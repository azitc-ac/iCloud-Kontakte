<#
.SYNOPSIS
    iCloud-Kontakte anzeigen und als vCard (.vcf) exportieren - lokale Web-App in einer einzigen PowerShell-Datei.

.DESCRIPTION
    Startet einen Webserver NUR auf 127.0.0.1 und oeffnet die Oberflaeche im Browser.
    Anmeldung per Apple-ID + APP-SPEZIFISCHEM Passwort (CardDAV, contacts.icloud.com).
    Zugangsdaten und Kontakte bleiben nur im Arbeitsspeicher. Beenden mit Strg+C.
    Voraussetzung: Windows PowerShell 5.1 oder neuer, sonst nichts.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\iCloud-Kontakte.ps1

.NOTES
    GENERIERT aus ps/iCloud-Kontakte.template.ps1 + static/* durch build_ps1.py - nicht von Hand bearbeiten.
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [string]$CardDavUrl   # nur fuer Tests: Mock-CardDAV-Server statt iCloud
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
try { [Net.ServicePointManager]::SecurityProtocol = 3072 -bor 12288 } catch { [Net.ServicePointManager]::SecurityProtocol = 3072 }
[Net.ServicePointManager]::Expect100Continue = $false
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:IdleSeconds = 1800
$script:Sessions = @{}
$script:AllowHost = $null
$script:BaseUrl = 'https://contacts.icloud.com/'
if ($CardDavUrl) {
    $script:BaseUrl = $CardDavUrl
    $script:AllowHost = ([Uri]$CardDavUrl).Host.ToLowerInvariant()
}

# ---------------------------------------------------------------- eingebettete Oberflaeche
$HtmlIndex = @'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iCloud-Kontakte Export</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header><h1>iCloud-Kontakte Export</h1><span id="who"></span><button id="logout" hidden>Abmelden</button></header>

<main id="login">
  <form id="loginForm" autocomplete="off">
    <h2>Mit Apple-Konto verbinden</h2>
    <div class="note">
      <strong>Wichtig:</strong> Apple erlaubt den Zugriff auf iCloud-Kontakte für Fremd-Apps nur über ein
      <strong>app-spezifisches Passwort</strong>. Ihr normales Apple-Passwort funktioniert hier nicht und wird nie verlangt.
      <ol>
        <li>Zwei-Faktor-Authentifizierung für Ihre Apple-ID aktivieren (Voraussetzung).</li>
        <li><a href="https://appleid.apple.com" target="_blank" rel="noopener noreferrer">appleid.apple.com</a> öffnen und anmelden.</li>
        <li>„Anmelden und Sicherheit“ → „App-spezifische Passwörter“ → neues Passwort erzeugen (z. B. „Kontakte-Export“).</li>
        <li>Das Passwort (Format <code>xxxx-xxxx-xxxx-xxxx</code>) unten eintragen. Danach können Sie es bei Apple wieder widerrufen.</li>
      </ol>
      Die Zugangsdaten bleiben nur im Arbeitsspeicher dieses lokalen Programms und gehen ausschließlich an Apples Server (<code>contacts.icloud.com</code>).
    </div>
    <label>Apple-ID (E-Mail)<input id="appleId" type="email" required autofocus></label>
    <label>App-spezifisches Passwort<input id="password" type="password" required placeholder="xxxx-xxxx-xxxx-xxxx"></label>
    <div id="pwWarn" class="warn" hidden>Das sieht nicht wie ein app-spezifisches Passwort aus (xxxx-xxxx-xxxx-xxxx). Ein normales Apple-Passwort wird abgelehnt.</div>
    <button type="submit" id="loginBtn">Verbinden</button>
    <div id="loginErr" class="err" hidden></div>
  </form>
</main>

<main id="app" hidden>
  <div class="bar">
    <label>Adressbuch <select id="book"></select></label>
    <button id="reload">Neu laden</button>
    <span id="status"></span>
  </div>
  <div id="loadErr" class="err" hidden></div>
  <div class="cols">
    <section class="list">
      <div class="bar">
        <input id="search" type="search" placeholder="Suchen (Name, Firma, Telefon, E-Mail)">
        <select id="sort"><option value="name">Nachname</option><option value="given">Vorname</option><option value="org">Firma</option></select>
      </div>
      <div class="bar small">
        <label><input type="checkbox" id="selAll"> Alle angezeigten</label>
        <span id="count"></span>
      </div>
      <ul id="items"></ul>
      <div class="bar export">
        <select id="fmt"><option value="vcf">Sammel-.vcf</option><option value="zip">ZIP mit Einzeldateien</option></select>
        <button id="expSel" disabled>Auswahl exportieren</button>
        <button id="expAll">Alle exportieren</button>
      </div>
    </section>
    <section class="detail" id="detail"><p class="muted">Kontakt auswählen.</p></section>
  </div>
</main>
<script src="/app.js"></script>
</body>
</html>
'@
$CssStyle = @'
:root{--bg:#f5f5f7;--fg:#1d1d1f;--card:#fff;--line:#d2d2d7;--acc:#0071e3;--err:#b00020;--muted:#6e6e73}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--card:#2c2c2e;--line:#48484a;--acc:#0a84ff;--err:#ff6b6b;--muted:#98989d}}
*{box-sizing:border-box}
body{margin:0;font:15px system-ui,"Segoe UI",sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;gap:1rem;align-items:center;padding:.6rem 1rem;background:var(--card);border-bottom:1px solid var(--line)}
h1{font-size:1.1rem;margin:0;flex:1}h2{margin-top:0}
main{max-width:1100px;margin:1rem auto;padding:0 1rem}
#login form{max-width:560px;margin:auto;background:var(--card);padding:1.2rem;border-radius:10px;border:1px solid var(--line)}
label{display:block;margin:.6rem 0}label input,label select{display:block;width:100%;padding:.5rem;margin-top:.2rem}
.bar label{display:flex;gap:.4rem;align-items:center;margin:0}.bar label input,.bar label select{width:auto;margin:0}
button{padding:.5rem .9rem;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);cursor:pointer}
button[type=submit],#expAll{background:var(--acc);color:#fff;border-color:var(--acc)}
button:disabled{opacity:.5;cursor:default}
input,select{font:inherit;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:6px}
.note{background:rgba(0,113,227,.08);border:1px solid var(--acc);border-radius:8px;padding:.7rem;font-size:.9rem}
.note ol{margin:.4rem 0;padding-left:1.3rem}
.warn{color:#9a6700;margin:.4rem 0}.err{color:var(--err);margin:.6rem 0;white-space:pre-wrap}
.muted{color:var(--muted)}
.bar{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap;padding:.4rem 0}.bar input[type=search]{flex:1;padding:.45rem}
.bar.small{font-size:.85rem;color:var(--muted)}.export{border-top:1px solid var(--line)}
.cols{display:grid;grid-template-columns:minmax(300px,1fr) 1.2fr;gap:1rem}
@media(max-width:760px){.cols{grid-template-columns:1fr}}
.list,.detail{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:.6rem .8rem}
#items{list-style:none;margin:0;padding:0;max-height:60vh;overflow:auto}
#items li{display:flex;gap:.5rem;align-items:center;padding:.4rem .3rem;border-bottom:1px solid var(--line);cursor:pointer}
#items li.sel{background:rgba(0,113,227,.15)}
#items li div{min-width:0}#items li small{display:block;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.detail img{width:96px;height:96px;object-fit:cover;border-radius:50%;float:right}
.detail h2{margin-bottom:.2rem}.detail dt{color:var(--muted);font-size:.8rem;margin-top:.7rem}.detail dd{margin:0;white-space:pre-line}
'@
$JsApp = @'
"use strict";
const $ = id => document.getElementById(id);
let contacts = [], selected = new Set(), current = null, poll = null;

async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: "POST", headers: {"X-Requested-With": "ICE", "Content-Type": "application/json"},
    body: JSON.stringify(body)};
  const r = await fetch(path, opt);
  if (!r.ok) {
    let e = {error: "HTTP " + r.status, kind: "error"};
    try { e = await r.json(); } catch (_) {}
    throw Object.assign(new Error(e.error), {kind: e.kind, status: r.status});
  }
  return r;
}
const json = async (p, b) => (await api(p, b)).json();
const el = (tag, props = {}, ...kids) => {
  const e = Object.assign(document.createElement(tag), props);
  kids.forEach(k => e.append(k)); return e;
};

$("password").addEventListener("input", () => {
  const v = $("password").value.trim();
  $("pwWarn").hidden = !v || /^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$/i.test(v);
});

$("loginForm").addEventListener("submit", async ev => {
  ev.preventDefault();
  $("loginErr").hidden = true; $("loginBtn").disabled = true; $("loginBtn").textContent = "Verbinde …";
  try {
    const r = await json("/api/login", {appleId: $("appleId").value, password: $("password").value});
    $("password").value = "";
    start(r);
  } catch (e) {
    $("loginErr").textContent = e.message; $("loginErr").hidden = false;
  } finally { $("loginBtn").disabled = false; $("loginBtn").textContent = "Verbinden"; }
});

function start(r) {
  $("login").hidden = true; $("app").hidden = false; $("logout").hidden = false;
  $("who").textContent = r.user;
  const sel = $("book"); sel.replaceChildren();
  r.books.forEach(b => sel.append(el("option", {value: b.url, textContent: b.name})));
  loadBook();
}

function loggedOut(msg) {
  $("app").hidden = true; $("login").hidden = false; $("logout").hidden = true; $("who").textContent = "";
  contacts = []; selected.clear(); current = null; clearInterval(poll);
  if (msg) { $("loginErr").textContent = msg; $("loginErr").hidden = false; }
}

$("logout").onclick = async () => { try { await api("/api/logout", {}); } catch (_) {} loggedOut(); };
$("reload").onclick = () => loadBook();
$("book").onchange = () => loadBook();

async function loadBook() {
  $("loadErr").hidden = true; selected.clear(); contacts = []; render(); showDetail(null);
  try { await api("/api/load", {book: $("book").value}); } catch (e) { return fail(e); }
  clearInterval(poll);
  poll = setInterval(async () => {
    try {
      const s = await json("/api/state");
      const j = s.job;
      if (j.state === "loading") $("status").textContent = `Lade … ${j.done}/${j.total}`;
      else {
        clearInterval(poll);
        if (j.state === "error") { $("status").textContent = ""; $("loadErr").textContent = j.error; $("loadErr").hidden = false; }
        else { contacts = await json("/api/contacts"); $("status").textContent = `${contacts.length} Kontakte geladen`; render(); }
      }
    } catch (e) { clearInterval(poll); fail(e); }
  }, 500);
}

function fail(e) {
  if (e.kind === "session") return loggedOut("Sitzung abgelaufen – bitte erneut anmelden.");
  $("loadErr").textContent = e.message; $("loadErr").hidden = false;
}

const key = c => ({name: (c.family || c.fn), given: (c.given || c.fn), org: (c.org || "￿")})[$("sort").value].toLowerCase();
function visible() {
  const q = $("search").value.trim().toLowerCase();
  const list = contacts.filter(c => !q || [c.fn, c.org, c.phone, c.email].some(v => (v || "").toLowerCase().includes(q)));
  return list.sort((a, b) => key(a).localeCompare(key(b), "de"));
}

function render() {
  const list = visible(), ul = $("items"); ul.replaceChildren();
  list.slice(0, 1000).forEach(c => {
    const cb = el("input", {type: "checkbox", checked: selected.has(c.id)});
    cb.onclick = ev => { ev.stopPropagation(); cb.checked ? selected.add(c.id) : selected.delete(c.id); upd(); };
    const li = el("li", {className: c.id === current ? "sel" : ""}, cb,
      el("div", {}, el("strong", {textContent: c.fn}), el("small", {textContent: [c.org, c.phone, c.email].filter(Boolean).join(" · ")})));
    li.onclick = () => showDetail(c.id);
    ul.append(li);
  });
  $("count").textContent = `${list.length} von ${contacts.length}` + (list.length > 1000 ? " (erste 1000 angezeigt – Suche nutzen)" : "");
  upd();
}
function upd() { $("expSel").disabled = !selected.size; $("expSel").textContent = `Auswahl exportieren (${selected.size})`; }
$("search").oninput = $("sort").onchange = render;
$("selAll").onchange = ev => { visible().forEach(c => ev.target.checked ? selected.add(c.id) : selected.delete(c.id)); render(); };

async function showDetail(id) {
  current = id; const d = $("detail"); d.replaceChildren();
  if (id === null) { d.append(el("p", {className: "muted", textContent: "Kontakt auswählen."})); return; }
  document.querySelectorAll("#items li").forEach(li => li.classList.remove("sel"));
  let c;
  try { c = await json("/api/contact/" + id); } catch (e) { return fail(e); }
  if (current !== id) return;
  if (c.hasPhoto) d.append(el("img", {src: "/api/photo/" + id, alt: ""}));
  d.append(el("h2", {textContent: c.fn}), el("div", {className: "muted", textContent: [c.title, c.org].filter(Boolean).join(" – ")}));
  const dl = el("dl");
  const add = (label, items) => items.forEach(i => {
    dl.append(el("dt", {textContent: label + (i.type ? ` (${i.type})` : "")}), el("dd", {textContent: i.value}));
  });
  add("Telefon", c.phones); add("E-Mail", c.emails); add("Adresse", c.addresses); add("Web", c.urls);
  if (c.birthday) add("Geburtstag", [{value: c.birthday}]);
  if (c.note) add("Notiz", [{value: c.note}]);
  dl.append(el("dt", {textContent: "vCard-Version"}), el("dd", {textContent: c.version}));
  d.append(dl);
  const one = el("button", {textContent: "Diesen Kontakt exportieren"}); one.onclick = () => exportIds([id]);
  d.append(one);
  render();
}

async function exportIds(ids) {
  $("loadErr").hidden = true;
  try {
    const r = await api("/api/export", {ids, format: $("fmt").value});
    const name = /filename="([^"]+)"/.exec(r.headers.get("Content-Disposition") || "")?.[1] || "kontakte.vcf";
    const a = el("a", {href: URL.createObjectURL(await r.blob()), download: name});
    document.body.append(a); a.click(); a.remove();
  } catch (e) { fail(e); }
}
$("expSel").onclick = () => exportIds([...selected]);
$("expAll").onclick = () => exportIds("all");

(async () => {
  try { const s = await json("/api/state"); start({user: s.user, books: s.books}); } catch (_) {}
})();
'@
$script:Assets = @{
    '/'           = @{ Type = 'text/html; charset=utf-8';       Body = $HtmlIndex }
    '/index.html' = @{ Type = 'text/html; charset=utf-8';       Body = $HtmlIndex }
    '/style.css'  = @{ Type = 'text/css; charset=utf-8';        Body = $CssStyle }
    '/app.js'     = @{ Type = 'text/javascript; charset=utf-8'; Body = $JsApp }
}

# ---------------------------------------------------------------- vCard (nur zur Anzeige)
$script:LineRx = New-Object System.Text.RegularExpressions.Regex('^(?:(?<g>[A-Za-z0-9\-]+)\.)?(?<n>[A-Za-z0-9\-]+)(?<p>(?:;(?:"[^"]*"|[^;:"])*)*):(?<v>.*)$')

function Split-VcLines([string]$Text) {
    $t = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return [regex]::Replace($t, "`n[ \t]", '') -split "`n"
}

function ConvertFrom-VcEscape([string]$V) {
    if ($V.IndexOf('\') -lt 0) { return $V }
    return [regex]::Replace($V, '\\(.)', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $c = $m.Groups[1].Value
        if ($c -eq 'n' -or $c -eq 'N') { "`n" } else { $c }
    })
}

function Split-VcFields([string]$V) { return [regex]::Split($V, '(?<!\\);') }

function Get-VcParams([string]$P) {
    $h = @{}
    foreach ($pm in [regex]::Matches($P, ';((?:"[^"]*"|[^;"])*)')) {
        $seg = $pm.Groups[1].Value
        if ($seg -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].ToUpperInvariant()
            if (-not $h.ContainsKey($k)) { $h[$k] = @() }
            foreach ($x in ($Matches[2] -split ',')) { $h[$k] += $x.Trim('"') }
        } elseif ($seg) {
            if (-not $h.ContainsKey('TYPE')) { $h['TYPE'] = @() }
            $h['TYPE'] += $seg
        }
    }
    return $h
}

function Get-VcTypes($Params, [string]$Label) {
    if ($Label) { return $Label }
    $t = @()
    if ($Params.ContainsKey('TYPE')) {
        foreach ($x in $Params['TYPE']) {
            if ($x.ToLowerInvariant() -notin 'pref', 'internet', 'voice') { $t += $x.ToLowerInvariant() }
        }
    }
    return ($t -join ', ')
}

function ConvertFrom-VCard([string]$Raw) {
    $props = New-Object System.Collections.ArrayList
    $labels = @{}
    foreach ($line in (Split-VcLines $Raw)) {
        if ($line.Length -eq 0) { continue }
        $m = $script:LineRx.Match($line)
        if (-not $m.Success) { continue }
        $name = $m.Groups['n'].Value.ToUpperInvariant()
        $grp = $m.Groups['g'].Value
        $val = $m.Groups['v'].Value
        if ($name -eq 'X-ABLABEL' -and $grp) {
            if ($val -match '^_\$!<(.*)>!\$_$') { $labels[$grp] = $Matches[1] } else { $labels[$grp] = $val }
        }
        [void]$props.Add(@{ g = $grp; n = $name; p = $m.Groups['p'].Value; v = $val })
    }
    $phones = New-Object System.Collections.ArrayList
    $emails = New-Object System.Collections.ArrayList
    $addrs = New-Object System.Collections.ArrayList
    $urls = New-Object System.Collections.ArrayList
    $c = [ordered]@{ version = ''; uid = ''; fn = ''; family = ''; given = ''; org = ''; title = ''
        birthday = ''; note = ''; hasPhoto = $false }
    foreach ($pr in $props) {
        $label = ''
        if ($pr.g -and $labels.ContainsKey($pr.g)) { $label = $labels[$pr.g] }
        $v = $pr.v
        switch ($pr.n) {
            'VERSION' { $c.version = $v }
            'UID' { $c.uid = $v }
            'FN' { $c.fn = ConvertFrom-VcEscape $v }
            'N' {
                $f = @(Split-VcFields $v) + @('', '')
                $c.family = ConvertFrom-VcEscape $f[0]; $c.given = ConvertFrom-VcEscape $f[1]
            }
            'ORG' { $c.org = (@(Split-VcFields $v | Where-Object { $_ } | ForEach-Object { ConvertFrom-VcEscape $_ }) -join ' / ') }
            'TITLE' { $c.title = ConvertFrom-VcEscape $v }
            'TEL' {
                $x = ConvertFrom-VcEscape $v
                if ($x.StartsWith('tel:')) { $x = $x.Substring(4) }
                [void]$phones.Add(@{ type = (Get-VcTypes (Get-VcParams $pr.p) $label); value = $x })
            }
            'EMAIL' { [void]$emails.Add(@{ type = (Get-VcTypes (Get-VcParams $pr.p) $label); value = (ConvertFrom-VcEscape $v) }) }
            'ADR' {
                $f = @((Split-VcFields $v) + @('', '', '', '', '', '', ''))[0..6] | ForEach-Object { ConvertFrom-VcEscape $_ }
                $lines = @($f[2], ((@($f[5], $f[3]) | Where-Object { $_ }) -join ' '), $f[4], $f[6]) | Where-Object { $_ }
                [void]$addrs.Add(@{ type = (Get-VcTypes (Get-VcParams $pr.p) $label); value = (@($lines) -join "`n") })
            }
            'URL' { [void]$urls.Add(@{ type = (Get-VcTypes (Get-VcParams $pr.p) $label); value = (ConvertFrom-VcEscape $v) }) }
            'BDAY' { $c.birthday = $v }
            'NOTE' { $c.note = ConvertFrom-VcEscape $v }
            'PHOTO' { $c.hasPhoto = $true }
        }
    }
    if (-not $c.fn) {
        $n = (@($c.given, $c.family) | Where-Object { $_ }) -join ' '
        if (-not $n) { $n = $c.org }
        if (-not $n -and $emails.Count) { $n = $emails[0].value }
        if (-not $n) { $n = '(ohne Namen)' }
        $c.fn = $n
    }
    $c.phones = @($phones); $c.emails = @($emails); $c.addresses = @($addrs); $c.urls = @($urls)
    return $c
}

function Get-VcPhoto([string]$Raw) {
    foreach ($line in (Split-VcLines $Raw)) {
        $m = $script:LineRx.Match($line)
        if (-not $m.Success -or $m.Groups['n'].Value.ToUpperInvariant() -ne 'PHOTO') { continue }
        $val = $m.Groups['v'].Value
        try {
            if ($val.ToLowerInvariant().StartsWith('data:')) {
                $comma = $val.IndexOf(',')
                $meta = $val.Substring(5, $comma - 5)
                $mime = ($meta -split ';')[0]
                if (-not $mime) { $mime = 'image/jpeg' }
                if ($meta -like '*;base64*') { return @{ Mime = $mime; Bytes = [Convert]::FromBase64String($val.Substring($comma + 1)) } }
                return $null
            }
            if ($val -match '^https?://') { return $null }   # externe Fotos werden bewusst nicht geladen
            $p = Get-VcParams $m.Groups['p'].Value
            $typ = 'jpeg'
            if ($p.ContainsKey('TYPE')) { $typ = $p['TYPE'][0].ToLowerInvariant() }
            if ($typ -eq 'jpg') { $typ = 'jpeg' }
            if ($typ -notlike '*/*') { $typ = "image/$typ" }
            return @{ Mime = $typ; Bytes = [Convert]::FromBase64String($val) }
        } catch { return $null }
    }
    return $null
}

function ConvertTo-Crlf([string]$Raw) {
    $t = ($Raw -replace "`r`n", "`n" -replace "`r", "`n").Trim("`n")
    return ($t -replace "`n", "`r`n") + "`r`n"
}

# ---------------------------------------------------------------- CardDAV
function Stop-Dav([string]$Message, [int]$Status = 502, [string]$Kind = 'error') {
    $e = New-Object System.Exception $Message
    $e.Data['status'] = $Status
    $e.Data['kind'] = $Kind
    throw $e
}

function Test-DavHost([string]$Url) {
    $u = [Uri]$Url
    $h = $u.Host.ToLowerInvariant()
    if ($script:AllowHost -and $h -eq $script:AllowHost) { return }
    if ($u.Scheme -ne 'https' -or -not ($h -eq 'icloud.com' -or $h.EndsWith('.icloud.com'))) {
        Stop-Dav "Ziel '$h' ist kein iCloud-Server; Zugangsdaten werden dorthin nicht gesendet."
    }
}

function Resolve-DavUrl([string]$Base, [string]$Rel) { return (New-Object Uri ((New-Object Uri $Base), $Rel)).AbsoluteUri }

function Invoke-Dav([string]$Auth, [string]$Method, [string]$Url, [string]$Body, $Depth) {
    for ($i = 0; $i -lt 6; $i++) {
        Test-DavHost $Url
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = $Method
        $req.AllowAutoRedirect = $false
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 60000
        $req.UserAgent = 'iCloud-Contacts-Export/1.0'
        $req.Headers['Authorization'] = $Auth
        if ($null -ne $Depth) { $req.Headers['Depth'] = [string]$Depth }
        if ($Body) {
            $bytes = $script:Utf8.GetBytes($Body)
            $req.ContentType = 'application/xml; charset=utf-8'
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        }
        try {
            $resp = $req.GetResponse()
        } catch [Net.WebException] {
            $resp = $_.Exception.Response
            if (-not $resp) { Stop-Dav ('Verbindung zum Server fehlgeschlagen: ' + $_.Exception.Message) 504 'network' }
        }
        $code = [int]$resp.StatusCode
        if ($code -in 301, 302, 303, 307, 308 -and $resp.Headers['Location']) {
            $Url = Resolve-DavUrl $Url $resp.Headers['Location']
            $resp.Close()
            continue
        }
        if ($code -eq 401 -or $code -eq 403) { $resp.Close(); Stop-Dav 'Anmeldung abgelehnt.' 401 'auth' }
        if ($code -ge 400) { $resp.Close(); Stop-Dav "Server antwortete mit HTTP $code." 502 }
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), $script:Utf8)
        $text = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return $text
    }
    Stop-Dav 'Zu viele Weiterleitungen.'
}

function ConvertTo-DavXml([string]$Text) {
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.XmlResolver = $null
        $d.LoadXml($Text)
        return , $d
    } catch { Stop-Dav 'Ungueltige XML-Antwort des Servers.' }
}

function New-DavNs($Doc) {
    $m = New-Object System.Xml.XmlNamespaceManager $Doc.NameTable
    $m.AddNamespace('d', 'DAV:'); $m.AddNamespace('c', 'urn:ietf:params:xml:ns:carddav')
    return , $m
}

function Invoke-Propfind([string]$Auth, [string]$Url, [string]$Props, [int]$Depth) {
    $body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:prop>' + $Props + '</d:prop></d:propfind>'
    $doc = ConvertTo-DavXml (Invoke-Dav $Auth 'PROPFIND' $Url $body $Depth)
    return , $doc
}

function Get-DavFirstHref($Doc, [string]$Path) {
    $ns = New-DavNs $Doc
    foreach ($n in $Doc.SelectNodes($Path, $ns)) {
        if ($n.InnerText.Trim()) { return $n.InnerText.Trim() }
    }
    return $null
}

function Get-DavBooks([string]$Auth) {
    $base = $script:BaseUrl
    $principal = Get-DavFirstHref (Invoke-Propfind $Auth $base '<d:current-user-principal/>' 0) '//d:current-user-principal/d:href'
    if (-not $principal) { Stop-Dav 'Kein Benutzer-Principal gefunden.' }
    $principal = Resolve-DavUrl $base $principal
    $homeUrl = Get-DavFirstHref (Invoke-Propfind $Auth $principal '<c:addressbook-home-set/>' 0) '//c:addressbook-home-set/d:href'
    if (-not $homeUrl) { Stop-Dav 'Kein Adressbuch-Verzeichnis gefunden.' }
    $homeUrl = Resolve-DavUrl $principal $homeUrl
    $doc = Invoke-Propfind $Auth $homeUrl '<d:resourcetype/><d:displayname/>' 1
    $ns = New-DavNs $doc
    $books = @()
    foreach ($r in $doc.SelectNodes('//d:response', $ns)) {
        $href = $r.SelectSingleNode('d:href', $ns)
        if ($href -and $r.SelectSingleNode('.//d:resourcetype/c:addressbook', $ns)) {
            $dn = $r.SelectSingleNode('.//d:displayname', $ns)
            $name = 'Kontakte'
            if ($dn -and $dn.InnerText) { $name = $dn.InnerText }
            $books += , @{ url = (Resolve-DavUrl $homeUrl $href.InnerText.Trim()); name = $name }
        }
    }
    if (-not $books.Count) { Stop-Dav 'Keine Adressbuecher gefunden.' }
    return $books
}

# Adressbuch-Inhalt auflisten und Ladevorgang vorbereiten; die Bloecke holt Step-Load schrittweise
function Start-Load($S, [string]$BookUrl) {
    $doc = Invoke-Propfind $S.Auth $BookUrl '<d:getetag/><d:getcontenttype/>' 1
    $ns = New-DavNs $doc
    $basePath = ([Uri]$BookUrl).AbsolutePath.TrimEnd('/')
    $hrefs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $doc.SelectNodes('//d:response/d:href', $ns)) {
        $h = $r.InnerText.Trim()
        if (-not $h) { continue }
        $path = (New-Object Uri ((Resolve-DavUrl $BookUrl $h))).AbsolutePath
        if ($path.TrimEnd('/') -eq $basePath -or $path.EndsWith('/')) { continue }
        $hrefs.Add($h)
    }
    $S.Contacts = New-Object System.Collections.Generic.List[object]
    $S.Job = @{ State = 'loading'; Done = 0; Total = $hrefs.Count; Error = $null; Hrefs = $hrefs; Pos = 0; Book = $BookUrl }
}

function Step-Load($S) {
    $j = $S.Job
    if ($j.State -ne 'loading') { return }
    if ($j.Pos -ge $j.Hrefs.Count) { $j.State = 'done'; return }
    $end = [Math]::Min($j.Pos + 100, $j.Hrefs.Count)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="utf-8"?><c:addressbook-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><c:address-data/></d:prop>')
    for ($i = $j.Pos; $i -lt $end; $i++) { [void]$sb.Append('<d:href>' + [Security.SecurityElement]::Escape($j.Hrefs[$i]) + '</d:href>') }
    [void]$sb.Append('</c:addressbook-multiget>')
    $doc = ConvertTo-DavXml (Invoke-Dav $S.Auth 'REPORT' $j.Book $sb.ToString() 1)
    $ns = New-DavNs $doc
    foreach ($ad in $doc.SelectNodes('//c:address-data', $ns)) {
        $raw = $ad.InnerText
        if (-not $raw.Trim()) { continue }
        $info = ConvertFrom-VCard $raw
        $info.id = [string]$S.Contacts.Count
        $S.Contacts.Add(@{ Raw = $raw; Info = $info })
    }
    $j.Pos = $end; $j.Done = $end
    if ($j.Pos -ge $j.Hrefs.Count) { $j.State = 'done' }
}

# ---------------------------------------------------------------- HTTP-Server
$script:AuthMessage = 'Apple hat die Anmeldung abgelehnt. Pruefen Sie: (1) Es muss ein APP-SPEZIFISCHES Passwort verwendet werden (Format xxxx-xxxx-xxxx-xxxx), nicht das normale Apple-Passwort. (2) Dafuer muss die Zwei-Faktor-Authentifizierung fuer die Apple-ID aktiv sein. (3) Apple-ID exakt eingeben (E-Mail-Adresse). (4) Bei Zweifeln unter appleid.apple.com ein neues app-spezifisches Passwort erzeugen.'

function Send-Bytes($Ctx, [int]$Code, [byte[]]$Bytes, [string]$Type, [hashtable]$Headers) {
    $r = $Ctx.Response
    $r.StatusCode = $Code
    $r.ContentType = $Type
    $r.ContentLength64 = $Bytes.Length
    $r.Headers['Cache-Control'] = 'no-store'
    $r.Headers['X-Content-Type-Options'] = 'nosniff'
    $r.Headers['Referrer-Policy'] = 'no-referrer'
    $r.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-ancestors 'none'"
    if ($Headers) { foreach ($k in $Headers.Keys) { $r.Headers[$k] = $Headers[$k] } }
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $r.OutputStream.Close()
}

function Send-Json($Ctx, [int]$Code, $Obj, [hashtable]$Headers) {
    $json = ConvertTo-Json -InputObject $Obj -Depth 8 -Compress
    Send-Bytes $Ctx $Code $script:Utf8.GetBytes($json) 'application/json; charset=utf-8' $Headers
}

function Send-Err($Ctx, [int]$Code, [string]$Msg, [string]$Kind = 'error') {
    Send-Json $Ctx $Code @{ error = $Msg; kind = $Kind } $null
}

function Get-Session($Ctx) {
    $now = Get-Date
    foreach ($k in @($script:Sessions.Keys)) {
        if (($now - $script:Sessions[$k].Last).TotalSeconds -gt $script:IdleSeconds) { $script:Sessions.Remove($k) }
    }
    $ck = $Ctx.Request.Cookies['ice_session']
    if (-not $ck) { return $null }
    $s = $script:Sessions[$ck.Value]
    if ($s) { $s.Last = $now }
    return $s
}

function Get-SortedContacts($S) {
    return @($S.Contacts | Sort-Object @{ Expression = { if ($_.Info.family) { $_.Info.family } else { $_.Info.fn } } }, @{ Expression = { $_.Info.given } })
}

function New-RandomToken {
    $b = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($b); $rng.Dispose()
    return ([Convert]::ToBase64String($b) -replace '\+', '-' -replace '/', '_' -replace '=', '')
}

function Invoke-Export($Ctx, $S, $B) {
    if (-not $S.Contacts -or $S.Contacts.Count -eq 0) { return Send-Err $Ctx 400 'Keine Kontakte geladen.' }
    $chosen = @()
    if ($null -eq $B.ids -or ($B.ids -is [string] -and $B.ids -eq 'all')) {
        $chosen = Get-SortedContacts $S
    } else {
        foreach ($id in @($B.ids)) {
            $n = 0
            if ([int]::TryParse([string]$id, [ref]$n) -and $n -ge 0 -and $n -lt $S.Contacts.Count) { $chosen += $S.Contacts[$n] }
        }
    }
    if ($chosen.Count -eq 0) { return Send-Err $Ctx 400 'Keine Kontakte ausgewaehlt.' }
    $stamp = Get-Date -Format 'yyyy-MM-dd'
    if ($B.format -eq 'zip') {
        $ms = New-Object System.IO.MemoryStream
        $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $used = @{}
        foreach ($c in $chosen) {
            $base = ([regex]::Replace($c.Info.fn, '[<>:"/\\|?*\x00-\x1f]', '_')).Trim(' ', '.')
            if ($base.Length -gt 80) { $base = $base.Substring(0, 80) }
            if (-not $base) { $base = 'Kontakt' }
            $name = $base; $n = 1
            while ($used.ContainsKey($name.ToLowerInvariant())) { $n++; $name = "$base ($n)" }
            $used[$name.ToLowerInvariant()] = $true
            $entry = $zip.CreateEntry($name + '.vcf')
            $es = $entry.Open()
            $bytes = $script:Utf8.GetBytes((ConvertTo-Crlf $c.Raw))
            $es.Write($bytes, 0, $bytes.Length); $es.Close()
        }
        $zip.Dispose()
        $data = $ms.ToArray(); $ms.Dispose()
        $type = 'application/zip'; $fname = "iCloud-Kontakte-$stamp.zip"
    } else {
        $sb = New-Object System.Text.StringBuilder
        foreach ($c in $chosen) { [void]$sb.Append((ConvertTo-Crlf $c.Raw)) }
        $data = $script:Utf8.GetBytes($sb.ToString())
        $type = 'text/vcard; charset=utf-8'; $fname = "iCloud-Kontakte-$stamp.vcf"
    }
    Send-Bytes $Ctx 200 $data $type @{ 'Content-Disposition' = "attachment; filename=`"$fname`""; 'X-Count' = [string]$chosen.Count }
}

function Invoke-Login($Ctx, $B) {
    $user = ([string]$B.appleId).Trim()
    $pw = ([string]$B.password).Trim()
    if (-not $user -or -not $pw) { return Send-Err $Ctx 400 'Bitte Apple-ID und app-spezifisches Passwort eingeben.' }
    $auth = 'Basic ' + [Convert]::ToBase64String($script:Utf8.GetBytes("${user}:${pw}"))
    try {
        $books = @(Get-DavBooks $auth)
    } catch {
        $ex = $_.Exception
        if ($ex.Data.Contains('kind') -and $ex.Data['kind'] -eq 'auth') { return Send-Err $Ctx 401 $script:AuthMessage 'auth' }
        if ($ex.Data.Contains('status')) { return Send-Err $Ctx $ex.Data['status'] $ex.Message $ex.Data['kind'] }
        return Send-Err $Ctx 502 ("Unerwarteter Fehler bei der Verbindung zu Apple: " + $ex.Message)
    }
    $token = New-RandomToken
    $script:Sessions[$token] = @{ User = $user; Auth = $auth; Books = $books; Contacts = $null; Last = Get-Date
        Job = @{ State = 'idle'; Done = 0; Total = 0; Error = $null } }
    Send-Json $Ctx 200 @{ user = $user; books = $books } @{ 'Set-Cookie' = "ice_session=$token; Path=/; HttpOnly; SameSite=Strict" }
}

function Get-JobView($J) { return @{ state = $J.State; done = $J.Done; total = $J.Total; error = $J.Error } }

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    $hostHdr = ([string]$req.Headers['Host']).ToLowerInvariant()
    if ($hostHdr -ne "127.0.0.1:$Port" -and $hostHdr -ne "localhost:$Port") { return Send-Err $Ctx 403 'Ungueltiger Host' }
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    if ($method -eq 'GET' -and -not $path.StartsWith('/api/')) {
        $a = $script:Assets[$path]
        if (-not $a) { return Send-Err $Ctx 404 'Nicht gefunden' }
        return Send-Bytes $Ctx 200 $script:Utf8.GetBytes($a.Body) $a.Type $null
    }

    $b = $null
    if ($method -eq 'POST') {
        if ($req.Headers['X-Requested-With'] -ne 'ICE') { return Send-Err $Ctx 403 'CSRF-Schutz: Header fehlt' }
        $sr = New-Object System.IO.StreamReader($req.InputStream, $script:Utf8)
        $text = $sr.ReadToEnd()
        try { $b = $text | ConvertFrom-Json } catch { return Send-Err $Ctx 400 'Ungueltige Anfrage' }
        if ($null -eq $b) { $b = New-Object PSObject }
        if ($path -eq '/api/login') { return Invoke-Login $Ctx $b }
    } elseif ($method -ne 'GET') { return Send-Err $Ctx 405 'Methode nicht erlaubt' }

    $s = Get-Session $Ctx
    if (-not $s) { return Send-Err $Ctx 401 'Nicht angemeldet.' 'session' }

    if ($method -eq 'POST') {
        switch ($path) {
            '/api/logout' {
                $script:Sessions.Remove($Ctx.Request.Cookies['ice_session'].Value)
                return Send-Json $Ctx 200 @{ ok = $true } @{ 'Set-Cookie' = 'ice_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict' }
            }
            '/api/load' {
                $book = [string]$b.book
                if (@($s.Books | Where-Object { $_.url -eq $book }).Count -eq 0) { return Send-Err $Ctx 400 'Unbekanntes Adressbuch.' }
                try { Start-Load $s $book } catch {
                    $ex = $_.Exception
                    if ($ex.Data.Contains('status')) { return Send-Err $Ctx $ex.Data['status'] $ex.Message $ex.Data['kind'] }
                    return Send-Err $Ctx 502 $ex.Message
                }
                return Send-Json $Ctx 202 @{ ok = $true } $null
            }
            '/api/export' { return Invoke-Export $Ctx $s $b }
        }
        return Send-Err $Ctx 404 'Unbekannt'
    }

    if ($path -eq '/api/state') {
        if ($s.Job.State -eq 'loading') {
            try { Step-Load $s } catch {
                $s.Job.State = 'error'; $s.Job.Error = $_.Exception.Message
            }
        }
        return Send-Json $Ctx 200 @{ user = $s.User; books = $s.Books; job = (Get-JobView $s.Job) } $null
    }
    if ($path -eq '/api/contacts') {
        $items = @()
        if ($s.Contacts) {
            foreach ($c in (Get-SortedContacts $s)) {
                $i = $c.Info
                $ph = ''; if ($i.phones.Count) { $ph = $i.phones[0].value }
                $em = ''; if ($i.emails.Count) { $em = $i.emails[0].value }
                $items += , @{ id = $i.id; fn = $i.fn; family = $i.family; given = $i.given; org = $i.org; phone = $ph; email = $em; hasPhoto = $i.hasPhoto }
            }
        }
        if ($items.Count -eq 0) { return Send-Bytes $Ctx 200 $script:Utf8.GetBytes('[]') 'application/json; charset=utf-8' $null }
        return Send-Json $Ctx 200 $items $null
    }
    if ($path -match '^/api/(contact|photo)/(\d+)$') {
        $n = [int]$Matches[2]
        if (-not $s.Contacts -or $n -ge $s.Contacts.Count) { return Send-Err $Ctx 404 'Kontakt nicht gefunden.' }
        $c = $s.Contacts[$n]
        if ($Matches[1] -eq 'contact') { return Send-Json $Ctx 200 $c.Info $null }
        $ph = Get-VcPhoto $c.Raw
        if (-not $ph -or $ph.Mime -notmatch '^image/(jpeg|png|gif|webp)$') { return Send-Err $Ctx 404 'Kein Foto.' }
        return Send-Bytes $Ctx 200 $ph.Bytes $ph.Mime $null
    }
    Send-Err $Ctx 404 'Unbekannt'
}

# ---------------------------------------------------------------- Start
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch {
    Write-Host "Port $Port konnte nicht geoeffnet werden (belegt?): $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$url = "http://127.0.0.1:$Port/"
Write-Host "Laeuft auf $url  (nur lokal erreichbar; Beenden mit Strg+C)"
if (-not $NoBrowser) { Start-Process $url }
try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(300)) { }   # kurze Wartezeiten, damit Strg+C greift
        $ctx = $task.Result
        try { Invoke-Request $ctx } catch {
            Write-Host ('Fehler: ' + $_.Exception.Message) -ForegroundColor Yellow
            try { Send-Err $ctx 500 ('Interner Fehler: ' + $_.Exception.Message) } catch { }
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
    $script:Sessions.Clear()
}
