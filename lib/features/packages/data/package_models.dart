import 'package:material_ui/material_ui.dart';

/// One installed package, normalised across package managers.
class InstalledPackage {
  const InstalledPackage({
    required this.name,
    required this.version,
    required this.managerId,
    this.description,
    this.size,
    this.installDate,
    this.explicit,
    this.origin,
    this.url,
    this.removeId,
    this.scope,
    this.details = const <String, String>{},
  });

  final String name;
  final String version;
  final String managerId;
  final String? description;

  /// Installed size in bytes, when the manager reports it.
  final int? size;
  final DateTime? installDate;

  /// `true` = installed explicitly, `false` = pulled in as a dependency,
  /// `null` = the manager does not track this.
  final bool? explicit;

  /// Repository / remote / registry the package came from.
  final String? origin;
  final String? url;

  /// Identifier to pass to the uninstall command when it differs from
  /// [name] (e.g. a Flatpak application ID).
  final String? removeId;

  /// `user` or `system` for managers with per-user installs (Flatpak).
  final String? scope;

  /// Extra key/value details shown in the details sheet.
  final Map<String, String> details;

  String get id => '$managerId:${scope ?? ''}:$name';

  String get searchText => '$name ${description ?? ''} ${origin ?? ''}'.toLowerCase();
}

/// How to uninstall a package.
class RemovalPlan {
  const RemovalPlan({required this.argv, required this.needsRoot, this.warning, this.reason});

  final List<String> argv;
  final bool needsRoot;

  /// Shown prominently in the confirmation dialog.
  final String? warning;

  /// Shown in the sudo password prompt.
  final String? reason;

  String get commandLine => argv.map((String a) => a.contains(' ') ? "'$a'" : a).join(' ');
}

/// A package manager adapter.
abstract class PackageManager {
  const PackageManager();

  /// Stable identifier, e.g. `pacman`.
  String get id;

  /// Short label for filter chips.
  String get label;

  /// One-line description.
  String get description;

  IconData get icon;

  /// System package managers are listed before language/tool installers.
  bool get isSystem => false;

  /// Whether this manager can tell explicit installs from dependencies.
  bool get tracksExplicit => false;

  Future<bool> detect();

  Future<List<InstalledPackage>> list();

  /// Null when uninstalling is not supported from the app.
  RemovalPlan? removalPlan(InstalledPackage package);

  /// Optional dry run: what the removal would affect, or why it would fail.
  Future<RemovalPreview?> removalPreview(InstalledPackage package) async => null;
}

/// Result of a removal dry run.
class RemovalPreview {
  const RemovalPreview({this.items = const <String>[], this.blocker});

  /// Packages (with versions/sizes) that would be removed.
  final List<String> items;

  /// Why the removal cannot proceed (e.g. other packages depend on it).
  final String? blocker;
}

/// Packages that would leave the system unbootable or unmanageable if
/// removed. Removal is still possible, but needs an explicit acknowledgement.
const Set<String> kCriticalPackages = <String>{
  // Arch Linux
  'base', 'linux', 'linux-lts', 'linux-zen', 'linux-hardened', 'linux-firmware', 'glibc', 'gcc-libs',
  'systemd', 'systemd-libs', 'pacman', 'filesystem', 'bash', 'coreutils', 'util-linux', 'shadow',
  'pam', 'sudo', 'polkit', 'grub', 'mkinitcpio', 'dracut', 'archlinux-keyring', 'openssl', 'dbus',
  'networkmanager', 'iproute2', 'e2fsprogs', 'btrfs-progs', 'xfsprogs', 'mesa', 'wayland', 'xorg-server',
  // Debian / Ubuntu
  'apt', 'dpkg', 'libc6', 'libc-bin', 'init', 'systemd-sysv', 'login', 'passwd', 'base-files',
  // Fedora / openSUSE
  'rpm', 'dnf', 'zypper', 'kernel', 'kernel-core', 'kernel-default',
  // Alpine / Void / others
  'apk-tools', 'musl', 'busybox', 'alpine-base', 'xbps', 'base-system', 'runit',
};
