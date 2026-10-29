#!/usr/bin/env python3
"""Disposable loopback SSH byte receiver for TerminalReliabilityUITest.

No login shell or received command is executed. Fresh SSH keys and all receipts
stay in a mode-0700 temporary directory; the user's sshd, keys and terminals are
untouched. This verifies the app's SSH input bytes, not a remote TUI's behavior.

  python3 scripts/verify/terminal-input-fixture.py start --state /tmp/input.json
  python3 scripts/verify/terminal-input-fixture.py run --state /tmp/input.json -- xcodebuild ...
  python3 scripts/verify/terminal-input-fixture.py stop --state /tmp/input.json

The runner receives TEST_RUNNER_MOSHPIT_SEED_* environment variables. A GET of
MOSHPIT_INPUT_RECEIPT_URL returns {"bytes": [13, ...]}; POST clears the receipt.
Keep test runs sequential: the receiver deliberately has one aggregate log.
"""

import argparse
import base64
import contextlib
import fcntl
import getpass
import hashlib
import ipaddress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty


SCRIPT = str(Path(__file__).resolve())


def private_write(path, text):
    fd = os.open(str(path), os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write(text)


def save(state_path, state):
    temporary = str(state_path) + ".new"
    private_write(temporary, json.dumps(state, indent=2) + "\n")
    os.replace(temporary, state_path)


def receipt(root, data=None, reset=False):
    with open(root / "input.bytes", "r+b", buffering=0) as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        if reset:
            file.truncate(0)
        elif data is not None:
            file.seek(0, os.SEEK_END)
            file.write(data)
        else:
            return list(file.read())


def terminal(root):
    command = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    # Capability/liveness side channels get deterministic, inert replies.
    if command:
        if "command -v" in command and "uname -s" in command:
            print("::Darwin::")
        elif command == "printf fixture-ready":
            print("fixture-ready", end="")
        elif command == "pwd":
            print(root)
        return
    old = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        os.write(1, b"\x1b[?2004h\x1b[2J\x1b[HIsolated input receiver\r\n> ")
        while True:
            data = os.read(0, 4096)
            if not data:
                return
            receipt(root, data=data)
            # Echo safely for visual inspection; never interpret as a command.
            printable = b"".join(bytes([b]) if b >= 32 and b != 127 else
                                  (b"\r\n> " if b == 13 else b"") for b in data)
            os.write(1, printable)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, old)


def serve(state_path):
    state = json.loads(state_path.read_text())
    root = Path(state["fixture_dir"])

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def answer(self, reset=False):
            if self.path != "/receipt":
                self.send_error(404)
                return
            if reset:
                receipt(root, reset=True)
            payload = json.dumps({"bytes": receipt(root)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            self.answer()

        def do_POST(self):
            self.answer(reset=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log = open(root / "sshd.log", "ab", buffering=0)
    sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    try:
        ssh = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
               "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=yes",
               "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
               "-i", str(root / "client_key"), "-p", str(state["port"]),
               state["username"] + "@" + state.get("listen_address", "127.0.0.1"), "printf fixture-ready"]
        for _ in range(40):
            if sshd.poll() is not None:
                raise RuntimeError("fixture sshd exited; inspect local sshd.log")
            result = subprocess.run(ssh, stdin=subprocess.DEVNULL, capture_output=True)
            if result.returncode == 0 and result.stdout == b"fixture-ready":
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("fixture SSH authentication failed")
        state.update(status="ready", pid=os.getpid(), sshd_pid=sshd.pid,
                     receipt_url="http://127.0.0.1:%d/receipt" % server.server_port)
        save(state_path, state)
        stopped.wait()
    finally:
        server.shutdown()
        sshd.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            sshd.wait(timeout=5)
        if sshd.poll() is None:
            sshd.kill()
        log.close()


def start(state_path, listen_address="127.0.0.1"):
    # A real embedded-tailnet test can bind specifically to this Mac's
    # Tailscale interface. Never expose the fixture on every LAN interface.
    address = ipaddress.ip_address(listen_address)
    if str(address) != "127.0.0.1" and address not in ipaddress.ip_network("100.64.0.0/10"):
        raise RuntimeError("fixture bind must be loopback or a local Tailscale IPv4 address")
    if state_path.exists():
        raise RuntimeError("Choose a new state path; existing state is preserved")
    root = Path(tempfile.mkdtemp(prefix="moshpit-input-fixture-")).resolve()
    os.chmod(root, 0o700)
    for name in ("client_key", "host_key"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
    private_write(root / "authorized_keys", (root / "client_key.pub").read_text())
    private_write(root / "input.bytes", "")
    with socket.socket() as listener:
        listener.bind((listen_address, 0))
        port = listener.getsockname()[1]
    public = (root / "host_key.pub").read_text().split()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(public[1])).digest()).decode().rstrip("=")
    username = getpass.getuser()
    config = ["AddressFamily inet", f"ListenAddress {listen_address}", f"Port {port}",
              f"HostKey {root}/host_key", f"PidFile {root}/sshd.pid", f"AuthorizedKeysFile {root}/authorized_keys",
              "StrictModes yes", f"AllowUsers {username}", "AuthenticationMethods publickey", "PubkeyAuthentication yes",
              "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "PermitRootLogin no",
              "AllowAgentForwarding no", "AllowTcpForwarding no", "X11Forwarding no", "PermitTunnel no",
              "UseDNS no", "PrintMotd no", "PrintLastLog no", "LogLevel ERROR",
              f"ForceCommand {sys.executable} {SCRIPT} _pty --state {state_path}"]
    private_write(root / "sshd_config", "\n".join(config) + "\n")
    private_write(root / "known_hosts", f"[{listen_address}]:{port} {public[0]} {public[1]}\n")
    state = dict(kind="moshpit-input-fixture-v1", status="starting", fixture_dir=str(root),
                 username=username, port=port, fingerprint=fingerprint, state_path=str(state_path), listen_address=listen_address)
    save(state_path, state)
    with open(root / "fixture.log", "ab", buffering=0) as log:
        process = subprocess.Popen([sys.executable, SCRIPT, "_serve", "--state", str(state_path)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    for _ in range(200):
        if process.poll() is not None:
            raise RuntimeError("fixture exited; inspect " + str(root / "fixture.log"))
        state = json.loads(state_path.read_text())
        if state.get("status") == "ready":
            print(json.dumps(state))
            return
        time.sleep(0.05)
    os.killpg(process.pid, signal.SIGTERM)
    raise RuntimeError("fixture startup timed out")


def stop(state_path):
    state = json.loads(state_path.read_text())
    if state.get("kind") != "moshpit-input-fixture-v1":
        raise RuntimeError("not this fixture")
    pid = state.get("pid", 0)
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    if SCRIPT in result.stdout and "_serve" in result.stdout and str(state_path) in result.stdout:
        os.killpg(pid, signal.SIGTERM)
    state["status"] = "stopped"
    save(state_path, state)
    # Preserve receipts and fresh keys for local review; the stopped server no
    # longer accepts them. The directory is never a production credential store.
    print(json.dumps({"status": "stopped", "fixture_dir": state["fixture_dir"]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["start", "stop", "run", "_serve", "_pty"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--listen-address", default="127.0.0.1")
    args, command = parser.parse_known_args()
    state_path = args.state.resolve()
    if args.command == "start":
        start(state_path, args.listen_address)
    elif args.command == "stop":
        stop(state_path)
    elif args.command == "_serve":
        serve(state_path)
    elif args.command == "_pty":
        terminal(Path(json.loads(state_path.read_text())["fixture_dir"]))
    else:
        if command and command[0] == "--":
            command.pop(0)
        if not command:
            parser.error("run requires a command after --")
        state = json.loads(state_path.read_text())
        if state.get("status") != "ready":
            raise RuntimeError("fixture is not ready")
        env = os.environ.copy()
        env.pop("TEST_RUNNER_MOSHPIT_SEED_PASSWORD", None)
        values = {"MOSHPIT_SEED_USER": state["username"], "MOSHPIT_SEED_HOST": state.get("listen_address", "127.0.0.1"),
                  "MOSHPIT_SEED_PORT": str(state["port"]), "MOSHPIT_SEED_TRUST_FP": state["fingerprint"],
                  "MOSHPIT_SEED_KEY_B64": base64.b64encode((Path(state["fixture_dir"]) / "client_key").read_bytes()).decode(),
                  "MOSHPIT_INPUT_RECEIPT_URL": state["receipt_url"]}
        env.update({"TEST_RUNNER_" + key: value for key, value in values.items()})
        os.execvpe(command[0], command, env)


if __name__ == "__main__":
    main()
