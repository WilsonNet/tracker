// Master stereo widener.
//
// Mid/side width with a frequency split: the side signal above `bass_hz` is
// scaled, everything below stays summed to mono. Because the mono sum is
// `L + R = 2M` for any width, this stays mono-compatible — only the stereo
// image changes.
//
// Ported from src-tauri/src/audio/fx/widener.rs.

package dsp

import "core:math"

Width_Params :: struct {
	enabled: bool `json:"enabled"`,
	// 0 = mono, 1 = unchanged, 2 = double width.
	width:   f32  `json:"width"`,
	// Side content below this frequency is folded to mono.
	bass_hz: f32  `json:"bassHz"`,
}

width_params_default :: proc() -> Width_Params {
	return Width_Params {
		enabled = false,
		width = 1.0,
		bass_hz = 140.0,
	}
}

width_params_sanitized :: proc "contextless" (params: Width_Params) -> Width_Params {
	p := params
	p.width = clamp(p.width, 0.0, 2.0)
	p.bass_hz = clamp(p.bass_hz, 40.0, 400.0)
	return p
}

// How much of the low side content is removed, 0..1.
width_bass_mono_amount :: proc "contextless" (p: Width_Params) -> f32 {
	if p.width <= 1.0 {
		return 0.0
	}
	return min(p.width - 1.0, 1.0)
}

Widener :: struct {
	params:      Width_Params,
	lp_l:        f32,
	lp_r:        f32,
	coeff:       f32,
	sample_rate: f32,
}

widener_new :: proc(sample_rate: f32, params: Width_Params) -> Widener {
	w := Widener {
		params      = width_params_sanitized(params),
		lp_l        = 0.0,
		lp_r        = 0.0,
		coeff       = 1.0,
		sample_rate = sample_rate,
	}
	widener_update(&w, sample_rate, params)
	return w
}

widener_update :: proc "contextless" (w: ^Widener, sample_rate: f32, params: Width_Params) {
	w.sample_rate = sample_rate
	w.params = width_params_sanitized(params)
	// 12 dB/oct side split: two cascaded one-poles.
	w.coeff = 1.0 - math.exp(-f32(math.TAU) * w.params.bass_hz / sample_rate)
	// 10 ms smoothing would matter for live automation; static here.
	_ = coeff_for_ms(10.0, sample_rate)
}

widener_reset :: proc "contextless" (w: ^Widener) {
	w.lp_l = 0.0
	w.lp_r = 0.0
}

// Disabled, or unity width, is a true bypass.
widener_process :: proc "contextless" (w: ^Widener, l, r: f32) -> (f32, f32) {
	if !w.params.enabled || abs(w.params.width - 1.0) < 0.001 {
		return l, r
	}
	mid := (l + r) * 0.5
	side := (l - r) * 0.5

	// Two-pole low-pass on the side signal, then take the complement.
	w.lp_l += w.coeff * (side - w.lp_l)
	w.lp_r += w.coeff * (w.lp_l - w.lp_r)
	low := w.lp_r
	high := side - low

	// Below unity width, narrow both bands. Above unity, leave the bass summed
	// to mono and widen only the top.
	low_gain := min(w.params.width, 1.0) * (1.0 - width_bass_mono_amount(w.params))
	out_side := low * low_gain + high * w.params.width
	// Widening adds side energy; trim the peak so bypass and active match.
	trim := 1.0 / (1.0 + 0.5 * max(w.params.width - 1.0, 0.0))
	return clamp((mid + out_side) * trim, -8.0, 8.0),
	       clamp((mid - out_side) * trim, -8.0, 8.0)
}
