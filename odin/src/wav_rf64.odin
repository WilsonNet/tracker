// RF64 read/write support (EBU Tech 3306).
//
// RF64 keeps the WAV chunk layout but replaces the 32-bit RIFF and data sizes
// with 0xFFFFFFFF sentinels and stores the real values in a `ds64` chunk. The
// writer switches automatically when a normal RIFF file would overflow; the
// streaming writer always emits RF64 so a take can grow past 4 GB without
// buffering the whole payload.

package main

import "core:encoding/endian"
import "core:os"

// 12 RIFF + 36 ds64 + 26 fmt (18-byte body) + 12 fact + 8 data header.
WAV_RF64_HEADER_SIZE :: 94

// How many interleaved samples a streaming write converts per syscall.
@(private)
WAV_STREAM_CHUNK_SAMPLES :: 8192

@(private)
Rf64_Ds64 :: struct {
	riff_size:    u64,
	data_size:    u64,
	sample_count: u64,
}

// Parses a structurally valid ds64 chunk at `off`. Table overrides are not
// supported (our writer never emits them), so a non-zero table is rejected
// instead of silently mis-sizing another chunk.
@(private)
rf64_ds64_at :: proc(data: []byte, off: int) -> (ds64: Rf64_Ds64, ok: bool) {
	if off < 0 || off + 8 > len(data) || !tag_eq(data[off:], "ds64") {
		return {}, false
	}
	size := u64(endian.unchecked_get_u32le(data[off + 4:]))
	if size < 28 {
		return {}, false
	}
	payload := off + 8
	if size > u64(len(data) - payload) {
		return {}, false
	}
	ds64.riff_size = endian.unchecked_get_u64le(data[payload:])
	ds64.data_size = endian.unchecked_get_u64le(data[payload + 8:])
	ds64.sample_count = endian.unchecked_get_u64le(data[payload + 16:])
	table_length := endian.unchecked_get_u32le(data[payload + 24:])
	if table_length != 0 {
		return {}, false
	}
	// The data chunk has to fit inside the container, and a frame is at least
	// one byte, so the sample count can never exceed the data byte count.
	if ds64.data_size > ds64.riff_size {
		return {}, false
	}
	if ds64.sample_count > ds64.data_size {
		return {}, false
	}
	return ds64, true
}

// Locates ds64. The normal walk covers the required layout (ds64 first) and
// files with fmt before or after it. If a 0xFFFFFFFF data chunk appears before
// ds64, its real end is unknown, so fall back to scanning for a validated
// ds64 header.
@(private)
rf64_find_ds64 :: proc(data: []byte) -> (ds64: Rf64_Ds64, offset: int, ok: bool) {
	off := 12
	for off + 8 <= len(data) {
		size := u64(endian.unchecked_get_u32le(data[off + 4:]))
		if tag_eq(data[off:], "ds64") {
			if d, valid := rf64_ds64_at(data, off); valid {
				return d, off, true
			}
			return {}, 0, false
		}
		if tag_eq(data[off:], "data") && size == 0xFFFF_FFFF {
			break
		}
		payload := off + 8
		if size > u64(len(data) - payload) {
			break
		}
		next := u64(payload) + size + (size % 2)
		if next <= u64(off) || next > u64(len(data)) {
			break
		}
		off = int(next)
	}

	for p := 12; p + 8 <= len(data); p += 1 {
		if !tag_eq(data[p:], "ds64") {
			continue
		}
		if d, valid := rf64_ds64_at(data, p); valid {
			return d, p, true
		}
	}
	return {}, 0, false
}

@(private)
wav_parse_rf64 :: proc(data: []byte) -> (wav: Wav, ok: bool) {
	ds64, ds64_off, have_ds64 := rf64_find_ds64(data)
	if !have_ds64 {
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
		size := u64(endian.unchecked_get_u32le(data[off + 4:]))
		payload := off + 8

		switch {
		case tag_eq(chunk, "ds64"):
			if off != ds64_off {
				return {}, false // duplicate ds64
			}
		case tag_eq(chunk, "fmt "):
			if size >= 16 && payload + 16 <= len(data) {
				format = endian.unchecked_get_u16le(data[payload:])
				wav.channels = u32(endian.unchecked_get_u16le(data[payload + 2:]))
				wav.sample_rate = endian.unchecked_get_u32le(data[payload + 4:])
				block_align = endian.unchecked_get_u16le(data[payload + 12:])
				bits = endian.unchecked_get_u16le(data[payload + 14:])
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
		case tag_eq(chunk, "data"):
			declared := size
			if declared == 0xFFFF_FFFF {
				declared = ds64.data_size
			}
			// A truncated fixture must not drive an allocation larger than the
			// bytes actually present.
			available := u64(len(data) - payload)
			if declared > available {
				declared = available
			}
			data_off = payload
			data_len = int(declared)
			have_data = true
		}

		advance := size
		if tag_eq(chunk, "data") && size == 0xFFFF_FFFF {
			advance = ds64.data_size
		}
		if advance > u64(len(data)) {
			break
		}
		next := u64(payload) + advance + (advance % 2)
		if next <= u64(off) || next > u64(len(data)) {
			break
		}
		off = int(next)
	}

	if !have_fmt || !have_data {
		return {}, false
	}
	if !wav_decode(&wav, data, data_off, data_len, format, bits, block_align) {
		return {}, false
	}
	return wav, true
}

@(private)
Wav_Container :: enum {
	Riff,
	Rf64,
}

// Size arithmetic shared by wav_write and the tests. `frames` is deliberately
// u64 so >4 GB decisions are testable without allocating a sample buffer.
@(private)
Wav_Plan :: struct {
	container:   Wav_Container,
	header_size: int,
	data_len:    u64,
	frames:      u64,
	riff_size:   u64,
}

@(private)
wav_plan :: proc(sample_rate, channels: u32, frames: u64) -> (plan: Wav_Plan, ok: bool) {
	if channels == 0 || channels > WAV_MAX_CHANNELS || sample_rate == 0 {
		return {}, false
	}
	frame_bytes := u64(channels) * 4
	if frames > max(u64) / frame_bytes {
		return {}, false
	}
	data_len := frames * frame_bytes
	// Same 32-bit byte-rate guard as the historical writer.
	if u64(sample_rate) * frame_bytes > 0xFFFF_FFFF {
		return {}, false
	}

	plan.data_len = data_len
	plan.frames = frames
	if data_len <= 0xFFFF_FFFF && frames <= 0xFFFF_FFFF &&
	   data_len <= u64(0xFFFF_FFFF) - u64(WAV_HEADER_SIZE - 8) {
		plan.container = .Riff
		plan.header_size = WAV_HEADER_SIZE
		plan.riff_size = u64(WAV_HEADER_SIZE - 8) + data_len
		return plan, true
	}

	riff_overhead := u64(WAV_RF64_HEADER_SIZE - 8)
	if data_len > max(u64) - riff_overhead {
		return {}, false
	}
	plan.container = .Rf64
	plan.header_size = WAV_RF64_HEADER_SIZE
	plan.riff_size = riff_overhead + data_len
	return plan, true
}

// Fills a complete RF64 header. The data chunk size is always the sentinel;
// the real sizes live in ds64. `frames` is the per-channel sample count.
@(private)
wav_rf64_put_header :: proc(
	buf: []byte,
	sample_rate, channels: u32,
	frames, data_len: u64,
) -> bool {
	if len(buf) < WAV_RF64_HEADER_SIZE || channels == 0 || channels > WAV_MAX_CHANNELS {
		return false
	}
	frame_bytes := u64(channels) * 4
	if frames > max(u64) / frame_bytes || frames * frame_bytes != data_len {
		return false
	}
	byte_rate := u64(sample_rate) * frame_bytes
	if byte_rate > 0xFFFF_FFFF {
		return false
	}
	riff_overhead := u64(WAV_RF64_HEADER_SIZE - 8)
	if data_len > max(u64) - riff_overhead {
		return false
	}

	put_tag(buf[0:], "RF64")
	endian.unchecked_put_u32le(buf[4:], 0xFFFF_FFFF)
	put_tag(buf[8:], "WAVE")

	put_tag(buf[12:], "ds64")
	endian.unchecked_put_u32le(buf[16:], 28)
	endian.unchecked_put_u64le(buf[20:], riff_overhead + data_len)
	endian.unchecked_put_u64le(buf[28:], data_len)
	endian.unchecked_put_u64le(buf[36:], frames)
	endian.unchecked_put_u32le(buf[44:], 0) // no table overrides

	put_tag(buf[48:], "fmt ")
	endian.unchecked_put_u32le(buf[52:], 18)
	endian.unchecked_put_u16le(buf[56:], 3) // WAVE_FORMAT_IEEE_FLOAT
	endian.unchecked_put_u16le(buf[58:], u16(channels))
	endian.unchecked_put_u32le(buf[60:], sample_rate)
	endian.unchecked_put_u32le(buf[64:], u32(byte_rate))
	endian.unchecked_put_u16le(buf[68:], u16(channels * 4))
	endian.unchecked_put_u16le(buf[70:], 32)
	endian.unchecked_put_u16le(buf[72:], 0) // cbSize

	put_tag(buf[74:], "fact")
	endian.unchecked_put_u32le(buf[78:], 4)
	// EBU 3306: the 32-bit sample count is a sentinel too; ds64.sample_count
	// is authoritative even when the value would fit.
	endian.unchecked_put_u32le(buf[82:], 0xFFFF_FFFF)

	put_tag(buf[86:], "data")
	endian.unchecked_put_u32le(buf[90:], 0xFFFF_FFFF)
	return true
}

@(private)
wav_write_all :: proc(f: ^os.File, data: []byte) -> bool {
	if f == nil {
		return false
	}
	remaining := data
	for len(remaining) > 0 {
		n, err := os.write(f, remaining)
		if err != nil || n <= 0 || n > len(remaining) {
			return false
		}
		remaining = remaining[n:]
	}
	return true
}

// Writes an RF64 file from an in-memory slice. wav_write only takes this path
// when the planned RIFF size would overflow; large payloads go through the
// streaming writer so the file is not copied into a second giant buffer.
@(private)
wav_write_rf64 :: proc(path: string, sample_rate, channels: u32, samples: []f32) -> bool {
	stream, ok := wav_stream_open(path, sample_rate, channels)
	if !ok {
		return false
	}
	if !wav_stream_write(&stream, samples) {
		wav_stream_close(&stream)
		return false
	}
	return wav_stream_close(&stream)
}

// Streaming 32-bit float writer. It emits an RF64 header immediately and
// patches the ds64 sizes on close, so memory use stays bounded regardless of
// file length. `frames` is the number of complete interleaved frames written.
Wav_Stream :: struct {
	file:        ^os.File,
	sample_rate: u32,
	channels:    u32,
	frames:      u64,
	failed:      bool,
}

// Opens `path` for RF64 output. Channels are limited to WAV_MAX_CHANNELS and
// the byte-rate field must fit 32 bits, mirroring wav_write.
wav_stream_open :: proc(path: string, sample_rate: u32, channels: u32) -> (stream: Wav_Stream, ok: bool) {
	if channels == 0 || channels > WAV_MAX_CHANNELS || sample_rate == 0 {
		return {}, false
	}
	if u64(sample_rate) * u64(channels) * 4 > 0xFFFF_FFFF {
		return {}, false
	}
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {
		return {}, false
	}

	stream.file = f
	stream.sample_rate = sample_rate
	stream.channels = channels

	header: [WAV_RF64_HEADER_SIZE]byte
	if !wav_rf64_put_header(header[:], sample_rate, channels, 0, 0) ||
	   !wav_write_all(f, header[:]) {
		os.close(f)
		return {}, false
	}
	return stream, true
}

// Appends complete interleaved frames. `samples` must be a multiple of the
// channel count; a short slice is rejected without poisoning the stream.
wav_stream_write :: proc(stream: ^Wav_Stream, samples: []f32) -> bool {
	if stream == nil || stream.file == nil || stream.failed {
		return false
	}
	if len(samples) == 0 {
		return true
	}
	channels := int(stream.channels)
	if channels == 0 || len(samples) % channels != 0 {
		return false
	}
	new_frames := u64(len(samples) / channels)
	if new_frames > max(u64) - stream.frames {
		stream.failed = true
		return false
	}

	bytes: [WAV_STREAM_CHUNK_SAMPLES * 4]byte
	for off := 0; off < len(samples); off += WAV_STREAM_CHUNK_SAMPLES {
		n := min(WAV_STREAM_CHUNK_SAMPLES, len(samples) - off)
		for i in 0 ..< n {
			endian.unchecked_put_u32le(bytes[i * 4:], transmute(u32)samples[off + i])
		}
		if !wav_write_all(stream.file, bytes[:n * 4]) {
			stream.failed = true
			return false
		}
	}
	stream.frames += new_frames
	return true
}

// Finalizes the ds64 sizes and closes the file. Returns false if any write
// failed or the header could not be patched.
wav_stream_close :: proc(stream: ^Wav_Stream) -> bool {
	if stream == nil || stream.file == nil {
		return false
	}
	ok := !stream.failed
	if ok {
		data_len := stream.frames * u64(stream.channels) * 4
		header: [WAV_RF64_HEADER_SIZE]byte
		if !wav_rf64_put_header(header[:], stream.sample_rate, stream.channels, stream.frames, data_len) {
			ok = false
		} else if _, err := os.seek(stream.file, 0, .Start); err != nil {
			ok = false
		} else if !wav_write_all(stream.file, header[:]) {
			ok = false
		}
	}
	if os.close(stream.file) != nil {
		ok = false
	}
	stream.file = nil
	return ok
}
