#+build !linux
// stb_truetype text path for the headless harness on macOS and non-Linux targets.
package ui

import "core:math"
import "core:unicode/utf8"
import stbtt "vendor:stb/truetype"

@(private)
FONT_INTER_REGULAR := #load("../../assets/Inter-Regular.ttf")
@(private)
FONT_INTER_MEDIUM := #load("../../assets/Inter-Medium.ttf")
@(private)
FONT_INTER_SEMIBOLD := #load("../../assets/Inter-SemiBold.ttf")
@(private)
FONT_NOTO_MONO := #load("../../assets/NotoSansMono-Regular.ttf")

@(private)
soft_fonts: [4]stbtt.fontinfo
@(private)
soft_fonts_init: [4]bool

@(private)
soft_font_info :: proc(weight: Font_Weight) -> (^stbtt.fontinfo, bool) {
	idx := int(weight)
	if !soft_fonts_init[idx] {
		data := FONT_INTER_REGULAR
		#partial switch weight {
		case .Medium:
			data = FONT_INTER_MEDIUM
		case .SemiBold:
			data = FONT_INTER_SEMIBOLD
		case .Mono:
			data = FONT_NOTO_MONO
		}
		if !stbtt.InitFont(&soft_fonts[idx], raw_data(data), 0) {
			return nil, false
		}
		soft_fonts_init[idx] = true
	}
	return &soft_fonts[idx], true
}

@(private)
soft_font_scale :: proc(fi: ^stbtt.fontinfo, px_physical: f32) -> f32 {
	return stbtt.ScaleForMappingEmToPixels(fi, max(px_physical, 1.0))
}

canvas_text_width :: proc(c: ^Canvas, text: string, px: f32, weight: Font_Weight = .Regular) -> f32 {
	if px <= 0 || len(text) == 0 {
		return 0
	}
	fi, ok := soft_font_info(weight)
	if !ok {
		return 0
	}
	scale := soft_font_scale(fi, px * c.scale)
	x_phys: f32 = 0
	prev: rune = 0
	for ch, i in text {
		if i > 0 {
			kern := stbtt.GetCodepointKernAdvance(fi, prev, ch)
			x_phys += f32(kern) * scale
		}
		adv, _: i32
		stbtt.GetCodepointHMetrics(fi, ch, &adv, nil)
		x_phys += f32(adv) * scale
		prev = ch
	}
	return x_phys / c.scale
}

canvas_text_height :: proc(c: ^Canvas, text: string, px: f32, weight: Font_Weight = .Regular) -> f32 {
	if px <= 0 {
		return 0
	}
	fi, ok := soft_font_info(weight)
	if !ok {
		return px
	}
	scale := soft_font_scale(fi, px * c.scale)
	asc, desc, gap: i32
	stbtt.GetFontVMetrics(fi, &asc, &desc, &gap)
	return f32(asc - desc) * scale / c.scale
}

canvas_text_px :: proc(c: ^Canvas, x, y: f32, text: string, col: Color, px: f32, weight: Font_Weight = .Regular) {
	if px <= 0 || len(text) == 0 || (col >> 24) == 0 {
		return
	}
	fi, ok := soft_font_info(weight)
	if !ok {
		return
	}
	scale := soft_font_scale(fi, px * c.scale)
	asc, _, _: i32
	stbtt.GetFontVMetrics(fi, &asc, nil, nil)

	pen_x := x * c.scale
	baseline := y * c.scale + f32(asc) * scale
	prev: rune = 0
	first := true
	glyph_buf: [256 * 256]u8

	s := text
	for len(s) > 0 {
		ch, width := utf8.decode_rune_in_string(s)
		s = s[width:]
		if !first {
			kern := stbtt.GetCodepointKernAdvance(fi, prev, ch)
			pen_x += f32(kern) * scale
		}
		first = false
		prev = ch

		x0, y0, x1, y1: i32
		stbtt.GetCodepointBitmapBox(fi, ch, scale, scale, &x0, &y0, &x1, &y1)
		gw := int(x1 - x0)
		gh := int(y1 - y0)
		if gw > 0 && gh > 0 && gw <= 256 && gh <= 256 {
			stbtt.MakeCodepointBitmap(fi, raw_data(glyph_buf[:]), i32(gw), i32(gh), i32(gw), scale, scale, ch)
			bx := int(math.floor(pen_x)) + int(x0)
			by := int(math.round(baseline)) + int(y0)
			for gy in 0 ..< gh {
				py := by + gy
				if py < 0 || py >= c.height {
					continue
				}
				for gx in 0 ..< gw {
					cov_u8 := glyph_buf[gy * gw + gx]
					if cov_u8 == 0 {
						continue
					}
					px_pos := bx + gx
					soft_plot(c, px_pos, py, col, f32(cov_u8) / 255.0)
				}
			}
		}

		adv: i32
		stbtt.GetCodepointHMetrics(fi, ch, &adv, nil)
		pen_x += f32(adv) * scale
	}
}
