# Odin port roadmap

Status board for the native rewrite. The Tauri/React implementation at the
repository root is the reference and stays untouched.

Legend: **done** = implemented and verified in this tree; **missing** = exists
in the reference but not here; **new** = only relevant to the native app.

## Phase 1 — audio core vertical slice (done)

| area | status | verification |
|---|---|---|
| Odin toolchain + vendored miniaudio | done | `dev-2026-11a`; static lib build script |
| Device enumeration | done | 8 PipeWire sources on the test machine |
| Hardware capture | done | 96,000 frames from a 2 s take through the native UI |
| Per-channel float WAVs | done | `record`, `trackN.wav`, ffprobe + sox clean |
| Biquad / EQ / compressor / limiter | done | parity vectors + 62 DSP tests |
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
| Cooperative JACK capture | done | CLI `record --jack`; 28,800 frames verified |
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
| Theme | done | DESIGN.md palette, mono bitmap type, flat panels |
| Keyboard model | done | Space/R/1–4/j/k/J/K/m/s/a/i/x/c/[/]/:/Esc |
| Screenshot + interaction tests | done | 56-action tour, 9 PNGs, JSON report |

## Phase 4 — hardening and audit (in progress)

| item | status | notes |
|---|---|---|
| A/B DSP parity with Rust | done | ported algorithms tested against reference vectors |
| WAV compatibility | done | IEEE-float 18-byte fmt body, PCM 16/24/32 import |
| Cross-process UI test harness | done | `ui-test`, semantic targets, assertions |
| Packaging | done | desktop entry, icon, `install-desktop.sh` |
| CI entry point | done | `scripts/check.sh` |
| Memory/leak audit | in progress | test runner reports leaks; project loader cleaned |
| Device hotplug / unplug mid-take | missing | no retry path yet |
| Latency compensation | missing | overdub alignment is approximate |
| Live input monitoring | missing | deliberately not passed through (feedback-safe) |
| Undo/redo | missing | new to the native app |
| Native file picker / recent projects | missing | fixed `--session` path |
| RF64 / >4 GB files | missing | 32-bit RIFF size field |
| Screen-reader/accessibility audit | missing | software canvas has no a11y tree |
| JACK capture in the GUI | missing | CLI only; GUI uses miniaudio |
| Multi-take comping | missing | not in the original scope |

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
- The UI is CPU-rendered at 1180×760; larger windows cost more per frame.
- Project strings from JSON are cloned into the app and freed on reload; a
  future schema change must preserve that ownership rule.
- The Rust app remains the oracle until the final parity audit is signed off.
