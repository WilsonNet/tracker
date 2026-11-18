package main

import "core:encoding/endian"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Regression: Odin's thread.create returns a SUSPENDED thread. The writer used
// to be started only by thread.join at stop, which meant the ring filled after
// two seconds and every longer take was truncated. The writer must drain while
// recording is active.
@(test)
recorder_writer_drains_while_running :: proc(t: ^testing.T) {
	path := "/tmp/tracker-writer-drain-test.raw"
	defer os.remove(path)
	raw, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	testing.expect(t, err == nil, "cannot open raw file")
	defer os.close(raw)

	rec: Recorder
	rec.raw = raw
	rec.channels = 1
	rec.cap_frames = 16
	rec.ring = make([]f32, rec.cap_frames)
	defer delete(rec.ring)
	rec.rate = 48_000

	G_RECORDER = &rec
	rec.writer = thread.create(recorder_writer)
	testing.expect(t, rec.writer != nil, "cannot create writer")
	thread.start(rec.writer)

	for i in 0 ..< 16 {
		rec.ring[i] = f32(i) / 16.0
	}
	sync.atomic_store(&rec.write_frame, 16)

	deadline := time.now()
	for sync.atomic_load(&rec.read_frame) < 16 && time.since(deadline) < time.Second {
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, sync.atomic_load(&rec.read_frame) == 16, "writer stalled: read=%d", sync.atomic_load(&rec.read_frame))

	sync.atomic_store(&rec.stop, 1)
	thread.join(rec.writer)
	thread.destroy(rec.writer)
	rec.writer = nil
	G_RECORDER = nil

	data, rerr := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, rerr == nil, "cannot read raw file")
	testing.expectf(t, len(data) == 16 * 4, "raw bytes %d", len(data))
	if len(data) >= 8 {
		first, _ := endian.get_f32(data[0:], .Little)
		last, _ := endian.get_f32(data[60:], .Little)
		testing.expectf(t, abs(first) < 1e-6, "first %v", first)
		testing.expectf(t, abs(last - 15.0 / 16.0) < 1e-6, "last %v", last)
	}
}
