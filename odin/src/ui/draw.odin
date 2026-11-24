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
	for i in a.view_first ..< a.view_first + app_view_count(a) {
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
	} else if a.mode == .Settings {
		draw_settings(a, c)
	} else if a.mode == .Cloud {
		draw_cloud(a, c)
	} else if a.mode == .Render {
		draw_render(a, c)
	}
}

@(private)
draw_header :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, l.header, T.color.surface)
	canvas_hline(c, 0, f32(a.width), l.header.h - 1, T.color.line_subtle)

	mode_text := "NORMAL"
	mode_col: Color = T.color.amber
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"; mode_col = T.color.amber
	case .Fx:
		mode_text = "FX RACK"; mode_col = T.color.amber
	case .Palette:
		mode_text = "COMMANDS"; mode_col = T.color.teal
	case .Io:
		mode_text = "INPUT"; mode_col = T.color.teal
	case .Recent:
		mode_text = "RECENT"; mode_col = T.color.teal
	case .Settings:
		mode_text = "SET"; mode_col = T.color.teal
	case .Cloud:
		mode_text = "CLOUD"; mode_col = T.color.teal
	case .Bounce:
		mode_text = "BOUNCE"; mode_col = T.color.red
	case .Render:
		mode_text = "RENDER"; mode_col = T.color.amber
	case .Track_Bounce:
		mode_text = "BOUNCE TO TRACK"; mode_col = T.color.amber
	case .Track_Delete:
		mode_text = "DELETE TRACK"; mode_col = T.color.red
	}
	if a.transport == .Recording {
		mode_text = "RECORDING"; mode_col = T.color.red
	}
	draw_badge(c, Rect{16, 13, 76, 30}, mode_text, mode_col)
}

@(private)
draw_transport :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	rec_on := a.transport == .Recording
	play_on := a.transport == .Playing
	live := a.transport != .Stopped

	draw_transport_button(c, l.rec, .Dot, "REC", rec_on, is_hover(a, l.rec), true, T.color.red)
	draw_transport_button(c, l.play, .Triangle, "PLAY", play_on, is_hover(a, l.play), true, T.color.teal)
	draw_transport_button(c, l.stop, .Square, "STOP", false, is_hover(a, l.stop), live, T.color.ink_dim)

	tc_col: Color = T.color.ink
	if rec_on {
		tc_col = T.color.red
	} else if play_on {
		tc_col = T.color.teal
	}
	canvas_text_px(c, 320, 7, timecode(a.frames, a.sample_rate), tc_col, T.type.readout, .Mono)
	state := "STOPPED"
	if rec_on {
		state = "RECORDING"
	} else if play_on {
		state = "PLAYING"
	}
	canvas_text_px(c, 322, 34, state, T.color.ink_muted, T.type.micro, .Medium)

	bpm_cx := (l.bpm_minus.x + l.bpm_minus.w + l.bpm_plus.x) * 0.5
	canvas_text_px_center(c, bpm_cx, 20, fmt.tprintf("%d BPM", a.bpm), T.color.ink_dim, T.type.caption, .Medium)
	draw_bar_button(c, l.bpm_minus, "-", false, is_hover(a, l.bpm_minus), a.bpm > 40, T.color.ink_dim)
	draw_bar_button(c, l.bpm_plus, "+", false, is_hover(a, l.bpm_plus), a.bpm < 240, T.color.ink_dim)

	draw_bar_button(c, l.bounce, "BOUNCE", a.mode == .Bounce, is_hover(a, l.bounce), a.transport != .Recording, T.color.amber)
	draw_bar_button(c, l.fx, "FX", a.mode == .Fx, is_hover(a, l.fx), true, T.color.amber)
	draw_bar_button(c, l.io, "I/O", a.mode == .Io, is_hover(a, l.io), true, T.color.amber)
	draw_bar_button(c, l.monitor, "MON", a.monitor, is_hover(a, l.monitor), true, T.color.teal)
	draw_bar_button(c, l.click, "CLICK", a.metronome, is_hover(a, l.click), true, T.color.teal)

	if a.mode == .Bounce {
		bar := Rect{l.bounce.x, l.bounce.y + l.bounce.h + 4, l.bounce.w, 3}
		canvas_fill_round(c, bar, 2, T.color.surface_high)
		canvas_fill_round(c, Rect{bar.x, bar.y, bar.w * clamp(a.bounce_progress, 0, 1), bar.h}, 2, T.color.amber)
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
draw_level_history :: proc(c: ^Canvas, r: Rect, hist: ^[HISTORY_LEN]f32, pos: int) {
	T := ACTIVE_TOKENS
	canvas_text_px(c, r.x, r.y, "INPUT LEVEL", T.color.ink_muted, 9, .Medium)
	for i in 1 ..< 4 {
		y := r.y + r.h * f32(i) / 4
		canvas_hline(c, r.x, r.x + r.w, y, with_alpha(T.color.line, 0x55))
	}
	pts: [HISTORY_LEN]Point
	for i in 0 ..< HISTORY_LEN {
		idx := (pos + 1 + i) % HISTORY_LEN
		norm := db_norm(hist[idx])
		pts[i] = Point{r.x + f32(i) / f32(HISTORY_LEN - 1) * r.w, r.y + 14 + (1 - norm) * (r.h - 18)}
	}
	canvas_area_gradient(c, pts[:], r.y + r.h, with_alpha(T.color.amber, 0x24), with_alpha(T.color.amber, 0x00))
	canvas_polyline(c, pts[:], with_alpha(T.color.amber, 0xCC), 1.2)
}

@(private)
draw_track :: proc(a: ^App, c: ^Canvas, i: int) {
	T := ACTIVE_TOKENS
	l := &a.layout
	t := &a.tracks[i]
	r := l.track[i]
	selected := a.selected == i
	recording := a.transport == .Recording && t.armed

	border := T.color.line_subtle
	if selected {
		border = T.color.border_amber
	}
	if t.armed {
		border = T.color.red
	}
	if recording {
		pulse := u8(0xE8)
		if !a.reduced_motion {
			pulse = u8(0x88 + 0x60 * (0.5 + 0.5 * math.sin(a.time * 7.0)))
		}
		border = with_alpha(T.color.red, pulse)
	}
	canvas_fill_round(c, r, T.radius.lg, T.color.surface)
	canvas_stroke_round(c, r, T.radius.lg, border, 1.5 if recording else 1)
	// A single top highlight gives the card a little elevation without a shadow.
	canvas_hline(c, r.x + 14, r.x + r.w - 14, r.y + 1, with_alpha(T.color.ink, 0x09))

	num_col: Color = T.color.amber if selected else T.color.ink_muted
	if t.armed {
		num_col = T.color.red
	}
	num_badge := Rect{r.x + 14, r.y + 11, 26, 26}
	canvas_fill_round(c, num_badge, 6, with_alpha(num_col, 0x18))
	canvas_text_px(c, num_badge.x + (26 - canvas_text_width(c, fmt.tprintf("%02d", i + 1), T.type.caption, .SemiBold)) * 0.5,
		num_badge.y + 6, fmt.tprintf("%02d", i + 1), num_col, T.type.caption, .SemiBold)

	name_right := l.input[i].x if a.take_count[i] == 0 else l.take[i].x
	name_w := max(name_right - (r.x + 48) - 6, 10)
	canvas_text_px_clip(c, r.x + 48, r.y + 17, name_w, t.name, T.color.ink, T.type.body, .Medium)

	if a.take_count[i] > 0 {
		tr := l.take[i]
		hov := is_hover(a, tr) && a.transport != .Recording
		canvas_fill_round(c, tr, 6, T.color.surface_raised if hov else T.color.bg)
		canvas_stroke_round(c, tr, 6, T.color.line_strong if hov else T.color.line_subtle, 1)
		label := "T?" if a.take_active[i] <= 0 else fmt.tprintf("T%d/%d", a.take_active[i], a.take_count[i])
		canvas_text_px_center(c, tr.x + tr.w * 0.5, text_middle_y(c, tr, label, T.type.caption, .Medium), label,
			T.color.amber if a.take_count[i] > 1 else T.color.ink_muted, T.type.caption, .Medium)
	}

	in_btn := l.input[i]
	hov_in := is_hover(a, in_btn) && a.transport != .Recording
	canvas_fill_round(c, in_btn, 6, T.color.surface_raised if hov_in else T.color.bg)
	canvas_stroke_round(c, in_btn, 6, T.color.line_strong if hov_in else T.color.line_subtle, 1)
	canvas_text_px_center(c, in_btn.x + in_btn.w * 0.5, text_middle_y(c, in_btn, "IN", T.type.caption, .Medium),
		fmt.tprintf("IN %d", t.input), T.color.amber if a.transport != .Recording else T.color.ink_muted, T.type.caption, .Medium)

	// FX summary: dots and short words, no chip chrome.
	fx_row := Rect{r.x + 14, r.y + 46, r.w - 28, 24}
	canvas_fill_round(c, fx_row, 6, T.color.bg)
	canvas_stroke_round(c, fx_row, 6, T.color.line_subtle, 1)
	canvas_text_px(c, fx_row.x + 8, fx_row.y + 6, "FX", T.color.ink_muted, 10, .Medium)
	chip_x := fx_row.x + 28
	chips := [4]struct {
		label: string,
		on:    bool,
		col:   Color,
	}{
		{"EQ", t.eq.enabled, T.color.amber},
		{"CMP", t.comp.enabled, T.color.amber},
		{"REV", t.send_reverb > 0.001, T.color.teal},
		{"DLY", t.send_delay > 0.001, T.color.teal},
	}
	for chip in chips {
		if chip.on {
			canvas_disc(c, chip_x + 2.5, fx_row.y + 12, 2.5, chip.col)
		} else {
			canvas_disc(c, chip_x + 2.5, fx_row.y + 12, 2, with_alpha(T.color.ink_muted, 0x66))
		}
		canvas_text_px(c, chip_x + 8, fx_row.y + 6, chip.label, chip.col if chip.on else T.color.ink_muted, 10, .Medium)
		chip_x += 8 + canvas_text_width(c, chip.label, 10, .Medium) + 10
	}

	draw_label_toggle(c, l.arm[i], "ARM", t.armed, is_hover(a, l.arm[i]), a.transport != .Recording, T.color.red)
	draw_label_toggle(c, l.solo[i], "SOLO", t.soloed, is_hover(a, l.solo[i]), true, T.color.teal)
	draw_label_toggle(c, l.mute[i], "MUTE", t.muted, is_hover(a, l.mute[i]), true, T.color.amber)

	if l.fader[i].w <= 0 {
		// Compact rack-focused strip: horizontal meter replaces the fader.
		bar := Rect{l.gr[i].x, l.gr[i].y + 4, l.gr[i].w - 62, 6}
		draw_h_meter(c, bar, db_norm(t.peak_db), T.color.amber if !t.muted else T.color.ink_muted)
		canvas_text_px_right(c, l.gr[i].x + l.gr[i].w, l.gr[i].y + 1, fmt.tprintf("%.0f dB", clamp(t.peak_db, -60, 0)), T.color.ink_muted, 10, .Mono)
		return
	}

	pr := l.pan[i]
	pcx := pr.x + pr.w * 0.5
	pcy := pr.y + 22
	draw_knob(c, pcx, pcy, 18, (t.pan + 1) * 0.5, !t.muted)
	canvas_text_px_center(c, pcx, pcy + 28, "PAN", T.color.ink_muted, 10, .Medium)
	canvas_text_px_center(c, pcx, pcy + 42, pan_label(t.pan), T.color.ink_dim, 10, .Mono)

	norm := clamp(t.level / 1.5, 0, 1)
	draw_fader(c, l.fader[i], norm, is_hover(a, l.fader[i]), !t.muted)
	draw_meter(c, l.meter[i], t.peak_db, t.peak_db, T.color.amber if !t.muted else T.color.ink_muted)
	level_db := -120.0 if t.level <= 0.0001 else 20.0 * math.log10(f64(t.level))
	canvas_text_px_center(c, l.fader[i].x + l.fader[i].w * 0.5, l.fader[i].y + l.fader[i].h + 10,
		fmt.tprintf("%.0f dB", clamp(level_db, -60, 6)), T.color.ink_muted, 10, .Mono)

	if t.comp.enabled && t.gr_db < -0.5 {
		canvas_text_px(c, l.gr[i].x, l.gr[i].y, fmt.tprintf("GR %.1f dB", t.gr_db), T.color.ink_muted, 10, .Mono)
	}

	hist_top := l.gr[i].y + 26
	hist_bottom := r.y + r.h - 18
	if hist_bottom - hist_top > 54 {
		draw_level_history(c, Rect{r.x + 14, hist_top, r.w - 28, hist_bottom - hist_top}, &a.peak_history[i], a.peak_history_pos)
	}
}

@(private)
draw_master :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, l.bottom, T.color.surface)
	canvas_hline(c, 0, f32(a.width), l.bottom.y, T.color.line_subtle)

	canvas_text_px(c, 16, l.bottom.y + 8, "PROJECT", T.color.ink_muted, 9, .Medium)
	canvas_text_px(c, 16, l.bottom.y + 21, app_project(a), T.color.ink, T.type.body, .Medium)
	canvas_text_px(c, 120, l.bottom.y + 23, fmt.tprintf("%d TRACK   %d ARM", a.track_count, arm_count(a)), T.color.ink_muted, T.type.micro, .Regular)

	hint := "SPACE play    R rec    B bounce    X fx    : commands"
	if a.width <= 1080 {
		hint = "SPACE play    R rec    : commands"
	}
	canvas_text_px_center(c, f32(a.width) * 0.5, l.bottom.y + 15, hint, with_alpha(T.color.ink_muted, 0xDD), T.type.caption, .Regular)

	r := l.master
	sel := a.selected >= MAX_TRACKS
	canvas_fill_round(c, r, T.radius.md, T.color.bg)
	canvas_stroke_round(c, r, T.radius.md, T.color.border_amber if sel else T.color.line, 1)
	canvas_text_px(c, r.x + 12, r.y + 8, "MASTER", T.color.amber, 10, .SemiBold)
	canvas_text_px(c, r.x + 66, r.y + 6, fmt.tprintf("%.1f dB", a.master.peak_db), T.color.ink, T.type.caption, .Mono)
	canvas_text_px(c, r.x + 134, r.y + 8, fmt.tprintf("GR %.1f", a.master.gr_db), T.color.ink_muted, 10, .Mono)
	canvas_text_px_right(c, r.x + r.w - 12, r.y + 8, fmt.tprintf("LIM %.1f", a.master.limiter.ceiling_db), T.color.ink_muted, 10, .Mono)
	draw_h_meter(c, l.master_meter, db_norm(a.master.peak_db), T.color.amber)
}

@(private)
draw_status :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, l.status, T.color.bg)
	canvas_hline(c, 0, f32(a.width), l.status.y, T.color.line_subtle)

	mode_text := "NORMAL"
	mode_col: Color = T.color.amber
	switch a.mode {
	case .Normal:
		mode_text = "NORMAL"; mode_col = T.color.amber
	case .Fx:
		mode_text = "FX"; mode_col = T.color.amber
	case .Palette:
		mode_text = "CMD"; mode_col = T.color.teal
	case .Io:
		mode_text = "I/O"; mode_col = T.color.teal
	case .Bounce:
		mode_text = "BOUNCE"; mode_col = T.color.red
	case .Recent:
		mode_text = "RECENT"; mode_col = T.color.teal
	case .Settings:
		mode_text = "SET"; mode_col = T.color.teal
	case .Cloud:
		mode_text = "CLOUD"; mode_col = T.color.teal
	case .Render:
		mode_text = "RENDER"; mode_col = T.color.amber
	case .Track_Bounce:
		mode_text = "BOUNCE TO TRACK"; mode_col = T.color.amber
	case .Track_Delete:
		mode_text = "DELETE TRACK"; mode_col = T.color.red
	}
	if a.transport == .Recording {
		mode_text = "REC"; mode_col = T.color.red
	}
	draw_badge(c, Rect{16, l.status.y + 5, 70, 20}, mode_text, mode_col)
	canvas_text_px(c, 98, l.status.y + 8, app_status(a), T.color.ink_dim, T.type.caption, .Regular)

	if a.toast_time > 0 {
		px := T.type.caption
		tw := canvas_text_width(c, app_toast(a), px, .Medium) + 28
		tx := clamp(f32(a.width) - tw - 280, 16, f32(a.width) - tw - 16)
		tr := Rect{tx, l.bottom.y - 38, tw, 28}
		canvas_shadow(c, tr, T.radius.md, 6, with_alpha(T.color.black, 0x44))
		canvas_fill_round(c, tr, T.radius.md, T.color.surface_high)
		canvas_stroke_round(c, tr, T.radius.md, with_alpha(T.color.amber, 0x77), 1)
		canvas_text_px(c, tr.x + 14, text_middle_y(c, tr, app_toast(a), px, .Medium), app_toast(a), T.color.amber, px, .Medium)
	}

	dev := app_device(a)
	if len(dev) == 0 {
		dev = "no input"
	}
	canvas_text_px_right(c, f32(a.width) - 16, l.status.y + 8, fmt.tprintf("%s   %d kHz", dev, a.sample_rate / 1000), T.color.ink_muted, T.type.caption, .Regular)
}

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
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_shadow(c, l.fx_panel, T.radius.lg, 10, with_alpha(T.color.black, 0x55))
	canvas_fill_round(c, l.fx_panel, T.radius.lg, T.color.surface)
	canvas_stroke_round(c, l.fx_panel, T.radius.lg, T.color.line, 1)
	canvas_text_px(c, l.fx_panel.x + 18, l.fx_panel.y + 17, "FX", T.color.amber, T.type.label, .SemiBold)

	for i in 0 ..< 5 {
		ch := app_fx_tab_channel(a, i)
		if ch < 0 {
			continue
		}
		label := fmt.tprintf("%d", ch + 1)
		if i == 4 {
			label = "MST"
		}
		active := a.fx_channel == ch
		tr := l.fx_tab[i]
		canvas_fill_round(c, tr, T.radius.sm, T.color.amber if active else T.color.surface_raised)
		canvas_stroke_round(c, tr, T.radius.sm, T.color.amber if active else T.color.line_subtle, 1)
		canvas_text_px_center(c, tr.x + tr.w * 0.5, text_middle_y(c, tr, label, T.type.caption, .Medium), label,
			T.color.on_amber if active else T.color.ink_dim, T.type.caption, .Medium)
		if fx_channel_active(a, ch) && !active {
			canvas_disc(c, tr.x + tr.w * 0.5, tr.y + tr.h + 5, 2, T.color.amber)
		}
	}

	// Close button: two AA strokes.
	cr := l.fx_close
	canvas_fill_round(c, cr, T.radius.sm, T.color.surface_raised if is_hover(a, cr) else T.color.bg)
	canvas_stroke_round(c, cr, T.radius.sm, T.color.line_subtle, 1)
	canvas_line_aa(c, cr.x + 10, cr.y + 10, cr.x + 18, cr.y + 18, T.color.ink_muted, 1.5)
	canvas_line_aa(c, cr.x + 18, cr.y + 10, cr.x + 10, cr.y + 18, T.color.ink_muted, 1.5)

	chan := "MASTER"
	if a.fx_channel < MAX_TRACKS {
		chan = fmt.tprintf("TRACK %d", a.fx_channel + 1)
	}
	canvas_text_px(c, l.fx_panel.x + 326, l.fx_panel.y + 18, chan, T.color.ink_dim, T.type.caption, .Medium)
	canvas_text_px_right(c, l.fx_panel.x + l.fx_panel.w - 54, l.fx_panel.y + 18, "DRAG  ·  SHIFT FINE  ·  TAB  ·  ESC", T.color.ink_muted, 9, .Regular)

	for mi in 0 ..< l.fx_module_count {
		p := l.fx_module[mi]
		m := l.fx_module_id[mi]
		canvas_fill_round(c, p, T.radius.md, T.color.surface_raised)
		canvas_stroke_round(c, p, T.radius.md, T.color.line_subtle, 1)
		canvas_text_px(c, p.x + 12, p.y + 14, fmt.tprintf("%02d", mi + 1), T.color.ink_muted, 9, .Medium)
		canvas_text_px(c, p.x + 34, p.y + 12, module_title(m), T.color.ink, T.type.label, .SemiBold)
		vis := Rect{p.x + 10, p.y + 40, p.w - 20, 46}
		draw_module_visual(a, c, m, vis)
		for k in 0 ..< l.knob_count {
			tt := l.knob_target[k]
			if tt.module != m { continue }
			kr := l.knob[k]
			cx := kr.x + kr.w * 0.5
			cy := kr.y + kr.h * 0.5
			lo, hi, log := knob_spec(m, tt.param)
			v := app_knob_value(a, tt)
			n := value_to_norm(v, lo, hi, log)
			enabled := bypass_state(a, m)
			draw_knob(c, cx, cy, 17, n, enabled)
			canvas_text_px_center(c, cx, cy + 22, param_label(m, tt.param), T.color.ink_muted, 10, .Medium)
			canvas_text_px_center(c, cx, cy + 34, knob_value_text(m, tt.param, v), T.color.ink if enabled else T.color.ink_muted, 10, .Mono)
			if a.fx_focus == k {
				canvas_stroke_round(c, Rect{kr.x - 3, kr.y - 3, kr.w + 6, kr.h + 6}, T.radius.sm, T.color.amber, 1.5)
			}
		}
	}
	for i in 0 ..< l.toggle_count {
		tt := l.toggle_target[i]
		bypassed := app_toggle_value(a, tt)
		lit := toggle_lit(a, tt)
		label := ("BYP" if bypassed else "ON") if tt.param == 0 else "PING"
		col: Color = T.color.amber
		if tt.module == .DELAY {
			col = T.color.teal
		}
		draw_toggle(c, l.toggle[i], label, lit, is_hover(a, l.toggle[i]), true, col)
		if a.fx_focus == l.knob_count + i {
			canvas_stroke_round(c, Rect{l.toggle[i].x - 3, l.toggle[i].y - 3, l.toggle[i].w + 6, l.toggle[i].h + 6}, T.radius.sm, T.color.amber, 1.5)
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

@(private)
command_hint :: proc(kind: Command_Kind) -> string {
	#partial switch kind {
	case .Play, .Stop, .Pause, .Set_Marker, .Clear_Marker, .Goto_Marker, .Audition, .Record_Now, .Preroll_Next, .Record_Start, .Record_Stop, .Seek, .Seek_Zero, .Shuttle_Back, .Shuttle_Forward, .Jog_Back, .Jog_Forward:
		return "transport"
	case .Bounce, .Render_Mix, .Render_File, .Bounce_Tracks, .Bounce_To_Track, .Delete_Track:
		return "render"
	case .Track_Add, .Track_Remove, .Rename_Track, .Apply_Track_Name, .Zoom_In, .Zoom_Out, .Page_Next, .Page_Prev:
		return "tracks"
	case .Save, .Load, .Save_As, .Rename_Project, .Apply_Project_Name:
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
	case .Settings:
		return "ui"
	case .Choose_Save_Dir, .Apply_Save_Dir, .Reset_Save_Dir:
		return "storage"
	case .Cloud, .Cloud_Open, .Cloud_Connect, .Cloud_Disconnect, .Cloud_Backup, .Cloud_Restore, .Cloud_List, .Cloud_Save_Credentials:
		return "cloud"
	case .Select_Device:
		return "audio"
	case .Fx, .Io, .Arm_All, .Clear_Arms, .Panic:
		return "ui"
	}
	return ""
}

@(private)
draw_palette :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xD0))
	canvas_shadow(c, l.palette, T.radius.xl, 14, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, l.palette, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, l.palette, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, l.palette.x + 20, l.palette.y + 17, "Commands", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px_right(c, l.palette.x + l.palette.w - 20, l.palette.y + 21, "ESC", T.color.ink_muted, T.type.caption, .Medium)

	input_rect := l.palette_input
	canvas_fill_round(c, input_rect, T.radius.md, T.color.bg)
	canvas_stroke_round(c, input_rect, T.radius.md, with_alpha(T.color.amber, 0xAA), 1)
	canvas_text_px(c, input_rect.x + 12, input_rect.y + 9, ":", T.color.amber, T.type.body, .Medium)
	typed := string(a.palette_buf[:a.palette_len])
	canvas_text_px(c, input_rect.x + 26, input_rect.y + 9, typed, T.color.ink, T.type.body, .Regular)
	cursor_x := input_rect.x + 26 + canvas_text_width(c, typed, T.type.body, .Regular)
	if cursor_x < input_rect.x + input_rect.w - 10 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 9, 2, 18}, T.color.amber)
	}

	if a.palette_count == 0 {
		canvas_text_px(c, l.palette.x + 20, l.palette.y + 100, "No matching command", T.color.ink_muted, T.type.body, .Regular)
	}
	for i in 0 ..< l.palette_count {
		row := l.palette_row[i]
		idx := a.palette_scroll + i
		selected := idx == a.palette_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill_round(c, row, T.radius.sm, T.color.amber_bg)
		} else if hov {
			canvas_fill_round(c, row, T.radius.sm, T.color.surface_raised)
		}
		cmd := PALETTE_COMMANDS[a.palette_items[idx]]
		if selected {
			canvas_disc(c, row.x + 12, row.y + row.h * 0.5, 3, T.color.amber)
		}
		name_weight: Font_Weight = .Regular
		if selected {
			name_weight = .Medium
		}
		canvas_text_px_clip(c, row.x + 24, row.y + 8, row.w - 130, cmd.name,
			T.color.ink if selected else T.color.ink_dim, T.type.body, name_weight)
		canvas_text_px_right(c, row.x + row.w - 12, row.y + 9, command_hint(cmd.kind), T.color.ink_muted, T.type.caption, .Regular)
	}
	canvas_text_px(c, l.palette.x + 20, l.palette.y + l.palette.h - 24, "ENTER run    ↑↓ select    ESC close", T.color.ink_muted, T.type.caption, .Regular)
	if a.palette_count > l.palette_count {
		canvas_text_px_right(c, l.palette.x + l.palette.w - 20, l.palette.y + l.palette.h - 24, fmt.tprintf("%d/%d", a.palette_scroll + 1, a.palette_count), T.color.ink_muted, T.type.caption, .Mono)
	}
}

@(private)
draw_io :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xB0))
	canvas_shadow(c, l.io_panel, T.radius.xl, 14, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, l.io_panel, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, l.io_panel, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, l.io_panel.x + 20, l.io_panel.y + 18, "Input Devices", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px(c, l.io_panel.x + 20, l.io_panel.y + 44, platform_audio_sources_subtitle(), T.color.ink_muted, T.type.caption, .Regular)

	l.io_count = min(len(a.devices), MAX_DEVICES)
	for i in 0 ..< l.io_count {
		row := l.io_row[i]
		sel := i == a.device_index
		hov := is_hover(a, row)
		if sel {
			canvas_fill_round(c, row, T.radius.sm, T.color.amber_bg)
			canvas_stroke_round(c, row, T.radius.sm, with_alpha(T.color.amber, 0x77), 1)
		} else if hov {
			canvas_fill_round(c, row, T.radius.sm, T.color.surface_raised)
		}
		if sel {
			canvas_disc(c, row.x + 12, row.y + row.h * 0.5, 3, T.color.amber)
		}
		canvas_text_px_clip(c, row.x + 24, row.y + 8, row.w - 40, a.devices[i],
			T.color.ink if sel else T.color.ink_dim, T.type.body, .Regular)
	}
	if l.io_count == 0 {
		canvas_text_px(c, l.io_panel.x + 20, l.io_panel.y + 84, "No devices reported", T.color.ink_muted, T.type.body, .Regular)
	}
	draw_toggle(c, l.jack, "JACK", a.jack_backend, is_hover(a, l.jack), true, T.color.teal)
	draw_button(c, l.rescan, "RESCAN", false, is_hover(a, l.rescan), true, T.color.ink)
	draw_button(c, l.lat_minus, "-", false, is_hover(a, l.lat_minus), a.latency_ms > 0, T.color.ink)
	draw_button(c, l.lat_plus, "+", false, is_hover(a, l.lat_plus), a.latency_ms < 500, T.color.ink)
	canvas_text_px_center(c, (l.lat_minus.x + l.lat_minus.w + l.lat_plus.x) * 0.5, l.lat_minus.y + 9,
		fmt.tprintf("LAT %.0f", a.latency_ms), T.color.ink, T.type.caption, .Mono)
	canvas_text_px(c, l.io_panel.x + 20, l.io_panel.y + l.io_panel.h - 30, "Click to select    ESC close", T.color.ink_muted, T.type.caption, .Regular)
}

@(private)
draw_recent :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	l := &a.layout
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xC0))
	canvas_shadow(c, l.recent_panel, T.radius.xl, 14, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, l.recent_panel, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, l.recent_panel, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, l.recent_panel.x + 20, l.recent_panel.y + 17, "Recent Projects", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px_right(c, l.recent_panel.x + l.recent_panel.w - 20, l.recent_panel.y + 21, "ESC", T.color.ink_muted, T.type.caption, .Medium)

	input_rect := l.recent_input
	canvas_fill_round(c, input_rect, T.radius.md, T.color.bg)
	canvas_stroke_round(c, input_rect, T.radius.md, with_alpha(T.color.amber, 0xAA), 1)
	canvas_text_px(c, input_rect.x + 12, input_rect.y + 9, "/", T.color.amber, T.type.body, .Medium)
	typed := string(a.recent_query_buf[:a.recent_query_len])
	canvas_text_px(c, input_rect.x + 26, input_rect.y + 9, typed, T.color.ink, T.type.body, .Regular)
	cursor_x := input_rect.x + 26 + canvas_text_width(c, typed, T.type.body, .Regular)
	if cursor_x < input_rect.x + input_rect.w - 10 && (a.reduced_motion || int(a.time * 2) % 2 == 0) {
		canvas_fill(c, Rect{cursor_x + 1, input_rect.y + 9, 2, 18}, T.color.amber)
	}

	if a.recent_filtered == 0 {
		msg := "No recent projects" if a.recent_count == 0 else "No matching project"
		canvas_text_px(c, l.recent_panel.x + 20, l.recent_panel.y + 100, msg, T.color.ink_muted, T.type.body, .Regular)
		if a.recent_count == 0 {
			canvas_text_px(c, l.recent_panel.x + 20, l.recent_panel.y + 124, "Use : open project to browse.", T.color.ink_dim, T.type.caption, .Regular)
		}
	}
	for i in 0 ..< min(l.recent_count, MAX_RECENT) {
		row := l.recent_row[i]
		selected := i == a.recent_sel
		hov := is_hover(a, row)
		if selected {
			canvas_fill_round(c, row, T.radius.sm, T.color.amber_bg)
		} else if hov {
			canvas_fill_round(c, row, T.radius.sm, T.color.surface_raised)
		}
		path := app_recent_path(a, a.recent_items[i])
		if selected {
			canvas_disc(c, row.x + 12, row.y + row.h * 0.5, 3, T.color.amber)
		}
		canvas_text_px_clip(c, row.x + 24, row.y + 8, row.w - 60, path, T.color.ink if selected else T.color.ink_dim, T.type.body, .Regular)
		canvas_text_px_right(c, row.x + row.w - 12, row.y + 9, fmt.tprintf("%d", a.recent_items[i] + 1), T.color.ink_muted, T.type.caption, .Mono)
	}
	canvas_text_px(c, l.recent_panel.x + 20, l.recent_panel.y + l.recent_panel.h - 30, "TYPE filter    ENTER open    ↑↓ select    ESC close", T.color.ink_muted, T.type.caption, .Regular)
}

@(private)
draw_settings :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xC0))
	w: f32 = 660
	h: f32 = 500
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	canvas_shadow(c, r, T.radius.xl, 16, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, r, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, r, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, r.x + 24, r.y + 20, "Settings", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px(c, r.x + 112, r.y + 24, "Machine preferences", T.color.ink_muted, T.type.caption, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, r.y + 24, "ESC", T.color.ink_muted, T.type.caption, .Medium)

	x := r.x + 24
	y := r.y + 60
	canvas_text_px(c, x, y, "STORAGE", T.color.ink_muted, T.type.caption, .SemiBold)
	y += 24
	canvas_text_px(c, x, y, "Project folder", T.color.ink, T.type.body, .Medium)
	y += 20
	field := Rect{x, y, r.w - 48, 34}
	canvas_fill_round(c, field, T.radius.sm, T.color.bg)
	canvas_stroke_round(c, field, T.radius.sm, with_alpha(T.color.amber, 0x88), 1)
	canvas_text_px(c, field.x + 12, field.y + 8, "$", T.color.amber, T.type.body, .SemiBold)
	path := app_settings_path(a) if a.settings_path_edit else app_save_dir(a)
	if path == "" {
		path = "not set"
	}
	canvas_text_px_clip(c, field.x + 28, field.y + 8, field.w - 42, path, T.color.ink, T.type.caption, .Regular)
	y += 44
	draw_button(c, Rect{x, y, 88, 26}, "BROWSE", false, false, true, T.color.ink)
	draw_button(c, Rect{x + 96, y, 72, 26}, "APPLY", false, false, true, T.color.teal)
	draw_button(c, Rect{x + 176, y, 80, 26}, "DEFAULT", false, false, true, T.color.ink)
	y += 42
	canvas_text_px_clip(c, x, y, r.w - 48, "project.json, takes and bounce.wav are written here.", T.color.ink_muted, T.type.caption, .Regular)

	y += 30
	canvas_text_px(c, x, y, "AUDIO", T.color.ink_muted, T.type.caption, .SemiBold)
	y += 22
	canvas_text_px(c, x, y, "Input device", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, app_device(a), T.color.ink_dim, T.type.caption, .Regular)
	y += 22
	canvas_text_px(c, x, y, "Capture backend", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, "JACK" if a.jack_backend else platform_audio_backend_name(), T.color.ink_dim, T.type.caption, .Regular)
	y += 22
	canvas_text_px(c, x, y, "Input latency", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, fmt.tprintf("%.0f ms", a.latency_ms), T.color.ink_dim, T.type.caption, .Mono)
	y += 22
	canvas_text_px(c, x, y, "Direct monitoring", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, "On" if a.monitor else "Off", T.color.ink_dim, T.type.caption, .Regular)

	y += 30
	canvas_text_px(c, x, y, "APPEARANCE", T.color.ink_muted, T.type.caption, .SemiBold)
	y += 22
	canvas_text_px(c, x, y, "High contrast", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, "On" if a.high_contrast else "Off", T.color.ink_dim, T.type.caption, .Regular)
	y += 22
	canvas_text_px(c, x, y, "Reduced motion", T.color.ink, T.type.body, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, "On" if a.reduced_motion else "Off", T.color.ink_dim, T.type.caption, .Regular)

	canvas_text_px(c, x, r.y + h - 30, "ENTER edit path    B browse    A apply    ESC close", T.color.ink_muted, T.type.caption, .Regular)
}

@(private)
draw_cloud :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xC0))
	w: f32 = 620
	h: f32 = 460
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	canvas_shadow(c, r, T.radius.xl, 14, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, r, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, r, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, r.x + 20, r.y + 18, "Cloud Projects", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px(c, r.x + 20, r.y + 44, "Google Drive · hidden app data", T.color.ink_muted, T.type.caption, .Regular)
	canvas_text_px_right(c, r.x + r.w - 20, r.y + 22, "ESC", T.color.ink_muted, T.type.caption, .Medium)
	if !a.cloud_connected {
		canvas_text_px(c, r.x + 20, r.y + 86, "Connect Google Drive in Settings.", T.color.ink_dim, T.type.body, .Regular)
	} else if a.cloud_project_count == 0 {
		canvas_text_px(c, r.x + 20, r.y + 86, "No cloud projects yet.", T.color.ink_muted, T.type.body, .Regular)
	}
	for i in 0 ..< min(a.cloud_project_count, 10) {
		row := Rect{r.x + 16, r.y + 78 + f32(i) * 34, r.w - 32, 30}
		sel := i == a.cloud_selected
		if sel {
			canvas_fill_round(c, row, T.radius.sm, T.color.amber_bg)
			canvas_disc(c, row.x + 12, row.y + 15, 3, T.color.amber)
		}
		p := &a.cloud_projects[i]
		canvas_text_px_clip(c, row.x + 24, row.y + 7, row.w - 140, cloud_view_name(p),
			T.color.ink if sel else T.color.ink_dim, T.type.body, .Regular)
		canvas_text_px_right(c, row.x + row.w - 12, row.y + 8, cloud_time_text(p.modified), T.color.ink_muted, T.type.caption, .Mono)
	}
	canvas_text_px(c, r.x + 20, r.y + h - 30, "ENTER restore    U back up    R refresh    ESC close", T.color.ink_muted, T.type.caption, .Regular)
}

@(private)
draw_render_handle :: proc(c: ^Canvas, x, cy: f32, selected, dragging: bool) {
	T := ACTIVE_TOKENS
	if selected || dragging {
		canvas_fill_round(c, Rect{x - 9, cy - 15, 18, 30}, 4, with_alpha(T.color.amber, 0x28))
		canvas_fill_round(c, Rect{x - 7, cy - 14, 14, 28}, 3, T.color.amber_bright)
		canvas_fill_round(c, Rect{x - 5, cy - 12, 10, 24}, 2, T.color.amber)
		canvas_fill_round(c, Rect{x - 1.5, cy - 6, 1, 12}, 0.5, with_alpha(T.color.bg, 0xD0))
		canvas_fill_round(c, Rect{x + 1.5, cy - 6, 1, 12}, 0.5, with_alpha(T.color.bg, 0xD0))
	} else {
		canvas_fill_round(c, Rect{x - 7, cy - 14, 14, 28}, 3, with_alpha(T.color.amber, 0xB0))
		canvas_fill_round(c, Rect{x - 6, cy - 13, 12, 26}, 2, T.color.surface)
		canvas_fill_round(c, Rect{x - 1, cy - 6, 1, 12}, 0.5, with_alpha(T.color.amber, 0xD0))
		canvas_fill_round(c, Rect{x + 2, cy - 6, 1, 12}, 0.5, with_alpha(T.color.amber, 0xD0))
	}
}

@(private)
draw_render :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xD0))
	w: f32 = 560
	h: f32 = 270
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	canvas_shadow(c, r, T.radius.xl, 16, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, r, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, r, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, r.x + 24, r.y + 20, "Render Mix", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px(c, r.x + 142, r.y + 24, "RANGE + FORMAT", T.color.ink_muted, T.type.caption, .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, r.y + 24, "ESC", T.color.ink_muted, T.type.caption, .Medium)

	y := r.y + 60
	canvas_text_px(c, r.x + 24, y, "RANGE", T.color.ink_muted, T.type.caption, .SemiBold)
	canvas_text_px_right(c, r.x + r.w - 24, y, "drag either handle", T.color.ink_muted, T.type.caption, .Regular)
	track := Rect{r.x + 33, y + 30, r.w - 66, 6}
	canvas_fill_round(c, track, 3, T.color.surface_high)
	from_x := track.x if a.render_duration <= 0 else track.x + track.w * clamp(a.render_from / a.render_duration, 0, 1)
	to_x := track.x if a.render_duration <= 0 else track.x + track.w * clamp(a.render_to / a.render_duration, 0, 1)
	if a.render_duration > 0 && to_x > from_x {
		canvas_fill_round(c, Rect{from_x, track.y, to_x - from_x, track.h}, 3, with_alpha(T.color.amber, 0xE6))
	}
	cy := track.y + track.h * 0.5
	if a.render_duration > 0 {
		if a.render_sel == 0 || a.render_drag == .From {
			draw_render_handle(c, to_x, cy, a.render_sel == 1, a.render_drag == .To)
			draw_render_handle(c, from_x, cy, a.render_sel == 0, a.render_drag == .From)
		} else {
			draw_render_handle(c, from_x, cy, a.render_sel == 0, a.render_drag == .From)
			draw_render_handle(c, to_x, cy, a.render_sel == 1, a.render_drag == .To)
		}
	}
	y += 54
	canvas_text_px(c, r.x + 24, y, fmt.tprintf("FROM %s", render_time_text(a.render_from)), T.color.amber if a.render_sel == 0 else T.color.ink_dim, T.type.caption, .SemiBold if a.render_sel == 0 else .Regular)
	canvas_text_px_right(c, r.x + r.w - 24, y, fmt.tprintf("TO %s", render_time_text(a.render_to)), T.color.amber if a.render_sel == 1 else T.color.ink_dim, T.type.caption, .SemiBold if a.render_sel == 1 else .Regular)

	y += 20
	sel := a.render_sel == 2
	format_row := Rect{r.x + 24, y, r.w - 48, 29}
	if sel {
		canvas_fill_round(c, format_row, T.radius.sm, T.color.amber_bg)
		canvas_stroke_round(c, format_row, T.radius.sm, T.color.amber_dim, 1)
	}
	canvas_text_px(c, format_row.x + 10, format_row.y + 7, "FORMAT", T.color.amber if sel else T.color.ink_muted, T.type.caption, .SemiBold)
	canvas_text_px(c, format_row.x + 74, format_row.y + 7, "WAV", T.color.ink_dim, T.type.caption, .SemiBold)
	chips := [RENDER_FORMAT_COUNT]string{"32-BIT FLOAT", "24-BIT", "16-BIT"}
	for chip, i in chips {
		on := int(a.render_format) == i
		cr := Rect{format_row.x + 116 + f32(i) * 92, format_row.y + 3, 86, 23}
		canvas_fill_round(c, cr, T.radius.sm, T.color.amber if on else T.color.surface_high)
		canvas_text_px_center(c, cr.x + cr.w * 0.5, cr.y + 5, chip, T.color.bg if on else T.color.ink_muted, T.type.micro, .SemiBold)
	}
	y += 38
	detail := render_format_label(a.render_format)
	if a.render_duration > 0 {
		detail = fmt.tprintf("%s  ·  stereo  ·  %d kHz  ·  full mix %s", detail, a.sample_rate / 1000, render_time_text(a.render_duration))
	}
	canvas_text_px(c, r.x + 24, y, detail, T.color.ink_muted, T.type.caption, .Regular)

	by := r.y + h - 72
	canvas_hline(c, r.x + 24, r.x + r.w - 24, by - 12, T.color.line_subtle)
	draw_button(c, Rect{r.x + 24, by, 100, 28}, "RENDER...", false, false, true, T.color.amber)
	draw_button(c, Rect{r.x + 132, by, 88, 28}, "CANCEL", false, false, true, T.color.ink_dim)
	canvas_text_px(c, r.x + 24, r.y + h - 30, "J/K row   H/L nudge (SHIFT 5s)   ENTER render   ESC close", T.color.ink_muted, T.type.caption, .Regular)
}

@(private)
draw_bounce :: proc(a: ^App, c: ^Canvas) {
	T := ACTIVE_TOKENS
	canvas_fill(c, Rect{0, 0, f32(a.width), f32(a.height)}, with_alpha(T.color.bg, 0xD0))
	w: f32 = 520
	h: f32 = 210
	r := Rect{(f32(a.width) - w) * 0.5, (f32(a.height) - h) * 0.5, w, h}
	canvas_shadow(c, r, T.radius.xl, 16, with_alpha(T.color.black, 0x66))
	canvas_fill_round(c, r, T.radius.xl, T.color.surface)
	canvas_stroke_round(c, r, T.radius.xl, T.color.line, 1)
	canvas_text_px(c, r.x + 24, r.y + 20, "Bouncing Mix", T.color.ink, T.type.title, .SemiBold)
	canvas_text_px_right(c, r.x + r.w - 24, r.y + 24, "ESC", T.color.ink_muted, T.type.caption, .Medium)
	canvas_text_px(c, r.x + 24, r.y + 52, "TRACK FX  >  MASTER COMP  >  REVERB  >  DELAY  >  WIDTH  >  LIMITER", T.color.ink_muted, T.type.caption, .Regular)

	bar := Rect{r.x + 24, r.y + 84, r.w - 48, 10}
	canvas_fill_round(c, bar, 5, T.color.surface_high)
	canvas_fill_round(c, Rect{bar.x, bar.y, bar.w * clamp(a.bounce_progress, 0, 1), bar.h}, 5, T.color.amber)
	canvas_text_px(c, r.x + 24, r.y + 108, fmt.tprintf("%.0f%%", a.bounce_progress * 100), T.color.ink, T.type.readout, .SemiBold)
	canvas_text_px_right(c, r.x + r.w - 24, r.y + 118, "writing bounce.wav", T.color.ink_muted, T.type.caption, .Regular)
	canvas_text_px(c, r.x + 24, r.y + h - 30, "ESC dismiss  ·  render continues in background", T.color.ink_muted, T.type.caption, .Regular)
}
