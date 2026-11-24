# Verification matrix

Measured on Linux (Arch Linux, PipeWire 1.6.11, Odin `dev-2026-11-nightly`, 2026-11-17 through 2026-11-22) and **macOS** (Apple M4 `arm64`, macOS 27.2.1, CoreAudio + Metal / OpenGL 3.3, Odin `dev-2026-11`, 2026-11-23). The native port and cross-OS modularization are complete; details and intentional limits are in `ROADMAP.md` and `../PLATFORMS.md`.

## macOS verification (Apple Silicon, Metal + CoreAudio, 2026-11-23)

| check | command / mode | result |
|---|---|---|
| Build & `-vet` | `make clean && make build && odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui` | clean (`darwin_arm64`) |
| Unit tests | `make test` (`src/dsp`, `src`, `src/ui`) | **270 passed** (**71** DSP + **125** core + **74** UI; 6 Linux JACK tests excluded via `#+build linux`) |
| Offline check | `make check` (`scripts/check.sh`) | **PASS**: unit tests, `selftest`, **220/220** UI tour (`full-tour.json`, 17 valid PNGs via pure-Odin + `stb_truetype` harness), offline bounce, `ffprobe` `pcm_f32le` |
| Window e2e | `make e2e` (`vui-test tests/ui/window.vt`) | **21/21 passed** on Metal (`VUI_HIDDEN=1`) |
| Tape scrubber (`\|◄`, `SHUTTLE`, `JOG`) | `vui-ctl` + unit/engine tests + `window.vt` | Hover scroll & drag on dual platters (`5.0 s` / `1.0 s` Shift / `0.25 s` Ctrl\|Alt; `250 ms` / `50 ms` Shift / `10 ms` Ctrl\|Alt), keyboard (`h/l`, `H/L`, `Ctrl\|Alt+h/l`, `</>`, `0`), palette commands, `\|◄` / double-click RTZ, live playback seek + stopped head meter peeking; verified at `1180×760` and `900×620` (`RHYTHM ON`) |
| Project titling & Drive rename | `vui-ctl` + fake Drive + `window.vt` | Status bar click / `n` / `: rename project` / Settings `PROJECT` / Cloud `RENAME`; persists to `project.json` and reloads on restart; fake-Drive `PATCH` renames `untitled-<id>` in place with zero orphaned folders and `DELETES == 0` |
| Metal UI (`vui-ctl`) | `VUI_HIDDEN=1 VUI_PORT=7421 ./bin/tracker-odin ui` | `backend: "GPU"`, `gpu_driver: "metal"`, `video_driver: "cocoa"`, `frame_ms: 2.68`, `unknown_classes: []`; visually verified I/O (`CoreAudio input devices`), Settings (`COREAUDIO`), FX `MST`, Render dialog |
| OpenGL 3.3 fallback | `VUI_BACKEND=gl VUI_HIDDEN=1 VUI_PORT=7422 ./bin/tracker-odin ui --demo` | `backend: "GL"`, `gl_renderer: "Apple M4"`, `unknown_classes: []`, `frame_ms: 2.66` |
| Scarlett 4i4 USB CLI 2ch | `./bin/tracker-odin record --seconds 2 --channels 2 --device 0` | `96,000` frames @ `48,000 Hz` (short 0), `track1.wav` **−52.30 dBFS peak / −60.33 dBFS rms** (phantom-powered condenser @ 9 o'clock), `track2.wav` −86.99 / −99.59 dBFS; bounce `mix.wav` −50.08 dBFS |
| Scarlett 4i4 USB CLI 6ch | `./bin/tracker-odin record --seconds 2 --channels 6 --device 0` | `96,000` frames @ `48,000 Hz` (short 0), tracks 1–6 unmixed in hardware order (ch 1 −52.46 / −60.10, ch 2 −89.38 / −99.92, ch 3 −94.34 / −101.81, ch 4 −94.45 / −101.84, ch 5/6 −120.00 dBFS) |
| Scarlett 4i4 USB live UI | `VUI_HIDDEN=1` live session: arm preview + REC + `MON ON` + playback | Live arm preview meter/waveform before REC; 2.133 s take (`track1-take1.wav`, 102,400 frames, −51.93 dBFS peak) + 1.280 s `MON ON` duplex take (`track1.wav`, 61,440 frames, −52.46 dBFS peak); playback verified |

## Linux build and unit tests

| check | command | result |
|---|---|---|
| clean build | `make clean && make build` | ≈0.8 s |
| DSP | `odin test src/dsp` | **71 passed** |
| engine / project / WAV / RF64 / takes / CLI / settings / cloud | `odin test src` | **138 passed** |
| UI state, layout, HiDPI, harness zoom, PNG | `odin test src/ui` | **81 passed** |
| native renderer | vinland-ui SDL3 + Vulkan/GL | JetBrains Mono, canvas charts, `vui-ctl` screenshots |
| harness renderer | Cairo paths + Pango text | AA curves, gradients, shadows, Inter |
| charts | level history + 5 FX response graphs | 17 screenshots inspected |
| static checks | `odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui` | clean |
| packaging | `PREFIX=/tmp/tracker ./scripts/install-desktop.sh` | binary, PNG+SVG, desktop entry, Inter fonts |

Total: **290 unit tests** (Linux, 2026-11-24).

## Headless UI harness

`./bin/tracker-odin ui-test --script tests/ui/full-tour.json --out /tmp/ui`

- **220 actions, 0 failures**
- **17 PNG screenshots** at 900×620, 1180×760, 1920×1080; layout geometry asserted at all three sizes
- Full tour also passes at `--scale 2` (physical 2360×1520)
- Covers arm/mute/solo, record/play/stop, faders/pans, FX tabs/knobs/bypass,
  palette, recents, bounce, I/O, tempo/click, monitor, JACK toggle, latency,
  rescan, undo/redo, keyboard focus, resizes
- Headless virtual-frame zoom verified at 1440x900 (1.20x), 1920x1080
  (1.52x), 2536x986 (1.59x) and 3840x2160 (1.80x cap); the virtual frame never
  drops below 900x620. The native e2e window is exercised at 900x620 and
  1180x760 with SDL density and the flexible layout.
- Window suite (`make e2e`): **18 cases**, including the render dialog
  range/format flow, settings path edit and apply, text selection/caret,
  secret masking, and the cloud settings/overlay.
  The suite asserts the I/O overlay text but does not baseline its live device
  list: enumeration order is PipeWire/compositor-dependent.

## Background input and focus safety (2026-11-22)

`vui-ctl` pointer/key commands are synthetic and in-process; they never move the
real OS pointer, raise the window or request focus. `VUI_BACKGROUND=1` (or
`make ui-bg`) maps a visible window without activation and with SDL's
non-focusable hint, and suppresses cursor/IME side effects driven by synthetic
hover. X11 window managers honor the hint; Wayland leaves focus policy to the
compositor, so `VUI_HIDDEN=1` remains the hard no-desktop-contact guarantee.

| check | result |
|---|---|
| `vinland-ui/scripts/check-background.sh` (Xvfb + openbox) | window mapped `background:true`, `focusable:false`; pointer stayed at `640,400` across a synthetic `click-text`; screenshot rendered |
| `vui-ctl info` on Tracker in background mode | `background:true`, `focusable:false`, `keyboard_focus` reported from SDL window flags |
| escape hatch | `vui-ctl foreground` clears background suppression and raises/flashes the window; `vui-ctl background` restores it |
| regression | Tracker `tests/ui/window.vt` 18/18; vinland showroom e2e 6/6 after the change |

On Wayland a compositor may refuse to make an existing surface focusable; the
`foreground` response reports that, and the documented fallback is to restart
without `VUI_BACKGROUND=1` for the flow that needs native focus.

## Audit fixes (2026-11-22)

Read-only audits in `docs/audit/2026-11-22/` produced these changes; 271 unit
tests and the 18-case e2e suite pass after them.

| fix | evidence |
|---|---|
| master `t`/`T` no longer indexes take lists out of bounds | `engine_take_cycle` guard + regression test |
| project sample rate adopted on startup/palette load | `engine_load_tracks` sets `e.sample_rate` from the loaded project; 44.1 kHz regression test |
| Save As refuses an occupied Tracker folder | `engine_save_as_to` guard; regression test leaves the destination take unchanged |
| closing during REC finalizes the take before take-list teardown | `engine_destroy` stops first, window close stops/syncs/saves; old canonical is stabilized |
| take stop/selection and clean close persist `project.json` | `window_save_project` in `ui_window.odin` |
| unreadable `project.json` quarantined and takes recovered | renamed `project.json.corrupt-<pid>`; manual malformed-session repro |
| RIFF/PCM WAV writes are atomic | `wav_write`/export use `write_file_atomic` |
| `bounce` requires `--session` | CLI refuses the default session |
| Ctrl/Alt chords no longer fire Vim letters | `window_on_event` swallows non-edit modifier chords |
| pan law hoisted; PNG zlib level 3 | `dsp/render.odin`; `ui/png.odin` (pixel-stable, faster harness) |

Known open items (larger design/architecture changes) are listed in
`docs/audit/2026-11-22/code.md` and `performance.md`: JACK lifecycle, async
mixdown, compressor/resampler rewrites, WAV streaming, native strip
re-proportioning and settings overflow.

## External mix render (2026-11-22)

`RENDER…` in the mix row (or `B`) opens an in-app range/format dialog, then the
native WAV save dialog. The range is a dual-handle track: drag either end, or
click the track to move the nearest hand. `j/k` selects FROM/TO/FORMAT and
`h/l` nudges by 0.5 s (Shift: 5 s). Formats are 32-bit float, 24-bit PCM and
16-bit PCM. Rendering is always stereo at the project rate, applies the full
FX/master chain, and never modifies takes or `bounce.wav`. The range is applied
to the already-rendered mix, so reverb and filter state stay continuous; `TO`
defaults to the full rendered length including the tail, and `TO <= 0` means
the end. Handles clamp 0.1 s apart.

| check | result |
|---|---|
| dialog layout | 1180×760 and 900×620; `unknown_classes: []`, frame 4.0–5.3 ms |
| drag FROM | dragged 1/3 of a 3.000 s mix; label changed `FROM 0:00.0` → `FROM 0:01.0`, TO stayed `0:03.0` |
| drag TO | dragged the right hand left; `TO 0:03.0` → `TO 0:02.2`, FROM stayed `0:01.0` |
| click track | click between hands moved the nearest hand; `FROM 0:01.0` from a track click |
| keyboard | `j/k` rows, `h/l` ±0.5 s, Shift ±5 s, `f`/arrows cycle format, Enter renders |
| grab offset | unit test: grabbing a hand away from its centre preserves the offset; crossing clamps at 0.1 s |
| full mix, 16-bit | 3.000 s stereo `pcm_s16le` at 48 kHz; 2.5 s sub-range was 480,044 bytes |
| full mix, 24-bit | 3.000 s stereo `pcm_s24le` (24-bit) at 48 kHz, 864,044 bytes |
| sub-range | `0:00.5 → 0:02.0` produced exactly 1.500 s, 432,044 bytes |
| drag → render | dragged `0:00.0 → 0:03.0` to `0:01.0 → 0:02.2`, chose 24-bit, rendered 1.164 s `pcm_s24le`, 335,276 bytes |
| 32-bit float | 3.000 s `pcm_f32le` at 48 kHz, 768,058 bytes (earlier round) |
| save dialog | fake zenity captured `--title=Render Mix to WAV`, `--filename=<session>/mix.wav`, `*.wav` filter |
| non-destructive | no `bounce.wav` created; source takes untouched |
| recording guard | while recording, `RENDER…` reports `stop recording before rendering` and does not interrupt the take |
| empty range | `render_slice_bounds` rejects equal/reversed ranges; unit test covers clamping and the end marker |
| format round-trip | 16-bit and 24-bit exports decode through `wav_read` within one LSB; headers assert PCM tag and bit depth |

Intentional limit: integer exports are RIFF only. A >4 GB 16/24-bit mix is
refused rather than switching to RF64; the float path retains RF64 support.

## Settings persistence (2026-11-21)

Verified against the real window with isolated XDG dirs, no `--session`:

```sh
VUI_HIDDEN=1 VUI_PORT=7426 \
  XDG_DATA_HOME=/tmp/opencode/final2/data \
  XDG_CONFIG_HOME=/tmp/opencode/final2/config \
  ./bin/tracker-odin ui &

vui-ctl --port 7426 click-text SET
vui-ctl --port 7426 key down            # j/k selection reaches APPLY
vui-ctl --port 7426 key up              # back to the path row
vui-ctl --port 7426 key enter           # edit
vui-ctl --port 7426 type "/kb2"
vui-ctl --port 7426 key enter           # apply
```

| check | result |
|---|---|
| Project folder | `/tmp/opencode/final2/data/tracker/session/kb2` created with `project.json` |
| settings.json | `saveDir` updated, `highContrast` toggled via keyboard |
| visuals | 1180×760 and 900×620 screenshots inspected; `unknown_classes: []` |
| folder picker | BROWSE starts in the parent of the current project folder (`dialog_start_dir`) so sibling projects are one click away |
| restart | opens the saved project, keeps high contrast and the folder |
| idle | frame count 489 → 496 over 3 s after closing the overlay |
| isolation | explicit `--session` ignores and never writes the real config |

`engine_apply_save_dir` refuses a folder that already contains `project.json`
or any `trackN.wav` (1–24), so the picker and DEFAULT cannot silently overwrite another
session.

## Clipboard paste and edit mode (2026-11-22)

Verified in the real window with `vui-ctl` and the OS clipboard:

```sh
printf 'pasted-client.apps.googleusercontent.com' | wl-copy
vui-ctl --port 7421 type ","
# select Client ID, press Enter
vui-ctl --port 7421 key v ctrl
```

| check | result |
|---|---|
| SDL clipboard | returned an empty string on this Wayland session |
| fallback | `vapp.clipboard_read` read the same text via `wl-paste`; `xclip`/`xsel` are also tried |
| field insertion | Client ID showed the pasted client id; `unknown_classes: []` |
| full input flow | `  old-client-ID  ` → paste, type `-X`, backspace twice, `Ctrl+A`, paste `new-client-id` → saved exactly |
| secret masking | secret field showed `************` during EDIT; saved `cloud.json` held `super-secret`; plaintext never appeared in the tree |
| spaces | Client ID/secret reject spaces; Drive folder preserved `My Studio` |
| select all | `Ctrl+A` + paste/type/backspace replaces the whole field |
| click switching | Client ID draft survived clicking Client secret, typing `S`, clicking Client ID |
| Tab | Client ID → Client secret; typing `T` updated the secret count to `**` |
| Shift+Tab | Client ID → Drive folder; `TrackerX` and `IDDRAFT` drafts both survived |
| UTF-8 | path backspace removes a whole rune (`café` → `caf`) |
| switched draft close | closing with a draft in a non-edit row asks before discarding |
| edit mode | selecting a field shows the `EDIT` chip |
| discard guard | first `Esc` keeps EDIT and says `discard changes?`; second `Esc` cancels |
| tests | paste cloud/project, paste palette/recent, select-all replace, credential spaces, UTF-8 backspace, secret mask, two-step escape, click/Tab/Shift+Tab switching, switched-draft close |
| upstream | vinland-ui `536dce2` adds `clipboard_from_argv`/`clipboard_read` + regression test |

The SDL read path was also fixed to clone the clipboard text **before**
`SDL_free`; reading after free produced garbage in the field.

## Text selection, caret and clipboard (2026-11-22)

Verified in the real offscreen window at 900x620 and 1180x760 with isolated XDG
dirs. `vui-ctl tree` exposed the caret and selection boxes so their geometry could
be asserted, not just seen in a screenshot.

| check | result |
|---|---|
| mouse cursor | the four settings rows and their value containers carry `cursor-text`; palette/recent query bars do too |
| caret blink | a hard 0.53 s on/off caret; four native snapshots alternated present/present/absent/absent; Reduced motion keeps it steady |
| click caret | clicking the path field placed the 2x14 px caret at the pointer x (503 for click x=500) |
| drag selection | drag from x=360 to 620 selected 224 px / 34 characters; amber selection box behind the text |
| shift-click | shift-click at x=390 selected 9 secret stars from the caret anchor |
| double-click | selected the 8-character word under the pointer (52.8 px) and kept it after the button release |
| triple-click | selected the full 297 px path; `vui-ctl click ... triple` drives the native clicks=3 path |
| keyboard selection | Home, Shift+Right (one rune), Shift+Home, End and Ctrl+Shift+Right move/extend exactly |
| Ctrl+word | Ctrl+Left/Right, Ctrl+Backspace and Ctrl+Delete stop at path/word boundaries |
| clipboard | Ctrl+A, Ctrl+C, End, Ctrl+V round-tripped the full path inside the app |
| cut/undo | Ctrl+X cleared the field; Ctrl+Z restored it with its selection; Ctrl+Y redid the cut |
| paste undo | a pasted replacement is one undo step and restores the previous field contents |
| typing undo | a run of typed characters coalesces into one undo step |
| secret mask | secret stayed `**********` with a selection/caret; plaintext never appeared in `tree` |
| tab switching | Tab/Shift+Tab moved ID ↔ secret and preserved both drafts |
| save | Enter on the secret saved `id`/`sec` to the isolated `cloud.json`; the window stayed responsive |
| session isolation | `--session` stores `cloud.json` beside the session, so e2e never overwrites `~/.config/tracker/cloud.json` |
| e2e | `settings text field selection and secret mask`: click, keyboard selection, double-click, Tab/Shift+Tab, mask and save |
| unit tests | caret/selection, word ops, copy/cut/paste, undo/redo, UTF-8 and select-all (`ui_text_*`) |
| upstream | vinland-ui `357c115` adds triple-click and Ctrl+Y to the `vui-ctl` synthetic surface |

A double/triple click must not be converted into a drag on the following frame:
the button-up arrives in a later frame, so multi-click selections lock drag
updates until release. Synthetic Tab also reaches vinland's focus traversal;
Tracker clears vinland focus while a text field is editing so a later synthetic
Enter cannot activate BROWSE and block on the native folder dialog.

## Track count, bounce-to-track and F1 help (2026-11-23)

| check | result |
|---|---|
| `make test` | 71 DSP + 137 core + 80 UI, all green (new: variable-count project round trip, `bounce_tracks_mix` sum/refusals/label, `engine_bounce_to_track` take + mono WAV + sources untouched, Save As copies tracks > 4, add/remove limits, zoom/page/width cap, navigation + FX channel order, marks and target dialog, F1 contexts) |
| `make e2e` | 25 cases at the time (26 now, with `rename a track inline`); screenshots `help-mixer`, `help-palette`, `tracks-six`, `bounce-to-track`, `tracks-24-min` read back |
| 24 tracks @ 900×620 | 11 strips shown (92 px minimum), `unknown_classes: []`, rail shows all 24 dots |
| real window bounce | session with two 1 s tones: marks 1+2, `V`, Enter → `track3.wav` mono float 48 kHz, take `Bounce 1+2` in `project.json`, `tracks` length 4 |
| `make check` | 220-action tour (master FX channel is now `24`) + format checks pass |
| track rename | unit test (edit/commit/cancel/default/paste/reset), `rename a track inline` e2e (key `R` and double-click), `project.json` round trip |
| Google Drive (fake server, `cloud_fake_drive_roundtrips_renamed_many_track_project`) | 9-track project with renamed tracks (one non-ASCII), tracks 1/7/9 audio and a take file: backup → restore → `project_load` keeps names, count, audio flags; zero remote DELETEs. Existing fake-Drive tests (innocent file, duplicate names, same-name project, rename-in-place) still pass. Live Google consent/quota not re-run |
| hardware | none required; JACK/capture paths unchanged apart from `MAX_ENGINE_TRACKS = 24` (capture of tracks > 4 not exercised on hardware) |

## Google Drive (2026-11-22)

Setup: [`docs/cloud-setup.md`](../docs/cloud-setup.md). Scope is exactly
`https://www.googleapis.com/auth/drive.file`; the visible Drive folder name is
configured in Settings → CLOUD.

### Fake-Drive round-trip

`odin test src` starts `tests/cloud/fake_drive.py` and exercises the production
transport, backup and restore code:

| check | result |
|---|---|
| OAuth callback | loopback listener accepts `code` + matching `state`; PKCE URL uses S256 and `drive.file` |
| client metadata | every Tracker folder/file carries `appProperties: {tracker: "1"}` |
| backup | `project.json` + `track1.wav` uploaded into `Studio/...`; index written |
| innocent file | a same-named `track1.wav` without the marker is seeded inside the project folder |
| second backup | innocent file remains byte-identical; marked file updated instead |
| restore | downloads only marked files; restores “MARKED”, never “INNOCENT” |
| delete guard | fake server records **0** DELETE requests |
| query scope | every list is anchored to `'<parent>' in parents`; no global name search |

Additional unit guards cover `..`, `/`, `\`, NUL and empty restore names,
refusal to reuse an existing local folder, and a source test that fails if a
`DELETE` call or `os.remove_all(final)` is added.

### Real-window check

`vui-ctl` with isolated XDG dirs and fake credentials verified:

- Settings → CLOUD scrolls to the Drive folder/Client ID/secret rows and
  remembers the name (`Studio`) in `cloud.json`.
- CONNECT with a missing secret reports `Set the Google Client ID and secret
  first` without opening a browser.
- `g` opens the Cloud projects overlay; disconnected and empty states are
  readable; `Esc` closes it.
- `unknown_classes: []`; the window idles after closing.

### Live Google account round-trip (2026-11-22)

The real Desktop OAuth client was connected through Google’s consent screen
with only `https://www.googleapis.com/auth/drive.file`:

| check | result |
|---|---|
| consent | loopback callback accepted the code/state; Settings showed `Google Drive connected` |
| Drive layout | visible `Tracker/` with `index.json`, `projects/untitled-umnNNw/`; every item carried `appProperties.tracker=1` |
| backup | `project.json`, `track1.wav` and `.tracker-cloud-id` uploaded; `cloud.json`/`settings.json` were not uploaded |
| repeated backup | marked files updated in place instead of creating a second project folder |
| innocent file | an app-created, same-named `track1.wav` without the marker (18 B, `INNOCENT-LIVE-TEST`) stayed byte-identical while the marked `track1.wav` was updated |
| restore | downloaded into a fresh `untitled-umnNNw` folder; `project.json` and `track1.wav` SHA-256 matched the originals |
| local folder collision | a pre-created `untitled-umnNNw/DO-NOT-TOUCH.txt` made restore choose `untitled-umnNNw-2`; the dummy folder stayed untouched; the unit test also exhausts `-2..-99` and checks the timestamp fallback |
| delete + restore | deleted the restored local folder and restored again; `project.json` and `track1.wav` SHA-256 matched the previous restore |
| Drive folder collision | an unmarked `untitled-umnNNw` folder in `projects/` stayed empty; backup used the marked Tracker folder |
| Drive file collision | an unmarked `track1.wav` stayed `INNOCENT-AGGRESSIVE`; the marked `track1.wav` was updated and hash-matched the local file |
| duplicate marked names | `cloud_drive_find` rejects multiple marked files with the same name instead of choosing one |
| same display name | a second local project named `Test Project` got a new cloud id, a sibling Drive folder and a second index entry; the first project was untouched |
| delete guard | the app performed no Drive DELETE; the test-only innocent fixtures were removed by the verification script afterwards |
| fonts/UI | the window stayed responsive; `unknown_classes: []` |

This run exposed two lifetime bugs: the curl body-file argument and the existing
`index.json` ID were freed by a block-scoped `defer` before the request. Both
are fixed, and the fake-Drive test now asserts an exact form-body round-trip.

## Real audio

| check | result |
|---|---|
| miniaudio capture (default source) | 96,000 frames / 2.000 s |
| arm preview (no take, transport stopped) | armed track 1 shows live input meter/history; unarm decays and idles |
| native UI capture (loopback tone) | 100,352 frames, **−6.02 dBFS** |
| loopback known tone | **−6.02 dBFS**, RMS −9.13, exact 2.000 s |
| long loopback | 480,000 frames / **10.000 s** |
| JACK CLI | 24,000 frames / 0.500 s |
| JACK GUI (`ui --jack`) | 57,344 frames / 1.195 s |
| Scarlett 4i4 (6-in, "Surround 5.1"), 2026-11-21 | inputs 1/2 at half gain, nothing plugged; per-input levels match `pw-record` 1:1 reference |
| ↳ miniaudio CLI 2 ch / 6 ch, 20 s | in1 −63.3 dBFS RMS (60 Hz hum), in2 −94.0, in3/4 digital silence, in5/6 −101.9; 960,000 frames exact |
| ↳ JACK CLI 2 ch / 6 ch, 20 s | in1 −60.9, in2 −93.8, same per-input pattern; binds the default device's JACK client |
| ↳ native UI (hidden, sandboxed GL) miniaudio / JACK | track1 −58.7 / −61.2, track2 −94.0 / −94.0 |
| ↳ dropouts | no zero runs or low-level blocks after the first 1,024 frames (PipeWire start-up hole) |
| live monitor + latency + 2 takes | duplex monitor, track1-take1 + canonical, T1/2 |
| comp region | 2 takes, region [0, 48000) → 1.000 s comp bounce |
| bounce | stereo float, limiter ceiling held |
| project save/reload | takes, active take, latency and a11y flags restored |
| recent projects | `/tmp/tracker-feature/project.json` persisted and reopened |
| HiDPI | 1180×760, 1770×1140, 2360×1520, 3540×2280 screenshots |

A real 2-second take through the native window and a 4-second take followed by
bounce/project save were both verified with xdotool on Xvfb.

The loopback test is reproducible with:

```sh
./scripts/check.sh --loopback
```

## Design tokens

`src/ui/theme.odin` keeps raw palette → semantic colour roles → space/type/
metric scales → theme bundle. Widgets read `ACTIVE_TOKENS.color.*`; layout reads
`METRICS`/`SPACE`. The reference palette is asserted by the UI contrast test, and
the high-contrast theme changes colour only.

## Accessibility

- `ui --a11y-log` prints `app_describe()` on every state revision: mode,
  transport, selection, per-track arm/mute/solo/takes/level/pan/peak, tempo,
  monitor/latency/backend, contrast/motion flags, undo depth and status.
- High-contrast and reduced-motion modes are keyboard/palette accessible and
  persisted in `settings.json` (projects also carry the values for portable
  sessions).
- No AT-SPI tree; the textual log is the screen-reader surface.

## Packaging

`make install` and `make uninstall` are idempotent. The desktop entry uses
`Name=Tracker (Odin)`, `StartupWMClass=tracker`, quoted `Exec`, PNG and SVG
icons. The window class `tracker` lets an optional compositor rule route dev
runs to a scratchpad; normal launches open on the active workspace.

## Sources consulted

The implementation follows the project research rule in `AGENTS.md`; the
significant sources are recorded in the README (Cairo image surfaces + paths,
Pango Cairo integration, Inter/SIL OFL, SDL2 high-DPI, stb_truetype fallback,
RF64/EBU, JACK, XDG, Odin core/vendor).
