# Test: Vinted raggiungibile dal runner GitHub Actions?
$ErrorActionPreference = "Stop"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

Write-Output "--- Test Vinted $(Get-Date -Format 'HH:mm:ss') UTC ---"

foreach ($term in @("76294", "x-mansion")) {
    $url = "https://www.vinted.it/catalog?search_text=$([uri]::EscapeDataString($term))"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $UA } -UseBasicParsing -TimeoutSec 60
        $anchors = [regex]::Matches($resp.Content, 'data-testid="product-item-id-(\d+)"').Count
        Write-Output "RISULTATO '$term': HTTP $([int]$resp.StatusCode) LEN=$($resp.Content.Length) ITEMS=$anchors"
    } catch {
        Write-Output "RISULTATO '$term': BLOCCO - $($_.Exception.Message)"
    }
}
