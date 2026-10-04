import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../core/system/command_runner.dart';
import '../../core/system/shell_env.dart';
import 'data/disk_scanner.dart';

/// An entry shown in the folder browser (a sub-folder or a file).
class FolderItem {
  const FolderItem({required this.path, required this.size, required this.isDir, this.node, this.modified});

  final String path;
  final int size;
  final bool isDir;
  final DirNode? node;
  final DateTime? modified;

  String get name => path.substring(path.lastIndexOf('/') + 1);
}

/// Outcome of deleting or trashing a set of paths.
class DeleteOutcome {
  const DeleteOutcome({required this.removed, required this.failures, required this.freed});

  final List<String> removed;
  final Map<String, String> failures;
  final int freed;
}

class StorageController extends ChangeNotifier {
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

  /// The smallest "large file" size collected while scanning; the Large
  /// files tab filters the results further by the chosen threshold.
  static const int scanMinFileBytes = 50 * 1024 * 1024;

  List<DiskInfo> _disks = <DiskInfo>[];
  bool _loadingDisks = false;
  String _root = ShellEnv.instance.home;
  bool _scanning = false;
  ScanProgress? _progress;
  ScanResult? _result;
  String? _error;
  CancelToken? _cancel;

  DirNode? _current;
  List<FolderItem> _items = <FolderItem>[];
  bool _loadingItems = false;

  List<DiskInfo> get disks => _disks;
  bool get loadingDisks => _loadingDisks;
  String get root => _root;
  bool get scanning => _scanning;
  ScanProgress? get progress => _progress;
  ScanResult? get result => _result;
  String? get error => _error;
  DirNode? get current => _current;
  List<FolderItem> get items => _items;
  bool get loadingItems => _loadingItems;

  List<LargeFile> largeFiles(int minBytes) =>
      (_result?.largeFiles ?? const <LargeFile>[]).where((LargeFile f) => f.size >= minBytes).toList();

  Future<void> loadDisks() async {
    _loadingDisks = true;
    notifyListeners();
    try {
      _disks = await DiskScanner.disks();
    } on Object {
      _disks = <DiskInfo>[];
    } finally {
      _loadingDisks = false;
      notifyListeners();
    }
  }

  set root(String value) {
    if (_scanning || value == _root) return;
    _root = value;
    _result = null;
    _current = null;
    _items = <FolderItem>[];
    notifyListeners();
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _error = null;
    _progress = const ScanProgress(folders: 0, files: 0);
    final CancelToken cancel = _cancel = CancelToken();
    notifyListeners();
    try {
      final ScanResult result = await DiskScanner.scan(
        _root,
        minFileBytes: scanMinFileBytes,
        oneFileSystem: AppSettings.instance.stayOnFilesystem,
        cancel: cancel,
        onProgress: (ScanProgress p) {
          _progress = p;
          notifyListeners();
        },
      );
      if (cancel.isCancelled) return;
      if (result.root == null) {
        _error = 'Could not read "$_root". Check that the folder exists and is readable.';
      } else {
        _result = result;
        await _show(result.root!);
      }
      loadDisks();
    } on Object catch (e) {
      _error = 'Scan failed: $e';
    } finally {
      _scanning = false;
      _cancel = null;
      notifyListeners();
    }
  }

  void cancelScan() => _cancel?.cancel();

  Future<void> open(DirNode node) => _show(node);

  Future<void> up() async {
    final DirNode? parent = _current?.parent;
    if (parent != null) await _show(parent);
  }

  Future<void> _show(DirNode node) async {
    _current = node;
    _loadingItems = true;
    _items = <FolderItem>[
      for (final DirNode c in node.children) FolderItem(path: c.path, size: c.size, isDir: true, node: c),
    ];
    notifyListeners();
    final List<FolderItem> files = await _listFiles(node.path);
    if (!identical(_current, node)) return;
    _items = <FolderItem>[
      for (final DirNode c in node.children) FolderItem(path: c.path, size: c.size, isDir: true, node: c),
      ...files,
    ]..sort((FolderItem a, FolderItem b) => b.size.compareTo(a.size));
    _loadingItems = false;
    notifyListeners();
  }

  static Future<List<FolderItem>> _listFiles(String dir) async {
    final List<FolderItem> files = <FolderItem>[];
    try {
      await for (final FileSystemEntity e in Directory(dir).list(followLinks: false)) {
        if (e is! File) continue;
        try {
          final FileStat stat = await e.stat();
          files.add(FolderItem(path: e.path, size: stat.size, isDir: false, modified: stat.modified));
        } on FileSystemException {
          // Vanished or unreadable; skip.
        }
      }
    } on FileSystemException {
      // Unreadable directory.
    }
    return files;
  }

  // ------------------------------------------------------------- deletion

  /// Paths that must never be deleted from the storage browser.
  static String _trimSlash(String path) =>
      path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  static Set<String>? _mountPoints;

  /// Every mount point (a whole drive or partition is never deleted from
  /// here), read once from /proc/self/mountinfo.
  static Set<String> get mountPoints {
    if (_mountPoints != null) return _mountPoints!;
    final Set<String> points = <String>{};
    try {
      for (final String line in File('/proc/self/mountinfo').readAsLinesSync()) {
        final List<String> f = line.split(' ');
        if (f.length > 4) {
          points.add(
            f[4].replaceAllMapped(
              RegExp(r'\\([0-7]{3})'),
              (Match m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
            ),
          );
        }
      }
    } on FileSystemException {
      // Not Linux /proc; rely on the static list below.
    }
    return _mountPoints = points;
  }

  static bool isProtected(String path) {
    final String home = _trimSlash(ShellEnv.instance.home);
    final String p = _trimSlash(path);
    if (mountPoints.contains(p)) return true;
    const Set<String> system = <String>{
      '/',
      '/bin',
      '/boot',
      '/dev',
      '/etc',
      '/home',
      '/lib',
      '/lib32',
      '/lib64',
      '/mnt',
      '/media',
      '/opt',
      '/proc',
      '/root',
      '/run',
      '/sbin',
      '/srv',
      '/sys',
      '/tmp',
      '/usr',
      '/var',
    };
    if (system.contains(p)) return true;
    for (final String prefix in <String>[
      '/usr/',
      '/etc/',
      '/boot/',
      '/proc/',
      '/sys/',
      '/dev/',
      '/run/',
      '/bin/',
      '/sbin/',
      '/lib/',
      '/lib64/',
      '/lib32/',
      '/var/',
      '/opt/',
      '/srv/',
      '/root/',
      // Private keys.
      '$home/.ssh/',
      '$home/.gnupg/',
    ]) {
      if (p.startsWith(prefix)) return true;
    }
    final Set<String> homeCritical = <String>{
      home,
      '$home/.config',
      '$home/.local',
      '$home/.local/share',
      '$home/.local/bin',
      '$home/.ssh',
      '$home/.gnupg',
    };
    return homeCritical.contains(p);
  }

  Future<DeleteOutcome> delete(List<String> paths, {required bool toTrash}) async {
    final List<String> removed = <String>[];
    final Map<String, String> failures = <String, String>{};
    final Map<String, int> sizes = <String, int>{for (final String p in paths) p: _knownSize(p)};

    final List<String> allowed = <String>[];
    for (final String p in paths) {
      if (isProtected(p)) {
        failures[p] = 'Protected location';
      } else {
        allowed.add(p);
      }
    }

    if (toTrash && allowed.isNotEmpty) {
      if (!ShellEnv.instance.has('gio')) {
        for (final String p in allowed) {
          failures[p] = '"gio" (GLib) is not installed, so the Trash is unavailable';
        }
      } else {
        // One gio call per item, so a single failure doesn't hide the rest.
        for (final String p in allowed) {
          final CommandResult r = await CommandRunner.run('gio', <String>[
            'trash',
            '--',
            p,
          ], timeout: const Duration(minutes: 10));
          if (r.ok) {
            removed.add(p);
          } else {
            failures[p] = r.errorSummary;
          }
        }
      }
    } else {
      for (final String p in allowed) {
        try {
          final FileSystemEntityType type = FileSystemEntity.typeSync(p, followLinks: false);
          switch (type) {
            case FileSystemEntityType.directory:
              await Directory(p).delete(recursive: true);
            case FileSystemEntityType.link:
              await Link(p).delete();
            case FileSystemEntityType.notFound:
              break;
            default:
              await File(p).delete();
          }
          removed.add(p);
        } on FileSystemException catch (e) {
          failures[p] = e.osError?.message ?? e.message;
        }
      }
    }

    int freed = 0;
    for (final String p in removed) {
      freed += sizes[p] ?? 0;
      _forget(p, sizes[p] ?? 0);
    }
    if (removed.isNotEmpty) {
      notifyListeners();
      loadDisks();
    }
    return DeleteOutcome(removed: removed, failures: failures, freed: freed);
  }

  int _knownSize(String path) {
    final DirNode? node = _result?.root?.find(path);
    if (node != null) return node.size;
    for (final FolderItem i in _items) {
      if (i.path == path) return i.size;
    }
    for (final LargeFile f in _result?.largeFiles ?? const <LargeFile>[]) {
      if (f.path == path) return f.size;
    }
    return 0;
  }

  void _forget(String path, int size) {
    final DirNode? root = _result?.root;
    final DirNode? node = root?.find(path);
    if (node != null) {
      node.detach();
    } else if (root != null) {
      // A file: subtract from its folder and all ancestors.
      final String dir = path.substring(0, path.lastIndexOf('/').clamp(1, path.length));
      DirNode? a = root.find(dir);
      while (a != null) {
        a.size = (a.size - size).clamp(0, 1 << 62);
        a = a.parent;
      }
    }
    _result?.largeFiles.removeWhere((LargeFile f) => f.path == path || f.path.startsWith('$path/'));
    _items = _items.where((FolderItem i) => i.path != path).toList();
  }
}
