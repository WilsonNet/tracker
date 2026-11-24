// Real-time streaming DSP mixer for live playback.
//
// Runs lock-free and allocation-free inside the audio callback (every runtime
// proc is `contextless`). Mirrors `render_mix`'s track and master chain so
// live playback matches offline bounce/render while allowing instant transport
// start and live parameter updates.

package dsp

import "core:math"

LIVE_MAX_TRACKS :: 24

Live_Mix_Params :: struct {
	track_count: int,
	tracks:      [LIVE_MAX_TRACKS]Track_Mix,
	master_comp: Comp_Params,
	reverb:      Reverb_Params,
	delay:       Delay_Params,
	width:       Width_Params,
	limiter:     Limiter_Params,
}

live_mix_tail_seconds :: proc "contextless" (params: ^Live_Mix_Params) -> f32 {
	if params == nil {
		return 0
	}
	count := clamp(params.track_count, 0, LIVE_MAX_TRACKS)
	active_sends := false
	for i in 0 ..< count {
		t := track_mix_sanitized(params.tracks[i])
		if t.send_reverb > 0.001 || t.send_delay > 0.001 {
			active_sends = true
			break
		}
	}
	if !active_sends || (!params.reverb.enabled && !params.delay.enabled) {
		return 0
	}
	tail: f32 = 2.0
	if params.reverb.enabled {
		tail += min(reverb_rt60_seconds(params.reverb), 5.0)
	}
	return tail
}

Live_Mixer :: struct {
	initialized:  bool,
	has_params:   bool,
	sample_rate:  f32,
	track_count:  int,
	params:       Live_Mix_Params,
	pan_l:        [LIVE_MAX_TRACKS]f32,
	pan_r:        [LIVE_MAX_TRACKS]f32,
	target_pan_l: [LIVE_MAX_TRACKS]f32,
	target_pan_r: [LIVE_MAX_TRACKS]f32,
	gain_smooth:  f32,
	eqs:          [LIVE_MAX_TRACKS]Eq_State,
	comps:        [LIVE_MAX_TRACKS]Compressor,
	master_comp:  Compressor,
	reverb:       Reverb,
	delay:        Stereo_Delay,
	widener:      Widener,
	limiter:      Limiter,
}

live_mixer_init :: proc(m: ^Live_Mixer, sample_rate: f32) {
	if m == nil {
		return
	}
	rate := max(sample_rate, 8_000.0)
	if m.initialized {
		live_mixer_destroy(m)
	}
	m.sample_rate = rate
	m.track_count = LIVE_MAX_TRACKS
	m.gain_smooth = coeff_for_ms(4.0, rate)
	def := fx_settings_default()
	tm := track_mix_default()
	for i in 0 ..< LIVE_MAX_TRACKS {
		m.params.tracks[i] = tm
		m.eqs[i] = eq_new(rate, tm.eq)
		m.comps[i] = comp_new(rate, tm.comp)
		gl, gr := track_mix_pan_gains(tm)
		m.pan_l[i] = gl
		m.pan_r[i] = gr
		m.target_pan_l[i] = gl
		m.target_pan_r[i] = gr
	}
	m.params.track_count = LIVE_MAX_TRACKS
	m.params.master_comp = def.master_comp
	m.params.reverb = def.reverb
	m.params.delay = def.delay
	m.params.width = def.width
	m.params.limiter = def.limiter

	m.master_comp = comp_new(rate, def.master_comp)
	m.reverb = reverb_new(rate, def.reverb)
	m.delay = delay_new(rate, def.delay)
	m.widener = widener_new(rate, def.width)
	m.limiter = limiter_new(rate, def.limiter)
	m.has_params = false
	m.initialized = true
}

live_mixer_destroy :: proc(m: ^Live_Mixer) {
	if m == nil || !m.initialized {
		return
	}
	reverb_destroy(&m.reverb)
	delay_destroy(&m.delay)
	limiter_destroy(&m.limiter)
	m^ = {}
}

live_mixer_reset :: proc "contextless" (m: ^Live_Mixer) {
	if m == nil || !m.initialized {
		return
	}
	for i in 0 ..< LIVE_MAX_TRACKS {
		eq_reset(&m.eqs[i])
		comp_reset(&m.comps[i])
		m.pan_l[i] = m.target_pan_l[i]
		m.pan_r[i] = m.target_pan_r[i]
	}
	comp_reset(&m.master_comp)
	reverb_reset(&m.reverb)
	delay_reset(&m.delay)
	widener_reset(&m.widener)
	limiter_reset(&m.limiter)
}

live_mixer_apply_params :: proc "contextless" (m: ^Live_Mixer, next: ^Live_Mix_Params, snap_gains: bool = false) {
	if m == nil || !m.initialized || next == nil {
		return
	}
	rate := m.sample_rate
	count := clamp(next.track_count, 0, LIVE_MAX_TRACKS)
	force := !m.has_params
	m.track_count = count
	m.params.track_count = count

	for i in 0 ..< count {
		t := track_mix_sanitized(next.tracks[i])
		prev := m.params.tracks[i]
		if force || t.eq != prev.eq {
			eq_set_params(&m.eqs[i], rate, t.eq)
		}
		if force || t.comp != prev.comp {
			comp_update(&m.comps[i], rate, t.comp)
		}
		if force || t.level != prev.level || t.pan != prev.pan || t.muted != prev.muted {
			gl, gr := track_mix_pan_gains(t)
			m.target_pan_l[i] = gl
			m.target_pan_r[i] = gr
			if snap_gains {
				m.pan_l[i] = gl
				m.pan_r[i] = gr
			}
		}
		m.params.tracks[i] = t
	}

	mc := comp_params_sanitized(next.master_comp)
	if force || mc != m.params.master_comp {
		comp_update(&m.master_comp, rate, mc)
		m.params.master_comp = mc
	}

	rev := reverb_params_sanitized(next.reverb)
	if force || rev != m.params.reverb {
		if force || rev.size != m.params.reverb.size || rev.decay != m.params.reverb.decay || rev.tone != m.params.reverb.tone || rev.predelay_ms != m.params.reverb.predelay_ms {
			reverb_update(&m.reverb, rate, rev)
		} else {
			m.reverb.params = rev
		}
		m.params.reverb = rev
	}

	dly := delay_params_sanitized(next.delay)
	if force || dly != m.params.delay {
		delay_update(&m.delay, rate, dly)
		m.params.delay = dly
	}

	wid := width_params_sanitized(next.width)
	if force || wid != m.params.width {
		widener_update(&m.widener, rate, wid)
		m.params.width = wid
	}

	lim := limiter_params_sanitized(next.limiter)
	if force || lim != m.params.limiter {
		if force || lim.ceiling_db != m.params.limiter.ceiling_db || lim.release_ms != m.params.limiter.release_ms || lim.lookahead_ms != m.params.limiter.lookahead_ms {
			// Preserve lookahead ring buffer on threshold/release changes unless lookahead itself changed.
			if force || lim.lookahead_ms != m.params.limiter.lookahead_ms {
				limiter_update(&m.limiter, rate, lim)
			} else {
				m.limiter.params = lim
				m.limiter.release = 1.0 - coeff_for_ms(lim.release_ms, rate)
				m.limiter.ceiling_lin = db_to_lin(lim.ceiling_db)
			}
		} else {
			m.limiter.params = lim
		}
		m.params.limiter = lim
	}

	if snap_gains {
		for i in 0 ..< count {
			m.pan_l[i] = m.target_pan_l[i]
			m.pan_r[i] = m.target_pan_r[i]
		}
	}
	m.has_params = true
}

live_mixer_step :: proc "contextless" (
	m: ^Live_Mixer,
	samples: ^[LIVE_MAX_TRACKS]f32,
	has_audio: ^[LIVE_MAX_TRACKS]bool,
	track_peaks: ^[LIVE_MAX_TRACKS]f32,
) -> (f32, f32) {
	if m == nil || !m.initialized {
		return 0.0, 0.0
	}
	bus_l: f32 = 0.0
	bus_r: f32 = 0.0
	send_rev_l: f32 = 0.0
	send_rev_r: f32 = 0.0
	send_dly_l: f32 = 0.0
	send_dly_r: f32 = 0.0

	c := m.gain_smooth
	one_minus_c := 1.0 - c

	for i in 0 ..< m.track_count {
		if !has_audio[i] {
			continue
		}
		tl := m.target_pan_l[i]
		tr := m.target_pan_r[i]
		pl := m.pan_l[i]
		pr := m.pan_r[i]
		if abs(tl - pl) < 1e-6 {
			pl = tl
		} else {
			pl = c * pl + one_minus_c * tl
		}
		if abs(tr - pr) < 1e-6 {
			pr = tr
		} else {
			pr = c * pr + one_minus_c * tr
		}
		m.pan_l[i] = pl
		m.pan_r[i] = pr

		t := &m.params.tracks[i]
		if t.muted && abs(pl) < 1e-6 && abs(pr) < 1e-6 {
			continue
		}

		s := samples[i]
		if math.is_nan(s) || math.is_inf(s) {
			s = 0.0
		}
		l, r := eq_process(&m.eqs[i], s, s)
		l, r = comp_process(&m.comps[i], l, r)
		out_l := l * pl
		out_r := r * pr
		if track_peaks != nil {
			track_peaks[i] = max(track_peaks[i], abs(out_l), abs(out_r))
		}
		bus_l += out_l
		bus_r += out_r
		send_rev_l += out_l * t.send_reverb
		send_rev_r += out_r * t.send_reverb
		send_dly_l += out_l * t.send_delay
		send_dly_r += out_r * t.send_delay
	}

	rev_l, rev_r := reverb_process(&m.reverb, send_rev_l, send_rev_r)
	dly_l, dly_r := delay_process(&m.delay, send_dly_l, send_dly_r)
	bus_l += rev_l + dly_l
	bus_r += rev_r + dly_r

	bus_l, bus_r = comp_process(&m.master_comp, bus_l, bus_r)
	bus_l, bus_r = widener_process(&m.widener, bus_l, bus_r)
	bus_l, bus_r = limiter_process(&m.limiter, bus_l, bus_r)
	return bus_l, bus_r
}
