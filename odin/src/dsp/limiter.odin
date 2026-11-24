// Look-ahead brickwall limiter with a soft-clip safety stage.
//
// The detector runs `lookahead` samples ahead of the audio; gain reduction
// therefore starts before the transient reaches the output. Release is a
// one-pole, attack is a short ramp sized to the lookahead window.
//
// Ported from src-tauri/src/audio/fx/limiter.rs.

package dsp

Limiter_Params :: struct {
	enabled:      bool `json:"enabled"`,
	// Output ceiling, dBFS. -0.3 is a safe default for 32-bit float renders.
	ceiling_db:   f32  `json:"ceilingDb"`,
	release_ms:   f32  `json:"releaseMs"`,
	lookahead_ms: f32  `json:"lookaheadMs"`,
}

limiter_params_default :: proc() -> Limiter_Params {
	return Limiter_Params {
		enabled = true,
		ceiling_db = -0.3,
		release_ms = 120.0,
		lookahead_ms = 5.0,
	}
}

limiter_params_sanitized :: proc "contextless" (params: Limiter_Params) -> Limiter_Params {
	p := params
	p.ceiling_db = clamp(p.ceiling_db, -12.0, 0.0)
	p.release_ms = clamp(p.release_ms, 10.0, 1_000.0)
	p.lookahead_ms = clamp(p.lookahead_ms, 0.5, 20.0)
	return p
}

Limiter :: struct {
	sample_rate:  f32,
	params:       Limiter_Params,
	left:         []f32,
	right:        []f32,
	write:        int,
	lookahead:    int,
	attack:       f32,
	release:      f32,
	envelope:     f32,
	ceiling_lin:  f32,
	min_gain_db:  f32,
}

limiter_new :: proc(sample_rate: f32, params: Limiter_Params) -> Limiter {
	max_lookahead := int(0.05 * sample_rate) + 4
	lim := Limiter {
		sample_rate = sample_rate,
		left        = make([]f32, max_lookahead),
		right       = make([]f32, max_lookahead),
	}
	limiter_update(&lim, sample_rate, params)
	return lim
}

limiter_destroy :: proc(lim: ^Limiter) {
	delete(lim.left)
	delete(lim.right)
	lim.left = nil
	lim.right = nil
}

limiter_update :: proc "contextless" (lim: ^Limiter, sample_rate: f32, params: Limiter_Params) {
	lim.sample_rate = sample_rate
	lim.params = limiter_params_sanitized(params)
	lim.lookahead = max(int(lim.params.lookahead_ms * 0.001 * sample_rate), 1)
	lim.lookahead = min(lim.lookahead, len(lim.left) - 2)
	// Reach the target inside the lookahead window: ~99.9% in N samples.
	lim.attack = min(1.0 / (0.15 * f32(lim.lookahead)), 1.0)
	lim.release = 1.0 - coeff_for_ms(lim.params.release_ms, sample_rate)
	lim.ceiling_lin = db_to_lin(lim.params.ceiling_db)
	lim.envelope = 1.0
	for i in 0 ..< len(lim.left) {
		lim.left[i] = 0.0
		lim.right[i] = 0.0
	}
	lim.write = 0
	lim.min_gain_db = 0.0
}

limiter_reset :: proc "contextless" (lim: ^Limiter) {
	for i in 0 ..< len(lim.left) {
		lim.left[i] = 0.0
		lim.right[i] = 0.0
	}
	lim.write = 0
	lim.envelope = 1.0
	lim.min_gain_db = 0.0
}

limiter_gain_reduction_db :: proc(lim: ^Limiter) -> f32 {
	return lim.min_gain_db
}

// Reduction currently applied to the delayed sample, dB (<= 0). Unlike
// `limiter_gain_reduction_db` this is not a running minimum, so meter
// timelines can show the release instead of staying at the worst value.
limiter_instantaneous_reduction_db :: proc "contextless" (lim: ^Limiter) -> f32 {
	return lin_to_db(lim.envelope)
}

limiter_reset_meter :: proc "contextless" (lim: ^Limiter) {
	lim.min_gain_db = 0.0
}

@(private)
limiter_delayed :: proc "contextless" (lim: ^Limiter, l, r: f32) -> (f32, f32) {
	read := (lim.write + len(lim.left) - lim.lookahead) % len(lim.left)
	out_l := lim.left[read]
	out_r := lim.right[read]
	lim.left[lim.write] = l
	lim.right[lim.write] = r
	lim.write = (lim.write + 1) % len(lim.left)
	return out_l, out_r
}

// Returns limited output. A disabled limiter is a true bypass.
limiter_process :: proc "contextless" (lim: ^Limiter, l, r: f32) -> (f32, f32) {
	if !lim.params.enabled {
		return l, r
	}
	peak := max(abs(l), abs(r))
	target := f32(1.0)
	if peak > lim.ceiling_lin {
		target = lim.ceiling_lin / peak
	}

	// Gain moves down fast (predicted ahead of the audio) and up slowly.
	if target < lim.envelope {
		lim.envelope += (target - lim.envelope) * lim.attack
	} else {
		lim.envelope += (target - lim.envelope) * lim.release
	}
	lim.envelope = clamp(lim.envelope, 0.0, 1.0)

	dl, dr := limiter_delayed(lim, l, r)
	gain_db := lin_to_db(lim.envelope)
	if gain_db < lim.min_gain_db {
		lim.min_gain_db = gain_db
	}

	ceiling := lim.ceiling_lin
	return soft_clip(dl * lim.envelope, ceiling), soft_clip(dr * lim.envelope, ceiling)
}
