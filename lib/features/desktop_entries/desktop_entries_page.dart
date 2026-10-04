import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/system/command_runner.dart';
import '../../core/system/shell_env.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/filter_bar.dart';
import '../../core/widgets/states.dart';
import 'data/desktop_entry.dart';
import 'data/mime_apps.dart';
import 'desktop_entries_controller.dart';
import 'desktop_entry_editor_page.dart';
import 'widgets/entry_icon.dart';

class DesktopEntriesPage extends StatefulWidget {
  const DesktopEntriesPage({super.key});

  @override
  State<DesktopEntriesPage> createState() => _DesktopEntriesPageState();
}

class _DesktopEntriesPageState extends State<DesktopEntriesPage> {
  final DesktopEntriesController _controller = DesktopEntriesController();
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

  Future<void> _openEditor({DesktopEntry? entry}) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => DesktopEntryEditorPage(
          entry: entry,
          existingIds: _controller.entries.map((DesktopEntry e) => e.id).toList(),
          installedIds: _controller.installedIds,
        ),
      ),
    );
    if (changed == true) await _controller.load();
  }

  Future<void> _delete(DesktopEntry entry) async {
    final String name = _controller.displayName(entry);
    if (entry.isUser) {
      final bool confirmed = await showConfirmDialog(
        context,
        title: 'Delete "$name"?',
        icon: M3EIcons.delete_outline,
        message: entry.isOverride
            ? 'This removes your personal copy. The original system launcher '
                  'will become visible again.'
            : 'The launcher file will be permanently deleted.',
        content: _PathText(entry.path),
        confirmLabel: 'Delete',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      try {
        await _controller.repository.deleteUserEntry(entry);
        if (!entry.isOverride) await MimeApps.instance.forget(entry.id);
        if (mounted) showSnack(context, 'Deleted "$name"');
      } on Object catch (e) {
        if (mounted) showInfoDialog(context, title: 'Could not delete', message: '$e');
      }
      await _controller.load();
      return;
    }

    // System / Flatpak / Snap entries: hiding is safe and reversible; deleting
    // the file needs administrator rights and is undone by package updates.
    final _SystemDeleteChoice? choice = await M3EDialog.show<_SystemDeleteChoice>(
      context,
      dialog: Builder(
        builder: (BuildContext context) => M3EDialog(
          title: 'Remove "$name"?',
          icon: const Icon(M3EIcons.delete_outline),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'This is a ${entry.source.label.toLowerCase()} launcher installed by a package. '
                'You can hide it just for you (recommended, reversible), or delete the file '
                'for everyone. A package update may restore a deleted file.',
              ),
              const SizedBox(height: 12),
              _PathText(entry.path),
            ],
          ),
          actions: <Widget>[
            M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            if (_controller.repository.canModifySystemFile(entry))
              M3EButton.text(
                onPressed: () => Navigator.of(context).pop(_SystemDeleteChoice.deleteFile),
                child: const Text('Delete file (admin)'),
              ),
            M3EButton.tonal(
              onPressed: () => Navigator.of(context).pop(_SystemDeleteChoice.hide),
              child: const Text('Hide for me'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _SystemDeleteChoice.hide) {
      try {
        await _controller.repository.hideWithOverride(entry);
        if (mounted) showSnack(context, '"$name" is now hidden from launchers');
      } on Object catch (e) {
        if (mounted) showInfoDialog(context, title: 'Could not hide', message: '$e');
      }
    } else {
      final bool confirmed = await showConfirmDialog(
        context,
        title: 'Delete system file?',
        message:
            'The file will be deleted for all users. This cannot be undone '
            'from Kalanjiyam (reinstalling the package restores it).',
        content: _PathText(entry.path),
        confirmLabel: 'Delete',
        destructive: true,
        icon: M3EIcons.warning_amber,
      );
      if (!confirmed || !mounted) return;
      await runWithLog(
        context,
        title: 'Deleting launcher',
        successMessage: 'Deleted "$name"',
        task: (void Function(String) log) => _controller.repository.deleteSystemEntry(entry, onLine: log),
      );
    }
    await _controller.load();
  }

  Future<void> _launch(DesktopEntry entry) async {
    final String? gtkLaunch = ShellEnv.instance.which('gtk-launch') ?? ShellEnv.instance.which('gtk4-launch');
    final String id = entry.id.replaceAll(RegExp(r'\.desktop$'), '');
    if (gtkLaunch != null) {
      final CommandResult result = await CommandRunner.run(
        gtkLaunch,
        <String>[id],
        timeout: const Duration(seconds: 10),
        cLocale: false,
      );
      if (!mounted) return;
      if (!result.ok && !result.timedOut) {
        showInfoDialog(context, title: 'Could not launch', message: result.errorSummary);
      } else {
        showSnack(context, 'Launching ${_controller.displayName(entry)}…');
      }
      return;
    }
    if (mounted) {
      showInfoDialog(
        context,
        title: 'Launch not available',
        message: 'Install "gtk-launch" (part of GTK 3) to start launchers from here.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, _) {
        final List<DesktopEntry> visible = _controller.visible;
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: M3EAppBar.top(
            titleText: 'Launchers',
            subtitleText: _controller.entries.isEmpty
                ? 'Desktop entries'
                : '${_controller.entries.length} desktop entries',
            actions: <Widget>[
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.refresh),
                tooltip: 'Reload',
                onPressed: _controller.loading ? null : _controller.load,
              ),
              const SizedBox(width: 8),
            ],
          ),
          floatingActionButton: M3EExtendedFab(
            label: 'New launcher',
            icon: const Icon(M3EIcons.add),
            onPressed: () => _openEditor(),
          ),
          body: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SearchField(controller: _search, hint: 'Search launchers'),
              ),
              FilterChipBar<EntryFilter>(
                selected: _controller.filter,
                onSelected: (EntryFilter f) => _controller.filter = f,
                options: <FilterOption<EntryFilter>>[
                  FilterOption<EntryFilter>(
                    value: EntryFilter.all,
                    label: 'All',
                    count: _controller.count(EntryFilter.all),
                  ),
                  FilterOption<EntryFilter>(
                    value: EntryFilter.user,
                    label: 'Mine',
                    icon: M3EIcons.person_outline,
                    count: _controller.count(EntryFilter.user),
                  ),
                  FilterOption<EntryFilter>(
                    value: EntryFilter.system,
                    label: 'System',
                    icon: M3EIcons.dns_outlined,
                    count: _controller.count(EntryFilter.system),
                  ),
                  FilterOption<EntryFilter>(
                    value: EntryFilter.hidden,
                    label: 'Hidden',
                    icon: M3EIcons.visibility_off_outlined,
                    count: _controller.count(EntryFilter.hidden),
                  ),
                  FilterOption<EntryFilter>(
                    value: EntryFilter.broken,
                    label: 'Broken',
                    icon: M3EIcons.link_off,
                    count: _controller.count(EntryFilter.broken),
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

  Widget _buildBody(List<DesktopEntry> visible) {
    if (_controller.loading && _controller.entries.isEmpty) {
      return const LoadingView(message: 'Reading launchers…');
    }
    if (_controller.error != null) {
      return ErrorView(message: _controller.error!, onRetry: _controller.load);
    }
    if (visible.isEmpty) {
      return const EmptyView(
        icon: M3EIcons.apps_outlined,
        title: 'No launchers here',
        message: 'Try another filter or search term.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      itemCount: visible.length,
      itemBuilder: (BuildContext context, int index) {
        final DesktopEntry entry = visible[index];
        return _EntryTile(
          key: ValueKey<String>(entry.path),
          entry: entry,
          name: _controller.displayName(entry),
          comment: _controller.displayComment(entry),
          iconPath: _controller.iconPath(entry),
          onEdit: () => _openEditor(entry: entry),
          onDelete: () => _delete(entry),
          onLaunch: () => _launch(entry),
        );
      },
    );
  }
}

enum _SystemDeleteChoice { hide, deleteFile }

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.name,
    required this.comment,
    required this.iconPath,
    required this.onEdit,
    required this.onDelete,
    required this.onLaunch,
  });

  final DesktopEntry entry;
  final String name;
  final String? comment;
  final String? iconPath;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> tags = <Widget>[
      if (entry.isOverride)
        TagChip(
          label: 'Override',
          icon: M3EIcons.layers_outlined,
          color: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
        )
      else
        TagChip(label: entry.source.label),
      if (entry.isHiddenFromMenus)
        TagChip(
          label: 'Hidden',
          icon: M3EIcons.visibility_off_outlined,
          color: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
        ),
      if (entry.isBroken)
        TagChip(
          label: 'Broken',
          icon: M3EIcons.link_off,
          color: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
        ),
    ];
    final String supporting = <String>[
      if (comment != null && comment!.isNotEmpty) comment!,
      if (entry.isBroken) 'Missing: ${entry.missingProgram}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: M3EListItem(
        headline: name,
        supportingText: supporting.isEmpty ? Fmt.tildify(entry.path, ShellEnv.instance.home) : supporting,
        leading: Opacity(
          opacity: entry.isHiddenFromMenus ? 0.5 : 1,
          child: FileIcon(path: iconPath, size: 40),
        ),
        onTap: onEdit,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ...tags.expand((Widget t) => <Widget>[t, const SizedBox(width: 6)]),
            M3EMenu.entries(
              position: M3EMenuAnchorPosition.bottomEnd,
              anchorBuilder: (BuildContext context, VoidCallback open) => M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.more_vert),
                tooltip: 'More',
                onPressed: open,
              ),
              entries: <M3EMenuEntry>[
                M3EMenuEntry(label: 'Edit', leading: const Icon(M3EIcons.edit_outlined), onPressed: onEdit),
                if (entry.type == 'Application' && !entry.isBroken)
                  M3EMenuEntry(label: 'Launch', leading: const Icon(M3EIcons.play_arrow_outlined), onPressed: onLaunch),
                M3EMenuEntry(
                  label: entry.isUser ? 'Delete' : 'Remove…',
                  leading: const Icon(M3EIcons.delete_outline),
                  isDestructive: true,
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PathText extends StatelessWidget {
  const _PathText(this.path);

  final String path;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: SelectableText(path, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
    );
  }
}
