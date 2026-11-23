#+build linux
// Pango text path for the headless vector shell.
package ui

import "core:math"

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
