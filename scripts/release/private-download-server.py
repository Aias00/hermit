#!/usr/bin/env python3
"""Serve one explicitly selected IPA on loopback, behind private Tailscale Serve.

No directory listing, upload endpoint or automatic installation. Package bytes
stay on this Mac. Run --help for the required release/package arguments.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import subprocess
from urllib.parse import urlsplit
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
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "minimumOS": info.get("MinimumOSVersion", "18.0"),
        "size": path.stat().st_size, "sha256": digest, "sourceCommit": source_commit,
        "signing": kind, "profileExpiresAt": expires, "notes": notes,
        "download": "/Hermit.ipa", "overTheAirInstall": False,
    }


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


def handler(package, release):
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
                    data, kind = json.dumps(release, ensure_ascii=False).encode(), "application/json; charset=utf-8"
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
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        parser.error("--source-commit must be the full source SHA")
    release = inspect_package(args.ipa, args.source_commit, args.note)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(args.ipa, release))
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
