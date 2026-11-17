// Device capture through vendored miniaudio.
//
// This is the Odin replacement for the cpal/JACK layer. Phase 1 records the
// selected capture device to memory (one mono track per hardware channel),
// then the CLI writes the tracks as 32-bit float WAVs.

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import dsp "dsp"
import ma "vendor:miniaudio"

Capture_State :: struct {
	buffer:   []f32,
	channels: int,
	capacity: int,
	written:  int,
	lock:     sync.Mutex,
}

Capture_Result :: struct {
	// Interleaved samples.
	samples:  []f32,
	channels: int,
	rate:     u32,
	frames:   int,
	// Frames missing from the requested duration (0 on a complete take).
	short:    int,
}

capture_destroy :: proc(result: ^Capture_Result) {
	delete(result.samples)
	result.samples = nil
}

@(private)
capture_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	if input == nil {
		return
	}
	state := cast(^Capture_State)device.pUserData
	if state == nil {
		return
	}
	frames := int(frame_count)
	src := cast([^]f32)input

	sync.mutex_lock(&state.lock)
	remaining := state.capacity - state.written
	n := min(frames, remaining)
	if n > 0 {
		base := state.written * state.channels
		count := n * state.channels
		for i in 0 ..< count {
			state.buffer[base + i] = src[i]
		}
		state.written += n
	}
	sync.mutex_unlock(&state.lock)
}

@(private)
device_name :: proc(info: ^ma.device_info) -> string {
	name, _ := strings.clone_from_cstring(cstring(&info.name[0]))
	return name
}

// Lists capture devices. Returns false when no usable device is found.
list_capture_devices :: proc() -> bool {
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		fmt.eprintln("cannot initialise audio context")
		return false
	}
	defer ma.context_uninit(&ctx)

	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS {
		fmt.eprintln("cannot enumerate audio devices")
		return false
	}
	if count == 0 {
		fmt.eprintln("no capture devices found")
		return false
	}

	fmt.printfln("capture devices (%d):", count)
	for i in 0 ..< int(count) {
		info := &infos[i]
		name := device_name(info)
		marker := " "
		if info.isDefault {
			marker = "*"
		}
		fmt.printfln("  %s %2d  %s", marker, i, name)
		delete(name)
	}
	return true
}

// Records `seconds` from a capture device. `device_index < 0` selects the
// system default. Returns interleaved f32 samples.
capture_record :: proc(seconds: f32, channels: int, rate: u32, device_index: int) -> (result: Capture_Result, ok: bool) {
	if seconds <= 0.0 || channels <= 0 || channels > 32 {
		return {}, false
	}
	if seconds > 3_600.0 {
		fmt.eprintln("refusing a take longer than one hour")
		return {}, false
	}

	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		fmt.eprintln("cannot initialise audio context")
		return {}, false
	}
	defer ma.context_uninit(&ctx)

	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS || count == 0 {
		fmt.eprintln("no capture devices found")
		return {}, false
	}

	index := device_index
	if index < 0 {
		index = 0
		for i in 0 ..< int(count) {
			if infos[i].isDefault {
				index = i
				break
			}
		}
	}
	if index >= int(count) {
		fmt.eprintfln("device index %d out of range (0..%d)", index, int(count) - 1)
		return {}, false
	}

	target_frames := int(seconds * f32(rate))
	state := Capture_State {
		buffer   = make([]f32, target_frames * channels),
		channels = channels,
		capacity = target_frames,
	}
	defer delete(state.buffer)

	cfg := ma.device_config_init(.capture)
	cfg.sampleRate = rate
	cfg.capture.format = .f32
	cfg.capture.channels = u32(channels)
	cfg.capture.pDeviceID = &infos[index].id
	cfg.dataCallback = capture_callback
	cfg.pUserData = &state
	cfg.periodSizeInFrames = 1024

	device: ma.device
	if ma.device_init(&ctx, &cfg, &device) != .SUCCESS {
		fmt.eprintln("cannot open capture device")
		return {}, false
	}
	defer ma.device_uninit(&device)

	if ma.device_start(&device) != .SUCCESS {
		fmt.eprintln("cannot start capture device")
		return {}, false
	}

	actual_rate := device.sampleRate
	actual_channels := int(device.capture.channels)
	// The callback writes `state.channels` wide; miniaudio is configured to
	// match, so a mismatch means the backend rejected the request.
	if actual_channels != channels {
		fmt.eprintfln("device opened %d channels, requested %d", actual_channels, channels)
		ma.device_stop(&device)
		return {}, false
	}

	start := time.now()
	last_print := time.Duration(0)
	for {
		sync.mutex_lock(&state.lock)
		written := state.written
		sync.mutex_unlock(&state.lock)

		elapsed := time.since(start)
		if written >= target_frames || elapsed > time.Duration(f64(seconds + 3.0) * f64(time.Second)) {
			break
		}
		if elapsed - last_print >= 250 * time.Millisecond {
			last_print = elapsed
			progress := f32(written) / f32(target_frames)
			fmt.printfln("  recording  %5.1f%%  %4.1f/%4.1f s", progress * 100.0, f32(written) / f32(actual_rate), seconds)
		}
		time.sleep(50 * time.Millisecond)
	}

	ma.device_stop(&device)

	sync.mutex_lock(&state.lock)
	frames := state.written
	sync.mutex_unlock(&state.lock)

	out_frames := min(frames, target_frames)
	samples := make([]f32, out_frames * channels)
	for i in 0 ..< len(samples) {
		samples[i] = state.buffer[i]
	}

	return Capture_Result {
		samples = samples,
		channels = channels,
		rate = actual_rate,
		frames = out_frames,
		short = target_frames - out_frames,
	}, true
}

// Writes one mono 32-bit float WAV per capture channel.
write_capture_tracks :: proc(result: ^Capture_Result, out_dir: string) -> bool {
	if result.channels == 0 || result.frames == 0 {
		return false
	}
	os_make_directory(out_dir)
	for ch in 0 ..< result.channels {
		mono := make([]f32, result.frames)
		for i in 0 ..< result.frames {
			mono[i] = result.samples[i * result.channels + ch]
		}
		path := fmt.tprintf("%s/track%d.wav", out_dir, ch + 1)
		peak, rms := dsp.peak_rms_db(mono, 1)
		if !wav_write(path, result.rate, 1, mono) {
			fmt.eprintfln("cannot write %s", path)
			delete(mono)
			return false
		}
		fmt.printfln("  wrote %s  peak %.2f dBFS  rms %.2f dBFS", path, peak, rms)
		delete(mono)
	}
	return true
}

@(private)
os_make_directory :: proc(path: string) {
	if !os.exists(path) {
		_ = os.make_directory(path)
	}
}
