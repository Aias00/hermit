#!/usr/bin/env python3
"""Private Hermit diagnostic receiver. Bind only to loopback behind Access.

The exact /diagnostics/v1/batches route uses a per-device bearer credential.
All pairing routes must remain behind Cloudflare Access with origin JWT checks.
No request URLs, headers, tokens or received payloads are written to stdout.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import secrets
import sqlite3
import time
from urllib.parse import urlencode, urlsplit
import uuid

PREFIX = "/diagnostics"
MAX_BODY = 128 * 1024


def identifier(value):
    if not isinstance(value, str): raise ValueError("Invalid identifier")
    return str(uuid.UUID(value))


def validate_batch(value):
    allowed = {"schema", "batchID", "installationID", "createdAt", "appVersion", "appBuild", "osVersion", "events"}
    if not isinstance(value, dict) or set(value) != allowed or type(value["schema"]) is not int or value["schema"] != 1:
        raise ValueError("Invalid schema")
    identifier(value["batchID"]); identifier(value["installationID"])
    datetime.fromisoformat(value["createdAt"].replace("Z", "+00:00"))
    for field in ("appVersion", "appBuild", "osVersion"):
        if not isinstance(value[field], str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,40}", value[field]): raise ValueError("Invalid version")
    if not isinstance(value["events"], list) or not 1 <= len(value["events"]) <= 128: raise ValueError("Invalid events")
    event_keys = {"id", "at", "kind", "connection", "attempt", "route", "phase", "outcome", "code", "value"}
    kinds = {"ssh", "health", "lifecycle", "network", "tailscale"}
    routes = {"direct", "socks5", "cloudflareSSH", "tailcat", "tailscale", "relay"}
    phases = {"transport-validation", "cloudflare-access", "tailcat-credential", "tailscale-account", "relay-credential",
              "ssh-credential", "authentication-method", "transport-dial", "ssh-authentication", "direct-ssh-connect"}
    for event in value["events"]:
        if not isinstance(event, dict) or set(event) - event_keys or not {"id", "at", "kind"} <= set(event): raise ValueError("Invalid event")
        identifier(event["id"])
        datetime.fromisoformat(event["at"].replace("Z", "+00:00"))
        if event["kind"] not in kinds: raise ValueError("Invalid kind")
        for field in ("connection", "attempt"):
            if field in event: identifier(event[field])
        for field, accepted in [("route", routes), ("phase", phases), ("outcome", {"started", "succeeded", "failed"})]:
            if field in event and event[field] not in accepted: raise ValueError("Invalid classifier")
        if "code" in event and (not isinstance(event["code"], str) or not re.fullmatch(r"[a-z][a-z0-9.-]{0,79}", event["code"])):
            raise ValueError("Invalid code")
        if "value" in event and (type(event["value"]) is not int or not 0 <= event["value"] <= 604800): raise ValueError("Invalid value")
    return value


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / "diagnostics.sqlite3"
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, digest TEXT UNIQUE, created REAL,
                    installation TEXT, revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS batches (device TEXT, batch TEXT, received REAL, bytes INTEGER,
                    payload TEXT, PRIMARY KEY (device, batch));
            """)
        self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            db.execute("PRAGMA secure_delete=ON")
            with db: yield db
        finally: db.close()

    def prune(self):
        with self.connect() as db:
            db.execute("DELETE FROM batches WHERE received < ?", (time.time() - 7 * 86400,))
            db.execute("DELETE FROM devices WHERE installation IS NULL AND created < ?", (time.time() - 86400,))

    def revoke(self, device):
        with self.connect() as db: db.execute("UPDATE devices SET revoked=1 WHERE id=?", (identifier(device),))

    def create_device(self):
        now = time.time()
        token = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("DELETE FROM devices WHERE installation IS NULL AND created < ?", (now - 86400,))
            if db.execute("SELECT COUNT(*) FROM devices WHERE revoked = 0").fetchone()[0] >= 100: raise ValueError("Device limit")
            db.execute("INSERT INTO devices(id,digest,created) VALUES(?,?,?)", (str(uuid.uuid4()), hashlib.sha256(token.encode()).hexdigest(), now))
        return token

    def device(self, token):
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token): return None
        with self.connect() as db:
            row = db.execute("SELECT id,installation,created FROM devices WHERE digest=? AND revoked=0", (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if row is None or (row[1] is None and row[2] < time.time() - 86400): return None
        return row[0]

    def accept(self, device, value, size):
        now = time.time(); installation = identifier(value["installationID"]); batch = identifier(value["batchID"])
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT installation FROM devices WHERE id=? AND revoked=0", (device,)).fetchone()
            if row is None or (row[0] is not None and row[0] != installation): raise PermissionError("Device binding mismatch")
            db.execute("DELETE FROM batches WHERE received < ?", (now - 7 * 86400,))
            if db.execute("SELECT 1 FROM batches WHERE device=? AND batch=?", (device, batch)).fetchone(): return batch
            daily = db.execute("SELECT COALESCE(SUM(bytes),0) FROM batches WHERE device=? AND received>=?", (device, int(now / 86400) * 86400)).fetchone()[0]
            if daily + size > 2 * 1024 * 1024: raise OverflowError("Daily limit")
            db.execute("UPDATE devices SET installation=? WHERE id=?", (installation, device))
            db.execute("INSERT INTO batches VALUES(?,?,?,?,?)", (device, batch, now, size, json.dumps(value, separators=(",", ":"))))
        return batch


def handler(store, origin, require_access=True):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def setup(self):
            super().setup(); self.connection.settimeout(10)

        def reply(self, status, body, kind="application/json"):
            if not isinstance(body, bytes): body = json.dumps(body).encode()
            self.send_response(status); self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers(); self.wfile.write(body)

        def access(self): return not require_access or bool(self.headers.get("Cf-Access-Jwt-Assertion"))

        def page(self, link=None):
            content = ("<p>在这台 iPhone 上点击后，Hermit 会显示接收地址及采集范围，确认后才开始上报。</p><p><a href=\"" + html.escape(link, quote=True) + "\">在 Hermit 中配置诊断上报</a></p><p>请勿分享本页中的设备配置链接。首次启用须在 24 小时内完成。</p>" if link else
                       '<p>为当前设备生成专用凭据。仅上报 Hermit 的结构化诊断，不包含终端正文或 SSH 凭据。</p><form method="post" action="/diagnostics/pair"><button>生成当前设备配置</button></form>')
            return ("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Hermit 诊断配置</title><style>body{font:17px/1.7 system-ui;max-width:640px;margin:48px auto;padding:20px}button,a{font:inherit}a{overflow-wrap:anywhere}</style><h1>Hermit 诊断上报</h1>" + content).encode()

        def do_GET(self):
            if urlsplit(self.path).path != PREFIX + "/setup": self.reply(404, {"error": "not_found"}); return
            if not self.access(): self.reply(403, {"error": "access_required"}); return
            self.reply(200, self.page(), "text/html; charset=utf-8")

        def do_POST(self):
            route = urlsplit(self.path).path
            if route == PREFIX + "/pair":
                if not self.access() or self.headers.get("Origin") != origin:
                    self.reply(403, {"error": "access_required"}); return
                try:
                    token = store.create_device()
                    link = "hermit-diagnostics://diagnostics/configure?" + urlencode({"endpoint": origin + PREFIX + "/v1/batches", "token": token})
                    self.reply(200, self.page(link), "text/html; charset=utf-8")
                except ValueError: self.reply(429, {"error": "device_limit"})
                return
            if route != PREFIX + "/v1/batches": self.reply(404, {"error": "not_found"}); return
            authorization = self.headers.get("Authorization", "")
            device = store.device(authorization.removeprefix("Bearer ")) if authorization.startswith("Bearer ") else None
            if device is None: self.reply(401, {"error": "device_auth_required"}); return
            try:
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 < length <= MAX_BODY or self.headers.get("Transfer-Encoding"):
                    self.reply(413, {"error": "invalid_size"}); return
                if self.headers.get("Content-Type", "").split(";", 1)[0] != "application/json":
                    self.reply(415, {"error": "json_required"}); return
                data = self.rfile.read(length)
                if len(data) != length: raise ValueError("Incomplete body")
                value = validate_batch(json.loads(data))
                accepted = store.accept(device, value, len(data))
                self.reply(202, {"acceptedBatchID": accepted})
            except PermissionError: self.reply(403, {"error": "device_binding_mismatch"})
            except OverflowError: self.reply(429, {"error": "daily_limit"})
            except (ValueError, TypeError, KeyError, AttributeError): self.reply(400, {"error": "invalid_batch"})
            except (TimeoutError, ConnectionError): pass
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--origin")
    parser.add_argument("--port", type=int, default=18750)
    parser.add_argument("--revoke-device", help="Revoke a device UUID without starting the server")
    args = parser.parse_args()
    store = Store(args.state_dir)
    if args.revoke_device: store.revoke(args.revoke_device); return
    if not args.origin: parser.error("--origin is required when serving")
    origin = urlsplit(args.origin)
    if origin.scheme != "https" or not origin.hostname or origin.path or origin.query or origin.fragment or origin.username:
        parser.error("--origin must be an HTTPS origin")
    class Server(ThreadingHTTPServer):
        last_prune = 0
        def service_actions(self):
            if time.monotonic() - self.last_prune > 60:
                store.prune(); self.last_prune = time.monotonic()
    server = Server(("127.0.0.1", args.port), handler(store, args.origin))
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__": main()
