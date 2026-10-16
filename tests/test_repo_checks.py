"""Repo-Regeln als ausführbare Checks.

Jede Regel hier ist aus einem realen Fehler dieses Projekts entstanden:
* generierte .ps1 vergessen neu zu bauen        -> test_generated_files_in_sync
* `$home` als lokale Variable (PowerShell: nur lesbar) -> test_powershell_syntax_and_reserved_variables  (2x passiert)
* „Sie“/„der Kunde“ in Nutzertexten               -> test_user_facing_text_uses_du_and_is_neutral
* Parameter/Flag ohne Doku                        -> test_every_parameter_is_documented
* README verweist auf nicht existierende Datei    -> test_readme_references_existing_files
"""
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import build_ps1  # noqa: E402

GENERATED = [out for _, out, _ in build_ps1.TARGETS]
README = (ROOT / "README.md").read_text(encoding="utf-8")


def analyze():
    import os
    cmd = [os.environ.get("PS_EXE", "powershell.exe"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
           str(ROOT / "tests" / "analyze.ps1"), "-Files",
           ";".join(str(ROOT / g) for g in GENERATED)]   # Templates enthalten Platzhalter -> nur Generiertes parsen
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    assert p.returncode == 0, p.stderr
    return [ln.split("|", 2) for ln in p.stdout.splitlines() if "|" in ln]


class RepoChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.findings = analyze()

    def test_generated_files_in_sync(self):
        for template, out, extra in build_ps1.TARGETS:
            want = build_ps1.render(template, extra)
            have = (ROOT / out).read_bytes().decode("utf-8-sig")
            self.assertEqual(have, want, f"{out} ist veraltet: `python build_ps1.py` ausführen und mitcommitten")
            self.assertTrue((ROOT / out).read_bytes().startswith(b"\xef\xbb\xbf"), f"{out}: UTF-8-BOM fehlt (5.1 liest sonst Umlaute falsch)")

    def test_powershell_syntax_and_reserved_variables(self):
        bad = [f for f in self.findings if f[0] in ("SYNTAX", "RESERVED")]
        self.assertEqual(bad, [], "\n".join("|".join(b) for b in bad))
        self.assertTrue(any(f[0] == "PARAM" for f in self.findings), "Analyse hat keine Parameter gefunden (Check defekt?)")

    def test_user_facing_text_uses_du_and_is_neutral(self):
        files = [ROOT / "README.md", ROOT / "server.py", ROOT / "carddav.py", ROOT / "mock_carddav.py",
                 ROOT / "mock_graph.py", *(ROOT / "static").glob("*"), *(ROOT / "ps").glob("*"), *(ROOT / g for g in GENERATED)]
        files = [f for f in files if f.is_file()]
        rx = re.compile(r"\b(Sie|Ihr\w*|Ihnen|Kunde[n]?|Kundin)\b")
        hits = []
        for f in files:
            for n, line in enumerate(f.read_text(encoding="utf-8-sig").splitlines(), 1):
                if rx.search(line):
                    hits.append(f"{f.relative_to(ROOT)}:{n}: {line.strip()[:90]}")
        self.assertEqual(hits, [], "Anrede muss „Du“ sein, kein „der Kunde“:\n" + "\n".join(hits))

    def test_every_parameter_is_documented(self):
        missing = []
        for _, name, param in self.findings:
            if name.endswith(".ps1") and not name.endswith("template.ps1") and name in GENERATED:
                if not re.search(r"(?<![\w-])-" + re.escape(param) + r"\b", README, re.I):
                    missing.append(f"{name}: -{param}")
        for flag in re.findall(r'add_argument\("(--[\w-]+)"', (ROOT / "server.py").read_text(encoding="utf-8")):
            if flag not in README:
                missing.append(f"server.py: {flag}")
        self.assertEqual(missing, [], "In der README (Parameter-Tabelle) dokumentieren:\n" + "\n".join(missing))

    def test_readme_references_existing_files(self):
        refs = set(re.findall(r"`\.?\\?/?([\w./\\-]+\.(?:py|ps1|js|html|css|md))\b", README))
        refs |= set(re.findall(r"\b((?:ps|static|tests)/[\w./-]+)", README))
        missing = sorted(r for r in refs if not (ROOT / r.replace("\\", "/")).exists())
        self.assertEqual(missing, [], "README verweist auf fehlende Dateien: " + ", ".join(missing))
        self.assertGreater(len(refs), 3, "Referenz-Extraktion findet fast nichts (Check defekt?)")


if __name__ == "__main__":
    unittest.main()
