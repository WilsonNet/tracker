// Pointer and keyboard input, command palette, semantic test targets and
// assertion paths. Everything here is pure state: no OS calls.

package ui

import "core:fmt"

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
	{"save project", .Save},
	{"load project", .Load},
	{"arm all", .Arm_All},
	{"clear arms", .Clear_Arms},
	{"panic", .Panic},
	{"metronome", .Metronome},
	{"tempo up", .Bpm_Up},
	{"tempo down", .Bpm_Down},
}

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
	a.dirty = true

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

app_toggle_value :: proc(a: ^App, t: Toggle_Target) -> bool {
	if t.module == .DELAY && t.param == 1 {
		return a.master.delay.ping_pong
	}
	if a.fx_channel >= MAX_TRACKS {
		#partial switch t.module {
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
			return false
		}
	}
	track := &a.tracks[a.fx_channel]
	#partial switch t.module {
	case .EQ:
		return track.eq.enabled
	case .COMP:
		return track.comp.enabled
	case .SEND:
		return track.send_reverb > 0 || track.send_delay > 0
	case:
		return false
	}
}

app_flip_toggle :: proc(a: ^App, t: Toggle_Target) {
	a.dirty = true
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
	a.palette_sel = clamp(a.palette_sel, 0, max(a.palette_count - 1, 0))
	app_layout(a)
}

app_palette_execute :: proc(a: ^App) {
	if a.palette_count == 0 {
		return
	}
	idx := a.palette_items[a.palette_sel]
	cmd := PALETTE_COMMANDS[idx]
	a.mode = .Normal
	status_buf_set(a, fmt.tprintf(": %s", cmd.name))
	app_execute(a, cmd.kind)
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
		if ch >= 32 && ch <= 126 && a.palette_len < len(a.palette_buf) {
			a.palette_buf[a.palette_len] = ch
			a.palette_len += 1
			app_palette_rebuild(a)
			return true
		}
	case .Space:
		if a.palette_len < len(a.palette_buf) {
			a.palette_buf[a.palette_len] = ' '
			a.palette_len += 1
			app_palette_rebuild(a)
			return true
		}
	case:
	}
	return false
}

// ---------------------------------------------------------------- pointer

app_mouse_move :: proc(a: ^App, x, y: f32) {
	a.mouse_x = x
	a.mouse_y = y
	if !a.mouse_down {
		return
	}
	switch a.drag.kind {
	case .Fader:
		i := a.drag.index
		h := max(a.layout.fader[i].h - 4, 1)
		norm := clamp(a.drag.start_norm - (y - a.drag.start_y) / h, 0, 1)
		a.tracks[i].level = norm * 1.5
		a.dirty = true
	case .Pan:
		i := a.drag.index
		norm := clamp(a.drag.start_norm - (y - a.drag.start_y) / 120.0, 0, 1)
		a.tracks[i].pan = norm * 2 - 1
		a.dirty = true
	case .Knob:
		lo, hi, log := knob_spec(a.drag.target.module, a.drag.target.param)
		speed: f32 = 300.0
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

	if a.mode == .Palette {
		if !rect_contains(l.palette, x, y) {
			a.mode = .Normal
			return
		}
		for i in 0 ..< l.palette_count {
			if rect_contains(l.palette_row[i], x, y) {
				a.palette_sel = i
				app_palette_execute(a)
				return
			}
		}
		return
	}

	if a.mode == .Io {
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
			return
		}
		for i in 0 ..< 5 {
			if rect_contains(l.fx_tab[i], x, y) {
				a.fx_channel = i
				app_layout(a)
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
				lo, hi, log := knob_spec(t.module, t.param)
				begin_drag(a, .Knob, i, t, value_to_norm(app_knob_value(a, t), lo, hi, log))
				return
			}
		}
		if !rect_contains(l.fx_panel, x, y) {
			a.mode = .Normal
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

	for i in 0 ..< MAX_TRACKS {
		if rect_contains(l.arm[i], x, y) {
			a.tracks[i].armed = !a.tracks[i].armed
			a.selected = i
			return
		}
		if rect_contains(l.solo[i], x, y) {
			a.tracks[i].soloed = !a.tracks[i].soloed
			a.selected = i
			return
		}
		if rect_contains(l.mute[i], x, y) {
			a.tracks[i].muted = !a.tracks[i].muted
			a.selected = i
			return
		}
		if rect_contains(l.input[i], x, y) {
			a.tracks[i].input = (a.tracks[i].input % 8) + 1
			a.selected = i
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
}

app_double_click :: proc(a: ^App, x, y: f32) {
	// Reset faders/pans/knobs to their defaults.
	l := &a.layout
	for i in 0 ..< MAX_TRACKS {
		if rect_contains(l.fader[i], x, y) {
			a.tracks[i].level = 0.8
			return
		}
		if rect_contains(l.pan[i], x, y) {
			a.tracks[i].pan = 0
			return
		}
	}
}

// ---------------------------------------------------------------- keyboard

app_key :: proc(a: ^App, key: Key, ch: u8 = 0, shift: bool = false) {
	if a.mode == .Palette {
		if app_palette_key(a, key, ch) {
			return
		}
	}
	if a.mode == .Bounce {
		if key == .Escape {
			a.mode = .Normal
		}
		return
	}

	#partial switch key {
	case .Escape:
		a.mode = .Normal
		return
	case .Space:
		app_toggle_play(a)
		return
	case .Enter:
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
		case 'r':
			app_toggle_record(a)
			return
		case 'b':
			app_execute(a, .Bounce)
			return
		case 'c':
			app_execute(a, .Metronome)
			return
		case 'j':
			a.selected = max(a.selected - 1, 0)
			return
		case 'k':
			a.selected = min(a.selected + 1, MAX_TRACKS - 1)
			return
		case 'J':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].level = clamp(a.tracks[a.selected].level - 0.05, 0, 1.5)
			}
			return
		case 'K':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].level = clamp(a.tracks[a.selected].level + 0.05, 0, 1.5)
			}
			return
		case 'm':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].muted = !a.tracks[a.selected].muted
			}
			return
		case 's':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].soloed = !a.tracks[a.selected].soloed
			}
			return
		case 'a':
			if a.selected < MAX_TRACKS {
				a.tracks[a.selected].armed = !a.tracks[a.selected].armed
			}
			return
		case '1', '2', '3', '4':
			idx := int(ch - '1')
			a.tracks[idx].armed = !a.tracks[idx].armed
			a.selected = idx
			return
		case '[':
			a.fx_channel = (a.fx_channel + 4) % 5
			return
		case ']':
			a.fx_channel = (a.fx_channel + 1) % 5
			return
		}
	case .Up:
		a.selected = max(a.selected - 1, 0)
		return
	case .Down:
		a.selected = min(a.selected + 1, MAX_TRACKS - 1)
		return
	case .Left, .Right, .Backspace, .Tab:
		return
	}
}

// ---------------------------------------------------------------- test surface

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
	case "io.panel":
		return l.io_panel, true
	}
	for i in 0 ..< MAX_TRACKS {
		switch name {
		case "track.0":
			if i == 0 {
				return l.track[i], true
			}
		}
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
	for i in 0 ..< l.io_count {
		if name == fmt.tprintf("io.row.%d", i) {
			return l.io_row[i], true
		}
	}
	return {}, false
}

app_click_id :: proc(a: ^App, name: string) -> bool {
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

app_drag_id :: proc(a: ^App, name: string, dy: f32) -> bool {
	r, ok := app_target_rect(a, name)
	if !ok {
		return false
	}
	x := r.x + r.w * 0.5
	y := r.y + r.h * 0.5
	a.mouse_x = x
	a.mouse_y = y
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
	case:
		if len(name) == 1 {
			app_key(a, .Char, name[0], name[0] >= 'A' && name[0] <= 'Z')
			return true
		}
		return false
	}
	return true
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
	case "fx.open":
		return "true" if a.mode == .Fx else "false", true
	case "fx.channel":
		return fmt.tprintf("%d", a.fx_channel), true
	case "bounce.progress":
		return fmt.tprintf("%.2f", a.bounce_progress), true
	case "tracks":
		return fmt.tprintf("%d", MAX_TRACKS), true
	case "bpm":
		return fmt.tprintf("%d", a.bpm), true
	case "metronome":
		return "true" if a.metronome else "false", true
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
