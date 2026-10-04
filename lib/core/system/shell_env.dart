import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Resolves the environment used for every child process.
///
/// Desktop launchers often start apps with a minimal `PATH` that misses
/// user-level tool directories (`~/.cargo/bin`, `~/.bun/bin`, the Flutter SDK,
/// …). We merge the current `PATH`, the user's login-shell `PATH` and a list
/// of well-known tool directories so package managers and cache tools are
/// found no matter how the app was launched.
class ShellEnv {
  ShellEnv._();

  static final ShellEnv instance = ShellEnv._();

  Map<String, String> _env = Map<String, String>.of(Platform.environment);
  Completer<void>? _ready;
  int? _uid;

  Map<String, String> get environment => _env;

  String get home => _env['HOME'] ?? Platform.environment['HOME'] ?? '/';

  /// Numeric user id of the running app (resolved once [ready] completes).
  int? get uid => _uid;

  bool get isRoot => _uid == 0;

  String get xdgConfigHome => _nonEmpty(_env['XDG_CONFIG_HOME']) ?? '$home/.config';

  String get xdgDataHome => _nonEmpty(_env['XDG_DATA_HOME']) ?? '$home/.local/share';

  String get xdgCacheHome => _nonEmpty(_env['XDG_CACHE_HOME']) ?? '$home/.cache';

  List<String> get xdgDataDirs {
    final String raw = _nonEmpty(_env['XDG_DATA_DIRS']) ?? '/usr/local/share:/usr/share';
    return raw.split(':').where((String d) => d.isNotEmpty).toList();
  }

  List<String> get xdgConfigDirs {
    final String raw = _nonEmpty(_env['XDG_CONFIG_DIRS']) ?? '/etc/xdg';
    return raw.split(':').where((String d) => d.isNotEmpty).toList();
  }

  /// Lower-cased desktop names from `XDG_CURRENT_DESKTOP` (e.g. `hyprland`).
  List<String> get currentDesktops => (_env['XDG_CURRENT_DESKTOP'] ?? '')
      .split(':')
      .where((String d) => d.isNotEmpty)
      .map((String d) => d.toLowerCase())
      .toList();

  List<String> get pathDirs => (_env['PATH'] ?? '').split(':').where((String d) => d.isNotEmpty).toList();

  /// Completes once [init] has finished. Safe to await many times.
  Future<void> get ready => (_ready ??= Completer<void>()..complete(_init())).future;

  Future<void> _init() async {
    final List<String> dirs = <String>[];
    final Set<String> seen = <String>{};
    void add(String dir) {
      if (dir.isNotEmpty && seen.add(dir)) {
        dirs.add(dir);
      }
    }

    pathDirs.forEach(add);
    final String? loginPath = await _loginShellPath();
    if (loginPath != null) {
      loginPath.split(':').forEach(add);
    }
    for (final String dir in _wellKnownToolDirs()) {
      if (Directory(dir).existsSync()) {
        add(dir);
      }
    }
    _env = <String, String>{..._env, 'PATH': dirs.join(':')};
    _uid = await _resolveUid();
  }

  /// Environment for a child process. Forces the C locale by default so the
  /// output of CLI tools is stable and parseable.
  Map<String, String> childEnvironment({bool cLocale = true, Map<String, String>? extra}) {
    return <String, String>{..._env, if (cLocale) 'LC_ALL': 'C', if (cLocale) 'LANG': 'C', ...?extra};
  }

  /// Finds an executable on the resolved `PATH`. Returns its absolute path.
  String? which(String name) {
    if (name.contains('/')) {
      return _isExecutable(name) ? name : null;
    }
    for (final String dir in pathDirs) {
      final String candidate = '$dir/$name';
      if (_isExecutable(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  bool has(String name) => which(name) != null;

  /// Root-owned system directories. Programs run as root are only ever taken
  /// from here, never from user-writable PATH entries such as ~/.local/bin.
  static const List<String> systemBinDirs = <String>[
    '/usr/bin',
    '/bin',
    '/usr/sbin',
    '/sbin',
    '/usr/local/sbin',
    '/usr/local/bin',
  ];

  /// Like [which], but only searches [systemBinDirs] and rejects directories
  /// or files that are writable by group/others. With [setuid], the file must
  /// also carry the setuid bit (sudo, pkexec).
  String? systemWhich(String name, {bool setuid = false}) {
    if (name.contains('/')) {
      final String dir = name.substring(0, name.lastIndexOf('/'));
      if (!systemBinDirs.contains(dir)) return null;
      name = name.substring(name.lastIndexOf('/') + 1);
    }
    for (final String dir in systemBinDirs) {
      final String candidate = '$dir/$name';
      if (!_isExecutable(candidate)) continue;
      try {
        final int dirMode = FileStat.statSync(dir).mode;
        final int mode = FileStat.statSync(candidate).mode;
        if ((dirMode & 0x12) != 0 || (mode & 0x12) != 0) continue; // g+w / o+w
        if (setuid && (mode & 0x800) == 0) continue;
        return candidate;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static bool _isExecutable(String path) {
    try {
      final FileStat stat = FileStat.statSync(path);
      return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
    } on FileSystemException {
      return false;
    }
  }

  static String? _nonEmpty(String? value) => (value == null || value.trim().isEmpty) ? null : value;

  Future<int?> _resolveUid() async {
    try {
      final ProcessResult result = await Process.run('id', <String>['-u']);
      return int.tryParse((result.stdout as String).trim());
    } on Object {
      return null;
    }
  }

  /// Asks the user's login shell for its `PATH`. Interactive rc files are
  /// where most people extend `PATH`, so `-i -l` is used, with stdin closed
  /// and a hard timeout so a misbehaving rc file can never hang the app.
  Future<String?> _loginShellPath() async {
    final String? shell = _nonEmpty(Platform.environment['SHELL']);
    if (shell == null || !File(shell).existsSync()) {
      return null;
    }
    const String start = '__KALANJIYAM_PATH_START__';
    const String end = '__KALANJIYAM_PATH_END__';
    Process? process;
    try {
      process = await Process.start(
        shell,
        <String>['-i', '-l', '-c', 'printf "%s%s%s" "$start" "\$PATH" "$end"'],
        environment: <String, String>{'TERM': 'dumb'},
      );
      unawaited(process.stdin.close());
      unawaited(process.stderr.drain<void>());
      final String output = await process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 6));
      final int s = output.lastIndexOf(start);
      final int e = output.lastIndexOf(end);
      if (s == -1 || e == -1 || e <= s) {
        return null;
      }
      final String path = output.substring(s + start.length, e).trim();
      return path.contains('/') ? path : null;
    } on Object {
      return null;
    } finally {
      process?.kill();
    }
  }

  List<String> _wellKnownToolDirs() {
    final String h = home;
    return <String>[
      '$h/.local/bin',
      '$h/bin',
      '$h/.cargo/bin',
      '$h/.bun/bin',
      '$h/go/bin',
      '$h/.deno/bin',
      '$h/.pub-cache/bin',
      '$h/.npm-global/bin',
      '$h/.yarn/bin',
      '$h/.local/share/pnpm',
      '$h/.volta/bin',
      '$h/.dotnet/tools',
      '$h/.local/share/mise/shims',
      '$h/.asdf/shims',
      '$h/.nix-profile/bin',
      '/nix/var/nix/profiles/default/bin',
      '/home/linuxbrew/.linuxbrew/bin',
      '$h/.linuxbrew/bin',
      '/var/lib/flatpak/exports/bin',
      '$h/.local/share/flatpak/exports/bin',
      '/snap/bin',
      '$h/.sdkman/candidates/gradle/current/bin',
      '$h/.sdkman/candidates/maven/current/bin',
      '$h/fvm/default/bin',
      '$h/flutter/bin',
      '$h/development/flutter/bin',
      '$h/snap/flutter/common/flutter/bin',
      '/opt/flutter/bin',
      '$h/miniconda3/bin',
      '$h/anaconda3/bin',
      '$h/miniforge3/bin',
    ];
  }
}
