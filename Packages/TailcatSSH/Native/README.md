# Native Tailcat and Tailscale library

`scripts/build-tailcat.sh` builds the C ABI from the commit recorded in
`UPSTREAM.json`. It verifies the source archive SHA-256, uses Go 1.27.3, the
the reviewed feature tags in `build-tags.txt`, and the selected Xcode SDKs. Go verifies module
downloads against the pinned upstream `go.sum`. The generated artifact records
the actual Xcode version and all artifact hashes in `BUILD-INFO.json`.

Run from the repository root:

```sh
scripts/build-tailcat.sh
```

The output is `Packages/TailcatSSH/Artifacts/CTailcat.xcframework`, ignored by
Git. Source downloads and intermediate archives live under `build/tailcat`.
Build this artifact before SwiftPM resolves the local package or XcodeGen
generates the application project. A network proxy, when required by the build
machine, can be passed through standard `HTTPS_PROXY`/`HTTP_PROXY` environment
variables; no proxy address or credentials are embedded in the script or app.

The supported slices are iOS 18 arm64, iOS Simulator 18 arm64, and macOS 14
arm64. The script requires an Apple Silicon host and fails explicitly on Intel.
Intel simulators/Macs and Mac Catalyst are not included. Consumers import
`CTailcat` and link the CoreFoundation and Security frameworks. The script links
an upstream C smoke executable for every slice and runs it on an Apple Silicon
Mac. Simulator smoke executables remain under `build/tailcat/slices`; they may
be run with `xcrun simctl spawn DEVICE_UDID PATH_TO_C_SMOKE` on a booted simulator.
These checks validate the ABI and native runtime, not remote network access or
background operation in an iOS app.

`tailcat.h` is the upstream public ABI header, copied without edits and compared
against the pinned source on each build. `moshpit_tailscale.h` adds an embedded
tsnet node using the same pinned `tailscale.com` dependency and the same Go
runtime. The build stages `Overlay/` into a fresh upstream source tree and adds
one reviewed node-close case to the existing C handle registry; `stage-overlay.py`
fails if the exact upstream anchor changes. The fixed Tailscale module is cloned
to disposable build space, selected using a relative module replacement, and
given one additional method through Go's source-overlay mechanism. This avoids
modifying the module cache. Both the overlay sources and hashes are recorded in
`BUILD-INFO.json`. No second Go static/shared runtime is linked.
The Go runtime is linked into the app for its lifetime. All C API I/O calls are
synchronous; callers must use worker threads, preserve buffers until calls
return, process partial byte counts, and explicitly release handles and strings.

The combined runtime retains DNS, IPN state notifications, and other tsnet
features that the earlier Tailcat-only release tags excluded. Logtail upload and
buffering are compiled out. Native node/user logs are discarded; only the explicit
status schema crosses the bridge. The status client uses tsnet's in-memory
LocalClient rather than a loopback TCP listener. Peer data is projected to the
documented schema, and errors crossing the new ABI use fixed safe messages.

TCP targets must resolve to a currently visible peer's IP, MagicDNS name, or
unambiguous hostname. Unknown/public targets are rejected without public DNS.
The added `MoshpitDialPeerTCP` method connects directly through tsnet's userspace
netstack. It deliberately bypasses `Server.Dial`/`UserDial`, whose ordinary
network fallback would otherwise permit routing outside the selected tailnet.
Even a peer-removal race cannot redirect a connection onto the system network.
Subnet routers, exit nodes, and self-dial are outside this first TCP transport.

App nodes opt into `MoshpitExplicitLoginOnly`, a checked source patch that stops
upstream tsnet's automatic interactive enrollment from `Start()` and ignores
ambient CLI authentication keys/forced-login settings. Restoring an existing
node still starts normally; a new or expired login needs the explicit login ABI.

The App supplies a 32-byte Keychain encryption key and a protected, excluded-from-
backup data directory. `moshpit-tailscale.state` stores all tsnet identity state
as an AES-256-GCM authenticated envelope with a fresh nonce per write. Writes use
a 0600 temporary file, fsync, then atomic rename; failed writes preserve the old
file and in-memory state, and make further node operations fail closed until a
restart. A nonblocking filesystem lock prevents simultaneous ownership of the
same node state; corrupt or wrong-key state never silently resets its identity.
Logout requests control-plane revocation and closes child streams; a failed
request is reported. A full local reset requires closing the node before deleting
its directory and Keychain encryption key. iOS suspension still requires App
foreground recovery; embedding tsnet does not make the process run in background.

The script runs the complete capi test suite under Go's race detector before
building and links both the existing Tailcat smoke and new Tailscale ABI smoke
for all slices. It runs both on macOS. The new smoke is offline and covers shared
handles, secure-state ownership, status before start, cancellation and close;
native tests additionally exercise the real tsnet engine against an unreachable
loopback control endpoint without enrolling a device.

The upstream BSD-3-Clause license is in `Licenses/tailcat.LICENSE`. The build
generates `DEPENDENCIES.json` and `THIRD-PARTY-NOTICES.txt` from dependencies
selected by all three target builds, including the Go runtime. Include these
notices when distributing the binary. The script also copies the combined notice
to `Moshpit/Resources/ThirdParty/tailcat-licenses.txt` for the app bundle.
Regenerate them when changing the pin,
toolchain, feature tags, or dependency patches.
