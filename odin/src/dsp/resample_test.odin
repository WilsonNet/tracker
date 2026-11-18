package dsp

import "core:math"
import "core:testing"

// Resampler tests use rates as plain integers so the arithmetic in the
// assertions stays exact.

@(test)
resample_identity_rate_copies_input :: proc(t: ^testing.T) {
	input := [6]f32{0.0, 0.25, -0.5, 1.0, -0.75, 0.125}
	out := resample(input[:], 48_000, 48_000)
	defer delete(out)

	testing.expectf(t, len(out) == len(input), "length %v, want %v", len(out), len(input))
	for i in 0 ..< min(len(out), len(input)) {
		testing.expectf(t, out[i] == input[i], "sample %d changed: %v != %v", i, out[i], input[i])
	}
	// The result is owned by the caller, not an alias of the input.
	out[0] = 99.0
	testing.expect(t, input[0] == 0.0, "identity result aliases the input")
}

@(test)
resample_lengths_follow_rate_ratio :: proc(t: ^testing.T) {
	up_in := make([]f32, 1_000)
	defer delete(up_in)
	up := resample(up_in, 24_000, 48_000)
	defer delete(up)
	testing.expectf(t, len(up) == 2_000, "24k -> 48k length %v, want 2000", len(up))

	down_in := make([]f32, 1_001)
	defer delete(down_in)
	down := resample(down_in, 48_000, 24_000)
	defer delete(down)
	// ceil(1001 / 2) = 501.
	testing.expectf(t, len(down) == 501, "48k -> 24k length %v, want 501", len(down))

	odd_in := make([]f32, 441)
	defer delete(odd_in)
	odd := resample(odd_in, 44_100, 48_000)
	defer delete(odd)
	// 441 * 48000 / 44100 = 480 exactly.
	testing.expectf(t, len(odd) == 480, "44.1k -> 48k length %v, want 480", len(odd))

	one := [1]f32{1.0}
	tiny := resample(one[:], 8_000, 48_000)
	defer delete(tiny)
	testing.expectf(t, len(tiny) == 6, "single sample length %v, want 6", len(tiny))
}

@(test)
resample_degenerate_inputs_are_empty :: proc(t: ^testing.T) {
	empty: []f32
	testing.expect(t, len(resample(empty, 48_000, 24_000)) == 0, "empty input should stay empty")

	one := [1]f32{1.0}
	testing.expect(t, len(resample(one[:], 0, 24_000)) == 0, "zero source rate should be empty")
	testing.expect(t, len(resample(one[:], 48_000, 0)) == 0, "zero destination rate should be empty")
	testing.expect(t, len(resample(one[:], 0, 0)) == 0, "both rates zero should be empty")
}

@(test)
resample_preserves_440_hz_when_downsampling :: proc(t: ^testing.T) {
	n := 48_000
	input := make([]f32, n)
	defer delete(input)
	for i in 0 ..< n {
		input[i] = math.sin(f32(i) * math.TAU * 440.0 / 48_000.0)
	}

	out := resample(input, 48_000, 24_000)
	defer delete(out)

	// Estimate the frequency from positive-going zero crossings, away from
	// the zero-padded edges of the output.
	first := -1
	last := -1
	crossings := 0
	for i in 129 ..< len(out) - 128 {
		if out[i - 1] <= 0.0 && out[i] > 0.0 {
			if first < 0 {
				first = i
			}
			last = i
			crossings += 1
		}
	}
	testing.expectf(t, crossings > 400, "only %v crossings", crossings)
	if first < 0 || last <= first {
		return
	}
	freq := f64(crossings - 1) * 24_000.0 / f64(last - first)
	testing.expectf(t, abs(freq - 440.0) < 0.5, "estimated %v Hz, want 440 Hz", freq)
}

@(test)
resample_passes_tone_below_new_nyquist :: proc(t: ^testing.T) {
	// 10 kHz at 48k -> 24k sits below the new 12 kHz Nyquist, so a correct
	// anti-aliasing filter passes it (with the expected passband droop).
	// Attenuating it by 30 dB would require a cutoff below 10 kHz, destroying
	// everything between 10 and 12 kHz.
	n := 48_000
	input := make([]f32, n)
	defer delete(input)
	for i in 0 ..< n {
		input[i] = 0.5 * math.sin(f32(i) * math.TAU * 10_000.0 / 48_000.0)
	}

	out := resample(input, 48_000, 24_000)
	defer delete(out)
	_, rms_db := peak_rms_db(out[256 : len(out) - 256], 1)
	attenuation := lin_to_db(0.35355339) - rms_db
	testing.expectf(t, abs(attenuation) < 3.0, "10 kHz level changed by %v dB", attenuation)
}

@(test)
resample_rejects_tone_above_new_nyquist :: proc(t: ^testing.T) {
	// 15 kHz at 48k -> 24k is above the new 12 kHz Nyquist. Without the
	// lowpass it would alias to 9 kHz at full level.
	n := 48_000
	input := make([]f32, n)
	defer delete(input)
	for i in 0 ..< n {
		input[i] = 0.5 * math.sin(f32(i) * math.TAU * 15_000.0 / 48_000.0)
	}

	out := resample(input, 48_000, 24_000)
	defer delete(out)
	_, rms_db := peak_rms_db(out[256 : len(out) - 256], 1)
	attenuation := lin_to_db(0.35355339) - rms_db
	testing.expectf(t, attenuation >= 30.0, "15 kHz attenuated by only %v dB", attenuation)
}

@(test)
resample_dc_has_unity_gain :: proc(t: ^testing.T) {
	input := make([]f32, 48_000)
	defer delete(input)
	for i in 0 ..< len(input) {
		input[i] = 0.8
	}

	rates := [3][2]u32{
		{48_000, 24_000},
		{48_000, 44_100},
		{8_000, 48_000},
	}
	for pair in rates {
		out := resample(input, pair[0], pair[1])
		defer delete(out)
		worst_db: f32 = 0.0
		for i in 256 ..< len(out) - 256 {
			worst_db = max(worst_db, abs(lin_to_db(out[i] / 0.8)))
		}
		testing.expectf(
			t,
			worst_db < 0.2,
			"DC gain deviates by %v dB at %v -> %v",
			worst_db,
			pair[0],
			pair[1],
		)
	}
}

@(test)
resample_random_input_stays_finite :: proc(t: ^testing.T) {
	n := 4_000
	input := make([]f32, n)
	defer delete(input)
	seed: u32 = 0x1234_5678
	for i in 0 ..< n {
		seed = seed * 1_664_525 + 1_013_904_223
		input[i] = (f32(seed >> 8) / 8_388_608.0) - 1.0
	}

	out := resample(input, 44_100, 48_000)
	defer delete(out)
	want := (n * 48_000 + 44_099) / 44_100
	testing.expectf(t, len(out) == want, "length %v, want %v", len(out), want)
	for y, i in out {
		testing.expectf(t, !math.is_nan(y) && !math.is_inf(y), "non-finite output at %d: %v", i, y)
	}
}

@(test)
resample_upsampling_does_not_explode :: proc(t: ^testing.T) {
	n := 8_000
	input := make([]f32, n)
	defer delete(input)
	in_peak: f32 = 0.0
	for i in 0 ..< n {
		input[i] = 0.9 * math.sin(f32(i) * math.TAU * 440.0 / 8_000.0)
		in_peak = max(in_peak, abs(input[i]))
	}

	out := resample(input, 8_000, 48_000)
	defer delete(out)
	testing.expectf(t, len(out) == 48_000, "length %v, want 48000", len(out))

	out_peak: f32 = 0.0
	for y in out {
		out_peak = max(out_peak, abs(y))
	}
	testing.expectf(
		t,
		out_peak <= in_peak * 1.1,
		"output peak %v exceeds 1.1 * input peak %v",
		out_peak,
		in_peak,
	)
}
