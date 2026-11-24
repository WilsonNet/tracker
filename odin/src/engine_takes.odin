// Engine-side take/comp loading and take registration.
// The pure model lives in takes.odin; this file connects it to the audio slots.

package main

import "core:fmt"
import "core:os"
import "core:strings"

import dsp "dsp"
import ui "ui"

@(private)
engine_takes_clear :: proc(e: ^Engine) {
	for i in 0 ..< MAX_ENGINE_TRACKS {
		take_list_clear(&e.takes[i])
	}
}

@(private)
engine_takes_ensure :: proc(e: ^Engine) {
	if e.session_dir == "" {
		return
	}
	for i in 0 ..< MAX_ENGINE_TRACKS {
		if len(e.takes[i].takes) == 0 {
			_ = takes_load_from_dir(&e.takes[i], e.session_dir, i)
		}
	}
}

// The canonical trackN.wav is the latest take. Before overwriting it with a
// new take, copy its audio to the stable take file so the old take survives.
@(private)
engine_take_stabilize_canonical :: proc(e: ^Engine, track: int) {
	list := &e.takes[track]
	if len(list.takes) == 0 {
		_ = takes_load_from_dir(list, e.session_dir, track)
	}
	canonical := fmt.tprintf("track%d.wav", track + 1)
	for &take in list.takes {
		if take.file != canonical {
			continue
		}
		stable := fmt.tprintf("track%d-take%d.wav", track + 1, take.id)
		src := fmt.tprintf("%s/%s", e.session_dir, canonical)
		dst := fmt.tprintf("%s/%s", e.session_dir, stable)
		if !os.exists(dst) && os.exists(src) {
			if !copy_file(src, dst) {
				continue
			}
		}
		delete(take.file)
		take.file = strings.clone(stable)
	}
}

@(private)
engine_take_register_new :: proc(e: ^Engine, track: int, rate: u32, label := "", offset := 0) {
	list := &e.takes[track]
	id := take_list_next_id(list)
	name := label if label != "" else fmt.tprintf("Take %d", id)
	file := fmt.tprintf("track%d.wav", track + 1)
	new_id := take_list_add(list, name, file, rate, offset, 1.0, false, id)
	_ = take_list_select(list, new_id)
}

// Returns (handled, ok). handled=false means the caller should use the legacy
// canonical-file path.
@(private)
engine_load_track_from_takes :: proc(e: ^Engine, a: ^ui.App, track: int) -> (handled: bool, ok: bool) {
	list := &e.takes[track]
	if len(list.takes) == 0 {
		return false, false
	}

	if len(list.comp) > 0 {
		buffers, loaded := takes_load_buffers(e.session_dir, list)
		if loaded {
			resampled := make([]Take_Buffer, len(buffers))
			all_ok := true
			for buffer, i in buffers {
				resampled[i] = Take_Buffer {
					take_id = buffer.take_id,
					sample_rate = e.sample_rate,
				}
				if buffer.sample_rate == e.sample_rate {
					resampled[i].samples = make([]f32, len(buffer.samples))
					copy(resampled[i].samples, buffer.samples)
				} else {
					resampled[i].samples = dsp.resample(buffer.samples, buffer.sample_rate, e.sample_rate)
				}
				if resampled[i].samples == nil {
					all_ok = false
				}
			}
			take_buffers_free(buffers)
			if all_ok {
				comp, comp_ok := comp_render(list, resampled)
				take_buffers_free(resampled)
				if comp_ok {
					delete(e.loaded[track])
					e.loaded[track] = comp
					e.loaded_rate[track] = e.sample_rate
					if a != nil {
						a.tracks[track].has_audio = len(comp) > 0
					}
					return true, true
				}
			} else {
				take_buffers_destroy(resampled)
				delete(resampled)
			}
		}
	}

	take, has_take := take_list_active(list)
	if !has_take {
		return true, false
	}
	path := fmt.tprintf("%s/%s", e.session_dir, take.file)
	wav, ok_read := wav_read(path)
	if !ok_read || wav.frames == 0 {
		wav_destroy(&wav)
		return true, false
	}
	mono := make([]f32, wav.frames)
	channels := int(wav.channels)
	for f in 0 ..< wav.frames {
		sum: f32 = 0
		for c in 0 ..< channels {
			sum += wav.samples[f * channels + c]
		}
		mono[f] = sum / f32(max(channels, 1))
	}
	delete(e.loaded[track])
	e.loaded[track] = mono
	e.loaded_rate[track] = wav.sample_rate
	if a != nil {
		a.tracks[track].has_audio = true
	}
	wav_destroy(&wav)
	return true, true
}

engine_take_count :: proc(e: ^Engine, track: int) -> int {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return 0
	}
	return len(e.takes[track].takes)
}

engine_take_active :: proc(e: ^Engine, track: int) -> int {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return TAKE_ID_NONE
	}
	return e.takes[track].active
}

// Selects a take by id (0 = comp/none) and reloads that track immediately.
engine_take_select :: proc(e: ^Engine, a: ^ui.App, track, id: int) -> bool {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return false
	}
	if !take_list_select(&e.takes[track], id) {
		return false
	}
	handled, ok := engine_load_track_from_takes(e, a, track)
	if !handled {
		return false
	}
	return ok
}

// Builds a one-region comp from the active take's full loaded length. This is
// the UI's whole-take comping action; the CLI can add arbitrary regions.
engine_comp_use_active :: proc(e: ^Engine, a: ^ui.App, track: int) -> bool {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return false
	}
	list := &e.takes[track]
	take, has := take_list_active(list)
	if !has {
		return false
	}
	frames := len(e.loaded[track])
	if frames <= 0 {
		return false
	}
	comp_clear(list)
	if !comp_add_region(list, take.id, 0, frames) {
		return false
	}
	if a != nil {
		ui.status_buf_set(a, "comp: active take")
	}
	return true
}

engine_comp_clear :: proc(e: ^Engine, a: ^ui.App, track: int) -> bool {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return false
	}
	comp_clear(&e.takes[track])
	if a != nil {
		ui.status_buf_set(a, "comp cleared")
	}
	return true
}

engine_take_cycle :: proc(e: ^Engine, a: ^ui.App, track, delta: int) -> bool {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return false
	}
	list := &e.takes[track]
	if len(list.takes) == 0 {
		return false
	}
	idx := 0
	for take, i in list.takes {
		if take.id == list.active {
			idx = i
		}
	}
	idx = (idx + delta + len(list.takes)) % len(list.takes)
	return engine_take_select(e, a, track, list.takes[idx].id)
}

// Rescales the UI's punch point when the opened device runs at another rate
// than the project (frames are counted at the project rate until then).
@(private)
engine_rescale_punch :: proc(e: ^Engine, a: ^ui.App, new_rate: u32) {
	old_rate := a.sample_rate if a.sample_rate != 0 else 48_000
	if new_rate == 0 || new_rate == old_rate {
		return
	}
	ratio := f64(new_rate) / f64(old_rate)
	e.rec_punch = int(f64(e.rec_punch) * ratio)
	e.rec_pre = int(f64(e.rec_pre) * ratio)
}

// Writes one finished capture as the track's new take. At punch 0 this is the
// classic behaviour (the new take becomes the active take). From a punch point
// the take carries its timeline offset and is comped over the old audio only
// between punch-in and punch-out, so the rest of the track keeps sounding.
// Takes ownership of `mono`.
@(private)
engine_commit_recorded_take :: proc(e: ^Engine, a: ^ui.App, track: int, rate: u32, mono: []f32) -> bool {
	punch := e.rec_punch
	list := &e.takes[track]
	old_active := list.active
	if len(list.takes) == 0 {
		_ = takes_load_from_dir(list, e.session_dir, track)
		old_active = list.active
	}
	old_len := len(e.loaded[track])
	if e.loaded_rate[track] != 0 && e.loaded_rate[track] != e.sample_rate && e.sample_rate != 0 {
		old_len = int(f64(old_len) * f64(e.sample_rate) / f64(e.loaded_rate[track]))
	}

	path := fmt.tprintf("%s/track%d.wav", e.session_dir, track + 1)
	engine_take_stabilize_canonical(e, track)
	if !wav_write(path, rate, 1, mono) {
		delete(mono)
		return false
	}
	if punch <= 0 {
		engine_take_register_new(e, track, rate)
		delete(e.loaded[track])
		e.loaded[track] = mono
		e.loaded_rate[track] = rate
		if a != nil {
			a.tracks[track].has_audio = true
		}
		return true
	}

	label := fmt.tprintf("Punch @%.1fs", f32(punch) / f32(max(e.sample_rate, 1)))
	engine_take_register_new(e, track, rate, label, punch)
	new_id := take_list_next_id(list) - 1
	end := punch + len(mono)
	if rate != e.sample_rate && rate != 0 && e.sample_rate != 0 {
		end = punch + int(f64(len(mono)) * f64(e.sample_rate) / f64(rate))
	}
	// If no comp can be built the new take simply stays the active take.
	_ = comp_punch(list, old_active, new_id, punch, end, old_len)
	delete(mono)
	_, _ = engine_load_track_from_takes(e, a, track)
	if a != nil {
		a.tracks[track].has_audio = true
	}
	return true
}
