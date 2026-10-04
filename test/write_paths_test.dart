import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kalanjiyam/core/system/shell_env.dart';
import 'package:kalanjiyam/features/desktop_entries/data/desktop_entry.dart';
import 'package:kalanjiyam/features/desktop_entries/data/desktop_entry_repository.dart';
import 'package:kalanjiyam/features/desktop_entries/data/key_file.dart';
import 'package:kalanjiyam/features/desktop_entries/data/mime_apps.dart';
import 'package:kalanjiyam/features/storage/data/cache_model.dart';

/// Exercises the code paths that write to disk. Run only with XDG_DATA_HOME
/// and XDG_CONFIG_HOME pointing at a throwaway directory (see the guard).
void main() {
  final String? data = Platform.environment['XDG_DATA_HOME'];
  final bool isolated = data != null && data.contains('kalanjiyam-test');

  test('launcher create / edit / default app / delete', () async {
    await ShellEnv.instance.ready;
    final DesktopEntryRepository repo = DesktopEntryRepository.instance;
    final String id = repo.suggestId('My Test App', const <String>[]);
    expect(id, 'my-test-app.desktop');

    final KeyFile f = KeyFile.empty()
      ..set(kDesktopEntryGroup, 'Type', 'Application')
      ..set(kDesktopEntryGroup, 'Name', 'My Test App')
      ..set(kDesktopEntryGroup, 'Exec', '/usr/bin/true %U')
      ..set(kDesktopEntryGroup, 'MimeType', KeyFile.joinList(<String>['text/x-kalanjiyam-test']));
    final ValidationReport report = await repo.validate(id, f.serialize());
    expect(report.errors, isEmpty, reason: report.errors.join('\n'));
    final String path = await repo.writeUserEntry(id, f.serialize());
    expect(File(path).readAsStringSync(), contains('Name=My Test App'));

    final List<DesktopEntry> entries = await repo.scan();
    final DesktopEntry mine = entries.firstWhere((DesktopEntry e) => e.id == id);
    expect(mine.isUser, isTrue);
    expect(mine.isBroken, isFalse);

    // Edit in place keeps unknown keys.
    final KeyFile edited = mine.file.copy()
      ..set(kDesktopEntryGroup, 'X-Custom', 'keep-me')
      ..set(kDesktopEntryGroup, 'Name', 'Renamed');
    await repo.writeFile(mine.path, edited.serialize());
    expect(File(mine.path).readAsStringSync(), allOf(contains('Name=Renamed'), contains('X-Custom=keep-me')));

    // Default application.
    await MimeApps.instance.setDefault(id, <String>['text/x-kalanjiyam-test']);
    final Map<String, String?> d = await MimeApps.instance.defaultsFor(
      <String>['text/x-kalanjiyam-test'],
      <String>{id},
    );
    expect(d['text/x-kalanjiyam-test'], id);
    await MimeApps.instance.clearDefault(id, <String>['text/x-kalanjiyam-test']);
    final Map<String, String?> d2 = await MimeApps.instance.defaultsFor(
      <String>['text/x-kalanjiyam-test'],
      <String>{id},
    );
    expect(d2['text/x-kalanjiyam-test'], isNull);

    // Hide a "system" entry via override, then delete the user file.
    await repo.hideWithOverride(mine);
    expect(File(repo.userPathFor(id)).readAsStringSync(), contains('NoDisplay=true'));
    await repo.deleteUserEntry(mine);
    await MimeApps.instance.forget(id);
    expect(File(mine.path).existsSync(), isFalse);
  }, skip: isolated ? false : 'Run with XDG_DATA_HOME/XDG_CONFIG_HOME set to a kalanjiyam-test temp dir');

  test('cache deletion stays inside home and refuses protected paths', () async {
    await ShellEnv.instance.ready;
    final String home = ShellEnv.instance.home;
    expect(CacheCleaner.isSafeToDelete(home), isFalse);
    expect(CacheCleaner.isSafeToDelete('$home/.config'), isFalse);
    expect(CacheCleaner.isSafeToDelete('/var/cache/pacman/pkg'), isFalse);
    expect(CacheCleaner.isSafeToDelete('$home/../../etc'), isFalse);

    final Directory tmp = Directory('$data/cache-case')..createSync(recursive: true);
    File('${tmp.path}/a.bin').writeAsStringSync('x');
    Directory('${tmp.path}/sub').createSync();
    File('${tmp.path}/sub/b.bin').writeAsStringSync('y');
    // A symlinked cache root must never be followed.
    final Directory outside = Directory('$data/outside')..createSync();
    File('${outside.path}/precious').writeAsStringSync('keep');
    final Link link = Link('${tmp.path}/link')..createSync(outside.path);

    final List<String> log = <String>[];
    await CacheCleaner.deletePaths(<String>[tmp.path], log.add, contentsOnly: true);
    expect(tmp.existsSync(), isTrue);
    expect(tmp.listSync(), isEmpty);
    expect(link.existsSync(), isFalse);
    expect(File('${outside.path}/precious').existsSync(), isTrue, reason: 'symlink target must survive');
  }, skip: isolated && (data.startsWith(Platform.environment['HOME']!)) ? false : 'needs isolated dir inside HOME');
}
