// Project + settings persistence. The UI view is the source of truth; this file
// maps it to the DSP parameter structs and to an on-disk project.json.

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import dsp "dsp"
import ui "ui"

PROJECT_VERSION :: 1

Project_Track :: struct {
	name:        string         `json:"name"`,
	file:        string         `json:"file"`,
	input:       int            `json:"input"`,
	level:       f32            `json:"level"`,
	pan:         f32            `json:"pan"`,
	muted:       bool           `json:"muted"`,
	solo:        bool           `json:"solo"`,
	armed:       bool           `json:"armed"`,
	send_reverb: f32            `json:"sendReverb"`,
	send_delay:  f32            `json:"sendDelay"`,
	eq:          dsp.Eq_Params  `json:"eq"`,
	comp:        dsp.Comp_Params `json:"comp"`,
}

Project_Master :: struct {
	comp:    dsp.Comp_Params    `json:"comp"`,
	reverb:  dsp.Reverb_Params  `json:"reverb"`,
	delay:   dsp.Delay_Params   `json:"delay"`,
	width:   dsp.Width_Params   `json:"width"`,
	limiter: dsp.Limiter_Params `json:"limiter"`,
}

Project_Doc :: struct {
	version:     int             `json:"version"`,
	name:        string          `json:"name"`,
	sample_rate: u32             `json:"sampleRate"`,
	bpm:         int             `json:"bpm"`,
	device:      string          `json:"device"`,
	tracks:      []Project_Track `json:"tracks"`,
	master:      Project_Master  `json:"master"`,
}

project_master_default :: proc() -> Project_Master {
	comp := dsp.comp_params_default()
	comp.enabled = false
	comp.threshold_db = -14
	comp.ratio = 2.5
	comp.attack_ms = 20
	comp.release_ms = 250
	comp.knee_db = 10
	return Project_Master {
		comp = comp,
		reverb = dsp.reverb_params_default(),
		delay = dsp.delay_params_default(),
		width = dsp.width_params_default(),
		limiter = dsp.limiter_params_default(),
	}
}

PROJECT_TRACK_NAMES := [4]string{"Track 1", "Track 2", "Track 3", "Track 4"}

project_track_default :: proc(i: int) -> Project_Track {
	return Project_Track {
		name = PROJECT_TRACK_NAMES[clamp(i, 0, 3)],
		input = i + 1,
		level = 0.8,
		pan = 0,
		eq = dsp.eq_params_default(),
		comp = dsp.comp_params_default(),
	}
}

project_default :: proc() -> Project_Doc {
	tracks := make([]Project_Track, 4)
	for i in 0 ..< 4 {
		tracks[i] = project_track_default(i)
	}
	return Project_Doc {
		version = PROJECT_VERSION,
		name = "untitled",
		sample_rate = 48_000,
		bpm = 120,
		device = "",
		tracks = tracks,
		master = project_master_default(),
	}
}

eq_view_from_params :: proc(p: dsp.Eq_Params) -> ui.Eq_View {
	return ui.Eq_View {
		enabled = p.enabled,
		low_db = p.low_db,
		mid_db = p.mid_db,
		mid_hz = p.mid_hz,
		mid_q = p.mid_q,
		high_db = p.high_db,
	}
}

comp_view_from_params :: proc(p: dsp.Comp_Params) -> ui.Comp_View {
	return ui.Comp_View {
		enabled = p.enabled,
		threshold_db = p.threshold_db,
		ratio = p.ratio,
		attack_ms = p.attack_ms,
		release_ms = p.release_ms,
		knee_db = p.knee_db,
		auto_makeup = p.auto_makeup,
	}
}

eq_params_from_view :: proc(v: ui.Eq_View) -> dsp.Eq_Params {
	return dsp.Eq_Params {
		enabled = v.enabled,
		low_db = v.low_db,
		mid_db = v.mid_db,
		mid_hz = v.mid_hz,
		mid_q = v.mid_q,
		high_db = v.high_db,
	}
}

comp_params_from_view :: proc(v: ui.Comp_View) -> dsp.Comp_Params {
	return dsp.Comp_Params {
		enabled = v.enabled,
		threshold_db = v.threshold_db,
		ratio = v.ratio,
		attack_ms = v.attack_ms,
		release_ms = v.release_ms,
		knee_db = v.knee_db,
		makeup_db = 0,
		mix = 1,
		auto_makeup = v.auto_makeup,
	}
}

settings_from_app :: proc(a: ^ui.App) -> dsp.Fx_Settings {
	settings := dsp.fx_settings_default()
	settings.tracks = make([]dsp.Track_Mix, 4)
	any_solo := false
	for t in a.tracks {
		if t.soloed {
			any_solo = true
		}
	}
	for i in 0 ..< 4 {
		t := a.tracks[i]
		settings.tracks[i] = dsp.Track_Mix {
			level = t.level,
			pan = t.pan,
			muted = t.muted || (any_solo && !t.soloed),
			send_reverb = t.send_reverb,
			send_delay = t.send_delay,
			eq = eq_params_from_view(t.eq),
			comp = comp_params_from_view(t.comp),
		}
	}
	settings.master_comp = comp_params_from_view(a.master.comp)
	settings.reverb = dsp.Reverb_Params {
		enabled = a.master.reverb.enabled,
		size = a.master.reverb.size,
		decay = a.master.reverb.decay,
		tone = a.master.reverb.tone,
		predelay_ms = a.master.reverb.predelay_ms,
		return_level = a.master.reverb.return_level,
	}
	settings.delay = dsp.Delay_Params {
		enabled = a.master.delay.enabled,
		time_ms = a.master.delay.time_ms,
		feedback = a.master.delay.feedback,
		tone = a.master.delay.tone,
		ping_pong = a.master.delay.ping_pong,
		return_level = a.master.delay.return_level,
	}
	settings.width = dsp.Width_Params {
		enabled = a.master.width.enabled,
		width = a.master.width.width,
		bass_hz = a.master.width.bass_hz,
	}
	settings.limiter = dsp.Limiter_Params {
		enabled = a.master.limiter.enabled,
		ceiling_db = a.master.limiter.ceiling_db,
		release_ms = a.master.limiter.release_ms,
		lookahead_ms = a.master.limiter.lookahead_ms,
	}
	return settings
}

app_apply_settings :: proc(a: ^ui.App, s: dsp.Fx_Settings) {
	for i in 0 ..< min(len(s.tracks), 4) {
		t := s.tracks[i]
		a.tracks[i].level = t.level
		a.tracks[i].pan = t.pan
		a.tracks[i].muted = t.muted
		a.tracks[i].send_reverb = t.send_reverb
		a.tracks[i].send_delay = t.send_delay
		a.tracks[i].eq = eq_view_from_params(t.eq)
		a.tracks[i].comp = comp_view_from_params(t.comp)
	}
	a.master.comp = comp_view_from_params(s.master_comp)
	a.master.reverb = ui.Reverb_View {
		enabled = s.reverb.enabled,
		size = s.reverb.size,
		decay = s.reverb.decay,
		tone = s.reverb.tone,
		predelay_ms = s.reverb.predelay_ms,
		return_level = s.reverb.return_level,
	}
	a.master.delay = ui.Delay_View {
		enabled = s.delay.enabled,
		time_ms = s.delay.time_ms,
		feedback = s.delay.feedback,
		tone = s.delay.tone,
		return_level = s.delay.return_level,
		ping_pong = s.delay.ping_pong,
	}
	a.master.width = ui.Width_View {
		enabled = s.width.enabled,
		width = s.width.width,
		bass_hz = s.width.bass_hz,
	}
	a.master.limiter = ui.Limiter_View {
		enabled = s.limiter.enabled,
		ceiling_db = s.limiter.ceiling_db,
		release_ms = s.limiter.release_ms,
		lookahead_ms = s.limiter.lookahead_ms,
	}
}

project_from_app :: proc(a: ^ui.App) -> Project_Doc {
	doc := project_default()
	doc.name = ui.app_project(a)
	doc.sample_rate = a.sample_rate
	doc.bpm = a.bpm
	doc.device = ui.app_device(a)
	for i in 0 ..< 4 {
		t := a.tracks[i]
		doc.tracks[i].name = t.name
		doc.tracks[i].file = fmt.tprintf("track%d.wav", i + 1) if t.has_audio else ""
		doc.tracks[i].input = t.input
		doc.tracks[i].level = t.level
		doc.tracks[i].pan = t.pan
		doc.tracks[i].muted = t.muted
		doc.tracks[i].solo = t.soloed
		doc.tracks[i].armed = t.armed
		doc.tracks[i].send_reverb = t.send_reverb
		doc.tracks[i].send_delay = t.send_delay
		doc.tracks[i].eq = eq_params_from_view(t.eq)
		doc.tracks[i].comp = comp_params_from_view(t.comp)
	}
	doc.master.comp = comp_params_from_view(a.master.comp)
	doc.master.reverb = dsp.Reverb_Params {
		enabled = a.master.reverb.enabled,
		size = a.master.reverb.size,
		decay = a.master.reverb.decay,
		tone = a.master.reverb.tone,
		predelay_ms = a.master.reverb.predelay_ms,
		return_level = a.master.reverb.return_level,
	}
	doc.master.delay = dsp.Delay_Params {
		enabled = a.master.delay.enabled,
		time_ms = a.master.delay.time_ms,
		feedback = a.master.delay.feedback,
		tone = a.master.delay.tone,
		ping_pong = a.master.delay.ping_pong,
		return_level = a.master.delay.return_level,
	}
	doc.master.width = dsp.Width_Params {
		enabled = a.master.width.enabled,
		width = a.master.width.width,
		bass_hz = a.master.width.bass_hz,
	}
	doc.master.limiter = dsp.Limiter_Params {
		enabled = a.master.limiter.enabled,
		ceiling_db = a.master.limiter.ceiling_db,
		release_ms = a.master.limiter.release_ms,
		lookahead_ms = a.master.limiter.lookahead_ms,
	}
	return doc
}

project_save :: proc(a: ^ui.App, path: string) -> bool {
	doc := project_from_app(a)
	defer delete(doc.tracks)
	data, err := json.marshal(doc, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fmt.eprintfln("project encode failed: %v", err)
		return false
	}
	defer delete(data)
	if werr := os.write_entire_file(path, data); werr != nil {
		fmt.eprintfln("cannot write %s: %v", path, werr)
		return false
	}
	return true
}

project_load :: proc(a: ^ui.App, dir, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", path)
		return false
	}
	defer delete(data)

	// Start from zero so every allocated string belongs to the unmarshaler and
	// can be freed here; fill defaults explicitly afterwards.
	doc := Project_Doc {
		version = PROJECT_VERSION,
		sample_rate = 48_000,
		bpm = 120,
		master = project_master_default(),
	}
	if uerr := json.unmarshal(data, &doc); uerr != nil {
		fmt.eprintfln("project parse failed: %v", uerr)
		return false
	}
	defer {
		if len(doc.name) > 0 {
			delete(doc.name)
		}
		if len(doc.device) > 0 {
			delete(doc.device)
		}
		for t in doc.tracks {
			if len(t.name) > 0 {
				delete(t.name)
			}
			if len(t.file) > 0 {
				delete(t.file)
			}
		}
		delete(doc.tracks)
	}

	if doc.sample_rate == 0 {
		doc.sample_rate = 48_000
	}
	if doc.bpm == 0 {
		doc.bpm = 120
	}
	a.sample_rate = doc.sample_rate
	a.bpm = doc.bpm
	ui.app_set_project(a, doc.name if doc.name != "" else "untitled")
	if len(doc.device) > 0 {
		ui.app_set_device(a, doc.device)
	}

	for i in 0 ..< 4 {
		tr := &a.tracks[i]
		base := project_track_default(i)
		src: Project_Track
		have := i < len(doc.tracks)
		if have {
			src = doc.tracks[i]
		}

		if have && src.name != "" {
			if a.track_name_owned[i] {
				delete(tr.name)
			}
			tr.name = strings.clone(src.name)
			a.track_name_owned[i] = true
		} else {
			if a.track_name_owned[i] {
				delete(tr.name)
				a.track_name_owned[i] = false
			}
			tr.name = base.name
		}

		tr.input = clamp(src.input if have && src.input != 0 else base.input, 1, 32)
		tr.level = clamp(src.level if have && src.level != 0 else base.level, 0, 1.5)
		tr.pan = clamp(src.pan if have else 0, -1, 1)
		tr.muted = src.muted if have else false
		tr.soloed = src.solo if have else false
		tr.armed = src.armed if have else false
		tr.send_reverb = clamp(src.send_reverb if have else 0, 0, 1)
		tr.send_delay = clamp(src.send_delay if have else 0, 0, 1)

		eq := base.eq
		if have {
			eq.enabled = src.eq.enabled
			eq.low_db = src.eq.low_db
			eq.mid_db = src.eq.mid_db
			eq.mid_hz = src.eq.mid_hz if src.eq.mid_hz != 0 else 1_000
			eq.mid_q = src.eq.mid_q if src.eq.mid_q != 0 else 1
			eq.high_db = src.eq.high_db
			eq = dsp.eq_params_sanitized(eq)
		}
		tr.eq = eq_view_from_params(eq)

		comp := base.comp
		if have {
			comp.enabled = src.comp.enabled
			comp.threshold_db = src.comp.threshold_db
			comp.ratio = src.comp.ratio if src.comp.ratio != 0 else 3
			comp.attack_ms = src.comp.attack_ms if src.comp.attack_ms != 0 else 12
			comp.release_ms = src.comp.release_ms if src.comp.release_ms != 0 else 180
			comp.knee_db = src.comp.knee_db
			comp.auto_makeup = src.comp.auto_makeup
			comp = dsp.comp_params_sanitized(comp)
		}
		tr.comp = comp_view_from_params(comp)

		file := src.file if have else ""
		tr.has_audio = file != "" && os.exists(fmt.tprintf("%s/%s", dir, file))
	}

	m := doc.master
	a.master.comp = comp_view_from_params(dsp.comp_params_sanitized(m.comp))
	rp := dsp.reverb_params_sanitized(m.reverb)
	a.master.reverb = ui.Reverb_View {
		enabled = m.reverb.enabled,
		size = rp.size,
		decay = rp.decay,
		tone = rp.tone,
		predelay_ms = rp.predelay_ms,
		return_level = rp.return_level,
	}
	dp := dsp.delay_params_sanitized(m.delay)
	a.master.delay = ui.Delay_View {
		enabled = m.delay.enabled,
		time_ms = dp.time_ms,
		feedback = dp.feedback,
		tone = dp.tone,
		return_level = dp.return_level,
		ping_pong = m.delay.ping_pong,
	}
	wp := dsp.width_params_sanitized(m.width)
	a.master.width = ui.Width_View {
		enabled = m.width.enabled,
		width = wp.width,
		bass_hz = wp.bass_hz,
	}
	lp := dsp.limiter_params_sanitized(m.limiter)
	a.master.limiter = ui.Limiter_View {
		enabled = m.limiter.enabled,
		ceiling_db = lp.ceiling_db,
		release_ms = lp.release_ms,
		lookahead_ms = lp.lookahead_ms,
	}
	return true
}
