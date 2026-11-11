import Foundation

/// The shell Hermit installs on a dev host, verbatim.
///
/// Each literal is byte-for-byte its file under `scripts/host/`, which is the
/// canonical copy and the one the shell and Go tests actually execute. Two
/// copies exist only because the app cannot read a repo file at runtime on a
/// phone; `HostScriptsTests` fails the moment they diverge.
///
/// Regenerate after editing any of the shell files:
///
///     scripts/gen/gen-host-scripts.py
///
/// Do not hand-edit the literals.
///
/// These are delivered as FILES over an exec channel — not pasted into a shell —
/// so unlike the flow this replaces they carry their own comments, may contain
/// single quotes, and need no escaping of any kind. A user who goes looking at
/// `~/.moshpit/` finds readable programs.
enum HostScripts {

    /// User service forwarding native HERDR state through the sealed sender.
    static let herdrNotify = #"""
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
"""#

    /// What an agent's lifecycle hook calls: stamps the pane, hands attention/done to the sender.
    static let stamp = #"""
#!/bin/sh
# moshpit-stamp.sh — what a coding agent's lifecycle hook calls.
#
# Installed on the DEV HOST at ~/.moshpit/moshpit-stamp.sh. Each agent's config
# registers it against four events; every fire stamps the CURRENT tmux pane with
# @moshpit_state / @moshpit_agent / @moshpit_since, so Hermit reads precise
# agent status over the tmux control channel instead of guessing from output.
#
# It also hands `attention` and `done` — and only those two — to
# moshpit-push.sh, detached and silenced, so a paired host can wake a phone that
# is not running Hermit. `working` fires on every tool call and is deliberately
# never pushed.
#
# Two rules this script must never break, because it runs INSIDE an agent's turn:
#   * exit 0 always. A hook that fails is an error the agent surfaces to the user.
#   * never block. The push is `( ... & )`, so a slow network costs the agent
#     nothing.
#
# The title is best-effort: with jq it is derived from the hook's stdin JSON,
# without jq it is skipped and only the state is stamped. While a turn runs it
# is what the agent is doing or asking; on `done` it becomes the PROMPT the turn
# answered (remembered in @moshpit_prompt from UserPromptSubmit), so the finish
# card can say what finished. Whenever no title is derivable it is cleared, so a
# stale one never lingers.
#
# Canonical copy. Hermit/Services/Install/HostScripts.swift carries a
# byte-identical literal (the app cannot read a repo file on a phone);
# scripts/gen/gen-host-scripts.py regenerates it and a test fails if they drift.
[ -n "$TMUX" ] || exit 0
ST="$1"; AG="${2:-agent}"; TITLE=""
if command -v jq >/dev/null 2>&1 && [ ! -t 0 ]; then
  IN=$(cat)
  EV=$(printf "%s" "$IN" | jq -r ".hook_event_name // empty" 2>/dev/null)
  case "$EV" in
    PreToolUse|PermissionRequest)
      TN=$(printf "%s" "$IN" | jq -r ".tool_name // empty" 2>/dev/null)
      AR=$(printf "%s" "$IN" | jq -r ".tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.pattern // .tool_input.url // empty" 2>/dev/null)
      if [ -n "$AR" ]; then TITLE="$TN: $AR"; else TITLE="$TN"; fi ;;
    Notification)
      TITLE=$(printf "%s" "$IN" | jq -r ".message // empty" 2>/dev/null) ;;
    UserPromptSubmit)
      TITLE=$(printf "%s" "$IN" | jq -r ".prompt // empty" 2>/dev/null) ;;
  esac
  TITLE=$(printf "%s" "$TITLE" | tr "\n" " " | cut -c1-80)
  command -v iconv >/dev/null 2>&1 && TITLE=$(printf "%s" "$TITLE" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)
  # Claude Code routes its own injected turns through UserPromptSubmit too:
  # a background task finishing (<task-notification>), a teammate or another
  # session writing in, a slash command's local output, an interrupt marker.
  # Nobody typed those, and a finish card that quoted one read
  # "<task-notification> <task-id>…" on a real lock screen. Drop the text and
  # keep the prompt the person actually gave — that is still what this work is.
  if [ "$EV" = "UserPromptSubmit" ]; then
    LEAD=${TITLE#"${TITLE%%[! ]*}"}
    case "$LEAD" in
      "<task-notification>"*|"<teammate-message"*|"<cross-session-message"*|\
      "<system-reminder>"*|"<local-command-"*|"<command-name>"*|\
      "[SYSTEM NOTIFICATION"*|"[Request interrupted"*) TITLE="" ;;
    esac
  fi
  # Remember the prompt for this turn's `done`. Only the prompt: a tool line
  # would overwrite it on the very next PreToolUse, and a Stop hook brings no
  # text of its own. Already cut to 80 bytes above — a prompt can be a
  # paragraph, and a lock screen shows two lines (the phone cuts again, by
  # character, before showing it).
  if [ "$EV" = "UserPromptSubmit" ] && [ -n "$TITLE" ]; then
    tmux set -p -t "$TMUX_PANE" @moshpit_prompt "$TITLE" 2>/dev/null
  fi
fi
# What the pane was doing BEFORE this stamp, read in one round trip. Two things
# hang off it below: telling a real question apart from an idle nag, and
# measuring how long a finished turn ran.
PREV=$(tmux display-message -p -t "$TMUX_PANE" "#{@moshpit_state}|#{@moshpit_since}" 2>/dev/null)
PREV_ST=${PREV%%|*}
PREV_SINCE=${PREV#*|}

# A PARKED agent is not asking anything. Claude Code fires its Notification hook
# both for real blocking questions (a permission prompt, mid-turn) and for idle
# reminders ("Claude is waiting for your input") on a pane the user deliberately
# left at the prompt — and the user told us plainly which of those is noise:
# an agent parked on purpose must not light up phones and islands as NEEDS YOU.
#
# The reliable, language-independent tell is the TRANSITION: a real question can
# only interrupt a turn, so it arrives on a pane that was `working` (or already
# `attention`, when a second prompt replaces the first). An idle reminder
# arrives on a pane whose turn already ENDED — prior state `done`. The message
# text is a second, Claude-specific belt for panes with no prior stamp at all.
if [ "$ST" = "attention" ]; then
  IDLE=""
  case "$TITLE" in *"waiting for your input"*) IDLE=1 ;; esac
  case "$PREV_ST" in working|attention) ;; done) IDLE=1 ;; esac
  if [ -n "$IDLE" ]; then
    # Not just dropped — HEALED. A pane still marked `attention` when an idle
    # reminder arrives is a fossil (an older stamp, or a question that stopped
    # existing): the agent is at its prompt, which is what `done` means. Left
    # alone it stands forever — a real phone showed NEEDS YOU frozen for 24
    # hours — because this branch used to exit without touching it and nothing
    # else ever would. Silent: no push, no title; just the truth.
    if [ "$PREV_ST" = "attention" ]; then
      tmux set -p -t "$TMUX_PANE" @moshpit_state done 2>/dev/null
      tmux set -p -t "$TMUX_PANE" @moshpit_since "$(date +%s)" 2>/dev/null
      tmux set -pu -t "$TMUX_PANE" @moshpit_title 2>/dev/null
    fi
    exit 0
  fi
fi

NOW=$(date +%s)
tmux set -p -t "$TMUX_PANE" @moshpit_state "$ST" 2>/dev/null
tmux set -p -t "$TMUX_PANE" @moshpit_agent "$AG" 2>/dev/null
# `@moshpit_since` marks when the pane ENTERED its state — the episode's
# identity — so it moves only when the state does. It used to be overwritten on
# every fire, which made "how long did this run" unanswerable: PostToolUse
# stamps `working` per tool call, so by `done` the timestamp was the last tool's,
# not the turn's. (The app already kept its own stable copy for the same reason;
# now the host agrees with it.)
if [ "$PREV_ST" != "$ST" ]; then
  tmux set -p -t "$TMUX_PANE" @moshpit_since "$NOW" 2>/dev/null
else
  case "$PREV_SINCE" in *[!0-9]*|"") tmux set -p -t "$TMUX_PANE" @moshpit_since "$NOW" 2>/dev/null ;; esac
fi
# The episode id the grace fork below must match: the standing since.
EPISODE=$NOW
if [ "$PREV_ST" = "$ST" ]; then
  case "$PREV_SINCE" in *[!0-9]*|"") ;; *) EPISODE=$PREV_SINCE ;; esac
fi
# A `done` carries the prompt this turn answered: "what finished" is the one
# thing a finish card is for, and the Stop event itself says nothing.
if [ "$ST" = "done" ]; then
  TITLE=$(tmux display-message -p -t "$TMUX_PANE" "#{@moshpit_prompt}" 2>/dev/null)
fi
if [ -n "$TITLE" ]; then
  tmux set -p -t "$TMUX_PANE" @moshpit_title "$TITLE" 2>/dev/null
else
  tmux set -pu -t "$TMUX_PANE" @moshpit_title 2>/dev/null
fi
case "$ST" in
  attention)
    # GRACE before the push: a question answered at the desk within this window
    # never reaches a phone. The fork sleeps, then re-reads the pane — same
    # state AND same episode (`@moshpit_since` unchanged) — before sending.
    # Detached, so the agent's turn is never held. Overridable for tests.
    if [ -x "$HOME/.moshpit/moshpit-push.sh" ]; then
      GRACE=${MOSHPIT_NOTIFY_GRACE:-30}
      (
        sleep "$GRACE"
        CUR=$(tmux display-message -p -t "$TMUX_PANE" "#{@moshpit_state}|#{@moshpit_since}" 2>/dev/null)
        [ "$CUR" = "attention|$EPISODE" ] || exit 0
        exec "$HOME/.moshpit/moshpit-push.sh" attention "$AG" "$TITLE"
      ) >/dev/null 2>&1 &
    fi
    ;;
  done)
    # A finish pushes immediately — but carries how long the turn RAN, so the
    # phone can tell a three-minute build (worth a chime) from a twenty-second
    # answer (list-only, silent). Only a turn measured from `working` counts;
    # anything else sends no duration and reads as short.
    if [ -x "$HOME/.moshpit/moshpit-push.sh" ]; then
      DUR=0
      if [ "$PREV_ST" = "working" ] || [ "$PREV_ST" = "attention" ]; then
        case "$PREV_SINCE" in
          *[!0-9]*|"") ;;
          *) [ "$NOW" -ge "$PREV_SINCE" ] && DUR=$((NOW - PREV_SINCE)) ;;
        esac
      fi
      ( "$HOME/.moshpit/moshpit-push.sh" done "$AG" "$TITLE" "$DUR" >/dev/null 2>&1 & )
    fi
    ;;
esac

exit 0
"""#

    /// Seals one agent status and hands it to the push relay.
    static let sender = #"""
#!/bin/sh
# moshpit-push.sh — seal one agent status and hand it to the Hermit push relay.
#
# Installed on the DEV HOST at ~/.moshpit/moshpit-push.sh, next to the stamp
# script that the Vibe Island hooks already write there. The stamp script calls
# this one, fire-and-forget, for the only two states worth waking a phone for:
#
#     attention  — the agent is blocked on you
#     done       — the agent finished its turn
#
# Everything else (`working`, which fires on every tool call) stays on the tmux
# option bridge, where it costs nothing.
#
# Why this exists at all: the tmux bridge only reaches a phone that is running
# Hermit with a live session. Once iOS suspends the app, the socket dies and no
# amount of local cleverness can wake it. A push can — but only Apple can
# deliver one, and only for a payload signed with the app's team key. So this
# script seals the status with a key the relay does not have, and the relay does
# the one thing it is for: sign, and forward.
#
# Config — written by the app into ~/.moshpit/push.d/<conn>.conf:
#
#     RELAY_URL=https://push.example.org
#     SEND_TOKEN=<64 hex>   bearer credential the relay minted; proves "may
#                           push to that phone" without the relay keeping a
#                           registry — it is an HMAC over the three fields below
#     SECRET=<64 hex>       E2E key; the relay never has it
#     CONN=<uuid>           the phone's own id for this connection
#     APNS_TOKEN=<hex>      where Apple should deliver; rides in each request
#     APNS_ENV=production|sandbox   which APNs host, a hint only
#     SEND_IAT=<unix>       when SEND_TOKEN was minted; tokens expire and the
#                           app rewrites this file well before they do
#
# Usage:
#     moshpit-push.sh <state> <agent> [title]
#     moshpit-push.sh --test [nonce]
#
# --test sends one `done` push labelled with the reserved agent name
# moshpit-selftest. That label is how the app proves a pairing actually works:
# it asks the host to fire one, then waits for a notification carrying the same
# nonce back. A signal that has to travel host -> relay -> Apple -> phone cannot
# be faked by a local check, and the app suppresses it rather than showing the
# user a notification about plumbing. AgentActivityMonitor ignores the label too,
# so proving the install leaves no phantom agent on the island.
#
# Requires: openssl, curl. Nothing else — no jq, no python, no bash. Prints
# nothing and exits 0 on every failure path: it runs inside an agent's hook, and
# a push problem must never become the agent's problem.
#
# WHAT IS VISIBLE TO OTHER LOCAL USERS. openssl takes its keys as command-line
# arguments and offers no file or fd alternative for `enc`, so while this script
# runs, the derived encryption subkey — and the pairing secret it came from —
# appear in this process's argv. On Linux /proc/<pid>/cmdline is world-readable
# by default, so another local user on a SHARED host can capture them by polling
# ps, and with them read or forge this host's notifications. The 0600 on
# push.conf does not help during those milliseconds, and a hook fires often.
#
# The send token is kept out of argv (curl reads it from a private --config
# file below), because that one CAN be protected. The encryption key cannot be,
# portably. On a machine you share with people you would not hand your agent
# transcripts to, either do not pair it or run a kernel with hidepid=2.

set -u

# EVERY paired device gets every push. One `push.conf` used to be the whole
# story, which quietly meant one PHONE per host: a second device pairing
# overwrote the first's secret and its notifications just stopped. Pairings now
# live one file per device under push.d/ (keyed by the device's connection id),
# and the legacy single file is still honored so nothing already installed
# breaks. `MOSHPIT_PUSH_CONF` narrows to a single file for tests.
CONFS=""
if [ -n "${MOSHPIT_PUSH_CONF:-}" ]; then
  [ -r "$MOSHPIT_PUSH_CONF" ] && CONFS="$MOSHPIT_PUSH_CONF"
else
  [ -r "$HOME/.moshpit/push.conf" ] && CONFS="$HOME/.moshpit/push.conf"
  for F in "$HOME/.moshpit/push.d"/*.conf; do
    [ -r "$F" ] && CONFS="$CONFS
$F"
  done
fi
[ -n "$CONFS" ] || exit 0
command -v openssl >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

STATE="${1:-}"
AGENT="${2:-agent}"
TITLE="${3:-}"
# Optional: how long the episode this status closes ran, in seconds. The phone
# uses it to decide whether a finished turn is worth a sound. Digits only;
# anything else reads as absent.
DUR="${4:-}"
case "$DUR" in *[!0-9]*) DUR="" ;; esac

TESTMODE=""
TESTCONN="${HERMIT_PUSH_CONNECTION:-}"
if [ "$STATE" = "--test" ]; then
  STATE="done"
  AGENT="moshpit-selftest"
  TITLE="${2:-pairing-selftest}"
  # Optional third argument: prove ONE pairing. The app passes its own
  # connection id so a self-test doesn't ping every other phone in the house.
  TESTCONN="${3:-}"
  TESTMODE="yes"
fi

# Only these two ever justify a push. Guard here as well as in the caller: this
# script is also what a user runs by hand to test, and a stray "working" would
# spend a phone buzz on nothing.
case "$STATE" in
  attention|done) ;;
  *) exit 0 ;;
esac

PANE="${HERMIT_PUSH_PANE:-${TMUX_PANE:-%0}}"
SESSION="${HERMIT_PUSH_SESSION:-}"
if [ -z "$SESSION" ] && [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  SESSION=$(tmux display-message -p "#S" 2>/dev/null || echo "")
fi
HOST="${MOSHPIT_PUSH_HOST:-$(hostname 2>/dev/null || echo host)}"

# --- JSON string escaping ------------------------------------------------------
# Backslash first, then quote — the other order double-escapes. Control
# characters are deleted rather than escaped: they can only have come from a
# terminal title we are about to show on a lock screen, where they mean nothing.
esc() {
  printf '%s' "$1" \
    | tr -d '\000-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# A lock screen shows ~2 lines. Cut to 120 characters, then let iconv drop any
# UTF-8 sequence the cut split in half — the same treatment the stamp script
# gives its titles, for the same reason (a half character breaks JSON parsers
# and renders as a replacement glyph).
TITLE=$(printf '%s' "$TITLE" | tr '\n\t' '  ' | cut -c1-120)
if command -v iconv >/dev/null 2>&1; then
  TITLE=$(printf '%s' "$TITLE" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$TITLE")
fi

DURFIELD=""
[ -n "$DUR" ] && [ "$DUR" -gt 0 ] 2>/dev/null && DURFIELD=$(printf ',"dur":%s' "$DUR")
TS=$(date +%s)

# One 0600 scratch file for the bearer token, reused per pairing — it never
# reaches argv where any local user could read it out of /proc. trap BEFORE the
# first write, so a crash between creating and writing still cleans up.
AUTHFILE=$(mktemp 2>/dev/null) || exit 0
trap 'rm -f "$AUTHFILE"' EXIT INT TERM

# Seal and send this status to ONE paired device. Everything conn-specific
# lives in here: the plaintext echoes the pairing's connection id (that is how
# the phone routes a tap), the envelope is sealed with ITS secret, the collapse
# thread carries ITS conn, and the POST bears ITS token. A failure for one
# device must never cost another its notification, so nothing in here exits the
# script in hook mode.
send_one() {
  # shellcheck disable=SC1090
  RELAY_URL=""; SEND_TOKEN=""; SECRET=""; CONN=""; APNS_TOKEN=""; APNS_ENV=""; SEND_IAT=""
  . "$1" 2>/dev/null || return 0
  [ -n "${RELAY_URL:-}" ] || return 0
  [ -n "${SEND_TOKEN:-}" ] || return 0
  [ -n "${SECRET:-}" ] || return 0
  # The stateless relay routes by what THIS request carries: the phone's APNs
  # token and the token's mint time ride in the conf. A conf without them is
  # from before the relay stopped keeping a registry — sending would only earn
  # a 401, so skip quietly and let the app rewrite the file on its next
  # connect (it re-checks every conf against its own copy byte for byte).
  [ -n "${APNS_TOKEN:-}" ] || return 0
  case "$SEND_IAT" in *[!0-9]*|"") return 0 ;; esac
  case "$SEND_TOKEN" in *[!0-9a-f]*|"") return 0 ;; esac
  [ ${#SEND_TOKEN} -eq 64 ] || return 0
  if [ -n "$TESTCONN" ] && [ "$CONN" != "$TESTCONN" ]; then return 0; fi

  PLAIN=$(printf '{"conn":"%s","host":"%s","sess":"%s","pane":"%s","agent":"%s","state":"%s","title":"%s","ts":%s%s}' \
    "$(esc "${CONN:-}")" "$(esc "$HOST")" "$(esc "$SESSION")" "$(esc "$PANE")" \
    "$(esc "$AGENT")" "$STATE" "$(esc "$TITLE")" "$TS" "$DURFIELD")

  # --- seal (format v1; see push-relay/sealbox/sealbox.go) ---------------------
  # The secret is lowercased first: the key derivation is defined over the ASCII
  # of the hex string, so "AB" and "ab" would otherwise derive different keys and
  # the phone would reject its own messages with a MAC error.
  SECRET=$(printf '%s' "$SECRET" | tr 'ABCDEF' 'abcdef')

  # `openssl dgst -hmac <string>` is used rather than `-mac HMAC -macopt hexkey:`
  # because the latter does not exist in the LibreSSL that macOS ships as
  # /usr/bin/openssl. That is also why both subkeys stay in hex-string form.
  KE=$(printf '%s' 'moshpit-push-enc-v1' | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | awk '{print $NF}')
  KM=$(printf '%s' 'moshpit-push-mac-v1' | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | awk '{print $NF}')
  [ ${#KE} -eq 64 ] || return 0
  [ ${#KM} -eq 64 ] || return 0

  IV=$(openssl rand -hex 16 2>/dev/null) || return 0
  CT=$(printf '%s' "$PLAIN" | openssl enc -aes-256-cbc -K "$KE" -iv "$IV" -a -A 2>/dev/null) || return 0
  [ -n "$CT" ] || return 0
  MAC=$(printf 'v1|%s|%s' "$IV" "$CT" | openssl dgst -sha256 -hmac "$KM" -binary 2>/dev/null | openssl base64 -A 2>/dev/null) || return 0

  # --- route -------------------------------------------------------------------
  # `cat` is the only field the relay reads besides the routing token: it picks
  # the localized fallback text and the interruption level for a phone whose
  # decryption extension times out.
  #
  # `thread` is the collapse id — the SAME string the app uses as its local
  # notification identifier, so a push replaces the local copy instead of
  # stacking. For `attention` it is per CONNECTION: every waiting prompt on a
  # host collapses into ONE summary card ("claude +2"). `done` stays per pane —
  # finishes are per-turn events, not a standing set.
  if [ "$STATE" = "attention" ]; then
    THREAD="moshpit.attention.${CONN:-none}"
  else
    THREAD="moshpit.$STATE.${CONN:-none}.$PANE"
  fi
  # `tok`/`tokEnv`/`conn`/`iat` are the routing facts the relay verifies the
  # bearer token against — it keeps no registry to look them up in. All four
  # were written into this conf by the app, next to the token they were minted
  # with; none of them is content (the conn already rides in `thread`).
  BODY=$(printf '{"env":{"v":1,"iv":"%s","ct":"%s","mac":"%s"},"cat":"%s","thread":"%s","tok":"%s","tokEnv":"%s","conn":"%s","iat":%s}' \
    "$IV" "$CT" "$MAC" "$STATE" "$(esc "$THREAD")" \
    "$(esc "$APNS_TOKEN")" "$(esc "${APNS_ENV:-production}")" "$(esc "${CONN:-}")" "$SEND_IAT")

  printf 'header = "authorization: Bearer %s"\n' "$SEND_TOKEN" > "$AUTHFILE"

  # -m 6 total, no retry: a hook is holding an agent's turn open. Losing a
  # notification is a nuisance; making every tool call wait on a slow network is
  # a broken product.
  #
  # In --test mode the status code is REPORTED — discarding it made the app
  # unable to tell "the relay refused us" from "still in flight". A hook fire
  # stays silent either way: an agent must never see output from this.
  if [ -n "$TESTMODE" ]; then
    CODE=$(curl -sS -m 6 -o /dev/null -w "%{http_code}" \
      --config "$AUTHFILE" \
      -X POST "$RELAY_URL/v1/notify" \
      -H "content-type: application/json" \
      --data-binary "$BODY" 2>/dev/null)
    case "$CODE" in
      200) ;;
      401) echo "relay rejected this host's send token (401): this phone has not registered with $RELAY_URL" ;;
      410) echo "relay says the device is gone (410): pair again from the app" ;;
      429) echo "relay is rate limiting (429): wait a few seconds" ;;
      502) echo "relay could not reach Apple (502)" ;;
      000|"") echo "could not reach $RELAY_URL" ;;
      *) echo "relay answered $CODE" ;;
    esac
  else
    # One retry, hook mode only. "No retry" was designed when this script ran
    # INSIDE an agent's turn; every caller now detaches it (the stamp's grace
    # fork, the backgrounded done push), so a retry costs the agent nothing —
    # and a cold DNS lookup was observed eating the whole 6s budget on the
    # first push after a quiet period, dropping it silently. Only NETWORK
    # failures retry (curl exits non-zero); an HTTP error is the relay's
    # answer and asking again would not change it.
    for _ in 1 2; do
      if curl -sS -m 8 -o /dev/null \
        --config "$AUTHFILE" \
        -X POST "$RELAY_URL/v1/notify" \
        -H "content-type: application/json" \
        --data-binary "$BODY" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi
}

IFS='
'
for CONF in $CONFS; do
  send_one "$CONF"
done
unset IFS

exit 0
"""#

    /// Content digest of each script, as the manifest records it. Computed from
    /// the literal rather than stored, so it cannot fall out of date.
    static func digest(of component: InstallComponent) -> String? {
        switch component {
        case .stamp:  return ContentDigest.of(stamp)
        case .sender: return ContentDigest.of(sender)
        case .hooks, .pairing: return nil
        }
    }

    /// Body of a component that is a plain file, if it has a fixed one.
    static func body(of component: InstallComponent) -> String? {
        switch component {
        case .stamp:  return stamp
        case .sender: return sender
        case .hooks, .pairing: return nil
        }
    }
}
