<#
.SYNOPSIS
Twinbar: a second, separately signed-in copy of an Electron app on Windows.

.DESCRIPTION
  twinbar new -App PATH -Name NAME [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
  twinbar list [-Json]
  twinbar open PROFILE
  twinbar remove PROFILE [-DeleteData]
  twinbar help
  twinbar version

PATH is the app's .exe, its install folder or its Start menu shortcut.
PROFILE is a profile's name ("Work"), its full name ("Postman Work") or its id
("postman.work"); see twinbar list.

https://github.com/sadrazkh/twinbar (MIT licence)
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Position = 0)] [string] $Command = 'help',
  [Parameter(Position = 1)] [string] $Target,
  [string] $App,
  [string] $Name,
  [string] $DataDir,
  [switch] $AdoptDataDir,
  [string] $ShortcutDir,
  [switch] $DeleteData,
  [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TwinbarVersion = '0.1.0'
$script:MarkerName = '.twinbar-profile' # in each data folder Twinbar created or adopted
$script:AppIdPrefix = 'Twinbar'          # AppUserModelID: Twinbar.<app id>.<name key>
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------------------
# Windows interop: shortcuts with an AppUserModelID, and the Recycle Bin.
# Compiled once per run by Add-Type (C# 5, so it works with Windows PowerShell 5.1).
# ---------------------------------------------------------------------------

$script:InteropSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace TwinbarInterop {
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct PropertyKey {
    public Guid FormatId;
    public uint PropertyId;
    public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
  }

  // PROPVARIANT: only the type and a pointer are used; Size covers 64-bit Windows.
  [StructLayout(LayoutKind.Explicit, Size = 24)]
  public struct PropVariant {
    [FieldOffset(0)] public ushort VarType;
    [FieldOffset(8)] public IntPtr Pointer;
  }

  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
    [PreserveSig] int Commit();
  }

  [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int cch, IntPtr findData, uint flags);
    void GetIDList(out IntPtr pidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
    void GetHotkey(out short hotkey);
    void SetHotkey(short hotkey);
    void GetShowCmd(out int showCmd);
    void SetShowCmd(int showCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int cch, out int iconIndex);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relPath, uint reserved);
    void Resolve(IntPtr hwnd, uint flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
  }

  [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
  public class ShellLinkObject { }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct FileOperation {
    public IntPtr Hwnd;
    public uint Func;
    public string From;
    public string To;
    public ushort Flags;
    public int AnyOperationsAborted;
    public IntPtr NameMappings;
    public string ProgressTitle;
  }

  public static class Shell {
    static readonly Guid AppUserModelFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    const uint AppUserModelIdProperty = 5;
    const ushort VT_LPWSTR = 31;

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref FileOperation operation);

    static void Check(int hr, string what) {
      if (hr != 0) throw new InvalidOperationException("couldn't " + what + " (0x" + hr.ToString("X8") + ")");
    }

    public static void SaveLink(string path, string target, string arguments, string workingDirectory,
                                string iconPath, int iconIndex, string description, string appUserModelId) {
      IShellLinkW link = (IShellLinkW)new ShellLinkObject();
      try {
        link.SetPath(target);
        link.SetArguments(arguments ?? "");
        if (!String.IsNullOrEmpty(workingDirectory)) link.SetWorkingDirectory(workingDirectory);
        if (!String.IsNullOrEmpty(iconPath)) link.SetIconLocation(iconPath, iconIndex);
        if (!String.IsNullOrEmpty(description)) link.SetDescription(description);
        if (!String.IsNullOrEmpty(appUserModelId)) {
          IPropertyStore store = (IPropertyStore)link;
          PropertyKey key = new PropertyKey(AppUserModelFormat, AppUserModelIdProperty);
          PropVariant value = new PropVariant();
          value.VarType = VT_LPWSTR;
          value.Pointer = Marshal.StringToCoTaskMemUni(appUserModelId);
          try {
            Check(store.SetValue(ref key, ref value), "set the shortcut's AppUserModelID");
            Check(store.Commit(), "save the shortcut's properties");
          } finally {
            Marshal.FreeCoTaskMem(value.Pointer);
          }
        }
        ((IPersistFile)link).Save(path, true);
      } finally {
        Marshal.ReleaseComObject(link);
      }
    }

    // Returns target, arguments, working directory, icon path, icon index, AppUserModelID.
    public static string[] ReadLink(string path) {
      IShellLinkW link = (IShellLinkW)new ShellLinkObject();
      try {
        ((IPersistFile)link).Load(path, 0);
        StringBuilder text = new StringBuilder(32768);
        link.GetPath(text, text.Capacity, IntPtr.Zero, 0);
        string target = text.ToString();
        text.Length = 0;
        link.GetArguments(text, text.Capacity);
        string arguments = text.ToString();
        text.Length = 0;
        link.GetWorkingDirectory(text, text.Capacity);
        string workingDirectory = text.ToString();
        text.Length = 0;
        int iconIndex;
        link.GetIconLocation(text, text.Capacity, out iconIndex);
        string iconPath = text.ToString();
        string appUserModelId = "";
        IPropertyStore store = (IPropertyStore)link;
        PropertyKey key = new PropertyKey(AppUserModelFormat, AppUserModelIdProperty);
        PropVariant value;
        if (store.GetValue(ref key, out value) == 0) {
          try {
            if (value.VarType == VT_LPWSTR && value.Pointer != IntPtr.Zero) appUserModelId = Marshal.PtrToStringUni(value.Pointer);
          } finally {
            PropVariantClear(ref value);
          }
        }
        return new string[] { target, arguments, workingDirectory, iconPath, iconIndex.ToString(), appUserModelId };
      } finally {
        Marshal.ReleaseComObject(link);
      }
    }

    // Moves a file or folder to the Recycle Bin without asking. Windows still warns
    // before deleting outright, which happens only where there is no Recycle Bin.
    public static void Recycle(string path) {
      FileOperation op = new FileOperation();
      op.Func = 3;                                  // FO_DELETE
      op.From = path + "\0\0";
      op.Flags = 0x0040 | 0x0010 | 0x0004 | 0x0400 | 0x4000;
      // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING
      int result = SHFileOperation(ref op);
      if (result != 0) throw new InvalidOperationException("couldn't move " + path + " to the Recycle Bin (error " + result + ")");
      if (op.AnyOperationsAborted != 0) throw new InvalidOperationException("moving " + path + " to the Recycle Bin was cancelled");
    }
  }
}
'@

function Initialize-Interop {
  if (-not ('TwinbarInterop.Shell' -as [type])) {
    Add-Type -TypeDefinition $script:InteropSource -Language CSharp
  }
}

function Save-ShellLink {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $TargetPath,
    [string] $Arguments = '',
    [string] $WorkingDirectory = '',
    [string] $IconPath = '',
    [int] $IconIndex = 0,
    [string] $Description = '',
    [string] $AppUserModelId = ''
  )
  Initialize-Interop
  [TwinbarInterop.Shell]::SaveLink($Path, $TargetPath, $Arguments, $WorkingDirectory, $IconPath, $IconIndex, $Description, $AppUserModelId)
}

function Read-ShellLink([string] $Path) {
  Initialize-Interop
  $v = [TwinbarInterop.Shell]::ReadLink($Path)
  [pscustomobject]@{
    TargetPath       = $v[0]
    Arguments        = $v[1]
    WorkingDirectory = $v[2]
    IconPath         = $v[3]
    IconIndex        = [int]$v[4]
    AppUserModelId   = $v[5]
  }
}

function Move-ToRecycleBin([string] $Path) {
  Initialize-Interop
  [TwinbarInterop.Shell]::Recycle($Path)
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Stop-Twinbar([string] $Message) {
  throw $Message
}

function Get-TwinbarHome {
  if ($env:TWINBAR_HOME) { return $env:TWINBAR_HOME.TrimEnd('\') }
  return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Twinbar')
}

function Get-ProfilesDir { Join-Path (Get-TwinbarHome) 'profiles' }

function Get-RecordPath([string] $Id) { Join-Path (Get-ProfilesDir) "$Id.json" }

function Get-DefaultShortcutDir { Join-Path ([Environment]::GetFolderPath('Programs')) 'Twinbar' }

function Resolve-FullPath([string] $Path) {
  $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
  if (-not [IO.Path]::IsPathRooted($p)) {
    $p = Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $p
  }
  return [IO.Path]::GetFullPath($p)
}

# Names: letters (any language), digits, spaces, '.', '_' and '-'; 1 to 40 characters.
# Inside a name, combining marks and the zero-width non-joiner (used in Persian) are fine too.
$script:NamePattern = '^[\p{L}\p{N}](?:[\p{L}\p{N}\p{Mn}' + [char]0x200C + ' ._-]*[\p{L}\p{N}\p{Mn}])?$'
function Test-ProfileName([string] $Value) {
  if ($null -eq $Value -or $Value.Trim().Length -eq 0) { Stop-Twinbar 'a profile name is required (-Name)' }
  $n = $Value.Trim()
  if ($n.Length -gt 40) { Stop-Twinbar 'the profile name must be at most 40 characters' }
  if ($n -cnotmatch $script:NamePattern) {
    Stop-Twinbar "the profile name may use letters, digits, spaces, '.', '_' and '-', and must start and end with a letter or digit"
  }
  if ($n -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { Stop-Twinbar "'$n' is a name Windows reserves" }
  return $n
}

# A short ASCII key for ids and file names: "My Work 2" -> "my-work-2".
# Names with no ASCII letters or digits get a stable hash-based key instead.
function Get-NameKey([string] $Value) {
  $k = ($Value.ToLowerInvariant() -creplace '[^a-z0-9]+', '-').Trim('-')
  if ($k.Length -gt 32) { $k = $k.Substring(0, 32).Trim('-') }
  if ($k.Length -eq 0) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) } finally { $sha.Dispose() }
    $k = 'p' + (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  return $k
}

function Test-IsStoreAppPath([string] $Path) {
  return ($Path -match '\\WindowsApps\\')
}

function Test-ElectronDir([string] $Dir) {
  return ((Test-Path -LiteralPath (Join-Path $Dir 'resources\app.asar') -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $Dir 'resources\app\package.json') -PathType Leaf))
}

# The newest "app-<version>" folder of a Squirrel install that holds ExeName.
function Get-SquirrelLatestDir([string] $Root, [string] $ExeName) {
  $best = $null
  $bestVersion = $null
  foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)) {
    $v = $null
    $text = ($d.Name.Substring(4) -split '-')[0]
    if (-not [version]::TryParse($text, [ref] $v)) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName $ExeName) -PathType Leaf)) { continue }
    if ($null -eq $bestVersion -or $v -gt $bestVersion) {
      $best = $d.FullName
      $bestVersion = $v
    }
  }
  return $best
}

function Find-AppExeInFolder([string] $Folder) {
  $skip = '^(update|squirrel|elevate|uninstall.*|unins\d+|.*helper.*|crashpad_handler)\.exe$'
  $exes = @(Get-ChildItem -LiteralPath $Folder -Filter '*.exe' -File | Where-Object { $_.Name -notmatch $skip })
  if (Test-Path -LiteralPath (Join-Path $Folder 'Update.exe') -PathType Leaf) {
    $exes = @($exes | Where-Object { Get-SquirrelLatestDir $Folder $_.Name })
  } elseif (-not (Test-ElectronDir $Folder)) {
    Stop-Twinbar "no Electron app found in $Folder"
  }
  if ($exes.Count -eq 1) { return $exes[0].FullName }
  if ($exes.Count -eq 0) { Stop-Twinbar "no program found in $Folder" }
  $leaf = (Split-Path -Leaf $Folder) -replace '[^a-z0-9]', ''
  $byName = @($exes | Where-Object { ($_.BaseName -replace '[^a-z0-9]', '') -ieq $leaf })
  if ($byName.Count -eq 1) { return $byName[0].FullName }
  Stop-Twinbar ("found several programs in {0}; pass the .exe instead: {1}" -f $Folder, (($exes | ForEach-Object { $_.Name }) -join ', '))
}

# Works out how to start an Electron app from its .exe, install folder or shortcut.
#   Kind      standard (one folder) or squirrel (Update.exe + app-<version> folders)
#   LaunchExe what the profile's shortcut starts; for Squirrel the root launcher,
#             which always starts the newest version and passes the arguments on
#   RealExe   the Electron executable that ends up running
function Resolve-ElectronApp([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    Stop-Twinbar 'which app? Give -App: its .exe, its install folder or its Start menu shortcut'
  }
  $p = Resolve-FullPath $Path
  if (-not (Test-Path -LiteralPath $p)) { Stop-Twinbar "not found: $p" }

  $displayName = ''
  if ($p -match '\.lnk$') {
    $link = Read-ShellLink $p
    if ($link.AppUserModelId -like "$script:AppIdPrefix.*") {
      Stop-Twinbar 'that is a Twinbar profile; give the original app instead'
    }
    $displayName = [IO.Path]::GetFileNameWithoutExtension($p)
    $t = [Environment]::ExpandEnvironmentVariables($link.TargetPath)
    if (-not $t) { Stop-Twinbar "the shortcut doesn't point to a program: $p" }
    if ([IO.Path]::GetFileName($t) -ieq 'Update.exe' -and
      $link.Arguments -match '--processStart(?:=|\s+)(?:"([^"]+)"|(\S+))') {
      $exe = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
      $t = Join-Path (Split-Path -Parent $t) $exe
    }
    $p = $t
    if (-not (Test-Path -LiteralPath $p)) { Stop-Twinbar "the shortcut points to something that's missing: $p" }
  }
  if (Test-IsStoreAppPath $p) {
    Stop-Twinbar 'Microsoft Store apps (installed under WindowsApps), such as Claude, are not supported yet'
  }
  if (Test-Path -LiteralPath $p -PathType Container) { $p = Find-AppExeInFolder $p }
  if ($p -notmatch '\.exe$') { Stop-Twinbar "not a program (.exe): $p" }

  $exeName = [IO.Path]::GetFileName($p)
  $dir = Split-Path -Parent $p
  $parent = Split-Path -Parent $dir
  # An exe inside a Squirrel app-<version> folder: use the root launcher instead.
  if ((Split-Path -Leaf $dir) -like 'app-*' -and $parent -and
    (Test-Path -LiteralPath (Join-Path $parent 'Update.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $parent $exeName) -PathType Leaf)) {
    $dir = $parent
    $p = Join-Path $parent $exeName
  }
  $kind = ''
  $real = ''
  if (Test-Path -LiteralPath (Join-Path $dir 'Update.exe') -PathType Leaf) {
    $latest = Get-SquirrelLatestDir $dir $exeName
    if ($latest -and (Test-ElectronDir $latest)) {
      $kind = 'squirrel'
      $real = Join-Path $latest $exeName
    }
  }
  if (-not $kind -and (Test-ElectronDir $dir)) {
    $kind = 'standard'
    $real = $p
  }
  if (-not $kind) { Stop-Twinbar "$exeName doesn't look like an Electron app (there's no resources\app.asar next to it)" }

  if (-not $displayName) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($real)
    foreach ($candidate in @($info.ProductName, $info.FileDescription)) {
      if ($candidate -and $candidate.Trim()) {
        $displayName = $candidate.Trim()
        break
      }
    }
  }
  $displayName = ($displayName -replace '[\\/:*?"<>|]', '').Trim()
  if (-not $displayName) { $displayName = [IO.Path]::GetFileNameWithoutExtension($exeName) }

  [pscustomobject]@{
    Name      = $displayName
    Id        = Get-NameKey ([IO.Path]::GetFileNameWithoutExtension($exeName))
    Kind      = $kind
    LaunchExe = $p
    RealExe   = $real
  }
}

# missing | file | empty | ours | other:<profile id> | foreign (has files, no marker)
function Get-DataDirState([string] $Dir, [string] $Id) {
  if (-not (Test-Path -LiteralPath $Dir)) { return 'missing' }
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 'file' }
  $marker = Join-Path $Dir $script:MarkerName
  if (Test-Path -LiteralPath $marker -PathType Leaf) {
    $owner = ([IO.File]::ReadAllText($marker)).Trim()
    if ($owner -ieq $Id) { return 'ours' }
    return "other:$owner"
  }
  if (@(Get-ChildItem -LiteralPath $Dir -Force | Select-Object -First 1).Count -eq 0) { return 'empty' }
  return 'foreign'
}

# Folders a profile must never use as its data folder (removing it would be a disaster).
function Test-ProtectedDir([string] $Dir) {
  $d = $Dir.TrimEnd('\')
  if ($d.Length -le 2) { return $true } # a drive root
  $twHome = Get-TwinbarHome
  $userProfile = [Environment]::GetFolderPath('UserProfile')
  $protected = @(
    $userProfile, (Split-Path -Parent $userProfile),
    [Environment]::GetFolderPath('ApplicationData'), [Environment]::GetFolderPath('LocalApplicationData'),
    [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
    [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'),
    [Environment]::GetFolderPath('Windows'), $env:TEMP,
    $twHome, (Join-Path $twHome 'data'), (Join-Path $twHome 'profiles')
  )
  foreach ($x in $protected) {
    if ($x -and $d -ieq $x.TrimEnd('\')) { return $true }
  }
  return $false
}

function Get-AllProfiles {
  $dir = Get-ProfilesDir
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $required = 'id', 'name', 'appName', 'launchExe', 'realExe', 'dataDir', 'shortcut', 'aumid'
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name)) {
    try {
      $record = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      Write-Warning "skipping $($f.Name): it isn't valid JSON"
      continue
    }
    $names = @($record.PSObject.Properties | ForEach-Object { $_.Name })
    $missing = @($required | Where-Object { $names -notcontains $_ })
    if ($missing.Count) {
      Write-Warning "skipping $($f.Name): it has no $($missing -join ', ')"
      continue
    }
    $record
  }
}

function Write-Record($Record) {
  [void][IO.Directory]::CreateDirectory((Get-ProfilesDir))
  $path = Get-RecordPath $Record.id
  $tmp = "$path.tmp"
  [IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Find-Profile([string] $Which) {
  if ([string]::IsNullOrWhiteSpace($Which)) {
    Stop-Twinbar 'which profile? Give its name, its full name or its id (see: twinbar list)'
  }
  $t = $Which.Trim()
  $all = @(Get-AllProfiles)
  $found = @($all | Where-Object { $_.id -ieq $t })
  if (-not $found.Count) { $found = @($all | Where-Object { ('{0} {1}' -f $_.appName, $_.name) -ieq $t -or $_.shortcut -ieq $t }) }
  if (-not $found.Count) { $found = @($all | Where-Object { $_.name -ieq $t }) }
  if ($found.Count -eq 0) { Stop-Twinbar "there's no profile called '$t' (see: twinbar list)" }
  if ($found.Count -gt 1) {
    Stop-Twinbar ("'{0}' matches more than one profile; use the id: {1}" -f $t, (($found | ForEach-Object { $_.id }) -join ', '))
  }
  return $found[0]
}

# Processes started with --user-data-dir, fetched once per run.
$script:DataDirProcesses = $null
function Get-DataDirProcesses {
  if ($null -eq $script:DataDirProcesses) {
    $script:DataDirProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "CommandLine LIKE '%--user-data-dir%'" -ErrorAction SilentlyContinue)
  }
  return $script:DataDirProcesses
}

function Get-ProfileProcesses($Record) {
  $pattern = '--user-data-dir="?' + [regex]::Escape($Record.dataDir.TrimEnd('\')) + '"?(?=\s|$)'
  @(Get-DataDirProcesses) | Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern }
}

function Get-ProfileStatus($Record) {
  if (@(Get-ProfileProcesses $Record).Count) { return 'running' }
  if (-not (Test-Path -LiteralPath $Record.shortcut -PathType Leaf)) { return 'shortcut missing' }
  if (-not (Test-Path -LiteralPath $Record.launchExe -PathType Leaf)) { return 'app missing' }
  return 'ready'
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

function Invoke-New {
  param([string] $AppPath, [string] $ProfileName, [string] $DataFolder, [switch] $Adopt, [string] $MenuDir)

  $label = Test-ProfileName $ProfileName
  $app = Resolve-ElectronApp $AppPath
  $key = Get-NameKey $label
  $id = "$($app.Id).$key"
  $aumid = "$script:AppIdPrefix.$id"
  $fullName = "$($app.Name) $label"

  if (Test-Path -LiteralPath (Get-RecordPath $id)) {
    Stop-Twinbar "there's already a profile '$id' (see: twinbar list)"
  }
  $menu = if ($MenuDir) { Resolve-FullPath $MenuDir } else { Get-DefaultShortcutDir }
  $shortcut = Join-Path $menu "$fullName.lnk"
  if (Test-Path -LiteralPath $shortcut) {
    Stop-Twinbar "there's already a shortcut called '$fullName.lnk' in $menu; remove or rename it first"
  }

  $dataRoot = Join-Path (Join-Path (Get-TwinbarHome) 'data') $app.Id
  $dd = if ($DataFolder) { Resolve-FullPath $DataFolder } else { Join-Path $dataRoot $key }
  $dd = $dd.TrimEnd('\')
  if ($dd.Contains('"')) { Stop-Twinbar 'the data folder path may not contain quotes' }
  if (Test-ProtectedDir $dd) { Stop-Twinbar "$dd can't be a profile's data folder; pick a folder of its own" }
  foreach ($exe in @($app.LaunchExe, $app.RealExe)) {
    if ($exe.StartsWith($dd + '\', [StringComparison]::OrdinalIgnoreCase)) {
      Stop-Twinbar "the data folder can't contain the app itself: $dd"
    }
  }
  foreach ($other in @(Get-AllProfiles)) {
    if ($other.dataDir.TrimEnd('\') -ieq $dd) { Stop-Twinbar "the profile '$($other.id)' already uses $dd" }
  }

  $state = Get-DataDirState $dd $id
  $dataNote = 'new'
  if ($state -eq 'file') { Stop-Twinbar "the data folder is a file: $dd" }
  if ($state -like 'other:*') {
    $owner = $state.Substring(6)
    if (Test-Path -LiteralPath (Get-RecordPath $owner)) { Stop-Twinbar "that data folder belongs to the profile '$owner'" }
    if (-not $Adopt) { Stop-Twinbar "that data folder belonged to the removed profile '$owner'; add -AdoptDataDir to use it for this one" }
    $dataNote = 'adopted'
  }
  if ($state -eq 'foreign') {
    if (-not $Adopt) {
      Stop-Twinbar "the data folder already has files in it: $dd. Add -AdoptDataDir to use it for this profile (the app will see what's there)"
    }
    $dataNote = 'adopted'
  }
  if ($state -eq 'ours') { $dataNote = 'kept from before' }

  $createdDir = -not (Test-Path -LiteralPath $dd)
  $markerPath = Join-Path $dd $script:MarkerName
  $oldMarker = if (Test-Path -LiteralPath $markerPath -PathType Leaf) { [IO.File]::ReadAllText($markerPath) } else { $null }
  [void][IO.Directory]::CreateDirectory($dd)
  [IO.File]::WriteAllText($markerPath, $id, $script:Utf8NoBom)
  try {
    [void][IO.Directory]::CreateDirectory($menu)
    Save-ShellLink -Path $shortcut -TargetPath $app.LaunchExe `
      -Arguments ('--user-data-dir="' + $dd + '"') `
      -WorkingDirectory (Split-Path -Parent $app.LaunchExe) `
      -IconPath $app.LaunchExe -IconIndex 0 `
      -Description "$fullName (a Twinbar profile of $($app.Name))" `
      -AppUserModelId $aumid
    Write-Record ([ordered]@{
        schema         = 1
        id             = $id
        name           = $label
        appName        = $app.Name
        appId          = $app.Id
        appKind        = $app.Kind
        launchExe      = $app.LaunchExe
        realExe        = $app.RealExe
        dataDir        = $dd
        shortcut       = $shortcut
        aumid          = $aumid
        created        = (Get-Date).ToString('o')
        twinbarVersion = $script:TwinbarVersion
      })
  } catch {
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    if ($createdDir) {
      Remove-Item -LiteralPath $dd -Recurse -Force
    } elseif ($null -ne $oldMarker) {
      [IO.File]::WriteAllText($markerPath, $oldMarker, $script:Utf8NoBom)
    } else {
      Remove-Item -LiteralPath $markerPath -Force
    }
    throw
  }

  "Made ""$fullName""."
  "  Start menu:   $shortcut"
  "  Sign-in data: $dd ($dataNote)"
  "Open it from the Start menu, or run: twinbar open ""$fullName"""
}

function Invoke-List([switch] $AsJson) {
  $rows = @(Get-AllProfiles | ForEach-Object {
      [pscustomobject]@{
        id       = $_.id
        name     = $_.name
        appName  = $_.appName
        fullName = '{0} {1}' -f $_.appName, $_.name
        status   = Get-ProfileStatus $_
        dataDir  = $_.dataDir
        shortcut = $_.shortcut
        appKind  = if ($_.PSObject.Properties['appKind']) { $_.appKind } else { '' }
        aumid    = $_.aumid
      }
    })
  if ($AsJson) {
    return (ConvertTo-Json -InputObject $rows -Depth 4)
  }
  if (-not $rows.Count) {
    return 'No profiles yet. Make one with: twinbar new -App <app> -Name <name>'
  }
  $w1 = [Math]::Max(7, ($rows | ForEach-Object { $_.fullName.Length } | Measure-Object -Maximum).Maximum)
  $w2 = [Math]::Max(2, ($rows | ForEach-Object { $_.id.Length } | Measure-Object -Maximum).Maximum)
  $w3 = [Math]::Max(6, ($rows | ForEach-Object { $_.status.Length } | Measure-Object -Maximum).Maximum)
  ('{0}  {1}  {2}  {3}' -f 'Profile'.PadRight($w1), 'Id'.PadRight($w2), 'Status'.PadRight($w3), 'Data folder')
  foreach ($r in $rows) {
    ('{0}  {1}  {2}  {3}' -f $r.fullName.PadRight($w1), $r.id.PadRight($w2), $r.status.PadRight($w3), $r.dataDir)
  }
}

function Invoke-Open([string] $Which) {
  $p = Find-Profile $Which
  if (Test-Path -LiteralPath $p.shortcut -PathType Leaf) {
    Start-Process -FilePath $p.shortcut
  } else {
    Write-Warning "the Start menu shortcut is missing ($($p.shortcut)); starting the app directly"
    Start-Process -FilePath $p.launchExe -ArgumentList ('--user-data-dir="' + $p.dataDir + '"')
  }
  "Opening $($p.appName) $($p.name)."
}

function Invoke-Remove([string] $Which, [switch] $WithData) {
  $p = Find-Profile $Which
  $fullName = '{0} {1}' -f $p.appName, $p.name
  if (@(Get-ProfileProcesses $p).Count) { Stop-Twinbar "$fullName is running; quit it first" }

  $report = @()
  if (Test-Path -LiteralPath $p.shortcut -PathType Leaf) {
    $link = Read-ShellLink $p.shortcut
    if ($link.AppUserModelId -ne $p.aumid) {
      Write-Warning "left $($p.shortcut) alone: it isn't the shortcut Twinbar made"
    } else {
      Move-ToRecycleBin $p.shortcut
      $report += '  Start menu shortcut: moved to the Recycle Bin'
    }
  }
  if ($WithData) {
    $state = Get-DataDirState $p.dataDir $p.id
    if ($state -eq 'ours') {
      Move-ToRecycleBin $p.dataDir
      $report += "  Sign-in data: moved to the Recycle Bin ($($p.dataDir))"
    } elseif ($state -ne 'missing') {
      Write-Warning "kept $($p.dataDir): it doesn't carry this profile's Twinbar marker"
    }
  } else {
    $report += "  Sign-in data: kept in $($p.dataDir) (make the profile again to use it, or add -DeleteData to remove it)"
  }
  Remove-Item -LiteralPath (Get-RecordPath $p.id) -Force
  "Removed ""$fullName""."
  $report
}

function Show-Help {
  @"
Twinbar $($script:TwinbarVersion): a second, separately signed-in copy of an Electron app.

  twinbar new -App PATH -Name NAME [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
      Make a profile. PATH is the app's .exe, install folder or Start menu
      shortcut. Adds "<App> <Name>" to the Start menu; the app then keeps that
      profile's sign-in, settings and data in a folder of its own.
  twinbar list [-Json]
      Show the profiles.
  twinbar open PROFILE
      Start a profile.
  twinbar remove PROFILE [-DeleteData]
      Remove a profile's shortcut (to the Recycle Bin). Its sign-in is kept
      unless you add -DeleteData.
  twinbar version

PROFILE is a name ("Work"), a full name ("Postman Work") or an id ("postman.work").
Profiles live in $(Get-TwinbarHome).
"@
}

function Invoke-Twinbar {
  $cmd = if ($Command) { $Command.Trim().ToLowerInvariant() } else { 'help' }
  switch ($cmd) {
    'new' {
      $profileName = if ($Name) { $Name } else { $Target }
      Invoke-New -AppPath $App -ProfileName $profileName -DataFolder $DataDir -Adopt:$AdoptDataDir -MenuDir $ShortcutDir
    }
    'list' { Invoke-List -AsJson:$Json }
    'open' { Invoke-Open $Target }
    'remove' { Invoke-Remove $Target -WithData:$DeleteData }
    'help' { Show-Help }
    'version' { "twinbar $script:TwinbarVersion" }
    default { Stop-Twinbar "unknown command '$Command' (see: twinbar help)" }
  }
}

# Run unless dot-sourced (the tests dot-source this file to reach its functions).
if ($MyInvocation.InvocationName -ne '.') {
  try {
    Invoke-Twinbar
    exit 0
  } catch {
    [Console]::Error.WriteLine('twinbar: ' + $_.Exception.Message)
    exit 1
  }
}
