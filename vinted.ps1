# Vinted Listings Monitor - GitHub Actions (cloud, 24/7)
# Ricerche: "76294" e "lego x-mansion" â notifica Telegram per annunci nuovi.
# Lo stato ( annunci gia' visti ) si tiene nel cache del workflow.

$ErrorActionPreference = "Stop"

$Searches = @(
    @{ term = "21302" },
    @{ term = "76352" },
    @{ term = "31199" }
)
$StateFile = "./vinted-state.json"
$MaxNotPerRun = 20   # anti-spam: massimo notifiche per giro (il resto slitta al giro dopo)
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
$termIds = @{}   # termine di ricerca -> ids di quell'annuncio in quella ricerca
$okTerms = @()   # termini con almeno 1 annuncio trovato in QUESTO giro

foreach ($s in $Searches) {
    try {
        $url = "https://www.vinted.it/catalog?search_text=$([uri]::EscapeDataString($s.term))"
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA } -UseBasicParsing -TimeoutSec 60
        $c = $resp.Content
        $anchors = [regex]::Matches($c, 'data-testid="product-item-id-(\d+)"')
        foreach ($a in $anchors) {
            $id = $a.Groups[1].Value
            if (-not $termIds.ContainsKey($s.term)) { $termIds[$s.term] = @() }
            if ($foundItems.ContainsKey($id)) {
                # id gia' visto in un'altra ricerca: solo registro per il termine
                if ($termIds[$s.term] -notcontains $id) { $termIds[$s.term] = @($termIds[$s.term]) + $id }
                continue
            }
            $winSize = [Math]::Min(4000, $c.Length - $a.Index)
            $win = $c.Substring($a.Index, $winSize)
            $t = [regex]::Match($win, 'alt="([^"]{5,200})"')
            if (-not $t.Success) { continue }
            $alt = $t.Groups[1].Value
            $titolo = ($alt -split ',\s*(?:Condizioni|Marca|Brand)').Trim()
            $prezzo = [regex]::Match($alt, '(\d{1,6}[\.,]\d{2})').Groups[1].Value
            $foundItems[$id] = @{ title = $titolo; price = $prezzo }
            $termIds[$s.term] = @($termIds[$s.term]) + $id
        }
        if ($termIds.ContainsKey($s.term) -and @($termIds[$s.term]).Count -gt 0) { $okTerms = @($okTerms) + $s.term }
        Write-Log "Ricerca '$($s.term)': $($anchors.Count) item."
    } catch {
        Write-Log "ERRORE ricerca '$($s.term)': $($_.Exception.Message)"
    }
}

$allIds = @($foundItems.Keys)
Write-Log "Totale item validi: $($allIds.Count)"

# ---- Baseline completamente primo run: registra e non notifica ----
# NOTA: baseliniamo SOLO i termini che hanno effettivamente restituito annunci:
# un termine fallito (es. Vinted bloccato) NON va baselinato a vuoto, altrimenti
# al giro dopo TUTTI i suoi annunci risultano "nuovi" e spamma Telegram.
if (-not (Test-Path $StateFile)) {
    @{ seenIds = $allIds; baselinedTerms = $okTerms } |
        ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline salvata: $($allIds.Count) annunci gia' online, nessuna notifica (termini baseline: $($okTerms.Count))."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
$known = @($state.seenIds)
$baselined = @($state.baselinedTerms)
if (-not $state.baselinedTerms) { $baselined = @() }

$notifiedCount = 0
foreach ($s in $Searches) {
    $term = $s.term
    $ids = @(); if ($termIds.ContainsKey($term)) { $ids = @($termIds[$term]) }
    if ($baselined -contains $term) {
        # ricerca gia' attiva: notifica solo annunci nuovi
        $news = @($ids | Where-Object { $known -notcontains $_ })
        if ($news.Count -gt $MaxNotPerRun) {
            # TROPPI "nuovi" in un solo giro per una ricerca gia' baseline:
            # quasi certamente lo stato si e' perduto/rigenerato (cache evasa).
            # Re-baseline silenziosa: ZERO notifiche, anti-spam.
            Write-Log "ATTENZIONE: $($news.Count) nuovi per '$term' su ricerca gia' baseline: probabile perdita di stato -> re-baseline silenziosa, nessuna notifica."
            foreach ($id in $news) { if ($known -notcontains $id) { $known += $id } }
        } else {
            foreach ($id in $news) {
                if ($notifiedCount -ge $MaxNotPerRun) {
                    Write-Log "LIMITE $MaxNotPerRun notifiche/giro: '$id' slitta al prossimo giro."
                    continue
                }
                # CLAIM del singolo id PRIMA dell'invio Telegram (anti-doppio)
                $known = @($known) + $id
                @{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
                $it = $foundItems[$id]
                $sent = Send-Telegram "<b>Nuovo annuncio Vinted</b> ($term): $($it.title)
Prezzo: $($it.price) euro
Link: https://www.vinted.it/items/$id"
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
        # NUOVA ricerca: baseline silenziosa SOLO se ha trovato almeno 1 annuncio.
        # Se la fetch e' fallita o ha dato 0 risultati (Vinted bloccato/rallentato in
        # quel giro), NON la baseline: resta silenziosa nei prossimi giri finche'
        # non vedra' il primo annuncio. Cosi' non puo' mai notificare annunci vecchi.
        if ($ids.Count -gt 0) {
            foreach ($id in $ids) { if ($known -notcontains $id) { $known += $id } }
            $baselined += $term
            Write-Log "Baseline silenziosa per '$term': $($ids.Count) annunci registrati senza notifiche."
        } else {
            Write-Log "Termine '$term': 0 annunci trovati in questo giro, NON baselinato (nessuna notifica, riprovo ai prossimi giri)."
        }
    }
}

if ($known.Count -gt 800) { $known = $known | Select-Object -Last 800 }
@{ seenIds = $known; baselinedTerms = $baselined } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding utf8
Write-Log "Stato aggiornato: $($known.Count) id in memoria. Notificati in questo giro: $notifiedCount."
