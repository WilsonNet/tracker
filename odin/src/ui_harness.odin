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

import ui "ui"

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

run_ui_test :: proc(args: []string) -> bool {
	script_path, has_script := flag_value(args, "--script")
	if !has_script {
		fmt.eprintln("ui-test needs --script FILE.json")
		return false
	}
	out_dir := flag_string(args, "--out", "/tmp/tracker-ui-test")
	ensure_dir(out_dir)

	data, err := os.read_entire_file(script_path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", script_path)
		return false
	}
	defer delete(data)

	script: Harness_Script
	if uerr := json.unmarshal(data, &script); uerr != nil {
		fmt.eprintfln("invalid script %s: %v", script_path, uerr)
		return false
	}
	if len(script.actions) == 0 {
		fmt.eprintln("script has no actions")
		return false
	}
	width := script.width if script.width > 0 else 1180
	height := script.height if script.height > 0 else 760

	a: ui.App
	ui.app_init(&a, width, height)
	defer ui.app_destroy(&a)
	a.demo = script.demo
	if len(script.devices) > 0 {
		ui.app_set_devices(&a, script.devices, 0)
	}

	c: ui.Canvas
	ui.canvas_init(&c, width, height)
	defer ui.canvas_destroy(&c)

	results: [dynamic]Harness_Result
	defer delete(results)
	passed := 0
	failed := 0

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
			if !ui.app_drag_id(&a, action.id, action.dy) {
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
			for ch in action.text {
				ui.app_key(&a, .Char, u8(ch), ch >= 'A' && ch <= 'Z')
			}
			detail = fmt.tprintf("type %q", action.text)
		case "wait":
			frames := action.frames
			if frames <= 0 {
				frames = max(1, int(action.ms / 16.6667))
			}
			for _ in 0 ..< frames {
				ui.app_tick(&a, 1.0 / 60.0)
			}
			detail = fmt.tprintf("wait %d frames", frames)
		case "screenshot":
			name := action.name
			if name == "" {
				name = fmt.tprintf("shot-%02d", i)
			}
			path := fmt.tprintf("%s/%02d-%s.png", out_dir, i, name)
			ui.app_draw(&a, &c)
			if !ui.canvas_screenshot(&c, path) {
				ok = false
				detail = fmt.tprintf("screenshot failed: %s", path)
			} else {
				detail = fmt.tprintf("screenshot %s", path)
			}
		case "assert":
			value, has := ui.app_value(&a, action.path)
			if !has {
				ok = false
				detail = fmt.tprintf("unknown path %q", action.path)
			} else if action.equals != "" {
				ok = value == action.equals
				detail = fmt.tprintf("%s = %q (want %q)", action.path, value, action.equals)
			} else if action.has_min || action.has_max {
				if parsed, pok := strconv.parse_f32(value); pok {
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
			} else {
				detail = fmt.tprintf("%s = %q", action.path, value)
			}
		case "resize":
			w := action.width if action.width > 0 else a.width
			h := action.height if action.height > 0 else a.height
			ui.app_resize(&a, w, h)
			ui.canvas_resize(&c, w, h)
			detail = fmt.tprintf("resize %dx%d", w, h)
		case:
			ok = false
			detail = fmt.tprintf("unknown action %q", action.type)
		}

		ui.app_layout(&a)
		status := "PASS" if ok else "FAIL"
		fmt.printfln("[%s] %02d  %s", status, i, detail)
		append(&results, Harness_Result{i, ok, detail})
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
	if encoded, merr := json.marshal(report, json.Marshal_Options{pretty = true}); merr == nil {
		_ = os.write_entire_file(fmt.tprintf("%s/report.json", out_dir), encoded)
		delete(encoded)
	}

	fmt.printfln("%s: %d passed, %d failed  (%s)", script.name, passed, failed, out_dir)
	return failed == 0
}
