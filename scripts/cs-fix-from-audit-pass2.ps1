[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$CsvPath = ".\audit\cs-audit-trackers.csv",
  [switch]$Backup
)

function Get-RepoRoot {
  try { return (git rev-parse --show-toplevel 2>$null).Trim() } catch { return (Get-Location).Path }
}

function Resolve-PathFromCsv([string]$repoRoot, [string]$relOrAbs) {
  if ([string]::IsNullOrWhiteSpace($relOrAbs)) { return $null }
  if (Test-Path $relOrAbs) { return (Resolve-Path $relOrAbs).Path }
  $p = Join-Path $repoRoot $relOrAbs
  if (Test-Path $p) { return (Resolve-Path $p).Path }
  return $null
}

function Normalize-CssLink([string]$html) {
  $canonical = '  <link rel="stylesheet" href="/assets/css/main.css" />'

  # Replace any existing main.css link regardless of quoting / attribute order
  if ($html -match '(?is)<link\b[^>]*href\s*=\s*(?:"|''|)?/assets/css/main\.css(?:"|''|)?[^>]*>') {
    return [regex]::Replace(
      $html,
      '(?is)<link\b[^>]*href\s*=\s*(?:"|''|)?/assets/css/main\.css(?:"|''|)?[^>]*>',
      $canonical,
      1
    )
  }

  # Insert before </head>
  if ($html -match '(?is)</head>') {
    return [regex]::Replace($html, '(?is)</head>', "$canonical`n</head>", 1)
  }

  return $html
}

function Ensure-ClassInTag([string]$html, [string]$tag, [string]$requiredClass) {
  # Only match real tags (word boundary): <li\b, <ul\b
  $pattern = "(?is)<$tag\b(?![^>]*\b$([regex]::Escape($requiredClass))\b)([^>]*)>"

  return [regex]::Replace($html, $pattern, {
    param($m)
    $attrs = $m.Groups[1].Value

    if ($attrs -match '\bclass\s*=\s*"([^"]*)"') {
      $cls = $Matches[1]
      $new = ($cls + " " + $requiredClass).Trim()
      $attrs = [regex]::Replace($attrs, '\bclass\s*=\s*"([^"]*)"', ('class="' + $new + '"'), 1)
      return "<$tag$attrs>"
    }

    if ($attrs -match "\bclass\s*=\s*'([^']*)'") {
      $cls = $Matches[1]
      $new = ($cls + " " + $requiredClass).Trim()
      $attrs = [regex]::Replace($attrs, "\bclass\s*=\s*'([^']*)'", ("class='$new'"), 1)
      return "<$tag$attrs>"
    }

    if ($attrs -match '\bclass\s*=\s*([^\s>]+)') {
      $cls = $Matches[1]
      $new = ($cls + " " + $requiredClass).Trim()
      $attrs = [regex]::Replace($attrs, '\bclass\s*=\s*([^\s>]+)', ('class="' + $new + '"'), 1)
      return "<$tag$attrs>"
    }

    return "<$tag class=""$requiredClass""$attrs>"
  })
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
  $masked = [regex]::Replace($masked, '(?i)\bWorkgroup\b\s*:\s*', '')
  return (Unmask-Urls $masked $tmp.Map)
}

function DateKey([string]$d) {
  if ($d -match '^\d{4}\.\d{2}\.\d{2}$') {
    return [int]($d -replace '\.','')
  }
  return 0
}

function Get-WeeklyLinksFromFs([string]$repoRoot, [string]$scope, [string]$tracker) {
  $weeklyRoot = Join-Path $repoRoot ("public/reports/{0}/trackers/{1}/weekly" -f $scope, $tracker)
  $items = @()
  if (!(Test-Path $weeklyRoot)) { return $items }

  # directory-style weekly/YYYY.MM.DD/index.html
  Get-ChildItem $weeklyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
    ForEach-Object {
      $idx = Join-Path $_.FullName "index.html"
      if (Test-Path $idx) {
        $items += [pscustomobject]@{
          Date = $_.Name
          Href = ("/reports/{0}/trackers/{1}/weekly/{2}/" -f $scope, $tracker, $_.Name)
        }
      }
    }

  # file-style weekly/YYYY.MM.DD.html
  Get-ChildItem $weeklyRoot -File -Filter "*.html" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
    ForEach-Object {
      $date = $_.Name -replace '\.html$',''
      $items += [pscustomobject]@{
        Date = $date
        Href = ("/reports/{0}/trackers/{1}/weekly/{2}.html" -f $scope, $tracker, $date)
      }
    }

  return ($items | Sort-Object { DateKey $_.Date } -Descending)
}

function Fix-LatestWeeklySection([string]$html, [string]$repoRoot, [string]$scope, [string]$tracker) {
  $m = [regex]::Match($html, '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>')
  if (!$m.Success) { return $html }

  $sec = $m.Value
  $aMatches = [regex]::Matches($sec, '(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>')

  $dated = @()
  $other = @()

  foreach ($a in $aMatches) {
    $href = $a.Groups[1].Value
    $text = ($a.Groups[2].Value -replace '(?is)<[^>]+>', '').Trim()

    $dm = [regex]::Match($href, '(\d{4}\.\d{2}\.\d{2})')
    if (-not $dm.Success) { $dm = [regex]::Match($text, '(\d{4}\.\d{2}\.\d{2})') }

    if ($dm.Success) {
      $dated += [pscustomobject]@{ Date=$dm.Groups[1].Value; Href=$href }
    } elseif ($href) {
      $other += [pscustomobject]@{ Text=$text; Href=$href }
    }
  }

  # If section has no links, populate from filesystem
  if ($aMatches.Count -eq 0) {
    $dated = Get-WeeklyLinksFromFs -repoRoot $repoRoot -scope $scope -tracker $tracker
  }

  if ($dated.Count -gt 0) {
    $dated = $dated | Sort-Object { DateKey $_.Date } -Descending
  }

  $li = @()

  foreach ($d in $dated) {
    $li += @"
    <li class="cs-report__list-item">
      <a href="$($d.Href)">
        $($d.Date)
      </a>
    </li>
"@
  }

  foreach ($o in $other) {
    if (-not [string]::IsNullOrWhiteSpace($o.Text)) {
      $li += @"
    <li class="cs-report__list-item">
      <a href="$($o.Href)">
        $($o.Text)
      </a>
    </li>
"@
    }
  }

  if ($li.Count -eq 0) {
    $li += '    <li class="cs-report__list-item">No weekly reports posted yet.</li>'
  }

  $newSec = @"
<section id="latest-weekly" class="cs-report__section">
  <h2 class="cs-report__section-title">Latest Weekly Update</h2>

  <ul class="cs-report__list">
$($li -join "")
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

# ---------------- RUN ----------------
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
  if ([string]::IsNullOrWhiteSpace($allIssues)) { continue }

  $path = Resolve-PathFromCsv -repoRoot $repoRoot -relOrAbs $rel
  if (-not $path) {
    Write-Warning "SKIP (file not found): $rel"
    continue
  }

  $orig = Get-Content -Raw -Path $path
  $html = $orig

  if ($allIssues -match 'MissingCssLink') {
    $html = Normalize-CssLink $html
  }

  # Only affects real <ul> / <li> tags now (not <link>)
  if ($allIssues -match 'LiMissingCsReportListItem|UlMissingCsReportList') {
    $html = Ensure-ClassInTag $html "ul" "cs-report__list"
    $html = Ensure-ClassInTag $html "li" "cs-report__list-item"
  }

  if ($allIssues -match 'WorkgroupLabelPresent') {
    $html = Remove-WorkgroupLabel $html
  }

  if ($pageType -eq 'landing' -and ($allIssues -match 'LandingLatestWeeklyNotNewestFirst|LandingLatestWeeklyNoLinks')) {
    $html = Fix-LatestWeeklySection -html $html -repoRoot $repoRoot -scope $scope -tracker $tracker
    $html = Ensure-ClassInTag $html "ul" "cs-report__list"
    $html = Ensure-ClassInTag $html "li" "cs-report__list-item"
  }

  if ($html -ne $orig) {
    if ($PSCmdlet.ShouldProcess($path, "Apply drift fixes from audit CSV")) {
      if ($Backup) { Copy-Item -Force $path ($path + ".bak") }
      Set-Content -Path $path -Value $html -Encoding UTF8 -NoNewline
      $changed++
      Write-Host ("UPDATED: {0}" -f $path)
    }
  }
}

Write-Host ""
Write-Host ("Files changed: {0}" -f $changed)