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

Canvas :: struct {
	width, height: int,
	pixels:        []u32,
	clip:          Rect,
}

canvas_init :: proc(c: ^Canvas, width, height: int) {
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

canvas_push_clip :: proc(c: ^Canvas, r: Rect) -> Rect {
	old := c.clip
	c.clip = rect_intersect(c.clip, r)
	return old
}

canvas_pop_clip :: proc(c: ^Canvas, old: Rect) {
	c.clip = old
}

canvas_fill :: proc(c: ^Canvas, r: Rect, col: Color) {
	x0 := max(i32(math.floor(r.x)), 0)
	y0 := max(i32(math.floor(r.y)), 0)
	x1 := min(i32(math.ceil(r.x + r.w)), i32(c.width))
	y1 := min(i32(math.ceil(r.y + r.h)), i32(c.height))
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			plot(c, x, y, col)
		}
	}
}

canvas_rect :: proc(c: ^Canvas, r: Rect, col: Color, thickness: i32 = 1) {
	x0 := i32(math.round(r.x))
	y0 := i32(math.round(r.y))
	x1 := i32(math.round(r.x + r.w)) - 1
	y1 := i32(math.round(r.y + r.h)) - 1
	for t in 0 ..< thickness {
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
	yy := i32(math.round(y))
	a := i32(math.round(min(x0, x1)))
	b := i32(math.round(max(x0, x1)))
	for x in a ..= b {
		plot(c, x, yy, col)
	}
}

canvas_vline :: proc(c: ^Canvas, x, y0, y1: f32, col: Color) {
	xx := i32(math.round(x))
	a := i32(math.round(min(y0, y1)))
	b := i32(math.round(max(y0, y1)))
	for y in a ..= b {
		plot(c, xx, y, col)
	}
}

canvas_line :: proc(c: ^Canvas, x0, y0, x1, y1: f32, col: Color) {
	x0i := i32(math.round(x0))
	y0i := i32(math.round(y0))
	x1i := i32(math.round(x1))
	y1i := i32(math.round(y1))
	dx := abs(x1i - x0i)
	dy := -abs(y1i - y0i)
	sx: i32 = 1 if x0i < x1i else -1
	sy: i32 = 1 if y0i < y1i else -1
	err := dx + dy
	for {
		plot(c, x0i, y0i, col)
		if x0i == x1i && y0i == y1i {
			break
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0i += sx
		}
		if e2 <= dx {
			err += dx
			y0i += sy
		}
	}
}

canvas_circle_fill :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	r2 := radius * radius
	x0 := i32(math.floor(cx - radius))
	x1 := i32(math.ceil(cx + radius))
	y0 := i32(math.floor(cy - radius))
	y1 := i32(math.ceil(cy + radius))
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			dx := f32(x) + 0.5 - cx
			dy := f32(y) + 0.5 - cy
			if dx * dx + dy * dy <= r2 {
				plot(c, x, y, col)
			}
		}
	}
}

canvas_circle :: proc(c: ^Canvas, cx, cy, radius: f32, col: Color) {
	steps := max(24, int(radius * 4))
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
	steps := max(12, int(abs(a1 - a0) * radius * 0.5))
	prev_x := cx + math.cos(a0) * radius
	prev_y := cy + math.sin(a0) * radius
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		a := a0 + (a1 - a0) * t
		x := cx + math.cos(a) * radius
		y := cy + math.sin(a) * radius
		if thickness <= 1.01 {
			canvas_line(c, prev_x, prev_y, x, y, col)
		} else {
			for t2 in 0 ..< int(thickness) {
				rr := radius - f32(t2)
				canvas_line(c, cx + math.cos(a0 + (a1 - a0) * (f32(i - 1) / f32(steps))) * rr,
					cy + math.sin(a0 + (a1 - a0) * (f32(i - 1) / f32(steps))) * rr,
					cx + math.cos(a) * rr, cy + math.sin(a) * rr, col)
			}
		}
		prev_x = x
		prev_y = y
	}
}

text_width :: proc(text: string, scale: int = 1) -> f32 {
	return f32(len(text)) * f32(FONT_W) * f32(scale)
}

text_height :: proc(scale: int = 1) -> f32 {
	return f32(FONT_H) * f32(scale)
}

canvas_text :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, scale: int = 1) {
	cx := i32(math.round(x))
	cy := i32(math.round(y))
	start_x := cx
	for ch in text {
		if ch == '\n' {
			cx = start_x
			cy += i32(FONT_H * scale)
			continue
		}
		if int(ch) < FONT_FIRST || int(ch) > FONT_LAST {
			cx += i32(FONT_W * scale)
			continue
		}
		if ch == ' ' {
			cx += i32(FONT_W * scale)
			continue
		}
		idx := int(ch) - FONT_FIRST
		for row in 0 ..< FONT_H {
			bits := FONT_ROWS[idx][row]
			if bits == 0 {
				continue
			}
			for col_i in 0 ..< FONT_W {
				if bits & (u16(1) << u32(FONT_W - 1 - col_i)) != 0 {
					for sy in 0 ..< scale {
						for sx in 0 ..< scale {
							plot(c, cx + i32(col_i * scale + sx), cy + i32(row * scale + sy), col)
						}
					}
				}
			}
		}
		cx += i32(FONT_W * scale)
	}
}

canvas_text_right :: proc(c: ^Canvas, right, y: f32, text: string, col: Color, scale: int = 1) {
	canvas_text(c, right - text_width(text, scale), y, text, col, scale)
}

canvas_text_center :: proc(c: ^Canvas, cx, y: f32, text: string, col: Color, scale: int = 1) {
	canvas_text(c, cx - text_width(text, scale) * 0.5, y, text, col, scale)
}

// Truncates text with ".." to fit `max_width`.
canvas_text_clip :: proc(c: ^Canvas, x, y, max_width: f32, text: string, col: Color, scale: int = 1) {
	per := f32(FONT_W * scale)
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
