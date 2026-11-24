// Small bridge helpers used by the SDL window.

package main

import ui "ui"

ui_sync_takes :: proc(a: ^ui.App, e: ^Engine) {
	for i in 0 ..< MAX_ENGINE_TRACKS {
		ui.app_set_takes(a, i, engine_take_count(e, i), engine_take_active(e, i))
	}
	engine_sync_tape_length(e, a)
}

// Persist take metadata and the current mix state after a state-changing
// operation. Take files are already on disk; the project.json is what makes
// them survive a restart.
window_save_project :: proc(a: ^ui.App, e: ^Engine) -> bool {
	if project_save_with_takes(a, e.takes[:], e.project_path) {
		a.dirty = false
		return true
	}
	return false
}

ui_persist_recent :: proc(a: ^ui.App, path: string) {
	if path == "" {
		return
	}
	paths := make([]string, a.recent_count)
	defer delete(paths)
	for i in 0 ..< a.recent_count {
		paths[i] = ui.app_recent_path(a, i)
	}
	_ = recent_save(path, paths)
}

ui_load_recent :: proc(a: ^ui.App, path: string) {
	paths := recent_load(path)
	defer recent_free(paths)
	ui.app_set_recent(a, paths)
}

ui_add_recent :: proc(a: ^ui.App, path, store: string) {
	ui.app_add_recent(a, path)
	ui_persist_recent(a, store)
}

// Writes settings.json after a folder or accessibility change. Persistence
// failure is reported once per change, not retried every frame.
ui_persist_settings :: proc(a: ^ui.App, store: string) {
	mode := "free" if a.timing_mode == .Free else "grid"
	if !settings_save(store, ui.app_save_dir(a), a.high_contrast, a.reduced_motion, ui.app_preroll_seconds(a), a.preroll_grid_idx, mode) {
		ui.status_buf_set(a, "cannot save settings")
	}
	a.settings_dirty = false
}
