// Pointer-aware rendering for the settings text fields.
//
// The model owns the caret/anchor (byte offsets into the active buffer); this
// file maps vinland's pointer coordinates onto those offsets, draws the
// selection and caret, and keeps the active field scrolled to the caret. It is
// deliberately generic: path, folder and credential fields all use it.

package ui

import vui "vinland:vui"

TEXT_FIELD_FONT_SIZE :: 11
TEXT_FIELD_CARET_H :: 14

@(private = "file")
text_field_style :: proc() -> vui.Style {
	s: vui.Style
	s.font_family = "mono"
	s.font_size = TEXT_FIELD_FONT_SIZE
	s.font_weight = 400
	return s
}

@(private = "file")
text_display :: proc(value: string, masked: bool) -> string {
	return cloud_mask_secret(value) if masked else value
}

// Plain byte offset -> caret-stop index in the displayed (possibly masked)
// string.
@(private = "file")
text_display_index :: proc(value: string, masked: bool, off: int) -> int {
	if masked {
		return clamp(off, 0, min(len(value), 32))
	}
	return clamp(off, 0, len(value))
}

@(private = "file")
text_stop_for_offset :: proc(offsets: []int, off: int) -> int {
	for o, i in offsets {
		if o >= off {
			return i
		}
	}
	return len(offsets) - 1
}

// Caret-stop index under a mouse x coordinate. Ties choose the earlier stop,
// so clicking the left half of a glyph lands before it.
@(private = "file")
text_stop_at_x :: proc(xs: []f32, x: f32) -> int {
	best := 0
	bd := f32(1e30)
	for v, i in xs {
		d := abs(v - x)
		if d < bd {
			bd = d
			best = i
		}
	}
	return best
}

@(private = "file")
text_stop_plain_offset :: proc(value: string, masked: bool, offsets: []int, stop: int) -> int {
	if masked {
		if len(value) > 32 && stop >= 32 {
			return len(value)
		}
		return clamp(stop, 0, len(value))
	}
	return offsets[clamp(stop, 0, len(offsets) - 1)]
}

// Draws one editable field inside an already-open relative/flex parent.
// `rect` is that parent's previous-frame rect. Presses begin editing at the
// clicked character; dragging, Shift+click, double-click (word) and
// triple-click (all) follow the desktop convention.
text_field_view :: proc(a: ^App, index: int, value: string, masked, editing: bool, placeholder: string, rect: vui.Rect) {
	ctx := vui.ctx_get()
	if ctx == nil {
		return
	}
	display := text_display(value, masked)
	style := text_field_style()
	offsets, xs := vui.caret_stops(&ctx.fonts, &ctx.theme, display, &style)
	in_ := &ctx.input
	inside := vui.rect_contains(rect, in_.mouse)
	is_editing := editing

	if inside && .Left in in_.pressed {
		stop := text_stop_at_x(xs, in_.mouse.x - rect.x + a.text_scroll_x)
		off := text_stop_plain_offset(value, masked, offsets, stop)
		text_field_begin(a, index)
		is_editing = text_field_index(a) == index
		switch {
		case in_.click_count >= 3:
			text_select_all(a)
		case in_.click_count == 2:
			text_select_word_at(a, off)
		case .Shift in in_.mods:
			text_set_cursor(a, off, true)
		case:
			text_set_cursor(a, off, false)
		}
		a.text_dragging = true
		a.text_drag_multi = in_.click_count >= 2
		a.text_drag_field = index
	} else if a.text_dragging && !a.text_drag_multi && a.text_drag_field == index && .Left in in_.buttons {
		stop := text_stop_at_x(xs, in_.mouse.x - rect.x + a.text_scroll_x)
		off := text_stop_plain_offset(value, masked, offsets, stop)
		text_set_cursor(a, off, true)
	} else if a.text_drag_field == index && .Left not_in in_.buttons {
		a.text_dragging = false
		a.text_drag_multi = false
	}

	is_editing = text_field_index(a) == index
	cursor_stop := text_stop_for_offset(offsets, text_display_index(value, masked, a.text_cursor))
	anchor_stop := text_stop_for_offset(offsets, text_display_index(value, masked, a.text_anchor))
	cursor_x := xs[cursor_stop]
	anchor_x := xs[anchor_stop]

	inner_w := rect.w
	if is_editing && inner_w > 4 {
		total := xs[len(xs) - 1]
		if cursor_x - a.text_scroll_x > inner_w - 2 {
			a.text_scroll_x = cursor_x - inner_w + 2
		}
		if cursor_x - a.text_scroll_x < 0 {
			a.text_scroll_x = cursor_x
		}
		a.text_scroll_x = clamp(a.text_scroll_x, 0, max(total - inner_w + 2, 0))
	}

	if is_editing && cursor_stop != anchor_stop {
		x0 := min(cursor_x, anchor_x) - a.text_scroll_x
		x1 := max(cursor_x, anchor_x) - a.text_scroll_x
		vui.el("absolute")
		sel := vui.last_style()
		sel.inset = {vui.px(2), vui.AUTO, vui.px(2), vui.px(x0)}
		sel.width = vui.px(max(x1 - x0, 1))
		sel.bg = vui.oklch(0.73, 0.157, 57, 0.32)
		vui.last().flags += {.No_Hit}
	}

	show := display
	empty := len(display) == 0
	if empty && placeholder != "" {
		show = placeholder
	}
	vui.text(show, vui.cx("whitespace-pre text-[11px]", empty ? "text-ink-muted" : "text-ink"))
	ts := vui.last_style()
	if is_editing {
		ts.margin[3] = -a.text_scroll_x
	}
	vui.last().flags += {.No_Hit}

	if is_editing {
		vui.el("absolute w-[2px] animate-pulse bg-sig")
		cs := vui.last_style()
		cs.width = vui.px(2)
		cs.height = vui.px(TEXT_FIELD_CARET_H)
		cs.inset = {vui.pct(50), vui.AUTO, vui.AUTO, vui.px(cursor_x - a.text_scroll_x)}
		cs.translate = {vui.px(0), vui.pct(-50)}
		vui.last().flags += {.No_Hit}
	}
}
