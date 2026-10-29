#!/usr/bin/env python3
"""Loopback-only TLS WebSocket -> isolated sshd integration fixture.

    python3 scripts/spikes/cloudflare-ssh/local_fixture.py start --state /tmp/moshpit-cf.json
    TEST_RUNNER_MOSHPIT_CF_FIXTURE=/tmp/moshpit-cf.json xcodebuild test ...
    python3 scripts/spikes/cloudflare-ssh/local_fixture.py stop --state /tmp/moshpit-cf.json

Requires only Python's standard library, OpenSSH, and openssl. All keys, the
authorized_keys/known_hosts files, TLS CA, logs, and sshd configuration live in
a new mode-0700 temporary directory. No user SSH or system sshd configuration
is modified. JSON contains file paths, never key/token contents. The generated
CA is trusted only by the optional integration tests, never installed globally.

This is a local protocol experiment, NOT a production bridge or evidence that
Cloudflare's real carrier (G1) or browser/Access authentication (G2) works.
"""

import argparse
import asyncio
import base64
import contextlib
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time


MAX_FRAME = 1024 * 1024
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def write_private(path, text):
    path = Path(path)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(text)


def write_state(path, state):
    temporary = Path(str(path) + ".new")
    write_private(temporary, json.dumps(state, indent=2) + "\n")
    os.replace(temporary, path)


def run_quiet(argv):
    # Only executable/option/file paths enter argv; key/token material never does.
    subprocess.run(argv, check=True, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def unused_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def prepare(state_path):
    root = Path(tempfile.mkdtemp(prefix="moshpit-cf-fixture-")).resolve()
    os.chmod(root, 0o700)
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    try:
        for name in ("client_ed25519", "host_ed25519"):
            run_quiet(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)])
        write_private(root / "authorized_keys", (root / "client_ed25519.pub").read_text())
        host_public = (root / "host_ed25519.pub").read_text().split()
        fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(host_public[1])).digest()).decode().rstrip("=")
        port = unused_port()
        username = getpass.getuser()
        if os.getuid() == 0:
            raise RuntimeError("Run this isolated fixture as an ordinary user, not root")
        config = "\n".join([
            "AddressFamily inet", "ListenAddress 127.0.0.1", "Port %d" % port,
            "HostKey " + str(root / "host_ed25519"), "PidFile " + str(root / "sshd.pid"),
            "AuthorizedKeysFile " + str(root / "authorized_keys"), "StrictModes yes",
            "AllowUsers " + username, "AuthenticationMethods publickey", "PubkeyAuthentication yes",
            "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no",
            "PermitRootLogin no", "AllowAgentForwarding no", "AllowTcpForwarding no",
            "X11Forwarding no", "PermitTunnel no", "UseDNS no", "PrintMotd no", "PrintLastLog no",
            "Subsystem sftp internal-sftp", "LogLevel ERROR", "",
        ])
        write_private(root / "sshd_config", config)
        write_private(root / "known_hosts", "[127.0.0.1]:%d,[localhost]:%d %s %s\n" % (port, port, host_public[0], host_public[1]))
        write_private(root / "ca.cnf", """[req]
prompt = no
distinguished_name = dn
x509_extensions = ca
[dn]
CN = Hermit disposable loopback fixture CA
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
""")
        write_private(root / "server.cnf", """[req]
prompt = no
distinguished_name = dn
[dn]
CN = localhost
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1,IP:::1
""")
        run_quiet(["openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                   "-keyout", str(root / "ca.key"), "-out", str(root / "ca.pem"), "-config", str(root / "ca.cnf")])
        run_quiet(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                   "-keyout", str(root / "server.key"), "-out", str(root / "server.csr"), "-config", str(root / "server.cnf")])
        run_quiet(["openssl", "x509", "-req", "-days", "2", "-in", str(root / "server.csr"),
                   "-CA", str(root / "ca.pem"), "-CAkey", str(root / "ca.key"), "-CAcreateserial",
                   "-out", str(root / "server.pem"), "-extfile", str(root / "server.cnf"), "-extensions", "server"])
        write_private(root / "access_token", secrets.token_urlsafe(32))
        state = dict(kind="moshpit-local-cloudflare-ssh-fixture-v1", status="starting", fixture_dir=str(root),
                     host="127.0.0.1", port=port, username=username, sshd=sshd,
                     private_key_path=str(root / "client_ed25519"), host_key_fingerprint=fingerprint,
                     ca_certificate_path=str(root / "ca.pem"), access_token_path=str(root / "access_token"),
                     known_hosts_path=str(root / "known_hosts"), state_path=str(state_path))
        write_state(state_path, state)
        return state
    except BaseException:
        shutil.rmtree(root)
        raise


def frame(payload, opcode=2, fin=True):
    first = (0x80 if fin else 0) | opcode
    length = len(payload)
    if length < 126:
        header = bytes([first, length])
    elif length < 65536:
        header = bytes([first, 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 127]) + struct.pack("!Q", length)
    return header + payload


async def bridge(reader, writer, state, token):
    upstream = None
    tasks = []
    try:
        request = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
        if len(request) > 16384:
            return
        lines = request.decode("ascii").split("\r\n")
        if lines[0] != "GET /ssh HTTP/1.1":
            return
        headers = {}
        for line in lines[1:]:
            if line:
                name, value = line.split(":", 1)
                name = name.lower()
                if name in headers:
                    return
                headers[name] = value.strip()
        if not hmac.compare_digest(headers.get("cf-access-token", ""), token):
            writer.write(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            return
        key = headers.get("sec-websocket-key", "")
        if (len(base64.b64decode(key, validate=True)) != 16 or headers.get("sec-websocket-version") != "13"
                or headers.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in [part.strip().lower() for part in headers.get("connection", "").split(",")]):
            return
        remote_reader, upstream = await asyncio.open_connection("127.0.0.1", state["port"])
        banner = await asyncio.wait_for(remote_reader.readline(), timeout=5)
        if not banner.startswith(b"SSH-"):
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest())
        response = (b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        # Deliberately coalesce the upgrade and first SSH banner frame. Losing
        # leftover HTTP decoder bytes or activating before NIOSSH is ready fails.
        writer.write(response + frame(banner))
        await writer.drain()

        async def to_ssh():
            fragmented = False
            message_size = 0
            while True:
                first, second = await reader.readexactly(2)
                opcode, final = first & 15, bool(first & 128)
                if first & 112 or not second & 128:
                    raise ValueError("invalid frame")
                length = second & 127
                if length == 126:
                    length = struct.unpack("!H", await reader.readexactly(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", await reader.readexactly(8))[0]
                if length > MAX_FRAME or (opcode >= 8 and (length > 125 or not final)):
                    raise ValueError("oversized frame")
                mask = await reader.readexactly(4)
                masked = await reader.readexactly(length)
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(masked))
                if opcode == 8:
                    writer.write(frame(payload, opcode=8))
                    await writer.drain()
                    return
                if opcode == 9:
                    writer.write(frame(payload, opcode=10))
                    await writer.drain()
                    continue
                if opcode == 10:
                    continue
                if opcode == 2 and not fragmented:
                    message_size = 0
                elif opcode != 0 or not fragmented:
                    raise ValueError("unsupported frame")
                message_size += length
                if message_size > MAX_FRAME:
                    raise ValueError("oversized message")
                fragmented = not final
                upstream.write(payload)
                await upstream.drain()

        async def from_ssh():
            while True:
                chunk = await remote_reader.read(8192)
                if not chunk:
                    writer.write(frame(struct.pack("!H", 1000), opcode=8))
                    await writer.drain()
                    return
                split = max(1, len(chunk) // 2)
                # Fragment binary messages and interleave a ping. SSH sees only
                # ordered payload bytes, never WS control frames or boundaries.
                writer.write(frame(chunk[:split], fin=False) + frame(b"fixture", opcode=9)
                             + frame(chunk[split:], opcode=0))
                await writer.drain()

        tasks = [asyncio.create_task(to_ssh()), asyncio.create_task(from_ssh())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError,
            ConnectionError, OSError, UnicodeError, ValueError):
        pass  # Never log HTTP headers, credentials, or SSH payloads.
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for stream in (upstream, writer):
            if stream:
                stream.close()
                with contextlib.suppress(Exception):
                    await stream.wait_closed()


async def serve(state_path):
    state = json.loads(state_path.read_text())
    root = Path(state["fixture_dir"])
    log = open(root / "sshd.log", "ab", buffering=0)
    sshd = subprocess.Popen([state["sshd"], "-D", "-e", "-f", str(root / "sshd_config")],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    server = None
    handlers = set()
    try:
        # Verify isolated authorized_keys and known_hosts before marking ready.
        ssh_args = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=" + state["known_hosts_path"], "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "ConnectTimeout=2",
                    "-i", state["private_key_path"], "-p", str(state["port"]),
                    state["username"] + "@127.0.0.1", "printf fixture-ready"]
        for _ in range(40):
            if sshd.poll() is not None:
                raise RuntimeError("isolated sshd exited; inspect its local log")
            result = await asyncio.to_thread(subprocess.run, ssh_args, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if result.returncode == 0 and result.stdout == b"fixture-ready":
                break
            await asyncio.sleep(0.1)
        else:
            raise RuntimeError("isolated SSH authentication did not become ready")
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.set_alpn_protocols(["http/1.1"])
        tls.load_cert_chain(str(root / "server.pem"), str(root / "server.key"))
        token = (root / "access_token").read_text()

        async def accept(reader, writer):
            task = asyncio.current_task()
            handlers.add(task)
            try:
                await bridge(reader, writer, state, token)
            finally:
                handlers.discard(task)

        server = await asyncio.start_server(accept, "127.0.0.1", 0, ssl=tls, limit=16384)
        state.update(status="ready", pid=os.getpid(), sshd_pid=sshd.pid,
                     endpoint="wss://localhost:%d/ssh" % server.sockets[0].getsockname()[1])
        write_state(state_path, state)
        stopped = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            asyncio.get_running_loop().add_signal_handler(sig, stopped.set)
        await stopped.wait()
    finally:
        if server:
            server.close()
            await server.wait_closed()
        for task in list(handlers):
            task.cancel()
        await asyncio.gather(*handlers, return_exceptions=True)
        sshd.terminate()
        try:
            await asyncio.to_thread(sshd.wait, 5)
        except subprocess.TimeoutExpired:
            sshd.kill()
            await asyncio.to_thread(sshd.wait)
        log.close()


def managed_process(state):
    pid = state.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return False
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    command = result.stdout
    return (result.returncode == 0 and str(Path(__file__).resolve()) in command
            and "_serve" in command and state["state_path"] in command and os.getpgid(pid) == pid)


def start(state_path):
    if state_path.exists() and managed_process(json.loads(state_path.read_text())):
        raise RuntimeError("fixture is already running; stop it before starting again")
    state = prepare(state_path)
    root = Path(state["fixture_dir"])
    with open(root / "fixture.log", "ab", buffering=0) as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_serve", "--state", str(state_path)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    try:
        for _ in range(400):
            if process.poll() is not None:
                raise RuntimeError("fixture exited; inspect " + str(root / "fixture.log"))
            current = json.loads(state_path.read_text())
            if current.get("status") == "ready":
                print(json.dumps({key: current[key] for key in ("state_path", "endpoint", "pid", "sshd_pid")}))
                return
            time.sleep(0.05)
        raise RuntimeError("fixture startup timed out")
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        raise


def stop(state_path):
    state = json.loads(state_path.read_text())
    if state.get("kind") != "moshpit-local-cloudflare-ssh-fixture-v1":
        raise RuntimeError("not a fixture state file")
    if managed_process(state):
        os.killpg(state["pid"], signal.SIGTERM)
        for _ in range(100):
            if not managed_process(state):
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("fixture did not stop; keeping its files for inspection")
    root = Path(state["fixture_dir"])
    if root.name.startswith("moshpit-cf-fixture-") and root.parent == Path(tempfile.gettempdir()).resolve():
        shutil.rmtree(root)
    state["status"] = "stopped"
    write_state(state_path, state)
    print(json.dumps({"state_path": str(state_path), "status": "stopped"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("start", "stop", "_serve"))
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    path = args.state.expanduser().resolve()
    try:
        if args.command == "start":
            start(path)
        elif args.command == "stop":
            stop(path)
        else:
            asyncio.run(serve(path))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Errors from key generation contain argv paths only. No key/token data
        # or subprocess output is ever passed through this diagnostic.
        print("Local fixture failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
