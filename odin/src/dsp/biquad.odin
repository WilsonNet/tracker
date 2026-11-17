// Biquad filters - Robert Bristow-Johnson "Audio EQ Cookbook".
//
// Transposed direct form II: two state words, good numerical behaviour for
// float audio, one multiply-add per coefficient.
//
// Ported from src-tauri/src/audio/fx/biquad.rs.

package dsp

import "core:math"

Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	z1, z2:            f32,
}

// Peaking EQ. `gain_db` positive boosts, `q` sets bandwidth.
biquad_peaking :: proc(fs, freq, q, gain_db: f32) -> Biquad {
	a := math.pow(10.0, gain_db / 40.0)
	w0 := math.TAU * clamp(freq / fs, 1e-5, 0.49)
	cos_w0 := math.cos(w0)
	alpha := math.sin(w0) / (2.0 * max(q, 0.05))
	a0 := 1.0 + alpha / a
	return Biquad {
		b0 = (1.0 + alpha * a) / a0,
		b1 = (-2.0 * cos_w0) / a0,
		b2 = (1.0 - alpha * a) / a0,
		a1 = (-2.0 * cos_w0) / a0,
		a2 = (1.0 - alpha / a) / a0,
	}
}

// Low shelf. `slope` of 1.0 is the RBJ default (Q ~= 0.707).
biquad_low_shelf :: proc(fs, freq, gain_db, slope: f32) -> Biquad {
	a := math.pow(10.0, gain_db / 40.0)
	w0 := math.TAU * clamp(freq / fs, 1e-5, 0.49)
	cos_w0 := math.cos(w0)
	sin_w0 := math.sin(w0)
	alpha := sin_w0 / 2.0 * math.sqrt((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0)
	two_sqrt_a_alpha := 2.0 * math.sqrt(a) * alpha
	a0 := (a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha
	return Biquad {
		b0 = a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha) / a0,
		b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0) / a0,
		b2 = a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
		a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0) / a0,
		a2 = ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
	}
}

// High shelf. `slope` of 1.0 is the RBJ default.
biquad_high_shelf :: proc(fs, freq, gain_db, slope: f32) -> Biquad {
	a := math.pow(10.0, gain_db / 40.0)
	w0 := math.TAU * clamp(freq / fs, 1e-5, 0.49)
	cos_w0 := math.cos(w0)
	sin_w0 := math.sin(w0)
	alpha := sin_w0 / 2.0 * math.sqrt((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0)
	two_sqrt_a_alpha := 2.0 * math.sqrt(a) * alpha
	a0 := (a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha
	return Biquad {
		b0 = a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha) / a0,
		b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0) / a0,
		b2 = a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
		a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0) / a0,
		a2 = ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
	}
}

biquad_process :: proc(b: ^Biquad, x: f32) -> f32 {
	y := b.b0 * x + b.z1
	b.z1 = flush_denormal(b.b1 * x - b.a1 * y + b.z2)
	b.z2 = flush_denormal(b.b2 * x - b.a2 * y)
	return y
}

biquad_reset :: proc(b: ^Biquad) {
	b.z1 = 0.0
	b.z2 = 0.0
}

// Complex magnitude response at `freq`, computed from the transfer function.
biquad_magnitude_at :: proc(b: ^Biquad, fs, freq: f32) -> f32 {
	w := math.TAU * freq / fs
	sin1 := math.sin(w)
	cos1 := math.cos(w)
	sin2 := math.sin(2.0 * w)
	cos2 := math.cos(2.0 * w)
	num_re := b.b0 + b.b1 * cos1 + b.b2 * cos2
	num_im := -(b.b1 * sin1 + b.b2 * sin2)
	den_re := 1.0 + b.a1 * cos1 + b.a2 * cos2
	den_im := -(b.a1 * sin1 + b.a2 * sin2)
	return math.sqrt((num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im))
}
