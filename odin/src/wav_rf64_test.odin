package main

import "core:encoding/endian"
import "core:os"
import "core:testing"

// Synthetic RF64 fixtures use real ds64 fields but only a handful of payload
// bytes, so the reader's 64-bit paths are exercised without a 4 GB allocation.
Wav_Rf64_Order :: enum {
	Ds64_First,
	Fmt_First,
	Data_First,
}

@(private)
wav_f32_payload :: proc(values: []f32) -> []byte {
	buf := make([]byte, len(values) * 4)
	for v, i in values {
		endian.unchecked_put_u32le(buf[i * 4:], transmute(u32)v)
	}
	return buf
}

@(private)
wav_rf64_put_fmt :: proc(buf: []byte, off: int, channels: u16, rate: u32) {
	put_tag(buf[off:], "fmt ")
	endian.unchecked_put_u32le(buf[off + 4:], 18)
	endian.unchecked_put_u16le(buf[off + 8:], 3) // IEEE float
	endian.unchecked_put_u16le(buf[off + 10:], channels)
	endian.unchecked_put_u32le(buf[off + 12:], rate)
	endian.unchecked_put_u32le(buf[off + 16:], rate * u32(channels) * 4)
	endian.unchecked_put_u16le(buf[off + 20:], channels * 4)
	endian.unchecked_put_u16le(buf[off + 22:], 32)
	endian.unchecked_put_u16le(buf[off + 24:], 0)
}

@(private)
wav_rf64_put_ds64 :: proc(
	buf: []byte,
	off: int,
	riff_size, data_size, sample_count: u64,
	table_length: u32,
) {
	put_tag(buf[off:], "ds64")
	endian.unchecked_put_u32le(buf[off + 4:], 28)
	endian.unchecked_put_u64le(buf[off + 8:], riff_size)
	endian.unchecked_put_u64le(buf[off + 16:], data_size)
	endian.unchecked_put_u64le(buf[off + 24:], sample_count)
	endian.unchecked_put_u32le(buf[off + 32:], table_length)
}

// data_size/sample_count/riff_size overrides of 0 mean "derive from payload".
// The data chunk always carries the 0xFFFFFFFF sentinel, as a real RF64 does.
@(private)
wav_rf64_fixture :: proc(
	payload: []byte,
	channels: u16 = 1,
	rate: u32 = 48_000,
	order: Wav_Rf64_Order = .Ds64_First,
	data_size: u64 = 0,
	sample_count: u64 = 0,
	riff_size: u64 = 0,
	table_length: u32 = 0,
) -> []byte {
	frame_bytes := u64(channels) * 4
	frames := u64(len(payload)) / frame_bytes
	data_len := data_size
	if data_len == 0 {
		data_len = u64(len(payload))
	}
	samples := sample_count
	if samples == 0 {
		samples = frames
	}
	total := 82 + len(payload)
	riff := riff_size
	if riff == 0 {
		riff = u64(total - 8)
	}

	buf := make([]byte, total)
	put_tag(buf[0:], "RF64")
	endian.unchecked_put_u32le(buf[4:], 0xFFFF_FFFF)
	put_tag(buf[8:], "WAVE")

	ds64_off: int
	fmt_off: int
	data_off: int
	switch order {
	case .Ds64_First:
		ds64_off, fmt_off, data_off = 12, 48, 74
	case .Fmt_First:
		fmt_off, ds64_off, data_off = 12, 38, 74
	case .Data_First:
		data_off = 12
		ds64_off = data_off + 8 + len(payload)
		fmt_off = ds64_off + 36
	}

	wav_rf64_put_ds64(buf, ds64_off, riff, data_len, samples, table_length)
	wav_rf64_put_fmt(buf, fmt_off, channels, rate)
	put_tag(buf[data_off:], "data")
	endian.unchecked_put_u32le(buf[data_off + 4:], 0xFFFF_FFFF)
	copy(buf[data_off + 8:], payload)
	return buf
}

@(private)
wav_rf64_write_fixture :: proc(t: ^testing.T, path: string, buf: []byte) {
	testing.expect(t, os.write_entire_file(path, buf) == nil, "fixture write")
}

@(test)
wav_reads_rf64_with_ds64_first :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64.wav"
	defer os.remove(path)

	values := [8]f32{0.5, -0.5, 0.25, -0.25, 0.125, -0.125, 1.0, -1.0}
	payload := wav_f32_payload(values[:])
	defer delete(payload)
	buf := wav_rf64_fixture(payload, 2, 48_000)
	defer delete(buf)

	ds64, ds_ok := rf64_ds64_at(buf, 12)
	testing.expect(t, ds_ok, "ds64 not parsed")
	testing.expectf(t, ds64.riff_size == u64(len(buf) - 8), "riff size %d", ds64.riff_size)
	testing.expectf(t, ds64.data_size == u64(len(payload)), "data size %d", ds64.data_size)
	testing.expectf(t, ds64.sample_count == 4, "sample count %d", ds64.sample_count)

	wav_rf64_write_fixture(t, path, buf)
	wav, ok := wav_read(path)
	testing.expect(t, ok, "RF64 read failed")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.sample_rate == 48_000, "rate %v", wav.sample_rate)
	testing.expectf(t, wav.channels == 2, "channels %v", wav.channels)
	testing.expectf(t, wav.frames == 4, "frames %v", wav.frames)
	for v, i in values {
		testing.expectf(t, abs(wav.samples[i] - v) < 1e-7, "sample %d: %v vs %v", i, wav.samples[i], v)
	}
}

@(test)
wav_reads_rf64_with_fmt_before_ds64 :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64-fmtfirst.wav"
	defer os.remove(path)

	payload := wav_f32_payload([]f32{0.5, -0.5})
	defer delete(payload)
	buf := wav_rf64_fixture(payload, 1, 44_100, .Fmt_First)
	defer delete(buf)
	wav_rf64_write_fixture(t, path, buf)

	wav, ok := wav_read(path)
	testing.expect(t, ok, "fmt-before-ds64 rejected")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 2, "frames %v", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-7, "sample 0")
	testing.expectf(t, abs(wav.samples[1] + 0.5) < 1e-7, "sample 1")
}

@(test)
wav_reads_rf64_with_data_before_ds64 :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64-datafirst.wav"
	defer os.remove(path)

	payload := wav_f32_payload([]f32{0.25, -0.25, 0.75, -0.75})
	defer delete(payload)
	buf := wav_rf64_fixture(payload, 2, 48_000, .Data_First)
	defer delete(buf)
	wav_rf64_write_fixture(t, path, buf)

	wav, ok := wav_read(path)
	testing.expect(t, ok, "data-before-ds64 rejected")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 2, "frames %v", wav.frames)
	testing.expectf(t, abs(wav.samples[2] - 0.75) < 1e-7, "sample 2 %v", wav.samples[2])
}

@(test)
wav_rf64_parses_real_64_bit_sizes_without_allocating :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64-huge.wav"
	defer os.remove(path)

	payload := wav_f32_payload([]f32{0.5})
	defer delete(payload)
	huge_data := u64(0x1_0000_0000) + u64(len(payload))
	huge_frames := u64(0x4000_0001)
	buf := wav_rf64_fixture(
		payload,
		1,
		48_000,
		.Ds64_First,
		data_size = huge_data,
		sample_count = huge_frames,
		riff_size = huge_data + 4096,
	)
	defer delete(buf)

	ds64, ok := rf64_ds64_at(buf, 12)
	testing.expect(t, ok, "64-bit ds64 rejected")
	testing.expectf(t, ds64.data_size == huge_data, "data size %v", ds64.data_size)
	testing.expectf(t, ds64.sample_count == huge_frames, "sample count %v", ds64.sample_count)
	testing.expectf(t, ds64.riff_size == huge_data + 4096, "riff size %v", ds64.riff_size)

	wav_rf64_write_fixture(t, path, buf)
	wav, read_ok := wav_read(path)
	testing.expect(t, read_ok, "truncated huge RF64 rejected")
	if !read_ok {
		return
	}
	defer wav_destroy(&wav)
	// Only the bytes actually present are decoded; the 64-bit declaration must
	// not drive a 4 GB allocation.
	testing.expectf(t, wav.frames == 1, "frames %v", wav.frames)
	testing.expectf(t, abs(wav.samples[0] - 0.5) < 1e-7, "sample %v", wav.samples[0])
}

@(test)
wav_rejects_malformed_rf64_ds64 :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64-bad.wav"
	defer os.remove(path)

	payload := wav_f32_payload([]f32{0.5, -0.5})
	defer delete(payload)
	base := wav_rf64_fixture(payload, 1)
	defer delete(base)

	short := make([]byte, len(base))
	copy(short, base)
	endian.unchecked_put_u32le(short[16:], 20) // ds64 smaller than 28 bytes
	wav_expect_reject(t, path, short)

	truncated := make([]byte, len(base))
	copy(truncated, base)
	endian.unchecked_put_u32le(truncated[16:], u32(len(base))) // runs past EOF
	wav_expect_reject(t, path, truncated)

	table := make([]byte, len(base))
	copy(table, base)
	endian.unchecked_put_u32le(table[44:], 1) // unsupported table override
	wav_expect_reject(t, path, table)

	missing := make([]byte, len(base))
	copy(missing, base)
	put_tag(missing[12:], "JUNK") // RF64 without a ds64 chunk
	wav_expect_reject(t, path, missing)

	wav_expect_reject(t, path, wav_rf64_fixture(
		payload,
		1,
		48_000,
		.Ds64_First,
		data_size = 1000,
		sample_count = 2,
		riff_size = 100,
	))
}

@(test)
wav_plan_selects_rf64_past_32_bit_sizes :: proc(t: ^testing.T) {
	// Mono float: largest frame count whose 58-byte RIFF header still fits.
	frames := (u64(0xFFFF_FFFF) - u64(WAV_HEADER_SIZE - 8)) / 4
	plan, ok := wav_plan(48_000, 1, frames)
	testing.expect(t, ok, "normal plan rejected")
	testing.expect(t, plan.container == .Riff, "boundary file not RIFF")
	testing.expectf(t, plan.header_size == WAV_HEADER_SIZE, "header %d", plan.header_size)
	testing.expectf(t, plan.riff_size == u64(WAV_HEADER_SIZE - 8) + frames * 4, "riff size")

	plan, ok = wav_plan(48_000, 1, frames + 1)
	testing.expect(t, ok, "RF64 plan rejected")
	testing.expect(t, plan.container == .Rf64, "overflowing file not RF64")
	testing.expectf(t, plan.header_size == WAV_RF64_HEADER_SIZE, "header %d", plan.header_size)
	testing.expectf(t, plan.data_len == (frames + 1) * 4, "data len %d", plan.data_len)
	testing.expectf(
		t,
		plan.riff_size == u64(WAV_RF64_HEADER_SIZE - 8) + plan.data_len,
		"rf64 riff size %d",
		plan.riff_size,
	)

	// 24 GB of stereo float audio: arithmetic only, no allocation.
	HUGE_FRAMES :: u64(3_000_000_000)
	plan, ok = wav_plan(48_000, 2, HUGE_FRAMES)
	testing.expect(t, ok, "huge plan rejected")
	testing.expect(t, plan.container == .Rf64, "huge file not RF64")
	testing.expectf(t, plan.data_len == HUGE_FRAMES * 8, "huge data len %d", plan.data_len)
	testing.expectf(
		t,
		plan.riff_size == u64(WAV_RF64_HEADER_SIZE - 8) + HUGE_FRAMES * 8,
		"huge riff size %d",
		plan.riff_size,
	)

	_, ok = wav_plan(48_000, 2, max(u64))
	testing.expect(t, !ok, "overflowing frame count accepted")
	_, ok = wav_plan(0, 2, 1)
	testing.expect(t, !ok, "zero rate accepted")
	_, ok = wav_plan(48_000, 33, 1)
	testing.expect(t, !ok, "33 channels accepted")
	_, ok = wav_plan(0xFFFF_FFFF, 32, 1)
	testing.expect(t, !ok, "byte-rate overflow accepted")
}

@(test)
wav_rf64_header_encodes_64_bit_sizes :: proc(t: ^testing.T) {
	FRAMES :: u64(0x1_0000_0001)
	DATA_LEN :: FRAMES * 8
	header: [WAV_RF64_HEADER_SIZE]byte
	testing.expect(t, wav_rf64_put_header(header[:], 48_000, 2, FRAMES, DATA_LEN), "header rejected")
	testing.expect(t, tag_eq(header[0:], "RF64"), "missing RF64")
	testing.expectf(t, endian.unchecked_get_u32le(header[4:]) == 0xFFFF_FFFF, "riff sentinel")
	testing.expect(t, tag_eq(header[12:], "ds64"), "missing ds64")
	testing.expectf(t, endian.unchecked_get_u32le(header[16:]) == 28, "ds64 size")
	testing.expectf(t, endian.unchecked_get_u64le(header[20:]) == u64(WAV_RF64_HEADER_SIZE - 8) + DATA_LEN, "ds64 riff")
	testing.expectf(t, endian.unchecked_get_u64le(header[28:]) == DATA_LEN, "ds64 data")
	testing.expectf(t, endian.unchecked_get_u64le(header[36:]) == FRAMES, "ds64 samples")
	testing.expectf(t, endian.unchecked_get_u32le(header[44:]) == 0, "ds64 table")
	testing.expect(t, tag_eq(header[48:], "fmt "), "missing fmt")
	testing.expect(t, tag_eq(header[74:], "fact"), "missing fact")
	testing.expectf(t, endian.unchecked_get_u32le(header[82:]) == 0xFFFF_FFFF, "fact sentinel")
	testing.expect(t, tag_eq(header[86:], "data"), "missing data")
	testing.expectf(t, endian.unchecked_get_u32le(header[90:]) == 0xFFFF_FFFF, "data sentinel")

	// Mismatched 64-bit sizes must not produce a header that lies.
	testing.expect(t, !wav_rf64_put_header(header[:], 48_000, 2, FRAMES, DATA_LEN + 8), "mismatched sizes accepted")
}

@(test)
wav_rf64_in_memory_write_roundtrip :: proc(t: ^testing.T) {
	path := WAV_TMP + "-rf64-write.wav"
	defer os.remove(path)

	values := [6]f32{0.5, -0.5, 0.25, -0.25, 0.75, -0.75}
	testing.expect(t, wav_write_rf64(path, 48_000, 2, values[:]), "RF64 write failed")
	wav, ok := wav_read(path)
	testing.expect(t, ok, "RF64 roundtrip read failed")
	if !ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.frames == 3, "frames %v", wav.frames)
	for v, i in values {
		testing.expectf(t, abs(wav.samples[i] - v) < 1e-7, "sample %d", i)
	}
}

@(test)
wav_stream_writer_roundtrip :: proc(t: ^testing.T) {
	path := WAV_TMP + "-stream-rf64.wav"
	defer os.remove(path)

	RATE :: 44_100
	CHANNELS :: 2
	frames := 200
	buf := make([]f32, frames * CHANNELS)
	defer delete(buf)
	for i in 0 ..< frames {
		buf[i * 2 + 0] = f32(i) / f32(frames)
		buf[i * 2 + 1] = -f32(i) / f32(frames)
	}

	stream, ok := wav_stream_open(path, RATE, CHANNELS)
	testing.expect(t, ok, "stream open failed")
	if !ok {
		return
	}
	split := 100 * CHANNELS
	testing.expect(t, wav_stream_write(&stream, buf[:split]), "first stream write failed")
	testing.expect(t, wav_stream_write(&stream, buf[split:]), "second stream write failed")
	testing.expect(t, wav_stream_close(&stream), "stream close failed")

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, "stream file unreadable")
	testing.expectf(t, len(data) == WAV_RF64_HEADER_SIZE + len(buf) * 4, "file size %d", len(data))
	testing.expect(t, tag_eq(data[0:], "RF64"), "missing RF64")
	testing.expectf(t, endian.unchecked_get_u32le(data[4:]) == 0xFFFF_FFFF, "riff sentinel")
	testing.expect(t, tag_eq(data[12:], "ds64"), "missing ds64")
	testing.expectf(t, endian.unchecked_get_u64le(data[20:]) == u64(len(data) - 8), "ds64 riff size")
	testing.expectf(t, endian.unchecked_get_u64le(data[28:]) == u64(len(buf) * 4), "ds64 data size")
	testing.expectf(t, endian.unchecked_get_u64le(data[36:]) == u64(frames), "ds64 samples")
	testing.expectf(t, endian.unchecked_get_u32le(data[44:]) == 0, "ds64 table")
	testing.expectf(t, endian.unchecked_get_u32le(data[82:]) == 0xFFFF_FFFF, "fact sentinel")
	testing.expectf(t, endian.unchecked_get_u32le(data[90:]) == 0xFFFF_FFFF, "data sentinel")

	wav, read_ok := wav_read(path)
	testing.expect(t, read_ok, "stream roundtrip read failed")
	if !read_ok {
		return
	}
	defer wav_destroy(&wav)
	testing.expectf(t, wav.sample_rate == RATE, "rate %v", wav.sample_rate)
	testing.expectf(t, wav.channels == CHANNELS, "channels %v", wav.channels)
	testing.expectf(t, wav.frames == frames, "frames %v", wav.frames)
	for i in 0 ..< len(buf) {
		testing.expectf(t, abs(wav.samples[i] - buf[i]) < 1e-7, "sample %d", i)
	}
}

@(test)
wav_stream_writer_rejects_bad_shapes :: proc(t: ^testing.T) {
	path := WAV_TMP + "-stream-bad.wav"
	defer os.remove(path)

	_, ok := wav_stream_open(path, 48_000, 0)
	testing.expect(t, !ok, "zero channels accepted")
	_, ok = wav_stream_open(path, 48_000, 33)
	testing.expect(t, !ok, "33 channels accepted")
	_, ok = wav_stream_open(path, 0, 1)
	testing.expect(t, !ok, "zero rate accepted")

	stream, opened := wav_stream_open(path, 48_000, 2)
	testing.expect(t, opened, "stream open failed")
	if !opened {
		return
	}
	odd := [3]f32{0, 0, 0}
	testing.expect(t, !wav_stream_write(&stream, odd[:]), "partial frame accepted")
	frame := [2]f32{0.5, -0.5}
	testing.expect(t, wav_stream_write(&stream, frame[:]), "valid write after shape error failed")
	testing.expect(t, wav_stream_close(&stream), "close failed")
	testing.expect(t, !wav_stream_write(&stream, frame[:]), "write after close accepted")
	testing.expect(t, !wav_stream_close(&stream), "double close accepted")
}

@(test)
wav_small_write_stays_riff :: proc(t: ^testing.T) {
	path := WAV_TMP + "-small-riff.wav"
	defer os.remove(path)
	one := [1]f32{0.5}
	testing.expect(t, wav_write(path, 48_000, 1, one[:]), "write failed")

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, "file unreadable")
	testing.expectf(t, len(data) == WAV_HEADER_SIZE + 4, "file size %d", len(data))
	testing.expect(t, tag_eq(data[0:], "RIFF"), "small file not RIFF")
	testing.expect(t, !tag_eq(data[12:], "ds64"), "small file grew a ds64")
	testing.expectf(t, endian.unchecked_get_u32le(data[4:]) == u32(len(data) - 8), "riff size")
	testing.expectf(t, endian.unchecked_get_u32le(data[54:]) == 4, "data size")
}
