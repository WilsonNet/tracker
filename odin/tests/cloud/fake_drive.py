#!/usr/bin/env python3
"""Tiny fake of the Google Drive v3 surface used by Tracker's cloud tests.

It deliberately records DELETE calls instead of implementing them, so the test
can prove the client never asks Drive to remove anything.
"""
import json
import re
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FILES = {}
SESSIONS = {}
NEXT_ID = 1
DELETES = 0
METHODS = []


def new_id(prefix="file"):
    global NEXT_ID
    value = f"{prefix}{NEXT_ID}"
    NEXT_ID += 1
    return value


def json_bytes(value):
    return json.dumps(value).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _file_json(self, f):
        return {
            "id": f["id"],
            "name": f["name"],
            "mimeType": f["mimeType"],
            "size": str(len(f.get("content", b""))),
        }

    def do_DELETE(self):
        global DELETES
        DELETES += 1
        METHODS.append("DELETE")
        self._send(405, json_bytes({"error": {"message": "fake drive does not delete"}}))

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        METHODS.append("POST")
        body = self._body()
        if path == "/__echo":
            return self._send(200, body)
        if path == "/__innocent":
            seed = json.loads(body or b"{}")
            fid = new_id("innocent")
            FILES[fid] = {
                "id": fid,
                "name": seed.get("name", "unrelated.txt"),
                "mimeType": "text/plain",
                "parents": [seed.get("parent", "root")],
                "content": seed.get("content", "do not touch").encode(),
                "props": {},
            }
            return self._send(200, json_bytes({"id": fid}))
        if path == "/upload-session":
            sid = secrets.token_hex(8)
            SESSIONS[sid] = {"id": new_id("file")}
            return self._send(200, b"", {"Location": f"http://127.0.0.1:{self.server.server_port}/upload-session/{sid}"})
        if path.endswith("/files") and "uploadType=resumable" in parsed.query:
            meta = json.loads(body or b"{}")
            fid = new_id("file")
            FILES[fid] = {
                "id": fid,
                "name": meta.get("name", "file"),
                "mimeType": meta.get("mimeType", "application/octet-stream"),
                "parents": meta.get("parents", []),
                "content": b"",
                "props": meta.get("appProperties", {}),
            }
            sid = secrets.token_hex(8)
            SESSIONS[sid] = {"id": fid}
            return self._send(200, b"", {"Location": f"http://127.0.0.1:{self.server.server_port}/upload-session/{sid}"})
        if path.endswith("/files"):
            meta = json.loads(body or b"{}")
            fid = new_id("folder")
            FILES[fid] = {
                "id": fid,
                "name": meta.get("name", "folder"),
                "mimeType": meta.get("mimeType", "application/vnd.google-apps.folder"),
                "parents": meta.get("parents", []),
                "content": b"",
                "props": meta.get("appProperties", {}),
            }
            return self._send(200, json_bytes({"id": fid}))
        self._send(404, json_bytes({"error": {"message": "not found"}}))

    def do_PUT(self):
        parsed = urlparse(self.path)
        METHODS.append("PUT")
        if not parsed.path.startswith("/upload-session/"):
            return self._send(404, json_bytes({"error": {"message": "no session"}}))
        sid = parsed.path.rsplit("/", 1)[-1]
        session = SESSIONS.get(sid)
        if not session:
            return self._send(404, json_bytes({"error": {"message": "no session"}}))
        FILES[session["id"]]["content"] = self._body()
        return self._send(200, json_bytes({"id": session["id"]}))

    def do_PATCH(self):
        parsed = urlparse(self.path)
        path = parsed.path
        METHODS.append("PATCH")
        body = self._body()
        if path.startswith("/upload/drive/v3/files/"):
            fid = path.rsplit("/", 1)[-1]
            if fid not in FILES:
                return self._send(404, json_bytes({"error": {"message": "missing file"}}))
            meta = json.loads(body or b"{}")
            if "appProperties" in meta:
                FILES[fid]["props"] = meta["appProperties"]
            sid = secrets.token_hex(8)
            SESSIONS[sid] = {"id": fid}
            return self._send(200, b"", {"Location": f"http://127.0.0.1:{self.server.server_port}/upload-session/{sid}"})
        self._send(404, json_bytes({"error": {"message": "not found"}}))

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        METHODS.append("GET")
        if path == "/__stats":
            return self._send(200, json_bytes({"files": len(FILES), "deletes": DELETES, "methods": METHODS}))
        if path == "/__all":
            return self._send(200, json_bytes({"files": [{
                "id": f["id"], "name": f["name"], "parents": f.get("parents", []),
                "props": f.get("props", {}), "content": f.get("content", b"").decode(errors="replace"),
            } for f in FILES.values()]}))
        if path.startswith("/drive/v3/files/"):
            fid = path.split("/")[4]
            f = FILES.get(fid)
            if not f:
                return self._send(404, json_bytes({"error": {"message": "missing file"}}))
            if parse_qs(parsed.query).get("alt") == ["media"]:
                self.send_response(200)
                self.send_header("Content-Length", str(len(f.get("content", b""))))
                self.send_header("Content-Type", "application/octet-stream")
                self.end_headers()
                self.wfile.write(f.get("content", b""))
                return
            return self._send(200, json_bytes(self._file_json(f)))
        if path == "/drive/v3/files":
            params = parse_qs(parsed.query)
            q = params.get("q", [""])[0]
            parent_match = re.search(r"'([^']+)' in parents", q)
            name_match = re.search(r"name = '([^']*)'", q)
            mime_eq = re.search(r"mimeType = '([^']+)'", q)
            mime_ne = re.search(r"mimeType != '([^']+)'", q)
            marked = "appProperties has" in q
            out = []
            for f in FILES.values():
                if parent_match and parent_match.group(1) not in f.get("parents", []):
                    continue
                if name_match and f["name"] != name_match.group(1).replace("\\'", "'"):
                    continue
                if mime_eq and f["mimeType"] != mime_eq.group(1):
                    continue
                if mime_ne and f["mimeType"] == mime_ne.group(1):
                    continue
                if marked and f.get("props", {}).get("tracker") != "1":
                    continue
                out.append(self._file_json(f))
            return self._send(200, json_bytes({"files": out}))
        self._send(404, json_bytes({"error": {"message": "not found"}}))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8767
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
