// Offline mixdown: track chains -> stereo bus -> master chain.
//
// Rendering is deterministic and allocation-free inside the loop. Reverb,
// delay and the widener are not ported yet; see odin/ROADMAP.md.
//
// Ported from src-tauri/src/audio/fx/render.rs (EQ + comp + fader/pan +
// master comp + limiter).

package dsp

import "core:math"

Track_Mix :: struct {
	// Fader position, 0..1.5 (unity at 1.0).
	level:       f32 `json:"level"`,
	// -1 hard left ... 0 centre ... +1 hard right.
	pan:         f32 `json:"pan"`,
	muted:       bool `json:"muted"`,
	// Reserved for the reverb bus (phase 2).
	send_reverb: f32 `json:"sendReverb"`,
	// Reserved for the delay bus (phase 2).
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
	total := max_len

	tracks := make([]Track_Mix, len(track_audio))
	defer delete(tracks)
	for i in 0 ..< len(track_audio) {
		tracks[i] = track_mix_default()
		if i < len(settings.tracks) {
			tracks[i] = track_mix_sanitized(settings.tracks[i])
		}
	}

	eqs := make([]Eq_State, len(tracks))
	defer delete(eqs)
	comps := make([]Compressor, len(tracks))
	defer delete(comps)
	for track, i in tracks {
		eqs[i] = eq_new(sample_rate, track.eq)
		comps[i] = comp_new(sample_rate, track.comp)
	}

	master_comp := comp_new(sample_rate, settings.master_comp)
	limiter := limiter_new(sample_rate, settings.limiter)
	defer limiter_destroy(&limiter)

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

	for frame in 0 ..< total {
		bus_l: f32 = 0.0
		bus_r: f32 = 0.0

		for track, i in tracks {
			sample: f32 = 0.0
			if frame < len(track_audio[i]) {
				sample = track_audio[i][frame]
			}
			l, r := eq_process(&eqs[i], sample, sample)
			l, r = comp_process(&comps[i], l, r)
			gl, gr := track_mix_pan_gains(track)
			bus_l += l * gl
			bus_r += r * gr
		}

		bus_l, bus_r = comp_process(&master_comp, bus_l, bus_r)
		bus_l, bus_r = limiter_process(&limiter, bus_l, bus_r)

		peak = max(peak, abs(bus_l), abs(bus_r))
		samples[frame * 2 + 0] = bus_l
		samples[frame * 2 + 1] = bus_r

		meter_acc += 1
		if meter_acc >= meter_interval {
			meter_acc = 0
			for i in 0 ..< len(tracks) {
				gr := comp_gain_reduction_db(&comps[i])
				stats.track_gr[i] = min(stats.track_gr[i], gr)
				stats.track_gr_timeline[i][meter_slot] = gr
				comp_reset_meter(&comps[i])
			}
			mgr := comp_gain_reduction_db(&master_comp)
			stats.master_gr = min(stats.master_gr, mgr)
			stats.master_gr_timeline[meter_slot] = mgr
			comp_reset_meter(&master_comp)

			lgr := limiter_gain_reduction_db(&limiter)
			stats.limiter_gr = min(stats.limiter_gr, lgr)
			stats.limiter_gr_timeline[meter_slot] = lgr
			limiter_reset_meter(&limiter)

			meter_slot += 1
		}
	}

	return Render_Output {
		samples = samples,
		frames = total,
		peak_db = lin_to_db(peak),
		stats = stats,
	}
}
