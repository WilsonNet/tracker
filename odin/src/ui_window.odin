// Native window: vinland-ui (SDL3 + Vulkan, OpenGL fallback). The element tree
// is built by ui.view_frame from the same App model the headless Cairo harness
// renders; keyboard input goes straight to ui.app_key, so every Vim binding
// behaves exactly like the harness and the unit tests.
//
// Agents: VUI_PORT=7421 ./bin/tracker-odin ui  then  vui-ctl --port 7421 screenshot x.png

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"
import vui "vinland:vui"
import vapp "vinland:vui/app"
import ui "ui"

Window_State :: struct {
	a: ^ui.App,
}

@(private)
TRACKER_ICON_PNG := #load("../assets/tracker.png")

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

	ctx := new(vui.Context)
	defer free(ctx)
	vui.init(ctx)
	defer vui.destroy(ctx)
	view: ui.View
	ui.view_init(&view, ctx)

	va: vapp.App
	cfg := vapp.Config {
		title        = "Tracker",
		size         = {i32(width), i32(height)},
		min_size     = {900, 620},
		scale        = scale,
		app_id       = "tracker", // Hyprland rule: open on the silent special workspace
		control_port = flag_int(args, "--control-port", 0),
		icon_png     = TRACKER_ICON_PNG,
	}
	if !vapp.init(&va, cfg, ctx) {
		return false
	}
	defer vapp.shutdown(&va)
	va.clear_color = vui.oklch(0.07, 0, 0)

	// Machine settings apply only to an implicit session. An explicit
	// `--session` (tests, sandboxes, throwaway takes) stays isolated from the
	// user's saved folder and accessibility choices.
	settings_store := settings_config_path()
	defer delete(settings_store)
	settings: Settings_Doc
	defer settings_destroy(&settings)
	settings_loaded: bool
	_, session_given := flag_value(args, "--session")
	engine_args := args
	augmented: [dynamic]string
	defer delete(augmented)
	if !session_given {
		settings, settings_loaded = settings_load(settings_store)
		if settings.save_dir != "" {
			normalized, valid := normalize_save_dir(settings.save_dir)
			if valid {
				delete(settings.save_dir)
				settings.save_dir = normalized
			} else {
				delete(settings.save_dir)
				settings.save_dir = ""
			}
		}
		if settings.save_dir != "" {
			append(&augmented, ..args)
			append(&augmented, "--session", settings.save_dir)
			engine_args = augmented[:]
		}
	}

	e: Engine
	if !engine_init(&e, engine_args) {
		return false
	}
	defer engine_destroy(&e)

	cloud: Cloud
	cloud_store := cloud_store_path()
	// An explicit session is a sandbox: keep cloud credentials beside the
	// project so e2e/throwaway runs can never overwrite the user's real
	// ~/.config/tracker/cloud.json.
	if session_given {
		delete(cloud_store)
		cloud_store = fmt.aprintf("%s/cloud.json", e.session_dir)
	}
	cloud_init(&cloud, cloud_store)
	delete(cloud_store)
	defer cloud_destroy(&cloud)
	// An explicit session is a sandbox: keep settings beside the takes instead
	// of touching the user's real XDG config. Its own file may carry the
	// accessibility switches, but the explicit folder still wins.
	if session_given {
		delete(settings_store)
		// aprintf, not tprintf: the store string lives for the whole run.
		settings_store = fmt.aprintf("%s/settings.json", e.session_dir)
		settings, settings_loaded = settings_load(settings_store)
	}

	a: ui.App
	ui.app_init(&a, width, height)
	defer ui.app_destroy(&a)
	ui.app_set_save_dir(&a, e.session_dir)
	ui.app_set_settings_path(&a, e.session_dir)

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
			ui.app_set_save_dir(&a, e.session_dir)
			ui.app_mark_settings_dirty(&a)
		}
	} else if os.exists(e.project_path) {
		if project_load_with_takes(&a, e.session_dir, e.project_path, e.takes[:]) {
			engine_match_device(&e, &a, ui.app_device(&a))
			engine_set_latency_ms(&e, a.latency_ms)
			_ = engine_load_tracks(&e, &a)
			ui_sync_takes(&a, &e)
			ui.app_history_reset(&a)
			ui.status_buf_set(&a, "project loaded")
		} else {
			// Preserve an unreadable project.json instead of letting the next
			// save overwrite it, then recover any canonical take files on disk.
			backup := fmt.tprintf("%s.corrupt-%d", e.project_path, os.get_pid())
			renamed := os.rename(e.project_path, backup) == nil
			_ = engine_load_tracks(&e, &a)
			ui_sync_takes(&a, &e)
			ui.app_history_reset(&a)
			if renamed {
				ui.status_buf_set(&a, "project unreadable · original preserved")
			} else {
				ui.status_buf_set(&a, "project unreadable · takes recovered")
			}
			ui.toast(&a, "project file was unreadable")
		}
	} else {
		_ = engine_load_tracks(&e, &a)
		ui_sync_takes(&a, &e)
		ui.status_buf_set(&a, "ready")
	}
	// Machine accessibility choices win over a project's copied flags once the
	// user has a settings file; without one, keep the project's saved values.
	if settings_loaded {
		a.high_contrast = settings.high_contrast
		a.reduced_motion = settings.reduced_motion
		ui.app_set_preroll_seconds(&a, settings.preroll_s)
	}
	engine_set_latency_ms(&e, a.latency_ms)

	a11y_log := has_flag(args, "--a11y-log")
	a11y_revision: u64 = a.state_revision
	last_title: string
	defer delete(last_title)
	window_sync_title(&va, &a, &last_title)
	last := time.now()
	for {
		// vui-ctl keys bypass window_on_event and reach vinland's input, so a
		// synthetic Tab would move vinland focus to a button and a later Enter
		// would click it. Text fields own Tab/Enter/Space; keep vinland focus
		// clear while one is being edited.
		if ui.app_text_editing(&a) {
			vui.focus(0)
		}
		if !vapp.next_frame(&va) {
			break
		}
		window_synthetic_keys(&a, ctx)
		// key events are consumed by window_on_event, so vinland's input.mods
		// never sees modifiers; poll them for fine drags, micro-scrubbing and wheel steps
		mods_now := sdl.GetModState()
		ui.app_set_mods(
			&a,
			mods_now & {.LSHIFT, .RSHIFT} != {},
			mods_now & {.LCTRL, .RCTRL, .LGUI, .RGUI} != {},
			mods_now & {.LALT, .RALT} != {},
		)

		now := time.now()
		dt := f32(time.duration_seconds(time.since(last)))
		last = now
		ui.app_tick(&a, clamp(dt, 0, 0.1))
		window_run_commands(&a, &e, recent_store, &cloud)
		engine_update(&e, &a)
		cloud_sync_ui(&cloud, &a, &e, recent_store)
		ui_sync_takes(&a, &e)
		window_sync_title(&va, &a, &last_title)
		if a11y_log && a.state_revision != a11y_revision {
			a11y_revision = a.state_revision
			fmt.println(ui.app_describe(&a))
		}

		ui.view_frame(&a, &view)
		vapp.end_frame(&va)
		// clicks in the tree emit commands; run them before the next idle wait
		window_run_commands(&a, &e, recent_store, &cloud)
		window_sync_title(&va, &a, &last_title)
		dirty_settings := a.settings_dirty
		if dirty_settings {
			ui_persist_settings(&a, settings_store)
		}
		if ui.view_busy(&a) || len(a.commands) > a.cmd_read || dirty_settings || ui.app_text_editing(&a) {
			vapp.request_redraw(&va)
		}
	}
	// A clean close keeps take selection, comp regions and mix edits. If a take
	// is still open, finalize it first: the old active take is stabilized to its
	// take file before the new canonical WAV is written, so closing mid-record
	// cannot destroy the previous audio.
	if e.rec.active || jack_session_is_running(&e.jack) {
		_ = engine_record_stop(&e, &a)
		ui_sync_takes(&a, &e)
	}
	if !e.rec.active && !jack_session_is_running(&e.jack) {
		_ = window_save_project(&a, &e)
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
		ctrl_down := platform_primary_mod(ev.key.mod)
		alt_down := ev.key.mod & {.LALT, .RALT} != {}
		shift_down := .LSHIFT in ev.key.mod || .RSHIFT in ev.key.mod
		// SDL key events are consumed before vinland sees them, so the app's
		// custom text surfaces handle their own clipboard/selection shortcuts.
		if ui.app_text_editing(ws.a) && (ctrl_down || (shift_down && (ev.key.key == sdl.K_INSERT || ev.key.key == sdl.K_DELETE))) {
			if ev.key.repeat {
				return true
			}
			if shift_down && ev.key.key == sdl.K_INSERT {
				window_clipboard_paste(ws.a)
				return true
			}
			if shift_down && ev.key.key == sdl.K_DELETE {
				window_clipboard_copy(ws.a, va.ctx, true)
				return true
			}
			if ctrl_down && ev.key.key == sdl.K_INSERT {
				window_clipboard_copy(ws.a, va.ctx, false)
				return true
			}
			key, ch, shift := map_key(ev.key.key, ev.key.mod)
			window_edit_shortcut(ws.a, va.ctx, key, ch, shift)
			// Swallow every other Ctrl chord so it cannot type a literal.
			return true
		}
		key, ch, shift := map_key(ev.key.key, ev.key.mod)
		// Allow held key repeat only for Normal-mode tape scrub keys so holding
		// h/l/</> rolls the tape smoothly; other keys stay single-fire.
		scrub_key := ws.a.mode == .Normal && !ui.app_text_editing(ws.a) && key == .Char &&
			(ch == 'h' || ch == 'l' || ch == 'H' || ch == 'L' || ch == '<' || ch == '>')
		if ev.key.repeat && !scrub_key {
			return true
		}
		// Outside text fields, Alt or Ctrl + scrub key enters micro-scrubbing;
		// swallow every other modifier chord so Ctrl+S doesn't solo, Ctrl+R doesn't record.
		// Ctrl/Alt+r records at once (skips the pre-roll); also pass through
		record_now_key := ws.a.mode == .Normal && !ui.app_text_editing(ws.a) && key == .Char && ch == 'r'
		if (ctrl_down || alt_down) && (scrub_key || record_now_key) {
			ui.app_set_mods(ws.a, shift, ctrl_down, alt_down)
			ui.app_key(ws.a, key, ch, shift, true)
			return true
		}
		if ctrl_down || ev.key.mod & {.LALT, .RALT, .LGUI, .RGUI} != {} {
			return true
		}
		ui.app_set_mods(ws.a, shift, ctrl_down, alt_down)
		if key != .Char || ch != 0 {
			window_key(ws.a, key, ch, shift)
		}
		return true
	case .KEY_UP:
		ui.app_set_mods(
			ws.a,
			ev.key.mod & {.LSHIFT, .RSHIFT} != {},
			platform_primary_mod(ev.key.mod),
			ev.key.mod & {.LALT, .RALT} != {},
		)
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

@(private)
window_clipboard_paste :: proc(a: ^ui.App) {
	text := vapp.clipboard_read(context.temp_allocator)
	if text == "" {
		return
	}
	ui.app_paste_text(a, text)
}

@(private)
window_clipboard_copy :: proc(a: ^ui.App, ctx: ^vui.Context, cut: bool) {
	text := ui.app_copy_text(a, cut)
	if text == "" {
		return
	}
	defer delete(text)
	if ctx.clipboard_set != nil {
		ctx.clipboard_set(text)
	}
}

// Standard single-line editing chords. Returns false for a Ctrl chord that is
// not an edit command; the caller still swallows it while a field has focus.
@(private)
window_edit_shortcut :: proc(a: ^ui.App, ctx: ^vui.Context, key: ui.Key, ch: u8, shift: bool) -> bool {
	#partial switch key {
	case .Char:
		switch ch {
		case 'v', 'V':
			window_clipboard_paste(a)
			return true
		case 'a', 'A':
			ui.app_select_all_text(a)
			return true
		case 'c', 'C':
			window_clipboard_copy(a, ctx, false)
			return true
		case 'x', 'X':
			window_clipboard_copy(a, ctx, true)
			return true
		case 'z', 'Z':
			if shift {
				_ = ui.text_redo(a)
			} else {
				_ = ui.text_undo(a)
			}
			return true
		case 'y', 'Y':
			_ = ui.text_redo(a)
			return true
		}
	case .Backspace, .Delete, .Left, .Right, .Home, .End:
		ui.app_key(a, key, ch, shift, true)
		return true
	}
	return false
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
	shift := .Shift in in_.mods
	ctrl := .Ctrl in in_.mods || .Super in in_.mods
	alt := .Alt in in_.mods
	if in_.mods != {} {
		ui.app_set_mods(a, shift, ctrl, alt)
	}
	if ctrl {
		if .V in in_.keys_pressed {
			window_clipboard_paste(a)
		}
		if .A in in_.keys_pressed {
			ui.app_select_all_text(a)
		}
		if .C in in_.keys_pressed {
			window_clipboard_copy(a, ctx, false)
		}
		if .X in in_.keys_pressed {
			window_clipboard_copy(a, ctx, true)
		}
		if .Z in in_.keys_pressed {
			if shift {
				_ = ui.text_redo(a)
			} else {
				_ = ui.text_undo(a)
			}
		}
		if .Y in in_.keys_pressed {
			_ = ui.text_redo(a)
		}
	}
	if !ctrl && !alt {
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
	} else if a.mode == .Normal && !ui.app_text_editing(a) {
		for r in in_.text {
			if r == 'h' || r == 'l' || r == 'H' || r == 'L' || r == '<' || r == '>' {
				ui.app_key(a, .Char, u8(r), shift, true)
			}
		}
	}
	pairs := [?]struct {
		k: vui.Key,
		t: ui.Key,
	}{{.Escape, .Escape}, {.Enter, .Enter}, {.Tab, .Tab}, {.Space, .Space}, {.Backspace, .Backspace}, {.Delete, .Delete}, {.Home, .Home}, {.End, .End}, {.Left, .Left}, {.Right, .Right}, {.Up, .Up}, {.Down, .Down}, {.F1, .F1}}
	for p in pairs {
		if p.k in in_.keys_pressed {
			ui.app_key(a, p.t, ' ' if p.t == .Space else 0, shift, ctrl)
		}
	}
}

@(private)
window_apply_save_dir :: proc(a: ^ui.App, e: ^Engine, dir: string, recent_store: string) -> bool {
	if dir == "" {
		ui.status_buf_set(a, "choose a project folder first")
		ui.toast(a, "choose a project folder first")
		return false
	}
	normalized, valid := normalize_save_dir(dir)
	if !valid {
		ui.status_buf_set(a, "project folder must be an absolute path")
		ui.toast(a, "use an absolute path, e.g. ~/Music/Tracker")
		return false
	}
	defer delete(normalized)
	target := normalized
	if target == e.session_dir {
		ui.app_set_save_dir(a, e.session_dir)
		ui.app_set_settings_path(a, e.session_dir)
		ui.app_mark_settings_dirty(a)
		ui.status_buf_set(a, "project folder unchanged")
		ui.toast(a, "already using this folder")
		return true
	}
	if !engine_apply_save_dir(a, e, target) {
		msg := ui.app_status(a)
		ui.toast(a, msg if msg != "" else "cannot change project folder")
		return false
	}
	ui.app_set_save_dir(a, e.session_dir)
	ui.app_set_settings_path(a, e.session_dir)
	ui.app_mark_settings_dirty(a)
	ui_add_recent(a, e.project_path, recent_store)
	ui.status_buf_set(a, fmt.tprintf("saving to %s", e.session_dir))
	ui.toast(a, "project folder updated")
	return true
}

@(private)
window_sync_title :: proc(va: ^vapp.App, a: ^ui.App, last_title: ^string) {
	if va == nil || va.window == nil || a == nil {
		return
	}
	name := ui.app_project(a)
	desired := "Tracker" if name == "" || name == "untitled" else fmt.tprintf("Tracker — %s", name)
	if desired == last_title^ {
		return
	}
	delete(last_title^)
	last_title^ = strings.clone(desired)
	sdl.SetWindowTitle(va.window, strings.clone_to_cstring(desired, context.temp_allocator))
}

@(private)
window_cloud_commit :: proc(a: ^ui.App, cloud: ^Cloud) -> bool {
	if cloud == nil {
		return false
	}
	ok := cloud_set_client(
		cloud,
		ui.app_cloud_client_id(a),
		ui.app_cloud_client_secret(a),
		ui.app_cloud_folder(a),
	)
	if ok {
		ui.app_cloud_mark_saved(a)
	}
	return ok
}

@(private)
window_run_commands :: proc(a: ^ui.App, e: ^Engine, recent_store: string, cloud: ^Cloud) {
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
			// A finished take changes the take list; persist it now so a crash or
			// a close without an explicit save cannot point project.json at the
			// old canonical file.
			if !e.rec.active {
				_ = window_save_project(a, e)
			}
		case .Bounce:
			if engine_bounce_all(e, a) {
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
			}
		case .Bounce_To_Track:
			ok, msg := engine_bounce_to_track(e, a, cmd.index)
			if ok {
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
			}
			ui.app_tb_finished(a, ok, msg)
		case .Delete_Track:
			ok, msg := engine_delete_track(e, a, cmd.index)
			if ok {
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
			} else {
				a.mode = .Normal
			}
			ui.status_buf_set(a, msg)
			ui.toast(a, msg)
		case .Render_Mix:
			ui.app_render_set_duration(a, engine_mix_duration(e, a))
		case .Render_File:
			path, picked := pick_mix_save(e.session_dir)
			if picked {
				defer delete(path)
				format := Wav_Export_Format.F32
				switch a.render_format {
				case .Wav_F32:
					format = .F32
				case .Wav_PCM24:
					format = .PCM24
				case .Wav_PCM16:
					format = .PCM16
				}
				if render_ok, render_err := engine_render_to_file(e, a, path, a.render_from, a.render_to, format); render_ok {
					ui.app_render_close(a)
					ui.status_buf_set(a, fmt.tprintf("rendered %s", path))
					ui.toast(a, "mix rendered")
				} else {
					ui.status_buf_set(a, render_err)
					ui.toast(a, render_err)
				}
			} else {
				ui.status_buf_set(a, "render cancelled")
			}
		case .Save:
			if window_save_project(a, e) {
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
			if a.jack_backend && !platform_supports_jack() {
				a.jack_backend = false
				ui.status_buf_set(a, fmt.tprintf("JACK is Linux-only (using %s)", platform_audio_backend_name()))
				ui.toast(a, "JACK is Linux-only")
			} else if !engine_set_backend(e, .Jack if a.jack_backend else .Miniaudio) {
				a.jack_backend = !a.jack_backend
				ui.status_buf_set(a, "stop transport before changing capture backend")
				ui.toast(a, "stop transport first")
			} else {
				ui.status_buf_set(a, "JACK capture selected" if a.jack_backend else fmt.tprintf("%s capture selected", platform_audio_backend_name()))
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
				_ = window_save_project(a, e)
			} else {
				ui.status_buf_set(a, "no takes on this track")
			}
		case .Take_Prev:
			if engine_take_cycle(e, a, cmd.index, -1) {
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
			} else {
				ui.status_buf_set(a, "no takes on this track")
			}
		case .Comp_Use:
			if engine_comp_use_active(e, a, cmd.index) {
				_ = engine_take_select(e, a, cmd.index, e.takes[cmd.index].active)
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
				ui_add_recent(a, e.project_path, recent_store)
			} else {
				ui.status_buf_set(a, "no active take to comp")
			}
		case .Comp_Clear:
			if engine_comp_clear(e, a, cmd.index) {
				_ = engine_take_select(e, a, cmd.index, e.takes[cmd.index].active)
				ui_sync_takes(a, e)
				_ = window_save_project(a, e)
			}
		case .Open_Project:
			path, picked := pick_project_open()
			if picked {
				if engine_open_project(a, e, path) {
					ui_sync_takes(a, e)
					ui_add_recent(a, path, recent_store)
					ui.app_set_save_dir(a, e.session_dir)
					ui.app_mark_settings_dirty(a)
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
					ui.app_set_save_dir(a, e.session_dir)
					ui.app_mark_settings_dirty(a)
				}
				delete(path)
			} else {
				ui.status_buf_set(a, "save-as picker cancelled")
			}
		case .Rename_Project:
			// Pure UI state transition; editing starts inline.
		case .Apply_Project_Name:
			if window_save_project(a, e) {
				ui_add_recent(a, e.project_path, recent_store)
			} else {
				ui.status_buf_set(a, "save failed")
				ui.toast(a, "save failed")
			}
		case .Seek:
			engine_seek(e, a)
		case .Settings:
			// The mode transition is pure App state; nothing to do here.
		case .Choose_Save_Dir:
			path, picked := pick_save_dir(ui.app_settings_path(a))
			if picked {
				_ = window_apply_save_dir(a, e, path, recent_store)
				delete(path)
			} else {
				ui.status_buf_set(a, "folder picker cancelled")
			}
		case .Apply_Save_Dir:
			_ = window_apply_save_dir(a, e, ui.app_settings_path(a), recent_store)
		case .Reset_Save_Dir:
			dir := default_session_dir()
			defer delete(dir)
			ui.app_set_settings_path(a, dir)
			_ = window_apply_save_dir(a, e, dir, recent_store)
		case .Cloud_Connect:
			if cloud == nil || !window_cloud_commit(a, cloud) {
				ui.app_cloud_failed(a, "cannot save cloud.json")
			} else if ui.app_cloud_client_id(a) == "" || ui.app_cloud_client_secret(a) == "" {
				ui.app_cloud_failed(a, "Set the Google Client ID and secret first")
			} else if !cloud_start_connect(cloud) {
				ui.app_cloud_failed(a, "a cloud operation is already running")
			}
		case .Cloud_Disconnect:
			if cloud != nil && cloud_is_connected(cloud) {
				if !cloud_start_disconnect(cloud) {
					ui.app_cloud_failed(a, "a cloud operation is already running")
				}
			}
		case .Cloud_List:
			_ = window_cloud_commit(a, cloud)
			if cloud == nil || !cloud_is_connected(cloud) {
				ui.app_cloud_failed(a, "Connect Google Drive first")
			} else if !cloud_start_list(cloud) {
				ui.app_cloud_failed(a, "a cloud operation is already running")
			}
		case .Cloud_Save_Credentials:
			if cloud == nil || !cloud_set_client(cloud, ui.app_cloud_client_id(a), ui.app_cloud_client_secret(a), ui.app_cloud_folder(a)) {
				ui.app_cloud_failed(a, "cannot save cloud.json")
			} else {
				ui.app_cloud_mark_saved(a)
				ui.app_cloud_status_set(a, "Google credentials saved", "")
				ui.status_buf_set(a, "Google credentials saved")
			}
		case .Cloud_Backup:
			_ = window_cloud_commit(a, cloud)
			if cloud == nil || !cloud_is_connected(cloud) {
				ui.app_cloud_failed(a, "Connect Google Drive first")
			} else if a.transport != .Stopped || e.rec.active || e.play.active {
				ui.app_cloud_failed(a, "stop transport before backing up")
			} else if !project_save_with_takes(a, e.takes[:], e.project_path) {
				ui.app_cloud_failed(a, "cannot save the project before backup")
			} else {
				take_names: [dynamic]string
				defer {
					for name in take_names {
						delete(name)
					}
					delete(take_names)
				}
				for list in e.takes {
					for take in list.takes {
						if take.file != "" {
							append(&take_names, fmt.aprintf("%s", take.file))
						}
					}
				}
				if !cloud_start_backup(cloud, e.session_dir, ui.app_project(a), take_names[:]) {
					ui.app_cloud_failed(a, "a cloud operation is already running")
				} else {
					ui.status_buf_set(a, "backing up to Google Drive")
				}
			}
		case .Cloud_Restore:
			id := ui.app_cloud_selected_id(a)
			_ = window_cloud_commit(a, cloud)
			if cloud == nil || !cloud_is_connected(cloud) {
				ui.app_cloud_failed(a, "Connect Google Drive first")
			} else if id == "" {
				ui.app_cloud_failed(a, "no cloud project selected")
			} else if a.transport != .Stopped || e.rec.active || e.play.active {
				ui.app_cloud_failed(a, "stop transport before restoring")
			} else {
				root := parent_dir(e.session_dir)
				if !cloud_start_restore(cloud, id, root) {
					ui.app_cloud_failed(a, "a cloud operation is already running")
				} else {
					ui.status_buf_set(a, "restoring from Google Drive")
				}
			}
		case .Open_Recent:
			path := ui.app_recent_target(a)
			if path != "" && engine_open_project(a, e, path) {
				ui_sync_takes(a, e)
				ui_add_recent(a, path, recent_store)
				ui.app_set_save_dir(a, e.session_dir)
				ui.app_mark_settings_dirty(a)
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
	case sdl.K_DELETE:
		return .Delete, 0, shift
	case sdl.K_HOME:
		return .Home, 0, shift
	case sdl.K_END:
		return .End, 0, shift
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
	case sdl.K_F1:
		return .F1, 0, shift
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
