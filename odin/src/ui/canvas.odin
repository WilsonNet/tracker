// Flat software canvas. Every pixel the app shows is drawn here first, which is
// what makes the native UI testable headlessly: the harness renders the exact
// same frames the SDL window uploads.

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

// `width`/`height` are physical pixels (the size of the pixel buffer). `scale`
// is physical pixels per logical pixel: all public drawing calls take logical
// coordinates, so the layout code never has to know the display density.
Canvas :: struct {
	width, height: int,
	pixels:        []u32,
	clip:          Rect, // physical pixels
	scale:         f32,
	font:          Runtime_Font,
}

CANVAS_MIN_SCALE :: 1.0
CANVAS_MAX_SCALE :: 3.0

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
	runtime_font_destroy(&c.font)
}

// Physical size for a logical size at the canvas density (rounded up so the
// last logical pixel is never lost).
canvas_pixel_size :: proc(logical: int, scale: f32) -> int {
	return max(int(math.ceil(f32(logical) * clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE))), 1)
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

// Logical size of the canvas at the current density.
canvas_logical_width :: proc(c: ^Canvas) -> int {
	return max(int(math.round(f32(c.width) / c.scale)), 1)
}

canvas_logical_height :: proc(c: ^Canvas) -> int {
	return max(int(math.round(f32(c.height) / c.scale)), 1)
}

// Map a point from physical pixels (window/backing-buffer space) to the
// logical coordinates the UI state machine uses. The window layer uses this
// for pointer events; the headless harness uses it to drive targets at 2x.
canvas_physical_to_logical :: proc(c: ^Canvas, x, y: f32) -> (f32, f32) {
	return x / c.scale, y / c.scale
}

@(private)
scale_rect :: proc(c: ^Canvas, r: Rect) -> Rect {
	return Rect{r.x * c.scale, r.y * c.scale, r.w * c.scale, r.h * c.scale}
}

@(private)
blend_channel :: proc(src, dst: u32, a: u32) -> u32 {
	return (src * a + dst * (255 - a)) / 255
}

@(private)
plot :: proc(c: ^Canvas, x, y: i32, col: Color) {
	if x < i32(c.clip.x) || y < i32(c.clip.y) ||
	   x >= i32(c.clip.x + c.clip.w) || y >= i32(c.clip.y + c.clip.h) {
		return
	}
	if x < 0 || y < 0 || x >= i32(c.width) || y >= i32(c.height) {
		return
	}
	a := (col >> 24) & 0xFF
	if a == 0 {
		return
	}
	idx := int(y) * c.width + int(x)
	if a == 0xFF {
		c.pixels[idx] = col
		return
	}
	dst := c.pixels[idx]
	r := blend_channel((col >> 16) & 0xFF, (dst >> 16) & 0xFF, a)
	g := blend_channel((col >> 8) & 0xFF, (dst >> 8) & 0xFF, a)
	b := blend_channel(col & 0xFF, dst & 0xFF, a)
	c.pixels[idx] = (0xFF << 24) | (r << 16) | (g << 8) | b
}

canvas_clear :: proc(c: ^Canvas, col: Color) {
	for i in 0 ..< len(c.pixels) {
		c.pixels[i] = col
	}
	c.clip = Rect{0, 0, f32(c.width), f32(c.height)}
}

// False for a uniform frame, which is what a renderer regression (or a
// screenshot taken before the first draw) would produce.
canvas_nonblank :: proc(c: ^Canvas) -> bool {
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
	c.clip = rect_intersect(c.clip, scale_rect(c, r))
	return old
}

canvas_pop_clip :: proc(c: ^Canvas, old: Rect) {
	c.clip = old
}

canvas_fill :: proc(c: ^Canvas, r: Rect, col: Color) {
	a := (col >> 24) & 0xFF
	if a == 0 {
		return
	}
	clip := rect_intersect(c.clip, scale_rect(c, r))
	x0 := max(i32(math.floor(clip.x)), 0)
	y0 := max(i32(math.floor(clip.y)), 0)
	x1 := min(i32(math.ceil(clip.x + clip.w)), i32(c.width))
	y1 := min(i32(math.ceil(clip.y + clip.h)), i32(c.height))
	if x1 <= x0 || y1 <= y0 {
		return
	}
	if a == 0xFF {
		for y in y0 ..< y1 {
			row := c.pixels[int(y) * c.width:]
			for x in x0 ..< x1 {
				row[int(x)] = col
			}
		}
		return
	}
	sr := (col >> 16) & 0xFF
	sg := (col >> 8) & 0xFF
	sb := col & 0xFF
	for y in y0 ..< y1 {
		row := c.pixels[int(y) * c.width:]
		for x in x0 ..< x1 {
			dst := row[int(x)]
			dr := blend_channel(sr, (dst >> 16) & 0xFF, a)
			dg := blend_channel(sg, (dst >> 8) & 0xFF, a)
			db := blend_channel(sb, dst & 0xFF, a)
			row[int(x)] = (0xFF << 24) | (dr << 16) | (dg << 8) | db
		}
	}
}

canvas_rect :: proc(c: ^Canvas, r: Rect, col: Color, thickness: i32 = 1) {
	pr := scale_rect(c, r)
	px := max(i32(math.round(f32(thickness) * c.scale)), 1)
	x0 := i32(math.round(pr.x))
	y0 := i32(math.round(pr.y))
	x1 := i32(math.round(pr.x + pr.w)) - 1
	y1 := i32(math.round(pr.y + pr.h)) - 1
	for t in 0 ..< px {
		for x in x0 + t ..= x1 - t {
			plot(c, x, y0 + t, col)
			plot(c, x, y1 - t, col)
		}
		for y in y0 + t ..= y1 - t {
			plot(c, x0 + t, y, col)
			plot(c, x1 - t, y, col)
		}
	}
}

canvas_hline :: proc(c: ^Canvas, x0, x1, y: f32, col: Color) {
	s := c.scale
	yy := i32(math.round(y * s))
	a := i32(math.round(min(x0, x1) * s))
	b := i32(math.round(max(x0, x1) * s))
	thick := max(i32(math.round(s)), 1)
	for t in 0 ..< thick {
		for x in a ..= b {
			plot(c, x, yy + t, col)
		}
	}
}

canvas_vline :: proc(c: ^Canvas, x, y0, y1: f32, col: Color) {
	s := c.scale
	xx := i32(math.round(x * s))
	a := i32(math.round(min(y0, y1) * s))
	b := i32(math.round(max(y0, y1) * s))
	thick := max(i32(math.round(s)), 1)
	for t in 0 ..< thick {
		for y in a ..= b {
			plot(c, xx + t, y, col)
		}
	}
}

@(private)
line_pixels :: proc(c: ^Canvas, x0_in, y0_in, x1, y1: i32, col: Color) {
	x0 := x0_in
	y0 := y0_in
	dx := abs(x1 - x0)
	dy := -abs(y1 - y0)
	sx: i32 = 1 if x0 < x1 else -1
	sy: i32 = 1 if y0 < y1 else -1
	err := dx + dy
	for {
		plot(c, x0, y0, col)
		if x0 == x1 && y0 == y1 {
			break
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

canvas_line :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color) {
	s := c.scale
	x0i := i32(math.round(x0 * s))
	y0i := i32(math.round(y0 * s))
	x1i := i32(math.round(x1 * s))
	y1i := i32(math.round(y1 * s))
	thick := max(i32(math.round(s)), 1)
	lo := -(thick - 1) / 2
	for t in lo ..< lo + thick {
		line_pixels(c, x0i + t, y0i, x1i + t, y1i, col)
	}
}

canvas_circle_fill :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	s := c.scale
	pcx := cx * s
	pcy := cy * s
	pr := radius * s
	r2 := pr * pr
	x0 := i32(math.floor(pcx - pr))
	x1 := i32(math.ceil(pcx + pr))
	y0 := i32(math.floor(pcy - pr))
	y1 := i32(math.ceil(pcy + pr))
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			dx := f32(x) + 0.5 - pcx
			dy := f32(y) + 0.5 - pcy
			if dx * dx + dy * dy <= r2 {
				plot(c, x, y, col)
			}
		}
	}
}

canvas_circle :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	steps := max(24, int(radius * c.scale * 4))
	prev_x := cx + radius
	prev_y := cy
	for i in 1 ..= steps {
		a := f32(i) / f32(steps) * f32(math.TAU)
		x := cx + math.cos(a) * radius
		y := cy + math.sin(a) * radius
		canvas_line(c, prev_x, prev_y, x, y, col)
		prev_x = x
		prev_y = y
	}
}

// Angles are radians, 0 = right, clockwise on screen.
canvas_arc :: proc(c: ^Canvas, cx, cy, radius, a0, a1: f32, col: Color, thickness: f32 = 1) {
	steps := max(12, int(abs(a1 - a0) * radius * c.scale * 0.5))
	tpx := thickness * c.scale
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		a := a0 + (a1 - a0) * t
		ap := a0 + (a1 - a0) * (f32(i - 1) / f32(steps))
		if tpx <= 1.01 {
			canvas_line(c, cx + math.cos(ap) * radius, cy + math.sin(ap) * radius,
				cx + math.cos(a) * radius, cy + math.sin(a) * radius, col)
		} else {
			for t2 in 0 ..< int(tpx) {
				rr := radius - f32(t2) / c.scale
				canvas_line(c, cx + math.cos(ap) * rr, cy + math.sin(ap) * rr,
					cx + math.cos(a) * rr, cy + math.sin(a) * rr, col)
			}
		}
	}
}

text_width :: proc(text: string, scale: int = 1) -> f32 {
	return f32(len(text)) * f32(FONT_W) * f32(max(scale, 1))
}

text_height :: proc(scale: int = 1) -> f32 {
	return f32(FONT_H) * f32(max(scale, 1))
}

// Alpha coverage of the baked atlases. Rows are packed MSB-first; 0 is
// transparent and 255 is full ink.
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

// Blend one coverage sample. The text colour's own alpha is multiplied in so
// translucent labels still work exactly as they did with the 1-bit font.
@(private)
text_plot :: proc(c: ^Canvas, x, y: i32, col: Color, coverage: u8) {
	if coverage == 0 {
		return
	}
	a := u32(coverage) * u32((col >> 24) & 0xFF)
	if a == 0 {
		return
	}
	aa := u8((a + 127) / 255)
	plot(c, x, y, (col & 0x00FFFFFF) | (Color(aa) << 24))
}

@(private)
text_baked_small :: proc(c: ^Canvas, start_x, start_y: i32, text: string, col: Color) {
	cx := start_x
	cy := start_y
	for ch in text {
		if ch == '\n' {
			cx = start_x
			cy += i32(FONT_H)
			continue
		}
		if int(ch) < FONT_FIRST || int(ch) > FONT_LAST || ch == ' ' {
			cx += i32(FONT_W)
			continue
		}
		idx := int(ch) - FONT_FIRST
		for row in 0 ..< FONT_H {
			if FONT_SMALL_ALPHA[idx][row] == 0 {
				continue
			}
			for col_i in 0 ..< FONT_W {
				a := font_small_alpha(idx, row, col_i)
				if a != 0 {
					text_plot(c, cx + i32(col_i), cy + i32(row), col, a)
				}
			}
		}
		cx += i32(FONT_W)
	}
}

// One-to-one blit of the 25 px baked atlas. Used for heading text at 1x and
// body text at 2x, where the cell is exactly 16x30 physical pixels.
@(private)
text_baked_large :: proc(c: ^Canvas, start_x, start_y: i32, text: string, col: Color) {
	cx := start_x
	cy := start_y
	for ch in text {
		if ch == '\n' {
			cx = start_x
			cy += i32(FONT_LARGE_H)
			continue
		}
		if int(ch) < FONT_FIRST || int(ch) > FONT_LAST || ch == ' ' {
			cx += i32(FONT_LARGE_W)
			continue
		}
		idx := int(ch) - FONT_FIRST
		for row in 0 ..< FONT_LARGE_H {
			if FONT_LARGE_ALPHA[idx][row][0] == 0 && FONT_LARGE_ALPHA[idx][row][1] == 0 {
				continue
			}
			for col_i in 0 ..< FONT_LARGE_W {
				a := font_large_alpha(idx, row, col_i)
				if a != 0 {
					text_plot(c, cx + i32(col_i), cy + i32(row), col, a)
				}
			}
		}
		cx += i32(FONT_LARGE_W)
	}
}

canvas_text :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, scale: int = 1) {
	sc := max(scale, 1)
	s := c.scale
	// Exact baked cells keep 1x byte-identical and 2x body text on the
	// purpose-baked 25 px companion atlas. Every other density is rasterised
	// at its true physical size by the runtime stb_truetype atlas -- never a
	// magnified 1x bitmap.
	cell_w := f32(FONT_W * sc) * s
	cell_h := f32(FONT_H * sc) * s
	if abs(s - 1) < 0.0001 && sc == 1 {
		text_baked_small(c, i32(math.round(x)), i32(math.round(y)), text, col)
	} else if abs(cell_w - f32(FONT_LARGE_W)) < 0.01 && abs(cell_h - f32(FONT_LARGE_H)) < 0.01 {
		text_baked_large(c, i32(math.round(x * s)), i32(math.round(y * s)), text, col)
	} else {
		canvas_text_runtime(c, x, y, text, col, sc)
	}
}


// Arbitrary-size text for hierarchy that falls between the baked 12.5/25 px
// cells (timecode, track numbers, labels). Rendered from the bundled TTF at
// the exact physical size, so it stays crisp at every display density.
text_width_px :: proc(text: string, px: f32) -> f32 {
	return f32(len(text)) * max(px * 0.60, 1)
}

text_height_px :: proc(px: f32) -> f32 {
	return max(px * 1.2, 1)
}

canvas_text_px :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, px: f32) {
	if px <= 0 || len(text) == 0 {
		return
	}
	if !runtime_font_init(&c.font) {
		canvas_text(c, x, y, text, col, 1)
		return
	}
	s := c.scale
	cell_w := max(i32(math.round(px * 0.60 * s)), 1)
	baseline := i32(math.round(px * 0.96 * s))
	font_px := px * s
	start_x := i32(math.round(x * s))
	pen_x := start_x
	pen_y := i32(math.round(y * s))
	for ch in text {
		if ch == '\n' {
			pen_x = start_x
			pen_y += i32(math.round(px * 1.2 * s))
			continue
		}
		if int(ch) < FONT_FIRST || int(ch) > FONT_LAST || ch == ' ' {
			pen_x += cell_w
			continue
		}
		g := runtime_glyph(&c.font, u8(ch), font_px)
		if g.w > 0 && g.h > 0 {
			for row in 0 ..< g.h {
				src := row * g.w
				for ci in 0 ..< g.w {
					a := g.alpha[int(src + ci)]
					if a != 0 {
						text_plot(c, pen_x + g.xoff + ci, pen_y + baseline + g.yoff + row, col, a)
					}
				}
			}
		}
		pen_x += cell_w
	}
}

canvas_text_px_right :: proc(c: ^Canvas, right, y: f32, text: string, col: Color, px: f32) {
	canvas_text_px(c, right - text_width_px(text, px), y, text, col, px)
}

canvas_text_px_center :: proc(c: ^Canvas, cx, y: f32, text: string, col: Color, px: f32) {
	canvas_text_px(c, cx - text_width_px(text, px) * 0.5, y, text, col, px)
}

canvas_text_right :: proc(c: ^Canvas, right, y: f32, text: string, col: Color, scale: int = 1) {
	canvas_text(c, right - text_width(text, scale), y, text, col, scale)
}

canvas_text_center :: proc(c: ^Canvas, cx, y: f32, text: string, col: Color, scale: int = 1) {
	canvas_text(c, cx - text_width(text, scale) * 0.5, y, text, col, scale)
}

// Truncates text with ".." to fit `max_width`.
canvas_text_clip :: proc(c: ^Canvas, x, y, max_width: f32, text: string, col: Color, scale: int = 1) {
	per := f32(FONT_W * max(scale, 1))
	if text_width(text, scale) <= max_width {
		canvas_text(c, x, y, text, col, scale)
		return
	}
	fit := int(max_width / per) - 2
	if fit <= 0 {
		return
	}
	out := text
	if len(out) > fit {
		out = out[:fit]
	}
	canvas_text(c, x, y, out, col, scale)
	canvas_text(c, x + f32(fit) * per, y, "..", col, scale)
}

@(private)
upper :: proc(s: string) -> string {
	return s
}

// Uppercase a short label in-place into a caller buffer. ASCII only.
uppercase_ascii :: proc(dst: []u8, s: string) {
	n := min(len(s), len(dst))
	for i in 0 ..< n {
		c := s[i]
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		dst[i] = c
	}
}
