# Read-only audit — 2026-11-22

Five independent reviews of the native app and vinland-ui at commit `d39946d`
(Tracker-FX) and `357c115` (vinland-ui). The reviewers changed no code. This
directory preserves their reports; the changes that came out of the audit are
listed at the end.

| report | scope |
|---|---|
| `design.md` | Impeccable-style visual/UX review of the shipped window and the Cairo harness; screenshots were generated under `/tmp/opencode/audit-design/` and are not committed |
| `performance.md` | Startup, frame cost, harness throughput, offline render/WAV/resample, memory and idle measurements with repro commands |
| `vinland-control.md` | Focus/pointer safety of `vui-ctl`, control-server state handling, and the source of the "mouse steal" report |
| `flow.md` | End-to-end flow audit of the CLI, Cairo tour, native e2e and hidden-window interactions |
| `code.md` | Correctness/security review of the engine, DSP, WAV/RF64, persistence and cloud paths |

These are point-in-time reports, not a changelog. Several recommendations remain
open on purpose (native UI re-proportioning, compressor/resampler rewrites,
asynchronous mixdown, WAV streaming, design-token consolidation); use the
reports as a backlog, then re-measure before claiming a number.

## What this audit changed

- vinland-ui: synthetic input is now separated from real buttons/modifiers, the
  cursor/IME side effects of synthetic gestures are gated on real focus/pointer
  state, and `VUI_BACKGROUND=1` + `vui-ctl foreground`/`background`/`release`
  provide explicit no-focus vs escape-hatch modes. `vui-test` now owns the
  sandbox environment (`VUI_HIDDEN`, `SDL_VIDEO_DRIVER`, display variables).
- Tracker-FX: `make ui-bg`, the background-input workflow, and the X11/Xvfb proof
  script are documented in `AGENTS.md`, `odin/README.md`, `odin/VERIFICATION.md`
  and the Vinland/Herdr skills.
- Data safety from `code.md`/`flow.md`: guarded master take cycling
  (crash), project-rate adoption on load, occupied-folder refusal for Save As,
  take finalization + project save on close/stop/selection, corrupt-project
  quarantine with take recovery, atomic RIFF/PCM WAV writes, `bounce` requiring
  `--session`, and Ctrl/Alt chords no longer firing Vim letter actions.
- Offline perf: constant-power pan gains are hoisted out of the render loop and
  PNG screenshots use zlib level 3 (same pixels, less encode time). The larger
  items in `performance.md` (compressor dB conversions, synchronous mixdown,
  WAV streaming, resampler) are untouched.
