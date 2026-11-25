package main

import "core:fmt"
import "core:os"
import "core:testing"

import ui "ui"

@(test)
engine_save_as_and_open_roundtrip :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-paths"
	os.remove_all(base)
	defer os.remove_all(base)
	source_dir := fmt.tprintf("%s/source", base)
	target_dir := fmt.tprintf("%s/target dir", base)
	_ = os.make_directory_all(source_dir)

	samples := make([]f32, 480)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = 0.25 * f32(i % 7) / 7.0
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", source_dir), 48_000, 1, samples), "fixture wav")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "path test")
	a.tracks[0].has_audio = true

	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", source_dir}), "engine init")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load source")

	testing.expect(t, engine_save_as(&a, &e, target_dir), "save as")
	testing.expect(t, os.exists(fmt.tprintf("%s/project.json", target_dir)), "project copied")
	testing.expect(t, os.exists(fmt.tprintf("%s/track1.wav", target_dir)), "take copied")

	// Save-as must not merge into an existing Tracker folder.
	occupied := fmt.tprintf("%s/occupied", base)
	_ = os.make_directory_all(occupied)
	_ = os.write_entire_file(fmt.tprintf("%s/track1.wav", occupied), transmute([]u8)string("OTHER"))
	testing.expect(t, !engine_save_as(&a, &e, occupied), "occupied save-as must be refused")
	marker, _ := os.read_entire_file(fmt.tprintf("%s/track1.wav", occupied), context.allocator)
	defer delete(marker)
	testing.expect(t, string(marker) == "OTHER", "save-as overwrote the destination take")

	// Open the new project from a fresh app/engine.
	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	e2: Engine
	testing.expect(t, engine_init(&e2, []string{"--session", fmt.tprintf("%s/scratch", base)}), "engine2")
	defer engine_destroy(&e2)
	testing.expect(t, engine_open_project(&b, &e2, fmt.tprintf("%s/project.json", target_dir)), "open project")
	testing.expect(t, ui.app_project(&b) == "path test", "project name")
	testing.expect(t, b.tracks[0].has_audio, "take restored")
	testing.expect(t, e2.loaded[0] != nil, "engine loaded take")
	testing.expectf(t, engine_take_count(&e2, 0) >= 1, "take count %d", engine_take_count(&e2, 0))
}

@(test)
engine_load_tracks_adopts_project_rate :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-project-rate"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)
	samples := make([]f32, 441)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = 0.1
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 44_100, 1, samples))

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.sample_rate = 44_100
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}))
	defer engine_destroy(&e)
	testing.expect(t, e.sample_rate == 48_000, "engine starts at the default rate")
	testing.expect(t, engine_load_tracks(&e, &a), "load takes")
	testing.expect(t, e.sample_rate == 44_100, "engine adopted the project rate")
	testing.expect(t, e.loaded_rate[0] == 44_100, "take kept its native rate")
}

@(test)
engine_apply_save_dir_copies_takes_and_retargets :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-apply-dir"
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)
	source_dir := fmt.tprintf("%s/source", base)
	target_dir := fmt.tprintf("%s/target", base)
	_ = os.make_directory_all(source_dir)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.tracks[0].has_audio = true

	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", source_dir}), "engine init")
	defer engine_destroy(&e)

	samples := make([]f32, 480)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = 0.1
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", source_dir), 48_000, 1, samples), "fixture wav")

	testing.expect(t, engine_apply_save_dir(&a, &e, target_dir), "apply save dir")
	testing.expectf(t, e.session_dir == target_dir, "session dir %s", e.session_dir)
	testing.expect(t, os.exists(fmt.tprintf("%s/project.json", target_dir)), "project written")
	testing.expect(t, os.exists(fmt.tprintf("%s/track1.wav", target_dir)), "take copied")
	testing.expect(t, ui.app_status(&a) == "project folder updated", ui.app_status(&a))
	testing.expect(t, os.exists(fmt.tprintf("%s/track1.wav", source_dir)), "source kept")
}

@(test)
engine_init_rejects_a_file_session_path :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-session-file"
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)
	_ = os.make_directory_all(base)
	path := fmt.tprintf("%s/not-a-dir", base)
	testing.expect(t, os.write_entire_file(path, "x") == nil, "fixture")

	e: Engine
	testing.expect(t, !engine_init(&e, []string{"--session", path}), "file session must be rejected")
	testing.expect(t, e.session_dir == "", "no leaked session path")
}

@(test)
engine_apply_save_dir_refuses_occupied_folder :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-occupied"
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)
	source_dir := fmt.tprintf("%s/source", base)
	occupied := fmt.tprintf("%s/occupied", base)
	_ = os.make_directory_all(source_dir)
	_ = os.make_directory_all(occupied)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/project.json", occupied), "{}") == nil, "fixture")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", source_dir}), "engine init")
	defer engine_destroy(&e)

	testing.expect(t, !engine_apply_save_dir(&a, &e, occupied), "occupied folder must be refused")
	testing.expectf(t, e.session_dir == source_dir, "session moved to %s", e.session_dir)
	testing.expect(t, ui.app_status(&a) == "folder already contains a tracker project", ui.app_status(&a))
}

@(test)
engine_retarget_rejects_transport :: proc(t: ^testing.T) {
	e: Engine
	e.session_dir = fmt.aprintf("/tmp/old")
	e.project_path = fmt.aprintf("/tmp/old/project.json")
	e.take_path = fmt.aprintf("/tmp/old/take.raw")
	e.bounce_path = fmt.aprintf("/tmp/old/bounce.wav")
	e.rec.active = true
	testing.expect(t, !engine_retarget(&e, "/tmp/new", "/tmp/new/project.json"), "retarget during record")
	e.rec.active = false
	delete(e.session_dir)
	delete(e.project_path)
	delete(e.take_path)
	delete(e.bounce_path)
}

@(test)
project_folder_slug_and_unique_dir :: proc(t: ^testing.T) {
	s1 := project_folder_slug("Midnight Riff #2")
	defer delete(s1)
	testing.expect_value(t, s1, "midnight-riff-2")

	s2 := project_folder_slug("../..//..")
	defer delete(s2)
	testing.expect_value(t, s2, "untitled")

	s3 := project_folder_slug("   ")
	defer delete(s3)
	testing.expect_value(t, s3, "untitled")

	base := "/tmp/tracker-unique-dir"
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)
	_ = os.make_directory_all(base)

	d1 := engine_unique_project_dir(base, "demo")
	defer delete(d1)
	testing.expect_value(t, d1, fmt.tprintf("%s/demo", base))
	_ = os.make_directory_all(d1)

	d2 := engine_unique_project_dir(base, "demo")
	defer delete(d2)
	testing.expect_value(t, d2, fmt.tprintf("%s/demo-2", base))
	_ = os.make_directory_all(d2)

	d3 := engine_unique_project_dir(base, "demo")
	defer delete(d3)
	testing.expect_value(t, d3, fmt.tprintf("%s/demo-3", base))
}

@(test)
engine_new_project_resets_audio_and_keeps_machine_prefs :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-new-project"
	_ = os.remove_all(base)
	defer _ = os.remove_all(base)
	first_dir := fmt.tprintf("%s/old-song", base)
	_ = os.make_directory_all(first_dir)

	samples := make([]f32, 256)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = 0.25
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", first_dir), 48_000, 1, samples), "seed wav")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	names := [?]string{"Scarlett 4i4 USB"}
	ui.app_set_devices(&a, names[:], 0)
	ui.app_set_project(&a, "Old Song")
	ui.app_set_track_count(&a, 6)
	a.bpm = 142
	a.tracks[0].has_audio = true
	a.tracks[0].armed = true
	a.tracks[0].muted = true
	a.tracks[0].level = 1.2
	a.master.reverb.enabled = true
	a.marker = 48_000
	a.marker_set = true
	a.high_contrast = true
	a.latency_ms = 12
	a.timing_mode = .Free
	a.dirty = true

	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", first_dir}), "engine init")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load first project")

	// Transport running must refuse.
	e.play.active = true
	ok_play, _ := engine_new_project(&a, &e, "Blocked")
	testing.expect(t, !ok_play, "refuse while playing")
	e.play.active = false

	ok, msg := engine_new_project(&a, &e, "Midnight Riff")
	testing.expectf(t, ok, "new project failed: %s", msg)

	expected_dir := fmt.tprintf("%s/midnight-riff", base)
	testing.expect_value(t, e.session_dir, expected_dir)
	testing.expect(t, os.exists(fmt.tprintf("%s/project.json", expected_dir)), "new project.json written")
	testing.expect(t, !os.exists(fmt.tprintf("%s/track1.wav", expected_dir)), "new project folder has no WAVs")
	testing.expect(t, os.exists(fmt.tprintf("%s/project.json", first_dir)), "old project saved")
	testing.expect(t, os.exists(fmt.tprintf("%s/track1.wav", first_dir)), "old WAV untouched")

	// Project state reset cleanly.
	testing.expect_value(t, ui.app_project(&a), "Midnight Riff")
	testing.expect_value(t, a.track_count, 4)
	testing.expect_value(t, a.bpm, 120)
	testing.expect(t, !a.marker_set && !a.master.reverb.enabled && a.master.limiter.enabled, "marker and master FX reset")
	testing.expect(t, a.mode == .Normal, "back to mixer")
	for i in 0 ..< ui.MAX_TRACKS {
		testing.expect(t, e.loaded[i] == nil && engine_take_count(&e, i) == 0, "engine audio/takes cleared")
		testing.expect(t, !a.tracks[i].has_audio && !a.tracks[i].armed && !a.tracks[i].muted && a.tracks[i].level == 0.8, "ui track reset")
	}

	// Machine preferences preserved.
	testing.expect(t, a.high_contrast && a.latency_ms == 12 && a.timing_mode == .Free, "machine settings preserved")
	testing.expect_value(t, ui.app_device(&a), "Scarlett 4i4 USB")

	// Creating another project with the same name allocates -2 cleanly.
	ok2, _ := engine_new_project(&a, &e, "Midnight Riff")
	testing.expect(t, ok2, "second project with same name")
	testing.expect_value(t, e.session_dir, fmt.tprintf("%s/midnight-riff-2", base))
}
