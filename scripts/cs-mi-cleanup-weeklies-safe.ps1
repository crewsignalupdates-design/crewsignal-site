param(
  [Parameter(Mandatory=$true)]
  [string]$TrackerSlug,

  [string]$TrackersRoot = "public\reports\merger-integration\trackers",

  [switch]$WhatIf
)

$repo = (git rev-parse --show-toplevel).Trim()
Set-Location $repo
[System.Environment]::CurrentDirectory = $repo

$weeklyDir = Join-Path $repo (Join-Path $TrackersRoot "$TrackerSlug\weekly")
if (-not (Test-Path $weeklyDir)) {
  throw "Weekly directory not found: $weeklyDir"
}

$files = Get-ChildItem $weeklyDir -Filter "*.html" -File | Sort-Object Name
Write-Host "Tracker:  $TrackerSlug"
Write-Host "WeeklyDir: $weeklyDir"
Write-Host "Files:    $($files.Count)"
Write-Host ""

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-DateInHtml([string]$html) {
  $m = [regex]::Match($html, '(?is)Week ending\s+(\d{4}\.\d{2}\.\d{2})')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Is-EmptyMain([string]$html) {
  return ($html -match '(?is)<main\s+class="cs-report__main">\s*</main>')
}

function Ensure-IndentStyle([string]$html) {
  if ($html -match '\.cs-report__section\s*>\s*\.cs-report__list') { return $html }

  $style = @"
    <style>
      .cs-report__section > .cs-report__list {
        margin: 0.75rem 0 0 1rem;
        padding-left: 1.25rem;
      }
    </style>
"@

  return ($html -replace '(?is)</head>', "$style`r`n  </head>")
}

function Normalize-SectionTitles([string]$html) {
  # Only title text changes; content untouched.
  $html = $html -replace '(?is)<h2\s+class="cs-report__section-title">\s*Status\s+This\s+Week\s*</h2>',
                         '<h2 class="cs-report__section-title">Status Summary</h2>'

  $html = $html -replace '(?is)<h2\s+class="cs-report__section-title">\s*Integration\s+dashboard\s*</h2>',
                         '<h2 class="cs-report__section-title">Integration Dashboard</h2>'

  $html = $html -replace '(?is)<h2\s+class="cs-report__section-title">\s*CrewSignal\s+Assessment\s*</h2>',
                         '<h2 class="cs-report__section-title">CrewSignal Watch Points</h2>'

  return $html
}

function Remove-SectionFromMainById([string]$html, [string]$sectionId) {
  $mainOpen = '<main class="cs-report__main">'
  $mainClose = '</main>'

  $iMain = $html.IndexOf($mainOpen)
  $iEnd  = $html.IndexOf($mainClose)
  if ($iMain -lt 0 -or $iEnd -lt 0 -or $iEnd -le $iMain) { return $html }

  $before = $html.Substring(0, $iMain)
  $main   = $html.Substring($iMain, $iEnd - $iMain)
  $after  = $html.Substring($iEnd)

  $rx = [regex]::new("(?is)\s*<section\b[^>]*\bid\s*=\s*`"$sectionId`"[^>]*>.*?</section>\s*")
  if ($rx.IsMatch($main)) {
    $main = $rx.Replace($main, "`r`n")
  }

  return ($before + $main + $after)
}

function Remove-SectionFromMainByH2([string]$html, [string]$h2Text) {
  $mainOpen = '<main class="cs-report__main">'
  $mainClose = '</main>'

  $iMain = $html.IndexOf($mainOpen)
  $iEnd  = $html.IndexOf($mainClose)
  if ($iMain -lt 0 -or $iEnd -lt 0 -or $iEnd -le $iMain) { return $html }

  $before = $html.Substring(0, $iMain)
  $main   = $html.Substring($iMain, $iEnd - $iMain)
  $after  = $html.Substring($iEnd)

  # Find an <h2> with cs-report__section-title containing exactly the heading text
  $rxH2 = [regex]::new("(?is)<h2\b[^>]*class\s*=\s*`"[^`"]*\bcs-report__section-title\b[^`"]*`"[^>]*>\s*$([regex]::Escape($h2Text))\s*</h2>")
  $m = $rxH2.Match($main)
  if (-not $m.Success) { return $html }

  $idx = $m.Index
  $sStart = $main.LastIndexOf("<section", $idx)
  if ($sStart -lt 0) { return $html }

  $sEnd = $main.IndexOf("</section>", $idx)
  if ($sEnd -lt 0) { return $html }
  $sEnd = $sEnd + "</section>".Length

  $main = $main.Remove($sStart, $sEnd - $sStart)
  return ($before + $main + $after)
}

function Find-GoodCommit([string]$repoRelPath, [string]$expectedDate) {
  $commits = git log --follow --format="%H" -- $repoRelPath
  foreach ($c in $commits) {
    $content = git show "${c}:$repoRelPath" 2>$null
    if (-not $content) { continue }

    $hasCorrectDate = ($content -match [regex]::Escape("Week ending $expectedDate"))
    $hasBody = ($content -match 'class="cs-report__section"') -or ($content -match 'id="status-this-week"')

    if ($hasCorrectDate -and $hasBody) { return $c }
  }
  return $null
}

$restored = 0
$edited = 0
$flagged = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
  $expected = $f.BaseName  # should be YYYY.MM.DD
  $repoRel  = ($f.FullName.Substring($repo.Length + 1) -replace '\\','/')

  $html = [System.IO.File]::ReadAllText($f.FullName)
  $dateIn = Get-DateInHtml $html
  $emptyMain = Is-EmptyMain $html

  $needsRestore = $emptyMain -or ($dateIn -and $dateIn -ne $expected)

  if ($needsRestore) {
    $good = Find-GoodCommit -repoRelPath $repoRel -expectedDate $expected
    if ($good) {
      Write-Host "Restore: $repoRel  <=  $good"
      if (-not $WhatIf) {
        git restore --source $good -- $repoRel | Out-Null
      }
      $restored++
      $html = [System.IO.File]::ReadAllText($f.FullName)
    } else {
      $flagged.Add("NO GOOD COMMIT: $repoRel (expected $expected)") | Out-Null
    }
  }

  $before = $html

  # Hub-only policy: remove contract link sections from weekly pages (safe: within <main> only)
  $html = Remove-SectionFromMainById $html "related-contract-architecture"
  $html = Remove-SectionFromMainById $html "contract-comparison"
  $html = Remove-SectionFromMainByH2 $html "Related Contract Architecture"
  $html = Remove-SectionFromMainByH2 $html "Contract Comparison"

  # Canonical headings + list indent helper
  $html = Normalize-SectionTitles $html
  $html = Ensure-IndentStyle $html

  # cleanup blank lines
  $html = [regex]::Replace($html, "(\r?\n){3,}", "`r`n`r`n")

  # Guardrail: never write a blank <main>
  if (Is-EmptyMain $html) {
    $flagged.Add("REFUSED (empty <main>): $repoRel") | Out-Null
    continue
  }

  if ($html -ne $before) {
    if (-not $WhatIf) {
      [System.IO.File]::WriteAllText($f.FullName, $html, $utf8NoBom)
    }
    $edited++
  }
}

Write-Host ""
Write-Host "Restored files: $restored"
Write-Host "Edited files:   $edited"

if ($flagged.Count -gt 0) {
  Write-Host ""
  Write-Host "Flagged items:"
  $flagged | ForEach-Object { Write-Host " - $_" }
}

if ($WhatIf) {
  Write-Host ""
  Write-Host "NOTE: -WhatIf used. No files were modified."
}
