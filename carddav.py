"""Schlanker CardDAV-Client (nur Standardbibliothek)."""
import base64
import ssl
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ICLOUD_URL = "https://contacts.icloud.com/"
DAV = "{DAV:}"
CARD = "{urn:ietf:params:xml:ns:carddav}"
BATCH = 100


class CardDAVError(Exception):
    def __init__(self, message, status=502, kind="error"):
        super().__init__(message)
        self.status, self.kind = status, kind


class AuthError(CardDAVError):
    def __init__(self):
        super().__init__("Anmeldung abgelehnt.", 401, "auth")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Client:
    def __init__(self, user, password, base_url=ICLOUD_URL, allow_host=None, timeout=60):
        self._auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.base_url = base_url
        self.timeout = timeout
        self._allow_host = allow_host  # nur für Tests mit lokalem Mock
        self._opener = urllib.request.build_opener(
            _NoRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def _check_host(self, url):
        u = urllib.parse.urlsplit(url)
        host = (u.hostname or "").lower()
        if self._allow_host and host == self._allow_host:
            return
        if u.scheme != "https" or not (host == "icloud.com" or host.endswith(".icloud.com")):
            raise CardDAVError(f"Ziel {host!r} ist kein iCloud-Server; Zugangsdaten werden dorthin nicht gesendet.")

    def request(self, method, url, body=None, depth=None):
        for _ in range(6):
            self._check_host(url)
            req = urllib.request.Request(url, data=body, method=method)
            req.add_header("Authorization", self._auth)
            req.add_header("User-Agent", "iCloud-Contacts-Export/1.0")
            if body is not None:
                req.add_header("Content-Type", "application/xml; charset=utf-8")
            if depth is not None:
                req.add_header("Depth", str(depth))
            try:
                with self._opener.open(req, timeout=self.timeout) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                    url = urllib.parse.urljoin(url, e.headers["Location"])
                    continue
                if e.code in (401, 403):
                    raise AuthError()
                raise CardDAVError(f"Server antwortete mit HTTP {e.code}.", 502)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                raise CardDAVError(f"Verbindung zum Server fehlgeschlagen: {getattr(e, 'reason', e)}", 504, "network")
        raise CardDAVError("Zu viele Weiterleitungen.")

    def _propfind(self, url, props, depth):
        body = ('<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" '
                'xmlns:c="urn:ietf:params:xml:ns:carddav"><d:prop>' + props + "</d:prop></d:propfind>").encode()
        _, data = self.request("PROPFIND", url, body, depth)
        try:
            return ET.fromstring(data)
        except ET.ParseError:
            raise CardDAVError("Ungültige XML-Antwort des Servers.")

    @staticmethod
    def _first_href(root, prop_tag):
        for el in root.iter(prop_tag):
            h = el.find(DAV + "href")
            if h is not None and (h.text or "").strip():
                return h.text.strip()
        return None

    def discover(self):
        """Principal -> addressbook-home-set -> Adressbücher. Liefert [{'url','name'}]."""
        root = self._propfind(self.base_url, "<d:current-user-principal/>", 0)
        principal = self._first_href(root, DAV + "current-user-principal")
        if not principal:
            raise CardDAVError("Kein Benutzer-Principal gefunden.")
        principal = urllib.parse.urljoin(self.base_url, principal)
        root = self._propfind(principal, "<c:addressbook-home-set/>", 0)
        home = self._first_href(root, CARD + "addressbook-home-set")
        if not home:
            raise CardDAVError("Kein Adressbuch-Verzeichnis gefunden.")
        home = urllib.parse.urljoin(principal, home)
        root = self._propfind(home, "<d:resourcetype/><d:displayname/>", 1)
        books = []
        for resp in root.iter(DAV + "response"):
            href = resp.findtext(DAV + "href")
            rt = resp.find(f".//{DAV}resourcetype")
            if href and rt is not None and rt.find(CARD + "addressbook") is not None:
                name = resp.findtext(f".//{DAV}displayname") or "Kontakte"
                books.append({"url": urllib.parse.urljoin(home, href), "name": name})
        if not books:
            raise CardDAVError("Keine Adressbücher gefunden.")
        return books

    def fetch_all(self, book_url, progress=None):
        """Alle vCards eines Adressbuchs: PROPFIND-Liste, dann Multiget in Blöcken."""
        root = self._propfind(book_url, "<d:getetag/><d:getcontenttype/>", 1)
        hrefs = []
        base_path = urllib.parse.urlsplit(book_url).path.rstrip("/")
        for resp in root.iter(DAV + "response"):
            href = resp.findtext(DAV + "href")
            if not href:
                continue
            path = urllib.parse.urlsplit(urllib.parse.urljoin(book_url, href)).path
            if path.rstrip("/") == base_path or path.endswith("/"):
                continue
            hrefs.append(href)
        if progress:
            progress(0, len(hrefs))
        cards = []
        for i in range(0, len(hrefs), BATCH):
            chunk = hrefs[i:i + BATCH]
            body = ('<?xml version="1.0" encoding="utf-8"?><c:addressbook-multiget xmlns:d="DAV:" '
                    'xmlns:c="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><c:address-data/></d:prop>'
                    + "".join(f"<d:href>{_esc(h)}</d:href>" for h in chunk)
                    + "</c:addressbook-multiget>").encode()
            _, data = self.request("REPORT", book_url, body, 1)
            try:
                r = ET.fromstring(data)
            except ET.ParseError:
                raise CardDAVError("Ungültige XML-Antwort beim Laden der Kontakte.")
            for resp in r.iter(DAV + "response"):
                ad = resp.find(f".//{CARD}address-data")
                if ad is not None and (ad.text or "").strip():
                    cards.append((resp.findtext(DAV + "href") or "", ad.text))
            if progress:
                progress(min(i + BATCH, len(hrefs)), len(hrefs))
        return cards
