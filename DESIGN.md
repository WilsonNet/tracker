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

**Primary Font:** JetBrains Mono (fallback: Fira Code, Cascadia Code, Consolas). No display/body pairing. One family carries headings, labels, buttons, meters, and body text.

**Character:** Technical precision without feeling cold. The monospace choice aligns with the Vim-native, keyboard-first philosophy. Letters have clear differentiation (no ambiguous 0/O, 1/l/I). Reading rhythm feels natural, not mechanical.

### Hierarchy

- **Heading** (bold, 1.25rem–1.5rem): Section headers, track names, transport labels. Fixed rem scale, no fluid clamp.
- **Body** (regular, 0.875rem–1rem, 1.5 line-height): Prose, settings descriptions, help text. Max line length 65–75ch where prose appears.
- **Label** (medium, 0.75rem–0.8125rem, uppercase, 0.04em letter-spacing): Button labels, meter readouts, status indicators, keybinding hints.
- **Data** (regular, 0.8125rem–0.875rem, tabular-nums): Timecode, level readouts, track numbers. Monospace numbers align naturally.

**Named Rules**
- **The One-Family Rule.** One font family across the entire interface. Weight, size, and case create hierarchy — not font pairing. A second family is allowed only for timecode/timing displays where tabular-nums and monospace precision are critical.
- **The Fixed-Scale Rule.** Type sizes are fixed rem values, not fluid clamp. This is a tool viewed at consistent DPI, not a marketing page viewed across devices. Headings that shrink when the window narrows serve no purpose here.

## 4. Elevation

Flat by default. The recorder is a single surface with tonal separation: near-black background, slightly lighter panels (track strips, settings). Depth comes from focus and state changes, not shadow layers.

Shadows exist only where they serve a structural purpose: dropdown menus, dialogs, and tooltips that must visually separate from the surface beneath. Even then, shadows are subtle — a tight 0–4px blur at low opacity, enough to lift without calling attention to themselves.

**Named Rules**
- **The Flat-at-Rest Rule.** All surfaces are flat when inactive. Elevation (subtle shadow or glow) appears only as a response to state: hover, focus, or overlay presence. No decorative layering.

## 5. Components

All components live in `src/components/`. Shared tokens are in `src/styles/tokens.css`; the FX system has its own sheet (`src/styles/fx.css`).

**Transport bar** — amber-bordered REC / PLAY / STOP, timecode in tabular mono, BPM stepper. State is carried by fill, not by shadow: recording red, playing teal, idle ink-dim.

**Track strip** — numbered header, `IN n` channel selector, `FX` badge row (lit label + `EQ · CMP · REV · DLY` summary), ARM/SOLO/MUTE toggles, pan knob, vertical fader, segmented meter. Selected = amber-dim border; armed = amber border; recording = red border with pulsing number.

**FX rack** (`FxRack.tsx`) — a horizontal instrument rack above the bounce row.
- Header: `FX`, channel tabs `1 2 3 4 MST` (a 3px dot marks a channel with active effects), channel name, interaction hint, close.
- Modules: numbered `01…05`, power switch (`ON` amber / `BYP` dim), a response visual, a knob row, and a readout footer. Bypassed modules dim to 40% but stay editable-free (knobs disabled).
- Overflow: the chain scrolls horizontally with edge chevrons; the wheel scrolls it too.
- Channels: track = `EQ · COMP · SEND`; master = `COMP · REVERB · DELAY · WIDTH · LIMITER`.
- Visuals are derived from the actual DSP parameters: EQ magnitude curve with draggable nodes, compressor transfer curve + GR meter, reverb RT60 envelope with pre-delay and early reflections, delay repeats with L/R lanes, vectorscope for width, ceiling-clipped waveform for the limiter.

**Knob** — the single control primitive for continuous values. 270° arc, amber value arc, pointer, label + real-unit readout. Drag (vertical, `Shift` = fine), wheel, arrow keys (`Home`/`End`, `PageUp`/`PageDown`), double-click reset. `role="slider"` with `aria-valuetext` in real units. Disabled at 35% opacity.

**Gain-reduction meter** — right-to-left amber fill over a 24 dB range, peak tick, numeric `−x.x dB`. Static peak after a render, animated at 20 Hz while audio plays.

**Command palette** — Vim `:` overlay, monospace, amber selection.

**Status line / rhythm section** — mode badge, transient message, capture/record indicators, hint string; rhythm toggle at the right.

### Interaction vocabulary
- Buttons: 1px border, flat; hover fills with the 8–12% tint (`--amber-bg`, `--teal-bg`, `--red-bg`).
- Toggles: `aria-pressed` + filled state; chips (`AUTO`, `SYNC`, `P·P`) are the compact form.
- Focus: 1px amber outline, 1–2px offset, never removed.
- Nothing is a modal unless it must be (command palette only).

## 6. Do's and Don'ts

### Do:

- **Do** use the amber primary for recording state, transport controls, meters, and track selection — the color IS the identity.
- **Do** provide a Vim keybinding for every action. The keyboard is the primary interface.
- **Do** use the right input affordance for each control: sliders for EQ and levels, toggles for arming and muting, buttons for transport.
- **Do** keep the surface dark and flat. The screen should recede during a recording session so the musician focuses on performance, not chrome.
- **Do** use white text on saturated color fills (amber buttons, red recording indicator, teal overdub badge).
- **Do** maintain ≥7:1 contrast for body text against the background surface. Studio environments have variable lighting.
- **Do** respond to every state change with purposeful, fast motion (150–250ms). Recording glow, meter bounce, mode transitions.
- **Do** respect `prefers-reduced-motion`: replace transitions with instant state changes when the user requests it.

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
