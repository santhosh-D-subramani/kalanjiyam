import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/system/command_runner.dart';
import '../../core/system/privilege.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/filter_bar.dart';
import '../../core/widgets/states.dart';
import 'data/package_models.dart';
import 'packages_controller.dart';

class PackagesPage extends StatefulWidget {
  const PackagesPage({super.key});

  @override
  State<PackagesPage> createState() => _PackagesPageState();
}

class _PackagesPageState extends State<PackagesPage> {
  final PackagesController _controller = PackagesController();
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => _controller.query = _search.text);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _showDetails(InstalledPackage p) async {
    final PackageManager? manager = _controller.managerFor(p);
    if (manager == null) return;
    final RemovalPlan? plan = manager.removalPlan(p);
    await M3ESideSheet.show<void>(
      context,
      title: p.name,
      width: 420,
      scrollable: true,
      body: _PackageDetails(package: p, manager: manager),
      actions: <Widget>[
        if (plan != null)
          Builder(
            builder: (BuildContext sheetContext) => M3EButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _uninstall(p);
              },
              decoration: destructiveButtonDecoration(Theme.of(sheetContext).colorScheme),
              icon: const Icon(M3EIcons.delete_outline),
              label: const Text('Uninstall'),
            ),
          ),
      ],
    );
  }

  Future<void> _uninstall(InstalledPackage p) async {
    final PackageManager? manager = _controller.managerFor(p);
    final RemovalPlan? plan = manager?.removalPlan(p);
    if (manager == null || plan == null) return;

    RemovalPreview? dryRun;
    try {
      dryRun = await manager.removalPreview(p);
    } on Object {
      dryRun = null;
    }
    if (!mounted) return;
    if (dryRun?.blocker != null) {
      await showInfoDialog(
        context,
        title: 'Cannot uninstall ${p.name}',
        icon: M3EIcons.block,
        message: dryRun!.blocker!,
      );
      return;
    }
    final List<String>? preview = dryRun?.items;
    // Strip apt's ":amd64" and rpm's ".x86_64" qualifiers before the lookup.
    final String baseName = p.name
        .split(':')
        .first
        .replaceFirst(RegExp(r'\.(x86_64|i686|aarch64|noarch|ppc64le|s390x)$'), '');
    final bool critical = kCriticalPackages.contains(baseName) && manager.isSystem;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Uninstall ${p.name}?',
      icon: critical ? M3EIcons.warning_amber : M3EIcons.delete_outline,
      destructive: true,
      confirmLabel: 'Uninstall',
      requireCheckbox: critical ? 'I know this may break my system' : null,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (critical)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
              child: Text(
                '${p.name} is a core system package. Removing it can leave your system unable to boot or update.',
                style: text.bodyMedium?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          if (plan.warning != null) ...<Widget>[Text(plan.warning!), const SizedBox(height: 12)],
          if (preview != null && preview.isNotEmpty) ...<Widget>[
            Text('${Fmt.plural(preview.length, 'package')} will be removed:', style: text.titleSmall),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: SingleChildScrollView(
                child: Text(preview.join('\n'), style: text.bodySmall?.copyWith(fontFamily: 'monospace')),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text('Command', style: text.titleSmall),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: SelectableText(
              '${plan.needsRoot ? '(as administrator) ' : ''}${plan.commandLine}',
              style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;

    final CommandResult? result = await runWithLog(
      context,
      title: 'Uninstalling ${p.name}',
      successMessage: '${p.name} was uninstalled.',
      task: (void Function(String) log) {
        if (plan.needsRoot) {
          return PrivilegeService.instance.run(
            plan.argv,
            reason: plan.reason ?? 'Uninstalling ${p.name} requires administrator rights.',
            onLine: log,
          );
        }
        return CommandRunner.run(
          plan.argv.first,
          plan.argv.sublist(1),
          onLine: log,
          timeout: const Duration(minutes: 30),
        );
      },
    );
    if (result != null && result.ok) {
      await _controller.reload(p.managerId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, _) {
        final List<InstalledPackage> visible = _controller.visible;
        final List<ManagerState> states = _controller.states;
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: M3EAppBar.top(
            titleText: 'Packages',
            subtitleText: _controller.detecting
                ? 'Looking for package managers…'
                : '${_controller.total} installed · ${Fmt.plural(states.length, 'package manager')}',
            actions: <Widget>[
              M3EMenu.entries(
                position: M3EMenuAnchorPosition.bottomEnd,
                selectedValue: _controller.sort,
                onSelected: (Object? v) {
                  if (v is PackageSort) _controller.sort = v;
                },
                anchorBuilder: (BuildContext context, VoidCallback open) => M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(M3EIcons.sort),
                  tooltip: 'Sort',
                  onPressed: open,
                ),
                entries: const <M3EMenuEntry>[
                  M3EMenuEntry(label: 'Name', value: PackageSort.name, leading: Icon(M3EIcons.sort_by_alpha)),
                  M3EMenuEntry(label: 'Size', value: PackageSort.size, leading: Icon(M3EIcons.data_usage)),
                  M3EMenuEntry(label: 'Install date', value: PackageSort.date, leading: Icon(M3EIcons.event)),
                ],
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.refresh),
                tooltip: 'Reload',
                onPressed: _controller.anyLoading ? null : _controller.load,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SearchField(controller: _search, hint: 'Search installed packages'),
              ),
              FilterChipBar<String?>(
                selected: _controller.selected,
                onSelected: (String? id) => _controller.selected = id,
                options: <FilterOption<String?>>[
                  FilterOption<String?>(value: null, label: 'All', count: _controller.countFor(null)),
                  for (final ManagerState s in states)
                    FilterOption<String?>(
                      value: s.manager.id,
                      label: s.loading ? '${s.manager.label} …' : s.manager.label,
                      icon: s.error != null ? M3EIcons.error_outline : s.manager.icon,
                      count: s.loading ? null : _controller.countFor(s.manager.id),
                    ),
                ],
                trailing: <Widget>[
                  if (_controller.explicitFilterRelevant)
                    M3EChip(
                      type: M3EChipType.filter,
                      label: 'Hide dependencies',
                      leading: const Icon(M3EIcons.account_tree_outlined, size: 18),
                      selected: _controller.explicitOnly,
                      onPressed: () => _controller.explicitOnly = !_controller.explicitOnly,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(child: _buildBody(visible)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(List<InstalledPackage> visible) {
    if (_controller.detecting || (!_controller.detected)) {
      return const LoadingView(message: 'Looking for package managers…');
    }
    if (_controller.states.isEmpty) {
      return const EmptyView(
        icon: M3EIcons.inventory_2_outlined,
        title: 'No package managers found',
        message: 'Kalanjiyam did not find any supported package manager on this system.',
      );
    }
    final String? selected = _controller.selected;
    final ManagerState? state = selected == null ? null : _controller.stateOf(selected);
    if (state != null && state.error != null) {
      return ErrorView(message: state.error!, onRetry: () => _controller.reload(state.manager.id));
    }
    if (visible.isEmpty) {
      if (_controller.anyLoading) return const LoadingView(message: 'Reading installed packages…');
      return const EmptyView(
        icon: M3EIcons.search_off,
        title: 'No packages match',
        message: 'Try another filter or search term.',
      );
    }
    final List<ManagerState> failed = _controller.states.where((ManagerState s) => s.error != null).toList();
    return Column(
      children: <Widget>[
        if (selected == null && failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _ErrorBanner(states: failed, onRetry: (String id) => _controller.reload(id)),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
            itemCount: visible.length,
            itemExtent: 76,
            itemBuilder: (BuildContext context, int index) {
              final InstalledPackage p = visible[index];
              final PackageManager? m = _controller.managerFor(p);
              return _PackageTile(package: p, manager: m, showManager: selected == null, onTap: () => _showDetails(p));
            },
          ),
        ),
      ],
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({required this.package, required this.manager, required this.showManager, required this.onTap});

  final InstalledPackage package;
  final PackageManager? manager;
  final bool showManager;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> meta = <String>[
      package.version,
      if (showManager && manager != null) manager!.label,
      if (package.scope != null) package.scope!,
      if (package.explicit == false) 'dependency',
      if (package.installDate != null) Fmt.date(package.installDate),
    ].where((String s) => s.isNotEmpty).toList();
    final String subtitle = <String>[
      meta.join(' · '),
      if (package.description != null && package.description!.isNotEmpty) package.description!,
    ].join(' — ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: M3EListItem(
        headline: package.name,
        supportingText: subtitle,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: package.explicit == false ? scheme.surfaceContainerHighest : scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            manager?.icon ?? M3EIcons.inventory_2_outlined,
            size: 22,
            color: package.explicit == false ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
          ),
        ),
        trailingText: package.size == null ? null : Fmt.bytes(package.size),
        onTap: onTap,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.states, required this.onRetry});

  final List<ManagerState> states;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: <Widget>[
          Icon(M3EIcons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Could not read: ${states.map((ManagerState s) => s.manager.label).join(', ')}',
              style: text.bodyMedium?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          for (final ManagerState s in states)
            M3EButton.text(onPressed: () => onRetry(s.manager.id), child: Text('Retry ${s.manager.label}')),
        ],
      ),
    );
  }
}

class _PackageDetails extends StatelessWidget {
  const _PackageDetails({required this.package, required this.manager});

  final InstalledPackage package;
  final PackageManager manager;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final RemovalPlan? plan = manager.removalPlan(package);
    final Map<String, String> rows = <String, String>{
      'Version': package.version,
      'Package manager': manager.label,
      if (package.scope != null) 'Installation': package.scope!,
      if (package.origin != null) 'Source': package.origin!,
      if (package.size != null) 'Installed size': Fmt.bytes(package.size),
      if (package.installDate != null) 'Installed on': Fmt.dateTime(package.installDate),
      if (package.explicit != null) 'Reason': package.explicit! ? 'Installed explicitly' : 'Installed as a dependency',
      if (package.url != null) 'Website': package.url!,
      ...package.details,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (package.description != null && package.description!.isNotEmpty) ...<Widget>[
            Text(package.description!, style: text.bodyLarge),
            const SizedBox(height: 16),
          ],
          for (final MapEntry<String, String> r in rows.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(r.key, style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  SelectableText(r.value, style: text.bodyMedium),
                ],
              ),
            ),
          if (plan == null)
            Text(
              (package.origin ?? '').startsWith('System package') ||
                      (package.origin ?? '').startsWith('System gem') ||
                      (package.origin ?? '').startsWith('Bundled')
                  ? 'This is managed by your system package manager. Uninstall the system package instead.'
                  : 'Uninstalling this from Kalanjiyam is not supported.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            )
          else if (plan.needsRoot)
            TagChip(label: 'Uninstall needs administrator rights', icon: M3EIcons.admin_panel_settings_outlined),
        ],
      ),
    );
  }
}
