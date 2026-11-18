package main

import "core:os"
import "core:testing"

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
	testing.expect(t, os.write_entire_file(path, `{"version":1,"name":"min","tracks":[{}]}`) == nil)

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
