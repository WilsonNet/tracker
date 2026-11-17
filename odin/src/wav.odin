// WAV read/write. 32-bit IEEE float is the working format, mirroring the
// Rust engine's 32-bit float philosophy. The reader also accepts the integer
// PCM formats ffmpeg/sox commonly produce, so the CLI can ingest references.

package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"

import dsp "dsp"

Wav :: struct {
	sample_rate: u32,
	channels:    u32,
	frames:      int,
	// Interleaved samples.
	samples:     []f32,
}

wav_destroy :: proc(w: ^Wav) {
	delete(w.samples)
	w.samples = nil
}

@(private)
put_tag :: proc(dst: []byte, tag: string) {
	for i in 0 ..< len(tag) {
		dst[i] = tag[i]
	}
}

@(private)
tag_eq :: proc(src: []byte, tag: string) -> bool {
	if len(src) < len(tag) {
		return false
	}
	for i in 0 ..< len(tag) {
		if src[i] != tag[i] {
			return false
		}
	}
	return true
}

// Writes 32-bit float WAV with a `fact` chunk.
wav_write :: proc(path: string, sample_rate: u32, channels: u32, samples: []f32) -> bool {
	if channels == 0 || channels > 32 || len(samples) == 0 {
		return false
	}
	if len(samples) % int(channels) != 0 {
		return false
	}
	frames := len(samples) / int(channels)
	data_len := len(samples) * 4
	// 12 RIFF + 26 fmt (18-byte body) + 12 fact + 8 data header.
	HEADER :: 58
	buf := make([]byte, HEADER + data_len)
	defer delete(buf)

	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(HEADER - 8 + data_len))
	put_tag(buf[8:], "WAVE")

	put_tag(buf[12:], "fmt ")
	endian.unchecked_put_u32le(buf[16:], 18)
	endian.unchecked_put_u16le(buf[20:], 3) // WAVE_FORMAT_IEEE_FLOAT
	endian.unchecked_put_u16le(buf[22:], u16(channels))
	endian.unchecked_put_u32le(buf[24:], sample_rate)
	endian.unchecked_put_u32le(buf[28:], sample_rate * channels * 4)
	endian.unchecked_put_u16le(buf[32:], u16(channels * 4))
	endian.unchecked_put_u16le(buf[34:], 32)
	endian.unchecked_put_u16le(buf[36:], 0) // cbSize

	put_tag(buf[38:], "fact")
	endian.unchecked_put_u32le(buf[42:], 4)
	endian.unchecked_put_u32le(buf[46:], u32(frames))

	put_tag(buf[50:], "data")
	endian.unchecked_put_u32le(buf[54:], u32(data_len))
	for s, i in samples {
		endian.put_f32(buf[HEADER + i * 4:], .Little, s)
	}

	return os.write_entire_file(path, buf) == nil
}

wav_read :: proc(path: string) -> (wav: Wav, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)

	if len(data) < 44 || !tag_eq(data[0:], "RIFF") || !tag_eq(data[8:], "WAVE") {
		return {}, false
	}

	format: u16
	bits: u16
	block_align: u16
	data_off: int
	data_len: int
	have_fmt := false
	have_data := false

	off := 12
	for off + 8 <= len(data) {
		chunk := data[off:off + 4]
		size := int(endian.unchecked_get_u32le(data[off + 4:]))
		payload := off + 8

		if tag_eq(chunk, "fmt ") && payload + 16 <= len(data) {
			format = endian.unchecked_get_u16le(data[payload:])
			wav.channels = u32(endian.unchecked_get_u16le(data[payload + 2:]))
			wav.sample_rate = endian.unchecked_get_u32le(data[payload + 4:])
			block_align = endian.unchecked_get_u16le(data[payload + 12:])
			bits = endian.unchecked_get_u16le(data[payload + 14:])
			// WAVE_FORMAT_EXTENSIBLE carries the real format in the subformat GUID.
			if format == 0xFFFE && payload + 40 <= len(data) {
				subformat := endian.unchecked_get_u32le(data[payload + 24:])
				if subformat == 3 {
					format = 3
				} else if subformat == 1 {
					format = 1
				}
			}
			have_fmt = true
		} else if tag_eq(chunk, "data") {
			data_off = payload
			data_len = min(size, len(data) - payload)
			have_data = true
		}

		next := payload + size + (size % 2)
		if next <= off {
			break
		}
		off = next
	}

	if !have_fmt || !have_data || wav.channels == 0 || block_align == 0 {
		return {}, false
	}

	frames := data_len / int(block_align)
	sample_count := frames * int(wav.channels)
	wav.samples = make([]f32, sample_count)
	wav.frames = frames

	switch {
	case format == 3 && bits == 32:
		for i in 0 ..< sample_count {
			v, _ := endian.get_f32(data[data_off + i * 4:], .Little)
			wav.samples[i] = v
		}
	case format == 1 && bits == 16:
		for i in 0 ..< sample_count {
			v := i16(endian.unchecked_get_u16le(data[data_off + i * 2:]))
			wav.samples[i] = f32(v) / 32768.0
		}
	case format == 1 && bits == 24:
		for i in 0 ..< sample_count {
			p := data_off + i * 3
			v := u32(data[p]) | u32(data[p + 1]) << 8 | u32(data[p + 2]) << 16
			if v & 0x800000 != 0 {
				v |= 0xFF000000
			}
			wav.samples[i] = f32(i32(v)) / 8388608.0
		}
	case format == 1 && bits == 32:
		for i in 0 ..< sample_count {
			v := i32(endian.unchecked_get_u32le(data[data_off + i * 4:]))
			wav.samples[i] = f32(v) / 2147483648.0
		}
	case:
		delete(wav.samples)
		wav.samples = nil
		return {}, false
	}

	return wav, true
}

// Prints format details plus peak/RMS. Used by `tracker-odin info`.
wav_print_info :: proc(path: string) -> bool {
	wav, ok := wav_read(path)
	if !ok {
		fmt.eprintfln("cannot read WAV: %s", path)
		return false
	}
	defer wav_destroy(&wav)
	peak, rms := dsp.peak_rms_db(wav.samples, int(wav.channels))
	seconds := f32(wav.frames) / f32(wav.sample_rate)
	fmt.printfln("%s", path)
	fmt.printfln("  %d Hz, %d channel(s), %d frames (%.3f s)", wav.sample_rate, wav.channels, wav.frames, seconds)
	fmt.printfln("  peak %.2f dBFS, rms %.2f dBFS", peak, rms)
	return true
}
