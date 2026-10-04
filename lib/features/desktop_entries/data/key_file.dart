/// A format-preserving reader/writer for freedesktop "key file" documents
/// (`.desktop` files, `mimeapps.list`, icon theme `index.theme`).
///
/// Comments, blank lines, unknown keys, localized keys (`Name[ta]=…`) and
/// the original order are kept, so editing one value never rewrites the
/// rest of the file.
class KeyFile {
  KeyFile._(this._header, this._groups);

  factory KeyFile.empty() => KeyFile._(<String>[], <KeyFileGroup>[]);

  factory KeyFile.parse(String text) {
    final List<String> header = <String>[];
    final List<KeyFileGroup> groups = <KeyFileGroup>[];
    KeyFileGroup? current;
    final List<String> lines = text.replaceAll('\r\n', '\n').split('\n');
    // A trailing newline produces one empty element; drop it.
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    for (final String raw in lines) {
      final String trimmed = raw.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']') && trimmed.length > 2) {
        current = KeyFileGroup._parsed(trimmed.substring(1, trimmed.length - 1));
        groups.add(current);
        continue;
      }
      if (current == null) {
        header.add(raw);
        continue;
      }
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        current._lines.add(_Line.verbatim(raw));
        continue;
      }
      final int eq = raw.indexOf('=');
      if (eq <= 0) {
        // Not valid key file syntax; keep it untouched.
        current._lines.add(_Line.verbatim(raw));
        continue;
      }
      final String key = raw.substring(0, eq).trim();
      final String value = raw.substring(eq + 1).replaceFirst(RegExp(r'^[ \t]+'), '');
      current._lines.add(_Line.entry(raw, key, value));
    }
    return KeyFile._(header, groups);
  }

  final List<String> _header;
  final List<KeyFileGroup> _groups;

  List<KeyFileGroup> get groups => List<KeyFileGroup>.unmodifiable(_groups);

  List<String> get groupNames => _groups.map((KeyFileGroup g) => g.name).toList();

  KeyFileGroup? group(String name) {
    for (final KeyFileGroup g in _groups) {
      if (g.name == name) return g;
    }
    return null;
  }

  bool hasGroup(String name) => group(name) != null;

  KeyFileGroup ensureGroup(String name) {
    final KeyFileGroup? existing = group(name);
    if (existing != null) return existing;
    final KeyFileGroup created = KeyFileGroup(name);
    _groups.add(created);
    return created;
  }

  void removeGroup(String name) => _groups.removeWhere((KeyFileGroup g) => g.name == name);

  /// Raw (still escaped) value of [key] in [group].
  String? get(String group, String key) => this.group(group)?.get(key);

  /// Sets the raw value; `null` removes the key.
  void set(String group, String key, String? value) {
    if (value == null) {
      this.group(group)?.remove(key);
      return;
    }
    ensureGroup(group).set(key, value);
  }

  KeyFile copy() => KeyFile.parse(serialize());

  /// Writes the document back. Parsed content is reproduced verbatim; only
  /// changed entries are re-rendered, and new groups get a blank separator.
  String serialize() {
    final StringBuffer out = StringBuffer();
    bool endsWithBlank = true;
    for (final String line in _header) {
      out.writeln(line);
      endsWithBlank = line.trim().isEmpty;
    }
    for (final KeyFileGroup g in _groups) {
      if (g._created && out.isNotEmpty && !endsWithBlank) {
        out.writeln();
      }
      out.writeln('[${g.name}]');
      endsWithBlank = false;
      for (final _Line line in g._lines) {
        out.writeln(line.render());
        endsWithBlank = line.isBlank;
      }
    }
    return out.toString();
  }

  // ---- Value encoding (Desktop Entry Specification, "Possible value types").

  /// Decodes `\s \n \t \r \\` escapes of a string value.
  static String unescape(String value) {
    if (!value.contains(r'\')) return value;
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < value.length; i++) {
      final String c = value[i];
      if (c == r'\' && i + 1 < value.length) {
        final String n = value[i + 1];
        switch (n) {
          case 's':
            out.write(' ');
          case 'n':
            out.write('\n');
          case 't':
            out.write('\t');
          case 'r':
            out.write('\r');
          case r'\':
            out.write(r'\');
          default:
            // Unknown escape (e.g. `\;` inside lists): keep both characters.
            out
              ..write(c)
              ..write(n);
        }
        i++;
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// Encodes a string value so it survives a round trip.
  static String escape(String value) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < value.length; i++) {
      final String c = value[i];
      switch (c) {
        case r'\':
          out.write(r'\\');
        case '\n':
          out.write(r'\n');
        case '\t':
          out.write(r'\t');
        case '\r':
          out.write(r'\r');
        case ' ' when i == 0:
          out.write(r'\s');
        default:
          out.write(c);
      }
    }
    return out.toString();
  }

  /// Splits a `;`-separated list value, honouring `\;` escapes.
  static List<String> splitList(String? raw) {
    if (raw == null || raw.isEmpty) return <String>[];
    final List<String> items = <String>[];
    final StringBuffer current = StringBuffer();
    for (int i = 0; i < raw.length; i++) {
      final String c = raw[i];
      if (c == r'\' && i + 1 < raw.length) {
        final String n = raw[i + 1];
        if (n == ';') {
          current.write(';');
        } else {
          current
            ..write(c)
            ..write(n);
        }
        i++;
      } else if (c == ';') {
        items.add(unescape(current.toString()));
        current.clear();
      } else {
        current.write(c);
      }
    }
    if (current.isNotEmpty) {
      items.add(unescape(current.toString()));
    }
    return items.map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
  }

  /// Joins list items with `;` (and a trailing `;`, as the spec recommends).
  static String? joinList(Iterable<String> items) {
    final List<String> cleaned = items.map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    if (cleaned.isEmpty) return null;
    return '${cleaned.map((String s) => escape(s).replaceAll(';', r'\;')).join(';')};';
  }
}

class KeyFileGroup {
  KeyFileGroup(this.name) : _created = true;

  KeyFileGroup._parsed(this.name) : _created = false;

  final String name;
  final bool _created;
  final List<_Line> _lines = <_Line>[];

  Iterable<String> get keys => _lines.where((_Line l) => l.key != null).map((_Line l) => l.key!);

  /// All entries as key → raw value, in file order.
  Map<String, String> get entries => <String, String>{
    for (final _Line l in _lines)
      if (l.key != null) l.key!: l.value!,
  };

  String? get(String key) {
    for (final _Line line in _lines) {
      if (line.key == key) return line.value;
    }
    return null;
  }

  void set(String key, String value) {
    for (final _Line line in _lines) {
      if (line.key == key) {
        if (line.value != value) {
          line
            ..value = value
            ..dirty = true;
        }
        return;
      }
    }
    // Insert after the last entry, before trailing blank lines/comments.
    int insertAt = _lines.length;
    while (insertAt > 0 && _lines[insertAt - 1].key == null) {
      insertAt--;
    }
    _lines.insert(insertAt, _Line.entry(null, key, value));
  }

  void remove(String key) => _lines.removeWhere((_Line l) => l.key == key);
}

class _Line {
  _Line.verbatim(this.raw) : key = null, value = null, dirty = false;

  _Line.entry(this.raw, this.key, this.value) : dirty = raw == null;

  final String? raw;
  final String? key;
  String? value;
  bool dirty;

  bool get isBlank => key == null && (raw ?? '').trim().isEmpty;

  String render() {
    if (key == null) return raw ?? '';
    if (!dirty && raw != null) return raw!;
    return '$key=$value';
  }
}
