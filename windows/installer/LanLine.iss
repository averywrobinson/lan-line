; Lan-Line Windows installer (Inno Setup 7). From the repo root:
;   dotnet publish windows/LanLine.App -c Release -r win-x64 --self-contained true -o windows/publish-sc
;   ISCC windows/installer/LanLine.iss            -> dist/Lan-Line-<version>-windows-setup.exe
; Paths can be overridden with /DLicensePath=... /DOutDir=... /DSourceDir=...
; Per-user install (no admin prompt), self-contained .NET, Start menu shortcut, optional sign-in start, clean uninstall.
#define AppVersion "0.9.0"
#define AppVersionFull "0.9.0-beta.3"
#ifndef SourceDir
  #define SourceDir "..\publish-sc"
#endif
#ifndef LicensePath
  #define LicensePath "..\..\LICENSE"
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
AppPublisherURL=https://lan-line.averywrobinson.com
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
Name: "startup"; Description: "Start Lan-Line when I sign in"; Flags: unchecked
Name: "desktopicon"; Description: "Add a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Leftovers from 0.9.0-beta.1, which shipped the core library under its old name. [Files] only adds and
; replaces, so an upgrade would otherwise keep these next to LanLine.Core.dll.
Type: files; Name: "{app}\Ferry.Core.dll"
Type: files; Name: "{app}\Ferry.Core.pdb"

[Icons]
Name: "{userprograms}\Lan-Line"; Filename: "{app}\Lan-Line.exe"
Name: "{userdesktop}\Lan-Line"; Filename: "{app}\Lan-Line.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Lan-Line"; ValueData: """{app}\Lan-Line.exe"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Lan-Line.exe"; Description: "Open Lan-Line"; Flags: nowait postinstall skipifsilent

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

function InitializeSetup(): Boolean;
begin
  Result := CloseRunningLanLine(WizardSilent(), 'setup');
end;

function InitializeUninstall(): Boolean;
begin
  Result := CloseRunningLanLine(UninstallSilent(), 'uninstall');
end;
