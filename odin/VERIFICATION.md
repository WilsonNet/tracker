# Verification matrix

Measured on the development machine (Arch Linux, PipeWire 1.6.11, Odin
`dev-2026-11-nightly`), 2026-11-17 through 2026-11-22. The native port is
complete; details and intentional limits are in `ROADMAP.md`.

## Build and unit tests

| check | command | result |
|---|---|---|
| clean build | `make clean && make build` | ≈0.8 s |
| DSP | `odin test src/dsp` | **70 passed** |
| engine / project / WAV / RF64 / takes / CLI / settings / cloud | `odin test src` | **124 passed** |
| UI state, layout, HiDPI, harness zoom, PNG | `odin test src/ui` | **70 passed** |
| native renderer | vinland-ui SDL3 + Vulkan/GL | JetBrains Mono, canvas charts, `vui-ctl` screenshots |
| harness renderer | Cairo paths + Pango text | AA curves, gradients, shadows, Inter |
| charts | level history + 5 FX response graphs | 17 screenshots inspected |
| static checks | `odin check src -no-entry-point -vet -collection:vinland=../../vinland-ui` | clean |
| packaging | `PREFIX=/tmp/tracker ./scripts/install-desktop.sh` | binary, PNG+SVG, desktop entry, Inter fonts |

Total: **264 unit tests**.

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
- Window suite (`make e2e`): **17 cases**, including settings path edit and
  apply, text selection/caret, secret masking, and the cloud settings/overlay

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
| restart | opens the saved project, keeps high contrast and the folder |
| idle | frame count 489 → 496 over 3 s after closing the overlay |
| isolation | explicit `--session` ignores and never writes the real config |

`engine_apply_save_dir` refuses a folder that already contains `project.json`
or `track1..4.wav`, so the picker and DEFAULT cannot silently overwrite another
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

**Pending:** a live Google account round-trip with the user’s OAuth client.
The fake server covers the full transport/backup/restore/delete-safety path,
but Google’s real OAuth consent and quota behavior still need one manual run.

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
