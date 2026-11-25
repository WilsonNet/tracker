package main

import "core:fmt"
import "core:os"
import "core:testing"

import ui "ui"

@(test)
engine_takes_register_stabilize_and_comp :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-takes"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)

	old := make([]f32, 256)
	defer delete(old)
	for i in 0 ..< len(old) {
		old[i] = 0.25
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 48_000, 1, old), "first wav")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load first")
	testing.expect(t, engine_take_count(&e, 0) == 1, "one legacy take")
	testing.expect(t, e.loaded[0] != nil && abs(e.loaded[0][0] - 0.25) < 1e-6, "loaded first")

	// Stabilize the canonical take before recording over it.
	engine_take_stabilize_canonical(&e, 0)
	testing.expect(t, os.exists(fmt.tprintf("%s/track1-take1.wav", base)), "stable take file")

	new := make([]f32, 256)
	defer delete(new)
	for i in 0 ..< len(new) {
		new[i] = -0.5
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 48_000, 1, new), "second wav")
	engine_take_register_new(&e, 0, 48_000)
	testing.expect(t, engine_take_count(&e, 0) == 2, "two takes")
	testing.expect(t, engine_take_active(&e, 0) == 2, "new take active")
	handled1, ok1 := engine_load_track_from_takes(&e, &a, 0)
	testing.expect(t, handled1 && ok1, "load active")
	testing.expect(t, abs(e.loaded[0][0] + 0.5) < 1e-6, "active take loaded")

	// Select take 1 and force comp mode over the first 50 frames.
	testing.expect(t, engine_take_select(&e, &a, 0, 1), "select take 1")
	testing.expect(t, abs(e.loaded[0][0] - 0.25) < 1e-6, "take 1 loaded")
	comp_clear(&e.takes[0])
	testing.expect(t, comp_add_region(&e.takes[0], 1, 0, 256), "comp region")
	testing.expect(t, comp_length(&e.takes[0]) == 256, "comp length")
	handled2, ok2 := engine_load_track_from_takes(&e, &a, 0)
	testing.expect(t, handled2 && ok2, "load comp")
	testing.expect(t, len(e.loaded[0]) == 256, "comp frames")
	testing.expectf(t, abs(e.loaded[0][128] - 0.25) < 1e-6, "comp source %v len %d active %d", e.loaded[0][50], len(e.loaded[0]), e.takes[0].active)
}

@(test)
engine_take_cycle_rejects_master :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-take-master"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}))
	defer engine_destroy(&e)
	testing.expect(t, !engine_take_cycle(&e, nil, MAX_ENGINE_TRACKS, 1), "master must not index takes")
	testing.expect(t, !engine_take_cycle(&e, nil, -1, 1), "negative track must not index takes")
}

@(test)
engine_comp_use_active_and_clear :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-comp-ui"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)
	samples := make([]f32, 128)
	defer delete(samples)
	for i in 0 ..< len(samples) {
		samples[i] = 0.1
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1.wav", base), 48_000, 1, samples))
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}))
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a))
	testing.expect(t, engine_comp_use_active(&e, &a, 0), "comp use")
	testing.expectf(t, len(e.takes[0].comp) == 1, "regions %d", len(e.takes[0].comp))
	testing.expect(t, engine_comp_clear(&e, &a, 0), "comp clear")
	testing.expect(t, len(e.takes[0].comp) == 0, "regions remain")
}

@(test)
engine_take_delete_moves_wav_and_reloads_neighbor :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-take-delete"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)

	// Seed 3 distinct takes (take1, take2, canonical track1).
	t1 := make([]f32, 128)
	t2 := make([]f32, 128)
	t3 := make([]f32, 128)
	defer delete(t1)
	defer delete(t2)
	defer delete(t3)
	for i in 0 ..< 128 {
		t1[i] = 0.1
		t2[i] = 0.2
		t3[i] = 0.3
	}
	testing.expect(t, wav_write(fmt.tprintf("%s/track1-take1.wav", base), 48_000, 1, t1), "t1 wav")
	testing.expect(t, wav_write(fmt.tprintf("%s/track1-take2.wav", base), 48_000, 1, t2), "t2 wav")
	testing.expect(t, wav_write(fmt.tprintf("%s/track1-take3.wav", base), 48_000, 1, t3), "t3 wav")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)
	testing.expect(t, engine_load_tracks(&e, &a), "load takes")
	testing.expect(t, engine_take_count(&e, 0) == 3, "three takes")

	// Refusals: playing/recording, out-of-range/master, empty track, comp mode.
	e.play.active = true
	ok_play, _ := engine_take_delete(&e, &a, 0)
	testing.expect(t, !ok_play, "refuse while playing")
	e.play.active = false

	ok_master, _ := engine_take_delete(&e, &a, MAX_ENGINE_TRACKS)
	testing.expect(t, !ok_master, "refuse master")
	ok_empty, _ := engine_take_delete(&e, &a, 1)
	testing.expect(t, !ok_empty, "refuse empty track")

	// Comp mode (active == TAKE_ID_NONE) refuses rather than guessing.
	testing.expect(t, comp_add_region(&e.takes[0], 1, 0, 64), "comp region t1")
	testing.expect(t, comp_add_region(&e.takes[0], 2, 64, 128), "comp region t2")
	_ = take_list_select(&e.takes[0], TAKE_ID_NONE)
	ok_comp, _ := engine_take_delete(&e, &a, 0)
	testing.expect(t, !ok_comp, "refuse in comp mode")

	// Select take 1 and delete it: moves take1 to deleted/, strips its comp region, lands on take 2 (ordinal 1).
	testing.expect(t, engine_take_select(&e, &a, 0, 1), "select take 1")
	ok1, msg1 := engine_take_delete(&e, &a, 0)
	testing.expectf(t, ok1, "delete take 1: %s", msg1)
	testing.expect(t, engine_take_count(&e, 0) == 2, "two takes remain")
	testing.expect(t, engine_take_active(&e, 0) == 2, "active moved to take 2")
	testing.expect(t, engine_take_active_ordinal(&e, 0) == 1, "active ordinal is 1")
	testing.expect(t, len(e.takes[0].comp) == 1 && e.takes[0].comp[0].take_id == 2, "comp region for take 1 stripped")
	testing.expect(t, !os.exists(fmt.tprintf("%s/track1-take1.wav", base)), "take 1 moved out of session root")
	testing.expect(t, os.exists(fmt.tprintf("%s/deleted/track1-take1.wav", base)), "take 1 preserved in deleted/")

	// Clear comp so direct take audio loads, select take 3 (last), delete it -> falls back to take 2.
	comp_clear(&e.takes[0])
	testing.expect(t, engine_take_select(&e, &a, 0, 3), "select take 3")
	ok3, _ := engine_take_delete(&e, &a, 0)
	testing.expect(t, ok3, "delete take 3")
	testing.expect(t, engine_take_count(&e, 0) == 1 && engine_take_active(&e, 0) == 2, "take 2 remains active")
	testing.expect(t, e.loaded[0] != nil && abs(e.loaded[0][0] - 0.2) < 1e-6, "loaded audio switched to take 2")
	testing.expect(t, os.exists(fmt.tprintf("%s/deleted/track1-take3.wav", base)), "take 3 in deleted/")

	// Delete the last remaining take (take 2): clears track audio and survives save/reload.
	ok2, _ := engine_take_delete(&e, &a, 0)
	testing.expect(t, ok2, "delete last take")
	testing.expect(t, engine_take_count(&e, 0) == 0 && engine_take_active(&e, 0) == TAKE_ID_NONE, "no takes left")
	testing.expect(t, engine_take_active_ordinal(&e, 0) == 0, "ordinal 0 when empty")
	testing.expect(t, e.loaded[0] == nil && !a.tracks[0].has_audio, "loaded audio and has_audio cleared")
	testing.expect(t, os.exists(fmt.tprintf("%s/deleted/track1-take2.wav", base)), "take 2 in deleted/")

	testing.expect(t, project_save_with_takes(&a, e.takes[:], e.project_path), "save project after deleting all takes")
	a2: ui.App
	ui.app_init(&a2, 1180, 760)
	defer ui.app_destroy(&a2)
	e2: Engine
	testing.expect(t, engine_init(&e2, []string{"--session", base}), "engine 2")
	defer engine_destroy(&e2)
	testing.expect(t, project_load_with_takes(&a2, e2.session_dir, e2.project_path, e2.takes[:]), "reload project")
	_ = engine_load_tracks(&e2, &a2)
	testing.expect(t, engine_take_count(&e2, 0) == 0 && !a2.tracks[0].has_audio, "empty track survives reload")
}

@(test)
engine_take_new_opt_in_and_tape_overwrite :: proc(t: ^testing.T) {
	base := "/tmp/tracker-engine-take-new"
	os.remove_all(base)
	defer os.remove_all(base)
	_ = os.make_directory_all(base)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	e: Engine
	testing.expect(t, engine_init(&e, []string{"--session", base}), "engine")
	defer engine_destroy(&e)

	// Guards on empty track / invalid track / running transport.
	ok_empty, _ := engine_take_new(&e, &a, 0)
	testing.expect(t, !ok_empty, "empty track refuses new take")
	ok_master, _ := engine_take_new(&e, &a, MAX_ENGINE_TRACKS)
	testing.expect(t, !ok_master, "master refuses new take")

	// First recording creates Take 1 on canonical track1.wav.
	pass1 := make([]f32, 2400)
	for i in 0 ..< len(pass1) {
		pass1[i] = 0.25
	}
	e.rec_punch = 0
	testing.expect(t, engine_commit_recorded_take(&e, &a, 0, 48_000, pass1), "first record")
	testing.expect(t, engine_take_count(&e, 0) == 1 && engine_take_active(&e, 0) == 1, "take 1 active")
	testing.expect(t, os.exists(fmt.tprintf("%s/track1.wav", base)), "canonical wav created")

	// Guard while active transport is playing/recording.
	e.play.active = true
	ok_play, _ := engine_take_new(&e, &a, 0)
	testing.expect(t, !ok_play, "playing refuses new take")
	e.play.active = false

	// Opt-in new take archives Take 1 to track1-take1.wav and opens empty Take 2.
	ok_new, msg_new := engine_take_new(&e, &a, 0)
	testing.expectf(t, ok_new, "create take 2: %s", msg_new)
	testing.expect(t, engine_take_count(&e, 0) == 2 && engine_take_active(&e, 0) == 2, "take 2 active")
	testing.expect(t, e.loaded[0] == nil && !a.tracks[0].has_audio, "take 2 starts empty")
	testing.expect(t, os.exists(fmt.tprintf("%s/track1-take1.wav", base)), "take 1 stabilized")
	testing.expect(t, !os.exists(fmt.tprintf("%s/track1.wav", base)), "canonical cleared for take 2")

	// Creating a third take while Take 2 is still empty is refused.
	ok_double, _ := engine_take_new(&e, &a, 0)
	testing.expect(t, !ok_double, "refuse new take when current take is empty")

	// Switching back and forth while Take 2 is empty works cleanly and preserves state across save/reload.
	testing.expect(t, engine_take_select(&e, &a, 0, 1), "switch back to take 1")
	testing.expect(t, e.loaded[0] != nil && a.tracks[0].has_audio, "take 1 audio restored")
	testing.expect(t, engine_take_select(&e, &a, 0, 2), "switch back to empty take 2")
	testing.expect(t, e.loaded[0] == nil && !a.tracks[0].has_audio, "empty take 2 stays empty")

	testing.expect(t, project_save_with_takes(&a, e.takes[:], e.project_path), "save project with empty take 2")
	a2: ui.App
	ui.app_init(&a2, 1180, 760)
	defer ui.app_destroy(&a2)
	e2: Engine
	testing.expect(t, engine_init(&e2, []string{"--session", base}), "engine 2")
	defer engine_destroy(&e2)
	testing.expect(t, project_load_with_takes(&a2, base, e2.project_path, e2.takes[:]), "reload")
	_ = engine_load_tracks(&e2, &a2)
	testing.expect(t, engine_take_count(&e2, 0) == 2 && engine_take_active(&e2, 0) == 2, "two takes survive reload")
	testing.expect(t, e2.loaded[0] == nil && !a2.tracks[0].has_audio, "empty take 2 survives reload")

	// Recording onto empty Take 2 at punch > 0 pads leading silence and stays on Take 2 on a second overwrite.
	pass2 := make([]f32, 1000)
	for i in 0 ..< len(pass2) {
		pass2[i] = 0.6
	}
	e2.rec_punch = 500
	testing.expect(t, engine_commit_recorded_take(&e2, &a2, 0, 48_000, pass2), "record punch onto empty take 2")
	testing.expect(t, len(e2.loaded[0]) == 1500 && abs(e2.loaded[0][100]) < 1e-6 && abs(e2.loaded[0][1000] - 0.6) < 1e-4, "punch on empty take pads lead-in silence")

	pass3 := make([]f32, 800)
	for i in 0 ..< len(pass3) {
		pass3[i] = -0.3
	}
	e2.rec_punch = 600
	testing.expect(t, engine_commit_recorded_take(&e2, &a2, 0, 48_000, pass3), "second overwrite on take 2")
	testing.expect(t, engine_take_count(&e2, 0) == 2 && len(e2.loaded[0]) == 1500, "stays on take 2, end preserved")
	testing.expect(t, abs(e2.loaded[0][1000] + 0.3) < 1e-4 && abs(e2.loaded[0][1450] - 0.6) < 1e-4, "second punch overwrote slice without touching tail")

	// Deleting Take 2 removes track1.wav to deleted/ and falls back to Take 1.
	ok_del, _ := engine_take_delete(&e2, &a2, 0)
	testing.expect(t, ok_del && engine_take_count(&e2, 0) == 1 && engine_take_active(&e2, 0) == 1, "delete take 2 falls back to take 1")
	testing.expect(t, e2.loaded[0] != nil && abs(e2.loaded[0][0] - 0.25) < 1e-4, "take 1 audio active")
}
