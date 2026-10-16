"""Minimaler vCard-Parser (2.1/3.0/4.0) nur für die Anzeige.

Exportiert wird immer der unveränderte Originaltext; geparst wird nur,
um Liste und Detailansicht zu füllen.
"""
import base64
import re
import urllib.parse


def unfold(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return re.sub(r"\n[ \t]", "", text).split("\n")


def _unescape(v):
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            n = v[i + 1]
            out.append("\n" if n in "nN" else n)
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _split_unescaped(v, sep):
    parts, cur, i = [], [], 0
    while i < len(v):
        if v[i] == "\\" and i + 1 < len(v):
            cur.append(v[i:i + 2])
            i += 2
        elif v[i] == sep:
            parts.append("".join(cur))
            cur = []
            i += 1
        else:
            cur.append(v[i])
            i += 1
    parts.append("".join(cur))
    return parts


def _parse_line(line):
    """-> (group, name, params{name:[values]}, value) oder None."""
    in_q, colon = False, -1
    for i, ch in enumerate(line):
        if ch == '"':
            in_q = not in_q
        elif ch == ":" and not in_q:
            colon = i
            break
    if colon < 0:
        return None
    head, value = line[:colon], line[colon + 1:]
    segs, cur, in_q = [], [], False
    for ch in head:
        if ch == '"':
            in_q = not in_q
            cur.append(ch)
        elif ch == ";" and not in_q:
            segs.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    segs.append("".join(cur))
    name = segs[0]
    group = ""
    if "." in name:
        group, name = name.split(".", 1)
    params = {}
    for s in segs[1:]:
        if "=" in s:
            k, v = s.split("=", 1)
            params.setdefault(k.upper(), []).extend(x.strip('"') for x in v.split(","))
        elif s:  # vCard 2.1: nacktes TYPE
            params.setdefault("TYPE", []).append(s)
    return group, name.upper(), params, value


_LABEL_RE = re.compile(r"^_\$!<(.*)>!\$_$")


def _types(params, label):
    if label:
        return label
    t = [x.lower() for x in params.get("TYPE", []) if x.lower() not in ("pref", "internet", "voice")]
    return ", ".join(t)


def parse(raw):
    """Zerlegt eine einzelne vCard in ein Dict für die UI."""
    props, labels = [], {}
    for line in unfold(raw):
        p = _parse_line(line)
        if not p:
            continue
        group, name, params, value = p
        if name == "X-ABLABEL" and group:
            m = _LABEL_RE.match(value)
            labels[group] = m.group(1) if m else value
        props.append(p)

    c = {"version": "", "uid": "", "fn": "", "family": "", "given": "", "org": "", "title": "",
         "phones": [], "emails": [], "addresses": [], "urls": [], "birthday": "", "note": "",
         "hasPhoto": False}
    for group, name, params, value in props:
        label = labels.get(group, "")
        if name == "VERSION":
            c["version"] = value
        elif name == "UID":
            c["uid"] = value
        elif name == "FN":
            c["fn"] = _unescape(value)
        elif name == "N":
            f = _split_unescaped(value, ";") + ["", ""]
            c["family"], c["given"] = _unescape(f[0]), _unescape(f[1])
        elif name == "ORG":
            c["org"] = " / ".join(_unescape(x) for x in _split_unescaped(value, ";") if x)
        elif name == "TITLE":
            c["title"] = _unescape(value)
        elif name == "TEL":
            v = _unescape(value)
            c["phones"].append({"type": _types(params, label), "value": v[4:] if v.startswith("tel:") else v})
        elif name == "EMAIL":
            c["emails"].append({"type": _types(params, label), "value": _unescape(value)})
        elif name == "ADR":
            f = (_split_unescaped(value, ";") + [""] * 7)[:7]
            f = [_unescape(x) for x in f]
            street, city, region, zipc, country = f[2], f[3], f[4], f[5], f[6]
            lines = [street, " ".join(x for x in (zipc, city) if x), region, country]
            c["addresses"].append({"type": _types(params, label), "value": "\n".join(x for x in lines if x)})
        elif name == "URL":
            c["urls"].append({"type": _types(params, label), "value": _unescape(value)})
        elif name == "BDAY":
            c["birthday"] = value
        elif name == "NOTE":
            c["note"] = _unescape(value)
        elif name == "PHOTO":
            c["hasPhoto"] = True
    if not c["fn"]:
        c["fn"] = (" ".join(x for x in (c["given"], c["family"]) if x) or c["org"]
                   or (c["emails"][0]["value"] if c["emails"] else "") or "(ohne Namen)")
    return c


def extract_photo(raw):
    """-> (mime, bytes) oder None."""
    for line in unfold(raw):
        p = _parse_line(line)
        if not p or p[1] != "PHOTO":
            continue
        _, _, params, value = p
        try:
            if value.lower().startswith("data:"):
                meta, _, data = value[5:].partition(",")
                mime = meta.split(";")[0] or "image/jpeg"
                if ";base64" in meta:
                    return mime, base64.b64decode(data)
                return mime, urllib.parse.unquote_to_bytes(data)
            if value.lower().startswith(("http://", "https://")):
                return None  # externe URLs laden wir bewusst nicht (Datenschutz)
            typ = (params.get("TYPE") or ["JPEG"])[0].lower()
            mime = typ if "/" in typ else "image/" + ("jpeg" if typ == "jpg" else typ)
            return mime, base64.b64decode(value)
        except Exception:
            return None
    return None


def sort_key(c):
    return (c["family"] or c["fn"]).casefold(), (c["given"] or "").casefold()
