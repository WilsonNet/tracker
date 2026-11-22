# Code review — 2026-11-22

Read-only review at commit `d39946d`; scratch repros lived in
`/tmp/opencode/audit-code/`. The root-package tests passed there.

## P0

- `engine_take_cycle` indexed `e.takes[track]` with no bounds guard. Selecting
  Master (`MAX_TRACKS`) and pressing `t` panicked; `.Comp_Clear` also indexed
  `e.takes[cmd.index]` after the guarded clear returned false. Fixed with guards
  and a regression test.

## P1

- Save As copied takes into an existing Tracker folder, overwriting its audio.
  Fixed: `engine_save_as_to` refuses an occupied destination; regression test.
- Startup and palette Load did not copy the project sample rate into the
  engine, so 44.1 kHz projects mixed/exported at 48 kHz. Fixed in
  `engine_load_tracks` (single authoritative path); regression test.
- JACK lifecycle: `engine_destroy` discarded an open JACK take; `rec.active`
  never covered JACK, so guide-end/Already_Running could make it unstoppable.
  Close-time finalization is now ordered before take-list teardown; the full
  JACK state-machine fix remains open.
- Take metadata was not saved on stop, take selection or close. Fixed with
  `window_save_project` calls and a stop-then-save close path.
- Per-track WAV write failure could be reported as a successful take, and a
  direct write could truncate the previous canonical file. RIFF/PCM writes now
  go through `write_file_atomic`; per-track failure reporting remains open.
- Comp-active-take truncation and native-rate length mismatch; delay tails cut
  at 2 s; cloud upload order (project.json before takes); world-readable cloud
  temp header dump; JACK unbounded sample rate; wheel undo missing; input
  channels 5–8 unwired; Ctrl chords triggering Vim letters; corrupt
  `project.json` recovery; 64-take cap; invalid saved saveDir blocking startup;
  cloud worker/UI races. Some were fixed in closeout; the rest are open.

## P2/P3 highlights

Truncated WAV data accepted silently; OAuth HTML not escaped and error branch
before state check; Drive query backslash escaping; palette not fully modal;
cloud draft dirty flag global; WAV sample-rate cap; test leaks; no
server-loss/destroy-during-JACK test; no occupied-folder/partial-comp tests.

## Verified sound

WAV header/offset/endian/24-bit/malformed-chunk handling (apart from truncation
tolerance), RF64 `ds64` arithmetic, capture ring and writer lifecycle, project
strictness/traversal/atomic save, comp region math, cloud PKCE/state/no-DELETE/
marker scoping/duplicate guards/restore collisions, limiter lookahead/latency,
NaN sanitization, biquad extremes, widener mono trim, resampler bounds, reverb
sizing, caret/UTF-8/masking/clipboard, and settings discard guards.
