package main

import "core:encoding/endian"
import "core:os"
import "core:testing"

@(private)
wav_fixture :: proc(
	format: u16,
	channels: u16,
	rate: u32,
	block_align: u16,
	bits: u16,
	payload: []byte,
	fmt_size: u32 = 16,
) -> []byte {
	total := 12 + 8 + int(fmt_size) + 8 + len(payload)
	buf := make([]byte, total)
	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(len(buf) - 8))
	put_tag(buf[8:], "WAVE")
	put_tag(buf[12:], "fmt ")
	endian.unchecked_put_u32le(buf[16:], fmt_size)
	endian.unchecked_put_u16le(buf[20:], format)
	endian.unchecked_put_u16le(buf[22:], channels)
	endian.unchecked_put_u32le(buf[24:], rate)
	endian.unchecked_put_u32le(buf[28:], rate * u32(channels) * u32(bits / 8))
	endian.unchecked_put_u16le(buf[32:], block_align)
	endian.unchecked_put_u16le(buf[34:], bits)
	off := 36
	if fmt_size > 16 {
		off = 36 + int(fmt_size) - 16
	}
	put_tag(buf[off:], "data")
	endian.unchecked_put_u32le(buf[off + 4:], u32(len(payload)))
	copy(buf[off + 8:], payload)
	return buf
}

@(private)
wav_expect_reject :: proc(t: ^testing.T, path: string, buf: []byte) {
	defer delete(buf)
	testing.expect(t, os.write_entire_file(path, buf) == nil, "fixture write")
	wav, ok := wav_read(path)
	if ok {
		wav_destroy(&wav)
	}
	testing.expect(t, !ok, "malformed WAV accepted")
}

@(test)
wav_rejects_block_align_smaller_than_a_frame :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-badalign.wav"
	defer os.remove(path)
	payload := [8]byte{0, 1, 2, 3, 4, 5, 6, 7}
	wav_expect_reject(t, path, wav_fixture(1, 2, 48_000, 1, 16, payload[:]))
}

@(test)
wav_reads_24_bit_pcm_with_sign_extension :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-24bit.wav"
	defer os.remove(path)
	// Max positive, min negative, -1 LSB.
	payload := [9]byte{
		0xFF, 0xFF, 0x7F,
		0x00, 0x00, 0x80,
		0xFF, 0xFF, 0xFF,
	}
	buf := wav_fixture(1, 1, 48_000, 3, 24, payload[:])
	defer delete(buf)
	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "24-bit read failed")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 3, "frames %d", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 8388607.0 / 8388608.0) < 1e-6, "positive %v", wav.samples[0])
	testing.expectf(t, wav.samples[1] == -1.0, "negative %v", wav.samples[1])
	testing.expectf(t, abs(wav.samples[2] + 1.0 / 8388608.0) < 1e-9, "-1 LSB %v", wav.samples[2])
}

@(test)
wav_reads_32_bit_pcm_sign :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-pcm32.wav"
	defer os.remove(path)
	payload := make([]byte, 12)
	defer delete(payload)
	endian.unchecked_put_u32le(payload[0:], 0x7FFF_FFFF)
	endian.unchecked_put_u32le(payload[4:], 0x8000_0000)
	endian.unchecked_put_u32le(payload[8:], 0)
	buf := wav_fixture(1, 1, 48_000, 4, 32, payload)
	defer delete(buf)
	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "32-bit PCM read failed")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, abs(wav.samples[0] - 1.0) < 1e-6, "positive %v", wav.samples[0])
	testing.expectf(t, wav.samples[1] == -1.0, "negative %v", wav.samples[1])
	testing.expectf(t, wav.samples[2] == 0, "zero %v", wav.samples[2])
}

@(test)
wav_reads_fmt_after_data :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-fmtlast.wav"
	defer os.remove(path)
	payload := [4]byte{0x00, 0x40, 0x00, 0xC0} // +0.5, -0.5 as PCM16

	// RIFF + data + fmt, no fact chunk.
	buf := make([]byte, 12 + 8 + len(payload) + 8 + 16)
	defer delete(buf)
	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(len(buf) - 8))
	put_tag(buf[8:], "WAVE")
	put_tag(buf[12:], "data")
	endian.unchecked_put_u32le(buf[16:], u32(len(payload)))
	copy(buf[20:], payload[:])
	put_tag(buf[24:], "fmt ")
	endian.unchecked_put_u32le(buf[28:], 16)
	endian.unchecked_put_u16le(buf[32:], 1)
	endian.unchecked_put_u16le(buf[34:], 1)
	endian.unchecked_put_u32le(buf[36:], 48_000)
	endian.unchecked_put_u32le(buf[40:], 96_000)
	endian.unchecked_put_u16le(buf[44:], 2)
	endian.unchecked_put_u16le(buf[46:], 16)

	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "fmt-after-data rejected")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 2, "frames %d", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-6, "sample 0 %v", wav.samples[0])
	testing.expectf(t, abs(wav.samples[1] + 0.5) < 1e-6, "sample 1 %v", wav.samples[1])
}

@(test)
wav_skips_odd_sized_chunks_with_padding :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-junk.wav"
	defer os.remove(path)
	payload := [4]byte{0x00, 0x40, 0x00, 0xC0}

	buf := make([]byte, 12 + 8 + 3 + 1 + 8 + 16 + 8 + len(payload))
	defer delete(buf)
	put_tag(buf[0:], "RIFF")
	endian.unchecked_put_u32le(buf[4:], u32(len(buf) - 8))
	put_tag(buf[8:], "WAVE")
	put_tag(buf[12:], "JUNK")
	endian.unchecked_put_u32le(buf[16:], 3)
	buf[20] = 0xAA
	buf[21] = 0xBB
	buf[22] = 0xCC
	buf[23] = 0 // pad
	off := 24
	put_tag(buf[off:], "fmt ")
	endian.unchecked_put_u32le(buf[off + 4:], 16)
	endian.unchecked_put_u16le(buf[off + 8:], 1)
	endian.unchecked_put_u16le(buf[off + 10:], 1)
	endian.unchecked_put_u32le(buf[off + 12:], 48_000)
	endian.unchecked_put_u32le(buf[off + 16:], 96_000)
	endian.unchecked_put_u16le(buf[off + 20:], 2)
	endian.unchecked_put_u16le(buf[off + 22:], 16)
	off += 24
	put_tag(buf[off:], "data")
	endian.unchecked_put_u32le(buf[off + 4:], u32(len(payload)))
	copy(buf[off + 8:], payload[:])

	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "JUNK chunk broke parsing")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 2, "frames %d", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-6, "sample %v", wav.samples[0])
}

@(test)
wav_rejects_inconsistent_headers :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-badheader.wav"
	defer os.remove(path)
	payload := [4]byte{0, 0, 0, 0}

	wav_expect_reject(t, path, wav_fixture(1, 0, 48_000, 2, 16, payload[:]))
	wav_expect_reject(t, path, wav_fixture(1, 33, 48_000, 66, 16, payload[:]))
	wav_expect_reject(t, path, wav_fixture(1, 1, 0, 2, 16, payload[:]))
	wav_expect_reject(t, path, wav_fixture(1, 1, 48_000, 0, 16, payload[:]))
	wav_expect_reject(t, path, wav_fixture(2, 1, 48_000, 2, 16, payload[:]))
	// 8-bit unsigned PCM is supported now; 12-bit integer PCM is not.
	wav_expect_reject(t, path, wav_fixture(1, 1, 48_000, 2, 12, payload[:]))
	// A fmt chunk smaller than its required 16-byte body must not read into
	// the following data chunk.
	wav_expect_reject(t, path, wav_fixture(1, 1, 48_000, 2, 16, payload[:], 15))
}

@(test)
wav_truncated_data_reads_only_complete_frames :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-truncated.wav"
	defer os.remove(path)
	payload := [8]byte{0x00, 0x40, 0x00, 0xC0, 0x00, 0x20, 0x00, 0xE0}
	buf := wav_fixture(1, 1, 48_000, 2, 16, payload[:])
	// Declare far more data than the file actually contains.
	endian.unchecked_put_u32le(buf[40:], 100)
	defer delete(buf)

	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "truncated data rejected")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 4, "frames %d", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-6, "sample %v", wav.samples[0])
}

@(test)
wav_reads_padded_frames_by_block_align :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-padded.wav"
	defer os.remove(path)
	// Stereo PCM16 with one padding byte per frame (block_align = 5).
	payload := [10]byte{
		0x00, 0x40, 0x00, 0xC0, 0x00,
		0x00, 0x20, 0x00, 0xE0, 0x00,
	}
	buf := wav_fixture(1, 2, 48_000, 5, 16, payload[:])
	defer delete(buf)

	testing.expect(t, os.write_entire_file(path, buf) == nil)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "padded frames rejected")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 2, "frames %d", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-6, "0 %v", wav.samples[0])
	testing.expectf(t, abs(wav.samples[1] + 0.5) < 1e-6, "1 %v", wav.samples[1])
	testing.expectf(t, abs(wav.samples[2] - 0.25) < 1e-6, "2 %v", wav.samples[2])
	testing.expectf(t, abs(wav.samples[3] + 0.25) < 1e-6, "3 %v", wav.samples[3])
}

@(test)
wav_write_rejects_overflowing_size_fields :: proc(t: ^testing.T) {
	path := "/tmp/tracker-fx-wav-overflow.wav"
	defer os.remove(path)
	one := [1]f32{1.0}
	testing.expect(t, !wav_write(path, 0, 1, one[:]), "zero rate accepted")
	testing.expect(t, !wav_write(path, 48_000, 33, one[:]), "33 channels accepted")

	// 32 channels at an absurd rate overflows the 32-bit byte-rate field.
	wide := make([]f32, 32)
	defer delete(wide)
	testing.expect(t, !wav_write(path, 0xFFFF_FFFF, 32, wide), "byte rate overflow accepted")

	max_data := int(0xFFFF_FFFF) - (WAV_HEADER_SIZE - 8)
	testing.expect(t, wav_riff_fits(max_data), "RIFF limit boundary rejected")
	testing.expect(t, !wav_riff_fits(max_data + 1), "RIFF overflow accepted")
	testing.expect(t, !wav_riff_fits(-1), "negative data length accepted")
}
