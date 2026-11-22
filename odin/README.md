# tracker-odin

Native Tracker application in [Odin](https://odin-lang.org/). The original
Tauri + React app was the behavioral reference during the port; it was removed
once the port completed and remains in git history.

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
newer, the sibling [vinland-ui](https://github.com/WilsonNet/vinland-ui) checkout
(`../../vinland-ui` from `odin/`, override with `VINLAND=`), and development files
for SDL3, JACK, zlib, Cairo and Pango. ALSA or PipeWire is
needed at runtime. `make check` also needs `python3`; `sox` and `ffprobe` are
optional format checks. Project open/save-as dialogs use `zenity` (falling back
to `kdialog`); `--open FILE` and the recent-projects list work without them.
Google Drive transfer needs `curl` and a browser opener (`xdg-open` or `gio`).

Arch:

```sh
sudo pacman -S --needed base-devel clang sdl3 cairo pango zlib alsa-lib pipewire-jack python
# optional: sox ffmpeg
```

Debian/Ubuntu:

```sh
sudo apt install build-essential clang libsdl3-dev libcairo2-dev libpango1.0-dev libjack-jackd2-dev \
  zlib1g-dev libasound2-dev python3
# optional: sox ffmpeg
```

The Odin release binary is statically linked, so no `llvm-config` or LLVM
development package is needed; the build still invokes the system
`clang`/`cc`/`ld` listed above.

## Quick start

```sh
# 0. System libraries (Arch: sdl3 cairo pango jack; Debian/Ubuntu:
#    libsdl3-dev libcairo2-dev libpango1.0-dev libjack-jackd2-dev)
#    vinland-ui (SDL3 + Vulkan, OpenGL fallback) draws the window; Cairo/Pango
#    only render the headless ui-shot/ui-test harness. JACK is optional.
#    git clone https://github.com/WilsonNet/vinland-ui ../../vinland-ui

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
make test         # 264 unit tests
make check        # unit + native UI tour + offline end-to-end

# 4. Run the app
./bin/tracker-odin ui
```

The default session is `$XDG_DATA_HOME/tracker/session` (usually
`~/.local/share/tracker/session`); `--session DIR`
selects another one (parent directories are created) and deliberately ignores
the saved folder and accessibility settings so tests and throwaway takes stay
isolated. The Settings overlay (`SET`, `,`) changes the folder for normal
launches and persists it in `~/.config/tracker/settings.json`.
`ui --demo` runs the window with synthetic meters when no audio hardware is
available.
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
| `test` | 264 unit tests: 70 DSP, 124 core/engine/project/cloud, 70 UI |
| `check` | `scripts/check.sh`: unit tests, 220-action UI tour, offline bounce |
| `e2e` | 17 headless vinland-ui window cases (`tests/ui/window.vt`) |
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
  meter and compressor gain-reduction meter. Arming a track opens a
  capture-only preview, so its input meter and history graph are live before
  REC (the miniaudio/PipeWire path; JACK meters during the take).
- **Transport:** REC / PLAY / STOP / BOUNCE, timecode, armed count, BPM
  stepper, metronome click, live input **MON**itoring, latency trim and a
  PipeWire/cooperative-JACK backend switch.
- **Takes:** multi-take recording (`T1/2` on each strip), active-take cycling,
  whole-take comping from the palette, and arbitrary comp regions through the
  `comp` CLI. Projects keep the legacy `file` plus the full take/comp list.
- **HiDPI + responsive density:** logical layout at physical pixel density,
  1×–3×, with runtime stb_truetype glyphs; larger windows scale the whole
  instrument (type, padding, controls) up to 1.8×, smaller ones keep 1:1 and
  let the layout compress. `--ui-scale` forces a density for testing.
- **FX rack:** `x` or FX. Track tabs `1–4`, `MST`; draggable knobs (vertical
  drag), bypass toggles, ping-pong, response visuals.
- **I/O panel:** live PipeWire/JACK source list, JACK-backend toggle, latency
  ± controls, rescan and device selection.
- **Settings:** `,` or the SET button. Edits the project folder (type, BROWSE…,
  APPLY, DEFAULT), shows the input device/backends, latency and monitoring, and
  toggles high contrast and reduced motion. `j/k` selects a row and `Enter`
  runs it. Clicking a text field enters EDIT with a real caret: click/drag or
  Shift+click select, double-click selects a word, triple-click selects all,
  arrows/Home/End and Ctrl+word movement work, and `Ctrl+C`/`X`/`V`/`Z`/`Y`
  use the clipboard and undo. `Enter` applies, `Esc` asks before discarding,
  and `Tab`/`Shift+Tab` switch inputs without losing drafts.
  Client secrets render as `*` even while editing. The folder and
  accessibility choices persist in
  `~/.config/tracker/settings.json`; changing the folder copies the current
  takes into it and leaves the old folder as a recovery copy. A folder that
  already contains `project.json` or `track1..4.wav` is refused, so applying
  cannot overwrite another session.
- **Cloud projects:** Google Drive backup/restore. `Settings → CLOUD` holds
  the Drive folder name, OAuth client ID/secret, connect/disconnect, back up
  and restore. `g` opens the cloud-project list; `u` backs up, `r` refreshes.
  Setup and the safety model are in [`../docs/cloud-setup.md`](../docs/cloud-setup.md).
- **Playwright replacement:** `ui-test` (below) drives the exact same state
  machine headlessly.
- **Keyboard:** `Space` play/stop, `R` record, `b` bounce, `1–4` arm, `j/k`
  select, `J/K` level, `m` mute, `s` solo, `a` arm, `I` input, `x` FX,
  `c` click, `o` monitor, `y` JACK backend, `t`/`T` next/previous take,
  `u`/`U` undo/redo, `[`/`]` FX channel, `Tab`/`Shift+Tab` FX focus,
  `,` settings, `g` cloud projects, `:` command palette, `Esc` close. Recent
  projects and open/save-as live in the palette; the dialogs use zenity or
  kdialog. Double-click resets a fader/pan/knob.

### Google Drive

Setup is in [`../docs/cloud-setup.md`](../docs/cloud-setup.md). The short version:

- Create a **Desktop app** OAuth client in Google Cloud with only the
  `https://www.googleapis.com/auth/drive.file` scope and add your account as a
  test user.
- Enter the Client ID/secret and a Drive folder name in Settings → CLOUD.
- Testing-mode refresh tokens last 7 days; reconnect weekly, or publish the app.
- The folder is visible in My Drive, so you can delete it without Tracker.
  Tracker has no Google Drive delete operation.
- Every file/folder Tracker creates carries an `appProperties` marker; queries
  and restores only see marked items. The fake-Drive test seeds an unrelated
  same-named file and proves it is neither downloaded, overwritten, nor deleted.

### Design tokens

`src/ui/theme.odin` is the single source of truth, layered so a palette change
or a density tweak never touches drawing code:

- **Palette constants** — the exact brand values as sRGB (`BG_VALUE`,
  `AMBER_VALUE`, …), with the OKLCH origin in comments. These values are
  canonical; the retired React frontend used the same OKLCH palette.
- **`Color_Tokens`** — semantic roles (`bg`, `surface`, `ink`, `ink_dim`,
  `line`, `amber`, `red`, `teal`, …). Widgets never read the raw palette.
- **`Space_Tokens`** — a 1/2/4/6/8/12/16/24 px rhythm used for padding.
- **`Type_Tokens`** — a fixed 8.5/9/10/11.5/14/20/25 px scale (product UI never
  scales type fluidly). The 12.5 px body and 25 px heading atlases remain for
  `canvas_text`.
- **`Metric_Tokens`** — header/bottom/status heights, margins, gutters, control
  sizes, fader/meter widths. `app_layout` reads these instead of magic numbers.
- **Responsive density** — `UI_BASE_WIDTH/HEIGHT`, `UI_MAX_ZOOM` and
  `ui_zoom_for_window()` derive a uniform zoom from the window size; the same
  scale multiplies the canvas density, so type and controls grow together.
- **`Tokens` / `ACTIVE_TOKENS`** — the live bundle handed to the renderer;
  `TOKENS_HIGH_CONTRAST` swaps colour only, leaving geometry untouched.

The default theme is the reference palette: `#010101` canvas, `#060606` bars and
panels, `#1B1B1B` hairlines, `#F08A31` amber, `#BA022F` record red, `#00858D`
solo/play teal, and the three-step ink ramp `#E8E8E8` / `#8F8F8F` / `#5D5D5D`.

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
./bin/tracker-odin ui-shot --out /tmp/settings.png --settings
./bin/tracker-odin ui-shot --out /tmp/cloud.png --cloud
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

`render` accepts a directory of `track1.wav`…`track16.wav` or one WAV; tracks
at another rate are resampled to the first track's rate. Every reader (`info`,
`render`, `bounce`) accepts RIFF, RF64 and BW64 containers with 32/64-bit float
or 8/16/24/32-bit integer PCM. Numeric options must parse (`--seconds abc` is an
error, not a silent default). `ui`, `ui-shot` and `ui-test` sizes must be at
least the 900x620 layout minimum. `comp --track` is 0-based (0..3); `comp`
never creates a session, `--list` prints each take's length in project frames,
and a region that does not fit its take is rejected.
`bounce` reads `project.json` (if present), loads the session tracks (active
takes or comp regions), resamples mixed-rate files to the project rate, renders
through the full chain and writes stereo 32-bit float (RF64 automatically for
files over the RIFF limit). `comp --list` shows takes/regions; `--select`
changes the active take; `--take/--start/--end` adds a region; `--clear`
removes them.

## Tests and verification

```sh
make test        # 70 DSP + 124 core/engine/project/cloud + 70 UI = 264 tests
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
    ui_window.odin     vinland-ui window (SDL3/Vulkan) + key mapping + engine commands
    ui_harness.odin    scripted native UI test runner
    ui_cmd.odin        ui-shot
    engine.odin        ring-buffer capture, playback, bounce, overdub
    project.odin       project.json + DSP/view mapping
    capture.odin       miniaudio enumeration/capture
    jack_capture.odin  cooperative JACK client
    wav.odin           float32 WAV + PCM import
    dsp/               biquad, EQ, comp, limiter, reverb, delay, widener,
                       resample, render
    ui/                cairo canvas, Pango text, theme, widgets, app, input,
                       draw, charts, PNG, tests
  scripts/             check.sh, install-desktop.sh, gen_font.py
  tests/ui/            full-tour.json
  assets/              tracker.png / tracker.svg / Inter-*.ttf /
                       Inter-OFL.txt / NotoSansMono-Regular.ttf
```

Correspondence with the retired Rust implementation (git history):

| Rust | Odin |
|---|---|
| `audio/fx/biquad.rs`, `eq.rs`, `compressor.rs`, `limiter.rs` | `dsp/*` |
| `audio/fx/reverb.rs`, `delay.rs`, `widener.rs` | `dsp/*` |
| `audio/fx/render.rs` | `dsp/render.odin` |
| `audio/device.rs`, `engine.rs` capture | `capture.odin` + `engine.odin` |
| `audio/jack.rs` | `jack_capture.odin` |
| `hound` WAV writer | `wav.odin` |
| UI layer | `src/ui/view.odin` (vinland-ui element tree; window) and `src/ui/draw.odin` (Cairo, headless harness) |
| Playwright | `ui_harness.odin` |

## Window UI (vinland-ui)

The window is built with [vinland-ui](https://github.com/WilsonNet/vinland-ui):
`src/ui/view.odin` turns the `App` model into a Tailwind-styled element tree that
follows DESIGN.md (JetBrains Mono, amber signal, flat 1px panels; tokens from
`src/ui/theme.odin` in sRGB). Knobs, meters and
the FX graphs (EQ response, compressor transfer, reverb envelope, delay taps,
width scope, limiter) are drawn with vinland's vector canvas primitives
(`draw_line`, `draw_arc`, `draw_area`). Rendering is SDL3 GPU (Vulkan) with an
OpenGL 3.3 fallback (`VUI_BACKEND=gl`), at the display's real pixel density.
The loop idles when nothing changes and redraws at vsync while audio runs.

Keyboard goes straight to `ui.app_key`, so every Vim binding matches the
harness and the unit tests. Agents can drive the window with `vui-ctl`:

```sh
VUI_PORT=7421 ./bin/tracker-odin ui --demo &
vui-ctl --port 7421 screenshot tracker.png
vui-ctl --port 7421 type x          # open the FX rack
vui-ctl --port 7421 click-text MST
```

The Cairo/Pango renderer below remains for `ui-shot` / `ui-test` (headless,
pixel-stable regression tests).

## Rendering notes (crispness)

The UI is a native vector canvas, not a webview and not a bitmap game canvas.
Layout stays in logical pixels; the canvas owns an ARGB32 image surface backed
by the SDL texture buffer, and Cairo rasterises every path at the display
density.

- **Cairo geometry.** Panels, cards, buttons, knobs, faders, meter segments and
  chart fills are real anti-aliased paths with rounded corners, linear
  gradients and soft shadows. The same primitives are tested at 1×/2×/3× and
  under the responsive zoom.
- **Pango text.** Inter (Regular / Medium / SemiBold) carries the interface;
  Noto Sans Mono is reserved for timecode and numeric readouts. Pango provides
  shaping, kerning, hinting and per-face weights at the exact physical size, so
  labels stay crisp at fractional densities and responsive zoom.
- **Bundled fonts.** `assets/Inter-*.ttf` (SIL OFL 1.1) and
  `assets/NotoSansMono-Regular.ttf` (Apache-2.0) ship with the app.
  `scripts/install-desktop.sh` installs the Inter faces under
  `$PREFIX/share/fonts/tracker` and refreshes fontconfig. Pango falls back to
  the system sans face if they are absent.
- **HiDPI.** SDL opens the window with `WINDOW_ALLOW_HIGHDPI`; the density is
  `GetWindowSizeInPixels / GetWindowSize` and is recomputed every frame.
  `--ui-scale 1|1.25|1.5|2|3` forces it for testing. Pointer coordinates are
  normalised through the same pixel/logical ratio.
- **Window-responsive zoom.** The panel is authored at 1180x760. Above that,
  `ui_zoom_for_window()` returns a uniform zoom from the geometric mean of the
  width and height ratios, clamped to 1.8x and never below the tested 900x620
  virtual frame. The window layer renders the virtual layout with
  `canvas.scale = display_density * zoom` and maps pointer input through the
  same transform, so hit targets stay aligned at every size. At 1920x1080 the
  effective zoom is 1.52x (1263x710 layout); a 2536x986 window uses 1.59x
  (1595x620 layout). Below 1180x760 the zoom stays 1:1 and the flexible
  layout compresses instead of shrinking the type.
- **Charts.** Per-track input-level history, EQ response, compressor transfer,
  reverb decay, delay taps, stereo width and limiter ceiling are drawn as
  smooth polylines with gradient fills, grids and threshold markers.
- **Content-sized overlays.** The command palette, recent-project picker and
  I/O drawer shrink to their contents; the I/O list switches to two columns
  when crowded, and compact track strips trade the fader for a horizontal
  meter when the FX rack is open in a short window.

The legacy 12.5 px / 25 px mono atlases and the stb_truetype runtime path remain
only for the fixed-cell `canvas_text` tests; the application shell uses Pango.

Sources that shaped this path: Cairo's image-surface and path API, Pango's
Cairo integration (`pango_cairo_show_layout`, 72 dpi resolution), the SDL2
high-DPI guidance, and the Inter/SIL OFL and Noto font licences.

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
