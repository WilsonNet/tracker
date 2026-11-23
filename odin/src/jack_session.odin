// Shared JACK session types and error messages.
//
// Platform implementations live in jack_session_linux.odin and
// jack_session_other.odin.
package main

import "core:time"

MAX_JACK_SESSION_CHANNELS :: 32
JACK_SESSION_CHUNK_FRAMES :: 16_384
JACK_SESSION_WRITER_POLL :: 2 * time.Millisecond
JACK_SESSION_MIN_RATE :: 8_000
JACK_SESSION_MAX_RATE :: 384_000
JACK_SESSION_MAX_SECONDS :: 86_400.0

Jack_Session_State :: enum u8 {
	Idle,
	Running,
	Stopped,
	Failed,
}

Jack_Session_Error :: enum u8 {
	None,
	Bad_Arguments,
	Bad_Rate,
	Not_Enough_Ports,
	Already_Running,
	No_Server,
	Rate_Mismatch,
	No_Ports,
	Port_Register_Failed,
	Connect_Failed,
	Callback_Failed,
	Activate_Failed,
	Out_Of_Memory,
	Writer_Failed,
	No_Frames,
}

jack_session_error_string :: proc(err: Jack_Session_Error) -> string {
	switch err {
	case .None:            return "ok"
	case .Bad_Arguments:   return "invalid session arguments"
	case .Bad_Rate:        return "unsupported sample rate"
	case .Not_Enough_Ports: return "not enough JACK capture ports"
	case .Already_Running: return "a JACK session is already running"
	case .No_Server:       return "JACK server not available"
	case .Rate_Mismatch:   return "JACK server sample rate differs from the requested rate"
	case .No_Ports:        return "no JACK capture ports on the graph"
	case .Port_Register_Failed: return "cannot register JACK input port"
	case .Connect_Failed:  return "cannot connect a JACK capture port"
	case .Callback_Failed: return "cannot install the JACK process callback"
	case .Activate_Failed: return "cannot activate the JACK client"
	case .Out_Of_Memory:   return "out of memory"
	case .Writer_Failed:   return "capture writer stopped"
	case .No_Frames:       return "no frames were delivered"
	}
	return "unknown JACK session error"
}
