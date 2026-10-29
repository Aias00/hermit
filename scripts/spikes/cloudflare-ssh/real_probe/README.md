# Real Cloudflare Access / SSH banner probe

This macOS command-line experiment reuses the app's `CloudflareAccess` and
`CloudflareSSH` libraries. It does not create an Access app, DNS record, tunnel,
SSH account, or server configuration, and never opens a browser automatically.
Use only an explicitly configured SSH ingress authorized by its owner.

`--anonymous-transport --hostname … --team … --aud …` makes one 15-second WSS attempt without tokens, discovery, browser login, or SSH payload; it rejects login/file flags.
It reports safe phase timings and numeric HTTP responses, and immediately closes an unexpected 101; this diagnostic does not establish authenticated access or G1/G2 acceptance.

Build and check the local tool (no network endpoint is contacted by self-check):

```sh
swift build --package-path scripts/spikes/cloudflare-ssh/real_probe
scripts/spikes/cloudflare-ssh/real_probe/.build/debug/cloudflare-real-probe --self-check
```

Start a real attempt with the trusted application configuration:

```sh
scripts/spikes/cloudflare-ssh/real_probe/.build/debug/cloudflare-real-probe \
  --hostname ssh.example.com \
  --team example.cloudflareaccess.com \
  --aud YOUR_ACCESS_APPLICATION_AUDIENCE
```

`--aud` may be omitted only when the configured team's signing keys can verify
the ingress's `Cf-Access-Metadata` response. The tool never chooses a team from
an unverified redirect or token. Specifying an audience still requires a valid
user token signature, issuer, audience, expiration, and subject after login.

The tool reports a `waiting_for_browser_login` JSON event containing a local
`login_html` path. Open that file yourself and click its login link. Keep the
probe process running while completing your organization's authentication.
The temporary directory is mode 0700, the HTML is mode 0600, and it is deleted
when the login attempt ends. The login capability URL is not printed.

Tokens remain in memory by default. For subsequent real SSH integration tests
or a process-restart/revocation check, explicitly add:

```sh
  --save-credentials /tmp/your-new-private-credentials.json
```

This creates a new mode-0600 `AccessCredentials` JSON file; it refuses to
overwrite an existing file or symlink. Treat the file as a credential and
delete it after testing. Tokens and identity values are not printed; the probe
reports coarse validation results and remaining lifetime. Reuse it with the same
trusted `--hostname`, `--team`, and `--aud` plus:

```sh
  --reuse-credentials /tmp/your-new-private-credentials.json
```

Reuse rejects symlinks, files owned by another user, and group/world-accessible
files, then verifies the JWT again using freshly fetched team signing keys.
The edge's response remains authoritative for revocation. A failed reuse does
not silently start another browser login. Organization-token refresh is not
implemented in P0.

`--login-only` stops after authenticated transfer and optional credential-file
creation. `--login-timeout-seconds` accepts 1–600 seconds (default 300). Ctrl-C
or SIGTERM cancels the request and removes the temporary login HTML.

On the normal path, successful events are:

1. `access_credentials_verified`: encrypted transfer (or private-file reuse)
   yielded a correctly signed and scoped user JWT. Subject and email are not
   printed.
2. `wss_upgraded`: the configured ingress passed system certificate and hostname
   verification, and its HTTP/1.1 WebSocket response was accepted.
3. `ssh_banner_verified`: ordered binary payload delivered an SSH 2.0/1.99
   identification. The tool sends only its SSH client identification, then
   closes. It does not authenticate a host key or execute commands.

Each event explicitly leaves `g1_complete` / `g2_complete` false where relevant.
A banner alone does not prove SSH key exchange, pinned host-key validation,
exec/PTY/SFTP, large transfers, revocation, expiry, or native-app browser handoff.
Use the app's real SSH integration entry point for the remaining G1 checks.

## Attended App verification and diagnostic privacy

The separate [UI-run configuration helper](../prepare_live_ui_run.py) prepares
a copy of an existing xctestrun for synthetic smoke or attended App login. It
does not inject this CLI probe's credentials into the App. Its explicit capture
flag suppresses the smoke test's manual screenshot and hierarchy attachments;
`keepNever` requests non-retention of system and user attachments. The selected
format does not request automatic screen recordings.

These settings do **not** guarantee zero captures. XCTest retained a Safari UI
hierarchy while retrying a tap on an animating Cancel button despite `keepNever`.
The test now waits for stable native-control geometry and taps its coordinate,
but other XCTest failures may still produce diagnostics. Audit the smoke result
on the installed runtime, then audit every live result, including failed runs,
before sharing artifacts. Keep unexpected attachments private; do not print
their contents, browser URLs, account labels, or credentials. A clean smoke run
does not certify all failure paths in a later login run.

An optional Debug-simulator-only public-key link lets a person complete the
App's pending login in an external browser. The App still starts its system
authentication session and performs its own encrypted transfer, validation, and
Keychain persistence. This verifies cross-browser handoff when successful; it
does not establish that a person completed MFA inside the simulator's Safari.
First login, cancellation, restart reuse, expiry, and revocation each need their
own recorded outcome.

## Pinned login-protocol comparison

The package follows cloudflared **2026.10.3**, commit
`de6376c5af4a67cbc65258682e5a01781827643d`:

- [`token/transfer.go`](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/transfer.go#L90-L165):
  `/cdn-cgi/access/cli`; `token` and `aud` appear both on the outer URL and inside
  `redirect_url`; `send_org_token=true`, `edge_token_transfer=true`. The optional
  `close_interstitial` flag is omitted, matching `autoClose=false`.
- [`token/encrypt.go`](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/encrypt.go#L46-L84):
  a fresh Curve25519 box key pair for each attempt, padded URL-safe Base64 public
  key, standard Base64 transfer body, `service-public-key` response header, and
  24-byte nonce preceding the authenticated NaCl box ciphertext.
- Poll URL is `https://login.cloudflareaccess.org/transfer/<public-key>`;
  per-request timeout is 60 seconds, with at most 10 attempts. The package adds
  a total deadline, cancellation, response-size limits, no redirects, and JWT
  validation against the configured issuer. FedRAMP is explicitly unsupported.

One source-level compatibility difference remains to observe on the real
service: cloudflared continues polling for a 200 response with an empty body;
the package currently rejects it as an invalid transfer/key. No evidence yet
shows that the real transfer service emits that response during normal login.
Neither the protocol comparison nor local mocks establish real G1/G2 success.
