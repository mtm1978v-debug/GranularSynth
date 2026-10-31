{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Prof;

{ Einfache Zeitmessung fuer Zeichenroutinen (nur aktiv mit Umgebungsvariable GRANULAR_PROF=1).
  ProfBegin/ProfEnd je Bereich, nach 10 s Laufzeit wird eine Zusammenfassung geschrieben
  (%TEMP%\granular_prof_<modul>.txt). Ohne die Variable kostet es nur eine Abfrage. }

interface

procedure ProfBegin(Slot: Integer);
procedure ProfEnd(Slot: Integer; const Name: string);
{ Startzeit-Protokoll (nur mit GRANULAR_STARTLOG=1): %TEMP%\granular_start.txt }
procedure StartMark(const What: string);

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils;

var
  GEnabled: Integer = -1;
  GStart: array[0..15] of Int64;
  GSum: array[0..15] of Int64;
  GCount: array[0..15] of Integer;
  GNames: array[0..15] of string;
  GT0: Int64;
  GWritten: Boolean;

function Enabled: Boolean;
begin
  if GEnabled < 0 then
  begin
    if GetEnvironmentVariable('GRANULAR_PROF') = '1' then GEnabled := 1 else GEnabled := 0;
    QueryPerformanceCounter(GT0);
  end;
  Result := GEnabled = 1;
end;

procedure StartMark(const What: string);
begin
  if GetEnvironmentVariable('GRANULAR_STARTLOG') = '1' then
    TFile.AppendAllText(TPath.Combine(TPath.GetTempPath, 'granular_start.txt'),
      FormatDateTime('hh:nn:ss.zzz', Now) + '    ' + What + sLineBreak);
end;

procedure ProfBegin(Slot: Integer);
begin
  if Enabled then
    QueryPerformanceCounter(GStart[Slot]);
end;

procedure ProfEnd(Slot: Integer; const Name: string);
var
  T, F: Int64;
  I: Integer;
  S: string;
begin
  if not Enabled then
    Exit;
  QueryPerformanceCounter(T);
  Inc(GSum[Slot], T - GStart[Slot]);
  Inc(GCount[Slot]);
  GNames[Slot] := Name;
  QueryPerformanceFrequency(F);
  if not GWritten and (T - GT0 > 25 * F) then
  begin
    GWritten := True;
    S := '';
    for I := 0 to High(GSum) do
      if GCount[I] > 0 then
        S := S + Format('%-22s %5d x  gesamt %7.1f ms  je %.3f ms  -> %.2f %% CPU (bezogen auf 25 s)'#13#10,
          [GNames[I], GCount[I], GSum[I] * 1000 / F, GSum[I] * 1000 / F / GCount[I], GSum[I] * 100 / F / 25]);
    TFile.WriteAllText(TPath.Combine(TPath.GetTempPath, 'granular_prof_' +
      ChangeFileExt(ExtractFileName(GetModuleName(HInstance)), '') + '.txt'), S);
  end;
end;

end.
