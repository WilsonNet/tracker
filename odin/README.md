# tracker-odin

Native rewrite of Tracker in [Odin](https://odin-lang.org/). The original
Tauri + React app remains at the repository root as the behavioral reference.

**Status: native app working.** The window, live capture, overdub, playback,
full FX chain, bounce, project persistence, JACK capture and a headless
click/screenshot harness all work. Remaining gaps are listed in
[ROADMAP.md](ROADMAP.md).

## Why Odin

The motivation is iteration speed. Measured on this machine (Ryzen, 16 threads):

| step | time |
|---|---|
| full `odin build` (UI + audio + DSP + CLI) | **≈0.7 s** |
| Tauri/Rust dev rebuild | minutes |

No Node dev server, no webview, no IPC boundary. Change a pixel or a DSP
coefficient and the native window is rebuilt and running immediately.

## Dependencies

Linux, a C toolchain (Odin shells out to `clang`, `cc` and `ld`; `ar` is
needed only when building the miniaudio archive), Odin `dev-2026-11a` or
newer, and development files for SDL2, JACK and zlib. ALSA or PipeWire is
needed at runtime. `make check` also needs `python3`; `sox` and `ffprobe` are
optional format checks.

Arch:

```sh
sudo pacman -S --needed base-devel clang sdl2-compat zlib alsa-lib pipewire-jack python
# optional: sox ffmpeg
```

Debian/Ubuntu:

```sh
sudo apt install build-essential clang libsdl2-dev libjack-jackd2-dev \
  zlib1g-dev libasound2-dev python3
# optional: sox ffmpeg
```

The Odin release binary is statically linked, so no `llvm-config` or LLVM
development package is needed; the build still invokes the system
`clang`/`cc`/`ld` listed above.

## Quick start

```sh
# 1. Toolchain (once)
curl -sL -o /tmp/odin.tar.gz \
  https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz
mkdir -p ~/.local/opt ~/.local/bin
tar xzf /tmp/odin.tar.gz -C ~/.local/opt
mv ~/.local/opt/odin-linux-amd64-* ~/.local/opt/odin
ln -sf ~/.local/opt/odin/odin ~/.local/bin/odin

# 2. miniaudio static library (recent releases ship it; build only if missing)
export ODIN_ROOT="$HOME/.local/opt/odin"
test -f "$ODIN_ROOT/vendor/miniaudio/lib/miniaudio.a" || \
  sh "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"

# 3. Build and verify
cd odin
make build        # -> bin/tracker-odin
make test         # 164 unit tests
make check        # unit + native UI tour + offline end-to-end

# 4. Run the app
./bin/tracker-odin ui
```

The default session is `~/.local/share/tracker/session`; `--session DIR`
selects another one (parent directories are created). `ui --demo` runs the
window with synthetic meters when no audio hardware is available.

`make install` installs the binary, PNG/SVG icons and a desktop entry under
`~/.local` (override with `PREFIX=...`); `make uninstall` removes them. A
custom prefix is only picked up by desktop launchers when its `share`
directory is in `XDG_DATA_DIRS`.

## Make targets

| target | what it does |
|---|---|
| `build` | compile `bin/tracker-odin` |
| `test` | 164 unit tests: 70 DSP, 56 core/engine/project/WAV, 38 UI |
| `check` | `scripts/check.sh`: unit tests, 118-action UI tour, offline bounce |
| `ui` | build and open the native window (`run` is an alias) |
| `ui-shot` | render one frame; `SHOT=/tmp/ui.png` |
| `ui-test` | run a harness script; `SCRIPT=... UI_OUT=...` |
| `devices`, `selftest`, `bounce` | CLI helpers; `bounce` uses `SESSION=...` |
| `install`, `uninstall` | desktop integration under `PREFIX` |
| `clean` | remove `bin/` |

## Native UI

```sh
./bin/tracker-odin ui                 # real window
./bin/tracker-odin ui --demo          # demo meters, no audio hardware
./bin/tracker-odin ui --session DIR   # project/session directory
```

- **Tracks:** 4 strips with input selector, arm/solo/mute, pan, fader, peak/RMS
  meter and compressor gain-reduction meter.
- **Transport:** REC / PLAY / STOP / BOUNCE, timecode, armed count, BPM
  stepper and metronome click.
- **FX rack:** `x` or FX. Track tabs `1–4`, `MST`; draggable knobs (vertical
  drag), bypass toggles, ping-pong, response visuals.
- **I/O panel:** live PipeWire/JACK source list from miniaudio.
- **Playwright replacement:** `ui-test` (below) drives the exact same state
  machine headlessly.
- **Keyboard:** `Space` play/stop, `R` record, `b` bounce, `1–4` arm, `j/k`
  select, `J/K` level, `m` mute, `s` solo, `a` arm, `i` I/O, `x` FX,
  `c` click, `[`/`]` FX channel, `:` command palette, `Esc` close.

Sessions live in `~/.local/share/tracker/session` by default and contain
`project.json`, `track1.wav` … `track4.wav`, and `bounce.wav` (plus a
transient `take.raw` while a take is being captured).

## The Playwright replacement

`ui-test` drives `ui.App` with semantic targets, keyboard input, numeric
assertions and deterministic PNG screenshots. It needs no browser, no webview
and no IPC socket, and the whole tour runs in well under a second.

```sh
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui
```

```json
{
  "name": "full-tour",
  "width": 1180,
  "height": 760,
  "actions": [
    {"type": "click", "id": "arm.0"},
    {"type": "assert", "path": "armed.0", "equals": "true"},
    {"type": "key", "key": "r"},
    {"type": "assert", "path": "transport", "equals": "Recording"},
    {"type": "wait", "frames": 45},
    {"type": "screenshot", "name": "recording"},
    {"type": "click", "id": "fx"},
    {"type": "drag", "id": "knob.eq.low", "dy": -40},
    {"type": "assert", "path": "knob.eq.low", "min": 3, "hasMin": true}
  ]
}
```

Targets: `track.N`, `master`, `arm.N`, `solo.N`, `mute.N`, `input.N`,
`fader.N`, `pan.N`, `transport.rec|play|stop`, `bounce`, `fx`, `io`,
`bpm.plus|minus`, `metronome`, `fx.tab.N`, `fx.close`,
`knob.<module>.<param>`, `fx.bypass.<module>`, `fx.pingpong.delay`,
`palette.row.N`, `io.row.N`. Targets are availability-gated by the current
overlay/mode; clicking a track control while the FX rack is open fails instead
of silently closing the rack.
Track tabs expose `eq`, `comp` and `send`; the `MST` tab (`fx.tab.4`) exposes
the master `comp`, `reverb`, `delay`, `width` and `limiter` modules.
`palette.row.N` requires the palette open and `io.row.N` a populated device
list (set `devices` in the script).

Assertion paths: `transport`, `mode`, `selected`, `armed.N`, `muted.N`,
`solo.N`, `audible.N`, `input.N`, `level.N`, `pan.N`, `has_audio.N`, `bpm`,
`metronome`, `palette.open`, `palette.text`, `palette.count`, `palette.sel`,
`fx.open`, `fx.channel`, `fx.focus`, `bounce.progress`, `bounce.running`,
`device`, `device.count`, `input.count`, `armed.count`, `solo.any`, `dirty`,
`project`, `status`, plus every knob and bypass target.

Actions: `click`, `drag` (`dy`), `key`, `type`, `wait` (`frames` or `ms`),
`screenshot`, `assert` (`equals`, or `min`/`max` + `hasMin`/`hasMax`),
`resize`. The full tour is **118 actions / 10 screenshots**. A `report.json`
with every result is written next to the screenshots.

`ui-shot` renders one frame to PNG for fast visual iteration:

```sh
./bin/tracker-odin ui-shot --out /tmp/ui.png --fx --master
```

## CLI

```sh
./bin/tracker-odin devices
./bin/tracker-odin record --seconds 8 --channels 2 --out ~/Music/session
./bin/tracker-odin record --jack --seconds 8 --channels 2 --out ~/Music/session
./bin/tracker-odin tone --out /tmp/tone.wav --seconds 3 --freq 440
./bin/tracker-odin render --in ~/Music/session --out /tmp/bounce.wav \
  --level 0.9 --eq-low 3 --comp-threshold -20
./bin/tracker-odin bounce --session ~/Music/session --out /tmp/mix.wav
./bin/tracker-odin info /tmp/mix.wav
./bin/tracker-odin selftest
./bin/tracker-odin ui
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui
```

`render` accepts a directory of `track1.wav`…`track16.wav` or one WAV.
`bounce` reads `project.json` (if present), loads the session tracks, resamples
mixed-rate files to the project rate, renders through the full chain and writes
stereo 32-bit float.

## Tests and verification

```sh
make test        # 70 DSP + 56 core/engine/project/WAV + 38 UI = 164 tests
make test-dsp    # only src/dsp
make test-core   # only the root src package (engine/project/WAV)
make test-ui     # only src/ui

make check       # tests + 118-action UI tour + offline bounce + format checks
./scripts/check.sh --hardware   # + 2 s miniaudio capture
./scripts/check.sh --jack       # + 0.5 s JACK capture
./scripts/check.sh --loopback   # + known 440 Hz tone through a null sink
```

`scripts/check.sh` needs `python3` (it validates the PNG screenshots). The
`ffprobe` codec checks and the `sox` header/peak checks run only when those
tools are installed; the offline core of the script does not need audio
hardware.

Coverage includes the ported Rust DSP vectors (biquad, EQ, compressor, limiter,
reverb, delay, widener), resampling quality, WAV layout/import, RF64
read/write/streaming, project round-trip and defaults, solo semantics, every UI control and overlay, screenshot
PNG validity, and an offline engine bounce. Independent checks: `ffprobe`
reports `pcm_f32le`, `sox` reads the files without warnings, and its peak/RMS
agree with the engine.

A real 2-second take was recorded through the native window with xdotool:
`track1.wav` = 96,000 frames @ 48 kHz, then previewed and bounced.

## Layout

```
odin/
  src/
    main.odin          CLI entry
    ui_window.odin     SDL2 window + input mapping
    ui_harness.odin    scripted native UI test runner
    ui_cmd.odin        ui-shot
    engine.odin        ring-buffer capture, playback, bounce, overdub
    project.odin       project.json + DSP/view mapping
    capture.odin       miniaudio enumeration/capture
    jack_capture.odin  cooperative JACK client
    wav.odin           float32 WAV + PCM import
    wav_rf64.odin      RF64/ds64 read/write + streaming writer
    dsp/               biquad, EQ, comp, limiter, reverb, delay, widener,
                       resample, render
    ui/                canvas, font, theme, widgets, app, input, draw,
                       PNG, tests
  scripts/             check.sh, install-desktop.sh, gen_font.py
  tests/ui/            full-tour.json
  assets/              tracker.png / tracker.svg / FONT-LICENSE.txt
```

Correspondence with the Rust reference:

| Rust | Odin |
|---|---|
| `audio/fx/biquad.rs`, `eq.rs`, `compressor.rs`, `limiter.rs` | `dsp/*` |
| `audio/fx/reverb.rs`, `delay.rs`, `widener.rs` | `dsp/*` |
| `audio/fx/render.rs` | `dsp/render.odin` |
| `audio/device.rs`, `engine.rs` capture | `capture.odin` + `engine.odin` |
| `audio/jack.rs` | `jack_capture.odin` |
| `hound` WAV writer | `wav.odin` |
| React UI | `src/ui/` (software canvas) |
| Playwright | `ui_harness.odin` |

## Rendering notes (crispness)

The UI is a deterministic software canvas, not a webview. It already applies the
parts of the "web-crisp" playbook that fit an instrument panel:

- Two pre-baked **anti-aliased grayscale atlases** at the exact design sizes
  (12.5 px body, 25 px heading), with shared baselines and descenders. Text is
  blended per pixel; coordinates are rounded to whole pixels.
- No runtime scaling of a small bitmap: `scale = 1` uses the 12.5 px atlas,
  `scale = 2` uses the 25 px companion. The native SDL texture and the headless
  screenshot harness draw the same pixels.
- Flat 1 px borders and rectangles are snapped to the pixel grid; the design
  intentionally has no rounded cards, shadows, gradients or icon font.

Deliberately **not** used: Clay/Flexbox (the 4-track layout is fixed and covered
by geometry tests at 900/1180/1920), raylib, MSDF/SDF shaders (they soften
12 px text and need a GPU path), and runtime FreeType. The remaining crispness
gap is **HiDPI**: SDL is not opened with `ALLOW_HIGHDPI`, so a 2× compositor may
scale the 1× buffer. The next step is integer-scale layout with 2×/3× atlases
(or runtime `stb_truetype` rasterization at physical sizes); it is recorded in
`ROADMAP.md`. Runtime TTF/SDF and a flex layout engine would be a larger
architectural change than this port needs today.

## Limitations

- No zero-latency input monitoring. Playback/overdub is rendered and played;
  the live input is not passed through the output (feedback-safe by default).
- Overdub is not latency-compensated: the click/existing mix and the capture
  start on separate devices, so sample-accurate alignment is not guaranteed.
- Preview render and bounce run synchronously on the UI thread; a long mix
  pauses the window while it renders. JACK capture is exposed through the CLI,
  not yet as a GUI mode.
- The session path is fixed per run (`--session`); there is no native file
  picker or recent-projects list.
- No undo/redo, comping, or screen-reader accessibility yet. Large takes use
  RF64 automatically, but the GUI still buffers a whole take in memory.
- `ui-test` covers the state machine and rendering, not OS-level window focus or
  audio-device hotplug.
- The embedded text atlas is generated from Noto Sans Mono (Apache-2.0); see
  `assets/FONT-LICENSE.txt`. On a machine with JetBrains Mono installed,
  `scripts/gen_font.py` regenerates from it instead.
