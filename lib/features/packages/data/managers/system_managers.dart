import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' show IconData;

import '../../../../core/system/command_runner.dart';
import '../../../../core/utils/format.dart';
import '../package_managers.dart';
import '../package_models.dart';

// =================================================================== pacman

/// Snapshot of pacman's local database plus repository membership, shared by
/// [PacmanManager] and [ForeignPacmanManager] so the DB is read only once.
class _PacmanSnapshot {
  _PacmanSnapshot(this.packages, this.repoOf, this.foreign);

  final List<Map<String, List<String>>> packages;

  /// name → repository, from `pacman -Sl`.
  final Map<String, String> repoOf;

  /// Fallback foreign set (`pacman -Qqm`) when `pacman -Sl` is unavailable.
  final Set<String>? foreign;

  bool isForeign(String name) => foreign != null ? foreign!.contains(name) : !repoOf.containsKey(name);
}

abstract final class _PacmanDb {
  static Future<_PacmanSnapshot>? _future;
  static DateTime? _key;
  static String? _dbPath;

  static Future<String> dbPath() async {
    if (_dbPath != null) return _dbPath!;
    final String? conf = await CommandRunner.output('pacman-conf', <String>['DBPath']);
    String path = (conf == null || conf.isEmpty) ? '/var/lib/pacman/' : conf.split('\n').first.trim();
    if (!path.endsWith('/')) path = '$path/';
    return _dbPath = path;
  }

  static Future<_PacmanSnapshot> load() async {
    final String local = '${await dbPath()}local';
    DateTime? key;
    try {
      key = Directory(local).statSync().modified;
    } on FileSystemException {
      key = null;
    }
    if (_future != null && key != null && key == _key) return _future!;
    _key = key;
    final Future<_PacmanSnapshot> future = _load(local);
    _future = future;
    try {
      return await future;
    } on Object {
      _future = null;
      rethrow;
    }
  }

  static Future<_PacmanSnapshot> _load(String localDir) async {
    final Future<List<Map<String, List<String>>>> parsed = _readLocalDb(localDir);
    final CommandResult sl = await run('pacman', <String>['-Sl'], timeout: const Duration(minutes: 1));
    final Map<String, String> repoOf = <String, String>{};
    for (final String line in sl.stdout.split('\n')) {
      final List<String> parts = line.split(' ');
      if (parts.length >= 3) repoOf.putIfAbsent(parts[1], () => parts[0]);
    }
    Set<String>? foreign;
    if (repoOf.isEmpty) {
      // No sync databases (never ran `pacman -Sy`): ask pacman directly.
      final CommandResult qm = await run('pacman', <String>['-Qqm']);
      foreign = qm.stdout.split('\n').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toSet();
    }
    return _PacmanSnapshot(await parsed, repoOf, foreign);
  }

  /// Parses every `local/<pkg>/desc` file (alpm-db-desc(5)) on a background
  /// isolate — about 7× faster than `pacman -Qi`.
  static Future<List<Map<String, List<String>>>> _readLocalDb(String localDir) {
    return Isolate.run(() {
      final List<Map<String, List<String>>> result = <Map<String, List<String>>>[];
      for (final FileSystemEntity e in Directory(localDir).listSync()) {
        if (e is! Directory) continue;
        final String? text = readText('${e.path}/desc');
        if (text == null) continue;
        final Map<String, List<String>> fields = <String, List<String>>{};
        String? key;
        for (final String raw in text.split('\n')) {
          final String line = raw.trimRight();
          if (line.startsWith('%') && line.endsWith('%') && line.length > 2) {
            key = line.substring(1, line.length - 1);
            fields[key] = <String>[];
          } else if (line.isEmpty) {
            key = null;
          } else if (key != null) {
            fields[key]!.add(line);
          }
        }
        if ((fields['NAME'] ?? const <String>[]).isNotEmpty) result.add(fields);
      }
      return result;
    });
  }
}

InstalledPackage _pacmanPackage(Map<String, List<String>> f, String managerId, String? origin) {
  String? one(String k) => (f[k] == null || f[k]!.isEmpty) ? null : f[k]!.first;
  final List<String> depends = f['DEPENDS'] ?? const <String>[];
  return InstalledPackage(
    name: one('NAME')!,
    version: one('VERSION') ?? '',
    managerId: managerId,
    description: one('DESC'),
    size: int.tryParse(one('SIZE') ?? ''),
    installDate: epochSeconds(one('INSTALLDATE')),
    // %REASON% is absent for explicit installs and `1` for dependencies.
    explicit: one('REASON') != '1',
    origin: origin,
    url: one('URL'),
    details: <String, String>{
      if ((f['LICENSE'] ?? const <String>[]).isNotEmpty) 'Licence': f['LICENSE']!.join(', '),
      if ((f['GROUPS'] ?? const <String>[]).isNotEmpty) 'Groups': f['GROUPS']!.join(', '),
      if (one('BUILDDATE') != null) 'Built on': Fmt.dateTime(epochSeconds(one('BUILDDATE'))),
      if (depends.isNotEmpty)
        'Depends on': depends.length > 12
            ? '${depends.take(12).join(', ')} … (+${depends.length - 12})'
            : depends.join(', '),
      if ((f['PROVIDES'] ?? const <String>[]).isNotEmpty) 'Provides': f['PROVIDES']!.join(', '),
    },
  );
}

RemovalPlan _pacmanRemoval(InstalledPackage p) => RemovalPlan(
  argv: <String>['pacman', '-Rs', '--noconfirm', p.name],
  needsRoot: true,
  reason: 'Uninstalling ${p.name} with pacman requires administrator rights.',
  warning: 'Dependencies that nothing else needs are removed too (pacman -Rs).',
);

Future<RemovalPreview> _pacmanPreview(InstalledPackage p) async {
  // `--print` performs a dry run and works without root.
  final CommandResult r = await run('pacman', <String>[
    '-Rs',
    '--print',
    '--print-format',
    '%n %v %s',
    p.name,
  ], timeout: const Duration(seconds: 60));
  if (!r.ok) {
    final List<String> lines = r.output
        .split('\n')
        .map((String l) => l.replaceAll(':: ', '').trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return RemovalPreview(blocker: 'pacman refused to remove ${p.name}.');
    final String shown = lines.take(12).join('\n');
    return RemovalPreview(blocker: lines.length > 12 ? '$shown\n… and ${lines.length - 12} more' : shown);
  }
  final List<String> items = <String>[];
  for (final String line in r.stdout.split('\n')) {
    final List<String> parts = line.trim().split(' ');
    if (parts.length >= 3) {
      items.add('${parts[0]} ${parts[1]}  (${Fmt.bytes(int.tryParse(parts[2]))})');
    } else if (line.trim().isNotEmpty) {
      items.add(line.trim());
    }
  }
  return RemovalPreview(items: items);
}

Future<bool> _pacmanPresent() async => has('pacman') && nonEmptyDir('${await _PacmanDb.dbPath()}local');

class PacmanManager extends PackageManager {
  @override
  String get id => 'pacman';
  @override
  String get label => 'pacman';
  @override
  String get description => 'Arch Linux repository packages';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() => _pacmanPresent();

  @override
  Future<List<InstalledPackage>> list() async {
    final _PacmanSnapshot s = await _PacmanDb.load();
    return <InstalledPackage>[
      for (final Map<String, List<String>> f in s.packages)
        if (!s.isForeign(f['NAME']!.first)) _pacmanPackage(f, id, s.repoOf[f['NAME']!.first]),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => _pacmanRemoval(package);

  @override
  Future<RemovalPreview?> removalPreview(InstalledPackage package) => _pacmanPreview(package);
}

/// Foreign packages (AUR or locally built). AUR helpers (yay, paru, …) all
/// install into pacman's database; removal goes through pacman because the
/// helpers refuse to run as root.
class ForeignPacmanManager extends PackageManager {
  static const List<String> _helpers = <String>['yay', 'paru', 'pikaur', 'trizen', 'aura', 'pamac'];

  String? get _helper {
    for (final String h in _helpers) {
      if (has(h)) return h;
    }
    return null;
  }

  @override
  String get id => 'aur';
  @override
  String get label => _helper == null ? 'Foreign' : 'AUR · $_helper';
  @override
  String get description => 'AUR and locally built packages (not in any configured repository)';
  @override
  IconData get icon => M3EIcons.hub_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async {
    if (!await _pacmanPresent()) return false;
    final _PacmanSnapshot s = await _PacmanDb.load();
    return s.packages.any((Map<String, List<String>> f) => s.isForeign(f['NAME']!.first));
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final _PacmanSnapshot s = await _PacmanDb.load();
    return <InstalledPackage>[
      for (final Map<String, List<String>> f in s.packages)
        if (s.isForeign(f['NAME']!.first)) _pacmanPackage(f, id, 'AUR / local build'),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => _pacmanRemoval(package);

  @override
  Future<RemovalPreview?> removalPreview(InstalledPackage package) => _pacmanPreview(package);
}

// ====================================================================== apt

class AptManager extends PackageManager {
  @override
  String get id => 'apt';
  @override
  String get label => 'apt';
  @override
  String get description => 'Debian / Ubuntu packages (dpkg)';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async =>
      has('dpkg-query') &&
      has('apt-get') &&
      nonEmptyFile('/var/lib/dpkg/status') &&
      osIsLike(<String>['debian', 'ubuntu']);

  @override
  Future<List<InstalledPackage>> list() async {
    const String fmtWithDate =
        r'${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Installed-Size}\t${db-fsys:Last-Modified}\t${binary:Summary}\n';
    const String fmtNoDate =
        r'${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Installed-Size}\t\t${binary:Summary}\n';
    CommandResult r = await run('dpkg-query', <String>['-W', '-f=$fmtWithDate']);
    if (!r.ok || r.stdout.trim().isEmpty) {
      // dpkg < 1.19.3 does not know db-fsys:Last-Modified.
      r = await run('dpkg-query', <String>['-W', '-f=$fmtNoDate']);
    }
    if (!r.ok) throw StateError('dpkg-query failed: ${r.errorSummary}');
    final CommandResult manual = await run('apt-mark', <String>['showmanual']);
    final Set<String> manualSet = manual.ok
        ? manual.stdout.split('\n').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toSet()
        : <String>{};
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final String line in r.stdout.split('\n')) {
      final List<String> f = line.split('\t');
      if (f.length < 6) continue;
      final String status = f[0];
      if (status.length < 2 || status[1] != 'i') continue;
      final String name = f[1];
      final String bare = name.split(':').first;
      out.add(
        InstalledPackage(
          name: name,
          version: f[2],
          managerId: id,
          size: int.tryParse(f[3]) == null ? null : int.parse(f[3]) * 1024,
          installDate: epochSeconds(f[4]),
          description: f.sublist(5).join('\t'),
          explicit: manual.ok ? (manualSet.contains(name) || manualSet.contains(bare)) : null,
        ),
      );
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    argv: <String>['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'remove', '-y', package.name],
    needsRoot: true,
    reason: 'Uninstalling ${package.name} with apt requires administrator rights.',
  );

  @override
  Future<RemovalPreview?> removalPreview(InstalledPackage package) async {
    final CommandResult r = await run('apt-get', <String>[
      '-s',
      'remove',
      package.name,
    ], timeout: const Duration(seconds: 60));
    if (!r.ok) return RemovalPreview(blocker: r.output.trim());
    final RegExp re = RegExp(r'^Remv (\S+)(?: \[([^\]]+)\])?');
    return RemovalPreview(
      items: <String>[
        for (final String line in r.stdout.split('\n'))
          if (re.firstMatch(line) case final RegExpMatch m) '${m.group(1)} ${m.group(2) ?? ''}'.trim(),
      ],
    );
  }
}

// ============================================================== rpm family

const String _rpmQueryFormat =
    r'%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{LONGSIZE}\t%{INSTALLTIME}\t%{SUMMARY}\n';

bool _rpmDbPresent() => has('rpm') && (nonEmptyDir('/var/lib/rpm') || nonEmptyDir('/usr/lib/sysimage/rpm'));

Future<List<InstalledPackage>> _rpmList(String managerId, bool? Function(String name) explicit) async {
  final String out = await runOrThrow('rpm', <String>['-qa', '--qf', _rpmQueryFormat]);
  final Map<String, int> counts = <String, int>{};
  final List<List<String>> rows = <List<String>>[];
  for (final String line in out.split('\n')) {
    final List<String> f = line.split('\t');
    if (f.length < 8 || f[0] == 'gpg-pubkey') continue;
    rows.add(f);
    counts[f[0]] = (counts[f[0]] ?? 0) + 1;
  }
  return <InstalledPackage>[
    for (final List<String> f in rows)
      InstalledPackage(
        // Multilib installs (x86_64 + i686) share a name; keep them distinct.
        name: (counts[f[0]] ?? 0) > 1 ? '${f[0]}.${f[4]}' : f[0],
        version: '${f[1] == '0' || f[1].isEmpty ? '' : '${f[1]}:'}${f[2]}-${f[3]}',
        managerId: managerId,
        size: int.tryParse(f[5]),
        installDate: epochSeconds(f[6]),
        description: f.sublist(7).join('\t'),
        explicit: explicit(f[0]),
        details: <String, String>{'Architecture': f[4]},
      ),
  ];
}

/// Installed packages that depend on [name] (and would be removed with it by
/// dnf/zypper). Works without root, unlike their own dry runs.
Future<RemovalPreview> _rpmDependentsPreview(InstalledPackage package) async {
  final String bare = package.name;
  final CommandResult provides = await run('rpm', <String>[
    '-q',
    '--provides',
    bare,
  ], timeout: const Duration(seconds: 30));
  final List<String> caps = <String>{
    bare,
    for (final String l in provides.stdout.split('\n'))
      if (l.trim().isNotEmpty) l.trim().split(RegExp(r'\s')).first,
  }.toList();
  final CommandResult req = await run('rpm', <String>[
    '-q',
    '--qf',
    r'%{NAME}\n',
    '--whatrequires',
    ...caps,
  ], timeout: const Duration(seconds: 30));
  final String self = bare.replaceFirst(RegExp(r'\.(x86_64|i686|aarch64|noarch|ppc64le|s390x)$'), '');
  final List<String> dependents = <String>{
    for (final String l in req.stdout.split('\n'))
      if (l.trim().isNotEmpty && !l.contains('no package requires') && l.trim() != self) l.trim(),
  }.toList()..sort();
  return RemovalPreview(
    items: <String>['${package.name} ${package.version}', ...dependents.map((String d) => '$d  (depends on it)')],
  );
}

class DnfManager extends PackageManager {
  String get _dnf => has('dnf5') ? 'dnf5' : (has('dnf') ? 'dnf' : 'yum');

  @override
  String get id => 'dnf';
  @override
  String get label => _dnf;
  @override
  String get description => 'Fedora / RHEL packages (rpm)';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async =>
      (has('dnf5') || has('dnf') || has('yum')) &&
      _rpmDbPresent() &&
      !File('/run/ostree-booted').existsSync() &&
      osIsLike(<String>['fedora', 'rhel', 'centos', 'rocky', 'almalinux', 'ol', 'amzn', 'nobara', 'mageia']);

  @override
  Future<List<InstalledPackage>> list() async {
    Set<String>? user;
    final String dnf = _dnf;
    if (dnf != 'yum') {
      final CommandResult r = await run(dnf, <String>[
        '-C',
        '-q',
        'repoquery',
        '--userinstalled',
        '--qf',
        dnf == 'dnf5' ? r'%{name}\n' : '%{name}',
      ], timeout: const Duration(seconds: 90));
      if (r.ok) {
        user = r.stdout.split('\n').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toSet();
      }
    }
    return _rpmList(id, (String name) => user?.contains(name));
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    argv: <String>[_dnf, 'remove', '-y', package.name],
    needsRoot: true,
    reason: 'Uninstalling ${package.name} with $_dnf requires administrator rights.',
  );

  @override
  Future<RemovalPreview?> removalPreview(InstalledPackage package) async {
    // Only dnf5 can do a dry run without root; otherwise ask rpm which
    // installed packages depend on it (dnf removes those too).
    if (_dnf != 'dnf5') return _rpmDependentsPreview(package);
    final CommandResult r = await run('dnf5', <String>[
      'remove',
      '--assumeno',
      package.name,
    ], timeout: const Duration(seconds: 90));
    final String out = r.output.trim();
    return out.isEmpty
        ? null
        : RemovalPreview(items: out.split('\n').where((String l) => l.trim().isNotEmpty).toList());
  }
}

class ZypperManager extends PackageManager {
  @override
  String get id => 'zypper';
  @override
  String get label => 'zypper';
  @override
  String get description => 'openSUSE packages (rpm)';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('zypper') && _rpmDbPresent();

  @override
  Future<List<InstalledPackage>> list() async {
    final String? auto = readText('/var/lib/zypp/AutoInstalled');
    final Set<String>? autoSet = auto
        ?.split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && !s.startsWith('#'))
        .toSet();
    return _rpmList(id, (String name) => autoSet == null ? null : !autoSet.contains(name));
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    argv: <String>['zypper', '--non-interactive', 'remove', package.name],
    needsRoot: true,
    reason: 'Uninstalling ${package.name} with zypper requires administrator rights.',
  );
  @override
  Future<RemovalPreview?> removalPreview(InstalledPackage package) => _rpmDependentsPreview(package);
}

// ====================================================================== apk

class ApkManager extends PackageManager {
  @override
  String get id => 'apk';
  @override
  String get label => 'apk';
  @override
  String get description => 'Alpine packages';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('apk') && nonEmptyFile('/lib/apk/db/installed');

  @override
  Future<List<InstalledPackage>> list() async {
    final String db = readText('/lib/apk/db/installed') ?? '';
    final Set<String> world = (readText('/etc/apk/world') ?? '')
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .map((String s) => s.split(RegExp(r'[<>=~@]')).first)
        .toSet();
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final String stanza in db.split(RegExp(r'\n\s*\n'))) {
      final Map<String, String> f = <String, String>{};
      for (final String line in stanza.split('\n')) {
        if (line.length > 2 && line[1] == ':') f.putIfAbsent(line[0], () => line.substring(2));
      }
      final String? name = f['P'];
      if (name == null) continue;
      out.add(
        InstalledPackage(
          name: name,
          version: f['V'] ?? '',
          managerId: id,
          description: f['T'],
          size: int.tryParse(f['I'] ?? ''),
          url: f['U'],
          origin: f['o'],
          explicit: world.contains(name),
          details: <String, String>{if (f['L'] != null) 'Licence': f['L']!},
        ),
      );
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['apk', 'del', package.name], needsRoot: true);
}

// ===================================================================== xbps

class XbpsManager extends PackageManager {
  @override
  String get id => 'xbps';
  @override
  String get label => 'xbps';
  @override
  String get description => 'Void Linux packages';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('xbps-query') && nonEmptyDir('/var/db/xbps');

  static (String, String) _split(String pkgver) {
    final int i = pkgver.lastIndexOf('-');
    return i <= 0 ? (pkgver, '') : (pkgver.substring(0, i), pkgver.substring(i + 1));
  }

  @override
  Future<List<InstalledPackage>> list() async {
    final String all = await runOrThrow('xbps-query', <String>['-l']);
    final CommandResult manual = await run('xbps-query', <String>['-m']);
    final Set<String> manualNames = <String>{
      for (final String l in manual.stdout.split('\n'))
        if (l.trim().isNotEmpty) _split(l.trim()).$1,
    };
    final List<InstalledPackage> out = <InstalledPackage>[];
    for (final String line in all.split('\n')) {
      final List<String> parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[0] != 'ii') continue;
      final (String name, String version) = _split(parts[1]);
      out.add(
        InstalledPackage(
          name: name,
          version: version,
          managerId: id,
          description: parts.length > 2 ? parts.sublist(2).join(' ') : null,
          explicit: manual.ok ? manualNames.contains(name) : null,
        ),
      );
    }
    return out;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['xbps-remove', '-y', package.name], needsRoot: true);
}

// ================================================================== portage

class PortageManager extends PackageManager {
  @override
  String get id => 'portage';
  @override
  String get label => 'portage';
  @override
  String get description => 'Gentoo packages';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;
  @override
  bool get tracksExplicit => true;

  @override
  Future<bool> detect() async => has('qlist') && has('emerge') && nonEmptyDir('/var/db/pkg');

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('qlist', <String>[
      '-I',
      '-C',
      '-F',
      '%{CATEGORY}/%{PN} %{PVR} %{SLOT} %{REPO}',
    ]);
    final Set<String> world = (readText('/var/lib/portage/world') ?? '')
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toSet();
    return <InstalledPackage>[
      for (final String line in out.split('\n'))
        if (line.trim().split(' ') case final List<String> f when f.length >= 2)
          InstalledPackage(
            name: f[0],
            version: f[1],
            managerId: id,
            origin: f.length > 3 ? f[3] : null,
            explicit: world.contains(f[0]),
            details: <String, String>{if (f.length > 2) 'Slot': f[2]},
          ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => RemovalPlan(
    // Packages in @world are never depcleaned, so deselect first.
    argv: <String>[
      'sh',
      '-c',
      r'emerge --ask=n --deselect "$1" && emerge --ask=n --depclean "$1"',
      'kalanjiyam',
      package.name,
    ],
    needsRoot: true,
    warning: 'emerge --depclean refuses to remove packages that others still need.',
  );
}

// ==================================================================== eopkg

class EopkgManager extends PackageManager {
  @override
  String get id => 'eopkg';
  @override
  String get label => 'eopkg';
  @override
  String get description => 'Solus packages';
  @override
  IconData get icon => M3EIcons.widgets_outlined;
  @override
  bool get isSystem => true;

  @override
  Future<bool> detect() async => has('eopkg') && nonEmptyDir('/var/lib/eopkg');

  @override
  Future<List<InstalledPackage>> list() async {
    final String summaries = await runOrThrow('eopkg', <String>['li', '-N']);
    final Map<String, String> summaryOf = <String, String>{};
    for (final String line in summaries.split('\n')) {
      final int sep = line.indexOf(' - ');
      if (sep > 0) summaryOf[line.substring(0, sep).trim()] = line.substring(sep + 3).trim();
    }
    final CommandResult details = await run('eopkg', <String>['li', '-N', '-i']);
    final Map<String, String> versionOf = <String, String>{};
    for (final String line in details.stdout.split('\n')) {
      final List<String> f = line.split('|').map((String s) => s.trim()).toList();
      if (f.length >= 4 && f[0].isNotEmpty && f[0] != 'Name' && !f[0].startsWith('=')) {
        versionOf[f[0]] = '${f[2]}-${f[3]}';
      }
    }
    return <InstalledPackage>[
      for (final MapEntry<String, String> e in summaryOf.entries)
        InstalledPackage(name: e.key, version: versionOf[e.key] ?? '', managerId: id, description: e.value),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['eopkg', 'remove', '-y', package.name], needsRoot: true);
}

// ====================================================================== nix

class NixManager extends PackageManager {
  bool get _newStyle => File('${env.home}/.nix-profile/manifest.json').existsSync();

  @override
  String get id => 'nix';
  @override
  String get label => 'Nix';
  @override
  String get description => 'Packages in your Nix user profile';
  @override
  IconData get icon => M3EIcons.ac_unit;

  @override
  Future<bool> detect() async => (has('nix') || has('nix-env')) && Link('${env.home}/.nix-profile').existsSync();

  @override
  Future<List<InstalledPackage>> list() async {
    if (_newStyle && has('nix')) {
      final String out = await runOrThrow('nix', <String>[
        '--extra-experimental-features',
        'nix-command flakes',
        'profile',
        'list',
        '--json',
      ]);
      final Object? json = jsonDecode(out);
      final List<InstalledPackage> result = <InstalledPackage>[];
      final Object? elements = json is Map ? json['elements'] : null;
      void add(String name, Map<dynamic, dynamic> e) {
        final List<dynamic> paths = (e['storePaths'] as List<dynamic>?) ?? const <dynamic>[];
        final String store = paths.isEmpty ? '' : paths.first.toString();
        final RegExpMatch? m = RegExp(r'/nix/store/[a-z0-9]+-(.+?)-(\d[^/]*)$').firstMatch(store);
        result.add(
          InstalledPackage(
            name: name,
            version: m?.group(2) ?? '',
            managerId: id,
            origin: (e['originalUrl'] ?? e['url'])?.toString(),
            details: <String, String>{if (e['attrPath'] != null) 'Attribute': e['attrPath'].toString()},
          ),
        );
      }

      if (elements is Map) {
        elements.forEach((dynamic k, dynamic v) {
          if (v is Map) add(k.toString(), v);
        });
      } else if (elements is List) {
        for (int i = 0; i < elements.length; i++) {
          final Object? v = elements[i];
          if (v is Map) add((v['attrPath'] ?? 'element $i').toString().split('.').last, v);
        }
      }
      return result;
    }
    final String out = await runOrThrow('nix-env', <String>['-q', '--installed', '--json', '--meta']);
    final Object? json = jsonDecode(out);
    final List<InstalledPackage> result = <InstalledPackage>[];
    if (json is Map) {
      json.forEach((dynamic attr, dynamic v) {
        if (v is! Map) return;
        final Object? meta = v['meta'];
        result.add(
          InstalledPackage(
            name: (v['pname'] ?? v['name'] ?? attr).toString(),
            version: (v['version'] ?? '').toString(),
            managerId: id,
            description: meta is Map ? meta['description']?.toString() : null,
          ),
        );
      });
    }
    return result;
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) => _newStyle
      ? RemovalPlan(
          argv: <String>[
            'nix',
            '--extra-experimental-features',
            'nix-command flakes',
            'profile',
            'remove',
            package.name,
          ],
          needsRoot: false,
        )
      : RemovalPlan(argv: <String>['nix-env', '-e', package.name], needsRoot: false);
}

// ===================================================================== guix

class GuixManager extends PackageManager {
  @override
  String get id => 'guix';
  @override
  String get label => 'Guix';
  @override
  String get description => 'Packages in your Guix profile';
  @override
  IconData get icon => M3EIcons.eco_outlined;

  @override
  Future<bool> detect() async => has('guix');

  @override
  Future<List<InstalledPackage>> list() async {
    final String out = await runOrThrow('guix', <String>['package', '-I'], timeout: const Duration(minutes: 2));
    return <InstalledPackage>[
      for (final String line in out.split('\n'))
        if (line.split('\t') case final List<String> f when f.length >= 2 && f[0].trim().isNotEmpty)
          InstalledPackage(
            name: f[0].trim(),
            version: f[1].trim(),
            managerId: id,
            details: <String, String>{if (f.length > 2) 'Output': f[2].trim()},
          ),
    ];
  }

  @override
  RemovalPlan? removalPlan(InstalledPackage package) =>
      RemovalPlan(argv: <String>['guix', 'remove', package.name], needsRoot: false);
}
