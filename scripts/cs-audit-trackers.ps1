[CmdletBinding()]
param(
  [string[]]$MergerTrackers    = @("united-jetblue","republic-mesa","horizon"),
  [string[]]$MediationTrackers = @("united","horizon","psa"),
  [string]$OutCsv = ".\audit\cs-audit-trackers.csv",
  [switch]$FailOnIssues
)

function Get-RepoRoot {
  try {
    $root = (git rev-parse --show-toplevel 2>$null).Trim()
    if ($root) { return $root }
  } catch {}
  return (Get-Location).Path
}

function Normalize-TrackerList {
  param([string[]]$Items)
  # Accept: space-separated, comma-separated, or mixed
  $joined = (@($Items) -join ' ')
  $tokens = $joined -split '[,\s]+' | Where-Object { $_ }
  return $tokens
}

function RelPath {
  param([string]$RepoRoot, [string]$FullPath)
  return $FullPath.Replace($RepoRoot + [IO.Path]::DirectorySeparatorChar, "")
}

function Count-Matches {
  param([string]$Text, [string]$Pattern)
  return [regex]::Matches($Text, $Pattern, "IgnoreCase").Count
}

function Has {
  param([string]$Html, [string]$Pattern)
  return [regex]::IsMatch($Html, $Pattern, "IgnoreCase,Singleline")
}

function Strip-Html {
  param([string]$s)
  if ([string]::IsNullOrEmpty($s)) { return "" }
  $noTags = [regex]::Replace($s, '(?s)<[^>]+>', ' ')
  $decoded = [System.Net.WebUtility]::HtmlDecode($noTags)
  return ([regex]::Replace($decoded, '\s+', ' ').Trim())
}

function Get-Text {
  param([string]$Html, [string]$Pattern, [int]$Group = 1)
  $m = [regex]::Match($Html, $Pattern, "IgnoreCase,Singleline")
  if ($m.Success) { return (Strip-Html $m.Groups[$Group].Value) }
  return ""
}

function Scrub-Urls {
  param([string]$Html)
  $scrub = $Html
  $scrub = [regex]::Replace($scrub, '(?is)\bhref="[^"]*"', 'href=""')
  $scrub = [regex]::Replace($scrub, '(?is)\bsrc="[^"]*"', 'src=""')
  return $scrub
}

function Detect-EncodingArtifacts {
  param([string]$Html)
  if ([string]::IsNullOrEmpty($Html)) { return $false }
  # Look for common mojibake lead characters (no non-ASCII literals here)
  $c2 = [char]0x00C2  # typically shows up as "Â"
  $e2 = [char]0x00E2  # typically shows up as "â"
  $c3 = [char]0x00C3  # typically shows up as "Ã"
  return ($Html.Contains($c2) -or $Html.Contains($e2) -or $Html.Contains($c3))
}

function Get-LandingPath {
  param([string]$RepoRoot, [string]$Scope, [string]$Tracker)
  return Join-Path $RepoRoot ("public/reports/{0}/trackers/{1}/index.html" -f $Scope, $Tracker)
}

function Get-WeeklyPages {
  param([string]$RepoRoot, [string]$Scope, [string]$Tracker)

  $weeklyRoot = Join-Path $RepoRoot ("public/reports/{0}/trackers/{1}/weekly" -f $Scope, $Tracker)
  $out = New-Object System.Collections.Generic.List[object]

  if (!(Test-Path $weeklyRoot)) { return $out.ToArray() }

  # Pattern A: weekly/YYYY.MM.DD.html
  Get-ChildItem $weeklyRoot -File -Filter "*.html" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}\.html$' } |
    ForEach-Object {
      $date = $_.Name -replace '\.html$',''
      [void]$out.Add([pscustomobject]@{ Date=$date; Path=$_.FullName })
    }

  # Pattern B: weekly/YYYY.MM.DD/index.html
  Get-ChildItem $weeklyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}\.\d{2}\.\d{2}$' } |
    ForEach-Object {
      $idx = Join-Path $_.FullName "index.html"
      if (Test-Path $idx) {
        [void]$out.Add([pscustomobject]@{ Date=$_.Name; Path=$idx })
      }
    }

  return ($out.ToArray() | Sort-Object Date)
}

function Get-LatestWeeklyInfo {
  param([string]$Html)

  $m = [regex]::Match($Html, '(?is)<section[^>]*id="latest-weekly"[^>]*>(.*?)</section>')
  if (!$m.Success) {
    return [pscustomobject]@{
      HasSection = $false
      LinkCount  = 0
      LinkTextFormat = "Missing"
      NewestFirst = $true
      Sample = ""
    }
  }

  $section = $m.Groups[1].Value
  $links = [regex]::Matches($section, '(?is)<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>')

  $texts = @()
  $dates = @()

  foreach ($a in $links) {
    $href = $a.Groups[1].Value
    $text = Strip-Html $a.Groups[2].Value
    if ($text) { $texts += $text }

    $dm = [regex]::Match($href, '(\d{4}\.\d{2}\.\d{2})')
    if ($dm.Success) { $dates += $dm.Groups[1].Value }
  }

  $fmt = "Other"
  if ($texts.Count -eq 0) {
    $fmt = "NoLinksFound"
  } else {
    $dateOnlyCount = ($texts | Where-Object { $_ -match '^\d{4}\.\d{2}\.\d{2}$' }).Count
    $weekEndingCount = ($texts | Where-Object { $_ -match '(?i)\bweek\s+ending\b' }).Count

    if ($dateOnlyCount -eq $texts.Count) { $fmt = "DateOnly" }
    elseif ($weekEndingCount -eq $texts.Count) { $fmt = "WeekEnding" }
    elseif ($dateOnlyCount -gt 0 -or $weekEndingCount -gt 0) { $fmt = "Mixed" }
  }

  $newestFirst = $true
  if ($dates.Count -gt 1) {
    $sorted = $dates | Sort-Object -Descending
    if (-not (@($dates) -ceq @($sorted))) { $newestFirst = $false }
  }

  return [pscustomobject]@{
    HasSection = $true
    LinkCount  = $texts.Count
    LinkTextFormat = $fmt
    NewestFirst = $newestFirst
    Sample = (($texts | Select-Object -First 6) -join " | ")
  }
}

function Get-WeeklySubtitleFormat {
  param([string]$Subtitle, [string]$Date)
  if ($Subtitle -match '(?i)\bweek\s+ending\b') { return "WeekEnding" }
  if ($Date -and $Subtitle -match [regex]::Escape($Date)) { return "DateInSubtitle" }
  if ($Subtitle -match '\d{4}\.\d{2}\.\d{2}') { return "DateLikeInSubtitle" }
  if ([string]::IsNullOrWhiteSpace($Subtitle)) { return "MissingSubtitle" }
  return "Other"
}

function Audit-Common {
  param([string]$Html)

  $issues = @()

  if (-not (Has $Html '(?is)<!doctype\s+html')) { $issues += "MissingDoctype" }
  if (-not (Has $Html '(?is)<link[^>]+href="/assets/css/main\.css"')) { $issues += "MissingCssLink" }

  if (-not (Has $Html '(?is)<body[^>]*class="[^"]*\bcs-report\b')) { $issues += "BodyMissingCsReport" }
  if (-not (Has $Html '(?is)<header[^>]*class="[^"]*\bcs-report__header\b')) { $issues += "HeaderMissingClass" }
  if (-not (Has $Html '(?is)<a[^>]*class="[^"]*\bcs-report__back\b')) { $issues += "BackLinkMissingClass" }
  if (-not (Has $Html '(?is)<main[^>]*class="[^"]*\bcs-report__main\b')) { $issues += "MainMissingClass" }
  if (-not (Has $Html '(?is)<section[^>]*class="[^"]*\bcs-report__section\b')) { $issues += "SectionMissingClass" }
  if (-not (Has $Html '(?is)<footer[^>]*class="[^"]*\bcs-report__footer\b')) { $issues += "FooterMissingClass" }
  if (-not (Has $Html '(?is)\bcs-report__fineprint\b')) { $issues += "FineprintMissingClass" }

  if ((Count-Matches $Html 'cs-report__header') -gt 1) { $issues += "DuplicateHeaderBlock" }

  # Unbalanced list tags often cause layout/misalignment
  if ((Count-Matches $Html '<ul(\s|>)') -ne (Count-Matches $Html '</ul>')) { $issues += "UlTagUnbalanced" }
  if ((Count-Matches $Html '<li(\s|>)') -ne (Count-Matches $Html '</li>')) { $issues += "LiTagUnbalanced" }

  # List class drift
  if ($Html -match '(?is)<ul\b(?![^>]*\bcs-report__list\b)') { $issues += "UlMissingCsReportList" }
  if ($Html -match '(?is)<li\b(?![^>]*\bcs-report__list-item\b)') { $issues += "LiMissingCsReportListItem" }

  if (Detect-EncodingArtifacts $Html) { $issues += "EncodingArtifactsLikely" }

  # Naming rule audit (avoid hardcoding the legacy acronym in this file)
  $scrub = Scrub-Urls $Html
  $token = ('A'+'F'+'A')
  if ($scrub -match "(?<!CWA-)\b$token\b") { $issues += "NamingRulePlainText" }

  # Prohibited label audit (generic)
  if ($scrub -match '(?i)\bWorkgroup\b') { $issues += "WorkgroupLabelPresent" }

  return $issues
}

function Audit-Landing {
  param([string]$Html)

  $issues = @(Audit-Common $Html)

  $latest = Get-LatestWeeklyInfo $Html
  if (-not $latest.HasSection) { $issues += "LandingMissingLatestWeeklySection" }
  elseif ($latest.LinkCount -eq 0) { $issues += "LandingLatestWeeklyNoLinks" }
  else {
    if ($latest.LinkTextFormat -ne "DateOnly") { $issues += "LandingLatestWeeklyTextNotDateOnly" }
    if (-not $latest.NewestFirst) { $issues += "LandingLatestWeeklyNotNewestFirst" }
  }

  return ($issues | Sort-Object -Unique)
}

function Audit-Weekly {
  param([string]$Html, [string]$Scope, [string]$Date)

  $issues = @(Audit-Common $Html)

  if ($Date -and ($Html -notmatch [regex]::Escape($Date))) { $issues += "WeeklyMissingDateString" }

  if ($Scope -eq "mediation") {
    foreach ($h in @("Status This Week","Process Signals","CrewSignal Assessment")) {
      if ($Html -notmatch [regex]::Escape($h)) { $issues += ("MissingHeading:" + $h) }
    }
  }

  return ($issues | Sort-Object -Unique)
}

# ---------------- RUN ----------------

$repoRoot = Get-RepoRoot
$MergerTrackers    = Normalize-TrackerList $MergerTrackers
$MediationTrackers = Normalize-TrackerList $MediationTrackers

$rows = New-Object System.Collections.Generic.List[object]

function Add-ScopeRows {
  param([string]$Scope, [string[]]$Trackers)

  foreach ($t in $Trackers) {
    $landingPath = Get-LandingPath -RepoRoot $repoRoot -Scope $Scope -Tracker $t

    if (Test-Path $landingPath) {
      $html = Get-Content -Raw -Path $landingPath
      $issues = Audit-Landing $html
      $latest = Get-LatestWeeklyInfo $html

      [void]$rows.Add([pscustomobject]@{
        Scope=$Scope; Tracker=$t; PageType="landing"; Date="";
        RelPath=(RelPath $repoRoot $landingPath);
        Eyebrow=(Get-Text $html '(?is)<p[^>]*class="[^"]*\bcs-report__eyebrow\b[^"]*"[^>]*>(.*?)</p>');
        Subtitle=(Get-Text $html '(?is)<p[^>]*class="[^"]*\bcs-report__subtitle\b[^"]*"[^>]*>(.*?)</p>');
        LatestWeeklyFormat=$latest.LinkTextFormat;
        LatestWeeklyNewestFirst=$latest.NewestFirst;
        LatestWeeklySample=$latest.Sample;
        IssueCount=$issues.Count; Issues=($issues -join ";")
      }) | Out-Null
    } else {
      [void]$rows.Add([pscustomobject]@{
        Scope=$Scope; Tracker=$t; PageType="landing"; Date="";
        RelPath=(RelPath $repoRoot $landingPath);
        Eyebrow=""; Subtitle="";
        LatestWeeklyFormat="MissingLanding";
        LatestWeeklyNewestFirst=$true;
        LatestWeeklySample="";
        IssueCount=1; Issues="MissingLandingPage"
      }) | Out-Null
    }

    foreach ($w in (Get-WeeklyPages -RepoRoot $repoRoot -Scope $Scope -Tracker $t)) {
      $html = Get-Content -Raw -Path $w.Path
      $issues = Audit-Weekly -Html $html -Scope $Scope -Date $w.Date
      $subtitle = Get-Text $html '(?is)<p[^>]*class="[^"]*\bcs-report__subtitle\b[^"]*"[^>]*>(.*?)</p>'

      [void]$rows.Add([pscustomobject]@{
        Scope=$Scope; Tracker=$t; PageType="weekly"; Date=$w.Date;
        RelPath=(RelPath $repoRoot $w.Path);
        Eyebrow=(Get-Text $html '(?is)<p[^>]*class="[^"]*\bcs-report__eyebrow\b[^"]*"[^>]*>(.*?)</p>');
        Subtitle=$subtitle;
        WeeklySubtitleFormat=(Get-WeeklySubtitleFormat -Subtitle $subtitle -Date $w.Date);
        LatestWeeklyFormat=""; LatestWeeklyNewestFirst=$true; LatestWeeklySample="";
        IssueCount=$issues.Count; Issues=($issues -join ";")
      }) | Out-Null
    }
  }
}

Add-ScopeRows -Scope "merger-integration" -Trackers $MergerTrackers
Add-ScopeRows -Scope "mediation"         -Trackers $MediationTrackers

$all = $rows | Sort-Object Scope, Tracker, PageType, Date
$bad = $all | Where-Object { [int]$_.IssueCount -gt 0 }

Write-Host ""
Write-Host ("Pages scanned: {0}" -f $all.Count)
Write-Host ("Pages with issues: {0}" -f $bad.Count)
Write-Host ""

Write-Host "=== Landing microcopy snapshot ==="
$all | Where-Object { $_.PageType -eq "landing" } |
  Sort-Object Scope, Tracker |
  Format-Table Scope, Tracker, Eyebrow, Subtitle, LatestWeeklyFormat, LatestWeeklyNewestFirst, IssueCount -AutoSize -Wrap

Write-Host ""
Write-Host "=== Weekly microcopy snapshot ==="
$all | Where-Object { $_.PageType -eq "weekly" } |
  Sort-Object Scope, Tracker, Date |
  Format-Table Scope, Tracker, Date, WeeklySubtitleFormat, IssueCount, RelPath -AutoSize -Wrap

Write-Host ""
Write-Host "=== Files with issues (IssueCount > 0) ==="
if ($bad.Count -gt 0) {
  $bad | Format-Table Scope, Tracker, PageType, Date, IssueCount, RelPath, Issues -AutoSize -Wrap
} else {
  Write-Host "OK"
}

if ($OutCsv) {
  $csvPath = $OutCsv
  if (-not [IO.Path]::IsPathRooted($csvPath)) { $csvPath = Join-Path $repoRoot $OutCsv }
  $dir = Split-Path $csvPath -Parent
  if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $all | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Host ""
  Write-Host ("Wrote CSV: {0}" -f $csvPath)
}

if ($FailOnIssues -and $bad.Count -gt 0) { exit 1 }