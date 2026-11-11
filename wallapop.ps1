# Wallapop Listings Monitor - versione CLOUD per GitHub Actions
# Uso l'API ufficiale https://api.wallapop.com/api/v3/search:
#  - NON richiede device-fingerprint (verificato 2026-11-11, header banali bastano)
#  - NON e' geo-bloccata dai runner GitHub Actions (test: HTTP 200 da ubuntu runner)
#  - il vecchio blocco era dato da /search/section (400/403 senza fingerprint) e dal
#    geo-blocco CloudFront che colpisce SOLO il sito es.wallapop.com (HTTP 403), non l'API
# Il monitor nel telefono (WallapopService, WebView) resta attivo come fallback.
#
# Le chiavi di ricerca nel blocco $Searches qui sotto sono GESTITE DALL'APP
# Fallen App (tab Wallapop): non modificarle a mano qui.
# Le credenziali arrivano dai secrets TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.

$Searches = @(
    @{ term = "76352" },
    @{ term = "Lego stranger Things" }
)

$ErrorActionPreference = "Stop"

# Centro mappa per la ricerca (Madrid centro). L'API ordina per novita' e copre
# tutta la Spagna: per cercare in Italia cambia le coordinate (es. Milano 45.4642/9.19).
$Lat = 40.4168
$Lon = -3.7038
$OnlyShippable = $false      # true = solo annunci con spedizione attiva
$MaxNewPerRun  = 12          # anti-spam: massimo avvisi per ciclo
$StateFile     = "./wallapop_state.json"
$ApiHeaders    = @{
    "X-DeviceOS" = "0"
    "User-Agent" = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    "Accept"     = "application/json, text/plain, */*"
}

function Write-Log { param([string]$m); Write-Output $m }

function Send-Telegram {
    param([string]$Text)
    try {
        $uri = "https://api.telegram.org/bot$env:TELEGRAM_BOT_TOKEN/sendMessage"
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $Text; parse_mode = "HTML" }
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -TimeoutSec 30 | Out-Null
        return $true
    } catch {
        Write-Log "ERRORE invio Telegram: $($_.Exception.Message)"
        return $false
    }
}

function Esc {
    param([string]$s)
    if ($null -eq $s) { return "" }
    return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

Write-Log "--- Controllo Wallapop $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# Modalita' test: invia messaggio di prova via Telegram ed esce
if ($env:TEST_MESSAGE -eq "true") {
    $sent = Send-Telegram "TEST invio: il monitor Wallapop (cloud, API ufficiale) e' attivo e funzionante."
    if ($sent) { Write-Log "TEST MESSAGE INVIATO CORRETTAMENTE." } else { Write-Log "TEST MESSAGE: invio fallito." }
    exit 0
}

$firstRun = -not (Test-Path $StateFile)

# stato: set di id gia' visti
$seen = @{}
if (-not $firstRun) {
    try {
        $prev = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($id in $prev.ids) { $seen[[string]$id] = $true }
    } catch {
        Write-Log "Stato illeggibile, riparto con baseline."
        $firstRun = $true
        $seen = @{}
    }
}

$allNew = New-Object System.Collections.Generic.List[object]
foreach ($s in $Searches) {
    $term = [uri]::EscapeDataString([string]$s.term)
    $url  = "https://api.wallapop.com/api/v3/search?source=search_box&keywords=$term&latitude=$Lat&longitude=$Lon&order_by=newest"
    try {
        $resp  = Invoke-RestMethod -Uri $url -Headers $ApiHeaders -TimeoutSec 60
        $items = $resp.data.section.payload.items
        Write-Log ("termine '" + $s.term + "': " + $items.Count + " risultati")
    } catch {
        Write-Log "ERRORE chiamata API per '$($s.term)': $($_.Exception.Message)"
        continue
    }
    foreach ($it in $items) {
        if ($it.reserved.flag) { continue }
        if ($OnlyShippable -and -not $it.shipping.item_is_shippable) { continue }
        if (-not $seen.ContainsKey([string]$it.id)) {
            $seen[[string]$it.id] = $true
            $allNew.Add(@{ item = $it; term = [string]$s.term })
        }
    }
    Start-Sleep -Milliseconds 800
}

# salva lo stato (mantieni gli ultimi 2000 id)
$ids = @($seen.Keys | Select-Object -First 5000)
if ($ids.Count -gt 2000) { $ids = $ids | Select-Object -Last 2000 }
@{ ids = $ids } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8

if ($firstRun) {
    Write-Log "Baseline iniziale salvata ($($ids.Count) id visti, nessun avviso)."
    exit 0
}

if ($allNew.Count -eq 0) {
    Write-Log "Nessun nuovo annuncio."
    exit 0
}

Write-Log "Nuovi annunci: $($allNew.Count)"
$daNotificare = $allNew | Sort-Object { $_.item.created_at } -Descending | Select-Object -First $MaxNewPerRun
if ($allNew.Count -gt $MaxNewPerRun) {
    Write-Log "ATTENZIONE: $($allNew.Count - $MaxNewPerRun) annunci oltre il limite di $MaxNewPerRun per questo giro non notificati."
}

foreach ($n in $daNotificare) {
    $it = $n.item
    $prezzo = if ($it.price -and $it.price.amount -ne $null) {
        ("{0:N2}" -f [double]$it.price.amount).Replace(".", ",") + " " + $it.price.currency
    } else { "prezzo n/d" }
    $citta = if ($it.location -and $it.location.city) { [string]$it.location.city } else { "" }
    $paese = if ($it.location -and $it.location.country_code) { [string]$it.location.country_code } else { "" }
    $sped  = if ($it.shipping -and $it.shipping.item_is_shippable) { "sì" } else { "no" }
    $link  = "https://es.wallapop.com/item/" + [string]$it.web_slug
    $msg = "<b>🟣 Wallapop</b> · nuova inserizione per «$(Esc $n.term)»"
    $msg += "`n<b>$(Esc $it.title)</b> — $prezzo"
    $geo = $citta
    if ($paese) { $geo += " ($paese)" }
    if ($geo) { $msg += "`n📍 $geo · spedizione: $sped" }
    $msg += "`n$link"
    $sent = Send-Telegram $msg
    if (-not $sent) { Write-Log "Invio fallito per '$(Esc $it.title)': riproverà al prossimo giro (id resta nel pacchetto)." }
    Start-Sleep -Milliseconds 600
}

Write-Log "FINE."
exit 0
