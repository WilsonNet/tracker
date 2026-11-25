package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

import ma "vendor:miniaudio"
import ui "ui"

// ---------------------------------------------------------------- monitoring

@(test)
monitor_snapshot_dedupes_and_wraps_armed_inputs :: proc(t: ^testing.T) {
	m: Monitor
	armed := [4]bool{true, true, false, true}
	inputs := [4]int{1, 2, 2, 3}
	monitor_snapshot_sources(&m, armed[:], inputs[:], 2)
	testing.expectf(t, m.source_count == 2, "sources %d", m.source_count)
	testing.expectf(t, m.sources[0] == 0 && m.sources[1] == 1, "sources %v", m.sources[:2])

	// Input 3 wraps to channel 0 on a stereo device, so it is a duplicate.
	monitor_snapshot_sources(&m, armed[:], inputs[:], 1)
	testing.expectf(t, m.source_count == 1 && m.sources[0] == 0, "mono wrap %v", m.sources[:m.source_count])

	monitor_snapshot_sources(&m, armed[:], inputs[:], 0)
	testing.expectf(t, m.source_count == 0, "invalid channels kept sources")
}

@(test)
monitor_mix_is_safe_and_maps_selected_channels :: proc(t: ^testing.T) {
	m: Monitor
	monitor_init(&m)
	m.sources[0] = 0
	m.sources[1] = 1
	m.source_count = 2
	monitor_set_enabled(&m, true)

	src := [4]f32{0.2, -0.4, 0.6, 0.8}
	dst := [4]f32{-9, -9, -9, -9}
	monitor_mix(&m, src[:], dst[:], 2, 2, 2)
	testing.expectf(t, abs(dst[0] - 0.1) < 1e-6, "L0 %v", dst[0])
	testing.expectf(t, abs(dst[1] + 0.2) < 1e-6, "R0 %v", dst[1])
	testing.expectf(t, abs(dst[2] - 0.3) < 1e-6, "L1 %v", dst[2])
	testing.expectf(t, abs(dst[3] - 0.4) < 1e-6, "R1 %v", dst[3])

	// Mono output averages the selected channels instead of dropping one.
	mono := [2]f32{-9, -9}
	monitor_mix(&m, src[:], mono[:], 2, 2, 1)
	testing.expectf(t, abs(mono[0] + 0.05) < 1e-6, "mono0 %v", mono[0])
	testing.expectf(t, abs(mono[1] - 0.35) < 1e-6, "mono1 %v", mono[1])

	// A single selected channel is centred.
	m.source_count = 1
	stereo := [2]f32{}
	monitor_mix(&m, src[:2], stereo[:], 1, 2, 2)
	testing.expectf(t, abs(stereo[0] - 0.1) < 1e-6 && abs(stereo[1] - 0.1) < 1e-6, "centre %v", stereo)

	// Disabled monitoring silences the buffer, including stale contents.
	monitor_set_enabled(&m, false)
	dst = {-9, -9, -9, -9}
	monitor_mix(&m, src[:], dst[:], 2, 2, 2)
	testing.expectf(t, dst == [4]f32{}, "disabled left audio %v", dst)

	// Degenerate inputs must be harmless.
	monitor_set_enabled(&m, true)
	monitor_mix(nil, nil, nil, 0, 0, 0)
	monitor_mix(&m, src[:], dst[:], 2, 0, 2)
	testing.expectf(t, dst == [4]f32{}, "zero input channels wrote audio")
}

@(test)
recorder_callback_captures_and_monitors_on_duplex :: proc(t: ^testing.T) {
	r := Recorder {
		active     = true,
		channels   = 2,
		cap_frames = 4,
	}
	r.ring = make([]f32, r.cap_frames * r.channels)
	defer delete(r.ring)
	monitor_init(&r.monitor)
	r.monitor.sources[0] = 0
	r.monitor.sources[1] = 1
	r.monitor.source_count = 2
	monitor_set_enabled(&r.monitor, true)

	dev: ma.device
	dev.pUserData = &r
	dev.capture.channels = 2
	dev.playback.channels = 2
	src := [4]f32{0.2, -0.4, 0.6, 0.8}
	out := [4]f32{-9, -9, -9, -9}

	recorder_callback(&dev, raw_data(out[:]), raw_data(src[:]), 2)
	testing.expectf(t, sync.atomic_load(&r.write_frame) == 2, "captured %v frames", sync.atomic_load(&r.write_frame))
	testing.expectf(t, r.ring[0] == 0.2 && r.ring[3] == 0.8, "ring %v", r.ring[:4])
	testing.expectf(t, abs(out[0] - 0.1) < 1e-6 && abs(out[1] + 0.2) < 1e-6, "monitor %v", out)

	// Stopping monitoring keeps the take but silences the output.
	monitor_set_enabled(&r.monitor, false)
	out = {-9, -9, -9, -9}
	recorder_callback(&dev, raw_data(out[:]), raw_data(src[:]), 2)
	testing.expectf(t, out == [4]f32{}, "disabled monitor output %v", out)
	testing.expectf(t, sync.atomic_load(&r.write_frame) == 4, "capture stopped")
}

// ---------------------------------------------------------------- latency

@(test)
engine_latency_frames_rounds_at_odd_rates :: proc(t: ^testing.T) {
	testing.expectf(t, engine_latency_frames(0, 48_000) == 0, "zero latency")
	testing.expectf(t, engine_latency_frames(1, 48_000) == 48, "1 ms @48k")
	testing.expectf(t, engine_latency_frames(2.5, 44_100) == 110, "2.5 ms @44.1k")
	testing.expectf(t, engine_latency_frames(1.5, 44_100) == 66, "1.5 ms @44.1k")
	testing.expectf(t, engine_latency_frames(0.5, 22_050) == 11, "0.5 ms @22.05k")
	testing.expectf(t, engine_latency_frames(0.01, 96_000) == 1, "sub-frame rounds up")
	testing.expectf(t, engine_latency_frames(-3, 48_000) == 0, "negative latency")
	testing.expectf(t, engine_latency_frames(10, 0) == 0, "zero rate")

	e: Engine
	engine_set_latency_ms(&e, -5)
	testing.expectf(t, e.latency_ms == 0, "negative setter %v", e.latency_ms)
	engine_set_latency_ms(&e, 12.5)
	testing.expectf(t, e.latency_ms == 12.5, "setter %v", e.latency_ms)
	testing.expect(t, !e.monitor_enabled, "monitor should default off")
}

@(test)
engine_split_take_drops_latency_frames :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-fx-engine-latency"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer {
		_ = os.remove_all(dir)
	}

	e := Engine{}
	defer {
		for i in 0 ..< MAX_ENGINE_TRACKS {
			delete(e.loaded[i])
		}
		delete(e.session_dir)
		delete(e.take_path)
	}
	e.session_dir = fmt.aprintf("%s", dir)
	e.take_path = fmt.aprintf("%s/take.raw", dir)
	e.rec.channels = 2
	e.rec.rate = 44_100
	e.rec.armed[0] = true
	e.rec.inputs[0] = 1
	e.latency_ms = 1.5 // 66 frames at 44.1 kHz

	frames := 200
	testing.expect(t, live_test_write_raw(e.take_path, frames, 2), "write raw")
	testing.expect(t, engine_split_take(&e, nil), "split failed")

	testing.expectf(t, len(e.loaded[0]) == frames - 66, "frames %d", len(e.loaded[0]))
	testing.expectf(t, e.loaded[0][0] == f32(66 * 10 + 1), "first sample %v", e.loaded[0][0])
	testing.expectf(t, e.loaded[0][len(e.loaded[0]) - 1] == f32(199 * 10 + 1), "last sample %v", e.loaded[0][len(e.loaded[0]) - 1])
	testing.expect(t, !os.exists(e.take_path), "raw take should be removed")

	// Dropping the whole take is a failure, not an empty WAV.
	e.latency_ms = 10 // 441 frames at 44.1 kHz > 200
	testing.expect(t, live_test_write_raw(e.take_path, frames, 2), "rewrite raw")
	testing.expect(t, !engine_split_take(&e, nil), "empty post-latency take accepted")
	testing.expect(t, !os.exists(e.take_path), "failed split left the raw take")
}

// ---------------------------------------------------------------- hotplug

@(test)
device_notifications_set_interrupt_only_when_unexpected :: proc(t: ^testing.T) {
	r: Recorder
	dev: ma.device
	dev.pUserData = &r
	n := ma.device_notification {
		pDevice = &dev,
		type    = .stopped,
	}

	recorder_notification(&n)
	testing.expectf(t, sync.atomic_load(&r.interrupt) == 1, "capture stop not flagged")

	// A deliberate stop marks itself first; its notification must not look
	// like a hot-unplug.
	sync.atomic_store(&r.interrupt, 0)
	sync.atomic_store(&r.stop_expected, 1)
	recorder_notification(&n)
	testing.expectf(t, sync.atomic_load(&r.interrupt) == 0, "expected stop flagged")

	// Devices that report an interruption are treated the same as a stop.
	sync.atomic_store(&r.stop_expected, 0)
	n.type = .interruption_began
	recorder_notification(&n)
	testing.expectf(t, sync.atomic_load(&r.interrupt) == 1, "interruption not flagged")

	n.type = .started
	recorder_notification(&n)
	testing.expectf(t, sync.atomic_load(&r.interrupt) == 0, "start did not clear")

	p: Playback
	dev.pUserData = &p
	n.type = .stopped
	playback_notification(&n)
	testing.expectf(t, sync.atomic_load(&p.interrupt) == 1, "playback stop not flagged")
	sync.atomic_store(&p.stop_expected, 1)
	sync.atomic_store(&p.interrupt, 0)
	playback_notification(&n)
	testing.expectf(t, sync.atomic_load(&p.interrupt) == 0, "expected playback stop flagged")
}

@(test)
engine_device_resolution_falls_back_after_unplug :: proc(t: ^testing.T) {
	names := [3]string{"Built-in Mic", "Scarlett 4i4", "USB Headset"}

	// Normal selection by index.
	testing.expectf(t, engine_resolve_device_index(1, "Scarlett 4i4", names[:], 0) == 1, "valid index")
	// The list shifted (a device before it disappeared): follow the name.
	testing.expectf(t, engine_resolve_device_index(1, "USB Headset", names[:], 0) == 2, "shifted name")
	// The selected name disappeared: use the system default, not the index
	// that now points at a different device.
	testing.expectf(t, engine_resolve_device_index(2, "Gone Interface", names[:], 0) == 0, "default fallback")
	// No name available keeps a valid index, and an invalid one falls back.
	testing.expectf(t, engine_resolve_device_index(2, "", names[:], 0) == 2, "index only")
	testing.expectf(t, engine_resolve_device_index(9, "", names[:], 1) == 1, "invalid index")
	testing.expectf(t, engine_resolve_device_index(0, "", nil, 0) == -1, "no devices")

	testing.expectf(t, engine_fallback_device_index(1, 3, 2) == 1, "fallback valid")
	testing.expectf(t, engine_fallback_device_index(7, 3, 2) == 2, "fallback default")
	testing.expectf(t, engine_fallback_device_index(7, 0, 0) == -1, "fallback empty")

	// Cross-OS profile suffix matching (PipeWire <-> CoreAudio).
	mac_names := [3]string{"Scarlett 4i4 USB", "MX Brio", "MacBook Air Microphone"}
	idx, matched := engine_resolve_device_index_ex(1, "Scarlett 4i4 USB Analog Surround 5.1", mac_names[:], 1)
	testing.expectf(t, idx == 0 && matched, "linux->mac prefix match got (%d, %v)", idx, matched)

	linux_names := [2]string{"MX Brio Analog Stereo", "Scarlett 4i4 USB Analog Surround 5.1"}
	idx, matched = engine_resolve_device_index_ex(0, "Scarlett 4i4 USB", linux_names[:], 0)
	testing.expectf(t, idx == 1 && matched, "mac->linux prefix match got (%d, %v)", idx, matched)

	// Ambiguous prefix must not guess; fall back to default_index with matched=false.
	ambig := [2]string{"Scarlett 4i4 USB Analog", "Scarlett 4i4 USB Digital"}
	idx, matched = engine_resolve_device_index_ex(0, "Scarlett 4i4 USB", ambig[:], 1)
	testing.expectf(t, idx == 1 && !matched, "ambiguous prefix got (%d, %v)", idx, matched)

	// Non-prefix (Monitor source) must not match.
	mon := [2]string{"Monitor of Scarlett 4i4 USB", "Built-in Mic"}
	idx, matched = engine_resolve_device_index_ex(0, "Scarlett 4i4 USB", mon[:], 1)
	testing.expectf(t, idx == 1 && !matched, "monitor prefix got (%d, %v)", idx, matched)
}

@(test)
engine_match_and_set_device_keep_ui_in_sync :: proc(t: ^testing.T) {
	e := Engine{}
	e.default_device_index = 1
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	names := [3]string{"Scarlett 4i4 USB", "MX Brio", "MacBook Air Microphone"}
	ui.app_set_devices(&a, names[:], 1)
	e.device_index = 1

	// Cross-OS project device name resolves to Scarlett and updates UI/app state.
	ui.app_set_device(&a, "Scarlett 4i4 USB Analog Surround 5.1")
	engine_match_device(&e, &a, ui.app_device(&a))
	testing.expect_value(t, e.device_index, 0)
	testing.expect_value(t, a.device_index, 0)
	testing.expect_value(t, ui.app_device(&a), "Scarlett 4i4 USB")

	// Missing device falls back to default_device_index and toasts.
	engine_match_device(&e, &a, "Unplugged Box")
	testing.expect_value(t, e.device_index, 1)
	testing.expect_value(t, a.device_index, 1)
	testing.expect_value(t, ui.app_device(&a), "MX Brio")
	testing.expect(t, a.toast_time > 0, "fallback should toast")

	// engine_set_device repairs drifted a.device even when index == e.device_index.
	ui.app_set_device(&a, "Stale Name")
	a.device_index = 2
	engine_set_device(&e, &a, 1)
	testing.expect_value(t, e.device_index, 1)
	testing.expect_value(t, a.device_index, 1)
	testing.expect_value(t, ui.app_device(&a), "MX Brio")
}

@(test)
engine_monitor_switch_is_safe_when_idle :: proc(t: ^testing.T) {
	e: Engine
	testing.expect(t, !e.monitor_enabled, "monitor default")
	testing.expect(t, engine_monitor_start(&e, nil), "idle enable failed")
	testing.expect(t, e.monitor_enabled, "monitor not enabled")
	testing.expect(t, engine_monitor_stop(&e, nil), "idle disable failed")
	testing.expect(t, !e.monitor_enabled, "monitor not disabled")
	testing.expect(t, !engine_monitor_stop(&e, nil), "second disable reported a change")
}

// ---------------------------------------------------------------- helper

live_test_write_raw :: proc(path: string, frames, channels: int) -> bool {
	data := make([]byte, frames * channels * 4)
	defer delete(data)
	for f in 0 ..< frames {
		for c in 0 ..< channels {
			_ = endian.put_f32(data[(f * channels + c) * 4:], .Little, f32(f * 10 + c + 1))
		}
	}
	return os.write_entire_file(path, data) == nil
}

@(test)
engine_seek_updates_playback_cursor_and_scrub_meters :: proc(t: ^testing.T) {
	e: Engine
	e.sample_rate = 48_000
	e.loaded_rate[0] = 48_000
	e.loaded[0] = make([]f32, 48_000 * 4)
	defer {
		delete(e.loaded[0])
		e.loaded[0] = nil
	}
	// Put silence in seconds 0..2, strong 0.5 signal in seconds 2..4.
	for i in 48_000 * 2 ..< 48_000 * 4 {
		e.loaded[0][i] = 0.5
	}
	testing.expect(t, engine_tape_frames(&e) == 48_000 * 4, "tape length 4 s")

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	engine_sync_tape_length(&e, &a)
	testing.expect(t, a.tape_frames == 48_000 * 4, "synced tape_frames")

	// Scrubbing into silence yields -60 dB; scrubbing into second 2 lights track 1 meter.
	ui.app_seek_zero(&a)
	engine_seek(&e, &a)
	testing.expectf(t, a.tracks[0].peak_db < -50, "silence peak %v", a.tracks[0].peak_db)

	_ = ui.app_scrub_seconds(&a, 2.0)
	engine_seek(&e, &a)
	testing.expectf(t, a.tracks[0].peak_db > -12 && a.master.peak_db > -12, "scrubbed signal peak %v / %v", a.tracks[0].peak_db, a.master.peak_db)

	// Active playback seek repositions atomic playback cursor + bumps seek_gen.
	e.play.active = true
	e.play.frames = 48_000 * 4
	e.play.bpm = 120
	e.play.sig_num = 4
	e.play.sig_den = 4
	_ = ui.app_scrub_seconds(&a, 1.0)
	engine_seek(&e, &a)
	testing.expect(t, sync.atomic_load(&e.play.cursor) == i64(48_000 * 3), "play cursor moved to 3 s")
	testing.expect(t, sync.atomic_load(&e.play.seek_gen) == 1, "seek_gen incremented")

	// Unbounded playback allows seeking past p.frames without clamping back to the audio end.
	e.play.unbounded = true
	a.frames = 48_000 * 8
	engine_seek(&e, &a)
	testing.expect(t, sync.atomic_load(&e.play.cursor) == i64(48_000 * 8), "unbounded seek moves cursor past p.frames")
	e.play.unbounded = false
	e.play.active = false
}

// ---------------------------------------------------------------- live playback

@(test)
engine_sync_play_tracks_caches_mixed_rates_without_leaks :: proc(t: ^testing.T) {
	e: Engine
	e.sample_rate = 48_000
	e.play_tracks_dirty = true
	defer {
		engine_free_play_tracks(&e)
		for i in 0 ..< MAX_ENGINE_TRACKS {
			delete(e.loaded[i])
			e.loaded[i] = nil
		}
	}

	e.loaded[0] = make([]f32, 48_000)
	e.loaded_rate[0] = 48_000
	for i in 0 ..< len(e.loaded[0]) {
		e.loaded[0][i] = 0.25
	}

	e.loaded[1] = make([]f32, 44_100)
	e.loaded_rate[1] = 44_100
	for i in 0 ..< len(e.loaded[1]) {
		e.loaded[1][i] = 0.5
	}

	engine_sync_play_tracks(&e)
	testing.expect(t, !e.play_tracks_dirty, "sync cleared dirty")
	testing.expect(t, !e.play_tracks_owned[0] && raw_data(e.play_tracks[0]) == raw_data(e.loaded[0]), "matching rate borrows loaded slice")
	testing.expect(t, e.play_tracks_owned[1] && len(e.play_tracks[1]) == 48_000, "mismatched rate resamples and owns slice")

	// Second sync is a cached no-op (keeps exact same resampled slice pointer).
	cached_ptr := raw_data(e.play_tracks[1])
	engine_sync_play_tracks(&e)
	testing.expect(t, raw_data(e.play_tracks[1]) == cached_ptr, "second sync did not reuse cache")
}

@(test)
live_mix_params_from_app_matches_settings_and_mutes_armed :: proc(t: ^testing.T) {
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	a.tracks[0].armed = true
	a.tracks[0].level = 0.9
	a.tracks[1].soloed = true
	a.tracks[1].pan = -0.5
	a.tracks[2].muted = false

	p := live_mix_params_from_app(&a, true)
	testing.expect_value(t, p.track_count, a.track_count)
	testing.expect(t, p.tracks[0].muted, "armed track muted when mute_armed=true")
	testing.expect(t, !p.tracks[1].muted, "soloed track active")
	testing.expect(t, p.tracks[2].muted, "unsoloed track muted while another is soloed")
	testing.expectf(t, abs(p.tracks[1].pan + 0.5) < 1e-6, "pan preserved")

	s := settings_from_app(&a)
	defer delete(s.tracks)
	testing.expectf(t, abs(p.tracks[0].level - s.tracks[0].level) < 1e-6, "level matches settings_from_app")
}
