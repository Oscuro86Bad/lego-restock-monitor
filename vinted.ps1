# Vinted Listings Monitor - GitHub Actions (cloud, 24/7)
# Ricerche: "76294" e "lego x-mansion" — notifica Telegram per annunci nuovi.
# Lo stato ( annunci gia' visti ) si tiene nel cache del workflow.

$ErrorActionPreference = "Stop"

$Searches = @(
    @{ term = "76294" },
    @{ term = "lego x-mansion" }
)
$StateFile = "./vinted-state.json"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

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

Write-Log "--- Vinted scan $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

$foundItems = @{}

foreach ($s in $Searches) {
    try {
        $url = "https://www.vinted.it/catalog?search_text=$([uri]::EscapeDataString($s.term))"
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA } -UseBasicParsing -TimeoutSec 60
        $c = $resp.Content
        $anchors = [regex]::Matches($c, 'data-testid="product-item-id-(\d+)"')
        foreach ($a in $anchors) {
            $id = $a.Groups[1].Value
            if ($foundItems.ContainsKey($id)) { continue }
            $winSize = [Math]::Min(4000, $c.Length - $a.Index)
            $win = $c.Substring($a.Index, $winSize)
            $t = [regex]::Match($win, 'alt="([^"]{5,200})"')
            if (-not $t.Success) { continue }
            $alt = $t.Groups[1].Value
            $titolo = ($alt -split ',\s*(?:Condizioni|Marca|Brand)').Trim()
            $prezzo = [regex]::Match($alt, '(\d{1,6}[\.,]\d{2})').Groups[1].Value
            $foundItems[$id] = @{ title = $titolo; price = $prezzo }
        }
        Write-Log "Ricerca '$($s.term)': $($anchors.Count) item."
    } catch {
        Write-Log "ERRORE ricerca '$($s.term)': $($_.Exception.Message)"
    }
}

$allIds = @($foundItems.Keys)
Write-Log "Totale item validi: $($allIds.Count)"

# ---- Baseline primo run: registra e non notifica ----
if (-not (Test-Path $StateFile)) {
    @{ seenIds = $allIds } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline salvata: $($allIds.Count) annunci gia' online, nessuna notifica."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
$known = @($state.seenIds)
$news = @($allIds | Where-Object { $known -notcontains $_ })
Write-Log "Delta: $($news.Count) nuovi annunci."

foreach ($id in $news) {
    $it = $foundItems[$id]
    $sent = Send-Telegram "<b>Nuovo annuncio Vinted</b>: $($it.title)
Prezzo: $($it.price) euro
Link: https://www.vinted.it/items/$id"
    if ($sent) {
        $known += $id
        Write-Log "Notificato $id"
    }
}

if ($known.Count -gt 800) { $known = $known | Select-Object -Last 800 }
@{ seenIds = $known } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
Write-Log "Stato aggiornato: $($known.Count) id in memoria."
