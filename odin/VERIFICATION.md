# Verification matrix

Measured on the development machine (Arch Linux, PipeWire 1.6.11, Odin
`dev-2026-11-nightly`), 2026-11-17/18. The port is complete; details and
intentional limits are in `ROADMAP.md`.

## Build and unit tests

| check | command | result |
|---|---|---|
| clean build | `make clean && make build` | ≈0.8 s |
| DSP | `odin test src/dsp` | **70 passed** |
| engine / project / WAV / RF64 / takes / CLI | `odin test src` | **85 passed** |
| UI state, layout, HiDPI, responsive zoom, PNG | `odin test src/ui` | **57 passed** |
| static checks | `odin check src -no-entry-point -vet` | clean |
| packaging | `PREFIX=/tmp/tracker ./scripts/install-desktop.sh` | binary, PNG+SVG, desktop entry |

Total: **212 unit tests**.

## Native UI harness

`./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui`

- **220 actions, 0 failures**
- **17 PNG screenshots** at 900×620, 1180×760, 1920×1080; layout geometry asserted at all three sizes
- Full tour also passes at `--scale 2` (physical 2360×1520)
- Covers arm/mute/solo, record/play/stop, faders/pans, FX tabs/knobs/bypass,
  palette, recents, bounce, I/O, tempo/click, monitor, JACK toggle, latency,
  rescan, undo/redo, keyboard focus, resizes
- Window-responsive zoom verified at 1440x900 (1.20x), 1920x1080 (1.52x),
  2536x986 (1.59x) and 3840x2160 (1.80x cap); the virtual frame never drops
  below 900x620

## Real audio

| check | result |
|---|---|
| miniaudio capture (default source) | 96,000 frames / 2.000 s |
| native UI capture (loopback tone) | 100,352 frames, **−6.02 dBFS** |
| loopback known tone | **−6.02 dBFS**, RMS −9.13, exact 2.000 s |
| long loopback | 480,000 frames / **10.000 s** |
| JACK CLI | 24,000 frames / 0.500 s |
| JACK GUI (`ui --jack`) | 57,344 frames / 1.195 s |
| live monitor + latency + 2 takes | duplex monitor, track1-take1 + canonical, T1/2 |
| comp region | 2 takes, region [0, 48000) → 1.000 s comp bounce |
| bounce | stereo float, limiter ceiling held |
| project save/reload | takes, active take, latency and a11y flags restored |
| recent projects | `/tmp/tracker-feature/project.json` persisted and reopened |
| HiDPI | 1180×760, 1770×1140, 2360×1520, 3540×2280 screenshots |

A real 2-second take through the native window and a 4-second take followed by
bounce/project save were both verified with xdotool on Xvfb.

The loopback test is reproducible with:

```sh
./scripts/check.sh --loopback
```

## Design tokens

`src/ui/theme.odin` keeps raw palette → semantic colour roles → space/type/
metric scales → theme bundle. Widgets read `ACTIVE_TOKENS.color.*`; layout reads
`METRICS`/`SPACE`. The reference palette is asserted by the UI contrast test, and
the high-contrast theme changes colour only.

## Accessibility

- `ui --a11y-log` prints `app_describe()` on every state revision: mode,
  transport, selection, per-track arm/mute/solo/takes/level/pan/peak, tempo,
  monitor/latency/backend, contrast/motion flags, undo depth and status.
- High-contrast and reduced-motion modes are keyboard/palette accessible and
  persisted in `project.json`.
- No AT-SPI tree; the textual log is the screen-reader surface.

## Packaging

`make install` and `make uninstall` are idempotent. The desktop entry uses
`Name=Tracker (Odin)`, `StartupWMClass=tracker`, quoted `Exec`, PNG and SVG
icons. The window class matches the existing silent `special:tracker` rule.

## Sources consulted

The implementation follows the project research rule in `AGENTS.md`; the
significant sources are recorded in the README (SDL2 high-DPI, stb_truetype,
RF64/EBU, JACK, XDG, Odin core/vendor).
