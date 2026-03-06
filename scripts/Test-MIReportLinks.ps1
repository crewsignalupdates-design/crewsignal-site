param(
  [Parameter(Mandatory = $true)]
  [string]$ScanDir,

  [ValidateSet("Local","Http","Both")]
  [string]$Mode = "Local",

  [string]$BaseUrl = "",
  [string]$OutFile = ""
)

$repoRoot = (git rev-parse --show-toplevel).Trim()
$scanDirPath = (Resolve-Path $ScanDir -ErrorAction Stop).Path

function Find-AncestorDir([string]$start, [string]$leafName) {
  $d = $start
  while ($true) {
    if ((Split-Path $d -Leaf) -ieq $leafName) { return $d }
    $p = Split-Path $d -Parent
    if ([string]::IsNullOrWhiteSpace($p) -or $p -eq $d) { break }
    $d = $p
  }
  return $null
}

# This is the LOCAL folder that corresponds to URL root "/reports/"
$reportsRootLocal = Find-AncestorDir $scanDirPath "reports"

if (-not $reportsRootLocal) {
  # Fallback if your scan dir isn't under a folder literally named "reports"
  $fallback = Join-Path $repoRoot "reports"
  if (Test-Path $fallback) { $reportsRootLocal = (Resolve-Path $fallback).Path }
}

Write-Host "Repo root:       $repoRoot"
Write-Host "Scan directory:  $scanDirPath"
Write-Host "Reports root:    $reportsRootLocal"

function Get-LinksFromHtml([string]$raw) {
  $matches = [regex]::Matches($raw, '(?is)\b(?:href|src)\s*=\s*(?:"([^"]+)"|''([^'']+)'')')
  foreach ($m in $matches) {
    if ($m.Groups[1].Success) { $m.Groups[1].Value.Trim() } else { $m.Groups[2].Value.Trim() }
  }
}

function Strip-QueryAndHash([string]$url) { ($url -split '[\?#]', 2)[0] }

function Is-Skippable([string]$link) {
  $l = $link.ToLowerInvariant()
  return (
    $l.StartsWith("#") -or
    $l.StartsWith("mailto:") -or
    $l.StartsWith("tel:") -or
    $l.StartsWith("javascript:") -or
    $l.StartsWith("/assets/") -or
    $l.StartsWith("/favicon") -or
    $l.StartsWith("/robots.txt")
  )
}

function Resolve-LocalTarget([string]$link, [string]$fileDir) {
  $clean = Strip-QueryAndHash $link
  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

  # External URL? skip local resolution
  if ($clean -match '^(?i)https?://') { return $null }

  # Absolute internal links:
  if ($clean.StartsWith("/reports/")) {
    if (-not $reportsRootLocal) { return $null }
    $relative = $clean.Substring("/reports/".Length) -replace '/', '\'
    $candidate = Join-Path $reportsRootLocal $relative
  }
  elseif ($clean.StartsWith("/")) {
    # Skip other absolute links (assets handled above)
    return $null
  }
  else {
    # Relative link
    $candidate = Join-Path $fileDir ($clean -replace '/', '\')
  }

  $ext = [System.IO.Path]::GetExtension($clean)

  if ($ext -ieq ".html") { return $candidate }

  $asDirIndex = Join-Path $candidate "index.html"
  $asHtml = $candidate + ".html"

  if (Test-Path $candidate) { return $candidate }
  if (Test-Path $asDirIndex) { return $asDirIndex }
  if (Test-Path $asHtml) { return $asHtml }

  return $asDirIndex
}

if (($Mode -eq "Http" -or $Mode -eq "Both") -and [string]::IsNullOrWhiteSpace($BaseUrl)) {
  throw "BaseUrl is required for Mode=Http or Mode=Both."
}
if ($BaseUrl) { $BaseUrl = $BaseUrl.TrimEnd("/") }

$useBasicParsing = $PSVersionTable.PSVersion.Major -lt 6

function Get-HttpStatus([string]$url) {
  try {
    if ($useBasicParsing) { (Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20).StatusCode }
    else { (Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 20).StatusCode }
  } catch {
    try {
      if ($useBasicParsing) { (Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 20).StatusCode }
      else { (Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 20).StatusCode }
    } catch { -1 }
  }
}

$files = Get-ChildItem $scanDirPath -Recurse -Filter *.html

$results = New-Object System.Collections.Generic.List[object]

foreach ($f in $files) {
  $raw = Get-Content $f.FullName -Raw
  $links = Get-LinksFromHtml $raw | Where-Object { $_ -and -not (Is-Skippable $_) } | Select-Object -Unique
  $fileDir = Split-Path $f.FullName -Parent

  foreach ($link in $links) {
    $clean = Strip-QueryAndHash $link

    if ($Mode -eq "Local" -or $Mode -eq "Both") {
      # Only check /reports/* and relative links locally
      if ($clean.StartsWith("/reports/") -or (-not $clean.StartsWith("/"))) {
        $target = Resolve-LocalTarget $clean $fileDir
        $exists = $false
        if ($target) { $exists = Test-Path $target }

        $results.Add([pscustomobject]@{
          Check  = "Local"
          File   = $f.FullName
          Link   = $link
          Target = $target
          Status = $(if ($exists) { "OK" } else { "MISSING" })
        })
      }
    }

    if ($Mode -eq "Http" -or $Mode -eq "Both") {
      if ($clean.StartsWith("/reports/")) {
        $url = "$BaseUrl$clean"
        $code = Get-HttpStatus $url
        $results.Add([pscustomobject]@{
          Check  = "HTTP"
          File   = $f.FullName
          Link   = $link
          Target = $url
          Status = $(if ($code -ge 200 -and $code -lt 400) { "OK" } else { "$code" })
        })
      }
    }
  }
}

$broken = $results | Where-Object { $_.Status -ne "OK" }
$broken | Sort-Object Check, File | Format-Table -AutoSize

if ($OutFile) {
  $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutFile
  Write-Host "Wrote: $OutFile"
}

if ($broken.Count -gt 0) { exit 1 } else { exit 0 }
