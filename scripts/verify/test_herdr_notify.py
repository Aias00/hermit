import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('herdr_notify', Path(__file__).resolve().parents[1] / 'host/hermit-herdr-notify.py')
notify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notify)


def snapshot(state, terminal='terminal-1', title='private title'):
    return {'workspaces': [{'workspace_id': 'w1', 'label': 'project'}],
            'panes': [{'pane_id': 'w1:p1', 'terminal_id': terminal, 'workspace_id': 'w1',
                       'agent': 'codex', 'agent_status': state, 'terminal_title_stripped': title}]}


class NativeHerdrNotifications(unittest.TestCase):
    def test_completion_requires_observed_work_and_survives_restart(self):
        tracker = notify.Tracker()
        self.assertEqual(tracker.update(snapshot('done'), 1), [])
        tracker.update(snapshot('working'), 10)
        event, = tracker.update(snapshot('done'), 210)
        self.assertEqual((event['pane'], event['state'], event['duration']), ('w1:p1', 'done', 200))
        restored = notify.Tracker(json.loads(json.dumps(tracker.records)))
        self.assertEqual(restored.update(snapshot('done'), 220), [])
        self.assertNotIn('private title', json.dumps(tracker.records))

    def test_prompt_grace_cancellation_and_deduplication(self):
        tracker = notify.Tracker(grace=30)
        tracker.update(snapshot('working'), 0)
        self.assertEqual(tracker.update(snapshot('blocked'), 1), [])
        self.assertEqual(tracker.update(snapshot('blocked'), 20), [])
        tracker.update(snapshot('working'), 21)
        self.assertEqual(tracker.update(snapshot('working'), 60), [])
        tracker.update(snapshot('blocked'), 100)
        event, = tracker.update(snapshot('blocked'), 131)
        self.assertEqual(event['state'], 'attention')
        self.assertEqual(tracker.update(snapshot('blocked'), 140), [])

    def test_terminal_reuse_does_not_inherit_a_previous_turn(self):
        tracker = notify.Tracker()
        tracker.update(snapshot('working'), 0)
        self.assertEqual(tracker.update(snapshot('done', terminal='terminal-2'), 10), [])
        self.assertNotIn('terminal-1', tracker.records)

    def test_waiting_time_is_part_of_turn_duration(self):
        tracker = notify.Tracker()
        tracker.update(snapshot('working'), 0)
        tracker.update(snapshot('blocked'), 30)
        event, = tracker.update(snapshot('done'), 200)
        self.assertEqual(event['duration'], 200)

    def test_rpc_is_read_only_and_uses_the_requested_unix_socket(self):
        with tempfile.TemporaryDirectory(prefix='hermit-notify-') as directory:
            path = Path(directory) / 'server.sock'
            calls = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path)); server.listen()
                def answer():
                    channel, _ = server.accept()
                    with channel:
                        message = json.loads(channel.makefile('rb').readline())
                        calls.append(message)
                        channel.sendall((json.dumps({'id': message['id'], 'result': {'snapshot': snapshot('working')}}) + '\n').encode())
                thread = threading.Thread(target=answer); thread.start()
                result = notify.request(path, 'session.snapshot')
                thread.join(timeout=2)
                self.assertEqual(result['snapshot']['panes'][0]['agent_status'], 'working')
                self.assertEqual([call['method'] for call in calls], ['session.snapshot'])

    def test_delivery_preserves_hostile_text_as_data_and_scopes_the_pairing(self):
        with tempfile.TemporaryDirectory(prefix='hermit-notify-') as directory:
            root = Path(directory)
            sender = root / 'sender.sh'
            receipt = root / 'receipt'
            sender.write_text('#!/bin/sh\nprintf "%s\\n" "$HERMIT_PUSH_CONNECTION" "$HERMIT_PUSH_PANE" "$3" > ' + notify.shlex.quote(str(receipt)) + '\n')
            event = {'state': 'attention', 'agent': 'codex', 'pane': 'w1:p1', 'session': 'project',
                     'title': '$(touch SHOULD_NOT_EXIST); `whoami`', 'duration': 30}
            notify.deliver(event, sender, 'DEVICE-CONNECTION')
            self.assertEqual(receipt.read_text().splitlines(), ['DEVICE-CONNECTION', 'w1:p1', event['title']])


if __name__ == '__main__': unittest.main()
