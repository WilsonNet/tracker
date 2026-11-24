package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import ui "ui"

@(private)
fake_drive_mutex: sync.Mutex

Fake_Server :: struct {
	pid: int,
	port: int,
}

@(private)
fake_wait_ready :: proc(port: int) -> bool {
	for _ in 0 ..< 120 {
		sock, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(25 * time.Millisecond)
	}
	return false
}

@(private)
fake_start :: proc() -> (server: Fake_Server, ok: bool) {
	reserve, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0}, 1)
	if lerr != nil {
		return server, false
	}
	bound, berr := net.bound_endpoint(reserve)
	net.close(reserve)
	if berr != nil || bound.port <= 0 {
		return server, false
	}
	server.port = bound.port
	source_dir := filepath.dir(#file)
	command := fmt.tprintf("python3 '%s/../tests/cloud/fake_drive.py' %d >/tmp/tracker-fake-drive.log 2>&1 & echo $!", source_dir, server.port)
	state, out, err, exec_err := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", command}}, context.allocator)
	defer delete(out)
	defer delete(err)
	if exec_err != nil || !state.exited || state.exit_code != 0 {
		return server, false
	}
	pid_text := strings.trim_space(string(out))
	pid, pid_ok := strconv.parse_int(pid_text)
	if !pid_ok {
		return server, false
	}
	server.pid = pid
	if !fake_wait_ready(server.port) {
		return server, false
	}
	ok = true
	return
}

@(private)
fake_stop :: proc(server: Fake_Server) {
	if server.pid <= 0 {
		return
	}
	command := fmt.tprintf("kill %d 2>/dev/null || true", server.pid)
	state, out, err, _ := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", command}}, context.allocator)
	delete(out)
	delete(err)
	_ = state
}

@(private)
fake_url :: proc(server: Fake_Server, path: string) -> string {
	return fmt.aprintf("http://127.0.0.1:%d%s", server.port, path)
}

@(private)
fake_post_json :: proc(server: Fake_Server, path, payload: string) -> ([]u8, bool) {
	dir := cloud_temp_dir()
	defer delete(dir)
	body := cloud_write_temp(dir, "fake-body", transmute([]u8)payload)
	if body == "" {
		return nil, false
	}
	defer delete(body)
	defer os.remove(body)
	url := fake_url(server, path)
	defer delete(url)
	res := cloud_curl_request("POST", url, []string{"Content-Type: application/json"}, body_file = body, max_time = 30)
	defer cloud_curl_destroy(&res)
	if !res.ok {
		return nil, false
	}
	out := res.out
	res.out = nil
	return out, true
}

@(private)
fake_get_json :: proc(server: Fake_Server, path: string) -> ([]u8, bool) {
	url := fake_url(server, path)
	defer delete(url)
	res := cloud_curl_request("GET", url, []string{}, max_time = 30)
	defer cloud_curl_destroy(&res)
	if !res.ok {
		return nil, false
	}
	out := res.out
	res.out = nil
	return out, true
}

@(test)
cloud_fake_drive_roundtrip_never_touches_unrelated_files :: proc(t: ^testing.T) {
	sync.mutex_lock(&fake_drive_mutex)
	defer sync.mutex_unlock(&fake_drive_mutex)
	server, sok := fake_start()
	if !sok {
		testing.fail_now(t, "fake Drive server did not start")
	}
	defer fake_stop(server)

	// The curl helper must pass the body file path intact through `@path`;
	// a block-scoped defer that frees the argument early corrupts the request.
	payload := "grant_type=authorization_code&code=abc%2Fdef&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"
	temp_dir := cloud_temp_dir()
	defer delete(temp_dir)
	body_path := cloud_write_temp(temp_dir, "echo-body", transmute([]u8)payload)
	testing.expect(t, body_path != "", "body fixture")
	defer os.remove(body_path)
	defer delete(body_path)
	echo_url := fake_url(server, "/__echo")
	defer delete(echo_url)
	echo := cloud_curl_request(
		"POST", echo_url,
		[]string{"Content-Type: application/x-www-form-urlencoded"},
		body_file = body_path, max_time = 30,
	)
	defer cloud_curl_destroy(&echo)
	testing.expectf(t, echo.ok, "echo request failed: %s", string(echo.err))
	testing.expectf(t, string(echo.out) == payload, "body round-trip: %q", string(echo.out))

	old_api := cloud_api_base
	old_upload := cloud_upload_base
	cloud_api_base = fmt.aprintf("http://127.0.0.1:%d/drive/v3", server.port)
	cloud_upload_base = fmt.aprintf("http://127.0.0.1:%d/upload/drive/v3", server.port)
	defer {
		delete(cloud_api_base)
		delete(cloud_upload_base)
		cloud_api_base = old_api
		cloud_upload_base = old_upload
	}

	base := "/tmp/tracker-fake-drive"
	_ = os.remove_all(base)
	_ = os.make_directory_all(base)
	defer _ = os.remove_all(base)
	session := fmt.tprintf("%s/session", base)
	_ = os.make_directory_all(session)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/project.json", session), `{"name":"Test Project"}`) == nil, "project fixture")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/track1.wav", session), "MARKED") == nil, "audio fixture")

	c := Cloud{}
	cloud_init(&c, "/tmp/tracker-fake-drive/cloud.json")
	defer cloud_destroy(&c)
	c.store.access_token = strings.clone("fake-token")
	c.store.refresh_token = strings.clone("fake-refresh")
	c.store.expires_unix = cloud_now() + 3600
	c.store.folder_name = strings.clone("Studio")

	backup := new(Cloud_Task)
	backup.kind = .Backup
	backup.session_dir = strings.clone(session)
	backup.project_name = strings.clone("Test Project")
	backup.takes = []string{}
	defer {
		delete(backup.session_dir)
		delete(backup.project_name)
		free(backup)
	}
	cloud_job_backup(&c, backup)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))
	testing.expect(t, c.status_len > 0, "backup status")

	token := "fake-token"
	err := ""
	root, root_ok := cloud_drive_root(token, "Studio", &err)
	testing.expect(t, root_ok, err)
	defer delete(root)
	index, index_ok := cloud_index_load(token, root, &err)
	testing.expect(t, index_ok, err)
	defer cloud_index_destroy(&index)
	testing.expect(t, len(index.projects) == 1, "one cloud project")
	entry := index.projects[0]
	testing.expect(t, entry.name == "Test Project", entry.name)

	// Seed an unrelated, same-named file directly into the project folder.
	// It has no Tracker appProperties marker, so Tracker must neither see nor
	// overwrite it.
	seed := strings.concatenate([]string{`{"parent":"`, entry.folder_id, `","name":"track1.wav","content":"INNOCENT"}`})
	defer delete(seed)
	seed_out, seed_ok := fake_post_json(server, "/__innocent", seed)
	testing.expect(t, seed_ok, "seed innocent")
	delete(seed_out)

	// A second backup must not touch the innocent file.
	backup2 := new(Cloud_Task)
	backup2.kind = .Backup
	backup2.session_dir = strings.clone(session)
	backup2.project_name = strings.clone("Test Project")
	backup2.takes = []string{}
	defer {
		delete(backup2.session_dir)
		delete(backup2.project_name)
		free(backup2)
	}
	cloud_job_backup(&c, backup2)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))

	// Restore the marked project. The innocent track1.wav must not replace the
	// marked file and must not be downloaded.
	restore_root := fmt.tprintf("%s/restored", base)
	_ = os.make_directory_all(restore_root)
	restore := new(Cloud_Task)
	restore.kind = .Restore
	restore.project_id = strings.clone(entry.id)
	restore.save_root = strings.clone(restore_root)
	defer {
		delete(restore.project_id)
		delete(restore.save_root)
		free(restore)
	}
	cloud_job_restore(&c, restore)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))
	restored := c.result.restored
	testing.expect(t, restored != "", "restored path")
	if restored != "" {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/track1.wav", restored), context.allocator)
		defer delete(data)
		testing.expect(t, rerr == nil, "restored track")
		if rerr == nil {
			testing.expect(t, string(data) == "MARKED", string(data))
			testing.expect(t, string(data) != "INNOCENT", "innocent file was downloaded")
		}
		testing.expect(t, os.exists(fmt.tprintf("%s/project.json", restored)), "restored project.json")
	}

	all_data, all_ok := fake_get_json(server, "/__all")
	testing.expect(t, all_ok, "list fake files")
	defer delete(all_data)
	if all_ok {
		All :: struct {
			files: []struct {
				id:      string `json:"id"`,
				name:    string `json:"name"`,
				parents: []string `json:"parents"`,
				props:   map[string]string `json:"props"`,
				content: string `json:"content"`,
			} `json:"files"`,
		}
		all: All
		if json.unmarshal(all_data, &all) == nil {
			saw_root := false
			for f in all.files {
				if f.name == "track1.wav" && f.props["tracker"] != "1" {
					testing.expect(t, f.content == "INNOCENT", "innocent file was overwritten")
				}
				if f.name == "Studio" && len(f.parents) == 1 && f.parents[0] == "root" {
					saw_root = true
				}
				if f.name == "Studio" || f.name == "index.json" || f.name == "project.json" {
					testing.expect(t, f.props["tracker"] == "1", "Tracker file lacks the app marker")
				}
			}
			testing.expect(t, saw_root, "configured Drive folder name was not used")
		}
	}

	// Two marked files with the same name must fail loudly instead of letting
	// backup/restore pick one nondeterministically.
	dup_path := fmt.tprintf("%s/track1.wav", session)
	dup_err := ""
	dup_ok, dup_upload_err := cloud_drive_upload(token, dup_path, "track1.wav", entry.folder_id, "", nil)
	testing.expect(t, dup_ok, dup_upload_err)
	_, dup_found := cloud_drive_find(token, entry.folder_id, "track1.wav", false, &dup_err)
	testing.expect(t, !dup_found && strings.contains(dup_err, "multiple Tracker items"), dup_err)

	// A second local project with the same display name must get a new cloud
	// identity and a sibling Drive folder, never overwrite the first project.
	same := fmt.tprintf("%s/same-name", base)
	_ = os.make_directory_all(same)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/project.json", same), `{"name":"Test Project"}`) == nil, "same-name project fixture")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/track1.wav", same), "SAME-NAME") == nil, "same-name audio fixture")
	backup3 := new(Cloud_Task)
	backup3.kind = .Backup
	backup3.session_dir = strings.clone(same)
	backup3.project_name = strings.clone("Test Project")
	backup3.takes = []string{}
	defer {
		delete(backup3.session_dir)
		delete(backup3.project_name)
		free(backup3)
	}
	cloud_job_backup(&c, backup3)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))
	index2, index2_ok := cloud_index_load(token, root, &err)
	testing.expect(t, index2_ok, err)
	defer cloud_index_destroy(&index2)
	testing.expect(t, len(index2.projects) == 2, "same display name must create a second cloud project")
	if len(index2.projects) == 2 {
		testing.expect(t, index2.projects[0].name == "Test Project", index2.projects[0].name)
		testing.expect(t, index2.projects[1].name == "Test Project", index2.projects[1].name)
		testing.expect(t, index2.projects[0].id != index2.projects[1].id, "cloud ids must differ")
		testing.expect(t, index2.projects[0].folder_id != index2.projects[1].folder_id, "project folders must differ")
	}

	stats_data, stats_ok := fake_get_json(server, "/__stats")
	testing.expect(t, stats_ok, "stats")
	defer delete(stats_data)
	if stats_ok {
		Stats :: struct { deletes: int `json:"deletes"` }
		stats: Stats
		if json.unmarshal(stats_data, &stats) == nil {
			testing.expect(t, stats.deletes == 0, "client issued a remote DELETE")
		}
	}
}

@(test)
cloud_fake_drive_rename_reuses_folder_and_updates_index :: proc(t: ^testing.T) {
	sync.mutex_lock(&fake_drive_mutex)
	defer sync.mutex_unlock(&fake_drive_mutex)
	server, sok := fake_start()
	if !sok {
		testing.fail_now(t, "fake Drive server did not start")
	}
	defer fake_stop(server)

	old_api := cloud_api_base
	old_upload := cloud_upload_base
	cloud_api_base = fmt.aprintf("http://127.0.0.1:%d/drive/v3", server.port)
	cloud_upload_base = fmt.aprintf("http://127.0.0.1:%d/upload/drive/v3", server.port)
	defer {
		delete(cloud_api_base)
		delete(cloud_upload_base)
		cloud_api_base = old_api
		cloud_upload_base = old_upload
	}

	base := "/tmp/tracker-fake-drive-rename"
	_ = os.remove_all(base)
	_ = os.make_directory_all(base)
	defer _ = os.remove_all(base)
	session := fmt.tprintf("%s/session", base)
	_ = os.make_directory_all(session)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/project.json", session), `{"version":1,"name":"untitled"}`) == nil, "initial project fixture")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/track1.wav", session), "AUDIO") == nil, "audio fixture")

	c := Cloud{}
	cloud_init(&c, fmt.tprintf("%s/cloud.json", base))
	defer cloud_destroy(&c)
	c.store.access_token = strings.clone("fake-token")
	c.store.refresh_token = strings.clone("fake-refresh")
	c.store.expires_unix = cloud_now() + 3600
	c.store.folder_name = strings.clone("Studio")

	b1 := new(Cloud_Task)
	b1.kind = .Backup
	b1.session_dir = strings.clone(session)
	b1.project_name = strings.clone("untitled")
	b1.takes = []string{}
	defer {
		delete(b1.session_dir)
		delete(b1.project_name)
		free(b1)
	}
	cloud_job_backup(&c, b1)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))

	token := "fake-token"
	err := ""
	root, root_ok := cloud_drive_root(token, "Studio", &err)
	testing.expect(t, root_ok, err)
	defer delete(root)
	idx1, idx1_ok := cloud_index_load(token, root, &err)
	testing.expect(t, idx1_ok, err)
	defer cloud_index_destroy(&idx1)
	testing.expect(t, len(idx1.projects) == 1, "one cloud project after first backup")
	first_folder_id := strings.clone(idx1.projects[0].folder_id)
	defer delete(first_folder_id)

	// Rename locally and back up again: same Drive folder ID must be renamed in place.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/project.json", session), `{"version":1,"name":"Midnight Tape"}`) == nil, "renamed project fixture")
	b2 := new(Cloud_Task)
	b2.kind = .Backup
	b2.session_dir = strings.clone(session)
	b2.project_name = strings.clone("Midnight Tape")
	b2.takes = []string{}
	defer {
		delete(b2.session_dir)
		delete(b2.project_name)
		free(b2)
	}
	cloud_job_backup(&c, b2)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))

	idx2, idx2_ok := cloud_index_load(token, root, &err)
	testing.expect(t, idx2_ok, err)
	defer cloud_index_destroy(&idx2)
	testing.expect(t, len(idx2.projects) == 1, "rename must update existing cloud entry")
	testing.expect(t, idx2.projects[0].name == "Midnight Tape", idx2.projects[0].name)
	testing.expect(t, idx2.projects[0].folder_id == first_folder_id, "folder_id reused in place")

	all_data, all_ok := fake_get_json(server, "/__all")
	testing.expect(t, all_ok, "list fake files")
	defer delete(all_data)
	if all_ok {
		All :: struct {
			files: []struct {
				id:   string `json:"id"`,
				name: string `json:"name"`,
			} `json:"files"`,
		}
		all: All
		if json.unmarshal(all_data, &all) == nil {
			untitled_folders := 0
			renamed_folders := 0
			for f in all.files {
				if strings.has_prefix(f.name, "untitled-") {
					untitled_folders += 1
				}
				if f.id == first_folder_id && strings.has_prefix(f.name, "Midnight-Tape-") {
					renamed_folders += 1
				}
			}
			testing.expect(t, untitled_folders == 0, "no orphaned untitled folder left behind")
			testing.expect(t, renamed_folders == 1, "folder renamed to Midnight-Tape-<id>")
		}
	}

	restore_root := fmt.tprintf("%s/restored", base)
	_ = os.make_directory_all(restore_root)
	restore := new(Cloud_Task)
	restore.kind = .Restore
	restore.project_id = strings.clone(idx2.projects[0].id)
	restore.save_root = strings.clone(restore_root)
	defer {
		delete(restore.project_id)
		delete(restore.save_root)
		free(restore)
	}
	cloud_job_restore(&c, restore)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))
	if c.result.restored != "" {
		pdata, perr := os.read_entire_file(fmt.tprintf("%s/project.json", c.result.restored), context.allocator)
		defer delete(pdata)
		testing.expect(t, perr == nil && strings.contains(string(pdata), `"Midnight Tape"`), "restored project.json has new title")
	}

	stats_data, stats_ok := fake_get_json(server, "/__stats")
	testing.expect(t, stats_ok, "stats")
	defer delete(stats_data)
	if stats_ok {
		Stats :: struct { deletes: int `json:"deletes"` }
		stats: Stats
		if json.unmarshal(stats_data, &stats) == nil {
			testing.expect(t, stats.deletes == 0, "client issued a remote DELETE")
		}
	}
}

// A renamed, many-track project with a bounce take must survive backup and
// restore: names, track count and every trackN / take file.
@(test)
cloud_fake_drive_roundtrips_renamed_many_track_project :: proc(t: ^testing.T) {
	sync.mutex_lock(&fake_drive_mutex)
	defer sync.mutex_unlock(&fake_drive_mutex)
	server, sok := fake_start()
	if !sok {
		testing.fail_now(t, "fake Drive server did not start")
	}
	defer fake_stop(server)

	old_api := cloud_api_base
	old_upload := cloud_upload_base
	cloud_api_base = fmt.aprintf("http://127.0.0.1:%d/drive/v3", server.port)
	cloud_upload_base = fmt.aprintf("http://127.0.0.1:%d/upload/drive/v3", server.port)
	defer {
		delete(cloud_api_base)
		delete(cloud_upload_base)
		cloud_api_base = old_api
		cloud_upload_base = old_upload
	}

	base := "/tmp/tracker-fake-drive-tracks"
	_ = os.remove_all(base)
	_ = os.make_directory_all(base)
	defer _ = os.remove_all(base)
	session := fmt.tprintf("%s/session", base)
	_ = os.make_directory_all(session)

	// Build the project through the real model: 9 tracks, three renamed
	// (one with a non-ASCII name), audio on tracks 1, 7 and 9.
	src: ui.App
	ui.app_init(&src, 1180, 760)
	defer ui.app_destroy(&src)
	ui.app_set_track_count(&src, 9)
	names := [3]string{"Lead Gtr", "Kick — close", "Överheads"}
	picks := [3]int{0, 6, 8}
	for pick, k in picks {
		src.selected = pick
		testing.expect(t, ui.app_track_begin_edit(&src, pick), "begin rename")
		ui.app_paste_text(&src, names[k])
		testing.expect(t, ui.app_track_commit_edit(&src), "commit rename")
		src.tracks[pick].has_audio = true
	}
	ui.app_set_takes(&src, 8, 2, 2)
	testing.expect(t, project_save(&src, fmt.tprintf("%s/project.json", session)), "save project")
	files := [4]string{"track1.wav", "track7.wav", "track9.wav", "track9-take1.wav"}
	for f in files {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", session, f), fmt.tprintf("AUDIO:%s", f)) == nil, "audio fixture")
	}

	c := Cloud{}
	cloud_init(&c, fmt.tprintf("%s/cloud.json", base))
	defer cloud_destroy(&c)
	c.store.access_token = strings.clone("fake-token")
	c.store.refresh_token = strings.clone("fake-refresh")
	c.store.expires_unix = cloud_now() + 3600
	c.store.folder_name = strings.clone("Studio")

	backup := new(Cloud_Task)
	backup.kind = .Backup
	backup.session_dir = strings.clone(session)
	backup.project_name = strings.clone("Many Tracks")
	backup.takes = []string{"track9-take1.wav"}
	defer {
		delete(backup.session_dir)
		delete(backup.project_name)
		free(backup)
	}
	cloud_job_backup(&c, backup)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))

	token := "fake-token"
	err := ""
	root, root_ok := cloud_drive_root(token, "Studio", &err)
	testing.expect(t, root_ok, err)
	defer delete(root)
	index, index_ok := cloud_index_load(token, root, &err)
	testing.expect(t, index_ok, err)
	defer cloud_index_destroy(&index)
	testing.expect(t, len(index.projects) == 1, "one cloud project")
	if len(index.projects) != 1 {
		return
	}

	restore_root := fmt.tprintf("%s/restored", base)
	_ = os.make_directory_all(restore_root)
	restore := new(Cloud_Task)
	restore.kind = .Restore
	restore.project_id = strings.clone(index.projects[0].id)
	restore.save_root = strings.clone(restore_root)
	defer {
		delete(restore.project_id)
		delete(restore.save_root)
		free(restore)
	}
	cloud_job_restore(&c, restore)
	testing.expect(t, c.error_len == 0, string(c.error_buf[:c.error_len]))
	restored := c.result.restored
	testing.expect(t, restored != "", "restored path")
	if restored == "" {
		return
	}
	for f in files {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", restored, f), context.allocator)
		defer delete(data)
		testing.expectf(t, rerr == nil, "restored %s", f)
		if rerr == nil {
			testing.expectf(t, string(data) == fmt.tprintf("AUDIO:%s", f), "%s content: %s", f, string(data))
		}
	}

	// Open the restored project the way the app does.
	dst: ui.App
	ui.app_init(&dst, 1180, 760)
	defer ui.app_destroy(&dst)
	testing.expect(t, project_load(&dst, restored, fmt.tprintf("%s/project.json", restored)), "load restored project")
	testing.expectf(t, dst.track_count == 9, "track count %d", dst.track_count)
	for pick, k in picks {
		testing.expectf(t, dst.tracks[pick].name == names[k], "track %d name %q", pick + 1, dst.tracks[pick].name)
		testing.expectf(t, dst.tracks[pick].has_audio, "track %d has audio", pick + 1)
	}
	testing.expect(t, dst.tracks[1].name == "Track 2" && !dst.tracks[1].has_audio, "untouched track stays default and empty")

	// the rename survives a second backup of the restored copy (same cloud id)
	stats_data, stats_ok := fake_get_json(server, "/__stats")
	testing.expect(t, stats_ok, "stats")
	defer delete(stats_data)
	if stats_ok {
		Stats :: struct { deletes: int `json:"deletes"` }
		stats: Stats
		if json.unmarshal(stats_data, &stats) == nil {
			testing.expect(t, stats.deletes == 0, "client issued a remote DELETE")
		}
	}
}
