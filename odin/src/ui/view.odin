// Window UI built with vinland-ui. It follows DESIGN.md: a dark instrument
// panel, JetBrains Mono, one amber signal colour, flat 1px-bordered surfaces.
// The App model, commands and
// keyboard handling are shared with the headless Cairo harness; this file only
// turns App state into an element tree and routes pointer input back into it.

package ui

import "core:fmt"
import "core:math"
import vui "vinland:vui"

JBM_REGULAR :: #load("../../assets/fonts/JetBrainsMono-Regular.ttf")
JBM_MEDIUM :: #load("../../assets/fonts/JetBrainsMono-Medium.ttf")
JBM_SEMIBOLD :: #load("../../assets/fonts/JetBrainsMono-SemiBold.ttf")
JBM_BOLD :: #load("../../assets/fonts/JetBrainsMono-Bold.ttf")

View_Drag_Kind :: enum {
	None,
	Fader,
	Pan,
	Knob,
}

View_Drag :: struct {
	kind:   View_Drag_Kind,
	index:  int,
	target: Knob_Target,
	start:  [2]f32,
	norm:   f32,
}

View :: struct {
	drag:          View_Drag,
	ic_play:       vui.Icon,
	ic_close:      vui.Icon,
	ic_left:       vui.Icon,
	ic_right:      vui.Icon,
	high_contrast: bool,
	fine:          bool, // Shift held: fine knob drag / wheel
	tight:         bool, // FX rack open in a short window: compact strips + rack
	knob_wheel:    bool, // a rack knob consumed this frame's wheel
	focus_rect:    vui.Rect, // module holding the keyboard focus (last frame)
	last_focus:    int,
	chain_w:       f32,
}

@(private = "file")
PLAY_PATH := [?]vui.Icon_Path{{d = "M5 3.2C5 2.4 5.9 1.9 6.6 2.4L16.1 9.2C16.7 9.6 16.7 10.4 16.1 10.8L6.6 17.6C5.9 18.1 5 17.6 5 16.8Z"}}
@(private = "file")
CLOSE_PATH := [?]vui.Icon_Path{{d = "M5.3 4.2 10 8.9 14.7 4.2 15.8 5.3 11.1 10 15.8 14.7 14.7 15.8 10 11.1 5.3 15.8 4.2 14.7 8.9 10 4.2 5.3Z"}}
@(private = "file")
LEFT_PATH := [?]vui.Icon_Path{{d = "M12.3 4.2 13.4 5.3 8.7 10 13.4 14.7 12.3 15.8 6.5 10Z"}}
@(private = "file")
RIGHT_PATH := [?]vui.Icon_Path{{d = "M7.7 4.2 13.5 10 7.7 15.8 6.6 14.7 11.3 10 6.6 5.3Z"}}

view_init :: proc(v: ^View, ctx: ^vui.Context) {
	v^ = {}
	f := &ctx.fonts
	vui.font_register(f, "JetBrains Mono", JBM_REGULAR, 400)
	vui.font_register(f, "JetBrains Mono", JBM_MEDIUM, 500)
	vui.font_register(f, "JetBrains Mono", JBM_SEMIBOLD, 600)
	vui.font_register(f, "JetBrains Mono", JBM_BOLD, 700)
	ctx.theme.fonts["mono"] = "JetBrains Mono"
	ctx.theme.default_font = "mono"
	v.ic_play = vui.icon_register(ctx, "tracker-play", {20, 20}, PLAY_PATH[:])
	v.ic_close = vui.icon_register(ctx, "tracker-close", {20, 20}, CLOSE_PATH[:])
	v.ic_left = vui.icon_register(ctx, "tracker-left", {20, 20}, LEFT_PATH[:])
	v.ic_right = vui.icon_register(ctx, "tracker-right", {20, 20}, RIGHT_PATH[:])
	view_theme(&ctx.theme, false)
	vui.set_dark(true)
}

// Design tokens from src/styles/tokens.css (oklch). High contrast lifts the
// secondary inks and the hairlines; the amber identity stays put.
view_theme :: proc(t: ^vui.Theme, high_contrast: bool) {
	set :: proc(t: ^vui.Theme, name: string, c: vui.Color) {
		vui.theme_set_color(t, name, c, c)
	}
	hc := high_contrast
	set(t, "canvas", vui.oklch(0.07, 0, 0))
	set(t, "panel", vui.oklch(0.125, 0, 0))
	set(t, "panel-raised", vui.oklch(0.175, 0, 0))
	set(t, "panel-hover", vui.oklch(0.15, 0, 0))
	set(t, "ink", vui.oklch(0.97 if hc else 0.93, 0, 0))
	set(t, "ink-dim", vui.oklch(0.82 if hc else 0.65, 0, 0))
	set(t, "ink-muted", vui.oklch(0.68 if hc else 0.48, 0, 0))
	set(t, "sig", vui.oklch(0.73, 0.157, 57))
	set(t, "sig-hi", vui.oklch(0.80, 0.18, 57))
	set(t, "sig-dim", vui.oklch(0.50, 0.09, 57))
	set(t, "sig-bg", vui.oklch(0.20, 0.04, 57))
	set(t, "rec", vui.oklch(0.50, 0.20, 20))
	set(t, "rec-hi", vui.oklch(0.55, 0.22, 20))
	set(t, "rec-bg", vui.oklch(0.18, 0.06, 20))
	set(t, "cue", vui.oklch(0.55, 0.12, 200))
	set(t, "cue-bg", vui.oklch(0.18, 0.04, 200))
	set(t, "line", vui.oklch(0.34 if hc else 0.22, 0, 0))
	set(t, "line-subtle", vui.oklch(0.26 if hc else 0.15, 0, 0))
	set(t, "line-sig", vui.oklch(0.40, 0.06, 57))
	vui.theme_changed()
}

@(private = "file")
tok :: proc(name: string) -> vui.Color {
	return vui.theme().colors[name].dark
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

view_frame :: proc(a: ^App, v: ^View) {
	ctx := vui.ctx_get()
	if v.high_contrast != a.high_contrast {
		v.high_contrast = a.high_contrast
		view_theme(&ctx.theme, a.high_contrast)
	}
	// keyboard focus in the FX rack indexes the model's knob/toggle lists
	app_layout(a)
	a.mouse_x = ctx.input.mouse.x
	a.mouse_y = ctx.input.mouse.y
	// The window consumes SDL key events before vinland sees them, so
	// ctx.input.mods never carries a physical Shift; ui_window keeps
	// a.shift_down current. Synthetic (vui-ctl) modifiers arrive via mods.
	v.fine = a.shift_down || .Shift in ctx.input.mods
	// With the 266px rack open, windows shorter than ~700px (down to the
	// 620px minimum) cannot fit a full strip: the take row slid under the
	// rack. Drop the level history and shorten the rack visuals instead.
	v.tight = a.mode == .Fx && ctx.viewport.y < TIGHT_HEIGHT
	view_drag_update(a, v)
	if .Left in ctx.input.released {
		v.drag.kind = .None
		app_history_commit(a)
	}

	if vui.div("relative flex h-full flex-col overflow-hidden bg-canvas text-[14px] leading-[1.4] text-ink") {
		view_transport(a, v)
		if vui.div("flex min-h-0 flex-1 gap-2 p-3") {
			for i in 0 ..< MAX_TRACKS {
				vui.push_id(i)
				view_track(a, v, i)
				vui.pop_id()
			}
		}
		if a.mode == .Fx {
			view_fx(a, v)
		}
		view_bounce_row(a, v)
		view_status(a)
		view_rhythm(a)

		if a.toast_time > 0 && a.mode != .Palette {
			vui.text(app_toast(a), "absolute bottom-28 right-4 z-40 rounded-[2px] border border-line-sig bg-panel-raised px-3 py-1.5 text-[11px] font-medium tracking-[0.04em] text-sig shadow-sm")
		}
		#partial switch a.mode {
		case .Palette:
			view_palette(a)
		case .Io:
			view_io(a)
		case .Recent:
			view_recent(a)
		case .Bounce:
			view_bounce_overlay(a)
		}
	}
}

// Busy = the window should keep rendering (meters, clock, toast, pulse).
view_busy :: proc(a: ^App) -> bool {
	return a.transport != .Stopped || a.monitor || a.bounce_active || a.toast_time > 0 || a.mode == .Palette || a.mode == .Recent || a.demo
}

@(private = "file")
view_drag_update :: proc(a: ^App, v: ^View) {
	ctx := vui.ctx_get()
	d := &v.drag
	if d.kind == .None || .Left not_in ctx.input.buttons {
		return
	}
	dy := ctx.input.mouse.y - d.start.y
	switch d.kind {
	case .Fader:
		n := clamp(d.norm - dy / 110, 0, 1)
		if a.tracks[d.index].level != n * 1.5 {
			a.tracks[d.index].level = n * 1.5
			app_history_note(a, "fader")
			app_touch(a)
		}
	case .Pan:
		n := clamp(d.norm - dy / 120, 0, 1)
		if a.tracks[d.index].pan != n * 2 - 1 {
			a.tracks[d.index].pan = n * 2 - 1
			app_history_note(a, "pan")
			app_touch(a)
		}
	case .Knob:
		lo, hi, lg := knob_spec(d.target.module, d.target.param)
		// Knob.tsx: 170 px for the full range, shift = 0.12x
		speed: f32 = 170 / 0.12 if v.fine else 170
		n := clamp(d.norm - dy / speed, 0, 1)
		app_set_knob(a, d.target, norm_to_value(n, lo, hi, lg))
	case .None:
	}
}

@(private = "file")
drag_begin :: proc(v: ^View, kind: View_Drag_Kind, index: int, target: Knob_Target, norm: f32) {
	ctx := vui.ctx_get()
	v.drag = View_Drag {
		kind   = kind,
		index  = index,
		target = target,
		start  = ctx.input.mouse,
		norm   = norm,
	}
}

// pressed this frame on the current element
@(private = "file")
press_started :: proc() -> bool {
	return vui.active() && .Left in vui.ctx_get().input.pressed
}

@(private = "file")
wheel_here :: proc() -> f32 {
	if !vui.hovered() {
		return 0
	}
	// vinland reports wheel travel in pixels (48 per notch, negative = up);
	// callers step per notch like Knob.tsx's onWheel
	return -vui.ctx_get().input.wheel.y / WHEEL_NOTCH
}

@(private = "file")
WHEEL_NOTCH :: 48

@(private = "file")
TIGHT_HEIGHT :: 700

// ---------------------------------------------------------------------------
// Transport bar
// ---------------------------------------------------------------------------

@(private = "file")
status_mode :: proc(a: ^App) -> (string, string) {
	if a.transport == .Recording {
		return "REC", "bg-rec text-ink"
	}
	switch a.mode {
	case .Normal:
		return "NORMAL", "bg-sig-bg text-sig"
	case .Fx:
		return "FX", "bg-sig-bg text-sig"
	case .Palette:
		return "COMMAND", "bg-cue-bg text-cue"
	case .Io:
		return "I/O", "bg-cue-bg text-cue"
	case .Bounce:
		return "BOUNCE", "bg-rec-bg text-rec-hi"
	case .Recent:
		return "RECENT", "bg-cue-bg text-cue"
	}
	return "NORMAL", "bg-sig-bg text-sig"
}

@(private = "file")
TBTN :: "flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-[2px] px-3 py-1 text-[12px] font-semibold tracking-[0.04em] transition-colors duration-150 focus-visible:ring-1 focus-visible:ring-sig"

@(private = "file")
view_transport :: proc(a: ^App, v: ^View) {
	if vui.div("flex shrink-0 items-center gap-6 border-b border-line bg-panel px-4 py-2") {
		mode, mcls := status_mode(a)
		vui.text(mode, vui.cx("shrink-0 whitespace-nowrap rounded-[2px] px-2 py-1 text-[12px] font-semibold leading-none tracking-[0.04em]", mcls))

		if vui.div("flex shrink-0 items-center gap-1") {
			rec := a.transport == .Recording
			if vui.button_box(vui.cx(TBTN, rec ? "animate-pulse bg-rec text-ink" : "text-rec hover:bg-rec-bg")) {
				vui.el("size-2 rounded-full bg-rec" if !rec else "size-2 rounded-full bg-ink")
				vui.text("REC")
				if vui.clicked() {
					app_toggle_record(a)
				}
			}
			playing := a.transport == .Playing
			if vui.button_box(vui.cx(TBTN, playing ? "bg-sig text-canvas" : "text-sig hover:bg-sig-bg")) {
				if playing {
					vui.el("size-2 rounded-[1px] bg-canvas")
				} else {
					vui.icon(v.ic_play, "size-3 text-sig")
				}
				vui.text("STOP" if playing else "PLAY")
				if vui.clicked() {
					app_toggle_play(a)
				}
			}
			if vui.button_box(vui.cx(TBTN, "text-ink-dim hover:bg-panel-hover hover:text-ink")) {
				vui.el("size-2 rounded-[1px] bg-ink-dim")
				vui.text("STOP")
				if vui.clicked() {
					app_execute(a, .Stop)
				}
			}
		}

		vui.text(timecode(a.frames, a.sample_rate), "ml-auto shrink-0 whitespace-nowrap text-[13px] tabular-nums tracking-[0.02em] text-ink")

		if vui.div("ml-4 flex shrink-0 items-center gap-2") {
			vui.text("BPM", "text-[12px] font-semibold tracking-[0.04em] text-ink-dim")
			if vui.div("flex h-7 items-center rounded-[2px] border border-line bg-canvas hover:border-sig-dim") {
				if w := wheel_here(); w != 0 {
					app_execute(a, .Bpm_Up if w > 0 else .Bpm_Down)
				}
				// button_box + flex centring: a bare text button pins its glyph
				// to the top of the h-full box
				if vui.button_box("flex h-full items-center px-1.5 text-[13px] text-ink-muted hover:text-sig") {
					vui.text("−")
					if vui.clicked() {
						app_execute(a, .Bpm_Down)
					}
				}
				vui.text(fmt.tprintf("%d", a.bpm), "w-9 text-center text-[13px] tabular-nums text-ink")
				if vui.button_box("flex h-full items-center px-1.5 text-[13px] text-ink-muted hover:text-sig") {
					vui.text("+")
					if vui.clicked() {
						app_execute(a, .Bpm_Up)
					}
				}
			}
		}

		if vui.div("ml-3 flex min-w-0 items-center gap-1") {
			mon := a.monitor
			if vui.button_box(vui.cx(TBTN, "border", mon ? "border-line-sig bg-sig-bg text-sig" : "border-line text-ink-dim hover:border-sig-dim hover:bg-panel-hover hover:text-ink")) {
				vui.el("size-1.5 rounded-full bg-sig shadow-[0_0_6px_var(--color-sig)]" if mon else "size-1.5 rounded-full bg-ink-muted")
				vui.text("MON ON" if mon else "MON")
				if vui.clicked() {
					app_execute(a, .Monitor)
				}
			}
			io := a.mode == .Io
			// the only transport item allowed to shrink: at the 900px minimum
			// with a long mode chip (COMMAND) the device name truncates
			// instead of the "I/O" label wrapping and growing the bar
			if vui.button_box(vui.cx(TBTN, "min-w-0 max-w-[240px] shrink border", io ? "border-line-sig bg-sig-bg text-sig" : "border-line text-ink-dim hover:border-ink-muted hover:bg-panel-hover hover:text-ink")) {
				vui.text("I/O")
				dev := app_device(a)
				if dev != "" {
					vui.text(dev, vui.cx("ml-0.5 min-w-0 max-w-[140px] shrink truncate border-l pl-1.5 text-[11px] font-normal tracking-normal", io ? "border-line-sig text-sig" : "border-line text-ink-muted"))
				}
				if vui.clicked() {
					app_execute(a, .Io)
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Track strip
// ---------------------------------------------------------------------------

@(private = "file")
track_badges :: proc(t: ^Track_View) -> string {
	parts: [4]string
	n := 0
	if t.eq.enabled && (abs(t.eq.low_db) > 0.05 || abs(t.eq.mid_db) > 0.05 || abs(t.eq.high_db) > 0.05) {
		parts[n] = "EQ"; n += 1
	}
	if t.comp.enabled {
		parts[n] = "CMP"; n += 1
	}
	if t.send_reverb > 0.001 {
		parts[n] = "REV"; n += 1
	}
	if t.send_delay > 0.001 {
		parts[n] = "DLY"; n += 1
	}
	if n == 0 {
		return ""
	}
	s := parts[0]
	for i in 1 ..< n {
		s = fmt.tprintf("%s · %s", s, parts[i])
	}
	return s
}

@(private = "file")
level_db_text :: proc(level: f32) -> string {
	if level <= 0.0005 {
		return "-∞dB"
	}
	return fmt.tprintf("%.0fdB", 20 * math.log10(level))
}

@(private = "file")
recording_guard :: proc(a: ^App, what: string) -> bool {
	if a.transport == .Recording {
		msg := fmt.tprintf("stop recording to change %s", what)
		toast(a, msg)
		status_buf_set(a, msg)
		return false
	}
	return true
}

@(private = "file")
CTRL :: "rounded-[2px] border px-2 py-0.5 text-[10px] font-bold leading-[1.6] tracking-[0.06em] transition-colors duration-150"

@(private = "file")
view_track :: proc(a: ^App, v: ^View, i: int) {
	t := &a.tracks[i]
	selected := a.selected == i
	recording := a.transport == .Recording && t.armed
	cls := "flex min-w-[140px] flex-1 flex-col gap-2 rounded-[2px] border p-3 transition-colors duration-150"
	state := "border-line-subtle bg-canvas hover:border-line hover:bg-panel-hover"
	if recording {
		state = "border-rec bg-panel" if selected else "border-rec bg-canvas"
	} else if t.armed {
		state = "border-sig-dim bg-panel" if selected else "border-sig-dim bg-canvas hover:bg-panel-hover"
	} else if selected {
		state = "border-line-sig bg-panel"
	}
	if vui.div(vui.cx(cls, state)) {
		if vui.clicked() {
			a.selected = i
			bump_revision(a)
		}
		// header
		if vui.div("flex items-center gap-2") {
			vui.text(fmt.tprintf("%02d", i + 1), recording ? "animate-pulse text-[12px] font-semibold tracking-[0.04em] text-rec" : "text-[12px] font-semibold tracking-[0.04em] text-sig")
			vui.text(t.name, "truncate text-[12px] font-medium text-ink")
			if vui.div("ml-auto flex items-center gap-[3px]") {
				vui.text("IN", "mr-0.5 text-[10px] font-semibold tracking-[0.04em] text-ink-muted")
				count := clamp(a.input_count, 1, 4)
				for ch in 1 ..= count {
					on := t.input == ch
					vui.push_id(ch)
					if vui.button(fmt.tprintf("%d", ch), vui.cx("flex h-[18px] min-w-[18px] items-center justify-center rounded-[2px] border px-1 text-[10px] font-bold leading-none transition-colors duration-150", on ? "border-sig bg-sig text-ink" : "border-line bg-canvas text-ink-muted hover:border-sig-dim hover:text-ink")) {
						if recording_guard(a, "input") && t.input != ch {
							t.input = ch
							a.selected = i
							app_history_note(a, "input")
							app_touch(a)
						}
					}
					vui.pop_id()
				}
				if a.input_count > 4 {
					vui.text(fmt.tprintf("%d", t.input) if t.input > 4 else "…", "ml-0.5 text-[10px] text-sig")
				}
			}
		}
		// FX summary
		badges := track_badges(t)
		fxcls := "flex w-full items-center gap-2 rounded-[2px] border px-2 py-0.5 text-[9px] tracking-[0.06em] transition-colors duration-150 hover:bg-panel-hover"
		if vui.button_box(vui.cx(fxcls, selected ? "border-line-sig text-ink-dim" : badges != "" ? "border-line text-ink-dim" : "border-line-subtle text-ink-muted hover:border-line hover:text-ink-dim")) {
			vui.text("FX", "font-bold text-sig" if badges != "" else "font-bold text-ink-muted")
			vui.text(badges if badges != "" else "CLEAN", "flex-1 truncate")
			if vui.hovered() {
				vui.text("x", "text-[8px] text-ink-muted")
			}
			if vui.clicked() {
				a.selected = i
				a.fx_channel = i
				a.fx_focus = -1
				if a.mode != .Fx {
					app_execute(a, .Fx)
				}
			}
		}
		// controls
		if vui.div("flex items-end gap-3") {
			if vui.div("flex flex-col gap-1") {
				if vui.button("ARM", vui.cx(CTRL, t.armed ? "border-rec bg-rec text-ink" : "border-transparent text-rec hover:border-rec hover:bg-rec-bg")) {
					if recording_guard(a, "arms") {
						t.armed = !t.armed
						a.selected = i
						app_history_note(a, "arm")
						app_touch(a)
					}
				}
				if vui.button("SOLO", vui.cx(CTRL, t.soloed ? "border-cue bg-cue text-canvas" : "border-transparent text-cue hover:border-cue hover:bg-cue-bg")) {
					t.soloed = !t.soloed
					a.selected = i
					app_history_note(a, "solo")
					app_touch(a)
				}
				if vui.button("MUTE", vui.cx(CTRL, t.muted ? "border-ink-muted bg-ink-muted text-canvas" : "border-transparent text-ink-dim hover:border-ink-dim hover:bg-panel-raised")) {
					t.muted = !t.muted
					a.selected = i
					app_history_note(a, "mute")
					app_touch(a)
				}
			}
			// pan
			if vui.div("flex items-center justify-center px-1") {
				io := knob_ui(v, "PAN", pan_label(t.pan), (t.pan + 1) * 0.5, true, true, false, .Knob)
				if io.start {
					a.selected = i
					drag_begin(v, .Pan, i, {}, (t.pan + 1) * 0.5)
				}
				if io.wheel != 0 {
					t.pan = clamp(t.pan + io.wheel * 0.03, -1, 1)
					app_history_note(a, "pan")
					app_touch(a)
				}
				if io.reset {
					t.pan = 0
					app_history_note(a, "pan")
					app_touch(a)
				}
			}
			// fader
			if vui.div("flex flex-col items-center gap-1") {
				norm := clamp(t.level / 1.5, 0, 1)
				dragging := v.drag.kind == .Fader && v.drag.index == i
				if vui.div("relative h-16 w-6 cursor-ns-resize") {
					if press_started() {
						a.selected = i
						drag_begin(v, .Fader, i, {}, norm)
					}
					if w := wheel_here(); w != 0 {
						t.level = clamp(t.level + w * 0.02, 0, 1.5)
						app_history_note(a, "fader")
						app_touch(a)
					}
					if vui.double_clicked() {
						t.level = 0.8
						app_history_note(a, "fader")
						app_touch(a)
					}
					vui.el("absolute inset-y-0 left-1/2 w-1 -translate-x-1/2 rounded-[2px] bg-line")
					// unity mark
					vui.el("absolute left-0.5 right-0.5 h-px bg-ink-muted/60")
					vui.last_style().inset = {vui.px(8 + 48 * (1 - 1 / 1.5)), vui.AUTO, vui.AUTO, vui.px(2)}
					vui.el(vui.cx("absolute left-1 size-4 rounded-[2px] transition-colors duration-150", dragging ? "bg-sig-hi" : "bg-sig hover:bg-sig-hi"))
					vui.last_style().inset = {vui.px(48 * (1 - norm)), vui.AUTO, vui.AUTO, vui.px(4)}
				}
				vui.text(level_db_text(t.level), "text-[11px] tabular-nums text-ink-muted")
			}
			// meter
			active := !t.muted && (selected || t.armed || a.transport != .Stopped || a.monitor)
			meter_ui(db_norm(t.peak_db) if t.peak_db > -59.9 || !active else 0, active, "h-20")
		}

		// footer: level history, takes
		if vui.div("mt-auto flex flex-col gap-2") {
			if !v.tight {
				hist := new(History_Draw, context.temp_allocator)
				hist^ = {a, i}
				vui.canvas("h-8 w-full", history_draw, hist)
			}
			if vui.div("flex items-center gap-1.5 text-[10px] tracking-[0.06em] text-ink-muted") {
				vui.text("TAKE")
				if a.take_count[i] > 0 {
					if vui.button_box("rounded-[2px] p-0.5 text-ink-muted hover:bg-panel-raised hover:text-sig") {
						vui.icon(v.ic_left, "size-3")
						if vui.clicked() {
							app_execute(a, .Take_Prev, i)
						}
					}
					// take ids are 1-based; 0 means the comp / no take is active
					act := a.take_active[i]
					vui.text(fmt.tprintf("%d/%d", act, a.take_count[i]) if act > 0 else fmt.tprintf("C/%d", a.take_count[i]), "tabular-nums text-ink-dim")
					if vui.button_box("rounded-[2px] p-0.5 text-ink-muted hover:bg-panel-raised hover:text-sig") {
						vui.icon(v.ic_right, "size-3")
						if vui.clicked() {
							app_execute(a, .Take_Next, i)
						}
					}
					if vui.button("COMP", "ml-auto rounded-[2px] border border-line px-1.5 py-px text-[9px] font-semibold text-ink-muted hover:border-sig-dim hover:text-sig") {
						app_execute(a, .Comp_Use, i)
					}
				} else {
					vui.text("—", "text-ink-muted")
					vui.text("EMPTY" if !t.has_audio else "AUDIO", "ml-auto text-[9px]")
				}
			}
		}
	}
}

History_Draw :: struct {
	a: ^App,
	i: int,
}

@(private = "file")
history_draw :: proc(ctx: ^vui.Context, r: vui.Rect, data: rawptr) {
	d := (^History_Draw)(data)
	a := d.a
	base := tok("line-subtle")
	vui.draw_rect(ctx, {r.x, r.y + r.h - 1, r.w, 1}, base)
	col := tok("sig-dim")
	if a.transport == .Recording && a.tracks[d.i].armed {
		col = tok("rec")
	}
	step := r.w / f32(HISTORY_LEN - 1)
	for k in 0 ..< HISTORY_LEN {
		idx := (a.peak_history_pos + k) % HISTORY_LEN
		n := db_norm(a.peak_history[d.i][idx])
		if n <= 0.01 {
			continue
		}
		h := max(n * (r.h - 2), 1)
		vui.draw_rect(ctx, {r.x + f32(k) * step, r.y + r.h - 1 - h, max(step - 0.6, 0.6), h}, vui.with_alpha(col, 0.85))
	}
}

// Segmented meter (LevelMeter.tsx): 16 segments, amber, bright amber past 80%,
// red past 95%.
@(private = "file")
meter_ui :: proc(norm: f32, active: bool, size: string, loc := #caller_location) {
	SEGMENTS :: 16
	filled := int(math.round(clamp(norm, 0, 1) * SEGMENTS))
	if vui.div(vui.cx("flex w-2 flex-col-reverse gap-px overflow-hidden rounded-[2px] bg-panel", size), loc = loc) {
		for s in 0 ..< SEGMENTS {
			ratio := f32(s + 1) / SEGMENTS
			cls := "flex-1 bg-line"
			if active && s < filled {
				cls = "flex-1 bg-rec" if ratio > 0.95 else "flex-1 bg-sig-hi" if ratio > 0.8 else "flex-1 bg-sig"
			}
			vui.el(cls)
		}
	}
}

// ---------------------------------------------------------------------------
// Knob (Knob.tsx): 270° dial, amber value arc, pointer, label and readout.
// ---------------------------------------------------------------------------

Knob_Io :: struct {
	start: bool,
	wheel: f32,
	reset: bool,
}

Dial :: struct {
	norm:    f32,
	enabled: bool,
	hover:   bool,
}

@(private = "file")
dial_draw :: proc(ctx: ^vui.Context, r: vui.Rect, data: rawptr) {
	d := (^Dial)(data)
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	rad := r.w * 0.5 - 3
	start := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	n := clamp(d.norm, 0, 1)
	track := tok("line")
	if d.hover && d.enabled {
		track = tok("ink-muted")
	}
	vui.draw_arc(ctx, c, rad, start, sweep, track, 2)
	arc := tok("sig") if d.enabled else tok("ink-muted")
	if n > 0.004 {
		vui.draw_arc(ctx, c, rad, start, sweep * n, arc, 2)
	}
	ang := start + sweep * n
	dir := [2]f32{math.cos(ang), math.sin(ang)}
	vui.draw_line(ctx, c + dir * (rad - 6), c + dir * (rad - 1), tok("ink") if d.enabled else tok("ink-muted"), 1.5)
}

@(private = "file")
knob_ui :: proc(v: ^View, label, value: string, norm: f32, enabled, small, focus: bool, _kind: View_Drag_Kind, loc := #caller_location) -> (io: Knob_Io) {
	cls := "flex flex-col items-center gap-px rounded-[2px] px-0.5 py-px"
	if enabled {
		cls = vui.cx(cls, "cursor-ns-resize")
	}
	if focus {
		cls = vui.cx(cls, "ring-1 ring-sig")
	}
	if vui.div(cls, loc = loc) {
		if enabled {
			io.start = press_started()
			io.wheel = wheel_here()
			io.reset = vui.double_clicked()
		}
		d := new(Dial, context.temp_allocator)
		d^ = {norm, enabled, vui.hovered()}
		vui.canvas("size-[30px]" if small else "size-[38px]", dial_draw, d)
		vui.text(label, "text-[9px] font-semibold tracking-[0.06em] text-ink-muted")
		vui.text(value, "text-[10px] tabular-nums text-ink-dim" if enabled else "text-[10px] tabular-nums text-ink-muted")
	}
	return
}

// ---------------------------------------------------------------------------
// FX rack (FxRack.tsx + fx.css)
// ---------------------------------------------------------------------------

@(private = "file")
TRACK_MODULES := [3]Fx_Module{.EQ, .COMP, .SEND}
@(private = "file")
TRACK_COUNTS := [3]int{5, 5, 2}
@(private = "file")
MASTER_MODULES := [5]Fx_Module{.COMP, .REVERB, .DELAY, .WIDTH, .LIMITER}
@(private = "file")
MASTER_COUNTS := [5]int{5, 5, 4, 2, 3}

@(private = "file")
view_fx :: proc(a: ^App, v: ^View) {
	master := a.fx_channel >= MAX_TRACKS
	modules := MASTER_MODULES[:] if master else TRACK_MODULES[:]
	counts := MASTER_COUNTS[:] if master else TRACK_COUNTS[:]
	knob_total := 0
	for c in counts {
		knob_total += c
	}

	if vui.div(vui.cx("flex shrink-0 flex-col border-t border-line bg-panel", v.tight ? "h-[242px]" : "h-[266px]")) {
		// head
		if vui.div("flex min-h-8 items-center gap-3 border-b border-line-subtle px-3 py-[5px]") {
			vui.text("FX", "text-[12px] font-bold tracking-[0.09em] text-sig")
			if vui.div("flex items-center gap-0.5") {
				for i in 0 ..< 5 {
					on := a.fx_channel == i
					vui.push_id(i)
					if vui.button_box(vui.cx("relative rounded-[2px] border px-[9px] py-0.5 text-[11px] font-semibold tracking-[0.06em] transition-colors duration-150", on ? "border-line-sig bg-sig-bg text-sig" : "border-transparent text-ink-muted hover:bg-panel-hover hover:text-ink")) {
						vui.text("MST" if i == 4 else fmt.tprintf("%d", i + 1))
						if !on && fx_channel_active(a, i) {
							vui.el("absolute right-[3px] top-[3px] size-[3px] rounded-full bg-sig")
						}
						if vui.clicked() && a.fx_channel != i {
							a.fx_channel = i
							a.fx_focus = -1
							bump_revision(a)
						}
					}
					vui.pop_id()
				}
			}
			vui.text("MASTER" if master else fmt.tprintf("TRACK %d", a.fx_channel + 1), "text-[11px] tracking-[0.08em] text-ink-dim")
			vui.text("drag / scroll · shift = fine · dbl-click = reset · tab", "ml-auto truncate text-[10px] tracking-[0.02em] text-ink-muted")
			if vui.button_box("rounded-[2px] px-1.5 py-px text-ink-muted hover:bg-panel-raised hover:text-ink") {
				vui.icon(v.ic_close, "size-3.5")
				if vui.clicked() {
					a.mode = .Normal
					a.fx_focus = -1
					bump_revision(a)
				}
			}
		}
		// chain
		if vui.div("flex min-h-0 flex-1 items-stretch gap-2 overflow-x-auto px-3 py-2") {
			k := 0
			tg := knob_total
			v.knob_wheel = false
			v.focus_rect = {}
			for m, mi in modules {
				vui.push_id(int(m))
				fx_module(a, v, m, mi, counts[mi], &k, &tg)
				vui.pop_id()
			}
			fx_chain_scroll(a, v)
		}
		// foot
		if vui.div("flex items-center justify-between gap-3 px-3 pb-[5px] text-[10px] tracking-[0.05em] text-ink-muted") {
			vui.text(fx_summary(a), "text-ink-dim")
			if focus := fx_focus_label(a); focus != "" {
				vui.text(focus, "text-sig")
			} else {
				vui.text("PLAY MIX TO AUDITION · X CLOSES" if master else "B BOUNCES · X CLOSES", "whitespace-nowrap")
			}
		}
	}
}

// The master chain (5 modules) overflows narrow windows. FxRack.tsx had
// scroll arrows; here a plain wheel over the chain (not over a knob) pans it,
// and keyboard focus (Tab) brings its module into view.
@(private = "file")
fx_chain_scroll :: proc(a: ^App, v: ^View) {
	st := vui.current().state
	if st == nil || st.scroll_max.x <= 0 {
		v.last_focus = a.fx_focus
		v.chain_w = 0
		return
	}
	chain := vui.prev_rect()
	if w := wheel_here(); w != 0 && !v.knob_wheel {
		st.scroll_target.x = clamp(st.scroll_target.x - w * WHEEL_NOTCH, 0, st.scroll_max.x)
	}
	// follow the focus when it moves or the window is resized
	if (a.fx_focus != v.last_focus || chain.w != v.chain_w) && v.focus_rect.w > 0 {
		PAD :: 12
		fr := v.focus_rect
		if fr.x < chain.x {
			st.scroll_target.x -= chain.x - fr.x + PAD
		} else if fr.x + fr.w > chain.x + chain.w {
			st.scroll_target.x += fr.x + fr.w - (chain.x + chain.w) + PAD
		}
		st.scroll_target.x = clamp(st.scroll_target.x, 0, st.scroll_max.x)
	}
	v.last_focus = a.fx_focus
	v.chain_w = chain.w
}

@(private = "file")
fx_summary :: proc(a: ^App) -> string {
	if a.fx_channel >= MAX_TRACKS {
		s := ""
		add :: proc(s: string, on: bool, name: string) -> string {
			if !on {
				return s
			}
			return name if s == "" else fmt.tprintf("%s · %s", s, name)
		}
		s = add(s, a.master.comp.enabled, "CMP")
		s = add(s, a.master.reverb.enabled, "REV")
		s = add(s, a.master.delay.enabled, "DLY")
		s = add(s, a.master.width.enabled, "WIDTH")
		s = add(s, a.master.limiter.enabled, "LIM")
		return s if s != "" else "ALL BYPASSED"
	}
	b := track_badges(&a.tracks[a.fx_channel])
	return b if b != "" else "CLEAN"
}

@(private = "file")
CHIP :: "rounded-[2px] border px-1 py-px text-[9px] font-bold tracking-[0.08em] transition-colors duration-150"

@(private = "file")
fx_module :: proc(a: ^App, v: ^View, m: Fx_Module, mi, count: int, k, tg: ^int) {
	enabled := bypass_state(a, m)
	wide := m == .EQ || m == .REVERB
	cls := "flex min-w-[214px] max-w-[330px] flex-1 flex-col gap-[5px] rounded-[2px] border bg-canvas px-[9px] pb-2 pt-[7px] transition-colors duration-150 hover:border-line"
	if wide {
		cls = vui.cx(cls, "min-w-[256px]")
	}
	if vui.div(vui.cx(cls, enabled ? "border-line" : "border-line-subtle")) {
		k0, tg0 := k^, tg^
		defer if f := a.fx_focus; (f >= k0 && f < k^) || (f >= tg0 && f < tg^) {
			v.focus_rect = vui.prev_rect()
		}
		// head
		if vui.div("flex min-h-4 items-center gap-2") {
			vui.text(fmt.tprintf("%02d", mi + 1), "text-[9px] tabular-nums tracking-[0.04em] text-ink-muted")
			vui.text(module_title(m), vui.cx("mr-auto text-[12px] font-bold tracking-[0.07em]", enabled ? "text-ink" : "text-ink-dim"))
			if m == .COMP {
				comp := a.master.comp if a.fx_channel >= MAX_TRACKS else a.tracks[a.fx_channel].comp
				vui.text("AUTO", vui.cx(CHIP, comp.auto_makeup ? "border-line-sig bg-sig-bg text-sig" : "border-line text-ink-muted"))
			}
			if m == .DELAY {
				pp := Toggle_Target{.DELAY, 1}
				on := app_toggle_value(a, pp)
				if vui.button("P·P", vui.cx(CHIP, on ? "border-line-sig bg-sig-bg text-sig" : "border-line text-ink-muted hover:border-ink-muted hover:text-ink", a.fx_focus == tg^ + 1 ? "ring-1 ring-sig" : "")) {
					app_flip_toggle(a, pp)
				}
			}
			if m != .SEND {
				t := Toggle_Target{m, 0}
				if vui.button("ON" if enabled else "BYP", vui.cx(CHIP, "min-w-[27px] text-center", enabled ? "border-sig bg-sig text-ink" : "border-line text-ink-muted hover:border-ink-muted hover:text-ink", a.fx_focus == tg^ ? "ring-1 ring-sig" : "")) {
					app_flip_toggle(a, t)
				}
				tg^ += 1
				if m == .DELAY {
					tg^ += 1
				}
			}
		}
		// visual
		vis := new(Fx_Draw, context.temp_allocator)
		vis^ = {a, m, enabled}
		vui.canvas(vui.cx("w-full shrink-0", v.tight ? "h-8" : "h-14", enabled ? "" : "opacity-40"), fx_visual_draw, vis)
		// knobs
		if vui.div("mt-auto flex items-start justify-between gap-0.5") {
			for p in 0 ..< count {
				t := Knob_Target{m, p}
				lo, hi, lg := knob_spec(m, p)
				val := app_knob_value(a, t)
				norm := value_to_norm(val, lo, hi, lg)
				vui.push_id(p)
				io := knob_ui(v, param_label(m, p), fx_value_text(m, p, val), norm, enabled, count >= 5 && a.fx_channel >= MAX_TRACKS, a.fx_focus == k^, .Knob)
				vui.pop_id()
				if io.start {
					drag_begin(v, .Knob, 0, t, norm)
				}
				if io.wheel != 0 {
					v.knob_wheel = true
					fine: f32 = 0.2 if v.fine else 1
					app_set_knob(a, t, norm_to_value(clamp(norm + io.wheel * 0.015 * fine, 0, 1), lo, hi, lg))
					app_history_commit(a)
				}
				if io.reset {
					app_knob_reset(a, t)
					app_history_commit(a)
				}
				k^ += 1
			}
		}
		// readout
		if vui.div("flex min-h-3 items-end justify-between gap-2") {
			l, r := fx_readout(a, m)
			vui.text(l, "truncate text-[10px] tracking-[0.02em] text-ink-dim")
			if m == .COMP || m == .LIMITER {
				gr := fx_gr(a, m)
				if vui.div("mx-1 mb-[3px] h-1 flex-1 overflow-hidden rounded-[1px] bg-panel-raised") {
					vui.el("ml-auto h-full bg-sig")
					vui.last_style().width = vui.pct(clamp(-gr / 24, 0, 1) * 100)
				}
			}
			vui.text(r, "shrink-0 text-[10px] tracking-[0.02em] text-ink-muted")
		}
	}
}

// Knob readouts keep the established formats: unit-less 0..1 amounts read as
// percentages, decay as RT60 seconds; the rest reuse the compact harness
// formatter so five knobs still fit a 214px module.
@(private = "file")
fx_value_text :: proc(m: Fx_Module, p: int, v: f32) -> string {
	pct :: proc(v: f32) -> string {
		return fmt.tprintf("%.0f%%", v * 100)
	}
	#partial switch m {
	case .SEND:
		return pct(v)
	case .REVERB:
		switch p {
		case 0, 2, 4:
			return pct(v)
		case 1:
			return fmt.tprintf("%.1fs", 0.3 + v * 4.7) // same curve as the RT60 readout
		}
	case .DELAY:
		if p >= 1 {
			return pct(v)
		}
	case .WIDTH:
		if p == 0 {
			return pct(v)
		}
	}
	// dB readouts: a value that rounds to zero must not print as "-0.0"
	db := (m == .EQ && p != 2 && p != 3) || (m == .COMP && (p == 0 || p == 4)) || (m == .LIMITER && p == 0)
	if db && abs(v) < 0.05 {
		return knob_value_text(m, p, 0, true)
	}
	return knob_value_text(m, p, v, true)
}

// Footer readout for the keyboard-focused control (the model's ids such as
// "knob.eq.low" are for the test harness, not for people).
@(private = "file")
fx_focus_label :: proc(a: ^App) -> string {
	l := &a.layout
	f := a.fx_focus
	if f < 0 {
		return ""
	}
	if f < l.knob_count {
		t := l.knob_target[f]
		return fmt.tprintf("%s · %s %s", module_title(t.module), param_label(t.module, t.param), fx_value_text(t.module, t.param, app_knob_value(a, t)))
	}
	i := f - l.knob_count
	if i < l.toggle_count {
		t := l.toggle_target[i]
		if t.param == 1 {
			return fmt.tprintf("DELAY · PING-PONG %s · ENTER TOGGLES", "ON" if app_toggle_value(a, t) else "OFF")
		}
		return fmt.tprintf("%s · %s · ENTER TOGGLES", module_title(t.module), "ON" if bypass_state(a, t.module) else "BYPASSED")
	}
	return ""
}

@(private = "file")
fx_gr :: proc(a: ^App, m: Fx_Module) -> f32 {
	if a.fx_channel >= MAX_TRACKS {
		return -abs(a.master.gr_db)
	}
	return -abs(a.tracks[a.fx_channel].gr_db)
}

@(private = "file")
fx_readout :: proc(a: ^App, m: Fx_Module) -> (string, string) {
	switch m {
	case .EQ:
		eq := a.tracks[clamp(a.fx_channel, 0, MAX_TRACKS - 1)].eq
		return fmt.tprintf("MID %s · Q %.2f", knob_value_text(.EQ, 2, eq.mid_hz), eq.mid_q), "3-BAND"
	case .COMP:
		gr := fx_gr(a, m)
		return "GR", fmt.tprintf("%.1f dB", gr if gr < -0.05 else 0)
	case .SEND:
		t := a.tracks[clamp(a.fx_channel, 0, MAX_TRACKS - 1)]
		return fmt.tprintf("REV %.0f%% · DLY %.0f%%", t.send_reverb * 100, t.send_delay * 100), "POST-FADER"
	case .REVERB:
		r := a.master.reverb
		return fmt.tprintf("RT60 %.1f s", 0.3 + r.decay * 4.7), fmt.tprintf("%.0f%% room · %.0f ms pre", r.size * 100, r.predelay_ms)
	case .DELAY:
		d := a.master.delay
		return fmt.tprintf("%.0f ms", d.time_ms), "L/R alternating" if d.ping_pong else "mono repeats"
	case .WIDTH:
		w := a.master.width
		return fmt.tprintf("SIDE %+.1f dB", 20 * math.log10(max(w.width, 0.01))), fmt.tprintf("MONO < %.0f Hz", w.bass_hz)
	case .LIMITER:
		return "GR", fmt.tprintf("PEAK %.1f dB", a.master.peak_db)
	}
	return "", ""
}

// ---------------------------------------------------------------------------
// FX visuals (derived from the actual parameters)
// ---------------------------------------------------------------------------

Fx_Draw :: struct {
	a:       ^App,
	m:       Fx_Module,
	enabled: bool,
}

@(private = "file")
fx_visual_draw :: proc(ctx: ^vui.Context, r: vui.Rect, data: rawptr) {
	d := (^Fx_Draw)(data)
	a := d.a
	sig := tok("sig")
	grid := vui.with_alpha(tok("line"), 0.7)
	faint := tok("line-subtle")
	muted := tok("ink-muted")
	pts := make([][2]f32, 160, context.temp_allocator)
	n := len(pts)
	switch d.m {
	case .EQ, .SEND:
		t := &a.tracks[clamp(a.fx_channel, 0, MAX_TRACKS - 1)]
		lo, mid, hi := t.eq.low_db, t.eq.mid_db, t.eq.high_db
		center: f32 = 0.5
		width: f32 = 0.17 / max(t.eq.mid_q, 0.2)
		if d.m == .SEND {
			lo, mid, hi = t.send_reverb * 12 - 6, t.send_delay * 12 - 6, 0
			width = 0.17
		} else {
			center = clamp((math.ln(max(t.eq.mid_hz, 20) / 20)) / math.ln(f32(1000)), 0.05, 0.95)
		}
		for x in 1 ..< 4 {
			vui.draw_rect(ctx, {r.x + r.w * f32(x) / 4, r.y, 1, r.h}, faint)
		}
		vui.draw_rect(ctx, {r.x, r.y + r.h * 0.5, r.w, 1}, grid)
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			low := 1.0 / (1.0 + math.exp((u - 0.18) * 22))
			high := 1.0 / (1.0 + math.exp(-(u - 0.82) * 22))
			bell := math.exp(-math.pow((u - center) / width, 2.0))
			db := lo * low + hi * high + mid * bell
			pts[i] = {r.x + u * r.w, r.y + r.h * 0.5 - clamp(db, -18, 18) / 18.0 * (r.h * 0.42)}
		}
		vui.draw_area(ctx, pts, r.y + r.h, vui.with_alpha(sig, 0.22), vui.with_alpha(sig, 0.02))
		vui.draw_polyline(ctx, pts, sig, 1.25)
		if d.m == .EQ {
			nodes := [3][2]f32{{0.12, lo}, {center, mid}, {0.88, hi}}
			for nd in nodes {
				vui.draw_circle(ctx, {r.x + nd.x * r.w, r.y + r.h * 0.5 - clamp(nd.y, -18, 18) / 18.0 * (r.h * 0.42)}, 2.5, sig)
			}
		}
	case .COMP:
		comp := a.master.comp if a.fx_channel >= MAX_TRACKS else a.tracks[a.fx_channel].comp
		for x in 1 ..< 5 {
			vui.draw_rect(ctx, {r.x + r.w * f32(x) / 5, r.y, 1, r.h}, faint)
		}
		vui.draw_line(ctx, {r.x, r.y + r.h}, {r.x + r.w, r.y}, grid, 1)
		thr := clamp(1.0 + comp.threshold_db / 60.0, 0, 1)
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			out := u if u < thr else thr + (u - thr) / max(comp.ratio, 1)
			pts[i] = {r.x + u * r.w, r.y + r.h - out * r.h}
		}
		vui.draw_polyline(ctx, pts, sig, 1.25)
		vui.draw_circle(ctx, {r.x + thr * r.w, r.y + r.h - thr * r.h}, 2.5, sig)
	case .REVERB:
		rv := a.master.reverb
		k := 6.0 - rv.decay * 5.2
		pre := clamp(rv.predelay_ms / 200, 0, 0.3)
		mid := r.y + r.h * 0.5
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			e: f32 = 0
			if u >= pre {
				e = math.exp(-(u - pre) / (1 - pre) * k)
			}
			pts[i] = {r.x + u * r.w, mid - e * r.h * 0.46}
		}
		vui.draw_rect(ctx, {r.x, mid, r.w, 1}, grid)
		vui.draw_area(ctx, pts, mid, vui.with_alpha(sig, 0.28), vui.with_alpha(sig, 0.04))
		vui.draw_polyline(ctx, pts, sig, 1.25)
		for i in 0 ..< n {
			pts[i].y = 2 * mid - pts[i].y
		}
		vui.draw_polyline(ctx, pts, vui.with_alpha(sig, 0.7), 1)
		// early reflections
		for e in 0 ..< 5 {
			x := r.x + (pre + 0.02 + f32(e) * 0.035 * (0.5 + rv.size)) * r.w
			h := (0.55 - f32(e) * 0.08) * r.h * 0.5
			vui.draw_rect(ctx, {x, mid - h, 1, h * 2}, vui.with_alpha(tok("cue"), 0.8))
		}
	case .DELAY:
		dl := a.master.delay
		mid := r.y + r.h * 0.5
		vui.draw_rect(ctx, {r.x, mid, r.w, 1}, grid)
		vui.draw_rect(ctx, {r.x, r.y, 1, r.h}, grid)
		spacing := clamp(dl.time_ms / 1200, 0.06, 0.4) * r.w
		x := r.x + spacing * 0.4
		amp: f32 = 1
		for i in 0 ..< 12 {
			if x > r.x + r.w - 2 || amp < 0.02 {
				break
			}
			h := amp * r.h * 0.44
			up := !dl.ping_pong || i % 2 == 0
			vui.draw_rect(ctx, {x - 1, up ? mid - h : mid, 2, h}, sig)
			x += spacing
			amp *= clamp(dl.feedback, 0, 0.95)
		}
	case .WIDTH:
		w := a.master.width.width
		c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
		vui.draw_line(ctx, {c.x - r.h * 0.6, r.y}, {c.x + r.h * 0.6, r.y + r.h}, faint, 1)
		vui.draw_line(ctx, {c.x + r.h * 0.6, r.y}, {c.x - r.h * 0.6, r.y + r.h}, faint, 1)
		rx := clamp(w, 0, 2) * r.w * 0.22 + 2
		ry := r.h * 0.32
		seed: u32 = 2166136261
		for i in 0 ..< 240 {
			seed = seed * 1664525 + 1013904223
			ang := f32(seed >> 8) / f32(1 << 24) * math.TAU
			seed = seed * 1664525 + 1013904223
			rad := math.sqrt(f32(seed >> 8) / f32(1 << 24))
			p := c + [2]f32{math.cos(ang) * rx * rad, math.sin(ang) * ry * rad}
			vui.draw_rect(ctx, {p.x, p.y, 1.2, 1.2}, vui.with_alpha(sig, 0.75 if i % 3 == 0 else 0.4))
		}
		vui.draw_rect(ctx, {c.x, r.y + 2, 1, r.h - 4}, vui.with_alpha(muted, 0.5))
	case .LIMITER:
		lm := a.master.limiter
		ceil_y := r.y + r.h * 0.5 - (1 - clamp(-lm.ceiling_db / 12, 0, 1)) * r.h * 0.42
		seed: u32 = 7
		for i in 0 ..< n {
			u := f32(i) / f32(n - 1)
			seed = seed * 1664525 + 1013904223
			noise := f32(seed >> 8) / f32(1 << 24)
			env := 0.35 + 0.55 * math.abs(math.sin(u * 9.0)) * noise
			y := r.y + r.h * 0.5 - env * r.h * 0.5
			pts[i] = {r.x + u * r.w, max(y, ceil_y)}
		}
		vui.draw_polyline(ctx, pts, sig, 1)
		dx: f32 = 0
		for dx < r.w {
			vui.draw_rect(ctx, {r.x + dx, ceil_y, min(4, r.w - dx), 1}, vui.with_alpha(tok("rec"), 0.8))
			dx += 8
		}
	}
	_ = muted
}

// ---------------------------------------------------------------------------
// Bounce row, status line, rhythm
// ---------------------------------------------------------------------------

@(private = "file")
BBTN :: "rounded-[2px] border px-3 py-1 text-[12px] font-semibold tracking-[0.04em] transition-colors duration-150"

@(private = "file")
view_bounce_row :: proc(a: ^App, v: ^View) {
	if vui.div("flex shrink-0 items-center gap-2 border-t border-line px-4 py-2") {
		vui.text("BOUNCE", "mr-2 text-[12px] font-semibold tracking-[0.06em] text-ink-dim")
		if vui.button("···" if a.bounce_active else "BOUNCE", vui.cx(BBTN, "border-line-sig text-sig hover:bg-sig-bg"), {.Disabled} if a.bounce_active else {}) {
			app_execute(a, .Bounce)
		}
		can_undo := app_can_undo(a)
		if vui.button("UNDO", vui.cx(BBTN, can_undo ? "border-line text-ink-dim hover:bg-panel-hover hover:text-ink" : "border-line-subtle text-ink-muted/60"), {} if can_undo else {.Disabled}) {
			app_execute(a, .Undo)
		}
		playing := a.transport == .Playing
		if vui.button_box(vui.cx(BBTN, "flex items-center gap-1.5", playing ? "border-cue bg-cue text-canvas" : "border-cue text-cue hover:bg-cue-bg")) {
			if playing {
				vui.el("size-2 rounded-[1px] bg-canvas")
			} else {
				vui.icon(v.ic_play, "size-3")
			}
			vui.text("STOP" if playing else "PLAY")
			if vui.clicked() {
				app_toggle_play(a)
			}
		}
		// master meter
		if vui.div("ml-auto flex items-center gap-2") {
			// Tab / j/k reach the master as the fifth selectable strip
			mst_sel := a.selected >= MAX_TRACKS
			vui.text("MST", vui.cx("text-[10px] font-semibold tracking-[0.06em]", mst_sel ? "text-sig" : "text-ink-muted"))
			if vui.div(vui.cx("h-1.5 w-40 overflow-hidden rounded-[1px] bg-panel-raised", mst_sel ? "ring-1 ring-sig-dim" : "")) {
				vui.el("h-full bg-rec" if a.master.peak_db > -0.5 else "h-full bg-sig")
				vui.last_style().width = vui.pct(db_norm(a.master.peak_db) * 100)
			}
			vui.text(fmt.tprintf("%5.1f", a.master.peak_db), "w-10 text-right text-[10px] tabular-nums text-ink-muted")
		}
		status := "Ready"
		if a.bounce_active {
			status = fmt.tprintf("Bouncing… %.0f%%", a.bounce_progress * 100)
		} else if playing {
			status = "Playing"
		} else if a.transport == .Recording {
			status = "Recording"
		}
		vui.text(status, "ml-4 w-28 text-right text-[11px] text-ink-muted")
	}
}

@(private = "file")
view_status :: proc(a: ^App) {
	if vui.div("flex shrink-0 items-center gap-2 border-t border-line bg-panel px-4 py-1 text-[11px] text-ink-muted") {
		mode, mcls := status_mode(a)
		vui.text(mode if a.mode != .Palette else ":", vui.cx("rounded-[2px] px-2 py-px text-[10px] font-bold leading-[1.5] tracking-[0.08em]", mcls))
		vui.text(app_status(a), "flex-1 truncate text-ink-dim")
		if a.monitor {
			vui.text("● CAP", "rounded-[2px] bg-sig-bg px-2 py-px text-[10px] font-semibold tracking-[0.05em] text-sig")
		}
		if a.transport == .Recording {
			vui.text(fmt.tprintf("● REC %d", arm_count(a)), "rounded-[2px] bg-rec px-2 py-px text-[10px] font-semibold tracking-[0.05em] text-ink")
		}
		vui.text(fmt.tprintf("%s · %s%s · %d kHz", app_project(a), app_device(a), " · JACK" if a.jack_backend else "", a.sample_rate / 1000), "truncate text-ink-muted")
		hint := "j/k: nav  J/K: vol  : command"
		#partial switch a.mode {
		case .Fx:
			hint = "tab: focus  h/l: adjust  x: close"
		case .Palette, .Recent:
			hint = "enter: run  esc: close"
		case .Io:
			hint = "click: select  esc: close"
		}
		vui.text(hint, "ml-2 whitespace-pre text-ink-muted")
	}
}

@(private = "file")
view_rhythm :: proc(a: ^App) {
	if vui.div("flex shrink-0 items-center gap-3 border-t border-line px-4 py-2") {
		on := a.metronome
		if vui.button_box(vui.cx("flex items-center gap-2 rounded-[2px] border px-3 py-1 text-[12px] font-semibold tracking-[0.06em] transition-colors duration-150", on ? "border-line-sig bg-sig-bg text-sig" : "border-line text-ink-dim hover:bg-panel-hover hover:text-ink")) {
			vui.text("RHYTHM")
			vui.text("ON" if on else "OFF", "text-sig" if on else "text-ink-muted")
			if vui.clicked() {
				app_execute(a, .Metronome)
			}
		}
		if on {
			vui.text(fmt.tprintf("CLICK · %d BPM · 4/4", a.bpm), "text-[11px] tracking-[0.04em] text-ink-dim")
		}
		if vui.div("ml-auto flex items-center gap-1") {
			lat := fmt.tprintf("LAT %.0f ms", a.latency_ms)
			vui.text(lat, "text-[11px] tabular-nums text-ink-muted")
			can_redo := app_can_redo(a)
			if vui.button("REDO", vui.cx("ml-3 rounded-[2px] border px-2 py-0.5 text-[10px] font-semibold tracking-[0.06em]", can_redo ? "border-line text-ink-dim hover:bg-panel-hover hover:text-ink" : "border-line-subtle text-ink-muted/60"), {} if can_redo else {.Disabled}) {
				app_execute(a, .Redo)
			}
			if vui.button(":", "rounded-[2px] border border-line px-2 py-0.5 text-[11px] font-bold text-sig hover:bg-sig-bg") {
				a.mode = .Palette
				a.palette_len = 0
				a.palette_sel = 0
				a.palette_scroll = 0
				app_palette_rebuild(a)
				bump_revision(a)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Overlays: command palette, I/O, recent projects, bounce progress
// ---------------------------------------------------------------------------

@(private = "file")
OVERLAY :: "absolute inset-0 z-50 flex items-start justify-center bg-canvas/75 pt-20"
@(private = "file")
PANEL :: "flex w-[560px] max-w-[90%] flex-col gap-2 rounded-[4px] border border-line bg-panel p-4 shadow-lg"

@(private = "file")
close_on_backdrop :: proc(a: ^App) {
	// vinland bubbles clicks to every ancestor, so a click on a panel button
	// (JACK, RESCAN, LAT ±) also reports clicked() here. Only the backdrop
	// itself -- the topmost hit under the pointer -- dismisses the overlay.
	if vui.clicked() && vui.ctx_get().hover_id == vui.current_id() {
		a.mode = .Normal
		bump_revision(a)
	}
}

@(private = "file")
view_palette :: proc(a: ^App) {
	if vui.pressable(OVERLAY) {
		close_on_backdrop(a)
		if vui.pressable(PANEL) {
			if vui.div("flex items-center") {
				vui.text("Commands", "text-[14px] font-semibold text-ink")
				vui.text("ESC", "ml-auto text-[10px] font-semibold tracking-[0.06em] text-ink-muted")
			}
			if vui.div("flex items-center gap-2 rounded-[2px] border border-sig-dim bg-canvas px-3 py-2 text-[13px]") {
				vui.text(":", "font-bold text-sig")
				vui.text(string(a.palette_buf[:a.palette_len]), "text-ink")
				vui.el("h-4 w-[2px] animate-pulse bg-sig")
			}
			if a.palette_count == 0 {
				vui.text("No matching command", "px-2 py-3 text-[13px] text-ink-muted")
			}
			visible := min(a.palette_count - a.palette_scroll, 10)
			if vui.div("flex flex-col") {
				for row in 0 ..< max(visible, 0) {
					idx := a.palette_scroll + row
					sel := idx == a.palette_sel
					cmd := PALETTE_COMMANDS[a.palette_items[idx]]
					vui.push_id(idx)
					if vui.button_box(vui.cx("flex items-center gap-2 rounded-[2px] px-2 py-1.5 text-[13px]", sel ? "bg-sig-bg text-ink" : "text-ink-dim hover:bg-panel-raised")) {
						vui.el("size-1.5 rounded-full bg-sig" if sel else "size-1.5")
						vui.text(cmd.name, "flex-1 truncate font-medium" if sel else "flex-1 truncate")
						vui.text(command_hint(cmd.kind), "text-[11px] text-ink-muted")
						if vui.clicked() {
							a.palette_sel = idx
							app_palette_execute(a)
						}
					}
					vui.pop_id()
				}
			}
			if vui.div("flex items-center pt-1 text-[11px] text-ink-muted") {
				vui.text("ENTER run   ↑↓ select   ESC close", "whitespace-pre")
				if a.palette_count > 10 {
					vui.text(fmt.tprintf("%d/%d", a.palette_sel + 1, a.palette_count), "ml-auto tabular-nums")
				}
			}
		}
	}
}

@(private = "file")
view_io :: proc(a: ^App) {
	if vui.pressable(OVERLAY) {
		close_on_backdrop(a)
		if vui.pressable(PANEL) {
			if vui.div("flex items-baseline gap-3") {
				vui.text("Input devices", "text-[14px] font-semibold text-ink")
				vui.text("PipeWire / JACK sources", "text-[11px] text-ink-muted")
				vui.text("ESC", "ml-auto text-[10px] font-semibold tracking-[0.06em] text-ink-muted")
			}
			if len(a.devices) == 0 {
				vui.text("No devices reported", "px-2 py-3 text-[13px] text-ink-muted")
			}
			if vui.div("flex max-h-[320px] flex-col overflow-y-auto") {
				for d, i in a.devices {
					if i >= MAX_DEVICES {
						break
					}
					sel := i == a.device_index
					vui.push_id(i)
					if vui.button_box(vui.cx("flex items-center gap-2 rounded-[2px] border px-2 py-1.5 text-[13px]", sel ? "border-line-sig bg-sig-bg text-ink" : "border-transparent text-ink-dim hover:bg-panel-raised")) {
						vui.el("size-1.5 shrink-0 rounded-full bg-sig" if sel else "size-1.5 shrink-0")
						vui.text(d, "truncate")
						if vui.clicked() {
							app_execute(a, .Select_Device, i)
							a.mode = .Normal
						}
					}
					vui.pop_id()
				}
			}
			if vui.div("flex items-center gap-2 border-t border-line-subtle pt-3") {
				if vui.button("JACK", vui.cx(BBTN, a.jack_backend ? "border-cue bg-cue-bg text-cue" : "border-line text-ink-dim hover:text-ink")) {
					app_execute(a, .Backend)
				}
				if vui.button("RESCAN", vui.cx(BBTN, "border-line text-ink-dim hover:bg-panel-hover hover:text-ink")) {
					app_execute(a, .Rescan)
				}
				if vui.div("ml-auto flex items-center gap-1") {
					if vui.button("−", vui.cx(BBTN, "border-line px-2 text-ink-dim hover:text-ink")) {
						app_execute(a, .Latency_Down)
					}
					vui.text(fmt.tprintf("LAT %.0f ms", a.latency_ms), "w-24 text-center text-[12px] tabular-nums text-ink")
					if vui.button("+", vui.cx(BBTN, "border-line px-2 text-ink-dim hover:text-ink")) {
						app_execute(a, .Latency_Up)
					}
				}
			}
		}
	}
}

@(private = "file")
view_recent :: proc(a: ^App) {
	if vui.pressable(OVERLAY) {
		close_on_backdrop(a)
		if vui.pressable(PANEL) {
			if vui.div("flex items-center") {
				vui.text("Recent projects", "text-[14px] font-semibold text-ink")
				vui.text("ESC", "ml-auto text-[10px] font-semibold tracking-[0.06em] text-ink-muted")
			}
			if vui.div("flex items-center gap-2 rounded-[2px] border border-sig-dim bg-canvas px-3 py-2 text-[13px]") {
				vui.text("/", "font-bold text-sig")
				vui.text(string(a.recent_query_buf[:a.recent_query_len]), "text-ink")
				vui.el("h-4 w-[2px] animate-pulse bg-sig")
			}
			if a.recent_filtered == 0 {
				vui.text("No recent projects" if a.recent_count == 0 else "No matching project", "px-2 pt-3 text-[13px] text-ink-muted")
				if a.recent_count == 0 {
					vui.text("Use : open project to browse.", "px-2 pb-2 text-[11px] text-ink-dim")
				}
			}
			for i in 0 ..< min(a.recent_filtered, MAX_RECENT) {
				sel := i == a.recent_sel
				vui.push_id(i)
				if vui.button_box(vui.cx("flex items-center gap-2 rounded-[2px] px-2 py-1.5 text-[13px]", sel ? "bg-sig-bg text-ink" : "text-ink-dim hover:bg-panel-raised")) {
					vui.el("size-1.5 shrink-0 rounded-full bg-sig" if sel else "size-1.5 shrink-0")
					vui.text(app_recent_path(a, a.recent_items[i]), "flex-1 truncate")
					vui.text(fmt.tprintf("%d", a.recent_items[i] + 1), "text-[11px] tabular-nums text-ink-muted")
					if vui.clicked() {
						a.recent_sel = i
						app_recent_choose(a)
					}
				}
				vui.pop_id()
			}
			vui.text("TYPE filter   ENTER open   ↑↓ select   ESC close", "whitespace-pre pt-1 text-[11px] text-ink-muted")
		}
	}
}

@(private = "file")
view_bounce_overlay :: proc(a: ^App) {
	if vui.pressable(OVERLAY) {
		close_on_backdrop(a)
		if vui.pressable(vui.cx(PANEL, "gap-3 p-5")) {
			if vui.div("flex items-center") {
				vui.text("Bouncing mix", "text-[14px] font-semibold text-ink")
				vui.text("ESC", "ml-auto text-[10px] font-semibold tracking-[0.06em] text-ink-muted")
			}
			vui.text("TRACK FX › MASTER COMP › REVERB › DELAY › WIDTH › LIMITER", "text-[10px] tracking-[0.06em] text-ink-muted")
			if vui.div("h-1.5 w-full overflow-hidden rounded-[1px] bg-panel-raised") {
				vui.el("h-full bg-sig")
				vui.last_style().width = vui.pct(clamp(a.bounce_progress, 0, 1) * 100)
			}
			if vui.div("flex items-baseline") {
				vui.text(fmt.tprintf("%.0f%%", a.bounce_progress * 100), "text-[20px] font-semibold tabular-nums text-ink")
				vui.text("writing bounce.wav", "ml-auto text-[11px] text-ink-muted")
			}
			vui.text("ESC dismiss · render continues in background", "text-[11px] text-ink-muted")
		}
	}
}
