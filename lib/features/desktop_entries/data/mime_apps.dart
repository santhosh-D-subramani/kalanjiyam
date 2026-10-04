import 'dart:io';

import '../../../core/system/shell_env.dart';
import '../../../core/utils/atomic_write.dart';
import 'key_file.dart';

const String _defaultGroup = 'Default Applications';
const String _addedGroup = 'Added Associations';
const String _removedGroup = 'Removed Associations';

/// Known MIME types (from the shared-mime-info database) for suggestions.
class MimeDatabase {
  MimeDatabase._();

  static final MimeDatabase instance = MimeDatabase._();

  List<String>? _types;

  Future<List<String>> types() async {
    if (_types != null) return _types!;
    await ShellEnv.instance.ready;
    final Set<String> result = <String>{};
    final ShellEnv env = ShellEnv.instance;
    for (final String dir in <String>[env.xdgDataHome, ...env.xdgDataDirs]) {
      final File file = File('$dir/mime/types');
      if (!file.existsSync()) continue;
      try {
        for (final String line in await file.readAsLines()) {
          final String t = line.trim();
          if (t.isNotEmpty && t.contains('/')) result.add(t);
        }
      } on Object {
        // Ignore unreadable databases.
      }
    }
    // A few pseudo types used by launchers for URL handlers.
    result.addAll(const <String>[
      'x-scheme-handler/http',
      'x-scheme-handler/https',
      'x-scheme-handler/mailto',
      'x-scheme-handler/ftp',
      'inode/directory',
    ]);
    return _types = result.toList()..sort();
  }
}

/// Reads and writes default-application associations (`mimeapps.list`), as
/// defined by the freedesktop "Association between MIME types and
/// applications" specification.
class MimeApps {
  MimeApps._();

  static final MimeApps instance = MimeApps._();

  String get _userFile => '${ShellEnv.instance.xdgConfigHome}/mimeapps.list';

  /// Lookup order: desktop-specific files before generic ones, config dirs
  /// before data dirs, user before system.
  List<String> _lookupFiles() {
    final ShellEnv env = ShellEnv.instance;
    final List<String> desktops = env.currentDesktops;
    final List<String> files = <String>[];
    void addDir(String dir) {
      for (final String d in desktops) {
        files.add('$dir/$d-mimeapps.list');
      }
      files.add('$dir/mimeapps.list');
    }

    addDir(env.xdgConfigHome);
    env.xdgConfigDirs.forEach(addDir);
    addDir('${env.xdgDataHome}/applications');
    for (final String d in env.xdgDataDirs) {
      addDir('$d/applications');
    }
    return files;
  }

  /// Current default desktop ID for each of [mimeTypes] (null when unset).
  /// [installedIds] filters out defaults that point to missing launchers.
  Future<Map<String, String?>> defaultsFor(Iterable<String> mimeTypes, Set<String> installedIds) async {
    await ShellEnv.instance.ready;
    final List<KeyFile> files = <KeyFile>[];
    for (final String path in _lookupFiles()) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      try {
        files.add(KeyFile.parse(await file.readAsString()));
      } on Object {
        // Skip unreadable files.
      }
    }
    final Map<String, String?> result = <String, String?>{};
    for (final String type in mimeTypes) {
      String? found;
      outer:
      for (final KeyFile file in files) {
        for (final String id in KeyFile.splitList(file.get(_defaultGroup, type))) {
          if (installedIds.contains(id)) {
            found = id;
            break outer;
          }
        }
      }
      result[type] = found;
    }
    return result;
  }

  /// Makes [desktopId] the default handler for [mimeTypes] for this user.
  Future<void> setDefault(String desktopId, Iterable<String> mimeTypes) async {
    await _edit((KeyFile file) {
      for (final String type in mimeTypes) {
        file.set(_defaultGroup, type, '$desktopId;');
        final List<String> added = KeyFile.splitList(file.get(_addedGroup, type));
        added
          ..remove(desktopId)
          ..insert(0, desktopId);
        file.set(_addedGroup, type, KeyFile.joinList(added));
        final List<String> removed = KeyFile.splitList(file.get(_removedGroup, type))..remove(desktopId);
        file.set(_removedGroup, type, KeyFile.joinList(removed));
      }
    });
  }

  /// Removes [desktopId] as the user's default for [mimeTypes].
  Future<void> clearDefault(String desktopId, Iterable<String> mimeTypes) async {
    await _edit((KeyFile file) {
      for (final String type in mimeTypes) {
        final List<String> ids = KeyFile.splitList(file.get(_defaultGroup, type))..remove(desktopId);
        file.set(_defaultGroup, type, KeyFile.joinList(ids));
      }
    });
  }

  /// Removes every user-level association that references [desktopId]
  /// (used after deleting a launcher).
  Future<void> forget(String desktopId) async {
    await _edit((KeyFile file) {
      for (final String group in <String>[_defaultGroup, _addedGroup]) {
        final KeyFileGroup? g = file.group(group);
        if (g == null) continue;
        for (final MapEntry<String, String> e in g.entries.entries) {
          final List<String> ids = KeyFile.splitList(e.value);
          if (ids.remove(desktopId)) {
            file.set(group, e.key, KeyFile.joinList(ids));
          }
        }
      }
    });
  }

  Future<void> _edit(void Function(KeyFile file) change) async {
    await ShellEnv.instance.ready;
    final List<String> targets = <String>[_userFile];
    // A desktop-specific user file overrides the generic one; keep it in sync
    // when it exists so the change actually takes effect.
    for (final String d in ShellEnv.instance.currentDesktops) {
      final String path = '${ShellEnv.instance.xdgConfigHome}/$d-mimeapps.list';
      if (File(path).existsSync()) targets.add(path);
    }
    for (final String path in targets) {
      final File file = File(path);
      final KeyFile keyFile = file.existsSync() ? KeyFile.parse(await file.readAsString()) : KeyFile.empty();
      change(keyFile);
      // Drop groups that became empty, except the main one we just touched.
      for (final String group in <String>[_addedGroup, _removedGroup]) {
        final KeyFileGroup? g = keyFile.group(group);
        if (g != null && g.keys.isEmpty) keyFile.removeGroup(group);
      }
      await atomicWrite(path, keyFile.serialize());
    }
  }
}
