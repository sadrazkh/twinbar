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
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $script:fakeBuilt -OutputType WindowsApplication
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

  # -------------------------------------------------------------------------
  Write-Section 'Command line'
  Assert-Cli (Invoke-Cli @('help')) 0 'twinbar new -App' 'help'
  Assert-Cli (Invoke-Cli @('version')) 0 ([regex]::Escape($version)) 'version'
  Assert-Cli (Invoke-Cli @('bogus')) 1 'unknown command' 'an unknown command fails'
  Assert-Cli (Invoke-Cli @('list')) 0 'No profiles yet' 'list with no profiles'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-ShortcutDir', $menu)) 1 'profile name is required' 'new without a name fails'
  Assert-Cli (Invoke-Cli @('new', '-App', (Join-Path $plain 'FakeApp.exe'), '-Name', 'Work', '-ShortcutDir', $menu)) 1 'Electron' 'new with a non-Electron app fails'

  $r = Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Work"' 'new Work'
  $workLink = Join-Path $menu 'Fake App Work.lnk'
  $workData = Join-Path $twHome 'data\fakeapp\work'
  Assert-True (Test-Path -LiteralPath $workLink) 'the Start menu shortcut exists'
  if (Test-Path -LiteralPath $workLink) {
    $l = Read-ShellLink $workLink
    Assert-Equal $stdExe $l.TargetPath 'shortcut: target'
    Assert-Equal "--user-data-dir=""$workData""" $l.Arguments 'shortcut: --user-data-dir argument'
    Assert-Equal 'Twinbar.fakeapp.work' $l.AppUserModelId 'shortcut: its own AppUserModelID'
    Assert-Equal $std $l.WorkingDirectory 'shortcut: working folder'
    Assert-Equal $stdExe $l.IconPath "shortcut: the app's icon"
  }
  Assert-Equal 'fakeapp.work' ([IO.File]::ReadAllText((Join-Path $workData '.twinbar-profile'))) 'the data folder has the marker'
  Assert-True (Test-Path -LiteralPath (Join-Path $twHome 'profiles\fakeapp.work.json')) 'the profile record exists'

  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Work', '-ShortcutDir', $menu)) 1 'already a profile' 'the same profile twice fails'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'WORK', '-ShortcutDir', $menu)) 1 'already a profile' 'names differing only in case clash'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Other', '-DataDir', $workData, '-ShortcutDir', $menu)) 1 'already uses' "a data folder can't be shared"
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', [Environment]::GetFolderPath('UserProfile'), '-ShortcutDir', $menu)) 1 "can't be a profile's data folder" 'the user folder is refused as a data folder'
  Assert-Cli (Invoke-Cli @('new', '-App', $stdExe, '-Name', 'Bad', '-DataDir', (Join-Path $std 'x\..'), '-ShortcutDir', $menu)) 1 "can't contain the app" "the app's own folder is refused"

  $r = Invoke-Cli @('new', 'Home', '-App', $sqExe, '-ShortcutDir', $menu)
  Assert-Cli $r 0 'Made "Fake App Home"' 'new Home (name given first) for the Squirrel app'
  Assert-Equal $sqExe (Read-ShellLink (Join-Path $menu 'Fake App Home.lnk')).TargetPath 'Squirrel shortcut starts the root launcher'

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
  Assert-Equal 4 $rows.Count 'list -Json shows 4 profiles'
  Assert-Equal 'ready' (@($rows | Where-Object { $_.id -eq 'fakeapp.work' })[0]).status 'Work is ready'
  Assert-Cli (Invoke-Cli @('list')) 0 'Fake App Work\s+fakeapp\.work\s+ready' 'list shows a table'

  # -------------------------------------------------------------------------
  Write-Section 'Opening a profile'
  [IO.File]::WriteAllText((Join-Path $workData 'stay.txt'), 'keep running')
  Assert-Cli (Invoke-Cli @('open', 'Work')) 0 'Opening Fake App Work' 'open Work'
  $launched = Join-Path $workData 'launched.txt'
  Assert-True (Wait-Until { Test-Path -LiteralPath $launched } 20) 'the app started'
  if (Test-Path -LiteralPath $launched) {
    $info = @{}
    foreach ($line in [IO.File]::ReadAllLines($launched)) {
      $i = $line.IndexOf('=')
      $info[$line.Substring(0, $i)] = $line.Substring($i + 1)
    }
    Assert-Equal $workData $info['datadir'] 'the app got its own data folder'
    Assert-True ($info['appid'] -eq 'Twinbar.fakeapp.work' -or $info['linkname'] -eq $workLink) 'Windows told the app which shortcut started it' ("appid='{0}' linkname='{1}'" -f $info['appid'], $info['linkname'])
    Write-Host ("        (start info: appid='{0}', linkname='{1}')" -f $info['appid'], $info['linkname']) -ForegroundColor DarkGray
  }
  Assert-True (Wait-Until { @(Get-ProcessesFor $workData).Count -gt 0 } 10) 'the running app is found by its data folder'
  Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq 'fakeapp.work' })[0]).status 'list shows Work running'
  Assert-Cli (Invoke-Cli @('remove', 'Work')) 1 'running' "a running profile isn't removed"
  Remove-Item -LiteralPath (Join-Path $workData 'stay.txt')
  Assert-True (Wait-Until { @(Get-ProcessesFor $workData).Count -eq 0 } 15) 'the app quit'

  # -------------------------------------------------------------------------
  Write-Section 'Removing'
  Assert-Cli (Invoke-Cli @('remove', 'Home')) 1 'more than one' 'an ambiguous name is refused'
  Assert-Cli (Invoke-Cli @('remove', 'Nope')) 1 "no profile called" 'an unknown profile is refused'
  $r = Invoke-Cli @('remove', 'Work')
  Assert-Cli $r 0 'Removed "Fake App Work"' 'remove Work'
  Assert-True (-not (Test-Path -LiteralPath $workLink)) 'the shortcut is gone'
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
      Write-Host ("        {0} ({1}): starts {2}" -f $rec.fullName, $rec.appKind, $l.TargetPath) -ForegroundColor DarkGray
      Assert-True (Test-Path -LiteralPath $l.TargetPath) 'the shortcut starts an existing program'
      Assert-Equal "--user-data-dir=""$($rec.dataDir)""" $l.Arguments 'the shortcut passes the data folder'
      if ($Launch) {
        Assert-Cli (Invoke-Cli @('open', $rec.id)) 0 'Opening' 'open it'
        Assert-True (Wait-Until { @(Get-ChildItem -LiteralPath $rec.dataDir -Force | Where-Object { $_.Name -ne '.twinbar-profile' }).Count -ge 2 } 60) 'the app keeps its data in the profile folder'
        $procs = @(Get-ProcessesFor $rec.dataDir)
        Assert-True ($procs.Count -gt 0) 'the app runs with the profile folder'
        $realExe = (Resolve-ElectronApp $RealApp).RealExe
        Assert-True (@($procs | Where-Object { $_.ExecutablePath -ieq $realExe }).Count -gt 0) "the Electron exe itself got the folder ($realExe)"
        Assert-Equal 'running' (@(Get-ListRows | Where-Object { $_.id -eq $rec.id })[0]).status 'list shows it running'
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Assert-True (Wait-Until { @(Get-ProcessesFor $rec.dataDir).Count -eq 0 } 20) 'closed it again'
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
