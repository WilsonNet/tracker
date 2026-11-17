package dsp

import "core:math"
import "core:testing"

@(test)
eq_flat_is_a_passthrough :: proc(t: ^testing.T) {
	params := eq_params_default()
	testing.expect(t, !eq_params_is_active(params), "flat EQ should be inactive")
	eq := eq_new(FS, params)
	for i in 0 ..< 1_000 {
		x := f32(math.sin(f32(i) / 100.0)) * 0.5
		l, r := eq_process(&eq, x, x)
		testing.expect(t, l == x && r == x, "flat EQ altered the signal")
	}
}

@(test)
eq_boosts_low_end_only :: proc(t: ^testing.T) {
	params := eq_params_default()
	params.low_db = 6.0
	eq := eq_new(FS, params)
	low := eq_response_db(&eq, FS, 40.0)
	high := eq_response_db(&eq, FS, 10_000.0)
	testing.expectf(t, abs(low - 6.0) < 1.0, "low shelf gain %v", low)
	testing.expectf(t, abs(high) < 0.6, "high end coloured by %v dB", high)
}

@(test)
eq_mid_bell_centre_matches_setting :: proc(t: ^testing.T) {
	params := eq_params_default()
	params.mid_db = -9.0
	params.mid_hz = 2_500.0
	eq := eq_new(FS, params)
	got := eq_response_db(&eq, FS, 2_500.0)
	testing.expectf(t, abs(got + 9.0) < 0.4, "mid bell %v dB", got)
}

@(test)
compressor_quiet_signal_passes_untouched :: proc(t: ^testing.T) {
	params := comp_params_default()
	params.auto_makeup = false
	c := comp_new(FS, params)
	for _ in 0 ..< 48_000 {
		l, r := comp_process(&c, 0.01, -0.01)
		testing.expectf(t, abs(l - 0.01) < 1e-4, "l %v", l)
		testing.expectf(t, abs(r + 0.01) < 1e-4, "r %v", r)
	}
	testing.expectf(t, comp_gain_reduction_db(&c) > -0.2, "unexpected reduction %v", comp_gain_reduction_db(&c))
}

@(test)
compressor_reduces_loud_signal :: proc(t: ^testing.T) {
	params := comp_params_default()
	params.attack_ms = 1.0
	params.auto_makeup = false
	c := comp_new(FS, params)
	peak: f32 = 0.0
	for i in 0 ..< 48_000 {
		l, _ := comp_process(&c, 0.9, 0.9)
		if i > 4_800 {
			peak = max(peak, l)
		}
	}
	testing.expectf(t, peak < 0.4, "peak %v", peak)
	testing.expectf(t, comp_gain_reduction_db(&c) < -8.0, "reduction %v", comp_gain_reduction_db(&c))
}

@(test)
compressor_transfer_curve_is_monotonic_and_bounded :: proc(t: ^testing.T) {
	p := comp_params_default()
	prev: f32 = -100.0
	for i in -60 ..= 0 {
		out := comp_transfer_db(p, f32(i))
		testing.expectf(t, out >= prev - 1e-4, "not monotonic at %d", i)
		testing.expectf(t, out <= f32(i) + 1e-4, "curve exceeded unity at %d", i)
		prev = out
	}
}

@(test)
compressor_makeup_compensates_threshold :: proc(t: ^testing.T) {
	p := comp_params_default()
	p.threshold_db = -20.0
	p.ratio = 4.0
	testing.expectf(t, abs(comp_auto_makeup_db(p) - 9.0) < 1e-3, "auto makeup %v", comp_auto_makeup_db(p))
	out := comp_transfer_db(p, 0.0) + comp_effective_makeup_db(p)
	testing.expectf(t, abs(out + 6.0) < 0.01, "0 dBFS out %v", out)
}

@(test)
limiter_never_exceeds_ceiling :: proc(t: ^testing.T) {
	params := limiter_params_default()
	ceiling := db_to_lin(params.ceiling_db)
	lim := limiter_new(FS, params)
	defer limiter_destroy(&lim)
	peak: f32 = 0.0
	for i in 0 ..< 480_000 {
		x := math.sin(f32(i) * 110.0 / FS * f32(math.TAU)) * 4.0
		l, r := limiter_process(&lim, x, x)
		testing.expect(t, !math.is_nan(l) && !math.is_nan(r), "limiter produced NaN")
		peak = max(peak, abs(l), abs(r))
	}
	testing.expectf(t, peak <= ceiling + 1e-4, "peak %v > ceiling %v", peak, ceiling)
	testing.expectf(t, limiter_gain_reduction_db(&lim) < -8.0, "no limiting reported")
}

@(test)
limiter_quiet_signal_is_delayed_not_altered :: proc(t: ^testing.T) {
	lim := limiter_new(FS, limiter_params_default())
	defer limiter_destroy(&lim)
	for _ in 0 ..< 1_000 {
		limiter_process(&lim, 0.0, 0.0)
	}
	lookahead := int(5.0 * 0.001 * FS)
	for i in 0 ..< 48_000 {
		x := f32(math.sin(f32(i) * 0.01)) * 0.1
		l, _ := limiter_process(&lim, x, x)
		if i > lookahead + 10 {
			expected := f32(math.sin(f32(i - lookahead) * 0.01)) * 0.1
			testing.expectf(t, abs(l - expected) < 1e-4, "%v vs %v at %d", l, expected, i)
		}
	}
}

@(test)
limiter_disabled_is_a_bypass :: proc(t: ^testing.T) {
	params := limiter_params_default()
	params.enabled = false
	lim := limiter_new(FS, params)
	defer limiter_destroy(&lim)
	l, r := limiter_process(&lim, 2.5, -3.0)
	testing.expect(t, l == 2.5 && r == -3.0, "disabled limiter altered the signal")
}
