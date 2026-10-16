"""Erzeugt die Ein-Datei-Skripte aus ps/*.template.ps1 (+ ps/part-vcard.ps1, static/*):

* iCloud-Kontakte.ps1                 (Export-App)
* Import-VCardToExchangeOnline.ps1    (Importer)
"""
from pathlib import Path

root = Path(__file__).parent
vcard_part = (root / "ps" / "part-vcard.ps1").read_text(encoding="utf-8").rstrip()


def build(template, out, extra=()):
    tpl = (root / "ps" / template).read_text(encoding="utf-8").replace("@@VCARD@@", vcard_part)
    for key, f in extra:
        body = (root / "static" / f).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")
        assert "\n'@" not in "\n" + body, f"{f} enthält Here-String-Terminator"
        tpl = tpl.replace(key, body)
    # UTF-8 mit BOM, damit Windows PowerShell 5.1 Umlaute sicher richtig liest
    (root / out).write_text(tpl.replace("\r\n", "\n").replace("\n", "\r\n"), encoding="utf-8-sig", newline="")
    print(out, "erzeugt")


build("iCloud-Kontakte.template.ps1", "iCloud-Kontakte.ps1",
      (("@@INDEX@@", "index.html"), ("@@STYLE@@", "style.css"), ("@@APP@@", "app.js")))
if (root / "ps" / "Import-VCardToExchangeOnline.template.ps1").exists():
    build("Import-VCardToExchangeOnline.template.ps1", "Import-VCardToExchangeOnline.ps1")
