import 'dart:convert';
import 'dart:io';

import 'package:material_3_expressive/material_3_expressive.dart';

import '../../../core/system/command_runner.dart';
import '../../../core/system/privilege.dart';
import '../../../core/system/shell_env.dart';
import '../../../core/utils/format.dart';
import 'cache_model.dart';

// ------------------------------------------------------------------ helpers

ShellEnv get _env => ShellEnv.instance;
String get _home => _env.home;
String get _cache => _env.xdgCacheHome;
String get _data => _env.xdgDataHome;
String? _var(String name) {
  final String? v = _env.environment[name];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

bool _has(String bin) => _env.has(bin);
bool _exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

/// Runs a path-printing command from a neutral directory (project files can
/// change which tool version runs).
Future<String?> _out(String exe, List<String> args, {Map<String, String>? environment}) async {
  final String? out = await CommandRunner.output(
    exe,
    args,
    timeout: const Duration(seconds: 30),
    workingDirectory: _home,
    environment: <String, String>{'NO_COLOR': '1', 'TERM': 'dumb', ...?environment},
  );
  if (out == null) return null;
  final String first = out
      .split('\n')
      .map((String l) => l.trim())
      .firstWhere((String l) => l.startsWith('/'), orElse: () => '');
  return first.isEmpty ? null : first;
}

Future<List<String>> _list(List<String> paths) async => paths;

/// Matches `prefix*` entries inside [dir] (e.g. AndroidStudio2025.1).
List<String> _glob(String dir, bool Function(String name) match) {
  try {
    return Directory(dir)
        .listSync(followLinks: false)
        .where((FileSystemEntity e) => match(e.path.substring(e.path.lastIndexOf('/') + 1)))
        .map((FileSystemEntity e) => e.path)
        .toList();
  } on FileSystemException {
    return <String>[];
  }
}

Future<String> _npmCache() async =>
    (await _out('npm', <String>['config', 'get', 'cache'])) ?? (_var('npm_config_cache') ?? '$_home/.npm');

String get _gradleHome => _var('GRADLE_USER_HOME') ?? '$_home/.gradle';
String get _cargoHome => _var('CARGO_HOME') ?? '$_home/.cargo';
String get _pubCache => _var('PUB_CACHE') ?? '$_home/.pub-cache';

Future<List<String>> _goPaths(String which) async {
  final String? out = await CommandRunner.output(
    'go',
    <String>['env', which],
    workingDirectory: _home,
    environment: <String, String>{'GOTOOLCHAIN': 'local'},
  );
  final String? p = out?.split('\n').first.trim();
  return (p == null || p.isEmpty) ? <String>[] : <String>[p];
}

/// Stops Gradle and Kotlin daemons (all versions) before touching Gradle's
/// user home, so files are not deleted underneath a running build.
Future<void> _stopGradleDaemons(void Function(String) log) async {
  final List<String> wrappers = <String>[];
  final Directory dists = Directory('$_gradleHome/wrapper/dists');
  if (dists.existsSync()) {
    for (final FileSystemEntity d in dists.listSync()) {
      for (final FileSystemEntity hash in d is Directory ? d.listSync() : const <FileSystemEntity>[]) {
        for (final FileSystemEntity g in hash is Directory ? hash.listSync() : const <FileSystemEntity>[]) {
          final String bin = '${g.path}/bin/gradle';
          if (File(bin).existsSync()) wrappers.add(bin);
        }
      }
    }
  }
  if (_has('gradle')) wrappers.add('gradle');
  for (final String g in wrappers) {
    log('\$ ${g.split('/').skip(g.split('/').length > 4 ? g.split('/').length - 4 : 0).join('/')} --stop');
    await CommandRunner.run(g, <String>['--stop'], workingDirectory: _home, timeout: const Duration(minutes: 2));
  }
  // Remaining daemons of versions without a local distribution.
  for (final FileSystemEntity e in Directory('/proc').listSync()) {
    final String pid = e.path.substring(6);
    if (int.tryParse(pid) == null) continue;
    try {
      final String cmd = File('${e.path}/cmdline').readAsStringSync();
      if (cmd.contains('org.gradle.launcher.daemon.bootstrap.GradleDaemon') ||
          cmd.contains('org.jetbrains.kotlin.daemon.KotlinCompileDaemon')) {
        log('Stopping daemon process $pid');
        Process.killPid(int.parse(pid));
      }
    } on Object {
      continue;
    }
  }
}

CleanCustom _gradleDelete(String description) =>
    CleanCustom(description, (List<String> paths, void Function(String) log) async {
      await _stopGradleDaemons(log);
      return CacheCleaner.deletePaths(paths, log);
    });

const List<String> _ideGuard = <String>['android-studio', 'idea.sh', 'jetbrains', 'com.intellij'];

// ------------------------------------------------------------------ catalog

List<CacheTarget> buildCacheCatalog() => <CacheTarget>[
  // ======================================================= JavaScript
  CacheTarget(
    id: 'npm',
    name: 'npm cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Downloaded npm packages (_cacache).',
    paths: () async => <String>['${await _npmCache()}/_cacache'],
    clean: const CleanCommand(<String>['npm', 'cache', 'clean', '--force'], fallbackToDelete: true),
  ),
  CacheTarget(
    id: 'npx',
    name: 'npx cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Packages fetched by npx / npm exec.',
    paths: () async => <String>['${await _npmCache()}/_npx'],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'npm-logs',
    name: 'npm logs',
    group: CacheGroup.javascript,
    icon: M3EIcons.article_outlined,
    description: 'Debug logs written by npm.',
    paths: () async => <String>['${await _npmCache()}/_logs'],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'yarn',
    name: 'Yarn classic cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Packages cached by Yarn 1.x.',
    detect: () async {
      if (!_has('yarn')) return false;
      final String? v = await CommandRunner.output('yarn', <String>['--version'], workingDirectory: _home);
      return v != null && v.startsWith('1.');
    },
    paths: () async => <String>[
      (await _out('yarn', <String>['cache', 'dir'])) ?? (_var('YARN_CACHE_FOLDER') ?? '$_cache/yarn'),
    ],
    clean: const CleanCommand(<String>['yarn', 'cache', 'clean']),
  ),
  CacheTarget(
    id: 'yarn-berry',
    name: 'Yarn (Berry) global cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    safety: CacheSafety.caution,
    description: 'Global cache and mirror of Yarn 2+.',
    warning:
        'Plug\'n\'Play projects load packages straight from this cache. They need "yarn install" again afterwards.',
    paths: () async {
      final String root = _var('YARN_GLOBAL_FOLDER') ?? '$_home/.yarn/berry';
      return <String>['$root/cache', '$root/metadata'];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'pnpm-store',
    name: 'pnpm store',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Content-addressable store; pruning removes packages no project uses.',
    sharedStorage: true,
    detect: () async => _has('pnpm'),
    paths: () async => <String>[
      (await _out('pnpm', <String>['store', 'path'])) ?? '$_data/pnpm/store',
    ],
    clean: const CleanCommand(<String>['pnpm', 'store', 'prune']),
  ),
  CacheTarget(
    id: 'pnpm-cache',
    name: 'pnpm metadata cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Package metadata and dlx cache.',
    paths: () async => <String>['$_cache/pnpm'],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'bun',
    name: 'Bun cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.bakery_dining_outlined,
    description: 'Global package cache of Bun.',
    sharedStorage: true,
    paths: () async => <String>[
      (await _out('bun', <String>['pm', 'cache', '-g'])) ??
          (_var('BUN_INSTALL_CACHE_DIR') ?? '$_home/.bun/install/cache'),
    ],
    clean: const CleanCommand(<String>['bun', 'pm', 'cache', 'rm', '-g'], fallbackToDelete: true),
  ),
  CacheTarget(
    id: 'deno',
    name: 'Deno cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.pets_outlined,
    safety: CacheSafety.caution,
    description: 'Remote modules, npm packages and compiled code (DENO_DIR).',
    warning: 'DENO_DIR also holds localStorage data of Deno programs.',
    detect: () async => _has('deno'),
    paths: () async {
      final String? json = await CommandRunner.output('deno', <String>['info', '--json'], workingDirectory: _home);
      try {
        final Object? d = json == null ? null : jsonDecode(json);
        if (d is Map && d['denoDir'] is String) return <String>[d['denoDir'] as String];
      } on FormatException {
        // fall through
      }
      return <String>[_var('DENO_DIR') ?? '$_cache/deno'];
    },
    clean: const CleanCommand(<String>['deno', 'clean']),
  ),
  CacheTarget(
    id: 'node-gyp',
    name: 'node-gyp headers',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Node.js headers downloaded for native addons.',
    paths: () => _list(<String>['$_cache/node-gyp', '$_home/.node-gyp']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'corepack',
    name: 'Corepack cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Package manager versions downloaded by Corepack.',
    paths: () => _list(<String>[_var('COREPACK_HOME') ?? '$_cache/node/corepack']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'nvm',
    name: 'nvm downloads',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Node.js archives downloaded by nvm.',
    paths: () => _list(<String>['${_var('NVM_DIR') ?? '$_home/.nvm'}/.cache']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'playwright',
    name: 'Playwright browsers',
    group: CacheGroup.javascript,
    icon: M3EIcons.travel_explore,
    safety: CacheSafety.caution,
    description: 'Browsers downloaded for Playwright tests.',
    warning: 'Hundreds of MB are downloaded again the next time tests run.',
    paths: () => _list(<String>[_var('PLAYWRIGHT_BROWSERS_PATH') ?? '$_cache/ms-playwright']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'puppeteer',
    name: 'Puppeteer browsers',
    group: CacheGroup.javascript,
    icon: M3EIcons.travel_explore,
    safety: CacheSafety.caution,
    description: 'Chrome builds downloaded by Puppeteer.',
    paths: () => _list(<String>[_var('PUPPETEER_CACHE_DIR') ?? '$_home/.cache/puppeteer']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'cypress',
    name: 'Cypress binaries',
    group: CacheGroup.javascript,
    icon: M3EIcons.travel_explore,
    safety: CacheSafety.caution,
    description: 'Cypress app versions.',
    paths: () => _list(<String>[_var('CYPRESS_CACHE_FOLDER') ?? '$_cache/Cypress']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'electron',
    name: 'Electron downloads',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Electron and electron-builder downloads.',
    paths: () => _list(<String>[
      _var('electron_config_cache') ?? '$_cache/electron',
      _var('ELECTRON_BUILDER_CACHE') ?? '$_cache/electron-builder',
    ]),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'typescript',
    name: 'TypeScript type cache',
    group: CacheGroup.javascript,
    icon: M3EIcons.javascript,
    description: 'Automatic type acquisition used by editors.',
    paths: () => _list(<String>['$_cache/typescript']),
    clean: const CleanDelete(),
  ),

  // ========================================================= Dart
  CacheTarget(
    id: 'pub-gc',
    name: 'Pub cache — unused packages',
    group: CacheGroup.dart,
    icon: M3EIcons.flutter_dash,
    description: 'Removes packages no recent project uses (dart pub cache gc). Projects keep working.',
    detect: () async => _has('dart') && _exists(_pubCache),
    paths: () => _list(<String>[_pubCache]),
    clean: const CleanCommand(<String>['dart', 'pub', 'cache', 'gc', '--force']),
  ),
  CacheTarget(
    id: 'pub-clean',
    name: 'Pub cache — everything',
    group: CacheGroup.dart,
    icon: M3EIcons.flutter_dash,
    safety: CacheSafety.caution,
    description: 'Wipes the whole Dart/Flutter package cache (dart pub cache clean).',
    warning:
        'Every project needs "flutter pub get" / "dart pub get" again, and globally activated '
        'Dart tools are removed.',
    detect: () async => (_has('dart') || _has('flutter')) && _exists(_pubCache),
    paths: () => _list(<String>[_pubCache]),
    clean: CleanCommand(<String>[if (_has('dart')) 'dart' else 'flutter', 'pub', 'cache', 'clean', '--force']),
  ),
  CacheTarget(
    id: 'dart-analysis',
    name: 'Dart analysis server cache',
    group: CacheGroup.dart,
    icon: M3EIcons.flutter_dash,
    description: 'Byte cache of the Dart analyzer used by IDEs.',
    warning: 'Close your IDE first.',
    processGuard: const <String>['analysis_server', 'language-server'],
    paths: () => _list(<String>['$_home/.dartServer/.analysis-driver']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'flutter-sdk-cache',
    name: 'Flutter SDK artifacts',
    group: CacheGroup.dart,
    icon: M3EIcons.flutter_dash,
    safety: CacheSafety.caution,
    optIn: true,
    description: 'Engine, Dart SDK and web SDK inside the Flutter SDK (bin/cache).',
    warning: 'Flutter downloads 1–2 GB again on its next run and cannot work offline until then.',
    processGuard: const <String>['flutter_tools', 'dart-sdk/bin'],
    paths: () async {
      final String? flutter = _env.which('flutter');
      if (flutter == null) return <String>[];
      final String root = File(flutter).resolveSymbolicLinksSync().replaceFirst(RegExp(r'/bin/flutter$'), '');
      return <String>['$root/bin/cache'];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'fvm',
    name: 'FVM git cache',
    group: CacheGroup.dart,
    icon: M3EIcons.flutter_dash,
    safety: CacheSafety.caution,
    description: 'Flutter repository mirror used by FVM (installed versions are kept).',
    paths: () => _list(<String>[_var('FVM_GIT_CACHE_PATH') ?? '${_var('FVM_CACHE_PATH') ?? '$_home/fvm'}/cache.git']),
    clean: const CleanDelete(),
  ),

  // ========================================================= JVM
  CacheTarget(
    id: 'gradle-caches',
    name: 'Gradle caches',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    safety: CacheSafety.caution,
    description: 'Dependencies, transforms and the build cache in ~/.gradle/caches.',
    warning: 'Gradle daemons are stopped first. Builds download dependencies again.',
    processGuard: _ideGuard,
    paths: () async => <String>['$_gradleHome/caches'],
    clean: _gradleDelete('Stop all Gradle/Kotlin daemons, then delete ~/.gradle/caches'),
  ),
  CacheTarget(
    id: 'gradle-wrapper',
    name: 'Gradle wrapper distributions',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    description: 'Gradle versions downloaded by ./gradlew (~100–200 MB each).',
    processGuard: _ideGuard,
    paths: () async => <String>['$_gradleHome/wrapper/dists'],
    clean: _gradleDelete('Stop all Gradle daemons, then delete ~/.gradle/wrapper/dists'),
  ),
  CacheTarget(
    id: 'gradle-temp',
    name: 'Gradle logs & temp files',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    description: 'Daemon logs, native libraries and temporary files.',
    paths: () async => <String>[
      for (final String d in <String>['daemon', 'native', '.tmp', 'build-scan-data', 'kotlin-profile'])
        '$_gradleHome/$d',
    ],
    clean: _gradleDelete('Stop all Gradle daemons, then delete daemon/, native/ and temp folders'),
  ),
  CacheTarget(
    id: 'gradle-jdks',
    name: 'Gradle JDK toolchains',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    safety: CacheSafety.caution,
    description: 'JDKs downloaded automatically by Gradle toolchains.',
    warning: 'Builds that need these JDKs fail offline until they are downloaded again.',
    paths: () async => <String>['$_gradleHome/jdks'],
    clean: _gradleDelete('Stop all Gradle daemons, then delete ~/.gradle/jdks'),
  ),
  CacheTarget(
    id: 'maven',
    name: 'Maven local repository',
    group: CacheGroup.jvm,
    icon: M3EIcons.coffee_outlined,
    safety: CacheSafety.caution,
    description: 'Artifacts downloaded by Maven (~/.m2/repository).',
    warning: 'Artifacts you installed locally with "mvn install" cannot be downloaded again.',
    paths: () async {
      final String? settings = File('$_home/.m2/settings.xml').existsSync()
          ? File('$_home/.m2/settings.xml').readAsStringSync()
          : null;
      final RegExpMatch? m = settings == null
          ? null
          : RegExp(r'<localRepository>\s*([^<]+?)\s*</localRepository>')
                .firstMatch(settings.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ''));
      final String repo = (m?.group(1) ?? '$_home/.m2/repository').replaceAll(r'${user.home}', _home);
      return <String>[repo];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'maven-wrapper',
    name: 'Maven wrapper distributions',
    group: CacheGroup.jvm,
    icon: M3EIcons.coffee_outlined,
    description: 'Maven versions downloaded by ./mvnw.',
    paths: () => _list(<String>['$_home/.m2/wrapper/dists']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'coursier',
    name: 'Coursier / sbt / Ivy caches',
    group: CacheGroup.jvm,
    icon: M3EIcons.coffee_outlined,
    description: 'Scala dependency caches (local publishes are kept).',
    paths: () =>
        _list(<String>[_var('COURSIER_CACHE') ?? '$_cache/coursier/v1', '$_home/.ivy2/cache', '$_home/.sbt/boot']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'android-cache',
    name: 'Android SDK caches',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    description: 'SDK manager metadata and the legacy build cache (keystores and emulators are kept).',
    paths: () async {
      final String root = _var('ANDROID_USER_HOME') ?? '$_home/.android';
      return <String>['$root/cache', '$root/build-cache'];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'android-studio',
    name: 'Android Studio caches',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    description: 'IDE system caches and logs (like "Invalidate Caches").',
    warning: 'Close Android Studio first. Indexes are rebuilt on next start.',
    processGuard: const <String>['android-studio'],
    paths: () async => _glob('$_cache/Google', (String n) => n.startsWith('AndroidStudio')),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'konan',
    name: 'Kotlin/Native toolchains',
    group: CacheGroup.jvm,
    icon: M3EIcons.android,
    safety: CacheSafety.caution,
    description: 'Kotlin/Native compilers and dependencies (~/.konan).',
    paths: () => _list(<String>[_var('KONAN_DATA_DIR') ?? '$_home/.konan', '$_home/.kotlin/daemon']),
    clean: const CleanDelete(),
  ),

  // ======================================================= Python
  CacheTarget(
    id: 'pip',
    name: 'pip cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Downloaded wheels and HTTP responses.',
    paths: () async => <String>[
      (await _out('python3', <String>['-m', 'pip', 'cache', 'dir'])) ?? (_var('PIP_CACHE_DIR') ?? '$_cache/pip'),
    ],
    clean: const CleanCommand(<String>['python3', '-m', 'pip', 'cache', 'purge'], fallbackToDelete: true),
  ),
  CacheTarget(
    id: 'pipx',
    name: 'pipx run cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Temporary environments created by "pipx run".',
    paths: () async => <String>[
      (await _out('pipx', <String>['environment', '--value', 'PIPX_VENV_CACHEDIR'])) ?? '$_cache/pipx',
    ],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'uv',
    name: 'uv cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Packages and builds cached by uv. Existing environments keep working.',
    sharedStorage: true,
    detect: () async => _has('uv'),
    paths: () async => <String>[
      (await _out('uv', <String>['cache', 'dir'])) ?? (_var('UV_CACHE_DIR') ?? '$_cache/uv'),
    ],
    clean: const CleanCommand(<String>['uv', 'cache', 'clean']),
  ),
  CacheTarget(
    id: 'poetry',
    name: 'Poetry cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Repository metadata and downloaded artifacts (project virtualenvs are kept).',
    detect: () async => _has('poetry'),
    paths: () async {
      final String dir = (await _out('poetry', <String>['config', 'cache-dir'])) ?? '$_cache/pypoetry';
      return <String>['$dir/cache', '$dir/artifacts'];
    },
    clean: CleanCustom('poetry cache clear <each> --all -n, then delete artifacts/', (
      List<String> paths,
      void Function(String) log,
    ) async {
      final CommandResult listed = await CommandRunner.run('poetry', <String>[
        'cache',
        'list',
      ], workingDirectory: _home);
      for (final String name
          in listed.stdout.split('\n').map((String s) => s.trim()).where((String s) => s.isNotEmpty)) {
        log('\$ poetry cache clear $name --all -n');
        await CommandRunner.run(
          'poetry',
          <String>['cache', 'clear', name, '--all', '-n'],
          workingDirectory: _home,
          onLine: log,
        );
      }
      return CacheCleaner.deletePaths(paths.where((String p) => p.endsWith('/artifacts')).toList(), log);
    }),
  ),
  CacheTarget(
    id: 'pdm',
    name: 'PDM cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Unreferenced wheels, metadata and packages.',
    detect: () async => _has('pdm'),
    paths: () async => <String>[
      (await _out('pdm', <String>['config', 'cache_dir'])) ?? '$_cache/pdm',
    ],
    clean: const CleanCommand(<String>['pdm', 'cache', 'clear']),
  ),
  CacheTarget(
    id: 'conda',
    name: 'Conda package cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Unused packages, tarballs and index cache (conda clean --all).',
    detect: () async => _has('conda') || _has('mamba') || _has('micromamba'),
    paths: () async {
      if (!_has('conda')) return <String>[];
      final String? json = await CommandRunner.output('conda', <String>[
        'info',
        '--json',
      ], timeout: const Duration(seconds: 60));
      try {
        final Object? d = json == null ? null : jsonDecode(json);
        if (d is Map && d['pkgs_dirs'] is List) {
          return (d['pkgs_dirs'] as List<dynamic>).map((dynamic e) => e.toString()).toList();
        }
      } on FormatException {
        // ignore
      }
      return <String>[];
    },
    clean: CleanCommand(<String>[
      if (_has('conda')) 'conda' else if (_has('mamba')) 'mamba' else 'micromamba',
      'clean',
      '--all',
      '--yes',
    ]),
  ),
  CacheTarget(
    id: 'pyenv',
    name: 'pyenv downloads',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Python source archives kept by pyenv.',
    paths: () async => <String>[
      '${(await _out('pyenv', <String>['root'])) ?? (_var('PYENV_ROOT') ?? '$_home/.pyenv')}/cache',
    ],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'hatch',
    name: 'Hatch cache',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Cache of the Hatch project manager.',
    paths: () => _list(<String>[_var('HATCH_CACHE_DIR') ?? '$_cache/hatch']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'pre-commit',
    name: 'pre-commit hook environments',
    group: CacheGroup.python,
    icon: M3EIcons.data_object,
    description: 'Hook repositories and environments.',
    paths: () => _list(<String>[_var('PRE_COMMIT_HOME') ?? '$_cache/pre-commit']),
    clean: _has('pre-commit') ? const CleanCommand(<String>['pre-commit', 'clean']) : const CleanDelete(),
  ),
  CacheTarget(
    id: 'huggingface',
    name: 'Hugging Face models (unused)',
    group: CacheGroup.python,
    icon: M3EIcons.smart_toy_outlined,
    safety: CacheSafety.caution,
    optIn: true,
    description: 'Removes unreferenced model revisions and partial downloads (hf cache prune).',
    warning: 'Models can be many GB to download again.',
    detect: () async => _has('hf'),
    paths: () => _list(<String>[_var('HF_HUB_CACHE') ?? '${_var('HF_HOME') ?? '$_cache/huggingface'}/hub']),
    clean: const CleanCommand(<String>['hf', 'cache', 'prune', '--yes']),
  ),

  // ========================================================= Rust
  CacheTarget(
    id: 'cargo',
    name: 'Cargo registry & git cache',
    group: CacheGroup.rust,
    icon: M3EIcons.build_outlined,
    description: 'Downloaded crates and git checkouts (installed binaries are kept).',
    processGuard: const <String>['/cargo ', 'rustc '],
    paths: () async => <String>[
      for (final String d in <String>['registry/cache', 'registry/src', 'registry/index', 'git/db', 'git/checkouts'])
        '$_cargoHome/$d',
    ],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'rustup',
    name: 'rustup downloads',
    group: CacheGroup.rust,
    icon: M3EIcons.build_outlined,
    description: 'Leftover rustup downloads and temp files (toolchains are kept).',
    paths: () async {
      final String root = _var('RUSTUP_HOME') ?? '$_home/.rustup';
      return <String>['$root/downloads', '$root/tmp'];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'sccache',
    name: 'sccache',
    group: CacheGroup.rust,
    icon: M3EIcons.build_outlined,
    description: 'Compiler output cache.',
    paths: () => _list(<String>[_var('SCCACHE_DIR') ?? '$_cache/sccache']),
    clean: CleanCustom('sccache --stop-server, then delete the cache', (
      List<String> paths,
      void Function(String) log,
    ) async {
      if (_has('sccache')) await CommandRunner.run('sccache', <String>['--stop-server'], onLine: log);
      return CacheCleaner.deletePaths(paths, log);
    }),
  ),

  // =========================================================== Go
  CacheTarget(
    id: 'go-build',
    name: 'Go build cache',
    group: CacheGroup.go,
    icon: M3EIcons.speed,
    description: 'Compiled packages and test results (go clean -cache).',
    detect: () async => _has('go'),
    paths: () => _goPaths('GOCACHE'),
    clean: const CleanCommand(
      <String>['go', 'clean', '-cache', '-testcache'],
      environment: <String, String>{'GOTOOLCHAIN': 'local'},
    ),
  ),
  CacheTarget(
    id: 'go-mod',
    name: 'Go module cache',
    group: CacheGroup.go,
    icon: M3EIcons.speed,
    safety: CacheSafety.caution,
    description: 'Downloaded modules and toolchains (go clean -modcache).',
    warning: 'Projects download their modules again on the next build.',
    detect: () async => _has('go'),
    paths: () => _goPaths('GOMODCACHE'),
    clean: const CleanCommand(
      <String>['go', 'clean', '-modcache'],
      environment: <String, String>{'GOTOOLCHAIN': 'local'},
    ),
  ),

  // ======================================================== Other
  CacheTarget(
    id: 'gem',
    name: 'RubyGems & Bundler caches',
    group: CacheGroup.other,
    icon: M3EIcons.diamond_outlined,
    description: 'Gem spec cache and Bundler download cache.',
    paths: () =>
        _list(<String>['$_cache/gem', '$_home/.gem/specs', _var('BUNDLE_USER_CACHE') ?? '$_home/.bundle/cache']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'composer',
    name: 'Composer cache',
    group: CacheGroup.other,
    icon: M3EIcons.php,
    description: 'Downloaded PHP packages.',
    detect: () async => _has('composer'),
    paths: () async => <String>[
      (await _out('composer', <String>['config', '--global', 'cache-dir'])) ?? '$_cache/composer',
    ],
    clean: const CleanCommand(<String>['composer', 'clear-cache', '--no-interaction']),
  ),
  CacheTarget(
    id: 'nuget',
    name: 'NuGet caches (.NET)',
    group: CacheGroup.other,
    icon: M3EIcons.developer_board,
    safety: CacheSafety.caution,
    description: 'Global packages, HTTP and temp caches (dotnet nuget locals all --clear).',
    warning: 'Every .NET project restores its packages again. Close IDEs first.',
    detect: () async => _has('dotnet'),
    paths: () => _list(<String>[
      _var('NUGET_PACKAGES') ?? '$_home/.nuget/packages',
      _var('NUGET_HTTP_CACHE_PATH') ?? '$_data/NuGet/v3-cache',
      '$_data/NuGet/plugins-cache',
    ]),
    clean: const CleanCommand(<String>['dotnet', 'nuget', 'locals', 'all', '--clear']),
  ),
  CacheTarget(
    id: 'cabal',
    name: 'Cabal download cache',
    group: CacheGroup.other,
    icon: M3EIcons.functions,
    description: 'Haskell package downloads (the package store is kept).',
    paths: () => _list(<String>['$_cache/cabal', '$_home/.cabal/packages']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'ghcup',
    name: 'GHCup cache',
    group: CacheGroup.other,
    icon: M3EIcons.functions,
    description: 'Downloads cached by GHCup.',
    detect: () async => _has('ghcup'),
    paths: () => _list(<String>['$_home/.ghcup/cache']),
    clean: const CleanCommand(<String>['ghcup', 'gc', '--cache']),
  ),
  CacheTarget(
    id: 'opam',
    name: 'opam caches',
    group: CacheGroup.other,
    icon: M3EIcons.functions,
    description: 'Logs, download cache and switch leftovers (opam clean).',
    detect: () async => _has('opam'),
    paths: () => _list(<String>['${_var('OPAMROOT') ?? '$_home/.opam'}/download-cache']),
    clean: const CleanCommand(<String>['opam', 'clean']),
  ),
  CacheTarget(
    id: 'julia',
    name: 'Julia unused packages',
    group: CacheGroup.other,
    icon: M3EIcons.functions,
    description: 'Package versions and artifacts unused for a week (Pkg.gc()).',
    detect: () async => _has('julia'),
    paths: () => _list(<String>['${(_var('JULIA_DEPOT_PATH') ?? '$_home/.julia').split(':').first}/compiled']),
    clean: const CleanCommand(<String>['julia', '--startup-file=no', '-e', 'using Pkg; Pkg.gc()']),
  ),
  CacheTarget(
    id: 'zig',
    name: 'Zig global cache',
    group: CacheGroup.other,
    icon: M3EIcons.bolt_outlined,
    description: 'Build artifacts and fetched packages.',
    paths: () async {
      final String? env = _has('zig')
          ? await CommandRunner.output('zig', <String>['env'], workingDirectory: _home)
          : null;
      final RegExpMatch? m = env == null ? null : RegExp(r'global_cache_dir"?\s*[:=]\s*"([^"]+)"').firstMatch(env);
      return <String>[m?.group(1) ?? (_var('ZIG_GLOBAL_CACHE_DIR') ?? '$_cache/zig')];
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'ccache',
    name: 'ccache',
    group: CacheGroup.other,
    icon: M3EIcons.memory,
    description: 'C/C++ compiler cache (ccache -C, settings are kept).',
    detect: () async => _has('ccache'),
    paths: () async => <String>[
      (await _out('ccache', <String>['-k', 'cache_dir'])) ?? (_var('CCACHE_DIR') ?? '$_cache/ccache'),
    ],
    clean: const CleanCommand(<String>['ccache', '-C']),
  ),
  CacheTarget(
    id: 'swiftpm',
    name: 'Swift Package Manager cache',
    group: CacheGroup.other,
    icon: M3EIcons.flight_takeoff,
    description: 'Repository and manifest caches (configuration is kept).',
    paths: () => _list(<String>['$_cache/org.swift.swiftpm']),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'brew',
    name: 'Homebrew downloads',
    group: CacheGroup.other,
    icon: M3EIcons.sports_bar_outlined,
    description: 'Downloaded bottles and source archives.',
    paths: () async => <String>[
      (await _out('brew', <String>['--cache'], environment: <String, String>{'HOMEBREW_NO_AUTO_UPDATE': '1'})) ??
          (_var('HOMEBREW_CACHE') ?? '$_cache/Homebrew'),
    ],
    clean: const CleanDelete(contentsOnly: true),
  ),
  CacheTarget(
    id: 'mise',
    name: 'mise cache',
    group: CacheGroup.other,
    icon: M3EIcons.swap_vert,
    description: 'Download and metadata cache of mise (installed tools are kept).',
    detect: () async => _has('mise'),
    paths: () async => <String>[
      (await _out('mise', <String>['cache', 'path'])) ?? (_var('MISE_CACHE_DIR') ?? '$_cache/mise'),
    ],
    clean: const CleanCommand(<String>['mise', 'cache', 'clear'], fallbackToDelete: true),
  ),
  CacheTarget(
    id: 'asdf',
    name: 'asdf downloads',
    group: CacheGroup.other,
    icon: M3EIcons.swap_vert,
    description: 'Kept downloads of asdf plugins.',
    paths: () => _list(<String>['${_var('ASDF_DATA_DIR') ?? '$_home/.asdf'}/downloads']),
    clean: const CleanDelete(),
  ),

  // ======================================================= System
  CacheTarget(
    id: 'pacman',
    name: 'pacman package cache',
    group: CacheGroup.system,
    icon: M3EIcons.widgets_outlined,
    safety: CacheSafety.caution,
    description:
        'Keeps the 2 newest versions of each installed package and removes the rest '
        'plus all versions of uninstalled packages.',
    warning: 'You can downgrade only to versions that are kept.',
    detect: () async => _has('pacman') && _has('pacman-conf'),
    paths: () async {
      final String? out = await CommandRunner.output('pacman-conf', <String>['CacheDir']);
      final List<String> dirs = (out ?? '/var/cache/pacman/pkg/')
          .split('\n')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .map((String s) => s.endsWith('/') && s.length > 1 ? s.substring(0, s.length - 1) : s)
          .toList();
      return dirs;
    },
    clean: _has('paccache')
        ? const CleanCommand(<String>['sh', '-c', 'paccache -rk2 && paccache -ruk0'], root: true)
        // pacman -Sc removes packages that are no longer installed.
        : const CleanCommand(<String>['pacman', '-Sc', '--noconfirm'], root: true),
  ),
  CacheTarget(
    id: 'pacman-all',
    name: 'pacman package cache — everything',
    group: CacheGroup.system,
    icon: M3EIcons.widgets_outlined,
    safety: CacheSafety.caution,
    optIn: true,
    description: 'Deletes every cached package file (paccache -rk0).',
    warning: 'Downgrading or reinstalling offline will not be possible.',
    detect: () async => _has('paccache') && _has('pacman-conf'),
    paths: () async => <String>['/var/cache/pacman/pkg'],
    clean: const CleanCommand(<String>['paccache', '-rk0'], root: true),
  ),
  CacheTarget(
    id: 'yay',
    name: 'yay build cache',
    group: CacheGroup.system,
    icon: M3EIcons.hub_outlined,
    description: 'AUR build folders of packages that are uninstalled or outdated.',
    detect: () async => _has('yay'),
    paths: () => _list(<String>[_var('AURDEST') ?? '$_cache/yay']),
    // --aur keeps yay from calling "sudo pacman -Sc" itself.
    clean: const CleanCommand(<String>['yay', '-Sc', '--aur', '--noconfirm']),
  ),
  CacheTarget(
    id: 'paru',
    name: 'paru clone cache',
    group: CacheGroup.system,
    icon: M3EIcons.hub_outlined,
    description: 'AUR clone folders of packages that are uninstalled or outdated.',
    detect: () async => _has('paru'),
    paths: () => _list(<String>['$_cache/paru/clone']),
    clean: const CleanCommand(<String>['paru', '-Sc', '--aur', '--noconfirm']),
  ),
  CacheTarget(
    id: 'apt',
    name: 'APT package cache',
    group: CacheGroup.system,
    icon: M3EIcons.widgets_outlined,
    description: 'Downloaded .deb files (apt-get clean).',
    detect: () async => _has('apt-get') && _exists('/var/cache/apt/archives'),
    paths: () => _list(<String>['/var/cache/apt/archives']),
    clean: const CleanCommand(<String>['apt-get', 'clean'], root: true),
  ),
  CacheTarget(
    id: 'dnf',
    name: 'DNF cache',
    group: CacheGroup.system,
    icon: M3EIcons.widgets_outlined,
    description: 'Downloaded packages and metadata (dnf clean all).',
    detect: () async => _has('dnf') || _has('dnf5'),
    paths: () => _list(<String>['/var/cache/dnf', '/var/cache/libdnf5']),
    clean: CleanCommand(<String>[if (_has('dnf5')) 'dnf5' else 'dnf', 'clean', 'all'], root: true),
  ),
  CacheTarget(
    id: 'zypper',
    name: 'zypper cache',
    group: CacheGroup.system,
    icon: M3EIcons.widgets_outlined,
    description: 'Downloaded packages and metadata.',
    detect: () async => _has('zypper'),
    paths: () => _list(<String>['/var/cache/zypp']),
    clean: const CleanCommand(<String>['zypper', '--non-interactive', 'clean', '--all'], root: true),
  ),
  CacheTarget(
    id: 'flatpak-unused',
    name: 'Unused Flatpak runtimes',
    group: CacheGroup.system,
    icon: M3EIcons.layers_outlined,
    safety: CacheSafety.caution,
    description: 'Runtimes and extensions no installed app needs (your user installation).',
    warning: 'SDKs you installed by hand for flatpak-builder also count as unused.',
    detect: () async => _has('flatpak'),
    paths: () => _list(const <String>[]),
    size: (_) async => null,
    clean: const CleanCommand(<String>['flatpak', 'uninstall', '--user', '--unused', '-y', '--noninteractive']),
  ),
  CacheTarget(
    id: 'flatpak-app-cache',
    name: 'Flatpak app caches',
    group: CacheGroup.system,
    icon: M3EIcons.layers_outlined,
    description: 'Cache folders of Flatpak apps (~/.var/app/*/cache).',
    warning: 'Close Flatpak apps first.',
    paths: () async => <String>[
      for (final String app in _glob('$_home/.var/app', (_) => true))
        if (Directory('$app/cache').existsSync()) '$app/cache',
    ],
    clean: const CleanDelete(contentsOnly: true),
  ),
  CacheTarget(
    id: 'snap-disabled',
    name: 'Old snap revisions',
    group: CacheGroup.system,
    icon: M3EIcons.extension_outlined,
    safety: CacheSafety.caution,
    description: 'Disabled snap revisions kept for rollback.',
    warning: 'You will not be able to roll back those snaps.',
    detect: () async => _has('snap') && File('/run/snapd.socket').existsSync(),
    paths: () => _list(const <String>[]),
    size: (_) async => null,
    clean: CleanCustom('snap remove <name> --revision=<rev> for each disabled revision', (
      List<String> paths,
      void Function(String) log,
    ) async {
      final CommandResult listed = await CommandRunner.run('snap', <String>['list', '--all']);
      final List<String> args = <String>[];
      for (final String line in listed.stdout.split('\n').skip(1)) {
        final List<String> f = line.trim().split(RegExp(r'\s+'));
        if (f.length >= 6 && f.sublist(5).join(' ').contains('disabled')) args.addAll(<String>[f[0], f[2]]);
      }
      if (args.isEmpty) {
        log('No disabled revisions found.');
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
      return PrivilegeService.instance.run(
        <String>[
          'sh',
          '-c',
          r'while [ $# -gt 1 ]; do snap remove "$1" --revision="$2" || exit 1; shift 2; done',
          'kalanjiyam',
          ...args,
        ],
        reason: 'Removing old snap revisions requires administrator rights.',
        onLine: log,
      );
    }, root: true),
  ),
  CacheTarget(
    id: 'journal',
    name: 'System logs (journal)',
    group: CacheGroup.system,
    icon: M3EIcons.receipt_long_outlined,
    safety: CacheSafety.caution,
    description: 'Shrinks the systemd journal to 200 MB.',
    warning: 'Older log entries are deleted.',
    detect: () async => _has('journalctl'),
    paths: () => _list(<String>['/var/log/journal']),
    size: (_) async {
      final String? out = await CommandRunner.output('journalctl', <String>['--disk-usage']);
      final RegExpMatch? m = out == null ? null : RegExp(r'take up ([0-9.]+\s*[KMGT]?)').firstMatch(out);
      return m == null ? null : Fmt.parseSize(m.group(1)!.replaceAll(' ', ''));
    },
    clean: const CleanCommand(<String>['journalctl', '--rotate', '--vacuum-size=200M'], root: true),
  ),
  CacheTarget(
    id: 'coredumps',
    name: 'Crash dumps',
    group: CacheGroup.system,
    icon: M3EIcons.bug_report_outlined,
    description: 'Core dumps of crashed programs kept by systemd-coredump.',
    paths: () => _list(<String>['/var/lib/systemd/coredump']),
    clean: const CleanCommand(<String>[
      'find',
      '/var/lib/systemd/coredump',
      '-mindepth',
      '1',
      '-maxdepth',
      '1',
      '-type',
      'f',
      '-name',
      'core.*',
      '-delete',
    ], root: true),
  ),
  CacheTarget(
    id: 'thumbnails',
    name: 'Thumbnail cache',
    group: CacheGroup.system,
    icon: M3EIcons.photo_library_outlined,
    description: 'Image and video previews generated by file managers.',
    paths: () => _list(<String>['$_cache/thumbnails', '$_home/.thumbnails']),
    clean: const CleanDelete(contentsOnly: true),
  ),
  CacheTarget(
    id: 'trash',
    name: 'Trash',
    group: CacheGroup.system,
    icon: M3EIcons.delete_outline,
    safety: CacheSafety.caution,
    optIn: true,
    description: 'Empties the Trash (gio trash --empty).',
    warning: 'Files in the Trash are deleted permanently.',
    detect: () async => _has('gio'),
    paths: () => _list(<String>['$_data/Trash']),
    clean: const CleanCommand(<String>['gio', 'trash', '--empty']),
  ),
  CacheTarget(
    id: 'docker-builder',
    name: 'Docker build cache',
    group: CacheGroup.system,
    icon: M3EIcons.directions_boat_outlined,
    safety: CacheSafety.risky,
    optIn: true,
    description: 'Docker BuildKit cache only (docker builder prune -f).',
    warning: 'Images, containers and volumes are not touched, but builds start from scratch.',
    detect: () async => _has('docker') && File('/var/run/docker.sock').existsSync(),
    paths: () => _list(const <String>[]),
    size: (_) async => null,
    clean: const CleanCommand(<String>['docker', 'builder', 'prune', '-f']),
  ),
  CacheTarget(
    id: 'docker-system',
    name: 'Docker unused data',
    group: CacheGroup.system,
    icon: M3EIcons.directions_boat_outlined,
    safety: CacheSafety.risky,
    optIn: true,
    description: 'Stopped containers, unused networks, dangling images and build cache (docker system prune -f).',
    warning: 'Stopped containers are deleted. Volumes are kept.',
    detect: () async => _has('docker') && File('/var/run/docker.sock').existsSync(),
    paths: () => _list(const <String>[]),
    size: (_) async => null,
    clean: const CleanCommand(<String>['docker', 'system', 'prune', '-f']),
  ),
  CacheTarget(
    id: 'podman',
    name: 'Podman unused data',
    group: CacheGroup.system,
    icon: M3EIcons.directions_boat_outlined,
    safety: CacheSafety.risky,
    optIn: true,
    description: 'Stopped containers, unused pods/networks and dangling images (podman system prune -f).',
    warning: 'Stopped containers are deleted. Volumes are kept.',
    detect: () async => _has('podman'),
    paths: () => _list(const <String>[]),
    size: (_) async => null,
    clean: const CleanCommand(<String>['podman', 'system', 'prune', '-f']),
  ),

  // ========================================================= Apps
  CacheTarget(
    id: 'vscode',
    name: 'VS Code caches',
    group: CacheGroup.apps,
    icon: M3EIcons.code,
    description: 'Code/GPU caches and logs of VS Code, VSCodium and Cursor (settings and backups are kept).',
    warning: 'Close the editor first.',
    processGuard: const <String>['/code ', '/codium', '/cursor', 'code-oss'],
    paths: () async => <String>[
      for (final String app in <String>['Code', 'Code - Insiders', 'VSCodium', 'Cursor'])
        for (final String sub in <String>[
          'Cache',
          'CachedData',
          'CachedExtensionVSIXs',
          'Code Cache',
          'GPUCache',
          'DawnGraphiteCache',
          'DawnWebGPUCache',
          'Service Worker/CacheStorage',
          'Service Worker/ScriptCache',
          'logs',
        ])
          '${_env.xdgConfigHome}/$app/$sub',
    ],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'jetbrains',
    name: 'JetBrains IDE caches',
    group: CacheGroup.apps,
    icon: M3EIcons.code,
    description: 'Indexes and logs of IntelliJ-based IDEs (settings and plugins are kept).',
    warning: 'Close JetBrains IDEs first. Projects are re-indexed.',
    processGuard: const <String>['com.intellij', 'jetbrains'],
    paths: () async => _glob('$_cache/JetBrains', (_) => true),
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'chromium',
    name: 'Chromium-based browser caches',
    group: CacheGroup.apps,
    icon: M3EIcons.public,
    description: 'Web caches of Chrome, Chromium, Brave, Edge and Vivaldi (profiles are kept).',
    warning: 'Close the browser first.',
    processGuard: const <String>['chrome', 'chromium', 'brave', 'msedge', 'vivaldi'],
    paths: () async {
      final List<String> out = <String>[];
      for (final String root in <String>[
        '$_cache/google-chrome',
        '$_cache/chromium',
        '$_cache/BraveSoftware/Brave-Browser',
        '$_cache/microsoft-edge',
        '$_cache/vivaldi',
      ]) {
        for (final String profile in _glob(root, (_) => true)) {
          out
            ..add('$profile/Cache')
            ..add('$profile/Code Cache');
        }
      }
      return out;
    },
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'firefox',
    name: 'Firefox caches',
    group: CacheGroup.apps,
    icon: M3EIcons.public,
    description: 'Web cache and startup cache of Firefox profiles (profiles are kept).',
    warning: 'Close Firefox first.',
    processGuard: const <String>['firefox'],
    paths: () async => <String>[
      for (final String profile in _glob('$_cache/mozilla/firefox', (_) => true))
        for (final String sub in <String>['cache2', 'startupCache', 'thumbnails']) '$profile/$sub',
    ],
    clean: const CleanDelete(),
  ),
  CacheTarget(
    id: 'shaders',
    name: 'GPU shader caches',
    group: CacheGroup.apps,
    icon: M3EIcons.videogame_asset_outlined,
    description: 'Compiled shaders of Mesa, NVIDIA and Qt (rebuilt automatically).',
    paths: () async => <String>[
      ..._glob(_cache, (String n) => n.startsWith('mesa_shader_cache') || n.startsWith('qtshadercache')),
      '$_cache/nvidia/GLCache',
    ],
    clean: const CleanDelete(),
  ),
];
