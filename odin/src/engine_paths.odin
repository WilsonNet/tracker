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
	return engine_save_as_to(a, e, fmt.tprintf("%s/project.json", new_dir))
}

// Saves a self-contained project at an explicit .json path (used by the native
// save-as picker), copying takes next to it.
engine_save_as_to :: proc(a: ^ui.App, e: ^Engine, project_path: string) -> bool {
	if e.rec.active || e.play.active {
		ui.status_buf_set(a, "stop transport before save as")
		return false
	}
	dir := parent_dir(project_path)
	if !ensure_dir(dir) {
		ui.status_buf_set(a, "cannot create save-as directory")
		return false
	}
	if save_dir_occupied(dir) {
		ui.status_buf_set(a, "folder already contains a tracker project")
		return false
	}
	for i in 1 ..= MAX_ENGINE_TRACKS {
		src := fmt.tprintf("%s/track%d.wav", e.session_dir, i)
		if !os.exists(src) {
			continue
		}
		dst := fmt.tprintf("%s/track%d.wav", dir, i)
		if src != dst && !copy_file(src, dst) {
			ui.status_buf_set(a, "cannot copy take to new project")
			return false
		}
	}
	for list in e.takes {
		for take in list.takes {
			if take.file == "" {
				continue
			}
			src := fmt.tprintf("%s/%s", e.session_dir, take.file)
			dst := fmt.tprintf("%s/%s", dir, take.file)
			if src == dst || !os.exists(src) {
				continue
			}
			if !copy_file(src, dst) {
				ui.status_buf_set(a, "cannot copy take to new project")
				return false
			}
		}
	}
	if !project_save_with_takes(a, e.takes[:], project_path) {
		ui.status_buf_set(a, "save as failed")
		return false
	}
	if !engine_retarget(e, dir, project_path) {
		ui.status_buf_set(a, "cannot retarget project")
		return false
	}
	ui.status_buf_set(a, "project saved as")
	return true
}

// True when a folder already holds tracker output. Used to avoid silently
// overwriting another project when the user picks a save folder.
@(private)
save_dir_occupied :: proc(dir: string) -> bool {
	if os.exists(fmt.tprintf("%s/project.json", dir)) {
		return true
	}
	for i in 1 ..= MAX_ENGINE_TRACKS {
		if os.exists(fmt.tprintf("%s/track%d.wav", dir, i)) {
			return true
		}
	}
	return false
}

// Moves the current project into `new_dir` and makes it the default save
// folder. Existing takes are copied first, so the new folder is
// self-contained; the old folder is left untouched as a recovery copy.
engine_apply_save_dir :: proc(a: ^ui.App, e: ^Engine, new_dir: string) -> bool {
	if a == nil || e == nil || new_dir == "" {
		return false
	}
	normalized, valid := normalize_save_dir(new_dir)
	if !valid {
		ui.status_buf_set(a, "project folder must be an absolute path")
		return false
	}
	defer delete(normalized)
	target := normalized
	if target == e.session_dir {
		ui.status_buf_set(a, "project folder unchanged")
		return true
	}
	if e.rec.active || e.play.active {
		ui.status_buf_set(a, "stop transport before changing project folder")
		return false
	}
	if !ensure_dir(target) {
		ui.status_buf_set(a, "cannot create project folder")
		return false
	}
	if save_dir_occupied(target) {
		ui.status_buf_set(a, "folder already contains a tracker project")
		return false
	}
	path := fmt.tprintf("%s/project.json", target)
	if !engine_save_as_to(a, e, path) {
		return false
	}
	ui.status_buf_set(a, "project folder updated")
	return true
}

// Opens a project.json from any directory and reloads its tracks.
engine_open_project :: proc(a: ^ui.App, e: ^Engine, path: string) -> bool {
	if e.rec.active || e.play.active {
		ui.status_buf_set(a, "stop transport before opening a project")
		return false
	}
	dir := parent_dir(path)
	if !project_load_with_takes(a, dir, path, e.takes[:]) {
		ui.status_buf_set(a, "cannot load project")
		return false
	}
	if !engine_retarget(e, dir, path) {
		ui.status_buf_set(a, "cannot use project directory")
		return false
	}
	e.sample_rate = a.sample_rate
	engine_match_device(e, a, ui.app_device(a))
	engine_set_latency_ms(e, a.latency_ms)
	_ = engine_load_tracks(e, a)
	ui.app_history_reset(a)
	ui.status_buf_set(a, "project loaded")
	return true
}
