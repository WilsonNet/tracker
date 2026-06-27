<!-- SEED: re-run /impeccable document once there's code to capture the actual tokens and components. -->

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
- **Amber Signal** `[to be resolved during implementation]`: The brand anchor. Used for the transport bar, recording state, track arm indicators, level meters, and primary action buttons. Vibrant but never fluorescent. The color of a hardware VU meter at night.

**Neutral**
- **Console Black** `[to be resolved during implementation]`: The background surface. Near-black, chroma 0. The canvas that lets amber carry the identity.
- **Panel Gray** `[to be resolved during implementation]`: Slightly lifted surface for track strips, channel controls, and setting panels. Same hue family as bg, pure neutral.
- **Signal White** `[to be resolved during implementation]`: Body text and high-contrast labels. Near-white, chroma 0. Clean, readable, no hidden warmth.
- **Dim Label** `[to be resolved during implementation]`: Secondary text and muted labels. Ink pulled toward bg at reduced contrast. Still ≥3.5:1 against the surface.

**State Semantic**
- **Recording Red** `[to be resolved during implementation]`: Recording indicator — a distinct red, not derived from the orange primary. Pulsing glow.
- **Overdub Teal** `[to be resolved during implementation]`: Overdub/solo state. Cool contrast to the warm primary. A second distinct hue used sparingly for state differentiation.

**Named Rules**
- **The No-Hidden-Warmth Rule.** The background is pure near-black (chroma 0). The orange primary carries all the warmth. Tinting the surface toward amber is prohibited — it muddies contrast and reads as a dim panel, not a precision instrument.
- **The White-on-Color Rule.** Any text on a saturated color fill (transport buttons, recording indicators, accent badges) uses white or near-white text. Dark text on amber reads as muddy. The Helmholtz-Kohlrausch effect makes saturated colors appear brighter than their luminance suggests.

## 3. Typography

**Primary Font:** Mono-forward — a single monospace or monospace-adjacent family `[font pairing to be chosen at implementation]`. No display/body pairing. One family carries headings, labels, buttons, meters, and body text.

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

No components exist yet. This section will be populated when `impeccable document` runs in scan mode after implementation begins.

Key component direction (non-normative preview):
- Transport controls: prominent, amber-filled, keyboard-bound (Space = play/stop, R = record, etc.)
- Track strips: horizontal or vertical channel controls with level meters, arm buttons, solo/mute, and pan
- Level meters: vertical/horizontal bars with amber fill, peak indicators, segmented for readability
- VU-style metering: smooth responsive motion tied to audio levels
- Modal overlays: used only when inline alternatives are exhausted (settings, project config)
- Command palette: Vim-style `:` command mode for actions without dedicated keybindings

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
