#+build !linux
#+build !darwin
package ui

platform_audio_backend_name :: proc() -> string {
	return "Audio"
}

platform_audio_backend_upper :: proc() -> string {
	return "AUDIO"
}

platform_audio_sources_subtitle :: proc() -> string {
	return "Audio input devices"
}

platform_supports_jack :: proc() -> bool {
	return false
}

platform_delete_take_shortcut :: proc() -> string {
	return "Ctrl+Del"
}

platform_new_take_shortcut :: proc() -> string {
	return "Ctrl+t"
}
