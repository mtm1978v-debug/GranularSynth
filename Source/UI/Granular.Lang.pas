{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Lang;

{ Sprache der Oberflaeche. Quelltext und Presets bleiben deutsch; der deutsche Text ist zugleich der
  Schluessel fuer die Uebersetzung (wie gettext):
    Tr('Speichern…')  →  'Save…' (Englisch)  bzw. unveraendert (Deutsch)
  Sprachdateien: <Plugin-Ordner>\Sprachen\<Kuerzel>.txt, UTF-8, erste Zeile "#Name=English",
  danach je Zeile  Deutsch<TAB>Uebersetzung  (Zeilenumbruch im Text als \n). Eine neue Sprache =
  eine neue Datei, sie erscheint automatisch in der Auswahl (Reiter Extras).
  Die Wahl steht in <Plugin-Ordner>\Sprache.txt (fehlt sie: Deutsch auf deutschem Windows, sonst Englisch).
  Sammelmodus (Pruefstand): LangMissing liefert alle Texte, die ueber Tr liefen und in der Sprachdatei
  fehlen - so faellt jeder neue, unuebersetzte Text sofort auf.
  Nur im GUI-Thread benutzen (nicht im Audio-Thread). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Menus, Vcl.Forms;

const
  LANG_DIR = 'Sprachen';
  LANG_FILE = 'Sprache.txt';
  SCALE_FILE = 'Fenstergroesse.txt';
  { waehlbare Fenstergroessen in Prozent }
  UI_SCALES: array[0..4] of Integer = (100, 125, 150, 175, 200);

function Tr(const S: string): string;
{ einmal je Plugin-Ordner: gemerkte Sprache laden }
procedure LangInit(const BaseDir: string);
{ umschalten und merken ('de' = Deutsch) }
procedure LangSet(const Code: string);
function LangCode: string;
{ gemerkte Fenstergroesse in Prozent (fehlt die Datei: 100) und speichern }
{ aktuelle Skalierung der Oberflaeche in Prozent (setzt der Editor) und Schriftgroesse dazu:
  selbst gezeichnete Anzeigen nehmen UiPt(7) statt 7 }
var
  GUiScalePct: Integer = 100;
function UiPt(Size: Integer): Integer;
function UiScaleLoad(const BaseDir: string = ''): Integer;   // '' = Ordner aus LangInit
procedure UiScaleSave(Pct: Integer);
{ Zusatzfenster (Hilfe, Info, Audio bearbeiten, Zeichnen ...) auf die gewaehlte Fenstergroesse bringen:
  einmal nach dem Aufbau, vor dem Zeigen aufrufen }
procedure UiScaleForm(F: TCustomForm);
{ verfuegbare Sprachen: Kuerzel und Anzeigename (Deutsch immer zuerst) }
procedure LangList(Codes, Names: TStrings);
{ Sprachdatei direkt laden (Pruefstand), ohne die Wahl zu speichern }
procedure LangLoadFile(const Code, FileName: string);
{ Sammelmodus fuer den Pruefstand: fehlende Uebersetzungen merken }
procedure LangCollect(On: Boolean);
function LangMissing: TArray<string>;
{ alle Beschriftungen, Hinweise und Menues unterhalb von Root uebersetzen (nach dem Aufbau der Oberflaeche).
  Listen (ComboBox) werden NICHT angefasst: deren Eintraege uebersetzt der Code beim Fuellen. }
procedure TranslateComponents(Root: TComponent);
{ Hilfe-Datei passend zur Sprache: Hilfe\Hilfe_<Kuerzel>.rtf, sonst Hilfe\Hilfe.rtf }
function LangHelpFile(const BaseDir: string): string;

implementation

var
  GDict: TDictionary<string, string>;
  GCode: string = 'de';
  GBase: string;
  GInit: Boolean;
  GCollect: Boolean;
  GMissing: TDictionary<string, Boolean>;
  GValues: TDictionary<string, Boolean>;    // alle Uebersetzungen (Norm), fuer doppelte Durchlaeufe

function HasLetter(const S: string): Boolean;
var
  C: Char;
  I: Integer;
begin
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if C = '%' then
    begin
      // Formatangabe (%d, %.1f, %s ...) ist kein Wort
      Inc(I);
      while (I <= Length(S)) and CharInSet(S[I], ['0'..'9', '.', '-', ':']) do Inc(I);
      Inc(I);
      Continue;
    end;
    Inc(I);
    if CharInSet(C, ['A'..'Z', 'a'..'z', 'Ä', 'Ö', 'Ü', 'ä', 'ö', 'ü', 'ß']) then
      Exit(True);
  end;
  Result := False;
end;

{ Vergleichsform fuer schon uebersetzte Texte: Leerzeichen und Zeilenumbrueche zaehlen nicht -
  WrapText bricht auch hinter einem Bindestrich um ("->" wird zu "-" + Umbruch + ">") }
function Norm(const S: string): string;
var
  I: Integer;
begin
  // Doppelpunkt am Ende egal
  Result := '';
  for I := 1 to Length(S) do
    if not CharInSet(S[I], [' ', #13, #10]) then
      Result := Result + S[I];
  while (Result <> '') and (Result[Length(Result)] = ':') do
    SetLength(Result, Length(Result) - 1);
end;

function Tr(const S: string): string;
var
  T, Part: string;
  L, R, I: Integer;
  Parts: TArray<string>;
  Ok: Boolean;
begin
  if (GDict = nil) or (S = '') then
    Exit(S);
  if GDict.TryGetValue(S, Result) then
    Exit;
  // schon uebersetzt (z.B. Beschriftung, die beim Aufbau Tr bekam und danach noch einmal durchlaeuft)
  if GValues.ContainsKey(Norm(S)) then
    Exit(S);
  // fuehrende/folgende Leerzeichen und Doppelpunkt gehoeren nicht zum Schluessel
  L := 1;
  R := Length(S);
  while (L <= R) and (S[L] = ' ') do Inc(L);
  while (R >= L) and CharInSet(S[R], [' ', ':']) do Dec(R);
  T := Copy(S, L, R - L + 1);
  if (T <> S) and (T <> '') and GDict.TryGetValue(T, Result) then
    Exit(Copy(S, 1, L - 1) + Result + Copy(S, R + 1, MaxInt));
  // mehrere Absaetze (z.B. Text + sLineBreak + Text): Absatz fuer Absatz, wenn jeder bekannt ist
  if Pos(#10, S) > 0 then
  begin
    Parts := S.Split([#13#10, #10]);
    Ok := True;
    for I := 0 to High(Parts) do
      if Trim(Parts[I]) <> '' then
      begin
        if GDict.TryGetValue(Trim(Parts[I]), Part) then
          Parts[I] := Part
        else if not GValues.ContainsKey(Norm(Parts[I])) then
          Ok := False;
      end;
    if Ok then
      Exit(string.Join(sLineBreak, Parts));
  end;
  Result := S;
  if T = '' then
    T := S;
  if GCollect and HasLetter(T) then
    GMissing.AddOrSetValue(T, True);
end;

function Unescape(const S: string): string;
begin
  Result := StringReplace(S, '\n', sLineBreak, [rfReplaceAll]);
end;

procedure LangLoadFile(const Code, FileName: string);
var
  L: TStringList;
  I, P: Integer;
begin
  FreeAndNil(GDict);
  FreeAndNil(GValues);
  GCode := Code;
  if (Code = 'de') or not FileExists(FileName) then
  begin
    GCode := 'de';
    if GCollect then
    begin
      // Sammelmodus ohne Sprachdatei: leeres Woerterbuch -> jeder Text gilt als fehlend
      GDict := TDictionary<string, string>.Create;
      GValues := TDictionary<string, Boolean>.Create;
    end;
    Exit;
  end;
  GDict := TDictionary<string, string>.Create;
  GValues := TDictionary<string, Boolean>.Create;
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName, TEncoding.UTF8);
    for I := 0 to L.Count - 1 do
    begin
      if (L[I] = '') or (L[I][1] = '#') then
        Continue;
      P := Pos(#9, L[I]);
      if P > 1 then
      begin
        GDict.AddOrSetValue(Unescape(Copy(L[I], 1, P - 1)), Unescape(Copy(L[I], P + 1, MaxInt)));
        GValues.AddOrSetValue(Norm(Unescape(Copy(L[I], P + 1, MaxInt))), True);
      end;
    end;
  finally
    L.Free;
  end;
end;

function DefaultCode: string;
begin
  if (GetUserDefaultUILanguage and $3FF) = LANG_GERMAN then
    Result := 'de'
  else
    Result := 'en';
end;

procedure LangInit(const BaseDir: string);
var
  Code: string;
begin
  if GInit and SameText(BaseDir, GBase) then
    Exit;
  GInit := True;
  GBase := IncludeTrailingPathDelimiter(BaseDir);
  Code := '';
  try
    if FileExists(GBase + LANG_FILE) then
      with TStringList.Create do
      try
        LoadFromFile(GBase + LANG_FILE, TEncoding.UTF8);
        if Count > 0 then
          Code := Trim(Strings[0]);
      finally
        Free;
      end;
  except
    Code := '';
  end;
  if Code = '' then
    Code := DefaultCode;
  LangLoadFile(Code, GBase + LANG_DIR + PathDelim + Code + '.txt');
end;

procedure LangSet(const Code: string);
begin
  LangLoadFile(Code, GBase + LANG_DIR + PathDelim + Code + '.txt');
  try
    with TStringList.Create do
    try
      Add(GCode);
      SaveToFile(GBase + LANG_FILE, TEncoding.UTF8);
    finally
      Free;
    end;
  except
    // Ordner schreibgeschuetzt: Wahl gilt bis zum Schliessen
  end;
end;

procedure UiScaleForm(F: TCustomForm);
begin
  if (F = nil) or (GUiScalePct = 100) then
    Exit;
  TForm(F).ParentFont := False;
  F.ScaleBy(GUiScalePct, 100);
end;

function UiPt(Size: Integer): Integer;
begin
  Result := MulDiv(Size, GUiScalePct, 100);
end;

{ Vorschlag beim ersten Start (ohne Fenstergroesse.txt): Windows-Skalierung des Bildschirms, so wie sie das
  Plugin sieht. Ist die DAW nicht DPI-faehig, meldet Windows 96 dpi und vergroessert selbst -> 100 % (keine
  doppelte Vergroesserung). Gewaehlt wird hoechstens die Stufe, bei der das Fenster (1260 x 712 bei 100 %)
  noch auf den Arbeitsbereich des Hauptbildschirms passt. }
function UiScaleSuggest: Integer;
const
  BASE_W = 1260;
  BASE_H = 712 + 60;                // + Rahmen/Titel der DAW
var
  Dc: HDC;
  Dpi: Integer;
  R: TRect;
begin
  Result := 100;
  try
    Dc := GetDC(0);
    try
      Dpi := GetDeviceCaps(Dc, LOGPIXELSY);
    finally
      ReleaseDC(0, Dc);
    end;
    if not SystemParametersInfo(SPI_GETWORKAREA, 0, @R, 0) then
      Exit;
    for var P in UI_SCALES do
      if (P <= MulDiv(Dpi, 100, 96)) and (MulDiv(BASE_W, P, 100) <= R.Width) and
        (MulDiv(BASE_H, P, 100) <= R.Height) then
        Result := P;
  except
    Result := 100;
  end;
end;

function UiScaleLoad(const BaseDir: string): Integer;
var
  I: Integer;
  Dir: string;
begin
  Result := 100;
  Dir := BaseDir;
  if Dir = '' then
    Dir := GBase;
  try
    if not FileExists(Dir + SCALE_FILE) then
      Exit(UiScaleSuggest);       // noch nie gewaehlt: Vorschlag aus der Windows-Skalierung
    begin
      I := StrToIntDef(Trim(TFile.ReadAllText(Dir + SCALE_FILE)), 100);
      for var P in UI_SCALES do
        if P = I then
          Result := I;
    end;
  except
  end;
end;

procedure UiScaleSave(Pct: Integer);
begin
  try
    TFile.WriteAllText(GBase + SCALE_FILE, IntToStr(Pct));
  except
    // Ordner schreibgeschuetzt: Wahl gilt bis zum Schliessen
  end;
end;

function LangCode: string;
begin
  Result := GCode;
end;

procedure LangList(Codes, Names: TStrings);
var
  SR: TSearchRec;
  L: TStringList;
  N: string;
begin
  Codes.Clear;
  Names.Clear;
  Codes.Add('de');
  Names.Add('Deutsch');
  if (GBase = '') or (FindFirst(GBase + LANG_DIR + PathDelim + '*.txt', faAnyFile, SR) <> 0) then
    Exit;
  L := TStringList.Create;
  try
    repeat
      N := ChangeFileExt(SR.Name, '');
      try
        L.LoadFromFile(GBase + LANG_DIR + PathDelim + SR.Name, TEncoding.UTF8);
        if (L.Count > 0) and SameText(Copy(L[0], 1, 6), '#Name=') then
        begin
          Codes.Add(N);
          Names.Add(Copy(L[0], 7, MaxInt));
        end;
      except
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
    L.Free;
  end;
end;

procedure LangCollect(On: Boolean);
begin
  GCollect := On;
  if GMissing = nil then
    GMissing := TDictionary<string, Boolean>.Create;
  GMissing.Clear;
end;

function LangMissing: TArray<string>;
begin
  if GMissing = nil then
    Exit(nil);
  Result := GMissing.Keys.ToArray;
  TArray.Sort<string>(Result);
end;

type
  TControlAccess = class(TControl);

procedure TranslateComponents(Root: TComponent);
var
  I: Integer;
  C: TComponent;
begin
  if GDict = nil then
    Exit;
  for I := 0 to Root.ComponentCount - 1 do
  begin
    C := Root.Components[I];
    if C is TMenuItem then
      TMenuItem(C).Caption := Tr(TMenuItem(C).Caption)
    else if C is TControl then
    begin
      if TControl(C).Hint <> '' then
        TControl(C).Hint := Tr(TControl(C).Hint);
      if (C is TLabel) or (C is TButton) or (C is TCheckBox) or (C is TRadioButton) or
         (C is TTabSheet) or (C is TGroupBox) or (C is TPanel) then
        if TControlAccess(C).Caption <> '' then
          TControlAccess(C).Caption := Tr(TControlAccess(C).Caption);
    end;
    if C.ComponentCount > 0 then
      TranslateComponents(C);
  end;
end;

function LangHelpFile(const BaseDir: string): string;
var
  Dir: string;
begin
  Dir := IncludeTrailingPathDelimiter(BaseDir) + 'Hilfe' + PathDelim;
  Result := Dir + 'Hilfe_' + GCode + '.rtf';
  if (GCode = 'de') or not FileExists(Result) then
    Result := Dir + 'Hilfe.rtf';
end;

initialization

finalization
  GDict.Free;
  GValues.Free;
  GMissing.Free;

end.
