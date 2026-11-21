// Cooperative JACK capture for the Odin engine.
//
// Mirrors src-tauri/src/audio/jack.rs: a temporary client joins the
// PipeWire/JACK graph, connects to the capture ports (the graph's physical
// outputs), and records interleaved float samples into a preallocated buffer.
// Nothing is stolen from other clients — Ardour, browsers and PipeWire keep
// running while tracker records.
//
// Like capture.odin's miniaudio path, the process callback locks a mutex and
// copies into a bounded buffer. That is fine for a bounded CLI take; the
// real-time monitor path needs a lock-free ring before this can run alongside
// a UI.

package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

// Selects the JACK capture ports that belong to one audio device. PipeWire's
// JACK layer names each device's client after the same description miniaudio
// reports ("Scarlett 4i4 USB Analog Surround 5.1"), with ports
// "<client>:capture_FL" etc. in hardware order. Without this filter "the first
// N physical ports" is whatever device the graph happens to list first (a
// webcam or laptop mic), so track input 1 would not be the interface's input 1.
// Returns a new slice of borrowed strings (free with `delete`), or nil when
// `device` is empty or owns no ports.
jack_ports_for_device :: proc(ports: []string, device: string, allocator := context.allocator) -> []string {
	if device == "" {
		return nil
	}
	count := 0
	for p in ports {
		if jack_port_client(p) == device {
			count += 1
		}
	}
	if count == 0 {
		return nil
	}
	out := make([]string, count, allocator)
	n := 0
	for p in ports {
		if jack_port_client(p) == device {
			out[n] = p
			n += 1
		}
	}
	return out
}

// Client part of a full JACK port name ("client:port"). JACK forbids ':' in
// client names, so the first colon is the separator.
jack_port_client :: proc(port: string) -> string {
	idx := strings.index_byte(port, ':')
	if idx < 0 {
		return ""
	}
	return port[:idx]
}

when ODIN_OS == .Linux {
	foreign import jack "system:jack"

	// Opaque JACK handles; only ever used through pointers.
	jack_client_t :: struct {}
	jack_port_t :: struct {}

	// jack_options_t (types.h)
	JACK_NO_START_SERVER :: u32(0x01)

	// JackPortFlags (types.h)
	JACK_PORT_IS_INPUT :: u64(0x1)
	JACK_PORT_IS_OUTPUT :: u64(0x2)
	JACK_PORT_IS_PHYSICAL :: u64(0x4)

	// JACK_DEFAULT_AUDIO_TYPE; jack_default_audio_sample_t is a float.
	JACK_DEFAULT_AUDIO_TYPE :: "32 bit float mono audio"

	Jack_Process_Callback :: proc "c" (nframes: u32, arg: rawptr) -> c.int

	foreign jack {
		jack_client_open          :: proc(client_name: cstring, options: u32, status: ^u32, #c_vararg args: ..any) -> ^jack_client_t ---
		jack_client_close         :: proc(client: ^jack_client_t) -> c.int ---
		jack_get_client_name      :: proc(client: ^jack_client_t) -> cstring ---
		jack_get_sample_rate      :: proc(client: ^jack_client_t) -> u32 ---
		jack_get_ports            :: proc(client: ^jack_client_t, port_name_pattern: cstring, type_name_pattern: cstring, flags: u64) -> [^]cstring ---
		jack_free                 :: proc(ptr: rawptr) ---
		jack_port_register        :: proc(client: ^jack_client_t, port_name: cstring, port_type: cstring, flags: u64, buffer_size: u64) -> ^jack_port_t ---
		jack_port_get_buffer      :: proc(port: ^jack_port_t, nframes: u32) -> rawptr ---
		jack_set_process_callback :: proc(client: ^jack_client_t, callback: Jack_Process_Callback, arg: rawptr) -> c.int ---
		jack_connect              :: proc(client: ^jack_client_t, source_port: cstring, destination_port: cstring) -> c.int ---
		jack_activate             :: proc(client: ^jack_client_t) -> c.int ---
		jack_deactivate           :: proc(client: ^jack_client_t) -> c.int ---
	}

	@(private)
	Jack_Context :: struct {
		state: ^Capture_State,
		ports: []^jack_port_t,
	}

	// Real-time process callback: deinterleave nothing, interleave everything.
	// Writes at most the remaining capacity and never allocates.
	@(private)
	jack_process :: proc "c" (nframes: u32, arg: rawptr) -> c.int {
		ctx := cast(^Jack_Context)arg
		if ctx == nil || ctx.state == nil || len(ctx.ports) == 0 {
			return 0
		}
		state := ctx.state
		frames := int(nframes)

		sync.mutex_lock(&state.lock)
		remaining := state.capacity - state.written
		n := min(frames, remaining)
		if n > 0 {
			channels := state.channels
			for port, channel in ctx.ports {
				buffer := cast([^]f32)jack_port_get_buffer(port, nframes)
				if buffer == nil {
					continue
				}
				for i in 0 ..< n {
					state.buffer[(state.written + i) * channels + channel] = buffer[i]
				}
			}
			state.written += n
		}
		sync.mutex_unlock(&state.lock)
		return 0
	}

	// Copy `s` into `buf` and NUL-terminate it for the C API.
	@(private)
	jack_cstring :: proc(buf: []u8, s: string) -> cstring {
		if len(buf) == 0 {
			return nil
		}
		n := min(len(s), len(buf) - 1)
		for i in 0 ..< n {
			buf[i] = s[i]
		}
		buf[n] = 0
		return cstring(&buf[0])
	}

	@(private)
	jack_port_count :: proc(ports: [^]cstring) -> int {
		if ports == nil {
			return 0
		}
		count := 0
		for ports[count] != nil {
			count += 1
		}
		return count
	}

	// Capture sources: physical output ports. PipeWire marks hardware capture
	// ports physical; if a server does not, fall back to every output so the
	// list is never empty for a running graph.
	@(private)
	jack_query_capture_ports :: proc(client: ^jack_client_t) -> [^]cstring {
		ports := jack_get_ports(
			client,
			nil,
			cstring(JACK_DEFAULT_AUDIO_TYPE),
			JACK_PORT_IS_OUTPUT | JACK_PORT_IS_PHYSICAL,
		)
		if jack_port_count(ports) > 0 {
			return ports
		}
		if ports != nil {
			jack_free(rawptr(ports))
		}
		return jack_get_ports(client, nil, cstring(JACK_DEFAULT_AUDIO_TYPE), JACK_PORT_IS_OUTPUT)
	}

	// True when a JACK server (jackd or PipeWire's JACK layer) accepts clients.
	jack_available :: proc() -> bool {
		status: u32
		client := jack_client_open(cstring("tracker-probe"), JACK_NO_START_SERVER, &status, rawptr(nil))
		if client == nil {
			return false
		}
		jack_client_close(client)
		return true
	}

	// Full names ("client:capture_FL") of every capture port on the graph.
	// Caller frees each string and then the slice: delete(name), delete(names).
	jack_port_names :: proc() -> []string {
		status: u32
		client := jack_client_open(cstring("tracker-probe"), JACK_NO_START_SERVER, &status, rawptr(nil))
		if client == nil {
			return nil
		}
		defer jack_client_close(client)

		ports := jack_query_capture_ports(client)
		if ports == nil {
			return nil
		}
		defer jack_free(rawptr(ports))

		count := jack_port_count(ports)
		names := make([]string, count)
		for i in 0 ..< count {
			name, _ := strings.clone_from_cstring(ports[i])
			names[i] = name
		}
		return names
	}

	// Records `seconds` of interleaved f32 audio from `channels` JACK capture
	// ports. With an empty `port_names`, the first N physical output ports are
	// used. Returns partial data with `short = target - frames` when the graph
	// stops delivering frames.
	jack_record :: proc(seconds: f32, channels: int, rate: u32, port_names: []string) -> (Capture_Result, bool) {
		if seconds <= 0.0 || channels <= 0 || channels > 32 {
			return {}, false
		}
		if seconds > 3_600.0 {
			fmt.eprintln("refusing a take longer than one hour")
			return {}, false
		}

		status: u32
		client := jack_client_open(cstring("tracker"), JACK_NO_START_SERVER, &status, rawptr(nil))
		if client == nil {
			fmt.eprintln("JACK server not available")
			return {}, false
		}
		defer jack_client_close(client)

		jack_rate := jack_get_sample_rate(client)
		if jack_rate != rate {
			fmt.eprintfln(
				"JACK server runs at %d Hz, requested %d Hz (no resampling yet)",
				jack_rate,
				rate,
			)
			return {}, false
		}

		target_frames := int(seconds * f32(jack_rate))
		if target_frames <= 0 {
			return {}, false
		}

		state := Capture_State {
			buffer   = make([]f32, target_frames * channels),
			channels = channels,
			capacity = target_frames,
		}
		defer delete(state.buffer)

		ports := make([]^jack_port_t, channels)
		defer delete(ports)

		port_name_buf: [64]u8
		for i in 0 ..< channels {
			name := fmt.bprintf(port_name_buf[:], "in_%d", i + 1)
			ports[i] = jack_port_register(
				client,
				jack_cstring(port_name_buf[:], name),
				cstring(JACK_DEFAULT_AUDIO_TYPE),
				JACK_PORT_IS_INPUT,
				0,
			)
			if ports[i] == nil {
				fmt.eprintfln("JACK: cannot register port in_%d", i + 1)
				return {}, false
			}
		}

		// Resolve connection sources before connecting; ownership of the JACK
		// port-name array ends here, so copy the names into local buffers.
		source_bufs: [32][256]u8
		sources: [32]cstring
		connect_count := 0
		if len(port_names) > 0 {
			connect_count = min(channels, len(port_names))
			for i in 0 ..< connect_count {
				sources[i] = jack_cstring(source_bufs[i][:], port_names[i])
			}
		} else {
			targets := jack_query_capture_ports(client)
			count := jack_port_count(targets)
			if count == 0 {
				if targets != nil {
					jack_free(rawptr(targets))
				}
				fmt.eprintln("JACK: no capture ports on the graph")
				return {}, false
			}
			connect_count = min(channels, count)
			for i in 0 ..< connect_count {
				sources[i] = jack_cstring(source_bufs[i][:], string(targets[i]))
			}
			jack_free(rawptr(targets))
		}

		client_name := jack_get_client_name(client)
		if client_name == nil {
			fmt.eprintln("JACK: client has no name")
			return {}, false
		}

		dst_name_buf: [256]u8
		destination_buf: [256]u8
		for i in 0 ..< connect_count {
			dst_name := fmt.bprintf(dst_name_buf[:], "%s:in_%d", client_name, i + 1)
			destination := jack_cstring(destination_buf[:], dst_name)
			if jack_connect(client, sources[i], destination) != 0 {
				fmt.eprintfln("JACK: cannot connect %s -> %s", sources[i], destination)
				return {}, false
			}
		}

		ctx := Jack_Context {
			state = &state,
			ports = ports,
		}
		if jack_set_process_callback(client, jack_process, &ctx) != 0 {
			fmt.eprintln("JACK: cannot install process callback")
			return {}, false
		}

		if jack_activate(client) != 0 {
			fmt.eprintln("JACK: cannot activate client")
			return {}, false
		}

		start := time.now()
		last_print := time.Duration(0)
		timeout := time.Duration(f64(seconds + 3.0) * f64(time.Second))
		timed_out := false
		for {
			sync.mutex_lock(&state.lock)
			written := state.written
			sync.mutex_unlock(&state.lock)

			elapsed := time.since(start)
			if written >= target_frames {
				break
			}
			if elapsed > timeout {
				timed_out = true
				break
			}
			if elapsed - last_print >= 250 * time.Millisecond {
				last_print = elapsed
				progress := f32(written) / f32(target_frames)
				fmt.printfln(
					"  recording  %5.1f%%  %4.1f/%4.1f s",
					progress * 100.0,
					f32(written) / f32(jack_rate),
					seconds,
				)
			}
			time.sleep(50 * time.Millisecond)
		}

		// Deactivate *before* reading the buffer. On a timeout the process
		// callback can still be delivering frames; deactivating first (and
		// copying under the same lock) keeps the copy free of races and makes
		// the local `state` safe to leave scope.
		_ = jack_deactivate(client)
		sync.mutex_lock(&state.lock)
		frames := state.written
		out_frames := min(frames, target_frames)
		samples := make([]f32, out_frames * channels)
		copy(samples, state.buffer[:out_frames * channels])
		sync.mutex_unlock(&state.lock)

		if timed_out {
			fmt.eprintfln("JACK: capture timed out, keeping %d of %d frames", out_frames, target_frames)
		}
		if out_frames == 0 {
			delete(samples)
			fmt.eprintln("JACK: no frames were delivered")
			return {}, false
		}

		return Capture_Result {
			samples = samples,
			channels = channels,
			rate = jack_rate,
			frames = out_frames,
			short = target_frames - out_frames,
		}, true
	}
} else {
	// JACK capture is Linux-only; keep the interface available elsewhere.
	jack_available :: proc() -> bool {
		return false
	}

	jack_port_names :: proc() -> []string {
		return nil
	}

	jack_record :: proc(seconds: f32, channels: int, rate: u32, port_names: []string) -> (Capture_Result, bool) {
		return {}, false
	}
}
