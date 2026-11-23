// Device capture through vendored miniaudio.
//
// This is the Odin replacement for the cpal/JACK layer. Phase 1 records the
// selected capture device to memory (one mono track per hardware channel),
// then the CLI writes the tracks as 32-bit float WAVs.

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import dsp "dsp"
import ma "vendor:miniaudio"

Capture_State :: struct {
	buffer:   []f32,
	// Channels kept per frame in `buffer`.
	channels: int,
	// Channels per frame delivered by the device. 0 means equal to `channels`;
	// larger values mean the device was opened at its native width and only
	// the first `channels` hardware inputs are kept.
	src_channels: int,
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
		capture_copy_frames(state.buffer[state.written * state.channels:], src, n, state.src_channels, state.channels)
		state.written += n
	}
	sync.mutex_unlock(&state.lock)
}

// Copies `frames` interleaved frames of `src_channels` into `dst`, keeping
// only the first `keep` channels (hardware inputs 1..keep). `src_channels`
// of 0 (or <= keep) means the source is already `keep` wide.
capture_copy_frames :: proc "contextless" (dst: []f32, src: [^]f32, frames, src_channels, keep: int) {
	if keep <= 0 || frames <= 0 {
		return
	}
	stride := src_channels if src_channels > keep else keep
	if stride == keep {
		count := min(frames * keep, len(dst))
		for i in 0 ..< count {
			dst[i] = src[i]
		}
		return
	}
	n := min(frames, len(dst) / keep)
	for f in 0 ..< n {
		for c in 0 ..< keep {
			dst[f * keep + c] = src[f * stride + c]
		}
	}
}

// PA_CHANNEL_MAP_AUX (pulse/channelmap.h). miniaudio's PulseAudio backend
// otherwise asks for an AIFF/standard speaker map, and PulseAudio/PipeWire
// then *remix* the source into it: on a 6-input interface exposed as
// "Analog Surround 5.1" (FL FR RL RR FC LFE), a 2-channel stream gets inputs
// 3-6 folded into tracks 1/2, and a 6-channel stream comes back reordered.
// AUX positions carry no speaker meaning, so the server copies channels 1:1
// in hardware order.
PULSE_CHANNEL_MAP_AUX :: i32(2)

// Capture channel counts to try, in order. 0 opens the device at its native
// width with the client map copied from the device map, so miniaudio's own
// converter is a passthrough and no backend can remix inputs; the caller then
// keeps the first `requested` channels. Explicit widths are the fallback for
// backends that reject a native open.
capture_open_attempts :: proc(requested: int) -> (attempts: [7]int, count: int) {
	candidates := [7]int{0, requested, 16, 8, 4, 2, 1}
	for c, i in candidates {
		if i > 0 && (c > requested || c <= 0) {
			continue
		}
		dup := false
		for j in 0 ..< count {
			if attempts[j] == c {
				dup = true
			}
		}
		if !dup {
			attempts[count] = c
			count += 1
		}
	}
	return
}

// PulseAudio stream map for a capture open of `channels` (0 = native width).
// AUX is safe for the native open (miniaudio copies the device map to the
// client, so its converter is a passthrough) and for 1-2 channels (miniaudio
// reports MONO/FL-FR for those regardless of the stream map). For explicit
// widths above 2 miniaudio would see AUX positions against a speaker client
// map and output silence, so those keep PulseAudio's default map.
capture_pulse_channel_map :: proc(channels: int) -> i32 {
	if channels <= 2 {
		return PULSE_CHANNEL_MAP_AUX
	}
	return 0 // PA_CHANNEL_MAP_DEFAULT (AIFF)
}

// Configures a capture (or duplex) config so hardware inputs arrive unmixed
// and in device order. `channels` is one entry of `capture_open_attempts`.
capture_config_unmixed :: proc(cfg: ^ma.device_config, channels: int) {
	cfg.capture.channels = u32(max(channels, 0))
	cfg.capture.channelMap = nil
	platform_audio_configure_capture(cfg, channels)
}

capture_device_name :: proc(info: ^ma.device_info) -> string {
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
		name := capture_device_name(info)
		marker := " "
		if info.isDefault {
			marker = "*"
		}
		fmt.printfln("  %s %2d  %s", marker, i, name)
		delete(name)
	}
	return true
}

// Returns capture device names. The caller owns and must free every string and
// the slice.
capture_device_names :: proc() -> []string {
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return nil
	}
	defer ma.context_uninit(&ctx)
	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS {
		return nil
	}
	names := make([]string, int(count))
	for i in 0 ..< int(count) {
		names[i] = capture_device_name(&infos[i])
	}
	return names
}

// Enumerates capture devices and also reports which one the system considers
// default. The caller owns the names and must free every string and the slice.
capture_device_list :: proc() -> (names: []string, default_index: int) {
	default_index = 0
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return nil, 0
	}
	defer ma.context_uninit(&ctx)
	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS || count == 0 {
		return nil, 0
	}
	names = make([]string, int(count))
	for i in 0 ..< int(count) {
		names[i] = capture_device_name(&infos[i])
		if infos[i].isDefault {
			default_index = i
		}
	}
	return
}

capture_default_index :: proc() -> int {
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return 0
	}
	defer ma.context_uninit(&ctx)
	infos: [^]ma.device_info
	count: u32
	if ma.context_get_devices(&ctx, nil, nil, &infos, &count) != .SUCCESS {
		return 0
	}
	for i in 0 ..< int(count) {
		if infos[i].isDefault {
			return i
		}
	}
	return 0
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

	state := Capture_State{}
	defer delete(state.buffer)

	cfg := ma.device_config_init(.capture)
	cfg.sampleRate = rate
	cfg.capture.format = .f32
	cfg.capture.pDeviceID = &infos[index].id
	cfg.dataCallback = capture_callback
	cfg.pUserData = &state
	cfg.periodSizeInFrames = 1024

	// Open at the native width first (no remixing anywhere), then fall back
	// down the list for backends that reject it.
	device: ma.device
	opened := false
	attempts, attempt_count := capture_open_attempts(channels)
	for attempt in attempts[:attempt_count] {
		capture_config_unmixed(&cfg, attempt)
		if ma.device_init(&ctx, &cfg, &device) == .SUCCESS {
			opened = true
			break
		}
	}
	if !opened {
		fmt.eprintln("cannot open capture device")
		return {}, false
	}
	defer ma.device_uninit(&device)

	actual_rate := device.sampleRate
	device_channels := int(device.capture.channels)
	if actual_rate == 0 || device_channels <= 0 {
		fmt.eprintln("capture device reported an invalid format")
		return {}, false
	}
	actual_channels := min(channels, device_channels)
	if actual_channels != channels {
		fmt.eprintfln("device has %d input channel(s), requested %d", device_channels, channels)
	}
	if actual_rate != rate {
		fmt.eprintfln("device runs at %d Hz, requested %d Hz", actual_rate, rate)
	}

	target_frames := int(seconds * f32(actual_rate))
	if target_frames <= 0 {
		return {}, false
	}
	// Allocate after the device is open so the buffer matches the channels and
	// rate that were actually accepted. The callback cannot run until
	// `device_start`, below.
	state.channels = actual_channels
	state.src_channels = device_channels
	state.capacity = target_frames
	state.buffer = make([]f32, target_frames * actual_channels)

	if ma.device_start(&device) != .SUCCESS {
		fmt.eprintln("cannot start capture device")
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
	samples := make([]f32, out_frames * actual_channels)
	copy(samples, state.buffer[:out_frames * actual_channels])

	return Capture_Result {
		samples = samples,
		channels = actual_channels,
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
