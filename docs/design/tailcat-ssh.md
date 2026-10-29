# Tailcat SSH transport

Tailcat is an independent, experimental connection option alongside Direct,
SOCKS5, and Cloudflare SSH. It carries the existing SSH protocol through an
application-local WireGuard/netstack connection, attempting UDP direct paths
and falling back to DERP. It does not use Cloudflare Access, require a
Tailscale account, install a system VPN, or replace Herdr/SwiftTerm/Metal.

## Configure a connection

1. Create an SSH connection and select **Tailcat (Experimental)** under
   Transport. Copy **Tailcat client public key**. The app generates a persistent
   client identity for this connection; its private key is never displayed.
2. On the remote Mac, run Tailcat to forward the existing SSH port, allowing
   that client public key:

   ```sh
   tailcat serve --allow='nodekey:PASTE_THE_APP_PUBLIC_KEY' 22
   ```

3. Paste the complete `tc…` address printed by the server into the app's
   **Tailcat address** field. Enter the remote SSH username and password or
   choose its SSH private key. The SSH host alias is optional and does not
   need to be a resolvable hostname. Save or connect, then verify the SSH host
   fingerprint as usual.

Keep the PSK enabled (the Tailcat default). This implementation accepts complete
addresses with a PSK and a separate discovery key; DNS TXT lookup and old
addresses without those protections are not supported. Do not put the address
in the ordinary Host field: the address contains a secret. Ports other than 22
work when the server forwards the corresponding port. This transport currently
carries SSH/TCP only; selecting it disables Mosh. Herdr, tmux, and plain shell
remain selectable.

The command above uses an ephemeral server identity unless a default saved
identity already exists. To keep an address across server restarts, configure
and protect a named saved server key with Tailcat's `genkey`/`--key` options and
fix the relay region. See the pinned upstream
[key management instructions](https://github.com/tailscale/tailcat/blob/52fbad323e9d352f1febb623e0975368e9a8cbdd/README.md#key-management).
Use the same app client public key in `--allow` after restarting the server.

## Application boundaries

- `ServerConnection` stores only the transport selector, an opaque Keychain
  reference, and the public server node key. JSON export contains no capability
  address or client private key. Imported metadata on another device needs its
  own credentials and client allowlist entry.
- `TailcatCredentials` uses a separate System Keychain service on both devices
  and signed simulators. Updating the address stages a new item before changing
  the saved reference. Editing without entering a replacement preserves the
  identity. The UI copies only the client public key.
- SSH host trust is indexed by remote Tailcat node public key plus service
  port. A user-editable alias cannot accidentally share trust with a different
  server. The trust prompt still displays the alias.
- `TailcatSSHDialer` shares one native client per address/client identity. Each
  SSH connection gets its own native TCP stream; Herdr's main and push channels
  must not create competing WireGuard nodes with the same key.
- An anonymous Unix socketpair adapts the blocking C byte stream to NIO. There
  is no listening TCP port. Native calls run off the event loop; fixed-size
  pumps, kernel buffers, and an outbound budget bound queued data. Reads remain
  gated until Citadel and the authentication observer are installed.
- Cancellation closes only the affected stream and releases its client lease.
  The final lease closes the shared node. Retry delays and foreground recovery
  use the same bounded policy as the existing tunneled SSH path; configuration,
  credential, SSH authentication, and host-trust failures require user action.
- Diagnostics contain a random attempt ID, phase, elapsed time, and typed error
  codes. Raw addresses, keys, native error strings, and terminal bytes are not
  logged.

## Build

The native source is pinned to upstream commit
`52fbad323e9d352f1febb623e0975368e9a8cbdd`, including its C API. That API is newer
than upstream's v0.7.0 release; the app does not fetch an unpinned main branch.
Build on Apple Silicon with Go 1.27.3 and Xcode:

```sh
scripts/build-tailcat.sh
xcodegen generate
```

The build now produces one shared native library for **Tailcat and embedded
Tailscale**. `TailcatSSH` and `TailscaleSSH` are separate Swift products backed
by the same `CTailcat` binary, not two independently linked Go runtimes. The
reviewed overlays and exact Tailscale dependency are recorded in
`Packages/TailcatSSH/Native/UPSTREAM.json` and the generated build manifest.

Native archives and the XCFramework are regenerated, not tracked in Git. The
script verifies the source archive checksum, pins dependencies through upstream
`go.sum`, links all slices, and runs the upstream ABI smoke test on macOS.
Provenance, build instructions, and collected third-party notices are under
`Packages/TailcatSSH/Native/`; the app also bundles those notices. Supported
slices are arm64 iOS, arm64 iOS Simulator, and arm64 macOS for package tests.

## Verification

Package tests cover identity parsing, native resource lifetime, concurrent
client leases, cancellation, bounded writes, activation gating, and lossless
binary transfer. Optional live tests require a private fixture file through
`MOSHPIT_TAILCAT_FIXTURE`; the file's contents must never be printed or committed.

`scripts/verify/tailcat-fixture/main.go` wraps the existing disposable
`scripts/verify/terminal-input-fixture.py` SSH receiver. It creates a fresh
Tailcat server and an allowlisted client, uses the actual public DERP bootstrap,
and forwards only the temporary loopback SSH port. It exposes no user shell:
the SSH receiver records and echoes synthetic input without executing it.
Compile the Go fixture from the pinned upstream source directory downloaded by
the native build, using upstream `build-tags.txt`; pass the input fixture's
state path and a new private output state path. Stop both fixtures after tests.

For simulator XCTest, pass
`TEST_RUNNER_MOSHPIT_TAILCAT_FIXTURE=/absolute/path/to/private-fixture.json`.
`TailcatSSHServiceLiveTests` verifies parallel authenticated SSH connections,
separate close behavior, host-key identity, exec, UTF-8 PTY input/output, and
resize. `TailcatConnectionUITest` separately exercises configuration validation,
save/relaunch/edit, preservation of the client public key, secret masking, and
deletion. Recovery and credential suites cover permanent failures and retries.

Public-relay simulator tests validate native integration, not cellular NAT
traversal or long-term relay performance. A real iPhone on 5G still needs direct
versus relayed path, input latency, network switch, and suspension/resume tests.
iOS background suspension still applies. Tailcat remains experimental upstream,
so this option is explicit and does not become the default transport.

### Local validation record — 2026-10-28

- iPhone 18 Pro and iPad mini (A17 Pro), iOS 27 simulators: **172 tests passed
  on each**, including the live product SSH service test. No skips or failures.
- Full configuration/save/relaunch/edit/delete UI flow passed on both sizes.
  The iPad UI run used a fresh same-model simulator and completed despite
  repeated 60-second system animation-wait delays after SecureField actions;
  app animations were not disabled to make the test pass.
- Package verification: 14 offline tests passed; the separate real public-DERP
  dual-stream test also passed. The final server path sample reported a relayed
  peer; these runs do not establish cellular direct-connect performance.
- Simulator and signed device builds passed. The retained package is
  `build/Personal/tailcat-20261028.ipa` (72,890,848 bytes), bundle
  `com.aias.moshpit.personal`, version 1.0.8. Deep/strict signature verification,
  ZIP integrity, provisioning bundle match, and a 1,265-file source snapshot
  check passed. The profile expires 2026-10-31 13:55:04 UTC.
- The package has **not** been installed on the phone. The user currently has
  only 5G access and asked to keep the update for later installation. Real-phone
  5G and suspension/resume checks remain outstanding.
- Both disposable network services were stopped. Results and configuration/edit
  screenshots are under `build/verification/20261028-tailcat/`; the device audit
  is `build/Personal/tailcat-device-artifact.json`.

## Embedded Tailscale connection option

Tailscale is a separate experimental transport. It enrolls Moshpit as its own
node on the user's tailnet; the phone does not need the system Tailscale VPN
enabled. The remote Mac still needs Tailscale, a reachable ordinary SSH service,
and an access policy allowing this app node to reach that SSH port.

1. Open **Settings → Tailscale → Sign in to Tailscale**. Complete the official
   browser login. Dismiss the browser using its close control or the sheet's
   pull-down gesture to return to the account settings, which offer **Copy
   login link** for authentication in a browser on another device. A tailnet requiring device
   approval must approve the new `moshpit-…` node in its admin console.
2. Add or edit a host and choose **Tailscale (Experimental)**. Select a visible
   device, or enter its Tailscale IP, full MagicDNS name, or unambiguous hostname.
3. Enter the existing SSH username and password/private key. SSH host-key
   verification, Herdr, tmux, and the terminal renderer remain in the existing
   SSH pipeline. This does not enable the separate **Tailscale SSH** identity
   authentication feature. Mosh/UDP, subnet routers, and exit nodes are outside
   this first implementation.

The connection stores only the local account-binding UUID and optional stable
peer ID. A manually edited host clears the selected peer. Selecting a different
account requires an explicit rebind; refreshing the account or importing an
old connection cannot silently grant it access to a new tailnet. SSH trust is
scoped to the account binding and peer identity (or normalized manual host).
Signing out and signing in again also creates a new local binding, even for the
same Tailscale account. Edit an existing host, choose **Use current Tailscale
account**, then select its device again.

Account secrets use a separate device-only system Keychain service, including
on Simulator. Native node state is AES-256-GCM encrypted using a 32-byte key
from that service, written atomically into an app-private directory excluded
from backups. An unavailable key or invalid ciphertext fails closed. Signing
out closes all app-owned Tailscale streams and removes the local encryption
key/state; it does not claim to delete the device from the remote admin console.

One native node is shared by the account's SSH/control/push streams. The
bounded socketpair bridge and SSH activation gate are reused from Tailcat.
Manual targets are resolved against the current peer map and dialed directly
through the userspace netstack. The generic `tsnet.Server.Dial` system-network
fallback is deliberately not used. Peer disappearance, ambiguous names, and
non-peer targets fail closed.

Login URLs are accepted only from the official HTTPS login origin and are
opened only in response to a user action. Automatic SSH retries never launch a
browser. Account/approval/configuration failures require user action; transient
transport failures use bounded retries. After a long iOS suspension the shared
node is closed and recreated from encrypted state before its SSH/Herdr sessions
resume. Other transports do not wait for that account's control connection.
After a node first reports `Running`, a selected device can still be absent
from its initial cached peer map. Connection preparation waits up to ten
seconds for the target during this startup window, checks cancellation and
account identity on every pass, and never falls back to direct SSH. An
established node losing permission to see a device still requires user action.

Tests cover Keychain failures, identity changes and stale concurrent account
responses, cancellation during startup, selected-peer trust, login presentation,
native encrypted storage, peer-only routing, and both simulator form factors.
`TailscaleLiveLoginUITest` is opt-in with
`TEST_RUNNER_MOSHPIT_TAILSCALE_LIVE_LOGIN=1`; it keeps the app alive for attended
browser authentication. After enrollment, the separate live SSH test accepts
`TEST_RUNNER_MOSHPIT_TAILSCALE_FIXTURE=/absolute/path/to/private-fixture.json`.
Create that isolated forced-command receiver with:

```sh
python3 scripts/verify/terminal-input-fixture.py start \
  --state /tmp/moshpit-tailscale-input.json --listen-address YOUR_MAC_TAILSCALE_IPV4
```

Stop the fixture after verification. Successful simulator enrollment and SSH
tests do not measure actual iPhone 5G latency, direct versus relayed paths,
battery use, or real-device suspension; those require separate device testing.

### Embedded Tailscale validation — 2026-10-28

- iPhone 18 Pro and iPad mini (A17 Pro), iOS 27 simulators: **204 regression
  tests each**, no failures or skips. Both configuration/settings UI flows passed.
- The user completed a real browser enrollment on the iPhone simulator. Device
  listing and the real SSH service test to the Mac mini's isolated receiver
  passed, including concurrent connections, UTF-8 PTY, resize, host trust, and
  recreating the native node without another login. The early peer-map recovery
  failure was reproduced, fixed, and re-tested successfully.
- Native: 33 race-tested cases passed. Swift packages: 14 Tailscale and 14
  Tailcat cases passed; the separately run real Tailcat DERP regression passed.
- The signed update is `build/Personal/tailscale-20261028.ipa` (75,342,149 bytes).
  Build, deep/strict signature, ZIP integrity, profile match, and 1,291-file
  source snapshot checks passed. Its profile expires 2026-10-31 13:55:04 UTC.
  It is retained, **not installed on the phone**.
- The temporary SSH receiver and Tailcat fixtures were stopped. The temporary
  iPhone test simulator was shut down. The user's authorized simulator account
  remains available for further testing. Results and screenshots are under
  `build/verification/20261028-tailscale/`; no real-device 5G performance claim
  follows from these simulator tests.
