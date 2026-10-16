<#
.SYNOPSIS
    Importiert einzelne oder alle vCards (.vcf) in einen waehlbaren Kontakte-Ordner in Exchange Online (Microsoft Graph).

.DESCRIPTION
    Quellen (-Path): .vcf-Dateien (auch Sammeldateien mit mehreren Kontakten), Ordner (rekursiv) oder .zip-Archive,
    z. B. der Export der iCloud-Kontakte-App.
    Anmeldung per Device-Code-Flow (Browser + Code, MFA-faehig). Es werden keine Module benoetigt, nur Windows PowerShell 5.1+.
    Tokens bleiben nur im Arbeitsspeicher. Berechtigung (delegiert): Contacts.ReadWrite
    (bei -Mailbox zusaetzlich Contacts.ReadWrite.Shared).

    Ohne -All wird eine Auswahlliste (Out-GridView) fuer die Kontakte gezeigt, ohne -Folder eine Liste der Ordner.
    Bereits vorhandene Kontakte (gleicher Anzeigename + erste E-Mail) werden uebersprungen, ausser mit -AllowDuplicates.

.PARAMETER Path          .vcf-Datei(en), Ordner oder .zip. Ohne Angabe oeffnet sich ein Dateidialog.
.PARAMETER All           Alle gefundenen Kontakte importieren (keine Auswahlliste).
.PARAMETER Folder        Zielordner (Name oder Pfad wie "Privat/iCloud"). Ohne Angabe: Auswahlliste.
.PARAMETER CreateFolder  Zielordner anlegen, falls er nicht existiert.
.PARAMETER Mailbox       Anderes/gemeinsames Postfach (UPN/E-Mail) statt des eigenen.
.PARAMETER TenantId      Mandant (Standard: organizations). Bei Bedarf Domaene oder GUID Deines Mandanten.
.PARAMETER ClientId      App-ID fuer die Anmeldung. Standard: "Microsoft Graph Command Line Tools" (oeffentlicher Microsoft-Client).
                         Wenn diese App in Deiner Umgebung gesperrt ist: eigene App-Registrierung (oeffentlicher Client, delegiert Contacts.ReadWrite).
.PARAMETER Force         Keine Rueckfrage vor dem Import.

.EXAMPLE
    .\Import-VCardToExchangeOnline.ps1 -Path .\iCloud-Kontakte-2026-10-16.zip

.EXAMPLE
    .\Import-VCardToExchangeOnline.ps1 -Path .\kontakte.vcf -All -Folder "iCloud" -CreateFolder -WhatIf

.NOTES
    GENERIERT aus ps/Import-VCardToExchangeOnline.template.ps1 durch build_ps1.py - nicht von Hand bearbeiten.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Path,
    [switch]$All,
    [string]$Folder,
    [switch]$CreateFolder,
    [string]$Mailbox,
    [string]$TenantId = 'organizations',
    [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',
    [switch]$AllowDuplicates,
    [switch]$Force,
    [switch]$NoBrowser,
    [string]$GraphBase = 'https://graph.microsoft.com/v1.0',   # nur fuer Tests aenderbar
    [string]$LoginBase = 'https://login.microsoftonline.com'    # nur fuer Tests aenderbar
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
try { [Net.ServicePointManager]::SecurityProtocol = 3072 -bor 12288 } catch { [Net.ServicePointManager]::SecurityProtocol = 3072 }
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Token = $null

@@VCARD@@

# ---------------------------------------------------------------- Quellen einlesen
function Split-VCards([string]$Raw) {
    $out = @()
    foreach ($m in [regex]::Matches($Raw, '(?ims)^BEGIN:VCARD\b.*?^END:VCARD[ \t\r]*$')) { $out += $m.Value }
    return $out
}

function Read-VCardSources([string[]]$Paths) {
    $cards = New-Object System.Collections.ArrayList
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Pfad nicht gefunden: $p" }
        $item = Get-Item -LiteralPath $p
        $files = @()
        if ($item.PSIsContainer) {
            $files = @(Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object { $_.Extension -in '.vcf', '.vcard', '.zip' })
        } else { $files = @($item) }
        foreach ($f in $files) {
            if ($f.Extension -eq '.zip') {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($f.FullName)
                try {
                    foreach ($e in $zip.Entries) {
                        if ($e.FullName -notmatch '\.(vcf|vcard)$') { continue }
                        $sr = New-Object System.IO.StreamReader($e.Open(), $script:Utf8)
                        $txt = $sr.ReadToEnd(); $sr.Close()
                        foreach ($c in (Split-VCards $txt)) { [void]$cards.Add(@{ Raw = $c; Source = "$($f.Name)!$($e.FullName)" }) }
                    }
                } finally { $zip.Dispose() }
            } else {
                $txt = [System.IO.File]::ReadAllText($f.FullName, $script:Utf8)
                foreach ($c in (Split-VCards $txt)) { [void]$cards.Add(@{ Raw = $c; Source = $f.Name }) }
            }
        }
    }
    return , $cards
}

# ---------------------------------------------------------------- vCard -> Graph-Kontakt
function Add-Overflow($List, [string]$Label, $Items) {
    foreach ($i in $Items) { [void]$List.Add(("{0}{1}: {2}" -f $Label, $(if ($i.type) { " ($($i.type))" } else { '' }), ($i.value -replace "`n", ', '))) }
}

function ConvertTo-GraphContact($Card) {
    $i = ConvertFrom-VCard $Card.Raw
    $body = [ordered]@{ displayName = $i.fn }
    foreach ($pair in @(@('givenName', $i.given), @('surname', $i.family), @('middleName', $i.middle), @('title', $i.prefix),
            @('generation', $i.suffix), @('companyName', $i.company), @('department', $i.department), @('jobTitle', $i.title))) {
        if ($pair[1]) { $body[$pair[0]] = $pair[1] }
    }
    $extra = New-Object System.Collections.ArrayList

    # Telefone: Mobil (1), privat (2), geschaeftlich (2); Rest landet in den Notizen
    $mobile = @(); $homePh = @(); $biz = @()
    foreach ($ph in $i.phones) {
        $t = [string]$ph.type
        if ($t -match 'fax') { Add-Overflow $extra 'Fax' @($ph) }
        elseif ($t -match 'cell|mobile|iphone') { $mobile += $ph }
        elseif ($t -match 'home|privat') { $homePh += $ph }
        else { $biz += $ph }
    }
    if ($mobile.Count) { $body.mobilePhone = $mobile[0].value; if ($mobile.Count -gt 1) { Add-Overflow $extra 'Telefon' $mobile[1..($mobile.Count - 1)] } }
    if ($homePh.Count) { $body.homePhones = @($homePh[0..([Math]::Min(1, $homePh.Count - 1))] | ForEach-Object { $_.value }); if ($homePh.Count -gt 2) { Add-Overflow $extra 'Telefon' $homePh[2..($homePh.Count - 1)] } }
    if ($biz.Count) { $body.businessPhones = @($biz[0..([Math]::Min(1, $biz.Count - 1))] | ForEach-Object { $_.value }); if ($biz.Count -gt 2) { Add-Overflow $extra 'Telefon' $biz[2..($biz.Count - 1)] } }

    # E-Mail: Exchange speichert bis zu 3
    if ($i.emails.Count) {
        $body.emailAddresses = @($i.emails[0..([Math]::Min(2, $i.emails.Count - 1))] | ForEach-Object { @{ name = $i.fn; address = $_.value } })
        if ($i.emails.Count -gt 3) { Add-Overflow $extra 'E-Mail' $i.emails[3..($i.emails.Count - 1)] }
    }

    # Adressen: privat / geschaeftlich / sonstige je eine
    $slots = @{}
    foreach ($a in $i.addresses) {
        $t = [string]$a.type
        $slot = 'otherAddress'
        if ($t -match 'home|privat') { $slot = 'homeAddress' } elseif ($t -match 'work|business|gesch') { $slot = 'businessAddress' }
        if ($slots.ContainsKey($slot)) { Add-Overflow $extra 'Adresse' @($a); continue }
        $g = [ordered]@{}
        foreach ($pair in @(@('street', $a.street), @('city', $a.city), @('state', $a.state), @('postalCode', $a.zip), @('countryOrRegion', $a.country))) {
            if ($pair[1]) { $g[$pair[0]] = $pair[1] }
        }
        $slots[$slot] = $true; $body[$slot] = $g
    }

    if ($i.urls.Count) { $body.businessHomePage = $i.urls[0].value; if ($i.urls.Count -gt 1) { Add-Overflow $extra 'Web' $i.urls[1..($i.urls.Count - 1)] } }
    if ($i.birthday) {
        if ($i.birthday -match '^(\d{4})-?(\d{2})-?(\d{2})') { $body.birthday = "$($Matches[1])-$($Matches[2])-$($Matches[3])T00:00:00Z" }
        else { [void]$extra.Add("Geburtstag: $($i.birthday)") }
    }
    $notes = @()
    if ($i.note) { $notes += $i.note }
    if ($extra.Count) { $notes += ('--- Weitere Daten aus vCard ---' + "`n" + ($extra -join "`n")) }
    if ($notes.Count) { $body.personalNotes = ($notes -join "`n`n") }

    $key = $i.fn.ToLowerInvariant() + '|' + $(if ($i.emails.Count) { ([string]$i.emails[0].value).ToLowerInvariant() } else { '' })
    return @{ Body = $body; Name = $i.fn; Key = $key; Photo = (Get-VcPhoto $Card.Raw); Info = $i; Source = $Card.Source }
}

# ---------------------------------------------------------------- Anmeldung (Device-Code-Flow)
function Get-ErrorText($ErrRecord) {
    $t = $ErrRecord.Exception.Message
    try {
        $j = $ErrRecord.ErrorDetails.Message | ConvertFrom-Json
        if ($j.error.message) { $t = $j.error.message } elseif ($j.error_description) { $t = $j.error_description }
    } catch { }
    return $t
}

function Connect-Graph {
    $scope = 'https://graph.microsoft.com/Contacts.ReadWrite offline_access'
    if ($Mailbox) { $scope = 'https://graph.microsoft.com/Contacts.ReadWrite https://graph.microsoft.com/Contacts.ReadWrite.Shared offline_access' }
    $dc = Invoke-RestMethod -Method Post -Uri "$LoginBase/$TenantId/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = $scope }
    Write-Host ''
    Write-Host $dc.message -ForegroundColor Cyan
    try { Set-Clipboard -Value $dc.user_code; Write-Host '(Code wurde in die Zwischenablage kopiert.)' } catch { }
    if (-not $NoBrowser) { try { Start-Process $dc.verification_uri } catch { } }
    $interval = [Math]::Max(1, [int]$dc.interval)
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $t = Invoke-RestMethod -Method Post -Uri "$LoginBase/$TenantId/oauth2/v2.0/token" -Body @{
                grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $ClientId; device_code = $dc.device_code }
            Set-Token $t
            return
        } catch {
            $err = ''
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { $interval += 5; continue }
            throw ('Anmeldung fehlgeschlagen: ' + (Get-ErrorText $_))
        }
    }
    throw 'Anmeldung nicht rechtzeitig abgeschlossen.'
}

function Set-Token($T) {
    $refresh = $T.refresh_token
    if (-not $refresh -and $script:Token) { $refresh = $script:Token.Refresh }
    $script:Token = @{ Access = $T.access_token; Refresh = $refresh; Expires = (Get-Date).AddSeconds([int]$T.expires_in) }
}

function Get-AccessToken {
    if ($script:Token.Refresh -and (Get-Date).AddMinutes(5) -gt $script:Token.Expires) {
        $t = Invoke-RestMethod -Method Post -Uri "$LoginBase/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type = 'refresh_token'; client_id = $ClientId; refresh_token = $script:Token.Refresh }
        Set-Token $t
    }
    return $script:Token.Access
}

# ---------------------------------------------------------------- Graph-Aufrufe
function Invoke-Graph([string]$Method, [string]$Url, $Body = $null, [byte[]]$Bytes = $null, [string]$ContentType = 'application/json; charset=utf-8') {
    $args2 = @{ Method = $Method; Uri = $Url; Headers = @{ Authorization = 'Bearer ' + (Get-AccessToken) }; UseBasicParsing = $true }
    if ($null -ne $Body) { $args2.Body = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress)); $args2.ContentType = $ContentType }
    elseif ($null -ne $Bytes) { $args2.Body = $Bytes; $args2.ContentType = $ContentType }
    for ($try = 1; ; $try++) {
        try { return Invoke-RestMethod @args2 }
        catch {
            $code = 0; $wait = 3 * $try
            try { $code = [int]$_.Exception.Response.StatusCode; $ra = $_.Exception.Response.Headers['Retry-After']; if ($ra) { $wait = [int]$ra } } catch { }
            if ($try -lt 6 -and $code -in 429, 502, 503, 504) { Start-Sleep -Seconds $wait; $args2.Headers.Authorization = 'Bearer ' + (Get-AccessToken); continue }
            throw (Get-ErrorText $_)
        }
    }
}

function Get-GraphPages([string]$Url) {
    $all = New-Object System.Collections.ArrayList
    while ($Url) {
        $r = Invoke-Graph 'GET' $Url
        foreach ($v in @($r.value)) { if ($null -ne $v) { [void]$all.Add($v) } }
        $Url = $r.'@odata.nextLink'
    }
    return , $all
}

$script:UserBase = '/me'
if ($Mailbox) { $script:UserBase = '/users/' + [Uri]::EscapeDataString($Mailbox) }

function Get-ContactFolders {
    $result = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($listUrl, $prefix, $top)
        foreach ($f in (Get-GraphPages $listUrl)) {
            if ($top -and $f.displayName -in 'Contacts', 'Kontakte') { continue }   # = Standardordner, wird separat angeboten
            $p = $prefix + $f.displayName
            [void]$result.Add(@{ Id = $f.id; Path = $p; Name = $f.displayName })
            & $walk ("$GraphBase$($script:UserBase)/contactFolders/$($f.id)/childFolders?`$top=100") ($p + '/') $false
        }
    }
    & $walk ("$GraphBase$($script:UserBase)/contactFolders?`$top=100") '' $true
    return , $result
}

function New-ContactFolder([string]$PathName) {
    $parent = $null; $folders = Get-ContactFolders; $built = ''
    foreach ($seg in ($PathName -split '/' | Where-Object { $_ })) {
        $built = if ($built) { "$built/$seg" } else { $seg }
        $hit = $folders | Where-Object { $_.Path -ieq $built } | Select-Object -First 1
        if ($hit) { $parent = $hit.Id; continue }
        $url = "$GraphBase$($script:UserBase)/contactFolders"
        if ($parent) { $url = "$GraphBase$($script:UserBase)/contactFolders/$parent/childFolders" }
        $created = Invoke-Graph 'POST' $url @{ displayName = $seg }
        $parent = $created.id
    }
    return $parent
}

function Select-TargetFolder {
    $default = @{ Id = $null; Path = 'Kontakte (Standardordner)'; Name = 'Kontakte (Standardordner)' }
    $folders = Get-ContactFolders
    if ($Folder) {
        if ($Folder -in 'Contacts', 'Kontakte') { return $default }
        $hit = @($folders | Where-Object { $_.Path -ieq $Folder }) + @($folders | Where-Object { $_.Name -ieq $Folder }) | Select-Object -First 1
        if ($hit) { return $hit }
        if (-not $CreateFolder) { throw "Ordner '$Folder' nicht gefunden. Mit -CreateFolder wird er angelegt." }
        if ($PSCmdlet.ShouldProcess($Folder, 'Kontakte-Ordner anlegen')) { $id = New-ContactFolder $Folder } else { $id = '(whatif)' }
        return @{ Id = $id; Path = $Folder; Name = $Folder }
    }
    if ($Force) { return $default }
    $choices = @($default) + @($folders) + @(@{ Id = '*new*'; Path = '[Neuen Ordner anlegen ...]'; Name = '' })
    $sel = $null
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        $sel = $choices | ForEach-Object { New-Object PSObject -Property @{ Ordner = $_.Path; Ref = $_ } } |
            Out-GridView -Title 'Ziel-Kontakteordner waehlen (Auswaehlen + OK)' -OutputMode Single
        if (-not $sel) { throw 'Abgebrochen (kein Ordner gewaehlt).' }
        $sel = $sel.Ref
    } else {
        for ($n = 0; $n -lt $choices.Count; $n++) { Write-Host ("[{0}] {1}" -f $n, $choices[$n].Path) }
        $sel = $choices[[int](Read-Host 'Nummer des Zielordners')]
    }
    if ($sel.Id -eq '*new*') {
        $name = Read-Host 'Name des neuen Ordners (Unterordner mit /)'
        if (-not $name) { throw 'Abgebrochen.' }
        return @{ Id = (New-ContactFolder $name); Path = $name; Name = $name }
    }
    return $sel
}

# ---------------------------------------------------------------- Ablauf
if (-not $Path) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'vCard-Dateien oder ZIP waehlen'; $dlg.Multiselect = $true
        $dlg.Filter = 'vCard / ZIP (*.vcf;*.zip)|*.vcf;*.vcard;*.zip|Alle Dateien|*.*'
        if ($dlg.ShowDialog() -eq 'OK') { $Path = $dlg.FileNames }
    } catch { $Path = @((Read-Host 'Pfad zu .vcf / Ordner / .zip')) }
    if (-not $Path) { throw 'Keine Quelle angegeben.' }
}

Write-Host 'Lese vCards ...'
$cards = Read-VCardSources $Path
if ($cards.Count -eq 0) { throw 'Keine vCards gefunden.' }
$contacts = @($cards | ForEach-Object { ConvertTo-GraphContact $_ })
Write-Host ("{0} Kontakte gefunden." -f $contacts.Count)

if (-not $All) {
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        $rows = for ($n = 0; $n -lt $contacts.Count; $n++) {
            $c = $contacts[$n]; $i = $c.Info
            New-Object PSObject -Property ([ordered]@{ Nr = $n; Name = $c.Name; Firma = $i.org
                    Telefon = $(if ($i.phones.Count) { $i.phones[0].value } else { '' })
                    Email = $(if ($i.emails.Count) { $i.emails[0].value } else { '' }); Quelle = $c.Source })
        }
        $picked = @($rows | Out-GridView -Title 'Zu importierende Kontakte waehlen (Strg/Shift + OK; Abbrechen = nichts)' -OutputMode Multiple)
        if ($picked.Count -eq 0) { Write-Host 'Nichts ausgewaehlt.'; return }
        $contacts = @($picked | ForEach-Object { $contacts[[int]$_.Nr] })
    } else {
        if ((Read-Host "Alle $($contacts.Count) Kontakte importieren? (j/n)") -notmatch '^[jJyY]') { return }
    }
}

Connect-Graph
$target = Select-TargetFolder
$rel = "$($script:UserBase)/contacts"
if ($target.Id) { $rel = "$($script:UserBase)/contactFolders/$($target.Id)/contacts" }
$who = if ($Mailbox) { $Mailbox } else { 'eigenes Postfach' }

$existing = @{}
if (-not $AllowDuplicates -and $target.Id -ne '(whatif)') {
    Write-Host 'Pruefe vorhandene Kontakte im Zielordner ...'
    foreach ($e in (Get-GraphPages "$GraphBase$rel`?`$select=displayName,emailAddresses&`$top=999")) {
        $em = ''; if ($e.emailAddresses -and $e.emailAddresses.Count) { $em = ([string]$e.emailAddresses[0].address).ToLowerInvariant() }
        $existing[([string]$e.displayName).ToLowerInvariant() + '|' + $em] = $true
    }
}
$todo = @(); $skipped = @()
foreach ($c in $contacts) {
    if ($existing.ContainsKey($c.Key)) { $skipped += $c } else { $existing[$c.Key] = $true; $todo += $c }
}
Write-Host ("Ziel: '{0}' ({1}). Neu: {2}, bereits vorhanden/uebersprungen: {3}." -f $target.Path, $who, $todo.Count, $skipped.Count)
if ($todo.Count -eq 0) { return }

if (-not $Force -and -not $WhatIfPreference) {
    if ((Read-Host "Jetzt $($todo.Count) Kontakte importieren? (j/n)") -notmatch '^[jJyY]') { Write-Host 'Abgebrochen.'; return }
}
if (-not $PSCmdlet.ShouldProcess("$($target.Path) ($who)", "$($todo.Count) Kontakte anlegen")) { return }

$created = 0; $failed = New-Object System.Collections.ArrayList; $photoFail = 0
for ($start = 0; $start -lt $todo.Count; $start += 20) {
    $chunk = @($todo[$start..([Math]::Min($start + 19, $todo.Count - 1))])
    $pending = @{}
    for ($k = 0; $k -lt $chunk.Count; $k++) { $pending[[string]$k] = $chunk[$k] }
    for ($attempt = 1; $attempt -le 5 -and $pending.Count; $attempt++) {
        $reqs = @($pending.Keys | Sort-Object { [int]$_ } | ForEach-Object {
                @{ id = $_; method = 'POST'; url = $rel; headers = @{ 'Content-Type' = 'application/json' }; body = $pending[$_].Body } })
        $resp = Invoke-Graph 'POST' "$GraphBase/`$batch" @{ requests = $reqs }
        $wait = 0
        foreach ($r in @($resp.responses)) {
            $c = $pending[[string]$r.id]
            if ([int]$r.status -in 200, 201) {
                $created++; $pending.Remove([string]$r.id)
                if ($c.Photo) {
                    try { [void](Invoke-Graph 'PUT' "$GraphBase$($script:UserBase)/contacts/$($r.body.id)/photo/`$value" $null $c.Photo.Bytes $c.Photo.Mime) }
                    catch { $photoFail++ }
                }
            } elseif ([int]$r.status -in 429, 503, 504) {
                $ra = 5; try { $ra = [int]$r.headers.'Retry-After' } catch { }
                $wait = [Math]::Max($wait, $ra)
            } else {
                $msg = "HTTP $($r.status)"; try { $msg += ': ' + $r.body.error.message } catch { }
                [void]$failed.Add("$($c.Name) - $msg"); $pending.Remove([string]$r.id)
            }
        }
        if ($pending.Count -and $wait) { Start-Sleep -Seconds $wait }
    }
    foreach ($k in $pending.Keys) { [void]$failed.Add("$($pending[$k].Name) - gedrosselt/abgebrochen") }
    Write-Progress -Activity 'Importiere Kontakte' -Status "$created von $($todo.Count)" -PercentComplete ([int](100 * [Math]::Min($start + 20, $todo.Count) / $todo.Count))
}
Write-Progress -Activity 'Importiere Kontakte' -Completed

Write-Host ''
Write-Host ("Fertig: {0} angelegt, {1} uebersprungen (vorhanden), {2} fehlgeschlagen, {3} Fotos nicht uebertragen." -f $created, $skipped.Count, $failed.Count, $photoFail) -ForegroundColor Green
if ($failed.Count) { $failed | ForEach-Object { Write-Host "  FEHLER: $_" -ForegroundColor Yellow }; exit 1 }
