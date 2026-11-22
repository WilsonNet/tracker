// Google Drive v3 transport on top of cloud_curl_request.
//
// The user-visible folder lives in My Drive (drive.file scope):
//   Tracker/index.json
//   Tracker/projects/<cloud-id>/project.json + WAVs + .tracker-cloud-id

package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

CLOUD_FOLDER_MIME :: "application/vnd.google-apps.folder"
CLOUD_ROOT_ID :: "root"
CLOUD_APP_KEY :: "tracker"
CLOUD_APP_VALUE :: "1"
CLOUD_APP_QUERY :: "appProperties has { key='tracker' and value='1' }"

// ---------------------------------------------------------------- errors

@(private)
cloud_error_text :: proc(res: ^Cloud_Curl) -> string {
	text := strings.trim_space(string(res.out))
	if text == "" {
		text = strings.trim_space(string(res.err))
	}
	if text == "" {
		text = fmt.tprintf("Google Drive request failed (curl exit %d)", res.code)
	}
	if len(text) > 280 {
		text = text[:280]
	}
	return strings.clone(text)
}

@(private)
cloud_write_temp :: proc(dir, prefix: string, data: []u8) -> string {
	path := cloud_temp_name(dir, prefix)
	if !cloud_write_private(path, data) {
		return ""
	}
	return path
}

// ---------------------------------------------------------------- list / folders

// Every list is anchored to one parent folder. There is deliberately no
// global name search, so a query can never wander into unrelated Drive files.
cloud_drive_parent_query :: proc(parent, suffix: string) -> string {
	q := fmt.aprintf("'%s' in parents and trashed = false", parent)
	if suffix != "" {
		next := fmt.aprintf("%s and (%s)", q, suffix)
		delete(q)
		q = next
	}
	return q
}

cloud_drive_list :: proc(token, parent, query_suffix: string, page_size: int = 1000) -> (files: []Cloud_Drive_File, err: string) {
	out: [dynamic]Cloud_Drive_File
	defer if err != "" {
		cloud_drive_files_destroy(out[:])
	}
	dir := cloud_temp_dir()
	defer delete(dir)
	auth := fmt.aprintf("Authorization: Bearer %s", token)
	defer delete(auth)
	headers := []string{auth}
	page_token := ""
	defer delete(page_token)
	for _ in 0 ..< 16 {
		q := cloud_drive_parent_query(parent, query_suffix)
		defer delete(q)
		encoded_q := cloud_url_encode(q)
		defer delete(encoded_q)
		base := fmt.aprintf(
			"%s/files?q=%s&fields=files(id,name,mimeType,modifiedTime,size),nextPageToken&pageSize=%d",
			cloud_api_base, encoded_q, page_size,
		)
		defer delete(base)
		url := base
		page_url := ""
		if page_token != "" {
			page_url = fmt.aprintf("%s&pageToken=%s", base, cloud_url_encode(page_token))
			url = page_url
		}
		res := cloud_curl_request("GET", url, headers, max_time = 60)
		delete(page_url)
		if !res.ok {
			err = cloud_error_text(&res)
			cloud_curl_destroy(&res)
			return nil, err
		}
		list: Cloud_Drive_List
		if uerr := json.unmarshal(res.out, &list); uerr != nil {
			cloud_curl_destroy(&res)
			delete(list.next_page_token)
			for f in list.files {
				delete(f.id)
				delete(f.name)
				delete(f.mime_type)
				delete(f.modified_time)
				delete(f.size)
			}
			delete(list.files)
			return nil, fmt.tprintf("cannot parse Drive list: %v", uerr)
		}
		cloud_curl_destroy(&res)
		for f in list.files {
			append(&out, f)
		}
		if list.next_page_token == "" {
			delete(list.files)
			break
		}
		delete(page_token)
		page_token = strings.clone(list.next_page_token)
		delete(list.next_page_token)
		delete(list.files)
	}
	return out[:], ""
}

cloud_drive_files_destroy :: proc(files: []Cloud_Drive_File) {
	for f in files {
		delete(f.id)
		delete(f.name)
		delete(f.mime_type)
		delete(f.modified_time)
		delete(f.size)
	}
	delete(files)
}

cloud_drive_find :: proc(token, parent, name: string, folder: bool, err: ^string) -> (id: string, found: bool) {
	escaped_raw, was_alloc := strings.replace_all(name, "'", "\\'")
	escaped := strings.clone(escaped_raw)
	if was_alloc {
		delete(escaped_raw)
	}
	defer delete(escaped)
	suffix := fmt.aprintf("name = '%s'", escaped)
	defer delete(suffix)
	if folder {
		next := fmt.aprintf("%s and mimeType = '%s'", suffix, CLOUD_FOLDER_MIME)
		delete(suffix)
		suffix = next
	} else {
		next := fmt.aprintf("%s and mimeType != '%s'", suffix, CLOUD_FOLDER_MIME)
		delete(suffix)
		suffix = next
	}
	next := fmt.aprintf("%s and %s", suffix, CLOUD_APP_QUERY)
	delete(suffix)
	suffix = next
	files, lerr := cloud_drive_list(token, parent, suffix, 2)
	if lerr != "" {
		err^ = lerr
		return "", false
	}
	defer cloud_drive_files_destroy(files)
	if len(files) == 0 {
		return "", false
	}
	if len(files) > 1 {
		err^ = fmt.tprintf("multiple Tracker items named '%s'; remove duplicates in Drive", name)
		return "", false
	}
	return strings.clone(files[0].id), true
}

cloud_drive_create_folder :: proc(token, name, parent: string, err: ^string) -> (id: string, ok: bool) {
	dir := cloud_temp_dir()
	defer delete(dir)
	props := struct {
		tracker: string `json:"tracker"`,
	}{CLOUD_APP_VALUE}
	meta := struct {
		name:      string   `json:"name"`,
		mime:      string   `json:"mimeType"`,
		parents:   []string `json:"parents"`,
		props:     struct{ tracker: string `json:"tracker"` } `json:"appProperties"`,
	}{name, CLOUD_FOLDER_MIME, []string{parent}, props}
	data, merr := json.marshal(meta)
	if merr != nil {
		err^ = fmt.tprintf("cannot encode folder: %v", merr)
		return "", false
	}
	defer delete(data)
	body := cloud_write_temp(dir, "folder", data)
	if body == "" {
		err^ = "cannot prepare cloud request"
		return "", false
	}
	defer delete(body)
	defer os.remove(body)
	auth := fmt.aprintf("Authorization: Bearer %s", token)
	defer delete(auth)
	headers := []string{auth, "Content-Type: application/json; charset=UTF-8"}
	url := fmt.tprintf("%s/files?fields=id", cloud_api_base)
	res := cloud_curl_request("POST", url, headers, body_file = body, max_time = 60)
	defer cloud_curl_destroy(&res)
	if !res.ok {
		err^ = cloud_error_text(&res)
		return "", false
	}
	reply: struct {
		id: string `json:"id"`,
	}
	defer delete(reply.id)
	if uerr := json.unmarshal(res.out, &reply); uerr != nil || reply.id == "" {
		err^ = "Drive did not return a folder id"
		return "", false
	}
	return strings.clone(reply.id), true
}

// Finds or creates `name` under parent. The caller owns the returned id.
cloud_drive_ensure_folder :: proc(token, name, parent: string, err: ^string) -> (id: string, ok: bool) {
	if existing, found := cloud_drive_find(token, parent, name, true, err); found {
		return existing, true
	} else if err^ != "" {
		return "", false
	}
	created, cok := cloud_drive_create_folder(token, name, parent, err)
	return created, cok
}

cloud_drive_root :: proc(token, name: string, err: ^string) -> (id: string, ok: bool) {
	folder_name := strings.trim_space(name)
	if folder_name == "" {
		folder_name = CLOUD_ROOT_NAME
	}
	return cloud_drive_ensure_folder(token, folder_name, CLOUD_ROOT_ID, err)
}

// ---------------------------------------------------------------- upload / download

cloud_drive_upload :: proc(token, local_path, name, parent, existing_id: string, progress_name: ^string) -> (ok: bool, err: string) {
	info, stat_err := os.stat(local_path, context.allocator)
	if stat_err != nil {
		return false, fmt.tprintf("cannot read %s", local_path)
	}
	defer os.file_info_delete(info, context.allocator)
	size := int(info.size)
	if size < 0 {
		return false, fmt.tprintf("invalid file size for %s", local_path)
	}
	dir := cloud_temp_dir()
	defer delete(dir)

	props := struct {
		tracker: string `json:"tracker"`,
	}{CLOUD_APP_VALUE}
	meta := struct {
		name:    string   `json:"name,omitempty"`,
		parents: []string `json:"parents,omitempty"`,
		props:   struct{ tracker: string `json:"tracker"` } `json:"appProperties"`,
	}{props = props}
	if existing_id == "" {
		meta.name = name
		meta.parents = []string{parent}
	}
	data, merr := json.marshal(meta)
	if merr != nil {
		return false, fmt.tprintf("cannot encode upload: %v", merr)
	}
	defer delete(data)
	body := cloud_write_temp(dir, "upload-meta", data)
	if body == "" {
		return false, "cannot prepare cloud request"
	}
	defer delete(body)
	defer os.remove(body)

	auth := fmt.aprintf("Authorization: Bearer %s", token)
	defer delete(auth)
	headers := []string{
		auth,
		"Content-Type: application/json; charset=UTF-8",
		"X-Upload-Content-Type: application/octet-stream",
		fmt.tprintf("X-Upload-Content-Length: %d", size),
	}
	init_url := ""
	init_method := "POST"
	if existing_id == "" {
		init_url = fmt.aprintf("%s/files?uploadType=resumable&fields=id", cloud_upload_base)
	} else {
		init_url = fmt.aprintf("%s/files/%s?uploadType=resumable&fields=id", cloud_upload_base, existing_id)
		init_method = "PATCH"
	}
	defer delete(init_url)
	init := cloud_curl_request(init_method, init_url, headers, body_file = body, max_time = 60)
	defer cloud_curl_destroy(&init)
	if !init.ok {
		return false, cloud_error_text(&init)
	}
	location := cloud_header(init.headers, "location")
	if location == "" {
		return false, "Drive did not return an upload session"
	}

	upload_headers := []string{
		"Content-Type: application/octet-stream",
		fmt.tprintf("Content-Length: %d", size),
		fmt.tprintf("Content-Range: bytes 0-%d/%d", max(size - 1, 0), size),
	}
	if progress_name != nil {
		progress_name^ = strings.clone(name)
	}
	put := cloud_curl_request("PUT", location, upload_headers, upload_file = local_path, max_time = 900)
	defer cloud_curl_destroy(&put)
	if !put.ok {
		return false, cloud_error_text(&put)
	}
	return true, ""
}

cloud_drive_download :: proc(token, file_id, out_path: string) -> (ok: bool, err: string) {
	auth := fmt.aprintf("Authorization: Bearer %s", token)
	defer delete(auth)
	url := fmt.tprintf("%s/files/%s?alt=media", cloud_api_base, file_id)
	res := cloud_curl_request("GET", url, []string{auth}, output_path = out_path, max_time = 900)
	defer cloud_curl_destroy(&res)
	if !res.ok {
		return false, cloud_error_text(&res)
	}
	return true, ""
}

cloud_drive_media :: proc(token, file_id: string) -> (data: []u8, ok: bool, err: string) {
	auth := fmt.aprintf("Authorization: Bearer %s", token)
	defer delete(auth)
	url := fmt.tprintf("%s/files/%s?alt=media", cloud_api_base, file_id)
	res := cloud_curl_request("GET", url, []string{auth}, max_time = 120)
	if !res.ok {
		err = cloud_error_text(&res)
		cloud_curl_destroy(&res)
		return nil, false, err
	}
	data = res.out
	res.out = nil
	cloud_curl_destroy(&res)
	return data, true, ""
}

// ---------------------------------------------------------------- index

cloud_index_destroy :: proc(index: ^Cloud_Index) {
	for e in index.projects {
		delete(e.id)
		delete(e.folder_id)
		delete(e.name)
	}
	delete(index.projects)
	index^ = Cloud_Index{version = CLOUD_VERSION}
}

cloud_index_load :: proc(token, root: string, err: ^string) -> (index: Cloud_Index, ok: bool) {
	index = Cloud_Index{version = CLOUD_VERSION}
	id, found := cloud_drive_find(token, root, CLOUD_INDEX_NAME, false, err)
	if !found {
		if err^ != "" {
			return index, false
		}
		return index, true
	}
	defer delete(id)
	data, dok, derr := cloud_drive_media(token, id)
	if !dok {
		err^ = derr
		return index, false
	}
	defer delete(data)
	if uerr := json.unmarshal(data, &index); uerr != nil {
		cloud_index_destroy(&index)
		err^ = fmt.tprintf("cannot parse cloud index: %v", uerr)
		return Cloud_Index{version = CLOUD_VERSION}, false
	}
	if index.version != CLOUD_VERSION {
		cloud_index_destroy(&index)
		err^ = "cloud index has an unsupported version"
		return Cloud_Index{version = CLOUD_VERSION}, false
	}
	return index, true
}

cloud_index_save :: proc(token, root: string, index: ^Cloud_Index) -> (ok: bool, err: string) {
	data, merr := json.marshal(index^, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if merr != nil {
		return false, fmt.tprintf("cannot encode cloud index: %v", merr)
	}
	defer delete(data)
	existing, found := cloud_drive_find(token, root, CLOUD_INDEX_NAME, false, &err)
	if err != "" {
		return false, err
	}
	if !found {
		existing = ""
	}
	defer delete(existing)
	return cloud_index_upload_data(token, data, existing, root)
}

// The index is small; write it to a temp file so it uses the same resumable
// upload path as projects.
@(private)
cloud_index_upload_data :: proc(token: string, data: []u8, existing_id, parent: string) -> (ok: bool, err: string) {
	dir := cloud_temp_dir()
	defer delete(dir)
	path := cloud_write_temp(dir, "index", data)
	if path == "" {
		return false, "cannot prepare cloud index"
	}
	defer delete(path)
	defer os.remove(path)
	return cloud_drive_upload(token, path, CLOUD_INDEX_NAME, parent, existing_id, nil)
}

cloud_index_merge :: proc(index: ^Cloud_Index, entry: Cloud_Index_Entry) {
	for i in 0 ..< len(index.projects) {
		if index.projects[i].id == entry.id {
			// Free the replaced value's strings before overwriting.
			delete(index.projects[i].id)
			delete(index.projects[i].folder_id)
			delete(index.projects[i].name)
			index.projects[i] = entry
			return
		}
	}
	projects := make([dynamic]Cloud_Index_Entry, 0, len(index.projects) + 1)
	append(&projects, ..index.projects)
	append(&projects, entry)
	delete(index.projects)
	index.projects = projects[:]
	// Newest first; manual insertion sort keeps the list stable for equal times.
	i := len(index.projects) - 1
	for i > 0 && index.projects[i].modified > index.projects[i - 1].modified {
		index.projects[i], index.projects[i - 1] = index.projects[i - 1], index.projects[i]
		i -= 1
	}
}

// ---------------------------------------------------------------- local helpers

// A cloud file may only be a single, ordinary name inside the project folder.
// This blocks absolute paths, traversal and Windows separators before a
// download can write anywhere.
cloud_safe_file_name :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." || len(name) > 255 {
		return false
	}
	for c in transmute([]u8)name {
		if c == 0 || c == '/' || c == '\\' {
			return false
		}
	}
	return true
}

cloud_collect_files :: proc(session_dir: string, take_names: []string) -> []string {
	out: [dynamic]string
	seen: [dynamic]string
	defer {
		for s in seen {
			delete(s)
		}
		delete(seen)
	}
	add :: proc(out: ^[dynamic]string, seen: ^[dynamic]string, path: string) {
		if !os.exists(path) {
			return
		}
		for s in seen^ {
			if s == path {
				return
			}
		}
		append(seen, strings.clone(path))
		append(out, strings.clone(path))
	}
	add(&out, &seen, fmt.tprintf("%s/project.json", session_dir))
	add(&out, &seen, fmt.tprintf("%s/%s", session_dir, CLOUD_ID_FILE))
	for i in 1 ..= 4 {
		add(&out, &seen, fmt.tprintf("%s/track%d.wav", session_dir, i))
	}
	add(&out, &seen, fmt.tprintf("%s/bounce.wav", session_dir))
	for name in take_names {
		if !cloud_safe_file_name(name) {
			continue
		}
		add(&out, &seen, fmt.tprintf("%s/%s", session_dir, name))
	}
	return out[:]
}

cloud_files_free :: proc(files: []string) {
	for f in files {
		delete(f)
	}
	delete(files)
}

cloud_session_id :: proc(session_dir: string) -> (id: string, ok: bool) {
	path := fmt.tprintf("%s/%s", session_dir, CLOUD_ID_FILE)
	data, err := os.read_entire_file(path, context.allocator)
	if err == nil {
		defer delete(data)
		text := strings.trim_space(string(data))
		if len(text) >= 8 && len(text) <= CLOUD_ID_MAX && cloud_id_chars_ok(text) {
			return strings.clone(text), true
		}
	}
	raw := cloud_random_bytes(16)
	defer delete(raw)
	generated := base64.encode(raw, base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
	defer delete(generated)
	if !ensure_dir(session_dir) {
		return "", false
	}
	if !cloud_write_private(path, transmute([]u8)generated) {
		return "", false
	}
	return strings.clone(generated), true
}

@(private)
cloud_id_chars_ok :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

cloud_sanitize_name :: proc(name: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	last_dash := false
	for c in transmute([]u8)name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.'
		if ok {
			strings.write_byte(&b, c)
			last_dash = false
		} else if !last_dash {
			strings.write_byte(&b, '-')
			last_dash = true
		}
		if strings.builder_len(b) >= 48 {
			break
		}
	}
	s := strings.trim(strings.to_string(b), "-.")
	if s == "" {
		return strings.clone("project")
	}
	return strings.clone(s)
}

cloud_short_id :: proc(id: string) -> string {
	return strings.clone(id[:min(len(id), 6)])
}

cloud_format_bytes :: proc(bytes: u64) -> string {
	if bytes >= 1 << 30 {
		return fmt.aprintf("%.1f GB", f32(bytes) / f32(1 << 30))
	}
	if bytes >= 1 << 20 {
		return fmt.aprintf("%.1f MB", f32(bytes) / f32(1 << 20))
	}
	if bytes >= 1 << 10 {
		return fmt.aprintf("%.0f KB", f32(bytes) / f32(1 << 10))
	}
	return fmt.aprintf("%d B", bytes)
}

cloud_format_time :: proc(unix: i64) -> string {
	if unix <= 0 {
		return strings.clone("never")
	}
	t := time.unix(unix, 0)
	date: [16]u8
	clock: [16]u8
	dstr := time.to_string_yyyy_mm_dd(t, date[:])
	cstr := time.to_string_hms(t, clock[:])
	return fmt.aprintf("%s %s", dstr, cstr)
}

cloud_unique_dir :: proc(root, name: string) -> string {
	base := fmt.aprintf("%s/%s", root, name)
	if !os.exists(base) {
		return base
	}
	for i in 2 ..= 99 {
		candidate := fmt.aprintf("%s-%d", base, i)
		if !os.exists(candidate) {
			delete(base)
			return candidate
		}
		delete(candidate)
	}
	// Never fall back to a path that may already exist: the restore path is
	// allowed to fail, but it must not replace an unrelated local folder.
	for i in 0 ..< 1000 {
		candidate := fmt.aprintf("%s-%d-%d", base, time.to_unix_seconds(time.now()), i)
		if !os.exists(candidate) {
			delete(base)
			return candidate
		}
		delete(candidate)
	}
	delete(base)
	return ""
}

// A private scratch sibling for a restore. It is guaranteed not to exist (and
// therefore is never an existing user folder), so cleanup can only remove data
// this job created.
cloud_partial_dir :: proc(final: string) -> string {
	for _ in 0 ..< 64 {
		raw := cloud_random_bytes(6)
		defer delete(raw)
		tag := base64.encode(raw, base64.ENC_URL_TABLE, context.allocator, {.No_Padding})
		defer delete(tag)
		candidate := fmt.aprintf("%s.partial-%s", final, tag)
		if !os.exists(candidate) {
			return candidate
		}
		delete(candidate)
	}
	return ""
}
