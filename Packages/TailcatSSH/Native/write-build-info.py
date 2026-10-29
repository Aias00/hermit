#!/usr/bin/env python3
"""Record toolchain and artifact hashes without local paths or credentials."""

import hashlib
import json
import pathlib
import subprocess
import sys

artifact = pathlib.Path(sys.argv[1])
native = pathlib.Path(__file__).resolve().parent
upstream = json.loads((native / "UPSTREAM.json").read_text())
info = {
    "repository": "https://github.com/tailscale/tailcat",
    "revision": sys.argv[2],
    "source_archive_sha256": sys.argv[3],
    "go": subprocess.check_output(["go", "version"], text=True).strip(),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "patches": upstream["patches"],
    "tailscale_revision": upstream["embedded_tailscale_revision"],
    "tailscale_abi_version": upstream["tailscale_abi_version"],
    "build_tags": (native / "build-tags.txt").read_text().strip(),
    "overlay_sha256": {
        str(path.relative_to(native)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted([*native.glob("Overlay/**/*.go"), *native.glob("OverlayDependencies/**/*.go"), native / "stage-overlay.py", native / "moshpit_tailscale.h"])
    },
    "files": {
        str(path.relative_to(artifact)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(artifact.rglob("*"))
        if path.is_file() and path.name != "BUILD-INFO.json"
    },
}
(artifact / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
