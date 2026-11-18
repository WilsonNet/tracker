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
