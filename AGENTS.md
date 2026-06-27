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

### Testing audio with real input device
1. `npm run tauri dev` — launches the full Tauri app
2. Hover sidebar on right → select your Focusrite Scarlett (or other input device)
3. Click **CAPTURE** — meters on Track 1 should show live level
4. Speak/sing into the mic on Input 1 to verify the LevelMeter responds

### E2E Testing (18 tests passing)
- `cd e2e && npx playwright test --project=browser-only` — 18 tests in ~20s
- Tests: transport controls, arm/solo/mute, keyboard shortcuts (Space, R, 1-4, `:`), command palette, bounce section, meter rendering, capture/demo mode
- Fixtures in `e2e/fixtures.ts` with `createTauriTest` (browser mode with IPC mocks + Tauri mode via socket bridge)
- For Tauri desktop E2E: build with `--features e2e-testing` flag

### Architecture: Audio Engine (Rust, real-time safe)

- **cpal 0.18** with ALSA backend (compatible with PipeWire on modern Linux)
- Three-thread model: React UI / Audio Control Thread / cpal RT Callback
- **ringbuf** for lock-free sample transfer (no allocs in audio callback)
- **crossbeam-channel** for commands to audio control thread
- `level-update` Tauri events (50ms interval) stream RMS/peak per channel
- Device enumeration via `list_audio_devices` Tauri command
- Track meters driven by live level data when capture is active
