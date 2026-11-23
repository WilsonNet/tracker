// Bounce marked tracks into one target track.
//
// The marked tracks run through their own chains (EQ, compressor, fader, pan)
// and are summed to a mono take on the target. The reverb/delay sends and the
// whole master chain are left out on purpose: they belong to the final mix, and
// applying them twice (now and again at render time) would double the effect.
// The sources are never touched; the target gets a new take, so its previous
// take stays one `t`/`T` away.

package main

import "core:fmt"
import "core:strings"

import dsp "dsp"
import ui "ui"

// Pure render step (no engine, no disk). `track_audio` is one mono slice per
// track at `sample_rate`; `marked` picks the sources. Returns nil when no
// marked track has audio. Caller owns the result.
bounce_tracks_mix :: proc(
	track_audio: [][]f32,
	settings: dsp.Fx_Settings,
	marked: []bool,
	sample_rate: f32,
) -> []f32 {
	any_audio := false
	for audio, i in track_audio {
		if i < len(marked) && marked[i] && len(audio) > 0 {
			any_audio = true
		}
	}
	if !any_audio {
		return nil
	}

	s := settings
	s.tracks = make([]dsp.Track_Mix, len(track_audio))
	defer delete(s.tracks)
	for i in 0 ..< len(track_audio) {
		if i < len(settings.tracks) {
			s.tracks[i] = settings.tracks[i]
		} else {
			s.tracks[i] = dsp.track_mix_default()
		}
		// Marked tracks always sound (their solo/mute state is a monitoring
		// choice); everything else is silent. No sends.
		s.tracks[i].muted = !(i < len(marked) && marked[i])
		s.tracks[i].send_reverb = 0
		s.tracks[i].send_delay = 0
	}
	s.master_comp.enabled = false
	s.reverb.enabled = false
	s.delay.enabled = false
	s.width.enabled = false
	s.limiter.enabled = false

	out := dsp.render_mix(track_audio, s, sample_rate)
	defer dsp.render_destroy(&out)
	if out.frames <= 0 {
		return nil
	}
	mono := make([]f32, out.frames)
	// 1/sqrt(2): a centred track keeps unity gain after the constant-power pan.
	for f in 0 ..< out.frames {
		mono[f] = (out.samples[f * 2] + out.samples[f * 2 + 1]) * 0.70710678
	}
	return mono
}

// Label like "Bounce 1+2+3" for the new take.
bounce_tracks_label :: proc(marked: []bool, count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Bounce ")
	first := true
	for i in 0 ..< min(count, len(marked)) {
		if !marked[i] {
			continue
		}
		if !first {
			strings.write_byte(&b, '+')
		}
		strings.write_int(&b, i + 1)
		first = false
	}
	return strings.to_string(b)
}

engine_bounce_to_track :: proc(e: ^Engine, a: ^ui.App, target: int) -> (ok: bool, message: string) {
	if e.rec.active {
		return false, "stop recording before bouncing tracks"
	}
	if target < 0 || target >= a.track_count {
		return false, "choose a target track"
	}
	if a.marked[target] {
		return false, "the target cannot be one of the marked tracks"
	}
	if e.session_dir == "" {
		return false, "no project folder"
	}

	tracks, owned := engine_track_audio(e)
	defer engine_free_track_audio(tracks, owned)
	settings := settings_from_app(a)
	defer delete(settings.tracks)

	marked := a.marked[:]
	mono := bounce_tracks_mix(tracks, settings, marked, f32(e.sample_rate))
	if mono == nil {
		return false, "marked tracks have no audio yet"
	}

	path := fmt.tprintf("%s/track%d.wav", e.session_dir, target + 1)
	engine_take_stabilize_canonical(e, target)
	if !wav_write(path, e.sample_rate, 1, mono) {
		delete(mono)
		return false, fmt.tprintf("cannot write track%d.wav", target + 1)
	}
	engine_take_register_new(e, target, e.sample_rate, bounce_tracks_label(marked, a.track_count))
	delete(e.loaded[target])
	e.loaded[target] = mono
	e.loaded_rate[target] = e.sample_rate
	a.tracks[target].has_audio = true

	sources := 0
	for i in 0 ..< a.track_count {
		if a.marked[i] {
			sources += 1
		}
	}
	return true, fmt.tprintf("bounced %d tracks to track %d · %.1f s", sources, target + 1, f32(len(mono)) / f32(e.sample_rate))
}
