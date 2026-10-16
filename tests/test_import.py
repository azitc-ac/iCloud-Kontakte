"""Tests für Import-VCardToExchangeOnline.ps1 gegen den Graph-Mock."""
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import mock_carddav  # noqa: E402
import mock_graph  # noqa: E402

PS1 = ROOT / "Import-VCardToExchangeOnline.ps1"
N = 30


class ImportFlow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = mock_graph.make_server(0)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.st = cls.srv.state
        cls.port = cls.srv.server_address[1]
        cls.tmp = tempfile.TemporaryDirectory()
        t = Path(cls.tmp.name)
        cls.vcf = t / "alle.vcf"
        cls.vcf.write_bytes("".join(mock_carddav.make_card(i) for i in range(N)).encode("utf-8"))
        cls.zip = t / "einzeln.zip"
        with zipfile.ZipFile(cls.zip, "w") as z:
            for i in range(3):
                z.writestr(f"k{i}.vcf", mock_carddav.make_card(100 + i).encode("utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.tmp.cleanup()

    def run_ps(self, *extra):
        cmd = [os.environ.get("PS_EXE", "powershell.exe"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(PS1), "-NoBrowser", "-Force",
               "-GraphBase", f"http://127.0.0.1:{self.port}/v1.0", "-LoginBase", f"http://127.0.0.1:{self.port}",
               *extra]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        return p.returncode, p.stdout + p.stderr

    def folder_id(self, name):
        return next(i for i, f in self.st.folders.items() if f["displayName"] == name)

    def test_1_whatif_creates_nothing(self):
        rc, out = self.run_ps("-Path", str(self.vcf), "-All", "-Folder", "Privat", "-WhatIf")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.st.contacts["F-PRIV"]), 0)

    def test_2_import_new_nested_folder_and_rerun(self):
        rc, out = self.run_ps("-Path", str(self.vcf), "-All", "-Folder", "iCloud/Neu", "-CreateFolder")
        self.assertEqual(rc, 0, out)
        self.assertIn(f"{N} angelegt", out)          # inkl. gedrosseltem Kontakt (429 -> Wiederholung)
        fid = self.folder_id("Neu")
        self.assertEqual(self.st.folders[fid]["parent"], self.folder_id("iCloud"))
        cs = self.st.contacts[fid]
        self.assertEqual(len(cs), N)
        c0 = next(c for c in cs if c["displayName"].endswith("0000"))   # vCard 3.0, Apple-Label Mobile, Foto
        self.assertEqual(c0["mobilePhone"], "+49 30 0000000")
        self.assertEqual(c0["emailAddresses"][0]["address"], "anna0@example.org")
        self.assertIn("gefaltet", c0["personalNotes"])
        self.assertIn(c0["id"], self.st.photos)
        self.assertEqual(self.st.photos[c0["id"]][0], "image/png")
        c1 = next(c for c in cs if c["displayName"].endswith("0001"))   # vCard 4.0
        self.assertEqual((c1["givenName"], c1["surname"]), ("Jörg", "Schröder0001"))
        self.assertEqual(c1["mobilePhone"], "+49 170 0000001")
        self.assertEqual((c1["companyName"], c1["department"], c1["jobTitle"]), ("Firma 1", "Abteilung", "Leiter, Test"))
        self.assertEqual(c1["homeAddress"], {"street": "Hauptstr. 1", "city": "Berlin", "postalCode": "10115", "countryOrRegion": "Deutschland"})
        self.assertEqual(c1["personalNotes"], "Zeile1\nZeile2; mit Semikolon")
        # zweiter Lauf: alles bereits vorhanden
        rc, out = self.run_ps("-Path", str(self.vcf), "-All", "-Folder", "iCloud/Neu")
        self.assertEqual(rc, 0, out)
        self.assertIn(f"uebersprungen: {N}", out)
        self.assertEqual(len(self.st.contacts[fid]), N)
        # Nutzer will Duplikate
        rc, out = self.run_ps("-Path", str(self.vcf), "-All", "-Folder", "iCloud/Neu", "-AllowDuplicates")
        self.assertEqual(len(self.st.contacts[fid]), 2 * N, out)

    def test_3_zip_into_existing_child_folder(self):
        rc, out = self.run_ps("-Path", str(self.zip), "-All", "-Folder", "Privat/Alt")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.st.contacts["F-ALT"]), 3)

    def test_4_default_folder_and_missing_folder(self):
        rc, out = self.run_ps("-Path", str(self.zip), "-All", "-Folder", "Kontakte")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.st.contacts["F-DEF"]), 3)
        rc, out = self.run_ps("-Path", str(self.zip), "-All", "-Folder", "Gibt es nicht")
        self.assertNotEqual(rc, 0)
        self.assertIn("nicht gefunden", out)


if __name__ == "__main__":
    unittest.main()
