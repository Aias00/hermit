import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("receiver", Path(__file__).with_name("receiver.py"))
receiver = importlib.util.module_from_spec(spec); spec.loader.exec_module(receiver)


def batch():
    now = datetime.now(timezone.utc).isoformat()
    return {"schema": 1, "batchID": str(uuid.uuid4()), "installationID": str(uuid.uuid4()), "createdAt": now,
            "appVersion": "1.0.8", "appBuild": "30", "osVersion": "27.0.1",
            "events": [{"id": str(uuid.uuid4()), "at": now, "kind": "ssh", "route": "tailscale",
                        "phase": "transport-dial", "outcome": "failed", "code": "ssh.connection-failed"}]}


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = receiver.Store(Path(self.temp.name))
        self.token = self.store.create_device()
        self.device = self.store.device(self.token)

    def tearDown(self): self.temp.cleanup()

    def test_duplicate_delivery_is_acknowledged_without_duplication(self):
        value = receiver.validate_batch(batch())
        self.assertEqual(self.store.accept(self.device, value, 400), value["batchID"])
        self.assertEqual(self.store.accept(self.device, value, 400), value["batchID"])
        with self.store.connect() as db: self.assertEqual(db.execute("SELECT COUNT(*) FROM batches").fetchone()[0], 1)

    def test_device_tokens_are_bound_to_one_installation_and_revocable(self):
        value = batch(); self.store.accept(self.device, value, 400)
        with self.assertRaises(PermissionError): self.store.accept(self.device, batch(), 400)
        self.store.revoke(self.device)
        self.assertIsNone(self.store.device(self.token))

    def test_plaintext_tokens_are_not_stored(self):
        self.assertNotIn(self.token.encode(), self.store.path.read_bytes())
        self.assertIsNone(self.store.device("wrong"))

    def test_unclaimed_tokens_expire(self):
        with self.store.connect() as db: db.execute("UPDATE devices SET created=0")
        self.assertIsNone(self.store.device(self.token))

    def test_old_records_are_purged_without_new_uploads(self):
        value = batch(); self.store.accept(self.device, value, 400)
        with self.store.connect() as db: db.execute("UPDATE batches SET received=0")
        self.store.prune()
        with self.store.connect() as db: self.assertEqual(db.execute("SELECT COUNT(*) FROM batches").fetchone()[0], 0)

    def test_schema_excludes_terminal_text_and_unstructured_errors(self):
        for field in ("command", "hostname", "password", "token", "terminal"):
            value = batch(); value["events"][0][field] = "SECRET"
            with self.assertRaises(ValueError): receiver.validate_batch(value)
        for code in ("https://secret.example/?token=SECRET", "command contents", "token=secret"):
            value = batch(); value["events"][0]["code"] = code
            with self.assertRaises(ValueError): receiver.validate_batch(value)
        value = batch(); value["schema"] = True
        with self.assertRaises(ValueError): receiver.validate_batch(value)

    def test_server_limits_daily_storage(self):
        value = batch(); self.store.accept(self.device, value, 2 * 1024 * 1024)
        value["batchID"] = str(uuid.uuid4())
        with self.assertRaises(OverflowError): self.store.accept(self.device, value, 1)

    def test_http_requires_bearer_and_setup_access_and_origin(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), receiver.handler(self.store, "https://app.example", require_access=True))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        base = "http://127.0.0.1:" + str(server.server_port)
        def request(path, data=None, headers=None):
            req = urllib.request.Request(base + path, data=data, headers=headers or {})
            try:
                with opener.open(req, timeout=3) as response: return response.status, response.read()
            except urllib.error.HTTPError as error: return error.code, error.read()
        try:
            status, _ = request("/diagnostics/setup"); self.assertEqual(status, 403)
            status, _ = request("/diagnostics/pair", b"", {"Cf-Access-Jwt-Assertion": "verified-by-gateway"}); self.assertEqual(status, 403)
            value = batch(); payload = json.dumps(value).encode()
            status, _ = request("/diagnostics/v1/batches", payload); self.assertEqual(status, 401)
            headers = {"Authorization": "Bearer " + self.token, "Content-Type": "application/json"}
            status, body = request("/diagnostics/v1/batches", payload, headers)
            self.assertEqual(status, 202); self.assertEqual(json.loads(body)["acceptedBatchID"], value["batchID"])
            status, _ = request("/diagnostics/v1/batches", b"x" * (receiver.MAX_BODY + 1), headers); self.assertEqual(status, 413)
            status, body = request("/diagnostics/pair", b"", {"Cf-Access-Jwt-Assertion": "verified-by-gateway", "Origin": "https://app.example"})
            self.assertEqual(status, 200); self.assertIn(b"hermit-diagnostics://diagnostics/configure?", body)
        finally:
            server.shutdown(); thread.join(timeout=3); server.server_close()


if __name__ == "__main__": unittest.main()
