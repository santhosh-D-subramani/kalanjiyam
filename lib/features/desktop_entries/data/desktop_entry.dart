import 'key_file.dart';

const String kDesktopEntryGroup = 'Desktop Entry';

enum EntrySource { user, system, flatpak, snap }

extension EntrySourceLabel on EntrySource {
  String get label => switch (this) {
    EntrySource.user => 'User',
    EntrySource.system => 'System',
    EntrySource.flatpak => 'Flatpak',
    EntrySource.snap => 'Snap',
  };
}

/// One `.desktop` file found in an XDG `applications` directory.
class DesktopEntry {
  DesktopEntry({
    required this.id,
    required this.path,
    required this.source,
    required this.file,
    required this.writable,
    this.shadowed = const <String>[],
    this.missingProgram,
  });

  /// Desktop file ID, e.g. `org.gnome.Nautilus.desktop`.
  final String id;

  /// Absolute path of the file.
  final String path;
  final EntrySource source;
  final KeyFile file;

  /// Whether the current user can modify the file directly.
  final bool writable;

  /// Lower-precedence files with the same ID that this entry overrides.
  final List<String> shadowed;

  /// Set when the program from `TryExec`/`Exec` cannot be found.
  final String? missingProgram;

  bool get isUser => source == EntrySource.user;

  /// A user entry that overrides a system/flatpak entry with the same ID.
  bool get isOverride => isUser && shadowed.isNotEmpty;

  bool get isBroken => missingProgram != null;

  String? raw(String key) => file.get(kDesktopEntryGroup, key);

  String? string(String key) {
    final String? value = raw(key);
    return value == null ? null : KeyFile.unescape(value);
  }

  bool boolean(String key) => raw(key)?.trim().toLowerCase() == 'true';

  List<String> list(String key) => KeyFile.splitList(raw(key));

  /// Locale-aware lookup (`Name[ta_IN]`, `Name[ta]`, then `Name`).
  String? localized(String key, List<String> localeKeys) {
    for (final String locale in localeKeys) {
      final String? value = raw('$key[$locale]');
      if (value != null && value.isNotEmpty) return KeyFile.unescape(value);
    }
    return string(key);
  }

  String get type => string('Type') ?? 'Application';
  String get name => string('Name') ?? id.replaceAll(RegExp(r'\.desktop$'), '');
  String? get genericName => string('GenericName');
  String? get comment => string('Comment');
  String? get exec => raw('Exec');
  String? get tryExec => string('TryExec');
  String? get icon => string('Icon');
  bool get terminal => boolean('Terminal');
  bool get noDisplay => boolean('NoDisplay');
  bool get hidden => boolean('Hidden');
  List<String> get categories => list('Categories');
  List<String> get mimeTypes => list('MimeType');
  List<String> get keywords => list('Keywords');
  List<String> get actions => list('Actions');

  /// Hidden from launchers either way (`Hidden` = deleted, `NoDisplay` = not
  /// shown in menus but still usable to open files).
  bool get isHiddenFromMenus => hidden || noDisplay;

  /// Text used for searching.
  String get searchText => <String?>[
    name,
    genericName,
    comment,
    id,
    exec,
    ...keywords,
    ...categories,
  ].whereType<String>().join(' ').toLowerCase();
}

/// Locale suffixes to try for localized keys, most specific first, derived
/// from `LC_ALL` / `LC_MESSAGES` / `LANG` (e.g. `ta_IN.UTF-8`).
List<String> localeKeysFrom(Map<String, String> env) {
  final String raw = <String?>[
    env['LC_ALL'],
    env['LC_MESSAGES'],
    env['LANG'],
  ].firstWhere((String? v) => v != null && v.isNotEmpty, orElse: () => '')!;
  if (raw.isEmpty || raw == 'C' || raw == 'POSIX') return const <String>[];
  final RegExpMatch? m = RegExp(r'^([a-zA-Z]+)(?:_([a-zA-Z]+))?(?:\.[^@]*)?(?:@(.*))?$').firstMatch(raw);
  if (m == null) return const <String>[];
  final String lang = m.group(1)!;
  final String? country = m.group(2);
  final String? modifier = m.group(3);
  return <String>[
    if (country != null && modifier != null) '${lang}_$country@$modifier',
    if (country != null) '${lang}_$country',
    if (modifier != null) '$lang@$modifier',
    lang,
  ];
}

/// Extracts the program (first word) of an `Exec` value, following the
/// spec's quoting rules and skipping a leading `env VAR=value …`.
String? execProgram(String? exec) {
  if (exec == null || exec.trim().isEmpty) return null;
  final List<String> args = splitExec(exec);
  int i = 0;
  if (args.isNotEmpty && (args.first == 'env' || args.first.endsWith('/env'))) {
    i = 1;
    while (i < args.length && (args[i].contains('=') || args[i].startsWith('-'))) {
      i++;
    }
  }
  return i < args.length ? args[i] : null;
}

/// Splits an `Exec` value into arguments (double quotes with `\"`, `\``,
/// `\$`, `\\` escapes, as described in the Desktop Entry Specification).
List<String> splitExec(String exec) {
  final String value = KeyFile.unescape(exec);
  final List<String> args = <String>[];
  final StringBuffer current = StringBuffer();
  bool inQuotes = false;
  bool hasToken = false;
  for (int i = 0; i < value.length; i++) {
    final String c = value[i];
    if (inQuotes) {
      if (c == r'\' && i + 1 < value.length && r'"`$\'.contains(value[i + 1])) {
        current.write(value[i + 1]);
        i++;
      } else if (c == '"') {
        inQuotes = false;
      } else {
        current.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
      hasToken = true;
    } else if (c == ' ' || c == '\t') {
      if (hasToken || current.isNotEmpty) {
        args.add(current.toString());
        current.clear();
        hasToken = false;
      }
    } else {
      current.write(c);
      hasToken = true;
    }
  }
  if (hasToken || current.isNotEmpty) {
    args.add(current.toString());
  }
  return args;
}

/// Quotes a path for use as the program in an `Exec` value.
String quoteExecArg(String arg) {
  if (arg.isNotEmpty && !RegExp(r'''[\s"'\\`$;&|<>()*?#~]''').hasMatch(arg)) {
    return arg;
  }
  final String escaped = arg
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$');
  return '"$escaped"';
}
