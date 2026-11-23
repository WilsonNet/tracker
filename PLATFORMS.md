# Cross-Platform Matrix & Verification Handoff

Tracker runs natively on **Linux** and **macOS** from one Odin codebase, with OS-specific boundaries isolated behind Odin `#+build` files.

> [!IMPORTANT]
> **Session Workflow:** Read [Pending Cross-OS Verification](#pending-cross-os-verification) at the start of any coding session. Clear checkboxes verified on your current OS, and add a checkbox whenever you modify OS-specific code for the *other* OS that you cannot run locally.

---

## Platform Matrix

| Layer | Linux (`#+build linux`) | macOS (`#+build darwin`) | Other (`#+build !linux` + `#+build !darwin`) |
|---|---|---|---|
| **Native Window Graphics** | Vulkan (preferred) / OpenGL 3.3 fallback via `vinland-ui` | Metal (preferred) / OpenGL 3.3 fallback via `vinland-ui` | Via `vinland-ui` |
| **Primary Audio Engine** | `vendor:miniaudio` (PipeWire / PulseAudio / ALSA, `PULSE_CHANNEL_MAP_AUX`) | `vendor:miniaudio` (CoreAudio, native unmixed channel order) | `vendor:miniaudio` |
| **Secondary Audio Backend** | Cooperative JACK (`--jack`, `libjack`) | Disabled (`platform_supports_jack() == false`) | Disabled |
| **Headless Harness Canvas** | Cairo image surface + Pango text (`Inter`, `Noto Sans Mono`) | Pure-Odin software rasterizer + embedded `vendor:stb/truetype` | Pure-Odin software rasterizer + embedded `vendor:stb/truetype` |
| **Native File/Folder Picker** | `zenity` (fallback `kdialog`) | `osascript` Cocoa panels | Disabled (`"", false`) |
| **Browser OAuth Opener** | `xdg-open` / `gio open` / `sensible-browser` | `open <url>` | Disabled (`false`) |
| **Primary Text Shortcut** | `Ctrl` (`.LCTRL` / `.RCTRL`) | `Cmd` (`.LGUI` / `.RGUI`) and `Ctrl` | `Ctrl` |
| **Unit Test Count (`make test`)** | **276** (71 DSP + 131 core + 74 UI) | **270** (71 DSP + 125 core + 74 UI; 6 JACK session tests Linux-only) | **270** |

---

## OS-Isolated Module Map

Never add `when ODIN_OS` conditionals inside shared files (`engine.odin`, `capture.odin`, `cloud_oauth.odin`, `file_dialog.odin`, `ui_window.odin`, `ui/app.odin`, `ui/view.odin`, `ui/draw.odin`, `ui/canvas_common.odin`).

| Concern | Shared API | Linux (`#+build linux`) | macOS (`#+build darwin`) | Fallback (`#+build !linux` + `#+build !darwin`) |
|---|---|---|---|---|
| **Audio / OS utilities** | `capture.odin`, `cloud_oauth.odin`, `ui_window.odin`, `audit_perf_test.odin` | `platform_linux.odin` | `platform_darwin.odin` | `platform_other.odin` |
| **File & folder pickers** | `file_dialog.odin` | `file_dialog_linux.odin` | `file_dialog_darwin.odin` | `file_dialog_other.odin` |
| **JACK CLI capture** | `jack_capture.odin` | `jack_capture_linux.odin` | `jack_capture_other.odin` (`!linux`) | `jack_capture_other.odin` (`!linux`) |
| **JACK GUI session** | `jack_session.odin` | `jack_session_linux.odin`, `jack_session_test.odin` | `jack_session_other.odin` (`!linux`) | `jack_session_other.odin` (`!linux`) |
| **UI backend labels** | `ui/view.odin`, `ui/draw.odin`, `ui/app.odin` | `ui/platform_linux.odin` | `ui/platform_darwin.odin` | `ui/platform_other.odin` |
| **Headless canvas & fonts** | `ui/canvas_common.odin` | `ui/cairo_ffi.odin`, `ui/canvas_cairo_linux.odin`, `ui/font_runtime_linux.odin` | `ui/canvas_soft_other.odin`, `ui/font_runtime_other.odin` (`!linux`) | `ui/canvas_soft_other.odin`, `ui/font_runtime_other.odin` (`!linux`) |

---

## Quick Verification Commands

### macOS (`darwin_arm64`)
```sh
cd odin
make build && make test && make check
make e2e
odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui
# Metal + GL live control check:
VUI_HIDDEN=1 VUI_PORT=7421 ./bin/tracker-odin ui --demo --session /tmp/tracker-check
# CoreAudio hardware check (with audio interface connected):
./bin/tracker-odin devices
./bin/tracker-odin record --seconds 2 --channels 2 --device 0 --out /tmp/tracker-hw
```

### Linux (`linux_amd64`)
```sh
cd odin
make build && make test && make check
make e2e
odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui
./scripts/check.sh --hardware --jack --loopback
```

---

## Pending Cross-OS Verification

- [ ] **Linux (`linux_amd64`)**: Verify split `#+build linux` modules (`platform_linux.odin`, `file_dialog_linux.odin`, `jack_capture_linux.odin`, `jack_session_linux.odin`, `jack_session_test.odin`, `ui/platform_linux.odin`, `ui/cairo_ffi.odin`, `ui/canvas_cairo_linux.odin`, `ui/font_runtime_linux.odin`), updated `odin/Makefile` (`$(ODIN) root`), `odin/scripts/check.sh`, `VUI_HIDDEN=1` file-dialog suppression in `file_dialog_linux.odin`, Tape Scrubber (`Ctrl`/`Alt` + `Shift` scroll/key modifiers and updated `main.png`/`min-size.png` baselines), and the 21-case `odin/tests/ui/window.vt` (`make build && make test && make check && make e2e && odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui`).
