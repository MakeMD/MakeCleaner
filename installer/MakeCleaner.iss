; MakeCleaner - per-user installer. Build with tools\release.ps1 (it passes MyAppVersion from src\main.zig).
; Ships dist\publish: MakeCleaner.exe (Zig, Dear ImGui and SQLite compiled in, no runtime dlls), rules\, THIRD-PARTY-NOTICES.txt.
; No autostart, no services, no bundled offers, no network. The only system object the app can own is the
; scheduled task the user creates in Options; uninstall removes it.
; ponytail: no license page, no custom wizard pages, no icon - Inno defaults are enough.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif

[Setup]
AppId={{4F7A2C91-6B3E-4D58-A0E7-9C1D2B3F4E65}
AppName=MakeCleaner
AppVersion={#MyAppVersion}
AppPublisher=MakeMD
DefaultDirName={autopf}\MakeCleaner
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayIcon={app}\MakeCleaner.exe
OutputDir=..\dist
OutputBaseFilename=MakeCleaner-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; 1.x (.NET/WPF) left native runtime dlls next to the exe; 2.x needs none of them.
[InstallDelete]
Type: files; Name: "{app}\*_cor3.dll"
Type: files; Name: "{app}\e_sqlite3.dll"

[Icons]
Name: "{autoprograms}\MakeCleaner"; Filename: "{app}\MakeCleaner.exe"
Name: "{autodesktop}\MakeCleaner"; Filename: "{app}\MakeCleaner.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\MakeCleaner.exe"; Description: "{cm:LaunchProgram,MakeCleaner}"; Flags: postinstall nowait skipifsilent

; The task exists only if the user created it in Options > Scheduled cleaning; schtasks just fails quietly otherwise.
; Name must match task_name in src\core\schedule.zig.
[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""MakeCleaner Auto Clean"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "deltask"

[CustomMessages]
en.DeleteSettings=Also delete your MakeCleaner settings (checkbox states, include/exclude and cookie keep-lists, auto-clean log)?%n%n%1
uk.DeleteSettings=Видалити також налаштування MakeCleaner (стани пунктів, списки Include/Exclude і збережених cookies, лог автоочищення)?%n%n%1

[Code]
// Settings live in %AppData%\MakeCleaner (installed mode). Asked, default No: a reinstall should not lose the
// user's keep-lists. A silent uninstall keeps them. ponytail: other Windows users' %AppData% is never touched.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  Dir := ExpandConstant('{userappdata}\MakeCleaner');
  if UninstallSilent or not DirExists(Dir) then Exit;
  if MsgBox(FmtMessage(CustomMessage('DeleteSettings'), [Dir]), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(Dir, True, True, True);
end;
