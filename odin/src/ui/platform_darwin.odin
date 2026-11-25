#+build darwin
package ui

platform_audio_backend_name :: proc() -> string {
	return "CoreAudio"
}

platform_audio_backend_upper :: proc() -> string {
	return "COREAUDIO"
}

platform_audio_sources_subtitle :: proc() -> string {
	return "CoreAudio input devices"
}

platform_supports_jack :: proc() -> bool {
	return false
}

platform_delete_take_shortcut :: proc() -> string {
	return "Cmd+Del"
}

platform_new_take_shortcut :: proc() -> string {
	return "Cmd+t"
}
