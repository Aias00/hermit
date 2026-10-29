#!/usr/bin/env python3
"""Official cloudflared 2026.10.3 + OpenSSH reference for an isolated SSH fixture.

Tokens are read from an explicitly supplied mode-0600 AccessCredentials file.
Only a fresh, exclusive host/AUD cache entry is created, and only that entry
and its guard are removed. HOME and all existing cloudflared cache files stay
unchanged. No credential is passed in argv or emitted in diagnostics.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.parse import urlsplit


EXPECTED_VERSION = "2026.10.3"
HOST_ALIAS = "moshpit-official-reference-fixture"
ECHO_MARKER = b"moshpit-cloudflared-reference-ok\n"


class ReferenceError(Exception):
    """Only fixed, non-secret messages may be constructed here."""


def event(name, **fields):
    print(json.dumps(dict(event=name, **fields), sort_keys=True), flush=True)


def private_bytes(path, limit=256 * 1024):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > limit:
            raise ReferenceError("Private input has unsafe ownership, permissions, type, or size.")
        result = bytearray()
        while True:
            chunk = os.read(fd, min(4096, limit + 1 - len(result)))
            if not chunk:
                return bytes(result)
            result.extend(chunk)
            if len(result) > limit:
                raise ReferenceError("Private input exceeds the size limit.")
    finally:
        os.close(fd)


def private_json(path):
    try:
        result = json.loads(private_bytes(path))
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except ReferenceError:
        raise
    except Exception:
        raise ReferenceError("Could not decode the specified private JSON file.") from None


def write_new(path, data, mode=0o600):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    info = os.fstat(fd)
    identity = (info.st_dev, info.st_ino)
    try:
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise ReferenceError("Could not write the private fixture file.")
            view = view[count:]
        os.fsync(fd)
        return identity
    except BaseException:
        remove_owned(path, identity)
        raise
    finally:
        os.close(fd)


def remove_owned(path, identity, directory=False):
    try:
        info = os.lstat(path)
        if (info.st_dev, info.st_ino) == identity:
            os.rmdir(path) if directory else os.unlink(path)
        else:
            raise ReferenceError("A temporary cache path changed ownership; it was preserved instead of removed.")
    except FileNotFoundError:
        pass


class ExclusiveTokenCache:
    def __init__(self, hostname, audience, token):
        # Do not override HOME. This is the exact default cache location used
        # by cloudflared's pinned token/path.go + go-homedir dependency.
        self.directory = Path.home().resolve() / ".cloudflared"
        self.path = self.directory / (hostname + "-" + audience + "-token")
        self.guard = Path(str(self.path) + ".lock")
        self.token = token.encode("ascii")
        self.token_identity = None
        self.guard_identity = None
        self.directory_identity = None

    def __enter__(self):
        try:
            if self.directory.is_symlink():
                raise ReferenceError("The cloudflared cache directory must not be a symlink.")
            if not self.directory.exists():
                self.directory.mkdir(mode=0o700)
                info = self.directory.stat()
                self.directory_identity = (info.st_dev, info.st_ino)
            info = self.directory.stat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise ReferenceError("The cloudflared cache directory is not owned by this user.")
            # A .url companion from an earlier login would be an existing
            # capability. Never overwrite, display, or consume it.
            if os.path.lexists(self.path) or os.path.lexists(str(self.path) + ".url"):
                raise ReferenceError("A cache entry already exists for this host and audience; refusing to replace it.")
            self.guard.mkdir(mode=0o700)
            info = self.guard.stat()
            self.guard_identity = (info.st_dev, info.st_ino)
            self.token_identity = write_new(self.path, self.token)
            # getToken() returns a valid app cache before taking its lock. If
            # the edge rejects this token, lock acquisition reads this exclusive
            # directory and cannot proceed to an existing org cache or browser.
            # The outer SSH timeout then ends the attempt. This guard is scoped
            # to a new host/AUD only; no other login is blocked.
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        cleanup_failed = False
        for path, identity, directory in [(self.path, self.token_identity, False),
                                           (self.guard, self.guard_identity, True)]:
            if identity:
                try:
                    remove_owned(path, identity, directory=directory)
                except (OSError, ReferenceError):
                    cleanup_failed = True
        if self.directory_identity:
            try:
                remove_owned(self.directory, self.directory_identity, directory=True)
            except OSError:
                # Another process may have legitimately created its own file.
                pass
        self.token = b""
        if cleanup_failed:
            raise ReferenceError("A temporary cache path could not be safely removed; other files were preserved.")


def sandbox_profile(directory, token_path):
    def literal(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
    # The official metadata discovery caches team JWKS even when the app token
    # is already present. Deny those writes and reads of unrelated caches;
    # pinned cloudflared degrades a JWKS cache failure to an HTTPS fetch.
    # config.FileExists opens the cache directory to probe it; allow that
    # directory read without admitting any other cache file's contents.
    return ("(version 1)(allow default)"
            "(deny file-read-data (require-all (subpath " + literal(directory) + ") "
            "(require-not (require-any (literal " + literal(directory) + ") "
            "(literal " + literal(token_path) + ")))))"
            "(deny file-write* (require-all (subpath " + literal(directory) + ") "
            "(require-not (literal " + literal(token_path) + "))))\n")


def diagnostic_categories(stderr, carrier_log=None):
    # Only fixed labels escape this function. Never emit an exception's text,
    # a log line, URL, header, command or authentication material.
    text = stderr.decode("utf8", errors="replace").lower()
    labels = []
    for label, needles in [
        ("ssh_banner_timeout", ["timed out during banner exchange", "connection timed out"]),
        ("ssh_connection_closed", ["connection closed"]),
        ("ssh_key_rejected", ["host key verification failed", "remote host identification has changed"]),
        ("ssh_authentication_denied", ["permission denied (publickey"]),
    ]:
        if any(value in text for value in needles): labels.append(label)
    if carrier_log:
        try: text = private_bytes(carrier_log).decode("utf8", errors="replace").lower()
        except Exception: return labels + ["carrier_log_unavailable"]
        for label, needles in [
            ("carrier_eof", ["unexpected eof"]),
            ("carrier_metadata_failure", ["failed to get app info", "metadata jwt verification failed"]),
            ("carrier_upgrade_failure", ["bad handshake"]),
            ("carrier_cache_denied", ["operation not permitted", "permission denied"]),
            ("carrier_timeout", ["timeout", "timed out"]),
        ]:
            if any(value in text for value in needles): labels.append(label)
    return labels


def bounded_process(argv, input_data=b"", timeout=75, phase="process", carrier_log=None):
    started = time.monotonic()
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(input=input_data, timeout=timeout)
        if process.returncode != 0:
            event("reference_phase_failed", phase=phase, exit_code=process.returncode,
                  elapsed_ms=round((time.monotonic() - started) * 1000),
                  categories=diagnostic_categories(stderr, carrier_log=carrier_log))
            raise ReferenceError("The reference process failed; raw stderr was suppressed.")
        event("reference_phase_passed", phase=phase, elapsed_ms=round((time.monotonic() - started) * 1000))
        return stdout
    except BaseException:
        # A completed SSH failure already drained all proxy pipes. Do not kill
        # an expired process-group ID: macOS may return EPERM (or reuse the ID),
        # which would hide the actual connection failure.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                process.kill()
            process.communicate(timeout=5)
        raise


def validate_scope(credentials, fixture):
    application = credentials["application"]
    endpoint = urlsplit(fixture["endpoint"])
    hostname = application["hostname"]
    audience = application["audience"]
    team = application["teamDomain"]
    if (endpoint.scheme != "wss" or endpoint.hostname != hostname or endpoint.username or endpoint.password
            or endpoint.port not in (None, 443) or endpoint.path not in ("", "/") or endpoint.query or endpoint.fragment
            or audience != fixture["audience"] or team != fixture["team_domain"]):
        raise ReferenceError("Credential hostname, audience, or team does not match the explicitly configured fixture.")
    if not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", hostname) or not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", audience):
        raise ReferenceError("The application configuration is not a supported hostname and audience.")
    token = credentials["applicationToken"]
    if not isinstance(token, str) or len(token) > 64 * 1024 or not re.fullmatch(r"[A-Za-z0-9_.-]+", token):
        raise ReferenceError("The specified credential file does not contain a compact user JWT.")
    if fixture.get("host") not in ("127.0.0.1", "::1", "localhost"):
        raise ReferenceError("This script only verifies an explicitly configured isolated localhost SSH fixture.")
    return hostname, audience, team, token


def pinned_known_host(fixture):
    expected = fixture["host_key_fingerprint"]
    matches = []
    for line in private_bytes(fixture["known_hosts_path"]).decode("ascii").splitlines():
        fields = line.split()
        if len(fields) < 3 or fields[0].startswith(("#", "@")):
            continue
        key_type, encoded_key = fields[1:3]
        try:
            raw = base64.b64decode(encoded_key, validate=True)
        except Exception:
            continue
        fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(raw).digest()).decode("ascii").rstrip("=")
        if fingerprint == expected:
            matches.append((key_type, encoded_key))
    if len(set(matches)) != 1:
        raise ReferenceError("The fixture known_hosts does not uniquely match its pinned SSH fingerprint.")
    key_type, encoded_key = matches[0]
    return (HOST_ALIAS + " " + key_type + " " + encoded_key + "\n").encode("ascii")


def proxy(configuration_path):
    configuration = private_json(configuration_path)
    # Headers are never passed via argv. The cache was populated by run().
    arguments = ["/usr/bin/sandbox-exec", "-f", configuration["sandbox_profile"],
                 configuration["cloudflared"], "access", "ssh", "--hostname", configuration["hostname"],
                 "--loglevel", "error", "--logfile", configuration["stderr_path"]]
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith(("TUNNEL_", "CLOUDFLARED_", "CLOUDFLARE_")):
            environment.pop(key)
    environment["PATH"] = configuration["guard_bin"] + ":/usr/bin:/bin"
    fd = os.open(configuration["stderr_path"], os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC)
    os.dup2(fd, 2)
    os.close(fd)
    os.execve(arguments[0], arguments, environment)


def run(arguments):
    credentials = private_json(arguments.credentials_file)
    fixture = private_json(arguments.fixture_file)
    hostname, audience, team, token = validate_scope(credentials, fixture)
    known_host = pinned_known_host(fixture)
    # Validate the client key's file permissions without displaying its contents.
    _ = private_bytes(fixture["private_key_path"])
    cloudflared = str(Path(arguments.cloudflared).resolve(strict=True))
    if not Path("/usr/bin/sandbox-exec").is_file():
        raise ReferenceError("This isolated official reference requires macOS sandbox-exec.")
    version = bounded_process([cloudflared, "--version"], timeout=10, phase="binary_version").decode("ascii", errors="replace")
    if not re.search(r"\bversion " + re.escape(EXPECTED_VERSION) + r"\b", version):
        raise ReferenceError("The cloudflared binary does not match the pinned reference version.")
    if arguments.inspect_only:
        event("reference_preflight_passed", version=EXPECTED_VERSION, scope_matches=True,
              known_host_fingerprint_matches=True, network_commands_executed=False)
        return
    # The native verifier reloads fresh team JWKS; no browser login occurs in
    # --reuse-credentials mode. stdout/stderr are captured and never forwarded.
    bounded_process([arguments.native_probe, "--hostname", hostname, "--team", team, "--aud", audience,
                     "--reuse-credentials", arguments.credentials_file, "--login-only"], timeout=30, phase="jwt_validation")
    with tempfile.TemporaryDirectory(prefix="moshpit-official-reference-") as temporary:
        root = Path(temporary)
        os.chmod(root, 0o700)
        known_hosts = root / "known_hosts"
        write_new(known_hosts, known_host)
        stderr_path = root / "cloudflared-stderr.log"
        write_new(stderr_path, b"")
        guard_bin = root / "bin"
        guard_bin.mkdir(mode=0o700)
        # Defense in depth: if the pinned cache-lock behavior ever changes,
        # a missing/rejected token still cannot open a browser automatically.
        write_new(guard_bin / "open", b"#!/bin/sh\nexit 1\n", mode=0o700)
        proxy_configuration = root / "proxy.json"
        cache = ExclusiveTokenCache(hostname, audience, token)
        profile_path = root / "cache.sb"
        write_new(profile_path, sandbox_profile(cache.directory, cache.path).encode("utf8"))
        write_new(proxy_configuration, json.dumps(dict(cloudflared=cloudflared, hostname=hostname,
            stderr_path=str(stderr_path), guard_bin=str(guard_bin), sandbox_profile=str(profile_path))).encode("utf8"))
        proxy_command = shlex.join([sys.executable, str(Path(__file__).resolve()), "_proxy", str(proxy_configuration)])
        ssh = ["/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes",
               "-o", "StrictHostKeyChecking=yes", "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no",
               "-o", "VerifyHostKeyDNS=no", "-o", "GlobalKnownHostsFile=/dev/null",
               "-o", "UserKnownHostsFile=" + str(known_hosts), "-o", "HostKeyAlias=" + HOST_ALIAS,
               "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "PreferredAuthentications=publickey",
               "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
               "-o", "ConnectTimeout=45", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5",
               "-o", "ServerAliveCountMax=3", "-o", "ProxyCommand=" + proxy_command,
               "-i", fixture["private_key_path"], "-l", fixture["username"], HOST_ALIAS]
        with cache:
            start = time.monotonic()
            echo = bounded_process(ssh + ["printf '%s\\n' moshpit-cloudflared-reference-ok"],
                                   phase="ssh_echo", carrier_log=stderr_path)
            if echo != ECHO_MARKER:
                raise ReferenceError("The SSH echo result did not match the expected fixture marker.")
            event("official_ssh_echo_passed", version=EXPECTED_VERSION, strict_host_key_verified=True)
            payload = os.urandom(128 * 1024)
            returned = bounded_process(ssh + ["cat"], input_data=payload, phase="ssh_128k_roundtrip", carrier_log=stderr_path)
            if returned != payload:
                raise ReferenceError("The SSH binary stdin/stdout round trip differed from its input.")
            event("official_ssh_roundtrip_passed", bytes=len(payload), strict_host_key_verified=True,
                  elapsed_ms=round((time.monotonic() - start) * 1000))
    event("reference_complete", cache_entry_removed=True, existing_cache_unchanged=True)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "_proxy":
        try:
            proxy(sys.argv[2])
        except BaseException:
            # stdout is the SSH wire here: no JSON or raw exception may enter it.
            os._exit(1)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials-file", required=True)
    parser.add_argument("--fixture-file", required=True)
    parser.add_argument("--cloudflared", default="/opt/homebrew/bin/cloudflared")
    parser.add_argument("--native-probe", default="/Volumes/data/idea/moshpit-cloudflare-real-probe-build/debug/cloudflare-real-probe")
    parser.add_argument("--inspect-only", action="store_true", help="Validate local files/version without cache writes or network commands")
    arguments = parser.parse_args()
    def stop(_signal, _frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    try:
        run(arguments)
    except ReferenceError as error:
        event("reference_failed", message=str(error))
        return 1
    except subprocess.TimeoutExpired:
        event("reference_failed", message="The official reference timed out; no browser login was attempted.")
        return 1
    except (KeyboardInterrupt, SystemExit):
        event("reference_cancelled")
        return 130
    except Exception as error:
        frames = traceback.extract_tb(error.__traceback__)
        event("reference_failed", message="Private-file or process operation failed; raw diagnostics were suppressed.",
              error_type=type(error).__name__, errno=getattr(error, "errno", None),
              source_line=frames[-1].lineno if frames else None)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
