# tracker-odin

Native Tracker application in [Odin](https://odin-lang.org/) for **Linux and macOS**. One
self-contained binary: SDL3 GPU (Metal on macOS, Vulkan on Linux) + OpenGL 3.3 fallback through vinland-ui, miniaudio (CoreAudio on macOS, PipeWire/ALSA on Linux) or a
cooperative JACK client (Linux), and a hand-written DSP chain. No webview, no
JavaScript runtime, no IPC boundary.

**Status: complete.** The window, live capture, monitoring, overdub, playback,
takes/comping, full FX chain, bounce, RF64, project persistence, native dialogs,
recent projects, undo/redo, JACK GUI, HiDPI and the headless click/screenshot
harness all work. See [ROADMAP.md](ROADMAP.md) for the completion record and
intentional limits.

## Why Odin

The motivation is iteration speed: a full build of the UI, audio engine, DSP
and CLI takes **≈0.8 s** on this machine (Ryzen, 16 threads). Change a pixel or
a DSP coefficient and the native window is rebuilt and running immediately.

No Node dev server, no webview and no IPC boundary are involved.

## Dependencies

**macOS (Apple Silicon / Intel):** Odin (`dev-2026-11a` or newer), SDL3, and Xcode Command Line Tools. Odin already ships precompiled `vendor/miniaudio/lib/darwin/miniaudio.a` and `vendor/stb/lib/darwin/stb_truetype.a`, and the headless harness uses a pure-Odin + `stb_truetype` rasterizer, so Pango/Cairo/JACK are not needed. Native open/save-as dialogs use `osascript` Cocoa panels, Drive login opens Safari/default browser with `open`, and text fields accept both `Cmd` and `Ctrl`.

```sh
brew install odin sdl3
# optional for format checks: ffmpeg
```

**Linux:** A C toolchain (Odin shells out to `clang`, `cc` and `ld`; `ar` is
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
make test         # 274 unit tests (Linux) / 268 (macOS)
make check        # unit + headless UI tour + offline end-to-end

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
| `test` | unit tests: 71 DSP, 130 core (Linux) / 124 core (macOS), 73 UI = 274 (Linux) / 268 (macOS) |
| `check` | `scripts/check.sh`: unit tests, 220-action UI tour, offline bounce |
| `e2e` | 20 headless vinland-ui window cases (`tests/ui/window.vt`) |
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
- **Transport & Tape Scrubber:** REC / PLAY / STOP / BOUNCE, timecode, armed count, BPM
  stepper, metronome click, live input **MON**itoring, latency trim and a
  PipeWire/cooperative-JACK backend switch. Centered in the bottom deck bar is a
  hardware-inspired **Tape Scrubber** with a **`|◄` RTZ** button and dual rotary
  wheels: **SHUTTLE** (`5.0 s` normal / `1.0 s` `Shift` / `0.25 s` `Ctrl|Alt`)
  and **JOG** (`250 ms` normal / `50 ms` `Shift` / `10 ms` `Ctrl|Alt`), plus loaded
  tape length (`/ MM:SS.s`). Hover either wheel (or the transport timecode) and
  scroll, vertical-drag either wheel, double-click the wheel/timecode for RTZ, or
  scrub from the keyboard; when stopped, scrubbing cues playback and peeks the
  meters at the tape head without modifying takes.
- **Takes and mix:** multi-take recording (`T1/2` on each strip), active-take cycling,
  whole-take comping from the palette, and arbitrary comp regions through the
  `comp` CLI. `BOUNCE` writes the canonical `bounce.wav`; `RENDER…` opens a
  range/format dialog and writes the same full-chain stereo mix to an external
  WAV. Drag either end of the range track (or click the track to move the
  nearest hand); `j/k` selects FROM/TO/FORMAT and `h/l` nudges by 0.5 s
  (Shift: 5 s). Formats are 32-bit float, 24-bit PCM and 16-bit PCM. Projects
  keep the legacy `file` plus the full take/comp list.
- **HiDPI + responsive density:** the window lays out in logical pixels at the
  compositor's density (1×–3×). The native window expands or compresses the
  flexible layout; the headless harness scales the whole virtual frame up to
  1.8×. `--ui-scale` forces a physical density for testing.
- **FX rack:** `x` or FX. Track tabs `1–4`, `MST`; draggable knobs (vertical
  drag), bypass toggles, ping-pong, response visuals.
- **I/O panel:** live PipeWire/JACK source list, JACK-backend toggle, latency
  ± controls, rescan and device selection.
- **Settings:** `,` or the SET button. Edits the **Project name** (`PROJECT`
  section) and **Project folder** (type, BROWSE…, APPLY, DEFAULT); BROWSE starts
  in the parent of the current project so sibling projects are visible. Shows the
  input device/backends, latency and monitoring, and toggles high contrast and
  reduced motion. `j/k` selects a row and `Enter` runs it. Clicking a text field
  enters EDIT with a real caret: click/drag or Shift+click select, double-click
  selects a word, triple-click selects all, arrows/Home/End and Ctrl+word
  movement work, and `Ctrl+C`/`X`/`V`/`Z`/`Y` use the clipboard and undo.
  `Enter` applies, `Esc` asks before discarding, and `Tab`/`Shift+Tab` switch
  inputs without losing drafts. Client secrets render as `*` even while
  editing. The folder and accessibility choices persist in
  `~/.config/tracker/settings.json`; changing the folder copies the current
  takes into it and leaves the old folder as a recovery copy. A folder that
  already contains `project.json` or any `trackN.wav` (1–24) is refused, so applying
  cannot overwrite another session.
- **Project title & Google Drive naming:** Click the project title in the
  bottom status bar, press `n`, run `: rename project`, edit `Project name` in
  Settings, or click `RENAME` inside Cloud projects (`g`). `Enter` trims and
  persists the name to `project.json`, updates the window title
  (`Tracker — <name>`), and renames the existing Google Drive backup folder
  in place on the next backup (updating `index.json` without creating
  duplicate/orphaned folders). Empty names are rejected.
- **Render dialog:** `B` or `RENDER…` opens Range + Format around a
  dual-handle track. Drag either handle to trim; clicking the track moves the
  nearest handle there. `j/k` select FROM/TO/FORMAT, `h/l` nudge by 0.5 s
  (Shift: 5 s), and the format chips choose 32-bit float, 24-bit PCM or 16-bit
  PCM. `Enter` opens the save dialog. Rendering is non-destructive and always
  stereo at the project rate. Handles clamp at 0.1 s apart and at the mix
  bounds; an empty range is refused.
- **Cloud projects:** Google Drive backup/restore. Shows the current project
  title with quick `RENAME` and `BACK UP` actions. `Settings → CLOUD` holds
  the Drive folder name, OAuth client ID/secret, connect/disconnect, back up
  and restore. `g` opens the cloud-project list; `u` backs up, `n` renames the
  project, `r` refreshes. Setup, the new-machine restore path and the safety
  model are in [`../docs/cloud-setup.md`](../docs/cloud-setup.md).
- **Headless UI harness:** `ui-test` (below) drives the exact same state
  machine without a browser or window.
- **Keyboard:** `Space` play/stop, `R` record, `b` bounce, `B` render dialog, `1–4` arm, `j/k`
  select, `J/K` level, `h/l` jog `±250 ms` (`H/L` fine `±50 ms`, `Alt|Ctrl+h/l`
  micro `±10 ms`), `</>` shuttle `±5.0 s`, `0` return to zero (`|◄`), `m` mute,
  `s` solo, `a` arm, `n` rename project, `I` input, `x` FX, `c` click, `o`
  monitor, `y` JACK backend, `t`/`T` next/previous take, `u`/`U` undo/redo,
  `[`/`]` FX channel, `Tab`/`Shift+Tab` FX focus, `,` settings, `g` cloud projects,
  `:` command palette (`rewind to start`, `shuttle forward/back`, `jog forward/back`),
  `Esc` close. Recent projects and open/save-as live in the palette; the dialogs
  use zenity or kdialog on Linux and Cocoa panels on macOS. Double-click resets a
  fader/pan/knob or rewinds from the scrubber/timecode.

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
- A live Google account round-trip verified the visible `Tracker/` hierarchy,
  repeated backup, an innocent same-named `track1.wav`, and byte-identical
  restore into a fresh local folder (see `VERIFICATION.md`).

### Design tokens

`src/ui/theme.odin` is the single source of truth, layered so a palette change
or a density tweak never touches drawing code:

- **Palette constants** — the exact brand values as sRGB (`BG_VALUE`,
  `AMBER_VALUE`, …), with the OKLCH origin in comments. These values are
  canonical.
- **`Color_Tokens`** — semantic roles (`bg`, `surface`, `ink`, `ink_dim`,
  `line`, `amber`, `red`, `teal`, …). Widgets never read the raw palette.
- **`Space_Tokens`** — a 1/2/4/6/8/12/16/24 px rhythm used for padding.
- **`Type_Tokens`** — a fixed 8.5/9/10/11.5/14/20/25 px scale (product UI never
  scales type fluidly). The 12.5 px body and 25 px heading atlases remain for
  `canvas_text`.
- **`Metric_Tokens`** — header/bottom/status heights, margins, gutters, control
  sizes, fader/meter widths. `app_layout` reads these instead of magic numbers.
- **Responsive density (headless)** — `UI_BASE_WIDTH/HEIGHT`, `UI_MAX_ZOOM`
  and `ui_zoom_for_window()` derive a uniform virtual-frame zoom for
  `ui-test`/`ui-shot`; the same scale multiplies canvas density, so type and
  controls grow together. The native window uses SDL density plus the
  flexible layout instead.
- **`Tokens` / `ACTIVE_TOKENS`** — the live bundle handed to the renderer;
  `TOKENS_HIGH_CONTRAST` swaps colour only, leaving geometry untouched.

The default theme is the reference palette: `#010101` canvas, `#060606` bars and
panels, `#1B1B1B` hairlines, `#F08A31` amber, `#BA022F` record red, `#00858D`
solo/play teal, and the three-step ink ramp `#E8E8E8` / `#8F8F8F` / `#5D5D5D`.

Sessions live in `~/.local/share/tracker/session` by default and contain
`project.json`, `track1.wav` … `track4.wav`, and `bounce.wav` (plus a
transient `take.raw` while a take is being captured).

## Headless UI harness

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
`resize`. The full tour is **220 actions / 17 screenshots**. A `report.json`
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
files over the RIFF limit). It requires an explicit `--session`; the command no
longer writes the default session's `bounce.wav`. `comp --list` shows
takes/regions; `--select` changes the active take; `--take/--start/--end` adds
a region; `--clear` removes them.

Save As refuses a folder that already contains a Tracker project or
`trackN.wav`, so it cannot merge two sessions. Closing the window during REC
finalizes the take (the previous active take is stabilized to its take file
first) and writes `project.json`; take stop/selection and a clean close also
persist the project. A malformed `project.json` is renamed to
`project.json.corrupt-<pid>` before the recovered takes are shown.

## Tests and verification

```sh
make test        # 71 DSP + 129 core/engine/project/cloud + 71 UI = 271 tests
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

Coverage includes the DSP regression vectors (biquad, EQ, compressor, limiter,
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
    main.odin              CLI entry
    ui_window.odin         vinland-ui window (SDL3 Metal/Vulkan + GL fallback) + key mapping + engine commands
    ui_harness.odin        scripted headless UI test runner
    ui_cmd.odin            ui-shot
    platform_*.odin        OS isolation (linux, darwin, other): audio map, JACK flag, open URL, Cmd/Ctrl mod, RSS
    file_dialog*.odin      shared picker logic + zenity/kdialog (linux) + osascript (darwin) + stub (other)
    engine.odin            ring-buffer capture, playback, bounce, overdub
    project.odin           project.json + DSP/view mapping
    capture.odin           miniaudio enumeration/capture (CoreAudio / PipeWire / ALSA)
    jack_capture*.odin     shared JACK port filter + Linux client + non-Linux stub
    jack_session*.odin     Linux lock-free JACK session + non-Linux stub
    wav.odin               float32 WAV + PCM import
    cloud*.odin            Drive store, OAuth, Drive API, background jobs
    dsp/                   biquad, EQ, comp, limiter, reverb, delay, widener,
                           resample, render
    ui/                    view (vinland element tree), theme, app/input,
                           text_edit, text_field_view, platform_*.odin,
                           canvas_common.odin, Cairo/Pango (linux), pure-Odin/stb_truetype (!linux),
                           charts, PNG, tests
  scripts/                 check.sh, install-desktop.sh, gen_font.py
  tests/ui/                full-tour.json, window.vt, e2e-checklist.md
  assets/                  tracker.png / tracker.svg / Inter-*.ttf /
                           Inter-OFL.txt / NotoSansMono-Regular.ttf
  assets/fonts/            JetBrainsMono-*.ttf (window) / JetBrainsMono-OFL.txt
```

The native tree is self-contained. Source comments record the original DSP
algorithm names for provenance, but no legacy frontend or Node toolchain is
needed to build, test or run it.

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

`vui-ctl` pointer/key commands are injected inside the app: they never move the
real OS pointer, raise the window or request focus. To keep a visible window
while the user plays a game or works in another app, start it with
`VUI_BACKGROUND=1` (or `make ui-bg`): the window is mapped without activation and
with SDL's non-focusable hint. X11 window managers honor the hint; Wayland leaves
focus policy to the compositor, so use a no-focus rule there or `VUI_HIDDEN=1`
for the hard no-desktop-contact guarantee. `vui-ctl info` reports `background`,
`focusable`, `keyboard_focus`, `mouse_inside`, `pointer_synthetic` and
`video_driver`. When a native dialog, IME or human takeover genuinely needs the
OS window, `vui-ctl foreground` is the explicit escape hatch (and
`vui-ctl background` returns to the safe mode); on Wayland the compositor may
refuse to make an existing surface focusable, so restart without
`VUI_BACKGROUND=1` for that flow.

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
  under the harness responsive zoom.
- **Pango text (headless harness).** Inter (Regular / Medium / SemiBold) carries
  labels; Noto Sans Mono is reserved for timecode and numeric readouts. Pango provides
  shaping, kerning, hinting and per-face weights at the exact physical size, so
  labels stay crisp at fractional densities and harness zoom.
- **Bundled fonts.** The window embeds `assets/fonts/JetBrainsMono-*.ttf`
  (SIL OFL 1.1). The Cairo/Pango harness uses `assets/Inter-*.ttf` (SIL OFL
  1.1) and `assets/NotoSansMono-Regular.ttf` (Apache-2.0).
  `scripts/install-desktop.sh` installs the Inter faces under
  `$PREFIX/share/fonts/tracker` and refreshes fontconfig. Pango falls back to
  the system sans face if they are absent.
- **HiDPI.** SDL opens the window with `HIGH_PIXEL_DENSITY`; density is
  `GetWindowSizeInPixels / GetWindowSize` and is recomputed every frame.
  `--ui-scale 1|1.25|1.5|2|3` forces it for testing. Pointer coordinates are
  normalised through the same pixel/logical ratio.
- **Headless virtual frame.** `ui-test` and `ui-shot` author the panel at
  1180x760 and apply `ui_zoom_for_window()` from the geometric mean of the
  width/height ratios, clamped to 1.8x and never below the tested 900x620
  virtual frame. At 1920x1080 the harness uses 1.52x (1263x710 layout); a
  2536x986 canvas uses 1.59x (1595x620 layout). The native window stays at
  SDL's logical pixel size and lets the flexible layout expand or compress;
  `--ui-scale` only changes physical density.
- **Charts.** Per-track input-level history, EQ response, compressor transfer,
  reverb decay, delay taps, stereo width and limiter ceiling are drawn as
  smooth polylines with gradient fills, grids and threshold markers.
- **Content-sized overlays.** The command palette, recent-project picker and
  I/O drawer shrink to their contents; the I/O list switches to two columns
  when crowded, and compact track strips trade the fader for a horizontal
  meter when the FX rack is open in a short window.

The legacy 12.5 px / 25 px mono atlases and the stb_truetype runtime path remain
only for the fixed-cell `canvas_text` tests; the headless harness uses Pango.

Sources that shaped this path: Cairo's image-surface and path API, Pango's
Cairo integration (`pango_cairo_show_layout`, 72 dpi resolution), the SDL3
high-DPI guidance, and the JetBrains Mono/Inter/Noto font licences.

## Limitations

- Latency compensation is manual (`--latency-ms`/I/O ±): it trims a fixed
  offset from each new take. There is no automatic round-trip calibration.
- Live monitoring is a duplex path with a fixed −6 dB gain; it is not a
  zero-latency hardware monitor loop, and overdub can still drift on long takes.
- Accessibility is keyboard-first with high-contrast/reduced-motion modes and a
  textual `--a11y-log` snapshot. There is no AT-SPI accessibility tree.
- Settings text entry is single-line printable ASCII; there is no IME or
  non-Latin composition in the custom text fields.
- JACK GUI takes accumulate in RAM until stop (≈384 MB/hour stereo); the CLI
  path is unchanged.
- RF64 writing/streaming is implemented and tested, but the engine still
  buffers each take while splitting it; it does not stream a take end-to-end.
- Multi-take comping has whole-take UI and arbitrary-region CLI; there is no
  waveform/timeline region editor by product design.
- Preview render, bounce and external render run synchronously on the UI
  thread; a long mix can pause the window while it renders. Long bounces show
  the bounce overlay but do not make the render asynchronous.
- External render is stereo WAV at the project rate: 32-bit float, 24-bit PCM
  or 16-bit PCM. There is no compressed format (MP3/FLAC) and no stem export.
  Integer exports stay RIFF; a >4 GB 16/24-bit mix is refused.
- The Cairo/Pango harness remains the pixel-stable regression surface. The
  vinland window is exercised through `vui-test`/`vui-ctl`; pointer input is
  synthetic by default and never touches the OS pointer. Real OS focus is an
  explicit `vui-ctl foreground` escape hatch, not the default.
- HiDPI density is sampled from the compositor's window/pixel ratio; densities
  outside 1–3× are clamped. `--ui-scale` is limited to the tested
  1/1.25/1.5/2/3 set.
- Google Drive transfer is explicit backup/restore, not live sync; a live Google
  account round-trip still needs the user's own OAuth client.
