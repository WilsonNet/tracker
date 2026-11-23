#+build !linux
// Pure-Odin software vector canvas for the headless harness on macOS and
// non-Linux platforms (avoids requiring Pango/Cairo at build or runtime).
package ui

import "core:math"

// `width`/`height` are physical pixels; `scale` is physical pixels per logical
// pixel. All public drawing calls take logical coordinates.
Canvas :: struct {
	width, height: int,
	pixels:        []u32,
	clip:          Rect, // physical pixels
	scale:         f32,
}

canvas_init :: proc(c: ^Canvas, width, height: int, scale: f32 = 1.0) {
	c.scale = clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE)
	c.width = max(width, 1)
	c.height = max(height, 1)
	c.pixels = make([]u32, c.width * c.height)
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	canvas_clear(c, 0)
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.pixels)
	c.pixels = nil
}

canvas_flush :: proc(c: ^Canvas) {
}

canvas_resize :: proc(c: ^Canvas, width, height: int) {
	if width == c.width && height == c.height {
		return
	}
	delete(c.pixels)
	c.width = max(width, 1)
	c.height = max(height, 1)
	c.pixels = make([]u32, c.width * c.height)
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
	canvas_clear(c, 0)
}

canvas_set_scale :: proc(c: ^Canvas, scale: f32) {
	s := clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE)
	if s == c.scale {
		return
	}
	c.scale = s
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
}

@(private)
soft_blend :: proc "contextless" (dst, src: Color, cov: f32 = 1.0) -> Color {
	sa := f32((src >> 24) & 0xFF) * clamp(cov, 0, 1)
	if sa <= 0.5 {
		return dst
	}
	if sa >= 254.5 {
		return src | 0xFF000000
	}
	a := sa / 255.0
	inv := 1.0 - a
	sr := f32((src >> 16) & 0xFF)
	sg := f32((src >> 8) & 0xFF)
	sb := f32(src & 0xFF)

	dr := f32((dst >> 16) & 0xFF)
	dg := f32((dst >> 8) & 0xFF)
	db := f32(dst & 0xFF)
	da := f32((dst >> 24) & 0xFF)

	rr := u32(clamp(sr * a + dr * inv + 0.5, 0, 255))
	rg := u32(clamp(sg * a + dg * inv + 0.5, 0, 255))
	rb := u32(clamp(sb * a + db * inv + 0.5, 0, 255))
	ra := u32(clamp(sa + da * inv + 0.5, 0, 255))
	return (ra << 24) | (rr << 16) | (rg << 8) | rb
}

@(private)
soft_plot :: proc "contextless" (c: ^Canvas, px, py: int, col: Color, cov: f32 = 1.0) {
	if px < 0 || py < 0 || px >= c.width || py >= c.height {
		return
	}
	fx := f32(px) + 0.5
	fy := f32(py) + 0.5
	if fx < c.clip.x || fy < c.clip.y || fx >= c.clip.x + c.clip.w || fy >= c.clip.y + c.clip.h {
		return
	}
	idx := py * c.width + px
	c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
}

@(private)
soft_clip_bounds :: proc(c: ^Canvas, x0, y0, x1, y1: f32) -> (ix0, iy0, ix1, iy1: int, ok: bool) {
	ax := max(x0, c.clip.x, 0)
	ay := max(y0, c.clip.y, 0)
	bx := min(x1, c.clip.x + c.clip.w, f32(c.width))
	by := min(y1, c.clip.y + c.clip.h, f32(c.height))
	if bx <= ax || by <= ay {
		return 0, 0, 0, 0, false
	}
	ix0 = clamp(int(math.floor(ax)), 0, c.width)
	iy0 = clamp(int(math.floor(ay)), 0, c.height)
	ix1 = clamp(int(math.ceil(bx)), 0, c.width)
	iy1 = clamp(int(math.ceil(by)), 0, c.height)
	ok = ix1 > ix0 && iy1 > iy0
	return
}

@(private)
fill_device :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color) {
	if (col >> 24) == 0 || len(c.pixels) == 0 {
		return
	}
	ax := max(x0, c.clip.x, 0)
	ay := max(y0, c.clip.y, 0)
	bx := min(x1, c.clip.x + c.clip.w, f32(c.width))
	by := min(y1, c.clip.y + c.clip.h, f32(c.height))
	if bx <= ax || by <= ay {
		return
	}
	rx0 := clamp(int(math.round(ax)), 0, c.width)
	ry0 := clamp(int(math.round(ay)), 0, c.height)
	rx1 := clamp(int(math.round(bx)), 0, c.width)
	ry1 := clamp(int(math.round(by)), 0, c.height)
	if rx1 <= rx0 {
		rx1 = min(rx0 + 1, c.width)
	}
	if ry1 <= ry0 {
		ry1 = min(ry0 + 1, c.height)
	}
	alpha := (col >> 24) & 0xFF
	for y in ry0 ..< ry1 {
		row := y * c.width
		if alpha == 0xFF {
			for x in rx0 ..< rx1 {
				c.pixels[row + x] = col
			}
		} else {
			for x in rx0 ..< rx1 {
				c.pixels[row + x] = soft_blend(c.pixels[row + x], col, 1.0)
			}
		}
	}
}

canvas_clear :: proc(c: ^Canvas, col: Color) {
	for i in 0 ..< len(c.pixels) {
		c.pixels[i] = col
	}
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
}

canvas_push_clip :: proc(c: ^Canvas, r: Rect) -> Rect {
	old := c.clip
	pr := scale_rect(c, r)
	c.clip = rect_intersect(c.clip, pr)
	return old
}

canvas_pop_clip :: proc(c: ^Canvas, old: Rect) {
	c.clip = old
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
	canvas_line_aa(c, x0, y0, x1, y1, col, 1.0)
}

canvas_line_aa :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color, thickness: f32 = 1) {
	if (col >> 24) == 0 {
		return
	}
	s := c.scale
	ax := x0 * s
	ay := y0 * s
	bx := x1 * s
	by := y1 * s
	half_w := max(thickness * s, 1.0) * 0.5
	pad := half_w + 1.0
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, min(ax, bx) - pad, min(ay, by) - pad, max(ax, bx) + pad, max(ay, by) + pad)
	if !ok {
		return
	}
	dx := bx - ax
	dy := by - ay
	len_sq := dx * dx + dy * dy
	for py in iy0 ..< iy1 {
		cy := f32(py) + 0.5
		for px in ix0 ..< ix1 {
			cx := f32(px) + 0.5
			t: f32 = 0
			if len_sq > 1e-6 {
				t = clamp(((cx - ax) * dx + (cy - ay) * dy) / len_sq, 0, 1)
			}
			px_proj := ax + t * dx
			py_proj := ay + t * dy
			dist := math.sqrt((cx - px_proj) * (cx - px_proj) + (cy - py_proj) * (cy - py_proj))
			cov := clamp(half_w + 0.5 - dist, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
}

canvas_circle_fill :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	pcx := cx * s
	pcy := cy * s
	pr := radius * s
	pad := pr + 1.5
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pcx - pad, pcy - pad, pcx + pad, pcy + pad)
	if !ok {
		return
	}
	for py in iy0 ..< iy1 {
		dy := f32(py) + 0.5 - pcy
		for px in ix0 ..< ix1 {
			dx := f32(px) + 0.5 - pcx
			dist := math.sqrt(dx * dx + dy * dy)
			cov := clamp(pr + 0.5 - dist, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
}

canvas_circle :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	canvas_ring(c, cx, cy, radius, col, 1.0)
}

canvas_disc :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	canvas_circle_fill(c, cx, cy, radius, col)
}

canvas_ring :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color, thickness: f32 = 1) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	pcx := cx * s
	pcy := cy * s
	pr := radius * s
	half_w := max(thickness * s, 1.0) * 0.5
	pad := pr + half_w + 1.5
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pcx - pad, pcy - pad, pcx + pad, pcy + pad)
	if !ok {
		return
	}
	for py in iy0 ..< iy1 {
		dy := f32(py) + 0.5 - pcy
		for px in ix0 ..< ix1 {
			dx := f32(px) + 0.5 - pcx
			dist := abs(math.sqrt(dx * dx + dy * dy) - pr)
			cov := clamp(half_w + 0.5 - dist, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
}

@(private)
angle_in_arc :: proc(ang, a0, a1: f32) -> bool {
	span := a1 - a0
	if abs(span) >= math.TAU - 1e-4 {
		return true
	}
	norm :: proc(x: f32) -> f32 {
		v := math.mod(x, math.TAU)
		return v + math.TAU if v < 0 else v
	}
	if span >= 0 {
		return norm(ang - a0) <= span + 1e-4
	}
	return norm(a0 - ang) <= (-span) + 1e-4
}

canvas_arc :: proc(c: ^Canvas, cx, cy, radius, a0, a1: f32, col: Color, thickness: f32 = 1) {
	if radius <= 0 || (col >> 24) == 0 {
		return
	}
	s := c.scale
	pcx := cx * s
	pcy := cy * s
	pr := radius * s
	half_w := max(thickness * s, 1.0) * 0.5
	pad := pr + half_w + 1.5
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pcx - pad, pcy - pad, pcx + pad, pcy + pad)
	if !ok {
		return
	}
	for py in iy0 ..< iy1 {
		dy := f32(py) + 0.5 - pcy
		for px in ix0 ..< ix1 {
			dx := f32(px) + 0.5 - pcx
			dist := abs(math.sqrt(dx * dx + dy * dy) - pr)
			if dist > half_w + 0.5 {
				continue
			}
			ang := math.atan2(dy, dx)
			if !angle_in_arc(ang, a0, a1) {
				continue
			}
			cov := clamp(half_w + 0.5 - dist, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
}

canvas_arc_aa :: proc(c: ^Canvas, cx, cy, radius, a0, a1: f32, col: Color, thickness: f32 = 2) {
	canvas_arc(c, cx, cy, radius, a0, a1, col, thickness)
}

@(private)
round_box_sdf :: proc(dx, dy, hx, hy, rad: f32) -> f32 {
	qx := abs(dx) - (hx - rad)
	qy := abs(dy) - (hy - rad)
	ox := max(qx, 0)
	oy := max(qy, 0)
	return min(max(qx, qy), 0) + math.sqrt(ox * ox + oy * oy) - rad
}

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
	pr := scale_rect(c, r)
	rr := rad * s
	cx := pr.x + pr.w * 0.5
	cy := pr.y + pr.h * 0.5
	hx := pr.w * 0.5
	hy := pr.h * 0.5
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pr.x - 1, pr.y - 1, pr.x + pr.w + 1, pr.y + pr.h + 1)
	if !ok {
		return
	}
	for py in iy0 ..< iy1 {
		dy := f32(py) + 0.5 - cy
		for px in ix0 ..< ix1 {
			dx := f32(px) + 0.5 - cx
			d := round_box_sdf(dx, dy, hx, hy, rr)
			cov := clamp(0.5 - d, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
}

canvas_stroke_round :: proc(c: ^Canvas, r: Rect, radius: f32, col: Color, thickness: f32 = 1) {
	if r.w <= 0 || r.h <= 0 || (col >> 24) == 0 || thickness <= 0 {
		return
	}
	rad := clamp(radius, 0, min(r.w, r.h) * 0.5)
	s := c.scale
	pr := scale_rect(c, r)
	t := max(thickness * s, 0.5)
	off := t * 0.5
	rr := max(rad * s - off, 0)
	cx := pr.x + pr.w * 0.5
	cy := pr.y + pr.h * 0.5
	hx := max(pr.w * 0.5 - off, 0)
	hy := max(pr.h * 0.5 - off, 0)
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pr.x - 1, pr.y - 1, pr.x + pr.w + 1, pr.y + pr.h + 1)
	if !ok {
		return
	}
	for py in iy0 ..< iy1 {
		dy := f32(py) + 0.5 - cy
		for px in ix0 ..< ix1 {
			dx := f32(px) + 0.5 - cx
			d := abs(round_box_sdf(dx, dy, hx, hy, rr))
			cov := clamp(off + 0.5 - d, 0, 1)
			if cov > 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, cov)
			}
		}
	}
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

canvas_polyline :: proc(c: ^Canvas, pts: []Point, col: Color, thickness: f32 = 1.5) {
	if len(pts) < 2 || (col >> 24) == 0 {
		return
	}
	for i in 0 ..< len(pts) - 1 {
		canvas_line_aa(c, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, col, thickness)
	}
}

@(private)
lerp_color :: proc(a, b: Color, t: f32) -> Color {
	u := clamp(t, 0, 1)
	aa := f32((a >> 24) & 0xFF)
	ar := f32((a >> 16) & 0xFF)
	ag := f32((a >> 8) & 0xFF)
	ab := f32(a & 0xFF)

	ba := f32((b >> 24) & 0xFF)
	br := f32((b >> 16) & 0xFF)
	bg := f32((b >> 8) & 0xFF)
	bb := f32(b & 0xFF)

	ra := u32(aa + (ba - aa) * u + 0.5)
	rr := u32(ar + (br - ar) * u + 0.5)
	rg := u32(ag + (bg - ag) * u + 0.5)
	rb := u32(ab + (bb - ab) * u + 0.5)
	return (ra << 24) | (rr << 16) | (rg << 8) | rb
}

canvas_area_gradient :: proc(c: ^Canvas, pts: []Point, base_y: f32, top, bottom: Color) {
	if len(pts) < 2 {
		return
	}
	s := c.scale
	min_y := pts[0].y
	for p in pts {
		min_y = min(min_y, p.y)
	}
	p_min_y := min_y * s
	p_base_y := base_y * s
	grad_span := max(p_base_y - p_min_y, 1.0)

	for i in 0 ..< len(pts) - 1 {
		ax := pts[i].x * s
		ay := pts[i].y * s
		bx := pts[i + 1].x * s
		by := pts[i + 1].y * s
		if bx == ax {
			continue
		}
		if bx < ax {
			ax, bx = bx, ax
			ay, by = by, ay
		}
		ix0, _, ix1, _, ok := soft_clip_bounds(c, ax, min(ay, by, p_base_y), bx, max(ay, by, p_base_y))
		if !ok {
			continue
		}
		for px in ix0 ..< ix1 {
			x_mid := f32(px) + 0.5
			if x_mid < ax || x_mid > bx {
				continue
			}
			u := (x_mid - ax) / (bx - ax)
			cy := ay + (by - ay) * u
			y0 := min(cy, p_base_y)
			y1 := max(cy, p_base_y)
			_, iy0, _, iy1, yok := soft_clip_bounds(c, f32(px), y0, f32(px + 1), y1)
			if !yok {
				continue
			}
			for py in iy0 ..< iy1 {
				gt := clamp((f32(py) + 0.5 - p_min_y) / grad_span, 0, 1)
				col := lerp_color(top, bottom, gt)
				if (col >> 24) > 0 {
					idx := py * c.width + px
					c.pixels[idx] = soft_blend(c.pixels[idx], col, 1.0)
				}
			}
		}
	}
}

canvas_triangle :: proc(c: ^Canvas, x0, y0, x1, y1, x2, y2: f32, col: Color) {
	if (col >> 24) == 0 {
		return
	}
	s := c.scale
	ax, ay := x0 * s, y0 * s
	bx, by := x1 * s, y1 * s
	cx, cy := x2 * s, y2 * s
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, min(ax, bx, cx) - 1, min(ay, by, cy) - 1, max(ax, bx, cx) + 1, max(ay, by, cy) + 1)
	if !ok {
		return
	}
	edge :: proc(ax, ay, bx, by, px, py: f32) -> f32 {
		return (px - ax) * (by - ay) - (py - ay) * (bx - ax)
	}
	area := edge(ax, ay, bx, by, cx, cy)
	if abs(area) < 1e-6 {
		return
	}
	sign: f32 = 1.0 if area > 0 else -1.0
	for py in iy0 ..< iy1 {
		fy := f32(py) + 0.5
		for px in ix0 ..< ix1 {
			fx := f32(px) + 0.5
			w0 := edge(ax, ay, bx, by, fx, fy) * sign
			w1 := edge(bx, by, cx, cy, fx, fy) * sign
			w2 := edge(cx, cy, ax, ay, fx, fy) * sign
			if w0 >= 0 && w1 >= 0 && w2 >= 0 {
				idx := py * c.width + px
				c.pixels[idx] = soft_blend(c.pixels[idx], col, 1.0)
			}
		}
	}
}

canvas_gradient_v :: proc(c: ^Canvas, r: Rect, top, bottom: Color) {
	if r.w <= 0 || r.h <= 0 {
		return
	}
	pr := scale_rect(c, r)
	ix0, iy0, ix1, iy1, ok := soft_clip_bounds(c, pr.x, pr.y, pr.x + pr.w, pr.y + pr.h)
	if !ok {
		return
	}
	span := max(pr.h, 1.0)
	for py in iy0 ..< iy1 {
		t := clamp((f32(py) + 0.5 - pr.y) / span, 0, 1)
		col := lerp_color(top, bottom, t)
		if (col >> 24) == 0 {
			continue
		}
		for px in ix0 ..< ix1 {
			idx := py * c.width + px
			c.pixels[idx] = soft_blend(c.pixels[idx], col, 1.0)
		}
	}
}
