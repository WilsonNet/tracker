// Offline mixdown: track chains -> stereo bus -> master chain.
//
// Rendering is deterministic and allocation-free inside the loop. The full
// chain is EQ -> compressor -> fader/pan -> post-fader reverb/delay sends on
// each track, then master compressor -> widener -> look-ahead limiter.
//
// The limiter delays its output by its look-ahead window. The render loop
// compensates for that inside this file so a rendered mix stays aligned with
// the source (and a take shorter than the look-ahead is not rendered silent).
//
// Ported from src-tauri/src/audio/fx/render.rs, with the latency compensation
// and final meter capture added.

package dsp

import "core:math"

Track_Mix :: struct {
	// Fader position, 0..1.5 (unity at 1.0).
	level:       f32 `json:"level"`,
	// -1 hard left ... 0 centre ... +1 hard right.
	pan:         f32 `json:"pan"`,
	muted:       bool `json:"muted"`,
	// Post-fader send into the reverb bus.
	send_reverb: f32 `json:"sendReverb"`,
	// Post-fader send into the delay bus.
	send_delay:  f32 `json:"sendDelay"`,
	eq:          Eq_Params   `json:"eq"`,
	comp:        Comp_Params `json:"comp"`,
}

track_mix_default :: proc() -> Track_Mix {
	return Track_Mix {
		level = 0.8,
		pan = 0.0,
		muted = false,
		send_reverb = 0.0,
		send_delay = 0.0,
		eq = eq_params_default(),
		comp = comp_params_default(),
	}
}

track_mix_sanitized :: proc(track: Track_Mix) -> Track_Mix {
	t := track
	t.level = clamp(t.level, 0.0, 1.5)
	t.pan = clamp(t.pan, -1.0, 1.0)
	t.send_reverb = clamp(t.send_reverb, 0.0, 1.0)
	t.send_delay = clamp(t.send_delay, 0.0, 1.0)
	t.eq = eq_params_sanitized(t.eq)
	t.comp = comp_params_sanitized(t.comp)
	return t
}

// Reverb/delay tail appended to the source length. Exported so the render
// dialog can show the true end of the mix and the UI can clamp ranges to it.
render_tail_seconds :: proc(settings: Fx_Settings) -> f32 {
	active_sends := false
	for track in settings.tracks {
		t := track_mix_sanitized(track)
		if t.send_reverb > 0.001 || t.send_delay > 0.001 {
			active_sends = true
			break
		}
	}
	if !active_sends || (!settings.reverb.enabled && !settings.delay.enabled) {
		return 0
	}
	tail: f32 = 2.0
	if settings.reverb.enabled {
		tail += min(reverb_rt60_seconds(settings.reverb), 5.0)
	}
	return tail
}

// Constant-power pan gains (centre = -3 dB per side).
track_mix_pan_gains :: proc(track: Track_Mix) -> (f32, f32) {
	if track.muted {
		return 0.0, 0.0
	}
	angle := (track.pan + 1.0) * (f32(math.TAU) / 8.0)
	return math.cos(angle) * track.level, math.sin(angle) * track.level
}

Fx_Settings :: struct {
	tracks:      []Track_Mix  `json:"tracks"`,
	master_comp: Comp_Params  `json:"masterComp"`,
	reverb:      Reverb_Params `json:"reverb"`,
	delay:       Delay_Params  `json:"delay"`,
	width:       Width_Params  `json:"width"`,
	limiter:     Limiter_Params `json:"limiter"`,
}

fx_settings_default :: proc() -> Fx_Settings {
	master := comp_params_default()
	master.enabled = false
	master.threshold_db = -14.0
	master.ratio = 2.5
	master.attack_ms = 20.0
	master.release_ms = 250.0
	master.knee_db = 10.0
	master.mix = 1.0
	return Fx_Settings {
		tracks = nil,
		master_comp = master,
		reverb = reverb_params_default(),
		delay = delay_params_default(),
		width = width_params_default(),
		limiter = limiter_params_default(),
	}
}

Fx_Stats :: struct {
	// Worst compressor reduction per track, dB (<= 0).
	track_gr:             []f32,
	// Worst master compressor reduction, dB (<= 0).
	master_gr:            f32,
	// Worst limiter reduction, dB (<= 0).
	limiter_gr:           f32,
	// Reduction timelines at 20 points/second.
	track_gr_timeline:    [][]f32,
	master_gr_timeline:   []f32,
	limiter_gr_timeline:  []f32,
}

Render_Output :: struct {
	// Interleaved stereo, 2 channels.
	samples: []f32,
	frames:  int,
	peak_db: f32,
	stats:   Fx_Stats,
}

render_destroy :: proc(out: ^Render_Output) {
	delete(out.samples)
	out.samples = nil
	for timeline in out.stats.track_gr_timeline {
		delete(timeline)
	}
	delete(out.stats.track_gr_timeline)
	delete(out.stats.master_gr_timeline)
	delete(out.stats.limiter_gr_timeline)
	delete(out.stats.track_gr)
	out.stats = {}
}

METER_HZ :: 20.0

// Mix `tracks` (mono, one slice per track) through the full chain.
render_mix :: proc(track_audio: [][]f32, settings: Fx_Settings, sample_rate: f32) -> Render_Output {
	max_len := 0
	for track in track_audio {
		max_len = max(max_len, len(track))
	}

	tracks := make([]Track_Mix, len(track_audio))
	defer delete(tracks)
	for i in 0 ..< len(track_audio) {
		tracks[i] = track_mix_default()
		if i < len(settings.tracks) {
			tracks[i] = track_mix_sanitized(settings.tracks[i])
		}
	}

	tail_seconds := render_tail_seconds(settings)
	total := max_len + int(tail_seconds * sample_rate)

	eqs := make([]Eq_State, len(tracks))
	defer delete(eqs)
	comps := make([]Compressor, len(tracks))
	defer delete(comps)
	pan_l := make([]f32, len(tracks))
	defer delete(pan_l)
	pan_r := make([]f32, len(tracks))
	defer delete(pan_r)
	for track, i in tracks {
		eqs[i] = eq_new(sample_rate, track.eq)
		comps[i] = comp_new(sample_rate, track.comp)
		// Constant-power pan depends only on the track settings, not the sample:
		// hoist the sin/cos out of the per-frame loop.
		pan_l[i], pan_r[i] = track_mix_pan_gains(track)
	}

	master_comp := comp_new(sample_rate, settings.master_comp)
	reverb := reverb_new(sample_rate, settings.reverb)
	defer reverb_destroy(&reverb)
	delay := delay_new(sample_rate, settings.delay)
	defer delay_destroy(&delay)
	widener := widener_new(sample_rate, settings.width)
	limiter := limiter_new(sample_rate, settings.limiter)
	defer limiter_destroy(&limiter)

	// The limiter's output is delayed by its look-ahead window. Render that
	// many extra frames and discard the leading zeros so the mix stays
	// sample-aligned with the source and its final samples are not lost.
	lookahead := 0
	if limiter.params.enabled {
		lookahead = limiter.lookahead
	}
	render_frames := total + lookahead

	meter_interval := max(int(sample_rate / METER_HZ), 1)
	meter_points := total / meter_interval
	stats := Fx_Stats {
		track_gr = make([]f32, len(tracks)),
		track_gr_timeline = make([][]f32, len(tracks)),
		master_gr_timeline = make([]f32, meter_points),
		limiter_gr_timeline = make([]f32, meter_points),
	}
	for i in 0 ..< len(tracks) {
		stats.track_gr_timeline[i] = make([]f32, meter_points)
	}

	samples := make([]f32, total * 2)
	peak: f32 = 0.0
	meter_acc := 0
	meter_slot := 0
	out_frame := 0

	for frame in 0 ..< render_frames {
		bus_l: f32 = 0.0
		bus_r: f32 = 0.0
		send_rev_l: f32 = 0.0
		send_rev_r: f32 = 0.0
		send_dly_l: f32 = 0.0
		send_dly_r: f32 = 0.0

		for track, i in tracks {
			sample: f32 = 0.0
			if frame < len(track_audio[i]) {
				sample = track_audio[i][frame]
				// A non-finite sample would poison the recursive filter
				// states for the rest of the mix. Treat it as a dropout.
				if math.is_nan(sample) || math.is_inf(sample) {
					sample = 0.0
				}
			}
			l, r := eq_process(&eqs[i], sample, sample)
			l, r = comp_process(&comps[i], l, r)
			out_l := l * pan_l[i]
			out_r := r * pan_r[i]
			bus_l += out_l
			bus_r += out_r
			send_rev_l += out_l * track.send_reverb
			send_rev_r += out_r * track.send_reverb
			send_dly_l += out_l * track.send_delay
			send_dly_r += out_r * track.send_delay
		}

		rev_l, rev_r := reverb_process(&reverb, send_rev_l, send_rev_r)
		dly_l, dly_r := delay_process(&delay, send_dly_l, send_dly_r)
		bus_l += rev_l + dly_l
		bus_r += rev_r + dly_r

		bus_l, bus_r = comp_process(&master_comp, bus_l, bus_r)
		bus_l, bus_r = widener_process(&widener, bus_l, bus_r)
		bus_l, bus_r = limiter_process(&limiter, bus_l, bus_r)

		if frame < lookahead {
			continue
		}

		peak = max(peak, abs(bus_l), abs(bus_r))
		samples[out_frame * 2 + 0] = bus_l
		samples[out_frame * 2 + 1] = bus_r
		out_frame += 1

		meter_acc += 1
		if meter_acc >= meter_interval {
			meter_acc = 0
			if meter_slot < meter_points {
				for i in 0 ..< len(tracks) {
					stats.track_gr_timeline[i][meter_slot] = comp_instantaneous_reduction_db(&comps[i])
				}
				stats.master_gr_timeline[meter_slot] = comp_instantaneous_reduction_db(&master_comp)
				stats.limiter_gr_timeline[meter_slot] = limiter_instantaneous_reduction_db(&limiter)
				meter_slot += 1
			}
		}
	}

	// Capture the worst-case reduction after the whole render, including a
	// final partial meter interval (a take shorter than 50 ms otherwise
	// reports no compressor or limiter activity at all).
	for i in 0 ..< len(tracks) {
		stats.track_gr[i] = comp_gain_reduction_db(&comps[i])
	}
	stats.master_gr = comp_gain_reduction_db(&master_comp)
	stats.limiter_gr = limiter_gain_reduction_db(&limiter)

	return Render_Output {
		samples = samples,
		frames = total,
		peak_db = lin_to_db(peak),
		stats = stats,
	}
}
