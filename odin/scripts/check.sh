#!/usr/bin/env sh
# Offline end-to-end check for tracker-odin.
#
#   ./scripts/check.sh              unit tests + UI harness + synthesized render
#   ./scripts/check.sh --hardware   also records 2 s from the default capture device
#   ./scripts/check.sh --jack       also records 0.5 s through the JACK client
#   ./scripts/check.sh --loopback   also records a known 440 Hz tone through a
#                                   PulseAudio null sink (full-scale path check)
set -eu

cd "$(dirname "$0")/.."
ODIN="${ODIN:-odin}"
HARDWARE=0
JACK=0
LOOPBACK=0
for arg in "$@"; do
	case "$arg" in
		--hardware) HARDWARE=1 ;;
		--jack) JACK=1 ;;
		--loopback) LOOPBACK=1 ;;
		*)
			echo "unknown option: $arg" >&2
			echo "usage: $0 [--hardware] [--jack] [--loopback]" >&2
			exit 2
			;;
	esac
done

LINK='-extra-linker-flags:-lm -ldl -lpthread -ljack -lz -lSDL2'

command -v "$ODIN" >/dev/null 2>&1 || {
	echo "odin not found; install it and/or set ODIN=/path/to/odin" >&2
	exit 1
}

echo "== unit tests =="
"$ODIN" test src/dsp
"$ODIN" test src "$LINK"
"$ODIN" test src/ui "$LINK"

echo "== build =="
mkdir -p bin
"$ODIN" build src -out:bin/tracker-odin "$LINK"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tracker-odin-check.XXXXXX")
SINK_MOD=""
cleanup() {
	if [ -n "$SINK_MOD" ]; then
		pactl unload-module "$SINK_MOD" >/dev/null 2>&1 || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT

echo "== selftest =="
./bin/tracker-odin selftest

echo "== native UI harness (Playwright replacement) =="
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out "$tmp/ui"
[ -f "$tmp/ui/report.json" ] || { echo "FAIL: no UI report" >&2; exit 1; }
shots=$(find "$tmp/ui" -name '*.png' | wc -l | tr -d ' ')
[ "$shots" -ge 8 ] || { echo "FAIL: only $shots UI screenshots" >&2; exit 1; }
python3 - "$tmp/ui" <<'PY'
import glob, sys
files = glob.glob(sys.argv[1] + "/*.png")
assert files, "no screenshots"
for f in files:
    with open(f, "rb") as fh:
        assert fh.read(8) == b"\x89PNG\r\n\x1a\n", f
print(f"  {len(files)} PNG screenshots, signatures valid")
PY

echo "== synthesized session =="
./bin/tracker-odin tone --out "$tmp/track1.wav" --seconds 3 --freq 220 --amp 0.7
./bin/tracker-odin tone --out "$tmp/track2.wav" --seconds 3 --freq 330 --amp 0.5
./bin/tracker-odin render --in "$tmp" --out "$tmp/bounce.wav" \
	--level 1.2 --pan 0 --eq-low 3 --eq-mid -2 --eq-high -1 --comp-threshold -20
./bin/tracker-odin info "$tmp/bounce.wav"

echo "== engine bounce from a session directory =="
mkdir -p "$tmp/session"
cp "$tmp/track1.wav" "$tmp/session/track1.wav"
cp "$tmp/track2.wav" "$tmp/session/track2.wav"
./bin/tracker-odin bounce --session "$tmp/session" --out "$tmp/session/mix.wav"
./bin/tracker-odin info "$tmp/session/mix.wav"

echo "== mixed-rate session (44.1 kHz track into a 48 kHz project) =="
mkdir -p "$tmp/mixed"
./bin/tracker-odin tone --out "$tmp/mixed/track1.wav" --seconds 2 --freq 440 --rate 44100
./bin/tracker-odin bounce --session "$tmp/mixed" --out "$tmp/mixed/mix.wav"
if command -v ffprobe >/dev/null 2>&1; then
	rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$tmp/mixed/mix.wav")
	[ "$rate" = "48000" ] || { echo "FAIL: mixed-rate bounce is $rate Hz" >&2; exit 1; }
	echo "  resampled 44.1 kHz -> 48 kHz"
fi

echo "== project-driven reverb send extends the bounce =="
mkdir -p "$tmp/fx"
./bin/tracker-odin tone --out "$tmp/fx/track1.wav" --seconds 2 --freq 330 --amp 0.4 >/dev/null
cat > "$tmp/fx/project.json" <<'JSON'
{
  "version": 1, "name": "fx tail", "sampleRate": 48000, "bpm": 120,
  "tracks": [{"file": "track1.wav", "input": 1, "level": 1.0, "sendReverb": 0.8,
    "eq": {"enabled": false}, "comp": {"enabled": false}}],
  "master": {
    "reverb": {"enabled": true, "size": 0.6, "decay": 0.6, "tone": 0.5, "predelayMs": 18, "returnLevel": 0.8},
    "delay": {"enabled": false}, "width": {"enabled": false},
    "limiter": {"enabled": true, "ceilingDb": -0.3, "releaseMs": 120, "lookaheadMs": 5}
  }
}
JSON
./bin/tracker-odin bounce --session "$tmp/fx" --out "$tmp/fx/mix.wav" | tee "$tmp/fx/bounce.log"
if command -v ffprobe >/dev/null 2>&1; then
	dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/fx/mix.wav")
	awk -v d="$dur" 'BEGIN { exit (d > 4.0) ? 0 : 1 }' || {
		echo "FAIL: reverb tail missing (duration $dur)" >&2
		exit 1
	}
	echo "  reverb tail present ($dur s from a 2 s take)"
fi

echo "== format assertions =="
if command -v ffprobe >/dev/null 2>&1; then
	for f in "$tmp/bounce.wav" "$tmp/session/mix.wav" "$tmp/mixed/mix.wav"; do
		codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f")
		channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$f")
		[ "$codec" = "pcm_f32le" ] || { echo "FAIL: $f codec $codec" >&2; exit 1; }
		[ "$channels" = "2" ] || { echo "FAIL: $f channels $channels" >&2; exit 1; }
	done
	echo "  ffprobe: pcm_f32le, stereo"
else
	echo "  ffprobe not installed, skipping codec checks"
fi

if command -v sox >/dev/null 2>&1; then
	for f in "$tmp/bounce.wav" "$tmp/session/mix.wav" "$tmp/mixed/mix.wav"; do
		stats=$(sox "$f" -n stat 2>&1)
		if echo "$stats" | grep -q "wave header missing"; then
			echo "FAIL: sox rejected the WAV header in $f" >&2
			exit 1
		fi
		peak=$(echo "$stats" | awk '/Maximum amplitude/ { print $3 }')
		awk -v p="$peak" 'BEGIN { exit (p <= 0.98) ? 0 : 1 }' || {
			echo "FAIL: $f peak $peak exceeds limiter ceiling" >&2
			exit 1
		}
	done
	echo "  sox: headers clean, limiter ceiling respected"
fi

if [ "$HARDWARE" -eq 1 ]; then
	echo "== hardware capture (2 s, default device) =="
	rm -rf "$tmp/capture"
	./bin/tracker-odin record --seconds 2 --channels 2 --out "$tmp/capture"
	[ -f "$tmp/capture/track1.wav" ] || { echo "FAIL: no track1.wav" >&2; exit 1; }
	[ -f "$tmp/capture/track2.wav" ] || { echo "FAIL: no track2.wav" >&2; exit 1; }
	./bin/tracker-odin bounce --session "$tmp/capture" --out "$tmp/capture/bounce.wav"
	./bin/tracker-odin info "$tmp/capture/bounce.wav"
fi

if [ "$LOOPBACK" -eq 1 ]; then
	echo "== loopback capture (known 440 Hz tone, -6 dBFS) =="
	for tool in pactl paplay sox; do
		command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool required for --loopback" >&2; exit 1; }
	done
	SINK="tracker_check_$$"
	SINK_MOD=$(pactl load-module module-null-sink sink_name="$SINK" sink_properties=device.description=TrackerCheck)
	sox -n -r 48000 -c 2 "$tmp/loop-tone.wav" synth 4 sine 440 vol 0.5
	paplay --device="$SINK" "$tmp/loop-tone.wav" >/dev/null 2>&1 &
	PLAYER=$!
	sleep 0.4
	idx=$(./bin/tracker-odin devices | awk '/TrackerCheck/ { if ($1=="*") print $2; else print $1; exit }')
	[ -n "$idx" ] || { echo "FAIL: loopback source not enumerated" >&2; exit 1; }
	rm -rf "$tmp/loopback"
	./bin/tracker-odin record --seconds 2 --channels 2 --device "$idx" --out "$tmp/loopback"
	peak=$(./bin/tracker-odin info "$tmp/loopback/track1.wav" | awk '/peak/ { print $2; exit }')
	awk -v p="$peak" 'BEGIN { exit (p <= -4.0 && p >= -8.0) ? 0 : 1 }' || {
		echo "FAIL: loopback peak $peak dBFS, expected -6 ±2" >&2
		exit 1
	}
	echo "  loopback peak $peak dBFS (expected -6.02)"
	wait "$PLAYER" 2>/dev/null || true
	pactl unload-module "$SINK_MOD" >/dev/null 2>&1 || true
	SINK_MOD=""
fi

if [ "$JACK" -eq 1 ]; then
	echo "== JACK capture (0.5 s) =="
	rm -rf "$tmp/jack"
	./bin/tracker-odin record --jack --seconds 0.5 --channels 2 --out "$tmp/jack"
	[ -f "$tmp/jack/track1.wav" ] || { echo "FAIL: no JACK track1.wav" >&2; exit 1; }
	./bin/tracker-odin info "$tmp/jack/track1.wav"
fi

echo "== PASS =="
