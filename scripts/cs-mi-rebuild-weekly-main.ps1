param(
  [Parameter(Mandatory=$true)]
  [string]$TrackerSlug,

  [string]$TrackersRoot = "public\reports\merger-integration\trackers",

  [string[]]$OnlyDates,

  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$repo = (git rev-parse --show-toplevel).Trim()
Set-Location $repo
[System.Environment]::CurrentDirectory = $repo

$weeklyDir = Join-Path $repo (Join-Path $TrackersRoot "$TrackerSlug\weekly")
if (-not (Test-Path $weeklyDir)) {
  throw "Weekly directory not found: $weeklyDir"
}

$files = Get-ChildItem $weeklyDir -Filter "*.html" -File | Sort-Object Name
if ($OnlyDates -and $OnlyDates.Count -gt 0) {
  $files = $files | Where-Object { $OnlyDates -contains $_.BaseName }
}

Write-Host "Tracker:   $TrackerSlug"
Write-Host "WeeklyDir: $weeklyDir"
Write-Host "Files:     $($files.Count)"
Write-Host ""

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-TextNoBom([string]$path) {
  $t = [System.IO.File]::ReadAllText($path)
  if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { return $t.Substring(1) }
  return $t
}

$cp1252 = [System.Text.Encoding]::GetEncoding(1252)
$utf8   = [System.Text.Encoding]::UTF8

function Decode-Cp1252([byte[]]$bytes) {
  return $cp1252.GetString($bytes)
}

function New-MojibakeMap() {
  $m = [ordered]@{}

  # single-pass mojibake (UTF-8 bytes decoded as cp1252)
  $ldq1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0x9C))
  $rdq1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0x9D))
  $rsq1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0x99))
  $end1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0x93))
  $emd1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0x94))
  $ell1 = Decode-Cp1252 ([byte[]](0xE2,0x80,0xA6))

  $m[$ldq1] = '&ldquo;'
  $m[$rdq1] = '&rdquo;'
  $m[$rsq1] = '&rsquo;'
  $m[$end1] = '&ndash;'
  $m[$emd1] = '&mdash;'
  $m[$ell1] = '&hellip;'

  # double-pass variants: UTF-8 of the mojibake string decoded as cp1252
  $m[$cp1252.GetString($utf8.GetBytes($ldq1))] = '&ldquo;'
  $m[$cp1252.GetString($utf8.GetBytes($rdq1))] = '&rdquo;'
  $m[$cp1252.GetString($utf8.GetBytes($rsq1))] = '&rsquo;'
  $m[$cp1252.GetString($utf8.GetBytes($end1))] = '&ndash;'
  $m[$cp1252.GetString($utf8.GetBytes($emd1))] = '&mdash;'
  $m[$cp1252.GetString($utf8.GetBytes($ell1))] = '&hellip;'

  # "Â" artifact and NBSP cleanup (NBSP handled separately)
  $m[(Decode-Cp1252 ([byte[]](0xC2)))] = ''  # "Â"

  return $m
}

$script:MojibakeMap = New-MojibakeMap

function Fix-Mojibake([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }

  foreach ($k in $script:MojibakeMap.Keys) {
    $s = $s.Replace($k, $script:MojibakeMap[$k])
  }

  # Replace NBSP with regular space
  $s = $s.Replace([char]0x00A0, ' ')
  return $s
}

function Strip-Tags([string]$s) {
  return [regex]::Replace($s, '(?is)<[^>]+>', '')
}

function Norm-Key([string]$htmlFrag) {
  $t = Fix-Mojibake $htmlFrag
  $t = Strip-Tags $t
  $t = [regex]::Replace($t, '\s+', ' ').Trim().ToLowerInvariant()
  return $t
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

  return [regex]::Replace($html, '(?is)</head>', "$style`r`n</head>", 1)
}

function Add-Unique(
  [System.Collections.Generic.List[string]]$bucket,
  [System.Collections.Generic.HashSet[string]]$seen,
  [string]$item
) {
  $clean = (Fix-Mojibake $item).Trim()
  if ($clean -eq '') { return }

  $key = Norm-Key $clean
  if (-not $seen.Contains($key)) {
    $seen.Add($key) | Out-Null
    $bucket.Add($clean) | Out-Null
  }
}

function Split-DashboardItem([string]$liInner) {
  $s = (Fix-Mojibake $liInner).Trim()

  $strong = ''
  $rest = $s

  $m = [regex]::Match($s, '(?is)^(?<strong>\s*<strong\b[^>]*>.*?</strong>)(?<rest>.*)$')
  if ($m.Success) {
    $strong = $m.Groups['strong'].Value.Trim()
    $rest = $m.Groups['rest'].Value
  }

  $rest = [regex]::Replace($rest, '\s+', ' ').Trim()

  $tw = $rest
  $wn = ''

  $m2 = [regex]::Match($rest, '(?is)(?i)This\s+week:\s*(?<tw>.*?)(?:(?i)Watch\s+next:\s*(?<wn>.*))?$')
  if ($m2.Success) {
    $tw = $m2.Groups['tw'].Value.Trim()
    $wn = $m2.Groups['wn'].Value.Trim()
  }

  # minimal mechanical "full sentence" improvement
  if ($tw -match '^(?i)No material change observed\b') {
    $tw = ($tw -replace '^(?i)No material change observed', 'No material change was observed')
  }
  if ($tw -ne '' -and $tw -notmatch '[\.\!\?]$') { $tw += '.' }

  $cleanDash = ''
  if ($strong -ne '' -and $tw -ne '') { $cleanDash = "$strong $tw" }
  elseif ($tw -ne '') { $cleanDash = $tw }
  elseif ($strong -ne '') { $cleanDash = $strong }

  $watch = ''
  if ($wn -ne '') {
    if ($wn -notmatch '[\.\!\?]$') { $wn += '.' }
    $watch = if ($strong -ne '') { "$strong $wn" } else { $wn }
  }

  return [pscustomobject]@{ Clean = $cleanDash.Trim(); Watch = $watch.Trim() }
}

function Indent-Fragment([string]$frag, [string]$indent) {
  $lines = $frag -split "\r?\n"
  return (($lines | ForEach-Object {
    $ln = $_.Trim()
    if ($ln -eq '') { '' } else { $indent + $ln }
  }) -join "`r`n")
}

function New-CanonicalSection([string]$id, [string]$title, [System.Collections.Generic.List[string]]$items) {
  $sb = New-Object System.Text.StringBuilder

  [void]$sb.AppendLine("      <section id=""$id"" class=""cs-report__section"">")
  [void]$sb.AppendLine("        <h2 class=""cs-report__section-title"">$title</h2>")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("        <ul class=""cs-report__list"">")

  foreach ($it in $items) {
    [void]$sb.AppendLine("          <li class=""cs-report__list-item"">")
    [void]$sb.AppendLine((Indent-Fragment $it "            "))
    [void]$sb.AppendLine("          </li>")
  }

  [void]$sb.AppendLine("        </ul>")
  [void]$sb.AppendLine("      </section>")

  return $sb.ToString().TrimEnd()
}

$rxMain     = [regex]::new('(?is)(?<open><main\b[^>]*\bclass\s*=\s*"cs-report__main"[^>]*>)(?<inner>.*?)(?<close></main>)')
$rxH2Blocks = [regex]::new('(?is)<h2\b[^>]*\bcs-report__section-title\b[^>]*>\s*(?<title>.*?)\s*</h2>(?<content>.*?)(?=(<h2\b[^>]*\bcs-report__section-title\b[^>]*>|\z))')

$changed = 0
$flagged = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
  $html = Read-TextNoBom $f.FullName
  $before = $html

  if ($html -match '(?is)<main\s+class="cs-report__main">\s*</main>') {
    $flagged.Add("EMPTY <main> (skipped): $($f.Name)") | Out-Null
    continue
  }

  $html = Ensure-IndentStyle $html

  $mMain = $rxMain.Match($html)
  if (-not $mMain.Success) {
    $flagged.Add("NO <main> MATCH (skipped): $($f.Name)") | Out-Null
    continue
  }

  $inner = $mMain.Groups['inner'].Value

  $status = New-Object System.Collections.Generic.List[string]
  $dash   = New-Object System.Collections.Generic.List[string]
  $watch  = New-Object System.Collections.Generic.List[string]
  $refs   = New-Object System.Collections.Generic.List[string]

  $seenStatus = New-Object System.Collections.Generic.HashSet[string]
  $seenDash   = New-Object System.Collections.Generic.HashSet[string]
  $seenWatch  = New-Object System.Collections.Generic.HashSet[string]
  $seenRefs   = New-Object System.Collections.Generic.HashSet[string]

  $blocks = $rxH2Blocks.Matches($inner)

  foreach ($b in $blocks) {
    $title = Fix-Mojibake (Strip-Tags $b.Groups['title'].Value)
    $title = [regex]::Replace($title, '\s+', ' ').Trim()

    $bucket = 'status'
    switch -Regex ($title) {
      '^(?i)Status\s+Summary$'            { $bucket = 'status'; break }
      '^(?i)Status\s+This\s+Week$'        { $bucket = 'status'; break }
      '^(?i)Integration\s+Signals$'       { $bucket = 'status'; break }
      '^(?i)Integration\s+Dashboard$'     { $bucket = 'dash';   break }
      '^(?i)CrewSignal\s+Watch\s+Points$' { $bucket = 'watch';  break }
      '^(?i)CrewSignal\s+Assessment$'     { $bucket = 'watch';  break }
      '^(?i)Process\s+Signals$'           { $bucket = 'watch';  break }
      '^(?i)Notable\s+Public\s+References$' { $bucket = 'refs'; break }
      default { $bucket = 'status' }
    }

    $content = $b.Groups['content'].Value

    $liMatches = [regex]::Matches($content, '(?is)<li\b[^>]*>(?<li>.*?)</li>')
    if ($liMatches.Count -gt 0) {
      foreach ($lm in $liMatches) {
        $liInner = $lm.Groups['li'].Value

        if ($bucket -eq 'dash') {
          $split = Split-DashboardItem $liInner
          if ($split.Clean -ne '') { Add-Unique $dash  $seenDash  $split.Clean }
          if ($split.Watch -ne '') { Add-Unique $watch $seenWatch $split.Watch }
        }
        elseif ($bucket -eq 'refs') {
          Add-Unique $refs $seenRefs $liInner
        }
        elseif ($bucket -eq 'watch') {
          Add-Unique $watch $seenWatch $liInner
        }
        else {
          Add-Unique $status $seenStatus $liInner
        }
      }
      continue
    }

    $pMatches = [regex]::Matches($content, '(?is)<p\b[^>]*>(?<p>.*?)</p>')
    if ($pMatches.Count -gt 0) {
      foreach ($pm in $pMatches) {
        $pInner = $pm.Groups['p'].Value
        if ($bucket -eq 'refs')   { Add-Unique $refs   $seenRefs   $pInner }
        elseif ($bucket -eq 'watch') { Add-Unique $watch $seenWatch $pInner }
        elseif ($bucket -eq 'dash')  { Add-Unique $dash  $seenDash  $pInner }
        else { Add-Unique $status $seenStatus $pInner }
      }
    }
  }

  if ($status.Count -eq 0 -or $dash.Count -eq 0 -or $watch.Count -eq 0 -or $refs.Count -eq 0) {
    $flagged.Add("REFUSED (empty bucket): $($f.Name) | status=$($status.Count) dash=$($dash.Count) watch=$($watch.Count) refs=$($refs.Count)") | Out-Null
    continue
  }

  $rebuilt = @()
  $rebuilt += (New-CanonicalSection "status-this-week" "Status Summary" $status)
  $rebuilt += ""
  $rebuilt += (New-CanonicalSection "integration-dashboard" "Integration Dashboard" $dash)
  $rebuilt += ""
  $rebuilt += (New-CanonicalSection "crewsignal-assessment" "CrewSignal Watch Points" $watch)
  $rebuilt += ""
  $rebuilt += (New-CanonicalSection "notable-public-references" "Notable Public References" $refs)

  $newInner = "`r`n" + ($rebuilt -join "`r`n") + "`r`n    "
  $html = $rxMain.Replace($html, '${open}' + $newInner + '${close}', 1)

  $html = Fix-Mojibake $html
  $html = [regex]::Replace($html, "(\r?\n){3,}", "`r`n`r`n")

  if ($html -match '(?is)<main\s+class="cs-report__main">\s*</main>') {
    $flagged.Add("REFUSED (empty <main> after rebuild): $($f.Name)") | Out-Null
    continue
  }

  if ($html -ne $before) {
    $changed++
    if (-not $WhatIf) {
      [System.IO.File]::WriteAllText($f.FullName, $html, $utf8NoBom)
    }
  }
}

Write-Host "Changed files: $changed"

if ($flagged.Count -gt 0) {
  Write-Host ""
  Write-Host "Flagged:"
  $flagged | ForEach-Object { Write-Host " - $_" }
}

if ($WhatIf) {
  Write-Host ""
  Write-Host "NOTE: -WhatIf used. No files were modified."
}
