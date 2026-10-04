import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/settings/app_settings.dart';
import 'core/system/shell_env.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Start resolving PATH (login shell, tool dirs) right away; every command
  // waits for it, the UI does not.
  unawaited(ShellEnv.instance.ready);
  await AppSettings.instance.load();
  // `--page=packages|launchers|storage|settings` opens a specific section
  // (used by the desktop file's actions).
  final String? page = args
      .where((String a) => a.startsWith('--page='))
      .map((String a) => a.substring('--page='.length))
      .firstOrNull;
  runApp(KalanjiyamApp(initialPage: page));
}
