package dsp

import "core:math"
import "core:testing"

// Regression tests for issues found in the DSP audit. They are kept in their
// own file so each one documents the failure it pins down.

@(private)
audit_clean_settings :: proc() -> Fx_Settings {
	s := fx_settings_default()
	s.master_comp.enabled = false
	return s
}

@(private)
audit_clean_track :: proc() -> Track_Mix {
	tm := track_mix_default()
	tm.level = 1.0
	tm.comp.enabled = false
	tm.eq.enabled = false
	return tm
}

@(test)
audit_nan_sample_is_silence_for_soft_clip :: proc(t: ^testing.T) {
	nan := f32(math.sqrt(-1.0))
	testing.expectf(t, soft_clip(nan, 0.966) == 0.0, "NaN became %v", soft_clip(nan, 0.966))
	// Infinity is a normal overshoot and still lands on the ceiling.
	inf := f32(3.4e38) * 2.0
	testing.expectf(t, soft_clip(inf, 0.966) == 0.966, "+inf clipped to %v", soft_clip(inf, 0.966))
	testing.expectf(t, soft_clip(-inf, 0.966) == -0.966, "-inf clipped to %v", soft_clip(-inf, 0.966))
}

@(test)
audit_render_short_take_is_not_silent :: proc(t: ^testing.T) {
	n := 64
	src := make([]f32, n)
	defer delete(src)
	for i in 0 ..< n {
		src[i] = 0.5
	}

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	s.tracks[0] = audit_clean_track()

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	gain := math.cos(f32(math.TAU) / 8.0)
	want := 0.5 * gain
	testing.expectf(t, out.frames == n, "frames %v, want %v", out.frames, n)
	testing.expectf(t, abs(out.samples[0] - want) < 1e-4, "first sample %v, want %v", out.samples[0], want)
	last := out.samples[(n - 1) * 2]
	testing.expectf(t, abs(last - want) < 1e-4, "last sample %v, want %v", last, want)
}

@(test)
audit_render_keeps_last_samples_ahead_of_the_limiter :: proc(t: ^testing.T) {
	n := 1_000
	src := make([]f32, n)
	defer delete(src)
	src[n - 1] = 0.5

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	s.tracks[0] = audit_clean_track()

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	last := max(abs(out.samples[(n - 1) * 2]), abs(out.samples[(n - 1) * 2 + 1]))
	testing.expectf(t, last > 0.1, "final impulse lost: %v", last)
}

@(test)
audit_render_short_take_reports_track_compression :: proc(t: ^testing.T) {
	n := 64
	src := make([]f32, n)
	defer delete(src)
	for i in 0 ..< n {
		src[i] = 0.9
	}

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	tm := audit_clean_track()
	tm.comp.enabled = true
	tm.comp.attack_ms = 0.1
	tm.comp.threshold_db = -40.0
	tm.comp.ratio = 20.0
	tm.comp.auto_makeup = false
	s.tracks[0] = tm

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	testing.expectf(t, out.stats.track_gr[0] < -5.0, "short take reported GR %v", out.stats.track_gr[0])
}

@(test)
audit_render_short_take_reports_limiter :: proc(t: ^testing.T) {
	n := 64
	src := make([]f32, n)
	defer delete(src)
	for i in 0 ..< n {
		src[i] = 0.9
	}

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	tm := audit_clean_track()
	tm.level = 1.5
	s.tracks[0] = tm
	s.limiter.ceiling_db = -12.0

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	testing.expectf(t, out.stats.limiter_gr < -1.0, "short take reported limiter GR %v", out.stats.limiter_gr)
}

@(test)
audit_render_limiter_timeline_recovers :: proc(t: ^testing.T) {
	n := int(FS)
	src := make([]f32, n)
	defer delete(src)
	for i in 0 ..< 4_800 {
		src[i] = 2.0
	}

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	s.tracks[0] = audit_clean_track()

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	testing.expectf(t, len(out.stats.limiter_gr_timeline) == 20, "timeline points %v", len(out.stats.limiter_gr_timeline))
	worst: f32 = 0.0
	for v in out.stats.limiter_gr_timeline {
		worst = min(worst, v)
	}
	last := out.stats.limiter_gr_timeline[len(out.stats.limiter_gr_timeline) - 1]
	testing.expectf(t, worst < -2.0, "limiter never engaged: worst %v", worst)
	testing.expectf(t, abs(last) < 0.5, "timeline did not release: last %v (worst %v)", last, worst)
}

@(test)
audit_render_recovers_from_non_finite_samples :: proc(t: ^testing.T) {
	n := 4_800
	src := make([]f32, n)
	defer delete(src)
	for i in 0 ..< n {
		src[i] = 0.2 * math.sin(f32(i) * 0.05)
	}
	src[100] = f32(math.sqrt(-1.0)) // NaN
	src[200] = f32(3.4e38) * 2.0 // +inf

	s := audit_clean_settings()
	s.tracks = make([]Track_Mix, 1)
	defer delete(s.tracks)
	tm := audit_clean_track()
	tm.eq.low_db = 3.0
	s.tracks[0] = tm

	out := render_mix([][]f32{src}, s, FS)
	defer render_destroy(&out)

	testing.expectf(t, out.frames == n, "frames %v, want %v", out.frames, n)
	for i in 0 ..< out.frames {
		l := out.samples[i * 2]
		r := out.samples[i * 2 + 1]
		testing.expectf(
			t,
			!math.is_nan(l) && !math.is_inf(l) && !math.is_nan(r) && !math.is_inf(r),
			"non-finite output at %d: %v %v",
			i,
			l,
			r,
		)
	}
	peak: f32 = 0.0
	for i in out.frames - 2_000 ..< out.frames {
		peak = max(peak, abs(out.samples[i * 2]))
	}
	testing.expectf(t, peak > 0.05 && peak < 0.3, "tail did not recover: peak %v", peak)
}

@(test)
audit_reverb_allpass_buffers_fit_max_size :: proc(t: ^testing.T) {
	for fs in ([5]f32{8_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0}) {
		p := reverb_test_params()
		p.size = 1.0
		r := reverb_new(fs, p)
		scale := reverb_size_scale(r.params) * fs / 48_000.0
		for i in 0 ..< REVERB_AP_COUNT {
			want := max(int(math.round(f32(REVERB_AP_LEN[i]) * scale * REVERB_AP_SCALE)), 2)
			testing.expectf(
				t,
				r.allpasses[i].length == want,
				"ap %d at %v Hz configured %d, want %d",
				i,
				fs,
				r.allpasses[i].length,
				want,
			)
		}
		for i in 0 ..< REVERB_N {
			want := max(int(math.round(f32(REVERB_BASE_LEN[i]) * scale)), 8)
			testing.expectf(
				t,
				r.length[i] == want,
				"line %d at %v Hz configured %d, want %d",
				i,
				fs,
				r.length[i],
				want,
			)
		}
		reverb_destroy(&r)
	}
}
