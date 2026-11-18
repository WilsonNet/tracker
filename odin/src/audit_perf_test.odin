// Performance + leak audit harness.
//
// This file is measurement only: it is compiled by `odin test`, never by
// `odin build`, and it does not touch the app's code paths. Run it with:
//
//   odin test src -define:ODIN_TEST_THREADS=1 \
//     -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lSDL2"
//
// Why one thread: the benchmark rows are wall-clock timings, and the default
// 16-thread test runner would measure contention between tests.
//
// Reported numbers: wall milliseconds, bytes allocated by the operation
// (tracked with core:mem's tracking allocator) and peak live bytes. UI frame
// rows also report bytes written to the temporary allocator per frame, which
// is the long-session leak surface. See odin/PERF.md for the findings.

package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"

import dsp "dsp"
import ui "ui"

AUDIT_MB :: f64(1024 * 1024)

// ---------------------------------------------------------------- utilities

// Resident set size of this process in KiB, from /proc/self/statm. Linux-only,
// returns 0 elsewhere. Used to confirm that a repeated operation does not grow
// the process.
audit_rss_kb :: proc() -> int {
	when ODIN_OS == .Linux {
		f, err := os.open("/proc/self/statm", os.O_RDONLY)
		if err != nil {
			return 0
		}
		defer os.close(f)
		buf: [128]u8
		n, rerr := os.read(f, buf[:])
		if rerr != nil || n <= 0 {
			return 0
		}
		// "size resident shared text lib data dt" (all in pages).
		text := string(buf[:n])
		fields := 0
		for i in 0 ..< len(text) {
			if text[i] == ' ' {
				fields += 1
				if fields == 1 {
					start := i + 1
					val := 0
					for j in start ..< len(text) {
						if text[j] == ' ' {
							return val * 4096 / 1024
						}
						val = val * 10 + int(text[j] - '0')
					}
				}
			}
		}
	}
	return 0
}

audit_ms :: proc(since: time.Time) -> f64 {
	return time.duration_milliseconds(time.since(since))
}

// Tracking allocator scope: everything allocated through `context.allocator`
// between begin/end is counted, including peak live bytes.
//
// Odin passes `context` by value into each call, so the assignment to
// `context.allocator` MUST happen in the same procedure body that calls the
// measured code (a helper that sets it only changes the helper's own copy).
Audit_Track :: struct {
	ta:   mem.Tracking_Allocator,
	prev: mem.Allocator,
}

audit_track_begin :: proc(t: ^Audit_Track) -> mem.Allocator {
	t.prev = context.allocator
	mem.tracking_allocator_init(&t.ta, t.prev, t.prev)
	return mem.tracking_allocator(&t.ta)
}

audit_track_end :: proc(t: ^Audit_Track) -> (total_mb, peak_mb: f64, allocs: int, leaked: int) {
	total_mb = f64(t.ta.total_memory_allocated) / AUDIT_MB
	peak_mb = f64(t.ta.peak_memory_allocated) / AUDIT_MB
	allocs = int(t.ta.total_allocation_count)
	leaked = int(t.ta.current_memory_allocated)
	return
}

audit_track_destroy :: proc(t: ^Audit_Track) {
	mem.tracking_allocator_destroy(&t.ta)
}

// Temporary-allocator probe. Replaces context.temp_allocator with a fresh
// arena so the audit can read exactly how many bytes a frame writes into it
// (that is what a long-running loop leaks when it never calls free_all).
Audit_Temp :: struct {
	ta:    mem.Tracking_Allocator,
	arena: runtime.Default_Temp_Allocator,
	prev:  mem.Allocator,
}

audit_temp_begin :: proc(t: ^Audit_Temp, block_size := 64 * 1024) -> mem.Allocator {
	t.prev = context.temp_allocator
	mem.tracking_allocator_init(&t.ta, context.allocator, context.allocator)
	runtime.default_temp_allocator_init(&t.arena, block_size, mem.tracking_allocator(&t.ta))
	return runtime.default_temp_allocator(&t.arena)
}

audit_temp_used :: proc(t: ^Audit_Temp) -> int {
	return int(t.arena.arena.total_used)
}

audit_temp_capacity :: proc(t: ^Audit_Temp) -> int {
	return int(t.arena.arena.total_capacity)
}

audit_temp_end :: proc(t: ^Audit_Temp) {
	runtime.default_temp_allocator_destroy(&t.arena)
	mem.tracking_allocator_destroy(&t.ta)
}

// ---------------------------------------------------------------- fixtures

audit_sine :: proc(frames: int, rate: f32, hz: f32, amp: f32 = 0.7) -> []f32 {
	out := make([]f32, frames)
	for i in 0 ..< frames {
		// Two partials so the compressor sees realistic crest factor.
		t := f32(i) / rate
		out[i] = amp * (math.sin(t * hz * f32(math.TAU)) +
			f32(0.35) * math.sin(t * hz * 2.01 * f32(math.TAU)))
	}
	return out
}

audit_free_tracks :: proc(tracks: [][]f32) {
	for track in tracks {
		delete(track)
	}
	delete(tracks)
}

// ---------------------------------------------------------------- rows

Audit_Row :: struct {
	name:     string,
	ms:       f64,
	alloc_mb: f64,
	peak_mb:  f64,
	note:     string,
}

audit_print_header :: proc(title: string) {
	fmt.printfln("")
	fmt.printfln("== %s ==", title)
	fmt.printfln("%-42s %9s %8s %8s  %s", "case", "ms", "allocMB", "peakMB", "note")
	fmt.printfln("%-42s %9s %8s %8s  %s", "------------------------------------------", "---------", "--------", "--------", "----")
}

audit_print_row :: proc(r: Audit_Row) {
	fmt.printfln("%-42s %9.2f %8.2f %8.2f  %s", r.name, r.ms, r.alloc_mb, r.peak_mb, r.note)
}

// ---------------------------------------------------------------- benchmarks

Render_Chain :: enum {
	Flat,     // faders/pans only: no EQ, comp or limiter
	Eq_Only,  // EQ only
	Comp_Only, // track comp only
	Dynamics, // EQ + track comp, no master FX
	Default,  // EQ + comp + limiter (the app's default)
	Full,     // + master comp, reverb, delay, widener sends
}

@(private)
audit_bench_render :: proc(name: string, tracks_n, frames: int, rate: f32, chain: Render_Chain) -> Audit_Row {
	tracks := make([][]f32, tracks_n)
	for i in 0 ..< tracks_n {
		tracks[i] = audit_sine(frames, rate, 110.0 + f32(i) * 47.0)
	}
	defer audit_free_tracks(tracks)

	settings := dsp.fx_settings_default()
	settings.tracks = make([]dsp.Track_Mix, tracks_n)
	defer delete(settings.tracks)
	for i in 0 ..< tracks_n {
		tm := dsp.track_mix_default()
		tm.level = 0.8
		tm.pan = f32(i - 1) * 0.3
		if chain == .Full {
			tm.send_reverb = 0.25
			tm.send_delay = 0.2
		}
		switch chain {
		case .Flat:
			tm.eq.enabled = false
			tm.comp.enabled = false
		case .Eq_Only:
			tm.comp.enabled = false
		case .Comp_Only:
			tm.eq.enabled = false
		case .Dynamics, .Default, .Full:
		}
		if tm.eq.enabled && (chain == .Eq_Only || chain == .Dynamics) {
			// Flat EQ is bypassed by eq_new, so the EQ rows need a real curve.
			tm.eq.low_db = 3.0
			tm.eq.mid_db = -2.0
			tm.eq.high_db = 1.5
		}
		settings.tracks[i] = tm
	}
	switch chain {
	case .Flat, .Eq_Only, .Comp_Only, .Dynamics:
		settings.limiter.enabled = false
	case .Default:
	case .Full:
		settings.limiter.enabled = true
		settings.master_comp.enabled = true
		settings.reverb.enabled = true
		settings.delay.enabled = true
		settings.width.enabled = true
	}

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	t0 := time.now()
	out := dsp.render_mix(tracks, settings, rate)
	ms := audit_ms(t0)
	dsp.render_destroy(&out)
	alloc, peak, _, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)

	note := fmt.tprintf("%d tr x %.0fs (frames %d)", tracks_n, f32(frames) / rate, out.frames)
	return Audit_Row{name = name, ms = ms, alloc_mb = alloc, peak_mb = peak, note = note if leaked == 0 else "LEAK"}
}

@(private)
audit_bench_limiter :: proc(frames: int, rate: f32) -> Audit_Row {
	input := audit_sine(frames, rate, 82.0, 0.95)
	defer delete(input)

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	t0 := time.now()
	lim := dsp.limiter_new(rate, dsp.limiter_params_default())
	peak: f32 = 0
	for i in 0 ..< frames {
		v := input[i]
		l, r := dsp.limiter_process(&lim, v, -v * 0.7)
		peak = max(peak, abs(l), abs(r))
	}
	ms := audit_ms(t0)
	gr := dsp.limiter_gain_reduction_db(&lim)
	dsp.limiter_destroy(&lim)
	alloc, mem_peak, _, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)

	note := fmt.tprintf("%.0fs mono->stereo, GR %.1f dB, peak %.2f", f32(frames) / rate, gr, peak)
	return Audit_Row{name = "limiter 10 s @48k", ms = ms, alloc_mb = alloc, peak_mb = mem_peak, note = note if leaked == 0 else "LEAK"}
}

@(private)
audit_bench_resample :: proc(frames: int, src_rate, dst_rate: u32) -> Audit_Row {
	input := audit_sine(frames, f32(src_rate), 440.0, 0.5)
	defer delete(input)

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	t0 := time.now()
	out := dsp.resample(input, src_rate, dst_rate)
	ms := audit_ms(t0)
	out_len := len(out)
	delete(out)
	alloc, peak, _, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)

	note := fmt.tprintf("%d Hz -> %d Hz, %d frames", src_rate, dst_rate, out_len)
	return Audit_Row{name = "resample 60 s @48k->44.1k", ms = ms, alloc_mb = alloc, peak_mb = peak, note = note if leaked == 0 else "LEAK"}
}

// Draw `frames` frames of the real app and report the per-frame temp-allocator
// write volume (the leak surface) and the frame cost.
@(private)
audit_bench_ui :: proc(name: string, width, height: int, frames: int, mode: ui.Mode) -> Audit_Row {
	a: ui.App
	ui.app_init(&a, width, height)
	a.demo = true
	a.transport = .Playing
	a.time = 1.3
	for i in 0 ..< ui.MAX_TRACKS {
		a.tracks[i].has_audio = true
		a.tracks[i].peak_db = -12.0 - f32(i)
	}
	a.mode = mode

	c: ui.Canvas
	ui.canvas_init(&c, width, height)

	// Warm up: first frame touches fresh pages, allocate nothing per frame after.
	for _ in 0 ..< 5 {
		ui.app_draw(&a, &c)
	}

	temp: Audit_Temp
	context.temp_allocator = audit_temp_begin(&temp)
	t0 := time.now()
	for i in 0 ..< frames {
		a.time += 0.016
		ui.app_draw(&a, &c)
	}
	ms := audit_ms(t0) / f64(frames)
	used := audit_temp_used(&temp)

	// A/B: resetting the frame arena each frame keeps usage flat at one
	// frame's worth instead of growing for the life of the process.
	free_all(context.temp_allocator)
	for _ in 0 ..< 20 {
		a.time += 0.016
		ui.app_draw(&a, &c)
		free_all(context.temp_allocator)
	}
	used_reset := audit_temp_used(&temp)
	capacity := audit_temp_capacity(&temp)
	context.temp_allocator = temp.prev
	audit_temp_end(&temp)

	pixels_mb := f64(c.width * c.height * 4) / AUDIT_MB
	ui.canvas_destroy(&c)
	ui.app_destroy(&a)

	note := fmt.tprintf("%dx%d, %.2f MB canvas, temp %.0f B/frame (%d B with free_all), arena %d KB", width, height, pixels_mb, f64(used) / f64(frames), used_reset, capacity / 1024)
	return Audit_Row{name = name, ms = ms, alloc_mb = pixels_mb, peak_mb = pixels_mb, note = note}
}

// Cost of the per-frame pan law: render_mix computes these gains inside the
// sample loop, so a 60 s 4-track mix calls sin+cos 11.5M times.
@(private)
audit_bench_pan :: proc(iters: int) -> Audit_Row {
	tm := dsp.track_mix_default()
	tm.pan = 0.3
	acc: f32 = 0
	t0 := time.now()
	for _ in 0 ..< iters {
		l, r := dsp.track_mix_pan_gains(tm)
		acc += l + r
	}
	ms := audit_ms(t0)
	note := fmt.tprintf("%d calls = 4 tr x 60 s @48k (acc %.3f)", iters, acc)
	return Audit_Row{name = "pan_gains (trig) 11.5M calls", ms = ms, note = note}
}

// Cost of the per-sample dB conversion used by the compressor and limiter.
@(private)
audit_bench_log :: proc(iters: int) -> Audit_Row {
	acc: f32 = 0
	t0 := time.now()
	for i in 0 ..< iters {
		x := f32(i % 997) * 0.001 + 0.001
		acc += dsp.lin_to_db(x)
	}
	ms := audit_ms(t0)
	note := fmt.tprintf("%d log10 calls (acc %.1f)", iters, acc)
	return Audit_Row{name = "lin_to_db (log10) 2.88M calls", ms = ms, note = note}
}

// Full-screen fill cost, the dominant primitive of the software canvas.
@(private)
audit_bench_fill :: proc(name: string, width, height: int, col: ui.Color, iters: int) -> Audit_Row {
	c: ui.Canvas
	ui.canvas_init(&c, width, height)
	defer ui.canvas_destroy(&c)
	r := ui.Rect{0, 0, f32(width), f32(height)}

	ui.canvas_fill(&c, r, col)
	t0 := time.now()
	for _ in 0 ..< iters {
		ui.canvas_fill(&c, r, col)
	}
	ms := audit_ms(t0) / f64(iters)

	mb := f64(width * height * 4) / AUDIT_MB
	kind := "opaque" if (col >> 24) == 0xFF else "alpha"
	note := fmt.tprintf("%dx%d %s full-screen fill, %.1f Mpix/s", width, height, kind, f64(width * height) * 1000.0 / (ms * 1e6))
	return Audit_Row{name = name, ms = ms, alloc_mb = mb, peak_mb = mb, note = note}
}

// WAV write/read cost and peak memory for a 60 s stereo float file.
@(private)
audit_bench_wav :: proc(frames: int, rate: u32) -> (write_row, read_row: Audit_Row) {
	samples := make([]f32, frames * 2)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = math.sin(f32(i) * 0.01) * 0.4
	}
	path := "/tmp/tracker-odin-audit-60s.wav"
	defer os.remove(path)
	in_mb := f64(len(samples) * 4) / AUDIT_MB

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	t0 := time.now()
	ok := wav_write(path, rate, 2, samples)
	ms := audit_ms(t0)
	alloc, peak, _, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)
	write_row = Audit_Row{
		name     = "wav_write 60 s stereo",
		ms       = ms,
		alloc_mb = alloc,
		peak_mb  = peak,
		note     = fmt.tprintf("%.0f MB payload, wrote %v", in_mb, ok) if leaked == 0 else "LEAK",
	}

	tr2: Audit_Track
	context.allocator = audit_track_begin(&tr2)
	t0 = time.now()
	w, rok := wav_read(path)
	ms = audit_ms(t0)
	if rok {
		wav_destroy(&w)
	}
	alloc2, peak2, _, leaked2 := audit_track_end(&tr2)
	context.allocator = tr2.prev
	audit_track_destroy(&tr2)
	read_row = Audit_Row{
		name     = "wav_read 60 s stereo",
		ms       = ms,
		alloc_mb = alloc2,
		peak_mb  = peak2,
		note     = fmt.tprintf("%.0f MB file, read %v", in_mb, rok) if leaked2 == 0 else "LEAK",
	}
	return
}

// One PNG encode at the given size, measured with the tracking allocator.
@(private)
audit_bench_png :: proc(width, height: int) -> Audit_Row {
	c: ui.Canvas
	ui.canvas_init(&c, width, height)
	// A little content so compression is not all-zero noise.
	for i in 0 ..< min(len(c.pixels), 200_000) {
		c.pixels[i] = 0xFF20 + u32(i & 0xFF)
	}
	path := fmt.tprintf("/tmp/tracker-odin-audit-%dx%d.png", width, height)
	defer os.remove(path)

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	t0 := time.now()
	ok := ui.canvas_screenshot(&c, path)
	ms := audit_ms(t0)
	alloc, peak, _, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)
	ui.canvas_destroy(&c)

	note := fmt.tprintf("%dx%d, wrote %v", width, height, ok)
	return Audit_Row{name = fmt.tprintf("png %dx%d", width, height), ms = ms, alloc_mb = alloc, peak_mb = peak, note = note if leaked == 0 else "LEAK"}
}

// The real `ui-test` command, 20 times. `full-tour.json` is the 56-action
// smoke tour with 10 screenshots, so this measures the harness, the click
// routing, the draw path and PNG encoding together.
@(private)
audit_bench_ui_test :: proc(runs: int) -> Audit_Row {
	script := "tests/ui/full-tour.json"
	if !os.exists(script) {
		script = "../tests/ui/full-tour.json"
	}
	if !os.exists(script) {
		return Audit_Row{name = "ui-test x20", note = "script not found (run from odin/)"}
	}
	out_dir := "/tmp/tracker-odin-audit-ui"
	if !os.exists(out_dir) {
		_ = os.make_directory(out_dir)
	}

	rss_before := audit_rss_kb()
	t0 := time.now()
	passed := 0
	for i in 0 ..< runs {
		if run_ui_test([]string{"--script", script, "--out", out_dir}) {
			passed += 1
		}
	}
	ms := audit_ms(t0)
	rss_after := audit_rss_kb()

	note := fmt.tprintf("%d runs, %d passed, RSS %+d KB (%.1f KB/run)", runs, passed, rss_after - rss_before, f64(rss_after - rss_before) / f64(runs))
	return Audit_Row{name = fmt.tprintf("ui-test x%d (full tour)", runs), ms = ms, note = note}
}

// ---------------------------------------------------------------- benchmark test

@(test)
audit_perf_benchmarks :: proc(t: ^testing.T) {
	// The full benchmark takes ~20 s; keep the default unit-test run fast.
	// Run with: AUDIT_PERF=1 odin test src -define:ODIN_TEST_THREADS=1 ...
	if os.get_env("AUDIT_PERF", context.temp_allocator) == "" {
		fmt.printfln("AUDIT PERF skipped (set AUDIT_PERF=1 to run the benchmark rows)")
		return
	}

	rate: f32 = 48_000
	frames_60s := int(rate) * 60

	fmt.printfln("")
	fmt.printfln("AUDIT PERF — %v, Odin, 1 test thread", ODIN_OS)
	fmt.printfln("RSS at start: %d KB", audit_rss_kb())

	audit_print_header("DSP / engine throughput")
	audit_print_row(audit_bench_render("render 4x60s, faders only", 4, frames_60s, rate, .Flat))
	audit_print_row(audit_bench_render("render 4x60s, EQ only", 4, frames_60s, rate, .Eq_Only))
	audit_print_row(audit_bench_render("render 4x60s, comp only", 4, frames_60s, rate, .Comp_Only))
	audit_print_row(audit_bench_render("render 4x60s, EQ+comp", 4, frames_60s, rate, .Dynamics))
	audit_print_row(audit_bench_render("render 4x60s, default FX", 4, frames_60s, rate, .Default))
	audit_print_row(audit_bench_render("render 4x60s, full chain", 4, frames_60s, rate, .Full))
	audit_print_row(audit_bench_limiter(int(rate) * 10, rate))
	audit_print_row(audit_bench_resample(frames_60s, 48_000, 44_100))
	audit_print_row(audit_bench_pan(11_520_000))
	audit_print_row(audit_bench_log(2_880_000))

	audit_print_header("UI frame cost (per frame)")
	audit_print_row(audit_bench_ui("ui frame 1180x760 normal", 1180, 760, 60, .Normal))
	audit_print_row(audit_bench_ui("ui frame 1920x1080 normal", 1920, 1080, 30, .Normal))
	audit_print_row(audit_bench_ui("ui frame 1180x760 fx rack", 1180, 760, 60, .Fx))
	audit_print_row(audit_bench_ui("ui frame 1920x1080 fx rack", 1920, 1080, 30, .Fx))

	audit_print_header("Canvas primitives")
	audit_print_row(audit_bench_fill("canvas fill 1180x760 opaque", 1180, 760, 0xFF101010, 40))
	audit_print_row(audit_bench_fill("canvas fill 1180x760 alpha", 1180, 760, 0xC00A0A0A, 40))
	audit_print_row(audit_bench_fill("canvas fill 1920x1080 opaque", 1920, 1080, 0xFF101010, 20))
	audit_print_row(audit_bench_fill("canvas fill 1920x1080 alpha", 1920, 1080, 0xC00A0A0A, 20))

	audit_print_header("Persistence / screenshots / harness")
	write_row, read_row := audit_bench_wav(int(rate) * 60, 48_000)
	audit_print_row(write_row)
	audit_print_row(read_row)
	audit_print_row(audit_bench_png(1180, 760))
	audit_print_row(audit_bench_png(1920, 1080))
	audit_print_row(audit_bench_ui_test(20))

	fmt.printfln("")
	fmt.printfln("RSS at end: %d KB", audit_rss_kb())
	testing.expect(t, true, "benchmark completed")
}

// ---------------------------------------------------------------- leak tests

@(test)
audit_leak_ui_and_canvas :: proc(t: ^testing.T) {
	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	names := [3]string{"Scarlett 4i4", "MX Brio", "Ryzen Mic"}
	ui.app_set_devices(&a, names[:], 1)
	c: ui.Canvas
	ui.canvas_init(&c, 1180, 760)
	for _ in 0 ..< 3 {
		ui.app_draw(&a, &c)
	}
	ui.canvas_destroy(&c)
	ui.app_destroy(&a)

	alloc, peak, count, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)
	fmt.printfln("[leak] ui app+canvas: alloc %.2f MB peak %.2f MB (%d allocs), live after destroy %d B", alloc, peak, count, leaked)
	testing.expectf(t, leaked == 0, "ui app/canvas leaked %d bytes", leaked)
}

@(test)
audit_leak_render_and_wav :: proc(t: ^testing.T) {
	rate: u32 = 48_000
	frames := int(rate) * 2
	tracks := make([][]f32, 4)
	for i in 0 ..< 4 {
		tracks[i] = audit_sine(frames, f32(rate), 220.0 + f32(i) * 33.0)
	}
	defer audit_free_tracks(tracks)

	settings := dsp.fx_settings_default()
	settings.tracks = make([]dsp.Track_Mix, 4)
	defer delete(settings.tracks)
	for i in 0 ..< 4 {
		settings.tracks[i] = dsp.track_mix_default()
	}

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	out := dsp.render_mix(tracks, settings, f32(rate))
	dsp.render_destroy(&out)
	alloc, peak, count, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)
	fmt.printfln("[leak] render_mix 4x2s: alloc %.2f MB peak %.2f MB (%d allocs), live %d B", alloc, peak, count, leaked)
	testing.expectf(t, leaked == 0, "render_mix leaked %d bytes", leaked)

	path := "/tmp/tracker-odin-audit.wav"
	defer os.remove(path)

	tr2: Audit_Track
	context.allocator = audit_track_begin(&tr2)
	ok := wav_write(path, rate, 1, tracks[0])
	w, read_ok := wav_read(path)
	if read_ok {
		wav_destroy(&w)
	}
	alloc2, peak2, count2, leaked2 := audit_track_end(&tr2)
	context.allocator = tr2.prev
	audit_track_destroy(&tr2)
	fmt.printfln("[leak] wav write+read: alloc %.2f MB peak %.2f MB (%d allocs), live %d B", alloc2, peak2, count2, leaked2)
	testing.expect(t, ok && read_ok, "wav write/read failed")
	testing.expectf(t, leaked2 == 0, "wav round-trip leaked %d bytes", leaked2)
}

@(test)
audit_leak_engine_and_project :: proc(t: ^testing.T) {
	session := "/tmp/tracker-odin-audit-session"
	if !os.exists(session) {
		_ = os.make_directory(session)
	}

	tr: Audit_Track
	context.allocator = audit_track_begin(&tr)
	e: Engine
	ok := engine_init(&e, []string{"--session", session})
	engine_destroy(&e)
	alloc, peak, count, leaked := audit_track_end(&tr)
	context.allocator = tr.prev
	audit_track_destroy(&tr)
	fmt.printfln("[leak] engine_init+destroy: alloc %.2f MB peak %.2f MB (%d allocs), live %d B", alloc, peak, count, leaked)
	testing.expect(t, ok, "engine_init failed")
	testing.expectf(t, leaked == 0, "engine lifecycle leaked %d bytes", leaked)

	path := fmt.tprintf("%s/project.json", session)
	defer os.remove(path)

	// One scope covers the App and the JSON document: project_save allocates
	// the encoded document, project_load clones track names into the App, and
	// app_destroy must free both. Anything still live here is a real leak.
	tr2: Audit_Track
	context.allocator = audit_track_begin(&tr2)
	a: ui.App
	ui.app_init(&a, 1180, 760)
	ui.app_set_project(&a, "audit")
	saved := project_save(&a, path)
	loaded := project_load(&a, session, path)
	ui.app_destroy(&a)
	alloc2, peak2, count2, leaked2 := audit_track_end(&tr2)
	context.allocator = tr2.prev
	audit_track_destroy(&tr2)
	fmt.printfln("[leak] app+project save+load+destroy: alloc %.2f MB peak %.2f MB (%d allocs), live %d B", alloc2, peak2, count2, leaked2)
	testing.expect(t, saved && loaded, "project save/load failed")
	testing.expectf(t, leaked2 == 0, "project round-trip leaked %d bytes", leaked2)
}
