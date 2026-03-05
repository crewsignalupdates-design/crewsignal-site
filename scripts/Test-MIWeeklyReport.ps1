param(
  [Parameter(Mandatory = $true)]
  [string]$Path
)

if (-not (Test-Path $Path)) {
  throw "File not found: $Path"
}

$raw = Get-Content $Path -Raw
$errors = New-Object System.Collections.Generic.List[string]

$requiredPatterns = @(
  @{ Name = "body class"; Pattern = '<body class="cs-report">' },
  @{ Name = "Status Summary"; Pattern = '<section id="status-this-week" class="cs-report__section">[\s\S]*?<h2 class="cs-report__section-title">Status Summary</h2>' },
  @{ Name = "Integration Dashboard"; Pattern = '<section id="integration-dashboard" class="cs-report__section">[\s\S]*?<h2 class="cs-report__section-title">Integration Dashboard</h2>' },
  @{ Name = "CrewSignal Watch Points"; Pattern = '<section id="crewsignal-assessment" class="cs-report__section">[\s\S]*?<h2 class="cs-report__section-title">CrewSignal Watch Points</h2>' },
  @{ Name = "Notable Public References"; Pattern = '<section id="notable-public-references" class="cs-report__section">[\s\S]*?<h2 class="cs-report__section-title">Notable Public References</h2>' },
  @{ Name = "Related Contract Architecture"; Pattern = '<section id="related-contract-architecture" class="cs-report__section">[\s\S]*?<h2 class="cs-report__section-title">Related Contract Architecture</h2>' },
  @{ Name = "Contract Comparison"; Pattern = '<section class="cs-report__section" id="contract-comparison">[\s\S]*?<h2 class="cs-report__section-title">Contract Comparison</h2>' },
  @{ Name = "list wrapper"; Pattern = '<ul class="cs-report__list">' },
  @{ Name = "list item class"; Pattern = '<li class="cs-report__list-item">' },
  @{ Name = "indent style"; Pattern = '\.cs-report__section > \.cs-report__list' }
)

foreach ($item in $requiredPatterns) {
  if ($raw -notmatch $item.Pattern) {
    $errors.Add("Missing or malformed: $($item.Name)")
  }
}

if ($raw -match '<p[^>]*>\s*<li') {
  $errors.Add("Invalid list structure: found <li> directly inside <p>.")
}

if ($raw -notmatch 'href="/reports/contract-architecture/"') {
  $errors.Add("Missing Contract Architecture library link.")
}

$carrierContractLinks = [regex]::Matches($raw, 'href="/reports/contract-architecture/CWA-AFA/[^/]+/"').Count
if ($carrierContractLinks -lt 2) {
  $errors.Add("Expected two carrier contract analysis links.")
}

if ($raw -notmatch 'href="/reports/merger-integration/trackers/[^"]+/contract-comparison/"') {
  $errors.Add("Missing Contract Comparison link.")
}

if ($errors.Count -gt 0) {
  Write-Host ""
  Write-Host "FAIL: $Path" -ForegroundColor Red
  foreach ($error in $errors) {
    Write-Host " - $error" -ForegroundColor Red
  }
  exit 1
}

Write-Host "PASS: $Path" -ForegroundColor Green
