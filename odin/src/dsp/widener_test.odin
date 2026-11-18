package dsp

import "core:math"
import "core:testing"

// Steady-state peak of the side signal `(L - R) / 2` for a side-only input
// (L = s, R = -s) at `freq`. Skips the first `settle` samples so the one-pole
// split has settled before measuring.
@(private)
widener_side_peak :: proc(w: ^Widener, freq, amp: f32, settle, measure: int) -> f32 {
	peak: f32 = 0.0
	for i in 0 ..< settle + measure {
		t := f32(i) / FS
		s := f32(math.sin(t * freq * f32(math.TAU))) * amp
		l, r := widener_process(w, s, -s)
		if i >= settle {
			peak = max(peak, abs(l - r) * 0.5)
		}
	}
	return peak
}

@(test)
widener_width_of_one_is_a_passthrough :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 1.0
	w := widener_new(FS, params)
	for i in 0 ..< 1_000 {
		l := f32(math.sin(f32(i) * 0.01))
		r := f32(math.cos(f32(i) * 0.013))
		ol, or := widener_process(&w, l, r)
		testing.expectf(t, ol == l && or == r, "unity width altered %v %v -> %v %v", l, r, ol, or)
	}
}

@(test)
widener_wide_keeps_the_mono_sum :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 2.0
	w := widener_new(FS, params)

	trim: f32 = 1.0 / 1.5
	worst: f32 = 0.0
	for i in 0 ..< 48_000 {
		time := f32(i) / FS
		l := f32(math.sin(time * 440.0 * f32(math.TAU))) * 0.5
		r := f32(math.sin(time * 660.0 * f32(math.TAU))) * 0.5
		ol, or := widener_process(&w, l, r)
		worst = max(worst, abs((ol + or) / trim - (l + r)))
	}
	testing.expectf(t, worst < 1e-5, "mono sum changed by %v", worst)
}

@(test)
widener_zero_width_collapses_to_mono :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 0.0
	w := widener_new(FS, params)

	l, r: f32
	for _ in 0 ..< 48_000 {
		l, r = widener_process(&w, 0.5, -0.25)
	}
	testing.expectf(t, abs(l - r) < 0.05, "not mono: %v %v", l, r)
	// Zero width removes the side completely: L = R = M.
	testing.expectf(t, abs(l - 0.125) < 1e-5, "mid level changed: %v", l)
}

// Above the bass crossover the side is doubled; the peak trim keeps the
// overall level in check, so the gain is 2 / 1.5.
@(test)
widener_width_two_boosts_the_side :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 2.0
	w := widener_new(FS, params)

	side := widener_side_peak(&w, 4_000.0, 0.25, 9_600, 24_000)
	gain := side / 0.25
	testing.expectf(t, abs(gain - 4.0 / 3.0) < 0.02, "side gain %v, expected 1.333", gain)
}

// Bass side content stays mono-safe when widening. The two-pole split passes
// DC with unity gain, so a constant side signal is completely removed: below
// the crossover the output collapses to the mid signal. Well below the
// crossover (30 Hz against 140 Hz) the side gain is strongly reduced compared
// with the fully widened top band.
@(test)
widener_bass_stays_mono_when_wide :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 2.0
	w := widener_new(FS, params)

	// Constant side content (0 Hz) is pure bass: no widening, and the side
	// vanishes, so L and R are equal.
	l, r: f32
	for _ in 0 ..< 9_600 {
		l, r = widener_process(&w, 0.5, -0.5)
	}
	testing.expectf(t, abs(l - r) < 1e-4, "DC bass not mono: %v %v", l, r)

	low_gain := widener_side_peak(&w, 30.0, 0.5, 14_400, 24_000) / 0.5
	high_gain := widener_side_peak(&w, 4_000.0, 0.5, 9_600, 24_000) / 0.5
	testing.expectf(t, low_gain < 0.6, "30 Hz side was widened: gain %v", low_gain)
	testing.expectf(t, high_gain > 1.2, "4 kHz side was not widened: gain %v", high_gain)
	testing.expectf(
		t,
		low_gain < 0.6 * high_gain,
		"bass not collapsed relative to highs: low %v, high %v",
		low_gain,
		high_gain,
	)
}

@(test)
widener_disabled_is_a_bypass :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = false
	params.width = 2.0
	w := widener_new(FS, params)
	l, r := widener_process(&w, 2.5, -3.0)
	testing.expectf(t, l == 2.5 && r == -3.0, "disabled widener altered %v %v -> %v %v", 2.5, -3.0, l, r)
}

@(test)
widener_finite_on_extreme_input :: proc(t: ^testing.T) {
	params := width_params_default()
	params.enabled = true
	params.width = 2.0
	params.bass_hz = 40.0
	w := widener_new(FS, params)

	inputs := [8]f32{4.0, -4.0, 9.0, -9.0, 1_000_000.0, -1_000_000.0, 0.0, 3.0}
	for i in 0 ..< 48_000 {
		x := inputs[i % len(inputs)]
		l, r := widener_process(&w, x, -x)
		testing.expectf(t, !math.is_nan(l) && !math.is_inf(l), "l diverged at %d: %v", i, l)
		testing.expectf(t, !math.is_nan(r) && !math.is_inf(r), "r diverged at %d: %v", i, r)
		testing.expectf(t, abs(l) <= 8.0 && abs(r) <= 8.0, "output left the ceiling at %d: %v %v", i, l, r)
	}
}

@(test)
widener_params_are_sanitized :: proc(t: ^testing.T) {
	p := width_params_sanitized(Width_Params{width = -1.0, bass_hz = 10.0})
	testing.expectf(t, p.width == 0.0, "width %v", p.width)
	testing.expectf(t, p.bass_hz == 40.0, "bass_hz %v", p.bass_hz)

	p = width_params_sanitized(Width_Params{width = 3.0, bass_hz = 1_000.0})
	testing.expectf(t, p.width == 2.0, "width %v", p.width)
	testing.expectf(t, p.bass_hz == 400.0, "bass_hz %v", p.bass_hz)

	defaults := width_params_default()
	testing.expectf(t, !defaults.enabled, "widener should default to disabled")
	testing.expectf(t, defaults.width == 1.0, "default width %v", defaults.width)
	testing.expectf(t, defaults.bass_hz == 140.0, "default bass %v", defaults.bass_hz)
}

@(test)
widener_bass_mono_amount_scales_above_unity :: proc(t: ^testing.T) {
	testing.expectf(t, width_bass_mono_amount(Width_Params{width = 0.5}) == 0.0, "narrow should remove no bass")
	testing.expectf(t, width_bass_mono_amount(Width_Params{width = 1.0}) == 0.0, "unity should remove no bass")
	testing.expectf(t, width_bass_mono_amount(Width_Params{width = 1.5}) == 0.5, "width 1.5")
	testing.expectf(t, width_bass_mono_amount(Width_Params{width = 2.0}) == 1.0, "width 2")
	testing.expectf(t, width_bass_mono_amount(Width_Params{width = 3.0}) == 1.0, "width 3 clamps")
}
