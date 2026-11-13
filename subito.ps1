# Subito.it Listings Monitor - GitHub Actions (cloud, 24/7)
# Ricerche gestite dall'app Android (tab Subito): legge il blocco $Searches.
# NOTA ROTTA: subito.it ora redirige la vecchia /annunci-italia/vendita/?q=
# su /annunci-italia/vendita/usato/ BUTTANDO la query. La rotta corretta e'
# la nuova: /annunci-italia/vendita/usato/?q=<termine> (risultati SSR filtrati).
# I dati degli annunci sono nel JSON __NEXT_DATA__ (fields: subject, urls, features).

$ErrorActionPreference = "Stop"

# compatibilità PowerShell 5.1 (Windows locale): forza TLS 1.2; su pwsh 7 e' ignorato
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Searches = @(
    @{ term = "76352" },
    @{ term = "21302" },
    @{ term = "6866" },
    @{ term = "76194" }
)
$SearchUrl = "https://www.subito.it/annunci-italia/vendita/usato/?q={0}"
$StateFile = "./subito-state.json"
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

Write-Log "--- Subito scan $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

$foundItems = @{}
$termIds = @{}   # termine di ricerca -> id annunci trovati in quella ricerca
$okTerms = @()   # termini con almeno 1 annuncio trovato in QUESTO giro

foreach ($s in $Searches) {
    if (-not $termIds.ContainsKey($s.term)) { $termIds[$s.term] = @() }
    try {
        $url = $SearchUrl -f [uri]::EscapeDataString($s.term)
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA; "Accept-Language" = "it-IT,it;q=0.9" } -UseBasicParsing -TimeoutSec 60
        $c = $resp.Content
        $j = [regex]::Match($c, '<script id="__NEXT_DATA__" type="application/json">(.*?)</script>').Groups[1].Value
        if (-not $j) { Write-Log "ERRORE ricerca '$($s.term)': __NEXT_DATA__ assente."; continue }
        $o = $j | ConvertFrom-Json
        $list = $o.props.pageProps.initialState.items.originalList
        $ids = @()
        foreach ($it in $list) {
            $adUrl = $it.urls.default
            $m = [regex]::Match($adUrl, '-([0-9]{8,12})\.htm$')
            if (-not $m.Success) { continue }
            $id = $m.Groups[1].Value
            if ($foundItems.ContainsKey($id)) {
                if ($termIds[$s.term] -notcontains $id) { $termIds[$s.term] = @($termIds[$s.term]) + $id }
                continue
            }
            # prezzo dentro features["/price"].values[0].value (es. "800 EUR")
            $prezzo = ""
            try {
                $pv = $it.features."/price".values[0].value
                if ($pv) {
                    # tiene solo cifre e separatori, poi aggiunge " euro"
                    $num = ($pv -replace '[^0-9,\.]', '').Trim()
                    if ($num) { $prezzo = "$num euro" }
                }
            } catch {}
            $titolo = $it.subject
            $foundItems[$id] = @{ title = $titolo; price = $prezzo; url = $adUrl }
            $termIds[$s.term] = @($termIds[$s.term]) + $id
            $ids += $id
        }
        if ($termIds.ContainsKey($s.term) -and @($termIds[$s.term]).Count -gt 0) { $okTerms = @($okTerms) + $s.term }
        Write-Log "Ricerca '$($s.term)': $($ids.Count) annunci validi."
        Start-Sleep -Seconds 2   # pausa cortese tra le ricerche
    } catch {
        Write-Log "ERRORE ricerca '$($s.term)': $($_.Exception.Message)"
    }
}

$allIds = @($foundItems.Keys)
Write-Log "Totale annunci validi: $($allIds.Count)"

# ---- Baseline al primo run: registra tutto, non notifica ----
# SOLO i termini che hanno restituito annunci: un termine fallito non va baselinato a vuoto
# (altrimenti al giro dopo tutti i suoi annunci risultano "nuovi" e spamma Telegram).
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
            # TROPPI "nuovi" per una ricerca gia' baseline: probabile perdita di stato
            # (cache evasa/rigenerata). Re-baseline silenziosa: ZERO notifiche.
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
                $prezzo = if ($it.price) { $it.price } else { "prezzo n.d." }
                $sent = Send-Telegram "<b>Nuovo annuncio Subito</b> ($term): $($it.title)
$prezzo
$($it.url)"
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
        # Se la fetch e' fallita o ha dato 0 risultati in quel giro, NON la baseline:
        # resta silenziosa finche' non vedra' il primo annuncio (mai spam annunci vecchi).
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
