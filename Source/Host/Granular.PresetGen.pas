{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.PresetGen;

{ Erzeugt die mitgelieferten Beispiel-Presets (GranularHost.exe -makepresets <Projektordner>).
  Jedes Preset startet von den Standardwerten und setzt nur, was den Klang ausmacht.
  Samplepfade relativ ("Beispieltoene\...") -> funktionieren in jedem Installationsordner.
  Zusaetzlich wird der eingebaute Demo-Klang als Beispieltoene\Demo_Klang.wav exportiert. }

interface

function MakePresets(const ProjectDir: string): string;

implementation

uses
  System.SysUtils, System.Classes,
  System.Math, Granular.Params, Granular.Eq, Granular.Sample, Granular.Engine, Granular.State, Granular.AudioDecode;

type
  TPresetBuilder = class
  private
    FEngine: TGranularEngine;
    FDir: string;
    FCount: Integer;
    FSample: string;
    FSlot: Integer;
  public
    constructor Create(const Dir: string);
    destructor Destroy; override;
    procedure Start(const SampleFile: string);
    procedure StartBlank;
    procedure P(Id: TGranularParamId; Plain: Double);
    procedure LfoFree(Lfo: Integer; Hz: Double; Shape: Integer);
    procedure LfoSync(Lfo: Integer; Division: Integer; Shape: Integer);
    procedure EchoSync(Division: Integer);
    { Form 'Frei' mit Halbtonstufen (Modus 0) bzw. freien Stufen (Modus 1, Werte -1..1 * 24) }
    procedure FreeSteps(Lfo, Mode: Integer; const Semis: array of Double);
    procedure FreeGlide(Lfo: Integer; const Steps: array of Integer);   // Stufen (ab 0), die gleiten
    procedure Wavetable(Osc: Integer; const FileName: string);           // Osc 1..3, Datei in Beispieltoene
    procedure FreeDraw(Lfo: Integer; Kind: Integer);
    { LFO -> Pitch, Menge 50 %, Faktor x1: eine Stufe = ein Halbton }
    procedure PitchFromFree(Lfo: Integer);
    procedure Hall(Size, Decay, Damp, Pre, Mix: Double);
    { aktuelle Einstellung als Morph-Ziel B merken }
    procedure StoreMorph;
    { aktuelle Einstellung + aktuelles Sample als Morph-Ziel B, danach Sample von A setzen }
    procedure StoreMorphAndSwitch(const SampleA: string);
    { eigener Morph-LFO: Form (1..5 wie LFO-Formen + 1, 6 = frei), frei laufend oder im Takt }
    procedure MorphLfo(Shape: Integer; Hz: Double; Depth: Double);
    { EQ-Kurve wie am Mischpult: Tiefenschnitt unter LowCut, Sub (60 Hz), Mulm (300 Hz),
      Praesenz (3 kHz), Luft (12 kHz) - alles in dB; schaltet den EQ ein }
    procedure Eq(LowCut, Sub, Mud, Presence, Air: Double);
    { Doppel-Preset: dieselben Grain-/Huellkurven-Einstellungen fuer A und B setzen }
    procedure Shared(Grain, Dens, Spray, Scan, Spread, Pos, Att, Dec, Sus, Rel: Double);
    procedure MorphLfoSync(Shape, Division: Integer; Depth: Double);
    { Arpeggiator: Muster als Text, 'x' = Schritt spielt, '.' = Pause; Laenge = Schrittzahl }
    procedure Arp(Mode, Oct, Rate: Integer; Gate, Swing: Double; const Pattern: string);
    { Wirkwert += (Quelle * Faktor + Offset) * Menge  -  Menge/Offset in Prozent }
    procedure M(Src: TModSource; Dst: TGranularParamId; AmountPct: Double;
      FactorIdx: Integer = MOD_FACTOR_DEFAULT; OffsetPct: Double = 0);
    procedure Save(const AName: string);
    function TaggedName(const Name: string): string;
    property Count: Integer read FCount;
  end;

const
  // Notenwerte (Index in LFO_DIV_NAMES)
  D_1_1 = 2; D_1_2 = 3; D_1_4 = 4; D_1_4T = 5; D_1_8 = 6; D_1_8T = 7; D_1_16 = 8;
  // LFO-Formen
  SINUS = 0; DREIECK = 1; SAEGE = 2; RECHTECK = 3; SH = 4;
  // Fenster
  W_HANN = 0; W_DREIECK = 1; W_TRAPEZ = 2; W_GAUSS = 3;
  // Filtertyp
  F_TP = 0; F_BP = 1; F_HP = 2;

{ TPresetBuilder }

constructor TPresetBuilder.Create(const Dir: string);
begin
  inherited Create;
  FDir := IncludeTrailingPathDelimiter(Dir);
  ForceDirectories(FDir);
end;

destructor TPresetBuilder.Destroy;
begin
  FEngine.Free;
  inherited;
end;

procedure TPresetBuilder.Start(const SampleFile: string);
begin
  FreeAndNil(FEngine);
  FEngine := TGranularEngine.Create;   // frische Standardwerte
  P(gpAutoTune, 1);                   // Samples automatisch auf den C-Bezug stimmen
  FSample := 'Beispieltoene' + PathDelim + SampleFile;
  FSlot := 0;
end;

procedure TPresetBuilder.StartBlank;
begin
  FreeAndNil(FEngine);
  FEngine := TGranularEngine.Create;   // nur Standardwerte, kein Sample
  FSample := EMPTY_SAMPLE_REF;
  FSlot := 0;
end;

procedure TPresetBuilder.P(Id: TGranularParamId; Plain: Double);
begin
  FEngine.SetParamById(Id, PlainToParam(Id, Plain));
end;

procedure TPresetBuilder.LfoFree(Lfo: Integer; Hz: Double; Shape: Integer);
begin
  if Lfo = 1 then
  begin
    P(gpLfo1Sync, 0); P(gpLfo1Rate, Hz); P(gpLfo1Shape, Shape);
  end
  else if Lfo = 3 then
  begin
    P(gpLfo3Sync, 0); P(gpLfo3Rate, Hz); P(gpLfo3Shape, Shape);
  end
  else if Lfo = 4 then
  begin
    P(gpLfo4Sync, 0); P(gpLfo4Rate, Hz); P(gpLfo4Shape, Shape);
  end
  else
  begin
    P(gpLfo2Sync, 0); P(gpLfo2Rate, Hz); P(gpLfo2Shape, Shape);
  end;
end;

procedure TPresetBuilder.LfoSync(Lfo: Integer; Division: Integer; Shape: Integer);
var
  Norm: Single;
begin
  Norm := Division / (LFO_DIV_COUNT - 1);
  if Lfo = 1 then
  begin
    P(gpLfo1Sync, 1); FEngine.SetParamById(gpLfo1Rate, Norm); P(gpLfo1Shape, Shape);
  end
  else if Lfo = 3 then
  begin
    P(gpLfo3Sync, 1); FEngine.SetParamById(gpLfo3Rate, Norm); P(gpLfo3Shape, Shape);
  end
  else if Lfo = 4 then
  begin
    P(gpLfo4Sync, 1); FEngine.SetParamById(gpLfo4Rate, Norm); P(gpLfo4Shape, Shape);
  end
  else
  begin
    P(gpLfo2Sync, 1); FEngine.SetParamById(gpLfo2Rate, Norm); P(gpLfo2Shape, Shape);
  end;
end;

procedure TPresetBuilder.EchoSync(Division: Integer);
begin
  P(gpEchoSync, 1);
  FEngine.SetParamById(gpEchoTime, (LFO_DIV_COUNT - 1 - Division) / (LFO_DIV_COUNT - 1));
end;

procedure TPresetBuilder.FreeSteps(Lfo, Mode: Integer; const Semis: array of Double);
var
  F: PFreeLfo;
  I: Integer;
begin
  F := FEngine.FreeLfo[Lfo - 1];
  F.Mode := Mode;
  F.Steps := Length(Semis);
  for I := 0 to High(Semis) do
    F.Step[I] := EnsureRange(Semis[I] / FREE_SEMIS, -1, 1);
  if Lfo = 3 then P(gpMorphLfoShape, MORPH_LFO_FREE)
  else if Lfo = 1 then P(gpLfo1Shape, LFO_SHAPE_FREE) else P(gpLfo2Shape, LFO_SHAPE_FREE);
end;

procedure TPresetBuilder.FreeGlide(Lfo: Integer; const Steps: array of Integer);
var
  I: Integer;
begin
  FEngine.FreeLfo[Lfo - 1].Glide := 0;
  for I := 0 to High(Steps) do
    FEngine.FreeLfo[Lfo - 1].Glide := FEngine.FreeLfo[Lfo - 1].Glide or (UInt64(1) shl Steps[I]);
end;

procedure TPresetBuilder.Wavetable(Osc: Integer; const FileName: string);
begin
  FEngine.WtRef[Osc - 1] := FileName;          // relativ: wird gegen Plugin-Ordner bzw. Beispieltoene aufgeloest
  FEngine.SetParamById(OSC_P[Osc - 1].WtOn, 1);
end;

procedure TPresetBuilder.FreeDraw(Lfo: Integer; Kind: Integer);
var
  F: PFreeLfo;
  I: Integer;
  X: Double;
begin
  F := FEngine.FreeLfo[Lfo - 1];
  F.Mode := 2;
  for I := 0 to FREE_DRAW_N - 1 do
  begin
    X := I / FREE_DRAW_N;
    case Kind of
      3: F.Draw[I] := -1 + (1 - Exp(-9 * X)) * 0.95;                       // Pumpen: Einbruch auf dem Schlag, dann zurueck
      0: F.Draw[I] := Exp(-6 * X) * 2 - 1;                                   // Zupfen: schnell hoch, langsam runter
      1: F.Draw[I] := Sin(2 * Pi * X) * 0.6 + Sin(6 * Pi * X) * 0.4;          // Welle mit Oberton
    else
      F.Draw[I] := Sin(2 * Pi * X) * (1 - X);                                // ausklingendes Wackeln
    end;
  end;
  if Lfo = 1 then P(gpLfo1Shape, LFO_SHAPE_FREE) else P(gpLfo2Shape, LFO_SHAPE_FREE);
end;

procedure TPresetBuilder.PitchFromFree(Lfo: Integer);
begin
  if Lfo = 1 then
  begin
    M(msLfo1, gpPitch, 50, MOD_FACTOR_DEFAULT, 0);
    P(gpLfo1Trig, 1);
  end
  else
  begin
    M(msLfo2, gpPitch, 50, MOD_FACTOR_DEFAULT, 0);
    P(gpLfo2Trig, 1);
  end;
end;

procedure TPresetBuilder.StoreMorph;
begin
  FEngine.StoreMorphTarget;
  P(gpMorphMode, 0);           // Morph-Flaechen: Werte stufenlos ueberblenden (wie bisher)
end;

procedure TPresetBuilder.Eq(LowCut, Sub, Mud, Presence, Air: Double);
var
  I: Integer;
  F, G: Double;
  C: PEqCurve;
begin
  C := FEngine.EqCurve;
  for I := 0 to EQ_CURVE_N - 1 do
  begin
    F := EQ_F_MIN * Power(EQ_F_MAX / EQ_F_MIN, I / (EQ_CURVE_N - 1));
    G := Sub * Exp(-Sqr(Ln(F / 60) / 0.7)) + Mud * Exp(-Sqr(Ln(F / 300) / 0.6)) +
      Presence * Exp(-Sqr(Ln(F / 3000) / 0.7)) + Air * Exp(-Sqr(Ln(F / 12000) / 0.8));
    if (LowCut > 0) and (F < LowCut) then
      G := G - 18 * Min(1, Ln(LowCut / F) / Ln(2));       // ca. 18 dB je Oktave darunter
    C[I] := EnsureRange(G, -EQ_MAX_DB, EQ_MAX_DB);
  end;
  FEngine.EqChanged;
  P(gpEqOn, 1);
end;

procedure TPresetBuilder.Shared(Grain, Dens, Spray, Scan, Spread, Pos, Att, Dec, Sus, Rel: Double);
begin
  P(gpGrainSize, Grain); P(gpDensity, Dens); P(gpSpray, Spray); P(gpScan, Scan); P(gpSpread, Spread);
  P(gpPosition, Pos); P(gpWindow, W_HANN);
  P(gpAttack, Att); P(gpDecay, Dec); P(gpSustain, Sus); P(gpRelease, Rel);
end;

procedure TPresetBuilder.MorphLfo(Shape: Integer; Hz: Double; Depth: Double);
begin
  P(gpMorphLfoShape, Shape); P(gpMorphLfoSync, 0); P(gpMorphLfoRate, Hz); P(gpMorphLfoDepth, Depth);
end;

procedure TPresetBuilder.MorphLfoSync(Shape, Division: Integer; Depth: Double);
begin
  P(gpMorphLfoShape, Shape); P(gpMorphLfoSync, 1); P(gpMorphLfoDepth, Depth);
  FEngine.SetParamById(gpMorphLfoRate, Division / (LFO_DIV_COUNT - 1));
end;

procedure TPresetBuilder.StoreMorphAndSwitch(const SampleA: string);
begin
  FEngine.StoreMorphTarget;
  P(gpMorphMode, 0);
  FEngine.MorphSampleRef := FSample;          // Sample von B = bisheriges Sample
  FSample := 'Beispieltoene' + PathDelim + SampleA;
end;

procedure TPresetBuilder.Arp(Mode, Oct, Rate: Integer; Gate, Swing: Double; const Pattern: string);
var
  I: Integer;
  M: Cardinal;
begin
  P(gpArpOn, 1); P(gpArpMode, Mode); P(gpArpOct, Oct - 1); P(gpArpRate, Rate);
  P(gpArpGate, Gate); P(gpArpSwing, Swing); P(gpArpSteps, Length(Pattern) - 1);
  M := 0;
  for I := 1 to Length(Pattern) do
    if Pattern[I] = 'x' then
      M := M or (1 shl (I - 1));
  FEngine.ArpMask := M;
end;

procedure TPresetBuilder.Hall(Size, Decay, Damp, Pre, Mix: Double);
begin
  P(gpRevOn, 1); P(gpRevSize, Size); P(gpRevDecay, Decay); P(gpRevDamp, Damp);
  P(gpRevPreDelay, Pre); P(gpRevMix, Mix);
end;

procedure TPresetBuilder.M(Src: TModSource; Dst: TGranularParamId; AmountPct: Double;
  FactorIdx: Integer; OffsetPct: Double);
begin
  FEngine.SetParam(SlotSourceIndex(FSlot), StepToParam(SlotSourceIndex(FSlot), Ord(Src)));
  FEngine.SetParam(SlotDestIndex(FSlot), StepToParam(SlotDestIndex(FSlot), Ord(Dst) + 1));
  FEngine.SetParam(SlotAmountIndex(FSlot), PlainToParam(SlotAmountIndex(FSlot), AmountPct));
  FEngine.SetParam(SlotFactorIndex(FSlot), StepToParam(SlotFactorIndex(FSlot), FactorIdx));
  FEngine.SetParam(SlotOffsetIndex(FSlot), PlainToParam(SlotOffsetIndex(FSlot), OffsetPct));
  Inc(FSlot);
end;

{ Namensregel: "Nummer GRAINS + FM - Thema - Name", "Nummer GRAINS - ..." oder "Nummer FM - ...", je nachdem
  ob Grains und/oder Oszillatoren klingen (Klang A oder Morph-Ziel B). Vorhandene Kennzeichen im Namen
  werden ersetzt - so passt die Filtersuche immer zum tatsaechlichen Klang. }
function TPresetBuilder.TaggedName(const Name: string): string;
const
  OLD_TAGS: array[0..5] of string = ('GRAINS + FM - ', 'Grains + FM - ', 'FM + Grains - ', 'GRAINS - ', 'Grains - ', 'FM - ');
var
  Num, Rest, Tag: string;
  P, I: Integer;
  G, O: Boolean;

  function GrainsOn(B: Boolean): Boolean;
  begin
    if B then
      Result := ParamStep(Ord(gpGrainOn), FEngine.MorphBValue(gpGrainOn)) = 1
    else
      Result := ParamStep(Ord(gpGrainOn), FEngine.GetParam(Ord(gpGrainOn))) = 1;
  end;

  function OscOn(B: Boolean): Boolean;
  var
    K: Integer;
    VOn, VLvl: Single;
  begin
    Result := False;
    for K := 0 to OSC_COUNT - 1 do
    begin
      if B then
      begin
        VOn := FEngine.MorphBValue(OSC_P[K].On_); VLvl := FEngine.MorphBValue(OSC_P[K].Level);
      end
      else
      begin
        VOn := FEngine.GetParam(Ord(OSC_P[K].On_)); VLvl := FEngine.GetParam(Ord(OSC_P[K].Level));
      end;
      if (ParamStep(Ord(OSC_P[K].On_), VOn) = 1) and (ParamToPlain(Ord(OSC_P[K].Level), VLvl) > 0.5) then
        Exit(True);
    end;
  end;

begin
  P := Pos(' ', Name);
  if P = 0 then
    Exit(Name);
  Num := Copy(Name, 1, P - 1);
  Rest := Copy(Name, P + 1, MaxInt);
  for I := 0 to High(OLD_TAGS) do
    if Copy(Rest, 1, Length(OLD_TAGS[I])) = OLD_TAGS[I] then
    begin
      Rest := Copy(Rest, Length(OLD_TAGS[I]) + 1, MaxInt);
      Break;
    end;
  if Copy(Rest, 1, 4) = 'Init' then
    Exit(Name);                               // Init-Presets bleiben schlicht
  G := GrainsOn(False);
  O := OscOn(False);
  if FEngine.MorphValid then
  begin
    G := G or GrainsOn(True);
    O := O or OscOn(True);
  end;
  if G and O then Tag := 'GRAINS + FM'
  else if G then Tag := 'GRAINS'
  else if O then Tag := 'FM'
  else Tag := '';
  if Tag = '' then
    Result := Num + ' ' + Rest
  else
    Result := Num + ' ' + Tag + ' - ' + Rest;
end;

const
  { aussortierte Presets (01.11.2026): Code bleibt als Vorlage stehen, die Nummern werden nicht wieder vergeben }
  DELETED_PRESETS: array[0..18] of Integer = (2, 3, 23, 35, 40, 46, 48, 55, 65, 66, 95, 101, 107, 109, 112, 113, 117, 133, 158);

function IsDeletedPreset(const AName: string): Boolean;
var
  N, I: Integer;
begin
  N := StrToIntDef(Copy(AName, 1, Pos(' ', AName) - 1), -1);
  for I := 0 to High(DELETED_PRESETS) do
    if DELETED_PRESETS[I] = N then
      Exit(True);
  Result := False;
end;

procedure TPresetBuilder.Save(const AName: string);
var
  Check: TGranularEngine;
  Path, Resolved, Name: string;
  I, Blk: Integer;
  BufL, BufR: TArray<Single>;
  Peak: Single;
begin
  // vom Nutzer aussortiert: wird nicht mehr erzeugt, die Nummer bleibt frei (nie neu vergeben)
  if IsDeletedPreset(AName) then
  begin
    if FileExists(FDir + TaggedName(AName) + '.gspreset') then
      DeleteFile(FDir + TaggedName(AName) + '.gspreset');
    Exit;
  end;
  Name := TaggedName(AName);
  // Doppel-Presets: zwei vollstaendig getrennte Klaenge (eigene Tonhoehe, Effekte, LFOs je Instrument)
  if Pos('(Doppel)', Name) > 0 then
    P(gpMorphMode, 1);
  SaveChunkToFile(FEngine, FSample, FDir + Name + '.gspreset');
  // Gegenprobe: zurueckladen, alle Werte und den Samplepfad pruefen
  Check := TGranularEngine.Create;
  try
    if not LoadChunkFromFile(Check, FDir + Name + '.gspreset', Path) then
      raise Exception.Create('Preset nicht lesbar: ' + Name);
    for I := 0 to PARAM_COUNT - 1 do
      if Abs(Check.GetParam(I) - FEngine.GetParam(I)) > 1E-6 then
        raise Exception.CreateFmt('Preset %s: Parameter %s weicht ab', [Name, GetParamInfo(I).Name]);
    if Path = EMPTY_SAMPLE_REF then
    begin
      Inc(FCount);   // leeres Init-Preset: keine Hoerprobe
      Exit;
    end;
    Resolved := ResolveSamplePath(Path, ExtractFilePath(ExcludeTrailingPathDelimiter(FDir)));
    if Resolved = '' then
      raise Exception.CreateFmt('Preset %s: Sample %s nicht gefunden', [Name, Path]);
    // Hoerprobe ohne Sidechain: eine Note, 2,5 s (auch langsame Einblendungen) - kein Preset darf (fast) stumm sein
    Check.SetSampleRate(44100);
    Check.LoadSample(LoadAudioFile(Resolved));
    LoadMorphSample(Check, ExtractFilePath(ExcludeTrailingPathDelimiter(FDir)));
    Check.NoteOn(60, 0.8);
    SetLength(BufL, 512);
    SetLength(BufR, 512);
    Peak := 0;
    for Blk := 0 to 214 do
    begin
      Check.Process(nil, nil, @BufL[0], @BufR[0], 512);
      for I := 0 to 511 do
        Peak := Max(Peak, Max(Abs(BufL[I]), Abs(BufR[I])));
    end;
    if Peak < 0.0316 then   // -30 dBFS
      raise Exception.CreateFmt('Preset %s ist ohne Sidechain zu leise (Spitze %.1f dB)',
        [Name, 20 * Log10(Max(Peak, 1E-9))]);
  finally
    Check.Free;
  end;
  Inc(FCount);
end;

{ ------------------------------------------------------------------------------ }

procedure BuildAll(B: TPresetBuilder);
begin
  // ===== Leer =====
  B.StartBlank;
  B.Save('00 Init (leer)');

  // ===== Flaechen / Pads =====
  B.Start('Demo_Klang.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 45); B.P(gpSpray, 4); B.P(gpSpread, 40);
  B.P(gpAttack, 20); B.P(gpRelease, 600);
  B.Save('01 Init Demo-Klang');

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 260); B.P(gpDensity, 32); B.P(gpSpray, 14); B.P(gpScan, 0.25);
  B.P(gpSpread, 85); B.P(gpPitchRand, 0.08); B.P(gpWindow, W_GAUSS);
  B.P(gpAttack, 900); B.P(gpDecay, 1500); B.P(gpSustain, 85); B.P(gpRelease, 2600);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 4500); B.P(gpFltReso, 10); B.P(gpFltContour, 70);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 45); B.P(gpEchoDamp, 55); B.P(gpEchoMix, 25);
  B.LfoFree(1, 0.12, SINUS); B.M(msLfo1, gpPosition, 18);
  B.Save('02 Chor-Wolke');

  B.Start('Chor_Aah.wav');
  B.P(gpScan, 0); B.P(gpPosition, 45); B.P(gpSpray, 6); B.P(gpGrainSize, 420); B.P(gpDensity, 26);
  B.P(gpPitchRand, 0.12); B.P(gpSpread, 100); B.P(gpWindow, W_HANN);
  B.P(gpAttack, 1600); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpEchoOn, 1); B.P(gpEchoTime, 620); B.P(gpEchoFeedback, 55); B.P(gpEchoDamp, 70); B.P(gpEchoMix, 30);
  B.Save('03 Gefrorener Chor');

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 40); B.P(gpScan, 0.5); B.P(gpSpray, 8); B.P(gpSpread, 75);
  B.P(gpAttack, 700); B.P(gpDecay, 1200); B.P(gpSustain, 90); B.P(gpRelease, 2200);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2200); B.P(gpFltReso, 25); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 35); B.P(gpFltAttack, 1200); B.P(gpFltDecay, 2500); B.P(gpFltSustain, 40);
  B.LfoFree(1, 0.18, DREIECK); B.M(msLfo1, gpFltCutoff, 12);
  B.Save('04 Streicher-Pad');

  B.Start('Streicherflaeche.wav');
  B.P(gpScan, 0.08); B.P(gpGrainSize, 330); B.P(gpDensity, 28); B.P(gpReverse, 35); B.P(gpSpray, 20);
  B.P(gpSpread, 90); B.P(gpPitch, -12); B.P(gpAttack, 2000); B.P(gpRelease, 4500);
  B.P(gpEchoOn, 1); B.P(gpEchoTime, 900); B.P(gpEchoFeedback, 60); B.P(gpEchoDamp, 80); B.P(gpEchoMix, 35);
  B.Save('05 Streicher in Zeitlupe');

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 50); B.P(gpScan, 0.6); B.P(gpSpread, 70);
  B.P(gpAttack, 30); B.P(gpSustain, 80); B.P(gpRelease, 1200);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 300); B.P(gpFltReso, 65); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 75); B.P(gpFltAttack, 1800); B.P(gpFltDecay, 2500); B.P(gpFltSustain, 35); B.P(gpFltRelease, 1500);
  B.Save('06 Filter-Sweep-Pad');

  // ===== Glocken / Glas =====
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 140); B.P(gpDensity, 55); B.P(gpSpray, 25); B.P(gpScan, 0.4); B.P(gpReverse, 30);
  B.P(gpSpread, 95); B.P(gpPitch, 12); B.P(gpAttack, 300); B.P(gpRelease, 3000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_HP); B.P(gpFltCutoff, 500); B.P(gpFltContour, 80);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 62); B.P(gpEchoDamp, 35); B.P(gpEchoMix, 40);
  B.Save('07 Glas-Shimmer');

  B.Start('Kennedy_Berliner.wav');
  B.P(gpGrainSize, 100); B.P(gpDensity, 50); B.P(gpScan, 1); B.P(gpSpread, 25); B.P(gpKeyTrack, 0);
  B.P(gpAttack, 5); B.P(gpSustain, 100); B.P(gpRelease, 1200);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 72); B.P(gpEchoDamp, 15);
  B.P(gpEchoPitch, 5); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 50);      // jedes Wort klettert in Quarten
  B.Hall(60, 2.5, 40, 15, 20);
  B.Save('08 Echo-Treppe - Kennedy klettert');

  // ===== Rhythmisch / perkussiv =====
  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 45); B.P(gpScan, 1); B.P(gpSpread, 50); B.P(gpWindow, W_TRAPEZ);
  B.P(gpAttack, 3); B.P(gpSustain, 100); B.P(gpRelease, 250);
  B.P(gpFltOn, 1); B.P(gpFltType, F_BP); B.P(gpFltCutoff, 1400); B.P(gpFltReso, 55); B.P(gpFltContour, 50);
  B.LfoSync(1, D_1_8, RECHTECK); B.M(msLfo1, gpFltCutoff, 25);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 45); B.P(gpEchoMix, 30);
  B.Save('09 Puls-Arpeggio (Sync)');

  B.Start('drumloop_120bpm.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 30); B.P(gpScan, 1); B.P(gpSpray, 0); B.P(gpReverse, 15);
  B.P(gpKeyTrack, 0); B.P(gpWindow, W_TRAPEZ); B.P(gpAttack, 2); B.P(gpSustain, 100); B.P(gpRelease, 150);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_16); B.P(gpEchoFeedback, 50); B.P(gpEchoMix, 30);
  B.LfoSync(1, D_1_4, SH); B.M(msLfo1, gpGrainSize, 20);
  B.Save('11 Drum-Stotterer');

  // ===== Texturen / Atmosphaere =====
  B.Start('Armstrong_Mondlandung.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 45); B.P(gpScan, 1); B.P(gpSpread, 30); B.P(gpKeyTrack, 0);
  B.P(gpAttack, 5); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4T); B.P(gpEchoFeedback, 75); B.P(gpEchoDamp, 10);
  B.P(gpEchoPitch, 7); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 50);      // Quinten aufwaerts ins All
  B.Hall(85, 6, 35, 30, 30);
  B.Save('13 Echo-Treppe - Armstrong steigt auf');

  // ===== Tasten =====
  // ===== Stimme =====

  // ===== Modulation / Sidechain-Demos =====
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 150); B.P(gpDensity, 45); B.P(gpScan, 0.2); B.P(gpSpread, 70);
  B.P(gpAttack, 50); B.P(gpSustain, 100); B.P(gpRelease, 1000);
  B.P(gpScPitchMode, 2);                                  // Auto-Pitch, Halbtoene
  B.M(msSidechain, gpVolume, 30);                         // lauter, wenn Signal kommt
  B.P(gpVolume, -8);                                      // auch ohne Signal hoerbar
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 35); B.P(gpEchoMix, 20);
  B.Save('19 Sidechain-Saenger (Auto-Pitch)');

  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainSize, 60); B.P(gpDensity, 70); B.P(gpScan, 0.8); B.P(gpSpread, 60);
  B.P(gpAttack, 5); B.P(gpRelease, 600);
  B.M(msNoteRandom, gpPosition, 80);                      // jede Note startet woanders
  B.M(msVelocity, gpFltCutoff, 40);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1200); B.P(gpFltReso, 35); B.P(gpFltContour, 100);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4T); B.P(gpEchoFeedback, 50); B.P(gpEchoMix, 30);
  B.Save('21 Zufall je Note');

  // ===== Pitch-Echo =====
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 30); B.P(gpSpray, 30); B.P(gpSpread, 60);
  B.P(gpAttack, 5); B.P(gpRelease, 900);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 70); B.P(gpEchoDamp, 25);
  B.P(gpEchoPitch, -7); B.P(gpEchoMix, 50);
  B.LfoSync(1, D_1_2, SH); B.M(msLfo1, gpEchoTime, 25);              // Echozeit springt rhythmisch
  B.LfoFree(2, 0.2, SINUS); B.M(msLfo2, gpEchoPitch, 15);             // Pitch-Drift wandert
  B.Save('23 Fallendes Zufalls-Echo');

  // ===== Freier LFO, Einmal-Modus, Hall =====

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 40); B.P(gpSpread, 70); B.P(gpAttack, 20); B.P(gpRelease, 1200);
  B.LfoFree(1, 0.6, SINUS); B.FreeDraw(1, 0);                // gezeichnete Zupf-Kurve
  B.P(gpLfo1Trig, 1); B.P(gpLfo1Once, 1);                     // einmal pro Note
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 900); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.M(msLfo1, gpFltCutoff, 45);
  B.Hall(60, 2.5, 45, 15, 30);
  B.Save('26 Einmal - gezeichneter Filter-Zupfer');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 35); B.P(gpSpread, 40); B.P(gpAttack, 2); B.P(gpRelease, 500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 70); B.P(gpEchoDamp, 20);
  B.P(gpEchoPitch, 12); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 50);   // jede Wiederholung eine Oktave hoeher
  B.Hall(80, 4, 30, 20, 30);
  B.Save('28 Echo-Treppe Oktaven + Hall');

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 35); B.P(gpSpray, 10); B.P(gpSpread, 90);
  B.P(gpAttack, 600); B.P(gpRelease, 3000);
  B.Hall(100, 14, 25, 60, 55);
  B.Save('29 Hall - Kathedrale');

  // ===== Tonleiter, Grain-Akkord, Morph, Freeze, Saettigung, Gate =====

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 40); B.P(gpSpread, 80); B.P(gpAttack, 300); B.P(gpRelease, 2000);
  B.P(gpFreeze, 1); B.P(gpPosition, 35);
  B.Hall(90, 8, 30, 40, 50);
  B.Save('35 Freeze - eingefrorener Chor (Hall unendlich)');

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 60); B.P(gpSpread, 10); B.P(gpPitch, -12); B.P(gpAttack, 3); B.P(gpRelease, 300);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 600); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.P(gpDrive, 55);
  B.Save('36 Saettigung - warmer Bass');

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 120); B.P(gpDensity, 60); B.P(gpSpread, 70); B.P(gpAttack, 5); B.P(gpRelease, 400);
  B.LfoSync(1, D_1_1, SINUS);
  B.FreeSteps(1, 1, [0, -24, 0, -24, 0, 0, -24, 0, 0, -24, 0, -24, 0, 0, 0, -24]);   // 16tel-Gate
  B.M(msLfo1, gpVolume, 100);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoMix, 25);
  B.Hall(60, 2.5, 40, 10, 25);
  B.Save('37 Gate - Streicher im 16tel-Rhythmus');

  // Morph: Ziel B = dunkle, weite Flaeche; A = helle, kurze Glocke; LFO wandert dazwischen
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 300); B.P(gpDensity, 25); B.P(gpSpread, 100); B.P(gpAttack, 800); B.P(gpRelease, 4000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 700); B.P(gpFltContour, 100);
  B.Hall(100, 10, 50, 50, 55);
  B.StoreMorph;
  B.P(gpGrainSize, 40); B.P(gpDensity, 80); B.P(gpSpread, 40); B.P(gpAttack, 2); B.P(gpRelease, 900);
  B.P(gpFltCutoff, 8000); B.P(gpRevMix, 15); B.P(gpRevDecay, 1.5);
  B.LfoFree(1, 0.08, SINUS); B.M(msLfo1, gpMorph, 50, MOD_FACTOR_DEFAULT, 100);   // 0..100 % hin und her
  B.Save('38 Morph - Glocke wandert zur Flaeche');

  // ===== Flaechen, die sich langsam veraendern =====
  // Regeln gegen "Roboter"-Klang: lange Grains (>= 150 ms) mit weichem Fenster, maessige Dichte,
  // etwas Positions-Streuung (keine starre Wiederholrate = kein Brummton), Bewegung nur ueber
  // sehr langsame LFOs (0,02 .. 0,15 Hz) und Hall als Raum.
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 260); B.P(gpDensity, 30); B.P(gpSpray, 8); B.P(gpScan, 0.05); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.1); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2500); B.P(gpFltReso, 20); B.P(gpFltContour, 60);
  B.LfoFree(1, 0.05, SINUS); B.M(msLfo1, gpPosition, 25);          // wandert langsam durch den Chor
  B.LfoFree(2, 0.13, DREIECK); B.M(msLfo2, gpFltCutoff, 30);        // atmet in der Helligkeit
  B.M(msModWheel, gpFltCutoff, 40);                                  // Modrad oeffnet
  B.Hall(85, 7, 45, 40, 40);
  B.Save('39 Flaeche - Atmender Chor');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 320); B.P(gpDensity, 22); B.P(gpSpray, 15); B.P(gpScan, 0.02); B.P(gpSpread, 100);
  B.P(gpPitchRand, 7); B.P(gpScale, 5); B.P(gpScaleRoot, 0);          // funkelt in C-Dur-Pentatonik (passt zu Am F C G)
  B.P(gpWindow, W_GAUSS); B.P(gpAttack, 900); B.P(gpRelease, 5000);
  B.LfoFree(1, 0.03, SINUS); B.M(msLfo1, gpGrainSize, 25);
  B.LfoFree(2, 0.07, SINUS); B.M(msLfo2, gpSpray, 30);
  B.Hall(100, 12, 35, 50, 50);
  B.Save('40 Flaeche - Glaeserne Daemmerung');

  // Morph: B = dunkler, gefilterter Ozean, A = heller; LFO wandert in ~25 s zwischen beiden
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 240); B.P(gpDensity, 35); B.P(gpSpray, 10); B.P(gpScan, 0.15); B.P(gpSpread, 85);
  B.P(gpPitchRand, 0.08); B.P(gpWindow, W_HANN); B.P(gpAttack, 1500); B.P(gpRelease, 5000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 700); B.P(gpFltReso, 25); B.P(gpFltContour, 100);
  B.Hall(95, 9, 60, 30, 50);
  B.StoreMorph;
  B.P(gpFltCutoff, 7000); B.P(gpGrainSize, 160); B.P(gpRevMix, 30);
  B.LfoFree(1, 0.04, SINUS); B.M(msLfo1, gpMorph, 50, MOD_FACTOR_DEFAULT, 100);
  B.LfoFree(2, 0.09, DREIECK); B.M(msLfo2, gpPosition, 20);
  B.Save('41 Flaeche - Streicher-Ozean (Morph)');

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 280); B.P(gpDensity, 28); B.P(gpSpray, 6); B.P(gpScan, 0.08); B.P(gpSpread, 80);
  B.P(gpPitchRand, 0.12); B.P(gpWindow, W_HANN); B.P(gpAttack, 1000); B.P(gpRelease, 4500);
  B.P(gpDrive, 18);
  B.LfoFree(1, 0.02, SINUS); B.M(msLfo1, gpPosition, 40);
  B.LfoSync(2, D_1_1, SINUS); B.M(msLfo2, gpSpread, 25);             // leichte Bewegung im Takt
  B.M(msAftertouch, gpGrainSize, 35);                                 // Druck macht weicher
  B.Hall(75, 6, 50, 30, 35);
  B.Save('43 Flaeche - Warmes Pad im Wind');

  B.Start('vokale_aeiou.wav');
  B.P(gpGrainSize, 300); B.P(gpDensity, 24); B.P(gpSpray, 5); B.P(gpScan, 0); B.P(gpSpread, 70);
  B.P(gpPitchRand, 0.1); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1400); B.P(gpRelease, 5000);
  B.P(gpPosition, 50);
  B.LfoFree(1, 0.025, DREIECK); B.M(msLfo1, gpPosition, 45);         // ~40 s durch a-e-i-o-u
  B.Hall(90, 10, 55, 60, 50);
  B.Save('44 Flaeche - Vokal-Nebel');

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 35); B.P(gpSpread, 90); B.P(gpAttack, 600); B.P(gpRelease, 3000);
  B.P(gpWindow, W_GAUSS); B.P(gpPosition, 40);
  B.M(msModWheel, gpFreeze, 100);                                     // Modrad hoch = einfrieren
  B.M(msModWheel, gpRevMix, 40);
  B.Hall(90, 8, 35, 40, 35);
  B.Save('45 Flaeche - Modrad friert ein');

  // ===== Arpeggiator =====
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 60); B.P(gpSpread, 50); B.P(gpAttack, 2); B.P(gpDecay, 250);
  B.P(gpSustain, 30); B.P(gpRelease, 400);
  B.Arp(0, 2, 3, 55, 0, 'xxxxxxxx');                                  // hoch, 2 Oktaven, 1/16
  B.Hall(70, 3, 35, 20, 30);
  B.Save('46 Arp - Glocken aufwaerts');

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 60); B.P(gpSpread, 70); B.P(gpAttack, 3); B.P(gpRelease, 250);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2200); B.P(gpFltReso, 35); B.P(gpFltContour, 100);
  B.Arp(6, 1, 1, 40, 0, 'x..x..x.');                                  // Akkord-Stabs im 3-3-2
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 30);
  B.Hall(60, 2.5, 40, 10, 25);
  B.Save('48 Arp - Akkord-Stabs (3-3-2)');

  // ===== Beruehmte Stimmen (gemeinfreie Aufnahmen, Wikimedia Commons) =====
  // Armstrong 1969 (NASA), Kennedy 1963 "Ich bin ein Berliner" (Schluss der Rede), Caruso/Melba 1907
  B.Start('Armstrong_Mondlandung.wav');
  B.P(gpGrainSize, 260); B.P(gpDensity, 28); B.P(gpSpray, 10); B.P(gpScan, 0.08); B.P(gpSpread, 100);
  B.P(gpPitchRand, 0.1); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1500); B.P(gpRelease, 5000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 3500); B.P(gpFltReso, 15); B.P(gpFltContour, 80);
  B.LfoFree(1, 0.04, SINUS); B.M(msLfo1, gpPosition, 40);
  B.Hall(100, 14, 40, 60, 55);
  B.Save('51 Stimme - Mondlandung im Weltraum (Flaeche)');

  B.Start('Armstrong_Mondlandung.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 40); B.P(gpScan, 1); B.P(gpSpread, 40); B.P(gpAttack, 5); B.P(gpRelease, 800);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 60); B.P(gpEchoDamp, 40);
  B.P(gpEchoPitch, -5); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 45);       // jede Wiederholung tiefer
  B.Hall(80, 5, 50, 20, 30);
  B.Save('52 Stimme - Armstrong Funk-Echo');

  B.Start('Kennedy_Berliner.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 50); B.P(gpScan, 1); B.P(gpSpread, 30); B.P(gpAttack, 5); B.P(gpRelease, 900);
  B.P(gpKeyTrack, 0);                                                     // Sprache in Originalhoehe
  B.Hall(85, 4, 40, 30, 40);
  B.Save('53 Stimme - Kennedy auf dem Rathausplatz');

  B.Start('Kennedy_Berliner.wav');
  B.P(gpGrainSize, 290); B.P(gpDensity, 25); B.P(gpSpray, 6); B.P(gpScan, 0); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.12); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1500); B.P(gpRelease, 5000);
  B.LfoFree(1, 0.02, DREIECK); B.M(msLfo1, gpPosition, 48);             // wandert ~50 s durch den Satz
  B.M(msModWheel, gpFreeze, 100);
  B.Hall(95, 10, 50, 50, 50);
  B.Save('54 Stimme - Berliner Nebel (Flaeche)');

  B.Start('Kennedy_Berliner.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 60); B.P(gpScan, 1); B.P(gpSpread, 50); B.P(gpAttack, 2); B.P(gpRelease, 200);
  B.P(gpKeyTrack, 0);
  B.M(msNoteRandom, gpPosition, 100);                                     // jeder Arp-Schritt ein anderes Wort
  B.Arp(0, 1, 3, 70, 15, 'xx.xx.x.');
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 25);
  B.Save('55 Stimme - Kennedy Schnipsel-Arp');

  B.Start('Caruso_Melba_Oper.wav');
  B.P(gpGrainSize, 300); B.P(gpDensity, 26); B.P(gpSpray, 6); B.P(gpScan, 0.05); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.08); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpRelease, 5000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 4500); B.P(gpFltContour, 70);   // Schellack-Rauschen zaehmen
  B.LfoFree(1, 0.03, SINUS); B.M(msLfo1, gpPosition, 35);
  B.M(msModWheel, gpFreeze, 100);
  B.Hall(95, 10, 45, 40, 50);
  B.Save('56 Oper - Caruso-Flaeche');

  B.Start('Caruso_Melba_Oper.wav');
  B.P(gpGrainSize, 240); B.P(gpDensity, 32); B.P(gpSpray, 3); B.P(gpSpread, 80); B.P(gpWindow, W_GAUSS);
  B.P(gpAttack, 800); B.P(gpRelease, 6000); B.P(gpPosition, 70); B.P(gpFreeze, 1);       // Schlusston halten
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 5000); B.P(gpFltContour, 60);
  B.Hall(100, 16, 40, 50, 55);
  B.Save('57 Oper - Eingefrorener Schlusston');

  B.Start('Caruso_Melba_Oper.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 30); B.P(gpScan, 0.25); B.P(gpSpread, 70); B.P(gpWindow, W_HANN);
  B.P(gpAttack, 400); B.P(gpRelease, 3000); B.P(gpKeyTrack, 0);           // Duett in Zeitlupe, Originalhoehe
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 5000); B.P(gpFltContour, 60);
  B.Hall(85, 7, 40, 30, 40);
  B.Save('58 Oper - Duett in Zeitlupe');

  // ===== Weitere Echo-Treppen: erkennbares Sample, jede Wiederholung eine Stufe hoeher/tiefer =====

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 130); B.P(gpDensity, 45); B.P(gpScan, 1); B.P(gpSpread, 50);
  B.P(gpAttack, 10); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 68); B.P(gpEchoDamp, 25);
  B.P(gpEchoPitch, 5); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 45);      // Akkord-Kaskade in Quarten
  B.Hall(75, 4, 40, 20, 30);
  B.Save('62 Echo-Treppe - Pad-Kaskade');

  // ===== Sidechain-Trigger: Ereignisse am Eingang starten LFOs =====
  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 40); B.P(gpSpread, 70); B.P(gpAttack, 200); B.P(gpRelease, 2500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 500); B.P(gpFltReso, 50); B.P(gpFltContour, 100);
  B.LfoFree(1, 0.5, SAEGE); B.P(gpLfo1Trig, LFO_TRIG_SC_LEVEL); B.P(gpLfo1Once, 1);
  B.M(msLfo1, gpFltCutoff, -45, MOD_FACTOR_DEFAULT, -100);    // laut ins Mikro -> Filter klappt auf und schliesst
  B.P(gpScTrigLevel, 35);
  B.Hall(70, 4, 40, 20, 30);
  B.Save('65 SC-Trigger - Lautes Wort oeffnet den Filter');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 45); B.P(gpSpread, 50); B.P(gpAttack, 5); B.P(gpRelease, 1500);
  B.LfoFree(1, 0.4, SINUS); B.FreeSteps(1, 0, [0, 7, 12, 19, 24, 19, 12, 7]);
  B.PitchFromFree(1);
  B.P(gpLfo1Trig, LFO_TRIG_SC_LEVEL); B.P(gpLfo1Once, 1);       // Sidechain-Trigger ...
  B.P(gpScUseLevel, 0); B.P(gpScUsePitch, 1);                     // ... nur ueber den Ton: hoher gesungener Ton startet das Arpeggio
  B.P(gpScTrigNote, 64);
  B.Hall(80, 5, 35, 25, 35);
  B.Save('66 SC-Trigger - Hoher Ton startet Glocken-Arpeggio');

  // ===== Schwellen-Tor: beliebige Quelle schaltet Ein/Aus-Regler =====
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 130); B.P(gpDensity, 50); B.P(gpSpread, 70); B.P(gpAttack, 20); B.P(gpRelease, 900);
  B.Arp(2, 2, 3, 70, 0, 'xxxxxxxxxxxxxxxx'); B.P(gpArpOn, 0);   // Arp eingestellt, aber aus ...
  B.P(gpGateSrc, Ord(msModWheel)); B.P(gpGateThresh, 50);
  B.M(msGate, gpArpOn, 100);                                       // ... Modrad ueber die Haelfte = Arp an
  B.Hall(75, 4, 40, 20, 30);
  B.Save('67 Tor - Modrad schaltet den Arp ein');

  B.Start('E-Piano_Akkorde.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 45); B.P(gpSpread, 40); B.P(gpAttack, 5); B.P(gpRelease, 1200);
  B.P(gpEchoOn, 0); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 65); B.P(gpEchoPitch, 7); B.P(gpEchoMix, 45);
  B.P(gpGateSrc, Ord(msVelocity)); B.P(gpGateThresh, 75);
  B.M(msGate, gpEchoOn, 100);                                      // nur kraeftig gespielte Noten bekommen die Echo-Treppe
  B.Hall(65, 3, 40, 15, 25);
  B.Save('68 Tor - Kraeftiger Anschlag schaltet Echo-Treppe');

  // ===== Echtes Morphen zwischen zwei Klangquellen (Grain-Ueberblendung + Regler) =====
  // Ziel B wird zuerst gebaut und gemerkt, danach Klang A; der eigene Morph-LFO pendelt dazwischen.
  B.Start('Streicherflaeche.wav');                                     // B: weite Streicherflaeche
  B.P(gpGrainSize, 240); B.P(gpDensity, 30); B.P(gpSpray, 8); B.P(gpScan, 0.15); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.08); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 900); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 3500); B.P(gpFltReso, 15); B.P(gpFltContour, 60);
  B.Hall(95, 8, 45, 40, 45);
  B.StoreMorphAndSwitch('Kettensaege.wav');                           // A: Kettensaege
  B.P(gpGrainSize, 80); B.P(gpDensity, 45); B.P(gpSpray, 0); B.P(gpScan, 1); B.P(gpSpread, 40);
  B.P(gpPitchRand, 0); B.P(gpWindow, W_TRAPEZ); B.P(gpAttack, 5); B.P(gpRelease, 1500);
  B.P(gpFltType, F_BP); B.P(gpFltCutoff, 1400); B.P(gpFltReso, 30); B.P(gpFltContour, 50);
  B.P(gpRevMix, 20); B.P(gpRevDecay, 2.5);
  B.P(gpMorph, 50); B.MorphLfo(1, 0.05, 100);                          // ~20 s: Saege -> Streicher -> Saege
  B.Save('69 Morph - Kettensaege wird Streicherflaeche');

  B.Start('Chor_Aah.wav');                                             // B: Chorflaeche
  B.P(gpGrainSize, 230); B.P(gpDensity, 32); B.P(gpSpray, 6); B.P(gpScan, 0.05); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.1); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 600); B.P(gpSustain, 100); B.P(gpRelease, 3500);
  B.Hall(90, 7, 40, 35, 45);
  B.StoreMorphAndSwitch('Glasglocken.wav');                           // A: Glockenschlag (kurzer Anschlag)
  B.P(gpGrainSize, 80); B.P(gpDensity, 50); B.P(gpSpray, 3); B.P(gpScan, 1); B.P(gpSpread, 50);
  B.P(gpPitchRand, 0); B.P(gpWindow, W_HANN); B.P(gpAttack, 2); B.P(gpDecay, 350); B.P(gpSustain, 40); B.P(gpRelease, 1500);
  B.P(gpRevMix, 30); B.P(gpRevDecay, 4);
  B.P(gpMorph, 50);
  B.FreeSteps(3, 1, [-24, -24, 24, 24, -24, 24, 24, -24]);              // Glocke, Glocke, Chor, Chor, ...
  B.MorphLfoSync(MORPH_LFO_FREE, 0, 100);                               // ein Durchlauf = 4 Takte
  B.Save('70 Morph - Glockenschlag und Chorflaeche im Wechsel');

  B.Start('Chor_Aah.wav');                                             // B: Chor
  B.P(gpGrainSize, 260); B.P(gpDensity, 28); B.P(gpSpray, 6); B.P(gpScan, 0.05); B.P(gpSpread, 90);
  B.P(gpPitchRand, 0.1); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 800); B.P(gpRelease, 4000);
  B.Hall(95, 9, 45, 45, 50);
  B.StoreMorphAndSwitch('Kennedy_Berliner.wav');                      // A: Kennedy-Rede
  B.P(gpGrainSize, 100); B.P(gpDensity, 50); B.P(gpSpray, 0); B.P(gpScan, 1); B.P(gpSpread, 30);
  B.P(gpPitchRand, 0); B.P(gpWindow, W_HANN); B.P(gpAttack, 10); B.P(gpRelease, 1500);
  B.P(gpRevMix, 30); B.P(gpRevDecay, 3);
  B.P(gpMorph, 50); B.MorphLfo(2, 0.04, 100);                          // Dreieck: Sprache loest sich in den Chor auf
  B.Save('71 Morph - Kennedy spricht in den Chor');

  // ===== Echte Instrumente (University of Iowa MIS, frei verwendbar) - hochwertig =====
  // Jedes Sample so gestimmt, dass Taste = gespielte Tonhoehe (Pitch = 60 - Samplenote).
  // Ausgehaltene Instrumente: Position im eingeschwungenen Teil, Scan 0, lange weiche Grains ->
  // natuerlicher Ton beliebig lang; leichtes LFO-Vibrato und Raum.
  B.Start('Floete_C5.wav');
  B.P(gpPitch, -12); B.P(gpPosition, 45); B.P(gpScan, 0); B.P(gpSpray, 6); B.P(gpGrainSize, 170);
  B.P(gpDensity, 45); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 35); B.P(gpAttack, 70); B.P(gpSustain, 100); B.P(gpRelease, 900);
  B.LfoFree(1, 5.2, SINUS); B.M(msLfo1, gpPitch, 0.35);               // Vibrato
  B.M(msModWheel, gpPitch, 0.5);                                         // Modrad: mehr Vibrato-Spielraum
  B.Hall(70, 3.5, 40, 25, 30);
  B.Save('73 Floete - Atemhauch-Melodie');

  B.Start('Oboe_C5.wav');
  B.P(gpPitch, -12); B.P(gpPosition, 50); B.P(gpScan, 0); B.P(gpSpray, 5); B.P(gpGrainSize, 150);
  B.P(gpDensity, 48); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 30); B.P(gpAttack, 50); B.P(gpSustain, 100); B.P(gpRelease, 700);
  B.LfoFree(1, 5.5, SINUS); B.M(msLfo1, gpPitch, 0.3);
  B.P(gpDrive, 8);
  B.Hall(65, 3, 45, 20, 28);
  B.Save('74 Oboe - Pastorale');

  B.Start('Trompete_C4.wav');
  B.P(gpPitch, 0); B.P(gpPosition, 40); B.P(gpScan, 0); B.P(gpSpray, 5); B.P(gpGrainSize, 140);
  B.P(gpDensity, 55); B.P(gpWindow, W_HANN); B.P(gpSpread, 30); B.P(gpAttack, 25); B.P(gpSustain, 100); B.P(gpRelease, 600);
  B.M(msVelocity, gpFltCutoff, 30);                                      // kraeftig = strahlender
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 4000); B.P(gpFltContour, 60);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 20); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 15);
  B.Hall(80, 4, 40, 30, 30);
  B.Save('75 Trompete - Fanfare im Saal');

  B.Start('Horn_C4.wav');
  B.P(gpPitch, 0); B.P(gpPosition, 45); B.P(gpScan, 0.04); B.P(gpSpray, 8); B.P(gpGrainSize, 260);
  B.P(gpDensity, 30); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 80); B.P(gpPitchRand, 0.06);
  B.P(gpAttack, 800); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.LfoFree(1, 0.06, SINUS); B.M(msLfo1, gpSpread, 25);
  B.Hall(95, 8, 45, 40, 45);
  B.Save('76 Horn - Waldhorn-Flaeche');

  B.Start('Tuba_C2.wav');
  B.P(gpPitch, 24); B.P(gpPosition, 45); B.P(gpScan, 0); B.P(gpSpray, 5); B.P(gpGrainSize, 200);
  B.P(gpDensity, 40); B.P(gpWindow, W_HANN); B.P(gpSpread, 20); B.P(gpAttack, 120); B.P(gpSustain, 100); B.P(gpRelease, 1200);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1800); B.P(gpFltContour, 70);
  B.P(gpDrive, 15);
  B.Hall(60, 2.5, 50, 15, 22);
  B.Save('77 Tuba - Tiefe Saeule');

  B.Start('Cello_C3.wav');
  B.P(gpPitch, 12); B.P(gpPosition, 50); B.P(gpScan, 0); B.P(gpSpray, 6); B.P(gpGrainSize, 180);
  B.P(gpDensity, 45); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 40); B.P(gpAttack, 120); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.LfoFree(1, 5.0, SINUS); B.M(msLfo1, gpPitch, 0.35);
  B.M(msAftertouch, gpPitch, 0.6);                                       // Druck = mehr Vibrato
  B.Hall(80, 4, 40, 25, 32);
  B.Save('78 Cello - Kantilene');

  B.Start('Violine_C5.wav');
  B.P(gpPitch, -12); B.P(gpPosition, 50); B.P(gpScan, 0.03); B.P(gpSpray, 8); B.P(gpGrainSize, 280);
  B.P(gpDensity, 32); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 90); B.P(gpPitchRand, 0.1);     // Ensemble-Schweben
  B.P(gpAttack, 1000); B.P(gpSustain, 100); B.P(gpRelease, 5000);
  B.LfoFree(1, 0.05, SINUS); B.M(msLfo1, gpPosition, 15);
  B.Hall(95, 9, 45, 40, 45);
  B.Save('79 Violinen - Ensemble-Flaeche');

  B.Start('Klavier_C4.wav');
  B.P(gpPitch, 0); B.P(gpPosition, 0); B.P(gpScan, 1); B.P(gpSpray, 0); B.P(gpGrainSize, 120);
  B.P(gpDensity, 50); B.P(gpWindow, W_HANN); B.P(gpSpread, 30); B.P(gpAttack, 2); B.P(gpDecay, 2500);
  B.P(gpSustain, 40); B.P(gpRelease, 1500);
  B.M(msVelocity, gpFltCutoff, 35);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 3500); B.P(gpFltContour, 60);
  B.Hall(70, 3, 35, 15, 25);
  B.Save('80 Klavier - Konzertglanz');

  B.Start('Vibraphon_C4.wav');
  B.P(gpPitch, 0); B.P(gpPosition, 0); B.P(gpScan, 0.7); B.P(gpSpray, 2); B.P(gpGrainSize, 150);
  B.P(gpDensity, 45); B.P(gpWindow, W_HANN); B.P(gpSpread, 50); B.P(gpAttack, 2); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.LfoFree(1, 5.5, SINUS); B.M(msLfo1, gpVolume, 5);                    // Vibraphon-Motor (Tremolo)
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 18);
  B.Hall(85, 6, 35, 25, 35);
  B.Save('81 Vibraphon - Nachtclub-Traum');

  B.Start('Didgeridoo_D2.wav');
  B.P(gpKeyTrack, 0); B.P(gpPosition, 30); B.P(gpScan, 0.3); B.P(gpSpray, 6); B.P(gpGrainSize, 250);
  B.P(gpDensity, 30); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 60); B.P(gpAttack, 600); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_BP); B.P(gpFltCutoff, 900); B.P(gpFltReso, 35); B.P(gpFltContour, 50);
  B.LfoFree(1, 0.12, DREIECK); B.M(msLfo1, gpFltCutoff, 35);
  B.Hall(70, 5, 50, 20, 30);
  B.Save('82 Didgeridoo - Erdtrance (Flaeche)');

  // ===== Instrument-Flaechen mit Morph (nur gleich gestimmte Paare -> kein Tonhoehen-Gleiten) =====
  B.Start('Trompete_C4.wav');                                         // B: Trompeten-Flaeche
  B.P(gpPitch, 0); B.P(gpPosition, 40); B.P(gpScan, 0.03); B.P(gpSpray, 8); B.P(gpGrainSize, 240);
  B.P(gpDensity, 32); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 85); B.P(gpPitchRand, 0.06);
  B.P(gpAttack, 900); B.P(gpSustain, 100); B.P(gpRelease, 4500);
  B.Hall(95, 8, 45, 40, 45);
  B.StoreMorphAndSwitch('Horn_C4.wav');                               // A: Horn-Flaeche
  B.P(gpPosition, 45); B.P(gpGrainSize, 270);
  B.P(gpMorph, 50); B.MorphLfo(1, 0.03, 100);                          // ~33 s: Horn -> Trompete -> Horn
  B.Save('83 Flaeche - Blechblaeser-Atem (Morph)');

  B.Start('Violine_C5.wav');                                          // B: Violinen
  B.P(gpPitch, -12); B.P(gpPosition, 50); B.P(gpScan, 0.03); B.P(gpSpray, 8); B.P(gpGrainSize, 280);
  B.P(gpDensity, 30); B.P(gpWindow, W_GAUSS); B.P(gpSpread, 90); B.P(gpPitchRand, 0.1);
  B.P(gpAttack, 1000); B.P(gpSustain, 100); B.P(gpRelease, 5000);
  B.Hall(95, 9, 45, 40, 45);
  B.StoreMorphAndSwitch('Floete_C5.wav');                             // A: Floeten
  B.P(gpPosition, 45); B.P(gpGrainSize, 220);
  B.P(gpMorph, 50); B.MorphLfo(2, 0.04, 100);
  B.Save('84 Flaeche - Floete schwebt in die Violinen (Morph)');

  B.Start('Vibraphon_C4.wav');                                        // B: Vibraphon
  B.P(gpPitch, 0); B.P(gpPosition, 0); B.P(gpScan, 0.7); B.P(gpGrainSize, 150); B.P(gpDensity, 45);
  B.P(gpWindow, W_HANN); B.P(gpSpread, 50); B.P(gpAttack, 2); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.Hall(85, 6, 35, 25, 35);
  B.StoreMorphAndSwitch('Klavier_C4.wav');                            // A: Klavier
  B.P(gpScan, 1); B.P(gpGrainSize, 120); B.P(gpDecay, 2500); B.P(gpSustain, 40); B.P(gpRelease, 1500);
  B.P(gpMorph, 50); B.MorphLfoSync(1, 0, 100);                          // im Takt: Klavier <-> Vibraphon
  B.Save('85 Klavier und Vibraphon im Wechsel (Morph)');

  // ===== Knabenchor (synthetisch) und Kontraste =====
  B.Start('Knabenchor_C5.wav');
  B.P(gpGrainSize, 280); B.P(gpDensity, 28); B.P(gpSpray, 8); B.P(gpScan, 0.04); B.P(gpSpread, 95);
  B.P(gpPitchRand, 0.08); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpSustain, 100); B.P(gpRelease, 5000);
  B.P(gpPosition, 40);
  B.LfoFree(1, 0.04, SINUS); B.M(msLfo1, gpPosition, 30);             // wandert durch Aah -> Ooh
  B.P(gpEqOn, 1); B.P(gpEqTreble, 3);                                    // etwas Glanz
  B.Hall(100, 11, 40, 50, 55);
  B.Save('86 Knabenchor - Engelsflaeche');

  B.Start('pad_akkord.wav');                                          // B: tiefe Bassflaeche, kein Arp
  B.P(gpPitch, -12); B.P(gpGrainSize, 260); B.P(gpDensity, 30); B.P(gpSpray, 6); B.P(gpScan, 0.05);
  B.P(gpSpread, 80); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 900); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 900); B.P(gpFltContour, 80);
  B.Hall(85, 6, 50, 30, 40);
  B.StoreMorphAndSwitch('Glasglocken.wav');                           // A: hoher Arp
  B.P(gpPitch, 12); B.P(gpGrainSize, 70); B.P(gpDensity, 55); B.P(gpScan, 0.3); B.P(gpSpread, 50);
  B.P(gpAttack, 2); B.P(gpDecay, 250); B.P(gpSustain, 30); B.P(gpRelease, 500);
  B.P(gpFltCutoff, 9000);
  B.Arp(0, 2, 3, 50, 10, 'xxxxxxxx');
  B.P(gpMorph, 50); B.MorphLfo(1, 0.05, 100);                          // ~20 s: Arp oben <-> Bassflaeche unten
  B.P(gpVolume, 6);                                                    // Pegel angleichen (Analyse)
  B.Save('88 Arp oben trifft Bassflaeche (Morph)');

  // ===== Deep House / House / Elektro: harmonische Samples, EQ wie am Mischpult =====

  B.Start('Deep_Stab_Cm9.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 50); B.P(gpScan, 1); B.P(gpSpread, 50); B.P(gpWindow, W_HANN);
  B.P(gpAttack, 2); B.P(gpDecay, 380); B.P(gpSustain, 0); B.P(gpRelease, 300);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1900); B.P(gpFltReso, 30); B.P(gpFltContour, 90);
  B.LfoSync(1, 1, SINUS); B.M(msLfo1, gpFltCutoff, 30);
  B.Arp(6, 1, 3, 60, 0, 'x..x..x...x..x..');                             // klassischer Stab-Rhythmus
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 45); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 30);
  B.Eq(150, 0, -2, 2, 2);
  B.Hall(60, 2.5, 45, 15, 22);
  B.P(gpVolume, 7);                                                    // Pegel angleichen (Analyse)
  B.Save('90 Deep House - Moll9-Stabs (Arp)');

  B.Start('Rhodes_C4.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 50); B.P(gpScan, 1); B.P(gpSpread, 70); B.P(gpPitchRand, 0.05);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 2); B.P(gpDecay, 1800); B.P(gpSustain, 35); B.P(gpRelease, 1200);
  B.LfoFree(1, 4.8, SINUS); B.M(msLfo1, gpSpread, 25);                   // Stereo-Tremolo
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 25); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 15);
  B.Eq(80, 0, 1.5, -1.5, 2);                                              // warm, nicht spitz
  B.Hall(70, 3, 40, 20, 25);
  B.Save('91 House - Rhodes-Melodie');

  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 50); B.P(gpScan, 0); B.P(gpPosition, 30); B.P(gpSpread, 0);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 8); B.P(gpSustain, 100); B.P(gpRelease, 250);
  B.P(gpDrive, 25);
  B.Eq(30, 3, -1, -2, -6);                                                // Druck unten, oben ruhig
  B.Save('92 Deep - Warmer Sub-Bass');

  B.Start('Deep_Stab_Cm9.wav');                                        // B: Moll-9 als Flaeche
  B.P(gpPosition, 25); B.P(gpGrainSize, 240); B.P(gpDensity, 32); B.P(gpSpray, 6); B.P(gpScan, 0.02);
  B.P(gpSpread, 100); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 700); B.P(gpSustain, 100); B.P(gpRelease, 3500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2400); B.P(gpFltContour, 70);
  B.Hall(85, 5, 40, 30, 35);
  B.StoreMorphAndSwitch('House_Akkord_Cmaj9.wav');                    // A: Dur-9-Flaeche
  B.P(gpPosition, 40); B.P(gpGrainSize, 230); B.P(gpFltCutoff, 3000);
  B.Eq(110, 0, -2, 1, 3);
  B.P(gpMorph, 50); B.MorphLfoSync(1, 0, 100);                          // Dur -> Moll -> Dur ueber 4 Takte
  B.Save('94 Deep House - Dur wird Moll (Morph-Flaeche)');

  B.Start('Rhodes_C4.wav');
  B.P(gpGrainSize, 80); B.P(gpDensity, 55); B.P(gpScan, 1); B.P(gpSpread, 60); B.P(gpAttack, 2);
  B.P(gpDecay, 400); B.P(gpSustain, 20); B.P(gpRelease, 600);
  B.Arp(0, 3, 3, 50, 12, 'xxxxxxxxxxxxxxxx');
  B.P(gpScale, 5); B.P(gpScaleRoot, 0);                                   // C-Dur-Pentatonik: immer harmonisch
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 25);
  B.Eq(300, 0, -1, 1, 4);                                                 // bleibt oben, Platz fuer Bass
  B.Hall(70, 3.5, 35, 20, 28);
  B.Save('95 Elektro - Glitzer-Arp in C-Dur');

  B.Start('Deep_Stab_Cm9.wav');
  B.P(gpGrainSize, 80); B.P(gpDensity, 55); B.P(gpScan, 1); B.P(gpSpread, 45); B.P(gpAttack, 2);
  B.P(gpDecay, 300); B.P(gpSustain, 0); B.P(gpRelease, 250);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1500); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.LfoSync(1, 0, SINUS); B.FreeSteps(1, 1, [-10, -4, 2, 8, 14, 8, 2, -4]);   // Filter oeffnet stufenweise
  B.M(msLfo1, gpFltCutoff, 35);
  B.Arp(6, 1, 3, 55, 0, 'x.x..x.x..x.x...');
  B.P(gpDrive, 20);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 50); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 35);
  B.Eq(120, 0, -2, 2, 1);
  B.Hall(55, 2, 50, 10, 18);
  B.P(gpVolume, 6);                                                    // Pegel angleichen (Analyse)
  B.Save('96 Techno - Hypnotische Akkord-Schleife (Arp)');

  // ===== Doppel-Presets: zwei Instrumente gleichzeitig (feste Morph-Stellung = Schichtung) =====
  // A und B bekommen dieselben Grain-/Huellkurven-Werte, damit die Mischung nichts verschmiert.
  B.Start('Violine_C5.wav');                                          // B: Violinen
  B.P(gpPitch, -12); B.Shared(180, 40, 5, 0.4, 75, 35, 4, 2600, 55, 2200);
  B.Hall(85, 4.5, 40, 25, 35);
  B.StoreMorphAndSwitch('Klavier_C4.wav');                            // A: Klavier
  B.P(gpPitch, 0);
  B.Eq(70, 0, -1, 0.5, 2);
  B.P(gpMorph, 42);                                                       // 58 % Klavier, 42 % Streicher
  B.Save('98 Klavier mit Streichern (Doppel)');

  B.Start('pad_akkord.wav');                                          // B: dunkler Akkord-Teppich
  B.P(gpPitch, 0); B.Shared(200, 38, 6, 0.06, 80, 40, 150, 3000, 85, 2500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2200); B.P(gpFltReso, 15); B.P(gpFltContour, 70);
  B.Hall(90, 6, 45, 30, 40);
  B.StoreMorphAndSwitch('Trompete_C4.wav');                           // A: Trompete
  B.LfoFree(1, 5.2, SINUS); B.M(msLfo1, gpPitch, 0.3);
  B.Eq(45, 1.5, -2, 1.5, 1);
  B.P(gpMorph, 45);
  B.Save('99 Trompete ueber dunklem Teppich (Doppel)');

  B.Start('Tuba_C2.wav');                                             // B: Tuba (eine Oktave unter der Oboe -> sehr tief)
  B.P(gpPitch, -12); B.Shared(190, 40, 5, 0.03, 60, 45, 90, 2500, 90, 1800);
  B.Hall(80, 5, 50, 25, 35);
  B.StoreMorphAndSwitch('Oboe_C5.wav');                               // A: Oboe
  B.LfoFree(1, 5.5, SINUS); B.M(msLfo1, gpPitch, 0.25);
  B.Eq(30, 2, -2, 1, 1);
  B.P(gpMorph, 40);
  B.Save('100 Oboe ueber tiefer Tuba (Doppel)');

  B.Start('Violine_C5.wav');                                          // B: Violinen
  B.P(gpPitch, -12); B.Shared(120, 50, 3, 0.3, 80, 40, 3, 400, 60, 500);
  B.Hall(70, 3, 40, 15, 28);
  B.StoreMorphAndSwitch('Rhodes_C4.wav');                             // A: Rhodes
  B.P(gpPitch, 0);
  B.LfoSync(1, 2, SINUS);
  B.FreeSteps(1, 1, [0, -24, 0, -24, 0, 0, -24, 0, 0, -24, 0, -24, 0, 0, 0, -24]);   // Gute-Laune-Gate
  B.M(msLfo1, gpVolume, 100);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 22);
  B.Eq(110, 0, -2, 1.5, 2.5);
  B.P(gpMorph, 50);
  B.P(gpVolume, 3);
  B.Save('101 Deep House - Rhodes und Streicher im Gate (Doppel)');

  B.Start('Violine_C5.wav');                                          // B: Violinen
  B.P(gpPitch, -12); B.Shared(200, 38, 6, 0.3, 85, 40, 6, 3000, 60, 2600);
  B.Hall(92, 7, 40, 35, 42);
  B.StoreMorphAndSwitch('Klavier_C4.wav');                            // A: Klavier
  B.P(gpPitch, 0);
  // Oszillator-Schicht: Sinus zwei Oktaven tiefer als Sub-Fundament
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 1); B.P(gpOscLevel, 45);
  B.P(gpOscAttack, 20); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 70); B.P(gpOscRelease, 1500);
  B.Eq(30, 1.5, -2, 0.5, 2);
  B.P(gpMorph, 45);
  B.Save('102 Emotional - Klavier, Streicher und Sub (Doppel)');

  // ===== Dunkle Flaeche mit Sternenstaub =====
  B.Start('pad_akkord.wav');
  B.P(gpPitch, -12); B.P(gpGrainSize, 260); B.P(gpDensity, 32); B.P(gpSpray, 6); B.P(gpScan, 0.05);
  B.P(gpSpread, 85); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpSustain, 100); B.P(gpRelease, 4500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 650); B.P(gpFltReso, 20); B.P(gpFltContour, 100);
  B.LfoFree(1, 0.04, SINUS); B.M(msLfo1, gpFltCutoff, 15);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 45); B.P(gpEchoDamp, 10); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 30);
  B.Eq(35, 2, -1, 0, 3);
  B.Hall(100, 10, 30, 40, 50);
  B.Save('104 Deep House - Dunkle Flaeche mit Sternenstaub');

  // ===== Erde, Dschungel, Voegel - und als Kontrast eine warme Industrieflaeche =====
  // Auto-Panning: LFO -> Summen-Panorama ueber die Matrix
  B.Start('Dschungel_Voegel.wav');
  B.P(gpKeyTrack, 0); B.P(gpGrainSize, 130); B.P(gpDensity, 40); B.P(gpSpray, 10); B.P(gpScan, 1);
  B.P(gpSpread, 90); B.P(gpWindow, W_HANN); B.P(gpAttack, 600); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.LfoFree(1, 0.08, SINUS); B.M(msLfo1, gpPan, 25);                    // Auto-Pan: der Wald wandert
  B.Eq(150, 0, -1, 1, 3);
  B.Hall(85, 5, 35, 25, 35);
  B.Save('105 Natur - Dschungelmorgen (Flaeche)');

  B.Start('Erde_Grollen.wav');                                        // B: Erde
  B.P(gpKeyTrack, 0); B.Shared(200, 32, 8, 0.3, 90, 40, 900, 3000, 100, 4500);
  B.Hall(90, 7, 40, 30, 40);
  B.StoreMorphAndSwitch('Dschungel_Voegel.wav');                      // A: Voegel
  B.P(gpMorph, 50); B.MorphLfo(1, 0.03, 70);                            // mal mehr Voegel, mal mehr Erde
  B.LfoFree(1, 0.09, SINUS); B.M(msLfo1, gpPan, 30);
  B.Eq(30, 1.5, -1.5, 0.5, 2.5);
  B.Save('107 Natur - Voegel ueber der Erde (Morph-Flaeche)');

  B.Start('Dschungel_Voegel.wav');                                    // B: Dschungel
  B.P(gpKeyTrack, 0); B.Shared(220, 30, 8, 0.15, 95, 40, 1000, 3000, 100, 5000);
  B.Hall(90, 7, 40, 30, 40);
  B.StoreMorphAndSwitch('Industrie_Brummen.wav');                     // A: warme Industrie
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1800); B.P(gpFltReso, 25); B.P(gpFltContour, 70);
  B.P(gpDrive, 15);
  B.P(gpMorph, 50); B.MorphLfo(2, 0.025, 100);                          // wandert ~40 s: Fabrik <-> Dschungel
  B.LfoFree(1, 0.11, SINUS); B.M(msLfo1, gpPan, 35);                    // ... und durch den Raum
  B.LfoFree(2, 0.06, SINUS); B.M(msLfo2, gpFltCutoff, 20);
  B.Eq(40, 1.5, -2, 0, 1.5);
  B.Save('108 Kontrast - Warme Industrie wandert in den Dschungel (Morph-Flaeche)');

  B.Start('Industrie_Brummen.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 40); B.P(gpSpray, 4); B.P(gpScan, 0.5); B.P(gpSpread, 70);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 20); B.P(gpSustain, 100); B.P(gpRelease, 900);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2200); B.P(gpFltReso, 30); B.P(gpFltContour, 80);
  B.LfoSync(1, 4, SINUS); B.FreeDraw(1, 3); B.M(msLfo1, gpVolume, 45);   // Pumpen auf jeder Viertel
  B.LfoSync(2, 2, SINUS); B.M(msLfo2, gpPan, 30);                        // Auto-Pan ueber einen Takt
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 20);
  B.P(gpDrive, 20);
  B.Eq(60, 1, -2, 1, 1);
  B.Hall(60, 2.5, 50, 15, 22);
  B.Save('109 Industrie - Warmes Brummen im Takt');

  // ===== Hell, gestottert, Arps und Natur (Wasserfall) - viel Bewegung, Harmonie mal gebrochen =====
  B.Start('Helle_Flaeche_Cadd9.wav');
  B.P(gpGrainSize, 180); B.P(gpDensity, 40); B.P(gpSpray, 5); B.P(gpScan, 0.1); B.P(gpSpread, 95);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 15); B.P(gpSustain, 100); B.P(gpRelease, 1200);
  B.LfoSync(1, 2, SINUS);
  B.FreeSteps(1, 1, [0, -24, 0, 0, -24, 0, -24, 0, 0, 0, -24, 0, -24, -24, 0, -24]);   // gestottert, synkopisch
  B.M(msLfo1, gpVolume, 100);
  B.LfoSync(2, 0, SINUS); B.M(msLfo2, gpGrainSize, 25);                 // Koernung atmet ueber 4 Takte
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 28);
  B.Eq(130, 0, -2, 1.5, 3);
  B.Hall(70, 3.5, 35, 20, 28);
  B.P(gpVolume, 6);
  B.Save('112 Hell - Gestotterte Lichtflaeche (Gate)');

  B.Start('Wasserfall.wav');
  B.P(gpKeyTrack, 0); B.P(gpGrainSize, 220); B.P(gpDensity, 34); B.P(gpSpray, 20); B.P(gpScan, 0.3);
  B.P(gpSpread, 100); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 3000); B.P(gpFltContour, 50);
  B.P(gpFlt2On, 1); B.P(gpFltRouting, 1); B.P(gpFlt2Type, 1); B.P(gpFlt2Cutoff, 900); B.P(gpFlt2Reso, 55); B.P(gpFlt2Contour, 100);
  B.LfoFree(1, 0.07, DREIECK); B.M(msLfo1, gpFlt2Cutoff, 35);           // Bandpass wandert durchs Rauschen
  B.LfoFree(2, 0.05, SINUS); B.M(msLfo2, gpPan, 35);
  B.Eq(60, 0, -1, 0, 2);
  B.Hall(95, 8, 40, 30, 45);
  B.P(gpVolume, 7);
  B.Save('113 Wasserfall - Rauschende Weite (Flaeche)');

  B.Start('Helle_Flaeche_Cadd9.wav');
  B.P(gpGrainSize, 240); B.P(gpDensity, 32); B.P(gpSpray, 10); B.P(gpScan, 0.08); B.P(gpSpread, 100);
  B.P(gpWindow, W_GAUSS); B.P(gpAttack, 900); B.P(gpSustain, 100); B.P(gpRelease, 5000);
  B.LfoFree(1, 0.06, SINUS); B.M(msLfo1, gpGrainSize, 30);               // atmet in der Koernung
  B.LfoFree(2, 0.13, DREIECK); B.M(msLfo2, gpSpray, 25);
  B.M(msModWheel, gpFreeze, 100);                                          // Modrad hoch = einfrieren
  B.M(msVelocity, gpFltCutoff, 30);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 4000); B.P(gpFltContour, 60);
  B.Eq(120, 0, -2, 1, 4);
  B.Hall(95, 9, 30, 40, 48);
  B.P(gpVolume, 3);
  B.Save('116 Dynamik - Atmende Lichtflaeche (Modrad friert ein)');

  B.Start('Dschungel_Voegel.wav');                                    // B: Dschungel (Schicht)
  B.P(gpKeyTrack, 1); B.Shared(80, 55, 4, 0.6, 80, 30, 2, 450, 30, 700);
  B.Hall(75, 4, 35, 20, 30);
  B.StoreMorphAndSwitch('Vibraphon_C4.wav');                          // A: Vibraphon-Arp
  B.Arp(6, 1, 3, 45, 10, 'x..x..x...x.x...');                             // Akkord-Rhythmus
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 25);
  B.P(gpMorph, 28);
  B.LfoSync(1, 1, SINUS); B.M(msLfo1, gpPan, 25);
  B.Eq(140, 0, -1.5, 1, 2.5);
  B.P(gpVolume, 7);
  B.Save('117 Arp - Vibraphon im Dschungel (Arp)');

  // ===== Filmmusik-Stil (eigene Motive, kein Zitat): Kirchenorgel, tickendes Ostinato, Weite =====
  B.Start('Kirchenorgel_C3.wav');
  B.Shared(140, 45, 2, 0.3, 80, 30, 60, 2000, 100, 2500);
  B.LfoSync(1, D_1_1, SINUS); B.FreeSteps(1, 0, [0, 12, 7, 12, 0, 12, 7, 12, 0, 12, 8, 12, 0, 12, 8, 12]);
  B.PitchFromFree(1);                                                     // eigenes, tickendes Ostinato
  B.P(gpLfo1Trig, 0);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2200); B.P(gpFltContour, 40);
  B.LfoFree(2, 0.03, SINUS); B.M(msLfo2, gpFltCutoff, 35);                // ueber ~30 s anschwellen
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 15);
  B.Eq(60, 1, -2, 0.5, 2);
  B.Hall(100, 9, 30, 45, 45);
  B.P(gpVolume, -5);
  B.Save('121 Weltraum-Orgel - Tickendes Ostinato (Arp)');

  B.Start('Violine_C5.wav');                                          // B: Streicher-Flaeche
  B.Shared(240, 34, 6, 0.05, 100, 40, 1500, 3000, 100, 5000);
  B.Hall(100, 10, 30, 45, 48);
  B.StoreMorphAndSwitch('Kirchenorgel_C3.wav');                       // A: Orgel-Flaeche
  B.Shared(260, 30, 4, 0.04, 90, 40, 1800, 3000, 100, 5000);
  B.P(gpMorph, 40); B.MorphLfo(0, 0.025, 60);                            // Orgel und Streicher atmen ineinander
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 2); B.P(gpOscLevel, 35);   // Sinus-Sub, eine Oktave tiefer
  B.P(gpOscAttack, 2500); B.P(gpOscSustain, 100); B.P(gpOscRelease, 5000);
  B.LfoFree(1, 0.04, SINUS); B.M(msLfo1, gpVolume, 30);                  // grosse Dynamikwelle
  B.Eq(30, 2, -1.5, 0.5, 2.5);
  B.P(gpVolume, -5);
  B.Save('122 Orgel und Streicher - Anschwellende Weite (Morph-Flaeche)');

  // ===== Techno: sauber rumsende Kick (Oszillator, FM-Punch per Huellkurve) + harmonische Flaeche =====
  // ===== Rauschen als Hi-Hat: Oszillator "Weisses Rauschen" mit kurzer Huellkurve, vom Arp angeschlagen.

  // ===== Drei Oszillatoren =====
  // 128: drei leicht gegeneinander verstimmte Saegezaehne (Supersaw), darunter leise die Grain-Flaeche
  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 30); B.P(gpSpray, 12); B.P(gpSpread, 80); B.P(gpGrainLevel, -12);
  B.P(gpAttack, 600); B.P(gpSustain, 85); B.P(gpRelease, 1800);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscLevel, 42);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Level, 40); B.P(gpOsc2Fine, 14); B.P(gpOsc2Pan, 45);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 2); B.P(gpOsc3Level, 40); B.P(gpOsc3Fine, -14); B.P(gpOsc3Pan, -45);
  B.P(gpOscAttack, 500); B.P(gpOscDecay, 2000); B.P(gpOscSustain, 85); B.P(gpOscRelease, 1600);
  B.P(gpOsc2Attack, 500); B.P(gpOsc2Decay, 2000); B.P(gpOsc2Sustain, 85); B.P(gpOsc2Release, 1600);
  B.P(gpOsc3Attack, 500); B.P(gpOsc3Decay, 2000); B.P(gpOsc3Sustain, 85); B.P(gpOsc3Release, 1600);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1500); B.P(gpFltReso, 18); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 30); B.P(gpFltAttack, 1400); B.P(gpFltDecay, 3000); B.P(gpFltSustain, 40); B.P(gpFltRelease, 1800);
  B.LfoFree(1, 0.12, SINUS); B.M(msLfo1, gpFltCutoff, 7);                        // Filter atmet langsam
  B.P(gpWidth, 140);
  B.Hall(88, 5, 40, 25, 32);
  B.Save('128 Analog - Drei Saegen als breite Flaeche');

  // 129: Bass aus Saege + Rechteck (eine Oktave tiefer) und Sinus-Sub, Filter-Punch, gleitet legato
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 2); B.P(gpOscLevel, 60);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 3); B.P(gpOsc2Oct, 2); B.P(gpOsc2Fine, 6); B.P(gpOsc2Level, 42);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 60);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 500); B.P(gpOscSustain, 70); B.P(gpOscRelease, 120);
  B.P(gpOsc2Attack, 2); B.P(gpOsc2Decay, 500); B.P(gpOsc2Sustain, 70); B.P(gpOsc2Release, 120);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Decay, 800); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 120);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 420); B.P(gpFltReso, 35); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 55); B.P(gpFltAttack, 1); B.P(gpFltDecay, 320); B.P(gpFltSustain, 20); B.P(gpFltRelease, 150);
  B.M(msVelocity, gpFltEnvAmt, 20);                                               // fester Anschlag = mehr Biss (je Note)
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 70);
  B.P(gpDrive, 18);
  B.Save('129 Analog-Bass - Saege, Rechteck und Sub (Glide)');

  // 130: FM-Glocke mit eigener Klangfarben-Huellkurve, hohe FM-Obertoene, Sinus-Schimmer, Glas-Grains
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 120); B.P(gpDensity, 18); B.P(gpSpray, 10); B.P(gpSpread, 90); B.P(gpGrainLevel, -9);
  B.P(gpAttack, 5); B.P(gpDecay, 2500); B.P(gpSustain, 20); B.P(gpRelease, 2500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 45); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 2600); B.P(gpOscSustain, 0); B.P(gpOscRelease, 2600);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 600); B.P(gpOscFmSustain, 10); B.P(gpOscFmRelease, 900);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 4); B.P(gpOsc2FmRatio, 7); B.P(gpOsc2FmAmt, 30);
  B.P(gpOsc2Level, 24); B.P(gpOsc2Pan, 35);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 1200); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 1500);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 4); B.P(gpOsc3Fine, 6); B.P(gpOsc3Level, 18); B.P(gpOsc3Pan, -35);
  B.P(gpOsc3Attack, 400); B.P(gpOsc3Decay, 3000); B.P(gpOsc3Sustain, 30); B.P(gpOsc3Release, 3000);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 30); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 14);
  B.Hall(88, 6, 35, 30, 34);
  B.P(gpVolume, 3);
  B.Save('130 FM-Glocken mit Schimmer');

  // 131: Orgel aus drei Fusslagen (Grundton, Oktave, Doppeloktave), Vibrato und kreisendes Leslie
  B.Start('Kirchenorgel_C3.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscLevel, 62);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 4); B.P(gpOsc2Level, 42);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 1); B.P(gpOsc3Oct, 5); B.P(gpOsc3Level, 24);
  B.P(gpOscAttack, 8); B.P(gpOscDecay, 50); B.P(gpOscSustain, 100); B.P(gpOscRelease, 90);
  B.P(gpOsc2Attack, 8); B.P(gpOsc2Decay, 50); B.P(gpOsc2Sustain, 100); B.P(gpOsc2Release, 90);
  B.P(gpOsc3Attack, 8); B.P(gpOsc3Decay, 50); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 90);
  B.LfoFree(1, 6.2, SINUS);                                                       // Vibrato
  B.M(msLfo1, gpOscFine, 3); B.M(msLfo1, gpOsc2Fine, 3); B.M(msLfo1, gpOsc3Fine, 3);
  B.LfoFree(2, 0.9, SINUS); B.M(msLfo2, gpPan, 30);                                // Leslie kreist
  B.P(gpDrive, 22);
  B.Hall(65, 2.4, 40, 12, 20);
  B.Save('131 Orgel - Drei Fusslagen mit Leslie');

  // 132: Pluck aus Saege + Rechteck (Oktave hoeher) + Sub, Filter zupft, Arp mit Ping-Pong-Echo
  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscLevel, 58);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 3); B.P(gpOsc2Oct, 4); B.P(gpOsc2Level, 24); B.P(gpOsc2Pan, 30);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 36);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 280); B.P(gpOscSustain, 0); B.P(gpOscRelease, 220);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 200); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 200);
  B.P(gpOsc3Attack, 1); B.P(gpOsc3Decay, 420); B.P(gpOsc3Sustain, 0); B.P(gpOsc3Release, 260);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 700); B.P(gpFltReso, 42); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 60); B.P(gpFltAttack, 1); B.P(gpFltDecay, 230); B.P(gpFltSustain, 0); B.P(gpFltRelease, 200);
  B.M(msVelocity, gpFltCutoff, 12);
  B.Arp(0, 2, 3, 60, 8, 'xxxxxxxx');                                             // hoch, 2 Oktaven, 1/16
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 38); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 24);
  B.Hall(60, 2.5, 45, 15, 18);
  B.P(gpVolume, 6); B.P(gpOscLevel, 72); B.P(gpOsc3Level, 46);
  B.Save('132 Pluck-Arp - Saege, Rechteck und Sub (Echo)');

  // 133: Hybrid - Chor-Grains, darunter zwei weich gefilterte Saegezaehne (je eigener Filter) als Waerme
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 260); B.P(gpDensity, 32); B.P(gpSpray, 14); B.P(gpScan, 0.25); B.P(gpSpread, 85);
  B.P(gpPitchRand, 0.08); B.P(gpWindow, W_GAUSS);
  B.P(gpAttack, 900); B.P(gpDecay, 1500); B.P(gpSustain, 85); B.P(gpRelease, 2400);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscFine, -8); B.P(gpOscLevel, 34); B.P(gpOscPan, -30);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Fine, 8); B.P(gpOsc2Level, 34); B.P(gpOsc2Pan, 30);
  B.P(gpOscAttack, 1100); B.P(gpOscDecay, 2000); B.P(gpOscSustain, 90); B.P(gpOscRelease, 2200);
  B.P(gpOsc2Attack, 1100); B.P(gpOsc2Decay, 2000); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 2200);
  B.P(gpOscFltOn, 1); B.P(gpOscFltCutoff, 1100); B.P(gpOscFltReso, 10);
  B.P(gpOsc2FltOn, 1); B.P(gpOsc2FltCutoff, 1100); B.P(gpOsc2FltReso, 10);
  B.Hall(85, 5, 40, 25, 34);
  B.P(gpVolume, 3);
  B.Save('133 Hybrid - Chor ueber warmen Saegen');

  // 134: Lead mit Hard Sync (Klangfarbe wandert per LFO), zweite Saege verstimmt, Rechteck eine Oktave tiefer
  B.Start('Trompete_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscSync, 35); B.P(gpOscLevel, 52);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Fine, 9); B.P(gpOsc2Level, 34);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 3); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 26);
  B.P(gpOscAttack, 6); B.P(gpOscDecay, 400); B.P(gpOscSustain, 90); B.P(gpOscRelease, 220);
  B.P(gpOsc2Attack, 6); B.P(gpOsc2Decay, 400); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 220);
  B.P(gpOsc3Attack, 6); B.P(gpOsc3Decay, 400); B.P(gpOsc3Sustain, 90); B.P(gpOsc3Release, 220);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 3200); B.P(gpFltReso, 22); B.P(gpFltContour, 100);
  B.LfoFree(1, 0.35, DREIECK); B.M(msLfo1, gpOscSync, 25);                       // Sync-Klangfarbe wandert
  B.LfoFree(2, 5.5, SINUS); B.M(msLfo2, gpOscFine, 2); B.M(msLfo2, gpOsc2Fine, 2);  // dezentes Vibrato
  B.P(gpGlideMode, 1); B.P(gpGlideTime, 80);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 14);
  B.Hall(60, 2.2, 40, 15, 16);
  B.Save('134 Sync-Lead - schneidend und gleitend');

  // ===== FM: nur Oszillatoren (keine Grains) =====
  // 135: E-Piano - FM 1:1 mit kurzer heller Klangfarben-Huellkurve (Anschlag), Tine-Glanz eine Oktave
  // hoeher (FM 7, sehr kurz), fester Anschlag = hellerer Ton je Note, sanftes Tremolo
  B.Start('Rhodes_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 38); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 2800); B.P(gpOscSustain, 25); B.P(gpOscRelease, 450);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 420); B.P(gpOscFmSustain, 15); B.P(gpOscFmRelease, 300);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 4); B.P(gpOsc2FmRatio, 7); B.P(gpOsc2FmAmt, 25); B.P(gpOsc2Level, 22);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 260); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 200);
  B.M(msVelocity, gpOscFmAmt, 30);                                               // fester = heller (je Note)
  B.M(msVelocity, gpOsc2Level, 12);
  B.LfoFree(1, 4.5, SINUS); B.M(msLfo1, gpOscLevel, 6); B.M(msLfo1, gpOscPan, 12);   // Tremolo, leichtes Wandern
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 20); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 10);
  B.Hall(60, 2.2, 40, 12, 18);
  B.Save('135 FM - E-Piano mit Tine und Tremolo');

  // 136: LFO-Kette - LFO 2 (sehr langsam) veraendert das Tempo von LFO 1, LFO 1 (Saege) duckt
  // Oszillator 2: das Pumpen wird mal schneller, mal langsamer. Darueber eine ruhige FM-Flaeche.
  B.Start('pad_akkord.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 22); B.P(gpOscLevel, 55);
  B.P(gpOscAttack, 900); B.P(gpOscDecay, 2000); B.P(gpOscSustain, 85); B.P(gpOscRelease, 2200);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 4); B.P(gpOsc2FmRatio, 3); B.P(gpOsc2FmAmt, 35);
  B.P(gpOsc2Level, 90); B.P(gpOsc2Fine, 5);
  B.P(gpOsc2Attack, 20); B.P(gpOsc2Decay, 1000); B.P(gpOsc2Sustain, 100); B.P(gpOsc2Release, 1500);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 40);
  B.P(gpOsc3Attack, 600); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 2000);
  B.LfoFree(1, 3, SAEGE);   B.M(msLfo1, gpOsc2Level, 45);                       // duckt Osz 2 (Pumpen)
  B.LfoFree(2, 0.05, SINUS); B.M(msLfo2, gpLfo1Rate, 22);                        // ... dessen Tempo wandert langsam
  B.M(msLfo2, gpOscFmAmt, 12);                                                    // und die Flaeche wird mit heller
  B.P(gpWidth, 130);
  B.Hall(85, 5, 40, 25, 30);
  B.P(gpVolume, -4);
  B.Save('136 FM - LFO-Kette - Pumpen mit wanderndem Tempo');

  // 137: FM-Bass - 1:1 mit kurzem Klangfarben-Biss, Sinus-Sub, gleitet legato
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 600); B.P(gpOscSustain, 75); B.P(gpOscRelease, 120);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 160); B.P(gpOscFmSustain, 20); B.P(gpOscFmRelease, 120);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 60);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 120);
  B.M(msVelocity, gpOscFmAmt, 25);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 60);
  B.P(gpDrive, 15);
  B.Save('137 FM - Bass mit Biss (Glide)');

  // 138: Marimba - FM 4:1, sehr kurze Klangfarbe, Holz-Anschlag; zweiter Oszillator als Resonanzkoerper
  B.Start('Vibraphon_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 4); B.P(gpOscFmAmt, 40); B.P(gpOscLevel, 72);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 450); B.P(gpOscSustain, 0); B.P(gpOscRelease, 350);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 70); B.P(gpOscFmSustain, 0); B.P(gpOscFmRelease, 80);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 4); B.P(gpOsc2Level, 26);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 250); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 200);
  B.M(msVelocity, gpOscFmAmt, 25);
  B.Hall(55, 1.6, 45, 8, 16);
  B.P(gpVolume, 6); B.P(gpOscLevel, 95);
  B.Save('138 FM - Marimba');

  // 139: Blech - FM 1:1, Klangfarbe schwillt langsam AN (Attack 90 ms) wie beim Anblasen, Vibrato setzt spaet ein
  B.Start('Trompete_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 45); B.P(gpOscLevel, 62);
  B.P(gpOscAttack, 30); B.P(gpOscDecay, 600); B.P(gpOscSustain, 85); B.P(gpOscRelease, 180);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 90); B.P(gpOscFmDecay, 400); B.P(gpOscFmSustain, 70); B.P(gpOscFmRelease, 150);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 1); B.P(gpOsc2FmAmt, 40); B.P(gpOsc2Fine, 8); B.P(gpOsc2Level, 40);
  B.P(gpOsc2Attack, 40); B.P(gpOsc2Decay, 600); B.P(gpOsc2Sustain, 85); B.P(gpOsc2Release, 180);
  B.M(msVelocity, gpOscFmAmt, 25);
  // Vibrato je Note: LFO 3 startet mit jeder Note neu (jede Stimme schwingt fuer sich)
  B.P(gpLfo3Rate, 5.2); B.P(gpLfo3Shape, SINUS); B.P(gpLfo3Trig, 1);
  B.M(msLfo3, gpOscFine, 2); B.M(msLfo3, gpOsc2Fine, 2);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 18); B.P(gpEchoMix, 10);
  B.Hall(65, 2.4, 40, 15, 20);
  B.Save('139 FM - Blech mit anschwellender Klangfarbe');

  // 140: atmende Flaeche - zwei FM-Paare, LFO 3 (langsam) steuert das Tempo von LFO 4,
  // LFO 4 bewegt die FM-Menge beider Paare gegenlaeufig: die Flaeche atmet unregelmaessig
  B.Start('Helle_Flaeche_Cadd9.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 25); B.P(gpOscLevel, 50); B.P(gpOscPan, -40);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 3); B.P(gpOsc2FmAmt, 25); B.P(gpOsc2Fine, 7);
  B.P(gpOsc2Level, 48); B.P(gpOsc2Pan, 40);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 1); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 30);
  B.P(gpOscAttack, 1500); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 90); B.P(gpOscRelease, 3000);
  B.P(gpOsc2Attack, 1800); B.P(gpOsc2Decay, 3000); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 3200);
  B.P(gpOsc3Attack, 1200); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 3000);
  B.P(gpLfo3Rate, 0.04); B.P(gpLfo3Shape, SINUS);
  B.P(gpLfo4Rate, 0.3); B.P(gpLfo4Shape, DREIECK);
  B.M(msLfo3, gpLfo4Rate, 25);
  B.M(msLfo4, gpOscFmAmt, 20); B.M(msLfo4, gpOsc2FmAmt, -20);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 16);
  B.P(gpWidth, 140);
  B.Hall(92, 7, 35, 30, 38);
  B.Save('140 FM - Atmende Flaeche (LFO steuert LFO)');

  // 141: Wobble-Bass - LFO 1 im Takt (1/8) auf die FM-Menge, das Modrad beschleunigt den Wobble
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 0.5); B.P(gpOscFmAmt, 35); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 3); B.P(gpOscDecay, 800); B.P(gpOscSustain, 90); B.P(gpOscRelease, 140);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Oct, 2); B.P(gpOsc2Fine, -6); B.P(gpOsc2Level, 35);
  B.P(gpOsc2Attack, 3); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 140);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 55);
  B.P(gpOsc3Attack, 3); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 140);
  B.LfoSync(1, D_1_8, SINUS);
  B.M(msLfo1, gpOscFmAmt, 30);
  B.M(msModWheel, gpLfo1Rate, 25);                                                // Modrad = schnellerer Wobble
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1400); B.P(gpFltReso, 25); B.P(gpFltContour, 100);
  B.M(msLfo1, gpFltCutoff, 12);
  B.P(gpDrive, 25);
  B.Save('141 FM - Wobble-Bass (Modrad = Tempo)');

  // 142: Glocken-Arp - FM-Glocke im Arpeggiator, die Glocke wird mit jeder Note per Zufall
  // etwas anders gefaerbt (Zufall je Note -> FM-Menge), Ping-Pong-Echo
  B.Start('Glasglocken.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 35); B.P(gpOscLevel, 66);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 900); B.P(gpOscSustain, 0); B.P(gpOscRelease, 700);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 250); B.P(gpOscFmSustain, 10); B.P(gpOscFmRelease, 300);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 4); B.P(gpOsc2Level, 20);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 500); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 400);
  B.M(msNoteRandom, gpOscFmAmt, 25);
  B.M(msNoteRandom, gpOscPan, 60);                                                 // jede Glocke an anderer Stelle
  B.Arp(2, 2, 3, 70, 10, 'xx.xx.x.');                                             // hoch/runter, 2 Oktaven, 1/16
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 22);
  B.Hall(80, 4, 35, 20, 28);
  B.Save('142 FM - Glocken-Arp mit Zufallsfarbe');

  // ----- FM-Pads -----
  // 143: Glas-Pad - die Klangfarbe blueht langsam auf (FM-Attack laenger als die Lautstaerke),
  // zweites Paar eine Oktave hoeher, breit und verhallt
  B.Start('Helle_Flaeche_Cadd9.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 3); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 55); B.P(gpOscPan, -35);
  B.P(gpOscAttack, 700); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 85); B.P(gpOscRelease, 2800);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 2500); B.P(gpOscFmDecay, 3000); B.P(gpOscFmSustain, 60); B.P(gpOscFmRelease, 2500);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 4); B.P(gpOsc2FmRatio, 2); B.P(gpOsc2FmAmt, 20);
  B.P(gpOsc2Fine, 6); B.P(gpOsc2Level, 30); B.P(gpOsc2Pan, 35);
  B.P(gpOsc2Attack, 1500); B.P(gpOsc2Decay, 3000); B.P(gpOsc2Sustain, 80); B.P(gpOsc2Release, 3000);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 30); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 14);
  B.P(gpWidth, 140);
  B.Hall(90, 6, 35, 30, 36);
  B.Save('143 FM - Glas-Pad, die Farbe blueht auf');

  // 144: dunkles Pad - FM 0.5 (Unterton-Fundament), zwei verstimmte Paare schweben gegeneinander,
  // Tiefpass atmet langsam
  B.Start('pad_akkord.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 0.5); B.P(gpOscFmAmt, 28); B.P(gpOscLevel, 55);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 0.5); B.P(gpOsc2FmAmt, 28); B.P(gpOsc2Fine, 11); B.P(gpOsc2Level, 50);
  B.P(gpOsc2Pan, 40); B.P(gpOscPan, -40);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 35);
  B.P(gpOscAttack, 1200); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 90); B.P(gpOscRelease, 3000);
  B.P(gpOsc2Attack, 1400); B.P(gpOsc2Decay, 3000); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 3000);
  B.P(gpOsc3Attack, 1000); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 2500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1100); B.P(gpFltReso, 22); B.P(gpFltContour, 100);
  B.LfoFree(1, 0.07, SINUS); B.M(msLfo1, gpFltCutoff, 10);
  B.Hall(92, 7, 50, 30, 34);
  B.Save('144 FM - Dunkles Pad mit Schwebung');

  // 145: Chor-Pad - FM 2 mit Dreieck eine Oktave hoeher, jede Note bekommt ein eigenes, leicht
  // unterschiedliches Vibrato (LFO je Note, Rate per Zufall je Note)
  B.Start('Chor_Aah.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 18); B.P(gpOscLevel, 58);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 1); B.P(gpOsc2Oct, 4); B.P(gpOsc2Level, 22); B.P(gpOsc2Fine, -6);
  B.P(gpOscAttack, 600); B.P(gpOscDecay, 2000); B.P(gpOscSustain, 85); B.P(gpOscRelease, 1800);
  B.P(gpOsc2Attack, 900); B.P(gpOsc2Decay, 2000); B.P(gpOsc2Sustain, 80); B.P(gpOsc2Release, 1800);
  B.P(gpLfo3Rate, 4.8); B.P(gpLfo3Shape, SINUS); B.P(gpLfo3Trig, 1);
  B.M(msLfo3, gpOscFine, 2.5); B.M(msLfo3, gpOsc2Fine, 2.5);
  B.M(msNoteRandom, gpLfo3Rate, 8);                                                // jede Stimme schwingt etwas anders
  B.M(msNoteRandom, gpOscPan, 50);
  B.Hall(88, 5, 40, 25, 34);
  B.Save('145 FM - Chor-Pad, jede Stimme mit eigenem Vibrato');

  // 146: wandelndes Pad - LFO 3 oeffnet sehr langsam den Filter der Saege (dunkel <-> hell),
  // LFO 4 bewegt die FM-Menge in anderem Tempo: das Pad klingt nie zweimal gleich
  B.Start('Helle_Flaeche_Cadd9.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 55);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Level, 26); B.P(gpOsc2Fine, 7);
  B.P(gpOsc2FltOn, 1); B.P(gpOsc2FltCutoff, 900); B.P(gpOsc2FltReso, 15);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 2); B.P(gpOsc3Level, 30);
  B.P(gpOscAttack, 1500); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 90); B.P(gpOscRelease, 3000);
  B.P(gpOsc2Attack, 1800); B.P(gpOsc2Sustain, 90); B.P(gpOsc2Release, 3000);
  B.P(gpOsc3Attack, 1200); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 3000);
  B.P(gpLfo3Rate, 0.03); B.P(gpLfo3Shape, DREIECK); B.M(msLfo3, gpOsc2FltCutoff, 18);
  B.P(gpLfo4Rate, 0.11); B.P(gpLfo4Shape, SINUS); B.M(msLfo4, gpOscFmAmt, 15);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 15);
  B.P(gpWidth, 135);
  B.Hall(92, 7, 35, 30, 38);
  B.Save('146 FM - Wandelndes Pad, nie zweimal gleich');

  // ----- FM-Leads -----
  // 147: Lead mit Biss - FM 1:1, Klangfarbe mit kurzem Anschlag und mittlerem Halten, Velocity = Biss,
  // Vibrato je Note setzt mit jeder Note neu an, gleitet legato
  B.Start('Trompete_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 50); B.P(gpOscLevel, 66);
  B.P(gpOscAttack, 4); B.P(gpOscDecay, 500); B.P(gpOscSustain, 85); B.P(gpOscRelease, 200);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 300); B.P(gpOscFmSustain, 45); B.P(gpOscFmRelease, 200);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Fine, 7); B.P(gpOsc2Level, 30);
  B.P(gpOsc2Attack, 4); B.P(gpOsc2Sustain, 85); B.P(gpOsc2Release, 200);
  B.M(msVelocity, gpOscFmAmt, 30);
  B.P(gpLfo3Rate, 5.5); B.P(gpLfo3Shape, SINUS); B.P(gpLfo3Trig, 1);
  B.M(msLfo3, gpOscFine, 2); B.M(msLfo3, gpOsc2Fine, 2);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 90);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 25); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 14);
  B.Hall(60, 2.2, 40, 15, 16);
  B.Save('147 FM - Lead mit Biss (Glide)');

  // 148: Floeten-Lead - FM 1:1 sehr sanft, dazu leises Rauschen durch einen Bandpass als Atem,
  // der Atem kommt vor allem im Anschlag
  B.Start('Floete_C5.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 12); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 60); B.P(gpOscDecay, 800); B.P(gpOscSustain, 90); B.P(gpOscRelease, 260);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 5); B.P(gpOsc3Level, 18);
  B.P(gpOsc3Attack, 20); B.P(gpOsc3Decay, 250); B.P(gpOsc3Sustain, 35); B.P(gpOsc3Release, 200);
  B.P(gpOsc3FltOn, 1); B.P(gpOsc3FltType, F_BP); B.P(gpOsc3FltCutoff, 2400); B.P(gpOsc3FltReso, 40);
  B.P(gpLfo3Rate, 5); B.P(gpLfo3Shape, SINUS); B.P(gpLfo3Trig, 1);
  B.M(msLfo3, gpOscFine, 1.5); B.M(msLfo3, gpOscLevel, 3);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 60);
  B.Hall(70, 2.8, 40, 18, 24);
  B.Save('148 FM - Floeten-Lead mit Atem');

  // 149: kreischender Lead - FM 5,5 (unharmonisch, schneidend); Modrad und Aftertouch schaerfen,
  // Sinus eine Oktave tiefer haelt ihn zusammen
  B.Start('Trompete_C4.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 5.5); B.P(gpOscFmAmt, 25); B.P(gpOscLevel, 55);
  B.P(gpOscAttack, 5); B.P(gpOscDecay, 500); B.P(gpOscSustain, 90); B.P(gpOscRelease, 200);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 2); B.P(gpOsc2Level, 50);
  B.P(gpOsc2Attack, 5); B.P(gpOsc2Sustain, 100); B.P(gpOsc2Release, 200);
  B.M(msModWheel, gpOscFmAmt, 45);
  B.M(msAftertouch, gpOscFmAmt, 30);
  B.P(gpGlideMode, 1); B.P(gpGlideTime, 50);
  B.P(gpDrive, 20);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 22); B.P(gpEchoMix, 12);
  B.Hall(55, 2, 45, 12, 14);
  B.Save('149 FM - Kreisch-Lead (Modrad = schaerfer)');

  // 150: Pfeif-Lead - fast reiner Sinus mit Hauch FM, gleitet immer, Vibrato je Note, langes Echo
  B.Start('Floete_C5.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 6); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 40); B.P(gpOscDecay, 600); B.P(gpOscSustain, 90); B.P(gpOscRelease, 350);
  B.P(gpLfo3Rate, 6); B.P(gpLfo3Shape, SINUS); B.P(gpLfo3Trig, 1); B.M(msLfo3, gpOscFine, 2.5);
  B.P(gpGlideMode, 1); B.P(gpGlideTime, 140);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 45); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 22);
  B.Hall(80, 4, 35, 20, 28);
  B.Save('150 FM - Pfeif-Lead mit langem Echo');

  // ----- FM-Baesse -----
  // 151: Sub-Bass mit Klick - FM 1:1 nur fuer 25 ms (Klick im Anschlag), darunter reiner Sinus-Sub
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 60); B.P(gpOscLevel, 45);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 180); B.P(gpOscSustain, 30); B.P(gpOscRelease, 100);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 25); B.P(gpOscFmSustain, 0); B.P(gpOscFmRelease, 50);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 85);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Decay, 600); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 120);
  B.M(msVelocity, gpOscFmAmt, 25);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 40);
  B.P(gpVolume, -2);
  B.Save('151 FM - Sub-Bass mit Klick');

  // 152: Growl-Bass - FM 2, ein Noten-LFO (2 Hz) laesst die FM-Menge jeder Note knurren, Tiefpass mit Biss
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 40); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 3); B.P(gpOscDecay, 800); B.P(gpOscSustain, 90); B.P(gpOscRelease, 150);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 50);
  B.P(gpOsc3Attack, 3); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 150);
  B.LfoFree(1, 2.2, DREIECK); B.P(gpLfo1Trig, 1);
  B.M(msLfo1, gpOscFmAmt, 28);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 900); B.P(gpFltReso, 30); B.P(gpFltContour, 100);
  B.M(msLfo1, gpFltCutoff, 10);
  B.P(gpDrive, 30);
  B.P(gpVolume, -2);
  B.Save('152 FM - Growl-Bass');

  // 153: Slap-Bass - FM 3 sehr kurz und hart, Lautstaerke faellt schnell auf ein Plateau; fester Anschlag = Slap
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 3); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 75);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 320); B.P(gpOscSustain, 35); B.P(gpOscRelease, 120);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 90); B.P(gpOscFmSustain, 5); B.P(gpOscFmRelease, 80);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 2); B.P(gpOsc2FmRatio, 1); B.P(gpOsc2FmAmt, 15); B.P(gpOsc2Level, 45);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 500); B.P(gpOsc2Sustain, 60); B.P(gpOsc2Release, 120);
  B.M(msVelocity, gpOscFmAmt, 45);
  B.Hall(40, 1, 50, 5, 8);
  B.Save('153 FM - Slap-Bass (Anschlag = Slap)');

  // 154: Acid-Bass - FM 1:1 durch resonanten Tiefpass, kurze Filter-Huellkurve, gleitet legato,
  // fester Anschlag = Akzent (mehr Filter je Note)
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 55); B.P(gpOscLevel, 75);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 400); B.P(gpOscSustain, 80); B.P(gpOscRelease, 90);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 320); B.P(gpFltReso, 72); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 65); B.P(gpFltAttack, 1); B.P(gpFltDecay, 220); B.P(gpFltSustain, 10); B.P(gpFltRelease, 120);
  B.M(msVelocity, gpFltEnvAmt, 25);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 55);
  B.P(gpDrive, 35);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 10);
  B.P(gpVolume, -4);
  B.Save('154 FM - Acid-Bass (Anschlag = Akzent)');

  // ----- FM-Arps -----
  // 155: Kristall-Arp - FM 4 kurz gezupft, hoch/runter ueber 3 Oktaven in 1/16, Ping-Pong-Echo
  B.Start('Glasglocken.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 4); B.P(gpOscFmAmt, 32); B.P(gpOscLevel, 66);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 380); B.P(gpOscSustain, 0); B.P(gpOscRelease, 300);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 120); B.P(gpOscFmSustain, 10); B.P(gpOscFmRelease, 150);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 2); B.P(gpOsc2Level, 26);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 500); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 300);
  B.Arp(2, 3, 3, 55, 6, 'xxxxxxxxxxxxxxxx');
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 24);
  B.Hall(75, 3.5, 35, 18, 24);
  B.P(gpVolume, 3);
  B.Save('155 FM - Kristall-Arp');

  // 156: Bass-Arp - pulsiert im Achtel-Muster eine Oktave tief, Filter-Huellkurve zupft jede Note
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 45); B.P(gpOscLevel, 72);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 260); B.P(gpOscSustain, 20); B.P(gpOscRelease, 120);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 45);
  B.P(gpOsc3Attack, 1); B.P(gpOsc3Decay, 300); B.P(gpOsc3Sustain, 50); B.P(gpOsc3Release, 120);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 500); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 55); B.P(gpFltAttack, 1); B.P(gpFltDecay, 180); B.P(gpFltSustain, 5); B.P(gpFltRelease, 120);
  B.Arp(0, 2, 1, 70, 0, 'x.xxx.x.');                                               // hoch, 2 Oktaven, 1/8
  B.P(gpDrive, 20);
  B.P(gpVolume, 4);
  B.Save('156 FM - Pulsierender Bass-Arp');

  // 157: Triolen-Glocken - FM 3,5 im 1/16-Triolen-Arp, jede Glocke per Zufall an anderer Stelle im Raum
  B.Start('Glasglocken.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 66);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 700); B.P(gpOscSustain, 0); B.P(gpOscRelease, 600);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 200); B.P(gpOscFmSustain, 15); B.P(gpOscFmRelease, 300);
  B.M(msNoteRandom, gpOscPan, 70);
  B.M(msNoteRandom, gpOscFmAmt, 15);
  B.Arp(0, 2, 4, 60, 0, 'xxxxxx');                                                // hoch, 2 Oktaven, 1/16 Triole
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 18);
  B.Hall(85, 5, 35, 25, 32);
  B.P(gpVolume, 3);
  B.Save('157 FM - Triolen-Glocken (Arp)');

  // 158: Zufalls-Arp - Arp waehlt die Toene zufaellig, ein taktsynchroner LFO (1 Takt) dreht die
  // Klangfarbe von weich nach hell und zurueck
  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 25); B.P(gpOscLevel, 66);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 300); B.P(gpOscSustain, 0); B.P(gpOscRelease, 250);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Level, 24); B.P(gpOsc2Fine, 6);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 240); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 200);
  B.P(gpOsc2FltOn, 1); B.P(gpOsc2FltCutoff, 1600); B.P(gpOsc2FltReso, 30);
  B.LfoSync(1, D_1_1, SINUS);
  B.M(msLfo1, gpOscFmAmt, 25); B.M(msLfo1, gpOsc2FltCutoff, 15);
  B.Arp(4, 3, 3, 55, 12, 'xxx.xx.xxx.x.xx.');                                     // Zufall, 3 Oktaven, 1/16
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 20);
  B.Hall(70, 3, 40, 15, 22);
  B.P(gpVolume, 5);
  B.Save('158 FM - Zufalls-Arp mit wandernder Farbe');

  // 159: Geige - der Ton setzt glatt ein, nach einer halben Note beginnt das Vibrato (je Note,
  // Reiter Timing / Hüllk.: "Note an" um 1/2 verzoegert). LFO 1 laeuft dauerhaft, Neustart Note an.
  B.Start('Violine_C5.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpSpray, 4); B.P(gpScan, 0.4); B.P(gpSpread, 55);
  B.P(gpAttack, 90); B.P(gpDecay, 1500); B.P(gpSustain, 90); B.P(gpRelease, 600);
  B.LfoFree(1, 5.6, SINUS); B.P(gpLfo1Trig, 1);
  B.M(msLfo1, gpPitch, 0.45);                                                     // Vibrato ca. +-0,2 Halbtoene
  B.M(msLfo1, gpVolume, 1.5);                                                     // ... mit leichtem Bogendruck
  B.P(gpDlyOnSync, 4);                                                            // Note an um 1/2 verzoegert
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 60);
  B.Hall(80, 3.5, 40, 20, 26);
  B.Save('159 Geige - Vibrato setzt nach einer halben Note ein');

  // ===== 160-169: Hybride mit den physikalisch modellierten Instrumenten (Tools\make_instruments.py) =====
  // Grains spielen das Instrument im Originaltempo ab (Scan 1, kaum Streuung = natuerlich), die Oszillatoren
  // legen Glanz, Fundament oder Atem darunter; LFO-Start/Stopp und Verzoegerungen geben Ausdruck.

  // 160: Konzertgitarre - Grains spielen die Saite, ein weicher FM-Zupfer gibt Glanz; Vibrato kommt nach 1/2
  B.Start('Konzertgitarre_C3.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 60); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 35);
  B.P(gpAttack, 1); B.P(gpDecay, 3000); B.P(gpSustain, 100); B.P(gpRelease, 900);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 14); B.P(gpOscLevel, 22);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 900); B.P(gpOscSustain, 0); B.P(gpOscRelease, 400);
  B.LfoFree(1, 5.2, SINUS); B.P(gpLfo1Trig, 1); B.P(gpLfo1Stop, 2);
  B.M(msLfo1, gpPitch, 0.35);
  B.P(gpDlyOnSync, 4);                                                    // Vibrato erst nach 1/2
  B.M(msVelocity, gpOscFmAmt, 20);
  B.Eq(70, 0, -2, 1.5, 2);
  B.Hall(60, 2.2, 45, 15, 18);
  B.P(gpVolume, 6);
  B.Save('160 Grains + FM - Konzertgitarre mit Saitenglanz');

  // 161: Harfe im Sternenregen - Harfe als Grains, FM-Glocke dazu; beim Loslassen glitzert es einen Takt
  B.Start('Harfe_C4.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 55); B.P(gpSpray, 2); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 70);
  B.P(gpAttack, 1); B.P(gpDecay, 4000); B.P(gpSustain, 100); B.P(gpRelease, 2500);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 4); B.P(gpOsc2FmRatio, 3.5); B.P(gpOsc2FmAmt, 30); B.P(gpOsc2Level, 14);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 1600); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 1500);
  B.LfoSync(1, D_1_16, SH); B.P(gpLfo1Trig, 2);
  B.P(gpLfo1Stop, LFO_STOP_TIME); B.P(gpLfo1StopSync, 2);                // Glitzern einen Takt lang
  B.M(msLfo1, gpPitchRand, 50); B.M(msLfo1, gpPosition, 20);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 40); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 18);
  B.Hall(90, 6, 30, 30, 32);
  B.P(gpVolume, 10);
  B.Save('161 Grains + FM - Harfe im Sternenregen');

  // 162: Marimba-Ensemble - Holz als Grains, Sinus eine Oktave tiefer als Resonanzrohr, Velocity macht hell
  B.Start('Marimba_C4.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 65); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 50);
  B.P(gpAttack, 1); B.P(gpDecay, 2000); B.P(gpSustain, 100); B.P(gpRelease, 700);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 2); B.P(gpOscLevel, 30);
  B.P(gpOscAttack, 8); B.P(gpOscDecay, 900); B.P(gpOscSustain, 0); B.P(gpOscRelease, 400);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2500); B.P(gpFltContour, 60);
  B.M(msVelocity, gpFltCutoff, 30);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 22); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 14);
  B.Hall(55, 1.8, 40, 10, 16);
  B.Save('162 Grains + FM - Marimba-Ensemble');

  // 163: Roehrenglocken im Dom - Glocke als Grains, FM-Teilton (2,76) schwingt mit, grosser Raum
  B.Start('Roehrenglocke_C5.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpSpray, 2); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 80);
  B.P(gpAttack, 1); B.P(gpDecay, 6000); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2.76); B.P(gpOscFmAmt, 35); B.P(gpOscLevel, 16);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 3500); B.P(gpOscSustain, 0); B.P(gpOscRelease, 3000);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 600); B.P(gpOscFmSustain, 20); B.P(gpOscFmRelease, 2000);
  B.LfoFree(1, 0.12, SINUS); B.M(msLfo1, gpPan, 25);                      // die Glocke wandert leise im Raum
  B.Hall(100, 9, 35, 45, 40);
  B.P(gpVolume, 2);
  B.Save('163 Grains + FM - Roehrenglocken im Dom');

  // 164: Kalimba-Spieluhr - Arp in Sechzehnteln ueber zwei Oktaven, FM-Glanz, Ping-Pong
  B.Start('Kalimba_C5.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 60); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 60);
  B.P(gpAttack, 1); B.P(gpDecay, 1500); B.P(gpSustain, 100); B.P(gpRelease, 900);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 6.27); B.P(gpOscFmAmt, 12); B.P(gpOscLevel, 14);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 500); B.P(gpOscSustain, 0); B.P(gpOscRelease, 300);
  B.Arp(0, 2, 3, 70, 8, 'xxxx');
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 35); B.P(gpEchoPingPong, 1); B.P(gpEchoMix, 20);
  B.Hall(70, 3.5, 40, 20, 26);
  B.Save('164 Grains + FM - Kalimba-Spieluhr (Arp)');

  // 165: Steeldrum - Grains + kurzer FM-Zupfer (Oktave), leichtes Swing-Echo
  B.Start('Steeldrum_C4.wav');
  B.P(gpGrainSize, 80); B.P(gpDensity, 60); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 45);
  B.P(gpAttack, 1); B.P(gpDecay, 1800); B.P(gpSustain, 100); B.P(gpRelease, 800);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 18); B.P(gpOscLevel, 16);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 400); B.P(gpOscSustain, 0); B.P(gpOscRelease, 300);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 15);
  B.Hall(60, 2, 40, 12, 18);
  B.P(gpVolume, 3);
  B.Save('165 Grains + FM - Steeldrum am Strand');

  // 166: Klarinette mit Atem - Grains halten den Ton (langsames Scan), Rechteck-Osz. stuetzt die
  // ungeraden Obertoene, gefiltertes Rauschen = Atem; Vibrato nach 1/4, endet beim Loslassen
  B.Start('Klarinette_C4.wav');
  B.P(gpGrainSize, 140); B.P(gpDensity, 50); B.P(gpSpray, 6); B.P(gpScan, 0.15); B.P(gpPosition, 25); B.P(gpSpread, 30);
  B.P(gpAttack, 50); B.P(gpDecay, 500); B.P(gpSustain, 100); B.P(gpRelease, 300);
  B.P(gpOscOn, 1); B.P(gpOscWave, 3); B.P(gpOscLevel, 14);
  B.P(gpOscAttack, 60); B.P(gpOscSustain, 100); B.P(gpOscRelease, 250);
  B.P(gpOscFltOn, 1); B.P(gpOscFltType, F_TP); B.P(gpOscFltCutoff, 1500); B.P(gpOscFltReso, 10);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 5); B.P(gpOsc3Level, 5);
  B.P(gpOsc3Attack, 40); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 200);
  B.P(gpOsc3FltOn, 1); B.P(gpOsc3FltType, F_BP); B.P(gpOsc3FltCutoff, 2200); B.P(gpOsc3FltReso, 30);
  B.LfoFree(1, 5, SINUS); B.P(gpLfo1Trig, 1); B.P(gpLfo1Stop, 2);
  B.M(msLfo1, gpPitch, 0.3); B.M(msLfo1, gpVolume, 1.2);
  B.P(gpDlyOnSync, 7);                                                    // Vibrato nach 1/4
  B.M(msVelocity, gpOscFltCutoff, 25);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 50);
  B.Hall(65, 2.5, 40, 15, 20);
  B.P(gpVolume, -5);
  B.Save('166 Grains + FM - Klarinette mit Atem');

  // 167: Kontrabass pizzicato mit Sub - Grains spielen den Zupfer, Sinus darunter, kurzer FM-Klick
  B.Start('Kontrabass_Pizzicato_C2.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 55); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 15);
  B.P(gpAttack, 1); B.P(gpDecay, 1500); B.P(gpSustain, 100); B.P(gpRelease, 400);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 2); B.P(gpOscLevel, 40);
  B.P(gpOscAttack, 3); B.P(gpOscDecay, 800); B.P(gpOscSustain, 20); B.P(gpOscRelease, 250);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 1); B.P(gpOsc2FmAmt, 30); B.P(gpOsc2Level, 12);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 80); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 60);
  B.Eq(30, 3, -3, 1, 0);
  B.Hall(40, 1.4, 50, 8, 10);
  B.P(gpVolume, 5);
  B.Save('167 Grains + FM - Kontrabass pizzicato mit Sub');

  // 168: Doppel - B: Klarinettenflaeche, A: Harfe; beide klingen zusammen (Morph 45 %)
  B.Start('Klarinette_C4.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 35); B.P(gpSpray, 12); B.P(gpScan, 0.08); B.P(gpPosition, 30); B.P(gpSpread, 85);
  B.P(gpPitchRand, 0.05); B.P(gpWindow, W_GAUSS); B.P(gpAttack, 700); B.P(gpSustain, 100); B.P(gpRelease, 2500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 2); B.P(gpOscLevel, 18); B.P(gpOscAttack, 800); B.P(gpOscSustain, 100); B.P(gpOscRelease, 2500);
  B.Hall(90, 6, 40, 30, 36);
  B.StoreMorphAndSwitch('Harfe_C4.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 55); B.P(gpSpray, 2); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 60);
  B.P(gpPitchRand, 0); B.P(gpWindow, W_HANN); B.P(gpAttack, 1); B.P(gpDecay, 4000); B.P(gpSustain, 100); B.P(gpRelease, 2500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 4); B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 25); B.P(gpOscLevel, 10);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 1200); B.P(gpOscSustain, 0); B.P(gpOscRelease, 1200);
  B.Hall(85, 5, 35, 25, 28);
  B.P(gpMorph, 45);
  B.Save('168 Grains + FM - Harfe ueber Klarinettenflaeche (Doppel)');

  // 169: Doppel - Marimba (A) wird langsam zur Roehrenglocke (B) und zurueck (Morph-LFO, 4 Takte)
  B.Start('Roehrenglocke_C5.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpSpray, 2); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 85);
  B.P(gpAttack, 1); B.P(gpDecay, 6000); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2.76); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 12);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 3000); B.P(gpOscSustain, 0); B.P(gpOscRelease, 2500);
  B.Hall(100, 8, 35, 40, 38);
  B.StoreMorphAndSwitch('Marimba_C4.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 65); B.P(gpSpray, 1); B.P(gpScan, 1); B.P(gpPosition, 0); B.P(gpSpread, 50);
  B.P(gpAttack, 1); B.P(gpDecay, 2000); B.P(gpSustain, 100); B.P(gpRelease, 700);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 2); B.P(gpOscFmAmt, 0); B.P(gpOscLevel, 28);
  B.P(gpOscAttack, 8); B.P(gpOscDecay, 900); B.P(gpOscSustain, 0); B.P(gpOscRelease, 400);
  B.Hall(55, 1.8, 40, 10, 16);
  B.P(gpMorph, 0); B.MorphLfoSync(1, D_1_1, 100);
  B.Save('169 Grains + FM - Marimba wird Roehrenglocke (Doppel)');

  // --- Feedback-Resampling (Nov. 2026): der eigene Klang wird Durchlauf fuer Durchlauf zur Grain-Quelle ---

  // 170: Klavier zerfliesst - jeder Durchlauf mischt 60 % des Gespielten (mit Hall) ins Sample
  B.Start('Klavier_C4.wav');
  B.P(gpGrainSize, 260); B.P(gpDensity, 30); B.P(gpSpray, 6); B.P(gpScan, 0.15); B.P(gpSpread, 80);
  B.P(gpWindow, W_GAUSS); B.P(gpAttack, 600); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.Hall(85, 5, 40, 25, 30);
  B.Eq(120, 0, -2, 0, 1);
  B.P(gpResOn, 1); B.P(gpResMix, 60); B.P(gpResSync, 3);
  B.Save('170 Grains - Resampling - Klavier zerfliesst zur Flaeche');

  // 171: Chor wird endloser Nebel - wenig Anteil neu, das Original verschwindet langsam
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 320); B.P(gpDensity, 28); B.P(gpSpray, 10); B.P(gpScan, 0.05); B.P(gpPosition, 30); B.P(gpSpread, 90);
  B.P(gpWindow, W_GAUSS); B.P(gpAttack, 1200); B.P(gpSustain, 100); B.P(gpRelease, 4000);
  B.LfoFree(1, 0.05, SINUS); B.M(msLfo1, gpPosition, 15);
  B.Hall(100, 8, 45, 30, 40);
  B.Eq(150, 0, -2, -1, 2);
  B.P(gpResOn, 1); B.P(gpResMix, 35); B.P(gpResTime, 1500);
  B.Save('171 Grains - Resampling - Chor wird endloser Nebel');

  // 172: Glocken verwischen - das Echo wandert mit in die Aufnahme und baut eine Wolke
  B.Start('Roehrenglocke_C5.wav');
  B.P(gpGrainSize, 180); B.P(gpDensity, 40); B.P(gpSpray, 3); B.P(gpScan, 0.4); B.P(gpSpread, 85);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 10); B.P(gpSustain, 100); B.P(gpRelease, 3500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 45); B.P(gpEchoMix, 25);
  B.Hall(90, 6, 35, 30, 32);
  B.Eq(200, 0, -1, -1, 0);
  B.P(gpResOn, 1); B.P(gpResMix, 70); B.P(gpResSync, 2);
  B.Save('172 Grains - Resampling - Glocken verwischen mit Echo');

  // 173: Deep House - der Moll9-Stab wird zum warmen Teppich (Tiefpass, Pumpen)
  B.Start('Deep_Stab_Cm9.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 35); B.P(gpSpray, 8); B.P(gpScan, 0.1); B.P(gpSpread, 85);
  B.P(gpWindow, W_GAUSS); B.P(gpAttack, 400); B.P(gpSustain, 100); B.P(gpRelease, 2500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2500); B.P(gpFltReso, 10);
  B.Hall(80, 4, 50, 20, 28);
  B.Eq(140, 0, -3, 1, 1);
  B.P(gpResOn, 1); B.P(gpResMix, 50); B.P(gpResSync, 3);
  B.Save('173 Grains - Deep House - Resampling - Moll9-Stab wird Teppich');

  // 174: Stimme verdampft - 100 % neu: jeder Durchlauf ersetzt ganz, aus Worten wird Klang
  B.Start('Armstrong_Mondlandung.wav');
  B.P(gpGrainSize, 150); B.P(gpDensity, 45); B.P(gpSpray, 15); B.P(gpScan, 0.3); B.P(gpSpread, 75);
  B.P(gpWindow, W_HANN); B.P(gpAttack, 300); B.P(gpSustain, 100); B.P(gpRelease, 3000);
  B.Hall(95, 7, 40, 35, 38);
  B.Eq(160, 0, -2, 1, 1);
  B.P(gpResOn, 1); B.P(gpResMix, 100); B.P(gpResTime, 700);
  B.Save('174 Grains - Resampling - Stimme verdampft');

  // ----- FM + Drive fuer Techno (Oversampling haelt die Obertoene sauber) -----
  // 175: Rumble-Bass - FM 1:1 eine Oktave tief + Sinus-Sub, kraeftige Saettigung, dunkler Tiefpass,
  // kurzes 1/16-Echo und dunkler Hall geben das typische Techno-Grollen
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 38); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 600); B.P(gpOscSustain, 75); B.P(gpOscRelease, 180);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 260); B.P(gpOscFmSustain, 35); B.P(gpOscFmRelease, 150);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 55);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 180);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 700); B.P(gpFltReso, 25); B.P(gpFltContour, 100);
  B.P(gpDrive, 55);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_16); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 9);
  B.Hall(70, 3, 80, 0, 10);
  B.P(gpVolume, -5);
  B.Save('175 FM - Techno - Rumble-Bass mit Drive');

  // 176: Reese-Bass - FM 2 mit 5 Unison-Stimmen und Schwebung, Sinus-Sub, Tiefpass wandert langsam im
  // Takt (1 Takt), Saettigung macht ihn breit und dreckig
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 45); B.P(gpOscLevel, 65);
  B.P(gpOscAttack, 4); B.P(gpOscDecay, 800); B.P(gpOscSustain, 90); B.P(gpOscRelease, 220);
  B.P(gpOscUnison, 5); B.P(gpOscDetune, 22); B.P(gpOscUniWidth, 60);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 45);
  B.P(gpOsc3Attack, 4); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 220);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1100); B.P(gpFltReso, 30); B.P(gpFltContour, 100);
  B.LfoSync(1, D_1_1, SINUS);
  B.M(msLfo1, gpFltCutoff, 18);
  B.P(gpDrive, 50);
  B.Hall(50, 2, 70, 0, 8);
  B.P(gpVolume, -3);
  B.Save('176 FM - Techno - Reese-Bass, wandert im Takt');

  // 177: Industrial-Stab - harte FM 3.5 mit kurzer FM-Huellkurve (metallischer Anschlag), viel Drive,
  // etwas Crusher und ein grosser Hall: ein Akkordschlag fuer Peak-Time-Techno
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 65); B.P(gpOscLevel, 65);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 380); B.P(gpOscSustain, 0); B.P(gpOscRelease, 260);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 140); B.P(gpOscFmSustain, 10); B.P(gpOscFmRelease, 200);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2Oct, 2); B.P(gpOsc2FmRatio, 1); B.P(gpOsc2FmAmt, 30); B.P(gpOsc2Level, 45);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 420); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 260);
  B.M(msVelocity, gpOscFmAmt, 30);
  B.P(gpDrive, 70);
  B.P(gpCrushOn, 1); B.P(gpCrushBits, 10); B.P(gpCrushMix, 18);
  B.Hall(85, 4, 55, 15, 24);
  B.P(gpVolume, -4);
  B.Save('177 FM - Techno - Industrial-Stab (Anschlag = haerter)');

  // 178: Verzerrter Acid - FM 1:1 durch sehr resonanten Tiefpass mit kurzer Filter-Huellkurve, legato
  // gleitend, Drive vor dem Filter-Quietschen; fester Anschlag = Akzent
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 62); B.P(gpOscLevel, 75);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 300); B.P(gpOscSustain, 85); B.P(gpOscRelease, 80);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 260); B.P(gpFltReso, 82); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 70); B.P(gpFltAttack, 1); B.P(gpFltDecay, 180); B.P(gpFltSustain, 8); B.P(gpFltRelease, 100);
  B.M(msVelocity, gpFltEnvAmt, 30);
  B.P(gpGlideMode, 2); B.P(gpGlideTime, 60);
  B.P(gpDrive, 68);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 12);
  B.P(gpVolume, -7);
  B.Save('178 FM - Techno - Verzerrter Acid (Anschlag = Akzent)');

  // 179: Peitschen-Lead - FM 2 mit 3 Unison-Stimmen; das Modrad dreht Drive und FM-Menge zugleich auf,
  // vom runden Lead bis zur Kreissaege; 1/8-Echo
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 35); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 3); B.P(gpOscDecay, 500); B.P(gpOscSustain, 85); B.P(gpOscRelease, 200);
  B.P(gpOscUnison, 3); B.P(gpOscDetune, 14); B.P(gpOscUniWidth, 70);
  B.M(msModWheel, gpDrive, 55);
  B.M(msModWheel, gpOscFmAmt, 35);
  B.P(gpDrive, 25);
  B.P(gpGlideMode, 1); B.P(gpGlideTime, 40);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 28); B.P(gpEchoMix, 14);
  B.Hall(60, 2, 50, 10, 12);
  B.P(gpVolume, 1);
  B.Save('179 FM - Techno - Peitschen-Lead (Modrad = Drive)');

  // 180: Pump-Pad - weiche FM 2 mit langsamer FM-Huellkurve, das Trance-Gate in 1/16 laesst es im Takt
  // pumpen, leichter Drive und grosser Hall: Flaeche fuer den Breakdown
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 55);
  B.P(gpOscAttack, 250); B.P(gpOscDecay, 1500); B.P(gpOscSustain, 90); B.P(gpOscRelease, 1200);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1500); B.P(gpOscFmDecay, 2000); B.P(gpOscFmSustain, 70); B.P(gpOscFmRelease, 1200);
  B.P(gpOscUnison, 3); B.P(gpOscDetune, 12); B.P(gpOscUniWidth, 90);
  B.P(gpTgOn, 1); B.P(gpTgRate, 3); B.P(gpTgDepth, 80); B.P(gpTgSmooth, 8);
  B.P(gpDrive, 30);
  B.Hall(90, 6, 50, 20, 30);
  B.P(gpVolume, 0);
  B.Save('180 FM - Techno - Pump-Pad fuer den Breakdown');
end;

{ ------------------------------------------------------------------------------
  Lernpfad: jedes Preset zeigt genau EIN Prinzip der Matrix bzw. des Sidechains.
  Begleittext: Presets\LERNPFAD.txt (wird mit erzeugt).
  ------------------------------------------------------------------------------ }
procedure BuildLearning(B: TPresetBuilder);
begin
  // ---------- Teil 1: Matrix-Grundlagen ----------
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 180); B.P(gpDensity, 40); B.P(gpScan, 0); B.P(gpPosition, 50); B.P(gpSpray, 3);
  B.P(gpSpread, 60); B.P(gpAttack, 300); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.LfoFree(1, 0.1, SINUS);
  B.M(msLfo1, gpPosition, 45);                               // langsames Wandern durchs Sample
  B.Save('L01 Matrix - LFO wandert durchs Sample');

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 40); B.P(gpScan, 0.4); B.P(gpSpread, 50);
  B.P(gpAttack, 400); B.P(gpSustain, 100); B.P(gpRelease, 1800);
  B.LfoFree(1, 5, SINUS); B.LfoFree(2, 0.08, DREIECK);
  B.M(msLfo1, gpPitch, 0.8);                                 // Vibrato
  B.M(msLfo2, gpLfo1Rate, 45);                               // ... dessen Tempo langsam schwankt
  B.P(gpVolume, 6); B.P(gpGrainLevel, 6);  // Pegel angleichen (Analyse +12 dB)
  B.Save('L02 Matrix - LFO steuert LFO (Vibrato atmet)');

  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 45); B.P(gpScan, 1); B.P(gpSpread, 40);
  B.P(gpAttack, 3); B.P(gpDecay, 600); B.P(gpSustain, 40); B.P(gpRelease, 500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 500); B.P(gpFltReso, 35); B.P(gpFltContour, 100);
  B.M(msVelocity, gpFltCutoff, 70);                          // laut = hell
  B.M(msVelocity, gpGrainSize, -30);                         // laut = kuerzere, knackigere Grains
  B.P(gpVolume, 6); B.P(gpGrainLevel, 5);  // Pegel angleichen (Analyse +11 dB)
  B.Save('L03 Matrix - Anschlag macht hell');

  B.Start('E-Piano_Akkorde.wav');
  B.P(gpGrainSize, 150); B.P(gpDensity, 40); B.P(gpScan, 0.4); B.P(gpSpread, 50);
  B.P(gpAttack, 10); B.P(gpRelease, 1200);
  B.P(gpEchoOn, 1); B.P(gpEchoTime, 350); B.P(gpEchoFeedback, 45); B.P(gpEchoMix, 30);
  B.M(msNote, gpGrainSize, -80, MOD_FACTOR_DEFAULT, -50);    // tief = grosse Grains, hoch = kleine
  B.M(msNote, gpEchoTime, -60, MOD_FACTOR_DEFAULT, -50);     // hoch = kurzes Echo
  B.Save('L04 Matrix - Tonhoehe formt den Klang');

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpScan, 0.3); B.P(gpSpread, 50);
  B.P(gpAttack, 200); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 700); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.M(msModWheel, gpFltCutoff, 60);                          // Modrad oeffnet das Filter
  B.M(msModWheel, gpMacroMotion, 40);                        // ... und bringt Bewegung
  B.M(msModWheel, gpMacroSpace, 30);                         // ... und Raum
  B.Save('L05 Matrix - Modrad als Ausdrucksregler');

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 38); B.P(gpScan, 0.2); B.P(gpSpread, 70);
  B.P(gpAttack, 250); B.P(gpSustain, 100); B.P(gpRelease, 1800);
  B.M(msAftertouch, gpPitchRand, 50);                        // Druck = Chor faechert auf
  B.M(msAftertouch, gpSpray, 40);
  B.M(msPitchBend, gpEchoPitch, 60);                         // Pitchbend verbiegt nur das Echo
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 50); B.P(gpEchoMix, 30);
  B.P(gpVolume, 6); B.P(gpGrainLevel, 5);  // Pegel angleichen (Analyse +11 dB)
  B.Save('L06 Matrix - Aftertouch und Pitchbend');

  // ---------- Teil 2: Huellkurven und Trigger als Quellen ----------
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 100); B.P(gpDensity, 60); B.P(gpScan, 0.2); B.P(gpSpread, 80);
  B.P(gpAttack, 5); B.P(gpRelease, 2000);
  B.P(gpFltAttack, 5); B.P(gpFltDecay, 1500); B.P(gpFltSustain, 0); B.P(gpFltRelease, 800);
  B.M(msFilterEnv, gpSpray, 80);                             // Anschlag streut, dann zieht es sich zusammen
  B.M(msFilterEnv, gpPitchRand, 30);
  B.Save('L07 Huellkurve - Streuung verglueht');

  B.Start('E-Piano_Akkorde.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 40); B.P(gpScan, 0.3); B.P(gpSpread, 50);
  B.P(gpAttack, 5); B.P(gpSustain, 100); B.P(gpRelease, 2500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4T); B.P(gpEchoFeedback, 55); B.P(gpEchoMix, 70);
  B.M(msAmpEnv, gpEchoMix, -65);                             // solange die Note klingt: trocken,
  B.Save('L08 Huellkurve - Echo blueht im Release');        //   beim Loslassen blueht das Echo auf

  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 140); B.P(gpDensity, 50); B.P(gpScan, 0.4); B.P(gpSpread, 60);
  B.P(gpAttack, 10); B.P(gpSustain, 100); B.P(gpRelease, 800);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 400); B.P(gpFltReso, 60); B.P(gpFltContour, 100);
  B.LfoSync(1, D_1_1, SAEGE); B.P(gpLfo1Trig, 1);            // Saege, Neustart bei jeder Note
  B.M(msLfo1, gpFltCutoff, 45, MOD_FACTOR_DEFAULT, 100);     // Offset macht den Sweep einseitig
  B.Save('L09 Trigger - jede Note derselbe Filter-Sweep');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 120); B.P(gpDensity, 45); B.P(gpSpread, 70); B.P(gpAttack, 20); B.P(gpRelease, 2500);
  B.LfoFree(1, 0.6, SAEGE); B.P(gpLfo1Trig, 2);              // Neustart beim Loslassen
  B.M(msLfo1, gpPitch, -12, MOD_FACTOR_DEFAULT, 100);        // Ausklang faellt in der Tonhoehe
  B.P(gpEchoOn, 1); B.P(gpEchoTime, 300); B.P(gpEchoFeedback, 40); B.P(gpEchoMix, 25);
  B.Save('L10 Trigger - Ausklang faellt ab');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 55); B.P(gpSpread, 50); B.P(gpAttack, 2); B.P(gpDecay, 250);
  B.P(gpSustain, 30); B.P(gpRelease, 400);
  B.Arp(0, 2, 3, 50, 0, 'x.xxx.x.');                         // hoch, 2 Oktaven, Pausen im Muster
  B.Hall(60, 2.5, 35, 15, 25);
  B.P(gpVolume, 6); B.P(gpGrainLevel, 6);  // Pegel angleichen (Analyse +12 dB)
  B.Save('L11 Arp - Schrittmuster und Oktaven');

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 40); B.P(gpScan, 0.3); B.P(gpSpread, 50);
  B.P(gpAttack, 300); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.LfoFree(1, 0.25, SINUS);
  // bipolarer LFO -> mit Faktor x1/2 und Offset +50 % wird er einseitig (0..1)
  B.M(msLfo1, gpReverse, 100, 3, 50);
  B.M(msLfo1, gpSpread, 60, 3, 50);
  B.P(gpVolume, 6); B.P(gpGrainLevel, 6);  // Pegel angleichen (Analyse +12 dB)
  B.Save('L12 Faktor+Offset - LFO nur in eine Richtung');

  // ---------- Teil 3: Sidechain (Quelle unten im Host oder im DAW-Mixer zuweisen) ----------
  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 150); B.P(gpDensity, 50); B.P(gpScan, 0.3); B.P(gpSpread, 70);
  B.P(gpAttack, 100); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpScGain, 18); B.P(gpScAttack, 5); B.P(gpScRelease, 250);
  B.M(msSidechain, gpVolume, -45);                           // Signal am Sidechain duckt das Pad
  B.P(gpVolume, 4);  // Pegel angleichen (Analyse +4 dB)
  B.Save('L13 SC - Ducking (Pumpen)');

  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainSize, 70); B.P(gpDensity, 80); B.P(gpScan, 0.5); B.P(gpSpread, 50);
  B.P(gpAttack, 20); B.P(gpSustain, 100); B.P(gpRelease, 800);
  B.P(gpFltOn, 1); B.P(gpFltType, F_BP); B.P(gpFltCutoff, 350); B.P(gpFltReso, 75); B.P(gpFltContour, 100);
  B.P(gpScGain, 20); B.P(gpScAttack, 3); B.P(gpScRelease, 150);
  B.M(msSidechain, gpFltCutoff, 75);                         // Auto-Wah: Lautstaerke oeffnet das Filter
  B.P(gpVolume, 6);  // Pegel angleichen (Analyse +6 dB)
  B.Save('L14 SC - Auto-Wah per Stimme');

  B.Start('Gezupftes_Arpeggio.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 45); B.P(gpScan, 1); B.P(gpSpread, 30);
  B.P(gpAttack, 3); B.P(gpSustain, 100); B.P(gpRelease, 800);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 70); B.P(gpEchoDamp, 15); B.P(gpEchoMix, 45);
  B.M(msModWheel, gpEchoPitch, 50);                          // Modrad 0..100 % = Echo-Stufe 0..+12 Halbtoene
  B.Save('L15 Echo - Treppenstufe per Modrad');

  B.Start('vokale_aeiou.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 60); B.P(gpScan, 0); B.P(gpSpread, 40);
  B.P(gpAttack, 50); B.P(gpSustain, 100); B.P(gpRelease, 800);
  B.P(gpScGain, 22); B.P(gpScAttack, 20); B.P(gpScRelease, 300);
  B.M(msSidechain, gpPosition, 90);                          // Pegel scrubbt durch die Vokale a-e-i-o-u
  B.P(gpVolume, 6);  // Pegel angleichen (Analyse +6 dB)
  B.Save('L16 SC - Pegel spricht die Vokale');

  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 40); B.P(gpSpread, 80); B.P(gpAttack, 10); B.P(gpRelease, 1500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 20); B.P(gpEchoDamp, 40); B.P(gpEchoMix, 45);
  B.P(gpScGain, 18); B.P(gpScRelease, 600);
  B.M(msSidechain, gpEchoFeedback, 70);                      // Dub: nur bei Signal rueckkoppelt das Echo
  B.M(msSidechain, gpEchoPitch, 20);
  B.Save('L17 SC - Dub-Echo auf Zuruf');

  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 140); B.P(gpDensity, 50); B.P(gpScan, 0.15); B.P(gpSpread, 60);
  B.P(gpAttack, 40); B.P(gpSustain, 100); B.P(gpRelease, 900); B.P(gpKeyTrack, 0);
  // SC-Tonhoehe (0..1 = MIDI 0..127) -> Pitch (48 Halbtoene): Faktor x2,65, Offset -125 % = C4 neutral
  B.M(msScPitch, gpPitch, 100, 6, -125);
  B.M(msSidechain, gpVolume, 30);                            // mit Stimme lauter
  B.P(gpVolume, -8);                                         // ohne Stimme gut hoerbar (kein stummes Preset)
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 35); B.P(gpEchoMix, 20);
  B.P(gpVolume, -2);  // Pegel angleichen (Analyse +6 dB)
  B.Save('L18 SC - Chor folgt der Stimme (Matrix)');

  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 180); B.P(gpDensity, 45); B.P(gpScan, 0.2); B.P(gpSpread, 80);
  B.P(gpAttack, 60); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpScPitchMode, 2);                                     // Auto-Pitch in Halbtoenen
  B.P(gpPitch, 12);                                          // eine Oktave ueber der Stimme
  B.M(msSidechain, gpVolume, 30);                            // mit Stimme lauter
  B.P(gpVolume, 0);                                          // ohne Stimme gut hoerbar
  B.LfoFree(1, 5.5, SINUS); B.M(msLfo1, gpPitch, 0.5);
  B.P(gpVolume, 6);  // Pegel angleichen (Analyse +6 dB)
  B.Save('L19 SC - Streicher singen eine Oktave hoeher');

  // ---------- Finale: alles zusammen ----------
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 220); B.P(gpDensity, 45); B.P(gpScan, 0.25); B.P(gpSpread, 85);
  B.P(gpAttack, 600); B.P(gpSustain, 90); B.P(gpRelease, 3000); B.P(gpWindow, W_GAUSS);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1500); B.P(gpFltReso, 30); B.P(gpFltContour, 80);
  B.P(gpFltEnvAmt, 30); B.P(gpFltAttack, 2000); B.P(gpFltDecay, 3000); B.P(gpFltSustain, 50);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 50); B.P(gpEchoDamp, 55); B.P(gpEchoMix, 30);
  B.P(gpEchoPitch, 7);
  B.LfoFree(1, 0.07, SINUS); B.LfoFree(2, 0.31, DREIECK);
  B.M(msLfo1, gpPosition, 35);
  B.M(msLfo2, gpFltCutoff, 15);
  B.M(msLfo1, gpLfo2Rate, 40);
  B.M(msVelocity, gpGrainSize, -25);
  B.M(msModWheel, gpEchoMix, 50);
  B.M(msSidechain, gpPitchRand, 40);
  B.M(msAmpEnv, gpSpray, -30, MOD_FACTOR_DEFAULT, 50);
  B.M(msNoteRandom, gpSpread, 30);
  B.P(gpVolume, 6); B.P(gpGrainLevel, 1);  // Pegel angleichen (Analyse +7 dB)
  B.Save('L20 Finale - Klangreise (alles zusammen)');

  // ---------- Neue Funktionen: Sidechain-Trigger, Glide, FM-Huellkurve ----------
  // L21: lautes Signal am Sidechain startet einmalig eine Melodie (freier LFO -> Pitch)
  B.Start('Floete_C5.wav');
  B.P(gpGrainSize, 120); B.P(gpDensity, 45); B.P(gpSpread, 50); B.P(gpAttack, 30); B.P(gpSustain, 100); B.P(gpRelease, 900);
  B.LfoFree(1, 0.45, SINUS);
  B.FreeSteps(1, 0, [0, 2, 4, 7, 9, 7, 4, 0]);                       // due-due-due: Pentatonik hoch und zurueck
  B.PitchFromFree(1);                                                 // Matrix LFO 1 -> Pitch, Stufe = Halbton
  B.P(gpLfo1Trig, LFO_TRIG_SC_LEVEL); B.P(gpLfo1Once, 1);             // ... aber gestartet vom Sidechain, einmal
  B.P(gpScUseLevel, 1); B.P(gpScUsePitch, 0); B.P(gpScTrigLevel, 30);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 22);
  B.Hall(70, 3, 35, 20, 25);
  B.P(gpVolume, -5);  // Pegel angleichen (Analyse -5 dB)
  B.Save('L21 SC-Trigger - Laut ruft eine Melodie');

  // L22: Ton am Sidechain -> Dreiklang nacheinander, passend zum gesungenen Ton (Auto-Pitch)
  B.Start('Rhodes_C4.wav');
  B.P(gpGrainSize, 110); B.P(gpDensity, 45); B.P(gpSpread, 60); B.P(gpAttack, 10); B.P(gpSustain, 90); B.P(gpRelease, 1200);
  B.P(gpScPitchMode, 2);                                              // Grains folgen dem gesungenen Ton (Halbtoene)
  B.LfoFree(1, 0.6, SINUS);
  B.FreeSteps(1, 0, [0, 4, 7, 12, 7, 4, 0, 0]);                       // Dur-Dreiklang aufwaerts und zurueck
  B.PitchFromFree(1);
  B.P(gpLfo1Trig, LFO_TRIG_SC_LEVEL); B.P(gpLfo1Once, 1);
  B.P(gpScUseLevel, 0); B.P(gpScUsePitch, 1); B.P(gpScTrigNote, 55);  // jeder Ton ueber G3 loest aus
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 20);
  B.Hall(65, 2.5, 35, 15, 22);
  B.P(gpVolume, -4);  // Pegel angleichen (Analyse -4 dB)
  B.Save('L22 SC-Trigger - Gesungener Ton spielt seinen Dreiklang');

  // L23: beide Bedingungen - nur laut UND hoch oeffnet den Filter (einmaliger gezeichneter Zupfer)
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpSpread, 80); B.P(gpAttack, 80); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 450); B.P(gpFltReso, 45); B.P(gpFltContour, 100);
  B.LfoFree(2, 0.7, SINUS); B.FreeDraw(2, 0);                          // Zupfen: schnell auf, langsam zu
  B.M(msLfo2, gpFltCutoff, 55, MOD_FACTOR_DEFAULT, 100);
  B.P(gpLfo2Trig, LFO_TRIG_SC_LEVEL); B.P(gpLfo2Once, 1);
  B.P(gpScUseLevel, 1); B.P(gpScUsePitch, 1); B.P(gpScTrigLevel, 30); B.P(gpScTrigNote, 62);
  B.Hall(75, 4, 40, 20, 30);
  B.P(gpVolume, 6);  // Pegel angleichen (Analyse +6 dB)
  B.Save('L23 SC-Trigger - Nur laut UND hoch oeffnet den Filter');

  // L24: Portamento - die Floete gleitet von Ton zu Ton
  B.Start('Floete_C5.wav');
  B.P(gpGrainSize, 130); B.P(gpDensity, 50); B.P(gpSpread, 40); B.P(gpAttack, 40); B.P(gpSustain, 100); B.P(gpRelease, 700);
  B.P(gpGlideMode, 1); B.P(gpGlideTime, 280);                         // jede Note gleitet 0,28 s von der vorigen her
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 3); B.P(gpOscLevel, 35);   // Sinus (eine Oktave unter der Floete) gleitet mit
  B.P(gpOscAttack, 30); B.P(gpOscSustain, 90); B.P(gpOscRelease, 600);
  B.LfoFree(1, 5, SINUS); B.M(msLfo1, gpPitch, 0.4);                   // leichtes Vibrato
  B.Hall(70, 3, 35, 20, 25);
  B.P(gpVolume, -6);  // Pegel angleichen (Analyse -6 dB)
  B.Save('L24 Glide - Floete gleitet von Ton zu Ton');

  // L25: Oszillator FM mit eigener Huellkurve - Klangfarbe klingt aus, Lautstaerke bleibt
  B.Start('pad_akkord.wav');
  B.P(gpGrainSize, 200); B.P(gpDensity, 35); B.P(gpSpread, 90); B.P(gpAttack, 400); B.P(gpSustain, 100); B.P(gpRelease, 2000);
  B.P(gpVolume, -9);                                                   // Flaeche leise darunter
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscLevel, 130);
  B.P(gpOscFmRatio, 3.5); B.P(gpOscFmAmt, 70);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 1800); B.P(gpOscSustain, 40); B.P(gpOscRelease, 900);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 250); B.P(gpOscFmSustain, 10); B.P(gpOscFmRelease, 300);
  B.Hall(80, 4, 35, 25, 30);
  B.Save('L25 Oszillator - FM-Huellkurve macht die Glocke');

  // L26: Filter je Note - jede Note oeffnet ihr eigenes Filter (eigene Filter-Huellkurve, eigener
  // Noten-LFO, Velocity). Akkord nacheinander anschlagen: jede Stimme blueht einzeln auf.
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 180); B.P(gpDensity, 40); B.P(gpSpread, 70); B.P(gpAttack, 30); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 3); B.P(gpOscLevel, 70);      // Saege: viele Obertoene fuers Filter
  B.P(gpOscAttack, 20); B.P(gpOscSustain, 90); B.P(gpOscRelease, 1200);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 260); B.P(gpFltReso, 60); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 75); B.P(gpFltAttack, 1400); B.P(gpFltDecay, 2500); B.P(gpFltSustain, 35); B.P(gpFltRelease, 1500);
  B.LfoFree(1, 0.6, SINUS); B.P(gpLfo1Trig, 1); B.P(gpLfo1Once, 1);             // Noten-LFO: einmal je Anschlag
  B.M(msLfo1, gpFltCutoff, 18);                                                  // ... wiegt nur das eigene Filter
  B.M(msVelocity, gpFltReso, 25);                                                // fester Anschlag = mehr Resonanz (nur diese Note)
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 15);
  B.Hall(80, 4, 35, 25, 30);
  B.P(gpVolume, -3);
  B.Save('L26 Filter je Note - jede Stimme blueht einzeln auf');

  // ---------- Teil 4: Start, Stopp und Zeit (Reiter LFO 1-4 / Trigger und Timing / Hüllk.) ----------
  // Namen: "FM" = nutzt die Oszillatoren, "Grains" = nutzt die Grains

  // L27: Stopp "Note aus" - Vibrato je Note, beim Loslassen haelt der LFO an: der Ausklang ist ruhig
  B.Start('Floete_C5.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscLevel, 80);
  B.P(gpOscAttack, 40); B.P(gpOscDecay, 800); B.P(gpOscSustain, 85); B.P(gpOscRelease, 1800);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 2); B.P(gpOsc2FmAmt, 18); B.P(gpOsc2Level, 35);
  B.P(gpOsc2Attack, 60); B.P(gpOsc2Decay, 900); B.P(gpOsc2Sustain, 70); B.P(gpOsc2Release, 1800);
  B.LfoFree(1, 5.5, SINUS); B.P(gpLfo1Trig, 1); B.P(gpLfo1Stop, 2);       // Start Note an, Stopp Note aus
  B.M(msLfo1, gpPitch, 0.9);                                              // deutliches Vibrato
  B.Hall(75, 3.5, 35, 20, 30);
  B.P(gpVolume, -7);  // Pegel angleichen (Analyse -7 dB)
  B.Save('L27 FM - Stopp Note aus - Vibrato endet beim Loslassen');

  // L28: Stopp "nach Zeit" (Notenwert) - ein Wobble auf der FM-Menge laeuft nur eine halbe Note lang
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 90);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 600); B.P(gpOscSustain, 80); B.P(gpOscRelease, 250);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Oct, 1); B.P(gpOsc2Level, 60);   // Sinus-Fundament
  B.P(gpOsc2Attack, 2); B.P(gpOsc2Sustain, 100); B.P(gpOsc2Release, 250);
  B.LfoSync(1, D_1_16, RECHTECK); B.P(gpLfo1Trig, 1);
  B.P(gpLfo1Stop, LFO_STOP_TIME); B.P(gpLfo1StopSync, 4);                 // Stopp nach 1/2
  B.M(msLfo1, gpOscFmAmt, 30);
  B.P(gpVolume, -7);  // Pegel angleichen (Analyse -7 dB)
  B.Save('L28 FM - Stopp nach Zeit - Wobble nur eine halbe Note');

  // L29: Verzoegerter Start + Stopp nach Zeit - das Tremolo kommt nach 1/4 und geht nach 1/1 wieder
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 170); B.P(gpDensity, 40); B.P(gpSpread, 70); B.P(gpAttack, 150); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 3); B.P(gpOscLevel, 45); B.P(gpOscFine, 7);
  B.P(gpOscAttack, 150); B.P(gpOscSustain, 90); B.P(gpOscRelease, 1500);
  B.P(gpOscFltOn, 1); B.P(gpOscFltCutoff, 1800); B.P(gpOscFltReso, 20);
  B.LfoSync(1, D_1_16, SINUS); B.P(gpLfo1Trig, 1);
  B.P(gpDlyOnSync, 7);                                                    // Note an um 1/4 verzoegert
  B.P(gpLfo1Stop, LFO_STOP_TIME); B.P(gpLfo1StopSync, 2);                 // laeuft dann 1/1 lang
  B.M(msLfo1, gpVolume, 12);
  B.Hall(80, 4, 35, 25, 30);
  B.P(gpVolume, 3);
  B.Save('L29 FM + Grains - Tremolo kommt nach 1-4 und geht nach 1-1');

  // L30: Stopp nach Zeit in ms - ein Pitch-Sweep beim Anschlag, nach 120 ms Schluss (Laser-Pluck)
  B.Start('Glasglocken.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 3); B.P(gpOscFmAmt, 40); B.P(gpOscLevel, 80);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 700); B.P(gpOscSustain, 0); B.P(gpOscRelease, 500);
  B.LfoFree(1, 4, SAEGE); B.P(gpLfo1Trig, 1);
  B.P(gpLfo1Stop, LFO_STOP_TIME); B.P(gpLfo1StopMs, 120);                 // nur die ersten 120 ms
  B.M(msLfo1, gpPitch, -8);                                               // faellt beim Anschlag
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 30); B.P(gpEchoMix, 20);
  B.Hall(65, 2.5, 40, 15, 20);
  B.P(gpVolume, 6);
  B.Save('L30 FM - Stopp nach 120 ms - Pitch-Zip beim Anschlag');

  // L31: drei Oszillatoren, jeder mit eigener Huellkurve: Sinus schwillt an, FM zupft, Rauschen haucht
  B.Start('Floete_C5.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 900); B.P(gpOscSustain, 100); B.P(gpOscRelease, 1200);              // langsam
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 4); B.P(gpOsc2FmRatio, 3); B.P(gpOsc2FmAmt, 45); B.P(gpOsc2Level, 60);
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 350); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 300);  // Zupfer
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 5); B.P(gpOsc3Level, 18);
  B.P(gpOsc3Attack, 5); B.P(gpOsc3Decay, 120); B.P(gpOsc3Sustain, 0); B.P(gpOsc3Release, 100);  // Hauch
  B.P(gpOsc3FltOn, 1); B.P(gpOsc3FltType, F_BP); B.P(gpOsc3FltCutoff, 3000); B.P(gpOsc3FltReso, 40);
  B.Hall(75, 3, 35, 20, 28);
  B.Save('L31 FM - Drei Oszillatoren, drei Huellkurven');

  // L32: Huellkurve als Matrix-Quelle - die Huellkurve von Osz 2 (kurz) steuert die FM-Menge von Osz 1
  B.Start('E-Piano_Akkorde.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 5); B.P(gpOscLevel, 85);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 2500); B.P(gpOscSustain, 30); B.P(gpOscRelease, 600);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 0); B.P(gpOsc2Level, 0);                          // stumm: nur Huellkurve
  B.P(gpOsc2Attack, 1); B.P(gpOsc2Decay, 400); B.P(gpOsc2Sustain, 0); B.P(gpOsc2Release, 200);
  B.M(msOsc2Env, gpOscFmAmt, 60);                                                      // heller Anschlag, weich danach
  B.M(msVelocity, gpOscFmAmt, 20);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_4); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 15);
  B.Hall(70, 2.5, 40, 20, 22);
  B.Save('L32 FM - Osz2-Huellkurve als Quelle formt den Anschlag');

  // L33: Start "Note aus" + Stopp nach 1/1 - beim Loslassen glitzern die Grains einen Takt lang
  B.Start('Glasglocken.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 55); B.P(gpSpray, 10); B.P(gpSpread, 90); B.P(gpAttack, 20); B.P(gpSustain, 90); B.P(gpRelease, 2500);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 20); B.P(gpOscLevel, 50);
  B.P(gpOscAttack, 5); B.P(gpOscDecay, 900); B.P(gpOscSustain, 50); B.P(gpOscRelease, 1200);
  B.LfoSync(1, D_1_16, SH); B.P(gpLfo1Trig, 2);                                       // Neustart beim Loslassen
  B.P(gpLfo1Stop, LFO_STOP_TIME); B.P(gpLfo1StopSync, 2);                             // ... einen Takt lang
  B.M(msLfo1, gpPitchRand, 60);
  B.M(msLfo1, gpPosition, 25);
  B.Hall(85, 5, 30, 30, 34);
  B.Save('L33 FM + Grains - Loslassen glitzert einen Takt lang');

  // L34: LFO-Kette 1 -> 2 -> 3 ueber die Partner-Wahl. Note halten: Takt 1 oeffnet LFO 1 das Filter,
  // an seinem Ende laesst LFO 2 (Partner LFO 1) die FM-Menge an- und abschwellen, an dessen Ende LFO 3 (Partner LFO 2)
  // einen Schwenk durchs Panorama. Alle drei "Einmal"; LFO 2/3 warten (Stopp Note aus) auf ihren Start.
  B.Start('Floete_C5.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 10); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 10); B.P(gpOscSustain, 100); B.P(gpOscRelease, 600);
  B.P(gpOscFltOn, 1); B.P(gpOscFltType, F_TP); B.P(gpOscFltCutoff, 400); B.P(gpOscFltReso, 35);
  B.P(gpOsc2On, 1); B.P(gpOsc2Wave, 2); B.P(gpOsc2Oct, 2); B.P(gpOsc2Level, 30);
  B.P(gpOsc2Attack, 10); B.P(gpOsc2Sustain, 100); B.P(gpOsc2Release, 600);
  B.LfoSync(1, D_1_1, SAEGE); B.P(gpLfo1Trig, 1); B.P(gpLfo1Once, 1);          // Glied 1: Filter auf
  B.M(msLfo1, gpOscFltCutoff, 30);
  B.LfoSync(2, D_1_1, SINUS); B.P(gpLfo2Trig, LFO_TRIG_OTHER_END); B.P(gpLfo2Partner, 0);
  B.P(gpLfo2Once, 1); B.P(gpLfo2Stop, 2);                                         // Glied 2: FM schwillt an und ab
  B.M(msLfo2, gpOscFmAmt, 40);
  B.LfoSync(3, D_1_1, SINUS); B.P(gpLfo3Trig, LFO_TRIG_OTHER_END); B.P(gpLfo3Partner, 1);
  B.P(gpLfo3Once, 1); B.P(gpLfo3Stop, 2);                                         // Glied 3: Schwenk
  B.M(msLfo3, gpPan, 80);
  B.Hall(70, 3, 35, 20, 25);
  B.Save('L34 FM - LFO-Kette 1 - 2 - 3 (Partner)');

  // ---------- Teil 5: freie Makros (ein Regler bewegt viele) ----------
  // L35: Makro 1 (S-Kurve) laesst die Flaeche aufbluehen: heller, groessere Grains, breiter, mehr Hall
  B.Start('Streicherflaeche.wav');
  B.P(gpGrainSize, 120); B.P(gpDensity, 40); B.P(gpScan, 0.3); B.P(gpSpread, 20);
  B.P(gpAttack, 400); B.P(gpSustain, 100); B.P(gpRelease, 1800);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 600); B.P(gpFltReso, 15);
  B.Hall(70, 3, 40, 20, 10);
  B.P(gpUMac1, 25); B.P(gpUMac1Curve, 3);
  B.M(msMacro1, gpFltCutoff, 60);
  B.M(msMacro1, gpGrainSize, 50);
  B.M(msMacro1, gpSpread, 70);
  B.M(msMacro1, gpRevMix, 50);
  B.Save('L35 Makro - ein Regler laesst die Flaeche aufbluehen');

  // L36: Makro 2 (langsam ansteigend) zerlegt den Chor: Streuung, Rueckwaerts, Tonhoehen-Zufall, Echo;
  // die Dichte geht dabei zurueck (negative Menge)
  B.Start('Chor_Aah.wav');
  B.P(gpGrainSize, 160); B.P(gpDensity, 45); B.P(gpScan, 0); B.P(gpPosition, 40); B.P(gpSpray, 2);
  B.P(gpSpread, 50); B.P(gpAttack, 300); B.P(gpSustain, 100); B.P(gpRelease, 1500);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 35); B.P(gpEchoMix, 0);
  B.Hall(60, 2.5, 40, 15, 20);
  B.P(gpUMac2, 0); B.P(gpUMac2Curve, 1);
  B.M(msMacro2, gpSpray, 60);
  B.M(msMacro2, gpReverse, 70);
  B.M(msMacro2, gpPitchRand, 40);
  B.M(msMacro2, gpEchoMix, 50);
  B.M(msMacro2, gpDensity, -30);
  B.Save('L36 Makro - Chor zerfaellt (Kurve langsam ansteigend)');

  // L37: zwei Makros fuer die DAW-Automation: Makro 1 macht den Bass-Wobble schneller und heller,
  // Makro 3 (schnell ansteigend) dreht das Echo bis kurz vor die Selbstoszillation
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainSize, 90); B.P(gpDensity, 50); B.P(gpScan, 0); B.P(gpSpray, 1);
  B.P(gpAttack, 5); B.P(gpSustain, 100); B.P(gpRelease, 300);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 300); B.P(gpFltReso, 45);
  B.LfoFree(1, 1, SINUS);
  B.M(msLfo1, gpFltCutoff, 25);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 20); B.P(gpEchoMix, 15);
  B.P(gpUMac1, 0); B.P(gpUMac3, 0); B.P(gpUMac3Curve, 2);
  B.M(msMacro1, gpLfo1Rate, 60);
  B.M(msMacro1, gpFltCutoff, 35);
  B.M(msMacro3, gpEchoFeedback, 55);
  B.M(msMacro3, gpEchoMix, 35);
  B.Save('L37 Makro - Wobble und Echo fuer die DAW-Automation');

  // ---------- Teil 6: Gleiten, Saettigungs-Arten, Kompressor (Nov. 2026) ----------
  // L38: Acid-Linie aus dem freien LFO (16 Stufen in Halbtoenen, 1 Takt) auf Pitch; die Stufen 3, 7, 10,
  // 14 und 16 gleiten vom vorigen Ton herueber, die anderen springen. Trance-Gate 1/16 macht Einzelnoten.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 45); B.P(gpOscLevel, 75);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 300); B.P(gpOscSustain, 90); B.P(gpOscRelease, 80);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 420); B.P(gpFltReso, 75); B.P(gpFltContour, 100);
  B.LfoSync(1, D_1_1, SINUS);
  B.FreeSteps(1, 0, [0, 0, 12, 0, 3, 0, 7, 10, 0, 12, 0, 3, 5, 0, 7, 12]);
  B.FreeGlide(1, [2, 6, 9, 13, 15]);
  B.PitchFromFree(1);
  B.P(gpOscFollowPitch, 1);    // Pitch steuert sonst nur die Grains - hier spielen die Oszillatoren
  B.LfoSync(2, D_1_2, DREIECK);
  B.M(msLfo2, gpFltCutoff, 22);
  B.P(gpTgOn, 1); B.P(gpTgRate, 3); B.P(gpTgDepth, 70); B.P(gpTgSmooth, 10);
  B.P(gpDrive, 40); B.P(gpDriveType, 1);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8T); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 10);
  B.P(gpVolume, -6);
  B.Save('L38 FM - Step-Sequencer mit Gleiten je Stufe (Acid)');

  // L39: Saettigungs-Arten im Vergleich - FM-Bass mit kraeftigem Drive auf "Roehre"; Art im Reiter EQ
  // auf Warm / Hart / Faltung umschalten und vergleichen. Modrad = mehr Drive.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 2); B.P(gpOscFmRatio, 1); B.P(gpOscFmAmt, 30); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 500); B.P(gpOscSustain, 80); B.P(gpOscRelease, 160);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 50);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 160);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 1500); B.P(gpFltReso, 20); B.P(gpFltContour, 100);
  B.P(gpDrive, 60); B.P(gpDriveType, 1);
  B.M(msModWheel, gpDrive, 35);
  B.P(gpVolume, -6);
  B.Save('L39 FM - Saettigung Art Roehre (umschalten und vergleichen)');

  // L40: Faltung (Wavefolder) - ein Sinus-Lead; das Modrad dreht den Drive auf, die Welle faltet sich
  // immer oefter zurueck: von rund ueber hohl bis metallisch. Ein langsamer LFO bewegt es leicht.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 0); B.P(gpOscOct, 3); B.P(gpOscLevel, 70);
  B.P(gpOscAttack, 5); B.P(gpOscDecay, 800); B.P(gpOscSustain, 85); B.P(gpOscRelease, 300);
  B.P(gpDrive, 35); B.P(gpDriveType, 3);
  B.M(msModWheel, gpDrive, 60);
  B.LfoSync(1, D_1_2, SINUS);
  B.M(msLfo1, gpDrive, 10);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 12);
  B.Hall(55, 2, 50, 10, 12);
  B.P(gpVolume, -8);
  B.Save('L40 FM - Saettigung Art Faltung (Modrad = Falten)');

  // L41: Kompressor - gezupfte FM-Akkorde mit langem Hall. Kompressor an, Menge 85 %: der Ausklang und
  // der Hall kommen nach vorn, der Anschlag wird gebremst. Im Reiter Summe an/aus schalten und vergleichen.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 40); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 450); B.P(gpOscSustain, 15); B.P(gpOscRelease, 500);
  B.P(gpOscFmEnvOn, 1); B.P(gpOscFmAttack, 1); B.P(gpOscFmDecay, 200); B.P(gpOscFmSustain, 20); B.P(gpOscFmRelease, 300);
  B.M(msVelocity, gpOscFmAmt, 25);
  B.P(gpDrive, 20); B.P(gpDriveType, 2);
  B.Hall(75, 4, 50, 15, 28);
  B.P(gpCompOn, 1); B.P(gpCompAmt, 85); B.P(gpCompTime, 100);
  B.P(gpVolume, -8);
  B.Save('L41 FM - Kompressor macht Ausklang und Hall dicht');

  // L42: Bass mono - ein sehr breiter Reese-Bass (7 Unison-Stimmen, volle Breite, Chorus). Bass mono 120 Hz
  // legt das Fundament in die Mitte, die Breite darueber bleibt. Im Reiter Summe ein-/ausschalten.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 2); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 3); B.P(gpOscDecay, 800); B.P(gpOscSustain, 90); B.P(gpOscRelease, 200);
  B.P(gpOscUnison, 7); B.P(gpOscDetune, 25); B.P(gpOscUniWidth, 100);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 900); B.P(gpFltReso, 20); B.P(gpFltContour, 100);
  B.P(gpChoOn, 1); B.P(gpChoMix, 35);
  B.P(gpWidth, 160);
  B.P(gpBassMonoOn, 1); B.P(gpBassMonoFreq, 120);
  B.P(gpDrive, 25);
  B.P(gpVolume, -6);
  B.Save('L42 FM - Bass mono haelt den breiten Bass in der Mitte');

  // L43: Modulations-Huellkurven - FM-Pluck: Mod-Huellk. 1 (kurz) macht nur den Anschlag hell (FM-Menge),
  // Mod-Huellk. 2 (langsam an) oeffnet waehrend des Haltens das Filter. Note lange halten.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 4); B.P(gpOscOct, 3); B.P(gpOscFmRatio, 2); B.P(gpOscFmAmt, 10); B.P(gpOscLevel, 65);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 1500); B.P(gpOscSustain, 70); B.P(gpOscRelease, 400);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 500); B.P(gpFltReso, 35); B.P(gpFltContour, 100);
  B.P(gpMEnv1Att, 1); B.P(gpMEnv1Dec, 180); B.P(gpMEnv1Sus, 0); B.P(gpMEnv1Rel, 100);
  B.P(gpMEnv2Att, 2500); B.P(gpMEnv2Dec, 500); B.P(gpMEnv2Sus, 100); B.P(gpMEnv2Rel, 800);
  B.M(msModEnv1, gpOscFmAmt, 45);
  B.M(msModEnv2, gpFltCutoff, 40);
  B.P(gpEchoOn, 1); B.EchoSync(D_1_8); B.P(gpEchoFeedback, 25); B.P(gpEchoMix, 12);
  B.Hall(55, 2, 50, 10, 14);
  B.P(gpVolume, -6);
  B.Save('L43 FM - Mod-Huellkurven - heller Anschlag, Filter oeffnet beim Halten');

  // L44: Wavetable - Oszillator 1 spielt WT_FM_Wachsend (Sinus -> harte FM). Mod-Huellk. 1 faehrt bei jeder
  // Note durch die Frames, das Modrad schiebt die Position weiter; Roehren-Saettigung und Bass mono.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscOct, 2); B.P(gpOscLevel, 70);
  B.Wavetable(1, 'WT_FM_Wachsend.wav');
  B.P(gpOscWtPos, 10);
  B.P(gpOscAttack, 2); B.P(gpOscDecay, 900); B.P(gpOscSustain, 85); B.P(gpOscRelease, 200);
  B.P(gpOsc3On, 1); B.P(gpOsc3Wave, 0); B.P(gpOsc3Oct, 1); B.P(gpOsc3Level, 45);
  B.P(gpOsc3Attack, 2); B.P(gpOsc3Sustain, 100); B.P(gpOsc3Release, 200);
  B.P(gpMEnv1Att, 400); B.P(gpMEnv1Dec, 900); B.P(gpMEnv1Sus, 35); B.P(gpMEnv1Rel, 300);
  B.M(msModEnv1, gpOscWtPos, 60);
  B.M(msModWheel, gpOscWtPos, 40);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 2400); B.P(gpFltReso, 20); B.P(gpFltContour, 100);
  B.P(gpDrive, 35); B.P(gpDriveType, 1);
  B.P(gpBassMonoOn, 1);
  B.P(gpVolume, -6);
  B.Save('L44 FM - Wavetable faehrt bei jeder Note durch die Frames');

  // L45: Sub und Rauschen an Osz 1 - Saegezahn-Bass mit Sinus-Sub eine Oktave tiefer (Fundament) und etwas
  // Rauschen im Anschlag (die Huellkurve ist kurz, das Filter oeffnet beim Anschlag)
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 2); B.P(gpOscLevel, 60);
  B.P(gpOscAttack, 1); B.P(gpOscDecay, 400); B.P(gpOscSustain, 70); B.P(gpOscRelease, 150);
  B.P(gpSubLevel, 80); B.P(gpSubOct, 0); B.P(gpSubWave, 0);
  B.P(gpNoiseLevel, 25);
  B.P(gpFltOn, 1); B.P(gpFltType, F_TP); B.P(gpFltCutoff, 400); B.P(gpFltReso, 30); B.P(gpFltContour, 100);
  B.P(gpFltEnvAmt, 55); B.P(gpFltAttack, 1); B.P(gpFltDecay, 220); B.P(gpFltSustain, 10); B.P(gpFltRelease, 120);
  B.P(gpBassMonoOn, 1);
  B.P(gpVolume, -6);
  B.Save('L45 FM - Sub und Rauschen geben dem Bass Fundament und Anschlag');

  // L46: Reihenfolge der Effekte - Akkord-Flaeche mit Trance-Gate, Crusher und Chorus. Reihenfolge
  // "Chorus > Crusher > ..." : der Crusher zerhackt auch die Schwebung. Im Reiter Effekte umschalten.
  B.Start('Warmer_Bass_C2.wav');
  B.P(gpGrainOn, 0);
  B.P(gpOscOn, 1); B.P(gpOscWave, 2); B.P(gpOscOct, 3); B.P(gpOscLevel, 55);
  B.P(gpOscAttack, 30); B.P(gpOscDecay, 1500); B.P(gpOscSustain, 85); B.P(gpOscRelease, 600);
  B.P(gpOscUnison, 3); B.P(gpOscDetune, 12); B.P(gpOscUniWidth, 80);
  B.P(gpTgOn, 1); B.P(gpTgRate, 3); B.P(gpTgDepth, 85); B.P(gpTgSmooth, 6);
  B.P(gpCrushOn, 1); B.P(gpCrushBits, 7); B.P(gpCrushRate, 9000); B.P(gpCrushMix, 70);
  B.P(gpChoOn, 1); B.P(gpChoDepth, 70); B.P(gpChoMix, 50);
  B.P(gpFxOrder, 14);          // Chorus > Crusher > Gate > Phaser (siehe FX_ORDERS)
  B.Hall(70, 3, 50, 15, 20);
  B.P(gpVolume, -7);
  B.Save('L46 FM - Reihenfolge der Effekte (Chorus vor Crusher)');
end;

procedure WriteLearningGuide(const Dir: string);
var
  T: TStringList;
begin
  T := TStringList.Create;
  try
    T.Add('GranularSynth - Lernpfad (Presets L01 bis L46)');
    T.Add('==============================================');
    T.Add('Jedes Preset zeigt ein Prinzip. Oeffnen, spielen, und im Reiter "Modulation"');
    T.Add('nachsehen, welche Matrix-Zeilen belegt sind. Der rote Strich unter einem Regler');
    T.Add('zeigt live, wie weit die Matrix ihn gerade verschiebt.');
    T.Add('Formel jeder Zeile: Wirkwert = Grundwert + (Quelle x Faktor + Offset) x Menge');
    T.Add('');
    T.Add('Teil 1 - Matrix-Grundlagen');
    T.Add('  L01  LFO -> Position. Eine lange Note halten: der Klang wandert langsam durch das');
    T.Add('       Chor-Sample. Menge in Zeile 1 aendern = wie weit er wandert.');
    T.Add('  L02  LFO 1 macht Vibrato, LFO 2 veraendert das Tempo von LFO 1. Das Vibrato atmet.');
    T.Add('       Ein LFO kann jeden Parameter steuern - auch einen anderen LFO.');
    T.Add('  L03  Velocity -> Cutoff und Graingroesse. Leise und laut spielen: laut wird heller');
    T.Add('       und knackiger. Negative Menge = Gegenrichtung.');
    T.Add('  L04  Notenhoehe -> Graingroesse und Echozeit. Tiefe Noten: grosse Grains, langes Echo.');
    T.Add('       Offset -50 % zentriert die Quelle um die Tastaturmitte.');
    T.Add('  L05  Modrad -> Filter + Makros "Bewegung" und "Raum". Modrad langsam hochdrehen:');
    T.Add('       ein Regler fuer den ganzen Ausdruck.');
    T.Add('  L06  Aftertouch faechert den Chor auf, Pitchbend verbiegt nur das Echo.');
    T.Add('');
    T.Add('Teil 2 - Huellkurven und Trigger');
    T.Add('  L07  Filter-Huellkurve -> Streuung: beim Anschlag explodieren die Grains und ziehen');
    T.Add('       sich zusammen. Huellkurven sind auch fuer Nicht-Filter-Ziele nutzbar.');
    T.Add('  L08  Grain-Huellkurve -> Echo-Mix mit negativer Menge: solange die Note klingt, bleibt');
    T.Add('       es trocken - beim Loslassen blueht das Echo auf.');
    T.Add('  L09  LFO-Trigger "Note an": die Saege startet mit jeder Note neu -> jede Note bekommt');
    T.Add('       denselben Filter-Sweep. Auf "frei" stellen und vergleichen.');
    T.Add('  L10  LFO-Trigger "Note aus": der Ausklang faellt in der Tonhoehe ab.');
    T.Add('  L11  Arpeggiator: Akkord halten - die Toene laufen nacheinander ueber 2 Oktaven.');
    T.Add('       Im Schrittmuster (Reiter Extras) sind Schritte aus = Pausen. Felder anklicken!');
    T.Add('  L12  Faktor x1/2 + Offset +50 % machen aus einem LFO (-1..+1) eine einseitige');
    T.Add('       Quelle (0..1): Rueckwaerts-Anteil und Breite schwanken nur nach oben.');
    T.Add('');
    T.Add('Teil 3 - Sidechain');
    T.Add('  Sidechain-Quelle waehlen: im GranularHost unten "Sidechain" (z.B. Mikrofon),');
    T.Add('  in FL Studio einen Mixerkanal auf den Plugin-Eingang routen. Der Monitor zeigt');
    T.Add('  orange das Sidechain-Signal, IN den Pegel, SC den Huellkurvenfolger.');
    T.Add('  L13  Ducking: Signal am Sidechain macht das Pad leiser - das klassische Pumpen.');
    T.Add('       Eine Kick auf den Sidechain legen.');
    T.Add('  L14  Auto-Wah: Lautstaerke der Stimme oeffnet den Bandpass. "Wah wah" sprechen.');
    T.Add('  L15  Echo Pitch per Modrad: unten = normale Echos, hoch = jede Wiederholung bis zu');
    T.Add('       einer Oktave hoeher. Beim Spielen langsam bewegen - die Treppe wird steiler.');
    T.Add('  L16  Der Pegel scrubbt durch die Vokale a-e-i-o-u: leise = a, laut = u.');
    T.Add('  L17  Dub-Echo: Rueckkopplung nur, solange Signal kommt - Echos auf Zuruf.');
    T.Add('  L18  SC-Tonhoehe -> Pitch ueber die Matrix (Faktor x2,65, Offset -125 %): der Chor');
    T.Add('       singt die Toene nach, die ins Mikrofon gesungen werden. Taste halten!');
    T.Add('       Ohne Stimme klingt der Chor normal; mit Stimme wird er lauter und folgt ihr.');
    T.Add('  L19  Dasselbe mit "Auto-Pitch" in Halbtoenen, eine Oktave hoeher, mit Vibrato.');
    T.Add('');
    T.Add('Finale');
    T.Add('  L20  Alles zusammen: wandernde Position, LFO-Kaskade, Filter-Huellkurve, steigendes');
    T.Add('       Pitch-Echo, Velocity, Modrad (Echo-Menge) und Sidechain (Tonhoehen-Streuung).');
    T.Add('       Lange Noten halten, Modrad bewegen, ins Mikrofon sprechen.');
    T.Add('');
    T.Add('Neue Funktionen');
    T.Add('  L21  Sidechain-Trigger (Pegel): lauter Zuruf ins Mikrofon startet einen Einmal-LFO,');
    T.Add('       der eine Melodie ueber die Pitch-Matrix spielt. Taste halten, dann rufen.');
    T.Add('  L22  Sidechain-Trigger (Ton): ein gesungener Ton laesst seinen Dur-Dreiklang');
    T.Add('       nacheinander erklingen (Auto-Pitch in Halbtoenen + freier LFO auf Pitch).');
    T.Add('  L23  Beide Bedingungen: nur ein lauter UND hoher Ton oeffnet den Filter einmal.');
    T.Add('       Leise hoch oder laut tief singen: nichts passiert.');
    T.Add('  L24  Glide (Portamento): jede Note gleitet 0,28 s von der vorigen her, der');
    T.Add('       Sinus-Oszillator gleitet mit. Glide-Zeit im Synth-Reiter aendern.');
    T.Add('  L25  Oszillator FM mit eigener FM-Huellkurve: der Anschlag klingt metallisch, die');
    T.Add('       Klangfarbe wird schnell weich, waehrend der Ton weiterklingt - eine Glocke.');
    T.Add('  L26  Filter je Note: jede Note hat ihr eigenes Filter mit eigener Filter-Huellkurve.');
    T.Add('       Akkordtoene nacheinander anschlagen (je 1 s Abstand) und halten: jeder Ton');
    T.Add('       oeffnet sich langsam fuer sich, die schon klingenden bleiben, wo sie sind.');
    T.Add('');
    T.Add('Teil 4 - Start, Stopp und Zeit (Reiter "LFO 1-4 / Trigger" und "Timing / Hüllk.")');
    T.Add('  Im Namen: "FM" = Oszillatoren klingen mit, "Grains" = Grains klingen mit.');
    T.Add('  Ein LFO mit Start-Ereignis laeuft, bis sein Stopp ihn anhaelt (dann keine Modulation).');
    T.Add('  L27  Stopp "Note aus": Vibrato je Note, beim Loslassen ist der Ausklang ruhig.');
    T.Add('       Stopp auf "nie" stellen: das Vibrato laeuft im Ausklang weiter.');
    T.Add('  L28  Stopp "nach Zeit" 1/2: der Wobble auf der FM-Menge laeuft nur eine halbe Note.');
    T.Add('       Tempo aendern - die Laenge folgt dem Takt.');
    T.Add('  L29  Verzoegerung + Stopp: das Tremolo setzt nach 1/4 ein (Timing / Hüllk.) und');
    T.Add('       haelt nach 1/1 an - die Laufzeit zaehlt ab dem verzoegerten Start.');
    T.Add('  L30  Stopp nach 120 ms: ein schneller Pitch-Fall nur im Anschlag. ms-Wert aendern.');
    T.Add('  L31  Drei Oszillatoren, jeder mit eigener Huellkurve (Reiter Osz 1-3): Sinus');
    T.Add('       schwillt langsam an, FM zupft kurz, gefiltertes Rauschen haucht.');
    T.Add('  L32  Osz2-Huellkurve als Matrix-Quelle: Osz 2 ist stumm, seine kurze Huellkurve');
    T.Add('       macht den FM-Anschlag von Osz 1 hell. Decay von Osz 2 aendern.');
    T.Add('  L33  Start "Note aus" + Stopp nach 1/1: beim Loslassen glitzern die Grains genau');
    T.Add('       einen Takt lang, dann klingt es ruhig aus.');
    T.Add('  L34  LFO-Kette ueber die Partner-Wahl (Feld unter "Einmal"): Note 3 Takte halten.');
    T.Add('       Takt 1: LFO 1 oeffnet das Filter. Takt 2: LFO 2 (Partner LFO 1) laesst die');
    T.Add('       FM-Menge an- und abschwellen. Takt 3: LFO 3 (Partner LFO 2) schwenkt durchs');
    T.Add('       Panorama. Alle drei stehen auf "Einmal" - nur ein Einmal-Ende loest den Partner aus.');
    T.Add('       LFO 2 und 3 haben Stopp "Note aus": so warten sie bis zu ihrem Start.');
    T.Add('');
    T.Add('Teil 5: freie Makros (Reiter Modulation, rechts neben der Matrix)');
    T.Add('  L35  Makro 1 mit S-Kurve: Note halten und Makro 1 langsam aufziehen - Filter, Grains,');
    T.Add('       Breite und Hall gehen gemeinsam auf. Die Ziele stehen unter dem Makro.');
    T.Add('  L36  Makro 2, Kurve "langsam ansteigend": erst passiert wenig, oben zerfaellt der Chor');
    T.Add('       (Streuung, Rueckwaerts, Tonhoehen-Zufall, Echo). Die Dichte hat eine negative Menge.');
    T.Add('  L37  Zwei Makros fuer die DAW: Makro 1 = Wobble schneller und heller, Makro 3 = Echo.');
    T.Add('       In FL: Rechtsklick auf den Makro-Regler > Automation in der DAW.');
    T.Add('');
    T.Add('Teil 6: Step-Sequencer, Saettigungs-Arten, Kompressor');
    T.Add('  L38  Eine Taste halten: der freie LFO spielt eine Acid-Linie (16 Stufen, 1 Takt). Einige');
    T.Add('       Stufen gleiten vom vorigen Ton herueber - im LFO-Fenster (Klick auf die LFO-Grafik)');
    T.Add('       zeigt die Leiste "Gleiten" unten, welche. Felder anklicken und hoeren.');
    T.Add('  L39  Saettigung Art "Roehre" (Reiter Summe): voller, mit geraden Obertoenen. Art auf Warm,');
    T.Add('       Hart und Faltung umschalten und vergleichen. Modrad = mehr Drive.');
    T.Add('  L40  Art "Faltung": Modrad langsam hochdrehen - die Sinuswelle faltet sich immer oefter');
    T.Add('       zurueck, von rund ueber hohl bis metallisch.');
    T.Add('  L41  Kompressor (Reiter Summe): Akkorde kurz anschlagen. Ausklang und Hall bleiben dicht und');
    T.Add('       laut. Kompressor aus- und einschalten, Menge und Tempo veraendern.');
    T.Add('  L42  Bass mono (Reiter Summe): ein sehr breiter Reese-Bass. Bass mono aus- und einschalten -');
    T.Add('       mit "an" steht das Fundament fest in der Mitte, die Breite darueber bleibt.');
    T.Add('  L43  Modulations-Huellkurven (Reiter Timing / Hüllk., unten): Note lange halten. Huellkurve 1');
    T.Add('       macht nur den Anschlag hell, Huellkurve 2 oeffnet langsam das Filter (Matrix-Zeilen 1-2).');
    T.Add('  L44  Wavetable (Reiter Osz 1, rechts unten): jede Note faehrt durch die Frames von WT_FM_Wachsend,');
    T.Add('       das Modrad schiebt weiter. Mit "Laden ..." eine andere Wavetable probieren.');
    T.Add('  L45  Sub und Rauschen (Reiter Osz 1, Mitte unten): ein Sinus eine Oktave tiefer gibt Fundament,');
    T.Add('       Rauschen den Anschlag. Sub und Rauschen auf 0 ziehen und vergleichen.');
    T.Add('  L46  Reihenfolge der Effekte (Reiter Effekte, unten): Chorus vor Crusher - der Crusher zerhackt');
    T.Add('       auch die Schwebung. Andere Reihenfolgen waehlen und hoeren.');
    T.SaveToFile(IncludeTrailingPathDelimiter(Dir) + 'LERNPFAD.txt', TEncoding.UTF8);
  finally
    T.Free;
  end;
end;

function MakePresets(const ProjectDir: string): string;
var
  Base: string;
  Demo: TSampleData;
  B: TPresetBuilder;
begin
  Base := IncludeTrailingPathDelimiter(ProjectDir);
  ForceDirectories(Base + 'Beispieltoene');
  Demo := CreateDemoSample(44100);
  try
    SaveWaveFile(Demo, Base + 'Beispieltoene' + PathDelim + 'Demo_Klang.wav');
  finally
    Demo.Free;
  end;
  B := TPresetBuilder.Create(Base + 'Presets');
  try
    try
      BuildAll(B);
      BuildLearning(B);
      WriteLearningGuide(Base + 'Presets');
    except
      on E: Exception do
        Exit('FEHLER: ' + E.Message);
    end;
    Result := Format('%d Presets nach %sPresets geschrieben und zurueckgelesen (alle Werte + Samplepfade OK), Demo_Klang.wav exportiert.', [B.Count, Base]);
  finally
    B.Free;
  end;
end;

end.
