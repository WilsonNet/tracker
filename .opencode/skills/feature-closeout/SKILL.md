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
make test                  # all unit tests (counts live in README/VERIFICATION)
make e2e                   # 16 headless vinland-ui window cases
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
  any settings changes beside the session. Tests and throwaway takes must not
  touch the user's real config.
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
  idle. Keep the 15-case `make e2e` suite green.

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
  that state. Another field cannot steal EDIT.
- `Ctrl+A` is select-all; the next type/paste/backspace replaces the buffer.
  Backspace deletes a whole UTF-8 rune. Credential fields reject spaces and
  secrets render as `*` while editing, not plaintext.
- Regression tests: unit tests for cloud/project/palette/recent paste and the
  two-step escape; upstream `clipboard_from_argv` test.

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

### Window visibility (2026-11-21)

- A Hyprland `workspace = "special:tracker silent"` rule made every `tracker`
  window invisible. The rule is now an opt-in commented block in
  `~/.config/hypr/hyprland.lua`; normal launches open on the active workspace.
- Before debugging "no window", check `hyprctl clients` for the class and
  workspace, then the window rules — not the renderer logs.
- The app is `tracker-odin`; `tracker` is not a command.

### Repo cleanup (2026-11-21)

- After removing the Tauri app, stale references hide in desktop entries,
  project skills, README commands and doc paths. `git grep` for `src-tauri`,
  `npm`, `cargo`, `vite` and `tauri` after a removal.
- The Odin test counts are part of the docs contract; update every count when
  adding tests.
