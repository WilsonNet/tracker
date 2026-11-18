// Pango text path for the vector shell.
//
// Sizes are logical pixels. Pango is configured at 72 dpi so 1 point == 1
// pixel; the actual layout uses the physical size (logical * canvas scale), so
// text stays crisp and correctly hinted at every display density and responsive
// zoom. Inter is the UI face; Noto Sans Mono is reserved for timecode and
// numeric readouts.

package ui

import "core:math"

Font_Weight :: enum u8 {
	Regular,
	Medium,
	SemiBold,
	Mono,
}

@(private)
canvas_set_font :: proc(c: ^Canvas, layout: ^pango_layout_t, weight: Font_Weight, px_physical: f32) {
	if layout == nil {
		return
	}
	desc := pango_font_description_new()
	if desc == nil {
		return
	}
	family: cstring = "Inter"
	w := PANGO_WEIGHT_NORMAL
	#partial switch weight {
	case .Medium:
		w = PANGO_WEIGHT_MEDIUM
	case .SemiBold:
		w = PANGO_WEIGHT_SEMIBOLD
	case .Mono:
		family = "Noto Sans Mono"
		w = PANGO_WEIGHT_NORMAL
	}
	pango_font_description_set_family(desc, family)
	pango_font_description_set_weight(desc, w)
	size := max(int(math.round(px_physical * f32(PANGO_SCALE))), 1)
	pango_font_description_set_size(desc, i32(size))
	pango_layout_set_font_description(layout, desc)
	pango_font_description_free(desc)
}

canvas_text_width :: proc(c: ^Canvas, text: string, px: f32, weight: Font_Weight = .Regular) -> f32 {
	if px <= 0 || len(text) == 0 || c.measure == nil {
		return 0
	}
	canvas_set_font(c, c.measure, weight, px * c.scale)
	pango_layout_set_text(c.measure, cstring(raw_data(text)), i32(len(text)))
	w, h: i32
	pango_layout_get_pixel_size(c.measure, &w, &h)
	return f32(w) / c.scale
}

canvas_text_height :: proc(c: ^Canvas, text: string, px: f32, weight: Font_Weight = .Regular) -> f32 {
	if px <= 0 || c.measure == nil {
		return 0
	}
	canvas_set_font(c, c.measure, weight, px * c.scale)
	pango_layout_set_text(c.measure, cstring(raw_data(text)), i32(len(text)))
	w, h: i32
	pango_layout_get_pixel_size(c.measure, &w, &h)
	return f32(h) / c.scale
}

canvas_text_px :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, px: f32, weight: Font_Weight = .Regular) {
	if px <= 0 || len(text) == 0 || c.layout == nil || (col >> 24) == 0 {
		return
	}
	cairo_color(c, col)
	canvas_set_font(c, c.layout, weight, px * c.scale)
	pango_layout_set_text(c.layout, cstring(raw_data(text)), i32(len(text)))
	cairo_move_to(c.cr, f64(x * c.scale), f64(y * c.scale))
	pango_cairo_show_layout(c.cr, c.layout)
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
