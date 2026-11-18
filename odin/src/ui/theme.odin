// Design tokens — the single source of truth for the native UI.
//
// Values mirror the React frontend's src/styles/tokens.css (OKLCH there,
// sRGB hex here because the software canvas rasterises in sRGB). When the
// palette changes, change it here first and update tokens.css to match.
//
// Layers, from raw to applied:
//
//   Palette constants   exact brand values, no UI meaning
//   Color_Tokens        semantic roles the drawing code consumes
//   Space_Tokens        4 px rhythm scale
//   Type_Tokens         fixed px scale (product UI never scales fluidly)
//   Metric_Tokens       layout constants shared by app_layout and widgets
//   Tokens              one complete theme; ACTIVE_TOKENS is the live copy
//
// Drawing code reads roles (ACTIVE_TOKENS.color.ink, .space.md, .type.label),
// never the raw palette or bare pixel numbers, so adding a theme — or moving
// the whole layout — stays a data change instead of a rewrite.

package ui

import "core:math"

// ---------------------------------------------------------------- palette
//
// sRGB equivalents of the OKLCH tokens in tokens.css. Reference only: widget
// code goes through Color_Tokens below.

BG_VALUE         :: 0xFF010101 // oklch(0.07  0     0)   canvas
SURFACE_VALUE    :: 0xFF060606 // oklch(0.125 0     0)   panels, bars
RAISED_VALUE     :: 0xFF0B0B0B // oklch(0.15  0     0)   controls, rows
HIGH_VALUE       :: 0xFF101010 // oklch(0.175 0     0)   wells, meter tracks
LINE_VALUE       :: 0xFF1B1B1B // oklch(0.22  0     0)   hairlines
LINE_SUBTLE_VALUE:: 0xFF0B0B0B // oklch(0.15  0     0)   faintest dividers
LINE_STRONG_VALUE:: 0xFF2B2B2B // 1 px emphasised strokes
AMBER_VALUE      :: 0xFFF08A31 // oklch(0.73  0.157 57)  primary signal
AMBER_BRIGHT_VALUE:: 0xFFFF9B2C
AMBER_DIM_VALUE  :: 0xFF8A552B // oklch(0.50  0.09  57)  quiet amber
AMBER_BG_VALUE   :: 0xFF231103 // oklch(0.20  0.04  57)  amber wash fill
AMBER_BORDER_VALUE:: 0xFF603F26 // oklch(0.40 0.06  57)
INK_VALUE        :: 0xFFE8E8E8 // oklch(0.93  0     0)
INK_DIM_VALUE    :: 0xFF8F8F8F // oklch(0.65  0     0)
INK_MUTED_VALUE  :: 0xFF5D5D5D // oklch(0.48  0     0)
RED_VALUE        :: 0xFFBA022F // oklch(0.50  0.20  20)
RED_BRIGHT_VALUE :: 0xFFD40237 // oklch(0.55  0.22  20)
RED_BG_VALUE     :: 0xFF260406 // oklch(0.18  0.06  20)
TEAL_VALUE       :: 0xFF00858D // oklch(0.55  0.12 200)
TEAL_BG_VALUE    :: 0xFF001718 // oklch(0.18  0.04 200)
GREEN_VALUE      :: 0xFF62B36E
BLACK_VALUE      :: 0xFF000000
WHITE_VALUE      :: 0xFFFFFFFF

// Translucent amber for state washes; alpha is part of the token because the
// flat surfaces underneath are near-black and opacity reads as brightness.
AMBER_FAINT_VALUE :: 0x33F08A31
AMBER_WASH_VALUE  :: 0x1AF08A31

// ---------------------------------------------------------------- color

Color_Tokens :: struct {
	// Surfaces, darkest to lightest. Three steps are enough to separate
	// canvas, panel, and interactive control without a gray haze.
	bg:             Color,
	surface:        Color,
	surface_raised: Color,
	surface_high:   Color,

	// Hairlines. line_subtle separates groups without drawing a box,
	// line is the default, line_strong marks hover/selection.
	line:        Color,
	line_subtle: Color,
	line_strong: Color,

	// Ink ramp. Body-sized copy uses ink or ink_dim; ink_muted is reserved
	// for labels and hints that sit next to a brighter value.
	ink:       Color,
	ink_dim:   Color,
	ink_muted: Color,

	// Amber signal (hue 57°) — transport focus, armed tracks, primary
	// actions, and the one accent that carries the brand.
	amber:        Color,
	amber_bright: Color,
	amber_dim:    Color,
	amber_bg:     Color,
	amber_faint:  Color,
	amber_wash:   Color,
	border_amber: Color,

	// Semantic states. Red is record/stop/mute, teal is play/solo/monitor.
	red:        Color,
	red_bright: Color,
	red_bg:     Color,
	teal:       Color,
	teal_bg:    Color,
	green:      Color,

	black: Color,
	white: Color,
}

COLORS_DEFAULT := Color_Tokens {
	bg             = BG_VALUE,
	surface        = SURFACE_VALUE,
	surface_raised = RAISED_VALUE,
	surface_high   = HIGH_VALUE,
	line           = LINE_VALUE,
	line_subtle    = LINE_SUBTLE_VALUE,
	line_strong    = LINE_STRONG_VALUE,
	ink            = INK_VALUE,
	ink_dim        = INK_DIM_VALUE,
	ink_muted      = INK_MUTED_VALUE,
	amber          = AMBER_VALUE,
	amber_bright   = AMBER_BRIGHT_VALUE,
	amber_dim      = AMBER_DIM_VALUE,
	amber_bg       = AMBER_BG_VALUE,
	amber_faint    = AMBER_FAINT_VALUE,
	amber_wash     = AMBER_WASH_VALUE,
	border_amber   = AMBER_BORDER_VALUE,
	red            = RED_VALUE,
	red_bright     = RED_BRIGHT_VALUE,
	red_bg         = RED_BG_VALUE,
	teal           = TEAL_VALUE,
	teal_bg        = TEAL_BG_VALUE,
	green          = GREEN_VALUE,
	black          = BLACK_VALUE,
	white          = WHITE_VALUE,
}

COLORS_HIGH_CONTRAST := Color_Tokens {
	bg             = 0xFF000000,
	surface        = 0xFF0D0D0D,
	surface_raised = 0xFF171717,
	surface_high   = 0xFF262626,
	line           = 0xFF4D4D4D,
	line_subtle    = 0xFF262626,
	line_strong    = 0xFF707070,
	ink            = 0xFFFFFFFF,
	ink_dim        = 0xFFD2D2D2,
	ink_muted      = 0xFFB0B0B0,
	amber          = 0xFFFFA23A,
	amber_bright   = 0xFFFFB65C,
	amber_dim      = 0xFFB87533,
	amber_bg       = 0xFF3A1D05,
	amber_faint    = 0x55FFA23A,
	amber_wash     = 0x2AFFA23A,
	border_amber   = 0xFFB87533,
	red            = 0xFFFF5C54,
	red_bright     = 0xFFFF8078,
	red_bg         = 0xFF4A0F0C,
	teal           = 0xFF44D8E0,
	teal_bg        = 0xFF0E3A3D,
	green          = 0xFF7FD98C,
	black          = BLACK_VALUE,
	white          = WHITE_VALUE,
}

// ---------------------------------------------------------------- space

// 4 px rhythm, with a 2 px and 1 px step for hairline-adjacent work.
Space_Tokens :: struct {
	hair: f32, // 1
	xxs:  f32, // 2
	xs:   f32, // 4
	sm:   f32, // 6
	md:   f32, // 8
	lg:   f32, // 12
	xl:   f32, // 16
	xxl:  f32, // 24
}

SPACE := Space_Tokens {
	hair = 1,
	xxs  = 2,
	xs   = 4,
	sm   = 6,
	md   = 8,
	lg   = 12,
	xl   = 16,
	xxl  = 24,
}

// ---------------------------------------------------------------- type

// Fixed px scale. The canvas rasterises text at these exact sizes instead of
// relying on a browser's fluid type, so the hierarchy is identical at every
// window size. 12.5 and 25 remain the baked atlas sizes used by canvas_text.
Type_Tokens :: struct {
	micro:   f32, // 8.5  knob labels, GR numerals
	caption: f32, // 9    chips, hints, meter readouts
	label:   f32, // 10   section labels, bar buttons
	body:    f32, // 11.5 values, project name
	title:   f32, // 14   track number
	readout: f32, // 20   timecode
	display: f32, // 25   reserved for dialogs
}

TYPE := Type_Tokens {
	micro   = 8.5,
	caption = 9,
	label   = 10,
	body    = 11.5,
	title   = 14,
	readout = 20,
	display = 25,
}

// ---------------------------------------------------------------- metrics

// Layout constants shared by app_layout and the widgets. Keep geometry in
// one place so the density can be tuned without hunting through draw code.
Metric_Tokens :: struct {
	header_h:     f32,
	bottom_h:     f32,
	status_h:     f32,
	margin:       f32,
	gutter:       f32,
	control_h:    f32,
	control_h_sm: f32,
	track_pad:    f32,
	row_h:        f32,
	fader_w:      f32,
	meter_w:      f32,
	knob_r:       f32,
	knob_r_sm:    f32,
	fx_h:         f32,
	palette_w:    f32,
	palette_h:    f32,
	io_w:         f32,
}

METRICS := Metric_Tokens {
	header_h     = 48,
	bottom_h     = 36,
	status_h     = 28,
	margin       = 14,
	gutter       = 8,
	control_h    = 24,
	control_h_sm = 22,
	track_pad    = 10,
	row_h        = 26,
	fader_w      = 16,
	meter_w      = 9,
	knob_r       = 20,
	knob_r_sm    = 15,
	fx_h         = 250,
	palette_w    = 560,
	palette_h    = 460,
	io_w         = 426,
}

// ---------------------------------------------------------------- theme

Tokens :: struct {
	color:   Color_Tokens,
	space:   Space_Tokens,
	type:    Type_Tokens,
	metrics: Metric_Tokens,
}

TOKENS_DEFAULT := Tokens {
	color   = COLORS_DEFAULT,
	space   = SPACE,
	type    = TYPE,
	metrics = METRICS,
}

TOKENS_HIGH_CONTRAST := Tokens {
	color   = COLORS_HIGH_CONTRAST,
	space   = SPACE,
	type    = TYPE,
	metrics = METRICS,
}

theme_tokens :: proc(high_contrast: bool) -> Tokens {
	return TOKENS_HIGH_CONTRAST if high_contrast else TOKENS_DEFAULT
}

// ---------------------------------------------------------------- responsive

// The panel is authored at 1180x760. Above that, scale the whole instrument
// (type, padding, control heights) with the window instead of leaving a large
// canvas full of 9 px labels. The zoom follows the geometric mean of the width
// and height ratios, so a wide short window still gets the type bump, but it
// never compresses the virtual frame below the tested 900x620 minimum.
// Below 1180x760 the zoom stays at 1:1 and the flexible layout does the work.
UI_BASE_WIDTH  :: 1180
UI_BASE_HEIGHT :: 760
UI_MIN_WIDTH   :: 900
UI_MIN_HEIGHT  :: 620
UI_MAX_ZOOM    :: 1.8

ui_zoom_for_window :: proc(width, height: int) -> f32 {
	if width <= 0 || height <= 0 {
		return 1
	}
	area_ratio := (f32(width) / UI_BASE_WIDTH) * (f32(height) / UI_BASE_HEIGHT)
	z := math.sqrt(area_ratio)
	z = min(z, f32(width) / UI_MIN_WIDTH, f32(height) / UI_MIN_HEIGHT)
	return clamp(z, 1.0, UI_MAX_ZOOM)
}

// Layout size after the window has been scaled. Rounding keeps the virtual
// frame integral, so every pane still lands on whole layout pixels.
ui_virtual_size :: proc(width, height: int) -> (int, int) {
	z := ui_zoom_for_window(width, height)
	return max(int(math.round(f32(width) / z)), 1),
	       max(int(math.round(f32(height) / z)), 1)
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
