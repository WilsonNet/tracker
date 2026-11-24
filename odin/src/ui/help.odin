package ui

// Contextual F1 cheat sheet. The model decides which keys are relevant for
// the current mode / sub-state; view.odin only renders the result.

Help_Entry :: struct {
	keys: string, // empty keys => section header (title in desc)
	desc: string,
}

app_help_toggle :: proc(a: ^App) {
	a.help_open = !a.help_open
	bump_revision(a)
}

// Short label for the sheet header: where the user is right now.
app_help_context :: proc(a: ^App) -> string {
	if (a.mode == .Normal && (a.project_name_edit || a.track_edit)) ||
	   (a.mode == .Settings && (a.project_name_edit || a.settings_path_edit || a.cloud_edit != .None)) {
		return "Editing text"
	}
	if a.transport == .Recording && a.mode == .Normal {
		return "Recording"
	}
	switch a.mode {
	case .Normal:  return "Mixer"
	case .Fx:      return "FX rack"
	case .Palette: return "Command palette"
	case .Io:      return "Input devices"
	case .Bounce:  return "Bounce"
	case .Recent:  return "Recent projects"
	case .Settings: return "Settings"
	case .Cloud:   return "Cloud projects"
	case .Render:  return "Render mix"
	case .Track_Bounce: return "Bounce to track"
	}
	return "Mixer"
}

@(private = "file")
head :: proc(out: ^[dynamic]Help_Entry, title: string) {
	append(out, Help_Entry{"", title})
}

@(private = "file")
row :: proc(out: ^[dynamic]Help_Entry, keys, desc: string) {
	append(out, Help_Entry{keys, desc})
}

@(private = "file")
help_text_edit :: proc(out: ^[dynamic]Help_Entry, enter, esc: string) {
	head(out, "Editing")
	row(out, "Enter", enter)
	row(out, "Esc", esc)
	row(out, "← → Home End", "move caret")
	row(out, "Ctrl+← →", "move by word")
	row(out, "Ctrl+Bksp / Del", "delete word")
	head(out, "Clipboard")
	row(out, "Ctrl+A", "select all")
	row(out, "Ctrl+C / X / V", "copy / cut / paste")
	row(out, "Ctrl+Z / Y", "undo / redo")
}

// Entries for the current context, allocated on the temp allocator.
// Section headers have empty `keys`.
app_help_entries :: proc(a: ^App) -> []Help_Entry {
	out := make([dynamic]Help_Entry, 0, 40, context.temp_allocator)

	switch {
	case a.mode == .Normal && a.track_edit:
		help_text_edit(&out, "save name (empty = default)", "cancel")
	case a.mode == .Normal && a.project_name_edit:
		help_text_edit(&out, "save name", "cancel")
	case a.mode == .Settings && a.project_name_edit:
		help_text_edit(&out, "save name", "ask, then discard")
		head(&out, "Fields")
		row(&out, "Tab / Shift+Tab", "next / previous field")
	case a.mode == .Settings && (a.settings_path_edit || a.cloud_edit != .None):
		help_text_edit(&out, "apply", "ask, then discard")
		head(&out, "Fields")
		row(&out, "Tab / Shift+Tab", "next / previous field")
	case a.mode == .Settings:
		head(&out, "Settings")
		row(&out, "j k / ↑ ↓", "select row")
		row(&out, "Enter", "run selected row")
		row(&out, "b", "browse for folder")
		row(&out, "a", "apply folder")
		row(&out, "r", "reset to default")
		row(&out, "Tab", "edit next text field")
		row(&out, "Esc / ,", "close")
	case a.mode == .Palette:
		head(&out, "Command palette")
		row(&out, "type", "filter commands")
		row(&out, "↑ ↓", "select")
		row(&out, "Enter", "run")
		row(&out, "Esc", "close")
	case a.mode == .Recent:
		head(&out, "Recent projects")
		row(&out, "type", "filter projects")
		row(&out, "↑ ↓", "select")
		row(&out, "Enter", "open")
		row(&out, "Esc", "close")
	case a.mode == .Cloud:
		head(&out, "Cloud projects")
		row(&out, "j k / ↑ ↓", "select project")
		row(&out, "Enter", "restore selected")
		row(&out, "u", "back up current")
		row(&out, "n", "rename project")
		row(&out, "r", "refresh list")
		row(&out, "Esc", "close")
	case a.mode == .Render:
		head(&out, "Render mix")
		row(&out, "j k / Tab", "select row")
		row(&out, "h l / ← →", "nudge handle")
		row(&out, "Shift + h l", "fine nudge")
		row(&out, "f", "cycle format")
		row(&out, "Enter", "choose file and render")
		row(&out, "Esc", "cancel")
	case a.mode == .Track_Bounce:
		head(&out, "Bounce marked tracks")
		row(&out, "j k / ← →", "choose target track")
		row(&out, "Enter", "bounce into target")
		row(&out, "Esc", "cancel")
	case a.mode == .Bounce:
		head(&out, "Bounce")
		row(&out, "Esc", "dismiss when finished")
	case a.mode == .Io:
		head(&out, "Input devices")
		row(&out, "click", "choose device / JACK / latency")
		row(&out, "i / Esc", "close")
		help_transport(&out, a)
	case a.mode == .Fx:
		head(&out, "FX rack")
		row(&out, "Tab / S-Tab", "next / prev control")
		row(&out, "↑ ↓ ← → / h l", "adjust focused knob")
		row(&out, "Shift + arrows", "fine adjust")
		row(&out, "Enter", "toggle focused switch")
		row(&out, "[ ]", "previous / next channel")
		row(&out, "x / Esc", "close rack")
		help_transport(&out, a)
	case:
		help_normal(&out, a)
	}

	head(&out, "Help")
	row(&out, "F1 / Esc", "close this sheet")
	return out[:]
}

@(private = "file")
help_transport :: proc(out: ^[dynamic]Help_Entry, a: ^App) {
	head(out, "Transport")
	row(out, "Space", "play / stop")
	if a.transport == .Recording {
		row(out, "r", "stop take")
	} else {
		row(out, "r", "record armed tracks")
	}
}

@(private = "file")
help_normal :: proc(out: ^[dynamic]Help_Entry, a: ^App) {
	recording := a.transport == .Recording

	head(out, "Transport")
	row(out, "Space", "play / stop")
	row(out, "r", "stop take" if recording else "record armed tracks")
	row(out, "0", "rewind to start")
	row(out, "h l", "jog tape")
	row(out, "H L", "slow jog")
	row(out, "< >", "shuttle")
	row(out, "Ctrl + jog", "micro step")

	head(out, "Tracks")
	row(out, "j k / Tab", "select track")
	row(out, "v", "mark for bounce")
	row(out, "V", "bounce marked to a track")
	row(out, "R", "rename track")
	row(out, "m", "mute")
	row(out, "s", "solo")
	row(out, "← →", "pan (Shift: fine)")
	row(out, "J K", "level down / up")
	if !recording {
		row(out, "1-9", "arm track")
		row(out, "a", "arm selected")
		row(out, "I", "cycle input channel")
		row(out, "t T", "next / prev take")
	}

	head(out, "Track count")
	if !recording {
		row(out, "N", "add a track")
		row(out, "D", "remove last (empty) track")
	}
	row(out, "{ }", "show fewer / more tracks")
	row(out, "( )", "previous / next page")

	head(out, "Session")
	row(out, "c", "metronome")
	row(out, "o", "live monitor")
	row(out, "+ -", "BPM up / down")
	row(out, "u U", "undo / redo")
	row(out, "n", "rename project")

	head(out, "Panels")
	row(out, ":", "command palette")
	row(out, "x", "FX rack")
	row(out, "i", "input devices")
	row(out, ",", "settings")
	row(out, "g", "cloud projects")
	if !recording {
		row(out, "b", "bounce")
		row(out, "B", "render mix")
		row(out, "y", "switch backend")
	}
}
