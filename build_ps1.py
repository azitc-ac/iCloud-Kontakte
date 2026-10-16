"""Erzeugt die Ein-Datei-Skripte aus ps/*.template.ps1 (+ ps/part-vcard.ps1, static/*):

* iCloud-Kontakte.ps1                 (Export-App)
* Import-VCardToExchangeOnline.ps1    (Importer)

`render()` liefert den Soll-Inhalt; tests/test_repo_checks.py vergleicht ihn mit den eingecheckten Dateien.
"""
from pathlib import Path

root = Path(__file__).parent

TARGETS = [
    ("iCloud-Kontakte.template.ps1", "iCloud-Kontakte.ps1",
     (("@@INDEX@@", "index.html"), ("@@STYLE@@", "style.css"), ("@@APP@@", "app.js"))),
    ("Import-VCardToExchangeOnline.template.ps1", "Import-VCardToExchangeOnline.ps1", ()),
]


def render(template, extra=()):
    """Soll-Text der generierten Datei (UTF-8, CRLF; beim Schreiben kommt ein BOM davor)."""
    vcard_part = (root / "ps" / "part-vcard.ps1").read_text(encoding="utf-8").rstrip()
    tpl = (root / "ps" / template).read_text(encoding="utf-8").replace("@@VCARD@@", vcard_part)
    for key, f in extra:
        body = (root / "static" / f).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")
        assert "\n'@" not in "\n" + body, f"{f} enthält Here-String-Terminator"
        tpl = tpl.replace(key, body)
    return tpl.replace("\r\n", "\n").replace("\n", "\r\n")


def main():
    for template, out, extra in TARGETS:
        # UTF-8 mit BOM, damit Windows PowerShell 5.1 Umlaute sicher richtig liest
        (root / out).write_text(render(template, extra), encoding="utf-8-sig", newline="")
        print(out, "erzeugt")


if __name__ == "__main__":
    main()
