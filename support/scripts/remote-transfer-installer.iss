#ifndef PayloadDir
  #error PayloadDir is required
#endif

[Setup]
AppId=LocalSend.RemoteTransfer.Test
AppName=LocalSend Remote
AppVersion=1.18.2
DefaultDirName={localappdata}\Programs\LocalSend Remote
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=LocalSend-Remote-Windows-x64
UninstallDisplayIcon={app}\localsend_app.exe

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "settings.json"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\settings.json"; DestDir: "{app}"; Flags: onlyifdoesntexist

[Icons]
Name: "{autoprograms}\LocalSend Remote"; Filename: "{app}\localsend_app.exe"
