// `ui-shot`: render one deterministic frame of the native UI to PNG. This is
// the visual feedback loop used while developing the shell.

package main

import "core:fmt"

import ui "ui"

// Scales the app supports. They keep the 8x15 logical cell an integral number
// of physical pixels, which is what makes the baked 1x/2x cells and runtime
// glyphs land on the pixel grid.
SUPPORTED_UI_SCALES := [?]f32{1.0, 1.25, 1.5, 2.0, 3.0}

ui_scale_from_flags :: proc(args: []string, name: string, fallback: f32 = 1.0) -> (f32, bool) {
	if !validate_numbers(args, []string{name}, nil) {
		return fallback, false
	}
	s := flag_f32(args, name, fallback)
	for v in SUPPORTED_UI_SCALES {
		if abs(s - v) < 0.001 {
			return v, true
		}
	}
	fmt.eprintfln("%s must be one of 1, 1.25, 1.5, 2, 3", name)
	return fallback, false
}

run_ui_shot :: proc(args: []string) -> bool {
	if !validate_flags(args, []string{"--out", "--width", "--height", "--scale"}, []string{
		"--playing", "--recording", "--three", "--fx", "--master", "--palette", "--io", "--settings", "--cloud", "--bounce", "--click",
	}) || !validate_numbers(args, nil, []string{"--width", "--height"}) {
		return false
	}
	out := flag_string(args, "--out", "/tmp/tracker-odin-ui.png")
	width := flag_int(args, "--width", 1180)
	height := flag_int(args, "--height", 760)
	scale, scale_ok := ui_scale_from_flags(args, "--scale")
	if !scale_ok {
		return false
	}
	if !cli_window_size_ok(width, height) {
		return false
	}
	if !ensure_parent_dir(out) {
		return false
	}

	// `--width/--height` are window points. The layout is authored smaller and
	// scaled up so text and control density track the window.
	zoom := ui.ui_zoom_for_window(width, height)
	virtual_w, virtual_h := ui.ui_virtual_size(width, height)
	a: ui.App
	ui.app_init(&a, virtual_w, virtual_h)
	defer ui.app_destroy(&a)
	a.demo = true
	a.transport = .Stopped
	if has_flag(args, "--playing") {
		a.transport = .Playing
		a.time = 1.6
	}
	if has_flag(args, "--recording") {
		a.tracks[0].armed = true
		a.tracks[1].armed = true
		a.transport = .Recording
		a.time = 2.4
	}
	a.tracks[0].has_audio = true
	a.tracks[1].has_audio = true
	a.tracks[2].has_audio = has_flag(args, "--three")
	if has_flag(args, "--fx") {
		a.mode = .Fx
		a.fx_channel = 4 if has_flag(args, "--master") else 0
	}
	if has_flag(args, "--palette") {
		a.mode = .Palette
		a.palette_len = 0
		ui.app_palette_rebuild(&a)
	}
	if has_flag(args, "--io") {
		a.mode = .Io
	}
	if has_flag(args, "--settings") {
		a.mode = .Settings
		ui.app_set_save_dir(&a, "/home/studio/Music/Tracker")
		ui.app_set_settings_path(&a, "/home/studio/Music/Tracker")
	}
	if has_flag(args, "--cloud") {
		a.mode = .Cloud
	}
	if has_flag(args, "--bounce") {
		a.mode = .Bounce
		a.bounce_progress = 0.42
	}
	if has_flag(args, "--click") {
		a.metronome = true
	}
	if a.transport != .Stopped {
		for _ in 0 ..< 360 {
			ui.app_tick(&a, 1.0 / 60.0)
		}
	}

	c: ui.Canvas
	ui.canvas_init(&c,
		ui.canvas_pixel_size(width, scale),
		ui.canvas_pixel_size(height, scale),
		scale * zoom)
	defer ui.canvas_destroy(&c)
	ui.app_draw(&a, &c)

	if !ui.canvas_screenshot(&c, out) {
		fmt.eprintfln("cannot write %s", out)
		return false
	}
	fmt.printfln("wrote %s  %dx%d window @ %.2fx  zoom %.2f  (%dx%d layout, %dx%d px)",
		out, width, height, scale, zoom, virtual_w, virtual_h, c.width, c.height)
	return true
}
