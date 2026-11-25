#+build darwin
// Native macOS file pickers via osascript Cocoa panels.
package main

import "core:fmt"
import "core:os"
import "core:strings"

@(private)
applescript_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '\\' || ch == '"' {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, ch)
	}
	strings.write_byte(&b, '"')
	return strings.clone(strings.to_string(b))
}

@(private)
run_osascript_dialog :: proc(script: string) -> (string, bool) {
	hidden := os.get_env("VUI_HIDDEN", context.allocator)
	defer delete(hidden)
	if hidden == "1" {
		return "", false
	}
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = []string{"osascript", "-e", script}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	path := trim_line(string(stdout))
	if path == "" {
		return "", false
	}
	return strings.clone(path), true
}

@(private)
platform_pick_project_open :: proc(start: string) -> (string, bool) {
	qstart := applescript_quote(start)
	defer delete(qstart)
	script: string
	if start != "" {
		script = fmt.aprintf(
			`POSIX path of (choose file with prompt "Open Tracker-FX Project" of type {{"json"}} default location POSIX file %s)`,
			qstart,
		)
	} else {
		script = fmt.aprintf(
			`POSIX path of (choose file with prompt "Open Tracker-FX Project" of type {{"json"}})`,
		)
	}
	defer delete(script)
	return run_osascript_dialog(script)
}

@(private)
platform_pick_project_save :: proc(start: string) -> (string, bool) {
	qstart := applescript_quote(start)
	defer delete(qstart)
	script: string
	if start != "" {
		script = fmt.aprintf(
			`POSIX path of (choose file name with prompt "Save Tracker-FX Project As" default name "project.json" default location POSIX file %s)`,
			qstart,
		)
	} else {
		script = fmt.aprintf(
			`POSIX path of (choose file name with prompt "Save Tracker-FX Project As" default name "project.json")`,
		)
	}
	defer delete(script)
	return run_osascript_dialog(script)
}

@(private)
platform_pick_mix_save :: proc(start: string) -> (string, bool) {
	qstart := applescript_quote(start)
	defer delete(qstart)
	script: string
	if start != "" {
		script = fmt.aprintf(
			`POSIX path of (choose file name with prompt "Render Mix to WAV" default name "mix.wav" default location POSIX file %s)`,
			qstart,
		)
	} else {
		script = fmt.aprintf(
			`POSIX path of (choose file name with prompt "Render Mix to WAV" default name "mix.wav")`,
		)
	}
	defer delete(script)
	return run_osascript_dialog(script)
}

@(private)
platform_pick_directory :: proc(title, start: string) -> (string, bool) {
	qtitle := applescript_quote(title)
	defer delete(qtitle)
	qstart := applescript_quote(start)
	defer delete(qstart)
	script: string
	if start != "" {
		script = fmt.aprintf(
			`POSIX path of (choose folder with prompt %s default location POSIX file %s)`,
			qtitle, qstart,
		)
	} else {
		script = fmt.aprintf(
			`POSIX path of (choose folder with prompt %s)`,
			qtitle,
		)
	}
	defer delete(script)
	path, ok := run_osascript_dialog(script)
	if !ok {
		return "", false
	}
	// AppleScript's `POSIX path of (choose folder)` appends a trailing '/'.
	for len(path) > 1 && path[len(path) - 1] == '/' {
		trimmed := strings.clone(path[:len(path) - 1])
		delete(path)
		path = trimmed
	}
	return path, true
}
