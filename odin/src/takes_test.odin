package main

import "core:os"
import "core:strings"
import "core:testing"

import ui "ui"

@(private)
fill_buffer :: proc(id: int, value: f32, frames: int, rate: u32 = 48_000) -> Take_Buffer {
	samples := make([]f32, frames)
	for i in 0 ..< frames {
		samples[i] = value
	}
	return Take_Buffer{take_id = id, sample_rate = rate, samples = samples}
}

@(test)
takes_crud_selection_and_next_filename :: proc(t: ^testing.T) {
	list: Take_List
	testing.expect(t, take_list_add(&list, "first", "a.wav", 48_000) == 1, "first id")
	testing.expect(t, take_list_add(&list, "second", "b.wav", 44_100, 120, 0.5, false) == 2, "second id")
	testing.expect(t, list.active == 1, "first take should be active")
	testing.expect(t, take_list_select(&list, 2), "select second")
	testing.expect(t, list.active == 2, "active id")
	if active, ok := take_list_active(&list); testing.expect(t, ok, "active take missing") {
		testing.expect(t, active.name == "second", "active name")
		testing.expect(t, active.sample_rate == 44_100, "sample rate")
		testing.expect(t, active.offset == 120, "offset")
		testing.expectf(t, abs(active.gain - 0.5) < 1e-4, "gain %v", active.gain)
	}
	testing.expect(t, !take_list_select(&list, 99), "unknown take selected")
	testing.expect(t, take_list_add(&list, "duplicate", "c.wav", 48_000, id = 2) == 0, "duplicate id accepted")

	name := take_next_filename(&list, 2)
	defer delete(name)
	testing.expectf(t, name == "track3-take3.wav", "next filename %q", name)

	testing.expect(t, comp_add_region(&list, 2, 0, 100), "region")
	testing.expect(t, take_list_remove(&list, 2), "remove take")
	testing.expect(t, len(list.takes) == 1, "take not removed")
	testing.expect(t, len(list.comp) == 0, "regions not removed with take")
	testing.expect(t, list.active == 1, "active fallback")
	take_list_destroy(&list)
}

@(test)
takes_comp_two_regions_crossfade :: proc(t: ^testing.T) {
	list: Take_List
	defer take_list_destroy(&list)
	first := take_list_add(&list, "A", "a.wav", 48_000)
	second := take_list_add(&list, "B", "b.wav", 48_000)
	testing.expect(t, comp_add_region(&list, first, 0, 100), "region A")
	testing.expect(t, comp_add_region(&list, second, 100, 200), "region B")

	buffers := []Take_Buffer {
		fill_buffer(first, 0.25, 200),
		fill_buffer(second, 0.75, 200),
	}
	defer take_buffers_destroy(buffers)

	out, ok := comp_render(&list, buffers, 16)
	defer delete(out)
	testing.expect(t, ok, "render failed")
	testing.expect(t, len(out) == 200, "length")

	// Outside a crossfade the selected take is the only contributor.
	testing.expectf(t, abs(out[50] - 0.25) < 1e-5, "take A sample %v", out[50])
	testing.expectf(t, abs(out[150] - 0.75) < 1e-5, "take B sample %v", out[150])

	// Both takes contribute at the join and the equal-power sum of two
	// identical signals never dips below either solo level.
	testing.expectf(t, out[100] > 0.25, "boundary dipped: %v", out[100])
	for frame in 100 ..< 116 {
		testing.expectf(t, out[frame] >= 0.25 - 1e-4, "crossfade hole at %d: %v", frame, out[frame])
	}
}

@(test)
takes_comp_offset_gain_mute_and_gaps :: proc(t: ^testing.T) {
	list: Take_List
	defer take_list_destroy(&list)
	take := take_list_add(&list, "gained", "a.wav", 48_000, 10, 0.5, false)
	muted := take_list_add(&list, "muted", "b.wav", 48_000, 0, 1, true)
	later := take_list_add(&list, "later", "c.wav", 48_000, 0, 1, false)
	testing.expect(t, comp_add_region(&list, take, 10, 60), "region with offset")
	testing.expect(t, comp_add_region(&list, muted, 80, 120), "muted region")
	testing.expect(t, comp_add_region(&list, later, 140, 180), "later region")

	buffers := []Take_Buffer {
		fill_buffer(take, 1, 200),
		fill_buffer(muted, 1, 120),
		fill_buffer(later, 0.25, 200),
	}
	defer take_buffers_destroy(buffers)

	out, ok := comp_render(&list, buffers, 8)
	defer delete(out)
	testing.expect(t, ok, "render failed")
	testing.expect(t, len(out) == 180, "length")

	// Silence before the offset take starts, then decayed by gain.
	for frame in 0 ..< 10 {
		testing.expectf(t, out[frame] == 0, "pre-offset frame %d = %v", frame, out[frame])
	}
	testing.expectf(t, abs(out[40] - 0.5) < 1e-5, "offset/gain sample %v", out[40])
	// Gaps between regions stay silent.
	for frame in 60 ..< 80 {
		testing.expectf(t, out[frame] == 0, "gap frame %d = %v", frame, out[frame])
	}
	for frame in 80 ..< 120 {
		testing.expectf(t, out[frame] == 0, "muted frame %d = %v", frame, out[frame])
	}
	testing.expectf(t, abs(out[160] - 0.25) < 1e-5, "later sample %v", out[160])
}

@(test)
takes_comp_rejects_invalid_regions :: proc(t: ^testing.T) {
	list: Take_List
	defer take_list_destroy(&list)
	one := take_list_add(&list, "one", "a.wav")
	testing.expect(t, comp_add_region(&list, 999, 0, 10) == false, "unknown take accepted")
	testing.expect(t, comp_add_region(&list, one, -1, 10) == false, "negative start accepted")
	testing.expect(t, comp_add_region(&list, one, 10, 10) == false, "empty region accepted")
	testing.expect(t, comp_add_region(&list, one, 0, 50), "valid region rejected")
	testing.expect(t, comp_add_region(&list, one, 40, 60) == false, "overlap accepted")
	testing.expect(t, comp_add_region(&list, one, 50, 70), "abutting region rejected")

	lengths := []Take_Length{{take_id = one, frames = 60}}
	ok, bad := comp_validate(&list, lengths)
	testing.expect(t, !ok, "regions past buffer end accepted")
	testing.expect(t, bad == 1, "bad region index")

	buffers := []Take_Buffer{fill_buffer(one, 1, 40)}
	defer take_buffers_destroy(buffers)
	_, rendered := comp_render(&list, buffers, 4)
	testing.expect(t, !rendered, "short buffer rendered")
	testing.expect(t, comp_remove_region(&list, 1), "remove region")
}

@(test)
project_takes_backward_compatible_roundtrip :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-takes-project"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	defer os.remove_all(dir)

	canonical := "/tmp/tracker-takes-project/track1.wav"
	samples := make([]f32, 100)
	defer delete(samples)
	testing.expect(t, wav_write(canonical, 48_000, 1, samples[:]), "wav fixture")
	testing.expect(t, os.write_entire_file(
		"/tmp/tracker-takes-project/project.json",
		`{"version":1,"name":"legacy","tracks":[{"name":"Guitar","file":"track1.wav","level":0.5}]}`,
	) == nil, "legacy project")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	lists: [4]Take_List
	defer {
		for &list in lists {
			take_list_destroy(&list)
		}
	}

	testing.expect(t, project_load_with_takes(&a, dir, "/tmp/tracker-takes-project/project.json", lists[:]), "legacy load")
	testing.expect(t, len(lists[0].takes) == 1, "legacy take count")
	testing.expect(t, lists[0].takes[0].name == "Take 1", "legacy take name")
	testing.expect(t, lists[0].takes[0].file == "track1.wav", "legacy take file")
	testing.expect(t, lists[0].active == 1, "legacy active take")
	testing.expect(t, a.tracks[0].has_audio, "legacy audio flag")

	second := take_list_add(&lists[0], "Take 2", "track1-take2.wav", 48_000, 0, 0.8, false)
	testing.expect(t, second == 2, "second take")
	testing.expect(t, take_list_select(&lists[0], second), "select second")
	testing.expect(t, comp_add_region(&lists[0], 1, 0, 40), "comp first")
	testing.expect(t, comp_add_region(&lists[0], second, 40, 100), "comp second")

	saved := "/tmp/tracker-takes-project/saved.json"
	testing.expect(t, project_save_with_takes(&a, lists[:], saved), "save failed")
	text, read_err := os.read_entire_file(saved, context.allocator)
	testing.expect(t, read_err == nil, "saved project unreadable")
	defer delete(text)
	body := string(text)
	testing.expect(t, strings.contains(body, `"takes"`), "take list missing")
	testing.expect(t, strings.contains(body, `"activeTake": 2`), "active take missing")
	testing.expect(t, strings.contains(body, `"file": "track1.wav"`), "canonical file missing")
	testing.expect(t, strings.contains(body, `"compRegions"`), "comp regions missing")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	loaded: [4]Take_List
	defer {
		for &list in loaded {
			take_list_destroy(&list)
		}
	}
	testing.expect(t, project_load_with_takes(&b, dir, saved, loaded[:]), "round-trip load")
	testing.expect(t, len(loaded[0].takes) == 2, "round-trip take count")
	testing.expect(t, loaded[0].takes[1].name == "Take 2", "round-trip take name")
	testing.expectf(t, abs(loaded[0].takes[1].gain - 0.8) < 1e-4, "round-trip gain")
	testing.expect(t, loaded[0].active == 2, "round-trip active")
	testing.expect(t, len(loaded[0].comp) == 2, "round-trip comp")
	testing.expect(t, loaded[0].comp[1].start_frame == 40, "round-trip region")

	// The old app-facing entry points still load and save the same project.
	testing.expect(t, project_load(&b, dir, saved), "legacy entry point load")
	testing.expect(t, project_save(&b, "/tmp/tracker-takes-project/plain.json"), "legacy entry point save")
}

@(test)
project_takes_repeated_load_and_save_is_owned :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-takes-reload"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	defer os.remove_all(dir)
	path := "/tmp/tracker-takes-reload/project.json"

	testing.expect(t, os.write_entire_file(path, `{"version":1,"tracks":[{"file":"track1.wav","takes":[
		{"id":1,"name":"one","file":"track1-take1.wav","sampleRate":48000,"offset":0,"gain":1,"muted":false},
		{"id":2,"name":"two","file":"track1-take2.wav","sampleRate":48000,"offset":24,"gain":0.7,"muted":false}],
		"activeTake":2,"compRegions":[{"takeId":1,"startFrame":0,"endFrame":64},{"takeId":2,"startFrame":64,"endFrame":128}]}]}`) == nil, "fixture")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	lists: [4]Take_List
	defer {
		for &list in lists {
			take_list_destroy(&list)
		}
	}

	for _ in 0 ..< 4 {
		testing.expect(t, project_load_with_takes(&a, dir, path, lists[:]), "repeated load")
		testing.expect(t, len(lists[0].takes) == 2, "takes after reload")
		testing.expect(t, lists[0].takes[1].name == "two", "name after reload")
		testing.expect(t, lists[0].active == 2, "active after reload")
	}
	out := "/tmp/tracker-takes-reload/out.json"
	testing.expect(t, project_save_with_takes(&a, lists[:], out), "save after reloads")

	b: ui.App
	ui.app_init(&b, 1180, 760)
	defer ui.app_destroy(&b)
	again: [4]Take_List
	defer {
		for &list in again {
			take_list_destroy(&list)
		}
	}
	testing.expect(t, project_load_with_takes(&b, dir, out, again[:]), "load saved copy")
	testing.expect(t, len(again[0].comp) == 2, "comp after save")
	testing.expect(t, again[0].active == 2, "active after save")
}

@(test)
takes_load_from_session_directory :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-takes-session"
	os.remove_all(dir)
	testing.expect(t, ensure_dir(dir), "session dir")
	defer os.remove_all(dir)

	one := make([]f32, 32)
	two := make([]f32, 16)
	defer delete(one)
	defer delete(two)
	testing.expect(t, wav_write("/tmp/tracker-takes-session/track2-take1.wav", 48_000, 1, one[:]), "take 1 wav")
	testing.expect(t, wav_write("/tmp/tracker-takes-session/track2-take2.wav", 44_100, 1, two[:]), "take 2 wav")

	list: Take_List
	defer take_list_destroy(&list)
	testing.expect(t, takes_load_from_dir(&list, dir, 1), "scan failed")
	testing.expect(t, len(list.takes) == 2, "scanned take count")
	testing.expect(t, list.takes[0].name == "Take 1", "scanned name")
	testing.expect(t, list.takes[1].file == "track2-take2.wav", "scanned file")
	testing.expect(t, list.active == 1, "scanned active")

	buffers, ok := takes_load_buffers(dir, &list)
	defer take_buffers_free(buffers)
	testing.expect(t, ok, "buffer load failed")
	testing.expect(t, len(buffers) == 2, "buffer count")
	testing.expect(t, len(buffers[0].samples) == 32, "buffer 1 length")
	testing.expect(t, buffers[1].sample_rate == 44_100, "buffer rate")
}
