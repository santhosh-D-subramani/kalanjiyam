import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/system/shell_env.dart';
import 'data/cache_catalog.dart';
import 'data/cache_model.dart';
import 'data/disk_scanner.dart';

class CacheEntry {
  CacheEntry(this.target, this.paths);

  final CacheTarget target;
  List<String> paths;
  int? size;
  bool measuring = true;

  List<String> get existingPaths => paths
      .where((String p) => FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound)
      .toList();
}

class CachesController extends ChangeNotifier {
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

  bool _loading = false;
  bool _loaded = false;
  bool _showAdvanced = false;
  final List<CacheEntry> _entries = <CacheEntry>[];
  final Set<String> selected = <String>{};

  bool get loading => _loading;
  bool get loaded => _loaded;
  bool get showAdvanced => _showAdvanced;

  /// Entries to show: advanced ones only on request, and nothing that turned
  /// out to be empty.
  List<CacheEntry> get visible =>
      _entries.where((CacheEntry e) => (_showAdvanced || !e.target.optIn) && (e.measuring || e.size != 0)).toList();

  int get hiddenCount => _entries.where((CacheEntry e) => e.target.optIn).length;

  int get totalSize => visible.fold<int>(0, (int s, CacheEntry e) => s + (e.size ?? 0));

  bool get measuring => _entries.any((CacheEntry e) => e.measuring);

  set showAdvanced(bool value) {
    _showAdvanced = value;
    if (!value) {
      selected.removeWhere((String id) => _entries.any((CacheEntry e) => e.target.id == id && e.target.optIn));
    }
    notifyListeners();
  }

  CacheEntry? entry(String id) {
    for (final CacheEntry e in _entries) {
      if (e.target.id == id) return e;
    }
    return null;
  }

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    await ShellEnv.instance.ready;
    final List<CacheTarget> catalog = buildCacheCatalog();
    final List<CacheEntry> found = <CacheEntry>[];
    await _forEachLimited<CacheTarget>(catalog, 6, (CacheTarget t) async {
      try {
        final bool present = await (t.detect?.call() ?? Future<bool>.value(true));
        if (!present) return;
        final List<String> paths = await t.paths().timeout(const Duration(seconds: 40));
        final CacheEntry e = CacheEntry(t, paths);
        // Path-based caches only appear when something is actually there.
        if (paths.isNotEmpty && e.existingPaths.isEmpty) return;
        found.add(e);
      } on Object {
        // A broken tool must never hide the rest of the list.
      }
    });
    // Keep catalog order.
    final Map<String, int> order = <String, int>{for (int i = 0; i < catalog.length; i++) catalog[i].id: i};
    found.sort((CacheEntry a, CacheEntry b) => order[a.target.id]!.compareTo(order[b.target.id]!));
    _entries
      ..clear()
      ..addAll(found);
    selected.removeWhere((String id) => entry(id) == null);
    _loading = false;
    _loaded = true;
    notifyListeners();
    await _forEachLimited<CacheEntry>(List<CacheEntry>.of(_entries), 4, _measure);
  }

  Future<void> remeasure(String id) async {
    final CacheEntry? e = entry(id);
    if (e == null) return;
    try {
      e.paths = await e.target.paths();
    } on Object {
      // keep previous paths
    }
    await _measure(e);
  }

  Future<void> _measure(CacheEntry e) async {
    e.measuring = true;
    notifyListeners();
    try {
      final Future<int?> Function(List<String>)? custom = e.target.size;
      e.size = custom != null ? await custom(e.paths) : await DiskScanner.usage(e.existingPaths);
    } on Object {
      e.size = null;
    } finally {
      e.measuring = false;
      notifyListeners();
    }
  }

  static Future<void> _forEachLimited<T>(List<T> items, int limit, Future<void> Function(T item) action) async {
    int next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final T item = items[next++];
        await action(item);
      }
    }

    await Future.wait(<Future<void>>[for (int i = 0; i < limit; i++) worker()]);
  }
}
