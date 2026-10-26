#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/128x128/apps"
TARGET_BIN="$REPO_DIR/src-tauri/target/release/tracker"

mkdir -p "$APP_DIR" "$ICON_DIR"

# Copy 128x128 icon
if [ -f "$REPO_DIR/src-tauri/icons/128x128.png" ]; then
  cp "$REPO_DIR/src-tauri/icons/128x128.png" "$ICON_DIR/tracker.png"
fi

cat <<EOF > "$APP_DIR/tracker.desktop"
[Desktop Entry]
Name=Tracker
GenericName=Multitrack Audio Recorder
Comment=A minimal multitrack audio recorder for desktop
Exec=$TARGET_BIN
Icon=$REPO_DIR/src-tauri/icons/128x128.png
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Recorder;Music;
Keywords=audio;recorder;multitrack;tracker;music;focusrite;
StartupWMClass=tracker
EOF

chmod +x "$APP_DIR/tracker.desktop"

# Refresh desktop database if tool exists
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Tracker desktop entry installed to $APP_DIR/tracker.desktop"
