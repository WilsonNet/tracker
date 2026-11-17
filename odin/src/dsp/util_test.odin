package dsp

import "core:math"
import "core:testing"

@(test)
db_round_trip :: proc(t: ^testing.T) {
	values := [4]f32{-60.0, -12.0, 0.0, 6.0}
	for db in values {
		got := lin_to_db(db_to_lin(db))
		testing.expectf(t, abs(got - db) < 1e-4, "db %v round-tripped to %v", db, got)
	}
}

@(test)
soft_clip_is_bounded_and_monotonic :: proc(t: ^testing.T) {
	c: f32 = 0.966
	prev: f32 = -1e9
	for i in -200 ..= 200 {
		y := soft_clip(f32(i) / 100.0, c)
		testing.expectf(t, abs(y) <= c + 1e-5, "soft_clip exceeded ceiling at i=%d: %v", i, y)
		testing.expectf(t, y >= prev, "soft_clip not monotonic at i=%d: %v < %v", i, y, prev)
		prev = y
	}
	testing.expect(t, abs(soft_clip(0.1, c) - 0.1) < 1e-6, "not transparent below knee")
	testing.expect(t, abs(soft_clip(0.5, c) - 0.5) < 1e-6, "not transparent at half ceiling")
	testing.expect(t, abs(soft_clip(c, c) - c) < 1e-6, "ceiling not reached")
	testing.expect(t, abs(soft_clip(-c, c) + c) < 1e-6, "negative ceiling not reached")
	testing.expect(t, soft_clip(4.0, c) <= c, "overshoot not clamped")
}

@(test)
peak_rms_of_silence_is_floored :: proc(t: ^testing.T) {
	buf := make([]f32, 64)
	defer delete(buf)
	peak, rms := peak_rms_db(buf, 1)
	testing.expect(t, peak <= -120.0 && rms <= -120.0, "silence should floor at -120 dB")
}

@(test)
peak_rms_matches_known_sine :: proc(t: ^testing.T) {
	// 1 kHz at 0.5 amplitude: peak -6.021 dBFS, RMS -9.031 dBFS.
	n := 48_000
	buf := make([]f32, n)
	defer delete(buf)
	for i in 0 ..< n {
		buf[i] = 0.5 * math.sin(f32(i) * math.TAU * 1000.0 / 48000.0)
	}
	peak, rms := peak_rms_db(buf, 1)
	testing.expectf(t, abs(peak + 6.0206) < 0.05, "peak %v", peak)
	testing.expectf(t, abs(rms + 9.0309) < 0.05, "rms %v", rms)
}
