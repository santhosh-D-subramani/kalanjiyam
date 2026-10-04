# Changelog

## 1.0.3

- Set the application ID to `com.santhoshDsubramani.kalanjiyam`.
- Added a desktop file (with Packages/Launchers/Storage actions and a Tamil name), an SVG app icon and
  `linux/packaging/install.sh` for a per-user install.

## 1.0.2

Security and correctness fixes from a code review:

- Programs run as administrator, and `sudo`/`pkexec` themselves, are only taken from root-owned system
  folders (`/usr/bin`, `/usr/sbin`, …), never from user-writable PATH entries such as `~/.local/bin`.
- sudo: the password is never sent when sudo would not read it (NOPASSWD rules are detected first).
- Root commands get a root-side time limit, since a pkexec'd process cannot be killed by the app.
- Launchers: administrator edits/deletes only for files really in `/usr/share/applications`,
  `/usr/local/share/applications` or `/etc/xdg`; Flatpak, Snap and Nix launchers get a personal copy instead.
  The root copy refuses a source file that was swapped for a symlink.
- Saving launchers and `mimeapps.list` writes through symlinks (dotfile managers) instead of replacing them.
- Editor keeps unchanged values byte for byte (escapes such as `\;` survive).
- dnf (4) and zypper uninstall now show which installed packages depend on the target; Portage deselects
  the package before `--depclean`; the core-package warning also matches `libc6:amd64` / `glibc.x86_64`.
- Storage: mount points, the contents of `~/.ssh`/`~/.gnupg`, and `/var`, `/opt`, `/srv` are protected.
- Cache cleaning works when `~/.cache` or `XDG_*` dirs are symlinks to another drive.
- Maven cache path ignores commented-out settings; polkit agent scan runs off the UI thread;
  controllers no longer notify after disposal.

## 1.0.1

- Cache cleaner: always protect `~/.config`, `~/.cache` and `~/.local/share`, even when `XDG_*` variables point elsewhere.
- Polkit agent detection now finds agents built into desktop shells (e.g. quickshell) by their loaded agent library.
- Added isolated write-path tests for launchers, default apps and cache deletion.

## 1.0.0

- Packages: lists installed packages from pacman, AUR/foreign (yay, paru, …), apt, dnf, zypper, apk, xbps,
  portage, eopkg, Nix, Guix, Flatpak, Snap, AppImage, Homebrew and language tools (npm, pnpm, Yarn, Bun, Deno,
  pipx, uv, pip, Cargo, Go, RubyGems, Composer, Dart pub, .NET, mise, asdf, SDKMAN!). Filter per manager,
  search, sort, details, uninstall with a dry-run preview (pacman, apt) and core-package protection.
- Launchers: browse, edit, add and delete `.desktop` entries (format-preserving), icon/exec/folder pickers,
  categories, MIME types with default-app toggles, actions, raw source editing and validation.
  System entries can be hidden or overridden per user, or edited/deleted with admin rights.
- Storage: disk overview, folder-size browser, large-file finder, Trash or permanent delete with protected
  paths, and a cache cleaner for ~70 tools (npm, pub, Gradle, Cargo, pip, uv, pacman, yay, journal, …).
- Admin access through polkit (pkexec) with an automatic in-app sudo fallback when no polkit agent runs.
- Material 3 Expressive UI (material_3_expressive), light/dark/system theme and colour choices.
