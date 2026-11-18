package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import ui "ui"

@(test)
project_round_trip_preserves_state :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-roundtrip.json"
	defer os.remove(path)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "night session")
	ui.app_set_device(&a, "Scarlett 4i4")
	a.sample_rate = 44_100
	a.bpm = 92
	a.tracks[0].level = 0.62
	a.tracks[0].pan = -0.4
	a.tracks[0].muted = true
	a.tracks[1].soloed = true
	a.tracks[1].armed = true
	a.tracks[1].send_reverb = 0.33
	a.tracks[1].send_delay = 0.12
	a.tracks[1].eq.low_db = 4.5
	a.tracks[1].eq.mid_hz = 2_200
	a.tracks[1].comp.threshold_db = -24
	a.tracks[1].has_audio = true
	a.master.reverb.enabled = true
	a.master.reverb.decay = 0.71
	a.master.delay.enabled = true
	a.master.delay.time_ms = 410
	a.master.width.enabled = true
	a.master.width.width = 1.4
	a.master.limiter.ceiling_db = -1.0

	testing.expect(t, project_save(&a, path), "save failed")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	testing.expect(t, project_load(&b, "/tmp", path), "load failed")

	testing.expect(t, ui.app_project(&b) == "night session", "project name")
	testing.expect(t, ui.app_device(&b) == "Scarlett 4i4", "device")
	testing.expectf(t, b.sample_rate == 44_100, "rate %d", b.sample_rate)
	testing.expectf(t, b.bpm == 92, "bpm %d", b.bpm)
	testing.expectf(t, abs(b.tracks[0].level - 0.62) < 1e-4, "level %v", b.tracks[0].level)
	testing.expectf(t, abs(b.tracks[0].pan + 0.4) < 1e-4, "pan %v", b.tracks[0].pan)
	testing.expect(t, b.tracks[0].muted, "mute")
	testing.expect(t, b.tracks[1].soloed, "solo")
	testing.expect(t, b.tracks[1].armed, "arm")
	testing.expectf(t, abs(b.tracks[1].send_reverb - 0.33) < 1e-4, "reverb send")
	testing.expectf(t, abs(b.tracks[1].eq.low_db - 4.5) < 1e-4, "eq low")
	testing.expectf(t, abs(b.tracks[1].comp.threshold_db + 24) < 1e-4, "comp threshold")
	testing.expect(t, b.master.reverb.enabled, "reverb enabled")
	testing.expectf(t, abs(b.master.reverb.decay - 0.71) < 1e-4, "reverb decay")
	testing.expectf(t, abs(b.master.delay.time_ms - 410) < 1e-4, "delay time")
	testing.expectf(t, abs(b.master.width.width - 1.4) < 1e-4, "width")
	testing.expectf(t, abs(b.master.limiter.ceiling_db + 1.0) < 1e-4, "ceiling")
}

@(test)
project_minimal_json_gets_defaults :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-minimal.json"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, `{"version":1,"name":"min","extra":{"nested":[1,2,3]},"tracks":[{"futureField":true}]}`) == nil)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	testing.expect(t, project_load(&a, "/tmp", path), "load failed")
	testing.expect(t, ui.app_project(&a) == "min", "name")
	testing.expectf(t, a.sample_rate == 48_000, "default rate %d", a.sample_rate)
	testing.expectf(t, a.bpm == 120, "default bpm %d", a.bpm)
	testing.expectf(t, abs(a.tracks[0].level - 0.8) < 1e-4, "default level %v", a.tracks[0].level)
	testing.expectf(t, a.tracks[0].comp.ratio == 3, "default ratio %v", a.tracks[0].comp.ratio)
}

@(test)
settings_mapping_round_trip :: proc(t: ^testing.T) {
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.tracks[2].level = 1.1
	a.tracks[2].pan = 0.55
	a.tracks[2].eq.high_db = -3.5
	a.tracks[2].comp.enabled = false
	a.master.reverb.enabled = true
	a.master.reverb.size = 0.8
	a.master.delay.feedback = 0.6
	a.master.width.bass_hz = 200
	a.master.limiter.release_ms = 300

	s := settings_from_app(&a)
	defer delete(s.tracks)
	testing.expectf(t, abs(s.tracks[2].level - 1.1) < 1e-4, "level")
	testing.expectf(t, abs(s.tracks[2].pan - 0.55) < 1e-4, "pan")
	testing.expectf(t, abs(s.tracks[2].eq.high_db + 3.5) < 1e-4, "eq")
	testing.expect(t, !s.tracks[2].comp.enabled, "comp")
	testing.expect(t, s.reverb.enabled, "reverb")
	testing.expectf(t, abs(s.delay.feedback - 0.6) < 1e-4, "delay")
	testing.expectf(t, abs(s.width.bass_hz - 200) < 1e-4, "width")
	testing.expectf(t, abs(s.limiter.release_ms - 300) < 1e-4, "limiter")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	app_apply_settings(&b, s)
	testing.expectf(t, abs(b.tracks[2].level - 1.1) < 1e-4, "level back")
	testing.expectf(t, abs(b.master.delay.feedback - 0.6) < 1e-4, "delay back")
}

@(test)
solo_mutes_other_tracks_in_the_mix :: proc(t: ^testing.T) {
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	a.tracks[1].soloed = true
	s := settings_from_app(&a)
	defer delete(s.tracks)
	testing.expect(t, s.tracks[0].muted, "non-soloed track should be muted")
	testing.expect(t, !s.tracks[1].muted, "soloed track should stay audible")
}

// ---------------------------------------------------------------- audit regressions

@(private)
write_test_text :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, text) == nil
}

@(private)
test_path :: proc(dir, name: string) -> string {
	return fmt.tprintf("%s/%s", dir, name)
}

@(test)
project_load_rejects_malformed_documents :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-malformed.json"
	defer os.remove(path)

	bad := []string{
		"",
		"{",
		`{"version":1,"tracks":[`,
		`[]`,
		`{"name":5}`,
		`{"tracks":{}}`,
		`{"bpm":"fast"}`,
		`{"master":5}`,
		`{"tracks":[{"level":"loud"}]}`,
		`{"version":1,"tracks":42}`,
		`{"version":1,"tracks":[{"name":42}]}`,
		`{"version":1,"tracks":null}`,
		`{"version":1,"tracks":[null]}`,
		`{"version":1,"tracks":[{"eq":null}]}`,
		`{"version":1,"master":{"comp":null}}`,
		`{"version":1,"name":null}`,
	}

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	for text, i in bad {
		testing.expectf(t, write_test_text(path, text), "fixture %d write failed", i)
		testing.expectf(t, !project_load(&a, "/tmp", path), "accepted malformed document %d", i)
		testing.expectf(t, ui.app_project(&a) == "untitled", "state changed after failure %d", i)
	}
}

@(test)
project_load_version_rules :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-version.json"
	defer os.remove(path)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	testing.expect(t, write_test_text(path, `{"version":2,"name":"future"}`))
	testing.expect(t, !project_load(&a, "/tmp", path), "future version accepted")
	testing.expect(t, ui.app_project(&a) == "untitled", "future version mutated app")

	testing.expect(t, write_test_text(path, `{"version":-1,"name":"negative"}`))
	testing.expect(t, !project_load(&a, "/tmp", path), "negative version accepted")

	// Version 0 is the legacy/missing-version form and is accepted.
	testing.expect(t, write_test_text(path, `{"version":0,"name":"legacy"}`))
	testing.expect(t, project_load(&a, "/tmp", path), "legacy version rejected")
	testing.expect(t, ui.app_project(&a) == "legacy", "legacy name")
}

@(test)
project_load_handles_track_counts_and_missing_files :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-project-tracks"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	defer os.remove_all(dir)

	path := test_path(dir, "project.json")
	testing.expect(t, write_test_text(path, `{
		"version": 1,
		"name": "many",
		"tracks": [
			{"name": "one", "file": "track1.wav"},
			{"name": "two", "file": "track2.wav"},
			{"name": "three"},
			{"name": "four"},
			{"name": "five"},
			{"name": "six"}
		]
	}`))

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	testing.expect(t, project_load(&a, dir, path), "six-track project rejected")
	testing.expect(t, ui.app_project(&a) == "many", "name")
	testing.expect(t, a.tracks[0].name == "one", "track 1 name")
	testing.expect(t, a.tracks[3].name == "four", "track 4 name")
	testing.expect(t, !a.tracks[0].has_audio, "missing track1.wav should not report audio")
	testing.expect(t, !a.tracks[1].has_audio, "missing track2.wav should not report audio")

	// A plain file inside the session is accepted.
	testing.expect(t, write_test_text(test_path(dir, "track1.wav"), "not really a wav"))
	testing.expect(t, project_load(&a, dir, path), "reload")
	testing.expect(t, a.tracks[0].has_audio, "existing track1.wav should report audio")

	// A directory with the expected name is not a track file.
	testing.expect(t, os.make_directory(test_path(dir, "track2.wav")) == nil)
	testing.expect(t, project_load(&a, dir, path), "reload with directory")
	testing.expect(t, !a.tracks[1].has_audio, "directory named track2.wav accepted as audio")

	// Short arrays leave the remaining tracks at their defaults.
	testing.expect(t, write_test_text(path, `{"version":1,"tracks":[{"name":"only"}]}`))
	testing.expect(t, project_load(&a, dir, path), "short track array rejected")
	testing.expect(t, a.tracks[0].name == "only", "first track")
	testing.expect(t, a.tracks[1].name == "Track 2", "default second track")
	testing.expectf(t, abs(a.tracks[1].level - 0.8) < 1e-4, "default level %v", a.tracks[1].level)
}

@(test)
project_load_rejects_path_traversal_file_names :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-project-traversal"
	outside := "/tmp/tracker-project-outside.wav"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	testing.expect(t, ensure_dir(test_path(dir, "sub")), "sub dir")
	testing.expect(t, write_test_text(outside, "outside"))
	testing.expect(t, write_test_text(test_path(dir, "track1.wav"), "inside"))
	testing.expect(t, write_test_text(test_path(dir, "sub/track1.wav"), "nested"))
	defer {
		os.remove_all(dir)
		os.remove(outside)
	}

	path := test_path(dir, "project.json")
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	cases := []struct {
		file:  string,
		audio: bool,
		load:  bool,
	}{
		{`track1.wav`, true, true},
		{`sub/track1.wav`, true, true},
		{`../tracker-project-outside.wav`, false, true},
		{`sub/../../tracker-project-outside.wav`, false, true},
		{`/tmp/tracker-project-outside.wav`, false, true},
		// An escaped NUL is valid JSON but never a usable local file.
		{`track1.wav\u0000/../x.wav`, false, true},
	}

	for c, i in cases {
		text := strings.concatenate({`{"version":1,"tracks":[{"file":"`, c.file, `"}]}`})
		testing.expectf(t, write_test_text(path, text), "fixture %d", i)
		delete(text)
		testing.expectf(t, project_load(&a, dir, path) == c.load, "load %d", i)
		testing.expectf(t, a.tracks[0].has_audio == c.audio, "file %q has_audio = %v", c.file, a.tracks[0].has_audio)
	}
}

@(test)
project_load_preserves_zero_level_and_partial_nested_params :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-partial.json"
	defer os.remove(path)

	testing.expect(t, write_test_text(path, `{
		"version": 1,
		"tracks": [
			{"level": 0, "eq": {"enabled": false}, "comp": {"enabled": false, "ratio": 2}},
			{"name": "partial eq", "eq": {"midDb": 3}},
			{"name": "partial comp", "comp": {"thresholdDb": -30}},
			{}
		]
	}`))

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	testing.expect(t, project_load(&a, "/tmp", path), "load failed")

	testing.expectf(t, a.tracks[0].level == 0, "level 0 became %v", a.tracks[0].level)
	testing.expect(t, !a.tracks[0].eq.enabled, "eq enabled flag lost")
	testing.expectf(t, abs(a.tracks[0].eq.mid_hz - 1_000) < 1e-4, "eq mid default %v", a.tracks[0].eq.mid_hz)
	testing.expect(t, !a.tracks[0].comp.enabled, "comp enabled flag lost")
	testing.expectf(t, abs(a.tracks[0].comp.ratio - 2) < 1e-4, "comp ratio %v", a.tracks[0].comp.ratio)
	testing.expectf(t, abs(a.tracks[0].comp.threshold_db + 18) < 1e-4, "comp threshold default %v", a.tracks[0].comp.threshold_db)

	testing.expectf(t, abs(a.tracks[1].eq.mid_db - 3) < 1e-4, "partial eq mid %v", a.tracks[1].eq.mid_db)
	testing.expectf(t, abs(a.tracks[1].eq.mid_hz - 1_000) < 1e-4, "partial eq default %v", a.tracks[1].eq.mid_hz)

	testing.expectf(t, abs(a.tracks[2].comp.threshold_db + 30) < 1e-4, "partial comp threshold %v", a.tracks[2].comp.threshold_db)
	testing.expectf(t, abs(a.tracks[2].comp.ratio - 3) < 1e-4, "partial comp default ratio %v", a.tracks[2].comp.ratio)
}

@(test)
project_load_clamps_invalid_ranges :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-ranges.json"
	defer os.remove(path)

	testing.expect(t, write_test_text(path, `{
		"version": 1,
		"sampleRate": 1,
		"bpm": 999,
		"tracks": [{
			"level": 9,
			"pan": -9,
			"input": 0,
			"sendReverb": 5,
			"sendDelay": -5
		}]
	}`))

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	testing.expect(t, project_load(&a, "/tmp", path), "load failed")
	testing.expectf(t, a.sample_rate == 48_000, "sample rate %d", a.sample_rate)
	testing.expectf(t, a.bpm == 240, "bpm %d", a.bpm)
	testing.expectf(t, abs(a.tracks[0].level - 1.5) < 1e-4, "level %v", a.tracks[0].level)
	testing.expectf(t, abs(a.tracks[0].pan + 1) < 1e-4, "pan %v", a.tracks[0].pan)
	testing.expectf(t, a.tracks[0].input == 1, "input %d", a.tracks[0].input)
	testing.expectf(t, abs(a.tracks[0].send_reverb - 1) < 1e-4, "reverb send %v", a.tracks[0].send_reverb)
	testing.expectf(t, a.tracks[0].send_delay == 0, "delay send %v", a.tracks[0].send_delay)

	testing.expect(t, write_test_text(path, `{"version":1,"bpm":-5,"sampleRate":999999}`))
	testing.expect(t, project_load(&a, "/tmp", path), "second load failed")
	testing.expectf(t, a.sample_rate == 48_000, "sample rate fallback %d", a.sample_rate)
	testing.expectf(t, a.bpm == 120, "negative bpm fallback %d", a.bpm)
}

@(test)
project_load_unicode_and_long_names :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-unicode.json"
	defer os.remove(path)

	long, repeat_err := strings.repeat("é", 100)
	testing.expect(t, repeat_err == nil, "cannot build long name")
	defer delete(long)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "café 東京")
	ui.app_set_device(&a, long)
	a.tracks[0].name = long
	testing.expect(t, project_save(&a, path), "save failed")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	testing.expect(t, project_load(&b, "/tmp", path), "load failed")
	testing.expectf(t, ui.app_project(&b) == "café 東京", "project name %q", ui.app_project(&b))
	testing.expectf(t, len(b.tracks[0].name) <= PROJECT_TRACK_NAME_MAX, "track name length %d", len(b.tracks[0].name))
	testing.expectf(t, utf8.valid_string(b.tracks[0].name), "truncated name is not valid UTF-8")
	testing.expectf(t, strings.has_prefix(b.tracks[0].name, "ééé"), "track name prefix lost")
	testing.expectf(t, len(ui.app_device(&b)) <= PROJECT_DEVICE_NAME_MAX, "device name length %d", len(ui.app_device(&b)))
	testing.expectf(t, utf8.valid_string(ui.app_device(&b)), "truncated device name is not valid UTF-8")

	ui.app_set_project(&a, long)
	testing.expect(t, project_save(&a, path), "long project name save failed")
	c: ui.App
	ui.app_init(&c, 1180, 760)
	defer ui.app_destroy(&c)
	testing.expect(t, project_load(&c, "/tmp", path), "long project name load failed")
	testing.expectf(t, len(ui.app_project(&c)) <= PROJECT_NAME_MAX, "project name length %d", len(ui.app_project(&c)))
	testing.expectf(t, utf8.valid_string(ui.app_project(&c)), "truncated project name is not valid UTF-8")
	testing.expectf(t, strings.has_prefix(ui.app_project(&c), "ééé"), "project name prefix lost")
}

@(test)
project_save_is_atomic_and_creates_parents :: proc(t: ^testing.T) {
	base := "/tmp/tracker-project-atomic"
	os.remove_all(base)
	defer os.remove_all(base)

	path := test_path(base, "nested/a b/project.json")
	tmp := fmt.aprintf("%s.tmp.%d", path, os.get_pid())
	defer delete(tmp)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "first")
	testing.expect(t, project_save(&a, path), "save into missing parents failed")
	testing.expect(t, os.exists(path), "project file missing")
	testing.expect(t, !os.exists(tmp), "temporary file left behind")

	ui.app_set_project(&a, "second")
	testing.expect(t, project_save(&a, path), "overwrite failed")
	testing.expect(t, !os.exists(tmp), "temporary file left after overwrite")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	testing.expect(t, project_load(&b, test_path(base, "nested/a b"), path), "saved project not readable")
	testing.expect(t, ui.app_project(&b) == "second", "overwrite was not atomic")

	// A directory target fails cleanly and leaves no sibling temp file.
	dir_target := test_path(base, "target")
	testing.expect(t, os.make_directory(dir_target) == nil)
	testing.expect(t, !project_save(&a, dir_target), "directory target accepted")
	dir_tmp := fmt.aprintf("%s.tmp.%d", dir_target, os.get_pid())
	defer delete(dir_tmp)
	testing.expect(t, !os.exists(dir_tmp), "temporary file left after failure")
	testing.expect(t, os.is_directory(dir_target), "target directory removed")

	testing.expect(t, !project_save(&a, ""), "empty path accepted")
}

@(test)
project_repeated_load_and_save_is_owned :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-project-reload"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	defer os.remove_all(dir)

	path := test_path(dir, "project.json")
	other := test_path(dir, "other.json")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "reload")
	a.tracks[0].name = "custom"
	testing.expect(t, project_save(&a, path), "initial save")

	// Loading into the same app repeatedly must release the previous owned
	// names before installing the new ones (checked by the test runner).
	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	for _ in 0 ..< 4 {
		testing.expect(t, project_load(&b, dir, path), "repeated load")
	}
	testing.expect(t, b.tracks[0].name == "custom", "custom name")
	testing.expect(t, project_save(&b, other), "save after repeated loads")

	c: ui.App
	ui.app_init(&c, 1180, 760)
	defer ui.app_destroy(&c)
	testing.expect(t, project_load(&c, dir, other), "load saved copy")
	testing.expect(t, c.tracks[0].name == "custom", "name after save/load")
}

@(test)
project_failed_load_preserves_previous_state :: proc(t: ^testing.T) {
	path := "/tmp/tracker-project-preserve.json"
	defer os.remove(path)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	ui.app_set_project(&a, "stable")
	a.tracks[0].level = 0.42
	testing.expect(t, project_save(&a, path), "save")

	testing.expect(t, write_test_text(path, `{"version":1,"tracks":[{"level":0.1}`))
	testing.expect(t, !project_load(&a, "/tmp", path), "truncated project accepted")
	testing.expect(t, ui.app_project(&a) == "stable", "name changed after failed load")
	testing.expectf(t, abs(a.tracks[0].level - 0.42) < 1e-4, "level changed after failed load: %v", a.tracks[0].level)
}

@(test)
ui_test_harness_reports_and_cleans_up :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-project-harness"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "harness dir")
	defer os.remove_all(dir)

	pass_path := test_path(dir, "pass.json")
	fail_path := test_path(dir, "fail.json")
	bad_path := test_path(dir, "unknown.json")
	report_path := test_path(dir, "out/report.json")

	testing.expect(t, write_test_text(pass_path, `{"name":"audit","actions":[
		{"type":"assert","path":"bpm","min":120,"max":120,"hasMin":true,"hasMax":true},
		{"type":"assert","path":"level.0","min":0.7,"hasMin":true},
		{"type":"screenshot","name":"audit shot"}
	]}`))
	testing.expect(t, run_ui_test([]string{"--script", pass_path, "--out", test_path(dir, "out")}), "passing script failed")
	testing.expect(t, os.exists(report_path), "report missing")

	testing.expect(t, write_test_text(fail_path, `{"name":"audit","actions":[{"type":"assert","path":"bpm","equals":"999"}]}`))
	testing.expect(t, !run_ui_test([]string{"--script", fail_path, "--out", test_path(dir, "fail-out")}), "failing assert returned success")
	testing.expect(t, os.exists(test_path(dir, "fail-out/report.json")), "failed report missing")

	testing.expect(t, write_test_text(bad_path, `{"name":"audit","actions":[{"type":"dance"}]}`))
	testing.expect(t, !run_ui_test([]string{"--script", bad_path, "--out", test_path(dir, "bad-out")}), "unknown action returned success")

	// An output path that is a regular file is rejected before any actions run.
	file_path := test_path(dir, "not-a-dir")
	testing.expect(t, write_test_text(file_path, "x"))
	testing.expect(t, !run_ui_test([]string{"--script", pass_path, "--out", file_path}), "file output dir accepted")
}

@(test)
cli_flag_validation_and_directory_helpers :: proc(t: ^testing.T) {
	values := []string{"--out", "--seconds", "--pan", "--freq"}
	switches := []string{"--jack"}

	testing.expect(t, validate_flags([]string{"--out=/tmp/a b/tone.wav", "--seconds", "3", "--pan", "-1", "--freq", "440"}, values, switches), "valid forms rejected")
	testing.expect(t, validate_flags([]string{"--out", "/tmp/a b/tone.wav", "--jack"}, values, switches), "path with spaces rejected")
	testing.expect(t, validate_flags([]string{"--out=-1"}, values, switches), "single-dash value rejected")

	testing.expect(t, !validate_flags([]string{"--out"}, values, switches), "missing value accepted")
	testing.expect(t, !validate_flags([]string{"--out", ""}, values, switches), "empty argument value accepted")
	testing.expect(t, !validate_flags([]string{"--out", "--jack"}, values, switches), "flag as value accepted")
	testing.expect(t, !validate_flags([]string{"--out="}, values, switches), "empty value accepted")
	testing.expect(t, !validate_flags([]string{"--bogus=1"}, values, switches), "unknown flag accepted")
	testing.expect(t, !validate_flags([]string{"--jack=1"}, values, switches), "switch value accepted")
	testing.expect(t, !validate_flags([]string{"stray"}, values, switches), "positional argument accepted")

	if v, ok := flag_value([]string{"--out=/tmp/a b.wav"}, "--out"); testing.expect(t, ok, "= form not found") {
		testing.expect(t, v == "/tmp/a b.wav", "= form value")
	}
	if v, ok := flag_value([]string{"--out", "/tmp/a b.wav"}, "--out"); testing.expect(t, ok, "space form not found") {
		testing.expect(t, v == "/tmp/a b.wav", "space form value")
	}
	_, missing := flag_value([]string{"--out"}, "--out")
	testing.expect(t, !missing, "missing value reported as present")
	testing.expect(t, flag_f32([]string{"--gain=nan"}, "--gain", 1.5) == 1.5, "NaN accepted")

	base := "/tmp/tracker-project-dirs"
	os.remove_all(base)
	defer os.remove_all(base)
	nested := test_path(base, "nested/a b/c")
	testing.expect(t, ensure_dir(nested), "nested directory")
	testing.expect(t, os.is_directory(nested), "nested directory missing")
	testing.expect(t, ensure_dir(nested), "existing directory rejected")
	testing.expect(t, write_test_text(test_path(base, "file"), "x"))
	testing.expect(t, !ensure_dir(test_path(base, "file")), "file accepted as directory")
	testing.expect(t, ensure_parent_dir(test_path(nested, "file.txt")), "parent helper")
}
