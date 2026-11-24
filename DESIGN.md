---
name: "Tracker — Multitrack Recorder"
description: "A minimal multitrack audio recorder for the desktop. Keyboard-first, Vim-native, hardware-inspired — no timeline, no grid, just record."
---

# Design System: Tracker

## 1. Overview

**Creative North Star: "The Instrument Panel"**

Tracker is a precision instrument, not a webpage. Every control has a clear purpose. The keyboard is the primary interface — Vim key bindings for every action — while the mouse provides discovery. The interface recedes during a session, leaving only meters, levels, and the transport. When you reach for the keyboard to arm a track or punch in, the tool responds instantly.

The visual identity draws from hardware multitrack recorders (tactile, purpose-built, no fluff), modern precision tools like Linear (dark, minimal, fast), and keyboard-native environments like Obsidian (focused, extensible, local-first). The result should feel like a piece of studio gear — not a DAW, not a website, not a toy.

This system explicitly rejects Pro Tools-level clutter, GarageBand friendliness, SaaS dashboard conventions, and the timeline paradigm. There is no arrange window. There are no waveforms to drag. There is only: arm, level, record, listen.

**Key Characteristics:**
- Dark, instrument-grade surface with a single committed color identity
- Mono-forward typography — one family, precise, technical without feeling cold
- Motion is responsive feedback tied to audio events (recording glow, meter bounce, state transitions), never decorative
- Every interactive element has a keyboard binding; the mouse is available but secondary
- Flat surfaces with tonal separation; depth through focus, not shadow

## 2. Colors

**The Committed Rule.** One saturated color — the orange/honey anchor at hue 57° — carries 30–60% of the visible surface: transport controls, meters, track selectors, recording indicators. Its rarity is not the point; its presence is the identity.

The palette is dark. The scene is a musician in a dim home studio at night, monitor glow the only light source, instrument in hand. The near-black surface recedes; the amber primary signals action and state.

**Primary**
- **Amber Signal** `oklch(0.73 0.157 57)` / bright `oklch(0.80 0.18 57)`: The brand anchor. Used for the transport bar, recording state, track arm indicators, level meters, and primary action buttons. Vibrant but never fluorescent. The color of a hardware VU meter at night.

**Neutral**
- **Console Black** `oklch(0.07 0 0)`: The background surface. Near-black, chroma 0. The canvas that lets amber carry the identity.
- **Panel Gray** `oklch(0.125 0 0)` (raised: `oklch(0.175 0 0)`): Slightly lifted surface for track strips, channel controls, and setting panels. Same hue family as bg, pure neutral.
- **Signal White** `oklch(0.93 0 0)`: Body text and high-contrast labels. Near-white, chroma 0. Clean, readable, no hidden warmth.
- **Dim Label** `oklch(0.65 0 0)` (muted: `oklch(0.48 0 0)`): Secondary text and muted labels. Ink pulled toward bg at reduced contrast. Still ≥3.5:1 against the surface.

**State Semantic**
- **Recording Red** `oklch(0.50 0.20 20)`: Recording indicator — a distinct red, not derived from the orange primary. Pulsing glow.
- **Overdub Teal** `oklch(0.55 0.12 200)`: Overdub/solo state. Cool contrast to the warm primary. A second distinct hue used sparingly for state differentiation.

**Named Rules**
- **The No-Hidden-Warmth Rule.** The background is pure near-black (chroma 0). The orange primary carries all the warmth. Tinting the surface toward amber is prohibited — it muddies contrast and reads as a dim panel, not a precision instrument.
- **The White-on-Color Rule.** Any text on a saturated color fill (transport buttons, recording indicators, accent badges) uses white or near-white text. Dark text on amber reads as muddy. The Helmholtz-Kohlrausch effect makes saturated colors appear brighter than their luminance suggests.

## 3. Typography

**Primary Font:** JetBrains Mono in the native window (fallback: the system mono face). No display/body pairing. One family carries headings, labels, buttons, meters, and body text. The Cairo/Pango regression harness uses Inter for labels and Noto Sans Mono for timecode.

**Character:** Technical precision without feeling cold. The monospace choice aligns with the Vim-native, keyboard-first philosophy. Letters have clear differentiation (no ambiguous 0/O, 1/l/I). Reading rhythm feels natural, not mechanical.

### Hierarchy

- **Heading** (bold, 20–25 px): Section headers, track names, transport labels. Fixed logical-px scale, no fluid clamp.
- **Body** (regular, 11.5–14 px, 1.5 line-height): Prose, settings descriptions, help text. Max line length 65–75ch where prose appears.
- **Label** (medium, 10–12 px, uppercase, 0.04em letter-spacing): Button labels, meter readouts, status indicators, keybinding hints.
- **Data** (regular, 11–14 px, tabular-nums): Timecode, level readouts, track numbers. Monospace numbers align naturally.

**Named Rules**
- **The One-Family Rule.** One font family across the entire interface. Weight, size, and case create hierarchy — not font pairing. A second family is allowed only for timecode/timing displays where tabular-nums and monospace precision are critical.
- **The Fixed-Scale Rule.** Type sizes are fixed logical-px values, not fluid clamp. This is a tool viewed at consistent DPI, not a marketing page viewed across devices. Headings that shrink when the window narrows serve no purpose here.

## 4. Elevation

Flat by default. The recorder is a single surface with tonal separation: near-black background, slightly lighter panels (track strips, settings). Depth comes from focus and state changes, not shadow layers.

Shadows exist only where they serve a structural purpose: dropdown menus, dialogs, and tooltips that must visually separate from the surface beneath. Even then, shadows are subtle — a tight 0–4px blur at low opacity, enough to lift without calling attention to themselves.

**Named Rules**
- **The Flat-at-Rest Rule.** All surfaces are flat when inactive. Elevation (subtle shadow or glow) appears only as a response to state: hover, focus, or overlay presence. No decorative layering.

## 5. Components

All native UI components live in `odin/src/ui/`; `odin/src/ui_window.odin` is the thin SDL3/vinland window adapter. `view.odin` composes the vinland-ui element tree; `theme.odin` is the single source of colour, space, type and metric tokens; `app.odin` owns state and key handling; `text_edit.odin` and `text_field_view.odin` own the settings text fields. Knobs, meters and FX graphs use vinland canvas primitives (`draw_line`, `draw_arc`, `draw_area`). The Cairo/Pango path in `draw.odin`/`canvas.odin` is the headless regression renderer.

**Transport bar** — amber-bordered REC / PLAY / STOP, timecode in tabular mono, BPM stepper. State is carried by fill, not by shadow: recording red, playing teal, idle ink-dim. The mix row keeps BOUNCE (canonical project bounce) primary and RENDER… (external WAV) secondary. RENDER… opens a compact panel with a dual-handle range track, three WAV format chips, a non-destructive note and one primary action. The handles use the amber signal fill; the active handle is brighter and its label turns amber, while the inactive handle stays a dark grip with an amber edge. The same panel is keyboard-complete.

**Transport states** — PLAY becomes a PAUSE button (two bars) while the tape rolls; STOP always returns to the marker. REC turns into an amber `PRE n` countdown (with an amber `PRE-ROLL` mode chip) while the guide plays before the punch point, then red. The bottom deck carries the two "how do I start a take" controls: the `PRE-ROLL n s` chip next to RHYTHM, and `MARK` plus its amber time chip (click to cue, `x` clears) beside the scrubber. The marker is a state, not a timeline: no ruler, no flags on a track.

**Track strip** — numbered header, `IN n` channel selector, `FX` badge row (lit label + `EQ · CMP · REV · DLY` summary), ARM/SOLO/MUTE toggles, pan knob, vertical fader, segmented meter. Selected = amber-dim border; armed = amber border; recording = red border with pulsing number; marked for bounce = bright amber border with a filled tick box beside the `FX` badge. Double-clicking the name edits it inline (amber border field). Below 200 px a strip goes compact (`IN n` button, single-letter A/S/M row, no pan knob or history, pan shown as text); below 120 px it keeps only the number, tick box, fader and meter.

**Track rail** — a thin row under the strips: `TRACKS − n +`, one small box per track (red = armed, amber = has audio, outlined = visible, ringed = marked or selected), the visible range with `‹ ›`, and `SHOW − n +` zoom. It keeps tracks that are off screen from being invisible.

**Bounce-to-track dialog** — the standard overlay panel: sources as amber chips, a grid of target boxes (marked tracks disabled), one honest line about whether the target already holds audio, and `BOUNCE` / `CANCEL`.

**Key sheet (F1)** — the standard overlay panel with the amber-bordered header "Keys · <context>" and three columns of sections; keys are amber mono, descriptions ink-dim. Only keys valid in the current context appear.

**FX rack** (`view.odin` / `app.odin`) — a horizontal instrument rack above the bounce row.
- Header: `FX`, channel tabs for four tracks at a time plus `MST` (`‹ ›` page when there are more tracks) (a 3px dot marks a channel with active effects), channel name, interaction hint, close.
- Modules: numbered `01…05`, power switch (`ON` amber / `BYP` dim), a response visual, a knob row, and a readout footer. Bypassed modules dim to 40% but stay editable-free (knobs disabled).
- Overflow: the chain scrolls horizontally with edge chevrons; the wheel scrolls it too.
- Channels: track = `EQ · COMP · SEND`; master = `COMP · REVERB · DELAY · WIDTH · LIMITER`.
- Visuals are derived from the actual DSP parameters: EQ magnitude curve with draggable nodes, compressor transfer curve + GR meter, reverb RT60 envelope with pre-delay and early reflections, delay repeats with L/R lanes, vectorscope for width, ceiling-clipped waveform for the limiter.

**Knob** — the single control primitive for continuous values. 270° arc, amber value arc, pointer, label + real-unit readout. Drag (vertical, `Shift` = fine), wheel, arrow keys (`Home`/`End`, `PageUp`/`PageDown`), double-click reset. The selected module and real-unit readout are mirrored in the `--a11y-log` snapshot. Disabled at 35% opacity.

**Gain-reduction meter** — right-to-left amber fill over a 24 dB range, peak tick, numeric `−x.x dB`. Static peak after a render, animated at 20 Hz while audio plays.

**Command palette** — Vim `:` overlay, monospace, amber selection.

**Settings overlay** — grouped preferences (Storage, Audio, Appearance, Cloud) in the same panel style. One row is selected at a time with `j` / `k` or the arrows; `Enter` edits the folder or runs the row. The project-folder row is a full-width monospace path field with an `EDIT` affordance, followed by BROWSE / APPLY / DEFAULT. Clicking a field enters an explicit EDIT state (`EDIT` chip in the status bar); `Enter` applies and `Esc` asks once before discarding. Click or `Tab`/`Shift+Tab` switches between text fields while preserving drafts. The field shows a real caret and selection: click positions it, drag selects, Shift+click extends, double-click selects a word and triple-click selects the line. Arrows/Home/End and their Shift/Ctrl variants move or select; `Ctrl+A` selects all and the next type/paste/backspace replaces it; `Ctrl+C`/`X`/`V`/`Z`/`Y` use the clipboard and undo. Secrets are always rendered as `*`, including in EDIT. New settings are added as rows inside an existing group so the panel scales.

**Cloud section** — a visible, named Google Drive folder (`Tracker` by default), Client ID/secret fields, a connection row with `CONNECT`/`DISCONNECT`, and `BACK UP NOW` / `RESTORE…`. Transfer status uses a thin amber progress bar and the same mono labels; no cloud illustrations, cards, or dashboard chrome. The keyboard-selected cloud row scrolls into view.

**Cloud projects overlay** — compact list of remote projects with name, short cloud id, modified time and size. Same overlay shell and amber selection as Recents; `Enter` restores, `U` backs up the current project, `R` refreshes. Disconnected and empty states teach the next action.

**Status line / rhythm / tape scrubber bar** — status bar shows mode badge, transient message, project title (`untitled` click / `n`), hardware rate, and key hints. Below it, the bottom deck bar pairs the metronome controls on the left (`RHYTHM`, time signature, meter readout) with a hardware-inspired centered **Tape Scrubber** (`|◄` return-to-zero button, `SHUTTLE` coarse wheel `5.0s` / `1.0s` Shift / `0.25s` Ctrl|Alt, `JOG` fine wheel `250ms` / `50ms` Shift / `10ms` Ctrl|Alt, plus loaded `/ MM:SS.s` tape length) and latency/redo/palette controls on the right. Each wheel is a 24×24 milled canvas platter with knurl ticks and a rotating amber finger-well dimple, highlighting in amber while dragged, hovered with Shift/Ctrl/Alt, or cued (`00:00:00.000` turns amber in the transport bar).

### Interaction vocabulary
- Buttons: 1px border, flat; hover fills with the 8–12% tint (`amber_bg`, `teal_bg`, `red_bg` semantic tokens).
- Toggles: filled on-state plus a model flag; chips (`AUTO`, `SYNC`, `P·P`) are the compact form.
- Focus: 1px amber outline, 1–2px offset, never removed.
- Nothing is a modal unless it must be (command palette, settings, project/cloud browser).

## 6. Do's and Don'ts

### Do:

- **Do** use the amber primary for recording state, transport controls, meters, and track selection — the color IS the identity.
- **Do** provide a Vim keybinding for every action. The keyboard is the primary interface.
- **Do** use the right input affordance for each control: sliders for EQ and levels, toggles for arming and muting, buttons for transport.
- **Do** keep the surface dark and flat. The screen should recede during a recording session so the musician focuses on performance, not chrome.
- **Do** use white text on saturated color fills (amber buttons, red recording indicator, teal overdub badge).
- **Do** maintain ≥7:1 contrast for body text against the background surface. Studio environments have variable lighting.
- **Do** respond to every state change with purposeful, fast motion (150–250ms). Recording glow, meter bounce, mode transitions.
- **Do** respect the in-app **Reduced motion** setting: replace transitions with instant state changes when it is on.

### Don't:

- **Don't** build a timeline, arrange window, or waveform grid. This is not a DAW. There is no clip-based editing. Arm, level, record, listen.
- **Don't** replicate Pro Tools / Cubase complexity — tiny targets, cluttered toolbars, modal overload, dozens of nested menus.
- **Don't** use GarageBand-style toy aesthetics: friendly icons, guided tutorials, rounded-everything, beginner-first language.
- **Don't** apply SaaS dashboard conventions: white cards, blue CTA buttons, elevation shadows, onboarding wizards. This is a tool, not a service.
- **Don't** use display fonts in UI labels, buttons, or data readouts. One mono family carries everything.
- **Don't** tint the background toward warm. The near-black surface stays at chroma 0. The amber primary carries all the warmth.
- **Don't** use decorative motion. Animation conveys state (recording, playback, metering, mode change) — nothing else.
- **Don't** use gradient text, glassmorphism, side-stripe borders, or identical card grids. None of these belong in an instrument panel.
- **Don't** ship half-states. Every interactive component has default, hover, focus, active, disabled, and loading states.
- **Don't** use modals as a first resort. Exhaust inline and progressive disclosure alternatives before reaching for a dialog.
