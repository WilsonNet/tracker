// Flat instrument-panel widgets drawn on the software canvas.

package ui

import "core:math"

draw_panel :: proc(c: ^Canvas, r: Rect, fill: Color = 0, border: Color = 0) {
	canvas_fill(c, r, fill if fill != 0 else ACTIVE_TOKENS.panel)
	if (border >> 24) != 0 {
		canvas_rect(c, r, border)
	}
}

draw_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.amber
	fill: Color = ACTIVE_TOKENS.panel_2
	border: Color = ACTIVE_TOKENS.line
	ink: Color = ACTIVE_TOKENS.dim
	if enabled {
		if active {
			fill = with_alpha(acc, 0xF0)
			border = acc
			ink = ACTIVE_TOKENS.white
		} else if hover {
			fill = ACTIVE_TOKENS.panel_3
			border = with_alpha(acc, 0x88)
			ink = ACTIVE_TOKENS.text
		} else {
			border = ACTIVE_TOKENS.line_bright
			ink = ACTIVE_TOKENS.dim
		}
	} else {
		ink = ACTIVE_TOKENS.muted
	}
	canvas_fill(c, r, fill)
	canvas_rect(c, r, border)
	scale := 1
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height(scale)) * 0.5, label, ink, scale)
}

draw_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.amber
	fill: Color = ACTIVE_TOKENS.panel_2
	border: Color = ACTIVE_TOKENS.line
	ink: Color = ACTIVE_TOKENS.muted
	if enabled {
		ink = ACTIVE_TOKENS.dim
		border = ACTIVE_TOKENS.line_bright
		if hover {
			fill = ACTIVE_TOKENS.panel_3
			ink = ACTIVE_TOKENS.text
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
	acc := accent if accent != 0 else ACTIVE_TOKENS.amber
	canvas_fill(c, r, ACTIVE_TOKENS.panel_2)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	segments := 24
	gap: f32 = 1
	seg_h := (r.h - 4 - f32(segments - 1) * gap) / f32(segments)
	norm := db_norm(db)
	peak_norm := db_norm(peak_db)
	lit := int(math.ceil(norm * f32(segments)))
	peak_seg := int(math.ceil(peak_norm * f32(segments))) - 1
	for i in 0 ..< segments {
		y := r.y + r.h - 2 - (f32(i) + 1) * (seg_h + gap)
		x := r.x + 2
		w := r.w - 4
		bg := with_alpha(ACTIVE_TOKENS.panel_3, 0xAA)
		canvas_fill(c, Rect{x, y, w, seg_h}, bg)
		if i < lit {
			col := acc
			if i >= segments - 4 {
				col = ACTIVE_TOKENS.red
			} else if i >= segments - 8 {
				col = ACTIVE_TOKENS.amber_bright
			}
			canvas_fill(c, Rect{x, y, w, seg_h}, col)
		}
		if i == peak_seg && peak_norm > 0.01 {
			canvas_fill(c, Rect{x, y, w, max(seg_h, 1)}, with_alpha(ACTIVE_TOKENS.text, 0xCC))
		}
	}
}

draw_gr :: proc(c: ^Canvas, r: Rect, gr_db: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel_2)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	amount := clamp(-gr_db / 24.0, 0, 1)
	w := (r.w - 2) * amount
	canvas_fill(c, Rect{r.x + r.w - 1 - w, r.y + 1, w, r.h - 2}, ACTIVE_TOKENS.amber)
	canvas_text(c, r.x + 4, r.y + (r.h - text_height()) * 0.5, "GR", ACTIVE_TOKENS.muted)
}

draw_fader :: proc(c: ^Canvas, r: Rect, norm: f32, hover: bool, enabled: bool = true) {
	track_w: f32 = 6
	tx := r.x + r.w * 0.5 - track_w * 0.5
	canvas_fill(c, Rect{tx, r.y, track_w, r.h}, ACTIVE_TOKENS.panel_3)
	canvas_rect(c, Rect{tx, r.y, track_w, r.h}, ACTIVE_TOKENS.line)
	fill_h := (r.h - 4) * clamp(norm, 0, 1)
	canvas_fill(c, Rect{tx + 1, r.y + r.h - 2 - fill_h, track_w - 2, fill_h}, ACTIVE_TOKENS.amber if enabled else ACTIVE_TOKENS.muted)
	// unity mark at 1.0/1.5
	unity_y := r.y + r.h - 2 - (r.h - 4) * (1.0 / 1.5)
	canvas_hline(c, tx - 5, tx + track_w + 5, unity_y, with_alpha(ACTIVE_TOKENS.dim, 0xAA))
	thumb_y := r.y + r.h - 2 - fill_h
	thumb_col: Color = Color(ACTIVE_TOKENS.amber_bright) if hover && enabled else Color(ACTIVE_TOKENS.text if enabled else ACTIVE_TOKENS.muted)
	canvas_fill(c, Rect{r.x, thumb_y - 3, r.w, 6}, thumb_col)
	canvas_rect(c, Rect{r.x, thumb_y - 3, r.w, 6}, ACTIVE_TOKENS.black)
}

draw_knob :: proc(c: ^Canvas, cx, cy, radius, norm: f32, enabled: bool = true, accent: Color = 0) {
	acc := accent if accent != 0 else ACTIVE_TOKENS.amber
	start := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	n := clamp(norm, 0, 1)
	ring := acc if enabled else ACTIVE_TOKENS.muted
	canvas_circle(c, cx, cy, radius, with_alpha(ACTIVE_TOKENS.line_bright, 0xCC))
	if enabled {
		canvas_arc(c, cx, cy, radius, start, start + sweep * n, ring, 3)
	} else {
		canvas_arc(c, cx, cy, radius, start, start + sweep, with_alpha(ACTIVE_TOKENS.muted, 0x66), 2)
	}
	canvas_circle_fill(c, cx, cy, max(radius - 6, 2), ACTIVE_TOKENS.panel_2)
	angle := start + sweep * n
	ix := cx + math.cos(angle) * (radius - 3)
	iy := cy + math.sin(angle) * (radius - 3)
	canvas_line(c, cx, cy, ix, iy, ring if enabled else ACTIVE_TOKENS.muted)
	canvas_circle_fill(c, cx, cy, 2, ring if enabled else ACTIVE_TOKENS.muted)
}

draw_badge :: proc(c: ^Canvas, r: Rect, label: string, accent: Color) {
	canvas_fill(c, r, with_alpha(accent, 0x24))
	canvas_rect(c, r, with_alpha(accent, 0x99))
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height()) * 0.5, label, accent)
}

draw_hint :: proc(c: ^Canvas, x, y: f32, key, text: string) {
	kw := text_width(key) + 8
	canvas_fill(c, Rect{x, y - 2, kw, 16}, ACTIVE_TOKENS.panel_3)
	canvas_rect(c, Rect{x, y - 2, kw, 16}, ACTIVE_TOKENS.line)
	canvas_text(c, x + 4, y, key, ACTIVE_TOKENS.amber)
	canvas_text(c, x + kw + 6, y, text, ACTIVE_TOKENS.muted)
}

draw_eq_curve :: proc(c: ^Canvas, r: Rect, low_db, mid_db, high_db: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	mid_y := r.y + r.h * 0.5
	canvas_hline(c, r.x + 4, r.x + r.w - 4, mid_y, with_alpha(ACTIVE_TOKENS.line_bright, 0x88))
	n := int(r.w - 8)
	for i in 0 ..< n {
		t := f32(i) / f32(max(n - 1, 1))
		// Rough visual: shelves at the ends, bell in the middle.
		low_w := 1.0 - clamp(t / 0.38, 0, 1)
		high_w := clamp((t - 0.62) / 0.38, 0, 1)
		bell := math.exp(-math.pow((t - 0.5) / 0.16, 2.0))
		db := low_db * low_w + high_db * high_w + mid_db * bell
		y := mid_y - clamp(db, -18, 18) / 18.0 * (r.h * 0.42)
		canvas_fill(c, Rect{r.x + 4 + f32(i), y, 1, 1}, ACTIVE_TOKENS.amber)
	}
	canvas_text(c, r.x + 4, r.y + 2, "+18", ACTIVE_TOKENS.muted)
	canvas_text(c, r.x + 4, r.y + r.h - 14, "-18", ACTIVE_TOKENS.muted)
}

draw_comp_curve :: proc(c: ^Canvas, r: Rect, threshold_db, ratio: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	// input -60..0 -> output -60..0, two line segments.
	tx := r.x + 4 + (1.0 - clamp(-threshold_db / 60.0, 0, 1)) * (r.w - 8)
	ty := r.y + 4 + (clamp(-threshold_db / 60.0, 0, 1)) * (r.h - 8)
	canvas_line(c, r.x + 4, r.y + r.h - 4, tx, ty, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
	end_y := ty + (r.y + r.h - 4 - ty) * clamp(1.0 / max(ratio, 1), 0, 1)
	canvas_line(c, tx, ty, r.x + r.w - 4, end_y, ACTIVE_TOKENS.amber)
	canvas_vline(c, tx, r.y + 2, r.y + r.h - 2, with_alpha(ACTIVE_TOKENS.dim, 0x55))
}

draw_reverb_tail :: proc(c: ^Canvas, r: Rect, decay: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	for i in 0 ..< int(r.w - 8) {
		t := f32(i) / max(r.w - 9, 1)
		env := math.exp(-t * (6.0 - decay * 5.2))
		h := env * (r.h - 8)
		canvas_fill(c, Rect{r.x + 4 + f32(i), r.y + r.h - 4 - h, 1, h}, with_alpha(ACTIVE_TOKENS.amber, 0xCC))
	}
}

draw_delay_lanes :: proc(c: ^Canvas, r: Rect, feedback: f32, ping_pong: bool) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
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
		canvas_fill(c, Rect{x, y + (r.h * 0.36 - h) * 0.5, 3, h}, ACTIVE_TOKENS.amber)
	}
	canvas_text_right(c, r.x + r.w - 4, r.y + 4, "L", ACTIVE_TOKENS.muted)
	canvas_text_right(c, r.x + r.w - 4, r.y + r.h * 0.5 + 2, "R", ACTIVE_TOKENS.muted)
}

draw_width_scope :: proc(c: ^Canvas, r: Rect, width: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	cx := r.x + r.w * 0.5
	cy := r.y + r.h * 0.5
	rad := min(r.w, r.h) * 0.36
	canvas_line(c, cx - rad, cy, cx + rad, cy, with_alpha(ACTIVE_TOKENS.line_bright, 0x66))
	canvas_line(c, cx, cy - rad, cx, cy + rad, with_alpha(ACTIVE_TOKENS.line_bright, 0x66))
	n := int(width * 16)
	for i in 0 ..< n {
		t := f32(i) / f32(max(n - 1, 1))
		a := (t - 0.5) * math.PI * 0.5
		x := cx + math.sin(a) * rad
		y := cy - math.cos(a) * rad * 0.7
		canvas_fill(c, Rect{x, y, 1, 1}, ACTIVE_TOKENS.amber)
	}
}

draw_limiter_curve :: proc(c: ^Canvas, r: Rect, ceiling_db: f32) {
	canvas_fill(c, r, ACTIVE_TOKENS.panel)
	canvas_rect(c, r, ACTIVE_TOKENS.line)
	level := db_norm(ceiling_db)
	y := r.y + r.h - 3 - (r.h - 6) * level
	canvas_hline(c, r.x + 3, r.x + r.w - 3, y, with_alpha(ACTIVE_TOKENS.amber, 0xAA))
	for i in 0 ..< 24 {
		x := r.x + 4 + f32(i) * (r.w - 8) / 23.0
		top := r.y + r.h - 4 - math.pow(f32(i) / 23.0, 5.0) * (r.h - 8)
		canvas_fill(c, Rect{x, top, 1, r.y + r.h - 4 - top}, with_alpha(ACTIVE_TOKENS.amber, 0x44))
	}
}
