import http.client
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import threading
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("private_download", Path(__file__).with_name("private-download-server.py"))
portal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portal)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.package = Path(self.temp.name) / "test.ipa"
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("Payload/Hermit.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "1.0.8", "CFBundleVersion": "13",
                "MoshpitBuildStamp": "aaaaaaa · personal 13"}))
        self.release = portal.inspect_package(self.package, "a" * 40, ["test fix"])
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), portal.handler(self.package, self.release))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, path, method="GET", headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_metadata_and_fixed_routes_do_not_expose_local_files(self):
        status, headers, data = self.request("/api/release")
        self.assertEqual(status, 200)
        release = json.loads(data)
        self.assertEqual(release["build"], "13")
        self.assertFalse(release["overTheAirInstall"])
        self.assertNotIn(self.temp.name, data.decode())
        self.assertEqual(headers["Cache-Control"], "private, no-store")
        for path in ["/../test.ipa", "/%2e%2e/test.ipa", "/manifest.plist", "/test.ipa"]:
            self.assertEqual(self.request(path)[0], 404)

    def test_download_and_resume_return_exact_package_bytes(self):
        original = self.package.read_bytes()
        status, headers, data = self.request("/Hermit.ipa")
        self.assertEqual((status, data), (200, original))
        status, headers, data = self.request("/Hermit.ipa", headers={"Range": "bytes=7-23"})
        self.assertEqual((status, data), (206, original[7:24]))
        self.assertEqual(headers["Content-Range"], f"bytes 7-23/{len(original)}")
        self.assertEqual(self.request("/Hermit.ipa", headers={"Range": "bytes=-8"})[2], original[-8:])
        status, headers, data = self.request("/Hermit.ipa", method="HEAD")
        self.assertEqual(data, b"")
        self.assertEqual(int(headers["Content-Length"]), len(original))
        self.assertEqual(self.request("/Hermit.ipa", headers={"Range": "bytes=0-3", "If-Range": '"old"'})[0], 200)

    def test_invalid_ranges_and_replaced_packages_fail_closed(self):
        for value in ["bytes=999999-", "bytes=5-1", "bytes=-0", "bytes=0-1,4-5"]:
            self.assertEqual(self.request("/Hermit.ipa", headers={"Range": value})[0], 416)
        self.package.write_bytes(b"replaced")
        self.assertEqual(self.request("/Hermit.ipa")[0], 503)

    def test_download_page_has_no_misleading_ota_install(self):
        status, headers, data = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("下载 IPA".encode(), data)
        self.assertNotIn(b"itms-services:", data)
        self.assertEqual(self.request("/app.js")[0], 200)

    def test_old_package_cannot_be_labeled_with_a_different_source_commit(self):
        with self.assertRaises(ValueError):
            portal.inspect_package(self.package, "b" * 40, [])


if __name__ == "__main__":
    unittest.main()
