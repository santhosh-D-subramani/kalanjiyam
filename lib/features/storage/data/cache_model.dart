import 'dart:io';

import 'package:material_ui/material_ui.dart' show IconData;

import '../../../core/system/command_runner.dart';
import '../../../core/system/privilege.dart';
import '../../../core/system/shell_env.dart';

enum CacheSafety { safe, caution, risky }

enum CacheGroup { javascript, dart, jvm, python, rust, go, other, system, apps }

extension CacheGroupLabel on CacheGroup {
  String get label => switch (this) {
    CacheGroup.javascript => 'JavaScript & Node',
    CacheGroup.dart => 'Dart & Flutter',
    CacheGroup.jvm => 'Gradle, Java & Android',
    CacheGroup.python => 'Python',
    CacheGroup.rust => 'Rust',
    CacheGroup.go => 'Go',
    CacheGroup.other => 'Other languages & tools',
    CacheGroup.system => 'System',
    CacheGroup.apps => 'Apps & browsers',
  };
}

/// How a cache is cleaned.
sealed class CleanSpec {
  const CleanSpec();

  /// Human readable description shown before cleaning.
  String describe(List<String> paths);
}

/// Runs the tool's official clean command.
class CleanCommand extends CleanSpec {
  const CleanCommand(this.argv, {this.root = false, this.fallbackToDelete = false, this.environment});

  final List<String> argv;
  final bool root;

  /// Delete the cache paths if the command fails (e.g. older tool versions).
  final bool fallbackToDelete;
  final Map<String, String>? environment;

  @override
  String describe(List<String> paths) => '${root ? '(as administrator) ' : ''}${argv.join(' ')}';
}

/// Deletes the cache directories (or only their contents).
class CleanDelete extends CleanSpec {
  const CleanDelete({this.contentsOnly = false});

  final bool contentsOnly;

  @override
  String describe(List<String> paths) =>
      '${contentsOnly ? 'Delete the contents of' : 'Delete'}:\n${paths.map(_tildify).join('\n')}';
}

/// Anything more involved (stop daemons first, several commands, …).
class CleanCustom extends CleanSpec {
  const CleanCustom(this.description, this.run, {this.root = false});

  final String description;
  final bool root;
  final Future<CommandResult> Function(List<String> paths, void Function(String line) log) run;

  @override
  String describe(List<String> paths) => description;
}

/// One cache the user can measure and clean.
class CacheTarget {
  const CacheTarget({
    required this.id,
    required this.name,
    required this.group,
    required this.icon,
    required this.description,
    required this.paths,
    required this.clean,
    this.safety = CacheSafety.safe,
    this.warning,
    this.detect,
    this.size,
    this.optIn = false,
    this.sharedStorage = false,
    this.processGuard = const <String>[],
  });

  final String id;
  final String name;
  final CacheGroup group;
  final IconData icon;
  final String description;
  final CacheSafety safety;

  /// Extra warning shown in the confirmation (for caution/risky items).
  final String? warning;

  /// Resolves the actual cache locations (honouring env vars and tool config).
  final Future<List<String>> Function() paths;

  /// Defaults to "at least one path exists".
  final Future<bool> Function()? detect;

  /// Defaults to the disk usage of [paths].
  final Future<int?> Function(List<String> paths)? size;
  final CleanSpec clean;

  /// Hidden unless "Show advanced" is on (big re-downloads, user data, …).
  final bool optIn;

  /// Hard-linked stores free less than their measured size.
  final bool sharedStorage;

  /// Substrings of process command lines that should not be running.
  final List<String> processGuard;

  bool get needsRoot => switch (clean) {
    CleanCommand(:final bool root) => root,
    CleanCustom(:final bool root) => root,
    CleanDelete() => false,
  };
}

String _tildify(String path) {
  final String home = ShellEnv.instance.home;
  return path == home || path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}

/// Executes [CacheTarget.clean] safely.
abstract final class CacheCleaner {
  /// Paths that a cache clean must never delete, even if a resolver
  /// returned them by mistake.
  static bool isSafeToDelete(String path) {
    final ShellEnv env = ShellEnv.instance;
    final String home = env.home;
    String realOf(String p) {
      try {
        return File(p).resolveSymbolicLinksSync();
      } on FileSystemException {
        return p;
      }
    }

    // Caches live in the home folder or the XDG dirs; those dirs may be
    // symlinks to (or set to) another drive, so accept their real paths too.
    final Set<String> roots = <String>{
      for (final String r in <String>[
        home,
        env.xdgCacheHome,
        '$home/.cache',
        env.xdgDataHome,
        env.xdgConfigHome,
      ]) ...<String>{r, realOf(r)},
    };
    bool under(String p) => roots.any((String r) => p.startsWith('$r/'));
    if (!under(path)) return false;
    final FileSystemEntityType type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) return false; // never follow a symlinked cache root
    final String real = type == FileSystemEntityType.notFound ? path : realOf(path);
    if (!under(real)) return false;
    final Set<String> protected = <String>{
      home,
      env.xdgCacheHome,
      env.xdgConfigHome,
      env.xdgDataHome,
      // The defaults too, in case XDG_* point elsewhere.
      '$home/.cache',
      '$home/.config',
      '$home/.local/share',
      '$home/.local',
      '$home/.local/state',
      '$home/.gradle',
      '$home/.android',
      '$home/.cargo',
      '$home/.rustup',
      '$home/.m2',
      '$home/.npm',
      '$home/.pub-cache/bin',
      '$home/.ssh',
      '$home/.gnupg',
      '$home/Documents',
      '$home/Downloads',
      '$home/Pictures',
      '$home/Music',
      '$home/Videos',
      '$home/Desktop',
    };
    final Set<String> protectedAll = <String>{
      for (final String x in protected) ...<String>{x, realOf(x)},
      ...roots,
    };
    return !protectedAll.contains(real) && !protectedAll.contains(path);
  }

  static Future<CommandResult> run(CacheTarget target, List<String> paths, void Function(String line) log) async {
    final CleanSpec spec = target.clean;
    final String home = ShellEnv.instance.home;
    switch (spec) {
      case CleanCommand():
        log('\$ ${spec.argv.join(' ')}');
        final CommandResult r = spec.root
            ? await PrivilegeService.instance.run(
                spec.argv,
                reason: 'Cleaning ${target.name} requires administrator rights.',
                onLine: log,
              )
            : await CommandRunner.run(
                spec.argv.first,
                spec.argv.sublist(1),
                onLine: log,
                workingDirectory: home,
                environment: <String, String>{'NO_COLOR': '1', 'TERM': 'dumb', ...?spec.environment},
                timeout: const Duration(minutes: 15),
              );
        if (!r.ok && spec.fallbackToDelete && !spec.root) {
          log('Command failed; deleting the cache folders instead.');
          return deletePaths(paths, log);
        }
        return r;
      case CleanDelete():
        return deletePaths(paths, log, contentsOnly: spec.contentsOnly);
      case CleanCustom():
        return spec.run(paths, log);
    }
  }

  /// Deletes [paths] (inside the home directory only). Read-only trees are
  /// made writable first when a plain delete fails.
  static Future<CommandResult> deletePaths(
    List<String> paths,
    void Function(String line) log, {
    bool contentsOnly = false,
  }) async {
    final List<String> errors = <String>[];
    for (final String path in paths) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (!isSafeToDelete(path)) {
        errors.add('Refusing to delete ${_tildify(path)} (protected location)');
        continue;
      }
      final List<String> targets = <String>[];
      if (contentsOnly && type == FileSystemEntityType.directory) {
        try {
          targets.addAll(Directory(path).listSync(followLinks: false).map((FileSystemEntity e) => e.path));
        } on FileSystemException catch (e) {
          errors.add('${_tildify(path)}: ${e.osError?.message ?? e.message}');
          continue;
        }
      } else {
        targets.add(path);
      }
      for (final String t in targets) {
        log('Deleting ${_tildify(t)}');
        if (await _delete(t)) continue;
        // Go module caches, Bazel trees, … are read-only on purpose.
        await CommandRunner.run('chmod', <String>['-R', 'u+w', '--', t], timeout: const Duration(minutes: 5));
        if (!await _delete(t)) errors.add('Could not delete ${_tildify(t)}');
      }
    }
    for (final String e in errors) {
      log(e);
    }
    return CommandResult(exitCode: errors.isEmpty ? 0 : 1, stdout: '', stderr: errors.join('\n'));
  }

  static Future<bool> _delete(String path) async {
    try {
      final FileSystemEntityType type = FileSystemEntity.typeSync(path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          await File(path).delete();
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Names of running processes whose command line contains any of [needles].
  static List<String> runningProcesses(List<String> needles) {
    if (needles.isEmpty) return const <String>[];
    final Set<String> found = <String>{};
    try {
      for (final FileSystemEntity e in Directory('/proc').listSync()) {
        final String name = e.path.substring(6);
        if (int.tryParse(name) == null) continue;
        try {
          final String cmdline = File('${e.path}/cmdline').readAsStringSync().replaceAll('\u0000', ' ');
          for (final String n in needles) {
            if (cmdline.contains(n)) found.add(n);
          }
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      return const <String>[];
    }
    return found.toList();
  }
}
