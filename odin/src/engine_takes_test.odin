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
