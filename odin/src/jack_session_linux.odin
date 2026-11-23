#+build linux
// Linux JACK session backend.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

foreign import jack_session "system:jack"

Jack_Session_Shutdown_Callback :: proc "c" (arg: rawptr)
Jack_Session_XRun_Callback :: proc "c" (arg: rawptr) -> c.int

foreign jack_session {
	jack_get_buffer_size   :: proc(client: ^jack_client_t) -> u32 ---
	jack_on_shutdown       :: proc(client: ^jack_client_t, callback: Jack_Session_Shutdown_Callback, arg: rawptr) ---
	jack_set_xrun_callback :: proc(client: ^jack_client_t, callback: Jack_Session_XRun_Callback, arg: rawptr) -> c.int ---
}

Jack_Chunk :: struct {
	next:     ^Jack_Chunk,
	samples:  []f32,
	frames:   int,
	capacity: int,
}

// A live JACK take. Zero value is idle and safe to destroy.
Jack_Session :: struct {
	state:     Jack_Session_State,
	error:     Jack_Session_Error,
	detail:    [256]u8,
	detail_len: int,

	channels:      int,
	rate:          u32, // actual server rate once start succeeds
	requested_rate: u32,
	max_frames:    int, // 0 = unbounded (GUI takes)
	port_count:    int, // explicit ports requested, 0 = auto

	client:    ^jack_client_t,
	activated: bool,
	ports:     []^jack_port_t,
	connect_count: int,
	client_name: string,
	source_names: []string,

	// Lock-free capture ring. The callback only touches write_frame and
	// the samples it owns between read/write; the writer owns read_frame.
	ring:       []f32,
	cap_frames: int,
	write_frame: u64,
	read_frame:  u64,
	overflow:    u64,
	peak:        [MAX_JACK_SESSION_CHANNELS]f32,

	stop:        u64,
	active:      u64,
	writer_error: u64,
	xruns:       u64,
	server_down: u64,

	// Written by the writer thread only; read after join.
	writer:      ^thread.Thread,
	chunks:      ^Jack_Chunk,
	tail:        ^Jack_Chunk,
	chunk_frames: int,
}

// ---------------------------------------------------------------- helpers

@(private)
jack_session_set_detail :: proc(s: ^Jack_Session, err: Jack_Session_Error, msg: string) {
	s.error = err
	s.state = .Failed
	n := min(len(msg), len(s.detail) - 1)
	for i in 0 ..< n {
		s.detail[i] = msg[i]
	}
	s.detail[n] = 0
	s.detail_len = n
	fmt.eprintfln("JACK session: %s", msg)
}

jack_session_detail :: proc(s: ^Jack_Session) -> string {
	if s == nil || s.detail_len <= 0 {
		return ""
	}
	return string(s.detail[:clamp(s.detail_len, 0, len(s.detail))])
}

jack_session_error :: proc(s: ^Jack_Session) -> Jack_Session_Error {
	return s.error if s != nil else .Bad_Arguments
}

jack_session_is_running :: proc(s: ^Jack_Session) -> bool {
	if s == nil || s.state != .Running {
		return false
	}
	return sync.atomic_load(&s.active) != 0 && s.client != nil
}

// Frames delivered to the ring so far. Monotonic for the life of a take;
// the GUI uses this for the timecode and does not need the writer cursor.
jack_session_frames :: proc(s: ^Jack_Session) -> u64 {
	if s == nil {
		return 0
	}
	return sync.atomic_load(&s.write_frame)
}

jack_session_overflow :: proc(s: ^Jack_Session) -> u64 {
	return sync.atomic_load(&s.overflow) if s != nil else 0
}

jack_session_xruns :: proc(s: ^Jack_Session) -> u64 {
	return sync.atomic_load(&s.xruns) if s != nil else 0
}

jack_session_server_lost :: proc(s: ^Jack_Session) -> bool {
	return s != nil && sync.atomic_load(&s.server_down) != 0
}

jack_session_full :: proc(s: ^Jack_Session) -> bool {
	if s == nil || s.max_frames <= 0 {
		return false
	}
	return sync.atomic_load(&s.write_frame) >= u64(s.max_frames)
}

// Linear peak for one channel, for meter display. Not dB so callers can
// reuse the same scaling they use for miniaudio capture.
jack_session_peak :: proc(s: ^Jack_Session, channel: int) -> f32 {
	if s == nil || channel < 0 || channel >= min(s.channels, len(s.peak)) {
		return 0
	}
	return sync.atomic_load(&s.peak[channel])
}

jack_session_connected_ports :: proc(s: ^Jack_Session) -> int {
	return s.connect_count if s != nil else 0
}

jack_session_source_names :: proc(s: ^Jack_Session) -> []string {
	if s == nil {
		return nil
	}
	return s.source_names
}

// Pure validation, so the GUI can reject a request before opening a
// client and so tests can cover it without a server.
jack_session_validate :: proc(channels: int, rate: u32, port_names: []string, max_seconds: f32) -> Jack_Session_Error {
	if channels <= 0 || channels > MAX_JACK_SESSION_CHANNELS {
		return .Bad_Arguments
	}
	if rate != 0 && (rate < JACK_SESSION_MIN_RATE || rate > JACK_SESSION_MAX_RATE) {
		return .Bad_Rate
	}
	if max_seconds != max_seconds || max_seconds < 0 || max_seconds > JACK_SESSION_MAX_SECONDS {
		return .Bad_Arguments
	}
	if len(port_names) > 0 {
		if len(port_names) < channels {
			return .Not_Enough_Ports
		}
		for name in port_names[:channels] {
			if name == "" || len(name) >= 256 {
				return .Bad_Arguments
			}
		}
	}
	return .None
}

// Requested rate 0 means "adopt the server rate"; any other value must
// match, because the engine does not resample a live JACK take.
jack_session_check_rate :: proc(server_rate, requested_rate: u32) -> Jack_Session_Error {
	if server_rate == 0 {
		return .Bad_Rate
	}
	if requested_rate != 0 && requested_rate != server_rate {
		return .Rate_Mismatch
	}
	return .None
}

@(private)
jack_session_stop_requested :: proc(s: ^Jack_Session) -> bool {
	return sync.atomic_load(&s.stop) != 0
}

// Real-time body of the process callback, kept as a normal proc so the
// ring can be tested with synthetic data. Fetches each port buffer once,
// never allocates and never takes a lock.
@(private)
jack_session_push :: proc "contextless" (s: ^Jack_Session, bufs: []^f32, frames: int, port_frames: int) {
	if s == nil || s.ring == nil || s.channels <= 0 || s.cap_frames <= 0 || frames <= 0 {
		return
	}
	write := sync.atomic_load(&s.write_frame)
	read := sync.atomic_load(&s.read_frame)
	if read > write {
		read = write
	}
	capacity := u64(s.cap_frames)
	allowed := frames
	if s.max_frames > 0 {
		if write >= u64(s.max_frames) {
			sync.atomic_add(&s.overflow, u64(frames))
			return
		}
		space := s.max_frames - int(write)
		allowed = min(allowed, space)
	}

	peak_channels := min(s.channels, len(s.peak))
	peaks: [MAX_JACK_SESSION_CHANNELS]f32
	for ch in 0 ..< peak_channels {
		peaks[ch] = sync.atomic_load(&s.peak[ch])
	}

	pushed := 0
	for f in 0 ..< allowed {
		if write - read >= capacity {
			break
		}
		base := int(write % capacity) * s.channels
		for ch in 0 ..< s.channels {
			v: f32 = 0
			if ch < len(bufs) && bufs[ch] != nil && f < port_frames {
				v = (cast([^]f32)bufs[ch])[f]
			}
			idx := base + ch
			if idx < len(s.ring) {
				s.ring[idx] = v
			}
			if ch < peak_channels {
				peaks[ch] = max(peaks[ch] * 0.94, abs(v))
			}
		}
		write += 1
		pushed += 1
	}
	sync.atomic_store(&s.write_frame, write)
	for ch in 0 ..< peak_channels {
		sync.atomic_store(&s.peak[ch], peaks[ch])
	}
	if pushed < frames {
		sync.atomic_add(&s.overflow, u64(frames - pushed))
	}
}

// Copies up to `frames` interleaved frames out of the ring. Used by the
// writer thread and by tests; advances read_frame only after the copy.
@(private)
jack_session_pull :: proc(s: ^Jack_Session, dst: []f32, frames: int) -> int {
	if s == nil || s.ring == nil || s.channels <= 0 || s.cap_frames <= 0 || frames <= 0 {
		return 0
	}
	write := sync.atomic_load(&s.write_frame)
	read := sync.atomic_load(&s.read_frame)
	if read >= write {
		return 0
	}
	avail := write - read
	n := frames
	if u64(n) > avail {
		n = int(avail)
	}
	if n > len(dst) / s.channels {
		n = len(dst) / s.channels
	}
	if n <= 0 {
		return 0
	}
	capacity := u64(s.cap_frames)
	for f in 0 ..< n {
		frame := int((read + u64(f)) % capacity)
		for ch in 0 ..< s.channels {
			dst[f * s.channels + ch] = s.ring[frame * s.channels + ch]
		}
	}
	sync.atomic_store(&s.read_frame, read + u64(n))
	return n
}

@(private)
jack_session_chunk_new :: proc(s: ^Jack_Session, capacity: int) -> ^Jack_Chunk {
	if capacity <= 0 || s == nil || s.channels <= 0 {
		return nil
	}
	// Chunks are allocated by the writer thread and freed by the stopping
	// thread. Use the process heap directly: it is thread-safe and does not
	// inherit a thread-local/arena allocator from the caller.
	chunk, chunk_err := new(Jack_Chunk, runtime.heap_allocator())
	if chunk_err != nil || chunk == nil {
		return nil
	}
	samples, err := make([]f32, capacity * s.channels, runtime.heap_allocator())
	if err != nil || samples == nil {
		free(chunk, runtime.heap_allocator())
		return nil
	}
	chunk.samples = samples
	chunk.capacity = capacity
	return chunk
}

@(private)
jack_session_append_chunk :: proc(s: ^Jack_Session, chunk: ^Jack_Chunk) {
	if s.tail == nil {
		s.chunks = chunk
	} else {
		s.tail.next = chunk
	}
	s.tail = chunk
}

@(private)
jack_session_free_chunks :: proc(s: ^Jack_Session) {
	chunk := s.chunks
	for chunk != nil {
		next := chunk.next
		delete(chunk.samples, runtime.heap_allocator())
		free(chunk, runtime.heap_allocator())
		chunk = next
	}
	s.chunks = nil
	s.tail = nil
}

// Writer thread: drains the ring into 16k-frame chunks. Allocation and
// growth happen here, never in the JACK callback.
@(private)
jack_session_writer :: proc(t: ^thread.Thread) {
	s := cast(^Jack_Session)t.data
	if s == nil || s.channels <= 0 || s.chunk_frames <= 0 {
		if s != nil {
			sync.atomic_store(&s.writer_error, 1)
		}
		return
	}
	for {
		if sync.atomic_load(&s.read_frame) >= sync.atomic_load(&s.write_frame) {
			if jack_session_stop_requested(s) {
				return
			}
			time.sleep(JACK_SESSION_WRITER_POLL)
			continue
		}
		if s.tail == nil || s.tail.frames >= s.tail.capacity {
			chunk := jack_session_chunk_new(s, s.chunk_frames)
			if chunk == nil {
				sync.atomic_store(&s.writer_error, 1)
				return
			}
			jack_session_append_chunk(s, chunk)
		}
		room := s.tail.capacity - s.tail.frames
		got := jack_session_pull(s, s.tail.samples[s.tail.frames * s.channels:], room)
		if got <= 0 {
			if jack_session_stop_requested(s) && sync.atomic_load(&s.read_frame) >= sync.atomic_load(&s.write_frame) {
				return
			}
			time.sleep(JACK_SESSION_WRITER_POLL)
			continue
		}
		s.tail.frames += got
	}
}

@(private)
jack_session_start_writer :: proc(s: ^Jack_Session) -> bool {
	s.writer = thread.create(jack_session_writer)
	if s.writer == nil {
		return false
	}
	s.writer.data = s
	thread.start(s.writer)
	return true
}

@(private)
jack_session_join_writer :: proc(s: ^Jack_Session) {
	if s.writer != nil {
		thread.destroy(s.writer)
		s.writer = nil
	}
}

// Captures anything the writer could not drain (writer error, or a stop
// that raced the last block). Safe and allocation-only outside the RT path.
@(private)
jack_session_absorb_remaining :: proc(s: ^Jack_Session) {
	for {
		write := sync.atomic_load(&s.write_frame)
		read := sync.atomic_load(&s.read_frame)
		if read >= write {
			return
		}
		remaining := int(min(write - read, u64(JACK_SESSION_CHUNK_FRAMES)))
		chunk := jack_session_chunk_new(s, remaining)
		if chunk == nil {
			sync.atomic_store(&s.writer_error, 1)
			return
		}
		got := jack_session_pull(s, chunk.samples, remaining)
		if got <= 0 {
			delete(chunk.samples, runtime.heap_allocator())
			free(chunk, runtime.heap_allocator())
			return
		}
		chunk.frames = got
		jack_session_append_chunk(s, chunk)
	}
}

// ---------------------------------------------------------------- JACK callbacks

jack_session_process :: proc "c" (nframes: u32, arg: rawptr) -> c.int {
	s := cast(^Jack_Session)arg
	if s == nil || nframes == 0 || s.ring == nil || s.channels <= 0 {
		return 0
	}
	if sync.atomic_load(&s.active) == 0 {
		return 0
	}
	if len(s.ports) < s.channels {
		return 0
	}
	bufs: [MAX_JACK_SESSION_CHANNELS]^f32
	channels := min(s.channels, len(bufs))
	for ch in 0 ..< channels {
		bufs[ch] = cast(^f32)jack_port_get_buffer(s.ports[ch], nframes)
	}
	jack_session_push(s, bufs[:channels], int(nframes), int(nframes))
	return 0
}

jack_session_xrun :: proc "c" (arg: rawptr) -> c.int {
	s := cast(^Jack_Session)arg
	if s != nil {
		sync.atomic_add(&s.xruns, 1)
	}
	return 0
}

jack_session_shutdown :: proc "c" (arg: rawptr) {
	s := cast(^Jack_Session)arg
	if s != nil {
		sync.atomic_store(&s.server_down, 1)
		sync.atomic_store(&s.active, 0)
	}
}

// ---------------------------------------------------------------- lifecycle

@(private)
jack_session_release :: proc(s: ^Jack_Session) {
	if s == nil {
		return
	}
	sync.atomic_store(&s.active, 0)
	sync.atomic_store(&s.stop, 1)
	jack_session_join_writer(s)

	// Deactivate/close before releasing the ring or the chunk list, so no
	// late callback can observe freed memory even on a partial start.
	if s.client != nil {
		if s.activated {
			_ = jack_deactivate(s.client)
		}
		_ = jack_client_close(s.client)
		s.client = nil
	}
	s.activated = false
	jack_session_free_chunks(s)
	delete(s.ports)
	s.ports = nil
	s.connect_count = 0
	delete(s.ring)
	s.ring = nil
	s.cap_frames = 0

	if s.client_name != "" {
		delete(s.client_name)
		s.client_name = ""
	}
	for name in s.source_names {
		delete(name)
	}
	delete(s.source_names)
	s.source_names = nil
}

@(private)
jack_session_fail :: proc(s: ^Jack_Session, err: Jack_Session_Error, msg: string) -> bool {
	jack_session_set_detail(s, err, msg)
	jack_session_release(s)
	return false
}

// Opens a client, registers input ports, connects them to the requested
// sources (or the first N physical graph outputs) and starts a non-blocking
// take. `max_seconds == 0` means unbounded; a positive value is a cap.
jack_session_start :: proc(
	s: ^Jack_Session,
	channels: int,
	rate: u32,
	port_names: []string = nil,
	max_seconds: f32 = 0,
) -> bool {
	if s == nil {
		return false
	}
	if s.state == .Running || s.client != nil || s.writer != nil {
		jack_session_set_detail(s, .Already_Running, jack_session_error_string(.Already_Running))
		return false
	}
	jack_session_release(s)
	s.state = .Idle
	s.error = .None
	s.detail_len = 0
	s.detail[0] = 0
	s.channels = channels
	s.requested_rate = rate

	if err := jack_session_validate(channels, rate, port_names, max_seconds); err != .None {
		return jack_session_fail(s, err, jack_session_error_string(err))
	}

	status: u32
	client := jack_client_open(cstring("tracker"), JACK_NO_START_SERVER, &status, rawptr(nil))
	if client == nil {
		buf: [128]u8
		msg := fmt.bprintf(buf[:], "JACK server not available (status 0x%x)", status)
		return jack_session_fail(s, .No_Server, msg)
	}
	s.client = client

	server_rate := jack_get_sample_rate(client)
	s.rate = server_rate
	if err := jack_session_check_rate(server_rate, rate); err != .None {
		buf: [160]u8
		msg := fmt.bprintf(
			buf[:],
			"JACK server runs at %d Hz, requested %d Hz (no resampling yet)",
			server_rate,
			rate,
		)
		return jack_session_fail(s, err, msg)
	}

	client_name := jack_get_client_name(client)
	if client_name == nil {
		return jack_session_fail(s, .No_Server, "JACK client has no name")
	}
	s.client_name = strings.clone_from_cstring(client_name)

	// Resolve the source ports before registering our inputs so the query
	// returns the graph's ports, not our own destinations.
	explicit := len(port_names) > 0
	query: [^]cstring
	query_count := 0
	if explicit {
		query_count = len(port_names)
	} else {
		query = jack_query_capture_ports(client)
		query_count = jack_port_count(query)
	}
	defer {
		if query != nil {
			jack_free(rawptr(query))
		}
	}
	if query_count < channels {
		buf: [160]u8
		msg := fmt.bprintf(
			buf[:],
			"JACK has %d capture port(s) for %d channel(s)",
			query_count,
			channels,
		)
		err := Jack_Session_Error.No_Ports if query_count == 0 else .Not_Enough_Ports
		return jack_session_fail(s, err, msg)
	}

	s.source_names = make([]string, channels)
	if s.source_names == nil {
		return jack_session_fail(s, .Out_Of_Memory, jack_session_error_string(.Out_Of_Memory))
	}
	for i in 0 ..< channels {
		if explicit {
			s.source_names[i] = strings.clone(port_names[i])
		} else {
			s.source_names[i], _ = strings.clone_from_cstring(query[i])
		}
		if s.source_names[i] == "" {
			return jack_session_fail(s, .Bad_Arguments, "empty JACK source port name")
		}
	}

	s.ports = make([]^jack_port_t, channels)
	if s.ports == nil {
		return jack_session_fail(s, .Out_Of_Memory, jack_session_error_string(.Out_Of_Memory))
	}
	port_name_buf: [64]u8
	for i in 0 ..< channels {
		name := fmt.bprintf(port_name_buf[:], "in_%d", i + 1)
		s.ports[i] = jack_port_register(
			client,
			jack_cstring(port_name_buf[:], name),
			cstring(JACK_DEFAULT_AUDIO_TYPE),
			JACK_PORT_IS_INPUT,
			0,
		)
		if s.ports[i] == nil {
			buf: [128]u8
			msg := fmt.bprintf(buf[:], "cannot register JACK input in_%d", i + 1)
			return jack_session_fail(s, .Port_Register_Failed, msg)
		}
	}

	s.max_frames = 0
	if max_seconds > 0 {
		s.max_frames = max(int(max_seconds * f32(server_rate)), 1)
	}
	buffer_frames := int(jack_get_buffer_size(client))
	if buffer_frames <= 0 {
		buffer_frames = 1024
	}
	// Two seconds of headroom, and always several JACK periods so a
	// scheduling hiccup in the writer does not drop a block.
	s.cap_frames = max(int(server_rate) * 2, buffer_frames * 4, 4096)
	s.ring = make([]f32, s.cap_frames * channels)
	if s.ring == nil {
		return jack_session_fail(s, .Out_Of_Memory, jack_session_error_string(.Out_Of_Memory))
	}
	s.write_frame = 0
	s.read_frame = 0
	s.overflow = 0
	s.stop = 0
	s.active = 0
	s.writer_error = 0
	s.xruns = 0
	s.server_down = 0
	s.chunk_frames = JACK_SESSION_CHUNK_FRAMES
	for i in 0 ..< len(s.peak) {
		sync.atomic_store(&s.peak[i], 0)
	}

	if !jack_session_start_writer(s) {
		return jack_session_fail(s, .Out_Of_Memory, "cannot start JACK take writer")
	}

	if jack_set_process_callback(client, jack_session_process, s) != 0 {
		return jack_session_fail(s, .Callback_Failed, jack_session_error_string(.Callback_Failed))
	}
	jack_on_shutdown(client, jack_session_shutdown, s)
	_ = jack_set_xrun_callback(client, jack_session_xrun, s)

	// Connect while the client is still inactive, so the first processed
	// block already has every input routed.
	source_buf: [256]u8
	dest_buf: [256]u8
	for source, i in s.source_names {
		destination := fmt.bprintf(dest_buf[:], "%s:in_%d", s.client_name, i + 1)
		source_c := jack_cstring(source_buf[:], source)
		destination_c := jack_cstring(dest_buf[:], destination)
		if jack_connect(client, source_c, destination_c) != 0 {
			buf: [300]u8
			msg := fmt.bprintf(buf[:], "cannot connect %s -> %s", source, destination)
			return jack_session_fail(s, .Connect_Failed, msg)
		}
		s.connect_count += 1
	}

	sync.atomic_store(&s.active, 1)
	if jack_activate(client) != 0 {
		sync.atomic_store(&s.active, 0)
		return jack_session_fail(s, .Activate_Failed, jack_session_error_string(.Activate_Failed))
	}
	s.activated = true
	s.state = .Running
	return true
}

// Stops a take. Deactivates the JACK client first (no callback can run
// afterwards), drains the ring, joins the writer and returns interleaved
// samples. Safe to call twice: the second call returns no data.
jack_session_stop :: proc(s: ^Jack_Session) -> (Capture_Result, bool) {
	if s == nil {
		return {}, false
	}
	has_capture := s.state == .Running || s.client != nil || s.writer != nil || s.ring != nil
	if !has_capture {
		return {}, false
	}

	sync.atomic_store(&s.active, 0)
	if s.client != nil && s.activated {
		_ = jack_deactivate(s.client)
		s.activated = false
	}

	sync.atomic_store(&s.stop, 1)
	jack_session_join_writer(s)
	jack_session_absorb_remaining(s)
	writer_failed := sync.atomic_load(&s.writer_error) != 0

	total := 0
	for chunk := s.chunks; chunk != nil; chunk = chunk.next {
		total += chunk.frames
	}
	if total <= 0 {
		jack_session_set_detail(s, .No_Frames, "no frames were delivered")
		jack_session_release(s)
		return {}, false
	}

	samples := make([]f32, total * s.channels)
	if samples == nil {
		jack_session_set_detail(s, .Out_Of_Memory, jack_session_error_string(.Out_Of_Memory))
		jack_session_release(s)
		return {}, false
	}
	offset := 0
	for chunk := s.chunks; chunk != nil; chunk = chunk.next {
		count := chunk.frames * s.channels
		copy(samples[offset:offset + count], chunk.samples[:count])
		offset += count
	}

	short := 0
	if s.max_frames > 0 {
		short = max(s.max_frames - total, 0)
	}

	result := Capture_Result {
		samples  = samples,
		channels = s.channels,
		rate     = s.rate,
		frames   = total,
		short    = short,
	}

	if writer_failed {
		jack_session_set_detail(s, .Writer_Failed, "capture writer stopped; kept the delivered prefix")
		s.state = .Stopped
	} else {
		s.error = .None
		s.detail_len = 0
		s.detail[0] = 0
		s.state = .Stopped
	}
	jack_session_release(s)
	return result, true
}

// Stops and discards any take. Safe on an idle/zero session.
jack_session_destroy :: proc(s: ^Jack_Session) {
	if s == nil {
		return
	}
	if s.state == .Running || s.client != nil || s.writer != nil || s.ring != nil {
		result, ok := jack_session_stop(s)
		if ok {
			capture_destroy(&result)
		}
	}
	jack_session_release(s)
	s.state = .Idle
	s.error = .None
	s.detail_len = 0
	s.detail[0] = 0
}
