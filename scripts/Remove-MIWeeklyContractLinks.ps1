param(
  # Root folder that contains tracker folders
  [string]$TrackersRoot = ".\public\reports\merger-integration\trackers",

  # Optional: limit to a single tracker slug (e.g. "alaska-hawaiian")
  [string]$TrackerSlug = "",

  # Preview changes without writing files
  [switch]$WhatIf
)

$repoRoot = (git rev-parse --show-toplevel).Trim()

function ToAbsPath([string]$p) {
  $rel = $p.Trim()
  $rel = $rel.TrimStart(".\").TrimStart("./")
  $rel = $rel -replace '/', '\'
  return (Join-Path $repoRoot $rel)
}

$scanDir = ToAbsPath $TrackersRoot
if ($TrackerSlug) {
  $scanDir = Join-Path $scanDir $TrackerSlug
}

if (-not (Test-Path $scanDir)) {
  throw "Scan directory not found: $scanDir"
}

# Weekly pages live in ...\weekly\*.html (your current structure)
# Also include ...\YYYY.MM.DD\index.html in case any tracker uses the folder-per-week style.
$weeklyFiles =
  Get-ChildItem $scanDir -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -match '\\weekly\\.*\.html$' -or
    $_.FullName -match '\\\d{4}\.\d{2}\.\d{2}\\index\.html$'
  }

# Remove sections by ID (preferred) and by canonical H2 title (fallback)
$rxRelatedId    = [regex]::new('(?is)\s*<section\b[^>]*\bid\s*=\s*"(?:related-contract-architecture)"[^>]*>.*?</section>\s*')
$rxCompareId    = [regex]::new('(?is)\s*<section\b[^>]*\bid\s*=\s*"(?:contract-comparison)"[^>]*>.*?</section>\s*')

$rxRelatedTitle = [regex]::new('(?is)\s*<section\b[^>]*>.*?<h2\b[^>]*class\s*=\s*"cs-report__section-title"[^>]*>\s*Related Contract Architecture\s*</h2>.*?</section>\s*')
$rxCompareTitle = [regex]::new('(?is)\s*<section\b[^>]*>.*?<h2\b[^>]*class\s*=\s*"cs-report__section-title"[^>]*>\s*Contract Comparison\s*</h2>.*?</section>\s*')

$changed = New-Object System.Collections.Generic.List[string]
$unchanged = 0

foreach ($f in $weeklyFiles) {
  $raw = Get-Content $f.FullName -Raw
  $before = $raw

  $raw = $rxRelatedId.Replace($raw, "`r`n")
  $raw = $rxCompareId.Replace($raw, "`r`n")
  $raw = $rxRelatedTitle.Replace($raw, "`r`n")
  $raw = $rxCompareTitle.Replace($raw, "`r`n")

  # Clean up excess blank lines after removals (3+ -> 2)
  $raw = [regex]::Replace($raw, "(\r?\n){3,}", "`r`n`r`n")

  if ($raw -ne $before) {
    if (-not $WhatIf) {
      Set-Content -Path $f.FullName -Value $raw -Encoding UTF8
    }
    $changed.Add($f.FullName) | Out-Null
  } else {
    $unchanged++
  }
}

Write-Host ""
Write-Host ("Weekly files scanned: {0}" -f $weeklyFiles.Count)
Write-Host ("Files changed:       {0}" -f $changed.Count)
Write-Host ("Files unchanged:     {0}" -f $unchanged)

if ($changed.Count -gt 0) {
  Write-Host ""
  Write-Host "Changed files:"
  $changed | ForEach-Object { Write-Host " - $_" }
}

if ($WhatIf) {
  Write-Host ""
  Write-Host "NOTE: -WhatIf used. No files were modified."
}
