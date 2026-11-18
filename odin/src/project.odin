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

// A project is a fixed four-track document. Files claiming more tracks are
// rejected by the loader instead of being silently truncated.
PROJECT_MAX_LOAD_TRACKS :: 64
PROJECT_TRACK_NAME_MAX :: 64
PROJECT_NAME_MAX :: 64
PROJECT_DEVICE_NAME_MAX :: 64
PROJECT_FILE_NAME_MAX :: 255
PROJECT_SAMPLE_RATE_MIN :: 8_000
PROJECT_SAMPLE_RATE_MAX :: 192_000
PROJECT_BPM_MIN :: 40
PROJECT_BPM_MAX :: 240

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
	// Multi-take comping. Optional in the file: projects without it keep
	// working and are exposed as a single "Take 1" built from `file`.
	takes:       []Take        `json:"takes,omitempty"`,
	active_take: int           `json:"activeTake,omitempty"`,
	regions:     []Comp_Region `json:"compRegions,omitempty"`,
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
	latency_ms:  f32             `json:"latencyMs"`,
	high_contrast: bool          `json:"highContrast"`,
	reduced_motion: bool         `json:"reducedMotion"`,
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
	return project_from_app_with_takes(a, nil)
}

// `takes` is borrowed: the returned document only points at its slices and
// strings, so the caller must keep it alive until `json.marshal` completes.
project_from_app_with_takes :: proc(a: ^ui.App, takes: []Take_List) -> Project_Doc {
	doc := project_default()
	doc.name = ui.app_project(a)
	doc.sample_rate = a.sample_rate
	doc.bpm = a.bpm
	doc.latency_ms = a.latency_ms
	doc.high_contrast = a.high_contrast
	doc.reduced_motion = a.reduced_motion
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
		if len(takes) > i && len(takes[i].takes) > 0 {
			// Canonical file stays the first thing a legacy reader opens.
			doc.tracks[i].file = fmt.tprintf("track%d.wav", i + 1)
			doc.tracks[i].takes = takes[i].takes
			doc.tracks[i].active_take = takes[i].active
			doc.tracks[i].regions = takes[i].comp
		}
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

// The loader uses a fixed-size track array pre-filled with defaults. Unlike a
// freshly allocated slice, omitted JSON fields keep those defaults, so a
// partial track (or a partial eq/comp object) is merged instead of reset to
// zero. Explicit values survive, including level 0 and enabled=false.
@(private)
Project_Load_Doc :: struct {
	version:     int                     `json:"version"`,
	name:        string                  `json:"name"`,
	sample_rate: u32                     `json:"sampleRate"`,
	bpm:         int                     `json:"bpm"`,
	latency_ms:  f32                     `json:"latencyMs"`,
	high_contrast: bool                  `json:"highContrast"`,
	reduced_motion: bool                 `json:"reducedMotion"`,
	device:      string                  `json:"device"`,
	tracks:      [PROJECT_MAX_LOAD_TRACKS]Project_Track `json:"tracks"`,
	master:      Project_Master          `json:"master"`,
}

// JSON null would zero an otherwise pre-filled struct or array (and silently
// mute tracks). The project schema has no nulls, so reject them before the
// typed unmarshal. Unknown deeply nested values are bounded.
@(private)
project_value_has_nulls :: proc(value: json.Value, depth := 0) -> bool {
	if depth > 32 {
		return false
	}
	#partial switch v in value {
	case json.Null:
		return true
	case json.Array:
		for elem in v {
			if project_value_has_nulls(elem, depth + 1) {
				return true
			}
		}
	case json.Object:
		for _, elem in v {
			if project_value_has_nulls(elem, depth + 1) {
				return true
			}
		}
	}
	return false
}

@(private)
project_load_doc_free :: proc(d: ^Project_Load_Doc) {
	if len(d.name) > 0 {
		delete(d.name)
		d.name = ""
	}
	if len(d.device) > 0 {
		delete(d.device)
		d.device = ""
	}
	for i in 0 ..< PROJECT_MAX_LOAD_TRACKS {
		if len(d.tracks[i].name) > 0 {
			delete(d.tracks[i].name)
			d.tracks[i].name = ""
		}
		if len(d.tracks[i].file) > 0 {
			delete(d.tracks[i].file)
			d.tracks[i].file = ""
		}
		for &take in d.tracks[i].takes {
			if len(take.name) > 0 {
				delete(take.name)
				take.name = ""
			}
			if len(take.file) > 0 {
				delete(take.file)
				take.file = ""
			}
		}
		delete(d.tracks[i].takes)
		d.tracks[i].takes = nil
		delete(d.tracks[i].regions)
		d.tracks[i].regions = nil
	}
}

@(private)
parent_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	if i < 0 {
		return "."
	}
	if i == 0 {
		return "/"
	}
	return path[:i]
}

@(private)
ensure_parent_dir :: proc(path: string) -> bool {
	return ensure_dir(parent_dir(path))
}

// Write through a sibling temporary file and rename it into place. A failed
// encode, write or rename never leaves a truncated project.json behind.
@(private)
write_file_atomic :: proc(path: string, data: []u8) -> bool {
	if path == "" {
		fmt.eprintln("cannot write an empty path")
		return false
	}
	if os.is_directory(path) {
		fmt.eprintfln("cannot write %s: is a directory", path)
		return false
	}
	if !ensure_parent_dir(path) {
		return false
	}

	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if werr := os.write_entire_file(tmp, data); werr != nil {
		fmt.eprintfln("cannot write %s: %v", tmp, werr)
		_ = os.remove(tmp)
		return false
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		fmt.eprintfln("cannot replace %s: %v", path, rerr)
		_ = os.remove(tmp)
		return false
	}
	return true
}

// Untrusted project files may only name a file inside the session directory.
// Absolute paths, `..` components, NUL bytes and over-long names are rejected.
@(private)
project_file_is_local :: proc(file: string) -> bool {
	if file == "" || len(file) > PROJECT_FILE_NAME_MAX || os.is_absolute_path(file) {
		return false
	}
	start := 0
	for i in 0 ..= len(file) {
		if i < len(file) && file[i] != '/' {
			if file[i] == 0 {
				return false
			}
			continue
		}
		part := file[start:i]
		if part == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

@(private)
truncate_utf8 :: proc(s: string, max_bytes: int) -> string {
	if len(s) <= max_bytes {
		return s
	}
	n := max_bytes
	for n > 0 && (s[n] & 0xc0) == 0x80 {
		n -= 1
	}
	return s[:n]
}

project_save :: proc(a: ^ui.App, path: string) -> bool {
	return project_save_with_takes(a, nil, path)
}

// Saves the app plus optional per-track take lists. The take data is borrowed
// for the duration of the call; the lists remain the caller's.
project_save_with_takes :: proc(a: ^ui.App, takes: []Take_List, path: string) -> bool {
	doc := project_from_app_with_takes(a, takes)
	defer delete(doc.tracks)
	data, err := json.marshal(doc, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fmt.eprintfln("project encode failed: %v", err)
		return false
	}
	defer delete(data)
	return write_file_atomic(path, data)
}

project_load :: proc(a: ^ui.App, dir, path: string) -> bool {
	return project_load_with_takes(a, dir, path, nil)
}

// Loads a project and, when `takes` is non-nil, fills it with one list per
// track (up to four). Existing lists are cleared first. Projects without a
// `takes` array expose their legacy `file` as a single take named "Take 1".
project_load_with_takes :: proc(a: ^ui.App, dir, path: string, takes: []Take_List) -> bool {
	if dir == "" {
		fmt.eprintln("cannot load a project without a session directory")
		return false
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", path)
		return false
	}
	defer delete(data)

	value, verr := json.parse(data, .JSON)
	if verr != nil {
		fmt.eprintfln("project parse failed: %v", verr)
		return false
	}
	defer json.destroy_value(value)
	if project_value_has_nulls(value) {
		fmt.eprintln("project contains null values")
		return false
	}

	// Set defaults before unmarshalling and free every allocated string even
	// when the parse fails halfway through.
	doc := Project_Load_Doc {
		version = PROJECT_VERSION,
		sample_rate = 48_000,
		bpm = 120,
		master = project_master_default(),
	}
	for i in 0 ..< PROJECT_MAX_LOAD_TRACKS {
		doc.tracks[i] = project_track_default(i % 4)
		// Keep the default name static; an empty name is mapped to it below.
		doc.tracks[i].name = ""
	}
	defer project_load_doc_free(&doc)

	if uerr := json.unmarshal(data, &doc, .JSON); uerr != nil {
		fmt.eprintfln("project parse failed: %v", uerr)
		return false
	}
	if doc.version > PROJECT_VERSION {
		fmt.eprintfln("project version %d is newer than supported version %d", doc.version, PROJECT_VERSION)
		return false
	}
	if doc.version < 0 {
		fmt.eprintfln("project version %d is invalid", doc.version)
		return false
	}

	sample_rate := doc.sample_rate
	if sample_rate < PROJECT_SAMPLE_RATE_MIN || sample_rate > PROJECT_SAMPLE_RATE_MAX {
		sample_rate = 48_000
	}
	bpm := doc.bpm
	if bpm <= 0 {
		bpm = 120
	} else {
		bpm = clamp(bpm, PROJECT_BPM_MIN, PROJECT_BPM_MAX)
	}

	a.sample_rate = sample_rate
	a.bpm = bpm
	a.latency_ms = clamp(doc.latency_ms, 0, 10_000)
	a.high_contrast = doc.high_contrast
	a.reduced_motion = doc.reduced_motion
	ui.app_set_project(a, truncate_utf8(doc.name, PROJECT_NAME_MAX) if doc.name != "" else "untitled")
	if len(doc.device) > 0 {
		ui.app_set_device(a, truncate_utf8(doc.device, PROJECT_DEVICE_NAME_MAX))
	}

	for i in 0 ..< 4 {
		tr := &a.tracks[i]
		base := project_track_default(i)
		src := doc.tracks[i]

		if src.name != "" {
			if a.track_name_owned[i] {
				delete(tr.name)
			}
			tr.name = strings.clone(truncate_utf8(src.name, PROJECT_TRACK_NAME_MAX))
			a.track_name_owned[i] = true
		} else {
			if a.track_name_owned[i] {
				delete(tr.name)
				a.track_name_owned[i] = false
			}
			tr.name = base.name
		}

		input := src.input
		if input == 0 {
			input = base.input
		}
		tr.input = clamp(input, 1, 32)
		tr.level = clamp(src.level, 0, 1.5)
		tr.pan = clamp(src.pan, -1, 1)
		tr.muted = src.muted
		tr.soloed = src.solo
		tr.armed = src.armed
		tr.send_reverb = clamp(src.send_reverb, 0, 1)
		tr.send_delay = clamp(src.send_delay, 0, 1)

		tr.eq = eq_view_from_params(dsp.eq_params_sanitized(src.eq))
		tr.comp = comp_view_from_params(dsp.comp_params_sanitized(src.comp))

		file := src.file
		tr.has_audio = false
		if file != "" && project_file_is_local(file) {
			track_path := fmt.tprintf("%s/%s", dir, file)
			tr.has_audio = os.exists(track_path) && !os.is_directory(track_path)
		}
		for take in src.takes {
			if tr.has_audio {
				break
			}
			if take.file == "" || !project_file_is_local(take.file) {
				continue
			}
			take_path := fmt.tprintf("%s/%s", dir, take.file)
			tr.has_audio = os.exists(take_path) && !os.is_directory(take_path)
		}
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

	for i in 0 ..< min(len(takes), 4) {
		list := &takes[i]
		take_list_clear(list)
		src := doc.tracks[i]

		if len(src.takes) > 0 {
			for take in src.takes {
				if take.file == "" || !project_file_is_local(take.file) {
					continue
				}
				rate := take.sample_rate
				if rate < PROJECT_SAMPLE_RATE_MIN || rate > PROJECT_SAMPLE_RATE_MAX {
					rate = 0
				}
				_ = take_list_add(
					list,
					take.name,
					take.file,
					rate,
					take.offset,
					take.gain,
					take.muted,
					take.id,
				)
			}
		} else if src.file != "" && project_file_is_local(src.file) {
			// Backward compatibility: a plain `file` project is one take.
			_ = take_list_add(list, "Take 1", src.file, sample_rate, 0, 1, false, 1)
		}

		if len(list.takes) > 0 {
			if src.active_take <= TAKE_ID_NONE || !take_list_select(list, src.active_take) {
				list.active = list.takes[0].id
			}
		}
		for region in src.regions {
			_ = comp_add_region(list, region.take_id, region.start_frame, region.end_frame)
		}
	}
	return true
}
