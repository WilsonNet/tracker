# Verification matrix

Recorded on the development machine (Arch Linux, PipeWire 1.6.11, Odin
`dev-2026-11-nightly`), 2026-11-17/18.

## Build and unit tests

| check | command | result |
|---|---|---|
| clean build | `make clean && make build` | 0.68 s, 1 binary |
| DSP tests | `odin test src/dsp` | 62 passed |
| engine/project/WAV | `odin test src` | 11 passed |
| UI state/layout/PNG | `odin test src/ui` | 11 passed |
| vet | `odin check src -no-entry-point -vet` | clean |
| packaging | `PREFIX=/tmp/tracker-install ./scripts/install-desktop.sh` | binary + icon + desktop entry |

Total: **84 unit tests**.

## Native UI harness (Playwright replacement)

`./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui`

- **56 actions, 0 failures**
- 9 PNG screenshots at 1180×760 and 900×620
- assertions cover arm/mute/solo, record/play/stop, fader/pan drag, FX tabs,
  knobs, bypass, ping-pong, palette filtering/execution, bounce, I/O selection,
  tempo/click, resize, and final state

## Real audio

| check | result |
|---|---|
| miniaudio capture (default source) | 96,000 frames / 2.000 s, short 0 |
| JACK capture (`record --jack`) | 24,000 frames / 0.500 s, short 0 |
| loopback capture (known 440 Hz, 0.5 amplitude) | peak **−6.02 dBFS**, RMS −9.13, exact 2.000 s |
| long loopback capture | 480,000 frames / **10.000 s**, exact |
| mic input (phantom on, input 1) | signal present, peak ≈ −52 dBFS (quiet source) |
| 5 s UI take after writer fix | 239,616 frames / 4.992 s, overflow 0 |
| overdub | existing mix plays while track 2 records; both takes written |
| bounce from native UI | `bounce.wav`, stereo float, limiter ceiling respected |
| project save/reload | `project.json` + `track1.wav`; TAKE restored after relaunch |
| mixed-rate session | 44.1 kHz track → 48 kHz bounce |
| project-driven reverb send | 2 s take → 7.50 s bounce with tail |
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
file picker, undo/redo, RF64, a11y tree, JACK GUI mode, hotplug. These are
explicitly out of scope for the current port; everything else on the roadmap is
implemented and exercised above.
