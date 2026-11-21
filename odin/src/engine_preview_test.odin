package main

import "core:sync"
import "core:testing"

import ui "ui"

// ---------------------------------------------------------------- preview

@(test)
preview_push_publishes_decayed_block_peaks :: proc(t: ^testing.T) {
	p := Preview{channels = 2}
	src := [4]f32{0.5, -0.25, 0.1, 0.8}
	preview_push(&p, src[:], 2)
	testing.expectf(t, abs(sync.atomic_load(&p.peak[0]) - 0.47) < 0.001, "ch0 %v", sync.atomic_load(&p.peak[0]))
	testing.expectf(t, abs(sync.atomic_load(&p.peak[1]) - 0.752) < 0.001, "ch1 %v", sync.atomic_load(&p.peak[1]))

	// A silent block decays the envelope instead of holding the old peak.
	zero := [2]f32{0, 0}
	preview_push(&p, zero[:], 1)
	testing.expectf(t, sync.atomic_load(&p.peak[0]) < 0.47, "ch0 did not decay: %v", sync.atomic_load(&p.peak[0]))
	testing.expectf(t, sync.atomic_load(&p.peak[1]) < 0.752, "ch1 did not decay: %v", sync.atomic_load(&p.peak[1]))
}

@(test)
preview_runs_only_for_armed_idle_miniaudio :: proc(t: ^testing.T) {
	e := Engine{}
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	testing.expect(t, !preview_wanted(&e, &a), "preview started with no armed track")
	a.tracks[1].armed = true
	testing.expect(t, preview_wanted(&e, &a), "armed idle track should preview")

	a.transport = .Playing
	testing.expect(t, !preview_wanted(&e, &a), "preview during playback")
	a.transport = .Stopped

	a.demo = true
	testing.expect(t, !preview_wanted(&e, &a), "demo mode has synthetic meters")
	a.demo = false

	e.backend = .Jack
	testing.expect(t, !preview_wanted(&e, &a), "JACK uses the take session")
	e.backend = .Miniaudio

	e.rec.active = true
	testing.expect(t, !preview_wanted(&e, &a), "preview during recording")
	e.rec.active = false

	e.play.active = true
	testing.expect(t, !preview_wanted(&e, &a), "preview during engine playback")
}

@(test)
preview_signature_tracks_arm_and_input_changes :: proc(t: ^testing.T) {
	e := Engine{}
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	before := preview_signature(&e, &a)
	a.tracks[0].armed = true
	armed := preview_signature(&e, &a)
	testing.expectf(t, armed != before, "arm did not change signature")

	a.tracks[0].input = 3
	remapped := preview_signature(&e, &a)
	testing.expectf(t, remapped != armed, "input did not change signature")

	e.device_index = 2
	device := preview_signature(&e, &a)
	testing.expectf(t, device != remapped, "device did not change signature")
}
