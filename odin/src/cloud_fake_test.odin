package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

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
