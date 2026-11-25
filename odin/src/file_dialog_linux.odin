#+build linux
// Native Linux file pickers via the desktop's dialog helper (zenity -> kdialog).
package main

import "core:fmt"
import "core:os"
import "core:strings"

@(private)
run_dialog :: proc(argv: []string) -> (string, bool) {
	hidden := os.get_env("VUI_HIDDEN", context.allocator)
	defer delete(hidden)
	if hidden == "1" {
		return "", false
	}
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

@(private)
platform_pick_project_open :: proc(start: string) -> (string, bool) {
	filter := "Tracker-FX project | *.json"
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--title=Open Tracker-FX Project",
			fmt.tprintf("--filename=%s/", start),
			fmt.tprintf("--file-filter=%s", filter),
		}
	} else {
		argv = []string{"kdialog", "--getopenfilename", start, "*.json"}
	}
	return run_dialog(argv)
}

@(private)
platform_pick_project_save :: proc(start: string) -> (string, bool) {
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--save", "--confirm-overwrite",
			"--title=Save Tracker-FX Project As",
			fmt.tprintf("--filename=%s/project.json", start),
			"--file-filter=Tracker-FX project | *.json",
		}
	} else {
		argv = []string{"kdialog", "--getsavefilename", fmt.tprintf("%s/project.json", start), "*.json"}
	}
	return run_dialog(argv)
}

@(private)
platform_pick_mix_save :: proc(start: string) -> (string, bool) {
	argv: []string
	if zenity_available() {
		argv = []string{
			"zenity", "--file-selection", "--save", "--confirm-overwrite",
			"--title=Render Mix to WAV",
			fmt.tprintf("--filename=%s/mix.wav", start),
			"--file-filter=WAV audio | *.wav",
		}
	} else {
		argv = []string{"kdialog", "--getsavefilename", fmt.tprintf("%s/mix.wav", start), "*.wav"}
	}
	return run_dialog(argv)
}

@(private)
platform_pick_directory :: proc(title, start: string) -> (string, bool) {
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
