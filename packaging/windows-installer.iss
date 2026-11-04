; LMStory Windows installer (Inno Setup 6).
; Version is injected by CI: ISCC /DLmStoryVersion=0.4.2
; Falls back to 0.0.0 when compiled locally without the define.
; Builds a per-user install (no admin/UAC): DefaultDirName {autopf} maps to
; %LOCALAPPDATA%\Programs under PrivilegesRequired=lowest.

#ifndef LmStoryVersion
  #define LmStoryVersion "0.0.0"
#endif

[Setup]
AppId={{7BD30086-268C-4CD6-8DF8-91FAAB30A80E}
AppName=LMStory
AppVersion={#LmStoryVersion}
AppPublisher=LMStory
DefaultDirName={autopf}\LMStory
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir=output
OutputBaseFilename=lmstory-{#LmStoryVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lmstory.exe
DisableProgramGroupPage=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\LMStory"; Filename: "{app}\lmstory.exe"
Name: "{autodesktop}\LMStory"; Filename: "{app}\lmstory.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lmstory.exe"; Description: "{cm:LaunchProgram,LMStory}"; Flags: nowait postinstall skipifsilent
