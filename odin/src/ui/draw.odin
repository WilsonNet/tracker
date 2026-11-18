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
knob_value_text :: proc(m: Fx_Module, p: int, v: f32, compact: bool = false) -> string {
	switch m {
	case .EQ:
		switch p {
		case 2:
			if compact {
				if v >= 1000 {
					return fmt.tprintf("%.1fk", v / 1000.0)
				}
				return fmt.tprintf("%.0f", v)
			}
			if v >= 1000 {
				return fmt.tprintf("%.2f kHz", v / 1000.0)
			}
			return fmt.tprintf("%.0f Hz", v)
		case 3:
			return fmt.tprintf("%.2f", v)
		case:
			if compact {
				return fmt.tprintf("%+.1f", v)
			}
			return fmt.tprintf("%+.1f dB", v)
		}
	case .COMP:
		switch p {
		case 0:
			return fmt.tprintf("%.1f", v) if compact else fmt.tprintf("%.1f dB", v)
		case 1:
			return fmt.tprintf("%.1f:1", v)
		case 4:
			return fmt.tprintf("%.1f", v) if compact else fmt.tprintf("%.1f dB", v)
		case:
			return fmt.tprintf("%.0fms", v) if compact else fmt.tprintf("%.0f ms", v)
		}
	case .SEND:
		return fmt.tprintf("%.2f", v)
	case .REVERB:
		if p == 3 {
			return fmt.tprintf("%.0fms", v) if compact else fmt.tprintf("%.0f ms", v)
		}
		return fmt.tprintf("%.2f", v)
	case .DELAY:
		if p == 0 {
			return fmt.tprintf("%.0fms", v) if compact else fmt.tprintf("%.0f ms", v)
		}
		return fmt.tprintf("%.2f", v)
	case .WIDTH:
		if p == 1 {
			return fmt.tprintf("%.0fHz", v) if compact else fmt.tprintf("%.0f Hz", v)
		}
		return fmt.tprintf("%.2f", v)
	case .LIMITER:
		if p == 0 {
			return fmt.tprintf("%.1f", v) if compact else fmt.tprintf("%.1f dB", v)
		}
		if p == 2 {
			return fmt.tprintf("%.1fms", v) if compact else fmt.tprintf("%.1f ms", v)
		}
		return fmt.tprintf("%.0fms", v) if compact else fmt.tprintf("%.0f ms", v)
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
	ACTIVE_TOKENS = app_tokens(a)
	canvas_clear(c, ACTIVE_TOKENS.bg)

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
	} else if a.mode == .Recent {
		draw_recent(a, c)
	}
}

@(private)
draw_header :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.header, ACTIVE_TOKENS.panel)
	canvas_hline(c, 0, f32(a.width), l.header.h - 1, ACTIVE_TOKENS.line)
	canvas_fill(c, Rect{16, 10, 3, 26}, ACTIVE_TOKENS.amber)
	canvas_text(c, 27, 6, "TRACKER", ACTIVE_TOKENS.amber, 2)
	canvas_vline(c, 142, 10, 36, ACTIVE_TOKENS.line_bright)
	canvas_text_clip(c, 156, 9, max(f32(a.width) - 456, 120), app_project(a), ACTIVE_TOKENS.text)
	canvas_text(c, 156, 25, "MULTITRACK RECORDER · ODIN NATIVE", ACTIVE_TOKENS.muted)
	// Top-right: sample rate, then the device name to its left. Both live on
	// the first row so the BPM stepper on row two never paints over them.
	right := f32(a.width) - 16
	canvas_text_right(c, right, 8, fmt.tprintf("%d kHz", a.sample_rate / 1000), ACTIVE_TOKENS.dim)
	device_right := right - 62
	canvas_text_clip(c, device_right - 210, 8, 210, app_device(a), ACTIVE_TOKENS.muted)
	draw_button(c, l.bpm_minus, "-", false, is_hover(a, l.bpm_minus), a.bpm > 40, ACTIVE_TOKENS.dim)
	draw_button(c, l.bpm_plus, "+", false, is_hover(a, l.bpm_plus), a.bpm < 240, ACTIVE_TOKENS.dim)
	canvas_text_center(c, (l.bpm_minus.x + l.bpm_minus.w + l.bpm_plus.x) * 0.5, 28, fmt.tprintf("%d BPM", a.bpm), ACTIVE_TOKENS.dim)
	draw_toggle(c, l.click, "CLICK", a.metronome, is_hover(a, l.click), true, ACTIVE_TOKENS.teal)
}

@(private)
draw_transport :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.transport, ACTIVE_TOKENS.bg)
	canvas_hline(c, 0, f32(a.width), l.transport.y + l.transport.h - 1, ACTIVE_TOKENS.line)

	rec_on := a.transport == .Recording
	play_on := a.transport == .Playing
	draw_button(c, l.rec, "REC", rec_on, is_hover(a, l.rec), true, ACTIVE_TOKENS.red)
	draw_button(c, l.play, "PLAY", play_on, is_hover(a, l.play), true, ACTIVE_TOKENS.teal)
	draw_button(c, l.stop, "STOP", false, is_hover(a, l.stop), a.transport != .Stopped)
	draw_button(c, l.bounce, "BOUNCE", a.mode == .Bounce, is_hover(a, l.bounce), a.transport != .Recording, ACTIVE_TOKENS.amber)
	draw_button(c, l.fx, "FX", a.mode == .Fx, is_hover(a, l.fx), true, ACTIVE_TOKENS.amber)
	draw_button(c, l.io, "I/O", a.mode == .Io, is_hover(a, l.io), true, ACTIVE_TOKENS.amber)

	tc_col: Color = ACTIVE_TOKENS.text
	if rec_on {
		tc_col = ACTIVE_TOKENS.red
	} else if play_on {
		tc_col = ACTIVE_TOKENS.teal
	}
	cx := max(f32(a.width) * 0.5, l.io.x + l.io.w + 120)
	canvas_text_center(c, cx, 54, timecode(a.frames, a.sample_rate), tc_col, 2)
	state := "STOPPED"
	if rec_on {
		state = "RECORDING"
	} else if play_on {
		state = "PLAYING"
	}
	canvas_text_center(c, cx, 88, state, ACTIVE_TOKENS.muted)

	// Bounce progress under its button.
	if a.mode == .Bounce {
		r := Rect{l.bounce.x, l.bounce.y + l.bounce.h + 4, l.bounce.w, 4}
		canvas_fill(c, r, ACTIVE_TOKENS.panel_3)
		canvas_fill(c, Rect{r.x, r.y, r.w * clamp(a.bounce_progress, 0, 1), r.h}, ACTIVE_TOKENS.amber)
	}

	canvas_text_right(c, f32(a.width) - 16, 62, "TAKE 01", ACTIVE_TOKENS.dim)
	canvas_text_right(c, f32(a.width) - 16, 78, fmt.tprintf("%d ARM", arm_count(a)), ACTIVE_TOKENS.muted)
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
	audible := app_track_audible(a, i)

	border: Color = ACTIVE_TOKENS.line
	if selected {
		border = ACTIVE_TOKENS.amber_dim
	}
	if t.armed {
		border = ACTIVE_TOKENS.amber
	}
	if recording {
		pulse := u8(0xE8)
		if !a.reduced_motion {
			pulse = u8(0x88 + 0x60 * (0.5 + 0.5 * math.sin(a.time * 7.0)))
		}
		border = with_alpha(ACTIVE_TOKENS.red, pulse)
	}
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, border, 2 if recording else 1)

	num_col: Color = ACTIVE_TOKENS.amber if selected || t.armed else ACTIVE_TOKENS.muted
	if recording {
		num_col = ACTIVE_TOKENS.red
	}
	canvas_text(c, r.x + 10, r.y + 8, fmt.tprintf("%02d", i + 1), num_col, 2)
	canvas_text_clip(c, r.x + 50, r.y + 11, r.w - 104, t.name, ACTIVE_TOKENS.text)
	if recording {
		canvas_fill(c, Rect{r.x + r.w - 44, r.y + 10, 34, 18}, with_alpha(ACTIVE_TOKENS.red, 0x33))
		canvas_rect(c, Rect{r.x + r.w - 44, r.y + 10, 34, 18}, ACTIVE_TOKENS.red)
		canvas_text(c, r.x + r.w - 38, r.y + 12, "REC", ACTIVE_TOKENS.red)
	} else if !audible {
		canvas_text_right(c, r.x + r.w - 10, r.y + 12, "MUTE" if t.muted else "SOLO", ACTIVE_TOKENS.muted)
	} else if t.has_audio {
		canvas_text_right(c, r.x + r.w - 10, r.y + 12, "TAKE", ACTIVE_TOKENS.muted)
	}

	in_btn := l.input[i]
	in_hover := is_hover(a, in_btn) && a.transport != .Recording
	canvas_fill(c, in_btn, ACTIVE_TOKENS.panel_2 if !in_hover else ACTIVE_TOKENS.panel_3)
	canvas_rect(c, in_btn, ACTIVE_TOKENS.line_bright)
	canvas_text(c, in_btn.x + 6, in_btn.y + 8, fmt.tprintf("IN %d", t.input), ACTIVE_TOKENS.amber if a.transport != .Recording else ACTIVE_TOKENS.muted)

	// FX summary chips.
	chip_x := r.x + 10
	chips := [4]Chip{
		{"EQ", t.eq.enabled, ACTIVE_TOKENS.amber},
		{"CMP", t.comp.enabled, ACTIVE_TOKENS.amber},
		{"REV", t.send_reverb > 0.001, ACTIVE_TOKENS.teal},
		{"DLY", t.send_delay > 0.001, ACTIVE_TOKENS.teal},
	}
	for chip in chips {
		w: f32 = 30
		cr := Rect{chip_x, r.y + 62, w, 16}
		canvas_fill(c, cr, with_alpha(chip.col, 0x22) if chip.on else ACTIVE_TOKENS.panel_2)
		canvas_rect(c, cr, with_alpha(chip.col, 0xAA) if chip.on else ACTIVE_TOKENS.line)
		canvas_text_center(c, cr.x + w * 0.5, cr.y + 1, chip.label, chip.col if chip.on else ACTIVE_TOKENS.muted)
		chip_x += w + 4
	}

	draw_toggle(c, l.arm[i], "A", t.armed, is_hover(a, l.arm[i]), a.transport != .Recording, ACTIVE_TOKENS.amber)
	draw_toggle(c, l.solo[i], "S", t.soloed, is_hover(a, l.solo[i]), true, ACTIVE_TOKENS.teal)
	draw_toggle(c, l.mute[i], "M", t.muted, is_hover(a, l.mute[i]), true, ACTIVE_TOKENS.red)

	// Pan knob.
	pr := l.pan[i]
	pcx := pr.x + pr.w * 0.5
	pcy := pr.y + pr.h * 0.5 - 4
	draw_knob(c, pcx, pcy, 18, (t.pan + 1) * 0.5, audible)
	canvas_text_center(c, pcx, pcy + 23, "PAN", ACTIVE_TOKENS.muted)
	canvas_text_center(c, pcx, pcy + 36, pan_label(t.pan), ACTIVE_TOKENS.dim)

	// Fader and meter.
	norm := clamp(t.level / 1.5, 0, 1)
	draw_fader(c, l.fader[i], norm, is_hover(a, l.fader[i]), audible)
	draw_meter(c, l.meter[i], t.peak_db, t.peak_db, ACTIVE_TOKENS.amber if audible else ACTIVE_TOKENS.muted)
	canvas_text_center(c, l.fader[i].x + l.fader[i].w * 0.5, l.fader[i].y + l.fader[i].h + 4, fmt.tprintf("%.0f%%", norm * 100), ACTIVE_TOKENS.dim)

	// GR meter.
	if t.comp.enabled {
		draw_gr(c, l.gr[i], t.gr_db)
		gr_ink: Color = ACTIVE_TOKENS.black if t.gr_db < -1.0 else ACTIVE_TOKENS.muted
		canvas_text_right(c, l.gr[i].x + l.gr[i].w - 2, l.gr[i].y + 3, fmt.tprintf("%.1f", t.gr_db), gr_ink)
	} else {
		canvas_fill(c, l.gr[i], ACTIVE_TOKENS.panel_2)
		canvas_rect(c, l.gr[i], ACTIVE_TOKENS.line)
		canvas_text(c, l.gr[i].x + 4, l.gr[i].y + 3, "GR", ACTIVE_TOKENS.muted)
		canvas_text_right(c, l.gr[i].x + l.gr[i].w - 2, l.gr[i].y + 3, "byp", ACTIVE_TOKENS.muted)
	}

}

@(private)
draw_master :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	r := l.master
	canvas_fill(c, r, ACTIVE_TOKENS.panel_2)
	canvas_rect(c, r, ACTIVE_TOKENS.amber_dim if a.selected >= MAX_TRACKS else ACTIVE_TOKENS.line_bright)
	canvas_text(c, r.x + 12, r.y + 10, "MASTER", ACTIVE_TOKENS.amber)
	canvas_text(c, r.x + 12, r.y + 28, "STEREO BUS", ACTIVE_TOKENS.muted)

	canvas_text(c, r.x + 16, r.y + 54, "PEAK", ACTIVE_TOKENS.muted)
	canvas_text_right(c, r.x + r.w - 14, r.y + 54, fmt.tprintf("%.1f dB", a.master.peak_db), ACTIVE_TOKENS.text)

	draw_meter(c, l.master_meter, a.master.peak_db, a.master.peak_db, ACTIVE_TOKENS.amber)
	canvas_text(c, l.master_meter.x + l.master_meter.w + 12, l.master_meter.y + 6, "L/R", ACTIVE_TOKENS.muted)
	canvas_text(c, l.master_meter.x + l.master_meter.w + 12, l.master_meter.y + 26, fmt.tprintf("%.0f", a.master.peak_db), ACTIVE_TOKENS.dim)

	gr := Rect{r.x + 14, r.y + r.h - 100, r.w - 28, 18}
	draw_gr(c, gr, a.master.gr_db)
	master_gr_ink: Color = ACTIVE_TOKENS.black if a.master.gr_db < -1.0 else ACTIVE_TOKENS.muted
	canvas_text_right(c, gr.x + gr.w - 2, gr.y + 3, fmt.tprintf("%.1f", a.master.gr_db), master_gr_ink)

	y := r.y + r.h - 70
	canvas_text(c, r.x + 14, y, "REV", ACTIVE_TOKENS.teal if a.master.reverb.enabled else ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 54, y, "DLY", ACTIVE_TOKENS.teal if a.master.delay.enabled else ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 94, y, "WID", ACTIVE_TOKENS.amber if a.master.width.enabled else ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 14, y + 16, fmt.tprintf("CEIL %.1f", a.master.limiter.ceiling_db), ACTIVE_TOKENS.muted)

}

@(private)
draw_status :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.status, ACTIVE_TOKENS.panel)
	canvas_hline(c, 0, f32(a.width), l.status.y, ACTIVE_TOKENS.line)

	mode_text := "NORMAL"
	mode_col: Color = ACTIVE_TOKENS.amber
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"
		mode_col = ACTIVE_TOKENS.amber
	case .Fx:
		mode_text = "FX"
		mode_col = ACTIVE_TOKENS.amber
	case .Palette:
		mode_text = "CMD"
		mode_col = ACTIVE_TOKENS.teal
	case .Io:
		mode_text = "I/O"
		mode_col = ACTIVE_TOKENS.teal
	case .Bounce:
		mode_text = "BOUNCE"
		mode_col = ACTIVE_TOKENS.red
	case .Recent:
		mode_text = "RECENT"
		mode_col = ACTIVE_TOKENS.teal
	}
	if a.transport == .Recording {
		mode_text = "REC"
		mode_col = ACTIVE_TOKENS.red
	}
	badge := Rect{12, l.status.y + 5, 58, 18}
	draw_badge(c, badge, mode_text, mode_col)
	canvas_text(c, 82, l.status.y + 7, app_status(a), ACTIVE_TOKENS.dim)

	// Toast.
	if a.toast_time > 0 {
		tw := text_width(app_toast(a)) + 24
		tx := clamp(f32(a.width) - tw - 300, 8, f32(a.width) - tw - 8)
		tr := Rect{tx, l.status.y - 30, tw, 22}
		canvas_fill(c, tr, ACTIVE_TOKENS.panel_2)
		canvas_rect(c, tr, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
		canvas_text(c, tr.x + 10, tr.y + 4, app_toast(a), ACTIVE_TOKENS.amber)
	}

	canvas_text_right(c, f32(a.width) - 12, l.status.y + 7, "SPACE PLAY   R REC   X FX   : CMD", ACTIVE_TOKENS.muted)
}

// ---------------------------------------------------------------- FX rack

@(private)
fx_channel_active :: proc(a: ^App, i: int) -> bool {
	if i >= MAX_TRACKS {
		return a.master.comp.enabled || a.master.reverb.enabled || a.master.delay.enabled ||
			a.master.width.enabled || a.master.limiter.enabled
	}
	t := &a.tracks[i]
	return t.eq.enabled || t.comp.enabled || t.send_reverb > 0.001 || t.send_delay > 0.001
}

@(private)
draw_fx :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0xC00A0A0A)
	draw_panel(c, l.fx_panel, ACTIVE_TOKENS.panel_2, ACTIVE_TOKENS.amber_dim)

	canvas_text(c, l.fx_panel.x + 14, l.fx_panel.y + 14, "FX", ACTIVE_TOKENS.amber, 2)
	for i in 0 ..< 5 {
		label := fmt.tprintf("%d", i + 1)
		if i == 4 {
			label = "MST"
		}
		draw_button(c, l.fx_tab[i], label, a.fx_channel == i, is_hover(a, l.fx_tab[i]), true, ACTIVE_TOKENS.amber)
		if fx_channel_active(a, i) {
			canvas_fill(c, Rect{l.fx_tab[i].x + l.fx_tab[i].w * 0.5 - 1.5, l.fx_tab[i].y + l.fx_tab[i].h + 2, 3, 3}, ACTIVE_TOKENS.amber)
		}
	}
	draw_button(c, l.fx_close, "X", false, is_hover(a, l.fx_close), true, ACTIVE_TOKENS.dim)

	chan := "MASTER"
	if a.fx_channel < MAX_TRACKS {
		chan = fmt.tprintf("TRACK %d", a.fx_channel + 1)
	}
	canvas_text(c, l.fx_panel.x + 306, l.fx_panel.y + 18, chan, ACTIVE_TOKENS.text)
	canvas_text_right(c, l.fx_panel.x + l.fx_panel.w - 48, l.fx_panel.y + 18, "DRAG/SHIFT FINE · TAB FOCUS · ESC", ACTIVE_TOKENS.muted)

	// Module panels.
	for mi in 0 ..< l.fx_module_count {
		p := l.fx_module[mi]
		m := l.fx_module_id[mi]
		canvas_fill(c, p, ACTIVE_TOKENS.panel)
		canvas_rect(c, p, ACTIVE_TOKENS.line_bright)
		canvas_text(c, p.x + 10, p.y + 10, fmt.tprintf("%02d", mi + 1), ACTIVE_TOKENS.muted)
		canvas_text(c, p.x + 34, p.y + 10, module_title(m), ACTIVE_TOKENS.text)

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
			canvas_text_center(c, cx, cy + 23, param_label(m, t.param), ACTIVE_TOKENS.muted)
			compact := p.w / 3 < 68
			canvas_text_center(c, cx, cy + 37, knob_value_text(m, t.param, v, compact), enabled ? ACTIVE_TOKENS.text : ACTIVE_TOKENS.muted)
			if a.fx_focus == k {
				canvas_rect(c, Rect{kr.x - 3, kr.y - 3, kr.w + 6, kr.h + 6}, ACTIVE_TOKENS.amber)
			}
		}
	}

	// Toggles.
	for i in 0 ..< l.toggle_count {
		t := l.toggle_target[i]
		bypassed := app_toggle_value(a, t)
		lit := toggle_lit(a, t)
		label := ("BYP" if bypassed else "ON") if t.param == 0 else "P-P"
		col: Color = ACTIVE_TOKENS.amber
		if t.module == .DELAY {
			col = ACTIVE_TOKENS.teal
		}
		draw_toggle(c, l.toggle[i], label, lit, is_hover(a, l.toggle[i]), true, col)
		if a.fx_focus == l.knob_count + i {
			r := l.toggle[i]
			canvas_rect(c, Rect{r.x - 2, r.y - 2, r.w + 4, r.h + 4}, ACTIVE_TOKENS.amber)
		}
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
	draw_panel(c, l.palette, ACTIVE_TOKENS.panel_2, ACTIVE_TOKENS.amber)
	canvas_text(c, l.palette.x + 16, l.palette.y + 14, "COMMAND", ACTIVE_TOKENS.amber)
	canvas_text_right(c, l.palette.x + l.palette.w - 16, l.palette.y + 14, "ESC", ACTIVE_TOKENS.muted)

	input_rect := l.palette_input
	canvas_fill(c, input_rect, ACTIVE_TOKENS.bg)
	canvas_rect(c, input_rect, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
	canvas_text(c, input_rect.x + 8, input_rect.y + 7, ":", ACTIVE_TOKENS.amber)
	typed := string(a.palette_buf[:a.palette_len])
	canvas_text_clip(c, input_rect.x + 22, input_rect.y + 7, input_rect.w - 34, typed, ACTIVE_TOKENS.text)
	cursor_x := input_rect.x + 22 + text_width(typed)
	if cursor_x < input_rect.x + input_rect.w - 8 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 7, 2, 14}, ACTIVE_TOKENS.amber)
	}

	if a.palette_count == 0 {
		canvas_text(c, l.palette.x + 16, l.palette.y + 86, "no matching command", ACTIVE_TOKENS.muted)
	}
	for i in 0 ..< l.palette_count {
		row := l.palette_row[i]
		idx := a.palette_scroll + i
		selected := idx == a.palette_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill(c, row, ACTIVE_TOKENS.amber_wash)
			canvas_fill(c, Rect{row.x, row.y, 2, row.h}, ACTIVE_TOKENS.amber)
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.panel_3)
		}
		cmd := PALETTE_COMMANDS[a.palette_items[idx]]
		canvas_text_clip(c, row.x + 10, row.y + 7, row.w - 110, cmd.name, ACTIVE_TOKENS.text if selected else ACTIVE_TOKENS.dim)
		hint := command_hint(cmd.kind)
		canvas_text_right(c, row.x + row.w - 8, row.y + 7, hint, ACTIVE_TOKENS.muted)
	}
	canvas_text(c, l.palette.x + 16, l.palette.y + l.palette.h - 22, "ENTER RUN  ·  UP/DOWN SELECT  ·  ESC CLOSE", ACTIVE_TOKENS.muted)
	if a.palette_count > l.palette_count {
		canvas_text_right(c, l.palette.x + l.palette.w - 16, l.palette.y + l.palette.h - 22, fmt.tprintf("%d/%d", a.palette_scroll + 1, a.palette_count), ACTIVE_TOKENS.muted)
	}
}

@(private)
command_hint :: proc(kind: Command_Kind) -> string {
	#partial switch kind {
	case .Play, .Stop, .Record_Start, .Record_Stop:
		return "transport"
	case .Bounce:
		return "render"
	case .Save, .Load, .Save_As:
		return "project"
	case .Open_Project, .Recent, .Open_Recent:
		return "project"
	case .Undo, .Redo:
		return "history"
	case .High_Contrast, .Reduced_Motion:
		return "a11y"
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
	draw_panel(c, l.io_panel, ACTIVE_TOKENS.panel_2, ACTIVE_TOKENS.amber_dim)
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 14, "INPUT DEVICES", ACTIVE_TOKENS.amber, 2)
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 48, "cooperative PipeWire / JACK sources", ACTIVE_TOKENS.muted)

	l.io_count = min(len(a.devices), MAX_DEVICES)
	for i in 0 ..< l.io_count {
		row := l.io_row[i]
		sel := i == a.device_index
		hov := is_hover(a, row)
		if sel {
			canvas_fill(c, row, ACTIVE_TOKENS.amber_wash)
			canvas_rect(c, row, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.panel_3)
			canvas_rect(c, row, ACTIVE_TOKENS.line)
		} else {
			canvas_fill(c, row, ACTIVE_TOKENS.panel)
			canvas_rect(c, row, ACTIVE_TOKENS.line)
		}
		marker := "*" if sel else " "
		canvas_text(c, row.x + 8, row.y + 6, marker, ACTIVE_TOKENS.amber)
		canvas_text_clip(c, row.x + 22, row.y + 6, row.w - 32, a.devices[i], ACTIVE_TOKENS.text if sel else ACTIVE_TOKENS.dim)
	}
	if l.io_count == 0 {
		canvas_text(c, l.io_panel.x + 14, l.io_panel.y + 64, "no devices reported", ACTIVE_TOKENS.muted)
	}
	canvas_text(c, l.io_panel.x + 14, l.io_panel.y + l.io_panel.h - 24, "click to select  ·  ESC close", ACTIVE_TOKENS.muted)
}

@(private)
draw_recent :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(ACTIVE_TOKENS.bg, 0xC0))
	draw_panel(c, l.recent_panel, ACTIVE_TOKENS.panel_2, ACTIVE_TOKENS.amber)
	canvas_text(c, l.recent_panel.x + 16, l.recent_panel.y + 14, "RECENT PROJECTS", ACTIVE_TOKENS.amber)
	canvas_text_right(c, l.recent_panel.x + l.recent_panel.w - 16, l.recent_panel.y + 14, "ESC", ACTIVE_TOKENS.muted)

	input_rect := l.recent_input
	canvas_fill(c, input_rect, ACTIVE_TOKENS.bg)
	canvas_rect(c, input_rect, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
	canvas_text(c, input_rect.x + 8, input_rect.y + 7, "/", ACTIVE_TOKENS.amber)
	typed := string(a.recent_query_buf[:a.recent_query_len])
	canvas_text_clip(c, input_rect.x + 22, input_rect.y + 7, input_rect.w - 34, typed, ACTIVE_TOKENS.text)
	cursor_x := input_rect.x + 22 + text_width(typed)
	if cursor_x < input_rect.x + input_rect.w - 8 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 7, 2, 14}, ACTIVE_TOKENS.amber)
	}

	if a.recent_filtered == 0 {
		msg := "no recent projects" if a.recent_count == 0 else "no matching project"
		canvas_text(c, l.recent_panel.x + 16, l.recent_panel.y + 86, msg, ACTIVE_TOKENS.muted)
		if a.recent_count == 0 {
			canvas_text(c, l.recent_panel.x + 16, l.recent_panel.y + 106, "use : open project  (the window supplies the picker)", ACTIVE_TOKENS.dim)
		}
	}
	for i in 0 ..< min(l.recent_count, MAX_RECENT) {
		row := l.recent_row[i]
		selected := i == a.recent_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill(c, row, ACTIVE_TOKENS.amber_wash)
			canvas_fill(c, Rect{row.x, row.y, 2, row.h}, ACTIVE_TOKENS.amber)
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.panel_3)
		}
		path := app_recent_path(a, a.recent_items[i])
		canvas_text(c, row.x + 10, row.y + 8, ">", ACTIVE_TOKENS.amber if selected else ACTIVE_TOKENS.muted)
		canvas_text_clip(c, row.x + 24, row.y + 8, row.w - 60, path, ACTIVE_TOKENS.text if selected else ACTIVE_TOKENS.dim)
		canvas_text_right(c, row.x + row.w - 8, row.y + 8, fmt.tprintf("%d", a.recent_items[i] + 1), ACTIVE_TOKENS.muted)
	}
	canvas_text(c, l.recent_panel.x + 16, l.recent_panel.y + l.recent_panel.h - 22, "TYPE FILTER  ·  ENTER OPEN  ·  UP/DOWN SELECT  ·  ESC CLOSE", ACTIVE_TOKENS.muted)
}

@(private)
draw_bounce :: proc(a: ^App, c: ^Canvas) {
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, 0xD00A0A0A)
	w: f32 = 460
	h: f32 = 168
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	draw_panel(c, r, ACTIVE_TOKENS.panel_2, ACTIVE_TOKENS.amber)
	canvas_text(c, r.x + 20, r.y + 18, "BOUNCING MIX", ACTIVE_TOKENS.amber)
	canvas_text(c, r.x + 20, r.y + 40, "track chains -> master comp -> reverb", ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 20, r.y + 54, "-> delay -> width -> limiter", ACTIVE_TOKENS.muted)
	bar := Rect{r.x + 20, r.y + 74, r.w - 40, 18}
	canvas_fill(c, bar, ACTIVE_TOKENS.panel_3)
	canvas_fill(c, Rect{bar.x, bar.y, bar.w * clamp(a.bounce_progress, 0, 1), bar.h}, ACTIVE_TOKENS.amber)
	canvas_rect(c, bar, ACTIVE_TOKENS.line_bright)
	canvas_text(c, r.x + 20, r.y + 104, fmt.tprintf("%.0f%%", a.bounce_progress * 100), ACTIVE_TOKENS.text)
	canvas_text_right(c, r.x + r.w - 20, r.y + 104, "writing bounce.wav", ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 20, r.y + h - 24, "ESC dismiss (render continues)", ACTIVE_TOKENS.muted)
}
