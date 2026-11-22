# Tracker design/UX review — d39946d

Method: design review only (native app; no web detector). Reviewed the shipped vinland window offscreen with `VUI_HIDDEN=1 VUI_PORT=7451` (llvmpipe, `unknown_classes: []`, 3–16 ms frames) at 1180x760, 900x620, 1440x900 and 1920x1080, plus the Cairo `ui-shot`/`ui-test` harness and `tests/ui/full-tour.json` (1x and 2x). The `real-*.png` files in this directory are the shipped window; `main-*.png` and `tour/` are the Cairo regression renderer.

## (a) Verdict

A genuinely specific instrument aesthetic — one JetBrains Mono family, pure near-black, flat 1 px surfaces, one amber accent — wrapped around an unfinished panel. The core loop is physically undersized: a 64 px fader and 8 px meter sit in a 577 px strip that is 62% empty, the transport is duplicated, the keyboard is barely taught, and Settings hides the Cloud connect action at the default window size. The Cairo regression surface is a different, older composition (red armed borders vs amber, 270 px faders vs 64 px, no take rows), so visual QA is currently green on a UI users never see. I would score the shipped surface **23/40 (Acceptable)** on Nielsen heuristics: strong identity, weak hierarchy, legibility and control placement.

## What's working

- The identity is specific and coherent: one JetBrains Mono family, near-black flat surfaces, 1 px rules, and one amber accent. It reads like studio gear, not a DAW or a SaaS dashboard. The native's all-mono typography is stronger and more distinctive than the Cairo harness's Inter labels.
- The recording state is immediately legible in the native window: red strip border, filled red ARM, red input history, filled REC. Arm/solo/mute are compact and the take row (`TAKE 1/3`, `COMP`, `EMPTY`) is a genuinely good model.
- The render dialog and command palette are the most finished surfaces: compact, content-sized, clear primary/secondary actions, complete in-panel keyboard hints, and a dual-handle range whose active handle is visibly different (filled vs edged). The FX visualisations (EQ curve, transfer curve, reverb envelope, delay lanes, vectorscope, limiter ceiling) are product-specific rather than generic.

## (b) Prioritized findings

### 1. [P1] The harness and the shipped window are two different products
Screenshots: `/tmp/opencode/audit-design/main-1180.png` vs `real-main-1180.png`; `tour/43-fx-track.png` vs `real-armed-default.png`; `settings.png` vs `real-settings.png`.
- Armed strip: Cairo red border (`draw.odin:345-362`, `border = T.color.red`), shipped amber border (`view.odin:455-456`, `border-sig-dim`). The shipped state semantics are correct per DESIGN.md; the harness is not.
- Geometry: Cairo fader ~270 px tall; shipped `h-16` = 64 px (`view.odin:554`). Cairo has no TAKE row, bounce row, or rhythm row; the shipped window has all three (`view.odin:583-616`, `1198-1245`, `1288-1323`).
- Settings: Cairo has Storage/Audio/Appearance only; shipped has a CLOUD group (`view.odin:1640-1699`). Cairo labels use Inter; shipped is JetBrains Mono (README:143, 440-450).
- Design tokens are duplicated, not shared: `view_theme` redefines the palette and OKLCH values at `view.odin:83-107`; `theme.odin` calls itself the single source, but the shipped UI does not consume its radii (2 px vs 4/8/12/16), space, or type (9 px vs micro 10). At 900 the Cairo hint silently drops `B` and `X`; the shipped hint is different again.
- Consequence: a green `make e2e`/ui-shot does not prove the native window. The clipped Settings panel and clipped master FX chain below were not caught by the Cairo screenshots.
- Fix: make `view.odin` canonical, port `theme.odin` tokens into it, and regenerate or retire the Cairo visual surface; do not polish `draw.odin` and assume it ships.

### 2. [P1] The primary "level" stage is the smallest thing on screen
Screenshots: `real-main-1180.png`, `real-armed-default.png`, `real-1920.png`.
- Track card at 1180 is 283×577; controls end at y≈206; the footer starts at y≈565. **358 px, 62% of the card, is empty** before the 32 px input history and take row. At 1920 the card is 458×976 and the void is ~760 px.
- The fader is 24×64 with a 16×16 handle (`view.odin:554-574`); the meter is **8 px wide × 80 px tall** (`meter_ui`, `view.odin:650-653`). The level readout is 11 px at **2.9:1** (`view.odin:576`), with no dB scale and only an unlabeled unity tick (`view.odin:571-572`). The input history is 32 px high at the very bottom and has no label (`view.odin:585-588`).
- The control group is left-packed: x≈30–184 inside a 25–282 content box, leaving ~98 px of dead space to its right at 1180 and ~276 px at 1920.
- This contradicts PRODUCT.md's core loop, "arm, level, record, listen": the level stage has less visual weight than the empty surface.
- Fix: make the meter/history the centrepiece: `h-16`→`h-40` fader, `h-20`→`h-40` meter and `w-2`→`w-3` (`view.odin:650-653`), `h-8` history→`flex-1 min-h-12`, remove `mt-auto` and let the history fill the void. Put the readout under the fader in `text-ink-dim` at 12 px with a `+` sign, and add an empty-state "ARM TO MONITOR" label.

### 3. [P1] The transport is duplicated and the record/stop hierarchy is inverted
Screenshots: `real-playing.png`, `real-recording-default.png`, `real-main-1180.png`.
- At rest there are two PLAY buttons: header (`view.odin:313-323`) and mix row (`view.odin:1211-1222`). During playback both turn into STOP, beside a third dedicated STOP that stays dim (`view.odin:324-330`): three stop affordances, two of them labelled STOP, one of them low-contrast.
- The dedicated STOP stays `text-ink-dim` even while recording — the emergency exit is the quietest action on screen. REC at rest is borderless 12 px red text at **3.03:1** (`view.odin:305-307`), so it reads as a status light, while the passive 62×20 NORMAL badge (`view.odin:301`) is the strongest left-header element.
- BOUNCE/RENDER/UNDO ("BOUNCE" label plus "BOUNCE" button) fill the mix row while the 64 px fader is the thing that needed the space.
- Fix: one transport. Delete the mix-row play, keep one high-contrast STOP, make REC a real button (filled `bg-rec text-ink` or bordered `bg-rec-bg text-rec-hi`), and label the play toggle PAUSE/icon rather than a second STOP. Remove the duplicate BOUNCE label.

### 4. [P1] Keyboard-first is promised, but not taught or consistently implemented
Screenshots: `real-palette-j.png`, `real-io.png`, `real-main-1180.png`.
- The only persistent keyboard hint is `j/k: nav  J/K: vol  : command` (`view.odin:1262`). It omits `A` arm, `R` record, `Space` play, `B` bounce, `Shift+B` render, `X` FX, `I` I/O, `,` settings and `G` cloud. Those bindings exist (`input.odin:1598-1645`), but the discovery surface hides them.
- The command palette — the app's Vim `:` surface — supports arrows but not `j`/`k` (`input.odin:666-695`). Typing `j` filters the list to "jack capture" (`real-palette-j.png`); it does not move the selection. The recent picker behaves the same (`input.odin:706-734`), while Settings uses `j`/`k` for down/up (`input.odin:1068-1070`) and the main track row uses `j` for left/previous (`input.odin:1630-1636`). One app, three meanings.
- The I/O picker is pointer-only: no `.Io` branch in the mode dispatch (`input.odin:1520-1545`), and its hint says "click: select" (`view.odin:1268`). Pressing `j`/`k` while the I/O panel is open silently changes the selected track behind the modal.
- Fix: add `j`/`k` to palette/recent, add an I/O key handler (↑↓/j/k, Enter, Esc), show the core transport/arm keys in the status line (or a `?` cheat sheet), and make the palette's right column show the binding (R, Space, B, Shift+B, X…) instead of a category.

### 5. [P1] Settings clips the Cloud connect action at the default size, and breaks at 900
Screenshots: `real-settings.png`, `real-settings-900.png`, `real-settings-900-cloud2.png`, `real-cloud.png`.
- The panel is 700×639 at y=80, but its content extends to y≈857 (tree). The Google Drive row starts at y=716 and BACK UP NOW/RESTORE at y=748 — below the panel viewport (it ends at 719). The CLOUD group's actual connect action is effectively invisible at 1180×760, with only a hairline scrollbar as a cue. The wheel did not move the panel in the offscreen test.
- At 900×620 the panel is taller than the window (it ends at 719 in a 620 window). When `j` reaches the Cloud fields the panel scrolls, but the "Settings" header and section labels scroll out of view (`real-settings-900-cloud2.png`), leaving a bare "Project folder" at the top and a clipped bottom.
- The Cloud overlay's only action is OPEN SETTINGS (`view.odin:1782-1786`); it leads to this hidden CONNECT. The working action has no visible keyboard binding, and the overlay still advertises ENTER restore / U / R for a disconnected state (`view.odin:1831`).
- Fix: make the overlay padding viewport-safe (`OVERLAY` `pt-20`→`p-4`, settings `max-h-[94%]`→`max-h-full`), make the header sticky, put the Settings hints inside the panel, and move CONNECT next to the credentials or split the panel into sections. Do not let a modal exceed the window.

### 6. [P1] Contrast and type are below the product's own accessibility bar
Screenshots: `real-main-1180.png`, `real-armed-default.png`, `real-fx-master.png`; measured from the PNGs.
- `ink-muted` is oklch(0.48) (`view.odin:94`). On canvas it renders at **2.5–3.1:1**: EMPTY 2.51, TAKE 2.80, fader value 2.89, hint/project line 3.08. `rec` red text renders at **3.03:1** (idle REC, ARM). These are 9–11 px labels; WCAG AA requires 4.5:1 and DESIGN.md asks for 7:1 body text.
- The fader level, take state, device/project line, and the keyboard/shortcut hint — the exact data a recordist needs — are all in the darkest ink. High contrast lifts `ink-muted` to 0.68 and measures 6.4:1, but that is opt-in and not the default.
- Type is compressed to 9–13 px (FX chips 9, knob labels 9, take row 9–10, track name 12, modal title 14); no 20–25 px heading appears in the shipped window despite the type scale. The `Type_Tokens` values themselves disagree with their comments (theme.odin:211-229).
- Fix: `ink-muted` 0.48→0.58 (≈4.9:1), use `ink-dim` (6.4:1) for data, use `rec-hi`/a lighter red for text or fill the REC button, raise 9 px to 10 px minimum, and verify with a contrast test.

### 7. [P1] The master FX chain clips at 900 and hides the limiter
Screenshot: `real-fx-master-900.png`; also `real-fx-master.png`.
- At 900 the master rack shows COMP, REVERB, DELAY and part of WIDTH. DELAY loses its RET control; WIDTH is cut; LIMITER (the last safety stage) is absent. There is no chevron, scrollbar, or "more" cue; the only hint is drag/scroll for knobs. The modules have `min-w-[214px]` (wide modules 256) (`view.odin:866-868`), so five cannot fit in 876 px.
- At 1180 the 5 modules fit, but the rack is a wall of 9 px labels and 26 px knobs; the focused readout is in the far footer.
- Fix: add visible edge chevrons/scrollbar and pin the LIMITER, or wrap the master chain to two rows / shrink the modules with a 3+2 layout at 900; raise the module labels to 10 px.

### 8. [P2] Four bottom bands repeat the same status and split related controls
Screenshot: `real-main-1180.png`, `real-playing.png`.
- Header 45 + mix row 44 + status 26 + rhythm 44 = **159 px (21% of 760)**. "Ready" (`view.odin:1234-1242`) and "ready" (`:1254`); NORMAL twice (`:301`, `:1250`); the device name twice (`:376`, `:1261`); recording is signalled by the top badge, the REC button, the status badge and "Recording" (`:1240`) — four times.
- The metronome is labelled "RHYTHM OFF" in its own bottom bar (`:1288-1300`), isolated from BPM in the header (`:335-356`). UNDO is in the mix row (`:1208`) and REDO in the rhythm row (`:1308`); LAT and ":" share the rhythm row with no grouping. At 900 this costs 114 px of track height.
- BOUNCE vs RENDER… are adjacent synonyms; the surface never says "project bounce" vs "export WAV", and the palette files both under "render".
- Fix: merge status + rhythm into one 26 px line; keep one mode badge; move REDO next to UNDO, LAT into Settings, and CLICK next to BPM; remove the mix-row PLAY and the "BOUNCE" label.

### 9. [P2] Selected and armed share the same amber border
Screenshots: `real-error-arm.png` (Track 2 selected, not armed) vs `real-armed-default.png` (Track 1 selected and armed).
- `border-line-sig` for selected and `border-sig-dim` for armed (`view.odin:455-458`) are both dark amber; the number is amber in both (`:467`). Clicking ARM also selects the track (`:514`), so armed tracks are always selected and the border is the armed amber; a selected-but-unarmed strip still has an amber border. The only reliable difference is the 31×17 ARM fill, which gets a red hover outline (`real-error-arm.png`) that reads as another on-state.
- Fix: reserve the amber strip border for armed, use a neutral raised surface + 1 px left rule for selection, and/or add an "ARMED" tag in the header; keep red exclusively for recording.

### 10. [P2] FX summary hover "x" and channel dots are ambiguous
Screenshots: `real-hover-fxchip.png`, `real-fx-track.png`.
- The FX row is an ~19 px-high, 9 px-text pill; on hover a tiny `x` appears at its right (`view.odin:490-507`). `x` convention means close/remove, but clicking opens the FX rack. The row otherwise lacks an affordance (no chevron/EDIT).
- Active-effect dots are 3 px at the tab's top-right (`view.odin:758-762`); the tabs read like `1° 2° 3° 4°` rather than "channel 2 has effects".
- Fix: use a chevron/“EDIT FX” (no x on hover), make the row 20–24 px, and put the active dot under the tab label as a 4 px bar or filled background.

### 11. [P2] The toast duplicates the status line and covers track content
Screenshot: `real-error-arm.png`, `real-cloud.png`.
- `absolute bottom-28 right-4` (`view.odin:168-170`) puts the toast 112 px above the bottom, over Track 4's TAKE/EMPTY footer (e.g. "arm a track first" at 1018–1164, y=618–648). The same message is already in the status line (`app.odin` sets both). The Cairo toast uses a different anchor (`draw.odin:522-531`), so this is also a surface mismatch.
- Fix: keep one message channel; place a transient above the status bar without covering the take row, or rely on the status line alone.

### 12. [P2] Above 1180 the shipped window sprawls instead of scaling
Screenshots: `real-1440.png`, `real-1920.png`; compare `main-1920.png` (harness zooms 1.52x).
- At 1440/1920 the type stays 9–13 px and the fader/meter stay 64/80 px; the track strips grow to 458×976 and the control cluster stays in the top-left with ~760 px of empty body. The Cairo harness applies `ui_zoom_for_window` up to 1.8x; the native window does not (README:460-463).
- Fix: apply a bounded native UI zoom (1.0–1.4x by window height) or cap the 4-track field at `max-w-[1600px] mx-auto` and let the meter/history occupy the extra height. At 1920 the 10 px labels are physically too small.

### 13. [P2] Cloud copy and actions mislead
Screenshots: `real-cloud.png`, `real-settings.png`.
- "Google Drive · hidden app data" (`view.odin:1779`) contradicts the product's visible, named My Drive folder (AGENTS). The disconnected empty state shows ENTER restore / U back up / R refresh (`:1831`) for actions that fail, while the only working action (OPEN SETTINGS) has no key binding. The destination of OPEN SETTINGS hides CONNECT below the fold (finding 5).
- Fix: say "Google Drive · Tracker folder" (or the real folder name), hide/disable unavailable commands, show "ENTER open settings", and keep CONNECT visible.

### 14. [P2] Reduced motion is a setting the shipped animations ignore
Source evidence; screenshot `tour/191-reduced-motion.png` (Cairo honours it), `real-recording-default.png` (native still pulses).
- `a.reduced_motion` is toggled (`app.odin:1962`) and used by the Cairo renderer (`draw.odin:356`) and the text caret (`text_field_view.odin:81`), but the shipped view has unconditional `animate-pulse` on the REC button (`view.odin:305`), the recording number (`:467`) and the palette caret (`:1358`).
- Fix: gate those classes with `!a.reduced_motion` (conditional `vui.cx`), and test the native window with the setting on.

## (c) Three highest-leverage improvements

1. **Re-proportion the track strip around the meter.** In `view.odin`, change the fader `relative h-16 w-6` (554) to `relative h-40 w-8`, the meter call `"h-20"` (580) to `"h-40"` and the meter width `w-2` (653) to `w-3`; change the history `h-8` (588) to `flex-1 min-h-12`; remove `mt-auto` from the footer (584); make the control row `items-stretch justify-between` (509). Put the level readout under the fader at 12 px in `text-ink-dim` with a sign, add a 0 dB mark, and show "ARM TO MONITOR" when the strip is idle. Raise `ink-muted` 0.48→0.58 (view.odin:94) and stop using it for data; use `ink-dim` (0.65) for the level/take values.
2. **One transport, one status line.** Delete the mix-row PLAY (1211-1222) and the "BOUNCE" label (1200); keep one dedicated STOP and make it high-contrast (`text-ink` + border, not `text-ink-dim` at 324); style REC as a real button (filled `bg-rec text-ink` or bordered `bg-rec-bg text-rec-hi`) and label the play toggle PAUSE/icon-only. Remove the rhythm bar (1288-1320), move CLICK next to BPM (335-356), move REDO beside UNDO (1308→1208), and keep one mode badge and one "Ready"/"ready" message. This alone frees 44–88 px of vertical space and removes three duplicate actions.
3. **Make the overlays fit and the keyboard complete.** Change `OVERLAY` `pt-20` (1325) to `p-4` and the Settings `max-h-[94%]` (1507) to `max-h-full`; make the panel header sticky, add a footer inside with the `j/k select · enter run · b browse · esc close` hints, and move CLOUD/CONNECT above the fold. Add `j`/`k` to `app_palette_key` (input.odin:666) and `app_recent_key` (:706), add an I/O mode key handler (:1520-1545), and replace the status hint at view.odin:1262 with the core bindings (`a arm · r rec · space play · b bounce · shift+b render · x fx · i io · , settings · : commands`) or a `?` cheat sheet. Gate `animate-pulse` on `!a.reduced_motion` (305, 467, 1358).

## (d) Broken vs taste

**Actually broken**
- Settings clips the Cloud connect/backup/restore rows at 1180x760 and exceeds the window at 900x620; the title scrolls away (`real-settings.png`, `real-settings-900.png`, `real-settings-900-cloud2.png`). The Cloud empty state's OPEN SETTINGS leads to a hidden CONNECT (`real-cloud.png`).
- Master FX at 900 drops DELAY's RET control, cuts WIDTH and hides LIMITER with no scroll cue (`real-fx-master-900.png`).
- `j` in the command palette filters instead of moving the selection (`real-palette-j.png`); `j`/`k` in the I/O panel silently changes the track behind the modal.
- Default text contrast: 2.5–3.1:1 for take state, fader value, hints and device/project line; 3.03:1 for idle REC/ARM, at 9–11 px.
- Reduced motion does not disable the shipped recording pulse or the REC button pulse.
- Toasts cover Track 4's TAKE/EMPTY footer and repeat the status message (`real-error-arm.png`).
- The Cairo `ui-shot`/`ui-test` surface differs from the shipped window in state colors, layout, fonts and available panels, so visual regression is false-green.
- The header I/O name is truncated to "Scarlett…" at 900 with no tooltip and repeated in the status line (`real-900.png`).

**Inconsistent**
- Amber border means selected or armed; ARM/SOLO/MUTE use red/teal/gray on-states; High contrast/Reduced motion use teal; BOUNCE mode uses the recording red; `REC` text is dark red while the filled REC button is bright.
- UNDO lives in the mix row and REDO in the rhythm row; BPM is in the header and its CLICK is "RHYTHM OFF" in the footer.
- Units: fader "-2dB" (`view.odin:425-430`), master "-24.0" with no dB (`:1232`), "48000 Hz" in the recording message vs "48 kHz" in the same status bar (`:1261`); knob values mix "+0.0" without dB, "12ms" without a space, "3.0:1".
- "BOUNCE" and "RENDER…" are adjacent synonyms with no surface explanation of project-bounce vs external-WAV.

**Taste / design-system debate**
- The identity is strong: all-mono, pure near-black, one amber, no shadows, no card grid. Keep it.
- The 2 px radii versus theme.odin's 4/8/12/16 and the 9 px type versus the token scale are a deliberate instrument look, but the docs call theme.odin the source of truth; decide which one wins.
- The huge empty strip could be intentional negative space. The problem is not the emptiness itself, it is that the fader and meter are too small to anchor it.
- Amber covers far less than DESIGN.md's 30–60% of the surface at rest. A quiet idle is defensible for a studio; if the committed-color rule matters, put the amber in the meter/history, not more chrome.
- "NORMAL" is Vim jargon for a musician; "READY" or no mode chip may be better. The all-dark theme with no light mode is right for the stated night-studio scene.
- Top-anchored overlays, thin master meter, and dense FX module cards are taste; the clipping and the missing keyboard paths are not.
- Mouse targets are small: IN chips 17×15, ARM/SOLO/MUTE ~31×17, fader handle 16×16, COMP 9 px text. Keyboard-first mitigates this, but the mouse is not "available" for everyone at these sizes.
- The project identity ("untitled") is only in the 11 px status line and the save action is only in the palette; that is a product decision, not a visual bug.

## Evidence index

Native (shipped window, 7451): `real-main-1180.png`, `real-900.png`, `real-1440.png`, `real-1920.png`, `real-armed-default.png`, `real-recording-default.png`, `real-playing.png`, `real-fx-track.png`, `real-fx-master.png`, `real-fx-master-900.png`, `real-fx-focus.png`, `real-settings.png`, `real-settings-900.png`, `real-settings-900-cloud2.png`, `real-cloud.png`, `real-io.png`, `real-palette.png`, `real-palette-j.png`, `real-render.png`, `real-render-from.png`, `real-error-arm.png`, `real-hc.png`, `real-hover-fxchip.png`, `real-hover-arm2.png`.

Cairo regression: `main-1180.png`, `main-900.png`, `main-1440.png`, `main-1920.png`, `main-1180@2x.png`, `fx-track.png`, `fx-master.png`, `settings.png`, `cloud.png`, `palette.png`, `io.png`, `bounce.png`, `recording.png`, `playing.png`, `tour/` (220-action run, all passed).
