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
make e2e                   # 14 headless vinland-ui window cases
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
