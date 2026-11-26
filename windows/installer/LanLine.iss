; Lan-Line Windows installer (Inno Setup 7). From the repo root:
;   dotnet publish windows/LanLine.App -c Release -r win-x64 --self-contained true -o windows/publish-sc
;   ISCC windows/installer/LanLine.iss            -> dist/Lan-Line-<version>-windows-setup.exe
; Paths can be overridden with /DLicensePath=... /DOutDir=... /DSourceDir=...
; Per-user install (no admin prompt), self-contained .NET, Start menu shortcut, optional sign-in start, clean uninstall.
#define AppVersion "0.9.0"
#define AppVersionFull "0.9.0-beta.10"
#ifndef SourceDir
  #define SourceDir "..\publish-sc"
#endif
; The MIT license, one line per paragraph, so the wizard's license box wraps it cleanly.
#ifndef LicensePath
  #define LicensePath "License.txt"
#endif
#ifndef OutDir
  #define OutDir "..\..\dist"
#endif

[Setup]
AppId={{6F0B1E52-4C1B-4C8F-9E0A-6B7C3F2D9A41}
AppName=Lan-Line
AppVersion={#AppVersionFull}
AppVerName=Lan-Line {#AppVersionFull}
VersionInfoVersion={#AppVersion}
AppPublisher=Avery Robinson
AppPublisherURL=https://averywrobinson.com/lan-line/
AppSupportURL=https://github.com/averywrobinson/lan-line/issues
AppUpdatesURL=https://github.com/averywrobinson/lan-line/releases
DefaultDirName={localappdata}\Programs\Lan-Line
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
WizardStyle=modern
WizardSizePercent=100
SetupIconFile=..\LanLine.App\LanLine.ico
UninstallDisplayIcon={app}\Lan-Line.exe
UninstallDisplayName=Lan-Line
LicenseFile={#LicensePath}
OutputDir={#OutDir}
OutputBaseFilename=Lan-Line-{#AppVersionFull}-windows-setup
Compression=lzma2/ultra64
SolidCompression=yes
; No AppMutex: Inno would only say "please close Lan-Line" (and cancel when silent).
; [Code] below closes the running app politely instead, for both setup and uninstall.
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Add a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Leftovers from 0.9.0-beta.1, which shipped the core library under its old name. [Files] only adds and
; replaces, so an upgrade would otherwise keep these next to LanLine.Core.dll.
Type: files; Name: "{app}\Ferry.Core.dll"
Type: files; Name: "{app}\Ferry.Core.pdb"
; Builds up to 0.9.0-beta.3 also shipped .pdb files, which carry the build machine's source path.
; The build no longer makes them (DebugType=none), so remove any an older install left behind.
Type: files; Name: "{app}\*.pdb"

[Icons]
Name: "{userprograms}\Lan-Line"; Filename: "{app}\Lan-Line.exe"
Name: "{userdesktop}\Lan-Line"; Filename: "{app}\Lan-Line.exe"; Tasks: desktopicon
; Explorer: right-click → Send to → Lan-Line (beta.8). Stages the files in the window; nothing is sent until Send.
Name: "{usersendto}\Lan-Line"; Filename: "{app}\Lan-Line.exe"; Parameters: "--stage"; Comment: "Get these ready to send with Lan-Line"

[Registry]
; "Open Lan-Line when I sign in" lives in the app's Settings since beta.10 (the Run value, with --background); the
; old installer checkbox is gone so an upgrade never turns it back on. Uninstall removes the value (see [Code]).
; "Send with Lan-Line" for files and folders (beta.8). Per user, so no admin prompt; on Windows 11 it is under
; "Show more options" (the new top-level menu only lists packaged, signed apps). Removed on uninstall.
Root: HKCU; Subkey: "Software\Classes\*\shell\LanLine.Send"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Send with Lan-Line"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\LanLine.Send"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Lan-Line.exe"",0"
Root: HKCU; Subkey: "Software\Classes\*\shell\LanLine.Send\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Lan-Line.exe"" --stage ""%1"""
Root: HKCU; Subkey: "Software\Classes\Directory\shell\LanLine.Send"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Send with Lan-Line"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\LanLine.Send"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\Lan-Line.exe"",0"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\LanLine.Send\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Lan-Line.exe"" --stage ""%1"""

; Notifications (beta.10): the toast sender's name and icon (unpackaged apps register their AppUserModelID per
; user; the app also rewrites these at start), and lanline: links, which the toast buttons open.
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\LanLine.Desktop"; ValueType: string; ValueName: "DisplayName"; ValueData: "Lan-Line"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\lanline"; ValueType: string; ValueName: ""; ValueData: "URL:Lan-Line"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\lanline"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\lanline\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\Lan-Line.exe"",0"
Root: HKCU; Subkey: "Software\Classes\lanline\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Lan-Line.exe"" --url ""%1"""

[Run]
Filename: "{app}\Lan-Line.exe"; Description: "Open Lan-Line"; Flags: nowait postinstall skipifsilent
; One-click update from inside Lan-Line (beta.10): silent, then reopen it.
Filename: "{app}\Lan-Line.exe"; Flags: nowait; Check: IsLanLineUpdate

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  AppMutexName = 'Local\Lan-Line.SingleInstance';

// Ask a running Lan-Line to close (WM_CLOSE via taskkill without /F) and wait up to 10 s for it to go.
function CloseRunningLanLine(Silent: Boolean; const Verb: String): Boolean;
var
  Code, I: Integer;
begin
  Result := True;
  if not CheckForMutexes(AppMutexName) then Exit;
  if not Silent then
    if SuppressibleMsgBox('Lan-Line is running. It will be closed so ' + Verb + ' can continue.',
         mbInformation, MB_OKCANCEL, IDOK) <> IDOK then
    begin
      Result := False;
      Exit;
    end;
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM Lan-Line.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  for I := 1 to 40 do
  begin
    if not CheckForMutexes(AppMutexName) then Exit;
    Sleep(250);
  end;
  Result := not CheckForMutexes(AppMutexName);
  if not Result then
    SuppressibleMsgBox('Lan-Line did not close. Close it from its window, then run ' + Verb + ' again.',
      mbError, MB_OK, IDOK);
end;

// Started by Lan-Line's own Install button (/lanlineupdate=1), not by winget or a user.
function IsLanLineUpdate(): Boolean;
begin
  Result := ExpandConstant('{param:lanlineupdate|0}') = '1';
end;

function InitializeSetup(): Boolean;
begin
  Result := CloseRunningLanLine(WizardSilent(), 'setup');
end;

function InitializeUninstall(): Boolean;
begin
  Result := CloseRunningLanLine(UninstallSilent(), 'uninstall');
end;

// Open at sign-in is set in Lan-Line's Settings (beta.10); take it away with the app.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Lan-Line');
end;
