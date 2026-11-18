// 8-line feedback delay network reverb.
//
// Topology (the one used by most modern algorithmic reverbs): pre-delay →
// four input allpasses → eight prime-numbered delay lines → per-line damping →
// an orthogonal 8×8 Householder feedback matrix → two decorrelated stereo taps.
//
// Why not Freeverb: its eight parallel combs ring metallically and its "size"
// is only a feedback change. Why not Dattorro: no honest size control, and the
// signed taps are easy to get subtly wrong. The FDN costs about the same CPU
// and gives a real room-size knob plus an exact RT60.
//
// Algorithms are public-domain math (Householder matrices, Schroeder allpass,
// Jot/Smith FDN design). No GPL code involved.
//
// Ported from src-tauri/src/audio/fx/reverb.rs. Sample-for-sample identical to
// the Rust reference so the Odin engine can be A/B checked against it.

package dsp

import "core:math"

REVERB_N :: 8
// Prime-ish line lengths at 48 kHz (31–86 ms), coprime to avoid coincident
// echoes. Scaled by the size knob.
REVERB_BASE_LEN := [REVERB_N]int{1499, 1823, 2099, 2399, 2741, 3137, 3593, 4127}
// Input diffusion (Dattorro allpass lengths, scaled from 29.761 kHz to 48 kHz).
REVERB_AP_COUNT :: 4
REVERB_AP_LEN := [REVERB_AP_COUNT]int{229, 173, 611, 447}
REVERB_AP_GAIN := [REVERB_AP_COUNT]f32{0.75, 0.75, 0.625, 0.625}
// Zero-sum injection: never excite the all-ones mode (it would ring forever).
REVERB_INJECTION := [REVERB_N]f32{1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0}
// Two orthogonal tap patterns → decorrelated left/right tails.
REVERB_TAP_L := [REVERB_N]f32{1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0}
REVERB_TAP_R := [REVERB_N]f32{1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0}
REVERB_MOD_DEPTH :: 4.0
REVERB_MAX_PREDELAY_SECONDS :: 0.2

Reverb_Params :: struct {
	enabled:      bool `json:"enabled"`,
	// Room size, 0..1. Scales the delay lengths (small club → hall).
	size:         f32  `json:"size"`,
	// Decay, 0..1. Maps to RT60.
	decay:        f32  `json:"decay"`,
	// Tone, 0..1. 0 = dark tail, 1 = bright.
	tone:         f32  `json:"tone"`,
	predelay_ms:  f32  `json:"predelayMs"`,
	// Wet return level, 0..1 (this is a send bus, so it is wet only).
	return_level: f32  `json:"returnLevel"`,
}

reverb_params_default :: proc() -> Reverb_Params {
	return Reverb_Params {
		enabled = false,
		size = 0.62,
		decay = 0.55,
		tone = 0.55,
		predelay_ms = 18.0,
		return_level = 0.45,
	}
}

reverb_params_sanitized :: proc(p: Reverb_Params) -> Reverb_Params {
	s := p
	s.size = clamp(s.size, 0.0, 1.0)
	s.decay = clamp(s.decay, 0.0, 1.0)
	s.tone = clamp(s.tone, 0.0, 1.0)
	s.predelay_ms = clamp(s.predelay_ms, 0.0, REVERB_MAX_PREDELAY_SECONDS * 1_000.0)
	s.return_level = clamp(s.return_level, 0.0, 1.0)
	return s
}

// Exact RT60 in seconds, from the decay knob.
reverb_rt60_seconds :: proc(p: Reverb_Params) -> f32 {
	return 0.3 * math.pow(60.0, p.decay)
}

// Room scale applied to the line lengths.
reverb_size_scale :: proc(p: Reverb_Params) -> f32 {
	return 0.25 * math.pow(4.0, p.size)
}

// `flush_denormal` is file-private in util.odin, so this module keeps its own
// copy rather than widening the shared helper's visibility.
@(private)
reverb_flush_denormal :: proc(x: f32) -> f32 {
	return 0.0 if abs(x) < 1e-20 else x
}

@(private)
Reverb_Line :: struct {
	buffer: []f32,
	length: int,
	write:  int,
}

@(private)
reverb_line_new :: proc(max_len: int) -> Reverb_Line {
	return Reverb_Line {
		buffer = make([]f32, max(max_len, 2)),
		length = 1,
		write = 0,
	}
}

@(private)
reverb_line_configure :: proc(line: ^Reverb_Line, length: int) {
	new_length := clamp(length, 2, len(line.buffer))
	if new_length != line.length {
		for i in 0 ..< len(line.buffer) {
			line.buffer[i] = 0.0
		}
		line.write = 0
		line.length = new_length
	}
}

@(private)
reverb_line_read :: proc(line: ^Reverb_Line, delay: f32) -> f32 {
	d := clamp(delay, 1.0, f32(line.length - 2))
	whole := int(d)
	frac := d - f32(whole)
	i0 := (line.write + line.length - whole) % line.length
	i1 := (line.write + line.length - whole - 1) % line.length
	return line.buffer[i0] * (1.0 - frac) + line.buffer[i1] * frac
}

@(private)
reverb_line_write :: proc(line: ^Reverb_Line, x: f32) {
	line.buffer[line.write] = reverb_flush_denormal(x)
	line.write += 1
	if line.write >= line.length {
		line.write = 0
	}
}

@(private)
Reverb_Allpass :: struct {
	buffer: []f32,
	index:  int,
	length: int,
	gain:   f32,
}

@(private)
reverb_allpass_new :: proc(max_len: int, gain: f32) -> Reverb_Allpass {
	return Reverb_Allpass {
		buffer = make([]f32, max(max_len, 2)),
		index = 0,
		length = 1,
		gain = gain,
	}
}

@(private)
reverb_allpass_configure :: proc(ap: ^Reverb_Allpass, length: int) {
	new_length := clamp(length, 2, len(ap.buffer))
	if new_length != ap.length {
		for i in 0 ..< len(ap.buffer) {
			ap.buffer[i] = 0.0
		}
		ap.index = 0
		ap.length = new_length
	}
}

@(private)
reverb_allpass_process :: proc(ap: ^Reverb_Allpass, input: f32) -> f32 {
	delayed := ap.buffer[ap.index]
	output := delayed - ap.gain * input
	ap.buffer[ap.index] = reverb_flush_denormal(input + ap.gain * output)
	ap.index += 1
	if ap.index >= ap.length {
		ap.index = 0
	}
	return output
}

Reverb :: struct {
	lines:           [REVERB_N]Reverb_Line,
	allpasses:       [REVERB_AP_COUNT]Reverb_Allpass,
	predelay:        []f32,
	predelay_write:  int,
	predelay_length: int,
	damping:         [REVERB_N]f32,
	gains:           [REVERB_N]f32,
	phases:          [REVERB_N]f32,
	phase_inc:       [REVERB_N]f32,
	length:          [REVERB_N]int,
	damp_coeff:      f32,
	input_gain:      f32,
	params:          Reverb_Params,
	sample_rate:     f32,
}

reverb_new :: proc(sample_rate: f32, params: Reverb_Params) -> Reverb {
	p := reverb_params_sanitized(params)
	max_len := int(f32(REVERB_BASE_LEN[REVERB_N - 1]) * sample_rate / 48_000.0 * 1.1) + 16
	max_predelay := int(REVERB_MAX_PREDELAY_SECONDS * sample_rate) + 4

	r := Reverb {
		predelay = make([]f32, max_predelay),
		predelay_write = 0,
		predelay_length = 1,
		damp_coeff = 1.0,
		input_gain = 0.1,
		params = p,
		sample_rate = sample_rate,
	}

	for i in 0 ..< REVERB_N {
		r.lines[i] = reverb_line_new(max_len)
		r.length[i] = 1
	}
	for i in 0 ..< REVERB_AP_COUNT {
		ap_max := int(f32(REVERB_AP_LEN[i]) * sample_rate / 48_000.0 * 1.1) + 4
		r.allpasses[i] = reverb_allpass_new(ap_max, REVERB_AP_GAIN[i])
	}

	// Each line modulates at a different slow rate (0.31–1.37 Hz).
	for i in 0 ..< REVERB_N {
		r.phase_inc[i] = f32(math.TAU) * (0.31 + 0.15 * f32(i)) / sample_rate
		r.phases[i] = f32(i) * 0.7
	}

	reverb_update(&r, sample_rate, p)
	return r
}

reverb_destroy :: proc(r: ^Reverb) {
	for i in 0 ..< REVERB_N {
		delete(r.lines[i].buffer)
		r.lines[i].buffer = nil
	}
	for i in 0 ..< REVERB_AP_COUNT {
		delete(r.allpasses[i].buffer)
		r.allpasses[i].buffer = nil
	}
	delete(r.predelay)
	r.predelay = nil
}

reverb_update :: proc(r: ^Reverb, sample_rate: f32, params: Reverb_Params) {
	r.sample_rate = sample_rate
	r.params = reverb_params_sanitized(params)
	p := r.params
	scale := reverb_size_scale(p) * sample_rate / 48_000.0
	rt60 := reverb_rt60_seconds(p)

	for i in 0 ..< REVERB_N {
		line_length := int(math.round(f32(REVERB_BASE_LEN[i]) * scale))
		r.length[i] = max(line_length, 8)
		reverb_line_configure(&r.lines[i], r.length[i])
		// Exact RT60: amplitude falls 60 dB over `rt60` seconds.
		loop_seconds := f32(r.length[i]) / sample_rate
		r.gains[i] = math.pow(10.0, -3.0 * loop_seconds / rt60)
	}

	for i in 0 ..< REVERB_AP_COUNT {
		ap_length := int(math.round(f32(REVERB_AP_LEN[i]) * scale * 1.15))
		reverb_allpass_configure(&r.allpasses[i], ap_length)
	}

	fc := 500.0 * math.pow(40.0, p.tone)
	r.damp_coeff = 1.0 - math.exp(-f32(math.TAU) * fc / sample_rate)
	r.predelay_length = clamp(int(p.predelay_ms * 0.001 * sample_rate), 1, len(r.predelay))

	// Compensate the network's 1/(1−g) buildup so the send stays level
	// across decay settings.
	mean_gain: f32 = 0.0
	for g in r.gains {
		mean_gain += g
	}
	mean_gain /= f32(REVERB_N)
	r.input_gain = clamp(0.5 * (1.0 - mean_gain), 0.004, 0.08)
}

// Wet-only output. The caller sums `return_level` inside this function.
reverb_process :: proc(r: ^Reverb, l, rr: f32) -> (f32, f32) {
	if !r.params.enabled || r.params.return_level <= 0.0001 {
		return 0.0, 0.0
	}

	// Pre-delay
	delayed := r.predelay[r.predelay_write]
	r.predelay[r.predelay_write] = 0.5 * (l + rr)
	r.predelay_write += 1
	if r.predelay_write >= r.predelay_length {
		r.predelay_write = 0
	}

	x := delayed
	for i in 0 ..< REVERB_AP_COUNT {
		x = reverb_allpass_process(&r.allpasses[i], x)
	}
	x *= r.input_gain

	s: [REVERB_N]f32
	for i in 0 ..< REVERB_N {
		r.phases[i] += r.phase_inc[i]
		if r.phases[i] >= f32(math.TAU) {
			r.phases[i] -= f32(math.TAU)
		}
		delay := f32(r.length[i]) + REVERB_MOD_DEPTH * math.sin(r.phases[i])
		y := reverb_line_read(&r.lines[i], delay)
		r.damping[i] += r.damp_coeff * (y - r.damping[i])
		s[i] = reverb_flush_denormal(r.damping[i] * r.gains[i])
	}

	// Householder: y_i = s_i − (2/N)·Σs
	sum: f32 = 0.0
	for v in s {
		sum += v
	}
	for i in 0 ..< REVERB_N {
		feedback := s[i] - 0.25 * sum
		reverb_line_write(&r.lines[i], x * REVERB_INJECTION[i] + feedback)
	}

	wet_l: f32 = 0.0
	wet_r: f32 = 0.0
	for i in 0 ..< REVERB_N {
		wet_l += REVERB_TAP_L[i] * r.damping[i]
		wet_r += REVERB_TAP_R[i] * r.damping[i]
	}
	norm := 1.0 / math.sqrt(f32(REVERB_N))
	level := r.params.return_level
	return wet_l * norm * level, wet_r * norm * level
}
