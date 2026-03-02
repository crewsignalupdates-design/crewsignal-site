[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$CsvPath = ".\audit\cs-audit-trackers.csv",
  [switch]$Backup
)

function Get-RepoRoot {
  try { return (git rev-parse --show-toplevel 2>$null).Trim() } catch { return (Get-Location).Path }
}

function Resolve-RowPath([string]$repoRoot, [string]$relOrAbs) {
  if ([string]::IsNullOrWhiteSpace($relOrAbs)) { return $null }
  if (Test-Path $relOrAbs) { return (Resolve-Path $relOrAbs).Path }
  $p = Join-Path $repoRoot $relOrAbs
  if (Test-Path $p) { return (Resolve-Path $p).Path }
  return $null
}

function Normalize-CssLink([string]$html) {
  $canonical = '  <link rel="stylesheet" href="/assets/css/main.css" />'

  # Replace any existing main.css link tag (any quoting/attribute order) with canonical
  if ($html -match '(?is)<link\b[^>]*href\s*=\s*(?:"|''|)?/assets/css/main\.css(?:"|''|)?[^>]*>') {
    return [regex]::Replace(
      $html,
      '(?is)<link\b[^>]*href\s*=\s*(?:"|''|)?/assets/css/main\.css(?:"|''|)?[^>]*>',
      $canonical,
      1
    )
  }

  # Otherwise insert before </head>
  if ($html -match '(?is)</head>') {
    return [regex]::Replace($html, '(?is)</head>', "$canonical`n</head>", 1)
  }

  return $html
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
  foreach ($k in $map.Keys) { $html = $html.Replace($k, $map[$k]) }
  return $html
}

function Remove-WorkgroupLabel([string]$html) {
  $tmp = Mask-Urls $html
  $masked = $tmp.Html
  # remove label (don’t touch the rest of the line beyond removing the label itself)
  $masked = [regex]::Replace($masked, '(?i)\bWorkgroup\b\s*:\s*', '')
  return (Unmask-Urls $masked $tmp.Map)
}

function DateKey([string]$d) {
  if ($d -match '^\d{4}\.\d{2}\.\d{2}$') { return [int]($d -replace '\.','') }
  return 0
}

function Get-WeeklyLinks([string]$repoRoot, [string]$scope, [string]$tracker) {
  $weeklyRoot = Join-Path $repoRoot ("public/reports/{0}/trackers/{1}/weekly" -f $scope, $tracker)
  $items = @()
  if (!(Test-Path $weeklyRoot)) { return $items }

  if ($scope -eq "mediation") {
    # Prefer directory style: weekly/YYYY.MM.DD/index.html
    Get-ChildItem $weeklyRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
      ForEach-Object {
        $idx = Join-Path $_.FullName "index.html"
        if (Test-Path $idx) {
          $items += [pscustomobject]@{
            Date=$_.Name
            Href=("/reports/{0}/trackers/{1}/weekly/{2}/" -f $scope, $tracker, $_.Name)
          }
        }
      }

    # Fallback to file style if needed
    if ($items.Count -eq 0) {
      Get-ChildItem $weeklyRoot -File -Filter "*.html" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
        ForEach-Object {
          $date = $_.Name -replace '\.html$',''
          $items += [pscustomobject]@{
            Date=$date
            Href=("/reports/{0}/trackers/{1}/weekly/{2}.html" -f $scope, $tracker, $date)
          }
        }
    }
  }
  else {
    # Prefer file style: weekly/YYYY.MM.DD.html
    Get-ChildItem $weeklyRoot -File -Filter "*.html" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
      ForEach-Object {
        $date = $_.Name -replace '\.html$',''
        $items += [pscustomobject]@{
          Date=$date
          Href=("/reports/{0}/trackers/{1}/weekly/{2}.html" -f $scope, $tracker, $date)
        }
      }

    # Fallback to directory style if needed
    if ($items.Count -eq 0) {
      Get-ChildItem $weeklyRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
        ForEach-Object {
          $idx = Join-Path $_.FullName "index.html"
          if (Test-Path $idx) {
            $items += [pscustomobject]@{
              Date=$_.Name
              Href=("/reports/{0}/trackers/{1}/weekly/{2}/" -f $scope, $tracker, $_.Name)
            }
          }
        }
    }
  }

  return ($items | Sort-Object { DateKey $_.Date } -Descending)
}

function Rebuild-LatestWeeklySection([string]$html, [string]$repoRoot, [string]$scope, [string]$tracker) {
  $items = Get-WeeklyLinks -repoRoot $repoRoot -scope $scope -tracker $tracker

  # If still none, leave as-is (we don’t want to manufacture links)
  if ($items.Count -eq 0) { return $html }

  $lis = ($items | ForEach-Object {
@"
    <li class="cs-report__list-item">
      <a href="$($_.Href)">
        $($_.Date)
      </a>
    </li>
"@
  }) -join ""

  $newSec = @"
<section id="latest-weekly" class="cs-report__section">
  <h2 class="cs-report__section-title">Latest Weekly Update</h2>

  <ul class="cs-report__list">
$($lis.TrimEnd())
  </ul>
</section>
"@

  # Replace existing section if present
  if ($html -match '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>') {
    return [regex]::Replace(
      $html,
      '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>',
      [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newSec },
      1
    )
  }

  # Otherwise insert right after <main ...>
  if ($html -match '(?is)<main\b[^>]*>') {
    return [regex]::Replace($html, '(?is)<main\b[^>]*>', '$0' + "`n`n  " + $newSec + "`n", 1)
  }

  return $html
}

# -------------- RUN --------------
$repoRoot = Get-RepoRoot
$rows = Import-Csv $CsvPath | Where-Object { [int]$_.IssueCount -gt 0 }
$groups = $rows | Group-Object RelPath

$changed = 0

foreach ($g in $groups) {
  $row0 = $g.Group | Select-Object -First 1
  $scope = $row0.Scope
  $tracker = $row0.Tracker
  $pageType = $row0.PageType
  $rel = $g.Name

  $allIssues = ($g.Group | ForEach-Object { $_.Issues }) -join ';'
  $path = Resolve-RowPath -repoRoot $repoRoot -relOrAbs $rel
  if (-not $path) {
    Write-Warning "SKIP (file not found): $rel"
    continue
  }

  $orig = Get-Content -Raw -Path $path
  $html = $orig

  if ($allIssues -match 'MissingCssLink') {
    $html = Normalize-CssLink $html
  }

  if ($allIssues -match 'WorkgroupLabelPresent') {
    $html = Remove-WorkgroupLabel $html
  }

  if ($pageType -eq "landing" -and ($allIssues -match 'LandingLatestWeeklyNotNewestFirst|LandingLatestWeeklyNoLinks')) {
    $html = Rebuild-LatestWeeklySection -html $html -repoRoot $repoRoot -scope $scope -tracker $tracker
  }

  if ($html -ne $orig) {
    if ($PSCmdlet.ShouldProcess($path, "Fix final drift issues")) {
      if ($Backup) { Copy-Item -Force $path ($path + ".bak") }
      Set-Content -Path $path -Value $html -Encoding UTF8 -NoNewline
      $changed++
      Write-Host ("UPDATED: {0}" -f $path)
    }
  }
}

Write-Host ""
Write-Host ("Files changed: {0}" -f $changed)