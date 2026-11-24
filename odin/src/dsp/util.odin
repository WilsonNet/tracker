// Shared DSP helpers: dB conversions, smoothing coefficients, saturation.
//
// Ported from src-tauri/src/audio/fx/util.rs. Kept sample-for-sample identical
// to the Rust reference so the Odin engine can be A/B checked against it.

package dsp

import "core:math"

// Linear amplitude -> decibels. Silence floors at -120 dB.
lin_to_db :: proc "contextless" (x: f32) -> f32 {
	if x <= 1e-6 {
		return -120.0
	}
	return 20.0 * math.log10(x)
}

db_to_lin :: proc "contextless" (db: f32) -> f32 {
	return math.pow(10.0, db / 20.0)
}

// One-pole coefficient for a time constant in milliseconds.
coeff_for_ms :: proc "contextless" (ms, sample_rate: f32) -> f32 {
	return math.exp(-1.0 / (max(ms, 0.01) * 0.001 * sample_rate))
}

// Piecewise Hermite soft clipper. Exactly linear below 75% of `ceiling`,
// unity slope at the knee, zero slope at the ceiling. A NaN input would
// otherwise turn into a full-scale DC sample at the output of the safety
// stage, so it is treated as silence.
soft_clip :: proc "contextless" (x, ceiling: f32) -> f32 {
	if math.is_nan(x) {
		return 0.0
	}
	c := max(abs(ceiling), 1e-6)
	knee := 0.75 * c
	s := abs(x)
	y: f32
	if s <= knee {
		y = s
	} else if s < c {
		t := (s - knee) / (c - knee)
		t2 := t * t
		t3 := t2 * t
		y = (2.0 * t3 - 3.0 * t2 + 1.0) * knee +
		    (t3 - 2.0 * t2 + t) * (c - knee) +
		    (-2.0 * t3 + 3.0 * t2) * c
	} else {
		y = c
	}
	return math.copy_sign(y, x)
}

@(private)
flush_denormal :: proc "contextless" (x: f32) -> f32 {
	return 0.0 if abs(x) < 1e-20 else x
}

// Peak and RMS of an interleaved buffer, in dBFS. Used by `info` and by the
// end-to-end tests.
peak_rms_db :: proc(samples: []f32, channels: int) -> (peak_db: f32, rms_db: f32) {
	peak: f32
	sum: f64
	if len(samples) == 0 {
		return -120.0, -120.0
	}
	for s in samples {
		peak = max(peak, abs(s))
		sum += f64(s) * f64(s)
	}
	peak_db = lin_to_db(peak)
	rms := f32(math.sqrt(sum / f64(len(samples))))
	rms_db = lin_to_db(rms)
	return
}
