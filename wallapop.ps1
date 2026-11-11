# Wallapop Listings Monitor - CONFIG ricerche
# Ricerche gestite dall'app Android (tab Wallapop): il blocco $Searches sotto
# e' l'unica parte che cambia. Il resto del file e' solo documentazione.
#
# NOTE TECNICHE (per il monitor locale sul PC):
# - api.wallapop.com/api/v3/search/section richiede un device-fingerprint:
#   da script non-browser risponde 400/403. La strada affidabile e' il browser
#   (Playwright) su https://es.wallapop.com/search?keywords=<termine>.
# - Da GitHub Actions non funziona: CloudFront geo-blocca gli IP USA dei runner
#   ("ERROR: The request could not be satisfied"). Il monitor gira quindi sul
#   PC locale (IP residenziale) e notifica via Telegram.
# - Il monitor locale scarica QUESTO file (raw.githubusercontent.com) e parsa
#   i termini con la regex: term = "..." (stesso schema di subito.ps1/vinted.ps1).

$Searches = @(
    @{ term = "76352" },
    @{ term = "Lego stranger Things" }
)
