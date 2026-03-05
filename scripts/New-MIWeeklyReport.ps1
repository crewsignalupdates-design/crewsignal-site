param(
  [Parameter(Mandatory = $true)]
  [string]$TrackerSlug,

  [Parameter(Mandatory = $true)]
  [string]$CarrierPair,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{4}\.\d{2}\.\d{2}$')]
  [string]$WeekEnding,

  [Parameter(Mandatory = $true)]
  [string]$CarrierA,

  [Parameter(Mandatory = $true)]
  [string]$CarrierB
)

$repoRoot = (git rev-parse --show-toplevel).Trim()
$templatePath = Join-Path $repoRoot "templates\mi-weekly-report.template.html"

if (-not (Test-Path $templatePath)) {
  throw "Template not found: $templatePath"
}

$outDir = Join-Path $repoRoot "reports\merger-integration\trackers\$TrackerSlug\$WeekEnding"
$outFile = Join-Path $outDir "index.html"

if (Test-Path $outFile) {
  throw "Report already exists: $outFile"
}

$content = Get-Content $templatePath -Raw

$content = $content.Replace("__WEEK_ENDING__", $WeekEnding)
$content = $content.Replace("__CARRIER_PAIR__", $CarrierPair)
$content = $content.Replace("__TRACKER_INDEX_HREF__", "/reports/merger-integration/trackers/$TrackerSlug/")
$content = $content.Replace("__CARRIER_A__", $CarrierA)
$content = $content.Replace("__CARRIER_B__", $CarrierB)
$content = $content.Replace("__CARRIER_A_CONTRACT_HREF__", "/reports/contract-architecture/CWA-AFA/$CarrierA/")
$content = $content.Replace("__CARRIER_B_CONTRACT_HREF__", "/reports/contract-architecture/CWA-AFA/$CarrierB/")
$content = $content.Replace("__CONTRACT_COMPARISON_HREF__", "/reports/merger-integration/trackers/$TrackerSlug/contract-comparison/")

New-Item -ItemType Directory -Force $outDir | Out-Null
Set-Content -Path $outFile -Value $content -Encoding UTF8

Write-Host "Created: $outFile"
