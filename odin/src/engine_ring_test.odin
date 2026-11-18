package main

import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import ma "vendor:miniaudio"

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
	dir := "/tmp/tracker-odin-engine-writer"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	raw_path := "/tmp/tracker-odin-engine-writer/take.raw"
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
	p.beat_frames = 24_000
	p.beat_pos = 1
	p.click_left = 10
	p.click_phase = 1.0
	sync.atomic_store(&p.cursor, 0)
	out = {}
	playback_callback(&dev, raw_data(out[:]), nil, 2)
	testing.expectf(t, out[0] != 0 && out[1] != 0, "click missing")

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

// ---------------------------------------------------------------- helper

@(private)
f32_from_le_bytes :: proc(data: []byte) -> (f32, bool) {
	if len(data) < 4 {
		return 0, false
	}
	u := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	return transmute(f32)u, true
}
