# Performance + memory audit (historical native snapshot)

> **Historical document.** The measurements below were taken at commit
> `dff9236` and are a conservative baseline, not current verification. Current
> test counts, commands and behavior live in `README.md` and
> `VERIFICATION.md`.
>
> **Post-audit note:** these numbers were measured at `dff9236`. Before merge,
> the canvas gained an opaque/alpha bulk-fill fast path, the window resets its
> temp arena every frame, and the harness owns its result strings. Treat the
> table as a conservative baseline; leaks 1/2 below are fixed.
> Post-audit re-run: canvas fill 1180 opaque 3.12 ms (was 6.28), alpha 5.35 ms
> (was 10.52); 1920 opaque 7.23 ms (was 14.47), alpha 12.36 ms (was 24.62),
> i.e. ~2.1× faster after the bulk-fill fast path.

Scope: measure the native app at commit `dff9236` (Odin `dev-2026-11-nightly`),
report concrete costs and leaks, and rank the fixes. No application source was
changed by this audit — every finding below is a report, not a patch.
The only additions are this file and `src/audit_perf_test.odin`.

Reproduce:

```sh
cd odin
export PATH="$HOME/.local/bin:$PATH"

# current suites (leak tracking is on by default in the Odin test runner)
make test

# historical audit benchmark rows; numbers will differ on the current tree
AUDIT_PERF=1 odin test src -define:ODIN_TEST_THREADS=1 \
  -collection:vinland=../../vinland-ui \
  -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0"
```

`audit_perf_test.odin` also contains three cheap leak tests that always run:
App + Canvas lifecycle, `render_mix` + WAV round-trip, engine + project
load/save. All three report `live 0 B` after their `*_destroy`.

Machine: Ryzen, 16 threads, 13.6 GB RAM. Numbers are single-run medians from
the run above; treat ±15 %. `valgrind` and `heaptrack` are **not installed**
on this machine, so allocation numbers come from `core:mem`'s tracking
allocator wrapped around each measured call; RSS comes from
`/proc/<pid>/status`.

## Benchmark table

| case | ms | alloc MB | peak MB | notes |
|---|---:|---:|---:|---|
| render 4 tracks × 60 s, faders only | 477 | 22.9 | 22.9 | 2,880,000 frames |
| render 4 × 60 s, EQ only (3/−2/+1.5 dB) | 749 | 22.9 | 22.9 | EQ bypasses at 0 dB |
| render 4 × 60 s, compressor only | 1290 | 22.9 | 22.9 | 4 track comps |
| render 4 × 60 s, EQ + comp | 1507 | 22.9 | 22.9 | |
| render 4 × 60 s, default FX (flat EQ, comp, limiter) | 1490 | 22.9 | 22.9 | shipped defaults |
| render 4 × 60 s, full chain (sends + master FX) | 3205 | 24.7 | 24.7 | 3,112,881 frames (tail) |
| limiter 10 s @48k | 36.6 | 0.02 | 0.02 | 480k stereo frames |
| resample 60 s 48k→44.1k | 729 | 10.2 | 10.2 | 2,646,000 frames |
| `pan_gains` (sin+cos) 11.52M calls | 114 | — | — | cost inside the render loop |
| `lin_to_db` (log10) 2.88M calls | 122 | — | — | 42 ns/call |
| UI frame 1180×760 normal | 11.2 | 3.42 | 3.42 | 89 fps ceiling |
| UI frame 1920×1080 normal | 24.8 | 7.91 | 7.91 | 40 fps ceiling |
| UI frame 1180×760 FX rack | 27.5 | 3.42 | 3.42 | 36 fps ceiling |
| UI frame 1920×1080 FX rack | 58.6 | 7.91 | 7.91 | 17 fps ceiling |
| canvas fill 1180×760 opaque | 6.28 | 3.42 | 3.42 | 143 Mpix/s |
| canvas fill 1180×760 alpha 0xC0 | 10.52 | 3.42 | 3.42 | 85 Mpix/s |
| canvas fill 1920×1080 opaque | 14.47 | 7.91 | 7.91 | 143 Mpix/s |
| canvas fill 1920×1080 alpha 0xC0 | 24.62 | 7.91 | 7.91 | 84 Mpix/s |
| `wav_write` 60 s stereo | 40.7 | 22.0 | 22.0 | 1× extra payload copy |
| `wav_read` 60 s stereo | 58.5 | 44.0 | 44.0 | file + samples in RAM |
| PNG 1180×760 | 24.0 | 6.88 | 6.87 | 2× raw frame |
| PNG 1920×1080 | 55.2 | 15.87 | 15.85 | 2× raw frame |
| `ui-test` full tour ×20 | 7846 | — | — | 392 ms/run, RSS +456 KB |

Per-frame temp-allocator writes (measured with a private temp arena):

| frame | bytes/frame | with `free_all` per frame |
|---|---:|---:|
| 1180×760 normal | 224 B | 0 B |
| 1920×1080 normal | 224 B | 0 B |
| 1180×760 FX | 392 B | 0 B |
| 1920×1080 FX | 392 B | 0 B |

## Leaks found

1. **UI frame loop never resets the temporary allocator** — `src/ui_window.odin:93-177`
   (`app_draw` at line 170), and the same pattern in `src/ui_harness.odin:147`.
   `fmt.tprintf` in `src/ui/draw.odin` (lines 222, 226, 269, 309, 323, 358,
   363, 383, 387, 391, 397, 456, 466, 477, 677) allocates every frame from
   `context.temp_allocator` (default arena, 4 MiB `#config` blocks). Nothing
   calls `free_all`; measured 224 B/frame (392 B in the FX rack) ⇒ 13–24 KB/s
   at 60 fps, i.e. a new 4 MiB arena block every few minutes, never returned.
   Controlled proof: a build with
   `-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536` (same code, smaller
   block) grew RSS **+7.3 MB in 120 s** of idle `ui --demo` at 1180×760; the
   stock 4 MiB build refuses to show it for the first minutes because the
   first block is preallocated. With `free_all` per frame the measured growth
   is 0 B/frame.
   *Fix*: `free_all(context.temp_allocator)` at the top of the frame loop, or
   (better, also removes the formatting CPU) replace per-frame `tprintf` with
   `fmt.bprintf` into stack buffers, as `src/jack_capture.odin:224` already
   does.

2. **`ui-test` leaks the parsed script** — `src/ui_harness.odin:74`
   (`json.unmarshal(data, &script)`). The typed unmarshal allocates every
   string in `Harness_Script` (56 actions × ~2 strings) and there is no
   `defer` that frees them. The Odin test runner reports **2,600 leak records
   / 19.4 KB** for 20 in-process harness runs (1,280 per run), and RSS grew
   **+456 KB over 20 runs (22.8 KB/run)**. Harmless for the one-shot CLI
   (process exit), a real leak if the harness is ever embedded, and it is what
   makes `AUDIT_PERF=1 odin test src` print leak lines.
   *Fix*: free `script.name/devices/actions[i].{type,id,key,text,name,path,equals}`
   before returning, or move the script into a scoped arena. Note: the report's
   `Harness_Result.detail` strings are also `tprintf` results stored in a
   struct (`ui_harness.odin:97-98`), so it must be marshalled before any
   `free_all` or changed to `aprintf` + `delete`.

3. **`project_load` leaks its parsed strings if `json.unmarshal` fails** —
   `src/project.odin:320-340`: the cleanup `defer` is registered *after* the
   unmarshal, so a malformed `project.json` that fails mid-document leaks the
   fields already allocated. One-shot CLI impact; trivial to fix by moving the
   defer above the unmarshal (or unmarshalling into a fresh doc and freeing in
   a `defer` set up first).

4. **Everything else was clean at the audit commit.** All 62 DSP, 9 main and
   11 UI tests passed with the runner's memory tracking on, and the audit's tracked scopes report
   `live 0 B` for: App (track names + device clones + command queue), Canvas
   pixels, Engine (session strings, loaded tracks), `render_mix` (output +
   meter timelines + reverb/delay/limiter state), WAV write+read, PNG encode,
   and project save/load. `last_mix` (`src/engine.odin:73`) is allocated
   nowhere — dead field, only deleted at line 121.

## Real-time paths

| path | allocation | locks | syscalls | verdict |
|---|---|---|---|---|
| `recorder_callback` `engine.odin:132-158` | none | none | none | **RT-safe** (lock-free ring, atomics) |
| `playback_callback` `engine.odin:398-435` | none | none | none | **RT-safe** |
| `recorder_writer` `engine.odin:161-193` | one chunk at start | none | `os.write` every 2048 frames | not an RT thread; fine |
| `capture_callback` `capture.odin:43-66` | none | **`sync.Mutex`** | none | **not RT-safe** |
| `jack_process` `jack_capture.odin:66-92` | none | **`sync.Mutex`** | none | **not RT-safe** |

Details:

- `recorder_callback` reads two `sync.atomic_load`s and does a scalar copy.
  The ring is 2 s (`cap_frames = max(rate*2, 4096)`, `engine.odin:279`), the
  writer drains 2048-frame chunks, so overflow needs a 2 s stall. Good.
  Two real defects, both cheap:
  - `r.peak[]` is written by the audio callback (`engine.odin:152,156`) and
    read by the UI thread without atomics (`engine.odin:610`) — a data race
    on `f32`. Torn floats are benign in practice, but it is UB by the memory
    model. Fix: publish peaks as `u32` bits with `atomic_store`/`atomic_load`,
    or move the peak meter to the writer thread.
  - `write_frame`, `read_frame`, `stop` are adjacent `u64`s
    (`engine.odin:32-34`) → one cache line shared by the audio thread, the
    writer thread and the UI. Pad each to 64 B (or group them into
    separately aligned counters). Low impact (one atomic per callback) but
    free to fix.
- `playback_callback` reads `p.samples` (slice written by the UI thread) but
  `engine_stop_playback` calls `ma.device_stop` before `delete(p.samples)`
  (`engine.odin:570-582`), which is synchronous — safe. The only per-sample
  transcendental is the click oscillator, ~12 samples per beat.
- `capture_callback` and `jack_process` take a mutex that the UI/main thread
  also takes (`capture.odin:54`, `jack_capture.odin:74`). A mutex in an audio
  callback is a priority-inversion hazard; the JACK file even documents this
  (`jack_capture.odin:9-12`). The GUI capture path uses the lock-free ring; the
  mutex remains a CLI-path concern.
  `jack_process` also writes with a stride of `channels` per sample (line 85)
  instead of copying each port into a contiguous lane.
- Buffer sizing: both callbacks use `periodSizeInFrames = 1024`
  (`engine.odin:260,549`) = 21.3 ms at 48 kHz. Fine for recording; live
  monitoring was added later and should be re-measured for latency. The writer
  polls every 2 ms (`engine.odin:176`) = 500 wakeups/s while recording;
  a condition variable or a 10 ms poll would cut idle wakeups 5×.
- `engine_render_mix` (`engine.odin:495-513`) is not on an RT thread but runs
  synchronously on the **UI thread** from `engine_play` (`engine.odin:517`)
  and `engine_bounce` (`engine.odin:585`). The benchmark says a 60 s 4-track
  preview costs 0.5–3.2 s of frozen window before playback starts; the window
  loop does not run in between. This is the biggest perceived-performance
  defect after the canvas.

## Top fixes, ranked by impact (status as of the audit)

1. **Bulk canvas fill / clear.** `canvas_fill` (`ui/canvas.odin:109-119`)
   calls `plot` per pixel, and `plot` re-checks the clip and re-blends for
   every pixel (`ui/canvas.odin:68-90`). Measured 6.3 ms for one opaque
   1180×760 fill and 10.5 ms for the 0xC0 translucent fill used by every
   overlay (`ui/draw.odin:451,580,634,666`). A row-wise `memset`/`slice.fill`
   fast path for fully clipped, fully opaque spans, plus a 256-entry
   alpha-blend table or SIMD blend for translucent spans, should take the
   11.2 ms normal frame to ~2-3 ms and the 58.6 ms 1080p FX frame to
   ~10-15 ms. This is the single biggest win in the product: 1080p is
   currently 17 fps in the FX rack.
2. **Compressor's per-sample dB round-trip.** `comp_process`
   (`dsp/compressor.odin:136,147`) calls `lin_to_db` (log10) and `db_to_lin`
   (pow) for every sample of every track. Measured: comp-only render is
   1290 ms vs 477 ms with faders only → **813 ms** for 60 s × 4 tracks;
   `lin_to_db` alone measures 42 ns/call. Fix: keep the detector/gain in the
   linear domain with a 1024-point log/exp lookup (or `exp2` approximation),
   converting to dB only at the 20 Hz meter tick (`render.odin:228-242`).
   Expect ~500-600 ms off a default 60 s render (~35 %).
3. **Canvas temp-arena leak** (finding 1). `free_all(context.temp_allocator)`
   once per frame; better, format labels into stack buffers so the loop
   allocates nothing. Removes 13-24 KB/s of permanent growth and a few
   hundred µs/frame of `fmt` work.
4. **Hoist the pan law out of the render loop.** `render_mix` calls
   `track_mix_pan_gains` inside the per-frame, per-track loop
   (`dsp/render.odin:204`), i.e. 11.5M sin+cos pairs for a 60 s 4-track mix.
   The measured cost of those calls alone is 114 ms; precomputing `gl/gr`
   once per track (as the loop at `render.odin:158` already sets up state)
   removes ~25 % of the faders-only render and ~7 % of the default render for
   a five-line change.
5. **Don't block the UI on render.** `engine_play`/`engine_bounce` render the
   whole mix on the UI thread (`engine.odin:517,585`). Move to a worker
   thread with a progress event, or render in 4096-frame blocks into the
   playback ring. Removes a 0.5-3.2 s window freeze before every preview and
   bounce.
6. **Stream WAV I/O and take splitting.** `wav_write` allocates the whole
   file (`wav.odin:58`), `wav_read` reads the file then allocates the sample
   array (`wav.odin:89,148`), and `engine_split_take` reads the whole take and
   allocates one mono slice per armed track (`engine.odin:351-393`). Measured
   overhead: write peak 22 MB per 60 s stereo (1× extra), read peak 44 MB
   (2×). At the app's documented 1-hour cap, a 4-channel take split is
   ≈2.8 GB (raw read) + 4 × 691 MB (mono tracks) ≈ 5.5 GB peak — an OOM on
   this 13.6 GB machine if anything else is running. Write the 58-byte header,
   then stream 64 KiB chunks; split the take with a chunked reader per track.
7. **PNG encode memory/time.** `png_encode` (`ui/png.odin:33-79`) allocates
   `raw` (w*4+1)*h, `comp` at `compressBound(raw)`, a growing `[dynamic]u8`
   appended byte-by-byte, then a final full copy. Measured 6.9 MB / 24 ms at
   1180×760 and 15.9 MB / 55 ms at 1080p. Reserve the output once, compress
   into a fixed 256 KiB buffer in `deflate` chunks, and write the file in
   place. Also `screenshot` is 10/56 of a full `ui-test` run's 392 ms.
8. **Resampler kernel rebuild + f64 32-tap loop** — `dsp/resample.odin:96`
   rebuilds the 512×32 kernel (66 KB, 33k sin/cos) on every call, and the
   inner loop (`:104-130`) does an f64 multiply-add with a bounds check per
   tap. Measured 729 ms for 60 s mono (277 ns/output sample). Cache the kernel
   per (src,dst) pair and split the loop into a clamped head/tail plus an
   unchecked interior → expect 2-4×. Offline path only.
9. **`ui-test` script leak** (finding 2) — 1 KB/run of JSON strings plus the
   temp arena. Fix before anyone embeds the harness in a long-lived process.
10. **Cleanups:** `last_mix` is dead (`engine.odin:73`); `Recorder.error`
    is written but never read (`engine.odin:188`); `G_RECORDER` is a global
    that limits the process to one recorder (`engine.odin:76`); the default
    session dir fails when `~/.local/share/tracker` does not exist because
    `os.make_directory` does not create parents (`engine.odin:103-107`) —
    reproduce with a fresh HOME: `ui` exits with "cannot create session dir".

## Is the real-time design sound?

Yes for the shipped GUI path: capture and playback callbacks are allocation-
free, lock-free, syscall-free, and the capture ring sized at 2 s gives the
writer thread huge slack. The GUI never runs DSP in a callback; everything is
rendered offline into a buffer. The two mutex callbacks are CLI-only and
already flagged in their own comments. Fix the shared-peak data race and the
false-shared counters when the capture path is next touched; neither will
produce audible glitches today.
