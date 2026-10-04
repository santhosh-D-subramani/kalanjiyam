import 'dart:io';

import '../../../core/system/command_runner.dart';
import '../../../core/system/shell_env.dart';
import 'managers/language_managers.dart';
import 'managers/system_managers.dart';
import 'managers/universal_managers.dart';
import 'package_models.dart';

/// Every supported package manager, system managers first. Only those
/// detected on the running system are shown.
List<PackageManager> buildPackageManagers() => <PackageManager>[
  // System
  PacmanManager(),
  ForeignPacmanManager(),
  AptManager(),
  DnfManager(),
  ZypperManager(),
  ApkManager(),
  XbpsManager(),
  PortageManager(),
  EopkgManager(),
  NixManager(),
  GuixManager(),
  // Universal
  FlatpakManager(),
  SnapManager(),
  AppImageManager(),
  BrewManager(),
  // Language & tool installers
  NpmGlobalManager(),
  PnpmGlobalManager(),
  YarnGlobalManager(),
  BunGlobalManager(),
  DenoManager(),
  PipxManager(),
  UvToolManager(),
  PipUserManager(),
  CargoManager(),
  GoBinManager(),
  GemManager(),
  ComposerManager(),
  DartPubManager(),
  DotnetToolManager(),
  MiseManager(),
  AsdfManager(),
  SdkmanManager(),
];

// ------------------------------------------------------------------ helpers

ShellEnv get env => ShellEnv.instance;

bool has(String binary) => env.has(binary);

/// Runs a command with the C locale and returns the result.
Future<CommandResult> run(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(minutes: 2),
  Map<String, String>? environment,
}) => CommandRunner.run(exe, args, timeout: timeout, environment: environment);

/// Runs a command and throws a readable error when it fails.
Future<String> runOrThrow(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(minutes: 2),
  Map<String, String>? environment,
  bool allowNonZero = false,
}) async {
  final CommandResult r = await run(exe, args, timeout: timeout, environment: environment);
  if (r.timedOut) throw StateError('$exe timed out');
  if (r.exitCode != 0 && !(allowNonZero && r.stdout.trim().isNotEmpty)) {
    throw StateError('$exe ${args.join(' ')} failed: ${r.errorSummary}');
  }
  return r.stdout;
}

bool nonEmptyFile(String path) {
  try {
    return File(path).lengthSync() > 0;
  } on FileSystemException {
    return false;
  }
}

bool nonEmptyDir(String path) {
  try {
    return Directory(path).listSync().isNotEmpty;
  } on FileSystemException {
    return false;
  }
}

String? readText(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

DateTime? epochSeconds(String? raw) {
  final int? s = int.tryParse((raw ?? '').trim());
  if (s == null || s <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(s * 1000);
}

DateTime? mtimeOf(String path) {
  try {
    return File(path).statSync().modified;
  } on FileSystemException {
    return null;
  }
}

/// `/etc/os-release` as a map (ID, ID_LIKE, NAME, …).
Map<String, String> osRelease() {
  final String text = readText('/etc/os-release') ?? readText('/usr/lib/os-release') ?? '';
  final Map<String, String> map = <String, String>{};
  for (final String line in text.split('\n')) {
    final int eq = line.indexOf('=');
    if (eq <= 0) continue;
    String value = line.substring(eq + 1).trim();
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    map[line.substring(0, eq).trim()] = value;
  }
  return map;
}

/// True when `/etc/os-release` ID or ID_LIKE mentions any of [ids].
bool osIsLike(List<String> ids) {
  final Map<String, String> os = osRelease();
  final Set<String> tokens = <String>{
    ...(os['ID'] ?? '').toLowerCase().split(RegExp(r'\s+')),
    ...(os['ID_LIKE'] ?? '').toLowerCase().split(RegExp(r'\s+')),
  };
  return ids.any((String id) => tokens.any((String t) => t == id || t.startsWith(id)));
}

/// Finds which system package owns each path (one batched query).
/// Returns path → package name for owned paths only.
Future<Map<String, String>> systemOwners(List<String> paths) async {
  if (paths.isEmpty) return <String, String>{};
  final Map<String, String> owners = <String, String>{};
  if (has('pacman') && nonEmptyDir('/var/lib/pacman/local')) {
    final CommandResult r = await run('pacman', <String>['-Qo', ...paths], timeout: const Duration(seconds: 30));
    final RegExp re = RegExp(r'^(.*) is owned by (\S+) (\S+)$');
    for (final String line in r.stdout.split('\n')) {
      final RegExpMatch? m = re.firstMatch(line.trim());
      if (m == null) continue;
      // pacman appends "/" to directories.
      String path = m.group(1)!;
      if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
      owners[path] = m.group(2)!;
    }
  } else if (has('dpkg-query') && nonEmptyFile('/var/lib/dpkg/status')) {
    final CommandResult r = await run('dpkg-query', <String>['-S', ...paths], timeout: const Duration(seconds: 30));
    for (final String line in r.stdout.split('\n')) {
      final int sep = line.lastIndexOf(': ');
      if (sep <= 0) continue;
      final String path = line.substring(sep + 2).trim();
      final String pkg = line.substring(0, sep).split(',').first.trim();
      if (paths.contains(path)) owners[path] = pkg;
    }
  } else if (has('rpm') && (nonEmptyDir('/var/lib/rpm') || nonEmptyDir('/usr/lib/sysimage/rpm'))) {
    for (final String path in paths) {
      final CommandResult r = await run('rpm', <String>[
        '-qf',
        '--qf',
        '%{NAME}\n',
        path,
      ], timeout: const Duration(seconds: 15));
      if (r.ok && r.stdout.trim().isNotEmpty) owners[path] = r.stdout.trim().split('\n').first;
    }
  }
  return owners;
}

/// Whether the current user can write to [path].
Future<bool> isWritable(String path) async {
  final CommandResult r = await run('test', <String>['-w', path], timeout: const Duration(seconds: 5));
  return r.exitCode == 0;
}

String tildify(String path) {
  final String home = env.home;
  if (path == home || path.startsWith('$home/')) return '~${path.substring(home.length)}';
  return path;
}
