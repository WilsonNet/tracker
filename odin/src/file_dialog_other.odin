#+build !linux
#+build !darwin
package main

@(private)
platform_pick_project_open :: proc(start: string) -> (string, bool) {
	return "", false
}

@(private)
platform_pick_project_save :: proc(start: string) -> (string, bool) {
	return "", false
}

@(private)
platform_pick_mix_save :: proc(start: string) -> (string, bool) {
	return "", false
}

@(private)
platform_pick_directory :: proc(title, start: string) -> (string, bool) {
	return "", false
}
