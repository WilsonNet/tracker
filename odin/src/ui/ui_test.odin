package ui

import "core:os"
import "core:testing"

@(test)
ui_initial_layout_exposes_every_control :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	ids := [10]string{
		"transport.rec", "transport.play", "transport.stop",
		"bounce", "fx", "io", "arm.0", "fader.3", "pan.1", "input.2",
	}
	for id in ids {
		_, ok := app_target_rect(&a, id)
		testing.expectf(t, ok, "missing target %s", id)
	}

	value, ok := app_value(&a, "transport")
	testing.expect(t, ok && value == "Stopped", "initial transport")
	testing.expectf(t, a.selected == 0, "selected %d", a.selected)
}

@(test)
ui_arm_and_record_keyboard :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_key(&a, .Char, '1')
	testing.expect(t, a.tracks[0].armed, "1 should arm track 1")

	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Recording, "R should start recording")
	app_tick(&a, 0.5)
	testing.expectf(t, a.frames > 0, "timecode did not advance: %d", a.frames)

	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Stopped, "R should stop recording")
}

@(test)
ui_record_requires_armed_track :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Stopped, "record without arms should be refused")
	testing.expect(t, app_status(&a) == "arm a track first", "missing guidance status")
}

@(test)
ui_pointer_toggles_and_fader :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_click_id(&a, "arm.1"), "arm hit target")
	testing.expect(t, a.tracks[1].armed, "click did not arm")

	testing.expect(t, app_click_id(&a, "mute.0"), "mute hit target")
	testing.expect(t, a.tracks[0].muted, "click did not mute")

	start := a.tracks[0].level
	testing.expect(t, app_drag_id(&a, "fader.0", -60), "fader hit target")
	testing.expectf(t, a.tracks[0].level > start, "fader did not rise: %v -> %v", start, a.tracks[0].level)

	pan_before := a.tracks[0].pan
	testing.expect(t, app_drag_id(&a, "pan.0", -60), "pan hit target")
	testing.expectf(t, a.tracks[0].pan > pan_before, "pan did not move right")
}

@(test)
ui_fx_rack_knob_and_bypass :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_click_id(&a, "fx"), "fx button")
	testing.expect(t, a.mode == .Fx, "fx mode")

	lo_before := a.tracks[0].eq.low_db
	testing.expect(t, app_drag_id(&a, "knob.eq.low", -60), "eq knob target")
	testing.expectf(t, a.tracks[0].eq.low_db > lo_before + 3, "knob did not boost: %v", a.tracks[0].eq.low_db)

	testing.expect(t, app_click_id(&a, "fx.bypass.comp"), "comp bypass")
	testing.expect(t, !a.tracks[0].comp.enabled, "comp should be bypassed")

	testing.expect(t, app_click_id(&a, "fx.tab.4"), "master tab")
	testing.expectf(t, a.fx_channel == 4, "fx channel %d", a.fx_channel)
	testing.expect(t, app_drag_id(&a, "knob.limiter.ceiling", -40), "limiter knob")
	testing.expectf(t, a.master.limiter.ceiling_db > -0.3, "ceiling did not move: %v", a.master.limiter.ceiling_db)
}

@(test)
ui_palette_filters_and_executes :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_key(&a, .Char, ':')
	testing.expect(t, a.mode == .Palette, "colon should open palette")
	app_key(&a, .Char, 'b')
	app_key(&a, .Char, 'o')
	testing.expectf(t, a.palette_count == 1, "filter count %d", a.palette_count)
	app_key(&a, .Enter)
	testing.expect(t, a.mode == .Bounce, "bounce command should start")

	app_tick(&a, 1.4)
	testing.expect(t, a.mode == .Normal, "bounce should finish")
	testing.expectf(t, a.bounce_progress >= 1.0, "progress %v", a.bounce_progress)
}

@(test)
ui_io_panel_selects_device :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	names := [2]string{"Alpha Input", "Beta Input"}
	app_set_devices(&a, names[:], 0)
	testing.expect(t, app_click_id(&a, "io"), "io button")
	testing.expect(t, a.mode == .Io, "io mode")
	testing.expect(t, app_click_id(&a, "io.row.1"), "io row")
	testing.expectf(t, a.device_index == 1, "device index %d", a.device_index)
	testing.expect(t, app_device(&a) == "Beta Input", "device label")
	testing.expect(t, a.mode == .Normal, "io should close after selection")
}

@(test)
ui_tempo_and_metronome_controls :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	testing.expect(t, app_click_id(&a, "bpm.plus"), "bpm plus")
	testing.expectf(t, a.bpm == 121, "bpm %d", a.bpm)
	testing.expect(t, app_click_id(&a, "bpm.minus"), "bpm minus")
	testing.expectf(t, a.bpm == 120, "bpm %d", a.bpm)
	testing.expect(t, app_click_id(&a, "metronome"), "metronome")
	testing.expect(t, a.metronome, "metronome should be on")
	app_key(&a, .Char, 'c')
	testing.expect(t, !a.metronome, "c should toggle the click")
}

@(test)
ui_screenshot_is_a_real_png :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	a.demo = true
	a.transport = .Playing
	a.time = 1.2
	a.tracks[0].has_audio = true
	a.tracks[1].has_audio = true
	a.tracks[0].peak_db = -12
	a.tracks[1].peak_db = -20

	c: Canvas
	canvas_init(&c, 1180, 760)
	defer canvas_destroy(&c)
	app_draw(&a, &c)

	path := "/tmp/tracker-odin-ui-test.png"
	defer os.remove(path)
	testing.expect(t, canvas_screenshot(&c, path), "screenshot failed")
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, "screenshot unreadable")
	testing.expectf(t, len(data) > 5_000, "screenshot suspiciously small: %d", len(data))
	sig := [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	if len(data) >= 8 {
		for b, i in sig {
			testing.expectf(t, data[i] == b, "bad PNG signature at %d", i)
		}
	}
}

@(test)
ui_draws_every_overlay_without_panicking :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	c: Canvas
	canvas_init(&c, 1180, 760)
	defer canvas_destroy(&c)

	modes := [5]Mode{.Normal, .Fx, .Palette, .Io, .Bounce}
	for mode in modes {
		a.mode = mode
		app_draw(&a, &c)
	}
	a.mode = .Fx
	a.fx_channel = 4
	app_draw(&a, &c)
	a.fx_channel = 0
	app_draw(&a, &c)
}

@(test)
ui_resize_keeps_controls_hittable :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 900, 620)
	defer app_destroy(&a)
	_, ok := app_target_rect(&a, "fader.0")
	testing.expect(t, ok, "fader missing at minimum size")
	app_resize(&a, 1920, 1080)
	_, ok = app_target_rect(&a, "bounce")
	testing.expect(t, ok, "bounce missing at large size")
}
