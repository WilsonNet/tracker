package main

import "core:testing"

@(test)
file_dialog_starts_in_parent_of_current_project :: proc(t: ^testing.T) {
	testing.expect(t, dialog_start_dir("/home/u/Tracker-FX/session", "/home/u") == "/home/u/Tracker-FX", "project parent")
	testing.expect(t, dialog_start_dir("/home/u/Tracker-FX/Album/take-2", "/home/u") == "/home/u/Tracker-FX/Album", "nested project parent")
	testing.expect(t, dialog_start_dir("", "/home/u") == "/home/u", "empty falls back to home")
	testing.expect(t, dialog_start_dir("/", "/home/u") == "/", "root stays root")
}
