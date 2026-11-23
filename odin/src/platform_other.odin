#+build !linux
#+build !darwin
package main

import sdl "vendor:sdl3"
import ma "vendor:miniaudio"

platform_audio_configure_capture :: proc(cfg: ^ma.device_config, channels: int) {
}

platform_supports_jack :: proc() -> bool {
	return false
}

platform_audio_backend_name :: proc() -> string {
	return "Audio"
}

platform_open_url :: proc(url: string) -> bool {
	return false
}

platform_primary_mod :: proc(mod: sdl.Keymod) -> bool {
	return .LCTRL in mod || .RCTRL in mod
}

platform_rss_kb :: proc() -> int {
	return 0
}
