"""Mock-CardDAV-Server (nur Tests/Demo): imitiert die iCloud-Abläufe lokal.

Start:  python mock_carddav.py --port 8766 [--count 250]
Login:  Apple-ID test@example.com, Passwort abcd-efgh-ijkl-mnop
"""
import argparse
import base64
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USER, PASSWORD = "test@example.com", "abcd-efgh-ijkl-mnop"
# 1x1-PNG als Beispielfoto
PNG = base64.b64encode(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)).decode()
NAMES = [("Anna", "Müller"), ("Jörg", "Schröder"), ("Łukasz", "Nowak"), ("Chloé", "Dubois"),
         ("Max", "Mustermann"), ("Zoë", "Ärztin"), ("Ola", "Nordmann")]


def make_card(i):
    given, family = NAMES[i % len(NAMES)]
    family = f"{family}{i:04d}"
    if i % 2:  # vCard 4.0, ungerade
        lines = ["BEGIN:VCARD", "VERSION:4.0", f"UID:mock-{i}", f"FN:{given} {family}", f"N:{family};{given};;;",
                 f"TEL;TYPE=cell:+49 170 {i:07d}", f"EMAIL;TYPE=work:{given.lower()}{i}@example.com",
                 f"ORG:Firma {i % 5};Abteilung", "TITLE:Leiter, Test",
                 f"ADR;TYPE=home:;;Hauptstr. {i};Berlin;;10115;Deutschland", "NOTE:Zeile1\\nZeile2; mit Semikolon",
                 "END:VCARD"]
        if i % 3 == 1:
            lines.insert(-1, f"PHOTO:data:image/png;base64,{PNG}")
    else:  # vCard 3.0 im Apple-Stil mit item-Gruppen, Foto, Faltung
        lines = ["BEGIN:VCARD", "VERSION:3.0", f"UID:mock-{i}", f"FN:{given} {family}", f"N:{family};{given};;;",
                 f"item1.TEL;type=pref:+49 30 {i:07d}", "item1.X-ABLabel:_$!<Mobile>!$_",
                 f"EMAIL;type=INTERNET;type=HOME:{given.lower()}{i}@example.org",
                 "NOTE:Eine sehr lange Notiz, die gefaltet werden muss, damit der Parser das Entfalten "
                 "von Zeilen mit Leerzeichen am Anfang korrekt nachweisen kann."]
        if i % 4 == 0:
            lines.insert(-0 or len(lines), f"PHOTO;ENCODING=b;TYPE=PNG:{PNG}")
        lines.append("END:VCARD")
    folded = []
    for ln in lines:
        while len(ln.encode()) > 75:
            folded.append(ln[:70])
            ln = " " + ln[70:]
        folded.append(ln)
    return "\r\n".join(folded) + "\r\n"


def build(count):
    return {f"/dav/home/card/c{i}.vcf": make_card(i) for i in range(count)}


def multi(parts):
    return ('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:carddav">' + "".join(parts) + "</d:multistatus>").encode()


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def handler_for(cards):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=b"", headers=None):
            self.send_response(code)
            self.send_header("Content-Type", "application/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def handle_any(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode() if n else ""
            expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
            if self.headers.get("Authorization") != expected:
                return self.reply(401, b"", {"WWW-Authenticate": 'Basic realm="mock"'})
            p = self.path
            if self.command == "PROPFIND":
                if p == "/":
                    return self.reply(301, b"", {"Location": "/dav/"})  # wie iCloud: Weiterleitung
                if p == "/dav/":
                    return self.reply(207, multi(['<d:response><d:href>/dav/</d:href><d:propstat><d:prop>'
                        '<d:current-user-principal><d:href>/dav/principal/</d:href></d:current-user-principal>'
                        '</d:prop></d:propstat></d:response>']))
                if p == "/dav/principal/":
                    return self.reply(207, multi(['<d:response><d:href>/dav/principal/</d:href><d:propstat><d:prop>'
                        '<c:addressbook-home-set><d:href>http://127.0.0.1:%d/dav/home/</d:href></c:addressbook-home-set>'
                        '</d:prop></d:propstat></d:response>' % self.server.server_address[1]]))
                if p == "/dav/home/":
                    return self.reply(207, multi([
                        '<d:response><d:href>/dav/home/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/>'
                        '</d:resourcetype></d:prop></d:propstat></d:response>',
                        '<d:response><d:href>/dav/home/card/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/>'
                        '<c:addressbook/></d:resourcetype><d:displayname>Kontakte</d:displayname></d:prop></d:propstat></d:response>']))
                if p == "/dav/home/card/":
                    items = ['<d:response><d:href>/dav/home/card/</d:href><d:propstat><d:prop/></d:propstat></d:response>']
                    items += [f'<d:response><d:href>{h}</d:href><d:propstat><d:prop><d:getetag>"1"</d:getetag>'
                              '<d:getcontenttype>text/vcard</d:getcontenttype></d:prop></d:propstat></d:response>'
                              for h in cards]
                    return self.reply(207, multi(items))
            if self.command == "REPORT" and p == "/dav/home/card/":
                hrefs = re.findall(r"<d:href>([^<]+)</d:href>", body)
                if len(hrefs) > 100:
                    return self.reply(507, b"")  # wie echte Server: Blockgröße begrenzt
                items = [f'<d:response><d:href>{h}</d:href><d:propstat><d:prop><d:getetag>"1"</d:getetag>'
                         f'<c:address-data>{esc(cards[h])}</c:address-data></d:prop></d:propstat></d:response>'
                         for h in hrefs if h in cards]
                return self.reply(207, multi(items))
            self.reply(404)

        do_PROPFIND = do_REPORT = do_GET = handle_any

    return H


def make_server(port=0, count=250):
    return ThreadingHTTPServer(("127.0.0.1", port), handler_for(build(count)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--count", type=int, default=250)
    a = ap.parse_args()
    s = make_server(a.port, a.count)
    print(f"Mock-CardDAV auf http://127.0.0.1:{a.port}/  Login: {USER} / {PASSWORD}  ({a.count} Kontakte)")
    s.serve_forever()
