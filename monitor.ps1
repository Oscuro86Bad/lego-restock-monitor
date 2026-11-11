# LEGO Restock Monitor - versione per GitHub Actions
# Controlla la disponibilita' del set 76294 su LEGO.com Shop IT
# e invia un messaggio Telegram a OGNI cambio di stato:
# "GREAT NEWS!" quando torna acquistabile, "ATTENZIONE" quando torna terminato.
# Le credenziali arrivano dai secrets TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.

$ErrorActionPreference = "Stop"

$ProductSlug = "x-men-the-x-mansion-76294"
$ProductUrl  = "https://www.lego.com/it-it/product/$ProductSlug"
$StateFile   = "./state.json"

function Write-Log { param([string]$m); Write-Output $m }

function Send-Telegram {
    param([string]$Text)
    try {
        $uri = "https://api.telegram.org/bot$env:TELEGRAM_BOT_TOKEN/sendMessage"
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $Text; parse_mode = "HTML" }
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -TimeoutSec 30 | Out-Null
        Write-Log "Telegram inviato."
        return $true
    } catch {
        Write-Log "ERRORE invio Telegram: $($_.Exception.Message)"
        return $false
    }
}

Write-Log "--- Controllo $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# Modalita' test: invia messaggio di prova via Telegram ed esce
if ($env:TEST_MESSAGE -eq "true") {
    $sent = Send-Telegram "TEST invio: il monitoraggio LEGO (76294 X-Men: X-Mansion) e' attivo e funzionante. Quando il set torna disponibile, riceverai l'avviso qui."
    if ($sent) { Write-Log "TEST MESSAGE INVIATO CORRETTAMENTE." } else { Write-Log "TEST MESSAGE: invio fallito, controllare i secrets." }
    exit 0
}

$query = @"
{ product(slug: "$ProductSlug") {
  name
  ... on SingleVariantProduct {
    variant {
      price { formattedAmount }
      attributes { availabilityStatus availabilityText canAddToBag }
    }
  }
} }
"@

$payload = @{ query = $query } | ConvertTo-Json -Depth 5

try {
    $headers = @{
        "Content-Type" = "application/json"
        "User-Agent"   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
        "Origin"       = "https://www.lego.com"
        "Referer"      = $ProductUrl
        "x-locale"     = "it-IT"
    }
    $response = Invoke-RestMethod -Uri "https://www.lego.com/api/graphql/Product" -Method Post -Headers $headers -Body $payload -TimeoutSec 60
    $v     = $response.data.product.variant
    $attrs = $v.attributes
    $name  = $response.data.product.name
    $canBuy = [bool]$attrs.canAddToBag
    Write-Log "Stato: $($attrs.availabilityStatus) | $($attrs.availabilityText) | canAddToBag: $canBuy | prezzo: $($v.price.formattedAmount)"
} catch {
    Write-Log "ERRORE interrogazione LEGO.com: $($_.Exception.Message)"
    exit 0
}

# Baseline: primo run (nessuno stato salvato) => salva e non avvisa
if (-not (Test-Path $StateFile)) {
    $lastNote = if ($canBuy) { "avail" } else { "out" }
    @{ lastNotified = $lastNote } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline iniziale salvata."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json

# Migrazione automatica dal vecchio schema ({alerted: bool}) al nuovo ({lastNotified: "avail"|"out"})
if (-not ($state.PSObject.Properties.Name -contains "lastNotified")) {
    $legacy = if ($state.alerted) { "avail" } else { "out" }
    @{ lastNotified = $legacy } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    Write-Log "Stato migrato allo schema lastNotified: $legacy"
}

# Transizione DISPONIBILE: notifica se l'ultimo avviso non era gia' "avail"
if ($canBuy -and $state.lastNotified -ne "avail") {
    $prev = $state.lastNotified
    # CLAIM ANTICIPATO: segna l'invio PRIMA di inviarlo per evitare doppi
    # (esecuzioni concorrenti vedrebbero lo stato gia' avvisato e non ripeterebbero)
    @{ lastNotified = "avail" } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    $msg = "<b>GREAT NEWS!</b> Il set LEGO <b>$name (76294)</b> e' <b>tornato disponibile</b>!"
    $msg += "`nPrezzo: $($v.price.formattedAmount)"
    $msg += "`nLink: $ProductUrl"
    $sent = Send-Telegram $msg
    if ($sent) {
        Write-Log "AVVISO DISPONIBILE INVIATO."
    } else {
        # invio fallito: ripristina lo stato precedente e ritenta al prossimo giro
        @{ lastNotified = $prev } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
        Write-Log "Invio fallito: ritento al prossimo ciclo."
    }
    exit 0
}

# Transizione TERMINATO: ora notifica SEMPRE il cambio di stato
if (-not $canBuy -and $state.lastNotified -ne "out") {
    $prev = $state.lastNotified
    @{ lastNotified = "out" } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    $msg = "<b>ATTENZIONE</b>: il set LEGO <b>$name (76294)</b> e' tornato <b>TERMINATO</b>."
    $msg += "`nAl prossimo restock arrivera' di nuovo l'avviso <b>GREAT NEWS!</b>"
    $sent = Send-Telegram $msg
    if ($sent) {
        Write-Log "AVVISO TERMINATO INVIATO."
    } else {
        @{ lastNotified = $prev } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
        Write-Log "Invio fallito: ritento al prossimo ciclo."
    }
    exit 0
}

Write-Log "Nessun cambiamento ($($attrs.availabilityStatus))."
