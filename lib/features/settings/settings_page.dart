import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../app.dart';
import '../../core/settings/app_settings.dart';
import '../../core/system/command_runner.dart';
import '../../core/system/privilege.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';

const String kAppVersion = '1.0.4';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  PrivilegeDiagnostics? _diag;

  @override
  void initState() {
    super.initState();
    _refreshDiagnostics();
  }

  Future<void> _refreshDiagnostics() async {
    final PrivilegeDiagnostics diag = await PrivilegeService.instance.diagnostics();
    if (mounted) setState(() => _diag = diag);
  }

  Future<void> _testAdmin() async {
    final CommandResult? result = await runWithLog(
      context,
      title: 'Testing administrator access',
      successMessage: 'Administrator access works.',
      task: (void Function(String) log) async {
        final CommandResult r = await PrivilegeService.instance.run(
          <String>['id', '-un'],
          reason: 'Kalanjiyam is checking that it can get administrator rights.',
          onLine: log,
        );
        return r;
      },
    );
    if (result != null) await _refreshDiagnostics();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final AppSettings settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, _) {
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: M3EAppBar.top(titleText: 'Settings'),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SectionCard(
                      title: 'Appearance',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Theme', style: text.titleSmall),
                          const SizedBox(height: 8),
                          M3ESegmentedButton<AppThemeMode>(
                            segments: const <M3ESegment<AppThemeMode>>[
                              M3ESegment<AppThemeMode>(
                                value: AppThemeMode.system,
                                label: 'System',
                                icon: Icon(M3EIcons.brightness_auto),
                              ),
                              M3ESegment<AppThemeMode>(
                                value: AppThemeMode.light,
                                label: 'Light',
                                icon: Icon(M3EIcons.light_mode),
                              ),
                              M3ESegment<AppThemeMode>(
                                value: AppThemeMode.dark,
                                label: 'Dark',
                                icon: Icon(M3EIcons.dark_mode),
                              ),
                            ],
                            selected: <AppThemeMode>{settings.themeMode},
                            onSelectionChanged: (Set<AppThemeMode> v) => settings.themeMode = v.first,
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text('Use system accent colour', style: text.bodyLarge),
                                    Text(
                                      'Follow the GTK theme accent when available',
                                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                              M3ESwitch(
                                value: settings.useSystemAccent,
                                onChanged: (bool v) => settings.useSystemAccent = v,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text('Colour', style: text.titleSmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: <Widget>[
                              for (final Color c in AppSettings.seedPalette)
                                _ColorDot(
                                  color: c,
                                  selected: settings.seedColor.toARGB32() == c.toARGB32() && !settings.useSystemAccent,
                                  onTap: () {
                                    settings.seedColor = c;
                                    if (settings.useSystemAccent) settings.useSystemAccent = false;
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildPrivilegeCard(context, settings),
                    const SizedBox(height: 16),
                    _buildAbout(context),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPrivilegeCard(BuildContext context, AppSettings settings) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final PrivilegeDiagnostics? d = _diag;
    Widget row(IconData icon, String title, String value, {bool ok = true}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: ok ? scheme.primary : scheme.error),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: text.bodyMedium)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
    return SectionCard(
      title: 'Administrator access',
      subtitle:
          'Needed only to uninstall system packages, clean system caches '
          '(pacman cache, journal logs) and edit launchers owned by packages.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          M3ESegmentedButton<PrivilegeMethod>(
            segments: const <M3ESegment<PrivilegeMethod>>[
              M3ESegment<PrivilegeMethod>(value: PrivilegeMethod.auto, label: 'Automatic'),
              M3ESegment<PrivilegeMethod>(value: PrivilegeMethod.polkit, label: 'Polkit (pkexec)'),
              M3ESegment<PrivilegeMethod>(value: PrivilegeMethod.sudo, label: 'sudo'),
            ],
            selected: <PrivilegeMethod>{settings.privilegeMethod},
            onSelectionChanged: (Set<PrivilegeMethod> v) => settings.privilegeMethod = v.first,
          ),
          const SizedBox(height: 8),
          Text(switch (settings.privilegeMethod) {
            PrivilegeMethod.auto =>
              'Uses your desktop\'s polkit password dialog when a polkit agent is running; '
                  'otherwise asks for your password here and passes it to sudo.',
            PrivilegeMethod.polkit =>
              'Always uses pkexec. Requires a polkit authentication agent (e.g. hyprpolkitagent, '
                  'polkit-gnome, polkit-kde-agent).',
            PrivilegeMethod.sudo =>
              'Asks for your password inside Kalanjiyam and passes it to sudo through a pipe. '
                  'It is never stored or logged.',
          }, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (d == null)
            const Center(child: M3ELoadingIndicator(size: 32))
          else ...<Widget>[
            if (d.isRoot) row(M3EIcons.warning_amber, 'Running as root', 'Not recommended', ok: false),
            row(M3EIcons.verified_user_outlined, 'pkexec', d.pkexecPath ?? 'Not installed', ok: d.pkexecPath != null),
            row(
              M3EIcons.badge_outlined,
              'Polkit agent',
              d.pkexecWorksThisSession == false ? 'None running (detected)' : (d.polkitAgentProcess ?? 'Not detected'),
              ok: d.pkexecWorksThisSession != false && d.polkitAgentProcess != null,
            ),
            row(M3EIcons.terminal, 'sudo', d.sudoPath ?? 'Not installed', ok: d.sudoPath != null),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: M3EButton.tonal(
              onPressed: _testAdmin,
              icon: const Icon(M3EIcons.admin_panel_settings_outlined),
              label: const Text('Test administrator access'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbout(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return SectionCard(
      title: 'About',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('$kAppName  ·  $kAppTamilName', style: text.headlineSmall),
          const SizedBox(height: 4),
          Text('Version $kAppVersion', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Text(
            '"Kalanjiyam" is Tamil for a storehouse or treasury: one place to look after your '
            'packages, launchers and disk space.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Privacy: Kalanjiyam works entirely offline. It sends no data anywhere, has no '
            'telemetry, and stores only your appearance and storage preferences.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          M3EButton.text(
            onPressed: () =>
                showLicensePage(context: context, applicationName: kAppName, applicationVersion: kAppVersion),
            child: const Text('Open-source licences'),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Colour',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          width: 44,
          height: 44,
          decoration: ShapeDecoration(
            color: color,
            shape: selected
                ? const StarBorder(points: 8, innerRadiusRatio: 0.84, pointRounding: 0.9)
                : CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
          ),
          child: selected ? const Icon(M3EIcons.check, color: Colors.white, size: 20) : null,
        ),
      ),
    );
  }
}
