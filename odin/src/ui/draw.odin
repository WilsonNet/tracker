// Rendering. All layout comes from app_layout so input hit-testing and pixels
// can never drift apart.

package ui

import "core:fmt"
import "core:math"

Chip :: struct {
	label: string,
	on:    bool,
	col:   Color,
}

@(private)
is_hover :: proc(a: ^App, r: Rect) -> bool {
	return rect_contains(r, a.mouse_x, a.mouse_y)
}

@(private)
timecode :: proc(frames: i64, rate: u32) -> string {
	total_ms := i64(f64(frames) / f64(max(rate, 1)) * 1000.0)
	ms := total_ms % 1000
	total_s := total_ms / 1000
	s := total_s % 60
	m := (total_s / 60) % 60
	h := total_s / 3600
	return fmt.tprintf("%02d:%02d:%02d.%03d", h, m, s, ms)
}

@(private)
pan_label :: proc(pan: f32) -> string {
	if abs(pan) < 0.02 {
		return "C"
	}
	if pan < 0 {
		return fmt.tprintf("L%d", int(abs(pan) * 100))
	}
	return fmt.tprintf("R%d", int(pan * 100))
}

@(private)
param_label :: proc(m: Fx_Module, p: int) -> string {
	switch m {
	case .EQ:
		switch p {
		case 0:
			return "LOW"
		case 1:
			return "MID"
		case 2:
			return "FREQ"
		case 3:
			return "Q"
		case 4:
			return "HIGH"
		}
	case .COMP:
		switch p {
		case 0:
			return "THR"
		case 1:
			return "RATIO"
		case 2:
			return "ATK"
		case 3:
			return "REL"
		case 4:
			return "KNEE"
		}
	case .SEND:
		return "REV" if p == 0 else "DLY"
	case .REVERB:
		switch p {
		case 0:
			return "SIZE"
		case 1:
			return "DECAY"
		case 2:
			return "TONE"
		case 3:
			return "PRE"
		case 4:
			return "RET"
		}
	case .DELAY:
		switch p {
		case 0:
			return "TIME"
		case 1:
			return "FB"
		case 2:
			return "TONE"
		case 3:
			return "RET"
		}
	case .WIDTH:
		return "WIDTH" if p == 0 else "BASS"
	case .LIMITER:
		switch p {
		case 0:
			return "CEIL"
		case 1:
			return "REL"
		case 2:
			return "LOOK"
		}
	}
	return "?"
}

@(private)
knob_value_text :: proc(m: Fx_Module, p: int, v: f32) -> string {
	switch m {
	case .EQ:
		switch p {
		case 2:
			if v >= 1000 {
				return fmt.tprintf("%.2f kHz", v / 1000.0)
			}
			return fmt.tprintf("%.0f Hz", v)
		case 3:
			return fmt.tprintf("%.2f", v)
		case:
			return fmt.tprintf("%+.1f dB", v)
		}
	case .COMP:
		switch p {
		case 0:
			return fmt.tprintf("%.1f dB", v)
		case 1:
			return fmt.tprintf("%.1f:1", v)
		case 4:
			return fmt.tprintf("%.1f dB", v)
		case:
			return fmt.tprintf("%.0f ms", v)
		}
	case .SEND:
		return fmt.tprintf("%.2f", v)
	case .REVERB:
		if p == 3 {
			return fmt.tprintf("%.0f ms", v)
		}
		return fmt.tprintf("%.2f", v)
	case .DELAY:
		if p == 0 {
			return fmt.tprintf("%.0f ms", v)
		}
		return fmt.tprintf("%.2f", v)
	case .WIDTH:
		if p == 1 {
			return fmt.tprintf("%.0f Hz", v)
		}
		return fmt.tprintf("%.2f", v)
	case .LIMITER:
		if p == 0 {
			return fmt.tprintf("%.1f dB", v)
		}
		if p == 2 {
			return fmt.tprintf("%.1f ms", v)
		}
		return fmt.tprintf("%.0f ms", v)
	}
	return "?"
}

@(private)
module_title :: proc(m: Fx_Module) -> string {
	switch m {
	case .EQ:
		return "EQ"
	case .COMP:
		return "COMP"
	case .SEND:
		return "SEND"
	case .REVERB:
		return "REVERB"
	case .DELAY:
		return "DELAY"
	case .WIDTH:
		return "WIDTH"
	case .LIMITER:
		return "LIMITER"
	}
	return "?"
}

app_draw :: proc(a: ^App, c: ^Canvas) {
	app_layout(a)
	canvas_clear(c, BG)

	draw_header(a, c)
	draw_transport(a, c)
	for i in 0 ..< MAX_TRACKS {
		draw_track(a, c, i)
	}
	draw_master(a, c)
	draw_status(a, c)

	if a.mode == .Fx {
		draw_fx(a, c)
	} else if a.mode == .Palette {
		draw_palette(a, c)
	} else if a.mode == .Io {
		draw_io(a, c)
	} else if a.mode == .Bounce {
		draw_bounce(a, c)
	}
}

@(private)
draw_header :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.header, PANEL)
	canvas_hline(c, 0, f32(a.width), l.header.h - 1, LINE)
	canvas_fill(c, Rect{16, 10, 3, 26}, AMBER)
	canvas_text(c, 27, 6, "TRACKER", AMBER, 2)
	canvas_vline(c, 142, 10, 36, LINE_BRIGHT)
	canvas_text(c, 156, 9, app_project(a), TEXT)
	canvas_text(c, 156, 25, "MULTITRACK RECORDER · ODIN NATIVE", MUTED)
	right := f32(a.width) - 16
	canvas_text(c, 500, 9, fmt.tprintf("%d kHz", a.sample_rate / 1000), DIM)
	if a.width >= 1040 {
		canvas_text_clip(c, 574, 9, f32(a.width) - 894, app_device(a), MUTED)
	}
	draw_toggle(c, l.click, "CLICK", a.metronome, is_hover(a, l.click), true, TEAL)
	draw_button(c, l.bpm_minus, "-", false, is_hover(a, l.bpm_minus), a.bpm > 40, DIM)
	draw_button(c, l.bpm_plus, "+", false, is_hover(a, l.bpm_plus), a.bpm < 240, DIM)
	canvas_text_center(c, (l.bpm_minus.x + l.bpm_minus.w + l.bpm_plus.x) * 0.5, 8, fmt.tprintf("%d BPM", a.bpm), DIM)
	canvas_text_right(c, right, 25, "TRACKER · 4 TRACK · 32-BIT FLOAT", MUTED)
}

@(private)
draw_transport :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.transport, BG)
	canvas_hline(c, 0, f32(a.width), l.transport.y + l.transport.h - 1, LINE)

	rec_on := a.transport == .Recording
	play_on := a.transport == .Playing
	draw_button(c, l.rec, "REC", rec_on, is_hover(a, l.rec), true, RED)
	draw_button(c, l.play, "PLAY", play_on, is_hover(a, l.play), true, TEAL)
	draw_button(c, l.stop, "STOP", false, is_hover(a, l.stop), a.transport != .Stopped)
	draw_button(c, l.bounce, "BOUNCE", a.mode == .Bounce, is_hover(a, l.bounce), a.transport != .Recording, AMBER)
	draw_button(c, l.fx, "FX", a.mode == .Fx, is_hover(a, l.fx), true, AMBER)
	draw_button(c, l.io, "I/O", a.mode == .Io, is_hover(a, l.io), true, AMBER)

	tc_col: Color = TEXT
	if rec_on {
		tc_col = RED
	} else if play_on {
		tc_col = TEAL
	}
	cx: f32 = 640
	canvas_text_center(c, cx, 54, timecode(a.frames, a.sample_rate), tc_col, 2)
	state := "STOPPED"
	if rec_on {
		state = "RECORDING"
	} else if play_on {
		state = "PLAYING"
	}
	canvas_text_center(c, cx, 88, state, MUTED)

	// Bounce progress under its button.
	if a.mode == .Bounce {
		r := Rect{l.bounce.x, l.bounce.y + l.bounce.h + 4, l.bounce.w, 4}
		canvas_fill(c, r, PANEL_3)
		canvas_fill(c, Rect{r.x, r.y, r.w * clamp(a.bounce_progress, 0, 1), r.h}, AMBER)
	}

	canvas_text_right(c, f32(a.width) - 16, 62, "TAKE 01", DIM)
	canvas_text_right(c, f32(a.width) - 16, 78, fmt.tprintf("%d ARM", arm_count(a)), MUTED)
}

@(private)
arm_count :: proc(a: ^App) -> int {
	n := 0
	for t in a.tracks {
		if t.armed {
			n += 1
		}
	}
	return n
}

@(private)
draw_track :: proc(a: ^App, c: ^Canvas, i: int) {
	l := &a.layout
	t := &a.tracks[i]
	r := l.track[i]
	selected := a.selected == i
	recording := a.transport == .Recording && t.armed

	border: Color = LINE
	if selected {
		border = AMBER_DIM
	}
	if t.armed {
		border = AMBER
	}
	if recording {
		pulse := u8(0x88 + 0x60 * (0.5 + 0.5 * math.sin(a.time * 7.0)))
		border = with_alpha(RED, pulse)
	}
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, border, 2 if recording else 1)

	num_col: Color = AMBER if selected || t.armed else MUTED
	if recording {
		num_col = RED
	}
	canvas_text(c, r.x + 10, r.y + 8, fmt.tprintf("%02d", i + 1), num_col, 2)
	canvas_text(c, r.x + 50, r.y + 11, t.name, TEXT)
	if recording {
		canvas_fill(c, Rect{r.x + r.w - 44, r.y + 10, 34, 18}, with_alpha(RED, 0x33))
		canvas_rect(c, Rect{r.x + r.w - 44, r.y + 10, 34, 18}, RED)
		canvas_text(c, r.x + r.w - 38, r.y + 12, "REC", RED)
	} else if t.has_audio {
		canvas_text_right(c, r.x + r.w - 10, r.y + 12, "TAKE", MUTED)
	}

	in_btn := l.input[i]
	in_hover := is_hover(a, in_btn)
	canvas_fill(c, in_btn, PANEL_2 if !in_hover else PANEL_3)
	canvas_rect(c, in_btn, LINE_BRIGHT)
	canvas_text(c, in_btn.x + 6, in_btn.y + 4, fmt.tprintf("IN %d", t.input), AMBER)

	// FX summary chips.
	chip_x := r.x + 10
	chips := [4]Chip{
		{"EQ", t.eq.enabled, AMBER},
		{"CMP", t.comp.enabled, AMBER},
		{"REV", t.send_reverb > 0.001, TEAL},
		{"DLY", t.send_delay > 0.001, TEAL},
	}
	for chip in chips {
		w: f32 = 30
		cr := Rect{chip_x, r.y + 64, w, 16}
		canvas_fill(c, cr, with_alpha(chip.col, 0x22) if chip.on else PANEL_2)
		canvas_rect(c, cr, with_alpha(chip.col, 0xAA) if chip.on else LINE)
		canvas_text_center(c, cr.x + w * 0.5, cr.y + 1, chip.label, chip.col if chip.on else MUTED)
		chip_x += w + 4
	}

	draw_toggle(c, l.arm[i], "A", t.armed, is_hover(a, l.arm[i]), true, AMBER)
	draw_toggle(c, l.solo[i], "S", t.soloed, is_hover(a, l.solo[i]), true, TEAL)
	draw_toggle(c, l.mute[i], "M", t.muted, is_hover(a, l.mute[i]), true, RED)

	// Pan knob.
	pr := l.pan[i]
	pcx := pr.x + pr.w * 0.5
	pcy := pr.y + pr.h * 0.5 - 4
	draw_knob(c, pcx, pcy, 18, (t.pan + 1) * 0.5, !t.muted)
	canvas_text_center(c, pcx, pcy + 23, "PAN", MUTED)
	canvas_text_center(c, pcx, pcy + 36, pan_label(t.pan), DIM)

	// Fader and meter.
	norm := clamp(t.level / 1.5, 0, 1)
	draw_fader(c, l.fader[i], norm, is_hover(a, l.fader[i]))
	draw_meter(c, l.meter[i], t.peak_db, t.peak_db, AMBER)
	canvas_text_center(c, l.fader[i].x + 9, l.fader[i].y + l.fader[i].h + 4, fmt.tprintf("%.0f%%", norm * 100), DIM)

	// GR meter.
	if t.comp.enabled {
		draw_gr(c, l.gr[i], t.gr_db)
		canvas_text_right(c, l.gr[i].x + l.gr[i].w - 2, l.gr[i].y + 3, fmt.tprintf("%.1f", t.gr_db), MUTED)
	} else {
		canvas_fill(c, l.gr[i], PANEL_2)
		canvas_rect(c, l.gr[i], LINE)
		canvas_text(c, l.gr[i].x + 4, l.gr[i].y + 3, "GR", MUTED)
		canvas_text_right(c, l.gr[i].x + l.gr[i].w - 2, l.gr[i].y + 3, "byp", MUTED)
	}

}

@(private)
draw_master :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	r := l.master
	canvas_fill(c, r, PANEL_2)
	canvas_rect(c, r, LINE_BRIGHT)
	canvas_text(c, r.x + 12, r.y + 10, "MASTER", AMBER)
	canvas_text(c, r.x + 12, r.y + 28, "STEREO BUS", MUTED)

	canvas_text(c, r.x + 16, r.y + 54, "PEAK", MUTED)
	canvas_text_right(c, r.x + r.w - 14, r.y + 54, fmt.tprintf("%.1f dB", a.master.peak_db), TEXT)

	draw_meter(c, l.master_meter, a.master.peak_db, a.master.peak_db, AMBER)
	canvas_text(c, l.master_meter.x + l.master_meter.w + 12, l.master_meter.y + 6, "L/R", MUTED)
	canvas_text(c, l.master_meter.x + l.master_meter.w + 12, l.master_meter.y + 26, fmt.tprintf("%.0f", a.master.peak_db), DIM)

	gr := Rect{r.x + 14, r.y + r.h - 100, r.w - 28, 18}
	draw_gr(c, gr, a.master.gr_db)
	canvas_text_right(c, gr.x + gr.w - 2, gr.y + 3, fmt.tprintf("%.1f", a.master.gr_db), MUTED)

	y := r.y + r.h - 70
	canvas_text(c, r.x + 14, y, "REV", TEAL if a.master.reverb.enabled else MUTED)
	canvas_text(c, r.x + 54, y, "DLY", TEAL if a.master.delay.enabled else MUTED)
	canvas_text(c, r.x + 94, y, "WID", AMBER if a.master.width.enabled else MUTED)
	canvas_text(c, r.x + 14, y + 16, fmt.tprintf("CEIL %.1f", a.master.limiter.ceiling_db), MUTED)

}

@(private)
draw_status :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.status, PANEL)
	canvas_hline(c, 0, f32(a.width), l.status.y, LINE)

	mode_text := "NORMAL"
	mode_col: Color = AMBER
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"
		mode_col = AMBER
	case .Fx:
		mode_text = "FX"
		mode_col = AMBER
	case .Palette:
		mode_text = "CMD"
		mode_col = TEAL
	case .Io:
		mode_text = "I/O"
		mode_col = TEAL
	case .Bounce:
		mode_text = "BOUNCE"
		mode_col = RED
	}
	if a.transport == .Recording {
		mode_text = "REC"
		mode_col = RED
	}
	badge := Rect{12, l.status.y + 5, 58, 18}
	draw_badge(c, badge, mode_text, mode_col)
	canvas_text(c, 82, l.status.y + 7, app_status(a), DIM)

	// Toast.
	if a.toast_time > 0 {
		tw := text_width(app_toast(a)) + 24
		tr := Rect{f32(a.width) - tw - 300, l.status.y - 30, tw, 22}
		canvas_fill(c, tr, PANEL_2)
		canvas_rect(c, tr, with_alpha(AMBER, 0xAA))
		canvas_text(c, tr.x + 10, tr.y + 4, app_toast(a), AMBER)
	}

	canvas_text_right(c, f32(a.width) - 12, l.status.y + 7, "SPACE PLAY   R REC   X FX   : CMD", MUTED)
}

// ---------------------------------------------------------------- FX rack

@(private)
draw_fx :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0xC00A0A0A)
	draw_panel(c, l.fx_panel, PANEL_2, AMBER_DIM)

	canvas_text(c, l.fx_panel.x + 14, l.fx_panel.y + 14, "FX", AMBER, 2)
	for i in 0 ..< 5 {
		label := fmt.tprintf("%d", i + 1)
		if i == 4 {
			label = "MST"
		}
		draw_button(c, l.fx_tab[i], label, a.fx_channel == i, is_hover(a, l.fx_tab[i]), true, AMBER)
	}
	draw_button(c, l.fx_close, "X", false, is_hover(a, l.fx_close), true, DIM)

	chan := "MASTER"
	if a.fx_channel < MAX_TRACKS {
		chan = fmt.tprintf("TRACK %d", a.fx_channel + 1)
	}
	canvas_text(c, l.fx_panel.x + 286, l.fx_panel.y + 18, chan, TEXT)
	canvas_text_right(c, l.fx_panel.x + l.fx_panel.w - 48, l.fx_panel.y + 18, "DRAG KNOBS  ·  SHIFT FINE  ·  ESC CLOSE", MUTED)

	// Module panels.
	for mi in 0 ..< l.fx_module_count {
		p := l.fx_module[mi]
		m := l.fx_module_id[mi]
		canvas_fill(c, p, PANEL)
		canvas_rect(c, p, LINE_BRIGHT)
		canvas_text(c, p.x + 10, p.y + 10, fmt.tprintf("%02d", mi + 1), MUTED)
		canvas_text(c, p.x + 34, p.y + 10, module_title(m), TEXT)

		// Visual.
		vis := Rect{p.x + 10, p.y + 32, p.w - 20, 52}
		draw_module_visual(a, c, m, vis)

		// Knobs belonging to this module.
		for k in 0 ..< l.knob_count {
			t := l.knob_target[k]
			if t.module != m {
				continue
			}
			kr := l.knob[k]
			cx := kr.x + kr.w * 0.5
			cy := kr.y + kr.h * 0.5
			lo, hi, log := knob_spec(m, t.param)
			v := app_knob_value(a, t)
			n := value_to_norm(v, lo, hi, log)
			enabled := bypass_state(a, m)
			draw_knob(c, cx, cy, 18, n, enabled)
			canvas_text_center(c, cx, cy + 23, param_label(m, t.param), MUTED)
			canvas_text_center(c, cx, cy + 37, knob_value_text(m, t.param, v), enabled ? TEXT : MUTED)
		}
	}

	// Toggles.
	for i in 0 ..< l.toggle_count {
		t := l.toggle_target[i]
		on := app_toggle_value(a, t)
		label := ("ON" if on else "BYP") if t.param == 0 else "P-P"
		col: Color = AMBER
		if t.module == .DELAY {
			col = TEAL
		}
		draw_toggle(c, l.toggle[i], label, on, is_hover(a, l.toggle[i]), true, col)
	}
}

@(private)
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

@(private)
draw_module_visual :: proc(a: ^App, c: ^Canvas, m: Fx_Module, r: Rect) {
	track := &a.tracks[clamp(a.fx_channel, 0, MAX_TRACKS - 1)]
	#partial switch m {
	case .EQ:
		eq := track.eq
		if a.fx_channel >= MAX_TRACKS {
			eq = Eq_View{enabled = true, mid_hz = 1000, mid_q = 1}
		}
		draw_eq_curve(c, r, eq.low_db, eq.mid_db, eq.high_db)
	case .COMP:
		comp := track.comp
		if a.fx_channel >= MAX_TRACKS {
			comp = a.master.comp
		}
		draw_comp_curve(c, r, comp.threshold_db, comp.ratio)
	case .SEND:
		draw_eq_curve(c, r, track.send_reverb * 12 - 6, track.send_delay * 12 - 6, 0)
	case .REVERB:
		draw_reverb_tail(c, r, a.master.reverb.decay)
	case .DELAY:
		draw_delay_lanes(c, r, a.master.delay.feedback, a.master.delay.ping_pong)
	case .WIDTH:
		draw_width_scope(c, r, a.master.width.width)
	case .LIMITER:
		draw_limiter_curve(c, r, a.master.limiter.ceiling_db)
	}
}

// ---------------------------------------------------------------- overlays

@(private)
draw_palette :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0xC00A0A0A)
	draw_panel(c, l.palette, PANEL_2, AMBER)
	canvas_text(c, l.palette.x + 16, l.palette.y + 18, "COMMAND", AMBER)
	canvas_text_right(c, l.palette.x + l.palette.w - 16, l.palette.y + 18, "ESC", MUTED)

	input_rect := l.palette_input
	canvas_fill(c, input_rect, BG)
	canvas_rect(c, input_rect, with_alpha(AMBER, 0xAA))
	canvas_text(c, input_rect.x + 8, input_rect.y + 7, ":", AMBER)
	typed := string(a.palette_buf[:a.palette_len])
	canvas_text(c, input_rect.x + 22, input_rect.y + 7, typed, TEXT)
	cursor_x := input_rect.x + 22 + text_width(typed)
	if int(a.time * 2) % 2 == 0 {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 7, 2, 14}, AMBER)
	}

	if a.palette_count == 0 {
		canvas_text(c, l.palette.x + 16, l.palette.y + 60, "no matching command", MUTED)
	}
	for i in 0 ..< a.palette_count {
		row := l.palette_row[i]
		selected := i == a.palette_sel
		if selected {
			canvas_fill(c, row, AMBER_WASH)
			canvas_fill(c, Rect{row.x, row.y, 2, row.h}, AMBER)
		}
		cmd := PALETTE_COMMANDS[a.palette_items[i]]
		canvas_text(c, row.x + 10, row.y + 4, cmd.name, TEXT if selected else DIM)
		hint := command_hint(cmd.kind)
		canvas_text_right(c, row.x + row.w - 8, row.y + 4, hint, MUTED)
	}
	canvas_text(c, l.palette.x + 16, l.palette.y + l.palette.h - 22, "ENTER RUN  ·  UP/DOWN SELECT  ·  ESC CLOSE", MUTED)
}

@(private)
command_hint :: proc(kind: Command_Kind) -> string {
	#partial switch kind {
	case .Play, .Stop, .Record_Start, .Record_Stop:
		return "transport"
	case .Bounce:
		return "render"
	case .Save, .Load:
		return "project"
	case .Select_Device:
		return "audio"
	case .Fx, .Io, .Arm_All, .Clear_Arms, .Panic:
		return "ui"
	}
	return ""
}

@(private)
draw_io :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0x990A0A0A)
	draw_panel(c, l.io_panel, PANEL_2, AMBER_DIM)
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 14, "INPUT DEVICES", AMBER, 2)
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 36, "cooperative PipeWire / JACK sources", MUTED)

	l.io_count = len(a.devices)
	for i in 0 ..< l.io_count {
		row := l.io_row[i]
		sel := i == a.device_index
		hov := is_hover(a, row)
		if sel {
			canvas_fill(c, row, AMBER_WASH)
			canvas_rect(c, row, with_alpha(AMBER, 0xAA))
		} else if hov {
			canvas_fill(c, row, PANEL_3)
			canvas_rect(c, row, LINE)
		} else {
			canvas_fill(c, row, PANEL)
			canvas_rect(c, row, LINE)
		}
		marker := "*" if sel else " "
		canvas_text(c, row.x + 8, row.y + 6, marker, AMBER)
		canvas_text_clip(c, row.x + 22, row.y + 6, row.w - 32, a.devices[i], TEXT if sel else DIM)
	}
	if l.io_count == 0 {
		canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 64, "no devices reported", MUTED)
	}
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + l.io_panel.h - 24, "click to select  ·  ESC close", MUTED)
}

@(private)
draw_bounce :: proc(a: ^App, c: ^Canvas) {
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0xD00A0A0A)
	w: f32 = 460
	h: f32 = 168
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	draw_panel(c, r, PANEL_2, AMBER)
	canvas_text(c, r.x + 20, r.y + 18, "BOUNCING MIX", AMBER)
	canvas_text(c, r.x + 20, r.y + 40, "track chains -> master comp -> reverb -> delay -> width -> limiter", MUTED)
	bar := Rect{r.x + 20, r.y + 74, r.w - 40, 18}
	canvas_fill(c, bar, PANEL_3)
	canvas_fill(c, Rect{bar.x, bar.y, bar.w * clamp(a.bounce_progress, 0, 1), bar.h}, AMBER)
	canvas_rect(c, bar, LINE_BRIGHT)
	canvas_text(c, r.x + 20, r.y + 104, fmt.tprintf("%.0f%%", a.bounce_progress * 100), TEXT)
	canvas_text_right(c, r.x + r.w - 20, r.y + 104, "writing bounce.wav", MUTED)
	canvas_text(c, r.x + 20, r.y + h - 24, "ESC cancel", MUTED)
}
