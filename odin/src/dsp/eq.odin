// Three-band channel EQ: low shelf -> mid bell -> high shelf.
//
// Ported from src-tauri/src/audio/fx/eq.rs.

package dsp

LOW_SHELF_HZ :: 110.0
HIGH_SHELF_HZ :: 7_500.0

Eq_Params :: struct {
	enabled: bool `json:"enabled"`,
	// Low shelf gain, dB.
	low_db:  f32  `json:"lowDb"`,
	// Mid bell gain, dB.
	mid_db:  f32  `json:"midDb"`,
	// Mid bell centre, Hz.
	mid_hz:  f32  `json:"midHz"`,
	// Mid bell width.
	mid_q:   f32  `json:"midQ"`,
	// High shelf gain, dB.
	high_db: f32  `json:"highDb"`,
}

eq_params_default :: proc() -> Eq_Params {
	return Eq_Params {
		enabled = true,
		low_db = 0.0,
		mid_db = 0.0,
		mid_hz = 1_000.0,
		mid_q = 1.0,
		high_db = 0.0,
	}
}

eq_params_sanitized :: proc "contextless" (params: Eq_Params) -> Eq_Params {
	p := params
	p.low_db = clamp(p.low_db, -18.0, 18.0)
	p.mid_db = clamp(p.mid_db, -18.0, 18.0)
	p.high_db = clamp(p.high_db, -18.0, 18.0)
	p.mid_hz = clamp(p.mid_hz, 150.0, 8_000.0)
	p.mid_q = clamp(p.mid_q, 0.3, 8.0)
	return p
}

eq_params_is_active :: proc "contextless" (params: Eq_Params) -> bool {
	return params.enabled &&
	       (abs(params.low_db) > 0.05 || abs(params.mid_db) > 0.05 || abs(params.high_db) > 0.05)
}

Eq_State :: struct {
	low_l, low_r:   Biquad,
	mid_l, mid_r:   Biquad,
	high_l, high_r: Biquad,
	active:         bool,
}

eq_new :: proc(sample_rate: f32, params: Eq_Params) -> Eq_State {
	eq: Eq_State
	eq_update(&eq, sample_rate, params)
	return eq
}

eq_update :: proc "contextless" (eq: ^Eq_State, sample_rate: f32, params: Eq_Params) {
	p := eq_params_sanitized(params)
	eq.active = eq_params_is_active(p)
	eq.low_l = biquad_low_shelf(sample_rate, LOW_SHELF_HZ, p.low_db, 1.0)
	eq.low_r = biquad_low_shelf(sample_rate, LOW_SHELF_HZ, p.low_db, 1.0)
	eq.mid_l = biquad_peaking(sample_rate, p.mid_hz, p.mid_q, p.mid_db)
	eq.mid_r = biquad_peaking(sample_rate, p.mid_hz, p.mid_q, p.mid_db)
	eq.high_l = biquad_high_shelf(sample_rate, HIGH_SHELF_HZ, p.high_db, 1.0)
	eq.high_r = biquad_high_shelf(sample_rate, HIGH_SHELF_HZ, p.high_db, 1.0)
}

eq_set_params :: proc "contextless" (eq: ^Eq_State, sample_rate: f32, params: Eq_Params) {
	p := eq_params_sanitized(params)
	eq.active = eq_params_is_active(p)
	low := biquad_low_shelf(sample_rate, LOW_SHELF_HZ, p.low_db, 1.0)
	mid := biquad_peaking(sample_rate, p.mid_hz, p.mid_q, p.mid_db)
	high := biquad_high_shelf(sample_rate, HIGH_SHELF_HZ, p.high_db, 1.0)
	biquad_copy_coeffs(&eq.low_l, low)
	biquad_copy_coeffs(&eq.low_r, low)
	biquad_copy_coeffs(&eq.mid_l, mid)
	biquad_copy_coeffs(&eq.mid_r, mid)
	biquad_copy_coeffs(&eq.high_l, high)
	biquad_copy_coeffs(&eq.high_r, high)
}

eq_reset :: proc "contextless" (eq: ^Eq_State) {
	biquad_reset(&eq.low_l)
	biquad_reset(&eq.low_r)
	biquad_reset(&eq.mid_l)
	biquad_reset(&eq.mid_r)
	biquad_reset(&eq.high_l)
	biquad_reset(&eq.high_r)
}

eq_process :: proc "contextless" (eq: ^Eq_State, l, r: f32) -> (f32, f32) {
	if !eq.active {
		return l, r
	}
	l_out := l
	r_out := r
	l_out = biquad_process(&eq.low_l, l_out)
	r_out = biquad_process(&eq.low_r, r_out)
	l_out = biquad_process(&eq.mid_l, l_out)
	r_out = biquad_process(&eq.mid_r, r_out)
	l_out = biquad_process(&eq.high_l, l_out)
	r_out = biquad_process(&eq.high_r, r_out)
	return l_out, r_out
}

// Combined magnitude response in dB at `freq` (left channel).
eq_response_db :: proc(eq: ^Eq_State, sample_rate, freq: f32) -> f32 {
	if !eq.active {
		return 0.0
	}
	mag := biquad_magnitude_at(&eq.low_l, sample_rate, freq) *
	       biquad_magnitude_at(&eq.mid_l, sample_rate, freq) *
	       biquad_magnitude_at(&eq.high_l, sample_rate, freq)
	return lin_to_db(mag)
}
