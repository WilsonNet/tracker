# Flow audit — 2026-11-22

Read-only audit at commit `d39946d`. Windows used `VUI_HIDDEN=1` and isolated
XDG dirs. Full artifacts (screenshots, trees, logs, throwaway sessions) were
under `/tmp/opencode/audit-flow-573890/` and are not committed.

## Side effect disclosed

Running `./bin/tracker-odin bounce` without `--session` overwrote the real
`~/.local/share/tracker/session/bounce.wav`. This report is also a source for
the CLI safeguard added in the closeout commit. No takes or `project.json` were
touched.

## P0 — quitting during REC could replace the previous take

`engine_destroy` cleared take metadata before `engine_record_stop`, so the split
could not stabilize the old canonical WAV. Closing during a take replaced
`track1.wav` with the partial new capture while `project.json` still pointed at
the old take. Fixed by finalizing an open take before dropping take lists and by
stopping/saving at window close; see `engine.odin` and `ui_window.odin`.

## P1 — broken/dangerous flows

- A malformed `project.json` opened as an empty project; an explicit Save then
  overwrote it. Fixed by quarantining the unreadable file as
  `project.json.corrupt-<pid>` and recovering canonical takes.
- `bounce` without `--session` wrote the default session silently. Fixed:
  `bounce` now requires `--session`.
- Command palette selection could move below the visible 10 hard-coded rows;
  Enter ran an off-screen command. Still open (`view_palette` row cap).
- Native strips under-use their height; no per-track GR readout. Still open;
  see `design.md`.
- `--demo` synthetic meters are overwritten by real capture peaks during REC.
  Still open.
- Settings → Cloud is below the fold at 1180×760/900×620; `OPEN SETTINGS` from
  the Cloud overlay does not scroll to the cloud section. Still open.
- COMP has no persistent take-row indicator or visible clear action. Still open.
- Missing take files are shown as a normal `TAKE 1/1`/`EMPTY`; bounce says only
  “no tracks in session”. Still open.
- `record` defaults to a relative `./session` when `--out` is omitted. Still
  open.

## Verified working

- Cairo tour 220/220 (1× and 2×), 17 PNGs.
- Native e2e 18/18, `unknown_classes: []`, frame_ms 3.2–8.2.
- CLI: selftest, devices, tone/info/render, bounce, comp list/select/add/clear,
  malformed projects, missing files, read-only sessions, numeric/size errors,
  paths with spaces.
- Native window: arm/solo/mute/input, REC gating, record/stop, multi-take,
  t/T cycling, save/load/save-as with a fake zenity, settings edit/apply/restart,
  credential masking/space rejection, cloud overlay, I/O, render dialog with
  real 24-bit output, 900×620 and 1920×1080, idle to ~3.4 ms.
- Hardware signal quality was not evaluated: captured inputs were silent.
