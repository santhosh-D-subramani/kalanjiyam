/// Formatting helpers shared by all features.
abstract final class Fmt {
  static const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Binary (1024-based) human readable size, e.g. `1.4 GB`.
  static String bytes(int? value) {
    if (value == null || value < 0) return '—';
    if (value < 1024) return '$value B';
    double size = value.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < _units.length - 1) {
      size /= 1024;
      unit++;
    }
    final String digits = size >= 100 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
    return '$digits ${_units[unit]}';
  }

  /// Parses sizes such as `12.34 MiB`, `512 KiB`, `1.2 GB`, `880 kB`, `42`.
  static int? parseSize(String raw) {
    final RegExpMatch? m = RegExp(r'^\s*([0-9]+(?:[.,][0-9]+)?)\s*([A-Za-z]*)\s*$').firstMatch(raw);
    if (m == null) return null;
    final double? number = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (number == null) return null;
    final String unit = m.group(2)!.toLowerCase();
    const Map<String, int> binary = <String, int>{
      '': 1,
      'b': 1,
      'kib': 1024,
      'mib': 1024 * 1024,
      'gib': 1024 * 1024 * 1024,
      'tib': 1024 * 1024 * 1024 * 1024,
      'k': 1024,
      'm': 1024 * 1024,
      'g': 1024 * 1024 * 1024,
      't': 1024 * 1024 * 1024 * 1024,
    };
    const Map<String, int> decimal = <String, int>{
      'kb': 1000,
      'mb': 1000 * 1000,
      'gb': 1000 * 1000 * 1000,
      'tb': 1000 * 1000 * 1000 * 1000,
    };
    final int? factor = binary[unit] ?? decimal[unit];
    if (factor == null) return null;
    return (number * factor).round();
  }

  static String date(DateTime? value) {
    if (value == null) return '—';
    final DateTime d = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String dateTime(DateTime? value) {
    if (value == null) return '—';
    final DateTime d = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date(d)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// Replaces the user's home directory with `~` for display.
  static String tildify(String path, String home) {
    if (home.length > 1 && (path == home || path.startsWith('$home/'))) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  static String plural(int count, String singular, [String? pluralForm]) =>
      '$count ${count == 1 ? singular : (pluralForm ?? '${singular}s')}';
}
