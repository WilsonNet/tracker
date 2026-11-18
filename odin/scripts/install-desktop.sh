#!/usr/bin/env sh
# Install the native app into a user prefix (default ~/.local).
set -eu
cd "$(dirname "$0")/.."
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
APPS="$PREFIX/share/applications"
ICONS="$PREFIX/share/icons/hicolor/256x256/apps"

make build
mkdir -p "$BIN" "$APPS" "$ICONS"
install -m 755 bin/tracker-odin "$BIN/tracker-odin"
install -m 644 assets/tracker.png "$ICONS/tracker-odin.png"

cat > "$APPS/tracker-odin.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Tracker
GenericName=Multitrack Recorder
Comment=Minimal keyboard-first multitrack recorder
Exec=$BIN/tracker-odin ui
Icon=tracker-odin
Terminal=false
Categories=AudioVideo;Audio;
Keywords=recorder;multitrack;audio;music;
StartupWMClass=tracker-odin
DESKTOP

chmod 644 "$APPS/tracker-odin.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$APPS" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
	gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "installed: $BIN/tracker-odin"
echo "launcher:  $APPS/tracker-odin.desktop"
