#+build !linux
// JACK capture is Linux-only; keep the interface available elsewhere.
package main

jack_available :: proc() -> bool {
	return false
}

jack_port_names :: proc() -> []string {
	return nil
}

jack_record :: proc(seconds: f32, channels: int, rate: u32, port_names: []string) -> (Capture_Result, bool) {
	return {}, false
}
