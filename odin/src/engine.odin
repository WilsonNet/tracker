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

G_RECORDER: ^Recorder

// ---------------------------------------------------------------- helpers

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
		if err := os.mkdir_all(dir); err != nil {
			fmt.eprintfln("cannot create session dir %s", dir)
			return false
		}
	}
	return true
}

engine_destroy :: proc(e: ^Engine) {
	engine_stop_playback(e)
	if e.rec.active {
		engine_record_stop(e, nil)
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

@(private)
recorder_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	r := cast(^Recorder)device.pUserData
	if r == nil || !r.active || input == nil {
		return
	}
	src := cast([^]f32)input
	frames := int(frame_count)
	write := sync.atomic_load(&r.write_frame)
	read := sync.atomic_load(&r.read_frame)
	peak := r.peak

	for f in 0 ..< frames {
		if write - read >= u64(r.cap_frames) {
			r.overflow += 1
			break
		}
		base := int(write % u64(r.cap_frames)) * r.channels
		for c in 0 ..< r.channels {
			v := src[f * r.channels + c]
			r.ring[base + c] = v
			peak[c] = max(peak[c] * 0.94, abs(v))
		}
		write += 1
	}
	r.peak = peak
	sync.atomic_store(&r.write_frame, write)
}

@(private)
recorder_writer :: proc(_: ^thread.Thread) {
	r := G_RECORDER
	if r == nil {
		return
	}
	chunk := make([]f32, RING_CHUNK_FRAMES * r.channels)
	defer delete(chunk)

	for {
		write := sync.atomic_load(&r.write_frame)
		read := sync.atomic_load(&r.read_frame)
		if read >= write {
			if sync.atomic_load(&r.stop) != 0 {
				break
			}
			time.sleep(2 * time.Millisecond)
			continue
		}
		n := int(min(write - read, u64(RING_CHUNK_FRAMES)))
		for f in 0 ..< n {
			frame := (read + u64(f)) % u64(r.cap_frames)
			base := int(frame) * r.channels
			for c in 0 ..< r.channels {
				chunk[f * r.channels + c] = r.ring[base + c]
			}
		}
		if _, err := os.write(r.raw, slice.to_bytes(chunk[:n * r.channels])); err != nil {
			r.error = true
			break
		}
		sync.atomic_store(&r.read_frame, read + u64(n))
	}
}

engine_record_start :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if e.rec.active {
		return false
	}
	e.sample_rate = a.sample_rate

	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		ui.status_buf_set(a, "cannot init audio")
		return false
	}

	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS || count == 0 {
		ma.context_uninit(&ctx)
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

	requested := 1
	for i in 0 ..< MAX_ENGINE_TRACKS {
		e.rec.armed[i] = a.tracks[i].armed
		e.rec.inputs[i] = a.tracks[i].input
		if a.tracks[i].armed {
			requested = max(requested, a.tracks[i].input)
		}
	}
	requested = clamp(requested, 1, 8)

	raw, ferr := os.open(e.take_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if ferr != nil {
		ma.context_uninit(&ctx)
		ui.status_buf_set(a, "cannot open take file")
		return false
	}

	e.rec.ctx = ctx
	e.rec.raw = raw
	e.rec.channels = requested
	e.rec.stop = 0
	e.rec.write_frame = 0
	e.rec.read_frame = 0
	e.rec.overflow = 0
	e.rec.error = false
	e.rec.rate = e.sample_rate

	cfg := ma.device_config_init(.capture)
	cfg.sampleRate = e.sample_rate
	cfg.capture.format = .f32
	cfg.capture.channels = u32(requested)
	cfg.capture.pDeviceID = &infos[idx].id
	cfg.dataCallback = recorder_callback
	cfg.pUserData = &e.rec
	cfg.periodSizeInFrames = 1024

	res := ma.device_init(&e.rec.ctx, &cfg, &e.rec.device)
	if res != .SUCCESS && requested > 1 {
		cfg.capture.channels = 2
		e.rec.channels = 2
		res = ma.device_init(&e.rec.ctx, &cfg, &e.rec.device)
	}
	if res != .SUCCESS {
		os.close(raw)
		ma.context_uninit(&e.rec.ctx)
		ui.status_buf_set(a, "cannot open capture device")
		return false
	}

	e.rec.channels = int(e.rec.device.capture.channels)
	e.rec.rate = e.rec.device.sampleRate
	e.sample_rate = e.rec.rate
	a.sample_rate = e.rec.rate
	e.rec.cap_frames = max(int(e.rec.rate) * 2, 4_096)
	e.rec.ring = make([]f32, e.rec.cap_frames * e.rec.channels)
	e.rec.active = true
	for i in 0 ..< 32 {
		e.rec.peak[i] = 0
	}

	G_RECORDER = &e.rec
	e.rec.writer = thread.create(recorder_writer)
	if e.rec.writer != nil {
		thread.start(e.rec.writer)
	}

	if ma.device_start(&e.rec.device) != .SUCCESS {
		sync.atomic_store(&e.rec.stop, 1)
		if e.rec.writer != nil {
			thread.join(e.rec.writer)
			thread.destroy(e.rec.writer)
			e.rec.writer = nil
		}
		ma.device_uninit(&e.rec.device)
		ma.context_uninit(&e.rec.ctx)
		os.close(raw)
		delete(e.rec.ring)
		e.rec.ring = nil
		e.rec.active = false
		ui.status_buf_set(a, "cannot start capture")
		return false
	}

	overdub := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if e.loaded[i] != nil {
			overdub = true
		}
	}
	if overdub || a.metronome {
		_ = engine_play(e, a, true)
	}
	ui.status_buf_set(a, fmt.tprintf("recording %d ch @ %d Hz%s%s", e.rec.channels, e.rec.rate, " · overdub" if overdub else "", " · click" if a.metronome else ""))
	return true
}

engine_record_stop :: proc(e: ^Engine, a: ^ui.App) -> bool {
	if !e.rec.active {
		return false
	}
	ma.device_stop(&e.rec.device)
	engine_stop_playback(e)
	sync.atomic_store(&e.rec.stop, 1)
	if e.rec.writer != nil {
		thread.join(e.rec.writer)
		thread.destroy(e.rec.writer)
		e.rec.writer = nil
	}
	ma.device_uninit(&e.rec.device)
	ma.context_uninit(&e.rec.ctx)
	os.close(e.rec.raw)
	e.rec.raw = nil
	e.rec.active = false

	ok := engine_split_take(e, a)
	delete(e.rec.ring)
	e.rec.ring = nil
	if a != nil {
		if ok {
			ui.status_buf_set(a, "take captured")
		} else {
			ui.status_buf_set(a, "take failed")
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
	if channels <= 0 || len(data) < 4 {
		return false
	}
	frames := len(data) / (4 * channels)
	if frames == 0 {
		return false
	}

	any := false
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if !e.rec.armed[i] {
			continue
		}
		mono := make([]f32, frames)
		ch := e.rec.inputs[i] - 1
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
	p := cast(^Playback)device.pUserData
	if p == nil || output == nil {
		return
	}
	out := cast([^]f32)output
	cursor := sync.atomic_load(&p.cursor)
	frames := int(frame_count)
	click_len := max(int(f32(p.rate) * 0.012), 1)
	for f in 0 ..< frames {
		idx := int(cursor + u64(f))
		l: f32 = 0
		r: f32 = 0
		if !p.silent && idx < p.frames {
			l = p.samples[idx * 2 + 0]
			r = p.samples[idx * 2 + 1]
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
		out[f * 2 + 0] = l
		out[f * 2 + 1] = r
	}
	sync.atomic_store(&p.cursor, cursor + u64(frames))
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
		if !ok {
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

engine_play :: proc(e: ^Engine, a: ^ui.App, mute_armed: bool = false) -> bool {
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
	p.frames = out.frames if have_audio else int(e.sample_rate) * 3_600
	p.silent = !have_audio
	p.cursor = 0
	p.rate = e.sample_rate
	p.active = true
	p.click_enabled = a.metronome
	p.bpm = a.bpm
	p.beat_frames = max(int(60.0 / f32(max(a.bpm, 1)) * f32(e.sample_rate)), 1)
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
		dsp.render_destroy(&out)
		delete(p.samples)
		p.samples = nil
		p.active = false
		return false
	}
	if ma.device_start(&p.device) != .SUCCESS {
		ma.device_uninit(&p.device)
		ma.context_uninit(&p.ctx)
		delete(p.samples)
		p.samples = nil
		p.active = false
		return false
	}
	dsp.render_destroy(&out)
	return true
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
		if e.play.active {
			e.play.click_enabled = a.metronome
			e.play.bpm = a.bpm
			e.play.beat_frames = max(int(60.0 / f32(max(a.bpm, 1)) * f32(e.sample_rate)), 1)
		}
		a.frames = i64(sync.atomic_load(&e.rec.write_frame))
		for i in 0 ..< MAX_ENGINE_TRACKS {
			if !e.rec.armed[i] {
				continue
			}
			ch := e.rec.inputs[i] - 1
			if ch >= 0 && ch < 32 {
				a.tracks[i].peak_db = dsp.lin_to_db(e.rec.peak[ch])
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
		e.play.click_enabled = a.metronome
		e.play.bpm = a.bpm
		e.play.beat_frames = max(int(60.0 / f32(max(a.bpm, 1)) * f32(e.sample_rate)), 1)
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
