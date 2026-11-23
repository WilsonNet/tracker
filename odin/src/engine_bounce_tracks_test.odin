package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import dsp "dsp"
import ui "ui"

@(private = "file")
tone :: proc(frames: int, amp: f32, hz: f32 = 220) -> []f32 {
	out := make([]f32, frames)
	for i in 0 ..< frames {
		out[i] = amp * math.sin(2 * math.PI * hz * f32(i) / 48_000)
	}
	return out
}

@(private = "file")
flat_settings :: proc(count: int) -> dsp.Fx_Settings {
	s := dsp.fx_settings_default()
	s.tracks = make([]dsp.Track_Mix, count)
	for i in 0 ..< count {
		s.tracks[i] = dsp.track_mix_default()
		s.tracks[i].level = 1
		s.tracks[i].eq.enabled = false
		s.tracks[i].comp.enabled = false
	}
	return s
}

@(test)
bounce_tracks_mix_sums_only_marked_sources_without_sends :: proc(t: ^testing.T) {
	a := tone(4800, 0.25)
	b := tone(4800, 0.25, 330)
	c := tone(4800, 0.5, 440)
	defer delete(a)
	defer delete(b)
	defer delete(c)
	audio := [][]f32{a, b, c, nil}
	settings := flat_settings(4)
	defer delete(settings.tracks)
	// a send and a master reverb must not leak into a track bounce
	settings.tracks[0].send_reverb = 1
	settings.reverb.enabled = true
	settings.limiter.enabled = true
	settings.limiter.ceiling_db = -20

	marked := []bool{true, true, false, false}
	mix := bounce_tracks_mix(audio, settings, marked, 48_000)
	defer delete(mix)
	testing.expect(t, mix != nil, "bounce produced audio")
	testing.expectf(t, len(mix) == 4800, "no tail expected, got %d frames", len(mix))
	// centred tracks keep unity: mono == a + b (track c is unmarked, no limiter)
	worst: f32 = 0
	for i in 0 ..< len(mix) {
		worst = max(worst, abs(mix[i] - (a[i] + b[i])))
	}
	testing.expectf(t, worst < 0.01, "marked sum differs by %v", worst)
}

@(test)
bounce_tracks_mix_refuses_empty_sources :: proc(t: ^testing.T) {
	a := tone(480, 0.5)
	defer delete(a)
	audio := [][]f32{a, nil, nil, nil}
	settings := flat_settings(4)
	defer delete(settings.tracks)
	mix := bounce_tracks_mix(audio, settings, []bool{false, true, false, false}, 48_000)
	testing.expect(t, mix == nil, "marked track without audio renders nothing")
}

@(test)
bounce_tracks_label_lists_sources :: proc(t: ^testing.T) {
	testing.expect(t, bounce_tracks_label([]bool{true, false, true, true}, 4) == "Bounce 1+3+4", "label")
}

@(test)
engine_bounce_to_track_writes_new_take_and_keeps_sources :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-bounce-tracks"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)

	src1 := tone(9600, 0.2)
	src2 := tone(9600, 0.2, 330)
	defer delete(src1)
	defer delete(src2)
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 48_000, 1, src1), "wav 1")
	testing.expect(t, wav_write(fmt.tprintf("%s/track2.wav", base), 48_000, 1, src2), "wav 2")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load")
	for i in 0 ..< 2 {
		a.tracks[i].level = 1
		a.tracks[i].eq.enabled = false
		a.tracks[i].comp.enabled = false
	}

	a.marked[0] = true
	a.marked[1] = true
	ok, msg := engine_bounce_to_track(&e, &a, 2)
	testing.expectf(t, ok, "bounce failed: %s", msg)
	testing.expect(t, engine_take_count(&e, 2) == 1, "target has the bounce take")
	testing.expect(t, e.takes[2].takes[0].name == "Bounce 1+2", "take named after sources")
	testing.expect(t, a.tracks[2].has_audio, "target flagged as having audio")
	testing.expect(t, len(e.loaded[2]) == 9600, "target loaded")
	// sources untouched
	testing.expect(t, engine_take_count(&e, 0) == 1 && engine_take_count(&e, 1) == 1, "sources keep their takes")
	wav, wav_ok := wav_read(fmt.tprintf("%s/track3.wav", base))
	defer wav_destroy(&wav)
	testing.expect(t, wav_ok && wav.channels == 1 && wav.frames == 9600, "track3.wav is mono")

	// a second bounce into the same target keeps the first as an earlier take
	ok2, _ := engine_bounce_to_track(&e, &a, 2)
	testing.expect(t, ok2 && engine_take_count(&e, 2) == 2, "previous take is kept")

	// refusals
	bad, bad_msg := engine_bounce_to_track(&e, &a, 0)
	testing.expectf(t, !bad && bad_msg != "", "marked target refused: %s", bad_msg)
	a.marked[0] = false
	a.marked[1] = false
	none, _ := engine_bounce_to_track(&e, &a, 3)
	testing.expect(t, !none, "nothing marked refused")
}

@(test)
engine_save_as_copies_tracks_beyond_four :: proc(t: ^testing.T) {
	base := "/tmp/tracker-save-as-many"
	os.remove_all(base)
	defer os.remove_all(base)
	src_dir := fmt.tprintf("%s/src", base)
	_ = os.make_directory_all(src_dir)
	audio := tone(480, 0.2)
	defer delete(audio)
	testing.expect(t, wav_write(fmt.tprintf("%s/track7.wav", src_dir), 48_000, 1, audio), "track 7 wav")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_track_count(&a, 8)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", src_dir}), "engine")
	defer engine_destroy(&e)

	dst := fmt.tprintf("%s/dst", base)
	testing.expect(t, engine_save_as(&a, &e, dst), "save as")
	testing.expect(t, os.exists(fmt.tprintf("%s/track7.wav", dst)), "track 7 audio copied")
	// a folder holding only track 9 counts as occupied
	other := fmt.tprintf("%s/other", base)
	_ = os.make_directory_all(other)
	testing.expect(t, wav_write(fmt.tprintf("%s/track9.wav", other), 48_000, 1, audio), "track 9 wav")
	testing.expect(t, save_dir_occupied(other), "track 9 makes a folder occupied")
}
