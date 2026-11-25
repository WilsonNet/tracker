package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import dsp "dsp"
import ma "vendor:miniaudio"
import ui "ui"

// ---------------------------------------------------------------- ring

@(test)
recorder_input_channel_wraps_out_of_range_inputs :: proc(t: ^testing.T) {
	testing.expectf(t, recorder_input_channel(1, 2) == 0, "input 1")
	testing.expectf(t, recorder_input_channel(2, 2) == 1, "input 2")
	// The UI can select up to IN 8; a stereo fallback must not write silence.
	testing.expectf(t, recorder_input_channel(3, 2) == 0, "input 3 wraps")
	testing.expectf(t, recorder_input_channel(8, 2) == 1, "input 8 wraps")
	testing.expectf(t, recorder_input_channel(1, 1) == 0, "mono")
	testing.expectf(t, recorder_input_channel(4, 1) == 0, "mono wraps")
	testing.expectf(t, recorder_input_channel(0, 2) == 0, "zero input")
	testing.expectf(t, recorder_input_channel(-3, 2) == 0, "negative input")
	testing.expectf(t, recorder_input_channel(1, 0) == -1, "no channels")
}

@(test)
recorder_push_wraps_and_counts_dropped_frames :: proc(t: ^testing.T) {
	r := Recorder {
		channels   = 2,
		cap_frames = 4,
	}
	r.ring = make([]f32, r.cap_frames * r.channels)
	defer delete(r.ring)

	src := [12]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	recorder_push(&r, src[:], 6)

	testing.expectf(t, sync.atomic_load(&r.write_frame) == 4, "write %v", sync.atomic_load(&r.write_frame))
	testing.expectf(t, sync.atomic_load(&r.overflow) == 2, "overflow %v", sync.atomic_load(&r.overflow))
	testing.expectf(t, r.ring[0] == 1 && r.ring[7] == 8, "first block")
	testing.expectf(t, sync.atomic_load(&r.peak[0]) > 0, "peak 0")
	testing.expectf(t, sync.atomic_load(&r.peak[1]) > 0, "peak 1")

	// The reader catches up; the next push must wrap to the start of the ring.
	sync.atomic_store(&r.read_frame, 4)
	src2 := [4]f32{21, 22, 23, 24}
	recorder_push(&r, src2[:], 2)
	testing.expectf(t, sync.atomic_load(&r.write_frame) == 6, "write after wrap")
	testing.expectf(t, r.ring[0] == 21 && r.ring[1] == 22, "wrapped samples")
	testing.expectf(t, sync.atomic_load(&r.overflow) == 2, "no extra drops")
}

@(test)
recorder_push_rejects_unusable_state :: proc(t: ^testing.T) {
	r := Recorder{}
	src := [4]f32{1, 2, 3, 4}
	recorder_push(&r, src[:], 2)
	testing.expect(t, sync.atomic_load(&r.write_frame) == 0, "nil ring accepted")

	r.channels = 2
	r.cap_frames = 2
	r.ring = make([]f32, 4)
	defer delete(r.ring)
	recorder_push(&r, src[:2], 2)
	testing.expect(t, sync.atomic_load(&r.write_frame) == 2, "valid push")
	recorder_push(&r, src[:], 0)
	testing.expect(t, sync.atomic_load(&r.write_frame) == 2, "zero frames")
}

// The writer used to be created but never started; `thread.join` at stop time
// was what finally ran it, so a take longer than the ring only kept its first
// two seconds. This exercises the real thread, file drain and ordering without
// any audio hardware.
@(test)
recorder_writer_drains_while_recording :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-fx-engine-writer"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	raw_path := "/tmp/tracker-fx-engine-writer/take.raw"
	raw, ferr := os.open(raw_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	testing.expect(t, ferr == nil, "open raw take")
	if ferr != nil {
		return
	}

	e := Engine{}
	e.rec.raw = raw
	e.rec.channels = 2
	e.rec.cap_frames = 4096
	e.rec.ring = make([]f32, e.rec.cap_frames * e.rec.channels)
	defer {
		if e.rec.writer != nil {
			sync.atomic_store(&e.rec.stop, 1)
			recorder_join_writer(&e)
		}
		if raw != nil {
			_ = os.close(raw)
		}
		delete(e.rec.ring)
	}

	// This is the production start path; it must leave the writer running.
	testing.expect(t, recorder_start_writer(&e), "start writer")
	if e.rec.writer == nil {
		return
	}

	scale := f32(0.001)
	block := make([]f32, 64 * e.rec.channels)
	defer delete(block)
	for i in 0 ..< len(block) {
		block[i] = f32(i + 1) * scale
	}
	recorder_push(&e.rec, block, 64)

	// Wait until the running writer has reached the file. Before the fix this
	// stayed at 0 until stop because the thread was still suspended.
	wrote := false
	for _ in 0 ..< 100 {
		info, ierr := os.fstat(raw, context.allocator)
		if ierr == nil && info.size > 0 {
			os.file_info_delete(info, context.allocator)
			wrote = true
			break
		}
		if ierr == nil {
			os.file_info_delete(info, context.allocator)
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, wrote, "writer did not drain before stop")

	for _ in 0 ..< 5 {
		recorder_push(&e.rec, block, 64)
	}
	sync.atomic_store(&e.rec.stop, 1)
	recorder_join_writer(&e)
	_ = os.close(raw)
	raw = nil

	testing.expectf(t, sync.atomic_load(&e.rec.overflow) == 0, "overflow %v", sync.atomic_load(&e.rec.overflow))
	testing.expect(t, !e.rec.error, "writer reported an error")

	data, derr := os.read_entire_file(raw_path, context.allocator)
	defer delete(data)
	testing.expect(t, derr == nil, "read take")
	frames := 6 * 64
	testing.expectf(t, len(data) == frames * e.rec.channels * 4, "take bytes %d != %d", len(data), frames * e.rec.channels * 4)
	if len(data) != frames * e.rec.channels * 4 {
		return
	}
	for f in 0 ..< frames {
		for c in 0 ..< e.rec.channels {
			i := (f * e.rec.channels + c) * 4
			value, ok := f32_from_le_bytes(data[i:i + 4])
			testing.expect(t, ok, "decode sample")
			expected := f32((f % 64) * e.rec.channels + c + 1) * scale
			testing.expectf(t, abs(value - expected) < 1e-7, "sample %d/%d: %v != %v", f, c, value, expected)
		}
	}
}

// ---------------------------------------------------------------- capture

@(test)
capture_callback_is_bounded_and_keeps_the_first_frames :: proc(t: ^testing.T) {
	state := Capture_State {
		channels = 2,
		capacity = 3,
	}
	state.buffer = make([]f32, state.capacity * state.channels)
	defer delete(state.buffer)

	dev: ma.device
	dev.pUserData = &state
	src := [10]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}

	capture_callback(&dev, nil, raw_data(src[:]), 5)
	testing.expectf(t, state.written == 3, "written %d", state.written)
	testing.expectf(t, state.buffer[0] == 1 && state.buffer[5] == 6, "first frames copied")

	// A second callback cannot write past capacity or move the ring.
	capture_callback(&dev, nil, raw_data(src[:]), 2)
	testing.expectf(t, state.written == 3, "written after full %d", state.written)

	// Removing the user data or the input must be harmless.
	capture_callback(&dev, nil, nil, 2)
	dev.pUserData = nil
	capture_callback(&dev, nil, raw_data(src[:]), 2)
}

// ---------------------------------------------------------------- playback

@(test)
playback_callback_bounds_and_saturates :: proc(t: ^testing.T) {
	p: Playback
	p.samples = make([]f32, 6)
	defer delete(p.samples)
	copy(p.samples, []f32{1, 2, 3, 4, 5, 6})
	p.frames = 3
	p.rate = 48_000
	p.silent = false
	p.click_enabled = false

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	sync.atomic_store(&p.cursor, 1)
	out: [9]f32
	for i in 0 ..< len(out) {
		out[i] = -99
	}
	playback_callback(&dev, raw_data(out[:]), nil, 4)
	testing.expectf(t, out[0] == 3 && out[1] == 4, "frame 1: %v", out[0:2])
	testing.expectf(t, out[2] == 5 && out[3] == 6, "frame 2: %v", out[2:4])
	testing.expectf(t, out[4] == 0 && out[5] == 0, "past end: %v", out[4:6])
	testing.expectf(t, out[6] == 0 && out[7] == 0, "past end 2: %v", out[6:8])
	testing.expectf(t, sync.atomic_load(&p.cursor) == 3, "cursor saturates at frames")

	// Silent mode with no click must produce silence without touching samples.
	p.silent = true
	sync.atomic_store(&p.cursor, 0)
	out = {}
	playback_callback(&dev, raw_data(out[:]), nil, 2)
	testing.expectf(t, out[0] == 0 && out[1] == 0 && out[2] == 0 && out[3] == 0, "silent output")
	testing.expectf(t, sync.atomic_load(&p.cursor) == 2, "silent cursor")

	// Click mode writes the metronome into a silent preview.
	p.frames = 48_000
	p.silent = true
	p.click_enabled = true
	p.click_absolute = true
	p.has_last_beat = false
	p.bpm = 120
	p.sig_num = 4
	p.sig_den = 4
	sync.atomic_store(&p.cursor, 0)
	out = {}
	playback_callback(&dev, raw_data(out[:]), nil, 2)
	testing.expectf(t, out[0] == 0 && out[1] == 0, "sin(0) starts at 0")
	testing.expectf(t, out[2] != 0 && out[3] != 0, "click missing on sample 1: %v", out[2:4])

	// A mono device gets a proper downmix instead of a second-channel write.
	dev.playback.channels = 1
	mono: Playback
	mono.samples = make([]f32, 2)
	defer delete(mono.samples)
	mono.samples[0] = 0.2
	mono.samples[1] = 0.6
	mono.frames = 1
	mono.rate = 48_000
	mono.click_enabled = false
	dev.pUserData = &mono
	sync.atomic_store(&mono.cursor, 0)
	mono_out: [2]f32
	playback_callback(&dev, raw_data(mono_out[:]), nil, 1)
	testing.expectf(t, abs(mono_out[0] - 0.4) < 1e-6, "mono downmix %v", mono_out[0])
}

@(test)
playback_clicktrack_absolute_relative_countin_and_accents :: proc(t: ^testing.T) {
	p: Playback
	p.frames = 48_000 * 20
	p.rate = 48_000
	p.silent = true
	p.click_enabled = true
	p.click_absolute = true
	p.bpm = 120
	p.sig_num = 4
	p.sig_den = 4

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	// Absolute Grid mode starting mid-beat (12_000 frames = 0.5 beat): silent at start,
	// triggers beat 2 (unaccented, 950 Hz) exactly at frame 24_000.
	sync.atomic_store(&p.cursor, 12_000)
	buf: [16]f32
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expect(t, buf[2] == 0, "mid-beat start must not trigger spurious click")

	sync.atomic_store(&p.cursor, 23_999)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expect(t, buf[0] == 0 && buf[2] == 0, "frame 23999 silent, frame 24000 sin(0)=0")
	testing.expectf(t, buf[4] != 0, "beat 2 should sound right after frame 24000: %v", buf[4])
	testing.expectf(t, abs(p.click_freq - 950.0) < 1.0, "beat 2 is normal pitch, got %v", p.click_freq)

	// Downbeat at Bar 2 Beat 1 (frame 96_000) gets accented 1500 Hz downbeat.
	p.click_left = 0
	p.has_last_beat = false
	sync.atomic_store(&p.cursor, 95_999)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, buf[4] != 0 && abs(p.click_freq - 1500.0) < 1.0, "bar 2 beat 1 accented downbeat, freq=%v", p.click_freq)

	// Negative count-in from -96_000 (Bar -1 Beat 1) with countin_click_active and click_enabled = false:
	// ticks at -96_000 (accented), stops clicking once cursor reaches 0.
	c: Playback
	c.frames = 48_000 * 10
	c.rate = 48_000
	c.silent = true
	c.click_enabled = false
	c.click_absolute = true
	c.countin_click_active = true
	c.countin_click_until = 0
	c.bpm = 120
	c.sig_num = 4
	c.sig_den = 4
	dev.pUserData = &c
	sync.atomic_store(&c.cursor, -96_000)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, buf[2] != 0 && abs(c.click_freq - 1500.0) < 1.0, "count-in beat 1 accented at -96000, freq=%v", c.click_freq)
	c.click_left = 0
	sync.atomic_store(&c.cursor, 0)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expect(t, buf[2] == 0, "count-in-only stops clicking at frame 0 when metronome is off")

	// Relative Free mode starting mid-timeline (frame 12_000): beat 1 triggers immediately at click_origin.
	r: Playback
	r.frames = 48_000 * 10
	r.rate = 48_000
	r.silent = true
	r.click_enabled = true
	r.click_absolute = false
	r.click_origin = 12_000
	r.bpm = 120
	r.sig_num = 4
	r.sig_den = 4
	dev.pUserData = &r
	sync.atomic_store(&r.cursor, 12_000)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, buf[2] != 0 && abs(r.click_freq - 1500.0) < 1.0, "relative mode starts beat 1 at click_origin, freq=%v", r.click_freq)

	// Zero cumulative drift over 100 beats at non-integer BPM (127 BPM @ 48 kHz).
	d: Playback
	d.frames = 48_000 * 120
	d.rate = 48_000
	d.silent = true
	d.click_enabled = true
	d.click_absolute = true
	d.bpm = 127
	d.sig_num = 4
	d.sig_den = 4
	beat_f := (60.0 / 127.0) * 48_000.0
	target_100 := i64(math.floor(100.0 * beat_f))
	d.last_beat_idx = 99
	d.has_last_beat = true
	_ = playback_click_step(&d, target_100)
	testing.expect(t, d.click_left == 0, "before exact 100th beat must not fire early")
	_ = playback_click_step(&d, target_100 + 1)
	testing.expect(t, d.click_left > 0 && abs(d.click_freq - 1500.0) < 1.0, "100th beat (bar 26 beat 1) fires at exact f64 frame without drift")
}

@(test)
playback_unbounded_keeps_metronome_clicking_past_audio_end :: proc(t: ^testing.T) {
	// Existing recorded take is 1 s (48_000 frames = 2 beats at 120 BPM 4/4).
	// Unbounded playback must stop reading audio at p.frames while keeping the
	// cursor advancing so grid and free metronome clicks never stop.
	p: Playback
	p.frames = 48_000
	p.samples = make([]f32, p.frames * 2)
	defer delete(p.samples)
	for i in 0 ..< len(p.samples) {
		p.samples[i] = 0.25
	}
	p.rate = 48_000
	p.silent = false
	p.unbounded = true
	p.click_enabled = true
	p.click_absolute = true
	p.bpm = 120
	p.sig_num = 4
	p.sig_den = 4

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	// Cross p.frames (48_000 = Bar 1 Beat 3): first 2 samples carry audio (0.25),
	// samples past p.frames drop track audio to 0 and sound Beat 3 click (950 Hz),
	// and cursor advances to 48_002 instead of saturating at 48_000.
	sync.atomic_store(&p.cursor, 47_998)
	buf: [16]f32
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 48_002, "cursor must advance past p.frames, got %d", sync.atomic_load(&p.cursor))
	testing.expectf(t, abs(buf[0] - 0.25) < 1e-6 && abs(buf[2] - 0.25) < 1e-6, "frames before p.frames play track audio: %v", buf[0:4])
	testing.expectf(t, buf[4] == 0 && buf[6] != 0 && abs(p.click_freq - 950.0) < 1.0, "beat 3 triggers right at p.frames with no out-of-bounds audio: %v freq=%v", buf[4:8], p.click_freq)

	// Once click decay finishes past p.frames, output returns cleanly to silence.
	p.click_left = 0
	sync.atomic_store(&p.cursor, 50_000)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expect(t, buf[0] == 0 && buf[2] == 0 && buf[4] == 0 && buf[6] == 0, "past p.frames between beats is silent")

	// Beat 4 (72_000) and Bar 2 Beat 1 (96_000, accented 1500 Hz) keep firing cleanly.
	sync.atomic_store(&p.cursor, 71_999)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 72_003 && buf[4] != 0 && abs(p.click_freq - 950.0) < 1.0, "beat 4 fires at 72000")

	p.click_left = 0
	sync.atomic_store(&p.cursor, 95_999)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, buf[4] != 0 && abs(p.click_freq - 1500.0) < 1.0, "bar 2 beat 1 fires accented past p.frames, freq=%v", p.click_freq)

	// Starting a punch-in directly at/past p.frames still advances and clicks.
	p.click_left = 0
	p.has_last_beat = false
	sync.atomic_store(&p.cursor, 48_000)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 48_004 && buf[2] != 0, "starting at p.frames clicks immediately")

	// Free/relative timing mode also continues clicking past p.frames.
	p.click_absolute = false
	p.click_origin = 0
	p.click_left = 0
	p.has_last_beat = false
	p.last_beat_idx = 0
	sync.atomic_store(&p.cursor, 71_999)
	buf = {}
	playback_callback(&dev, raw_data(buf[:]), nil, 4)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 72_003 && buf[4] != 0, "free mode keeps clicking past p.frames")
}

@(test)
playback_callback_live_mixer_updates_seeks_and_ramps_to_idle :: proc(t: ^testing.T) {
	p: Playback
	rate: u32 = 48_000
	dsp.live_mixer_init(&p.mixer, f32(rate))
	defer dsp.live_mixer_destroy(&p.mixer)
	p.mixer_rate = rate

	tr0 := make([]f32, 48_000)
	tr1 := make([]f32, 48_000)
	defer delete(tr0)
	defer delete(tr1)
	for i in 0 ..< 48_000 {
		tr0[i] = 0.5
		tr1[i] = 0.25 * math.sin(f32(i) * 0.05)
	}
	p.tracks[0] = tr0
	p.tracks[1] = tr1
	p.track_count = 2
	p.use_live_mixer = true
	p.frames = 48_000
	p.rate = rate
	p.device_open = true
	p.fade_in_len = 64
	p.fade_in_left = 64

	params := dsp.Live_Mix_Params{track_count = 2}
	for i in 0 ..< 2 {
		params.tracks[i] = dsp.track_mix_default()
		params.tracks[i].level = 1.0
		params.tracks[i].eq.enabled = false
		params.tracks[i].comp.enabled = false
	}
	params.master_comp = dsp.fx_settings_default().master_comp
	params.reverb = dsp.reverb_params_default()
	params.reverb.enabled = true
	params.reverb.predelay_ms = 0
	params.tracks[0].send_reverb = 0.6
	params.delay = dsp.delay_params_default()
	params.width = dsp.width_params_default()
	params.limiter = dsp.limiter_params_default()
	params.limiter.enabled = false

	dsp.live_mixer_apply_params(&p.mixer, &params, true)
	dsp.live_mixer_reset(&p.mixer)
	playback_params_reset(&p, params)
	sync.atomic_store(&p.playing, 1)

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	out: [512]f32 // 256 stereo frames
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expect(t, sync.atomic_load(&p.cursor) == 256, "cursor advanced 256 frames")
	testing.expect(t, abs(out[0]) < abs(out[126]), "fade-in ramp grew from start of block")
	testing.expect(t, sync.atomic_load(&p.track_peak[0]) > 0.1, "track 0 peak published")

	// Live mute both tracks via triple buffer; after smoothing settles, dry audio drops out.
	params.tracks[0].muted = true
	params.tracks[1].muted = true
	params.tracks[0].send_reverb = 0
	params.reverb.enabled = false
	playback_params_publish(&p, params)
	for _ in 0 ..< 16 {
		playback_callback(&dev, raw_data(out[:]), nil, 256)
	}
	testing.expectf(t, abs(out[510]) < 1e-4 && abs(out[511]) < 1e-4, "live mute settled to silence, got %v %v", out[510], out[511])

	// Seeking resets mixer state and retriggers micro fade-in.
	sync.atomic_store(&p.seek_gen, 1)
	params.tracks[0].muted = false
	playback_params_publish(&p, params)
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expect(t, p.mixer_seek_gen == 1, "seek_gen handled in callback")

	// Warm idle mode ramps down to zero and keeps device ready without touching tracks.
	sync.atomic_store(&p.playing, 0)
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, out[510] == 0 && out[511] == 0, "idle tail settled to zero: %v %v", out[510], out[511])
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, out[0] == 0 && out[511] == 0, "subsequent idle block silent")
}

@(test)
playback_live_prepare_60s_4tracks_is_instant :: proc(t: ^testing.T) {
	// Measure live mixer preparation + first 256-frame callback on a 60 s 4-track
	// project with full FX enabled (previously ~1,500-3,200 ms offline render).
	rate: u32 = 48_000
	frames := 48_000 * 60
	e: Engine
	e.sample_rate = rate
	e.play_tracks_dirty = true
	defer {
		dsp.live_mixer_destroy(&e.play.mixer)
		engine_free_play_tracks(&e)
		for i in 0 ..< 4 {
			delete(e.loaded[i])
			e.loaded[i] = nil
		}
	}
	for i in 0 ..< 4 {
		e.loaded[i] = make([]f32, frames)
		e.loaded_rate[i] = rate
		e.loaded[i][0] = 0.5
		e.loaded[i][100] = -0.5
	}
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.sample_rate = rate
	a.master.reverb.enabled = true
	a.master.delay.enabled = true
	a.master.comp.enabled = true
	a.master.limiter.enabled = true
	for i in 0 ..< 4 {
		a.tracks[i].has_audio = true
		a.tracks[i].send_reverb = 0.25
		a.tracks[i].send_delay = 0.2
		a.tracks[i].eq.low_db = 2.0
	}

	// Warm mixer once (as engine_playback_warm does at startup).
	engine_sync_play_tracks(&e)
	playback_ensure_mixer(&e, rate)

	t0 := time.now()
	params := live_mix_params_from_app(&a, false)
	dsp.live_mixer_apply_params(&e.play.mixer, &params, true)
	dsp.live_mixer_reset(&e.play.mixer)
	playback_params_reset(&e.play, params)
	e.play.tracks = e.play_tracks
	e.play.track_count = params.track_count
	e.play.use_live_mixer = true
	e.play.frames = frames + int(dsp.live_mix_tail_seconds(&params) * f32(rate))
	e.play.rate = rate
	e.play.fade_in_len = 64
	e.play.fade_in_left = 64
	e.play.active = true
	sync.atomic_store(&e.play.playing, 1)

	dev: ma.device
	dev.pUserData = &e.play
	dev.playback.channels = 2
	out: [512]f32
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	ms := time.duration_milliseconds(time.since(t0))
	fmt.printfln("[perf] live playback prepare + 256f block (60s x 4tr full FX): %.3f ms", ms)
	testing.expectf(t, ms < 5.0, "live start took too long: %.3f ms", ms)
}

@(test)
playback_callback_preroll_song_and_click_only :: proc(t: ^testing.T) {
	rate: u32 = 48_000
	p: Playback
	dsp.live_mixer_init(&p.mixer, f32(rate))
	defer dsp.live_mixer_destroy(&p.mixer)
	p.mixer_rate = rate

	tr0 := make([]f32, 1024) // armed track
	tr1 := make([]f32, 1024) // backing track
	defer delete(tr0)
	defer delete(tr1)
	for i in 0 ..< 1024 {
		tr0[i] = 0.5
		tr1[i] = 0.25
	}
	p.tracks[0] = tr0
	p.tracks[1] = tr1
	p.track_count = 2
	p.use_live_mixer = true
	p.mute_armed = true
	p.armed_mask[0] = true
	p.preroll_active = true
	p.preroll_audio = true
	p.preroll_until = 256
	p.frames = 1024
	p.rate = rate
	p.device_open = true

	params := dsp.Live_Mix_Params{track_count = 2}
	for i in 0 ..< 2 {
		params.tracks[i] = dsp.track_mix_default()
		params.tracks[i].level = 1.0
		params.tracks[i].eq.enabled = false
		params.tracks[i].comp.enabled = false
		params.tracks[i].muted = false // effective_mute_armed = false during Song pre-roll
	}
	params.master_comp = dsp.fx_settings_default().master_comp
	params.master_comp.enabled = false
	params.reverb = dsp.reverb_params_default()
	params.reverb.enabled = false
	params.delay = dsp.delay_params_default()
	params.delay.enabled = false
	params.width = dsp.width_params_default()
	params.width.enabled = false
	params.limiter = dsp.limiter_params_default()
	params.limiter.enabled = false

	dsp.live_mixer_apply_params(&p.mixer, &params, true)
	dsp.live_mixer_reset(&p.mixer)
	playback_params_reset(&p, params)
	sync.atomic_store(&p.playing, 1)

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	// Song mode during pre-roll [0..256): both armed track 0 and backing track 1 play.
	out: [512]f32 // 256 stereo frames
	sync.atomic_store(&p.cursor, 0)
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, sync.atomic_load(&p.track_peak[0]) > 0.2, "armed track lead-in audible during Song pre-roll, peak=%v", sync.atomic_load(&p.track_peak[0]))
	testing.expectf(t, sync.atomic_load(&p.track_peak[1]) > 0.1, "backing track audible during Song pre-roll, peak=%v", sync.atomic_load(&p.track_peak[1]))

	// Past punch-in [256..512): armed track 0 mutes cleanly while backing track 1 continues.
	sync.atomic_store(&p.track_peak[0], 0)
	sync.atomic_store(&p.track_peak[1], 0)
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, sync.atomic_load(&p.track_peak[0]) == 0, "armed track muted at punch-in, peak=%v", sync.atomic_load(&p.track_peak[0]))
	testing.expectf(t, sync.atomic_load(&p.track_peak[1]) > 0.1, "backing track continues past punch-in, peak=%v", sync.atomic_load(&p.track_peak[1]))

	// Click-only mode during pre-roll [0..256): song muted, count-in click audible; after 256 song enters & count-in click stops.
	p.preroll_audio = false
	p.countin_click_active = true
	p.countin_click_until = 256
	p.click_enabled = false
	p.click_absolute = true
	p.has_last_beat = false
	p.click_left = 0
	p.bpm = 120
	p.sig_num = 4
	p.sig_den = 4
	p.fade_in_len = 32
	p.fade_in_left = 0
	dsp.live_mixer_reset(&p.mixer)
	sync.atomic_store(&p.track_peak[0], 0)
	sync.atomic_store(&p.track_peak[1], 0)
	sync.atomic_store(&p.cursor, 0)
	out = {}
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, sync.atomic_load(&p.track_peak[0]) == 0 && sync.atomic_load(&p.track_peak[1]) == 0, "click-only pre-roll mutes song tracks")
	testing.expectf(t, abs(out[2]) > 0.01, "click-only pre-roll plays count-in click: %v", out[2])

	p.click_left = 0
	sync.atomic_store(&p.track_peak[0], 0)
	sync.atomic_store(&p.track_peak[1], 0)
	out = {}
	playback_callback(&dev, raw_data(out[:]), nil, 256)
	testing.expectf(t, sync.atomic_load(&p.track_peak[0]) == 0, "armed track stays muted after click-only punch-in")
	testing.expectf(t, sync.atomic_load(&p.track_peak[1]) > 0.1, "backing track enters after click-only punch-in")
}

@(test)
playback_callback_loops_section_sample_accurately :: proc(t: ^testing.T) {
	p: Playback
	p.samples = make([]f32, 400) // 200 stereo frames: frame i -> sample i/200.0
	defer delete(p.samples)
	for i in 0 ..< 200 {
		v := f32(i) / 200.0
		p.samples[i * 2 + 0] = v
		p.samples[i * 2 + 1] = v
	}
	p.frames = 200
	p.rate = 48_000
	p.silent = false
	p.click_enabled = false
	sync.atomic_store(&p.loop_start, 100)
	sync.atomic_store(&p.loop_end, 180)
	sync.atomic_store(&p.loop_enabled, 1)

	dev: ma.device
	dev.pUserData = &p
	dev.playback.channels = 2

	// 120 frames starting at 100: [100..180) (80 frames) then wraps to [100..140) (40 frames).
	sync.atomic_store(&p.cursor, 100)
	out: [240]f32
	playback_callback(&dev, raw_data(out[:]), nil, 120)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 140, "loop wrapped to 140, got %d", sync.atomic_load(&p.cursor))
	testing.expectf(t, abs(out[0] - 100.0 / 200.0) < 1e-5, "frame 0 is 100, got %v", out[0])
	testing.expectf(t, abs(out[79 * 2] - 179.0 / 200.0) < 1e-5, "frame 79 is 179, got %v", out[79 * 2])
	testing.expectf(t, abs(out[80 * 2] - 100.0 / 200.0) < 1e-5, "frame 80 wrapped to 100, got %v", out[80 * 2])

	// Looping past p.frames (empty tail between p.frames and loop_end) still wraps cleanly without OOB.
	sync.atomic_store(&p.loop_start, 180)
	sync.atomic_store(&p.loop_end, 260)
	sync.atomic_store(&p.cursor, 198)
	out2: [140]f32 // 70 frames: 198..259 (62 frames) -> wraps to 180..187 (8 frames)
	playback_callback(&dev, raw_data(out2[:]), nil, 70)
	testing.expectf(t, sync.atomic_load(&p.cursor) == 188, "loop past p.frames wrapped to 188, got %d", sync.atomic_load(&p.cursor))
	testing.expectf(t, abs(out2[0] - 198.0 / 200.0) < 1e-5 && out2[4] == 0, "zero-pads past p.frames before wrap")
	testing.expectf(t, abs(out2[62 * 2] - 180.0 / 200.0) < 1e-5, "wrapped back to 180 after silent tail")
}

// ---------------------------------------------------------------- helper

@(private)
f32_from_le_bytes :: proc(data: []byte) -> (f32, bool) {
	if len(data) < 4 {
		return 0, false
	}
	u := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	return transmute(f32)u, true
}
