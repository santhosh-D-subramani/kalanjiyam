import 'package:file_selector/file_selector.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../core/system/open_external.dart';
import '../../core/system/shell_env.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import 'caches_view.dart';
import 'data/disk_scanner.dart';
import 'storage_controller.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  final StorageController _controller = StorageController();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _controller.loadDisks();
  }

  @override
  void dispose() {
    _controller.cancelScan();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chooseRoot() async {
    final String? dir = await getDirectoryPath(
      initialDirectory: _controller.root,
      confirmButtonText: 'Analyse this folder',
    );
    if (dir == null) return;
    _controller.root = dir;
    await _controller.scan();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, _) {
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: M3EAppBar.top(
            titleText: 'Storage',
            subtitleText: 'Analysing ${Fmt.tildify(_controller.root, ShellEnv.instance.home)}',
            actions: <Widget>[
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(M3EIcons.drive_folder_upload_outlined),
                tooltip: 'Choose folder to analyse',
                onPressed: _controller.scanning ? null : _chooseRoot,
              ),
              const SizedBox(width: 4),
              if (_controller.scanning)
                M3EButton.tonal(
                  onPressed: _controller.cancelScan,
                  icon: const Icon(M3EIcons.stop_circle_outlined),
                  label: const Text('Stop'),
                )
              else
                M3EButton.filled(
                  onPressed: _controller.scan,
                  icon: Icon(_controller.result == null ? M3EIcons.radar : M3EIcons.refresh),
                  label: Text(_controller.result == null ? 'Scan' : 'Rescan'),
                ),
              const SizedBox(width: 12),
            ],
          ),
          body: Column(
            children: <Widget>[
              M3ETabs(
                selectedIndex: _tab,
                onTabSelected: (int i) => setState(() => _tab = i),
                tabs: const <M3ETab>[
                  M3ETab(label: 'Overview', icon: Icon(M3EIcons.donut_large)),
                  M3ETab(label: 'Folders', icon: Icon(M3EIcons.folder_outlined)),
                  M3ETab(label: 'Large files', icon: Icon(M3EIcons.description_outlined)),
                  M3ETab(label: 'Caches', icon: Icon(M3EIcons.cleaning_services_outlined)),
                ],
              ),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: <Widget>[
                    _OverviewTab(controller: _controller, onOpenTab: (int i) => setState(() => _tab = i)),
                    _FoldersTab(controller: _controller),
                    _LargeFilesTab(controller: _controller),
                    const CachesView(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- overview

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.controller, required this.onOpenTab});

  final StorageController controller;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final ScanResult? result = controller.result;
    final DirNode? root = result?.root;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SectionCard(
                title: 'Disks',
                trailing: controller.loadingDisks ? const M3ELoadingIndicator(size: 28) : null,
                child: controller.disks.isEmpty && !controller.loadingDisks
                    ? Text('No disks found.', style: text.bodyMedium)
                    : Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[for (final DiskInfo d in controller.disks) _DiskCard(disk: d)],
                      ),
              ),
              const SizedBox(height: 16),
              if (controller.scanning)
                SectionCard(child: _ScanningBanner(controller: controller))
              else if (controller.error != null)
                SectionCard(
                  child: ErrorView(message: controller.error!, onRetry: controller.scan),
                )
              else if (root == null)
                SectionCard(
                  child: EmptyView(
                    icon: M3EIcons.radar,
                    title: 'Find what is using your space',
                    message:
                        'Scan ${Fmt.tildify(controller.root, ShellEnv.instance.home)} to see '
                        'the biggest folders and files. Nothing is changed until you choose to delete.',
                    action: M3EButton.filled(
                      onPressed: controller.scan,
                      icon: const Icon(M3EIcons.radar),
                      label: const Text('Scan now'),
                    ),
                  ),
                )
              else ...<Widget>[
                SectionCard(
                  title: 'Biggest folders',
                  subtitle:
                      '${Fmt.tildify(root.path, ShellEnv.instance.home)} uses ${Fmt.bytes(root.size)}'
                      ' · scanned in ${(result!.duration.inMilliseconds / 1000).toStringAsFixed(1)} s'
                      '${result.errors > 0 ? ' · ${Fmt.plural(result.errors, 'item')} not readable' : ''}',
                  trailing: M3EButton.text(onPressed: () => onOpenTab(1), child: const Text('Browse')),
                  child: Column(
                    children: <Widget>[
                      for (final DirNode n in root.children.take(8))
                        _SizeBarRow(
                          icon: M3EIcons.folder,
                          title: n.name,
                          size: n.size,
                          fraction: root.size == 0 ? 0 : n.size / root.size,
                          onTap: () {
                            controller.open(n);
                            onOpenTab(1);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Biggest files',
                  trailing: M3EButton.text(onPressed: () => onOpenTab(2), child: const Text('See all')),
                  child: Column(
                    children: <Widget>[
                      for (final LargeFile f in controller.largeFiles(0).take(6))
                        _SizeBarRow(
                          icon: _iconForFile(f.name),
                          title: f.name,
                          subtitle: Fmt.tildify(f.directory, ShellEnv.instance.home),
                          size: f.size,
                          fraction: root.size == 0 ? 0 : f.size / root.size,
                        ),
                      if (controller.largeFiles(0).isEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'No files over ${Fmt.bytes(StorageController.scanMinFileBytes)}.',
                            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SectionCard(
                title: 'Developer & system caches',
                subtitle: 'npm, pub, Gradle, Cargo, pip, pacman and more',
                trailing: M3EButton.tonal(
                  onPressed: () => onOpenTab(3),
                  icon: const Icon(M3EIcons.cleaning_services_outlined),
                  label: const Text('Open'),
                ),
                child: Text(
                  'Caches are safe to clear: tools download what they need again.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.disk});

  final DiskInfo disk;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool critical = disk.fraction >= 0.9;
    return Container(
      width: 290,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: critical ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                disk.mountPoint == '/' ? M3EIcons.storage : M3EIcons.save_outlined,
                color: critical ? scheme.onErrorContainer : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  disk.mountPoint,
                  style: text.titleMedium?.copyWith(color: critical ? scheme.onErrorContainer : null),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TagChip(label: disk.fsType),
            ],
          ),
          const SizedBox(height: 14),
          M3EProgressIndicator.linearWavy(value: disk.fraction, color: critical ? scheme.error : null),
          const SizedBox(height: 10),
          Text(
            '${Fmt.bytes(disk.used)} of ${Fmt.bytes(disk.size)} used',
            style: text.bodyMedium?.copyWith(color: critical ? scheme.onErrorContainer : null),
          ),
          Text(
            '${Fmt.bytes(disk.available)} free · ${disk.source}',
            style: text.bodySmall?.copyWith(color: critical ? scheme.onErrorContainer : scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _ScanningBanner extends StatelessWidget {
  const _ScanningBanner({required this.controller});

  final StorageController controller;

  @override
  Widget build(BuildContext context) {
    final ScanProgress? p = controller.progress;
    return LoadingView(
      message: 'Scanning ${Fmt.tildify(controller.root, ShellEnv.instance.home)}…',
      detail: p == null ? null : '${p.folders} folders measured · ${p.files} large files found',
    );
  }
}

class _SizeBarRow extends StatelessWidget {
  const _SizeBarRow({
    required this.icon,
    required this.title,
    required this.size,
    required this.fraction,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int size;
  final double fraction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Row(
          children: <Widget>[
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: text.bodyLarge, overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 6),
                  M3EProgressIndicator.linear(value: fraction.clamp(0.0, 1.0), linearSize: M3EProgressIndicatorSize.s),
                ],
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 80,
              child: Text(Fmt.bytes(size), textAlign: TextAlign.end, style: text.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- folders

class _FoldersTab extends StatefulWidget {
  const _FoldersTab({required this.controller});

  final StorageController controller;

  @override
  State<_FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends State<_FoldersTab> {
  final Set<String> _selected = <String>{};

  StorageController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    if (c.scanning) return _ScanningBanner(controller: c);
    final DirNode? current = c.current;
    if (current == null) {
      return EmptyView(
        icon: M3EIcons.folder_outlined,
        title: 'No scan yet',
        message: 'Scan a folder to browse it by size.',
        action: M3EButton.filled(onPressed: c.scan, icon: const Icon(M3EIcons.radar), label: const Text('Scan')),
      );
    }
    // Keep the selection valid after navigation or deletion.
    _selected.removeWhere((String p) => !c.items.any((FolderItem i) => i.path == p));
    final int selectedBytes = c.items
        .where((FolderItem i) => _selected.contains(i.path))
        .fold<int>(0, (int s, FolderItem i) => s + i.size);

    final List<DirNode> chain = <DirNode>[];
    for (DirNode? n = current; n != null; n = n.parent) {
      chain.insert(0, n);
    }

    return Column(
      children: <Widget>[
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: <Widget>[
              M3EIconButton(
                variant: M3EIconButtonVariant.tonal,
                icon: const Icon(M3EIcons.arrow_upward),
                tooltip: 'Up one level',
                onPressed: current.parent == null ? null : () => c.up(),
              ),
              const SizedBox(width: 8),
              for (int i = 0; i < chain.length; i++) ...<Widget>[
                Center(
                  child: M3EChip(
                    label: i == 0 ? Fmt.tildify(chain[i].path, ShellEnv.instance.home) : chain[i].name,
                    type: M3EChipType.filter,
                    selected: i == chain.length - 1,
                    onPressed: () => c.open(chain[i]),
                  ),
                ),
                if (i < chain.length - 1) Icon(M3EIcons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${Fmt.bytes(current.size)} · ${Fmt.plural(c.items.length, 'item')}',
                  style: text.titleSmall,
                ),
              ),
              M3EButton.text(onPressed: () => openExternally(current.path), child: const Text('Open in file manager')),
            ],
          ),
        ),
        Expanded(
          child: c.items.isEmpty && !c.loadingItems
              ? const EmptyView(icon: M3EIcons.folder_off_outlined, title: 'Empty folder')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: c.items.length,
                  itemBuilder: (BuildContext context, int i) {
                    final FolderItem item = c.items[i];
                    final bool protected = StorageController.isProtected(item.path);
                    return _SelectableSizeRow(
                      key: ValueKey<String>(item.path),
                      icon: item.isDir ? M3EIcons.folder : _iconForFile(item.name),
                      title: item.name,
                      subtitle: item.isDir
                          ? '${Fmt.plural(item.node?.children.length ?? 0, 'folder')} inside'
                          : (item.modified == null ? null : 'Modified ${Fmt.date(item.modified)}'),
                      size: item.size,
                      fraction: current.size == 0 ? 0 : item.size / current.size,
                      selected: _selected.contains(item.path),
                      selectable: !protected,
                      onSelect: (bool v) => setState(() => v ? _selected.add(item.path) : _selected.remove(item.path)),
                      onTap: item.isDir && item.node != null ? () => c.open(item.node!) : null,
                      trailingIcon: item.isDir ? M3EIcons.chevron_right : null,
                    );
                  },
                ),
        ),
        if (_selected.isNotEmpty)
          _SelectionBar(
            count: _selected.length,
            bytes: selectedBytes,
            onClear: () => setState(_selected.clear),
            onTrash: () => _delete(toTrash: true),
            onDelete: () => _delete(toTrash: false),
          ),
      ],
    );
  }

  Future<void> _delete({required bool toTrash}) async {
    final List<String> paths = _selected.toList();
    final bool ok = await confirmDeletion(
      context,
      paths,
      toTrash: toTrash,
      totalBytes: c.items
          .where((FolderItem i) => _selected.contains(i.path))
          .fold<int>(0, (int s, FolderItem i) => s + i.size),
    );
    if (!ok || !mounted) return;
    final DeleteOutcome outcome = await c.delete(paths, toTrash: toTrash);
    if (!mounted) return;
    setState(() => _selected.removeAll(outcome.removed));
    reportDeletion(context, outcome, toTrash: toTrash);
  }
}

// ------------------------------------------------------------- large files

class _LargeFilesTab extends StatefulWidget {
  const _LargeFilesTab({required this.controller});

  final StorageController controller;

  @override
  State<_LargeFilesTab> createState() => _LargeFilesTabState();
}

class _LargeFilesTabState extends State<_LargeFilesTab> {
  final Set<String> _selected = <String>{};
  static const List<int> _thresholdsMb = <int>[50, 100, 500, 1024];

  StorageController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    if (c.scanning) return _ScanningBanner(controller: c);
    if (c.result == null) {
      return EmptyView(
        icon: M3EIcons.description_outlined,
        title: 'No scan yet',
        message: 'Scan a folder to list its largest files.',
        action: M3EButton.filled(onPressed: c.scan, icon: const Icon(M3EIcons.radar), label: const Text('Scan')),
      );
    }
    final AppSettings settings = AppSettings.instance;
    final int thresholdMb = _thresholdsMb.contains(settings.bigFileThresholdMb) ? settings.bigFileThresholdMb : 100;
    final List<LargeFile> files = c.largeFiles(thresholdMb * 1024 * 1024);
    _selected.removeWhere((String p) => !files.any((LargeFile f) => f.path == p));
    final int selectedBytes = files
        .where((LargeFile f) => _selected.contains(f.path))
        .fold<int>(0, (int s, LargeFile f) => s + f.size);
    final int total = files.fold<int>(0, (int s, LargeFile f) => s + f.size);

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('Larger than', style: text.titleSmall),
              // The segmented button fills its width, so give it a fixed one.
              SizedBox(
                width: 400,
                child: M3ESegmentedButton<int>(
                  segments: <M3ESegment<int>>[
                    for (final int mb in _thresholdsMb)
                      M3ESegment<int>(value: mb, label: mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB'),
                  ],
                  selected: <int>{thresholdMb},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<int> v) => setState(() => settings.bigFileThresholdMb = v.first),
                ),
              ),
              Text('${Fmt.plural(files.length, 'file')} · ${Fmt.bytes(total)}', style: text.bodyMedium),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? const EmptyView(icon: M3EIcons.check_circle_outline, title: 'No files this large')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: files.length,
                  itemBuilder: (BuildContext context, int i) {
                    final LargeFile f = files[i];
                    return _SelectableSizeRow(
                      key: ValueKey<String>(f.path),
                      icon: _iconForFile(f.name),
                      title: f.name,
                      subtitle: '${Fmt.tildify(f.directory, ShellEnv.instance.home)} · ${Fmt.date(f.modified)}',
                      size: f.size,
                      fraction: files.first.size == 0 ? 0 : f.size / files.first.size,
                      selected: _selected.contains(f.path),
                      selectable: !StorageController.isProtected(f.path),
                      onSelect: (bool v) => setState(() => v ? _selected.add(f.path) : _selected.remove(f.path)),
                      onTap: () => openExternally(f.directory),
                      trailingIcon: M3EIcons.open_in_new,
                      trailingTooltip: 'Open containing folder',
                    );
                  },
                ),
        ),
        if (_selected.isNotEmpty)
          _SelectionBar(
            count: _selected.length,
            bytes: selectedBytes,
            onClear: () => setState(_selected.clear),
            onTrash: () => _delete(toTrash: true, bytes: selectedBytes),
            onDelete: () => _delete(toTrash: false, bytes: selectedBytes),
          ),
      ],
    );
  }

  Future<void> _delete({required bool toTrash, required int bytes}) async {
    final List<String> paths = _selected.toList();
    final bool ok = await confirmDeletion(context, paths, toTrash: toTrash, totalBytes: bytes);
    if (!ok || !mounted) return;
    final DeleteOutcome outcome = await c.delete(paths, toTrash: toTrash);
    if (!mounted) return;
    setState(() => _selected.removeAll(outcome.removed));
    reportDeletion(context, outcome, toTrash: toTrash);
  }
}

// ------------------------------------------------------------ shared rows

class _SelectableSizeRow extends StatelessWidget {
  const _SelectableSizeRow({
    super.key,
    required this.icon,
    required this.title,
    required this.size,
    required this.fraction,
    required this.selected,
    required this.selectable,
    required this.onSelect,
    this.subtitle,
    this.onTap,
    this.trailingIcon,
    this.trailingTooltip,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int size;
  final double fraction;
  final bool selected;
  final bool selectable;
  final ValueChanged<bool> onSelect;
  final VoidCallback? onTap;
  final IconData? trailingIcon;
  final String? trailingTooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.secondaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap ?? (selectable ? () => onSelect(!selected) : null),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(
              children: <Widget>[
                M3ECheckbox(
                  value: selected,
                  onChanged: selectable ? (bool? v) => onSelect(v ?? false) : null,
                  semanticLabel: 'Select $title',
                ),
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: text.bodyLarge, overflow: TextOverflow.ellipsis),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 6),
                      M3EProgressIndicator.linear(
                        value: fraction.clamp(0.0, 1.0),
                        linearSize: M3EProgressIndicatorSize.s,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 84,
                  child: Text(Fmt.bytes(size), textAlign: TextAlign.end, style: text.titleSmall),
                ),
                if (trailingIcon != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: trailingTooltip == null
                        ? Icon(trailingIcon, color: scheme.onSurfaceVariant)
                        : Tooltip(
                            message: trailingTooltip,
                            child: Icon(trailingIcon, color: scheme.onSurfaceVariant),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.bytes,
    required this.onClear,
    required this.onTrash,
    required this.onDelete,
  });

  final int count;
  final int bytes;
  final VoidCallback onClear;
  final VoidCallback onTrash;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(28)),
      child: Row(
        children: <Widget>[
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(M3EIcons.close),
            tooltip: 'Clear selection',
            onPressed: onClear,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('$count selected · ${Fmt.bytes(bytes)}', style: text.titleSmall)),
          M3EButton.tonal(
            onPressed: onTrash,
            icon: const Icon(M3EIcons.delete_outline),
            label: const Text('Move to Trash'),
          ),
          const SizedBox(width: 8),
          M3EButton(
            onPressed: onDelete,
            decoration: destructiveButtonDecoration(scheme),
            icon: const Icon(M3EIcons.delete_forever_outlined),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

/// Confirmation shared by the folder and large-file views.
Future<bool> confirmDeletion(
  BuildContext context,
  List<String> paths, {
  required bool toTrash,
  required int totalBytes,
}) {
  final String home = ShellEnv.instance.home;
  final List<String> shown = paths.take(8).map((String p) => Fmt.tildify(p, home)).toList();
  final int more = paths.length - shown.length;
  return showConfirmDialog(
    context,
    title: toTrash
        ? 'Move ${Fmt.plural(paths.length, 'item')} to Trash?'
        : 'Delete ${Fmt.plural(paths.length, 'item')} permanently?',
    icon: toTrash ? M3EIcons.delete_outline : M3EIcons.delete_forever_outlined,
    destructive: !toTrash,
    confirmLabel: toTrash ? 'Move to Trash' : 'Delete permanently',
    message: toTrash
        ? 'About ${Fmt.bytes(totalBytes)}. You can restore items from the Trash; space is freed when the Trash is emptied.'
        : 'This frees about ${Fmt.bytes(totalBytes)} and cannot be undone.',
    content: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${shown.join('\n')}${more > 0 ? '\n… and $more more' : ''}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    ),
    requireCheckbox: toTrash ? null : 'I understand this cannot be undone',
  );
}

void reportDeletion(BuildContext context, DeleteOutcome outcome, {required bool toTrash}) {
  if (outcome.failures.isEmpty) {
    showSnack(
      context,
      toTrash
          ? 'Moved ${Fmt.plural(outcome.removed.length, 'item')} to Trash'
          : 'Deleted ${Fmt.plural(outcome.removed.length, 'item')} · ${Fmt.bytes(outcome.freed)} freed',
    );
    return;
  }
  final String home = ShellEnv.instance.home;
  showInfoDialog(
    context,
    title: outcome.removed.isEmpty ? 'Nothing was removed' : 'Some items could not be removed',
    icon: M3EIcons.error_outline,
    message: <String>[
      if (outcome.removed.isNotEmpty) 'Removed ${Fmt.plural(outcome.removed.length, 'item')}.\n',
      for (final MapEntry<String, String> f in outcome.failures.entries) '${Fmt.tildify(f.key, home)}: ${f.value}',
    ].join('\n'),
  );
}

IconData _iconForFile(String name) {
  final String lower = name.toLowerCase();
  final int dot = lower.lastIndexOf('.');
  final String ext = dot == -1 ? '' : lower.substring(dot + 1);
  return switch (ext) {
    'mp4' || 'mkv' || 'webm' || 'avi' || 'mov' => M3EIcons.movie_outlined,
    'mp3' || 'flac' || 'ogg' || 'wav' || 'm4a' || 'opus' => M3EIcons.music_note_outlined,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'heic' => M3EIcons.image_outlined,
    'zip' || 'tar' || 'gz' || 'xz' || 'zst' || '7z' || 'rar' || 'bz2' => M3EIcons.folder_zip_outlined,
    'iso' || 'img' || 'qcow2' || 'vdi' || 'vmdk' || 'raw' => M3EIcons.album_outlined,
    'appimage' || 'deb' || 'rpm' || 'flatpak' || 'pkg' => M3EIcons.install_desktop,
    'pdf' => M3EIcons.picture_as_pdf_outlined,
    'log' || 'txt' => M3EIcons.article_outlined,
    'apk' || 'aab' => M3EIcons.android,
    _ => M3EIcons.insert_drive_file_outlined,
  };
}
