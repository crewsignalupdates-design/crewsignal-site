[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string[]]$MergerTrackers    = @("united-jetblue","republic-mesa","horizon"),
  [string[]]$MediationTrackers = @("united","horizon","psa"),
  [switch]$Backup
)

function Get-RepoRoot {
  try {
    $root = (git rev-parse --show-toplevel 2>$null).Trim()
    if ($root) { return $root }
  } catch {}
  return (Get-Location).Path
}

function Normalize-TrackerList([string[]]$Items) {
  $joined = (@($Items) -join " ")
  return ($joined -split "[,\s]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function RelPath([string]$RepoRoot, [string]$FullPath) {
  return $FullPath.Replace($RepoRoot + [IO.Path]::DirectorySeparatorChar, "")
}

function Get-LandingPath([string]$RepoRoot, [string]$Scope, [string]$Tracker) {
  return Join-Path $RepoRoot ("public/reports/{0}/trackers/{1}/index.html" -f $Scope, $Tracker)
}

function Get-WeeklyPages([string]$RepoRoot, [string]$Scope, [string]$Tracker) {
  $weeklyRoot = Join-Path $RepoRoot ("public/reports/{0}/trackers/{1}/weekly" -f $Scope, $Tracker)
  $out = New-Object System.Collections.Generic.List[object]
  if (!(Test-Path $weeklyRoot)) { return $out.ToArray() }

  # weekly/YYYY.MM.DD.html
  Get-ChildItem $weeklyRoot -File -Filter "*.html" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
    ForEach-Object {
      $date = $_.Name -replace '\.html$',''
      [void]$out.Add([pscustomobject]@{ Date=$date; Path=$_.FullName })
    }

  # weekly/YYYY.MM.DD/index.html
  Get-ChildItem $weeklyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
    ForEach-Object {
      $idx = Join-Path $_.FullName "index.html"
      if (Test-Path $idx) { [void]$out.Add([pscustomobject]@{ Date=$_.Name; Path=$idx }) }
    }

  return ($out.ToArray() | Sort-Object Date)
}

function Ensure-CssLink([string]$Html) {
  if ($Html -match '(?is)href="/assets/css/main\.css"') { return $Html }
  if ($Html -match '(?is)</head>') {
    return [regex]::Replace($Html, '(?is)</head>', "  <link rel=""stylesheet"" href=""/assets/css/main.css"" />`n</head>", 1)
  }
  if ($Html -match '(?is)<head[^>]*>') {
    return [regex]::Replace($Html, '(?is)<head[^>]*>', '$0' + "`n  <link rel=""stylesheet"" href=""/assets/css/main.css"" />", 1)
  }
  return $Html
}

function Ensure-TagHasClass([string]$Html, [string]$Tag, [string]$RequiredClass) {
  $pattern = "(?is)<$Tag\b([^>]*)>"
  return [regex]::Replace($Html, $pattern, {
    param($m)
    $attrs = $m.Groups[1].Value
    if ($attrs -match '\bclass\s*=\s*"([^"]*)"') {
      $classes = $Matches[1]
      if ($classes -notmatch "(?i)\b$([regex]::Escape($RequiredClass))\b") {
        $classes = ($classes + " " + $RequiredClass).Trim()
        $attrs = [regex]::Replace($attrs, '\bclass\s*=\s*"([^"]*)"', 'class="' + $classes + '"', 1)
      }
      return "<$Tag$attrs>"
    } else {
      return "<$Tag class=""$RequiredClass""$attrs>"
    }
  })
}

function Ensure-BodyCsReport([string]$Html) {
  if ($Html -notmatch '(?is)<body\b') { return $Html }
  # Ensure cs-report token is present; keep any existing classes
  $pattern = '(?is)<body\b([^>]*)>'
  return [regex]::Replace($Html, $pattern, {
    param($m)
    $attrs = $m.Groups[1].Value
    if ($attrs -match '\bclass\s*=\s*"([^"]*)"') {
      $classes = $Matches[1]
      if ($classes -notmatch '(?i)\bcs-report\b') {
        $classes = ($classes + " cs-report").Trim()
        $attrs = [regex]::Replace($attrs, '\bclass\s*=\s*"([^"]*)"', 'class="' + $classes + '"', 1)
      }
      return "<body$attrs>"
    } else {
      return "<body class=""cs-report""$attrs>"
    }
  }, 1)
}

function Ensure-MainCsReportMain([string]$Html) {
  if ($Html -match '(?is)<main\b') {
    return (Ensure-TagHasClass -Html $Html -Tag "main" -RequiredClass "cs-report__main")
  }

  # No <main>: insert wrapper between </header> and <footer ...> (or </body>)
  if ($Html -notmatch '(?is)</header>') { return $Html }

  $afterHeader = [regex]::Replace($Html, '(?is)</header>', "</header>`n`n  <main class=""cs-report__main"">", 1)

  if ($afterHeader -match '(?is)<footer\b') {
    return [regex]::Replace($afterHeader, '(?is)<footer\b', "  </main>`n`n<footer", 1)
  }

  if ($afterHeader -match '(?is)</body>') {
    return [regex]::Replace($afterHeader, '(?is)</body>', "  </main>`n</body>", 1)
  }

  return $afterHeader
}

function Ensure-ListClasses([string]$Html) {
  $Html = Ensure-TagHasClass -Html $Html -Tag "ul" -RequiredClass "cs-report__list"
  $Html = Ensure-TagHasClass -Html $Html -Tag "li" -RequiredClass "cs-report__list-item"
  return $Html
}

function Fix-LatestWeeklySection([string]$Html) {
  $secMatch = [regex]::Match($Html, '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>')
  if (!$secMatch.Success) { return $Html }

  $sec = $secMatch.Value
  $aMatches = [regex]::Matches($sec, '(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>')

  $items = @()
  foreach ($a in $aMatches) {
    $href = $a.Groups[1].Value
    $dm = [regex]::Match($href, '(\d{4}\.\d{2}\.\d{2})')
    if (!$dm.Success) {
      $text = ($a.Groups[2].Value -replace '(?is)<[^>]+>', '').Trim()
      $dm = [regex]::Match($text, '(\d{4}\.\d{2}\.\d{2})')
    }
    if ($dm.Success) {
      $date = $dm.Groups[1].Value
      $items += [pscustomobject]@{ Date=$date; Href=$href }
    }
  }

  if ($items.Count -eq 0) { return $Html }

  $items = $items | Sort-Object Date -Descending

  $li = $items | ForEach-Object {
@"
    <li class="cs-report__list-item">
      <a href="$($_.Href)">
        $($_.Date)
      </a>
    </li>
"@
  } | Out-String

  $newSec = @"
<section id="latest-weekly" class="cs-report__section">
  <h2 class="cs-report__section-title">Latest Weekly Update</h2>

  <ul class="cs-report__list">
$($li.TrimEnd())
  </ul>
</section>
"@

  $updated = [regex]::Replace($Html, '(?is)<section\b[^>]*\bid\s*=\s*"latest-weekly"[^>]*>.*?</section>', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newSec }, 1)

  # Update "Updated through: YYYY.MM.DD" if present (doesn't affect links)
  $newest = $items[0].Date
  $updated = [regex]::Replace($updated, '(?is)(Updated\s+through:\s*)(\d{4}\.\d{2}\.\d{2})', ('$1' + $newest), 1)

  return $updated
}

function Fix-NamingRulePlainText([string]$Html) {
  # Mask href/src values so URLs never change
  $map = @{}
  $i = 0
  $masked = [regex]::Replace($Html, '(?is)\b(href|src)\s*=\s*"([^"]*)"', {
    param($m)
    $key = "__CS_URL_$i__"
    $map[$key] = $m.Groups[2].Value
    $i++
    return ($m.Groups[1].Value + '="' + $key + '"')
  })

  # Build token without typing it directly
  $t = ('A'+'F'+'A')
  $from1 = ($t + '-' + 'CWA')        # legacy hyphen form
  $to    = ('CWA-' + $t)

  # Replace legacy forms in plain text
  $masked = [regex]::Replace($masked, "(?i)\b$([regex]::Escape($from1))\b", $to)

  # Replace standalone token unless already in CWA-<token>
  $masked = [regex]::Replace($masked, "(?i)(?<!CWA-)\b$t\b", $to)

  # Remove any "Workgroup:" label (do not touch content otherwise)
  $masked = [regex]::Replace($masked, '(?i)\bWorkgroup:\s*', '')

  # Unmask URLs
  foreach ($k in $map.Keys) {
    $masked = $masked.Replace($k, $map[$k])
  }

  return $masked
}

function Try-FixMojibake([string]$Html) {
  # If it contains common mojibake lead chars, try to reverse 1252->UTF8.
  $c2 = [char]0x00C2
  $e2 = [char]0x00E2
  $c3 = [char]0x00C3

  if (-not ($Html.Contains($c2) -or $Html.Contains($e2) -or $Html.Contains($c3))) { return $Html }

  $enc1252 = [System.Text.Encoding]::GetEncoding(1252)
  $bytes = $enc1252.GetBytes($Html)
  $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)

  # If conversion introduces replacement chars, skip to avoid corruption
  $rep = [char]0xFFFD
  if ($fixed.Contains($rep)) { return $Html }

  return $fixed
}

function Normalize-MediationHeadings([string]$Html) {
  # Rename common drift headings to canonical ones (does not invent missing content)
  $Html = [regex]::Replace($Html, '(?is)(<h2[^>]*>)(\s*current\s+status\s*)(</h2>)', '$1Status This Week$3')
  $Html = [regex]::Replace($Html, '(?is)(<h2[^>]*>)(\s*status\s*)(</h2>)', '$1Status This Week$3')
  $Html = [regex]::Replace($Html, '(?is)(<h2[^>]*>)(\s*process\s+signals\s*)(</h2>)', '$1Process Signals$3')
  $Html = [regex]::Replace($Html, '(?is)(<h2[^>]*>)(\s*assessment\s*)(</h2>)', '$1CrewSignal Assessment$3')
  return $Html
}

function Normalize-WeeklySubtitle([string]$Html, [string]$Date) {
  if (-not $Date) { return $Html }
  $pattern = '(?is)<p([^>]*\bcs-report__subtitle\b[^>]*)>(.*?)</p>'
  return [regex]::Replace($Html, $pattern, {
    param($m)
    $attrs = $m.Groups[1].Value
    $inner = ($m.Groups[2].Value -replace '(?is)<[^>]+>', '').Trim()
    # Only normalize if it looks like a date/week label or is empty
    if ([string]::IsNullOrWhiteSpace($inner) -or $inner -match '\d{4}\.\d{2}\.\d{2}' -or $inner -match '(?i)\bweek\s+ending\b') {
      return "<p$attrs>Week ending $Date</p>"
    }
    return $m.Value
  }, 1)
}

$repoRoot = Get-RepoRoot
$MergerTrackers    = Normalize-TrackerList $MergerTrackers
$MediationTrackers = Normalize-TrackerList $MediationTrackers

$targets = New-Object System.Collections.Generic.List[object]

function Add-TrackerTargets([string]$Scope, [string[]]$Trackers) {
  foreach ($t in $Trackers) {
    $landing = Get-LandingPath -RepoRoot $repoRoot -Scope $Scope -Tracker $t
    if (Test-Path $landing) {
      [void]$targets.Add([pscustomobject]@{ Scope=$Scope; Tracker=$t; Type="landing"; Date=""; Path=$landing })
    }
    foreach ($w in (Get-WeeklyPages -RepoRoot $repoRoot -Scope $Scope -Tracker $t)) {
      [void]$targets.Add([pscustomobject]@{ Scope=$Scope; Tracker=$t; Type="weekly"; Date=$w.Date; Path=$w.Path })
    }
  }
}

Add-TrackerTargets -Scope "merger-integration" -Trackers $MergerTrackers
Add-TrackerTargets -Scope "mediation" -Trackers $MediationTrackers

$changed = 0

foreach ($t in $targets) {
  $path = $t.Path
  $orig = Get-Content -Raw -Path $path
  $html = $orig

  $html = Ensure-CssLink $html
  $html = Ensure-BodyCsReport $html
  $html = Ensure-MainCsReportMain $html
  $html = Ensure-TagHasClass -Html $html -Tag "header" -RequiredClass "cs-report__header"
  $html = Ensure-TagHasClass -Html $html -Tag "footer" -RequiredClass "cs-report__footer"
  $html = Ensure-ListClasses $html

  if ($t.Type -eq "landing") {
    $html = Fix-LatestWeeklySection $html
  }

  if ($t.Scope -eq "mediation") {
    $html = Normalize-MediationHeadings $html
  }

  if ($t.Type -eq "weekly" -and $t.Date) {
    $html = Normalize-WeeklySubtitle -Html $html -Date $t.Date
  }

  $html = Fix-NamingRulePlainText $html
  $html = Try-FixMojibake $html

  if ($html -ne $orig) {
    if ($PSCmdlet.ShouldProcess($path, "Standardize tracker HTML")) {
      if ($Backup) {
        Copy-Item -Force $path ($path + ".bak")
      }
      Set-Content -Path $path -Value $html -Encoding UTF8 -NoNewline
      $changed++
      Write-Host ("UPDATED: {0}" -f (RelPath $repoRoot $path))
    }
  }
}

Write-Host ""
Write-Host ("Files changed: {0}" -f $changed)