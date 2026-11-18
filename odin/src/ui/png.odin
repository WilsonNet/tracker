// Minimal PNG writer (zlib deflate) so headless runs produce real screenshots
// without ImageMagick or a browser.

package ui

import "core:os"
import zlib "vendor:zlib"

PNG_SIG :: [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

@(private)
append_u32be :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v >> 24))
	append(out, u8(v >> 16))
	append(out, u8(v >> 8))
	append(out, u8(v))
}

@(private)
append_chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	append_u32be(out, u32(len(data)))
	start := len(out)
	for ch in kind {
		append(out, u8(ch))
	}
	for b in data {
		append(out, b)
	}
	crc := zlib.crc32(0, raw_data(out[start:]), zlib.uInt(len(out) - start))
	append_u32be(out, u32(crc))
}

png_encode :: proc(width, height: int, pixels: []u32) -> []u8 {
	w := max(width, 1)
	h := max(height, 1)
	raw := make([]u8, (w * 4 + 1) * h)
	defer delete(raw)

	for y in 0 ..< h {
		row := y * (w * 4 + 1)
		raw[row] = 0 // filter: none
		for x in 0 ..< w {
			col := pixels[y * w + x]
			o := row + 1 + x * 4
			raw[o + 0] = u8(col >> 16)
			raw[o + 1] = u8(col >> 8)
			raw[o + 2] = u8(col)
			raw[o + 3] = u8(col >> 24)
		}
	}

	bound := zlib.compressBound(zlib.uLong(len(raw)))
	comp := make([]u8, int(bound))
	defer delete(comp)
	dest_len := zlib.uLongf(bound)
	if zlib.compress2(raw_data(comp), &dest_len, raw_data(raw), zlib.uLong(len(raw)), 6) != 0 {
		return nil
	}
	compressed := comp[:int(dest_len)]

	out: [dynamic]u8
	for b in PNG_SIG {
		append(&out, b)
	}

	ihdr := [13]u8{
		u8(u32(w) >> 24), u8(u32(w) >> 16), u8(u32(w) >> 8), u8(u32(w)),
		u8(u32(h) >> 24), u8(u32(h) >> 16), u8(u32(h) >> 8), u8(u32(h)),
		8, 6, 0, 0, 0,
	}
	append_chunk(&out, "IHDR", ihdr[:])
	append_chunk(&out, "IDAT", compressed)
	append_chunk(&out, "IEND", nil)

	result := make([]u8, len(out))
	copy(result, out[:])
	delete(out)
	return result
}

png_write :: proc(path: string, width, height: int, pixels: []u32) -> bool {
	data := png_encode(width, height, pixels)
	if data == nil {
		return false
	}
	defer delete(data)
	return os.write_entire_file(path, data) == nil
}

canvas_screenshot :: proc(c: ^Canvas, path: string) -> bool {
	return png_write(path, c.width, c.height, c.pixels)
}
