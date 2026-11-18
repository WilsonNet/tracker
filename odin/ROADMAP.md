# Odin port roadmap

Status board for the native rewrite. The Tauri/React implementation at the
repository root is the reference and stays untouched.

Legend: **done** = implemented and verified in this tree; **missing** = exists
in the reference but not here; **new** = only relevant to the native app.

## Phase 1 — audio core vertical slice (done)

| area | status | verification |
|---|---|---|
| Odin toolchain + vendored miniaudio | done | `dev-2026-11a`; static lib build script |
| Device enumeration | done | PipeWire/JACK sources listed on the test machine |
| Hardware capture | done | 96,000 frames from a 2 s take through the native UI |
| Per-channel float WAVs | done | `record`, `trackN.wav`, ffprobe + sox clean |
| Biquad / EQ / compressor / limiter | done | parity vectors + 70 DSP tests |
| Fader / pan / mute / master bus | done | render tests |
| CLI + selftest + check script | done | `make check` |

## Phase 2 — full engine parity (done)

| item | status | verification |
|---|---|---|
| Preview playback | done | miniaudio playback device; 1.024 s playhead observed live |
| Gated / streaming capture | done | lock-free ring + writer thread; no allocation in callback |
| Reverb (FDN) | done | ported, impulse/RT60/decorrelation tests |
| Ping-pong delay | done | fractional tap, feedback, lane-ordering tests |
| Mid/side widener | done | mono-sum, bass-mono, trim tests |
| Post-fader sends | done | render extends with a tail; reverb/delay buses |
| Master chain | done | comp → reverb/delay returns → widener → limiter |
| JSON settings | done | `project.json`, defaults for omitted fields |
| Project persistence | done | save/load round-trip test; palette + engine commands |
| Resampling | done | 32-tap windowed sinc; mixed-rate session render |
| Bounce | done | GUI + `bounce --session`, limiter ceiling held |
| Cooperative JACK capture | done | CLI `record --jack`; 24,000 frames verified |
| Device persistence | done | device name stored and matched on load |
| Overdub playback | done | existing mix plays while a new take records |
| Metronome | done | synth click in the playback callback, BPM 40–240 |

## Phase 3 — native shell (done)

| item | status | verification |
|---|---|---|
| SDL2 window + software canvas | done | renders on X11/Xvfb and Hyprland |
| Track strips | done | arm/solo/mute/input/pan/fader/meters/GR |
| Transport | done | REC/PLAY/STOP/BOUNCE, timecode, armed count |
| FX rack | done | 5 master / 3 track modules, knobs, bypass, ping-pong |
| Command palette | done | `:`, filter, arrow select, execute |
| I/O panel | done | live source list, selection, device persistence |
| Bounce UI | done | overlay + progress + status |
| Theme | done | DESIGN.md palette, baked anti-aliased mono atlas, flat panels |
| Keyboard model | done | Space/R/1–4/j/k/J/K/m/s/a/i/x/c/[/]/:/Esc |
| Screenshot + interaction tests | done | 118-action tour, 10 PNGs, JSON report |

## Phase 4 — hardening and audit (in progress)

| item | status | notes |
|---|---|---|
| A/B DSP parity with Rust | done | parity vectors; audit fixed limiter latency, stats, NaN state, reverb buffers |
| WAV compatibility | done | IEEE-float 18-byte fmt body, PCM 16/24/32 import |
| Headless UI test harness | done | `ui-test`, semantic targets, assertions |
| Packaging | done | desktop entry, PNG/SVG icon, `make install`/`uninstall` |
| CI entry point | done | `scripts/check.sh` (+ `--hardware`, `--jack`, `--loopback`) |
| Performance audit | done | `PERF.md`: render, UI, PNG, WAV, resampler benchmarks |
| Memory/leak audit | done | suites report 0 live bytes; temp arena reset per frame; harness strings owned |
| Device hotplug / unplug mid-take | done | miniaudio notification flag → `engine_update` stops/splits; name/default fallback on next take; `engine_rescan_devices` |
| Latency compensation | done | `Engine.latency_ms` / `engine_set_latency_ms`; split drops the first N frames (odd-rate tests) |
| Live input monitoring | done | opt-in duplex path, −6 dB safe gain, default off; `engine_monitor_start/stop` (UI wiring pending) |
| Undo/redo | missing | new to the native app |
| Native file picker / recent projects | missing | fixed `--session` path |
| RF64 / >4 GB files | done | RF64 reader (ds64, sentinel data size, chunk-order variants), auto RIFF→RF64 writer, streaming `Wav_Stream` writer; synthetic fixtures + >4 GB size arithmetic + roundtrip tests |
| Screen-reader/accessibility audit | missing | software canvas has no a11y tree |
| JACK capture in the GUI | missing | CLI only; GUI uses miniaudio |
| HiDPI (2×/3×) crisp scaling | missing | 1× atlas is exact; integer-scale layout + higher-DPI atlases or runtime stb_truetype |
| Multi-take comping | done (model) | `takes.odin`: per-track takes, ordered comp regions, equal-power render, session loading; engine/UI wiring pending |

## Exit criteria

- `scripts/check.sh` (and `--hardware`, `--jack`) green.
- A musician can arm, record, overdub, mix, bounce and reopen a project from
  the native window.
- UI harness reaches every control and overlay with assertions and PNGs.
- The remaining Phase 4 table above is either implemented or explicitly
  accepted as out of scope.

## Known risks

- miniaudio/PulseAudio capture and playback run on separate devices during
  overdub; timing drift is possible on long takes.
- The UI is CPU-rendered; 1180×760 runs comfortably, but 1920×1080 with the
  full FX rack is the slowest surface. Canvas fill was optimized post-audit.
- Preview render and bounce run synchronously on the UI thread (0.5–3.2 s per
  60 s of audio), so the window pauses during render for long mixes.
- Project strings from JSON are cloned into the app and freed on reload; a
  future schema change must preserve that ownership rule.
- The Rust app remains the oracle until the final parity audit is signed off.
