// WAV read/write. 32-bit IEEE float is the working format, mirroring the
// Rust engine's 32-bit float philosophy. The reader also accepts the integer
// PCM formats ffmpeg/sox commonly produce (8/16/24/32-bit integer, 64-bit
// float), so the CLI can ingest references.

package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"

import dsp "dsp"

// Matches the writer's limit; keeps malformed headers from allocating absurd
// sample arrays and mirrors the engine's track channel count.
WAV_MAX_CHANNELS :: 32
// 12 RIFF + 26 fmt (18-byte body) + 12 fact + 8 data header.
WAV_HEADER_SIZE :: 58

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

// The RIFF size field is 32 bits and covers everything after the first 8 bytes.
@(private)
wav_riff_fits :: proc(data_len: int) -> bool {
	if data_len < 0 {
		return false
	}
	return u64(data_len) + u64(WAV_HEADER_SIZE - 8) <= 0xFFFF_FFFF
}

// Writes 32-bit float WAV with a `fact` chunk. Small files keep the historical
// RIFF layout byte-for-byte; once a 32-bit size field would overflow the writer
// switches to RF64 (64-bit sizes in `ds64`) automatically.
wav_write :: proc(path: string, sample_rate: u32, channels: u32, samples: []f32) -> bool {
	if channels == 0 || channels > WAV_MAX_CHANNELS || len(samples) == 0 {
		return false
	}
	if len(samples) % int(channels) != 0 {
		return false
	}
	if sample_rate == 0 {
		return false
	}
	frames := len(samples) / int(channels)
	// One plan drives both the size guard and the container choice, so the
	// arithmetic can be tested without allocating a >4 GB sample buffer.
	plan, plan_ok := wav_plan(sample_rate, channels, u64(frames))
	if !plan_ok {
		return false
	}
	if plan.container == .Rf64 {
		return wav_write_rf64(path, sample_rate, channels, samples)
	}

	data_len := len(samples) * 4
	buf := make([]byte, WAV_HEADER_SIZE + data_len)
	defer delete(buf)

	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(WAV_HEADER_SIZE - 8 + data_len))
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
		endian.put_f32(buf[WAV_HEADER_SIZE + i * 4:], .Little, s)
	}

	return write_file_atomic(path, buf)
}

// External render formats. The engine always works in f32; the export writer
// converts to integer PCM only at the file boundary. Integer exports stay RIFF
// (no RF64): a >4 GB PCM mix reports failure instead of writing a bad header.
Wav_Export_Format :: enum u8 {
	F32,
	PCM24,
	PCM16,
}

WAV_PCM_HEADER_SIZE :: 44

wav_write_export :: proc(
	path: string,
	sample_rate: u32,
	channels: u32,
	samples: []f32,
	format: Wav_Export_Format,
) -> bool {
	switch format {
	case .F32:
		return wav_write(path, sample_rate, channels, samples)
	case .PCM24:
		return wav_write_pcm(path, sample_rate, channels, samples, 24)
	case .PCM16:
		return wav_write_pcm(path, sample_rate, channels, samples, 16)
	}
	return false
}

@(private)
wav_write_pcm :: proc(
	path: string,
	sample_rate: u32,
	channels: u32,
	samples: []f32,
	bits: int,
) -> bool {
	if channels == 0 || channels > WAV_MAX_CHANNELS || len(samples) == 0 {
		return false
	}
	if len(samples) % int(channels) != 0 || sample_rate == 0 {
		return false
	}
	if bits != 16 && bits != 24 {
		return false
	}
	bytes_per_sample := bits / 8
	frame_bytes := int(channels) * bytes_per_sample
	byte_rate := u64(sample_rate) * u64(frame_bytes)
	if byte_rate > 0xFFFF_FFFF {
		return false
	}
	data_len := len(samples) * bytes_per_sample
	if u64(WAV_PCM_HEADER_SIZE - 8) + u64(data_len) > 0xFFFF_FFFF {
		return false
	}

	buf := make([]byte, WAV_PCM_HEADER_SIZE + data_len)
	defer delete(buf)

	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(WAV_PCM_HEADER_SIZE - 8 + data_len))
	put_tag(buf[8:], "WAVE")

	put_tag(buf[12:], "fmt ")
	endian.unchecked_put_u32le(buf[16:], 16)
	endian.unchecked_put_u16le(buf[20:], 1) // WAVE_FORMAT_PCM
	endian.unchecked_put_u16le(buf[22:], u16(channels))
	endian.unchecked_put_u32le(buf[24:], sample_rate)
	endian.unchecked_put_u32le(buf[28:], u32(byte_rate))
	endian.unchecked_put_u16le(buf[32:], u16(frame_bytes))
	endian.unchecked_put_u16le(buf[34:], u16(bits))

	put_tag(buf[36:], "data")
	endian.unchecked_put_u32le(buf[40:], u32(data_len))

	max_value := f32((i32(1) << uint(bits - 1)) - 1)
	for s, i in samples {
		v := clamp(s, -1.0, 1.0)
		q := i32(v * max_value + (0.5 if v >= 0 else -0.5))
		off := WAV_PCM_HEADER_SIZE + i * bytes_per_sample
		switch bits {
		case 16:
			endian.unchecked_put_u16le(buf[off:], u16(u32(q)))
		case 24:
			u := u32(q) & 0xFFFFFF
			buf[off + 0] = byte(u)
			buf[off + 1] = byte(u >> 8)
			buf[off + 2] = byte(u >> 16)
		}
	}

	return write_file_atomic(path, buf)
}

wav_read :: proc(path: string) -> (wav: Wav, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)

	return wav_parse(data)
}

// Parses a complete WAV image. RIFF and RF64 share the fmt validation and the
// sample decoder below; only the chunk-size bookkeeping differs.
@(private)
wav_parse :: proc(data: []byte) -> (wav: Wav, ok: bool) {
	if len(data) < 12 || !tag_eq(data[8:], "WAVE") {
		return {}, false
	}
	switch {
	case tag_eq(data[0:], "RIFF"):
		return wav_parse_riff(data)
	case tag_eq(data[0:], "RF64"), tag_eq(data[0:], "BW64"):
		// BW64 (ITU-R BS.2088) uses the RF64 ds64 layout under another tag.
		return wav_parse_rf64(data)
	case:
		return {}, false
	}
}

@(private)
wav_parse_riff :: proc(data: []byte) -> (wav: Wav, ok: bool) {
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

		if tag_eq(chunk, "fmt ") {
			// Never read a fmt body across the declared chunk boundary.
			if size >= 16 && payload + 16 <= len(data) {
				format = endian.unchecked_get_u16le(data[payload:])
				wav.channels = u32(endian.unchecked_get_u16le(data[payload + 2:]))
				wav.sample_rate = endian.unchecked_get_u32le(data[payload + 4:])
				block_align = endian.unchecked_get_u16le(data[payload + 12:])
				bits = endian.unchecked_get_u16le(data[payload + 14:])
				// WAVE_FORMAT_EXTENSIBLE carries the real format in the
				// subformat GUID. Its first four bytes are the format tag.
				if format == 0xFFFE && size >= 40 && payload + 40 <= len(data) {
					subformat := endian.unchecked_get_u32le(data[payload + 24:])
					if subformat == 3 {
						format = 3
					} else if subformat == 1 {
						format = 1
					}
				}
				have_fmt = true
			}
		} else if tag_eq(chunk, "data") {
			data_off = payload
			data_len = min(size, len(data) - payload)
			have_data = true
		}

		// Chunks are word-aligned; an odd-sized chunk has one pad byte.
		next := payload + size + (size % 2)
		if next <= off {
			break
		}
		off = next
	}

	if !have_fmt || !have_data {
		return {}, false
	}
	if !wav_decode(&wav, data, data_off, data_len, format, bits, block_align) {
		return {}, false
	}
	return wav, true
}

// Validates fmt and turns the payload into interleaved f32 samples. Shared by
// the RIFF and RF64 readers so both report `frames` and `samples` identically.
@(private)
wav_decode :: proc(
	wav: ^Wav,
	data: []byte,
	data_off: int,
	data_len: int,
	format: u16,
	bits: u16,
	block_align: u16,
) -> bool {
	if wav.channels == 0 || wav.channels > WAV_MAX_CHANNELS || wav.sample_rate == 0 {
		return false
	}
	if block_align == 0 {
		return false
	}
	if data_off < 0 || data_off > len(data) || data_len < 0 || data_len > len(data) - data_off {
		return false
	}

	bytes_per_sample := 0
	switch {
	case format == 3 && bits == 32:
		bytes_per_sample = 4
	case format == 3 && bits == 64:
		bytes_per_sample = 8
	case format == 1 && bits == 8:
		bytes_per_sample = 1
	case format == 1 && bits == 16:
		bytes_per_sample = 2
	case format == 1 && bits == 24:
		bytes_per_sample = 3
	case format == 1 && bits == 32:
		bytes_per_sample = 4
	case:
		return false
	}

	// Samples live inside frames of `block_align` bytes. Reject headers whose
	// frame stride cannot hold the declared channels; trusting them would read
	// past the data chunk (and previously past the end of the file).
	frame_bytes := int(wav.channels) * bytes_per_sample
	if int(block_align) < frame_bytes {
		return false
	}
	frames := data_len / int(block_align)
	sample_count := frames * int(wav.channels)
	if frames > 0 && sample_count / frames != int(wav.channels) {
		return false
	}

	wav.samples = make([]f32, sample_count)
	wav.frames = frames
	stride := int(block_align)

	switch {
	case format == 3 && bits == 32:
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				v, _ := endian.get_f32(data[frame + c * 4:], .Little)
				wav.samples[f * int(wav.channels) + c] = v
			}
		}
	case format == 3 && bits == 64:
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				v, _ := endian.get_f64(data[frame + c * 8:], .Little)
				wav.samples[f * int(wav.channels) + c] = f32(v)
			}
		}
	case format == 1 && bits == 8:
		// 8-bit WAV PCM is unsigned with a 128 midpoint.
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				wav.samples[f * int(wav.channels) + c] = (f32(data[frame + c]) - 128.0) / 128.0
			}
		}
	case format == 1 && bits == 16:
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				p := frame + c * 2
				v := i16(endian.unchecked_get_u16le(data[p:]))
				wav.samples[f * int(wav.channels) + c] = f32(v) / 32768.0
			}
		}
	case format == 1 && bits == 24:
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				p := frame + c * 3
				v := u32(data[p]) | u32(data[p + 1]) << 8 | u32(data[p + 2]) << 16
				s := i32(v)
				if v & 0x800000 != 0 {
					s -= 0x1000000
				}
				wav.samples[f * int(wav.channels) + c] = f32(s) / 8388608.0
			}
		}
	case format == 1 && bits == 32:
		for f in 0 ..< frames {
			frame := data_off + f * stride
			for c in 0 ..< int(wav.channels) {
				p := frame + c * 4
				v := i32(endian.unchecked_get_u32le(data[p:]))
				wav.samples[f * int(wav.channels) + c] = f32(v) / 2147483648.0
			}
		}
	}

	return true
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
