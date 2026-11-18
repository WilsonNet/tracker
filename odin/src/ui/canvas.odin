// Flat vector canvas backed by Cairo.
//
// Every frame is drawn into an ARGB32 image surface that is also the SDL
// texture upload buffer. Cairo handles anti-aliasing, rounded paths,
// gradients and clipping; Pango handles shaped text. The public API is still
// the small logical-coordinate vocabulary the shell and the tests use.

package ui

import "core:math"

Color :: u32

Rect :: struct {
	x, y, w, h: f32,
}

rect :: proc(x, y, w, h: f32) -> Rect {
	return Rect{x, y, w, h}
}

rect_contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

// `width`/`height` are physical pixels; `scale` is physical pixels per logical
// pixel. All public drawing calls take logical coordinates.
Canvas :: struct {
	width, height: int,
	pixels:        []u32,
	clip:          Rect, // physical pixels
	scale:         f32,
	cr:            ^cairo_t,
	surface:       ^cairo_surface_t,
	layout:        ^pango_layout_t,
	measure:       ^pango_layout_t,
}

CANVAS_MIN_SCALE :: 1.0
CANVAS_MAX_SCALE :: 6.0

canvas_init :: proc(c: ^Canvas, width, height: int, scale: f32 = 1.0) {
	c.scale = clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE)
	c.width = max(width, 1)
	c.height = max(height, 1)
	c.pixels = make([]u32, c.width * c.height)
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	c.surface = cairo_image_surface_create_for_data(
		cast([^]u8)raw_data(c.pixels), CANVAS_CAIRO_FORMAT_ARGB32,
		i32(c.width), i32(c.height), i32(c.width * 4))
	c.cr = cairo_create(c.surface)
	cairo_set_antialias(c.cr, CANVAS_ANTIALIAS_BEST)
	cairo_set_line_join(c.cr, CANVAS_LINE_JOIN_ROUND)
	cairo_set_line_cap(c.cr, CANVAS_LINE_CAP_ROUND)
	c.layout = pango_cairo_create_layout(c.cr)
	c.measure = pango_cairo_create_layout(c.cr)
	if c.layout != nil {
		pango_cairo_context_set_resolution(pango_layout_get_context(c.layout), 72.0)
	}
	if c.measure != nil {
		pango_cairo_context_set_resolution(pango_layout_get_context(c.measure), 72.0)
	}
	canvas_clear(c, 0)
}

canvas_destroy :: proc(c: ^Canvas) {
	if c.measure != nil {
		g_object_unref(c.measure)
		c.measure = nil
	}
	if c.layout != nil {
		g_object_unref(c.layout)
		c.layout = nil
	}
	if c.cr != nil {
		cairo_destroy(c.cr)
		c.cr = nil
	}
	if c.surface != nil {
		cairo_surface_destroy(c.surface)
		c.surface = nil
	}
	delete(c.pixels)
	c.pixels = nil
}

canvas_flush :: proc(c: ^Canvas) {
	if c.surface != nil {
		cairo_surface_flush(c.surface)
	}
}

canvas_pixel_size :: proc(logical: int, scale: f32) -> int {
	return max(int(math.ceil(f32(logical) * clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE))), 1)
}

canvas_resize :: proc(c: ^Canvas, width, height: int) {
	if width == c.width && height == c.height {
		return
	}
	if c.measure != nil {
		g_object_unref(c.measure)
		c.measure = nil
	}
	if c.layout != nil {
		g_object_unref(c.layout)
		c.layout = nil
	}
	if c.cr != nil {
		cairo_destroy(c.cr)
		c.cr = nil
	}
	if c.surface != nil {
		cairo_surface_destroy(c.surface)
		c.surface = nil
	}
	delete(c.pixels)

	c.width = max(width, 1)
	c.height = max(height, 1)
	c.pixels = make([]u32, c.width * c.height)
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	c.surface = cairo_image_surface_create_for_data(
		cast([^]u8)raw_data(c.pixels), CANVAS_CAIRO_FORMAT_ARGB32,
		i32(c.width), i32(c.height), i32(c.width * 4))
	c.cr = cairo_create(c.surface)
	cairo_set_antialias(c.cr, CANVAS_ANTIALIAS_BEST)
	cairo_set_line_join(c.cr, CANVAS_LINE_JOIN_ROUND)
	cairo_set_line_cap(c.cr, CANVAS_LINE_CAP_ROUND)
	c.layout = pango_cairo_create_layout(c.cr)
	c.measure = pango_cairo_create_layout(c.cr)
	if c.layout != nil {
		pango_cairo_context_set_resolution(pango_layout_get_context(c.layout), 72.0)
	}
	if c.measure != nil {
		pango_cairo_context_set_resolution(pango_layout_get_context(c.measure), 72.0)
	}
	canvas_clear(c, 0)
}

canvas_set_scale :: proc(c: ^Canvas, scale: f32) {
	s := clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE)
	if s == c.scale {
		return
	}
	c.scale = s
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	canvas_apply_clip(c)
}

canvas_logical_width :: proc(c: ^Canvas) -> int {
	return max(int(math.round(f32(c.width) / c.scale)), 1)
}

canvas_logical_height :: proc(c: ^Canvas) -> int {
	return max(int(math.round(f32(c.height) / c.scale)), 1)
}

canvas_physical_to_logical :: proc(c: ^Canvas, x, y: f32) -> (f32, f32) {
	return x / c.scale, y / c.scale
}

@(private)
scale_rect :: proc(c: ^Canvas, r: Rect) -> Rect {
	return Rect{r.x * c.scale, r.y * c.scale, r.w * c.scale, r.h * c.scale}
}

@(private)
cairo_color :: proc(c: ^Canvas, col: Color) {
	cairo_set_source_rgba(c.cr,
		f64((col >> 16) & 0xFF) / 255.0,
		f64((col >> 8) & 0xFF) / 255.0,
		f64(col & 0xFF) / 255.0,
		f64((col >> 24) & 0xFF) / 255.0)
}

@(private)
canvas_apply_clip :: proc(c: ^Canvas) {
	if c.cr == nil {
		return
	}
	cairo_reset_clip(c.cr)
	if c.clip.w <= 0 || c.clip.h <= 0 {
		cairo_rectangle(c.cr, 0, 0, 0, 0)
	} else {
		cairo_rectangle(c.cr, f64(c.clip.x), f64(c.clip.y), f64(c.clip.w), f64(c.clip.h))
	}
	cairo_clip(c.cr)
}

@(private)
fill_device :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color) {
	if c.cr == nil || (col >> 24) == 0 {
		return
	}
	ax := max(x0, c.clip.x)
	ay := max(y0, c.clip.y)
	bx := min(x1, c.clip.x + c.clip.w)
	by := min(y1, c.clip.y + c.clip.h)
	if bx <= ax || by <= ay {
		return
	}
	cairo_set_antialias(c.cr, CANVAS_ANTIALIAS_NONE)
	cairo_color(c, col)
	cairo_rectangle(c.cr, f64(math.round(ax)), f64(math.round(ay)),
		f64(max(math.round(bx) - math.round(ax), 1)),
		f64(max(math.round(by) - math.round(ay), 1)))
	cairo_fill(c.cr)
	cairo_set_antialias(c.cr, CANVAS_ANTIALIAS_BEST)
}

canvas_clear :: proc(c: ^Canvas, col: Color) {
	if c.cr == nil {
		return
	}
	cairo_set_operator(c.cr, CANVAS_OPERATOR_SOURCE)
	cairo_color(c, col)
	cairo_paint(c.cr)
	cairo_set_operator(c.cr, CANVAS_OPERATOR_OVER)
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	canvas_apply_clip(c)
}

canvas_nonblank :: proc(c: ^Canvas) -> bool {
	canvas_flush(c)
	if len(c.pixels) == 0 {
		return false
	}
	base := c.pixels[0]
	changed := 0
	threshold := max(len(c.pixels) / 200, 1)
	for p in c.pixels {
		if p != base {
			changed += 1
			if changed > threshold {
				return true
			}
		}
	}
	return false
}

canvas_push_clip :: proc(c: ^Canvas, r: Rect) -> Rect {
	old := c.clip
	pr := scale_rect(c, r)
	c.clip = rect_intersect(c.clip, pr)
	canvas_apply_clip(c)
	return old
}

canvas_pop_clip :: proc(c: ^Canvas, old: Rect) {
	c.clip = old
	canvas_apply_clip(c)
}

canvas_fill :: proc(c: ^Canvas, r: Rect, col: Color) {
	if r.w <= 0 || r.h <= 0 || (col >> 24) == 0 {
		return
	}
	pr := scale_rect(c, r)
	fill_device(c, pr.x, pr.y, pr.x + pr.w, pr.y + pr.h, col)
}

canvas_rect :: proc(c: ^Canvas, r: Rect, col: Color, thickness: i32 = 1) {
	t := max(thickness, 1)
	canvas_fill(c, Rect{r.x, r.y, r.w, f32(t)}, col)
	canvas_fill(c, Rect{r.x, r.y + r.h - f32(t), r.w, f32(t)}, col)
	canvas_fill(c, Rect{r.x, r.y + f32(t), f32(t), max(r.h - f32(t) * 2, 0)}, col)
	canvas_fill(c, Rect{r.x + r.w - f32(t), r.y + f32(t), f32(t), max(r.h - f32(t) * 2, 0)}, col)
}

canvas_hline :: proc(c: ^Canvas, x0, x1, y: f32, col: Color) {
	s := c.scale
	fill_device(c, min(x0, x1) * s, y * s, (max(x0, x1) + 1) * s, (y + 1) * s, col)
}

canvas_vline :: proc(c: ^Canvas, x, y0, y1: f32, col: Color) {
	s := c.scale
	fill_device(c, x * s, min(y0, y1) * s, (x + 1) * s, (max(y0, y1) + 1) * s, col)
}

canvas_line :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color) {
	if c.cr == nil || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(max(s, 1)))
	cairo_move_to(c.cr, f64(x0 * s), f64(y0 * s))
	cairo_line_to(c.cr, f64(x1 * s), f64(y1 * s))
	cairo_stroke(c.cr)
}

canvas_circle_fill :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_new_path(c.cr)
	cairo_arc(c.cr, f64(cx * s), f64(cy * s), f64(radius * s), 0, math.TAU)
	cairo_fill(c.cr)
}

canvas_circle :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(max(s, 1)))
	cairo_new_path(c.cr)
	cairo_arc(c.cr, f64(cx * s), f64(cy * s), f64(radius * s), 0, math.TAU)
	cairo_stroke(c.cr)
}

// Angles are radians, 0 = right, clockwise on screen.
canvas_arc :: proc(c: ^Canvas, cx, cy, radius, a0, a1: f32, col: Color, thickness: f32 = 1) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(max(thickness * s, 1)))
	cairo_new_path(c.cr)
	if a1 >= a0 {
		cairo_arc(c.cr, f64(cx * s), f64(cy * s), f64(radius * s), f64(a0), f64(a1))
	} else {
		cairo_arc(c.cr, f64(cx * s), f64(cy * s), f64(radius * s), f64(a0), f64(a1))
	}
	cairo_stroke(c.cr)
}

text_width :: proc(text: string, scale: int = 1) -> f32 {
	return f32(len(text)) * f32(FONT_W) * f32(max(scale, 1))
}

text_height :: proc(scale: int = 1) -> f32 {
	return f32(FONT_H) * f32(max(scale, 1))
}

@(private)
font_small_alpha :: proc(index, row, col: int) -> u8 {
	shift := u64((FONT_W - 1 - col) * 8)
	return u8((FONT_SMALL_ALPHA[index][row] >> shift) & 0xFF)
}

@(private)
font_large_alpha :: proc(index, row, col: int) -> u8 {
	half := col / 8
	shift := u64((7 - (col % 8)) * 8)
	return u8((FONT_LARGE_ALPHA[index][row][half] >> shift) & 0xFF)
}

// ---------------------------------------------------------------- AA shapes

canvas_fill_round :: proc(c: ^Canvas, r: Rect, radius: f32, col: Color) {
	if r.w <= 0 || r.h <= 0 || (col >> 24) == 0 {
		return
	}
	rad := clamp(radius, 0, min(r.w, r.h) * 0.5)
	if rad <= 0.01 {
		canvas_fill(c, r, col)
		return
	}
	s := c.scale
	x0 := r.x * s
	y0 := r.y * s
	x1 := (r.x + r.w) * s
	y1 := (r.y + r.h) * s
	rr := rad * s
	cairo_color(c, col)
	cairo_new_path(c.cr)
	cairo_arc(c.cr, f64(x0 + rr), f64(y0 + rr), f64(rr), math.PI, math.PI * 1.5)
	cairo_arc(c.cr, f64(x1 - rr), f64(y0 + rr), f64(rr), math.PI * 1.5, math.TAU)
	cairo_arc(c.cr, f64(x1 - rr), f64(y1 - rr), f64(rr), 0, math.PI * 0.5)
	cairo_arc(c.cr, f64(x0 + rr), f64(y1 - rr), f64(rr), math.PI * 0.5, math.PI)
	cairo_close_path(c.cr)
	cairo_fill(c.cr)
}

canvas_stroke_round :: proc(c: ^Canvas, r: Rect, radius: f32, col: Color, thickness: f32 = 1) {
	if r.w <= 0 || r.h <= 0 || (col >> 24) == 0 || thickness <= 0 {
		return
	}
	rad := clamp(radius, 0, min(r.w, r.h) * 0.5)
	s := c.scale
	x0 := r.x * s
	y0 := r.y * s
	x1 := (r.x + r.w) * s
	y1 := (r.y + r.h) * s
	rr := rad * s
	t := max(thickness * s, 0.5)
	// Keep the stroke inside the rect, like the software canvas did.
	off := t * 0.5
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(t))
	cairo_new_path(c.cr)
	cairo_arc(c.cr, f64(x0 + rr), f64(y0 + rr), f64(rr - off), math.PI, math.PI * 1.5)
	cairo_arc(c.cr, f64(x1 - rr), f64(y0 + rr), f64(rr - off), math.PI * 1.5, math.TAU)
	cairo_arc(c.cr, f64(x1 - rr), f64(y1 - rr), f64(rr - off), 0, math.PI * 0.5)
	cairo_arc(c.cr, f64(x0 + rr), f64(y1 - rr), f64(rr - off), math.PI * 0.5, math.PI)
	cairo_close_path(c.cr)
	cairo_stroke(c.cr)
}

canvas_shadow :: proc(c: ^Canvas, r: Rect, radius: f32, spread: f32, col: Color) {
	if spread <= 0 || (col >> 24) == 0 {
		return
	}
	layers := 3
	for i in 1 ..= layers {
		off := spread * f32(i) / f32(layers)
		a := u8(max(int((col >> 24) & 0xFF) / (i + 1), 1))
		canvas_fill_round(c,
			Rect{r.x - off, r.y - off + 1, r.w + off * 2, r.h + off * 2},
			radius + off, (col & 0x00FFFFFF) | (Color(a) << 24))
	}
}

canvas_line_aa :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color, thickness: f32 = 1) {
	if c.cr == nil || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(max(thickness * s, 1)))
	cairo_move_to(c.cr, f64(x0 * s), f64(y0 * s))
	cairo_line_to(c.cr, f64(x1 * s), f64(y1 * s))
	cairo_stroke(c.cr)
}

canvas_disc :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	canvas_circle_fill(c, cx, cy, radius, col)
}

canvas_ring :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color, thickness: f32 = 1) {
	canvas_circle(c, cx, cy, radius, col)
	if thickness != 1 && c.cr != nil {
		// canvas_circle always strokes 1 logical px; redraw at the requested width.
		s := c.scale
		cairo_color(c, col)
		cairo_set_line_width(c.cr, f64(max(thickness * s, 1)))
		cairo_new_path(c.cr)
		cairo_arc(c.cr, f64(cx * s), f64(cy * s), f64(radius * s), 0, math.TAU)
		cairo_stroke(c.cr)
	}
}

canvas_arc_aa :: proc(c: ^Canvas, cx, cy, radius, a0, a1: f32, col: Color, thickness: f32 = 2) {
	canvas_arc(c, cx, cy, radius, a0, a1, col, thickness)
}

Point :: struct {
	x, y: f32,
}

canvas_polyline :: proc(c: ^Canvas, pts: []Point, col: Color, thickness: f32 = 1.5) {
	if len(pts) < 2 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_set_line_width(c.cr, f64(max(thickness * s, 1)))
	cairo_new_path(c.cr)
	cairo_move_to(c.cr, f64(pts[0].x * s), f64(pts[0].y * s))
	for i in 1 ..< len(pts) {
		cairo_line_to(c.cr, f64(pts[i].x * s), f64(pts[i].y * s))
	}
	cairo_stroke(c.cr)
}

// Filled area between a curve and a baseline, painted with a vertical
// gradient. This is the chart workhorse for EQ / compressor / reverb / limiter
// response graphics.
canvas_area_gradient :: proc(c: ^Canvas, pts: []Point, base_y: f32, top, bottom: Color) {
	if len(pts) < 2 || c.cr == nil {
		return
	}
	s := c.scale
	min_y := pts[0].y
	for p in pts {
		min_y = min(min_y, p.y)
	}
	pat := cairo_pattern_create_linear(0, f64(min_y * s), 0, f64(base_y * s))
	cairo_pattern_add_color_stop_rgba(pat, 0,
		f64((top >> 16) & 0xFF) / 255.0, f64((top >> 8) & 0xFF) / 255.0, f64(top & 0xFF) / 255.0, f64((top >> 24) & 0xFF) / 255.0)
	cairo_pattern_add_color_stop_rgba(pat, 1,
		f64((bottom >> 16) & 0xFF) / 255.0, f64((bottom >> 8) & 0xFF) / 255.0, f64(bottom & 0xFF) / 255.0, f64((bottom >> 24) & 0xFF) / 255.0)
	cairo_new_path(c.cr)
	cairo_move_to(c.cr, f64(pts[0].x * s), f64(pts[0].y * s))
	for i in 1 ..< len(pts) {
		cairo_line_to(c.cr, f64(pts[i].x * s), f64(pts[i].y * s))
	}
	cairo_line_to(c.cr, f64(pts[len(pts) - 1].x * s), f64(base_y * s))
	cairo_line_to(c.cr, f64(pts[0].x * s), f64(base_y * s))
	cairo_close_path(c.cr)
	cairo_set_source(c.cr, pat)
	cairo_fill(c.cr)
	cairo_pattern_destroy(pat)
}

canvas_triangle :: proc(c: ^Canvas, x0, y0, x1, y1, x2, y2: f32, col: Color) {
	if c.cr == nil || (col >> 24) == 0 {
		return
	}
	s := c.scale
	cairo_color(c, col)
	cairo_new_path(c.cr)
	cairo_move_to(c.cr, f64(x0 * s), f64(y0 * s))
	cairo_line_to(c.cr, f64(x1 * s), f64(y1 * s))
	cairo_line_to(c.cr, f64(x2 * s), f64(y2 * s))
	cairo_close_path(c.cr)
	cairo_fill(c.cr)
}

canvas_gradient_v :: proc(c: ^Canvas, r: Rect, top, bottom: Color) {
	if r.w <= 0 || r.h <= 0 || c.cr == nil {
		return
	}
	s := c.scale
	x0 := r.x * s
	y0 := r.y * s
	x1 := (r.x + r.w) * s
	y1 := (r.y + r.h) * s
	pat := cairo_pattern_create_linear(f64(x0), f64(y0), f64(x0), f64(y1))
	ta := f64((top >> 24) & 0xFF) / 255.0
	ba := f64((bottom >> 24) & 0xFF) / 255.0
	cairo_pattern_add_color_stop_rgba(pat, 0,
		f64((top >> 16) & 0xFF) / 255.0, f64((top >> 8) & 0xFF) / 255.0, f64(top & 0xFF) / 255.0, ta)
	cairo_pattern_add_color_stop_rgba(pat, 1,
		f64((bottom >> 16) & 0xFF) / 255.0, f64((bottom >> 8) & 0xFF) / 255.0, f64(bottom & 0xFF) / 255.0, ba)
	cairo_set_source(c.cr, pat)
	cairo_rectangle(c.cr, f64(x0), f64(y0), f64(x1 - x0), f64(y1 - y0))
	cairo_fill(c.cr)
	cairo_pattern_destroy(pat)
}

// ---------------------------------------------------------------- legacy text

// The shell no longer uses the baked mono atlas, but the headless font tests
// still exercise it and a few fixed-cell call sites remain. These wrappers
// render through the proportional path at the same nominal size.
canvas_text :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, scale: int = 1) {
	canvas_text_px(c, x, y, text, col, 12.5 * f32(max(scale, 1)), .Mono)
}

canvas_text_right :: proc(c: ^Canvas, right, y: f32, text: string, col: Color, scale: int = 1) {
	px := 12.5 * f32(max(scale, 1))
	canvas_text_px(c, right - canvas_text_width(c, text, px, .Mono), y, text, col, px, .Mono)
}

canvas_text_center :: proc(c: ^Canvas, cx, y: f32, text: string, col: Color, scale: int = 1) {
	px := 12.5 * f32(max(scale, 1))
	canvas_text_px(c, cx - canvas_text_width(c, text, px, .Mono) * 0.5, y, text, col, px, .Mono)
}

canvas_text_clip :: proc(c: ^Canvas, x, y, max_width: f32, text: string, col: Color, scale: int = 1) {
	px := 12.5 * f32(max(scale, 1))
	canvas_text_px_clip(c, x, y, max_width, text, col, px, .Mono)
}
