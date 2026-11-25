package main

import "core:math"
import "core:sync"
import "core:testing"

import dsp "dsp"
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

	a.tempo_listen = true
	listen := preview_signature(&e, &a)
	testing.expectf(t, listen != device, "tempo_listen did not change signature")
}

@(test)
preview_runs_tempo_listen_and_respects_headless_and_masks :: proc(t: ^testing.T) {
	e := Engine{}
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	a.tempo_listen = true
	testing.expect(t, preview_wanted(&e, &a), "tempo listen wants preview even with no armed tracks")

	e.headless_window = true
	testing.expect(t, !preview_wanted(&e, &a), "headless window disables live audio preview for tempo listen")
	a.tracks[0].armed = true
	testing.expect(t, preview_wanted(&e, &a), "armed track still wants preview")

	// Channel mask maps armed tracks when armed, or 0 (all channels) when none armed.
	testing.expect(t, preview_tempo_channel_mask(&a, 4) == (1 << 0), "track 0 input 1 -> ch0 mask")
	a.tracks[0].armed = false
	testing.expect(t, preview_tempo_channel_mask(&a, 4) == 0, "unarmed -> 0 mask (all channels)")

	// Feed 4 claps at 120 BPM through preview_push -> publishes hit_count == 4 and bpm == 120.
	p := Preview{channels = 2, rate = 48_000}
	dsp.tempo_detector_init(&p.tempo_detector, 48_000, .Med)
	sync.atomic_store(&p.tempo_enabled, 1)
	sync.atomic_store(&p.tempo_sensitivity, u32(dsp.Tempo_Sensitivity.Med))
	sync.atomic_store(&p.tempo_chan_mask, 0)

	total_frames := 48_000 * 3
	stereo := make([]f32, total_frames * 2)
	defer delete(stereo)
	seed: u32 = 0x1357_2468
	for b in 0 ..< 4 {
		start := int(f64(b) * 0.500 * 48_000.0) + 2_400
		for i in 0 ..< 720 {
			idx := start + i
			if idx >= total_frames {
				break
			}
			seed = seed * 1_664_525 + 1_013_904_223
			noise := (f32(seed >> 8) / 8_388_608.0) - 1.0
			stereo[idx * 2] = 0.85 * math.exp(-f32(i) / 192.0) * noise
		}
	}
	for off := 0; off < total_frames; off += 1024 {
		n := min(1024, total_frames - off)
		preview_push(&p, stereo[off * 2:(off + n) * 2], n)
	}
	testing.expectf(t, sync.atomic_load(&p.tempo_hit_count) == 4, "expected 4 preview hits, got %d", sync.atomic_load(&p.tempo_hit_count))
	testing.expectf(t, sync.atomic_load(&p.tempo_bpm) == 120, "expected 120 preview BPM, got %d", sync.atomic_load(&p.tempo_bpm))
}
