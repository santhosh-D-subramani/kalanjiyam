import 'package:material_ui/material_ui.dart';

import '../../core/system/shell_env.dart';
import 'data/desktop_entry.dart';
import 'data/desktop_entry_repository.dart';
import 'data/icon_resolver.dart';

enum EntryFilter { all, user, system, hidden, broken }

class DesktopEntriesController extends ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Async work may finish after the page is gone; never notify then.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  DesktopEntriesController();

  final DesktopEntryRepository repository = DesktopEntryRepository.instance;

  List<DesktopEntry> _entries = <DesktopEntry>[];
  bool _loading = false;
  String? _error;
  EntryFilter _filter = EntryFilter.all;
  String _query = '';
  List<String> _localeKeys = const <String>[];

  bool get loading => _loading;
  String? get error => _error;
  EntryFilter get filter => _filter;
  List<DesktopEntry> get entries => _entries;
  bool get hasLoaded => _entries.isNotEmpty || _error != null;

  Set<String> get installedIds => _entries.where((DesktopEntry e) => !e.hidden).map((DesktopEntry e) => e.id).toSet();

  String displayName(DesktopEntry e) => e.localized('Name', _localeKeys) ?? e.name;

  String? displayComment(DesktopEntry e) =>
      e.localized('Comment', _localeKeys) ?? e.localized('GenericName', _localeKeys);

  String? iconPath(DesktopEntry e) => IconResolver.instance.resolve(e.icon);

  int count(EntryFilter f) => _entries.where((DesktopEntry e) => _matches(e, f)).length;

  List<DesktopEntry> get visible {
    final String q = _query.trim().toLowerCase();
    final List<DesktopEntry> list =
        _entries
            .where((DesktopEntry e) => _matches(e, _filter))
            .where(
              (DesktopEntry e) => q.isEmpty || e.searchText.contains(q) || displayName(e).toLowerCase().contains(q),
            )
            .toList()
          ..sort(
            (DesktopEntry a, DesktopEntry b) => displayName(a).toLowerCase().compareTo(displayName(b).toLowerCase()),
          );
    return list;
  }

  bool _matches(DesktopEntry e, EntryFilter f) => switch (f) {
    EntryFilter.all => true,
    EntryFilter.user => e.isUser,
    EntryFilter.system => !e.isUser,
    EntryFilter.hidden => e.isHiddenFromMenus,
    EntryFilter.broken => e.isBroken,
  };

  set filter(EntryFilter value) {
    _filter = value;
    notifyListeners();
  }

  set query(String value) {
    _query = value;
    notifyListeners();
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await ShellEnv.instance.ready;
      _localeKeys = localeKeysFrom(ShellEnv.instance.environment);
      final List<DesktopEntry> entries = await repository.scan();
      IconResolver.instance.clearCache();
      await IconResolver.instance.resolveAll(entries.map((DesktopEntry e) => e.icon));
      _entries = entries;
    } on Object catch (e) {
      _error = 'Could not read desktop entries: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
