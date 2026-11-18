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
