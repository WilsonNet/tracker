// Delete a track and everything recorded on it.
//
// Nothing is erased: the track's WAV files move into `<project>/deleted/`
// (renamed on a collision), so a mistaken delete can be recovered by hand.
// Later tracks shift up one slot, which means their `trackN.wav` /
// `trackN-takeK.wav` files are renamed and the take lists follow.

package main

import "core:fmt"
import "core:os"
import "core:strings"

import ui "ui"

// "track5-take2.wav" with from=5,to=4 -> "track4-take2.wav"; names that do not
// carry the prefix are returned as an owned copy unchanged.
@(private)
track_file_renumber :: proc(file: string, from, to: int) -> string {
	prefix := fmt.tprintf("track%d", from)
	if strings.has_prefix(file, prefix) {
		rest := file[len(prefix):]
		// "track1" must not match "track12.wav"
		if len(rest) == 0 || rest[0] < '0' || rest[0] > '9' {
			return fmt.aprintf("track%d%s", to, rest)
		}
	}
	return strings.clone(file)
}

@(private)
trash_file :: proc(e: ^Engine, name: string) {
	src := fmt.tprintf("%s/%s", e.session_dir, name)
	if !os.exists(src) {
		return
	}
	dir := fmt.tprintf("%s/deleted", e.session_dir)
	_ = os.make_directory(dir)
	dst := fmt.tprintf("%s/%s", dir, name)
	for k := 2; os.exists(dst); k += 1 {
		dst = fmt.tprintf("%s/%d-%s", dir, k, name)
	}
	_ = os.rename(src, dst)
}

engine_delete_track :: proc(e: ^Engine, a: ^ui.App, idx: int) -> (ok: bool, message: string) {
	if e.rec.active || e.play.active {
		return false, "stop the tape to delete a track"
	}
	if idx < 0 || idx >= a.track_count {
		return false, "choose a track to delete"
	}
	if e.session_dir == "" {
		return false, "no project folder"
	}
	strip := a.track_count > ui.MIN_TRACKS
	if !strip && !(a.tracks[idx].has_audio || e.loaded[idx] != nil || engine_take_count(e, idx) > 0) {
		return false, "4 tracks is the minimum"
	}
	engine_takes_ensure(e)
	had_audio := a.tracks[idx].has_audio || e.loaded[idx] != nil || len(e.takes[idx].takes) > 0 ||
		os.exists(fmt.tprintf("%s/track%d.wav", e.session_dir, idx + 1))

	// 1. the doomed track's files go to deleted/
	trash_file(e, fmt.tprintf("track%d.wav", idx + 1))
	for take in e.takes[idx].takes {
		trash_file(e, take.file)
	}
	take_list_clear(&e.takes[idx])
	delete(e.loaded[idx])
	e.loaded[idx] = nil
	e.loaded_rate[idx] = 0

	// 2. later tracks move up: files, take lists, loaded audio
	if strip {
		last := a.track_count - 1
		for j in idx + 1 ..= last {
			from := j + 1 // 1-based numbers in file names
			to := j
			canonical_old := fmt.tprintf("track%d.wav", from)
			canonical_new := fmt.tprintf("track%d.wav", to)
			if os.exists(fmt.tprintf("%s/%s", e.session_dir, canonical_old)) {
				_ = os.rename(fmt.tprintf("%s/%s", e.session_dir, canonical_old), fmt.tprintf("%s/%s", e.session_dir, canonical_new))
			}
			for &take in e.takes[j].takes {
				if take.file != canonical_old {
					old_path := fmt.tprintf("%s/%s", e.session_dir, take.file)
					renamed := track_file_renumber(take.file, from, to)
					if os.exists(old_path) {
						_ = os.rename(old_path, fmt.tprintf("%s/%s", e.session_dir, renamed))
					}
					delete(take.file)
					take.file = renamed
				} else {
					delete(take.file)
					take.file = strings.clone(canonical_new)
				}
			}
			e.takes[j - 1] = e.takes[j]
			e.loaded[j - 1] = e.loaded[j]
			e.loaded_rate[j - 1] = e.loaded_rate[j]
		}
		e.takes[last] = {}
		e.loaded[last] = nil
		e.loaded_rate[last] = 0
	}

	name := a.tracks[idx].name
	label := fmt.tprintf("%02d %s", idx + 1, name)
	ui.app_track_delete_apply(a, idx, strip)
	if !had_audio {
		return true, fmt.tprintf("track %s deleted", label)
	}
	return true, fmt.tprintf("track %s deleted · audio kept in deleted/", label)
}
