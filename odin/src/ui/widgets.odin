// Flat instrument-panel widgets drawn on the software canvas.

package ui

import "core:math"

draw_panel :: proc(c: ^Canvas, r: Rect, fill: Color = 0, border: Color = 0) {
	canvas_fill(c, r, fill if fill != 0 else ACTIVE_TOKENS.color.surface)
	if (border >> 24) != 0 {
		canvas_rect(c, r, border)
	}
}

draw_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	fill: Color = ACTIVE_TOKENS.color.surface_raised
	border: Color = ACTIVE_TOKENS.color.line
	ink: Color = ACTIVE_TOKENS.color.ink_dim
	if enabled {
		if active {
			fill = with_alpha(acc, 0xF0)
			border = acc
			ink = ACTIVE_TOKENS.color.white
		} else if hover {
			fill = ACTIVE_TOKENS.color.surface_high
			border = with_alpha(acc, 0x88)
			ink = ACTIVE_TOKENS.color.ink
		} else {
			border = ACTIVE_TOKENS.color.line_strong
			ink = ACTIVE_TOKENS.color.ink_dim
		}
	} else {
		ink = ACTIVE_TOKENS.color.ink_muted
	}
	canvas_fill(c, r, fill)
	canvas_rect(c, r, border)
	scale := 1
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height(scale)) * 0.5, label, ink, scale)
}

draw_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	fill: Color = ACTIVE_TOKENS.color.surface_raised
	border: Color = ACTIVE_TOKENS.color.line
	ink: Color = ACTIVE_TOKENS.color.ink_muted
	if enabled {
		ink = ACTIVE_TOKENS.color.ink_dim
		border = ACTIVE_TOKENS.color.line_strong
		if hover {
			fill = ACTIVE_TOKENS.color.surface_high
			ink = ACTIVE_TOKENS.color.ink
		}
		if on {
			fill = with_alpha(acc, 0x30)
			border = with_alpha(acc, 0xCC)
			ink = acc
		}
	}
	canvas_fill(c, r, fill)
	canvas_rect(c, r, border)
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height()) * 0.5, label, ink)
}

draw_meter :: proc(c: ^Canvas, r: Rect, db, peak_db: f32, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface_raised)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	segments := 24
	gap: f32 = 2
	seg_h := (r.h - 4 - f32(segments - 1) * gap) / f32(segments)
	norm := db_norm(db)
	peak_norm := db_norm(peak_db)
	lit := int(math.ceil(norm * f32(segments)))
	peak_seg := int(math.ceil(peak_norm * f32(segments))) - 1
	for i in 0 ..< segments {
		y := r.y + r.h - 2 - (f32(i) + 1) * (seg_h + gap)
		x := r.x + 2
		w := r.w - 4
		bg := with_alpha(ACTIVE_TOKENS.color.surface_high, 0xAA)
		canvas_fill(c, Rect{x, y, w, seg_h}, bg)
		if i < lit {
			col := acc
			if i >= segments - 4 {
				col = ACTIVE_TOKENS.color.red
			} else if i >= segments - 8 {
				col = ACTIVE_TOKENS.color.amber_bright
			}
			canvas_fill(c, Rect{x, y, w, seg_h}, col)
		}
		if i == peak_seg && peak_norm > 0.01 {
			canvas_fill(c, Rect{x, y, w, max(seg_h, 1)}, with_alpha(ACTIVE_TOKENS.color.ink, 0xCC))
		}
	}
}

draw_gr :: proc(c: ^Canvas, r: Rect, gr_db: f32) {
	// One thin reduction rail; label left, fill right-to-left like a meter.
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	canvas_text_px(c, r.x + 3, r.y + 1, "GR", ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.micro)
	bx := r.x + 18
	bw := r.w - 20
	by := r.y + r.h * 0.5 - 1
	canvas_fill(c, Rect{bx, by, bw, 3}, ACTIVE_TOKENS.color.surface_high)
	amount := clamp(-gr_db / 24.0, 0, 1)
	canvas_fill(c, Rect{bx + bw - bw * amount, by, bw * amount, 3}, ACTIVE_TOKENS.color.amber)
}

draw_fader :: proc(c: ^Canvas, r: Rect, norm: f32, hover: bool, enabled: bool = true) {
	track_w: f32 = 4
	tx := r.x + r.w * 0.5 - track_w * 0.5
	// A hardware fader: thin rail, unity tick, solid thumb. No fill — the
	// meter next to it carries level; the fader only carries position.
	canvas_fill(c, Rect{tx, r.y, track_w, r.h}, ACTIVE_TOKENS.color.surface_high)
	canvas_rect(c, Rect{tx - 1, r.y, track_w + 2, r.h}, ACTIVE_TOKENS.color.line)
	unity_y := r.y + 2 + (r.h - 4) * (1.0 - 1.0 / 1.5)
	canvas_hline(c, tx - 6, tx + track_w + 6, unity_y, with_alpha(ACTIVE_TOKENS.color.ink_dim, 0x88))
	thumb_y := r.y + 2 + (r.h - 8) * (1.0 - clamp(norm, 0, 1))
	thumb_col: Color = ACTIVE_TOKENS.color.amber_bright if hover && enabled else ACTIVE_TOKENS.color.amber
	if !enabled {
		thumb_col = ACTIVE_TOKENS.color.ink_muted
	}
	thumb := Rect{r.x + 1, thumb_y, r.w - 2, 8}
	canvas_fill(c, thumb, thumb_col)
	canvas_rect(c, thumb, ACTIVE_TOKENS.color.black)
	canvas_hline(c, thumb.x + 2, thumb.x + thumb.w - 2, thumb.y + 4, with_alpha(ACTIVE_TOKENS.color.black, 0x66))
}

draw_knob :: proc(c: ^Canvas, cx, cy, radius, norm: f32, enabled: bool = true, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	start := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	n := clamp(norm, 0, 1)
	// Track ring in neutral, travelled arc in quiet amber, pointer in ink.
	// The restraint keeps a row of knobs from reading as a row of gauges.
	canvas_circle(c, cx, cy, radius, with_alpha(ACTIVE_TOKENS.color.line_strong, 0xCC))
	canvas_arc(c, cx, cy, radius, start, start + sweep, with_alpha(ACTIVE_TOKENS.color.ink_muted, 0x55), 2)
	if enabled {
		canvas_arc(c, cx, cy, radius, start, start + sweep * n, with_alpha(acc, 0xCC), 2)
	}
	canvas_circle_fill(c, cx, cy, max(radius - 5, 2), ACTIVE_TOKENS.color.surface_raised)
	angle := start + sweep * n
	ix := cx + math.cos(angle) * (radius - 4)
	iy := cy + math.sin(angle) * (radius - 4)
	canvas_line(c, cx, cy, ix, iy, ACTIVE_TOKENS.color.ink if enabled else ACTIVE_TOKENS.color.ink_muted)
	canvas_circle_fill(c, cx, cy, 1.5, acc if enabled else ACTIVE_TOKENS.color.ink_muted)
}

draw_badge :: proc(c: ^Canvas, r: Rect, label: string, accent: Color) {
	canvas_fill(c, r, with_alpha(accent, 0x24))
	canvas_rect(c, r, with_alpha(accent, 0x99))
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height()) * 0.5, label, accent)
}

draw_hint :: proc(c: ^Canvas, x, y: f32, key, text: string) {
	kw := text_width(key) + 8
	canvas_fill(c, Rect{x, y - 2, kw, 16}, ACTIVE_TOKENS.color.surface_high)
	canvas_rect(c, Rect{x, y - 2, kw, 16}, ACTIVE_TOKENS.color.line)
	canvas_text(c, x + 4, y, key, ACTIVE_TOKENS.color.amber)
	canvas_text(c, x + kw + 6, y, text, ACTIVE_TOKENS.color.ink_muted)
}

draw_eq_curve :: proc(c: ^Canvas, r: Rect, low_db, mid_db, high_db: f32, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	mid_y := r.y + r.h * 0.5
	canvas_hline(c, r.x + 4, r.x + r.w - 4, mid_y, with_alpha(ACTIVE_TOKENS.color.line_strong, 0x88))
	n := int(r.w - 8)
	for i in 0 ..< n {
		t := f32(i) / f32(max(n - 1, 1))
		// Rough visual: shelves at the ends, bell in the middle.
		low_w := 1.0 - clamp(t / 0.38, 0, 1)
		high_w := clamp((t - 0.62) / 0.38, 0, 1)
		bell := math.exp(-math.pow((t - 0.5) / 0.16, 2.0))
		db := low_db * low_w + high_db * high_w + mid_db * bell
		y := mid_y - clamp(db, -18, 18) / 18.0 * (r.h * 0.42)
		canvas_fill(c, Rect{r.x + 4 + f32(i), y, 1, 1}, ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted)
	}
	canvas_text_px(c, r.x + 4, r.y + 2, "+18", ACTIVE_TOKENS.color.ink_muted, 8.5)
	canvas_text_px(c, r.x + 4, r.y + r.h - 11, "-18", ACTIVE_TOKENS.color.ink_muted, 8.5)
}

draw_comp_curve :: proc(c: ^Canvas, r: Rect, threshold_db, ratio: f32, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	// input -60..0 -> output -60..0, two line segments.
	tx := r.x + 4 + (1.0 - clamp(-threshold_db / 60.0, 0, 1)) * (r.w - 8)
	ty := r.y + 4 + (clamp(-threshold_db / 60.0, 0, 1)) * (r.h - 8)
	col := ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted
	canvas_line(c, r.x + 4, r.y + r.h - 4, tx, ty, with_alpha(col, 0xAA))
	end_y := ty + (r.y + r.h - 4 - ty) * clamp(1.0 / max(ratio, 1), 0, 1)
	canvas_line(c, tx, ty, r.x + r.w - 4, end_y, col)
	canvas_vline(c, tx, r.y + 2, r.y + r.h - 2, with_alpha(ACTIVE_TOKENS.color.ink_dim, 0x55))
}

draw_reverb_tail :: proc(c: ^Canvas, r: Rect, decay: f32, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	n := int(r.w - 8)
	for i in 0 ..< n {
		t := f32(i) / max(r.w - 9, 1)
		env := math.exp(-t * (6.0 - decay * 5.2))
		h := env * (r.h - 8)
		col := ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted
		canvas_fill(c, Rect{r.x + 4 + f32(i), r.y + r.h - 4 - h, 1, h}, with_alpha(col, 0x2A))
		canvas_fill(c, Rect{r.x + 4 + f32(i), r.y + r.h - 4 - h, 1, 1}, with_alpha(col, 0xCC))
	}
}

draw_delay_lanes :: proc(c: ^Canvas, r: Rect, feedback: f32, ping_pong: bool, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	repeats := 7
	for i in 0 ..< repeats {
		amp := math.pow(clamp(feedback, 0, 0.9), f32(i))
		frac := f32(i) / f32(repeats)
		x := r.x + 6 + frac * (r.w - 12)
		h := 4 + amp * (r.h * 0.36)
		lane := 0
		if ping_pong {
			lane = i % 2
		}
		y := r.y + 5 if lane == 0 else r.y + r.h * 0.5 + 2
		canvas_fill(c, Rect{x, y + (r.h * 0.36 - h) * 0.5, 3, h}, ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted)
	}
	canvas_text_px_right(c, r.x + r.w - 4, r.y + 3, "L", ACTIVE_TOKENS.color.ink_muted, 8.5)
	canvas_text_px_right(c, r.x + r.w - 4, r.y + r.h * 0.5 + 1, "R", ACTIVE_TOKENS.color.ink_muted, 8.5)
}

draw_width_scope :: proc(c: ^Canvas, r: Rect, width: f32, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	cx := r.x + r.w * 0.5
	cy := r.y + r.h * 0.5
	rad := min(r.w, r.h) * 0.40
	col := ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted
	// A stereo field: the ellipse narrows to mono, widens past 1.0.
	span := clamp(width, 0, 2) * rad
	canvas_vline(c, cx, cy - rad, cy + rad, with_alpha(ACTIVE_TOKENS.color.line_strong, 0x88))
	steps := 72
	for i in 0 ..< steps {
		a := f32(i) / f32(steps) * math.PI * 2
		x := cx + math.cos(a) * span
		y := cy + math.sin(a) * rad * 0.55
		canvas_fill(c, Rect{x, y, 1, 1}, with_alpha(col, 0xCC))
	}
	canvas_text_px(c, r.x + 3, r.y + 2, "L", ACTIVE_TOKENS.color.ink_muted, 8.5)
	canvas_text_px_right(c, r.x + r.w - 3, r.y + 2, "R", ACTIVE_TOKENS.color.ink_muted, 8.5)
}

draw_limiter_curve :: proc(c: ^Canvas, r: Rect, ceiling_db: f32, enabled: bool = true) {
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface)
	canvas_rect(c, r, ACTIVE_TOKENS.color.line)
	level := db_norm(ceiling_db)
	y := r.y + r.h - 3 - (r.h - 6) * level
	col := ACTIVE_TOKENS.color.amber if enabled else ACTIVE_TOKENS.color.ink_muted
	canvas_hline(c, r.x + 3, r.x + r.w - 3, y, with_alpha(col, 0xAA))
	for i in 0 ..< 24 {
		x := r.x + 4 + f32(i) * (r.w - 8) / 23.0
		top := r.y + r.h - 4 - math.pow(f32(i) / 23.0, 5.0) * (r.h - 8)
		canvas_fill(c, Rect{x, top, 1, r.y + r.h - 4 - top}, with_alpha(col, 0x44))
	}
}

// Transport button: icon + word, no box. Active state is a wash and a full
// accent; hover is a quiet raised fill. Stays legible at 22 px.
Transport_Icon :: enum { Dot, Triangle, Square }

draw_transport_button :: proc(c: ^Canvas, r: Rect, icon: Transport_Icon, label: string, on, hover, enabled: bool, accent: Color) {
	// The label keeps its functional colour at rest (REC red, PLAY teal) and
	// only gains a wash when it is the current transport state.
	col := with_alpha(accent, 0xB0)
	if !enabled {
		col = ACTIVE_TOKENS.color.ink_muted
	} else if on {
		col = accent
		canvas_fill(c, r, with_alpha(accent, 0x22))
	} else if hover {
		col = accent
		canvas_fill(c, r, ACTIVE_TOKENS.color.surface_raised)
	}
	cy := r.y + r.h * 0.5
	ix := r.x + 6
	switch icon {
	case .Dot:
		canvas_circle_fill(c, ix + 3, cy, 3, col)
	case .Triangle:
		for i in 0 ..< 6 {
			h := 8.0 - f32(i) * 0.9
			canvas_fill(c, Rect{ix + f32(i), cy - h * 0.5, 1, h}, col)
		}
	case .Square:
		canvas_fill(c, Rect{ix + 1, cy - 3, 6, 6}, col)
	}
	canvas_text_px(c, r.x + 16, r.y + (r.h - ACTIVE_TOKENS.type.label * 1.2) * 0.5 + 1, label, col, ACTIVE_TOKENS.type.label)
}

// Compact top-bar utility button: text-forward, hairline border.
draw_bar_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	if !enabled {
		canvas_fill(c, r, 0)
		canvas_rect(c, r, ACTIVE_TOKENS.color.line)
		canvas_text_px_center(c, r.x + r.w * 0.5, r.y + (r.h - ACTIVE_TOKENS.type.caption * 1.2) * 0.5 + 1, label, ACTIVE_TOKENS.color.ink_muted, ACTIVE_TOKENS.type.caption)
		return
	}
	if active {
		canvas_fill(c, r, with_alpha(acc, 0x28))
		canvas_rect(c, r, acc)
		canvas_text_px_center(c, r.x + r.w * 0.5, r.y + (r.h - ACTIVE_TOKENS.type.caption * 1.2) * 0.5 + 1, label, acc, ACTIVE_TOKENS.type.caption)
	} else {
		canvas_fill(c, r, ACTIVE_TOKENS.color.surface_raised if hover else 0)
		canvas_rect(c, r, ACTIVE_TOKENS.color.line_strong if hover else ACTIVE_TOKENS.color.line)
		canvas_text_px_center(c, r.x + r.w * 0.5, r.y + (r.h - ACTIVE_TOKENS.type.caption * 1.2) * 0.5 + 1, label, ACTIVE_TOKENS.color.ink if hover else ACTIVE_TOKENS.color.ink_dim, ACTIVE_TOKENS.type.caption)
	}
}

// Left-column strip toggle: a small signal square and a label, like hardware.
draw_label_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	if hover && enabled {
		canvas_fill(c, r, ACTIVE_TOKENS.color.surface_raised)
	}
	col := ACTIVE_TOKENS.color.ink_muted
	if enabled {
		col = acc if on else ACTIVE_TOKENS.color.ink_dim
	}
	sq := Rect{r.x + 1, r.y + (r.h - 6) * 0.5, 6, 6}
	if on && enabled {
		canvas_fill(c, sq, acc)
	} else {
		canvas_rect(c, sq, with_alpha(col, 0xAA))
	}
	canvas_text_px(c, r.x + 13, r.y + (r.h - ACTIVE_TOKENS.type.label * 1.2) * 0.5 + 1, label, col, ACTIVE_TOKENS.type.label)
}

draw_h_meter :: proc(c: ^Canvas, r: Rect, norm: f32, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.color.amber
	canvas_fill(c, r, ACTIVE_TOKENS.color.surface_high)
	w := (r.w - 2) * clamp(norm, 0, 1)
	canvas_fill(c, Rect{r.x + 1, r.y + 1, w, r.h - 2}, acc)
}
