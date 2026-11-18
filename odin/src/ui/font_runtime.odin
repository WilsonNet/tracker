// Runtime glyph rasteriser for non-integer display densities.
//
// The committed atlases in font_data.odin cover exactly 12.5 px (body at 1x)
// and 25 px (headings at 1x, body at 2x). Every other physical size -- 1.25x,
// 1.5x, 3x, and heading text at those densities -- is rasterised from the
// bundled Noto Sans Mono TTF with stb_truetype at the exact pixel height the
// display needs. Nothing is ever upscaled from a 1x bitmap.
//
// Glyphs are cached per (pixel size, codepoint) inside the Canvas, so a frame
// rasterises each glyph at most once and canvas_destroy releases the cache.

package ui

import "core:math"
import stb "vendor:stb/truetype"

// Bundled with the app (SIL Open Font License and Apache-2.0 covered; see
// assets/FONT-LICENSE.txt). Paths in #load are relative to this source file.
RUNTIME_FONT_DATA :: #load("../../assets/NotoSansMono-Regular.ttf")

Runtime_Glyph :: struct {
	px_key: int, // pixel size quantised to 1/64 px
	ch:     u8,
	w, h:   i32,
	xoff, yoff: i32,
	alpha: []u8,
}

Runtime_Font :: struct {
	info:   stb.fontinfo,
	ready:  bool,
	tried:  bool,
	glyphs: [dynamic]Runtime_Glyph,
}

runtime_font_destroy :: proc(f: ^Runtime_Font) {
	for g in f.glyphs {
		delete(g.alpha)
	}
	delete(f.glyphs)
	f.glyphs = nil
	f.ready = false
	f.tried = false
}

@(private)
runtime_font_init :: proc(f: ^Runtime_Font) -> bool {
	if f.tried {
		return f.ready
	}
	f.tried = true
	f.ready = stb.InitFont(&f.info, raw_data(RUNTIME_FONT_DATA), 0) != false
	return f.ready
}

@(private)
runtime_glyph :: proc(f: ^Runtime_Font, ch: u8, px: f32) -> ^Runtime_Glyph {
	key := int(math.round(px * 64))
	for &g in f.glyphs {
		if g.px_key == key && g.ch == ch {
			return &g
		}
	}

	w, h, xoff, yoff: i32
	alpha: []u8
	scale := stb.ScaleForMappingEmToPixels(&f.info, px)
	w_c, h_c, xoff_c, yoff_c: i32
	bmp := stb.GetCodepointBitmap(&f.info, scale, scale, rune(ch), &w_c, &h_c, &xoff_c, &yoff_c)
	w = i32(w_c)
	h = i32(h_c)
	xoff = i32(xoff_c)
	yoff = i32(yoff_c)
	if bmp != nil && w > 0 && h > 0 {
		alpha = make([]u8, int(w * h))
		copy(alpha, bmp[:int(w * h)])
	}
	if bmp != nil {
		stb.FreeBitmap(bmp, nil)
	}
	append(&f.glyphs, Runtime_Glyph{key, ch, w, h, xoff, yoff, alpha})
	return &f.glyphs[len(f.glyphs) - 1]
}

// Physical-pixel text pass. Logical cell metrics are 8x15 at text scale 1 and
// 16x30 at text scale 2; multiplying by the canvas density gives the physical
// advance, and the font is rasterised at 12.5 px * text_scale * density so the
// glyph ink matches the cell instead of being stretched into it.
canvas_text_runtime :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, text_scale: int) {
	if !runtime_font_init(&c.font) {
		return
	}
	s := c.scale
	ts := f32(text_scale)
	cell_w := max(i32(math.round(f32(FONT_W) * ts * s)), 1)
	cell_h := max(i32(math.round(f32(FONT_H) * ts * s)), 1)
	baseline := i32(math.round(12.0 * ts * s))
	font_px := 12.5 * ts * s

	start_x := i32(math.round(x * s))
	start_y := i32(math.round(y * s))
	pen_x := start_x
	pen_y := start_y
	for ch in text {
		if ch == '\n' {
			pen_x = start_x
			pen_y += cell_h
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
