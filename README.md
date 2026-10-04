# Kalanjiyam · களஞ்சியம்

*Kalanjiyam* means "storehouse" in Tamil. It is a Material 3 Expressive system manager for Linux that covers
installed packages, desktop launchers and disk space in one place.

## Features
- **Packages**: every installed package across system, universal and language package managers, with filters,
  search, details and uninstall.
- **Launchers**: edit, add and delete `.desktop` entries, including MIME types and default apps.
- **Storage**: biggest folders and files, safe deletion, and developer/system cache cleaning.

## Administrator access
Root is used only for system package removal, system cache cleaning and package-owned launchers. Kalanjiyam
uses `pkexec` when a polkit agent is running; otherwise it asks for your password and passes it to `sudo`
through a pipe. The password is never stored or logged. Kalanjiyam works offline and sends no telemetry.

## Build
Requires Flutter ≥ 3.47 (Dart ≥ 3.13) and the usual Linux desktop build dependencies.

```sh
flutter pub get
flutter build linux --release
```

To install it for your user (adds it to your app launcher, no root needed):

```sh
linux/packaging/install.sh            # after the release build
linux/packaging/install.sh --uninstall
```

The desktop file and icon live in `linux/packaging/` for distro packagers
(application ID `com.santhoshDsubramani.kalanjiyam`).

Run `kalanjiyam --page=storage` (or `packages`, `launchers`, `settings`) to open a section directly.

## License

MIT — see [LICENSE](LICENSE).
