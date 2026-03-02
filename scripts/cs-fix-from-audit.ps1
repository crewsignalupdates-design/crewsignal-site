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

function Resolve-RowPath([string]$repoRoot, [string]$relPath) {
  if (Test-Path $relPath) { return (Resolve-Path $relPath).Path }
  $p = Join-Path $repoRoot $relPath
  if (Test-Path $p) { return (Resolve-Path $p).Path }
  return $null
}

function Ensure-CssLink([string]$html) {
  # Accept variants: quotes, no quotes, attribute order, etc.
  if ($html -match '(?is)href\s*=\s*["'']?/assets/css/main\.css["'']?') { return $html }

  if ($html -match '(?is)</head>') {
    return [regex]::Replace(
      $html,
      '(?is)</head>',
      "  <link rel=""stylesheet"" href=""/assets/css/main.css"" />`n</head>",
      1
    )
  }

  if ($html -match '(?is)<head\b[^>]*>') {
    return [regex]::Replace(
      $html,
      '(?is)<head\b[^>]*>',
      '$0' + "`n  <link rel=""stylesheet"" href=""/assets/css/main.css"" />",
      1
    )
  }

  return $html
}

function Add-ClassToTag([string]$html, [string]$tag, [string]$requiredClass) {
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

function Fix-LatestWeeklyOrder([string]$html) {
  $m = [regex]::Match($html, '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>')
  if (!$m.Success) { return $html }

  $sec = $m.Value
  $links = [regex]::Matches($sec, '(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>.*?</a>')

  $items = @()
  foreach ($a in $links) {
    $href = $a.Groups[1].Value
    $dm = [regex]::Match($href, '(\d{4}\.\d{2}\.\d{2})')
    if ($dm.Success) {
      $items += [pscustomobject]@{ Date=$dm.Groups[1].Value; Href=$href }
    }
  }

  if ($items.Count -eq 0) { return $html }

  $items = $items | Sort-Object Date -Descending

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

  return [regex]::Replace(
    $html,
    '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($mm) $newSec },
    1
  )
}

# ---------- RUN ----------
$repoRoot = Get-RepoRoot
$rows = Import-Csv $CsvPath

# Group by file so we only write each file once
$groups = $rows | Group-Object RelPath

$changed = 0
foreach ($g in $groups) {
  $rel = $g.Name
  $issues = ($g.Group | Select-Object -ExpandProperty Issues) -join ";"

  # Only handle the top drift categories we’re fixing here
  if ($issues -notmatch 'MissingCssLink|LiMissingCsReportListItem|UlMissingCsReportList|LandingLatestWeeklyNotNewestFirst') { continue }

  $full = Resolve-RowPath -repoRoot $repoRoot -relPath $rel
  if (-not $full) {
    Write-Warning "SKIP (path not found): $rel"
    continue
  }

  $orig = Get-Content -Raw -Path $full
  $html = $orig

  if ($issues -match 'MissingCssLink') {
    $html = Ensure-CssLink $html
  }

  if ($issues -match 'LiMissingCsReportListItem|UlMissingCsReportList') {
    $html = Add-ClassToTag $html 'ul' 'cs-report__list'
    $html = Add-ClassToTag $html 'li' 'cs-report__list-item'
  }

  if ($issues -match 'LandingLatestWeeklyNotNewestFirst') {
    $html = Fix-LatestWeeklyOrder $html
  }

  if ($html -ne $orig) {
    if ($PSCmdlet.ShouldProcess($rel, "Apply CSS/list/latest-weekly fixes")) {
      if ($Backup) {
        Copy-Item -Force $full ($full + ".bak")
      }
      Set-Content -Path $full -Value $html -Encoding UTF8 -NoNewline
      $changed++
      Write-Host "UPDATED: $rel"
    }
  }
}

Write-Host ""
Write-Host ("Files changed: {0}" -f $changed)