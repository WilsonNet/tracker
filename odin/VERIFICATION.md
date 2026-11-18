# Verification matrix

Recorded on the development machine (Arch Linux, PipeWire 1.6.11, Odin
`dev-2026-11-nightly`), 2026-11-17/18.

## Build and unit tests

| check | command | result |
|---|---|---|
| clean build | `make clean && make build` | 0.68 s, 1 binary |
| DSP tests | `odin test src/dsp` | 70 passed |
| engine/project/WAV | `odin test src` | 56 passed |
| RF64 | `odin test src` | ds64 parse/reject, fmt/data chunk-order variants, RIFF boundary + >4 GB arithmetic, streaming roundtrip |
| UI state/layout/PNG | `odin test src/ui` | 38 passed |
| vet | `odin check src -no-entry-point -vet` | clean |
| packaging | `PREFIX=/tmp/tracker-install ./scripts/install-desktop.sh` | binary + icon + desktop entry |

Total: **164 unit tests**.

## Native UI harness (Playwright replacement)

`./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui`

- **118 actions, 0 failures**
- 10 PNG screenshots at 900×620, 1180×760 and 1920×1080
- assertions cover arm/mute/solo, record/play/stop, fader/pan drag, FX tabs,
  knobs, bypass, ping-pong, palette filtering/execution, bounce, I/O selection,
  tempo/click, resize, and final state

## Real audio

| check | result |
|---|---|
| miniaudio capture (default source) | 96,000 frames / 2.000 s, short 0 |
| native UI record (default source) | 100,352 frames / 2.091 s, peak **−6.02 dBFS** with loopback |
| JACK capture (`record --jack`) | 24,000 frames / 0.500 s, short 0 |
| loopback capture (known 440 Hz, 0.5 amplitude) | peak **−6.02 dBFS**, RMS −9.13, exact 2.000 s |
| long loopback capture | 480,000 frames / **10.000 s**, exact |
| mic input (phantom on, input 1) | peak ≈ −43 dBFS (quiet room) |
| 10 s loopback capture | 480,000 frames / 10.000 s, exact |
| 5 s UI take | 239,616 frames / 4.992 s, overflow 0 |
| final UI take (post-audit engine) | 191,488 frames / 3.989 s + bounce + project.json |
| overdub | existing mix plays while track 2 records; both takes written |
| bounce from native UI | `bounce.wav`, stereo float, limiter ceiling respected |
| project save/reload | `project.json` + `track1.wav`; TAKE restored after relaunch |
| UI loopback recording | track 1 peak **−6.02 dBFS**, master −7.9 dBFS on screen |
| text rendering | baked 12.5px/25px anti-aliased mono atlas, descenders/baseline tests |
| Hyprland window rule | class `tracker`, workspace `special:tracker`, silent, no focus steal |
| mixed-rate session | 44.1 kHz track → 48 kHz bounce |
| project-driven reverb send | 2 s take → 7.50 s bounce with tail |
| DSP audit | limiter latency, short-take stats, NaN recovery, reverb buffers fixed |
| WAV compatibility | `ffprobe` = `pcm_f32le`; `sox` header warnings absent |

The loopback test is reproducible with:

```sh
./scripts/check.sh --loopback
```

It creates a PulseAudio null sink, plays a known 0.5-amplitude 440 Hz tone,
records its monitor through `tracker-odin record`, and asserts the WAV peak is
−6.02 dBFS ±2 dB.

## Window-level tests

Driven through SDL2 under Xvfb with xdotool (X11 backend because the developer
session is Wayland):

- arm → record → stop → play → screenshot
- 10 s capture and overdub
- palette `: save`, `b save`, relaunch and reload
- keyboard-only path (`1`, `2`, `r`, `c`, `b`, `:`)

## Known gaps

See `ROADMAP.md` Phase 4: live input monitoring, latency compensation, native
file picker, undo/redo, a11y tree, JACK GUI mode, hotplug. These are explicitly
out of scope for the current port; everything else on the roadmap is
implemented and exercised above. RF64 is implemented and covered by the WAV
suite; the engine still buffers a take before writing it.
