#!/usr/bin/env python3
'''Forward native HERDR task transitions through Hermit's existing sealed sender.

No terminal attachment, resize, input, Codex API or agent-config edits. Run as a
user service on the host; APNs pairing must already have been installed by Hermit.
'''
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


class Tracker:
    def __init__(self, records=None, grace=30):
        self.records = records or {}
        self.grace = grace

    def update(self, snapshot, now):
        '''Return new events; retain episode state across socket reconnects.'''
        agents = {a.get('pane_id'): a for a in snapshot.get('agents', [])}
        workspaces = {w.get('workspace_id'): w.get('label', '') for w in snapshot.get('workspaces', [])}
        events, alive = [], set()
        for pane in snapshot.get('panes', []):
            pane_id = pane.get('pane_id')
            key = pane.get('terminal_id') or pane_id
            if not key or not pane_id: continue
            alive.add(key)
            agent = agents.get(pane_id, {})
            state = agent.get('agent_status', pane.get('agent_status', 'unknown'))
            previous = self.records.get(key)
            if previous is None or previous['state'] != state:
                started = now if state == 'working' else (previous.get('started', previous['since']) if previous else now)
                duration = max(0, int(now - started)) if previous else 0
                current = {'state': state, 'since': now, 'announced': False,
                           'started': started,
                           'eligible_done': previous is not None and previous['state'] in ('working', 'blocked'),
                           'duration': duration}
                self.records[key] = current
            current = self.records[key]
            notify = (state == 'blocked' and now - current['since'] >= self.grace
                      or state == 'done' and current['eligible_done'])
            if notify and not current['announced']:
                current['announced'] = True
                events.append({'state': 'attention' if state == 'blocked' else 'done',
                               'pane': pane_id, 'session': workspaces.get(pane.get('workspace_id'), ''),
                               'agent': pane.get('display_agent') or pane.get('agent') or agent.get('display_agent') or agent.get('agent') or 'agent',
                               'title': pane.get('terminal_title_stripped') or pane.get('title') or '',
                               'duration': current['duration']})
        self.records = {key: value for key, value in self.records.items() if key in alive}
        return events


def request(path, method, params=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(5)
        channel.connect(str(path))
        channel.sendall((json.dumps({'id': 'hermit-notify', 'method': method, 'params': params or {}}) + '\n').encode())
        line = channel.makefile('rb').readline(4_000_001)
        if len(line) > 4_000_000: raise ValueError('HERDR response too large')
        reply = json.loads(line)
        if reply.get('error'): raise ValueError('HERDR request failed')
        return reply['result']


def subscribe(path):
    channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        channel.settimeout(5)
        channel.connect(str(path))
        params = {'subscriptions': [{'type': kind} for kind in ['pane.updated', 'pane.created', 'pane.closed', 'pane.exited']]}
        channel.sendall((json.dumps({'id': 'hermit-watch', 'method': 'events.subscribe', 'params': params}) + '\n').encode())
        return channel
    except Exception:
        channel.close()
        raise


def deliver(event, sender, connection):
    env = os.environ.copy()
    env.update(HERMIT_PUSH_CONNECTION=connection, HERMIT_PUSH_PANE=event['pane'], HERMIT_PUSH_SESSION=event['session'])
    # Titles are data arguments, never shell code. Pairing secrets stay in the
    # existing sender's private files and are not copied into this process.
    subprocess.run(['/bin/sh', str(sender), event['state'], event['agent'], event['title'], str(event['duration'])],
                   env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=40, check=True)


def service_arguments(args):
    values = [sys.executable, str(Path(__file__).resolve()), '--connection', args.connection,
              '--sender', str(args.sender), '--state-file', str(args.state_file), '--herdr', args.herdr]
    if args.socket: values += ['--socket', str(args.socket)]
    return values


def install_service(args):
    args.herdr = shutil.which(args.herdr) or args.herdr
    if not Path(args.herdr).is_absolute() or not Path(args.herdr).is_file():
        raise RuntimeError('HERDR executable was not found on this host')
    label = 'com.aias.hermit.herdr-notify.' + args.connection.lower()
    arguments = service_arguments(args)
    args.state_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if sys.platform == 'darwin':
        directory = Path.home() / 'Library/LaunchAgents'
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (label + '.plist')
        data = {'Label': label, 'ProgramArguments': arguments, 'RunAtLoad': True,
                'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 15,
                'ProcessType': 'Background',
                'StandardOutPath': str(args.state_file.with_suffix('.log')),
                'StandardErrorPath': str(args.state_file.with_suffix('.log'))}
        path.write_bytes(plistlib.dumps(data)); path.chmod(0o600)
        domain = 'gui/' + str(os.getuid())
        subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
        subprocess.run(['launchctl', 'bootstrap', domain, str(path)], check=True, capture_output=True)
        subprocess.run(['launchctl', 'print', domain + '/' + label], check=True, capture_output=True)
    elif sys.platform.startswith('linux') and shutil.which('systemctl'):
        directory = Path.home() / '.config/systemd/user'
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (label + '.service')
        command = shlex.join(arguments).replace('%', '%%')
        path.write_text('[Unit]\nDescription=Hermit HERDR task notifications\n[Service]\nExecStart=' + command +
                        '\nRestart=on-failure\nRestartSec=15\n[Install]\nWantedBy=default.target\n')
        path.chmod(0o600)
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, capture_output=True)
        subprocess.run(['systemctl', '--user', 'enable', '--now', path.name], check=True, capture_output=True)
        subprocess.run(['systemctl', '--user', 'restart', path.name], check=True, capture_output=True)
    else:
        raise RuntimeError('A user launchd or systemd service is required on this host')
    print('HERDR notification service installed')


def run(args):
    pairing = Path.home() / '.moshpit/push.d' / (args.connection + '.conf')
    args.state_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with args.state_file.with_suffix('.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        try:
            records = json.loads(args.state_file.read_text())
            if not isinstance(records, dict): records = {}
        except (OSError, ValueError): records = {}
        tracker = Tracker(records)
        events = None
        last_snapshot, dirty = 0, False
        try:
            while pairing.exists():
                try:
                    path = args.socket
                    if path is None:
                        status = subprocess.run([args.herdr, 'status', 'server', '--json'], capture_output=True, text=True, timeout=5, check=True)
                        path = Path(json.loads(status.stdout)['socket'])
                    if events is None:
                        try: events = subscribe(path)
                        except (OSError, ValueError): pass  # bounded snapshot fallback
                    now = time.time()
                    if now - last_snapshot >= 2 or dirty and now - last_snapshot >= .5:
                        snapshot = request(path, 'session.snapshot')['snapshot']
                        outgoing = tracker.update(snapshot, now)
                        # Persist before delivery. A lost network acknowledgement
                        # must not re-ring the same standing prompt after restart.
                        atomic_json(args.state_file, tracker.records)
                        for event in outgoing:
                            try: deliver(event, args.sender, args.connection)
                            except (OSError, subprocess.SubprocessError):
                                print('Notification sender failed', file=sys.stderr, flush=True)
                        last_snapshot = time.time()
                        dirty = False
                    if events is not None:
                        ready, _, _ = select.select([events], [], [], 1)
                        if ready:
                            chunk = events.recv(65536)
                            dirty = True
                            if not chunk or b'"error"' in chunk:
                                events.close(); events = None
                            # Events are invalidations; authoritative state is
                            # always obtained from a fresh native snapshot.
                    else: time.sleep(1)
                except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                    if events is not None: events.close(); events = None
                    time.sleep(3)
        finally:
            if events is not None: events.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--connection', required=True)
    parser.add_argument('--socket', type=Path)
    parser.add_argument('--herdr', default='herdr')
    parser.add_argument('--sender', type=Path, default=Path.home() / '.moshpit/moshpit-push.sh')
    parser.add_argument('--state-file', type=Path)
    parser.add_argument('--install-service', action='store_true')
    args = parser.parse_args()
    args.connection = str(uuid.UUID(args.connection)).upper()
    args.state_file = args.state_file or Path.home() / '.moshpit/herdr-notify' / (args.connection + '.json')
    if args.install_service: install_service(args)
    else: run(args)


if __name__ == '__main__': main()
