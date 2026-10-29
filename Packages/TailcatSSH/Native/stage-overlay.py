#!/usr/bin/env python3
"""Apply the reviewed Moshpit tsnet overlay to a fresh, checksum-verified source."""
import pathlib
import json
import shutil
import sys

native = pathlib.Path(__file__).resolve().parent
source = pathlib.Path(sys.argv[1])
shutil.copytree(native / "Overlay", source, dirs_exist_ok=True)
shutil.copyfile(native / "moshpit_tailscale.h", source / "cmd/libtailcat/moshpit_tailscale.h")
registry = source / "internal/capi/registry.go"
original = registry.read_text()
anchor = "\t\tcase *client:\n\t\t\tresult = errors.Join(result, v.client.Close())"
if original.count(anchor) != 1:
    raise SystemExit("Pinned capi close hook changed; review overlay before building")
registry.write_text(original.replace(anchor,
    "\t\tcase *tailscaleNode:\n\t\t\tresult = errors.Join(result, v.close())\n" + anchor))
dependency = pathlib.Path(sys.argv[2])
overlay = {str(dependency / "tsnet/moshpit_peer_dial.go"):
           str(native / "OverlayDependencies/tsnet/moshpit_peer_dial.go")}
# App enrollment must be explicit. Upstream tsnet starts interactive enrollment
# automatically from Start and also accepts ambient CLI environment credentials.
tsnet_source = (dependency / "tsnet/tsnet.go").read_text()
changes = {
    "\tHostname string\n": "\tHostname string\n\n\t// MoshpitExplicitLoginOnly disables implicit enrollment and ambient CLI credentials.\n\tMoshpitExplicitLoginOnly bool\n",
    "\tif st == ipn.NeedsLogin || envknob.Bool(\"TSNET_FORCE_LOGIN\") {": "\tif !s.MoshpitExplicitLoginOnly && (st == ipn.NeedsLogin || envknob.Bool(\"TSNET_FORCE_LOGIN\")) {",
    "func (s *Server) getAuthKey() string {\n": "func (s *Server) getAuthKey() string {\n\tif s.MoshpitExplicitLoginOnly { return \"\" }\n",
}
for old, new in changes.items():
    if tsnet_source.count(old) != 1:
        raise SystemExit("Pinned tsnet login hook changed; review overlay before building")
    tsnet_source = tsnet_source.replace(old, new)
generated = source / ".moshpit-overlay/tsnet.go"
generated.parent.mkdir(exist_ok=True)
generated.write_text(tsnet_source)
overlay[str(dependency / "tsnet/tsnet.go")] = str(generated)
(source / "moshpit-overlay.json").write_text(json.dumps({"Replace": overlay}, indent=2) + "\n")
