# Official cloudflared reference

`official_reference.py` runs the installed, unmodified **cloudflared 2026.10.3**
as an OpenSSH `ProxyCommand` against the isolated localhost sshd fixture. It
requires an explicitly supplied user Access credential file from the encrypted
transfer/native app login. It never supplies service-token credentials, cookies,
or user tokens in process arguments.

Prepare without network traffic or cache writes:

```sh
python3 scripts/spikes/cloudflare-ssh/official_reference.py \
  --credentials-file /absolute/path/to/new-access-credentials.json \
  --fixture-file /absolute/path/to/live-fixture.json \
  --inspect-only
```

Remove `--inspect-only` only after the latest credentials and fixture are ready.
The optional `--native-probe` selects the built `cloudflare-real-probe` executable;
the default is this workspace's separate spike build directory. A normal run
first uses that probe's `--reuse-credentials --login-only` path to validate the
JWT with fresh team JWKS. That path does not initiate login. All its output is
captured, and only fixed error messages are surfaced.

The credentials and fixture must be owned regular files without group/other
permissions. Their hostname, audience and team must match. The SSH fixture must
have a localhost origin and an explicitly pinned host-key fingerprint that
matches its private `known_hosts` file. The SSH client uses `-F /dev/null`, strict
host-key checking, an isolated known-hosts file, the fixture's private key, no
agent and no password fallback. It checks a fixed `printf` marker and a random
128 KiB `cat` stdin/stdout round trip in two connections. Tokens and random bytes
are never printed.

## Cache isolation

The pinned CLI has no user-token environment variable, header-file option, or
alternate token-cache directory. Its `--header` option would expose the token in
argv. The script instead creates exactly one fresh
`~/.cloudflared/<hostname>-<audience>-token` file with `O_EXCL`, `O_NOFOLLOW` and
mode `0600`. It refuses an existing token, `.url` companion or `.lock` path, and
never changes `HOME`.

An exclusive `.lock` **directory** blocks the pinned client's refresh path if
the token is rejected. In this version a valid cached token is read before lock
acquisition; a directory cannot be read as a lock file, so fallback waits until
the outer deadline ends the process. It cannot reach an existing organization
token or browser flow. An isolated child-process `PATH` also supplies a no-op
`open` executable as defense in depth. Neither the system PATH nor the parent
environment is changed.

Metadata discovery in this CLI normally reads and writes a shared team JWKS
cache even with an existing app token. On macOS, `sandbox-exec` therefore denies
file data reads and all writes under `.cloudflared`, with only the new token path
excepted. The directory itself can be opened for the CLI's `config.FileExists`
probe; file metadata checks remain available. Official JWKS code tolerates
cache I/O failure and continues with keys fetched over HTTPS. Thus other app
tokens, organization tokens, JWKS and config files cannot be read or changed by
this subprocess. The script requires this policy facility rather than silently
running without it.

Temporary token/guard cleanup checks device and inode, and preserves any path
another process replaced. A timeout or interrupt kills the SSH process group
before cleanup. Raw cloudflared diagnostics remain in a private temporary log
that is deleted after the attempt; no automatic retry/login occurs. This
cleanup handles ordinary cancellation and errors; like any process, it cannot
clean up after `SIGKILL` or host power loss. A subsequent run refuses a remaining
entry rather than overwriting it.

## Fixed source evidence

Tag `2026.10.3`, commit `de6376c5af4a67cbc65258682e5a01781827643d`:

- [CLI flags](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/cmd/cloudflared/access/cmd.go):
  `access ssh` / `tcp`, argv-only `--header`, hostname and service-token flags.
- [Token paths](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/path.go):
  default cache directory and `<app hostname>-<AUD>-token` convention.
- [Token acquisition](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/token.go):
  `getToken`, `acquireLockFile`, `GetAppTokenIfExists`, `GetAppInfo`.
- [Metadata JWKS cache](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/jwks.go):
  `getJWKSWithCache` and `writeJWKSCache`, cache I/O failure fallback.
- [WebSocket authentication retry](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/carrier/websocket.go):
  an Access redirect removes the app token before refresh.
- [macOS browser launcher](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/token/launch_browser_darwin.go):
  uses `exec.Command("open", url)`.

## Local checks

```sh
python3 -m unittest discover -s scripts/spikes/cloudflare-ssh \
  -p test_official_reference.py -v
```

Eleven local checks pass: private/exclusive cache creation; preservation of other
cache files and existing locks; symlink rejection; inode-safe cleanup; partial
write and setup cancellation cleanup; scope mismatch; and real macOS sandbox
enforcement for reads/writes/creation/removal/rename. They use only temporary
fake tokens and do not start SSH, access the real cache or contact Cloudflare.
The process-failure check also verifies that an already completed SSH process
does not trigger a signal to an expired process-group ID and obscure the error.
Diagnostics report only a fixed phase, elapsed time, exit code and allowlisted
failure categories; a separate check verifies that raw log content cannot be
included. The SSH connect deadline is 45 seconds and each subprocess has a
75-second overall bound, accounting for the official client's metadata/JWKS
requests before the SSH handshake begins.

This script's readiness is not evidence of a real G1 pass. Record the actual
official-client run separately after the latest user credential file is ready.
