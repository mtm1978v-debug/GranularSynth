{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.State;

{ Zustand des Synthesizers als binaerer Chunk - dasselbe Format liefert spaeter das
  VST2-Plugin ueber effGetChunk/effSetChunk (Flag effFlagsProgramChunks).

  Robust gegen Erweiterungen: Parameter werden ueber ihren NAMEN zugeordnet, nicht
  ueber die Position. Stufen-Parameter (Matrix-Quelle/-Ziel, Fensterform, ...) tragen
  zusaetzlich den Klartext der Stufe ("LFO 1", "Cutoff"), damit neue Quellen/Ziele
  alte Presets nicht verschieben. Unbekannte Eintraege werden ignoriert, fehlende
  behalten ihren Standardwert.

  Aufbau (Little Endian):
    'GRNS'  Int32 Version (=1)  Int32 Anzahl
    je Eintrag: Str Name, Single Wert (normalisiert), Str Stufentext (leer = keiner)
    Str Samplepfad (leer = Demo-Klang)
    optional (ab Form 'Frei'): 'FLFO' Int32 Version(=1), je LFO 1 und 2:
      Int32 Modus, Int32 Stufen, Int32 n + n Single Stufenwerte, Int32 m + m Single Kurvenpunkte
    Fehlt der Abschnitt (alte Presets), bekommt der freie LFO seinen Standardinhalt.
    optional 'MRPH' Int32 Anzahl, je Eintrag Str Name + Single Wert: Morph-Ziel B
    (fehlt der Abschnitt, gibt es kein Ziel).
    optional 'ARPP' Int32 Schrittmuster des Arpeggiators (fehlt -> alle Schritte an).
    ... 'EQCV' Equalizer-Kurve, optional 'MRPC' Int32 Laenge + vollstaendiger Chunk des Klangs B
    (Matrix, freie LFOs, Arp-Muster, EQ; ohne Sample). Fehlt 'Morph-Art' bei einem Preset mit
    Ziel B (aeltere Presets), gilt 'Werte ueberblenden' - so klingen sie wie frueher.
  Str = Int32 Laenge + UTF-8-Bytes

  Preset-DATEI mit eingebetteten Samples (Option beim Speichern): hinter dem Chunk folgt
    'EMBD' Int32 Anzahl, je Sample: Str Verweis (wie im Chunk), Int32 Laenge + Dateiinhalt,
    danach Int32 Chunk-Laenge und 'GSEB' als letzte 4 Bytes.
  Aeltere Versionen lesen nur den Chunk und ueberlesen den Anhang. Beim Laden werden fehlende
  Samples nach 'Eigene Toene' ausgepackt und die Verweise darauf umgestellt. }

interface

uses
  System.SysUtils, System.Classes, System.Math,
  Granular.Params, Granular.Engine, Granular.Eq;

const
  MIDI_MAP_FILE = 'MidiLearn.txt';

function SaveChunk(Engine: TGranularEngine; const SamplePath: string): TBytes;
{ False, wenn die Daten kein gueltiger Chunk sind (Engine bleibt dann unveraendert) }
function LoadChunk(Engine: TGranularEngine; const Data: TBytes; out SamplePath: string): Boolean;

{ Preset-Datei schreiben; Embed: die Samples kommen mit in die Datei (s. oben) }
procedure SaveChunkToFile(Engine: TGranularEngine; const SamplePath, FileName: string;
  const BaseDir: string = ''; Embed: Boolean = False);

{ Samplepfade portabel halten: Dateien unterhalb von BaseDir (Ordner der Plugin-DLL)
  werden relativ gespeichert ("Beispieltoene\Chor.wav"). Beim Laden wird ein relativer
  oder nicht (mehr) vorhandener Pfad gegen BaseDir bzw. BaseDir\Beispieltoene aufgeloest. }
function MakePortablePath(const Path, BaseDir: string): string;
function ResolveSamplePath(const Path, BaseDir: string): string;

{ Fuer Preset-Dateien: liegt das Sample ausserhalb des Plugin-Ordners, wird es nach
  BaseDir\Eigene Toene kopiert und relativ referenziert -> Preset + Ordner sind portabel. }
function MakeSharedSamplePath(const Path, BaseDir: string): string;

{ BaseDir: eingebettete Samples dorthin auspacken (leer = nicht auspacken) }
function LoadChunkFromFile(Engine: TGranularEngine; const FileName: string; out SamplePath: string;
  const BaseDir: string = ''): Boolean;

{ Sample des Morph-Ziels B laden (nach LoadChunk): Pfad aus Engine.MorphSampleRef gegen BaseDir
  aufloesen; nur neu laden, wenn es eine andere Datei ist. Kein Ziel/kein Pfad -> B-Sample frei. }
procedure LoadMorphSample(Engine: TGranularEngine; const BaseDir: string);
{ Zonen-Samples des Presets laden (Pfade aus dem Chunk) }
procedure LoadZoneSamples(Engine: TGranularEngine; const BaseDir: string);
{ Wavetable-Dateien der Oszillatoren laden (Verweise aus dem Chunk); wird von LoadZoneSamples mit erledigt }
procedure LoadOscWavetables(Engine: TGranularEngine; const BaseDir: string);
function WtFrameLen(N: Integer): Integer;

{ MIDI-Learn-Zuordnung gehoert zum Rechner/Controller, nicht zum Klang: Textdatei im Plugin-Ordner,
  je Zeile "CC=Parametername". Unbekannte Namen werden uebersprungen. }
procedure LoadMidiMap(Engine: TGranularEngine; const FileName: string);
procedure SaveMidiMap(Engine: TGranularEngine; const FileName: string);

implementation

uses
  System.IOUtils, Granular.AudioDecode, Granular.Sample;

const
  CHUNK_MAGIC: array[0..3] of AnsiChar = ('G', 'R', 'N', 'S');
  CHUNK_VERSION = 1;
  USER_SAMPLE_DIR = 'Eigene Toene';
  FREE_MAGIC: array[0..3] of AnsiChar = ('F', 'L', 'F', 'O');
  MORPH_MAGIC: array[0..3] of AnsiChar = ('M', 'R', 'P', 'H');
  ARP_MAGIC: array[0..3] of AnsiChar = ('A', 'R', 'P', 'P');
  NAME_MAGIC: array[0..3] of AnsiChar = ('N', 'A', 'M', 'E');
  MSMP_MAGIC: array[0..3] of AnsiChar = ('M', 'S', 'M', 'P');
  EQCV_MAGIC: array[0..3] of AnsiChar = ('E', 'Q', 'C', 'V');
  MRPC_MAGIC: array[0..3] of AnsiChar = ('M', 'R', 'P', 'C');
  TGAT_MAGIC: array[0..3] of AnsiChar = ('T', 'G', 'A', 'T');
  ZONE_MAGIC: array[0..3] of AnsiChar = ('Z', 'O', 'N', 'E');
  FLF8_MAGIC: array[0..3] of AnsiChar = ('F', 'L', 'F', '8');   // freie Formen LFO 5..8
  FLSM_MAGIC: array[0..3] of AnsiChar = ('F', 'L', 'S', 'M');   // Nov. 2026: Glaettung je freier Form
  OSCW_MAGIC: array[0..3] of AnsiChar = ('O', 'S', 'C', 'W');   // Nov. 2026: gezeichnete Oszillator-Wellen
  FPAU_MAGIC: array[0..3] of AnsiChar = ('F', 'P', 'A', 'U');   // Nov. 2026: Pausen je Stufe der freien LFOs (nur wenn benutzt)
  FGLD_MAGIC: array[0..3] of AnsiChar = ('F', 'G', 'L', 'D');   // Nov. 2026: Gleiten je Stufe der freien LFOs (nur wenn benutzt)
  OSWT_MAGIC: array[0..3] of AnsiChar = ('O', 'S', 'W', 'T');   // Nov. 2026: Wavetable-Dateien der Oszillatoren (ganz hinten, nur wenn benutzt)
  MAX_STR = 4096;

procedure WriteStr(S: TStream; const Value: string);
var
  B: TBytes;
  N: Integer;
begin
  B := TEncoding.UTF8.GetBytes(Value);
  N := Length(B);
  S.WriteBuffer(N, 4);
  if N > 0 then
    S.WriteBuffer(B[0], N);
end;

procedure WriteFreeEntry(S: TStream; F: PFreeLfo);
var
  N: Integer;
begin
  S.WriteBuffer(F.Mode, 4);
  S.WriteBuffer(F.Steps, 4);
  N := FREE_MAX_STEPS;
  S.WriteBuffer(N, 4);
  S.WriteBuffer(F.Step[0], N * SizeOf(Single));
  N := FREE_DRAW_N;
  S.WriteBuffer(N, 4);
  S.WriteBuffer(F.Draw[0], N * SizeOf(Single));
end;

function SaveChunk(Engine: TGranularEngine; const SamplePath: string): TBytes;
var
  S: TBytesStream;
  I, N: Integer;
  V: Single;
  Info: TParamInfo;
  F: PFreeLfo;
  MB: array[0..NAMED_COUNT - 1] of Single;
  Sub: TBytes;
begin
  S := TBytesStream.Create;
  try
    S.WriteBuffer(CHUNK_MAGIC, 4);
    N := CHUNK_VERSION;
    S.WriteBuffer(N, 4);
    N := PARAM_COUNT;
    S.WriteBuffer(N, 4);
    for I := 0 to PARAM_COUNT - 1 do
    begin
      Info := GetParamInfo(I);
      V := Engine.GetParam(I);
      WriteStr(S, Info.Name);
      S.WriteBuffer(V, 4);
      if Info.Curve = pcStepped then
        WriteStr(S, StepName(I, ParamStep(I, V)))
      else
        WriteStr(S, '');
    end;
    WriteStr(S, SamplePath);
    // frei programmierbare LFOs
    S.WriteBuffer(FREE_MAGIC, 4);
    N := 3;                     // Version 3: LFO 1, LFO 2, Morph-LFO, LFO 3, LFO 4
    S.WriteBuffer(N, 4);
    for I := 0 to 4 do
      WriteFreeEntry(S, Engine.FreeLfo[I]);
    // Morph-Ziel (nur wenn gesetzt), ueber Namen -> robust gegen neue Parameter
    if Engine.GetMorphTarget(MB) then
    begin
      S.WriteBuffer(MORPH_MAGIC, 4);
      N := NAMED_COUNT;
      S.WriteBuffer(N, 4);
      for I := 0 to NAMED_COUNT - 1 do
      begin
        WriteStr(S, GetParamInfo(I).Name);
        S.WriteBuffer(MB[I], 4);
      end;
    end;
    S.WriteBuffer(ARP_MAGIC, 4);
    N := Integer(Engine.ArpMask);
    S.WriteBuffer(N, 4);
    S.WriteBuffer(NAME_MAGIC, 4);
    WriteStr(S, Engine.PresetName);
    if Engine.MorphValid and (Engine.MorphSampleRef <> '') then
    begin
      S.WriteBuffer(MSMP_MAGIC, 4);
      WriteStr(S, Engine.MorphSampleRef);
    end;
    // Equalizer-Kurve
    S.WriteBuffer(EQCV_MAGIC, 4);
    N := EQ_CURVE_N;
    S.WriteBuffer(N, 4);
    S.WriteBuffer(Engine.EqCurve^[0], EQ_CURVE_N * SizeOf(Single));
    // vollstaendiger Klang B
    if Engine.MorphValid and (Engine.MorphLayer <> nil) then
    begin
      Sub := SaveChunk(Engine.MorphLayer, '');
      S.WriteBuffer(MRPC_MAGIC, 4);
      N := Length(Sub);
      S.WriteBuffer(N, 4);
      if N > 0 then
        S.WriteBuffer(Sub[0], N);
    end;
    // Trance-Gate-Muster und Zonen (Pfad + Starttaste)
    S.WriteBuffer(TGAT_MAGIC, 4);
    N := Integer(Engine.TgMask);
    S.WriteBuffer(N, 4);
    S.WriteBuffer(ZONE_MAGIC, 4);
    N := ZONE_COUNT;
    S.WriteBuffer(N, 4);
    for I := 1 to ZONE_COUNT do
    begin
      WriteStr(S, Engine.GetZoneRef(I));
      N := Engine.GetZoneLow(I);
      S.WriteBuffer(N, 4);
    end;
    // frei gezeichnete Formen LFO 5..8: eigener Abschnitt am Ende (aeltere Versionen lesen 'FLFO' weiter)
    S.WriteBuffer(FLF8_MAGIC, 4);
    N := FREE_LFO_COUNT - 5;
    S.WriteBuffer(N, 4);
    for I := 5 to FREE_LFO_COUNT - 1 do
      WriteFreeEntry(S, Engine.FreeLfo[I]);
    // Glaettung der freien Formen (aeltere Versionen ueberlesen den Abschnitt)
    S.WriteBuffer(FLSM_MAGIC, 4);
    N := FREE_LFO_COUNT;
    S.WriteBuffer(N, 4);
    for I := 0 to FREE_LFO_COUNT - 1 do
      S.WriteBuffer(Engine.FreeLfo[I].Smooth, 4);
    // gezeichnete Oszillator-Wellen: je Oszillator Punktzahl, Punkte, Glaettung
    S.WriteBuffer(OSCW_MAGIC, 4);
    N := OSC_COUNT;
    S.WriteBuffer(N, 4);
    for I := 0 to OSC_COUNT - 1 do
    begin
      N := OSC_DRAW_N;
      S.WriteBuffer(N, 4);
      S.WriteBuffer(Engine.OscDraw[I].Pt[0], OSC_DRAW_N * SizeOf(Single));
      S.WriteBuffer(Engine.OscDraw[I].Smooth, 4);
    end;
    // Gleiten je Stufe: nur schreiben, wenn eine Stufe gleitet (sonst bleibt der Chunk wie bisher)
    N := 0;
    for I := 0 to FREE_LFO_COUNT - 1 do
      if Engine.FreeLfo[I].Glide <> 0 then
        N := FREE_LFO_COUNT;
    if N > 0 then
    begin
      S.WriteBuffer(FGLD_MAGIC, 4);
      S.WriteBuffer(N, 4);
      for I := 0 to FREE_LFO_COUNT - 1 do
        S.WriteBuffer(Engine.FreeLfo[I].Glide, 8);
    end;
    // Pausen je Stufe: nur schreiben, wenn eine Stufe pausiert
    N := 0;
    for I := 0 to FREE_LFO_COUNT - 1 do
      if Engine.FreeLfo[I].Rest <> 0 then
        N := FREE_LFO_COUNT;
    if N > 0 then
    begin
      S.WriteBuffer(FPAU_MAGIC, 4);
      S.WriteBuffer(N, 4);
      for I := 0 to FREE_LFO_COUNT - 1 do
        S.WriteBuffer(Engine.FreeLfo[I].Rest, 8);
    end;
    // Wavetable-Dateien: nur schreiben, wenn ein Oszillator eine hat (sonst bleibt der Chunk wie bisher)
    N := 0;
    for I := 0 to OSC_COUNT - 1 do
      if Engine.WtRef[I] <> '' then
        N := OSC_COUNT;
    if N > 0 then
    begin
      S.WriteBuffer(OSWT_MAGIC, 4);
      S.WriteBuffer(N, 4);
      for I := 0 to OSC_COUNT - 1 do
        WriteStr(S, Engine.WtRef[I]);
    end;
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

var
  { FX-Send 'Eingang Echo/Hall' gehoert zur Mixer-Spur: Preset-Dateien aendern ihn nicht, DAW-Projekte schon }
  GLoadingPresetFile: Boolean = False;

function LoadChunk(Engine: TGranularEngine; const Data: TBytes; out SamplePath: string): Boolean;
type
  TEntry = record
    Index: Integer;
    Value: Single;
  end;
var
  P, Version, Count, I, K, Idx: Integer;
  TgMaskV, ZN, ZL: Integer;
  Fr8: TFreeLfo;
  ZS: string;
  ZRef: array[1..ZONE_COUNT] of string;
  WtR: array[0..OSC_COUNT - 1] of string;
  ZLow: array[1..ZONE_COUNT] of Integer;
  Name, Text: string;
  V: Single;
  Info: TParamInfo;
  Entries: TArray<TEntry>;
  Free: array[0..FREE_LFO_COUNT - 1] of TFreeLfo;
  Ow: array[0..OSC_COUNT - 1] of TOscDraw;
  Pos, Frac: Double;
  J: Integer;
  MB: array[0..NAMED_COUNT - 1] of Single;
  HasMorph: Boolean;
  ArpMaskV: Integer;
  PName, MRef: string;
  EqC: TEqCurve;
  EqN: Integer;
  HasName: Boolean;
  HasMode: Boolean;
  Found: Boolean;
  LayerData: TBytes;
  LayerN: Integer;
  Dummy: string;

  function ReadInt(out Value: Integer): Boolean;
  begin
    Result := P + 4 <= Length(Data);
    if Result then
    begin
      Move(Data[P], Value, 4);
      Inc(P, 4);
    end;
  end;

  function ReadSingle(out Value: Single): Boolean;
  begin
    Result := P + 4 <= Length(Data);
    if Result then
    begin
      Move(Data[P], Value, 4);
      Inc(P, 4);
    end;
  end;

  function ReadStr(out Value: string): Boolean;
  var
    N: Integer;
  begin
    Value := '';
    Result := ReadInt(N) and (N >= 0) and (N <= MAX_STR) and (P + N <= Length(Data));
    if Result and (N > 0) then
    begin
      Value := TEncoding.UTF8.GetString(Data, P, N);
      Inc(P, N);
    end;
  end;

  function FindParam(const AName: string): Integer;
  var
    J: Integer;
    F: string;
  begin
    // erst exakt (schnell, der Normalfall), dann umlaut-neutral (aeltere Presets ohne Umlaute)
    for J := 0 to PARAM_COUNT - 1 do
      if SameText(GetParamInfo(J).Name, AName) then
        Exit(J);
    F := FoldUmlauts(AName);
    for J := 0 to PARAM_COUNT - 1 do
      if SameText(FoldUmlauts(GetParamInfo(J).Name), F) then
        Exit(J);
    Result := -1;
  end;

  { aeltere Presets: 'Osz Pegel' ging bis 100 %, 'Osz-Pegel' bis 200 % -> normierten Wert halbieren }
  function FindParamV(const AName: string; var Val: Single): Integer;
  begin
    Result := FindParam(AName);
    if (Result < 0) and SameText(AName, 'Osz Pegel') then
    begin
      Result := Ord(gpOscLevel);
      Val := Val * 0.5;
    end;
  end;

  { optionaler Abschnitt der freien LFOs; fehlt er oder ist er defekt -> Standardinhalt }
  { ein Eintrag einer frei gezeichneten Form }
  function ReadFreeEntry(out Tmp: TFreeLfo): Boolean;
  var
    M, Cnt, X: Integer;
    Val: Single;
  begin
    Result := False;
    FreeLfoDefault(Tmp);
    if not (ReadInt(M) and ReadInt(Tmp.Steps)) then
      Exit;
    Tmp.Mode := EnsureRange(M, 0, 2);
    Tmp.Steps := EnsureRange(Tmp.Steps, 1, FREE_MAX_STEPS);
    if not ReadInt(Cnt) or (Cnt < 0) or (Cnt > 100000) then
      Exit;
    for X := 0 to Cnt - 1 do
    begin
      if not ReadSingle(Val) then
        Exit;
      if X < FREE_MAX_STEPS then
        Tmp.Step[X] := EnsureRange(Val, -1, 1);
    end;
    if not ReadInt(Cnt) or (Cnt < 0) or (Cnt > 100000) then
      Exit;
    for X := 0 to Cnt - 1 do
    begin
      if not ReadSingle(Val) then
        Exit;
      if X < FREE_DRAW_N then
        Tmp.Draw[X] := EnsureRange(Val, -1, 1);
    end;
    Result := True;
  end;

  procedure ReadFree;
  var
    J, Ver: Integer;
    Tmp: TFreeLfo;
  begin
    for J := 0 to FREE_LFO_COUNT - 1 do
      FreeLfoDefault(Free[J]);
    Free[2].Mode := 2;
    if (P + 8 > Length(Data)) or not CompareMem(@Data[P], @FREE_MAGIC[0], 4) then
      Exit;
    Inc(P, 4);
    if not ReadInt(Ver) or (Ver < 1) then
      Exit;
    for J := 0 to IfThen(Ver >= 3, 4, IfThen(Ver = 2, 2, 1)) do   // V1: 2, V2: 3, V3: 5 Eintraege
    begin
      if not ReadFreeEntry(Tmp) then
        Exit;
      Free[J] := Tmp;
    end;
  end;

  procedure ReadMorph;
  var
    J, Cnt, Idx: Integer;
    Nm: string;
    Val: Single;
    Tmp: array[0..NAMED_COUNT - 1] of Single;
  begin
    HasMorph := False;
    if (P + 8 > Length(Data)) or not CompareMem(@Data[P], @MORPH_MAGIC[0], 4) then
      Exit;
    Inc(P, 4);
    if not ReadInt(Cnt) or (Cnt < 0) or (Cnt > 100000) then
      Exit;
    // fehlende Eintraege: Standardwert
    for J := 0 to NAMED_COUNT - 1 do
      Tmp[J] := PlainToParam(J, GetParamInfo(J).DefV);
    for J := 0 to Cnt - 1 do
    begin
      if not (ReadStr(Nm) and ReadSingle(Val)) then
        Exit;
      Idx := FindParamV(Nm, Val);
      if (Idx >= 0) and (Idx < NAMED_COUNT) then
        Tmp[Idx] := Val;
    end;
    for J := 0 to NAMED_COUNT - 1 do
      MB[J] := Tmp[J];
    HasMorph := True;
  end;

  procedure ReadArp;
  var
    M: Integer;
  begin
    ArpMaskV := $FFFF;
    // die optionalen Abschnitte koennen in beliebiger Reihenfolge folgen
    if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @ARP_MAGIC[0], 4) then
    begin
      Inc(P, 4);
      if ReadInt(M) then
        ArpMaskV := M and $FFFF;
    end;
  end;

begin
  Result := False;
  SamplePath := '';
  HasMorph := False;
  HasName := False;
  HasMode := False;
  LayerData := nil;
  ArpMaskV := $FFFF;
  if (Length(Data) < 12) or not CompareMem(@Data[0], @CHUNK_MAGIC[0], 4) then
    Exit;
  P := 4;
  if not ReadInt(Version) or (Version < 1) then
    Exit;
  if not ReadInt(Count) or (Count < 0) or (Count > 100000) then
    Exit;

  // erst komplett lesen und pruefen, dann uebernehmen
  Entries := nil;
  for I := 0 to Count - 1 do
  begin
    if not (ReadStr(Name) and ReadSingle(V) and ReadStr(Text)) then
      Exit;
    Idx := FindParamV(Name, V);
    if Idx < 0 then
      Continue;   // Parameter gibt es in dieser Version nicht mehr
    Info := GetParamInfo(Idx);
    // umbenannte Stufen aelterer Presets
    if SameText(Text, 'Amp-Huellk.') then
      Text := 'Grain-Huellk.';
    if SameText(Text, 'Ende Partner-LFO') then
      Text := 'Ende Partner-LFO (Einmal)';
    if (Text <> '') and (Info.Curve = pcStepped) then
    begin
      Found := False;
      for K := 0 to Info.Steps - 1 do
        if SameText(StepName(Idx, K), Text) or SameText(FoldUmlauts(StepName(Idx, K)), FoldUmlauts(Text)) then
        begin
          V := StepToParam(Idx, K);
          Found := True;
          Break;
        end;
      // Matrix-Quelle/-Ziel, das es nicht mehr gibt (z.B. 'Funkeln'): Zeile aus statt falsches Ziel
      if not Found and (Idx >= NAMED_COUNT) and
         (((Idx - NAMED_COUNT) mod MOD_STRIDE = SlotSourceIndex(0) - NAMED_COUNT) or
          ((Idx - NAMED_COUNT) mod MOD_STRIDE = SlotDestIndex(0) - NAMED_COUNT)) then
        V := 0;
    end;
    if Idx = Ord(gpMorphMode) then
      HasMode := True;
    SetLength(Entries, Length(Entries) + 1);
    Entries[High(Entries)].Index := Idx;
    Entries[High(Entries)].Value := V;
  end;
  ReadStr(SamplePath);
  ReadFree;
  ReadMorph;
  ReadArp;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @NAME_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadStr(PName) then
      HasName := True;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @MSMP_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    ReadStr(MRef);
  end;
  FillChar(EqC, SizeOf(EqC), 0);
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @EQCV_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(EqN) and (EqN = EQ_CURVE_N) and (P + EqN * 4 <= Length(Data)) then
    begin
      Move(Data[P], EqC[0], EqN * 4);
      Inc(P, EqN * 4);
    end;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @MRPC_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(LayerN) and (LayerN > 0) and (P + LayerN <= Length(Data)) then
    begin
      LayerData := Copy(Data, P, LayerN);
      Inc(P, LayerN);
    end;
  end;
  TgMaskV := $FFFF;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @TGAT_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(K) then
      TgMaskV := K and $FFFF;
  end;
  for K := 1 to ZONE_COUNT do
  begin
    ZRef[K] := '';
    ZLow[K] := 60;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @ZONE_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 1 to Min(ZN, 16) do
      begin
        if not ReadStr(ZS) or not ReadInt(ZL) then
          Break;
        if K <= ZONE_COUNT then
        begin
          ZRef[K] := ZS;
          ZLow[K] := ZL;
        end;
      end;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @FLF8_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 16) - 1 do
      begin
        if not ReadFreeEntry(Fr8) then
          Break;
        if 5 + K < FREE_LFO_COUNT then
          Free[5 + K] := Fr8;
      end;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @FLSM_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 64) - 1 do
      begin
        if P + 4 > Length(Data) then
          Break;
        if K < FREE_LFO_COUNT then
          Free[K].Smooth := EnsureRange(PSingle(@Data[P])^, 0, 1);
        Inc(P, 4);
      end;
  end;
  for K := 0 to OSC_COUNT - 1 do
    OscDrawDefault(Ow[K]);
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @OSCW_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 16) - 1 do
      begin
        if not ReadInt(ZL) or (ZL < 0) or (ZL > 4096) or (P + ZL * 4 + 4 > Length(Data)) then
          Break;
        if (K < OSC_COUNT) and (ZL > 0) then
          for I := 0 to OSC_DRAW_N - 1 do
          begin
            // andere Punktzahl (aeltere Zwischenstaende): zyklisch linear umrechnen
            Pos := I * ZL / OSC_DRAW_N;
            J := Trunc(Pos);
            Frac := Pos - J;
            Ow[K].Pt[I] := EnsureRange(PSingle(@Data[P + J * 4])^ * (1 - Frac) +
              PSingle(@Data[P + ((J + 1) mod ZL) * 4])^ * Frac, -1, 1);
          end;
        Inc(P, ZL * 4);
        if K < OSC_COUNT then
          Ow[K].Smooth := EnsureRange(PSingle(@Data[P])^, 0, 1);
        Inc(P, 4);
      end;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @FGLD_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 64) - 1 do
      begin
        if P + 8 > Length(Data) then
          Break;
        if K < FREE_LFO_COUNT then
          Free[K].Glide := PUInt64(@Data[P])^;
        Inc(P, 8);
      end;
  end;
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @FPAU_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 64) - 1 do
      begin
        if P + 8 > Length(Data) then
          Break;
        if K < FREE_LFO_COUNT then
          Free[K].Rest := PUInt64(@Data[P])^;
        Inc(P, 8);
      end;
  end;
  for K := 0 to OSC_COUNT - 1 do
    WtR[K] := '';
  if (P + 8 <= Length(Data)) and CompareMem(@Data[P], @OSWT_MAGIC[0], 4) then
  begin
    Inc(P, 4);
    if ReadInt(ZN) then
      for K := 0 to Min(ZN, 16) - 1 do
      begin
        if not ReadStr(ZS) then
          Break;
        if K < OSC_COUNT then
          WtR[K] := ZS;
      end;
  end;

  // Regler, die das Preset nicht kennt (aeltere Presets): Standardwert statt Rest vom vorigen
  // Preset. Master und Tempo gehoeren nicht zum Klang und bleiben.
  for I := 0 to NAMED_COUNT - 1 do
    if not IdIn(TGranularParamId(I), [gpMaster, gpTempo, gpPerformance, gpRenderHQ, gpOversample, gpOscModel]) and
       not ((I = Ord(gpFxInSend)) and GLoadingPresetFile) then
      Engine.SetParam(I, PlainToParam(TGranularParamId(I), GetParamInfo(I).DefV));
  // Leistungsstufe gehoert zum Rechner, nicht zum Klang: Presets aendern sie nicht
  for I := 0 to High(Entries) do
    if (Entries[I].Index <> Ord(gpPerformance)) and (Entries[I].Index <> Ord(gpRenderHQ)) and
      (Entries[I].Index <> Ord(gpOversample)) and (Entries[I].Index <> Ord(gpOscModel)) and
      not ((Entries[I].Index = Ord(gpFxInSend)) and GLoadingPresetFile) then
      Engine.SetParam(Entries[I].Index, Entries[I].Value);
  for I := 0 to FREE_LFO_COUNT - 1 do
    Engine.FreeLfo[I]^ := Free[I];
  // Wavetables nur neu rechnen, wenn sich die Zeichnung geaendert hat
  for I := 0 to OSC_COUNT - 1 do
    if not CompareMem(Engine.OscDraw[I], @Ow[I], SizeOf(TOscDraw)) then
    begin
      Engine.OscDraw[I]^ := Ow[I];
      Engine.OscDrawChanged(I);
    end;
  Engine.ArpMask := Cardinal(ArpMaskV);
  Engine.TgMask := Cardinal(TgMaskV);
  for K := 1 to ZONE_COUNT do
  begin
    Engine.SetZoneRef(K, ZRef[K]);
    Engine.SetZoneLow(K, ZLow[K]);
  end;
  for K := 0 to OSC_COUNT - 1 do
    Engine.WtRef[K] := WtR[K];
  Engine.EqCurve^ := EqC;
  Engine.EqChanged;
  if HasName then
    Engine.PresetName := PName;

  if HasMorph then
  begin
    Engine.SetMorphTarget(MB);
    Engine.MorphSampleRef := MRef;
    // vollstaendiger Klang B (neuere Presets): ersetzt die aus A abgeleiteten Teile
    if (LayerData <> nil) and LoadChunk(Engine.EnsureMorphLayer, LayerData, Dummy) then
      Engine.SyncMorphFromLayer;
    if not HasMode then
      Engine.SetParam(Ord(gpMorphMode), StepToParam(Ord(gpMorphMode), 0));
  end
  else
    Engine.ClearMorphTarget;
  Engine.ResPrepare;     // Resampling-Puffer anlegen, falls das Preset es nutzt
  Result := True;
end;

function MakePortablePath(const Path, BaseDir: string): string;
var
  Base: string;
begin
  Result := Path;
  if (Path = '') or (BaseDir = '') then
    Exit;
  Base := IncludeTrailingPathDelimiter(ExpandFileName(BaseDir));
  if SameText(Copy(ExpandFileName(Path), 1, Length(Base)), Base) then
    Result := Copy(ExpandFileName(Path), Length(Base) + 1, MaxInt);
end;

function ResolveSamplePath(const Path, BaseDir: string): string;
var
  Base, Cand: string;
begin
  Result := '';
  if Path = '' then
    Exit;
  if (ExtractFileDrive(Path) <> '') and FileExists(Path) then
    Exit(Path);
  if BaseDir = '' then
    Exit;
  Base := IncludeTrailingPathDelimiter(BaseDir);
  if ExtractFileDrive(Path) = '' then
  begin
    Cand := Base + Path;
    if FileExists(Cand) then
      Exit(Cand);
  end;
  // verschobene Installation: gleicher Dateiname im Beispiel- oder Eigene-Toene-Ordner
  Cand := Base + 'Beispieltoene' + PathDelim + ExtractFileName(Path);
  if FileExists(Cand) then
    Exit(Cand);
  Cand := Base + USER_SAMPLE_DIR + PathDelim + ExtractFileName(Path);
  if FileExists(Cand) then
    Result := Cand;
end;

function MakeSharedSamplePath(const Path, BaseDir: string): string;
var
  Dir, Dst, Name: string;
  N: Integer;
begin
  Result := MakePortablePath(Path, BaseDir);
  if (Result = '') or (ExtractFileDrive(Result) = '') or not FileExists(Path) then
    Exit;                                       // schon relativ (im Plugin-Ordner) oder nicht da
  Dir := IncludeTrailingPathDelimiter(BaseDir) + USER_SAMPLE_DIR;
  ForceDirectories(Dir);
  Name := ExtractFileName(Path);
  Dst := Dir + PathDelim + Name;
  N := 1;
  // gleicher Name, andere Datei -> nummerieren; gleiche Groesse gilt als dieselbe Datei
  while FileExists(Dst) and (TFile.GetSize(Dst) <> TFile.GetSize(Path)) do
  begin
    Inc(N);
    Dst := Dir + PathDelim + ChangeFileExt(Name, '') + '_' + IntToStr(N) + ExtractFileExt(Name);
  end;
  if not FileExists(Dst) then
    TFile.Copy(Path, Dst);
  Result := USER_SAMPLE_DIR + PathDelim + ExtractFileName(Dst);
end;

{ Zonen-Samples nach dem Laden eines Presets/Chunks: fehlende Dateien -> Zone leer }
{ Punkte je Frame einer Wavetable-Datei: Serum & Co. = 2048; kurze Dateien = ein einzelner Zyklus;
  sonst die groesste Zweierpotenz, die aufgeht }
function WtFrameLen(N: Integer): Integer;
begin
  if (N >= 2048) and (N mod 2048 = 0) then
    Result := 2048
  else if N <= 4096 then
    Result := N
  else if N mod 1024 = 0 then
    Result := 1024
  else if N mod 512 = 0 then
    Result := 512
  else if N mod 256 = 0 then
    Result := 256
  else
    Result := 2048;
end;

procedure LoadOscWavetables(Engine: TGranularEngine; const BaseDir: string);
var
  O, I: Integer;
  Res: string;
  D: TSampleData;
  M: TArray<Single>;
begin
  for O := 0 to OSC_COUNT - 1 do
  begin
    if Engine.WtRef[O] = '' then
      Res := ''
    else
      Res := ResolveSamplePath(Engine.WtRef[O], BaseDir);
    if SameText(Res, Engine.WtLoaded[O]) and ((Res = '') = (Engine.WtFrameCount(O) = 0)) then
      Continue;
    if Res = '' then
    begin
      Engine.SetOscWavetable(O, nil, 0, '');
      Continue;
    end;
    D := nil;
    try
      try
        D := LoadAudioFile(Res);
        SetLength(M, D.Frames);
        for I := 0 to D.Frames - 1 do
          M[I] := (D.L[I] + D.R[I]) * 0.5;
        Engine.SetOscWavetable(O, M, WtFrameLen(D.Frames), Res);
      except
        Engine.SetOscWavetable(O, nil, 0, '');
      end;
    finally
      D.Free;
    end;
  end;
end;

procedure LoadZoneSamples(Engine: TGranularEngine; const BaseDir: string);
var
  Z: Integer;
  Res: string;
begin
  LoadOscWavetables(Engine, BaseDir);   // Nov. 2026: Wavetables der Oszillatoren gehoeren mit dazu
  for Z := 1 to ZONE_COUNT do
  begin
    if Engine.GetZoneRef(Z) = '' then
      Res := ''
    else
      Res := ResolveSamplePath(Engine.GetZoneRef(Z), BaseDir);
    if SameText(Res, Engine.GetZoneLoaded(Z)) and ((Res = '') = (Engine.ZoneSample(Z) = nil)) then
      Continue;
    if Res = '' then
      Engine.SetZone(Z, nil, Engine.GetZoneLow(Z))
    else
      try
        Engine.SetZone(Z, LoadAudioFile(Res), Engine.GetZoneLow(Z));
      except
        Engine.SetZone(Z, nil, Engine.GetZoneLow(Z));
        Res := '';
      end;
    Engine.SetZoneLoaded(Z, Res);
  end;
end;

procedure LoadMorphSample(Engine: TGranularEngine; const BaseDir: string);
var
  Res: string;
begin
  if not Engine.MorphValid or (Engine.MorphSampleRef = '') then
  begin
    if Engine.MorphSampleLoaded <> '' then
      Engine.SetMorphSample(nil, '');
    Exit;
  end;
  Res := ResolveSamplePath(Engine.MorphSampleRef, BaseDir);
  if (Res = '') or SameText(Res, Engine.MorphSampleLoaded) then
    Exit;
  try
    Engine.SetMorphSample(LoadAudioFile(Res), Res);
  except
    Engine.SetMorphSample(nil, '');
  end;
end;

procedure LoadMidiMap(Engine: TGranularEngine; const FileName: string);
var
  L: TStringList;
  I, Cc, P: Integer;
begin
  if not FileExists(FileName) then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FileName, TEncoding.UTF8);
    except
      Exit;
    end;
    for I := 0 to L.Count - 1 do
    begin
      Cc := StrToIntDef(L.Names[I], -1);
      if (Cc < 0) or (Cc > 127) then
        Continue;
      for P := 0 to PARAM_COUNT - 1 do
        if SameText(GetParamInfo(P).Name, L.ValueFromIndex[I]) then
        begin
          Engine.SetCcTarget(Cc, P);
          Break;
        end;
    end;
  finally
    L.Free;
  end;
end;

procedure SaveMidiMap(Engine: TGranularEngine; const FileName: string);
var
  L: TStringList;
  Cc: Integer;
begin
  L := TStringList.Create;
  try
    for Cc := 0 to 127 do
      if Engine.CcTarget(Cc) >= 0 then
        L.Add(IntToStr(Cc) + '=' + GetParamInfo(Engine.CcTarget(Cc)).Name);
    try
      L.SaveToFile(FileName, TEncoding.UTF8);
    except
      // Plugin-Ordner schreibgeschuetzt: Zuordnung gilt dann nur bis zum Schliessen
    end;
  finally
    L.Free;
  end;
end;

const
  EMBD_MAGIC: array[0..3] of AnsiChar = 'EMBD';
  GSEB_MAGIC: array[0..3] of AnsiChar = 'GSEB';
  EMBED_MAX = 512 * 1024 * 1024;   // Schutz gegen kaputte Dateien

{ Anhang mit den Sample-Dateien (Hauptsample, Morph-Ziel B, Zonen) bauen }
function BuildEmbed(Engine: TGranularEngine; const SamplePath, BaseDir: string): TBytes;
var
  Refs: TStringList;
  S: TBytesStream;
  I, N: Integer;
  Res: string;
  Bytes: TBytes;

  procedure AddRef(const Ref: string);
  begin
    if (Ref <> '') and (Refs.IndexOf(Ref) < 0) and (ResolveSamplePath(Ref, BaseDir) <> '') then
      Refs.Add(Ref);
  end;

begin
  Refs := TStringList.Create;
  S := TBytesStream.Create;
  try
    AddRef(SamplePath);
    if Engine.MorphValid then
      AddRef(Engine.MorphSampleRef);
    for I := 1 to ZONE_COUNT do
      AddRef(Engine.GetZoneRef(I));
    S.WriteBuffer(EMBD_MAGIC, 4);
    N := Refs.Count;
    S.WriteBuffer(N, 4);
    for I := 0 to Refs.Count - 1 do
    begin
      Res := ResolveSamplePath(Refs[I], BaseDir);
      Bytes := TFile.ReadAllBytes(Res);
      WriteStr(S, Refs[I]);
      N := Length(Bytes);
      S.WriteBuffer(N, 4);
      if N > 0 then
        S.WriteBuffer(Bytes[0], N);
    end;
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
    Refs.Free;
  end;
end;

{ eingebettetes Sample bereitstellen: ist der Verweis aufloesbar und gleich gross, bleibt er;
  sonst nach 'Eigene Toene' schreiben (gleicher Name, andere Datei -> nummerieren). Ergebnis: neuer Verweis }
function UnpackSample(const Ref: string; const Bytes: TBytes; const BaseDir: string): string;
var
  Res, Dir, Name, Dst: string;
  N: Integer;
begin
  Result := Ref;
  Res := ResolveSamplePath(Ref, BaseDir);
  if (Res <> '') and (TFile.GetSize(Res) = Length(Bytes)) then
    Exit;
  Dir := IncludeTrailingPathDelimiter(BaseDir) + USER_SAMPLE_DIR;
  ForceDirectories(Dir);
  Name := ExtractFileName(StringReplace(Ref, '/', PathDelim, [rfReplaceAll]));
  if Name = '' then
    Name := 'Sample.wav';
  Dst := Dir + PathDelim + Name;
  N := 1;
  while FileExists(Dst) and (TFile.GetSize(Dst) <> Length(Bytes)) do
  begin
    Inc(N);
    Dst := Dir + PathDelim + ChangeFileExt(Name, '') + '_' + IntToStr(N) + ExtractFileExt(Name);
  end;
  if not FileExists(Dst) then
    TFile.WriteAllBytes(Dst, Bytes);
  Result := USER_SAMPLE_DIR + PathDelim + ExtractFileName(Dst);
end;

procedure SaveChunkToFile(Engine: TGranularEngine; const SamplePath, FileName: string;
  const BaseDir: string; Embed: Boolean);
var
  Data, Extra: TBytes;
  S: TFileStream;
  Tmp: string;
  N: Integer;
begin
  Data := SaveChunk(Engine, SamplePath);
  if Embed then
  begin
    Extra := BuildEmbed(Engine, SamplePath, BaseDir);
    N := Length(Data);
    Data := Data + Extra;
    SetLength(Data, Length(Data) + 8);
    Move(N, Data[Length(Data) - 8], 4);
    Move(GSEB_MAGIC, Data[Length(Data) - 4], 4);
  end;
  ForceDirectories(ExtractFilePath(FileName));
  // erst in Temp-Datei schreiben, dann ersetzen -> kein halber Zustand bei Absturz
  Tmp := FileName + '.tmp';
  S := TFileStream.Create(Tmp, fmCreate);
  try
    S.WriteBuffer(Data[0], Length(Data));
  finally
    S.Free;
  end;
  if FileExists(FileName) then
    DeleteFile(FileName);
  RenameFile(Tmp, FileName);
end;

function LoadChunkFromFile(Engine: TGranularEngine; const FileName: string; out SamplePath: string;
  const BaseDir: string): Boolean;
var
  S: TFileStream;
  Data: TBytes;
  Map: TStringList;
  ChunkLen, P, Cnt, I, L, Z: Integer;
  Ref, NewRef: string;
  Bytes: TBytes;

  function Remap(const R: string): string;
  begin
    Result := R;
    if (R <> '') and (Map.IndexOfName(R) >= 0) then
      Result := Map.Values[R];
  end;

begin
  Result := False;
  SamplePath := '';
  if not FileExists(FileName) then
    Exit;
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Data[0], S.Size);
  finally
    S.Free;
  end;
  // eingebettete Samples? (Anhang hinter dem Chunk, erkennbar an 'GSEB' am Dateiende)
  ChunkLen := -1;
  if (Length(Data) > 16) and CompareMem(@Data[Length(Data) - 4], @GSEB_MAGIC[0], 4) then
  begin
    Move(Data[Length(Data) - 8], ChunkLen, 4);
    if (ChunkLen < 12) or (ChunkLen > Length(Data) - 16) or
       not CompareMem(@Data[ChunkLen], @EMBD_MAGIC[0], 4) then
      ChunkLen := -1;
  end;
  if ChunkLen < 0 then
  begin
    GLoadingPresetFile := True;
    try
      Exit(LoadChunk(Engine, Data, SamplePath));
    finally
      GLoadingPresetFile := False;
    end;
  end;
  GLoadingPresetFile := True;
  try
    Result := LoadChunk(Engine, Copy(Data, 0, ChunkLen), SamplePath);
  finally
    GLoadingPresetFile := False;
  end;
  if not Result or (BaseDir = '') then
    Exit;
  Map := TStringList.Create;
  try
    Map.CaseSensitive := False;
    P := ChunkLen + 4;
    Move(Data[P], Cnt, 4);
    Inc(P, 4);
    for I := 0 to Cnt - 1 do
    begin
      if P + 4 > Length(Data) - 8 then Break;
      Move(Data[P], L, 4);
      Inc(P, 4);
      if (L < 0) or (L > 4096) or (P + L > Length(Data) - 8) then Break;
      Ref := TEncoding.UTF8.GetString(Data, P, L);
      Inc(P, L);
      if P + 4 > Length(Data) - 8 then Break;
      Move(Data[P], L, 4);
      Inc(P, 4);
      if (L < 0) or (L > EMBED_MAX) or (P + L > Length(Data) - 8) then Break;
      Bytes := Copy(Data, P, L);
      Inc(P, L);
      try
        NewRef := UnpackSample(Ref, Bytes, BaseDir);
      except
        NewRef := Ref;        // Ordner schreibgeschuetzt: Verweis bleibt, Sample fehlt dann ggf.
      end;
      if NewRef <> Ref then
        Map.Values[Ref] := NewRef;
    end;
    if Map.Count > 0 then
    begin
      SamplePath := Remap(SamplePath);
      Engine.MorphSampleRef := Remap(Engine.MorphSampleRef);
      for Z := 1 to ZONE_COUNT do
        Engine.SetZoneRef(Z, Remap(Engine.GetZoneRef(Z)));
    end;
  finally
    Map.Free;
  end;
end;

end.
