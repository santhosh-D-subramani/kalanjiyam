import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'shell_env.dart';

/// Result of a finished child process.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.cancelled = false,
  });

  /// A result for a command that could not be started at all.
  factory CommandResult.failure(String message) => CommandResult(exitCode: -1, stdout: '', stderr: message);

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool cancelled;

  bool get ok => exitCode == 0 && !timedOut && !cancelled;

  /// Combined output, useful for showing logs to the user.
  String get output {
    final String out = stdout.trimRight();
    final String err = stderr.trimRight();
    if (out.isEmpty) return err;
    if (err.isEmpty) return out;
    return '$out\n$err';
  }

  /// Short, human readable failure description.
  String get errorSummary {
    if (cancelled) return 'Cancelled';
    if (timedOut) return 'Timed out';
    final String err = stderr.trim();
    if (err.isNotEmpty) {
      final List<String> lines = err.split('\n');
      return lines.length > 6 ? lines.sublist(lines.length - 6).join('\n') : err;
    }
    return 'Exited with code $exitCode';
  }
}

/// Lets a caller stop a running command (e.g. a long disk scan).
class CancelToken {
  final List<void Function()> _listeners = <void Function()>[];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Calls [listener] on cancellation (immediately if already cancelled).
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

/// Runs external programs without a shell (argv lists only — no string
/// interpolation into `sh -c`, so file names can never inject commands).
abstract final class CommandRunner {
  static const Utf8Codec _utf8 = Utf8Codec(allowMalformed: true);

  /// Runs [executable] with [arguments] and collects its output.
  ///
  /// * [onLine] receives every stdout/stderr line as it arrives.
  /// * [stdinText] is written to stdin, which is then closed. When null,
  ///   stdin is closed immediately so a program can never block on input.
  /// * [cLocale] forces `LC_ALL=C` for stable, parseable output.
  static Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration? timeout = const Duration(minutes: 5),
    void Function(String line)? onLine,
    String? stdinText,
    bool cLocale = true,
    Map<String, String>? environment,
    String? workingDirectory,
    CancelToken? cancelToken,
  }) async {
    await ShellEnv.instance.ready;
    final String resolved = ShellEnv.instance.which(executable) ?? executable;
    final Process process;
    try {
      process = await Process.start(
        resolved,
        arguments,
        environment: ShellEnv.instance.childEnvironment(cLocale: cLocale, extra: environment),
        includeParentEnvironment: false,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      return CommandResult.failure('Could not start $executable: ${e.message}');
    }

    if (stdinText != null) {
      try {
        process.stdin.write(stdinText);
        await process.stdin.flush();
      } on Object {
        // The process may exit before reading stdin; nothing to do.
      }
    }
    unawaited(process.stdin.close().catchError((Object _) {}));

    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final Future<void> outDone = _pump(process.stdout, out, onLine);
    final Future<void> errDone = _pump(process.stderr, err, onLine);

    bool timedOut = false;
    bool cancelled = false;
    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        timedOut = true;
        process.kill();
      });
    }
    void onCancel() {
      cancelled = true;
      process.kill();
    }

    cancelToken?.addListener(onCancel);
    final int code = await process.exitCode;
    timer?.cancel();
    cancelToken?.removeListener(onCancel);
    // A grandchild may inherit and hold the pipes open after the direct child
    // exits; never let that hang the caller.
    await Future.wait(<Future<void>>[outDone, errDone]).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);
    return CommandResult(
      exitCode: code,
      stdout: out.toString(),
      stderr: err.toString(),
      timedOut: timedOut,
      cancelled: cancelled,
    );
  }

  /// Convenience: runs a command and returns trimmed stdout, or null when it
  /// fails or the program does not exist.
  static Future<String?> output(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    bool cLocale = true,
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    await ShellEnv.instance.ready;
    if (ShellEnv.instance.which(executable) == null) return null;
    final CommandResult result = await run(
      executable,
      arguments,
      timeout: timeout,
      cLocale: cLocale,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    if (!result.ok) return null;
    final String text = result.stdout.trim();
    return text.isEmpty ? null : text;
  }

  static Future<void> _pump(Stream<List<int>> stream, StringBuffer sink, void Function(String line)? onLine) async {
    if (onLine == null) {
      await for (final String chunk in stream.transform(_utf8.decoder)) {
        sink.write(chunk);
      }
      return;
    }
    await for (final String line in stream.transform(_utf8.decoder).transform(const LineSplitter())) {
      sink.writeln(line);
      onLine(line);
    }
  }
}
