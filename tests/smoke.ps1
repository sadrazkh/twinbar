<#
.SYNOPSIS
Twinbar tests: static checks, unit checks, and end-to-end checks with a fake Electron app.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -RealApp "C:\Program Files\Bruno\Bruno.exe" [-Launch]

Everything happens in a temporary folder: your real Start menu and profiles are
never touched. A few small test files end up in the Recycle Bin, because moving
things there is part of what is tested. With -Launch, the real app is started
once with an empty data folder and closed again.
#>
param(
  [string] $RealApp,
  [switch] $Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo 'twinbar.ps1'
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$root = Join-Path ([IO.Path]::GetTempPath()) ('twinbar test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$twHome = Join-Path $root 'home'
$menu = Join-Path $root 'start menu'
$pinned = Join-Path $root 'pinned'
$startMenu = Join-Path $root 'fake start menu'
# Store apps' data must live outside AppData; the temp folder usually is inside it.
$storeData = if ($root.StartsWith([Environment]::GetFolderPath('UserProfile') + '\AppData\', [StringComparison]::OrdinalIgnoreCase)) {
  Join-Path ([Environment]::GetFolderPath('UserProfile')) ('twinbar-test-' + (Split-Path -Leaf $root).Substring(13))
} else {
  Join-Path $root 'store data'
}
# Twinbar's jump list and "start with Windows" entry are per user, not per folder:
# the tests use their own, so yours aren't touched.
$testKey = (Split-Path -Leaf $root).Substring(13)
$jumpListId = "Twinbar.Test.$testKey"
$runKeyRoot = "HKCU:\Software\Twinbar tests\$testKey"
$runKey = "$runKeyRoot\Run"
$script:passed = 0
$script:failed = 0
$script:fakeBuilt = $null
$script:fakeTelegram = $null
$script:extraEnv = @{} # more environment variables for Invoke-Cli

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Section([string] $Title) {
  Write-Host ''
  Write-Host "== $Title"
}

function Assert-True([bool] $Condition, [string] $What, [string] $Detail = '') {
  if ($Condition) {
    $script:passed++
    Write-Host "  ok    $What"
  } else {
    $script:failed++
    Write-Host "  FAIL  $What" -ForegroundColor Red
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
    if ($env:GITHUB_ACTIONS -eq 'true') {
      # Shown on the workflow run's page and in the checks API.
      $message = ("$What. $Detail" -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')
      Write-Host "::error title=Twinbar test failed::$message"
    }
  }
}

function Assert-Equal($Expected, $Actual, [string] $What) {
  Assert-True ($Expected -eq $Actual) $What "expected '$Expected', got '$Actual'"
}

function Assert-Throws([scriptblock] $Block, [string] $Pattern, [string] $What) {
  $message = $null
  try { & $Block | Out-Null } catch { $message = $_.Exception.Message }
  Assert-True ($null -ne $message -and $message -match $Pattern) $What "message: $message"
}

function Assert-Cli($Result, [int] $Code, [string] $Pattern, [string] $What) {
  $text = $Result.Out + $Result.Err
  Assert-True ($Result.Code -eq $Code -and $text -match $Pattern) $What ("exit {0}; output: {1}" -f $Result.Code, $text.Trim())
}

function ConvertTo-ArgString([string] $Value) {
  if ($Value -and $Value -notmatch '[\s"]') { return $Value }
  $escaped = $Value -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

# Runs twinbar.ps1 (or another copy of it) in a fresh Windows PowerShell, with
# TWINBAR_HOME pointing at the test folder.
function Invoke-Cli([string[]] $Arguments, [string] $Script = $cli) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $powershellExe
  $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
  $psi.Arguments = (@($all | ForEach-Object { ConvertTo-ArgString $_ })) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['TWINBAR_HOME'] = $twHome
  $psi.EnvironmentVariables['TWINBAR_PINNED_DIR'] = $pinned
  $psi.EnvironmentVariables['TWINBAR_STORE_DATA'] = $storeData
  $psi.EnvironmentVariables['TWINBAR_SHORTCUT_DIR'] = $menu
  $psi.EnvironmentVariables['TWINBAR_START_MENU'] = $startMenu
  $psi.EnvironmentVariables['TWINBAR_JUMPLIST_ID'] = $jumpListId
  $psi.EnvironmentVariables['TWINBAR_RUN_KEY'] = $runKey
  foreach ($key in $script:extraEnv.Keys) { $psi.EnvironmentVariables[$key] = $script:extraEnv[$key] }
  $proc = [Diagnostics.Process]::Start($psi)
  $out = $proc.StandardOutput.ReadToEndAsync()
  $err = $proc.StandardError.ReadToEndAsync()
  if (-not $proc.WaitForExit(120000)) {
    $proc.Kill()
    throw "twinbar didn't finish: $($psi.Arguments)"
  }
  $proc.WaitForExit()
  [pscustomobject]@{ Code = $proc.ExitCode; Out = $out.Result; Err = $err.Result }
}

function Get-ListRows {
  $r = Invoke-Cli @('list', '-Json')
  if ($r.Code -ne 0) { throw "twinbar list failed: $($r.Err)" }
  $parsed = ConvertFrom-Json $r.Out
  return @($parsed | ForEach-Object { $_ })
}

function New-FakeExe([string] $Path) {
  if (-not $script:fakeBuilt) {
    $script:fakeBuilt = Join-Path $root 'build\FakeApp.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:fakeBuilt))
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeApp.cs'))
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $script:fakeBuilt -OutputType WindowsApplication -ReferencedAssemblies 'System.Windows.Forms'
  }
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
  Copy-Item -LiteralPath $script:fakeBuilt -Destination $Path
}

# A stand-in for Telegram Desktop: the fake app built as Telegram.exe with Telegram's
# product name, in a folder with an updater and an uninstaller next to it.
function New-FakeTelegram([string] $Dir) {
  if (-not $script:fakeTelegram) {
    $script:fakeTelegram = Join-Path $root 'build\Telegram.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:fakeTelegram))
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeApp.cs')).Replace('AssemblyProduct("Fake App")', 'AssemblyProduct("Telegram Desktop")').Replace('AssemblyTitle("Fake App")', 'AssemblyTitle("Telegram Desktop")')
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $script:fakeTelegram -OutputType WindowsApplication -ReferencedAssemblies 'System.Windows.Forms'
  }
  [void][IO.Directory]::CreateDirectory($Dir)
  Copy-Item -LiteralPath $script:fakeTelegram -Destination (Join-Path $Dir 'Telegram.exe')
  foreach ($other in 'Updater.exe', 'unins000.exe') { [IO.File]::WriteAllText((Join-Path $Dir $other), 'stand-in') }
}

function New-ElectronDir([string] $Dir, [string] $ExeName = 'FakeApp.exe') {
  New-FakeExe (Join-Path $Dir $ExeName)
  [void][IO.Directory]::CreateDirectory((Join-Path $Dir 'resources'))
  [IO.File]::WriteAllText((Join-Path $Dir 'resources\app.asar'), 'not really an asar')
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return [bool](& $Condition)
}

function Get-ProcessesFor([string] $DataDir) {
  $script:DataDirProcesses = $null # the dot-sourced script caches the process list
  @(Get-ProfileProcesses ([pscustomobject]@{ dataDir = $DataDir }))
}

# Launchers looking after a profile (their command line ends with the profile id).
function Get-LaunchersFor([string] $Id) {
  @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'twinbar-launcher.exe'" |
      Where-Object { $_.CommandLine -match ('\s' + [regex]::Escape($Id) + '\s*$') })
}

# Internet connections (not to this computer) that a profile's app processes have
# open, collected for a while: "process -> address:port".
function Get-OutsideConnections([string] $DataDir, [int] $Seconds) {
  $seen = @{}
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $script:DataDirProcesses = $null
    $ids = @(Get-ProfileProcesses ([pscustomobject]@{ dataDir = $DataDir }) | ForEach-Object { [int]$_.ProcessId })
    if ($ids.Count) {
      foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess -and $_.State -in 'Established', 'SynSent' })) {
        if ($c.RemoteAddress -notin '127.0.0.1', '::1', '::ffff:127.0.0.1', '0.0.0.0', '::') {
          $seen["$($c.OwningProcess) -> $($c.RemoteAddress):$($c.RemotePort)"] = $true
        }
      }
    }
    Start-Sleep -Seconds 2
  }
  return @($seen.Keys)
}

function Stop-ProfileApp([string] $DataDir, [string] $Id) {
  $script:DataDirProcesses = $null
  Get-ProfileProcesses ([pscustomobject]@{ dataDir = $DataDir }) | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  [void](Wait-Until { @(Get-ProcessesFor $DataDir).Count -eq 0 -and @(Get-LaunchersFor $Id).Count -eq 0 } 25)
}

function Read-Record([string] $Id) {
  [IO.File]::ReadAllText((Join-Path $twHome "profiles\$Id.json")) | ConvertFrom-Json
}

# The images in an .ico file: size, and whether it's stored as PNG.
function Read-IcoInfo([string] $Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  $count = [BitConverter]::ToUInt16($b, 4)
  $images = @()
  for ($i = 0; $i -lt $count; $i++) {
    $e = 6 + 16 * $i
    $size = if ($b[$e] -eq 0) { 256 } else { [int]$b[$e] }
    $offset = [BitConverter]::ToInt32($b, $e + 12)
    $images += [pscustomobject]@{ Size = $size; Png = ($b[$offset] -eq 0x89 -and $b[$offset + 1] -eq 0x50) }
  }
  [pscustomobject]@{ Type = [BitConverter]::ToUInt16($b, 2); Images = $images }
}

function Get-HueDistance([double] $A, [double] $B) {
  $d = [Math]::Abs($A - $B) % 360
  return [Math]::Min($d, 360 - $d)
}

# The average hue (0-360) of the clearly coloured, opaque pixels of an image
# (a PNG file, or a bitmap).
function Get-MainHue($Image) {
  Add-Type -AssemblyName System.Drawing
  $bmp = if ($Image -is [Drawing.Bitmap]) { $Image } else { New-Object Drawing.Bitmap $Image }
  try {
    $x = 0.0; $y = 0.0
    for ($j = 0; $j -lt $bmp.Height; $j += 4) {
      for ($i = 0; $i -lt $bmp.Width; $i += 4) {
        $c = $bmp.GetPixel($i, $j)
        if ($c.A -gt 200 -and $c.GetSaturation() -gt 0.35 -and $c.GetBrightness() -gt 0.2 -and $c.GetBrightness() -lt 0.85) {
          $x += [Math]::Cos($c.GetHue() * [Math]::PI / 180)
          $y += [Math]::Sin($c.GetHue() * [Math]::PI / 180)
        }
      }
    }
    return (([Math]::Atan2($y, $x) * 180 / [Math]::PI) + 360) % 360
  } finally {
    $bmp.Dispose()
  }
}

# ---------------------------------------------------------------------------

try {
  Write-Host "Twinbar tests in $root"

  # -------------------------------------------------------------------------
  Write-Section 'Static checks'
  foreach ($file in @($cli, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors)
    Assert-Equal 0 @($errors).Count "$(Split-Path -Leaf $file) parses"
  }
  foreach ($file in @($cli, (Join-Path $repo 'twinbar.cmd'), $PSCommandPath, (Join-Path $PSScriptRoot 'FakeApp.cs'), (Join-Path $PSScriptRoot 'TestNet.cs'), (Join-Path $repo 'tools\release-notes.ps1'), (Join-Path $repo 'tools\make-release.ps1'))) {
    $bytes = [IO.File]::ReadAllBytes($file)
    Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "$(Split-Path -Leaf $file) is plain ASCII (Windows PowerShell reads it the same in any locale)"
  }
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($cli, [ref] $tokens, [ref] $errors)
  $iex = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Invoke-Expression', 'iex' }, $true))
  Assert-Equal 0 $iex.Count 'twinbar.ps1 never uses Invoke-Expression'
  $cmdText = [IO.File]::ReadAllText((Join-Path $repo 'twinbar.cmd'))
  Assert-True ($cmdText -match "`r`n" -and $cmdText -notmatch "[^`r]`n") 'twinbar.cmd uses CRLF line endings'
  $version = ([regex]::Match([IO.File]::ReadAllText($cli), "TwinbarVersion = '([^']+)'")).Groups[1].Value
  Assert-True ([IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')).Contains("## [$version]")) "CHANGELOG.md has a section for $version"
  if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    $settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
    foreach ($file in @($cli, $PSCommandPath)) {
      $issues = @(Invoke-ScriptAnalyzer -Path $file -Settings $settings)
      Assert-Equal 0 $issues.Count "PSScriptAnalyzer finds nothing in $(Split-Path -Leaf $file)"
      $issues | ForEach-Object { Write-Host "        $($_.RuleName) line $($_.Line): $($_.Message)" -ForegroundColor DarkGray }
    }
  } else {
    Write-Host '  skip  PSScriptAnalyzer (not installed)'
  }

  # -------------------------------------------------------------------------
  Write-Section 'Release files'
  $dist = Join-Path $root 'dist'
  $notes = Join-Path $root 'notes.md'
  $build = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\make-release.ps1') -OutDir $dist -NotesPath $notes 2>&1
  Assert-Equal 0 $LASTEXITCODE 'tools\make-release.ps1 builds them' ($build | Out-String)
  $zipFile = Join-Path $dist "twinbar-$version.zip"
  Assert-True (Test-Path -LiteralPath $zipFile) "twinbar-$version.zip"
  if (Test-Path -LiteralPath $zipFile) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipRead = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try { $entries = @($zipRead.Entries | ForEach-Object { $_.FullName }) } finally { $zipRead.Dispose() }
    Assert-Equal 'CHANGELOG.md,LICENSE,README.md,twinbar.cmd,twinbar.ps1' (($entries | Sort-Object) -join ',') 'the zip has the script and its documents'
    $scoop = [IO.File]::ReadAllText((Join-Path $dist 'twinbar.json')) | ConvertFrom-Json
    Assert-Equal $version $scoop.version 'the Scoop manifest has the version'
    Assert-Equal (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant() $scoop.hash "the Scoop manifest has the zip's hash"
    Assert-True ($scoop.url -like "*/releases/download/v$version/twinbar-$version.zip") 'and its download address'
    $sumLines = @([IO.File]::ReadAllLines((Join-Path $dist 'SHA256SUMS')))
    Assert-True ($sumLines -contains ('{0}  twinbar-{1}.zip' -f $scoop.hash, $version)) 'SHA256SUMS has the zip'
    Assert-True ([IO.File]::ReadAllText($notes) -match 'scoop install' -and [IO.File]::ReadAllText($notes) -match '### ') "the release notes have the version's changes and how to install"
  }
  # Every release since the first has notes of its own in docs\releases.
  $released = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')), '(?m)^## \[([0-9]+\.[0-9]+\.[0-9]+)\]') |
      ForEach-Object { $_.Groups[1].Value } | Where-Object { [version]$_ -ge [version]'0.5.0' })
  $missingNotes = @($released | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repo "docs\releases\v$_.md")) })
  Assert-Equal '' ($missingNotes -join ', ') 'every release has its notes in docs\releases'
  $notesTool = Join-Path $repo 'tools\release-notes.ps1'
  $firstNotes = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $notesTool -Version 0.5.0) -join "`n"
  Assert-True ($firstNotes -match 'twinbar-0\.5\.0\.zip' -and $firstNotes -notmatch 'Twinbar-Setup') "release notes: 0.5.0, from before the installer, only offer the zip"
  $thisNotes = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $notesTool -Version $version) -join "`n"
  Assert-True ($thisNotes -match [regex]::Escape("Twinbar-Setup-$version.exe") -and $thisNotes -match [regex]::Escape("Update to $version")) "release notes: $version offers the installer, and says Twinbar updates itself"

  # The installer script: Inno Setup's preprocessor takes any line starting with
  # "#" as a directive, even in [Code] (a line starting with #13#10 broke a build).
  $iss = [IO.File]::ReadAllLines((Join-Path $repo 'installer\twinbar.iss'))
  $directive = '^\s*#\s*(if|ifdef|ifndef|elif|else|endif|define|undef|include|error|emit|expr|pragma|sub|endsub|for|insert|append|file|preproc)\b'
  $stray = @(for ($i = 0; $i -lt $iss.Count; $i++) { if ($iss[$i] -match '^\s*#' -and $iss[$i] -notmatch $directive) { "line $($i + 1): $($iss[$i].Trim())" } })
  Assert-Equal 0 $stray.Count 'installer\twinbar.iss: every line starting with # is a preprocessor directive' ($stray -join ' | ')
  Assert-True ([IO.File]::ReadAllText((Join-Path $repo 'installer\twinbar.iss')) -match "OutputBaseFilename=Twinbar-Setup-\{#AppVersion\}") 'the installer is named Twinbar-Setup-<version>.exe'

  # make-release -Installer, with stand-ins for Inno Setup's compiler (the real one runs in CI).
  # (In PowerShell: cmd.exe would split "/DAppVersion=x" at the "=".)
  $fakeIscc = Join-Path $root 'fake iscc.ps1'
  [IO.File]::WriteAllText($fakeIscc, (@(
        '# A stand-in for ISCC.exe: checks its arguments and writes an empty "installer".'
        '$version = [string]($args | Where-Object { $_ -like "/DAppVersion=*" }) -replace "^/DAppVersion=", ""'
        '$icon = [string]($args | Where-Object { $_ -like "/DIconFile=*" }) -replace "^/DIconFile=", ""'
        '$out = [string]($args | Where-Object { $_ -like "/O*" }) -replace "^/O", ""'
        '$script = [string]$args[-1]'
        'if (-not $version) { [Console]::Error.WriteLine("Error: no version"); exit 4 }'
        'if (-not (Test-Path -LiteralPath $icon)) { [Console]::Error.WriteLine("Error: no icon at $icon"); exit 2 }'
        'if (-not $script.EndsWith("twinbar.iss") -or -not (Test-Path -LiteralPath $script)) { [Console]::Error.WriteLine("Error: no script at $script"); exit 3 }'
        '[IO.File]::WriteAllText((Join-Path $out "Twinbar-Setup-$version.exe"), "fake")'
        '"Successful compile (fake)"'
        'exit 0'
      ) -join "`r`n") + "`r`n")
  $installerDist = Join-Path $root 'dist with installer'
  $r = Invoke-Cli @('-OutDir', $installerDist, '-Installer', '-Iscc', $fakeIscc) (Join-Path $repo 'tools\make-release.ps1')
  Assert-Cli $r 0 'Successful compile' 'make-release -Installer draws the icon and runs Inno Setup'
  Assert-True (Test-Path -LiteralPath (Join-Path $installerDist "Twinbar-Setup-$version.exe")) "with Twinbar-Setup-$version.exe as the result"
  if (Test-Path -LiteralPath (Join-Path $installerDist 'SHA256SUMS')) {
    Assert-True (@([IO.File]::ReadAllLines((Join-Path $installerDist 'SHA256SUMS')) | Where-Object { $_ -like "*  Twinbar-Setup-$version.exe" }).Count -eq 1) 'SHA256SUMS has the installer'
  }
  $failingIscc = Join-Path $root 'failing iscc.cmd'
  [IO.File]::WriteAllText($failingIscc, "@echo off`r`necho Error on line 7 in twinbar.iss: Unknown preprocessor directive. 1>&2`r`nexit /b 2`r`n")
  $r = Invoke-Cli @('-OutDir', (Join-Path $root 'dist failing'), '-Installer', '-Iscc', $failingIscc) (Join-Path $repo 'tools\make-release.ps1')
  Assert-Cli $r 1 'Inno Setup failed \(exit 2\).*line 7' "a failed Inno Setup build fails make-release, with Inno Setup's error"

  # -------------------------------------------------------------------------
  Write-Section 'Fake apps'
  $std = Join-Path $root 'apps\Fake App'
  New-ElectronDir $std
  $stdExe = Join-Path $std 'FakeApp.exe'
  $sq = Join-Path $root 'apps\FakeSquirrel'
  New-FakeExe (Join-Path $sq 'Update.exe')
  New-FakeExe (Join-Path $sq 'FakeApp.exe')
  New-ElectronDir (Join-Path $sq 'app-1.9.0')
  New-ElectronDir (Join-Path $sq 'app-1.10.0')
  $sqExe = Join-Path $sq 'FakeApp.exe'
  $sqLatest = Join-Path $sq 'app-1.10.0\FakeApp.exe'
  $other = Join-Path $root 'apps\Other'
  New-ElectronDir $other 'OtherApp.exe'
  $otherExe = Join-Path $other 'OtherApp.exe'
  $plain = Join-Path $root 'apps\Plain'
  New-FakeExe (Join-Path $plain 'FakeApp.exe')
  Assert-True (Test-Path -LiteralPath $stdExe) 'built the fake Electron app'

  # -------------------------------------------------------------------------
  Write-Section 'Unit checks'
  $env:TWINBAR_HOME = $twHome
  $env:TWINBAR_PINNED_DIR = $pinned
  $env:TWINBAR_STORE_DATA = $storeData
  $env:TWINBAR_SHORTCUT_DIR = $menu
  $env:TWINBAR_START_MENU = $startMenu
  $env:TWINBAR_JUMPLIST_ID = $jumpListId
  $env:TWINBAR_RUN_KEY = $runKey
  . $cli

  Assert-Equal 'C:\a;C:\b;C:\c' (Add-PathEntry 'C:\a;C:\b' 'C:\c') 'PATH: an entry is added at the end'
  Assert-Equal 'C:\a;C:\b' (Add-PathEntry 'C:\a;C:\b' 'C:\B\') 'PATH: an entry already there is not added twice'
  Assert-Equal 'C:\a;C:\c' (Remove-PathEntry 'C:\a;C:\b\;C:\c' 'C:\b') 'PATH: an entry is removed'
  Assert-Equal 'The app is gone.' (ConvertTo-Sentence 'the app is gone') 'messages read as sentences in the window'
  Assert-Equal '#8E4EC6' (Get-ColorItemHex 'Purple') 'window: colour names map to the palette'
  Assert-Equal '#12ABEF' (Get-ColorItemHex '#12abef') 'window: custom colours'

  $links = Join-Path $root 'links'
  [void][IO.Directory]::CreateDirectory($links)
  $lnkStd = Join-Path $links 'My Fake.lnk'
  Save-ShellLink -Path $lnkStd -TargetPath $stdExe
  $lnkUpdate = Join-Path $links 'Fake Updater.lnk'
  Save-ShellLink -Path $lnkUpdate -TargetPath (Join-Path $sq 'Update.exe') -Arguments '--processStart "FakeApp.exe"'
  $lnkProfile = Join-Path $links 'Fake App Someone.lnk'
  Save-ShellLink -Path $lnkProfile -TargetPath $stdExe -AppUserModelId 'Twinbar.fakeapp.someone'
  Assert-Equal 'Twinbar.fakeapp.someone' (Read-ShellLink $lnkProfile).AppUserModelId 'a shortcut keeps its AppUserModelID'

  $persian = -join ([char[]](0x06A9, 0x0627, 0x0631)) # "kar" (work) in Persian
  Assert-Equal 'Work' (Test-ProfileName 'Work') 'name: Work'
  Assert-Equal 'Work' (Test-ProfileName '  Work  ') 'name: spaces around are trimmed'
  Assert-Equal 'Work 2.0' (Test-ProfileName 'Work 2.0') 'name: Work 2.0'
  Assert-Equal $persian (Test-ProfileName $persian) 'name: Persian letters'
  $withZwnj = -join ([char[]](0x0645, 0x06CC, 0x200C, 0x0631)) # Persian word with a zero-width non-joiner
  Assert-Equal $withZwnj (Test-ProfileName $withZwnj) 'name: Persian with a zero-width non-joiner'
  Assert-Throws { Test-ProfileName ('a' + [char]0x202E + 'b') } 'letters' 'name: a right-to-left override is refused'
  Assert-Throws { Test-ProfileName '' } 'required' 'name: empty is refused'
  Assert-Throws { Test-ProfileName ('x' * 41) } '40' 'name: 41 characters is refused'
  Assert-Throws { Test-ProfileName 'Work!' } 'letters' 'name: Work! is refused'
  Assert-Throws { Test-ProfileName '-Work' } 'letters' 'name: -Work is refused'
  Assert-Throws { Test-ProfileName 'Work.' } 'letters' 'name: Work. is refused'
  Assert-Throws { Test-ProfileName 'a/b' } 'letters' 'name: a/b is refused'
  Assert-Throws { Test-ProfileName 'con' } 'reserves' 'name: CON is refused'

  Assert-Equal 'work' (Get-NameKey 'Work') 'key: Work -> work'
  Assert-Equal 'my-work-2' (Get-NameKey 'My  Work 2') 'key: My  Work 2 -> my-work-2'
  Assert-Equal 'mongodbcompass' (Get-NameKey 'MongoDBCompass') 'key: MongoDBCompass -> mongodbcompass'
  Assert-True ((Get-NameKey $persian) -match '^p[0-9a-f]{8}$') 'key: Persian name gets a hash key'
  Assert-Equal (Get-NameKey $persian) (Get-NameKey $persian) 'key: the hash key is stable'
  Assert-True ((Get-NameKey ('abc ' * 20)).Length -le 32) 'key: at most 32 characters'

  Assert-True (Test-IsStoreAppPath 'C:\Program Files\WindowsApps\Claude_1.0_x64__abc\app\claude.exe') 'Store app path is recognised'
  Assert-True (-not (Test-IsStoreAppPath 'C:\Program Files\Bruno\Bruno.exe')) 'normal path is not a Store app'

  $a = Resolve-ElectronApp $stdExe
  Assert-Equal 'standard' $a.Kind 'standard app: kind'
  Assert-Equal 'Fake App' $a.Name 'standard app: name from the version info'
  Assert-Equal 'fakeapp' $a.Id 'standard app: id'
  Assert-Equal $stdExe $a.LaunchExe 'standard app: starts its own exe'
  Assert-Equal $stdExe (Resolve-ElectronApp $std).LaunchExe 'standard app: found from its folder'
  $a = Resolve-ElectronApp $sqExe
  Assert-Equal 'squirrel' $a.Kind 'Squirrel app: kind'
  Assert-Equal $sqExe $a.LaunchExe 'Squirrel app: starts the root launcher'
  Assert-Equal $sqLatest $a.RealExe 'Squirrel app: newest version (1.10.0 after 1.9.0)'
  $a = Resolve-ElectronApp (Join-Path $sq 'app-1.9.0\FakeApp.exe')
  Assert-Equal $sqExe $a.LaunchExe 'Squirrel app: an exe in app-1.9.0 uses the root launcher'
  Assert-Equal $sqExe (Resolve-ElectronApp $sq).LaunchExe 'Squirrel app: found from its folder'
  $a = Resolve-ElectronApp $lnkStd
  Assert-Equal 'My Fake' $a.Name 'shortcut: name from the shortcut'
  Assert-Equal $stdExe $a.LaunchExe 'shortcut: its target'
  Assert-Equal $sqExe (Resolve-ElectronApp $lnkUpdate).LaunchExe 'shortcut to Update.exe --processStart'
  Assert-Throws { Resolve-ElectronApp $lnkProfile } 'Twinbar profile' 'a Twinbar profile is refused as the app'
  Assert-Throws { Resolve-ElectronApp (Join-Path $plain 'FakeApp.exe') } 'Electron' 'a non-Electron exe is refused'
  Assert-Throws { Resolve-ElectronApp (Join-Path $root 'nope.exe') } 'not found' 'a missing path is refused'
  Assert-Throws { Resolve-ElectronApp '' } 'which app' 'no app is refused'

  $dd = Join-Path $root 'state'
  Assert-Equal 'missing' (Get-DataDirState $dd 'x.y') 'data folder: missing'
  [void][IO.Directory]::CreateDirectory($dd)
  Assert-Equal 'empty' (Get-DataDirState $dd 'x.y') 'data folder: empty'
  [IO.File]::WriteAllText((Join-Path $dd 'file.txt'), 'x')
  Assert-Equal 'foreign' (Get-DataDirState $dd 'x.y') 'data folder: has files, no marker'
  [IO.File]::WriteAllText((Join-Path $dd '.twinbar-profile'), 'x.y')
  Assert-Equal 'ours' (Get-DataDirState $dd 'x.y') 'data folder: our marker'
  Assert-Equal 'other:x.y' (Get-DataDirState $dd 'x.z') "data folder: another profile's marker"

  Assert-True (Test-ProtectedDir ([Environment]::GetFolderPath('UserProfile'))) 'protected: the user folder'
  Assert-True (Test-ProtectedDir 'C:\') 'protected: a drive root'
  Assert-True (Test-ProtectedDir ([Environment]::GetFolderPath('ApplicationData') + '\')) 'protected: AppData\Roaming'
  Assert-True (Test-ProtectedDir (Join-Path $twHome 'data')) "protected: Twinbar's data folder"
  Assert-True (-not (Test-ProtectedDir (Join-Path $twHome 'data\fakeapp\work'))) "not protected: a profile's folder"

  Assert-Equal '#0090FF' (Resolve-ProfileColor 'Blue' 'x.y') 'colour: a palette name'
  Assert-Equal '#12ABEF' (Resolve-ProfileColor '12abef' 'x.y') 'colour: hex without #'
  Assert-Equal (Resolve-ProfileColor '' 'fakeapp.work') (Resolve-ProfileColor '' 'fakeapp.work') 'colour: the default is stable'
  Assert-True ((Resolve-ProfileColor '' 'fakeapp.work') -ne '#6F6E77') 'colour: the default is never gray'
  Assert-Throws { Resolve-ProfileColor 'mauve' 'x.y' } 'colour must be' 'colour: an unknown name is refused'
  Assert-Equal 'W' (Get-BadgeText '' 'work') 'badge: first letter of the name, upper case'
  Assert-Equal 'AB' (Get-BadgeText 'ab' 'Work') 'badge: two letters'
  Assert-Equal ([string][char]0x06A9) (Get-BadgeText '' $persian) 'badge: a Persian name gives its first letter'
  Assert-Throws { Get-BadgeText 'ABC' 'Work' } '1 or 2' 'badge: three letters are refused'
  Assert-Throws { Get-BadgeText '!' 'Work' } '1 or 2' 'badge: punctuation is refused'
  Assert-Equal 'tint+badge' (Resolve-Style '') 'style: tint+badge by default'
  Assert-Equal 'badge' (Resolve-Style 'Badge') 'style: badge'
  Assert-Throws { Resolve-Style 'sparkly' } 'style must be' 'style: an unknown one is refused'
  Assert-Equal 'system' (Resolve-Appearance '') 'appearance: system by default'
  Assert-Equal 'dark' (Resolve-Appearance 'Dark') 'appearance: dark'
  Assert-Throws { Resolve-Appearance 'sepia' } 'appearance must be' 'appearance: an unknown one is refused'
  Assert-Equal '--force-dark-mode' $script:Appearances['dark'] 'appearance: dark is --force-dark-mode'
  Assert-Equal 'socks5://127.0.0.1:10808' (Resolve-ProxyValue 'socks5://127.0.0.1:10808') 'proxy: socks5'
  Assert-Equal 'http://Proxy.Example:8080' (Resolve-ProxyValue ' HTTP://Proxy.Example:8080/ ') 'proxy: http, tidied'
  Assert-Equal 'https://[::1]:3128' (Resolve-ProxyValue 'https://[::1]:3128') 'proxy: https with an IPv6 address'
  Assert-Equal '' (Resolve-ProxyValue 'none') 'proxy: none'
  Assert-Equal '' (Resolve-ProxyValue '') 'proxy: empty is none'
  foreach ($badProxy in 'socks4://h:1', 'socks5://h', 'socks5://h:70000', 'ftp://h:21', 'socks5://a b:1', 'socks5://user:pw@h:1') {
    Assert-Throws { Resolve-ProxyValue $badProxy } 'proxy must look like' "proxy: '$badProxy' is refused"
  }
  $proxyArgs = Get-ProxyArgs 'socks5://127.0.0.1:10808'
  Assert-True ($proxyArgs.Contains('--proxy-server=socks5://127.0.0.1:10808')) 'proxy switches: the proxy'
  Assert-True ($proxyArgs.Contains('"--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost"')) 'proxy switches: no name is looked up locally, but the proxy and localhost'
  Assert-True ($proxyArgs.Contains('--force-webrtc-ip-handling-policy=disable_non_proxied_udp')) "proxy switches: WebRTC can't go around it"
  Assert-Equal '' (Get-ProxyArgs '') 'proxy switches: none without a proxy'
  Assert-True ((Get-ExtraArgs 'dark' 'http://h:1' 'standard') -match '^--force-dark-mode --proxy-server=http://h:1 ') 'appearance and proxy switches together'
  $storeArgs = Get-ExtraArgs 'system' 'socks5://127.0.0.1:1' 'store'
  Assert-True ($storeArgs -match '--proxy-server=socks5://127\.0\.0\.1:1' -and $storeArgs -match 'disable_non_proxied_udp' -and $storeArgs -notmatch 'host-resolver-rules') "Store apps: the proxy and WebRTC switches, without the DNS rule (Claude doesn't start with it)"
  Assert-Equal '--blink-settings=preferredColorScheme=1' $script:Appearances['light'] 'appearance: light prefers the light colour scheme'

  # Windows' proxy setting, in the forms it comes in.
  $env:TWINBAR_SYSTEM_PROXY = '127.0.0.1:10809'
  Assert-Equal 'any|127.0.0.1|10809' (@(Get-SystemProxyEntries) | ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Host, $_.Port }) "Windows' proxy setting: host:port"
  $env:TWINBAR_SYSTEM_PROXY = 'http=127.0.0.1:10809;https=127.0.0.1:10809;ftp=127.0.0.1:1;socks=127.0.0.1:10808'
  Assert-Equal 'http|10809 http|10809 socks5|10808' ((@(Get-SystemProxyEntries) | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Port }) -join ' ') "Windows' proxy setting: one per protocol, FTP left out"
  $env:TWINBAR_SYSTEM_PROXY = 'http://[::1]:3128'
  Assert-Equal 'any|[::1]|3128' (@(Get-SystemProxyEntries) | ForEach-Object { '{0}|{1}|{2}' -f $_.Kind, $_.Host, $_.Port }) "Windows' proxy setting: with a scheme and an IPv6 address"
  $env:TWINBAR_SYSTEM_PROXY = 'none'
  Assert-Equal 0 @(Get-SystemProxyEntries).Count "Windows' proxy setting: nothing usable"
  Remove-Item Env:\TWINBAR_SYSTEM_PROXY

  # Updates: what GitHub says about a release, and the SHA-256 list.
  $releaseJson = '{"tag_name":"v1.2.3","html_url":"https://github.com/sadrazkh/twinbar/releases/tag/v1.2.3","body":"New:\r\n- things",' +
    '"assets":[{"name":"twinbar-1.2.3.zip","size":10,"browser_download_url":"https://github.com/sadrazkh/twinbar/releases/download/v1.2.3/twinbar-1.2.3.zip"},' +
    '{"name":"Twinbar-Setup-1.2.3.exe","size":2000,"browser_download_url":"https://github.com/sadrazkh/twinbar/releases/download/v1.2.3/Twinbar-Setup-1.2.3.exe"},' +
    '{"name":"SHA256SUMS","size":200,"browser_download_url":"https://github.com/sadrazkh/twinbar/releases/download/v1.2.3/SHA256SUMS"}]}'
  $rel = ConvertFrom-ReleaseJson $releaseJson
  Assert-Equal '1.2.3|Twinbar-Setup-1.2.3.exe|2000' ('{0}|{1}|{2}' -f $rel.Version, $rel.SetupName, $rel.SetupSize) 'release: version and installer'
  Assert-Equal "New:`n- things" $rel.Notes "release: what's new"
  Assert-Equal "New:`n- things" (ConvertFrom-ReleaseJson ($releaseJson.Replace('- things"', '- things\r\n\r\n---\r\n\r\n## Install\r\nDownload it."'))).Notes "release: what's new, without the install section"
  Assert-True ($rel.SumsUrl.EndsWith('/SHA256SUMS')) 'release: the SHA-256 list'
  Assert-True (Test-UpdateUrl $rel.SetupUrl) "update: Twinbar's own release downloads are allowed"
  Assert-True (-not (Test-UpdateUrl 'https://github.com/someone/else/releases/download/v1/x.exe')) "update: another repository's aren't"
  Assert-True (-not (Test-UpdateUrl 'http://github.com/sadrazkh/twinbar/releases/download/v1/x.exe')) "update: nor plain HTTP"
  Assert-Throws { ConvertFrom-ReleaseJson '{"tag_name":"nightly"}' } "doesn't understand" 'release: an odd tag is refused'
  Assert-True (Test-NewerVersion '99.0.0') 'update: 99.0.0 is newer'
  Assert-True (-not (Test-NewerVersion $script:TwinbarVersion)) "update: this version isn't newer than itself"
  $sha = 'ab' * 32
  Assert-Equal $sha (Get-ListedHash ("$('cd' * 32)  twinbar-1.2.3.zip`n$($sha.ToUpperInvariant()) *Twinbar-Setup-1.2.3.exe`n") 'Twinbar-Setup-1.2.3.exe') 'SHA256SUMS: the line for the installer (binary mark, any case)'
  Assert-Throws { Get-ListedHash "$sha  other.exe" 'Twinbar-Setup-1.2.3.exe' } "doesn't list" "SHA256SUMS: a missing line is refused"
  Assert-Equal '/SILENT /SUPPRESSMSGBOXES /NORESTART' ((Get-SetupArguments 'setup') -join ' ') "update: quiet over the installer's own install"
  Assert-Equal '/NORESTART' ((Get-SetupArguments 'copy') -join ' ') "update: the installer's window otherwise"
  Assert-Equal 'copy' (Get-InstallKind) 'update: the repository is a plain copy'
  Assert-True ((Get-Settings).checkForUpdates) 'settings: checking for updates is on by default'
  Assert-True ((Get-Settings).closeToTray) 'settings: closing the window keeps Twinbar by the clock by default'
  Assert-Equal "`"$(Join-Path $repo 'Twinbar.exe')`" --tray" (Get-StartupCommand) 'startup: Twinbar.exe, straight to the clock'
  Assert-Throws { Set-StartWithWindows $true } 'needs an installed Twinbar' "startup: not from a copy that isn't installed"
  Assert-True (-not (Test-StartWithWindows)) "startup: off until it's turned on"

  # Extra arguments and environment variables, sizes, and the caches in a data folder.
  Assert-Equal '--disable-gpu --lang=fa' (Resolve-AppArgs '  --disable-gpu --lang=fa ') 'arguments: tidied'
  Assert-Equal '' (Resolve-AppArgs 'none') 'arguments: none'
  Assert-Equal '--title="a b"' (Resolve-AppArgs '--title="a b"') 'arguments: quotes that close are fine'
  Assert-Throws { Resolve-AppArgs '--User-Data-Dir=C:\x' } "can't set the data folder" "arguments: the data folder isn't theirs to set"
  Assert-Throws { Resolve-AppArgs '-startintray -workdir "C:\x"' } "can't set the data folder" "arguments: nor Telegram's -workdir"
  Assert-Equal '-startintray' (Resolve-AppArgs '-startintray') "arguments: Telegram's own switches are fine"
  Assert-Throws { Resolve-AppArgs '--title="a b' } 'never closed' 'arguments: a quote must close'

  # Telegram profiles: how they start, and how their process is recognised.
  $tgDirUnit = 'C:\Users\x\AppData\Roaming\Twinbar\data\telegram\work'
  Assert-Equal "-workdir ""$tgDirUnit"" -startintray" (Get-LaunchArguments ([pscustomobject]@{ family = 'telegram'; dataDir = $tgDirUnit; extraArgs = '-startintray' })) 'Telegram starts with -workdir and its folder'
  Assert-Equal '--user-data-dir="C:\d" --force-dark-mode' (Get-LaunchArguments ([pscustomobject]@{ family = 'electron'; dataDir = 'C:\d'; extraArgs = '--force-dark-mode' })) 'Electron apps with --user-data-dir'
  Assert-Equal '-x' (Get-ExtraArgs 'dark' 'http://h:1' 'standard' '-x' 'telegram') "Telegram gets no Chromium switches, only its extra arguments"
  Assert-True (Test-ProfileCommandLine $tgDirUnit ('"C:\T\Telegram.exe" -workdir "' + $tgDirUnit + '"')) 'process: Telegram with its -workdir'
  Assert-True (Test-ProfileCommandLine $tgDirUnit 'C:\T\Telegram.exe -workdir "C:/Users/x/AppData/Roaming/Twinbar/data/telegram/work/" -autostart') "process: Telegram's own spelling after it restarts (forward slashes, a slash at the end)"
  Assert-True (-not (Test-ProfileCommandLine $tgDirUnit ('"C:\T\Telegram.exe" -workdir "' + $tgDirUnit + '2"'))) 'process: not a folder whose name only starts the same'
  Assert-True (-not (Test-ProfileCommandLine $tgDirUnit '"C:\T\Telegram.exe"')) 'process: not the main Telegram'
  Assert-True (Test-ProfileCommandLine 'C:\d' 'app.exe --user-data-dir="C:\d" --x') 'process: Electron apps as before'
  Assert-Throws { Assert-FamilyOptions 'telegram' 'http://h:1' 'system' } 'proxy setting of its own' "Telegram: no Twinbar proxy"
  Assert-Throws { Assert-FamilyOptions 'telegram' '' 'dark' } 'its own theme' 'Telegram: no Twinbar light/dark'
  $cefDir = Join-Path $root 'apps\SomeCef'
  New-FakeExe (Join-Path $cefDir 'Some.exe')
  [IO.File]::WriteAllText((Join-Path $cefDir 'libcef.dll'), 'stand-in')
  Assert-Throws { Resolve-ElectronApp (Join-Path $cefDir 'Some.exe') } 'built on CEF' 'a CEF app is refused, saying why'
  $optionsDir = Join-Path $root 'telegram options'
  Set-TelegramOptions $optionsDir
  $optionsFile = Join-Path $optionsDir 'tdata\experimental_options.json'
  Assert-True (([IO.File]::ReadAllText($optionsFile) | ConvertFrom-Json).'skip-url-scheme-register' -eq $true) 'Telegram option file: made with skip-url-scheme-register'
  [IO.File]::WriteAllText($optionsFile, '{"a": 1, "skip-url-scheme-register": false}')
  Set-TelegramOptions $optionsDir
  $optionsBack = [IO.File]::ReadAllText($optionsFile) | ConvertFrom-Json
  Assert-True ($optionsBack.'skip-url-scheme-register' -eq $true -and $optionsBack.a -eq 1) 'Telegram option file: turned back on, other options kept'
  Assert-Throws { Resolve-AppArgs "--a`n--b" } 'one line' 'arguments: one line'
  Assert-Equal 'A=1;B_2=x y;C=' (Resolve-EnvValue ' A=1; B_2 = x y ;C=') 'environment: NAME=value pairs, tidied'
  Assert-Equal 'NODE_OPTIONS=--max-old-space-size=4096' (Resolve-EnvValue 'NODE_OPTIONS=--max-old-space-size=4096') "environment: '=' inside a value"
  Assert-Equal '' (Resolve-EnvValue 'none') 'environment: none'
  Assert-Throws { Resolve-EnvValue '1A=x' } 'NAME=value' 'environment: a name starts with a letter'
  Assert-Throws { Resolve-EnvValue 'JUSTANAME' } 'NAME=value' 'environment: a value is needed'
  Assert-Equal '--force-dark-mode --x' (Get-ExtraArgs 'dark' '' 'standard' '--x') "extra arguments come after Twinbar's own"
  Assert-Equal '1.5 GB|20 MB|3 KB|512 bytes' ('{0}|{1}|{2}|{3}' -f (Format-Size 1610612736), (Format-Size 20971520), (Format-Size 3072), (Format-Size 512)) 'sizes read as GB, MB, KB'
  $cacheTest = Join-Path $root 'cache test'
  foreach ($d in 'Cache\Cache_Data', 'Code Cache\js', 'Local Storage', 'Partitions\p1\GPUCache', 'Partitions\p1\IndexedDB', 'Service Worker\CacheStorage', 'Service Worker\Database') {
    [void][IO.Directory]::CreateDirectory((Join-Path $cacheTest $d))
  }
  Assert-Equal 'Cache|Code Cache|Service Worker\CacheStorage|Partitions\p1\GPUCache' ((@(Get-CacheFolders $cacheTest)) -join '|') 'caches: found at the top and in partitions, data left alone'
  [IO.File]::WriteAllText((Join-Path $cacheTest 'Cache\Cache_Data\a'), ('x' * 1000))
  [IO.File]::WriteAllText((Join-Path $cacheTest 'Local Storage\b'), ('y' * 500))
  Assert-Equal 1500 ([TwinbarInterop.Files]::Size($cacheTest)) 'sizes: every file under a folder'
  Assert-Equal 'Local Storage\b' (([TwinbarInterop.Files]::List($cacheTest, [string[]]@('Cache'))) -join '|') 'file lists: without the folders left out'

  # The jump list, under the tests' own ID. Windows keeps it in a file of its own;
  # the title is in there as UTF-16, at an even or an odd byte.
  $jumpDir = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations'
  $findInJumpLists = {
    param([string] $Text)
    @(Get-ChildItem -LiteralPath $jumpDir -File -ErrorAction SilentlyContinue | Where-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $bytes.Length -gt 1 -and ([Text.Encoding]::Unicode.GetString($bytes).Contains($Text) -or [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1).Contains($Text))
      }).Count -gt 0
  }
  $jumpTitle = "Fake App Jumpy $testKey"
  [TwinbarInterop.JumpList]::SetTasks($jumpListId, @($jumpTitle), @($stdExe), @('fakeapp.jumpy'), @(''), @('Open it'))
  Assert-True (& $findInJumpLists $jumpTitle) 'jump list: a profile is in it'
  [TwinbarInterop.JumpList]::Delete($jumpListId)
  Assert-True (-not (& $findInJumpLists $jumpTitle)) 'jump list: and gone when the list is deleted'

  $old = [pscustomobject]@{ schema = 1; id = 'fakeapp.old'; name = 'Old'; appName = 'Fake App'; launchExe = $stdExe; realExe = $stdExe; dataDir = 'x'; shortcut = 'y'; aumid = 'Twinbar.fakeapp.old' }
  $table = ConvertTo-ProfileTable $old
  Assert-Equal 'standard|tint+badge|O|system' ('{0}|{1}|{2}|{3}' -f $table.appKind, $table.style, $table.badge, $table.appearance) 'an 0.1.0 record gets the new defaults'
  Assert-Equal (Resolve-ProfileColor '' 'fakeapp.old') $table.color "an 0.1.0 record gets its name's colour"
  $iconA = Get-IconPath $table
  $table.color = '#E5484D'
  Assert-True ((Get-IconPath $table) -ne $iconA) 'a new look gets a new icon file name'
  Assert-True ((Split-Path -Leaf $iconA) -match '^fakeapp\.old-[0-9a-f]{8}\.ico$') 'icon file names are <id>-<hash>.ico'

  # A Store package, as Windows describes it in AppxManifest.xml.
  $pkgDir = Join-Path $root 'apps\StorePkg'
  New-ElectronDir (Join-Path $pkgDir 'app')
  New-FakeExe (Join-Path $pkgDir 'helper\Helper.exe')
  [IO.File]::WriteAllText((Join-Path $pkgDir 'AppxManifest.xml'), @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5">
  <Applications>
    <Application Id="Main" Executable="app\FakeApp.exe" EntryPoint="Windows.FullTrustApplication">
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias"><uap5:AppExecutionAlias><uap5:ExecutionAlias Alias="fake-app.exe" /></uap5:AppExecutionAlias></uap5:Extension>
      </Extensions>
    </Application>
    <Application Id="Helper" Executable="helper\Helper.exe" EntryPoint="Windows.FullTrustApplication" />
  </Applications>
</Package>
'@)
  $entries = @(Get-StoreAppEntries ([pscustomobject]@{ InstallLocation = $pkgDir; PackageFamilyName = 'Fake.App_abc123' }))
  Assert-Equal 'Main Helper' (($entries | ForEach-Object { $_.AppId }) -join ' ') 'Store manifest: both apps found'
  Assert-Equal 'fake-app.exe' ($entries[0].Aliases -join ',') 'Store manifest: the alias found'
  Assert-Equal (Join-Path $pkgDir 'app\FakeApp.exe') $entries[0].Exe 'Store manifest: the exe found'
  Assert-Throws { Resolve-ElectronApp 'NoSuchApp4711' } "no file, folder, Start menu app or Microsoft Store app" 'an unknown app name is refused'
  $claude = @(Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Where-Object { Test-ElectronDir (Join-Path $_.InstallLocation 'app') })
  if ($claude.Count) {
    $s = Resolve-ElectronApp 'Claude'
    Assert-Equal "store|claude|$($claude[0].PackageFamilyName)!Claude" ('{0}|{1}|{2}' -f $s.Kind, $s.Id, $s.PackageApp) 'Store app by name: Claude'
    Assert-Equal $s.PackageApp (Resolve-ElectronApp $s.PackageApp).PackageApp 'Store app by app id'
    Assert-Equal $s.PackageApp (Resolve-ElectronApp $s.LaunchExe).PackageApp 'Store app by its exe under WindowsApps'
  } else {
    Write-Host '  skip  Store app lookups (Claude from the Microsoft Store is not installed)'
  }

  # Icons, drawn from Explorer's icon (any exe with an icon would do).
  Initialize-Interop
  $iconDir = Join-Path $root 'icons'
  [void][IO.Directory]::CreateDirectory($iconDir)
  $explorer = Join-Path $env:WINDIR 'explorer.exe'
  foreach ($look in 'tint+badge', 'tint', 'badge', 'none') {
    $file = Join-Path $iconDir ($look.Replace('+', '-') + '.ico')
    [TwinbarInterop.IconMaker]::Build($explorer, $file, $look, '#30A46C', 'W', [IO.Path]::ChangeExtension($file, '.png'))
  }
  $ico = Read-IcoInfo (Join-Path $iconDir 'tint-badge.ico')
  Assert-Equal 1 $ico.Type 'icon: an .ico file'
  Assert-Equal '16 20 24 32 40 48 64 256' (($ico.Images | ForEach-Object { $_.Size }) -join ' ') 'icon: sizes 16 to 256'
  Assert-Equal 'True' (($ico.Images | Where-Object { $_.Size -eq 256 }).Png).ToString() 'icon: 256 x 256 is stored as PNG'
  Assert-Equal 0 @($ico.Images | Where-Object { $_.Size -lt 256 -and $_.Png }).Count 'icon: the small sizes are plain bitmaps'
  $hue = Get-MainHue (Join-Path $iconDir 'tint.png')
  Assert-True ([Math]::Abs($hue - 151) -lt 20) 'icon: tint recolours it green' "hue $([int]$hue)"
  $plainHue = Get-MainHue (Join-Path $iconDir 'none.png')
  Assert-True ([Math]::Abs($plainHue - 151) -gt 20) "icon: the original isn't green" "hue $([int]$plainHue)"
  Add-Type -AssemblyName System.Drawing
  $b = New-Object Drawing.Bitmap (Join-Path $iconDir 'badge.png')
  $ring = $b.GetPixel(255 - [int](256 * 0.52 * 0.045), 255 - [int](256 * 0.26))
  $fill = $b.GetPixel(255 - [int](256 * 0.52 * 0.2), 255 - [int](256 * 0.26))
  $b.Dispose()
  Assert-True ($ring.R -gt 230 -and $ring.G -gt 230 -and $ring.B -gt 230) 'icon: the badge has a white ring' "$ring"
  Assert-True ([Math]::Abs($fill.GetHue() - 151) -lt 15 -and $fill.GetSaturation() -gt 0.4) 'icon: the badge is filled with the colour' "$fill"
  $noIcon = Join-Path $iconDir 'fake.ico'
  [TwinbarInterop.IconMaker]::Build($stdExe, $noIcon, 'tint+badge', '#30A46C', 'W', '')
  Assert-Equal 8 @((Read-IcoInfo $noIcon).Images).Count "icon: an app without an icon gets Windows' application icon"

  # -------------------------------------------------------------------------
  Write-Section 'Command line'
  Assert-Cli (Invoke-Cli @('help')) 0 'twinbar new -App' 'help'
  Assert-Cli (Invoke-Cli @('version')) 0 ([regex]::Escape($version)) 'version'
  Assert-Cli (Invoke-Cli @('bogus')) 1 'unknown command' 'an unknown command fails'
  $r = Invoke-Cli @('settings')
  Assert-Cli $r 0 '(?m)^updates\s+on\b' 'settings: updates on by default'
  Assert-Cli $r 0 '(?m)^tray\s+on\b' 'settings: tray on by default'
  Assert-Cli $r 0 '(?m)^startup\s+off\b' 'settings: startup off by default'
  Assert-Cli (Invoke-Cli @('settings', 'updates', 'off')) 0 '(?m)^updates\s+off\b' 'settings updates off'
  Assert-Cli (Invoke-Cli @('settings', 'updates', 'on')) 0 '(?m)^updates\s+on\b' 'settings updates on'
  Assert-Cli (Invoke-Cli @('settings', 'colour', 'on')) 1 'the settings are: updates, tray, startup' 'settings: an unknown one is refused'
  Assert-Cli (Invoke-Cli @('settings', 'tray', 'maybe')) 1 'say on or off' 'settings: only on or off'
  Assert-Cli (Invoke-Cli @('settings', 'startup', 'on')) 1 'needs an installed Twinbar' "settings startup on: not for a copy that isn't installed"
  Assert-Cli (Invoke-Cli @('list')) 0 'No profiles yet' 'list with no profiles'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-ShortcutDir', $menu)) 1 'profile name is required' 'new without a name fails'
  Assert-Cli (Invoke-Cli @('new', '-App', (Join-Path $plain 'FakeApp.exe'), '-Name', 'Work', '-ShortcutDir', $menu)) 1 'Electron' 'new with a non-Electron app fails'

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Color', 'mauve', '-ShortcutDir', $menu)) 1 'colour must be' 'new with an unknown colour fails'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Style', 'sparkly', '-ShortcutDir', $menu)) 1 'style must be' 'new with an unknown style fails'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Badge', 'ABC', '-ShortcutDir', $menu)) 1 '1 or 2' 'new with a long badge fails'

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Appearance', 'sepia', '-ShortcutDir', $menu)) 1 'appearance must be' 'new with an unknown appearance fails'

  $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Color', 'green', '-Appearance', 'dark', '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Work"' 'new Work'
  Assert-Cli $r 0 'colour #30A46C, badge W; always dark' 'it reports the icon and appearance'
  $workLink = Join-Path $menu 'Fake App Work.lnk'
  $workData = Join-Path $twHome 'data\fakeapp\work'
  $workIcon = (Read-Record 'fakeapp.work').icon
  $launcher = Join-Path $twHome 'bin\twinbar-launcher.exe'
  Assert-True (Test-Path -LiteralPath $launcher) 'the launcher was built'
  Assert-Equal "$version.0" ([Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).FileVersion) "the launcher is version $version"
  Assert-Equal 8 @((Read-IcoInfo $workIcon).Images).Count "the profile's icon was drawn"
  Assert-True (Test-Path -LiteralPath $workLink) 'the Start menu shortcut exists'
  if (Test-Path -LiteralPath $workLink) {
    $l = Read-ShellLink $workLink
    Assert-Equal $launcher $l.TargetPath 'shortcut: starts the launcher'
    Assert-Equal 'fakeapp.work' $l.Arguments 'shortcut: with the profile id'
    Assert-Equal 'Twinbar.fakeapp.work' $l.AppUserModelId 'shortcut: its own AppUserModelID'
    Assert-Equal $std $l.WorkingDirectory 'shortcut: working folder'
    Assert-Equal $workIcon $l.IconPath "shortcut: the profile's icon"
  }
  Assert-Equal 'fakeapp.work' ([IO.File]::ReadAllText((Join-Path $workData '.twinbar-profile'))) 'the data folder has the marker'
  $record = Read-Record 'fakeapp.work'
  Assert-Equal 'tint+badge|#30A46C|W|dark|--force-dark-mode|3' ('{0}|{1}|{2}|{3}|{4}|{5}' -f $record.style, $record.color, $record.badge, $record.appearance, $record.extraArgs, $record.schema) 'the record has the look and appearance'
  Assert-Equal $stdExe $record.launchExe 'the record has the app'
  Assert-True ($workIcon -like (Join-Path $twHome 'icons\fakeapp.work-*.ico')) "the icon is in Twinbar's icons folder"

  $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Plain', '-Style', 'original', '-ShortcutDir', $menu)
  Assert-Cli $r 0 "the app's own icon" 'new with -Style original'
  Assert-Equal $stdExe (Read-ShellLink (Join-Path $menu 'Fake App Plain.lnk')).IconPath "-Style original keeps the app's icon"
  Assert-Equal '' (Read-Record 'fakeapp.plain').icon '-Style original draws no icon'

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-ShortcutDir', $menu)) 1 'already a profile' 'the same profile twice fails'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'WORK', '-ShortcutDir', $menu)) 1 'already a profile' 'names differing only in case clash'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Other', '-DataDir', $workData, '-ShortcutDir', $menu)) 1 'already uses' "a data folder can't be shared"
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', [Environment]::GetFolderPath('UserProfile'), '-ShortcutDir', $menu)) 1 "can't be a profile's data folder" 'the user folder is refused as a data folder'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', (Join-Path $std 'x\..'), '-ShortcutDir', $menu)) 1 "can't contain the app" "the app's own folder is refused"

  $r = Invoke-Cli @('new', 'Home', '-App', $sqExe, '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Home"' 'new Home (name given first) for the Squirrel app'
  Assert-Equal $sqExe (Read-Record 'fakeapp.home').launchExe "a Squirrel app is started through Squirrel's launcher"

  Assert-Cli (Invoke-Cli @('new', '-App', $otherExe, '-Name', 'Home', '-ShortcutDir', $menu)) 1 'already a shortcut' "an existing shortcut isn't overwritten"
  $menu2 = Join-Path $root 'other menu'
  Assert-Cli (Invoke-Cli @('new', '-App', $otherExe, '-Name', 'Home', '-ShortcutDir', $menu2)) 0 'Made' 'new Home for a second app'

  $existing = Join-Path $root 'existing data'
  [void][IO.Directory]::CreateDirectory($existing)
  [IO.File]::WriteAllText((Join-Path $existing 'keep.txt'), 'keep me')
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Side', '-DataDir', $existing, '-ShortcutDir', $menu)) 1 'AdoptDataDir' 'a folder with files needs -AdoptDataDir'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Side', '-DataDir', $existing, '-AdoptDataDir', '-ShortcutDir', $menu)) 0 'adopted' '-AdoptDataDir uses it'
  Assert-True (Test-Path -LiteralPath (Join-Path $existing 'keep.txt')) 'adopting keeps what was there'

  $rows = Get-ListRows
  Assert-Equal 5 $rows.Count 'list -Json shows 5 profiles'
  Assert-Equal 'ready' (@($rows | Where-Object { $_.id -eq 'fakeapp.work' })[0]).status 'Work is ready'
  Assert-Cli (Invoke-Cli @('list')) 0 'Fake App Work\s+fakeapp\.work\s+ready' 'list shows a table'

  # -------------------------------------------------------------------------
  Write-Section 'Opening a profile'
  [IO.File]::WriteAllText((Join-Path $workData 'stay.txt'), 'keep running')
  [IO.File]::WriteAllText((Join-Path $workData 'window.txt'), 'show a window')
  Assert-Cli (Invoke-Cli @('open', 'Work')) 0 'Opening Fake App Work' 'open Work'
  $launched = Join-Path $workData 'launched.txt'
  Assert-True (Wait-Until { Test-Path -LiteralPath $launched } 20) 'the app started'
  if (Test-Path -LiteralPath $launched) {
    $lines = [IO.File]::ReadAllLines($launched)
    $datadirLine = @($lines | Where-Object { $_ -like 'datadir=*' })[0]
    Assert-Equal "datadir=$workData" $datadirLine 'the app got its own data folder'
    $commandLine = @($lines | Where-Object { $_ -like 'commandline=*' })[0]
    Assert-True ($commandLine -match '--force-dark-mode') 'the app was asked to be dark' $commandLine
  }
  Assert-True (Wait-Until { @(Get-ProcessesFor $workData).Count -gt 0 } 10) 'the running app is found by its data folder'
  Assert-Equal 1 @(Get-LaunchersFor 'fakeapp.work').Count 'the launcher is looking after it'
  $script:fakeWindow = [IntPtr]::Zero
  $haveWindow = Wait-Until {
    foreach ($p in @(Get-ProcessesFor $workData)) {
      $h = ([Diagnostics.Process]::GetProcessById([int]$p.ProcessId)).MainWindowHandle
      if ($h -ne [IntPtr]::Zero) { $script:fakeWindow = $h; return $true }
    }
    return $false
  } 15
  Assert-True $haveWindow 'the app showed its window'
  if ($haveWindow) {
    $tagged = Wait-Until { [TwinbarInterop.Shell]::GetWindowAppId($script:fakeWindow) -eq 'Twinbar.fakeapp.work' } 10
    Assert-True $tagged "the window carries the profile's ID, though the app set its own" ("window ID: '{0}'" -f [TwinbarInterop.Shell]::GetWindowAppId($script:fakeWindow))
    $script:windowHue = -1
    $iconSet = Wait-Until {
      $bmp = [TwinbarInterop.IconMaker]::FromHandle([TwinbarInterop.Shell]::GetWindowIcon($script:fakeWindow, $true))
      if ($null -eq $bmp) { return $false }
      $script:windowHue = Get-MainHue $bmp
      return ([Math]::Abs($script:windowHue - 151) -lt 25)
    } 10
    Assert-True $iconSet "the window shows the profile's icon (title bar, Alt+Tab)" "hue $([int]$script:windowHue)"
    if ($null -eq (Get-TaskbarAppIds)) {
      Write-Host '  skip  taskbar button (no taskbar here)'
    } else {
      Assert-True (Wait-Until { (Get-TaskbarAppIds) -contains 'Twinbar.fakeapp.work' } 10) 'the taskbar shows a button of its own for it'
      Assert-True ((Get-TaskbarAppIds) -notcontains 'Fake.App') "it isn't on the app's own button"
    }
  }
  Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq 'fakeapp.work' })[0]).status 'list shows Work running'
  Assert-Cli (Invoke-Cli @('remove', 'Work')) 1 'running' "a running profile isn't removed"
  Assert-Cli (Invoke-Cli @('change', 'Work', '-Color', 'red')) 1 'running' "a running profile isn't changed"
  Assert-Cli (Invoke-Cli @('rebuild', 'Work')) 1 'running' "a running profile isn't rebuilt"
  Assert-Cli (Invoke-Cli @('doctor', 'Work')) 0 'running, looked after by the launcher' 'doctor sees it running'
  Assert-Cli (Invoke-Cli @('open', 'Work')) 0 'Opening' 'opening it again while it runs'
  Assert-True (Wait-Until { @(Get-LaunchersFor 'fakeapp.work').Count -le 1 } 10) 'still only one launcher looks after it'
  Remove-Item -LiteralPath (Join-Path $workData 'stay.txt')
  Assert-True (Wait-Until { @(Get-ProcessesFor $workData).Count -eq 0 } 15) 'the app quit'
  Assert-True (Wait-Until { @(Get-LaunchersFor 'fakeapp.work').Count -eq 0 } 25) 'the launcher quit after the app'
  $log = Join-Path $twHome 'logs\launcher.log'
  $logText = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log) } else { '' }
  Assert-True ($logText -match 'fakeapp\.work: the app quit; [1-9]\d* window\(s\) tagged') 'the launcher logged what it did' $logText.Trim()
  Remove-Item -LiteralPath (Join-Path $workData 'window.txt')

  # -------------------------------------------------------------------------
  Write-Section 'Changing a profile'
  [void][IO.Directory]::CreateDirectory($pinned)
  $pin = Join-Path $pinned 'Fake App Work.lnk'
  Save-ShellLink -Path $pin -TargetPath $launcher -Arguments 'fakeapp.work' -IconPath $workIcon -AppUserModelId 'Twinbar.fakeapp.work'
  $otherPin = Join-Path $pinned 'Something Else.lnk'
  Save-ShellLink -Path $otherPin -TargetPath $stdExe -IconPath $stdExe -AppUserModelId 'Someone.Else'
  Assert-Cli (Invoke-Cli @('change', 'Work')) 1 'nothing to change' 'change with nothing to change fails'
  Assert-Cli (Invoke-Cli @('change', 'Work', '-Badge', 'ABC')) 1 '1 or 2' 'change with a bad badge fails'
  $r = Invoke-Cli @('change', 'Work', '-Color', 'red', '-Badge', 'X', '-Appearance', 'light')
  Assert-Cli $r 0 'colour #E5484D, badge X; always light' 'change Work'
  Assert-Cli $r 0 'Updated 1 taskbar pin' 'it updated the taskbar pin'
  $changed = Read-Record 'fakeapp.work'
  Assert-Equal '#E5484D|X|light|--blink-settings=preferredColorScheme=1' ('{0}|{1}|{2}|{3}' -f $changed.color, $changed.badge, $changed.appearance, $changed.extraArgs) 'the record has the new look'
  Assert-True ($changed.icon -ne $workIcon -and (Test-Path -LiteralPath $changed.icon)) 'a new icon file was drawn'
  Assert-True (-not (Test-Path -LiteralPath $workIcon)) 'the old icon file is gone'
  Assert-Equal $changed.icon (Read-ShellLink $workLink).IconPath 'the Start menu shortcut shows the new icon'
  Assert-Equal $changed.icon (Read-ShellLink $pin).IconPath 'the taskbar pin shows the new icon'
  Assert-Equal $stdExe (Read-ShellLink $otherPin).IconPath "other pins aren't touched"
  $redHue = Get-MainHue ([TwinbarInterop.IconMaker]::Extract($changed.icon, 0, 256))
  Assert-True ((Get-HueDistance $redHue 358) -lt 15) 'the new icon is red' "hue $([int]$redHue)"
  Assert-Equal "fakeapp.work" ([IO.File]::ReadAllText((Join-Path $workData '.twinbar-profile'))) 'the data folder is untouched'
  $workIcon = $changed.icon

  # -------------------------------------------------------------------------
  Write-Section 'Rebuilding and doctor'
  Assert-Cli (Invoke-Cli @('doctor')) 0 'No problems found' 'doctor: all fine'
  Remove-Item -LiteralPath $workLink
  $r = Invoke-Cli @('doctor', 'Work')
  Assert-Cli $r 1 'shortcut: .* is missing; run: twinbar rebuild fakeapp\.work' 'doctor: a missing shortcut is found'
  Assert-Cli $r 1 '1 problem\(s\) found' 'doctor: it fails'
  Assert-Cli (Invoke-Cli @('rebuild', 'Work')) 0 'Rebuilt "Fake App Work"' 'rebuild Work'
  Assert-True (Test-Path -LiteralPath $workLink) 'the shortcut is back'
  Assert-Cli (Invoke-Cli @('doctor', 'Work')) 0 'No problems found' 'doctor: fine again'

  New-ElectronDir (Join-Path $sq 'app-1.11.0')
  Assert-Cli (Invoke-Cli @('rebuild', 'fakeapp.home')) 0 'app-1\.11\.0' 'rebuild follows a Squirrel update'
  Assert-Equal (Join-Path $sq 'app-1.11.0\FakeApp.exe') (Read-Record 'fakeapp.home').realExe 'the record has the new version'

  $movable = Join-Path $root 'apps\Movable'
  New-ElectronDir $movable
  Assert-Cli (Invoke-Cli @('new', '-App', (Join-Path $movable 'FakeApp.exe'), '-Name', 'Mover', '-ShortcutDir', $menu)) 0 'Made' 'new Mover'
  $moved = Join-Path $root 'apps\Moved'
  Rename-Item -LiteralPath $movable -NewName 'Moved'
  Assert-Cli (Invoke-Cli @('doctor', 'Mover')) 1 'If it moved, run: twinbar rebuild fakeapp\.mover -App' 'doctor: a moved app is found'
  Assert-Cli (Invoke-Cli @('rebuild', 'Mover')) 1 'If the app moved' "rebuild says how to point at the app's new place"
  Assert-Cli (Invoke-Cli @('rebuild', 'Mover', '-App', $otherExe)) 1 "that's another app" "rebuild won't switch to another app"
  Assert-Cli (Invoke-Cli @('rebuild', 'Mover', '-App', (Join-Path $moved 'FakeApp.exe'))) 0 'Rebuilt' "rebuild with the app's new place"
  Assert-Equal (Join-Path $moved 'FakeApp.exe') (Read-Record 'fakeapp.mover').launchExe 'the record has the new place'

  # A profile as Twinbar 0.1.0 left it: a shortcut straight to the app, no icon.
  $legacyData = Join-Path $twHome 'data\fakeapp\legacy'
  [void][IO.Directory]::CreateDirectory($legacyData)
  [IO.File]::WriteAllText((Join-Path $legacyData '.twinbar-profile'), 'fakeapp.legacy')
  $legacyLink = Join-Path $menu 'Fake App Legacy.lnk'
  Save-ShellLink -Path $legacyLink -TargetPath $stdExe -Arguments "--user-data-dir=""$legacyData""" -AppUserModelId 'Twinbar.fakeapp.legacy'
  $legacy = [ordered]@{ schema = 1; id = 'fakeapp.legacy'; name = 'Legacy'; appName = 'Fake App'; appId = 'fakeapp'; appKind = 'standard'
    launchExe = $stdExe; realExe = $stdExe; dataDir = $legacyData; shortcut = $legacyLink; aumid = 'Twinbar.fakeapp.legacy'
    created = '2026-11-22T00:00:00'; twinbarVersion = '0.1.0' }
  [IO.File]::WriteAllText((Join-Path $twHome 'profiles\fakeapp.legacy.json'), ($legacy | ConvertTo-Json))
  Assert-Cli (Invoke-Cli @('doctor', 'Legacy')) 1 'made with an older Twinbar \(0\.1\.0\)' 'doctor: an 0.1.0 profile is found'
  Assert-Cli (Invoke-Cli @('rebuild', '-All')) 0 'Rebuilt "Fake App Legacy"' 'rebuild -All'
  $upgraded = Read-Record 'fakeapp.legacy'
  Assert-Equal '3|tint+badge|L' ('{0}|{1}|{2}' -f $upgraded.schema, $upgraded.style, $upgraded.badge) 'the 0.1.0 profile is up to date'
  Assert-Equal $launcher (Read-ShellLink $legacyLink).TargetPath 'its shortcut now starts the launcher'
  Assert-True (Test-Path -LiteralPath $upgraded.icon) 'it has an icon now'
  Assert-Cli (Invoke-Cli @('doctor')) 0 'No problems found' 'doctor: all fine after rebuild -All'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.legacy', '-DeleteData')) 0 'Removed' 'remove Legacy'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.mover', '-DeleteData')) 0 'Removed' 'remove Mover'

  # -------------------------------------------------------------------------
  Write-Section 'Removing'
  Assert-Cli (Invoke-Cli @('remove', 'Home')) 1 'more than one' 'an ambiguous name is refused'
  Assert-Cli (Invoke-Cli @('remove', 'Nope')) 1 "no profile called" 'an unknown profile is refused'
  $r = Invoke-Cli @('remove', 'Work')
  Assert-Cli $r 0 'Removed "Fake App Work"' 'remove Work'
  Assert-True (-not (Test-Path -LiteralPath $workLink)) 'the shortcut is gone'
  Assert-True (-not (Test-Path -LiteralPath $workIcon)) 'the icon is gone'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome 'profiles\fakeapp.work.json'))) 'the record is gone'
  Assert-True (Test-Path -LiteralPath (Join-Path $workData '.twinbar-profile')) 'the sign-in data is kept'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-ShortcutDir', $menu)) 0 'kept from before' 'making it again reuses the kept data'
  Assert-Cli (Invoke-Cli @('remove', 'Fake App Work', '-DeleteData')) 0 'Sign-in data: moved to the Recycle Bin' 'remove by full name with -DeleteData'
  Assert-True (-not (Test-Path -LiteralPath $workData)) 'the data folder is gone'

  $sideLink = Join-Path $menu 'Fake App Side.lnk'
  Save-ShellLink -Path $sideLink -TargetPath $stdExe -AppUserModelId 'Someone.Else'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.side')) 0 'left .* alone' "a shortcut that isn't Twinbar's is left alone"
  Assert-True (Test-Path -LiteralPath $sideLink) 'that shortcut is still there'
  Assert-True (Test-Path -LiteralPath (Join-Path $existing 'keep.txt')) 'the adopted data is kept'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.home', '-DeleteData')) 0 'Removed' 'remove by id'
  Assert-Cli (Invoke-Cli @('remove', 'otherapp.home', '-DeleteData')) 0 'Removed' 'remove the second app'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.plain', '-DeleteData')) 0 'Removed' 'remove the plain one'
  Assert-Cli (Invoke-Cli @('list')) 0 'No profiles yet' 'no profiles left'

  # -------------------------------------------------------------------------
  Write-Section 'Proxy and IP check'
  Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TestNet.cs'))) -Language CSharp
  $socksProxy = New-Object TestProxy $true
  $httpProxy = New-Object TestProxy $false
  $ipService = New-Object TestIpService '{"ip":"203.0.113.7","city":"Testville","country":"ZZ","org":"AS64500 Test Net"}'
  $closed = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $closed.Start(); $closedPort = $closed.LocalEndpoint.Port; $closed.Stop()
  $script:extraEnv['TWINBAR_IP_URL'] = "http://127.0.0.1:$($ipService.Port)/json"
  $socksUrl = "socks5://127.0.0.1:$($socksProxy.Port)"
  try {
    Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Routed', '-Proxy', 'socks4://127.0.0.1:1080')) 1 'proxy must look like' 'new with a socks4 proxy fails'
    $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Routed', '-Proxy', $socksUrl)
    Assert-Cli $r 0 ([regex]::Escape("via $socksUrl")) 'new with a SOCKS5 proxy'
    Assert-Cli $r 0 "can't use a SOCKS proxy.*use http://" 'with the tip to prefer an HTTP proxy'
    $routed = Read-Record 'fakeapp.routed'
    Assert-Equal $socksUrl $routed.proxy 'the record has the proxy'
    $routedData = $routed.dataDir
    [IO.File]::WriteAllText((Join-Path $routedData 'stay.txt'), 'keep running')
    Assert-Cli (Invoke-Cli @('open', 'Routed')) 0 'Opening' 'open it'
    $launchedFile = Join-Path $routedData 'launched.txt'
    Assert-True (Wait-Until { Test-Path -LiteralPath $launchedFile } 20) 'it started'
    if (Test-Path -LiteralPath $launchedFile) {
      $lines = [IO.File]::ReadAllLines($launchedFile)
      $commandLine = @($lines | Where-Object { $_ -like 'commandline=*' })[0]
      Assert-True ($commandLine.Contains("--proxy-server=$socksUrl")) 'the app was given the proxy' $commandLine
      Assert-True ($commandLine.Contains('"--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost"')) 'and told not to look names up itself'
      Assert-Equal "all_proxy=$socksUrl" (@($lines | Where-Object { $_ -like 'all_proxy=*' })[0]) 'and ALL_PROXY for code outside Chromium'
      Assert-Equal 'https_proxy=' (@($lines | Where-Object { $_ -like 'https_proxy=*' })[0]) "but no HTTPS_PROXY: most code can't use a SOCKS address there"
    }
    $launcherLog = Join-Path $twHome 'logs\launcher.log'
    Assert-True (Wait-Until { [IO.File]::ReadAllText($launcherLog) -match 'fakeapp\.routed: looking after process' } 15) 'the launcher found the app, proxy switches and all'
    Remove-Item -LiteralPath (Join-Path $routedData 'stay.txt')
    $quit = Wait-Until { @(Get-ProcessesFor $routedData).Count -eq 0 -and @(Get-LaunchersFor 'fakeapp.routed').Count -eq 0 } 30
    $why = 'app processes: {0}; launchers: {1}; log: {2}' -f @(Get-ProcessesFor $routedData).Count, @(Get-LaunchersFor 'fakeapp.routed').Count,
      ((Get-Content -LiteralPath (Join-Path $twHome 'logs\launcher.log') -Tail 4 -ErrorAction SilentlyContinue) -join ' | ')
    Assert-True $quit 'it quit, and its launcher too' $why

    $r = Invoke-Cli @('ip', 'Routed', '-Json')
    Assert-Equal 0 $r.Code 'ip -Json'
    $ipRows = @((ConvertFrom-Json $r.Out) | ForEach-Object { $_ })
    Assert-Equal 2 $ipRows.Count 'ip: through the proxy, and without one'
    if ($ipRows.Count -eq 2) {
      Assert-True ($ipRows[0].ok -and $ipRows[0].ip -eq '203.0.113.7' -and $ipRows[0].where -eq 'Testville, ZZ' -and $ipRows[0].network -eq 'AS64500 Test Net') 'ip: the address, place and network the service saw' ($r.Out -replace '\s+', ' ')
      Assert-True ($ipRows[1].ok -and $ipRows[1].proxy -eq '') 'ip: and without a proxy'
    }
    Assert-True ($socksProxy.Requests() -contains "127.0.0.1:$($ipService.Port)") 'ip: the check went through the SOCKS5 proxy, like the profile' (($socksProxy.Requests()) -join ', ')
    Assert-Cli (Invoke-Cli @('ip', 'Routed')) 0 "through $([regex]::Escape($socksUrl)):\s+IP 203\.0\.113\.7\s+Testville, ZZ" 'ip: as text'
    $r = Invoke-Cli @('doctor', 'Routed')
    Assert-Cli $r 0 'proxy: .* answers' 'doctor: the proxy answers'
    Assert-Cli $r 0 "note  some apps' code outside Chromium" 'doctor: with the SOCKS note'

    $httpUrl = "http://127.0.0.1:$($httpProxy.Port)"
    $r = Invoke-Cli @('change', 'Routed', '-Proxy', $httpUrl)
    Assert-Cli $r 0 'via http://' 'change to an HTTP proxy'
    Assert-True ($r.Out -notmatch 'Tip:') 'no SOCKS tip for an HTTP proxy'
    Assert-Cli (Invoke-Cli @('ip', 'Routed')) 0 'IP 203\.0\.113\.7' 'ip through the HTTP proxy'
    Assert-True ($httpProxy.Requests() -contains "127.0.0.1:$($ipService.Port)") 'ip: the check went through the HTTP proxy' (($httpProxy.Requests()) -join ', ')
    Remove-Item -LiteralPath $launchedFile -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText((Join-Path $routedData 'stay.txt'), 'keep running')
    Assert-Cli (Invoke-Cli @('open', 'Routed')) 0 'Opening' 'open it with the HTTP proxy'
    if (Wait-Until { Test-Path -LiteralPath $launchedFile } 20) {
      $lines = [IO.File]::ReadAllLines($launchedFile)
      Assert-Equal "https_proxy=$httpUrl" (@($lines | Where-Object { $_ -like 'https_proxy=*' })[0]) 'with an HTTP proxy, HTTPS_PROXY too'
    } else {
      Assert-True $false 'it started with the HTTP proxy'
    }
    [void](Wait-Until { [IO.File]::ReadAllText($launcherLog) -match '(?s)fakeapp\.routed: looking after process.*fakeapp\.routed: looking after process' } 15)
    Remove-Item -LiteralPath (Join-Path $routedData 'stay.txt')
    Assert-True (Wait-Until { @(Get-ProcessesFor $routedData).Count -eq 0 -and @(Get-LaunchersFor 'fakeapp.routed').Count -eq 0 } 30) 'it quit again'

    Assert-Cli (Invoke-Cli @('change', 'Routed', '-Proxy', "socks5://127.0.0.1:$closedPort")) 0 'Changed' 'change to a proxy that is down'
    $r = Invoke-Cli @('ip', 'Routed')
    Assert-Cli $r 0 "can't get out" "ip: through a proxy that's down, nothing gets out"
    Assert-Cli $r 0 'kill switch' 'ip: and it says the profile is offline too'
    Assert-Cli (Invoke-Cli @('doctor', 'Routed')) 1 "doesn't answer.*kill switch" "doctor: the proxy doesn't answer"
    Assert-Cli (Invoke-Cli @('change', 'Routed', '-Proxy', 'none')) 0 'Changed' 'change -Proxy none'
    $plainAgain = Read-Record 'fakeapp.routed'
    Assert-True ($plainAgain.proxy -eq '' -and $plainAgain.extraArgs -eq '') 'no proxy, and no proxy switches, any more'
    $r = Invoke-Cli @('ip', '-Json')
    Assert-Equal 1 @((ConvertFrom-Json $r.Out) | ForEach-Object { $_ }).Count 'ip without a profile: just the direct one'
    Assert-Cli (Invoke-Cli @('remove', 'fakeapp.routed', '-DeleteData')) 0 'Removed' 'remove Routed'

    # Finding proxies: the two test proxies on "usual" ports, a closed port, and
    # Windows' proxy setting pointing at the HTTP one.
    $httpUrl = "http://127.0.0.1:$($httpProxy.Port)"
    $script:extraEnv['TWINBAR_PROXY_PORTS'] = "$($socksProxy.Port),$closedPort,$($httpProxy.Port)"
    $script:extraEnv['TWINBAR_SYSTEM_PROXY'] = "http=127.0.0.1:$($httpProxy.Port);https=127.0.0.1:$($httpProxy.Port)"
    $r = Invoke-Cli @('proxies', '-Json')
    Assert-Equal 0 $r.Code 'proxies -Json'
    $foundProxies = @((ConvertFrom-Json $r.Out) | ForEach-Object { $_ })
    Assert-Equal "$httpUrl|$socksUrl" (@($foundProxies | ForEach-Object { $_.url }) -join '|') 'proxies: the HTTP one first, then the SOCKS5 one; nothing on the closed port' ($r.Out -replace '\s+', ' ')
    if ($foundProxies.Count -eq 2) {
      Assert-True ($foundProxies[0].works -and $foundProxies[1].works) 'proxies: both get out'
      Assert-True ($foundProxies[0].windowsSetting -and -not $foundProxies[1].windowsSetting) "proxies: the HTTP one is Windows' proxy setting"
    }
    $r = Invoke-Cli @('proxies')
    Assert-Cli $r 0 "HTTP, works \(Windows' proxy setting\)" 'proxies as text'
    Assert-Cli $r 0 ([regex]::Escape("twinbar change PROFILE -Proxy $httpUrl")) 'proxies: says how to use the HTTP one'
    $script:extraEnv['TWINBAR_PROXY_PORTS'] = "$closedPort"
    $script:extraEnv['TWINBAR_SYSTEM_PROXY'] = 'none'
    Assert-Cli (Invoke-Cli @('proxies')) 0 'No proxy found' 'proxies: none found'
  } finally {
    $script:extraEnv.Remove('TWINBAR_IP_URL')
    $script:extraEnv.Remove('TWINBAR_PROXY_PORTS')
    $script:extraEnv.Remove('TWINBAR_SYSTEM_PROXY')
    $socksProxy.Stop(); $httpProxy.Stop(); $ipService.Stop()
  }

  # -------------------------------------------------------------------------
  Write-Section 'Finding apps'
  [void][IO.Directory]::CreateDirectory((Join-Path $startMenu 'Vendor'))
  Save-ShellLink -Path (Join-Path $startMenu 'Fake App.lnk') -TargetPath $stdExe
  Save-ShellLink -Path (Join-Path $startMenu 'Vendor\Fake Squirrel.lnk') -TargetPath $sqExe
  Save-ShellLink -Path (Join-Path $startMenu 'Not Electron.lnk') -TargetPath (Join-Path $plain 'FakeApp.exe')
  Save-ShellLink -Path (Join-Path $startMenu 'Fake App Someone.lnk') -TargetPath $launcher -Arguments 'fakeapp.someone' -AppUserModelId 'Twinbar.fakeapp.someone'
  $r = Invoke-Cli @('apps', '-Json')
  Assert-Equal 0 $r.Code 'apps -Json'
  $apps = @((ConvertFrom-Json $r.Out) | ForEach-Object { $_ })
  Assert-Equal 'standard' (@($apps | Where-Object { $_.Name -eq 'Fake App' }) | ForEach-Object { $_.Kind }) 'apps: a normal install in the Start menu'
  Assert-Equal 'squirrel' (@($apps | Where-Object { $_.Name -eq 'Fake Squirrel' }) | ForEach-Object { $_.Kind }) 'apps: a Squirrel install, in a Start menu folder'
  Assert-Equal 0 @($apps | Where-Object { $_.Name -eq 'Not Electron' }).Count "apps: a program that isn't Electron is left out"
  Assert-Equal 0 @($apps | Where-Object { $_.Source -like '*Fake App Someone*' }).Count "apps: Twinbar's own profiles are left out"
  Assert-Cli (Invoke-Cli @('apps')) 0 'Fake Squirrel\s+squirrel' 'apps shows a table'

  # -------------------------------------------------------------------------
  Write-Section 'Telegram'
  $tgDir = Join-Path $root 'apps\Telegram Desktop'
  New-FakeTelegram $tgDir
  $tgExe = Join-Path $tgDir 'Telegram.exe'
  $tgApp = Resolve-ElectronApp $tgDir
  Assert-Equal 'Telegram|telegram|telegram|standard' ('{0}|{1}|{2}|{3}' -f $tgApp.Name, $tgApp.Id, $tgApp.Family, $tgApp.Kind) 'Telegram Desktop is recognised, from its folder past Updater.exe'
  [void][IO.Directory]::CreateDirectory((Join-Path $startMenu 'Telegram Desktop'))
  Save-ShellLink -Path (Join-Path $startMenu 'Telegram Desktop\Telegram.lnk') -TargetPath $tgExe
  $apps = @((ConvertFrom-Json (Invoke-Cli @('apps', '-Json')).Out) | ForEach-Object { $_ })
  Assert-Equal 'telegram' (@($apps | Where-Object { $_.Name -eq 'Telegram' }) | ForEach-Object { $_.Family }) 'apps: Telegram Desktop in the Start menu'
  Assert-Cli (Invoke-Cli @('new', '-App', $tgExe, '-Name', 'Work', '-Proxy', 'http://127.0.0.1:9')) 1 'proxy setting of its own' "Telegram: Twinbar's proxy is refused (Telegram has its own)"
  Assert-Cli (Invoke-Cli @('new', '-App', $tgExe, '-Name', 'Work', '-Appearance', 'dark')) 1 'its own theme' 'Telegram: light/dark is refused (Telegram has its own)'
  Assert-Cli (Invoke-Cli @('new', '-App', $tgExe, '-Name', 'Work', '-AppArgs', '-workdir C:\x')) 1 "can't set the data folder" "Telegram: the arguments can't move the data folder"
  # By the name twinbar apps shows, found through the Start menu.
  $r = Invoke-Cli @('new', '-App', 'telegram', '-Name', 'Work', '-Color', 'teal', '-AppArgs', '-startintray')
  Assert-Cli $r 0 'Made "Telegram Work"' 'new Telegram Work, giving -App the name from twinbar apps'
  Assert-True ($r.Out -match 'tg://' -and $r.Out -match 'Launch Telegram when system starts') 'with a note on links and start-up' $r.Out
  $tg = Read-Record 'telegram.work'
  Assert-Equal 'telegram|-startintray' ('{0}|{1}' -f $tg.family, $tg.extraArgs) "the record: family telegram, and no Chromium switches"
  $tgOptions = Join-Path $tg.dataDir 'tdata\experimental_options.json'
  Assert-True ((Test-Path -LiteralPath $tgOptions) -and ([IO.File]::ReadAllText($tgOptions) | ConvertFrom-Json).'skip-url-scheme-register' -eq $true) "links stay with the main Telegram: skip-url-scheme-register is on"
  # An option Telegram keeps there already stays, and the launcher puts ours back.
  [IO.File]::WriteAllText($tgOptions, '{"some-option": 5}')
  [IO.File]::WriteAllText((Join-Path $tg.dataDir 'stay.txt'), 'keep running')
  [IO.File]::WriteAllText((Join-Path $tg.dataDir 'window.txt'), 'show a window')
  Assert-Cli (Invoke-Cli @('open', 'Telegram Work')) 0 'Opening Telegram Work' 'open Telegram Work'
  $tgLaunched = Join-Path $tg.dataDir 'launched.txt'
  if (Wait-Until { Test-Path -LiteralPath $tgLaunched } 20) {
    $lines = [IO.File]::ReadAllLines($tgLaunched)
    $commandLine = @($lines | Where-Object { $_ -like 'commandline=*' })[0]
    Assert-True ($commandLine.Contains("-workdir ""$($tg.dataDir)""") -and $commandLine -notmatch '--user-data-dir' -and $commandLine.EndsWith('-startintray')) 'Telegram gets -workdir with the profile folder, then its extra arguments' $commandLine
  } else {
    Assert-True $false 'Telegram started'
  }
  $saved = [IO.File]::ReadAllText($tgOptions) | ConvertFrom-Json
  Assert-True ($saved.'skip-url-scheme-register' -eq $true -and $saved.'some-option' -eq 5) "the launcher sets the link option before each start, keeping Telegram's other options" ([IO.File]::ReadAllText($tgOptions))
  Assert-True (Wait-Until { @(Get-ProcessesFor $tg.dataDir).Count -gt 0 } 10) 'the running Telegram is found by its -workdir'
  $tgLog = Join-Path $twHome 'logs\launcher.log'
  Assert-True (Wait-Until { [IO.File]::ReadAllText($tgLog) -match 'telegram\.work: looking after process' } 15) 'the launcher found it'
  $script:tgWindow = [IntPtr]::Zero
  $tgShown = Wait-Until {
    foreach ($p in @(Get-ProcessesFor $tg.dataDir)) {
      $h = ([Diagnostics.Process]::GetProcessById([int]$p.ProcessId)).MainWindowHandle
      if ($h -ne [IntPtr]::Zero) { $script:tgWindow = $h; return $true }
    }
    return $false
  } 15
  if ($tgShown) {
    Assert-True (Wait-Until { [TwinbarInterop.Shell]::GetWindowAppId($script:tgWindow) -eq 'Twinbar.telegram.work' } 10) "Telegram's window carries the profile's ID, so it gets a taskbar button of its own" ("window ID: '{0}'" -f [TwinbarInterop.Shell]::GetWindowAppId($script:tgWindow))
  } else {
    Assert-True $false "Telegram showed its window"
  }
  Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq 'telegram.work' })[0]).status 'list shows Telegram Work running'
  Assert-Cli (Invoke-Cli @('clean', 'Telegram Work')) 0 'Manage local storage' "clean: Telegram's cache is Telegram's to clear"
  Remove-Item -LiteralPath (Join-Path $tg.dataDir 'stay.txt')
  Assert-True (Wait-Until { @(Get-ProcessesFor $tg.dataDir).Count -eq 0 -and @(Get-LaunchersFor 'telegram.work').Count -eq 0 } 30) 'Telegram quit, and its launcher too'
  Remove-Item -LiteralPath (Join-Path $tg.dataDir 'window.txt'), $tgLaunched -ErrorAction SilentlyContinue
  Assert-Cli (Invoke-Cli @('change', 'Telegram Work', '-Proxy', 'http://127.0.0.1:9')) 1 'proxy setting of its own' "change: Twinbar's proxy is refused for Telegram too"
  Assert-Cli (Invoke-Cli @('change', 'Telegram Work', '-Color', 'red')) 0 'Changed' 'change its colour'
  Assert-Cli (Invoke-Cli @('remove', 'Telegram Work', '-DeleteData')) 0 'Removed' 'remove Telegram Work'
  Remove-Item -LiteralPath (Join-Path $startMenu 'Telegram Desktop') -Recurse -Force

  # -------------------------------------------------------------------------
  Write-Section 'Storage, options and backups'
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $backupDir = Join-Path $root 'backups'
  $script:extraEnv['TWINBAR_BACKUP_DIR'] = $backupDir
  try {
    $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Kept', '-Color', 'green', '-Proxy', 'http://127.0.0.1:9', '-AppArgs', '--disable-gpu --lang=fa', '-Environment', 'TWINBAR_TEST_VAR=hello; OTHER=1')
    Assert-Cli $r 0 'Made' 'new with extra arguments and environment variables'
    $kept = Read-Record 'fakeapp.kept'
    Assert-Equal '--disable-gpu --lang=fa|TWINBAR_TEST_VAR=hello;OTHER=1' ('{0}|{1}' -f $kept.userArgs, $kept.userEnv) 'the record has them'
    Assert-True ($kept.extraArgs.StartsWith('--proxy-server=') -and $kept.extraArgs.EndsWith('--disable-gpu --lang=fa')) "the arguments come after Twinbar's own switches" $kept.extraArgs
    Assert-Cli (Invoke-Cli @('change', 'Kept', '-AppArgs', '--user-data-dir=C:\x')) 1 "can't set the data folder" 'the arguments may not move the data folder'
    Assert-Cli (Invoke-Cli @('change', 'Kept', '-AppArgs', '--title="x')) 1 'never closed' 'the arguments need closed quotes'
    Assert-Cli (Invoke-Cli @('change', 'Kept', '-Environment', 'NOT A PAIR')) 1 'NAME=value' 'environment variables must be NAME=value'

    # Data as an Electron app keeps it: sign-in and settings, and caches (also in a partition).
    $keptData = $kept.dataDir
    $made = [ordered]@{
      'Local Storage\leveldb\000003.log' = 'local storage'; 'Network\Cookies' = 'cookies'; 'Preferences' = '{"x":1}'
      'Cache\Cache_Data\data_1' = ('c' * 50000); 'Code Cache\js\index' = ('j' * 20000); 'GPUCache\data_0' = ('g' * 10000)
      'Partitions\work\Cache\Cache_Data\f_000001' = ('p' * 30000); 'Partitions\work\IndexedDB\db.leveldb\000005.ldb' = 'indexed'
      'SingletonLock' = 'lock'
    }
    foreach ($f in $made.Keys) {
      $path = Join-Path $keptData $f
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
      [IO.File]::WriteAllText($path, $made[$f])
    }

    [IO.File]::WriteAllText((Join-Path $keptData 'stay.txt'), 'keep running')
    Assert-Cli (Invoke-Cli @('open', 'Kept')) 0 'Opening' 'open it'
    $launchedFile = Join-Path $keptData 'launched.txt'
    if (Wait-Until { Test-Path -LiteralPath $launchedFile } 20) {
      $lines = [IO.File]::ReadAllLines($launchedFile)
      Assert-Equal 'testvar=hello' (@($lines | Where-Object { $_ -like 'testvar=*' })[0]) 'the app gets its environment variables'
      Assert-True ((@($lines | Where-Object { $_ -like 'commandline=*' })[0]).EndsWith('--disable-gpu --lang=fa')) 'and its extra arguments'
    } else {
      Assert-True $false 'it started'
    }
    Assert-Cli (Invoke-Cli @('clean', 'Kept')) 1 'is running' "clean: not while it's running"
    Assert-Cli (Invoke-Cli @('backup', 'Kept')) 1 'is running' "backup: not while it's running"
    Remove-Item -LiteralPath (Join-Path $keptData 'stay.txt')
    Assert-True (Wait-Until { @(Get-ProcessesFor $keptData).Count -eq 0 -and @(Get-LaunchersFor 'fakeapp.kept').Count -eq 0 } 30) 'it quit'
    Remove-Item -LiteralPath $launchedFile -ErrorAction SilentlyContinue

    $r = Invoke-Cli @('storage', 'Kept', '-Json')
    $st = @((ConvertFrom-Json $r.Out) | ForEach-Object { $_ })
    Assert-True ($st.Count -eq 1 -and $st[0].cache -eq 110000 -and $st[0].total -gt 110000) 'storage: the size, and the cache in it (partitions too)' ($r.Out -replace '\s+', ' ')
    Assert-Cli (Invoke-Cli @('storage')) 0 'Fake App Kept\s+\d+ KB\s+107 KB' 'storage as a table'

    # Back up, then restore next to it and in its place.
    Assert-Cli (Invoke-Cli @('backup', 'Kept')) 0 'Backed up "Fake App Kept"' 'backup'
    $zips = @(Get-ChildItem -LiteralPath $backupDir -Filter 'fakeapp.kept-*.zip' -ErrorAction SilentlyContinue)
    Assert-Equal 1 $zips.Count 'backup: a zip in the backup folder'
    if ($zips.Count) {
      $zipFile = $zips[0].FullName
      $zip = [IO.Compression.ZipFile]::OpenRead($zipFile)
      $names = @($zip.Entries | ForEach-Object { $_.FullName })
      $zip.Dispose()
      Assert-True ($names -contains 'twinbar-backup.json' -and $names -contains 'data/Network/Cookies' -and $names -contains 'data/Partitions/work/IndexedDB/db.leveldb/000005.ldb') 'backup: the settings, sign-in and data' ($names -join ', ')
      Assert-Equal 0 @($names | Where-Object { $_ -match '/(Cache|Code Cache|GPUCache)/|SingletonLock|\.twinbar-profile' }).Count 'backup: without caches, lock files or the marker'
      Assert-Cli (Invoke-Cli @('restore', $zipFile)) 1 'already a profile' "restore: not over a profile that's still there"
      Assert-Cli (Invoke-Cli @('restore', $zipFile, '-Name', 'Copy')) 0 'Made "Fake App Copy"' 'restore under another name'
      $copy = Read-Record 'fakeapp.copy'
      Assert-Equal '#30A46C|http://127.0.0.1:9|--disable-gpu --lang=fa|TWINBAR_TEST_VAR=hello;OTHER=1|C' ('{0}|{1}|{2}|{3}|{4}' -f $copy.color, $copy.proxy, $copy.userArgs, $copy.userEnv, $copy.badge) 'restore: with the look, proxy and options, and a badge for its name'
      Assert-Equal 'cookies' ([IO.File]::ReadAllText((Join-Path $copy.dataDir 'Network\Cookies'))) 'restore: with the data'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $copy.dataDir 'Cache'))) 'restore: and no cache'
      Assert-Cli (Invoke-Cli @('remove', 'Kept', '-DeleteData')) 0 'Removed' 'remove Kept with its data'
      $r = Invoke-Cli @('restore', $zipFile)
      Assert-Cli $r 0 'Made "Fake App Kept"' 'restore it as it was'
      Assert-True ($r.Out -notmatch 'another Windows account') 'restore: from this account, no note about signing in again'
      Assert-Equal 'indexed' ([IO.File]::ReadAllText((Join-Path $keptData 'Partitions\work\IndexedDB\db.leveldb\000005.ldb'))) 'restore: partitions too'
    }

    # Clearing the cache.
    [void][IO.Directory]::CreateDirectory((Join-Path $keptData 'Code Cache\js'))
    [IO.File]::WriteAllText((Join-Path $keptData 'Code Cache\js\index'), ('j' * 20000))
    Assert-Cli (Invoke-Cli @('clean', 'Kept')) 0 'Cleared 20 KB of cache from Fake App Kept' 'clean'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $keptData 'Code Cache')) -and (Test-Path -LiteralPath (Join-Path $keptData 'Network\Cookies'))) 'clean: the cache went, the sign-in stayed'

    # A backup with a file that would land outside the data folder is refused.
    $evil = Join-Path $root 'evil.zip'
    $zip = [IO.Compression.ZipFile]::Open($evil, 'Create')
    $w = New-Object IO.StreamWriter($zip.CreateEntry('twinbar-backup.json').Open())
    $w.Write('{"format":1,"user":"x","profile":' + [IO.File]::ReadAllText((Join-Path $twHome 'profiles\fakeapp.copy.json')) + '}')
    $w.Dispose()
    $w = New-Object IO.StreamWriter($zip.CreateEntry('data/../../escaped.txt').Open())
    $w.Write('no')
    $w.Dispose()
    $zip.Dispose()
    Assert-Cli (Invoke-Cli @('restore', $evil, '-Name', 'Evil')) 1 'outside the profile' 'restore: a file outside the data folder is refused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome 'data\escaped.txt'))) 'restore: and nothing lands there'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome 'profiles\fakeapp.evil.json')) -and -not (Test-Path -LiteralPath (Join-Path $twHome 'data\fakeapp\evil'))) 'restore: and nothing is left behind'
    Assert-Cli (Invoke-Cli @('restore', (Join-Path $root 'nope.zip'))) 1 "there's no file" 'restore: a missing file'
    Assert-Cli (Invoke-Cli @('restore', $cli)) 1 "isn't a Twinbar backup" "restore: a file that isn't a backup"

    foreach ($id in 'fakeapp.kept', 'fakeapp.copy') { Assert-Cli (Invoke-Cli @('remove', $id, '-DeleteData')) 0 'Removed' "remove $id" }
  } finally {
    $script:extraEnv.Remove('TWINBAR_BACKUP_DIR')
  }

  # -------------------------------------------------------------------------
  Write-Section 'Updates'
  # A stand-in for GitHub: the newest release, its SHA256SUMS, and an installer that
  # writes down how it was started.
  $updateServer = New-Object TestWebServer
  $fakeSetup = Join-Path $root 'build\FakeSetup.exe'
  Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class TwinbarFakeSetup {
  public static int Main(string[] args) {
    File.WriteAllText(Environment.GetEnvironmentVariable("TWINBAR_TEST_SETUP_LOG"), String.Join(" ", args));
    return 0;
  }
}
'@ -Language CSharp -OutputAssembly $fakeSetup -OutputType WindowsApplication
  $setupBytes = [IO.File]::ReadAllBytes($fakeSetup)
  $setupHash = (Get-FileHash -LiteralPath $fakeSetup -Algorithm SHA256).Hash.ToLowerInvariant()
  $newVersion = '9.9.9'
  $setupName = "Twinbar-Setup-$newVersion.exe"
  $releaseFor = {
    param([string] $Tag, [string] $Prefix)
    $v = $Tag.TrimStart('v')
    ConvertTo-Json -Depth 4 -InputObject ([ordered]@{
        tag_name = $Tag; html_url = $updateServer.Url("/release/$Tag"); body = "Better things.`r`n- one`r`n- two"
        assets   = @(
          [ordered]@{ name = "Twinbar-Setup-$v.exe"; size = $setupBytes.Length; browser_download_url = $updateServer.Url("$Prefix/Twinbar-Setup-$v.exe") },
          [ordered]@{ name = 'SHA256SUMS'; size = 200; browser_download_url = $updateServer.Url("$Prefix/SHA256SUMS") }
        )
      })
  }
  $updateServer.PutText('/good/latest', (& $releaseFor "v$newVersion" '/good'))
  $updateServer.PutText('/good/SHA256SUMS', "$('cd' * 32)  twinbar-$newVersion.zip`n$setupHash  $setupName`n")
  $updateServer.Redirect("/good/$setupName", $updateServer.Url('/cdn/setup.exe'))
  $updateServer.Put('/cdn/setup.exe', $setupBytes)
  $updateServer.PutText('/same/latest', (& $releaseFor "v$version" '/same'))
  $updateServer.PutText('/bad/latest', (& $releaseFor "v$newVersion" '/bad'))
  $updateServer.PutText('/bad/SHA256SUMS', "$('ef' * 32)  $setupName`n")
  $updateServer.Put("/bad/$setupName", $setupBytes)
  $updateServer.PutText('/elsewhere/latest', (& $releaseFor "v$newVersion" '/good').Replace("127.0.0.1:$($updateServer.Port)/good/Twinbar", "127.0.0.2:$($updateServer.Port)/good/Twinbar"))
  try {
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/good/latest')
    $r = Invoke-Cli @('update', '-Check')
    Assert-Cli $r 0 "Twinbar 9\.9\.9 is out \(you have $([regex]::Escape($version))\)" 'update -Check: a newer version'
    Assert-True ($r.Out -match 'Run "twinbar update"') 'update -Check: says how to install it'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome 'updates'))) 'update -Check downloads nothing'
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/same/latest')
    Assert-Cli (Invoke-Cli @('update', '-Check')) 0 'is the newest version' 'update -Check: up to date'
    Assert-Cli (Invoke-Cli @('update')) 0 'is the newest version' 'update: nothing to do when up to date'
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/missing')
    Assert-Cli (Invoke-Cli @('update', '-Check')) 1 "couldn't ask GitHub" "update: GitHub doesn't answer"

    # A Twinbar the installer put there: a copy with an uninstaller next to it.
    $setupDir = Join-Path $root 'setup install'
    [void][IO.Directory]::CreateDirectory($setupDir)
    Copy-Item -LiteralPath $cli -Destination $setupDir
    [IO.File]::WriteAllText((Join-Path $setupDir 'unins000.exe'), 'stand-in')
    $setupScript = Join-Path $setupDir 'twinbar.ps1'
    $setupLog = Join-Path $root 'setup-args.txt'
    $script:extraEnv['TWINBAR_TEST_SETUP_LOG'] = $setupLog
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/good/latest')
    $r = Invoke-Cli @('update') $setupScript
    Assert-Cli $r 0 'its SHA-256 matches' 'update: the installer is downloaded and checked'
    Assert-Cli $r 0 'Updated Twinbar to 9\.9\.9' 'update: and run'
    Assert-Equal '/SILENT /SUPPRESSMSGBOXES /NORESTART' $(if (Test-Path -LiteralPath $setupLog) { [IO.File]::ReadAllText($setupLog) }) 'update: quietly, over the installed copy'
    Assert-True ($updateServer.Requests() -contains '/cdn/setup.exe') 'update: following the redirect to the file, as GitHub sends'
    Assert-Equal $setupName (@(Get-ChildItem -LiteralPath (Join-Path $twHome 'updates') | ForEach-Object { $_.Name }) -join ',') 'update: only the checked installer is kept'

    Remove-Item -LiteralPath $setupLog -ErrorAction SilentlyContinue
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/bad/latest')
    Assert-Cli (Invoke-Cli @('update') $setupScript) 1 'SHA-256 differs' "update: an installer that doesn't match is refused"
    Assert-True (-not (Test-Path -LiteralPath $setupLog)) "update: and isn't run"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome "updates\$setupName.part"))) 'update: and is deleted'
    $script:extraEnv['TWINBAR_UPDATE_URL'] = $updateServer.Url('/elsewhere/latest')
    Assert-Cli (Invoke-Cli @('update') $setupScript) 1 'somewhere other than' 'update: a download from anywhere else is refused'
    Assert-True (-not (Test-Path -LiteralPath $setupLog)) 'update: and nothing is run'
  } finally {
    foreach ($k in 'TWINBAR_UPDATE_URL', 'TWINBAR_TEST_SETUP_LOG') { $script:extraEnv.Remove($k) }
  }

  # -------------------------------------------------------------------------
  Write-Section 'The window'
  Initialize-Forms
  [Windows.Forms.Application]::EnableVisualStyles()
  $script:GuiNoDialogs = $true
  Set-TwinbarSetting 'checkForUpdates' $false # no check of its own when the window opens
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Listed', '-Color', 'teal')) 0 'Made' 'a profile to list'
  $mainForm = New-MainForm
  $mainForm.Opacity = 0
  $mainForm.ShowInTaskbar = $false
  $mainForm.Show()
  [Windows.Forms.Application]::DoEvents()
  try {
    Assert-Equal 'Fake App Listed' (@($script:Gui.List.Items | ForEach-Object { $_.Text }) -join ',') 'the window lists the profiles'
    Assert-Equal 'ready' $script:Gui.List.Items[0].SubItems[1].Text 'with their status'
    Assert-Equal 1 $script:Gui.Images.Images.Count 'and their icons'
    Assert-True ($script:Gui.Status.Text -match '1 profile') 'the status bar counts them'
    Assert-True (-not $script:Gui.Buttons.Edit.Enabled) 'Edit is off with nothing selected'
    $script:Gui.List.Items[0].Selected = $true
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($script:Gui.Buttons.Edit.Enabled -and $script:Gui.Buttons.Remove.Enabled -and $script:Gui.Buttons.Ip.Enabled) 'Edit, Remove and Check IP come on with a profile selected'

    $script:Gui.Apps = @([pscustomobject]@{ Name = 'Fake App'; Kind = 'standard'; Source = $stdExe; LaunchExe = $stdExe; Id = 'fakeapp' })
    $dialog = New-ProfileDialog $null
    Assert-Equal 'Fake App' ([string]$dialog.App.SelectedItem) 'New: the app is picked'
    $dialog.Name.Text = 'Windowed'
    Assert-Equal (Resolve-ProfileColor '' 'fakeapp.windowed') (Get-ColorItemHex ([string]$dialog.Color.SelectedItem)) 'New: the colour follows the name, as on the command line'
    $dialog.Color.SelectedItem = 'Purple'
    $dialog.Proxy.Text = 'socks5://127.0.0.1:9'
    Update-ProfilePreview $dialog
    Assert-True ($null -ne $dialog.Preview.Image) 'New: the icon is previewed'
    Assert-True ((Get-HueDistance (Get-MainHue (New-Object Drawing.Bitmap $dialog.Preview.Image)) 272) -lt 20) 'New: the preview is purple'
    Assert-True (Submit-ProfileDialog $dialog) 'New: Create makes the profile'
    $made = Read-Record 'fakeapp.windowed'
    Assert-Equal '#8E4EC6|W|tint+badge|socks5://127.0.0.1:9' ('{0}|{1}|{2}|{3}' -f $made.color, $made.badge, $made.style, $made.proxy) 'New: with the look and proxy picked in the window'
    $dialog.Form.Dispose()
    Assert-Equal 2 $script:Gui.List.Items.Count 'the list shows the new profile'

    $bad = New-ProfileDialog $null
    $bad.Name.Text = 'Bad!'
    $script:GuiMessages.Clear()
    Assert-True (-not (Submit-ProfileDialog $bad)) 'New: a bad name is refused'
    Assert-True ($script:GuiMessages.Count -and $script:GuiMessages[0] -match '^The profile name may use letters') 'with a message that says why' ($script:GuiMessages -join ' | ')
    $bad.Form.Dispose()

    # Picking Telegram turns off Twinbar's proxy and light/dark: it has its own.
    $tgDialog = New-ProfileDialog $null
    $tgDialog.Proxy.Text = 'http://127.0.0.1:9'
    $otherApps = $tgDialog.AppList.Count
    [void]$tgDialog.AppList.Add([pscustomobject]@{ Name = 'Telegram'; Kind = 'standard'; Family = 'telegram'; Source = 'C:\T\Telegram.exe'; LaunchExe = 'C:\T\Telegram.exe'; Id = 'telegram' })
    [void]$tgDialog.App.Items.Add('Telegram')
    $tgDialog.App.SelectedIndex = $tgDialog.App.Items.Count - 1
    Update-DialogFamily $tgDialog
    Assert-True (-not $tgDialog.Proxy.Enabled -and -not $tgDialog.FindProxy.Enabled -and -not $tgDialog.Appearance.Enabled) 'New: for Telegram, the proxy and light/dark are off'
    Assert-Equal '' $tgDialog.Proxy.Text 'New: and the proxy is cleared'
    if ($otherApps) {
      $tgDialog.App.SelectedIndex = 0
      Update-DialogFamily $tgDialog
      Assert-True ($tgDialog.Proxy.Enabled -and $tgDialog.Appearance.Enabled) 'New: back on for an Electron app'
    }
    $tgDialog.Form.Dispose()

    $row = @($script:Gui.Rows | Where-Object { $_.Id -eq 'fakeapp.windowed' })[0]
    $edit = New-ProfileDialog $row
    Assert-True (-not $edit.Name.Enabled -and -not $edit.App.Enabled) "Edit: the app and name can't change"
    Assert-Equal 'Purple' ([string]$edit.Color.SelectedItem) 'Edit: shows the colour'
    Assert-Equal 'socks5://127.0.0.1:9' $edit.Proxy.Text 'Edit: shows the proxy'
    $edit.Proxy.Text = ''
    Select-ColorItem $edit.Color '#123456'
    Assert-Equal '#123456' ([string]$edit.Color.SelectedItem) 'Edit: a custom colour'
    $edit.Appearance.SelectedItem = 'Dark'
    Assert-True (Submit-ProfileDialog $edit) 'Edit: Save changes it'
    $changedInWindow = Read-Record 'fakeapp.windowed'
    Assert-Equal '#123456|dark|W|' ('{0}|{1}|{2}|{3}' -f $changedInWindow.color, $changedInWindow.appearance, $changedInWindow.badge, $changedInWindow.proxy) 'Edit: with the new look, and the proxy cleared'
    $edit.Form.Dispose()

    $removeDialog = New-RemoveDialog $row
    Assert-True (-not $removeDialog.DeleteData.Checked) 'Remove: keeps the sign-in unless asked'
    $removeDialog.Form.Dispose()

    # Find... next to Proxy: the menu of proxies found, and picking one.
    $proxyDialog = New-ProfileDialog $row
    $menuFound = @([pscustomobject]@{ Url = 'http://127.0.0.1:10809'; Kind = 'HTTP'; State = 'works'; System = $true })
    $proxyMenu = New-ProxyMenu $proxyDialog $menuFound
    Assert-True ($proxyMenu.Items[0].Text -match "^http://127\.0\.0\.1:10809 .*HTTP, works \(Windows' proxy setting\)") 'Find proxy: the menu lists what was found'
    $proxyMenu.Items[0].PerformClick()
    Assert-Equal 'http://127.0.0.1:10809' $proxyDialog.Proxy.Text 'Find proxy: picking one fills in the Proxy field'
    $proxyMenu.Dispose()
    $proxyDialog.Form.Dispose()

    # Arguments and environment variables in the window, the right-click menu, and
    # restoring a backup next to its profile.
    $optionsDialog = New-ProfileDialog $row
    Assert-True ($optionsDialog.AppArgs.Text -eq '' -and $optionsDialog.EnvVars.Text -eq '') 'Edit: no extra arguments or environment variables yet'
    $optionsDialog.AppArgs.Text = '--disable-gpu'
    $optionsDialog.EnvVars.Text = 'A=1; B=2'
    Assert-True (Submit-ProfileDialog $optionsDialog) 'Edit: Save with arguments and environment variables'
    $optionsDialog.Form.Dispose()
    $withOptions = Read-Record 'fakeapp.windowed'
    Assert-Equal '--disable-gpu|A=1;B=2' ('{0}|{1}' -f $withOptions.userArgs, $withOptions.userEnv) 'Edit: they are kept'
    $reopened = New-ProfileDialog (@($script:Gui.Rows | Where-Object { $_.Id -eq 'fakeapp.windowed' })[0])
    Assert-Equal '--disable-gpu|A=1; B=2' ('{0}|{1}' -f $reopened.AppArgs.Text, $reopened.EnvVars.Text) 'Edit: and shown again'
    $reopened.Form.Dispose()
    $profileMenu = New-ProfileMenu
    $menuTexts = @($profileMenu.Items | ForEach-Object { $_.Text })
    Assert-True ($menuTexts -contains 'Open' -and $menuTexts -contains 'Clear cache...' -and $menuTexts -contains 'Back up...' -and $menuTexts -contains 'Remove...') 'right-click: what can be done with a profile' ($menuTexts -join ' | ')
    $profileMenu.Dispose()
    $windowedZip = Join-Path $root 'windowed.zip'
    [void](Invoke-Backup 'fakeapp.windowed' $windowedZip)
    Assert-Equal 'Windowed 2' (Get-FreeRestoreName $windowedZip) 'Restore: next to a profile that is still there, the next free name'

    # Updates in the window, from the same stand-in for GitHub.
    Assert-Equal "Twinbar $version" $script:Gui.Version.Text 'the status bar shows the version'
    $env:TWINBAR_UPDATE_URL = $updateServer.Url('/good/latest')
    $script:GuiMessages.Clear()
    Start-UpdateCheck -Manual
    $checked = Wait-Until { [Windows.Forms.Application]::DoEvents(); $null -eq $script:Gui.Work } 20
    Assert-True ($checked -and $script:Gui.Version.Text -eq "Update to $newVersion" -and $script:Gui.Version.IsLink) 'Check for updates: the status bar offers the new version' "$($script:Gui.Version.Text); $($script:GuiMessages -join ' | ')"
    Assert-True ($script:GuiMessages -contains "Twinbar $newVersion is out.") 'and says so'
    Remove-Item -LiteralPath (Join-Path $twHome 'updates') -Recurse -Force -ErrorAction SilentlyContinue
    $script:GuiMessages.Clear()
    Start-GuiUpdate $script:Gui.Update
    $downloaded = Wait-Until { [Windows.Forms.Application]::DoEvents(); $null -eq $script:Gui.Work } 30
    Assert-True ($downloaded -and @($script:GuiMessages | Where-Object { $_ -like 'Ready to install*' }).Count -eq 1) 'Update now: downloaded and checked, ready to install' ($script:GuiMessages -join ' | ')
    Assert-True (Test-Path -LiteralPath (Join-Path $twHome "updates\$setupName")) 'Update now: the checked installer is kept for it'
    $env:TWINBAR_UPDATE_URL = $updateServer.Url('/bad/latest')
    $script:GuiMessages.Clear()
    Start-GuiUpdate (ConvertFrom-ReleaseJson (& $releaseFor "v$newVersion" '/bad'))
    [void](Wait-Until { [Windows.Forms.Application]::DoEvents(); $null -eq $script:Gui.Work } 30)
    Assert-True (@($script:GuiMessages | Where-Object { $_ -match 'SHA-256 differs' }).Count -eq 1) "Update now: an installer that doesn't match is refused" ($script:GuiMessages -join ' | ')
    $env:TWINBAR_UPDATE_URL = $updateServer.Url('/same/latest')
    $script:GuiMessages.Clear()
    Start-UpdateCheck -Manual
    [void](Wait-Until { [Windows.Forms.Application]::DoEvents(); $null -eq $script:Gui.Work } 20)
    Assert-True ($script:GuiMessages -contains "Twinbar $version is the newest version.") 'Check for updates: up to date' ($script:GuiMessages -join ' | ')

    # The icon by the clock: its menu, and closing the window to it.
    Assert-Cli (Invoke-Cli @('change', 'Windowed', '-Proxy', "socks5://127.0.0.1:$closedPort")) 0 'Changed' 'a profile whose proxy is down'
    $trayMenu = New-Object Windows.Forms.ContextMenuStrip
    Update-TrayMenu $trayMenu
    $texts = @($trayMenu.Items | ForEach-Object { $_.Text })
    Assert-True ($texts[0] -eq 'Open Twinbar' -and $texts -contains 'Fake App Listed' -and $texts -contains 'Fake App Windowed' -and $texts[-1] -eq 'Quit Twinbar') 'tray menu: Open Twinbar, the profiles, Quit' ($texts -join ' | ')
    $windowedItem = @($trayMenu.Items | Where-Object { $_.Text -eq 'Fake App Windowed' })
    Assert-Equal 'proxy down' $(if ($windowedItem.Count) { $windowedItem[0].ShortcutKeyDisplayString }) "tray menu: says when a profile's proxy is down"
    Assert-True ($texts -contains 'Start Twinbar when I sign in to Windows' -and $texts -contains 'Check for updates automatically') "tray menu: Twinbar's switches"
    $trayMenu.Dispose()
    Set-TwinbarSetting 'trayHintShown' $true # no note by the clock during the tests
    Add-TrayIcon
    $mainForm.Close()
    [Windows.Forms.Application]::DoEvents()
    Assert-True (-not $mainForm.Visible -and -not $mainForm.IsDisposed) 'closing the window keeps Twinbar by the clock'
    Show-MainWindow
    Assert-True $mainForm.Visible 'the icon brings the window back'
    Exit-TwinbarWindow
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($mainForm.IsDisposed -and $script:Gui.Stopped) 'Quit closes the window and stops Twinbar'
  } finally {
    Remove-Item Env:\TWINBAR_UPDATE_URL -ErrorAction SilentlyContinue
    $updateServer.Stop()
    if (-not $mainForm.IsDisposed) {
      $mainForm.Close()
      $mainForm.Dispose()
    }
    if ($script:Gui -and $script:Gui.Tray) { $script:Gui.Tray.Dispose() }
    $script:Gui = $null
  }
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.listed', '-DeleteData')) 0 'Removed' 'remove Listed'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.windowed', '-DeleteData')) 0 'Removed' 'remove Windowed'

  # -------------------------------------------------------------------------
  Write-Section 'Installing'
  $installDir = Join-Path $root 'installed twinbar'
  Assert-Cli (Invoke-Cli @('install', '-Dir', $installDir)) 0 'Installed Twinbar' 'install'
  foreach ($file in 'twinbar.ps1', 'twinbar.cmd', 'Twinbar.exe', 'twinbar.ico', 'LICENSE', 'README.md', 'CHANGELOG.md', '.twinbar-install') {
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir $file)) "installed $file"
  }
  $appExe = Join-Path $installDir 'Twinbar.exe'
  Assert-Equal "$version.0" ([Diagnostics.FileVersionInfo]::GetVersionInfo($appExe).FileVersion) "Twinbar.exe is version $version"
  $appLink = Join-Path $menu 'Twinbar.lnk'
  if (Test-Path -LiteralPath $appLink) {
    $al = Read-ShellLink $appLink
    Assert-Equal "$appExe|Twinbar.App" ('{0}|{1}' -f $al.TargetPath, $al.AppUserModelId) 'the Start menu has Twinbar, with its own taskbar ID'
  } else {
    Assert-True $false 'the Start menu has Twinbar'
  }
  $cmd = New-Object Diagnostics.ProcessStartInfo
  $cmd.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
  $cmd.Arguments = '/c ""' + (Join-Path $installDir 'twinbar.cmd') + '" version"'
  $cmd.UseShellExecute = $false
  $cmd.RedirectStandardOutput = $true
  $cmd.CreateNoWindow = $true
  $cmdProc = [Diagnostics.Process]::Start($cmd)
  $cmdOut = $cmdProc.StandardOutput.ReadToEnd()
  $cmdProc.WaitForExit()
  Assert-True ($cmdOut -match [regex]::Escape("twinbar $version")) 'the installed twinbar.cmd runs' $cmdOut
  Assert-Cli (Invoke-Cli @('install', '-Dir', $installDir)) 0 'Installed' 'installing again over it'
  $busy = Join-Path $root 'busy folder'
  [void][IO.Directory]::CreateDirectory($busy)
  [IO.File]::WriteAllText((Join-Path $busy 'mine.txt'), 'x')
  Assert-Cli (Invoke-Cli @('install', '-Dir', $busy)) 1 'other files' "a folder with other files isn't used"
  Assert-Cli (Invoke-Cli @('install', '-Dir', [Environment]::GetFolderPath('UserProfile'))) 1 "can't be Twinbar's folder" "the user folder isn't used"

  $installedScript = Join-Path $installDir 'twinbar.ps1'
  Assert-Cli (Invoke-Cli @('settings', 'startup', 'on') $installedScript) 0 '(?m)^startup\s+on\b' 'settings startup on, once installed'
  Assert-Equal "`"$appExe`" --tray" ((Get-ItemProperty -Path $runKey -Name 'Twinbar' -ErrorAction SilentlyContinue).Twinbar) 'startup: Windows starts Twinbar.exe --tray at sign-in'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Shown')) 0 'Made' 'a profile for the window'
  Assert-True (& $findInJumpLists 'Fake App Shown') "once Twinbar is installed, a new profile goes in its jump list"
  # (Not $app: the dot-sourced script has a [string] $App, and names ignore case.)
  # Twinbar opens one window at a time: with one already open (an installed Twinbar
  # on this computer), a new Twinbar.exe just brings that one forward and ends.
  $alreadyOpen = @(Get-Process -Name Twinbar -ErrorAction SilentlyContinue).Count -gt 0
  $windowUp = $false
  if ($alreadyOpen) {
    Write-Host '  skip  opening Twinbar.exe: a Twinbar window is already open on this computer (close it to run these checks)'
  } else {
    $appProcess = [Diagnostics.Process]::Start($appExe)
    $windowUp = Wait-Until { $appProcess.Refresh(); $appProcess.MainWindowHandle -ne [IntPtr]::Zero } 90
    Assert-True $windowUp 'Twinbar.exe opens its window'
  }
  if ($windowUp) {
    Assert-Equal 'Twinbar' $appProcess.MainWindowTitle 'titled Twinbar'
    # Windows PowerShell's UI Automation client only sees the window's controls as
    # plain panes, so the list is asked for its row count directly.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class TwinbarTestWindows {
  delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int size);
  [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  // What the window's X button sends (WM_SYSCOMMAND, SC_CLOSE). A plain WM_CLOSE,
  // as Process.CloseMainWindow sends, ends Twinbar instead. "" if posted, else the error.
  public static string CloseLikeUser(IntPtr window) {
    return PostMessageW(window, 0x0112, (IntPtr)0xF060, IntPtr.Zero) ? "" : "PostMessage failed, error " + Marshal.GetLastWin32Error();
  }
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int size);
  // The visible top-level windows of a process, as "class | title", for test reports.
  public static string VisibleWindows(int processId) {
    StringBuilder found = new StringBuilder();
    EnumWindows(delegate (IntPtr hwnd, IntPtr lParam) {
      int pid;
      GetWindowThreadProcessId(hwnd, out pid);
      if (pid == processId && IsWindowVisible(hwnd)) {
        StringBuilder name = new StringBuilder(256), title = new StringBuilder(256);
        GetClassNameW(hwnd, name, name.Capacity);
        GetWindowTextW(hwnd, title, title.Capacity);
        found.Append(name).Append(" | ").Append(title).Append("; ");
      }
      return true;
    }, IntPtr.Zero);
    return found.ToString();
  }
  public static int ListRows(IntPtr window) {
    int rows = -1;
    EnumChildWindows(window, delegate (IntPtr hwnd, IntPtr lParam) {
      StringBuilder name = new StringBuilder(256);
      GetClassNameW(hwnd, name, name.Capacity);
      if (name.ToString().Contains("SysListView32")) { rows = (int)SendMessageW(hwnd, 0x1004, IntPtr.Zero, IntPtr.Zero); return false; }
      return true;
    }, IntPtr.Zero);
    return rows;
  }
}
'@
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $listed = Wait-Until { [TwinbarTestWindows]::ListRows($appProcess.MainWindowHandle) -eq 1 } 15
    Assert-True $listed 'the window lists the profile' "rows: $([TwinbarTestWindows]::ListRows($appProcess.MainWindowHandle))"
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($appProcess.MainWindowHandle)
    $windowNames = @($element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
    Assert-True ($windowNames -contains 'New profile...' -and $windowNames -contains 'Check all') 'and has its buttons'
    $windowLog = Join-Path $twHome 'logs\window.log'
    $second = [Diagnostics.Process]::Start($appExe)
    Assert-True ($second.WaitForExit(20000) -and $second.ExitCode -eq 0) 'a second Twinbar.exe just brings the window forward'
    Assert-True (-not $appProcess.HasExited) 'the first one stays open'
    # The first one picks the request up on its next look (every 0.3 s). Closing the
    # window before that would have it come straight back, so wait for it.
    Assert-True (Wait-Until { [string](Get-Content -LiteralPath $windowLog -Raw -ErrorAction SilentlyContinue) -match 'asked to show the window' } 10) 'and the first one brings its window forward'
    if ($null -ne (Get-TaskbarAppIds)) {
      Assert-True (Wait-Until { (Get-TaskbarAppIds) -contains 'Twinbar.App' } 10) 'Twinbar has a taskbar button of its own'
    }
    $appWindow = $appProcess.MainWindowHandle
    $posted = [TwinbarTestWindows]::CloseLikeUser($appWindow)
    $hidden = Wait-Until { $appProcess.HasExited -or -not [TwinbarTestWindows]::IsWindowVisible($appWindow) } 20
    $seen = if ($appProcess.HasExited) { 'it exited' } else {
      '{0} visible: {1} window visible: {2}; settings: {3}; log: {4}' -f $posted, [TwinbarTestWindows]::VisibleWindows($appProcess.Id), [TwinbarTestWindows]::IsWindowVisible($appWindow),
      ([IO.File]::ReadAllText((Join-Path $twHome 'settings.json')) -replace '\s+', ' '),
      $(if (Test-Path -LiteralPath $windowLog) { (Get-Content -LiteralPath $windowLog -Tail 8) -join ' | ' } else { 'none' })
    }
    Assert-True $hidden 'closing the window hides it' $seen
    Assert-True (-not $appProcess.HasExited) 'and Twinbar stays by the clock'
    $again = [Diagnostics.Process]::Start($appExe)
    [void]$again.WaitForExit(20000)
    Assert-True (Wait-Until { -not $appProcess.HasExited -and [TwinbarTestWindows]::IsWindowVisible($appWindow) } 15) 'opening Twinbar again shows that window'
    $quit = [Diagnostics.Process]::Start($appExe, '--quit')
    [void]$quit.WaitForExit(20000)
    Assert-True ($appProcess.WaitForExit(15000) -and $appProcess.ExitCode -eq 0) 'Twinbar.exe --quit ends it'

    # As Windows starts it at sign-in: just the icon by the clock.
    $trayOnly = [Diagnostics.Process]::Start($appExe, '--tray')
    $listening = Wait-Until {
      $signal = $null
      $open = [Threading.EventWaitHandle]::TryOpenExisting('Local\Twinbar.App.Show', [ref] $signal)
      if ($open) { $signal.Dispose() }
      $open
    } 90
    $trayOnly.Refresh()
    Assert-True ($listening -and -not $trayOnly.HasExited -and $trayOnly.MainWindowHandle -eq [IntPtr]::Zero) 'Twinbar.exe --tray starts by the clock, without its window'
    $again = [Diagnostics.Process]::Start($appExe)
    [void]$again.WaitForExit(20000)
    Assert-True (Wait-Until { $trayOnly.Refresh(); $trayOnly.MainWindowHandle -ne [IntPtr]::Zero } 15) 'opening Twinbar then shows its window'
    $quit = [Diagnostics.Process]::Start($appExe, '--quit')
    [void]$quit.WaitForExit(20000)
    Assert-True ($trayOnly.WaitForExit(15000)) 'and --quit ends it'
    if (-not $trayOnly.HasExited) { $trayOnly.Kill() }
  }
  if (-not $alreadyOpen -and -not $appProcess.HasExited) { $appProcess.Kill() }
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.shown', '-DeleteData')) 0 'Removed' 'remove Shown'
  Assert-True (-not (& $findInJumpLists 'Fake App Shown')) 'and it leaves the jump list'

  $r = Invoke-Cli @('uninstall')
  Assert-Cli $r 0 'Uninstalled Twinbar' 'uninstall'
  Assert-True (-not (Test-Path -LiteralPath $installDir)) 'its folder is gone'
  Assert-True (-not (Test-Path -LiteralPath $appLink)) 'its Start menu entry is gone'
  Assert-True ($null -eq (Get-ItemProperty -Path $runKey -Name 'Twinbar' -ErrorAction SilentlyContinue)) "and it doesn't start with Windows any more"
  Assert-Cli (Invoke-Cli @('uninstall', '-Dir', $installDir)) 1 "isn't installed" "uninstalling what isn't there fails"

  # What the Windows installer does: copy the files, then run that copy's install into its own folder.
  $ownDir = Join-Path $root 'own folder'
  [void][IO.Directory]::CreateDirectory($ownDir)
  foreach ($file in 'twinbar.ps1', 'twinbar.cmd', 'README.md', 'LICENSE', 'CHANGELOG.md') { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $ownDir }
  $ownScript = Join-Path $ownDir 'twinbar.ps1'
  Assert-Cli (Invoke-Cli @('install', '-Dir', $ownDir) $ownScript) 0 'Installed Twinbar' 'a copy installs into its own folder, as the installer does'
  Assert-True (Test-Path -LiteralPath (Join-Path $ownDir 'Twinbar.exe')) 'Twinbar.exe was built there'
  Assert-Equal ([IO.File]::ReadAllText($cli)) ([IO.File]::ReadAllText($ownScript)) 'its twinbar.ps1 is untouched'
  Assert-Cli (Invoke-Cli @('install', '-Dir', $ownDir) $ownScript) 0 'Installed Twinbar' 'and again, as an upgrade does'
  Assert-Cli (Invoke-Cli @('uninstall', '-Dir', $ownDir) $ownScript) 0 'Uninstalled' 'that copy uninstalls itself'
  Assert-True (-not (Test-Path -LiteralPath $ownDir)) 'and its folder is gone'
  Assert-True (-not (Test-StartedByDoubleClick)) "run from a terminal, twinbar isn't treated as double-clicked"

  # -------------------------------------------------------------------------
  if ($RealApp) {
    Write-Section "Real app: $RealApp"
    $realFamily = (Resolve-ElectronApp $RealApp).Family
    # Telegram must leave the main Telegram's tg:// links alone.
    $tgLinkKey = 'HKCU:\Software\Classes\tg\shell\open\command'
    $tgLinkBefore = (Get-ItemProperty -LiteralPath $tgLinkKey -ErrorAction SilentlyContinue).'(default)'
    $r = Invoke-Cli @('new', '-App', $RealApp, '-Name', 'Smoke Test', '-ShortcutDir', $menu)
    Assert-Cli $r 0 'Made' 'new Smoke Test'
    $rec = @(Get-ListRows | Where-Object { $_.name -eq 'Smoke Test' })
    if ($r.Code -eq 0 -and $rec.Count -eq 1) {
      $rec = $rec[0]
      $l = Read-ShellLink $rec.shortcut
      $full = [IO.File]::ReadAllText((Join-Path $twHome "profiles\$($rec.id).json")) | ConvertFrom-Json
      Write-Host ("        {0} ({1}): starts {2}" -f $rec.fullName, $rec.appKind, $full.launchExe) -ForegroundColor DarkGray
      Assert-True (Test-Path -LiteralPath $full.launchExe) 'the profile starts an existing program'
      Assert-Equal $rec.id $l.Arguments 'the shortcut starts the launcher with the profile id'
      Assert-Equal 8 @((Read-IcoInfo $rec.icon).Images).Count "the app's icon was redrawn"
      if ($rec.appKind -eq 'store') {
        Assert-True ($rec.dataDir.StartsWith($storeData + '\', [StringComparison]::OrdinalIgnoreCase)) "a Store app's data is kept outside AppData" $rec.dataDir
        Assert-True ($full.packageApp -match '!') "it's started through its package ($($full.packageApp))"
      }
      if ($Launch) {
        Assert-Cli (Invoke-Cli @('open', $rec.id)) 0 'Opening' 'open it'
        if ($realFamily -eq 'telegram') {
          # Telegram keeps its data in tdata; Twinbar only put experimental_options.json there.
          Assert-True (Wait-Until { @(Get-ChildItem -LiteralPath (Join-Path $rec.dataDir 'tdata') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'experimental_options.json' }).Count -ge 1 } 60) 'Telegram keeps its data in the profile folder'
        } else {
          Assert-True (Wait-Until { @(Get-ChildItem -LiteralPath $rec.dataDir -Force | Where-Object { $_.Name -ne '.twinbar-profile' }).Count -ge 2 } 60) 'the app keeps its data in the profile folder'
        }
        $procs = @(Get-ProcessesFor $rec.dataDir)
        Assert-True ($procs.Count -gt 0) 'the app runs with the profile folder'
        $realExe = (Resolve-ElectronApp $RealApp).RealExe
        Assert-True (@($procs | Where-Object { $_.ExecutablePath -ieq $realExe }).Count -gt 0) "the app's own exe got the folder ($realExe)"
        Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq $rec.id })[0]).status 'list shows it running'
        if ($null -eq (Get-TaskbarAppIds)) {
          Write-Host '  skip  taskbar button (no taskbar here)'
        } else {
          Assert-True (Wait-Until { (Get-TaskbarAppIds) -contains $rec.aumid } 30) "the taskbar shows a button of its own ($($rec.aumid))"
        }
        $procs = @(Get-ProcessesFor $rec.dataDir)
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Assert-True (Wait-Until { @(Get-ProcessesFor $rec.dataDir).Count -eq 0 } 20) 'closed it again'
        Assert-True (Wait-Until { @(Get-LaunchersFor $rec.id).Count -eq 0 } 25) 'the launcher quit after the app'
        Start-Sleep -Seconds 1 # let Windows release the files
      }
      Assert-Cli (Invoke-Cli @('remove', $rec.id, '-DeleteData')) 0 'Removed' 'remove it with its data'
    }
    if ($realFamily -eq 'telegram') {
      Assert-Equal $tgLinkBefore ((Get-ItemProperty -LiteralPath $tgLinkKey -ErrorAction SilentlyContinue).'(default)') 'tg:// links still open the main Telegram'
    }

    if ($Launch -and $realFamily -eq 'telegram') {
      Write-Host '  skip  the proxy checks (Telegram keeps its own proxy setting)'
    } elseif ($Launch) {
      # Through a proxy: a local SOCKS5 proxy that relays to the internet and logs
      # where it was asked to go; anything else the app connects to went around it.
      Write-Section "Real app through a proxy: $RealApp"
      if (-not ('TestProxy' -as [type])) { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TestNet.cs'))) -Language CSharp }
      $realProxy = New-Object TestProxy $true
      $deadPort = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
      $deadPort.Start(); $deadNumber = $deadPort.LocalEndpoint.Port; $deadPort.Stop()
      try {
        $r = Invoke-Cli @('new', '-App', $RealApp, '-Name', 'Smoke Proxy', '-Proxy', "socks5://127.0.0.1:$($realProxy.Port)")
        Assert-Cli $r 0 'Made' 'new Smoke Proxy'
        $pr = @(Get-ListRows | Where-Object { $_.name -eq 'Smoke Proxy' })
        if ($r.Code -eq 0 -and $pr.Count -eq 1) {
          $pr = $pr[0]
          Assert-Cli (Invoke-Cli @('open', $pr.id)) 0 'Opening' 'open it through the proxy'
          $running = Wait-Until { @(Get-ProcessesFor $pr.dataDir).Count -gt 0 } 60
          Assert-True $running 'it runs' ('launcher log: ' + ((Get-Content -LiteralPath (Join-Path $twHome 'logs\launcher.log') -Tail 5 -ErrorAction SilentlyContinue) -join ' | '))
          $around = @(Get-OutsideConnections $pr.dataDir 30)
          $through = @($realProxy.Requests() | Sort-Object -Unique)
          Assert-True ($through.Count -gt 0) "its traffic went through the proxy ($($through.Count) destination(s))" (($through | Select-Object -First 8) -join ', ')
          Write-Host ('        through the proxy: {0}' -f (($through | Select-Object -First 10) -join ', ')) -ForegroundColor DarkGray
          Assert-True ($around.Count -eq 0) 'nothing went around the proxy' ("went around it: " + ($around -join ', '))
          Stop-ProfileApp $pr.dataDir $pr.id

          Assert-Cli (Invoke-Cli @('change', $pr.id, '-Proxy', "socks5://127.0.0.1:$deadNumber")) 0 'Changed' 'point it at a proxy that is down'
          Assert-Cli (Invoke-Cli @('open', $pr.id)) 0 'Opening' 'open it again'
          Assert-True (Wait-Until { @(Get-ProcessesFor $pr.dataDir).Count -gt 0 } 60) 'it runs'
          $leaked = @(Get-OutsideConnections $pr.dataDir 30)
          Assert-True ($leaked.Count -eq 0) 'with the proxy down, nothing gets out (the kill switch)' ("got out: " + ($leaked -join ', '))
          Stop-ProfileApp $pr.dataDir $pr.id
          Start-Sleep -Seconds 1
          Assert-Cli (Invoke-Cli @('remove', $pr.id, '-DeleteData')) 0 'Removed' 'remove it with its data'
        }
      } finally {
        $realProxy.Stop()
      }
    }
  }
} finally {
  if (Get-Command Initialize-Interop -ErrorAction SilentlyContinue) {
    try { Initialize-Interop; [TwinbarInterop.JumpList]::Delete($jumpListId) } catch { Write-Host "  (couldn't remove the test jump list: $($_.Exception.Message))" }
  }
  Remove-Item -Path $runKeyRoot -Recurse -Force -ErrorAction SilentlyContinue
  if (-not @(Get-ChildItem -Path 'HKCU:\Software\Twinbar tests' -ErrorAction SilentlyContinue).Count) { Remove-Item -Path 'HKCU:\Software\Twinbar tests' -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:\TWINBAR_HOME, Env:\TWINBAR_PINNED_DIR, Env:\TWINBAR_STORE_DATA, Env:\TWINBAR_SHORTCUT_DIR, Env:\TWINBAR_START_MENU, Env:\TWINBAR_JUMPLIST_ID, Env:\TWINBAR_RUN_KEY -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $storeData.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $storeData -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ''
if ($script:failed) {
  Write-Host "$($script:passed) passed, $($script:failed) FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All $($script:passed) checks passed."
exit 0
