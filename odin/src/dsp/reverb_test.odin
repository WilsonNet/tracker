package dsp

import "core:math"
import "core:testing"

@(private)
reverb_test_params :: proc() -> Reverb_Params {
	p := reverb_params_default()
	p.enabled = true
	p.return_level = 1.0
	return p
}

// Sum of squared stereo output in a sample window for an impulse input.
@(private)
reverb_test_window_energy :: proc(params: Reverb_Params, start, end: int) -> f32 {
	r := reverb_new(FS, params)
	defer reverb_destroy(&r)
	energy: f32 = 0.0
	for i in 0 ..< end {
		x := f32(1.0) if i == 0 else 0.0
		l, rr := reverb_process(&r, x, x)
		if i >= start {
			energy += l * l + rr * rr
		}
	}
	return energy
}

@(test)
reverb_impulse_produces_a_decaying_tail :: proc(t: ^testing.T) {
	r := reverb_new(FS, reverb_test_params())
	defer reverb_destroy(&r)

	early: f32 = 0.0
	late: f32 = 0.0
	for i in 0 ..< 96_000 {
		x := f32(1.0) if i == 0 else 0.0
		l, rr := reverb_process(&r, x, x)
		e := l * l + rr * rr
		if i >= 1_000 && i < 20_000 {
			early += e
		}
		if i >= 60_000 && i < 80_000 {
			late += e
		}
		testing.expectf(t, !math.is_nan(l) && !math.is_inf(l) && !math.is_nan(rr) && !math.is_inf(rr), "non-finite output at %d", i)
	}
	testing.expectf(t, early > 0.0, "no tail")
	testing.expectf(t, late < early, "tail is not decaying: early %v late %v", early, late)
}

@(test)
reverb_disabled_is_silent_and_free :: proc(t: ^testing.T) {
	r := reverb_new(FS, reverb_params_default())
	defer reverb_destroy(&r)
	for i in 0 ..< 1_000 {
		l, rr := reverb_process(&r, f32(i) * 0.1, 0.0)
		testing.expectf(t, l == 0.0 && rr == 0.0, "disabled reverb returned (%v, %v) at %d", l, rr, i)
	}
}

@(test)
reverb_silent_input_returns_silence :: proc(t: ^testing.T) {
	r := reverb_new(FS, reverb_test_params())
	defer reverb_destroy(&r)
	for i in 0 ..< 4_800 {
		l, rr := reverb_process(&r, 0.0, 0.0)
		testing.expectf(t, l == 0.0 && rr == 0.0, "silent input produced (%v, %v) at %d", l, rr, i)
	}
}

@(test)
reverb_zero_return_level_is_silent :: proc(t: ^testing.T) {
	p := reverb_test_params()
	p.return_level = 0.0
	r := reverb_new(FS, p)
	defer reverb_destroy(&r)
	for _ in 0 ..< 1_000 {
		l, rr := reverb_process(&r, 0.5, 0.5)
		testing.expect(t, l == 0.0 && rr == 0.0, "zero return level produced output")
	}
}

@(test)
reverb_wet_output_stays_bounded_at_extreme_decay :: proc(t: ^testing.T) {
	p := reverb_test_params()
	p.decay = 1.0
	r := reverb_new(FS, p)
	defer reverb_destroy(&r)

	peak: f32 = 0.0
	for i in 0 ..< 480_000 {
		x := f32(0.8) if i % 4_800 == 0 else 0.0
		l, rr := reverb_process(&r, x, x)
		peak = max(peak, abs(l), abs(rr))
	}
	testing.expectf(t, !math.is_nan(peak) && !math.is_inf(peak), "non-finite peak %v", peak)
	testing.expectf(t, peak < 4.0, "peak %v", peak)
}

@(test)
reverb_stereo_output_is_decorrelated :: proc(t: ^testing.T) {
	r := reverb_new(FS, reverb_test_params())
	defer reverb_destroy(&r)

	sl: f32 = 0.0
	sr: f32 = 0.0
	slr: f32 = 0.0
	for i in 0 ..< 96_000 {
		x := f32(0.7) if i % 1_000 == 0 else 0.0
		l, rr := reverb_process(&r, x, x)
		sl += l * l
		sr += rr * rr
		slr += l * rr
	}
	corr := slr / max(math.sqrt(sl * sr), 1e-9)
	testing.expectf(t, corr < 0.9, "tail is nearly mono: corr %v", corr)
}

@(test)
reverb_stereo_taps_differ_materially :: proc(t: ^testing.T) {
	r := reverb_new(FS, reverb_test_params())
	defer reverb_destroy(&r)

	diff: f32 = 0.0
	total: f32 = 0.0
	for i in 0 ..< 48_000 {
		x := f32(1.0) if i == 0 else 0.0
		l, rr := reverb_process(&r, x, x)
		diff += abs(l - rr)
		total += abs(l) + abs(rr)
	}
	testing.expectf(t, total > 0.0, "impulse produced no tail")
	testing.expectf(t, diff > 0.05 * total, "L and R nearly identical: diff %v total %v", diff, total)
}

@(test)
reverb_decay_knob_orders_tail_energy :: proc(t: ^testing.T) {
	short_params := reverb_test_params()
	short_params.decay = 0.2
	long_params := reverb_test_params()
	long_params.decay = 0.8

	// Ratio of late to early energy removes any input-level dependence and
	// directly measures how fast the tail dies.
	short_early := reverb_test_window_energy(short_params, 5_000, 20_000)
	short_late := reverb_test_window_energy(short_params, 40_000, 60_000)
	long_early := reverb_test_window_energy(long_params, 5_000, 20_000)
	long_late := reverb_test_window_energy(long_params, 40_000, 60_000)

	testing.expectf(t, short_early > 0.0 && long_early > 0.0, "no early energy: %v / %v", short_early, long_early)
	short_ratio := short_late / short_early
	long_ratio := long_late / long_early
	testing.expectf(t, long_ratio > 0.0, "long decay tail vanished: %v", long_ratio)
	testing.expectf(t, long_ratio > short_ratio * 10.0, "decay knob did not lengthen the tail: short ratio %v long ratio %v", short_ratio, long_ratio)
}

@(test)
reverb_rt60_mapping_is_sane :: proc(t: ^testing.T) {
	p := reverb_params_default()

	p.decay = 0.0
	testing.expectf(t, abs(reverb_rt60_seconds(p) - 0.3) < 1e-3, "rt60(0) %v", reverb_rt60_seconds(p))

	p.decay = 1.0
	testing.expectf(t, reverb_rt60_seconds(p) > 10.0, "rt60(1) %v", reverb_rt60_seconds(p))
}

@(test)
reverb_size_scale_and_rt60_match_formulas :: proc(t: ^testing.T) {
	p := reverb_params_default()

	p.size = 0.0
	testing.expectf(t, abs(reverb_size_scale(p) - 0.25) < 1e-6, "size_scale(0) %v", reverb_size_scale(p))
	p.size = 0.5
	testing.expectf(t, abs(reverb_size_scale(p) - 0.5) < 1e-6, "size_scale(0.5) %v", reverb_size_scale(p))
	p.size = 1.0
	testing.expectf(t, abs(reverb_size_scale(p) - 1.0) < 1e-6, "size_scale(1) %v", reverb_size_scale(p))
	p.size = 0.62
	testing.expectf(t, abs(reverb_size_scale(p) - 0.25 * math.pow(f32(4.0), 0.62)) < 1e-6, "size_scale(0.62) %v", reverb_size_scale(p))

	p.decay = 0.5
	expected_rt60 := 0.3 * math.pow(f32(60.0), f32(0.5))
	testing.expectf(t, abs(reverb_rt60_seconds(p) - expected_rt60) < 1e-5, "rt60(0.5) %v expected %v", reverb_rt60_seconds(p), expected_rt60)
	p.decay = 1.0
	testing.expectf(t, abs(reverb_rt60_seconds(p) - 18.0) < 1e-4, "rt60(1) %v", reverb_rt60_seconds(p))
}

@(test)
reverb_params_sanitized_clamps_every_knob :: proc(t: ^testing.T) {
	p := Reverb_Params {
		enabled = true,
		size = -1.0,
		decay = 2.0,
		tone = -0.5,
		predelay_ms = 500.0,
		return_level = 3.0,
	}
	s := reverb_params_sanitized(p)
	testing.expectf(t, s.size == 0.0, "size %v", s.size)
	testing.expectf(t, s.decay == 1.0, "decay %v", s.decay)
	testing.expectf(t, s.tone == 0.0, "tone %v", s.tone)
	testing.expectf(t, s.predelay_ms == 200.0, "predelay %v", s.predelay_ms)
	testing.expectf(t, s.return_level == 1.0, "return level %v", s.return_level)

	p = Reverb_Params {
		enabled = false,
		size = 2.0,
		decay = -1.0,
		tone = 2.0,
		predelay_ms = -20.0,
		return_level = -1.0,
	}
	s = reverb_params_sanitized(p)
	testing.expectf(t, s.size == 1.0, "size %v", s.size)
	testing.expectf(t, s.decay == 0.0, "decay %v", s.decay)
	testing.expectf(t, s.tone == 1.0, "tone %v", s.tone)
	testing.expectf(t, s.predelay_ms == 0.0, "predelay %v", s.predelay_ms)
	testing.expectf(t, s.return_level == 0.0, "return level %v", s.return_level)
}

@(test)
reverb_noise_stays_finite_for_five_seconds :: proc(t: ^testing.T) {
	p := reverb_test_params()
	p.decay = 0.9
	r := reverb_new(FS, p)
	defer reverb_destroy(&r)

	seed: u32 = 0x1234_5678
	peak: f32 = 0.0
	for i in 0 ..< 240_000 {
		seed = seed * 1_664_525 + 1_013_904_223
		x := (f32(seed >> 8) / f32(1 << 24)) * 2.0 - 1.0
		l, rr := reverb_process(&r, x, -x)
		testing.expectf(t, !math.is_nan(l) && !math.is_inf(l) && !math.is_nan(rr) && !math.is_inf(rr), "non-finite output at %d", i)
		peak = max(peak, abs(l), abs(rr))
	}
	testing.expectf(t, peak < 8.0, "unbounded peak %v", peak)
}
