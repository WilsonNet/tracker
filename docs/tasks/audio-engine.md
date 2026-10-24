# Tracker Audio Engine — Build Plan & Status

> Last updated: 2026-10-24
> Status: Phase C complete — native effects, stereo preview & bounce

---

## Task Structure

| Phase | What | Area | Status |
|-------|------|------|--------|
| A | Audio engine foundation + device enumeration | Rust | ✅ Complete |
| B | Recording pipeline (arm, record WAV, level streaming) | Rust + React | ✅ Complete |
| C | Effects & bounce | Rust | ✅ Complete |
| D | Desktop E2E testing via tauri-playwright | Rust + Test | ✅ Complete |
| E | Performance tuning + polish pass | Rust + UI | ✅ Complete |
| F | Device & channel selection (PipeWire/JACK) | Rust + React | ✅ Complete |

---

## Phase A — Audio Engine Foundation

### Goals
- Add audio deps to Cargo.toml (cpal, ringbuf, crossbeam, hound)
- Create `src-tauri/src/audio/` module with AudioEngine struct
- Device enumeration (list_audio_devices command)
- Audio engine background thread with cpal PipeWire backend
- Level meter data streaming via Tauri events
- Device selection UI in React sidebar
- Testing with Focusrite Scarlett (Input 1 has active mic) to verify meters

### Status
- [x] Research complete (cpal with PipeWire-compatible ALSA backend, ringbuf, three-thread model)
- [x] Cargo.toml updated with audio deps (cpal 0.18, ringbuf, crossbeam)
- [x] audio/mod.rs — AudioEngine struct, re-exports
- [x] audio/device.rs — cpal ALSA/PipeWire device enumeration
- [x] audio/engine.rs — background thread, cpal input stream, ringbuf level pipeline
- [x] audio/metrics.rs — underrun/overrun tracking integrated into engine
- [x] lib.rs — AudioEngine managed state + commands (list, start, stop, status)
- [x] lib.rs — level-update Tauri event streaming from audio control thread
- [x] Capabilities — updated to core:default + event permissions
- [x] React: device selector dropdown + capture button in sidebar
- [x] React: wired level-update events to Track 1 meter
- [x] Test: `cargo build` passes (backend + frontend)
- [x] Test: `tsc --noEmit` passes (TypeScript)
- [x] Test: `vite build` passes
- [ ] Test: `cargo tauri dev` launches with audio capture from Scarlett
- [ ] Test: meters show real-time levels from Scarlett Input 1

### Current Blockers
None yet.

---

## Phase B — Recording & Playback

### Goals
- arm_track, start_recording, stop_recording commands
- 32-bit float WAV writing via hound
- Level data streaming (peak + RMS per track) with recording flag
- Recording glow + meter animation in frontend

### Status
- [x] hound crate added to Cargo.toml
- [x] AudioEngine.arm_track() — per-track arm state management
- [x] start_recording() — creates WAV files per armed track, writes 32-bit float
- [x] stop_recording() — finalizes WAV files, clears writers
- [x] Level thread writes samples to WAV when recording is active
- [x] lib.rs commands: arm_track, start_recording, stop_recording, recording_status
- [x] React: record button triggers backend recording
- [x] React: arm button syncs with backend
- [x] React: recording glow on transport (red active state)
- [x] Verified: Record button toggles "Stop recording" with active state
- [x] Verified: Arm buttons show active+pressed state
- [x] Verified: `cargo build` + `tsc --noEmit` + `vite build` all pass

---

## Phase C — Effects & Bounce

### Goals
- Native effects, no VST/plugin host: EQ, compressor, reverb, delay, stereo widener, limiter
- Per-track inserts + shared reverb/delay sends; master bus chain
- Bounce: mix 4 tracks through the full chain → stereo 32-bit float WAV

### Status
- [x] `audio/fx/` module: biquad (RBJ), EQ, compressor, FDN reverb, stereo delay, widener, lookahead limiter
- [x] Real-time-safe: all buffers allocated at construction, no allocation in `process`
- [x] Per-track chain: EQ → comp → constant-power fader/pan → post-fader sends
- [x] Master chain: comp → reverb → delay → widener → limiter (+ Hermite soft-clip ceiling)
- [x] `render_mix` offline renderer with a 20 Hz gain-reduction timeline per stage
- [x] `preview_mix` command: render + play through the default output device (resampled to device rate, any channel count)
- [x] `bounce_tracks` command: same chain → stereo `bounce.wav`; returns peak/GR stats
- [x] React FX rack: channel tabs, per-module bypass, drag/wheel/keyboard knobs, live response visuals, GR meters during playback
- [x] Keyboard: `x` rack, `[`/`]` channels, `Escape` closes; track FX badge opens that channel
- [x] 34 Rust DSP/engine tests + 26 browser E2E tests
- [ ] Live monitoring of effects during capture (effects currently apply to preview/bounce, not the input path)

### Notes
- Reverb is an 8-line Householder FDN (real size control, exact RT60), not Freeverb; delay uses linear-interpolated fractional reads with tape-style saturation in the loop.
- `fundsp` was dropped: GPL-3.0. Everything is written against public-domain papers (RBJ, Dattorro diffusion, Giannoulis/Reiss compressor, Adriaensen-style lookahead limiting) and unit-tested.
- Sends are shared buses: one reverb and one delay instance, track send knobs feed them, master RETURN sets the wet level.

---

## Phase D — Desktop E2E Testing

### Goals
- Add tauri-plugin-playwright behind e2e-testing feature
- Install @srsholmes/tauri-playwright
- Write fixtures + spec files
- Verify: device list, transport, arm/solo/mute, keyboard, capture, meters, bounce

### Status
- [x] tauri-plugin-playwright (0.4.1) added to Cargo.toml behind `e2e-testing` feature
- [x] @srsholmes/tauri-playwright (0.4.1) installed as dev dependency
- [x] Playwright config with browser-only and tauri projects
- [x] Test fixtures with IPC mocks
- [x] 17 E2E tests covering: transport controls, arm/solo/mute, keyboard shortcuts (Space, R, 1-4, `:`), command palette, bounce section, meter rendering, capture/demo mode
- [x] Verified: 17/17 tests pass in browser-only mode
- [x] Run: `npm run test:e2e` — browser-only (fast, no Tauri)
- [x] Run: `npm run test:e2e:tauri` — desktop (requires cargo tauri dev --features e2e-testing)

---

## Phase E — Performance Tuning & Polish

### Goals
- SCHED_FIFO real-time priority for audio thread (cpal realtime feature)
- Recording timer with timecode display
- Polished sidebar with recording status, output dir, perf metrics
- VimStatusLine with capture/recording indicators
- Error hardening in Rust engine
- Final E2E verification

### Status
- [x] cpal `realtime` feature enabled for SCHED_FIFO on audio callback thread
- [x] Recording timer with elapsed time in TransportBar
- [x] Sidebar: LIVE LEVELS, RECORDING (time, output, armed), SESSION, FX sections
- [x] VimStatusLine: ● CAP (capture indicator), ● REC N (recording with track count)
- [x] Rust: all warnings fixed, unused variables resolved
- [x] Rust: `cargo build` clean (0 warnings)
- [x] TypeScript: `tsc --noEmit` clean
- [x] Vite build passes
- [x] 17 E2E tests all pass (~20s)

### E2E Testing Infrastructure
- `tauri-plugin-playwright` (0.4.1) behind `e2e-testing` Cargo feature
- `@srsholmes/tauri-playwright` (0.4.1) with Playwright test runner
- 17 browser-only tests: transport, arm/solo/mute, keyboard, command palette, meters, capture
- `npm run test:e2e` — fast browser mode (no Tauri needed)
- `npm run test:e2e:tauri` — full desktop (requires e2e-testing feature + `playwright:default` cap)
- For Tauri e2e: add `"playwright:default"` to `capabilities/default.json` before `cargo tauri dev --features e2e-testing`

---

## Phase F — Device & Channel Selection (PipeWire/JACK)

### Goals
- Device list that shows real inputs on PipeWire (not ALSA plugin pseudo-devices)
- Per-track input channel selection (`IN n`), like Ardour's track "Inputs" menu
- Cooperative capture while PipeWire/Ardour hold the hardware
- True mono per-track WAVs (deinterleaved), no interleaved-in-mono bug

### Status
- [x] `jack` crate: enumerate PipeWire inputs as JACK clients with capture ports
      (`Scarlett 4i4 USB Analog Surround 5.1:capture_FL`, ...); default source resolved via `pactl`
- [x] `jack::start` connects `tracker:in_N` to the selected device's ports (RT-safe process callback into the same ringbuf)
- [x] Fallbacks: PipeWire ALSA sources via `pactl` + `PIPEWIRE_NODE` + `BufferSize::Fixed(1024)`; then raw `plughw` hardware cards
- [x] Engine: per-track channel write (deinterleave); true mono WAVs per armed track
- [x] Engine: `input_peaks`/`input_rms` arrays stream every channel
- [x] React: per-track `IN n` selector (defaults 1,2,3,4), sidebar LIVE LEVELS for all channels
- [x] Verified with 4i4 + Ardour running: 6 live channels, 3s record → 3.01s mono WAVs, track 1 = mic (-41 dB), track 2 = silent
- [x] `npm run typecheck` clean; 18/18 browser E2E tests pass

### Reference
- Ardour device list: `libs/ardouralsautil/devicelist.cc` (`get_alsa_audio_device_names`) — enumerate cards, probe capture PCMs
- Ardour track inputs: `gtk2_ardour/io_selector.cc` — `IOSelector`/`PortMatrix` patch grid over input ports

---

## Notes

- Primary audio backend on Linux/PipeWire: pipewire-jack (cooperative, same model as Ardour); cpal (ALSA) as fallback and for other platforms
- Three-thread model: React UI / Audio Control Thread / Audio RT Callback (cpal or JACK)
- ringbuf for lock-free sample transfer between threads
- crossbeam::bounded for commands to audio thread
- std::sync::atomic for real-time-safe parameter sharing
- Tauri events (`level-update`, `metrics-update`) for frontend streaming
- `tauri-plugin-playwright` for desktop E2E testing with Playwright API
