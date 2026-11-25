// Google OAuth 2.0 for installed apps: loopback redirect + PKCE.
//
// The browser talks to a one-shot HTTP listener on 127.0.0.1. Only the code is
// accepted; the state parameter must match. Tokens never travel through argv.

package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

@(private)
cloud_oauth_html :: proc(ok: bool, detail: string) -> string {
	title := "Tracker-FX connected" if ok else "Tracker-FX could not connect"
	body := "You can close this window and return to Tracker-FX." if ok else detail
	return fmt.aprintf(
		"<!doctype html><meta charset=utf-8><title>%s</title><body style=\"background:#121212;color:#eee;font:16px monospace;padding:3rem\"><h1 style=\"color:#e8a33d;font-size:1.4rem\">%s</h1><p>%s</p></body>",
		title, title, body,
	)
}

@(private)
cloud_send_http :: proc(client: net.TCP_Socket, status: string, body: string) {
	head := fmt.aprintf("HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: %d\r\n\r\n", status, len(body))
	_, _ = net.send_tcp(client, transmute([]u8)head)
	_, _ = net.send_tcp(client, transmute([]u8)body)
	delete(head)
}

// Opens a URL with the desktop's browser helper. Returns false when no helper
// exists; the caller turns that into a clear status message.
cloud_open_url :: proc(url: string) -> bool {
	return platform_open_url(url)
}

@(private)
cloud_query_value :: proc(query, key: string) -> (string, bool) {
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		if eq <= 0 {
			continue
		}
		if pair[:eq] == key {
			value := cloud_url_decode(pair[eq + 1:])
			return value, true
		}
	}
	return "", false
}

// Waits for the browser redirect and returns the authorization code. The
// listener is non-blocking so a timed-out or cancelled login cannot wedge the
// cloud worker forever.
@(private)
cloud_wait_for_code :: proc(listener: net.TCP_Socket, expected_state: string) -> (code: string, ok: bool, err: string) {
	defer net.close(listener)
	_ = net.set_blocking(listener, false)
	start := time.now()
	for time.duration_seconds(time.since(start)) < CLOUD_OAUTH_TIMEOUT_SECONDS {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			if aerr == .Would_Block || aerr == .Timeout {
				time.sleep(30 * time.Millisecond)
				continue
			}
			return "", false, fmt.tprintf("OAuth listener failed: %v", aerr)
		}
		_ = net.set_blocking(client, true)
		buf: [8192]u8
		n, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || n <= 0 {
			net.close(client)
			continue
		}
		request := string(buf[:n])
		line_end := strings.index(request, "\r\n")
		line := request if line_end < 0 else request[:line_end]
		parts := strings.split(line, " ")
		defer delete(parts)
		if len(parts) < 2 || parts[1] == "/favicon.ico" {
			cloud_send_http(client, "404 Not Found", "Not found")
			net.close(client)
			continue
		}
		path := parts[1]
		qpos := strings.index_byte(path, '?')
		query := path[qpos + 1:] if qpos >= 0 else ""
		if gerror, has_error := cloud_query_value(query, "error"); has_error {
			cloud_send_http(client, "200 OK", cloud_oauth_html(false, gerror))
			net.close(client)
			delete(gerror)
			return "", false, "Google authorization was cancelled"
		}
		got_state, has_state := cloud_query_value(query, "state")
		if !has_state || got_state != expected_state {
			cloud_send_http(client, "400 Bad Request", cloud_oauth_html(false, "State mismatch. Return to Tracker-FX and try again."))
			net.close(client)
			delete(got_state)
			return "", false, "OAuth state mismatch"
		}
		delete(got_state)
		got_code, has_code := cloud_query_value(query, "code")
		if !has_code || got_code == "" {
			cloud_send_http(client, "400 Bad Request", cloud_oauth_html(false, "No authorization code was returned."))
			net.close(client)
			delete(got_code)
			continue
		}
		cloud_send_http(client, "200 OK", cloud_oauth_html(true, ""))
		net.close(client)
		return got_code, true, ""
	}
	return "", false, "Google authorization timed out"
}

@(private)
cloud_form_body :: proc(values: [][2]string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for pair, i in values {
		if i > 0 {
			strings.write_byte(&b, '&')
		}
		strings.write_string(&b, pair[0])
		strings.write_byte(&b, '=')
		enc := cloud_url_encode(pair[1])
		strings.write_string(&b, enc)
		delete(enc)
	}
	return strings.clone(strings.to_string(b))
}

@(private)
cloud_token_request :: proc(body: string) -> (token: Cloud_Token, ok: bool, err: string) {
	dir := cloud_temp_dir()
	defer delete(dir)
	path := cloud_write_temp(dir, "token", transmute([]u8)body)
	if path == "" {
		return token, false, "cannot prepare token request"
	}
	defer delete(path)
	defer os.remove(path)
	res := cloud_curl_request(
		"POST", CLOUD_OAUTH_TOKEN,
		[]string{"Content-Type: application/x-www-form-urlencoded"},
		body_file = path, max_time = 60,
	)
	defer cloud_curl_destroy(&res)
	if !res.ok {
		err = cloud_error_text(&res)
		return token, false, err
	}
	if uerr := json_unmarshal(res.out, &token); uerr != "" {
		return token, false, uerr
	}
	if token.access_token == "" {
		reason := token.error_description if token.error_description != "" else token.error
		if reason == "" {
			reason = "token response did not include an access token"
		}
		cloud_token_destroy(&token)
		return Cloud_Token{}, false, reason
	}
	return token, true, ""
}

// Local wrapper so this file does not need the json import just for one call.
@(private)
json_unmarshal :: proc(data: []u8, token: ^Cloud_Token) -> string {
	// Declared here to keep the OAuth file focused; the actual decoder lives in
	// cloud.odin's JSON types.
	return cloud_json_token(data, token)
}

cloud_oauth_login :: proc(store: ^Cloud_Store) -> (ok: bool, err: string) {
	if !cloud_has_credentials(store) {
		return false, "Set the Google Client ID and Client secret first"
	}
	verifier, challenge := cloud_pkce()
	defer delete(verifier)
	defer delete(challenge)
	state := cloud_state()
	defer delete(state)

	ep := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, lerr := net.listen_tcp(ep, 4)
	if lerr != nil {
		return false, fmt.tprintf("cannot reserve an OAuth port: %v", lerr)
	}
	bound, berr := net.bound_endpoint(listener)
	if berr != nil || bound.port <= 0 {
		net.close(listener)
		return false, "cannot determine the OAuth callback port"
	}
	redirect := fmt.aprintf("http://127.0.0.1:%d", bound.port)
	defer delete(redirect)
	url := cloud_oauth_url(store.client_id, redirect, challenge, state)
	defer delete(url)
	if !cloud_open_url(url) {
		net.close(listener)
		return false, "cannot open a browser for Google sign-in"
	}
	code, wait_ok, wait_err := cloud_wait_for_code(listener, state)
	if !wait_ok {
		return false, wait_err
	}
	defer delete(code)

	body := cloud_form_body([][2]string{
		{"client_id", store.client_id},
		{"client_secret", store.client_secret},
		{"code", code},
		{"grant_type", "authorization_code"},
		{"redirect_uri", redirect},
		{"code_verifier", verifier},
	})
	defer delete(body)
	token, tok_ok, tok_err := cloud_token_request(body)
	defer cloud_token_destroy(&token)
	if !tok_ok {
		return false, tok_err
	}
	cloud_apply_token(store, &token)
	store.last_sync = cloud_now()
	return true, ""
}

cloud_apply_token :: proc(store: ^Cloud_Store, token: ^Cloud_Token) {
	delete(store.access_token)
	store.access_token = strings.clone(token.access_token)
	if token.refresh_token != "" {
		delete(store.refresh_token)
		store.refresh_token = strings.clone(token.refresh_token)
	}
	expires := token.expires_in
	if expires <= 0 {
		expires = 3000
	}
	store.expires_unix = cloud_now() + expires
}

cloud_refresh_token :: proc(store: ^Cloud_Store) -> (ok: bool, err: string) {
	if store.refresh_token == "" {
		return false, "Google Drive is not connected"
	}
	body := cloud_form_body([][2]string{
		{"client_id", store.client_id},
		{"client_secret", store.client_secret},
		{"refresh_token", store.refresh_token},
		{"grant_type", "refresh_token"},
	})
	defer delete(body)
	token, tok_ok, tok_err := cloud_token_request(body)
	defer cloud_token_destroy(&token)
	if !tok_ok {
		if strings.contains(tok_err, "invalid_grant") || strings.contains(tok_err, "expired") || strings.contains(tok_err, "revoked") {
			return false, "Google Drive session expired — reconnect"
		}
		return false, tok_err
	}
	cloud_apply_token(store, &token)
	return true, ""
}

cloud_ensure_token :: proc(store: ^Cloud_Store) -> (ok: bool, err: string) {
	if cloud_token_valid(store, cloud_now()) {
		return true, ""
	}
	if store.access_token == "" && store.refresh_token == "" {
		return false, "Google Drive is not connected"
	}
	return cloud_refresh_token(store)
}

cloud_revoke_token :: proc(store: ^Cloud_Store) {
	if store.refresh_token != "" {
		body := cloud_form_body([][2]string{{"token", store.refresh_token}})
		defer delete(body)
		dir := cloud_temp_dir()
		defer delete(dir)
		path := cloud_write_temp(dir, "revoke", transmute([]u8)body)
		if path != "" {
			res := cloud_curl_request(
				"POST", CLOUD_OAUTH_REVOKE,
				[]string{"Content-Type: application/x-www-form-urlencoded"},
				body_file = path, max_time = 30,
			)
			cloud_curl_destroy(&res)
			os.remove(path)
			delete(path)
		}
	}
	delete(store.access_token)
	store.access_token = ""
	delete(store.refresh_token)
	store.refresh_token = ""
	store.expires_unix = 0
}
