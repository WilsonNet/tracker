// Single-line text editing for the settings form.
//
// The caret and anchor are byte offsets into the active fixed buffer. The
// helpers here cover the standard desktop behaviour: caret movement, word
// movement, selection, replace-on-type, backspace/delete, copy/cut/paste and a
// small undo stack. The view maps mouse coordinates through vinland's caret
// stops.

package ui

import "core:strings"
import "core:unicode/utf8"

@(private)
text_prev_offset :: proc(s: string, i: int) -> int {
	if i <= 0 {
		return 0
	}
	_, size := utf8.decode_last_rune_in_string(s[:i])
	return i - size
}

@(private)
text_next_offset :: proc(s: string, i: int) -> int {
	if i >= len(s) {
		return len(s)
	}
	_, size := utf8.decode_rune_in_string(s[i:])
	return i + size
}

// Word boundaries for Ctrl+arrow / Ctrl+Backspace. ASCII punctuation and
// whitespace separate words; paths keep a whole directory segment together.
@(private)
text_word_gap :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '/' || c == '\\' || c == '_' || c == '-' ||
		c == '.' || c == ':' || c == ',' || c == ';' || c == '=' || c == '?' || c == '&'
}

@(private)
text_byte_at :: proc(s: string, i: int) -> u8 {
	if i < 0 || i >= len(s) {
		return 0
	}
	return s[i]
}

@(private)
text_word_left :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	for j > 0 && text_word_gap(text_byte_at(s, j - 1)) {
		j -= 1
	}
	for j > 0 && !text_word_gap(text_byte_at(s, j - 1)) {
		j -= 1
	}
	return j
}

@(private)
text_word_right :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	for j < len(s) && text_word_gap(text_byte_at(s, j)) {
		j += 1
	}
	for j < len(s) && !text_word_gap(text_byte_at(s, j)) {
		j += 1
	}
	return j
}

// Clamp a byte offset down to the start of a UTF-8 sequence.
@(private)
text_snap :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	for j > 0 && j < len(s) && (s[j] & 0xC0) == 0x80 {
		j -= 1
	}
	return j
}

// Active editable buffer (inline project title or settings form fields).
@(private)
text_active :: proc(a: ^App) -> (buf: []u8, len_out: ^int, ok: bool) {
	if a == nil || (a.mode != .Settings && a.mode != .Normal) {
		return nil, nil, false
	}
	if a.mode == .Normal && a.track_edit {
		return a.track_name_draft[:], &a.track_name_draft_len, true
	}
	if a.project_name_edit {
		return a.project_name_draft[:], &a.project_name_draft_len, true
	}
	if a.mode != .Settings {
		return nil, nil, false
	}
	if a.new_project_edit {
		return a.new_project_draft[:], &a.new_project_draft_len, true
	}
	if a.settings_path_edit {
		return a.settings_path[:], &a.settings_path_len, true
	}
	switch a.cloud_edit {
	case .Folder:
		return a.cloud_folder[:], &a.cloud_folder_len, true
	case .Client_ID:
		return a.cloud_client_id[:], &a.cloud_client_id_len, true
	case .Client_Secret:
		return a.cloud_client_secret[:], &a.cloud_client_secret_len, true
	case .None:
		return nil, nil, false
	}
	return nil, nil, false
}

// Editable field order used by Tab and by pointer hit testing.
text_field_index :: proc(a: ^App) -> int {
	if a == nil || (a.mode != .Settings && a.mode != .Normal) {
		return -1
	}
	if a.mode == .Normal && a.track_edit {
		return 5
	}
	if a.project_name_edit {
		return 0
	}
	if a.mode != .Settings {
		return -1
	}
	if a.new_project_edit {
		return 6
	}
	if a.settings_path_edit {
		return 1
	}
	switch a.cloud_edit {
	case .Folder:
		return 2
	case .Client_ID:
		return 3
	case .Client_Secret:
		return 4
	case .None:
	}
	return -1
}

// Starts editing the field at `index` (0..4) without clearing drafts in the
// other fields. The selection item follows so j/k and Tab stay in sync.
text_field_begin :: proc(a: ^App, index: int) {
	if a == nil {
		return
	}
	if a.mode == .Normal {
		if index == 5 {
			return // already editing: the click only moves the caret
		}
		if index == 0 && !a.project_name_edit {
			app_project_begin_edit(a, false)
		}
		return
	}
	if a.mode != .Settings {
		return
	}
	switch index {
	case 0:
		a.settings_sel = .Project_Name
		if !a.project_name_edit {
			app_project_begin_edit(a, false)
		}
	case 1:
		a.settings_sel = .Path
		if !a.settings_path_edit {
			app_settings_begin_edit(a)
		}
	case 2:
		a.settings_sel = .Cloud_Folder
		if a.cloud_edit != .Folder {
			app_cloud_begin_edit(a, .Folder)
		}
	case 3:
		a.settings_sel = .Cloud_Client_ID
		if a.cloud_edit != .Client_ID {
			app_cloud_begin_edit(a, .Client_ID)
		}
	case 4:
		a.settings_sel = .Cloud_Client_Secret
		if a.cloud_edit != .Client_Secret {
			app_cloud_begin_edit(a, .Client_Secret)
		}
	case 6:
		a.settings_sel = .New_Project
		if !a.new_project_edit {
			a.new_project_open = true
			a.new_project_edit = true
			a.project_name_edit = false
			a.settings_path_edit = false
			a.cloud_edit = .None
			a.edit_confirm = false
			a.edit_select_all = false
			a.text_cursor = a.new_project_draft_len
			a.text_anchor = a.text_cursor
			a.text_scroll_x = 0
			a.text_typing = false
			a.text_dragging = false
			a.text_drag_multi = false
			text_history_reset(a)
			bump_revision(a)
		}
	}
}

text_field_length :: proc(a: ^App) -> int {
	_, len_out, ok := text_active(a)
	return len_out^ if ok else 0
}

@(private)
text_clamp :: proc(a: ^App) {
	n := text_field_length(a)
	a.text_cursor = clamp(a.text_cursor, 0, n)
	a.text_anchor = clamp(a.text_anchor, 0, n)
}

@(private)
text_selection :: proc(a: ^App) -> (lo, hi: int) {
	text_clamp(a)
	return min(a.text_cursor, a.text_anchor), max(a.text_cursor, a.text_anchor)
}

@(private)
text_sync_select_all :: proc(a: ^App) {
	lo, hi := text_selection(a)
	a.edit_select_all = lo == 0 && hi == text_field_length(a) && lo != hi
}

@(private)
text_remove :: proc(buf: []u8, len_out: ^int, lo, hi: int) {
	a := clamp(lo, 0, len_out^)
	b := clamp(hi, a, len_out^)
	copy(buf[a:], buf[b:len_out^])
	len_out^ -= b - a
}

@(private)
text_insert_bytes :: proc(buf: []u8, len_out: ^int, at: int, s: string) -> int {
	pos := clamp(at, 0, len_out^)
	n := min(len(s), len(buf) - len_out^)
	if n <= 0 {
		return 0
	}
	copy(buf[pos + n:], buf[pos:len_out^])
	copy(buf[pos:], s[:n])
	len_out^ += n
	return n
}

@(private)
text_snapshot_bytes :: proc(buf: []u8, n: int) -> []u8 {
	out := make([]u8, n)
	copy(out, buf[:n])
	return out
}

@(private)
text_push_undo :: proc(a: ^App) {
	buf, len_out, ok := text_active(a)
	if !ok {
		return
	}
	if a.text_undo_count >= len(a.text_undo) {
		delete(a.text_undo[0].text)
		for i in 1 ..< len(a.text_undo) {
			a.text_undo[i - 1] = a.text_undo[i]
		}
		a.text_undo_count -= 1
	}
	a.text_undo[a.text_undo_count] = {
		text = text_snapshot_bytes(buf, len_out^),
		cursor = a.text_cursor,
		anchor = a.text_anchor,
	}
	a.text_undo_count += 1
	for i in 0 ..< a.text_redo_count {
		delete(a.text_redo[i].text)
	}
	a.text_redo_count = 0
}

@(private)
text_restore :: proc(a: ^App, snap: Text_Snapshot) {
	buf, len_out, ok := text_active(a)
	if !ok {
		return
	}
	n := min(len(snap.text), len(buf))
	copy(buf[:n], snap.text[:n])
	len_out^ = n
	a.text_cursor = clamp(snap.cursor, 0, n)
	a.text_anchor = clamp(snap.anchor, 0, n)
}

text_undo :: proc(a: ^App) -> bool {
	if a.text_undo_count <= 0 {
		return false
	}
	buf, len_out, ok := text_active(a)
	if !ok {
		return false
	}
	if a.text_redo_count < len(a.text_redo) {
		a.text_redo[a.text_redo_count] = {
			text = text_snapshot_bytes(buf, len_out^),
			cursor = a.text_cursor,
			anchor = a.text_anchor,
		}
		a.text_redo_count += 1
	}
	a.text_undo_count -= 1
	snap := a.text_undo[a.text_undo_count]
	text_restore(a, snap)
	a.text_typing = false
	text_sync_select_all(a)
	if a.cloud_edit != .None {
		a.cloud_dirty = true
	}
	delete(snap.text)
	a.text_undo[a.text_undo_count] = {}
	return true
}

text_redo :: proc(a: ^App) -> bool {
	if a.text_redo_count <= 0 {
		return false
	}
	buf, len_out, ok := text_active(a)
	if !ok {
		return false
	}
	if a.text_undo_count < len(a.text_undo) {
		a.text_undo[a.text_undo_count] = {
			text = text_snapshot_bytes(buf, len_out^),
			cursor = a.text_cursor,
			anchor = a.text_anchor,
		}
		a.text_undo_count += 1
	}
	a.text_redo_count -= 1
	snap := a.text_redo[a.text_redo_count]
	text_restore(a, snap)
	a.text_typing = false
	text_sync_select_all(a)
	if a.cloud_edit != .None {
		a.cloud_dirty = true
	}
	delete(snap.text)
	a.text_redo[a.text_redo_count] = {}
	return true
}

text_history_reset :: proc(a: ^App) {
	for i in 0 ..< a.text_undo_count {
		delete(a.text_undo[i].text)
	}
	for i in 0 ..< a.text_redo_count {
		delete(a.text_redo[i].text)
	}
	a.text_undo_count = 0
	a.text_redo_count = 0
	a.text_typing = false
}

@(private)
text_move :: proc(a: ^App, to: int, shift: bool) {
	text_clamp(a)
	a.text_typing = false
	if shift && a.text_cursor == a.text_anchor {
		a.text_anchor = a.text_cursor
	}
	buf, len_out, ok := text_active(a)
	limit := len_out^ if ok else 0
	a.text_cursor = text_snap(string(buf[:limit]) if ok else "", to)
	if !shift {
		a.text_anchor = a.text_cursor
	}
	text_sync_select_all(a)
}

text_set_cursor :: proc(a: ^App, index: int, shift: bool) {
	if _, _, ok := text_active(a); !ok {
		return
	}
	buf, len_out, ok := text_active(a)
	if !ok {
		return
	}
	s := string(buf[:len_out^])
	pos := text_snap(s, index)
	a.text_typing = false
	if !shift {
		a.text_cursor = pos
		a.text_anchor = pos
	} else {
		if a.text_cursor == a.text_anchor {
			a.text_anchor = a.text_cursor
		}
		a.text_cursor = pos
	}
	text_sync_select_all(a)
}

text_select_all :: proc(a: ^App) {
	if _, _, ok := text_active(a); !ok {
		return
	}
	a.text_anchor = 0
	a.text_cursor = text_field_length(a)
	a.text_typing = false
	a.edit_select_all = true
}

text_select_word_at :: proc(a: ^App, index: int) {
	buf, len_out, ok := text_active(a)
	if !ok {
		return
	}
	s := string(buf[:len_out^])
	at := text_snap(s, index)
	a.text_anchor = text_word_left(s, at)
	a.text_cursor = text_word_right(s, at)
	a.text_typing = false
	text_sync_select_all(a)
}

@(private)
text_delete_selection :: proc(a: ^App) -> bool {
	lo, hi := text_selection(a)
	if lo == hi {
		return false
	}
	buf, len_out, ok := text_active(a)
	if !ok {
		return false
	}
	text_remove(buf, len_out, lo, hi)
	a.text_cursor = lo
	a.text_anchor = lo
	a.edit_select_all = false
	return true
}

@(private)
text_replace :: proc(a: ^App, text: string, coalesce: bool) -> bool {
	buf, len_out, ok := text_active(a)
	if !ok || text == "" {
		return false
	}
	if !coalesce || !a.text_typing {
		text_push_undo(a)
	}
	_ = text_delete_selection(a)
	at := clamp(a.text_cursor, 0, len_out^)
	added := text_insert_bytes(buf, len_out, at, text)
	a.text_cursor = at + added
	a.text_anchor = a.text_cursor
	a.text_typing = coalesce
	a.edit_select_all = false
	a.edit_confirm = false
	if a.cloud_edit != .None {
		a.cloud_dirty = true
	}
	return true
}

// Inserts a typed character, coalescing a run of keystrokes into one undo step.
text_insert :: proc(a: ^App, text: string) -> bool {
	return text_replace(a, text, true)
}

// Inserts pasted text as its own undo step, replacing any selection.
text_paste :: proc(a: ^App, text: string) -> bool {
	return text_replace(a, text, false)
}

@(private)
text_backspace :: proc(a: ^App, word: bool) -> bool {
	if lo, hi := text_selection(a); lo != hi {
		text_push_undo(a)
		_ = text_delete_selection(a)
		return true
	}
	buf, len_out, ok := text_active(a)
	if !ok || len_out^ <= 0 || a.text_cursor <= 0 {
		return false
	}
	text_push_undo(a)
	s := string(buf[:len_out^])
	from := text_word_left(s, a.text_cursor) if word else text_prev_offset(s, a.text_cursor)
	text_remove(buf, len_out, from, a.text_cursor)
	a.text_cursor = from
	a.text_anchor = from
	a.text_typing = false
	text_sync_select_all(a)
	if a.cloud_edit != .None {
		a.cloud_dirty = true
	}
	return true
}

@(private)
text_delete_forward :: proc(a: ^App, word: bool) -> bool {
	if lo, hi := text_selection(a); lo != hi {
		text_push_undo(a)
		_ = text_delete_selection(a)
		return true
	}
	buf, len_out, ok := text_active(a)
	if !ok || a.text_cursor >= len_out^ {
		return false
	}
	text_push_undo(a)
	s := string(buf[:len_out^])
	to := text_word_right(s, a.text_cursor) if word else text_next_offset(s, a.text_cursor)
	text_remove(buf, len_out, a.text_cursor, to)
	a.text_typing = false
	text_sync_select_all(a)
	if a.cloud_edit != .None {
		a.cloud_dirty = true
	}
	return true
}

text_key :: proc(a: ^App, key: Key, ch: u8, shift, ctrl: bool) -> bool {
	buf, len_out, ok := text_active(a)
	if !ok {
		return false
	}
	s := string(buf[:len_out^])
	#partial switch key {
	case .Left:
		to := text_word_left(s, a.text_cursor) if ctrl else text_prev_offset(s, a.text_cursor)
		if !shift && a.text_cursor != a.text_anchor {
			lo, _ := text_selection(a)
			text_move(a, lo, false)
		} else {
			text_move(a, to, shift)
		}
		return true
	case .Right:
		to := text_word_right(s, a.text_cursor) if ctrl else text_next_offset(s, a.text_cursor)
		if !shift && a.text_cursor != a.text_anchor {
			_, hi := text_selection(a)
			text_move(a, hi, false)
		} else {
			text_move(a, to, shift)
		}
		return true
	case .Home:
		text_move(a, 0, shift)
		return true
	case .End:
		text_move(a, len_out^, shift)
		return true
	case .Backspace:
		return text_backspace(a, ctrl)
	case .Delete:
		return text_delete_forward(a, ctrl)
	case .Space:
		if ctrl {
			return false
		}
		if a.cloud_edit != .Folder && a.cloud_edit != .None {
			return true // credentials never contain spaces
		}
		return text_insert(a, " ")
	case .Char:
		if ctrl || ch < 32 || ch > 126 {
			return false
		}
		return text_insert(a, string([]u8{ch}))
	case:
		return false
	}
}

// Returns the selected text (caller owns it) and optionally cuts it.
text_clipboard :: proc(a: ^App, cut: bool) -> (string, bool) {
	lo, hi := text_selection(a)
	if lo == hi {
		return "", false
	}
	buf, len_out, ok := text_active(a)
	if !ok {
		return "", false
	}
	out := strings.clone(string(buf[lo:hi]))
	if cut {
		text_push_undo(a)
		text_remove(buf, len_out, lo, hi)
		a.text_cursor = lo
		a.text_anchor = lo
		a.text_typing = false
		a.edit_select_all = false
		if a.cloud_edit != .None {
			a.cloud_dirty = true
		}
	}
	return out, true
}
