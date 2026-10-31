{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.DemoRender;

{ Pruefstand fuer die Presets (GranularHost.exe -renderdemos <Projektordner>):
  1. Grundtonhoehe jedes Beispieltons (YIN-Tonhoehenerkenner der Engine, Median).
  2. Jedes Preset spielt das zu seinem Typ passende Autoplay-Stueck (Flaeche -> Liegeton,
     Arp -> Akkorde, sonst Melodie); 22 s werden als WAV nach <Projekt>\Demos geschrieben.
  3. Analyse je 8192-Sample-Fenster (FFT): Energie auf erwarteten Tonklassen (gespielte Noten
     samt Oktave/Quinte/Terz, bei Tonleiter auch deren Toene) gegen "fremde" Tonklassen, und
     Energie mehr als 30 Cent neben dem Halbtonraster ("verstimmt"). Ergebnis: Demos\analyse.txt,
     die auffaelligsten Presets zuerst. }

interface

function RenderDemos(const ProjectDir: string): string;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.IOUtils, System.Generics.Collections, System.Generics.Defaults, System.StrUtils,
  Granular.Params, Granular.Sample, Granular.Engine, Granular.State, Granular.AudioDecode,
  Granular.Pitch, Granular.AutoPlay;

const
  SR = 44100;
  BLOCK = 512;
  RENDER_SECONDS = 22;
  FFT_N = 8192;
  FFT_HOP = 4096;

type
  TResult = record
    Name, Song: string;
    Foreign, Detuned, Peak, RmsDb: Double;
  end;

  TRenderer = class
    Engine: TGranularEngine;
    Active: array[0..127] of Integer;
    LastOff: array[0..127] of Integer;    // Sampleposition des letzten Loslassens
    Pos: Integer;
    procedure Emit(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
  end;

procedure TRenderer.Emit(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
begin
  if IsOn then
  begin
    Engine.NoteOn(Note, Velocity, Delta);
    Inc(Active[Note and 127]);
  end
  else
  begin
    Engine.NoteOff(Note, Delta);
    if Active[Note and 127] > 0 then Dec(Active[Note and 127]);
    LastOff[Note and 127] := Pos + Delta;
  end;
end;

procedure FFT(var Re, Im: array of Double);
var
  N, I, J, K, M, Len: Integer;
  T, Wr, Wi, Ur, Ui, Xr, Xi, Ang: Double;
begin
  N := Length(Re);
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      T := Re[I]; Re[I] := Re[J]; Re[J] := T;
      T := Im[I]; Im[I] := Im[J]; Im[J] := T;
    end;
    K := N shr 1;
    while K <= J do
    begin
      J := J - K;
      K := K shr 1;
    end;
    J := J + K;
  end;
  Len := 2;
  while Len <= N do
  begin
    Ang := -2 * Pi / Len;
    for I := 0 to N div Len - 1 do
      for M := 0 to Len div 2 - 1 do
      begin
        Wr := Cos(Ang * M); Wi := Sin(Ang * M);
        J := I * Len + M;
        K := J + Len div 2;
        Xr := Re[K] * Wr - Im[K] * Wi;
        Xi := Re[K] * Wi + Im[K] * Wr;
        Ur := Re[J]; Ui := Im[J];
        Re[J] := Ur + Xr; Im[J] := Ui + Xi;
        Re[K] := Ur - Xr; Im[K] := Ui - Xi;
      end;
    Len := Len shl 1;
  end;
end;

function NoteName(N: Double): string;
const
  NAMES: array[0..11] of string = ('C', 'Cis', 'D', 'Dis', 'E', 'F', 'Fis', 'G', 'Gis', 'A', 'B', 'H');
var
  R: Integer;
begin
  R := Round(N);
  if N - R >= 0 then
    Result := Format('%s%d +%.0f ct', [NAMES[((R mod 12) + 12) mod 12], R div 12 - 1, (N - R) * 100])
  else
    Result := Format('%s%d %.0f ct', [NAMES[((R mod 12) + 12) mod 12], R div 12 - 1, (N - R) * 100]);
end;

{ Median der erkannten Tonhoehe eines Samples (nur deutliche, stabile Abschnitte) }
function SampleRoot(const FileName: string; out Valid: Boolean): Double;
var
  S: TSampleData;
  P: TPitchTracker;
  I, N: Integer;
  Notes: TList<Double>;
begin
  Valid := False;
  Result := 0;
  S := LoadAudioFile(FileName);
  P := TPitchTracker.Create;
  Notes := TList<Double>.Create;
  try
    P.SetSampleRate(S.SampleRate);
    I := 0;
    while I + 256 < S.Frames do
    begin
      N := 256;
      P.Process(@S.L[I], @S.R[I], N);
      if P.Valid and (I > S.SampleRate * 0.1) then
        Notes.Add(P.Note);
      Inc(I, N);
    end;
    if Notes.Count > 10 then
    begin
      Notes.Sort;
      Result := Notes[Notes.Count div 2];
      Valid := True;
    end;
  finally
    Notes.Free;
    P.Free;
    S.Free;
  end;
end;

function PickSong(Auto: TAutoPlayer; Mask: Integer): Integer;
const
  PREF: array[0..2] of string = ('Liegeton: langsame Akkordwechsel', 'Arp: Akkorde Am F C G', 'Abendlicht');
var
  I, K: Integer;
begin
  if Mask = SONG_DRONE then K := 0 else if Mask = SONG_ARP then K := 1 else K := 2;
  for I := 0 to Auto.SongCount - 1 do
    if Pos(PREF[K], Auto.Titles[I]) = 1 then
      Exit(I);
  Result := 0;
end;

function Analyse(const L, R: TArray<Single>; const Expected: TArray<Word>; out Foreign, Detuned: Double): Boolean;
var
  F, I, Bin, Pc: Integer;
  Re, Im: array of Double;
  Hz, Midi, E, Tot, Fo, De: Double;
  Mask: Word;
begin
  SetLength(Re, FFT_N);
  SetLength(Im, FFT_N);
  Tot := 0; Fo := 0; De := 0;
  F := 0;
  while (F + 1) * FFT_HOP + FFT_N <= Length(L) do
  begin
    Mask := Expected[Min(F, High(Expected))];
    for I := 0 to FFT_N - 1 do
    begin
      Re[I] := (L[F * FFT_HOP + I] + R[F * FFT_HOP + I]) * 0.5 * (0.5 - 0.5 * Cos(2 * Pi * I / (FFT_N - 1)));
      Im[I] := 0;
    end;
    FFT(Re, Im);
    if Mask <> 0 then
      for Bin := Round(100 * FFT_N / SR) to Round(4000 * FFT_N / SR) do
      begin
        E := Sqr(Re[Bin]) + Sqr(Im[Bin]);
        Hz := Bin * SR / FFT_N;
        Midi := 69 + 12 * Log2(Hz / 440);
        Pc := ((Round(Midi) mod 12) + 12) mod 12;
        Tot := Tot + E;
        if (Mask and (1 shl Pc)) = 0 then
          Fo := Fo + E;
        if Abs(Midi - Round(Midi)) > 0.3 then
          De := De + E;
      end;
    Inc(F);
  end;
  Result := Tot > 1E-6;
  if Result then
  begin
    Foreign := Fo / Tot * 100;
    Detuned := De / Tot * 100;
  end
  else
  begin
    Foreign := 0;
    Detuned := 0;
  end;
end;

function KindMaskForName(const Name: string): Integer;
const
  DRONE_WORDS: array[0..12] of string = ('flaeche', 'freeze', 'oper', 'stimme', 'kathedrale', 'nebel',
    'ozean', 'daemmerung', 'morph', 'regen', 'weltraum', 'eingefroren', 'pad im');
var
  Low: string;
  I: Integer;
begin
  Low := LowerCase(Name);
  if Pos('arp', Low) > 0 then
    Exit(SONG_ARP);
  for I := 0 to High(DRONE_WORDS) do
    if Pos(DRONE_WORDS[I], Low) > 0 then
      Exit(SONG_DRONE);
  Result := SONG_MELODY;
end;

function RenderDemos(const ProjectDir: string): string;
var
  Base, OutDir, F, Path, Res, Nm: string;
  Rep: TStringList;
  Files: TArray<string>;
  Results: TList<TResult>;
  Rd: TRenderer;
  Auto: TAutoPlayer;
  BufL, BufR: array[0..BLOCK - 1] of Single;
  L, R: TArray<Single>;
  Expected: TArray<Word>;
  Song, Total, Done, I, N, Frame, Pc, ScaleIdx, Root: Integer;
  Tempo, Peak, Sum, Note: Double;
  Valid: Boolean;
  Mask: Word;
  Rs: TResult;
  Wav: TSampleData;
begin
  Base := IncludeTrailingPathDelimiter(ProjectDir);
  OutDir := Base + 'Demos' + PathDelim;
  ForceDirectories(OutDir);
  Rep := TStringList.Create;
  Results := TList<TResult>.Create;
  Rd := TRenderer.Create;
  try
    // 1) Grundtonhoehen der Beispieltoene
    Rep.Add('Grundtonhoehe der Beispieltoene (Engine spielt das Sample auf C4 unveraendert):');
    for F in TDirectory.GetFiles(Base + 'Beispieltoene', '*.wav') do
    begin
      Note := SampleRoot(F, Valid);
      Wav := LoadAudioFile(F);
      Rd.Engine := TGranularEngine.Create;
      try
        Rd.Engine.LoadSample(Wav);
        if Rd.Engine.SampleRoot > 0 then
          Rep.Add(Format('  %-28s %-14s Auto-Stimmung: %s', [ExtractFileName(F), NoteName(Note),
            IfThen(Abs(Frac(Rd.Engine.SampleRoot)) >= 0, 'ja (ein stabiler Ton)', '')]))
        else if Valid then
          Rep.Add(Format('  %-28s %-14s Auto-Stimmung: nein (mehrere Toene/unstabil)', [ExtractFileName(F), NoteName(Note)]))
        else
          Rep.Add(Format('  %-28s (keine stabile Tonhoehe - Geraeusch/Sprache/Akkord)', [ExtractFileName(F)]));
      finally
        FreeAndNil(Rd.Engine);
      end;
      Continue;
      if Valid then
        Rep.Add(Format('  %-28s %s', [ExtractFileName(F), NoteName(Note)]))
      else
        Rep.Add(Format('  %-28s (keine stabile Tonhoehe - Geraeusch/Sprache/Akkord)', [ExtractFileName(F)]));
    end;
    Rep.Add('');

    // 2) + 3) Presets rendern und analysieren
    Files := TDirectory.GetFiles(Base + 'Presets', '*.gspreset');
    TArray.Sort<string>(Files);
    for F in Files do
    begin
      Nm := ChangeFileExt(ExtractFileName(F), '');
      Rd.Engine := TGranularEngine.Create;
      Auto := TAutoPlayer.Create(SR);
      try
        Rd.Engine.SetSampleRate(SR);
        if not LoadChunkFromFile(Rd.Engine, F, Path) then
          Continue;
        Res := ResolveSamplePath(Path, Base);
        if Res <> '' then
          Rd.Engine.LoadSample(LoadAudioFile(Res))
        else
          Rd.Engine.LoadSample(CreateDemoSample(SR));
        LoadMorphSample(Rd.Engine, Base);
        LoadZoneSamples(Rd.Engine, Base);
        Song := PickSong(Auto, KindMaskForName(Nm));
        Auto.KindMask := SONG_ALL;
        Auto.Start(Song);
        FillChar(Rd.Active, SizeOf(Rd.Active), 0);
        for I := 0 to 127 do Rd.LastOff[I] := -10 * SR;
        Total := RENDER_SECONDS * SR;
        SetLength(L, Total);
        SetLength(R, Total);
        SetLength(Expected, Total div FFT_HOP + 2);
        Tempo := 120;
        ScaleIdx := ParamStep(Ord(gpScale), Rd.Engine.GetParam(Ord(gpScale)));
        Root := ParamStep(Ord(gpScaleRoot), Rd.Engine.GetParam(Ord(gpScaleRoot)));
        Done := 0;
        Rd.Pos := 0;
        while Done < Total do
        begin
          N := Min(BLOCK, Total - Done);
          Auto.Process(N, Tempo, Rd.Emit);
          Rd.Engine.SetParamById(gpTempo, PlainToParam(gpTempo, Tempo));
          Rd.Engine.Process(nil, nil, @BufL[0], @BufR[0], N);
          Move(BufL[0], L[Done], N * SizeOf(Single));
          Move(BufR[0], R[Done], N * SizeOf(Single));
          // erwartete Tonklassen fuer das Analysefenster, das hier beginnt
          Frame := Done div FFT_HOP;
          if Frame <= High(Expected) then
          begin
            Mask := Expected[Frame];
            for I := 0 to 127 do
              if (Rd.Active[I] > 0) or (Rd.Pos - Rd.LastOff[I] < SR * 3 div 2) then
              begin
                Pc := I mod 12;
                Mask := Mask or (1 shl Pc) or (1 shl ((Pc + 7) mod 12)) or (1 shl ((Pc + 4) mod 12));
              end;
            if ScaleIdx > 0 then
              for Pc := 0 to 11 do
                if (SCALE_MASKS[ScaleIdx] and (1 shl Pc)) <> 0 then
                  Mask := Mask or (1 shl ((Pc + Root) mod 12));
            Expected[Frame] := Mask;
          end;
          Inc(Done, N);
          Inc(Rd.Pos, N);
        end;
        Auto.Stop;
        // Kennwerte
        Peak := 0; Sum := 0;
        for I := 0 to Total - 1 do
        begin
          Peak := Max(Peak, Max(Abs(L[I]), Abs(R[I])));
          Sum := Sum + Sqr(L[I]) + Sqr(R[I]);
        end;
        Rs.Name := Nm;
        Rs.Song := Auto.Titles[Song];
        Analyse(L, R, Expected, Rs.Foreign, Rs.Detuned);
        Rs.Peak := Peak;
        Rs.RmsDb := 10 * Log10(Max(Sum / (2 * Total), 1E-12));
        Results.Add(Rs);
        // WAV schreiben
        Wav := TSampleData.Create;
        try
          Wav.L := L; Wav.R := R; Wav.Frames := Total; Wav.SampleRate := SR; Wav.Channels := 2;
          SaveWaveFile(Wav, OutDir + Nm + '.wav');
        finally
          Wav.Free;
        end;
      finally
        Auto.Free;
        FreeAndNil(Rd.Engine);
      end;
    end;
    // 4) Bericht: auffaelligste zuerst (Fremdtoene + Verstimmung)
    Results.Sort(TComparer<TResult>.Construct(
      function(const A, B: TResult): Integer
      begin
        Result := CompareValue(B.Foreign + B.Detuned, A.Foreign + A.Detuned);
      end));
    Rep.Add('Presets, auffaelligste zuerst (Fremd = Energie auf nicht gespielten Tonklassen, ' +
      'Verstimmt = mehr als 30 Cent neben dem Raster):');
    Rep.Add(Format('  %-52s %7s %9s %6s %7s  %s', ['Preset', 'Fremd%', 'Verstimmt', 'Spitze', 'RMS dB', 'Stueck']));
    for Rs in Results do
      Rep.Add(Format('  %-52s %7.1f %9.1f %6.2f %7.1f  %s', [Rs.Name, Rs.Foreign, Rs.Detuned, Rs.Peak, Rs.RmsDb, Rs.Song]));
    Rep.SaveToFile(OutDir + 'analyse.txt', TEncoding.UTF8);
    Result := Format('%d Presets gerendert nach %s, Analyse in analyse.txt', [Results.Count, OutDir]);
  finally
    Rd.Free;
    Results.Free;
    Rep.Free;
  end;
end;

end.
