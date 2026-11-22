<#
.SYNOPSIS
Tests the Windows installer: a silent install for the current user, Twinbar's
window, and a silent uninstall.

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\installer.ps1 -Setup dist\Twinbar-Setup-x.y.z.exe

It installs into the real default place (%LOCALAPPDATA%\Programs\Twinbar), with
the PATH option, and adds Twinbar to the Start menu, then uninstalls it again.
CI runs it on a fresh Windows machine; on your own computer it replaces an
installed Twinbar.
#>
param([Parameter(Mandatory = $true)] [string] $Setup)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0

function Assert-True([bool] $Condition, [string] $What, [string] $Detail = '') {
  if ($Condition) {
    $script:passed++
    Write-Host "  ok    $What"
  } else {
    $script:failed++
    Write-Host "  FAIL  $What" -ForegroundColor Red
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
    if ($env:GITHUB_ACTIONS -eq 'true') {
      $message = ("$What. $Detail" -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')
      Write-Host "::error title=Twinbar installer test failed::$message"
    }
  }
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return [bool](& $Condition)
}

function Get-UserPath {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}

function Get-UninstallEntry {
  Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'Twinbar' }
}

$setupPath = (Resolve-Path -LiteralPath $Setup).Path
$version = ([regex]::Match((Split-Path -Leaf $setupPath), 'Twinbar-Setup-(.+)\.exe$')).Groups[1].Value
$dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Twinbar'
$link = Join-Path ([Environment]::GetFolderPath('Programs')) 'Twinbar\Twinbar.lnk'
$log = Join-Path ([IO.Path]::GetTempPath()) 'twinbar-setup-test.log'

try {
  Write-Host "== Installing $(Split-Path -Leaf $setupPath)"
  $install = Start-Process -FilePath $setupPath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/TASKS=addtopath', "/LOG=`"$log`"") -Wait -PassThru
  Assert-True ($install.ExitCode -eq 0) 'the installer finished' "exit code $($install.ExitCode)"
  foreach ($file in 'twinbar.ps1', 'twinbar.cmd', 'Twinbar.exe', 'twinbar.ico', 'README.md', 'LICENSE', '.twinbar-install') {
    Assert-True (Test-Path -LiteralPath (Join-Path $dir $file)) "installed $file"
  }
  $exe = Join-Path $dir 'Twinbar.exe'
  if (Test-Path -LiteralPath $exe) {
    Assert-True ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -eq "$version.0") "Twinbar.exe is version $version"
  }
  Assert-True (Test-Path -LiteralPath $link) 'Twinbar is in the Start menu'
  $entry = @(Get-UninstallEntry)
  Assert-True ($entry.Count -eq 1) 'Twinbar is in Settings > Apps'
  if ($entry.Count -eq 1) { Assert-True ($entry[0].DisplayVersion -eq $version) "with version $version" "shows $($entry[0].DisplayVersion)" }
  Assert-True (@((Get-UserPath) -split ';' | Where-Object { $_.TrimEnd('\') -ieq $dir }).Count -eq 1) 'the PATH option put Twinbar on the user PATH'

  $cmd = New-Object Diagnostics.ProcessStartInfo
  $cmd.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
  $cmd.Arguments = '/c ""' + (Join-Path $dir 'twinbar.cmd') + '" version"'
  $cmd.UseShellExecute = $false
  $cmd.RedirectStandardOutput = $true
  $cmd.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($cmd)
  $out = $proc.StandardOutput.ReadToEnd()
  $proc.WaitForExit()
  Assert-True ($out -match [regex]::Escape("twinbar $version")) 'the installed twinbar.cmd runs' $out

  if (Test-Path -LiteralPath $exe) {
    $app = [Diagnostics.Process]::Start($exe)
    $up = Wait-Until { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 120
    Assert-True $up 'Twinbar opens its window'
    if ($up) {
      Assert-True ($app.MainWindowTitle -eq 'Twinbar') 'titled Twinbar' $app.MainWindowTitle
      # What the window's X button sends (WM_SYSCOMMAND, SC_CLOSE).
      Add-Type -Namespace TwinbarInstallerTest -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);'
      [void][TwinbarInstallerTest.User32]::PostMessageW($app.MainWindowHandle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)
      Assert-True (Wait-Until { $app.Refresh(); $app.HasExited -or $app.MainWindowHandle -eq [IntPtr]::Zero } 10) 'closing the window hides it'
      Assert-True (-not $app.HasExited) 'and Twinbar stays by the clock'
      $quit = Start-Process -FilePath $exe -ArgumentList '--quit' -PassThru -Wait
      Assert-True ($quit.ExitCode -eq 0 -and $app.WaitForExit(15000)) 'Twinbar.exe --quit ends it'
    }
    if (-not $app.HasExited) { $app.Kill() }
  }

  Write-Host ''
  Write-Host '== Uninstalling'
  if ($entry.Count -eq 1) {
    $uninstaller = ($entry[0].UninstallString).Trim('"')
    $remove = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    Assert-True ($remove.ExitCode -eq 0) 'the uninstaller finished' "exit code $($remove.ExitCode)"
    # The uninstaller hands over to a copy of itself; wait for that to finish.
    Assert-True (Wait-Until { -not (Test-Path -LiteralPath $dir) } 120) "Twinbar's folder is gone" (@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')
    Assert-True (-not (Test-Path -LiteralPath $link)) 'the Start menu entry is gone'
    Assert-True (@(Get-UninstallEntry).Count -eq 0) 'Settings > Apps no longer lists it'
    Assert-True (@((Get-UserPath) -split ';' | Where-Object { $_.TrimEnd('\') -ieq $dir }).Count -eq 0) 'the PATH entry is gone'
  }
} finally {
  if ($script:failed -and (Test-Path -LiteralPath $log)) {
    Write-Host ''
    Write-Host '== Setup log (end)'
    Get-Content -LiteralPath $log -Tail 60 | ForEach-Object { Write-Host "  $_" }
  }
}

Write-Host ''
if ($script:failed) {
  Write-Host "$($script:passed) passed, $($script:failed) FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All $($script:passed) installer checks passed."
exit 0
