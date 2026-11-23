---
trigger: glob
globs:
  - odin/src/**/*.odin
  - odin/Makefile
  - odin/scripts/check.sh
---

# Platform Isolation & Cross-OS Rules

1. **Zero `when ODIN_OS` in shared files**:
   Never add `when ODIN_OS` inside shared modules (`engine.odin`, `capture.odin`, `cloud_oauth.odin`, `file_dialog.odin`, `ui_window.odin`, `ui/app.odin`, `ui/view.odin`, `ui/draw.odin`, `ui/canvas_common.odin`).

2. **Isolate OS specifics in `#+build` files**:
   Put OS-specific implementations in:
   - `odin/src/platform_{linux,darwin,other}.odin`
   - `odin/src/file_dialog_{linux,darwin,other}.odin`
   - `odin/src/jack_capture_{linux,other}.odin`, `odin/src/jack_session_{linux,other}.odin`
   - `odin/src/ui/platform_{linux,darwin,other}.odin`
   - `odin/src/ui/canvas_{cairo_linux,soft_other}.odin`, `odin/src/ui/font_runtime_{linux,other}.odin`

3. **Multi-negation build tag syntax**:
   Odin requires separate `#+build` lines for AND semantics on fallback files:
   ```odin
   #+build !linux
   #+build !darwin
   ```
   Never write `#+build !linux !darwin` on one line.

4. **Signature parity & handoff**:
   When changing any `platform_*`, `file_dialog`, `jack_*`, or `canvas_*` procedure signature, update every OS variant in the same commit. If you edit a `#+build linux` or `#+build darwin` file that you cannot compile/run locally, add a checkbox item under **Pending Cross-OS Verification** in `PLATFORMS.md`.
