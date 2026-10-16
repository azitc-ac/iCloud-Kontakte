import io
import json
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mock_carddav  # noqa: E402
import server  # noqa: E402

COUNT = 250  # > 2 Multiget-Blöcke


class Flow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mock = mock_carddav.make_server(0, COUNT)
        cls.srv = server.make_server("127.0.0.1", 0, f"http://127.0.0.1:{cls.mock.server_address[1]}/")
        for s in (cls.mock, cls.srv):
            threading.Thread(target=s.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        cls.cookie = None

    @classmethod
    def tearDownClass(cls):
        cls.mock.shutdown(); cls.srv.shutdown()

    def call(self, path, body=None, cookie=True, headers=None):
        h = {"X-Requested-With": "ICE", "Content-Type": "application/json"}
        h.update(headers or {})
        if cookie and self.cookie:
            h["Cookie"] = self.cookie
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers=h, method="POST" if body is not None else "GET")
        try:
            r = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers
        return r.status, r.read(), r.headers

    def login(self):
        code, body, h = self.call("/api/login", {"appleId": mock_carddav.USER, "password": mock_carddav.PASSWORD}, cookie=False)
        self.assertEqual(code, 200, body)
        type(self).cookie = h["Set-Cookie"].split(";")[0]
        return json.loads(body)

    def load(self, book):
        self.assertEqual(self.call("/api/load", {"book": book})[0], 202)
        for _ in range(100):
            st = json.loads(self.call("/api/state")[1])
            if st["job"]["state"] != "loading":
                return st["job"]
            time.sleep(0.1)
        self.fail("Timeout")

    def test_1_wrong_password(self):
        code, body, _ = self.call("/api/login", {"appleId": "x@y.de", "password": "falsch"}, cookie=False)
        self.assertEqual(code, 401)
        self.assertIn("APP-SPEZIFISCHES", json.loads(body)["error"])

    def test_2_csrf_and_host(self):
        req = urllib.request.Request(self.base + "/api/login", data=b"{}", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 403)
        req = urllib.request.Request(self.base + "/", headers={"Host": "evil.example"})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 403)

    def test_3_unauthenticated(self):
        self.assertEqual(self.call("/api/contacts", cookie=False)[0], 401)

    def test_4_full_flow(self):
        r = self.login()
        self.assertEqual(r["books"][0]["name"], "Kontakte")
        job = self.load(r["books"][0]["url"])
        self.assertEqual(job["state"], "done", job)
        lst = json.loads(self.call("/api/contacts")[1])
        self.assertEqual(len(lst), COUNT)
        # Detail: Apple-Label, Telefon, Foto
        c0 = next(c for c in lst if c["fn"].endswith("0000"))
        d = json.loads(self.call(f"/api/contact/{c0['id']}")[1])
        self.assertEqual(d["phones"][0]["type"], "Mobile")
        self.assertTrue(d["hasPhoto"])
        code, body, h = self.call(f"/api/photo/{c0['id']}")
        self.assertEqual((code, h["Content-Type"]), (200, "image/png"))
        self.assertTrue(body.startswith(b"\x89PNG"))
        # Umlaute + vCard 4.0 mit maskiertem Text
        c1 = next(c for c in lst if c["fn"].endswith("0001"))
        d1 = json.loads(self.call(f"/api/contact/{c1['id']}")[1])
        self.assertEqual(d1["title"], "Leiter, Test")
        self.assertEqual(d1["note"], "Zeile1\nZeile2; mit Semikolon")
        self.assertIn("Berlin", d1["addresses"][0]["value"])
        # Export alle (Originaldaten byte-genau enthalten)
        code, body, h = self.call("/api/export", {"ids": "all", "format": "vcf"})
        self.assertEqual(code, 200)
        text = body.decode("utf-8")
        self.assertEqual(text.count("BEGIN:VCARD"), COUNT)
        self.assertIn(server._norm(mock_carddav.make_card(7)), text)
        # Export Auswahl als ZIP
        code, body, h = self.call("/api/export", {"ids": [c0["id"], c1["id"]], "format": "zip"})
        z = zipfile.ZipFile(io.BytesIO(body))
        self.assertEqual(len(z.namelist()), 2)
        self.assertTrue(all(n.endswith(".vcf") for n in z.namelist()))
        # Abmelden
        self.assertEqual(self.call("/api/logout", {})[0], 200)
        self.assertEqual(self.call("/api/contacts")[0], 401)


if __name__ == "__main__":
    unittest.main()
