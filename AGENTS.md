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

Run the app in a herdr pane so it is easy to inspect and kill. Never leave it as an orphaned background process.

1. `herdr pane split --current --direction right --cwd "$PWD" --no-focus` — note the returned `pane_id`
2. `herdr pane run <pane-id> "npm run tauri -- dev --features e2e-testing"`
3. `herdr pane wait-output <pane-id> --match "listening on unix"` — wait for the app + playwright socket
4. `herdr pane read <pane-id> --source recent-unwrapped --lines 80` — read logs
5. `herdr pane close <pane-id>` — kills the app and its child processes

The `e2e-testing` feature exposes the tauri-playwright socket bridge at `/tmp/tauri-playwright.sock` for driving the real webview (screenshots, clicks, IPC). It requires temporarily adding `"playwright:default"` to `src-tauri/capabilities/default.json`; **remove it afterwards** — plain `cargo build` fails on the unknown permission once the feature is off.

### Testing audio with real input device
1. Launch the app via herdr with `--features e2e-testing` (see above)
2. Open the sidebar on the right → the device list shows the PipeWire inputs (JACK clients, Ardour-style); the default source is marked with `*`
3. Each track header has an **IN n** selector for the input channel it records (defaults to 1, 2, 3, 4)
4. Click **CAPTURE** — live levels appear for every channel; speak/sing into the mic on Input 1 to verify Track 1's meter responds

### E2E Testing (18 tests passing)
- `cd e2e && npx playwright test --project=browser-only` — 18 tests in ~20s
- Tests: transport controls, arm/solo/mute, keyboard shortcuts (Space, R, 1-4, `:`), command palette, bounce section, meter rendering, capture/demo mode
- Fixtures in `e2e/fixtures.ts` with `createTauriTest` (browser mode with IPC mocks + Tauri mode via socket bridge)
- For Tauri desktop E2E: build with `--features e2e-testing` flag

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
