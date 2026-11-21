// Pointer and keyboard input, command palette, semantic test targets and
// assertion paths. Everything here is pure state: no OS calls.

package ui

import "core:fmt"
import "core:strings"

Palette_Command :: struct {
	name: string,
	kind: Command_Kind,
}

PALETTE_COMMANDS := [?]Palette_Command{
	{"record", .Record_Start},
	{"play", .Play},
	{"stop", .Stop},
	{"bounce", .Bounce},
	{"fx rack", .Fx},
	{"io panel", .Io},
	{"settings", .Settings},
	{"save project", .Save},
	{"load project", .Load},
	{"arm all", .Arm_All},
	{"clear arms", .Clear_Arms},
	{"panic", .Panic},
	{"metronome", .Metronome},
	{"tempo up", .Bpm_Up},
	{"tempo down", .Bpm_Down},
	{"undo", .Undo},
	{"redo", .Redo},
	{"open project", .Open_Project},
	{"save project as", .Save_As},
	{"recent projects", .Recent},
	{"high contrast", .High_Contrast},
	{"reduced motion", .Reduced_Motion},
	{"monitor", .Monitor},
	{"jack capture", .Backend},
	{"rescan devices", .Rescan},
	{"latency up", .Latency_Up},
	{"latency down", .Latency_Down},
	{"next take", .Take_Next},
	{"previous take", .Take_Prev},
	{"comp active take", .Comp_Use},
	{"clear comp", .Comp_Clear},
}

// Longest query that still fits the palette input without clipping.
PALETTE_QUERY_MAX :: 44

@(private)
prefix_ci :: proc(s, p: string) -> bool {
	if len(p) > len(s) {
		return false
	}
	for i in 0 ..< len(p) {
		a := s[i]
		b := p[i]
		if a >= 'A' && a <= 'Z' {
			a += 32
		}
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		if a != b {
			return false
		}
	}
	return true
}

@(private)
module_name :: proc(m: Fx_Module) -> string {
	switch m {
	case .EQ:
		return "eq"
	case .COMP:
		return "comp"
	case .SEND:
		return "send"
	case .REVERB:
		return "reverb"
	case .DELAY:
		return "delay"
	case .WIDTH:
		return "width"
	case .LIMITER:
		return "limiter"
	}
	return "?"
}

@(private)
param_name :: proc(m: Fx_Module, p: int) -> string {
	switch m {
	case .EQ:
		switch p {
		case 0:
			return "low"
		case 1:
			return "mid"
		case 2:
			return "mid_hz"
		case 3:
			return "mid_q"
		case 4:
			return "high"
		}
	case .COMP:
		switch p {
		case 0:
			return "threshold"
		case 1:
			return "ratio"
		case 2:
			return "attack"
		case 3:
			return "release"
		case 4:
			return "knee"
		}
	case .SEND:
		return "reverb" if p == 0 else "delay"
	case .REVERB:
		switch p {
		case 0:
			return "size"
		case 1:
			return "decay"
		case 2:
			return "tone"
		case 3:
			return "predelay"
		case 4:
			return "return"
		}
	case .DELAY:
		switch p {
		case 0:
			return "time"
		case 1:
			return "feedback"
		case 2:
			return "tone"
		case 3:
			return "return"
		}
	case .WIDTH:
		return "width" if p == 0 else "bass"
	case .LIMITER:
		switch p {
		case 0:
			return "ceiling"
		case 1:
			return "release"
		case 2:
			return "lookahead"
		}
	}
	return "?"
}

@(private)
toggle_name :: proc(t: Toggle_Target) -> string {
	if t.param == 1 {
		return "fx.pingpong.delay"
	}
	return fmt.tprintf("fx.bypass.%s", module_name(t.module))
}

app_knob_name :: proc(t: Knob_Target) -> string {
	return fmt.tprintf("knob.%s.%s", module_name(t.module), param_name(t.module, t.param))
}

@(private)
knob_spec :: proc(m: Fx_Module, p: int) -> (lo, hi: f32, log: bool) {
	switch m {
	case .EQ:
		switch p {
		case 2:
			return 150, 8_000, true
		case 3:
			return 0.3, 8, true
		case:
			return -18, 18, false
		}
	case .COMP:
		switch p {
		case 0:
			return -60, 0, false
		case 1:
			return 1, 20, true
		case 2:
			return 0.1, 300, true
		case 3:
			return 5, 2_000, true
		case 4:
			return 0, 24, false
		}
	case .SEND:
		return 0, 1, false
	case .REVERB:
		switch p {
		case 3:
			return 0, 200, false
		case:
			return 0, 1, false
		}
	case .DELAY:
		switch p {
		case 0:
			return 1, 2_000, true
		case 1:
			return 0, 0.9, false
		case:
			return 0, 1, false
		}
	case .WIDTH:
		if p == 0 {
			return 0, 2, false
		}
		return 40, 400, false
	case .LIMITER:
		switch p {
		case 0:
			return -12, 0, false
		case 1:
			return 10, 1_000, true
		case 2:
			return 0.5, 20, true
		}
	}
	return 0, 1, false
}

// Factory defaults for double-click / keyboard reset. Master and track
// compressors intentionally have different defaults, matching app_init.
knob_default :: proc(a: ^App, t: Knob_Target) -> f32 {
	master := a.fx_channel >= MAX_TRACKS
	#partial switch t.module {
	case .EQ:
		switch t.param {
		case 2:
			return 1_000
		case 3:
			return 1
		case:
			return 0
		}
	case .COMP:
		switch t.param {
		case 0:
			return -14 if master else -18
		case 1:
			return 2.5 if master else 3
		case 2:
			return 20 if master else 12
		case 3:
			return 250 if master else 180
		case 4:
			return 10 if master else 8
		}
	case .SEND:
		return 0
	case .REVERB:
		switch t.param {
		case 0:
			return 0.62
		case 1:
			return 0.55
		case 2:
			return 0.55
		case 3:
			return 18
		case 4:
			return 0.45
		}
	case .DELAY:
		switch t.param {
		case 0:
			return 320
		case 1:
			return 0.35
		case 2:
			return 0.55
		case 3:
			return 0.35
		}
	case .WIDTH:
		return 1 if t.param == 0 else 140
	case .LIMITER:
		switch t.param {
		case 0:
			return -0.3
		case 1:
			return 120
		case 2:
			return 5
		}
	}
	return 0
}

app_knob_reset :: proc(a: ^App, t: Knob_Target) {
	app_set_knob(a, t, knob_default(a, t))
}

app_knob_value :: proc(a: ^App, t: Knob_Target) -> f32 {
	if a.fx_channel >= MAX_TRACKS {
		#partial switch t.module {
		case .COMP:
			c := a.master.comp
			switch t.param {
			case 0:
				return c.threshold_db
			case 1:
				return c.ratio
			case 2:
				return c.attack_ms
			case 3:
				return c.release_ms
			case 4:
				return c.knee_db
			}
		case .REVERB:
			r := a.master.reverb
			switch t.param {
			case 0:
				return r.size
			case 1:
				return r.decay
			case 2:
				return r.tone
			case 3:
				return r.predelay_ms
			case 4:
				return r.return_level
			}
		case .DELAY:
			d := a.master.delay
			switch t.param {
			case 0:
				return d.time_ms
			case 1:
				return d.feedback
			case 2:
				return d.tone
			case 3:
				return d.return_level
			}
		case .WIDTH:
			return a.master.width.width if t.param == 0 else a.master.width.bass_hz
		case .LIMITER:
			l := a.master.limiter
			switch t.param {
			case 0:
				return l.ceiling_db
			case 1:
				return l.release_ms
			case 2:
				return l.lookahead_ms
			}
		case:
		}
		return 0
	}

	track := &a.tracks[a.fx_channel]
	#partial switch t.module {
	case .EQ:
		switch t.param {
		case 0:
			return track.eq.low_db
		case 1:
			return track.eq.mid_db
		case 2:
			return track.eq.mid_hz
		case 3:
			return track.eq.mid_q
		case 4:
			return track.eq.high_db
		}
	case .COMP:
		switch t.param {
		case 0:
			return track.comp.threshold_db
		case 1:
			return track.comp.ratio
		case 2:
			return track.comp.attack_ms
		case 3:
			return track.comp.release_ms
		case 4:
			return track.comp.knee_db
		}
	case .SEND:
		return track.send_reverb if t.param == 0 else track.send_delay
	case:
	}
	return 0
}

app_set_knob :: proc(a: ^App, t: Knob_Target, value: f32) {
	lo, hi, log := knob_spec(t.module, t.param)
	v := clamp(value, lo, hi)
	app_history_note(a, "knob")
	app_touch(a)

	if a.fx_channel >= MAX_TRACKS {
		#partial switch t.module {
		case .COMP:
			c := &a.master.comp
			switch t.param {
			case 0:
				c.threshold_db = v
			case 1:
				c.ratio = v
			case 2:
				c.attack_ms = v
			case 3:
				c.release_ms = v
			case 4:
				c.knee_db = v
			}
		case .REVERB:
			r := &a.master.reverb
			switch t.param {
			case 0:
				r.size = v
			case 1:
				r.decay = v
			case 2:
				r.tone = v
			case 3:
				r.predelay_ms = v
			case 4:
				r.return_level = v
			}
		case .DELAY:
			d := &a.master.delay
			switch t.param {
			case 0:
				d.time_ms = v
			case 1:
				d.feedback = v
			case 2:
				d.tone = v
			case 3:
				d.return_level = v
			}
		case .WIDTH:
			if t.param == 0 {
				a.master.width.width = v
			} else {
				a.master.width.bass_hz = v
			}
		case .LIMITER:
			l := &a.master.limiter
			switch t.param {
			case 0:
				l.ceiling_db = v
			case 1:
				l.release_ms = v
			case 2:
				l.lookahead_ms = v
			}
		case:
		}
		return
	}

	track := &a.tracks[a.fx_channel]
	#partial switch t.module {
	case .EQ:
		switch t.param {
		case 0:
			track.eq.low_db = v
		case 1:
			track.eq.mid_db = v
		case 2:
			track.eq.mid_hz = v
		case 3:
			track.eq.mid_q = v
		case 4:
			track.eq.high_db = v
		}
	case .COMP:
		switch t.param {
		case 0:
			track.comp.threshold_db = v
		case 1:
			track.comp.ratio = v
		case 2:
			track.comp.attack_ms = v
		case 3:
			track.comp.release_ms = v
		case 4:
			track.comp.knee_db = v
		}
	case .SEND:
		if t.param == 0 {
			track.send_reverb = v
		} else {
			track.send_delay = v
		}
	case:
	}
	_ = log
}

// Whether a module is actively processing. Knobs and toggles dim when the
// module is bypassed, but stay reachable so they can be re-enabled.
bypass_state :: proc(a: ^App, m: Fx_Module) -> bool {
	if a.fx_channel >= MAX_TRACKS {
		#partial switch m {
		case .COMP:
			return a.master.comp.enabled
		case .REVERB:
			return a.master.reverb.enabled
		case .DELAY:
			return a.master.delay.enabled
		case .WIDTH:
			return a.master.width.enabled
		case .LIMITER:
			return a.master.limiter.enabled
		case:
			return true
		}
	}
	#partial switch m {
	case .EQ:
		return a.tracks[a.fx_channel].eq.enabled
	case .COMP:
		return a.tracks[a.fx_channel].comp.enabled
	case .SEND:
		return true
	case:
		return true
	}
}

app_toggle_value :: proc(a: ^App, t: Toggle_Target) -> bool {
	if t.module == .DELAY && t.param == 1 {
		return a.master.delay.ping_pong
	}
	// Bypass switches are exposed as "is bypassed" so a target named
	// fx.bypass.<module> reads true when the module is off.
	if a.fx_channel >= MAX_TRACKS {
		#partial switch t.module {
		case .COMP:
			return !a.master.comp.enabled
		case .REVERB:
			return !a.master.reverb.enabled
		case .DELAY:
			return !a.master.delay.enabled
		case .WIDTH:
			return !a.master.width.enabled
		case .LIMITER:
			return !a.master.limiter.enabled
		case:
			return true
		}
	}
	track := &a.tracks[a.fx_channel]
	#partial switch t.module {
	case .EQ:
		return !track.eq.enabled
	case .COMP:
		return !track.comp.enabled
	case .SEND:
		return !(track.send_reverb > 0 || track.send_delay > 0)
	case:
		return true
	}
}

// Visual "lit" state for a toggle: bypass switches are lit when the module is
// enabled, ping-pong when it is active.
@(private)
toggle_lit :: proc(a: ^App, t: Toggle_Target) -> bool {
	v := app_toggle_value(a, t)
	return v if t.param == 1 else !v
}

app_flip_toggle :: proc(a: ^App, t: Toggle_Target) {
	app_history_note(a, "fx")
	app_touch(a)
	if t.module == .DELAY && t.param == 1 {
		a.master.delay.ping_pong = !a.master.delay.ping_pong
		return
	}
	if a.fx_channel >= MAX_TRACKS {
		#partial switch t.module {
		case .COMP:
			a.master.comp.enabled = !a.master.comp.enabled
		case .REVERB:
			a.master.reverb.enabled = !a.master.reverb.enabled
		case .DELAY:
			a.master.delay.enabled = !a.master.delay.enabled
		case .WIDTH:
			a.master.width.enabled = !a.master.width.enabled
		case .LIMITER:
			a.master.limiter.enabled = !a.master.limiter.enabled
		case:
		}
		return
	}
	track := &a.tracks[a.fx_channel]
	#partial switch t.module {
	case .EQ:
		track.eq.enabled = !track.eq.enabled
	case .COMP:
		track.comp.enabled = !track.comp.enabled
	case .SEND:
	}
}

// ---------------------------------------------------------------- palette

app_palette_rebuild :: proc(a: ^App) {
	a.palette_count = 0
	query := string(a.palette_buf[:a.palette_len])
	for cmd, i in PALETTE_COMMANDS {
		if prefix_ci(cmd.name, query) {
			if a.palette_count < MAX_PALETTE {
				a.palette_items[a.palette_count] = i
				a.palette_count += 1
			}
		}
	}
	// A changed query invalidates the old selection position. Reset to the
	// first match so Enter can never run an item that scrolled out of view.
	a.palette_sel = 0
	a.palette_scroll = 0
	app_layout(a)
}

app_palette_execute :: proc(a: ^App) {
	if a.palette_count == 0 {
		status_buf_set(a, "no matching command")
		return
	}
	idx := a.palette_items[a.palette_sel]
	cmd := PALETTE_COMMANDS[idx]
	a.mode = .Normal
	status_buf_set(a, fmt.tprintf(": %s", cmd.name))
	// The palette entries are toggles for the two transport actions, exactly
	// like their keys; otherwise "record" while recording would dish a new take.
	if cmd.kind == .Record_Start && a.transport == .Recording {
		app_execute(a, .Record_Stop)
		return
	}
	if cmd.kind == .Play && a.transport == .Playing {
		app_execute(a, .Stop)
		return
	}
	app_execute(a, cmd.kind)
	app_history_commit(a)
}

@(private)
app_palette_key :: proc(a: ^App, key: Key, ch: u8) -> bool {
	#partial switch key {
	case .Escape:
		a.mode = .Normal
		return true
	case .Enter:
		app_palette_execute(a)
		return true
	case .Backspace:
		if a.palette_len > 0 {
			a.palette_len -= 1
			app_palette_rebuild(a)
		}
		return true
	case .Up:
		a.palette_sel = max(a.palette_sel - 1, 0)
		return true
	case .Down:
		a.palette_sel = min(a.palette_sel + 1, max(a.palette_count - 1, 0))
		return true
	case .Char:
		if ch >= 32 && ch <= 126 && a.palette_len < PALETTE_QUERY_MAX {
			a.palette_buf[a.palette_len] = ch
			a.palette_len += 1
			app_palette_rebuild(a)
			return true
		}
	case .Space:
		if a.palette_len < PALETTE_QUERY_MAX {
			a.palette_buf[a.palette_len] = ' '
			a.palette_len += 1
			app_palette_rebuild(a)
			return true
		}
	case:
	}
	return false
}

@(private)
app_recent_key :: proc(a: ^App, key: Key, ch: u8) -> bool {
	#partial switch key {
	case .Escape:
		a.mode = .Normal
		status_buf_set(a, "recent projects closed")
		bump_revision(a)
	case .Enter:
		app_recent_choose(a)
	case .Backspace:
		if a.recent_query_len > 0 {
			a.recent_query_len -= 1
			app_recent_rebuild(a)
		}
	case .Up:
		a.recent_sel = max(a.recent_sel - 1, 0)
	case .Down:
		a.recent_sel = min(a.recent_sel + 1, max(a.recent_filtered - 1, 0))
	case .Char:
		if ch >= 32 && ch <= 126 && a.recent_query_len < RECENT_QUERY_MAX {
			a.recent_query_buf[a.recent_query_len] = ch
			a.recent_query_len += 1
			app_recent_rebuild(a)
		}
	case .Space:
		if a.recent_query_len < RECENT_QUERY_MAX {
			a.recent_query_buf[a.recent_query_len] = ' '
			a.recent_query_len += 1
			app_recent_rebuild(a)
		}
	case:
	}
	return true
}

@(private)
app_settings_activate :: proc(a: ^App) {
	switch a.settings_sel {
	case .Path:
		app_settings_begin_edit(a)
	case .Browse:
		app_execute(a, .Choose_Save_Dir)
	case .Apply:
		app_execute(a, .Apply_Save_Dir)
	case .Default:
		app_execute(a, .Reset_Save_Dir)
	case .Inputs:
		app_execute(a, .Io)
	case .Backend:
		app_execute(a, .Backend)
	case .Latency_Down:
		app_execute(a, .Latency_Down)
	case .Latency_Up:
		app_execute(a, .Latency_Up)
	case .Monitor:
		app_execute(a, .Monitor)
	case .High_Contrast:
		app_execute(a, .High_Contrast)
	case .Reduced_Motion:
		app_execute(a, .Reduced_Motion)
	}
}

@(private)
settings_move :: proc(a: ^App, delta: int) {
	a.settings_sel = Settings_Item((int(a.settings_sel) + delta + SETTINGS_ITEM_COUNT) % SETTINGS_ITEM_COUNT)
	bump_revision(a)
}

@(private)
app_settings_key :: proc(a: ^App, key: Key, ch: u8) -> bool {
	if a.settings_path_edit {
		#partial switch key {
		case .Escape:
			app_settings_cancel_edit(a)
		case .Enter:
			a.settings_path_edit = false
			app_execute(a, .Apply_Save_Dir)
		case .Backspace:
			if a.settings_path_len > 0 {
				a.settings_path_len -= 1
				bump_revision(a)
			}
		case .Space:
			settings_path_append(a, ' ')
		case .Char:
			if ch >= 32 && ch <= 126 {
				settings_path_append(a, ch)
			}
		case:
		}
		return true
	}
	#partial switch key {
	case .Escape:
		app_settings_close(a)
	case .Enter:
		app_settings_activate(a)
	case .Up:
		settings_move(a, -1)
	case .Down:
		settings_move(a, 1)
	case .Char:
		switch ch {
		case 'j':
			settings_move(a, 1)
		case 'k':
			settings_move(a, -1)
		case 'b':
			a.settings_sel = .Browse
			app_execute(a, .Choose_Save_Dir)
		case 'a':
			a.settings_sel = .Apply
			app_execute(a, .Apply_Save_Dir)
		case 'r':
			a.settings_sel = .Default
			app_execute(a, .Reset_Save_Dir)
		}
	}
	return true
}

// ---------------------------------------------------------------- pointer

app_set_shift :: proc(a: ^App, down: bool) {
	a.shift_down = down
}

DOUBLE_CLICK_TIME :: 0.45
DOUBLE_CLICK_SLOP :: 5.0

app_mouse_move :: proc(a: ^App, x, y: f32) {
	a.mouse_x = x
	a.mouse_y = y
	if !a.mouse_down {
		return
	}
	if abs(x - a.click_x) > DOUBLE_CLICK_SLOP || abs(y - a.click_y) > DOUBLE_CLICK_SLOP {
		a.click_pending = false
	}
	switch a.drag.kind {
	case .Fader:
		i := a.drag.index
		h := max(a.layout.fader[i].h - 4, 1)
		norm := clamp(a.drag.start_norm - (y - a.drag.start_y) / h, 0, 1)
		a.tracks[i].level = norm * 1.5
		app_history_note(a, "fader")
		app_touch(a)
	case .Pan:
		i := a.drag.index
		norm := clamp(a.drag.start_norm - (y - a.drag.start_y) / 120.0, 0, 1)
		a.tracks[i].pan = norm * 2 - 1
		app_history_note(a, "pan")
		app_touch(a)
	case .Knob:
		lo, hi, log := knob_spec(a.drag.target.module, a.drag.target.param)
		speed: f32 = 300.0
		if a.shift_down {
			speed = 3_000.0 // 10x finer, as advertised in the rack header
		}
		norm := clamp(a.drag.start_norm - (y - a.drag.start_y) / speed, 0, 1)
		app_set_knob(a, a.drag.target, norm_to_value(norm, lo, hi, log))
	case .None:
	}
}

@(private)
begin_drag :: proc(a: ^App, kind: Drag_Kind, index: int, target: Knob_Target, norm: f32) {
	a.mouse_down = true
	a.drag = Drag {
		kind = kind,
		index = index,
		target = target,
		start_y = a.mouse_y,
		start_norm = norm,
	}
}

app_mouse_down :: proc(a: ^App, x, y: f32, button: int = 0) {
	a.mouse_x = x
	a.mouse_y = y
	a.mouse_down = true
	l := &a.layout

	double := a.click_pending &&
		a.time - a.click_time <= DOUBLE_CLICK_TIME &&
		abs(x - a.click_x) <= DOUBLE_CLICK_SLOP &&
		abs(y - a.click_y) <= DOUBLE_CLICK_SLOP
	a.click_pending = true
	a.click_time = a.time
	a.click_x = x
	a.click_y = y
	if double && app_double_click(a, x, y) {
		a.click_pending = false
		return
	}

	if a.mode == .Palette {
		if !rect_contains(l.palette, x, y) {
			a.mode = .Normal
			return
		}
		for i in 0 ..< l.palette_count {
			if rect_contains(l.palette_row[i], x, y) {
				a.palette_sel = a.palette_scroll + i
				app_palette_execute(a)
				return
			}
		}
		return
	}

	if a.mode == .Recent {
		if !rect_contains(l.recent_panel, x, y) {
			a.mode = .Normal
			status_buf_set(a, "recent projects closed")
			bump_revision(a)
			return
		}
		for i in 0 ..< min(l.recent_count, MAX_RECENT) {
			if rect_contains(l.recent_row[i], x, y) {
				a.recent_sel = i
				app_recent_choose(a)
				return
			}
		}
		return
	}

	if a.mode == .Io {
		if rect_contains(l.jack, x, y) {
			app_execute(a, .Backend)
			return
		}
		if rect_contains(l.rescan, x, y) {
			app_execute(a, .Rescan)
			return
		}
		if rect_contains(l.lat_minus, x, y) {
			app_execute(a, .Latency_Down)
			return
		}
		if rect_contains(l.lat_plus, x, y) {
			app_execute(a, .Latency_Up)
			return
		}
		for i in 0 ..< l.io_count {
			if rect_contains(l.io_row[i], x, y) {
				app_execute(a, .Select_Device, i)
				a.mode = .Normal
				return
			}
		}
		if !rect_contains(l.io_panel, x, y) {
			a.mode = .Normal
		}
		return
	}

	if a.mode == .Bounce {
		return
	}

	if a.mode == .Fx {
		if rect_contains(l.fx_close, x, y) {
			a.mode = .Normal
			a.fx_focus = -1
			return
		}
		for i in 0 ..< 5 {
			if rect_contains(l.fx_tab[i], x, y) {
				if a.fx_channel != i {
					a.fx_channel = i
					a.fx_focus = -1
					app_layout(a)
				}
				return
			}
		}
		for i in 0 ..< l.toggle_count {
			if rect_contains(l.toggle[i], x, y) {
				app_flip_toggle(a, l.toggle_target[i])
				return
			}
		}
		for i in 0 ..< l.knob_count {
			if rect_contains(l.knob[i], x, y) {
				t := l.knob_target[i]
				// Bypassed modules dim their knobs; keep them inert too.
				if !bypass_state(a, t.module) {
					return
				}
				lo, hi, log := knob_spec(t.module, t.param)
				begin_drag(a, .Knob, i, t, value_to_norm(app_knob_value(a, t), lo, hi, log))
				return
			}
		}
		if !rect_contains(l.fx_panel, x, y) {
			a.mode = .Normal
			a.fx_focus = -1
		}
		return
	}

	if rect_contains(l.rec, x, y) {
		app_toggle_record(a)
		return
	}
	if rect_contains(l.play, x, y) {
		app_toggle_play(a)
		return
	}
	if rect_contains(l.stop, x, y) {
		app_execute(a, .Stop)
		return
	}
	if rect_contains(l.bounce, x, y) {
		app_execute(a, .Bounce)
		return
	}
	if rect_contains(l.fx, x, y) {
		app_execute(a, .Fx)
		return
	}
	if rect_contains(l.io, x, y) {
		app_execute(a, .Io)
		return
	}
	if rect_contains(l.bpm_minus, x, y) {
		app_execute(a, .Bpm_Down)
		return
	}
	if rect_contains(l.bpm_plus, x, y) {
		app_execute(a, .Bpm_Up)
		return
	}
	if rect_contains(l.click, x, y) {
		app_execute(a, .Metronome)
		return
	}
	if rect_contains(l.monitor, x, y) {
		app_execute(a, .Monitor)
		return
	}

	for i in 0 ..< MAX_TRACKS {
		if rect_contains(l.arm[i], x, y) {
			if a.transport == .Recording {
				toast(a, "stop recording to change arms")
				status_buf_set(a, "stop recording to change arms")
				return
			}
			a.tracks[i].armed = !a.tracks[i].armed
			a.selected = i
			app_history_note(a, "arm")
			app_touch(a)
			return
		}
		if rect_contains(l.solo[i], x, y) {
			a.tracks[i].soloed = !a.tracks[i].soloed
			a.selected = i
			app_history_note(a, "solo")
			app_touch(a)
			return
		}
		if rect_contains(l.mute[i], x, y) {
			a.tracks[i].muted = !a.tracks[i].muted
			a.selected = i
			app_history_note(a, "mute")
			app_touch(a)
			return
		}
		if rect_contains(l.input[i], x, y) {
			if a.transport == .Recording {
				toast(a, "stop recording to change input")
				status_buf_set(a, "stop recording to change input")
				return
			}
			a.tracks[i].input = (a.tracks[i].input % max(a.input_count, 1)) + 1
			a.selected = i
			app_history_note(a, "input")
			app_touch(a)
			return
		}
		if rect_contains(l.fader[i], x, y) {
			a.selected = i
			begin_drag(a, .Fader, i, {}, clamp(a.tracks[i].level / 1.5, 0, 1))
			return
		}
		if rect_contains(l.pan[i], x, y) {
			a.selected = i
			begin_drag(a, .Pan, i, {}, (a.tracks[i].pan + 1) * 0.5)
			return
		}
		if rect_contains(l.track[i], x, y) {
			a.selected = i
			return
		}
	}
	if rect_contains(l.master, x, y) {
		a.selected = MAX_TRACKS
	}
}

app_mouse_up :: proc(a: ^App) {
	a.mouse_down = false
	a.drag.kind = .None
	a.shift_down = false
	app_history_commit(a)
}

// Double-click resets a continuous control to its default. Returns true when a
// reset target was hit, so the click does not also start a drag.
app_double_click :: proc(a: ^App, x, y: f32) -> bool {
	l := &a.layout
	if a.mode == .Normal {
		for i in 0 ..< MAX_TRACKS {
			if rect_contains(l.fader[i], x, y) {
				a.tracks[i].level = 0.8
				app_history_note(a, "fader")
				app_touch(a)
				return true
			}
			if rect_contains(l.pan[i], x, y) {
				a.tracks[i].pan = 0
				app_history_note(a, "pan")
				app_touch(a)
				return true
			}
		}
		return false
	}
	if a.mode == .Fx {
		for i in 0 ..< l.knob_count {
			if rect_contains(l.knob[i], x, y) {
				t := l.knob_target[i]
				if bypass_state(a, t.module) {
					app_knob_reset(a, t)
					return true
				}
				return false
			}
		}
	}
	return false
}

// ---------------------------------------------------------------- keyboard

@(private)
fx_focus_count :: proc(a: ^App) -> int {
	return a.layout.knob_count + a.layout.toggle_count
}

app_fx_focus_name :: proc(a: ^App) -> string {
	if a.mode != .Fx || a.fx_focus < 0 || a.fx_focus >= fx_focus_count(a) {
		return "none"
	}
	l := &a.layout
	if a.fx_focus < l.knob_count {
		return app_knob_name(l.knob_target[a.fx_focus])
	}
	return toggle_name(l.toggle_target[a.fx_focus - l.knob_count])
}

@(private)
fx_focus_cycle :: proc(a: ^App, backwards: bool) {
	n := fx_focus_count(a)
	if n == 0 {
		a.fx_focus = -1
		return
	}
	step := -1 if backwards else 1
	if a.fx_focus < 0 {
		a.fx_focus = 0 if !backwards else n - 1
		return
	}
	a.fx_focus = (a.fx_focus + step + n) % n
}

@(private)
fx_focus_step :: proc(a: ^App, dir: f32, fine: bool) {
	l := &a.layout
	if a.fx_focus < 0 || a.fx_focus >= l.knob_count {
		return // toggles are discrete; Enter flips them
	}
	t := l.knob_target[a.fx_focus]
	if !bypass_state(a, t.module) {
		return
	}
	lo, hi, log := knob_spec(t.module, t.param)
	step: f32 = 0.001 if fine else 0.01
	norm := clamp(value_to_norm(app_knob_value(a, t), lo, hi, log) + dir * step, 0, 1)
	app_set_knob(a, t, norm_to_value(norm, lo, hi, log))
}

@(private)
fx_focus_activate :: proc(a: ^App) {
	l := &a.layout
	if a.fx_focus < 0 {
		return
	}
	if a.fx_focus < l.knob_count {
		t := l.knob_target[a.fx_focus]
		if bypass_state(a, t.module) {
			app_knob_reset(a, t)
		}
		return
	}
	i := a.fx_focus - l.knob_count
	if i < l.toggle_count {
		app_flip_toggle(a, l.toggle_target[i])
	}
}

app_key :: proc(a: ^App, key: Key, ch: u8 = 0, shift: bool = false) {
	// SDL2 reports the modifier state on every KEYDOWN; refresh the drag
	// modifier here so Shift-drag works without a second input channel.
	a.shift_down = shift
	// Every key gesture is one undo step, including keyboard toggles and
	// arrow-key trims. Palette execution commits inside app_palette_execute.
	defer app_history_commit(a)

	if a.mode == .Palette {
		if app_palette_key(a, key, ch) {
			return
		}
	}
	if a.mode == .Recent {
		if app_recent_key(a, key, ch) {
			return
		}
	}
	if a.mode == .Settings {
		app_settings_key(a, key, ch)
		return
	}
	if a.mode == .Bounce {
		if key == .Escape {
			app_bounce_dismiss(a)
		}
		return
	}

	#partial switch key {
	case .Escape:
		a.fx_focus = -1
		a.mode = .Normal
		return
	case .Space:
		app_toggle_play(a)
		return
	case .Enter:
		if a.mode == .Fx {
			fx_focus_activate(a)
		}
		return
	case .Tab:
		if a.mode == .Fx {
			fx_focus_cycle(a, shift)
		} else {
			// Includes the master strip so every selectable surface is
			// reachable without a pointer.
			n := MAX_TRACKS + 1
			a.selected = (a.selected + (n - 1 if shift else 1)) % n
		}
		return
	case .Char:
		switch ch {
		case ':':
			a.mode = .Palette
			a.palette_len = 0
			a.palette_sel = 0
			app_palette_rebuild(a)
			return
		case 'x':
			app_execute(a, .Fx)
			return
		case 'i':
			app_execute(a, .Io)
			return
		case ',':
			app_execute(a, .Settings)
			return
		case 'I':
			if a.selected < MAX_TRACKS && a.transport != .Recording {
				a.tracks[a.selected].input = (a.tracks[a.selected].input % max(a.input_count, 1)) + 1
				app_history_note(a, "input")
				app_touch(a)
			} else if a.transport == .Recording {
				toast(a, "stop recording to change input")
			}
			return
		case 'r':
			app_toggle_record(a)
			return
		case 'b':
			app_execute(a, .Bounce)
			return
		case 'c':
			app_execute(a, .Metronome)
			return
		case 'o':
			app_execute(a, .Monitor)
			return
		case 'y':
			app_execute(a, .Backend)
			return
		case 't':
			app_execute(a, .Take_Next, a.selected)
			return
		case 'T':
			app_execute(a, .Take_Prev, a.selected)
			return
		case '+', '=':
			app_execute(a, .Bpm_Up)
			return
		case '-':
			app_execute(a, .Bpm_Down)
			return
		case 'j':
			a.selected = max(a.selected - 1, 0)
			return
		case 'k':
			a.selected = min(a.selected + 1, MAX_TRACKS)
			return
		case 'J':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].level = clamp(a.tracks[a.selected].level - 0.05, 0, 1.5)
				app_history_note(a, "fader")
				app_touch(a)
			}
			return
		case 'K':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].level = clamp(a.tracks[a.selected].level + 0.05, 0, 1.5)
				app_history_note(a, "fader")
				app_touch(a)
			}
			return
		case 'u':
			app_undo(a)
			return
		case 'U':
			app_redo(a)
			return
		case 'm':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].muted = !a.tracks[a.selected].muted
				app_history_note(a, "mute")
				app_touch(a)
			}
			return
		case 's':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].soloed = !a.tracks[a.selected].soloed
				app_history_note(a, "solo")
				app_touch(a)
			}
			return
		case 'a':
			if a.selected < MAX_TRACKS {
				if a.transport == .Recording {
					toast(a, "stop recording to change arms")
					status_buf_set(a, "stop recording to change arms")
				} else {
					a.tracks[a.selected].armed = !a.tracks[a.selected].armed
					app_history_note(a, "arm")
					app_touch(a)
				}
			}
			return
		case '1', '2', '3', '4':
			idx := int(ch - '1')
			if a.transport == .Recording {
				toast(a, "stop recording to change arms")
				status_buf_set(a, "stop recording to change arms")
				return
			}
			a.tracks[idx].armed = !a.tracks[idx].armed
			a.selected = idx
			app_history_note(a, "arm")
			app_touch(a)
			return
		case '[':
			a.fx_channel = (a.fx_channel + 4) % 5
			a.fx_focus = -1
			app_layout(a)
			return
		case ']':
			a.fx_channel = (a.fx_channel + 1) % 5
			a.fx_focus = -1
			app_layout(a)
			return
		}
	case .Up:
		if a.mode == .Fx {
			fx_focus_step(a, 1, shift)
		} else {
			a.selected = max(a.selected - 1, 0)
		}
		return
	case .Down:
		if a.mode == .Fx {
			fx_focus_step(a, -1, shift)
		} else {
			a.selected = min(a.selected + 1, MAX_TRACKS)
		}
		return
	case .Right:
		if a.mode == .Fx {
			fx_focus_step(a, 1, shift)
		} else if a.selected < MAX_TRACKS {
			a.tracks[a.selected].pan = clamp(a.tracks[a.selected].pan + (0.01 if shift else 0.05), -1, 1)
			app_history_note(a, "pan")
			app_touch(a)
		}
		return
	case .Left:
		if a.mode == .Fx {
			fx_focus_step(a, -1, shift)
		} else if a.selected < MAX_TRACKS {
			a.tracks[a.selected].pan = clamp(a.tracks[a.selected].pan - (0.01 if shift else 0.05), -1, 1)
			app_history_note(a, "pan")
			app_touch(a)
		}
		return
	case .Backspace:
		return
	}
}

// ---------------------------------------------------------------- test surface

app_any_solo :: proc(a: ^App) -> bool {
	for t in a.tracks {
		if t.soloed {
			return true
		}
	}
	return false
}

// Mirrors the engine's solo semantics: any solo silences every non-soloed
// track, on top of its own mute switch.
app_track_audible :: proc(a: ^App, i: int) -> bool {
	if a.tracks[i].muted {
		return false
	}
	return !(app_any_solo(a) && !a.tracks[i].soloed)
}

app_target_rect :: proc(a: ^App, name: string) -> (Rect, bool) {
	l := &a.layout
	switch name {
	case "transport.rec":
		return l.rec, true
	case "transport.play":
		return l.play, true
	case "transport.stop":
		return l.stop, true
	case "bounce":
		return l.bounce, true
	case "bpm.minus":
		return l.bpm_minus, true
	case "bpm.plus":
		return l.bpm_plus, true
	case "metronome":
		return l.click, true
	case "monitor":
		return l.monitor, true
	case "jack":
		return l.jack, true
	case "rescan":
		return l.rescan, true
	case "latency.minus":
		return l.lat_minus, true
	case "latency.plus":
		return l.lat_plus, true
	case "fx":
		return l.fx, true
	case "io":
		return l.io, true
	case "fx.close":
		return l.fx_close, true
	case "palette":
		return l.palette, true
	case "palette.input":
		return l.palette_input, true
	case "recent.panel":
		return l.recent_panel, true
	case "recent.input":
		return l.recent_input, true
	case "io.panel":
		return l.io_panel, true
	case "master":
		return l.master, true
	}
	for i in 0 ..< MAX_TRACKS {
		if name == fmt.tprintf("track.%d", i) {
			return l.track[i], true
		}
		if name == fmt.tprintf("arm.%d", i) {
			return l.arm[i], true
		}
		if name == fmt.tprintf("solo.%d", i) {
			return l.solo[i], true
		}
		if name == fmt.tprintf("mute.%d", i) {
			return l.mute[i], true
		}
		if name == fmt.tprintf("input.%d", i) {
			return l.input[i], true
		}
		if name == fmt.tprintf("fader.%d", i) {
			return l.fader[i], true
		}
		if name == fmt.tprintf("pan.%d", i) {
			return l.pan[i], true
		}
		if name == fmt.tprintf("take.%d", i) {
			return l.take[i], true
		}
	}
	for i in 0 ..< 5 {
		if name == fmt.tprintf("fx.tab.%d", i) {
			return l.fx_tab[i], true
		}
	}
	for i in 0 ..< l.knob_count {
		if name == app_knob_name(l.knob_target[i]) {
			return l.knob[i], true
		}
	}
	for i in 0 ..< l.toggle_count {
		if name == toggle_name(l.toggle_target[i]) {
			return l.toggle[i], true
		}
	}
	for i in 0 ..< l.palette_count {
		if name == fmt.tprintf("palette.row.%d", i) {
			return l.palette_row[i], true
		}
	}
	for i in 0 ..< min(l.recent_count, MAX_RECENT) {
		if name == fmt.tprintf("recent.row.%d", i) {
			return l.recent_row[i], true
		}
	}
	for i in 0 ..< l.io_count {
		if name == fmt.tprintf("io.row.%d", i) {
			return l.io_row[i], true
		}
	}
	return {}, false
}

// Whether a semantic target is exposed by the current overlay state. The
// harness uses this so a click can never silently land on a different control
// (or on the overlay backdrop) while still reporting success.
app_target_available :: proc(a: ^App, name: string) -> bool {
	_, exists := app_target_rect(a, name)
	if !exists {
		return false
	}
	is_fx := name == "fx" || name == "fx.close" ||
		strings.has_prefix(name, "fx.tab.") ||
		strings.has_prefix(name, "fx.bypass.") ||
		strings.has_prefix(name, "fx.pingpong.") ||
		strings.has_prefix(name, "knob.")
	is_palette := name == "palette" || name == "palette.input" ||
		strings.has_prefix(name, "palette.row.")
	is_recent := name == "recent.panel" || name == "recent.input" ||
		strings.has_prefix(name, "recent.row.")
	is_io := name == "io.panel" || strings.has_prefix(name, "io.row.") ||
		name == "jack" || name == "rescan" ||
		name == "latency.minus" || name == "latency.plus"

	switch a.mode {
	case .Normal:
		// Header, transport and track controls are only interactive in Normal;
		// the FX/IO buttons themselves stay live so they can close their panel.
		return !is_palette && !is_recent && !is_io && !(is_fx && name != "fx")
	case .Fx:
		return is_fx
	case .Palette:
		return is_palette
	case .Io:
		return is_io || name == "io"
	case .Recent:
		return is_recent
	case .Settings:
		return false
	case .Bounce:
		return false
	}
	return false
}

app_click_id :: proc(a: ^App, name: string) -> bool {
	if !app_target_available(a, name) {
		return false
	}
	r, ok := app_target_rect(a, name)
	if !ok {
		return false
	}
	x := r.x + r.w * 0.5
	y := r.y + r.h * 0.5
	a.mouse_x = x
	a.mouse_y = y
	app_mouse_down(a, x, y)
	app_mouse_up(a)
	return true
}

app_drag_id :: proc(a: ^App, name: string, dy: f32, shift: bool = false) -> bool {
	if !app_target_available(a, name) {
		return false
	}
	r, ok := app_target_rect(a, name)
	if !ok {
		return false
	}
	if len(name) > 5 && name[:5] == "knob." {
		// Bypassed modules render their knobs inert; mirror that for the driver.
		for i in 0 ..< a.layout.knob_count {
			if app_knob_name(a.layout.knob_target[i]) == name {
				if !bypass_state(a, a.layout.knob_target[i].module) {
					return false
				}
				break
			}
		}
	}
	x := r.x + r.w * 0.5
	y := r.y + r.h * 0.5
	a.shift_down = shift
	a.mouse_x = x
	a.mouse_y = y
	a.mouse_down = true
	a.click_pending = false
	app_mouse_down(a, x, y)
	app_mouse_move(a, x, y + dy)
	app_mouse_up(a)
	return true
}

app_key_name :: proc(a: ^App, name: string) -> bool {
	switch name {
	case "space":
		app_key(a, .Space)
	case "enter":
		app_key(a, .Enter)
	case "escape":
		app_key(a, .Escape)
	case "backspace":
		app_key(a, .Backspace)
	case "up":
		app_key(a, .Up)
	case "down":
		app_key(a, .Down)
	case "left":
		app_key(a, .Left)
	case "right":
		app_key(a, .Right)
	case "tab":
		app_key(a, .Tab)
	case "shift+tab":
		app_key(a, .Tab, 0, true)
	case:
		if len(name) == 1 {
			app_key(a, .Char, name[0], name[0] >= 'A' && name[0] <= 'Z')
			return true
		}
		return false
	}
	return true
}

command_name :: proc(kind: Command_Kind) -> string {
	switch kind {
	case .Play:
		return "Play"
	case .Stop:
		return "Stop"
	case .Record_Start:
		return "Record_Start"
	case .Record_Stop:
		return "Record_Stop"
	case .Bounce:
		return "Bounce"
	case .Save:
		return "Save"
	case .Load:
		return "Load"
	case .Select_Device:
		return "Select_Device"
	case .Fx:
		return "Fx"
	case .Io:
		return "Io"
	case .Metronome:
		return "Metronome"
	case .Bpm_Up:
		return "Bpm_Up"
	case .Bpm_Down:
		return "Bpm_Down"
	case .Arm_All:
		return "Arm_All"
	case .Clear_Arms:
		return "Clear_Arms"
	case .Panic:
		return "Panic"
	case .Undo:
		return "Undo"
	case .Redo:
		return "Redo"
	case .Open_Project:
		return "Open_Project"
	case .Save_As:
		return "Save_As"
	case .Recent:
		return "Recent"
	case .Open_Recent:
		return "Open_Recent"
	case .High_Contrast:
		return "High_Contrast"
	case .Reduced_Motion:
		return "Reduced_Motion"
	case .Monitor:
		return "Monitor"
	case .Latency_Up:
		return "Latency_Up"
	case .Latency_Down:
		return "Latency_Down"
	case .Backend:
		return "Backend"
	case .Rescan:
		return "Rescan"
	case .Take_Next:
		return "Take_Next"
	case .Take_Prev:
		return "Take_Prev"
	case .Comp_Use:
		return "Comp_Use"
	case .Comp_Clear:
		return "Comp_Clear"
	case .Settings:
		return "Settings"
	case .Choose_Save_Dir:
		return "Choose_Save_Dir"
	case .Apply_Save_Dir:
		return "Apply_Save_Dir"
	case .Reset_Save_Dir:
		return "Reset_Save_Dir"
	}
	return "None"
}

app_value :: proc(a: ^App, path: string) -> (string, bool) {
	switch path {
	case "transport":
		switch a.transport {
		case .Stopped:
			return "Stopped", true
		case .Playing:
			return "Playing", true
		case .Recording:
			return "Recording", true
		}
	case "mode":
		switch a.mode {
		case .Normal:
			return "Normal", true
		case .Fx:
			return "Fx", true
		case .Palette:
			return "Palette", true
		case .Io:
			return "Io", true
		case .Bounce:
			return "Bounce", true
		case .Recent:
			return "Recent", true
		case .Settings:
			return "Settings", true
		}
	case "selected":
		return fmt.tprintf("%d", a.selected), true
	case "device":
		return app_device(a), true
	case "project":
		return app_project(a), true
	case "status":
		return app_status(a), true
	case "palette.open":
		return "true" if a.mode == .Palette else "false", true
	case "palette.text":
		return string(a.palette_buf[:a.palette_len]), true
	case "palette.count":
		return fmt.tprintf("%d", a.palette_count), true
	case "palette.sel":
		return fmt.tprintf("%d", a.palette_sel), true
	case "palette.scroll":
		return fmt.tprintf("%d", a.palette_scroll), true
	case "palette.visible":
		return fmt.tprintf("%d", a.layout.palette_count), true
	case "recent.open":
		return "true" if a.mode == .Recent else "false", true
	case "recent.count":
		return fmt.tprintf("%d", a.recent_filtered), true
	case "recent.total":
		return fmt.tprintf("%d", a.recent_count), true
	case "recent.sel":
		return fmt.tprintf("%d", a.recent_sel), true
	case "recent.filter":
		return string(a.recent_query_buf[:a.recent_query_len]), true
	case "recent.path":
		if a.recent_filtered == 0 {
			return "", true
		}
		return app_recent_path(a, a.recent_items[clamp(a.recent_sel, 0, a.recent_filtered - 1)]), true
	case "recent.target":
		return app_recent_target(a), true
	case "settings.open":
		return "true" if a.mode == .Settings else "false", true
	case "settings.dir":
		return app_save_dir(a), true
	case "settings.path":
		return app_settings_path(a), true
	case "settings.editing":
		return "true" if a.settings_path_edit else "false", true
	case "command":
		return command_name(a.last_command), true
	case "command.index":
		return fmt.tprintf("%d", a.last_command_index), true
	case "revision":
		return fmt.tprintf("%d", a.state_revision), true
	case "a11y.high_contrast":
		return "true" if a.high_contrast else "false", true
	case "a11y.reduced_motion":
		return "true" if a.reduced_motion else "false", true
	case "undo.depth":
		return fmt.tprintf("%d", a.history_pos), true
	case "redo.depth":
		return fmt.tprintf("%d", a.history_count - 1 - a.history_pos), true
	case "undo.can":
		return "true" if app_can_undo(a) else "false", true
	case "redo.can":
		return "true" if app_can_redo(a) else "false", true
	case "describe":
		return app_describe(a), true
	case "fx.open":
		return "true" if a.mode == .Fx else "false", true
	case "fx.channel":
		return fmt.tprintf("%d", a.fx_channel), true
	case "bounce.progress":
		return fmt.tprintf("%.2f", a.bounce_progress), true
	case "bounce.running":
		return "true" if a.bounce_active else "false", true
	case "tracks":
		return fmt.tprintf("%d", MAX_TRACKS), true
	case "bpm":
		return fmt.tprintf("%d", a.bpm), true
	case "metronome":
		return "true" if a.metronome else "false", true
	case "monitor":
		return "true" if a.monitor else "false", true
	case "latency":
		return fmt.tprintf("%.0f", a.latency_ms), true
	case "backend":
		return "Jack" if a.jack_backend else "Miniaudio", true
	case "solo.any":
		return "true" if app_any_solo(a) else "false", true
	case "armed.count":
		n := 0
		for t in a.tracks {
			if t.armed {
				n += 1
			}
		}
		return fmt.tprintf("%d", n), true
	case "device.count":
		return fmt.tprintf("%d", len(a.devices)), true
	case "input.count":
		return fmt.tprintf("%d", a.input_count), true
	case "fx.focus":
		return app_fx_focus_name(a), true
	case "dirty":
		return "true" if a.dirty else "false", true
	}
	for i in 0 ..< MAX_TRACKS {
		if path == fmt.tprintf("armed.%d", i) {
			return "true" if a.tracks[i].armed else "false", true
		}
		if path == fmt.tprintf("muted.%d", i) {
			return "true" if a.tracks[i].muted else "false", true
		}
		if path == fmt.tprintf("solo.%d", i) {
			return "true" if a.tracks[i].soloed else "false", true
		}
		if path == fmt.tprintf("audible.%d", i) {
			return "true" if app_track_audible(a, i) else "false", true
		}
		if path == fmt.tprintf("input.%d", i) {
			return fmt.tprintf("%d", a.tracks[i].input), true
		}
		if path == fmt.tprintf("level.%d", i) {
			return fmt.tprintf("%.3f", a.tracks[i].level), true
		}
		if path == fmt.tprintf("pan.%d", i) {
			return fmt.tprintf("%.3f", a.tracks[i].pan), true
		}
		if path == fmt.tprintf("has_audio.%d", i) {
			return "true" if a.tracks[i].has_audio else "false", true
		}
		if path == fmt.tprintf("take.count.%d", i) {
			return fmt.tprintf("%d", a.take_count[i]), true
		}
		if path == fmt.tprintf("take.active.%d", i) {
			return fmt.tprintf("%d", a.take_active[i]), true
		}
	}
	for k in 0 ..< a.layout.knob_count {
		t := a.layout.knob_target[k]
		if path == app_knob_name(t) {
			return fmt.tprintf("%.3f", app_knob_value(a, t)), true
		}
	}
	for k in 0 ..< a.layout.toggle_count {
		t := a.layout.toggle_target[k]
		if path == toggle_name(t) {
			return "true" if app_toggle_value(a, t) else "false", true
		}
	}
	return "", false
}
