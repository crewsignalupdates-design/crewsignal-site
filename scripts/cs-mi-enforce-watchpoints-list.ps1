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
Write-Host "Tracker:   $TrackerSlug"
Write-Host "WeeklyDir: $weeklyDir"
Write-Host "Files:     $($files.Count)"
Write-Host ""

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Is-EmptyMain([string]$html) {
  return ($html -match '(?is)<main\s+class="cs-report__main">\s*</main>')
}

function Ensure-LiClass([string]$html) {
  # Add list-item class where missing
  return [regex]::Replace($html, '(?i)<li(?![^>]*\bclass=)', '<li class="cs-report__list-item"')
}

function Ensure-ListInCrewSignalSection([string]$html) {
  $rxSection = [regex]::new('(?is)(<section\b[^>]*\bid\s*=\s*"crewsignal-assessment"[^>]*>)(.*?)(</section>)')
  if (-not $rxSection.IsMatch($html)) { return $html }

  return $rxSection.Replace($html, {
    param($m)

    $open  = $m.Groups[1].Value
    $inner = $m.Groups[2].Value
    $close = $m.Groups[3].Value

    # If a cs-report__list already exists, just ensure li classes and return.
    if ($inner -match '(?is)<ul\b[^>]*\bcs-report__list\b') {
      $inner = Ensure-LiClass $inner
      return $open + $inner + $close
    }

    # Split header (<h2 ...>...</h2>) from body.
    $rxH2 = [regex]::new('(?is)(?<head>.*?<h2\b[^>]*\bcs-report__section-title\b[^>]*>.*?</h2>)(?<body>.*)$')
    $mh2 = $rxH2.Match($inner)

    if (-not $mh2.Success) {
      # Fallback: wrap entire section content after opening tag
      $body = $inner.Trim()
      if ($body -eq "") { return $open + $inner + $close }

      $wrapped = "`r`n`r`n<ul class=`"cs-report__list`">`r`n  <li class=`"cs-report__list-item`">`r`n    $body`r`n  </li>`r`n</ul>`r`n"
      return $open + $wrapped + $close
    }

    $head = $mh2.Groups["head"].Value
    $body = $mh2.Groups["body"].Value.Trim()

    if ($body -eq "") {
      # If there's no body, keep as-is (no content to preserve).
      return $open + $inner + $close
    }

    # Detect indentation from the <h2> line so we keep consistent formatting.
    $mIndent = [regex]::Match($head, '(?m)^(?<ind>\s*)<h2\b')
    $ind = if ($mIndent.Success) { $mIndent.Groups["ind"].Value } else { "      " }
    $indUl = $ind + "  "
    $indLi = $indUl + "  "
    $indTxt = $indLi + "  "

    # If body contains <p> blocks, convert each <p> to a bullet item.
    $pMatches = [regex]::Matches($body, '(?is)<p\b[^>]*>(?<t>.*?)</p>')
    $items = New-Object System.Collections.Generic.List[string]

    if ($pMatches.Count -gt 0) {
      foreach ($pm in $pMatches) {
        $t = $pm.Groups["t"].Value.Trim()
        if ($t -ne "") { $items.Add($t) | Out-Null }
      }

      $remainder = [regex]::Replace($body, '(?is)<p\b[^>]*>.*?</p>', '').Trim()
      if ($remainder -ne "") { $items.Add($remainder) | Out-Null }
    } else {
      # No <p> blocks: wrap the whole body as one bullet to preserve content exactly.
      $items.Add($body) | Out-Null
    }

    $list = "`r`n`r`n${indUl}<ul class=`"cs-report__list`">"
    foreach ($it in $items) {
      $list += "`r`n${indLi}<li class=`"cs-report__list-item`">"
      $list += "`r`n${indTxt}$it"
      $list += "`r`n${indLi}</li>"
    }
    $list += "`r`n${indUl}</ul>`r`n"

    return $open + $head + $list + $close
  })
}

$changed = 0
$flagged = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
  $html = [System.IO.File]::ReadAllText($f.FullName)
  $before = $html

  if (Is-EmptyMain $html) {
    $flagged.Add("EMPTY <main> (skipped): $($f.Name)") | Out-Null
    continue
  }

  $html = Ensure-ListInCrewSignalSection $html

  # Guardrail: refuse to write if main becomes empty (should never happen here)
  if (Is-EmptyMain $html) {
    $flagged.Add("REFUSED (empty <main>): $($f.Name)") | Out-Null
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
