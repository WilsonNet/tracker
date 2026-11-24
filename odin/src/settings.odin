// Machine-local preferences under XDG_CONFIG_HOME (or ~/.config).
//
// Project data lives where the user points `saveDir`; this file only records
// that folder plus the accessibility switches. Audio routing and mix settings
// stay in project.json, so opening a project restores them.
//
// The UI owns the values; this module is pure serialization plus the default
// data directory so the CLI and the window agree on where a session lives.

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

SETTINGS_VERSION :: 1
// Linux PATH_MAX; keep the whole path so applying never retargets a silently
// truncated folder.
SETTINGS_PATH_MAX :: 4096

Settings_Doc :: struct {
	version:        int    `json:"version"`,
	save_dir:       string `json:"saveDir,omitempty"`,
	high_contrast:  bool   `json:"highContrast"`,
	reduced_motion: bool   `json:"reducedMotion"`,
	preroll_s:      f32    `json:"prerollS"`,
	preroll_grid:   int    `json:"prerollGrid"`,
	timing_mode:    string `json:"timingMode,omitempty"`,
}

settings_destroy :: proc(doc: ^Settings_Doc) {
	if doc == nil {
		return
	}
	delete(doc.save_dir)
	doc.save_dir = ""
	delete(doc.timing_mode)
	doc.timing_mode = ""
}

// `$XDG_CONFIG_HOME/tracker` (or `~/.config/tracker`), matching recent.json.
settings_config_path :: proc() -> string {
	dir := recent_config_dir()
	defer delete(dir)
	return fmt.aprintf("%s/settings.json", dir)
}

// Default project folder: `$XDG_DATA_HOME/tracker/session` (or
// `~/.local/share/tracker/session`). Kept separate from settings so a fresh
// install and the CLI record into the same place.
default_session_dir :: proc() -> string {
	xdg := os.get_env("XDG_DATA_HOME", context.allocator)
	defer delete(xdg)
	if xdg != "" {
		return fmt.aprintf("%s/tracker/session", xdg)
	}
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	if home == "" {
		return fmt.aprintf(".local/share/tracker/session")
	}
	return fmt.aprintf("%s/.local/share/tracker/session", home)
}

// Normalizes a folder typed in the settings overlay. Expands a leading `~`,
// trims spaces and a trailing slash, and rejects relative paths so a typo can
// never start writing inside the process working directory. Caller owns the
// returned string.
normalize_save_dir :: proc(path: string) -> (string, bool) {
	p := strings.trim_space(path)
	if p == "" || len(p) > SETTINGS_PATH_MAX {
		return "", false
	}
	expanded := false
	if p == "~" || strings.has_prefix(p, "~/") {
		home := os.get_env("HOME", context.allocator)
		defer delete(home)
		if home == "" {
			return "", false
		}
		if p == "~" {
			p = home
		} else {
			p = fmt.aprintf("%s%s", home, p[1:])
			expanded = true
		}
	}
	if p == "" || p[0] != '/' || len(p) > SETTINGS_PATH_MAX {
		if expanded {
			delete(p)
		}
		return "", false
	}
	for len(p) > 1 && p[len(p) - 1] == '/' {
		p = p[:len(p) - 1]
	}
	if expanded {
		return p, true
	}
	return strings.clone(p), true
}

settings_load :: proc(path: string) -> (Settings_Doc, bool) {
	doc := Settings_Doc{version = SETTINGS_VERSION, preroll_s = 3, preroll_grid = 2}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return doc, false
	}
	defer delete(data)
	if uerr := json.unmarshal(data, &doc); uerr != nil {
		settings_destroy(&doc)
		return Settings_Doc{version = SETTINGS_VERSION}, false
	}
	if doc.version != SETTINGS_VERSION || len(doc.save_dir) > SETTINGS_PATH_MAX {
		settings_destroy(&doc)
		return Settings_Doc{version = SETTINGS_VERSION}, false
	}
	for b in doc.save_dir {
		if b == 0 {
			settings_destroy(&doc)
			return Settings_Doc{version = SETTINGS_VERSION}, false
		}
	}
	return doc, true
}

settings_save :: proc(
	path, save_dir: string,
	high_contrast, reduced_motion: bool,
	preroll_s: f32 = 3,
	preroll_grid: int = 2,
	timing_mode: string = "grid",
) -> bool {
	if len(save_dir) > SETTINGS_PATH_MAX {
		return false
	}
	doc := Settings_Doc {
		version        = SETTINGS_VERSION,
		save_dir       = save_dir,
		high_contrast  = high_contrast,
		reduced_motion = reduced_motion,
		preroll_s      = clamp(preroll_s, 0, 30),
		preroll_grid   = clamp(preroll_grid, 0, 4),
		timing_mode    = "free" if timing_mode == "free" else "grid",
	}
	data, err := json.marshal(doc, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fmt.eprintfln("settings encode failed: %v", err)
		return false
	}
	defer delete(data)
	return write_file_atomic(path, data)
}
