import 'dart:io';
import 'dart:isolate';

import '../../../core/system/command_runner.dart';
import '../../../core/system/privilege.dart';
import '../../../core/system/shell_env.dart';
import '../../../core/utils/atomic_write.dart';
import 'desktop_entry.dart';
import 'key_file.dart';

/// Result of validating a desktop file with `desktop-file-validate`.
class ValidationReport {
  const ValidationReport({required this.available, required this.errors, required this.warnings});

  final bool available;
  final List<String> errors;
  final List<String> warnings;

  bool get hasErrors => errors.isNotEmpty;
}

/// Finds, reads and writes `.desktop` files following the XDG Base
/// Directory and Desktop Entry specifications.
class DesktopEntryRepository {
  DesktopEntryRepository._();

  static final DesktopEntryRepository instance = DesktopEntryRepository._();

  /// Where user entries live (`$XDG_DATA_HOME/applications`).
  String get userDir => '${ShellEnv.instance.xdgDataHome}/applications';

  /// All `applications` directories, highest precedence first.
  List<String> applicationDirs() {
    final ShellEnv env = ShellEnv.instance;
    final List<String> dirs = <String>[
      userDir,
      for (final String d in env.xdgDataDirs) '$d/applications',
      // Usually already part of XDG_DATA_DIRS, but not when the app was started
      // from an environment that skipped /etc/profile.d.
      '${env.xdgDataHome}/flatpak/exports/share/applications',
      '/var/lib/flatpak/exports/share/applications',
      '/var/lib/snapd/desktop/applications',
    ];
    final List<String> result = <String>[];
    final Set<String> seen = <String>{};
    for (final String dir in dirs) {
      final String normalized = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
      if (seen.add(normalized)) result.add(normalized);
    }
    return result;
  }

  Future<List<DesktopEntry>> scan() async {
    await ShellEnv.instance.ready;
    final ShellEnv env = ShellEnv.instance;
    final List<String> dirs = applicationDirs();
    final String userDirPath = userDir;
    final String dataHome = env.xdgDataHome;
    final List<String> pathDirs = env.pathDirs;
    final List<_RawEntry> raw = await _scanInIsolate(dirs, userDirPath, dataHome, pathDirs);
    return raw
        .map(
          (_RawEntry r) => DesktopEntry(
            id: r.id,
            path: r.path,
            source: r.source,
            file: KeyFile.parse(r.text),
            writable: r.writable,
            shadowed: r.shadowed,
            missingProgram: r.missingProgram,
          ),
        )
        .toList();
  }

  static Future<List<_RawEntry>> _scanInIsolate(
    List<String> dirs,
    String userDir,
    String dataHome,
    List<String> pathDirs,
  ) {
    return Isolate.run(() => _scanSync(dirs, userDir, dataHome, pathDirs));
  }

  static List<_RawEntry> _scanSync(List<String> dirs, String userDir, String dataHome, List<String> pathDirs) {
    final Map<String, _RawEntry> byId = <String, _RawEntry>{};
    final List<_RawEntry> ordered = <_RawEntry>[];
    for (final String dir in dirs) {
      final Directory root = Directory(dir);
      if (!root.existsSync()) continue;
      final List<File> files = <File>[];
      try {
        for (final FileSystemEntity e in root.listSync(recursive: true, followLinks: false)) {
          if (!e.path.endsWith('.desktop')) continue;
          if (e is File || (e is Link && FileSystemEntity.isFileSync(e.path))) {
            files.add(File(e.path));
          }
        }
      } on FileSystemException {
        continue;
      }
      files.sort((File a, File b) => a.path.compareTo(b.path));
      for (final File file in files) {
        final String relative = file.path.substring(dir.length + 1);
        final String id = relative.replaceAll('/', '-');
        final _RawEntry? existing = byId[id];
        if (existing != null) {
          existing.shadowed.add(file.path);
          continue;
        }
        String text;
        try {
          text = file.readAsStringSync();
        } on Object {
          continue;
        }
        final KeyFile parsed = KeyFile.parse(text);
        if (!parsed.hasGroup(kDesktopEntryGroup)) continue;
        final EntrySource source = dir == userDir
            ? EntrySource.user
            : (file.path.contains('/flatpak/')
                  ? EntrySource.flatpak
                  : (file.path.contains('snapd') ? EntrySource.snap : EntrySource.system));
        final _RawEntry entry = _RawEntry(
          id: id,
          path: file.path,
          source: source,
          text: text,
          writable: _isWritable(file.path),
          missingProgram: _missingProgram(parsed, pathDirs),
        );
        byId[id] = entry;
        ordered.add(entry);
      }
    }
    return ordered;
  }

  static bool _isWritable(String path) {
    try {
      final RandomAccessFile f = File(path).openSync(mode: FileMode.append);
      f.closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String? _missingProgram(KeyFile file, List<String> pathDirs) {
    final String type = KeyFile.unescape(file.get(kDesktopEntryGroup, 'Type') ?? 'Application');
    if (type != 'Application') return null;
    if ((file.get(kDesktopEntryGroup, 'DBusActivatable') ?? '').toLowerCase() == 'true' &&
        file.get(kDesktopEntryGroup, 'Exec') == null) {
      return null;
    }
    final String? tryExec = file.get(kDesktopEntryGroup, 'TryExec');
    final String? program = tryExec != null
        ? KeyFile.unescape(tryExec).trim()
        : execProgram(file.get(kDesktopEntryGroup, 'Exec'));
    if (program == null || program.isEmpty) {
      return file.get(kDesktopEntryGroup, 'Exec') == null ? '(no Exec)' : null;
    }
    if (program.startsWith('/')) {
      return File(program).existsSync() ? null : program;
    }
    for (final String dir in pathDirs) {
      if (File('$dir/$program').existsSync()) return null;
    }
    return program;
  }

  // ---------------------------------------------------------------- writing

  /// Path a user-level file with [id] would have.
  String userPathFor(String id) => '$userDir/$id';

  /// Picks an unused desktop file ID derived from [name].
  String suggestId(String name, Iterable<String> takenIds) {
    String slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    if (slug.isEmpty) slug = 'launcher';
    final Set<String> taken = takenIds.toSet();
    String candidate = '$slug.desktop';
    int n = 2;
    while (taken.contains(candidate) || File(userPathFor(candidate)).existsSync()) {
      candidate = '$slug-$n.desktop';
      n++;
    }
    return candidate;
  }

  /// Writes [text] to the user's applications directory as [id].
  Future<String> writeUserEntry(String id, String text) async {
    final String path = userPathFor(id);
    await Directory(userDir).create(recursive: true);
    await atomicWrite(path, text);
    await _refreshDatabase(userDir);
    return path;
  }

  /// Atomically rewrites a file the user can already write (user entries,
  /// including ones in sub-directories of the applications folder).
  Future<void> writeFile(String path, String text) async {
    await atomicWrite(path, text);
    await _refreshDatabase(File(path).parent.path);
  }

  /// Real directories of distro-managed launchers. Anything else (Nix store,
  /// Flatpak/Snap exports, …) is managed by its own tool and is never
  /// modified with administrator rights.
  static const List<String> _systemRoots = <String>[
    '/usr/share/applications/',
    '/usr/local/share/applications/',
    '/etc/xdg/',
  ];

  /// Whether [entry] is a regular file in a distro launcher directory that
  /// may be overwritten or deleted with administrator rights.
  bool canModifySystemFile(DesktopEntry entry) => !entry.isUser && _isSystemFile(entry.path);

  static bool _isSystemFile(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return false;
      final String real = File(path).resolveSymbolicLinksSync();
      return _systemRoots.any(real.startsWith);
    } on FileSystemException {
      return false;
    }
  }

  /// Overwrites a system-wide file in place (requires administrator rights).
  Future<CommandResult> writeSystemEntry(String path, String text, {void Function(String)? onLine}) async {
    if (!_isSystemFile(path)) throw StateError('Not a system launcher file: $path');
    final Directory tmpDir = await Directory('${ShellEnv.instance.xdgCacheHome}/kalanjiyam').create(recursive: true);
    final File tmp = File('${tmpDir.path}/${path.split('/').last}');
    await tmp.writeAsString(text, flush: true);
    try {
      // One privileged call (one password prompt): copy, then refresh the
      // MIME cache. Paths are passed as positional parameters, never
      // interpolated into the script.
      return await PrivilegeService.instance.run(
        <String>[
          'sh',
          '-c',
          // Refuse a source that was swapped for a symlink (e.g. to /etc/shadow).
          r'[ -f "$1" ] && [ ! -L "$1" ] || { echo "unsafe source file" >&2; exit 3; }; '
              r'install -m 0644 -- "$1" "$2" && { command -v update-desktop-database >/dev/null 2>&1 '
              r'&& update-desktop-database -q "$3" || true; }',
          'kalanjiyam',
          tmp.path,
          path,
          File(path).parent.path,
        ],
        reason: 'Saving a system-wide launcher requires administrator rights.',
        onLine: onLine,
      );
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  /// Deletes a user-owned file.
  Future<void> deleteUserEntry(DesktopEntry entry) async {
    final File file = File(entry.path);
    if (file.existsSync()) await file.delete();
    await _refreshDatabase(userDir);
  }

  /// Deletes a system-wide file (requires administrator rights).
  Future<CommandResult> deleteSystemEntry(DesktopEntry entry, {void Function(String)? onLine}) async {
    if (!canModifySystemFile(entry)) throw StateError('Not a system launcher file: ${entry.path}');
    return PrivilegeService.instance.run(
      <String>[
        'sh',
        '-c',
        r'rm -f -- "$1" && { command -v update-desktop-database >/dev/null 2>&1 '
            r'&& update-desktop-database -q "$2" || true; }',
        'kalanjiyam',
        entry.path,
        File(entry.path).parent.path,
      ],
      reason: 'Deleting a system-wide launcher requires administrator rights.',
      onLine: onLine,
    );
  }

  /// Hides a system entry from launchers via a `NoDisplay=true` user override.
  Future<String> hideWithOverride(DesktopEntry entry) {
    final KeyFile copy = entry.file.copy()..set(kDesktopEntryGroup, 'NoDisplay', 'true');
    return writeUserEntry(entry.id, copy.serialize());
  }

  Future<ValidationReport> validate(String id, String text) async {
    if (!ShellEnv.instance.has('desktop-file-validate')) {
      return const ValidationReport(available: false, errors: <String>[], warnings: <String>[]);
    }
    final Directory tmpDir = await Directory('${ShellEnv.instance.xdgCacheHome}/kalanjiyam/validate')
        .create(recursive: true);
    final File tmp = File('${tmpDir.path}/${id.endsWith('.desktop') ? id : '$id.desktop'}');
    await tmp.writeAsString(text, flush: true);
    try {
      final CommandResult result = await CommandRunner.run('desktop-file-validate', <String>[
        tmp.path,
      ], timeout: const Duration(seconds: 20));
      final List<String> errors = <String>[];
      final List<String> warnings = <String>[];
      for (final String line in result.output.split('\n')) {
        final String l = line.replaceFirst('${tmp.path}: ', '').trim();
        if (l.isEmpty) continue;
        if (l.startsWith('error:')) {
          errors.add(l);
        } else if (l.startsWith('warning:') || l.startsWith('hint:')) {
          warnings.add(l);
        }
      }
      return ValidationReport(available: true, errors: errors, warnings: warnings);
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  Future<void> _refreshDatabase(String dir) async {
    if (!ShellEnv.instance.has('update-desktop-database')) return;
    try {
      await CommandRunner.run('update-desktop-database', <String>['-q', dir], timeout: const Duration(seconds: 30));
    } on Object {
      // The MIME cache refresh is an optimisation; failures are not fatal.
    }
  }
}

class _RawEntry {
  _RawEntry({
    required this.id,
    required this.path,
    required this.source,
    required this.text,
    required this.writable,
    required this.missingProgram,
  });

  final String id;
  final String path;
  final EntrySource source;
  final String text;
  final bool writable;
  final String? missingProgram;
  final List<String> shadowed = <String>[];
}
