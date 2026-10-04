import 'dart:io';

/// Writes [text] to [path] atomically (temp file + rename).
///
/// If [path] is a symlink (dotfile managers such as stow or chezmoi), the
/// link's target is updated instead of replacing the link with a file.
Future<void> atomicWrite(String path, String text) async {
  String target = path;
  if (FileSystemEntity.isLinkSync(path)) {
    try {
      target = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      // Dangling link: resolve it one level and create the target.
      final String link = Link(path).targetSync();
      target = link.startsWith('/') ? link : '${File(path).parent.path}/$link';
    }
  }
  await File(target).parent.create(recursive: true);
  final File tmp = File('$target.kalanjiyam-tmp');
  try {
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(target);
  } on FileSystemException {
    // The file is writable but its directory is not: write in place.
    if (tmp.existsSync()) await tmp.delete();
    await File(target).writeAsString(text, flush: true);
  }
}
