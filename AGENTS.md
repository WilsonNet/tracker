# AGENTS.md

## Design Context

This project has a PRODUCT.md and DESIGN.md at the repo root. Read both before making UI decisions.

- **Product**: A minimal multitrack audio recorder for desktop. Native Odin. Keyboard-first, Vim-native. No timeline, no grid — just arm, level, record, listen.
- **Design**: Dark instrument-panel aesthetic, committed orange/honey primary (hue 57°), mono-forward typography, flat surfaces, responsive motion tied to audio state.
- **Reference**: `docs/RESEARCH.md` analyzes the Zoom R4 MultiTrak (track system, overdub model, 32-bit float philosophy, hardware workflow). Read it before changing recording workflows. `docs/fx-research.md` covers the effects architecture.

## Architecture

The app is a single native binary in `odin/src/` — no webview, no IPC.

- **UI**: `src/ui/` — `view.odin` renders the `App` model as a vinland-ui element tree; `theme.odin` is the single source of design tokens; `text_edit.odin` owns caret/selection/clipboard/undo and `text_field_view.odin` maps pointer positions and paints the selection; `draw.odin` + `canvas_{cairo_linux,soft_other}.odin` + `font_runtime_{linux,other}.odin` power the headless harness (Cairo/Pango on Linux, pure-Odin + `stb_truetype` on macOS/other); `app.odin` holds state and key handling; `tracks.odin` the track count, visible window, marks, bounce-to-track dialog and track rename; `help.odin` the contextual F1 key sheet (pure model, `view.odin` only renders it).
- **Window**: `src/ui_window.odin` — SDL3 GPU (Metal on macOS, Vulkan on Linux) + OpenGL 3.3 fallback via vinland-ui, key mapping (`Cmd`/`Ctrl` via `platform_primary_mod`), engine commands, HiDPI.
- **Audio**: `engine.odin`, `engine_bounce_tracks.odin` (bounce marked tracks to a target track; BOUNCE button → dedicated `BOUNCE` track), `engine_track_delete.odin` (delete a track: WAVs to `deleted/`, later tracks shift up), `capture.odin` (miniaudio CoreAudio on macOS / PipeWire+ALSA on Linux), `jack_capture_{linux,other}.odin` + `jack_session_{linux,other}.odin` (Linux cooperative JACK), `wav.odin` (float32 WAV/RF64), `project.odin` (JSON persistence).
- **Platform isolation**: `src/platform_{linux,darwin,other}.odin`, `src/file_dialog_{linux,darwin,other}.odin` (`osascript` on macOS, `zenity`/`kdialog` on Linux), `src/ui/platform_{linux,darwin,other}.odin`. See `PLATFORMS.md` and `.agents/rules/`.

## Cross-OS Isolation & Handoff

- Never add `when ODIN_OS` conditionals inside shared files (`engine.odin`, `capture.odin`, `cloud_oauth.odin`, `file_dialog.odin`, `ui_window.odin`, `ui/app.odin`, `ui/view.odin`, `ui/draw.odin`, `ui/canvas_common.odin`). Put OS-specific code in `_linux.odin` (`#+build linux`), `_darwin.odin` (`#+build darwin`), and `_other.odin` (two lines: `#+build !linux` and `#+build !darwin`).
- Read [`PLATFORMS.md`](PLATFORMS.md) at the start of a session: clear any pending cross-OS checklist item you verify locally, and add a checkbox whenever you edit OS-specific code for the other OS that you cannot run locally.
- **DSP**: `src/dsp/` — hand-written biquad/EQ, compressor, limiter, FDN reverb, ping-pong delay, widener, resampling, mixdown. No VSTs, no plugin host.
- **Harness**: `src/ui_harness.odin` runs semantic UI scripts headlessly; `src/ui_cmd.odin` renders single frames.

Push logic into the model/engine and keep `view.odin` a pure render of `App`. New behavior belongs in `app.odin`/`engine.odin` with unit tests, not in the view.

## Text editing

SDL key events are consumed before vinland sees them, so Tracker owns text
entry. Clicking the project title in the status bar (or pressing `n` / running
`: rename project` / opening Settings `PROJECT` / clicking `RENAME` in Cloud
projects) enters inline or form **EDIT**; `Enter` saves (`project.json` +
window title + next Google Drive backup), while `Esc` cancels inline or asks
once before discarding in Settings (`Esc` again cancels). Clicking a text field
enters **EDIT**; `Enter` applies/saves and `Esc` asks once before discarding
(`Esc` again cancels). Clicking another field or `Tab`/`Shift+Tab` switches
text inputs without losing drafts; the form stays in EDIT until your explicit
save/cancel. The fields carry a real caret and anchor: click places it, drag
selects, Shift+click extends, double-click selects a word and triple-click
selects all. Arrows/Home/End move it, `Ctrl+arrow` moves by word,
`Ctrl+Backspace`/`Delete` delete words, and `Ctrl+C`/`X`/`V`/`Z`/`Y` (plus
`Shift+Insert`, `Shift+Delete`, `Ctrl+Insert`) use the desktop clipboard.
`Ctrl+A` selects all and the next type/paste/backspace replaces it. Paste goes
through `vapp.clipboard_read` and `ui.app_paste_text`; mirror the same path in
`window_synthetic_keys` so `vui-ctl` behaves like the real keyboard. Synthetic
keys reach vinland's input even though real SDL keys are consumed, so clear
vinland focus while a text field is editing or Tab/Enter can activate a button.
Credential fields reject spaces and secrets always render as `*`, including
while editing. Never put tokens in argv; clipboard helpers use fixed commands.
Native file pickers (`file_dialog_{linux,darwin}.odin`) return `"", false` when
`VUI_HIDDEN=1` so headless/e2e runs never pop OS dialogs onto the desktop.

## Feedback Loop (Critical)

Every prompt that produces a feature, component, or change must result in a **working, testable surface**:

1. `cd odin && make build` must succeed with no errors.
2. Run the relevant tests (`make test`, or `make test-dsp` / `test-core` / `test-ui`).
3. **Every UI change must be validated with `vui-ctl`** against the real offscreen
   window (see vinland-ui below): open the changed panel, click/type through the
   full flow, take screenshots, read the PNGs back, check `vui-ctl info` for
   `unknown_classes` and `frame_ms`, and confirm the window idles when the live
   state ends. A green build, unit tests, or `ui-shot` alone do not prove a UI
   change; run `make e2e` as well.
4. If something breaks, fix it in the same turn. Never leave a broken surface for the next prompt.

One-shot means: prompt in, working feature out.

## Feature Closeout

After implementing any feature, behavior change, or bug fix, load the
`.opencode/skills/feature-closeout` skill and follow it before saying the work is
done. It proves the surface and records durable lessons in `AGENTS.md`,
`odin/README.md`, `odin/ROADMAP.md`, `odin/VERIFICATION.md`, and the relevant
skills. Update stale counts, paths and claims in the same change.

## Research Rule

Before implementing any complex or unfamiliar feature, do an online search first. This includes audio device APIs, file formats, HiDPI/text rendering, persistence schemas, platform integration, and new UI patterns. Prefer official specifications and documentation (RF64/EBU, JACK, SDL3, Odin core/vendor, XDG), then prior art from comparable tools. Check the installed Odin sources for exact signatures, and record the sources that materially shaped the implementation in the relevant README/roadmap entry.

## Odin

- **Read the Odin documentation before writing Odin.** Prefer, in order: the installed compiler sources and examples under `~/.local/opt/odin` (`core/`, `vendor/`, `examples/`), the language overview at <https://odin-lang.org/docs/overview/>, and the package docs at <https://pkg.odin-lang.org/>. Use Context7 (`context7` MCP) when it has Odin coverage. Check exact signatures in the installed core/vendor sources before calling an API — do not guess.
- `odin/ROADMAP.md` is the status board: update it in the same change that moves a subsystem.
- `odin/README.md` documents the build, test, CLI and verification loop.
- `odin/VERIFICATION.md` is the test/measurement matrix; add new hardware or end-to-end evidence there.
- Keep `odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui` clean when touching package-level code.
- `proc "c"` audio callbacks have no Odin context: helpers they call must be
  `proc "contextless"`, and they must not allocate (see `recorder_push` and
  `preview_push`). Slicing or calling a contextful proc from a callback fails to
  compile with "context has not been defined".

## vinland-ui (native UI)

The window is drawn by the sibling [vinland-ui](https://github.com/WilsonNet/vinland-ui)
checkout at `../../vinland-ui` (override with `VINLAND=`); the Makefile passes it
as `-collection:vinland`. `odin/src/ui/view.odin` turns the app model into a
Tailwind-classed element tree; knobs, meters and FX graphs use vinland's canvas
primitives (`draw_line`, `draw_arc`, `draw_area`).

The upstream skill is symlinked at `.opencode/skills/vinland-ui` (`.claude/skills`
points at the same directory). **Load it before writing or changing any `vui`
code** — it covers the element API, the utility subset that actually renders,
design tokens, layout rules that differ from the web, and the screenshot/e2e loop.

vinland-ui is maintained by the same owner, so framework changes are allowed.
Keep them **generic and useful to every vinland app**: no tracker model types,
product names, or audio assumptions in `vui`. Add or update an upstream test or
example, run the vinland build/tests, and record the upstream change in the
closeout. Prefer composing the UI in `tracker` when existing primitives already
cover it.

- Build with `cd odin && make build`; rerun `./build.sh` in the vinland-ui checkout
  when its API changes. All UI edits must leave the build green.
- **Never run the app on the real GPU or the user's desktop for verification.** Use
  `VUI_HIDDEN=1` offscreen, drive it with `vui-ctl` (`--port`/`VUI_PORT`,
  `screenshot`, `tree`, `click-text`, `type`, `key`, `resize`, `dark`, `quit`),
  and read the PNG back. `VUI_HIDDEN_GPU` is only for a benchmark wrapped in
  `vinland-ui/tools/gpu-guard.sh`.
- `vui-ctl` input is synthetic and in-process: it never moves the real pointer,
  raises the window or asks for focus. For a **visible** run that must not
  disturb the user (gaming, calls), use `VUI_BACKGROUND=1` (or `make ui-bg`):
  the window is mapped without activation and with the non-focusable hint; X11
  honors it, while Wayland leaves focus policy to the compositor (use a
  no-focus rule there, or `VUI_HIDDEN=1` for the hard guarantee).
  `vui-ctl info` reports `background`, `focusable`, `keyboard_focus`,
  `mouse_inside`, `pointer_synthetic` and `video_driver`. `vui-ctl foreground`
  is the explicit escape hatch when a native file dialog, IME or a human
  takeover needs the OS window; `vui-ctl background` returns to the safe mode.
  On Wayland a compositor may refuse to make an existing surface focusable —
  restart without `VUI_BACKGROUND=1` for that flow.
  `vinland-ui/scripts/check-background.sh` verifies the X11 path under Xvfb.
- After every class change check `vui-ctl info` → `unknown_classes`: an unknown
  token renders nothing.
- Keep `make e2e` passing (`odin/tests/ui/window.vt`, run headless and sandboxed by
  `vinland-ui/build/vui-test`); inspect its report and baselines, not just the exit code.
- Parsed but **not drawn**: `blur-*`, `backdrop-*`, `mix-blend-*`, masks, `float`,
  `columns`, scroll-snap, 3D transforms, tables. Build those effects another way.

## Commands

All from `odin/`:

- `make build` — compile `bin/tracker-odin`
- `make test` — unit tests (318 on Linux / 312 on macOS: DSP + core/engine/project/cloud + UI)
- `make e2e` — headless vinland-ui window suite (`tests/ui/window.vt`)
- `make check` — unit tests + 220-action UI tour + offline bounce + format checks
- `make ui` (`make run`) — build and open the native window
- `make ui-bg` — visible non-focusable window on port 7421 for `vui-ctl` while the user games
- `make ui-shot SHOT=/tmp/ui.png` — render one frame (`--settings`, `--cloud`)
- `make ui-test SCRIPT=... UI_OUT=...` — run a harness script
- `make devices`, `make selftest`, `make bounce SESSION=...` — CLI helpers
- `make install` / `make uninstall` — desktop integration under `PREFIX`
- `./scripts/check.sh --hardware --jack --loopback` — real-device checks

Useful direct invocations:

```sh
./bin/tracker-odin ui --demo                  # synthetic meters, no hardware
./bin/tracker-odin ui --open session/project.json --jack
./bin/tracker-odin ui-shot --out /tmp/ui.png --fx --master --scale 2
./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui
```

### Running the app (herdr)

See the project skill `.opencode/skills/herdr` for the full workflow.

**Never split the pane/tab holding the agent conversation** — it steals width from the user's terminal. Run the app in its own tab.

The window class is `tracker`. Normal launches open on the active workspace, so
a visible run is fine to inspect with `vui-ctl`. For silent dev runs there is a
commented `tracker-dev-workspace` rule in `~/.config/hypr/hyprland.lua` that
routes the class to `special:tracker silent`; uncomment it and run `hyprctl
reload`. Agent verification should still use offscreen `VUI_HIDDEN=1`.

1. `herdr tab create --cwd "$PWD" --label "tracker"` — note `.result.root_pane.pane_id` and `.result.tab.tab_id` (no `--focus`)
2. `herdr pane run <pane-id> "cd odin && VUI_PORT=7421 ./bin/tracker-odin ui"`
3. `herdr pane wait-output <pane-id> --match 'vui: control server' --source recent-unwrapped --timeout 120000`
4. `vui-ctl --port 7421 screenshot /tmp/opencode/tracker.png` — read it back
5. `herdr pane read <pane-id> --source recent-unwrapped --lines 80` — logs
6. `herdr tab close <tab-id>` — kills the app and its children
7. only if the dev scratchpad rule is enabled: `hyprctl dispatch 'hl.dsp.workspace.toggle_special("tracker")'` to show/hide the window

## Testing

- `make test` — 74 DSP + core/engine/project/WAV/settings/cloud (160 on Linux, 154 on macOS without Linux JACK session tests) + 92 UI tests (326 total on Linux, 320 on macOS).
- `make e2e` — 32 cases in `tests/ui/window.vt` (layout, arm/solo/mute, input pills, record gating, FX rack, knob drag, BPM, render dialog range/format, palette, I/O, rhythm, undo, minimum size, fine drag, settings keyboard flow, text selection/caret and secret masking, cloud settings/overlay, project titling, create clean new project, tape scrubber shuttle/jog wheels + modifiers, timing mode Grid/Free switch, F1 contextual help, add tracks/zoom/page, bounce-to-track dialog, 24 tracks at minimum size, inline track rename, pause/marker/pre-roll controls, delete track, delete take, section end marker/loop/auto punch-out/pre-roll audio).
- The headless harness (`ui-test`, `ui-shot`; Cairo/Pango on Linux, pure-Odin + `stb_truetype` on macOS) remains the pixel-stable regression surface; the vinland window is verified through `vui-test` and `vui-ctl`.
- `scripts/check.sh` validates screenshots with `python3`; `ffprobe`/`sox` format checks run when installed.
- Do not claim a UI works without inspecting the generated PNG/report. Hardware recording evidence belongs in `odin/VERIFICATION.md`.

## Audio Engine

- **Capture** — miniaudio/ALSA and cooperative JACK (PipeWire). Arming a track while stopped opens a capture-only preview that feeds the input meter and history graph before REC; no take file is written. Each track records one selectable input channel; WAVs are true mono. Device hotplug falls back and can be rescanned.
- **Engine** — lock-free capture ring drained by a writer thread, real-time streaming playback via `dsp.Live_Mixer` (wait-free 3-slot triple buffer for live fader/pan/mute/solo/FX updates, pre-resampled `play_tracks` cache, persistent warm low-latency playback device configured per OS in `platform_{darwin,linux,other}.odin`), duplex live monitoring, metronome (40–240 BPM, Grid absolute clicktrack anchored to Bar 1 Beat 1 with accented downbeat + real time signatures `4/4, 3/4, 6/8, 5/4, 7/8, 2/4`, or opt-in Free relative click), pre-roll audio choice (`SONG` including armed lead-in ramp-out at punch-in vs `CLK` click-only until punch-in), sample-accurate `IN → OUT` playback looping with de-click fade (playback-only, never loop-recording), opt-in auto punch-out at `OUT`, manual latency trim, mixed-rate resampling to the project rate. Always call `engine_tracks_begin_edit`/`engine_tracks_end_edit` around mutations to `Engine.loaded` so the warm audio callback is quiesced safely.
- **Track chain** — 3-band EQ (low shelf 110 Hz → mid bell → high shelf 7.5 kHz) → compressor → fader/pan, with post-fader sends into the shared reverb and delay buses.
- **Master chain** — compressor → FDN reverb → ping-pong delay → mid/side widener (mono-safe below the bass crossover) → lookahead limiter with a soft-clip ceiling.
- **Persistence** — atomic `project.json` (takes, active take, comp regions, FX, markers `markerFrame`/`endMarkerFrame`/`loopEnabled`/`punchOutEnabled`, view and a11y flags), recent projects and machine settings under `XDG_CONFIG_HOME` (`settings.json`: project folder, high contrast, reduced motion, pre-roll length & `prerollAudio`; `cloud.json`: Google OAuth client/token/folder with 0600), RF64/BW64 reading and writing. Settings (`SET`, `,`) houses a unified `PROJECT` section (`+ NEW PROJECT` inline creator into a clean unique sibling folder preserving machine prefs, `OPEN…`, `RECENT`, rename, and `Project folder` copy/move); an explicit `--session` isolates `settings.json`, `recent.json`, and `cloud.json` beside the session so tests and throwaway takes never touch user config.
- **Cloud** — `cloud.odin` (store/PKCE/curl), `cloud_oauth.odin` (loopback OAuth), `cloud_drive.odin` (Drive v3), `cloud_jobs.odin` (background backup/restore + UI bridge). Scope is exactly `drive.file`; storage is a visible, named My Drive folder. Every created item carries `appProperties.tracker=1`, all queries are parent-scoped and marker-filtered, and there is **no remote DELETE**. Restore writes into a fresh local folder beside the current project, only after download succeeds, and never removes an existing target; a pre-existing name gets `-2`, `-3`, … Duplicate marked filenames are rejected instead of picked arbitrarily. Live setup, the new-machine path and safety tests: `docs/cloud-setup.md`, `tests/cloud/fake_drive.py`.
- Bounce renders the same chain offline to stereo float `bounce.wav`, including reverb tails. The main window also exposes `RENDER…` (`B`) for the same non-destructive mix to an external WAV via a dual-handle range/format dialog (32-bit float, 24-bit PCM, 16-bit PCM) and a save dialog. Drag either handle or click the track to move the nearest one; `j/k` selects and `h/l` nudges. The range is applied after the full mix render so reverb/filter state stays continuous.

## Docs

- `odin/README.md` — build, make targets, CLI, harness, limitations
- `odin/ROADMAP.md` — completion record and intentional limits
- `odin/VERIFICATION.md` — test/measurement matrix and sources
- `.opencode/skills/feature-closeout` — mandatory end-of-feature validation and docs update
- `docs/cloud-setup.md` — Google OAuth client, scope, Drive layout, safety model
- `docs/RESEARCH.md`, `docs/fx-research.md` — product and effects research
- `PRODUCT.md`, `DESIGN.md` — product strategy and visual system
