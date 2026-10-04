import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/system/command_runner.dart';
import '../../core/system/shell_env.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import 'data/desktop_entry.dart';
import 'data/desktop_entry_repository.dart';
import 'data/icon_resolver.dart';
import 'data/key_file.dart';
import 'data/mime_apps.dart';
import 'widgets/entry_icon.dart';

const List<String> _mainCategories = <String>[
  'AudioVideo',
  'Audio',
  'Video',
  'Development',
  'Education',
  'Game',
  'Graphics',
  'Network',
  'Office',
  'Science',
  'Settings',
  'System',
  'Utility',
];

const String _actionGroupPrefix = 'Desktop Action ';

class _ActionDraft {
  _ActionDraft({required this.id, String name = '', String exec = '', String icon = ''})
    : name = TextEditingController(text: name),
      exec = TextEditingController(text: exec),
      icon = TextEditingController(text: icon);

  final String id;
  final TextEditingController name;
  final TextEditingController exec;
  final TextEditingController icon;

  void dispose() {
    name.dispose();
    exec.dispose();
    icon.dispose();
  }
}

/// Edit an existing desktop entry, or create a new one when [entry] is null.
class DesktopEntryEditorPage extends StatefulWidget {
  const DesktopEntryEditorPage({super.key, required this.entry, required this.existingIds, required this.installedIds});

  final DesktopEntry? entry;
  final List<String> existingIds;
  final Set<String> installedIds;

  @override
  State<DesktopEntryEditorPage> createState() => _DesktopEntryEditorPageState();
}

class _DesktopEntryEditorPageState extends State<DesktopEntryEditorPage> {
  final DesktopEntryRepository _repo = DesktopEntryRepository.instance;

  late KeyFile _file;
  late final String _originalText;
  int _tab = 0;
  bool _saving = false;

  // General
  final TextEditingController _name = TextEditingController();
  final TextEditingController _genericName = TextEditingController();
  final TextEditingController _comment = TextEditingController();
  final TextEditingController _exec = TextEditingController();
  final TextEditingController _icon = TextEditingController();
  final TextEditingController _workDir = TextEditingController();
  final TextEditingController _keywords = TextEditingController();
  bool _terminal = false;
  bool _noDisplay = false;
  List<String> _categories = <String>[];

  // Advanced
  String _type = 'Application';
  final TextEditingController _url = TextEditingController();
  final TextEditingController _tryExec = TextEditingController();
  final TextEditingController _wmClass = TextEditingController();
  bool _startupNotify = false;
  bool _prefersNonDefaultGpu = false;
  List<String> _mimeTypes = <String>[];
  final List<_ActionDraft> _actions = <_ActionDraft>[];

  // Default applications: mime → is this launcher the default.
  final Map<String, bool> _wantDefault = <String, bool>{};
  Map<String, String?> _currentDefaults = <String, String?>{};

  // Source
  final TextEditingController _raw = TextEditingController();

  bool get _isNew => widget.entry == null;

  String get _desktopId => widget.entry?.id ?? '';

  @override
  void initState() {
    super.initState();
    if (widget.entry != null) {
      _file = widget.entry!.file.copy();
    } else {
      _file = KeyFile.empty()
        ..set(kDesktopEntryGroup, 'Type', 'Application')
        ..set(kDesktopEntryGroup, 'Terminal', 'false');
    }
    _fileToForm();
    // Normalise once so "unchanged" compares equal to what Save would write.
    _formToFile();
    _originalText = _file.serialize();
    _loadDefaults();
    IconResolver.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _genericName,
      _comment,
      _exec,
      _icon,
      _workDir,
      _keywords,
      _url,
      _tryExec,
      _wmClass,
      _raw,
    ]) {
      c.dispose();
    }
    for (final _ActionDraft a in _actions) {
      a.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDefaults() async {
    if (_isNew || _mimeTypes.isEmpty) return;
    final Map<String, String?> defaults = await MimeApps.instance.defaultsFor(_mimeTypes, widget.installedIds);
    if (!mounted) return;
    setState(() {
      _currentDefaults = defaults;
      for (final String m in _mimeTypes) {
        _wantDefault[m] = defaults[m] == _desktopId;
      }
    });
  }

  // ------------------------------------------------------------ form <-> file

  String _str(String key) => KeyFile.unescape(_file.get(kDesktopEntryGroup, key) ?? '');

  bool _bool(String key) => (_file.get(kDesktopEntryGroup, key) ?? '').trim().toLowerCase() == 'true';

  void _fileToForm() {
    _name.text = _str('Name');
    _genericName.text = _str('GenericName');
    _comment.text = _str('Comment');
    _exec.text = _file.get(kDesktopEntryGroup, 'Exec') ?? '';
    _icon.text = _str('Icon');
    _workDir.text = _str('Path');
    _keywords.text = KeyFile.splitList(_file.get(kDesktopEntryGroup, 'Keywords')).join(', ');
    _terminal = _bool('Terminal');
    _noDisplay = _bool('NoDisplay');
    _categories = KeyFile.splitList(_file.get(kDesktopEntryGroup, 'Categories'));
    _type = _str('Type').isEmpty ? 'Application' : _str('Type');
    _url.text = _str('URL');
    _tryExec.text = _str('TryExec');
    _wmClass.text = _str('StartupWMClass');
    _startupNotify = _bool('StartupNotify');
    _prefersNonDefaultGpu = _bool('PrefersNonDefaultGPU');
    _mimeTypes = KeyFile.splitList(_file.get(kDesktopEntryGroup, 'MimeType'));
    for (final String m in _mimeTypes) {
      _wantDefault.putIfAbsent(m, () => false);
    }
    for (final _ActionDraft a in _actions) {
      a.dispose();
    }
    _actions
      ..clear()
      ..addAll(
        KeyFile.splitList(_file.get(kDesktopEntryGroup, 'Actions')).map((String id) {
          final String group = '$_actionGroupPrefix$id';
          return _ActionDraft(
            id: id,
            name: KeyFile.unescape(_file.get(group, 'Name') ?? ''),
            exec: _file.get(group, 'Exec') ?? '',
            icon: KeyFile.unescape(_file.get(group, 'Icon') ?? ''),
          );
        }),
      );
  }

  void _setString(String key, String value, {bool escape = true}) {
    final String v = value.trim();
    final String? raw = _file.get(kDesktopEntryGroup, key);
    // Unchanged field: keep the original text byte for byte (it may contain
    // escapes that do not round-trip, such as "\;").
    if (raw != null && (escape ? KeyFile.unescape(raw).trim() : raw.trim()) == v) return;
    _file.set(kDesktopEntryGroup, key, v.isEmpty ? null : (escape ? KeyFile.escape(v) : v));
  }

  void _setBool(String key, bool value, {bool omitWhenFalse = true}) {
    _file.set(
      kDesktopEntryGroup,
      key,
      value ? 'true' : (omitWhenFalse && _file.get(kDesktopEntryGroup, key) == null ? null : 'false'),
    );
  }

  void _formToFile() {
    _setString('Type', _type);
    _setString('Name', _name.text);
    _setString('GenericName', _genericName.text);
    _setString('Comment', _comment.text);
    _setString('Icon', _icon.text);
    if (_type == 'Link') {
      _setString('URL', _url.text);
    } else {
      _setString('Exec', _exec.text, escape: false);
      _setString('TryExec', _tryExec.text);
      _setString('Path', _workDir.text);
      _setBool('Terminal', _terminal);
      _setString('StartupWMClass', _wmClass.text);
      _setBool('StartupNotify', _startupNotify);
      _setBool('PrefersNonDefaultGPU', _prefersNonDefaultGpu);
      _file.set(kDesktopEntryGroup, 'MimeType', KeyFile.joinList(_mimeTypes));
    }
    _setBool('NoDisplay', _noDisplay);
    _file.set(kDesktopEntryGroup, 'Categories', KeyFile.joinList(_categories));
    final String? rawKeywords = _file.get(kDesktopEntryGroup, 'Keywords');
    if (KeyFile.splitList(rawKeywords).join(', ') != _keywords.text.trim()) {
      _file.set(
        kDesktopEntryGroup,
        'Keywords',
        KeyFile.joinList(_keywords.text.split(',').map((String s) => s.trim())),
      );
    }

    // Actions: keep extra keys (translations) of surviving groups.
    final Set<String> keep = <String>{};
    for (final _ActionDraft a in _actions) {
      if (a.name.text.trim().isEmpty) continue;
      keep.add(a.id);
      final String group = '$_actionGroupPrefix${a.id}';
      _file.set(group, 'Name', KeyFile.escape(a.name.text.trim()));
      _file.set(group, 'Exec', a.exec.text.trim().isEmpty ? null : a.exec.text.trim());
      _file.set(group, 'Icon', a.icon.text.trim().isEmpty ? null : KeyFile.escape(a.icon.text.trim()));
    }
    for (final String g in _file.groupNames) {
      if (g.startsWith(_actionGroupPrefix) && !keep.contains(g.substring(_actionGroupPrefix.length))) {
        _file.removeGroup(g);
      }
    }
    _file.set(kDesktopEntryGroup, 'Actions', KeyFile.joinList(keep));
  }

  void _onTabSelected(int index) {
    if (index == _tab) return;
    setState(() {
      if (_tab == 2) {
        _file = KeyFile.parse(_raw.text);
        _fileToForm();
      }
      if (index == 2) {
        _formToFile();
        _raw.text = _file.serialize();
      }
      _tab = index;
    });
  }

  String _currentText() {
    if (_tab == 2) {
      _file = KeyFile.parse(_raw.text);
      _fileToForm();
    } else {
      _formToFile();
    }
    return _file.serialize();
  }

  // ---------------------------------------------------------------- pickers

  Future<void> _pickExec() async {
    final XFile? file = await openFile(
      initialDirectory: _initialDir(execProgram(_exec.text)),
      confirmButtonText: 'Use program',
    );
    if (file == null || !mounted) return;
    final String path = file.path;
    final FileStat stat = FileStat.statSync(path);
    if ((stat.mode & 0x49) == 0) {
      final bool makeExecutable = await showConfirmDialog(
        context,
        title: 'Make it executable?',
        message:
            '"${path.split('/').last}" is not marked as executable, so it cannot be launched. '
            'Mark it as executable for your user?',
        confirmLabel: 'Make executable',
        icon: M3EIcons.terminal,
      );
      if (makeExecutable) {
        final CommandResult result = await CommandRunner.run('chmod', <String>['u+x', '--', path]);
        if (!result.ok && mounted) {
          showInfoDialog(context, title: 'Could not change permissions', message: result.errorSummary);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      final String quoted = KeyFile.escape(quoteExecArg(path));
      final List<String> oldArgs = splitExec(_exec.text);
      // Keep field codes such as %U / %F from the previous Exec line.
      final String codes = oldArgs.where((String a) => RegExp(r'^%[fFuUdDnNickvm]$').hasMatch(a)).join(' ');
      _exec.text = codes.isEmpty ? quoted : '$quoted $codes';
      if (_name.text.trim().isEmpty) {
        _name.text = _prettyName(path.split('/').last);
      }
    });
  }

  Future<void> _pickIcon() async {
    const XTypeGroup images = XTypeGroup(
      label: 'Images',
      extensions: <String>['png', 'svg', 'jpg', 'jpeg', 'webp', 'xpm', 'ico'],
    );
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[images],
      initialDirectory: _initialDir(_icon.text.startsWith('/') ? _icon.text : null),
      confirmButtonText: 'Use icon',
    );
    if (file == null || !mounted) return;
    setState(() => _icon.text = file.path);
  }

  Future<void> _pickWorkDir() async {
    final String? dir = await getDirectoryPath(
      initialDirectory: _workDir.text.isNotEmpty ? _workDir.text : ShellEnv.instance.home,
      confirmButtonText: 'Use folder',
    );
    if (dir == null || !mounted) return;
    setState(() => _workDir.text = dir);
  }

  String? _initialDir(String? path) {
    if (path == null || !path.startsWith('/')) return ShellEnv.instance.home;
    final Directory parent = File(path).parent;
    return parent.existsSync() ? parent.path : ShellEnv.instance.home;
  }

  static String _prettyName(String fileName) {
    String name = fileName
        .replaceAll(RegExp(r'\.(AppImage|appimage|sh|py|jar|x86_64|bin|run)$'), '')
        .replaceAll(RegExp(r'[-_.]?(x86_64|amd64|aarch64|linux\d*)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_.]v?\d+(\.\d+)+.*$'), '')
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .trim();
    if (name.isEmpty) name = fileName;
    return name[0].toUpperCase() + name.substring(1);
  }

  // ------------------------------------------------------------ list editors

  Future<void> _addCategory() async {
    final String? value = await M3EDialog.show<String>(
      context,
      dialog: _PickFromListDialog(
        title: 'Add category',
        options: _mainCategories.where((String c) => !_categories.contains(c)).toList(),
        hint: 'Search or type a category',
        allowCustom: true,
        customValidator: (String v) =>
            RegExp(r'^[A-Za-z0-9-]+$').hasMatch(v) ? null : 'Use letters, digits and "-" only',
      ),
    );
    if (value == null || value.isEmpty || _categories.contains(value)) return;
    setState(() => _categories = <String>[..._categories, value]);
  }

  Future<void> _addMimeType() async {
    final List<String> all = await MimeDatabase.instance.types();
    if (!mounted) return;
    final String? value = await M3EDialog.show<String>(
      context,
      dialog: _PickFromListDialog(
        title: 'Add file type',
        options: all.where((String m) => !_mimeTypes.contains(m)).toList(),
        hint: 'e.g. text/plain, image/png, x-scheme-handler/https',
        allowCustom: true,
        customValidator: (String v) =>
            RegExp(r'^[a-zA-Z0-9.+_-]+/[a-zA-Z0-9.+_*-]+$').hasMatch(v) ? null : 'Use the form type/subtype',
      ),
    );
    if (value == null || value.isEmpty || _mimeTypes.contains(value)) return;
    setState(() {
      _mimeTypes = <String>[..._mimeTypes, value];
      _wantDefault[value] = false;
    });
  }

  void _addAction() {
    final Set<String> taken = _actions.map((_ActionDraft a) => a.id).toSet();
    int n = 1;
    while (taken.contains('action-$n')) {
      n++;
    }
    setState(() => _actions.add(_ActionDraft(id: 'action-$n')));
  }

  // ------------------------------------------------------------------- save

  Future<void> _save() async {
    if (_saving) return;
    final String text = _currentText();
    final String name = _str('Name');
    if (name.isEmpty) {
      showInfoDialog(context, title: 'Name is required', message: 'Give the launcher a name.');
      setState(() => _tab = 0);
      return;
    }
    if (_type == 'Application' &&
        (_file.get(kDesktopEntryGroup, 'Exec') ?? '').trim().isEmpty &&
        !_bool('DBusActivatable')) {
      showInfoDialog(context, title: 'Program is required', message: 'Choose the program this launcher starts.');
      setState(() => _tab = 0);
      return;
    }
    if (_type == 'Link' && _str('URL').isEmpty) {
      showInfoDialog(context, title: 'URL is required', message: 'A Link launcher needs a URL.');
      return;
    }

    setState(() => _saving = true);
    try {
      final String id = _isNew ? _repo.suggestId(name, widget.existingIds) : _desktopId;
      final ValidationReport report = await _repo.validate(id, text);
      if (!mounted) return;
      if (report.hasErrors) {
        final bool saveAnyway = await showConfirmDialog(
          context,
          title: 'This launcher has problems',
          icon: M3EIcons.warning_amber,
          content: _ReportList(lines: <String>[...report.errors, ...report.warnings]),
          message: 'desktop-file-validate reported errors. Launchers may ignore an invalid file.',
          confirmLabel: 'Save anyway',
        );
        if (!saveAnyway || !mounted) return;
      }

      final DesktopEntry? entry = widget.entry;
      if (entry == null) {
        await _repo.writeUserEntry(id, text);
      } else if (entry.isUser) {
        await _repo.writeFile(entry.path, text);
      } else {
        // Flatpak/Snap/Nix launchers are rewritten by their own tools, so they
        // always get a personal copy; distro launchers let the user choose.
        final bool systemOk = _repo.canModifySystemFile(entry);
        final _SaveTarget? target = systemOk ? await _askSaveTarget(entry) : _SaveTarget.override;
        if (target == null || !mounted) return;
        if (target == _SaveTarget.override) {
          await _repo.writeUserEntry(entry.id, text);
        } else if (entry.writable) {
          await _repo.writeFile(entry.path, text);
        } else {
          final CommandResult? result = await runWithLog(
            context,
            title: 'Saving system launcher',
            successMessage: 'Saved',
            task: (void Function(String) log) => _repo.writeSystemEntry(entry.path, text, onLine: log),
          );
          if (result == null || !result.ok) return;
        }
      }

      await _applyDefaults(id);
      if (!mounted) return;
      showSnack(
        context,
        report.warnings.isEmpty ? 'Saved "$name"' : 'Saved "$name" (${Fmt.plural(report.warnings.length, 'warning')})',
      );
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) showInfoDialog(context, title: 'Could not save', message: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyDefaults(String id) async {
    final List<String> toSet = <String>[];
    final List<String> toClear = <String>[];
    for (final String mime in _wantDefault.keys) {
      final bool want = (_wantDefault[mime] ?? false) && _mimeTypes.contains(mime);
      final bool isNow = _currentDefaults[mime] == id;
      if (want && !isNow) toSet.add(mime);
      if (!want && isNow) toClear.add(mime);
    }
    if (toSet.isNotEmpty) await MimeApps.instance.setDefault(id, toSet);
    if (toClear.isNotEmpty) await MimeApps.instance.clearDefault(id, toClear);
  }

  Future<_SaveTarget?> _askSaveTarget(DesktopEntry entry) {
    return M3EDialog.show<_SaveTarget>(
      context,
      dialog: Builder(
        builder: (BuildContext context) => M3EDialog(
          title: 'Save system launcher',
          icon: const Icon(M3EIcons.save_outlined),
          content: Text(
            'This launcher belongs to a package (${Fmt.tildify(entry.path, ShellEnv.instance.home)}).\n\n'
            'Saving a personal copy is recommended: it only affects you, needs no password and '
            'survives package updates. Overwriting the system file affects all users and may be '
            'reverted by the next update.',
          ),
          actions: <Widget>[
            M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            M3EButton.text(
              onPressed: () => Navigator.of(context).pop(_SaveTarget.system),
              child: const Text('Overwrite (admin)'),
            ),
            M3EButton.filled(
              onPressed: () => Navigator.of(context).pop(_SaveTarget.override),
              child: const Text('Save my copy'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkFile() async {
    final String text = _currentText();
    final ValidationReport report = await _repo.validate(_isNew ? 'new-launcher.desktop' : _desktopId, text);
    if (!mounted) return;
    if (!report.available) {
      showInfoDialog(
        context,
        title: 'Validator not installed',
        message: 'Install "desktop-file-utils" to check launchers for problems.',
      );
      return;
    }
    final List<String> lines = <String>[...report.errors, ...report.warnings];
    showInfoDialog(
      context,
      title: lines.isEmpty ? 'No problems found' : 'Validation report',
      icon: lines.isEmpty ? M3EIcons.check_circle_outline : M3EIcons.rule,
      message: lines.isEmpty ? 'desktop-file-validate found no problems.' : lines.join('\n'),
    );
  }

  Future<void> _confirmDiscard() async {
    final bool changed = _currentText() != _originalText;
    if (!changed) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    final bool discard = await showConfirmDialog(
      context,
      title: 'Discard changes?',
      message: 'Your edits to this launcher have not been saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (discard && mounted) Navigator.of(context).pop(false);
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DesktopEntry? entry = widget.entry;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: M3EAppBar.top(
          leading: M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(M3EIcons.arrow_back),
            tooltip: 'Back',
            onPressed: _confirmDiscard,
          ),
          titleText: _isNew ? 'New launcher' : 'Edit launcher',
          subtitleText: entry == null
              ? 'Saved to ${Fmt.tildify(_repo.userDir, ShellEnv.instance.home)}'
              : Fmt.tildify(entry.path, ShellEnv.instance.home),
          actions: <Widget>[
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(M3EIcons.rule),
              tooltip: 'Check for problems',
              onPressed: _checkFile,
            ),
            const SizedBox(width: 8),
            M3EButton.filled(
              onPressed: _saving ? null : _save,
              enabled: !_saving,
              icon: const Icon(M3EIcons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: <Widget>[
            M3ETabs(
              selectedIndex: _tab,
              onTabSelected: _onTabSelected,
              tabs: const <M3ETab>[
                M3ETab(label: 'General', icon: Icon(M3EIcons.tune)),
                M3ETab(label: 'Files & actions', icon: Icon(M3EIcons.extension_outlined)),
                M3ETab(label: 'Source', icon: Icon(M3EIcons.code)),
              ],
            ),
            Expanded(
              child: switch (_tab) {
                0 => _buildGeneral(context),
                1 => _buildAdvanced(context),
                _ => _buildSource(context),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _page(List<Widget> children) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children.expand((Widget w) => <Widget>[w, const SizedBox(height: 16)]).toList(),
          ),
        ),
      ),
    );
  }

  Widget _text(
    TextEditingController controller,
    String label, {
    String? supporting,
    Widget? trailing,
    int maxLines = 1,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: M3ETextField(
            controller: controller,
            label: label,
            supportingText: supporting,
            variant: M3ETextFieldVariant.outlined,
            maxLines: maxLines,
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 8),
          Padding(padding: const EdgeInsets.only(top: 8), child: trailing),
        ],
      ],
    );
  }

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.bodyLarge),
                Text(subtitle, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          M3ESwitch(value: value, onChanged: (bool v) => setState(() => onChanged(v))),
        ],
      ),
    );
  }

  Widget _buildGeneral(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String iconValue = _icon.text.trim();
    final String? iconPath = IconResolver.instance.resolve(iconValue);
    final DesktopEntry? entry = widget.entry;
    return _page(<Widget>[
      SectionCard(
        child: Row(
          children: <Widget>[
            Container(
              width: 88,
              height: 88,
              padding: const EdgeInsets.all(12),
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerHighest,
                shape: const StarBorder(points: 10, innerRadiusRatio: 0.88, pointRounding: 1),
              ),
              child: FileIcon(path: iconPath, size: 64),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _name.text.trim().isEmpty ? 'Untitled launcher' : _name.text.trim(),
                    style: text.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      TagChip(label: entry == null ? 'New · User' : entry.source.label),
                      if (entry?.isOverride ?? false) const TagChip(label: 'Overrides a system launcher'),
                      if (entry != null && !entry.isUser && !entry.writable)
                        TagChip(
                          label: 'Owned by a package',
                          icon: M3EIcons.lock_outline,
                          color: scheme.tertiaryContainer,
                          foreground: scheme.onTertiaryContainer,
                        ),
                      if (entry?.isBroken ?? false)
                        TagChip(
                          label: 'Missing program: ${entry!.missingProgram}',
                          icon: M3EIcons.link_off,
                          color: scheme.errorContainer,
                          foreground: scheme.onErrorContainer,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      SectionCard(
        title: 'Basics',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _text(_name, 'Name *'),
            const SizedBox(height: 12),
            _text(_genericName, 'Generic name', supporting: 'e.g. "Web Browser"'),
            const SizedBox(height: 12),
            _text(_comment, 'Comment', supporting: 'Tooltip text shown by launchers'),
            const SizedBox(height: 12),
            _text(
              _icon,
              'Icon',
              supporting: iconValue.isEmpty
                  ? 'An icon name from your theme, or a picture file'
                  : (iconPath == null
                        ? 'Not found in the current icon theme'
                        : Fmt.tildify(iconPath, ShellEnv.instance.home)),
              trailing: M3EButton.tonal(
                onPressed: _pickIcon,
                icon: const Icon(M3EIcons.image_outlined),
                label: const Text('Choose…'),
              ),
            ),
          ],
        ),
      ),
      if (_type == 'Application')
        SectionCard(
          title: 'Program',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _text(
                _exec,
                'Command (Exec) *',
                supporting: 'Field codes: %f/%F file(s), %u/%U URL(s)',
                trailing: M3EButton.tonal(
                  onPressed: _pickExec,
                  icon: const Icon(M3EIcons.folder_open_outlined),
                  label: const Text('Browse…'),
                ),
              ),
              const SizedBox(height: 12),
              _text(
                _workDir,
                'Working directory',
                trailing: M3EButton.tonal(
                  onPressed: _pickWorkDir,
                  icon: const Icon(M3EIcons.folder_outlined),
                  label: const Text('Choose…'),
                ),
              ),
              const SizedBox(height: 8),
              _switchRow(
                'Run in terminal',
                'Open a terminal window for command-line programs',
                _terminal,
                (bool v) => _terminal = v,
              ),
            ],
          ),
        ),
      SectionCard(
        title: 'Menus',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _switchRow(
              'Hide from app launchers',
              'Keeps file associations working (NoDisplay)',
              _noDisplay,
              (bool v) => _noDisplay = v,
            ),
            const SizedBox(height: 12),
            Text('Categories', style: text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final String c in _categories)
                  M3EChip(
                    type: M3EChipType.input,
                    label: c,
                    onDeleted: () => setState(() => _categories = List<String>.of(_categories)..remove(c)),
                  ),
                M3EChip(label: 'Add category', leading: const Icon(M3EIcons.add, size: 18), onPressed: _addCategory),
              ],
            ),
            const SizedBox(height: 16),
            _text(_keywords, 'Keywords', supporting: 'Extra search words, separated by commas'),
          ],
        ),
      ),
    ]);
  }

  Widget _buildAdvanced(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return _page(<Widget>[
      SectionCard(
        title: 'Type',
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 420,
            child: M3ESegmentedButton<String>(
              segments: const <M3ESegment<String>>[
                M3ESegment<String>(value: 'Application', label: 'Application', icon: Icon(M3EIcons.apps)),
                M3ESegment<String>(value: 'Link', label: 'Link (URL)', icon: Icon(M3EIcons.link)),
              ],
              selected: <String>{_type == 'Link' ? 'Link' : 'Application'},
              onSelectionChanged: (Set<String> v) => setState(() => _type = v.first),
            ),
          ),
        ),
      ),
      if (_type == 'Link')
        SectionCard(
          title: 'Link',
          child: _text(_url, 'URL *', supporting: 'e.g. https://example.org'),
        ),
      if (_type == 'Application') ...<Widget>[
        SectionCard(
          title: 'File types & default app',
          subtitle: 'MIME types this program can open. Turn on "Default" to make it open them.',
          trailing: M3EButton.tonal(onPressed: _addMimeType, icon: const Icon(M3EIcons.add), label: const Text('Add')),
          child: _mimeTypes.isEmpty
              ? Text('No file types yet.', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
              : Column(
                  children: <Widget>[
                    for (final String mime in _mimeTypes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: <Widget>[
                            Icon(M3EIcons.description_outlined, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(mime, style: text.bodyLarge),
                                  if (_currentDefaults[mime] != null && _currentDefaults[mime] != _desktopId)
                                    Text(
                                      'Current default: ${_currentDefaults[mime]}',
                                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                    ),
                                ],
                              ),
                            ),
                            Text('Default', style: text.labelLarge),
                            const SizedBox(width: 8),
                            M3ESwitch(
                              value: _wantDefault[mime] ?? false,
                              onChanged: (bool v) => setState(() => _wantDefault[mime] = v),
                            ),
                            const SizedBox(width: 4),
                            M3EIconButton(
                              variant: M3EIconButtonVariant.standard,
                              icon: const Icon(M3EIcons.close),
                              tooltip: 'Remove',
                              onPressed: () => setState(() {
                                _mimeTypes = List<String>.of(_mimeTypes)..remove(mime);
                              }),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Actions',
          subtitle: 'Extra entries shown when right-clicking the launcher (e.g. "New window").',
          trailing: M3EButton.tonal(onPressed: _addAction, icon: const Icon(M3EIcons.add), label: const Text('Add')),
          child: _actions.isEmpty
              ? Text('No actions.', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
              : Column(
                  children: <Widget>[
                    for (final _ActionDraft a in _actions)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(child: Text(a.id, style: text.labelLarge)),
                                M3EIconButton(
                                  variant: M3EIconButtonVariant.standard,
                                  icon: const Icon(M3EIcons.delete_outline),
                                  tooltip: 'Remove action',
                                  onPressed: () => setState(() {
                                    _actions.remove(a);
                                    a.dispose();
                                  }),
                                ),
                              ],
                            ),
                            _text(a.name, 'Name'),
                            const SizedBox(height: 8),
                            _text(a.exec, 'Command'),
                            const SizedBox(height: 8),
                            _text(a.icon, 'Icon (optional)'),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Advanced',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _text(_tryExec, 'TryExec', supporting: 'Hide the launcher when this program is missing'),
              const SizedBox(height: 12),
              _text(_wmClass, 'StartupWMClass', supporting: 'Window class, helps docks group windows'),
              const SizedBox(height: 8),
              _switchRow(
                'Startup notification',
                'Show a busy cursor while starting',
                _startupNotify,
                (bool v) => _startupNotify = v,
              ),
              _switchRow(
                'Prefer discrete GPU',
                'PrefersNonDefaultGPU on hybrid-graphics laptops',
                _prefersNonDefaultGpu,
                (bool v) => _prefersNonDefaultGpu = v,
              ),
            ],
          ),
        ),
      ],
      Text(
        'Translations (e.g. Name[ta]) and unknown keys are kept as they are. Edit them in the Source tab.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ]);
  }

  Widget _buildSource(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Container(
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _raw,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', height: 1.4),
              decoration: const InputDecoration.collapsed(hintText: '[Desktop Entry]'),
            ),
          ),
        ),
      ),
    );
  }
}

enum _SaveTarget { override, system }

class _ReportList extends StatelessWidget {
  const _ReportList({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: SingleChildScrollView(
        child: SelectableText(
          lines.join('\n'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

/// Searchable list picker that can also accept a custom value.
class _PickFromListDialog extends StatefulWidget {
  const _PickFromListDialog({
    required this.title,
    required this.options,
    required this.hint,
    this.allowCustom = false,
    this.customValidator,
  });

  final String title;
  final List<String> options;
  final String hint;
  final bool allowCustom;
  final String? Function(String value)? customValidator;

  @override
  State<_PickFromListDialog> createState() => _PickFromListDialogState();
}

class _PickFromListDialogState extends State<_PickFromListDialog> {
  final TextEditingController _query = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _submitCustom() {
    final String value = _query.text.trim();
    if (value.isEmpty) return;
    final String? error = widget.customValidator?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final String q = _query.text.trim().toLowerCase();
    final List<String> matches = widget.options
        .where((String o) => q.isEmpty || o.toLowerCase().contains(q))
        .take(200)
        .toList();
    return M3EDialog(
      title: widget.title,
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(
          children: <Widget>[
            M3ETextField(
              controller: _query,
              label: widget.hint,
              autofocus: true,
              errorText: _error,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) {
                if (widget.allowCustom) _submitCustom();
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (BuildContext context, int i) =>
                    M3EListItem(headline: matches[i], onTap: () => Navigator.of(context).pop(matches[i])),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (widget.allowCustom) M3EButton.tonal(onPressed: _submitCustom, child: const Text('Add typed value')),
      ],
    );
  }
}
