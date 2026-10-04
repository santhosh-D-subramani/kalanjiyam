import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/system/command_runner.dart';
import '../../core/system/privilege.dart';
import '../../core/system/shell_env.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import 'caches_controller.dart';
import 'data/cache_model.dart';

class CachesView extends StatefulWidget {
  const CachesView({super.key});

  @override
  State<CachesView> createState() => _CachesViewState();
}

class _CachesViewState extends State<CachesView> {
  final CachesController _controller = CachesController();

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _clean(List<CacheEntry> entries) async {
    if (entries.isEmpty) return;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool risky = entries.any((CacheEntry e) => e.target.safety != CacheSafety.safe);
    final int total = entries.fold<int>(0, (int s, CacheEntry e) => s + (e.size ?? 0));

    final List<Widget> details = <Widget>[];
    for (final CacheEntry e in entries) {
      final List<String> running = CacheCleaner.runningProcesses(e.target.processGuard);
      details.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text(e.target.name, style: text.titleSmall)),
                  if (e.size != null) Text(Fmt.bytes(e.size), style: text.labelLarge),
                ],
              ),
              const SizedBox(height: 4),
              Text(e.target.clean.describe(e.existingPaths), style: text.bodySmall?.copyWith(fontFamily: 'monospace')),
              if (e.target.warning != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(e.target.warning!, style: text.bodySmall?.copyWith(color: scheme.tertiary)),
              ],
              if (running.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Looks like it is in use right now (${running.join(', ')}). Close it before cleaning.',
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final bool confirmed = await showConfirmDialog(
      context,
      title: entries.length == 1 ? 'Clean ${entries.first.target.name}?' : 'Clean ${entries.length} caches?',
      icon: M3EIcons.cleaning_services_outlined,
      destructive: risky,
      confirmLabel: 'Clean',
      message: total > 0 ? 'About ${Fmt.bytes(total)} will be freed.' : null,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 340, maxWidth: 560),
        child: SingleChildScrollView(child: Column(children: details)),
      ),
    );
    if (!confirmed || !mounted) return;

    final Map<String, int?> before = <String, int?>{for (final CacheEntry e in entries) e.target.id: e.size};
    await runWithLog(
      context,
      title: entries.length == 1 ? 'Cleaning ${entries.first.target.name}' : 'Cleaning caches',
      successMessage: 'Caches cleaned.',
      task: (void Function(String) log) async {
        final List<String> failures = <String>[];
        for (final CacheEntry e in entries) {
          if (entries.length > 1) log('── ${e.target.name}');
          try {
            final CommandResult r = await CacheCleaner.run(e.target, e.existingPaths, log);
            if (!r.ok) failures.add('${e.target.name}: ${r.errorSummary}');
          } on PrivilegeCancelled {
            failures.add('${e.target.name}: authentication cancelled');
          } on PrivilegeUnavailable catch (err) {
            failures.add('${e.target.name}: ${err.message}');
          } on Object catch (err) {
            failures.add('${e.target.name}: $err');
          }
        }
        return CommandResult(exitCode: failures.isEmpty ? 0 : 1, stdout: '', stderr: failures.join('\n'));
      },
    );
    for (final CacheEntry e in entries) {
      await _controller.remeasure(e.target.id);
    }
    _controller.selected.removeAll(entries.map((CacheEntry e) => e.target.id));
    if (!mounted) return;
    int freed = 0;
    for (final CacheEntry e in entries) {
      final int? b = before[e.target.id];
      final int? a = _controller.entry(e.target.id)?.size;
      if (b != null && a != null && b > a) freed += b - a;
    }
    if (freed > 0) showSnack(context, '${Fmt.bytes(freed)} freed');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, _) {
        if (!_controller.loaded) {
          return const LoadingView(
            message: 'Looking for caches…',
            detail: 'npm, pub, Gradle, Cargo, pip, pacman and more',
          );
        }
        final List<CacheEntry> visible = _controller.visible;
        final List<CacheEntry> selectedEntries = visible
            .where((CacheEntry e) => _controller.selected.contains(e.target.id))
            .toList();
        final int selectedBytes = selectedEntries.fold<int>(0, (int s, CacheEntry e) => s + (e.size ?? 0));
        final Map<CacheGroup, List<CacheEntry>> groups = <CacheGroup, List<CacheEntry>>{};
        for (final CacheEntry e in visible) {
          groups.putIfAbsent(e.target.group, () => <CacheEntry>[]).add(e);
        }
        return Column(
          children: <Widget>[
            _Header(controller: _controller),
            Expanded(
              child: visible.isEmpty
                  ? const EmptyView(
                      icon: M3EIcons.check_circle_outline,
                      title: 'No caches found',
                      message: 'None of the supported tools have cached data here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      children: <Widget>[
                        for (final CacheGroup g in CacheGroup.values)
                          if (groups[g] != null) ...<Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                              child: Text(g.label, style: Theme.of(context).textTheme.titleSmall),
                            ),
                            for (final CacheEntry e in groups[g]!)
                              _CacheTile(
                                entry: e,
                                selected: _controller.selected.contains(e.target.id),
                                onSelect: (bool v) => setState(() {
                                  v ? _controller.selected.add(e.target.id) : _controller.selected.remove(e.target.id);
                                }),
                                onClean: () => _clean(<CacheEntry>[e]),
                              ),
                          ],
                      ],
                    ),
            ),
            if (selectedEntries.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  children: <Widget>[
                    M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      icon: const Icon(M3EIcons.close),
                      tooltip: 'Clear selection',
                      onPressed: () => setState(_controller.selected.clear),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${selectedEntries.length} selected · ${Fmt.bytes(selectedBytes)}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    M3EButton.filled(
                      onPressed: () => _clean(selectedEntries),
                      icon: const Icon(M3EIcons.cleaning_services_outlined),
                      label: const Text('Clean selected'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final CachesController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(28)),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Caches found', style: text.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Text(
                      Fmt.bytes(controller.totalSize),
                      style: text.headlineMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (controller.measuring) ...<Widget>[
                      const SizedBox(width: 12),
                      const M3ELoadingIndicator(size: 28),
                    ],
                  ],
                ),
                Text(
                  '${Fmt.plural(controller.visible.length, 'cache')} · tools download what they need again',
                  style: text.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('Advanced', style: text.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
                  const SizedBox(width: 8),
                  M3ESwitch(value: controller.showAdvanced, onChanged: (bool v) => controller.showAdvanced = v),
                ],
              ),
              const SizedBox(height: 8),
              M3EButton.tonal(
                onPressed: controller.loading || controller.measuring ? null : controller.load,
                icon: const Icon(M3EIcons.refresh),
                label: const Text('Re-measure'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CacheTile extends StatelessWidget {
  const _CacheTile({required this.entry, required this.selected, required this.onSelect, required this.onClean});

  final CacheEntry entry;
  final bool selected;
  final ValueChanged<bool> onSelect;
  final VoidCallback onClean;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final CacheTarget t = entry.target;
    final List<String> paths = entry.existingPaths;
    final String home = ShellEnv.instance.home;
    final String pathText = paths.isEmpty
        ? ''
        : '${paths.take(2).map((String p) => Fmt.tildify(p, home)).join('  ·  ')}${paths.length > 2 ? '  +${paths.length - 2}' : ''}';
    final (String safetyLabel, Color bg, Color fg) = switch (t.safety) {
      CacheSafety.safe => ('Safe', scheme.secondaryContainer, scheme.onSecondaryContainer),
      CacheSafety.caution => ('Caution', scheme.tertiaryContainer, scheme.onTertiaryContainer),
      CacheSafety.risky => ('Risky', scheme.errorContainer, scheme.onErrorContainer),
    };
    final bool empty = !entry.measuring && entry.size == 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? scheme.secondaryContainer.withValues(alpha: 0.6) : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: empty ? null : () => onSelect(!selected),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 12, 10),
            child: Row(
              children: <Widget>[
                M3ECheckbox(value: selected, onChanged: empty ? null : (bool? v) => onSelect(v ?? false)),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(t.icon, color: scheme.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(t.name, style: text.titleSmall),
                          TagChip(label: safetyLabel, color: bg, foreground: fg),
                          if (t.needsRoot) const TagChip(label: 'Admin', icon: M3EIcons.admin_panel_settings_outlined),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.description,
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (pathText.isNotEmpty)
                        Text(
                          pathText,
                          style: text.labelSmall?.copyWith(color: scheme.outline, fontFamily: 'monospace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 92,
                  child: entry.measuring
                      ? const Align(alignment: Alignment.centerRight, child: M3ELoadingIndicator(size: 24))
                      : Text(
                          entry.size == null ? '—' : '${t.sharedStorage ? 'up to ' : ''}${Fmt.bytes(entry.size)}',
                          textAlign: TextAlign.end,
                          style: text.titleSmall,
                        ),
                ),
                const SizedBox(width: 8),
                M3EButton.tonal(onPressed: empty ? null : onClean, enabled: !empty, child: const Text('Clean')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
