# iCloud-Kontakte Export

Kleine lokale Web-App (Python, nur Standardbibliothek – nichts zu installieren), mit der Sie Ihre
iCloud-Kontakte ansehen, durchsuchen und als **vCard (.vcf)** exportieren können.

## Wichtig: Anmeldung bei Apple

Apple bietet **keine öffentliche OAuth-Schnittstelle für Kontakte** („Sign in with Apple“ liefert keinen
Kontaktzugriff). Der offizielle Weg für Fremd-Apps ist **CardDAV** (`https://contacts.icloud.com`) mit

* Ihrer **Apple-ID** (E-Mail) und
* einem **app-spezifischen Passwort** – *nicht* Ihrem normalen Apple-Passwort.

So erzeugen Sie das app-spezifische Passwort:

1. Für die Apple-ID muss die **Zwei-Faktor-Authentifizierung** aktiv sein.
2. <https://appleid.apple.com> öffnen und anmelden.
3. **Anmelden und Sicherheit → App-spezifische Passwörter** → neues Passwort erzeugen (Name z. B. „Kontakte-Export“).
4. Das Passwort im Format `xxxx-xxxx-xxxx-xxxx` in der App eintragen. Nach dem Export können Sie es dort wieder widerrufen.

## Start

Voraussetzung: Python 3.9+ (getestet mit 3.12).

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
  (gegen den Mock-Server).

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
* Zugangsdaten und Kontakte liegen **nur im Arbeitsspeicher**; nichts wird auf die Platte geschrieben (außer Ihren Downloads).
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
* Der Login wurde bisher nur gegen den Mock getestet, nicht gegen echte iCloud-Server.
* Kontaktgruppen und Kontaktbilder in externen URLs werden nicht gesondert behandelt.
