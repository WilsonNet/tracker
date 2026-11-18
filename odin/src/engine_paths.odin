// Project path handling for open / save-as and recent projects.
// Kept outside engine.odin so the core device code stays focused.

package main

import "core:fmt"
import "core:os"

import ui "ui"

@(private)
copy_file :: proc(src, dst: string) -> bool {
	data, err := os.read_entire_file(src, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)
	if werr := os.write_entire_file(dst, data); werr != nil {
		return false
	}
	return true
}

// Points the engine at a new session/project directory, freeing the old paths.
engine_retarget :: proc(e: ^Engine, session_dir, project_path: string) -> bool {
	if e.rec.active || e.play.active {
		return false
	}
	if session_dir == "" || project_path == "" {
		return false
	}
	if !ensure_dir(session_dir) {
		return false
	}
	new_session := fmt.aprintf("%s", session_dir)
	new_project := fmt.aprintf("%s", project_path)
	new_take := fmt.aprintf("%s/take.raw", session_dir)
	new_bounce := fmt.aprintf("%s/bounce.wav", session_dir)

	delete(e.session_dir)
	delete(e.project_path)
	delete(e.take_path)
	delete(e.bounce_path)
	e.session_dir = new_session
	e.project_path = new_project
	e.take_path = new_take
	e.bounce_path = new_bounce
	return true
}

// Saves the current project into `new_dir`, copying the current takes so the
// new project is self-contained. Returns false without changing the engine if
// anything fails midway.
engine_save_as :: proc(a: ^ui.App, e: ^Engine, new_dir: string) -> bool {
	if e.rec.active || e.play.active {
		ui.status_buf_set(a, "stop transport before save as")
		return false
	}
	if !ensure_dir(new_dir) {
		ui.status_buf_set(a, "cannot create save-as directory")
		return false
	}
	for i in 1 ..= 4 {
		src := fmt.tprintf("%s/track%d.wav", e.session_dir, i)
		if !os.exists(src) {
			continue
		}
		dst := fmt.tprintf("%s/track%d.wav", new_dir, i)
		if !copy_file(src, dst) {
			ui.status_buf_set(a, "cannot copy take to new project")
			return false
		}
	}
	if !project_save(a, fmt.tprintf("%s/project.json", new_dir)) {
		ui.status_buf_set(a, "save as failed")
		return false
	}
	if !engine_retarget(e, new_dir, fmt.tprintf("%s/project.json", new_dir)) {
		ui.status_buf_set(a, "cannot retarget project")
		return false
	}
	ui.status_buf_set(a, "project saved as")
	return true
}

// Opens a project.json from any directory and reloads its tracks.
engine_open_project :: proc(a: ^ui.App, e: ^Engine, path: string) -> bool {
	if e.rec.active || e.play.active {
		ui.status_buf_set(a, "stop transport before opening a project")
		return false
	}
	dir := parent_dir(path)
	if !project_load(a, dir, path) {
		ui.status_buf_set(a, "cannot load project")
		return false
	}
	if !engine_retarget(e, dir, path) {
		ui.status_buf_set(a, "cannot use project directory")
		return false
	}
	e.sample_rate = a.sample_rate
	_ = engine_load_tracks(e, a)
	ui.status_buf_set(a, "project loaded")
	return true
}
