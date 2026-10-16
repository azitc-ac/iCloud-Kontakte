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
@@INDEX@@
'@
$CssStyle = @'
@@STYLE@@
'@
$JsApp = @'
@@APP@@
'@
$script:Assets = @{
    '/'           = @{ Type = 'text/html; charset=utf-8';       Body = $HtmlIndex }
    '/index.html' = @{ Type = 'text/html; charset=utf-8';       Body = $HtmlIndex }
    '/style.css'  = @{ Type = 'text/css; charset=utf-8';        Body = $CssStyle }
    '/app.js'     = @{ Type = 'text/javascript; charset=utf-8'; Body = $JsApp }
}

@@VCARD@@

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
