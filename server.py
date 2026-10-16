"""iCloud-Kontakte anzeigen & als vCard exportieren – lokale Web-App.

Start:  python server.py            (öffnet http://127.0.0.1:8765)
Zugangsdaten liegen nur im Arbeitsspeicher dieses Prozesses.
"""
import argparse
import io
import json
import mimetypes
import re
import secrets
import threading
import time
import urllib.parse
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import carddav
import vcard

STATIC = Path(__file__).parent / "static"
IDLE_SECONDS = 30 * 60
COOKIE = "ice_session"


class Session:
    def __init__(self, user, client, books):
        self.user, self.client, self.books = user, client, books
        self.contacts = {}          # id -> {"raw", "info"}
        self.job = {"state": "idle", "done": 0, "total": 0, "error": None}
        self.last = time.time()
        self.lock = threading.Lock()

    def load(self, book_url):
        def progress(done, total):
            self.job.update(done=done, total=total)
        try:
            cards = self.client.fetch_all(book_url, progress)
            contacts = {}
            for n, (href, raw) in enumerate(cards):
                info = vcard.parse(raw)
                info["id"] = str(n)
                contacts[str(n)] = {"raw": raw, "info": info}
            self.contacts = contacts
            self.job.update(state="done", error=None)
        except carddav.CardDAVError as e:
            self.job.update(state="error", error=str(e))
        except Exception as e:  # nie Zugangsdaten in Meldungen
            self.job.update(state="error", error=f"Unerwarteter Fehler: {type(e).__name__}")


class App:
    def __init__(self, carddav_url=None):
        self.sessions = {}
        self.lock = threading.Lock()
        self.carddav_url = carddav_url  # nur für Tests mit lokalem Mock
        self.port = None

    def new_client(self, user, pw):
        if self.carddav_url:
            host = urllib.parse.urlsplit(self.carddav_url).hostname
            return carddav.Client(user, pw, self.carddav_url, allow_host=host)
        return carddav.Client(user, pw)

    def get(self, handler):
        c = handler.cookies().get(COOKIE)
        with self.lock:
            now = time.time()
            for k in [k for k, s in self.sessions.items() if now - s.last > IDLE_SECONDS]:
                del self.sessions[k]
            s = self.sessions.get(c)
            if s:
                s.last = now
            return s


def auth_message(user):
    return ("Apple hat die Anmeldung abgelehnt. Prüfe: (1) Es muss ein APP-SPEZIFISCHES Passwort "
            "verwendet werden (Format xxxx-xxxx-xxxx-xxxx), nicht das normale Apple-Passwort. "
            "(2) Dafür muss die Zwei-Faktor-Authentifizierung für die Apple-ID aktiv sein. "
            "(3) Apple-ID exakt eingeben (E-Mail-Adresse). (4) Bei Zweifeln unter appleid.apple.com "
            "ein neues app-spezifisches Passwort erzeugen.")


def make_handler(app):
    class H(BaseHTTPRequestHandler):
        server_version = "ICE/1.0"

        def log_message(self, *a):  # keine Zugriffsprotokolle
            pass

        def cookies(self):
            out = {}
            for part in self.headers.get("Cookie", "").split(";"):
                if "=" in part:
                    k, v = part.strip().split("=", 1)
                    out[k] = v
            return out

        def _host_ok(self):
            host = (self.headers.get("Host") or "").lower()
            return host in (f"127.0.0.1:{app.port}", f"localhost:{app.port}")

        def _send(self, code, body, ctype="application/json; charset=utf-8", headers=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                             "script-src 'self'; frame-ancestors 'none'")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _err(self, code, msg, kind="error"):
            self._send(code, {"error": msg, "kind": kind})

        def _json_body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > 5_000_000:
                raise ValueError("zu groß")
            return json.loads(self.rfile.read(n) or b"{}")

        # ---------------- GET ----------------
        def handle_one_request(self):
            try:
                super().handle_one_request()
            except Exception as e:
                print("Fehler:", type(e).__name__, e)

        def do_GET(self):
            if not self._host_ok():
                return self._err(403, "Ungültiger Host")
            path = urllib.parse.urlsplit(self.path).path
            if not path.startswith("/api/"):
                return self._static(path)
            s = app.get(self)
            if not s:
                return self._err(401, "Nicht angemeldet.", "session")
            m = re.fullmatch(r"/api/(contact|photo)/(\d+)", path)
            if path == "/api/state":
                return self._send(200, {"user": s.user, "books": s.books, "job": s.job})
            if path == "/api/contacts":
                items = sorted((c["info"] for c in s.contacts.values()), key=vcard.sort_key)
                return self._send(200, [{k: i[k] for k in ("id", "fn", "family", "given", "org")}
                                        | {"phone": i["phones"][0]["value"] if i["phones"] else "",
                                           "email": i["emails"][0]["value"] if i["emails"] else "",
                                           "hasPhoto": i["hasPhoto"]} for i in items])
            if m:
                c = s.contacts.get(m.group(2))
                if not c:
                    return self._err(404, "Kontakt nicht gefunden.")
                if m.group(1) == "contact":
                    return self._send(200, c["info"])
                ph = vcard.extract_photo(c["raw"])
                if not ph or not re.fullmatch(r"image/(jpeg|png|gif|webp)", ph[0]):
                    return self._err(404, "Kein Foto.")
                return self._send(200, ph[1], ph[0])
            return self._err(404, "Unbekannt")

        def _static(self, path):
            name = "index.html" if path in ("/", "") else path.lstrip("/")
            f = (STATIC / name).resolve()
            if STATIC.resolve() not in f.parents or not f.is_file():
                return self._err(404, "Nicht gefunden")
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype.endswith("javascript"):
                ctype += "; charset=utf-8"
            self._send(200, f.read_bytes(), ctype)

        # ---------------- POST ----------------
        def do_POST(self):
            if not self._host_ok():
                return self._err(403, "Ungültiger Host")
            if self.headers.get("X-Requested-With") != "ICE":
                return self._err(403, "CSRF-Schutz: Header fehlt")
            path = urllib.parse.urlsplit(self.path).path
            try:
                body = self._json_body()
            except Exception:
                return self._err(400, "Ungültige Anfrage")
            if path == "/api/login":
                return self._login(body)
            s = app.get(self)
            if not s:
                return self._err(401, "Nicht angemeldet.", "session")
            if path == "/api/logout":
                with app.lock:
                    app.sessions.pop(self.cookies().get(COOKIE), None)
                return self._send(200, {"ok": True}, headers={
                    "Set-Cookie": f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"})
            if path == "/api/load":
                book = body.get("book")
                if book not in [b["url"] for b in s.books]:
                    return self._err(400, "Unbekanntes Adressbuch.")
                with s.lock:
                    if s.job["state"] == "loading":
                        return self._err(409, "Ladevorgang läuft bereits.")
                    s.contacts = {}
                    s.job.update(state="loading", done=0, total=0, error=None)
                threading.Thread(target=s.load, args=(book,), daemon=True).start()
                return self._send(202, {"ok": True})
            if path == "/api/export":
                return self._export(s, body)
            return self._err(404, "Unbekannt")

        def _login(self, body):
            user = str(body.get("appleId", "")).strip()
            pw = str(body.get("password", "")).strip()
            if not user or not pw:
                return self._err(400, "Bitte Apple-ID und app-spezifisches Passwort eingeben.")
            try:
                client = app.new_client(user, pw)
                books = client.discover()
            except carddav.AuthError:
                return self._err(401, auth_message(user), "auth")
            except carddav.CardDAVError as e:
                return self._err(e.status, str(e), e.kind)
            token = secrets.token_urlsafe(32)
            with app.lock:
                app.sessions[token] = Session(user, client, books)
            self._send(200, {"user": user, "books": books}, headers={
                "Set-Cookie": f"{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict"})

        def _export(self, s, body):
            if not s.contacts:
                return self._err(400, "Keine Kontakte geladen.")
            ids = body.get("ids")
            if ids == "all" or ids is None:
                chosen = sorted(s.contacts.values(), key=lambda c: vcard.sort_key(c["info"]))
            else:
                chosen = [s.contacts[str(i)] for i in ids if str(i) in s.contacts]
            if not chosen:
                return self._err(400, "Keine Kontakte ausgewählt.")
            stamp = time.strftime("%Y-%m-%d")
            if body.get("format") == "zip":
                buf, used = io.BytesIO(), set()
                with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
                    for c in chosen:
                        base = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", c["info"]["fn"]).strip(" .")[:80] or "Kontakt"
                        name, n = base, 1
                        while name.lower() in used:
                            n += 1
                            name = f"{base} ({n})"
                        used.add(name.lower())
                        z.writestr(name + ".vcf", _norm(c["raw"]))
                data, ctype, fname = buf.getvalue(), "application/zip", f"iCloud-Kontakte-{stamp}.zip"
            else:
                data = "".join(_norm(c["raw"]) for c in chosen).encode("utf-8")
                ctype, fname = "text/vcard; charset=utf-8", f"iCloud-Kontakte-{stamp}.vcf"
            self._send(200, data, ctype, {
                "Content-Disposition": f"attachment; filename=\"{fname}\"",
                "X-Count": str(len(chosen))})

    return H


def _norm(raw):
    """Inhalt unverändert; nur Zeilenenden einheitlich auf CRLF (RFC 6350), da XML sie ohnehin normalisiert."""
    t = raw.replace("\r\n", "\n").replace("\r", "\n").strip("\n")
    return t.replace("\n", "\r\n") + "\r\n"


def make_server(host="127.0.0.1", port=8765, carddav_url=None):
    app = App(carddav_url)
    srv = ThreadingHTTPServer((host, port), make_handler(app))
    app.port = srv.server_address[1]
    srv.app = app
    return srv


def main():
    ap = argparse.ArgumentParser(description="iCloud-Kontakte anzeigen und als vCard exportieren")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--carddav-url", help="nur für Tests: Mock-CardDAV-Server statt iCloud (z. B. http://127.0.0.1:8766/)")
    a = ap.parse_args()
    srv = make_server("127.0.0.1", a.port, a.carddav_url)
    url = f"http://127.0.0.1:{srv.app.port}/"
    print(f"Läuft auf {url}  (nur lokal erreichbar; Beenden mit Strg+C)")
    if not a.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
