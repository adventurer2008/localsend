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
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\LocalSend Remote"; Filename: "{app}\localsend_app.exe"
