<#
.SYNOPSIS
Builds Twinbar's release files from the repository.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-release.ps1 -OutDir dist [-NotesPath notes.md]

Writes into OutDir:
  twinbar-<version>.zip  twinbar.ps1, twinbar.cmd, README.md, LICENSE, CHANGELOG.md
  twinbar.json           a Scoop manifest for that zip
  SHA256SUMS             the SHA-256 of both
and, with -NotesPath, the release notes: the version's CHANGELOG section plus
how to install and check the download. The version comes from twinbar.ps1, and
CHANGELOG.md must have a section for it. The Release workflow runs this.
#>
param(
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [string] $NotesPath,
  [string] $Repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'sadrazkh/twinbar' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$source = [IO.File]::ReadAllText((Join-Path $repo 'twinbar.ps1'))
$version = ([regex]::Match($source, "TwinbarVersion = '([0-9]+\.[0-9]+\.[0-9]+)'")).Groups[1].Value
if (-not $version) { throw "couldn't find `$script:TwinbarVersion in twinbar.ps1" }

$changelog = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')).Replace("`r`n", "`n")
$section = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($version))\][^\n]*\n(.*?)(?=^## \[|\z)")
if (-not $section.Success) { throw "CHANGELOG.md has no section for $version" }
$changes = $section.Groups[1].Value.Trim()

$cmd = [IO.File]::ReadAllText((Join-Path $repo 'twinbar.cmd'))
if ($cmd -notmatch "`r`n" -or $cmd -match "[^`r]`n") { throw 'twinbar.cmd must have CRLF line endings (see .gitattributes)' }

if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).ProviderPath $OutDir }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
[void][IO.Directory]::CreateDirectory($OutDir)

# The zip, with the files at its root.
$zipName = "twinbar-$version.zip"
$zipPath = Join-Path $OutDir $zipName
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  foreach ($file in 'twinbar.ps1', 'twinbar.cmd', 'README.md', 'LICENSE', 'CHANGELOG.md') {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $repo $file), $file, 'Optimal')
  }
} finally {
  $archive.Dispose()
}
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

# A Scoop manifest: scoop install <its release download URL>
$manifest = [ordered]@{
  version     = $version
  description = 'A second, separately signed-in copy of your Electron apps on Windows, with its own taskbar button and icon.'
  homepage    = "https://github.com/$Repository"
  license     = 'MIT'
  url         = "https://github.com/$Repository/releases/download/v$version/$zipName"
  hash        = $zipHash
  bin         = 'twinbar.cmd'
  notes       = 'Run "twinbar install" to add the Twinbar window to the Start menu.'
  checkver    = 'github'
  autoupdate  = [ordered]@{ url = "https://github.com/$Repository/releases/download/v`$version/twinbar-`$version.zip" }
}
$manifestPath = Join-Path $OutDir 'twinbar.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4) + "`n", $utf8)

$sums = foreach ($name in $zipName, 'twinbar.json') {
  '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $OutDir $name) -Algorithm SHA256).Hash.ToLowerInvariant(), $name
}
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), (($sums -join "`n") + "`n"), $utf8)

if ($NotesPath) {
  $notes = @'
{{CHANGES}}

## Install

Download `{{ZIP}}` below, unpack it anywhere, and in that folder run:

```powershell
.\twinbar.cmd install -AddToPath
```

Twinbar is then in the Start menu, and `twinbar` works in any new terminal. With
[Scoop](https://scoop.sh) instead:

```powershell
scoop install https://github.com/{{REPO}}/releases/download/v{{VERSION}}/twinbar.json
```

## Check the download

`SHA256SUMS` has the SHA-256 of each file, and each file has signed build
provenance from this repository's Release workflow:

```powershell
(Get-FileHash .\{{ZIP}} -Algorithm SHA256).Hash
gh attestation verify .\{{ZIP}} -R {{REPO}}
```
'@
  $notes = $notes.Replace('{{CHANGES}}', $changes).Replace('{{ZIP}}', $zipName).Replace('{{REPO}}', $Repository).Replace('{{VERSION}}', $version)
  if (-not [IO.Path]::IsPathRooted($NotesPath)) { $NotesPath = Join-Path (Get-Location).ProviderPath $NotesPath }
  [IO.File]::WriteAllText($NotesPath, $notes.Replace("`r`n", "`n"), $utf8)
}

"Twinbar $version release files in $($OutDir):"
Get-ChildItem -LiteralPath $OutDir | ForEach-Object { '  {0,-24} {1,8:N0} bytes' -f $_.Name, $_.Length }
