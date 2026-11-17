// Feed-forward stereo-linked compressor with soft knee and auto makeup.
//
// Detector: peak (max of |L|, |R|) with a one-pole attack/release envelope.
// Gain computer: soft-knee static curve in dB, then a smoothed gain applied to
// both channels so the stereo image never shifts.
//
// Ported from src-tauri/src/audio/fx/compressor.rs.

package dsp

Comp_Params :: struct {
	enabled:      bool `json:"enabled"`,
	threshold_db: f32  `json:"thresholdDb"`,
	ratio:        f32  `json:"ratio"`,
	attack_ms:    f32  `json:"attackMs"`,
	release_ms:   f32  `json:"releaseMs"`,
	knee_db:      f32  `json:"kneeDb"`,
	makeup_db:    f32  `json:"makeupDb"`,
	mix:          f32  `json:"mix"`,
	auto_makeup:  bool `json:"autoMakeup"`,
}

comp_params_default :: proc() -> Comp_Params {
	return Comp_Params {
		enabled = true,
		threshold_db = -18.0,
		ratio = 3.0,
		attack_ms = 12.0,
		release_ms = 180.0,
		knee_db = 8.0,
		makeup_db = 0.0,
		mix = 1.0,
		auto_makeup = true,
	}
}

comp_params_sanitized :: proc(params: Comp_Params) -> Comp_Params {
	p := params
	p.threshold_db = clamp(p.threshold_db, -60.0, 0.0)
	p.ratio = clamp(p.ratio, 1.0, 20.0)
	p.attack_ms = clamp(p.attack_ms, 0.1, 300.0)
	p.release_ms = clamp(p.release_ms, 5.0, 2_000.0)
	p.knee_db = clamp(p.knee_db, 0.0, 24.0)
	p.makeup_db = clamp(p.makeup_db, -12.0, 24.0)
	p.mix = clamp(p.mix, 0.0, 1.0)
	return p
}

// Makeup that restores roughly the loudness the compressor removes:
// 0.6 * (-threshold) * (1 - 1/ratio).
comp_auto_makeup_db :: proc(p: Comp_Params) -> f32 {
	if p.ratio <= 1.0001 {
		return 0.0
	}
	return clamp(0.6 * -p.threshold_db * (1.0 - 1.0 / p.ratio), 0.0, 24.0)
}

comp_effective_makeup_db :: proc(p: Comp_Params) -> f32 {
	if p.auto_makeup {
		return comp_auto_makeup_db(p)
	}
	return p.makeup_db
}

// Static transfer curve: input dB -> output dB, before makeup.
comp_transfer_db :: proc(p: Comp_Params, input_db: f32) -> f32 {
	over := input_db - p.threshold_db
	slope := 1.0 - 1.0 / max(p.ratio, 1.0)
	knee := p.knee_db
	reduction: f32
	if knee <= 0.0 {
		reduction = max(over, 0.0) * slope
	} else if over <= -knee * 0.5 {
		reduction = 0.0
	} else if over >= knee * 0.5 {
		reduction = over * slope
	} else {
		x := over + knee * 0.5
		reduction = slope * x * x / (2.0 * knee)
	}
	return input_db - reduction
}

Compressor :: struct {
	sample_rate:    f32,
	params:         Comp_Params,
	attack_coeff:   f32,
	release_coeff:  f32,
	makeup_lin:     f32,
	// Release-smoothed gain reduction (dB, <= 0).
	y1:             f32,
	// Attack-smoothed gain reduction applied to the audio (dB, <= 0).
	gain_db:        f32,
	// Worst-case reduction seen since reset.
	min_gain_db:    f32,
}

comp_new :: proc(sample_rate: f32, params: Comp_Params) -> Compressor {
	c := Compressor {
		sample_rate = sample_rate,
	}
	comp_update(&c, sample_rate, params)
	return c
}

comp_update :: proc(c: ^Compressor, sample_rate: f32, params: Comp_Params) {
	c.sample_rate = sample_rate
	c.params = comp_params_sanitized(params)
	c.attack_coeff = coeff_for_ms(c.params.attack_ms, sample_rate)
	c.release_coeff = coeff_for_ms(c.params.release_ms, sample_rate)
	c.makeup_lin = db_to_lin(comp_effective_makeup_db(c.params))
}

comp_gain_reduction_db :: proc(c: ^Compressor) -> f32 {
	return c.min_gain_db
}

comp_instantaneous_reduction_db :: proc(c: ^Compressor) -> f32 {
	return c.gain_db
}

comp_reset_meter :: proc(c: ^Compressor) {
	c.min_gain_db = 0.0
}

@(private)
comp_target_reduction_db :: proc(c: ^Compressor, input_db: f32) -> f32 {
	return comp_transfer_db(c.params, input_db) - input_db
}

comp_process :: proc(c: ^Compressor, l, r: f32) -> (f32, f32) {
	if !c.params.enabled || c.params.ratio <= 1.0001 {
		return l, r
	}
	detector := max(abs(l), abs(r))
	input_db := lin_to_db(detector)
	target := min(comp_target_reduction_db(c, input_db), 0.0)

	// Decoupled detector (Giannoulis/Massberg/Reiss 2012, eq. 17): release
	// smoothing with instant attack, then attack smoothing.
	c.y1 = min(target, c.release_coeff * c.y1 + (1.0 - c.release_coeff) * target)
	c.gain_db = c.attack_coeff * c.gain_db + (1.0 - c.attack_coeff) * c.y1
	if c.gain_db < c.min_gain_db {
		c.min_gain_db = c.gain_db
	}

	gain := db_to_lin(c.gain_db) * c.makeup_lin
	wet_l := l * gain
	wet_r := r * gain
	mix := c.params.mix
	if mix >= 0.999 {
		return wet_l, wet_r
	}
	return wet_l * mix + l * (1.0 - mix), wet_r * mix + r * (1.0 - mix)
}
