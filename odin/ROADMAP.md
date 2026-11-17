# Odin port roadmap

Status board for the native rewrite. The Tauri/React implementation at the
repository root is the reference and stays untouched.

Legend: **done** = implemented and verified in this tree; **missing** = exists
in the reference but not here; **new** = only relevant to the native app.

## Phase 1 — audio core vertical slice (done)

Acceptance: `./scripts/check.sh` passes; `record` produces playable float WAVs
from real hardware; `render` produces a stereo bounce whose peak never exceeds
the limiter ceiling.

| area | status | notes / verification |
|---|---|---|
| Odin toolchain + vendor miniaudio build | done | `dev-2026-11a`, `vendor/miniaudio/src/build_miniaudio.sh` |
| Device enumeration | done | `tracker-odin devices`; 8 capture devices on the test machine |
| Hardware capture | done | miniaudio/PulseAudio; 96,000 frames at 48 kHz in a 2 s take |
| Per-channel mono WAVs | done | `record` writes `trackN.wav`, 32-bit float |
| WAV writer | done | IEEE float, `fact` chunk, 18-byte fmt body; ffprobe + sox clean |
| WAV reader | done | float32, PCM 16/24/32; rejects malformed files |
| Biquad (RBJ) | done | peaking, low shelf, high shelf; response tests |
| 3-band EQ | done | 110 Hz shelf, bell, 7.5 kHz shelf; identical constants |
| Compressor | done | soft knee, auto makeup, stereo-linked detector |
| Limiter | done | lookahead, soft-clip ceiling; 10 s overdrive test |
| Fader / constant-power pan / mute | done | matches `render.rs` |
| Master bus | done | master comp -> limiter (reverb/delay/widener missing) |
| Gain-reduction timelines | done | 20 Hz, one series per track + master + limiter |
| CLI: devices/record/tone/render/info/selftest | done | `odin/src/main.odin` |
| Unit tests | done | 28 total: 23 DSP + 5 WAV |
| Offline E2E | done | `scripts/check.sh` synthesizes, renders, validates |
| Native GUI | missing | phase 3 |

## Phase 2 — full engine parity (next)

| item | status | acceptance |
|---|---|---|
| Playback / monitoring | missing | miniaudio playback device; `play` command; A/B against bounce |
| Reverb bus | missing | FDN reverb ported, RT60/decay tests, send level respected |
| Ping-pong delay bus | missing | delay timing/decorrelation tests |
| Mid/side widener | missing | mono-safe below crossover test |
| Post-fader sends | missing | tracks feed reverb/delay; dry/wet mix matches Rust |
| JSON settings | missing | load `FxSettings`-shaped JSON; defaults for omitted fields; roundtrip test |
| Project persistence | missing | save/load session directory (tracks + settings + take list) |
| Resampling | missing | mixed-rate input renders correctly; libsamplerate-equivalent quality check |
| Bounce command | missing | `bounce` writes `bounce.wav` through the full chain like the Rust command |
| Cooperative JACK capture | missing | appear as `tracker:in_N` ports; record while Ardour owns the device |
| Device hotplug / selection persistence | missing | selected device survives restart; missing device falls back cleanly |
| Real-time capture path | missing | lock-free ring instead of mutex; no allocation in callback |

Exit criteria for phase 2: the CLI can reproduce the Rust `bounce_tracks` and
`preview_mix` outputs sample-for-sample within float tolerance on the same
input, and all DSP tests exist in both implementations.

## Phase 3 — native shell

Toolkit decision is open. Candidates: raylib (fast to iterate, immediate mode),
sokol (small, explicit), or direct X11/Wayland + a custom immediate UI. The
audio core must stay decoupled from the shell.

| item | status | acceptance |
|---|---|---|
| Window + app loop | missing | opens on the Hyprland special workspace, no focus steal |
| Track strips + arm/mute/solo | missing | 4 tracks, keyboard-first, visual state matches model |
| Level meters | missing | 50 ms updates from capture; peak/RMS per channel |
| Transport | missing | record/play/stop, overdub, space/R/1-4 bindings |
| FX rack | missing | EQ sliders, comp knobs, sends, GR meters, bypass |
| Command palette + vim status line | missing | `:` palette, `x` rack, `[`/`]` channel cycle |
| Bounce UI | missing | progress + result; writes through the same Rust-equivalent chain |
| Theme | missing | DESIGN.md palette/type/motion translated to the native renderer |
| Screenshot / interaction tests | missing | automated visual + input tests for the native surface |

Exit criteria for phase 3: a musician can arm, record, overdub, mix and bounce
without touching the reference app.

## Phase 4 — hardening and parity audit

- A/B the Rust and Odin renders on real takes; document any intentional drift.
- Profile the capture and render paths; confirm no allocation in real-time code.
- Crash/edge cases: device unplugged mid-take, zero devices, full disk, 0-frame
  takes, absurd sample rates, mono/6-channel interfaces.
- Packaging: desktop entry, icon, install script, versioned binary.
- Decide whether the Tauri tree is archived, kept as a test oracle, or removed.
  Until then it stays as-is.

## Known gaps / risks

- miniaudio's PulseAudio backend is not JACK-cooperative. The Rust engine's
  main advantage on Linux is the JACK client path; phase 2 must close this.
- The Odin WAV writer is deliberately minimal. It does not yet support RF64,
  broadcast WAV metadata, or >4 GB files.
- The limiter is sample-for-sample ported, including its 20 Hz meter sampling;
  any future DSP change must be made in both implementations or the Rust one
  retired.
- No CI configuration yet. `scripts/check.sh` is the intended CI entry point.
- No sanitizer/valgrind pass on the Odin binary yet.
