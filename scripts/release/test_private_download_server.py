import http.client
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import threading
import unittest
from urllib.parse import urlsplit, parse_qs
import zipfile

spec = importlib.util.spec_from_file_location("private_download", Path(__file__).with_name("private-download-server.py"))
portal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portal)


class ServerFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.package = Path(self.temp.name) / "test.ipa"
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("Payload/Hermit.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "1.0.8", "CFBundleVersion": "13",
                "CFBundleIdentifier": "com.example.hermit.fixture",
                "MoshpitBuildStamp": "aaaaaaa · personal 13"}))
        self.release = portal.inspect_package(self.package, "a" * 40, ["test fix"])
        self.install = None
        self.configure()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), portal.handler(self.package, self.release, self.install))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def configure(self):
        pass

    def request(self, path, method="GET", headers=None, body=None):
        connection = http.client.HTTPConnection(*self.server.server_address)
        try:
            connection.request(method, path, headers=headers or {}, body=body)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()


class DownloadTests(ServerFixture, unittest.TestCase):
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

    def test_download_fallback_remains_available_without_ota_configuration(self):
        status, headers, data = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("下载 IPA".encode(), data)
        self.assertNotIn(b"itms-services:", data)
        self.assertEqual(self.request("/app.js")[0], 200)

    def test_old_package_cannot_be_labeled_with_a_different_source_commit(self):
        with self.assertRaises(ValueError):
            portal.inspect_package(self.package, "b" * 40, [])


class InstallTests(ServerFixture, unittest.TestCase):
    def configure(self):
        self.now = 1_800_000_000
        self.release.update(signing="development", profileExpiresAt="2099-01-01T00:00:00+00:00")
        self.install = portal.InstallFlow("https://app.example.test", self.release, clock=lambda: self.now)

    def issue(self):
        status, headers, data = self.request("/api/install", "POST", body="{}", headers={
            "Origin": "https://app.example.test", "Content-Type": "application/json"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "private, no-store")
        return json.loads(data)

    def test_issued_manifest_and_ipa_work_without_browser_cookies(self):
        ticket = self.issue()
        self.assertEqual(parse_qs(urlsplit(ticket["installURL"]).query)["url"], [ticket["manifestURL"]])
        self.assertEqual(ticket["expiresAt"], (self.now + 600) * 1000)
        status, headers, data = self.request(urlsplit(ticket["manifestURL"]).path)
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("text/xml"))
        manifest = plistlib.loads(data)["items"][0]
        self.assertEqual(manifest["metadata"]["bundle-identifier"], self.release["bundleIdentifier"])
        self.assertEqual(manifest["metadata"]["bundle-version"], "13")
        url = urlsplit(manifest["assets"][0]["url"])
        self.assertEqual(url.netloc, "app.example.test")
        status, _, data = self.request(url.path)
        self.assertEqual((status, data), (200, self.package.read_bytes()))
        self.assertEqual(self.request(url.path, headers={"Range": "bytes=0-7"})[0], 206)
        # A manifest ticket cannot be repurposed into an IPA capability.
        self.assertEqual(self.request(urlsplit(ticket["manifestURL"]).path.replace("manifest.plist", "Hermit.ipa"))[0], 403)
        self.now += 600
        self.assertEqual(self.request(url.path)[0], 403)

    def test_expired_tampered_and_other_build_tickets_are_rejected(self):
        path = urlsplit(self.issue()["manifestURL"]).path
        self.assertEqual(self.request(path.replace("/ota/", "/ota/0", 1))[0], 403)
        self.install.release = {**self.release, "sha256": "b" * 64}
        self.assertEqual(self.request(path)[0], 403)
        self.install.release = self.release
        self.now += 600
        self.assertEqual(self.request(path)[0], 403)
        for path in ["/ota/invalid/manifest.plist", "/ota/api/install", "/ota/../Hermit.ipa"]:
            status, headers, _ = self.request(path)
            self.assertEqual(status, 403)
            self.assertEqual(headers["Cache-Control"], "private, no-store")

    def test_issuance_requires_json_post_and_same_origin(self):
        self.assertEqual(self.request("/api/install")[0], 404)
        for origin in ["https://evil.example", "null", ""]:
            self.assertEqual(self.request("/api/install", "POST", body="{}", headers={
                "Origin": origin, "Content-Type": "application/json"})[0], 403)
        self.assertEqual(self.request("/api/install", "POST", body="{}", headers={
            "Origin": self.install.origin, "Content-Type": "text/plain"})[0], 403)
        self.assertEqual(self.request("/ota/api/install", "POST", body="{}")[0], 404)
        self.assertEqual(self.request("/api/install", "POST", body="[]", headers={
            "Origin": self.install.origin, "Content-Type": "application/json"})[0], 400)

    def test_expired_profiles_disable_issuance(self):
        self.release["profileExpiresAt"] = "2000-01-01T00:00:00+00:00"
        status, _, body = self.request("/api/release")
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)["overTheAirInstall"])
        self.assertEqual(self.request("/api/install", "POST", body="{}", headers={
            "Origin": self.install.origin, "Content-Type": "application/json"})[0], 409)

    def test_a_restart_invalidates_old_links_and_host_injection_is_not_used(self):
        old = self.issue()["manifestURL"]
        self.install.key = portal.InstallFlow(self.install.origin, self.release).key
        self.assertEqual(self.request(urlsplit(old).path)[0], 403)
        status, _, data = self.request("/api/install", "POST", body="{}", headers={
            "Origin": self.install.origin, "Content-Type": "application/json", "Host": "evil.example"})
        self.assertEqual(status, 200)
        self.assertEqual(urlsplit(json.loads(data)["manifestURL"]).hostname, "app.example.test")


if __name__ == "__main__":
    unittest.main()
