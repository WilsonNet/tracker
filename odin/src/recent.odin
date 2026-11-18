// Recent-project list persisted under XDG_CONFIG_HOME (or ~/.config).
//
// Paths are owned strings; callers use recent_free.

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

RECENT_LIMIT :: 10

Recent_File :: struct {
	projects: []string `json:"projects"`,
}

recent_config_dir :: proc() -> string {
	if xdg := os.get_env("XDG_CONFIG_HOME", context.allocator); xdg != "" {
		defer delete(xdg)
		return fmt.aprintf("%s/tracker", xdg)
	}
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	if home == "" {
		return fmt.aprintf(".config/tracker")
	}
	return fmt.aprintf("%s/.config/tracker", home)
}

recent_config_path :: proc() -> string {
	dir := recent_config_dir()
	defer delete(dir)
	return fmt.aprintf("%s/recent.json", dir)
}

recent_free :: proc(paths: []string) {
	for path in paths {
		delete(path)
	}
	delete(paths)
}

recent_load :: proc(path: string) -> []string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	defer delete(data)
	doc: Recent_File
	if uerr := json.unmarshal(data, &doc); uerr != nil {
		return nil
	}
	if len(doc.projects) > RECENT_LIMIT {
		for i in RECENT_LIMIT ..< len(doc.projects) {
			delete(doc.projects[i])
		}
		doc.projects = doc.projects[:RECENT_LIMIT]
	}
	return doc.projects
}

recent_save :: proc(path: string, projects: []string) -> bool {
	doc := Recent_File{projects = projects}
	data, err := json.marshal(doc, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fmt.eprintfln("recent marshal: %v", err)
		return false
	}
	defer delete(data)
	dir := recent_config_dir()
	defer delete(dir)
	if !ensure_dir(dir) {
		return false
	}
	return write_file_atomic(path, data)
}

// Returns a new list with `path` first, de-duplicated, capped at RECENT_LIMIT.
// The caller owns the returned strings and slice.
recent_add :: proc(projects: []string, path: string) -> []string {
	out := make([dynamic]string, 0, min(len(projects) + 1, RECENT_LIMIT))
	append(&out, strings.clone(path))
	for p in projects {
		if p == path {
			continue
		}
		if len(out) >= RECENT_LIMIT {
			break
		}
		append(&out, strings.clone(p))
	}
	return out[:]
}
