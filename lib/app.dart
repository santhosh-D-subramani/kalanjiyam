import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'core/settings/app_settings.dart';
import 'core/system/privilege.dart';
import 'core/widgets/dialogs.dart';
import 'home_shell.dart';

/// Root navigator, used to show the sudo password prompt from services.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const String kAppName = 'Kalanjiyam';
const String kAppTamilName = 'களஞ்சியம்';

class KalanjiyamApp extends StatefulWidget {
  const KalanjiyamApp({super.key, this.initialPage});

  /// Section to open first (`packages`, `launchers`, `storage`, `settings`).
  final String? initialPage;

  @override
  State<KalanjiyamApp> createState() => _KalanjiyamAppState();
}

class _KalanjiyamAppState extends State<KalanjiyamApp> {
  final M3EThemeController _themeController = M3EThemeController();

  @override
  void initState() {
    super.initState();
    PrivilegeService.instance.passwordPrompter = ({required String reason, String? error}) async {
      final BuildContext? context = appNavigatorKey.currentState?.overlay?.context;
      if (context == null || !context.mounted) return null;
      return showPasswordDialog(context, reason: reason, error: error);
    };
  }

  @override
  void dispose() {
    PrivilegeService.instance.passwordPrompter = null;
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, _) {
        return M3EMaterialApp(
          title: kAppName,
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          data: M3EThemeData.light(seedColor: settings.seedColor),
          autoTheming: settings.themeMode == AppThemeMode.system,
          initialTheme: settings.themeMode == AppThemeMode.dark ? Brightness.dark : Brightness.light,
          dynamicColoring: settings.useSystemAccent,
          controller: _themeController,
          home: HomeShell(initialPage: widget.initialPage),
        );
      },
    );
  }
}
