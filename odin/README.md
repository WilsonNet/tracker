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
| full `odin build` (UI + audio + DSP + CLI) | **≈0.5 s** |
| Tauri/Rust dev rebuild | minutes |

No Node dev server, no webview, no IPC boundary. Change a pixel or a DSP
coefficient and the native window is rebuilt and running immediately.

## Quick start

Requires Linux, Odin `dev-2026-11a` (or newer) and LLVM, plus ALSA/PipeWire,
SDL2, JACK and zlib development files.

```sh
# 1. Toolchain (once)
curl -sL -o /tmp/odin.tar.gz \
  https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz
mkdir -p ~/.local/opt ~/.local/bin
tar xzf /tmp/odin.tar.gz -C ~/.local/opt
mv ~/.local/opt/odin-linux-amd64-* ~/.local/opt/odin
ln -sf ~/.local/opt/odin/odin ~/.local/bin/odin

# 2. miniaudio static library (once)
export ODIN_ROOT="$HOME/.local/opt/odin"
sh "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"

# 3. Build and verify
cd odin
make build        # -> bin/tracker-odin
make test         # 82 unit tests
make check        # unit + native UI tour + offline end-to-end

# 4. Run the app
./bin/tracker-odin ui
```

`make install` installs the binary, icon and desktop entry under
`~/.local` (override with `PREFIX=...`).

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
  drag, `Shift` fine), bypass toggles, ping-pong, response visuals.
- **I/O panel:** live PipeWire/JACK source list from miniaudio.
- **Playwright replacement:** `ui-test` (below) drives the exact same state
  machine headlessly.
- **Keyboard:** `Space` play/stop, `R` record, `1–4` arm, `j/k` select,
  `J/K` level, `m` mute, `s` solo, `a` arm, `i` I/O, `x` FX, `c` click,
  `[`/`]` FX channel, `:` command palette, `Esc` close.

Sessions live in `~/.local/share/tracker/session` by default and contain
`project.json`, `track1.wav` … `track4.wav`, and `bounce.wav`.

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
    {"type": "drag", "id": "knob.eq.low", "dy": -40},
    {"type": "assert", "path": "knob.eq.low", "min": 3, "hasMin": true}
  ]
}
```

Targets: `track.N`, `arm.N`, `solo.N`, `mute.N`, `input.N`, `fader.N`,
`pan.N`, `transport.rec|play|stop`, `bounce`, `fx`, `io`, `bpm.plus|minus`,
`metronome`, `fx.tab.N`, `fx.close`, `knob.<module>.<param>`,
`fx.bypass.<module>`, `fx.pingpong.delay`, `palette.row.N`, `io.row.N`.

Assertion paths: `transport`, `mode`, `selected`, `armed.N`, `muted.N`,
`solo.N`, `input.N`, `level.N`, `pan.N`, `has_audio.N`, `bpm`, `metronome`,
`palette.open`, `palette.text`, `fx.open`, `fx.channel`, `bounce.progress`,
`device`, `project`, `status`, plus every knob and bypass target.

Actions: `click`, `drag` (`dy`), `key`, `type`, `wait` (`frames` or `ms`),
`screenshot`, `assert` (`equals`, or `min`/`max` + `hasMin`/`hasMax`),
`resize`. A `report.json` with every result is written next to the screenshots.

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
odin test src/dsp   # 62 DSP tests
odin test src       #  9 project/WAV tests
odin test src/ui    # 11 UI state/layout/screenshot tests
./scripts/check.sh  # all of the above + 56-action UI tour + engine bounce + sox/ffprobe
./scripts/check.sh --hardware   # + 2 s miniaudio capture
./scripts/check.sh --jack       # + 0.5 s JACK capture
```

Coverage includes the ported Rust DSP vectors (biquad, EQ, compressor, limiter,
reverb, delay, widener), resampling quality, WAV layout/import, project
round-trip and defaults, solo semantics, every UI control and overlay, screenshot
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
    dsp/               biquad, EQ, comp, limiter, reverb, delay, widener,
                       resample, render
    ui/                canvas, font, theme, widgets, app, input, draw,
                       PNG, tests
  scripts/             check.sh, install-desktop.sh, gen_font.py
  tests/ui/            full-tour.json
  assets/              tracker.png / tracker.svg
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

## Limitations

- No zero-latency input monitoring. Playback/overdub is rendered and played;
  the live input is not passed through the output (feedback-safe by default).
- Overdub is not latency-compensated: the click/existing mix and the capture
  start on separate devices, so sample-accurate alignment is not guaranteed.
- JACK capture is exposed through the CLI, not yet as a GUI mode.
- The session path is fixed per run (`--session`); there is no native file
  picker or recent-projects list.
- No undo/redo, comping, RF64 (>4 GB), or screen-reader accessibility yet.
- `ui-test` covers the state machine and rendering, not OS-level window focus or
  audio-device hotplug.
