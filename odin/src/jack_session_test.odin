// Tests for the asynchronous JACK session.
//
// The lifecycle tests are deliberately server-free: they exercise argument
// validation, the lock-free ring, the chunk writer, the stop/drain path and
// double-stop safety with synthetic frames. The live take is opt-in:
//
//   TRACKER_JACK_LIVE=1 odin test src \
//     -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lSDL2"

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import dsp "dsp"

when ODIN_OS == .Linux {
	@(test)
	jack_session_validate_rejects_bad_requests :: proc(t: ^testing.T) {
		testing.expectf(t, jack_session_validate(0, 48_000, nil, 0) == .Bad_Arguments, "zero channels")
		testing.expectf(t, jack_session_validate(33, 48_000, nil, 0) == .Bad_Arguments, "33 channels")
		testing.expectf(t, jack_session_validate(2, 48_000, nil, 0) == .None, "valid request")
		testing.expectf(t, jack_session_validate(2, 0, nil, 0) == .None, "zero rate adopts the server")
		testing.expectf(t, jack_session_validate(2, 7999, nil, 0) == .Bad_Rate, "low rate")
		testing.expectf(t, jack_session_validate(2, 384_001, nil, 0) == .Bad_Rate, "high rate")
		testing.expectf(t, jack_session_validate(2, 48_000, nil, -1) == .Bad_Arguments, "negative cap")
		testing.expectf(t, jack_session_validate(2, 48_000, nil, 86_401) == .Bad_Arguments, "cap above one day")
		testing.expectf(t, jack_session_validate(2, 48_000, nil, math.QNAN_F32) == .Bad_Arguments, "NaN cap")

		one := []string{"system:capture_1"}
		testing.expectf(t, jack_session_validate(2, 48_000, one, 0) == .Not_Enough_Ports, "one name for two channels")
		two := []string{"system:capture_1", "system:capture_2"}
		testing.expectf(t, jack_session_validate(2, 48_000, two, 0) == .None, "two names")
		empty := []string{"system:capture_1", ""}
		testing.expectf(t, jack_session_validate(2, 48_000, empty, 0) == .Bad_Arguments, "empty name")
	}

	@(test)
	jack_session_rejects_rate_mismatch_clearly :: proc(t: ^testing.T) {
		testing.expectf(t, jack_session_check_rate(48_000, 48_000) == .None, "matching rate")
		testing.expectf(t, jack_session_check_rate(48_000, 0) == .None, "adopt rate")
		testing.expectf(t, jack_session_check_rate(48_000, 44_100) == .Rate_Mismatch, "mismatch")
		testing.expectf(t, jack_session_check_rate(0, 48_000) == .Bad_Rate, "server rate unknown")
	}

	// Prepares a session's ring without a JACK client. This is the same state
	// `jack_session_start` creates after resolving the server format.
	@(private)
	jack_session_test_ring :: proc(s: ^Jack_Session, channels, cap_frames: int) {
		s.channels = channels
		s.rate = 48_000
		s.cap_frames = cap_frames
		s.ring = make([]f32, cap_frames * channels)
		s.chunk_frames = 32
		s.state = .Idle
	}

	@(test)
	jack_session_ring_is_bounded_and_preserves_order :: proc(t: ^testing.T) {
		s: Jack_Session
		jack_session_test_ring(&s, 2, 4)
		defer delete(s.ring)

		src := [12]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
		bufs := [2]^f32{&src[0], &src[1]}
		// Push 6 frames from two independent per-channel buffers.
		l := [6]f32{1, 3, 5, 7, 9, 11}
		r := [6]f32{2, 4, 6, 8, 10, 12}
		jack_session_push(&s, {&l[0], &r[0]}, 6, 6)

		testing.expectf(t, sync.atomic_load(&s.write_frame) == 4, "write %d", sync.atomic_load(&s.write_frame))
		testing.expectf(t, sync.atomic_load(&s.overflow) == 2, "overflow %d", sync.atomic_load(&s.overflow))
		testing.expectf(t, s.ring[0] == 1 && s.ring[1] == 2 && s.ring[7] == 8, "first block")

		out: [4]f32
		n := jack_session_pull(&s, out[:], 2)
		testing.expectf(t, n == 2, "pull %d", n)
		testing.expectf(t, out[0] == 1 && out[1] == 2 && out[2] == 3 && out[3] == 4, "pulled order")
		testing.expectf(t, sync.atomic_load(&s.read_frame) == 2, "read cursor")

		// The reader caught up; a new push wraps to the start of the ring.
		jack_session_push(&s, {&l[0], &r[0]}, 2, 2)
		testing.expectf(t, s.ring[0] == 1 && s.ring[1] == 2, "wrap")
		testing.expectf(t, sync.atomic_load(&s.overflow) == 2, "no extra drops")

		// Nil ring and unknown channels are harmless in the RT path.
		bad: Jack_Session
		jack_session_push(&bad, bufs[:], 1, 1)
		testing.expectf(t, sync.atomic_load(&bad.write_frame) == 0, "nil ring accepted")

		// A bounded take stops accepting at max_frames and counts the rest.
		limited: Jack_Session
		jack_session_test_ring(&limited, 1, 8)
		defer delete(limited.ring)
		limited.max_frames = 3
		mono := [5]f32{1, 2, 3, 4, 5}
		jack_session_push(&limited, {&mono[0]}, 5, 5)
		testing.expectf(t, sync.atomic_load(&limited.write_frame) == 3, "cap write %d", sync.atomic_load(&limited.write_frame))
		testing.expectf(t, sync.atomic_load(&limited.overflow) == 2, "cap overflow %d", sync.atomic_load(&limited.overflow))
		testing.expectf(t, jack_session_full(&limited), "max_seconds cap should report full")
	}

	// Runs the real writer thread, chunks and collect path with no server.
	@(test)
	jack_session_writer_drains_indefinitely_without_blocking :: proc(t: ^testing.T) {
		s: Jack_Session
		jack_session_test_ring(&s, 2, 4096)
		defer jack_session_release(&s)
		testing.expect(t, jack_session_start_writer(&s), "writer start")

		left: [64]f32
		right: [64]f32
		for i in 0 ..< 64 {
			left[i] = f32(i * 2 + 1) * 0.001
			right[i] = f32(i * 2 + 2) * 0.001
		}
		bufs := [2]^f32{&left[0], &right[0]}
		const_blocks := 12
		for _ in 0 ..< const_blocks {
			jack_session_push(&s, bufs[:], 64, 64)
			// Spin briefly so the writer keeps pace instead of forcing the ring
			// to drop frames; the ring is deliberately larger than one block.
			for _ in 0 ..< 200 {
				if sync.atomic_load(&s.read_frame) + 64 > sync.atomic_load(&s.write_frame) {
					break
				}
				time.sleep(time.Millisecond)
			}
		}

		// Stop in the production order: no client here, so just signal and
		// join. The writer must drain all 768 frames left in the ring.
		sync.atomic_store(&s.stop, 1)
		jack_session_join_writer(&s)
		jack_session_absorb_remaining(&s)
		testing.expectf(t, sync.atomic_load(&s.overflow) == 0, "overflow %d", sync.atomic_load(&s.overflow))

		total := 0
		for chunk := s.chunks; chunk != nil; chunk = chunk.next {
			total += chunk.frames
		}
		testing.expectf(t, total == const_blocks * 64, "chunk frames %d", total)

		result, ok := jack_session_stop(&s)
		testing.expect(t, ok, "stop/collect")
		defer capture_destroy(&result)
		testing.expectf(t, result.frames == const_blocks * 64, "result frames %d", result.frames)
		testing.expectf(t, result.channels == 2 && result.rate == 48_000, "result format")
		if result.frames == const_blocks * 64 {
			for f in 0 ..< 4 {
				for ch in 0 ..< 2 {
					expected := f32((f % 64) * 2 + ch + 1) * 0.001
					got := result.samples[f * 2 + ch]
					testing.expectf(t, abs(got - expected) < 1e-7, "sample %d/%d %v != %v", f, ch, got, expected)
				}
			}
		}

		// A second stop must be a clean no-op, not a crash or duplicate take.
		again, ok_again := jack_session_stop(&s)
		testing.expect(t, !ok_again && again.samples == nil, "double stop returned data")
		testing.expectf(t, s.state == .Stopped, "state %v", s.state)
	}

	@(test)
	jack_session_stop_handles_idle_and_partial_sessions :: proc(t: ^testing.T) {
		idle: Jack_Session
		result, ok := jack_session_stop(&idle)
		testing.expect(t, !ok && result.samples == nil, "idle stop")
		jack_session_destroy(&idle)
		testing.expectf(t, idle.state == .Idle, "destroy state %v", idle.state)

		// A session that failed before any frame was delivered must report the
		// failure and leave nothing behind.
		failed: Jack_Session
		jack_session_test_ring(&failed, 1, 16)
		testing.expect(t, jack_session_start_writer(&failed), "writer")
		sync.atomic_store(&failed.stop, 1)
		failed.state = .Running
		empty, empty_ok := jack_session_stop(&failed)
		testing.expect(t, !empty_ok && empty.samples == nil, "empty take")
		testing.expectf(t, failed.error == .No_Frames, "error %v", failed.error)
		testing.expect(t, failed.ring == nil && failed.writer == nil, "empty take cleanup")

		// Starting with invalid arguments fails before opening a client.
		bad: Jack_Session
		testing.expect(t, !jack_session_start(&bad, 0, 48_000), "invalid start")
		testing.expectf(t, bad.state == .Failed && bad.error == .Bad_Arguments, "bad state %v/%v", bad.state, bad.error)
		testing.expectf(t, jack_session_detail(&bad) != "", "no error detail")
		jack_session_destroy(&bad)
	}

	// Opt-in hardware check: one second of real graph output. Skipped during
	// normal test runs so `make test` never depends on an audio server.
	@(test)
	jack_session_live_one_second_take :: proc(t: ^testing.T) {
		live := os.get_env("TRACKER_JACK_LIVE", context.allocator)
		defer delete(live)
		if live != "1" {
			return
		}
		if !jack_available() {
			fmt.println("jack live: skipped, no JACK/PipeWire server")
			return
		}

		s: Jack_Session
		defer jack_session_destroy(&s)
		testing.expect(t, jack_session_start(&s, 2, 48_000), "start live take")
		if s.state != .Running {
			fmt.printfln("jack live: start failed: %s", jack_session_detail(&s))
			return
		}
		fmt.printfln("jack live: connected %d port(s) at %d Hz via %s", jack_session_connected_ports(&s), s.rate, s.client_name)
		// Wait for a full second of delivered frames rather than sleeping a
		// wall-clock second: JACK's period granularity otherwise stops at 0.96 s.
		deadline := time.now()
		for jack_session_frames(&s) < u64(s.rate) {
			if time.since(deadline) > 3 * time.Second {
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		result, ok := jack_session_stop(&s)
		testing.expect(t, ok, "stop live take")
		if !ok {
			fmt.printfln("jack live: stop failed: %s", jack_session_detail(&s))
			return
		}
		defer capture_destroy(&result)
		peak, rms := dsp.peak_rms_db(result.samples, result.channels)
		fmt.printfln(
			"jack live: %d frames / %.3f s @ %d Hz, %d ch, peak %.2f dBFS, rms %.2f dBFS, overflow %d, xruns %d",
			result.frames,
			f32(result.frames) / f32(result.rate),
			result.rate,
			result.channels,
			peak,
			rms,
			jack_session_overflow(&s),
			jack_session_xruns(&s),
		)
		testing.expectf(t, result.frames >= int(f32(result.rate) * 0.90), "only %d frames", result.frames)

		// A real server must reject the wrong project rate before capture starts.
		wrong := u32(44_100) if result.rate != 44_100 else 48_000
		mismatch: Jack_Session
		testing.expect(t, !jack_session_start(&mismatch, 2, wrong), "wrong rate accepted")
		testing.expectf(t, mismatch.error == .Rate_Mismatch, "rate error %v", mismatch.error)
		fmt.printfln("jack live: rate mismatch detail: %s", jack_session_detail(&mismatch))
		jack_session_destroy(&mismatch)
	}
}
