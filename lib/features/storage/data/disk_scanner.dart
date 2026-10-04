import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/system/command_runner.dart';
import '../../../core/system/shell_env.dart';

/// A directory with its total disk usage (from `du`).
class DirNode {
  DirNode(this.path, this.size);

  final String path;
  int size;
  DirNode? parent;
  final List<DirNode> children = <DirNode>[];

  String get name {
    if (path == '/') return '/';
    final int i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
  }

  void sortRecursively() {
    final List<DirNode> stack = <DirNode>[this];
    while (stack.isNotEmpty) {
      final DirNode n = stack.removeLast();
      n.children.sort((DirNode a, DirNode b) => b.size.compareTo(a.size));
      stack.addAll(n.children);
    }
  }

  DirNode? find(String target) {
    if (target == path) return this;
    DirNode current = this;
    while (true) {
      DirNode? next;
      for (final DirNode c in current.children) {
        if (target == c.path) return c;
        if (target.startsWith('${c.path}/')) {
          next = c;
          break;
        }
      }
      if (next == null) return null;
      current = next;
    }
  }

  /// Removes this node from its parent and subtracts its size up the tree.
  void detach() {
    final DirNode? p = parent;
    if (p == null) return;
    p.children.remove(this);
    DirNode? a = p;
    while (a != null) {
      a.size = (a.size - size).clamp(0, 1 << 62);
      a = a.parent;
    }
    parent = null;
  }
}

/// A large file found by `find`.
class LargeFile {
  const LargeFile({required this.path, required this.size, required this.modified});

  final String path;
  final int size;
  final DateTime modified;

  String get name => path.substring(path.lastIndexOf('/') + 1);

  String get directory {
    final int i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }
}

/// One mounted filesystem from `df`.
class DiskInfo {
  const DiskInfo({
    required this.source,
    required this.fsType,
    required this.size,
    required this.used,
    required this.available,
    required this.mountPoint,
  });

  final String source;
  final String fsType;
  final int size;
  final int used;
  final int available;
  final String mountPoint;

  double get fraction => size <= 0 ? 0 : (used / size).clamp(0, 1);
}

class ScanProgress {
  const ScanProgress({required this.folders, required this.files});

  final int folders;
  final int files;
}

class ScanResult {
  const ScanResult({required this.root, required this.largeFiles, required this.errors, required this.duration});

  final DirNode? root;
  final List<LargeFile> largeFiles;
  final int errors;
  final Duration duration;
}

/// Disk usage analysis built on `du` and `find` (coreutils/findutils are on
/// every Linux system and are much faster than walking the tree in Dart).
abstract final class DiskScanner {
  static const int maxLargeFiles = 1000;

  static Future<List<DiskInfo>> disks() async {
    final CommandResult result = await CommandRunner.run('df', <String>[
      '-B1',
      '--output=source,fstype,size,used,avail,target',
      for (final String t in <String>[
        'tmpfs',
        'devtmpfs',
        'efivarfs',
        'overlay',
        'squashfs',
        'ramfs',
        'proc',
        'sysfs',
        'cgroup2',
        'devpts',
        'autofs',
        'nsfs',
        'tracefs',
        'debugfs',
        'fuse.portal',
        'fuse.gvfsd-fuse',
      ]) ...<String>['-x', t],
    ], timeout: const Duration(seconds: 15));
    // df exits non-zero when one mount is unreadable but still prints the rest.
    final List<DiskInfo> disks = <DiskInfo>[];
    final Set<String> seenSources = <String>{};
    final List<String> lines = result.stdout.split('\n');
    for (final String line in lines.skip(1)) {
      final List<String> parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      final int? size = int.tryParse(parts[2]);
      final int? used = int.tryParse(parts[3]);
      final int? avail = int.tryParse(parts[4]);
      if (size == null || used == null || avail == null || size == 0) continue;
      final String mount = parts.sublist(5).join(' ');
      // Btrfs subvolumes and bind mounts repeat the same device; keep the first.
      if (!seenSources.add(parts[0])) continue;
      disks.add(
        DiskInfo(source: parts[0], fsType: parts[1], size: size, used: used, available: avail, mountPoint: mount),
      );
    }
    return disks;
  }

  /// Scans [root]: directory sizes (for the folder tree) and files larger
  /// than [minFileBytes].
  static Future<ScanResult> scan(
    String root, {
    required int minFileBytes,
    required bool oneFileSystem,
    void Function(ScanProgress progress)? onProgress,
    CancelToken? cancel,
  }) async {
    await ShellEnv.instance.ready;
    final Stopwatch watch = Stopwatch()..start();
    final String normalizedRoot = root.length > 1 && root.endsWith('/') ? root.substring(0, root.length - 1) : root;

    int folders = 0;
    int files = 0;
    Timer? ticker;
    if (onProgress != null) {
      ticker = Timer.periodic(const Duration(milliseconds: 300), (_) {
        onProgress(ScanProgress(folders: folders, files: files));
      });
    }

    try {
      final Future<_Raw> du = _collect(
        'du',
        <String>['-0', '-B1', if (oneFileSystem) '-x', '--', normalizedRoot],
        cancel,
        (int records) => folders += records,
      );
      final int kib = (minFileBytes / 1024).ceil();
      final Future<_Raw> find = _collect(
        'find',
        <String>[
          normalizedRoot,
          if (oneFileSystem) '-xdev',
          '-type',
          'f',
          '-size',
          '+${kib}k',
          '-printf',
          r'%s\t%T@\t%p\0',
        ],
        cancel,
        (int records) => files += records,
      );
      final List<_Raw> raws = await Future.wait(<Future<_Raw>>[du, find]);
      if (cancel?.isCancelled ?? false) {
        return ScanResult(root: null, largeFiles: const <LargeFile>[], errors: 0, duration: watch.elapsed);
      }
      final Uint8List duBytes = raws[0].bytes;
      final Uint8List findBytes = raws[1].bytes;
      final _Parsed parsed = await _parseInIsolate(duBytes, findBytes, normalizedRoot);
      return ScanResult(
        root: parsed.root,
        largeFiles: parsed.files,
        errors: raws[0].errorLines + raws[1].errorLines,
        duration: watch.elapsed,
      );
    } finally {
      ticker?.cancel();
    }
  }

  static Future<_Parsed> _parseInIsolate(Uint8List du, Uint8List find, String root) {
    return Isolate.run(() => _Parsed(_parseDu(du, root), _parseFind(find)));
  }

  static Future<_Raw> _collect(
    String executable,
    List<String> args,
    CancelToken? cancel,
    void Function(int records) onRecords,
  ) async {
    final String? exe = ShellEnv.instance.which(executable);
    if (exe == null) {
      throw StateError('"$executable" is not installed');
    }
    final Process process = await Process.start(
      exe,
      args,
      environment: ShellEnv.instance.childEnvironment(),
      includeParentEnvironment: false,
    );
    unawaited(process.stdin.close().catchError((Object _) {}));
    void kill() => process.kill();
    cancel?.addListener(kill);
    final BytesBuilder out = BytesBuilder(copy: false);
    int errorLines = 0;
    final Future<void> errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((String _) => errorLines++);
    await for (final List<int> chunk in process.stdout) {
      out.add(chunk);
      int n = 0;
      for (int i = 0; i < chunk.length; i++) {
        if (chunk[i] == 0) n++;
      }
      onRecords(n);
    }
    await process.exitCode;
    await errDone.timeout(const Duration(seconds: 5), onTimeout: () {});
    cancel?.removeListener(kill);
    return _Raw(out.takeBytes(), errorLines);
  }

  static DirNode? _parseDu(Uint8List bytes, String root) {
    const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
    final Map<String, DirNode> nodes = <String, DirNode>{};
    int start = 0;
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      if (i > start) {
        final String record = decoder.convert(bytes, start, i);
        final int tab = record.indexOf('\t');
        if (tab > 0) {
          final int? size = int.tryParse(record.substring(0, tab));
          final String path = record.substring(tab + 1);
          if (size != null) nodes[path] = DirNode(path, size);
        }
      }
      start = i + 1;
    }
    final DirNode? rootNode = nodes[root];
    if (rootNode == null) return null;
    for (final DirNode node in nodes.values) {
      if (identical(node, rootNode)) continue;
      final int slash = node.path.lastIndexOf('/');
      if (slash < 0) continue;
      final String parentPath = slash == 0 ? '/' : node.path.substring(0, slash);
      final DirNode? parent = nodes[parentPath];
      if (parent != null) {
        node.parent = parent;
        parent.children.add(node);
      }
    }
    rootNode.sortRecursively();
    return rootNode;
  }

  static List<LargeFile> _parseFind(Uint8List bytes) {
    const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
    final List<LargeFile> files = <LargeFile>[];
    int start = 0;
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      if (i > start) {
        final String record = decoder.convert(bytes, start, i);
        final int t1 = record.indexOf('\t');
        final int t2 = t1 < 0 ? -1 : record.indexOf('\t', t1 + 1);
        if (t1 > 0 && t2 > t1) {
          final int? size = int.tryParse(record.substring(0, t1));
          final double? mtime = double.tryParse(record.substring(t1 + 1, t2));
          if (size != null) {
            files.add(
              LargeFile(
                path: record.substring(t2 + 1),
                size: size,
                modified: DateTime.fromMillisecondsSinceEpoch(((mtime ?? 0) * 1000).round()),
              ),
            );
          }
        }
      }
      start = i + 1;
    }
    files.sort((LargeFile a, LargeFile b) => b.size.compareTo(a.size));
    return files.length > maxLargeFiles ? files.sublist(0, maxLargeFiles) : files;
  }

  /// Total disk usage of [paths] in bytes (missing paths count as 0).
  static Future<int> usage(List<String> paths, {bool oneFileSystem = false}) async {
    final List<String> existing = paths
        .where((String p) => FileSystemEntity.typeSync(p, followLinks: false) != FileSystemEntityType.notFound)
        .toList();
    if (existing.isEmpty) return 0;
    final CommandResult result = await CommandRunner.run('du', <String>[
      '-s',
      '-c',
      '-B1',
      if (oneFileSystem) '-x',
      '--',
      ...existing,
    ], timeout: const Duration(minutes: 5));
    // The last line is the grand total ("<bytes>\ttotal").
    final List<String> lines = result.stdout.trim().split('\n');
    if (lines.isEmpty) return 0;
    return int.tryParse(lines.last.split('\t').first.trim()) ?? 0;
  }
}

class _Raw {
  _Raw(this.bytes, this.errorLines);

  final Uint8List bytes;
  final int errorLines;
}

class _Parsed {
  _Parsed(this.root, this.files);

  final DirNode? root;
  final List<LargeFile> files;
}
