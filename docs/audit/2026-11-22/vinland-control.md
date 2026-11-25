# vinland-ui control/input audit — pointer, focus, cursor

> **Follow-up (same day).** The "WIP `VUI_BACKGROUND`" findings below were used
> to harden the implementation before commit: synthetic buttons/modifiers are
> separated from real ones, cursor/IME side effects are gated on real
> focus/pointer state, `vui-test` owns the sandbox environment, and
> `scripts/check-background.sh` now unsets `WAYLAND_DISPLAY` and forces X11 so
> it cannot map a window on the live desktop. The report is kept as the audit
> trail; see `README.md` in this directory for the resulting changes.

Audit of `/home/wilsonn/www/vinland-ui` at `HEAD 357c115` (2026-11-22), plus a review of the
in-progress `VUI_BACKGROUND` work in the working tree. No files in the repo were edited.

Artifacts and repro code live in `/tmp/opencode/audit-vui/`:
- `head/` — clean `git archive HEAD` copy used for the baseline build
- `probe/probe.odin` — tiny app that reports `SDL_GetKeyboardFocus`, window flags,
  `SDL_TextInputActive`, `ctx.input.mods`, buttons, cursor, focus id
- `probe/xpeer.c` — second X11 window with a crosshair cursor
- `probe/xstate.c` — prints pointer position, X input focus, and the XFixes cursor serial/size/hash
- `probe/xtree.c` — prints the X window tree and map states
- `out/` — logs, screenshots, pointer/focus samples

## Bottom line

`vui-ctl click` / `click-text` **cannot move the real OS pointer**. The synthetic path is entirely
in-process (`vui/app/control.odin` → `App.synthetic` → `apply_synthetic`), and there is no
`SDL_WarpMouse`, `XWarpPointer`, `xdotool`, `ydotool`, or other OS input injection anywhere in the
framework or CLIs. A safe Xvfb repro confirms it: while a peer X11 window held focus and the pointer
at `(800,200)`, `vui-ctl click 100 100` left both pointer and X input focus unchanged; only the app's
internal `app.mouse` moved.

The OS-level "mouse steal" is much more likely **window mapping**, not clicking:

1. A visible window is created and mapped by `SDL_ShowWindow`. On Wayland, SDL explicitly requests
   activation through `xdg_activation` unless `SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN` is false. Under
   Hyprland, a new toplevel is focused by compositor policy anyway. A fullscreen game loses keyboard
   focus and often pointer lock. This happens once at launch, but an agent usually runs `vui-ctl`
   immediately afterwards, so it feels like the click did it.
2. The synthetic path mutates the same persistent state as the real mouse (`app.mouse`,
   `app.mouse_inside`, `app.buttons`, app focus). Hover, cursor, and especially a `down` without an
   `up` survive the agent session and change what the user's next real motion/click does.
3. `SDL_StartTextInput` is called from `end_frame` whenever a text field is focused, even when the
   window has no OS keyboard focus. On Linux/Wayland SDL gates the actual IME enable on keyboard
   focus, but it still flips `SDL_TextInputActive`; on platforms with a screen keyboard/IME this is a
   real keyboard/IME side effect. It is not the mouse.
4. Cursor `Show/Hide/SetCursor` calls are **not** the game-stealing mechanism. They are scoped to the
   app's own SDL windows on X11 and to the app's pointer focus on Wayland; the peer cursor was
   unchanged in the repro. They can leave this app's own cursor stale.

For a hard guarantee, the only portable mode is **offscreen** (`VUI_HIDDEN=1`, no compositor
connection). A visible "background" window is not reliably non-focusable on Wayland, and the current
`VUI_BACKGROUND` implementation overpromises and has several correctness bugs (below). If a visible
agent window is required, it needs a compositor rule (`no_focus` / `no_initial_focus` under
Hyprland) in addition to any SDL hint.

## Ranked root causes

### 1. Visible window mapping takes focus (very likely; actual OS focus steal)

`vui/app/app.odin:243-255` (HEAD) creates a normal window unless `cfg.hidden`; `SDL_CreateWindow`
calls `SDL_FinishWindowCreation`, which calls `SDL_ShowWindow` when `SDL_WINDOW_HIDDEN` is not set.
On Wayland:

- `SDL_waylandwindow.c:2139-2157` calls `xdg_activation_v1_activate` (via `Wayland_RaiseWindow`)
  when `SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN` is true, which is the default.
- `SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN` has no equivalent effect on the X11 backend; the window
  manager decides. Most WMs focus new toplevels.

Safe repro (Xvfb `:97` + openbox, a peer window focused at `(800,200)`):

```
BEFORE: POINTER_X=800 POINTER_Y=200 FOCUS=0x400001
launch visible probe on :97
AFTER:  POINTER_X=800 POINTER_Y=200 FOCUS=0x600034   <-- new window took focus
```

The same launch under `VUI_HIDDEN=1` produced no new X client at all (`_NET_CLIENT_LIST` unchanged),
no pointer change, and no focus change.

Why `VUI_BACKGROUND=1` does not fix it on Wayland:

- `SDL_WINDOW_NOT_FOCUSABLE` is only consulted for popups in the Wayland backend. The toplevel path never
  consults it: `SDL_waylandwindow.c:2027` and `:2200` are popup-only; `Wayland_SetWindowFocusable`
  returns `SDL_SetError("wayland: focus can only be toggled on popup menu windows")`
  (`SDL_waylandwindow.c:3221-3235`).
- `HINT_WINDOW_ACTIVATE_WHEN_SHOWN=0` only suppresses SDL's own `xdg_activation` request. It does not
  stop Hyprland from focusing a new toplevel by policy. The local Hyprland config already carries
  `no_initial_focus` rules for exactly this failure mode (Ardour), which is evidence that the
  compositor focuses new windows independently of client hints.
- On X11 the flag sets `WM_HINTS.input=False` at create time (`SDL_x11window.c:789`). In the
  openbox test the background probe was left unmapped/unmanaged: `xtree` showed `mapped=0`,
  `WM_STATE` absent, and the window was invisible. (Whether the WM or SDL's show path is responsible
  is WM-specific; the practical result is the same.) With no WM at all, `X11_ShowWindow` force-called `XSetInputFocus` when
  `net_wm` was absent and the "non-focusable" window still reported `keyboard_focus:true`. So even
  X11 behavior is WM-dependent.

**Consequence:** `VUI_BACKGROUND=1` is a best-effort hint on X11 and effectively unimplemented on
Wayland toplevels. It must not be described as "never focusable" / "never activates".

### 2. Synthetic input shares persistent state with real input (likely; app-level "mouse steal")

`vui/app/app.odin:520-564` (HEAD) makes synthetic events write the same fields as real SDL events:

- `.Move` / `.Down` / `.Wheel` set `app.mouse`, `app.mouse_inside = true`.
- `.Down` / `.Up` mutate `app.buttons`.
- A `.Down` without a matching `.Up` leaves `ctx.press_id`, `st.active`, and `app.buttons` set.
- `next_frame` then feeds that state to `vui.begin_frame` (`app.odin:612-619`), so hover, focus,
  drag, and cursor state all follow the invisible synthetic pointer.

Repro on HEAD, peer focused, pointer over peer:

```
vui-ctl raw '{"cmd":"down"}'        -> state: buttons=1, mouse_inside=true
real click in the app              -> buttons=0; the first real release had to clean up the
                                      synthetic drag state
```

Also observed: after a synthetic click on a text field, the app reported `mouse_inside:true` and
`text_wanted:true` forever, while the real pointer was over another window. The app renders as if a
ghost is moving the pointer. This is probably what "steals the mouse" feels like when the user
glances at the app; it is not an OS pointer move, but it changes the app's reaction to the next real
event.

`vui-ctl down` is not even exposed by the CLI (see "Other issues"), so a caller has to use `raw` and
can easily leave the down state behind.

### 3. Text input is enabled on an unfocused window (medium; keyboard/IME, not mouse)

`vui/app/app.odin:681-689` (HEAD):

```odin
if ctx.text_input_wanted != app.text_input_on {
    app.text_input_on = ctx.text_input_wanted
    if app.text_input_on { _ = sdl.StartTextInput(app.window) } ...
}
```

A synthetic click on a text field sets `ctx.text_input_wanted = true` in `vui/widgets.odin:247-249`.
The app then calls `SDL_StartTextInput` with no check of OS keyboard focus.

Repro: while the app was unfocused and the peer held X focus, `vui-ctl click-text 'type here'`
produced `text_active:true`, `keyboard_focus:false`.

SDL's own behavior on Linux is partly protective:
- Wayland `Wayland_StartTextInput` only enables the seat's text input if
  `seat->keyboard.focus == wind` (`SDL_waylandkeyboard.c:112-192`), so the IME should not pop up while
  another window is focused.
- X11 `X11_StartTextInput` resets/updates the XIC but does not change input focus
  (`SDL_x11keyboard.c:881-899`).

But SDL documents `SDL_StartTextInput` as possibly showing the screen keyboard/activating an IME on
some platforms, and `SDL_TextInputActive` becomes true regardless. The app should only call it when
the window actually has OS keyboard focus.

### 4. Cursor side effects from synthetic hover (low for other apps; medium for this app)

`vui/app/app.odin:668-680` (HEAD) calls `SDL_HideCursor`/`SDL_ShowCursor`/`SDL_SetCursor` whenever
`ctx.cursor` changes. Since `ctx.cursor` is derived from the synthetic pointer, an agent move can
change the cursor while the real pointer is over another app.

What this does and does not do:
- X11: `SDL_SetCursor`/`SDL_HideCursor` set the process-wide cursor state and `X11_ShowCursor` loops
  every SDL window of the app and calls `XDefineCursor` (`SDL_x11mouse.c:346-373`). It cannot change
  another X client's cursor. Repro: pointer over the peer crosshair, synthetic hover over a
  `cursor-none` region in the app, peer cursor serial/hash unchanged.
- Wayland: `Wayland_ShowCursor` only calls `wl_pointer.set_cursor` when `mouse->focus` matches the
  seat's pointer focus (`SDL_waylandmouse.c:1227-1245`); with the pointer over another surface it is a
  no-op. `SDL_RedrawCursor` uses `mouse->focus` (`SDL_mouse.c:1800-1822`).
- But: a synthetic hover over `cursor-none` calls `SDL_HideCursor`, which sets `cursor_visible=false`
  for the app. When the real pointer later enters, SDL may keep the cursor hidden until a real
  motion changes `ctx.cursor`. In the repro, entering the app directly over the synthetic
  `cursor-none` area showed the hidden cursor; entering over a normal area showed the default. This is
  app-local staleness, not a game cursor grab.

The WIP comment `app.odin:709-712` claiming "SDL_ShowCursor is display-global on X11 ... would end a
game's cursor grab" is incorrect and should be rewritten. The guard is good hygiene; the rationale is
wrong.

### 5. Visible control commands can disturb without touching the pointer (low/expected)

These are not synthetic-pointer leaks, but they are OS side effects an agent can trigger on a visible
window:
- `resize`: `sdl.SetWindowSize` (`control.odin:416-429`) actually resizes the user's window.
- `screenshot`: GPU readback (`gpu_read_pixels`) creates a transfer buffer and waits on GPU fences
  (`gpu.odin:429-478`); on a busy game GPU this can cause a hitch. Hidden/llvmpipe capture avoids it.
- `foreground` (WIP): `SDL_SetWindowFocusable(true)`, `SDL_RaiseWindow`, `SDL_FlashWindow` are
  explicit focus-stealing APIs by design.
- `quit`: terminates the app.
- Custom `App.on_command` commands can do anything (open dialogs, start recording, etc.).

### 6. `vui-ctl` itself has no OS input path (ruled out)

`tools/vui-ctl/main.odin` only builds JSON and does a loopback TCP exchange. It does not exec
`xdotool`, `ydotool`, `wtype`, or any compositor tool. The server only queues `Synthetic` events.
`vui-test` is the same (plus process launch and screenshot comparison). No `SDL_WarpMouse` anywhere
in `vui/`, `tools/`, `showroom/`, or `examples/`.

## What `VUI_HIDDEN=1` actually guarantees

Confirmed under Xvfb with explicit X11:

- `_NET_CLIENT_LIST` is unchanged (no X client/window is created).
- `xdotool getmouselocation` and X input focus are unchanged.
- `info.sandboxed` is `true`; `gl_renderer` is llvmpipe.
- Synthetic click/text still work and `SDL_TextInputActive` may be true internally, but the offscreen
  driver has no OS surface, so nothing reaches the compositor.

`VUI_HIDDEN=1 VUI_HIDDEN_GPU=1` is still offscreen/no compositor but uses the GPU; it can contend with
the game, hence the existing `gpu-guard.sh` rule. It does not affect pointer/focus.

Caveats in hidden mode:
- The framework window is isolated, but app code is not. Tracker-FX's native pickers shell out to
  `zenity`/`kdialog` (`odin/src/file_dialog.odin`); pressing `o`/`S`/a picker shortcut in a hidden
  app can map a real dialog and take focus. The same applies to any app command that opens a
  browser (OAuth) or another external process. Avoid those commands in hidden agent runs or stub
  the dialog layer under test.
- `clipboard_read` falls back to the real desktop clipboard with `wl-paste`/`xclip`/`xsel`
  (`app.odin:133-167`). A hidden test can read the user's clipboard; `Ctrl+V`/`Ctrl+C` can also write
  it via `clipboard_set`. That is a privacy/clipboard side effect, not pointer/focus.
- CPU/GPU consumption while rendering/animation runs; idle still blocks on `WaitEventTimeout`.

## Review of the in-progress `VUI_BACKGROUND` implementation

The working tree adds `Config.background`, `VUI_BACKGROUND`, `.NOT_FOCUSABLE`,
`pointer_synthetic`, `cursor_applied`, live keyboard-focus checks, `foreground`/`background`
commands, docs, and `scripts/check-background.sh`. The direction (separate synthetic state, gate OS
cursor/text input) is right; the guarantees are not.

### B1. "Mapped non-focusable and never activates" is false

As above: `NOT_FOCUSABLE` is popup-only on Wayland; Hyprland policy can focus a new toplevel. On
X11/openbox the window was actually **unmapped/invisible**, so the test can pass without a visible
window. On bare Xvfb (no WM) the same "non-focusable" window was mapped and **took focus** because
`X11_ShowWindow` force-focuses when no WM is present.

### B2. `background` does not return to non-focusable state

`control.odin:359-371` calls `SDL_SetWindowFocusable(false)` and `SDL_FlashWindow(.CANCEL)`, then
sets `cfg.background=true`. On X11, `SetWindowFocusable(false)` only updates `WM_HINTS` for future
focus decisions; it does not release the current input focus
(`SDL_x11window.c:2374-2400`). Repro (X11, openbox): after `foreground` then `background`,
`info.keyboard_focus` remained `true` and X focus remained on the app. On Wayland,
`SetWindowFocusable` fails for toplevels.

`SDL_FlashWindow(.CANCEL)` is worse on Wayland: `Wayland_FlashWindow` ignores the operation and calls
`Wayland_activate_window(..., false)`, which sends `xdg_activation` (`SDL_waylandwindow.c:2379-2386`,
`:2311-2372`). So "background" can *request activation*.

### B3. `foreground` leaves a half-foreground state on failure

`control.odin:339-358` does:

```odin
focusable := sdl.SetWindowFocusable(app.window, true)
raised := sdl.RaiseWindow(app.window)
flashed := sdl.FlashWindow(app.window, .UNTIL_FOCUSED)
app.cfg.background = false
```

It clears `background` even when `focusable` is false. On Wayland, `SDL_SetWindowFocusable` clears the
`SDL_WINDOW_NOT_FOCUSABLE` flag **before** calling the backend and does not restore it when the
backend fails (`SDL_video.c:3928-3945`). Consequences:
- `info.focusable` (computed as `.NOT_FOCUSABLE not_in flags`, `control.odin:315`) reports `true`
  even though the surface never became focusable.
- `cfg.background=false` disables the synthetic cursor guard and re-enables text-input attempts even
  though the window may still not be focused.
- The response reports `raised`/`flashed` from the API, not whether focus was actually obtained.

### B4. Background mode disables legitimate text input and cursor for real users

`app.odin:734` gates text input on `!app.cfg.background && app.keyboard_focus`. A real click can
focus a background window (`WINDOW_FOCUS_GAINED`; observed), but `text_active` stays false because
`background` is true. Repro (Xvfb `:98`, background app, real click into its text field):

```
info: keyboard_focus=true, background=true, text_wanted=true
xdotool type 'hello-bg'
tree: text still "type here", text_active=false
```

After `vui-ctl foreground`, the same typing produced `after-fg`.

The cursor guard is similarly too broad: a background window that the user is genuinely using never
gets a text/pointer cursor. The correct distinction is **synthetic vs real event**, not
background-window vs not:
- cursor: skip only when `!app.mouse_inside` or `app.pointer_synthetic`; a real enter/motion should
  restore normal cursor behavior even in background mode;
- text input: require `app.keyboard_focus` (live), not `!background`.

### B5. `info.focusable` is not a guarantee

`control.odin:315` reports `!NOT_FOCUSABLE` from SDL's flags. It is false on Wayland even when the
compositor focuses the window, and true after a failed `SetWindowFocusable(true)`. Tests asserting
`"focusable":false` prove only that the flag was set, not that the compositor honored it. Use
`keyboard_focus` (actual `SDL_WINDOW_INPUT_FOCUS`) as the truth, plus a documented
`focusable_requested`/`backend` field; don't call it "focusable".

### B6. `check-background.sh` can open a window on the real desktop and does not test focus

`scripts/check-background.sh:25` runs under `xvfb-run`, but never unsets `WAYLAND_DISPLAY` or forces
`SDL_VIDEO_DRIVER=x11`. On this machine `WAYLAND_DISPLAY=wayland-1` is inherited; SDL prefers Wayland,
so the app can map on the real session instead of Xvfb. (I hit exactly this while preparing the safe
repro: an early probe briefly mapped a 640×480 "Probe" window on the real session before I killed it.
All later runs explicitly unset `WAYLAND_DISPLAY` and set `SDL_VIDEO_DRIVER=x11`.)

The script also:
- never creates a peer window or checks `xdotool getwindowfocus` / `_NET_ACTIVE_WINDOW`, so it
  does not prove the no-focus guarantee;
- never checks `info.keyboard_focus` / `mouse_inside`;
- asserts `"focusable":false`, which is the misleading flag above;
- does not check that the background window is actually mapped/visible (the openbox case was
  unmapped, so `click-text` still passed);
- does not test typing while the window is focused, so B4 is invisible;
- calls `foreground` then `background` and only checks `"ok":true` / `"background":true`, not that
  focus was relinquished.

## Minimal recommended change

Backward compatibility is good: all of this is additive except the `background` semantics/docs.

### 1. Make offscreen the only promised safe mode

- Keep `VUI_HIDDEN=1` / `Config.hidden` as **the** hard guarantee. Document: "no compositor
  connection, no OS pointer/focus/cursor, no window."
- Rename/describe `VUI_BACKGROUND=1` as **best-effort no-focus**:
  - `Config.background` comment: "requests a non-focusable window where the backend supports it;
    on Wayland toplevels this is only a compositor policy, not a client guarantee."
  - README/skill/showroom: remove "mapped non-focusable and never activates"; say
    "may still be focused by the compositor; use `VUI_HIDDEN=1` or a `no_focus`/`no_initial_focus`
    window rule when that matters."
- For a visible agent window under Hyprland, document an exact rule (using a stable, distinct
  `app_id`):
  ```lua
  hl.window_rule({
      name  = "tracker-fx-agent-no-focus",
      match = { class = "^(tracker-fx-agent)$" },
      no_focus = true,          -- or no_initial_focus for launch-only
  })
  ```
  `Config.app_id` already controls Wayland app_id / X11 class (`app.odin:216-218`). Give background
  sessions a distinct id (`tracker-fx-agent`) so the rule does not affect normal launches.
- Add `vui-ctl --require-sandboxed` (or `--require-background`) that does a preflight `info` and exits
  non-zero when `sandboxed` is false (or when `background` is false / `keyboard_focus` is true).
  Keep normal behavior unchanged.

### 2. Fix `vui-test` before launch

`tools/vui-test/main.odin:343-358` appends `VUI_HIDDEN=1` and then suite `env` entries. Depending on
how duplicate environment entries are resolved, a suite can override the forced hidden value;
`launch` only checks `info.sandboxed` after the app has started (`:367-378`), so a visible window can
map and take focus before the check kills it. The runner should force the SDL video driver itself and
reject the override before launch.

- Set `SDL_VIDEO_DRIVER=offscreen` / `SDL_VIDEODRIVER=offscreen` in the child environment, and unset
  `WAYLAND_DISPLAY`/`DISPLAY` for the child. This protects even an older app that ignores
  `VUI_HIDDEN`.
- Append forced values **after** suite `env`, or reject suite keys `VUI_HIDDEN`, `VUI_HIDDEN_GPU`,
  `VUI_BACKGROUND`, `SDL_VIDEO_DRIVER`, `SDL_VIDEODRIVER`, `WAYLAND_DISPLAY`, `DISPLAY` unless
  `--allow-visible`/`--headed-gpu`.
- Honor the existing `ctl` timeout parameter (`timeout_ms` is currently unused, `:255-285`) so a hung
  app cannot hang a suite.

### 3. Separate synthetic input from real input

Add an explicit input source rather than reusing `app.mouse`/`app.buttons`:

```odin
// vui/app (suggested)
Input_Source :: enum { Real, Synthetic }
App :: struct {
    // ...
    real_mouse:     [2]f32,
    real_buttons:   vui.Mouse_Buttons,
    synthetic_mouse: [2]f32,
    synthetic_buttons: vui.Mouse_Buttons,
    pointer_synthetic: bool,
}
```

Minimum viable version, without changing `vui.Input`:
- Keep `app.mouse` for the app model, but add `app.real_mouse`/`app.real_buttons`.
- `handle_event` updates the real fields; `apply_synthetic` updates the synthetic fields.
- `next_frame` composes `Input.mouse` = synthetic if a synthetic pointer event is active, else real;
  `Input.buttons` = union, but **real button transitions always win**.
- On a real `MOUSE_MOTION`/`MOUSE_BUTTON_*`/`WINDOW_MOUSE_ENTER`, clear any synthetic button bits that
  are not physically held (`SDL_GetMouseState` can confirm). That fixes the stuck `down` and the
  "agent click cancels my drag" case.
- Add `vui-ctl release` (or `up all`) and call it on `quit`/`shutdown`; multi-command drags can still
  use explicit `down`/`up`.
- If a real pointer event and a synthetic pointer event arrive in the same frame, **defer the
  synthetic one** (or drop it) so the user's input wins.

### 4. Gate OS cursor and text-input calls on real state only

In `end_frame`:

```odin
// Cursor: apply only for real pointer state.
if !app.mouse_inside {
    app.cursor_applied = false
} else if !app.pointer_synthetic && (ctx.cursor != app.cur_cursor || !app.cursor_applied) {
    // Hide/SetCursor ...
}

// Text input: keyboard focus is the only condition.
want_text_input := ctx.text_input_wanted && app.keyboard_focus
```

Do **not** include `!app.cfg.background` in either condition. A synthetic click that focuses a text
field still has `keyboard_focus == false`, so no IME starts. A real user who focuses a background
window can type and gets a normal cursor. If a compositor wrongly focuses the background window at
map time, the app is honestly focused and text input should work; fix the compositor rule, not the
text field.

Recompute `app.keyboard_focus` from `SDL_GetWindowFlags(.INPUT_FOCUS)` at the top of `end_frame`
(WIP already does this) and set `cursor_applied=false` on `WINDOW_MOUSE_LEAVE`,
`WINDOW_FOCUS_LOST`, and `WINDOW_FOCUS_GAINED` (SDL may reset the cursor on focus changes).

### 5. Fix `foreground` / `background` semantics

- `foreground`:
  - If `cfg.hidden`, return `{"ok":false,"error":"offscreen app has no OS window"}`; do not toggle.
  - Only set `cfg.background=false` if `SDL_SetWindowFocusable(true)` **and** the window actually
    gains `INPUT_FOCUS` within the wait frames. Otherwise keep `background=true` and return
    `{"ok":true,"foreground":false,"hint":"restart without VUI_BACKGROUND=1"}`.
  - Report `keyboard_focus` after the wait, not just `raised`/`flashed`.
  - Set `SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN=1` while foreground if native dialogs are expected;
    restore to `"0"` in background.
- `background`:
  - Do not call `SDL_FlashWindow(.CANCEL)` on Wayland; gate it to the X11 driver or remove it.
  - Report `keyboard_focus`; on X11 it will often remain true. Say so in the response/docs rather
    than claiming "non-focusable".
  - `background off` is currently not the inverse of `foreground` (it only clears the app flag);
    either make it an alias for `foreground`/remove it, or document it as "app mode only".
- Keep the command names `foreground`/`background` for compatibility with the WIP docs; they are
  explicit escape hatches.

### 6. `info` fields that tell the truth

Additive fields (keep existing ones):
- `hidden`, `sandboxed`, `background`, `keyboard_focus`, `mouse_focus`, `video_driver`
- `not_focusable_flag` (SDL flag) instead of calling it `focusable`
- `pointer_synthetic`, `synthetic_buttons`
- `window_shown` (or the last `WINDOW_SHOWN`/`HIDDEN` event state)

`vui-ctl info` should print a warning to stderr when `sandboxed:false && background:false`:
"visible window; it may have taken OS focus when mapped; use VUI_HIDDEN=1 or a no-focus window
rule". This is the cheapest way to stop the next agent from repeating the incident.

### 7. Control API gaps (backward-compatible additions)

- `vui-ctl down <x> <y>` / `vui-ctl up <x> <y>` — `control.odin` already supports `down`/`up`, but
  `tools/vui-ctl` has no cases, so agents must use `raw`. Add them (plus `find <text>`).
- `click_text` already builds a `{ok,x,y}` response but drops it (`control.odin:395-399`; the
  `req_resp` variable is unused). Assign it to `req.response` (or `respond`) so callers get the hit
  point. This is additive JSON.
- `click_text` also does `app.synthetic[0].pos = p` after `push_click` (`:394`). That assumes the
  first queued event is its own `Move`; if other synthetic events are pending it rewrites the wrong
  event. `push_click` already sets the position; delete the line.
- `find_text` (`vui/widgets.odin:524-546`) ignores `n.clip`, scroll offsets, and the viewport. A
  text node scrolled out of view can "match" and `click-text` can click at coordinates where a
  different element is visible. Intersect with `n.clip` and the viewport, and skip fully clipped
  nodes. The `find` control command (`control.odin:355-385`) also returns untransformed rects, so
  `vui-test` clicks transformed nodes at the wrong point; apply `n.xform` like `find_text` does.

## Tests that actually prove pointer/focus are untouched

### A. Xvfb + openbox regression (extend `scripts/check-background.sh`)

Inside `xvfb-run`, **before** launching the app:

```sh
unset WAYLAND_DISPLAY
export SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11 XDG_SESSION_TYPE=x11
openbox & sleep 1
# optional peer: a second showroom/xmessage/xpeer; focus it
xdotool mousemove 640 400
before_ptr=$(xdotool getmouselocation --shell)
before_focus=$(xdotool getwindowfocus)
before_active=$(xprop -root _NET_ACTIVE_WINDOW)
```

Assertions after launch and after **each** command (`click`, `click-text`, `move`, `scroll`,
`type`, `key`, `screenshot`, `resize`, `dark`):
- `xdotool getmouselocation --shell` == `before_ptr`
- `xdotool getwindowfocus` == `before_focus`
- `xprop -root _NET_ACTIVE_WINDOW` == `before_active`
- `vui-ctl info` has `"keyboard_focus":false`, `"mouse_inside":false`, and (if used)
  `"background":true`
- the app window is actually mapped/viewable (`WM_STATE` = Normal or `xtree` map state), so a
  "pass" is not an invisible/unmapped window
- after `foreground`: focus changes, `"keyboard_focus":true`; after `background`: assert whether
  focus is relinquished. If it is not (current X11 behavior), fail or explicitly report the
  limitation. Do not claim a round-trip that did not happen.

Add an XFixes cursor check (optional but cheap): with the pointer over the peer, synthetic hover
over a `cursor-none` region must not change the peer's cursor serial/hash. This is the direct proof
that cursor changes are app-scoped. The helper in `probe/xstate.c` shows the API.

Add a hidden-mode block:
- launch with `VUI_HIDDEN=1`; assert `xdotool search --name <app>` finds nothing,
  `_NET_CLIENT_LIST` is unchanged, pointer/focus unchanged, `info.sandboxed:true`.

Add a real-focus/typing block (to catch B4):
- real-click the background window's text field, assert `keyboard_focus:true`, type with
  `xdotool type`, and assert the text appears **without** `foreground` (if the intended semantics
  allow a user to take over) or assert the documented requirement to call `foreground` first.

### B. Wayland/Hyprland integration (manual or dedicated test session)

Run in a test Hyprland session (not the user's live one):
```sh
hyprctl activewindow -j | jq -r .address > before
hyprctl cursorpos > before_pos
VUI_BACKGROUND=1 VUI_PORT=7421 ./build/showroom &
# wait for control
vui-ctl click-text "Introduction"
hyprctl activewindow -j | jq -r .address  # must equal before
hyprctl cursorpos                          # must equal before_pos
vui-ctl info                               # keyboard_focus must be false
```
This currently fails at launch without a `no_initial_focus`/`no_focus` rule. It is the test that
proves whether `VUI_BACKGROUND` is meaningful on the user's actual compositor.

### C. Unit tests for the input model (no display)

Factor the end-frame decisions into pure procs so they can be tested with a plain `App`/`Context`:

```odin
should_apply_cursor(app, ctx) -> bool
should_start_text_input(app, ctx) -> bool
```

Cases:
- `background=true, keyboard_focus=false, text_input_wanted=true` -> no `StartTextInput`
- `background=true, keyboard_focus=true, text_input_wanted=true` -> `StartTextInput`
  (if real focus is allowed to type)
- `pointer_synthetic=true` -> no cursor calls
- synthetic `Down` + real `MOUSE_MOTION` with no physical button -> synthetic button cleared
- synthetic key with no mods while real Shift is held -> `Input.mods` does not contain Shift
- synthetic key with `ctrl` -> Ctrl is present for the key frame and not replaced by real mods

### D. Process-level `vui-test` safety test

- A suite with `env VUI_HIDDEN=0` / `env SDL_VIDEO_DRIVER=x11` must be rejected **before** launch
  (or the forced offscreen env must win). Assert no window appears and the runner exits non-zero
  with a clear message.
- A suite with `--allow-visible` opt-in may open a window, but the test must assert focus changes
  only when expected.

### E. `xtrace` (optional, strongest X11 evidence)

`xtrace --display :99 -- ./probe` around a `vui-ctl click` run, then grep the request log for
`WarpPointer`, `SetInputFocus`, `RaiseWindow`, `ConfigureWindow` on the peer. Expected: none from the
synthetic click. This complements the state sampling.

## Other correctness/performance issues in the control/input path

1. **Synthetic modifiers are not isolated from real modifiers** (`app.odin:580-583`, `:616-618`).
   `apply_synthetic` sets `in_.mods = s.mods` for one frame; `next_frame` then falls back to
   `SDL_GetModState()` when `in_.mods == {}`. Repro: with real Shift held in the focused app,
   `vui-ctl key a` produced `ctx.input.mods` containing Shift; `vui-ctl key a ctrl` produced Shift on
   the frame after the key because Ctrl was not held. Track a `mods_synthetic` flag and skip the
   real `GetModState` fallback for synthetic frames; keep explicit key mods for the frame(s) the key
   is processed (or until the next real key event).
2. **`app.buttons` is shared** (see root cause 2). A synthetic `up` can remove a real held button,
   and a real release can clear a synthetic drag. Real input must win; use separate sets/counters.
3. **`request_redraw` does not wake the event loop** (`app.odin:726-728`). If called from another
   thread during `WaitEventTimeout(500)`, the redraw is delayed up to 500 ms and the `dirty_frames`
   int is racy. Call `wake(app)` (or document main-thread-only) and use an atomic/mutex.
4. **`vui-ctl` lacks `down`/`up`/`find`**, and `click-text` loses its coordinates
   (`control.odin:386-399`). Agents must use `raw` and cannot assert where a text click landed.
5. **`find_text` ignores clipping/scroll/viewport** (`vui/widgets.odin:524-546`), so `expect-text`
   and `click-text` can see content the user cannot; `find` also ignores transforms
   (`control.odin:363-385`), so `vui-test` clicks transformed nodes at the wrong point.
6. **The key table is tiny.** `key_from_name` (`control.odin:190-240`) accepts only tab, enter,
   escape, backspace, delete, arrows, home/end, page up/down, space, a/c/v/x/y/z/k, slash, F1.
   Tracker-FX is keyboard-first (`b`, `o`, `s`, `l`, `h`, etc.); `vui-ctl key o` returns "unknown key",
   and `vui-ctl type o` produces text, not a key press. Agents cannot exercise most shortcuts. Use
   SDL key names (`SDL_GetKeyFromName`) or a full table, and add `keydown`/`keyup` if holds matter.
7. **`vui-test`'s `ctl` timeout is unused** (`tools/vui-test/main.odin:255-285`), and its suite `env`
   can override the forced hidden env (`:343-358`); the sandbox check happens after launch
   (`:367-378`). See the recommendations above.
8. **Loopback control has no authentication** (`control.odin:46-68`). Any local process can call
   `screenshot`, `type`, `quit`, and now `foreground` (focus/raise). For a dev tool this may be
   acceptable, but document it; if the app can hold secrets, use a Unix socket with 0700 or a token.
9. **Clipboard escapes the sandbox** (`app.odin:133-167`). `VUI_HIDDEN=1` still runs `wl-paste`,
   `xclip`, or `xsel` on paste, and `clipboard_set` can write the real clipboard. A hidden test can
   read or overwrite the user's clipboard. Provide an app-level `ctx.clipboard_get/set` override for
   hidden tests (or skip the fallback when `app.sandboxed`).
10. **GPU screenshot readback can stall the compositor** (`gpu.odin:429-478`). It creates/releases a
   transfer buffer and waits on a fence per screenshot. Use hidden/llvmpipe for agent captures, or
   throttle/read back asynchronously; do not capture a visible GPU app during a game.
11. **`resize` mutates the user's visible window** (`control.odin:416-429`). Agent runs should use
    `VUI_HIDDEN=1` or restore the original size on `quit`; at minimum document it.
12. **App-level external processes are outside any VUI guarantee.** `VUI_HIDDEN=1` only isolates
    vinland-ui's own window. Native pickers (`zenity`/`kdialog` in Tracker-FX), OAuth browser launches,
    or any `App.on_command` side effect can open/focus real windows. Document this in the skill and
    avoid those commands during unattended runs; a test-only dialog stub is the robust fix.
13. **`foreground`/`background` half-state** (see B2/B3): `info.focusable` lies after a failed
    `SetWindowFocusable`; `background` does not release focus; `FlashWindow(.CANCEL)` can activate on
    Wayland. Fix before shipping the commands.
14. **`vui-test --headed-gpu` is not headed** (it still sets `VUI_HIDDEN=1`); the name is
    misleading but the behavior is safe. Rename to `--gpu` or document.
15. **`vui-ctl background 0`** is treated as true (`arg(rest,0,"on") != "off"`); use `arg_b`-style
    parsing or document `off` only.
16. **`Config.background` + `foreground` can't change app_id**; launch background sessions with a
    distinct `app_id` from the start so compositor rules can target them.
17. **`vui-ctl info` `mouse_inside` now means real SDL mouse focus**, while `App.mouse_inside` means
    synthetic-or-real app hover. The name is ambiguous; rename to `mouse_focus` (already added) and
    expose `synthetic_pointer` separately.

## Suggested doc fixes (exact claims to remove/qualify)

- `README.md:132-141`: "the window is mapped non-focusable and never activates" -> "best-effort
  non-focusable; on Wayland toplevels the compositor decides; use VUI_HIDDEN=1 or a no-focus rule".
- `README.md:141`: "`vui-ctl background` returns to non-focusable driving afterward" -> "returns the
  app to background *mode*; it does not necessarily release focus the compositor already gave the
  window (X11 keeps focus; Wayland cannot toggle toplevel focus)".
- `README.md:165-167`: "`check-background.sh` proves the guarantee" -> it proves pointer position
  only; add focus/window-map assertions first.
- `skills/vinland-ui/SKILL.md:49-62` and `showroom/pages_intro.odin` (new section): same overclaims.
  Replace "non-focusable window ... a game or editor keeps keyboard and pointer focus" with the
  offscreen guarantee and the compositor-rule caveat.
- `AGENTS.md` in tracker-fx: "Normal launches open on the active workspace, so a visible run is fine to
  inspect with `vui-ctl`" is the most dangerous line; qualify it: "visible runs map and can take
  focus; for agent verification use VUI_HIDDEN=1; only run visible when the user is not gaming/calling
  and accept the focus change."
- `make ui-bg` in tracker-fx: a visible non-focusable window is not a guarantee. Either make it
  `VUI_HIDDEN=1` (safe, but no visible window) or add the Hyprland `no_focus` rule and document the
  risk. Don't describe it as "while the user games".

## Reproduction commands (summary)

All X11 tests used `Xvfb :97` / `:98`, `openbox` where noted, and `WAYLAND_DISPLAY=` +
`SDL_VIDEO_DRIVER=x11`; no test intentionally used the real desktop. Build the probe against a clean
HEAD copy:

```sh
cd /tmp/opencode/audit-vui/head
git archive HEAD | tar -x -C /tmp/opencode/audit-vui/head
odin build /tmp/opencode/audit-vui/probe/probe.odin -file \
  -collection:vinland=/tmp/opencode/audit-vui/head \
  -out:/tmp/opencode/audit-vui/probe/probe_head
```

Key results:

```text
# synthetic click while peer focused
BEFORE: POINTER_X=800 POINTER_Y=200 FOCUS=0x400001 CURSOR_SERIAL=2
vui-ctl click 100 100
AFTER:  POINTER_X=800 POINTER_Y=200 FOCUS=0x400001 CURSOR_SERIAL=2
app state: mouse=[100,100], mouse_inside=true, keyboard_focus=false

# visible launch steals focus
BEFORE: FOCUS=0x400001
launch visible probe
AFTER:  FOCUS=0x600034

# text input while unfocused (HEAD)
vui-ctl click-text 'type here'
state: keyboard_focus=false, text_wanted=true, text_active=true

# cursor is app-scoped
pointer over peer (crosshair), synthetic hover over cursor-none -> peer CURSOR_SERIAL=2 unchanged

# background WIP is not a guarantee
openbox: bg window mapped=0 / WM_STATE absent (invisible), focus unchanged
no WM:   bg window mapped=2, keyboard_focus=true (SDL force-focused)
foreground -> focus changes; background -> keyboard_focus stays true
real click into bg text field + xdotool type -> no text until foreground
```

## Suggested implementation order

1. Fix the test safety net: `vui-test` forces offscreen driver, `check-background.sh` unsets Wayland
   and asserts focus; remove `AGENTS.md`'s "visible run is fine" line.
2. Make `vui-ctl info` honest (`hidden`, `sandboxed`, `keyboard_focus`, `video_driver`,
   `not_focusable_flag`) and add `--require-sandboxed` / `--require-background`.
3. Separate synthetic state and reconcile real input (buttons/mods/priority).
4. Gate cursor and text input on `pointer_synthetic`/`keyboard_focus` only; drop `!background` from
   those decisions so a real user can type in a background window.
5. Fix `foreground`/`background` atomicity and remove the Wayland `FlashWindow` path; document that
   visible non-focusable is a compositor policy, not a client guarantee.
6. Add the control API gaps (`down`/`up`/`find`, `click-text` coords, clip-aware `find_text`) and the
   tests above.
