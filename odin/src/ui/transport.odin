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

app_preroll_seconds :: proc(a: ^App) -> f32 {
	return PREROLL_STEPS[clamp(a.preroll_idx, 0, len(PREROLL_STEPS) - 1)]
}

app_preroll_label :: proc(a: ^App) -> string {
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

app_preroll_cycle :: proc(a: ^App) {
	a.preroll_idx = (a.preroll_idx + 1) % len(PREROLL_STEPS)
	a.settings_dirty = true
	msg := fmt.tprintf("pre-roll %s", app_preroll_label(a))
	status_buf_set(a, msg)
	toast(a, msg)
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

// ---------------------------------------------------------------- pause / stop

app_pause :: proc(a: ^App) {
	if a.transport != .Playing {
		return
	}
	a.audition_end = 0
	a.transport = .Stopped
	a.tape_cued = a.frames > 0
	status_buf_set(a, fmt.tprintf("paused %s · Space resumes", timecode(a.frames, a.sample_rate)))
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
		status_buf_set(a, fmt.tprintf("stopped · back at the marker %s", timecode(target, a.sample_rate)))
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
	a.marker = a.frames
	a.marker_set = true
	a.dirty = true
	msg := fmt.tprintf("marker %s · STOP returns here", timecode(a.marker, a.sample_rate))
	status_buf_set(a, msg)
	toast(a, fmt.tprintf("marker %s", timecode(a.marker, a.sample_rate)))
	bump_revision(a)
}

app_marker_clear :: proc(a: ^App) {
	if !a.marker_set {
		return
	}
	a.marker_set = false
	a.marker = 0
	a.dirty = true
	status_buf_set(a, "marker cleared · STOP returns to 00:00")
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
	status_buf_set(a, fmt.tprintf("cue %s (marker)", timecode(a.frames, a.sample_rate)))
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
	status_buf_set(a, fmt.tprintf("cue %s%s", timecode(target, a.sample_rate), " (marker)" if a.marker_set && target == a.marker && target > 0 else ""))
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
	if !skip_preroll && punch > 0 && app_has_guide(a) {
		pre = min(i64(math.round(f64(app_preroll_seconds(a)) * f64(app_rate(a)))), punch)
	}
	a.record_punch = punch
	a.record_pre = pre
	a.frames = punch - pre
	a.tape_cued = false
	a.transport = .Recording
	switch {
	case pre > 0:
		status_buf_set(a, fmt.tprintf("pre-roll %.0f s · recording from %s", f32(pre) / f32(app_rate(a)), timecode(punch, a.sample_rate)))
	case punch > 0:
		status_buf_set(a, fmt.tprintf("punch in at %s (undo is paused; takes are kept)", timecode(punch, a.sample_rate)))
	case:
		status_buf_set(a, "recording (undo is paused; takes are kept)")
	}
	emit(a, .Record_Start)
	bump_revision(a)
}

// ---------------------------------------------------------------- audition

// Plays the lead-in (the pre-roll length, at least 2 s) up to the playhead and
// pauses there: hear the moment you are about to punch into.
app_audition :: proc(a: ^App) {
	if a.transport == .Recording {
		return
	}
	if a.frames <= 0 {
		toast(a, "jog to where you want to punch in first")
		return
	}
	lead := max(app_preroll_seconds(a), AUDITION_MIN_SECONDS)
	end := a.frames
	start := max(end - i64(lead * f32(app_rate(a))), 0)
	a.audition_end = end
	a.frames = start
	a.tape_cued = start > 0
	a.transport = .Playing
	status_buf_set(a, fmt.tprintf("audition → %s", timecode(end, a.sample_rate)))
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
		status_buf_set(a, fmt.tprintf("at %s · r punches in, M marks", timecode(a.frames, a.sample_rate)))
		emit(a, .Stop)
		emit(a, .Seek)
		bump_revision(a)
	}
}
