#+build darwin
package main

import "core:os"
import sdl "vendor:sdl3"
import ma "vendor:miniaudio"

platform_audio_configure_capture :: proc(cfg: ^ma.device_config, channels: int) {
	// CoreAudio delivers hardware inputs 1..N without PulseAudio speaker remixing.
}

platform_audio_configure_playback :: proc(cfg: ^ma.device_config) {
	cfg.periodSizeInFrames = 256 // ~5.3 ms at 48 kHz on CoreAudio
	cfg.periods = 2
}

platform_supports_jack :: proc() -> bool {
	return false
}

platform_audio_backend_name :: proc() -> string {
	return "CoreAudio"
}

platform_open_url :: proc(url: string) -> bool {
	state, out, err, e := os.process_exec(os.Process_Desc{command = []string{"open", url}}, context.allocator)
	delete(out)
	delete(err)
	return e == nil && state.exited && state.exit_code == 0
}

platform_primary_mod :: proc(mod: sdl.Keymod) -> bool {
	return .LCTRL in mod || .RCTRL in mod || .LGUI in mod || .RGUI in mod
}

platform_rss_kb :: proc() -> int {
	return 0
}
