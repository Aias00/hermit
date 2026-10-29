#!/usr/bin/env python3
"""Exercise the actual Swift boot command on a PTY with an isolated fake CLI.

No Herdr server, user pane, network, or credentials are accessed. The fake
reproduces Herdr 0.9.5's stdin-reader thread and terminal.closed-before-exit
ordering, widening the exit window so the race is deterministic. This tests
the shell protocol; simulator tests cover SessionHub's choice of when to send.

Run from any directory. Optionally pass --before-dir containing the old
HerdrFrameChannel.swift and HerdrLaunch.swift to compare parser behavior too.
"""

import argparse
import base64
import errno
import json
import os
from pathlib import Path
import pty
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time

WARNING = ("herdr: terminal session control input ignored: invalid json command: "
           "expected value at line 1 column 1")
PAYLOAD = bytes([0, 255, 27, 10, 13])


def fake_controller():
    """Accept the same CLI argv shape, but only process synthetic test input."""
    target = sys.argv[5]
    released = threading.Event()

    def emit(event):
        print(json.dumps(event), flush=True)

    def read_input():
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                command = json.loads(line)
            except ValueError:
                print(WARNING, file=sys.stderr, flush=True)
                continue
            if command.get("type") == "terminal.release":
                released.set()
                return
            if command.get("type") == "terminal.input":
                accepted = base64.b64decode(command.get("bytes", "")) == PAYLOAD
                emit({"probe": "input_accepted", "payload_matches": accepted})

    if target not in ('w_test:p1', 'w_test:p2'):
        emit({"probe": "unexpected_target"})
        return
    threading.Thread(target=read_input, daemon=True).start()
    emit({"probe": "controller_started"})
    if os.environ.get("MOSHPIT_HANDOFF_PROBE_MODE") == "fallback" or target.endswith("p2"):
        released.wait(8)
    else:
        time.sleep(0.1)
    emit({"type": "terminal.closed"})
    # The real CLI flushes this event before returning from its output loop.
    # On an external eviction the concurrent stdin reader is still alive.
    time.sleep(0.35)
    os._exit(0)


SWIFT_MAIN = r'''
import Foundation
struct PaneInfo { let width: Int; let height: Int }
enum HostCapabilities { static let extraPathDirs = "/usr/local/bin" }
let warning = "herdr: terminal session control input ignored: invalid json command: expected value at line 1 column 1"
let parsed = HerdrFrameParser.parse(Array(warning.utf8))
let fault: Bool
if case .fault = parsed { fault = true } else { fault = false }
let custom = CommandLine.arguments[1]
let boot = HerdrFrameCommand.boot(target: "w_test:p1", cols: 80, rows: 24, customPath: custom)
let result: [String: Any] = [
    "boot": boot,
    "fallback": HerdrFrameCommand.start(target: "w_test:p1", cols: 80, rows: 24, customPath: custom),
    "retarget": HerdrFrameCommand.retarget(target: "w_test:p2", cols: 80, rows: 24),
    "input": HerdrFrameCommand.input(Data([0, 255, 27, 10, 13])),
    "release": HerdrFrameCommand.release,
    "warning_is_fatal_fault": fault,
    "warning_is_reported": parsed != nil,
    "boot_has_reader_ready_marker": boot.contains("moshpit.reader_ready")
]
print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
'''


def compile_commands(source_dir, work):
    work.mkdir()
    main = work / "main.swift"
    main.write_text(SWIFT_MAIN)
    binary = work / "commands"
    build = subprocess.run(["xcrun", "swiftc", str(source_dir / "HerdrFrameChannel.swift"),
                            str(source_dir / "HerdrLaunch.swift"), str(main), "-o", str(binary)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if build.returncode:
        raise RuntimeError("Host Swift command generator did not compile")
    fake = shlex.quote(sys.executable) + " " + shlex.quote(str(Path(__file__).resolve())) + " --fake-controller"
    output = subprocess.check_output([str(binary), fake], timeout=5)
    return json.loads(output)


class Probe:
    def __init__(self, command, mode):
        self.master, slave = pty.openpty()
        environment = dict(os.environ, MOSHPIT_HANDOFF_PROBE_MODE=mode)
        self.process = subprocess.Popen(["/bin/sh", "-c", command], stdin=slave,
                                        stdout=slave, stderr=slave, env=environment,
                                        start_new_session=True)
        os.close(slave)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.master, selectors.EVENT_READ)
        self.pending = b""
        self.events = []

    def send(self, line):
        os.write(self.master, (line + "\n").encode())

    def wait(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                line = line.strip()
                if line == WARNING.encode():
                    event = {"probe": "invalid_json_warning"}
                else:
                    try:
                        event = json.loads(line)
                    except (ValueError, UnicodeDecodeError):
                        continue
                self.events.append(event)
                if predicate(event):
                    return event
            if self.selector.select(0.1):
                try:
                    self.pending += os.read(self.master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
        raise AssertionError("Expected synthetic protocol event was not observed")

    def close(self):
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=3)
        self.selector.close()
        os.close(self.master)


def check_legacy_fallback(commands):
    probe = Probe(commands["boot"], "fallback")
    try:
        probe.wait(lambda event: event.get("probe") == "controller_started")
        # Model a delayed output path: the old app has not observed ready or
        # paint, even though the remote boot has reached its JSON reader.
        time.sleep(2.5)
        probe.send(commands["fallback"])
        probe.wait(lambda event: event.get("probe") == "invalid_json_warning")
    finally:
        probe.close()


def check_legacy_closed(commands):
    probe = Probe(commands["boot"], "handoff")
    try:
        probe.wait(lambda event: event.get("type") == "terminal.closed")
        probe.send(commands["retarget"])
        probe.wait(lambda event: event.get("probe") == "invalid_json_warning")
    finally:
        probe.close()


def check_reader_ready(commands):
    probe = Probe(commands["boot"], "handoff")
    try:
        probe.wait(lambda event: event.get("type") == "terminal.closed")
        probe.wait(lambda event: event.get("type") == "moshpit.reader_ready")
        probe.send(commands["retarget"])
        probe.wait(lambda event: event.get("probe") == "controller_started")
        probe.send(commands["input"])
        event = probe.wait(lambda event: event.get("probe") == "input_accepted")
        assert event["payload_matches"], "Base64 payload must survive the real PTY unchanged"
        probe.send(commands["release"])
        probe.wait(lambda event: event.get("type") == "moshpit.reader_ready")
        assert not any(event.get("probe") == "invalid_json_warning" for event in probe.events)
    finally:
        probe.close()


def check_late_json_is_not_a_target(commands):
    probe = Probe(commands["boot"], "handoff")
    try:
        probe.wait(lambda event: event.get("type") == "moshpit.reader_ready")
        # Bytes already in flight before eviction cannot be recalled by the
        # app's generation fence. The shell must distinguish them from targets.
        for stale in [commands["input"], commands["release"],
                      '{"type":"terminal.resize","cols":80,"rows":24}']:
            probe.send(stale)
        probe.send(commands["retarget"])
        probe.wait(lambda event: event.get("probe") == "controller_started")
        probe.send(commands["input"])
        accepted = probe.wait(lambda event: event.get("probe") == "input_accepted")
        assert accepted["payload_matches"]
        assert not any(event.get("probe") in ("unexpected_target", "invalid_json_warning")
                       for event in probe.events)
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-dir", type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = root / "Hermit/Services/Herdr"
    with tempfile.TemporaryDirectory(prefix="moshpit-herdr-handoff-") as directory:
        work = Path(directory)
        current = compile_commands(source, work / "current")
        before = compile_commands(options.before_dir, work / "before") if options.before_dir else current
        if options.before_dir:
            assert before["warning_is_fatal_fault"] and not before["boot_has_reader_ready_marker"]
        check_legacy_fallback(before)
        check_legacy_closed(before)
        assert current["warning_is_reported"] and not current["warning_is_fatal_fault"]
        assert current["boot_has_reader_ready_marker"]
        check_reader_ready(current)
        check_late_json_is_not_a_target(current)
        print(json.dumps({"legacy_boot_fallback_invalid_json_reproduced": True,
                          "legacy_closed_handoff_invalid_json_reproduced": True,
                          "actual_boot_reader_ready_handoff_passed": True,
                          "late_json_does_not_start_controller": True,
                          "binary_input_and_release_passed": True,
                          "input_warning_remains_nonfatal": True}, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake-controller":
        fake_controller()
    else:
        main()
