// Native Linux file pickers via the desktop's dialog helper.
//
// Prefers zenity (GNOME/GTK, present on this machine), falls back to kdialog.
// The dialog runs as a child process; the UI thread blocks only while the user
// is choosing a path, which is the expected modal behaviour.

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

@(private)
run_dialog :: proc(argv: []string) -> (string, bool) {
	command := argv
	forced: [dynamic]string
	defer delete(forced)
	driver := os.get_env("SDL_VIDEODRIVER", context.allocator)
	defer delete(driver)
	if driver == "x11" {
		// SDL is on X11 (e.g. Xvfb in tests). GTK would otherwise prefer
		// Wayland and open the dialog on a different display.
		append(&forced, "env", "GDK_BACKEND=x11")
		for arg in argv {
			append(&forced, arg)
		}
		command = forced[:]
	}
	desc := os.Process_Desc {
		command = command,
	}
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
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
zenity_available :: proc() -> bool {
	state, out, err, e := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", "command -v zenity"}}, context.allocator)
	defer delete(out)
	defer delete(err)
	return e == nil && state.exited && state.exit_code == 0
}

// Opens a project JSON file. Returns an owned string.
pick_project_open :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	start := home if home != "" else "."
	filter := "Tracker project | *.json"
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--title=Open Tracker Project",
			fmt.tprintf("--filename=%s/", start),
			fmt.tprintf("--file-filter=%s", filter),
		}
	} else {
		argv = []string{"kdialog", "--getopenfilename", start, "*.json"}
	}
	return run_dialog(argv)
}

// Save-as path (may not exist yet). Returns an owned string.
pick_project_save :: proc() -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	start := home if home != "" else "."
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--save", "--confirm-overwrite",
			"--title=Save Tracker Project As",
			fmt.tprintf("--filename=%s/project.json", start),
			"--file-filter=Tracker project | *.json",
		}
	} else {
		argv = []string{"kdialog", "--getsavefilename", fmt.tprintf("%s/project.json", start), "*.json"}
	}
	path, ok := run_dialog(argv)
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

// Opens a session directory. Returns an owned string.
pick_session_open :: proc() -> (string, bool) {
	return pick_directory("Open Tracker Session")
}

// Chooses the folder where project.json, takes and bounces are written.
pick_save_dir :: proc() -> (string, bool) {
	return pick_directory("Choose Tracker Project Folder")
}

@(private)
pick_directory :: proc(title: string) -> (string, bool) {
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	start := home if home != "" else "."
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--directory",
			fmt.tprintf("--title=%s", title),
			fmt.tprintf("--filename=%s/", start),
		}
	} else {
		argv = []string{"kdialog", "--getexistingdirectory", start}
	}
	return run_dialog(argv)
}
