// Live engine: streaming capture, preview playback, bounce and project I/O.
//
// Capture runs on a miniaudio callback that only copies into a lock-free ring;
// a writer thread drains it to a raw take file. Stopping the take splits that
// file into per-track float WAVs.

package main

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import dsp "dsp"
import ui "ui"
import ma "vendor:miniaudio"

MAX_ENGINE_TRACKS :: ui.MAX_TRACKS
RING_CHUNK_FRAMES :: 2048

Recorder :: struct {
	active:       bool,
	// True once the miniaudio device/context have been initialised, so every
	// teardown path can release exactly what was opened.
	device_open:  bool,
	ctx_open:     bool,
	ctx:          ma.context_type,
	device:       ma.device,
	ring:         []f32,
	cap_frames:   int,
	channels:     int,
	write_frame:  u64,
	read_frame:   u64,
	stop:         u64,
	overflow:     u64,
	raw:          ^os.File,
	writer:       ^thread.Thread,
	rate:         u32,
	armed:        [MAX_ENGINE_TRACKS]bool,
	inputs:       [MAX_ENGINE_TRACKS]int,
	peak:         [32]f32,
	error:        bool,
	// Live monitoring through the duplex path. `monitoring` records whether
	// this take actually opened a duplex device (it can fall back to capture).
	monitor:      Monitor,
	monitoring:   bool,
	// Device-loss bookkeeping. Deliberate stop paths set `stop_expected` first
	// so their own `stopped` notification does not look like a hot-unplug.
	stop_expected: u64,
	interrupt:     u64,
}

Playback :: struct {
	active:               bool,
	ctx_open:             bool,
	device_open:          bool,
	device_rate:          u32,
	ctx:                  ma.context_type,
	device:               ma.device,
	playing:              u32,
	cb_active:            u32,
	samples:              []f32,
	frames:               int,
	cursor:               i64,
	rate:                 u32,
	silent:               bool,
	unbounded:            bool,
	use_live_mixer:       bool,
	mute_armed:           bool,
	tracks:               [MAX_ENGINE_TRACKS][]f32,
	track_count:          int,
	mixer:                dsp.Live_Mixer,
	mixer_rate:           u32,
	mixer_seek_gen:       u64,
	fade_in_left:         int,
	fade_in_len:          int,
	last_l:               f32,
	last_r:               f32,
	fade_out_left:        int,
	fade_out_len:         int,
	was_playing:          bool,
	param_slots:          [3]dsp.Live_Mix_Params,
	param_ui_slot:        int,
	param_shared:         u32,
	param_audio_slot:     int,
	last_published_params: dsp.Live_Mix_Params,
	has_published_params: bool,
	track_peak:           [MAX_ENGINE_TRACKS]f32,
	track_gr:             [MAX_ENGINE_TRACKS]f32,
	master_peak:          f32,
	master_gr:            f32,
	click_enabled:        bool,
	click_absolute:       bool,
	click_origin:         i64,
	countin_click_active: bool,
	countin_click_until:  i64,
	bpm:                  int,
	sig_num:              int,
	sig_den:              int,
	seek_gen:             u64,
	last_seek_gen:        u64,
	last_beat_idx:        i64,
	has_last_beat:        bool,
	click_left:           int,
	click_len:            int,
	click_phase:          f32,
	click_freq:           f32,
	click_amp:            f32,
	stop_expected:        u64,
	interrupt:            u64,
}

// Input preview while at least one track is armed and the transport is idle.
// It opens a capture-only device and publishes per-channel peaks, so the
// input history graph is live before REC. No ring, writer or take file.
Preview :: struct {
	active:        bool,
	device_open:   bool,
	ctx_open:      bool,
	ctx:           ma.context_type,
	device:        ma.device,
	channels:      int,
	rate:          u32,
	peak:          [32]f32,
	interrupt:     u64,
	stop_expected: u64,
	device_index:  int,
	failed:        bool,
	signature:     u64,
}

Capture_Backend :: enum u8 {
	Miniaudio,
	Jack,
}

Engine :: struct {
	session_dir:  string,
	project_path: string,
	take_path:    string,
	bounce_path:  string,
	sample_rate:          u32,
	device_index:         int,
	default_device_index: int,
	// Live input monitoring is opt-in and only active during a take.
	monitor_enabled: bool,
	// Frames to trim from the start of a new take when splitting it. The
	// round-trip latency of the capture device belongs here; default 0.
	latency_ms:   f32,
	// Punch-in: the take starts at `rec_punch` (timeline frames at the engine
	// rate); the guide plays from `rec_punch - rec_pre`, and those `rec_pre`
	// frames of pre-roll are dropped from the capture when it is split.
	rec_punch:    int,
	rec_pre:      int,
	loaded:            [MAX_ENGINE_TRACKS][]f32,
	loaded_rate:       [MAX_ENGINE_TRACKS]u32,
	play_tracks:       [MAX_ENGINE_TRACKS][]f32,
	play_tracks_owned: [MAX_ENGINE_TRACKS]bool,
	play_tracks_rate:  u32,
	play_tracks_dirty: bool,
	rec:               Recorder,
	preview:           Preview,
	play:              Playback,
	backend:           Capture_Backend,
	jack:              Jack_Session,
	takes:             [MAX_ENGINE_TRACKS]Take_List,
}

// ---------------------------------------------------------------- helpers

// Maps a 1-based track input to a channel index on a device that opened
// `channels` wide. The reference Rust engine wraps out-of-range inputs with
// `% channels`; doing the same here means an 8-channel input selector on a
// 2-channel device still records audio instead of silently writing a blank
// track when the backend falls back to fewer channels.
@(private)
recorder_input_channel :: proc(input, channels: int) -> int {
	if channels <= 0 {
		return -1
	}
	if input <= 0 {
		return 0
	}
	ch := input - 1
	if ch >= channels {
		ch = ch % channels
	}
	return ch
}

engine_device_names :: proc() -> []string {
	return capture_device_names()
}

engine_default_device :: proc() -> int {
	return capture_default_index()
}

engine_init :: proc(e: ^Engine, args: []string) -> bool {
	e.sample_rate = 48_000
	e.device_index = -1
	e.default_device_index = 0
	e.monitor_enabled = false
	e.latency_ms = 0
	e.play_tracks_dirty = true
	dir := flag_string(args, "--session", "")
	if dir == "" {
		dir = default_session_dir()
	} else {
		dir = fmt.aprintf("%s", dir)
	}
	e.session_dir = dir
	e.project_path = fmt.aprintf("%s/project.json", dir)
	e.take_path = fmt.aprintf("%s/take.raw", dir)
	e.bounce_path = fmt.aprintf("%s/bounce.wav", dir)
	if os.exists(dir) {
		if !os.is_directory(dir) {
			fmt.eprintfln("session path is not a directory: %s", dir)
			delete(e.session_dir)
			delete(e.project_path)
			delete(e.take_path)
			delete(e.bounce_path)
			e.session_dir = ""
			e.project_path = ""
			e.take_path = ""
			e.bounce_path = ""
			return false
		}
	} else if err := os.make_directory_all(dir); err != nil {
		fmt.eprintfln("cannot create session dir %s", dir)
		delete(e.session_dir)
		delete(e.project_path)
		delete(e.take_path)
		delete(e.bounce_path)
		e.session_dir = ""
		e.project_path = ""
		e.take_path = ""
		e.bounce_path = ""
		return false
	}
	return true
}

engine_destroy :: proc(e: ^Engine) {
	engine_preview_stop(e)
	engine_stop_playback(e)
	playback_release_device(e)
	dsp.live_mixer_destroy(&e.play.mixer)
	// Finalize an open take before dropping the take lists: the split needs the
	// previous active take metadata to stabilize the old canonical WAV, otherwise
	// the new partial capture overwrites the take project.json still points at.
	if e.rec.active || jack_session_is_running(&e.jack) {
		_ = engine_record_stop(e, nil)
	}
	jack_session_destroy(&e.jack)
	engine_takes_clear(e)
	if e.rec.device_open || e.rec.ctx_open || e.rec.raw != nil || e.rec.writer != nil {
		sync.atomic_store(&e.rec.stop, 1)
		recorder_join_writer(e)
		recorder_release(e, true, true)
	}
	engine_free_play_tracks(e)
	for i in 0 ..< MAX_ENGINE_TRACKS {
		delete(e.loaded[i])
		e.loaded[i] = nil
	}
	delete(e.session_dir)
	delete(e.project_path)
	delete(e.take_path)
	delete(e.bounce_path)
}

engine_set_backend :: proc(e: ^Engine, backend: Capture_Backend) -> bool {
	if backend == .Jack && !platform_supports_jack() {
		return false
	}
	if e.rec.active || jack_session_is_running(&e.jack) {
		return false
	}
	if e.preview.active {
		engine_preview_stop(e)
		e.preview.failed = false
		e.preview.signature = 0
	}
	e.backend = backend
	return true
}

// ---------------------------------------------------------------- capture

// Copies up to `frames` interleaved frames from `src` into the capture ring.
// This is the body of the real-time callback, kept as an ordinary proc so the
// ring and overflow accounting can be exercised without an audio device.
@(private)
recorder_push :: proc "contextless" (r: ^Recorder, src: []f32, frames: int) {
	if r == nil || r.ring == nil || r.channels <= 0 || r.cap_frames <= 0 || frames <= 0 {
		return
	}
	write := sync.atomic_load(&r.write_frame)
	read := sync.atomic_load(&r.read_frame)
	if read > write {
		// Defensive: a corrupt cursor must not make the ring look empty
		// forever. Treat the reader as caught up.
		read = write
	}
	capacity := u64(r.cap_frames)
	pushed := 0
	// Load the meter state once per callback, update it locally, and publish it
	// once. Doing two atomics per sample/channel would be needlessly heavy in
	// the real-time callback.
	peak_channels := min(r.channels, len(r.peak))
	peaks: [32]f32
	for c in 0 ..< peak_channels {
		peaks[c] = sync.atomic_load(&r.peak[c])
	}

	for f in 0 ..< frames {
		if write - read >= capacity {
			break
		}
		base := int(write % capacity) * r.channels
		for c in 0 ..< r.channels {
			idx := f * r.channels + c
			if idx >= len(src) || base + c >= len(r.ring) {
				continue
			}
			v := src[idx]
			r.ring[base + c] = v
			if c < peak_channels {
				peaks[c] = max(peaks[c] * 0.94, abs(v))
			}
		}
		write += 1
		pushed += 1
	}
	sync.atomic_store(&r.write_frame, write)
	for c in 0 ..< peak_channels {
		sync.atomic_store(&r.peak[c], peaks[c])
	}
	if pushed < frames {
		sync.atomic_add(&r.overflow, u64(frames - pushed))
	}
}

@(private)
recorder_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	if device == nil {
		return
	}
	r := cast(^Recorder)device.pUserData
	if r == nil || frame_count == 0 {
		return
	}
	frames := int(frame_count)

	// Duplex devices hand us both buffers. Monitoring writes only through the
	// duplex output and silences itself when disabled or no take is active.
	if output != nil && r.channels > 0 {
		out := cast([^]f32)output
		out_channels := int(device.playback.channels)
		input_samples := cast([^]f32)input if input != nil else nil
		src: []f32
		if input_samples != nil {
			src = input_samples[:frames * r.channels]
		}
		dst := out[:frames * max(out_channels, 0)]
		monitor_mix(&r.monitor, src, dst, frames, r.channels, out_channels)
	}

	if !r.active || input == nil || r.channels <= 0 {
		return
	}
	src := cast([^]f32)input
	recorder_push(r, src[:frames * r.channels], frames)
}

@(private)
recorder_notification :: proc "c" (n: ^ma.device_notification) {
	if n == nil || n.pDevice == nil {
		return
	}
	r := cast(^Recorder)n.pDevice.pUserData
	if r == nil {
		return
	}
	#partial switch n.type {
	case .stopped, .interruption_began:
		// A deliberate stop (take end, teardown) sets this first. Anything
		// else is an unplug or backend failure and must be recovered on the
		// UI thread by `engine_update`.
		if sync.atomic_load(&r.stop_expected) == 0 {
			sync.atomic_store(&r.interrupt, 1)
		}
	case .started:
		// A successful (re)start clears a stale interruption flag.
		sync.atomic_store(&r.interrupt, 0)
	case:
	}
}

@(private)
playback_notification :: proc "c" (n: ^ma.device_notification) {
	if n == nil || n.pDevice == nil {
		return
	}
	p := cast(^Playback)n.pDevice.pUserData
	if p == nil {
		return
	}
	#partial switch n.type {
	case .stopped, .interruption_began:
		if sync.atomic_load(&p.stop_expected) == 0 {
			sync.atomic_store(&p.interrupt, 1)
		}
	case .started:
		sync.atomic_store(&p.interrupt, 0)
	case:
	}
}

// Writes the whole slice, retrying short writes. A bare `os.write` may write
// less than requested (signal interruption, full-ish disk); treating that as a
// complete chunk silently truncates the take.
@(private)
recorder_write_all :: proc(f: ^os.File, data: []byte) -> bool {
	if f == nil {
		return false
	}
	remaining := data
	for len(remaining) > 0 {
		n, err := os.write(f, remaining)
		if err != nil || n <= 0 {
			return false
		}
		if n > len(remaining) {
			return false
		}
		remaining = remaining[n:]
	}
	return true
}

// Drains everything currently in the ring. Runs on the recorder writer thread
// and is also called synchronously by the unit tests.
@(private)
recorder_drain :: proc(r: ^Recorder, chunk: []f32) -> bool {
	if r == nil || r.cap_frames <= 0 || r.channels <= 0 {
		return false
	}
	write := sync.atomic_load(&r.write_frame)
	read := sync.atomic_load(&r.read_frame)
	if read >= write {
		return false
	}
	n := int(min(write - read, u64(RING_CHUNK_FRAMES)))
	capacity := u64(r.cap_frames)
	for f in 0 ..< n {
		frame := (read + u64(f)) % capacity
		base := int(frame) * r.channels
		for c in 0 ..< r.channels {
			chunk[f * r.channels + c] = r.ring[base + c]
		}
	}
	if !recorder_write_all(r.raw, slice.to_bytes(chunk[:n * r.channels])) {
		return false
	}
	sync.atomic_store(&r.read_frame, read + u64(n))
	return true
}

@(private)
recorder_writer :: proc(t: ^thread.Thread) {
	r := cast(^Recorder)t.data
	if r == nil || r.channels <= 0 {
		return
	}
	chunk := make([]f32, RING_CHUNK_FRAMES * r.channels)
	if chunk == nil {
		r.error = true
		return
	}
	defer delete(chunk)

	for {
		if sync.atomic_load(&r.read_frame) >= sync.atomic_load(&r.write_frame) {
			if sync.atomic_load(&r.stop) != 0 {
				break
			}
			time.sleep(2 * time.Millisecond)
			continue
		}
		if !recorder_drain(r, chunk) {
			r.error = true
			break
		}
	}
}

// Creates and *starts* the writer. `thread.create` returns a suspended
// thread, so forgetting `start` leaves the ring to fill and only drains the
// first two seconds at stop time (when `join` starts it).
@(private)
recorder_start_writer :: proc(e: ^Engine) -> bool {
	e.rec.writer = thread.create(recorder_writer)
	if e.rec.writer == nil {
		return false
	}
	e.rec.writer.data = &e.rec
	thread.start(e.rec.writer)
	return true
}

@(private)
recorder_join_writer :: proc(e: ^Engine) {
	if e.rec.writer != nil {
		// `thread.destroy` joins and frees the Thread object. Plain `join`
		// leaks it on every take, and on a never-started thread it also starts
		// the writer only at stop time (so the ring overflows for the whole
		// take).
		thread.destroy(e.rec.writer)
		e.rec.writer = nil
	}
}

// Releases whatever the start path managed to open. The writer must have been
// joined first. `channels`/`rate` are left intact because split_take reads them.
@(private)
recorder_release :: proc(e: ^Engine, close_raw: bool, free_ring: bool) {
	e.rec.active = false
	e.rec.monitoring = false
	monitor_set_enabled(&e.rec.monitor, false)
	if e.rec.device_open {
		// This stop is intentional; keep its notification out of the
		// hot-unplug recovery path.
		sync.atomic_store(&e.rec.stop_expected, 1)
		_ = ma.device_stop(&e.rec.device)
		ma.device_uninit(&e.rec.device)
		e.rec.device_open = false
	}
	if e.rec.ctx_open {
		ma.context_uninit(&e.rec.ctx)
		e.rec.ctx_open = false
	}
	if close_raw && e.rec.raw != nil {
		_ = os.close(e.rec.raw)
		e.rec.raw = nil
	}
	if free_ring {
		delete(e.rec.ring)
		e.rec.ring = nil
		e.rec.cap_frames = 0
	}
}

// ---------------------------------------------------------------- preview

// Decayed block peaks from an interleaved capture block. Kept separate from
// the callback so the meter envelope can be tested without a device.
@(private)
preview_push :: proc "contextless" (p: ^Preview, src: []f32, frames: int) {
	if p == nil || p.channels <= 0 || frames <= 0 {
		return
	}
	peak_channels := min(p.channels, len(p.peak))
	peaks: [32]f32
	for c in 0 ..< peak_channels {
		peaks[c] = sync.atomic_load(&p.peak[c])
	}
	for f in 0 ..< frames {
		base := f * p.channels
		for c in 0 ..< peak_channels {
			idx := base + c
			if idx >= len(src) {
				continue
			}
			peaks[c] = max(peaks[c], abs(src[idx]))
		}
	}
	for c in 0 ..< peak_channels {
		// One decay per callback (~21 ms at 48 kHz / 1024 frames), not per
		// sample, so the 20 Hz UI graph sees a usable envelope.
		sync.atomic_store(&p.peak[c], peaks[c] * 0.94)
	}
}

@(private)
preview_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	if device == nil || input == nil || frame_count == 0 {
		return
	}
	p := cast(^Preview)device.pUserData
	if p == nil || p.channels <= 0 {
		return
	}
	src := cast([^]f32)input
	preview_push(p, src[:int(frame_count) * p.channels], int(frame_count))
}

@(private)
preview_notification :: proc "c" (n: ^ma.device_notification) {
	if n == nil || n.pDevice == nil {
		return
	}
	p := cast(^Preview)n.pDevice.pUserData
	if p == nil {
		return
	}
	#partial switch n.type {
	case .stopped, .interruption_began:
		if sync.atomic_load(&p.stop_expected) == 0 {
			sync.atomic_store(&p.interrupt, 1)
		}
	case .started:
		sync.atomic_store(&p.interrupt, 0)
	case:
	}
}

@(private)
preview_release :: proc(p: ^Preview) {
	if p.device_open {
		sync.atomic_store(&p.stop_expected, 1)
		_ = ma.device_stop(&p.device)
		ma.device_uninit(&p.device)
		p.device_open = false
	}
	if p.ctx_open {
		ma.context_uninit(&p.ctx)
		p.ctx_open = false
	}
	p.active = false
	p.channels = 0
	p.rate = 0
	p.interrupt = 0
	p.stop_expected = 0
	p.device_index = -1
	for i in 0 ..< len(p.peak) {
		sync.atomic_store(&p.peak[i], 0)
	}
}

engine_preview_stop :: proc(e: ^Engine) {
	if e.preview.active || e.preview.device_open || e.preview.ctx_open {
		preview_release(&e.preview)
	}
}

// True when a stopped transport has at least one armed track on a backend we
// can preview. JACK keeps its own session; its meters start with the take.
@(private)
preview_wanted :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if a == nil || a.demo || e.backend != .Miniaudio {
		return false
	}
	if e.rec.active || e.play.active || a.transport != .Stopped {
		return false
	}
	for t in a.tracks {
		if t.armed {
			return true
		}
	}
	return false
}

// Cheap identity of the preview inputs, used to retry a failed open only when
// the arm state, channel mapping or selected device changes.
@(private)
preview_signature :: proc(e: ^Engine, a: ^ui.App) -> u64 {
	sig := u64(0xcbf29ce484222325)
	sig = (sig ~ u64(e.device_index + 1)) * 0x100000001b3
	sig = (sig ~ u64(a.jack_backend)) * 0x100000001b3
	for t in a.tracks {
		sig = (sig ~ u64(t.armed)) * 0x100000001b3
		sig = (sig ~ u64(t.input)) * 0x100000001b3
	}
	return sig
}

@(private)
engine_preview_start :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if e.preview.active || e.rec.active || a == nil || e.backend != .Miniaudio {
		return false
	}
	p := &e.preview
	p.ctx = {}
	if ma.context_init(nil, 0, nil, &p.ctx) != .SUCCESS {
		return false
	}
	p.ctx_open = true

	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&p.ctx, nil, nil, &infos, &count) != .SUCCESS || count == 0 {
		preview_release(p)
		return false
	}

	default_index := capture_find_default_index(&p.ctx, infos, count)
	names := make([]string, int(count))
	for i in 0 ..< int(count) {
		names[i] = capture_device_name(&infos[i])
	}
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	idx, matched := engine_resolve_device_index_ex(e.device_index, ui.app_device(a), names, default_index)
	if idx < 0 {
		preview_release(p)
		return false
	}
	e.default_device_index = default_index
	e.device_index = idx
	engine_sync_ui_device(a, names[idx], matched)

	requested := 1
	for t in a.tracks {
		if t.armed {
			requested = max(requested, t.input)
		}
	}
	requested = clamp(requested, 1, 8)
	attempts_buf, attempt_count := capture_open_attempts(requested)
	attempts := attempts_buf[:attempt_count]

	cfg := ma.device_config_init(.capture)
	cfg.sampleRate = e.sample_rate if e.sample_rate != 0 else 48_000
	cfg.capture.format = .f32
	cfg.capture.pDeviceID = &infos[idx].id
	cfg.dataCallback = preview_callback
	cfg.notificationCallback = preview_notification
	cfg.pUserData = p
	cfg.periodSizeInFrames = 1024
	opened := false
	for attempt in attempts {
		capture_config_unmixed(&cfg, attempt)
		if ma.device_init(&p.ctx, &cfg, &p.device) == .SUCCESS {
			opened = true
			break
		}
	}
	if !opened {
		preview_release(p)
		return false
	}
	p.device_open = true
	p.channels = int(p.device.capture.channels)
	p.rate = p.device.sampleRate
	if p.channels <= 0 || p.rate == 0 {
		preview_release(p)
		return false
	}
	p.stop_expected = 0
	p.interrupt = 0
	for i in 0 ..< len(p.peak) {
		sync.atomic_store(&p.peak[i], 0)
	}
	if ma.device_start(&p.device) != .SUCCESS {
		preview_release(p)
		return false
	}
	p.active = true
	p.device_index = idx
	return true
}

// Keeps the preview stream in step with arm/transport/device changes. Called
// once per frame before the meter mapping.
engine_preview_sync :: proc(e: ^Engine, a: ^ui.App) {
	if a == nil {
		engine_preview_stop(e)
		return
	}
	if e.preview.active && sync.atomic_load(&e.preview.interrupt) != 0 {
		engine_preview_stop(e)
		e.preview.failed = true
		e.preview.signature = preview_signature(e, a)
		a.input_live = false
		ui.status_buf_set(a, "input meter device lost")
	}
	if e.preview.active && e.preview.device_index != e.device_index {
		engine_preview_stop(e)
		e.preview.failed = false
		e.preview.signature = 0
	}
	if !preview_wanted(e, a) {
		if e.preview.active {
			engine_preview_stop(e)
		}
		e.preview.failed = false
		e.preview.signature = 0
		a.input_live = false
		return
	}
	if e.preview.active {
		e.preview.signature = preview_signature(e, a)
		a.input_live = true
		return
	}
	sig := preview_signature(e, a)
	if e.preview.failed && e.preview.signature == sig {
		a.input_live = false
		return
	}
	if engine_preview_start(e, a) {
		e.preview.failed = false
		// Start can reconcile a stale device selection.
		e.preview.signature = preview_signature(e, a)
		a.input_live = true
	} else {
		e.preview.failed = true
		e.preview.signature = preview_signature(e, a)
		a.input_live = false
		ui.status_buf_set(a, "input meter unavailable")
	}
}

engine_record_start :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if e.rec.active || a == nil {
		return false
	}
	// Release the arm preview before taking the device for a real take.
	engine_preview_stop(e)
	e.preview.failed = false
	e.preview.signature = 0

	// Snapshot the arm/input state before touching hardware: the take must
	// represent what was armed when REC was pressed, not what the UI shows
	// when the device finally opens.
	armed_count := 0
	requested := 1
	for i in 0 ..< MAX_ENGINE_TRACKS {
		e.rec.armed[i] = a.tracks[i].armed
		e.rec.inputs[i] = a.tracks[i].input
		if a.tracks[i].armed {
			armed_count += 1
			requested = max(requested, a.tracks[i].input)
		}
	}
	if armed_count == 0 {
		ui.status_buf_set(a, "arm a track first")
		return false
	}
	requested = clamp(requested, 1, 8)

	// Punch-in position chosen in the UI (project-rate frames).
	e.rec_punch = int(max(a.record_punch, 0))
	e.rec_pre = int(max(a.record_pre, 0))

	// The previous preview (if any) must not keep playing under a new take.
	engine_stop_playback(e)

	e.sample_rate = a.sample_rate if a.sample_rate != 0 else 48_000
	e.sample_rate = clamp(e.sample_rate, 8_000, 384_000)

	if e.backend == .Jack {
		// 0 asks the JACK session to adopt the server rate rather than reject
		// the project rate; the UI is updated with the actual rate below.
		// Bind to the selected device's JACK client so track input N is that
		// device's input N; without a match keep the first physical ports.
		jack_ports := jack_port_names()
		defer {
			for p in jack_ports {
				delete(p)
			}
			delete(jack_ports)
		}
		device_ports := jack_ports_for_device(jack_ports, ui.app_device(a))
		defer delete(device_ports)
		chosen := device_ports if len(device_ports) >= requested else nil
		if !jack_session_start(&e.jack, requested, 0, chosen, 0) {
			ui.status_buf_set(a, jack_session_detail(&e.jack))
			return false
		}
		engine_rescale_punch(e, a, e.jack.rate)
		e.sample_rate = e.jack.rate
		a.sample_rate = e.jack.rate
		e.rec.channels = requested
		e.rec.rate = e.jack.rate
		overdub := false
		for i in 0 ..< MAX_ENGINE_TRACKS {
			if e.loaded[i] != nil {
				overdub = true
			}
		}
		start_pos := i64(e.rec_punch - e.rec_pre)
		countin_only := e.rec_pre > 0 && !a.metronome && start_pos < 0
		if overdub || a.metronome || countin_only {
			_ = engine_play(e, a, true, start_pos, true, 0, countin_only, true)
		}
		ui.status_buf_set(a, fmt.tprintf("recording %d ch via JACK @ %d Hz%s", requested, e.jack.rate, " · overdub" if overdub else ""))
		return true
	}

	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		ui.status_buf_set(a, "cannot init audio")
		return false
	}
	e.rec.ctx = ctx
	e.rec.ctx_open = true

	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&e.rec.ctx, nil, nil, &infos, &count) != .SUCCESS || count == 0 {
		recorder_release(e, false, false)
		ui.status_buf_set(a, "no capture devices")
		return false
	}

	// The UI stores the selected device by name. If the index went stale (the
	// device was unplugged and the list shifted), re-resolve by name first,
	// then fall back to the system default instead of recording the wrong box.
	default_index := capture_find_default_index(&e.rec.ctx, infos, count)
	names := make([]string, int(count))
	for i in 0 ..< int(count) {
		names[i] = capture_device_name(&infos[i])
	}
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	idx, matched := engine_resolve_device_index_ex(e.device_index, ui.app_device(a), names, default_index)
	if idx < 0 {
		recorder_release(e, false, false)
		ui.status_buf_set(a, "no capture devices")
		return false
	}
	e.default_device_index = default_index
	e.device_index = idx
	engine_sync_ui_device(a, names[idx], matched)

	// Open the device at its native width first so hardware inputs arrive
	// unmixed and in order (track input N = interface input N); see
	// `capture_config_unmixed`. If that is rejected, fall back to explicit
	// widths instead of failing the take outright. `ma_device_init` zeroes the
	// device on entry, so retrying into the same struct is safe.
	attempts_buf, attempt_count := capture_open_attempts(requested)
	attempts := attempts_buf[:attempt_count]
	opened := false
	monitoring := false

	// Monitoring uses a duplex device so the input and output share one clock
	// and one callback. If duplex init fails (no output device, backend
	// restriction), the take still records capture-only.
	if e.monitor_enabled {
		for playback_channels in ([2]int{2, 1}) {
			cfg := ma.device_config_init(.duplex)
			cfg.sampleRate = e.sample_rate
			cfg.capture.format = .f32
			cfg.capture.pDeviceID = &infos[idx].id
			cfg.playback.format = .f32
			cfg.playback.channels = u32(playback_channels)
			cfg.dataCallback = recorder_callback
			cfg.notificationCallback = recorder_notification
			cfg.pUserData = &e.rec
			cfg.periodSizeInFrames = 1024
			for attempt in attempts {
				capture_config_unmixed(&cfg, attempt)
				if ma.device_init(&e.rec.ctx, &cfg, &e.rec.device) == .SUCCESS {
					opened = true
					monitoring = true
					break
				}
			}
			if opened {
				break
			}
		}
	}

	if !opened {
		cfg := ma.device_config_init(.capture)
		cfg.sampleRate = e.sample_rate
		cfg.capture.format = .f32
		cfg.capture.pDeviceID = &infos[idx].id
		cfg.dataCallback = recorder_callback
		cfg.notificationCallback = recorder_notification
		cfg.pUserData = &e.rec
		cfg.periodSizeInFrames = 1024
		for attempt in attempts {
			capture_config_unmixed(&cfg, attempt)
			if ma.device_init(&e.rec.ctx, &cfg, &e.rec.device) == .SUCCESS {
				opened = true
				break
			}
		}
	}
	if !opened {
		recorder_release(e, false, false)
		ui.status_buf_set(a, "cannot open capture device")
		return false
	}
	e.rec.device_open = true

	e.rec.channels = int(e.rec.device.capture.channels)
	e.rec.rate = e.rec.device.sampleRate
	if e.rec.channels <= 0 || e.rec.rate == 0 {
		recorder_release(e, false, false)
		ui.status_buf_set(a, "capture device reported no channels")
		return false
	}
	engine_rescale_punch(e, a, e.rec.rate)
	e.sample_rate = e.rec.rate
	a.sample_rate = e.rec.rate

	monitor_init(&e.rec.monitor)
	monitor_snapshot_sources(&e.rec.monitor, e.rec.armed[:], e.rec.inputs[:], e.rec.channels)
	e.rec.monitoring = monitoring
	monitor_set_enabled(&e.rec.monitor, monitoring)

	raw, ferr := os.open(e.take_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if ferr != nil {
		recorder_release(e, false, false)
		ui.status_buf_set(a, "cannot open take file")
		return false
	}
	e.rec.raw = raw
	e.rec.stop = 0
	e.rec.write_frame = 0
	e.rec.read_frame = 0
	e.rec.overflow = 0
	e.rec.error = false
	e.rec.cap_frames = max(int(e.rec.rate) * 2, 4_096)
	e.rec.ring = make([]f32, e.rec.cap_frames * e.rec.channels)
	for i in 0 ..< len(e.rec.peak) {
		sync.atomic_store(&e.rec.peak[i], 0)
	}

	overdub := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if e.loaded[i] != nil {
			overdub = true
		}
	}
	start_pos := i64(e.rec_punch - e.rec_pre)
	countin_only := e.rec_pre > 0 && !a.metronome && start_pos < 0
	want_playback := overdub || a.metronome || countin_only

	// Prepare the guide mix before the capture device starts. Rendering is the
	// slow part of an overdub and must not become recorded pre-roll that
	// shifts the new performance out of alignment with the existing tracks.
	if want_playback {
		if !playback_prepare(e, a, true, start_pos, true, 0, countin_only, true) {
			recorder_release(e, true, true)
			_ = os.remove(e.take_path)
			ui.status_buf_set(a, "cannot start playback")
			return false
		}
	}

	e.rec.active = true
	sync.atomic_store(&e.rec.stop_expected, 0)
	sync.atomic_store(&e.rec.interrupt, 0)
	if !recorder_start_writer(e) {
		e.rec.active = false
		if want_playback {
			engine_stop_playback(e)
		}
		recorder_release(e, true, true)
		_ = os.remove(e.take_path)
		ui.status_buf_set(a, "cannot start take writer")
		return false
	}

	if ma.device_start(&e.rec.device) != .SUCCESS {
		e.rec.active = false
		sync.atomic_store(&e.rec.stop, 1)
		recorder_join_writer(e)
		if want_playback {
			engine_stop_playback(e)
		}
		recorder_release(e, true, true)
		_ = os.remove(e.take_path)
		ui.status_buf_set(a, "cannot start capture")
		return false
	}

	// Capture is live now; start the guide immediately after it so the gap
	// between the two device clocks is one start call, not a whole render.
	if want_playback && !playback_start(e) {
		e.rec.active = false
		sync.atomic_store(&e.rec.stop, 1)
		recorder_join_writer(e)
		recorder_release(e, true, true)
		_ = os.remove(e.take_path)
		ui.status_buf_set(a, "cannot start playback")
		return false
	}

	ui.status_buf_set(a, fmt.tprintf("recording %d ch · %s @ %d Hz%s%s%s", e.rec.channels, names[idx], e.rec.rate, " · overdub" if overdub else "", " · click" if a.metronome else "", " · monitor" if monitoring else ""))
	if e.monitor_enabled && !monitoring {
		ui.toast(a, "monitor unavailable · recording input only")
	}
	return true
}

engine_record_stop :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if jack_session_is_running(&e.jack) {
		engine_stop_playback(e)
		result, ok := jack_session_stop(&e.jack)
		defer capture_destroy(&result)
		if !ok {
			if a != nil {
				ui.status_buf_set(a, "JACK take failed")
				ui.app_force_stopped(a, ui.app_status(a))
			}
			return false
		}
		e.sample_rate = result.rate
		ok_split := engine_split_capture_result(e, a, &result, e.rec.armed, e.rec.inputs)
		if a != nil {
			if ok_split {
				ui.status_buf_set(a, fmt.tprintf("JACK take captured · %d frames", result.frames))
			} else {
				ui.status_buf_set(a, "JACK take empty")
			}
			ui.app_force_stopped(a, ui.app_status(a))
		}
		return ok_split
	}
	if !e.rec.active {
		// Recovery path: a failed start should never leave hardware or a
		// writer behind, but don't leak them if it does.
		if e.rec.device_open || e.rec.ctx_open || e.rec.raw != nil || e.rec.writer != nil {
			sync.atomic_store(&e.rec.stop, 1)
			recorder_join_writer(e)
			recorder_release(e, true, true)
		}
		return false
	}

	interrupted := sync.atomic_load(&e.rec.interrupt) != 0
	sync.atomic_store(&e.rec.interrupt, 0)

	// Stop the guide first so no playback outlives the take, then stop the
	// capture callback before telling the writer to drain and exit.
	engine_stop_playback(e)
	sync.atomic_store(&e.rec.stop_expected, 1)
	_ = ma.device_stop(&e.rec.device)
	sync.atomic_store(&e.rec.stop, 1)
	recorder_join_writer(e)

	overflow := sync.atomic_load(&e.rec.overflow)
	write_error := e.rec.error
	recorder_release(e, true, true)

	ok := engine_split_take(e, a)
	if a != nil {
		switch {
		case !ok && interrupted:
			ui.status_buf_set(a, "input device lost · take empty")
		case !ok:
			ui.status_buf_set(a, "take failed")
		case interrupted:
			ui.status_buf_set(a, "input device lost · take saved")
		case write_error:
			ui.status_buf_set(a, "take captured · disk write error, tail may be missing")
		case overflow > 0:
			ui.status_buf_set(a, fmt.tprintf("take captured · %d frames dropped (disk too slow)", overflow))
		case:
			ui.status_buf_set(a, "take captured")
		}
		ui.app_force_stopped(a, ui.app_status(a))
	}
	return ok
}

// Splits a JACK (or other pre-collected) interleaved capture into per-track
// WAVs, honouring the arm/input snapshot and the latency trim.
@(private)
engine_split_capture_result :: proc(e: ^Engine, a: ^ui.App, result: ^Capture_Result, armed: [MAX_ENGINE_TRACKS]bool, inputs: [MAX_ENGINE_TRACKS]int) -> bool {
	if result.channels <= 0 || result.frames <= 0 {
		return false
	}
	trim := engine_latency_frames(e.latency_ms, result.rate) + e.rec_pre
	start := min(trim, result.frames)
	frames := result.frames - start
	if frames <= 0 {
		return false
	}
	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if !armed[i] {
			continue
		}
		ch := (inputs[i] - 1) % result.channels
		if ch < 0 {
			ch += result.channels
		}
		mono := make([]f32, frames)
		for f in 0 ..< frames {
			mono[f] = result.samples[(f + start) * result.channels + ch]
		}
		if !engine_commit_recorded_take(e, a, i, result.rate, mono) {
			continue
		}
		any = true
	}
	return any
}

@(private)
engine_split_take :: proc(e: ^Engine, a: ^ui.App) -> bool {
	data, err := os.read_entire_file(e.take_path, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)
	channels := e.rec.channels
	if channels <= 0 || e.rec.rate == 0 {
		return false
	}
	frame_bytes := 4 * channels
	if len(data) < frame_bytes {
		return false
	}
	// A partial trailing frame (short raw write) is dropped rather than
	// indexing past the end of the data.
	frames := len(data) / frame_bytes
	if frames == 0 {
		return false
	}

	// Latency compensation: the first N frames of a take are the round-trip
	// delay between pressing REC and the performance reaching the converter.
	// Drop them when splitting so the new take lines up with the existing mix.
	drop := engine_latency_frames(e.latency_ms, e.rec.rate) + e.rec_pre
	if drop >= frames {
		_ = os.remove(e.take_path)
		return false
	}
	out_frames := frames - drop

	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if !e.rec.armed[i] {
			continue
		}
		mono := make([]f32, out_frames)
		ch := recorder_input_channel(e.rec.inputs[i], channels)
		if ch >= 0 && ch < channels {
			for f in 0 ..< out_frames {
				src_frame := f + drop
				v, _ := endian.get_f32(data[(src_frame * channels + ch) * 4:], .Little)
				mono[f] = v
			}
		}
		if !engine_commit_recorded_take(e, a, i, e.rec.rate, mono) {
			continue
		}
		any = true
	}
	_ = os.remove(e.take_path)
	return any
}

// ---------------------------------------------------------------- playback

@(private)
playback_click_step :: proc "contextless" (p: ^Playback, pos: i64) -> f32 {
	seek_gen := sync.atomic_load(&p.seek_gen)
	if seek_gen != p.last_seek_gen {
		p.last_seek_gen = seek_gen
		p.has_last_beat = false
	}

	want := p.click_enabled || (p.countin_click_active && pos < p.countin_click_until)
	rate := max(p.rate, 1)
	bpm := max(p.bpm, 1)
	sig_num := max(p.sig_num, 1)
	sig_den := max(p.sig_den, 1)
	beat_f := max((60.0 / f64(bpm)) * (4.0 / f64(sig_den)) * f64(rate), 1.0)

	rel_pos := pos if p.click_absolute else (pos - p.click_origin)
	beat_idx := i64(math.floor(f64(rel_pos) / beat_f))

	triggered := false
	trig_idx: i64 = 0
	if !p.has_last_beat {
		p.has_last_beat = true
		p.last_beat_idx = beat_idx
		nearest := math.round(f64(rel_pos) / beat_f)
		if want && abs(f64(rel_pos) - nearest * beat_f) <= 1.0 {
			triggered = true
			trig_idx = i64(nearest)
		}
	} else if beat_idx != p.last_beat_idx {
		prev_idx := p.last_beat_idx
		p.last_beat_idx = beat_idx
		if want && beat_idx > prev_idx {
			triggered = true
			trig_idx = beat_idx
		}
	}

	if triggered {
		sn := i64(sig_num)
		beat_in_bar := int(((trig_idx % sn) + sn) % sn)
		switch {
		case beat_in_bar == 0:
			p.click_freq = 1500.0
			p.click_amp = 0.28
			p.click_len = max(int(f32(rate) * 0.014), 1)
		case sig_num == 6 && sig_den == 8 && beat_in_bar == 3:
			p.click_freq = 1150.0
			p.click_amp = 0.22
			p.click_len = max(int(f32(rate) * 0.012), 1)
		case:
			p.click_freq = 950.0
			p.click_amp = 0.18
			p.click_len = max(int(f32(rate) * 0.011), 1)
		}
		p.click_left = p.click_len
		p.click_phase = 0
	}

	if p.click_left > 0 {
		env := f32(p.click_left) / f32(max(p.click_len, 1))
		v := math.sin(p.click_phase) * p.click_amp * env * env
		p.click_phase += f32(math.TAU) * p.click_freq / f32(rate)
		p.click_left -= 1
		return v
	}
	return 0
}

@(private)
playback_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	if device == nil {
		return
	}
	p := cast(^Playback)device.pUserData
	if p == nil || output == nil || frame_count == 0 {
		return
	}
	// miniaudio was configured for stereo, but honour however many channels
	// the device actually opened rather than writing past its output buffer.
	channels := int(device.playback.channels)
	if channels <= 0 {
		return
	}
	sync.atomic_store(&p.cb_active, 1)
	out := cast([^]f32)output
	frames := int(frame_count)
	is_playing := sync.atomic_load(&p.playing) != 0 || !p.device_open

	if !is_playing {
		if p.was_playing {
			p.was_playing = false
			fade_len := p.fade_out_len
			if fade_len <= 0 {
				fade_len = max(int(p.rate / 750), 16)
			}
			p.fade_out_len = fade_len
			p.fade_out_left = fade_len
		}
		for f in 0 ..< frames {
			l: f32 = 0
			r: f32 = 0
			if p.fade_out_left > 0 {
				gain := f32(p.fade_out_left - 1) / f32(max(p.fade_out_len, 1))
				l = p.last_l * gain
				r = p.last_r * gain
				p.fade_out_left -= 1
			}
			for c in 0 ..< channels {
				out[f * channels + c] = (l + r) * 0.5 if channels == 1 else (l if c % 2 == 0 else r)
			}
		}
		p.last_l = 0
		p.last_r = 0
		sync.atomic_store(&p.cb_active, 0)
		return
	}

	if p.use_live_mixer {
		seek_gen := sync.atomic_load(&p.seek_gen)
		if seek_gen != p.mixer_seek_gen {
			p.mixer_seek_gen = seek_gen
			dsp.live_mixer_reset(&p.mixer)
			p.fade_in_left = p.fade_in_len
		}
		if next_params := playback_params_consume(p); next_params != nil {
			dsp.live_mixer_apply_params(&p.mixer, next_params, false)
		}
	}

	has_audio: [MAX_ENGINE_TRACKS]bool
	track_peaks: [MAX_ENGINE_TRACKS]f32
	samples_in: [MAX_ENGINE_TRACKS]f32
	track_count := clamp(p.track_count, 0, MAX_ENGINE_TRACKS)
	for i in 0 ..< track_count {
		has_audio[i] = len(p.tracks[i]) > 0
	}

	cursor := sync.atomic_load(&p.cursor)
	master_peak: f32 = 0
	for f in 0 ..< frames {
		pos := cursor + i64(f)
		l: f32 = 0
		r: f32 = 0
		if !p.silent && pos >= 0 && pos < i64(p.frames) {
			idx := int(pos)
			if p.use_live_mixer {
				for i in 0 ..< track_count {
					if idx < len(p.tracks[i]) {
						samples_in[i] = p.tracks[i][idx]
					} else {
						samples_in[i] = 0
					}
				}
				l, r = dsp.live_mixer_step(&p.mixer, &samples_in, &has_audio, &track_peaks)
			} else if idx >= 0 && idx * 2 + 1 < len(p.samples) {
				l = p.samples[idx * 2 + 0]
				r = p.samples[idx * 2 + 1]
			}
		}
		if p.fade_in_left > 0 {
			denom := max(p.fade_in_len, 1)
			gain := f32(denom - p.fade_in_left + 1) / f32(denom)
			l *= gain
			r *= gain
			p.fade_in_left -= 1
		}
		v := playback_click_step(p, pos)
		l += v
		r += v
		master_peak = max(master_peak, abs(l), abs(r))
		p.last_l = l
		p.last_r = r
		p.was_playing = true
		for c in 0 ..< channels {
			out[f * channels + c] = (l + r) * 0.5 if channels == 1 else (l if c % 2 == 0 else r)
		}
	}
	// Saturate at `p.frames` for finite preview playback so a late callback
	// after the end does not wrap; during unbounded playback (recording
	// overdub/click or standalone metronome) keep advancing so the clicktrack
	// stays locked to the grid past the length of existing takes.
	next := cursor
	if p.unbounded {
		next = cursor + i64(frames)
	} else {
		end := i64(p.frames)
		if next < end {
			remaining := end - next
			next = end if i64(frames) >= remaining else next + i64(frames)
		}
	}
	sync.atomic_store(&p.cursor, next)

	if p.use_live_mixer {
		for i in 0 ..< track_count {
			sync.atomic_store(&p.track_peak[i], track_peaks[i])
			sync.atomic_store(&p.track_gr[i], dsp.comp_instantaneous_reduction_db(&p.mixer.comps[i]))
		}
		sync.atomic_store(&p.master_peak, master_peak)
		mg := dsp.comp_instantaneous_reduction_db(&p.mixer.master_comp)
		lg := dsp.limiter_instantaneous_reduction_db(&p.mixer.limiter)
		sync.atomic_store(&p.master_gr, min(mg, lg))
	}
	sync.atomic_store(&p.cb_active, 0)
}

engine_load_tracks :: proc(e: ^Engine, a: ^ui.App) -> bool {
	was_playing := engine_tracks_begin_edit(e)
	// The project's rate is authoritative when loading takes. Callers used to
	// forget this on startup/palette load, leaving a 44.1 kHz project mixing at
	// the engine default 48 kHz.
	if a != nil && a.sample_rate != 0 {
		e.sample_rate = clamp(a.sample_rate, 8_000, 384_000)
	}
	engine_takes_ensure(e)
	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if handled, ok := engine_load_track_from_takes(e, a, i); handled {
			any = any || ok
			if !ok {
				delete(e.loaded[i])
				e.loaded[i] = nil
				e.loaded_rate[i] = 0
				if a != nil {
					a.tracks[i].has_audio = false
				}
			}
			continue
		}
		path := fmt.tprintf("%s/track%d.wav", e.session_dir, i + 1)
		if !os.exists(path) {
			delete(e.loaded[i])
			e.loaded[i] = nil
			a.tracks[i].has_audio = false
			continue
		}
		wav, ok := wav_read(path)
		if !ok || wav.frames == 0 {
			// A corrupt or empty track must not leave the previously loaded
			// take marked as this slot's audio.
			wav_destroy(&wav)
			delete(e.loaded[i])
			e.loaded[i] = nil
			e.loaded_rate[i] = 0
			a.tracks[i].has_audio = false
			continue
		}
		mono := make([]f32, wav.frames)
		channels := int(wav.channels)
		for f in 0 ..< wav.frames {
			sum: f32 = 0
			for c in 0 ..< channels {
				sum += wav.samples[f * channels + c]
			}
			mono[f] = sum / f32(max(channels, 1))
		}
		delete(e.loaded[i])
		e.loaded[i] = mono
		e.loaded_rate[i] = wav.sample_rate
		a.tracks[i].has_audio = true
		wav_destroy(&wav)
		any = true
	}
	engine_tracks_end_edit(e, was_playing)
	engine_sync_tape_length(e, a)
	return any
}

// Longest loaded track length at the project sample rate.
engine_tape_frames :: proc(e: ^Engine) -> i64 {
	if e == nil {
		return 0
	}
	max_frames: i64 = 0
	dst_rate := max(e.sample_rate, 1)
	for i in 0 ..< MAX_ENGINE_TRACKS {
		src := e.loaded[i]
		if src == nil || len(src) == 0 {
			continue
		}
		src_rate := e.loaded_rate[i]
		if src_rate == 0 || src_rate == dst_rate {
			max_frames = max(max_frames, i64(len(src)))
		} else {
			scaled := i64(math.round(f64(len(src)) * f64(dst_rate) / f64(src_rate)))
			max_frames = max(max_frames, scaled)
		}
	}
	return max_frames
}

engine_sync_tape_length :: proc(e: ^Engine, a: ^ui.App) {
	if e == nil || a == nil {
		return
	}
	ui.app_set_tape_frames(a, engine_tape_frames(e))
}

// Repositions the active playback head (or peeks audio meters under the head
// when stopped) after a jog/shuttle scrub or return-to-zero.
engine_seek :: proc(e: ^Engine, a: ^ui.App) {
	if e == nil || a == nil || e.rec.active || jack_session_is_running(&e.jack) {
		return
	}
	if e.play.active {
		if !e.play.unbounded && e.play.frames <= 0 {
			return
		}
		target := max(a.frames, 0) if e.play.unbounded else clamp(a.frames, 0, i64(e.play.frames) - 1)
		a.frames = target
		sync.atomic_store(&e.play.cursor, target)
		if !e.play.click_absolute {
			e.play.click_origin = target
		}
		sync.atomic_add(&e.play.seek_gen, 1)
		return
	}
	rate := max(e.sample_rate, 1)
	peak_master: f32 = -60
	for i in 0 ..< MAX_ENGINE_TRACKS {
		src := e.loaded[i]
		if src == nil || len(src) == 0 {
			a.tracks[i].peak_db = -60
			a.tracks[i].rms_db = -60
			continue
		}
		src_rate := e.loaded_rate[i] if e.loaded_rate[i] > 0 else rate
		idx := int(f64(a.frames) * f64(src_rate) / f64(rate))
		if idx < 0 || idx >= len(src) {
			a.tracks[i].peak_db = -60
			a.tracks[i].rms_db = -60
			continue
		}
		peak: f32 = 0
		for f in idx ..< min(idx + 512, len(src)) {
			peak = max(peak, abs(src[f]))
		}
		a.tracks[i].peak_db = dsp.lin_to_db(peak * a.tracks[i].level)
		a.tracks[i].rms_db = a.tracks[i].peak_db - 6
		peak_master = max(peak_master, a.tracks[i].peak_db)
	}
	a.master.peak_db = peak_master
	a.master.rms_db = peak_master - 6
}

@(private)
engine_free_play_tracks :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if e.play_tracks_owned[i] {
			delete(e.play_tracks[i])
		}
		e.play_tracks[i] = nil
		e.play_tracks_owned[i] = false
	}
	e.play_tracks_rate = 0
	e.play_tracks_dirty = true
}

@(private)
engine_sync_play_tracks :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	rate := e.sample_rate if e.sample_rate != 0 else 48_000
	if !e.play_tracks_dirty && e.play_tracks_rate == rate {
		return
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if e.play_tracks_owned[i] {
			delete(e.play_tracks[i])
			e.play_tracks_owned[i] = false
		}
		e.play_tracks[i] = nil
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		src := e.loaded[i]
		if src == nil || len(src) == 0 {
			continue
		}
		src_rate := e.loaded_rate[i]
		if src_rate == 0 || src_rate == rate {
			e.play_tracks[i] = src
		} else {
			e.play_tracks[i] = dsp.resample(src, src_rate, rate)
			e.play_tracks_owned[i] = true
		}
	}
	e.play_tracks_rate = rate
	e.play_tracks_dirty = false
}

@(private)
engine_tracks_begin_edit :: proc(e: ^Engine) -> (was_playing: bool) {
	if e == nil {
		return false
	}
	was_playing = e.play.active && sync.atomic_load(&e.play.playing) != 0
	playback_quiesce(e)
	e.play_tracks_dirty = true
	return was_playing
}

@(private)
engine_tracks_end_edit :: proc(e: ^Engine, was_playing: bool) {
	if e == nil {
		return
	}
	engine_sync_play_tracks(e)
	if e.play.active && e.play.use_live_mixer {
		max_len := 0
		have_audio := false
		for i in 0 ..< MAX_ENGINE_TRACKS {
			e.play.tracks[i] = e.play_tracks[i]
			if len(e.play_tracks[i]) > 0 {
				have_audio = true
				max_len = max(max_len, len(e.play_tracks[i]))
			}
		}
		rate := max(e.play.rate, 1)
		tail_frames := int(dsp.live_mix_tail_seconds(&e.play.last_published_params) * f32(rate))
		e.play.frames = max_len + tail_frames if have_audio else int(rate) * 3_600
		e.play.silent = !have_audio
		if was_playing {
			sync.atomic_store(&e.play.playing, 1)
		}
	}
}

@(private)
engine_track_audio :: proc(e: ^Engine) -> (tracks: [][]f32, owned: [MAX_ENGINE_TRACKS]bool) {
	engine_sync_play_tracks(e)
	tracks = make([][]f32, MAX_ENGINE_TRACKS)
	for i in 0 ..< MAX_ENGINE_TRACKS {
		tracks[i] = e.play_tracks[i]
	}
	return
}

@(private)
engine_free_track_audio :: proc(tracks: [][]f32, owned: [MAX_ENGINE_TRACKS]bool) {
	for i in 0 ..< len(tracks) {
		if owned[i] {
			delete(tracks[i])
		}
	}
	delete(tracks)
}

engine_render_mix :: proc(e: ^Engine, a: ^ui.App, mute_armed: bool = false, skip_track: int = -1) -> (dsp.Render_Output, bool) {
	tracks, owned := engine_track_audio(e)
	defer engine_free_track_audio(tracks, owned)
	settings := settings_from_app(a)
	defer delete(settings.tracks)
	if mute_armed {
		for i in 0 ..< min(len(settings.tracks), MAX_ENGINE_TRACKS) {
			if a.tracks[i].armed {
				settings.tracks[i].muted = true
			}
		}
	}
	if skip_track >= 0 && skip_track < len(settings.tracks) {
		settings.tracks[skip_track].muted = true
	}
	out := dsp.render_mix(tracks, settings, f32(e.sample_rate))
	if out.frames <= 0 {
		dsp.render_destroy(&out)
		return {}, false
	}
	return out, true
}

@(private)
live_mix_params_from_app :: proc(a: ^ui.App, mute_armed: bool) -> dsp.Live_Mix_Params {
	p: dsp.Live_Mix_Params
	def := dsp.fx_settings_default()
	p.master_comp = def.master_comp
	p.reverb = def.reverb
	p.delay = def.delay
	p.width = def.width
	p.limiter = def.limiter
	if a == nil {
		p.track_count = ui.MIN_TRACKS
		for i in 0 ..< p.track_count {
			p.tracks[i] = dsp.track_mix_default()
		}
		return p
	}
	count := clamp(a.track_count, ui.MIN_TRACKS, MAX_ENGINE_TRACKS)
	p.track_count = count
	any_solo := false
	for i in 0 ..< count {
		if a.tracks[i].soloed {
			any_solo = true
			break
		}
	}
	for i in 0 ..< count {
		t := a.tracks[i]
		muted := t.muted || (any_solo && !t.soloed) || (mute_armed && t.armed)
		p.tracks[i] = dsp.Track_Mix {
			level = t.level,
			pan = t.pan,
			muted = muted,
			send_reverb = t.send_reverb,
			send_delay = t.send_delay,
			eq = eq_params_from_view(t.eq),
			comp = comp_params_from_view(t.comp),
		}
	}
	p.master_comp = comp_params_from_view(a.master.comp)
	p.reverb = dsp.Reverb_Params {
		enabled = a.master.reverb.enabled,
		size = a.master.reverb.size,
		decay = a.master.reverb.decay,
		tone = a.master.reverb.tone,
		predelay_ms = a.master.reverb.predelay_ms,
		return_level = a.master.reverb.return_level,
	}
	p.delay = dsp.Delay_Params {
		enabled = a.master.delay.enabled,
		time_ms = a.master.delay.time_ms,
		feedback = a.master.delay.feedback,
		tone = a.master.delay.tone,
		ping_pong = a.master.delay.ping_pong,
		return_level = a.master.delay.return_level,
	}
	p.width = dsp.Width_Params {
		enabled = a.master.width.enabled,
		width = a.master.width.width,
		bass_hz = a.master.width.bass_hz,
	}
	p.limiter = dsp.Limiter_Params {
		enabled = a.master.limiter.enabled,
		ceiling_db = a.master.limiter.ceiling_db,
		release_ms = a.master.limiter.release_ms,
		lookahead_ms = a.master.limiter.lookahead_ms,
	}
	return p
}

@(private)
playback_params_reset :: proc(p: ^Playback, initial: dsp.Live_Mix_Params) {
	p.param_slots[0] = initial
	p.param_slots[1] = initial
	p.param_slots[2] = initial
	p.param_ui_slot = 0
	p.param_audio_slot = 2
	sync.atomic_store(&p.param_shared, u32(1))
	p.last_published_params = initial
	p.has_published_params = true
}

@(private)
playback_params_publish :: proc(p: ^Playback, params: dsp.Live_Mix_Params) {
	slot := p.param_ui_slot
	p.param_slots[slot] = params
	prev := sync.atomic_exchange(&p.param_shared, u32(slot) | 0x4)
	p.param_ui_slot = int(prev & 0x3)
	p.last_published_params = params
	p.has_published_params = true
}

@(private)
playback_params_consume :: proc "contextless" (p: ^Playback) -> ^dsp.Live_Mix_Params {
	if (sync.atomic_load(&p.param_shared) & 0x4) == 0 {
		return nil
	}
	prev := sync.atomic_exchange(&p.param_shared, u32(p.param_audio_slot))
	p.param_audio_slot = int(prev & 0x3)
	return &p.param_slots[p.param_audio_slot]
}

@(private)
playback_quiesce :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	sync.atomic_store(&e.play.playing, 0)
	if !e.play.device_open {
		return
	}
	for _ in 0 ..< 256 {
		if sync.atomic_load(&e.play.cb_active) == 0 {
			return
		}
		sync.cpu_relax()
	}
	for _ in 0 ..< 1_000 {
		if sync.atomic_load(&e.play.cb_active) == 0 {
			return
		}
		time.sleep(100 * time.Microsecond)
	}
}

@(private)
playback_ensure_mixer :: proc(e: ^Engine, rate: u32) {
	r := max(rate, 8_000)
	if e.play.mixer.initialized && e.play.mixer_rate == r {
		return
	}
	dsp.live_mixer_destroy(&e.play.mixer)
	dsp.live_mixer_init(&e.play.mixer, f32(r))
	e.play.mixer_rate = r
}

playback_release_device :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	playback_quiesce(e)
	p := &e.play
	if p.device_open {
		sync.atomic_store(&p.stop_expected, 1)
		_ = ma.device_stop(&p.device)
		ma.device_uninit(&p.device)
		p.device_open = false
	}
	if p.ctx_open {
		ma.context_uninit(&p.ctx)
		p.ctx_open = false
		p.ctx = {}
	}
	p.device_rate = 0
	p.interrupt = 0
	p.stop_expected = 0
	p.was_playing = false
	p.fade_out_left = 0
}

@(private)
playback_ensure_device :: proc(e: ^Engine, rate: u32) -> bool {
	p := &e.play
	r := rate if rate != 0 else 48_000
	if p.device_open {
		if sync.atomic_load(&p.interrupt) == 0 && p.device_rate == r {
			return true
		}
		playback_release_device(e)
	}
	p.ctx = {}
	if ma.context_init(nil, 0, nil, &p.ctx) != .SUCCESS {
		return false
	}
	p.ctx_open = true

	cfg := ma.device_config_init(.playback)
	cfg.sampleRate = r
	cfg.playback.format = .f32
	cfg.playback.channels = 2
	cfg.performanceProfile = .low_latency
	cfg.noPreSilencedOutputBuffer = true
	cfg.noFixedSizedCallback = true
	platform_audio_configure_playback(&cfg)
	cfg.dataCallback = playback_callback
	cfg.notificationCallback = playback_notification
	cfg.pUserData = p

	sync.atomic_store(&p.playing, 0)
	sync.atomic_store(&p.stop_expected, 0)
	sync.atomic_store(&p.interrupt, 0)
	if ma.device_init(&p.ctx, &cfg, &p.device) != .SUCCESS {
		ma.context_uninit(&p.ctx)
		p.ctx_open = false
		p.ctx = {}
		return false
	}
	p.device_open = true
	p.device_rate = r
	if ma.device_start(&p.device) != .SUCCESS {
		playback_release_device(e)
		return false
	}
	return true
}

engine_playback_warm :: proc(e: ^Engine) {
	if e == nil {
		return
	}
	rate := e.sample_rate if e.sample_rate != 0 else 48_000
	engine_sync_play_tracks(e)
	playback_ensure_mixer(e, rate)
	_ = playback_ensure_device(e, rate)
}

// Prepares the live mixer, track pointers and warm output device without
// starting transport. Splitting preparation from `playback_start` lets record
// start open capture first, then flip `playing = 1` back-to-back.
@(private)
playback_prepare :: proc(
	e: ^Engine,
	a: ^ui.App,
	mute_armed: bool,
	start_frame: i64 = 0,
	has_start: bool = false,
	countin_click_until: i64 = 0,
	countin_click_active: bool = false,
	unbounded: bool = false,
) -> bool {
	engine_stop_playback(e)
	engine_sync_play_tracks(e)

	max_len := 0
	have_audio := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if len(e.play_tracks[i]) > 0 {
			have_audio = true
			max_len = max(max_len, len(e.play_tracks[i]))
		}
	}
	if !have_audio && !a.metronome && !countin_click_active {
		return false
	}

	rate := e.sample_rate if e.sample_rate != 0 else 48_000
	params := live_mix_params_from_app(a, mute_armed)
	tail_frames := int(dsp.live_mix_tail_seconds(&params) * f32(rate))
	total_frames := max_len + tail_frames if have_audio else max(int(rate), 1) * 3_600

	p := &e.play
	playback_ensure_mixer(e, rate)
	dsp.live_mixer_apply_params(&p.mixer, &params, true)
	dsp.live_mixer_reset(&p.mixer)
	playback_params_reset(p, params)

	p.tracks = e.play_tracks
	p.track_count = params.track_count
	p.use_live_mixer = true
	p.mute_armed = mute_armed
	p.frames = total_frames
	p.silent = !have_audio
	p.unbounded = unbounded || !have_audio
	p.rate = rate
	sig := ui.app_time_sig(a)
	p.click_enabled = a.metronome
	p.click_absolute = a.timing_mode == .Grid
	p.countin_click_active = countin_click_active
	p.countin_click_until = countin_click_until
	p.bpm = a.bpm
	p.sig_num = int(sig.num)
	p.sig_den = int(sig.den)
	p.seek_gen = 0
	p.last_seek_gen = 0
	p.mixer_seek_gen = 0
	p.has_last_beat = false
	p.last_beat_idx = 0
	p.fade_in_len = max(int(rate / 750), 16)
	p.fade_in_left = p.fade_in_len
	for i in 0 ..< MAX_ENGINE_TRACKS {
		sync.atomic_store(&p.track_peak[i], 0)
		sync.atomic_store(&p.track_gr[i], 0)
	}
	sync.atomic_store(&p.master_peak, 0)
	sync.atomic_store(&p.master_gr, 0)

	cursor: i64 = 0
	if has_start {
		// recording from the playhead: the guide starts at the pre-roll point (can be < 0)
		cursor = start_frame
	} else if !mute_armed && a.tape_cued && a.frames > 0 && a.frames < i64(p.frames) {
		cursor = a.frames
	}
	sync.atomic_store(&p.cursor, cursor)
	p.click_origin = cursor
	p.click_left = 0
	p.click_len = 0
	p.click_phase = 0
	p.click_freq = 950.0
	p.click_amp = 0.18

	if !playback_ensure_device(e, rate) {
		p.frames = 0
		p.use_live_mixer = false
		return false
	}
	p.active = true
	return true
}

@(private)
playback_start :: proc(e: ^Engine) -> bool {
	if !e.play.active || !e.play.device_open {
		return false
	}
	sync.atomic_store(&e.play.stop_expected, 0)
	sync.atomic_store(&e.play.interrupt, 0)
	sync.atomic_store(&e.play.playing, 1)
	return true
}

engine_play :: proc(
	e: ^Engine,
	a: ^ui.App,
	mute_armed: bool = false,
	start_frame: i64 = 0,
	has_start: bool = false,
	countin_click_until: i64 = 0,
	countin_click_active: bool = false,
	unbounded: bool = false,
) -> bool {
	if !playback_prepare(e, a, mute_armed, start_frame, has_start, countin_click_until, countin_click_active, unbounded) {
		return false
	}
	return playback_start(e)
}

engine_stop_playback :: proc(e: ^Engine) {
	if e == nil || !e.play.active {
		return
	}
	playback_quiesce(e)
	if e.play.samples != nil {
		delete(e.play.samples)
		e.play.samples = nil
	}
	e.play.active = false
	e.play.cursor = 0
	e.play.frames = 0
	e.play.unbounded = false
	e.play.use_live_mixer = false
	if sync.atomic_load(&e.play.interrupt) != 0 {
		playback_release_device(e)
	}
}

// Full rendered length: the longest loaded take at the project rate plus the
// reverb/delay tail. The render dialog uses it to clamp FROM/TO.
engine_mix_duration :: proc(e: ^Engine, a: ^ui.App) -> f32 {
	max_seconds: f32 = 0
	for i in 0 ..< MAX_ENGINE_TRACKS {
		src := e.loaded[i]
		if src == nil {
			continue
		}
		rate := e.loaded_rate[i]
		if rate == 0 {
			rate = e.sample_rate
		}
		if rate == 0 {
			continue
		}
		max_seconds = max(max_seconds, f32(len(src)) / f32(rate))
	}
	if max_seconds <= 0 {
		return 0
	}
	settings := settings_from_app(a)
	defer delete(settings.tracks)
	return max_seconds + dsp.render_tail_seconds(settings)
}

// Maps a dialog range in seconds to frame bounds in an already rendered mix.
// `end_s <= 0` means "to the end" so an unknown duration at open still renders
// the whole file. Out-of-range values clamp instead of failing.
render_slice_bounds :: proc(
	total_frames: int,
	sample_rate: u32,
	start_s, end_s: f32,
) -> (first, last: int, ok: bool) {
	if total_frames <= 0 || sample_rate == 0 {
		return 0, 0, false
	}
	total_s := f32(total_frames) / f32(sample_rate)
	s0 := clamp(start_s, 0, total_s)
	s1 := total_s if end_s <= 0 else clamp(end_s, 0, total_s)
	first = clamp(int(math.round(f64(s0) * f64(sample_rate))), 0, total_frames)
	last = clamp(int(math.round(f64(s1) * f64(sample_rate))), 0, total_frames)
	if last <= first {
		return 0, 0, false
	}
	return first, last, true
}

// Non-destructive offline render to an arbitrary external file. Never touches
// the take files or the canonical bounce.wav. The range is applied after the
// full mix is rendered, so filters and reverb state stay continuous.
engine_render_to_file :: proc(
	e: ^Engine,
	a: ^ui.App,
	path: string,
	start_s, end_s: f32,
	format: Wav_Export_Format,
) -> (ok: bool, err: string) {
	if path == "" {
		return false, "no render path"
	}
	out, have_audio := engine_render_mix(e, a)
	if !have_audio {
		return false, "record something first"
	}
	defer dsp.render_destroy(&out)
	first, last, range_ok := render_slice_bounds(out.frames, e.sample_rate, start_s, end_s)
	if !range_ok {
		return false, "render range is empty"
	}
	slice := out.samples[first * 2:last * 2]
	if !wav_write_export(path, e.sample_rate, 2, slice, format) {
		return false, "cannot write the mix file"
	}
	return true, ""
}

// ---------------------------------------------------------------- polling

engine_update :: proc(e: ^Engine, a: ^ui.App) {
	// Device loss is handled on the UI thread: stop the device, drain the
	// writer, split whatever reached disk and report a clear status. This is
	// the only safe place to tear down a miniaudio device.
	if e.rec.active && sync.atomic_load(&e.rec.interrupt) != 0 {
		_ = engine_record_stop(e, a)
		return
	}
	if e.play.active && sync.atomic_load(&e.play.interrupt) != 0 {
		engine_stop_playback(e)
		playback_release_device(e)
		if a != nil {
			ui.app_force_stopped(a, "output device lost · playback stopped")
		}
		return
	}
	if !e.play.active && e.play.device_open && sync.atomic_load(&e.play.interrupt) != 0 {
		playback_release_device(e)
	}
	engine_preview_sync(e, a)
	if e.rec.active {
		if e.play.active && a != nil {
			sig := ui.app_time_sig(a)
			e.play.click_enabled = a.metronome
			e.play.click_absolute = a.timing_mode == .Grid
			e.play.bpm = a.bpm
			e.play.sig_num = int(sig.num)
			e.play.sig_den = int(sig.den)
			if e.play.use_live_mixer {
				params := live_mix_params_from_app(a, e.play.mute_armed)
				if !e.play.has_published_params || params != e.play.last_published_params {
					playback_params_publish(&e.play, params)
				}
			}
		}
		a.frames = i64(e.rec_punch - e.rec_pre) + i64(sync.atomic_load(&e.rec.write_frame))
		for i in 0 ..< MAX_ENGINE_TRACKS {
			if !e.rec.armed[i] {
				continue
			}
			ch := recorder_input_channel(e.rec.inputs[i], e.rec.channels)
			if ch >= 0 && ch < len(e.rec.peak) {
				a.tracks[i].peak_db = dsp.lin_to_db(sync.atomic_load(&e.rec.peak[ch]))
				a.tracks[i].rms_db = a.tracks[i].peak_db - 7
			}
		}
		peak: f32 = -60
		for t in a.tracks {
			peak = max(peak, t.peak_db)
		}
		a.master.peak_db = peak
		a.master.rms_db = peak - 6
		return
	}
	if e.play.active {
		sig := ui.app_time_sig(a)
		e.play.click_enabled = a.metronome
		e.play.click_absolute = a.timing_mode == .Grid
		e.play.bpm = a.bpm
		e.play.sig_num = int(sig.num)
		e.play.sig_den = int(sig.den)
		if e.play.use_live_mixer {
			params := live_mix_params_from_app(a, e.play.mute_armed)
			if !e.play.has_published_params || params != e.play.last_published_params {
				playback_params_publish(&e.play, params)
			}
		}
		cursor := sync.atomic_load(&e.play.cursor)
		if !e.play.unbounded && cursor >= i64(e.play.frames) {
			engine_stop_playback(e)
			ui.app_force_stopped(a, "preview finished")
			return
		}
		a.frames = cursor
		if e.play.use_live_mixer {
			for i in 0 ..< MAX_ENGINE_TRACKS {
				if i >= e.play.track_count || len(e.play.tracks[i]) == 0 || int(cursor) >= len(e.play.tracks[i]) {
					a.tracks[i].peak_db = -60
					a.tracks[i].rms_db = -60
					a.tracks[i].gr_db = 0
					continue
				}
				pk := sync.atomic_load(&e.play.track_peak[i])
				a.tracks[i].peak_db = dsp.lin_to_db(pk)
				a.tracks[i].rms_db = a.tracks[i].peak_db - 6
				a.tracks[i].gr_db = sync.atomic_load(&e.play.track_gr[i])
			}
			mp := sync.atomic_load(&e.play.master_peak)
			a.master.peak_db = dsp.lin_to_db(mp)
			a.master.rms_db = a.master.peak_db - 6
			a.master.gr_db = sync.atomic_load(&e.play.master_gr)
			return
		}
		idx := int(cursor)
		for i in 0 ..< MAX_ENGINE_TRACKS {
			src := e.loaded[i]
			if src == nil || idx < 0 || idx >= len(src) {
				a.tracks[i].peak_db = -60
				continue
			}
			peak: f32 = 0
			for f in idx ..< min(idx + 512, len(src)) {
				peak = max(peak, abs(src[f]))
			}
			a.tracks[i].peak_db = dsp.lin_to_db(peak * a.tracks[i].level)
			a.tracks[i].rms_db = a.tracks[i].peak_db - 6
		}
		if idx >= 0 && idx * 2 + 1 < len(e.play.samples) {
			peak: f32 = 0
			for f in idx ..< min(idx + 512, e.play.frames) {
				peak = max(peak, abs(e.play.samples[f * 2]), abs(e.play.samples[f * 2 + 1]))
			}
			a.master.peak_db = dsp.lin_to_db(peak)
			a.master.rms_db = a.master.peak_db - 6
		}
		return
	}

	// Arm preview: show the live input on every armed track. Unarmed tracks
	// keep decaying, so the history graph clears when an arm is released.
	if e.preview.active {
		for i in 0 ..< MAX_ENGINE_TRACKS {
			a.tracks[i].peak_db += (-60 - a.tracks[i].peak_db) * 0.12
			a.tracks[i].rms_db += (-60 - a.tracks[i].rms_db) * 0.12
			a.tracks[i].gr_db += (0 - a.tracks[i].gr_db) * 0.2
		}
		for i in 0 ..< MAX_ENGINE_TRACKS {
			t := &a.tracks[i]
			if !t.armed {
				continue
			}
			ch := recorder_input_channel(t.input, e.preview.channels)
			if ch >= 0 && ch < len(e.preview.peak) {
				t.peak_db = dsp.lin_to_db(sync.atomic_load(&e.preview.peak[ch]))
				t.rms_db = t.peak_db - 7
			}
		}
		peak: f32 = -60
		for t in a.tracks {
			peak = max(peak, t.peak_db)
		}
		a.master.peak_db = peak
		a.master.rms_db = peak - 6
		return
	}

	// Idle meter decay.
	for i in 0 ..< MAX_ENGINE_TRACKS {
		a.tracks[i].peak_db += (-60 - a.tracks[i].peak_db) * 0.12
		a.tracks[i].rms_db += (-60 - a.tracks[i].rms_db) * 0.12
		a.tracks[i].gr_db += (0 - a.tracks[i].gr_db) * 0.2
	}
	a.master.peak_db += (-60 - a.master.peak_db) * 0.12
	a.master.rms_db += (-60 - a.master.rms_db) * 0.12
	a.master.gr_db += (0 - a.master.gr_db) * 0.2
}

// ---------------------------------------------------------------- monitoring

// Enables live input monitoring. It is delivered by a duplex capture device,
// so enabling it mid-take only works when that take opened duplex (monitoring
// was already on); otherwise it applies to the next take. Returns true when
// monitoring is live now (or will be for the next take while idle).
engine_monitor_start :: proc(e: ^Engine, a: ^ui.App) -> bool {
	e.monitor_enabled = true
	live := e.rec.active && e.rec.monitoring
	if live {
		monitor_set_enabled(&e.rec.monitor, true)
	}
	if a != nil {
		switch {
		case live:
			ui.status_buf_set(a, "monitor on")
		case e.rec.active:
			ui.status_buf_set(a, "monitor on · next take")
		case:
			ui.status_buf_set(a, "monitor on")
		}
	}
	return live || !e.rec.active
}

// Disables monitoring immediately. A duplex take keeps running (input still
// records); its output is silenced by the callback.
engine_monitor_stop :: proc(e: ^Engine, a: ^ui.App) -> bool {
	was := e.monitor_enabled || monitor_is_enabled(&e.rec.monitor)
	e.monitor_enabled = false
	monitor_set_enabled(&e.rec.monitor, false)
	if a != nil {
		ui.status_buf_set(a, "monitor off")
	}
	return was
}

// ---------------------------------------------------------------- latency

// Frames dropped from the start of a take for the given latency. Rounded to
// the nearest frame so odd rates (44.1 kHz, 22.05 kHz) stay within half a frame
// of the requested millisecond value.
engine_latency_frames :: proc(latency_ms: f32, rate: u32) -> int {
	if latency_ms <= 0 || rate == 0 {
		return 0
	}
	ms := min(latency_ms, 10_000.0)
	return int(math.round(f64(ms) * f64(rate) / 1000.0))
}

// Sets the capture round-trip latency used to trim new takes. Values are
// clamped to a sane 0–10 s; 0 disables compensation.
engine_set_latency_ms :: proc(e: ^Engine, latency_ms: f32) {
	e.latency_ms = clamp(latency_ms, 0, 10_000)
}

// ---------------------------------------------------------------- devices

// Word-boundary prefix match at index 0 across OS audio backends (e.g.
// CoreAudio "Scarlett 4i4 USB" <-> PipeWire "Scarlett 4i4 USB Analog Surround 5.1").
// Refuses unrelated prefixes like "Monitor of Scarlett 4i4 USB".
device_name_prefix_match :: proc(a, b: string) -> bool {
	if len(a) < 3 || len(b) < 3 || len(a) == len(b) {
		return false
	}
	short, long := a, b
	if len(a) > len(b) {
		short, long = b, a
	}
	return long[:len(short)] == short && long[len(short)] == ' '
}

// Resolves the device to open. Index and name are both considered so a list
// that shifted after an unplug does not silently pick a different device; a
// unique cross-OS profile-suffix match keeps the intended hardware selected,
// and a vanished selection falls back to the system default. Pure, for tests.
engine_resolve_device_index_ex :: proc(
	selected: int,
	selected_name: string,
	names: []string,
	default_index: int,
) -> (index: int, matched: bool) {
	if len(names) == 0 {
		return -1, false
	}
	if selected_name != "" {
		for name, i in names {
			if name == selected_name {
				return i, true
			}
		}
		match_idx := -1
		match_count := 0
		for name, i in names {
			if device_name_prefix_match(selected_name, name) {
				match_idx = i
				match_count += 1
			}
		}
		if match_count == 1 {
			return match_idx, true
		}
	} else if selected >= 0 && selected < len(names) {
		return selected, true
	}
	// The selected device is gone (or its index now points at another box);
	// fall back to the system default rather than recording the wrong device.
	if default_index >= 0 && default_index < len(names) {
		return default_index, false
	}
	return 0, false
}

engine_resolve_device_index :: proc(
	selected: int,
	selected_name: string,
	names: []string,
	default_index: int,
) -> int {
	idx, _ := engine_resolve_device_index_ex(selected, selected_name, names, default_index)
	return idx
}

@(private)
engine_sync_ui_device :: proc(a: ^ui.App, resolved_name: string, matched: bool) {
	if a == nil || resolved_name == "" {
		return
	}
	prev := ui.app_device(a)
	for d, i in a.devices {
		if d == resolved_name {
			a.device_index = i
			break
		}
	}
	if prev != resolved_name {
		if prev != "" && !matched {
			ui.toast(a, fmt.tprintf("input not found · using %s", resolved_name))
		}
		ui.app_set_device(a, resolved_name)
	}
}

engine_fallback_device_index :: proc(selected, count, default_index: int) -> int {
	if count <= 0 {
		return -1
	}
	if selected >= 0 && selected < count {
		return selected
	}
	if default_index >= 0 && default_index < count {
		return default_index
	}
	return 0
}

// Re-enumerates capture devices. Returns freshly allocated names owned by the
// caller (free each string and the slice) so a later UI pass can refresh its
// list. `e.device_index` is reconciled in place: a stale selection becomes the
// matching name or the default device.
engine_rescan_devices :: proc(e: ^Engine, a: ^ui.App) -> []string {
	names, default_index := capture_device_list()
	if e != nil {
		e.default_device_index = default_index
		selected_name := ""
		if a != nil {
			selected_name = ui.app_device(a)
		}
		e.device_index = engine_resolve_device_index(e.device_index, selected_name, names, default_index)
	}
	return names
}

engine_set_device :: proc(e: ^Engine, a: ^ui.App, index: int) {
	if e == nil || a == nil || index < 0 || index >= len(a.devices) {
		return
	}
	if index == e.device_index && a.device_index == index && ui.app_device(a) == a.devices[index] {
		return
	}
	e.device_index = index
	a.device_index = index
	ui.app_set_device(a, a.devices[index])
}

engine_match_device :: proc(e: ^Engine, a: ^ui.App, name: string) {
	if e == nil || a == nil || len(a.devices) == 0 {
		return
	}
	fallback := e.default_device_index if e.default_device_index >= 0 && e.default_device_index < len(a.devices) else 0
	idx, matched := engine_resolve_device_index_ex(e.device_index, name, a.devices, fallback)
	if idx < 0 {
		return
	}
	had_name := name != ""
	e.device_index = idx
	a.device_index = idx
	ui.app_set_device(a, a.devices[idx])
	if had_name && !matched {
		ui.toast(a, fmt.tprintf("input not found · using %s", a.devices[idx]))
	}
}
