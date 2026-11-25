// Real-time transient onset detector and tap-tempo estimator for hand claps
// and guitar hits/strums. Runs inside the audio callback (proc "contextless",
// zero heap allocation).

package dsp

import "core:math"

Tempo_Sensitivity :: enum u8 {
	Low,
	Med,
	High,
}

TEMPO_MAX_CHANNELS :: 16
TEMPO_MAX_INTERVALS :: 8
TEMPO_MIN_BPM :: 40
TEMPO_MAX_BPM :: 240
TEMPO_HPF_HZ :: f32(420.0)
TEMPO_WARMUP_SECONDS :: f32(0.030)
TEMPO_LOCKOUT_SECONDS :: f32(0.210)
TEMPO_MIN_INTERVAL_S :: f64(0.220)
TEMPO_MAX_INTERVAL_S :: f64(1.650)
TEMPO_GAP_RESET_S :: f64(1.850)

Tempo_Detector :: struct {
	rate:            f32,
	sensitivity:     Tempo_Sensitivity,
	hpf:             [TEMPO_MAX_CHANNELS]Biquad,
	fast_attack_c:   f32,
	fast_release_c:  f32,
	slow_attack_c:   f32,
	slow_release_c:  f32,
	warmup_c:        f32,
	env_fast:        f32,
	env_slow:        f32,
	last_thresh:     f32,
	armed:           bool,
	warmup_samples:  int,
	warmup_left:     int,
	lockout_samples: int,
	lockout_left:    int,
	total_samples:   u64,
	has_last_hit:    bool,
	last_hit_sample: u64,
	intervals:       [TEMPO_MAX_INTERVALS]f64,
	interval_count:  int,
	hit_count:       int,
	hit_seq:         u32,
	bpm:             int,
	bpm_exact:       f32,
}

@(private)
tempo_sens_params :: proc "contextless" (s: Tempo_Sensitivity) -> (floor, ratio, rearm_ratio: f32) {
	switch s {
	case .Low:
		return 0.080, 2.60, 1.45
	case .Med:
		return 0.032, 2.00, 1.30
	case .High:
		return 0.012, 1.65, 1.20
	}
	return 0.032, 2.00, 1.30
}

// Initializes `d` for `rate` Hz. Safe from audio callbacks.
tempo_detector_init :: proc "contextless" (d: ^Tempo_Detector, rate: u32, sens: Tempo_Sensitivity = .Med) {
	if d == nil {
		return
	}
	r := rate if rate != 0 else 48_000
	fs := clamp(f32(r), 8_000.0, 384_000.0)
	d^ = {}
	d.rate = fs
	d.sensitivity = sens
	hpf := biquad_high_pass(fs, TEMPO_HPF_HZ, 0.7071)
	for i in 0 ..< TEMPO_MAX_CHANNELS {
		d.hpf[i] = hpf
	}
	d.fast_attack_c = math.exp(-1.0 / (0.0015 * fs))
	d.fast_release_c = math.exp(-1.0 / (0.025 * fs))
	d.slow_attack_c = math.exp(-1.0 / (0.080 * fs))
	d.slow_release_c = math.exp(-1.0 / (0.250 * fs))
	d.warmup_c = math.exp(-1.0 / (0.008 * fs))
	d.warmup_samples = max(int(TEMPO_WARMUP_SECONDS * fs), 1)
	d.warmup_left = d.warmup_samples
	d.lockout_samples = max(int(TEMPO_LOCKOUT_SECONDS * fs), 1)
	floor, _, _ := tempo_sens_params(sens)
	d.last_thresh = floor
	d.armed = true
}

// Clears accumulated hits and envelope history while preserving sample rate,
// sensitivity, filter coefficients, `hit_seq`, and `total_samples`.
tempo_detector_reset :: proc "contextless" (d: ^Tempo_Detector) {
	if d == nil {
		return
	}
	for i in 0 ..< TEMPO_MAX_CHANNELS {
		biquad_reset(&d.hpf[i])
	}
	floor, _, _ := tempo_sens_params(d.sensitivity)
	d.env_fast = 0
	d.env_slow = 0
	d.last_thresh = floor
	d.armed = true
	d.warmup_left = d.warmup_samples
	d.lockout_left = 0
	d.has_last_hit = false
	d.last_hit_sample = 0
	d.interval_count = 0
	d.hit_count = 0
	d.bpm = 0
	d.bpm_exact = 0
}

tempo_detector_set_sensitivity :: proc "contextless" (d: ^Tempo_Detector, sens: Tempo_Sensitivity) {
	if d == nil {
		return
	}
	d.sensitivity = sens
}

@(private)
tempo_median_sorted :: proc "contextless" (intervals: []f64) -> f64 {
	buf: [TEMPO_MAX_INTERVALS]f64
	n := min(len(intervals), TEMPO_MAX_INTERVALS)
	if n <= 0 {
		return 0
	}
	for i in 0 ..< n {
		buf[i] = intervals[i]
	}
	for i in 1 ..< n {
		v := buf[i]
		j := i - 1
		for j >= 0 && buf[j] > v {
			buf[j + 1] = buf[j]
			j -= 1
		}
		buf[j + 1] = v
	}
	if n % 2 == 1 {
		return buf[n / 2]
	}
	return 0.5 * (buf[n / 2 - 1] + buf[n / 2])
}

// Computes BPM from recent inter-onset intervals using a median-trimmed mean
// so a single missed beat or double hit does not skew the result.
tempo_estimate_bpm :: proc "contextless" (intervals: []f64) -> (bpm: int, exact: f32) {
	n := min(len(intervals), TEMPO_MAX_INTERVALS)
	if n <= 0 {
		return 0, 0
	}
	med := tempo_median_sorted(intervals[:n])
	if med <= 0 {
		return 0, 0
	}
	sum: f64 = 0
	kept := 0
	for i in 0 ..< n {
		iv := intervals[i]
		if abs(iv - med) <= med * 0.25 {
			sum += iv
			kept += 1
		}
	}
	mean_iv := sum / f64(kept) if kept > 0 else med
	if mean_iv <= 0 {
		return 0, 0
	}
	exact = f32(60.0 / mean_iv)
	bpm = clamp(int(math.round(exact)), TEMPO_MIN_BPM, TEMPO_MAX_BPM)
	return bpm, exact
}

// Registers a discrete onset at `sample_pos`, updating the interval window and
// estimated BPM. Exposed for both audio-driven and unit-test callers.
tempo_detector_record_hit :: proc "contextless" (d: ^Tempo_Detector, sample_pos: u64) {
	if d == nil || d.rate <= 0 {
		return
	}
	if !d.has_last_hit {
		d.has_last_hit = true
		d.last_hit_sample = sample_pos
		d.hit_count = 1
		d.interval_count = 0
		d.bpm = 0
		d.bpm_exact = 0
		d.hit_seq += 1
		return
	}
	if sample_pos <= d.last_hit_sample {
		return
	}
	dt := f64(sample_pos - d.last_hit_sample) / f64(d.rate)
	if dt > TEMPO_GAP_RESET_S || dt > TEMPO_MAX_INTERVAL_S {
		d.last_hit_sample = sample_pos
		d.hit_count = 1
		d.interval_count = 0
		d.bpm = 0
		d.bpm_exact = 0
		d.hit_seq += 1
		return
	}
	if dt < TEMPO_MIN_INTERVAL_S {
		return
	}

	if d.interval_count >= 2 {
		prev_med := tempo_median_sorted(d.intervals[:d.interval_count])
		prev_iv := d.intervals[d.interval_count - 1]
		if abs(dt - prev_med) > prev_med * 0.25 &&
		   abs(prev_iv - prev_med) > prev_med * 0.25 &&
		   abs(dt - prev_iv) <= prev_iv * 0.15 {
			d.intervals[0] = prev_iv
			d.intervals[1] = dt
			d.interval_count = 2
			d.hit_count = 3
			d.last_hit_sample = sample_pos
			d.hit_seq += 1
			d.bpm, d.bpm_exact = tempo_estimate_bpm(d.intervals[:d.interval_count])
			return
		}
	}

	if d.interval_count < TEMPO_MAX_INTERVALS {
		d.intervals[d.interval_count] = dt
		d.interval_count += 1
	} else {
		for i in 1 ..< TEMPO_MAX_INTERVALS {
			d.intervals[i - 1] = d.intervals[i]
		}
		d.intervals[TEMPO_MAX_INTERVALS - 1] = dt
	}
	d.hit_count += 1
	d.last_hit_sample = sample_pos
	d.hit_seq += 1
	d.bpm, d.bpm_exact = tempo_estimate_bpm(d.intervals[:d.interval_count])
}

// Feeds an interleaved audio block into the onset detector. `chan_mask == 0`
// listens across all channels up to `TEMPO_MAX_CHANNELS`; otherwise only bits set
// in `chan_mask` contribute. Returns true if at least one onset triggered.
tempo_detector_process :: proc "contextless" (
	d: ^Tempo_Detector,
	interleaved: []f32,
	frames, channels: int,
	chan_mask: u32 = 0,
) -> (triggered: bool) {
	if d == nil || d.rate <= 0 || channels <= 0 || frames <= 0 {
		return false
	}
	ch_n := min(channels, TEMPO_MAX_CHANNELS)
	floor, ratio, rearm_ratio := tempo_sens_params(d.sensitivity)
	for f in 0 ..< frames {
		base := f * channels
		mag: f32 = 0
		for c in 0 ..< ch_n {
			if chan_mask != 0 && (chan_mask & (1 << u32(c))) == 0 {
				continue
			}
			idx := base + c
			if idx >= len(interleaved) {
				break
			}
			y := biquad_process(&d.hpf[c], interleaved[idx])
			if a := abs(y); a > mag {
				mag = a
			}
		}

		c_fast := d.fast_attack_c if mag > d.env_fast else d.fast_release_c
		d.env_fast = flush_denormal(c_fast * d.env_fast + (1.0 - c_fast) * mag)
		if d.warmup_left > 0 {
			d.env_slow = flush_denormal(d.warmup_c * d.env_slow + (1.0 - d.warmup_c) * mag)
			d.warmup_left -= 1
			thresh := max(d.env_slow * ratio + floor * 0.4, floor)
			d.last_thresh = thresh
			d.total_samples += 1
			continue
		}
		c_slow := d.slow_attack_c if mag > d.env_slow else d.slow_release_c
		d.env_slow = flush_denormal(c_slow * d.env_slow + (1.0 - c_slow) * mag)

		thresh := max(d.env_slow * ratio + floor * 0.4, floor)
		rearm := max(d.env_slow * rearm_ratio + floor * 0.25, floor * 0.7)
		d.last_thresh = thresh

		if d.lockout_left > 0 {
			d.lockout_left -= 1
		} else if !d.armed {
			if d.env_fast < rearm {
				d.armed = true
			}
		} else if d.env_fast > thresh {
			d.armed = false
			d.lockout_left = d.lockout_samples
			tempo_detector_record_hit(d, d.total_samples)
			triggered = true
		}

		d.total_samples += 1
	}
	return triggered
}

tempo_detector_silence_ms :: proc "contextless" (d: ^Tempo_Detector) -> u32 {
	if d == nil || !d.has_last_hit || d.rate <= 0 || d.total_samples <= d.last_hit_sample {
		return 0
	}
	ms := (d.total_samples - d.last_hit_sample) * 1000 / u64(d.rate)
	return u32(min(ms, u64(60_000)))
}
