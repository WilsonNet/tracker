// Design tokens from DESIGN.md, translated to sRGB and the software canvas.

package ui

import "core:math"

BG          :: 0xFF0A0A0A
PANEL       :: 0xFF121212
PANEL_2     :: 0xFF191919
PANEL_3     :: 0xFF222222
LINE        :: 0xFF2B2B2B
LINE_BRIGHT :: 0xFF3A3A3A
AMBER       :: 0xFFF08A31
AMBER_BRIGHT:: 0xFFFF9B2C
AMBER_DIM   :: 0xFF8A5524
AMBER_FAINT :: 0x33F08A31
AMBER_WASH  :: 0x1AF08A31
TEXT        :: 0xFFE8E8E8
DIM         :: 0xFF8F8F8F
MUTED       :: 0xFF737373
RED         :: 0xFFD0342C
RED_DIM     :: 0xFF5A1A18
TEAL        :: 0xFF1E9AA0
TEAL_DIM    :: 0xFF12484B
GREEN       :: 0xFF62B36E
BLACK       :: 0xFF000000
WHITE       :: 0xFFFFFFFF

rgb :: proc(r, g, b: u8, a: u8 = 255) -> Color {
	return (Color(a) << 24) | (Color(r) << 16) | (Color(g) << 8) | Color(b)
}

with_alpha :: proc(col: Color, a: u8) -> Color {
	return (col & 0x00FFFFFF) | (Color(a) << 24)
}

mix :: proc(a, b: Color, t: f32) -> Color {
	tt := clamp(t, 0, 1)
	ar := f32((a >> 16) & 0xFF)
	ag := f32((a >> 8) & 0xFF)
	ab := f32(a & 0xFF)
	br := f32((b >> 16) & 0xFF)
	bg := f32((b >> 8) & 0xFF)
	bb := f32(b & 0xFF)
	return rgb(u8(ar + (br - ar) * tt), u8(ag + (bg - ag) * tt), u8(ab + (bb - ab) * tt))
}

// -60 dBFS .. 0 dBFS -> 0..1
db_norm :: proc(db: f32) -> f32 {
	return clamp((db + 60.0) / 60.0, 0, 1)
}

norm_db :: proc(n: f32) -> f32 {
	return clamp(n, 0, 1) * 60.0 - 60.0
}

// Log-normalised parameter helpers for knobs.
value_to_norm :: proc(value, lo, hi: f32, logarithmic: bool) -> f32 {
	if logarithmic {
		lv := math.ln(max(value, 1e-6))
		llo := math.ln(max(lo, 1e-6))
		lhi := math.ln(max(hi, 1e-6))
		return clamp((lv - llo) / (lhi - llo), 0, 1)
	}
	return clamp((value - lo) / (hi - lo), 0, 1)
}

norm_to_value :: proc(norm, lo, hi: f32, logarithmic: bool) -> f32 {
	t := clamp(norm, 0, 1)
	if logarithmic {
		llo := math.ln(max(lo, 1e-6))
		lhi := math.ln(max(hi, 1e-6))
		return math.exp(llo + (lhi - llo) * t)
	}
	return lo + (hi - lo) * t
}
