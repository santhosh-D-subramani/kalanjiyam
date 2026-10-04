import 'dart:io';
import 'dart:isolate';

import '../../../core/system/command_runner.dart';
import '../../../core/system/shell_env.dart';
import 'key_file.dart';

/// Resolves freedesktop icon names (e.g. `firefox`) to files, following the
/// Icon Theme Specification: current theme → inherited themes → `hicolor`
/// → `/usr/share/pixmaps`.
class IconResolver {
  IconResolver._();

  static final IconResolver instance = IconResolver._();

  static const List<String> _extensions = <String>['svg', 'png', 'xpm'];
  static const int _preferredSize = 64;

  final Map<String, String?> _cache = <String, String?>{};
  List<_ThemeDir>? _searchDirs;
  List<String> _pixmapDirs = <String>[];
  Future<void>? _loading;
  String? themeName;

  Future<void> ensureLoaded() => _loading ??= _load();

  void clearCache() {
    _cache.clear();
  }

  /// Returns a file path for [icon] (a name or an absolute path), or null.
  /// Call [ensureLoaded] first.
  String? resolve(String? icon) {
    if (icon == null || icon.trim().isEmpty) return null;
    final String name = icon.trim();
    if (name.startsWith('/')) {
      return File(name).existsSync() ? name : null;
    }
    return _cache.putIfAbsent(name, () => _lookup(name));
  }

  /// Resolves many names at once on a background isolate (thousands of
  /// `stat` calls would otherwise stall the UI) and caches the results.
  Future<void> resolveAll(Iterable<String?> icons) async {
    await ensureLoaded();
    final Set<String> pending = <String>{
      for (final String? icon in icons)
        if (icon != null && icon.trim().isNotEmpty && !icon.trim().startsWith('/') && !_cache.containsKey(icon.trim()))
          icon.trim(),
    };
    if (pending.isEmpty) return;
    final List<String> dirs = (_searchDirs ?? const <_ThemeDir>[]).map((_ThemeDir d) => d.path).toList();
    final List<String> pixmaps = List<String>.of(_pixmapDirs);
    final List<String> names = pending.toList();
    _cache.addAll(await _resolveInIsolate(names, dirs, pixmaps));
  }

  // Static so the isolate closure can never capture `this`.
  static Future<Map<String, String?>> _resolveInIsolate(List<String> names, List<String> dirs, List<String> pixmaps) {
    return Isolate.run(() => <String, String?>{for (final String name in names) name: _lookupIn(name, dirs, pixmaps)});
  }

  String? _lookup(String rawName) =>
      _lookupIn(rawName, (_searchDirs ?? const <_ThemeDir>[]).map((_ThemeDir d) => d.path).toList(), _pixmapDirs);

  static String? _lookupIn(String rawName, List<String> dirs, List<String> pixmapDirs) {
    // Names should not carry an extension, but many files use one anyway.
    final String name = rawName.replaceFirst(RegExp(r'\.(png|svg|xpm)$'), '');
    if (name.contains('/')) return null;
    for (final String dir in dirs) {
      for (final String ext in _extensions) {
        final String candidate = '$dir/$name.$ext';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    for (final String dir in pixmapDirs) {
      for (final String ext in _extensions) {
        final String candidate = '$dir/$name.$ext';
        if (File(candidate).existsSync()) return candidate;
      }
      if (File('$dir/$rawName').existsSync()) return '$dir/$rawName';
    }
    return null;
  }

  Future<void> _load() async {
    await ShellEnv.instance.ready;
    final ShellEnv env = ShellEnv.instance;
    final List<String> baseDirs = <String>[
      '${env.home}/.icons',
      '${env.xdgDataHome}/icons',
      for (final String d in env.xdgDataDirs) '$d/icons',
    ].where((String d) => Directory(d).existsSync()).toList();
    _pixmapDirs = <String>[
      for (final String d in env.xdgDataDirs) '$d/pixmaps',
      '/usr/share/pixmaps',
    ].where((String d) => Directory(d).existsSync()).toSet().toList();

    themeName = await _currentThemeName(env);

    // Theme inheritance chain, always ending with hicolor.
    final List<String> chain = <String>[];
    void visit(String theme, int depth) {
      if (depth > 8 || chain.contains(theme)) return;
      chain.add(theme);
      final KeyFile? index = _readIndex(baseDirs, theme);
      final String? inherits = index?.get('Icon Theme', 'Inherits');
      for (final String parent in (inherits ?? '').split(',')) {
        final String p = parent.trim();
        if (p.isNotEmpty) visit(p, depth + 1);
      }
    }

    if (themeName != null) visit(themeName!, 0);
    if (!chain.contains('hicolor')) chain.add('hicolor');

    final List<_ThemeDir> dirs = <_ThemeDir>[];
    for (final String theme in chain) {
      final List<_ThemeDir> themeDirs = <_ThemeDir>[];
      for (final String base in baseDirs) {
        final String root = '$base/$theme';
        if (!Directory(root).existsSync()) continue;
        final KeyFile? index = _readIndexAt('$root/index.theme');
        if (index == null) {
          // Theme without index: scan common layouts.
          for (final String sub in const <String>[
            'scalable/apps',
            '256x256/apps',
            '128x128/apps',
            '64x64/apps',
            '48x48/apps',
            '32x32/apps',
          ]) {
            if (Directory('$root/$sub').existsSync()) {
              themeDirs.add(_ThemeDir('$root/$sub', 64, true));
            }
          }
          continue;
        }
        final String directories = <String?>[
          index.get('Icon Theme', 'Directories'),
          index.get('Icon Theme', 'ScaledDirectories'),
        ].whereType<String>().join(',');
        for (final String sub in directories.split(',')) {
          final String s = sub.trim();
          if (s.isEmpty) continue;
          final String path = '$root/$s';
          if (!Directory(path).existsSync()) continue;
          final int size = int.tryParse(index.get(s, 'Size') ?? '') ?? 48;
          final int scale = int.tryParse(index.get(s, 'Scale') ?? '') ?? 1;
          final String context = (index.get(s, 'Context') ?? '').toLowerCase();
          final bool isApps = context == 'applications' || context == 'apps' || s.contains('apps');
          themeDirs.add(
            _ThemeDir(path, size * scale, isApps, scalable: (index.get(s, 'Type') ?? '').toLowerCase() == 'scalable'),
          );
        }
      }
      // Within a theme: app icons first, then by closeness to the preferred
      // size (larger wins ties), scalable SVGs counting as a perfect fit.
      themeDirs.sort((_ThemeDir a, _ThemeDir b) {
        if (a.apps != b.apps) return a.apps ? -1 : 1;
        final int da = a.scalable ? 0 : (a.size - _preferredSize).abs();
        final int db = b.scalable ? 0 : (b.size - _preferredSize).abs();
        if (da != db) return da.compareTo(db);
        return b.size.compareTo(a.size);
      });
      dirs.addAll(themeDirs);
    }
    _searchDirs = dirs;
  }

  KeyFile? _readIndex(List<String> baseDirs, String theme) {
    for (final String base in baseDirs) {
      final KeyFile? index = _readIndexAt('$base/$theme/index.theme');
      if (index != null) return index;
    }
    return null;
  }

  KeyFile? _readIndexAt(String path) {
    try {
      final File file = File(path);
      if (!file.existsSync()) return null;
      return KeyFile.parse(file.readAsStringSync());
    } on Object {
      return null;
    }
  }

  Future<String?> _currentThemeName(ShellEnv env) async {
    // GNOME-style setting (also honoured by most GTK apps on other desktops).
    final String? gsettings = await CommandRunner.output('gsettings', <String>[
      'get',
      'org.gnome.desktop.interface',
      'icon-theme',
    ], timeout: const Duration(seconds: 5));
    if (gsettings != null) {
      final String name = gsettings.replaceAll("'", '').trim();
      if (name.isNotEmpty) return name;
    }
    // KDE
    final String? kde = _iniValue('${env.xdgConfigHome}/kdeglobals', 'Icons', 'Theme');
    if (kde != null) return kde;
    // GTK settings files
    for (final String file in <String>[
      '${env.xdgConfigHome}/gtk-4.0/settings.ini',
      '${env.xdgConfigHome}/gtk-3.0/settings.ini',
    ]) {
      final String? value = _iniValue(file, 'Settings', 'gtk-icon-theme-name');
      if (value != null) return value;
    }
    return null;
  }

  String? _iniValue(String path, String group, String key) {
    final KeyFile? file = _readIndexAt(path);
    final String? value = file?.get(group, key)?.replaceAll('"', '').trim();
    return (value == null || value.isEmpty) ? null : value;
  }
}

class _ThemeDir {
  _ThemeDir(this.path, this.size, this.apps, {this.scalable = false});

  final String path;
  final int size;
  final bool apps;
  final bool scalable;
}
