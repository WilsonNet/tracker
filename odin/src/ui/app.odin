// UI state, layout, input and commands. Deliberately independent of SDL and of
// the audio backend: the same App drives the native window and the headless
// click/screenshot harness.

package ui

import "core:fmt"
import "core:math"

MAX_TRACKS :: 4
MAX_KNOBS :: 24
MAX_TOGGLES :: 16
MAX_DEVICES :: 16
MAX_PALETTE :: 24

Mode :: enum { Normal, Fx, Palette, Io, Bounce }
Transport :: enum { Stopped, Playing, Recording }
Key :: enum { Char, Space, Enter, Escape, Backspace, Left, Right, Up, Down, Tab }

Fx_Module :: enum u8 { EQ, COMP, SEND, REVERB, DELAY, WIDTH, LIMITER }

Command_Kind :: enum {
	Play,
	Stop,
	Record_Start,
	Record_Stop,
	Bounce,
	Save,
	Load,
	Select_Device,
	Fx,
	Io,
	Metronome,
	Bpm_Up,
	Bpm_Down,
	Arm_All,
	Clear_Arms,
	Panic,
}

Command :: struct {
	kind:  Command_Kind,
	index: int,
}

Eq_View :: struct {
	enabled: bool,
	low_db:  f32,
	mid_db:  f32,
	mid_hz:  f32,
	mid_q:   f32,
	high_db: f32,
}

Comp_View :: struct {
	enabled:     bool,
	threshold_db: f32,
	ratio:       f32,
	attack_ms:   f32,
	release_ms:  f32,
	knee_db:     f32,
	auto_makeup: bool,
}

Reverb_View :: struct {
	enabled:      bool,
	size:         f32,
	decay:        f32,
	tone:         f32,
	predelay_ms:  f32,
	return_level: f32,
}

Delay_View :: struct {
	enabled:      bool,
	time_ms:      f32,
	feedback:     f32,
	tone:         f32,
	return_level: f32,
	ping_pong:    bool,
}

Width_View :: struct {
	enabled: bool,
	width:   f32,
	bass_hz: f32,
}

Limiter_View :: struct {
	enabled:      bool,
	ceiling_db:   f32,
	release_ms:   f32,
	lookahead_ms: f32,
}

Track_View :: struct {
	name:        string,
	input:       int,
	level:       f32,
	pan:         f32,
	armed:       bool,
	muted:       bool,
	soloed:      bool,
	peak_db:     f32,
	rms_db:      f32,
	gr_db:       f32,
	has_audio:   bool,
	eq:          Eq_View,
	comp:        Comp_View,
	send_reverb: f32,
	send_delay:  f32,
}

Master_View :: struct {
	comp:    Comp_View,
	reverb:  Reverb_View,
	delay:   Delay_View,
	width:   Width_View,
	limiter: Limiter_View,
	peak_db: f32,
	rms_db:  f32,
	gr_db:   f32,
}

Knob_Target :: struct {
	module: Fx_Module,
	param:  int,
}

Toggle_Target :: struct {
	module: Fx_Module,
	param:  int, // 0 = bypass, 1 = ping-pong
}

Layout :: struct {
	header:    Rect,
	transport: Rect,
	status:    Rect,

	rec:    Rect,
	play:   Rect,
	stop:   Rect,
	bounce: Rect,
	fx:     Rect,
	io:     Rect,
	bpm_minus: Rect,
	bpm_plus:  Rect,
	click:     Rect,

	track: [MAX_TRACKS]Rect,
	arm:   [MAX_TRACKS]Rect,
	solo:  [MAX_TRACKS]Rect,
	mute:  [MAX_TRACKS]Rect,
	input: [MAX_TRACKS]Rect,
	fader: [MAX_TRACKS]Rect,
	meter: [MAX_TRACKS]Rect,
	pan:   [MAX_TRACKS]Rect,
	gr:    [MAX_TRACKS]Rect,

	master:     Rect,
	master_meter: Rect,

	fx_panel: Rect,
	fx_tab:   [5]Rect,
	fx_close: Rect,
	fx_module: [5]Rect,
	fx_module_id: [5]Fx_Module,
	fx_module_count: int,

	knob:        [MAX_KNOBS]Rect,
	knob_target: [MAX_KNOBS]Knob_Target,
	knob_count:  int,

	toggle:        [MAX_TOGGLES]Rect,
	toggle_target: [MAX_TOGGLES]Toggle_Target,
	toggle_count:  int,

	palette:      Rect,
	palette_input: Rect,
	palette_row:  [MAX_PALETTE]Rect,
	palette_count: int,

	io_panel: Rect,
	io_row:   [MAX_DEVICES]Rect,
	io_count: int,
}

Drag_Kind :: enum { None, Fader, Pan, Knob }

Drag :: struct {
	kind:      Drag_Kind,
	index:     int,
	target:    Knob_Target,
	start_y:   f32,
	start_norm: f32,
}

App :: struct {
	width, height: int,
	tracks:        [MAX_TRACKS]Track_View,
	track_name_owned: [MAX_TRACKS]bool,
	master:        Master_View,
	selected:      int,
	mode:          Mode,
	transport:     Transport,
	sample_rate:   u32,
	bpm:           int,
	metronome:     bool,
	frames:        i64,
	time:          f32,

	project_buf: [64]u8,
	project_len: int,
	device_buf:  [64]u8,
	device_len:  int,
	status_buf:  [96]u8,
	status_len:  int,
	toast_buf:   [96]u8,
	toast_len:   int,
	toast_time:  f32,
	dirty:       bool,

	fx_channel: int,
	palette_buf: [96]u8,
	palette_len: int,
	palette_sel: int,
	palette_items: [MAX_PALETTE]int,
	palette_count: int,

	devices:      []string,
	device_index: int,
	bounce_progress: f32,
	demo:         bool,

	mouse_x, mouse_y: f32,
	mouse_down:   bool,
	drag:         Drag,
	hover_id:     string,

	layout:   Layout,
	commands: [dynamic]Command,
	cmd_read: int,
	frame_no: u64,
}

TRACK_NAMES := [MAX_TRACKS]string{"Track 1", "Track 2", "Track 3", "Track 4"}

app_init :: proc(a: ^App, width, height: int) {
	a^ = App{}
	a.width = width
	a.height = height
	a.sample_rate = 48_000
	a.bpm = 120
	a.selected = 0
	a.mode = .Normal
	a.transport = .Stopped
	a.fx_channel = 0
	a.device_index = 0
	status_buf_set(a, "ready")
	project_buf_set(a, "untitled")
	device_buf_set(a, "no input")
	for i in 0 ..< MAX_TRACKS {
		t := &a.tracks[i]
		t.name = TRACK_NAMES[i]
		t.input = i + 1
		t.level = 0.8
		t.pan = 0
		t.peak_db = -60
		t.rms_db = -60
		t.gr_db = 0
		t.eq.enabled = true
		t.eq.mid_hz = 1_000
		t.eq.mid_q = 1.0
		t.comp.enabled = true
		t.comp.threshold_db = -18
		t.comp.ratio = 3
		t.comp.attack_ms = 12
		t.comp.release_ms = 180
		t.comp.knee_db = 8
		t.comp.auto_makeup = true
	}
	a.master.comp.enabled = false
	a.master.comp.threshold_db = -14
	a.master.comp.ratio = 2.5
	a.master.comp.attack_ms = 20
	a.master.comp.release_ms = 250
	a.master.comp.knee_db = 10
	a.master.reverb.enabled = false
	a.master.reverb.size = 0.62
	a.master.reverb.decay = 0.55
	a.master.reverb.tone = 0.55
	a.master.reverb.predelay_ms = 18
	a.master.reverb.return_level = 0.45
	a.master.delay.enabled = false
	a.master.delay.time_ms = 320
	a.master.delay.feedback = 0.35
	a.master.delay.tone = 0.55
	a.master.delay.return_level = 0.35
	a.master.delay.ping_pong = true
	a.master.width.enabled = false
	a.master.width.width = 1
	a.master.width.bass_hz = 140
	a.master.limiter.enabled = true
	a.master.limiter.ceiling_db = -0.3
	a.master.limiter.release_ms = 120
	a.master.limiter.lookahead_ms = 5
	a.master.peak_db = -60
	a.master.rms_db = -60
	a.master.gr_db = 0
	app_resize(a, width, height)
}

app_destroy :: proc(a: ^App) {
	for i in 0 ..< MAX_TRACKS {
		if a.track_name_owned[i] {
			delete(a.tracks[i].name)
			a.track_name_owned[i] = false
		}
	}
	for d in a.devices {
		delete(d)
	}
	delete(a.devices)
	a.devices = nil
	delete(a.commands)
	a.commands = nil
}

// ---------------------------------------------------------------- string buffers

@(private)
buf_set :: proc(buf: []u8, len_out: ^int, s: string) {
	n := min(len(s), len(buf))
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	len_out^ = n
}

@(private)
buf_get :: proc(buf: []u8, n: int) -> string {
	return string(buf[:n])
}

app_status :: proc(a: ^App) -> string { return buf_get(a.status_buf[:], a.status_len) }
app_project :: proc(a: ^App) -> string { return buf_get(a.project_buf[:], a.project_len) }
app_device :: proc(a: ^App) -> string { return buf_get(a.device_buf[:], a.device_len) }
app_toast :: proc(a: ^App) -> string { return buf_get(a.toast_buf[:], a.toast_len) }

status_buf_set :: proc(a: ^App, s: string) {
	buf_set(a.status_buf[:], &a.status_len, s)
}

project_buf_set :: proc(a: ^App, s: string) {
	buf_set(a.project_buf[:], &a.project_len, s)
}

device_buf_set :: proc(a: ^App, s: string) {
	buf_set(a.device_buf[:], &a.device_len, s)
}

toast :: proc(a: ^App, s: string) {
	buf_set(a.toast_buf[:], &a.toast_len, s)
	a.toast_time = 2.2
}

app_set_devices :: proc(a: ^App, names: []string, selected: int) {
	for d in a.devices {
		delete(d)
	}
	delete(a.devices)
	a.devices = make([]string, len(names))
	for n, i in names {
		a.devices[i] = fmt.aprintf("%s", n)
	}
	a.device_index = clamp(selected, 0, max(len(names) - 1, 0))
	if len(a.devices) > 0 {
		device_buf_set(a, a.devices[a.device_index])
	}
	app_layout(a)
}

app_set_device :: proc(a: ^App, name: string) {
	device_buf_set(a, name)
}

app_set_project :: proc(a: ^App, name: string) {
	project_buf_set(a, name)
}

app_set_meters :: proc(a: ^App, peaks, rms, gr: []f32) {
	for i in 0 ..< min(len(peaks), MAX_TRACKS) {
		a.tracks[i].peak_db = peaks[i]
	}
	for i in 0 ..< min(len(rms), MAX_TRACKS) {
		a.tracks[i].rms_db = rms[i]
	}
	for i in 0 ..< min(len(gr), MAX_TRACKS) {
		a.tracks[i].gr_db = gr[i]
	}
}

app_take_command :: proc(a: ^App) -> (Command, bool) {
	if a.cmd_read >= len(a.commands) {
		clear(&a.commands)
		a.cmd_read = 0
		return {}, false
	}
	c := a.commands[a.cmd_read]
	a.cmd_read += 1
	return c, true
}

@(private)
emit :: proc(a: ^App, kind: Command_Kind, index: int = 0) {
	append(&a.commands, Command{kind, index})
}

// ---------------------------------------------------------------- layout

@(private)
add_knob :: proc(l: ^Layout, r: Rect, m: Fx_Module, p: int) {
	if l.knob_count >= MAX_KNOBS {
		return
	}
	l.knob[l.knob_count] = r
	l.knob_target[l.knob_count] = Knob_Target{m, p}
	l.knob_count += 1
}

@(private)
add_toggle :: proc(l: ^Layout, r: Rect, m: Fx_Module, p: int) {
	if l.toggle_count >= MAX_TOGGLES {
		return
	}
	l.toggle[l.toggle_count] = r
	l.toggle_target[l.toggle_count] = Toggle_Target{m, p}
	l.toggle_count += 1
}

@(private)
layout_module :: proc(l: ^Layout, panel: Rect, m: Fx_Module, count: int, start_y: f32) {
	// Knob centres: up to 3 per row.
	radius: f32 = 18
	cols := 3
	cell_w := panel.w / f32(cols)
	for i in 0 ..< count {
		row := i / cols
		col := i % cols
		cx := panel.x + cell_w * (f32(col) + 0.5)
		cy := start_y + f32(row) * 100 + radius + 8
		add_knob(l, Rect{cx - radius - 6, cy - radius - 6, radius * 2 + 12, radius * 2 + 12}, m, i)
	}
}

app_layout :: proc(a: ^App) {
	l := &a.layout
	l^ = Layout{}
	w := f32(a.width)
	h := f32(a.height)

	l.header = Rect{0, 0, w, 46}
	l.transport = Rect{0, 46, w, 70}
	l.status = Rect{0, h - 28, w, 28}

	btn_y := f32(58)
	bw: f32 = 74
	l.rec = Rect{16, btn_y, bw, 44}
	l.play = Rect{16 + bw + 8, btn_y, bw, 44}
	l.stop = Rect{16 + (bw + 8) * 2, btn_y, bw, 44}
	l.bounce = Rect{16 + (bw + 8) * 3 + 12, btn_y, 104, 44}
	l.fx = Rect{l.bounce.x + 112, btn_y, 64, 44}
	l.io = Rect{l.fx.x + 72, btn_y, 64, 44}
	l.bpm_minus = Rect{w - 132, 22, 20, 18}
	l.bpm_plus = Rect{w - 44, 22, 20, 18}
	l.click = Rect{w - 408, 22, 56, 18}

	area_y := f32(124)
	area_h := h - area_y - 32
	master_w: f32 = 168
	gap: f32 = 8
	margin: f32 = 14
	track_w := (w - master_w - margin * 2 - gap * MAX_TRACKS) / f32(MAX_TRACKS)
	for i in 0 ..< MAX_TRACKS {
		x := margin + f32(i) * (track_w + gap)
		r := Rect{x, area_y, track_w, area_h}
		l.track[i] = r
		inner_x := r.x + 10
		inner_w := r.w - 20

		l.input[i] = Rect{inner_x, r.y + 36, 70, 22}
		tog_y := r.y + 90
		tog_w := (inner_w - 8) / 3
		l.arm[i] = Rect{inner_x, tog_y, tog_w, 26}
		l.solo[i] = Rect{inner_x + tog_w + 4, tog_y, tog_w, 26}
		l.mute[i] = Rect{inner_x + (tog_w + 4) * 2, tog_y, tog_w, 26}

		l.pan[i] = Rect{inner_x + inner_w * 0.5 - 28, r.y + 128, 56, 56}
		fader_y := r.y + 206
		fader_h := max(r.h - 270, 80)
		l.fader[i] = Rect{inner_x + 18, fader_y, 18, fader_h}
		l.meter[i] = Rect{inner_x + 50, fader_y, 14, fader_h}
		l.gr[i] = Rect{inner_x, r.y + r.h - 38, inner_w, 18}
	}

	master_x := w - master_w - margin
	l.master = Rect{master_x, area_y, master_w, area_h}
	l.master_meter = Rect{master_x + 20, area_y + 70, 18, area_h - 140}

	// FX rack: overlays the track area.
	fx_y := area_y
	fx_h := min(340, area_h - 8)
	l.fx_panel = Rect{margin, fx_y, w - margin * 2, fx_h}
	tab_w: f32 = 44
	for i in 0 ..< 5 {
		l.fx_tab[i] = Rect{l.fx_panel.x + 14 + f32(i) * (tab_w + 4), fx_y + 12, tab_w, 24}
	}
	l.fx_close = Rect{l.fx_panel.x + l.fx_panel.w - 34, fx_y + 12, 22, 24}

	inner := Rect{l.fx_panel.x + 14, fx_y + 48, l.fx_panel.w - 28, fx_h - 62}
	if a.fx_channel >= MAX_TRACKS {
		modules := [5]Fx_Module{.COMP, .REVERB, .DELAY, .WIDTH, .LIMITER}
		counts := [5]int{5, 5, 4, 2, 3}
		mod_gap: f32 = 8
		mod_w := (inner.w - mod_gap * 4) / 5
		for m, i in modules {
			p := Rect{inner.x + f32(i) * (mod_w + mod_gap), inner.y, mod_w, inner.h}
			l.fx_module[i] = p
			l.fx_module_id[i] = m
			l.fx_module_count += 1
			layout_module(l, p, m, counts[i], p.y + 96)
			add_toggle(l, Rect{p.x + p.w - 46, p.y + 8, 38, 18}, m, 0)
			if m == .DELAY {
				add_toggle(l, Rect{p.x + p.w - 92, p.y + 8, 40, 18}, m, 1)
			}
		}
	} else {
		modules := [3]Fx_Module{.EQ, .COMP, .SEND}
		counts := [3]int{5, 5, 2}
		mod_gap: f32 = 10
		mod_w := (inner.w - mod_gap * 2) / 3
		for m, i in modules {
			p := Rect{inner.x + f32(i) * (mod_w + mod_gap), inner.y, mod_w, inner.h}
			l.fx_module[i] = p
			l.fx_module_id[i] = m
			l.fx_module_count += 1
			layout_module(l, p, m, counts[i], p.y + 96)
			if m != .SEND {
				add_toggle(l, Rect{p.x + p.w - 46, p.y + 8, 38, 18}, m, 0)
			}
		}
	}

	l.palette = Rect{(w - 560) * 0.5, 150, 560, 420}
	l.palette_input = Rect{l.palette.x + 14, l.palette.y + 14, l.palette.w - 28, 28}
	for i in 0 ..< MAX_PALETTE {
		l.palette_row[i] = Rect{l.palette.x + 10, l.palette.y + 52 + f32(i) * 26, l.palette.w - 20, 24}
	}

	l.io_panel = Rect{w - 440, 124, 426, h - 160}
	l.io_count = min(len(a.devices), MAX_DEVICES)
	for i in 0 ..< MAX_DEVICES {
		l.io_row[i] = Rect{l.io_panel.x + 12, l.io_panel.y + 52 + f32(i) * 30, l.io_panel.w - 24, 26}
	}
	l.palette_count = a.palette_count
	a.layout = l^
}

app_resize :: proc(a: ^App, width, height: int) {
	a.width = max(width, 900)
	a.height = max(height, 620)
	app_layout(a)
}

// ---------------------------------------------------------------- commands

app_execute :: proc(a: ^App, kind: Command_Kind, index: int = 0) {
	switch kind {
	case .Play:
		a.transport = .Playing
		a.frames = 0
		status_buf_set(a, "playing preview")
		emit(a, .Play)
	case .Stop:
		a.transport = .Stopped
		a.frames = 0
		status_buf_set(a, "stopped")
		emit(a, .Stop)
	case .Record_Start:
		armed := false
		for t in a.tracks {
			if t.armed {
				armed = true
			}
		}
		if !armed {
			status_buf_set(a, "arm a track first")
			toast(a, "arm a track first")
			return
		}
		a.transport = .Recording
		a.frames = 0
		status_buf_set(a, "recording")
		emit(a, .Record_Start)
	case .Record_Stop:
		a.transport = .Stopped
		status_buf_set(a, "take captured")
		emit(a, .Record_Stop)
	case .Bounce:
		if a.transport == .Recording {
			toast(a, "stop recording before bounce")
			return
		}
		a.mode = .Bounce
		a.bounce_progress = 0
		status_buf_set(a, "bouncing")
		emit(a, .Bounce)
	case .Save:
		emit(a, .Save)
		status_buf_set(a, "project saved")
	case .Load:
		emit(a, .Load)
		status_buf_set(a, "project loaded")
	case .Select_Device:
		a.device_index = clamp(index, 0, max(len(a.devices) - 1, 0))
		if len(a.devices) > 0 {
			device_buf_set(a, a.devices[a.device_index])
		}
		emit(a, .Select_Device, a.device_index)
		status_buf_set(a, "input device selected")
	case .Fx:
		a.mode = .Fx if a.mode != .Fx else .Normal
		status_buf_set(a, "fx rack")
	case .Io:
		a.mode = .Io if a.mode != .Io else .Normal
	case .Metronome:
		a.metronome = !a.metronome
		status_buf_set(a, "metronome on" if a.metronome else "metronome off")
	case .Bpm_Up:
		a.bpm = clamp(a.bpm + 1, 40, 240)
	case .Bpm_Down:
		a.bpm = clamp(a.bpm - 1, 40, 240)
	case .Arm_All:
		for i in 0 ..< MAX_TRACKS {
			a.tracks[i].armed = true
		}
		status_buf_set(a, "all tracks armed")
	case .Clear_Arms:
		for i in 0 ..< MAX_TRACKS {
			a.tracks[i].armed = false
		}
		status_buf_set(a, "arms cleared")
	case .Panic:
		a.transport = .Stopped
		a.frames = 0
		a.mode = .Normal
		status_buf_set(a, "stopped")
		toast(a, "panic stop")
		emit(a, .Stop)
	}
}

app_force_stopped :: proc(a: ^App, msg: string) {
	a.transport = .Stopped
	status_buf_set(a, msg)
}

app_bounce_finished :: proc(a: ^App, ok: bool, msg: string) {
	a.mode = .Normal
	a.bounce_progress = 1.0
	status_buf_set(a, msg)
	if ok {
		for i in 0 ..< MAX_TRACKS {
			if a.tracks[i].armed {
				a.tracks[i].has_audio = true
			}
		}
		toast(a, "bounce complete")
	} else {
		toast(a, "bounce failed")
	}
}

app_toggle_record :: proc(a: ^App) {
	if a.transport == .Recording {
		app_execute(a, .Record_Stop)
	} else {
		app_execute(a, .Record_Start)
	}
}

app_toggle_play :: proc(a: ^App) {
	if a.transport == .Playing {
		app_execute(a, .Stop)
	} else {
		app_execute(a, .Play)
	}
}

// ---------------------------------------------------------------- tick

app_tick :: proc(a: ^App, dt: f32) {
	a.time += dt
	a.frame_no += 1
	if a.transport != .Stopped {
		a.frames += i64(dt * f32(a.sample_rate))
	}
	if a.toast_time > 0 {
		a.toast_time -= dt
		if a.toast_time <= 0 {
			a.toast_len = 0
		}
	}

	if a.demo {
		for i in 0 ..< MAX_TRACKS {
			t := &a.tracks[i]
			active := a.transport != .Stopped && (t.has_audio || (a.transport == .Recording && t.armed))
			if active {
				base := -19.0 - f32(i) * 1.7
				osc := math.sin(a.time * 3.1 + f32(i) * 0.9) * 5.5 +
				       math.sin(a.time * 7.7 + f32(i) * 2.1) * 2.8
				t.peak_db = clamp(base + osc, -60, 0)
				t.rms_db = t.peak_db - 7
				t.gr_db = -abs(math.sin(a.time * 2.2 + f32(i))) * 1.5 if t.comp.enabled else 0
			} else {
				t.peak_db += (-60 - t.peak_db) * min(dt * 8, 1)
				t.rms_db += (-60 - t.rms_db) * min(dt * 8, 1)
				t.gr_db += (0 - t.gr_db) * min(dt * 6, 1)
			}
		}
		peak: f32 = -60.0
		for t in a.tracks {
			peak = max(peak, t.peak_db)
		}
		a.master.peak_db = peak
		a.master.rms_db = peak - 6
		a.master.gr_db = -abs(math.sin(a.time * 1.7)) * 0.8 if a.master.limiter.enabled && peak > -3 else 0
	}

	if a.mode == .Bounce {
		a.bounce_progress += dt * 0.9
		if a.bounce_progress >= 1.0 {
			a.bounce_progress = 1.0
			a.mode = .Normal
			for i in 0 ..< MAX_TRACKS {
				if a.tracks[i].armed {
					a.tracks[i].has_audio = true
				}
			}
			status_buf_set(a, "bounce written")
			toast(a, "bounce complete")
		}
	}
}
