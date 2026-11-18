package main

import "core:os"
import "core:testing"

@(test)
recent_add_dedupes_and_caps :: proc(t: ^testing.T) {
	seed := []string{"a", "b", "c"}
	out := recent_add(seed, "b")
	defer recent_free(out)
	testing.expect(t, len(out) == 3, "dedupe length")
	testing.expect(t, out[0] == "b", "recent should move to front")
	testing.expect(t, out[1] == "a" && out[2] == "c", "order")

	many := make([]string, RECENT_LIMIT)
	defer delete(many)
	for i in 0 ..< RECENT_LIMIT {
		many[i] = "p"
	}
	out2 := recent_add(many, "new")
	defer recent_free(out2)
	testing.expectf(t, len(out2) == RECENT_LIMIT, "cap %d", len(out2))
	testing.expect(t, out2[0] == "new", "new first")
}

@(test)
recent_roundtrip :: proc(t: ^testing.T) {
	path := "/tmp/tracker-recent-json-test.json"
	defer os.remove(path)
	projects := []string{"/tmp/one.json", "/tmp/two.json"}
	testing.expect(t, recent_save(path, projects), "save")
	loaded := recent_load(path)
	defer recent_free(loaded)
	testing.expect(t, len(loaded) == 2, "load length")
	testing.expect(t, loaded[0] == "/tmp/one.json" && loaded[1] == "/tmp/two.json", "load content")
}

@(test)
file_dialog_trim :: proc(t: ^testing.T) {
	testing.expect(t, trim_line("  /tmp/a b.json\n") == "/tmp/a b.json", "trim")
	testing.expect(t, trim_line("") == "", "empty")
	testing.expect(t, trim_line("\r\n") == "", "blank")
}
