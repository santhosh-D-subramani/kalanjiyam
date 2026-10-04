import 'package:flutter_test/flutter_test.dart';
import 'package:kalanjiyam/core/utils/format.dart';
import 'package:kalanjiyam/features/desktop_entries/data/desktop_entry.dart';
import 'package:kalanjiyam/features/desktop_entries/data/key_file.dart';

const String _sample = '''# A comment before the first group
[Desktop Entry]
Type=Application
Name=Firefox
Name[ta]=பயர்பாக்ஸ்
Comment = Browse the web
Exec=/usr/lib/firefox/firefox %u
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;
Actions=new-window;

# window action
[Desktop Action new-window]
Name=New Window
Exec=/usr/lib/firefox/firefox --new-window %u
''';

void main() {
  group('KeyFile', () {
    test('round-trips without changes', () {
      expect(KeyFile.parse(_sample).serialize(), _sample);
    });

    test('reads values, trimming spaces around "="', () {
      final KeyFile f = KeyFile.parse(_sample);
      expect(f.get('Desktop Entry', 'Comment'), 'Browse the web');
      expect(f.get('Desktop Entry', 'Name[ta]'), 'பயர்பாக்ஸ்');
      expect(f.get('Desktop Action new-window', 'Name'), 'New Window');
    });

    test('editing one key keeps everything else', () {
      final KeyFile f = KeyFile.parse(_sample)..set('Desktop Entry', 'Name', 'Firefox Nightly');
      final String out = f.serialize();
      expect(out, contains('Name=Firefox Nightly\n'));
      expect(out, contains('Name[ta]=பயர்பாக்ஸ்\n'));
      expect(out, contains('# window action\n'));
      expect(out, contains('Comment = Browse the web\n'));
    });

    test('adds new keys before trailing blank lines/comments of a group', () {
      final KeyFile f = KeyFile.parse(_sample)..set('Desktop Entry', 'Terminal', 'false');
      final String out = f.serialize();
      expect(out.indexOf('Terminal=false'), lessThan(out.indexOf('# window action')));
      expect(out.indexOf('Terminal=false'), greaterThan(out.indexOf('Actions=new-window;')));
    });

    test('removes keys and groups', () {
      final KeyFile f = KeyFile.parse(_sample)
        ..set('Desktop Entry', 'Icon', null)
        ..removeGroup('Desktop Action new-window');
      final String out = f.serialize();
      expect(out, isNot(contains('Icon=')));
      expect(out, isNot(contains('[Desktop Action')));
    });

    test('creates groups in an empty file', () {
      final KeyFile f = KeyFile.empty()..set('Default Applications', 'text/plain', 'org.gnome.TextEditor.desktop;');
      expect(f.serialize(), '[Default Applications]\ntext/plain=org.gnome.TextEditor.desktop;\n');
    });

    test('string escapes round-trip', () {
      const String value = ' leading space\twith tab\nand \\ backslash';
      expect(KeyFile.unescape(KeyFile.escape(value)), value);
    });

    test('lists honour escaped semicolons', () {
      expect(KeyFile.splitList(r'a;b\;c;d;'), <String>['a', 'b;c', 'd']);
      expect(KeyFile.joinList(<String>['a', 'b;c']), r'a;b\;c;');
      expect(KeyFile.joinList(<String>['', ' ']), isNull);
    });
  });

  group('Exec parsing', () {
    test('splits quoted arguments', () {
      expect(splitExec(r'"/opt/My App/run" --flag %U'), <String>['/opt/My App/run', '--flag', '%U']);
      expect(splitExec(r'sh -c "echo \"hi\""'), <String>['sh', '-c', 'echo "hi"']);
    });

    test('finds the program behind env', () {
      expect(execProgram('env FOO=1 BAR=2 /usr/bin/thing %f'), '/usr/bin/thing');
      expect(execProgram('firefox %u'), 'firefox');
      expect(execProgram(''), isNull);
    });

    test('quotes paths that need it', () {
      expect(quoteExecArg('/usr/bin/foo'), '/usr/bin/foo');
      expect(quoteExecArg('/opt/My App/run'), '"/opt/My App/run"');
      expect(splitExec(quoteExecArg(r'/tmp/a "b" $c')), <String>[r'/tmp/a "b" $c']);
    });
  });

  group('Locale keys', () {
    test('derives lookup order from LANG', () {
      expect(localeKeysFrom(<String, String>{'LANG': 'ta_IN.UTF-8'}), <String>['ta_IN', 'ta']);
      expect(localeKeysFrom(<String, String>{'LANG': 'sr_RS.UTF-8@latin'}), <String>[
        'sr_RS@latin',
        'sr_RS',
        'sr@latin',
        'sr',
      ]);
      expect(localeKeysFrom(<String, String>{'LANG': 'C'}), isEmpty);
    });
  });

  group('Sizes', () {
    test('parses pacman/flatpak style sizes', () {
      expect(Fmt.parseSize('12.00 MiB'), 12 * 1024 * 1024);
      expect(Fmt.parseSize('512 KiB'), 512 * 1024);
      expect(Fmt.parseSize('1.5 GB'), 1500000000);
      expect(Fmt.parseSize('0 B'), 0);
      expect(Fmt.parseSize('garbage'), isNull);
    });

    test('formats bytes', () {
      expect(Fmt.bytes(0), '0 B');
      expect(Fmt.bytes(1536), '1.5 KB');
      expect(Fmt.bytes(5 * 1024 * 1024 * 1024), '5.0 GB');
    });
  });
}
