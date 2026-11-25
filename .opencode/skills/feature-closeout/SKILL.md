---
name: Feature Closeout
description: Use at the end of any feature, behavior change, or bug fix in this repository, before telling the user it is done — prove the working surface, then record durable lessons in AGENTS.md, odin/README.md, odin/ROADMAP.md, odin/VERIFICATION.md, and the relevant .opencode/skills so the next agent starts where you finished.
---

# Feature closeout

A feature is not finished when it builds. It is finished when the next agent can
find the behavior, the command that proves it, the trap you hit, and what is
intentionally not supported.

Run this after every feature-sized change. For a typo or comment-only edit, skip
the documentation step only when no durable fact changed.

## 1. Prove the surface

Run the narrowest check first, then the broadest one the change can affect.

```sh
cd odin
make build                 # must be green (the vui.init stack warning is known)
make test-dsp              # DSP only
make test-core             # engine / project / WAV / CLI
make test-ui               # UI state, layout, HiDPI, PNG
make test                  # all 274 (Linux) / 268 (macOS) unit tests (counts live in README/VERIFICATION)
make e2e                   # 20 headless vinland-ui window cases
make check                 # tests + 220-action UI tour + offline bounce + format checks
```

For UI work, follow the vinland-ui skill and additionally:

```sh
VUI_HIDDEN=1 VUI_PORT=7421 ./bin/tracker-odin ui --session /tmp/closeout &
vui-ctl --port 7421 info
vui-ctl --port 7421 click-text "ARM"
vui-ctl --port 7421 screenshot /tmp/opencode/closeout.png
vui-ctl --port 7421 quit
```

Read the PNG back. Check `unknown_classes`, `frame_ms` and, when the change
involves meters, that the window idles again after the live state ends. Do not
claim a UI works from a passing command alone.

**Every UI change must be validated with `vui-ctl` against the offscreen
window.** `ui-shot`/Cairo PNGs and green unit tests are supporting evidence,
not proof of the real window. Click and type through the actual flow, inspect
`info`, and add the flow to `tests/ui/window.vt` when it is repeatable.

For settings/persistence work, use isolated XDG dirs and no `--session` so the
saved values are actually exercised:

```sh
XDG_DATA_HOME=/tmp/opencode/closeout/data \
XDG_CONFIG_HOME=/tmp/opencode/closeout/config \
VUI_HIDDEN=1 VUI_PORT=7421 ./bin/tracker-odin ui &
vui-ctl --port 7421 type ","
vui-ctl --port 7421 key down
vui-ctl --port 7421 key enter
vui-ctl --port 7421 screenshot /tmp/opencode/settings.png
```

Then inspect `config/tracker/settings.json` and restart the app to prove the
value is loaded, not just written.

Evidence that needs hardware (input capture, JACK, loopback) goes in
`odin/VERIFICATION.md`, not just in the chat.

## 2. Extract the durable lessons

Answer these before editing docs:

- What new state, thread, device, or ownership did I add?
- What must be started, stopped, drained, or released, and in what order?
- Which API required a non-obvious call shape (contextless callback, allocator,
  atomic, event ordering)?
- What fails silently if the caller gets it wrong?
- What did I verify with real hardware, with `--demo`, or only with unit tests?
- What did I deliberately not implement?
- Which existing claim, count, path, or command did this change invalidate?

Record reusable facts and exact commands. Do not paste a changelog.

## 3. Put each lesson in the right file

| Lesson | Goes in |
|---|---|
| Durable agent rule, architecture, command, gotcha, skill pointer | `AGENTS.md` |
| User-facing behavior, CLI, build, make targets | `odin/README.md` |
| Status row and evidence link | `odin/ROADMAP.md` |
| Measured result, hardware/loopback evidence, test counts | `odin/VERIFICATION.md` |
| App run/readiness/workspace workflow | `.opencode/skills/herdr/SKILL.md` |
| Reusable UI workflow (upstream) | `vinland-ui/skills/vinland-ui/SKILL.md` (symlinked at `.opencode/skills/vinland-ui`; do not edit it from this repo) |
| A workflow future agents must repeat | the relevant skill, or a new one under `.opencode/skills/<id>/SKILL.md` |

Rules for durable docs:

- Update in place; do not duplicate one rule across three files.
- Behavior goes in the README; proof goes in ROADMAP/VERIFICATION; operating
  rules go in AGENTS.md and skills.
- Include exact paths and commands, and say whether hardware is required.
- State limitations explicitly ("JACK meters during the take", not "JACK
  works").
- Delete or correct stale claims when behavior changes.
- Refresh test counts and file paths in the same edit.

## 4. Extend this skill when the workflow changes

If closeout itself needed a new step, add it here. If a feature reveals a new
class of trap, add it under "Durable lessons" below with the date and evidence.

## 5. Verify and report

```sh
git status --short
git diff --stat
```

Re-run the narrowest check if code changed after the last run. In the final
message state:

1. What changed and where.
2. The exact command(s) that prove it and the observed result.
3. Which docs/skills were updated.
4. Known limits or follow-ups.

## Durable lessons

### Arm preview (2026-11-21)

- Arming a stopped track opens a capture-only preview in `engine.odin`; it
  publishes per-channel peaks and writes no take file. The input meter and
  history graph are live before REC.
- Lifecycle: stop preview before `engine_record_start`; restart it after
  STOP; stop it during playback, recording, demo mode and backend changes;
  decay unarmed tracks and let `view_busy` go false so the window idles.
- `preview_callback` is `proc "c"`, so the slice-building helper must be
  `proc "contextless"` (Odin otherwise asks for a context in the callback).
- Validation: `vui-ctl` arm → graph and meter live, REC/STOP returns to
  preview, unarm decays and idles. Unit tests cover the envelope, the
  wanted-state matrix and the signature that avoids retrying a failed open.
- Limit: JACK uses its take session; arm preview is miniaudio/PipeWire only.

### Settings overlay (2026-11-21)

- Settings are machine-local in `settings.json` (`saveDir`, `highContrast`,
  `reducedMotion`); project/audio mix settings stay in `project.json`. Apply
  the global a11y values after loading a project when a settings file exists.
- Changing the project folder uses the save-as path: copy takes, write
  `project.json`, retarget, then persist. Refuse a folder that already has
  `project.json` or `track1..4.wav`; the old folder remains as a recovery copy.
- An explicit `--session` is a sandbox: do not load global settings, and write
  any settings **and cloud** changes beside the session. Tests and throwaway
  takes must not touch the user's real config. `ui/e2e` saves credentials, so
  `cloud.json` must follow the session path or the test suite corrupts the
  user's Google client.
- Long-lived path strings must use `fmt.aprintf`, not `fmt.tprintf`: the
  temporary allocator invalidated the settings store between frames and produced
  a garbage `.tmp` path plus "cannot save settings".
- vui-ctl synthetic Enter can activate a vinland-focused button *and* reach
  `app_key`, closing the panel. Clear `vui.focus(0)` when entering Settings and
  use a non-focusable box for the path field.
- The overlay is keyboard-complete: `j/k` or arrows select rows, `Enter` edits
  the folder or runs the row, `b/a/r` jump to storage actions, `Esc` cancels an
  edit or closes. Add new settings to `Settings_Item`, `app_settings_activate`,
  `view_settings` and the selection test together.
- Validation: `vui-ctl` open → select → edit path → apply → inspect
  `project.json`/`settings.json` → toggle contrast → restart → 900×620 →
  idle. Keep the 17-case `make e2e` suite green.

### Clipboard and edit mode (2026-11-22)

- SDL key events are consumed by Tracker, so `vui.text_input` never sees
  `Ctrl+V`. Handle paste in `window_on_event` (real keys) **and**
  `window_synthetic_keys` (vui-ctl) through `vapp.clipboard_read` and
  `ui.app_paste_text`.
- `SDL_GetClipboardText` can return non-nil but empty on Wayland. vinland-ui
  now falls back to `wl-paste`, `xclip` and `xsel`; clone SDL's buffer before
  `SDL_free` or the field fills with freed memory.
- Text fields enter EDIT on click; `Enter` applies, `Esc` asks once before
  discarding, second `Esc` cancels. The `EDIT` chip and status hint must match
  that state. Clicking another field or `Tab`/`Shift+Tab` switches inputs and
  preserves drafts; the form stays in EDIT until save/cancel.
- `Ctrl+A` is select-all; the next type/paste/backspace replaces the buffer.
  Backspace deletes a whole UTF-8 rune. Credential fields reject spaces and
  secrets render as `*` while editing, not plaintext.
- Regression tests: unit tests for cloud/project/palette/recent paste and the
  two-step escape; upstream `clipboard_from_argv` test.

### Text fields: caret, selection, drag (2026-11-22)

- Model the field as a caret plus anchor in byte offsets. Render the selection
  as an absolute amber box and the caret as an absolute 2 px bar inside a
  `relative overflow-hidden` parent; set `absolute` in the element class at
  creation, not only on `last_style`, or vinland never assigns a containing
  block and the element lays out at 0×0.
- Measure with `vui.caret_stops` using the same `font_family`/`font_size`/
  `font_weight` as the text. A zero weight resolves to faces with zero advance,
  so every click lands at offset 0.
- Click maps x→nearest caret stop; drag keeps the press anchor; Shift+click
  extends; double-click selects a word and triple-click selects all. The
  multi-click selection must lock drag updates until release: the button-up
  arrives a frame later and would otherwise turn the word/all selection into a
  drag to the click point.
- Keyboard: arrows/Home/End, Shift variants, Ctrl+arrow/Backspace/Delete,
  Ctrl+A/C/X/V/Z/Y and Shift+Insert/Shift+Delete/Ctrl+Insert. Coalesce a typed
  run into one undo step; paste and cut are their own steps.
- Synthetic vui-ctl keys bypass `window_on_event` and still reach vinland's
  focus traversal. Clear `vui.focus(0)` before each frame while a text field is
  editing, or Tab focuses BROWSE and a later synthetic Enter opens a blocking
  native folder dialog.
- Secrets stay masked through selection and save; assert the plaintext is
  absent from `vui-ctl tree`. e2e must pass an explicit `--session`, and the
  window must store `cloud.json` beside that session, never in the user's real
  `~/.config/tracker`.
- Hovering an input must change the OS cursor: put `cursor-text` on the field
  row and its clipped value container. Blink the caret with a hard on/off
  timer (`ctx.animating = true`) instead of `animate-pulse`; omit the caret
  node in the off phase so screenshots cannot catch a half-faded bar.
- Do not baseline screenshots containing live hardware enumeration. Device
  lists reorder between PipeWire restarts; assert their text instead.
- Project folders live side by side. `BROWSE…` must start in `parent_dir(current
  project)`, not inside the current project; `dialog_start_dir` is unit-tested
  so the parent, root and empty-folder cases stay correct.
- **`defer` is block-scoped in Odin.** Never write `defer delete(x)` inside an
  `if`/`for` block and then use `x` after the block: it frees `x` immediately.
  This silently corrupted the curl body-file argument and the existing
  `index.json` update ID. Declare the `defer` in the function scope or after the
  block, and regression-test uploads/repeat backups, not just first uploads.

### Google Drive transfer (2026-11-22)

- Scope is exactly `drive.file`; do not widen it to full Drive. Storage is a
  visible My Drive folder whose name is user-configurable (`cloud.json`).
- Every created file/folder carries `appProperties.tracker=1`; every lookup,
  list and restore filter uses that marker. This protects same-named files even
  inside the Tracker folder.
- There is **no remote DELETE**. Do not add one without a separate product and
  safety review. Deleting the Drive folder is the user-facing deletion path.
- Restore accepts single ordinary filenames only (`/`, `\`, NUL, `.` and `..`
  rejected), writes to a fresh `.partial-*` sibling, and never removes an
  existing local folder. The finish step must not call `os.remove_all(final)`.
- The only local deletes are generated temp files and the job's own partial
  folder. Long-lived strings use `fmt.aprintf`, not `tprintf`.
- OAuth is loopback + PKCE with a `state` check. The refresh token lives in
  `cloud.json` (0600). Testing-mode tokens expire weekly; detect
  `invalid_grant`, clear the token and prompt reconnect.
- Test with the fake Drive server (`tests/cloud/fake_drive.py`): it seeds an
  unrelated same-named file, records DELETE calls, and verifies the full
  backup/restore round-trip. A live Google account run is still required for
  consent and quota behavior.

### External mix render (2026-11-22)

- The main row has BOUNCE (canonical `bounce.wav`) and `RENDER…` (`B`,
  `.Render_Mix`). Render reuses `engine_render_mix`, writes stereo float via
  `wav_write`, and must not touch takes or `bounce.wav`; refuse while recording.
- Adding a `Command_Kind` is not local: update `command_name`, the palette
  table, the key handler, `App.execute`, and the button in the same change or
  the build fails on an unhandled switch.
- Native save dialogs are testable with a fake `zenity` on `PATH` that records
  argv and prints a path; assert the title, start folder and `.wav` filter, then
  inspect the file with `ffprobe`/`soxi`.
- Screenshots with a live device list are unstable; the render baselines are
  fine because they only gained a button.
- The render panel is pure App state: FROM/TO seconds, a format enum, a
  selected row and a drag handle. The window supplies the measured mix length
  after `.Render_Mix`; Enter emits `.Render_File`, which is where the save
  dialog and engine call live. Keeping those phases separate makes the dialog
  fully unit-testable and keeps `ui-shot` engine-free.
- The dual-handle track is a `vui.canvas`; do hit-testing and drag against the
  same `Rect` used to paint it. Press starts the drag from
  `ctx.input.pressed`, motion follows `ctx.input.buttons`, and release clears
  the drag. Store the grab offset in the model so a handle does not snap to the
  pointer. Draw the active handle last so overlapping ends still leave the
  selected grip on top. Canvas focus is separate from the App's `render_sel`;
  `j/k` must keep working without a pointer.
- Integer PCM is written at the file boundary only; the engine, FX chain and
  range slicing stay f32. Test 16/24-bit with `wav_read` plus `ffprobe`/`soxi`.

### Audit fixes (2026-11-22)

- `engine_load_tracks` owns the project-rate handoff: every caller (startup,
  palette Load, open-project) gets `e.sample_rate` from `a.sample_rate`. Do not
  load takes before syncing the rate or 44.1 kHz projects silently mix at 48 k.
- Finalize an open take before clearing take lists. `engine_destroy` stops the
  take first; window close stops/syncs/saves, and take stop/selection call
  `window_save_project`. This prevents the old canonical WAV being replaced
  while `project.json` still points at it.
- `engine_save_as_to` refuses an occupied destination (`project.json` or
  `trackN.wav`); Save As must not merge two sessions.
- A malformed `project.json` is renamed to `project.json.corrupt-<pid>` and the
  canonical takes are recovered. Do not silently open an empty project and let
  the next save overwrite the original.
- Swallow Ctrl/Alt/Super chords outside text editing. `app_key` only sees the
  character, so without the guard Ctrl+S toggles Solo, Ctrl+R records, etc.
- RIFF/PCM WAV writes go through `write_file_atomic`; a failed write must not
  truncate the previous take/bounce.
- `bounce` requires `--session`; it must never silently overwrite the default
  session's `bounce.wav`.

### Window visibility (2026-11-21)

- A Hyprland `workspace = "special:tracker silent"` rule made every `tracker`
  window invisible. The rule is now an opt-in commented block in
  `~/.config/hypr/hyprland.lua`; normal launches open on the active workspace.
- Before debugging "no window", check `hyprctl clients` for the class and
  workspace, then the window rules — not the renderer logs.
- The app is `tracker-odin`; `tracker` is not a command.

### Background driving without stealing input (2026-11-22)

- `vui-ctl` input is synthetic and in-process; it never warps/clicks the OS
  pointer. For a visible run that must not disturb the user, start the app with
  `VUI_BACKGROUND=1` (or `make ui-bg`). The window is created with
  `SDL_WINDOW_NOT_FOCUSABLE` and `SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN=0`; X11
  window managers honor the hint, but Wayland has no togglable focus flag, so
  the compositor still decides. `VUI_HIDDEN=1` is the only hard
  no-desktop-contact guarantee; a compositor no-focus rule is the visible-Wayland
  option.
- Guard the SDL side effects, not just the input events: `SDL_ShowCursor` /
  `SDL_SetCursor` on X11 apply to every window in the process, and
  `SDL_StartTextInput` is only valid for a focused window. Gate them on real
  pointer/focus state and skip while the last pointer event was synthetic;
  otherwise a script can leave the app's cursor hidden or start IME on a window
  the user never focused.
- `vui-ctl foreground` is the explicit escape hatch for native dialogs, IME or
  human takeover; `vui-ctl background` returns. Wayland may refuse to make an
  existing surface focusable (`SDL_SetWindowFocusable` fails for non-popup
  windows); report the failure and restart without `VUI_BACKGROUND=1` rather
  than pretending it worked.
- Proven by `vinland-ui/scripts/check-background.sh` under Xvfb + openbox:
  pointer position unchanged across `vui-ctl click-text`, `info` reports
  `background:true`/`focusable:false`, and the foreground/background toggle
  round-trips. Tracker e2e (18) and showroom e2e (6) stay green.

### macOS port & cross-OS `#+build` isolation (2026-11-23)

- Keep OS differences out of shared files by splitting into `_linux.odin` (`#+build linux`), `_darwin.odin` (`#+build darwin`), and `_other.odin` (`#+build !linux` and `#+build !darwin` on **separate** lines — Odin rejects `!linux !darwin` on one line).
- On non-Linux, the headless `ui-shot`/`ui-test` harness runs on a pure-Odin software rasterizer + embedded `vendor:stb/truetype` (`ScaleForMappingEmToPixels` matches Pango 72 dpi em-height sizing cleanly inside `ui_canvas_text_rasterises_at_physical_size`), removing Cairo/Pango as build dependencies on macOS.
- `tests/ui/window.vt` uses `threshold 0.005` because the header I/O pill and status bar display the live hardware device name (e.g. `"Scarlett 4i4 USB"` on CoreAudio vs `"Scarlett 4i4 USB Analog Surround 5.1"` on PipeWire), which shifts ~0.32% of pixels in the header/status bar while leaving every widget pixel-identical.
- Update `PLATFORMS.md` whenever editing OS-specific files you cannot test locally on the other OS.

### Repo cleanup (2026-11-21)

- After removing a retired frontend or toolchain, stale references hide in
  desktop entries, project skills, README commands and doc paths. `git grep`
  for the old framework names, source directories and build commands after a
  removal.
- The Odin test counts are part of the docs contract; update every count when
  adding tests.

### Project titling & headless dialog suppression (2026-11-23)

- `text_field_view` + `text_edit.odin` can drive both Settings form fields and inline Normal-mode status-bar editing cleanly once `text_active` / `app_text_editing` / `window_synthetic_keys` / `ui_window.odin` redraw checks share the same predicate.
- Package-global fake-server endpoints in `cloud_fake_test.odin` (`cloud_api_base`, `cloud_upload_base`) must be serialized with a mutex because `odin test` runs package tests across multiple threads.
- Gate native OS file/folder pickers (`file_dialog_{linux,darwin}.odin`) on `VUI_HIDDEN=1` returning `"", false` so headless automation never pops OS dialogs onto the desktop.
- In `tests/ui/window.vt`, give `view_settings` scroll-into-view `wait 15` before clicking a newly revealed row (`Client ID`) so `vui`'s animated `scroll_to` finishes moving the target rect before `click-text`.

### Tape scrubber & palette capacity (2026-11-23)

- `PALETTE_COMMANDS` uses a fixed backing capacity `MAX_PALETTE` in `ui/app.odin`; whenever new palette entries push `len(PALETTE_COMMANDS)` higher, bump `MAX_PALETTE` in the same change (`ui_palette_query_case_backspace_and_rows` enforces `a.palette_count == len(PALETTE_COMMANDS)`).
- In `tests/ui/window.vt`, `vui-test`'s `scroll` command takes numeric window coordinates (`scroll <dy> <x> <y> [mods]`), not a text locator, whereas `Shift+scroll` on macOS swaps `wheel.y` to `wheel.x` in SDL3 — handle both axes in wheel-hover widgets.

### Variable track count, bounce-to-track, F1 help (2026-11-23)

- `ui.MAX_TRACKS` (24) is capacity **and** the master's index for `App.selected`
  and `App.fx_channel`; `App.track_count` is the live count. Never index the
  master as `track_count`, and never loop `0 ..< MAX_TRACKS` for anything the
  user sees: use `track_count` (describe, layout, arm-all, project save).
- Anything that hard-codes four tracks hides in file lists, not UI: Save As,
  the folder-occupied check and Google Drive backup all looped `1 ..= 4`.
  `grep -n '1 ..= 4\|track1..4'` after any capacity change.
- vinland `ui.div` has a deferred close, so it cannot sit in `a && ui.div(...)`;
  toggle with a `hidden` class or a nested `if`.
- Palette growth needs `MAX_PALETTE` (now 64) in the same change.
- F1 is `Key.F1` handled first in `app_key`; the help sheet swallows every other
  key and any click, so it works over text edits without losing the draft.
### Transport, marker, pre-roll, punch-in (2026-11-24)

- `ui_sync_takes` runs **every frame**; anything it calls must tolerate a live
  recording (the playhead may legitimately pass the old tape end).
- Recording from the playhead = guide cursor at `punch - pre`, capture dropped by
  `latency + pre` frames, take registered with `offset = punch`, then
  `comp_punch` builds before/new/after regions. Single-take loading ignores
  `offset`, so a take with an offset must always be reachable through a comp.
- `ui` flags a `Command_Kind` addition in `command_name`, the palette table and
  `command_hint` at compile time; adding a `Settings_Item` shifts every
  keyboard-walk step in `tests/ui/window.vt` (the Client ID test counts `key down`).
- `ui --demo` with an armed track and `r` still opens the real capture device;
  use a throwaway `--session` and press Space to stop. Never `pkill -f
  "tracker-odin ui"` from a shell whose own command line contains that text.
- e2e cannot assert PLAY→PAUSE: without an output device `engine_play` fails and
  the transport force-stops. Cover pause in unit tests.
- Counts now: 303 Linux / 297 macOS unit tests, 28 e2e cases.

### macOS CoreAudio capture selection & cross-OS device names (2026-11-24)

- Upstream `ma_context_enumerate_devices__coreaudio` sets `info.isDefault = MA_TRUE` for the default playback device and does not reset `info` before emitting the capture entry for the same hardware, flagging multiple capture devices as default. `capture_find_default_index` resolves multi-flagged lists via `ma.context_get_device_info(ctx, .capture, &infos[i].id, &detail)`.
- PipeWire device names include profile suffixes (`"Scarlett 4i4 USB Analog Surround 5.1"`) that CoreAudio omits (`"Scarlett 4i4 USB"`). `engine_resolve_device_index_ex` falls back from exact match to a unique word-boundary prefix match (`device_name_prefix_match`, ignoring `"Monitor of ..."`), and `engine_match_device` / `engine_sync_ui_device` keep `e.device_index`, `a.device_index`, and `a.device` in sync across startup, `--open`/Open/Cloud-restore (`engine_open_project`), preview, and record start (toasting on fallback).
- `capture_config_unmixed` sets `cfg.capture.channelMixMode = .simple` so falling back from native width `0` to an explicit channel count drops extra hardware channels instead of spatially downmixing them.
- When verifying with `VUI_HIDDEN=1`, pick an unused `VUI_PORT` and poll `vui-ctl info` rather than grepping stdout for `"vui: control server"` (which also matches `"could not listen ... (Address_In_Use)"`).

### Musical Grid mode & Free tape mode (2026-11-24)

- `Playback.cursor` is signed `i64` so Bar-1 count-in can start at negative frames (`-pre` before frame 0) while keeping `playback_prepare`'s explicit `has_start: bool` flag instead of a `-1` sentinel.
- `playback_click_step` is `proc "contextless"` inside the `"c"` audio callback, computing exact `f64` beat boundaries from `pos` (`click_absolute = true` anchored to frame 0 in Grid, `pos - click_origin` in Free) with zero cumulative drift across non-integer BPMs and an atomic `seek_gen` counter for lock-free seek resync.
- Grid scrubbing snaps magnetically to bar/beat/1/4-beat boundaries (`floor(g + eps) + 1` forward, `ceil(g - eps) - 1` backward) while preserving `Ctrl|Alt + Jog` (`10 ms`) as a micro escape hatch; drag gestures accumulate pointer travel in `View.scrub_accum` (`18 px` detents) so dragging feels stepped like hardware.
- Adding `Timing_Mode` and `Time_Sig` to `Settings_Item` before `Preroll` shifts keyboard-walk `key down` counts in `tests/ui/window.vt` by +2; remember to free any new string field (`timing_mode`) in both `project_load_doc_free` and `settings_destroy`.
- Counts now: 306 Linux / 300 macOS unit tests, 29 e2e cases.

### Inline delete take (2026-11-24)

- `engine_take_active` returns the take **id** (`take.id`), whereas the take row displays `take_active/take_count`; use `engine_take_active_ordinal` (1-based position in `list.takes`) in `ui_sync_takes` so deleting Take 1 of `[1, 2]` renders `1/1` instead of `2/1`.
- `app_execute` defaults `index: int = 0`; route take-row `DEL` clicks straight to `app_take_delete_arm(a, i)` (and keyboard `Ctrl+Delete` / `Cmd+Delete` or palette `.Take_Delete` through `a.selected`) so track selection never snaps back to track 0. Also keep re-arming (`a.take_del_track == idx`) non-confirming and require `y`/`Enter`/click `DELETE` so rapid double-presses never delete accidentally.
- Avoid `"NO"` or short substring matches when driving `vui-ctl click-text` if `"NORMAL"` is on screen (`click-text` matches substrings case-insensitively, so `"NO"` hits `"NORMAL"` in the header).
- Counts now: 315 Linux / 309 macOS unit tests, 30 e2e cases.

### Clean new project & unified Settings PROJECT section (2026-11-24)

- Keep `Settings_Item` enum order identical to `view_settings` top-to-bottom layout; adding `.New_Project`, `.Open_Project`, `.Recent_Projects` before `.Project_Name` shifts `window.vt` `key down` walks by +3.
- `engine_new_project` saves the outgoing project (when dirty, existing, or holding audio) before clearing `Engine.loaded` and `Engine.takes`, creates a unique sibling `<parent>/<slug>[-N]` folder, resets per-project UI/mix/FX/marker state via `ui.app_reset_project`, and preserves machine preferences (`device`, `latency_ms`, `timing_mode`, `preroll`, `high_contrast`, `reduced_motion`, `cloud_*`, `recent_*`).
- `ui_window.odin` isolates `recent_store` (`<session_dir>/recent.json`) when `session_given` is true, matching `settings.json` and `cloud.json`, so e2e tests (`create a new clean project from settings`) never pollute `~/.config/tracker/recent.json`.
- Counts now: 318 Linux / 312 macOS unit tests, 31 e2e cases.

### Unbounded metronome, tape-first overwrite & opt-in takes (2026-11-24)

- `Playback.frames` governs track-audio bounds (`pos < i64(p.frames)`), not metronome lifetime: keep `Playback.unbounded = unbounded || !have_audio` (and pass `unbounded = true` from `engine_record_start`) so `playback_callback` keeps advancing `p.cursor` past existing takes and `engine_seek` does not clamp to `p.frames - 1`.
- Recording overwrites the active take WAV atomically (`<file>.tmp` → rename) via `tape_splice_overwrite` with a short crossfade (~4 ms) on overlapping punch-in/punch-out edges; multi-take creation is opt-in via `engine_take_new` (`+ TAKE` / `+`, `Ctrl+t` / `Cmd+t`, `: new take`), which archives `track{N}.wav` to `track{N}-take{ID}.wav` before opening an empty slot.
- `window_synthetic_keys` clears `ctx.input.keys_pressed = {}` and `ctx.input.text = ""` right after routing synthetic `vui-ctl` / `vui-test` keys so a previously clicked `vui.button` cannot also fire `Enter`/`Space` inside `vinland` on the same frame. Always use `whitespace-nowrap` on strip counters (`2/2`) and hide secondary badges (`TAKE` word, `COMP` when `!t.has_audio`) in `multi` rows so 4 strips at `900×620` never clip `DEL`.
- `vui.Key` upstream in `vinland-ui` exposes `.A, .C, .V, .X, .Z, .Y, .K, .Slash, .F1, .F5, .F12` (not `.T`), so `window.vt` tests Ctrl+t via `: new take` while `ui_test.odin` and `window_on_event` cover the real SDL `Ctrl+t` / `Cmd+t` chord.
- Counts now: 321 Linux / 315 macOS unit tests, 31 e2e cases.

### Pre-roll song/click audio, section loop & auto punch-out (2026-11-25)

- `Settings_Item.Preroll_Audio` before `High_Contrast` shifts `key down` walks in `tests/ui/window.vt` by +1 (20 for Client ID, 18 for Drive folder); extend `view_settings` scroll-into-view to `.Timing_Mode`..`.Cloud_Restore` so keyboard navigation in Settings reaches `TIMING` toggles cleanly without scrolling off-screen.
- Keep `view_settings` helper copy free of button-label substrings (`"SONG"`, `"CLICK ONLY"`) because `vui-test`'s `expect-text` / `click-text` matches case-insensitive substrings; use `expect-exact` for short toggle labels and avoid asserting cross-OS shortcut prefixes directly (`"+Del"` / `"+t"` match both `Ctrl+` and `Cmd+`).
- During Song pre-roll (`preroll_active && preroll_audio`), pass `effective_mute_armed = false` to `live_mix_params_from_app` so the armed track's lead-in plays before `rec_punch`, then ramp down over the final 64 samples and zero `samples_in[i]` inside `playback_callback` right at `pos == preroll_until` for sample-accurate muting without cutting reverb/delay tails.
- Loop playback wraps `pos` inside `playback_callback` (`pos >= loop_end` → `loop_start`, resetting `has_last_beat` and triggering `fade_in_len` de-click) while recording intentionally ignores `loop_enabled`; auto punch-out waits for `rec_pre + (rec_punch_out - rec_punch) + latency_frames` written frames before stopping and trims `engine_split_take`/`engine_split_capture_result` to exact `rec_punch_out - rec_punch`.
- Counts now: 326 Linux / 320 macOS unit tests, 32 e2e cases.

### Audio-triggered Tempo Listen (2026-11-25)

- Reuse the existing `Preview` capture device (`preview_wanted` returns true when `a.tempo_listen && !e.headless_window`) instead of opening a second miniaudio capture stream, and gate `e.headless_window` off `window_should_warm_audio` so `VUI_HIDDEN=1` tests never stall opening hardware audio.
- Inside `preview_push` (`proc "contextless"`), run `dsp.tempo_detector_process` (420 Hz HPF + 30 ms warmup so an already-ringing guitar chord settles `env_slow` before arming + dual-envelope adaptive threshold + 210 ms refractory lockout + median-trimmed IOI estimator) and communicate purely via atomics; in `engine_update`, only treat `new_hit` as true when `seq != a.tempo_listen_audio_seq && hits > 0` so no-hit idle frames never overwrite manual `TAP BEAT` hits or `÷2`/`×2` scaling.
- Adding a `"tempo ..."` entry to `PALETTE_COMMANDS` breaks `ui_palette_query_case_backspace_and_rows` (which asserts `"TEMPO"` matches exactly 2 commands); name the palette command `"listen tempo (clap / guitar)"` so `"TEMPO"` stays 2 and `: listen` discovers it.
- Keep `app_history_reset` in mind when writing unit tests that mutate `a.bpm` before testing undo (`u`), and keep status-bar copy free of contextual-bar labels (`"tempo cancelled"`, not `"tempo listen cancelled"`) so `expect-no-text "TEMPO LISTEN"` tests don't match status text.
- Counts now: 336 Linux / 330 macOS unit tests, 33 e2e cases.
