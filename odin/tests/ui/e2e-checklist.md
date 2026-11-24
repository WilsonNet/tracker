# Window end-to-end checklist

Manual/agent checklist for the native window (`src/ui/view.odin`), written in
the `vui-test` vocabulary (`tests/ui/window.vt`) so each block can be pasted
into a suite. Verified 2026-11-21 against the 1180x760 default and the 900x620
minimum at `VUI_SCALE=1.5`.

## Setup (sandboxed only)

```sh
S=/tmp/tracker-e2e; mkdir -p $S/config
# never set VUI_HIDDEN_GPU; never run without VUI_HIDDEN=1
XDG_CONFIG_HOME=$S/config VUI_HIDDEN=1 VUI_SCALE=1.5 VUI_PORT=7440 \
  ./bin/tracker-odin ui --demo --session $S/session &
C="../vinland-ui/build/vui-ctl --port 7440"
$C info            # must contain "sandboxed":true, else stop
```

- `XDG_CONFIG_HOME` keeps `recent.json` out of `~/.config/tracker` (save and
  recent-open write it).
- Do **not** run `: open project` / `: save project as`: they open a real
  desktop file picker.
- Bounce is synchronous in the window, so the bounce overlay is never on screen
  long enough to check there (check it with `ui-shot` instead).
- `vui-ctl key tab|enter|space` also reaches vinland's own focus handling (the
  real window consumes keys first). While a text field is editing Tracker
  clears vinland focus; outside edit mode, click an empty area to clear focus
  before key steps that must be isolated.
- Pointer modifiers are supported: `down`/`move`/`up` and `drag-text` accept
  `mods` (`shift`, `ctrl`). Shift-fine drag/wheel can be checked end to end.
  `click` accepts `right`, `double` and `triple`.

Locate controls by exact text (`raw '{"cmd":"find","text":"ARM","nth":1,"exact":true}'`).
`click-text` matches substrings without regard to case: `2` also matches `120`.

## Transport

```
test "rec needs an arm"
  click REC
  expect-text "arm a track first"        # status line + toast
  expect-text NORMAL
test "record / stop"
  click ARM 1                            # track 2
  expect-class ARM bg-rec                # (2nd ARM)
  click REC
  expect-exact REC 2                     # mode chip REC + button; button class has animate-pulse bg-rec
  expect-text "● REC 1"                  # status badge, armed count
  expect-text Recording                  # bounce-row status
  click ARM 2                            # during recording
  expect-text "stop recording to change arms"
  click-at <track 2 IN pill 1>
  expect-text "stop recording to change input"
  type 1
  expect-text "stop recording to change arms"
  click STOP
  expect-text "take captured"
  expect-exact 1/1                       # track 2 take row: "‹ 1/1 › COMP" (1-based id; C/n = comp)
test "play / stop"
  click PLAY                             # transport
  expect-text Playing                    # PLAY -> STOP (bg-sig text-canvas); bounce-row PLAY -> STOP (bg-cue)
  click STOP
  expect-text stopped
  type " "                               # Space toggles play too
```

## BPM

```
  click +            -> 121
  click − ; click −  -> 119
  scroll -48 828 22  -> +1 (wheel up over the BPM box); scroll 48 -> -1
  type +  type =  type -   -> +1 +1 -1
```
The − / + glyphs must sit on the vertical centre of the 28px box.

## Monitor and I/O

```
  click MON          -> "MON ON" (border-line-sig bg-sig-bg), status "monitor on", badge "● CAP"
  click "MON ON"     -> "MON", "monitor off"
  click I/O  (or type i) -> "Input devices", mode chip I/O, hint "click: select  esc: close"
  click + (LAT, 2nd "+")  -> "LAT 1 ms" in panel and rhythm row; overlay STAYS open
  click −  (2nd "−")      -> back to "LAT 0 ms"; overlay stays open
  click JACK         -> class border-cue bg-cue-bg; status "JACK capture selected"; status meta "· JACK ·"
  click JACK         -> "PipeWire capture selected"
  click RESCAN       -> "devices rescanned"; overlay stays open
  click "<device row>" -> overlay closes; transport device label + status meta show it; "input device selected"
  type i ; click-at 100 600 (backdrop) -> overlay closes
  type i ; key escape -> overlay closes ; type i twice -> toggles
```

## Track strip (track 3 shown; any index)

```
  click SOLO 2       -> class border-cue bg-cue text-canvas; again -> border-transparent
  click MUTE 2       -> class bg-ink-muted; again -> off
  click "2" (track 1 IN pill) -> pill bg-sig, track 1 selected (border-line-sig bg-panel)
  click CMP (FX badge)        -> rack opens on that track ("TRACK n"), mode FX
  pan knob (100,160 on track 1 @1180):
    drag 0 -30        -> "R50"   (120 px = full range)
    scroll -48        -> +3 %  ("R3" from C); scroll 96 -> "L3"
    dblclick          -> "C"
    key right / left  -> R5 / L5 (selected track)
  fader (149,150):
    drag 0 -20        -> "1dB"; drag 0 +60 -> "-12dB"
    scroll -48        -> +0.02 gain per notch; scroll 240 -> -5 notches
    dblclick          -> "-2dB" (0.8)
    type K / J        -> ±0.05
  takes (track with takes): ‹ / › -> "take selected"; COMP -> "comp: active take"
  track without takes: "TAKE —  EMPTY"
```

## FX rack

```
  type x                         -> rack "FX 1 2 3 4 MST  TRACK n"; hint "tab: focus  h/l: adjust  x: close"
  click 3 / MST / 1 (tabs, y > rack top) -> "TRACK 3" / "MASTER" / "TRACK 1"
  type ] / [                     -> next / previous channel (wraps through MST)
  MST: click BYP (REVERB)        -> "ON" (border-sig bg-sig); click P·P -> readout "mono repeats" <-> "L/R alternating"
  knob values follow the DSP defaults: SIZE 62%  DECAY 2.9s  TONE 55%  PRE 18ms  RET 45%  FB 35%  WIDTH 100%
  enabled knob drag 0 -17        -> +10 % (170 px = full range)
  enabled knob scroll -48        -> +1.5 % per notch; dblclick -> default
  bypassed module knob drag      -> unchanged
  key tab                        -> ring on LOW; footer "EQ · LOW +0.0" (no "knob.eq.low" ids)
  type l / lll / L / h / H       -> +1 % / +3 % / fine / -1 % / fine   (arrows do the same)
  key enter on a knob            -> reset to default
  Tab through the remaining knobs -> "EQ · ON · ENTER TOGGLES", "COMP · ON ..."; enter flips ON/BYP
  key tab shift                  -> back one
  click ✕ (close)  / type x / key escape -> rack closes, mode NORMAL
  values never read "-0.0" (EQ gains, GR readout)
```

## Bounce row, rhythm, undo/redo

```
  click BOUNCE 1     -> status "bounce N s · X dBFS", toast "bounce complete"
  click ARM ; click UNDO -> ARM off, "undid arm"; click REDO -> ARM on
  REDO with nothing to redo -> border-line-subtle text-ink-muted/60 (disabled look, like UNDO)
  click PLAY 1 (bounce row) -> "Playing", button "STOP" bg-cue; click STOP 2 -> "Ready"
  click RHYTHM       -> "RHYTHM ON", "CLICK · 120 BPM · 4/4", "metronome on"; type c -> OFF
```

## Command palette

```
  type :   (or click the ":" button, rhythm row) -> "Commands", mode COMMAND, 10 rows, "1/30"
  type s   -> rows stop / save project / save project as, first selected (font-medium bg-sig-bg)
  key down / up -> selection moves (clamped at the ends)
  type zzz -> "No matching command" ; backspace restores
  key enter on "stop"      -> runs, palette closes
  type met ; click metronome row -> runs (metronome toggles), palette closes
  click-at 100 600 (backdrop) -> closes ; click inside the panel -> stays open ; key escape -> closes
  ": save project"         -> "project saved", recent.json gains the session path
  ": high contrast"        -> "high contrast on" (inks/hairlines lift); again -> off
```

## Recent projects

```
  ": recent projects"  -> "Recent projects", mode RECENT, rows from $XDG_CONFIG_HOME/tracker/recent.json
  key down             -> selection moves
  type projB           -> filtered to the matching row; "zz" -> "No matching project"
  click <row>          -> "project loaded", mode NORMAL
  key escape           -> "recent projects closed"
```

## Vim keys (normal mode)

| key | expected |
|---|---|
| j / k, ↑ / ↓ | selection left / right (k past the last track selects the master: "MST" turns amber with a ring; the visible window follows) |
| Tab / Shift-Tab | next / previous strip including master |
| J / K | selected fader ∓0.05 |
| a, 1-9 | arm selected / arm track n if it exists (and select it) |
| N / D | add a track / remove the last empty track (4–24) |
| { } / ( ) | show fewer / more strips; previous / next page |
| v / V | mark selected for bounce / open bounce-to-track dialog (j/k target, Enter run, Esc cancel) |
| R | rename selected track inline (Enter save, Esc cancel, empty = default) |
| F1 | contextual key sheet; F1 or Esc closes; other keys ignored |
| s / m | solo / mute selected |
| I | cycle selected input |
| ← / → | pan ∓5 % |
| t / T | next / previous take ("no takes on this track" when empty) |
| u / U | undo / redo ("undid arm (takes kept)" / "redid arm") |
| o / y / c | monitor, JACK/PipeWire backend, metronome |
| Space | play / pause in place (resumes from the paused position); while recording punches out and stays put |
| r / Ctrl+r | record at the playhead after the pre-roll / record at once; again = punch out |
| M / p / 0 | marker here (again on it = clear) / audition lead-in up to the playhead / stop → marker → 00:00 |
| STOP button | halt and return to the marker; again → 00:00 |
| PRE-ROLL chip | cycles OFF, 1, 2, 3, 5, 10 s (also Settings → Pre-roll) |
| b | bounce |
| i / x / : | I/O overlay / FX rack / palette |
| [ / ] | FX channel previous / next |
| + = - | BPM |

## Sizes

```
  resize 900 620           -> one-line transport (I/O label never wraps; device name truncates),
                              4 strips with TAKE rows, bounce/status/rhythm rows visible
  type x at 900x620        -> compact rack (242px, short visuals, no level history): TAKE rows still above the rack
  MST at 900 / 1000 wide   -> chain overflows: wheel over the chain pans it, Tab focus scrolls the focused
                              module into view, also after a resize
  ":" with MON ON at 900   -> transport height stays 45
  resize 1600 1000         -> modules cap at 330px (as fx.css), no gaps or overlap
```
