package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
cloud_store_roundtrip_is_private :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-odin-cloud-store"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)
	path := "/tmp/tracker-odin-cloud-store/cloud.json"

	store := Cloud_Store {
		version = CLOUD_VERSION,
		client_id = strings.clone("client"),
		client_secret = strings.clone("secret"),
		access_token = strings.clone("access"),
		refresh_token = strings.clone("refresh"),
		expires_unix = 1234,
		last_sync = 5678,
	}
	testing.expect(t, cloud_store_save(path, &store), "save")
	cloud_store_destroy(&store)

	loaded, ok := cloud_store_load(path)
	defer cloud_store_destroy(&loaded)
	testing.expect(t, ok, "load")
	testing.expect(t, loaded.client_id == "client", "client id")
	testing.expect(t, loaded.refresh_token == "refresh", "refresh token")
	testing.expect(t, loaded.expires_unix == 1234, "expiry")

	info, stat_err := os.stat(path, context.allocator)
	defer os.file_info_delete(info, context.allocator)
	testing.expect(t, stat_err == nil, "stat")
	testing.expect(t, info.mode == os.Permissions{.Read_User, .Write_User}, "cloud.json must be 0600")
}

@(test)
cloud_pkce_and_url_are_well_formed :: proc(t: ^testing.T) {
	verifier, challenge := cloud_pkce()
	defer delete(verifier)
	defer delete(challenge)
	testing.expectf(t, len(verifier) == 43, "verifier length %d", len(verifier))
	testing.expectf(t, len(challenge) == 43, "challenge length %d", len(challenge))
	testing.expect(t, !strings.contains(verifier, "="), "verifier is unpadded")
	testing.expect(t, !strings.contains(challenge, "="), "challenge is unpadded")

	url := cloud_oauth_url("id with space", "http://127.0.0.1:1234", challenge, "state&x")
	defer delete(url)
	testing.expect(t, strings.contains(url, "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"), "scope encoded")
	testing.expect(t, strings.contains(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1234"), "redirect encoded")
	testing.expect(t, strings.contains(url, "state=state%26x"), "state encoded")
	testing.expect(t, strings.contains(url, "code_challenge_method=S256"), "PKCE method")
}

@(test)
cloud_url_roundtrip :: proc(t: ^testing.T) {
	raw := "name with / and & and ü"
	encoded := cloud_url_encode(raw)
	defer delete(encoded)
	decoded := cloud_url_decode(encoded)
	defer delete(decoded)
	testing.expect(t, decoded == raw, decoded)
}

@(test)
cloud_session_id_persists_and_rejects_traversal :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-odin-cloud-id"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)

	first, ok := cloud_session_id(dir)
	defer delete(first)
	testing.expect(t, ok, "id")
	testing.expect(t, len(first) >= 8, "id length")
	second, ok2 := cloud_session_id(dir)
	defer delete(second)
	testing.expect(t, ok2, "id reread")
	testing.expect(t, first == second, "id is stable")
	testing.expect(t, os.exists("/tmp/tracker-odin-cloud-id/.tracker-cloud-id"), "id file")

	files := cloud_collect_files(dir, []string{"../evil.wav", "take1.wav"})
	defer cloud_files_free(files)
	for path in files {
		testing.expect(t, !strings.contains(path, ".."), path)
	}
}

@(test)
cloud_index_merge_replaces_by_id :: proc(t: ^testing.T) {
	index := Cloud_Index{version = CLOUD_VERSION}
	defer cloud_index_destroy(&index)
	cloud_index_merge(&index, Cloud_Index_Entry {
		id = strings.clone("abc"),
		folder_id = strings.clone("folder-1"),
		name = strings.clone("First"),
		modified = 10,
	})
	testing.expect(t, len(index.projects) == 1, "first entry")
	cloud_index_merge(&index, Cloud_Index_Entry {
		id = strings.clone("abc"),
		folder_id = strings.clone("folder-2"),
		name = strings.clone("Renamed"),
		modified = 20,
	})
	testing.expect(t, len(index.projects) == 1, "no duplicate")
	testing.expect(t, index.projects[0].name == "Renamed", index.projects[0].name)
	testing.expect(t, index.projects[0].folder_id == "folder-2", index.projects[0].folder_id)
}

@(test)
cloud_sanitize_and_time_helpers :: proc(t: ^testing.T) {
	name := cloud_sanitize_name("Night Session / Take 2")
	defer delete(name)
	testing.expect(t, name == "Night-Session-Take-2", name)
	empty := cloud_sanitize_name("---")
	defer delete(empty)
	testing.expect(t, empty == "project", empty)
	never := cloud_format_time(0)
	defer delete(never)
	testing.expect(t, never == "never", never)
	size := cloud_format_bytes(1_048_576)
	defer delete(size)
	testing.expect(t, size == "1.0 MB", size)
}

@(test)
cloud_scope_is_file_only_not_full_drive :: proc(t: ^testing.T) {
	testing.expect(t, CLOUD_SCOPE == "https://www.googleapis.com/auth/drive.file", CLOUD_SCOPE)
	testing.expect(t, !strings.contains(CLOUD_SCOPE, "auth/drive\""), "never request full Drive")
	testing.expect(t, !strings.contains(CLOUD_SCOPE, "drive.readonly"), "no read-only global scope")
}

@(test)
cloud_queries_are_always_parent_scoped :: proc(t: ^testing.T) {
	q := cloud_drive_parent_query("folder-123", "name = 'project.json'")
	defer delete(q)
	testing.expect(t, strings.contains(q, "'folder-123' in parents"), q)
	testing.expect(t, strings.contains(q, "trashed = false"), q)
	testing.expect(t, strings.contains(q, "name = 'project.json'"), q)
	testing.expect(t, strings.contains(CLOUD_APP_QUERY, "appProperties has"), CLOUD_APP_QUERY)
	testing.expect(t, strings.contains(CLOUD_APP_QUERY, "key='tracker'"), CLOUD_APP_QUERY)
}

@(test)
cloud_restore_names_reject_traversal :: proc(t: ^testing.T) {
	good := []string{"project.json", "track1.wav", ".tracker-cloud-id", "take-2.wav"}
	for name in good {
		testing.expectf(t, cloud_safe_file_name(name), "rejected safe name %s", name)
	}
	bad := []string{"", ".", "..", "../secret", "/etc/passwd", "a/b.wav", "a\\b.wav", "track\x00.wav"}
	for name in bad {
		testing.expectf(t, !cloud_safe_file_name(name), "accepted unsafe name %q", name)
	}
}

@(test)
cloud_restore_never_reuses_an_existing_folder :: proc(t: ^testing.T) {
	root := "/tmp/tracker-odin-restore-safety"
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer _ = os.remove_all(root)

	_ = os.make_directory_all("/tmp/tracker-odin-restore-safety/Night")
	_ = os.make_directory_all("/tmp/tracker-odin-restore-safety/Night-2")
	first := cloud_unique_dir(root, "Night")
	defer delete(first)
	testing.expect(t, first == "/tmp/tracker-odin-restore-safety/Night-3", first)

	partial := cloud_partial_dir(first)
	defer delete(partial)
	testing.expect(t, partial != "" && !os.exists(partial), partial)
	_ = os.make_directory_all(partial)
	second := cloud_partial_dir(first)
	defer delete(second)
	testing.expect(t, second != "" && second != partial && !os.exists(second), second)

	// Exhaust the -2..-99 suffixes; the timestamp fallback must not use a
	// freed base path or return an existing directory.
	for i in 3 ..= 99 {
		_ = os.make_directory_all(fmt.tprintf("/tmp/tracker-odin-restore-safety/Night-%d", i))
	}
	fallback := cloud_unique_dir(root, "Night")
	defer delete(fallback)
	testing.expect(t, fallback != "" && !os.exists(fallback), fallback)
	testing.expect(t, strings.has_prefix(fallback, "/tmp/tracker-odin-restore-safety/Night-"), fallback)
}

@(test)
cloud_backup_file_set_is_explicit :: proc(t: ^testing.T) {
	root := "/tmp/tracker-odin-cloud-files"
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer _ = os.remove_all(root)
	names := []string{"project.json", ".tracker-cloud-id", "track1.wav", "bounce.wav", "take1.wav", "notes.txt"}
	for name in names {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "x") == nil, name)
	}
	files := cloud_collect_files(root, []string{"take1.wav", "../secret.wav", "/etc/passwd", "a\\b.wav", "take2.wav"})
	defer cloud_files_free(files)
	testing.expect(t, len(files) == 5, "only project, id, track, bounce and take")
	for path in files {
		name := path[strings.last_index_byte(path, '/') + 1:]
		testing.expect(t, cloud_safe_file_name(name), name)
		testing.expect(t, name != "notes.txt", "unrelated local file included")
	}
}

@(test)
cloud_hidden_folder_defaults_to_tracker :: proc(t: ^testing.T) {
	store: Cloud_Store
	testing.expect(t, cloud_folder_name(&store) == "Tracker", "default folder")
	store.folder_name = strings.clone("Studio Backups")
	defer cloud_store_destroy(&store)
	testing.expect(t, cloud_folder_name(&store) == "Studio Backups", cloud_folder_name(&store))
}

@(test)
cloud_credentials_and_folder_persist :: proc(t: ^testing.T) {
	dir := "/tmp/tracker-odin-cloud-config"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer _ = os.remove_all(dir)
	path := "/tmp/tracker-odin-cloud-config/cloud.json"

	c := Cloud{}
	cloud_init(&c, path)
	defer cloud_destroy(&c)
	testing.expect(t, cloud_set_client(&c, "client-id", "client-secret", "Studio Backups"), "save config")
	store, ok := cloud_store_load(path)
	defer cloud_store_destroy(&store)
	testing.expect(t, ok, "load config")
	testing.expect(t, store.client_id == "client-id", store.client_id)
	testing.expect(t, store.folder_name == "Studio Backups", store.folder_name)
}

// Guard against future regressions: this transport is intentionally
// append/update/download only. A remote delete would need explicit product
// approval and a separate safety review.
@(test)
cloud_transport_has_no_remote_delete :: proc(t: ^testing.T) {
	source_dir := filepath.dir(#file)
	source, err := os.read_entire_file(fmt.tprintf("%s/cloud_drive.odin", source_dir), context.allocator)
	testing.expect(t, err == nil, "source readable")
	defer delete(source)
	text := string(source)
	testing.expect(t, !strings.contains(text, "\"DELETE\""), "cloud_drive must not issue DELETE")
	testing.expect(t, !strings.contains(text, "files.delete"), "cloud_drive must not use files.delete")
	testing.expect(t, !strings.contains(text, "os.remove_all"), "cloud_drive must not remove directories")

	jobs, jerr := os.read_entire_file(fmt.tprintf("%s/cloud_jobs.odin", source_dir), context.allocator)
	testing.expect(t, jerr == nil, "jobs readable")
	defer delete(jobs)
	jtext := string(jobs)
	testing.expect(t, !strings.contains(jtext, "os.remove_all(final)"), "restore must not delete the target")
	testing.expect(t, !strings.contains(jtext, "\"DELETE\""), "cloud jobs must not issue DELETE")
	testing.expect(t, strings.count(jtext, "os.remove_all") == 1, "only the generated partial folder may be removed")
	testing.expect(t, strings.contains(jtext, "os.remove_all(partial)"), "cleanup must target the generated partial")
	testing.expect(t, strings.contains(jtext, "cloud_drive_list(token, entry.folder_id, CLOUD_APP_QUERY"), "restore must list only app-marked files")
}

Cloud_Callback_Probe :: struct {
	port: int,
	path: string,
}

@(private)
cloud_callback_probe :: proc(t: ^thread.Thread) {
	probe := cast(^Cloud_Callback_Probe)t.data
	time.sleep(40 * time.Millisecond)
	sock, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = probe.port})
	if err != nil {
		return
	}
	defer net.close(sock)
	request := fmt.aprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", probe.path)
	defer delete(request)
	_, _ = net.send_tcp(sock, transmute([]u8)request)
	buf: [1024]u8
	_, _ = net.recv_tcp(sock, buf[:])
}

@(test)
cloud_oauth_callback_checks_state_and_returns_code :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0}, 4)
	testing.expect(t, lerr == nil, "listener")
	bound, berr := net.bound_endpoint(listener)
	testing.expect(t, berr == nil && bound.port > 0, "bound port")

	probe := Cloud_Callback_Probe{port = bound.port, path = "/?code=the-code&state=the-state"}
	worker := thread.create(cloud_callback_probe)
	testing.expect(t, worker != nil, "probe thread")
	worker.data = &probe
	thread.start(worker)
	code, ok, err := cloud_wait_for_code(listener, "the-state")
	defer thread.destroy(worker)
	testing.expect(t, ok, err)
	testing.expect(t, code == "the-code", code)
	delete(code)
}

@(test)
cloud_token_json_and_apply :: proc(t: ^testing.T) {
	raw_text := `{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"token_type":"Bearer"}`
	raw := transmute([]u8)raw_text
	token: Cloud_Token
	defer cloud_token_destroy(&token)
	err := cloud_json_token(raw, &token)
	testing.expect(t, err == "", err)
	testing.expect(t, token.access_token == "access-1", token.access_token)
	store: Cloud_Store
	defer cloud_store_destroy(&store)
	before := cloud_now()
	cloud_apply_token(&store, &token)
	testing.expect(t, store.access_token == "access-1", "access token applied")
	testing.expect(t, store.refresh_token == "refresh-1", "refresh token applied")
	testing.expect(t, store.expires_unix >= before + 3500, "expiry applied")

	bad_text := `{"error":"invalid_grant"}`
	bad: Cloud_Token
	err = cloud_json_token(transmute([]u8)bad_text, &bad)
	testing.expect(t, err == "", err)
	testing.expect(t, bad.error == "invalid_grant", "error preserved")
}

@(test)
cloud_token_expiry_and_connection :: proc(t: ^testing.T) {
	store := Cloud_Store{version = CLOUD_VERSION, refresh_token = strings.clone("r"), access_token = strings.clone("a"), expires_unix = 1000}
	defer cloud_store_destroy(&store)
	testing.expect(t, cloud_connected(&store), "connected with refresh token")
	testing.expect(t, cloud_token_valid(&store, 900), "token valid before expiry")
	testing.expect(t, !cloud_token_valid(&store, 950), "token refresh window")
	testing.expect(t, !cloud_token_valid(&store, 2000), "token expired")
	testing.expect(t, time.to_unix_seconds(time.now()) > 0, "clock")
}
