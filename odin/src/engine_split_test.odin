package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"

import ui "ui"

// ---------------------------------------------------------------- take split

@(private)
engine_test_write_raw :: proc(path: string, frames, channels: int) -> bool {
	data := make([]byte, frames * channels * 4)
	defer delete(data)
	for f in 0 ..< frames {
		for c in 0 ..< channels {
			value := f32(f * 10 + c + 1)
			_ = endian.put_f32(data[(f * channels + c) * 4:], .Little, value)
		}
	}
	return os.write_entire_file(path, data) == nil
}

@(test)
engine_split_take_writes_armed_tracks_and_wraps_inputs :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-fx-engine-split"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	e := Engine{}
	defer {
		for i in 0 ..< MAX_ENGINE_TRACKS {
			delete(e.loaded[i])
		}
		delete(e.session_dir)
		delete(e.take_path)
	}
	e.session_dir = fmt.aprintf("%s", dir)
	e.take_path = fmt.aprintf("%s/take.raw", dir)
	e.sample_rate = 48_000
	e.rec.channels = 2
	e.rec.rate = 48_000
	e.rec.armed[0] = true
	e.rec.inputs[0] = 1
	e.rec.armed[2] = true
	e.rec.inputs[2] = 3 // out of range on a stereo fallback: wraps to IN 1
	e.rec.armed[3] = true
	e.rec.inputs[3] = 2

	frames := 4
	testing.expect(t, engine_test_write_raw(e.take_path, frames, 2), "write raw")
	testing.expect(t, engine_split_take(&e, nil), "split failed")

	testing.expectf(t, len(e.loaded[0]) == frames, "track 1 frames %d", len(e.loaded[0]))
	testing.expectf(t, len(e.loaded[2]) == frames, "track 3 frames %d", len(e.loaded[2]))
	testing.expectf(t, len(e.loaded[3]) == frames, "track 4 frames %d", len(e.loaded[3]))
	testing.expect(t, e.loaded[1] == nil, "unarmed track was written")
	for f in 0 ..< frames {
		testing.expectf(t, e.loaded[0][f] == f32(f * 10 + 1), "track 1 sample %d", f)
		testing.expectf(t, e.loaded[2][f] == f32(f * 10 + 1), "track 3 should wrap to input 1")
		testing.expectf(t, e.loaded[3][f] == f32(f * 10 + 2), "track 4 sample %d", f)
	}
	testing.expectf(t, e.loaded_rate[0] == 48_000, "loaded rate %d", e.loaded_rate[0])
	testing.expect(t, !os.exists(e.take_path), "raw take should be removed after a split")

	// The WAVs on disk must contain the same deinterleaved data.
	wav, ok := wav_read(fmt.tprintf("%s/track3.wav", e.session_dir))
	testing.expect(t, ok, "track3.wav unreadable")
	if ok {
		testing.expectf(t, wav.frames == frames && wav.channels == 1, "track3 shape")
		testing.expectf(t, wav.samples[2] == 21, "track3 sample %v", wav.samples[2])
		wav_destroy(&wav)
	}
}

@(test)
engine_split_take_rejects_empty_partial_and_malformed_raw :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-fx-engine-split-bad"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	e := Engine{}
	e.session_dir = fmt.aprintf("%s", dir)
	e.take_path = fmt.aprintf("%s/take.raw", dir)
	defer {
		delete(e.session_dir)
		delete(e.take_path)
	}
	e.rec.armed[0] = true
	e.rec.inputs[0] = 1
	e.rec.rate = 48_000

	// No data at all.
	testing.expect(t, os.write_entire_file(e.take_path, "") == nil)
	testing.expect(t, !engine_split_take(&e, nil), "empty take accepted")

	// Channels/rate are the frame layout; without them the file is unusable.
	testing.expect(t, engine_test_write_raw(e.take_path, 2, 2), "write raw")
	e.rec.channels = 0
	testing.expect(t, !engine_split_take(&e, nil), "zero channels accepted")
	e.rec.channels = 2
	e.rec.rate = 0
	testing.expect(t, !engine_split_take(&e, nil), "zero rate accepted")
	e.rec.rate = 48_000

	// One whole frame plus three bytes: the partial frame is dropped, not read
	// out of bounds.
	data, err := os.read_entire_file(e.take_path, context.allocator)
	testing.expect(t, err == nil, "read raw")
	if err == nil {
		defer delete(data)
		partial := make([]byte, len(data) + 3)
		defer delete(partial)
		copy(partial, data)
		testing.expect(t, os.write_entire_file(e.take_path, partial) == nil)
		testing.expect(t, engine_split_take(&e, nil), "partial take rejected")
		testing.expectf(t, len(e.loaded[0]) == 2, "partial frames %d", len(e.loaded[0]))
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		delete(e.loaded[i])
	}
}

// ---------------------------------------------------------------- state

@(test)
engine_record_start_requires_an_armed_track :: proc(t: ^testing.T) {
	e: Engine
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e.sample_rate = 48_000

	testing.expect(t, !engine_record_start(&e, &a), "record started with no armed tracks")
	testing.expect(t, !e.rec.active, "recorder became active")
	testing.expect(t, !e.rec.ctx_open && !e.rec.device_open, "hardware was opened")
}

@(test)
engine_record_stop_is_idempotent_before_start :: proc(t: ^testing.T) {
	e: Engine
	testing.expect(t, !engine_record_stop(&e, nil), "stop reported a take")
	testing.expect(t, !engine_record_stop(&e, nil), "second stop reported a take")
	testing.expect(t, !e.rec.active, "inactive recorder")
}

@(test)
engine_load_tracks_clears_stale_audio_on_bad_files :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-fx-engine-load"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	good := "/tmp/tracker-fx-engine-load/track1.wav"
	bad := "/tmp/tracker-fx-engine-load/track2.wav"
	tone: [8]f32
	for i in 0 ..< len(tone) {
		tone[i] = f32(i) * 0.1
	}
	testing.expect(t, wav_write(good, 48_000, 1, tone[:]), "write good track")
	testing.expect(t, os.write_entire_file(bad, "not a wave file") == nil, "write bad track")

	e := Engine{}
	defer {
		for i in 0 ..< MAX_ENGINE_TRACKS {
			delete(e.loaded[i])
		}
		engine_takes_clear(&e)
		delete(e.session_dir)
	}
	e.session_dir = fmt.aprintf("%s", dir)
	e.loaded[1] = make([]f32, 4)
	e.loaded_rate[1] = 48_000

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.tracks[1].has_audio = true

	testing.expect(t, engine_load_tracks(&e, &a), "load failed")
	testing.expect(t, e.loaded[0] != nil, "good track missing")
	testing.expect(t, e.loaded[1] == nil, "stale track kept")
	testing.expect(t, !a.tracks[1].has_audio, "bad track marked as audio")
}
