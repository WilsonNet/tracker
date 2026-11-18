// Small bridge helpers used by the SDL window.

package main

import ui "ui"

ui_sync_takes :: proc(a: ^ui.App, e: ^Engine) {
	for i in 0 ..< MAX_ENGINE_TRACKS {
		ui.app_set_takes(a, i, engine_take_count(e, i), engine_take_active(e, i))
	}
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
