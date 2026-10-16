"""Mock für Microsoft Graph (Kontakte) + Device-Code-Anmeldung – nur für Tests des Importers.

Start:  python mock_graph.py --port 8790
"""
import argparse
import json
import re
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "mock-access-token"
PAGE = 50


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.n = 0
        self.folders = {"F-DEF": {"displayName": "Contacts", "parent": None},
                        "F-PRIV": {"displayName": "Privat", "parent": None},
                        "F-ALT": {"displayName": "Alt", "parent": "F-PRIV"}}
        self.contacts = {"F-DEF": [], "F-PRIV": [], "F-ALT": []}   # Ordner-ID -> Kontakte
        self.default_id = "F-DEF"
        self.photos = {}          # Kontakt-ID -> (content-type, Länge)
        self.token_polls = 0
        self.throttled = set()

    def new_id(self, prefix):
        self.n += 1
        return f"{prefix}{self.n}"


def make_server(port=0):
    st = State()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send_json(self, code, obj, headers=None):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(b)

        def body(self):
            return self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def authed(self):
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                self.send_json(401, {"error": {"code": "InvalidAuthenticationToken", "message": "Token ungültig"}})
                return False
            return True

        # ---- Graph-Logik (path ohne /v1.0) ----
        def handle_graph(self, method, path, query, data):
            with st.lock:
                m = re.fullmatch(r"/me/contactFolders(?:/([^/]+)/childFolders)?", path)
                if m:
                    parent = m.group(1)
                    if method == "GET":
                        vals = [{"id": i, "displayName": f["displayName"]} for i, f in st.folders.items() if f["parent"] == parent]
                        return 200, {"value": vals}
                    if method == "POST":
                        i = st.new_id("F-")
                        st.folders[i] = {"displayName": data["displayName"], "parent": parent}
                        st.contacts[i] = []
                        return 201, {"id": i, "displayName": data["displayName"]}
                m = re.fullmatch(r"/me/contacts|/me/contactFolders/([^/]+)/contacts", path)
                if m:
                    fid = m.group(1) or st.default_id
                    if fid not in st.contacts:
                        return 404, {"error": {"message": "Ordner nicht gefunden"}}
                    if method == "GET":
                        skip = int(query.get("skip", ["0"])[0])
                        page = st.contacts[fid][skip:skip + PAGE]
                        out = {"value": [{"displayName": c.get("displayName"), "emailAddresses": c.get("emailAddresses", [])} for c in page]}
                        if skip + PAGE < len(st.contacts[fid]):
                            q = urllib.parse.urlencode({"skip": skip + PAGE})
                            out["@odata.nextLink"] = f"http://127.0.0.1:{self.server.server_address[1]}/v1.0{path}?{q}"
                        return 200, out
                    if method == "POST":
                        if data["displayName"].startswith("Max Mustermann0004") and data["displayName"] not in st.throttled:
                            st.throttled.add(data["displayName"])
                            return 429, {"error": {"message": "Throttled"}}
                        c = dict(data)
                        c["id"] = st.new_id("C-")
                        c["_folder"] = fid
                        st.contacts[fid].append(c)
                        return 201, c
                m = re.fullmatch(r"/me/contacts/([^/]+)/photo/\$value", path)
                if m and method == "PUT":
                    st.photos[m.group(1)] = (self.headers.get("Content-Type"), self._len)
                    return 200, {}
            return 404, {"error": {"message": f"unbekannt: {method} {path}"}}

        def route(self, method):
            raw = self.body()
            self._len = len(raw)
            u = urllib.parse.urlsplit(self.path)
            path, query = u.path, urllib.parse.parse_qs(u.query)
            # --- Anmeldung ---
            if path.endswith("/oauth2/v2.0/devicecode"):
                return self.send_json(200, {"device_code": "dc", "user_code": "ABCD1234", "verification_uri": "http://127.0.0.1/devicelogin",
                                            "expires_in": 300, "interval": 1, "message": "Mock: Code ABCD1234 eingeben"})
            if path.endswith("/oauth2/v2.0/token"):
                form = urllib.parse.parse_qs(raw.decode())
                if form.get("grant_type", [""])[0].endswith("device_code"):
                    st.token_polls += 1
                    if st.token_polls < 2:
                        return self.send_json(400, {"error": "authorization_pending"})
                return self.send_json(200, {"access_token": TOKEN, "refresh_token": "rt", "expires_in": 3600})
            if not path.startswith("/v1.0/") or not self.authed():
                if path.startswith("/v1.0/"):
                    return
                return self.send_json(404, {"error": {"message": "unbekannt"}})
            path = path[len("/v1.0"):]
            if path == "/$batch" and method == "POST":
                resp = []
                for r in json.loads(raw)["requests"]:
                    code, body = self.handle_graph(r["method"], r["url"], {}, r.get("body"))
                    item = {"id": r["id"], "status": code, "body": body}
                    if code == 429:
                        item["headers"] = {"Retry-After": "1"}
                    resp.append(item)
                return self.send_json(200, {"responses": resp})
            data = json.loads(raw) if raw and "json" in (self.headers.get("Content-Type") or "") else None
            code, body = self.handle_graph(method, path, query, data)
            self.send_json(code, body)

        def do_GET(self): self.route("GET")
        def do_POST(self): self.route("POST")
        def do_PUT(self): self.route("PUT")

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.state = st
    return srv


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8790)
    a = ap.parse_args()
    print(f"Mock-Graph auf http://127.0.0.1:{a.port}/  (GraphBase /v1.0, LoginBase /)")
    make_server(a.port).serve_forever()
