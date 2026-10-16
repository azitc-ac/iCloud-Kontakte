"""Erzeugt die Ein-Datei-Variante iCloud-Kontakte.ps1 aus ps/iCloud-Kontakte.template.ps1 + static/*."""
from pathlib import Path

root = Path(__file__).parent
tpl = (root / "ps" / "iCloud-Kontakte.template.ps1").read_text(encoding="utf-8")
for key, f in (("@@INDEX@@", "index.html"), ("@@STYLE@@", "style.css"), ("@@APP@@", "app.js")):
    body = (root / "static" / f).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n")
    assert "\n'@" not in "\n" + body, f"{f} enthält Here-String-Terminator"
    tpl = tpl.replace(key, body)
# UTF-8 mit BOM, damit Windows PowerShell 5.1 Umlaute sicher richtig liest
(root / "iCloud-Kontakte.ps1").write_text(tpl.replace("\r\n", "\n").replace("\n", "\r\n"), encoding="utf-8-sig", newline="")
print("iCloud-Kontakte.ps1 erzeugt")
