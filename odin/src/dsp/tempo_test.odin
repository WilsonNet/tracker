package dsp

import "core:math"
import "core:testing"

@(private)
tempo_synth_claps :: proc(buf: []f32, rate: int, period_s: f64, count: int, amp: f32 = 0.85) {
	burst_len := max(int(0.015 * f32(rate)), 1)
	seed: u32 = 0x51a7_9001
	for b in 0 ..< count {
		start := int(f64(b) * period_s * f64(rate)) + int(0.05 * f32(rate))
		for i in 0 ..< burst_len {
			idx := start + i
			if idx >= len(buf) {
				break
			}
			seed = seed * 1_664_525 + 1_013_904_223
			noise := (f32(seed >> 8) / 8_388_608.0) - 1.0
			env := math.exp(-f32(i) / (0.004 * f32(rate)))
			buf[idx] += amp * env * noise
		}
	}
}

@(private)
tempo_feed_blocks :: proc(d: ^Tempo_Detector, mono: []f32, block_frames: int = 512) {
	for off := 0; off < len(mono); off += block_frames {
		n := min(block_frames, len(mono) - off)
		_ = tempo_detector_process(d, mono[off:off + n], n, 1)
	}
}

@(test)
tempo_detects_steady_claps_120_bpm :: proc(t: ^testing.T) {
	rate := 48_000
	d: Tempo_Detector
	tempo_detector_init(&d, u32(rate), .Med)

	buf := make([]f32, rate * 3)
	defer delete(buf)
	tempo_synth_claps(buf, rate, 0.500, 4)
	tempo_feed_blocks(&d, buf)

	testing.expectf(t, d.hit_count == 4, "expected 4 hits, got %d", d.hit_count)
	testing.expectf(t, d.bpm == 120, "expected 120 BPM, got %d (exact %.2f)", d.bpm, d.bpm_exact)
}

@(test)
tempo_detects_slow_and_fast_across_rates :: proc(t: ^testing.T) {
	// 60 BPM at 48 kHz
	{
		rate := 48_000
		d: Tempo_Detector
		tempo_detector_init(&d, u32(rate), .Med)
		buf := make([]f32, rate * 5)
		defer delete(buf)
		tempo_synth_claps(buf, rate, 1.000, 4)
		tempo_feed_blocks(&d, buf)
		testing.expectf(t, abs(d.bpm - 60) <= 1, "60 BPM got %d", d.bpm)
	}
	// 180 BPM at 44.1 kHz
	{
		rate := 44_100
		d: Tempo_Detector
		tempo_detector_init(&d, u32(rate), .Med)
		buf := make([]f32, rate * 3)
		defer delete(buf)
		tempo_synth_claps(buf, rate, 1.0 / 3.0, 5)
		tempo_feed_blocks(&d, buf)
		testing.expectf(t, abs(d.bpm - 180) <= 2, "180 BPM at 44.1k got %d", d.bpm)
	}
}

@(test)
tempo_detects_guitar_strums_over_ringing_sustain :: proc(t: ^testing.T) {
	rate := 48_000
	d: Tempo_Detector
	tempo_detector_init(&d, u32(rate), .Med)

	buf := make([]f32, rate * 3)
	defer delete(buf)
	// Ringing low/mid guitar chord sustain (110 Hz + 220 Hz) underneath sharp pick attacks every 0.5 s.
	for i in 0 ..< len(buf) {
		tt := f32(i) / f32(rate)
		sustain := 0.22 * math.sin(math.TAU * 110.0 * tt) + 0.14 * math.sin(math.TAU * 220.0 * tt)
		buf[i] = sustain
	}
	for b in 0 ..< 4 {
		start := int(f64(b) * 0.500 * f64(rate)) + int(0.05 * f32(rate))
		for i in 0 ..< int(0.060 * f32(rate)) {
			idx := start + i
			if idx >= len(buf) {
				break
			}
			tt := f32(i) / f32(rate)
			pick := math.exp(-tt / 0.008) * (0.45 * math.sin(math.TAU * 1_800.0 * tt) + 0.35 * math.sin(math.TAU * 3_100.0 * tt))
			buf[idx] += pick
		}
	}
	tempo_feed_blocks(&d, buf)

	testing.expectf(t, d.hit_count == 4, "expected 4 guitar strums, got %d", d.hit_count)
	testing.expectf(t, abs(d.bpm - 120) <= 1, "guitar strum BPM got %d", d.bpm)
}

@(test)
tempo_rejects_clap_slapback_echo_and_hum :: proc(t: ^testing.T) {
	rate := 48_000
	d: Tempo_Detector
	tempo_detector_init(&d, u32(rate), .Med)

	buf := make([]f32, rate * 3)
	defer delete(buf)
	// Continuous 60 Hz mains hum.
	for i in 0 ..< len(buf) {
		buf[i] = 0.08 * math.sin(math.TAU * 60.0 * f32(i) / f32(rate))
	}
	// Primary claps at 120 BPM + 45 ms room echo bursts.
	tempo_synth_claps(buf, rate, 0.500, 4, 0.85)
	echo_offset := int(0.045 * f32(rate))
	tempo_synth_claps(buf[echo_offset:], rate, 0.500, 4, 0.40)

	tempo_feed_blocks(&d, buf)
	testing.expectf(t, d.hit_count == 4, "slapback echo should not double-trigger, got %d hits", d.hit_count)
	testing.expectf(t, d.bpm == 120, "expected 120 BPM with echo+hum, got %d", d.bpm)
}

@(test)
tempo_rejects_skipped_beat_outlier :: proc(t: ^testing.T) {
	d: Tempo_Detector
	tempo_detector_init(&d, 48_000, .Med)

	// Hits at 0.0s, 0.5s, 1.0s, (skip 1.5s), 2.0s, 2.5s -> intervals 0.5, 0.5, 1.0, 0.5.
	times := [5]f64{0.0, 0.5, 1.0, 2.0, 2.5}
	for s in times {
		tempo_detector_record_hit(&d, u64(s * 48_000.0))
	}
	testing.expectf(t, d.bpm == 120, "outlier interval should be rejected, got %d", d.bpm)
}

@(test)
tempo_adapts_to_midstream_tempo_change :: proc(t: ^testing.T) {
	d: Tempo_Detector
	tempo_detector_init(&d, 48_000, .Med)

	pos: u64 = 0
	// 3 beats at 90 BPM (0.6667 s).
	for _ in 0 ..< 4 {
		tempo_detector_record_hit(&d, pos)
		pos += u64(math.round((60.0 / 90.0) * 48_000.0))
	}
	testing.expectf(t, abs(d.bpm - 90) <= 1, "expected ~90 BPM first, got %d", d.bpm)

	// Switch cleanly to 140 BPM (0.4286 s) for 4 beats.
	for _ in 0 ..< 4 {
		tempo_detector_record_hit(&d, pos)
		pos += u64(math.round((60.0 / 140.0) * 48_000.0))
	}
	testing.expectf(t, abs(d.bpm - 140) <= 1, "expected ~140 BPM after change, got %d", d.bpm)
}

@(test)
tempo_channel_mask_and_sensitivity_and_gap_reset :: proc(t: ^testing.T) {
	rate := 48_000
	d: Tempo_Detector
	tempo_detector_init(&d, u32(rate), .High)

	// 2-channel interleaved buffer: clap only on channel 1 (right), silence on channel 0.
	mono := make([]f32, rate * 2)
	defer delete(mono)
	tempo_synth_claps(mono, rate, 0.500, 3, 0.06) // soft claps requiring High sensitivity
	stereo := make([]f32, len(mono) * 2)
	defer delete(stereo)
	for i in 0 ..< len(mono) {
		stereo[i * 2 + 1] = mono[i]
	}

	// Mask channel 0 only: nothing should trigger.
	_ = tempo_detector_process(&d, stereo, len(mono), 2, 1 << 0)
	testing.expectf(t, d.hit_count == 0, "masked ch0 should see 0 hits, got %d", d.hit_count)

	// Mask channel 1: soft claps trigger cleanly on High sensitivity.
	tempo_detector_reset(&d)
	_ = tempo_detector_process(&d, stereo, len(mono), 2, 1 << 1)
	testing.expectf(t, d.hit_count == 3 && d.bpm == 120, "ch1 soft claps got %d hits, %d BPM", d.hit_count, d.bpm)

	// Low sensitivity rejects the soft 0.06 burst.
	tempo_detector_reset(&d)
	tempo_detector_set_sensitivity(&d, .Low)
	_ = tempo_detector_process(&d, stereo, len(mono), 2, 1 << 1)
	testing.expectf(t, d.hit_count == 0, "Low sensitivity should ignore soft 0.06 noise, got %d", d.hit_count)

	// Gap > 1.85 s resets the hit sequence.
	tempo_detector_reset(&d)
	tempo_detector_record_hit(&d, 0)
	tempo_detector_record_hit(&d, u64(0.5 * f64(rate)))
	testing.expect(t, d.hit_count == 2 && d.bpm == 120, "two hits establish 120 BPM")
	tempo_detector_record_hit(&d, u64(2.6 * f64(rate))) // 2.1 s gap
	testing.expectf(t, d.hit_count == 1 && d.bpm == 0, "gap > 1.85s should reset sequence (hits=%d bpm=%d)", d.hit_count, d.bpm)
}
