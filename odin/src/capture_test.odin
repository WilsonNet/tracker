// Tests for the capture channel-routing helpers (pure logic, no hardware).
//
// Regression: miniaudio's PulseAudio backend asked for a speaker channel map,
// so PipeWire remixed a 6-input Scarlett 4i4 ("Analog Surround 5.1",
// FL FR RL RR FC LFE): a 2-channel take folded inputs 3-6 into tracks 1/2 and
// a 6-channel take came back reordered (input 1 leaked into track 5). Capture
// now opens at native width with an AUX map and keeps inputs 1..N in order.

package main

import "core:testing"

@(test)
capture_open_attempts_native_first :: proc(t: ^testing.T) {
	attempts, n := capture_open_attempts(2)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, attempts[0], 0) // native width
	testing.expect_value(t, attempts[1], 2)
	testing.expect_value(t, attempts[2], 1)

	attempts, n = capture_open_attempts(6)
	testing.expect_value(t, n, 5)
	want := [5]int{0, 6, 4, 2, 1}
	for w, i in want {
		testing.expectf(t, attempts[i] == w, "attempt %d = %d, want %d", i, attempts[i], w)
	}

	// No duplicates, never wider than requested.
	attempts, n = capture_open_attempts(16)
	testing.expect_value(t, n, 6)
	for i in 1 ..< n {
		testing.expect(t, attempts[i] <= 16 && attempts[i] > 0)
		for j in 0 ..< i {
			testing.expect(t, attempts[i] != attempts[j])
		}
	}

	attempts, n = capture_open_attempts(1)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, attempts[0], 0)
	testing.expect_value(t, attempts[1], 1)
}

@(test)
capture_pulse_map_is_aux_only_where_passthrough :: proc(t: ^testing.T) {
	testing.expect_value(t, capture_pulse_channel_map(0), PULSE_CHANNEL_MAP_AUX)
	testing.expect_value(t, capture_pulse_channel_map(1), PULSE_CHANNEL_MAP_AUX)
	testing.expect_value(t, capture_pulse_channel_map(2), PULSE_CHANNEL_MAP_AUX)
	// Explicit >2 widths would hit AUX-vs-speaker silence inside miniaudio.
	testing.expect_value(t, capture_pulse_channel_map(4), i32(0))
}

@(test)
capture_copy_frames_keeps_first_inputs_in_order :: proc(t: ^testing.T) {
	// 3 frames of a 6-channel device; sample = frame*10 + input.
	src: [18]f32
	for f in 0 ..< 3 {
		for c in 0 ..< 6 {
			src[f * 6 + c] = f32(f * 10 + c + 1)
		}
	}
	dst: [6]f32
	capture_copy_frames(dst[:], &src[0], 3, 6, 2)
	want := [6]f32{1, 2, 11, 12, 21, 22}
	for w, i in want {
		testing.expectf(t, dst[i] == w, "dst[%d] = %v, want %v", i, dst[i], w)
	}

	// Same width (or unknown source width) is a straight copy.
	same: [18]f32
	capture_copy_frames(same[:], &src[0], 3, 6, 6)
	testing.expect(t, same == src)
	zero_src: [18]f32
	capture_copy_frames(zero_src[:], &src[0], 3, 0, 6)
	testing.expect(t, zero_src == src)

	// Never writes past the destination.
	small: [3]f32
	capture_copy_frames(small[:], &src[0], 3, 6, 2)
	testing.expect_value(t, small[0], f32(1))
	testing.expect_value(t, small[1], f32(2))
	testing.expect_value(t, small[2], f32(0))
}

@(test)
jack_ports_for_device_filters_by_client :: proc(t: ^testing.T) {
	ports := []string {
		"MX Brio Analog Stereo:capture_FL",
		"MX Brio Analog Stereo:capture_FR",
		"Scarlett 4i4 USB Analog Surround 5.1:capture_FL",
		"Scarlett 4i4 USB Analog Surround 5.1:capture_FR",
		"Scarlett 4i4 USB Analog Surround 5.1:capture_RL",
		"Scarlett 4i4 USB:capture_FL", // prefix of the name, different client
		"no-colon",
	}
	got := jack_ports_for_device(ports, "Scarlett 4i4 USB Analog Surround 5.1")
	defer delete(got)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0], "Scarlett 4i4 USB Analog Surround 5.1:capture_FL")
		testing.expect_value(t, got[1], "Scarlett 4i4 USB Analog Surround 5.1:capture_FR")
		testing.expect_value(t, got[2], "Scarlett 4i4 USB Analog Surround 5.1:capture_RL")
	}

	testing.expect(t, jack_ports_for_device(ports, "") == nil)
	testing.expect(t, jack_ports_for_device(ports, "Monitor of Scarlett") == nil)
	testing.expect(t, jack_ports_for_device(nil, "Scarlett") == nil)

	testing.expect_value(t, jack_port_client("a:b:c"), "a")
	testing.expect_value(t, jack_port_client("no-colon"), "")
}
