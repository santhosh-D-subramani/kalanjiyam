import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../system/shell_env.dart';

enum AppThemeMode { system, light, dark }

/// How the app obtains administrator rights.
enum PrivilegeMethod {
  /// Try polkit (`pkexec`) first and fall back to `sudo` when no polkit
  /// authentication agent is running.
  auto,

  /// Only use `pkexec` (needs a running polkit authentication agent).
  polkit,

  /// Only use `sudo`, asking for the password inside the app.
  sudo,
}

/// User preferences, persisted as JSON in `$XDG_CONFIG_HOME/kalanjiyam/`.
///
/// Only UI preferences are stored here — never passwords or anything
/// sensitive.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const List<Color> seedPalette = <Color>[
    Color(0xFF006A60), // teal
    Color(0xFF8E4585), // plum
    Color(0xFFB3261E), // kumkum red
    Color(0xFFC77700), // turmeric
    Color(0xFF3F5AA9), // indigo
    Color(0xFF386A20), // leaf green
  ];

  AppThemeMode _themeMode = AppThemeMode.system;
  int _seedColor = seedPalette.first.toARGB32();
  bool _useSystemAccent = false;
  PrivilegeMethod _privilegeMethod = PrivilegeMethod.auto;
  int _bigFileThresholdMb = 100;
  bool _stayOnFilesystem = true;
  bool _showDependencies = false;

  AppThemeMode get themeMode => _themeMode;
  Color get seedColor => Color(_seedColor);
  bool get useSystemAccent => _useSystemAccent;
  PrivilegeMethod get privilegeMethod => _privilegeMethod;
  int get bigFileThresholdMb => _bigFileThresholdMb;
  bool get stayOnFilesystem => _stayOnFilesystem;
  bool get showDependencies => _showDependencies;

  File get _file => File('${ShellEnv.instance.xdgConfigHome}/kalanjiyam/settings.json');

  Future<void> load() async {
    try {
      final File file = _file;
      if (!file.existsSync()) return;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return;
      _themeMode = _enumByName(AppThemeMode.values, decoded['themeMode'], _themeMode);
      _privilegeMethod = _enumByName(PrivilegeMethod.values, decoded['privilegeMethod'], _privilegeMethod);
      final Object? seed = decoded['seedColor'];
      if (seed is int) _seedColor = seed;
      final Object? accent = decoded['useSystemAccent'];
      if (accent is bool) _useSystemAccent = accent;
      final Object? threshold = decoded['bigFileThresholdMb'];
      if (threshold is int && threshold > 0) _bigFileThresholdMb = threshold;
      final Object? stay = decoded['stayOnFilesystem'];
      if (stay is bool) _stayOnFilesystem = stay;
      final Object? deps = decoded['showDependencies'];
      if (deps is bool) _showDependencies = deps;
    } on Object {
      // A corrupt settings file must never stop the app from starting.
    }
  }

  Future<void> _save() async {
    try {
      final File file = _file;
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'themeMode': _themeMode.name,
          'seedColor': _seedColor,
          'useSystemAccent': _useSystemAccent,
          'privilegeMethod': _privilegeMethod.name,
          'bigFileThresholdMb': _bigFileThresholdMb,
          'stayOnFilesystem': _stayOnFilesystem,
          'showDependencies': _showDependencies,
        }),
      );
      await tmp.rename(file.path);
    } on Object {
      // Preferences are best effort.
    }
  }

  void _update(void Function() change) {
    change();
    notifyListeners();
    _save();
  }

  set themeMode(AppThemeMode value) => _update(() => _themeMode = value);
  set seedColor(Color value) => _update(() => _seedColor = value.toARGB32());
  set useSystemAccent(bool value) => _update(() => _useSystemAccent = value);
  set privilegeMethod(PrivilegeMethod value) => _update(() => _privilegeMethod = value);
  set bigFileThresholdMb(int value) => _update(() => _bigFileThresholdMb = value);
  set stayOnFilesystem(bool value) => _update(() => _stayOnFilesystem = value);
  set showDependencies(bool value) => _update(() => _showDependencies = value);

  static T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final T value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }
}
