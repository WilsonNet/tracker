// Live input monitoring for the duplex capture path.
//
// Monitoring is deliberately feedback-safe: it is off by default, only runs
// while a take is recording through a duplex miniaudio device, and applies a
// fixed low gain. The mix routine is pure and allocation-free so it can run in
// the real-time callback.

package main

import "core:sync"

MAX_MONITOR_SOURCES :: MAX_ENGINE_TRACKS
MONITOR_SAFE_GAIN :: f32(0.5) // -6 dB: audible without an easy feedback loop

Monitor :: struct {
	// Read by the real-time callback; written by UI-thread start/stop helpers.
	on:           u32,
	gain:         f32,
	// Zero-based capture channel indices, de-duplicated in selection order.
	sources:      [MAX_MONITOR_SOURCES]int,
	source_count: int,
}

monitor_init :: proc(m: ^Monitor) {
	m^ = Monitor{}
	m.gain = MONITOR_SAFE_GAIN
}

monitor_set_enabled :: proc(m: ^Monitor, enabled: bool) {
	if m == nil {
		return
	}
	sync_atomic_store_bool(&m.on, enabled)
}

monitor_is_enabled :: proc(m: ^Monitor) -> bool {
	if m == nil {
		return false
	}
	return sync_atomic_load_bool(&m.on)
}

// Small wrappers keep the atomic type in one place. `core:sync` takes ^u32.
@(private)
sync_atomic_store_bool :: proc "contextless" (p: ^u32, v: bool) {
	sync.atomic_store(p, u32(1) if v else u32(0))
}

@(private)
sync_atomic_load_bool :: proc "contextless" (p: ^u32) -> bool {
	return sync.atomic_load(p) != 0
}

// snapshots the armed tracks' input channels. Inputs are 1-based in the UI;
// `in_channels` is the channel count the device actually opened. Out-of-range
// inputs wrap exactly like the recorded take, so monitoring matches the WAV.
monitor_snapshot_sources :: proc(m: ^Monitor, armed: []bool, inputs: []int, in_channels: int) {
	if m == nil {
		return
	}
	m.source_count = 0
	if in_channels <= 0 {
		return
	}
	for i in 0 ..< min(min(len(armed), len(inputs)), MAX_MONITOR_SOURCES) {
		if !armed[i] {
			continue
		}
		ch := recorder_input_channel(inputs[i], in_channels)
		if ch < 0 {
			continue
		}
		duplicate := false
		for s in 0 ..< m.source_count {
			if m.sources[s] == ch {
				duplicate = true
				break
			}
		}
		if duplicate || m.source_count >= MAX_MONITOR_SOURCES {
			continue
		}
		m.sources[m.source_count] = ch
		m.source_count += 1
	}
}

// monitor_mix renders selected capture channels into a device output buffer.
// Pure, bounded and allocation-free: this is the body of the duplex callback.
//
// One selected source is centred (both output channels), two or more alternate
// left/right. A mono output gets the average of the selected sources. When
// monitoring is off the buffer is explicitly silenced rather than left stale.
monitor_mix :: proc "contextless" (
	m: ^Monitor,
	src, dst: []f32,
	frames, in_channels, out_channels: int,
) {
	if len(dst) == 0 || frames <= 0 || out_channels <= 0 {
		return
	}
	limit := min(len(dst), frames * out_channels)
	// Silence first. A disabled or shorter-than-expected input must never
	// leave the previous callback's samples in the output buffer.
	for i in 0 ..< limit {
		dst[i] = 0
	}
	if m == nil || !sync_atomic_load_bool(&m.on) || m.source_count <= 0 || in_channels <= 0 {
		return
	}
	count := min(m.source_count, MAX_MONITOR_SOURCES)
	gain := m.gain
	if gain <= 0 {
		gain = MONITOR_SAFE_GAIN
	}
	input_frames := len(src) / in_channels

	for f in 0 ..< frames {
		if f >= input_frames {
			break
		}
		if out_channels == 1 {
			sum: f32 = 0
			for s in 0 ..< count {
				ch := m.sources[s]
				if ch >= 0 && ch < in_channels {
					sum += src[f * in_channels + ch]
				}
			}
			idx := f
			if idx < len(dst) {
				dst[idx] = sum / f32(count) * gain
			}
			continue
		}
		for c in 0 ..< out_channels {
			ch := m.sources[0] if count == 1 else m.sources[c % count]
			idx := f * out_channels + c
			if idx >= len(dst) || ch < 0 || ch >= in_channels {
				continue
			}
			dst[idx] = src[f * in_channels + ch] * gain
		}
	}
}
