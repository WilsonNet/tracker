package main

import "core:encoding/endian"
import "core:math"
import "core:os"
import "core:testing"

WAV_TMP :: "/tmp/tracker-odin-test"

@(test)
wav_float32_roundtrip :: proc(t: ^testing.T) {
	path := WAV_TMP + "-roundtrip.wav"
	defer os.remove(path)

	RATE :: 48_000
	CHANNELS :: 2
	frames := 1_000
	buf := make([]f32, frames * CHANNELS)
	defer delete(buf)
	for i in 0 ..< frames {
		t := f32(i) / RATE
		buf[i * 2 + 0] = 0.5 * math.sin(t * 440.0 * f32(math.TAU))
		buf[i * 2 + 1] = -0.25 * math.sin(t * 440.0 * f32(math.TAU))
	}

	testing.expect(t, wav_write(path, RATE, CHANNELS, buf), "write failed")
	wav, ok := wav_read(path)
	testing.expect(t, ok, "read failed")
	defer wav_destroy(&wav)

	testing.expectf(t, wav.sample_rate == RATE, "rate %v", wav.sample_rate)
	testing.expectf(t, wav.channels == CHANNELS, "channels %v", wav.channels)
	testing.expectf(t, wav.frames == frames, "frames %v", wav.frames)
	testing.expectf(t, len(wav.samples) == len(buf), "samples %v", len(wav.samples))
	for i in 0 ..< len(buf) {
		testing.expectf(t, abs(wav.samples[i] - buf[i]) < 1e-7, "sample %d: %v vs %v", i, wav.samples[i], buf[i])
	}
}

@(test)
wav_header_is_well_formed :: proc(t: ^testing.T) {
	path := WAV_TMP + "-header.wav"
	defer os.remove(path)
	buf := [4]f32{0.0, 0.1, -0.1, 0.0}
	testing.expect(t, wav_write(path, 44_100, 2, buf[:]), "write failed")

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, "file unreadable")
	testing.expectf(t, len(data) == 58 + 16, "file size %d", len(data))
	testing.expect(t, tag_eq(data[0:], "RIFF"), "missing RIFF")
	testing.expect(t, tag_eq(data[8:], "WAVE"), "missing WAVE")
	testing.expect(t, tag_eq(data[12:], "fmt "), "missing fmt")
	testing.expect(t, tag_eq(data[38:], "fact"), "missing fact")
	testing.expect(t, tag_eq(data[50:], "data"), "missing data")
	testing.expectf(t, endian.unchecked_get_u32le(data[4:]) == u32(len(data) - 8), "riff size")
	testing.expectf(t, endian.unchecked_get_u16le(data[20:]) == 3, "not IEEE float")
	testing.expectf(t, endian.unchecked_get_u32le(data[16:]) == 18, "fmt size")
	testing.expectf(t, endian.unchecked_get_u32le(data[46:]) == 2, "fact frame count")
	testing.expectf(t, endian.unchecked_get_u32le(data[54:]) == 16, "data size")
}

@(test)
wav_reads_16_bit_pcm :: proc(t: ^testing.T) {
	path := WAV_TMP + "-pcm16.wav"
	defer os.remove(path)

	// 4 frames, mono, 16-bit PCM: 0, 0.5, -0.5, 0.
	payload := [8]byte{0x00, 0x00, 0x00, 0x40, 0x00, 0xC0, 0x00, 0x00}
	buf := make([]byte, 44 + len(payload))
	defer delete(buf)
	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(len(buf) - 8))
	put_tag(buf[8:], "WAVE")
	put_tag(buf[12:], "fmt ")
	endian.unchecked_put_u32le(buf[16:], 16)
	endian.unchecked_put_u16le(buf[20:], 1) // PCM
	endian.unchecked_put_u16le(buf[22:], 1)
	endian.unchecked_put_u32le(buf[24:], 48_000)
	endian.unchecked_put_u32le(buf[28:], 96_000)
	endian.unchecked_put_u16le(buf[32:], 2)
	endian.unchecked_put_u16le(buf[34:], 16)
	put_tag(buf[36:], "data")
	endian.unchecked_put_u32le(buf[40:], u32(len(payload)))
	copy(buf[44:], payload[:])
	testing.expect(t, os.write_entire_file(path, buf) == nil, "fixture write failed")

	wav, ok := wav_read(path)
	testing.expect(t, ok, "read failed")
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 4, "frames %v", wav.frames)
	testing.expectf(t, abs(wav.samples[1] - 0.5) < 1e-6, "sample 1 %v", wav.samples[1])
	testing.expectf(t, abs(wav.samples[2] + 0.5) < 1e-6, "sample 2 %v", wav.samples[2])
}

@(test)
wav_rejects_garbage :: proc(t: ^testing.T) {
	path := WAV_TMP + "-garbage.wav"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, "this is definitely not a wave file") == nil)
	_, ok := wav_read(path)
	testing.expect(t, !ok, "garbage accepted as WAV")
}

@(test)
wav_write_rejects_bad_shapes :: proc(t: ^testing.T) {
	buf := [3]f32{0.0, 0.0, 0.0}
	testing.expect(t, !wav_write(WAV_TMP + "-bad.wav", 48_000, 0, buf[:]), "zero channels accepted")
	testing.expect(t, !wav_write(WAV_TMP + "-bad.wav", 48_000, 2, buf[:]), "misaligned samples accepted")
	testing.expect(t, !wav_write(WAV_TMP + "-bad.wav", 48_000, 1, nil), "empty samples accepted")
}

@(test)
wav_export_integer_pcm_roundtrip :: proc(t: ^testing.T) {
	samples := []f32{-1.0, -0.5, -0.1, 0.0, 0.1, 0.5, 1.0}
	formats := [?]struct {
		format: Wav_Export_Format,
		bits:   u16,
		bytes:  int,
	}{
		{.PCM16, 16, 2},
		{.PCM24, 24, 3},
	}
	for item in formats {
		path := WAV_TMP + "-pcm.wav"
		defer os.remove(path)
		testing.expect(t, wav_write_export(path, 48_000, 1, samples, item.format), "write failed")

		data, err := os.read_entire_file(path, context.allocator)
		testing.expect(t, err == nil, "read header failed")
		defer delete(data)
		testing.expect(t, len(data) == WAV_PCM_HEADER_SIZE + len(samples) * item.bytes, "file size")
		testing.expect(t, endian.unchecked_get_u16le(data[20:]) == 1, "PCM format tag")
		testing.expect(t, endian.unchecked_get_u16le(data[34:]) == item.bits, "bit depth")

		wav, ok := wav_read(path)
		testing.expect(t, ok, "decode failed")
		defer wav_destroy(&wav)
		tolerance := f32(1.0) / f32(u32(1) << u32(item.bits - 1))
		for s, i in samples {
			testing.expectf(t, abs(wav.samples[i] - s) <= tolerance, "%v: %v vs %v", item.format, wav.samples[i], s)
		}
	}
}
