// `ui-test`: the native replacement for Playwright.
//
// Drives the real App state machine with semantic targets ("arm.0",
// "knob.eq.low"), keyboard actions, assertions and PNG screenshots. No browser,
// no webview, no socket bridge — and it runs in milliseconds.

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import ui "ui"

HARNESS_MAX_ACTIONS :: 10_000
HARNESS_MAX_DEVICES :: 64
HARNESS_MAX_WAIT_FRAMES :: 600_000
HARNESS_MAX_WAIT_MS :: 3_600_000
HARNESS_MAX_DRAG :: 10_000
HARNESS_MAX_TYPE_CHARS :: 4_096
HARNESS_MAX_SHOT_NAME :: 96

Harness_Action :: struct {
	type:   string  `json:"type"`,
	id:     string  `json:"id"`,
	key:    string  `json:"key"`,
	text:   string  `json:"text"`,
	name:   string  `json:"name"`,
	path:   string  `json:"path"`,
	equals: string  `json:"equals"`,
	min:    f32     `json:"min"`,
	max:    f32     `json:"max"`,
	has_min: bool   `json:"hasMin"`,
	has_max: bool   `json:"hasMax"`,
	dy:     f32     `json:"dy"`,
	frames: int     `json:"frames"`,
	ms:     f32     `json:"ms"`,
	width:  int     `json:"width"`,
	height: int     `json:"height"`,
}

Harness_Script :: struct {
	name:    string           `json:"name"`,
	width:   int              `json:"width"`,
	height:  int              `json:"height"`,
	demo:    bool             `json:"demo"`,
	devices: []string         `json:"devices"`,
	recent:  []string         `json:"recent"`,
	actions: []Harness_Action `json:"actions"`,
}

Harness_Result :: struct {
	index:  int    `json:"index"`,
	ok:     bool   `json:"ok"`,
	detail: string `json:"detail"`,
}

Harness_Report :: struct {
	name:    string           `json:"name"`,
	passed:  int              `json:"passed"`,
	failed:  int              `json:"failed"`,
	results: []Harness_Result `json:"results"`,
}

@(private)
harness_script_destroy :: proc(s: ^Harness_Script) {
	if len(s.name) > 0 {
		delete(s.name)
		s.name = ""
	}
	for device in s.devices {
		if len(device) > 0 {
			delete(device)
		}
	}
	delete(s.devices)
	s.devices = nil
	for path in s.recent {
		if len(path) > 0 {
			delete(path)
		}
	}
	delete(s.recent)
	s.recent = nil
	for &action in s.actions {
		for field in ([]^string{&action.type, &action.id, &action.key, &action.text, &action.name, &action.path, &action.equals}) {
			if len(field^) > 0 {
				delete(field^)
				field^ = ""
			}
		}
	}
	delete(s.actions)
	s.actions = nil
}

@(private)
is_ascii :: proc(s: string) -> bool {
	for b in s {
		if b >= 0x80 {
			return false
		}
	}
	return true
}

@(private)
harness_shot_name_is_safe :: proc(name: string) -> bool {
	if len(name) > HARNESS_MAX_SHOT_NAME {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == '\\' || name[i] == 0 {
			return false
		}
	}
	return true
}

run_ui_test :: proc(args: []string) -> bool {
	if !validate_flags(args, []string{"--script", "--out", "--scale"}, nil) {
		return false
	}
	script_path, has_script := flag_value(args, "--script")
	if !has_script {
		fmt.eprintln("ui-test needs --script FILE.json")
		return false
	}
	scale, scale_ok := ui_scale_from_flags(args, "--scale")
	if !scale_ok {
		return false
	}
	out_dir := flag_string(args, "--out", "/tmp/tracker-ui-test")
	if !ensure_dir(out_dir) {
		return false
	}

	data, err := os.read_entire_file(script_path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", script_path)
		return false
	}
	defer delete(data)

	script: Harness_Script
	defer harness_script_destroy(&script)
	if uerr := json.unmarshal(data, &script); uerr != nil {
		fmt.eprintfln("invalid script %s: %v", script_path, uerr)
		return false
	}
	if len(script.actions) == 0 {
		fmt.eprintln("script has no actions")
		return false
	}
	if len(script.actions) > HARNESS_MAX_ACTIONS {
		fmt.eprintfln("script has too many actions (%d, max %d)", len(script.actions), HARNESS_MAX_ACTIONS)
		return false
	}
	if len(script.devices) > HARNESS_MAX_DEVICES {
		fmt.eprintfln("script has too many devices (%d, max %d)", len(script.devices), HARNESS_MAX_DEVICES)
		return false
	}
	width := script.width if script.width > 0 else 1180
	height := script.height if script.height > 0 else 760
	if width < MIN_CLI_DIM || width > MAX_CLI_DIM || height < MIN_CLI_DIM || height > MAX_CLI_DIM {
		fmt.eprintfln("script size must be between %d and %d", MIN_CLI_DIM, MAX_CLI_DIM)
		return false
	}

	a: ui.App
	ui.app_init(&a, width, height)
	defer ui.app_destroy(&a)
	a.demo = script.demo
	if len(script.devices) > 0 {
		ui.app_set_devices(&a, script.devices, 0)
	}
	if len(script.recent) > 0 {
		ui.app_set_recent(&a, script.recent)
	}

	c: ui.Canvas
	ui.canvas_init(&c, ui.canvas_pixel_size(width, scale), ui.canvas_pixel_size(height, scale), scale)
	defer ui.canvas_destroy(&c)

	results: [dynamic]Harness_Result
	defer {
		for r in results {
			if len(r.detail) > 0 {
				delete(r.detail)
			}
		}
		delete(results)
	}
	passed := 0
	failed := 0

	// A failed action is recorded and the run continues so report.json lists
	// every mismatch instead of stopping at the first one. The final exit code
	// is non-zero whenever anything failed.
	for action, i in script.actions {
		ok := true
		detail := ""
		switch action.type {
		case "click":
			if !ui.app_click_id(&a, action.id) {
				ok = false
				detail = fmt.tprintf("no target %q", action.id)
			} else {
				detail = fmt.tprintf("click %s", action.id)
			}
		case "drag":
			if !f32_is_finite(action.dy) || abs(action.dy) > HARNESS_MAX_DRAG {
				ok = false
				detail = fmt.tprintf("invalid drag distance %v", action.dy)
			} else if !ui.app_drag_id(&a, action.id, action.dy) {
				ok = false
				detail = fmt.tprintf("no target %q", action.id)
			} else {
				detail = fmt.tprintf("drag %s by %.0f", action.id, action.dy)
			}
		case "key":
			if !ui.app_key_name(&a, action.key) {
				ok = false
				detail = fmt.tprintf("unknown key %q", action.key)
			} else {
				detail = fmt.tprintf("key %s", action.key)
			}
		case "type":
			if len(action.text) > HARNESS_MAX_TYPE_CHARS {
				ok = false
				detail = fmt.tprintf("type text too long (%d bytes, max %d)", len(action.text), HARNESS_MAX_TYPE_CHARS)
			} else if !is_ascii(action.text) {
				ok = false
				detail = fmt.tprintf("type text must be ASCII")
			} else {
				for ch in action.text {
					ui.app_key(&a, .Char, u8(ch), ch >= 'A' && ch <= 'Z')
				}
				detail = fmt.tprintf("type %q", action.text)
			}
		case "wait":
			frames := action.frames
			if frames <= 0 {
				if !f32_is_finite(action.ms) || action.ms < 0 || action.ms > HARNESS_MAX_WAIT_MS {
					ok = false
					detail = fmt.tprintf("invalid wait duration %v ms", action.ms)
				} else {
					frames = max(1, int(action.ms / 16.6667))
				}
			}
			if ok {
				if frames > HARNESS_MAX_WAIT_FRAMES {
					ok = false
					detail = fmt.tprintf("wait too long (%d frames, max %d)", frames, HARNESS_MAX_WAIT_FRAMES)
				} else {
					for _ in 0 ..< frames {
						ui.app_tick(&a, 1.0 / 60.0)
					}
					detail = fmt.tprintf("wait %d frames", frames)
				}
			}
		case "screenshot":
			name := action.name
			if name == "" {
				name = fmt.tprintf("shot-%02d", i)
			}
			if !harness_shot_name_is_safe(name) {
				ok = false
				detail = fmt.tprintf("invalid screenshot name %q", name)
			} else {
				path := fmt.tprintf("%s/%02d-%s.png", out_dir, i, name)
				ui.app_draw(&a, &c)
				if !ui.canvas_screenshot(&c, path) {
					ok = false
					detail = fmt.tprintf("screenshot failed: %s", path)
				} else {
					detail = fmt.tprintf("screenshot %s", path)
				}
			}
		case "assert":
			value, has := ui.app_value(&a, action.path)
			if !has {
				ok = false
				detail = fmt.tprintf("unknown path %q", action.path)
			} else if action.equals == "" && !action.has_min && !action.has_max {
				ok = false
				detail = fmt.tprintf("assert %q needs equals, min or max", action.path)
			} else if action.equals != "" {
				ok = value == action.equals
				detail = fmt.tprintf("%s = %q (want %q)", action.path, value, action.equals)
			} else {
				bad_bound := (action.has_min && !f32_is_finite(action.min)) || (action.has_max && !f32_is_finite(action.max))
				if bad_bound || (action.has_min && action.has_max && action.min > action.max) {
					ok = false
					detail = fmt.tprintf("invalid assertion range %.2f..%.2f", action.min, action.max)
				} else if parsed, pok := strconv.parse_f32(value); pok {
					if action.has_min && parsed < action.min {
						ok = false
					}
					if action.has_max && parsed > action.max {
						ok = false
					}
					if action.has_min && action.has_max {
						detail = fmt.tprintf("%s = %s (range %.2f..%.2f)", action.path, value, action.min, action.max)
					} else if action.has_min {
						detail = fmt.tprintf("%s = %s (min %.2f)", action.path, value, action.min)
					} else {
						detail = fmt.tprintf("%s = %s (max %.2f)", action.path, value, action.max)
					}
				} else {
					ok = false
					detail = fmt.tprintf("%s = %q is not numeric", action.path, value)
				}
			}
		case "resize":
			w := action.width if action.width > 0 else a.width
			h := action.height if action.height > 0 else a.height
			if w < MIN_CLI_DIM || w > MAX_CLI_DIM || h < MIN_CLI_DIM || h > MAX_CLI_DIM {
				ok = false
				detail = fmt.tprintf("resize %dx%d is outside %d..%d", w, h, MIN_CLI_DIM, MAX_CLI_DIM)
			} else {
				ui.app_resize(&a, w, h)
				ui.canvas_resize(&c, ui.canvas_pixel_size(w, scale), ui.canvas_pixel_size(h, scale))
				detail = fmt.tprintf("resize %dx%d @ %.2fx", w, h, scale)
			}
		case:
			ok = false
			detail = fmt.tprintf("unknown action %q", action.type)
		}

		ui.app_layout(&a)
		status := "PASS" if ok else "FAIL"
		fmt.printfln("[%s] %02d  %s", status, i, detail)
		append(&results, Harness_Result{i, ok, strings.clone(detail)})
		if ok {
			passed += 1
		} else {
			failed += 1
		}
	}

	report := Harness_Report {
		name = script.name,
		passed = passed,
		failed = failed,
		results = results[:],
	}
	encoded, merr := json.marshal(report, json.Marshal_Options{pretty = true})
	if merr != nil {
		fmt.eprintfln("cannot encode report: %v", merr)
		return false
	}
	defer delete(encoded)
	if !write_file_atomic(fmt.tprintf("%s/report.json", out_dir), encoded) {
		fmt.eprintfln("cannot write %s/report.json", out_dir)
		return false
	}

	fmt.printfln("%s: %d passed, %d failed  (%s)", script.name, passed, failed, out_dir)
	return failed == 0
}
