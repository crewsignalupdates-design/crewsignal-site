[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$CsvPath = ".\audit\cs-audit-trackers.csv",
  [switch]$Backup
)

function Get-RepoRoot {
  try {
    $root = (git rev-parse --show-toplevel 2>$null).Trim()
    if ($root) { return $root }
  } catch {}
  return (Get-Location).Path
}

function Resolve-RowPath([string]$repoRoot, [string]$relPath, [string]$scope, [string]$tracker) {
  if ($relPath -and (Test-Path $relPath)) { return (Resolve-Path $relPath).Path }

  if ($relPath) {
    $p = Join-Path $repoRoot $relPath
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }

  # Fallback: compute canonical landing path
  $fallback = Join-Path $repoRoot ("public/reports/{0}/trackers/{1}/index.html" -f $scope, $tracker)
  if (Test-Path $fallback) { return (Resolve-Path $fallback).Path }

  return $fallback
}

function Mask-Urls([string]$html) {
  $map = @{}
  $i = 0
  $masked = [regex]::Replace($html, '(?is)\b(href|src)\s*=\s*"([^"]*)"', {
    param($m)
    $key = "__CS_URL_$i__"
    $map[$key] = $m.Groups[2].Value
    $i++
    return ($m.Groups[1].Value + '="' + $key + '"')
  })
  return [pscustomobject]@{ Html=$masked; Map=$map }
}

function Unmask-Urls([string]$html, [hashtable]$map) {
  foreach ($k in $map.Keys) {
    $html = $html.Replace($k, $map[$k])
  }
  return $html
}

function Ensure-ClassOnTag([string]$html, [string]$tag, [string]$requiredClass) {
  $pattern = "(?is)<$tag\b([^>]*)>"
  return [regex]::Replace($html, $pattern, {
    param($m)
    $attrs = $m.Groups[1].Value

    if ($attrs -match '\bclass\s*=\s*"([^"]*)"') {
      $classes = $Matches[1]
      if ($classes -notmatch "(?i)(^|\s)$([regex]::Escape($requiredClass))(\s|$)") {
        $classes = ($classes + " " + $requiredClass).Trim()
        $attrs = [regex]::Replace($attrs, '\bclass\s*=\s*"([^"]*)"', 'class="' + $classes + '"', 1)
      }
      return "<$tag$attrs>"
    }

    return "<$tag class=""$requiredClass""$attrs>"
  })
}

function Fix-LiUlClasses([string]$html) {
  # Always make UL/LI conform to CrewSignal expectations
  $html = Ensure-ClassOnTag $html "ul" "cs-report__list"
  $html = Ensure-ClassOnTag $html "li" "cs-report__list-item"
  return $html
}

function Fix-LatestWeeklyOrder([string]$html) {
  $m = [regex]::Match($html, '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>')
  if (!$m.Success) { return $html }

  $sec = $m.Value
  $links = [regex]::Matches($sec, '(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>')

  $dated = @()
  $other = @()

  foreach ($a in $links) {
    $href = $a.Groups[1].Value
    $textRaw = $a.Groups[2].Value
    $text = ($textRaw -replace '(?is)<[^>]+>', '').Trim()

    $dm = [regex]::Match($href, '(\d{4}\.\d{2}\.\d{2})')
    if (-not $dm.Success) { $dm = [regex]::Match($text, '(\d{4}\.\d{2}\.\d{2})') }

    if ($dm.Success) {
      $dated += [pscustomobject]@{ Date=$dm.Groups[1].Value; Href=$href }
    } else {
      # Preserve non-date links in original order
      $other += [pscustomobject]@{ Text=$text; Href=$href }
    }
  }

  if ($dated.Count -eq 0 -and $other.Count -eq 0) { return $html }

  $dated = $dated | Sort-Object Date -Descending

  $lis = @()

  foreach ($d in $dated) {
    $lis += @"
    <li class="cs-report__list-item">
      <a href="$($d.Href)">
        $($d.Date)
      </a>
    </li>
"@
  }

  foreach ($o in $other) {
    if (-not [string]::IsNullOrWhiteSpace($o.Text)) {
      $lis += @"
    <li class="cs-report__list-item">
      <a href="$($o.Href)">
        $($o.Text)
      </a>
    </li>
"@
    }
  }

  $newSec = @"
<section id="latest-weekly" class="cs-report__section">
  <h2 class="cs-report__section-title">Latest Weekly Update</h2>

  <ul class="cs-report__list">
$($lis -join "")
  </ul>
</section>
"@

  return [regex]::Replace(
    $html,
    '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($mm) $newSec },
    1
  )
}

function Normalize-MediationHeadings([string]$html, [string[]]$missingHeadings) {
  # Try common heading variants first (rename vs insert)
  if ($missingHeadings -contains "Process Signals") {
    $html = [regex]::Replace($html, '(?is)(<h2\b[^>]*>)(\s*Process\s*Signal\s*)(</h2>)', '$1Process Signals$3')
    $html = [regex]::Replace($html, '(?is)(<h2\b[^>]*>)(\s*Process\s*Signals\s*)(</h2>)', '$1Process Signals$3')
  }

  if ($missingHeadings -contains "CrewSignal Assessment") {
    $html = [regex]::Replace($html, '(?is)(<h2\b[^>]*>)(\s*Crew\s*Signal\s*Assessment\s*)(</h2>)', '$1CrewSignal Assessment$3')

    # If still missing, upgrade a generic "Assessment" heading (common drift)
    if ($html -notmatch '(?i)\bCrewSignal Assessment\b') {
      $html = [regex]::Replace($html, '(?is)(<h2\b[^>]*>)(\s*Assessment\s*)(</h2>)', '$1CrewSignal Assessment$3', 1)
    }
  }

  # Insert missing sections (only if still missing after renames)
  $sectionsToAdd = @()

  if (($missingHeadings -contains "Process Signals") -and ($html -notmatch '(?i)\bProcess Signals\b')) {
    $sectionsToAdd += @"
<section class="cs-report__section">
  <h2 class="cs-report__section-title">Process Signals</h2>
  <ul class="cs-report__list">
    <li class="cs-report__list-item">Add publicly available process updates for this week.</li>
  </ul>
</section>
"@
  }

  if (($missingHeadings -contains "CrewSignal Assessment") -and ($html -notmatch '(?i)\bCrewSignal Assessment\b')) {
    $sectionsToAdd += @"
<section class="cs-report__section">
  <h2 class="cs-report__section-title">CrewSignal Assessment</h2>
  <ul class="cs-report__list">
    <li class="cs-report__list-item">Add CrewSignal assessment based on publicly available signals.</li>
  </ul>
</section>
"@
  }

  if ($sectionsToAdd.Count -gt 0) {
    if ($html -match '(?is)</main>') {
      $html = [regex]::Replace($html, '(?is)</main>', ($sectionsToAdd -join "`n") + "`n</main>", 1)
    } elseif ($html -match '(?is)</body>') {
      $html = [regex]::Replace($html, '(?is)</body>', ($sectionsToAdd -join "`n") + "`n</body>", 1)
    }
  }

  return $html
}

function Remove-WorkgroupLabel([string]$html) {
  # Remove the label but do NOT touch URLs
  $tmp = Mask-Urls $html
  $masked = $tmp.Html

  $masked = [regex]::Replace($masked, '(?i)\bWorkgroup:\s*', '')
  # Clean up accidental " · " or " - " left behind from label removal
  $masked = [regex]::Replace($masked, '\s{2,}', ' ')

  return (Unmask-Urls $masked $tmp.Map)
}

function Get-TrackerTitle([string]$scope, [string]$tracker) {
  $map = @{
    "merger-integration|united-jetblue" = "United / JetBlue (Blue Sky)"
    "merger-integration|republic-mesa" = "Republic / Mesa"
    "merger-integration|horizon"       = "Horizon Air"

    "mediation|united" = "United Airlines"
    "mediation|horizon" = "Horizon Air"
    "mediation|psa" = "PSA Airlines"
  }
  $key = "$scope|$tracker"
  if ($map.ContainsKey($key)) { return $map[$key] }
  return ($tracker -replace '-', ' ')
}

function Get-BackLink([string]$scope) {
  if ($scope -eq "merger-integration") {
    return [pscustomobject]@{ Href="/reports/merger-integration/"; Text="&larr; Back to Merger &amp; Integration Hub"; Eyebrow="Integration Tracker" }
  }
  if ($scope -eq "mediation") {
    return [pscustomobject]@{ Href="/reports/mediation/"; Text="&larr; Back to Negotiations &amp; Mediation"; Eyebrow="Carrier mediation tracker" }
  }
  return [pscustomobject]@{ Href="/reports/"; Text="&larr; Back to Reports"; Eyebrow="Tracker" }
}

function Build-LatestWeeklyList([string]$repoRoot, [string]$scope, [string]$tracker) {
  $weeklyDir = Join-Path $repoRoot ("public/reports/{0}/trackers/{1}/weekly" -f $scope, $tracker)
  $items = New-Object System.Collections.Generic.List[object]

  if (Test-Path $weeklyDir) {
    # directory-style
    Get-ChildItem $weeklyDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
      ForEach-Object {
        $idx = Join-Path $_.FullName "index.html"
        if (Test-Path $idx) {
          [void]$items.Add([pscustomobject]@{
            Date=$_.Name
            Href=("/reports/{0}/trackers/{1}/weekly/{2}/" -f $scope, $tracker, $_.Name)
          })
        }
      }

    # file-style
    Get-ChildItem $weeklyDir -File -Filter "*.html" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
      ForEach-Object {
        $date = $_.Name -replace '\.html$',''
        [void]$items.Add([pscustomobject]@{
          Date=$date
          Href=("/reports/{0}/trackers/{1}/weekly/{2}.html" -f $scope, $tracker, $date)
        })
      }
  }

  return ($items.ToArray() | Sort-Object Date -Descending)
}

function Create-MissingLandingPage([string]$repoRoot, [string]$scope, [string]$tracker, [string]$fullPath) {
  $title = Get-TrackerTitle $scope $tracker
  $back = Get-BackLink $scope

  $latest = Build-LatestWeeklyList $repoRoot $scope $tracker
  $li = if ($latest.Count -gt 0) {
    ($latest | ForEach-Object {
@"
    <li class="cs-report__list-item">
      <a href="$($_.Href)">
        $($_.Date)
      </a>
    </li>
"@
    }) -join ""
  } else {
@"
    <li class="cs-report__list-item">No weekly reports posted yet.</li>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$title · CrewSignal</title>
  <link rel="stylesheet" href="/assets/css/main.css" />
</head>

<body class="cs-report">
  <header class="cs-report__header">
    <a class="cs-report__back" href="$($back.Href)">$($back.Text)</a>
    <p class="cs-report__eyebrow">$($back.Eyebrow)</p>
    <h1 class="cs-report__title">$title</h1>
    <p class="cs-report__subtitle">Landing page template. Standardized layout and weekly links.</p>
  </header>

  <main class="cs-report__main">
    <section class="cs-report__section" id="latest-weekly">
      <h2 class="cs-report__section-title">Latest Weekly Update</h2>

      <ul class="cs-report__list">
$($li.TrimEnd())
      </ul>
    </section>
  </main>

  <footer class="cs-report__footer">
    <p class="cs-report__fineprint">&copy; CrewSignal · Informational resource for aviation professionals</p>
  </footer>
</body>
</html>
"@

  $dir = Split-Path $fullPath -Parent
  if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  Set-Content -Path $fullPath -Value $html -Encoding UTF8 -NoNewline
}

# ---------------- RUN ----------------
$repoRoot = Get-RepoRoot
$rows = Import-Csv $CsvPath | Where-Object { [int]$_.IssueCount -gt 0 }

$changed = 0
foreach ($r in $rows) {
  $scope   = $r.Scope
  $tracker = $r.Tracker
  $pageType = $r.PageType
  $rel = $r.RelPath
  $issues = @()
  if ($r.Issues) { $issues = $r.Issues -split ';' }

  # Missing landing page: create it and move on
  if ($issues -contains "MissingLandingPage") {
    $target = Resolve-RowPath -repoRoot $repoRoot -relPath $rel -scope $scope -tracker $tracker
    if ($PSCmdlet.ShouldProcess($target, "Create missing landing page")) {
      if ($Backup -and (Test-Path $target)) { Copy-Item -Force $target ($target + ".bak") }
      Create-MissingLandingPage -repoRoot $repoRoot -scope $scope -tracker $tracker -fullPath $target
      $changed++
      Write-Host "CREATED: $target"
    }
    continue
  }

  $full = Resolve-RowPath -repoRoot $repoRoot -relPath $rel -scope $scope -tracker $tracker
  if (-not (Test-Path $full)) {
    Write-Warning "SKIP (file not found): $rel"
    continue
  }

  $orig = Get-Content -Raw -Path $full
  $html = $orig

  if ($issues -contains "LiMissingCsReportListItem") {
    $html = Fix-LiUlClasses $html
  }

  if ($issues -contains "LandingLatestWeeklyNotNewestFirst" -and $pageType -eq "landing") {
    $html = Fix-LatestWeeklyOrder $html
  }

  if ($issues -contains "WorkgroupLabelPresent") {
    $html = Remove-WorkgroupLabel $html
  }

  if ($scope -eq "mediation" -and $pageType -eq "weekly") {
    $missing = @()
    foreach ($i in $issues) {
      if ($i -like "MissingHeading:*") {
        $missing += ($i -replace '^MissingHeading:','')
      }
    }
    if ($missing.Count -gt 0) {
      $html = Normalize-MediationHeadings -html $html -missingHeadings $missing
      # keep list classes correct even if we inserted sections
      $html = Fix-LiUlClasses $html
    }
  }

  if ($html -ne $orig) {
    if ($PSCmdlet.ShouldProcess($full, "Fix remaining drift issues")) {
      if ($Backup) { Copy-Item -Force $full ($full + ".bak") }
      Set-Content -Path $full -Value $html -Encoding UTF8 -NoNewline
      $changed++
      Write-Host "UPDATED: $full"
    }
  }
}

Write-Host ""
Write-Host ("Files changed: {0}" -f $changed)