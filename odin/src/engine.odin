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

MAX_ENGINE_TRACKS :: 4
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
}

Playback :: struct {
	active:  bool,
	ctx:     ma.context_type,
	device:  ma.device,
	samples: []f32,
	frames:  int,
	cursor:  u64,
	rate:    u32,
	silent:  bool,
	click_enabled: bool,
	bpm:     int,
	beat_frames: int,
	beat_pos: int,
	click_left: int,
	click_phase: f32,
}

Engine :: struct {
	session_dir:  string,
	project_path: string,
	take_path:    string,
	bounce_path:  string,
	sample_rate:  u32,
	device_index: int,
	loaded:       [MAX_ENGINE_TRACKS][]f32,
	loaded_rate:  [MAX_ENGINE_TRACKS]u32,
	rec:          Recorder,
	play:         Playback,
	last_mix:     []f32,
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
	dir := flag_string(args, "--session", "")
	if dir == "" {
		home := os.get_env("HOME", context.allocator)
		defer delete(home)
		dir = fmt.aprintf("%s/.local/share/tracker/session", home)
	} else {
		dir = fmt.aprintf("%s", dir)
	}
	e.session_dir = dir
	e.project_path = fmt.aprintf("%s/project.json", dir)
	e.take_path = fmt.aprintf("%s/take.raw", dir)
	e.bounce_path = fmt.aprintf("%s/bounce.wav", dir)
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
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
	}
	return true
}

engine_destroy :: proc(e: ^Engine) {
	engine_stop_playback(e)
	if e.rec.active {
		engine_record_stop(e, nil)
	} else if e.rec.device_open || e.rec.ctx_open || e.rec.raw != nil || e.rec.writer != nil {
		sync.atomic_store(&e.rec.stop, 1)
		recorder_join_writer(e)
		recorder_release(e, true, true)
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		delete(e.loaded[i])
		e.loaded[i] = nil
	}
	delete(e.last_mix)
	e.last_mix = nil
	delete(e.session_dir)
	delete(e.project_path)
	delete(e.take_path)
	delete(e.bounce_path)
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
	if r == nil || !r.active || input == nil || frame_count == 0 || r.channels <= 0 {
		return
	}
	src := cast([^]f32)input
	frames := int(frame_count)
	recorder_push(r, src[:frames * r.channels], frames)
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
	if e.rec.device_open {
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

engine_record_start :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if e.rec.active || a == nil {
		return false
	}

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

	// The previous preview (if any) must not keep playing under a new take.
	engine_stop_playback(e)

	e.sample_rate = a.sample_rate if a.sample_rate != 0 else 48_000
	e.sample_rate = clamp(e.sample_rate, 8_000, 384_000)

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
	idx := e.device_index
	if idx < 0 {
		idx = 0
		for i in 0 ..< int(count) {
			if infos[i].isDefault {
				idx = i
				break
			}
		}
	}
	idx = clamp(idx, 0, int(count) - 1)

	cfg := ma.device_config_init(.capture)
	cfg.sampleRate = e.sample_rate
	cfg.capture.format = .f32
	cfg.capture.pDeviceID = &infos[idx].id
	cfg.dataCallback = recorder_callback
	cfg.pUserData = &e.rec
	cfg.periodSizeInFrames = 1024

	// If the device rejects the widest requested input, fall back in steps
	// instead of failing the take outright. `ma_device_init` zeroes the device
	// on entry, so retrying into the same struct is safe.
	opened := false
	last_channels := 0
	attempts := [5]int{requested, 8, 4, 2, 1}
	for attempt in attempts {
		if attempt > requested || attempt == last_channels {
			continue
		}
		last_channels = attempt
		cfg.capture.channels = u32(attempt)
		if ma.device_init(&e.rec.ctx, &cfg, &e.rec.device) == .SUCCESS {
			opened = true
			break
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
	e.sample_rate = e.rec.rate
	a.sample_rate = e.rec.rate

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
	want_playback := overdub || a.metronome

	// Prepare the guide mix before the capture device starts. Rendering is the
	// slow part of an overdub and must not become recorded pre-roll that
	// shifts the new performance out of alignment with the existing tracks.
	if want_playback {
		if !playback_prepare(e, a, true) {
			recorder_release(e, true, true)
			_ = os.remove(e.take_path)
			ui.status_buf_set(a, "cannot start playback")
			return false
		}
	}

	e.rec.active = true
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

	ui.status_buf_set(a, fmt.tprintf("recording %d ch @ %d Hz%s%s", e.rec.channels, e.rec.rate, " · overdub" if overdub else "", " · click" if a.metronome else ""))
	return true
}

engine_record_stop :: proc(e: ^Engine, a: ^ui.App) -> bool {
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

	// Stop the guide first so no playback outlives the take, then stop the
	// capture callback before telling the writer to drain and exit.
	engine_stop_playback(e)
	_ = ma.device_stop(&e.rec.device)
	sync.atomic_store(&e.rec.stop, 1)
	recorder_join_writer(e)

	overflow := sync.atomic_load(&e.rec.overflow)
	write_error := e.rec.error
	recorder_release(e, true, true)

	ok := engine_split_take(e, a)
	if a != nil {
		switch {
		case !ok:
			ui.status_buf_set(a, "take failed")
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

	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if !e.rec.armed[i] {
			continue
		}
		mono := make([]f32, frames)
		ch := recorder_input_channel(e.rec.inputs[i], channels)
		if ch >= 0 && ch < channels {
			for f in 0 ..< frames {
				v, _ := endian.get_f32(data[(f * channels + ch) * 4:], .Little)
				mono[f] = v
			}
		}
		path := fmt.tprintf("%s/track%d.wav", e.session_dir, i + 1)
		if !wav_write(path, e.rec.rate, 1, mono) {
			delete(mono)
			continue
		}
		delete(e.loaded[i])
		e.loaded[i] = mono
		e.loaded_rate[i] = e.rec.rate
		if a != nil {
			a.tracks[i].has_audio = true
		}
		any = true
	}
	_ = os.remove(e.take_path)
	return any
}

// ---------------------------------------------------------------- playback

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
	out := cast([^]f32)output
	cursor := sync.atomic_load(&p.cursor)
	frames := int(frame_count)
	click_len := max(int(f32(p.rate) * 0.012), 1)
	for f in 0 ..< frames {
		// Compare in u64 before narrowing: a preview that ended just before
		// this callback must not turn into a negative array index.
		pos := cursor + u64(f)
		l: f32 = 0
		r: f32 = 0
		if !p.silent && pos < u64(p.frames) {
			idx := int(pos)
			if idx >= 0 && idx * 2 + 1 < len(p.samples) {
				l = p.samples[idx * 2 + 0]
				r = p.samples[idx * 2 + 1]
			}
		}
		if p.click_enabled {
			if p.beat_pos <= 0 {
				p.beat_pos = p.beat_frames
				p.click_left = click_len
				p.click_phase = 0
			}
			p.beat_pos -= 1
			if p.click_left > 0 {
				env := f32(p.click_left) / f32(click_len)
				v := math.sin(p.click_phase) * 0.22 * env
				l += v
				r += v
				p.click_phase += f32(math.TAU) * 1000.0 / f32(max(p.rate, 1))
				p.click_left -= 1
			}
		}
		for c in 0 ..< channels {
			out[f * channels + c] = (l + r) * 0.5 if channels == 1 else (l if c % 2 == 0 else r)
		}
	}
	// Saturate instead of wrapping if a callback arrives after the end.
	next := cursor
	if next < u64(p.frames) {
		remaining := u64(p.frames) - next
		next = u64(p.frames) if u64(frames) >= remaining else next + u64(frames)
	}
	sync.atomic_store(&p.cursor, next)
}

engine_load_tracks :: proc(e: ^Engine, a: ^ui.App) -> bool {
	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
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
	return any
}

@(private)
engine_track_audio :: proc(e: ^Engine) -> (tracks: [][]f32, owned: [MAX_ENGINE_TRACKS]bool) {
	tracks = make([][]f32, MAX_ENGINE_TRACKS)
	for i in 0 ..< MAX_ENGINE_TRACKS {
		src := e.loaded[i]
		if src == nil || e.loaded_rate[i] == e.sample_rate {
			tracks[i] = src
			continue
		}
		tracks[i] = dsp.resample(src, e.loaded_rate[i], e.sample_rate)
		owned[i] = true
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

engine_render_mix :: proc(e: ^Engine, a: ^ui.App, mute_armed: bool = false) -> (dsp.Render_Output, bool) {
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
	out := dsp.render_mix(tracks, settings, f32(e.sample_rate))
	if out.frames <= 0 {
		dsp.render_destroy(&out)
		return {}, false
	}
	return out, true
}

// Renders the guide mix and opens the output device, but does not start it.
// Splitting preparation from `playback_start` lets record start render before
// the capture device runs, then start both clocks back to back.
@(private)
playback_prepare :: proc(e: ^Engine, a: ^ui.App, mute_armed: bool) -> bool {
	engine_stop_playback(e)
	out, have_audio := engine_render_mix(e, a, mute_armed)
	if !have_audio && !a.metronome {
		dsp.render_destroy(&out)
		return false
	}

	p := &e.play
	p.ctx = {}
	if ma.context_init(nil, 0, nil, &p.ctx) != .SUCCESS {
		dsp.render_destroy(&out)
		return false
	}
	p.samples = out.samples
	out.samples = nil
	p.frames = out.frames if have_audio else max(int(e.sample_rate), 1) * 3_600
	p.silent = !have_audio
	p.cursor = 0
	p.rate = e.sample_rate
	p.click_enabled = a.metronome
	p.bpm = a.bpm
	p.beat_frames = max(int(60.0 / f32(max(a.bpm, 1)) * f32(max(e.sample_rate, 1))), 1)
	p.beat_pos = 0
	p.click_left = 0
	p.click_phase = 0

	cfg := ma.device_config_init(.playback)
	cfg.sampleRate = e.sample_rate
	cfg.playback.format = .f32
	cfg.playback.channels = 2
	cfg.dataCallback = playback_callback
	cfg.pUserData = p
	cfg.periodSizeInFrames = 1024
	if ma.device_init(&p.ctx, &cfg, &p.device) != .SUCCESS {
		ma.context_uninit(&p.ctx)
		p.ctx = {}
		delete(p.samples)
		p.samples = nil
		p.frames = 0
		dsp.render_destroy(&out)
		return false
	}
	dsp.render_destroy(&out)
	p.active = true
	return true
}

@(private)
playback_start :: proc(e: ^Engine) -> bool {
	if !e.play.active {
		return false
	}
	if ma.device_start(&e.play.device) != .SUCCESS {
		engine_stop_playback(e)
		return false
	}
	return true
}

engine_play :: proc(e: ^Engine, a: ^ui.App, mute_armed: bool = false) -> bool {
	if !playback_prepare(e, a, mute_armed) {
		return false
	}
	return playback_start(e)
}

engine_stop_playback :: proc(e: ^Engine) {
	if !e.play.active {
		return
	}
	ma.device_stop(&e.play.device)
	ma.device_uninit(&e.play.device)
	ma.context_uninit(&e.play.ctx)
	delete(e.play.samples)
	e.play.samples = nil
	e.play.active = false
	e.play.cursor = 0
	e.play.frames = 0
}

engine_bounce :: proc(e: ^Engine, a: ^ui.App) -> bool {
	out, ok := engine_render_mix(e, a)
	if !ok {
		ui.app_bounce_finished(a, false, "record something first")
		return false
	}
	defer dsp.render_destroy(&out)
	if !wav_write(e.bounce_path, e.sample_rate, 2, out.samples) {
		ui.app_bounce_finished(a, false, "cannot write bounce.wav")
		return false
	}
	ui.app_bounce_finished(a, true, fmt.tprintf("bounce %.1f s · %.1f dBFS", f32(out.frames) / f32(e.sample_rate), out.peak_db))
	return true
}

// ---------------------------------------------------------------- polling

engine_update :: proc(e: ^Engine, a: ^ui.App) {
	if e.rec.active {
		a.frames = i64(sync.atomic_load(&e.rec.write_frame))
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
		cursor := sync.atomic_load(&e.play.cursor)
		if cursor >= u64(e.play.frames) {
			engine_stop_playback(e)
			ui.app_force_stopped(a, "preview finished")
			return
		}
		a.frames = i64(cursor)
		idx := int(cursor)
		for i in 0 ..< MAX_ENGINE_TRACKS {
			src := e.loaded[i]
			if src == nil || idx >= len(src) {
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
		if idx * 2 + 1 < len(e.play.samples) {
			peak: f32 = 0
			for f in idx ..< min(idx + 512, e.play.frames) {
				peak = max(peak, abs(e.play.samples[f * 2]), abs(e.play.samples[f * 2 + 1]))
			}
			a.master.peak_db = dsp.lin_to_db(peak)
			a.master.rms_db = a.master.peak_db - 6
		}
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
}

// ---------------------------------------------------------------- devices

engine_set_device :: proc(e: ^Engine, a: ^ui.App, index: int) {
	if index == e.device_index {
		return
	}
	e.device_index = index
	if index >= 0 && index < len(a.devices) {
		ui.app_set_device(a, a.devices[index])
	}
}

engine_match_device :: proc(e: ^Engine, a: ^ui.App, name: string) {
	for d, i in a.devices {
		if d == name {
			e.device_index = i
			return
		}
	}
}
