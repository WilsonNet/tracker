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
	canvas_clear(c, ACTIVE_TOKENS.color.bg)

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
	canvas_fill(c, l.header, ACTIVE_TOKENS.color.surface)
	canvas_hline(c, 0, f32(a.width), l.header.h - 1, ACTIVE_TOKENS.color.line)

	mode_text := "NORMAL"
	mode_col: Color = ACTIVE_TOKENS.color.amber
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"; mode_col = ACTIVE_TOKENS.color.amber
	case .Fx:
		mode_text = "FX"; mode_col = ACTIVE_TOKENS.color.amber
	case .Palette:
		mode_text = "CMD"; mode_col = ACTIVE_TOKENS.color.teal
	case .Io:
		mode_text = "I/O"; mode_col = ACTIVE_TOKENS.color.teal
	case .Recent:
		mode_text = "RECENT"; mode_col = ACTIVE_TOKENS.color.teal
	case .Bounce:
		mode_text = "BOUNCE"; mode_col = ACTIVE_TOKENS.color.red
	}
	if a.transport == .Recording {
		mode_text = "REC"; mode_col = ACTIVE_TOKENS.color.red
	}
	badge := Rect{14, 12, 58, 24}
	canvas_fill(c, badge, with_alpha(mode_col, 0x18))
	canvas_rect(c, badge, with_alpha(mode_col, 0x99))
	canvas_text_px_center(c, badge.x + badge.w * 0.5, badge.y + 7, mode_text, mode_col, 9)
}

@(private)
draw_transport :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	rec_on := a.transport == .Recording
	play_on := a.transport == .Playing
	live := a.transport != .Stopped

	draw_transport_button(c, l.rec, .Dot, "REC", rec_on, is_hover(a, l.rec), live || true, ACTIVE_TOKENS.color.red)
	draw_transport_button(c, l.play, .Triangle, "PLAY", play_on, is_hover(a, l.play), live || true, ACTIVE_TOKENS.color.teal)
	draw_transport_button(c, l.stop, .Square, "STOP", false, is_hover(a, l.stop), live, ACTIVE_TOKENS.color.ink_dim)

	// Timecode is the one larger readout in the bar; everything else is
	// label-sized so the hierarchy stays calm.
	tc_col: Color = ACTIVE_TOKENS.color.ink
	if rec_on {
		tc_col = ACTIVE_TOKENS.color.red
	} else if play_on {
		tc_col = ACTIVE_TOKENS.color.teal
	}
	canvas_text_px(c, 260, 6, timecode(a.frames, a.sample_rate), tc_col, ACTIVE_TOKENS.type.title)
	state := "STOPPED"
	if rec_on {
		state = "RECORDING"
	} else if play_on {
		state = "PLAYING"
	}
	canvas_text_px(c, 260, 28, state, ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)

	canvas_text_px_center(c, (l.bpm_minus.x + l.bpm_minus.w + l.bpm_plus.x) * 0.5, 16, fmt.tprintf("%d BPM", a.bpm), ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)
	draw_bar_button(c, l.bpm_minus, "-", false, is_hover(a, l.bpm_minus), a.bpm > 40, ACTIVE_TOKENS.color.ink_dim)
	draw_bar_button(c, l.bpm_plus, "+", false, is_hover(a, l.bpm_plus), a.bpm < 240, ACTIVE_TOKENS.color.ink_dim)

	draw_bar_button(c, l.bounce, "BOUNCE", a.mode == .Bounce, is_hover(a, l.bounce), a.transport != .Recording, ACTIVE_TOKENS.color.amber)
	draw_bar_button(c, l.fx, "FX", a.mode == .Fx, is_hover(a, l.fx), true, ACTIVE_TOKENS.color.amber)
	draw_bar_button(c, l.io, "I/O", a.mode == .Io, is_hover(a, l.io), true, ACTIVE_TOKENS.color.amber)
	draw_bar_button(c, l.monitor, "MON", a.monitor, is_hover(a, l.monitor), true, ACTIVE_TOKENS.color.teal)
	draw_bar_button(c, l.click, "CLICK", a.metronome, is_hover(a, l.click), true, ACTIVE_TOKENS.color.teal)

	if a.mode == .Bounce {
		r := Rect{l.bounce.x, l.bounce.y + l.bounce.h + 2, l.bounce.w, 3}
		canvas_fill(c, r, ACTIVE_TOKENS.color.surface_high)
		canvas_fill(c, Rect{r.x, r.y, r.w * clamp(a.bounce_progress, 0, 1), r.h}, ACTIVE_TOKENS.color.amber)
	}
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

	border := ACTIVE_TOKENS.color.line
	if selected {
		border = ACTIVE_TOKENS.color.border_amber
	}
	if t.armed {
		border = ACTIVE_TOKENS.color.red
	}
	if recording {
		pulse := u8(0xE8)
		if !a.reduced_motion {
			pulse = u8(0x88 + 0x60 * (0.5 + 0.5 * math.sin(a.time * 7.0)))
		}
		border = with_alpha(ACTIVE_TOKENS.color.red, pulse)
	}
	canvas_fill(c, r, ACTIVE_TOKENS.color.bg)
	canvas_rect(c, r, border, 2 if recording else 1)

	// Header row.
	num_col: Color = ACTIVE_TOKENS.color.amber if selected else ACTIVE_TOKENS.color.ink_muted
	if t.armed {
		num_col = ACTIVE_TOKENS.color.red
	}
	canvas_text(c, r.x + 10, r.y + 10, fmt.tprintf("%02d", i + 1), num_col)
	name_w := max(l.take[i].x - (r.x + 32) - 6, 10)
	canvas_text_clip(c, r.x + 32, r.y + 11, name_w, t.name, ACTIVE_TOKENS.color.ink if !recording else ACTIVE_TOKENS.color.ink)

	if a.take_count[i] > 0 {
		tr := l.take[i]
		hov := is_hover(a, tr) && a.transport != .Recording
		canvas_fill(c, tr, ACTIVE_TOKENS.color.surface_raised if hov else 0)
		canvas_rect(c, tr, ACTIVE_TOKENS.color.line_strong if hov else ACTIVE_TOKENS.color.line)
		label := "T?" if a.take_active[i] <= 0 else fmt.tprintf("T%d/%d", a.take_active[i], a.take_count[i])
		canvas_text_px_center(c, tr.x + tr.w * 0.5, tr.y + 6, label, ACTIVE_TOKENS.color.amber if a.take_count[i] > 1 else ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
	}

	in_btn := l.input[i]
	hov_in := is_hover(a, in_btn) && a.transport != .Recording
	canvas_fill(c, in_btn, ACTIVE_TOKENS.color.surface_raised if hov_in else 0)
	canvas_rect(c, in_btn, ACTIVE_TOKENS.color.line_strong if hov_in else ACTIVE_TOKENS.color.line)
	canvas_text_px_center(c, in_btn.x + in_btn.w * 0.5, in_btn.y + 6, fmt.tprintf("IN %d", t.input), ACTIVE_TOKENS.color.amber if a.transport != .Recording else ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	// FX summary: one thin strip, on/off written as colour not chrome.
	fx_row := Rect{r.x + 10, r.y + 33, r.w - 20, 19}
	canvas_rect(c, fx_row, ACTIVE_TOKENS.color.line)
	canvas_text_px(c, fx_row.x + 6, fx_row.y + 6, "FX", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	chip_x := fx_row.x + 28
	chips := [4]struct {
		label: string,
		on:    bool,
		col:   Color,
	}{
		{"EQ", t.eq.enabled, ACTIVE_TOKENS.color.amber},
		{"CMP", t.comp.enabled, ACTIVE_TOKENS.color.amber},
		{"REV", t.send_reverb > 0.001, ACTIVE_TOKENS.color.teal},
		{"DLY", t.send_delay > 0.001, ACTIVE_TOKENS.color.teal},
	}
	for chip in chips {
		canvas_text_px(c, chip_x, fx_row.y + 6, chip.label, chip.col if chip.on else ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
		chip_x += f32(len(chip.label) + 1) * 5.4 + 5
	}

	draw_label_toggle(c, l.arm[i], "ARM", t.armed, is_hover(a, l.arm[i]), a.transport != .Recording, ACTIVE_TOKENS.color.red)
	draw_label_toggle(c, l.solo[i], "SOLO", t.soloed, is_hover(a, l.solo[i]), true, ACTIVE_TOKENS.color.teal)
	draw_label_toggle(c, l.mute[i], "MUTE", t.muted, is_hover(a, l.mute[i]), true, ACTIVE_TOKENS.color.red)

	// Pan knob.
	pr := l.pan[i]
	pcx := pr.x + pr.w * 0.5
	pcy := pr.y + 18
	draw_knob(c, pcx, pcy, 16, (t.pan + 1) * 0.5, !t.muted)
	canvas_text_px_center(c, pcx, pcy + 24, "PAN", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
	canvas_text_px_center(c, pcx, pcy + 36, pan_label(t.pan), ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)

	// Fader and meter.
	norm := clamp(t.level / 1.5, 0, 1)
	draw_fader(c, l.fader[i], norm, is_hover(a, l.fader[i]), !t.muted)
	draw_meter(c, l.meter[i], t.peak_db, t.peak_db, ACTIVE_TOKENS.color.amber if !t.muted else ACTIVE_TOKENS.color.ink_muted)
	level_db := -120.0 if t.level <= 0.0001 else 20.0 * math.log10(f64(t.level))
	canvas_text_px_center(c, l.fader[i].x + l.fader[i].w * 0.5, l.fader[i].y + l.fader[i].h + 7, fmt.tprintf("%.0f dB", clamp(level_db, -60, 6)), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	// GR only appears while the compressor is actually catching something,
	// so an idle strip stays as empty as a tape lane.
	if t.comp.enabled && t.gr_db < -0.5 {
		canvas_text_px(c, l.gr[i].x, l.gr[i].y + 1, fmt.tprintf("GR %.1f dB", t.gr_db), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	}
}

@(private)
draw_master :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.bottom, ACTIVE_TOKENS.color.surface)
	canvas_hline(c, 0, f32(a.width), l.bottom.y, ACTIVE_TOKENS.color.line)

	canvas_text_px(c, 14, l.bottom.y + 7, fmt.tprintf("PROJECT  %s", app_project(a)), ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)
	canvas_text_px(c, 14, l.bottom.y + 20, fmt.tprintf("%d TRACK / %d ARM / %d kHz", MAX_TRACKS, arm_count(a), a.sample_rate / 1000), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	canvas_text_px_center(c, f32(a.width) * 0.5, l.bottom.y + 13, "SPACE PLAY / R REC / B BOUNCE / X FX / : CMD", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	r := l.master
	sel := a.selected >= MAX_TRACKS
	canvas_fill(c, r, ACTIVE_TOKENS.color.bg)
	canvas_rect(c, r, ACTIVE_TOKENS.color.border_amber if sel else ACTIVE_TOKENS.color.line)
	canvas_text_px(c, r.x + 8, r.y + 6, "MASTER", ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.caption)
	canvas_text_px(c, r.x + 58, r.y + 5, fmt.tprintf("%.1f dB", a.master.peak_db), ACTIVE_TOKENS.color.ink, ACTIVE_TOKENS.type.label)
	canvas_text_px(c, r.x + 118, r.y + 6, fmt.tprintf("GR %.1f", a.master.gr_db), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	canvas_text_px_right(c, r.x + r.w - 8, r.y + 6, fmt.tprintf("LIM %.1f", a.master.limiter.ceiling_db), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	draw_h_meter(c, l.master_meter, db_norm(a.master.peak_db), ACTIVE_TOKENS.color.amber)
}

@(private)
draw_status :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, l.status, ACTIVE_TOKENS.color.bg)
	canvas_hline(c, 0, f32(a.width), l.status.y, ACTIVE_TOKENS.color.line)

	mode_text := "NORMAL"
	mode_col: Color = ACTIVE_TOKENS.color.amber
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"; mode_col = ACTIVE_TOKENS.color.amber
	case .Fx:
		mode_text = "FX"; mode_col = ACTIVE_TOKENS.color.amber
	case .Palette:
		mode_text = "CMD"; mode_col = ACTIVE_TOKENS.color.teal
	case .Io:
		mode_text = "I/O"; mode_col = ACTIVE_TOKENS.color.teal
	case .Bounce:
		mode_text = "BOUNCE"; mode_col = ACTIVE_TOKENS.color.red
	case .Recent:
		mode_text = "RECENT"; mode_col = ACTIVE_TOKENS.color.teal
	}
	if a.transport == .Recording {
		mode_text = "REC"; mode_col = ACTIVE_TOKENS.color.red
	}
	badge := Rect{12, l.status.y + 5, 56, 18}
	canvas_fill(c, badge, with_alpha(mode_col, 0x18))
	canvas_rect(c, badge, with_alpha(mode_col, 0x99))
	canvas_text_px_center(c, badge.x + badge.w * 0.5, badge.y + 4, mode_text, mode_col, 8.5)
	canvas_text_px(c, 78, l.status.y + 8, app_status(a), ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)

	if a.toast_time > 0 {
		tw := text_width_px(app_toast(a), 10) + 20
		tx := clamp(f32(a.width) - tw - 260, 8, f32(a.width) - tw - 8)
		tr := Rect{tx, l.bottom.y - 26, tw, 20}
		canvas_fill(c, tr, ACTIVE_TOKENS.color.surface_raised)
		canvas_rect(c, tr, with_alpha(ACTIVE_TOKENS.color.amber, 0xAA))
		canvas_text_px(c, tr.x + 8, tr.y + 4, app_toast(a), ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.caption)
	}

	dev := app_device(a)
	if len(dev) == 0 {
		dev = "no input"
	}
	canvas_text_px_right(c, f32(a.width) - 12, l.status.y + 8, fmt.tprintf("%s / %d kHz", dev, a.sample_rate / 1000), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
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
	draw_panel(c, l.fx_panel, ACTIVE_TOKENS.color.surface, ACTIVE_TOKENS.color.line_strong)
	canvas_text_px(c, l.fx_panel.x + 14, l.fx_panel.y + 12, "FX", ACTIVE_TOKENS.color.amber, 12)
	for i in 0 ..< 5 {
		label := fmt.tprintf("%d", i + 1)
		if i == 4 { label = "MST" }
		draw_bar_button(c, l.fx_tab[i], label, a.fx_channel == i, is_hover(a, l.fx_tab[i]), true, ACTIVE_TOKENS.color.amber)
		if fx_channel_active(a, i) && a.fx_channel != i {
			canvas_fill(c, Rect{l.fx_tab[i].x + l.fx_tab[i].w * 0.5 - 1, l.fx_tab[i].y + l.fx_tab[i].h + 2, 2, 2}, ACTIVE_TOKENS.color.amber)
		}
	}
	draw_bar_button(c, l.fx_close, "X", false, is_hover(a, l.fx_close), true, ACTIVE_TOKENS.color.ink_dim)

	chan := "MASTER"
	if a.fx_channel < MAX_TRACKS { chan = fmt.tprintf("TRACK %d", a.fx_channel + 1) }
	canvas_text_px(c, l.fx_panel.x + 264, l.fx_panel.y + 13, chan, ACTIVE_TOKENS.color.ink_dim, 10)
	canvas_text_px_right(c, l.fx_panel.x + l.fx_panel.w - 44, l.fx_panel.y + 13, "DRAG / SHIFT FINE / TAB FOCUS / ESC", ACTIVE_TOKENS.color.ink_muted, 9)

	for mi in 0 ..< l.fx_module_count {
		p := l.fx_module[mi]
		m := l.fx_module_id[mi]
		canvas_fill(c, p, ACTIVE_TOKENS.color.bg)
		canvas_rect(c, p, ACTIVE_TOKENS.color.line)
		canvas_text_px(c, p.x + 8, p.y + 9, fmt.tprintf("%02d", mi + 1), ACTIVE_TOKENS.color.ink_muted, 9)
		canvas_text_px(c, p.x + 28, p.y + 9, module_title(m), ACTIVE_TOKENS.color.ink, 10)
		vis := Rect{p.x + 8, p.y + 28, p.w - 16, 38}
		draw_module_visual(a, c, m, vis)
		for k in 0 ..< l.knob_count {
			t := l.knob_target[k]
			if t.module != m { continue }
			kr := l.knob[k]
			cx := kr.x + kr.w * 0.5
			cy := kr.y + kr.h * 0.5
			lo, hi, log := knob_spec(m, t.param)
			v := app_knob_value(a, t)
			n := value_to_norm(v, lo, hi, log)
			enabled := bypass_state(a, m)
			draw_knob(c, cx, cy, 15, n, enabled)
			canvas_text_px_center(c, cx, cy + 20, param_label(m, t.param), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
			canvas_text_px_center(c, cx, cy + 31, knob_value_text(m, t.param, v), enabled ? ACTIVE_TOKENS.color.ink : ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
			if a.fx_focus == k {
				canvas_rect(c, Rect{kr.x - 2, kr.y - 2, kr.w + 4, kr.h + 4}, ACTIVE_TOKENS.color.amber)
			}
		}
	}
	for i in 0 ..< l.toggle_count {
		t := l.toggle_target[i]
		bypassed := app_toggle_value(a, t)
		lit := toggle_lit(a, t)
		label := ("BYP" if bypassed else "ON") if t.param == 0 else "PING"
		col: Color = ACTIVE_TOKENS.color.amber
		if t.module == .DELAY { col = ACTIVE_TOKENS.color.teal }
		draw_toggle(c, l.toggle[i], label, lit, is_hover(a, l.toggle[i]), true, col)
		if a.fx_focus == l.knob_count + i {
			canvas_rect(c, Rect{l.toggle[i].x - 2, l.toggle[i].y - 2, l.toggle[i].w + 4, l.toggle[i].h + 4}, ACTIVE_TOKENS.color.amber)
		}
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
		draw_eq_curve(c, r, eq.low_db, eq.mid_db, eq.high_db, bypass_state(a, m))
	case .COMP:
		comp := track.comp
		if a.fx_channel >= MAX_TRACKS {
			comp = a.master.comp
		}
		draw_comp_curve(c, r, comp.threshold_db, comp.ratio, bypass_state(a, m))
	case .SEND:
		draw_eq_curve(c, r, track.send_reverb * 12 - 6, track.send_delay * 12 - 6, 0, true)
	case .REVERB:
		draw_reverb_tail(c, r, a.master.reverb.decay, bypass_state(a, m))
	case .DELAY:
		draw_delay_lanes(c, r, a.master.delay.feedback, a.master.delay.ping_pong, bypass_state(a, m))
	case .WIDTH:
		draw_width_scope(c, r, a.master.width.width, bypass_state(a, m))
	case .LIMITER:
		draw_limiter_curve(c, r, a.master.limiter.ceiling_db, bypass_state(a, m))
	}
}

// ---------------------------------------------------------------- overlays

@(private)
draw_palette :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(ACTIVE_TOKENS.color.bg, 0xC8))
	draw_panel(c, l.palette, ACTIVE_TOKENS.color.surface, ACTIVE_TOKENS.color.amber)
	canvas_text_px(c, l.palette.x + 16, l.palette.y + 12, "COMMAND", ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.label)
	canvas_text_px_right(c, l.palette.x + l.palette.w - 16, l.palette.y + 12, "ESC", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	input_rect := l.palette_input
	canvas_fill(c, input_rect, ACTIVE_TOKENS.color.bg)
	canvas_rect(c, input_rect, with_alpha(ACTIVE_TOKENS.color.amber, 0xAA))
	canvas_text(c, input_rect.x + 8, input_rect.y + 7, ":", ACTIVE_TOKENS.color.amber)
	typed := string(a.palette_buf[:a.palette_len])
	canvas_text_clip(c, input_rect.x + 22, input_rect.y + 7, input_rect.w - 34, typed, ACTIVE_TOKENS.color.ink)
	cursor_x := input_rect.x + 22 + text_width(typed)
	if cursor_x < input_rect.x + input_rect.w - 8 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 7, 2, 14}, ACTIVE_TOKENS.color.amber)
	}

	if a.palette_count == 0 {
		canvas_text_px(c, l.palette.x + 16, l.palette.y + 84, "no matching command", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.label)
	}
	for i in 0 ..< l.palette_count {
		row := l.palette_row[i]
		idx := a.palette_scroll + i
		selected := idx == a.palette_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill(c, row, ACTIVE_TOKENS.color.amber_wash)
			canvas_fill(c, Rect{row.x, row.y, 2, row.h}, ACTIVE_TOKENS.color.amber)
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.color.surface_high)
		}
		cmd := PALETTE_COMMANDS[a.palette_items[idx]]
		canvas_text_clip(c, row.x + 10, row.y + 7, row.w - 110, cmd.name, ACTIVE_TOKENS.color.ink if selected else ACTIVE_TOKENS.color.ink_dim)
		hint := command_hint(cmd.kind)
		canvas_text_right(c, row.x + row.w - 8, row.y + 7, hint, ACTIVE_TOKENS.color.ink_muted)
	}
	canvas_text_px(c, l.palette.x + 16, l.palette.y + l.palette.h - 20, "ENTER RUN / UP/DOWN SELECT / ESC CLOSE", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
	if a.palette_count > l.palette_count {
		canvas_text_px_right(c, l.palette.x + l.palette.w - 16, l.palette.y + l.palette.h - 20, fmt.tprintf("%d/%d", a.palette_scroll + 1, a.palette_count), ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
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
	case .Monitor, .Backend, .Rescan, .Latency_Up, .Latency_Down:
		return "audio"
	case .Take_Next, .Take_Prev:
		return "take"
	case .Comp_Use, .Comp_Clear:
		return "take"
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
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(ACTIVE_TOKENS.color.bg, 0xAA))
	draw_panel(c, l.io_panel, ACTIVE_TOKENS.color.surface, ACTIVE_TOKENS.color.amber_dim)
	canvas_text_px(c, l.io_panel.x + 14, l.io_panel.y + 14, "INPUT DEVICES", ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.title)
	canvas_text_px(c, l.io_panel.x + 14, l.io_panel.y + 38, "cooperative PipeWire / JACK sources", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	l.io_count = min(len(a.devices), MAX_DEVICES)
	for i in 0 ..< l.io_count {
		row := l.io_row[i]
		sel := i == a.device_index
		hov := is_hover(a, row)
		if sel {
			canvas_fill(c, row, ACTIVE_TOKENS.color.amber_wash)
			canvas_rect(c, row, with_alpha(ACTIVE_TOKENS.color.amber, 0xAA))
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.color.surface_high)
			canvas_rect(c, row, ACTIVE_TOKENS.color.line)
		} else {
			canvas_fill(c, row, ACTIVE_TOKENS.color.surface)
			canvas_rect(c, row, ACTIVE_TOKENS.color.line)
		}
		marker := "*" if sel else " "
		canvas_text_px(c, row.x + 8, row.y + 8, marker, ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.label)
		canvas_text_clip(c, row.x + 22, row.y + 8, row.w - 32, a.devices[i], ACTIVE_TOKENS.color.ink if sel else ACTIVE_TOKENS.color.ink_dim)
	}
	if l.io_count == 0 {
		canvas_text_px(c, l.io_panel.x + 14, l.io_panel.y + 62, "no devices reported", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.label)
	}
	draw_toggle(c, l.jack, "JACK", a.jack_backend, is_hover(a, l.jack), true, ACTIVE_TOKENS.color.teal)
	draw_button(c, l.rescan, "RESCAN", false, is_hover(a, l.rescan), true, ACTIVE_TOKENS.color.ink)
	draw_button(c, l.lat_minus, "-", false, is_hover(a, l.lat_minus), a.latency_ms > 0, ACTIVE_TOKENS.color.ink)
	draw_button(c, l.lat_plus, "+", false, is_hover(a, l.lat_plus), a.latency_ms < 500, ACTIVE_TOKENS.color.ink)
	canvas_text_px_center(c, (l.lat_minus.x + l.lat_minus.w + l.lat_plus.x) * 0.5, l.lat_minus.y + 7, fmt.tprintf("LAT %.0f", a.latency_ms), ACTIVE_TOKENS.color.ink, ACTIVE_TOKENS.type.caption)
	canvas_text_px(c, l.io_panel.x + 14, l.io_panel.y + l.io_panel.h - 24, "click to select / ESC close", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
}

@(private)
draw_recent :: proc(a: ^App, c: ^Canvas) {
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(ACTIVE_TOKENS.color.bg, 0xC0))
	draw_panel(c, l.recent_panel, ACTIVE_TOKENS.color.surface, ACTIVE_TOKENS.color.amber)
	canvas_text_px(c, l.recent_panel.x + 16, l.recent_panel.y + 12, "RECENT PROJECTS", ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.label)
	canvas_text_px_right(c, l.recent_panel.x + l.recent_panel.w - 16, l.recent_panel.y + 12, "ESC", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)

	input_rect := l.recent_input
	canvas_fill(c, input_rect, ACTIVE_TOKENS.color.bg)
	canvas_rect(c, input_rect, with_alpha(ACTIVE_TOKENS.color.amber, 0xAA))
	canvas_text(c, input_rect.x + 8, input_rect.y + 7, "/", ACTIVE_TOKENS.color.amber)
	typed := string(a.recent_query_buf[:a.recent_query_len])
	canvas_text_clip(c, input_rect.x + 22, input_rect.y + 7, input_rect.w - 34, typed, ACTIVE_TOKENS.color.ink)
	cursor_x := input_rect.x + 22 + text_width(typed)
	if cursor_x < input_rect.x + input_rect.w - 8 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 7, 2, 14}, ACTIVE_TOKENS.color.amber)
	}

	if a.recent_filtered == 0 {
		msg := "no recent projects" if a.recent_count == 0 else "no matching project"
		canvas_text_px(c, l.recent_panel.x + 16, l.recent_panel.y + 84, msg, ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.label)
		if a.recent_count == 0 {
			canvas_text_px(c, l.recent_panel.x + 16, l.recent_panel.y + 104, "use : open project  (the window supplies the picker)", ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)
		}
	}
	for i in 0 ..< min(l.recent_count, MAX_RECENT) {
		row := l.recent_row[i]
		selected := i == a.recent_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill(c, row, ACTIVE_TOKENS.color.amber_wash)
			canvas_fill(c, Rect{row.x, row.y, 2, row.h}, ACTIVE_TOKENS.color.amber)
		} else if hov {
			canvas_fill(c, row, ACTIVE_TOKENS.color.surface_high)
		}
		path := app_recent_path(a, a.recent_items[i])
		canvas_text(c, row.x + 10, row.y + 8, ">", ACTIVE_TOKENS.color.amber if selected else ACTIVE_TOKENS.color.ink_muted)
		canvas_text_clip(c, row.x + 24, row.y + 8, row.w - 60, path, ACTIVE_TOKENS.color.ink if selected else ACTIVE_TOKENS.color.ink_dim)
		canvas_text_right(c, row.x + row.w - 8, row.y + 8, fmt.tprintf("%d", a.recent_items[i] + 1), ACTIVE_TOKENS.color.ink_muted)
	}
	canvas_text_px(c, l.recent_panel.x + 16, l.recent_panel.y + l.recent_panel.h - 20, "TYPE FILTER / ENTER OPEN / UP/DOWN SELECT / ESC CLOSE", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
}

@(private)
draw_bounce :: proc(a: ^App, c: ^Canvas) {
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(ACTIVE_TOKENS.color.bg, 0xD0))
	w: f32 = 460
	h: f32 = 172
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	draw_panel(c, r, ACTIVE_TOKENS.color.surface, ACTIVE_TOKENS.color.amber)
	canvas_text_px(c, r.x + 20, r.y + 16, "BOUNCING MIX", ACTIVE_TOKENS.color.amber, ACTIVE_TOKENS.type.label)
	canvas_text_px_right(c, r.x + r.w - 20, r.y + 16, "ESC", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
	canvas_text_px(c, r.x + 20, r.y + 36, "TRACK FX  >  MASTER COMP  >  REVERB  >  DELAY  >  WIDTH  >  LIMITER", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)

	bar := Rect{r.x + 20, r.y + 62, r.w - 40, 16}
	canvas_fill(c, bar, ACTIVE_TOKENS.color.surface_high)
	canvas_fill(c, Rect{bar.x, bar.y, bar.w * clamp(a.bounce_progress, 0, 1), bar.h}, ACTIVE_TOKENS.color.amber)
	canvas_rect(c, bar, ACTIVE_TOKENS.color.line_strong)

	canvas_text_px(c, r.x + 20, r.y + 90, fmt.tprintf("%.0f%%", a.bounce_progress * 100), ACTIVE_TOKENS.color.ink, ACTIVE_TOKENS.type.body)
	canvas_text_px_right(c, r.x + r.w - 20, r.y + 92, "writing bounce.wav", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
	canvas_text_px(c, r.x + 20, r.y + h - 24, "ESC dismiss / render continues in background", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
}
