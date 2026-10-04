import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';
import 'data/package_managers.dart';
import 'data/package_models.dart';

class ManagerState {
  ManagerState(this.manager);

  final PackageManager manager;
  bool loading = true;
  String? error;
  List<InstalledPackage> packages = <InstalledPackage>[];
}

enum PackageSort { name, size, date }

class PackagesController extends ChangeNotifier {
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

  final List<PackageManager> _all = buildPackageManagers();
  final List<ManagerState> _states = <ManagerState>[];
  bool _detecting = false;
  bool _detected = false;
  String? _selected;
  String _query = '';
  PackageSort _sort = PackageSort.name;
  int _generation = 0;

  bool get detecting => _detecting;
  bool get detected => _detected;
  List<ManagerState> get states => _states;
  String? get selected => _selected;
  PackageSort get sort => _sort;

  bool get explicitOnly => !AppSettings.instance.showDependencies;

  bool get anyLoading => _detecting || _states.any((ManagerState s) => s.loading);

  int get total => _states.fold<int>(0, (int sum, ManagerState s) => sum + s.packages.length);

  ManagerState? stateOf(String managerId) {
    for (final ManagerState s in _states) {
      if (s.manager.id == managerId) return s;
    }
    return null;
  }

  /// True when the current view contains a manager that tracks dependencies.
  bool get explicitFilterRelevant {
    if (_selected == null) return _states.any((ManagerState s) => s.manager.tracksExplicit);
    return stateOf(_selected!)?.manager.tracksExplicit ?? false;
  }

  int countFor(String? managerId) {
    if (managerId == null) return _states.fold<int>(0, (int s, ManagerState m) => s + _visibleOf(m).length);
    final ManagerState? s = stateOf(managerId);
    return s == null ? 0 : _visibleOf(s).length;
  }

  Iterable<InstalledPackage> _visibleOf(ManagerState s) {
    if (!explicitOnly || !s.manager.tracksExplicit) return s.packages;
    return s.packages.where((InstalledPackage p) => p.explicit != false);
  }

  List<InstalledPackage> get visible {
    final String q = _query.trim().toLowerCase();
    final List<InstalledPackage> list = <InstalledPackage>[
      for (final ManagerState s in _states)
        if (_selected == null || s.manager.id == _selected)
          ..._visibleOf(s).where((InstalledPackage p) => q.isEmpty || p.searchText.contains(q)),
    ];
    switch (_sort) {
      case PackageSort.name:
        list.sort((InstalledPackage a, InstalledPackage b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case PackageSort.size:
        list.sort((InstalledPackage a, InstalledPackage b) => (b.size ?? -1).compareTo(a.size ?? -1));
      case PackageSort.date:
        list.sort(
          (InstalledPackage a, InstalledPackage b) =>
              (b.installDate?.millisecondsSinceEpoch ?? -1).compareTo(a.installDate?.millisecondsSinceEpoch ?? -1),
        );
    }
    return list;
  }

  set selected(String? value) {
    _selected = value;
    notifyListeners();
  }

  set query(String value) {
    _query = value;
    notifyListeners();
  }

  set sort(PackageSort value) {
    _sort = value;
    notifyListeners();
  }

  set explicitOnly(bool value) {
    AppSettings.instance.showDependencies = !value;
    notifyListeners();
  }

  PackageManager? managerFor(InstalledPackage p) => stateOf(p.managerId)?.manager;

  Future<void> load() async {
    final int generation = ++_generation;
    _detecting = true;
    notifyListeners();
    final List<bool> present = await Future.wait(
      _all.map((PackageManager m) async {
        try {
          return await m.detect().timeout(const Duration(seconds: 20));
        } on Object {
          return false;
        }
      }),
    );
    if (generation != _generation) return;
    _states
      ..clear()
      ..addAll(<ManagerState>[
        for (int i = 0; i < _all.length; i++)
          if (present[i]) ManagerState(_all[i]),
      ]);
    if (_selected != null && stateOf(_selected!) == null) _selected = null;
    _detecting = false;
    _detected = true;
    notifyListeners();
    await Future.wait(_states.map((ManagerState s) => _list(s, generation)));
  }

  Future<void> reload(String managerId) async {
    final ManagerState? s = stateOf(managerId);
    if (s == null) return;
    await _list(s, _generation);
  }

  Future<void> _list(ManagerState s, int generation) async {
    s
      ..loading = true
      ..error = null;
    notifyListeners();
    try {
      final List<InstalledPackage> packages = await s.manager.list().timeout(const Duration(minutes: 3));
      if (generation != _generation) return;
      s.packages = packages;
    } on TimeoutException {
      s.error = '${s.manager.label} took too long to respond.';
    } on Object catch (e) {
      s.error = '$e';
    } finally {
      s.loading = false;
      if (generation == _generation) notifyListeners();
    }
  }
}
