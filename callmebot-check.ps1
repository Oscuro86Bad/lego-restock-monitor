# CallMeBot Reopen Checker - versione per GitHub Actions
# Controlla ogni 4 ore la pagina della Free WhatsApp API di CallMeBot:
# se NON c'e' piu' il messaggio "The bot is currently full", la registrazione
# e' riaperta => invia un messaggio Telegram.
# Le credenziali arrivano dai secrets TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.

$ErrorActionPreference = "Stop"

$PageUrl   = "https://www.callmebot.com/blog/free-api-whatsapp-messages/"
$StateFile = "./cbstate.json"

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

Write-Log "--- Controllo CallMeBot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC ---"

# Modalita' test: invia messaggio di prova via Telegram ed esce
if ($env:TEST_MESSAGE -eq "true") {
    $sent = Send-Telegram "TEST invio: il controllo CallMeBot e' attivo. Ti avviso qui appena la registrazione gratuita WhatsApp si riapre."
    if ($sent) { Write-Log "TEST MESSAGE INVIATO CORRETTAMENTE." } else { Write-Log "TEST MESSAGE: invio fallito, controllare i secrets." }
    exit 0
}

try {
    $html = (Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36" }).Content
} catch {
    Write-Log "ERRORE scaricando la pagina CallMeBot: $($_.Exception.Message)"
    exit 0
}

# "chiusa" = la pagina contiene ancora l'avviso di bot pieno
$full = $html -match "currently\s+full"
if ($full) { Write-Log "Stato: registrazione ANCORA CHIUSA (bot pieno)." }
else       { Write-Log "Stato: nessun avviso 'bot pieno' trovato => possibile RIAPERTURA." }

# Baseline: primo run (nessuno stato salvato) => salva e non avvisa
if (-not (Test-Path $StateFile)) {
    @{ open = (-not $full) } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Baseline iniziale salvata."
    exit 0
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json

if (-not $full -and -not $state.open) {
    # RIAPERTURA: avvisa (claim anticipato per evitare doppi)
    @{ open = $true } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    $msg = "<b>🔔 CallMeBot RIAPERTO!</b>"
    $msg += "`nLa registrazione gratuita WhatsApp sembra di nuovo attiva."
    $msg += "`nProcedura (dal telefono): aggiungi il numero del bot ai contatti (ora visibile sulla pagina), invia <i>I allow callmebot to send me messages</i> su WhatsApp, ricevi l'apikey."
    $msg += "`nPagina: $PageUrl"
    $msg += "`nQuando hai l'apikey: aggiornare vinted-whatsapp-config / config.json e attivare il canale WhatsApp."
    $sent = Send-Telegram $msg
    if ($sent) {
        Write-Log "AVVISO RIAPERTURA INVIATO."
    } else {
        # invio fallito: ritenta al prossimo giro
        @{ open = $false } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
        Write-Log "Invio fallito: ritento al prossimo ciclo."
    }
    exit 0
}

if ($full -and $state.open) {
    # ri-chiuso dopo una riapertura: riarma silenziosamente
    @{ open = $false } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding utf8
    Write-Log "Registrazione tornata chiusa: notifica riarmata."
    exit 0
}

Write-Log "Nessun cambiamento."
