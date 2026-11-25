package dsp

import "core:math"
import "core:testing"

FS: f32 = 48_000.0

@(private)
db_of :: proc(x: f32) -> f32 {
	return 20.0 * math.log10(max(x, 1e-12))
}

@(test)
peaking_boosts_at_center :: proc(t: ^testing.T) {
	f := biquad_peaking(FS, 1_000.0, 1.0, 6.0)
	got := db_of(biquad_magnitude_at(&f, FS, 1_000.0))
	testing.expectf(t, abs(got - 6.0) < 0.15, "center gain %v", got)
	testing.expectf(t, abs(db_of(biquad_magnitude_at(&f, FS, 20.0))) < 0.5, "low end not transparent")
	testing.expectf(t, abs(db_of(biquad_magnitude_at(&f, FS, 20_000.0))) < 0.5, "high end not transparent")
}

@(test)
shelves_reach_target_gain :: proc(t: ^testing.T) {
	low := biquad_low_shelf(FS, 120.0, 9.0, 1.0)
	testing.expectf(t, abs(db_of(biquad_magnitude_at(&low, FS, 20.0)) - 9.0) < 0.6, "low shelf")
	high := biquad_high_shelf(FS, 8_000.0, -6.0, 1.0)
	testing.expectf(t, abs(db_of(biquad_magnitude_at(&high, FS, 20_000.0)) + 6.0) < 0.8, "high shelf")
}

@(test)
flat_settings_are_transparent :: proc(t: ^testing.T) {
	f := biquad_peaking(FS, 1_000.0, 1.0, 0.0)
	freqs := [5]f32{30.0, 100.0, 1_000.0, 10_000.0, 18_000.0}
	for freq in freqs {
		testing.expectf(t, abs(db_of(biquad_magnitude_at(&f, FS, freq))) < 0.01, "not flat at %v Hz", freq)
	}
}

@(test)
stays_finite_on_noise_burst :: proc(t: ^testing.T) {
	f := biquad_high_shelf(FS, 8_000.0, 12.0, 1.0)
	seed: u32 = 0x1234_5678
	for i in 0 ..< 48_000 {
		seed = seed * 1_664_525 + 1_013_904_223
		x := (f32(seed >> 8) / 8_388_608.0) - 1.0
		y := biquad_process(&f, x)
		testing.expectf(t, !math.is_nan(y) && !math.is_inf(y), "diverged at sample %d: %v", i, y)
	}
}

@(test)
biquad_high_pass_rejects_dc_and_passes_highs :: proc(t: ^testing.T) {
	f := biquad_high_pass(FS, 280.0, 0.7071)
	dc_out: f32 = 0
	for _ in 0 ..< 4_800 {
		dc_out = biquad_process(&f, 1.0)
	}
	testing.expectf(t, abs(dc_out) < 1e-3, "DC not attenuated: %v", dc_out)

	mag_high := biquad_magnitude_at(&f, FS, 4_000.0)
	testing.expectf(t, mag_high > 0.98, "4 kHz magnitude too low: %v", mag_high)
	mag_low := biquad_magnitude_at(&f, FS, 60.0)
	testing.expectf(t, mag_low < 0.06, "60 Hz magnitude too high: %v", mag_low)
}
