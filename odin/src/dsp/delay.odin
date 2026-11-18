// Stereo delay with a tone control in the feedback path and an optional
// ping-pong routing (mono input, left -> right -> left).
//
// The read tap is fractional (linear interpolation) and the delay time is
// smoothed, so moving TIME while audio is running never clicks.
//
// Ported from src-tauri/src/audio/fx/delay.rs. Sample-for-sample identical to
// the Rust reference: same buffer sizing, same fractional tap, same 20 ms
// glide, same tanh + DC-blocker feedback path.

package dsp

import "core:math"

MAX_DELAY_SECONDS :: 2.0

Delay_Params :: struct {
	enabled:      bool `json:"enabled"`,
	time_ms:      f32  `json:"timeMs"`,
	feedback:     f32  `json:"feedback"`,
	// 0 = dark repeats, 1 = bright.
	tone:         f32  `json:"tone"`,
	ping_pong:    bool `json:"pingPong"`,
	// Wet return level, 0..1 (this is a send bus, so it is wet only).
	return_level: f32  `json:"returnLevel"`,
}

delay_params_default :: proc() -> Delay_Params {
	return Delay_Params {
		enabled = false,
		time_ms = 320.0,
		feedback = 0.35,
		tone = 0.55,
		ping_pong = true,
		return_level = 0.35,
	}
}

delay_params_sanitized :: proc(params: Delay_Params) -> Delay_Params {
	p := params
	p.time_ms = clamp(p.time_ms, 1.0, 2_000.0)
	p.feedback = clamp(p.feedback, 0.0, 0.9)
	p.tone = clamp(p.tone, 0.0, 1.0)
	p.return_level = clamp(p.return_level, 0.0, 1.0)
	return p
}

@(private)
Delay_Line :: struct {
	buffer: []f32,
	write:  int,
}

@(private)
delay_line_new :: proc(max_samples: int) -> Delay_Line {
	return Delay_Line {
		buffer = make([]f32, max(max_samples, 2)),
	}
}

@(private)
delay_line_destroy :: proc(line: ^Delay_Line) {
	delete(line.buffer)
	line.buffer = nil
	line.write = 0
}

// Fractional read: linear interpolation between the two samples around the
// delayed position. The read happens before this call's write, so an integer
// delay of D returns the sample written D calls ago.
@(private)
delay_line_read :: proc(line: ^Delay_Line, delay: f32) -> f32 {
	n := len(line.buffer)
	d := clamp(delay, 1.0, f32(n - 2))
	read := f32(line.write) - d
	if read < 0.0 {
		read += f32(n)
	}
	floor := math.floor(read)
	i0 := int(floor) % n
	i1 := (i0 + 1) % n
	frac := read - floor
	return line.buffer[i0] * (1.0 - frac) + line.buffer[i1] * frac
}

@(private)
delay_line_write :: proc(line: ^Delay_Line, x: f32) {
	line.buffer[line.write] = flush_denormal(x)
	line.write += 1
	if line.write >= len(line.buffer) {
		line.write = 0
	}
}

Stereo_Delay :: struct {
	left:           Delay_Line,
	right:          Delay_Line,
	sample_rate:    f32,
	params:         Delay_Params,
	delay_samples:  f32,
	target_samples: f32,
	smoothing:      f32,
	tone_l:         f32,
	tone_r:         f32,
	tone_coeff:     f32,
	dc_x_l:         f32,
	dc_y_l:         f32,
	dc_x_r:         f32,
	dc_y_r:         f32,
}

delay_new :: proc(sample_rate: f32, params: Delay_Params) -> Stereo_Delay {
	params := delay_params_sanitized(params)
	max_samples := int(MAX_DELAY_SECONDS * sample_rate) + 8
	delay := Stereo_Delay {
		left           = delay_line_new(max_samples),
		right          = delay_line_new(max_samples),
		sample_rate    = sample_rate,
		params         = params,
		delay_samples  = params.time_ms * 0.001 * sample_rate,
		target_samples = params.time_ms * 0.001 * sample_rate,
		tone_coeff     = 1.0,
	}
	delay_update(&delay, sample_rate, params)
	delay.delay_samples = delay.target_samples
	return delay
}

delay_destroy :: proc(d: ^Stereo_Delay) {
	delay_line_destroy(&d.left)
	delay_line_destroy(&d.right)
	d.delay_samples = 0.0
	d.target_samples = 0.0
}

delay_update :: proc(d: ^Stereo_Delay, sample_rate: f32, params: Delay_Params) {
	d.sample_rate = sample_rate
	d.params = delay_params_sanitized(params)
	d.target_samples = d.params.time_ms * 0.001 * sample_rate
	// 20 ms glide for the read tap.
	d.smoothing = coeff_for_ms(20.0, sample_rate)
	cutoff := 400.0 + 16_000.0 * d.params.tone
	d.tone_coeff = 1.0 - math.exp(-f32(math.TAU) * cutoff / sample_rate)
}

// Soft saturation plus a DC blocker, applied inside the feedback loop. Bounds
// the state at any feedback setting and keeps repeats from building a DC
// offset.
@(private)
delay_shape :: proc(d: ^Stereo_Delay, x: f32, channel: int) -> f32 {
	saturated := math.tanh(1.5 * x) * 0.6667
	x1: ^f32
	y1: ^f32
	if channel == 0 {
		x1 = &d.dc_x_l
		y1 = &d.dc_y_l
	} else {
		x1 = &d.dc_x_r
		y1 = &d.dc_y_r
	}
	y := saturated - x1^ + 0.995 * y1^
	x1^ = saturated
	y1^ = y
	return y
}

// Wet return only; the dry signal is mixed by the caller. A disabled delay (or
// a silent return) is a true bypass that does not advance the lines.
delay_process :: proc(d: ^Stereo_Delay, l, r: f32) -> (f32, f32) {
	if !d.params.enabled || d.params.return_level <= 0.0001 {
		return 0.0, 0.0
	}
	d.delay_samples = d.smoothing * d.delay_samples + (1.0 - d.smoothing) * d.target_samples

	wet_l := delay_line_read(&d.left, d.delay_samples)
	wet_r := delay_line_read(&d.right, d.delay_samples)

	// Each repeat gets darker and slightly saturated, like tape.
	d.tone_l += d.tone_coeff * (wet_l - d.tone_l)
	d.tone_r += d.tone_coeff * (wet_r - d.tone_r)
	fb_l := delay_shape(d, d.tone_l, 0)
	fb_r := delay_shape(d, d.tone_r, 1)
	fb := d.params.feedback

	if d.params.ping_pong {
		// Mono feed -> left line -> right line -> left line ...
		mono := (l + r) * 0.5
		delay_line_write(&d.left, mono + fb_r * fb)
		delay_line_write(&d.right, fb_l * fb)
	} else {
		delay_line_write(&d.left, l + fb_l * fb)
		delay_line_write(&d.right, r + fb_r * fb)
	}

	level := d.params.return_level
	return wet_l * level, wet_r * level
}
