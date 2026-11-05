#!/usr/bin/env python3
"""Serve one selected IPA on loopback, behind Tailscale Serve or Access.

Optional OTA links expire after ten minutes and are bound to this exact IPA.
Only the ticket routes can bypass browser login; issuance stays private.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import time
from urllib.parse import quote, urlsplit
import zipfile


ASSETS = Path(__file__).with_name("private-download")


def inspect_package(path, source_commit, notes):
    path = Path(path).resolve(strict=True)
    if path.suffix != ".ipa" or not path.is_file():
        raise ValueError("Select an IPA file")
    with zipfile.ZipFile(path) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1 or archive.getinfo(names[0]).file_size > 1_000_000:
            raise ValueError("IPA must contain exactly one application Info.plist")
        info = plistlib.loads(archive.read(names[0]))
        stamp = re.match(r"^([0-9a-f]{7,40})(?:\s|$)", str(info.get("MoshpitBuildStamp", "")))
        if stamp and not source_commit.startswith(stamp.group(1)):
            raise ValueError("Source SHA does not match the package build stamp")
        profile_name = names[0].removesuffix("Info.plist") + "embedded.mobileprovision"
        profile = None
        if profile_name in archive.namelist():
            if archive.getinfo(profile_name).file_size > 1_000_000:
                raise ValueError("Provisioning profile is too large")
            result = subprocess.run(["security", "cms", "-D"], input=archive.read(profile_name),
                                    capture_output=True, timeout=10, check=True)
            profile = plistlib.loads(result.stdout)
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(256 * 1024), b""):
            checksum.update(block)
    digest = checksum.hexdigest()
    kind = "unsigned"
    expires = None
    if profile:
        kind = "development" if profile.get("Entitlements", {}).get("get-task-allow") else "distribution"
        if isinstance(profile.get("ExpirationDate"), datetime):
            expires = profile["ExpirationDate"].replace(tzinfo=timezone.utc).isoformat()
    return {
        "name": info.get("CFBundleDisplayName", "Hermit"),
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "minimumOS": info.get("MinimumOSVersion", "18.0"),
        "size": path.stat().st_size, "sha256": digest, "sourceCommit": source_commit,
        "signing": kind, "profileExpiresAt": expires, "notes": notes,
        "download": "/Hermit.ipa", "overTheAirInstall": False,
    }


class InstallFlow:
    lifetime = 600

    def __init__(self, origin, release, clock=time.time):
        url = urlsplit(origin)
        if url.scheme != "https" or not url.hostname or url.username or url.password \
                or url.path not in ("", "/") or url.query or url.fragment:
            raise ValueError("OTA origin must be an HTTPS origin without a path")
        self.origin = "https://" + url.netloc
        self.release = release
        self.clock = clock
        # Restarting the server invalidates all previously issued links.
        self.key = secrets.token_bytes(32)

    @property
    def available(self):
        expiry = self.release.get("profileExpiresAt")
        return self.release["signing"] in ("development", "distribution") and bool(expiry) \
            and datetime.fromisoformat(expiry).timestamp() > self.clock()

    def token(self, expiry, nonce, resource):
        message = f"{self.release['sha256']}:{expiry}:{nonce}:{resource}".encode()
        signature = hmac.new(self.key, message, hashlib.sha256).hexdigest()
        return f"{expiry}.{nonce}.{signature}"

    def validate(self, token, resource):
        match = re.fullmatch(r"([0-9]{10,12})\.([A-Za-z0-9_-]{24})\.([a-f0-9]{64})", token)
        if not match or not self.available:
            return None
        expiry, nonce, _ = match.groups()
        expiry = int(expiry)
        if not 0 < expiry - self.clock() <= self.lifetime:
            return None
        if not hmac.compare_digest(token, self.token(expiry, nonce, resource)):
            return None
        return expiry, nonce

    def issue(self):
        expiry = int(self.clock()) + self.lifetime
        nonce = secrets.token_urlsafe(18)
        url = self.origin + "/ota/" + self.token(expiry, nonce, "manifest.plist") + "/manifest.plist"
        return {"manifestURL": url, "expiresAt": expiry * 1000,
                "installURL": "itms-services://?action=download-manifest&url=" + quote(url, safe="")}

    def manifest(self, expiry, nonce):
        url = self.origin + "/ota/" + self.token(expiry, nonce, "Hermit.ipa") + "/Hermit.ipa"
        return plistlib.dumps({"items": [{
            "assets": [{"kind": "software-package", "url": url}],
            "metadata": {"bundle-identifier": self.release["bundleIdentifier"],
                         "bundle-version": self.release["build"], "kind": "software",
                         "title": self.release["name"]}}]}, fmt=plistlib.FMT_XML)


def byte_range(value, size):
    if value is None:
        return None
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
    if not match or not any(match.groups()) or size <= 0:
        raise ValueError("Unsupported range")
    first, last = match.groups()
    if not first:
        count = int(last)
        if count <= 0:
            raise ValueError("Empty suffix range")
        return max(0, size - count), size - 1
    start = int(first)
    end = min(int(last), size - 1) if last else size - 1
    if start >= size or end < start:
        raise ValueError("Unsatisfiable range")
    return start, end


def handler(package, release, install=None):
    package = Path(package).resolve(strict=True)
    original = package.stat()

    class Handler(BaseHTTPRequestHandler):
        # Avoid recording user identity, request headers or download query data.
        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self.respond(head=True)

        def do_GET(self):
            self.respond(head=False)

        def fail(self, status, message):
            data = message.encode()
            self.headers_for(status, "text/plain; charset=utf-8", len(data))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_POST(self):
            if urlsplit(self.path).path != "/api/install" or install is None:
                self.fail(404, "Not found")
                return
            # The Access-protected browser page owns issuance. JSON + exact
            # Origin checks reject form submissions and cross-site requests.
            if self.headers.get("Origin") != install.origin \
                    or self.headers.get_content_type() != "application/json":
                self.fail(403, "Open the private download page first")
                return
            try:
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 <= length <= 1024 or self.headers.get("Transfer-Encoding"):
                    raise ValueError()
                if json.loads(self.rfile.read(length)) != {}:
                    raise ValueError()
            except (ValueError, UnicodeError):
                self.fail(400, "Invalid request")
                return
            if not install.available:
                self.fail(409, "Package must be signed with an unexpired profile")
                return
            data = json.dumps(install.issue()).encode()
            self.headers_for(200, "application/json; charset=utf-8", len(data))
            self.end_headers()
            self.wfile.write(data)

        def headers_for(self, status, kind, size):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "private, no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")

        def respond(self, head):
            try:
                route = urlsplit(self.path).path
                assets = {"/": ("index.html", "text/html; charset=utf-8"),
                          "/app.js": ("app.js", "application/javascript; charset=utf-8")}
                if route in assets:
                    filename, kind = assets[route]
                    data = (ASSETS / filename).read_bytes()
                elif route == "/api/release":
                    metadata = dict(release)
                    metadata["overTheAirInstall"] = bool(install and install.available)
                    if install:
                        metadata["installOrigin"] = install.origin
                    data, kind = json.dumps(metadata, ensure_ascii=False).encode(), "application/json; charset=utf-8"
                elif route.startswith("/ota/"):
                    parts = route.split("/")
                    resource = parts[-1]
                    validated = install.validate(parts[2], resource) if install and len(parts) == 4 \
                        and resource in ("manifest.plist", "Hermit.ipa") else None
                    if validated is None:
                        self.fail(403, "Installation link expired or invalid. Reopen the private page.")
                        return
                    if resource == "Hermit.ipa":
                        self.download(head)
                        return
                    data, kind = install.manifest(*validated), "text/xml; charset=utf-8"
                elif route == "/Hermit.ipa":
                    self.download(head)
                    return
                else:
                    self.send_error(404)
                    return
                self.headers_for(200, kind, len(data))
                self.end_headers()
                if not head:
                    self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def download(self, head):
            # A replacement must restart the server with its new metadata/hash.
            with package.open("rb") as stream:
                import os
                current = os.fstat(stream.fileno())
                if (current.st_ino, current.st_size, current.st_mtime_ns) != (original.st_ino, original.st_size, original.st_mtime_ns):
                    self.send_error(503, "Package changed; restart the release server")
                    return
                size = current.st_size
                tag = '"' + release["sha256"] + '"'
                requested = self.headers.get("Range")
                if self.headers.get("If-Range") not in (None, tag):
                    requested = None
                try:
                    interval = byte_range(requested, size)
                except ValueError:
                    self.headers_for(416, "application/octet-stream", 0)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                start, end = interval or (0, size - 1)
                remaining = end - start + 1
                self.headers_for(206 if interval else 200, "application/octet-stream", remaining)
                self.send_header("Content-Disposition", 'attachment; filename="Hermit.ipa"')
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("ETag", tag)
                if interval:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.end_headers()
                if head:
                    return
                stream.seek(start)
                while remaining:
                    data = stream.read(min(256 * 1024, remaining))
                    if not data:
                        break
                    self.wfile.write(data)
                    remaining -= len(data)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--source-commit", required=True, help="Source SHA actually built into this IPA")
    parser.add_argument("--note", action="append", default=[])
    parser.add_argument("--port", type=int, default=18749)
    parser.add_argument("--ota-origin", help="HTTPS origin with private issuance and ticket-only /ota/ routes")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        parser.error("--source-commit must be the full source SHA")
    release = inspect_package(args.ipa, args.source_commit, args.note)
    install = InstallFlow(args.ota_origin, release) if args.ota_origin else None
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(args.ipa, release, install))
    server.daemon_threads = True
    print(f"Hermit private download ready on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
