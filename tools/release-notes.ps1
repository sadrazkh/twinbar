<#
.SYNOPSIS
Writes a Twinbar release's notes, or brings the notes of every published
release up to date.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\release-notes.ps1 -Version 0.9.0 -OutPath notes.md
  pwsh -NoProfile -File tools\release-notes.ps1 -Sync      (the Release workflow, with GH_TOKEN set)

A release's notes are docs\releases\v<version>.md (or, for a version without
one, its CHANGELOG.md section), followed by how to install that version and
check the download. -Sync compares them with every release on GitHub that has
such a file and updates those that differ (it needs the gh command).
This file is plain ASCII, like the scripts; the notes themselves are UTF-8.
#>
param(
  [string] $Version,
  [string] $OutPath,
  [switch] $Sync,
  [string] $Repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'sadrazkh/twinbar' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false

function Get-NotesBody([string] $V) {
  $file = Join-Path $repo "docs\releases\v$V.md"
  if (Test-Path -LiteralPath $file) { return [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Trim() }
  $changelog = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')).Replace("`r`n", "`n")
  $section = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($V))\][^\n]*\n(.*?)(?=^## \[|\z)")
  if (-not $section.Success) { throw "there are no notes for $($V), neither docs\releases\v$V.md nor a CHANGELOG.md section" }
  return $section.Groups[1].Value.Trim()
}

# The whole notes of a version: what's new, then how to install it and check it.
function Get-ReleaseNotes([string] $V) {
  $inbox = [char]::ConvertFromUtf32(0x1F4E5)
  $lock = [char]::ConvertFromUtf32(0x1F510)
  $setup = "Twinbar-Setup-$V.exe"
  $zip = "twinbar-$V.zip"
  $hasSetup = [version]$V -ge [version]'0.5.1'   # the installer came with 0.5.1
  $updatesItself = [version]$V -gt [version]'0.7.0' # 0.7.0 brought updates from inside Twinbar
  $text = New-Object System.Text.StringBuilder
  [void]$text.Append((Get-NotesBody $V)).Append("`n`n---`n`n## $inbox Install`n`n")
  if ($hasSetup) {
    [void]$text.Append("**New to Twinbar?** Download **``$setup``** below and run it. It installs Twinbar for you only,`n")
    [void]$text.Append("with no admin rights, puts **Twinbar** in the Start menu and opens it. It isn't code-signed yet,`n")
    [void]$text.Append("so Windows may say ""Windows protected your PC"": click **More info**, then **Run anyway**.`n")
    [void]$text.Append("Twinbar is then in Settings > Apps, where you can uninstall it; your profiles stay.`n`n")
  }
  if ($updatesItself) {
    [void]$text.Append("**Already have Twinbar 0.7.0 or later?** It offers this update itself: click **Update to $V**`n")
    [void]$text.Append("at the bottom right of its window, or run ``twinbar update``.`n`n")
  }
  [void]$text.Append($(if ($hasSetup) { 'Or download' } else { 'Download' }))
  [void]$text.Append(" ``$zip``, unpack it anywhere, and in that folder run ``.\twinbar.cmd install -AddToPath``.`n")
  [void]$text.Append("Or, with [Scoop](https://scoop.sh):`n`n")
  [void]$text.Append("``````powershell`nscoop install https://github.com/$Repository/releases/download/v$V/twinbar.json`n```````n`n")
  [void]$text.Append("## $lock Check the download`n`n")
  [void]$text.Append("``SHA256SUMS`` has the SHA-256 of each file, and each file has signed build provenance from this`n")
  [void]$text.Append("repository's Release workflow:`n`n")
  $file = if ($hasSetup) { $setup } else { $zip }
  [void]$text.Append("``````powershell`n(Get-FileHash .\$file -Algorithm SHA256).Hash`ngh attestation verify .\$file -R $Repository`n```````n")
  return $text.ToString()
}

if ($Sync) {
  # gh speaks UTF-8; the notes have emoji in them.
  [Console]::OutputEncoding = $utf8
  $ErrorActionPreference = 'Continue'
  $failed = 0
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'docs\releases') -Filter 'v*.md' | Sort-Object Name)) {
    $v = $f.BaseName.Substring(1)
    $current = @(& gh release view "v$v" --repo $Repository --json body --jq .body 2>$null)
    if ($LASTEXITCODE -ne 0) { "v$($v): not released yet"; continue }
    $wanted = Get-ReleaseNotes $v
    if (($current -join "`n").Replace("`r`n", "`n").Trim() -eq $wanted.Trim()) { "v$($v): up to date"; continue }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "twinbar-notes-$v.md"
    [IO.File]::WriteAllText($tmp, $wanted, $utf8)
    & gh release edit "v$v" --repo $Repository --notes-file $tmp
    if ($LASTEXITCODE -eq 0) { "v$($v): notes updated" } else { "v$($v): couldn't update the notes"; $failed++ }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
  if ($failed) { exit 1 }
  exit 0
}

if (-not $Version) { throw 'give -Version x.y.z (or -Sync)' }
$notes = Get-ReleaseNotes $Version
if ($OutPath) {
  if (-not [IO.Path]::IsPathRooted($OutPath)) { $OutPath = Join-Path (Get-Location).ProviderPath $OutPath }
  [IO.File]::WriteAllText($OutPath, $notes, $utf8)
} else {
  $notes
}
