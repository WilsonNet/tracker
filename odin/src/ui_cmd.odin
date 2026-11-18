// `ui-shot`: render one deterministic frame of the native UI to PNG. This is
// the visual feedback loop used while developing the shell.

package main

import "core:fmt"

import ui "ui"

run_ui_shot :: proc(args: []string) -> bool {
	if !validate_flags(args, []string{"--out", "--width", "--height"}, []string{
		"--playing", "--recording", "--three", "--fx", "--master", "--palette", "--io", "--bounce",
	}) {
		return false
	}
	out := flag_string(args, "--out", "/tmp/tracker-odin-ui.png")
	width := flag_int(args, "--width", 1180)
	height := flag_int(args, "--height", 760)
	if width < MIN_CLI_DIM || width > MAX_CLI_DIM || height < MIN_CLI_DIM || height > MAX_CLI_DIM {
		fmt.eprintfln("--width/--height must be between %d and %d", MIN_CLI_DIM, MAX_CLI_DIM)
		return false
	}
	if !ensure_parent_dir(out) {
		return false
	}

	a: ui.App
	ui.app_init(&a, width, height)
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
	if has_flag(args, "--bounce") {
		a.mode = .Bounce
		a.bounce_progress = 0.42
	}
	if has_flag(args, "--click") {
		a.metronome = true
	}
	if a.transport != .Stopped {
		for _ in 0 ..< 36 {
			ui.app_tick(&a, 1.0 / 60.0)
		}
	}

	c: ui.Canvas
	ui.canvas_init(&c, width, height)
	defer ui.canvas_destroy(&c)
	ui.app_draw(&a, &c)

	if !ui.canvas_screenshot(&c, out) {
		fmt.eprintfln("cannot write %s", out)
		return false
	}
	fmt.printfln("wrote %s  %dx%d", out, width, height)
	return true
}
