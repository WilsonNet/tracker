// Native SDL2 window. It uploads the same software canvas the headless harness
// renders, so a screenshot from `ui-test` is pixel-identical to the window.

package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:time"

import sdl "vendor:sdl2"
import ui "ui"

run_ui_window :: proc(args: []string) -> bool {
	width := flag_int(args, "--width", 1180)
	height := flag_int(args, "--height", 760)

	if sdl.Init(sdl.INIT_VIDEO) != 0 {
		fmt.eprintfln("SDL init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(
		"Tracker — Odin",
		80,
		80,
		c.int(width),
		c.int(height),
		sdl.WINDOW_RESIZABLE,
	)
	if window == nil {
		fmt.eprintfln("window creation failed: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyWindow(window)
	sdl.SetWindowMinimumSize(window, 900, 620)

	renderer := sdl.CreateRenderer(window, -1, sdl.RENDERER_ACCELERATED | sdl.RENDERER_PRESENTVSYNC)
	if renderer == nil {
		renderer = sdl.CreateRenderer(window, -1, sdl.RENDERER_SOFTWARE)
	}
	if renderer == nil {
		fmt.eprintfln("renderer creation failed: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyRenderer(renderer)

	e: Engine
	if !engine_init(&e, args) {
		return false
	}
	defer engine_destroy(&e)

	a: ui.App
	ui.app_init(&a, width, height)
	defer ui.app_destroy(&a)

	names := engine_device_names()
	default_idx := engine_default_device()
	ui.app_set_devices(&a, names, default_idx)
	for name in names {
		delete(name)
	}
	delete(names)
	e.device_index = default_idx
	a.demo = has_flag(args, "--demo")

	if os.exists(e.project_path) {
		if project_load(&a, e.session_dir, e.project_path) {
			engine_match_device(&e, &a, ui.app_device(&a))
			engine_load_tracks(&e, &a)
			ui.status_buf_set(&a, "project loaded")
		}
	} else {
		engine_load_tracks(&e, &a)
		ui.status_buf_set(&a, "ready")
	}

	canvas: ui.Canvas
	ui.canvas_init(&canvas, width, height)
	defer ui.canvas_destroy(&canvas)

	texture := sdl.CreateTexture(renderer, .ARGB8888, .STREAMING, c.int(width), c.int(height))
	if texture == nil {
		fmt.eprintfln("texture creation failed: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyTexture(texture)

	running := true
	last := time.now()
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEYDOWN:
				if event.key.repeat != 0 {
					continue
				}
				key, ch, shift := map_key(event.key.keysym)
				ui.app_key(&a, key, ch, shift)
			case .MOUSEMOTION:
				ui.app_mouse_move(&a, f32(event.motion.x), f32(event.motion.y))
			case .MOUSEBUTTONDOWN:
				if event.button.button == 1 {
					ui.app_mouse_down(&a, f32(event.button.x), f32(event.button.y))
				}
			case .MOUSEBUTTONUP:
				if event.button.button == 1 {
					ui.app_mouse_up(&a)
				}
			}
		}

		w, h: c.int
		sdl.GetWindowSizeInPixels(window, &w, &h)
		if int(w) != canvas.width || int(h) != canvas.height {
			ui.canvas_resize(&canvas, int(w), int(h))
			ui.app_resize(&a, int(w), int(h))
			sdl.DestroyTexture(texture)
			texture = sdl.CreateTexture(renderer, .ARGB8888, .STREAMING, w, h)
		}

		now := time.now()
		dt := f32(time.duration_seconds(time.since(last)))
		last = now
		ui.app_tick(&a, clamp(dt, 0, 0.1))
		for {
			cmd, has := ui.app_take_command(&a)
			if !has {
				break
			}
			#partial switch cmd.kind {
			case .Play:
				if !engine_play(&e, &a) {
					ui.app_force_stopped(&a, "nothing to play")
				}
			case .Stop:
				engine_stop_playback(&e)
				if e.rec.active {
					_ = engine_record_stop(&e, &a)
				}
			case .Record_Start:
				if !engine_record_start(&e, &a) {
					ui.app_force_stopped(&a, ui.app_status(&a))
				}
			case .Record_Stop:
				_ = engine_record_stop(&e, &a)
			case .Bounce:
				_ = engine_bounce(&e, &a)
			case .Save:
				if project_save(&a, e.project_path) {
					ui.status_buf_set(&a, "project saved")
				} else {
					ui.status_buf_set(&a, "save failed")
					ui.toast(&a, "save failed")
				}
			case .Load:
				if project_load(&a, e.session_dir, e.project_path) {
					_ = engine_load_tracks(&e, &a)
					engine_match_device(&e, &a, ui.app_device(&a))
					ui.status_buf_set(&a, "project loaded")
				} else {
					ui.status_buf_set(&a, "load failed")
					ui.toast(&a, "load failed")
				}
			case .Select_Device:
				engine_set_device(&e, &a, cmd.index)
			case:
			}
		}
		engine_update(&e, &a)
		ui.app_draw(&a, &canvas)

		sdl.UpdateTexture(texture, nil, raw_data(canvas.pixels), c.int(canvas.width * 4))
		sdl.RenderClear(renderer)
		sdl.RenderCopy(renderer, texture, nil, nil)
		sdl.RenderPresent(renderer)
		time.sleep(6 * time.Millisecond)
	}
	return true
}

@(private)
map_key :: proc(ks: sdl.Keysym) -> (key: ui.Key, ch: u8, shift: bool) {
	shift = .LSHIFT in ks.mod || .RSHIFT in ks.mod
	#partial switch ks.sym {
	case .SPACE:
		return .Space, ' ', shift
	case .RETURN, .RETURN2:
		return .Enter, 0, shift
	case .ESCAPE:
		return .Escape, 0, shift
	case .BACKSPACE:
		return .Backspace, 0, shift
	case .LEFT:
		return .Left, 0, shift
	case .RIGHT:
		return .Right, 0, shift
	case .UP:
		return .Up, 0, shift
	case .DOWN:
		return .Down, 0, shift
	case .TAB:
		return .Tab, 0, shift
	case:
	}

	sym := i32(ks.sym)
	if sym >= 'a' && sym <= 'z' {
		c := u8(sym)
		if shift {
			c -= 32
		}
		return .Char, c, shift
	}
	if sym >= '0' && sym <= '9' {
		c := u8(sym)
		if shift {
			if sym == '1' {
				c = '!'
			} else if sym == '2' {
				c = '@'
			} else if sym == '3' {
				c = '#'
			} else if sym == '4' {
				c = '$'
			} else if sym == '5' {
				c = '%'
			} else if sym == '6' {
				c = '^'
			} else if sym == '7' {
				c = '&'
			} else if sym == '8' {
				c = '*'
			} else if sym == '9' {
				c = '('
			} else if sym == '0' {
				c = ')'
			}
		}
		return .Char, c, shift
	}

	#partial switch ks.sym {
	case .SEMICOLON:
		return .Char, ':' if shift else ';', shift
	case .COLON:
		return .Char, ':', shift
	case .LEFTBRACKET:
		return .Char, '[' if !shift else '{', shift
	case .RIGHTBRACKET:
		return .Char, ']' if !shift else '}', shift
	case .MINUS:
		return .Char, '-' if !shift else '_', shift
	case .EQUALS:
		return .Char, '=' if !shift else '+', shift
	case .SLASH:
		return .Char, '/' if !shift else '?', shift
	case .PERIOD:
		return .Char, '.' if !shift else '>', shift
	case .COMMA:
		return .Char, ',' if !shift else '<', shift
	case .QUOTE:
		return .Char, '\'' if !shift else '"', shift
	case .BACKSLASH:
		return .Char, '\\' if !shift else '|', shift
	}
	return .Char, 0, shift
}
