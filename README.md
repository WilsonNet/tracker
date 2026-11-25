# Tracker-FX — Multitrack Recorder

A minimal multitrack audio recorder for the desktop. No timeline, no grid — just arm, level, record, listen.

Native [Odin](https://odin-lang.org/) application for **Linux and macOS**, drawn with the sibling
[vinland-ui](https://github.com/WilsonNet/vinland-ui) toolkit (SDL3 GPU Metal/Vulkan, OpenGL 3.3
fallback). Keyboard-first and Vim-native, inspired by the Zoom R4 MultiTrak.

![Tracker-FX with the FX rack open](docs/screenshot-app.png)

## Features

- **4-track recording, up to 24 tracks** — four strips by default (tape-deck
  layout); `N`/`D` add or delete tracks, `{ }` zoom how many show, `( )` page
- **Bounce marked tracks to a track** — `v` marks, `V` opens the target dialog;
  sources stay, the target gets a new mono take
- **Track names** — `R` or double-click a strip name; saved with the project and Drive backups
- **Contextual key help** — `F1` lists only the keys that work where you are
- **Multi-take recording and comping** — stable take files, active-take cycling, comp regions
- **Overdub** — hear the existing mix while recording the next part
- **Native effects** — 3-band EQ and compressor per track, shared FDN reverb and
  ping-pong delay sends, master compressor, widener and lookahead limiter
- **Bounce / render** — write the canonical project `bounce.wav` and drop the mix on a dedicated `BOUNCE` track (Zoom R4 style), or `RENDER…` the current mix to an external WAV with a dual-handle time range and 32-bit float / 24-bit / 16-bit format, including reverb tails
- **Live metering** — peak/RMS per track plus compressor gain reduction
- **Keyboard-first** — Vim navigation, `1`–`4` arm, `Space` play/stop, `R` record,
  `x` FX rack, `,` settings, `:` command palette
- **Project persistence** — atomic `project.json`, recent projects, undo/redo,
  native open/save dialogs
- **Google Drive transfer** — back up a self-contained project and restore it
  on another computer; visible, named Drive folder, `drive.file` scope only,
  no remote delete
- **Settings** — choose the project folder, input backend, latency and
  monitoring, plus high contrast and reduced motion; folder and accessibility
  choices persist in `settings.json`. Text fields have a real caret and
  selection: click/drag/shift-click, double-click a word, triple-click all,
  clipboard and undo, with secrets rendered as `*`
- **HiDPI and responsive density** — crisp type at 1×–3×; the native window uses SDL density and a flexible layout, while the headless harness and `ui-shot` scale the whole virtual frame for larger canvases
- **Cross-platform audio** — CoreAudio on macOS, PipeWire/ALSA and cooperative JACK (`--jack`) on Linux

## Quick start

The app lives in [`odin/`](odin/). You need Odin `dev-2026-11a` or newer, the
sibling vinland-ui checkout, and the system libraries listed in
[`odin/README.md`](odin/README.md#dependencies).

```sh
# vinland-ui must be checked out next to this repo
git clone https://github.com/WilsonNet/vinland-ui ../vinland-ui

cd odin
make build        # -> bin/tracker-fx
make test         # 300 unit tests (Linux) / 294 unit tests (macOS)
make check        # tests + headless UI tour + offline bounce

./bin/tracker-fx ui              # real window
./bin/tracker-fx ui --demo       # synthetic meters, no audio hardware
```

Sessions default to `$XDG_DATA_HOME/tracker-fx/session` (usually
`~/.local/share/tracker-fx/session`); press `,` and choose a
project folder to change it (persisted in `~/.config/tracker-fx/settings.json`),
or pass `--session DIR` for an isolated run that ignores saved settings.
For Google Drive transfer, follow [docs/cloud-setup.md](docs/cloud-setup.md)
(includes the new-machine restore path).
`make install` installs the binary, icons and desktop entry under `~/.local`.

## Verification

```sh
cd odin
make test          # DSP + engine/project/WAV + UI unit tests
make e2e           # 18 headless vinland-ui cases (tests/ui/window.vt)
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

- [`PLATFORMS.md`](PLATFORMS.md) — Linux / macOS matrix, OS module isolation map, cross-OS verification handoff
- [`odin/README.md`](odin/README.md) — build, CLI, make targets, native UI, verification
- [`odin/ROADMAP.md`](odin/ROADMAP.md) — completion record and intentional limits
- [`odin/VERIFICATION.md`](odin/VERIFICATION.md) — test and measurement matrix
- [`docs/RESEARCH.md`](docs/RESEARCH.md) — Zoom R4 MultiTrak analysis
- [`docs/fx-research.md`](docs/fx-research.md) — effects architecture research

## Implementation

Tracker-FX is a single native binary in [`odin/src/`](odin/src): the window is
SDL3 GPU (Metal/Vulkan, OpenGL fallback) through vinland-ui, audio runs through miniaudio (CoreAudio / PipeWire / ALSA) or
a cooperative JACK client on Linux, and the DSP is plain Odin. There is no webview, no
JavaScript runtime and no IPC boundary.

## License

MIT
