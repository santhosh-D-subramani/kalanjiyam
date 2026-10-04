#!/bin/sh
# Installs Kalanjiyam for the current user (no root needed).
#   From the release archive:  ./install.sh
#   From a source checkout:    flutter build linux --release && linux/packaging/install.sh
# Uninstall: add --uninstall
set -eu

APP_ID=com.santhoshDsubramani.kalanjiyam
HERE=$(cd "$(dirname "$0")" && pwd)
# The release archive ships the bundle next to this script.
if [ -x "$HERE/kalanjiyam" ] && [ -d "$HERE/data" ]; then
  BUNDLE="$HERE"
else
  BUNDLE="$HERE/../../build/linux/x64/release/bundle"
fi
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
PREFIX="$HOME/.local/opt/kalanjiyam"
BIN="$HOME/.local/bin"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf -- "$PREFIX"
  rm -f -- "$BIN/kalanjiyam" "$DATA/applications/$APP_ID.desktop" \
    "$DATA/icons/hicolor/scalable/apps/$APP_ID.svg" "$DATA/icons/hicolor/256x256/apps/$APP_ID.png"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DATA/applications" || true
  echo "Kalanjiyam removed."
  exit 0
fi

if [ ! -x "$BUNDLE/kalanjiyam" ]; then
  echo "Release build not found. Run: flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$BIN" "$DATA/applications" "$DATA/icons/hicolor/scalable/apps" "$DATA/icons/hicolor/256x256/apps"
rm -rf -- "$PREFIX"
mkdir -p "$PREFIX"
cp -r -- "$BUNDLE/kalanjiyam" "$BUNDLE/data" "$BUNDLE/lib" "$PREFIX/"
ln -sf -- "$PREFIX/kalanjiyam" "$BIN/kalanjiyam"
cp -- "$HERE/$APP_ID.svg" "$DATA/icons/hicolor/scalable/apps/$APP_ID.svg"
cp -- "$PREFIX/data/flutter_assets/assets/logo/kalanjiyam-256.png" "$DATA/icons/hicolor/256x256/apps/$APP_ID.png"
# Point Exec at the installed binary so it works even if ~/.local/bin is not on PATH.
sed "s|^Exec=kalanjiyam|Exec=$PREFIX/kalanjiyam|" "$HERE/$APP_ID.desktop" > "$DATA/applications/$APP_ID.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true
echo "Kalanjiyam installed to $PREFIX"
