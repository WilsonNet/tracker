package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
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
engine_bounce_all_fills_dedicated_track_without_stacking :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-bounce-all"
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

	testing.expect(t, ui.app_bounce_track_index(&a) == -1, "no bounce track yet")
	testing.expect(t, engine_bounce_all(&e, &a), "first bounce")
	testing.expect(t, a.track_count == 5, "BOUNCE track added")
	testing.expect(t, ui.app_bounce_track_index(&a) == 4 && a.tracks[4].name == "BOUNCE", "named BOUNCE")
	testing.expect(t, a.tracks[4].has_audio && a.selected == 4, "flagged and selected")
	testing.expect(t, engine_take_count(&e, 4) == 1 && e.takes[4].takes[0].name == "Bounce mix", "take")
	testing.expect(t, len(e.loaded[4]) >= 9600, "mix loaded (tail may extend it)")
	testing.expect(t, engine_take_count(&e, 0) == 1 && engine_take_count(&e, 1) == 1, "sources untouched")
	testing.expect(t, os.exists(e.bounce_path), "bounce.wav still written")
	peak1: f32
	for v in e.loaded[4] {
		peak1 = max(peak1, abs(v))
	}
	testing.expect(t, peak1 > 0.01, "bounce is not silent")

	// again: reuses the track, keeps the old take, and does not sum itself in
	testing.expect(t, engine_bounce_all(&e, &a), "second bounce")
	testing.expect(t, a.track_count == 5 && engine_take_count(&e, 4) == 2, "same track, two takes")
	peak2: f32
	for v in e.loaded[4] {
		peak2 = max(peak2, abs(v))
	}
	testing.expectf(t, abs(peak2 - peak1) < 0.001, "no stacking: %f vs %f", peak1, peak2)

	// nothing but the BOUNCE track has audio: refused
	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	e2: Engine
	base2 := "/tmp/tracker-engine-bounce-all-empty"
	os.remove_all(base2)
	defer os.remove_all(base2)
	_ = os.make_directory_all(base2)
	testing.expect(t, engine_init(&e2, []string{"--session", base2}), "engine 2")
	defer engine_destroy(&e2)
	_ = engine_load_tracks(&e2, &b) // nothing recorded: reports false
	testing.expect(t, !engine_bounce_all(&e2, &b) && b.track_count == 4, "empty project: no bounce, no track added")
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

@(test)
engine_punch_in_keeps_audio_before_and_after_the_punch :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-punch"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)

	old := make([]f32, 4800) // 0.1 s of 0.25
	defer delete(old)
	for i in 0 ..< len(old) {
		old[i] = 0.25
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 48_000, 1, old), "old take")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load")
	testing.expect(t, len(e.loaded[0]) == 4800, "old audio loaded")

	// punch in at frame 1200 with 1200 frames of -0.5
	nw := make([]f32, 1200)
	for i in 0 ..< len(nw) {
		nw[i] = -0.5
	}
	e.rec_punch = 1200
	e.rec_pre = 0
	testing.expect(t, engine_commit_recorded_take(&e, &a, 0, 48_000, nw), "commit punch")
	testing.expect(t, engine_take_count(&e, 0) == 2, "old take kept, punch take added")
	testing.expect(t, len(e.takes[0].comp) == 3, "comp: before / punch / after")
	testing.expectf(t, len(e.loaded[0]) == 4800, "length unchanged, got %d", len(e.loaded[0]))
	if len(e.loaded[0]) == 4800 {
		testing.expect(t, abs(e.loaded[0][600] - 0.25) < 1e-4, "before the punch: old audio")
		testing.expect(t, abs(e.loaded[0][1800] + 0.5) < 1e-4, "inside the punch: new audio")
		testing.expect(t, abs(e.loaded[0][3600] - 0.25) < 1e-4, "after the punch: old audio")
	}
	testing.expect(t, e.takes[0].takes[1].offset == 1200, "punch take remembers its timeline offset")

	// the project round-trips: reload from disk and the comp still renders
	a2: ui.App
	ui.app_init(&a2, 1180, 760)
	defer ui.app_destroy(&a2)
	testing.expect(t, project_save_with_takes(&a, e.takes[:], e.project_path), "save")
	e2: Engine
	testing.expect(t, engine_init(&e2, []string{"--session", base}), "engine 2")
	defer engine_destroy(&e2)
	testing.expect(t, project_load_with_takes(&a2, base, e2.project_path, e2.takes[:]), "load project")
	testing.expect(t, engine_load_tracks(&e2, &a2), "load tracks")
	testing.expect(t, len(e2.loaded[0]) == 4800 && abs(e2.loaded[0][1800] + 0.5) < 1e-4, "reloaded punch comp")

	// punch 0 keeps the classic behaviour: the new take simply replaces the track
	nw2 := make([]f32, 1000)
	for i in 0 ..< len(nw2) {
		nw2[i] = 0.1
	}
	e.rec_punch = 0
	testing.expect(t, engine_commit_recorded_take(&e, &a, 0, 48_000, nw2), "commit from zero")
	testing.expect(t, len(e.loaded[0]) == 1000, "plain take loaded as before")
}

@(test)
project_and_settings_persist_marker_and_preroll :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-marker-preroll"
	os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)
	path := fmt.tprintf("%s/project.json", dir)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.frames = 48_000 * 12
	ui.app_execute(&a, .Set_Marker)
	testing.expect(t, project_save(&a, path), "save")
	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	testing.expect(t, project_load(&b, dir, path), "load")
	testing.expect(t, b.marker_set && b.marker == 48_000 * 12, "marker survives save/load")

	// a project without a marker loads without one
	ui.app_execute(&a, .Clear_Marker)
	testing.expect(t, project_save(&a, path), "save without marker")
	testing.expect(t, project_load(&b, dir, path), "load without marker")
	testing.expect(t, !b.marker_set, "no marker")

	spath := fmt.tprintf("%s/settings.json", dir)
	testing.expect(t, settings_save(spath, "/tmp/x", false, false, 5, 3, "free"), "settings save")
	doc, ok := settings_load(spath)
	defer settings_destroy(&doc)
	testing.expect(t, ok && doc.preroll_s == 5 && doc.preroll_grid == 3 && doc.timing_mode == "free", "pre-roll and timing persist in settings.json")
	// an old settings file without the key keeps the 3 s / 1 BAR defaults
	testing.expect(t, os.write_entire_file(spath, `{"version":1,"highContrast":true}`) == nil, "old file")
	old, old_ok := settings_load(spath)
	defer settings_destroy(&old)
	testing.expect(t, old_ok && old.preroll_s == 3 && old.preroll_grid == 2 && old.timing_mode == "", "defaults for older settings files")
}

@(test)
engine_delete_track_shifts_later_tracks_and_keeps_files :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-delete-track"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)
	for n in 1 ..= 5 {
		audio := tone(4800 + n * 100, 0.2, f32(200 + n * 50))
		defer delete(audio)
		testing.expect(t, wav_write(fmt.tprintf("%s/track%d.wav", base, n), 48_000, 1, audio), "wav")
	}

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load")
	ui.app_set_track_count(&a, 5)
	a.tracks[1].name = "Keep"
	len4 := len(e.loaded[3])

	ok, msg := engine_delete_track(&e, &a, 1) // delete track 2
	testing.expectf(t, ok, "delete: %s", msg)
	testing.expect(t, a.track_count == 4, "one strip fewer")
	testing.expect(t, len(e.loaded[2]) == len4, "track 4 audio now sits in slot 3")
	testing.expect(t, e.loaded[4] == nil, "last slot vacated")
	// files: 2 moved aside, 3->2, 4->3, 5->4, no track5
	testing.expect(t, os.exists(fmt.tprintf("%s/deleted/track2.wav", base)), "deleted audio kept in deleted/")
	testing.expect(t, !os.exists(fmt.tprintf("%s/track5.wav", base)), "track5.wav renamed away")
	wav, wav_ok := wav_read(fmt.tprintf("%s/track3.wav", base))
	defer wav_destroy(&wav)
	testing.expect(t, wav_ok && wav.frames == len4, "track3.wav is the old track 4")
	testing.expect(t, engine_take_count(&e, 2) == 1 && e.takes[2].takes[0].file == "track3.wav", "take list renumbered")

	// at the four-track minimum the strip stays and is cleared
	ok2, _ := engine_delete_track(&e, &a, 0)
	testing.expect(t, ok2 && a.track_count == 4 && e.loaded[0] == nil && os.exists(fmt.tprintf("%s/deleted/track1.wav", base)), "cleared in place, file kept")

	// an empty track: plain message, nothing moved aside
	a2: ui.App
	ui.app_init(&a2, 1180, 760)
	defer ui.app_destroy(&a2)
	ui.app_set_track_count(&a2, 5)
	e3: Engine
	base3 := "/tmp/tracker-engine-delete-empty"
	os.remove_all(base3)
	defer os.remove_all(base3)
	_ = os.make_directory_all(base3)
	testing.expect(t, engine_init(&e3, []string{"--session", base3}), "engine 3")
	defer engine_destroy(&e3)
	ok3, msg3 := engine_delete_track(&e3, &a2, 4)
	testing.expectf(t, ok3 && !strings.contains(msg3, "deleted/"), "empty delete message: %s", msg3)
	testing.expect(t, !os.exists(fmt.tprintf("%s/deleted", base3)), "no deleted/ folder for an empty track")
}
