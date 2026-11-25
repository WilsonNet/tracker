package ui

import "core:fmt"
import "core:strings"

// Variable track count, the visible window onto it, bounce marks and the
// "bounce marked tracks to a target track" dialog. Pure model: no engine, no
// view. The window runs `.Bounce_To_Track` against the engine.

// Narrowest a strip may get (logical px) before the zoom is capped. Below this
// the ARM/SOLO/MUTE row no longer fits.
STRIP_MIN_W :: 92
// Strips narrower than this drop the pan knob, level history and input pills.
STRIP_FULL_W :: 200

VIEW_STEPS := [?]int{2, 3, 4, 6, 8, 12}

// Strips that physically fit across the window.
app_view_fit :: proc(a: ^App) -> int {
	gutter := METRICS.gutter
	usable := f32(a.width) - METRICS.margin * 2
	return max(int((usable + gutter) / (STRIP_MIN_W + gutter)), 1)
}

// Strips actually shown: the user's zoom, capped by what exists and fits.
app_view_count :: proc(a: ^App) -> int {
	return clamp(min(a.view_want, app_view_fit(a)), 1, max(a.track_count, 1))
}

// Keeps the window inside the track list and the selection inside the window.
app_view_clamp :: proc(a: ^App) {
	n := app_view_count(a)
	a.view_first = clamp(a.view_first, 0, max(a.track_count - n, 0))
	if a.selected >= 0 && a.selected < a.track_count {
		if a.selected < a.view_first {
			a.view_first = a.selected
		} else if a.selected >= a.view_first + n {
			a.view_first = a.selected - n + 1
		}
	}
	a.view_first = clamp(a.view_first, 0, max(a.track_count - n, 0))
}

app_view_is_visible :: proc(a: ^App, i: int) -> bool {
	n := app_view_count(a)
	return i >= a.view_first && i < a.view_first + n
}

// Index 0..track_count-1 are tracks, MAX_TRACKS is the master.
app_select_step :: proc(a: ^App, delta: int, wrap: bool) {
	// position in the compact order [0..count-1, master]
	count := a.track_count
	pos := count if a.selected >= MAX_TRACKS else clamp(a.selected, 0, count - 1)
	next := pos + delta
	if wrap {
		next = (next % (count + 1) + (count + 1)) % (count + 1)
	} else {
		next = clamp(next, 0, count)
	}
	a.selected = MAX_TRACKS if next >= count else next
	a.take_del_track = -1
	app_view_clamp(a)
	bump_revision(a)
}

// FX rack channel: same compact order, master = MAX_TRACKS.
app_fx_channel_step :: proc(a: ^App, delta: int) {
	count := a.track_count
	pos := count if a.fx_channel >= MAX_TRACKS else clamp(a.fx_channel, 0, count - 1)
	next := ((pos + delta) % (count + 1) + (count + 1)) % (count + 1)
	a.fx_channel = MAX_TRACKS if next >= count else next
	a.fx_focus = -1
	app_layout(a)
}

// FX tabs show four tracks at a time plus MST; this is the first channel of
// the page holding `fx_channel`.
app_fx_page_base :: proc(a: ^App) -> int {
	if a.fx_channel >= MAX_TRACKS {
		return clamp((a.track_count - 1) / 4 * 4, 0, MAX_TRACKS)
	}
	return a.fx_channel / 4 * 4
}

// Channel a tab index (0..3 tracks, 4 master) points to, or -1 when the page
// has no track there.
app_fx_tab_channel :: proc(a: ^App, tab: int) -> int {
	if tab == 4 {
		return MAX_TRACKS
	}
	ch := app_fx_page_base(a) + tab
	if ch >= a.track_count {
		return -1
	}
	return ch
}

// ---------------------------------------------------------------- count

@(private)
app_track_reset :: proc(a: ^App, i: int) {
	t := &a.tracks[i]
	name := t.name
	owned := a.track_name_owned[i]
	if owned {
		delete(name)
		a.track_name_owned[i] = false
	}
	fresh := Track_View{}
	fresh.name = TRACK_NAMES[i]
	fresh.input = i % max(a.input_count, 1) + 1
	fresh.level = 0.8
	fresh.peak_db = -60
	fresh.rms_db = -60
	fresh.eq.enabled = true
	fresh.eq.mid_hz = 1_000
	fresh.eq.mid_q = 1.0
	fresh.comp.enabled = true
	fresh.comp.threshold_db = -18
	fresh.comp.ratio = 3
	fresh.comp.attack_ms = 12
	fresh.comp.release_ms = 180
	fresh.comp.knee_db = 8
	fresh.comp.auto_makeup = true
	t^ = fresh
	for h in 0 ..< HISTORY_LEN {
		a.peak_history[i][h] = -60
	}
	a.take_count[i] = 0
	a.take_active[i] = 0
	a.marked[i] = false
	if a.take_del_track == i {
		a.take_del_track = -1
	}
}

// Sets the live strip count (loader / tests). Strips beyond it return to their
// defaults so a smaller project never inherits a larger one's arms or audio.
app_set_track_count :: proc(a: ^App, count: int) {
	n := clamp(count, MIN_TRACKS, MAX_TRACKS)
	for i in n ..< MAX_TRACKS {
		app_track_reset(a, i)
	}
	a.track_count = n
	a.take_del_track = -1
	if a.selected < MAX_TRACKS {
		a.selected = clamp(a.selected, 0, n - 1)
	}
	if a.fx_channel < MAX_TRACKS {
		a.fx_channel = clamp(a.fx_channel, 0, n - 1)
	}
	app_view_clamp(a)
	app_layout(a)
	bump_revision(a)
}

app_track_add :: proc(a: ^App) -> bool {
	if a.transport == .Recording {
		status_buf_set(a, "stop recording to add a track")
		toast(a, "stop recording to add a track")
		return false
	}
	if a.track_count >= MAX_TRACKS {
		status_buf_set(a, "24 tracks is the maximum")
		toast(a, "24 tracks is the maximum")
		return false
	}
	i := a.track_count
	app_track_reset(a, i)
	a.track_count += 1
	a.selected = i
	app_view_clamp(a)
	app_layout(a)
	status_buf_set(a, fmt.tprintf("track %d added · %d tracks", i + 1, a.track_count))
	app_history_note(a, "add track")
	app_touch(a)
	return true
}

// Delete the selected track. A track holding audio asks first (dialog); an
// empty one goes straight away. Later tracks move up one slot. At the minimum
// of 4 strips the strip stays and is cleared instead.
app_track_remove :: proc(a: ^App) -> bool {
	if a.transport != .Stopped {
		status_buf_set(a, "stop the tape to delete a track")
		toast(a, "stop the tape to delete a track")
		return false
	}
	i := a.selected
	if i < 0 || i >= a.track_count {
		toast(a, "select a track first")
		return false
	}
	has := a.tracks[i].has_audio || a.take_count[i] > 0
	if !has && a.track_count <= MIN_TRACKS {
		status_buf_set(a, "4 tracks is the minimum")
		toast(a, "4 tracks is the minimum")
		return false
	}
	if has {
		a.td_index = i
		a.td_confirm = false
		a.mode = .Track_Delete
		status_buf_set(a, fmt.tprintf("delete track %d and its audio?", i + 1))
		bump_revision(a)
		return true
	}
	emit(a, .Delete_Track, i)
	return true
}

app_td_close :: proc(a: ^App) {
	if a.mode != .Track_Delete {
		return
	}
	a.mode = .Normal
	status_buf_set(a, "delete track cancelled")
	bump_revision(a)
}

app_td_run :: proc(a: ^App) {
	if a.mode != .Track_Delete || a.td_index < 0 || a.td_index >= a.track_count {
		return
	}
	emit(a, .Delete_Track, a.td_index)
}

app_td_key :: proc(a: ^App, key: Key, ch: u8) {
	#partial switch key {
	case .Escape:
		app_td_close(a)
	case .Enter:
		if a.td_confirm {
			app_td_run(a)
		} else {
			app_td_close(a)
		}
	case .Left, .Right, .Tab, .Up, .Down:
		a.td_confirm = !a.td_confirm
		bump_revision(a)
	case .Char:
		switch ch {
		case 'y', 'Y':
			app_td_run(a)
		case 'n', 'N':
			app_td_close(a)
		case 'h', 'l', 'j', 'k':
			a.td_confirm = !a.td_confirm
			bump_revision(a)
		}
	}
}

// Model half of a delete, called by the engine once the files are moved aside.
// `strip` removes the slot (later tracks shift up); otherwise the slot is just
// reset (the 4-track minimum).
app_track_delete_apply :: proc(a: ^App, i: int, strip: bool) {
	if i < 0 || i >= a.track_count {
		return
	}
	app_track_reset(a, i) // frees an owned name
	if strip {
		last := a.track_count - 1
		for j in i ..< last {
			a.tracks[j] = a.tracks[j + 1]
			a.track_name_owned[j] = a.track_name_owned[j + 1]
			a.take_count[j] = a.take_count[j + 1]
			a.take_active[j] = a.take_active[j + 1]
			a.peak_history[j] = a.peak_history[j + 1]
		}
		a.track_name_owned[last] = false // the name moved down; do not free it twice
		app_track_reset(a, last)
		a.track_count -= 1
	}
	app_mark_clear(a)
	a.take_del_track = -1
	a.mode = .Normal
	a.selected = clamp(i, 0, a.track_count - 1)
	if a.fx_channel < MAX_TRACKS {
		a.fx_channel = clamp(a.fx_channel, 0, a.track_count - 1)
	}
	app_view_clamp(a)
	app_layout(a)
	a.dirty = true
	bump_revision(a)
}

// ---------------------------------------------------------------- view

app_view_zoom :: proc(a: ^App, dir: int) {
	// current step index = nearest step to the want
	idx := 0
	for s, k in VIEW_STEPS {
		if s <= a.view_want {
			idx = k
		}
	}
	// skip steps that cannot fit so every press visibly changes something
	fit := min(app_view_fit(a), a.track_count)
	next := idx
	for {
		cand := next + dir
		if cand < 0 || cand >= len(VIEW_STEPS) {
			break
		}
		next = cand
		if VIEW_STEPS[next] <= fit || dir < 0 {
			break
		}
	}
	a.view_want = VIEW_STEPS[next]
	app_view_clamp(a)
	app_layout(a)
	status_buf_set(a, fmt.tprintf("showing %d tracks", app_view_count(a)))
	bump_revision(a)
}

// Moves the window by a whole page (or a single strip with `step`).
app_view_page :: proc(a: ^App, dir: int, step: int = 0) {
	n := app_view_count(a)
	delta := step if step > 0 else n
	a.view_first = clamp(a.view_first + dir * delta, 0, max(a.track_count - n, 0))
	// keep the selection on screen so j/k continue from what is visible
	if a.selected < MAX_TRACKS {
		a.selected = clamp(a.selected, a.view_first, a.view_first + n - 1)
	}
	app_layout(a)
	bump_revision(a)
}

// ---------------------------------------------------------------- marks

app_marked_count :: proc(a: ^App) -> int {
	n := 0
	for i in 0 ..< a.track_count {
		if a.marked[i] {
			n += 1
		}
	}
	return n
}

app_mark_toggle :: proc(a: ^App, i: int) {
	if i < 0 || i >= a.track_count {
		return
	}
	a.marked[i] = !a.marked[i]
	n := app_marked_count(a)
	status_buf_set(a, fmt.tprintf("%d marked · V bounce to a track", n) if n > 0 else "marks cleared")
	bump_revision(a)
}

app_mark_clear :: proc(a: ^App) {
	for i in 0 ..< MAX_TRACKS {
		a.marked[i] = false
	}
	bump_revision(a)
}

// ---------------------------------------------------------------- bounce dialog

// Next unmarked track after `from` in `dir`, wrapping; -1 if none.
@(private)
tb_next_target :: proc(a: ^App, from, dir: int) -> int {
	n := a.track_count
	for k in 1 ..= n {
		cand := ((from + dir * k) % n + n) % n
		if !a.marked[cand] {
			return cand
		}
	}
	return -1
}

app_tb_open :: proc(a: ^App) -> bool {
	if a.transport == .Recording {
		toast(a, "stop recording before bouncing tracks")
		status_buf_set(a, "stop recording before bouncing tracks")
		return false
	}
	if app_marked_count(a) == 0 {
		// Nothing marked: mark the selected track so one keypress still works.
		if a.selected < a.track_count {
			a.marked[a.selected] = true
		}
	}
	marked := app_marked_count(a)
	if marked == 0 {
		toast(a, "mark tracks with V first")
		return false
	}
	if marked >= a.track_count {
		toast(a, "leave one track unmarked as the target")
		status_buf_set(a, "leave one track unmarked as the target")
		return false
	}
	// Prefer the first empty unmarked track: it destroys nothing visible.
	target := -1
	for i in 0 ..< a.track_count {
		if !a.marked[i] && !a.tracks[i].has_audio && a.take_count[i] == 0 {
			target = i
			break
		}
	}
	if target < 0 {
		target = tb_next_target(a, a.selected if a.selected < a.track_count else 0, 1)
	}
	if target < 0 {
		return false
	}
	project_edit_clear(a)
	a.tb_target = target
	a.mode = .Track_Bounce
	app_view_clamp(a)
	status_buf_set(a, "choose the target track")
	bump_revision(a)
	return true
}

app_tb_close :: proc(a: ^App) {
	if a.mode != .Track_Bounce {
		return
	}
	a.mode = .Normal
	bump_revision(a)
}

app_tb_move :: proc(a: ^App, dir: int) {
	if t := tb_next_target(a, a.tb_target, dir); t >= 0 {
		a.tb_target = t
		a.selected = t
		app_view_clamp(a)
		bump_revision(a)
	}
}

app_tb_run :: proc(a: ^App) {
	if a.mode != .Track_Bounce || a.tb_target < 0 || a.tb_target >= a.track_count || a.marked[a.tb_target] {
		return
	}
	emit(a, .Bounce_To_Track, a.tb_target)
	status_buf_set(a, "bouncing marked tracks…")
	bump_revision(a)
}

// Called by the window when the engine has finished (or refused) the bounce.
app_tb_finished :: proc(a: ^App, ok: bool, message: string) {
	status_buf_set(a, message)
	toast(a, message)
	if ok {
		target := a.tb_target
		a.mode = .Normal
		app_mark_clear(a)
		if target >= 0 && target < a.track_count {
			a.selected = target
			a.tracks[target].has_audio = true
		}
		app_view_clamp(a)
	}
	bump_revision(a)
}

@(private)
app_tb_key :: proc(a: ^App, key: Key, ch: u8) {
	#partial switch key {
	case .Escape:
		app_tb_close(a)
		status_buf_set(a, "bounce to track cancelled")
	case .Enter:
		app_tb_run(a)
	case .Up, .Left:
		app_tb_move(a, -1)
	case .Down, .Right, .Tab:
		app_tb_move(a, 1)
	case .Char:
		switch ch {
		case 'k', 'h':
			app_tb_move(a, -1)
		case 'j', 'l':
			app_tb_move(a, 1)
		}
	}
}

// ---------------------------------------------------------------- rename

app_track_draft :: proc(a: ^App) -> string {
	return string(a.track_name_draft[:a.track_name_draft_len])
}

@(private)
track_edit_reset_flags :: proc(a: ^App) {
	a.track_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
}

// Drops an open track rename without saving (overlays opening, panic, ...).
track_edit_clear :: proc(a: ^App) {
	if a.track_edit {
		track_edit_reset_flags(a)
	}
}

app_track_begin_edit :: proc(a: ^App, i: int, select_all: bool = true) -> bool {
	if i < 0 || i >= a.track_count || a.mode != .Normal {
		toast(a, "select a track to rename (j/k)")
		return false
	}
	if a.project_name_edit {
		app_project_cancel_edit(a)
	}
	a.track_edit = true
	a.track_edit_index = i
	a.selected = i
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_scroll_x = 0
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	buf_set(a.track_name_draft[:], &a.track_name_draft_len, a.tracks[i].name)
	a.text_cursor = a.track_name_draft_len
	a.text_anchor = a.text_cursor
	if select_all && a.track_name_draft_len > 0 {
		text_select_all(a)
	}
	app_view_clamp(a)
	status_buf_set(a, fmt.tprintf("rename track %d", i + 1))
	bump_revision(a)
	return true
}

app_track_cancel_edit :: proc(a: ^App) {
	if !a.track_edit {
		return
	}
	track_edit_reset_flags(a)
	status_buf_set(a, "rename cancelled")
	bump_revision(a)
}

// An empty name restores the default "Track N". Names are owned strings.
app_track_commit_edit :: proc(a: ^App) -> bool {
	if !a.track_edit {
		return false
	}
	i := a.track_edit_index
	if i < 0 || i >= a.track_count {
		track_edit_reset_flags(a)
		return false
	}
	trimmed := strings.trim_space(app_track_draft(a))
	t := &a.tracks[i]
	if a.track_name_owned[i] {
		delete(t.name)
		a.track_name_owned[i] = false
	}
	if trimmed == "" {
		t.name = TRACK_NAMES[i]
	} else {
		t.name = strings.clone(trimmed)
		a.track_name_owned[i] = true
	}
	track_edit_reset_flags(a)
	a.dirty = true
	status_buf_set(a, fmt.tprintf("track %d named %s", i + 1, t.name))
	toast(a, fmt.tprintf("track %d: %s", i + 1, t.name))
	bump_revision(a)
	return true
}

// ---------------------------------------------------------------- BOUNCE track

BOUNCE_TRACK_NAME :: "BOUNCE"

// Index of the dedicated bounce track (named BOUNCE), or -1.
app_bounce_track_index :: proc(a: ^App) -> int {
	for i in 0 ..< a.track_count {
		if a.tracks[i].name == BOUNCE_TRACK_NAME {
			return i
		}
	}
	return -1
}

// Finds the BOUNCE track or adds one at the end and names it. -1 when all
// MAX_TRACKS strips are already taken by other tracks.
app_bounce_track_ensure :: proc(a: ^App) -> int {
	if i := app_bounce_track_index(a); i >= 0 {
		return i
	}
	if !app_track_add(a) {
		return -1
	}
	i := a.track_count - 1
	t := &a.tracks[i]
	if a.track_name_owned[i] {
		delete(t.name)
	}
	t.name = strings.clone(BOUNCE_TRACK_NAME)
	a.track_name_owned[i] = true
	return i
}

// ---------------------------------------------------------------- take delete

// Arms inline take-delete confirmation on track `idx`; re-arming keeps the
// bar open without auto-confirming so double-presses never delete by mistake.
app_take_delete_arm :: proc(a: ^App, idx: int) -> bool {
	if a.transport != .Stopped {
		status_buf_set(a, "stop the tape to delete a take")
		toast(a, "stop the tape to delete a take")
		return false
	}
	if idx < 0 || idx >= a.track_count {
		toast(a, "select a track first")
		return false
	}
	if a.take_count[idx] <= 0 {
		status_buf_set(a, "no takes on this track")
		toast(a, "no takes on this track")
		return false
	}
	if a.take_active[idx] <= 0 {
		status_buf_set(a, "select a take first (t/T) — comp active")
		toast(a, "select a take first (t/T) — comp active")
		return false
	}
	if a.take_del_track == idx {
		return true
	}
	a.selected = idx
	a.take_del_track = idx
	app_view_clamp(a)
	status_buf_set(a, fmt.tprintf("delete take %d/%d on %s? y/Enter delete · Esc cancel", a.take_active[idx], a.take_count[idx], a.tracks[idx].name))
	bump_revision(a)
	return true
}

app_take_delete_confirm :: proc(a: ^App) {
	if a.take_del_track < 0 || a.take_del_track >= a.track_count {
		a.take_del_track = -1
		return
	}
	track := a.take_del_track
	a.take_del_track = -1
	emit(a, .Delete_Take, track)
	bump_revision(a)
}

app_take_delete_cancel :: proc(a: ^App, announce: bool = true) {
	if a.take_del_track < 0 {
		return
	}
	a.take_del_track = -1
	if announce {
		status_buf_set(a, "delete take cancelled")
	}
	bump_revision(a)
}

// Opt-in multi-take creation: guards transport, track selection, and whether
// the current take already has audio before emitting `.Take_New`.
app_take_new :: proc(a: ^App, idx: int) -> bool {
	if a.transport != .Stopped {
		status_buf_set(a, "stop the tape to create a new take")
		toast(a, "stop the tape to create a new take")
		return false
	}
	if idx < 0 || idx >= a.track_count {
		toast(a, "select a track first")
		return false
	}
	if a.take_count[idx] <= 0 && !a.tracks[idx].has_audio {
		status_buf_set(a, "record on this track first")
		toast(a, "record on this track first")
		return false
	}
	if a.take_count[idx] > 0 && !a.tracks[idx].has_audio && a.take_active[idx] > 0 {
		status_buf_set(a, "current take is already empty")
		toast(a, "current take is already empty")
		return false
	}
	a.take_del_track = -1
	a.selected = idx
	app_view_clamp(a)
	emit(a, .Take_New, idx)
	bump_revision(a)
	return true
}
