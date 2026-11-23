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
		--*) echo "unknown check.sh option: $arg" >&2; exit 1 ;;
	esac
done

VINLAND="${VINLAND:-$(cd "$(dirname "$0")/../../.." && pwd)/vinland-ui}"
case "$(uname -s)" in
	Darwin)
		BREW_PREFIX=$(brew --prefix 2>/dev/null || echo /opt/homebrew)
		LINK="-extra-linker-flags:-L$BREW_PREFIX/lib -Wl,-rpath,$BREW_PREFIX/lib"
		;;
	*)
		LINK='-extra-linker-flags:-lm -ldl -lpthread -ljack -lz -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0'
		;;
esac

command -v "$ODIN" >/dev/null 2>&1 || {
	echo "odin not found; install it and/or set ODIN=/path/to/odin" >&2
	exit 1
}

# Run a command that must fail (unknown flag, malformed project, failed assert).
expect_fail() {
	description=$1
	shift
	if "$@" >/dev/null 2>&1; then
		echo "FAIL: $description" >&2
		exit 1
	fi
}

echo "== unit tests =="
"$ODIN" test src/dsp
"$ODIN" test src -collection:vinland="$VINLAND" "$LINK"
"$ODIN" test src/ui -collection:vinland="$VINLAND" "$LINK"

echo "== build =="
mkdir -p bin
"$ODIN" build src -out:bin/tracker-odin -collection:vinland="$VINLAND" "$LINK"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tracker-odin-check.XXXXXX") || {
	echo "FAIL: cannot create a temporary directory" >&2
	exit 1
}
SINK_MOD=""
cleanup() {
	if [ -n "$SINK_MOD" ]; then
		pactl unload-module "$SINK_MOD" >/dev/null 2>&1 || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "== selftest =="
./bin/tracker-odin selftest

echo "== native UI harness (Playwright replacement) =="
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out "$tmp/ui"
[ -f "$tmp/ui/report.json" ] || { echo "FAIL: no UI report" >&2; exit 1; }
shots=$(find "$tmp/ui" -name '*.png' | wc -l | tr -d ' ')
[ "$shots" -ge 8 ] || { echo "FAIL: only $shots UI screenshots" >&2; exit 1; }
if command -v python3 >/dev/null 2>&1; then
	python3 - "$tmp/ui" <<'PY'
import glob, sys
files = glob.glob(sys.argv[1] + "/*.png")
assert files, "no screenshots"
for f in files:
    with open(f, "rb") as fh:
        assert fh.read(8) == b"\x89PNG\r\n\x1a\n", f
print(f"  {len(files)} PNG screenshots, signatures valid")
PY
else
	echo "  python3 not installed, skipping PNG signature checks"
fi

echo "== CLI argument and ui-test error handling =="
mkdir -p "$tmp/dir with spaces"
cat >"$tmp/ui-pass.json" <<'JSON'
{"name": "tiny", "actions": [
  {"type": "assert", "path": "bpm", "min": 120, "max": 120, "hasMin": true, "hasMax": true},
  {"type": "screenshot", "name": "tiny shot"}
]}
JSON
cat >"$tmp/ui-fail.json" <<'JSON'
{"name": "failure", "actions": [{"type": "assert", "path": "bpm", "equals": "999"}]}
JSON
printf '{' >"$tmp/bad-script.json"

# Nested --out directories and paths containing spaces both work.
./bin/tracker-odin ui-test --script "$tmp/ui-pass.json" --out "$tmp/dir with spaces/nested/ui"
[ -f "$tmp/dir with spaces/nested/ui/report.json" ] || {
	echo "FAIL: ui-test did not write a nested report" >&2
	exit 1
}
[ -f "$tmp/dir with spaces/nested/ui/01-tiny shot.png" ] || {
	echo "FAIL: ui-test did not write a screenshot with a spaced name" >&2
	exit 1
}

# Missing/malformed scripts and failing assertions must return non-zero and
# still produce the report for a failure.
expect_fail "ui-test accepted a missing script" ./bin/tracker-odin ui-test --out "$tmp/ui-missing"
expect_fail "ui-test accepted a malformed script" ./bin/tracker-odin ui-test --script "$tmp/bad-script.json" --out "$tmp/ui-bad"
expect_fail "ui-test returned success for a failed assertion" ./bin/tracker-odin ui-test --script "$tmp/ui-fail.json" --out "$tmp/ui-fail"
[ -f "$tmp/ui-fail/report.json" ] || {
	echo "FAIL: failed ui-test run did not write report.json" >&2
	exit 1
}
expect_fail "ui-test accepted an unknown option" ./bin/tracker-odin ui-test --script "$tmp/ui-pass.json" --bogus
expect_fail "ui-test accepted a missing option value" ./bin/tracker-odin ui-test --script

echo "== synthesized session =="
./bin/tracker-odin tone --out "$tmp/track1.wav" --seconds 3 --freq 220 --amp 0.7
./bin/tracker-odin tone --out "$tmp/track2.wav" --seconds 3 --freq 330 --amp 0.5
./bin/tracker-odin render --in "$tmp" --out "$tmp/nested render/a b/bounce.wav" \
	--level 1.2 --pan 0 --eq-low 3 --eq-mid -2 --eq-high -1 --comp-threshold -20
./bin/tracker-odin info "$tmp/nested render/a b/bounce.wav"

echo "== CLI validation =="
expect_fail "tone accepted an unknown option" ./bin/tracker-odin tone --out "$tmp/x.wav" --bogus 1
expect_fail "tone accepted a missing option value" ./bin/tracker-odin tone --out
expect_fail "tone accepted a negative duration" ./bin/tracker-odin tone --out "$tmp/x.wav" --seconds -1
expect_fail "bounce accepted an unknown option" ./bin/tracker-odin bounce --session "$tmp/session" --bogus
expect_fail "bounce returned success with no tracks" ./bin/tracker-odin bounce --session "$tmp/empty-session" --out "$tmp/empty.wav"
expect_fail "tone accepted a non-numeric duration" ./bin/tracker-odin tone --out "$tmp/x.wav" --seconds abc
expect_fail "tone accepted an out-of-range amplitude" ./bin/tracker-odin tone --out "$tmp/x.wav" --amp 2
expect_fail "render accepted a non-numeric level" ./bin/tracker-odin render --in "$tmp" --out "$tmp/x.wav" --level loud
expect_fail "ui-shot accepted a frame below the layout minimum" ./bin/tracker-odin ui-shot --out "$tmp/x.png" --width 600 --height 600
[ ! -f "$tmp/x.wav" ] || { echo "FAIL: a rejected command still wrote output" >&2; exit 1; }

echo "== takes and comp regions =="
mkdir -p "$tmp/comp"
./bin/tracker-odin tone --out "$tmp/comp/track1-take1.wav" --seconds 2 --freq 220 >/dev/null
./bin/tracker-odin tone --out "$tmp/comp/track1-take2.wav" --seconds 1 --freq 880 --rate 44100 >/dev/null
./bin/tracker-odin comp --session "$tmp/comp" --track 0 --list
expect_fail "comp accepted a region past the end of its take" \
	./bin/tracker-odin comp --session "$tmp/comp" --track 0 --take 2 --start 0 --end 96000
expect_fail "comp accepted an out-of-range track" ./bin/tracker-odin comp --session "$tmp/comp" --track 7 --list
expect_fail "comp created a missing session" ./bin/tracker-odin comp --session "$tmp/no-such-session" --track 0 --list
[ ! -d "$tmp/no-such-session" ] || { echo "FAIL: comp created a session directory" >&2; exit 1; }
./bin/tracker-odin comp --session "$tmp/comp" --track 0 --take 2 --start 0 --end 48000
./bin/tracker-odin comp --session "$tmp/comp" --track 0 --take 1 --start 48000 --end 96000
./bin/tracker-odin bounce --session "$tmp/comp" --out "$tmp/comp/mix.wav"
./bin/tracker-odin info "$tmp/comp/mix.wav" | grep -q "96000 frames" || {
	echo "FAIL: comp bounce is not 2 s" >&2
	exit 1
}

echo "== engine bounce from a session directory =="
mkdir -p "$tmp/session"
cp "$tmp/track1.wav" "$tmp/session/track1.wav"
cp "$tmp/track2.wav" "$tmp/session/track2.wav"
./bin/tracker-odin bounce --session "$tmp/session" --out "$tmp/session/mix.wav"
./bin/tracker-odin info "$tmp/session/mix.wav"

# Nested session and output paths, including spaces.
mkdir -p "$tmp/nested session/deep"
cp "$tmp/track1.wav" "$tmp/nested session/deep/track1.wav"
./bin/tracker-odin bounce --session "$tmp/nested session/deep" --out "$tmp/nested session/deep/out/a b/mix.wav"
./bin/tracker-odin info "$tmp/nested session/deep/out/a b/mix.wav"

# project.json drives the bounce sample rate.
mkdir -p "$tmp/project-rate"
./bin/tracker-odin tone --out "$tmp/project-rate/track1.wav" --seconds 0.5 --freq 440 --rate 44100
cat >"$tmp/project-rate/project.json" <<'JSON'
{"version": 1, "name": "rate", "sampleRate": 44100, "bpm": 100, "tracks": [{"file": "track1.wav"}]}
JSON
./bin/tracker-odin bounce --session "$tmp/project-rate" --out "$tmp/project-rate/mix.wav"
./bin/tracker-odin info "$tmp/project-rate/mix.wav"

# Malformed and future projects must fail without writing an output file.
mkdir -p "$tmp/bad project"
cp "$tmp/track1.wav" "$tmp/bad project/track1.wav"
printf '{"version": 1, "tracks": [' >"$tmp/bad project/project.json"
expect_fail "bounce accepted a truncated project" ./bin/tracker-odin bounce --session "$tmp/bad project" --out "$tmp/bad project/mix.wav"
[ ! -f "$tmp/bad project/mix.wav" ] || {
	echo "FAIL: truncated project still produced a bounce" >&2
	exit 1
}
printf '{"version": 2, "name": "future"}' >"$tmp/bad project/project.json"
expect_fail "bounce accepted a future project version" ./bin/tracker-odin bounce --session "$tmp/bad project" --out "$tmp/bad project/mix.wav"

echo "== mixed-rate session (44.1 kHz track into a 48 kHz session) =="
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
./bin/tracker-odin bounce --session "$tmp/fx" --out "$tmp/fx/mix.wav"
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
	for f in "$tmp/nested render/a b/bounce.wav" "$tmp/session/mix.wav" "$tmp/nested session/deep/out/a b/mix.wav"; do
		if ! codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f"); then
			echo "FAIL: ffprobe could not read $f" >&2
			exit 1
		fi
		if ! channels=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$f"); then
			echo "FAIL: ffprobe could not read $f" >&2
			exit 1
		fi
		[ "$codec" = "pcm_f32le" ] || { echo "FAIL: $f codec $codec" >&2; exit 1; }
		[ "$channels" = "2" ] || { echo "FAIL: $f channels $channels" >&2; exit 1; }
	done
	if ! rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$tmp/project-rate/mix.wav"); then
		echo "FAIL: ffprobe could not read the project-rate bounce" >&2
		exit 1
	fi
	[ "$rate" = "44100" ] || { echo "FAIL: project bounce rate $rate, expected 44100" >&2; exit 1; }
	echo "  ffprobe: pcm_f32le, stereo, project rate honoured"
else
	echo "  ffprobe not installed, skipping codec checks"
fi

if command -v sox >/dev/null 2>&1; then
	for f in "$tmp/nested render/a b/bounce.wav" "$tmp/session/mix.wav" "$tmp/nested session/deep/out/a b/mix.wav"; do
		if ! stats=$(sox "$f" -n stat 2>&1); then
			echo "FAIL: sox could not read $f" >&2
			echo "$stats" >&2
			exit 1
		fi
		if echo "$stats" | grep -q "wave header missing"; then
			echo "FAIL: sox rejected the WAV header in $f" >&2
			exit 1
		fi
		peak=$(echo "$stats" | awk '/Maximum amplitude/ { print $3 }')
		[ -n "$peak" ] || { echo "FAIL: sox reported no peak for $f" >&2; exit 1; }
		awk -v p="$peak" 'BEGIN { exit (p <= 0.98) ? 0 : 1 }' || {
			echo "FAIL: $f peak $peak exceeds limiter ceiling" >&2
			exit 1
		}
	done
	echo "  sox: headers clean, limiter ceiling respected"
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

if [ "$HARDWARE" -eq 1 ]; then
	echo "== hardware capture (2 s, default device) =="
	rm -rf "$tmp/capture"
	./bin/tracker-odin record --seconds 2 --channels 2 --out "$tmp/capture"
	[ -f "$tmp/capture/track1.wav" ] || { echo "FAIL: no track1.wav" >&2; exit 1; }
	[ -f "$tmp/capture/track2.wav" ] || { echo "FAIL: no track2.wav" >&2; exit 1; }
	./bin/tracker-odin bounce --session "$tmp/capture" --out "$tmp/capture/bounce.wav"
	./bin/tracker-odin info "$tmp/capture/bounce.wav"
fi

if [ "$JACK" -eq 1 ]; then
	if [ "$(uname -s)" != "Linux" ]; then
		echo "== JACK capture skipped (Linux-only) =="
	else
		echo "== JACK capture (0.5 s) =="
		rm -rf "$tmp/jack"
		./bin/tracker-odin record --jack --seconds 0.5 --channels 2 --out "$tmp/jack"
		[ -f "$tmp/jack/track1.wav" ] || { echo "FAIL: no JACK track1.wav" >&2; exit 1; }
		./bin/tracker-odin info "$tmp/jack/track1.wav"
	fi
fi

echo "== PASS =="
