{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

program Setup;

{ GranularSynth-Setup: verlangt ueber das Manifest Administratorrechte (Windows fragt einmal per UAC) und
  startet dann Install.ps1 aus demselben Ordner ohne Konsolenfenster. Das Skript zeigt die Auswahl
  (32/64 Bit, VST2, VST3, Test-Host, Zielordner) und kopiert. 32-Bit-EXE, laeuft auf allen Windows.
  Parameter werden an das Skript durchgereicht (Windows-Programmliste: "-Uninstall -Platform Win64").
  Auf 64-Bit-Windows wird die 64-Bit-PowerShell gestartet (Sysnative) - sonst saehe das Skript die
  32-Bit-Sicht: falsche Standardordner (Program Files (x86)) und WOW6432Node in der Registry. }

{$APPTYPE GUI}
{$R Setup.res}   // Manifest: requireAdministrator (Setup.rc / Setup.manifest)

uses
  Winapi.Windows, System.SysUtils;

var
  Dir, Script, Cmd, PS, Args: string;
  I: Integer;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Code: DWORD;
begin
  Dir := ExtractFilePath(ParamStr(0));
  Script := Dir + 'Install.ps1';
  if not FileExists(Script) then
  begin
    MessageBox(0, PChar('Install.ps1 fehlt neben Setup.exe:' + sLineBreak + Dir), 'GranularSynth Setup', MB_ICONERROR);
    ExitCode := 1;
    Exit;
  end;
  PS := GetEnvironmentVariable('SystemRoot') + '\Sysnative\WindowsPowerShell\v1.0\powershell.exe';
  if not FileExists(PS) then
    PS := 'powershell.exe';
  Args := '';
  for I := 1 to ParamCount do
    Args := Args + ' "' + ParamStr(I) + '"';
  Cmd := '"' + PS + '" -NoProfile -ExecutionPolicy Bypass -File "' + Script + '"' + Args;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  UniqueString(Cmd);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, False, CREATE_NO_WINDOW, nil, PChar(Dir), SI, PI) then
  begin
    MessageBox(0, PChar('PowerShell konnte nicht gestartet werden: ' + SysErrorMessage(GetLastError)),
      'GranularSynth Setup', MB_ICONERROR);
    ExitCode := 2;
    Exit;
  end;
  WaitForSingleObject(PI.hProcess, INFINITE);
  GetExitCodeProcess(PI.hProcess, Code);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  ExitCode := Integer(Code);
end.
