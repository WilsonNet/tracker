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
	forced_scale, scale_ok := ui_scale_from_flags(args, "--ui-scale")
	if !scale_ok {
		return false
	}
	has_forced_scale := false
	if _, ok := flag_value(args, "--ui-scale"); ok {
		has_forced_scale = true
	}

	if sdl.Init(sdl.INIT_VIDEO) != 0 {
		fmt.eprintfln("SDL init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	// Match the existing Hyprland window rule (class `tracker`) so the app opens
	// on the silent special workspace instead of stealing focus.
	sdl.SetHint("SDL_VIDEO_X11_WMCLASS", "tracker")
	sdl.SetHint("SDL_VIDEO_WAYLAND_WMCLASS", "tracker")
	sdl.SetHint("SDL_APP_ID", "tracker")
	sdl.SetHint("SDL_APP_NAME", "tracker")

	// ALLOW_HIGHDPI tells the compositor to hand us a real pixel buffer on
	// 2x/3x displays. Layout stays in window points; the canvas is allocated at
	// pixel density and every primitive is scaled by Canvas.scale.
	window := sdl.CreateWindow(
		"Tracker — Odin",
		80,
		80,
		c.int(width),
		c.int(height),
		sdl.WINDOW_RESIZABLE | sdl.WINDOW_ALLOW_HIGHDPI,
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

	lw, lh, pw, ph: c.int
	sdl.GetWindowSize(window, &lw, &lh)
	sdl.GetWindowSizeInPixels(window, &pw, &ph)
	scale := forced_scale if has_forced_scale else window_scale(lw, lh, pw, ph)
	logical_w := int(lw)
	logical_h := int(lh)

	a: ui.App
	ui.app_init(&a, logical_w, logical_h)
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
	ui.canvas_init(&canvas, ui.canvas_pixel_size(logical_w, scale), ui.canvas_pixel_size(logical_h, scale), scale)
	defer ui.canvas_destroy(&canvas)

	texture := sdl.CreateTexture(renderer, .ARGB8888, .STREAMING, c.int(canvas.width), c.int(canvas.height))
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
			case .KEYUP:
				if .LSHIFT in event.key.keysym.mod || .RSHIFT in event.key.keysym.mod {
					ui.app_set_shift(&a, false)
				}
			case .MOUSEMOTION:
				mx := pointer_to_logical(f32(event.motion.x), lw, f32(canvas.width), canvas.scale)
				my := pointer_to_logical(f32(event.motion.y), lh, f32(canvas.height), canvas.scale)
				ui.app_mouse_move(&a, mx, my)
			case .MOUSEBUTTONDOWN:
				if event.button.button == 1 {
					mx := pointer_to_logical(f32(event.button.x), lw, f32(canvas.width), canvas.scale)
					my := pointer_to_logical(f32(event.button.y), lh, f32(canvas.height), canvas.scale)
					ui.app_mouse_down(&a, mx, my)
				}
			case .MOUSEBUTTONUP:
				if event.button.button == 1 {
					ui.app_mouse_up(&a)
				}
			}
		}

		sdl.GetWindowSize(window, &lw, &lh)
		sdl.GetWindowSizeInPixels(window, &pw, &ph)
		new_scale := forced_scale if has_forced_scale else window_scale(lw, lh, pw, ph)
		pwanted := ui.canvas_pixel_size(int(lw), new_scale)
		phwanted := ui.canvas_pixel_size(int(lh), new_scale)
		if pwanted != canvas.width || phwanted != canvas.height {
			ui.canvas_resize(&canvas, pwanted, phwanted)
			ui.canvas_set_scale(&canvas, new_scale)
			ui.app_resize(&a, int(lw), int(lh))
			sdl.DestroyTexture(texture)
			texture = sdl.CreateTexture(renderer, .ARGB8888, .STREAMING, c.int(canvas.width), c.int(canvas.height))
			if texture == nil {
				fmt.eprintfln("texture resize failed: %s", sdl.GetError())
				return false
			}
		} else if new_scale != canvas.scale {
			ui.canvas_set_scale(&canvas, new_scale)
			ui.app_resize(&a, int(lw), int(lh))
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
				engine_stop_playback(&e)
				if e.rec.active {
					_ = engine_record_stop(&e, &a)
				}
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
		// fmt.tprintf and the layout helpers allocate from the temp arena; a
		// long-running window must reset it every frame or RSS creeps forever.
		free_all(context.temp_allocator)
		time.sleep(6 * time.Millisecond)
	}
	return true
}

@(private)
window_scale :: proc(logical_w, logical_h, pixel_w, pixel_h: c.int) -> f32 {
	if logical_w > 0 && pixel_w > 0 {
		return clamp(f32(pixel_w) / f32(logical_w), 1.0, 3.0)
	}
	return 1.0
}

// SDL2 reports pointer positions in window points. Fold them through the
// canvas pixel space (which is larger than the window when --ui-scale forces a
// supersampled buffer) so the result is the same logical coordinate layout and
// hit-testing use. A backend that reports physical pixels lands on the same
// point through canvas_physical_to_logical.
@(private)
pointer_to_logical :: proc(v: f32, window_points: c.int, canvas_pixels, canvas_scale: f32) -> f32 {
	if window_points <= 0 || canvas_pixels <= 0 || canvas_scale <= 0 {
		return v
	}
	return v * canvas_pixels / f32(window_points) / canvas_scale
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
