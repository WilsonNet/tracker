#+build linux
package main

import "core:os"
import sdl "vendor:sdl3"
import ma "vendor:miniaudio"

platform_audio_configure_capture :: proc(cfg: ^ma.device_config, channels: int) {
	cfg.pulse.channelMap = capture_pulse_channel_map(channels)
}

platform_audio_configure_playback :: proc(cfg: ^ma.device_config) {
	// PipeWire can glitch below ~20 ms total buffer; 512 x 2 (~21 ms @ 48 kHz)
	// cuts latency 3x vs 1024 x 3 while staying glitch-free.
	cfg.periodSizeInFrames = 512
	cfg.periods = 2
}

platform_supports_jack :: proc() -> bool {
	return true
}

platform_audio_backend_name :: proc() -> string {
	return "PipeWire"
}

platform_open_url :: proc(url: string) -> bool {
	candidates := [3][]string{
		{"xdg-open", url},
		{"gio", "open", url},
		{"sensible-browser", url},
	}
	for argv in candidates {
		state, out, err, e := os.process_exec(os.Process_Desc{command = argv}, context.allocator)
		delete(out)
		delete(err)
		if e == nil && state.exited && state.exit_code == 0 {
			return true
		}
	}
	return false
}

platform_primary_mod :: proc(mod: sdl.Keymod) -> bool {
	return .LCTRL in mod || .RCTRL in mod
}

platform_rss_kb :: proc() -> int {
	f, err := os.open("/proc/self/statm", os.O_RDONLY)
	if err != nil {
		return 0
	}
	defer os.close(f)
	buf: [128]u8
	n, rerr := os.read(f, buf[:])
	if rerr != nil || n <= 0 {
		return 0
	}
	// "size resident shared text lib data dt" (all in pages).
	text := string(buf[:n])
	fields := 0
	for i in 0 ..< len(text) {
		if text[i] == ' ' {
			fields += 1
			if fields == 1 {
				start := i + 1
				val := 0
				for j in start ..< len(text) {
					if text[j] == ' ' {
						return val * 4096 / 1024
					}
					val = val * 10 + int(text[j] - '0')
				}
			}
		}
	}
	return 0
}
