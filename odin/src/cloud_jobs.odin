// Background jobs for the cloud UI. One job at a time; the worker owns all
// network and token work, the UI only reads the copied status/result fields.

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import ui "ui"

Cloud_Job :: enum { None, Connect, Disconnect, Backup, List, Restore }

Cloud_Project :: struct {
	id:       string,
	name:     string,
	modified: i64,
	bytes:    u64,
	files:    int,
}

Cloud_Task :: struct {
	cloud:        ^Cloud,
	kind:         Cloud_Job,
	project_id:   string,
	project_name: string,
	session_dir:  string,
	save_root:    string,
	takes:        []string,
}

Cloud_Result :: struct {
	projects:     []Cloud_Project,
	restored:     string,
	last_sync:    i64,
}

Cloud :: struct {
	path:   string,
	store:  Cloud_Store,
	thread: ^thread.Thread,
	task:   ^Cloud_Task,

	mutex:  sync.Mutex,
	busy:   u64,
	done:   u64,
	kind:   Cloud_Job,

	status_buf: [192]u8,
	status_len: int,
	error_buf:  [320]u8,
	error_len:  int,
	progress_done:  u64,
	progress_total: u64,

	result: Cloud_Result,
}

cloud_task_destroy :: proc(task: ^Cloud_Task) {
	if task == nil {
		return
	}
	delete(task.project_id)
	delete(task.project_name)
	delete(task.session_dir)
	delete(task.save_root)
	cloud_files_free(task.takes)
	free(task)
}

cloud_result_destroy :: proc(result: ^Cloud_Result) {
	for p in result.projects {
		delete(p.id)
		delete(p.name)
	}
	delete(result.projects)
	delete(result.restored)
	result^ = {}
}

cloud_init :: proc(c: ^Cloud, path: string) {
	c^ = Cloud{}
	c.path = strings.clone(path)
	c.store, _ = cloud_store_load(path)
}

cloud_destroy :: proc(c: ^Cloud) {
	if c == nil {
		return
	}
	if c.thread != nil {
		// A browser sign-in or a large transfer can outlive the window. On
		// process exit the OS reclaims it; freeing Cloud underneath a running
		// worker would be worse than a short-lived leak.
		if cloud_is_busy(c) {
			return
		}
		thread.destroy(c.thread)
		c.thread = nil
	}
	cloud_task_destroy(c.task)
	c.task = nil
	cloud_result_destroy(&c.result)
	cloud_store_destroy(&c.store)
	delete(c.path)
	c.path = ""
}

@(private)
cloud_set_status :: proc(c: ^Cloud, text: string) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	n := min(len(text), len(c.status_buf))
	for i in 0 ..< n {
		c.status_buf[i] = text[i]
	}
	c.status_len = n
}

@(private)
cloud_set_error :: proc(c: ^Cloud, text: string) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	n := min(len(text), len(c.error_buf))
	for i in 0 ..< n {
		c.error_buf[i] = text[i]
	}
	c.error_len = n
}

@(private)
cloud_clear_error :: proc(c: ^Cloud) {
	sync.mutex_lock(&c.mutex)
	c.error_len = 0
	sync.mutex_unlock(&c.mutex)
}

cloud_is_busy :: proc(c: ^Cloud) -> bool {
	return sync.atomic_load(&c.busy) != 0
}

cloud_is_connected :: proc(c: ^Cloud) -> bool {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return cloud_connected(&c.store)
}

cloud_client_credentials :: proc(c: ^Cloud) -> (id, secret: string) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return strings.clone(c.store.client_id), strings.clone(c.store.client_secret)
}

cloud_set_client :: proc(c: ^Cloud, id, secret, folder: string) -> bool {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	delete(c.store.client_id)
	delete(c.store.client_secret)
	delete(c.store.folder_name)
	c.store.client_id = strings.clone(strings.trim_space(id))
	c.store.client_secret = strings.clone(strings.trim_space(secret))
	folder_name := strings.trim_space(folder)
	if folder_name == "" {
		folder_name = CLOUD_ROOT_NAME
	}
	c.store.folder_name = strings.clone(folder_name)
	return cloud_store_save(c.path, &c.store)
}

@(private)
cloud_start :: proc(c: ^Cloud, task: ^Cloud_Task) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		cloud_task_destroy(task)
		return false
	}
	cloud_clear_error(c)
	sync.atomic_store(&c.done, 0)
	sync.atomic_store(&c.progress_done, 0)
	sync.atomic_store(&c.progress_total, 0)
	c.kind = task.kind
	task.cloud = c
	th := thread.create(cloud_worker)
	if th == nil {
		cloud_task_destroy(task)
		return false
	}
	th.data = task
	c.task = task
	c.thread = th
	sync.atomic_store(&c.busy, 1)
	thread.start(th)
	return true
}

cloud_start_connect :: proc(c: ^Cloud) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		return false
	}
	task := new(Cloud_Task)
	task.kind = .Connect
	cloud_set_status(c, "waiting for Google sign-in")
	return cloud_start(c, task)
}

cloud_start_disconnect :: proc(c: ^Cloud) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		return false
	}
	task := new(Cloud_Task)
	task.kind = .Disconnect
	cloud_set_status(c, "disconnecting")
	return cloud_start(c, task)
}

cloud_start_list :: proc(c: ^Cloud) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		return false
	}
	task := new(Cloud_Task)
	task.kind = .List
	cloud_set_status(c, "loading cloud projects")
	return cloud_start(c, task)
}

cloud_start_backup :: proc(c: ^Cloud, session_dir, project_name: string, takes: []string) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		return false
	}
	task := new(Cloud_Task)
	task.kind = .Backup
	task.session_dir = strings.clone(session_dir)
	task.project_name = strings.clone(project_name)
	task.takes = make([]string, len(takes))
	for name, i in takes {
		task.takes[i] = strings.clone(name)
	}
	cloud_set_status(c, "preparing backup")
	return cloud_start(c, task)
}

cloud_start_restore :: proc(c: ^Cloud, project_id, save_root: string) -> bool {
	if c.thread != nil || cloud_is_busy(c) {
		return false
	}
	task := new(Cloud_Task)
	task.kind = .Restore
	task.project_id = strings.clone(project_id)
	task.save_root = strings.clone(save_root)
	cloud_set_status(c, "preparing restore")
	return cloud_start(c, task)
}

// ---------------------------------------------------------------- worker

@(private)
cloud_worker :: proc(t: ^thread.Thread) {
	task := cast(^Cloud_Task)t.data
	if task == nil || task.cloud == nil {
		return
	}
	cloud_run(task)
	sync.atomic_store(&task.cloud.busy, 0)
	sync.atomic_store(&task.cloud.done, 1)
}

@(private)
cloud_run :: proc(task: ^Cloud_Task) {
	c := task.cloud
	switch task.kind {
	case .Connect:
		cloud_job_connect(c)
	case .Disconnect:
		cloud_job_disconnect(c)
	case .List:
		cloud_job_list(c)
	case .Backup:
		cloud_job_backup(c, task)
	case .Restore:
		cloud_job_restore(c, task)
	case .None:
	}
}

// Network work happens on a store snapshot; the UI-side mutex is never held
// while curl or the browser is waiting.
@(private)
cloud_store_snapshot :: proc(c: ^Cloud) -> Cloud_Store {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return cloud_store_clone(&c.store)
}

@(private)
cloud_store_publish :: proc(c: ^Cloud, store: ^Cloud_Store) -> bool {
	sync.mutex_lock(&c.mutex)
	cloud_store_commit(&c.store, store)
	sync.mutex_unlock(&c.mutex)
	return cloud_store_save(c.path, &c.store)
}

@(private)
cloud_token_for_job :: proc(c: ^Cloud, token_out: ^string) -> (ok: bool, err: string) {
	local := cloud_store_snapshot(c)
	defer cloud_store_destroy(&local)
	ok, err = cloud_ensure_token(&local)
	if !ok {
		if strings.contains(err, "session expired") {
			delete(local.access_token)
			local.access_token = ""
			delete(local.refresh_token)
			local.refresh_token = ""
			local.expires_unix = 0
			_ = cloud_store_publish(c, &local)
		}
		return false, err
	}
	if !cloud_store_publish(c, &local) {
		return false, "cannot save cloud.json"
	}
	sync.mutex_lock(&c.mutex)
	token_out^ = strings.clone(c.store.access_token)
	sync.mutex_unlock(&c.mutex)
	return true, ""
}

@(private)
cloud_job_connect :: proc(c: ^Cloud) {
	local := cloud_store_snapshot(c)
	defer cloud_store_destroy(&local)
	ok, err := cloud_oauth_login(&local)
	if !ok {
		cloud_set_error(c, err)
		cloud_set_status(c, "not connected")
		return
	}
	if !cloud_store_publish(c, &local) {
		cloud_set_error(c, "cannot save cloud.json")
		return
	}
	cloud_set_status(c, "Google Drive connected")
	sync.mutex_lock(&c.mutex)
	c.result.last_sync = c.store.last_sync
	sync.mutex_unlock(&c.mutex)
}

@(private)
cloud_job_disconnect :: proc(c: ^Cloud) {
	local := cloud_store_snapshot(c)
	cloud_revoke_token(&local)
	_ = cloud_store_publish(c, &local)
	cloud_store_destroy(&local)
	cloud_set_status(c, "Google Drive disconnected")
}

@(private)
cloud_root_for_job :: proc(c: ^Cloud, token: string) -> (root: string, ok: bool, err: string) {
	sync.mutex_lock(&c.mutex)
	name := strings.clone(cloud_folder_name(&c.store))
	sync.mutex_unlock(&c.mutex)
	defer delete(name)
	root, ok = cloud_drive_root(token, name, &err)
	return
}

@(private)
cloud_job_list :: proc(c: ^Cloud) {
	token: string
	token_ok, token_err := cloud_token_for_job(c, &token)
	defer delete(token)
	if !token_ok {
		cloud_set_error(c, token_err)
		cloud_set_status(c, "not connected")
		return
	}
	root, root_ok, root_err := cloud_root_for_job(c, token)
	defer delete(root)
	if !root_ok {
		cloud_set_error(c, root_err)
		return
	}
	err := ""
	index, ok := cloud_index_load(token, root, &err)
	defer cloud_index_destroy(&index)
	if !ok {
		cloud_set_error(c, err)
		return
	}
	projects := make([]Cloud_Project, len(index.projects))
	for e, i in index.projects {
		projects[i] = Cloud_Project {
			id       = strings.clone(e.id),
			name     = strings.clone(e.name),
			modified = e.modified,
			bytes    = e.bytes,
			files    = e.files,
		}
	}
	sync.mutex_lock(&c.mutex)
	cloud_result_destroy(&c.result)
	c.result.projects = projects
	sync.mutex_unlock(&c.mutex)
	cloud_set_status(c, fmt.tprintf("%d cloud project%s", len(projects), "" if len(projects) == 1 else "s"))
}

@(private)
cloud_job_backup :: proc(c: ^Cloud, task: ^Cloud_Task) {
	token: string
	token_ok, token_err := cloud_token_for_job(c, &token)
	defer delete(token)
	if !token_ok {
		cloud_set_error(c, token_err)
		return
	}
	id, id_ok := cloud_session_id(task.session_dir)
	defer delete(id)
	if !id_ok {
		cloud_set_error(c, "cannot create a cloud project id")
		return
	}
	files := cloud_collect_files(task.session_dir, task.takes)
	defer cloud_files_free(files)
	if len(files) == 0 {
		cloud_set_error(c, "nothing to back up")
		return
	}

	api_err := ""
	root, root_ok, root_err := cloud_root_for_job(c, token)
	defer delete(root)
	if !root_ok {
		cloud_set_error(c, root_err)
		return
	}
	projects_folder, p_ok := cloud_drive_ensure_folder(token, "projects", root, &api_err)
	defer delete(projects_folder)
	if !p_ok {
		cloud_set_error(c, api_err)
		return
	}
	entry_name := strings.trim_space(task.project_name)
	if entry_name == "" {
		entry_name = "untitled"
	}
	safe_name := cloud_sanitize_name(entry_name)
	defer delete(safe_name)
	short_id := cloud_short_id(id)
	defer delete(short_id)
	remote_folder_name := fmt.aprintf("%s-%s", safe_name, short_id)
	defer delete(remote_folder_name)
	folder, f_ok := cloud_drive_ensure_folder(token, remote_folder_name, projects_folder, &api_err)
	defer delete(folder)
	if !f_ok {
		cloud_set_error(c, api_err)
		return
	}

	total := u64(0)
	for path in files {
		if info, stat_err := os.stat(path, context.allocator); stat_err == nil {
			total += u64(max(info.size, 0))
			os.file_info_delete(info, context.allocator)
		}
	}
	sync.atomic_store(&c.progress_total, u64(len(files)))
	for path, i in files {
		name := path[strings.last_index_byte(path, '/') + 1:]
		sync.atomic_store(&c.progress_done, u64(i))
		cloud_set_status(c, fmt.tprintf("uploading %d/%d · %s", i + 1, len(files), name))
		existing, _ := cloud_drive_find(token, folder, name, false, &api_err)
		if api_err != "" {
			cloud_set_error(c, api_err)
			return
		}
		upload_ok, upload_err := cloud_drive_upload(token, path, name, folder, existing, nil)
		delete(existing)
		if !upload_ok {
			cloud_set_error(c, upload_err)
			delete(upload_err)
			return
		}
	}
	sync.atomic_store(&c.progress_done, u64(len(files)))

	err := ""
	index, index_ok := cloud_index_load(token, root, &err)
	defer cloud_index_destroy(&index)
	if !index_ok {
		cloud_set_error(c, err)
		return
	}
	entry := Cloud_Index_Entry {
		id        = strings.clone(id),
		folder_id = strings.clone(folder),
		name      = strings.clone(entry_name),
		modified  = cloud_now(),
		bytes     = total,
		files     = len(files),
	}
	cloud_index_merge(&index, entry)
	save_ok, save_err := cloud_index_save(token, root, &index)
	if !save_ok {
		cloud_set_error(c, save_err)
		delete(save_err)
		return
	}
	sync.mutex_lock(&c.mutex)
	c.store.last_sync = cloud_now()
	_ = cloud_store_save(c.path, &c.store)
	c.result.last_sync = c.store.last_sync
	sync.mutex_unlock(&c.mutex)
	size_text := cloud_format_bytes(total)
	defer delete(size_text)
	cloud_set_status(c, fmt.tprintf("backed up %d files · %s", len(files), size_text))
}

@(private)
cloud_job_restore :: proc(c: ^Cloud, task: ^Cloud_Task) {
	token: string
	token_ok, token_err := cloud_token_for_job(c, &token)
	defer delete(token)
	if !token_ok {
		cloud_set_error(c, token_err)
		return
	}
	root, root_ok, root_err := cloud_root_for_job(c, token)
	defer delete(root)
	if !root_ok {
		cloud_set_error(c, root_err)
		return
	}
	err := ""
	index, index_ok := cloud_index_load(token, root, &err)
	defer cloud_index_destroy(&index)
	if !index_ok {
		cloud_set_error(c, err)
		return
	}
	entry: ^Cloud_Index_Entry
	for &e in index.projects {
		if e.id == task.project_id {
			entry = &e
			break
		}
	}
	if entry == nil {
		cloud_set_error(c, "cloud project not found")
		return
	}

	files, list_err := cloud_drive_list(token, entry.folder_id, CLOUD_APP_QUERY, 1000)
	defer cloud_drive_files_destroy(files)
	if list_err != "" {
		cloud_set_error(c, list_err)
		delete(list_err)
		return
	}
	has_project := false
	for f in files {
		if f.name == "project.json" {
			has_project = true
		}
	}
	if !has_project {
		cloud_set_error(c, "cloud project has no project.json")
		return
	}
	for f, i in files {
		for other in files[i + 1:] {
			if f.name == other.name {
				cloud_set_error(c, fmt.tprintf("cloud project has duplicate file names: %s", f.name))
				return
			}
		}
	}

	name := cloud_sanitize_name(entry.name)
	defer delete(name)
	short := cloud_short_id(entry.id)
	defer delete(short)
	base := fmt.aprintf("%s-%s", name, short)
	defer delete(base)
	final := cloud_unique_dir(task.save_root, base)
	defer delete(final)
	if final == "" {
		cloud_set_error(c, "cannot find a free restore folder")
		return
	}
	// Never reuse a name that already exists: a failed restore must not touch
	// an unrelated local folder. The scratch path is freshly generated and is
	// the only path this job is allowed to remove on failure.
	partial := cloud_partial_dir(final)
	defer delete(partial)
	if partial == "" || !ensure_dir(partial) {
		cloud_set_error(c, "cannot create the restore folder")
		return
	}
	success := false
	defer if !success {
		_ = os.remove_all(partial)
	}

	sync.atomic_store(&c.progress_total, u64(len(files)))
	for f, i in files {
		if !cloud_safe_file_name(f.name) {
			continue
		}
		sync.atomic_store(&c.progress_done, u64(i))
		cloud_set_status(c, fmt.tprintf("downloading %d/%d · %s", i + 1, len(files), f.name))
		out := fmt.aprintf("%s/%s", partial, f.name)
		defer delete(out)
		ok, derr := cloud_drive_download(token, f.id, out)
		if !ok {
			cloud_set_error(c, derr)
			delete(derr)
			return
		}
	}
	if rerr := os.rename(partial, final); rerr != nil {
		cloud_set_error(c, "cannot move the restored project into place")
		return
	}
	success = true
	sync.mutex_lock(&c.mutex)
	cloud_result_destroy(&c.result)
	c.result.restored = strings.clone(final)
	sync.mutex_unlock(&c.mutex)
	cloud_set_status(c, "project restored")
}

// ---------------------------------------------------------------- UI bridge

@(private)
cloud_copy_buf :: proc(dst: []u8, len_out: ^int, src: string) {
	n := min(len(src), len(dst))
	for i in 0 ..< n {
		dst[i] = src[i]
	}
	len_out^ = n
}

// Copies worker state into the App and handles a finished job. Called once per
// frame from the window loop on the UI thread.
cloud_sync_ui :: proc(c: ^Cloud, a: ^ui.App, e: ^Engine, recent_store: string) {
	if c == nil || a == nil {
		return
	}
	sync.mutex_lock(&c.mutex)
	connected := cloud_connected(&c.store)
	status := string(c.status_buf[:c.status_len])
	error_text := string(c.error_buf[:c.error_len])
	ui.app_set_cloud_status(a, status, error_text, connected)
	a.cloud_last_sync = c.store.last_sync
	if a.cloud_edit == .None && !a.cloud_dirty {
		ui.app_set_cloud_credentials(a, c.store.client_id, c.store.client_secret, cloud_folder_name(&c.store))
	}
	sync.mutex_unlock(&c.mutex)
	a.cloud_busy = cloud_is_busy(c)
	a.cloud_progress_done = int(sync.atomic_load(&c.progress_done))
	a.cloud_progress_total = int(sync.atomic_load(&c.progress_total))

	if sync.atomic_load(&c.done) == 0 {
		return
	}
	if c.thread != nil {
		thread.destroy(c.thread)
		c.thread = nil
	}
	kind := c.kind
	result: Cloud_Result
	sync.mutex_lock(&c.mutex)
	result = c.result
	c.result = {}
	final_status := string(c.status_buf[:c.status_len])
	final_error := string(c.error_buf[:c.error_len])
	sync.mutex_unlock(&c.mutex)

	cloud_task_destroy(c.task)
	c.task = nil
	sync.atomic_store(&c.done, 0)
	sync.atomic_store(&c.busy, 0)
	a.cloud_busy = false
	ui.app_set_cloud_status(a, final_status, final_error, cloud_is_connected(c))

	if final_error != "" {
		ui.app_cloud_failed(a, final_error)
	} else {
		switch kind {
		case .Connect:
			ui.app_cloud_connected(a, result.last_sync)
		case .Disconnect:
			ui.app_cloud_disconnected(a)
		case .List:
			views := cloud_projects_view(result.projects)
			ui.app_set_cloud_projects(a, views)
			delete(views)
			ui.status_buf_set(a, final_status)
		case .Backup:
			ui.app_cloud_backed_up(a, result.last_sync)
			ui_add_recent(a, e.project_path, recent_store)
		case .Restore:
			if result.restored != "" {
				if engine_open_project(a, e, fmt.tprintf("%s/project.json", result.restored)) {
					ui.app_set_save_dir(a, e.session_dir)
					ui.app_set_settings_path(a, e.session_dir)
					ui.app_mark_settings_dirty(a)
					ui_add_recent(a, e.project_path, recent_store)
					ui.app_cloud_restored(a)
				} else {
					ui.app_cloud_failed(a, "restored files but could not open the project")
				}
			}
		case .None:
		}
	}
	cloud_result_destroy(&result)
}

// The App stores a fixed-size view, so copy before freeing the worker result.
@(private)
cloud_projects_view :: proc(projects: []Cloud_Project) -> []ui.Cloud_Project_View {
	views := make([]ui.Cloud_Project_View, len(projects))
	for p, i in projects {
		views[i].modified = p.modified
		views[i].bytes = p.bytes
		views[i].files = p.files
		ui.Cloud_View_Set(&views[i], p.id, p.name)
	}
	return views
}
