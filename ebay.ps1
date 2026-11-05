# eBay Listings Monitor - GitHub Actions
# Cerca nuovi annunci per LEGO 76294 X-Men X-Mansion su eBay (API ufficiale).
# Richiede: secret EBAY_APP_ID (AppID da developer.ebay.com) + secrets Telegram.
# Se EBAY_APP_ID non e' ancora configurato, esce con log senza errori.

$ErrorActionPreference = "Stop"

$Keywords = "LEGO 76294"
$StateFile = "./ebay-state.json"

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

# ---- Richiede AppID eBay ----
if (-not $env:EBAY_APP_ID) {
    Write-Log "Attenzione: EBAY_APP_ID non impostato (secret). Impostalo e il monitor parte."
    exit 0
}

Write-Log "--- eBay scan $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# ---- Query API ufficiale eBay (Finding Service, JSON, annunci piu' recenti) ----
$base = "https://svcs.ebay.com/services/search/FindingService/v1"
$n = [System.Uri]::EscapeDataString
$qsStr = "OPERATION-NAME=findItemsAdvanced&SERVICE-VERSION=1.0.0&RESPONSE-DATA-FORMAT=JSON&REST-PAYLOAD"
$qsStr += "&SECURITY-APPNAME=$($n($env:EBAY_APP_ID))"
$qsStr += "&keywords=$($n($Keywords))"
$qsStr += "&paginationInput.entriesPerPage=25"
$qsStr += "&paginationInput.pageNumber=1"
$qsStr += "&sortOrder=StartTimeNewest"
$qsStr += "&outputSelector(0)=GalleryInfo"
$qsStr += "&itemFilter(0).name=Condition"
$qsStr += "&itemFilter(0).value(0)=New"
$qsStr += "&itemFilter(0).value(1)=NewOther"

try {
    $resp = Invoke-RestMethod -Uri "$base?$qsStr" -Headers @{ "User-Agent" = "LEGO Restock Monitor 1.0" } -TimeoutSec 60
} catch {
    Write-Log "ERRORE API eBay: $($_.Exception.Message)"
    exit 0
}

$finder = $resp.findItemsAdvancedResponse[0]
$ack = $finder.ack[0]
if ($ack -ne "Success") { Write-Log "API eBay risponde $ack"; exit 0 }

$items = @($finder.searchResult[0].item)
Write-Log "Trovati $($items.Count) annunci."

# ---- Baseline / delta ----
if (-not (Test-Path $StateFile)) {
    @{ seenIds = @($items | ForEach-Object { $_.itemId[0] }) } |
        ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline eBay salvata ($($items.Count) annunci gia' presenti, nessuna notifica)."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
$known = @($state.seenIds)
$news = @($items | Where-Object { $known -notcontains $_.itemId[0] })

foreach ($it in $news) {
    $id   = $it.itemId[0]
    $ttl  = $it.title[0]
    $prezzo = ($it.sellingStatus[0].currentPrice[0])."__value__"
    $url  = $it.viewItemURL[0]
    $sent = Send-Telegram "<b>Annuncio eBay nuovo</b>: $ttl
Prezzo: $prezzo EUR
Link: $url"
    if ($sent) { $known = @($known) + @($id); Write-Log "Notificato annuncio $id" }
}

# Limita lo stato a 800 id
if ($known.Count -gt 800) { $known = $known | Select-Object -Last 800 }

@{ seenIds = $known } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
Write-Log "Delta: $($news.Count) nuovi annunci. Stato aggiornato ($($known.Count) id)."
