<#
.SYNOPSIS
Builds Twinbar's release files from the repository.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-release.ps1 -OutDir dist [-NotesPath notes.md] [-Installer]

Writes into OutDir:
  Twinbar-Setup-<version>.exe  the Windows installer (with -Installer; needs Inno Setup 6)
  twinbar-<version>.zip        twinbar.ps1, twinbar.cmd, README.md, LICENSE, CHANGELOG.md
  twinbar.json                 a Scoop manifest for that zip
  SHA256SUMS                   the SHA-256 of each
and, with -NotesPath, the release notes (tools\release-notes.ps1: the version's
docs\releases notes, or its CHANGELOG section, plus how to install and check
the download). The version comes from twinbar.ps1, and
CHANGELOG.md must have a section for it. The CI and Release workflows run this.
#>
param(
  [Parameter(Mandatory = $true)] [string] $OutDir,
  [string] $NotesPath,
  [switch] $Installer,
  [string] $Iscc = (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  [string] $Repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'sadrazkh/twinbar' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runs a program and returns its exit code and everything it printed. Only the
# exit code says whether it failed: Windows PowerShell would otherwise turn any
# line on stderr (a warning, say) into an error.
function Invoke-Native([string] $Program, [string[]] $Arguments) {
  $ErrorActionPreference = 'Continue'
  $lines = & $Program @Arguments 2>&1 | ForEach-Object { [string]$_ }
  return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($lines) -join "`n") }
}

# On GitHub, a failure becomes an annotation on the run, readable without the log.
trap {
  if ($env:GITHUB_ACTIONS -eq 'true') {
    $message = ($_.Exception.Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')
    Write-Host "::error title=make-release failed::$message"
  }
  break
}

$repo = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$source = [IO.File]::ReadAllText((Join-Path $repo 'twinbar.ps1'))
$version = ([regex]::Match($source, "TwinbarVersion = '([0-9]+\.[0-9]+\.[0-9]+)'")).Groups[1].Value
if (-not $version) { throw "couldn't find `$script:TwinbarVersion in twinbar.ps1" }

$changelog = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')).Replace("`r`n", "`n")
$section = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($version))\][^\n]*\n(.*?)(?=^## \[|\z)")
if (-not $section.Success) { throw "CHANGELOG.md has no section for $version" }

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

$names = @($zipName, 'twinbar.json')
$setupName = "Twinbar-Setup-$version.exe"
if ($Installer) {
  if (-not (Test-Path -LiteralPath $Iscc)) { throw "Inno Setup 6 isn't at $Iscc (give -Iscc, or install it from https://jrsoftware.org)" }
  # Twinbar's own icon for the installer, drawn by twinbar.ps1 itself.
  $work = Join-Path ([IO.Path]::GetTempPath()) ('twinbar-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void][IO.Directory]::CreateDirectory($work)
  try {
    $iconPath = Join-Path $work 'twinbar.ico'
    $draw = "& { . '$((Join-Path $repo 'twinbar.ps1').Replace("'", "''"))'; Initialize-Interop; [TwinbarInterop.IconMaker]::BuildAppIcon('$($iconPath.Replace("'", "''"))') }"
    $drawn = Invoke-Native (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $draw)
    if ($drawn.Code -ne 0 -or -not (Test-Path -LiteralPath $iconPath)) { throw "couldn't draw Twinbar's icon:`n$($drawn.Output)" }
    $compiled = Invoke-Native $Iscc @("/DAppVersion=$version", "/DIconFile=$iconPath", "/O$OutDir", (Join-Path $repo 'installer\twinbar.iss'))
    $compiled.Output.TrimEnd() -split "`n" | ForEach-Object { "  iscc: $($_.TrimEnd())" }
    if ($compiled.Code -ne 0) {
      $errors = @($compiled.Output -split "`n" | Where-Object { $_ -match 'Error|error' }) -join ' '
      throw "Inno Setup failed (exit $($compiled.Code)): $errors"
    }
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path -LiteralPath (Join-Path $OutDir $setupName))) { throw "Inno Setup made no $setupName" }
  $names = @($setupName) + $names
}

$sums = foreach ($name in $names) {
  '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $OutDir $name) -Algorithm SHA256).Hash.ToLowerInvariant(), $name
}
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), (($sums -join "`n") + "`n"), $utf8)

if ($NotesPath) {
  & (Join-Path $PSScriptRoot 'release-notes.ps1') -Version $version -OutPath $NotesPath -Repository $Repository
}

"Twinbar $version release files in $($OutDir):"
Get-ChildItem -LiteralPath $OutDir | ForEach-Object { '  {0,-24} {1,8:N0} bytes' -f $_.Name, $_.Length }
