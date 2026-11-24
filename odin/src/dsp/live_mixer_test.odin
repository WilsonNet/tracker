package dsp

import "core:math"
import "core:testing"

@(test)
live_mixer_matches_render_mix_sample_for_sample :: proc(t: ^testing.T) {
	rate: f32 = 48_000.0
	frames := 2_400
	tracks := make([][]f32, 4)
	defer {
		for tr in tracks {
			delete(tr)
		}
		delete(tracks)
	}
	for i in 0 ..< 4 {
		tracks[i] = make([]f32, frames)
		freq := 110.0 + f32(i) * 73.0
		for f in 0 ..< frames {
			tracks[i][f] = 0.45 * math.sin(f32(f) / rate * freq * f32(math.TAU))
		}
	}

	settings := fx_settings_default()
	settings.tracks = make([]Track_Mix, 4)
	defer delete(settings.tracks)
	for i in 0 ..< 4 {
		tm := track_mix_default()
		tm.level = 0.85 - f32(i) * 0.1
		tm.pan = -0.6 + f32(i) * 0.4
		tm.send_reverb = 0.25
		tm.send_delay = 0.2
		tm.eq.low_db = 2.5
		tm.eq.mid_db = -1.5
		tm.eq.high_db = 1.0
		settings.tracks[i] = tm
	}
	settings.master_comp.enabled = true
	settings.reverb.enabled = true
	settings.delay.enabled = true
	settings.width.enabled = true
	settings.width.width = 1.3

	// 1. Limiter disabled: zero-frame offset exact match against render_mix.
	settings.limiter.enabled = false
	off := render_mix(tracks, settings, rate)
	defer render_destroy(&off)

	m: Live_Mixer
	live_mixer_init(&m, rate)
	defer live_mixer_destroy(&m)

	lp := Live_Mix_Params {
		track_count = 4,
		master_comp = settings.master_comp,
		reverb      = settings.reverb,
		delay       = settings.delay,
		width       = settings.width,
		limiter     = settings.limiter,
	}
	for i in 0 ..< 4 {
		lp.tracks[i] = settings.tracks[i]
	}
	live_mixer_apply_params(&m, &lp, true)

	has_audio: [LIVE_MAX_TRACKS]bool
	for i in 0 ..< 4 {
		has_audio[i] = true
	}
	peaks: [LIVE_MAX_TRACKS]f32
	samples: [LIVE_MAX_TRACKS]f32

	max_diff: f32 = 0
	for f in 0 ..< frames {
		for i in 0 ..< 4 {
			samples[i] = tracks[i][f]
		}
		l, r := live_mixer_step(&m, &samples, &has_audio, &peaks)
		max_diff = max(max_diff, abs(l - off.samples[f * 2]), abs(r - off.samples[f * 2 + 1]))
	}
	testing.expectf(t, max_diff < 1e-5, "live vs render_mix (no limiter) diff %v", max_diff)

	// 2. Limiter enabled: matches render_mix shifted by limiter lookahead.
	settings.limiter.enabled = true
	off_lim := render_mix(tracks, settings, rate)
	defer render_destroy(&off_lim)

	lp.limiter = settings.limiter
	live_mixer_apply_params(&m, &lp, true)
	live_mixer_reset(&m)

	lookahead := m.limiter.lookahead
	max_lim_diff: f32 = 0
	for f in 0 ..< frames {
		for i in 0 ..< 4 {
			samples[i] = tracks[i][f]
		}
		l, r := live_mixer_step(&m, &samples, &has_audio, &peaks)
		if f >= lookahead {
			of := f - lookahead
			max_lim_diff = max(max_lim_diff, abs(l - off_lim.samples[of * 2]), abs(r - off_lim.samples[of * 2 + 1]))
		}
	}
	testing.expectf(t, max_lim_diff < 1e-5, "live vs render_mix (limiter) diff %v", max_lim_diff)
}

@(test)
live_mixer_live_param_updates_and_reset :: proc(t: ^testing.T) {
	rate: f32 = 48_000.0
	m: Live_Mixer
	live_mixer_init(&m, rate)
	defer live_mixer_destroy(&m)

	lp := Live_Mix_Params{track_count = 2}
	lp.tracks[0] = track_mix_default()
	lp.tracks[0].send_reverb = 0.8
	lp.tracks[1] = track_mix_default()
	lp.reverb = reverb_params_default()
	lp.reverb.enabled = true
	lp.reverb.predelay_ms = 0
	lp.delay = delay_params_default()
	lp.limiter = limiter_params_default()
	lp.limiter.enabled = false
	live_mixer_apply_params(&m, &lp, true)

	has_audio := [LIVE_MAX_TRACKS]bool{0 = true, 1 = false}
	samples := [LIVE_MAX_TRACKS]f32{0 = 0.5}
	peaks: [LIVE_MAX_TRACKS]f32

	// Pump signal so reverb tail builds up.
	for _ in 0 ..< 1_000 {
		l, r := live_mixer_step(&m, &samples, &has_audio, &peaks)
		testing.expect(t, !math.is_nan(l) && !math.is_nan(r), "NaN during live step")
	}

	// Mute track 0 live without snapping: gain ramps smoothly down to zero over ~45 ms,
	// leaving only reverb tail, then reset clears all tails to exact zero.
	lp.tracks[0].muted = true
	live_mixer_apply_params(&m, &lp, false)
	for _ in 0 ..< 2_400 {
		_, _ = live_mixer_step(&m, &samples, &has_audio, &peaks)
	}
	testing.expectf(t, abs(m.pan_l[0]) < 1e-5 && abs(m.pan_r[0]) < 1e-5, "muted pan gains did not settle: %v %v", m.pan_l[0], m.pan_r[0])

	live_mixer_reset(&m)
	samples[0] = 0
	l, r := live_mixer_step(&m, &samples, &has_audio, &peaks)
	testing.expectf(t, l == 0 && r == 0, "reset left tail audio: %v %v", l, r)
}

@(test)
live_mixer_tail_seconds_matches_render_tail :: proc(t: ^testing.T) {
	p := Live_Mix_Params{track_count = 4}
	for i in 0 ..< 4 {
		p.tracks[i] = track_mix_default()
	}
	p.reverb = reverb_params_default()
	p.delay = delay_params_default()
	testing.expect(t, live_mix_tail_seconds(&p) == 0, "no active sends")

	p.tracks[1].send_reverb = 0.3
	p.reverb.enabled = true
	s := fx_settings_default()
	s.tracks = make([]Track_Mix, 4)
	defer delete(s.tracks)
	for i in 0 ..< 4 {
		s.tracks[i] = p.tracks[i]
	}
	s.reverb = p.reverb
	s.delay = p.delay
	testing.expectf(t, abs(live_mix_tail_seconds(&p) - render_tail_seconds(s)) < 1e-6, "tail mismatch")
}
