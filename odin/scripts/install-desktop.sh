#!/usr/bin/env sh
# Install (or remove) the native app in a user prefix (default ~/.local).
#
#   ./scripts/install-desktop.sh              # build + install
#   PREFIX=/opt/tracker ./scripts/install-desktop.sh
#   ./scripts/install-desktop.sh --uninstall  # remove installed files
#
# `make install` / `make uninstall` call this with PREFIX forwarded.
set -eu
cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
APPS="$PREFIX/share/applications"
ICONS="$PREFIX/share/icons/hicolor"
FONTS="$PREFIX/share/fonts/tracker"

uninstall=0
for arg in "$@"; do
	case "$arg" in
		--uninstall) uninstall=1 ;;
		--help | -h)
			echo "usage: $0 [--uninstall]   (PREFIX defaults to ~/.local)"
			exit 0
			;;
		*)
			echo "unknown argument: $arg" >&2
			exit 2
			;;
	esac
done

refresh_caches() {
	if [ -d "$APPS" ] && command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$APPS" >/dev/null 2>&1 || true
	fi
	if [ -d "$ICONS" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
		gtk-update-icon-cache -f -t "$ICONS" >/dev/null 2>&1 || true
	fi
}

if [ "$uninstall" -eq 1 ]; then
	rm -f "$BIN/tracker-odin" \
		"$APPS/tracker-odin.desktop" \
		"$ICONS/256x256/apps/tracker-odin.png" \
		"$ICONS/scalable/apps/tracker-odin.svg"
	rm -rf "$FONTS"
	refresh_caches
	echo "removed tracker-odin from $PREFIX"
	exit 0
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
	make build
fi
[ -x bin/tracker-odin ] || {
	echo "bin/tracker-odin is missing; run 'make build' first" >&2
	exit 1
}

mkdir -p "$BIN" "$APPS" "$ICONS/256x256/apps" "$ICONS/scalable/apps" "$FONTS"
install -m 755 bin/tracker-odin "$BIN/tracker-odin"
install -m 644 assets/Inter-Regular.ttf assets/Inter-Medium.ttf \
	assets/Inter-SemiBold.ttf assets/Inter-OFL.txt "$FONTS/"
if command -v fc-cache >/dev/null 2>&1; then
	fc-cache -f "$FONTS" >/dev/null 2>&1 || true
fi
install -m 644 assets/tracker.png "$ICONS/256x256/apps/tracker-odin.png"
install -m 644 assets/tracker.svg "$ICONS/scalable/apps/tracker-odin.svg"

# Quote the Exec path for the desktop-entry grammar: escape backslash, double
# quote, backtick and dollar, then wrap the argument in double quotes. Without
# this a PREFIX containing a space produces a launcher that cannot start.
desktop_exec_quote() {
	printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g')"
}

cat > "$APPS/tracker-odin.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=Tracker (Odin)
GenericName=Multitrack Recorder
Comment=Minimal keyboard-first multitrack recorder (native Odin port)
Exec=$(desktop_exec_quote "$BIN/tracker-odin") ui
Icon=tracker-odin
Terminal=false
StartupNotify=false
StartupWMClass=tracker
Categories=AudioVideo;Audio;
Keywords=recorder;multitrack;audio;music;
DESKTOP

chmod 644 "$APPS/tracker-odin.desktop"
refresh_caches

echo "installed: $BIN/tracker-odin"
echo "launcher:  $APPS/tracker-odin.desktop"
