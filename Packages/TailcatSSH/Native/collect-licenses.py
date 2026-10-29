#!/usr/bin/env python3
"""Collect notices for the pinned Go dependencies selected by every Apple build."""

import json
import pathlib
import re
import subprocess
import sys

destination = pathlib.Path(sys.argv[1])
modules = {}
for filename in sys.argv[2:]:
    for line in pathlib.Path(filename).read_text().splitlines():
        if not line:
            continue
        name, version, root, package = line.split("|", 3)
        entry = modules.setdefault(name, {"version": version, "root": pathlib.Path(root), "directories": set()})
        directory = pathlib.Path(package)
        while directory.is_relative_to(entry["root"]):
            entry["directories"].add(directory)
            if directory == entry["root"]:
                break
            directory = directory.parent

goroot = pathlib.Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
# Homebrew keeps Go's LICENSE beside libexec rather than inside GOROOT.
go_license_root = goroot if (goroot / "LICENSE").is_file() else goroot.parent
modules["Go runtime and standard library"] = {
    "version": subprocess.check_output(["go", "env", "GOVERSION"], text=True).strip(),
    "root": go_license_root,
    "directories": {goroot, go_license_root},
}
modules["github.com/tailscale/tailcat"]["version"] = json.loads((destination / "UPSTREAM.json").read_text())["revision"]
notices = ["Third-party notices for CTailcat\n\nGenerated from the packages selected for the pinned Apple builds.\n"]
manifest = []
for name, module in sorted(modules.items()):
    files = set()
    for directory in module["directories"]:
        for candidate in directory.iterdir():
            basename = candidate.name.upper()
            if candidate.is_file() and (re.fullmatch(r"(?:LICENSE|LICENCE|COPYING|NOTICE)(?:\.(?:TXT|MD|RST|LESSER))?", basename) or basename in ("PATENTS", "AUTHORS")):
                files.add(candidate)
    if not files:
        raise SystemExit(f"No license found for {name}")
    manifest.append({"module": name, "version": module["version"], "notices": [str(path.relative_to(module["root"])) for path in sorted(files)]})
    notices.append("\n" + "=" * 72 + f"\n{name} {module['version']}\n")
    for path in sorted(files):
        notices.append(f"\n--- {path.relative_to(module['root'])} ---\n\n" + path.read_text(errors="strict") + "\n")

(destination / "THIRD-PARTY-NOTICES.txt").write_text("".join(notices))
(destination / "DEPENDENCIES.json").write_text(json.dumps(manifest, indent=2) + "\n")
