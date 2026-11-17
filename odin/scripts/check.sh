#!/usr/bin/env sh
# Offline end-to-end check for tracker-odin.
#
#   ./scripts/check.sh              unit tests + synthesized render + format checks
#   ./scripts/check.sh --hardware   also records 2 s from the default capture device
set -eu

cd "$(dirname "$0")/.."
ODIN="${ODIN:-odin}"
HARDWARE=0
[ "${1:-}" = "--hardware" ] && HARDWARE=1

command -v "$ODIN" >/dev/null 2>&1 || {
	echo "odin not found; install it and/or set ODIN=/path/to/odin" >&2
	exit 1
}

echo "== unit tests =="
"$ODIN" test src/dsp
"$ODIN" test src -extra-linker-flags:"-lm -ldl -lpthread"

echo "== build =="
mkdir -p bin
"$ODIN" build src -out:bin/tracker-odin -extra-linker-flags:"-lm -ldl -lpthread"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tracker-odin-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "== selftest =="
./bin/tracker-odin selftest

echo "== synthesized session =="
./bin/tracker-odin tone --out "$tmp/track1.wav" --seconds 3 --freq 220 --amp 0.7
./bin/tracker-odin tone --out "$tmp/track2.wav" --seconds 3 --freq 330 --amp 0.5
./bin/tracker-odin render --in "$tmp" --out "$tmp/bounce.wav" \
	--level 1.2 --pan 0 --eq-low 3 --eq-mid -2 --eq-high -1 --comp-threshold -20
./bin/tracker-odin info "$tmp/bounce.wav"

echo "== format assertions =="
if command -v ffprobe >/dev/null 2>&1; then
	codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$tmp/bounce.wav")
	channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$tmp/bounce.wav")
	duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/bounce.wav")
	[ "$codec" = "pcm_f32le" ] || { echo "FAIL: codec $codec" >&2; exit 1; }
	[ "$channels" = "2" ] || { echo "FAIL: channels $channels" >&2; exit 1; }
	awk -v d="$duration" 'BEGIN { exit (d > 2.99 && d < 3.01) ? 0 : 1 }' || {
		echo "FAIL: duration $duration" >&2
		exit 1
	}
	echo "  ffprobe: pcm_f32le, stereo, 3.00 s"
else
	echo "  ffprobe not installed, skipping codec checks"
fi

if command -v sox >/dev/null 2>&1; then
	stats=$(sox "$tmp/bounce.wav" -n stat 2>&1)
	echo "$stats" | grep -q "wave header missing" && {
		echo "FAIL: sox rejected the WAV header" >&2
		exit 1
	}
	peak=$(echo "$stats" | awk '/Maximum amplitude/ { print $3 }')
	awk -v p="$peak" 'BEGIN { exit (p <= 0.98) ? 0 : 1 }' || {
		echo "FAIL: peak $peak exceeds limiter ceiling" >&2
		exit 1
	}
	echo "  sox: peak $peak (ceiling respected)"
fi

if [ "$HARDWARE" -eq 1 ]; then
	echo "== hardware capture (2 s, default device) =="
	rm -rf "$tmp/capture"
	./bin/tracker-odin record --seconds 2 --channels 2 --out "$tmp/capture"
	[ -f "$tmp/capture/track1.wav" ] || { echo "FAIL: no track1.wav" >&2; exit 1; }
	[ -f "$tmp/capture/track2.wav" ] || { echo "FAIL: no track2.wav" >&2; exit 1; }
	./bin/tracker-odin render --in "$tmp/capture" --out "$tmp/capture/bounce.wav" --level 1.2
	./bin/tracker-odin info "$tmp/capture/bounce.wav"
fi

echo "== PASS =="
