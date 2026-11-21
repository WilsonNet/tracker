// Native window: vinland-ui (SDL3 + Vulkan, OpenGL fallback). The element tree
// is built by ui.view_frame from the same App model the headless Cairo harness
// renders; keyboard input goes straight to ui.app_key, so every Vim binding
// behaves exactly like the harness and the unit tests.
//
// Agents: VUI_PORT=7421 ./bin/tracker-odin ui  then  vui-ctl --port 7421 screenshot x.png

package main

import "core:fmt"
import "core:os"
import "core:time"

import sdl "vendor:sdl3"
import vui "vinland:vui"
import vapp "vinland:vui/app"
import ui "ui"

Window_State :: struct {
	a: ^ui.App,
}

run_ui_window :: proc(args: []string) -> bool {
	width := flag_int(args, "--width", 1180)
	height := flag_int(args, "--height", 760)
	forced_scale, scale_ok := ui_scale_from_flags(args, "--ui-scale")
	if !scale_ok {
		return false
	}
	scale: f32 = 0
	if _, ok := flag_value(args, "--ui-scale"); ok {
		scale = forced_scale
	}

	ctx: vui.Context
	vui.init(&ctx)
	defer vui.destroy(&ctx)
	view: ui.View
	ui.view_init(&view, &ctx)

	va: vapp.App
	cfg := vapp.Config {
		title        = "Tracker",
		size         = {i32(width), i32(height)},
		min_size     = {900, 620},
		scale        = scale,
		app_id       = "tracker", // Hyprland rule: open on the silent special workspace
		control_port = flag_int(args, "--control-port", 0),
	}
	if !vapp.init(&va, cfg, &ctx) {
		return false
	}
	defer vapp.shutdown(&va)
	va.clear_color = vui.oklch(0.07, 0, 0)

	e: Engine
	if !engine_init(&e, args) {
		return false
	}
	defer engine_destroy(&e)

	a: ui.App
	ui.app_init(&a, width, height)
	defer ui.app_destroy(&a)

	ws := Window_State{&a}
	va.user_data = &ws
	va.on_event = window_on_event

	names := engine_device_names()
	default_idx := engine_default_device()
	ui.app_set_devices(&a, names, default_idx)
	for name in names {
		delete(name)
	}
	delete(names)
	e.device_index = default_idx
	a.demo = has_flag(args, "--demo")
	a.latency_ms = clamp(flag_f32(args, "--latency-ms", a.latency_ms), 0, 10_000)
	if has_flag(args, "--jack") {
		e.backend = .Jack
		a.jack_backend = true
	}

	recent_store := recent_config_path()
	defer delete(recent_store)
	ui_load_recent(&a, recent_store)

	open_path, has_open := flag_value(args, "--open")
	if has_open && open_path != "" {
		if engine_open_project(&a, &e, open_path) {
			ui_sync_takes(&a, &e)
			ui_add_recent(&a, open_path, recent_store)
		}
	} else if os.exists(e.project_path) {
		if project_load_with_takes(&a, e.session_dir, e.project_path, e.takes[:]) {
			engine_match_device(&e, &a, ui.app_device(&a))
			engine_set_latency_ms(&e, a.latency_ms)
			_ = engine_load_tracks(&e, &a)
			ui_sync_takes(&a, &e)
			ui.app_history_reset(&a)
			ui.status_buf_set(&a, "project loaded")
		}
	} else {
		_ = engine_load_tracks(&e, &a)
		ui_sync_takes(&a, &e)
		ui.status_buf_set(&a, "ready")
	}
	engine_set_latency_ms(&e, a.latency_ms)

	a11y_log := has_flag(args, "--a11y-log")
	a11y_revision: u64 = a.state_revision
	last := time.now()
	for vapp.next_frame(&va) {
		window_synthetic_keys(&a, &ctx)
		// key events are consumed by window_on_event, so vinland's input.mods
		// never sees Shift; poll it for fine knob drags and wheel steps
		ui.app_set_shift(&a, sdl.GetModState() & {.LSHIFT, .RSHIFT} != {})

		now := time.now()
		dt := f32(time.duration_seconds(time.since(last)))
		last = now
		ui.app_tick(&a, clamp(dt, 0, 0.1))
		window_run_commands(&a, &e, recent_store)
		engine_update(&e, &a)
		ui_sync_takes(&a, &e)
		if a11y_log && a.state_revision != a11y_revision {
			a11y_revision = a.state_revision
			fmt.println(ui.app_describe(&a))
		}

		ui.view_frame(&a, &view)
		vapp.end_frame(&va)
		// clicks in the tree emit commands; run them before the next idle wait
		window_run_commands(&a, &e, recent_store)
		if ui.view_busy(&a) || len(a.commands) > a.cmd_read {
			vapp.request_redraw(&va)
		}
	}
	return true
}

// Raw keyboard goes to the App's Vim keymap (consumed so vinland focus
// traversal never sees Tab/Space twice).
@(private)
window_on_event :: proc(va: ^vapp.App, ev: ^sdl.Event) -> bool {
	ws := (^Window_State)(va.user_data)
	#partial switch ev.type {
	case .KEY_DOWN, .KEY_UP:
		// consuming the key hides it from vinland, including its modifier
		// state; keep input.mods current so Shift+wheel pans scroll areas
		window_sync_mods(va, ev.key.mod)
	}
	#partial switch ev.type {
	case .KEY_DOWN:
		vapp.request_redraw(va)
		if ev.key.repeat {
			return true
		}
		key, ch, shift := map_key(ev.key.key, ev.key.mod)
		ui.app_set_shift(ws.a, shift)
		if key != .Char || ch != 0 {
			window_key(ws.a, key, ch, shift)
		}
		return true
	case .KEY_UP:
		if .LSHIFT not_in ev.key.mod && .RSHIFT not_in ev.key.mod {
			ui.app_set_shift(ws.a, false)
		}
		return true
	case .TEXT_INPUT:
		// keys already reached app_key above; if anything turns SDL text
		// input on, the same keystroke must not run twice via input.text
		return true
	}
	return false
}

@(private)
window_sync_mods :: proc(va: ^vapp.App, m: sdl.Keymod) {
	mods: vui.Mods
	if m & {.LSHIFT, .RSHIFT} != {} {
		mods += {.Shift}
	}
	if m & {.LCTRL, .RCTRL} != {} {
		mods += {.Ctrl}
	}
	if m & {.LALT, .RALT} != {} {
		mods += {.Alt}
	}
	if m & {.LGUI, .RGUI} != {} {
		mods += {.Super}
	}
	va.input.mods = mods
}

// Vim h/l adjust the focused FX rack control (the status line advertises
// "h/l: adjust"); H/L are the fine variants, like Shift+arrows.
@(private)
window_key :: proc(a: ^ui.App, key: ui.Key, ch: u8, shift: bool) {
	if key == .Char && a.mode == .Fx {
		switch ch {
		case 'h', 'H':
			ui.app_key(a, .Left, 0, ch == 'H')
			return
		case 'l', 'L':
			ui.app_key(a, .Right, 0, ch == 'L')
			return
		}
	}
	ui.app_key(a, key, ch, shift)
}

// vui-ctl `type` / `key` arrive as vinland synthetic input.
@(private)
window_synthetic_keys :: proc(a: ^ui.App, ctx: ^vui.Context) {
	in_ := &ctx.input
	for r in in_.text {
		if r < 128 {
			if r == ' ' {
				// SDL reports Space as a key, never as a Char; mirror that so
				// `vui-ctl type " "` toggles play like the real keyboard
				window_key(a, .Space, ' ', false)
			} else {
				window_key(a, .Char, u8(r), r >= 'A' && r <= 'Z')
			}
		}
	}
	shift := .Shift in in_.mods
	pairs := [?]struct {
		k: vui.Key,
		t: ui.Key,
	}{{.Escape, .Escape}, {.Enter, .Enter}, {.Tab, .Tab}, {.Space, .Space}, {.Backspace, .Backspace}, {.Left, .Left}, {.Right, .Right}, {.Up, .Up}, {.Down, .Down}}
	for p in pairs {
		if p.k in in_.keys_pressed {
			ui.app_key(a, p.t, ' ' if p.t == .Space else 0, shift)
		}
	}
}

@(private)
window_run_commands :: proc(a: ^ui.App, e: ^Engine, recent_store: string) {
	for {
		cmd, has := ui.app_take_command(a)
		if !has {
			break
		}
		#partial switch cmd.kind {
		case .Play:
			if !engine_play(e, a) {
				ui.app_force_stopped(a, "nothing to play")
			}
		case .Stop:
			engine_stop_playback(e)
			if e.rec.active || jack_session_is_running(&e.jack) {
				_ = engine_record_stop(e, a)
			}
		case .Record_Start:
			if !engine_record_start(e, a) {
				ui.app_force_stopped(a, ui.app_status(a))
			}
		case .Record_Stop:
			_ = engine_record_stop(e, a)
			ui_sync_takes(a, e)
		case .Bounce:
			_ = engine_bounce(e, a)
		case .Save:
			if project_save_with_takes(a, e.takes[:], e.project_path) {
				ui.status_buf_set(a, "project saved")
				ui_add_recent(a, e.project_path, recent_store)
			} else {
				ui.status_buf_set(a, "save failed")
				ui.toast(a, "save failed")
			}
		case .Load:
			engine_stop_playback(e)
			if e.rec.active {
				_ = engine_record_stop(e, a)
			}
			if project_load_with_takes(a, e.session_dir, e.project_path, e.takes[:]) {
				_ = engine_load_tracks(e, a)
				engine_match_device(e, a, ui.app_device(a))
				engine_set_latency_ms(e, a.latency_ms)
				ui_sync_takes(a, e)
				ui.app_history_reset(a)
				ui.status_buf_set(a, "project loaded")
			} else {
				ui.status_buf_set(a, "load failed")
				ui.toast(a, "load failed")
			}
		case .Select_Device:
			engine_set_device(e, a, cmd.index)
		case .Monitor:
			if a.monitor {
				_ = engine_monitor_start(e, a)
			} else {
				_ = engine_monitor_stop(e, a)
			}
		case .Latency_Up, .Latency_Down:
			engine_set_latency_ms(e, a.latency_ms)
		case .Backend:
			if !engine_set_backend(e, .Jack if a.jack_backend else .Miniaudio) {
				a.jack_backend = !a.jack_backend
				ui.status_buf_set(a, "stop transport before changing capture backend")
				ui.toast(a, "stop transport first")
			} else {
				ui.status_buf_set(a, "JACK capture selected" if a.jack_backend else "PipeWire capture selected")
			}
		case .Rescan:
			names2 := engine_rescan_devices(e, a)
			ui.app_set_devices(a, names2, max(e.device_index, 0))
			for name in names2 {
				delete(name)
			}
			delete(names2)
			ui.status_buf_set(a, "devices rescanned")
		case .Take_Next:
			if engine_take_cycle(e, a, cmd.index, 1) {
				ui_sync_takes(a, e)
			} else {
				ui.status_buf_set(a, "no takes on this track")
			}
		case .Take_Prev:
			if engine_take_cycle(e, a, cmd.index, -1) {
				ui_sync_takes(a, e)
			} else {
				ui.status_buf_set(a, "no takes on this track")
			}
		case .Comp_Use:
			if engine_comp_use_active(e, a, cmd.index) {
				_ = engine_take_select(e, a, cmd.index, e.takes[cmd.index].active)
				ui_sync_takes(a, e)
				_ = project_save_with_takes(a, e.takes[:], e.project_path)
				ui_add_recent(a, e.project_path, recent_store)
			} else {
				ui.status_buf_set(a, "no active take to comp")
			}
		case .Comp_Clear:
			_ = engine_comp_clear(e, a, cmd.index)
			_ = engine_take_select(e, a, cmd.index, e.takes[cmd.index].active)
			ui_sync_takes(a, e)
			_ = project_save_with_takes(a, e.takes[:], e.project_path)
		case .Open_Project:
			path, picked := pick_project_open()
			if picked {
				if engine_open_project(a, e, path) {
					ui_sync_takes(a, e)
					ui_add_recent(a, path, recent_store)
				}
				delete(path)
			} else {
				ui.status_buf_set(a, "project picker cancelled")
			}
		case .Save_As:
			path, picked := pick_project_save()
			if picked {
				if engine_save_as_to(a, e, path) {
					ui_add_recent(a, path, recent_store)
				}
				delete(path)
			} else {
				ui.status_buf_set(a, "save-as picker cancelled")
			}
		case .Open_Recent:
			path := ui.app_recent_target(a)
			if path != "" && engine_open_project(a, e, path) {
				ui_sync_takes(a, e)
				ui_add_recent(a, path, recent_store)
			}
		case:
		}
	}
}

@(private)
map_key :: proc(k: sdl.Keycode, mod: sdl.Keymod) -> (key: ui.Key, ch: u8, shift: bool) {
	shift = .LSHIFT in mod || .RSHIFT in mod
	switch k {
	case sdl.K_SPACE:
		return .Space, ' ', shift
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		return .Enter, 0, shift
	case sdl.K_ESCAPE:
		return .Escape, 0, shift
	case sdl.K_BACKSPACE:
		return .Backspace, 0, shift
	case sdl.K_LEFT:
		return .Left, 0, shift
	case sdl.K_RIGHT:
		return .Right, 0, shift
	case sdl.K_UP:
		return .Up, 0, shift
	case sdl.K_DOWN:
		return .Down, 0, shift
	case sdl.K_TAB:
		return .Tab, 0, shift
	}
	sym := u32(k)
	if sym >= 'a' && sym <= 'z' {
		c := u8(sym)
		if shift {
			c -= 32
		}
		return .Char, c, shift
	}
	if sym >= '0' && sym <= '9' {
		SHIFTED := ")!@#$%^&*("
		c := u8(sym)
		if shift {
			c = SHIFTED[c - '0']
		}
		return .Char, c, shift
	}
	pairs := [?][3]u8{{';', ';', ':'}, {':', ':', ':'}, {'[', '[', '{'}, {']', ']', '}'}, {'-', '-', '_'}, {'=', '=', '+'}, {'/', '/', '?'}, {'.', '.', '>'}, {',', ',', '<'}, {'\'', '\'', '"'}, {'\\', '\\', '|'}}
	for p in pairs {
		if sym == u32(p[0]) {
			return .Char, p[2] if shift else p[1], shift
		}
	}
	return .Char, 0, shift
}
