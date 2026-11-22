; Twinbar's Windows installer (Inno Setup 6). tools\make-release.ps1 -Installer builds it:
;   ISCC.exe /DAppVersion=x.y.z /DIconFile=<twinbar.ico> /O<output folder> installer\twinbar.iss
;
; It installs for the current user only (no admin rights) into
; %LOCALAPPDATA%\Programs\Twinbar, then runs "twinbar install" there, which
; compiles Twinbar.exe on this computer and adds Twinbar to the Start menu,
; exactly as installing from the zip does. Uninstalling runs "twinbar uninstall";
; profiles stay and keep working.

#ifndef AppVersion
  #error Give the version: ISCC /DAppVersion=x.y.z
#endif
#ifndef IconFile
  #error Give Twinbar's icon: ISCC /DIconFile=path\to\twinbar.ico
#endif
#define SourceDir AddBackslash(SourcePath) + ".."
#define PowerShell "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
AppId={{8F3C2B6E-4D1A-4E7B-9C35-2A6F0B9D7E41}
AppName=Twinbar
AppVersion={#AppVersion}
AppVerName=Twinbar {#AppVersion}
AppPublisher=sadrazkh
AppPublisherURL=https://github.com/sadrazkh/twinbar
AppSupportURL=https://github.com/sadrazkh/twinbar/issues
AppUpdatesURL=https://github.com/sadrazkh/twinbar/releases
AppComments=A second, separately signed-in copy of your Electron apps, with its own taskbar button and icon.
DefaultDirName={localappdata}\Programs\Twinbar
DisableDirPage=auto
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
UsedUserAreasWarning=no
MinVersion=10.0
; The Twinbar window holds this mutex: setup and uninstall ask to close it first.
AppMutex=Twinbar.App
ChangesEnvironment=yes
OutputBaseFilename=Twinbar-Setup-{#AppVersion}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\twinbar.ico
UninstallDisplayName=Twinbar
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
SetupLogging=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=Twinbar
VersionInfoDescription=Twinbar setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Let me type ""twinbar"" in any terminal (adds Twinbar to my PATH)"; Flags: unchecked

[Files]
Source: "{#SourceDir}\twinbar.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\twinbar.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "{app}\Twinbar.exe"; Description: "Open Twinbar"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{#PowerShell}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\twinbar.ps1"" uninstall -Dir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "TwinbarUninstall"

[UninstallDelete]
Type: files; Name: "{app}\Twinbar.exe"
Type: files; Name: "{app}\twinbar.ico"
Type: files; Name: "{app}\.twinbar-install"
Type: dirifempty; Name: "{app}"

[Code]
// Runs twinbar.ps1 in the installed folder; its output goes to Output.
function RunTwinbar(const Arguments: String; var Output: String): Integer;
var
  ResultCode: Integer;
  LogFile: String;
  Text: AnsiString;
begin
  LogFile := ExpandConstant('{tmp}\twinbar-setup.log');
  if not Exec(ExpandConstant('{cmd}'),
    '/c ""' + ExpandConstant('{#PowerShell}') + '" -NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\twinbar.ps1') + '" ' + Arguments + ' > "' + LogFile + '" 2>&1"',
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    ResultCode := -1;
  if LoadStringFromFile(LogFile, Text) then
    Output := String(Text)
  else
    Output := '';
  Log('twinbar ' + Arguments + ' exited with ' + IntToStr(ResultCode) + ':' + #13#10 + Output);
  Result := ResultCode;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Arguments, Output: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Setting up Twinbar...';
    Arguments := 'install -Dir "' + ExpandConstant('{app}') + '"';
    if WizardIsTaskSelected('addtopath') then
      Arguments := Arguments + ' -AddToPath';
    // (No line in this section may start with "#": the preprocessor would take it as a directive.)
    if RunTwinbar(Arguments, Output) <> 0 then
      SuppressibleMsgBox('Twinbar''s files were copied, but setting it up didn''t work:' + #13#10#13#10 +
        Output + #13#10 + 'You can try again later in a terminal: twinbar.cmd install', mbError, MB_OK, IDOK)
    else
      // Profiles made with an earlier version get the new launcher and icons; open ones are left as they are.
      RunTwinbar('rebuild -All', Output);
  end;
end;
