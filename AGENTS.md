# AGENTS.md

## Design Context

This project has a PRODUCT.md and DESIGN.md at the repo root. Read both before making UI decisions.

- **Product**: A minimal multitrack audio recorder for desktop. Tauri (Rust + React). Keyboard-first, Vim-native. No timeline, no grid — just arm, level, record, listen.
- **Design**: Dark instrument-panel aesthetic, committed orange/honey primary (hue 57°), mono-forward typography, flat surfaces, responsive motion tied to audio state.

## Architecture

- **UI**: React (TypeScript) — components, state, layout. Design lives here.
- **Non-UI / Backend**: Rust via Tauri — audio engine, file I/O, device management, project persistence, keyboard input capture, plugin system. Push as much logic to the Rust layer as possible. The React layer is a thin UI shell over a Rust core. When in doubt, implement a feature in Rust and expose it to the frontend via Tauri commands.

## Feedback Loop (Critical)

Every prompt that produces a feature, component, or change must result in a **working, testable surface**. Use Playwright MCP to verify:

1. Build/compile must succeed with no errors.
2. Launch the Tauri app (or the Vite dev server for UI-only iteration).
3. Use Playwright browser automation to confirm the feature renders, responds to input, and states work (hover, focus, active, disabled, empty, error, loading).
4. If something breaks, fix it in the same turn. Never leave a broken surface for the next prompt.

One-shot means: prompt in, working feature out. The feedback loop closes the gap between "wrote code" and "verified it works."

## Build Tracking

`docs/tasks/audio-engine.md` tracks the audio engine implementation as a phased build plan with real-time status. Read it before starting any Rust audio work to understand what's done and what's next.

## Reference Research

`docs/RESEARCH.md` contains a deep analysis of the Zoom R4 MultiTrak — the hardware reference for this product. Read it before building any recording workflow features. It documents the track system (4 tracks + bounce track), the overdub-based composition model, 32-bit float recording philosophy, hardware controls layout, effects architecture, and the key workflow principles that define this product category.

## Commands

- `npm run tauri dev` — full Tauri app with Rust backend (audio engine, device capture)
- `npm run dev` — Vite dev server (UI-only, faster iteration, no Tauri IPC)
- `cargo build` (from src-tauri/) — compile Rust backend
- `npm run typecheck` — TypeScript type check
- `npm run build` — full Vite production build
- `cargo test` (from src-tauri/) — Rust unit tests
- `npm run test:e2e` — browser-only E2E tests (fast, no Tauri needed)
- `npm run test:e2e:tauri` — full desktop E2E tests (requires `npm run tauri dev` with e2e-testing feature)

### Running the Tauri app (herdr)

See the project skill `.opencode/skills/herdr` for the full workflow.

**Never split the pane/tab holding the agent conversation** — it steals width from the user's terminal. Run every dev server in its own tab.

The window opens **silently on the Hyprland special workspace `special:tracker`** (window rule with the required ` silent` suffix, no keybind). It never switches the active workspace or steals focus. Because the workspace is hidden, the window is neither composited (screenshots are blank) nor reachable by native mouse injection — verify UI in the Vite dev server with Playwright instead.

1. `herdr tab create --cwd "$PWD" --label "tracker dev"` — note `.result.root_pane.pane_id` and `.result.tab.tab_id` (no `--focus`)
2. `herdr pane run <pane-id> "npm run tauri -- dev"`
3. `herdr pane wait-output <pane-id> --match 'Running \`target/debug/tracker\`' --source recent-unwrapped --timeout 300000`
4. `herdr pane read <pane-id> --source recent-unwrapped --lines 80` — read logs
5. `herdr tab close <tab-id>` — kills the app and its children
6. `hyprctl dispatch 'hl.dsp.workspace.toggle_special("tracker")'` — show/hide the app window

Only one Vite can bind port 1420. If `tauri dev` reports the port in use, a previous dev-server tab is still alive.

The `e2e-testing` feature exposes the tauri-playwright socket bridge at `/tmp/tauri-playwright.sock` for driving the real webview (screenshots, clicks, IPC). It requires temporarily adding `"playwright:default"` to `src-tauri/capabilities/default.json`; **remove it afterwards** — plain `cargo build` fails on the unknown permission once the feature is off.

### Native effects rack

All effects are hand-written Rust DSP (`src-tauri/src/audio/fx/`) — no VST, no plugin host, no GPL crates.

- **Track chain:** 3-band EQ (low shelf 110 Hz → mid bell → high shelf 7.5 kHz) → compressor → fader/pan, plus post-fader sends into the shared reverb and delay buses.
- **Master chain:** compressor → FDN reverb → ping-pong delay → mid/side widener (mono-safe below the bass crossover) → lookahead limiter with a Hermite soft-clip ceiling.
- `preview_mix` renders the current mix with FX and plays it (resampled to the device rate); `bounce_tracks` writes a stereo 32-bit float `bounce.wav` through the same chain. Both return 20 Hz gain-reduction timelines that drive the UI meters.
- The UI is `src/components/FxRack.tsx` + `src/components/fx/*`; shared model/math in `src/lib/fx.ts` (mirrors the Rust defaults and RBJ formulas). `x` toggles the rack, `[`/`]` cycle channels, `Escape` closes it.

### Testing audio with real input device
1. Launch the app via herdr with `--features e2e-testing` (see above)
2. Open the sidebar on the right → the device list shows the PipeWire inputs (JACK clients, Ardour-style); the default source is marked with `*`
3. Each track header has an **IN n** selector for the input channel it records (defaults to 1, 2, 3, 4)
4. Click **CAPTURE** — live levels appear for every channel; speak/sing into the mic on Input 1 to verify Track 1's meter responds

### E2E Testing (27 tests passing)
- `cd e2e && npx playwright test --project=browser-only` — 27 tests in ~45s
- Tests: transport controls, arm/solo/mute, keyboard shortcuts (Space, R, 1-4, `:`), command palette, bounce section, meter rendering, capture/demo mode, the I/O panel, and the FX rack (open/close, tabs, bypass, knob keyboard/drag, sends, live GR meters)
- Fixtures in `e2e/fixtures.ts` with `createTauriTest` (browser mode with IPC mocks + Tauri mode via socket bridge). Mock handlers are stringified into the page — they must be self-contained, no outer references.
- `e2e/tests/desktop.spec.ts` is the real-engine test; it's skipped unless the window is visible: `hyprctl dispatch 'hl.dsp.workspace.toggle_special("tracker")'`, then `TRACKER_VISIBLE=1 npm run test:e2e:tauri` (requires the `e2e-testing` feature + `playwright:default`)
- The bridge's native pointer injection does not reach a hidden or floating window. Drive the real webview through `e2e/js-driver.ts` (`click`, `setSelect`, `press`, `hotkey`) — it dispatches DOM events inside React instead. `e2e/tests/live-record.spec.ts` is the hardware recording check (`TAURI_LIVE=1`).
- Rust DSP coverage lives in `cargo test --lib` (34 tests): filter responses, compressor curve, reverb decay/decorrelation, delay timing, widener mono-sum, limiter ceiling, full stereo mixdown and WAV write, and the exact UI JSON payload.

### Architecture: Audio Engine (Rust, real-time safe)

- **cpal 0.18** with ALSA backend (compatible with PipeWire on modern Linux)
- **Capture device selection on Linux** (three tiers):
  1. **JACK** (`jack` crate, pipewire-jack): device list = PipeWire inputs as JACK clients with per-port capture (`Scarlett ...:capture_FL`); capture connects `tracker:in_N` ports to the selected device's ports. Cooperative — works while Ardour/PipeWire hold the hardware. This is Ardour's model.
  2. **PipeWire ALSA** fallback: `pactl` sources, captured through the `pipewire` PCM with `PIPEWIRE_NODE` targeting and `BufferSize::Fixed(1024)`.
  3. **Raw hardware** fallback (pure ALSA): `plughw:CARD=n,DEV=n` cards only, no ALSA plugin pseudo-devices.
- **Per-track input channel**: each track records one channel (`IN n` in the track header); WAVs are true mono, deinterleaved from the capture stream
- Three-thread model: React UI / Audio Control Thread / audio RT callback (cpal or JACK)
- **ringbuf** for lock-free sample transfer (no allocs in audio callback)
- **crossbeam-channel** for commands to audio control thread
- `level-update` Tauri events (50ms interval) stream peak/RMS for every channel
- Device enumeration via `list_audio_devices` Tauri command
