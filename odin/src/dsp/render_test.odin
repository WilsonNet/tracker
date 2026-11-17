package dsp

import "core:math"
import "core:testing"

@(test)
render_centre_pan_is_constant_power :: proc(t: ^testing.T) {
	n := 480
	track := make([]f32, n)
	defer delete(track)
	for i in 0 ..< n {
		track[i] = 0.5
	}

	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 1)
	defer delete(settings.tracks)
	track_mix := track_mix_default()
	track_mix.level = 1.0
	track_mix.comp.enabled = false
	track_mix.eq = eq_params_default()
	settings.tracks[0] = track_mix
	settings.limiter.enabled = false
	settings.master_comp.enabled = false

	out := render_mix([][]f32{track}, settings, FS)
	defer render_destroy(&out)

	testing.expectf(t, out.frames == n, "frames %v", out.frames)
	expected := f32(0.5) * math.cos(f32(math.TAU) / 8.0)
	for i in 0 ..< n {
		testing.expectf(t, abs(out.samples[i * 2] - expected) < 1e-5, "left %v", out.samples[i * 2])
		testing.expectf(t, abs(out.samples[i * 2 + 1] - expected) < 1e-5, "right %v", out.samples[i * 2 + 1])
	}
}

@(test)
render_hard_left_pan_zeros_right :: proc(t: ^testing.T) {
	n := 100
	track := make([]f32, n)
	defer delete(track)
	for i in 0 ..< n {
		track[i] = 1.0
	}
	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 1)
	defer delete(settings.tracks)
	tm := track_mix_default()
	tm.level = 1.0
	tm.pan = -1.0
	tm.comp.enabled = false
	settings.tracks[0] = tm
	settings.limiter.enabled = false

	out := render_mix([][]f32{track}, settings, FS)
	defer render_destroy(&out)
	for i in 0 ..< n {
		testing.expectf(t, abs(out.samples[i * 2] - 1.0) < 1e-5, "left %v", out.samples[i * 2])
		testing.expectf(t, abs(out.samples[i * 2 + 1]) < 1e-6, "right %v", out.samples[i * 2 + 1])
	}
}

@(test)
render_muted_track_is_silent :: proc(t: ^testing.T) {
	n := 100
	track := make([]f32, n)
	defer delete(track)
	for i in 0 ..< n {
		track[i] = 0.8
	}
	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 1)
	defer delete(settings.tracks)
	tm := track_mix_default()
	tm.muted = true
	tm.comp.enabled = false
	settings.tracks[0] = tm

	out := render_mix([][]f32{track}, settings, FS)
	defer render_destroy(&out)
	peak, _ := peak_rms_db(out.samples, 2)
	testing.expectf(t, peak <= -120.0, "muted track peak %v", peak)
}

@(test)
render_limiter_caps_hot_mix :: proc(t: ^testing.T) {
	n := 48_000
	track := make([]f32, n)
	defer delete(track)
	for i in 0 ..< n {
		track[i] = 2.0 * math.sin(f32(i) * 220.0 / FS * f32(math.TAU))
	}
	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 1)
	defer delete(settings.tracks)
	tm := track_mix_default()
	tm.level = 1.5
	tm.comp.enabled = false
	settings.tracks[0] = tm

	out := render_mix([][]f32{track}, settings, FS)
	defer render_destroy(&out)
	ceiling := db_to_lin(settings.limiter.ceiling_db)
	testing.expectf(t, out.peak_db <= lin_to_db(ceiling) + 0.01, "peak %v dB", out.peak_db)
	testing.expectf(t, out.stats.limiter_gr < -1.0, "limiter GR %v", out.stats.limiter_gr)
}

@(test)
render_preserves_length_and_stereo_shape :: proc(t: ^testing.T) {
	n := 1_000
	tracks := make([][]f32, 2)
	defer delete(tracks)
	for i in 0 ..< 2 {
		tracks[i] = make([]f32, n)
		defer delete(tracks[i])
		for j in 0 ..< n {
			tracks[i][j] = 0.1 * f32(i + 1)
		}
	}
	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 2)
	defer delete(settings.tracks)
	for i in 0 ..< 2 {
		tm := track_mix_default()
		tm.muted = true // keep the assertion about shape, not level
		settings.tracks[i] = tm
	}
	out := render_mix(tracks, settings, FS)
	defer render_destroy(&out)
	testing.expectf(t, len(out.samples) == n * 2, "sample count %v", len(out.samples))
	testing.expectf(t, len(out.stats.track_gr_timeline) == 2, "missing timeline")
}
