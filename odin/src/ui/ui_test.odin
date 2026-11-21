package ui

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
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

	modes := [7]Mode{.Normal, .Fx, .Palette, .Io, .Bounce, .Recent, .Settings}
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
	for i in 0 ..< a.layout.palette_count {
		row := a.layout.palette_row[i]
		testing.expectf(t, rect_within(row, a.layout.palette), "palette row %d escapes the panel", i)
		testing.expectf(t, row.y + row.h <= a.layout.palette.y + a.layout.palette.h - 26, "palette row %d hits the footer", i)
	}
	testing.expect(t, a.palette_count == len(PALETTE_COMMANDS), "all commands should be listed")
	testing.expectf(t, a.layout.palette_count < a.palette_count, "palette should window %d/%d rows", a.layout.palette_count, a.palette_count)
	// Selection follows the scroll window to the last command.
	a.palette_sel = a.palette_count - 1
	app_layout(&a)
	testing.expectf(t, a.palette_scroll > 0, "scroll did not follow selection: %d", a.palette_scroll)
	testing.expectf(t, a.palette_sel < a.palette_scroll + a.layout.palette_count, "selected row is outside the window")
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
	testing.expect(t, app_status(&a) == "recording: press R to stop the take", "missing refusal status")
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
ui_window_zoom_scales_type_and_keeps_base_density :: proc(t: ^testing.T) {
	testing.expect(t, abs(ui_zoom_for_window(1180, 760) - 1) < 0.001, "base window must be 1x")
	testing.expect(t, abs(ui_zoom_for_window(900, 620) - 1) < 0.001, "small windows must not shrink type")
	check_1080 := ui_zoom_for_window(1920, 1080)
	testing.expectf(t, check_1080 > 1.45 && check_1080 <= UI_MAX_ZOOM, "1080p zoom %.3f", check_1080)
	testing.expect(t, ui_zoom_for_window(3840, 2160) == UI_MAX_ZOOM, "4K must clamp to the max zoom")
	testing.expect(t, ui_zoom_for_window(900, 1400) == 1.0, "a narrow tall window must keep base type")
	testing.expect(t, ui_zoom_for_window(2536, 986) > 1.5, "a wide short window should still scale the type")

	vw, vh := ui_virtual_size(1920, 1080)
	testing.expectf(t, vw >= 900 && vh >= 620 && vh <= 760, "1080p layout %dx%d escaped the tested range", vw, vh)
	vw2, vh2 := ui_virtual_size(2536, 986)
	testing.expectf(t, vh2 >= 620 && vw2 >= 900, "wide layout %dx%d escaped the tested range", vw2, vh2)

	// The visible type size is type * zoom, so larger windows get larger type.
	z := ui_zoom_for_window(1920, 1080)
	testing.expect(t, TOKENS_DEFAULT.type.body * z > TOKENS_DEFAULT.type.body * 1.4, "body type must grow with the window")
	testing.expect(t, TOKENS_DEFAULT.metrics.header_h * z > TOKENS_DEFAULT.metrics.header_h, "header must grow with the type")
}

@(test)
ui_layout_geometry_across_sizes :: proc(t: ^testing.T) {
	sizes := [3][2]int{{900, 620}, {1180, 760}, {1920, 1080}}
	for size in sizes {
		vw, vh := ui_virtual_size(size[0], size[1])
		a: App
		app_init(&a, vw, vh)
		names := [2]string{"Alpha", "Beta"}
		app_set_devices(&a, names[:], 0)
		a.mode = .Palette
		a.palette_len = 0
		app_palette_rebuild(&a)
		app_layout(&a)

		testing.expect(t, rect_within(a.layout.palette, Rect{0, 0, f32(a.width), f32(a.height)}), "palette off-screen")
		for i in 0 ..< a.layout.palette_count {
			row := a.layout.palette_row[i]
			testing.expectf(t, rect_within(row, a.layout.palette), "%dx%d palette row %d escapes", size[0], size[1], i)
			testing.expectf(t, row.y + row.h <= a.layout.palette.y + a.layout.palette.h - 26, "%dx%d palette row %d hits footer", size[0], size[1], i)
		}
		testing.expectf(t, a.layout.palette_count >= 10, "%dx%d palette window too small: %d", size[0], size[1], a.layout.palette_count)

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
	modes := [7]Mode{.Normal, .Fx, .Palette, .Io, .Bounce, .Recent, .Settings}
	for size in sizes {
		vw, vh := ui_virtual_size(size[0], size[1])
		a: App
		app_init(&a, vw, vh)
		names := [3]string{"Scarlett 4i4", "MX Brio", "Ryzen Mic"}
		app_set_devices(&a, names[:], 0)
		a.demo = true
		a.tracks[0].has_audio = true
		a.tracks[0].armed = true
		c: Canvas
		canvas_init(&c, vw, vh)
		for mode in modes {
			a.mode = mode
			for ch in 0 ..< 5 {
				a.fx_channel = ch
				a.palette_len = 0
				app_palette_rebuild(&a)
				canvas_clear(&c, COLORS_DEFAULT.bg)
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
		{"text on bg", COLORS_DEFAULT.ink, COLORS_DEFAULT.bg, 7.0},
		{"dim on bg", COLORS_DEFAULT.ink_dim, COLORS_DEFAULT.bg, 4.5},
		// Muted is hint-only in this palette (the reference uses the same
		// value); essential labels use ink_dim, which is tested at 4.5.
		{"muted on bg", COLORS_DEFAULT.ink_muted, COLORS_DEFAULT.bg, 3.0},
		{"muted on panel", COLORS_DEFAULT.ink_muted, COLORS_DEFAULT.surface_raised, 2.8},
		{"amber on bg", COLORS_DEFAULT.amber, COLORS_DEFAULT.bg, 4.5},
		{"teal on bg", COLORS_DEFAULT.teal, COLORS_DEFAULT.bg, 4.5},
		{"red on panel", COLORS_DEFAULT.red, COLORS_DEFAULT.surface, 3.0},
		{"amber_dim border", COLORS_DEFAULT.amber_dim, COLORS_DEFAULT.surface, 3.0},
		{"on-amber on red", COLORS_DEFAULT.on_amber, COLORS_DEFAULT.red, 4.5},
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
ui_font_text_screenshot_has_grayscale_edges :: proc(t: ^testing.T) {	c: Canvas
	canvas_init(&c, 420, 80)
	defer canvas_destroy(&c)
	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_text(&c, 8, 6, "TRACKER gjpqy", COLORS_DEFAULT.ink, 2)
	canvas_text(&c, 8, 44, "00:01:23.456  -12.3 dB", COLORS_DEFAULT.ink_dim)

	levels: [256]bool
	ink := 0
	for p in c.pixels {
		r := u8((p >> 16) & 0xFF)
		if r != u8((COLORS_DEFAULT.bg >> 16) & 0xFF) {
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


// ---------------------------------------------------------------- undo / redo

@(test)
ui_undo_redo_arm_mute_solo :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_click_id(&a, "arm.0"), "arm")
	testing.expect(t, a.tracks[0].armed, "armed")
	testing.expect(t, app_click_id(&a, "mute.0"), "mute")
	testing.expect(t, a.tracks[0].muted, "muted")
	testing.expect(t, app_click_id(&a, "solo.0"), "solo")
	testing.expect(t, a.tracks[0].soloed, "soloed")

	app_key(&a, .Char, 'u')
	testing.expect(t, !a.tracks[0].soloed && a.tracks[0].muted && a.tracks[0].armed, "undo solo")
	app_key(&a, .Char, 'u')
	testing.expect(t, !a.tracks[0].muted && a.tracks[0].armed, "undo mute")
	app_key(&a, .Char, 'u')
	testing.expect(t, !a.tracks[0].armed, "undo arm")
	testing.expect(t, strings.contains(app_status(&a), "undid arm"), "undo status")
	testing.expect(t, strings.contains(app_status(&a), "takes kept"), "take safety documented")

	app_key(&a, .Char, 'U')
	app_key(&a, .Char, 'U')
	app_key(&a, .Char, 'U')
	testing.expect(t, a.tracks[0].armed && a.tracks[0].muted && a.tracks[0].soloed, "redo all")
	testing.expect(t, app_value_is(&a, "redo.can", "false"), "redo exhausted")
}

@(test)
ui_undo_redo_fader_pan_knob :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	testing.expect(t, app_drag_id(&a, "fader.0", -60), "fader drag")
	raised := a.tracks[0].level
	testing.expectf(t, raised > 0.9, "fader raised: %v", raised)
	app_key(&a, .Char, 'u')
	testing.expectf(t, abs(a.tracks[0].level - 0.8) < 0.001, "fader undo: %v", a.tracks[0].level)
	app_key(&a, .Char, 'U')
	testing.expectf(t, a.tracks[0].level > 0.9, "fader redo: %v", a.tracks[0].level)

	testing.expect(t, app_drag_id(&a, "pan.1", -60), "pan drag")
	panned := a.tracks[1].pan
	app_key(&a, .Char, 'u')
	testing.expectf(t, abs(a.tracks[1].pan) < 0.001, "pan undo: %v", a.tracks[1].pan)
	app_key(&a, .Char, 'U')
	testing.expectf(t, a.tracks[1].pan == panned, "pan redo")

	app_execute(&a, .Fx)
	testing.expect(t, app_drag_id(&a, "knob.eq.low", -40), "knob drag")
	boost := a.tracks[0].eq.low_db
	testing.expectf(t, boost > 3, "knob boosted: %v", boost)
	app_key(&a, .Char, 'u')
	testing.expectf(t, abs(a.tracks[0].eq.low_db) < 0.001, "knob undo: %v", a.tracks[0].eq.low_db)
	app_key(&a, .Char, 'U')
	testing.expectf(t, a.tracks[0].eq.low_db == boost, "knob redo")
}

@(test)
ui_undo_truncates_the_redo_branch :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_click_id(&a, "arm.0")
	app_key(&a, .Char, 'u')
	testing.expect(t, app_value_is(&a, "redo.depth", "1"), "one redo candidate")
	// A fresh edit after undo discards the abandoned redo branch.
	app_click_id(&a, "mute.0")
	testing.expect(t, app_value_is(&a, "redo.depth", "0"), "redo branch truncated")
	before := a.tracks[0].muted
	app_key(&a, .Char, 'U')
	testing.expect(t, a.tracks[0].muted == before, "redo did nothing after truncation")
	testing.expect(t, app_status(&a) == "nothing to redo", "redo refusal status")
}

@(test)
ui_undo_never_removes_a_recording_take :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_click_id(&a, "arm.0")
	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Recording, "recording")
	a.tracks[0].has_audio = true
	app_key(&a, .Char, 'u')
	testing.expect(t, a.transport == .Recording, "undo refused mid-take")
	testing.expect(t, app_status(&a) == "recording - stop before undo", "refusal status")
	testing.expect(t, a.tracks[0].armed, "arm untouched during take")

	app_key(&a, .Char, 'r')
	testing.expect(t, a.transport == .Stopped, "take stopped")
	testing.expect(t, strings.contains(app_status(&a), "undo keeps audio"), "take safety status")
	app_key(&a, .Char, 'u')
	testing.expect(t, !a.tracks[0].armed, "arm undone after take")
	testing.expect(t, a.tracks[0].has_audio, "take audio survives undo")
}

@(test)
ui_history_is_capped_at_64_entries :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	for _ in 0 ..< 70 {
		app_key(&a, .Char, 'c')
	}
	testing.expectf(t, a.history_count == MAX_HISTORY, "history count %d", a.history_count)
	testing.expect(t, a.history_pos == MAX_HISTORY - 1, "history position at the tip")
	testing.expect(t, a.metronome == false, "70 toggles return to off")
}

@(test)
ui_state_revision_tracks_mutations :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	start := a.state_revision
	testing.expect(t, app_value_is(&a, "revision", fmt.tprintf("%d", start)), "initial revision")
	app_click_id(&a, "arm.0")
	testing.expect(t, a.state_revision > start, "click bumps revision")
	mid := a.state_revision
	app_key(&a, .Char, 'u')
	testing.expect(t, a.state_revision > mid, "undo bumps revision")
}

// ---------------------------------------------------------------- recent projects

@(test)
ui_recent_filter_select_and_emit :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_set_recent(&a, []string{"/home/studio/live-set", "/home/studio/album-2026", "/tmp/sketch"})
	testing.expectf(t, a.recent_count == 3, "recent count %d", a.recent_count)

	app_recent_open(&a)
	testing.expect(t, a.mode == .Recent, "recent overlay")
	testing.expect(t, app_target_available(&a, "recent.row.0"), "recent row live")
	testing.expect(t, !app_target_available(&a, "arm.0"), "workspace covered")
	testing.expectf(t, a.recent_filtered == 3, "filtered %d", a.recent_filtered)

	type_query(&a, "live")
	testing.expectf(t, a.recent_filtered == 1, "filter live -> %d", a.recent_filtered)
	testing.expect(t, app_value_is(&a, "recent.path", "/home/studio/live-set"), "filtered path")
	app_key(&a, .Enter)
	testing.expect(t, a.mode == .Normal, "selection closes overlay")
	testing.expect(t, a.last_command == .Open_Recent, "Open_Recent emitted")
	testing.expect(t, app_value_is(&a, "command", "Open_Recent"), "command path")
	testing.expect(t, app_value_is(&a, "recent.target", "/home/studio/live-set"), "recent target")
	testing.expect(t, app_value_is(&a, "command.index", "0"), "command index")
}

@(test)
ui_recent_empty_state_and_duplicate_handling :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_recent_open(&a)
	testing.expect(t, a.recent_filtered == 0, "empty list")
	testing.expect(t, !app_target_available(&a, "recent.row.0"), "no rows when empty")
	app_key(&a, .Enter)
	testing.expect(t, app_status(&a) == "no recent projects", "empty status")
	testing.expect(t, a.mode == .Recent, "empty overlay stays open")

	c: Canvas
	canvas_init(&c, 1180, 760)
	defer canvas_destroy(&c)
	app_draw(&a, &c)
	testing.expect(t, canvas_nonblank(&c), "empty recent overlay renders")

	app_key(&a, .Escape)
	app_add_recent(&a, "/a")
	app_add_recent(&a, "/b")
	app_add_recent(&a, "/a")
	testing.expectf(t, a.recent_count == 2, "dedupe count %d", a.recent_count)
	testing.expect(t, app_recent_path(&a, 0) == "/a", "duplicate moved to front")
}

@(test)
ui_project_picker_commands_emit :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	open_palette(&a)
	type_query(&a, "open project")
	testing.expectf(t, a.palette_count == 1, "open project match %d", a.palette_count)
	app_key(&a, .Enter)
	testing.expect(t, a.last_command == .Open_Project, "Open_Project")
	testing.expect(t, app_value_is(&a, "command", "Open_Project"), "command assert path")
	testing.expect(t, a.last_command_index == 0, "picker index cleared")

	open_palette(&a)
	type_query(&a, "save project as")
	testing.expectf(t, a.palette_count == 1, "save as match %d", a.palette_count)
	app_key(&a, .Enter)
	testing.expect(t, a.last_command == .Save_As, "Save_As")
	testing.expect(t, strings.contains(app_status(&a), "picker"), "picker status")
}

// ---------------------------------------------------------------- accessibility

@(test)
ui_high_contrast_tokens_raise_contrast :: proc(t: ^testing.T) {
	base := theme_tokens(false)
	high := theme_tokens(true)
	testing.expect(t, base.color.ink != high.color.ink, "text token should change")
	testing.expect(t, base.color.ink_dim != high.color.ink_dim, "dim token should change")
	cases := [4]struct {
		name: string,
		lo:   Color,
		hi:   Color,
		min:  f32,
	}{
		{"text on bg", base.color.ink, high.color.ink, 15.0},
		{"dim on bg", base.color.ink_dim, high.color.ink_dim, 7.0},
		{"muted on bg", base.color.ink_muted, high.color.ink_muted, 5.0},
		{"amber on bg", base.color.amber, high.color.amber, 7.0},
	}
	for c in cases {
		rb := contrast_ratio(c.lo, base.color.bg)
		rh := contrast_ratio(c.hi, high.color.bg)
		testing.expectf(t, rh > rb, "%s did not improve: %.2f -> %.2f", c.name, rb, rh)
		testing.expectf(t, rh >= c.min, "%s high contrast %.2f < %.1f", c.name, rh, c.min)
	}
}

@(test)
ui_accessibility_toggles_from_palette :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	open_palette(&a)
	type_query(&a, "high contrast")
	app_key(&a, .Enter)
	testing.expect(t, a.high_contrast, "high contrast on")
	testing.expect(t, app_value_is(&a, "a11y.high_contrast", "true"), "high contrast path")
	testing.expect(t, app_tokens(&a).color.ink == TOKENS_HIGH_CONTRAST.color.ink, "app tokens switch")
	open_palette(&a)
	type_query(&a, "high contrast")
	app_key(&a, .Enter)
	testing.expect(t, !a.high_contrast, "high contrast off")

	open_palette(&a)
	type_query(&a, "reduced motion")
	app_key(&a, .Enter)
	testing.expect(t, a.reduced_motion, "reduced motion on")
	testing.expect(t, app_value_is(&a, "a11y.reduced_motion", "true"), "motion path")
}

@(private)
frames_equal :: proc(a, b: ^Canvas) -> bool {
	if len(a.pixels) != len(b.pixels) {
		return false
	}
	for p, i in a.pixels {
		if p != b.pixels[i] {
			return false
		}
	}
	return true
}

@(test)
ui_reduced_motion_freezes_the_recording_pulse :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	a.tracks[0].armed = true
	a.transport = .Recording

	c1: Canvas
	c2: Canvas
	canvas_init(&c1, 1180, 760)
	canvas_init(&c2, 1180, 760)
	defer canvas_destroy(&c1)
	defer canvas_destroy(&c2)

	a.time = 0
	app_draw(&a, &c1)
	a.time = 1.31
	app_draw(&a, &c2)
	testing.expect(t, !frames_equal(&c1, &c2), "normal recording pulse should animate")

	a.reduced_motion = true
	a.time = 0
	app_draw(&a, &c1)
	a.time = 1.31
	app_draw(&a, &c2)
	testing.expect(t, frames_equal(&c1, &c2), "reduced motion must freeze the pulse")
}

@(test)
ui_describe_is_a_screen_reader_snapshot :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_click_id(&a, "arm.0")
	app_click_id(&a, "mute.1")
	app_click_id(&a, "solo.2")
	app_execute(&a, .Fx)
	text := app_describe(&a)
	for want in ([]string{
		"mode Fx rack", "transport stopped", "selected track 3",
		"track 1 Track 1: armed", "mute on", "solo on", "level 53 percent",
		"tempo 120 bpm", "undo", "status",
	}) {
		testing.expectf(t, strings.contains(text, want), "describe missing %q in %q", want, text)
	}
	app_key(&a, .Escape)
	app_click_id(&a, "mute.0")
	text2 := app_describe(&a)
	testing.expect(t, strings.contains(text2, "track 1 Track 1: armed, mute on"), "describe reflects mute")
	testing.expect(t, text2 != text, "describe changes with state")
}

// ---------------------------------------------------------------- HiDPI

@(private)
pixel_at :: proc(c: ^Canvas, x, y: int) -> Color {
	canvas_flush(c)
	return c.pixels[y * c.width + x]
}

@(test)
ui_canvas_scale_maps_logical_primitives_to_physical_pixels :: proc(t: ^testing.T) {
	c: Canvas
	canvas_init(&c, 200, 100, 2.0)
	defer canvas_destroy(&c)
	testing.expect(t, c.scale == 2.0, "scale not stored")
	testing.expectf(t, canvas_logical_width(&c) == 100 && canvas_logical_height(&c) == 50, "logical size %dx%d", canvas_logical_width(&c), canvas_logical_height(&c))
	testing.expect(t, canvas_pixel_size(1180, 1.5) == 1770, "1.5x pixel width")

	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_fill(&c, Rect{10, 10, 20, 10}, COLORS_DEFAULT.ink)
	// A 20x10 logical rect covers 40x20 physical pixels at 2x.
	testing.expect(t, pixel_at(&c, 20, 20) == COLORS_DEFAULT.ink, "top-left physical pixel missing")
	testing.expect(t, pixel_at(&c, 59, 39) == COLORS_DEFAULT.ink, "bottom-right physical pixel missing")
	testing.expect(t, pixel_at(&c, 19, 20) == COLORS_DEFAULT.bg, "fill leaked left")
	testing.expect(t, pixel_at(&c, 60, 39) == COLORS_DEFAULT.bg, "fill leaked right")

	// 1 logical px borders become 2 physical px at 2x.
	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_rect(&c, Rect{4, 4, 20, 20}, COLORS_DEFAULT.ink)
	testing.expect(t, pixel_at(&c, 8, 8) == COLORS_DEFAULT.ink && pixel_at(&c, 9, 8) == COLORS_DEFAULT.ink, "rect border is not 2 px")
	testing.expect(t, pixel_at(&c, 10, 10) == COLORS_DEFAULT.bg, "rect border too thick")

	// Clips are stored in physical pixels and intersect logical rectangles.
	canvas_clear(&c, COLORS_DEFAULT.bg)
	old := canvas_push_clip(&c, Rect{0, 0, 15, 15})
	canvas_fill(&c, Rect{0, 0, 100, 100}, COLORS_DEFAULT.amber)
	canvas_pop_clip(&c, old)
	testing.expect(t, pixel_at(&c, 29, 29) == COLORS_DEFAULT.amber, "inside clip missing")
	testing.expect(t, pixel_at(&c, 30, 30) == COLORS_DEFAULT.bg, "clip did not scale")

	// Lines scale their endpoints and their 1 logical px thickness.
	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_hline(&c, 0, 10, 5, COLORS_DEFAULT.teal)
	testing.expect(t, pixel_at(&c, 20, 10) == COLORS_DEFAULT.teal && pixel_at(&c, 20, 11) == COLORS_DEFAULT.teal, "hline is not 2 px tall")
}

@(test)
ui_canvas_text_rasterises_at_physical_size :: proc(t: ^testing.T) {
	scan_height :: proc(c: ^Canvas, x0, x1: int) -> int {
		top, bottom := -1, -1
		for y in 0 ..< c.height {
			for x in x0 ..< x1 {
				if pixel_at(c, x, y) != COLORS_DEFAULT.bg {
					if top < 0 {
						top = y
					}
					bottom = y
				}
			}
		}
		return bottom - top + 1 if top >= 0 else 0
	}

	base: Canvas
	canvas_init(&base, 160, 60, 1.0)
	defer canvas_destroy(&base)
	canvas_clear(&base, COLORS_DEFAULT.bg)
	canvas_text(&base, 4, 4, "H", COLORS_DEFAULT.ink)
	h1 := scan_height(&base, 0, base.width)

	scaled: Canvas
	canvas_init(&scaled, 240, 90, 1.5)
	defer canvas_destroy(&scaled)
	canvas_clear(&scaled, COLORS_DEFAULT.bg)
	canvas_text(&scaled, 4, 4, "H", COLORS_DEFAULT.ink)
	h15 := scan_height(&scaled, 0, scaled.width)
	testing.expectf(t, h15 > h1, "1.5x glyph is not taller: %d vs %d", h15, h1)
	testing.expectf(t, h15 >= int(f32(h1) * 1.4), "1.5x glyph is not physically scaled: %d vs %d", h15, h1)

	// The runtime atlas must stay anti-aliased, not a 1-bit nearest blit.
	levels: [256]bool
	ink := 0
	for p in scaled.pixels {
		r := u8((p >> 16) & 0xFF)
		if p != COLORS_DEFAULT.bg {
			ink += 1
			levels[r] = true
		}
	}
	cov_levels := 0
	for seen in levels {
		if seen {
			cov_levels += 1
		}
	}
	testing.expectf(t, ink > 40, "runtime text has too few pixels: %d", ink)
	testing.expectf(t, cov_levels > 4, "runtime text has only %d coverage levels", cov_levels)

	// Advancing is still the logical 8 px cell: four M's span four cells.
	run: Canvas
	canvas_init(&run, 240, 90, 1.5)
	defer canvas_destroy(&run)
	canvas_clear(&run, COLORS_DEFAULT.bg)
	canvas_text(&run, 0, 0, "MMMM", COLORS_DEFAULT.ink)
	left, right := run.width, -1
	for y in 0 ..< run.height {
		for x in 0 ..< run.width {
			if pixel_at(&run, x, y) != COLORS_DEFAULT.bg {
				left = min(left, x)
				right = max(right, x)
			}
		}
	}
	testing.expectf(t, right - left + 1 >= 42 && right - left + 1 <= 48, "runtime advance drifted: %d px for 4 cells", right - left + 1)
}

@(test)
ui_hidpi_pointer_maps_to_logical_targets :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	c: Canvas
	canvas_init(&c, 2360, 1520, 2.0)
	defer canvas_destroy(&c)

	lx, ly := canvas_physical_to_logical(&c, 1180, 760)
	testing.expectf(t, abs(lx - 590) < 0.01 && abs(ly - 380) < 0.01, "physical centre mapped to %v,%v", lx, ly)

	r, ok := app_target_rect(&a, "arm.2")
	testing.expect(t, ok, "arm.2 target")
	px := (r.x + r.w * 0.5) * 2.0
	py := (r.y + r.h * 0.5) * 2.0
	mx, my := canvas_physical_to_logical(&c, px, py)
	app_mouse_down(&a, mx, my)
	app_mouse_up(&a)
	testing.expectf(t, a.tracks[2].armed, "click at physical %.0f,%.0f missed arm.2", px, py)

	// A point just outside the target in physical space must stay outside.
	r, _ = app_target_rect(&a, "mute.2")
	mx, my = canvas_physical_to_logical(&c, (r.x - 4) * 2.0, (r.y + r.h * 0.5) * 2.0)
	app_mouse_down(&a, mx, my)
	app_mouse_up(&a)
	testing.expect(t, !a.tracks[2].muted, "click outside mute.2 toggled it")
}

@(test)
ui_settings_edits_and_applies_project_folder :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)

	app_set_save_dir(&a, "/tmp/tracker-ui-settings")
	app_execute(&a, .Settings)
	testing.expect(t, a.mode == .Settings, "settings mode")
	testing.expect(t, app_settings_path(&a) == "/tmp/tracker-ui-settings", "path seeded from save dir")

	app_key(&a, .Enter)
	testing.expect(t, a.settings_path_edit, "enter starts editing")
	suffix := "/studio"
	for i in 0 ..< len(suffix) {
		app_key(&a, .Char, suffix[i])
	}
	testing.expectf(t, app_settings_path(&a) == "/tmp/tracker-ui-settings/studio", "typed %s", app_settings_path(&a))
	app_key(&a, .Enter)
	testing.expect(t, !a.settings_path_edit, "enter stops editing")
	testing.expect(t, a.last_command == .Apply_Save_Dir, "apply command emitted")

	app_execute(&a, .Settings)
	testing.expect(t, a.mode == .Normal, "settings closes")
}

@(test)
ui_settings_keyboard_selection_reaches_every_row :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_execute(&a, .Settings)
	testing.expect(t, a.settings_sel == .Path, "starts on path")

	app_key(&a, .Down)
	testing.expect(t, a.settings_sel == .Browse, "down moves to browse")
	app_key(&a, .Char, 'k')
	testing.expect(t, a.settings_sel == .Path, "k moves up")

	for _ in 0 ..< int(Settings_Item.High_Contrast) {
		app_key(&a, .Down)
	}
	testing.expect(t, a.settings_sel == .High_Contrast, "reached high contrast")
	app_key(&a, .Enter)
	testing.expect(t, a.high_contrast, "enter toggles high contrast")
	testing.expect(t, a.settings_dirty, "toggle asks for persistence")

	app_key(&a, .Down)
	testing.expect(t, a.settings_sel == .Reduced_Motion, "reached reduced motion")
	app_key(&a, .Down)
	testing.expect(t, a.settings_sel == .Path, "selection wraps")
}

@(test)
ui_settings_escape_cancels_path_edit :: proc(t: ^testing.T) {
	a: App
	app_init(&a, 1180, 760)
	defer app_destroy(&a)
	app_set_save_dir(&a, "/tmp/tracker-ui-cancel")
	app_execute(&a, .Settings)
	app_key(&a, .Enter)
	app_key(&a, .Char, 'x')
	testing.expect(t, app_settings_path(&a) != app_save_dir(&a), "edit changed path")
	app_key(&a, .Escape)
	testing.expect(t, a.mode == .Settings, "first escape keeps settings open")
	testing.expect(t, app_settings_path(&a) == app_save_dir(&a), "escape restores path")
	app_key(&a, .Escape)
	testing.expect(t, a.mode == .Normal, "second escape closes")

	// Closing the overlay while editing must clear the edit flag so the
	// window stops redrawing the caret.
	app_execute(&a, .Settings)
	app_key(&a, .Enter)
	testing.expect(t, a.settings_path_edit, "entered edit")
	app_settings_close(&a)
	testing.expect(t, !a.settings_path_edit, "close cancels edit")

	app_execute(&a, .High_Contrast)
	testing.expect(t, a.settings_dirty, "a11y change asks for persistence")
}

@(test)
ui_screenshots_render_at_every_supported_scale :: proc(t: ^testing.T) {
	scales := [4]f32{1.0, 1.5, 2.0, 3.0}
	for scale in scales {
		a: App
		app_init(&a, 1180, 760)
		a.demo = true
		a.transport = .Playing
		a.time = 1.3
		a.tracks[0].has_audio = true
		a.tracks[0].peak_db = -12
		a.tracks[1].has_audio = true
		a.tracks[1].peak_db = -20

		c: Canvas
		canvas_init(&c, canvas_pixel_size(1180, scale), canvas_pixel_size(760, scale), scale)
		app_draw(&a, &c)
		testing.expectf(t, canvas_nonblank(&c), "%.2fx frame blank", scale)

		path := fmt.aprintf("/tmp/tracker-hidpi-%.2f.png", scale)
		shot_ok := canvas_screenshot(&c, path)
		testing.expectf(t, shot_ok, "%.2fx screenshot failed", scale)
		data, err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, err == nil && len(data) > 20_000, "%.2fx screenshot too small", scale)
		if len(data) >= 24 {
			w := (int(data[16]) << 24) | (int(data[17]) << 16) | (int(data[18]) << 8) | int(data[19])
			h := (int(data[20]) << 24) | (int(data[21]) << 16) | (int(data[22]) << 8) | int(data[23])
			testing.expectf(t, w == c.width && h == c.height, "%.2fx PNG is %dx%d, want %dx%d", scale, w, h, c.width, c.height)
		} else {
			testing.expectf(t, false, "%.2fx screenshot missing IHDR", scale)
		}
		delete(data)
		os.remove(path)
		delete(path)
		canvas_destroy(&c)
		app_destroy(&a)
	}
}

@(test)
ui_runtime_text_is_deterministic :: proc(t: ^testing.T) {
	c: Canvas
	canvas_init(&c, canvas_pixel_size(640, 1.5), canvas_pixel_size(120, 1.5), 1.5)
	defer canvas_destroy(&c)

	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_text(&c, 8, 8, "DETERMINISTIC 0123", COLORS_DEFAULT.ink, 2)
	first := make([]u32, len(c.pixels))
	defer delete(first)
	copy(first, c.pixels)

	canvas_clear(&c, COLORS_DEFAULT.bg)
	canvas_text(&c, 8, 8, "DETERMINISTIC 0123", COLORS_DEFAULT.ink, 2)
	for p, i in c.pixels {
		if p != first[i] {
			testing.expectf(t, false, "runtime glyph cache changed pixel %d", i)
			return
		}
	}
}
