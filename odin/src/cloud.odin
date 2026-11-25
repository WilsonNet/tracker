// Google Drive project transfer.
//
// Scope is drive.file only: Tracker-FX can see the files/folders it created in a
// visible, named My Drive folder, and nothing else. OAuth is the desktop
// loopback + PKCE flow; the refresh token is stored in cloud.json with 0600
// permissions. Drive REST calls go through curl so large WAVs stream without a
// TLS stack in the app.

package main

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

CLOUD_VERSION :: 1
CLOUD_DRIVE_API :: "https://www.googleapis.com/drive/v3"
CLOUD_DRIVE_UPLOAD :: "https://www.googleapis.com/upload/drive/v3"
CLOUD_OAUTH_AUTH :: "https://accounts.google.com/o/oauth2/v2/auth"
CLOUD_OAUTH_TOKEN :: "https://oauth2.googleapis.com/token"
CLOUD_OAUTH_REVOKE :: "https://oauth2.googleapis.com/revoke"
CLOUD_SCOPE :: "https://www.googleapis.com/auth/drive.file"

// Overridden only by the fake-Drive integration test; production uses the
// constants above.
cloud_api_base: string = CLOUD_DRIVE_API
cloud_upload_base: string = CLOUD_DRIVE_UPLOAD
CLOUD_ROOT_NAME :: "Tracker-FX"
CLOUD_INDEX_NAME :: "index.json"
CLOUD_ID_FILE :: ".tracker-fx-cloud-id"
CLOUD_NAME_MAX :: 96
CLOUD_ID_MAX :: 64
CLOUD_PATH_MAX :: 4096
CLOUD_MAX_PROJECTS :: 32
CLOUD_OAUTH_TIMEOUT_SECONDS :: 180

// ---------------------------------------------------------------- store

Cloud_Store :: struct {
	version:       int    `json:"version"`,
	client_id:     string `json:"clientId,omitempty"`,
	client_secret: string `json:"clientSecret,omitempty"`,
	access_token:  string `json:"accessToken,omitempty"`,
	refresh_token: string `json:"refreshToken,omitempty"`,
	expires_unix:  i64    `json:"expiresUnix,omitempty"`,
	last_sync:     i64    `json:"lastSync,omitempty"`,
	folder_name:   string `json:"folderName,omitempty"`,
}

cloud_store_path :: proc() -> string {
	dir := recent_config_dir()
	defer delete(dir)
	return fmt.aprintf("%s/cloud.json", dir)
}

cloud_store_destroy :: proc(store: ^Cloud_Store) {
	if store == nil {
		return
	}
	delete(store.client_id)
	delete(store.client_secret)
	delete(store.access_token)
	delete(store.refresh_token)
	delete(store.folder_name)
	store^ = Cloud_Store{version = CLOUD_VERSION}
}

@(private)
cloud_write_private :: proc(path: string, data: []u8) -> bool {
	if path == "" {
		return false
	}
	if !ensure_parent_dir(path) {
		return false
	}
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		fmt.eprintfln("cannot write %s: %v", path, err)
		return false
	}
	defer os.close(f)
	_, werr := os.write(f, data)
	if werr != nil {
		return false
	}
	_ = os.chmod(path, os.Permissions{.Read_User, .Write_User})
	return true
}

cloud_store_load :: proc(path: string) -> (Cloud_Store, bool) {
	store := Cloud_Store{version = CLOUD_VERSION}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return store, false
	}
	defer delete(data)
	if uerr := json.unmarshal(data, &store); uerr != nil {
		cloud_store_destroy(&store)
		return Cloud_Store{version = CLOUD_VERSION}, false
	}
	if store.version != CLOUD_VERSION {
		cloud_store_destroy(&store)
		return Cloud_Store{version = CLOUD_VERSION}, false
	}
	return store, true
}

cloud_store_save :: proc(path: string, store: ^Cloud_Store) -> bool {
	if store == nil {
		return false
	}
	data, err := json.marshal(store^, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fmt.eprintfln("cloud encode failed: %v", err)
		return false
	}
	defer delete(data)
	return cloud_write_private(path, data)
}

cloud_store_clone :: proc(store: ^Cloud_Store) -> Cloud_Store {
	return Cloud_Store {
		version = store.version,
		client_id = strings.clone(store.client_id),
		client_secret = strings.clone(store.client_secret),
		access_token = strings.clone(store.access_token),
		refresh_token = strings.clone(store.refresh_token),
		expires_unix = store.expires_unix,
		last_sync = store.last_sync,
		folder_name = strings.clone(store.folder_name),
	}
}

// Moves `src` into `dst`, freeing the old strings. Caller must hold the mutex.
cloud_store_commit :: proc(dst: ^Cloud_Store, src: ^Cloud_Store) {
	cloud_store_destroy(dst)
	dst^ = src^
	src^ = Cloud_Store{version = CLOUD_VERSION}
}

cloud_folder_name :: proc(store: ^Cloud_Store) -> string {
	return strings.trim_space(store.folder_name) if store != nil && strings.trim_space(store.folder_name) != "" else CLOUD_ROOT_NAME
}

cloud_has_credentials :: proc(store: ^Cloud_Store) -> bool {
	return store != nil && store.client_id != "" && store.client_secret != ""
}

cloud_connected :: proc(store: ^Cloud_Store) -> bool {
	return store != nil && store.refresh_token != ""
}

cloud_token_valid :: proc(store: ^Cloud_Store, now: i64) -> bool {
	return store != nil && store.access_token != "" && store.expires_unix > now + 60
}

// ---------------------------------------------------------------- PKCE

@(private)
cloud_random_bytes :: proc(n: int) -> []u8 {
	out := make([]u8, n)
	crypto.rand_bytes(out)
	return out
}

cloud_pkce :: proc() -> (verifier, challenge: string) {
	raw := cloud_random_bytes(32)
	defer delete(raw)
	verifier = base64.encode(raw, base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
	digest: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)verifier)
	sha2.final(&ctx, digest[:])
	challenge = base64.encode(digest[:], base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
	return
}

cloud_state :: proc() -> string {
	raw := cloud_random_bytes(16)
	defer delete(raw)
	return base64.encode(raw, base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
}

// ---------------------------------------------------------------- URL helpers

cloud_url_encode :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~'
		if ok {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 0xF])
		}
	}
	return strings.clone(strings.to_string(b))
}

cloud_url_decode :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi := s[i + 1]
			lo := s[i + 2]
			hexval :: proc(c: u8) -> (u8, bool) {
				switch {
				case c >= '0' && c <= '9':
					return c - '0', true
				case c >= 'a' && c <= 'f':
					return c - 'a' + 10, true
				case c >= 'A' && c <= 'F':
					return c - 'A' + 10, true
				}
				return 0, false
			}
			h, hok := hexval(hi)
			l, lok := hexval(lo)
			if hok && lok {
				strings.write_byte(&b, h << 4 | l)
				i += 3
				continue
			}
		}
		if c == '+' {
			strings.write_byte(&b, ' ')
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	return strings.clone(strings.to_string(b))
}

cloud_oauth_url :: proc(client_id, redirect_uri, challenge, state: string) -> string {
	id := cloud_url_encode(client_id)
	defer delete(id)
	redirect := cloud_url_encode(redirect_uri)
	defer delete(redirect)
	scope := cloud_url_encode(CLOUD_SCOPE)
	defer delete(scope)
	challenge_enc := cloud_url_encode(challenge)
	defer delete(challenge_enc)
	state_enc := cloud_url_encode(state)
	defer delete(state_enc)
	return fmt.aprintf(
		"%s?client_id=%s&redirect_uri=%s&response_type=code&scope=%s&access_type=offline&prompt=consent&include_granted_scopes=true&code_challenge=%s&code_challenge_method=S256&state=%s",
		CLOUD_OAUTH_AUTH, id, redirect, scope, challenge_enc, state_enc,
	)
}

// ---------------------------------------------------------------- curl

Cloud_Curl :: struct {
	out:     []u8,
	err:     []u8,
	headers: []u8,
	ok:      bool,
	code:    int,
}

cloud_curl_destroy :: proc(r: ^Cloud_Curl) {
	delete(r.out)
	delete(r.err)
	delete(r.headers)
	r^ = {}
}

cloud_temp_dir :: proc() -> string {
	dir := fmt.aprintf("/tmp/tracker-fx-cloud-%d", os.get_pid())
	_ = os.make_directory_all(dir)
	return dir
}

cloud_temp_name :: proc(dir, prefix: string) -> string {
	raw := cloud_random_bytes(8)
	defer delete(raw)
	tag := base64.encode(raw, base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
	defer delete(tag)
	return fmt.aprintf("%s/%s-%s", dir, prefix, tag)
}

// Executes curl without putting tokens in argv. Headers are written to a 0600
// file and referenced with `--header @file`; an optional body file streams the
// request body. The response body is captured (small JSON) unless output_path
// is set, in which case curl writes the download there.
cloud_curl_request :: proc(
	method, url: string,
	headers: []string,
	body_file: string = "",
	upload_file: string = "",
	output_path: string = "",
	max_time: int = 120,
) -> Cloud_Curl {
	res: Cloud_Curl
	dir := cloud_temp_dir()
	defer delete(dir)

	header_path := cloud_temp_name(dir, "headers")
	defer delete(header_path)
	defer os.remove(header_path)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for h in headers {
		strings.write_string(&b, h)
		strings.write_string(&b, "\n")
	}
	if !cloud_write_private(header_path, transmute([]u8)strings.to_string(b)) {
		res.err = transmute([]u8)fmt.aprintf("cannot prepare cloud request")
		return res
	}

	dump_path := cloud_temp_name(dir, "response-headers")
	defer delete(dump_path)
	defer os.remove(dump_path)

	args: [dynamic]string
	defer delete(args)
	max_text := fmt.aprintf("%d", max_time)
	defer delete(max_text)
	header_arg := fmt.aprintf("@%s", header_path)
	defer delete(header_arg)
	append(&args, "curl")
	append(&args, "-sS", "--fail-with-body", "--connect-timeout", "20", "--max-time", max_text)
	append(&args, "-X", method)
	append(&args, "--header", header_arg)
	append(&args, "--dump-header", dump_path)
	body_arg: string
	if body_file != "" {
		body_arg = fmt.aprintf("@%s", body_file)
	}
	defer delete(body_arg)
	if body_arg != "" {
		append(&args, "--data-binary", body_arg)
	}
	if upload_file != "" {
		append(&args, "--upload-file", upload_file)
	}
	if output_path != "" {
		append(&args, "--output", output_path)
	}
	append(&args, url)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{command = args[:]}, context.allocator)
	res.out = stdout
	res.err = stderr
	res.code = state.exit_code
	res.ok = exec_err == nil && state.exited && state.exit_code == 0
	if exec_err != nil && len(res.err) == 0 {
		delete(res.err)
		res.err = transmute([]u8)fmt.aprintf("cannot run curl: %v", exec_err)
	}
	if hdata, herr := os.read_entire_file(dump_path, context.allocator); herr == nil {
		res.headers = hdata
	}
	return res
}

// Case-insensitive header lookup in the raw `--dump-header` output.
cloud_header :: proc(headers: []u8, name: string) -> string {
	text := string(headers)
	lines := strings.split(text, "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		colon := strings.index_byte(trimmed, ':')
		if colon <= 0 {
			continue
		}
		key := strings.trim_space(trimmed[:colon])
		if strings.equal_fold(key, name) {
			return strings.trim_space(trimmed[colon + 1:])
		}
	}
	return ""
}

// ---------------------------------------------------------------- JSON types

Cloud_Drive_File :: struct {
	id:           string `json:"id"`,
	name:         string `json:"name"`,
	mime_type:    string `json:"mimeType"`,
	modified_time: string `json:"modifiedTime"`,
	size:         string `json:"size"`,
}

Cloud_Drive_List :: struct {
	files:          []Cloud_Drive_File `json:"files"`,
	next_page_token: string            `json:"nextPageToken"`,
}

Cloud_Index_Entry :: struct {
	id:        string `json:"id"`,
	folder_id: string `json:"folderId"`,
	name:      string `json:"name"`,
	modified:  i64    `json:"modified"`,
	bytes:     u64    `json:"bytes"`,
	files:     int    `json:"files"`,
}

Cloud_Index :: struct {
	version:  int               `json:"version"`,
	projects: []Cloud_Index_Entry `json:"projects"`,
}

Cloud_Token :: struct {
	access_token:  string `json:"access_token"`,
	refresh_token: string `json:"refresh_token"`,
	expires_in:    i64    `json:"expires_in"`,
	token_type:    string `json:"token_type"`,
	error:         string `json:"error"`,
	error_description: string `json:"error_description"`,
}

cloud_json_token :: proc(data: []u8, token: ^Cloud_Token) -> string {
	if err := json.unmarshal(data, token); err != nil {
		return fmt.aprintf("cannot parse token response: %v", err)
	}
	return ""
}

cloud_token_destroy :: proc(t: ^Cloud_Token) {
	delete(t.access_token)
	delete(t.refresh_token)
	delete(t.token_type)
	delete(t.error)
	delete(t.error_description)
}

cloud_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}
