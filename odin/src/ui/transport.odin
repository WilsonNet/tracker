package ui

import "core:fmt"
import "core:math"

// Transport model: pause vs stop, the single return marker, pre-roll, punch-in
// parameters and the lead-in audition. Pure state; the engine reads
// `record_punch` / `record_pre` when it receives `.Record_Start`.
//
//   Space   play <-> pause in place (punches out while recording)
//   STOP    stop and return to the marker; again -> 00:00
//   M       drop / move the marker at the playhead (works while playing)
//   p       audition: play the lead-in up to the playhead, pause there
//   r       record at the playhead after the pre-roll; Ctrl/Alt+r or
//           Shift+click REC records immediately

PREROLL_STEPS := [?]f32{0, 1, 2, 3, 5, 10}
PREROLL_DEFAULT_IDX :: 3 // 3 s
AUDITION_MIN_SECONDS :: 2.0

Timing_Mode :: enum u8 {
	Grid,
	Free,
}

Time_Sig :: struct {
	num:   u8,
	den:   u8,
	label: string,
}

TIME_SIGS := [?]Time_Sig{
	{4, 4, "4/4"},
	{3, 4, "3/4"},
	{6, 8, "6/8"},
	{5, 4, "5/4"},
	{7, 8, "7/8"},
	{2, 4, "2/4"},
}
TIME_SIG_DEFAULT_IDX :: 0

Preroll_Grid_Preset :: struct {
	bars:  int,
	beats: int,
	label: string,
}

PREROLL_GRID_STEPS := [?]Preroll_Grid_Preset{
	{0, 0, "OFF"},
	{0, 2, "2 BT"},
	{1, 0, "1 BAR"},
	{2, 0, "2 BAR"},
	{4, 0, "4 BAR"},
}
PREROLL_GRID_DEFAULT_IDX :: 2 // 1 BAR

app_time_sig :: proc(a: ^App) -> Time_Sig {
	if a == nil {
		return TIME_SIGS[TIME_SIG_DEFAULT_IDX]
	}
	return TIME_SIGS[clamp(a.time_sig_idx, 0, len(TIME_SIGS) - 1)]
}

app_beat_frames_f64 :: proc(a: ^App) -> f64 {
	sig := app_time_sig(a)
	bpm := f64(clamp(a.bpm if a != nil else 120, 40, 240))
	rate := f64(app_rate(a))
	return max((60.0 / bpm) * (4.0 / f64(max(int(sig.den), 1))) * rate, 1.0)
}

app_bar_frames_f64 :: proc(a: ^App) -> f64 {
	sig := app_time_sig(a)
	return app_beat_frames_f64(a) * f64(max(int(sig.num), 1))
}

app_frame_to_bar_beat :: proc(a: ^App, frame: i64) -> (bar: int, beat: int, frac: f64) {
	sig := app_time_sig(a)
	num := i64(max(int(sig.num), 1))
	beat_f := app_beat_frames_f64(a)
	total_beats := f64(frame) / beat_f
	if abs(total_beats - math.round(total_beats)) < 1e-4 {
		total_beats = math.round(total_beats)
	}
	bi := i64(math.floor(total_beats))
	frac = clamp(total_beats - f64(bi), 0, 0.9999)
	if frame >= 0 {
		bar = int(bi / num) + 1
		beat = int(bi % num) + 1
	} else {
		bar = int(math.floor(f64(bi) / f64(num)))
		beat = int(((bi % num) + num) % num) + 1
	}
	return bar, beat, frac
}

app_bar_beat_parts :: proc(a: ^App, frame: i64) -> (main: string, sub: string) {
	bar, beat, frac := app_frame_to_bar_beat(a, frame)
	if bar >= 0 {
		main = fmt.tprintf("%03d.%d", bar, beat)
	} else {
		main = fmt.tprintf("-%02d.%d", -bar, beat)
	}
	centi := clamp(int(math.floor(frac * 100.0 + 1e-6)), 0, 99)
	sub = fmt.tprintf(".%02d", centi)
	return main, sub
}

app_position_text :: proc(a: ^App, frame: i64) -> string {
	if a != nil && a.timing_mode == .Grid {
		main, sub := app_bar_beat_parts(a, frame)
		return fmt.tprintf("%s%s", main, sub)
	}
	rate := a.sample_rate if a != nil else 48_000
	return timecode(max(frame, 0), rate)
}

app_short_pos_text :: proc(a: ^App, frame: i64) -> string {
	if a != nil && a.timing_mode == .Grid {
		bar, beat, frac := app_frame_to_bar_beat(a, frame)
		centi := clamp(int(math.floor(frac * 100.0 + 1e-6)), 0, 99)
		if centi == 0 {
			return fmt.tprintf("%d.%d", bar, beat)
		}
		return fmt.tprintf("%d.%d.%02d", bar, beat, centi)
	}
	return render_time_text(f32(max(frame, 0)) / f32(app_rate(a)))
}

app_duration_text :: proc(a: ^App, frames: i64) -> string {
	if a == nil || frames <= 0 {
		return ""
	}
	if a.timing_mode == .Grid {
		sig := app_time_sig(a)
		num := max(int(sig.num), 1)
		total_beats := f64(frames) / app_beat_frames_f64(a)
		bars := int(math.floor(total_beats / f64(num) + 1e-4))
		rem_beats := int(math.round(total_beats - f64(bars * num)))
		if rem_beats >= num {
			bars += 1
			rem_beats = 0
		}
		if bars <= 0 {
			return "<1 BAR" if rem_beats <= 0 else fmt.tprintf("%d BT", rem_beats)
		}
		if rem_beats == 0 {
			return fmt.tprintf("%d BAR", bars)
		}
		return fmt.tprintf("%d.%d BAR", bars, rem_beats)
	}
	return render_time_text(f32(frames) / f32(app_rate(a)))
}

app_tape_length_text :: proc(a: ^App) -> string {
	if a == nil || a.tape_frames <= 0 {
		return ""
	}
	return app_duration_text(a, a.tape_frames)
}

app_range_start :: proc(a: ^App) -> i64 {
	if a == nil || !a.marker_set {
		return 0
	}
	return max(a.marker, 0)
}

app_range_valid :: proc(a: ^App) -> bool {
	return a != nil && a.end_marker_set && a.end_marker > app_range_start(a)
}

app_loop_active :: proc(a: ^App) -> bool {
	return app_range_valid(a) && a.loop_enabled
}

app_punch_out_active :: proc(a: ^App) -> bool {
	return app_range_valid(a) && a.punch_out_enabled
}

app_range_length_text :: proc(a: ^App) -> string {
	if !app_range_valid(a) {
		return ""
	}
	return app_duration_text(a, a.end_marker - app_range_start(a))
}

app_clock_short :: proc(frame: i64, rate: u32) -> string {
	neg := frame < 0
	abs_f := -frame if neg else frame
	r := max(i64(rate), 1)
	tenths := int((abs_f * 10 + r / 2) / r)
	deci := tenths % 10
	total_s := tenths / 10
	s := total_s % 60
	m := total_s / 60
	if neg {
		return fmt.tprintf("-%02d:%02d.%d", m, s, deci)
	}
	return fmt.tprintf("%02d:%02d.%d", m, s, deci)
}

app_current_beat_in_bar :: proc(a: ^App) -> int {
	sig := app_time_sig(a)
	_, beat, _ := app_frame_to_bar_beat(a, a.frames)
	return clamp(beat - 1, 0, max(int(sig.num) - 1, 0))
}

app_preroll_seconds :: proc(a: ^App) -> f32 {
	return PREROLL_STEPS[clamp(a.preroll_idx, 0, len(PREROLL_STEPS) - 1)]
}

app_preroll_beats :: proc(a: ^App) -> int {
	p := PREROLL_GRID_STEPS[clamp(a.preroll_grid_idx, 0, len(PREROLL_GRID_STEPS) - 1)]
	if p.bars > 0 {
		return p.bars * int(app_time_sig(a).num)
	}
	return p.beats
}

app_preroll_frames :: proc(a: ^App) -> i64 {
	if a.timing_mode == .Grid {
		beats := app_preroll_beats(a)
		if beats <= 0 {
			return 0
		}
		return i64(math.round(f64(beats) * app_beat_frames_f64(a)))
	}
	s := app_preroll_seconds(a)
	if s <= 0 {
		return 0
	}
	return i64(math.round(f64(s) * f64(app_rate(a))))
}

app_preroll_active :: proc(a: ^App) -> bool {
	if a.timing_mode == .Grid {
		return app_preroll_beats(a) > 0
	}
	return app_preroll_seconds(a) > 0
}

app_preroll_label :: proc(a: ^App) -> string {
	if a.timing_mode == .Grid {
		return PREROLL_GRID_STEPS[clamp(a.preroll_grid_idx, 0, len(PREROLL_GRID_STEPS) - 1)].label
	}
	s := app_preroll_seconds(a)
	if s <= 0 {
		return "OFF"
	}
	return fmt.tprintf("%.0f s", s)
}

// Sets the pre-roll by seconds (settings load); unknown values pick the
// nearest step.
app_set_preroll_seconds :: proc(a: ^App, seconds: f32) {
	best := 0
	bd := f32(1e9)
	for s, i in PREROLL_STEPS {
		if d := abs(s - seconds); d < bd {
			bd = d
			best = i
		}
	}
	a.preroll_idx = best
}

app_set_preroll_grid_idx :: proc(a: ^App, idx: int) {
	a.preroll_grid_idx = clamp(idx, 0, len(PREROLL_GRID_STEPS) - 1)
}

app_set_time_sig :: proc(a: ^App, num, den: int) {
	for sig, i in TIME_SIGS {
		if int(sig.num) == num && int(sig.den) == den {
			a.time_sig_idx = i
			return
		}
	}
	a.time_sig_idx = TIME_SIG_DEFAULT_IDX
}

app_time_sig_cycle :: proc(a: ^App) {
	if a.transport == .Recording {
		toast(a, "stop recording to change meter")
		status_buf_set(a, "stop recording to change meter")
		return
	}
	a.time_sig_idx = (a.time_sig_idx + 1) % len(TIME_SIGS)
	sig := app_time_sig(a)
	msg := fmt.tprintf("time signature %s", sig.label)
	status_buf_set(a, msg)
	toast(a, sig.label)
	app_history_note(a, "meter")
	app_touch(a)
}

app_timing_mode_toggle :: proc(a: ^App) {
	if a.transport == .Recording {
		toast(a, "stop recording to switch timing")
		status_buf_set(a, "stop recording to switch timing")
		return
	}
	a.timing_mode = .Free if a.timing_mode == .Grid else .Grid
	if a.frames < 0 {
		a.frames = 0
	}
	a.settings_dirty = true
	a.dirty = true
	msg := "timing: free tape (seconds)" if a.timing_mode == .Free else "timing: grid (clicktrack + magnetic scrub)"
	status_buf_set(a, msg)
	toast(a, "FREE TAPE" if a.timing_mode == .Free else "GRID MODE")
	bump_revision(a)
}

app_preroll_cycle :: proc(a: ^App) {
	if a.timing_mode == .Grid {
		a.preroll_grid_idx = (a.preroll_grid_idx + 1) % len(PREROLL_GRID_STEPS)
	} else {
		a.preroll_idx = (a.preroll_idx + 1) % len(PREROLL_STEPS)
	}
	a.settings_dirty = true
	msg := fmt.tprintf("pre-roll %s", app_preroll_label(a))
	status_buf_set(a, msg)
	toast(a, msg)
	bump_revision(a)
}

app_preroll_audio_toggle :: proc(a: ^App) {
	a.preroll_audio = !a.preroll_audio
	a.settings_dirty = true
	status_buf_set(a, "pre-roll: song audio" if a.preroll_audio else "pre-roll: click only")
	toast(a, "PRE-ROLL: SONG" if a.preroll_audio else "PRE-ROLL: CLICK")
	bump_revision(a)
}

// Frames of silence-free guide playback the engine runs before the punch.
app_rate :: proc(a: ^App) -> i64 {
	return max(i64(a.sample_rate), 1)
}

// True while a recording is still in its pre-roll (guide plays, nothing kept).
app_in_preroll :: proc(a: ^App) -> bool {
	return a.transport == .Recording && a.frames < a.record_punch
}

app_preroll_left_seconds :: proc(a: ^App) -> f32 {
	if !app_in_preroll(a) {
		return 0
	}
	return f32(a.record_punch - a.frames) / f32(app_rate(a))
}

app_preroll_left_beats :: proc(a: ^App) -> f32 {
	if !app_in_preroll(a) {
		return 0
	}
	return f32(f64(a.record_punch - a.frames) / app_beat_frames_f64(a))
}

// ---------------------------------------------------------------- pause / stop

app_pause :: proc(a: ^App) {
	if a.transport != .Playing {
		return
	}
	a.audition_end = 0
	a.transport = .Stopped
	a.tape_cued = a.frames > 0
	status_buf_set(a, fmt.tprintf("paused %s · Space resumes", app_position_text(a, a.frames)))
	emit(a, .Stop)
	bump_revision(a)
}

// STOP: halt and return to the marker (00:00 without one). Already there ->
// 00:00. While recording it punches out and stays put, like Space.
app_stop_return :: proc(a: ^App) {
	if a.transport == .Recording {
		app_execute(a, .Record_Stop)
		return
	}
	was_stopped := a.transport == .Stopped
	a.audition_end = 0
	a.transport = .Stopped
	target: i64 = 0
	if a.marker_set {
		target = a.marker
	}
	if was_stopped && a.frames == target {
		target = 0
	}
	a.frames = target
	a.tape_cued = target > 0
	if target > 0 {
		status_buf_set(a, fmt.tprintf("stopped · back at the marker %s", app_position_text(a, target)))
	} else {
		status_buf_set(a, "stopped")
	}
	emit(a, .Stop)
	emit(a, .Seek)
	bump_revision(a)
}

// ---------------------------------------------------------------- marker

app_marker_set :: proc(a: ^App) {
	if a.marker_set && a.marker == a.frames {
		app_marker_clear(a)
		return
	}
	a.marker = max(a.frames, 0)
	a.marker_set = true
	a.dirty = true
	if a.end_marker_set && a.marker >= a.end_marker {
		a.end_marker_set = false
		a.end_marker = 0
		a.loop_enabled = false
		a.punch_out_enabled = false
		msg := fmt.tprintf("in %s · out cleared", app_position_text(a, a.marker))
		status_buf_set(a, msg)
		toast(a, fmt.tprintf("in %s · out cleared", app_short_pos_text(a, a.marker)))
	} else {
		msg := fmt.tprintf("marker %s · STOP returns here", app_position_text(a, a.marker))
		status_buf_set(a, msg)
		toast(a, fmt.tprintf("marker %s", app_position_text(a, a.marker)))
	}
	bump_revision(a)
}

app_marker_clear :: proc(a: ^App) {
	if !a.marker_set {
		return
	}
	a.marker_set = false
	a.marker = 0
	a.dirty = true
	status_buf_set(a, fmt.tprintf("marker cleared · STOP returns to %s", app_position_text(a, 0)))
	bump_revision(a)
}

app_marker_goto :: proc(a: ^App) {
	if !a.marker_set {
		toast(a, "no marker · M drops one at the playhead")
		return
	}
	if a.transport == .Recording {
		toast(a, "punch out first, then jump to the marker")
		return
	}
	a.audition_end = 0
	a.frames = a.marker
	a.tape_cued = a.frames > 0
	status_buf_set(a, fmt.tprintf("cue %s (marker)", app_position_text(a, a.frames)))
	a.last_command = .Seek
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
}

// Restores the marker from a project (frames at the project rate).
app_set_marker :: proc(a: ^App, frame: i64) {
	a.marker_set = frame >= 0
	a.marker = max(frame, 0)
	bump_revision(a)
}

// ---------------------------------------------------------------- end marker & section loop

app_end_marker_set :: proc(a: ^App) {
	if a.end_marker_set && a.end_marker == a.frames {
		app_end_marker_clear(a)
		return
	}
	pos := max(a.frames, 0)
	start := app_range_start(a)
	if pos <= start {
		if a.marker_set {
			msg := fmt.tprintf("end marker must be after IN (%s)", app_short_pos_text(a, start))
			status_buf_set(a, msg)
			toast(a, msg)
		} else {
			status_buf_set(a, "jog past start to set OUT marker")
			toast(a, "jog past start to set OUT marker")
		}
		return
	}
	a.end_marker = pos
	a.end_marker_set = true
	a.dirty = true
	msg := fmt.tprintf("out %s · section %s → %s (%s)", app_short_pos_text(a, pos), app_short_pos_text(a, start), app_short_pos_text(a, pos), app_range_length_text(a))
	status_buf_set(a, msg)
	toast(a, fmt.tprintf("OUT %s", app_short_pos_text(a, pos)))
	bump_revision(a)
}

app_end_marker_clear :: proc(a: ^App) {
	if !a.end_marker_set {
		return
	}
	a.end_marker_set = false
	a.end_marker = 0
	a.loop_enabled = false
	a.punch_out_enabled = false
	a.dirty = true
	status_buf_set(a, "end marker cleared")
	bump_revision(a)
}

app_end_marker_goto :: proc(a: ^App) {
	if !a.end_marker_set {
		toast(a, "no end marker · E drops one at the playhead")
		return
	}
	if a.transport == .Recording {
		toast(a, "punch out first, then jump to OUT")
		return
	}
	a.audition_end = 0
	a.frames = a.end_marker
	a.tape_cued = a.frames > 0
	status_buf_set(a, fmt.tprintf("cue %s (out)", app_position_text(a, a.frames)))
	a.last_command = .Seek
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
}

app_set_end_marker :: proc(a: ^App, frame: i64) {
	if frame > app_range_start(a) {
		a.end_marker_set = true
		a.end_marker = frame
	} else {
		a.end_marker_set = false
		a.end_marker = 0
		a.loop_enabled = false
		a.punch_out_enabled = false
	}
	bump_revision(a)
}

app_loop_toggle :: proc(a: ^App) {
	if !app_range_valid(a) {
		status_buf_set(a, "set an OUT marker (E) to loop a section")
		toast(a, "set an OUT marker (E) to loop")
		return
	}
	a.loop_enabled = !a.loop_enabled
	a.dirty = true
	if a.loop_enabled {
		status_buf_set(a, fmt.tprintf("loop %s → %s (%s)", app_short_pos_text(a, app_range_start(a)), app_short_pos_text(a, a.end_marker), app_range_length_text(a)))
		toast(a, "LOOP ON")
	} else {
		status_buf_set(a, "loop off")
		toast(a, "LOOP OFF")
	}
	bump_revision(a)
}

app_punch_out_toggle :: proc(a: ^App) {
	if a.transport == .Recording {
		status_buf_set(a, "stop recording to change punch-out")
		toast(a, "stop recording to change punch-out")
		return
	}
	if !app_range_valid(a) {
		status_buf_set(a, "set an OUT marker (E) for auto punch-out")
		toast(a, "set an OUT marker (E) for punch-out")
		return
	}
	a.punch_out_enabled = !a.punch_out_enabled
	a.dirty = true
	if a.punch_out_enabled {
		status_buf_set(a, fmt.tprintf("auto punch-out at %s", app_short_pos_text(a, a.end_marker)))
		toast(a, "PUNCH OUT ON")
	} else {
		status_buf_set(a, "auto punch-out off")
		toast(a, "PUNCH OUT OFF")
	}
	bump_revision(a)
}

app_auto_punch_out :: proc(a: ^App) {
	out_pos := a.record_punch_out
	a.audition_end = 0
	a.record_punch_out = 0
	a.transport = .Stopped
	a.frames = max(out_pos, 0)
	a.tape_cued = a.frames > 0
	status_buf_set(a, fmt.tprintf("punched out at %s · STOP returns to the marker", app_position_text(a, a.frames)))
	toast(a, "punched out")
	emit(a, .Record_Stop)
	bump_revision(a)
}

// RTZ and the `0` key: marker first, then 00:00.
app_return_to_marker_or_zero :: proc(a: ^App) -> bool {
	if a.transport == .Recording {
		toast(a, "stop recording to scrub")
		status_buf_set(a, "stop recording to scrub")
		return false
	}
	a.audition_end = 0
	target: i64 = 0
	if a.marker_set && a.frames != a.marker {
		target = a.marker
	}
	a.frames = target
	a.tape_cued = target > 0
	status_buf_set(a, fmt.tprintf("cue %s%s", app_position_text(a, target), " (marker)" if a.marker_set && target == a.marker && target > 0 else ""))
	a.last_command = .Seek_Zero
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
	return true
}

// ---------------------------------------------------------------- record / punch

app_has_guide :: proc(a: ^App) -> bool {
	if a.metronome {
		return true
	}
	for i in 0 ..< a.track_count {
		if a.tracks[i].has_audio || a.take_count[i] > 0 {
			return true
		}
	}
	return false
}

// Starts a take at the playhead. `skip_preroll` records immediately.
app_record_start :: proc(a: ^App, skip_preroll: bool) {
	if a.transport == .Recording {
		return
	}
	armed := false
	for i in 0 ..< a.track_count {
		if a.tracks[i].armed {
			armed = true
		}
	}
	if !armed {
		status_buf_set(a, "arm a track first")
		toast(a, "arm a track first")
		return
	}
	a.audition_end = 0
	punch := max(a.frames, 0)
	if a.tape_frames > 0 {
		punch = min(punch, a.tape_frames)
	}
	pre: i64 = 0
	if !skip_preroll {
		want := app_preroll_frames(a)
		if a.timing_mode == .Grid {
			if want > 0 && (a.metronome || punch == 0 || app_has_guide(a) || !a.preroll_audio) {
				pre = want
			}
		} else if punch > 0 && (app_has_guide(a) || !a.preroll_audio) {
			pre = min(want, punch)
		}
	}
	a.record_punch = punch
	a.record_pre = pre
	a.record_punch_out = a.end_marker if (app_punch_out_active(a) && a.end_marker > punch) else 0
	a.frames = punch - pre
	a.tape_cued = false
	a.transport = .Recording
	pout_suffix := fmt.tprintf(" → %s", app_short_pos_text(a, a.record_punch_out)) if a.record_punch_out > 0 else ""
	switch {
	case pre > 0 && a.timing_mode == .Grid && punch == 0:
		status_buf_set(a, fmt.tprintf("count-in %s · recording from %s%s", app_preroll_label(a), app_position_text(a, punch), pout_suffix))
	case pre > 0 && a.timing_mode == .Grid:
		status_buf_set(a, fmt.tprintf("pre-roll %s · recording from %s%s", app_preroll_label(a), app_position_text(a, punch), pout_suffix))
	case pre > 0:
		status_buf_set(a, fmt.tprintf("pre-roll %.0f s · recording from %s%s", f32(pre) / f32(app_rate(a)), app_position_text(a, punch), pout_suffix))
	case punch > 0:
		status_buf_set(a, fmt.tprintf("punch in at %s%s (undo is paused; takes are kept)", app_position_text(a, punch), pout_suffix))
	case:
		status_buf_set(a, fmt.tprintf("recording%s (undo is paused; takes are kept)", pout_suffix))
	}
	emit(a, .Record_Start)
	bump_revision(a)
}

// ---------------------------------------------------------------- audition

// Plays the lead-in (the pre-roll length, or 1 bar / 2 s min) up to the
// playhead and pauses there: hear the moment you are about to punch into.
app_audition :: proc(a: ^App) {
	if a.transport == .Recording {
		return
	}
	if a.frames <= 0 {
		toast(a, "jog to where you want to punch in first")
		return
	}
	lead_frames: i64
	if a.timing_mode == .Grid {
		lead_frames = app_preroll_frames(a)
		if lead_frames <= 0 {
			lead_frames = i64(math.round(app_bar_frames_f64(a)))
		}
	} else {
		lead := max(app_preroll_seconds(a), AUDITION_MIN_SECONDS)
		lead_frames = i64(lead * f32(app_rate(a)))
	}
	end := a.frames
	start := max(end - lead_frames, 0)
	a.audition_end = end
	a.frames = start
	a.tape_cued = start > 0
	a.transport = .Playing
	status_buf_set(a, fmt.tprintf("audition → %s", app_position_text(a, end)))
	emit(a, .Play)
	bump_revision(a)
}

app_audition_tick :: proc(a: ^App) {
	if a.audition_end <= 0 {
		return
	}
	if a.transport != .Playing {
		a.audition_end = 0
		return
	}
	if a.frames >= a.audition_end {
		a.frames = a.audition_end
		a.audition_end = 0
		a.transport = .Stopped
		a.tape_cued = true
		status_buf_set(a, fmt.tprintf("at %s · r punches in, M marks", app_position_text(a, a.frames)))
		emit(a, .Stop)
		emit(a, .Seek)
		bump_revision(a)
	}
}
