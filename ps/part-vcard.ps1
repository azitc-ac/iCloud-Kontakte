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
        birthday = ''; note = ''; hasPhoto = $false; middle = ''; prefix = ''; suffix = ''; company = ''; department = '' }
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
                $f = $f + @('', '', '')
                $c.middle = ConvertFrom-VcEscape $f[2]; $c.prefix = ConvertFrom-VcEscape $f[3]; $c.suffix = ConvertFrom-VcEscape $f[4]
            }
            'ORG' {
                $of = @(Split-VcFields $v) + @('', '')
                $c.company = ConvertFrom-VcEscape $of[0]; $c.department = ConvertFrom-VcEscape $of[1]
                $c.org = (@(Split-VcFields $v | Where-Object { $_ } | ForEach-Object { ConvertFrom-VcEscape $_ }) -join ' / ')
            }
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
                [void]$addrs.Add(@{ type = (Get-VcTypes (Get-VcParams $pr.p) $label); value = (@($lines) -join "`n")
                        street = ((@($f[0], $f[1], $f[2]) | Where-Object { $_ }) -join "`n"); city = [string]$f[3]; state = [string]$f[4]; zip = [string]$f[5]; country = [string]$f[6] })
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

