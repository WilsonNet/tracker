#+build linux
package ui

platform_audio_backend_name :: proc() -> string {
	return "PipeWire"
}

platform_audio_backend_upper :: proc() -> string {
	return "PIPEWIRE"
}

platform_audio_sources_subtitle :: proc() -> string {
	return "PipeWire / JACK sources"
}

platform_supports_jack :: proc() -> bool {
	return true
}
