{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Update;

{ Gibt es eine neuere Version auf GitHub?
  - Eine Anfrage an https://api.github.com/repos/mtm1978v-debug/GranularSynth/releases/latest (nur lesen; gesendet
    wird nichts ausser der ueblichen HTTP-Anfrage mit User-Agent "GranularSynth/<Version>").
  - Hoechstens einmal am Tag: das Ergebnis steht in %LOCALAPPDATA%\GranularSynth\update.txt (Datum + Version).
    Mehrere Plugin-Instanzen im selben Prozess teilen sich eine Pruefung.
  - Eigener Windows-Thread mit WinINet, nie im Audio-Thread. Der Thread haelt die DLL fest (Referenz auf das
    eigene Modul) und gibt sie am Ende mit FreeLibraryAndExitThread frei: entlaedt die DAW das Plugin, waehrend
    noch gefragt wird, bleibt der Code bis zum Ende des Threads im Speicher.
  - Ohne Netz oder bei Fehlern: einfach kein Hinweis. }

interface

{ Pruefung anstossen (mehrfacher Aufruf schadet nicht) }
procedure UpdateCheckStart(const CurrentVersion: string);
{ True, sobald feststeht, dass es eine neuere Version gibt; Version und Seite des Releases }
function UpdateAvailable(out Version, PageUrl: string): Boolean;
{ Setup im Programme-Ordner (fuer das Online-Update), leer wenn nicht installiert }
function UpdateSetupPath: string;

implementation

uses
  Winapi.Windows, Winapi.WinInet, System.SysUtils, System.Classes, System.IOUtils;

const
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 4;

function GetModuleHandleEx(dwFlags: DWORD; lpModuleName: PWideChar; var phModule: HMODULE): BOOL; stdcall;
  external kernel32 name 'GetModuleHandleExW';

const
  API_URL = 'https://api.github.com/repos/mtm1978v-debug/GranularSynth/releases/latest';
  RELEASES_URL = 'https://github.com/mtm1978v-debug/GranularSynth/releases/latest';

var
  GStarted: Integer;            // 0 = noch nicht, 1 = laeuft/fertig (InterlockedExchange)
  GDone: Boolean;               // Ergebnis steht fest (vom Thread geschrieben, danach nur gelesen)
  GLatest: string;              // neueste Version laut GitHub, z.B. '2.7'
  GCurrent: string;

function CacheFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) + 'GranularSynth\update.txt';
end;

{ '2.10' > '2.9' : Zahlen je Teil vergleichen }
function Newer(const A, B: string): Boolean;
var
  PA, PB: TArray<string>;
  I, X, Y: Integer;
begin
  PA := A.Split(['.']);
  PB := B.Split(['.']);
  for I := 0 to 2 do
  begin
    if I < Length(PA) then X := StrToIntDef(PA[I], 0) else X := 0;
    if I < Length(PB) then Y := StrToIntDef(PB[I], 0) else Y := 0;
    if X <> Y then
      Exit(X > Y);
  end;
  Result := False;
end;

function FetchLatest: string;
var
  Net, Url: HINTERNET;
  Buf: array[0..4095] of Byte;
  Got: DWORD;
  Data: TBytesStream;
  S: string;
  P, Q: Integer;
  Timeout: DWORD;
begin
  Result := '';
  Net := InternetOpen(PChar('GranularSynth/' + GCurrent), INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if Net = nil then
    Exit;
  Data := TBytesStream.Create;
  try
    Timeout := 8000;
    InternetSetOption(Net, INTERNET_OPTION_CONNECT_TIMEOUT, @Timeout, SizeOf(Timeout));
    InternetSetOption(Net, INTERNET_OPTION_RECEIVE_TIMEOUT, @Timeout, SizeOf(Timeout));
    Url := InternetOpenUrl(Net, API_URL, PChar('Accept: application/vnd.github+json'#13#10), DWORD(-1),
      INTERNET_FLAG_RELOAD or INTERNET_FLAG_NO_CACHE_WRITE or INTERNET_FLAG_SECURE or INTERNET_FLAG_NO_UI, 0);
    if Url = nil then
      Exit;
    try
      while InternetReadFile(Url, @Buf[0], SizeOf(Buf), Got) and (Got > 0) and (Data.Size < 2 * 1024 * 1024) do
        Data.WriteBuffer(Buf[0], Got);
    finally
      InternetCloseHandle(Url);
    end;
    S := TEncoding.UTF8.GetString(Data.Bytes, 0, Data.Size);
    // "tag_name": "v2.7"
    P := Pos('"tag_name"', S);
    if P = 0 then
      Exit;
    P := Pos('"', S, P + 10);          // Anfuehrungszeichen vor dem Wert
    if P = 0 then
      Exit;
    Q := Pos('"', S, P + 1);
    if Q = 0 then
      Exit;
    Result := Copy(S, P + 1, Q - P - 1);
    if (Result <> '') and CharInSet(Result[1], ['v', 'V']) then
      Delete(Result, 1, 1);
  finally
    Data.Free;
    InternetCloseHandle(Net);
  end;
end;

function CheckThread(Param: Pointer): DWORD; stdcall;
var
  L: TStringList;
  Day, V: string;
begin
  try
    try
      Day := FormatDateTime('yyyy-mm-dd', Date);
      V := '';
      L := TStringList.Create;
      try
        // heute schon gefragt? dann das gemerkte Ergebnis
        if FileExists(CacheFile) then
        begin
          L.LoadFromFile(CacheFile, TEncoding.UTF8);
          if (L.Count >= 2) and (L[0] = Day) then
            V := L[1];
        end;
        if V = '' then
        begin
          V := FetchLatest;
          if V <> '' then
          begin
            L.Clear;
            L.Add(Day);
            L.Add(V);
            ForceDirectories(ExtractFilePath(CacheFile));
            L.SaveToFile(CacheFile, TEncoding.UTF8);
          end;
        end;
      finally
        L.Free;
      end;
      GLatest := V;
    except
      GLatest := '';
    end;
  finally
    GDone := True;
    FreeLibraryAndExitThread(HMODULE(Param), 0);
  end;
  Result := 0;
end;

procedure UpdateCheckStart(const CurrentVersion: string);
var
  Me: HMODULE;
  Th: THandle;
  Id: DWORD;
begin
  if InterlockedExchange(GStarted, 1) <> 0 then
    Exit;
  GCurrent := CurrentVersion;
  // Prueftest: GRANULAR_FAKEVERSION=1.0 tut so, als waere die eigene Version aelter (Symbol erscheint)
  if GetEnvironmentVariable('GRANULAR_FAKEVERSION') <> '' then
    GCurrent := GetEnvironmentVariable('GRANULAR_FAKEVERSION');
  IsMultiThread := True;
  // eigene DLL festhalten, bis der Thread fertig ist
  if not GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, PChar(@CheckThread), Me) then
  begin
    GDone := True;
    Exit;
  end;
  Th := CreateThread(nil, 0, @CheckThread, Pointer(Me), 0, Id);
  if Th = 0 then
  begin
    FreeLibrary(Me);
    GDone := True;
    Exit;
  end;
  SetThreadPriority(Th, THREAD_PRIORITY_LOWEST);
  CloseHandle(Th);
end;

function UpdateAvailable(out Version, PageUrl: string): Boolean;
begin
  Version := '';
  PageUrl := RELEASES_URL;
  Result := GDone and (GLatest <> '') and Newer(GLatest, GCurrent);
  if Result then
    Version := GLatest;
end;

function UpdateSetupPath: string;
var
  Pf: string;
begin
  Pf := GetEnvironmentVariable('ProgramW6432');
  if Pf = '' then
    Pf := GetEnvironmentVariable('ProgramFiles');
  Result := IncludeTrailingPathDelimiter(Pf) + 'GranularSynth Setup\Setup.exe';
  if not FileExists(Result) then
    Result := '';
end;

end.
