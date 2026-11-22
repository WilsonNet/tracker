package main

import "core:testing"

@(test)
render_slice_bounds_clamps_ranges :: proc(t: ^testing.T) {
	RATE :: u32(48_000)
	total := int(RATE) * 3

	first, last, ok := render_slice_bounds(total, RATE, 0, 0)
	testing.expect(t, ok && first == 0 && last == total, "end marker is the full mix")

	first, last, ok = render_slice_bounds(total, RATE, 1.0, 2.0)
	testing.expect(t, ok && first == int(RATE) && last == int(RATE) * 2, "one-second range")

	first, last, ok = render_slice_bounds(total, RATE, -2.0, 99.0)
	testing.expect(t, ok && first == 0 && last == total, "out-of-range clamps")

	_, _, ok = render_slice_bounds(total, RATE, 2.0, 2.0)
	testing.expect(t, !ok, "empty range is rejected")
	_, _, ok = render_slice_bounds(total, RATE, 2.5, 1.0)
	testing.expect(t, !ok, "backwards range is rejected")
	_, _, ok = render_slice_bounds(0, RATE, 0, 1)
	testing.expect(t, !ok, "empty mix is rejected")
}
