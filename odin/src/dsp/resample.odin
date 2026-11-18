// Offline, band-limited sample-rate conversion.
//
// Windowed-sinc interpolation with a 32-tap Blackman window. The kernel is
// tabulated over 512 fractional phases and linearly interpolated, so the
// per-sample loop performs no allocations and no transcendental calls. Out of
// range source samples are zero-padded, which fades the first and last few
// source samples rather than wrapping or reflecting.
//
// This is deliberately mono: callers deinterleave multichannel input first.
//
// Bandwidth note: 32 taps buy a wide transition band (roughly 6-9 kHz at
// 48 kHz). The cutoff is `min(1, dst/src) * 0.94`; for 48k -> 24k that is
// 11.28 kHz, only slightly below the new 12 kHz Nyquist. A 10 kHz tone is
// therefore *below* Nyquist and passes (with ~1.7 dB of passband droop),
// while tones well above Nyquist, e.g. 15 kHz, are attenuated by >40 dB.
// Very large decimation ratios (more than ~4x) need a longer or multistage
// kernel to keep the whole transition band above the new Nyquist.

package dsp

import "core:math"

RESAMPLE_TAPS   :: 32
RESAMPLE_HALF   :: RESAMPLE_TAPS / 2
RESAMPLE_PHASES :: 512

// Build the phase table. Row `p` holds the kernel for a fractional source
// position of `p / RESAMPLE_PHASES`, with tap `j` applied to source sample
// `floor(t) - (HALF - 1) + j`. One extra row lets phase interpolation run to
// exactly 1.0 without wrapping the tap indices.
@(private)
resample_kernel :: proc(cutoff: f64) -> []f32 {
	table := make([]f32, (RESAMPLE_PHASES + 1) * RESAMPLE_TAPS)
	for p in 0 ..= RESAMPLE_PHASES {
		frac := f64(p) / f64(RESAMPLE_PHASES)
		sum: f64
		for j in 0 ..< RESAMPLE_TAPS {
			// Distance in source samples between the continuous read position
			// and this tap.
			d := frac + f64(RESAMPLE_HALF - 1 - j)

			sinc: f64
			if d == 0.0 {
				sinc = 1.0
			} else {
				x := math.PI * cutoff * d
				sinc = math.sin(x) / x
			}

			// Blackman window on [-HALF, HALF], peak 1 at the centre and 0 at
			// the support edges.
			x := d / f64(RESAMPLE_HALF)
			window := 0.42 + 0.5 * math.cos(math.PI * x) + 0.08 * math.cos(2.0 * math.PI * x)

			v := cutoff * sinc * window
			table[p * RESAMPLE_TAPS + j] = f32(v)
			sum += v
		}

		// Normalize each phase for exactly unity DC gain. Without this the
		// finite window leaves a small broadband level error.
		if sum != 0.0 {
			inv := 1.0 / sum
			for j in 0 ..< RESAMPLE_TAPS {
				i := p * RESAMPLE_TAPS + j
				table[i] = f32(f64(table[i]) * inv)
			}
		}
	}
	return table
}

// Band-limited windowed-sinc resampling (32 taps, Blackman window).
// Returns a newly allocated slice owned by the caller.
resample :: proc(input: []f32, src_rate, dst_rate: u32) -> []f32 {
	if len(input) == 0 || src_rate == 0 || dst_rate == 0 {
		return nil
	}

	// Identity conversion still returns a fresh allocation, so callers can
	// uniformly own and delete the result.
	if src_rate == dst_rate {
		out := make([]f32, len(input))
		copy(out, input)
		return out
	}

	// Exact ceiling in integer arithmetic: ceil(len * dst / src).
	out_len := (len(input) * int(dst_rate) + int(src_rate) - 1) / int(src_rate)
	out := make([]f32, max(out_len, 1))

	ratio := f64(dst_rate) / f64(src_rate)
	// 0.94 leaves room for the finite window's transition band when
	// downsampling; upsampling keeps the source passband to 0.94 * Nyquist.
	cutoff := min(1.0, ratio) * 0.94
	kernel := resample_kernel(cutoff)
	defer delete(kernel)

	step := f64(src_rate) / f64(dst_rate)
	taps := RESAMPLE_TAPS
	half_minus_one := RESAMPLE_HALF - 1
	src_len := len(input)

	for n in 0 ..< len(out) {
		t := f64(n) * step
		floor_t := math.floor(t)
		base := int(floor_t) - half_minus_one
		frac := t - floor_t

		pos := frac * f64(RESAMPLE_PHASES)
		phase := int(pos)
		if phase >= RESAMPLE_PHASES {
			phase = RESAMPLE_PHASES - 1
		}
		blend := pos - f64(phase)

		row0 := phase * taps
		row1 := row0 + taps

		acc: f64
		for j in 0 ..< taps {
			s := base + j
			if s >= 0 && s < src_len {
				w0 := f64(kernel[row0 + j])
				w1 := f64(kernel[row1 + j])
				acc += f64(input[s]) * (w0 + blend * (w1 - w0))
			}
		}
		out[n] = f32(acc)
	}

	return out
}
