# tracker-odin

Native rewrite of Tracker in [Odin](https://odin-lang.org/). The original
Tauri + React app remains at the repository root as the behavioral reference;
nothing here modifies or deletes it.

**Status: phase 1 vertical slice.** Real device capture, 32-bit float WAV I/O,
the track/master signal chain, and an offline mixdown all work and are tested.
The native graphical shell does not exist yet — see [ROADMAP.md](ROADMAP.md).

## Why Odin

The motivation is iteration speed. Measured on this machine (Ryzen, 16 threads):

| step | time |
|---|---|
| full `odin build` of this project (audio + DSP + CLI) | **0.46 s** |
| `odin run` hello-world equivalent | 0.39 s |
| Tauri/Rust dev rebuild | minutes |

Odin compiles the whole program every time, but the whole program is small and
the compiler is fast. No Node dev server, no webview, no IPC boundary, no
waiting on `cargo` to finish linking a Tauri binary before you can hear a
change.

## Quick start

Requires Linux, Odin `dev-2026-11a` (or newer) and LLVM, plus ALSA/PipeWire
headers for miniaudio.

```sh
# 1. Toolchain (once)
curl -sL -o /tmp/odin.tar.gz \
  https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz
mkdir -p ~/.local/opt ~/.local/bin
tar xzf /tmp/odin.tar.gz -C ~/.local/opt
mv ~/.local/opt/odin-linux-amd64-* ~/.local/opt/odin
ln -sf ~/.local/opt/odin/odin ~/.local/bin/odin

# 2. Build miniaudio's static library (once)
export ODIN_ROOT="$HOME/.local/opt/odin"
sh "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"

# 3. This project
cd odin
make build          # -> bin/tracker-odin
make test           # 28 tests
make check          # tests + offline end-to-end verification
```

`scripts/check.sh --hardware` additionally records two seconds from the default
capture device and renders the result.

## CLI

```sh
# What can I record from?
./bin/tracker-odin devices

# Record two hardware channels into per-track float WAVs.
./bin/tracker-odin record --seconds 8 --channels 2 --out ~/Music/session

# Generate a reference tone without hardware.
./bin/tracker-odin tone --out /tmp/tone.wav --seconds 3 --freq 440

# Mix tracks through EQ -> compressor -> fader/pan -> master comp -> limiter.
./bin/tracker-odin render --in ~/Music/session --out ~/Music/session/bounce.wav \
  --level 0.9 --eq-low 3 --eq-mid -2 --comp-threshold -20

# Inspect format, peak and RMS.
./bin/tracker-odin info ~/Music/session/bounce.wav

# Offline proof that the chain works: render two tones, assert the ceiling.
./bin/tracker-odin selftest
```

`render` accepts either a directory containing `track1.wav` … `track16.wav`
or a single WAV file. Multi-channel inputs are downmixed to mono per track.

## Tests and verification

```sh
odin test src/dsp                  # 23 DSP tests
odin test src -extra-linker-flags:"-lm -ldl -lpthread"   # 5 WAV tests
./scripts/check.sh                 # everything above + CLI E2E + sox/ffprobe
```

Coverage mirrors the Rust suite where the code has been ported:

- biquad response at centre/edges, shelf targets, flat transparency, noise stability
- compressor quiet passthrough, loud reduction, monotonic transfer curve, auto makeup
- limiter ceiling over 10 s of 4× overdriven sine, lookahead delay, bypass
- EQ pass-through and per-band response
- constant-power pan, mute, limiter-capped hot mix, stereo shape/length
- WAV float roundtrip, header layout, 16-bit PCM import, garbage rejection
- hardware capture (manual: `record`, then `info`)

Independent validation: `ffprobe` reports `pcm_f32le`, `sox` reads the files
without warnings, and `sox ... stat` agrees with the engine's peak/RMS report.

## Layout

```
odin/
  src/
    main.odin       CLI, argument parsing, selftest
    capture.odin    miniaudio device enumeration + capture
    wav.odin        WAV read/write (float32 out, PCM in)
    dsp/
      util.odin     dB math, smoothing, soft clip
      biquad.odin   RBJ biquad (peaking / low shelf / high shelf)
      eq.odin       3-band channel EQ
      compressor.odin  stereo-linked soft-knee compressor
      limiter.odin  lookahead limiter + soft clip
      render.odin   track chains, pan, master chain, GR timelines
  scripts/
    check.sh        offline end-to-end verification
  ROADMAP.md        what is done, what is missing, next phases
```

Correspondence with the Rust reference:

| Rust | Odin |
|---|---|
| `audio/fx/biquad.rs` | `dsp/biquad.odin` |
| `audio/fx/eq.rs` | `dsp/eq.odin` |
| `audio/fx/compressor.rs` | `dsp/compressor.odin` |
| `audio/fx/limiter.rs` | `dsp/limiter.odin` |
| `audio/fx/render.rs` (partial) | `dsp/render.odin` |
| `audio/device.rs` + `engine.rs` (capture) | `capture.odin` |
| `hound` WAV writer | `wav.odin` |

## Notes and limitations

- Capture uses miniaudio's PulseAudio backend, which works through PipeWire on
  this machine. It enumerates the same JACK/PipeWire sources as the Rust
  engine, but it is not yet a cooperative JACK client.
- The capture callback locks a mutex and copies into a preallocated buffer.
  That is fine for a bounded CLI take; the real-time monitor path needs a
  lock-free ring before it can run alongside a UI.
- Reverb, delay, the widener and the post-fader sends are **not** ported yet.
  `--flat` is a true bypass; the default chain is EQ + compressor + limiter.
- No project files, no native UI, no transport/playback yet.
- Sample rates must match across tracks in one render; resampling is phase 2.
