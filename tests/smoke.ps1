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

# The taskbar's buttons, by the AppUserModelID each stands for; $null when there's
# no taskbar to ask (for example on a build server).
function Get-TaskbarAppIds {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $a = [System.Windows.Automation.AutomationElement]
  $condition = New-Object System.Windows.Automation.PropertyCondition($a::ClassNameProperty, 'Shell_TrayWnd')
  $tray = $a::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
  if ($null -eq $tray) { return $null }
  $ids = @()
  foreach ($e in $tray.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($e.Current.AutomationId -like 'Appid:*') { $ids += $e.Current.AutomationId.Substring(6).Trim() }
  }
  return , $ids
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

# The average hue (0-360) of the clearly coloured, opaque pixels of an image.
function Get-MainHue([string] $PngPath) {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object Drawing.Bitmap $PngPath
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
    $issues = @(Invoke-ScriptAnalyzer -Path $cli -Severity Warning, Error)
    Assert-Equal 0 $issues.Count 'PSScriptAnalyzer finds no warnings or errors'
    $issues | ForEach-Object { Write-Host "        $($_.RuleName) line $($_.Line): $($_.Message)" -ForegroundColor DarkGray }
  } else {
    Write-Host '  skip  PSScriptAnalyzer (not installed)'
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
  . $cli

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

  $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-Color', 'green', '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Work"' 'new Work'
  Assert-Cli $r 0 'colour #30A46C, badge W' 'it reports the icon'
  $workLink = Join-Path $menu 'Fake App Work.lnk'
  $workData = Join-Path $twHome 'data\fakeapp\work'
  $workIcon = Join-Path $twHome 'icons\fakeapp.work.ico'
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
  $record = [IO.File]::ReadAllText((Join-Path $twHome 'profiles\fakeapp.work.json')) | ConvertFrom-Json
  Assert-Equal 'tint+badge|#30A46C|W' ('{0}|{1}|{2}' -f $record.style, $record.color, $record.badge) 'the record has the look'
  Assert-Equal $stdExe $record.launchExe 'the record has the app'

  $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Plain', '-Style', 'original', '-ShortcutDir', $menu)
  Assert-Cli $r 0 "the app's own icon" 'new with -Style original'
  Assert-Equal $stdExe (Read-ShellLink (Join-Path $menu 'Fake App Plain.lnk')).IconPath "-Style original keeps the app's icon"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $twHome 'icons\fakeapp.plain.ico'))) '-Style original draws no icon'

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-ShortcutDir', $menu)) 1 'already a profile' 'the same profile twice fails'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'WORK', '-ShortcutDir', $menu)) 1 'already a profile' 'names differing only in case clash'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Other', '-DataDir', $workData, '-ShortcutDir', $menu)) 1 'already uses' "a data folder can't be shared"
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', [Environment]::GetFolderPath('UserProfile'), '-ShortcutDir', $menu)) 1 "can't be a profile's data folder" 'the user folder is refused as a data folder'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', (Join-Path $std 'x\..'), '-ShortcutDir', $menu)) 1 "can't contain the app" "the app's own folder is refused"

  $r = Invoke-Cli @('new', 'Home', '-App', $sqExe, '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Home"' 'new Home (name given first) for the Squirrel app'
  $homeRecord = [IO.File]::ReadAllText((Join-Path $twHome 'profiles\fakeapp.home.json')) | ConvertFrom-Json
  Assert-Equal $sqExe $homeRecord.launchExe "a Squirrel app is started through Squirrel's launcher"

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
    $datadirLine = @([IO.File]::ReadAllLines($launched) | Where-Object { $_ -like 'datadir=*' })[0]
    Assert-Equal "datadir=$workData" $datadirLine 'the app got its own data folder'
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
    if ($null -eq (Get-TaskbarAppIds)) {
      Write-Host '  skip  taskbar button (no taskbar here)'
    } else {
      Assert-True (Wait-Until { (Get-TaskbarAppIds) -contains 'Twinbar.fakeapp.work' } 10) 'the taskbar shows a button of its own for it'
      Assert-True ((Get-TaskbarAppIds) -notcontains 'Fake.App') "it isn't on the app's own button"
    }
  }
  Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq 'fakeapp.work' })[0]).status 'list shows Work running'
  Assert-Cli (Invoke-Cli @('remove', 'Work')) 1 'running' "a running profile isn't removed"
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
  Remove-Item Env:\TWINBAR_HOME -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed) {
  Write-Host "$($script:passed) passed, $($script:failed) FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All $($script:passed) checks passed."
exit 0
