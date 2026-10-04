import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../settings/app_settings.dart';
import 'command_runner.dart';
import 'shell_env.dart';

/// Thrown when the user cancels authentication.
class PrivilegeCancelled implements Exception {
  const PrivilegeCancelled();

  @override
  String toString() => 'Authentication cancelled';
}

/// Thrown when administrator rights cannot be obtained at all.
class PrivilegeUnavailable implements Exception {
  const PrivilegeUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the user for their password. [error] is set after a failed attempt.
/// Returns null when the user cancels.
typedef PasswordPrompter = Future<String?> Function({required String reason, String? error});

/// Snapshot of what the system offers for privilege escalation.
class PrivilegeDiagnostics {
  const PrivilegeDiagnostics({
    required this.isRoot,
    required this.pkexecPath,
    required this.sudoPath,
    required this.polkitAgentProcess,
    required this.pkexecWorksThisSession,
  });

  final bool isRoot;
  final String? pkexecPath;
  final String? sudoPath;

  /// Name of a running polkit agent process, when one could be detected.
  final String? polkitAgentProcess;

  /// `false` once pkexec reported "no authentication agent" in this session.
  final bool? pkexecWorksThisSession;
}

/// Runs commands as root.
///
/// Strategy (configurable in Settings):
/// 1. Already root → run directly.
/// 2. `pkexec --disable-internal-agent` — the desktop's polkit agent shows
///    its own password dialog. Many tiling compositors (Hyprland, Sway, …)
///    do not start a polkit agent by default; pkexec then exits with 127 and
///    "No authentication agent found", and we fall back to:
/// 3. `sudo`. Cached credentials are used when present (`sudo -n`).
///    Otherwise the app asks for the password, validates it with
///    `sudo -S -v` and runs the command with `sudo -n`. If the sudoers
///    policy does not share the timestamp, the command is run once with
///    `sudo -S -k` instead, which always consumes the password itself.
///
/// The password only lives in memory for the duration of one call. It is
/// never logged, persisted, put on a command line or in the environment —
/// it is written to sudo's stdin only.
class PrivilegeService {
  PrivilegeService._();

  static final PrivilegeService instance = PrivilegeService._();

  PasswordPrompter? passwordPrompter;

  bool _pkexecHasNoAgent = false;
  bool? _pkexecWorked;

  /// Serialises privileged operations so two password prompts never overlap.
  Future<void> _queue = Future<void>.value();

  static const List<String> _agentProcessNames = <String>[
    'hyprpolkitagent',
    'polkit-gnome-authentication-agent-1',
    'polkit-kde-authentication-agent-1',
    'polkit-mate-authentication-agent-1',
    'lxpolkit',
    'lxqt-policykit-agent',
    'xfce-polkit',
    'polkit-efl-authentication-agent-1',
    'mate-polkit',
    'soteria',
    'polkit-agent-helper-1',
    'gnome-shell',
    'plasmashell',
    'cinnamon',
    'budgie-polkit-dialog',
  ];

  Future<PrivilegeDiagnostics> diagnostics() async {
    await ShellEnv.instance.ready;
    return PrivilegeDiagnostics(
      isRoot: ShellEnv.instance.isRoot,
      pkexecPath: ShellEnv.instance.systemWhich('pkexec', setuid: true),
      sudoPath: ShellEnv.instance.systemWhich('sudo', setuid: true),
      polkitAgentProcess: await _detectAgentProcess(),
      pkexecWorksThisSession: _pkexecHasNoAgent ? false : _pkexecWorked,
    );
  }

  /// Runs [argv] as root. [reason] is shown in the in-app password dialog.
  ///
  /// Throws [PrivilegeCancelled] if the user cancels and
  /// [PrivilegeUnavailable] if no escalation method works.
  Future<CommandResult> run(
    List<String> argv, {
    required String reason,
    void Function(String line)? onLine,
    Duration timeout = const Duration(minutes: 30),
  }) {
    final Completer<CommandResult> completer = Completer<CommandResult>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _run(argv, reason: reason, onLine: onLine, timeout: timeout));
      } on Object catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<CommandResult> _run(
    List<String> argv, {
    required String reason,
    void Function(String line)? onLine,
    required Duration timeout,
  }) async {
    if (argv.isEmpty) {
      throw ArgumentError('argv must not be empty');
    }
    await ShellEnv.instance.ready;
    final ShellEnv env = ShellEnv.instance;

    // Resolve the program up front, and only from root-owned system
    // directories: a user-writable PATH entry (~/.local/bin, …) must never be
    // able to plant a program that then runs as root.
    final String? program = env.systemWhich(argv.first);
    if (program == null) {
      throw PrivilegeUnavailable('${argv.first} was not found in the system directories (/usr/bin, /usr/sbin, …).');
    }
    // pkexec replaces itself with the root program, so the app cannot kill
    // it on timeout; let coreutils `timeout`, running as root, enforce it.
    final String? timeoutBin = env.systemWhich('timeout');
    final List<String> command = <String>[
      if (timeoutBin != null) ...<String>[timeoutBin, '--kill-after=30', '${timeout.inSeconds}s'],
      program,
      ...argv.skip(1),
    ];

    // Let the root-side `timeout` fire first; this is only a safety net.
    final Duration outerTimeout = timeout + const Duration(seconds: 90);

    if (env.isRoot) {
      return CommandRunner.run(command.first, command.sublist(1), onLine: onLine, timeout: outerTimeout);
    }

    final PrivilegeMethod method = AppSettings.instance.privilegeMethod;
    final String? pkexec = env.systemWhich('pkexec', setuid: true);
    final String? sudo = env.systemWhich('sudo', setuid: true);

    final bool tryPolkit =
        pkexec != null && (method == PrivilegeMethod.polkit || (method == PrivilegeMethod.auto && !_pkexecHasNoAgent));
    if (tryPolkit) {
      final CommandResult result = await _runPkexec(pkexec, command, onLine, outerTimeout);
      if (!_isMissingAgent(result)) {
        return result;
      }
      _pkexecHasNoAgent = true;
      if (method == PrivilegeMethod.polkit) {
        throw const PrivilegeUnavailable(
          'No polkit authentication agent is running. Start one (for example '
          'hyprpolkitagent or polkit-gnome) or switch the method to "sudo" in Settings.',
        );
      }
    } else if (method == PrivilegeMethod.polkit) {
      throw const PrivilegeUnavailable('pkexec is not installed.');
    }

    if (sudo == null) {
      throw const PrivilegeUnavailable(
        'Neither a working polkit agent nor sudo is available to gain administrator rights.',
      );
    }
    return _runSudo(sudo, command, reason, onLine, outerTimeout);
  }

  Future<CommandResult> _runPkexec(
    String pkexec,
    List<String> command,
    void Function(String line)? onLine,
    Duration timeout,
  ) async {
    final CommandResult result = await CommandRunner.run(
      pkexec,
      <String>['--disable-internal-agent', ...command],
      timeout: timeout,
      // Hide pkexec's own agent error; it is handled by falling back to sudo.
      onLine: onLine == null
          ? null
          : (String line) {
              if (!line.contains('authentication agent') &&
                  !line.startsWith('Error executing command as another user')) {
                onLine(line);
              }
            },
    );
    if (result.exitCode == 126 && result.stderr.contains('Request dismissed')) {
      throw const PrivilegeCancelled();
    }
    if ((result.exitCode == 126 || result.exitCode == 127) &&
        result.stderr.contains('Error executing command as another user: Not authorized')) {
      throw const PrivilegeUnavailable('Authorization failed: polkit did not grant administrator rights.');
    }
    if (!_isMissingAgent(result)) {
      _pkexecWorked = true;
    }
    return result;
  }

  Future<CommandResult> _runSudo(
    String sudo,
    List<String> command,
    String reason,
    void Function(String line)? onLine,
    Duration timeout,
  ) async {
    // Cached credentials or a NOPASSWD rule: no password needed.
    if (await _sudoNeedsNoPassword(sudo, command)) {
      return CommandRunner.run(sudo, <String>['-n', '--', ...command], onLine: onLine, timeout: timeout);
    }

    final PasswordPrompter? prompt = passwordPrompter;
    if (prompt == null) {
      throw const PrivilegeUnavailable('No password prompt is available.');
    }

    String? error;
    for (int attempt = 0; attempt < 3; attempt++) {
      String? password = await prompt(reason: reason, error: error);
      if (password == null) {
        throw const PrivilegeCancelled();
      }
      try {
        final CommandResult validate = await CommandRunner.run(
          sudo,
          <String>['-S', '-p', '', '-v'],
          stdinText: '$password\n',
          timeout: const Duration(seconds: 30),
        );
        if (!validate.ok) {
          if (_isNotInSudoers(validate)) {
            throw const PrivilegeUnavailable(
              'Your account is not allowed to use sudo. Ask an administrator to add you '
              'to the "wheel" (or "sudo") group, or use a polkit agent instead.',
            );
          }
          error = 'Incorrect password, please try again.';
          continue;
        }
        // Credentials are now cached for this app process (sudo's ppid/tty
        // timestamp). Prefer running without sending the password again.
        if (await _sudoNeedsNoPassword(sudo, command)) {
          return await CommandRunner.run(sudo, <String>['-n', '--', ...command], onLine: onLine, timeout: timeout);
        }
        // The sudoers policy does not share timestamps (e.g. timestamp_timeout=0)
        // and the command does need a password (checked just above, so a
        // NOPASSWD rule cannot apply): with `-k` sudo reads the password from
        // stdin itself, so it does not reach the command.
        return await CommandRunner.run(
          sudo,
          <String>['-S', '-k', '-p', '', '--', ...command],
          stdinText: '$password\n',
          onLine: onLine,
          timeout: timeout,
        );
      } finally {
        password = null;
      }
    }
    throw const PrivilegeUnavailable('Authentication failed: too many incorrect password attempts.');
  }

  /// True when sudo would run [command] without asking for a password
  /// (cached credentials, or a NOPASSWD rule for this specific command).
  static Future<bool> _sudoNeedsNoPassword(String sudo, List<String> command) async {
    const Duration t = Duration(seconds: 15);
    if ((await CommandRunner.run(sudo, <String>['-n', 'true'], timeout: t)).ok) return true;
    return (await CommandRunner.run(sudo, <String>['-n', '-l', '--', ...command], timeout: t)).ok;
  }

  static bool _isMissingAgent(CommandResult result) =>
      result.exitCode == 127 && result.stderr.contains('No authentication agent found');

  static bool _isNotInSudoers(CommandResult result) {
    final String err = result.stderr;
    return err.contains('not in the sudoers file') ||
        err.contains('is not allowed to') ||
        err.contains('may not run sudo');
  }

  /// Finds a running polkit authentication agent: any of the user's
  /// processes that has a polkit agent library mapped (desktop shells such as
  /// quickshell, GNOME Shell or Plasma embed their own agent), falling back to
  /// well-known agent process names.
  Future<String?> _detectAgentProcess() async {
    // Process maps can be megabytes each; scan them off the UI isolate.
    final String? fromMaps = await Isolate.run(_scanProcMapsForAgent);
    if (fromMaps != null) return fromMaps;
    final CommandResult result = await CommandRunner.run('ps', <String>[
      '-eo',
      'comm=',
    ], timeout: const Duration(seconds: 5));
    if (!result.ok) return null;
    final Set<String> running = result.stdout.split('\n').map((String l) => l.trim()).toSet();
    for (final String name in _agentProcessNames) {
      // `comm` is truncated to 15 characters by the kernel.
      final String truncated = name.length > 15 ? name.substring(0, 15) : name;
      if (running.contains(name) || running.contains(truncated)) {
        return name;
      }
    }
    return null;
  }

  static String? _scanProcMapsForAgent() {
    try {
      for (final FileSystemEntity e in Directory('/proc').listSync()) {
        final String pid = e.path.substring(6);
        if (int.tryParse(pid) == null) continue;
        try {
          final String maps = File('${e.path}/maps').readAsStringSync();
          if (maps.contains('libpolkit-agent-1') || RegExp(r'libpolkit-qt\d?-agent').hasMatch(maps)) {
            return File('${e.path}/comm').readAsStringSync().trim();
          }
        } on FileSystemException {
          continue; // other users' processes are not readable
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}
