---
name: herdr
description: Use whenever running, restarting, inspecting, or stopping the Tracker app through herdr — "run the app", "check the logs", "kill it", "run it for me" — and for any herdr tab/pane work in this repo. Covers the dedicated-tab rule, readiness waits, the hidden app workspace, and cleanup.
---

# Herdr workflow in this repo

`herdr` is the terminal workspace the user and the agent share. The current tab
holds the user's conversation: **never split it to run the app**. A split
permanently steals width from their terminal and interrupts them mid-task.
App runs go in their **own tab**.

## Rule: one dedicated tab per app run

Verify the session first (the CLI refuses to guess which Herdr to control):

```bash
test "${HERDR_ENV:-}" = 1
```

Create a tab without focus (`--focus` would yank the user's view; don't pass it):

```bash
herdr tab create --cwd "$PWD" --label "tracker"
# → .result.tab.tab_id        e.g. w1:t2
# → .result.root_pane.pane_id e.g. w1:p7
```

`tab create` returns JSON. Read the IDs from the response instead of guessing.

Build first (no dev server, no watcher — a rebuild is a new run):

```bash
cd odin && make build        # ≈1 s
```

Run the app in the pane and wait for the control server:

```bash
herdr pane run <pane-id> "cd odin && VUI_PORT=7421 ./bin/tracker-odin ui"
herdr pane wait-output <pane-id> \
  --match 'vui: control server' \
  --source recent-unwrapped --timeout 120000
```

Read logs without disturbing anything:

```bash
herdr pane read <pane-id> --source recent-unwrapped --lines 80
```

Cleanup (closes the pane and kills the app):

```bash
herdr tab close <tab-id>
```

Leave the tab running only when the user asked to keep using the app; otherwise
close it. Never leave an orphaned instance.

## What to run

| Goal | Command | Ready when |
|---|---|---|
| Real app | `cd odin && VUI_PORT=7421 ./bin/tracker-odin ui` | `vui: control server on 127.0.0.1:7421` |
| Demo meters, no hardware | `cd odin && VUI_PORT=7421 ./bin/tracker-odin ui --demo` | same |
| Offscreen UI check | `cd odin && VUI_HIDDEN=1 VUI_PORT=7421 ./bin/tracker-odin ui --demo &` | same |
| Window E2E suite | `cd odin && make e2e` | `N passed, 0 failed` |
| Headless UI tour | `cd odin && make check` | `== PASS ==` |

Only one process can bind `VUI_PORT=7421`; a second instance logs a bind error.
Stop the old tab first or use another port.

Because there is no file watcher, after editing code rebuild and restart:
`herdr tab close <tab-id>` then create/run a fresh tab (or stop the pane process
and run again in the same tab).

## The app window

The window class is `tracker`. Normal launches open on the active workspace, so
you can screenshot the real window through `vui-ctl`. The persistent
`special:tracker` scratchpad and a **commented** `tracker-dev-workspace` rule
live in `~/.config/hypr/hyprland.lua`; uncomment that rule and `hyprctl reload`
to make dev runs silent again. Agents should verify offscreen with `VUI_HIDDEN=1`
rather than relying on the scratchpad.

To move a visible run to the scratchpad manually:

```bash
hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:tracker", follow = false, window = "class:^(tracker)$" })'
```

Show/hide it when the user asks:

```bash
hyprctl dispatch 'hl.dsp.workspace.toggle_special("tracker")'
```

Move it to a numbered workspace without switching the user's view:

```bash
hyprctl dispatch 'hl.dsp.window.move({ workspace = 4, follow = false, window = "class:^(tracker)$" })'
```

Kill it: `hyprctl dispatch 'hl.dsp.window.close({ window = "class:^(tracker)$" })'`
or close the tab.

## UI verification

- Drive the running app with `vinland-ui/build/vui-ctl --port 7421`:
  `info`, `screenshot`, `tree`, `click-text`, `type`, `key`, `resize`, `dark`,
  `scroll`, `quit`.
- Always read the PNG back and check `info.unknown_classes` and `frame_ms`.
- `make e2e` runs `tests/ui/window.vt` headless and sandboxed through
  `vinland-ui/build/vui-test`; inspect `/tmp/tracker-e2e/report.html`.
- Hardware recording evidence belongs in `odin/VERIFICATION.md`; the loopback
  checks are `cd odin && ./scripts/check.sh --hardware --jack --loopback`.

## Verify before saying "running"

1. `herdr pane read` shows no panic / error / bind failure.
2. The `vui: control server` readiness match appeared.
3. `vui-ctl --port 7421 info` returns OK with the expected window size.
4. `hyprctl clients -j | jq '.[] | select(.class=="tracker")'` shows exactly one
   window, on the expected workspace.

## Don't

- Don't `herdr pane split --current` for app runs — use a tab.
- Don't run bare `herdr` (it launches/attaches the TUI).
- Don't create a new workspace or worktree for an app run.
- Don't leave the user's active workspace changed.
