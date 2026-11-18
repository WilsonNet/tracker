package ui

import "core:fmt"
import "core:math"
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

// ---------------------------------------------------------------- helpers

@(private)
rect_within :: proc(inner, outer: Rect) -> bool {
	return inner.x >= outer.x - 0.01 &&
		inner.y >= outer.y - 0.01 &&
		inner.x + inner.w <= outer.x + outer.w + 0.01 &&
		inner.y + inner.h <= outer.y + outer.h + 0.01
}

@(private)
type_query :: proc(a: ^App, s: string) {
	for ch in s {
		app_key(a, .Char, u8(ch), ch >= 'A' && ch <= 'Z')
	}
}

@(private)
open_palette :: proc(a: ^App) {
	app_key(a, .Char, ':')
}

@(private)
channel_linear :: proc(v: u8) -> f32 {
	f := f32(v) / 255.0
	return f / 12.92 if f <= 0.04045 else math.pow((f + 0.055) / 1.055, 2.4)
}

@(private)
contrast_ratio :: proc(a, b: Color) -> f32 {
	la := 0.2126 * channel_linear(u8(a >> 16)) + 0.7152 * channel_linear(u8(a >> 8)) + 0.0722 * channel_linear(u8(a))
	lb := 0.2126 * channel_linear(u8(b >> 16)) + 0.7152 * channel_linear(u8(b >> 8)) + 0.0722 * channel_linear(u8(b))
	hi := max(la, lb)
	lo := min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
}

// ---------------------------------------------------------------- regression tests

@(test)
ui_target_availability_follows_overlay_state :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	names := [2]string{"Alpha", "Beta"}
	app_set_devices(&a, names[:], 0)

	testing.expect(t, app_target_available(&a, "arm.0"), "arm should be live in Normal")
	testing.expect(t, app_target_available(&a, "bpm.plus"), "bpm should be live in Normal")
	testing.expect(t, !app_target_available(&a, "fx.close"), "fx.close must be inert when closed")
	testing.expect(t, !app_target_available(&a, "knob.eq.low"), "knob must be inert when closed")
	testing.expect(t, !app_target_available(&a, "palette.row.0"), "palette row must be inert when closed")
	testing.expect(t, !app_target_available(&a, "io.row.0"), "io row must be inert when closed")

	app_execute(&a, .Fx)
	testing.expect(t, app_target_available(&a, "knob.eq.low"), "knob should be live in FX")
	testing.expect(t, app_target_available(&a, "fx.close"), "fx.close should be live in FX")
	testing.expect(t, !app_target_available(&a, "arm.0"), "track controls are covered by the rack")
	testing.expect(t, !app_target_available(&a, "bpm.plus"), "header is covered by the rack")

	open_palette(&a)
	testing.expect(t, app_target_available(&a, "palette.row.0"), "palette row live in palette")
	testing.expect(t, !app_target_available(&a, "fx.close"), "rack is covered by the palette")
	testing.expect(t, !app_target_available(&a, "arm.0"), "tracks are covered by the palette")

	app_key(&a, .Escape)
	app_execute(&a, .Io)
	testing.expect(t, app_target_available(&a, "io.row.0"), "io row live in io")
	testing.expect(t, !app_target_available(&a, "arm.0"), "tracks are covered by io")

	a.mode = .Bounce
	testing.expect(t, !app_target_available(&a, "arm.0"), "bounce blocks the workspace")
	testing.expect(t, !app_target_available(&a, "fx.close"), "bounce blocks the header")
}

@(test)
ui_click_under_overlay_does_not_hit_hidden_control :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_click_id(&a, "fx"), "fx button")
	testing.expect(t, a.mode == .Fx, "fx mode")
	testing.expect(t, !app_click_id(&a, "arm.0"), "arm click must be rejected under the rack")
	testing.expect(t, !a.tracks[0].armed, "hidden arm must not toggle")
	testing.expect(t, app_click_id(&a, "fx.close"), "close must work")
	testing.expect(t, a.mode == .Normal, "rack closed")

	testing.expect(t, !app_click_id(&a, "knob.eq.low"), "knob click rejected when rack closed")
	testing.expect(t, app_click_id(&a, "arm.0"), "arm works again")
	testing.expect(t, a.tracks[0].armed, "arm toggled")
}

@(test)
ui_double_click_resets_fader_pan_and_knob :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	a.tracks[0].level = 1.4
	testing.expect(t, app_click_id(&a, "fader.0"), "fader click 1")
	testing.expect(t, app_click_id(&a, "fader.0"), "fader click 2")
	testing.expectf(t, abs(a.tracks[0].level - 0.8) < 0.001, "fader not reset: %v", a.tracks[0].level)

	a.tracks[1].pan = -0.8
	testing.expect(t, app_click_id(&a, "pan.1"), "pan click 1")
	testing.expect(t, app_click_id(&a, "pan.1"), "pan click 2")
	testing.expectf(t, abs(a.tracks[1].pan) < 0.001, "pan not reset: %v", a.tracks[1].pan)

	app_execute(&a, .Fx)
	a.tracks[0].eq.low_db = 9
	testing.expect(t, app_click_id(&a, "knob.eq.low"), "knob click 1")
	testing.expect(t, app_click_id(&a, "knob.eq.low"), "knob click 2")
	testing.expectf(t, abs(a.tracks[0].eq.low_db) < 0.001, "knob not reset: %v", a.tracks[0].eq.low_db)

	// A drag between clicks must break the double-click pair: otherwise the
	// second press silently resets the value the drag just set.
	app_execute(&a, .Fx) // close the rack: track controls are covered by it
	testing.expect(t, a.mode == .Normal, "rack closed")
	a.tracks[0].level = 1.4
	testing.expect(t, app_drag_id(&a, "fader.0", -10), "fader drag")
	testing.expect(t, app_click_id(&a, "fader.0"), "fader click after drag")
	testing.expectf(t, a.tracks[0].level > 1.0, "click after drag was treated as double-click")
}

@(test)
ui_shift_drag_is_fine_grained :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_execute(&a, .Fx)
	a.tracks[0].eq.low_db = 0

	testing.expect(t, app_drag_id(&a, "knob.eq.low", -60), "coarse drag")
	coarse := a.tracks[0].eq.low_db
	testing.expectf(t, coarse > 3, "coarse drag too small: %v", coarse)

	a.tracks[0].eq.low_db = 0
	testing.expect(t, app_drag_id(&a, "knob.eq.low", -60, true), "fine drag")
	fine := a.tracks[0].eq.low_db
	testing.expectf(t, fine > 0, "fine drag did not move: %v", fine)
	testing.expectf(t, fine < coarse * 0.25, "shift drag is not finer: %v vs %v", fine, coarse)
}

@(test)
ui_knob_keyboard_focus_and_adjust :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_execute(&a, .Fx)

	app_key(&a, .Tab)
	testing.expect(t, app_fx_focus_name(&a) == "knob.eq.low", "Tab should focus the first knob")
	start := app_knob_value(&a, a.layout.knob_target[0])
	app_key(&a, .Right)
	testing.expectf(t, app_knob_value(&a, a.layout.knob_target[0]) > start, "Right did not raise the knob")
	mid := app_knob_value(&a, a.layout.knob_target[0])
	app_key(&a, .Right, 0, true)
	testing.expectf(t, app_knob_value(&a, a.layout.knob_target[0]) - mid < (mid - start) * 0.5, "shift arrow is not fine")

	app_key(&a, .Enter)
	testing.expectf(t, abs(app_knob_value(&a, a.layout.knob_target[0])) < 0.001, "Enter should reset the knob")

	app_key(&a, .Tab, 0, true)
	testing.expect(t, app_fx_focus_name(&a) == "fx.bypass.comp", "shift+Tab should wrap to the last toggle")
	app_key(&a, .Enter)
	testing.expect(t, !a.tracks[0].comp.enabled, "Enter should flip the focused bypass")
	app_key(&a, .Tab)
	testing.expect(t, app_fx_focus_name(&a) == "knob.eq.low", "Tab should wrap to the first knob")

	// Channel changes rebuild the control list; stale focus must not index it.
	app_key(&a, .Char, ']')
	testing.expect(t, a.fx_channel == 1, "channel changed")
	testing.expect(t, app_fx_focus_name(&a) == "none", "focus should reset on channel change")
}

@(test)
ui_palette_query_case_backspace_and_rows :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	open_palette(&a)
	type_query(&a, "TEMPO")
	testing.expectf(t, a.palette_len == 5 && string(a.palette_buf[:a.palette_len]) == "TEMPO", "query not stored")
	testing.expectf(t, a.palette_count == 2, "uppercase query count %d", a.palette_count)
	app_key(&a, .Down)
	testing.expect(t, a.palette_sel == 1, "down should move selection")
	app_key(&a, .Backspace)
	testing.expect(t, a.palette_sel == 0, "query change must reset selection")
	testing.expect(t, a.palette_count == 2, "backspace broke the filter")

	// Overflow guard: the query is capped so it cannot paint over the panel.
	app_key(&a, .Escape)
	open_palette(&a)
	for _ in 0 ..< 80 do app_key(&a, .Char, 'a')
	testing.expectf(t, a.palette_len == PALETTE_QUERY_MAX, "query not capped: %d", a.palette_len)

	// All rows stay inside the panel and clear the footer.
	app_key(&a, .Escape)
	open_palette(&a)
	app_layout(&a)
	for i in 0 ..< a.palette_count {
		row := a.layout.palette_row[i]
		testing.expectf(t, rect_within(row, a.layout.palette), "palette row %d escapes the panel", i)
		testing.expectf(t, row.y + row.h <= a.layout.palette.y + a.layout.palette.h - 26, "palette row %d hits the footer", i)
	}
	testing.expect(t, a.palette_count == len(PALETTE_COMMANDS), "all commands should be listed")
}

@(test)
ui_palette_empty_and_backdrop_handling :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	open_palette(&a)
	type_query(&a, "zzz")
	testing.expect(t, a.palette_count == 0, "query should match nothing")
	app_key(&a, .Enter)
	testing.expect(t, a.mode == .Palette, "empty palette must stay open")
	testing.expect(t, app_status(&a) == "no matching command", "empty palette status")
	testing.expect(t, !app_click_id(&a, "palette.row.0"), "no row target when empty")

	a.mouse_down = false
	app_mouse_down(&a, 2, 2)
	app_mouse_up(&a)
	testing.expect(t, a.mode == .Normal, "backdrop click should close the palette")
}

@(test)
ui_palette_record_and_play_toggle_instead_of_restarting :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_key(&a, .Char, '1')

	open_palette(&a)
	type_query(&a, "record")
	app_key(&a, .Enter)
	testing.expect(t, a.transport == .Recording, "palette record should start")
	app_tick(&a, 0.2)
	open_palette(&a)
	type_query(&a, "record")
	app_key(&a, .Enter)
	testing.expect(t, a.transport == .Stopped, "palette record should stop an active take")

	open_palette(&a)
	type_query(&a, "play")
	app_key(&a, .Enter)
	testing.expect(t, a.transport == .Playing, "palette play should start")
	testing.expect(t, a.frames == 0, "play should reset the clock")
	app_tick(&a, 0.2)
	testing.expectf(t, a.frames > 0, "timecode should advance")
	open_palette(&a)
	type_query(&a, "play")
	app_key(&a, .Enter)
	testing.expect(t, a.transport == .Stopped, "palette play should stop")
}

@(test)
ui_play_and_arm_refused_while_recording :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_key(&a, .Char, '1')
	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Recording, "recording")

	start_frames := a.frames
	app_key(&a, .Space)
	testing.expect(t, a.transport == .Recording, "Space must not switch to Playing mid-take")
	testing.expect(t, app_status(&a) == "stop recording before play", "missing refusal status")
	app_tick(&a, 0.1)
	testing.expectf(t, a.frames > start_frames, "take should keep rolling")

	testing.expect(t, app_click_id(&a, "arm.1"), "arm target exists")
	testing.expect(t, !a.tracks[1].armed, "arm must be refused mid-take")
	input_before := a.tracks[0].input
	testing.expect(t, app_click_id(&a, "input.0"), "input target exists")
	testing.expect(t, a.tracks[0].input == input_before, "input must be refused mid-take")
	app_key(&a, .Char, 'a')
	testing.expect(t, a.tracks[0].armed, "arm key must be refused mid-take")
	app_key(&a, .Char, '2')
	testing.expect(t, !a.tracks[1].armed, "number key must be refused mid-take")

	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Stopped, "stopped")
}

@(test)
ui_input_cycles_within_device_channels :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	testing.expect(t, a.tracks[0].input == 1, "default input")
	for _ in 0 ..< MAX_TRACKS {
		testing.expect(t, app_click_id(&a, "input.0"), "input target")
	}
	testing.expectf(t, a.tracks[0].input == 1, "cycle should wrap to 1, got %d", a.tracks[0].input)

	app_set_input_channels(&a, 2)
	testing.expect(t, a.input_count == 2, "channel count")
	testing.expect(t, app_click_id(&a, "input.0"), "input target")
	testing.expect(t, a.tracks[0].input == 2, "second channel")
	app_key(&a, .Char, 'T') // unreachable char, ignored
	app_key(&a, .Char, 'I')
	testing.expect(t, a.tracks[0].input == 1, "I cycles back")

	app_set_input_channels(&a, 1)
	for i in 0 ..< MAX_TRACKS {
		testing.expectf(t, a.tracks[i].input == 1, "track %d input not clamped", i)
	}
}

@(test)
ui_solo_and_mute_effective_audibility :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_track_audible(&a, 0), "track 0 starts audible")
	testing.expect(t, app_track_audible(&a, 1), "track 1 starts audible")
	testing.expect(t, app_click_id(&a, "solo.0"), "solo target")
	testing.expect(t, app_any_solo(&a), "solo any")
	testing.expect(t, app_track_audible(&a, 0), "soloed track stays audible")
	testing.expect(t, !app_track_audible(&a, 1), "solo should silence the others")
	testing.expect(t, app_value_is(&a, "audible.1", "false"), "audible assertion")

	testing.expect(t, app_click_id(&a, "mute.0"), "mute target")
	testing.expect(t, !app_track_audible(&a, 0), "mute wins over solo")
	testing.expect(t, app_value_is(&a, "audible.0", "false"), "muted assertion")

	testing.expect(t, app_click_id(&a, "mute.0"), "unmute")
	testing.expect(t, app_click_id(&a, "solo.0"), "unsolo")
	testing.expect(t, app_track_audible(&a, 1), "audibility restored")
	testing.expect(t, !app_any_solo(&a), "no solo left")
}

@(private)
app_value_is :: proc(a: ^App, path, want: string) -> bool {
	v, ok := app_value(a, path)
	return ok && v == want
}

@(test)
ui_bounce_refused_while_recording_and_survives_dismissal :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_key(&a, .Char, '1')
	app_key(&a, .Char, 'r')

	app_execute(&a, .Bounce)
	testing.expect(t, a.transport == .Recording, "bounce must not interrupt a take")
	testing.expect(t, a.mode == .Normal, "no bounce overlay while recording")
	testing.expect(t, !a.bounce_active, "bounce must not start while recording")
	testing.expect(t, app_status(&a) == "stop recording before bounce", "bounce refusal status")

	app_key(&a, .Char, 'r')
	app_execute(&a, .Bounce)
	testing.expect(t, a.mode == .Bounce, "bounce overlay")
	testing.expect(t, a.bounce_active, "bounce active")
	testing.expect(t, !app_click_id(&a, "bounce"), "pointer is blocked by the overlay")

	app_key(&a, .Escape)
	testing.expect(t, a.mode == .Normal, "escape dismisses the overlay")
	testing.expect(t, a.bounce_active, "render continues after dismissal")
	testing.expect(t, app_status(&a) == "bounce continues in background", "dismiss status")

	app_tick(&a, 1.5)
	testing.expect(t, !a.bounce_active, "bounce should finish in the background")
	testing.expectf(t, a.bounce_progress >= 1.0, "progress %v", a.bounce_progress)
	testing.expect(t, app_value_is(&a, "bounce.running", "false"), "running flag")
}

@(test)
ui_master_strip_reachable_by_keyboard :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	a.selected = MAX_TRACKS - 1
	app_key(&a, .Tab)
	testing.expectf(t, a.selected == MAX_TRACKS, "Tab should reach master, got %d", a.selected)
	app_key(&a, .Tab, 0, true)
	testing.expectf(t, a.selected == MAX_TRACKS - 1, "shift+Tab should leave master, got %d", a.selected)
	app_key(&a, .Tab)
	testing.expect(t, app_click_id(&a, "master"), "master target")
	testing.expect(t, a.selected == MAX_TRACKS, "master click selects the bus")
}

@(test)
ui_bypassed_module_knobs_are_inert :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_execute(&a, .Fx)
	testing.expect(t, app_click_id(&a, "fx.bypass.eq"), "eq power toggle")
	testing.expect(t, !app_tracks_eq_enabled(&a), "eq should be bypassed")
	before := a.tracks[0].eq.low_db
	testing.expect(t, !app_drag_id(&a, "knob.eq.low", -80), "bypassed knob must be inert")
	testing.expectf(t, a.tracks[0].eq.low_db == before, "bypassed knob changed")
	testing.expect(t, app_click_id(&a, "fx.bypass.eq"), "eq power on")
	testing.expect(t, app_drag_id(&a, "knob.eq.low", -40), "enabled knob drags")
	testing.expectf(t, a.tracks[0].eq.low_db > before, "enabled knob did not move")
}

@(private)
app_tracks_eq_enabled :: proc(a: ^App) -> bool {
	return a.tracks[a.fx_channel].eq.enabled
}

@(test)
ui_fx_channel_shortcut_refreshes_layout :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_key(&a, .Char, ']')
	testing.expect(t, a.fx_channel == 1, "channel shortcut")
	app_execute(&a, .Fx)
	testing.expect(t, app_drag_id(&a, "knob.eq.mid", -30), "knob drag after channel change")
	testing.expectf(t, a.tracks[1].eq.mid_db > 0, "track 1 eq not changed: %v", a.tracks[1].eq.mid_db)
	testing.expectf(t, a.tracks[0].eq.mid_db == 0, "track 0 changed by mistake")
}

@(test)
ui_many_devices_do_not_overflow_the_io_panel :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	names := make([]string, 24)
	defer delete(names)
	for i in 0 ..< len(names) {
		names[i] = fmt.aprintf("Device %02d", i)
	}
	app_set_devices(&a, names, 0)
	// app_set_devices clones the names, so the originals can go now.
	for n in names {
		delete(n)
	}
	app_execute(&a, .Io)
	testing.expectf(t, a.layout.io_count == MAX_DEVICES, "io_count %d", a.layout.io_count)

	c: Canvas
	canvas_init(&c, 1180, 760)
	defer canvas_destroy(&c)
	app_draw(&a, &c) // must not index past io_row[MAX_DEVICES]
	testing.expect(t, canvas_nonblank(&c), "io screenshot blank")
	app_layout(&a)
	testing.expect(t, app_click_id(&a, "io.row.15"), "last visible row")
	testing.expectf(t, a.device_index == 15, "device index %d", a.device_index)
}

@(test)
ui_layout_geometry_across_sizes :: proc(t: ^testing.T) {
	sizes := [3][2]int{{900, 620}, {1180, 760}, {1920, 1080}}
	for size in sizes {
		a: App
		app_init(&a, size[0], size[1])
		names := [2]string{"Alpha", "Beta"}
		app_set_devices(&a, names[:], 0)
		a.mode = .Palette
		a.palette_len = 0
		app_palette_rebuild(&a)
		app_layout(&a)

		testing.expect(t, rect_within(a.layout.palette, Rect{0, 0, f32(a.width), f32(a.height)}), "palette off-screen")
		for i in 0 ..< a.palette_count {
			row := a.layout.palette_row[i]
			testing.expectf(t, rect_within(row, a.layout.palette), "%dx%d palette row %d escapes", size[0], size[1], i)
			testing.expectf(t, row.y + row.h <= a.layout.palette.y + a.layout.palette.h - 26, "%dx%d palette row %d hits footer", size[0], size[1], i)
		}

		a.mode = .Normal
		app_layout(&a)
		for i in 0 ..< MAX_TRACKS {
			tr := a.layout.track[i]
			for r, name in ([?]Rect{
				a.layout.arm[i], a.layout.solo[i], a.layout.mute[i], a.layout.input[i],
				a.layout.fader[i], a.layout.meter[i], a.layout.pan[i],
			}) {
				testing.expectf(t, rect_within(r, tr), "%dx%d track %d control %d escapes", size[0], size[1], i, name)
			}
			testing.expectf(t, a.layout.fader[i].x + a.layout.fader[i].w < a.layout.meter[i].x, "fader overlaps meter")
		}
		testing.expect(t, rect_within(a.layout.rec, a.layout.transport), "REC off transport")
		testing.expect(t, rect_within(a.layout.bounce, a.layout.transport), "BOUNCE off transport")
		testing.expect(t, rect_within(a.layout.io, a.layout.transport), "I/O off transport")
		testing.expect(t, rect_within(a.layout.bpm_minus, a.layout.header), "BPM- off header")
		testing.expect(t, rect_within(a.layout.bpm_plus, a.layout.header), "BPM+ off header")
		testing.expect(t, rect_within(a.layout.click, a.layout.header), "CLICK off header")

		a.mode = .Fx
		a.fx_channel = 4
		app_layout(&a)
		testing.expect(t, a.layout.knob_count + a.layout.toggle_count > 0, "master rack empty")
		for i in 0 ..< a.layout.knob_count {
			inside := false
			for m in 0 ..< a.layout.fx_module_count {
				if a.layout.fx_module_id[m] == a.layout.knob_target[i].module && rect_within(a.layout.knob[i], a.layout.fx_module[m]) {
					inside = true
				}
			}
			testing.expectf(t, inside, "%dx%d knob %d escapes its module", size[0], size[1], i)
		}
		for i in 0 ..< a.layout.toggle_count {
			inside := false
			for m in 0 ..< a.layout.fx_module_count {
				if a.layout.fx_module_id[m] == a.layout.toggle_target[i].module && rect_within(a.layout.toggle[i], a.layout.fx_module[m]) {
					inside = true
				}
			}
			testing.expectf(t, inside, "%dx%d toggle %d escapes its module", size[0], size[1], i)
		}
		for i in 0 ..< 5 {
			testing.expectf(t, rect_within(a.layout.fx_tab[i], a.layout.fx_panel), "tab %d escapes", i)
		}
		testing.expect(t, rect_within(a.layout.fx_close, a.layout.fx_panel), "close escapes")

		a.mode = .Io
		app_layout(&a)
		for i in 0 ..< a.layout.io_count {
			testing.expectf(t, rect_within(a.layout.io_row[i], a.layout.io_panel), "%dx%d io row %d escapes", size[0], size[1], i)
		}
		app_destroy(&a)
	}
}

@(test)
ui_interactive_targets_meet_minimum_size :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 900, 620)
	defer app_destroy(&a)
	names := [2]string{"Alpha", "Beta"}
	app_set_devices(&a, names[:], 0)

	check := proc(t: ^testing.T, label: string, r: Rect) {
		testing.expectf(t, r.w >= 20 && r.h >= 20, "%s target too small: %.0fx%.0f", label, r.w, r.h)
	}
	check(t, "rec", a.layout.rec)
	check(t, "play", a.layout.play)
	check(t, "stop", a.layout.stop)
	check(t, "bounce", a.layout.bounce)
	check(t, "fx", a.layout.fx)
	check(t, "io", a.layout.io)
	check(t, "bpm-", a.layout.bpm_minus)
	check(t, "bpm+", a.layout.bpm_plus)
	check(t, "click", a.layout.click)
	for i in 0 ..< MAX_TRACKS {
		check(t, "arm", a.layout.arm[i])
		check(t, "solo", a.layout.solo[i])
		check(t, "mute", a.layout.mute[i])
		check(t, "input", a.layout.input[i])
		check(t, "fader", a.layout.fader[i])
		check(t, "pan", a.layout.pan[i])
	}
	app_execute(&a, .Fx)
	for i in 0 ..< 5 do check(t, "tab", a.layout.fx_tab[i])
	check(t, "close", a.layout.fx_close)
	for i in 0 ..< a.layout.toggle_count do check(t, "toggle", a.layout.toggle[i])
	a.mode = .Palette
	a.palette_len = 0
	app_palette_rebuild(&a)
	for i in 0 ..< a.palette_count do check(t, "palette row", a.layout.palette_row[i])
	a.mode = .Io
	app_layout(&a)
	for i in 0 ..< a.layout.io_count do check(t, "io row", a.layout.io_row[i])
}

@(test)
ui_render_is_nonblank_in_every_mode_and_size :: proc(t: ^testing.T) {
	sizes := [3][2]int{{900, 620}, {1180, 760}, {1920, 1080}}
	modes := [5]Mode{.Normal, .Fx, .Palette, .Io, .Bounce}
	for size in sizes {
		a: App
		app_init(&a, size[0], size[1])
		names := [3]string{"Scarlett 4i4", "MX Brio", "Ryzen Mic"}
		app_set_devices(&a, names[:], 0)
		a.demo = true
		a.tracks[0].has_audio = true
		a.tracks[0].armed = true
		c: Canvas
		canvas_init(&c, size[0], size[1])
		for mode in modes {
			a.mode = mode
			for ch in 0 ..< 5 {
				a.fx_channel = ch
				a.palette_len = 0
				app_palette_rebuild(&a)
				canvas_clear(&c, BG)
				app_draw(&a, &c)
				testing.expectf(t, canvas_nonblank(&c), "%dx%d mode %v channel %d rendered blank", size[0], size[1], mode, ch)
			}
		}
		canvas_destroy(&c)
		app_destroy(&a)
	}
}

@(test)
ui_text_tokens_keep_readable_contrast :: proc(t: ^testing.T) {
	cases := [9]struct {
		name: string,
		fg:   Color,
		bg:   Color,
		min:  f32,
	}{
		{"text on bg", TEXT, BG, 7.0},
		{"dim on bg", DIM, BG, 4.5},
		{"muted on bg", MUTED, BG, 3.5},
		{"muted on panel", MUTED, PANEL_2, 3.5},
		{"amber on bg", AMBER, BG, 4.5},
		{"teal on bg", TEAL, BG, 4.5},
		{"red on panel", RED, PANEL, 3.5},
		{"amber_dim border", AMBER_DIM, PANEL, 3.0},
		{"white on red", WHITE, RED, 4.5},
	}
	for c in cases {
		ratio := contrast_ratio(c.fg, c.bg)
		testing.expectf(t, ratio >= c.min, "%s contrast %.2f < %.1f", c.name, ratio, c.min)
	}
}

@(test)
ui_unknown_targets_paths_and_keys_are_rejected :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	_, ok := app_target_rect(&a, "does.not.exist")
	testing.expect(t, !ok, "unknown rect")
	testing.expect(t, !app_click_id(&a, "does.not.exist"), "unknown click")
	testing.expect(t, !app_drag_id(&a, "does.not.exist", 10), "unknown drag")
	_, ok = app_value(&a, "does.not.exist")
	testing.expect(t, !ok, "unknown value path")
	testing.expect(t, !app_key_name(&a, "nope"), "unknown key")
	testing.expect(t, !app_target_available(&a, "does.not.exist"), "unknown availability")
	testing.expect(t, app_key_name(&a, "tab"), "tab key supported")
	testing.expect(t, app_key_name(&a, "shift+tab"), "shift+tab key supported")
	testing.expect(t, app_key_name(&a, "left"), "left key supported")
	testing.expect(t, app_key_name(&a, "right"), "right key supported")
	testing.expect(t, !app_key_name(&a, ""), "empty key rejected")
}

@(test)
ui_stop_clears_transport_after_play :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_execute(&a, .Play)
	testing.expect(t, a.transport == .Playing, "playing")
	app_tick(&a, 0.5)
	testing.expect(t, a.frames > 0, "timecode")
	app_execute(&a, .Stop)
	testing.expect(t, a.transport == .Stopped && a.frames == 0, "stop should reset timecode")
}

@(test)
ui_master_rack_text_fits_at_minimum_width :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 900, 620)
	defer app_destroy(&a)
	a.mode = .Fx
	a.fx_channel = MAX_TRACKS
	app_layout(&a)

	for mi in 0 ..< a.layout.fx_module_count {
		p := a.layout.fx_module[mi]
		m := a.layout.fx_module_id[mi]
		cell := p.w / 3
		for k in 0 ..< a.layout.knob_count {
			target := a.layout.knob_target[k]
			if target.module != m {
				continue
			}
			value := app_knob_value(&a, target)
			text := knob_value_text(m, target.param, value, true)
			testing.expectf(t, text_width(text) + 4 <= cell, "%s %s value %q overflows cell %.0f", module_title(m), param_label(m, target.param), text, cell)
		}

		// Module header: title must clear every power/ping-pong chip.
		title_end := p.x + 34 + text_width(module_title(m))
		for k in 0 ..< a.layout.toggle_count {
			if a.layout.toggle_target[k].module != m {
				continue
			}
			testing.expectf(t, title_end + 2 <= a.layout.toggle[k].x, "%s title hits its toggle", module_title(m))
		}
	}

	// The hero timecode clears the transport buttons at the minimum width.
	clock_left := max(f32(a.width) * 0.5, a.layout.io.x + a.layout.io.w + 120) - text_width(timecode(0, a.sample_rate), 2) * 0.5
	testing.expectf(t, clock_left >= a.layout.io.x + a.layout.io.w + 16, "timecode crowds the transport: %.0f", clock_left)
}
// ---------------------------------------------------------------- typography

@(test)
ui_font_metrics_match_cells :: proc(t: ^testing.T) {
	testing.expectf(t, text_width("M") == f32(FONT_W), "single cell width %v", text_width("M"))
	testing.expectf(t, text_width("MST", 2) == f32(FONT_W * 2 * 3), "scale-2 width %v", text_width("MST", 2))
	testing.expectf(t, text_height() == f32(FONT_H), "cell height %v", text_height())
	testing.expectf(t, text_height(2) == f32(FONT_H * 2), "scale-2 height %v", text_height(2))
	testing.expectf(t, FONT_LARGE_W == FONT_W * 2, "large atlas is not 2x wide")
	testing.expectf(t, FONT_LARGE_H == FONT_H * 2, "large atlas is not 2x tall")
	testing.expectf(t, FONT_SMALL_BASELINE > 0 && FONT_SMALL_BASELINE < FONT_H, "small baseline %d", FONT_SMALL_BASELINE)
}

@(test)
ui_font_glyphs_are_anti_aliased :: proc(t: ^testing.T) {
	small_aa, small_full, large_aa, large_full: int
	for i in 0 ..< (FONT_LAST - FONT_FIRST + 1) {
		for row in 0 ..< FONT_H {
			for col in 0 ..< FONT_W {
				a := font_small_alpha(i, row, col)
				if a > 0 && a < 255 {
					small_aa += 1
				}
				if a == 255 {
					small_full += 1
				}
			}
		}
		for row in 0 ..< FONT_LARGE_H {
			for col in 0 ..< FONT_LARGE_W {
				a := font_large_alpha(i, row, col)
				if a > 0 && a < 255 {
					large_aa += 1
				}
				if a == 255 {
					large_full += 1
				}
			}
		}
	}
	testing.expectf(t, small_aa > 100, "small atlas has only %d edge pixels", small_aa)
	testing.expectf(t, small_full > 0, "small atlas has no solid ink")
	testing.expectf(t, large_aa > 400, "large atlas has only %d edge pixels", large_aa)
	testing.expectf(t, large_full > 0, "large atlas has no solid ink")
}

@(test)
ui_font_keeps_descenders_and_baseline :: proc(t: ^testing.T) {
	// Every descender must paint below the shared baseline.
	for ch in "gjpqy" {
		i := int(ch) - FONT_FIRST
		below := 0
		lowest := 0
		for row in FONT_SMALL_BASELINE + 1 ..< FONT_H {
			for col in 0 ..< FONT_W {
				if font_small_alpha(i, row, col) > 0 {
					below += 1
				}
			}
		}
		for row in 0 ..< FONT_H {
			for col in 0 ..< FONT_W {
				if font_small_alpha(i, row, col) > 0 {
					lowest = row
				}
			}
		}
		testing.expectf(t, below > 0, "small %q has no descender below baseline", ch)
		testing.expectf(t, lowest > FONT_SMALL_BASELINE && lowest < FONT_H, "small %q descender row %d", ch, lowest)

		large_below := 0
		for row in FONT_LARGE_BASELINE + 1 ..< FONT_LARGE_H {
			for col in 0 ..< FONT_LARGE_W {
				if font_large_alpha(i, row, col) > 0 {
					large_below += 1
				}
			}
		}
		testing.expectf(t, large_below > 0, "large %q has no descender below baseline", ch)
	}

	// Cap tops are consistent between the two atlases: the large cell is the
	// exact 2x companion of the small one.
	small_top, large_top := FONT_H, FONT_LARGE_H
	for row in 0 ..< FONT_H {
		for col in 0 ..< FONT_W {
			if font_small_alpha(int('H') - FONT_FIRST, row, col) > 0 {
				small_top = min(small_top, row)
			}
		}
	}
	for row in 0 ..< FONT_LARGE_H {
		for col in 0 ..< FONT_LARGE_W {
			if font_large_alpha(int('H') - FONT_FIRST, row, col) > 0 {
				large_top = min(large_top, row)
			}
		}
	}
	testing.expectf(t, large_top == small_top * 2, "cap tops drift: small %d large %d", small_top, large_top)
	testing.expectf(t, FONT_LARGE_BASELINE == FONT_SMALL_BASELINE * 2, "baselines drift")
}

@(test)
ui_font_text_screenshot_has_grayscale_edges :: proc(t: ^testing.T) {
	c: Canvas
	canvas_init(&c, 420, 80)
	defer canvas_destroy(&c)
	canvas_clear(&c, BG)
	canvas_text(&c, 8, 6, "TRACKER gjpqy", TEXT, 2)
	canvas_text(&c, 8, 44, "00:01:23.456  -12.3 dB", DIM)

	levels: [256]bool
	ink := 0
	for p in c.pixels {
		r := u8((p >> 16) & 0xFF)
		if r != u8((BG >> 16) & 0xFF) {
			ink += 1
			levels[r] = true
		}
	}
	level_count := 0
	for seen in levels {
		if seen {
			level_count += 1
		}
	}
	testing.expectf(t, ink > 300, "too few text pixels: %d", ink)
	testing.expectf(t, level_count > 8, "text has only %d luminance levels (not anti-aliased)", level_count)

	path := "/tmp/tracker-odin-font-test.png"
	defer os.remove(path)
	testing.expect(t, canvas_screenshot(&c, path), "font screenshot failed")
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil && len(data) > 1_000, "font screenshot missing or tiny")
}
