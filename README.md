# Tracker — Multitrack Recorder

A minimal multitrack audio recorder for the desktop. No timeline, no grid — just arm, level, record, listen.

Native [Odin](https://odin-lang.org/) application, drawn with the sibling
[vinland-ui](https://github.com/WilsonNet/vinland-ui) toolkit (SDL3 + Vulkan, OpenGL
fallback). Keyboard-first and Vim-native, inspired by the Zoom R4 MultiTrak.

![Tracker with the FX rack open](docs/screenshot-app.png)

## Features

- **4-track recording** with true mono 32-bit float WAVs and RF64/BW64 support
- **Multi-take recording and comping** — stable take files, active-take cycling, comp regions
- **Overdub** — hear the existing mix while recording the next part
- **Native effects** — 3-band EQ and compressor per track, shared FDN reverb and
  ping-pong delay sends, master compressor, widener and lookahead limiter
- **Bounce** — render the full chain to a stereo float mixdown, with reverb tails
- **Live metering** — peak/RMS per track plus compressor gain reduction
- **Keyboard-first** — Vim navigation, `1`–`4` arm, `Space` play/stop, `R` record,
  `x` FX rack, `:` command palette
- **Project persistence** — atomic `project.json`, recent projects, undo/redo,
  native open/save dialogs
- **HiDPI and responsive density** — crisp type at 1×–3×, whole-panel zoom for larger windows
- **Linux audio** — PipeWire/ALSA capture and cooperative JACK capture (`--jack`)

## Quick start

The app lives in [`odin/`](odin/). You need Odin `dev-2026-11a` or newer, the
sibling vinland-ui checkout, and the system libraries listed in
[`odin/README.md`](odin/README.md#dependencies).

```sh
# vinland-ui must be checked out next to this repo
git clone https://github.com/WilsonNet/vinland-ui ../vinland-ui

cd odin
make build        # -> bin/tracker-odin
make test         # 219 unit tests
make check        # tests + native UI tour + offline bounce

./bin/tracker-odin ui              # real window
./bin/tracker-odin ui --demo       # synthetic meters, no audio hardware
```

Sessions default to `~/.local/share/tracker/session`; pass `--session DIR` to
use another directory. `make install` installs the binary, icons and desktop
entry under `~/.local`.

## Verification

```sh
cd odin
make test          # DSP + engine/project/WAV + UI unit tests
make e2e           # headless vinland-ui suite (tests/ui/window.vt)
make check         # unit + 220-action UI tour + offline bounce + format checks
```

`make check` needs `python3`; `ffprobe` and `sox` checks run when installed.
Hardware, loopback and JACK checks: `./scripts/check.sh --hardware --jack --loopback`.

## Layout

```
odin/          the native application (source, DSP, UI, tests, docs)
docs/          product research and design references
PRODUCT.md     product strategy
DESIGN.md      visual design system
```

- [`odin/README.md`](odin/README.md) — build, CLI, make targets, native UI, verification
- [`odin/ROADMAP.md`](odin/ROADMAP.md) — completion record and intentional limits
- [`odin/VERIFICATION.md`](odin/VERIFICATION.md) — test and measurement matrix
- [`docs/RESEARCH.md`](docs/RESEARCH.md) — Zoom R4 MultiTrak analysis
- [`docs/fx-research.md`](docs/fx-research.md) — effects architecture research

## History

The original Tauri (Rust) + React implementation was the behavioral reference
during the native port. It was removed once the port was complete and remains
in git history.

## License

MIT
