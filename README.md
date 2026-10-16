<img width="970" height="974" alt="image" src="https://github.com/user-attachments/assets/81b5ed2a-86af-4b50-84db-178b98f2e016" />

# iCloud-Kontakte Export

Kleine lokale Web-App (Python, nur Standardbibliothek – nichts zu installieren), mit der Du Deine
iCloud-Kontakte ansehen, durchsuchen und als **vCard (.vcf)** exportieren können.

## Wichtig: Anmeldung bei Apple

Apple bietet **keine öffentliche OAuth-Schnittstelle für Kontakte** („Sign in with Apple“ liefert keinen
Kontaktzugriff). Der offizielle Weg für Fremd-Apps ist **CardDAV** (`https://contacts.icloud.com`) mit

* Deiner **Apple-ID** (E-Mail) und
* einem **app-spezifischen Passwort** – *nicht* Deinem normalen Apple-Passwort.
<img width="858" height="658" alt="image" src="https://github.com/user-attachments/assets/471e622f-3433-4857-aded-4b87dfb1fd68" />

So erzeugst Du das app-spezifische Passwort:

1. Für die Apple-ID muss die **Zwei-Faktor-Authentifizierung** aktiv sein.
2. <https://appleid.apple.com> öffnen und anmelden.
3. **Anmelden und Sicherheit → App-spezifische Passwörter** → neues Passwort erzeugen (Name z. B. „Kontakte-Export“).
4. Das Passwort im Format `xxxx-xxxx-xxxx-xxxx` in der App eintragen. Nach dem Export kannst Du es dort wieder widerrufen.
<img width="1044" height="648" alt="image" src="https://github.com/user-attachments/assets/75e48aca-ab69-4c59-9b62-f509152acda4" />

## Start

Voraussetzung: Python 3.9+ (getestet nur mit 3.12).

```powershell
python server.py
```

Der Browser öffnet <http://127.0.0.1:8765/>. Optionen: `--port 9000`, `--no-browser`.

## Variante als einzelne PowerShell-Datei (ohne Python)

`iCloud-Kontakte.ps1` enthält alles (Server, CardDAV, Oberfläche) in **einer Datei** und läuft mit Windows PowerShell 5.1
oder neuer – ohne Installation, ohne Adminrechte. Funktionsumfang und Datenschutz wie oben.

```powershell
powershell -ExecutionPolicy Bypass -File .\iCloud-Kontakte.ps1          # optional: -Port 9000 -NoBrowser
```

* Die Datei ist nach Download/Mail oft „blockiert“: einmalig `Unblock-File .\iCloud-Kontakte.ps1` ausführen
  oder den Aufruf mit `-ExecutionPolicy Bypass` wie oben nutzen.
* Beenden mit Strg+C. Die Adresse ist `http://127.0.0.1:8765/` (nicht `localhost`).
* Die Datei wird **generiert** (`python build_ps1.py`) aus `ps/iCloud-Kontakte.template.ps1` und `static/*`. Änderungen
  an der Oberfläche daher in `static/` machen und neu bauen; die Python-App nutzt dieselben Dateien.
* Tests: `python -m unittest discover -s tests -v` führt dieselben Abläufe gegen Python- **und** PowerShell-Variante aus
  (gegen den Mock-Server) und testet den Importer gegen den Graph-Mock.

## Import nach Exchange Online (Microsoft Graph)

`Import-VCardToExchangeOnline.ps1` (ebenfalls eine einzelne Datei; getestet mit Windows PowerShell 5.1 und PowerShell 7) importiert **einzelne oder alle**
vCards in einen **wählbaren Kontakteordner** des eigenen oder eines gemeinsamen Postfachs. Quellen: `.vcf` (auch Sammeldateien),
Ordner oder das ZIP aus dem Export.

```powershell
# interaktiv: Dateidialog, Auswahlliste der Kontakte, Auswahlliste der Ordner (Out-GridView)
powershell -ExecutionPolicy Bypass -File .\Import-VCardToExchangeOnline.ps1

# automatisch: alle Kontakte in Ordner "iCloud" (wird bei Bedarf angelegt); erst mit -WhatIf probieren
.\Import-VCardToExchangeOnline.ps1 -Path .\iCloud-Kontakte-2026-10-16.zip -All -Folder "iCloud" -CreateFolder -WhatIf
.\Import-VCardToExchangeOnline.ps1 -Path .\iCloud-Kontakte-2026-10-16.zip -All -Folder "iCloud" -CreateFolder
```
<img width="1184" height="1008" alt="image" src="https://github.com/user-attachments/assets/09199abb-69da-44ec-a7da-43dfaf9d3218" />

* **Anmeldung:** Device-Code-Flow (Browser + Code, MFA-fähig), delegierte Berechtigung `Contacts.ReadWrite`
  (`-Mailbox user@firma.de` für ein anderes Postfach zusätzlich `Contacts.ReadWrite.Shared`). Tokens nur im Speicher.
  Standardmäßig wird Microsofts öffentlicher Client „Microsoft Graph Command Line Tools“ genutzt. Ist er in Deiner Umgebung gesperrt
  (Zustimmung des Administrators nötig), eine eigene App-Registrierung (öffentlicher Client, Device-Code erlaubt,
  delegiert `Contacts.ReadWrite`) anlegen und per `-ClientId` übergeben; ggf. `-TenantId firma.de`.
* **Ordner:** `-Folder "Name"` oder `"Eltern/Kind"`; `Kontakte` = Standardordner; `-CreateFolder` legt fehlende Ordner an.
  Ohne `-Folder` erscheint eine Auswahlliste (inkl. „Neuen Ordner anlegen“).
* **Duplikate:** Kontakte mit gleichem Anzeigenamen + erster E-Mail im Zielordner werden übersprungen (`-AllowDuplicates` schaltet das ab).
* **Abbildung vCard → Outlook-Kontakt:** Name (inkl. Anrede/Zweitname/Zusatz), Firma/Abteilung/Position, Mobil-/Privat-/Geschäftstelefon,
  bis zu 3 E-Mails, Privat-/Geschäfts-/Sonstige Adresse, Webseite, Geburtstag (mit Jahr), Notiz, Foto. Was Outlook nicht
  fassen kann (z. B. 4. E-Mail, Fax, weitere Adressen) wird **nicht verworfen**, sondern unten in die Notiz geschrieben.
* Import in 20er-Blöcken per `$batch`, Wiederholung bei Drosselung (HTTP 429), Zusammenfassung und Fehlerliste am Ende; Exitcode 1 bei Fehlern.
* Grenzen: nur Anlegen, kein Aktualisieren bestehender Kontakte; Kategorien/Gruppen aus iCloud werden nicht übertragen.
  Automatische Tests laufen gegen einen Graph-Mock (`mock_graph.py`); manuell gegen Exchange Online erfolgreich getestet.

## Parameter

**`iCloud-Kontakte.ps1`**

| Parameter | Bedeutung |
|---|---|
| `-Port` | Port des lokalen Servers (Standard 8765) |
| `-NoBrowser` | Browser nicht automatisch öffnen |
| `-CardDavUrl` | nur für Tests: Mock-CardDAV-Server statt iCloud |

**`Import-VCardToExchangeOnline.ps1`**

| Parameter | Bedeutung |
|---|---|
| `-Path` | `.vcf`-Datei(en), Ordner oder `.zip` (ohne Angabe: Dateidialog) |
| `-All` | alle Kontakte importieren (sonst Auswahlliste) |
| `-Folder` / `-CreateFolder` | Zielordner (`Name` oder `Eltern/Kind`) / fehlende Ordner anlegen |
| `-Mailbox` | anderes oder gemeinsames Postfach |
| `-TenantId` / `-ClientId` | Mandant / App-ID für die Anmeldung |
| `-AllowDuplicates` | auch bereits vorhandene Kontakte anlegen |
| `-Force` | keine Rückfragen (Standardordner, wenn kein `-Folder` angegeben) |
| `-NoBrowser` | Anmelde-Seite nicht automatisch öffnen |
| `-WhatIf` | nur anzeigen, nichts anlegen |
| `-GraphBase` / `-LoginBase` | nur für Tests: Mock-Graph-Server statt Microsoft |

**`server.py`**: `--port`, `--no-browser`, `--carddav-url` (nur für Tests).

## Funktionen

* Anmeldung mit Apple-ID + app-spezifischem Passwort, mit Anleitung und Warnung bei falschem Passwortformat
* CardDAV-Discovery: Principal → addressbook-home-set → Adressbücher (Auswahl, falls mehrere)
* Laden in Blöcken (Multiget à 100 Kontakte) mit Fortschrittsanzeige – auch für große Adressbücher
* Liste mit Suche (Name, Firma, Telefon, E-Mail) und Sortierung (Nachname, Vorname, Firma)
* Detailansicht: Name, Firma/Titel, Telefon, E-Mail, Adresse, Web, Geburtstag, Notiz, Foto
* Export: einzelner Kontakt, Auswahl oder alle – als **Sammel-.vcf** oder **ZIP mit Einzeldateien**.
  Die vCards (3.0/4.0) werden **unverändert** durchgereicht, lediglich die Zeilenenden werden auf CRLF vereinheitlicht.
* Fehlermeldungen für falsche Zugangsdaten (mit Hinweisen zu 2FA/app-spezifischem Passwort), Netzwerkfehler, abgelaufene Sitzung

## Datenschutz & Sicherheit

* Server bindet **nur an 127.0.0.1**; Host-Header-Prüfung (gegen DNS-Rebinding) und CSRF-Header-Pflicht für alle POSTs.
* Zugangsdaten und Kontakte liegen **nur im Arbeitsspeicher**; nichts wird auf die Platte geschrieben (außer Deinen Downloads).
  Sitzung endet bei „Abmelden“, nach 30 Minuten Inaktivität oder beim Beenden des Programms.
* Zugangsdaten gehen **ausschließlich an `*.icloud.com` über HTTPS**; andere Ziele (auch per Weiterleitung) werden abgelehnt.
* Keine Telemetrie, keine externen Ressourcen (Fotos werden nur aus den vCards selbst angezeigt, externe Foto-URLs nicht geladen).

## Tests / Demo ohne echte Zugangsdaten

`mock_carddav.py` ist ein lokaler CardDAV-Mock (inkl. Weiterleitung, vCard 3.0 und 4.0, Apple-Labels, Fotos, Umlauten,
gefalteten Zeilen, Block-Limit beim Multiget).

```powershell
python -m unittest discover -s tests -v      # automatische Tests: Login, Fehler, Laden (250 Kontakte), Export, Logout
```

Manuell ausprobieren:

```powershell
python mock_carddav.py --port 8766                                          # Terminal 1
python server.py --carddav-url http://127.0.0.1:8766/                       # Terminal 2
# Login: test@example.com / abcd-efgh-ijkl-mnop
```

## Grenzen

* Nur Lesen/Export; keine Änderungen an iCloud.
* Getestet: Mock-Tests (automatisch) sowie manuell gegen echtes iCloud und Exchange Online (erfolgreich).
* Kontaktgruppen und Kontaktbilder in externen URLs werden nicht gesondert behandelt.
