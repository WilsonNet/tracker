// Flat instrument-panel widgets drawn on the software canvas.

package ui

import "core:math"

draw_panel :: proc(c: ^Canvas, r: Rect, fill: Color = PANEL, border: Color = LINE) {
	canvas_fill(c, r, fill)
	if (border >> 24) != 0 {
		canvas_rect(c, r, border)
	}
}

draw_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = AMBER) {
	fill: Color = PANEL_2
	border: Color = LINE
	ink: Color = DIM
	if enabled {
		if active {
			fill = with_alpha(accent, 0xF0)
			border = accent
			ink = WHITE
		} else if hover {
			fill = PANEL_3
			border = with_alpha(accent, 0x88)
			ink = TEXT
		} else {
			border = LINE_BRIGHT
			ink = DIM
		}
	} else {
		ink = MUTED
	}
	canvas_fill(c, r, fill)
	canvas_rect(c, r, border)
	scale := 1
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height(scale)) * 0.5, label, ink, scale)
}

draw_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = AMBER) {
	fill: Color = PANEL_2
	border: Color = LINE
	ink: Color = MUTED
	if enabled {
		ink = DIM
		border = LINE_BRIGHT
		if hover {
			fill = PANEL_3
			ink = TEXT
		}
		if on {
			fill = with_alpha(accent, 0x30)
			border = with_alpha(accent, 0xCC)
			ink = accent
		}
	}
	canvas_fill(c, r, fill)
	canvas_rect(c, r, border)
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height()) * 0.5, label, ink)
}

draw_meter :: proc(c: ^Canvas, r: Rect, db, peak_db: f32, accent: Color = AMBER) {
	canvas_fill(c, r, PANEL_2)
	canvas_rect(c, r, LINE)
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
		bg := with_alpha(PANEL_3, 0xAA)
		canvas_fill(c, Rect{x, y, w, seg_h}, bg)
		if i < lit {
			col := accent
			if i >= segments - 4 {
				col = RED
			} else if i >= segments - 8 {
				col = AMBER_BRIGHT
			}
			canvas_fill(c, Rect{x, y, w, seg_h}, col)
		}
		if i == peak_seg && peak_norm > 0.01 {
			canvas_fill(c, Rect{x, y, w, max(seg_h, 1)}, with_alpha(TEXT, 0xCC))
		}
	}
}

draw_gr :: proc(c: ^Canvas, r: Rect, gr_db: f32) {
	canvas_fill(c, r, PANEL_2)
	canvas_rect(c, r, LINE)
	amount := clamp(-gr_db / 24.0, 0, 1)
	w := (r.w - 2) * amount
	canvas_fill(c, Rect{r.x + r.w - 1 - w, r.y + 1, w, r.h - 2}, AMBER)
	canvas_text(c, r.x + 4, r.y + (r.h - text_height()) * 0.5, "GR", MUTED)
}

draw_fader :: proc(c: ^Canvas, r: Rect, norm: f32, hover: bool) {
	track_w: f32 = 6
	tx := r.x + r.w * 0.5 - track_w * 0.5
	canvas_fill(c, Rect{tx, r.y, track_w, r.h}, PANEL_3)
	canvas_rect(c, Rect{tx, r.y, track_w, r.h}, LINE)
	fill_h := (r.h - 4) * clamp(norm, 0, 1)
	canvas_fill(c, Rect{tx + 1, r.y + r.h - 2 - fill_h, track_w - 2, fill_h}, AMBER)
	// unity mark at 1.0/1.5
	unity_y := r.y + r.h - 2 - (r.h - 4) * (1.0 / 1.5)
	canvas_hline(c, tx - 5, tx + track_w + 5, unity_y, with_alpha(DIM, 0xAA))
	thumb_y := r.y + r.h - 2 - fill_h
	thumb_col: Color = Color(AMBER_BRIGHT) if hover else Color(TEXT)
	canvas_fill(c, Rect{r.x, thumb_y - 3, r.w, 6}, thumb_col)
	canvas_rect(c, Rect{r.x, thumb_y - 3, r.w, 6}, BLACK)
}

draw_knob :: proc(c: ^Canvas, cx, cy, radius, norm: f32, enabled: bool = true, accent: Color = AMBER) {
	start := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	n := clamp(norm, 0, 1)
	ring := accent if enabled else MUTED
	canvas_circle(c, cx, cy, radius, with_alpha(LINE_BRIGHT, 0xCC))
	if enabled {
		canvas_arc(c, cx, cy, radius, start, start + sweep * n, ring, 3)
	} else {
		canvas_arc(c, cx, cy, radius, start, start + sweep, with_alpha(MUTED, 0x66), 2)
	}
	canvas_circle_fill(c, cx, cy, max(radius - 6, 2), PANEL_2)
	angle := start + sweep * n
	ix := cx + math.cos(angle) * (radius - 3)
	iy := cy + math.sin(angle) * (radius - 3)
	canvas_line(c, cx, cy, ix, iy, ring if enabled else MUTED)
	canvas_circle_fill(c, cx, cy, 2, ring if enabled else MUTED)
}

draw_badge :: proc(c: ^Canvas, r: Rect, label: string, accent: Color) {
	canvas_fill(c, r, with_alpha(accent, 0x24))
	canvas_rect(c, r, with_alpha(accent, 0x99))
	canvas_text_center(c, r.x + r.w * 0.5, r.y + (r.h - text_height()) * 0.5, label, accent)
}

draw_hint :: proc(c: ^Canvas, x, y: f32, key, text: string) {
	kw := text_width(key) + 8
	canvas_fill(c, Rect{x, y - 2, kw, 16}, PANEL_3)
	canvas_rect(c, Rect{x, y - 2, kw, 16}, LINE)
	canvas_text(c, x + 4, y, key, AMBER)
	canvas_text(c, x + kw + 6, y, text, MUTED)
}

draw_eq_curve :: proc(c: ^Canvas, r: Rect, low_db, mid_db, high_db: f32) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
	mid_y := r.y + r.h * 0.5
	canvas_hline(c, r.x + 4, r.x + r.w - 4, mid_y, with_alpha(LINE_BRIGHT, 0x88))
	n := int(r.w - 8)
	for i in 0 ..< n {
		t := f32(i) / f32(max(n - 1, 1))
		// Rough visual: shelves at the ends, bell in the middle.
		low_w := 1.0 - clamp(t / 0.38, 0, 1)
		high_w := clamp((t - 0.62) / 0.38, 0, 1)
		bell := math.exp(-math.pow((t - 0.5) / 0.16, 2.0))
		db := low_db * low_w + high_db * high_w + mid_db * bell
		y := mid_y - clamp(db, -18, 18) / 18.0 * (r.h * 0.42)
		canvas_fill(c, Rect{r.x + 4 + f32(i), y, 1, 1}, AMBER)
	}
	canvas_text(c, r.x + 4, r.y + 2, "+18", MUTED)
	canvas_text(c, r.x + 4, r.y + r.h - 14, "-18", MUTED)
}

draw_comp_curve :: proc(c: ^Canvas, r: Rect, threshold_db, ratio: f32) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
	// input -60..0 -> output -60..0, two line segments.
	tx := r.x + 4 + (1.0 - clamp(-threshold_db / 60.0, 0, 1)) * (r.w - 8)
	ty := r.y + 4 + (clamp(-threshold_db / 60.0, 0, 1)) * (r.h - 8)
	canvas_line(c, r.x + 4, r.y + r.h - 4, tx, ty, with_alpha(AMBER, 0xAA))
	end_y := ty + (r.y + r.h - 4 - ty) * clamp(1.0 / max(ratio, 1), 0, 1)
	canvas_line(c, tx, ty, r.x + r.w - 4, end_y, AMBER)
	canvas_vline(c, tx, r.y + 2, r.y + r.h - 2, with_alpha(DIM, 0x55))
}

draw_reverb_tail :: proc(c: ^Canvas, r: Rect, decay: f32) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
	for i in 0 ..< int(r.w - 8) {
		t := f32(i) / max(r.w - 9, 1)
		env := math.exp(-t * (6.0 - decay * 5.2))
		h := env * (r.h - 8)
		canvas_fill(c, Rect{r.x + 4 + f32(i), r.y + r.h - 4 - h, 1, h}, with_alpha(AMBER, 0xCC))
	}
}

draw_delay_lanes :: proc(c: ^Canvas, r: Rect, feedback: f32, ping_pong: bool) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
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
		canvas_fill(c, Rect{x, y + (r.h * 0.36 - h) * 0.5, 3, h}, AMBER)
	}
	canvas_text(c, r.x + 4, r.y + r.h - 14, "L", MUTED)
	canvas_text(c, r.x + 4, r.y + r.h * 0.5 + 2, "R", MUTED)
}

draw_width_scope :: proc(c: ^Canvas, r: Rect, width: f32) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
	cx := r.x + r.w * 0.5
	cy := r.y + r.h * 0.5
	rad := min(r.w, r.h) * 0.36
	canvas_line(c, cx - rad, cy, cx + rad, cy, with_alpha(LINE_BRIGHT, 0x66))
	canvas_line(c, cx, cy - rad, cx, cy + rad, with_alpha(LINE_BRIGHT, 0x66))
	n := int(width * 16)
	for i in 0 ..< n {
		t := f32(i) / f32(max(n - 1, 1))
		a := (t - 0.5) * math.PI * 0.5
		x := cx + math.sin(a) * rad
		y := cy - math.cos(a) * rad * 0.7
		canvas_fill(c, Rect{x, y, 1, 1}, AMBER)
	}
}

draw_limiter_curve :: proc(c: ^Canvas, r: Rect, ceiling_db: f32) {
	canvas_fill(c, r, PANEL)
	canvas_rect(c, r, LINE)
	level := db_norm(ceiling_db)
	y := r.y + r.h - 3 - (r.h - 6) * level
	canvas_hline(c, r.x + 3, r.x + r.w - 3, y, with_alpha(AMBER, 0xAA))
	for i in 0 ..< 24 {
		x := r.x + 4 + f32(i) * (r.w - 8) / 23.0
		top := r.y + r.h - 4 - math.pow(f32(i) / 23.0, 5.0) * (r.h - 8)
		canvas_fill(c, Rect{x, top, 1, r.y + r.h - 4 - top}, with_alpha(AMBER, 0x44))
	}
}
