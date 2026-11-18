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

// Runtime design tokens. The base set mirrors the DESIGN.md palette; the
// high-contrast set raises ink and border luminance for studio/vision use.
Tokens :: struct {
	bg:           Color,
	panel:        Color,
	panel_2:      Color,
	panel_3:      Color,
	line:         Color,
	line_bright:  Color,
	amber:        Color,
	amber_bright: Color,
	amber_dim:    Color,
	amber_faint:  Color,
	amber_wash:   Color,
	text:         Color,
	dim:          Color,
	muted:        Color,
	red:          Color,
	red_dim:      Color,
	teal:         Color,
	teal_dim:     Color,
	green:        Color,
	black:        Color,
	white:        Color,
}

TOKENS_DEFAULT := Tokens {
	bg           = BG,
	panel        = PANEL,
	panel_2      = PANEL_2,
	panel_3      = PANEL_3,
	line         = LINE,
	line_bright  = LINE_BRIGHT,
	amber        = AMBER,
	amber_bright = AMBER_BRIGHT,
	amber_dim    = AMBER_DIM,
	amber_faint  = AMBER_FAINT,
	amber_wash   = AMBER_WASH,
	text         = TEXT,
	dim          = DIM,
	muted        = MUTED,
	red          = RED,
	red_dim      = RED_DIM,
	teal         = TEAL,
	teal_dim     = TEAL_DIM,
	green        = GREEN,
	black        = BLACK,
	white        = WHITE,
}

TOKENS_HIGH_CONTRAST := Tokens {
	bg           = 0xFF000000,
	panel        = 0xFF0D0D0D,
	panel_2      = 0xFF171717,
	panel_3      = 0xFF262626,
	line         = 0xFF4D4D4D,
	line_bright  = 0xFF707070,
	amber        = 0xFFFFA23A,
	amber_bright = 0xFFFFB65C,
	amber_dim    = 0xFFB87533,
	amber_faint  = 0x55FFA23A,
	amber_wash   = 0x2AFFA23A,
	text         = 0xFFFFFFFF,
	dim          = 0xFFD2D2D2,
	muted        = 0xFFB0B0B0,
	red          = 0xFFFF5C54,
	red_dim      = 0xFF7A2420,
	teal         = 0xFF44D8E0,
	teal_dim     = 0xFF1A6064,
	green        = 0xFF7FD98C,
	black        = BLACK,
	white        = WHITE,
}

theme_tokens :: proc(high_contrast: bool) -> Tokens {
	return TOKENS_HIGH_CONTRAST if high_contrast else TOKENS_DEFAULT
}

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

// Set by app_draw before any widgets run. The UI is single-threaded (one App
// per window/harness), and tests drive rendering through app_draw, so this
// keeps widget call sites free of a token argument on every primitive.
ACTIVE_TOKENS: Tokens = TOKENS_DEFAULT
