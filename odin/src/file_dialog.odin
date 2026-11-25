// Cross-platform file & folder picker API.
//
// Platform-specific backends live in file_dialog_linux.odin,
// file_dialog_darwin.odin, and file_dialog_other.odin.
package main

import "core:fmt"
import "core:os"
import "core:strings"

@(private)
trim_line :: proc(s: string) -> string {
	start := 0
	end := len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' || s[start] == '\n') {
		start += 1
	}
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r' || s[end - 1] == '\n') {
		end -= 1
	}
	return s[start:end]
}

// Opens a project JSON file. Returns an owned string.
pick_project_open :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	start := home if home != "" else "."
	return platform_pick_project_open(start)
}

// Save-as path (may not exist yet). Returns an owned string.
pick_project_save :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	start := home if home != "" else "."
	path, ok := platform_pick_project_save(start)
	if !ok {
		return "", false
	}
	if !strings.has_suffix(path, ".json") {
		with_ext := fmt.aprintf("%s.json", path)
		delete(path)
		return with_ext, true
	}
	return path, true
}

// Project folders normally live side by side. Start the directory picker in
// their parent, not inside the current project, so siblings are visible.
dialog_start_dir :: proc(current, home: string) -> string {
	if current == "" {
		return home if home != "" else "."
	}
	return parent_dir(current)
}

// Save-as path for an external stereo mix render. Returns an owned string.
pick_mix_save :: proc(start_dir: string) -> (string, bool) {
	start := start_dir if start_dir != "" else "."
	path, ok := platform_pick_mix_save(start)
	if !ok {
		return "", false
	}
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".wav") {
		with_ext := fmt.aprintf("%s.wav", path)
		delete(path)
		return with_ext, true
	}
	return path, true
}

// Opens a session directory. Returns an owned string.
pick_session_open :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	return platform_pick_directory("Open Tracker-FX Session", home if home != "" else ".")
}

// Chooses the folder where project.json, takes and bounces are written.
pick_save_dir :: proc(current: string) -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	return platform_pick_directory("Choose Tracker-FX Project Folder", dialog_start_dir(current, home))
}
