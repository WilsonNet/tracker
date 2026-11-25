// UI state, layout, input and commands. Deliberately independent of SDL and of
// the audio backend: the same App drives the native window and the headless
// click/screenshot harness.

package ui

import "core:fmt"
import "core:math"
import "core:strings"

// Capacity of the mixer. The session starts with MIN_TRACKS strips (the
// four-track tape-deck default) and grows on demand; `App.track_count` is the
// number of live strips. `MAX_TRACKS` doubles as the master's index for
// `selected` / `fx_channel`, so a master selection never collides with a track.
MAX_TRACKS :: 24
MIN_TRACKS :: 4
MAX_KNOBS :: 24
MAX_TOGGLES :: 16
MAX_DEVICES :: 16
MAX_PALETTE :: 80
MAX_HISTORY :: 64
MAX_RECENT :: 8
RECENT_PATH_MAX :: 192
RECENT_QUERY_MAX :: 40
SAVE_DIR_MAX :: 4096
PROJECT_NAME_MAX :: 64
MAX_CLOUD_PROJECTS :: 32
CLOUD_PROJECT_ID_MAX :: 64
CLOUD_PROJECT_NAME_MAX :: 96
CLOUD_STATUS_MAX :: 192
CLOUD_ERROR_MAX :: 320
CLOUD_CREDENTIAL_MAX :: 256
DESCRIBE_MAX :: 4096
HISTORY_LABEL_MAX :: 40
HISTORY_LEN :: 120

Mode :: enum { Normal, Fx, Palette, Io, Bounce, Recent, Settings, Cloud, Render, Track_Bounce, Track_Delete }

// External render settings. All formats are WAV; the choice is the sample
// encoding. The mix itself always runs through the f32 engine chain.
Render_Format :: enum u8 { Wav_F32, Wav_PCM24, Wav_PCM16 }
Render_Handle :: enum u8 { None, From, To }
Scrub_Wheel :: enum u8 { Shuttle, Jog }
Scrub_Speed :: enum u8 { Normal, Slow, Micro }

RENDER_FORMAT_COUNT :: int(Render_Format.Wav_PCM16) + 1
RENDER_STEP_SECONDS :: f32(0.5)
RENDER_COARSE_STEP_SECONDS :: f32(5.0)

// Keyboard order of the settings rows. Keep view_settings, app_settings_key
// and this enum in the same order.
Settings_Item :: enum u8 {
	New_Project,
	Open_Project,
	Recent_Projects,
	Project_Name,
	Path,
	Browse,
	Apply,
	Default,
	Inputs,
	Backend,
	Latency_Down,
	Latency_Up,
	Monitor,
	Timing_Mode,
	Time_Sig,
	Preroll,
	Preroll_Audio,
	High_Contrast,
	Reduced_Motion,
	Cloud_Folder,
	Cloud_Client_ID,
	Cloud_Client_Secret,
	Cloud_Connect,
	Cloud_Backup,
	Cloud_Restore,
}

SETTINGS_ITEM_COUNT :: int(Settings_Item.Cloud_Restore) + 1

Cloud_Edit :: enum { None, Folder, Client_ID, Client_Secret }

Text_Snapshot :: struct {
	text:   []u8,
	cursor: int,
	anchor: int,
}

Cloud_Project_View :: struct {
	id:       [CLOUD_PROJECT_ID_MAX]u8,
	id_len:   int,
	name:     [CLOUD_PROJECT_NAME_MAX]u8,
	name_len: int,
	modified: i64,
	bytes:    u64,
	files:    int,
}

Cloud_View_Set :: proc(view: ^Cloud_Project_View, id, name: string) {
	buf_set(view.id[:], &view.id_len, id)
	buf_set(view.name[:], &view.name_len, name)
}

cloud_view_id :: proc(view: ^Cloud_Project_View) -> string {
	return string(view.id[:view.id_len])
}

cloud_view_name :: proc(view: ^Cloud_Project_View) -> string {
	return string(view.name[:view.name_len])
}
Transport :: enum { Stopped, Playing, Recording }
Key :: enum { Char, Space, Enter, Escape, Backspace, Delete, Left, Right, Up, Down, Home, End, Tab, F1 }

Fx_Module :: enum u8 { EQ, COMP, SEND, REVERB, DELAY, WIDTH, LIMITER }

Command_Kind :: enum {
	Play,
	Stop,
	Record_Start,
	Record_Stop,
	Bounce,
	Render_Mix,
	Render_File,
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
	Undo,
	Redo,
	New_Project,
	Create_Project,
	Open_Project,
	Save_As,
	Rename_Project,
	Apply_Project_Name,
	Seek,
	Seek_Zero,
	Shuttle_Back,
	Shuttle_Forward,
	Jog_Back,
	Jog_Forward,
	Recent,
	Open_Recent,
	High_Contrast,
	Reduced_Motion,
	Monitor,
	Latency_Up,
	Latency_Down,
	Backend,
	Rescan,
	Take_Next,
	Take_Prev,
	Take_New,    // opt-in: archives active take WAV and opens an empty new take slot
	Take_Delete, // arms inline delete-take confirmation
	Delete_Take, // index = track whose active take should be moved to deleted/
	Comp_Use,
	Comp_Clear,
	Settings,
	Choose_Save_Dir,
	Apply_Save_Dir,
	Reset_Save_Dir,
	Cloud,
	Cloud_Open,
	Cloud_Connect,
	Cloud_Disconnect,
	Cloud_Backup,
	Cloud_Restore,
	Cloud_List,
	Cloud_Save_Credentials,
	Track_Add,
	Track_Remove, // asks to delete the selected track (dialog when it holds audio)
	Delete_Track, // index = track to delete; the engine moves its files aside
	Bounce_Tracks,   // open the bounce-to-track dialog (marks sources)
	Bounce_To_Track, // index = target track; marked tracks are the sources
	Zoom_In,
	Zoom_Out,
	Page_Next,
	Page_Prev,
	Rename_Track,
	Apply_Track_Name,
	Pause,         // stop where you are (position kept)
	Set_Marker,    // drop / move the return marker at the playhead
	Clear_Marker,
	Goto_Marker,
	Audition,         // play the lead-in up to the playhead, then pause there
	Record_Now,       // record at the playhead without pre-roll
	Preroll_Next,     // cycle the pre-roll length
	Preroll_Audio,    // toggle pre-roll audio (song + armed lead-in vs click only)
	Timing_Mode,      // toggle Grid (clicktrack + magnetic scrub) / Free tape (seconds)
	Time_Sig_Next,    // cycle time signature (4/4, 3/4, 6/8, 5/4, 7/8, 2/4)
	Set_End_Marker,   // drop / move the section end marker at the playhead
	Clear_End_Marker,
	Goto_End_Marker,
	Loop_Toggle,      // toggle section loop playback (IN -> OUT)
	Punch_Out_Toggle, // toggle opt-in auto punch-out at OUT marker
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

// Undo snapshots contain mix/edit state only. They deliberately exclude take
// audio (`has_audio`), meters, the running transport and the project path: an
// undo can never delete a recorded take or re-start a render.
Track_Snapshot :: struct {
	input:       int,
	level:       f32,
	pan:         f32,
	armed:       bool,
	muted:       bool,
	soloed:      bool,
	eq:          Eq_View,
	comp:        Comp_View,
	send_reverb: f32,
	send_delay:  f32,
}

Master_Snapshot :: struct {
	comp:    Comp_View,
	reverb:  Reverb_View,
	delay:   Delay_View,
	width:   Width_View,
	limiter: Limiter_View,
}

Snapshot :: struct {
	tracks:       [MAX_TRACKS]Track_Snapshot,
	master:       Master_Snapshot,
	bpm:          int,
	metronome:    bool,
	time_sig_idx: int,
}

History_Entry :: struct {
	state:     Snapshot,
	label_buf: [HISTORY_LABEL_MAX]u8,
	label_len: int,
}

Layout :: struct {
	header:    Rect,
	transport: Rect,
	status:    Rect,
	bottom:    Rect,

	rec:    Rect,
	play:   Rect,
	stop:   Rect,
	bounce: Rect,
	fx:     Rect,
	io:     Rect,
	bpm_minus: Rect,
	bpm_plus:  Rect,
	click:     Rect,
	monitor:   Rect,
	take:      [MAX_TRACKS]Rect,

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
	palette_count: int, // visible rows (window into the full match list)
	palette_visible: int,

	recent_panel: Rect,
	recent_input: Rect,
	recent_row:   [MAX_RECENT]Rect,
	recent_count: int,

	io_panel: Rect,
	io_row:   [MAX_DEVICES]Rect,
	io_count: int,
	jack:     Rect,
	rescan:   Rect,
	lat_minus: Rect,
	lat_plus:  Rect,
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
	track_count:   int,  // live strips, MIN_TRACKS..MAX_TRACKS
	view_want:     int,  // strips the user wants on screen (zoom); see app_view_count
	view_first:    int,  // first visible strip
	marked:        [MAX_TRACKS]bool, // bounce sources (v)
	tb_target:     int,  // bounce destination while the dialog is open
	mode:          Mode,
	help_open:     bool, // F1 cheat sheet; overlays any mode, swallows keys until closed
	transport:     Transport,
	sample_rate:   u32,
	bpm:           int,
	metronome:     bool,
	timing_mode:   Timing_Mode,
	time_sig_idx:  int,
	monitor:       bool,
	latency_ms:    f32,
	jack_backend:  bool,
	take_count:    [MAX_TRACKS]int,
	take_active:   [MAX_TRACKS]int,
	frames:        i64,
	tape_frames:   i64,
	tape_cued:     bool,
	// Single return marker: STOP and the RTZ button go back to it (then to 0).
	marker:            i64,
	marker_set:        bool,
	end_marker:        i64,
	end_marker_set:    bool,
	loop_enabled:      bool,
	punch_out_enabled: bool,
	preroll_idx:       int, // index into PREROLL_STEPS (Free mode)
	preroll_grid_idx:  int, // index into PREROLL_GRID_STEPS (Grid mode)
	preroll_audio:     bool, // true = play song (incl. armed lead-in) during pre-roll
	record_punch:      i64, // frame where the take starts (read by the engine)
	record_pre:        i64, // pre-roll frames before the punch (guide only, not recorded)
	record_punch_out:  i64, // >0 while recording with auto punch-out active
	engine_clock:      bool, // true when live audio engine drives a.frames & auto punch-out
	audition_end:      i64, // >0 while auditioning the lead-in
	time:          f32,
	peak_history:  [MAX_TRACKS][HISTORY_LEN]f32,
	peak_history_pos: int,
	peak_history_acc: f32,

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
	palette_scroll: int,
	palette_items: [MAX_PALETTE]int,
	palette_count: int,

	// Recent projects are supplied by the window layer (zenity/GUI picker).
	// Fixed buffers keep the App free of heap ownership; the list is in-memory
	// session state and is meant to be seeded from a settings file by main.
	recent_projects:    [MAX_RECENT][RECENT_PATH_MAX]u8,
	recent_project_len: [MAX_RECENT]int,
	recent_count:       int,
	recent_query_buf:   [RECENT_QUERY_MAX]u8,
	recent_query_len:   int,
	recent_items:       [MAX_RECENT]int,
	recent_filtered:    int,
	recent_sel:         int,
	recent_target_buf:  [RECENT_PATH_MAX]u8,
	recent_target_len:  int,

	// Accessibility preferences live in App state so the window layer can seed
	// them from a config file. They are not part of undo snapshots.
	high_contrast:  bool,
	reduced_motion: bool,
	state_revision: u64,
	describe_buf:   [DESCRIBE_MAX]u8,
	describe_len:   int,
	last_command:       Command_Kind,
	last_command_index: int,

	// 64-entry linear history. history_pos indexes the current state; entries
	// after it are redo candidates and are discarded by the next commit.
	history:        [MAX_HISTORY]History_Entry,
	history_count:  int,
	history_pos:    int,
	history_pending: bool,
	pending_label_buf: [HISTORY_LABEL_MAX]u8,
	pending_label_len: int,

	devices:      []string,
	device_index: int,
	input_count:  int,
	bounce_progress: f32,
	bounce_active:   bool,
	// Render dialog. `render_duration` is supplied by the engine when the
	// dialog opens; 0 means "end of mix" until then.
	render_from:     f32,
	render_to:       f32,
	render_duration: f32,
	render_format:   Render_Format,
	render_sel:      int,
	render_drag:     Render_Handle,
	render_grab:     f32, // pointer-to-handle offset while dragging
	demo:         bool,
	// True while the arm preview capture is feeding live input levels, so the
	// window keeps redrawing the meters without waiting for an event.
	input_live:   bool,

	// Machine-local settings. `save_dir` is the project folder currently in
	// use; `settings_path` is the editable candidate shown in the overlay.
	// `settings_dirty` asks the window to persist settings.json.
	save_dir:               [SAVE_DIR_MAX]u8,
	save_dir_len:           int,
	settings_path:          [SAVE_DIR_MAX]u8,
	settings_path_len:      int,
	settings_path_edit:     bool,
	project_name_draft:     [PROJECT_NAME_MAX]u8,
	project_name_draft_len: int,
	project_name_edit:      bool,
	new_project_open:       bool,
	new_project_edit:       bool,
	new_project_draft:      [PROJECT_NAME_MAX]u8,
	new_project_draft_len:  int,
	// Inline rename of one track strip (R / double-click the name).
	td_index:       int,  // track the delete dialog is about
	td_confirm:     bool, // dialog focus: false = KEEP, true = DELETE
	take_del_track: int,  // track with inline take-delete confirmation armed (-1 = none)
	track_edit:            bool,
	track_edit_index:      int,
	track_name_draft:      [64]u8,
	track_name_draft_len:  int,
	settings_sel:           Settings_Item,
	settings_dirty:         bool,

	// Cloud display state. The worker in cloud_jobs.odin owns tokens and
	// network I/O; these fields are copied on the UI thread.
	cloud_connected:    bool,
	cloud_busy:         bool,
	cloud_status:       [CLOUD_STATUS_MAX]u8,
	cloud_status_len:   int,
	cloud_error:        [CLOUD_ERROR_MAX]u8,
	cloud_error_len:    int,
	cloud_progress_done:  int,
	cloud_progress_total: int,
	cloud_last_sync:      i64,
	cloud_folder:        [CLOUD_PROJECT_NAME_MAX]u8,
	cloud_folder_len:    int,
	cloud_client_id:      [CLOUD_CREDENTIAL_MAX]u8,
	cloud_client_id_len:  int,
	cloud_client_secret:     [CLOUD_CREDENTIAL_MAX]u8,
	cloud_client_secret_len: int,
	cloud_edit:           Cloud_Edit,
	edit_confirm:         bool,
	edit_select_all:      bool,
	cloud_dirty:          bool,
	// Caret/anchor for the active settings text field. Byte offsets into the
	// active fixed buffer; anchor == cursor means no selection.
	text_cursor:          int,
	text_anchor:          int,
	text_undo:            [32]Text_Snapshot,
	text_undo_count:      int,
	text_redo:            [32]Text_Snapshot,
	text_redo_count:      int,
	// Typed run coalescing: one undo step per run of typed characters.
	text_typing:          bool,
	text_scroll_x:        f32,
	text_dragging:        bool,
	text_drag_multi:      bool,
	text_drag_field:      int,
	cloud_projects:       [MAX_CLOUD_PROJECTS]Cloud_Project_View,
	cloud_project_count:  int,
	cloud_selected:       int,

	mouse_x, mouse_y: f32,
	mouse_down:   bool,
	drag:         Drag,
	hover_id:     string,

	// Keyboard focus inside the FX rack: -1 = none, otherwise an index into
	// the current knob list followed by the toggle list. All indices are
	// relative to layout.knob / layout.toggle so Tab reaches every control
	// without a mouse.
	fx_focus: int,

	// Modifier state for fine dragging & slow tape scrubbing.
	shift_down: bool,
	ctrl_down:  bool,
	alt_down:   bool,

	// Double-click detection (SDL2 has no native event; two mouse-downs in the
	// same spot within this window are treated as one).
	click_pending: bool,
	click_time:    f32,
	click_x:       f32,
	click_y:       f32,

	layout:   Layout,
	commands: [dynamic]Command,
	cmd_read: int,
	frame_no: u64,
}

TRACK_NAMES := [MAX_TRACKS]string{
	"Track 1", "Track 2", "Track 3", "Track 4", "Track 5", "Track 6",
	"Track 7", "Track 8", "Track 9", "Track 10", "Track 11", "Track 12",
	"Track 13", "Track 14", "Track 15", "Track 16", "Track 17", "Track 18",
	"Track 19", "Track 20", "Track 21", "Track 22", "Track 23", "Track 24",
}

app_init :: proc(a: ^App, width, height: int) {
	a^ = App{}
	a.width = width
	a.height = height
	a.sample_rate = 48_000
	a.bpm = 120
	a.timing_mode = .Grid
	a.time_sig_idx = TIME_SIG_DEFAULT_IDX
	a.selected = 0
	a.mode = .Normal
	a.transport = .Stopped
	a.fx_channel = 0
	a.device_index = 0
	a.input_count = MIN_TRACKS
	a.track_count = MIN_TRACKS
	a.preroll_idx = PREROLL_DEFAULT_IDX
	a.preroll_grid_idx = PREROLL_GRID_DEFAULT_IDX
	a.preroll_audio = true
	a.view_want = MIN_TRACKS
	a.fx_focus = -1
	a.take_del_track = -1
	status_buf_set(a, "ready")
	project_buf_set(a, "untitled")
	project_name_draft_set(a, "untitled")
	device_buf_set(a, "no input")
	save_dir_set(a, "")
	settings_path_set(a, "")
	a.recent_sel = 0
	a.history_count = 0
	for i in 0 ..< MAX_TRACKS {
		t := &a.tracks[i]
		t.name = TRACK_NAMES[i]
		t.input = i + 1
		t.level = 0.8
		t.pan = 0
		t.peak_db = -60
		t.rms_db = -60
		t.gr_db = 0
		for h in 0 ..< HISTORY_LEN {
			a.peak_history[i][h] = -60
		}
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
	app_master_reset(a)
	app_resize(a, width, height)
	app_history_reset(a)
}

@(private)
app_master_reset :: proc(a: ^App) {
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
}

// Resets all per-project state (tracks, takes, master FX, tempo, time sig,
// marker, undo history) to a clean 4-track slate while keeping machine/studio
// preferences (audio device, latency, timing mode, pre-roll, a11y, cloud, recents).
app_reset_project :: proc(a: ^App, name: string) {
	for i in 0 ..< MAX_TRACKS {
		app_track_reset(a, i)
	}
	a.track_count = MIN_TRACKS
	a.view_want = MIN_TRACKS
	a.view_first = 0
	a.selected = 0
	a.fx_channel = 0
	a.fx_focus = -1
	app_master_reset(a)

	a.sample_rate = 48_000
	a.bpm = 120
	a.time_sig_idx = TIME_SIG_DEFAULT_IDX
	a.metronome = false
	a.frames = 0
	a.tape_frames = 0
	a.tape_cued = false
	a.marker = 0
	a.marker_set = false
	a.end_marker = 0
	a.end_marker_set = false
	a.loop_enabled = false
	a.punch_out_enabled = false
	a.audition_end = 0
	a.record_punch = 0
	a.record_pre = 0
	a.record_punch_out = 0
	a.take_del_track = -1
	a.track_edit = false
	a.project_name_edit = false
	a.settings_path_edit = false
	a.cloud_edit = .None
	a.new_project_open = false
	a.new_project_edit = false
	a.new_project_draft_len = 0
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	a.mode = .Normal
	a.dirty = false

	final_name := strings.trim_space(name)
	if final_name == "" {
		final_name = "untitled"
	}
	project_buf_set(a, final_name)
	project_name_draft_set(a, final_name)
	text_history_reset(a)
	app_history_reset(a)
	app_layout(a)
	bump_revision(a)
}

app_destroy :: proc(a: ^App) {
	for i in 0 ..< a.text_undo_count {
		delete(a.text_undo[i].text)
	}
	for i in 0 ..< a.text_redo_count {
		delete(a.text_redo[i].text)
	}

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

// ---------------------------------------------------------------- undo / redo

@(private)
bump_revision :: proc(a: ^App) {
	a.state_revision += 1
}

@(private)
app_touch :: proc(a: ^App) {
	a.dirty = true
	bump_revision(a)
}

app_snapshot :: proc(a: ^App) -> Snapshot {
	s: Snapshot
	for i in 0 ..< MAX_TRACKS {
		t := a.tracks[i]
		s.tracks[i] = Track_Snapshot {
			input = t.input,
			level = t.level,
			pan = t.pan,
			armed = t.armed,
			muted = t.muted,
			soloed = t.soloed,
			eq = t.eq,
			comp = t.comp,
			send_reverb = t.send_reverb,
			send_delay = t.send_delay,
		}
	}
	s.master = Master_Snapshot {
		comp = a.master.comp,
		reverb = a.master.reverb,
		delay = a.master.delay,
		width = a.master.width,
		limiter = a.master.limiter,
	}
	s.bpm = a.bpm
	s.metronome = a.metronome
	s.time_sig_idx = a.time_sig_idx
	return s
}

app_apply_snapshot :: proc(a: ^App, s: Snapshot) {
	for i in 0 ..< MAX_TRACKS {
		t := &a.tracks[i]
		ts := s.tracks[i]
		t.input = ts.input
		t.level = ts.level
		t.pan = ts.pan
		t.armed = ts.armed
		t.muted = ts.muted
		t.soloed = ts.soloed
		t.eq = ts.eq
		t.comp = ts.comp
		t.send_reverb = ts.send_reverb
		t.send_delay = ts.send_delay
	}
	a.master.comp = s.master.comp
	a.master.reverb = s.master.reverb
	a.master.delay = s.master.delay
	a.master.width = s.master.width
	a.master.limiter = s.master.limiter
	a.bpm = s.bpm
	a.metronome = s.metronome
	a.time_sig_idx = clamp(s.time_sig_idx, 0, len(TIME_SIGS) - 1)
	a.dirty = true
	bump_revision(a)
}

@(private)
history_entry_label :: proc(e: ^History_Entry) -> string {
	return string(e.label_buf[:e.label_len])
}

// Mark the current gesture as undoable. The label is the human name shown in
// status/toasts ("fader", "arm", "knob"). Commits happen on mouse-up, at the
// end of a key action, and after palette execution.
app_history_note :: proc(a: ^App, label: string) {
	if a.history_pending && string(a.pending_label_buf[:a.pending_label_len]) == label {
		return
	}
	buf_set(a.pending_label_buf[:], &a.pending_label_len, label)
	a.history_pending = true
}

@(private)
history_store :: proc(a: ^App, label: string) {
	// Compare structurally: a click that did not change anything must not
	// consume a history slot or truncate the redo branch.
	snap := app_snapshot(a)
	if a.history_count > 0 && a.history[a.history_pos].state == snap {
		a.history_pending = false
		return
	}
	pos := a.history_pos + 1
	if pos >= MAX_HISTORY {
		// Drop the oldest entry to keep the newest 64 gestures.
		for i in 1 ..< MAX_HISTORY {
			a.history[i - 1] = a.history[i]
		}
		pos = MAX_HISTORY - 1
		a.history_count = MAX_HISTORY - 1
	}
	a.history_pos = pos
	a.history[pos].state = snap
	buf_set(a.history[pos].label_buf[:], &a.history[pos].label_len, label)
	a.history_count = pos + 1
	a.history_pending = false
}

app_history_commit :: proc(a: ^App) {
	if !a.history_pending {
		return
	}
	label := string(a.pending_label_buf[:a.pending_label_len])
	if label == "" {
		label = "edit"
	}
	history_store(a, label)
}

// Reset history after a project load/replace: old snapshots belong to another
// document. main/window can call this after project_load.
app_history_reset :: proc(a: ^App) {
	a.history = {}
	a.history_count = 1
	a.history_pos = 0
	a.history[0].state = app_snapshot(a)
	buf_set(a.history[0].label_buf[:], &a.history[0].label_len, "open")
	a.history_pending = false
	a.pending_label_len = 0
}

app_can_undo :: proc(a: ^App) -> bool {
	return a.history_pos > 0
}

app_can_redo :: proc(a: ^App) -> bool {
	return a.history_pos + 1 < a.history_count
}

app_undo :: proc(a: ^App) {
	if a.transport == .Recording {
		status_buf_set(a, "recording - stop before undo")
		toast(a, "stop recording before undo")
		return
	}
	if !app_can_undo(a) {
		status_buf_set(a, "nothing to undo")
		toast(a, "nothing to undo")
		return
	}
	label := history_entry_label(&a.history[a.history_pos])
	a.history_pending = false
	a.history_pos -= 1
	app_apply_snapshot(a, a.history[a.history_pos].state)
	status_buf_set(a, fmt.tprintf("undid %s (takes kept)", label))
	toast(a, fmt.tprintf("undo %s", label))
}

app_redo :: proc(a: ^App) {
	if a.transport == .Recording {
		status_buf_set(a, "recording - stop before redo")
		toast(a, "stop recording before redo")
		return
	}
	if !app_can_redo(a) {
		status_buf_set(a, "nothing to redo")
		toast(a, "nothing to redo")
		return
	}
	a.history_pending = false
	a.history_pos += 1
	app_apply_snapshot(a, a.history[a.history_pos].state)
	status_buf_set(a, fmt.tprintf("redid %s", history_entry_label(&a.history[a.history_pos])))
	toast(a, "redo")
}

// ---------------------------------------------------------------- recent projects

app_recent_path :: proc(a: ^App, i: int) -> string {
	if i < 0 || i >= a.recent_count {
		return ""
	}
	return string(a.recent_projects[i][:a.recent_project_len[i]])
}

app_recent_target :: proc(a: ^App) -> string {
	return string(a.recent_target_buf[:a.recent_target_len])
}

@(private)
recent_set :: proc(a: ^App, i: int, path: string) {
	buf_set(a.recent_projects[i][:], &a.recent_project_len[i], path)
}

app_add_recent :: proc(a: ^App, path: string) {
	if path == "" {
		return
	}
	// Move an existing entry to the front instead of duplicating it.
	for i in 0 ..< a.recent_count {
		if app_recent_path(a, i) == path {
			for j := i; j > 0; j -= 1 {
				a.recent_projects[j] = a.recent_projects[j - 1]
				a.recent_project_len[j] = a.recent_project_len[j - 1]
			}
			recent_set(a, 0, path)
			a.recent_filtered = 0
			return
		}
	}
	n := min(a.recent_count + 1, MAX_RECENT)
	for i := n - 1; i > 0; i -= 1 {
		a.recent_projects[i] = a.recent_projects[i - 1]
		a.recent_project_len[i] = a.recent_project_len[i - 1]
	}
	a.recent_count = n
	recent_set(a, 0, path)
	bump_revision(a)
}

app_set_recent :: proc(a: ^App, paths: []string) {
	a.recent_count = 0
	for path, i in paths {
		if i >= MAX_RECENT {
			break
		}
		recent_set(a, a.recent_count, path)
		a.recent_count += 1
	}
	bump_revision(a)
}

@(private)
contains_ci :: proc(haystack, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for start in 0 ..= len(haystack) - len(needle) {
		ok := true
		for i in 0 ..< len(needle) {
			h := haystack[start + i]
			n := needle[i]
			if h >= 'A' && h <= 'Z' {
				h += 32
			}
			if n >= 'A' && n <= 'Z' {
				n += 32
			}
			if h != n {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

app_recent_rebuild :: proc(a: ^App) {
	a.recent_filtered = 0
	query := string(a.recent_query_buf[:a.recent_query_len])
	for i in 0 ..< a.recent_count {
		if contains_ci(app_recent_path(a, i), query) {
			if a.recent_filtered < MAX_RECENT {
				a.recent_items[a.recent_filtered] = i
				a.recent_filtered += 1
			}
		}
	}
	a.recent_sel = clamp(a.recent_sel, 0, max(a.recent_filtered - 1, 0))
	app_layout(a)
}

app_recent_open :: proc(a: ^App) {
	a.mode = .Recent
	a.recent_query_len = 0
	a.recent_sel = 0
	app_recent_rebuild(a)
	status_buf_set(a, "recent projects")
	bump_revision(a)
}

app_recent_choose :: proc(a: ^App) {
	if a.recent_filtered == 0 {
		status_buf_set(a, "no recent projects")
		toast(a, "no recent projects")
		return
	}
	sel := clamp(a.recent_sel, 0, a.recent_filtered - 1)
	idx := a.recent_items[sel]
	path := app_recent_path(a, idx)
	buf_set(a.recent_target_buf[:], &a.recent_target_len, path)
	a.last_command = .Open_Recent
	a.last_command_index = idx
	emit(a, .Open_Recent, idx)
	a.mode = .Normal
	status_buf_set(a, fmt.tprintf("open %s", path))
	bump_revision(a)
}

// ---------------------------------------------------------------- settings

app_save_dir :: proc(a: ^App) -> string {
	return string(a.save_dir[:a.save_dir_len])
}

app_settings_path :: proc(a: ^App) -> string {
	return string(a.settings_path[:a.settings_path_len])
}

app_project_draft :: proc(a: ^App) -> string {
	return string(a.project_name_draft[:a.project_name_draft_len])
}

@(private)
save_dir_set :: proc(a: ^App, s: string) {
	buf_set(a.save_dir[:], &a.save_dir_len, s)
}

@(private)
settings_path_set :: proc(a: ^App, s: string) {
	buf_set(a.settings_path[:], &a.settings_path_len, s)
}

@(private)
project_name_draft_set :: proc(a: ^App, s: string) {
	buf_set(a.project_name_draft[:], &a.project_name_draft_len, s)
}

@(private)
project_edit_clear :: proc(a: ^App) {
	track_edit_clear(a)
	if !a.project_name_edit {
		return
	}
	a.project_name_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	project_name_draft_set(a, app_project(a))
}

app_set_save_dir :: proc(a: ^App, s: string) {
	save_dir_set(a, s)
	bump_revision(a)
}

app_set_settings_path :: proc(a: ^App, s: string) {
	settings_path_set(a, s)
	bump_revision(a)
}

app_mark_settings_dirty :: proc(a: ^App) {
	a.settings_dirty = true
}

app_project_begin_edit :: proc(a: ^App, select_all: bool = true) {
	a.project_name_edit = true
	a.new_project_edit = false
	a.settings_path_edit = false
	a.cloud_edit = .None
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_scroll_x = 0
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	if a.mode != .Settings || app_project_draft(a) == "" {
		project_name_draft_set(a, app_project(a))
	}
	a.text_cursor = a.project_name_draft_len
	a.text_anchor = a.text_cursor
	if select_all && a.project_name_draft_len > 0 {
		text_select_all(a)
	}
	bump_revision(a)
}

app_project_cancel_edit :: proc(a: ^App) {
	a.project_name_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	project_name_draft_set(a, app_project(a))
	if a.mode == .Normal {
		status_buf_set(a, "rename cancelled")
	}
	bump_revision(a)
}

app_project_commit_edit :: proc(a: ^App) -> bool {
	trimmed := strings.trim_space(app_project_draft(a))
	if trimmed == "" {
		toast(a, "project name cannot be empty")
		status_buf_set(a, "project name cannot be empty")
		bump_revision(a)
		return false
	}
	project_buf_set(a, trimmed)
	project_name_draft_set(a, app_project(a))
	a.project_name_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	a.dirty = true
	status_buf_set(a, fmt.tprintf("project named %s", app_project(a)))
	toast(a, fmt.tprintf("project: %s", app_project(a)))
	bump_revision(a)
	return true
}

app_settings_open :: proc(a: ^App) {
	a.mode = .Settings
	a.project_name_edit = false
	a.settings_path_edit = false
	a.cloud_edit = .None
	a.new_project_open = false
	a.new_project_edit = false
	a.new_project_draft_len = 0
	a.edit_confirm = false
	a.settings_sel = .New_Project
	project_name_draft_set(a, app_project(a))
	settings_path_set(a, app_save_dir(a))
	status_buf_set(a, "settings")
	bump_revision(a)
}

app_settings_close :: proc(a: ^App) {
	dirty := a.project_name_edit || a.settings_path_edit || a.cloud_edit != .None || a.cloud_dirty ||
		app_project_draft(a) != app_project(a) || app_settings_path(a) != app_save_dir(a)
	if dirty && !a.edit_confirm {
		a.edit_confirm = true
		if a.project_name_edit || a.settings_path_edit || a.cloud_edit != .None {
			status_buf_set(a, "discard changes? enter apply · esc or close again")
		} else {
			status_buf_set(a, "unsaved changes · esc or close again")
		}
		bump_revision(a)
		return
	}
	a.project_name_edit = false
	a.settings_path_edit = false
	a.cloud_edit = .None
	a.new_project_open = false
	a.new_project_edit = false
	a.new_project_draft_len = 0
	a.edit_confirm = false
	a.edit_select_all = false
	a.cloud_dirty = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	project_name_draft_set(a, app_project(a))
	settings_path_set(a, app_save_dir(a))
	a.mode = .Normal
	status_buf_set(a, "settings closed")
	bump_revision(a)
}

app_settings_begin_edit :: proc(a: ^App) {
	a.settings_path_edit = true
	a.new_project_edit = false
	a.project_name_edit = false
	a.cloud_edit = .None
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_cursor = a.settings_path_len
	a.text_anchor = a.text_cursor
	a.text_scroll_x = 0
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	// Keep a candidate left over from a failed apply so the user can fix it;
	// only seed an empty field from the applied folder.
	if app_settings_path(a) == "" {
		settings_path_set(a, app_save_dir(a))
	}
	bump_revision(a)
}

app_settings_cancel_edit :: proc(a: ^App) {
	a.settings_path_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	settings_path_set(a, app_save_dir(a))
	bump_revision(a)
}

// ---------------------------------------------------------------- cloud

cloud_mask_secret :: proc(secret: string) -> string {
	if secret == "" {
		return ""
	}
	n := min(len(secret), 32)
	stars, _ := strings.repeat("*", n, context.temp_allocator)
	if len(secret) > 32 {
		return fmt.tprintf("%s…", stars)
	}
	return stars
}

app_cloud_status :: proc(a: ^App) -> string { return string(a.cloud_status[:a.cloud_status_len]) }
app_cloud_error :: proc(a: ^App) -> string { return string(a.cloud_error[:a.cloud_error_len]) }
app_cloud_folder :: proc(a: ^App) -> string { return string(a.cloud_folder[:a.cloud_folder_len]) }
app_cloud_client_id :: proc(a: ^App) -> string { return string(a.cloud_client_id[:a.cloud_client_id_len]) }
app_cloud_client_secret :: proc(a: ^App) -> string { return string(a.cloud_client_secret[:a.cloud_client_secret_len]) }

app_cloud_status_set :: proc(a: ^App, status, err: string) {
	changed := app_cloud_status(a) != status || app_cloud_error(a) != err
	buf_set(a.cloud_status[:], &a.cloud_status_len, status)
	buf_set(a.cloud_error[:], &a.cloud_error_len, err)
	if changed {
		bump_revision(a)
	}
}

app_set_cloud_status :: proc(a: ^App, status, err: string, connected: bool) {
	if a.cloud_connected != connected {
		a.cloud_connected = connected
		bump_revision(a)
	}
	app_cloud_status_set(a, status, err)
}

app_set_cloud_credentials :: proc(a: ^App, id, secret, folder: string) {
	buf_set(a.cloud_client_id[:], &a.cloud_client_id_len, id)
	buf_set(a.cloud_client_secret[:], &a.cloud_client_secret_len, secret)
	buf_set(a.cloud_folder[:], &a.cloud_folder_len, folder)
}

app_cloud_connected :: proc(a: ^App, last_sync: i64) {
	a.cloud_connected = true
	a.cloud_last_sync = last_sync
	app_cloud_status_set(a, "Google Drive connected", "")
	status_buf_set(a, "Google Drive connected")
	toast(a, "Google Drive connected")
	bump_revision(a)
}

app_cloud_disconnected :: proc(a: ^App) {
	a.cloud_connected = false
	a.cloud_project_count = 0
	a.cloud_last_sync = 0
	app_cloud_status_set(a, "Google Drive disconnected", "")
	status_buf_set(a, "Google Drive disconnected")
	toast(a, "Google Drive disconnected")
	bump_revision(a)
}

app_cloud_backed_up :: proc(a: ^App, last_sync: i64) {
	a.cloud_last_sync = last_sync
	status_buf_set(a, "project backed up to Google Drive")
	toast(a, "backup complete")
	bump_revision(a)
}

app_cloud_restored :: proc(a: ^App) {
	a.mode = .Normal
	status_buf_set(a, "project restored from Google Drive")
	toast(a, "project restored")
	bump_revision(a)
}

app_cloud_failed :: proc(a: ^App, msg: string) {
	app_cloud_status_set(a, msg, msg)
	status_buf_set(a, msg)
	toast(a, msg)
	bump_revision(a)
}

app_set_cloud_projects :: proc(a: ^App, views: []Cloud_Project_View) {
	a.cloud_project_count = min(len(views), MAX_CLOUD_PROJECTS)
	for i in 0 ..< a.cloud_project_count {
		a.cloud_projects[i] = views[i]
	}
	a.cloud_selected = clamp(a.cloud_selected, 0, max(a.cloud_project_count - 1, 0))
	bump_revision(a)
}

app_cloud_selected_id :: proc(a: ^App) -> string {
	if a.cloud_selected < 0 || a.cloud_selected >= a.cloud_project_count {
		return ""
	}
	return cloud_view_id(&a.cloud_projects[a.cloud_selected])
}

app_new_project_draft :: proc(a: ^App) -> string {
	return string(a.new_project_draft[:a.new_project_draft_len])
}

app_new_project_preview_dir :: proc(a: ^App) -> string {
	trimmed := strings.trim_space(app_new_project_draft(a))
	b := strings.builder_make(context.temp_allocator)
	last_dash := false
	for raw in transmute([]u8)trimmed {
		c := raw
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if ok {
			strings.write_byte(&b, c)
			last_dash = false
		} else if !last_dash {
			strings.write_byte(&b, '-')
			last_dash = true
		}
		if strings.builder_len(b) >= 48 {
			break
		}
	}
	slug := strings.trim(strings.to_string(b), "-.")
	if slug == "" {
		slug = "untitled"
	}
	dir := app_save_dir(a)
	parent := "."
	if idx := strings.last_index_byte(dir, '/'); idx >= 0 {
		parent = "/" if idx == 0 else dir[:idx]
	}
	if parent == "/" {
		return fmt.tprintf("/%s", slug)
	}
	return fmt.tprintf("%s/%s", parent, slug)
}

app_new_project_begin :: proc(a: ^App) -> bool {
	if a.transport != .Stopped {
		toast(a, "stop transport before creating a new project")
		status_buf_set(a, "stop transport before creating a new project")
		return false
	}
	if a.mode != .Settings {
		app_settings_open(a)
	}
	a.settings_sel = .New_Project
	a.new_project_open = true
	a.new_project_edit = true
	a.project_name_edit = false
	a.settings_path_edit = false
	a.cloud_edit = .None
	a.edit_confirm = false
	a.edit_select_all = false
	a.new_project_draft_len = 0
	a.text_cursor = 0
	a.text_anchor = 0
	a.text_scroll_x = 0
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	status_buf_set(a, "new clean project · enter create · esc cancel")
	bump_revision(a)
	return true
}

app_new_project_cancel :: proc(a: ^App) {
	a.new_project_open = false
	a.new_project_edit = false
	a.new_project_draft_len = 0
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	status_buf_set(a, "new project cancelled")
	bump_revision(a)
}

app_new_project_commit :: proc(a: ^App) {
	if a.transport != .Stopped {
		toast(a, "stop transport before creating a new project")
		status_buf_set(a, "stop transport before creating a new project")
		return
	}
	a.last_command = .Create_Project
	a.last_command_index = 0
	emit(a, .Create_Project)
	bump_revision(a)
}

app_cloud_begin_edit :: proc(a: ^App, field: Cloud_Edit) {
	a.cloud_edit = field
	a.new_project_edit = false
	a.project_name_edit = false
	a.settings_path_edit = false
	a.edit_confirm = false
	a.edit_select_all = false
	a.text_cursor = text_field_length(a)
	a.text_anchor = a.text_cursor
	a.text_scroll_x = 0
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	bump_revision(a)
}

app_cloud_cancel_edit :: proc(a: ^App) {
	a.cloud_edit = .None
	a.edit_confirm = false
	a.edit_select_all = false
	a.cloud_dirty = false
	a.text_typing = false
	a.text_dragging = false
	a.text_drag_multi = false
	text_history_reset(a)
	bump_revision(a)
}

app_cloud_mark_saved :: proc(a: ^App) {
	a.cloud_dirty = false
	bump_revision(a)
}

app_select_all_text :: proc(a: ^App) {
	if _, _, ok := text_active(a); !ok {
		return
	}
	text_select_all(a)
	a.text_scroll_x = 0
	bump_revision(a)
}

// Selected text for Ctrl+C/Ctrl+X. The window writes the returned string to
// the desktop clipboard; cuts update the model through text_clipboard.
app_copy_text :: proc(a: ^App, cut: bool) -> string {
	text, ok := text_clipboard(a, cut)
	if !ok {
		return ""
	}
	if cut {
		a.edit_confirm = false
		bump_revision(a)
	}
	return text
}


// ---------------------------------------------------------------- accessibility

app_tokens :: proc(a: ^App) -> Tokens {
	return theme_tokens(a.high_contrast)
}

@(private)
describe_append :: proc(out: []u8, n: ^int, format: string, args: ..any) {
	if n^ >= len(out) || n^ < 0 {
		return
	}
	s := fmt.bprintf(out[n^:], format, ..args)
	n^ += len(s)
}

app_describe :: proc(a: ^App) -> string {
	out: [DESCRIBE_MAX]u8
	n := 0
	mode_name := "Normal"
	switch a.mode {
	case .Normal:
		mode_name = "Normal"
	case .Fx:
		mode_name = "Fx rack"
	case .Palette:
		mode_name = "Command palette"
	case .Io:
		mode_name = "Input devices"
	case .Bounce:
		mode_name = "Bounce"
	case .Recent:
		mode_name = "Recent projects"
	case .Settings:
		mode_name = "Settings"
	case .Cloud:
		mode_name = "Cloud projects"
	case .Render:
		mode_name = "Render mix"
	case .Track_Bounce:
		mode_name = "Bounce to track"
	case .Track_Delete:
		mode_name = "Delete track"
	}
	transport := "stopped"
	switch a.transport {
	case .Stopped:
		transport = "stopped"
	case .Playing:
		transport = "playing"
	case .Recording:
		transport = "recording"
	}
	describe_append(out[:], &n, "mode %s. transport %s. ", mode_name, transport)
	if a.selected >= MAX_TRACKS {
		describe_append(out[:], &n, "selected master. ")
	} else {
		describe_append(out[:], &n, "selected track %d. ", a.selected + 1)
	}
	describe_append(out[:], &n, "tempo %d bpm. time signature %s. timing %s. metronome %s. pre-roll audio %s. monitor %s. latency %.0f ms. capture %s. high contrast %s. reduced motion %s. project folder %s. ",
		a.bpm, app_time_sig(a).label, "free" if a.timing_mode == .Free else "grid", "on" if a.metronome else "off",
		"song" if a.preroll_audio else "click",
		"on" if a.monitor else "off", a.latency_ms,
		"Jack" if a.jack_backend else platform_audio_backend_name(),
		"on" if a.high_contrast else "off",
		"on" if a.reduced_motion else "off", app_save_dir(a))
	if a.end_marker_set {
		describe_append(out[:], &n, "section %s to %s, loop %s, punch out %s. ",
			app_short_pos_text(a, app_range_start(a)),
			app_short_pos_text(a, a.end_marker),
			"on" if app_loop_active(a) else "off",
			"on" if app_punch_out_active(a) else "off")
	}
	describe_append(out[:], &n, "google drive %s. cloud projects %d. ", "connected" if a.cloud_connected else "disconnected", a.cloud_project_count)
	for i in 0 ..< a.track_count {
		t := a.tracks[i]
		describe_append(out[:], &n, "track %d %s: %s, mute %s, solo %s, %d take(s), level %d percent, pan %s, peak %.1f dB. ",
			i + 1, t.name,
			"armed" if t.armed else "disarmed",
			"on" if t.muted else "off",
			"on" if t.soloed else "off",
			a.take_count[i],
			int(t.level / 1.5 * 100.0 + 0.5),
			"center" if abs(t.pan) < 0.02 else fmt.tprintf("%s%.0f", "left " if t.pan < 0 else "right ", abs(t.pan) * 100),
			t.peak_db)
	}
	describe_append(out[:], &n, "undo %d of %d. redo %d. status %s.",
		a.history_pos, a.history_count - 1,
		a.history_count - 1 - a.history_pos, app_status(a))
	buf_set(a.describe_buf[:], &a.describe_len, string(out[:min(n, DESCRIBE_MAX)]))
	return string(a.describe_buf[:a.describe_len])
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
	} else {
		device_buf_set(a, "no input")
	}
	app_layout(a)
}

app_set_device :: proc(a: ^App, name: string) {
	device_buf_set(a, name)
}

// Number of input channels the capture device exposes. Track input selectors
// cycle 1..input_count; the default is one channel per track.
app_set_input_channels :: proc(a: ^App, count: int) {
	a.input_count = clamp(count, 1, 32)
	for i in 0 ..< MAX_TRACKS {
		a.tracks[i].input = clamp(a.tracks[i].input, 1, a.input_count)
	}
}

app_set_project :: proc(a: ^App, name: string) {
	project_buf_set(a, name)
	if !a.project_name_edit {
		project_name_draft_set(a, app_project(a))
	}
	bump_revision(a)
}

app_set_takes :: proc(a: ^App, track, count, active: int) {
	if track < 0 || track >= MAX_TRACKS {
		return
	}
	a.take_count[track] = max(count, 0)
	a.take_active[track] = max(active, 0)
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
	// Knob centres: up to 3 per row. Compact rack geometry.
	radius: f32 = 17
	cols := 3
	cell_w := panel.w / f32(cols)
	for i in 0 ..< count {
		row := i / cols
		col := i % cols
		cx := panel.x + cell_w * (f32(col) + 0.5)
		cy := start_y + f32(row) * 64 + radius + 4
		add_knob(l, Rect{cx - radius - 7, cy - radius - 6, radius * 2 + 14, radius * 2 + 12}, m, i)
	}
}

app_layout :: proc(a: ^App) {
	l := &a.layout
	l^ = Layout{}
	w := f32(a.width)
	h := f32(a.height)
	m := METRICS
	sp := SPACE

	// ── bars ───────────────────────────────────────────────────────────
	l.header = Rect{0, 0, w, m.header_h}
	l.transport = l.header
	l.status = Rect{0, h - m.status_h, w, m.status_h}
	l.bottom = Rect{0, h - m.status_h - m.bottom_h, w, m.bottom_h}

	// ── top bar: mode / transport / timecode / tempo / utilities ───────
	l.rec = Rect{104, 12, 64, 32}
	l.play = Rect{176, 12, 68, 32}
	l.stop = Rect{252, 12, 64, 32}

	util_y := f32(13)
	util_h: f32 = 30
	right := w - m.margin
	l.click = Rect{right - 60, util_y, 60, util_h}
	l.monitor = Rect{l.click.x - 54, util_y, 54, util_h}
	l.io = Rect{l.monitor.x - 44, util_y, 44, util_h}
	l.fx = Rect{l.io.x - 44, util_y, 44, util_h}
	l.bounce = Rect{l.fx.x - 76, util_y, 76, util_h}
	l.bpm_plus = Rect{l.bounce.x - 8 - 24, util_y, 24, util_h}
	l.bpm_minus = Rect{l.bpm_plus.x - 82, util_y, 24, util_h}

	// ── rack reflows the workspace instead of covering it ───────────────
	fx_open := a.mode == .Fx
	fx_h: f32 = min(m.fx_h, h - 190)
	l.fx_panel = Rect{m.margin, l.bottom.y - fx_h - sp.xs, w - m.margin * 2, fx_h}
	area_y := m.header_h + sp.lg
	area_bottom := l.bottom.y - sp.lg
	if fx_open {
		area_bottom = l.fx_panel.y - sp.lg
	}
	area_h := max(area_bottom - area_y, 150)
	compact_tracks := fx_open && area_h < 260

	// ── channel strips ─────────────────────────────────────────────────
	app_view_clamp(a)
	view_n := app_view_count(a)
	track_w := (w - m.margin * 2 - m.gutter * f32(view_n)) / f32(view_n)
	for i in a.view_first ..< a.view_first + view_n {
		x := m.margin + f32(i - a.view_first) * (track_w + m.gutter)
		r := Rect{x, area_y, track_w, area_h}
		l.track[i] = r
		inner_x := r.x + m.track_pad
		inner_w := r.w - m.track_pad * 2

		l.input[i] = Rect{r.x + r.w - m.track_pad - 46, r.y + 11, 46, 26}
		l.take[i] = Rect{l.input[i].x - 48, r.y + 11, 44, 26}

		if compact_tracks {
			// Rack-focused layout: keep the track identity, FX summary,
			// arm/solo/mute and a horizontal level bar; hide the fader stack.
			bw := (inner_w - 10) / 3
			l.arm[i] = Rect{inner_x, r.y + 76, bw, 26}
			l.solo[i] = Rect{inner_x + bw + 5, r.y + 76, bw, 26}
			l.mute[i] = Rect{inner_x + (bw + 5) * 2, r.y + 76, bw, 26}
			l.pan[i] = Rect{}
			l.fader[i] = Rect{}
			l.meter[i] = Rect{}
			l.gr[i] = Rect{inner_x, r.y + 112, inner_w, 14}
		} else {
			compact_controls := area_h < 250
			tog_y := r.y + 70 if compact_controls else r.y + 82
			tog_pitch: f32 = 28 if compact_controls else 32
			tog_w: f32 = min(68, inner_w * 0.36)
			for j in 0 ..< 3 {
				rect := Rect{inner_x, tog_y + f32(j) * tog_pitch, tog_w, 26}
				switch j {
				case 0: l.arm[i] = rect
				case 1: l.solo[i] = rect
				case 2: l.mute[i] = rect
				}
			}

			fader_x := inner_x + inner_w - 58
			pan_cx := inner_x + tog_w + (fader_x - (inner_x + tog_w)) * 0.5
			l.pan[i] = Rect{pan_cx - 26, tog_y + 12, 52, 60}

			fader_h := clamp(area_h - (tog_y - r.y) - 40, 60, 240)
			l.fader[i] = Rect{fader_x, tog_y, 20, fader_h}
			l.meter[i] = Rect{fader_x + 30, tog_y - 4, 10, fader_h + 16}
			l.gr[i] = Rect{fader_x, tog_y + fader_h + 26, min(120, inner_w - (fader_x - inner_x)), 14}
		}
	}

	// ── master lives in the bottom bar ─────────────────────────────────
	l.master = Rect{w - 336, l.bottom.y + 5, 320, 34}
	l.master_meter = Rect{l.master.x + 108, l.master.y + 24, 120, 5}

	// ── FX rack ────────────────────────────────────────────────────────
	{
		tab_w: f32 = 40
		for i in 0 ..< 5 {
			l.fx_tab[i] = Rect{l.fx_panel.x + 72 + f32(i) * (tab_w + 4), l.fx_panel.y + 10, tab_w, 28}
		}
		l.fx_close = Rect{l.fx_panel.x + l.fx_panel.w - 40, l.fx_panel.y + 10, 28, 28}

		inner := Rect{l.fx_panel.x + 12, l.fx_panel.y + 48, l.fx_panel.w - 24, fx_h - 60}
		if a.fx_channel >= MAX_TRACKS {
			modules := [5]Fx_Module{.COMP, .REVERB, .DELAY, .WIDTH, .LIMITER}
			counts := [5]int{5, 5, 4, 2, 3}
			mod_gap: f32 = 8
			mod_w := (inner.w - mod_gap * 4) / 5
			for mod, i in modules {
				p := Rect{inner.x + f32(i) * (mod_w + mod_gap), inner.y, mod_w, inner.h}
				l.fx_module[i] = p
				l.fx_module_id[i] = mod
				l.fx_module_count += 1
				layout_module(l, p, mod, counts[i], p.y + 92)
				add_toggle(l, Rect{p.x + p.w - 44, p.y + 10, 40, 24}, mod, 0)
				if mod == .DELAY {
					add_toggle(l, Rect{p.x + p.w - 84, p.y + 10, 38, 24}, mod, 1)
				}
			}
		} else {
			modules := [3]Fx_Module{.EQ, .COMP, .SEND}
			counts := [3]int{5, 5, 2}
			mod_gap: f32 = 12
			mod_w := (inner.w - mod_gap * 2) / 3
			for mod, i in modules {
				p := Rect{inner.x + f32(i) * (mod_w + mod_gap), inner.y, mod_w, inner.h}
				l.fx_module[i] = p
				l.fx_module_id[i] = mod
				l.fx_module_count += 1
				layout_module(l, p, mod, counts[i], p.y + 92)
				if mod != .SEND {
					add_toggle(l, Rect{p.x + p.w - 52, p.y + 10, 44, 24}, mod, 0)
				}
			}
		}
	}

	// ── palette (content-sized, windowed; selection drives the scroll) ─
	pal_w := min(m.palette_w, w - 120)
	pal_max_h := min(m.palette_h, h - 160)
	palette_visible := max(int((pal_max_h - 116) / 34), 1)
	if a.palette_count > 0 {
		if a.palette_sel < a.palette_scroll {
			a.palette_scroll = a.palette_sel
		}
		if a.palette_sel >= a.palette_scroll + palette_visible {
			a.palette_scroll = a.palette_sel - palette_visible + 1
		}
		a.palette_scroll = clamp(a.palette_scroll, 0, max(a.palette_count - palette_visible, 0))
	} else {
		a.palette_scroll = 0
	}
	l.palette_visible = palette_visible
	l.palette_count = max(min(a.palette_count - a.palette_scroll, palette_visible), 0)
	pal_rows := max(l.palette_count, 1)
	pal_h := min(pal_max_h, 96 + f32(pal_rows) * 34 + 44)
	l.palette = Rect{(w - pal_w) * 0.5, max(76, (h - pal_h) * 0.5), pal_w, pal_h}
	l.palette_input = Rect{l.palette.x + 16, l.palette.y + 46, l.palette.w - 32, 36}
	for i in 0 ..< MAX_PALETTE {
		l.palette_row[i] = Rect{l.palette.x + 12, l.palette.y + 96 + f32(i) * 34, l.palette.w - 24, 32}
	}

	// ── recent projects (content-sized) ────────────────────────────────
	l.recent_count = a.recent_filtered
	recent_rows := max(min(l.recent_count, MAX_RECENT), 1)
	recent_h := min(f32(420), 96 + f32(recent_rows) * 34 + 78)
	l.recent_panel = Rect{(w - 640) * 0.5, max(100, (h - recent_h) * 0.5), 640, recent_h}
	l.recent_input = Rect{l.recent_panel.x + 16, l.recent_panel.y + 46, l.recent_panel.w - 32, 36}
	for i in 0 ..< MAX_RECENT {
		l.recent_row[i] = Rect{l.recent_panel.x + 12, l.recent_panel.y + 96 + f32(i) * 34, l.recent_panel.w - 24, 32}
	}

	// ── I/O drawer (content-sized, two columns when crowded) ───────────
	io_w := min(m.io_w, w - 80)
	l.io_count = min(len(a.devices), MAX_DEVICES)
	io_cols := 1 if l.io_count <= 10 else 2
	io_rows := max((l.io_count + io_cols - 1) / io_cols, 1)
	io_h := min(h - 136, 96 + f32(io_rows) * 36 + 78)
	l.io_panel = Rect{w - io_w - 20, max(76, (h - io_h) * 0.5), io_w, io_h}
	io_ctl_y := l.io_panel.y + l.io_panel.h - 68
	l.jack = Rect{l.io_panel.x + 16, io_ctl_y, 68, 30}
	l.rescan = Rect{l.io_panel.x + 92, io_ctl_y, 82, 30}
	l.lat_minus = Rect{l.io_panel.x + 194, io_ctl_y, 28, 30}
	l.lat_plus = Rect{l.io_panel.x + 302, io_ctl_y, 28, 30}
	col_w := (l.io_panel.w - 28 - f32(io_cols - 1) * 8) / f32(io_cols)
	for i in 0 ..< MAX_DEVICES {
		col := i / io_rows
		row := i % io_rows
		l.io_row[i] = Rect{l.io_panel.x + 14 + f32(col) * (col_w + 8), l.io_panel.y + 96 + f32(row) * 36, col_w, 32}
	}

	if a.fx_focus >= l.knob_count + l.toggle_count {
		a.fx_focus = -1
	}
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
		a.take_del_track = -1
		if a.transport == .Recording {
			toast(a, "recording: Space or r punches out")
			status_buf_set(a, "recording: Space or r punches out")
			return
		}
		if a.transport == .Playing {
			return
		}
		a.audition_end = 0
		a.transport = .Playing
		if app_loop_active(a) {
			if !a.tape_cued || a.frames >= a.end_marker || a.frames < app_range_start(a) {
				a.frames = app_range_start(a)
				a.tape_cued = a.frames > 0
			}
		} else {
			if !a.tape_cued {
				a.frames = 0
			} else if a.tape_frames > 0 && a.frames >= a.tape_frames {
				a.frames = 0
				a.tape_cued = false
			}
		}
		status_buf_set(a, "looping section" if app_loop_active(a) else "playing preview")
		emit(a, .Play)
		bump_revision(a)
	case .Stop:
		app_stop_return(a)
	case .Pause:
		app_pause(a)
	case .Set_Marker:
		app_marker_set(a)
	case .Clear_Marker:
		app_marker_clear(a)
	case .Goto_Marker:
		app_marker_goto(a)
	case .Set_End_Marker:
		app_end_marker_set(a)
	case .Clear_End_Marker:
		app_end_marker_clear(a)
	case .Goto_End_Marker:
		app_end_marker_goto(a)
	case .Loop_Toggle:
		app_loop_toggle(a)
	case .Punch_Out_Toggle:
		app_punch_out_toggle(a)
	case .Audition:
		app_audition(a)
	case .Record_Now:
		a.take_del_track = -1
		app_record_start(a, true)
	case .Preroll_Next:
		app_preroll_cycle(a)
	case .Preroll_Audio:
		app_preroll_audio_toggle(a)
	case .Timing_Mode:
		app_timing_mode_toggle(a)
	case .Time_Sig_Next:
		app_time_sig_cycle(a)
	case .Record_Start:
		a.take_del_track = -1
		app_record_start(a, a.shift_down)
	case .Record_Stop:
		a.audition_end = 0
		a.record_punch_out = 0
		a.transport = .Stopped
		a.frames = max(a.frames, 0)
		a.tape_cued = a.frames > 0
		status_buf_set(a, "take captured (undo keeps audio) · STOP returns to the marker")
		emit(a, .Record_Stop)
		bump_revision(a)
	case .Bounce:
		a.take_del_track = -1
		if a.transport == .Recording {
			toast(a, "stop recording before bounce")
			status_buf_set(a, "stop recording before bounce")
			return
		}
		if a.bounce_active {
			toast(a, "bounce already running")
			return
		}
		project_edit_clear(a)
		a.mode = .Bounce
		a.bounce_progress = 0
		a.bounce_active = true
		status_buf_set(a, "bouncing")
		emit(a, .Bounce)
		bump_revision(a)
	case .Track_Add:
		_ = app_track_add(a)
	case .Track_Remove:
		a.take_del_track = -1
		_ = app_track_remove(a)
	case .Delete_Track:
		emit(a, .Delete_Track, index)
	case .Bounce_Tracks:
		a.take_del_track = -1
		_ = app_tb_open(a)
	case .Bounce_To_Track:
		emit(a, .Bounce_To_Track, index)
	case .Zoom_In:
		app_view_zoom(a, -1)
	case .Zoom_Out:
		app_view_zoom(a, 1)
	case .Page_Next:
		app_view_page(a, 1)
	case .Page_Prev:
		app_view_page(a, -1)
	case .Rename_Track:
		app_track_begin_edit(a, a.selected)
	case .Apply_Track_Name:
		if app_track_commit_edit(a) {
			// persisted (project.json + next Drive backup) by the window
			emit(a, .Apply_Project_Name)
		}
	case .Render_Mix:
		a.take_del_track = -1
		if a.transport == .Recording {
			toast(a, "stop recording before rendering")
			status_buf_set(a, "stop recording before rendering")
			return
		}
		if a.mode == .Render {
			return
		}
		project_edit_clear(a)
		a.last_command = .Render_Mix
		a.last_command_index = 0
		app_render_open(a)
		emit(a, .Render_Mix)
	case .Render_File:
		if a.mode != .Render {
			return
		}
		a.last_command = .Render_File
		a.last_command_index = 0
		emit(a, .Render_File)
		status_buf_set(a, "choose where to render the mix")
	case .Save:
		a.last_command = .Save
		emit(a, .Save)
		status_buf_set(a, "saving project")
	case .Load:
		a.last_command = .Load
		emit(a, .Load)
		status_buf_set(a, "loading project")
	case .New_Project:
		a.take_del_track = -1
		_ = app_new_project_begin(a)
	case .Create_Project:
		app_new_project_commit(a)
	case .Open_Project:
		a.last_command = .Open_Project
		a.last_command_index = 0
		emit(a, .Open_Project)
		status_buf_set(a, "open project: waiting for picker")
		toast(a, "choose a project")
	case .Save_As:
		a.last_command = .Save_As
		a.last_command_index = 0
		emit(a, .Save_As)
		status_buf_set(a, "save project as: waiting for picker")
		toast(a, "choose a destination")
	case .Rename_Project:
		a.last_command = .Rename_Project
		a.last_command_index = 0
		a.mode = .Normal
		a.fx_focus = -1
		app_project_begin_edit(a, true)
		status_buf_set(a, "rename project")
	case .Apply_Project_Name:
		if app_project_commit_edit(a) {
			a.last_command = .Apply_Project_Name
			a.last_command_index = 0
			emit(a, .Apply_Project_Name)
		}
	case .Seek:
		a.last_command = .Seek
		emit(a, .Seek)
	case .Seek_Zero:
		_ = app_seek_zero(a)
	case .Shuttle_Back:
		_ = app_scrub_wheel(a, .Shuttle, -1, app_scrub_speed(a.shift_down, a.ctrl_down, a.alt_down))
	case .Shuttle_Forward:
		_ = app_scrub_wheel(a, .Shuttle, 1, app_scrub_speed(a.shift_down, a.ctrl_down, a.alt_down))
	case .Jog_Back:
		_ = app_scrub_wheel(a, .Jog, -1, app_scrub_speed(a.shift_down, a.ctrl_down, a.alt_down))
	case .Jog_Forward:
		_ = app_scrub_wheel(a, .Jog, 1, app_scrub_speed(a.shift_down, a.ctrl_down, a.alt_down))
	case .Select_Device:
		a.device_index = clamp(index, 0, max(len(a.devices) - 1, 0))
		if len(a.devices) > 0 {
			device_buf_set(a, a.devices[a.device_index])
		}
		emit(a, .Select_Device, a.device_index)
		status_buf_set(a, "input device selected")
		bump_revision(a)
	case .Fx:
		a.take_del_track = -1
		project_edit_clear(a)
		a.mode = .Fx if a.mode != .Fx else .Normal
		if a.mode != .Fx {
			a.fx_focus = -1
		}
		status_buf_set(a, "fx rack")
		bump_revision(a)
	case .Io:
		a.take_del_track = -1
		project_edit_clear(a)
		a.mode = .Io if a.mode != .Io else .Normal
		bump_revision(a)
	case .Settings:
		a.take_del_track = -1
		if a.mode == .Settings {
			app_settings_close(a)
		} else {
			app_settings_open(a)
		}
	case .Choose_Save_Dir:
		a.settings_path_edit = false
		a.last_command = .Choose_Save_Dir
		a.last_command_index = 0
		emit(a, .Choose_Save_Dir)
		status_buf_set(a, "choose project folder")
	case .Apply_Save_Dir:
		path := app_settings_path(a)
		if path == "" {
			toast(a, "project folder is empty")
			status_buf_set(a, "project folder is empty")
			bump_revision(a)
		} else {
			a.settings_path_edit = false
			a.last_command = .Apply_Save_Dir
			a.last_command_index = 0
			emit(a, .Apply_Save_Dir)
			status_buf_set(a, "applying project folder")
			bump_revision(a)
		}
	case .Reset_Save_Dir:
		a.last_command = .Reset_Save_Dir
		a.last_command_index = 0
		a.settings_path_edit = false
		emit(a, .Reset_Save_Dir)
		status_buf_set(a, "reset to default folder")
		bump_revision(a)
	case .Cloud:
		a.take_del_track = -1
		project_edit_clear(a)
		if a.mode == .Cloud {
			a.mode = .Normal
			status_buf_set(a, "cloud projects closed")
			bump_revision(a)
		} else {
			app_execute(a, .Cloud_Open)
		}
	case .Cloud_Open:
		a.take_del_track = -1
		project_edit_clear(a)
		a.mode = .Cloud
		a.cloud_selected = 0
		status_buf_set(a, "cloud projects")
		emit(a, .Cloud_List)
		bump_revision(a)
	case .Cloud_Connect:
		a.cloud_edit = .None
		a.last_command = .Cloud_Connect
		a.last_command_index = 0
		emit(a, .Cloud_Connect)
		status_buf_set(a, "connecting Google Drive")
		bump_revision(a)
	case .Cloud_Disconnect:
		a.last_command = .Cloud_Disconnect
		a.last_command_index = 0
		emit(a, .Cloud_Disconnect)
		status_buf_set(a, "disconnecting Google Drive")
		bump_revision(a)
	case .Cloud_Backup:
		a.cloud_edit = .None
		if a.mode == .Settings {
			trimmed := strings.trim_space(app_project_draft(a))
			if trimmed != "" && trimmed != app_project(a) {
				_ = app_project_commit_edit(a)
			}
			a.project_name_edit = false
		}
		if a.transport == .Recording {
			toast(a, "stop recording before backing up")
			status_buf_set(a, "stop recording before backing up")
			return
		}
		a.last_command = .Cloud_Backup
		a.last_command_index = 0
		emit(a, .Cloud_Backup)
		status_buf_set(a, "preparing Google Drive backup")
		bump_revision(a)
	case .Cloud_Restore:
		a.cloud_edit = .None
		if a.cloud_project_count == 0 {
			toast(a, "no cloud projects")
			status_buf_set(a, "no cloud projects")
			return
		}
		a.last_command = .Cloud_Restore
		a.last_command_index = a.cloud_selected
		emit(a, .Cloud_Restore, a.cloud_selected)
		status_buf_set(a, "restoring cloud project")
		bump_revision(a)
	case .Cloud_List:
		a.cloud_edit = .None
		a.last_command = .Cloud_List
		a.last_command_index = 0
		emit(a, .Cloud_List)
		status_buf_set(a, "refreshing cloud projects")
		bump_revision(a)
	case .Cloud_Save_Credentials:
		a.last_command = .Cloud_Save_Credentials
		a.last_command_index = 0
		emit(a, .Cloud_Save_Credentials)
		status_buf_set(a, "saving Google credentials")
		bump_revision(a)
	case .Recent:
		a.take_del_track = -1
		project_edit_clear(a)
		if a.mode == .Recent {
			a.mode = .Normal
			status_buf_set(a, "recent projects closed")
			bump_revision(a)
		} else {
			app_recent_open(a)
		}
	case .Open_Recent:
		a.last_command = .Open_Recent
		a.last_command_index = index
		if index >= 0 && index < a.recent_count {
			buf_set(a.recent_target_buf[:], &a.recent_target_len, app_recent_path(a, index))
		}
		emit(a, .Open_Recent, index)
		a.mode = .Normal
		status_buf_set(a, fmt.tprintf("open %s", app_recent_target(a)))
		bump_revision(a)
	case .Metronome:
		a.metronome = !a.metronome
		status_buf_set(a, "metronome on" if a.metronome else "metronome off")
		app_history_note(a, "metronome")
		app_touch(a)
	case .Monitor:
		a.last_command = .Monitor
		a.last_command_index = 0
		a.monitor = !a.monitor
		emit(a, .Monitor)
		status_buf_set(a, "monitor on" if a.monitor else "monitor off")
		app_history_note(a, "monitor")
		app_touch(a)
	case .Latency_Up:
		a.last_command = .Latency_Up
		a.last_command_index = 0
		a.latency_ms = clamp(a.latency_ms + 1, 0, 500)
		emit(a, .Latency_Up)
		status_buf_set(a, fmt.tprintf("latency %.0f ms", a.latency_ms))
		app_history_note(a, "latency")
		app_touch(a)
	case .Latency_Down:
		a.last_command = .Latency_Down
		a.last_command_index = 0
		a.latency_ms = clamp(a.latency_ms - 1, 0, 500)
		emit(a, .Latency_Down)
		status_buf_set(a, fmt.tprintf("latency %.0f ms", a.latency_ms))
		app_history_note(a, "latency")
		app_touch(a)
	case .Backend:
		a.last_command = .Backend
		a.last_command_index = 0
		a.jack_backend = !a.jack_backend
		emit(a, .Backend)
		status_buf_set(a, "JACK capture" if a.jack_backend else fmt.tprintf("%s capture", platform_audio_backend_name()))
		app_history_note(a, "backend")
		app_touch(a)
	case .Rescan:
		a.last_command = .Rescan
		a.last_command_index = 0
		emit(a, .Rescan)
		status_buf_set(a, "rescanning devices")
	case .Take_Next, .Take_Prev:
		a.take_del_track = -1
		emit(a, kind, a.selected)
		status_buf_set(a, "take selected")
	case .Take_New:
		_ = app_take_new(a, a.selected)
	case .Take_Delete:
		_ = app_take_delete_arm(a, a.selected)
	case .Delete_Take:
		emit(a, .Delete_Take, index)
	case .Comp_Use:
		a.take_del_track = -1
		emit(a, .Comp_Use, a.selected)
		status_buf_set(a, "comp: active take")
	case .Comp_Clear:
		a.take_del_track = -1
		emit(a, .Comp_Clear, a.selected)
		status_buf_set(a, "comp cleared")
		app_history_note(a, "metronome")
		app_touch(a)
	case .Bpm_Up:
		a.bpm = clamp(a.bpm + 1, 40, 240)
		app_history_note(a, "tempo")
		app_touch(a)
	case .Bpm_Down:
		a.bpm = clamp(a.bpm - 1, 40, 240)
		app_history_note(a, "tempo")
		app_touch(a)
	case .Arm_All:
		if a.transport == .Recording {
			toast(a, "stop recording to change arms")
			return
		}
		for i in 0 ..< a.track_count {
			a.tracks[i].armed = true
		}
		status_buf_set(a, "all tracks armed")
		app_history_note(a, "arms")
		app_touch(a)
	case .Clear_Arms:
		if a.transport == .Recording {
			toast(a, "stop recording to change arms")
			return
		}
		for i in 0 ..< MAX_TRACKS {
			a.tracks[i].armed = false
		}
		status_buf_set(a, "arms cleared")
		app_history_note(a, "arms")
		app_touch(a)
	case .Panic:
		a.take_del_track = -1
		project_edit_clear(a)
		a.audition_end = 0
		a.record_punch_out = 0
		a.transport = .Stopped
		a.frames = 0
		a.tape_cued = false
		a.mode = .Normal
		a.fx_focus = -1
		status_buf_set(a, "stopped")
		toast(a, "panic stop")
		emit(a, .Stop)
		bump_revision(a)
	case .Undo:
		app_undo(a)
	case .Redo:
		app_redo(a)
	case .High_Contrast:
		a.high_contrast = !a.high_contrast
		a.settings_dirty = true
		status_buf_set(a, "high contrast on" if a.high_contrast else "high contrast off")
		toast(a, "high contrast on" if a.high_contrast else "high contrast off")
		bump_revision(a)
	case .Reduced_Motion:
		a.reduced_motion = !a.reduced_motion
		a.settings_dirty = true
		status_buf_set(a, "reduced motion on" if a.reduced_motion else "reduced motion off")
		toast(a, "reduced motion on" if a.reduced_motion else "reduced motion off")
		bump_revision(a)
	}
}

app_force_stopped :: proc(a: ^App, msg: string) {
	a.record_punch_out = 0
	a.transport = .Stopped
	status_buf_set(a, msg)
}

app_bounce_finished :: proc(a: ^App, ok: bool, msg: string, target := -1) {
	a.mode = .Normal
	a.bounce_progress = 1.0
	a.bounce_active = false
	status_buf_set(a, msg)
	if ok {
		if target >= 0 && target < a.track_count {
			a.tracks[target].has_audio = true
			a.selected = target
			app_view_clamp(a)
		}
		toast(a, "bounce complete")
	} else {
		toast(a, "bounce failed")
	}
	bump_revision(a)
}

app_toggle_record :: proc(a: ^App, skip_preroll := false) {
	if a.transport == .Recording {
		app_execute(a, .Record_Stop)
	} else if skip_preroll {
		app_execute(a, .Record_Now)
	} else {
		app_execute(a, .Record_Start)
	}
}

// Space: play <-> pause in place; while recording it punches out (the take is
// kept and the tape stays where recording ended).
app_toggle_play :: proc(a: ^App) {
	switch a.transport {
	case .Recording:
		app_execute(a, .Record_Stop)
	case .Playing:
		app_execute(a, .Pause)
	case .Stopped:
		app_execute(a, .Play)
	}
}

// Dismissing the overlay does not stop the render job; the progress bar keeps
// advancing in the tick so the take still finishes.
app_bounce_dismiss :: proc(a: ^App) {
	if a.mode != .Bounce {
		return
	}
	a.mode = .Normal
	status_buf_set(a, "bounce continues in background")
}

// ---------------------------------------------------------------- render dialog

render_time_text :: proc(seconds: f32) -> string {
	tenths := int(max(seconds, 0) * 10 + 0.5)
	deci := tenths % 10
	total_s := tenths / 10
	s := total_s % 60
	m := (total_s / 60) % 60
	h := total_s / 3600
	if h > 0 {
		return fmt.tprintf("%d:%02d:%02d.%d", h, m, s, deci)
	}
	return fmt.tprintf("%d:%02d.%d", m, s, deci)
}

render_format_label :: proc(format: Render_Format) -> string {
	switch format {
	case .Wav_F32:
		return "WAV · 32-bit float"
	case .Wav_PCM24:
		return "WAV · 24-bit PCM"
	case .Wav_PCM16:
		return "WAV · 16-bit PCM"
	}
	return "WAV"
}

render_format_chip :: proc(format: Render_Format) -> string {
	switch format {
	case .Wav_F32:
		return "32-BIT FLOAT"
	case .Wav_PCM24:
		return "24-BIT"
	case .Wav_PCM16:
		return "16-BIT"
	}
	return "?"
}

@(private)
app_render_open :: proc(a: ^App) {
	a.mode = .Render
	a.render_sel = 0
	a.render_from = 0
	a.render_to = 0
	a.render_duration = 0
	a.render_drag = .None
	a.render_grab = 0
	status_buf_set(a, "render range: full mix")
	bump_revision(a)
}

app_render_close :: proc(a: ^App) {
	if a.mode != .Render {
		return
	}
	a.mode = .Normal
	a.render_drag = .None
	a.render_grab = 0
	bump_revision(a)
}

app_render_select :: proc(a: ^App, row: int) {
	a.render_sel = clamp(row, 0, 2)
	bump_revision(a)
}

// Called by the window after .Render_Mix, when the engine can measure the
// loaded takes and the FX tail. Keeping this out of app_execute preserves the
// headless model tests and lets `ui-shot` render the dialog without an engine.
app_render_set_duration :: proc(a: ^App, seconds: f32) {
	if a.mode != .Render || seconds <= 0 {
		return
	}
	a.render_duration = seconds
	if a.render_to <= 0 || a.render_to > seconds {
		a.render_to = seconds
	}
	a.render_from = clamp(a.render_from, 0, max(a.render_to - 0.1, 0))
	status_buf_set(a, fmt.tprintf("render range %s → %s", render_time_text(a.render_from), render_time_text(a.render_to)))
	bump_revision(a)
}

app_render_set_format :: proc(a: ^App, format: Render_Format) {
	if a.render_format == format {
		return
	}
	a.render_format = format
	status_buf_set(a, render_format_label(a.render_format))
	bump_revision(a)
}

app_render_cycle_format :: proc(a: ^App, direction: int) {
	if direction == 0 {
		return
	}
	next := (int(a.render_format) + direction + RENDER_FORMAT_COUNT) % RENDER_FORMAT_COUNT
	app_render_set_format(a, Render_Format(next))
}

// Clamps one hand and updates the dialog status. `seconds` is absolute in the
// mix; FROM cannot pass TO and TO cannot pass FROM.
app_render_set_handle_time :: proc(a: ^App, handle: Render_Handle, seconds: f32) {
	if a.mode != .Render || a.render_duration <= 0 {
		return
	}
	switch handle {
	case .From:
		upper := max(a.render_to - 0.1, 0)
		a.render_from = clamp(seconds, 0, upper)
	case .To:
		lower := min(a.render_from + 0.1, a.render_duration)
		a.render_to = clamp(seconds, lower, a.render_duration)
	case .None:
		return
	}
	status_buf_set(a, fmt.tprintf("render range %s → %s", render_time_text(a.render_from), render_time_text(a.render_to)))
	bump_revision(a)
}

app_render_adjust :: proc(a: ^App, direction: int, shift: bool) {
	if direction == 0 || a.mode != .Render {
		return
	}
	if a.render_sel == 2 {
		app_render_cycle_format(a, direction)
		return
	}
	step := RENDER_COARSE_STEP_SECONDS if shift else RENDER_STEP_SECONDS
	if a.render_sel == 0 {
		app_render_set_handle_time(a, .From, a.render_from + f32(direction) * step)
	} else {
		app_render_set_handle_time(a, .To, a.render_to + f32(direction) * step)
	}
}

// Starts a pointer drag on one hand. `pointer_seconds` is the mix time under
// the cursor; storing the offset keeps the hand from jumping when grabbed
// away from its center.
app_render_drag_start :: proc(a: ^App, handle: Render_Handle, pointer_seconds: f32) {
	if a.mode != .Render || a.render_duration <= 0 || handle == .None {
		return
	}
	current := a.render_from if handle == .From else a.render_to
	a.render_sel = 0 if handle == .From else 1
	a.render_drag = handle
	a.render_grab = current - pointer_seconds
	bump_revision(a)
}

app_render_drag_update :: proc(a: ^App, pointer_seconds: f32) {
	if a.render_drag == .None {
		return
	}
	app_render_set_handle_time(a, a.render_drag, pointer_seconds + a.render_grab)
}

app_render_drag_end :: proc(a: ^App) {
	a.render_drag = .None
	a.render_grab = 0
}

// ---------------------------------------------------------------- tape scrub

// Step size in seconds for one tick/key on the dual tape wheels.
// Shuttle seeks across phrases; Jog scrubs sub-second phrasing; modifiers step down smoothly.
scrub_step_seconds :: proc(wheel: Scrub_Wheel, speed: Scrub_Speed) -> f32 {
	switch wheel {
	case .Shuttle:
		switch speed {
		case .Normal: return 5.0
		case .Slow:   return 1.0
		case .Micro:  return 0.25
		}
	case .Jog:
		switch speed {
		case .Normal: return 0.25
		case .Slow:   return 0.05
		case .Micro:  return 0.01
		}
	}
	return 0.25
}

app_scrub_speed :: proc(shift, ctrl, alt: bool) -> Scrub_Speed {
	if ctrl || alt {
		return .Micro
	}
	if shift {
		return .Slow
	}
	return .Normal
}

app_set_tape_frames :: proc(a: ^App, frames: i64) {
	if a == nil {
		return
	}
	a.tape_frames = max(frames, 0)
	// A take being recorded may run past the old tape end; only clamp an idle
	// or playing playhead.
	if a.transport != .Recording && a.tape_frames > 0 && a.frames > a.tape_frames {
		a.frames = a.tape_frames
		a.tape_cued = a.frames > 0
	}
}

app_scrub_seconds :: proc(a: ^App, delta_s: f32) -> bool {
	if a == nil {
		return false
	}
	if a.transport == .Recording {
		toast(a, "stop recording to scrub")
		status_buf_set(a, "stop recording to scrub")
		return false
	}
	rate := max(i64(a.sample_rate), 1)
	limit := a.tape_frames if a.tape_frames > 0 else rate * 3_600
	delta_frames := i64(math.round(f64(delta_s) * f64(rate)))
	if delta_frames == 0 && delta_s != 0 {
		delta_frames = 1 if delta_s > 0 else -1
	}
	next := clamp(a.frames + delta_frames, 0, limit)
	a.frames = next
	a.tape_cued = next > 0
	status_buf_set(a, fmt.tprintf("cue %s", app_position_text(a, a.frames)))
	a.last_command = .Seek
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
	return true
}

scrub_grid_step_beats :: proc(a: ^App, wheel: Scrub_Wheel, speed: Scrub_Speed) -> f64 {
	sig := app_time_sig(a)
	switch wheel {
	case .Shuttle:
		switch speed {
		case .Normal: return f64(max(int(sig.num), 1))
		case .Slow:   return 1.0
		case .Micro:  return 0.25
		}
	case .Jog:
		switch speed {
		case .Normal: return 1.0
		case .Slow:   return 0.25
		case .Micro:  return 0.25
		}
	}
	return 1.0
}

app_scrub_wheel :: proc(a: ^App, wheel: Scrub_Wheel, steps: f32, speed: Scrub_Speed) -> bool {
	if a == nil || steps == 0 {
		return false
	}
	if a.transport == .Recording {
		toast(a, "stop recording to scrub")
		status_buf_set(a, "stop recording to scrub")
		return false
	}
	if a.timing_mode == .Free || (wheel == .Jog && speed == .Micro) {
		return app_scrub_seconds(a, steps * scrub_step_seconds(wheel, speed))
	}
	unit := max(scrub_grid_step_beats(a, wheel, speed) * app_beat_frames_f64(a), 1.0)
	n := int(math.round(steps))
	if n == 0 {
		n = 1 if steps > 0 else -1
	}
	cur := max(a.frames, 0)
	g := f64(cur) / unit
	eps := 1e-4
	k: i64
	if n > 0 {
		first := i64(math.floor(g + eps)) + 1
		k = first + i64(n - 1)
	} else {
		first := i64(math.ceil(g - eps)) - 1
		k = first + i64(n + 1)
	}
	rate := app_rate(a)
	limit := a.tape_frames if a.tape_frames > 0 else rate * 3_600
	target := clamp(i64(math.round(f64(k) * unit)), 0, limit)
	a.frames = target
	a.tape_cued = target > 0
	status_buf_set(a, fmt.tprintf("cue %s", app_position_text(a, a.frames)))
	a.last_command = .Seek
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
	return true
}

app_seek_zero :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	if a.transport == .Recording {
		toast(a, "stop recording to scrub")
		status_buf_set(a, "stop recording to scrub")
		return false
	}
	a.frames = 0
	a.tape_cued = false
	status_buf_set(a, fmt.tprintf("rewound to %s", app_position_text(a, 0)))
	a.last_command = .Seek_Zero
	a.last_command_index = 0
	emit(a, .Seek)
	bump_revision(a)
	return true
}

// ---------------------------------------------------------------- tick

app_tick :: proc(a: ^App, dt: f32) {
	a.time += dt
	a.frame_no += 1
	if a.transport != .Stopped {
		a.frames += i64(dt * f32(a.sample_rate))
		if a.transport == .Playing && a.audition_end <= 0 && app_loop_active(a) && a.frames >= a.end_marker {
			span := a.end_marker - app_range_start(a)
			if span > 0 {
				a.frames = app_range_start(a) + ((a.frames - app_range_start(a)) % span)
			}
		}
		if !a.engine_clock && a.transport == .Recording && a.record_punch_out > 0 && a.frames >= a.record_punch_out {
			app_auto_punch_out(a)
		}
	}
	app_audition_tick(a)
	if a.toast_time > 0 {
		a.toast_time -= dt
		if a.toast_time <= 0 {
			a.toast_len = 0
		}
	}

	if a.demo {
		for i in 0 ..< MAX_TRACKS {
			t := &a.tracks[i]
			// Arming alone is enough to show a live input trace in demo mode,
			// mirroring the capture preview in the real engine.
			armed_idle := t.armed && a.transport == .Stopped
			active := armed_idle || (a.transport != .Stopped && (t.has_audio || (a.transport == .Recording && t.armed)))
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

	a.peak_history_acc += dt
	for a.peak_history_acc >= 0.05 {
		a.peak_history_acc -= 0.05
		a.peak_history_pos = (a.peak_history_pos + 1) % HISTORY_LEN
		for i in 0 ..< MAX_TRACKS {
			a.peak_history[i][a.peak_history_pos] = a.tracks[i].peak_db
		}
	}

	// The render job is independent of the overlay: dismissing the panel must
	// not freeze a half-finished bounce.
	if a.bounce_active {
		a.bounce_progress = min(a.bounce_progress + dt * 0.9, 1.0)
		if a.bounce_progress >= 1.0 {
			a.bounce_active = false
			if a.mode == .Bounce {
				a.mode = .Normal
			}
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
