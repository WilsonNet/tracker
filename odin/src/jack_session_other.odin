#+build !linux
// JACK is Linux-only. Keep a minimal API so non-Linux targets compile the same call sites.
package main

Jack_Session :: struct {
	state:      Jack_Session_State,
	error:      Jack_Session_Error,
	detail:     [256]u8,
	detail_len: int,
	channels:   int,
	rate:       u32,
	max_frames: int,
}

jack_session_detail :: proc(s: ^Jack_Session) -> string { return "" }
jack_session_error :: proc(s: ^Jack_Session) -> Jack_Session_Error { return .No_Server }
jack_session_is_running :: proc(s: ^Jack_Session) -> bool { return false }
jack_session_frames :: proc(s: ^Jack_Session) -> u64 { return 0 }
jack_session_overflow :: proc(s: ^Jack_Session) -> u64 { return 0 }
jack_session_xruns :: proc(s: ^Jack_Session) -> u64 { return 0 }
jack_session_server_lost :: proc(s: ^Jack_Session) -> bool { return false }
jack_session_full :: proc(s: ^Jack_Session) -> bool { return false }
jack_session_peak :: proc(s: ^Jack_Session, channel: int) -> f32 { return 0 }
jack_session_connected_ports :: proc(s: ^Jack_Session) -> int { return 0 }
jack_session_source_names :: proc(s: ^Jack_Session) -> []string { return nil }
jack_session_validate :: proc(channels: int, rate: u32, port_names: []string, max_seconds: f32) -> Jack_Session_Error { return .No_Server }
jack_session_check_rate :: proc(server_rate, requested_rate: u32) -> Jack_Session_Error { return .No_Server }
jack_session_start :: proc(s: ^Jack_Session, channels: int, rate: u32, port_names: []string = nil, max_seconds: f32 = 0) -> bool { return false }
jack_session_stop :: proc(s: ^Jack_Session) -> (Capture_Result, bool) { return {}, false }
jack_session_destroy :: proc(s: ^Jack_Session) {}
