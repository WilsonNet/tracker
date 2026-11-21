package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"

// Builds a canonical 44-byte-header WAV image around `payload`.
@(private = "file")
wav_image :: proc(container: string, format, channels, bits: u16, rate: u32, payload: []byte) -> []byte {
	block := channels * (bits / 8)
	rf64 := container != "RIFF"
	header := 44 + (36 if rf64 else 0)
	buf := make([]byte, header + len(payload))
	put_tag(buf[0:], container)
	put_tag(buf[8:], "WAVE")
	off := 12
	if rf64 {
		endian.unchecked_put_u32le(buf[4:], 0xFFFF_FFFF)
		put_tag(buf[off:], "ds64")
		endian.unchecked_put_u32le(buf[off + 4:], 28)
		endian.unchecked_put_u64le(buf[off + 8:], u64(len(buf) - 8))
		endian.unchecked_put_u64le(buf[off + 16:], u64(len(payload)))
		endian.unchecked_put_u64le(buf[off + 24:], u64(len(payload) / int(block)))
		off += 36
	} else {
		endian.unchecked_put_u32le(buf[4:], u32(len(buf) - 8))
	}
	put_tag(buf[off:], "fmt ")
	endian.unchecked_put_u32le(buf[off + 4:], 16)
	endian.unchecked_put_u16le(buf[off + 8:], format)
	endian.unchecked_put_u16le(buf[off + 10:], channels)
	endian.unchecked_put_u32le(buf[off + 12:], rate)
	endian.unchecked_put_u32le(buf[off + 16:], rate * u32(block))
	endian.unchecked_put_u16le(buf[off + 20:], block)
	endian.unchecked_put_u16le(buf[off + 22:], bits)
	off += 24
	put_tag(buf[off:], "data")
	endian.unchecked_put_u32le(buf[off + 4:], 0xFFFF_FFFF if rf64 else u32(len(payload)))
	copy(buf[off + 8:], payload)
	return buf
}

@(test)
wav_reads_8_bit_unsigned_pcm :: proc(t: ^testing.T) {
	payload := [4]byte{128, 192, 64, 0}
	img := wav_image("RIFF", 1, 1, 8, 8_000, payload[:])
	defer delete(img)
	wav, ok := wav_parse(img)
	defer wav_destroy(&wav)
	testing.expect(t, ok, "8-bit PCM rejected")
	testing.expectf(t, wav.frames == 4, "frames %d", wav.frames)
	if ok {
		testing.expectf(t, wav.samples[0] == 0, "midpoint %v", wav.samples[0])
		testing.expectf(t, abs(wav.samples[1] - 0.5) < 1e-6, "0.5 %v", wav.samples[1])
		testing.expectf(t, abs(wav.samples[2] + 0.5) < 1e-6, "-0.5 %v", wav.samples[2])
		testing.expectf(t, wav.samples[3] == -1, "-1 %v", wav.samples[3])
	}
}

@(test)
wav_reads_64_bit_float :: proc(t: ^testing.T) {
	payload: [32]byte
	values := [4]f64{0, 0.25, -0.75, 1}
	for v, i in values {
		endian.unchecked_put_u64le(payload[i * 8:], transmute(u64)v)
	}
	img := wav_image("RIFF", 3, 2, 64, 44_100, payload[:])
	defer delete(img)
	wav, ok := wav_parse(img)
	defer wav_destroy(&wav)
	testing.expect(t, ok, "float64 rejected")
	testing.expectf(t, wav.frames == 2 && wav.channels == 2, "shape %d x %d", wav.frames, wav.channels)
	if ok {
		for v, i in values {
			testing.expectf(t, wav.samples[i] == f32(v), "sample %d %v", i, wav.samples[i])
		}
	}
}

@(test)
wav_reads_bw64_like_rf64 :: proc(t: ^testing.T) {
	payload: [8]byte
	endian.unchecked_put_u32le(payload[0:], transmute(u32)f32(0.5))
	endian.unchecked_put_u32le(payload[4:], transmute(u32)f32(-0.5))
	for tag in ([]string{"RF64", "BW64"}) {
		img := wav_image(tag, 3, 1, 32, 48_000, payload[:])
		defer delete(img)
		wav, ok := wav_parse(img)
		defer wav_destroy(&wav)
		testing.expectf(t, ok, "%s rejected", tag)
		testing.expectf(t, wav.frames == 2, "%s frames %d", tag, wav.frames)
	}
	img := wav_image("XX64", 3, 1, 32, 48_000, payload[:])
	defer delete(img)
	_, ok := wav_parse(img)
	testing.expect(t, !ok, "unknown container accepted")
}

@(test)
cli_validate_numbers_rejects_garbage :: proc(t: ^testing.T) {
	floats := []string{"--seconds"}
	ints := []string{"--rate"}
	testing.expect(t, validate_numbers([]string{"--seconds", "1.5", "--rate=44100"}, floats, ints), "valid numbers rejected")
	testing.expect(t, validate_numbers([]string{"--other", "x"}, floats, ints), "absent options must pass")
	testing.expect(t, !validate_numbers([]string{"--seconds", "abc"}, floats, ints), "non-numeric float accepted")
	testing.expect(t, !validate_numbers([]string{"--seconds=nan"}, floats, ints), "NaN accepted")
	testing.expect(t, !validate_numbers([]string{"--seconds", "inf"}, floats, ints), "Inf accepted")
	testing.expect(t, !validate_numbers([]string{"--rate", "2.5"}, floats, ints), "fractional int accepted")
	testing.expect(t, !validate_numbers([]string{"--rate", "48k"}, floats, ints), "suffixed int accepted")
	testing.expect(t, validate_numbers([]string{"--seconds", "-1"}, floats, ints), "negative is a range error, not a parse error")
}

@(test)
cli_window_size_matches_layout_minimum :: proc(t: ^testing.T) {
	testing.expect(t, cli_window_size_ok(MIN_CLI_WIDTH, MIN_CLI_HEIGHT), "layout minimum rejected")
	testing.expect(t, cli_window_size_ok(1180, 760), "default rejected")
	testing.expect(t, !cli_window_size_ok(600, 600), "clipped 600x600 frame accepted")
	testing.expect(t, !cli_window_size_ok(MIN_CLI_WIDTH - 1, 760), "narrow frame accepted")
	testing.expect(t, !cli_window_size_ok(1180, MIN_CLI_HEIGHT - 1), "short frame accepted")
	testing.expect(t, !cli_window_size_ok(MAX_CLI_DIM + 1, 760), "huge frame accepted")
}

@(test)
recent_save_creates_its_own_parent :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/tracker-recent-parent-%d", os.get_pid())
	os.remove_all(base)
	defer os.remove_all(base)
	path := fmt.tprintf("%s/nested/dir/recent.json", base)
	projects := []string{"/tmp/a.json"}
	testing.expect(t, recent_save(path, projects), "save into a fresh nested directory")
	loaded := recent_load(path)
	defer recent_free(loaded)
	testing.expect(t, len(loaded) == 1 && loaded[0] == "/tmp/a.json", "round trip")
}

@(test)
comp_take_lengths_report_project_frames :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/tracker-comp-lengths-%d", os.get_pid())
	os.remove_all(base)
	defer os.remove_all(base)
	testing.expect(t, ensure_dir(base), "fixture dir")
	samples := make([]f32, 44_100)
	defer delete(samples)
	testing.expect(t, wav_write(fmt.tprintf("%s/track1-take1.wav", base), 48_000, 1, samples[:48_00]), "take 1")
	testing.expect(t, wav_write(fmt.tprintf("%s/track1-take2.wav", base), 44_100, 1, samples), "take 2")

	list: Take_List
	defer take_list_destroy(&list)
	_ = take_list_add(&list, "a", "track1-take1.wav", 0, 0, 1, false, 1)
	_ = take_list_add(&list, "b", "track1-take2.wav", 0, 0, 1, false, 2)
	_ = take_list_add(&list, "c", "missing.wav", 0, 0, 1, false, 3)
	lengths := comp_take_lengths(base, &list, 48_000)
	defer delete(lengths)
	testing.expectf(t, len(lengths) == 3, "lengths %d", len(lengths))
	testing.expectf(t, lengths[0].frames == 4_800, "native-rate take %d", lengths[0].frames)
	testing.expectf(t, lengths[1].frames == 48_000, "1 s at 44.1 kHz is 48000 project frames, got %d", lengths[1].frames)
	testing.expectf(t, lengths[2].frames == 0, "missing take %d", lengths[2].frames)

	// A region past the end of its take must fail validation.
	testing.expect(t, comp_add_region(&list, 1, 0, 4_800), "fitting region")
	ok, _ := comp_validate(&list, lengths)
	testing.expect(t, ok, "fitting region rejected")
	testing.expect(t, comp_add_region(&list, 2, 4_800, 60_000), "region insert")
	ok, _ = comp_validate(&list, lengths)
	testing.expect(t, !ok, "overlong region accepted")
}
