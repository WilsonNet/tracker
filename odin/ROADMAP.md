# Native completion record

All phases are implemented in this native Odin tree. There is no legacy frontend
or external toolchain required to build, test or run the app.

Verification: `odin/VERIFICATION.md`, `odin/PERF.md`, and
`./scripts/check.sh --hardware --jack --loopback`.

## Core engine

| item | status | evidence |
|---|---|---|
| DSP parity (biquad, EQ, compressor, limiter) | done | 70 DSP tests, A/B vectors |
| FDN reverb, ping-pong delay, widener, sends | done | impulse/timing/mono tests |
| Master chain, limiter latency compensation | done | short-take and tail tests |
| Lock-free capture ring + writer thread | done | writer drains while recording, overflow reporting |
| Multi-channel capture to per-track float WAV | done | 2 s and 10 s captures exact |
| Preview playback and overdub | done | live window checks |
| Live input monitoring | done | duplex callback, engine API + MON toggle |
| Latency compensation | done | manual `--latency-ms` / I/O ±, take trim test |
| Device hotplug/unplug recovery | done | notification flag, safe split, fallback + rescan |
| Cooperative JACK capture (CLI + GUI) | done | async `/tmp` session, 1.0 s live take |
| Metronome with BPM 40–240 | done | playback callback click |

## Data and persistence

| item | status | evidence |
|---|---|---|
| Project JSON with defaults and strict validation | done | malformed/null/partial/version tests |
| Atomic save + path traversal protection | done | project tests |
| Recent-project list (`XDG_CONFIG_HOME`) | done | save/load + overlay |
| Native open / save-as dialogs | done | zenity with kdialog fallback |
| Mixed-rate resampling | done | 44.1↔48 kHz sessions |
| RF64 reader/writer + streaming writer | done | synthetic RF64, ffprobe/sox |
| Multi-take recording and active take | done | stable `trackN-takeM.wav`, project round-trip |
| Comp regions + comp renderer | done | equal-power joins, CLI `comp` |
| Whole-take comping in UI | done | palette “comp active take” |
| Latency/a11y settings persisted | done | project fields + `settings.json` |
| Settings overlay: project folder, audio, a11y, cloud | done | `vui-ctl`, settings tests, 17-case e2e |
| Folder picker starts with sibling projects visible | done | `dialog_start_dir` unit test |
| Text fields: caret, selection, click/drag/double/triple, clipboard, undo | done | native `vui-ctl` geometry + 4 UI tests + e2e case |
| Google Drive backup/restore (`drive.file`, visible named folder) | done | live Google round-trip, innocent-file guard, fake-Drive no-delete tests |
| Restore collision safety | done | `-2` local folder, delete+restore, duplicate marked-name guard |

## Native UI

| item | status | evidence |
|---|---|---|
| vinland-ui window (SDL3, Vulkan/GL), DESIGN.md palette | done | Hyprland, `vui-ctl` screenshots |
| SDL2 window, software canvas | replaced | superseded by vinland-ui |
| 4 track strips, master, meters, GR | done | 220-action tour |
| Arm preview: live input meter + history before REC | done | `vui-ctl` screenshots, preview tests |
| Reference density + design-token layers | done | `theme.odin`, geometry tests at 900/1180/1920 |
| Headless responsive zoom / virtual frame | done | `ui_zoom_for_window`, 1.0–1.8x, 70 UI tests; native window uses SDL density + flexible layout |
| Cairo/Pango harness + vinland canvas charts | done | AA paths, Inter, level history, FX graphs |
| Transport, timecode, BPM, click, monitor | done | tour |
| FX rack (track + master) | done | knobs, bypass, ping-pong, focus |
| Command palette, recents, recent overlay | done | 220-action tour |
| I/O panel: device list, JACK, latency, rescan | done | tour + live JACK take |
| Bounce overlay and status | done | engine bounce |
| Undo/redo | done | 64-entry history, tests |
| Accessibility: keyboard-first, high contrast, reduced motion | done | tests + `--a11y-log` |
| HiDPI 1×/1.25×/1.5×/2×/3× | done | SDL density in the window; stb_truetype atlases in the harness |
| Window class `tracker` for compositor rules | done | `hyprctl clients`; optional scratchpad rule |

## Headless UI test harness

| item | status | evidence |
|---|---|---|
| Semantic click/drag/key/type/assert/screenshot actions | done | `src/ui_harness.odin` |
| Full tour | done | **220 actions, 17 PNGs, 0 failures** |
| Scale runs | done | 1× and 2× full tours |
| Failure reports | done | `report.json` + non-zero exit |

## Verification matrix

| check | result |
|---|---|
| unit tests | **265** (70 DSP, 125 core/engine/project/cloud, 70 UI) |
| UI e2e | 17 headless vinland-ui cases |
| UI tour | 220 actions, 17 screenshots |
| clean build | ~0.8 s |
| hardware capture | 96,000 frames / 2.000 s |
| loopback known tone | −6.02 dBFS, exact |
| long loopback | 480,000 frames / 10.000 s |
| JACK CLI | 24,000 frames / 0.500 s |
| JACK GUI | 57,344 frames / 1.195 s |
| multi-take + comp | 2 takes, region 0–48,000 → 1.0 s comp bounce |
| HiDPI | 2360×1520 at 2×, 3540×2280 at 3× |
| packaging | desktop entry, PNG/SVG icon, install/uninstall |

## Intentional limitations

- Latency compensation is a manual trim; there is no automatic round-trip
  calibration.
- Live monitoring is a duplex software path at fixed −6 dB, not hardware
  zero-latency monitoring; long overdubs can drift.
- Accessibility is keyboard-first with high-contrast/reduced-motion and a
  textual `--a11y-log` snapshot; there is no AT-SPI tree.
- JACK GUI takes accumulate in RAM until stop (~384 MB/hour stereo).
- The engine still buffers a take while splitting it; RF64 streaming exists but
  is not used end-to-end for a single take.
- Comping has whole-take UI plus arbitrary-region CLI; there is no waveform or
  timeline region editor by product design (`PRODUCT.md`: no timeline).
