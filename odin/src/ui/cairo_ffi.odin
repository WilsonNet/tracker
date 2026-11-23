#+build linux
// Minimal Cairo + Pango bindings for the UI renderer.
//
// Cairo gives the shell a real vector rasteriser: anti-aliased paths, rounded
// corners, linear gradients and clipping. Pango sits on top for shaped text
// with real weights, kerning and hinting. Both are stable C APIs already
// present on Linux desktops, so the UI keeps its single-binary Odin core and
// only links two mature system libraries.

package ui

import "core:c"

cairo_t :: struct {}
cairo_surface_t :: struct {}
cairo_pattern_t :: struct {}
pango_layout_t :: struct {}
pango_context_t :: struct {}
pango_font_description_t :: struct {}

CANVAS_CAIRO_FORMAT_ARGB32 :: c.int(0)
CANVAS_ANTIALIAS_NONE      :: c.int(1)
CANVAS_ANTIALIAS_BEST      :: c.int(6)
CANVAS_OPERATOR_SOURCE     :: c.int(1)
CANVAS_OPERATOR_OVER       :: c.int(2)
CANVAS_LINE_CAP_ROUND      :: c.int(1)
CANVAS_LINE_JOIN_ROUND     :: c.int(1)

PANGO_SCALE            :: 1024
PANGO_WEIGHT_NORMAL    :: c.int(400)
PANGO_WEIGHT_MEDIUM    :: c.int(500)
PANGO_WEIGHT_SEMIBOLD  :: c.int(600)

foreign import cairo_lib "system:cairo"
foreign import pango_lib "system:pango-1.0"
foreign import pangocairo_lib "system:pangocairo-1.0"
foreign import gobject_lib "system:gobject-2.0"

@(default_calling_convention = "c")
foreign cairo_lib {
	cairo_image_surface_create_for_data :: proc(data: [^]u8, format: c.int, width, height, stride: c.int) -> ^cairo_surface_t ---
	cairo_create :: proc(surface: ^cairo_surface_t) -> ^cairo_t ---
	cairo_destroy :: proc(cr: ^cairo_t) ---
	cairo_surface_destroy :: proc(surface: ^cairo_surface_t) ---
	cairo_surface_flush :: proc(surface: ^cairo_surface_t) ---
	cairo_surface_mark_dirty :: proc(surface: ^cairo_surface_t) ---

	cairo_set_source_rgba :: proc(cr: ^cairo_t, r, g, b, a: f64) ---
	cairo_set_operator :: proc(cr: ^cairo_t, op: c.int) ---
	cairo_set_antialias :: proc(cr: ^cairo_t, aa: c.int) ---
	cairo_set_line_width :: proc(cr: ^cairo_t, width: f64) ---
	cairo_set_line_cap :: proc(cr: ^cairo_t, cap: c.int) ---
	cairo_set_line_join :: proc(cr: ^cairo_t, join: c.int) ---

	cairo_new_path :: proc(cr: ^cairo_t) ---
	cairo_new_sub_path :: proc(cr: ^cairo_t) ---
	cairo_move_to :: proc(cr: ^cairo_t, x, y: f64) ---
	cairo_line_to :: proc(cr: ^cairo_t, x, y: f64) ---
	cairo_arc :: proc(cr: ^cairo_t, cx, cy, radius, a0, a1: f64) ---
	cairo_close_path :: proc(cr: ^cairo_t) ---
	cairo_rectangle :: proc(cr: ^cairo_t, x, y, w, h: f64) ---
	cairo_fill :: proc(cr: ^cairo_t) ---
	cairo_fill_preserve :: proc(cr: ^cairo_t) ---
	cairo_stroke :: proc(cr: ^cairo_t) ---
	cairo_paint :: proc(cr: ^cairo_t) ---

	cairo_save :: proc(cr: ^cairo_t) ---
	cairo_restore :: proc(cr: ^cairo_t) ---
	cairo_clip :: proc(cr: ^cairo_t) ---
	cairo_reset_clip :: proc(cr: ^cairo_t) ---

	cairo_pattern_create_linear :: proc(x0, y0, x1, y1: f64) -> ^cairo_pattern_t ---
	cairo_pattern_add_color_stop_rgba :: proc(pattern: ^cairo_pattern_t, offset, r, g, b, a: f64) ---
	cairo_pattern_destroy :: proc(pattern: ^cairo_pattern_t) ---
	cairo_set_source :: proc(cr: ^cairo_t, pattern: ^cairo_pattern_t) ---
}

@(default_calling_convention = "c")
foreign pango_lib {
	pango_font_description_new :: proc() -> ^pango_font_description_t ---
	pango_font_description_set_family :: proc(desc: ^pango_font_description_t, family: cstring) ---
	pango_font_description_set_weight :: proc(desc: ^pango_font_description_t, weight: c.int) ---
	pango_font_description_set_size :: proc(desc: ^pango_font_description_t, size: c.int) ---
	pango_font_description_free :: proc(desc: ^pango_font_description_t) ---

	pango_layout_set_text :: proc(layout: ^pango_layout_t, text: cstring, length: c.int) ---
	pango_layout_set_font_description :: proc(layout: ^pango_layout_t, desc: ^pango_font_description_t) ---
	pango_layout_get_pixel_size :: proc(layout: ^pango_layout_t, width, height: ^c.int) ---
	pango_layout_get_context :: proc(layout: ^pango_layout_t) -> ^pango_context_t ---
}

@(default_calling_convention = "c")
foreign pangocairo_lib {
	pango_cairo_create_layout :: proc(cr: ^cairo_t) -> ^pango_layout_t ---
	pango_cairo_show_layout :: proc(cr: ^cairo_t, layout: ^pango_layout_t) ---
	pango_cairo_context_set_resolution :: proc(ctx: ^pango_context_t, dpi: f64) ---
}

@(default_calling_convention = "c")
foreign gobject_lib {
	g_object_unref :: proc(obj: rawptr) ---
}
