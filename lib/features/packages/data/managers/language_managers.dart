import 'dart:convert';
import 'dart:io';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' show IconData;

import '../../../../core/system/command_runner.dart';
import '../package_managers.dart';
import '../package_models.dart';

Map<String, dynamic>? _readJson(String path) {
  try {
    final Object? decoded = jsonDecode(readText(path) ?? '');
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

List<String> _lines(String text) =>
    text.split('\n').map((String l) => l.trimRight()).where((String l) => l.trim().isNotEmpty).toList();

// ====================================================================== npm

class NpmGlobalManager extends PackageManager {
  String? _root;
  bool _writable = true;

  @override
  String get id => 'npm';
  @override
  String get label => 'npm';
  @override
  String get description => 'Global npm packages (npm install -g)';
  @override
  IconData get icon => M3EIcons.javascript;

  @override
  Future<bool> detect() async {
    if (!has('npm')) return false;
    final String? root = await CommandRunner.output('npm', <String>['root', '-g']);
    if (root == null || !Directory(root).existsSync()) return false;
    _root = root;
    return true;
  }

  /// Reads `package.json` files under `npm root -g` instead of the slower
  /// `npm ls -g --json`.
  @override
  Future<List<InstalledPackage>> list() async {
    final String root = _root ?? (await detect() ? _root! : throw StateError('npm not found'));
    _writable = await isWritable(root);
    final List<String> dirs = <String>[];
    for (final FileSystemEntity e in Directory(root).listSync(followLinks: false)) {
      final String name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (name.startsWith('.')) continue;
      if (name.startsWith('@') && e is Directory) {
        for (final FileSystemEntity s in e.listSync(followLinks: false)) {
          dirs.add(s.path);
        }
      } else {
        dirs.add(e.path);
      }
    }
    // On distros where the global prefix is /usr, some modules (npm itself,
    // node-gyp, …) belong to the system package manager.
    final Map<String, String> owners = _writable ? <String, String>{} : await systemOwners(dirs);
    return <InstalledPackage>[
      for (final String dir in dirs)
        if (_readJson('$dir/package.json') case final Map<String, dynamic> pkg)
          InstalledPackage(
            name: (pkg['name'] ?? dir.substring(dir.lastIndexOf('/') + 1)).toString(),
            version: (pkg['version'] ?? '').toString(),
            managerId: id,
            description: pkg['description']?.toString(),
            url: pkg['homepage']?.toString(),
            origin: owners[dir] == null ? null : 'System package: ${owners[dir]}',
            removeId: owners[dir] == null ? null : 'system-owned',
            details: <String, String>{'Location': tildify(dir)},
          ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) {
    if (package.removeId == 'system-owned') return null;
    return RemovalPlan(
      argv: <String>['npm', 'uninstall', '-g', package.name],
      needsRoot: !_writable,
      reason: 'The global npm folder (${_root ?? ''}) is owned by root.',
    );
  }
}

// ===================================================================== pnpm

class PnpmGlobalManager extends PackageManager {
  @override
  String get id => 'pnpm';
  @override
  String get label => 'pnpm';
  @override
  String get description => 'Global pnpm packages';
  @override
  IconData get icon => M3EIcons.javascript;

  @override
  Future<bool> detect() async => has('pnpm');

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('pnpm', <String>['ls', '-g', '--depth=0', '--json'], allowNonZero: true);
    final Object? json = jsonDecode(out.trim().isEmpty ? '[]' : out);
    final List<dynamic> projects = json is List ? json : <dynamic>[json];
    final Map<String, InstalledPackage> byName = <String, InstalledPackage>{};
    for (final Object? project in projects) {
      if (project is! Map) continue;
      final Object? deps = project['dependencies'];
      if (deps is! Map) continue;
      deps.forEach((dynamic name, dynamic info) {
        byName[name.toString()] = InstalledPackage(
          name: name.toString(),
          version: info is Map ? (info['version'] ?? '').toString() : '',
          managerId: id,
          details: <String, String>{
            if (info is Map && info['path'] != null) 'Location': tildify(info['path'].toString()),
          },
        );
      });
    }
    return byName.values.toList();
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['pnpm', 'remove', '-g', package.name], needsRoot: false);
}

// ===================================================================== yarn

class YarnGlobalManager extends PackageManager {
  String? _dir;

  @override
  String get id => 'yarn';
  @override
  String get label => 'Yarn';
  @override
  String get description => 'Yarn classic global packages';
  @override
  IconData get icon => M3EIcons.javascript;

  @override
  Future<bool> detect() async {
    if (!has('yarn')) return false;
    final String? version = await CommandRunner.output('yarn', <String>['--version']);
    if (version == null || !version.startsWith('1.')) return false; // Yarn 2+ has no global installs.
    final String? dir = await CommandRunner.output('yarn', <String>['global', 'dir']);
    if (dir == null || !File('$dir/package.json').existsSync()) return false;
    _dir = dir;
    return true;
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final String dir = _dir ?? (await detect() ? _dir! : throw StateError('Yarn not found'));
    final Object? deps = _readJson('$dir/package.json')?['dependencies'];
    if (deps is! Map) return <InstalledPackage>[];
    return <InstalledPackage>[
      for (final dynamic name in deps.keys)
        InstalledPackage(
          name: name.toString(),
          version: (_readJson('$dir/node_modules/$name/package.json')?['version'] ?? deps[name]).toString(),
          managerId: id,
          description: _readJson('$dir/node_modules/$name/package.json')?['description']?.toString(),
        ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['yarn', 'global', 'remove', package.name], needsRoot: false);
}

// ====================================================================== bun

class BunGlobalManager extends PackageManager {
  @override
  String get id => 'bun';
  @override
  String get label => 'Bun';
  @override
  String get description => 'Global Bun packages (bun add -g)';
  @override
  IconData get icon => M3EIcons.bakery_dining_outlined;

  @override
  Future<bool> detect() async => has('bun');

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('bun', <String>['pm', 'ls', '-g'], allowNonZero: true);
    final RegExp entry = RegExp(r'^[├└]── (.+)@([^@]+)$');
    final List<String> lines = _lines(out);
    final String location = lines.isEmpty ? '' : lines.first.split(' node_modules').first;
    return <InstalledPackage>[
      for (final String line in lines.skip(1))
        if (entry.firstMatch(line.trim()) case final RegExpMatch m)
          InstalledPackage(
            name: m.group(1)!,
            version: m.group(2)!,
            managerId: id,
            details: <String, String>{if (location.isNotEmpty) 'Global folder': tildify(location)},
          ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['bun', 'remove', '-g', package.name], needsRoot: false);
}

// ===================================================================== deno

class DenoManager extends PackageManager {
  String get _bin {
    final String root = env.environment['DENO_INSTALL_ROOT'] ?? '${env.home}/.deno';
    return root.endsWith('/bin') ? root : '$root/bin';
  }

  @override
  String get id => 'deno';
  @override
  String get label => 'Deno';
  @override
  String get description => 'Scripts installed with deno install -g';
  @override
  IconData get icon => M3EIcons.pets_outlined;

  @override
  Future<bool> detect() async => has('deno') && nonEmptyDir(_bin);

  @override
  Future<List<InstalledPackage>> list() async {
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final FileSystemEntity e in Directory(_bin).listSync()) {
      if (e is! File) continue;
      final String name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (name.startsWith('.') || name == 'deno') continue;
      String? text;
      try {
        final RandomAccessFile f = e.openSync();
        text = utf8.decode(f.readSync(4096), allowMalformed: true);
        f.closeSync();
      } on FileSystemException {
        continue;
      }
      if (!text.contains('# generated by deno install')) continue;
      final RegExpMatch? spec = RegExp(r"""'((?:jsr|npm):[^']+|https?://[^']+)'""").firstMatch(text);
      final String specifier = spec?.group(1) ?? '';
      final RegExpMatch? ver = RegExp(r'@(\d[\w.+-]*)').firstMatch(specifier.replaceFirst(RegExp(r'^(jsr|npm):@'), ''));
      out.add(
        InstalledPackage(
          name: name,
          version: ver?.group(1) ?? '',
          managerId: id,
          origin: specifier.isEmpty ? null : specifier,
          installDate: mtimeOf(e.path),
        ),
      );
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['deno', 'uninstall', '-g', package.name], needsRoot: false);
}

// ===================================================================== pipx

class PipxManager extends PackageManager {
  @override
  String get id => 'pipx';
  @override
  String get label => 'pipx';
  @override
  String get description => 'Python applications installed with pipx';
  @override
  IconData get icon => M3EIcons.data_object;

  @override
  Future<bool> detect() async => has('pipx');

  @override
  Future<List<InstalledPackage>> list() async {
    final Object? json = jsonDecode(await runOrThrow('pipx', <String>['list', '--json']));
    final Object? venvs = json is Map ? json['venvs'] : null;
    if (venvs is! Map) return <InstalledPackage>[];
    final List<InstalledPackage> out = <InstalledPackage>[];
    venvs.forEach((dynamic venv, dynamic data) {
      final Object? meta = data is Map ? data['metadata'] : null;
      final Object? main = meta is Map ? meta['main_package'] : null;
      if (main is! Map) return;
      final Object? apps = main['apps'];
      out.add(
        InstalledPackage(
          name: (main['package'] ?? venv).toString(),
          version: (main['package_version'] ?? '').toString(),
          managerId: id,
          origin: main['package_or_url']?.toString(),
          removeId: venv.toString(),
          details: <String, String>{
            if (apps is List && apps.isNotEmpty) 'Commands': apps.join(', '),
            if (meta is Map && meta['python_version'] != null) 'Python': meta['python_version'].toString(),
          },
        ),
      );
    });
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['pipx', 'uninstall', package.removeId ?? package.name], needsRoot: false);
}

// ======================================================================= uv

class UvToolManager extends PackageManager {
  @override
  String get id => 'uv';
  @override
  String get label => 'uv tool';
  @override
  String get description => 'Python tools installed with uv tool install';
  @override
  IconData get icon => M3EIcons.data_object;

  @override
  Future<bool> detect() async => has('uv');

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('uv', <String>['tool', 'list', '--show-version-specifiers', '--show-python']);
    final List<InstalledPackage> result = <InstalledPackage>[];
    final RegExp tool = RegExp(r'^(\S+) v(\S+)(.*)$');
    String? name;
    String? version;
    String rest = '';
    final List<String> commands = <String>[];
    void flush() {
      if (name == null) return;
      final RegExpMatch? python = RegExp(r'\[(CPython|PyPy)[^\]]*\]').firstMatch(rest);
      final RegExpMatch? spec = RegExp(r'\[required:\s+([^\]]+)\]').firstMatch(rest);
      result.add(
        InstalledPackage(
          name: name,
          version: version ?? '',
          managerId: id,
          origin: spec?.group(1)?.trim(),
          details: <String, String>{
            if (commands.isNotEmpty) 'Commands': commands.join(', '),
            if (python != null) 'Python': python.group(0)!.replaceAll(RegExp(r'[\[\]]'), ''),
          },
        ),
      );
      commands.clear();
    }

    for (final String line in _lines(out)) {
      if (line.startsWith('- ')) {
        commands.add(line.substring(2).split(' (').first.trim());
        continue;
      }
      final RegExpMatch? m = tool.firstMatch(line.trim());
      if (m == null) continue;
      flush();
      name = m.group(1);
      version = m.group(2);
      rest = m.group(3) ?? '';
    }
    flush();
    return result;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['uv', 'tool', 'uninstall', package.name], needsRoot: false);
}

// ================================================================ pip --user

class PipUserManager extends PackageManager {
  @override
  String get id => 'pip';
  @override
  String get label => 'pip (user)';
  @override
  String get description => 'Python packages in your user site-packages (pip install --user)';
  @override
  IconData get icon => M3EIcons.data_object;

  @override
  Future<bool> detect() async {
    if (!has('python3')) return false;
    final String? site = await CommandRunner.output('python3', <String>['-m', 'site', '--user-site']);
    return site != null && nonEmptyDir(site);
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final CommandResult r = await run('python3', <String>[
      '-m',
      'pip',
      'list',
      '--user',
      '--not-required',
      '--format=json',
    ]);
    if (!r.ok) throw StateError('pip is not available for python3: ${r.errorSummary}');
    final Object? json = jsonDecode(r.stdout.trim().isEmpty ? '[]' : r.stdout);
    return <InstalledPackage>[
      if (json is List)
        for (final Object? p in json)
          if (p is Map)
            InstalledPackage(
              name: (p['name'] ?? '').toString(),
              version: (p['version'] ?? '').toString(),
              managerId: id,
            ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) {
    // PEP 668 ("externally managed") distros need the explicit override even
    // for --user site-packages.
    final bool externallyManaged = Directory('/usr/lib').listSync().whereType<Directory>().any(
      (Directory d) => RegExp(r'/python3\.\d+$').hasMatch(d.path) && File('${d.path}/EXTERNALLY-MANAGED').existsSync(),
    );
    return RemovalPlan(
      argv: <String>[
        'python3',
        '-m',
        'pip',
        'uninstall',
        '-y',
        if (externallyManaged) '--break-system-packages',
        package.name,
      ],
      needsRoot: false,
    );
  }
}

// ==================================================================== cargo

class CargoManager extends PackageManager {
  String get _home => env.environment['CARGO_HOME'] ?? '${env.home}/.cargo';

  @override
  String get id => 'cargo';
  @override
  String get label => 'Cargo';
  @override
  String get description => 'Rust binaries installed with cargo install';
  @override
  IconData get icon => M3EIcons.build_outlined;

  @override
  Future<bool> detect() async =>
      has('cargo') && (nonEmptyFile('$_home/.crates2.json') || nonEmptyFile('$_home/.crates.toml'));

  @override
  Future<List<InstalledPackage>> list() async {
    final Object? installs = _readJson('$_home/.crates2.json')?['installs'];
    final List<InstalledPackage> out = <InstalledPackage>[];
    if (installs is Map) {
      installs.forEach((dynamic key, dynamic value) {
        final RegExpMatch? m = RegExp(r'^(\S+) (\S+) \((.+)\)$').firstMatch(key.toString());
        if (m == null) return;
        final Object? bins = value is Map ? value['bins'] : null;
        out.add(
          InstalledPackage(
            name: m.group(1)!,
            version: m.group(2)!,
            managerId: id,
            origin: m.group(3)!.startsWith('registry+') ? 'crates.io' : m.group(3),
            details: <String, String>{if (bins is List && bins.isNotEmpty) 'Binaries': bins.join(', ')},
          ),
        );
      });
      return out;
    }
    // Fallback: `cargo install --list`.
    final String text = await runOrThrow('cargo', <String>['install', '--list']);
    for (final String line in _lines(text)) {
      final RegExpMatch? m = RegExp(r'^(\S+) v(\S+?)(?: \((.+)\))?:$').firstMatch(line);
      if (m != null) {
        out.add(InstalledPackage(name: m.group(1)!, version: m.group(2)!, managerId: id, origin: m.group(3)));
      }
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['cargo', 'uninstall', package.name], needsRoot: false);
}

// ======================================================================= go

class GoBinManager extends PackageManager {
  String? _dir;

  @override
  String get id => 'go';
  @override
  String get label => 'Go';
  @override
  String get description => 'Binaries installed with go install';
  @override
  IconData get icon => M3EIcons.speed;

  @override
  Future<bool> detect() async {
    if (!has('go')) return false;
    final String? out = await CommandRunner.output('go', <String>['env', 'GOBIN', 'GOPATH']);
    if (out == null) return false;
    final List<String> lines = out.split('\n');
    final String gobin = lines.isNotEmpty ? lines[0].trim() : '';
    final String gopath = lines.length > 1 ? lines[1].split(':').first.trim() : '';
    final String dir = gobin.isNotEmpty ? gobin : (gopath.isNotEmpty ? '$gopath/bin' : '${env.home}/go/bin');
    _dir = dir;
    return nonEmptyDir(dir);
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final String dir = _dir ?? (await detect() ? _dir! : throw StateError('Go not found'));
    final String out = await runOrThrow('go', <String>['version', '-m', dir], allowNonZero: true);
    final List<InstalledPackage> result = <InstalledPackage>[];
    String? binary;
    String? module;
    String? version;
    void flush() {
      if (binary == null) return;
      result.add(
        InstalledPackage(
          name: binary.substring(binary.lastIndexOf('/') + 1),
          version: version ?? '',
          managerId: id,
          origin: module,
          removeId: binary,
          installDate: mtimeOf(binary),
        ),
      );
      module = null;
      version = null;
    }

    for (final String line in out.split('\n')) {
      final RegExpMatch? head = RegExp(r'^(/.+): go[\d.]+').firstMatch(line);
      if (head != null) {
        flush();
        binary = head.group(1);
        continue;
      }
      final List<String> f = line.trim().split('\t');
      if (f.length >= 2 && f[0] == 'path') module = f[1];
      if (f.length >= 3 && f[0] == 'mod') version = f[2];
    }
    flush();
    return result;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => package.removeId == null
      ? null
      : RemovalPlan(argv: <String>['rm', '-f', '--', package.removeId!], needsRoot: false);
}

// ====================================================================== gem

class GemManager extends PackageManager {
  @override
  String get id => 'gem';
  @override
  String get label => 'RubyGems';
  @override
  String get description => 'Ruby gems (yours; system gems shown as built-in)';
  @override
  IconData get icon => M3EIcons.diamond_outlined;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('ruby') && has('gem');

  @override
  Future<List<InstalledPackage>> list() async {
    const String script =
        r'Gem::Specification.each{|s| puts [s.name, s.version, (s.default_gem? ? 1 : 0), s.base_dir, s.summary.to_s.gsub(/\s+/, " ")].join("\t")}';
    final String out = await runOrThrow('ruby', <String>['-e', script]);
    final String home = env.home;
    final List<InstalledPackage> result = <InstalledPackage>[];
    for (final String line in _lines(out)) {
      final List<String> f = line.split('\t');
      if (f.length < 4) continue;
      final bool isDefault = f[2] == '1';
      final bool userGem = f[3].startsWith('$home/');
      result.add(
        InstalledPackage(
          name: f[0],
          version: f[1],
          managerId: id,
          description: f.length > 4 ? f[4] : null,
          explicit: userGem && !isDefault,
          origin: isDefault ? 'Bundled with Ruby' : (userGem ? 'User gem' : 'System gem'),
          removeId: (userGem && !isDefault) ? f[3] : null,
          details: <String, String>{'Location': tildify(f[3])},
        ),
      );
    }
    return result;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) {
    // Only gems in your home; system gems belong to the system package manager.
    if (package.removeId == null) return null;
    return RemovalPlan(
      argv: <String>[
        'gem',
        'uninstall',
        '--abort-on-dependent',
        '-x',
        '-v',
        package.version,
        '-i',
        package.removeId!,
        package.name,
      ],
      needsRoot: false,
    );
  }
}

// ================================================================= composer

class ComposerManager extends PackageManager {
  @override
  String get id => 'composer';
  @override
  String get label => 'Composer';
  @override
  String get description => 'Global Composer (PHP) packages';
  @override
  IconData get icon => M3EIcons.php;

  @override
  Future<bool> detect() async => has('composer');

  @override
  Future<List<InstalledPackage>> list() async {
    final CommandResult r = await run('composer', <String>[
      'global',
      'show',
      '-D',
      '--format=json',
      '--no-interaction',
    ]);
    if (!r.ok && r.stdout.trim().isEmpty) {
      // No global composer.json yet means nothing is installed.
      return <InstalledPackage>[];
    }
    final int start = r.stdout.indexOf('{');
    final Object? json = start < 0 ? null : jsonDecode(r.stdout.substring(start));
    final Object? installed = json is Map ? json['installed'] : null;
    return <InstalledPackage>[
      if (installed is List)
        for (final Object? p in installed)
          if (p is Map)
            InstalledPackage(
              name: (p['name'] ?? '').toString(),
              version: (p['version'] ?? '').toString(),
              managerId: id,
              description: p['description']?.toString(),
            ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['composer', 'global', 'remove', '-n', package.name], needsRoot: false);
}

// ================================================================= dart pub

class DartPubManager extends PackageManager {
  @override
  String get id => 'dart';
  @override
  String get label => 'Dart pub';
  @override
  String get description => 'Packages activated with dart pub global activate';
  @override
  IconData get icon => M3EIcons.flutter_dash;

  @override
  Future<bool> detect() async {
    if (!has('dart')) return false;
    final String cache = env.environment['PUB_CACHE'] ?? '${env.home}/.pub-cache';
    return nonEmptyDir('$cache/global_packages');
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('dart', <String>['pub', 'global', 'list']);
    final RegExp re = RegExp(r'^(\S+) (\S+)(?: (?:at path|from Git repository) "(.*)")?');
    return <InstalledPackage>[
      for (final String line in _lines(out))
        if (re.firstMatch(line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '')) case final RegExpMatch m)
          InstalledPackage(name: m.group(1)!, version: m.group(2)!, managerId: id, origin: m.group(3)),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['dart', 'pub', 'global', 'deactivate', package.name], needsRoot: false);
}

// ================================================================== dotnet

class DotnetToolManager extends PackageManager {
  @override
  String get id => 'dotnet';
  @override
  String get label => '.NET tools';
  @override
  String get description => 'Global .NET tools (dotnet tool install -g)';
  @override
  IconData get icon => M3EIcons.developer_board;

  @override
  Future<bool> detect() async => has('dotnet') && nonEmptyDir('${env.home}/.dotnet/tools');

  @override
  Future<List<InstalledPackage>> list() async {
    final CommandResult json = await run('dotnet', <String>['tool', 'list', '-g', '--format', 'json']);
    if (json.ok && json.stdout.trim().startsWith('{')) {
      final Object? data = (jsonDecode(json.stdout) as Map<String, dynamic>)['data'];
      return <InstalledPackage>[
        if (data is List)
          for (final Object? t in data)
            if (t is Map)
              InstalledPackage(
                name: (t['packageId'] ?? '').toString(),
                version: (t['version'] ?? '').toString(),
                managerId: id,
                details: <String, String>{
                  if (t['commands'] is List) 'Commands': (t['commands'] as List<dynamic>).join(', '),
                },
              ),
      ];
    }
    // Older SDKs: parse the table (Package Id / Version / Commands).
    final String text = await runOrThrow('dotnet', <String>['tool', 'list', '-g']);
    final List<String> lines = _lines(text);
    return <InstalledPackage>[
      for (final String line in lines.skip(2))
        if (line.trim().split(RegExp(r'\s+')) case final List<String> f when f.length >= 2)
          InstalledPackage(name: f[0], version: f[1], managerId: id),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['dotnet', 'tool', 'uninstall', '-g', package.name], needsRoot: false);
}

// ============================================================ version managers

class MiseManager extends PackageManager {
  @override
  String get id => 'mise';
  @override
  String get label => 'mise';
  @override
  String get description => 'Tool versions installed with mise';
  @override
  IconData get icon => M3EIcons.swap_vert;

  @override
  Future<bool> detect() async => has('mise');

  @override
  Future<List<InstalledPackage>> list() async {
    final Object? json = jsonDecode(await runOrThrow('mise', <String>['ls', '--installed', '--json']));
    final List<InstalledPackage> out = <InstalledPackage>[];
    if (json is Map) {
      json.forEach((dynamic tool, dynamic versions) {
        if (versions is! List) return;
        for (final Object? v in versions) {
          if (v is! Map) continue;
          out.add(
            InstalledPackage(
              name: tool.toString(),
              version: (v['version'] ?? '').toString(),
              managerId: id,
              details: <String, String>{
                if (v['install_path'] != null) 'Location': tildify(v['install_path'].toString()),
                if (v['active'] == true) 'Active': 'yes',
              },
            ),
          );
        }
      });
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['mise', 'uninstall', '${package.name}@${package.version}'], needsRoot: false);
}

class AsdfManager extends PackageManager {
  String get _dir => env.environment['ASDF_DATA_DIR'] ?? '${env.home}/.asdf';

  @override
  String get id => 'asdf';
  @override
  String get label => 'asdf';
  @override
  String get description => 'Tool versions installed with asdf';
  @override
  IconData get icon => M3EIcons.swap_vert;

  @override
  Future<bool> detect() async => has('asdf') && nonEmptyDir('$_dir/installs');

  @override
  Future<List<InstalledPackage>> list() async {
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final FileSystemEntity plugin in Directory('$_dir/installs').listSync()) {
      if (plugin is! Directory) continue;
      for (final FileSystemEntity v in plugin.listSync()) {
        if (v is! Directory) continue;
        out.add(
          InstalledPackage(
            name: plugin.path.split('/').last,
            version: v.path.split('/').last,
            managerId: id,
            installDate: mtimeOf(v.path),
          ),
        );
      }
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['asdf', 'uninstall', package.name, package.version], needsRoot: false);
}

class SdkmanManager extends PackageManager {
  String get _dir => env.environment['SDKMAN_DIR'] ?? '${env.home}/.sdkman';

  @override
  String get id => 'sdkman';
  @override
  String get label => 'SDKMAN!';
  @override
  String get description => 'JDKs and JVM tools installed with SDKMAN!';
  @override
  IconData get icon => M3EIcons.swap_vert;

  @override
  Future<bool> detect() async => nonEmptyDir('$_dir/candidates') && File('$_dir/bin/sdkman-init.sh').existsSync();

  @override
  Future<List<InstalledPackage>> list() async {
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final FileSystemEntity candidate in Directory('$_dir/candidates').listSync()) {
      if (candidate is! Directory) continue;
      String? current;
      try {
        current = Link('${candidate.path}/current').targetSync().split('/').last;
      } on FileSystemException {
        current = null;
      }
      for (final FileSystemEntity v in candidate.listSync(followLinks: false)) {
        if (v is! Directory) continue;
        final String version = v.path.split('/').last;
        out.add(
          InstalledPackage(
            name: candidate.path.split('/').last,
            version: version,
            managerId: id,
            installDate: mtimeOf(v.path),
            details: <String, String>{if (version == current) 'Default': 'yes'},
          ),
        );
      }
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    // `sdk` is a shell function. Candidate and version are passed as
    // positional parameters, never interpolated into the script.
    argv: <String>[
      'bash',
      '-c',
      r'export sdkman_auto_answer=true; source "$1/bin/sdkman-init.sh" && sdk uninstall "$2" "$3"',
      'kalanjiyam',
      _dir,
      package.name,
      package.version,
    ],
    needsRoot: false,
    warning: package.details['Default'] == 'yes'
        ? 'This is the default version; SDKMAN! may refuse to remove it.'
        : null,
  );
}
