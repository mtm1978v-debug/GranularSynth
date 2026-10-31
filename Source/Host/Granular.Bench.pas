{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Bench;

{ Offline-Benchmark (GranularHost.exe -bench): rendert dieselbe Last einmal mit dem
  Pascal-Kern und einmal mit dem SSE-Kern, misst die Zeit und vergleicht die Ausgaben.
  Ergebnis landet in bench.txt neben der EXE. }

interface

function RunBenchmark: string;

implementation

uses
  Granular.Lang,
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.StrUtils, System.IOUtils,
  GR32, Granular.Params, Granular.Sample, Granular.Engine, Granular.DSP, Granular.GfxAsm, Granular.Reverb, Granular.Eq, Granular.AutoPlay, Granular.State, Granular.AudioDecode, Granular.Vst3, Granular.VstHost,
  Vcl.Forms, Granular.Editor, Granular.InfoView;

const
  SR = 44100;
  BLOCK = 512;
  SECONDS = 10;

type
  TRender = record
    L, R: TArray<Single>;
    Ms: Double;
    Grains: Integer;
  end;

function RenderWith(UseSSE: Boolean; HQ: Boolean = True; Limiter: Boolean = True): TRender;
var
  E: TGranularEngine;
  N, Frames, Done: Integer;
  T0, T1, Freq: Int64;
  Notes: array[0..7] of Integer;
begin
  InitDSP(UseSSE);
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    // hohe Last: 8 Stimmen x 120 Grains/s x 150 ms ~ 144 gleichzeitige Grains
    E.SetParamById(gpDensity, PlainToParam(gpDensity, 120));
    E.SetParamById(gpGrainSize, PlainToParam(gpGrainSize, 150));
    E.SetParamById(gpPitchRand, PlainToParam(gpPitchRand, 3));
    E.SetParamById(gpSpray, PlainToParam(gpSpray, 20));
    E.SetParamById(gpReverse, PlainToParam(gpReverse, 30));
    E.SetParamById(gpFltContour, PlainToParam(gpFltContour, 100));
    E.SetParamById(gpFltCutoff, PlainToParam(gpFltCutoff, 1500));
    E.SetParamById(gpFltReso, PlainToParam(gpFltReso, 60));
    E.SetParamById(gpFltEnvAmt, PlainToParam(gpFltEnvAmt, 50));
    E.SetParamById(gpEchoMix, PlainToParam(gpEchoMix, 40));
    E.SetParamById(gpQuality, Ord(HQ));
    E.SetParamById(gpLimiter, Ord(Limiter));
    Notes[0] := 48; Notes[1] := 52; Notes[2] := 55; Notes[3] := 60;
    Notes[4] := 64; Notes[5] := 67; Notes[6] := 72; Notes[7] := 76;
    for N := 0 to High(Notes) do
      E.NoteOn(Notes[N], 0.7);

    Frames := SR * SECONDS;
    SetLength(Result.L, Frames);
    SetLength(Result.R, Frames);
    QueryPerformanceFrequency(Freq);
    QueryPerformanceCounter(T0);
    Done := 0;
    while Done < Frames do
    begin
      N := Min(BLOCK, Frames - Done);
      E.Process(nil, nil, @Result.L[Done], @Result.R[Done], N);
      Inc(Done, N);
    end;
    QueryPerformanceCounter(T1);
    Result.Ms := (T1 - T0) * 1000 / Freq;
    Result.Grains := E.ActiveGrains;
  finally
    E.Free;
  end;
end;

function CheckGfxKernel: string;
var
  A, B: array of TColor32;
  I, K, Pass, Diff, Ofs: Integer;
begin
  // Grafik-Kern (MMX/SSE2) gegen Pascal-Referenz: zufaellige Pixel, beide Offset-Vorzeichen
  Diff := 0;
  RandSeed := 42;
  SetLength(A, 1001);   // ungerade Laenge prueft auch das Restpixel
  SetLength(B, 1001);
  for Pass := 0 to 3 do
  begin
    K := 40 + Pass * 40;
    if Odd(Pass) then Ofs := -60 else Ofs := 25;
    for I := 0 to High(A) do
    begin
      A[I] := TColor32(Random(MaxInt)) or (TColor32(Random(256)) shl 24);
      B[I] := A[I];
    end;
    ContrastRow(@A[0], Length(A), K, Ofs);
    ContrastRowPas(@B[0], Length(B), K, Ofs);
    for I := 0 to High(A) do
      if A[I] <> B[I] then
        Inc(Diff);
  end;
  if Diff = 0 then
    Result := 'Grafik-Kern (Kontrast, SIMD gegen Pascal): identisch'
  else
    Result := Format('Grafik-Kern (Kontrast): %d ABWEICHUNGEN gegenueber Pascal!', [Diff]);
end;

function CheckSpectrumKernels: string;
var
  R1, I1, R2, I2, TR, TI, P1, P2: array of Single;
  C1, C2, CS, CG: array of TColor32;
  I: Integer;
  D: Double;
begin
  // FFT-Butterfly und Leistung (SIMD) gegen Pascal-Referenz
  RandSeed := 7;
  SetLength(R1, 64); SetLength(I1, 64); SetLength(TR, 32); SetLength(TI, 32);
  for I := 0 to 63 do
  begin
    R1[I] := Random - 0.5;
    I1[I] := Random - 0.5;
  end;
  for I := 0 to 31 do
  begin
    TR[I] := Cos(Pi * I / 32);
    TI[I] := -Sin(Pi * I / 32);
  end;
  R2 := Copy(R1); I2 := Copy(I1);
  FftButterfly(@R1[0], @I1[0], 32 * SizeOf(Single), @TR[0], @TI[0], 32);
  FftButterflyPas(@R2[0], @I2[0], 32 * SizeOf(Single), @TR[0], @TI[0], 32);
  SetLength(P1, 64); SetLength(P2, 64);
  PowerSpec(@R1[0], @I1[0], @P1[0], 64);
  PowerSpecPas(@R2[0], @I2[0], @P2[0], 64);
  D := 0;
  for I := 0 to 63 do
    D := Max(D, Max(Abs(R1[I] - R2[I]), Max(Abs(I1[I] - I2[I]), Abs(P1[I] - P2[I]))));
  // Filteransicht: Aufhellen mit Saettigung (ungerade Laenge -> auch der Rest-Pfad)
  SetLength(C1, 37); SetLength(C2, 37); SetLength(CS, 37); SetLength(CG, 37);
  for I := 0 to 36 do
  begin
    CS[I] := TColor32(Cardinal(I * 2654435761));
    CG[I] := TColor32(Cardinal(I * 40503 + 977) * 2246822519);
  end;
  AddRowSat(@C1[0], @CS[0], @CG[0], 37);
  AddRowSatPas(@C2[0], @CS[0], @CG[0], 37);
  for I := 0 to 36 do
    if C1[I] <> C2[I] then
      D := 1;
  if D < 1E-5 then
    Result := Format('Grafik-Kern (Spektrum-FFT, SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Grafik-Kern (Spektrum-FFT): ABWEICHUNG %.3e gegenueber Pascal!', [D]);
end;

function CheckOsc: string;
var
  A, B: TOscArgs;
  Tab: array[0..4097] of Single;
  OA, OB: array[0..511] of Single;
  G, R: array[0..255] of Single;
  I, W: Integer;
  D: Double;
begin
  for I := 0 to 4097 do
    Tab[I] := Sin(2 * Pi * I / 4096);
  for I := 0 to 255 do
  begin
    G[I] := 0.5 + 0.4 * Sin(I * 0.05);
    R[I] := I / 255;
  end;
  D := 0;
  for W := 0 to 5 do
  begin
    FillChar(A, SizeOf(A), 0);
    A.Tab := @Tab[0]; A.Env := @G[0]; A.EnvRaw := @R[0]; A.Wave := W;
    A.Ph := 0.13; A.PhM := 0.71; A.Dt := 0.0123; A.DtM := 0.031; A.FmIdx := 0.6; A.GL := 0.8; A.GR := 1.1;
    A.C1 := 1; A.CM1 := -1; A.C4 := 4; A.CHalf := 0.5; A.CTab := 4096;
    A.Seed := 12345; A.CInv31 := 0.7 / 2147483648.0;
    A.SyncR := 1 + (W mod 3) * 1.37; A.DtP := A.Dt; A.Dt := Min(A.DtP * A.SyncR, 0.45);   // Hard Sync mitpruefen
    for I := 0 to 3 do A.AbsMask4[I] := $7FFFFFFF;
    B := A;
    FillChar(OA, SizeOf(OA), 0);
    FillChar(OB, SizeOf(OB), 0);
    A.Out := @OA[0]; A.Count := 256;
    B.Out := @OB[0]; B.Count := 256;
    RenderOscBlock(@A);
    OscBlockPas(@B);
    for I := 0 to High(OA) do
      D := Max(D, Abs(OA[I] - OB[I]));
    D := Max(D, Abs(A.Ph - B.Ph));
    if A.Seed <> B.Seed then D := 1;
  end;
  if D < 1E-4 then
    Result := Format('Oszillator (6 Wellen inkl. Rauschen, SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Oszillator: ABWEICHUNG %.3e gegenueber Pascal!', [D]);
end;

function CheckEq: string;
var
  P1, P2: TEqProcessor;
  C: TEqCurve;
  A, B: array[0..2047] of Single;
  I: Integer;
  D: Double;
begin
  for I := 0 to EQ_CURVE_N - 1 do
    C[I] := 12 * Sin(I * 0.3);
  P1 := TEqProcessor.Create;
  P2 := TEqProcessor.Create;
  try
    RandSeed := 9;
    for I := 0 to High(A) do
    begin
      A[I] := Random - 0.5;
      B[I] := A[I];
    end;
    InitEqDSP(True);
    P1.Process(@A[0], 1024, C, 1, 4, -3, [250, -6, 3000, 4]);
    InitEqDSP(False);
    P2.Process(@B[0], 1024, C, 1, 4, -3, [250, -6, 3000, 4]);
    InitEqDSP(CpuHasSSE2);
    D := 0;
    for I := 0 to High(A) do
      D := Max(D, Abs(A[I] - B[I]));
  finally
    P1.Free;
    P2.Free;
  end;
  // Double in beiden Pfaden -> nur die Single-Ein-/Ausgabe rundet
  if D < 1E-5 then
    Result := Format('Equalizer (Double, SSE2 gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Equalizer: ABWEICHUNG %.3e gegenueber Pascal!', [D]);
end;

function CheckSat: string;
var
  A, B: TSatArgs;
  XA, XB: array[0..255] of Single;
  I: Integer;
  D: Double;
begin
  FillChar(A, SizeOf(A), 0);
  for I := 0 to 3 do
  begin
    A.Drive4[I] := 6; A.Make4[I] := 0.5; A.Hi4[I] := 3; A.Lo4[I] := -3; A.C27[I] := 27; A.C9[I] := 9;
  end;
  B := A;
  RandSeed := 5;
  for I := 0 to High(XA) do
  begin
    XA[I] := (Random - 0.5) * 2.4;
    XB[I] := XA[I];
  end;
  A.P := @XA[0]; A.Count := Length(XA);
  B.P := @XB[0]; B.Count := Length(XB);
  RenderSat(@A);
  SatBlockPas(@B);
  D := 0;
  for I := 0 to High(XA) do
    D := Max(D, Abs(XA[I] - XB[I]));
  if D < 1E-5 then
    Result := Format('Saettigung (SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Saettigung: ABWEICHUNG %.3e gegenueber Pascal!', [D]);
end;

{ Kammfilter: SIMD gegen Pascal ueber mehrere Bloecke mit Zustand (Ring, Schreibposition) }
function CheckComb: string;
var
  A, B: TCombArgs;
  RA, RB: array[0..512 * 2 - 1] of Single;
  XA, XB: array[0..64 * 2 - 1] of Single;
  I, Pass: Integer;
  D: Double;
begin
  FillChar(RA, SizeOf(RA), 0);
  FillChar(RB, SizeOf(RB), 0);
  FillChar(A, SizeOf(A), 0);
  A.Buf := @RA[0]; A.Mask := 511; A.DInt := 37; A.Frac := 0.3; A.Fb := 0.9; A.MixX := 0.25; A.MixW := 0.6;
  B := A;
  B.Buf := @RB[0];
  RandSeed := 9;
  D := 0;
  for Pass := 0 to 40 do
  begin
    for I := 0 to High(XA) do
    begin
      XA[I] := Random - 0.5;
      XB[I] := XA[I];
    end;
    A.IO := @XA[0]; A.Count := 64;
    B.IO := @XB[0]; B.Count := 64;
    RenderComb(@A);
    CombBlockPas(@B);
    for I := 0 to High(XA) do
      D := Max(D, Abs(XA[I] - XB[I]));
  end;
  if (D < 1E-4) and (A.WritePos = B.WritePos) then
    Result := Format('Kammfilter (SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Kammfilter: FEHLER Abweichung %.3e gegenueber Pascal!', [D]);
end;

{ Neue Klangbausteine: jede Filterart, Unison, Chorus, Phaser, Bitcrusher, Hall-Schnitt,
  Trance-Gate - Ausgang endlich, hoerbar und vom Ausgangsklang verschieden; Zonen und Aufnahme }
{ Phaser: SIMD gegen Pascal ueber mehrere Bloecke mit Zustand und gleitendem Koeffizienten }
function CheckPhaser: string;
var
  A, B: TPhaserArgs;
  XA, XB: array[0..64 * 2 - 1] of Single;
  I, Pass, C: Integer;
  D: Double;
begin
  FillChar(A, SizeOf(A), 0);
  for C := 0 to 3 do
  begin
    A.A4[C] := -0.6 + 0.1 * C; A.DA4[C] := 0.001; A.Fb4[C] := 0.7; A.Dry4[C] := 0.6; A.Wet4[C] := 0.4;
  end;
  B := A;
  RandSeed := 13;
  D := 0;
  for Pass := 0 to 40 do
  begin
    for I := 0 to High(XA) do
    begin
      XA[I] := Random - 0.5;
      XB[I] := XA[I];
    end;
    A.IO := @XA[0]; A.Count := 64;
    B.IO := @XB[0]; B.Count := 64;
    RenderPhaser(@A);
    PhaserBlockPas(@B);
    for I := 0 to High(XA) do
      D := Max(D, Abs(XA[I] - XB[I]));
    for C := 0 to 1 do
    begin
      A.A4[C] := -0.6 + 0.1 * C + 0.0005 * Pass; B.A4[C] := A.A4[C];
    end;
  end;
  if D < 1E-4 then
    Result := Format('Phaser (SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Phaser: FEHLER Abweichung %.3e gegenueber Pascal!', [D]);
end;

{ Chorus: SIMD gegen Pascal ueber mehrere Bloecke (Ring, Phase, Schreibposition) }
function CheckChorus: string;
var
  A, B: TChorusArgs;
  RA, RB: array[0..1024 * 2 - 1] of Single;
  XA, XB: array[0..64 * 2 - 1] of Single;
  I, Pass: Integer;
  D: Double;
begin
  FillChar(RA, SizeOf(RA), 0);
  FillChar(RB, SizeOf(RB), 0);
  FillChar(A, SizeOf(A), 0);
  A.Buf := @RA[0]; A.Mask := 1023; A.PhInc := 98765432; A.Base8 := 300 * 256; A.Span8 := 500 * 256;
  A.Fb := 0.5; A.Dry := 0.7; A.Wet := 0.5; A.Inv256 := 1 / 256; A.Ph := $70000000;
  B := A;
  B.Buf := @RB[0];
  RandSeed := 17;
  D := 0;
  for Pass := 0 to 60 do
  begin
    for I := 0 to High(XA) do
    begin
      XA[I] := Random - 0.5;
      XB[I] := XA[I];
    end;
    A.IO := @XA[0]; A.Count := 64;
    B.IO := @XB[0]; B.Count := 64;
    RenderChorus(@A);
    ChorusBlockPas(@B);
    for I := 0 to High(XA) do
      D := Max(D, Abs(XA[I] - XB[I]));
  end;
  if (D < 1E-4) and (A.W = B.W) and (A.Ph = B.Ph) then
    Result := Format('Chorus (SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Chorus: FEHLER Abweichung %.3e gegenueber Pascal!', [D]);
end;

function CheckNewSound: string;
const
  BLK = 512;

  function Render(Setup: TProc<TGranularEngine>; out Peak: Double; Gate: PDouble = nil): TArray<Single>;
  var
    E: TGranularEngine;
    L, R: array[0..BLK - 1] of Single;
    B, I, Q: Integer;
    Mn, Mx, Lv: Double;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      Setup(E);
      E.NoteOn(57, 0.9);
      Peak := 0;
      SetLength(Result, 40 * BLK);
      Mn := 1E9; Mx := 0;
      for B := 0 to 39 do
      begin
        E.Process(nil, nil, @L[0], @R[0], BLK);
        for I := 0 to BLK - 1 do
        begin
          Result[B * BLK + I] := L[I];
          if IsNan(L[I]) or IsInfinite(L[I]) then
            Peak := 1E9
          else
            Peak := Max(Peak, Abs(L[I]));
        end;
        if B >= 10 then
          // Pegel je Viertelblock (Gate: grosser Unterschied zwischen offen und zu)
          for Q := 0 to 3 do
          begin
            Lv := 0;
            for I := Q * 128 to Q * 128 + 127 do
              Lv := Max(Lv, Abs(L[I]));
            Mn := Min(Mn, Lv);
            Mx := Max(Mx, Lv);
          end;
      end;
      if Gate <> nil then
        Gate^ := Mn / Max(Mx, 1E-9);
    finally
      E.Free;
    end;
  end;

  function Diff(const A, B: TArray<Single>): Double;
  var
    I: Integer;
  begin
    Result := 0;
    for I := 0 to Min(High(A), High(B)) do
      Result := Max(Result, Abs(A[I] - B[I]));
  end;

var
  Base, X: TArray<Single>;
  Pk, PkBase, G: Double;
  Bad, Info: string;
  T: Integer;
  E: TGranularEngine;
  Smp: TSampleData;
  In_, L, R: array[0..BLK - 1] of Single;

  procedure Test(const Name: string; Setup: TProc<TGranularEngine>);
  begin
    X := Render(Setup, Pk);
    if (Pk > 50) or (Pk < 1E-4) or (Diff(Base, X) < 1E-4) then
      Bad := Bad + Format(' %s(Spitze %.3g, Unterschied %.3g)', [Name, Pk, Diff(Base, X)])
    else
      Info := Info + Format(' %s %.2f', [Name, Pk]);
  end;

begin
  Bad := '';
  Info := '';
  Base := Render(procedure(E: TGranularEngine) begin end, PkBase);
  for T := 3 to 5 do
    Test(FILTER_NAMES[T], procedure(E: TGranularEngine)
      begin
        E.SetParamById(gpFltOn, 1);
        E.SetParamById(gpFltType, StepToParam(Ord(gpFltType), T));
        E.SetParamById(gpFltCutoff, PlainToParam(gpFltCutoff, 900));
        E.SetParamById(gpFltReso, PlainToParam(gpFltReso, 70));
      end);
  Test('Unison', procedure(E: TGranularEngine)
    begin
      E.SetParamById(gpGrainOn, 0);
      E.SetParamById(gpOscOn, 1);
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 2));
      E.SetParamById(gpOscUnison, StepToParam(Ord(gpOscUnison), 6));
      E.SetParamById(gpOscDetune, PlainToParam(gpOscDetune, 30));
    end);
  Test('Chorus', procedure(E: TGranularEngine)
    begin E.SetParamById(gpChoOn, 1); E.SetParamById(gpChoMix, PlainToParam(gpChoMix, 80)); end);
  Test('Phaser', procedure(E: TGranularEngine)
    begin E.SetParamById(gpPhaOn, 1); end);
  Test('Bitcrusher', procedure(E: TGranularEngine)
    begin E.SetParamById(gpCrushOn, 1); E.SetParamById(gpCrushBits, PlainToParam(gpCrushBits, 3)); end);
  Test('Hall-Schnitt', procedure(E: TGranularEngine)
    begin
      E.SetParamById(gpRevOn, 1);
      E.SetParamById(gpRevLowCut, PlainToParam(gpRevLowCut, 800));
      E.SetParamById(gpRevHighCut, PlainToParam(gpRevHighCut, 1500));
    end);
  // Trance-Gate: Muster 1010... -> Pegel schwankt stark
  Render(procedure(E: TGranularEngine)
    begin
      E.SetParamById(gpTgOn, 1);
      E.TgMask := $5555;
      E.SetParamById(gpTgRate, StepToParam(Ord(gpTgRate), 3));
    end, Pk, @G);
  if (G > 0.2) or (Pk > 50) then
    Bad := Bad + Format(' Trance-Gate(zu/offen %.2f)', [G])
  else
    Info := Info + Format(' Gate zu/offen %.2f', [G]);
  // Zone: Note ab C4 spielt ein anderes Sample (hier: Stille) -> Ausgang leise
  X := Render(procedure(E: TGranularEngine)
    begin
      E.SetZone(1, CreateEmptySample(SR), 48);
    end, Pk);
  if Pk > 0.01 then
    Bad := Bad + Format(' Zone(Spitze %.3g statt Stille)', [Pk]);
  // Aufnahme: 0,5 s Eingang -> Sample mit passender Laenge
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.StartRecording(0.5);
    for T := 0 to High(In_) do
      In_[T] := Sin(T * 0.05) * 0.5;
    for T := 0 to 59 do
      E.Process(@In_[0], @In_[0], @L[0], @R[0], BLK);
    Smp := E.StopRecording;
    try
      if (Smp = nil) or (Abs(Smp.Frames - SR div 2) > 1) then
        Bad := Bad + ' Aufnahme(Laenge)'
      else
        Info := Info + Format(' Aufnahme %.2f s', [Smp.Frames / SR]);
    finally
      Smp.Free;
    end;
  finally
    E.Free;
  end;
  if Bad = '' then
    Result := 'Neue Klangbausteine (Spitzenpegel):' + Info + ' -> OK'
  else
    Result := 'Neue Klangbausteine: FEHLER' + Bad;
end;

function CheckReverb: string;
var
  A, B: TFdnArgs;
  TA, TB: array[0..64 * 8 - 1] of Single;
  InLR, OA, OB: array[0..127] of Single;
  I, Pass: Integer;
  D: Double;
  Rv: TReverb;
  IO: array[0..1023] of Single;
  T0, T1, F: Int64;
begin
  // FDN-Kern (SSE) gegen Pascal: mehrere Bloecke mit Zustand
  RandSeed := 11;
  FillChar(A, SizeOf(A), 0);
  for I := 0 to 7 do
  begin
    A.Damp[I] := 0.3 + I * 0.05;
    A.Gain[I] := 0.3 - I * 0.01;
  end;
  A.SignA[1] := $80000000; A.SignA[3] := $80000000;
  A.SignB[2] := $80000000; A.SignB[3] := $80000000;
  B := A;
  D := 0;
  for Pass := 0 to 3 do
  begin
    for I := 0 to High(TA) do
    begin
      TA[I] := Random - 0.5;
      TB[I] := TA[I];
    end;
    for I := 0 to High(InLR) do
      InLR[I] := Random - 0.5;
    A.Tap := @TA[0]; A.InLR := @InLR[0]; A.OutLR := @OA[0]; A.Count := 64;
    B.Tap := @TB[0]; B.InLR := @InLR[0]; B.OutLR := @OB[0]; B.Count := 64;
    FdnBlock(@A);
    FdnBlockPas(@B);
    for I := 0 to High(TA) do
      D := Max(D, Abs(TA[I] - TB[I]));
    for I := 0 to High(OA) do
      D := Max(D, Abs(OA[I] - OB[I]));
  end;
  for I := 0 to 7 do
    D := Max(D, Abs(A.LP[I] - B.LP[I]));
  if D < 1E-5 then
    Result := Format('Hall-Kern (FDN, SIMD gegen Pascal): max. Abweichung %.1e', [D])
  else
    Result := Format('Hall-Kern (FDN): ABWEICHUNG %.3e gegenueber Pascal!', [D]);
  // Rechenzeit des ganzen Halls: 10 s Audio
  Rv := TReverb.Create;
  try
    QueryPerformanceFrequency(F);
    QueryPerformanceCounter(T0);
    for Pass := 0 to (441000 div 512) - 1 do
    begin
      for I := 0 to High(IO) do
        IO[I] := (Random - 0.5) * 0.1;
      Rv.Process(@IO[0], 512, 0.7, 4, 0.4, 20, 1, 0.3);
    end;
    QueryPerformanceCounter(T1);
    Result := Result + Format(sLineBreak + 'Hall (%s): 10 s Audio in %.1f ms = %.2f %% CPU',
      [DSPPathName, (T1 - T0) * 1000 / F, (T1 - T0) * 100 / F / 10]);
  finally
    Rv.Free;
  end;
end;

{ Belastung der Ausgangsstufe: +6 dB, volle Saettigung, starkes Echo, 8 Noten.
  Ausgang muss unter 0 dBFS bleiben; der groesste Sprung zwischen zwei Samples zeigt Knackser. }
function CheckOutputStage: string;
var
  E: TGranularEngine;
  L, R, InL: array[0..511] of Single;
  B, I, N, Pass: Integer;
  Peak, Jump, Prev: Double;
begin
  Result := '';
  for Pass := 0 to 1 do
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpVolume, PlainToParam(gpVolume, 6));
      E.SetParamById(gpDensity, PlainToParam(gpDensity, 300));
      E.SetParamById(gpGrainSize, PlainToParam(gpGrainSize, 200));
      E.SetParamById(gpSpread, 0);
      E.SetParamById(gpPitch, PlainToParam(gpPitch, -12));
      E.SetParamById(gpEchoOn, 1);
      E.SetParamById(gpEchoFeedback, PlainToParam(gpEchoFeedback, 90));
      E.SetParamById(gpEchoMix, PlainToParam(gpEchoMix, 100));
      E.SetParamById(gpLimiter, Pass);       // 0 = Limiter aus (nur weicher Clipper), 1 = an
      for N := 0 to 7 do
        E.NoteOn(48 + N * 3, 1.0);
      FillChar(InL, SizeOf(InL), 0);
      Peak := 0; Jump := 0; Prev := 0;
      for B := 0 to (SR * 4) div 512 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        for I := 0 to 511 do
        begin
          Peak := Max(Peak, Abs(L[I]));
          Jump := Max(Jump, Abs(L[I] - Prev));
          Prev := L[I];
        end;
      end;
    finally
      E.Free;
    end;
    if Pass = 0 then Result := Result + 'Ausgangsstufe ohne Limiter: ' else Result := Result + sLineBreak + 'Ausgangsstufe mit Limiter:  ';
    Result := Result + Format('Spitze %.3f (%.2f dBFS) %s',
      [Peak, 20 * Log10(Max(Peak, 1E-9)), IfThen(Peak < 0.99, 'OK', 'UEBERSTEUERT!')]);
  end;
end;

{ Trigger "Ausgang > Schwelle": Note an/aus im Wechsel -> Ereignisse und LFO-Starts zaehlen }
{ Polyphone Modulation: LFO 1 (Neustart "Note an") -> Pitch. Zwei versetzt gespielte Noten muessen
  verschiedene Pitch-Werte haben (eigene Phase), der globale Pitch bleibt beim Grundwert. }
function CheckPolyMod: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, V1, V2: Integer;
  P1, P2, PG: Double;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));      // Note an
    E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 1));
    E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
    E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
    E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 50));
    E.NoteOn(60, 0.8);
    for B := 0 to 10 do E.Process(nil, nil, @L[0], @R[0], 512);     // ~0,13 s
    E.NoteOn(64, 0.8);
    for B := 0 to 10 do E.Process(nil, nil, @L[0], @R[0], 512);
    V1 := E.VoiceOfNote(60);
    V2 := E.VoiceOfNote(64);
    P1 := E.VoiceValue(V1, gpPitch);
    P2 := E.VoiceValue(V2, gpPitch);
    PG := E.EffParam[Ord(gpPitch)];
  finally
    E.Free;
  end;
  Result := Format('Polyphone Modulation: Note 60 Pitch %.2f st, Note 64 Pitch %.2f st, global %.3f (normiert) -> %s',
    [P1, P2, PG, IfThen((Abs(P1 - P2) > 0.3) and (Abs(PG - 0.5) < 0.01), 'je Note OK', 'FEHLER')]);
end;

{ Morph-Art 'Zwei Klaenge': A ohne Arp, B mit Arp. Morph 0 muss exakt A sein, Morph 100 exakt B
  (eigener Arp, kein Umschalten der Schalter fuer beide Klaenge zugleich) }
function CheckMorphLayers: string;
const
  BLOCKS = 60;
var
  RefA, RefB, OutA, OutB: TArray<Single>;

  procedure Setup(E: TGranularEngine; Arp: Boolean);
  begin
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), Ord(Arp)));
  end;

  function Run(E: TGranularEngine): TArray<Single>;
  var
    B: Integer;
    L, R: array[0..511] of Single;
  begin
    SetLength(Result, BLOCKS * 512);
    E.Process(nil, nil, @L[0], @R[0], 512);   // Vorlauf: Wirkwerte (Arp an) stehen vor dem ersten Anschlag
    E.NoteOn(60, 0.8);
    E.NoteOn(64, 0.8);
    for B := 0 to BLOCKS - 1 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      Move(L[0], Result[B * 512], 512 * SizeOf(Single));
    end;
  end;

  function Layered(Morph: Single): TArray<Single>;
  var
    E: TGranularEngine;
  begin
    E := TGranularEngine.Create;
    try
      Setup(E, True);
      E.StoreMorphTarget;                                   // B: mit Arp
      E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), 0)); // A: ohne Arp
      E.SetParamById(gpMorphMode, StepToParam(Ord(gpMorphMode), 1));
      E.SetParamById(gpMorph, Morph);
      Result := Run(E);
    finally
      E.Free;
    end;
  end;

  function Single1(Arp: Boolean): TArray<Single>;
  var
    E: TGranularEngine;
  begin
    E := TGranularEngine.Create;
    try
      Setup(E, Arp);
      Result := Run(E);
    finally
      E.Free;
    end;
  end;

  function MaxDiff(const X, Y: TArray<Single>): Double;
  var
    I: Integer;
  begin
    Result := 0;
    for I := 1024 to High(X) do      // erster Subblock: Einblend-Rampe
      Result := Max(Result, Abs(X[I] - Y[I]));
  end;

  function Peak(const X: TArray<Single>): Double;
  var
    I: Integer;
  begin
    Result := 0;
    for I := 0 to High(X) do
      Result := Max(Result, Abs(X[I]));
  end;

var
  DA, DB, DAB: Double;
begin
  RefA := Single1(False);
  RefB := Single1(True);
  OutA := Layered(0);
  OutB := Layered(1);
  DA := MaxDiff(OutA, RefA);
  DB := MaxDiff(OutB, RefB);
  DAB := MaxDiff(RefA, RefB);
  Result := Format('Morph zwei Klaenge: Morph 0 vs. A allein %.1E, Morph 100 vs. B allein %.1E (A/B unterscheiden sich um %.2f, Spitze %.2f) -> %s',
    [DA, DB, DAB, Peak(RefA), IfThen((DA < 1E-4) and (DB < 1E-4) and (DAB > 0.05), 'getrennt OK', 'FEHLER')]);
end;

{ Noten-LFO (One-Shot, Neustart bei Note an) auf Attack und Filter-Kontur: eine zweite Note darf die
  Modulation der ersten nicht neu starten - Wert der ersten Note mit und ohne zweite Note gleich }
function CheckNoteLfoIsolation: string;

  function Run(Second: Boolean; Id: TGranularParamId): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));      // Note an
      E.SetParamById(gpLfo1Once, StepToParam(Ord(gpLfo1Once), 1));      // One-Shot
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 0.5));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(Id) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 40));
      E.NoteOn(60, 0.8);
      for B := 0 to 40 do E.Process(nil, nil, @L[0], @R[0], 512);     // ~0,5 s
      if Second then
        E.NoteOn(64, 0.8);
      for B := 0 to 20 do E.Process(nil, nil, @L[0], @R[0], 512);
      Result := E.VoiceValue(E.VoiceOfNote(60), Id);
    finally
      E.Free;
    end;
  end;

var
  A1, A2, C1, C2, R1, R2: Double;
begin
  A1 := Run(False, gpAttack);    A2 := Run(True, gpAttack);
  C1 := Run(False, gpFltContour); C2 := Run(True, gpFltContour);
  R1 := Run(False, gpLfo2Rate);  R2 := Run(True, gpLfo2Rate);
  Result := Format('Noten-LFO je Note: Attack der 1. Note %.1f / mit 2. Note %.1f ms, Kontur %.1f / %.1f %%, LFO2-Rate %.3f / %.3f Hz -> %s',
    [A1, A2, C1, C2, R1, R2, IfThen((Abs(A1 - A2) < 1E-3) and (Abs(C1 - C2) < 1E-3) and (Abs(R1 - R2) < 1E-4), 'unabhaengig OK', 'FEHLER')]);
end;

{ Freier LFO (Neustart 'frei') laeuft global durch: eine kurze Note uebernimmt den aktuellen Wert
  des durchlaufenden LFOs (keinen Neustart bei 0), mit und ohne Noten-Modulation in anderen Zeilen }
function CheckFreeLfo: string;

  function Run(WithNoteRow: Boolean; StartBlock: Integer; out GlobalV: Double): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 1));      // 1 Hz, frei
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 50));
      if WithNoteRow then
      begin
        E.SetParam(SlotSourceIndex(1), StepToParam(SlotSourceIndex(1), Ord(msVelocity)));
        E.SetParam(SlotDestIndex(1), StepToParam(SlotDestIndex(1), Ord(gpVolume) + 1));
        E.SetParam(SlotAmountIndex(1), PlainToParam(SlotAmountIndex(1), 10));
      end;
      for B := 0 to StartBlock do E.Process(nil, nil, @L[0], @R[0], 512);
      E.NoteOn(60, 0.8);
      for B := 0 to 1 do E.Process(nil, nil, @L[0], @R[0], 512);
      GlobalV := ParamToPlain(gpPitch, E.EffParam[Ord(gpPitch)]);
      Result := E.VoiceValue(E.VoiceOfNote(60), gpPitch);
    finally
      E.Free;
    end;
  end;

var
  V1, V2, V3, G1, G2, G3: Double;
begin
  V1 := Run(False, 10, G1);
  V2 := Run(True, 10, G2);
  V3 := Run(True, 30, G3);
  Result := Format('Freier LFO: Note nach 0,13 s Pitch %.2f (global %.2f), mit Noten-Zeile %.2f (%.2f), nach 0,36 s %.2f (%.2f) -> %s',
    [V1, G1, V2, G2, V3, G3, IfThen((Abs(V1 - G1) < 0.01) and (Abs(V2 - G2) < 0.01) and (Abs(V3 - G3) < 0.01) and
      (Abs(V3 - V2) > 1), 'laeuft durch OK', 'FEHLER')]);
end;

{ Oszillator 1, 2 und 3 haben denselben Aufbau: jeder allein (gleiche Einstellung, FM-Welle mit
  eigener Huellkurve, eigenem Filter, Noten-Modulation auf den Pegel) muss bitgleich klingen }
function CheckOsc123: string;

  function Run(O: Integer): TArray<Single>;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
    P: TOscParamIds;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
      P := OSC_P[O];
      E.SetParamById(P.On_, StepToParam(Ord(P.On_), 1));
      E.SetParamById(P.Wave, StepToParam(Ord(P.Wave), 4));
      E.SetParamById(P.FmEnvOn, StepToParam(Ord(P.FmEnvOn), 1));
      E.SetParamById(P.FltOn, StepToParam(Ord(P.FltOn), 1));
      E.SetParamById(P.FltCutoff, PlainToParam(P.FltCutoff, 900));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msVelocity)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(P.Level) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 30));
      SetLength(Result, 40 * 512);
      E.NoteOn(60, 0.9);
      E.NoteOn(67, 0.4);
      for B := 0 to 39 do
      begin
        if B = 25 then E.NoteOff(60);
        E.Process(nil, nil, @L[0], @R[0], 512);
        Move(L[0], Result[B * 512], 512 * SizeOf(Single));
      end;
    finally
      E.Free;
    end;
  end;

var
  A, B2, B3: TArray<Single>;
  I: Integer;
  D2, D3, Pk: Double;
begin
  A := Run(0); B2 := Run(1); B3 := Run(2);
  D2 := 0; D3 := 0; Pk := 0;
  for I := 0 to High(A) do
  begin
    D2 := Max(D2, Abs(A[I] - B2[I]));
    D3 := Max(D3, Abs(A[I] - B3[I]));
    Pk := Max(Pk, Abs(A[I]));
  end;
  Result := Format('Oszillatoren 1/2/3 gleich aufgebaut: Abweichung Osz 2 %.1E, Osz 3 %.1E (Spitze %.2f) -> %s',
    [D2, D3, Pk, IfThen((D2 = 0) and (D3 = 0) and (Pk > 0.01), 'OK', 'FEHLER')]);
end;

{ Grain-Pegel regelt nur die Grains: Grains aus + Osz 1 -> Grain-Pegel -60 dB darf nichts aendern;
  Grains allein -> -60 dB = still }
function CheckGrainLevel: string;

  function Run(Grains, Osc: Boolean; LevelDb: Double): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B, I: Integer;
  begin
    Result := 0;
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), Ord(Grains)));
      E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), Ord(Osc)));
      E.SetParamById(gpGrainLevel, PlainToParam(gpGrainLevel, LevelDb));
      E.NoteOn(60, 0.8);
      for B := 0 to 30 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        if B > 5 then
          for I := 0 to 511 do
            Result := Result + Sqr(L[I]);
      end;
      Result := Sqrt(Result / (25 * 512));
    finally
      E.Free;
    end;
  end;

var
  O0, O1, G0, G1: Double;
begin
  O0 := Run(False, True, 0); O1 := Run(False, True, -60);
  G0 := Run(True, False, 0); G1 := Run(True, False, -60);
  Result := Format('Grain-Pegel: Osz 1 allein %.4f / mit Grain-Pegel -60 dB %.4f, Grains %.4f -> %.6f -> %s',
    [O0, O1, G0, G1, IfThen((Abs(O0 - O1) < 1E-6) and (O0 > 0.001) and (G0 > 0.001) and (G1 < G0 * 0.01), 'nur Grains OK', 'FEHLER')]);
end;

{ feste VST-Nummern: Zuordnung vollstaendig und eindeutig, Hin- und Rueckweg passen }
function CheckVstMap: string;
var
  I: Integer;
  Ok: Boolean;
begin
  Ok := VstMapComplete;
  for I := 0 to PARAM_COUNT - 1 do
    if (VstToParam(ParamToVst(I)) <> I) then
      Ok := False;
  // feste Nummern aus aelteren Versionen: Matrix-Zeilen 1..8 direkt nach VST_ORDER, dann VST_ADDED
  // (erste Nummer 199 + 40 = 239), Zeilen 9.. ganz hinten; LFO-/Matrix-Erweiterungen duerfen das nie verschieben
  if (ParamToVst(SlotSourceIndex(0)) <> Length(VST_ORDER)) or
     (ParamToVst(Ord(VST_ADDED[0])) <> Length(VST_ORDER) + MOD_SLOTS_V1 * MOD_STRIDE) or
     (ParamToVst(Ord(gpDlyOn)) <> 239) or
     ((MOD_SLOTS > MOD_SLOTS_V1) and
      (ParamToVst(SlotSourceIndex(MOD_SLOTS_V1)) <> Length(VST_ORDER) + MOD_SLOTS_V1 * MOD_STRIDE + VST_ADDED_COUNT)) then
    Ok := False;
  Result := Format('VST-Nummern: %d Regler, fest (VST_ORDER %d + Matrix %d + spaeter %d), VST 0 = %s, Matrix ab %d -> %s',
    [PARAM_COUNT, Length(VST_ORDER), MOD_SLOTS * MOD_STRIDE, VST_ADDED_COUNT, GetParamInfo(VstToParam(0)).Name,
     Length(VST_ORDER), IfThen(Ok, 'OK', 'FEHLER: neuen Regler hinten in VST_ADDED eintragen')]);
end;

{ Bearbeitungstausch A <-> B: der Klang bleibt gleich (Morph gespiegelt), zweimal tauschen = Ausgangslage }
function CheckSwapAB: string;

  function Run(Swaps: Integer): TArray<Single>;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B, K: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
      E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 0));
      E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), 1));
      E.StoreMorphTarget;                                       // B: Sinus mit Arp
      E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), 0));    // A: Saege ohne Arp
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 2));
      E.SetParamById(gpMorphMode, StepToParam(Ord(gpMorphMode), 1));
      E.SetParamById(gpMorph, 0.3);
      for K := 1 to Swaps do
        E.SwapMorphAB;
      SetLength(Result, 40 * 512);
      E.Process(nil, nil, @L[0], @R[0], 512);
      E.NoteOn(60, 0.8);
      E.NoteOn(64, 0.8);
      for B := 0 to 39 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        Move(L[0], Result[B * 512], 512 * SizeOf(Single));
      end;
    finally
      E.Free;
    end;
  end;

  function MaxDiff(const X, Y: TArray<Single>): Double;
  var
    I: Integer;
  begin
    Result := 0;
    for I := 1024 to High(X) do
      Result := Max(Result, Abs(X[I] - Y[I]));
  end;

var
  R0, R1, R2: TArray<Single>;
  D1, D2: Double;
begin
  R0 := Run(0); R1 := Run(1); R2 := Run(2);
  D1 := MaxDiff(R0, R1); D2 := MaxDiff(R0, R2);
  Result := Format('A <-> B tauschen: Klang nach Tausch Abweichung %.1E, nach zweimal %.1E -> %s',
    [D1, D2, IfThen((D1 < 1E-5) and (D2 = 0), 'OK', 'FEHLER')]);
end;

{ Mischpult-Pegel: Grains, Osz 1, Echo, Hall, Summe, Ausgang melden Pegel; Osz 2/3 (aus) bleiben 0 }
function CheckMixMeters: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, I: Integer;
  M: array[0..MIX_METERS - 1] of Single;
  Ok: Boolean;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 1));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 1));
    E.MetersOn := True;
    E.NoteOn(60, 0.8);
    for B := 0 to 40 do E.Process(nil, nil, @L[0], @R[0], 512);
    for I := 0 to MIX_METERS - 1 do
      M[I] := E.TakeMeter(I);
  finally
    E.Free;
  end;
  Ok := (M[MM_GRAINS] > 0.01) and (M[MM_OSC1] > 0.01) and (M[MM_OSC1 + 1] = 0) and (M[MM_OSC1 + 2] = 0) and
    (M[MM_ECHO] > 0.001) and (M[MM_HALL] > 0.001) and (M[MM_SUM] > 0.01) and (M[MM_OUT] > 0.01);
  Result := Format('Mischpult-Pegel: Grains %.2f, Osz %.2f/%.2f/%.2f, Echo %.2f, Hall %.2f, Summe %.2f, Ausgang %.2f -> %s',
    [M[0], M[1], M[2], M[3], M[4], M[5], M[6], M[7], IfThen(Ok, 'OK', 'FEHLER')]);
end;

{ umbenannte Matrix-Quelle: aeltere Presets mit 'Amp-Huellk.' laden als 'Grain-Huellk.' }
function CheckSourceRename: string;
var
  E, F: TGranularEngine;
  D, Old: TBytes;
  NewTxt, OldTxt: TBytes;
  I, P, N: Integer;
  Path: string;
  Src: Integer;
begin
  E := TGranularEngine.Create;
  F := TGranularEngine.Create;
  try
    E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msAmpEnv)));
    E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpEchoMix) + 1));
    D := SaveChunk(E, '');
    NewTxt := TEncoding.UTF8.GetBytes(MOD_SOURCE_NAMES[msAmpEnv]);   // aktueller Name (mit Umlaut)
    OldTxt := TEncoding.UTF8.GetBytes('Amp-Huellk.');
    // Laengenfeld + Text ersetzen (wie ein Preset aus der Zeit vor der Umbenennung)
    P := -1;
    for I := 4 to Length(D) - Length(NewTxt) do
      if CompareMem(@D[I], @NewTxt[0], Length(NewTxt)) then
      begin
        P := I - 4;
        Break;
      end;
    if P < 0 then
      Exit('Quelle umbenannt: Text im Chunk nicht gefunden -> FEHLER');
    N := Length(OldTxt);
    Old := Copy(D, 0, P) ;
    SetLength(Old, P + 4 + N);
    Move(N, Old[P], 4);
    Move(OldTxt[0], Old[P + 4], N);
    Old := Old + Copy(D, P + 4 + Length(NewTxt), MaxInt);
    if not LoadChunk(F, Old, Path) then
      Exit('Quelle umbenannt: alter Chunk nicht lesbar -> FEHLER');
    Src := ParamStep(SlotSourceIndex(0), F.GetParam(SlotSourceIndex(0)));
  finally
    E.Free;
    F.Free;
  end;
  Result := Format('Quelle umbenannt: altes Preset "Amp-Huellk." -> "%s" -> %s',
    [MOD_SOURCE_NAMES[TModSource(Src)], IfThen(Src = Ord(msAmpEnv), 'OK', 'FEHLER')]);
end;

{ Volllast: alles an, was Rechenzeit kostet - 32 gehaltene Noten, dichte lange Grains, drei FM-Oszillatoren
  mit eigenem Filter und Sync, Filter 1+2 je Note, vier Noten-LFOs mit Matrix-Zeilen je Note, Echo, Hall,
  EQ, Saettigung, Limiter; optional derselbe Klang zusaetzlich als B ('Zwei Klaenge', Morph 50 %).
  Liefert Rechenzeit fuer 10 s Audio (schneller Pfad) und die laengste Einzelblockzeit. }
function CheckFullLoad: string;

  procedure Setup(E: TGranularEngine);
  var
    O: Integer;
    P: TOscParamIds;
  begin
    E.SetParamById(gpGrainSize, PlainToParam(gpGrainSize, 250));
    E.SetParamById(gpDensity, PlainToParam(gpDensity, 120));
    E.SetParamById(gpSpray, PlainToParam(gpSpray, 20));
    E.SetParamById(gpSpread, PlainToParam(gpSpread, 90));
    E.SetParamById(gpSustain, PlainToParam(gpSustain, 100));
    E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));                     // HQ
    for O := 0 to OSC_COUNT - 1 do
    begin
      P := OSC_P[O];
      E.SetParamById(P.On_, StepToParam(Ord(P.On_), 1));
      E.SetParamById(P.Wave, StepToParam(Ord(P.Wave), 4));                          // FM
      E.SetParamById(P.Sync, PlainToParam(P.Sync, 30));
      E.SetParamById(P.FmEnvOn, StepToParam(Ord(P.FmEnvOn), 1));
      E.SetParamById(P.FltOn, StepToParam(Ord(P.FltOn), 1));
      E.SetParamById(P.Sustain, PlainToParam(P.Sustain, 100));
    end;
    E.SetParamById(gpFltOn, StepToParam(Ord(gpFltOn), 1));
    E.SetParamById(gpFlt2On, StepToParam(Ord(gpFlt2On), 1));
    E.SetParamById(gpFltRouting, StepToParam(Ord(gpFltRouting), 1));             // parallel (teurer)
    E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));
    E.SetParamById(gpLfo2Trig, StepToParam(Ord(gpLfo2Trig), 1));
    E.SetParamById(gpLfo3Trig, StepToParam(Ord(gpLfo3Trig), 1));
    E.SetParamById(gpLfo4Trig, StepToParam(Ord(gpLfo4Trig), 1));
    E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
    E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpFltCutoff) + 1));
    E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 20));
    E.SetParam(SlotSourceIndex(1), StepToParam(SlotSourceIndex(1), Ord(msLfo2)));
    E.SetParam(SlotDestIndex(1), StepToParam(SlotDestIndex(1), Ord(gpOscFmAmt) + 1));
    E.SetParam(SlotAmountIndex(1), PlainToParam(SlotAmountIndex(1), 20));
    E.SetParam(SlotSourceIndex(2), StepToParam(SlotSourceIndex(2), Ord(msLfo3)));
    E.SetParam(SlotDestIndex(2), StepToParam(SlotDestIndex(2), Ord(gpOsc2Level) + 1));
    E.SetParam(SlotAmountIndex(2), PlainToParam(SlotAmountIndex(2), 20));
    E.SetParam(SlotSourceIndex(3), StepToParam(SlotSourceIndex(3), Ord(msVelocity)));
    E.SetParam(SlotDestIndex(3), StepToParam(SlotDestIndex(3), Ord(gpOscAttack) + 1));
    E.SetParam(SlotAmountIndex(3), PlainToParam(SlotAmountIndex(3), 20));
    E.SetParam(SlotSourceIndex(4), StepToParam(SlotSourceIndex(4), Ord(msLfo4)));
    E.SetParam(SlotDestIndex(4), StepToParam(SlotDestIndex(4), Ord(gpPitch) + 1));
    E.SetParam(SlotAmountIndex(4), PlainToParam(SlotAmountIndex(4), 2));
    E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 1));
    E.SetParamById(gpEchoPitch, PlainToParam(gpEchoPitch, 3));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 1));
    E.SetParamById(gpEqOn, StepToParam(Ord(gpEqOn), 1));
    E.SetParamById(gpDrive, PlainToParam(gpDrive, 30));
    E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 1));
  end;

  procedure Measure1(Layer: Boolean; out MsTotal, MsWorst: Double; out Grains, Voices: Integer; Variant: Integer);
  const
    BLK = 512;
  var
    E: TGranularEngine;
    L, R: array[0..BLK - 1] of Single;
    B, I: Integer;
    F, T0, T1, Tb: Int64;
    Ms: Double;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      Setup(E);
      case Variant of        // Aufschluesselung: je ein Teil abgeschaltet
        1: E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
        2: for I := 0 to OSC_COUNT - 1 do E.SetParamById(OSC_P[I].On_, StepToParam(Ord(OSC_P[I].On_), 0));
        3: begin
             E.SetParamById(gpFltOn, StepToParam(Ord(gpFltOn), 0));
             E.SetParamById(gpFlt2On, StepToParam(Ord(gpFlt2On), 0));
             for I := 0 to OSC_COUNT - 1 do E.SetParamById(OSC_P[I].FltOn, StepToParam(Ord(OSC_P[I].FltOn), 0));
           end;
        4: for I := 0 to MOD_SLOTS - 1 do E.SetParam(SlotSourceIndex(I), 0);
        5: E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 0));
      end;
      if Layer then
      begin
        E.StoreMorphTarget;                                        // B = derselbe volle Klang
        E.SetParamById(gpMorphMode, StepToParam(Ord(gpMorphMode), 1));
        E.SetParamById(gpMorph, 0.5);
      end;
      E.Process(nil, nil, @L[0], @R[0], BLK);
      for I := 0 to 31 do
        E.NoteOn(36 + I * 2, 0.5 + 0.015 * I);                       // 32 Noten ueber 5 Oktaven
      for B := 0 to 20 do                                          // einschwingen (Grains fuellen sich)
        E.Process(nil, nil, @L[0], @R[0], BLK);
      QueryPerformanceFrequency(F);
      MsWorst := 0;
      QueryPerformanceCounter(T0);
      for B := 0 to Round(10 * SR / BLK) - 1 do
      begin
        QueryPerformanceCounter(Tb);
        E.Process(nil, nil, @L[0], @R[0], BLK);
        QueryPerformanceCounter(T1);
        Ms := (T1 - Tb) * 1000 / F;
        if Ms > MsWorst then MsWorst := Ms;
      end;
      MsTotal := (T1 - T0) * 1000 / F;
      Grains := E.ActiveGrains;
      Voices := 0;
      for I := 0 to 31 do
        if E.VoiceOfNote(36 + I * 2) >= 0 then Inc(Voices);
    finally
      E.Free;
    end;
  end;

  { Minimum aus drei Laeufen: robust gegen andere Last auf dem Rechner }
  procedure Measure(Layer: Boolean; out MsTotal, MsWorst: Double; out Grains, Voices: Integer; Variant: Integer = 0);
  var
    K: Integer;
    T, W: Double;
  begin
    MsTotal := 1E9; MsWorst := 1E9;
    for K := 1 to 3 do
    begin
      Measure1(Layer, T, W, Grains, Voices, Variant);
      MsTotal := Min(MsTotal, T);
      MsWorst := Min(MsWorst, W);
    end;
  end;

var
  T1, W1, T2, W2: Double;
  G1, V1, G2, V2, Gd, Vd: Integer;
  BlockMs, Wd: Double;
  D: array[1..5] of Double;
begin
  Measure(False, T1, W1, G1, V1);
  Measure(True, T2, W2, G2, V2);
  Measure(False, D[1], Wd, Gd, Vd, 1); Measure(False, D[2], Wd, Gd, Vd, 2); Measure(False, D[3], Wd, Gd, Vd, 3);
  Measure(False, D[4], Wd, Gd, Vd, 4); Measure(False, D[5], Wd, Gd, Vd, 5);
  BlockMs := 512 * 1000 / SR;     // Echtzeit-Budget je Block
  Result := Format('Volllast A: %d Stimmen, %d Grains: %.1f %% eines Kerns, laengster Block %.2f ms von %.2f ms' + sLineBreak +
    'Volllast A+B (Zwei Klaenge): %.1f %% eines Kerns, laengster Block %.2f ms von %.2f ms -> %s',
    [V1, G1, T1 / 100, W1, BlockMs, T2 / 100, W2, BlockMs,
     IfThen(W2 < BlockMs * 0.7, 'Reserve OK', 'KNAPP')]) + sLineBreak +
    Format('  Anteile (A, je ein Teil aus): Grains %.1f %%, Oszillatoren %.1f %%, Filter je Note %.1f %%, Matrix je Note %.1f %%, HQ %.1f %%',
    [(T1 - D[1]) / 100, (T1 - D[2]) / 100, (T1 - D[3]) / 100, (T1 - D[4]) / 100, (T1 - D[5]) / 100]);
end;

{ Huellkurven-Kern: SIMD gegen Pascal (geometrisch und linear) }
function CheckEnvSeg: string;
var
  A: TEnvSegArgs;
  R1, G1, R2, G2: array[0..63] of Single;
  I, K: Integer;
  Dmax: Double;
begin
  Dmax := 0;
  for K := 0 to 1 do
  begin
    for I := 0 to 3 do
    begin
      if K = 0 then
      begin
        A.Base4[I] := 0.4; A.D4[I] := 0.5 * Power(0.97, I + 1); A.Mul4[I] := Power(0.97, 4); A.Add4[I] := 0;
      end
      else
      begin
        A.Base4[I] := 0.1; A.D4[I] := 0.013 * (I + 1); A.Mul4[I] := 1; A.Add4[I] := 0.052;
      end;
      A.G4[I] := 0.37;
    end;
    A.Count := 16;
    A.Raw := @R1[0]; A.Gain := @G1[0];
    EnvSegPas(@A);
    A.Raw := @R2[0]; A.Gain := @G2[0];
    EnvSegSSE(@A);
    for I := 0 to 63 do
      Dmax := Max(Dmax, Max(Abs(R1[I] - R2[I]), Abs(G1[I] - G2[I])));
  end;
  Result := Format('Huellkurven-Kern (SIMD gegen Pascal): max. Abweichung %.1E -> %s', [Dmax, IfThen(Dmax < 1E-6, 'OK', 'FEHLER')]);
end;

{ Ereignis-Verzoegerung: LFO je Note (Neustart Note an) auf Pitch, Note an um 1/4 verzoegert (120 BPM = 0,5 s):
  vorher keine Modulation, danach schon; ohne Verzoegerung sofort }
function CheckEventDelay: string;

  function Run(SyncStep: Integer; Blocks: Integer): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpTempo, PlainToParam(gpTempo, 120));
      E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 5));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 5));
      E.SetParamById(gpDlyOnSync, StepToParam(Ord(gpDlyOnSync), SyncStep));
      E.NoteOn(60, 0.8);
      Result := 0;
      for B := 0 to Blocks - 1 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        Result := Max(Result, Abs(E.VoiceValue(E.VoiceOfNote(60), gpPitch)));   // groesster Ausschlag
      end;
    finally
      E.Free;
    end;
  end;

var
  Early, Late, NoDly: Double;
begin
  Early := Run(7, 38);    // 1/4 = 0,5 s; 38 Bloecke = 0,44 s
  Late := Run(7, 60);     // 0,70 s: Vibrato laeuft
  NoDly := Run(0, 12);    // ohne Verzoegerung: nach 0,14 s schon Ausschlag
  Result := Format('Ereignis-Verzoegerung: Note an um 1/4 verzoegert -> Pitch-Ausschlag vor 0,5 s %.3f st, danach %.3f st; ohne Verzoegerung %.3f st -> %s',
    [Early, Late, NoDly, IfThen((Early < 0.001) and (Late > 0.1) and (NoDly > 0.1), 'OK', 'FEHLER')]);
end;

{ Aus-Trigger: Noten-LFO (Start Note an, Stopp Note aus) auf Pitch - nach dem Loslassen keine Modulation
  mehr; ohne Stopp laeuft er im Release weiter. Globaler LFO (Start Tor, Stopp Note an) ruht vor dem ersten Start. }
function CheckLfoStop: string;

  function Run(StopStep: Integer): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpRelease, PlainToParam(gpRelease, 3000));
      E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));
      E.SetParamById(gpLfo1Stop, StepToParam(Ord(gpLfo1Stop), StopStep));
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 5));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 5));
      E.NoteOn(60, 0.8);
      for B := 0 to 20 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      E.NoteOff(60);
      Result := 0;
      for B := 0 to 30 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        if E.VoiceOfNote(60) >= 0 then
          Result := Max(Result, Abs(E.VoiceValue(E.VoiceOfNote(60), gpPitch)));
      end;
    finally
      E.Free;
    end;
  end;

  function RunGlobal: Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), LFO_TRIG_GATE));
      E.SetParamById(gpLfo1Stop, StepToParam(Ord(gpLfo1Stop), 1));
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 5));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 5));
      Result := 0;
      for B := 0 to 30 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        Result := Max(Result, Abs(E.SourceValue[msLfo1]));
      end;
    finally
      E.Free;
    end;
  end;

  { Stopp nach Zeit 1/4 (120 BPM = 0,5 s), Note gehalten: Ausschlag in Bloecken From..To }
  function RunTime(FromB, ToB: Integer): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B: Integer;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpTempo, PlainToParam(gpTempo, 120));
      E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));
      E.SetParamById(gpLfo1Stop, StepToParam(Ord(gpLfo1Stop), LFO_STOP_TIME));
      E.SetParamById(gpLfo1StopSync, StepToParam(Ord(gpLfo1StopSync), 7));
      E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 5));
      E.SetParam(SlotSourceIndex(0), StepToParam(SlotSourceIndex(0), Ord(msLfo1)));
      E.SetParam(SlotDestIndex(0), StepToParam(SlotDestIndex(0), Ord(gpPitch) + 1));
      E.SetParam(SlotAmountIndex(0), PlainToParam(SlotAmountIndex(0), 5));
      E.NoteOn(60, 0.8);
      Result := 0;
      for B := 0 to ToB do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        if B >= FromB then
          Result := Max(Result, Abs(E.VoiceValue(E.VoiceOfNote(60), gpPitch)));
      end;
    finally
      E.Free;
    end;
  end;

var
  Stop, Free, G, T1, T2: Double;
begin
  T1 := RunTime(5, 38);     // bis 0,44 s: laeuft
  T2 := RunTime(50, 80);    // ab 0,58 s: angehalten
  Stop := Run(2);
  Free := Run(0);
  G := RunGlobal;
  Result := Format('LFO-Stopp: Note aus haelt Noten-LFO an -> Ausschlag im Release %.3f st (ohne Stopp %.3f st); globaler LFO vor erstem Start %.3f -> %s',
    [Stop, Free, G, IfThen((Stop < 0.001) and (Free > 0.1) and (G < 0.001), 'OK', 'FEHLER')]) + sLineBreak +
    Format('LFO-Stopp nach Zeit 1/4: Ausschlag vorher %.3f st, danach %.3f st -> %s',
    [T1, T2, IfThen((T1 > 0.1) and (T2 < 0.001), 'OK', 'FEHLER')]);
end;

{ Partner waehlbar: LFO 3 startet, wenn LFO 1 (Partner) seinen Einmal-Durchlauf beendet (0,2 s) }
function CheckLfoPartner: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B: Integer;
  Before, After: Double;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), 1));
    E.SetParamById(gpLfo1Once, StepToParam(Ord(gpLfo1Once), 1));
    E.SetParamById(gpLfo1Rate, PlainToParam(gpLfo1Rate, 5));
    E.SetParamById(gpLfo3Trig, StepToParam(Ord(gpLfo3Trig), LFO_TRIG_OTHER_END));
    E.SetParamById(gpLfo3Partner, StepToParam(Ord(gpLfo3Partner), 0));
    E.SetParamById(gpLfo3Stop, StepToParam(Ord(gpLfo3Stop), 2));      // mit Stopp: wartet auf den Start
    E.SetParamById(gpLfo3Shape, StepToParam(Ord(gpLfo3Shape), 2));    // Saege: sofort Ausschlag
    E.SetParamById(gpLfo3Rate, PlainToParam(gpLfo3Rate, 0.5));
    E.NoteOn(60, 0.8);
    Before := 0; After := 0;
    for B := 0 to 40 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      if B < 14 then Before := Max(Before, Abs(E.SourceValue[msLfo3]))     // bis 0,16 s
      else if B > 22 then After := Max(After, Abs(E.SourceValue[msLfo3]));  // ab 0,27 s
    end;
  finally
    E.Free;
  end;
  Result := Format('LFO-Partner: LFO 3 wartet auf das Ende von LFO 1 -> vorher %.3f, danach %.3f -> %s',
    [Before, After, IfThen((Before < 0.001) and (After > 0.3), 'OK', 'FEHLER')]);
end;

{ Arp Latch: Akkord anschlagen und loslassen -> Arp spielt weiter; neue Taste ersetzt den Akkord }
{ MIDI-Learn: naechster Controller wird gelernt (Pedal nicht), steuert danach den Parameter;
  Neu-Lernen loest die alte Zuordnung }
{ Anlauf: Note beginnt bei 10 % (vor der Auswahl 50..60 %), laeuft hinein und bleibt dann in der
  Auswahl; Schleife hin und her kehrt am Ende um (Abspielkopf laeuft auch rueckwaerts) }
function CheckPreRoll: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  Ph: array[0..7] of Single;
  B: Integer;
  First, Prev, MinIn, MaxIn: Double;
  Back, Outside: Integer;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpSelStart, PlainToParam(gpSelStart, 50));
    E.SetParamById(gpSelEnd, PlainToParam(gpSelEnd, 60));
    E.SetParamById(gpPosition, PlainToParam(gpPosition, 0));
    E.SetParamById(gpSpray, PlainToParam(gpSpray, 0));
    E.SetParamById(gpScan, PlainToParam(gpScan, 1));
    E.SetParamById(gpSustain, PlainToParam(gpSustain, 100));
    E.SetParamById(gpPreOn, 1);
    E.SetParamById(gpPreStart, PlainToParam(gpPreStart, 10));
    E.SetParamById(gpLoopMode, StepToParam(Ord(gpLoopMode), 1));
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.NoteOn(60, 0.8);
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.GetPlayheads(Ph);
    First := Ph[0];
    Prev := First; Back := 0; Outside := 0; MinIn := 1; MaxIn := 0;
    for B := 0 to 800 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      if E.GetPlayheads(Ph) = 0 then Break;
      if B > 400 then
      begin
        if (Ph[0] < 0.499) or (Ph[0] > 0.601) then Inc(Outside);
        MinIn := Min(MinIn, Ph[0]);
        MaxIn := Max(MaxIn, Ph[0]);
        if Ph[0] < Prev - 1E-6 then Inc(Back);
      end;
      Prev := Ph[0];
    end;
  finally
    E.Free;
  end;
  Result := Format('Anlauf/Schleife: Start %.3f, spaeter in der Auswahl %.3f..%.3f (ausserhalb %d), rueckwaerts %d Bloecke -> %s',
    [First, MinIn, MaxIn, Outside, Back,
     IfThen((First > 0.09) and (First < 0.13) and (Outside = 0) and (Back > 20), 'OK', 'FEHLER')]);
end;

{ Rechenzeit der Summen-Effekte (Chorus, Phaser, Bitcrusher, Gate) im Verhaeltnis zu den Grains -
  Grundlage fuer das Gewicht der Zeile 'FX' im Reiter Leistung (Grains = 30) }
function CheckFxLoad: string;

  function TimeIt(Grains: Boolean; Fx: Integer): Double;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B, K: Integer;
    T0, T1, F: Int64;
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, IfThen(Grains, 1, 0));
      E.SetParamById(gpOscOn, 1);
      if Fx and 1 <> 0 then E.SetParamById(gpChoOn, 1);
      if Fx and 2 <> 0 then E.SetParamById(gpPhaOn, 1);
      if Fx and 4 <> 0 then E.SetParamById(gpCrushOn, 1);
      if Fx and 8 <> 0 then E.SetParamById(gpTgOn, 1);
      for K := 0 to 7 do
        E.NoteOn(48 + K * 3, 0.8);
      for B := 0 to 20 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      QueryPerformanceFrequency(F);
      QueryPerformanceCounter(T0);
      for B := 0 to 399 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      QueryPerformanceCounter(T1);
      Result := (T1 - T0) / F * 1000;
    finally
      E.Free;
    end;
  end;

var
  Base, DGr: Double;
  D: array[0..3] of Double;
  K: Integer;
begin
  Base := Min(TimeIt(False, 0), TimeIt(False, 0));
  for K := 0 to 3 do
    D[K] := Min(TimeIt(False, 1 shl K), TimeIt(False, 1 shl K)) - Base;
  DGr := Min(TimeIt(True, 0), TimeIt(True, 0)) - Base;
  Result := Format('FX-Last je 400 Bloecke: Chorus %.1f, Phaser %.1f, Bitcrusher %.1f, Gate %.1f ms; Grains (8 Noten) %.1f ms ' +
    '-> Gewicht FX %.1f (Grains = 30)',
    [D[0], D[1], D[2], D[3], DGr, 30 * (D[0] + D[1] + D[2] + D[3]) / Max(DGr, 0.001)]);
end;

{ LFO 5..8: LFO 5 -> Pitch moduliert; unbenutzte LFOs 6..8 werden nicht gerechnet; LFO 5 mit Start
  'Ende Partner-LFO' und Partner LFO 7 macht LFO 7 benutzt; Matrix-Zeile 20 wirkt wie Zeile 1 }
{ freie Makros: Makro 1 (S-Kurve) ueber zwei Matrix-Zeilen auf Pitch und Cutoff }
function CheckUserMacros: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  P0, P1, C0, C1, Src: Double;

  procedure SetRow(Slot: Integer; Dst: TGranularParamId);
  begin
    E.SetParam(SlotSourceIndex(Slot), StepToParam(SlotSourceIndex(Slot), Ord(msMacro1)));
    E.SetParam(SlotDestIndex(Slot), StepToParam(SlotDestIndex(Slot), Ord(Dst) + 1));
    E.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), 50));
    E.SetParam(SlotFactorIndex(Slot), StepToParam(SlotFactorIndex(Slot), MOD_FACTOR_DEFAULT));
  end;

begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    SetRow(3, gpPitch);
    SetRow(24, gpFltCutoff);
    E.SetParamById(gpUMac1Curve, StepToParam(Ord(gpUMac1Curve), 3));   // S-Kurve
    E.NoteOn(60, 0.8);
    E.Process(nil, nil, @L[0], @R[0], 512);
    P0 := E.EffParam[Ord(gpPitch)];
    C0 := E.EffParam[Ord(gpFltCutoff)];
    E.SetParamById(gpUMac1, PlainToParam(gpUMac1, 25));
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.Process(nil, nil, @L[0], @R[0], 512);
    Src := E.SourceValue[msMacro1];
    P1 := E.EffParam[Ord(gpPitch)];
    C1 := E.EffParam[Ord(gpFltCutoff)];
  finally
    E.Free;
  end;
  // S-Kurve bei 25 %: 0,25^2 * (3 - 0,5) = 0,15625
  Result := Format('Freie Makros: Makro 1 = 25 %% (S-Kurve) -> Quelle %.4f, Pitch %.3f -> %.3f, Cutoff %.3f -> %.3f -> %s',
    [Src, P0, P1, C0, C1, IfThen((Abs(Src - 0.15625) < 0.001) and (P1 > P0 + 0.01) and (C1 > C0 + 0.01), 'OK', 'FEHLER')]);
end;

{ Preset mit eingebetteten Samples: speichern, Original weg, in anderem Plugin-Ordner laden ->
  Sample liegt in 'Eigene Toene', Verweis zeigt darauf; alter Lesepfad (nur Chunk) klappt auch }
function CheckEmbedPreset: string;
var
  E: TGranularEngine;
  Root, DirA, DirB, Src, Fn, Path, Old: string;
  Bytes, Got, Data: TBytes;
  I: Integer;
  Ok, OkOld, OkPlain: Boolean;
begin
  Root := TPath.Combine(TPath.GetTempPath, 'GranularEmbedTest');
  if TDirectory.Exists(Root) then
    TDirectory.Delete(Root, True);
  DirA := TPath.Combine(Root, 'A');
  DirB := TPath.Combine(Root, 'B');
  ForceDirectories(DirA);
  ForceDirectories(DirB);
  SetLength(Bytes, 5000);
  for I := 0 to High(Bytes) do
    Bytes[I] := Byte(I * 7 + 3);
  Src := TPath.Combine(DirA, 'Mein Ton.wav');
  TFile.WriteAllBytes(Src, Bytes);
  Fn := TPath.Combine(Root, 'Test.gspreset');
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.SetZoneRef(2, Src);
    SaveChunkToFile(E, Src, Fn, DirA, True);
    TFile.Delete(Src);
    E.SetZoneRef(2, '');
    Ok := LoadChunkFromFile(E, Fn, Path, DirB);
    Got := nil;
    if FileExists(TPath.Combine(DirB, 'Eigene Toene\Mein Ton.wav')) then
      Got := TFile.ReadAllBytes(TPath.Combine(DirB, 'Eigene Toene\Mein Ton.wav'));
    Ok := Ok and SameText(Path, 'Eigene Toene\Mein Ton.wav') and SameText(E.GetZoneRef(2), Path) and
      (Length(Got) = Length(Bytes)) and CompareMem(@Got[0], @Bytes[0], Length(Bytes));
    // aeltere Version: liest die ganze Datei als Chunk (Anhang wird ueberlesen)
    Data := TFile.ReadAllBytes(Fn);
    OkOld := LoadChunk(E, Data, Old) and SameText(Old, Src);
    // ohne Einbetten: Datei endet nicht mit dem Anhang
    SaveChunkToFile(E, 'x.wav', Fn, DirA, False);
    Data := TFile.ReadAllBytes(Fn);
    OkPlain := (Length(Data) > 4) and not CompareMem(@Data[Length(Data) - 4], PAnsiChar('GSEB'), 4);
  finally
    E.Free;
    try TDirectory.Delete(Root, True); except end;
  end;
  Result := Format('Preset mit eingebetteten Samples: ausgepackt %s, alter Leser %s, ohne Einbetten unveraendert %s -> %s',
    [BoolToStr(Ok, True), BoolToStr(OkOld, True), BoolToStr(OkPlain, True), IfThen(Ok and OkOld and OkPlain, 'OK', 'FEHLER')]);
end;

{ Test-Host laedt GranularSynth als VST3 (.vst3 = dieselbe DLL): Note, Ton, Zustand, Fenstergroesse }
function CheckHostVst3: string;
var
  H: TVstHostPlugin;
  Dir, F: string;
  L, R: array[0..511] of Single;
  B, I: Integer;
  Peak: Double;
  St: TBytes;
  Ok: Boolean;
begin
  Dir := TPath.Combine(TPath.GetTempPath, 'GranularV3Host');
  ForceDirectories(Dir);
  F := TPath.Combine(Dir, 'GranularSynth.vst3');
  TFile.Copy(ExtractFilePath(ParamStr(0)) + 'GranularSynth.dll', F, True);
  H := TVstHostPlugin.Create;
  try
    try
      H.Load(F, SR, 512);
    except
      on E: Exception do
        Exit('Test-Host mit VST3: Laden fehlgeschlagen (' + E.Message + ') -> FEHLER');
    end;
    Ok := H.IsVst3 and H.Loaded and H.IsSynth;
    H.AddMidi($90, 60, 100, 0);
    Peak := 0;
    for B := 0 to 39 do
    begin
      H.Process(nil, nil, @L[0], @R[0], 512);
      for I := 0 to 511 do
        Peak := Max(Peak, Abs(L[I]));
    end;
    H.AddMidi($80, 60, 0, 0);
    H.Process(nil, nil, @L[0], @R[0], 512);
    St := H.SaveState;
    Ok := Ok and (Peak > 0.001) and (Length(St) > 100) and H.LoadState(St);
    Result := Format('Test-Host mit VST3: %s, Synth %s, Ton %.3f, Zustand %d Byte -> %s',
      [H.Name, BoolToStr(H.IsSynth, True), Peak, Length(St), IfThen(Ok, 'OK', 'FEHLER')]);
    H.Unload;
  finally
    H.Free;
    try TDirectory.Delete(Dir, True); except end;
  end;
end;

{ Uebersetzung: Oberflaeche einmal aufbauen und alle Reglernamen, Stufen und das Info-Fenster durch Tr
  schicken. Jeder Text, der in einer Sprachdatei (Sprachen\*.txt) fehlt, wird gemeldet und nach
  bin\<Plattform>\lang_fehlend_<Kuerzel>.txt geschrieben. Ohne Sprachdatei (Kuerzel 'alle') entsteht
  die vollstaendige Liste aller Texte. Neue Funktionen ohne Uebersetzung fallen so sofort auf. }
function LangRun(const Code, FileName: string): Integer;
var
  E: TGranularEngine;
  Frm: TForm;
  I, K: Integer;
  Miss: TArray<string>;
  L: TStringList;
  Rows: TArray<TInfoRow>;
begin
  LangCollect(True);
  LangLoadFile(Code, FileName);
  E := TGranularEngine.Create;
  Frm := TForm.CreateNew(nil);
  try
    E.SetSampleRate(SR);
    TGranularEditor.Create(Frm, Frm, E);
    for I := 0 to PARAM_COUNT - 1 do
    begin
      Tr(GetParamInfo(I).Name);
      if GetParamInfo(I).Curve = pcStepped then
        for K := 0 to GetParamInfo(I).Steps - 1 do
          Tr(StepName(I, K));
    end;
    Rows := BuildInfo(E);       // uebersetzt seine Textteile selbst (Tr je Baustein)
  finally
    Frm.Free;
    E.Free;
  end;
  Miss := LangMissing;
  L := TStringList.Create;
  try
    for I := 0 to High(Miss) do
      L.Add(StringReplace(StringReplace(Miss[I], #13#10, '\n', [rfReplaceAll]), #10, '\n', [rfReplaceAll]));
    L.SaveToFile(ExtractFilePath(ParamStr(0)) + 'lang_fehlend_' + Code + '.txt', TEncoding.UTF8);
  finally
    L.Free;
  end;
  LangCollect(False);
  LangLoadFile('de', '');
  Result := Length(Miss);
end;

function CheckLanguage: string;
var
  Dir: string;
  SR: TSearchRec;
  N: Integer;
  Bad: Boolean;
begin
  Dir := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\' + LANG_DIR + '\');
  N := LangRun('alle', '');
  Result := Format('Uebersetzung: %d Texte der Oberflaeche', [N]);
  Bad := False;
  if FindFirst(Dir + '*.txt', faAnyFile, SR) = 0 then
  try
    repeat
      if SR.Name[1] = '_' then
        Continue;                     // Arbeitslisten (_fehlend_*, _alle_texte), keine Sprache
      N := LangRun(ChangeFileExt(SR.Name, ''), Dir + SR.Name);
      Result := Result + Format(', %s: %d fehlen', [ChangeFileExt(SR.Name, ''), N]);
      Bad := Bad or (N > 0);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := Result + IfThen(Bad, ' (Liste: lang_fehlend_<Sprache>.txt) -> FEHLER', ' -> OK');
end;

function CheckLfo58: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, Slot: Integer;
  Mn, Mx, V: Double;
  Used6, Used7: Boolean;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    Slot := 19;                                     // Zeile 20 (neuer Bereich)
    E.SetParam(SlotSourceIndex(Slot), StepToParam(SlotSourceIndex(Slot), Ord(msLfo5)));
    E.SetParam(SlotDestIndex(Slot), StepToParam(SlotDestIndex(Slot), Ord(gpPitch) + 1));
    E.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), 100));
    E.SetParam(SlotFactorIndex(Slot), StepToParam(SlotFactorIndex(Slot), MOD_FACTOR_DEFAULT));
    E.SetParamById(gpLfo5Rate, PlainToParam(gpLfo5Rate, 3));
    E.NoteOn(60, 0.8);
    Mn := 1E9; Mx := -1E9;
    for B := 0 to 86 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      V := E.EffParam[Ord(gpPitch)];
      Mn := Min(Mn, V); Mx := Max(Mx, V);
    end;
    Used6 := E.LfoUsed(5);
    // LFO 5 wartet auf das Ende von LFO 7 -> LFO 7 wird gebraucht
    E.SetParamById(gpLfo5Trig, StepToParam(Ord(gpLfo5Trig), LFO_TRIG_OTHER_END));
    E.SetParamById(gpLfo5Partner, StepToParam(Ord(gpLfo5Partner), 6));
    E.Process(nil, nil, @L[0], @R[0], 512);
    Used7 := E.LfoUsed(6);
  finally
    E.Free;
  end;
  Result := Format('LFO 5-8: LFO 5 ueber Zeile 20 -> Pitch-Ausschlag %.3f; LFO 6 gerechnet: %s; LFO 7 als Partner gerechnet: %s -> %s',
    [Mx - Mn, BoolToStr(Used6, True), BoolToStr(Used7, True),
     IfThen((Mx - Mn > 0.05) and not Used6 and Used7, 'OK', 'FEHLER')]);
end;

{ --- VST3: die DLL wie eine DAW ueber GetPluginFactory ansprechen (eigener Mini-Host) --- }

type
  TV3Events = class(TInterfacedObject, IEventList)
    FEv: array of TVst3Event;
    function getEventCount: Int32; stdcall;
    function getEvent(index: Int32; var e: TVst3Event): TResult; stdcall;
    function addEvent(var e: TVst3Event): TResult; stdcall;
  end;

  TV3Stream = class(TInterfacedObject, IBStream)
    FData: TBytes;
    FPos: Integer;
    function read(buffer: Pointer; numBytes: Int32; numBytesRead: PInteger): TResult; stdcall;
    function write(buffer: Pointer; numBytes: Int32; numBytesWritten: PInteger): TResult; stdcall;
    function seek(pos: Int64; mode: Int32; newPos: PInt64): TResult; stdcall;
    function tell(pos: PInt64): TResult; stdcall;
  end;

function TV3Events.getEventCount: Int32;
begin
  Result := Length(FEv);
end;

function TV3Events.getEvent(index: Int32; var e: TVst3Event): TResult;
begin
  if (index < 0) or (index > High(FEv)) then
    Exit(kInvalidArgument);
  e := FEv[index];
  Result := kResultOk;
end;

function TV3Events.addEvent(var e: TVst3Event): TResult;
begin
  FEv := FEv + [e];
  Result := kResultOk;
end;

function TV3Stream.read(buffer: Pointer; numBytes: Int32; numBytesRead: PInteger): TResult;
var
  N: Integer;
begin
  N := Max(0, Min(numBytes, Length(FData) - FPos));
  if N > 0 then
    Move(FData[FPos], buffer^, N);
  Inc(FPos, N);
  if numBytesRead <> nil then
    numBytesRead^ := N;
  Result := kResultOk;
end;

function TV3Stream.write(buffer: Pointer; numBytes: Int32; numBytesWritten: PInteger): TResult;
begin
  if FPos + numBytes > Length(FData) then
    SetLength(FData, FPos + numBytes);
  Move(buffer^, FData[FPos], numBytes);
  Inc(FPos, numBytes);
  if numBytesWritten <> nil then
    numBytesWritten^ := numBytes;
  Result := kResultOk;
end;

function TV3Stream.seek(pos: Int64; mode: Int32; newPos: PInt64): TResult;
begin
  case mode of
    kIBSeekSet: FPos := pos;
    kIBSeekCur: FPos := FPos + pos;
  else
    FPos := Length(FData) + pos;
  end;
  if newPos <> nil then
    newPos^ := FPos;
  Result := kResultOk;
end;

function TV3Stream.tell(pos: PInt64): TResult;
begin
  if pos <> nil then
    pos^ := FPos;
  Result := kResultOk;
end;

function CheckVst3: string;
const
  CID_SYNTH: TGUID = '{8F3A2C61-4B7D-4E19-A6C2-1D5E9B07F3A1}';
  CID_FX: TGUID = '{8F3A2C61-4B7D-4E19-A6C2-1D5E9B07F3A2}';
  N = 512;
type
  TGetFactory = function: Pointer; stdcall;
var
  Lib: HMODULE;
  GetF: TGetFactory;
  Fac: IPluginFactory;
  Fac2: IPluginFactory2;
  Ci: TClassInfo2;
  Obj: Pointer;
  Comp, Comp2: IComponent;
  AP: IAudioProcessor;
  EC, EC2: IEditController;
  MM: IMidiMapping;
  Setup: TProcessSetup;
  Data: TProcessData;
  OutBus: TAudioBusBuffers;
  InBus: array[0..1] of TAudioBusBuffers;
  OutCh: array[0..1] of PSingle;
  InCh: array[0..3] of PSingle;
  L, R, Z: array[0..N - 1] of Single;
  Evs: TV3Events;
  EvI: IEventList;
  St: TV3Stream;
  StI: IBStream;
  B, I: Integer;
  Peak, V1, V2: Double;
  Names, Bad: string;
  View: Pointer;
  Rect: TViewRect;
  MidiId: TParamID;
  Info: TParameterInfo;
  BI: TBusInfo;
  IID: TGUID;
begin
  Bad := '';
  Lib := LoadLibrary(PChar(ExtractFilePath(ParamStr(0)) + 'GranularSynth.dll'));
  if Lib = 0 then
    Exit('VST3: GranularSynth.dll nicht gefunden -> FEHLER');
  @GetF := GetProcAddress(Lib, 'GetPluginFactory');
  if not Assigned(GetF) then
    Exit('VST3: Export GetPluginFactory fehlt -> FEHLER');
  if GetProcAddress(Lib, 'InitDll') = nil then
    Bad := Bad + ' InitDll';
  Pointer(Fac) := GetF;                       // gehoert uns (AddRef in der DLL)
  if not Supports(Fac, IPluginFactory2, Fac2) then
    Exit('VST3: IPluginFactory2 fehlt -> FEHLER');
  Names := '';
  for I := 0 to Fac.countClasses - 1 do
    if Fac2.getClassInfo2(I, @Ci) = kResultOk then
      Names := Names + Format('%s [%s]; ', [string(AnsiString(Ci.name)), string(AnsiString(Ci.subCategories))]);
  // Instanz wie eine DAW: IComponent anfordern, Prozessor und Controller daraus holen
  IID := IComponent;
  if Fac.createInstance(@CID_SYNTH, @IID, Obj) <> kResultOk then
    Exit('VST3: createInstance fehlgeschlagen -> FEHLER');
  Pointer(Comp) := Obj;
  Comp.initialize(nil);
  if not Supports(Comp, IAudioProcessor, AP) then Bad := Bad + ' IAudioProcessor';
  if not Supports(Comp, IEditController, EC) then Bad := Bad + ' IEditController';
  if not Supports(Comp, IMidiMapping, MM) then Bad := Bad + ' IMidiMapping';
  if Bad <> '' then
    Exit('VST3: Schnittstellen fehlen:' + Bad + ' -> FEHLER');
  if Comp.getBusCount(kAudio, kInput) <> 2 then Bad := Bad + ' Eingangsbusse';
  if (Comp.getBusInfo(kAudio, kOutput, 0, BI) <> kResultOk) or (BI.channelCount <> 2) then Bad := Bad + ' Ausgangsbus';
  if EC.getParameterCount <> PARAM_COUNT + kCountCtrlNumber then Bad := Bad + ' Parameterzahl';
  if (EC.getParameterInfo(0, Info) <> kResultOk) or (Info.id <> 0) or (Info.title[0] = #0) then Bad := Bad + ' Parameterinfo';
  if (MM.getMidiControllerAssignment(0, 0, 1, MidiId) <> kResultOk) or (MidiId = 0) then Bad := Bad + ' MIDI-Zuordnung';
  FillChar(Setup, SizeOf(Setup), 0);
  Setup.processMode := kRealtime;
  Setup.symbolicSampleSize := kSample32;
  Setup.maxSamplesPerBlock := N;
  Setup.sampleRate := 44100;
  AP.setupProcessing(Setup);
  Comp.setActive(1);
  AP.setProcessing(1);
  // Note an ueber die Ereignisliste, dann 40 Bloecke rechnen
  Evs := TV3Events.Create;
  EvI := Evs;
  SetLength(Evs.FEv, 1);
  FillChar(Evs.FEv[0], SizeOf(TVst3Event), 0);
  Evs.FEv[0].eventType := kNoteOnEvent;
  Evs.FEv[0].onPitch := 60;
  Evs.FEv[0].onVelocity := 0.8;
  FillChar(Z, SizeOf(Z), 0);
  OutCh[0] := @L[0]; OutCh[1] := @R[0];
  for I := 0 to 3 do InCh[I] := @Z[0];
  OutBus.numChannels := 2; OutBus.silenceFlags := 0; OutBus.channelBuffers32 := @OutCh[0];
  InBus[0].numChannels := 2; InBus[0].silenceFlags := 0; InBus[0].channelBuffers32 := @InCh[0];
  InBus[1].numChannels := 2; InBus[1].silenceFlags := 0; InBus[1].channelBuffers32 := @InCh[2];
  Peak := 0;
  for B := 0 to 39 do
  begin
    FillChar(Data, SizeOf(Data), 0);
    Data.processMode := kRealtime;
    Data.symbolicSampleSize := kSample32;
    Data.numSamples := N;
    Data.numInputs := 2;
    Data.numOutputs := 1;
    Data.inputs := @InBus[0];
    Data.outputs := @OutBus;
    if B = 0 then
      Data.inputEvents := Pointer(EvI);
    AP.process(Data);
    for I := 0 to N - 1 do
      Peak := Max(Peak, Abs(L[I]));
  end;
  if Peak < 0.001 then Bad := Bad + ' kein Ton';
  // Zustand: Regler setzen, speichern, in eine zweite Instanz laden
  EC.setParamNormalized(ParamToVst(Ord(gpVolume)), 0.37);
  St := TV3Stream.Create;
  StI := St;
  Comp.getState(Pointer(StI));
  St.FPos := 0;
  IID := IComponent;
  Fac.createInstance(@CID_FX, @IID, Obj);
  Pointer(Comp2) := Obj;
  Comp2.initialize(nil);
  Comp2.setState(Pointer(StI));
  Supports(Comp2, IEditController, EC2);
  V1 := EC.getParamNormalized(ParamToVst(Ord(gpVolume)));
  V2 := EC2.getParamNormalized(ParamToVst(Ord(gpVolume)));
  if Abs(V1 - V2) > 1E-5 then Bad := Bad + ' Zustand';
  // Ansicht: Groesse abfragen (ohne Fenster)
  View := EC.createView('editor');
  if View = nil then
    Bad := Bad + ' Ansicht'
  else
  begin
    FillChar(Rect, SizeOf(Rect), 0);
    IPlugView(View).getSize(@Rect);
    if (Rect.right <= 0) or (Rect.bottom <= 0) then Bad := Bad + ' Ansichtsgroesse';
    IPlugView(View)._Release;
  end;
  AP.setProcessing(0);
  Comp.setActive(0);
  Comp.terminate;
  Comp2.terminate;
  // Strukturgroessen wie der C++-Compiler sie aus den Steinberg-Headern bildet (natuerliche Ausrichtung)
  {$IFDEF CPUX64}
  if (SizeOf(TParameterInfo) <> 792) or (SizeOf(TBusInfo) <> 276) or (SizeOf(TProcessData) <> 80) or
     (SizeOf(TAudioBusBuffers) <> 24) or (SizeOf(TProcessSetup) <> 24) or (SizeOf(TClassInfo2) <> 440) or
     (SizeOf(TFactoryInfo) <> 452) or (SizeOf(TContextMenuItem) <> 264) or (SizeOf(TViewRect) <> 16) then
  {$ELSE}
  if (SizeOf(TParameterInfo) <> 792) or (SizeOf(TBusInfo) <> 276) or (SizeOf(TProcessData) <> 48) or
     (SizeOf(TAudioBusBuffers) <> 24) or (SizeOf(TProcessSetup) <> 24) or (SizeOf(TClassInfo2) <> 440) or
     (SizeOf(TFactoryInfo) <> 452) or (SizeOf(TContextMenuItem) <> 264) or (SizeOf(TViewRect) <> 16) then
  {$ENDIF}
    Bad := Bad + Format(' Strukturgroesse(PI %d Bus %d PD %d ABB %d PS %d CI2 %d FI %d CMI %d)',
      [SizeOf(TParameterInfo), SizeOf(TBusInfo), SizeOf(TProcessData), SizeOf(TAudioBusBuffers),
       SizeOf(TProcessSetup), SizeOf(TClassInfo2), SizeOf(TFactoryInfo), SizeOf(TContextMenuItem)]);
  if (PByte(@Info.defaultNormalizedValue) - PByte(@Info) <> 776) or (PByte(@Data.inputs) - PByte(@Data) <> {$IFDEF CPUX64}24{$ELSE}20{$ENDIF}) then
    Bad := Bad + ' Feldversatz';
  Result := Format('VST3 (eigener Mini-Host): Klassen %sTon %.3f, Zustand %.3f/%.3f, Ansicht %dx%d, Chunk %d Byte -> %s',
    [Names, Peak, V1, V2, Rect.right, Rect.bottom, Length(St.FData), IfThen(Bad = '', 'OK', 'FEHLER' + Bad)]);
end;

function CheckMidiLearn: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  Idx, CcA, CcB, Old: Integer;
  V: Single;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    Idx := Ord(gpFltCutoff);
    E.MidiLearnStart(Idx);
    E.ControlChange(64, 1);                       // Pedal: darf nicht gelernt werden
    E.ControlChange(21, 0.7);
    E.Process(nil, nil, @L[0], @R[0], 512);
    CcA := E.MidiLearnPoll;
    V := E.GetParam(Idx);
    E.MidiLearnStart(Idx);
    E.ControlChange(22, 0.2);
    E.Process(nil, nil, @L[0], @R[0], 512);
    CcB := E.MidiLearnPoll;
    Old := E.CcTarget(21);
  finally
    E.Free;
  end;
  Result := Format('MIDI-Learn: gelernt CC %d, Wert %.2f; neu gelernt CC %d, alte Zuordnung %d -> %s',
    [CcA, V, CcB, Old, IfThen((CcA = 21) and (Abs(V - 0.7) < 0.01) and (CcB = 22) and (Old = -1), 'OK', 'FEHLER')]);
end;

function CheckArpLatch: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, N0, N1, OldSeen, NewSeen: Integer;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), 1));
    E.SetParamById(gpArpLatch, StepToParam(Ord(gpArpLatch), 1));
    E.Process(nil, nil, @L[0], @R[0], 512);                              // Arp-Schalter wirksam werden lassen
    E.NoteOn(60, 0.8); E.NoteOn(64, 0.8); E.NoteOn(67, 0.8);
    for B := 0 to 9 do E.Process(nil, nil, @L[0], @R[0], 512);
    E.NoteOff(60); E.NoteOff(64); E.NoteOff(67);
    for B := 0 to 4 do E.Process(nil, nil, @L[0], @R[0], 512);
    N0 := E.NoteOnCount;
    for B := 0 to 86 do E.Process(nil, nil, @L[0], @R[0], 512);          // 1 s nach dem Loslassen
    N1 := E.NoteOnCount;
    E.NoteOn(72, 0.8); E.NoteOff(72);                                     // neue Taste: ersetzt den Akkord
    OldSeen := 0; NewSeen := 0;
    for B := 0 to 80 do E.Process(nil, nil, @L[0], @R[0], 512);           // Ausklang der alten Noten abwarten
    for B := 0 to 86 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      if (E.VoiceOfNote(60) >= 0) or (E.VoiceOfNote(64) >= 0) or (E.VoiceOfNote(67) >= 0) then Inc(OldSeen);
      if E.VoiceOfNote(72) >= 0 then Inc(NewSeen);
    end;
  finally
    E.Free;
  end;
  Result := Format('Arp Latch: nach dem Loslassen %d Anschlaege in 1 s; neue Taste: alter Akkord %d, neue Taste %d Bloecke -> %s',
    [N1 - N0, OldSeen, NewSeen, IfThen((N1 - N0 >= 3) and (OldSeen = 0) and (NewSeen > 10), 'OK', 'FEHLER')]);
end;

{ Stille ueberspringen: nach Note aus und abgeklungenem Hall werden Bloecke uebersprungen (Ausgang exakt 0),
  eine neue Note klingt sofort wieder; Rechenzeit je Block in Stille }
function CheckIdleSkip: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, I: Integer;
  Skips0, Skips1: Int64;
  MaxOut, NewPeak: Single;
  T0, T1, F: Int64;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 1));
    E.SetParamById(gpRevDecay, PlainToParam(gpRevDecay, 3));
    E.NoteOn(60, 0.8);
    for B := 0 to 40 do E.Process(nil, nil, @L[0], @R[0], 512);
    E.NoteOff(60);
    for B := 0 to 1500 do E.Process(nil, nil, @L[0], @R[0], 512);     // ~17 s: Hall klingt ganz aus
    Skips0 := E.IdleSkips;
    MaxOut := 0;
    QueryPerformanceCounter(T0);
    for B := 0 to 999 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      for I := 0 to 511 do MaxOut := Max(MaxOut, Max(Abs(L[I]), Abs(R[I])));
    end;
    QueryPerformanceCounter(T1);
    QueryPerformanceFrequency(F);
    Skips1 := E.IdleSkips;
    E.NoteOn(64, 0.8);
    NewPeak := 0;
    for B := 0 to 20 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      for I := 0 to 511 do NewPeak := Max(NewPeak, Abs(L[I]));
    end;
  finally
    E.Free;
  end;
  Result := Format('Stille ueberspringen: %d von 1000 Bloecken uebersprungen, Ausgang max %.1E, %.4f ms je Block; neue Note danach Spitze %.2f -> %s',
    [Skips1 - Skips0, MaxOut, (T1 - T0) * 1000 / F / 1000, NewPeak,
     IfThen((Skips1 - Skips0 = 1000) and (MaxOut = 0) and (NewPeak > 0.01), 'OK', 'FEHLER')]);
end;

{ Zwei Instanzen im selben Thread (wie FL Studio ohne Multithreading): kostet das mehr als die doppelte
  Zeit einer Instanz? (Hinweis auf Cache-Verdraengung durch Sample-, Grain- und Effektspeicher) }
function CheckTwoInstances: string;
const
  NB = 400;
var
  E: array[0..1] of TGranularEngine;
  L, R: array[0..511] of Single;
  I, B: Integer;
  T0, T1, F: Int64;
  One, Two: Double;

  procedure Setup(X: TGranularEngine; Seed: Integer);
  var
    K: Integer;
  begin
    X.SetSampleRate(SR);
    X.LoadSample(CreateDemoSample(SR));
    X.SetParamById(gpDensity, PlainToParam(gpDensity, 60));
    X.SetParamById(gpGrainSize, PlainToParam(gpGrainSize, 150));
    X.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 1));
    X.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 1));
    X.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    for K := 0 to 5 do
      X.NoteOn(48 + Seed + K * 4, 0.8);
    for K := 0 to 20 do
      X.Process(nil, nil, @L[0], @R[0], 512);
  end;

begin
  QueryPerformanceFrequency(F);
  for I := 0 to 1 do
  begin
    E[I] := TGranularEngine.Create;
    Setup(E[I], I);
  end;
  try
    QueryPerformanceCounter(T0);
    for B := 0 to NB - 1 do
      E[0].Process(nil, nil, @L[0], @R[0], 512);
    QueryPerformanceCounter(T1);
    One := (T1 - T0) / F;
    QueryPerformanceCounter(T0);
    for B := 0 to NB - 1 do
    begin
      E[0].Process(nil, nil, @L[0], @R[0], 512);
      E[1].Process(nil, nil, @L[0], @R[0], 512);
    end;
    QueryPerformanceCounter(T1);
    Two := (T1 - T0) / F;
  finally
    E[0].Free;
    E[1].Free;
  end;
  Result := Format('Zwei Instanzen nacheinander: eine %.1f ms, zwei %.1f ms = %.2f-fach (2,00 = linear)',
    [One * 1000, Two * 1000, Two / One]);
end;

{ Echte Presets (Doppel/Flaeche): Akkord halten, Rechenzeit in % eines Kerns - zum Vergleich vor/nach
  Optimierungen. Presets aus dem Projektordner (..\..\Presets relativ zur exe). }
{ Klang-Regression: jedes Preset spielt einen Akkord (1,5 s halten, 1 s Ausklang); Summe und Spitze des
  Ausgangs je Preset werden mit Demos\regress_ref.txt verglichen. Fehlt die Datei, wird sie angelegt
  (Referenz VOR einem Umbau erzeugen, danach muss jedes Preset gleich klingen). }
function CheckRegression: string;
const
  CHORD: array[0..3] of Integer = (48, 55, 60, 64);
var
  Dir, RefFile, Path, Res, Line, Bad: string;
  SR2: TSearchRec;
  Names, Ref, Outp: TStringList;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  I, B, K, Cnt, NBad: Integer;
  Sum, Peak, RSum, RPeak: Double;
  Parts: TArray<string>;
  FS: TFormatSettings;
begin
  FS := TFormatSettings.Invariant;
  Dir := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..'));
  RefFile := Dir + 'Demos' + PathDelim + 'regress_ref.txt';
  Names := TStringList.Create;
  Ref := TStringList.Create;
  Outp := TStringList.Create;
  try
    Names.Sorted := True;
    if FindFirst(Dir + 'Presets' + PathDelim + '*.gspreset', faAnyFile, SR2) = 0 then
    try
      repeat
        Names.Add(SR2.Name);
      until FindNext(SR2) <> 0;
    finally
      FindClose(SR2);
    end;
    if FileExists(RefFile) then
      Ref.LoadFromFile(RefFile, TEncoding.UTF8);
    Cnt := 0; NBad := 0; Bad := '';
    for I := 0 to Names.Count - 1 do
    begin
      E := TGranularEngine.Create;
      try
        E.SetSampleRate(SR);
        if not LoadChunkFromFile(E, Dir + 'Presets' + PathDelim + Names[I], Path) then
          Continue;
        Res := ResolveSamplePath(Path, Dir);
        if FileExists(Res) then
          E.LoadSample(LoadAudioFile(Res))
        else
          E.LoadSample(CreateDemoSample(SR));
        LoadMorphSample(E, Dir);
        LoadZoneSamples(E, Dir);
        for K := 0 to High(CHORD) do
          E.NoteOn(CHORD[K], 0.8);
        Sum := 0; Peak := 0;
        for B := 0 to 214 do                        // 2,5 s
        begin
          if B = 129 then                           // nach 1,5 s loslassen
            for K := 0 to High(CHORD) do
              E.NoteOff(CHORD[K]);
          E.Process(nil, nil, @L[0], @R[0], 512);
          for K := 0 to 511 do
          begin
            Sum := Sum + Abs(L[K]) + Abs(R[K]);
            Peak := Max(Peak, Max(Abs(L[K]), Abs(R[K])));
          end;
        end;
      finally
        E.Free;
      end;
      Inc(Cnt);
      Line := Names[I] + '|' + FloatToStrF(Sum, ffExponent, 12, 2, FS) + '|' + FloatToStrF(Peak, ffExponent, 12, 2, FS);
      Outp.Add(Line);
      K := Ref.IndexOfName(Names[I]);
      if Ref.Count > 0 then
      begin
        // Referenzzeile suchen (Format Name|Summe|Spitze)
        RSum := -1; RPeak := -1;
        for K := 0 to Ref.Count - 1 do
          if Ref[K].StartsWith(Names[I] + '|') then
          begin
            Parts := Ref[K].Split(['|']);
            RSum := StrToFloat(Parts[1], FS);
            RPeak := StrToFloat(Parts[2], FS);
            Break;
          end;
        if (RSum >= 0) and ((Abs(Sum - RSum) > 1E-5 * Max(1.0, RSum)) or (Abs(Peak - RPeak) > 1E-5)) then
        begin
          Inc(NBad);
          if NBad <= 6 then
            Bad := Bad + Format(' [%s: Summe %.6g statt %.6g, Spitze %.5f statt %.5f]', [Names[I], Sum, RSum, Peak, RPeak]);
        end;
      end;
    end;
    if Ref.Count = 0 then
    begin
      ForceDirectories(ExtractFilePath(RefFile));
      Outp.SaveToFile(RefFile, TEncoding.UTF8);
      Result := Format('Klang-Regression: Referenz fuer %d Presets angelegt (%s)', [Cnt, RefFile]);
    end
    else if NBad = 0 then
      Result := Format('Klang-Regression: %d Presets wie die Referenz -> OK', [Cnt])
    else
      Result := Format('Klang-Regression: FEHLER %d von %d Presets weichen ab:%s', [NBad, Cnt, Bad]);
  finally
    Names.Free;
    Ref.Free;
    Outp.Free;
  end;
end;

function CheckPresetLoad: string;
const
  NAMES: array[0..3] of string = ('98 ', '102 ', '168 ', '41 ');
  CHORD: array[0..3] of Integer = (48, 55, 60, 64);
var
  Dir, F, Path, Res: string;
  SR2: TSearchRec;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  I, B, NB, GSum, K: Integer;
  T0, T1, Fq: Int64;
  Tot: Double;
begin
  Result := '';
  Dir := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..'));
  QueryPerformanceFrequency(Fq);
  for I := 0 to High(NAMES) do
  begin
    F := '';
    if FindFirst(Dir + 'Presets' + PathDelim + NAMES[I] + '*.gspreset', faAnyFile, SR2) = 0 then
    begin
      F := Dir + 'Presets' + PathDelim + SR2.Name;
      FindClose(SR2);
    end;
    if F = '' then
      Continue;
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      if not LoadChunkFromFile(E, F, Path) then
        Continue;
      Res := ResolveSamplePath(Path, Dir);
      if FileExists(Res) then
        E.LoadSample(LoadAudioFile(Res));
      LoadMorphSample(E, Dir);
      for B := 0 to High(CHORD) do
        E.NoteOn(CHORD[B], 0.8);
      for B := 0 to 40 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      NB := Round(SECONDS * SR / 512);
      GSum := 0;
      FillChar(GSectTicks, SizeOf(GSectTicks), 0);
      GSectProfOn := True;
      QueryPerformanceCounter(T0);
      for B := 0 to NB - 1 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        Inc(GSum, E.ActiveGrains);
      end;
      QueryPerformanceCounter(T1);
      GSectProfOn := False;
      Tot := 0;
      for K := 0 to 11 do
        Tot := Tot + GSectTicks[K];        // 12..17 liegen innerhalb von 9 (UpdateModulation)
      for K := 20 to 25 do
        Tot := Tot + GSectTicks[K];        // Teile des frueheren "Rest"
      Tot := Max(Tot, 1);
      Result := Result + Format('%s%s: %.1f %% eines Kerns, Grains %d', [IfThen(Result <> '', sLineBreak, ''),
        ChangeFileExt(SR2.Name, ''), 100 * ((T1 - T0) / Fq) / SECONDS, GSum div NB]) + sLineBreak +
        Format('    Rest: Grain-Pegel %.0f %%, Lautstärke %.0f %%, Drive %.0f %%, EQ %.0f %%, Stereo %.0f %%, Limiter %.0f %%',
          [100 * GSectTicks[20] / Tot, 100 * GSectTicks[21] / Tot, 100 * GSectTicks[22] / Tot, 100 * GSectTicks[23] / Tot,
           100 * GSectTicks[24] / Tot, 100 * GSectTicks[25] / Tot]) + sLineBreak +
        Format('    UpdateModulation: Sidechain/Tonhöhe %.0f %%, Trigger %.0f %%, Stimmung %.0f %%, LFOs %.0f %%, Matrix %.0f %%, je Note %.0f %%',
          [100 * GSectTicks[12] / Tot, 100 * GSectTicks[13] / Tot, 100 * GSectTicks[14] / Tot, 100 * GSectTicks[15] / Tot,
           100 * GSectTicks[16] / Tot, 100 * GSectTicks[17] / Tot]) + sLineBreak +
        Format('    Modulation: Arp/SC2 %.0f %%, UpdateModulation %.0f %%, Filter-Hüllk. %.0f %%, Blockparameter %.0f %%',
          [100 * GSectTicks[8] / Tot, 100 * GSectTicks[9] / Tot, 100 * GSectTicks[10] / Tot, 100 * GSectTicks[11] / Tot]) + sLineBreak +
        Format('    Anteile: Modulation %.0f %%, Stimmen %.0f %%, Grains %.0f %%, Osz %.0f %%, Filter je Note %.0f %%, ' +
          'Echo %.0f %%, Hall %.0f %%, Rest %.0f %%', [100 * GSectTicks[0] / Tot, 100 * GSectTicks[1] / Tot,
          100 * GSectTicks[2] / Tot, 100 * GSectTicks[3] / Tot, 100 * GSectTicks[4] / Tot, 100 * GSectTicks[5] / Tot,
          100 * GSectTicks[6] / Tot, 100 * GSectTicks[7] / Tot]);
    finally
      E.Free;
    end;
  end;
  if Result = '' then
    Result := 'Preset-Last: keine Presets gefunden';
end;

{ Stimmungserkennung: sanfte, gebundene Dur-Akkorde -> zaertlich; schnelle, laute Moll-Cluster -> angespannt }
function CheckMood: string;
const
  CH: array[0..3, 0..2] of Integer = ((60, 64, 67), (65, 69, 72), (67, 71, 74), (60, 64, 67));
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, C, I: Integer;
  M1, M2: TMood;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    // zaertlich: je Akkord 2 s, leise, ueberlappend (neuer Akkord vor dem Loslassen des alten)
    for C := 0 to 7 do
    begin
      for I := 0 to 2 do E.NoteOn(CH[C mod 4, I], 0.35);
      for B := 0 to 20 do E.Process(nil, nil, @L[0], @R[0], 512);
      for I := 0 to 2 do E.NoteOff(CH[(C + 3) mod 4, I]);
      for B := 0 to 150 do E.Process(nil, nil, @L[0], @R[0], 512);
    end;
    M1 := E.GetMood;
    for I := 0 to 127 do E.NoteOff(I);
    // angespannt: schnell, laut, Moll-Cluster mit kleinen Sekunden/Tritonus
    for C := 0 to 79 do
    begin
      E.NoteOn(48 + (C * 7) mod 12, 1.0); E.NoteOn(49 + (C * 7) mod 12, 1.0); E.NoteOn(54 + (C * 7) mod 12, 1.0);
      for B := 0 to 8 do E.Process(nil, nil, @L[0], @R[0], 512);
      for I := 0 to 127 do E.NoteOff(I);
    end;
    M2 := E.GetMood;
  finally
    E.Free;
  end;
  Result := Format('Stimmung: sanfte Dur-Akkorde -> %s (V %.2f, E %.2f, zaertlich %.2f); harte Cluster -> %s (V %.2f, E %.2f)',
    [M1.Name, M1.Valence, M1.Arousal, M1.Tender, M2.Name, M2.Valence, M2.Arousal]);
end;

type
  TSongFeeder = class
    E: TGranularEngine;
    procedure Emit(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
  end;

procedure TSongFeeder.Emit(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
begin
  if IsOn then E.NoteOn(Note, Velocity, Delta) else E.NoteOff(Note, Delta);
end;

{ Gefuehls-Stuecke: wie oft wuerde die Taenzerin "zaertlich" neu erkennen (geglaettet wie im Banner) }
function CheckMoodSongs: string;
var
  Ap: TAutoPlayer;
  F: TSongFeeder;
  L, R: array[0..511] of Single;
  I, Song, B, Enter: Integer;
  Tempo, T, Smooth: Double;
  M: TMood;
  On: Boolean;
  Line: string;
begin
  Result := '';
  for Song := 0 to 200 do
  begin
    Ap := TAutoPlayer.Create(SR);
    F := TSongFeeder.Create;
    F.E := TGranularEngine.Create;
    try
      if Song >= Ap.SongCount then
        Break;
      if not ContainsText(Ap.Titles[Song], '->') then
        Continue;
      F.E.SetSampleRate(SR);
      F.E.LoadSample(CreateDemoSample(SR));
      Ap.Start(Song);
      Tempo := 120;
      Smooth := 0; Enter := 0; On := False; T := 0; Line := '';
      for B := 0 to Round(SR * 75 / 512) do
      begin
        Ap.Process(512, Tempo, F.Emit);
        F.E.Process(nil, nil, @L[0], @R[0], 512);
        T := T + 512 / SR;
        M := F.E.GetMood;
        Smooth := Smooth + (M.Tender - Smooth) * Min(1.0, (512 / SR) / 1.5);
        if B mod Round(SR * 4 / 512) = 0 then
          Line := Line + Format(' [%.0fs %s V%.2f E%.2f Z%.2f]', [T, Copy(M.Name, 1, 6), M.Valence, M.Arousal, M.Tender]);
        if (not On) and (Smooth > 0.55) then begin On := True; Inc(Enter); Line := Line + Format(' %.0fs', [T]); end
        else if On and (Smooth < 0.35) then On := False;
      end;
      Result := Result + Format('%s%s: %d x zaertlich (bei%s)', [IfThen(Result <> '', sLineBreak, ''), Ap.Titles[Song], Enter, Line]);
    finally
      F.E.Free;
      F.Free;
      Ap.Free;
    end;
  end;
end;

function CheckOutTrigger: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, I, Evt, Starts, Pos: Integer;
  Items: TArray<TTrigLogItem>;
  Peak: Single;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpLfo1Trig, StepToParam(Ord(gpLfo1Trig), LFO_TRIG_OUT));
    E.SetParamById(gpLfo1Once, 1);
    E.SetParamById(gpOutTrigLevel, PlainToParam(gpOutTrigLevel, 20));
    E.TriggerLog := True;
    Evt := 0; Starts := 0; Pos := 0; Peak := 0;
    for B := 0 to (SR * 6) div 512 do
    begin
      if B mod 80 = 0 then E.NoteOn(60, 0.9);
      if B mod 80 = 40 then E.NoteOff(60);
      E.Process(nil, nil, @L[0], @R[0], 512);
      Peak := Max(Peak, E.OutputPeak);
      Items := E.ReadTriggerLog(Pos);
      for I := 0 to High(Items) do
        if Items[I].Kind = tlOutTrig then Inc(Evt)
        else if Items[I].Kind = tlLfoStart then Inc(Starts);
    end;
  finally
    E.Free;
  end;
  Result := Format('Ausgangs-Trigger: %d Ereignisse, %d LFO-Starts (Spitze %.2f)', [Evt, Starts, Peak]);
end;

function RunBenchmark: string;
var
  P, S: TRender;
  I: Integer;
  MaxDiff, Peak: Double;
  HasSSE: Boolean;
  FastName: string;
  Std, NoLim: TRender;
begin
  // Messungen moeglichst ungestoert von anderen Programmen
  SetPriorityClass(GetCurrentProcess, HIGH_PRIORITY_CLASS);
  SetThreadPriority(GetCurrentThread, THREAD_PRIORITY_HIGHEST);
  HasSSE := CpuHasSSE;
  P := RenderWith(False);
  if HasSSE then
    S := RenderWith(True)
  else
    S := P;
  InitDSP(True);
  FastName := DSPPathName;
  Std := RenderWith(HasSSE, False, True);
  NoLim := RenderWith(HasSSE, True, False);
  InitDSP(True);

  MaxDiff := 0;
  Peak := 0;
  for I := 0 to High(P.L) do
  begin
    MaxDiff := Max(MaxDiff, Max(Abs(P.L[I] - S.L[I]), Abs(P.R[I] - S.R[I])));
    Peak := Max(Peak, Max(Abs(P.L[I]), Abs(P.R[I])));
  end;

  Result := Format(
    'Granular-Benchmark ' + {$IFDEF CPUX64}'64 Bit'{$ELSE}'32 Bit'{$ENDIF} + ': %d s Audio, %d Hz, Block %d, ca. %d aktive Grains' + sLineBreak +
    'CPU unterstuetzt SSE: %s' + sLineBreak +
    'Pascal: %8.1f ms  (%.1f%% eines Kerns in Echtzeit)' + sLineBreak +
    'Schnell (%s): %8.1f ms  (%.1f%% eines Kerns in Echtzeit)' + sLineBreak +
    'Faktor: %.2fx' + sLineBreak +
    'Max. Abweichung Pascal/schnell: %.3g (Spitzenpegel %.3f, = %.1f dB darunter)',
    [SECONDS, SR, BLOCK, P.Grains, BoolToStr(HasSSE, True),
     P.Ms, P.Ms / (SECONDS * 10), FastName, S.Ms, S.Ms / (SECONDS * 10),
     P.Ms / Max(S.Ms, 0.001), MaxDiff, Peak,
     20 * Log10(Max(Peak, 1e-9) / Max(MaxDiff, 1e-12))]);
  Result := Result + sLineBreak + Format(
    'Aufschluesselung (schneller Pfad): HQ+Limiter %.1f ms | Standard+Limiter %.1f ms | HQ ohne Limiter %.1f ms',
    [S.Ms, Std.Ms, NoLim.Ms]);
  Result := Result + sLineBreak + CheckGfxKernel + sLineBreak + CheckSpectrumKernels + sLineBreak + CheckReverb + sLineBreak + CheckSat + sLineBreak + CheckComb + sLineBreak + CheckPhaser + sLineBreak + CheckChorus +
    sLineBreak + CheckNewSound + sLineBreak + CheckEq + sLineBreak + CheckOsc + sLineBreak + CheckOutputStage + sLineBreak + CheckOutTrigger + sLineBreak + CheckPolyMod + sLineBreak + CheckMorphLayers + sLineBreak + CheckNoteLfoIsolation + sLineBreak + CheckFreeLfo + sLineBreak + CheckOsc123 + sLineBreak + CheckGrainLevel + sLineBreak + CheckVstMap + sLineBreak + CheckSwapAB + sLineBreak + CheckMixMeters + sLineBreak + CheckSourceRename + sLineBreak + CheckEnvSeg + sLineBreak + CheckEventDelay + sLineBreak + CheckLfoStop + sLineBreak + CheckLfoPartner + sLineBreak + CheckArpLatch + sLineBreak + CheckRegression + sLineBreak + CheckVst3 + sLineBreak + CheckLfo58 + sLineBreak + CheckUserMacros + sLineBreak + CheckLanguage + sLineBreak + CheckHostVst3 + sLineBreak + CheckEmbedPreset + sLineBreak + CheckMidiLearn +
    sLineBreak + CheckFxLoad + sLineBreak + CheckPreRoll + sLineBreak + CheckIdleSkip + sLineBreak + CheckTwoInstances + sLineBreak + CheckPresetLoad + sLineBreak + CheckFullLoad + sLineBreak + CheckMood + sLineBreak + CheckMoodSongs;
end;

end.
