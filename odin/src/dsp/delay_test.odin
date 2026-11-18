package dsp

import "core:math"
import "core:testing"

@(test)
delay_silence_in_silence_out :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)
	for _ in 0 ..< 10_000 {
		l, r := delay_process(&d, 0.0, 0.0)
		testing.expectf(t, l == 0.0 && r == 0.0, "silence produced %v %v", l, r)
	}
}

@(test)
delay_repeats_appear_at_the_delay_time :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 100.0
	params.feedback = 0.5
	params.ping_pong = false
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	delay_samples := 4_800
	first_echo := -1
	for i in 0 ..< 20_000 {
		x: f32 = 1.0 if i == 0 else 0.0
		l, _ := delay_process(&d, x, x)
		if abs(l) > 0.01 && first_echo < 0 && i > 10 {
			first_echo = i
		}
	}
	testing.expectf(t, first_echo >= 0, "no echo")
	testing.expectf(
		t,
		abs(first_echo - delay_samples) < 5,
		"echo at %d, expected %d",
		first_echo,
		delay_samples,
	)
}

// The read tap is fractional: a delay of 100.5 samples splits the impulse
// across the two neighbouring samples at half amplitude each.
@(test)
delay_fractional_tap_is_interpolated :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 100.5 / 48.0 // exactly 100.5 samples at 48 kHz
	params.feedback = 0.0
	params.ping_pong = false
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	got: [4]f32
	for i in 0 ..< 102 {
		x: f32 = 1.0 if i == 0 else 0.0
		l, _ := delay_process(&d, x, x)
		if i >= 99 && i <= 102 {
			got[i - 99] = l
		}
	}
	testing.expectf(t, abs(got[0]) < 1e-6, "pre-echo at 99: %v", got[0])
	testing.expectf(t, abs(got[1] - 0.5) < 1e-4, "tap at 100: %v", got[1])
	testing.expectf(t, abs(got[2] - 0.5) < 1e-4, "tap at 101: %v", got[2])
	testing.expectf(t, abs(got[3]) < 1e-6, "post-echo at 102: %v", got[3])
}

@(test)
delay_feedback_repeats_decay :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 100.0
	params.feedback = 0.6
	params.tone = 1.0
	params.ping_pong = false
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	peaks := [4]f32{}
	for i in 0 ..< 5 * 4_800 {
		x: f32 = 1.0 if i == 0 else 0.0
		l, _ := delay_process(&d, x, x)
		n := i / 4_800
		if n >= 1 && n <= 4 {
			peaks[n - 1] = max(peaks[n - 1], abs(l))
		}
	}
	testing.expectf(t, peaks[0] > 0.9, "first repeat %v", peaks[0])
	for n in 0 ..< 3 {
		testing.expectf(
			t,
			peaks[n + 1] < peaks[n],
			"repeat %d (%v) did not decay below %v",
			n + 2,
			peaks[n + 1],
			peaks[n],
		)
	}
	testing.expectf(t, peaks[3] > 0.01, "repeats died out too fast: %v", peaks[3])
}

// Ping-pong: the mono sum enters the left line, the left tap feeds the right
// line, the right tap feeds the left. So an impulse appears left at D and
// right at 2D, never the other way around.
@(test)
delay_ping_pong_alternates_lanes :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 100.0
	params.feedback = 0.5
	params.tone = 1.0
	params.ping_pong = true
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	d_samples := 4_800
	first_l, first_r: f32
	second_l, second_r: f32
	for i in 0 ..< 4 * d_samples {
		x: f32 = 1.0 if i == 0 else 0.0
		l, r := delay_process(&d, x, x)
		if i >= d_samples - 5 && i <= d_samples + 5 {
			first_l = max(first_l, abs(l))
			first_r = max(first_r, abs(r))
		}
		if i >= 2 * d_samples - 5 && i <= 2 * d_samples + 5 {
			second_l = max(second_l, abs(l))
			second_r = max(second_r, abs(r))
		}
	}
	testing.expectf(t, first_l > 0.9, "first repeat missing on the left: %v", first_l)
	testing.expectf(t, first_r < 0.01, "first repeat leaked to the right: %v", first_r)
	testing.expectf(t, second_r > 0.2, "ping-pong repeat missing on the right: %v", second_r)
	testing.expectf(t, second_l < 0.01, "ping-pong repeat leaked to the left: %v", second_l)
}

@(test)
delay_feedback_never_blows_up :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 10.0
	params.feedback = 0.9
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	peak: f32 = 0.0
	for i in 0 ..< 480_000 {
		x: f32 = 0.9 if i % 480 == 0 else 0.0
		l, r := delay_process(&d, x, x)
		peak = max(peak, abs(l), abs(r))
	}
	testing.expectf(t, !math.is_nan(peak) && !math.is_inf(peak), "delay diverged")
	testing.expectf(t, peak < 10.0, "delay runaway: %v", peak)
}

// A disabled delay, or one with a silent return, is a true bypass: it must not
// emit the wet signal or advance its lines.
@(test)
delay_disabled_is_a_bypass :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = false
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)
	for _ in 0 ..< 1_000 {
		l, r := delay_process(&d, 1.0, -1.0)
		testing.expectf(t, l == 0.0 && r == 0.0, "disabled delay emitted %v %v", l, r)
	}

	params.enabled = true
	params.return_level = 0.0
	silent := delay_new(FS, params)
	defer delay_destroy(&silent)
	for _ in 0 ..< 1_000 {
		l, r := delay_process(&silent, 1.0, -1.0)
		testing.expectf(t, l == 0.0 && r == 0.0, "silent return emitted %v %v", l, r)
	}
}

@(test)
delay_time_changes_glide :: proc(t: ^testing.T) {
	params := delay_params_default()
	params.enabled = true
	params.time_ms = 100.0
	params.feedback = 0.0
	params.ping_pong = false
	params.return_level = 1.0
	d := delay_new(FS, params)
	defer delay_destroy(&d)

	before := d.target_samples
	testing.expectf(t, abs(d.delay_samples - before) < 1e-4, "tap not initialised at target")

	params.time_ms = 900.0
	delay_update(&d, FS, params)
	testing.expectf(t, d.target_samples > before * 8.0, "target did not move: %v", d.target_samples)
	testing.expectf(
		t,
		abs(d.delay_samples - before) < 1e-4,
		"update moved the tap instantly: %v",
		d.delay_samples,
	)

	delay_process(&d, 0.0, 0.0)
	testing.expectf(
		t,
		d.delay_samples > before && d.delay_samples < before + 100.0,
		"tap jumped rather than glided: %v",
		d.delay_samples,
	)

	for _ in 0 ..< 20_000 {
		delay_process(&d, 0.0, 0.0)
	}
	testing.expectf(
		t,
		abs(d.delay_samples - d.target_samples) < 0.01 * d.target_samples,
		"tap never settled: %v -> %v",
		d.delay_samples,
		d.target_samples,
	)
}

@(test)
delay_params_are_sanitized :: proc(t: ^testing.T) {
	p := delay_params_sanitized(Delay_Params {
		time_ms = 0.0,
		feedback = 4.0,
		tone = -1.0,
		return_level = 2.0,
	})
	testing.expectf(t, p.time_ms == 1.0, "time_ms %v", p.time_ms)
	testing.expectf(t, p.feedback == 0.9, "feedback %v", p.feedback)
	testing.expectf(t, p.tone == 0.0, "tone %v", p.tone)
	testing.expectf(t, p.return_level == 1.0, "return_level %v", p.return_level)

	p = delay_params_sanitized(Delay_Params {
		time_ms = 5_000.0,
		feedback = -1.0,
		tone = 2.0,
		return_level = -1.0,
	})
	testing.expectf(t, p.time_ms == 2_000.0, "time_ms %v", p.time_ms)
	testing.expectf(t, p.feedback == 0.0, "feedback %v", p.feedback)
	testing.expectf(t, p.tone == 1.0, "tone %v", p.tone)
	testing.expectf(t, p.return_level == 0.0, "return_level %v", p.return_level)
}
