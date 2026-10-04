import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' show IconData;

import '../../../../core/system/command_runner.dart';
import '../../../../core/utils/format.dart';
import '../../../desktop_entries/data/desktop_entry.dart';
import '../../../desktop_entries/data/key_file.dart';
import '../package_managers.dart';
import '../package_models.dart';

// ================================================================== flatpak

class FlatpakManager extends PackageManager {
  @override
  String get id => 'flatpak';
  @override
  String get label => 'Flatpak';
  @override
  String get description => 'Flatpak apps and runtimes (user and system)';
  @override
  IconData get icon => M3EIcons.layers_outlined;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('flatpak');

  static const String _columns = 'application,name,version,branch,arch,origin,installation,size,description,ref';

  @override
  Future<List<InstalledPackage>> list() async {
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final bool apps in <bool>[true, false]) {
      final String text = await runOrThrow('flatpak', <String>[
        'list',
        apps ? '--app' : '--runtime',
        '--columns=$_columns',
      ]);
      for (final String line in text.split('\n')) {
        final List<String> f = line.split('\t');
        if (f.length < 10 || f[0].trim().isEmpty) continue;
        final String appId = f[0].trim();
        final String branch = f[3].trim();
        final String arch = f[4].trim();
        final String installation = f[6].trim();
        final bool user = installation == 'user';
        final String base = user ? '${env.home}/.local/share/flatpak' : '/var/lib/flatpak';
        out.add(
          InstalledPackage(
            name: f[1].trim().isEmpty ? appId : f[1].trim(),
            version: f[2].trim().isEmpty ? branch : f[2].trim(),
            managerId: id,
            description: f[8].trim(),
            size: Fmt.parseSize(f[7].replaceAll(' ', ' ').replaceAll('bytes', 'B').trim()),
            origin: f[5].trim(),
            scope: installation,
            explicit: apps,
            removeId: '$appId//$branch',
            installDate: (installation == 'user' || installation == 'system')
                ? mtimeOf('$base/${apps ? 'app' : 'runtime'}/$appId/$arch/$branch/active')
                : null,
            details: <String, String>{
              'Application ID': appId,
              'Branch': branch,
              'Architecture': arch,
              if (!apps) 'Kind': 'Runtime',
            },
          ),
        );
      }
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) {
    final String scope = package.scope ?? 'user';
    final String ref = package.removeId ?? package.name;
    if (scope == 'user') {
      return RemovalPlan(
        argv: <String>['flatpak', 'uninstall', '-y', '--noninteractive', '--user', ref],
        needsRoot: false,
      );
    }
    final RegExpMatch? named = RegExp(r'^system \((.+)\)$').firstMatch(scope);
    return RemovalPlan(
      argv: <String>[
        'flatpak',
        'uninstall',
        '-y',
        '--noninteractive',
        if (named != null) '--installation=${named.group(1)}' else '--system',
        ref,
      ],
      // Run as root through Kalanjiyam's own privilege handling, so it also
      // works without a polkit agent.
      needsRoot: true,
      reason: 'Removing a system-wide Flatpak requires administrator rights.',
      warning: package.explicit == false ? 'This is a runtime. Apps that use it will stop working.' : null,
    );
  }
}

// ===================================================================== snap

class SnapManager extends PackageManager {
  @override
  String get id => 'snap';
  @override
  String get label => 'Snap';
  @override
  String get description => 'Snap packages';
  @override
  IconData get icon => M3EIcons.extension_outlined;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('snap') && File('/run/snapd.socket').existsSync();

  @override
  Future<List<InstalledPackage>> list() async {
    final CommandResult r = await run('snap', <String>['list']);
    if (!r.ok) {
      if (r.stderr.contains('No snaps are installed')) return <InstalledPackage>[];
      throw StateError('snap list failed: ${r.errorSummary}');
    }
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final String line in r.stdout.split('\n').skip(1)) {
      final List<String> f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 5) continue;
      final String notes = f.length > 5 ? f.sublist(5).join(' ') : '';
      final bool infra = RegExp(r'\b(base|core|snapd|gadget|kernel)\b').hasMatch(notes);
      out.add(
        InstalledPackage(
          name: f[0],
          version: f[1],
          managerId: id,
          origin: f[4].replaceAll('✓', '').replaceAll('*', ''),
          explicit: !infra,
          details: <String, String>{
            'Revision': f[2],
            'Tracking': f[3],
            if (notes.isNotEmpty && notes != '-') 'Notes': notes,
          },
        ),
      );
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    argv: <String>['snap', 'remove', package.name],
    needsRoot: true,
    reason: 'Removing a snap requires administrator rights.',
    warning: 'snapd keeps a snapshot of the app data for a while after removal.',
  );
}

// ================================================================= AppImage

class AppImageManager extends PackageManager {
  @override
  String get id => 'appimage';
  @override
  String get label => 'AppImage';
  @override
  String get description => 'AppImage files in common folders';
  @override
  IconData get icon => M3EIcons.rocket_launch_outlined;

  List<InstalledPackage>? _cache;

  @override
  Future<bool> detect() async {
    _cache = await _scan();
    return _cache!.isNotEmpty;
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final List<InstalledPackage>? cached = _cache;
    _cache = null;
    return cached ?? await _scan();
  }

  Future<List<InstalledPackage>> _scan() async {
    final String home = env.home;
    final String dataHome = env.xdgDataHome;
    final String configHome = env.xdgConfigHome;
    final List<_AppImageInfo> found = await _scanInIsolate(home, dataHome, configHome);
    return <InstalledPackage>[
      for (final _AppImageInfo a in found)
        InstalledPackage(
          name: a.name,
          version: a.version ?? '',
          managerId: id,
          size: a.size,
          installDate: a.modified,
          removeId: a.path,
          description: tildify(a.path),
          details: <String, String>{'File': a.path, if (a.desktopFile != null) 'Launcher': a.desktopFile!},
        ),
    ];
  }

  static Future<List<_AppImageInfo>> _scanInIsolate(String home, String dataHome, String configHome) {
    return Isolate.run(() => _scanSync(home, dataHome, configHome));
  }

  static bool _isAppImage(String path) {
    try {
      final RandomAccessFile f = File(path).openSync();
      try {
        final List<int> header = f.readSync(11);
        return header.length == 11 && header[8] == 0x41 && header[9] == 0x49 && (header[10] == 1 || header[10] == 2);
      } finally {
        f.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  static List<_AppImageInfo> _scanSync(String home, String dataHome, String configHome) {
    final Map<String, _AppImageInfo> byPath = <String, _AppImageInfo>{};

    // Launchers that point at AppImages give us nice names and versions.
    final Map<String, (String, String?, String)> launcherInfo = <String, (String, String?, String)>{};
    final Directory apps = Directory('$dataHome/applications');
    if (apps.existsSync()) {
      for (final FileSystemEntity e in apps.listSync()) {
        if (e is! File || !e.path.endsWith('.desktop')) continue;
        try {
          final KeyFile kf = KeyFile.parse(e.readAsStringSync());
          String? program = execProgram(kf.get(kDesktopEntryGroup, 'Exec'));
          if (program == null) continue;
          if (program.startsWith('~/')) program = '$home${program.substring(1)}';
          if (!program.toLowerCase().endsWith('.appimage') &&
              kf.get(kDesktopEntryGroup, 'X-AppImage-Version') == null) {
            continue;
          }
          final String name = KeyFile.unescape(
            kf.get(kDesktopEntryGroup, 'Name') ?? kf.get(kDesktopEntryGroup, 'X-AppImage-Old-Name') ?? '',
          );
          launcherInfo[program] = (name, kf.get(kDesktopEntryGroup, 'X-AppImage-Version'), e.path);
        } on Object {
          continue;
        }
      }
    }

    final List<String> dirs = <String>[
      '$home/Applications',
      '$home/AppImages',
      '$home/.local/bin',
      '$home/bin',
      '$home/Downloads',
      '$home/Desktop',
      '/opt',
    ];
    // AppImageLauncher's integration folder.
    final String? cfg = readText('$configHome/appimagelauncher.cfg');
    if (cfg != null) {
      final RegExpMatch? m = RegExp(r'^\s*destination\s*=\s*(.+)$', multiLine: true).firstMatch(cfg);
      if (m != null) {
        String d = m.group(1)!.trim();
        if (d.startsWith('~/')) d = '$home${d.substring(1)}';
        dirs.add(d);
      }
    }

    void consider(String path, {required bool requireExtension}) {
      if (byPath.containsKey(path)) return;
      final bool hasExt = path.toLowerCase().endsWith('.appimage');
      if (requireExtension && !hasExt) return;
      if (!_isAppImage(path)) return;
      final FileStat stat = FileStat.statSync(path);
      final (String, String?, String)? info = launcherInfo[path];
      String name = info?.$1 ?? '';
      if (name.isEmpty) {
        name = path
            .substring(path.lastIndexOf('/') + 1)
            .replaceAll(RegExp(r'\.appimage$', caseSensitive: false), '')
            .replaceAll(RegExp(r'_[0-9a-f]{32}$'), '');
      }
      byPath[path] = _AppImageInfo(path, name, info?.$2, stat.size, stat.modified, info?.$3);
    }

    for (final String dir in dirs) {
      final Directory d = Directory(dir);
      if (!d.existsSync()) continue;
      final bool loose =
          dir.endsWith('/Downloads') ||
          dir.endsWith('/Desktop') ||
          dir == '/opt' ||
          dir.endsWith('/.local/bin') ||
          dir.endsWith('/bin');
      try {
        for (final FileSystemEntity e in d.listSync(followLinks: false)) {
          if (e is File) {
            consider(e.path, requireExtension: loose);
          } else if (e is Directory &&
              (dir == '/opt' || dir.endsWith('/Applications') || dir.endsWith('/.local/bin'))) {
            // One level deep (e.g. /opt/<app>/<app>.AppImage, ~/.local/bin/app_image/).
            try {
              for (final FileSystemEntity c in e.listSync(followLinks: false)) {
                if (c is File) consider(c.path, requireExtension: true);
              }
            } on FileSystemException {
              continue;
            }
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    for (final String program in launcherInfo.keys) {
      if (File(program).existsSync()) consider(program, requireExtension: false);
    }
    return byPath.values.toList();
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) {
    final String path = package.removeId ?? '';
    if (path.isEmpty) return null;
    final bool userOwned = path.startsWith('${env.home}/');
    return RemovalPlan(
      argv: <String>['rm', '-f', '--', path],
      needsRoot: !userOwned,
      warning: package.details['Launcher'] != null
          ? 'The launcher for this AppImage will show as "Broken" in Launchers; delete it there if you like.'
          : null,
    );
  }
}

class _AppImageInfo {
  _AppImageInfo(this.path, this.name, this.version, this.size, this.modified, this.desktopFile);

  final String path;
  final String name;
  final String? version;
  final int size;
  final DateTime modified;
  final String? desktopFile;
}

// ================================================================= Homebrew

class BrewManager extends PackageManager {
  static const Map<String, String> brewEnv = <String, String>{
    'HOMEBREW_NO_AUTO_UPDATE': '1',
    'HOMEBREW_NO_ANALYTICS': '1',
    'HOMEBREW_NO_ENV_HINTS': '1',
    'HOMEBREW_NO_INSTALL_CLEANUP': '1',
  };

  String? _prefix;

  @override
  String get id => 'brew';
  @override
  String get label => 'Homebrew';
  @override
  String get description => 'Homebrew on Linux formulae and casks';
  @override
  IconData get icon => M3EIcons.sports_bar_outlined;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async {
    if (!has('brew')) return false;
    final CommandResult r = await run(
      'brew',
      <String>['--prefix'],
      environment: brewEnv,
      timeout: const Duration(seconds: 20),
    );
    final String prefix = r.stdout.trim();
    if (!r.ok || prefix.isEmpty || !Directory('$prefix/Cellar').existsSync()) return false;
    _prefix = prefix;
    return nonEmptyDir('$prefix/Cellar') || nonEmptyDir('$prefix/Caskroom');
  }

  /// Reads install receipts directly — no slow Ruby start-up per query.
  @override
  Future<List<InstalledPackage>> list() async {
    final String prefix = _prefix ?? (await detect() ? _prefix! : throw StateError('Homebrew not found'));
    final List<InstalledPackage> out = <InstalledPackage>[];
    final List<String> kegs = <String>[];
    final Directory cellar = Directory('$prefix/Cellar');
    for (final FileSystemEntity formula in cellar.existsSync() ? cellar.listSync() : const <FileSystemEntity>[]) {
      if (formula is! Directory) continue;
      final List<Directory> versions = formula.listSync().whereType<Directory>().toList()
        ..sort((Directory a, Directory b) => b.path.compareTo(a.path));
      if (versions.isEmpty) continue;
      final Directory keg = versions.first;
      kegs.add(keg.path);
      Map<String, dynamic> receipt = <String, dynamic>{};
      try {
        final Object? decoded = jsonDecode(readText('${keg.path}/INSTALL_RECEIPT.json') ?? '{}');
        if (decoded is Map<String, dynamic>) receipt = decoded;
      } on FormatException {
        receipt = <String, dynamic>{};
      }
      final Object? source = receipt['source'];
      out.add(
        InstalledPackage(
          name: formula.path.substring(formula.path.lastIndexOf('/') + 1),
          version: keg.path.substring(keg.path.lastIndexOf('/') + 1),
          managerId: id,
          explicit: receipt['installed_on_request'] is bool ? receipt['installed_on_request'] as bool : null,
          installDate: receipt['time'] is int
              ? DateTime.fromMillisecondsSinceEpoch((receipt['time'] as int) * 1000)
              : null,
          origin: source is Map ? source['tap']?.toString() : null,
          scope: 'formula',
          removeId: keg.path,
          details: <String, String>{
            if (versions.length > 1)
              'Other versions': versions.skip(1).map((Directory d) => d.path.split('/').last).join(', '),
          },
        ),
      );
    }
    final Directory caskroom = Directory('$prefix/Caskroom');
    for (final FileSystemEntity cask in caskroom.existsSync() ? caskroom.listSync() : const <FileSystemEntity>[]) {
      if (cask is! Directory) continue;
      final List<Directory> versions = cask
          .listSync()
          .whereType<Directory>()
          .where((Directory d) => !d.path.endsWith('/.metadata'))
          .toList();
      out.add(
        InstalledPackage(
          name: cask.path.substring(cask.path.lastIndexOf('/') + 1),
          version: versions.isEmpty ? '' : versions.first.path.split('/').last,
          managerId: id,
          explicit: true,
          scope: 'cask',
        ),
      );
    }
    // Keg sizes in one du call.
    if (kegs.isNotEmpty) {
      final CommandResult du = await run('du', <String>['-s', '-B1', '--', ...kegs]);
      final Map<String, int> sizes = <String, int>{};
      for (final String line in du.stdout.split('\n')) {
        final int tab = line.indexOf('\t');
        if (tab > 0) sizes[line.substring(tab + 1)] = int.tryParse(line.substring(0, tab)) ?? 0;
      }
      for (int i = 0; i < out.length; i++) {
        final InstalledPackage p = out[i];
        if (p.scope == 'formula' && sizes[p.removeId] != null) {
          out[i] = InstalledPackage(
            name: p.name,
            version: p.version,
            managerId: p.managerId,
            explicit: p.explicit,
            installDate: p.installDate,
            origin: p.origin,
            scope: p.scope,
            removeId: p.removeId,
            details: p.details,
            size: sizes[p.removeId],
          );
        }
      }
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    argv: <String>[
      'env',
      ...brewEnv.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}'),
      'brew',
      'uninstall',
      package.scope == 'cask' ? '--cask' : '--formula',
      package.name,
    ],
    needsRoot: false,
    warning: 'Homebrew refuses to uninstall a formula that other formulae depend on.',
  );
}
