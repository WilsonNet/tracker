# Tracker performance audit — 2026-11-22

> **Follow-up (same day).** The pan-law hoist and the PNG zlib-level change
> recommended here were applied after the audit; the measured table below is
> the pre-change baseline. Compressor dB conversions, synchronous mixdown,
> WAV streaming and the resampler remain open.

Pinned source: `d39946d` (tracker), vinland-ui `357c115` (checkout modified by
other sessions during the run). Primary app binary hash:
`bca79a9a97815880cc17cc9343d86bc243cb58aa453cdf582c683f6c8347761d`
(frozen at `/tmp/opencode/audit-perf/tracker-odin-d39946d`).

Host: AMD Ryzen 7 6800H, 16 threads, 13.6 GiB RAM, Odin
`dev-2026-11-nightly:9a69916`. Headless runs are `VUI_HIDDEN=1`, SDL offscreen,
Mesa llvmpipe (software GL).

**Load caveat.** Other sessions ran 3–5 hidden `tracker-odin ui` windows and
rebuilt `odin/bin/tracker-odin` during this audit. Load average ranged ~3–18.
Absolute wall/`frame_ms` numbers are therefore conservative and noisy; medians
and code-cost ratios are the reliable part. To keep one artifact, the repo
binary was copied to `/tmp/opencode/audit-perf/tracker-odin-d39946d` and all
"frozen" rows below use that copy. Earlier low-load rows are shown where useful.

**`/usr/bin/time` is not installed.** `measure.py` runs the command with
`os.posix_spawnp` + `os.wait4`; `ru_maxrss` is the same kernel peak-RSS field
GNU time prints. `ru_utime`/`ru_stime` are reported too.

## (a) Results

### Startup / one-shot PNG

| case | n | wall median | min–max | peak RSS | note |
|---|---:|---:|---:|---:|---|
| `ui-shot` 1180×760 (frozen) | 10 | **99.7 ms** | 87.0–108.1 | 30.9 MB | earlier low-load build: 74.6 ms (n=7) |
| `ui-shot` 1920×1080 (frozen) | 5 | **133.3 ms** | 130.3–145.9 | 40.5 MB | earlier low-load build: 108.9 ms (n=7) |
| `ui-shot --fx` 1180 | 5 | 112.7 ms | 109.5–123.8 | 31.2 MB | |
| `ui-shot --settings` 1180 | 5 | 113.0 ms | 105.4–125.1 | 31.5 MB | |
| `ui-shot --cloud` 1180 | 5 | 111.9 ms | 106.2–119.1 | 30.8 MB | |
| `ui-shot --palette` 1180 | 5 | 110.5 ms | 106.4–125.8 | 31.2 MB | |
| `ui-shot --bounce` 1180 | 5 | 109.5 ms | 104.3–117.3 | 31.1 MB | |
| isolated draw 1180 normal | 15 | 5.62 ms | — | — | warm Cairo frame |
| isolated PNG 1180 | 15 | **38.86 ms** | — | — | real drawn frame |
| isolated draw 1920 normal | 15 | 6.93 ms | — | — | |
| isolated PNG 1920 | 15 | **85.16 ms** | — | — | |
| isolated draw 1180 FX | 15 | 9.86 ms | — | — | |
| isolated PNG 1180 FX | 15 | 40.06 ms | — | — | |
| isolated draw 1920 FX | 15 | 11.62 ms | — | — | |
| isolated PNG 1920 FX | 15 | 86.61 ms | — | — | |

PNG encode is ~40 % of the 1180 `ui-shot` and ~64–80 % of the 1920 one. The
warm draw+PNG totals (44.5 / 92.1 ms) are below the process-level medians
because `ui-shot` pays cold font/Pango initialisation on its single draw.

### Native window frame cost (`vui-ctl info`, 7 samples/state)

Static screens, frozen binary, `VUI_HIDDEN=1`, 1× scale. Budget from
`odin/tests/ui/window.vt:14` is **`expect-frame-ms 40`**.

| state | 1180×760 median (min–max) | nodes / cmds | 1920×1080 median (min–max) | nodes / cmds |
|---|---:|---:|---:|---:|
| normal | **3.49** (3.24–4.00) | 269 / 553 | **5.79** (4.89–7.00) | 269 / 553 |
| FX rack | **5.20** (4.95–6.57) | 375 / 1651 | **9.01** (7.72–9.66) | 375 / 1651 |
| settings | **7.00** (6.45–11.29) | 336 / 986 | **11.18** (10.26–15.69) | 336 / 1210 |
| cloud | **5.09** (4.86–7.44) | 279 / 750 | **8.08** (7.42–13.60) | 279 / 750 |
| palette | **7.44** (5.47–9.34) | 322 / 745 | **9.72** (8.26–11.17) | 322 / 745 |
| render dialog | **5.36** (5.14–8.24) | 294 / 815 | **9.84** (8.35–12.86) | 294 / 815 |

All medians and all but a handful of individual samples are under the 40 ms
budget. Worst median is 11.18 ms (1920 settings); worst single sample seen was
15.69 ms. `unknown_classes` was `[]` in every state; backend `GL`, renderer
`llvmpipe (LLVM 23.1.5, 256 bits)`, `sandboxed=true`. This is a software
rasteriser, so the numbers are not a GPU-window prediction.

Live-meter runs add noise and are not directly comparable: 1180 demo normal
medians were 8.8–10.7 ms, FX 7.5–11.2 ms; 1920 demo normal 6.1 ms, FX 9.3 ms.
The higher 1180 values coincided with other sessions' llvmpipe windows.

### Harness throughput

| case | n | wall median | peak RSS |
|---|---:|---:|---:|
| `ui-test --script tests/ui/full-tour.json` (220 actions, 17 PNGs) | 3 | **880.6 ms** | 46.2 MB |
| same, earlier low-load binary | 3 | 915.7 ms | 45.5 MB |
| `AUDIT_PERF=1` in-process `ui-test x20` | 20 | 14,709 ms (735 ms/run) | RSS +1.3 MB/20 runs |

The tour grew from the historical 56 actions / 10 screenshots to **220 actions /
17 screenshots**. Per action it is faster than the old audit (3.3 ms vs ~7.0 ms),
but the absolute tour time is longer. With ~39 ms PNG + ~6 ms Cairo draw per
1180 shot, screenshot work is roughly 765 ms of the 881 ms tour (~87 %; screens
vary from 900×620 to 1920×1080).

### Audio / offline

`AUDIT_PERF=1`, one test thread, one run (the audit is a single-run benchmark;
PERF.md itself documents ±15 %). Frozen-binary CLI rows are medians of 3.

| case | ms | alloc/peak MB | note |
|---|---:|---:|---|
| render 4×60 s, faders only | 678.71 | 22.93 | 2,880,000 frames |
| render 4×60 s, EQ only | 993.37 | 22.93 | 3/−2/+1.5 dB |
| render 4×60 s, compressor only | 1,623.60 | 22.93 | |
| render 4×60 s, EQ+comp | 1,922.83 | 22.93 | |
| render 4×60 s, default FX | **1,896.64** | 22.93 | shipped defaults |
| render 4×60 s, full chain | 3,893.77 | 24.71 | sends + master FX |
| limiter 10 s @48k | 49.32 | 0.02 | 480k stereo frames |
| resample 60 s 48k→44.1k | 898.73 | 10.16 | mono |
| `pan_gains` 11.52 M calls | 137.33 | — | |
| `lin_to_db` 2.88 M calls | 149.88 | — | 52 ns/call |
| `wav_write` 60 s stereo | 59.06 | 21.97 | whole-file buffer |
| `wav_read` 60 s stereo | 93.76 | 43.95 | file + samples |
| PNG 1180 (synthetic canvas) | 28.92 | 6.87 | |
| PNG 1920 (synthetic canvas) | 64.19 | 15.85 | |
| `ui-test` ×20 | 14,709.33 | — | 20/20 passed |

Microbench (same 11.52 M calls as a 60 s 4-track mix):

| conversion | ms | ns/call |
|---|---:|---:|
| `lin_to_db` | 598.00 | 51.9 |
| `db_to_lin` | 151.05 | 13.1 |
| `pan_gains` (sin+cos) | 138.99 | 12.1 |

Resampler scaling (shows fixed kernel-build cost vs loop):

| input | out frames | ms | ns/out |
|---|---:|---:|---:|
| 0.1 s | 4,410 | 1.96 | 444 |
| 1 s | 44,100 | 18.97 | 430 |
| 10 s | 441,000 | 164.28 | 373 |
| 60 s | 2,646,000 | 1,012.40 | 383 |

Frozen CLI:

| case | ms | peak RSS | note |
|---|---:|---:|---|
| `tone` 60 s stereo write | 128.1 | 56.1 MB | includes sine generation |
| `info` 60 s stereo read | 128.8 | 55.6 MB | includes peak/RMS scan |
| `bounce` 4×60 s | **2,564.0** | **102.1 MB** | 60.000 s, stereo, peak −0.30 dBFS |

A bounce of four 60 s stereo tracks is 102 MB peak RSS; the 60 s stereo WAV
itself is 23.04 MB.

### Memory / idle

| case | RSS | CPU | note |
|---|---:|---:|---|
| hidden `ui --demo`, 1180×760, 30 s | 187.1 MB flat | **186 % of one core** | ~45 fps; `--demo` forces continuous rendering |
| hidden `ui` (no demo), 30 s | 187.3 MB flat | **8.4 %** | ~2.2 fps idle |
| hidden `ui`, 3,604 frames / ~60 s | 187.28 MB **flat** | 245 % total, 19.9 % main thread | main thread 3.32 ms/frame |
| `ui-shot` 1180 / 1920 | 30.9 / 40.5 MB | | one-shot |
| `ui-test` tour | 46.2 MB | | 17 PNGs |
| 60 s stereo WAV write/read | 56.1 / 55.6 MB | | process peak |
| 4-track bounce | 102.1 MB | | |

The temp-arena leak is gone: RSS is byte-identical at 187,280 KB after 3,600
continuously rendered frames. `free_all(context.temp_allocator)` is called by
the vinland app per frame (`vinland-ui/vui/app/app.odin`, currently line 779;
the file moved during this session). The harness script leak and
`project_load` leak are also fixed; the audit's leak tests report `live 0 B`.

### Framework / view cost

Measured with `view_bench.odin` (real `ui.view_frame` + `vui.end_frame`, no SDL
window), 1180×760, live demo state, 60 frames, temp arena reset per frame.

| state | view build | layout+paint | view temp | layout temp | nodes (custom) | cmds |
|---|---:|---:|---:|---:|---:|---:|
| normal | 1.03 ms | 1.19 ms | 11,151 B | 238,165 B | 269 (8) | 766 |
| FX rack | 1.71 ms | 2.13 ms | 14,851 B | 333,741 B | 375 (23) | 1,864 |
| settings | 1.51 ms | 1.94 ms | 15,694 B | 302,622 B | 336 (8) | 1,143 |
| cloud | 1.11 ms | 1.33 ms | 11,438 B | 245,870 B | 278 (8) | 919 |
| palette | 1.37 ms | 1.68 ms | 12,103 B | 295,789 B | 322 (8) | 944 |
| render | 1.27 ms | 1.61 ms | 12,534 B | 261,230 B | 294 (9) | 1,038 |

Primitive mix (live demo, same run):

| state | RRect | Glyph | Arc | Area | Segment |
|---|---:|---:|---:|---:|---:|
| normal | 391 | 363 | 8 | 0 | 4 |
| FX | 426 | 596 | 30 | 318 | 494 |

Normal has 8 custom canvases: 4 pan dials + 4 level-history canvases. FX has 23:
those 8 plus 12 knobs and 3 FX graph canvases. The FX graphs alone emit
318 `Area` + 494 `Segment` + 30 `Arc` = 842 of the 1,864 commands (~45 %).
A live history draw adds ~244 RRect commands (static 522 → live 766).

`view.odin` has **47 `fmt.tprintf` call sites** and 5
`context.temp_allocator` sites. Per frame it writes 11–15 KB into the temp
arena (history/dial/FX structs, the 160-point FX graph arrays, formatted
labels). Vinland's layout/paint writes a further **238–334 KB/frame** into
`context.temp_allocator` (`vui/layout.odin:578,696,1235`, `vui/paint.odin:558`).
Nothing leaks (the app frees the temp arena each frame), but the churn is
~15–21 MB/s at 60 fps and is the dominant per-frame allocation volume.

## (b) Top 5 remaining performance problems

Ranked by measured impact. "Expected gain" is estimated from the measured
delta, not implemented here.

1. **Per-sample dB round-trips in compressor + limiter.**
   `dsp/compressor.odin:136` (`lin_to_db(detector)`) and `:147`
   (`db_to_lin(c.gain_db)`) run for every track frame; `dsp/limiter.odin:132`
   computes `lin_to_db(lim.envelope)` every stereo frame only to update
   `min_gain_db`. Measured: comp-only − faders-only = **945 ms** per 60 s
   4-track render; the two conversions alone cost 598 + 151 = **749 ms** for
   the same 11.52 M calls. Limiter log ≈ 52 ns × 2.88 M = **150 ms** per 60 s.
   Expected: 600–800 ms off a 1.90 s default render (32–42 %), plus faster
   preview/bounce. Fix: keep detector/gain in linear or exp2 domain; compute
   meter dB only at the 20 Hz meter tick.

2. **The whole mix is rendered synchronously on the UI thread.**
   `engine.odin:1369` calls `dsp.render_mix`; `playback_prepare` (`:1383`) and
   `engine_bounce` (`:1548`) call it, and the UI command loop calls them at
   `ui_window.odin:489` / `:505`. Measured with four 60 s tracks: a `vui-ctl`
   Play round-trip was **2,065.7 ms** vs a 22 ms baseline (Stop: 48 ms), i.e.
   a ~2 s frozen window before playback starts. Expected: remove the freeze
   with a worker thread/streamed render; the 1.9 s CPU cost remains but is off
   the UI thread.

3. **Pan law is recomputed inside the per-frame, per-track loop.**
   `dsp/render.odin:233` calls `track_mix_pan_gains(track)` (sin + cos) for
   every sample of every track. Measured **139 ms** for 11.52 M calls:
   7.3 % of the 1,896.6 ms default render and 20.5 % of the 678.7 ms
   faders-only render. Expected: ~139 ms off default (all but the multiply),
   for a five-line hoist of `gl/gr` next to the EQ/comp state setup.

4. **PNG encoding dominates screenshots and the test tour.**
   `ui/png.odin:36` allocates a full raw RGBA buffer, `:56` calls zlib level 6
   over the whole frame, `:63` appends the IDAT payload byte-by-byte, `:75`
   makes a second full copy. Measured real drawn-frame PNG: **38.9 ms** at
   1180×760 and **85.2 ms** at 1920×1080. That is ~40 % of a 1180 `ui-shot`
   and ~64–80 % of a 1920 `ui-shot`; with 17 screenshots it is ~75–87 % of the
   881 ms tour. Component measurement: zlib level 6 is 19.4 ms (1180) /
   39.0 ms (1920); level 3 is 7.1 / 17.6 ms with 68 / 102 KB output, and level 1
   is 8.8 / 16.7 ms. The other ~19 / 46 ms is the per-pixel scanline conversion
   and the extra output copy. Expected: level 3 plus a vectorised/byte-order
   conversion should save ~20–40 ms per 1920 shot (~15–30 % of `ui-shot` and a
   similar share of the tour); it is not a 4× win on its own.

5. **WAV I/O still buffers the whole file.**
   `wav.odin:87` allocates the entire RIFF payload; `:213` reads the entire
   file and `:352` allocates all samples; `engine.odin:1153` reads the whole
   raw take and `:1188` allocates one mono slice per armed track. Measured
   60 s stereo: write 22.0 MB / 59 ms, read 44.0 MB / 94 ms; 4-track bounce
   102 MB peak. Extrapolated to the documented 1 h cap: 1 h stereo = 1.38 GB
   payload (write peak ≈1.38 GB, read peak ≈2.76 GB); 1 h 4-channel split ≈
   8.3 GB peak (2.76 GB raw + 2.76 GB read copy + 2.76 GB mono tracks) on a
   13.6 GB machine. Expected: streaming write already exists for RF64
   (`wav_rf64.odin:312`), use it for normal takes/bounce; chunked read/split
   drops the multi-GB peaks to tens of MB. Time gain is modest (~10–30 ms per
   60 s file); the win is OOM avoidance.

Also significant, below the top five:

- **Resampler inner loop**: `dsp/resample.odin:96` rebuilds the 512×32 kernel
  every call, but scaling shows the fixed cost is only ~2 ms; the 60 s mono
  cost is 1,012 ms (~383 ns/output) from the f64 32-tap loop with a per-tap
  bounds check (`:120–129`). f32 + clamped head/tail + unchecked interior is
  the real 2–3× win. Applies only when take rate ≠ project rate; four such
  tracks add ~4 s to a 60 s play/bounce.
- **FX graph canvas cost**: `view.odin:1059` allocates a 160-point array every
  frame and `:1066–1089` recomputes `exp`/`pow` per point. The three graph
  canvases emit 842 primitives (~45 % of FX commands). Cache the point arrays
  until a parameter changes; FX frame is 1.5× normal (9.0 vs 5.8 ms at 1920).
- **Layout scratch allocations**: vinland allocates 238–334 KB/frame from
  `context.temp_allocator`; moving layout/paint scratch to the existing
  per-frame `ctx.frame_alloc` arena would remove the app's dependence on a
  global `free_all` and cut allocation churn.
- **`view.odin` formatting**: 47 `tprintf` sites and 11–15 KB/frame of temp
  strings; stack buffers / cached labels would trim CPU and churn, though view
  build is already only 1.0–1.7 ms.

## (c) PERF.md claims: true / false now

| PERF.md claim / recommendation | status now | evidence |
|---|---|---|
| Canvas gained opaque/alpha bulk-fill fast path; ~2.1× (3.12/5.35 ms at 1180) | **superseded / not comparable** | Canvas is Cairo now: `ui/canvas.odin:200–218` `fill_device` → `cairo_rectangle`+`cairo_fill`. `AUDIT_PERF` rows are 0.06 ms opaque / 0.31 ms alpha at 1180, 0.13/0.77 at 1920, but these time Cairo command submission, not the old pixel loop. Fast fills: goal met; old numbers obsolete. |
| Window resets the temp arena every frame | **TRUE** | `vinland-ui/vui/app/app.odin` `free_all(context.temp_allocator)` (currently line 779; moved during session). RSS flat 187,280 KB over 3,604 frames. |
| Harness owns its result strings; parsed-script leak fixed | **TRUE** | `ui_harness.odin:66–95` `harness_script_destroy`, `defer` at `:145`. Leak scopes report `live 0 B`. RSS still +65 KB/run over 20 in-process runs (allocator high-water, no live allocation). |
| Compressor per-sample log/exp fix | **FALSE** | `dsp/compressor.odin:136,147`; 598 + 151 ms per 11.52 M calls. |
| Hoist pan law out of the render loop | **FALSE** | `dsp/render.odin:233`; 139 ms per 11.52 M calls. |
| Stream WAV I/O and take splitting | **PARTIAL** | RF64 streaming writer exists (`wav_rf64.odin:312–322`, `wav_stream_*`), used only when RIFF would overflow. Normal `wav_write` (`wav.odin:87`), `wav_read` (`:213,352`) and `engine_split_take` (`engine.odin:1153,1188`) still whole-file. |
| PNG encode avoids whole-file copies | **FALSE** | `ui/png.odin:36,56,63,75`; 38.9/85.2 ms real. |
| Resampler caches its kernel / fast inner loop | **FALSE** | `dsp/resample.odin:96` rebuilds; `:120–129` f64 + bounds check. Kernel is ~2 ms; loop is ~1,012 ms/60 s mono. |
| Move render off the UI thread | **FALSE** | `engine.odin:1369`; UI calls `ui_window.odin:489,505`; measured 2.07 s freeze. |
| `project_load` leak on malformed JSON | **TRUE fixed** | `project.odin:550` defer registered before `:552` unmarshal. |
| Peak meter data race | **TRUE fixed** | atomic load/store at `engine.odin:279,1593` (and preview equivalents). |
| Dead `last_mix`, `G_RECORDER`, missing parent dirs | **TRUE fixed/removed** | no `last_mix`/`G_RECORDER` hits; `os.make_directory_all` at `engine.odin:180`. |
| `write_frame`/`read_frame`/`stop` cache-line padding | **FALSE** | still adjacent `u64`s at `engine.odin:36–38`. Low impact. |
| UI frame 11.2 ms @1180 / 24.8 ms @1080 | **no longer** | Cairo harness 3.45/4.52 ms; native 3.49/5.79 ms. Renderer changed, so not a like-for-like win. |
| `ui-test` ×20 = 7,846 ms | **not comparable** | 14,709 ms now, but the tour is 220 actions/17 PNGs vs 56/10; per action 3.3 ms vs ~7.0 ms. |

## (d) Exact repro commands and artifacts

All artifacts are under `/tmp/opencode/audit-perf/`. The app binary was frozen
once because another session rebuilt `odin/bin/tracker-odin` mid-audit.

```sh
cd /home/wilsonn/www/tracker/odin
BIN=/tmp/opencode/audit-perf/tracker-odin-d39946d   # sha256 bca79...
python3 /tmp/opencode/audit-perf/measure.py 5 shot1180 "$BIN" ui-shot \
  --out /tmp/opencode/audit-perf/frozen-shot-1180.png --width 1180 --height 760

# hidden native window; use a PORT no other session owns (check `ss -ltn`)
VUI_HIDDEN=1 VUI_SIZE=1180x760 VUI_PORT=7461 VUI_QUIET=1 \
  setsid nohup "$BIN" ui --session /tmp/opencode/audit-perf/ui-session \
  >/tmp/opencode/audit-perf/frozen-ui-1180.log 2>&1 < /dev/null &
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 settle
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 info
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 type x   # FX
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 type ,   # settings
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 type g   # cloud
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 type :   # palette
/home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 type B   # render dialog
# 7 samples/state: wait 2; info
for i in 1 2 3 4 5 6 7; do \
  /home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 wait 2 >/dev/null; \
  /home/wilsonn/www/vinland-ui/build/vui-ctl --port 7461 info; done

# 30 s idle demo: sample /proc/<pid>/status VmRSS/VmHWM and
# /proc/<pid>/stat fields 14/15; CLK_TCK=100.
VUI_HIDDEN=1 VUI_SIZE=1180x760 VUI_PORT=7461 VUI_QUIET=1 \
  setsid nohup "$BIN" ui --demo --session /tmp/opencode/audit-perf/idle-session ...

# offline benchmark (compiles its own test binary; no app build)
AUDIT_PERF=1 ODIN_TEST_THREADS=1 odin test src -define:ODIN_TEST_THREADS=1 \
  -collection:vinland=../../vinland-ui \
  -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0"

# 60 s stereo throwaway session
"$BIN" tone --out /tmp/opencode/audit-perf/frozen-tone60.wav \
  --seconds 60 --freq 220 --amp 0.3 --channels 2 --rate 48000
for n in 1 2 3 4; do cp /tmp/opencode/audit-perf/frozen-tone60.wav \
  /tmp/opencode/audit-perf/bounce-session/track$n.wav; done
"$BIN" bounce --session /tmp/opencode/audit-perf/bounce-session \
  --out /tmp/opencode/audit-perf/frozen-bounce.wav

# custom measurement harnesses (source-compiled, outside the repo)
odin build /tmp/opencode/audit-perf/shot_bench.odin -file \
  -out:/tmp/opencode/audit-perf/shot_bench \
  -collection:tracker=/home/wilsonn/www/tracker/odin/src \
  -collection:vinland=/home/wilsonn/www/vinland-ui \
  -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0"
/tmp/opencode/audit-perf/shot_bench     # draw vs PNG, 1180/1920 normal/FX
/tmp/opencode/audit-perf/view_bench     # view build / layout / temp / primitives
/tmp/opencode/audit-perf/dsp_bench      # lin_to_db, db_to_lin, pan_gains
/tmp/opencode/audit-perf/resample_bench # resample scaling
/tmp/opencode/audit-perf/zlib_bench     # zlib levels on a real scanline payload
```

Key artifacts:

- `results.json` — machine-readable summary.
- `audit-perf-run1.txt` — full `AUDIT_PERF=1` test output.
- `frozen-1*-*.jsonl` — native `info` samples per state (`cloud`, `fx`,
  `normal`, `palette`, `render`, `settings` at 1180/1920).
- `frozen_shot_*.json`, `ui_shot_*.json`, `frozen_ui_test.json`,
  `frozen_tone60.json`, `frozen_info60.json`, `frozen_bounce.json` — raw
  `measure.py` runs (wall, user, sys, max RSS).
- `shot_bench.txt`, `view_bench.txt`, `dsp_bench.txt`, `resample_bench.txt`,
  `zlib_bench.txt`.
- `shot-1180-*.png`, `shot-1920-*.png`, `frozen-ui-shot-*.png`,
  `frozen-shot-*.png` — rendered evidence.
- `frozen-ui-1180.log`, `frozen-ui-1920.log`, `frozen-idle-demo.log`,
  `frozen-steady.log` — backend/control-server logs.
- `measure.py`, `shot_bench.odin`, `view_bench.odin`, `dsp_bench.odin`,
  `resample_bench.odin` — the measurement harnesses.
- `tracker-odin-d39946d` — frozen binary used for all app-level rows.

## Caveats

- `/usr/bin/time` is absent; peak RSS comes from `wait4`/`ru_maxrss`, the same
  kernel source GNU time uses.
- `frame_ms` is the last `end_frame` (paint/present) only; view build and
  layout are measured separately by `view_bench`. `frame_ms` excludes the
  ~2.3 ms/frame UI build+layout and is a software-llvmpipe number.
- Other sessions' windows and rebuilds raised load to ~12–18 during several
  runs. Frozen medians are conservative; low-load medians are noted where they
  exist. Re-run on a quiet machine for final budgeting.
- `AUDIT_PERF` rows are single-run medians from one process; the audit itself
  documents ±15 %. The CLI rows are independent 3-run medians.
- The 1 h / 4-channel memory figures are arithmetic extrapolations from the
  measured 60 s byte counts, not a 1 h measurement.
