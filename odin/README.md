# tracker-odin

Native rewrite of Tracker in [Odin](https://odin-lang.org/). The original
Tauri + React app remains at the repository root as the behavioral reference.

**Status: complete.** The window, live capture, monitoring, overdub, playback,
takes/comping, full FX chain, bounce, RF64, project persistence, native dialogs,
recent projects, undo/redo, JACK GUI, HiDPI and the headless click/screenshot
harness all work. See [ROADMAP.md](ROADMAP.md) for the completion record and
intentional limits.

## Why Odin

The motivation is iteration speed. Measured on this machine (Ryzen, 16 threads):

| step | time |
|---|---|
| full `odin build` (UI + audio + DSP + CLI) | **≈0.8 s** |
| Tauri/Rust dev rebuild | minutes |

No Node dev server, no webview, no IPC boundary. Change a pixel or a DSP
coefficient and the native window is rebuilt and running immediately.

## Dependencies

Linux, a C toolchain (Odin shells out to `clang`, `cc` and `ld`; `ar` is
needed only when building the miniaudio archive), Odin `dev-2026-11a` or
newer, and development files for SDL2, JACK and zlib. ALSA or PipeWire is
needed at runtime. `make check` also needs `python3`; `sox` and `ffprobe` are
optional format checks. Project open/save-as dialogs use `zenity` (falling back
to `kdialog`); `--open FILE` and the recent-projects list work without them.

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

# 2. Native support archives (recent releases ship miniaudio but not
#    stb_truetype; `make build` also creates the latter automatically)
export ODIN_ROOT="$HOME/.local/opt/odin"
test -f "$ODIN_ROOT/vendor/miniaudio/lib/miniaudio.a" || \
  sh "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"
test -f "$ODIN_ROOT/vendor/stb/lib/stb_truetype.a" || \
  sh "$ODIN_ROOT/vendor/stb/src/build_stb.sh" unix

# 3. Build and verify
cd odin
make build        # -> bin/tracker-odin
make test         # 211 unit tests
make check        # unit + native UI tour + offline end-to-end

# 4. Run the app
./bin/tracker-odin ui
```

The default session is `~/.local/share/tracker/session`; `--session DIR`
selects another one (parent directories are created). `ui --demo` runs the
window with synthetic meters when no audio hardware is available.
`ui --ui-scale 2` forces a display density (1, 1.25, 1.5, 2 or 3); otherwise
the density comes from SDL's window-size-versus-pixel-size ratio.

`make install` installs the binary, PNG/SVG icons and a desktop entry under
`~/.local` (override with `PREFIX=...`); `make uninstall` removes them. A
custom prefix is only picked up by desktop launchers when its `share`
directory is in `XDG_DATA_DIRS`.

## Make targets

| target | what it does |
|---|---|
| `build` | compile `bin/tracker-odin` |
| `stb` | build the vendored `stb_truetype` archive if missing (auto for `build`/tests) |
| `test` | 211 unit tests: 70 DSP, 85 core/engine/project, 56 UI |
| `check` | `scripts/check.sh`: unit tests, 220-action UI tour, offline bounce |
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
  stepper, metronome click, live input **MON**itoring, latency trim and a
  PipeWire/cooperative-JACK backend switch.
- **Takes:** multi-take recording (`T1/2` on each strip), active-take cycling,
  whole-take comping from the palette, and arbitrary comp regions through the
  `comp` CLI. Projects keep the legacy `file` plus the full take/comp list.
- **HiDPI:** logical layout at physical pixel density, 1×–3×, with runtime
  stb_truetype glyphs; `--ui-scale` for testing.
- **FX rack:** `x` or FX. Track tabs `1–4`, `MST`; draggable knobs (vertical
  drag), bypass toggles, ping-pong, response visuals.
- **I/O panel:** live PipeWire/JACK source list, JACK-backend toggle, latency
  ± controls, rescan and device selection.
- **Playwright replacement:** `ui-test` (below) drives the exact same state
  machine headlessly.
- **Keyboard:** `Space` play/stop, `R` record, `b` bounce, `1–4` arm, `j/k`
  select, `J/K` level, `m` mute, `s` solo, `a` arm, `I` input, `x` FX,
  `c` click, `o` monitor, `y` JACK backend, `t`/`T` next/previous take,
  `u`/`U` undo/redo, `[`/`]` FX channel, `Tab`/`Shift+Tab` FX focus,
  `:` command palette, `Esc` close. Recent projects and open/save-as live in
  the palette; the dialogs use zenity or kdialog. Double-click resets a
  fader/pan/knob.

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
with every result is written next to the screenshots. `ui-test --scale 1.5|2|3`
renders the same actions into a physical-size canvas (the logical layout and
targets are unchanged); `ui-shot --scale N` does the same for a single frame.

`ui-shot` renders one frame to PNG for fast visual iteration:

```sh
./bin/tracker-odin ui-shot --out /tmp/ui.png --fx --master
./bin/tracker-odin ui-shot --out /tmp/ui@2x.png --scale 2 --fx --master
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
./bin/tracker-odin comp --session ~/Music/session --track 0 --list
./bin/tracker-odin comp --session ~/Music/session --track 0 --take 2 --start 0 --end 96000
./bin/tracker-odin ui --open ~/Music/session/project.json --jack
./bin/tracker-odin ui --a11y-log
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui
```

`render` accepts a directory of `track1.wav`…`track16.wav` or one WAV.
`bounce` reads `project.json` (if present), loads the session tracks (active
takes or comp regions), resamples mixed-rate files to the project rate, renders
through the full chain and writes stereo 32-bit float (RF64 automatically for
files over the RIFF limit). `comp --list` shows takes/regions; `--select`
changes the active take; `--take/--start/--end` adds a region; `--clear`
removes them.

## Tests and verification

```sh
make test        # 70 DSP + 85 core/engine/project + 56 UI = 211 tests
make test-dsp    # only src/dsp
make test-core   # only the root src package (engine/project/WAV)
make test-ui     # only src/ui

make check       # tests + 220-action UI tour + offline bounce + format checks
./scripts/check.sh --hardware   # + 2 s miniaudio capture
./scripts/check.sh --jack       # + 0.5 s JACK capture
./scripts/check.sh --loopback   # + known 440 Hz tone through a null sink
```

`scripts/check.sh` needs `python3` (it validates the PNG screenshots). The
`ffprobe` codec checks and the `sox` header/peak checks run only when those
tools are installed; the offline core of the script does not need audio
hardware.

Coverage includes the ported Rust DSP vectors (biquad, EQ, compressor, limiter,
reverb, delay, widener), resampling quality, WAV/RF64 layout/import, project
round-trip/defaults/takes/comp regions, solo semantics, undo/redo, recent
projects, HiDPI canvas/text at 1/1.5/2/3×, hotplug/latency/monitor helpers,
every UI control and overlay, screenshot PNG validity, and an offline engine
bounce. Independent checks: `ffprobe`
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
    ui/                canvas, font (baked + runtime), theme, widgets, app,
                       input, draw, PNG, tests
  scripts/             check.sh, install-desktop.sh, gen_font.py
  tests/ui/            full-tour.json
  assets/              tracker.png / tracker.svg / FONT-LICENSE.txt /
                       NotoSansMono-Regular.ttf (runtime glyphs)
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

The UI is a deterministic software canvas, not a webview. Layout is always in
logical pixels; the canvas allocates its pixel buffer at the display density and
every primitive (fill, rect, line, circle, arc, text, clip) converts through
`Canvas.scale`. The design now applies the full "web-crisp" playbook:

- SDL opens the window with `WINDOW_ALLOW_HIGHDPI`. The density is
  `GetWindowSizeInPixels / GetWindowSize` (every frame, so moving between a
  laptop panel and an external display updates the UI); `--ui-scale 1|1.25|1.5|2|3`
  forces it for testing. Pointer coordinates are normalised through the same
  pixel/logical ratio in `ui_window.odin`.
- Two pre-baked **anti-aliased grayscale atlases** at the exact design sizes
  (12.5 px body, 25 px heading) are used where the physical size matches them
  byte-for-byte: 1× body, 1× headings, and 2× body (the 25 px companion). The
  default 1× screenshot output is pixel-identical to the pre-HiDPI renderer.
- Every other density (1.25×, 1.5×, 3×, and headings at those densities) is
  rasterised at its true physical pixel height by a runtime `stb_truetype`
  atlas from the bundled `assets/NotoSansMono-Regular.ttf` (Apache-2.0). The
  cache is keyed by pixel size and lives on the canvas. No small bitmap is ever
  magnified: text is crisp, with real anti-aliased edge coverage.
- Logical cell metrics (8×15 body, 16×30 heading) and baselines are unchanged
  at every density, so `text_width`/`text_height`, centering, truncation and
  hit-testing stay identical across scales.
- Flat 1 px borders, rules and rectangles are snapped to the physical grid, so
  a 1 logical px border is 2 physical px at 2× and 3 at 3×. The design
  intentionally has no rounded cards, shadows, gradients or icon font.

Deliberately **not** used: Clay/Flexbox (the 4-track layout is fixed and covered
by geometry tests at 900/1180/1920), raylib, MSDF/SDF shaders (they soften
12 px text and need a GPU path), and runtime FreeType. The runtime text path is
stb_truetype only, with a single bundled mono face — no font matching, shaping
or fallback, which this ASCII instrument panel does not need.

Sources that shaped this path: the SDL high-DPI guidance ([SDL3 README-highdpi]
— window sizes and mouse positions are in points, `GetWindowSizeInPixels` is the
drawable pixel buffer), the installed Odin `vendor:sdl2` bindings
(`WINDOW_ALLOW_HIGHDPI`, `GetWindowSizeInPixels`) and `vendor:stb/truetype`
(`ScaleForMappingEmToPixels`, `GetCodepointBitmap`), and stb_truetype's header
notes on em-size versus pixel-height scaling. The baked atlases remain the
ground truth for 1×/2× metrics; `scripts/gen_font.py` documents Pillow/FreeType's
anchor/baseline behaviour used to generate them.

[SDL3 README-highdpi]: https://wiki.libsdl.org/SDL3/README-highdpi

## Limitations

- Latency compensation is manual (`--latency-ms`/I/O ±): it trims a fixed
  offset from each new take. There is no automatic round-trip calibration.
- Live monitoring is a duplex path with a fixed −6 dB gain; it is not a
  zero-latency hardware monitor loop, and overdub can still drift on long takes.
- Accessibility is keyboard-first with high-contrast/reduced-motion modes and a
  textual `--a11y-log` snapshot. There is no AT-SPI accessibility tree.
- JACK GUI takes accumulate in RAM until stop (≈384 MB/hour stereo); the CLI
  path is unchanged.
- RF64 writing/streaming is implemented and tested, but the engine still
  buffers each take while splitting it; it does not stream a take end-to-end.
- Multi-take comping has whole-take UI and arbitrary-region CLI; there is no
  waveform/timeline region editor by product design.
- Preview render and bounce run synchronously on the UI thread; a long mix
  pauses the window while it renders. JACK capture is exposed through the CLI,
  not yet as a GUI mode.
- The session path is fixed per run (`--session`); there is no native file
  picker or recent-projects list.
- No undo/redo, comping, RF64 (>4 GB), or screen-reader accessibility yet.
- `ui-test` covers the state machine and rendering, not OS-level window focus or
  audio-device hotplug.
- The baked text atlases are generated from Noto Sans Mono (Apache-2.0) and the
  runtime path embeds `assets/NotoSansMono-Regular.ttf` from the same family;
  see `assets/FONT-LICENSE.txt`. On a machine with JetBrains Mono installed,
  `scripts/gen_font.py` regenerates the baked atlases from it instead, but the
  bundled runtime TTF stays Noto so builds are reproducible.
- HiDPI density is sampled from the compositor's window/pixel ratio; densities
  outside 1–3× are clamped. Arbitrary fractional densities inside that range
  are rasterised at their exact physical size (glyph metrics stay logical);
  `--ui-scale` is deliberately limited to the tested 1/1.25/1.5/2/3 set.
- `ui-test` pointer assertions drive logical coordinates; physical→logical
  mapping is covered by unit tests and used by the SDL window, but the harness
  has no OS pointer injection.
