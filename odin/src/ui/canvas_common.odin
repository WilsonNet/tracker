// Shared Canvas types and pure geometric / font-metric helpers.
//
// Platform backends live in canvas_cairo_linux.odin + font_runtime_linux.odin
// (Linux) and canvas_soft_other.odin + font_runtime_other.odin (macOS/other).
package ui

import "core:math"

Color :: u32

Rect :: struct {
	x, y, w, h: f32,
}

Point :: struct {
	x, y: f32,
}

Font_Weight :: enum u8 {
	Regular,
	Medium,
	SemiBold,
	Mono,
}

CANVAS_MIN_SCALE :: 1.0
CANVAS_MAX_SCALE :: 6.0

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

canvas_pixel_size :: proc(logical: int, scale: f32) -> int {
	return max(int(math.ceil(f32(logical) * clamp(scale, CANVAS_MIN_SCALE, CANVAS_MAX_SCALE))), 1)
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

canvas_text_px_right :: proc(c: ^Canvas, right, y: f32, text: string, col: Color, px: f32, weight: Font_Weight = .Regular) {
	canvas_text_px(c, right - canvas_text_width(c, text, px, weight), y, text, col, px, weight)
}

canvas_text_px_center :: proc(c: ^Canvas, cx, y: f32, text: string, col: Color, px: f32, weight: Font_Weight = .Regular) {
	canvas_text_px(c, cx - canvas_text_width(c, text, px, weight) * 0.5, y, text, col, px, weight)
}

canvas_text_px_clip :: proc(c: ^Canvas, x, y, max_width: f32, text: string, col: Color, px: f32, weight: Font_Weight = .Regular) {
	if px <= 0 || len(text) == 0 {
		return
	}
	if canvas_text_width(c, text, px, weight) <= max_width {
		canvas_text_px(c, x, y, text, col, px, weight)
		return
	}
	buf: [512]u8
	n := min(len(text), 508)
	for n > 0 {
		copy(buf[:n], text[:n])
		buf[n] = '.'
		buf[n + 1] = '.'
		if canvas_text_width(c, string(buf[:n + 2]), px, weight) <= max_width {
			break
		}
		n -= 1
	}
	canvas_text_px(c, x, y, string(buf[:n + 2]), col, px, weight)
}

// ---------------------------------------------------------------- legacy text

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
