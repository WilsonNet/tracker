---
name: herdr
description: Use whenever running, restarting, inspecting, or stopping the Tracker app or its dev server through herdr — "run the app", "start the dev server", "check the logs", "kill it", "run it for me" — and for any herdr tab/pane work in this repo. Covers the dedicated-tab rule, readiness waits, the hidden app workspace, and cleanup.
---

# Herdr workflow in this repo

`herdr` is the terminal workspace the user and the agent share. The current tab
holds the user's conversation: **never split it to run a server**. A split
permanently steals width from their terminal and interrupts them mid-task.
Servers and app runs go in their **own tab**.

## Rule: one dedicated tab per dev server

Verify the session first (the CLI refuses to guess which Herdr to control):

```bash
test "${HERDR_ENV:-}" = 1
```

Create a tab without focus (`--focus` would yank the user's view; don't pass it):

```bash
herdr tab create --cwd "$PWD" --label "tracker dev"
# → .result.tab.tab_id        e.g. w1:t2
# → .result.root_pane.pane_id e.g. w1:p7
```

`tab create` returns JSON. Read the IDs from the response instead of guessing.

Run the command in that pane and wait for a real readiness signal:

```bash
herdr pane run <pane-id> "npm run tauri -- dev"
herdr pane wait-output <pane-id> \
  --match 'Running `target/debug/tracker`' \
  --source recent-unwrapped --timeout 300000
```

Read logs without disturbing anything:

```bash
herdr pane read <pane-id> --source recent-unwrapped --lines 80
```

Cleanup (closes the pane and kills the app + Vite children):

```bash
herdr tab close <tab-id>
```

Leave the tab running only when the user asked to keep using the app; otherwise
close it. Never leave an orphaned dev server.

## What to run

| Goal | Command | Ready when |
|---|---|---|
| Full desktop app | `npm run tauri -- dev` | `Running \`target/debug/tracker\`` |
| UI only (fast iteration) | `npm run dev` | `Local:` / `VITE ... ready` |
| Desktop E2E app | `npm run tauri -- dev --features e2e-testing` | `tauri-plugin-playwright: listening on unix` |

Port `1420` is strict (`strictPort: true`). Only one Vite can run: stop the old
tab first or check `ss -ltn 'sport = :1420'`. A `Port 1420 is already in use`
error in the pane means another dev server is still alive.

Because `tauri dev` watches `src-tauri`, Rust edits trigger a rebuild **inside
the same tab**; re-wait for `Running \`target/debug/tracker\`` after backend
changes instead of starting a second instance.

## The app window

The Hyprland rule opens the native window on a persistent **hidden** special
workspace (`special:tracker silent`), so a launch never switches the user's
workspace or steals focus. Do not screenshot it with `grim` while hidden — an
uncomposited window captures blank. Verify UI in the Vite dev server with the
Playwright MCP browser at `http://localhost:1420`.

Show/hide it when the user asks:

```bash
hyprctl dispatch 'hl.dsp.workspace.toggle_special("tracker")'
```

Move it to a numbered workspace without switching the user's view:

```bash
hyprctl dispatch 'hl.dsp.window.move({ workspace = 4, follow = false, window = "class:^(tracker)$" })'
```

Kill it: `hyprctl dispatch 'hl.dsp.window.close({ window = "class:^(tracker)$" })'`
or close the dev-server tab.

## E2E caveats

- Desktop E2E needs `--features e2e-testing` **and** `"playwright:default"` in
  `src-tauri/capabilities/default.json`; remove the permission afterwards or
  plain `cargo build` fails on the unknown permission.
- The socket bridge's native pointer injection does not reach a hidden or
  floating window. Use `e2e/js-driver.ts` (`click`, `setSelect`, `press`,
  `hotkey`) to dispatch DOM events inside React instead; it works in any window
  state. `e2e/tests/live-record.spec.ts` is the hardware recording check.
- Browser-only tests are the fast loop: `npm run test:e2e` (26 tests).

## Verify before saying "running"

1. `herdr pane read` shows no panic / `error` / `Port 1420` lines.
2. The readiness match appeared.
3. `hyprctl clients -j | jq '.[] | select(.class=="tracker")'` shows exactly one
   window, on the expected workspace.
4. UI checks go through Playwright at `localhost:1420`, not a compositor
   screenshot.

## Don't

- Don't `herdr pane split --current` for servers — use a tab.
- Don't run bare `herdr` (it launches/attaches the TUI).
- Don't create a new workspace or worktree for a dev server.
- Don't leave the user's active workspace changed.
