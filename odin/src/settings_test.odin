package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
settings_roundtrip_preserves_folder_and_a11y :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-odin-settings"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)
	path := "/tmp/tracker-odin-settings/settings.json"

	testing.expect(t, settings_save(path, "/home/studio/Music/Tracker", true, false), "save")
	doc, ok := settings_load(path)
	defer settings_destroy(&doc)
	testing.expect(t, ok, "load")
	testing.expect(t, doc.save_dir == "/home/studio/Music/Tracker", "save dir")
	testing.expect(t, doc.high_contrast, "high contrast")
	testing.expect(t, !doc.reduced_motion, "reduced motion")
}

@(test)
settings_rejects_unknown_version_and_keeps_defaults :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-odin-settings-version"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)
	path := "/tmp/tracker-odin-settings-version/settings.json"
	testing.expect(t, os.write_entire_file(path, `{"version":99,"saveDir":"/tmp/x"}`) == nil, "fixture")

	doc, ok := settings_load(path)
	defer settings_destroy(&doc)
	testing.expect(t, !ok, "unknown version must not load")
	testing.expect(t, doc.save_dir == "", "no stale save dir")
}

@(test)
normalize_save_dir_expands_home_and_rejects_relative :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	if home != "" {
		expanded, ok := normalize_save_dir("~/Music/Tracker/")
		defer delete(expanded)
		testing.expect(t, ok, "home path accepted")
		testing.expectf(t, expanded == fmt.tprintf("%s/Music/Tracker", home), "expanded %s", expanded)
	}

	_, relative := normalize_save_dir("Music/Tracker")
	testing.expect(t, !relative, "relative path rejected")
	_, empty := normalize_save_dir("   ")
	testing.expect(t, !empty, "empty path rejected")

	root, root_ok := normalize_save_dir("/")
	defer delete(root)
	testing.expect(t, root_ok && root == "/", "root stays root")
}

@(test)
default_session_dir_honors_xdg_data_home :: proc(t: ^testing.T) {
	old_xdg := os.get_env("XDG_DATA_HOME", context.allocator)
	defer {
		if old_xdg != "" {
			_ = os.set_env("XDG_DATA_HOME", old_xdg)
		} else {
			os.unset_env("XDG_DATA_HOME")
		}
		delete(old_xdg)
	}
	testing.expect(t, os.set_env("XDG_DATA_HOME", "/tmp/tracker-xdg-data") == nil, "set xdg")
	dir := default_session_dir()
	defer delete(dir)
	testing.expect(t, dir == "/tmp/tracker-xdg-data/tracker/session", dir)

	_ = os.set_env("XDG_DATA_HOME", "/tmp/other")
	fallback := default_session_dir()
	defer delete(fallback)
	testing.expect(t, fallback == "/tmp/other/tracker/session", fallback)
}
