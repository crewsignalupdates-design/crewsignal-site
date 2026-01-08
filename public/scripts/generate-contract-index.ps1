$root = "public/reports/contract-architecture"
$out  = "public/reports/contract-architecture/contract-index.json"

function Get-YearRange($name) {
  $m = [regex]::Match($name, '(19|20)\d{2}\s*[–-]\s*(19|20)\d{2}')
  if ($m.Success) {
    $parts = ($m.Value -replace '\s','') -split '[–-]'
    return @{ start = [int]$parts[0]; end = [int]$parts[1] }
  }
  return $null
}

function Get-DocType($name) {
  if ($name -match '(?i)\bTA\b|Tentative|_TA_|-TA-') { return "TA" }
  if ($name -match '(?i)\bCBA\b|_CBA_|-CBA-| CBA ') { return "CBA" }
  if ($name -match '(?i)contract')                  { return "Contract" }
  return "Unknown"
}

$entries = @()

Get-ChildItem $root -Directory |
Where-Object { $_.Name -notin @("criteria") } |
ForEach-Object {
  $union = $_.Name

  Get-ChildItem $_.FullName -Directory | ForEach-Object {
    $carrier = $_.Name
    $carrierPage = "/reports/contract-architecture/$union/$carrier/"

    $pdfs = @()
    $contractDir = Join-Path $_.FullName "contract"

    if (Test-Path $contractDir) {
      Get-ChildItem $contractDir -Filter *.pdf -ErrorAction SilentlyContinue |
      ForEach-Object {
$years = Get-YearRange $_.Name
$docType = Get-DocType $_.Name

# Fallback: if it has a year range and isn't explicitly TA, treat as CBA
if ($docType -eq "Unknown" -and $years -ne $null) {
  $docType = "CBA"
}

# 2) If it's still Unknown (no year range, no CBA/TA keywords) => treat as Contract
if ($docType -eq "Unknown") {
  $docType = "Contract"
}

$pdfs += [pscustomobject]@{
  fileName = $_.Name
  href     = "/reports/contract-architecture/$union/$carrier/contract/$($_.Name)"
  docType  = $docType
  years    = $years
}
        
      }
    }

    # Status is intentionally neutral: just indicates whether PDFs exist
    $status = if ($pdfs.Count -gt 0) { "active" } else { "no_pdf" }

    $entries += [pscustomobject]@{
      union       = $union
      carrier     = $carrier
      carrierPage = $carrierPage
      status      = $status
      pdfCount    = $pdfs.Count
      pdfs        = $pdfs
    }
  }
}

$index = [pscustomobject]@{
  generatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
  root        = "/reports/contract-architecture/"
  contracts   = ($entries | Sort-Object union, carrier)
}

$index | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $out
Write-Host "Generated $out"
