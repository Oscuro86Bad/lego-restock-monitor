# eBay Listings Monitor - catena cloud (GitHub Actions)
# Ricerche: gestite dall'app Fallen App (tab eBay, file ebay.ps1 - SOLO blocco $Searches)
# Credenziali API: repo PRIVATO Oscuro86Bad/vintedkeys-config, file ebay.json (salvate dall'app)
# Notifica i NUOVI annunci via Telegram. Baseline silenziosa primo giro / nuova chiave.
# Se le credenziali eBay non sono valide (401), esce in silenzio con messaggio chiaro:
# la catena riprovera' al giro dopo e funzionera' appena le credenziali vengono corrette.

$ErrorActionPreference = "Stop"

$ConfigRepo   = "Oscuro86Bad/vintedkeys-config"
$Marketplace  = "EBAY_IT"      # cambia in EBAY_ES / EBAY_US se serve
$StateFile    = "./ebay-state.json"
$MaxNewPerRun = 15             # anti-spam: massimo notifiche per giro
$MaxAgeHours  = 72             # solo annunci creati da meno di 3 giorni (anti-vecchi)

function Write-Log { param([string]$m); Write-Output $m }

function Send-Telegram {
    param([string]$Text)
    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$env:TELEGRAM_BOT_TOKEN/sendMessage" -Method Post -Body @{
            chat_id = $env:TELEGRAM_CHAT_ID; text = $Text; parse_mode = "HTML"
        } -TimeoutSec 30 | Out-Null
        Write-Log "Telegram inviato."
        return $true
    } catch {
        Write-Log "ERRORE invio Telegram: $($_.Exception.Message)"
        return $false
    }
}

function Esc {
    param([string]$s)
    if ($null -eq $s) { return "" }
    return ([string]$s).Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

Write-Log "--- eBay scan $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# ---- ricerche gestite dall'app (ebay.ps1 contiene il blocco $Searches) ----
. ./ebay.ps1
if (-not $Searches -or @($Searches).Count -eq 0) {
    Write-Log "Nessuna ricerca eBay configurata (ebay.ps1 vuoto): niente da fare."
    exit 0
}
Write-Log "Ricerche da app: $(@($Searches).Count)"

# ---- credenziali: prima i secrets (EBAY_CLIENT_ID/EBAY_CLIENT_CERT), poi il repo privato ----
$ebayCfg = $null
if ($env:EBAY_CLIENT_ID -and $env:EBAY_CLIENT_CERT) {
    $ebayCfg = [pscustomobject]@{ clientId = $env:EBAY_CLIENT_ID; clientSecret = $env:EBAY_CLIENT_CERT }
    Write-Log "Credenziali da secrets EBAY_CLIENT_ID/EBAY_CLIENT_CERT."
} else {
    try {
        $ghHeaders = @{
            Authorization = "token $env:TRIGGER_TOKEN"
            Accept        = "application/vnd.github+json"
            "User-Agent"  = "ebay-monitor"
        }
        $cfgRaw = Invoke-RestMethod -Uri "https://api.github.com/repos/$ConfigRepo/contents/ebay.json" -Headers $ghHeaders -TimeoutSec 30
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($cfgRaw.content -replace "\s", "")))
        $ebayCfg = $json | ConvertFrom-Json
    } catch {
        Write-Log "ERRORE lettura ebay.json da $ConfigRepo : $($_.Exception.Message)"
        exit 0
    }
}
if (-not $ebayCfg.clientId -or -not $ebayCfg.clientSecret) {
    Write-Log "ebay.json incompleto (clientId/clientSecret mancanti): apri l'app Fallen, tab eBay, e salva le credenziali."
    exit 0
}

# ---- OAuth client_credentials ----
try {
    $pair = "$($ebayCfg.clientId):$($ebayCfg.clientSecret)"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $tokResp = Invoke-RestMethod -Uri "https://api.ebay.com/identity/v1/oauth2/token" -Method Post `
        -Headers @{ Authorization = "Basic $b64" } `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope" -TimeoutSec 30
    $tok = $tokResp.access_token
    Write-Log "OAuth OK (token valido $($tokResp.expires_in) s)."
} catch {
    $code = ""
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 401) {
        Write-Log "Credenziali eBay NON valide (401): il Cert ID non e' corretto (spesso si copia per errore il Dev ID)."
        Write-Log "FIX: developer.ebay.com/my/keys -> production -> COPIA IL CERT ID (quello lungo) -> app Fallen, tab eBay, Credenziali API eBay -> salva."
    } else {
        Write-Log "OAuth eBay fallito (HTTP $code): $($_.Exception.Message)"
    }
    exit 0
}

$h = @{
    Authorization            = "Bearer $tok"
    Accept                   = "application/json"
    "X-EBAY-C-MARKETPLACE-ID" = $Marketplace
}

# ---- scansione per ogni termine ----
$foundItems = @{}
$termIds = @{}
foreach ($s in @($Searches)) {
    $term = [string]$s.term
    if (-not $term) { continue }
    if (-not $termIds.ContainsKey($term)) { $termIds[$term] = @() }
    try {
        $q = [uri]::EscapeDataString($term)
        $url = "https://api.ebay.com/buy/browse/v1/item_summary/search?q=$q&limit=50&sort=newlyListed"
        $r = Invoke-RestMethod -Uri $url -Headers $h -TimeoutSec 60
        $tot = if ($r.itemSummaries) { @($r.itemSummaries).Count } else { 0 }
        Write-Log "Ricerca '$term': $($r.total) risultati (presi $tot)."
        foreach ($it in @($r.itemSummaries)) {
            $id = [string]$it.itemId
            if ($termIds[$term] -notcontains $id) { $termIds[$term] = @($termIds[$term]) + $id }
            if ($foundItems.ContainsKey($id)) { continue }
            $foundItems[$id] = @{
                title    = [string]$it.title
                price    = "$($it.price.value) $($it.price.currency)"
                link     = [string]$it.itemWebUrl
                created  = [string]$it.itemCreationDate
            }
        }
    } catch {
        Write-Log "ERRORE ricerca '$term': $($_.Exception.Message)"
    }
}

$allIds = @($foundItems.Keys)
Write-Log "Totale item validi: $($allIds.Count)"

# ---- baseline completamente primo run ----
if (-not (Test-Path $StateFile)) {
    @{ seenIds = $allIds; baselinedTerms = @() } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline salvata: $($allIds.Count) annunci gia' online, nessuna notifica."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
$known = @($state.seenIds)
$baselined = @($state.baselinedTerms)
if (-not $baselined) { $baselined = @() }

$notifiedCount = 0
foreach ($s in @($Searches)) {
    $term = [string]$s.term
    if (-not $term) { continue }
    $ids = @(); if ($termIds.ContainsKey($term)) { $ids = @($termIds[$term]) }
    if ($baselined -contains $term) {
        $news = @($ids | Where-Object { $known -notcontains $_ })
        # guardia eta': eBay puo' risalire annunci vecchi nella prima pagina
        $nowUtc = (Get-Date).ToUniversalTime()
        $recent = @()
        $old = @()
        foreach ($id in $news) {
            $ageOk = $false
            try {
                $dt = [datetime]$foundItems[$id].created
                $ageOk = (($nowUtc - $dt.ToUniversalTime()).TotalHours -lt $MaxAgeHours)
            } catch { $ageOk = $false }   # senza data valida: prudente, lo registra ma non lo notifica
            if ($ageOk) { $recent += $id } else { $old += $id }
        }
        if ($old.Count -gt 0) {
            foreach ($id in $old) { if ($known -notcontains $id) { $known += $id } }
            Write-Log "Scartati $($old.Count) annunci vecchi (>$MaxAgeHours h) per '$term': registrati in silenzio."
        }
        $news = $recent
        if ($news.Count -gt 30) {
            # TROPPI nuovi su ricerca gia' baseline: probabile perdita di stato -> re-baseline
            Write-Log "ATTENZIONE: $($news.Count) nuovi per '$term' su ricerca gia' baseline: re-baseline silenziosa, nessuna notifica."
            foreach ($id in $news) { if ($known -notcontains $id) { $known += $id } }
        } else {
            foreach ($id in $news) {
                if ($notifiedCount -ge $MaxNewPerRun) {
                    Write-Log "LIMITE $MaxNewPerRun notifiche/giro: '$id' slitta al prossimo giro."
                    continue
                }
                # CLAIM PRIMA dell'invio (anti-doppio)
                $known = @($known) + $id
                @{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
                $it = $foundItems[$id]
                $msg = "<b>Nuovo annuncio eBay</b> ($term): $(Esc $it.title)
Prezzo: $(Esc $it.price)
Link: $(Esc $it.link)"
                $sent = Send-Telegram $msg
                if ($sent) {
                    $notifiedCount++
                    Write-Log "Notificato $id ($term)"
                } else {
                    # invio fallito: rimuovi il claim per riprovarci al prossimo giro
                    $known = @($known | Where-Object { $_ -ne $id })
                    @{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
                }
            }
        }
    } else {
        # NUOVA ricerca: baseline silenziosa solo se ha trovato annunci
        if ($ids.Count -gt 0) {
            foreach ($id in $ids) { if ($known -notcontains $id) { $known += $id } }
            $baselined += $term
            Write-Log "Baseline silenziosa per '$term': $($ids.Count) annunci registrati senza notifiche."
        } else {
            Write-Log "Termine '$term': 0 annunci in questo giro, NON baselinato (riprovo ai prossimi giri)."
        }
    }
}

if ($known.Count -gt 800) { $known = @($known | Select-Object -Last 800) }
@{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
Write-Log "Stato aggiornato: $($known.Count) id in memoria. Notificati in questo giro: $notifiedCount."
