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
$script:passed = 0
$script:failed = 0
$script:fakeBuilt = $null

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

# Runs twinbar.ps1 in a fresh Windows PowerShell, with TWINBAR_HOME pointing at the test folder.
function Invoke-Cli([string[]] $Arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $powershellExe
  $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cli) + $Arguments
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
  foreach ($file in @($cli, (Join-Path $repo 'twinbar.cmd'), $PSCommandPath, (Join-Path $PSScriptRoot 'FakeApp.cs'))) {
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
  Assert-Equal '--blink-settings=preferredColorScheme=1' $script:Appearances['light'] 'appearance: light prefers the light colour scheme'

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
  Assert-Throws { Resolve-ElectronApp 'NoSuchApp4711' } "no file, folder or Microsoft Store app" 'an unknown Store app name is refused'
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
  Write-Section 'The window'
  Initialize-Forms
  [Windows.Forms.Application]::EnableVisualStyles()
  $script:GuiNoDialogs = $true
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
    Assert-True ($script:Gui.Buttons.Edit.Enabled -and $script:Gui.Buttons.Remove.Enabled) 'Edit and Remove come on with a profile selected'

    $script:Gui.Apps = @([pscustomobject]@{ Name = 'Fake App'; Kind = 'standard'; Source = $stdExe; LaunchExe = $stdExe; Id = 'fakeapp' })
    $dialog = New-ProfileDialog $null
    Assert-Equal 'Fake App' ([string]$dialog.App.SelectedItem) 'New: the app is picked'
    $dialog.Name.Text = 'Windowed'
    Assert-Equal (Resolve-ProfileColor '' 'fakeapp.windowed') (Get-ColorItemHex ([string]$dialog.Color.SelectedItem)) 'New: the colour follows the name, as on the command line'
    $dialog.Color.SelectedItem = 'Purple'
    Update-ProfilePreview $dialog
    Assert-True ($null -ne $dialog.Preview.Image) 'New: the icon is previewed'
    Assert-True ((Get-HueDistance (Get-MainHue (New-Object Drawing.Bitmap $dialog.Preview.Image)) 272) -lt 20) 'New: the preview is purple'
    Assert-True (Submit-ProfileDialog $dialog) 'New: Create makes the profile'
    $made = Read-Record 'fakeapp.windowed'
    Assert-Equal '#8E4EC6|W|tint+badge' ('{0}|{1}|{2}' -f $made.color, $made.badge, $made.style) 'New: with the look picked in the window'
    $dialog.Form.Dispose()
    Assert-Equal 2 $script:Gui.List.Items.Count 'the list shows the new profile'

    $bad = New-ProfileDialog $null
    $bad.Name.Text = 'Bad!'
    $script:GuiMessages.Clear()
    Assert-True (-not (Submit-ProfileDialog $bad)) 'New: a bad name is refused'
    Assert-True ($script:GuiMessages.Count -and $script:GuiMessages[0] -match '^The profile name may use letters') 'with a message that says why' ($script:GuiMessages -join ' | ')
    $bad.Form.Dispose()

    $row = @($script:Gui.Rows | Where-Object { $_.Id -eq 'fakeapp.windowed' })[0]
    $edit = New-ProfileDialog $row
    Assert-True (-not $edit.Name.Enabled -and -not $edit.App.Enabled) "Edit: the app and name can't change"
    Assert-Equal 'Purple' ([string]$edit.Color.SelectedItem) 'Edit: shows the colour'
    Select-ColorItem $edit.Color '#123456'
    Assert-Equal '#123456' ([string]$edit.Color.SelectedItem) 'Edit: a custom colour'
    $edit.Appearance.SelectedItem = 'Dark'
    Assert-True (Submit-ProfileDialog $edit) 'Edit: Save changes it'
    $changedInWindow = Read-Record 'fakeapp.windowed'
    Assert-Equal '#123456|dark|W' ('{0}|{1}|{2}' -f $changedInWindow.color, $changedInWindow.appearance, $changedInWindow.badge) 'Edit: with the new look'
    $edit.Form.Dispose()

    $removeDialog = New-RemoveDialog $row
    Assert-True (-not $removeDialog.DeleteData.Checked) 'Remove: keeps the sign-in unless asked'
    $removeDialog.Form.Dispose()
  } finally {
    $mainForm.Close()
    $mainForm.Dispose()
    $script:Gui = $null
  }
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.listed', '-DeleteData')) 0 'Removed' 'remove Listed'
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.windowed', '-DeleteData')) 0 'Removed' 'remove Windowed'

  # -------------------------------------------------------------------------
  Write-Section 'Installing'
  $installDir = Join-Path $root 'installed twinbar'
  Assert-Cli (Invoke-Cli @('install', '-Dir', $installDir)) 0 'Installed Twinbar' 'install'
  foreach ($file in 'twinbar.ps1', 'twinbar.cmd', 'Twinbar.exe', 'twinbar.ico', 'LICENSE', 'README.md', '.twinbar-install') {
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

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Shown')) 0 'Made' 'a profile for the window'
  # (Not $app: the dot-sourced script has a [string] $App, and names ignore case.)
  $appProcess = [Diagnostics.Process]::Start($appExe)
  $windowUp = Wait-Until { $appProcess.Refresh(); $appProcess.MainWindowHandle -ne [IntPtr]::Zero } 90
  Assert-True $windowUp 'Twinbar.exe opens its window'
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
    $second = [Diagnostics.Process]::Start($appExe)
    Assert-True ($second.WaitForExit(20000) -and $second.ExitCode -eq 0) 'a second Twinbar.exe just brings the window forward'
    Assert-True (-not $appProcess.HasExited) 'the first one stays open'
    if ($null -ne (Get-TaskbarAppIds)) {
      Assert-True (Wait-Until { (Get-TaskbarAppIds) -contains 'Twinbar.App' } 10) 'Twinbar has a taskbar button of its own'
    }
    [void]$appProcess.CloseMainWindow()
    Assert-True ($appProcess.WaitForExit(15000) -and $appProcess.ExitCode -eq 0) 'closing the window ends Twinbar.exe'
  }
  if (-not $appProcess.HasExited) { $appProcess.Kill() }
  Assert-Cli (Invoke-Cli @('remove', 'fakeapp.shown', '-DeleteData')) 0 'Removed' 'remove Shown'

  $r = Invoke-Cli @('uninstall')
  Assert-Cli $r 0 'Uninstalled Twinbar' 'uninstall'
  Assert-True (-not (Test-Path -LiteralPath $installDir)) 'its folder is gone'
  Assert-True (-not (Test-Path -LiteralPath $appLink)) 'its Start menu entry is gone'
  Assert-Cli (Invoke-Cli @('uninstall', '-Dir', $installDir)) 1 "isn't installed" "uninstalling what isn't there fails"

  # -------------------------------------------------------------------------
  if ($RealApp) {
    Write-Section "Real app: $RealApp"
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
        Assert-True (Wait-Until { @(Get-ChildItem -LiteralPath $rec.dataDir -Force | Where-Object { $_.Name -ne '.twinbar-profile' }).Count -ge 2 } 60) 'the app keeps its data in the profile folder'
        $procs = @(Get-ProcessesFor $rec.dataDir)
        Assert-True ($procs.Count -gt 0) 'the app runs with the profile folder'
        $realExe = (Resolve-ElectronApp $RealApp).RealExe
        Assert-True (@($procs | Where-Object { $_.ExecutablePath -ieq $realExe }).Count -gt 0) "the Electron exe itself got the folder ($realExe)"
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
  }
} finally {
  Remove-Item Env:\TWINBAR_HOME, Env:\TWINBAR_PINNED_DIR, Env:\TWINBAR_STORE_DATA, Env:\TWINBAR_SHORTCUT_DIR, Env:\TWINBAR_START_MENU -ErrorAction SilentlyContinue
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
