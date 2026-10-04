import 'dart:io';

import 'shell_env.dart';

/// Opens a file or folder with the user's default application (detached, so
/// the app never waits for the file manager to exit).
Future<bool> openExternally(String path) async {
  await ShellEnv.instance.ready;
  final String? opener = ShellEnv.instance.which('xdg-open') ?? ShellEnv.instance.which('gio');
  if (opener == null) return false;
  try {
    await Process.start(
      opener,
      opener.endsWith('gio') ? <String>['open', path] : <String>[path],
      environment: ShellEnv.instance.childEnvironment(cLocale: false),
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
    return true;
  } on ProcessException {
    return false;
  }
}
