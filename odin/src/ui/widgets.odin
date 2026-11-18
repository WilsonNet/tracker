// Skald-inspired widget vocabulary: Inter labels, rounded surfaces, restrained
// accent fills, and real AA paths. Components read ACTIVE_TOKENS so the same
// drawing code works at every display density and responsive zoom.

package ui

import "core:math"

@(private)
ink_on :: proc(accent: Color) -> Color {
	return ACTIVE_TOKENS.color.on_amber
}

@(private)
text_middle_y :: proc(c: ^Canvas, r: Rect, label: string, px: f32, weight: Font_Weight) -> f32 {
	h := canvas_text_height(c, label, px, weight)
	return r.y + (r.h - h) * 0.5
}

draw_panel :: proc(c: ^Canvas, r: Rect, fill: Color = 0, border: Color = 0, radius: f32 = -1) {
	T := ACTIVE_TOKENS
	rad := T.radius.lg if radius < 0 else radius
	canvas_fill_round(c, r, rad, fill if fill != 0 else T.color.surface)
	if (border >> 24) != 0 {
		canvas_stroke_round(c, r, rad, border, 1)
	}
}

draw_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	fill: Color = T.color.surface_raised
	border: Color = T.color.line_subtle
	ink: Color = T.color.ink_dim
	if !enabled {
		fill = T.color.surface
		border = T.color.line_subtle
		ink = T.color.ink_muted
	} else if active {
		fill = acc
		border = acc
		ink = ink_on(acc)
	} else if hover {
		fill = T.color.surface_high
		border = T.color.line_strong
		ink = T.color.ink
	}
	canvas_fill_round(c, r, T.radius.md, fill)
	canvas_stroke_round(c, r, T.radius.md, border, 1)
	px := T.type.label
	canvas_text_px(c, r.x + (r.w - canvas_text_width(c, label, px, .Medium)) * 0.5,
		text_middle_y(c, r, label, px, .Medium), label, ink, px, .Medium)
}

// Transport button: icon + word, no box at rest. The active state is a solid
// accent fill with dark ink; idle keeps the functional colour of the control.
Transport_Icon :: enum { Dot, Triangle, Square }

draw_transport_button :: proc(c: ^Canvas, r: Rect, icon: Transport_Icon, label: string, on, hover, enabled: bool, accent: Color) {
	T := ACTIVE_TOKENS
	col := accent
	fill: Color = 0
	border: Color = 0
	if !enabled {
		col = T.color.ink_muted
	} else if on {
		fill = accent
		col = ink_on(accent)
	} else if hover {
		fill = T.color.surface_raised
		border = T.color.line_subtle
	}
	if fill != 0 {
		canvas_fill_round(c, r, T.radius.md, fill)
	}
	if border != 0 {
		canvas_stroke_round(c, r, T.radius.md, border, 1)
	}
	cy := r.y + r.h * 0.5
	ix := r.x + 11
	switch icon {
	case .Dot:
		canvas_disc(c, ix + 3, cy, 4, col)
	case .Triangle:
		canvas_triangle(c, ix, cy - 6, ix + 10, cy, ix, cy + 6, col)
	case .Square:
		canvas_fill_round(c, Rect{ix, cy - 5, 10, 10}, 2, col)
	}
	px := T.type.label
	canvas_text_px(c, r.x + 26, text_middle_y(c, r, label, px, .Medium), label, col, px, .Medium)
}

draw_bar_button :: proc(c: ^Canvas, r: Rect, label: string, active, hover, enabled: bool, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	fill: Color = 0
	border: Color = T.color.line_subtle
	ink: Color = T.color.ink_dim
	if !enabled {
		ink = T.color.ink_muted
	} else if active {
		fill = T.color.amber_bg if acc == T.color.amber else with_alpha(acc, 0x22)
		border = T.color.border_amber if acc == T.color.amber else with_alpha(acc, 0x77)
		ink = acc
	} else if hover {
		fill = T.color.surface_raised
		border = T.color.line
		ink = T.color.ink
	}
	if fill != 0 {
		canvas_fill_round(c, r, T.radius.md, fill)
	}
	if border != 0 {
		canvas_stroke_round(c, r, T.radius.md, border, 1)
	}
	px := T.type.caption
	canvas_text_px(c, r.x + (r.w - canvas_text_width(c, label, px, .Medium)) * 0.5,
		text_middle_y(c, r, label, px, .Medium), label, ink, px, .Medium)
}

// Left-column strip toggle: rounded pill, functional accent, small LED.
draw_label_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	fill: Color = T.color.surface_raised
	border: Color = T.color.line_subtle
	if !enabled {
		fill = T.color.surface
		border = T.color.line_subtle
	} else if on {
		fill = with_alpha(acc, 0x1E)
		border = with_alpha(acc, 0x66)
	} else if hover {
		fill = T.color.surface_raised
		border = T.color.line
	}
	if fill != 0 {
		canvas_fill_round(c, r, T.radius.md, fill)
	}
	if border != 0 {
		canvas_stroke_round(c, r, T.radius.md, border, 1)
	}
	col: Color = T.color.ink_dim
	if !enabled {
		col = T.color.ink_muted
	} else if on {
		col = acc
	}
	led := Rect{r.x + 9, r.y + (r.h - 12) * 0.5, 12, 12}
	if on && enabled {
		canvas_fill_round(c, led, 3, acc)
	} else {
		canvas_stroke_round(c, led, 3, with_alpha(col, 0xAA), 1.5)
	}
	px := T.type.caption
	canvas_text_px(c, r.x + 28, text_middle_y(c, r, label, px, .Medium), label, col, px, .Medium)
}

draw_toggle :: proc(c: ^Canvas, r: Rect, label: string, on, hover, enabled: bool, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	fill: Color = T.color.surface_raised
	border: Color = T.color.line_subtle
	ink: Color = T.color.ink_muted
	if !enabled {
		fill = T.color.surface
	} else if on {
		fill = with_alpha(acc, 0x22)
		border = with_alpha(acc, 0x88)
		ink = acc
	} else if hover {
		fill = T.color.surface_high
		border = T.color.line
		ink = T.color.ink_dim
	}
	canvas_fill_round(c, r, T.radius.sm, fill)
	canvas_stroke_round(c, r, T.radius.sm, border, 1)
	px := T.type.caption
	canvas_text_px(c, r.x + (r.w - canvas_text_width(c, label, px, .Medium)) * 0.5,
		text_middle_y(c, r, label, px, .Medium), label, ink, px, .Medium)
}

draw_meter :: proc(c: ^Canvas, r: Rect, db, peak_db: f32, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	canvas_fill_round(c, r, 3, T.color.surface_high)
	segments := 28
	gap: f32 = 2
	seg_h := (r.h - 6 - f32(segments - 1) * gap) / f32(segments)
	norm := db_norm(db)
	peak_norm := db_norm(peak_db)
	lit := int(math.ceil(norm * f32(segments)))
	peak_seg := int(math.ceil(peak_norm * f32(segments))) - 1
	for i in 0 ..< segments {
		y := r.y + 3 + f32(segments - 1 - i) * (seg_h + gap)
		col := with_alpha(T.color.surface_high, 0xCC)
		if i < lit {
			col = acc
			if i >= segments - 4 {
				col = T.color.red
			} else if i >= segments - 8 {
				col = mix(acc, T.color.amber_bright, 0.6)
			}
		}
		canvas_fill_round(c, Rect{r.x + 2, y, r.w - 4, max(seg_h, 1)}, 1, col)
		if i == peak_seg && peak_norm > 0.01 {
			canvas_fill_round(c, Rect{r.x + 2, y, r.w - 4, max(seg_h, 1)}, 1, with_alpha(T.color.ink, 0xDD))
		}
	}
}

draw_fader :: proc(c: ^Canvas, r: Rect, norm: f32, hover: bool, enabled: bool = true) {
	T := ACTIVE_TOKENS
	rail_w: f32 = 6
	tx := r.x + r.w * 0.5 - rail_w * 0.5
	canvas_fill_round(c, Rect{tx, r.y, rail_w, r.h}, 3, T.color.surface_high)
	n := clamp(norm, 0, 1)
	thumb_h: f32 = 14
	thumb_y := r.y + 4 + (r.h - 12) * (1 - n) - thumb_h * 0.5
	thumb_y = clamp(thumb_y, r.y + 1, r.y + r.h - thumb_h - 1)
	col := T.color.amber
	if !enabled {
		col = T.color.ink_muted
	}
	canvas_fill_round(c, Rect{tx, thumb_y + thumb_h * 0.5, rail_w, r.y + r.h - (thumb_y + thumb_h * 0.5) - 2}, 3, with_alpha(col, 0xB0))
	// Unity tick.
	uy := r.y + 4 + (r.h - 8) * (1 - 1.0 / 1.5)
	canvas_hline(c, tx - 7, tx + rail_w + 7, uy, with_alpha(T.color.ink_muted, 0x88))
	thumb := Rect{r.x + 1, thumb_y, r.w - 2, thumb_h}
	thumb_border := with_alpha(T.color.line_strong, 0xCC)
	if hover && enabled {
		thumb_border = T.color.amber_bright
	}
	canvas_fill_round(c, thumb, 4, T.color.ink if enabled else T.color.ink_muted)
	canvas_stroke_round(c, thumb, 4, thumb_border, 1)
	canvas_fill_round(c, Rect{thumb.x + 5, thumb.y + thumb_h * 0.5 - 1, thumb.w - 10, 2}, 1, with_alpha(T.color.bg, 0x99))
}

draw_knob :: proc(c: ^Canvas, cx, cy, radius, norm: f32, enabled: bool = true, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	start := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	n := clamp(norm, 0, 1)
	// Soft body: outer shadow, raised rim, recessed face.
	canvas_disc(c, cx, cy + 1, radius + 1, with_alpha(T.color.black, 0x33))
	canvas_disc(c, cx, cy, radius, T.color.surface_high)
	canvas_disc(c, cx, cy, max(radius - 2.5, 2), T.color.surface_raised)
	canvas_ring(c, cx, cy, radius - 0.5, with_alpha(T.color.line_strong, 0xCC), 1)
	canvas_arc(c, cx, cy, radius - 2.5, start, start + sweep, with_alpha(T.color.line_strong, 0x99), 2)
	if enabled {
		canvas_arc(c, cx, cy, radius - 2.5, start, start + sweep * n, with_alpha(acc, 0xEE), 3)
	}
	angle := start + sweep * n
	ix := cx + math.cos(angle) * (radius - 6)
	iy := cy + math.sin(angle) * (radius - 6)
	canvas_line_aa(c, cx, cy, ix, iy, T.color.ink if enabled else T.color.ink_muted, 2)
	canvas_disc(c, cx, cy, 2.5, acc if enabled else T.color.ink_muted)
}

draw_badge :: proc(c: ^Canvas, r: Rect, label: string, accent: Color) {
	T := ACTIVE_TOKENS
	canvas_fill_round(c, r, T.radius.pill, with_alpha(accent, 0x1E))
	canvas_stroke_round(c, r, T.radius.pill, with_alpha(accent, 0x88), 1)
	px := T.type.caption
	canvas_text_px(c, r.x + (r.w - canvas_text_width(c, label, px, .Medium)) * 0.5,
		text_middle_y(c, r, label, px, .Medium), label, accent, px, .Medium)
}

draw_hint :: proc(c: ^Canvas, x, y: f32, key, text: string) {
	T := ACTIVE_TOKENS
	kw := canvas_text_width(c, key, T.type.caption, .Medium) + 12
	canvas_fill_round(c, Rect{x, y - 3, kw, 20}, 4, T.color.surface_raised)
	canvas_stroke_round(c, Rect{x, y - 3, kw, 20}, 4, T.color.line_subtle, 1)
	canvas_text_px(c, x + 6, y, key, T.color.amber, T.type.caption, .Medium)
	canvas_text_px(c, x + kw + 8, y, text, T.color.ink_muted, T.type.caption, .Regular)
}

draw_h_meter :: proc(c: ^Canvas, r: Rect, norm: f32, accent: Color = 0) {
	T := ACTIVE_TOKENS
	acc := accent if accent != 0 else T.color.amber
	canvas_fill_round(c, r, 2, T.color.surface_high)
	w := (r.w - 2) * clamp(norm, 0, 1)
	canvas_fill_round(c, Rect{r.x + 1, r.y + 1, w, r.h - 2}, 2, acc)
}

// ---------------------------------------------------------------- graphs

@(private)
graph_frame :: proc(c: ^Canvas, r: Rect, enabled: bool) {
	T := ACTIVE_TOKENS
	canvas_fill_round(c, r, T.radius.sm, T.color.bg)
	canvas_stroke_round(c, r, T.radius.sm, T.color.line_subtle, 1)
	for i in 1 ..< 4 {
		y := r.y + r.h * f32(i) / 4
		canvas_hline(c, r.x + 1, r.x + r.w - 1, y, with_alpha(T.color.line, 0x66))
	}
	for i in 1 ..< 5 {
		x := r.x + r.w * f32(i) / 5
		canvas_vline(c, x, r.y + 1, r.y + r.h - 1, with_alpha(T.color.line, 0x44))
	}
}

@(private)
graph_caption :: proc(c: ^Canvas, r: Rect, text: string) {
	T := ACTIVE_TOKENS
	canvas_text_px(c, r.x + 6, r.y + r.h - 15, text, with_alpha(T.color.ink_muted, 0xDD), 9, .Regular)
}

draw_eq_curve :: proc(c: ^Canvas, r: Rect, low_db, mid_db, high_db: f32, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.amber if enabled else T.color.ink_muted
	pts: [512]Point
	n := max(int((r.w - 4) / 2), 8)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		low := 1.0 / (1.0 + math.exp((t - 0.18) * 22))
		high := 1.0 / (1.0 + math.exp(-(t - 0.82) * 22))
		bell := math.exp(-math.pow((t - 0.5) / 0.17, 2.0))
		db := low_db * low + high_db * high + mid_db * bell
		y := r.y + r.h * 0.5 - clamp(db, -18, 18) / 18.0 * (r.h * 0.40)
		pts[i] = Point{r.x + 2 + t * (r.w - 4), y}
	}
	canvas_area_gradient(c, pts[:n], r.y + r.h - 2, with_alpha(col, 0x33), with_alpha(col, 0x00))
	canvas_polyline(c, pts[:n], col, 1.5)
}

draw_comp_curve :: proc(c: ^Canvas, r: Rect, threshold_db, ratio: f32, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.amber if enabled else T.color.ink_muted
	// Reference 1:1 line.
	canvas_line_aa(c, r.x + 3, r.y + r.h - 3, r.x + r.w - 3, r.y + 3, with_alpha(T.color.line_strong, 0x66), 1)
	pts: [1024]Point
	n := max(int(r.w - 6), 16)
	thr := clamp(1.0 + threshold_db / 60.0, 0, 1)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		out := t if t < thr else thr + (t - thr) / max(ratio, 1)
		y := r.y + r.h - 3 - out * (r.h - 6)
		pts[i] = Point{r.x + 3 + t * (r.w - 6), y}
	}
	canvas_area_gradient(c, pts[:n], r.y + r.h - 3, with_alpha(col, 0x30), with_alpha(col, 0x00))
	canvas_polyline(c, pts[:n], col, 1.5)
	// Threshold marker.
	tx := r.x + 3 + thr * (r.w - 6)
	ty := r.y + r.h - 3 - thr * (r.h - 6)
	canvas_disc(c, tx, ty, 2.5, col)
	graph_caption(c, r, "1:1")
}

draw_reverb_tail :: proc(c: ^Canvas, r: Rect, decay: f32, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.amber if enabled else T.color.ink_muted
	pts: [512]Point
	pts_r: [512]Point
	n := max(int(r.w - 4), 16)
	k := 6.0 - decay * 5.2
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		h := math.exp(-t * k)
		pts[i] = Point{r.x + 2 + t * (r.w - 4), r.y + r.h - 3 - h * (r.h - 8)}
		h2 := math.exp(-t * (k * 0.82))
		pts_r[i] = Point{r.x + 2 + t * (r.w - 4), r.y + r.h - 3 - h2 * (r.h - 8)}
	}
	canvas_area_gradient(c, pts[:n], r.y + r.h - 2, with_alpha(col, 0x33), with_alpha(col, 0x00))
	teal_alpha := u8(0x99) if enabled else u8(0x44)
	canvas_polyline(c, pts_r[:n], with_alpha(T.color.teal, teal_alpha), 1)
	canvas_polyline(c, pts[:n], col, 1.5)
	canvas_vline(c, r.x + 2, r.y + 3, r.y + r.h - 3, with_alpha(col, 0x88))
	graph_caption(c, r, "L / R")
}

draw_delay_lanes :: proc(c: ^Canvas, r: Rect, feedback: f32, ping_pong: bool, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.teal if enabled else T.color.ink_muted
	repeats := 8
	canvas_hline(c, r.x + 3, r.x + r.w - 3, r.y + r.h * 0.5, with_alpha(T.color.line, 0x88))
	for i in 0 ..< repeats {
		amp := math.pow(clamp(feedback, 0, 0.9), f32(i))
		x := r.x + 8 + f32(i) * (r.w - 16) / f32(repeats - 1)
		h := 5 + amp * (r.h * 0.30)
		lane := 0
		if ping_pong {
			lane = i % 2
		}
		y := r.y + r.h * 0.5 - h - 3 if lane == 0 else r.y + r.h * 0.5 + 3
		canvas_fill_round(c, Rect{x - 2, y, 4, h}, 2, col)
	}
	canvas_text_px_right(c, r.x + r.w - 5, r.y + 3, "L", T.color.ink_muted, 9, .Medium)
	canvas_text_px_right(c, r.x + r.w - 5, r.y + r.h * 0.5 + 3, "R", T.color.ink_muted, 9, .Medium)
}

draw_width_scope :: proc(c: ^Canvas, r: Rect, width: f32, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.amber if enabled else T.color.ink_muted
	cx := r.x + r.w * 0.5
	cy := r.y + r.h * 0.5
	radx := clamp(width, 0, 2) * (r.w * 0.34)
	rady := r.h * 0.30
	pts: [96]Point
	for i in 0 ..< len(pts) {
		a := f32(i) / f32(len(pts)) * math.TAU
		pts[i] = Point{cx + math.cos(a) * radx, cy + math.sin(a) * rady}
	}
	canvas_polyline(c, pts[:], with_alpha(col, 0xCC), 1.5)
	canvas_vline(c, cx, cy - rady - 3, cy + rady + 3, with_alpha(T.color.line_strong, 0x88))
	canvas_text_px(c, r.x + 5, r.y + 3, "L", T.color.ink_muted, 9, .Medium)
	canvas_text_px_right(c, r.x + r.w - 5, r.y + 3, "R", T.color.ink_muted, 9, .Medium)
}

draw_limiter_curve :: proc(c: ^Canvas, r: Rect, ceiling_db: f32, enabled: bool = true) {
	T := ACTIVE_TOKENS
	graph_frame(c, r, enabled)
	col := T.color.amber if enabled else T.color.ink_muted
	pts: [1024]Point
	n := max(int(r.w - 6), 16)
	ceil := clamp(1.0 + ceiling_db / 60.0, 0, 1)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		out := t if t < ceil else ceil + (1.0 - math.exp(-(t - ceil) * 12)) * 0.012
		y := r.y + r.h - 3 - clamp(out, 0, 1) * (r.h - 6)
		pts[i] = Point{r.x + 3 + t * (r.w - 6), y}
	}
	canvas_area_gradient(c, pts[:n], r.y + r.h - 3, with_alpha(col, 0x30), with_alpha(col, 0x00))
	canvas_polyline(c, pts[:n], col, 1.5)
	cy := r.y + r.h - 3 - ceil * (r.h - 6)
	// Dashed ceiling.
	x := r.x + 3
	for x < r.x + r.w - 4 {
		canvas_line_aa(c, x, cy, min(x + 4, r.x + r.w - 4), cy, with_alpha(T.color.red, 0xAA), 1)
		x += 8
	}
	graph_caption(c, r, "CEIL")
}
