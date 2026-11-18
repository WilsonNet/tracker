// Multi-take recording and comping model.
//
// This file is deliberately pure data + buffer math: no engine, UI, device or
// playback state. The owning types are explicit:
//
//   Take_List  owns its `takes` slice, every non-empty take.name/take.file
//              string, and its `comp` slice. `take_list_clear` / `_destroy`
//              release all of it.
//   Take_Buffer / []Take_Buffer  own only the `samples` slices.
//              `take_buffers_destroy` releases them.
//
// Timeline convention: a region is [start_frame, end_frame) in project
// frames. A take maps to the timeline at `timeline = take.offset + source`,
// and `gain` / `muted` are applied while comping. Take buffers are expected
// to already be mono and at the project sample rate; the engine resamples
// before calling `comp_render` (the per-take sample_rate stays in the model
// so it can do that).

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

TAKE_NAME_MAX :: 64
TAKE_FILE_NAME_MAX :: 255
TAKE_MAX :: 64
COMP_MAX_REGIONS :: 256

// Short equal-power crossfade used at abutting comp boundaries and at the
// outer edges of a region.
TAKE_CROSSFADE_FRAMES :: 64
TAKE_ID_NONE :: 0

Take :: struct {
	id:          int    `json:"id"`,
	name:        string `json:"name"`,
	file:        string `json:"file"`,
	sample_rate: u32    `json:"sampleRate"`,
	offset:      int    `json:"offset"`,
	gain:        f32    `json:"gain"`,
	muted:       bool   `json:"muted"`,
}

Comp_Region :: struct {
	take_id:     int `json:"takeId"`,
	start_frame: int `json:"startFrame"`,
	end_frame:   int `json:"endFrame"`,
}

// One track's takes and comp. `active` is a take id (0 = none). The project
// schema splits these across `takes`, `activeTake` and `comp` so old readers
// can still use `file`.
Take_List :: struct {
	takes:  []Take,
	comp:   []Comp_Region,
	active: int,
}

Take_Buffer :: struct {
	take_id:     int,
	sample_rate: u32,
	samples:     []f32,
}

Take_Length :: struct {
	take_id: int,
	frames:  int,
}

Take_Match :: struct {
	id:   int,
	name: string,
}

// ---------------------------------------------------------------- ownership

take_list_clear :: proc(list: ^Take_List) {
	if list == nil {
		return
	}
	for &take in list.takes {
		if len(take.name) > 0 {
			delete(take.name)
			take.name = ""
		}
		if len(take.file) > 0 {
			delete(take.file)
			take.file = ""
		}
	}
	delete(list.takes)
	list.takes = nil
	delete(list.comp)
	list.comp = nil
	list.active = TAKE_ID_NONE
}

take_list_destroy :: proc(list: ^Take_List) {
	take_list_clear(list)
}

// Frees the sample ownership held by the buffers. The container slice itself
// belongs to the caller (it may be a literal or a stack slice); use
// `take_buffers_free` for slices returned by `takes_load_buffers`.
take_buffers_destroy :: proc(buffers: []Take_Buffer) {
	for i in 0 ..< len(buffers) {
		delete(buffers[i].samples)
		buffers[i].samples = nil
		buffers[i].take_id = TAKE_ID_NONE
	}
}

take_buffers_free :: proc(buffers: []Take_Buffer) {
	take_buffers_destroy(buffers)
	delete(buffers)
}

// ---------------------------------------------------------------- take CRUD

take_find :: proc(list: ^Take_List, id: int) -> (^Take, bool) {
	if list == nil || id <= TAKE_ID_NONE {
		return nil, false
	}
	for i in 0 ..< len(list.takes) {
		if list.takes[i].id == id {
			return &list.takes[i], true
		}
	}
	return nil, false
}

take_list_next_id :: proc(list: ^Take_List) -> int {
	next := 1
	for take in list.takes {
		if take.id >= next {
			next = take.id + 1
		}
	}
	return next
}

// Adds a take and takes ownership of cloned name/file copies. `id = 0` picks
// the next free id. Returns the id, or 0 when the list is full or the id is
// already present.
take_list_add :: proc(
	list: ^Take_List,
	name, file: string,
	sample_rate: u32 = 0,
	offset: int = 0,
	gain: f32 = 1,
	muted: bool = false,
	id: int = 0,
) -> int {
	if list == nil || file == "" || len(list.takes) >= TAKE_MAX {
		return 0
	}
	take_id := id
	if take_id <= 0 {
		take_id = take_list_next_id(list)
	} else if _, exists := take_find(list, take_id); exists {
		return 0
	}
	take := Take {
		id = take_id,
		sample_rate = sample_rate,
		offset = max(offset, 0),
		gain = clamp(gain, 0, 4),
		muted = muted,
	}
	if name == "" {
		take.name = fmt.aprintf("Take %d", take_id)
	} else {
		take.name = strings.clone(truncate_utf8(name, TAKE_NAME_MAX))
	}
	take.file = strings.clone(truncate_utf8(file, TAKE_FILE_NAME_MAX))

	next := make([]Take, len(list.takes) + 1)
	copy(next, list.takes)
	next[len(list.takes)] = take
	delete(list.takes)
	list.takes = next
	if list.active == TAKE_ID_NONE {
		list.active = take_id
	}
	return take_id
}

// Removes a take, its owned strings, and every comp region that referenced it.
take_list_remove :: proc(list: ^Take_List, id: int) -> bool {
	if list == nil || id <= TAKE_ID_NONE {
		return false
	}
	index := -1
	for take, i in list.takes {
		if take.id == id {
			index = i
			break
		}
	}
	if index < 0 {
		return false
	}

	take := list.takes[index]
	if len(take.name) > 0 {
		delete(take.name)
	}
	if len(take.file) > 0 {
		delete(take.file)
	}
	copy(list.takes[index:], list.takes[index + 1:])
	list.takes = list.takes[:len(list.takes) - 1]

	// Compact regions in place; the allocation stays owned by the list.
	write := 0
	for region in list.comp {
		if region.take_id != id {
			list.comp[write] = region
			write += 1
		}
	}
	list.comp = list.comp[:write]

	if list.active == id {
		list.active = list.takes[0].id if len(list.takes) > 0 else TAKE_ID_NONE
	}
	return true
}

take_list_select :: proc(list: ^Take_List, id: int) -> bool {
	if list == nil {
		return false
	}
	if id == TAKE_ID_NONE {
		list.active = TAKE_ID_NONE
		return true
	}
	if _, ok := take_find(list, id); !ok {
		return false
	}
	list.active = id
	return true
}

take_list_active :: proc(list: ^Take_List) -> (^Take, bool) {
	if list == nil {
		return nil, false
	}
	return take_find(list, list.active)
}

// The next free canonical take file: track{N}-take{M}.wav (1-based track).
// The returned string is owned by the caller.
take_next_filename :: proc(list: ^Take_List, track_index: int) -> string {
	for id in take_list_next_id(list) ..= TAKE_MAX * 4 {
		candidate := fmt.aprintf("track%d-take%d.wav", max(track_index, 0) + 1, id)
		used := false
		if list != nil {
			for take in list.takes {
				if take.file == candidate {
					used = true
					break
				}
			}
		}
		if !used {
			return candidate
		}
		delete(candidate)
	}
	return ""
}

// ---------------------------------------------------------------- comp regions

comp_length :: proc(list: ^Take_List) -> int {
	end := 0
	if list == nil {
		return 0
	}
	for region in list.comp {
		end = max(end, region.end_frame)
	}
	return end
}

// Inserts a region keeping the list ordered by start frame. Overlapping,
// empty, negative and unknown-take regions are rejected.
comp_add_region :: proc(list: ^Take_List, take_id, start_frame, end_frame: int) -> bool {
	if list == nil || len(list.comp) >= COMP_MAX_REGIONS {
		return false
	}
	if _, ok := take_find(list, take_id); !ok {
		return false
	}
	if start_frame < 0 || end_frame <= start_frame {
		return false
	}
	for region in list.comp {
		if start_frame < region.end_frame && end_frame > region.start_frame {
			return false
		}
	}

	position := len(list.comp)
	for region, i in list.comp {
		if start_frame < region.start_frame {
			position = i
			break
		}
	}

	next := make([]Comp_Region, len(list.comp) + 1)
	copy(next, list.comp[:position])
	next[position] = Comp_Region {
		take_id = take_id,
		start_frame = start_frame,
		end_frame = end_frame,
	}
	copy(next[position + 1:], list.comp[position:])
	delete(list.comp)
	list.comp = next
	return true
}

comp_remove_region :: proc(list: ^Take_List, index: int) -> bool {
	if list == nil || index < 0 || index >= len(list.comp) {
		return false
	}
	copy(list.comp[index:], list.comp[index + 1:])
	list.comp = list.comp[:len(list.comp) - 1]
	return true
}

comp_clear :: proc(list: ^Take_List) {
	if list == nil {
		return
	}
	delete(list.comp)
	list.comp = nil
}

@(private)
comp_measure_region :: proc(
	list: ^Take_List,
	region: Comp_Region,
	lengths: []Take_Length,
) -> bool {
	take, ok := take_find(list, region.take_id)
	if !ok || region.start_frame < 0 || region.end_frame <= region.start_frame {
		return false
	}
	for entry in lengths {
		if entry.take_id != region.take_id {
			continue
		}
		if entry.frames <= 0 {
			return false
		}
		available_start := max(take.offset, 0)
		available_end := take.offset + entry.frames
		return region.start_frame >= available_start && region.end_frame <= available_end
	}
	return false
}

// Checks ordering, overlap and that every region fits the referenced take
// buffer (after `offset`). Returns the first bad region index.
comp_validate :: proc(list: ^Take_List, lengths: []Take_Length) -> (ok: bool, bad_index: int) {
	if list == nil {
		return false, 0
	}
	previous_end := -1
	for region, i in list.comp {
		if region.start_frame < previous_end {
			return false, i
		}
		if !comp_measure_region(list, region, lengths) {
			return false, i
		}
		previous_end = region.end_frame
	}
	return true, -1
}

comp_validate_buffers :: proc(list: ^Take_List, buffers: []Take_Buffer) -> (ok: bool, bad_index: int) {
	if list == nil {
		return false, 0
	}
	previous_end := -1
	for region, i in list.comp {
		if region.start_frame < previous_end {
			return false, i
		}
		take, take_ok := take_find(list, region.take_id)
		buffer, buffer_ok := take_buffer_find(buffers, region.take_id)
		valid := take_ok && buffer_ok && region.start_frame >= 0 &&
		         region.end_frame > region.start_frame
		if valid {
			available_start := max(take.offset, 0)
			available_end := take.offset + len(buffer.samples)
			valid = region.start_frame >= available_start && region.end_frame <= available_end
		}
		if !valid {
			return false, i
		}
		previous_end = region.end_frame
	}
	return true, -1
}

take_buffer_find :: proc(buffers: []Take_Buffer, take_id: int) -> (^Take_Buffer, bool) {
	for i in 0 ..< len(buffers) {
		if buffers[i].take_id == take_id {
			return &buffers[i], true
		}
	}
	return nil, false
}

@(private)
add_take_sample :: proc(out: []f32, index: int, source: int, buffer: []f32, env, gain: f32) {
	if index < 0 || index >= len(out) || source < 0 || source >= len(buffer) {
		return
	}
	out[index] += buffer[source] * env * gain
}

@(private)
equal_power_in :: proc(position, length: int) -> f32 {
	p := clamp((f32(position) + 0.5) / f32(length), 0, 1)
	return math.sin(p * f32(math.PI) * 0.5)
}

@(private)
equal_power_out :: proc(remaining, length: int) -> f32 {
	p := clamp(1.0 - (f32(remaining) - 0.5) / f32(length), 0, 1)
	return math.cos(p * f32(math.PI) * 0.5)
}

// Renders the comp into a newly allocated mono buffer. Regions select audio
// from the take buffers, abutting regions are joined with an equal-power
// crossfade (the previous take's tail continues into the next region), gaps
// and everything outside the regions stay silent. Returns false when a region
// references a missing/too-short buffer.
comp_render :: proc(
	list: ^Take_List,
	buffers: []Take_Buffer,
	crossfade_frames := TAKE_CROSSFADE_FRAMES,
) -> ([]f32, bool) {
	if list == nil {
		return nil, false
	}
	if ok, _ := comp_validate_buffers(list, buffers); !ok {
		return nil, false
	}
	total := comp_length(list)
	if total <= 0 {
		return make([]f32, 0), true
	}
	out := make([]f32, total)
	cap_frames := max(crossfade_frames, 0)

	for region, index in list.comp {
		take, take_ok := take_find(list, region.take_id)
		buffer, buffer_ok := take_buffer_find(buffers, region.take_id)
		if !take_ok || !buffer_ok {
			delete(out)
			return nil, false
		}
		gain := take.gain
		if take.muted {
			gain = 0
		}
		length := region.end_frame - region.start_frame

		prev_crossfade := 0
		if index > 0 {
			previous := list.comp[index - 1]
			if previous.end_frame == region.start_frame {
				previous_length := previous.end_frame - previous.start_frame
				prev_crossfade = min(cap_frames, min(previous_length, length))
			}
		}
		next_crossfade := 0
		if index + 1 < len(list.comp) {
			next := list.comp[index + 1]
			if next.start_frame == region.end_frame {
				next_length := next.end_frame - next.start_frame
				next_crossfade = min(cap_frames, min(length, next_length))
			}
		}

		fade_in := min(cap_frames, length)
		fade_out := min(cap_frames, length)
		for frame in region.start_frame ..< region.end_frame {
			distance := frame - region.start_frame
			env: f32 = 1
			if prev_crossfade > 0 {
				if distance < prev_crossfade {
					env = equal_power_in(distance, prev_crossfade)
				}
			} else if fade_in > 0 && distance < fade_in {
				env = equal_power_in(distance, fade_in)
			}
			if next_crossfade == 0 && fade_out > 0 {
				remaining := region.end_frame - frame
				if remaining <= fade_out {
					env *= equal_power_out(remaining, fade_out)
				}
			}
			add_take_sample(out, frame, frame - take.offset, buffer.samples, env, gain)
		}

		// Continue the previous region into this one for an equal-power join.
		if prev_crossfade > 0 {
			previous := list.comp[index - 1]
			prev_take, prev_take_ok := take_find(list, previous.take_id)
			prev_buffer, prev_buffer_ok := take_buffer_find(buffers, previous.take_id)
			if prev_take_ok && prev_buffer_ok {
				prev_gain := prev_take.gain
				if prev_take.muted {
					prev_gain = 0
				}
				for frame in region.start_frame ..< region.start_frame + prev_crossfade {
					distance := frame - region.start_frame
					env := math.cos(
						clamp((f32(distance) + 0.5) / f32(prev_crossfade), 0, 1) *
						f32(math.PI) *
						0.5,
					)
					add_take_sample(
						out,
						frame,
						frame - prev_take.offset,
						prev_buffer.samples,
						env,
						prev_gain,
					)
				}
			}
		}
	}
	return out, true
}

// ---------------------------------------------------------------- session I/O

@(private)
mono_from_wav :: proc(wav: ^Wav) -> []f32 {
	if wav.frames <= 0 || wav.channels == 0 {
		return nil
	}
	mono := make([]f32, wav.frames)
	channels := int(wav.channels)
	for frame in 0 ..< wav.frames {
		sum: f32 = 0
		for channel in 0 ..< channels {
			sum += wav.samples[frame * channels + channel]
		}
		mono[frame] = sum / f32(channels)
	}
	return mono
}

// Loads every take in the list from `dir`, mono, at its native rate. All
// returned buffers are owned; free them with `take_buffers_destroy`.
takes_load_buffers :: proc(dir: string, list: ^Take_List) -> (buffers: []Take_Buffer, ok: bool) {
	if list == nil || dir == "" {
		return nil, false
	}
	buffers = make([]Take_Buffer, len(list.takes))
	for take, i in list.takes {
		if !project_file_is_local(take.file) {
			take_buffers_free(buffers)
			return nil, false
		}
		path := fmt.tprintf("%s/%s", dir, take.file)
		wav, read_ok := wav_read(path)
		if !read_ok || wav.frames <= 0 {
			wav_destroy(&wav)
			take_buffers_free(buffers)
			return nil, false
		}
		buffers[i] = Take_Buffer {
			take_id = take.id,
			sample_rate = wav.sample_rate,
			samples = mono_from_wav(&wav),
		}
		wav_destroy(&wav)
		if buffers[i].samples == nil {
			take_buffers_free(buffers)
			return nil, false
		}
	}
	return buffers, true
}

// Rebuilds a track's take list from `track{N}-take*.wav` files. Falls back to
// the canonical `track{N}.wav` as a single "Take 1". The list is replaced;
// previous owned strings are released first.
takes_load_from_dir :: proc(list: ^Take_List, dir: string, track_index: int) -> bool {
	if list == nil || dir == "" || !os.is_directory(dir) {
		return false
	}
	take_list_clear(list)

	files, read_err := os.read_directory_by_path(dir, -1, context.allocator)
	if read_err != nil {
		return false
	}
	defer os.file_info_slice_delete(files, context.allocator)

	prefix := fmt.aprintf("track%d-take", max(track_index, 0) + 1)
	defer delete(prefix)

	matches := make([dynamic]Take_Match)
	defer delete(matches)
	for info in files {
		if info.type == .Directory {
			continue
		}
		name := info.name
		if !strings.has_prefix(name, prefix) || !strings.has_suffix(name, ".wav") {
			continue
		}
		number := name[len(prefix):len(name) - 4]
		id, parsed := strconv.parse_int(number, 10)
		if !parsed || id <= 0 {
			continue
		}
		append(&matches, Take_Match{id = id, name = name})
	}
	slice.sort_by(matches[:], proc(a, b: Take_Match) -> bool { return a.id < b.id })
	for match in matches {
		_ = take_list_add(list, "", match.name, 0, 0, 1, false, match.id)
	}

	if len(list.takes) == 0 {
		canonical := fmt.aprintf("track%d.wav", max(track_index, 0) + 1)
		defer delete(canonical)
		path := fmt.tprintf("%s/%s", dir, canonical)
		if os.exists(path) && !os.is_directory(path) {
			_ = take_list_add(list, "Take 1", canonical, 0, 0, 1, false, 1)
		}
	}
	if len(list.takes) > 0 {
		list.active = list.takes[0].id
	}
	return true
}
