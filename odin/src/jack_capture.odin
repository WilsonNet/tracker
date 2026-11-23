// Shared JACK port-name helpers. Platform capture implementations live in
// jack_capture_linux.odin and jack_capture_other.odin.
package main

import "core:strings"

// Selects the JACK capture ports that belong to one audio device. PipeWire's
// JACK layer names each device's client after the same description miniaudio
// reports ("Scarlett 4i4 USB Analog Surround 5.1"), with ports
// "<client>:capture_FL" etc. in hardware order.
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
