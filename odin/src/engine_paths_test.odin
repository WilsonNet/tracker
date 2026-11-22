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
