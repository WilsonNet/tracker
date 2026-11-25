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
	if !os.exists(path) {
		delete(e.loaded[track])
		e.loaded[track] = nil
		e.loaded_rate[track] = 0
		if a != nil {
			a.tracks[track].has_audio = false
			a.tracks[track].peak_db = -60
			a.tracks[track].rms_db = -60
		}
		return true, false
	}
	wav, ok_read := wav_read(path)
	if !ok_read || wav.frames == 0 {
		wav_destroy(&wav)
		delete(e.loaded[track])
		e.loaded[track] = nil
		e.loaded_rate[track] = 0
		if a != nil {
			a.tracks[track].has_audio = false
			a.tracks[track].peak_db = -60
			a.tracks[track].rms_db = -60
		}
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

// 1-based ordinal of the active take in `e.takes[track].takes`, or 0 when
// comp mode / no active take is selected. Used by the UI readout (`1/2`).
engine_take_active_ordinal :: proc(e: ^Engine, track: int) -> int {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return 0
	}
	list := &e.takes[track]
	if list.active == TAKE_ID_NONE {
		return 0
	}
	for take, i in list.takes {
		if take.id == list.active {
			return i + 1
		}
	}
	return 0
}

// Selects a take by id (0 = comp/none) and reloads that track immediately.
engine_take_select :: proc(e: ^Engine, a: ^ui.App, track, id: int) -> bool {
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		return false
	}
	if !take_list_select(&e.takes[track], id) {
		return false
	}
	was_playing := engine_tracks_begin_edit(e)
	handled, ok := engine_load_track_from_takes(e, a, track)
	engine_tracks_end_edit(e, was_playing)
	engine_sync_tape_length(e, a)
	if !handled {
		return false
	}
	if !ok {
		if take, has := take_list_active(&e.takes[track]); has && take.file != "" {
			if !os.exists(fmt.tprintf("%s/%s", e.session_dir, take.file)) {
				return true
			}
		}
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

// Deletes the active take on `track`. The take's WAV moves into
// `<session_dir>/deleted/` (unless another take shares the file), comp regions
// referencing it are removed, and the engine reloads a neighboring take or
// clears the slot when the last take goes.
engine_take_delete :: proc(e: ^Engine, a: ^ui.App, track: int) -> (ok: bool, message: string) {
	if e.rec.active || e.play.active {
		return false, "stop the tape to delete a take"
	}
	if track < 0 || track >= MAX_ENGINE_TRACKS || (a != nil && track >= a.track_count) {
		return false, "select a track first"
	}
	if e.session_dir == "" {
		return false, "no project folder"
	}
	engine_takes_ensure(e)
	list := &e.takes[track]
	if len(list.takes) == 0 {
		return false, "no takes on this track"
	}
	if list.active == TAKE_ID_NONE {
		return false, "select a take first (t/T) — comp active"
	}
	del_idx := -1
	for take, i in list.takes {
		if take.id == list.active {
			del_idx = i
			break
		}
	}
	if del_idx < 0 {
		return false, "no active take to delete"
	}

	take_id := list.takes[del_idx].id
	raw_name := list.takes[del_idx].name
	take_name := strings.clone(raw_name if raw_name != "" else fmt.tprintf("Take %d", take_id), context.temp_allocator)
	take_file := strings.clone(list.takes[del_idx].file, context.temp_allocator)

	next_active := TAKE_ID_NONE
	if len(list.takes) > 1 {
		if del_idx + 1 < len(list.takes) {
			next_active = list.takes[del_idx + 1].id
		} else {
			next_active = list.takes[del_idx - 1].id
		}
	}
	shared_file := false
	for take, i in list.takes {
		if i != del_idx && take.file == take_file {
			shared_file = true
			break
		}
	}

	was_playing := engine_tracks_begin_edit(e)
	_ = take_list_remove(list, take_id)
	if next_active != TAKE_ID_NONE {
		_ = take_list_select(list, next_active)
	}
	if !shared_file && take_file != "" {
		trash_file(e, take_file)
	}
	if len(list.takes) == 0 {
		delete(e.loaded[track])
		e.loaded[track] = nil
		e.loaded_rate[track] = 0
		if a != nil {
			a.tracks[track].has_audio = false
			a.tracks[track].peak_db = -60
			a.tracks[track].rms_db = -60
			for h in 0 ..< ui.HISTORY_LEN {
				a.peak_history[track][h] = -60
			}
		}
	} else {
		_, loaded_ok := engine_load_track_from_takes(e, a, track)
		if !loaded_ok {
			delete(e.loaded[track])
			e.loaded[track] = nil
			e.loaded_rate[track] = 0
			if a != nil {
				a.tracks[track].has_audio = false
			}
		}
	}
	engine_tracks_end_edit(e, was_playing)
	engine_sync_tape_length(e, a)
	if a != nil {
		a.dirty = true
	}
	return true, fmt.tprintf("%s deleted · audio kept in deleted/", take_name)
}

// Opt-in multi-take creation: stabilizes the current take into a dedicated
// archived WAV (`track{N}-take{ID}.wav`) and opens an empty new take slot so the
// next recording starts fresh without overwriting prior takes.
engine_take_new :: proc(e: ^Engine, a: ^ui.App, track: int) -> (ok: bool, message: string) {
	if e.rec.active || e.play.active {
		return false, "stop the tape to create a new take"
	}
	if track < 0 || track >= MAX_ENGINE_TRACKS || (a != nil && track >= a.track_count) {
		return false, "select a track first"
	}
	if e.session_dir == "" {
		return false, "no project folder"
	}
	engine_takes_ensure(e)
	list := &e.takes[track]
	if len(list.takes) == 0 {
		return false, "record on this track first"
	}
	if e.loaded[track] == nil {
		return false, "current take is already empty"
	}
	if len(list.takes) >= TAKE_MAX {
		return false, "track already has max takes"
	}

	engine_take_stabilize_canonical(e, track)
	canonical := fmt.tprintf("track%d.wav", track + 1)
	for take in list.takes {
		if take.file == canonical {
			return false, "could not archive current take"
		}
	}
	canonical_path := fmt.tprintf("%s/%s", e.session_dir, canonical)
	if os.exists(canonical_path) {
		_ = os.remove(canonical_path)
	}

	comp_clear(list)
	engine_take_register_new(e, track, e.sample_rate)

	was_playing := engine_tracks_begin_edit(e)
	delete(e.loaded[track])
	e.loaded[track] = nil
	e.loaded_rate[track] = 0
	engine_tracks_end_edit(e, was_playing)
	if a != nil {
		a.tracks[track].has_audio = false
		a.tracks[track].peak_db = -60
		a.tracks[track].rms_db = -60
		for h in 0 ..< ui.HISTORY_LEN {
			a.peak_history[track][h] = -60
		}
		a.dirty = true
	}
	engine_sync_tape_length(e, a)

	track_name := fmt.tprintf("Track %d", track + 1)
	if a != nil && track < a.track_count && a.tracks[track].name != "" {
		track_name = a.tracks[track].name
	}
	return true, fmt.tprintf("Take %d ready on %s · press r to record", list.active, track_name)
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
	if e.rec_punch_out > 0 {
		e.rec_punch_out = int(f64(e.rec_punch_out) * ratio)
	}
}

// Overwrites `existing[punch : punch + len(recorded)]` in place with short linear
// crossfades at punch-in and punch-out boundaries where existing audio overlaps.
@(private)
tape_splice_overwrite :: proc(existing: []f32, punch: int, recorded: []f32, rate: u32) -> []f32 {
	start := max(punch, 0)
	old_len := len(existing)
	rec_len := len(recorded)
	out_len := max(old_len, start + rec_len)
	out := make([]f32, out_len)
	if old_len > 0 {
		copy(out[:old_len], existing)
	}
	if rec_len > 0 {
		copy(out[start:start + rec_len], recorded)
	}
	if old_len > 0 && rec_len > 0 {
		xfade := min(max(int(rate) / 250, 16), 192)
		xf_in := 0
		if start > 0 && start < old_len {
			xf_in = min(xfade, rec_len / 2, old_len - start)
			for k in 0 ..< xf_in {
				t := f32(k) / f32(xf_in)
				out[start + k] = existing[start + k] * (1.0 - t) + recorded[k] * t
			}
		}
		end := start + rec_len
		if end < old_len && rec_len > xf_in {
			xf_out := min(xfade, rec_len - xf_in, old_len - end)
			for k in 0 ..< xf_out {
				t := f32(k) / f32(xf_out)
				out[end - xf_out + k] = recorded[rec_len - xf_out + k] * (1.0 - t) + existing[end - xf_out + k] * t
			}
		}
	}
	return out
}

// Writes one finished capture onto the track's active take WAV in tape style:
// overwriting only `[punch, punch + len(mono))` in place while preserving
// audio before and after the punch. Multiple takes are opt-in via `engine_take_new`.
// Takes ownership of `mono`.
@(private)
engine_commit_recorded_take :: proc(e: ^Engine, a: ^ui.App, track: int, rate: u32, mono: []f32) -> bool {
	defer delete(mono)
	punch := max(e.rec_punch, 0)
	list := &e.takes[track]
	if len(list.takes) == 0 {
		_ = takes_load_from_dir(list, e.session_dir, track)
	}
	if len(list.takes) == 0 {
		engine_take_register_new(e, track, rate)
	} else if list.active == TAKE_ID_NONE {
		_ = take_list_select(list, list.takes[len(list.takes) - 1].id)
	}
	take, has_take := take_list_active(list)
	if !has_take || take.file == "" {
		return false
	}

	existing: []f32
	existing_rate: u32 = 0
	existing_owned := false
	defer if existing_owned {
		delete(existing)
	}

	if len(list.comp) == 0 && e.loaded[track] != nil {
		existing = e.loaded[track]
		existing_rate = e.loaded_rate[track]
	} else {
		existing_path := fmt.tprintf("%s/%s", e.session_dir, take.file)
		if os.exists(existing_path) {
			wav, ok_read := wav_read(existing_path)
			if ok_read && wav.frames > 0 {
				buf := make([]f32, wav.frames)
				ch := int(wav.channels)
				for f in 0 ..< wav.frames {
					sum: f32 = 0
					for c in 0 ..< ch {
						sum += wav.samples[f * ch + c]
					}
					buf[f] = sum / f32(max(ch, 1))
				}
				existing = buf
				existing_rate = wav.sample_rate
				existing_owned = true
			}
			wav_destroy(&wav)
		}
	}

	// Legacy offset takes stored unpadded WAVs starting at `take.offset`; pad to timeline 0 before overwriting.
	if take.offset > 0 && len(existing) > 0 {
		padded := make([]f32, take.offset + len(existing))
		copy(padded[take.offset:], existing)
		if existing_owned {
			delete(existing)
		}
		existing = padded
		existing_owned = true
	}

	if len(existing) > 0 && existing_rate != 0 && existing_rate != rate {
		resampled := dsp.resample(existing, existing_rate, rate)
		if existing_owned {
			delete(existing)
		}
		existing = resampled
		existing_owned = true
	}

	merged := tape_splice_overwrite(existing, punch, mono, rate)
	path := fmt.tprintf("%s/%s", e.session_dir, take.file)
	tmp := fmt.tprintf("%s.tmp", path)
	if !wav_write(tmp, rate, 1, merged) {
		_ = os.remove(tmp)
		delete(merged)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		delete(merged)
		return false
	}

	take.sample_rate = rate
	take.offset = 0
	comp_clear(list)

	was_playing := engine_tracks_begin_edit(e)
	delete(e.loaded[track])
	e.loaded[track] = merged
	e.loaded_rate[track] = rate
	engine_tracks_end_edit(e, was_playing)
	if a != nil {
		a.tracks[track].has_audio = true
	}
	return true
}
