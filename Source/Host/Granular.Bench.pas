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
function RunTextBench: string;
function RenderAB(const ProjectDir: string): string;

implementation

uses
  Granular.Lang,
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.Math, System.StrUtils, System.IOUtils,
  System.Threading, System.Diagnostics,
  GR32, Granular.Fader, Granular.Params, Granular.Sample, Granular.Engine, Granular.DSP, Granular.GfxAsm, Granular.Reverb, Granular.Eq, Granular.AutoPlay, Granular.State, Granular.AudioDecode, Granular.Pitch, Granular.Vst3, Granular.VstHost,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics,
  Granular.Editor, Granular.InfoView, Granular.ArpMidi, Granular.SampleEdit{$IFDEF USE_FASTMM5}, FastMM5{$ENDIF};

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

{ Saettigungs-Arten Roehre/Hart/Faltung: SIMD gegen Pascal, dazu Grenzen (Hart und Faltung nie ueber
  Make, Roehre: Stille bleibt Stille) }
function CheckShape: string;
const
  KN: array[1..3] of string = ('Roehre', 'Hart', 'Faltung');
var
  A, B: TShapeArgs;
  XA, XB: array[0..255] of Single;
  I, K: Integer;
  D, Pk: Double;
  Ok: Boolean;
  Z: Single;
begin
  Result := 'Saettigungs-Arten (SIMD gegen Pascal):';
  Ok := True;
  for K := 1 to 3 do
  begin
    FillChar(A, SizeOf(A), 0);
    A.Kind := K;
    for I := 0 to 3 do
    begin
      A.Drive4[I] := 6; A.Make4[I] := 0.5; A.C27[I] := 27; A.C9[I] := 9;
      A.One4[I] := 1; A.MOne4[I] := -1; A.Zero4[I] := 0;
      if K = 3 then begin A.Hi4[I] := 5; A.Lo4[I] := -5; end
      else begin A.Hi4[I] := 3; A.Lo4[I] := -3; end;
      if K = 1 then
      begin
        A.Bias4[I] := 0.35;
        A.Off4[I] := ((27 + 0.35 * 0.35) * 0.35) / (0.35 * 0.35 * 9 + 27);
      end;
    end;
    B := A;
    RandSeed := 5 + K;
    for I := 0 to High(XA) do
    begin
      XA[I] := (Random - 0.5) * 2.4;
      XB[I] := XA[I];
    end;
    A.P := @XA[0]; A.Count := Length(XA);
    B.P := @XB[0]; B.Count := Length(XB);
    RenderShape(@A);
    ShapeBlockPas(@B);
    D := 0;
    Pk := 0;
    for I := 0 to High(XA) do
    begin
      D := Max(D, Abs(XA[I] - XB[I]));
      Pk := Max(Pk, Abs(XA[I]));
    end;
    Result := Result + Format(' %s %.1e (Spitze %.2f)', [KN[K], D, Pk]);
    if D >= 1E-5 then Ok := False;
    if (K >= 2) and (Pk > 0.5 + 1E-6) then Ok := False;
    if K = 1 then
    begin
      Z := 0;
      A.P := @Z; A.Count := 1;
      ShapeBlockPas(@A);
      if Abs(Z) > 1E-6 then Ok := False;
    end;
  end;
  if Ok then Result := Result + ' -> OK' else Result := Result + ' -> FEHLER';
end;

{ Kompressor: Menge 0 = unveraendert (Baender ergeben wieder das Signal), Menge 100 = dichter
  (der leise Ausklang kommt relativ zum gehaltenen Ton nach vorn), der Anschlag wird nicht
  ueberhoeht (Spitze hoechstens 6 dB ueber ohne Kompressor), keine ungueltigen Werte }
function CheckComp: string;
var
  RmsOff, RmsZero, RmsFull, PkOff, PkFull, Dev, TailOff, TailFull, Tail: Double;
  Kl: Boolean;
  Bad: Boolean;
  Ref: array of Single;

  // Mode 0 = Referenz merken, 1 = mit Referenz vergleichen, 2 = nur messen
  procedure Run(OnV, Amt, Mode: Integer; out Rms, Pk: Double);
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    Blk, I, Cnt: Integer;
    S, ST, SH: Double;
    NT, NH: Integer;
  begin
    ST := 0; SH := 0; NT := 0; NH := 0;
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
      E.SetParamById(gpCompOn, StepToParam(Ord(gpCompOn), OnV));
      E.SetParamById(gpCompAmt, PlainToParam(gpCompAmt, Amt));
      E.SetParamById(gpMaster, PlainToParam(gpMaster, 0.5));
      E.NoteOn(60, 0.7);
      S := 0; Pk := 0; Cnt := 0;
      for Blk := 0 to 99 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        if Blk = 70 then E.NoteOff(60);
        for I := 0 to 511 do
        begin
          if IsNan(L[I]) or IsInfinite(L[I]) then Bad := True;
          S := S + Sqr(L[I]);
          Pk := Max(Pk, Abs(L[I]));
          if (Blk >= 20) and (Blk < 70) then begin SH := SH + Sqr(L[I]); Inc(NH); end;
          if (Blk >= 74) and (Blk < 90) then begin ST := ST + Sqr(L[I]); Inc(NT); end;
          if Mode = 0 then
            Ref[Cnt] := L[I]
          else if Mode = 1 then
            Dev := Max(Dev, Abs(Ref[Cnt] - L[I]));
          Inc(Cnt);
        end;
      end;
      Rms := Sqrt(S / Cnt);
      Tail := Sqrt(ST / Max(NT, 1)) / Max(Sqrt(SH / Max(NH, 1)), 1E-9);   // Ausklang relativ zum Ton
    finally
      E.Free;
    end;
  end;

begin
  Bad := False;
  Dev := 0;
  SetLength(Ref, 100 * 512);
  Run(0, 0, 0, RmsOff, PkOff);
  TailOff := Tail;
  Run(1, 0, 1, RmsZero, PkFull);
  Run(1, 100, 2, RmsFull, PkFull);
  TailFull := Tail;
  // Kennlinie: 12 dB ueber der Schwelle bei 4:1 = -9 dB; Knick 12 dB stetig an beiden Kanten
  Kl := Abs(CompGainDb(-8, -20, 4, 0) + 9) < 1E-9;
  Kl := Kl and (Abs(CompGainDb(-14, -20, 4, 12) - CompGainDb(-14 + 1E-7, -20, 4, 0)) < 1E-5);
  Kl := Kl and (Abs(CompGainDb(-26, -20, 4, 12) - CompGainDb(-26 - 1E-7, -20, 4, 12)) < 1E-5);
  Kl := Kl and (CompGainDb(-20, -20, 4, 12) < 0) and (CompGainDb(-20, -20, 4, 12) > -3);
  // Knick rundet beide Seiten: unten an der Kniegrenze stetig zur Aufwaerts-Geraden, ohne Knick 0 dB an der Schwelle
  Kl := Kl and (Abs(CompGainDb(-26, -20, 4, 12) - CompGainDb(-26 - 1E-7, -20, 4, 0)) < 1E-5)
    and (Abs(CompGainDb(-20, -20, 4, 0)) < 1E-12);
  Result := Format('Kompressor: Menge 0 Abweichung %.1e, Ausklang/Ton aus %.3f -> voll %.3f, Spitze aus %.2f -> voll %.2f, Kennlinie %s',
    [Dev, TailOff, TailFull, PkOff, PkFull, BoolToStr(Kl, True)]);
  if Kl and (Dev < 1E-4) and not Bad and (RmsFull > 0) and (TailFull > TailOff * 1.25) and (PkFull < PkOff * 2) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

{ Bass mono: Mitte (L+R) bleibt unveraendert, das Seitensignal unter 120 Hz verschwindet weitgehend,
  darueber bleibt es (Stereobreite 200 %, Demo-Klang tief gespielt) }
{ FX-Variante 'Eingang Echo/Hall': ohne Noten kommt vom Eingang nur der Echo-/Hall-Anteil (Trockenes
  gibt das Plugin selbst aus). Send 0 = still; Echo an mit Mix 0 und Hall aus = kein trockener Rest. }
function CheckFxInSend: string;

  function Run(Send, EchoMix: Double; HallOn: Integer): Double;
  var
    E: TGranularEngine;
    L, R, InL, InR: array[0..511] of Single;
    Blk, I: Integer;
  begin
    Result := 0;
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
      E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 1));
      E.SetParamById(gpEchoMix, PlainToParam(gpEchoMix, EchoMix));
      E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), HallOn));
      E.SetParamById(gpFxInSend, PlainToParam(gpFxInSend, Send));
      for Blk := 0 to 59 do
      begin
        for I := 0 to 511 do
        begin
          if Blk < 10 then
            InL[I] := 0.5 * Sin(2 * Pi * 440 * (Blk * 512 + I) / SR)
          else
            InL[I] := 0;
          InR[I] := InL[I];
        end;
        E.SetFxInput(@InL[0], @InR[0]);
        E.Process(nil, nil, @L[0], @R[0], 512);
        for I := 0 to 511 do
          Result := Max(Result, Max(Abs(L[I]), Abs(R[I])));
      end;
    finally
      E.Free;
    end;
  end;

var
  Off, Wet, Leak: Double;
begin
  Off := Run(0, 40, 1);
  Wet := Run(60, 40, 1);
  Leak := Run(100, 0, 0);
  Result := Format('Eingang Echo/Hall (FX): Send 0 Spitze %.1e, Send 60 %% Spitze %.3f, trockener Rest %.1e',
    [Off, Wet, Leak]);
  if (Off < 1E-6) and (Wet > 0.01) and (Leak < 1E-6) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

function CheckBassMono: string;
var
  SumDev, LowOff, LowOn, HiOff, HiOn: Double;
  Mid: array of Single;

  procedure Run(OnV: Integer; out Low, Hi: Double);
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    Blk, I, Cnt: Integer;
    S, Lp, Lp2, Lp3, Hp, C: Double;
  begin
    Low := 0; Hi := 0; Lp := 0; Lp2 := 0; Lp3 := 0; Cnt := 0;
    C := 1 - Exp(-2 * Pi * 40 / SR);
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
      E.SetParamById(gpWidth, PlainToParam(gpWidth, 200));
      E.SetParamById(gpMaster, PlainToParam(gpMaster, -18));    // leise: der Soft-Clip am Ausgang greift nicht
      E.SetParamById(gpBassMonoOn, StepToParam(Ord(gpBassMonoOn), OnV));
      E.NoteOn(36, 0.8);
      E.NoteOn(72, 0.8);
      for Blk := 0 to 79 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        for I := 0 to 511 do
        begin
          S := (L[I] - R[I]) * 0.5;
          // Messfilter: 3 Einpol-Tiefpaesse bei 40 Hz (steil genug, dass die hohe Note nicht durchrutscht)
          Lp := Lp + (S - Lp) * C;
          Lp2 := Lp2 + (Lp - Lp2) * C;
          Lp3 := Lp3 + (Lp2 - Lp3) * C;
          Hp := S - Lp;
          if Blk >= 10 then
          begin
            Low := Low + Sqr(Lp3);
            Hi := Hi + Sqr(Hp);
          end;
          if OnV = 0 then
            Mid[Cnt] := L[I] + R[I]
          else
            SumDev := Max(SumDev, Abs(Mid[Cnt] - (L[I] + R[I])));
          Inc(Cnt);
        end;
      end;
    finally
      E.Free;
    end;
  end;

begin
  SumDev := 0;
  SetLength(Mid, 80 * 512);
  Run(0, LowOff, HiOff);
  Run(1, LowOn, HiOn);
  Result := Format('Bass mono: Mitte Abweichung %.1e, Seite tief %.1f%% uebrig, Seite hoch %.0f%% uebrig',
    [SumDev, 100 * Sqrt(LowOn / Max(LowOff, 1E-20)), 100 * Sqrt(HiOn / Max(HiOff, 1E-20))]);
  if (LowOff > 1E-6) and (SumDev < 1E-4) and (LowOn < LowOff * 0.0225) and (HiOn > HiOff * 0.5) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

{ Modulations-Huellkurven: Attack 100 ms erreicht 1, Decay faellt auf Sustain 30 %, Release nach
  Note aus faellt auf 0; Huellkurve 2 mit anderen Zeiten laeuft unabhaengig }
function CheckModEnv: string;
var
  E: TGranularEngine;
  L, R: array[0..255] of Single;
  I, Blk: Integer;
  PkA, AtSus, AtRel, E2Mid: Single;
  T, TA: Double;
begin
  TA := 0;
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpRelease, PlainToParam(gpRelease, 20));
    E.SetParamById(gpMEnv1Att, PlainToParam(gpMEnv1Att, 100));
    E.SetParamById(gpMEnv1Dec, PlainToParam(gpMEnv1Dec, 200));
    E.SetParamById(gpMEnv1Sus, PlainToParam(gpMEnv1Sus, 30));
    E.SetParamById(gpMEnv1Rel, PlainToParam(gpMEnv1Rel, 100));
    E.SetParamById(gpMEnv2Att, PlainToParam(gpMEnv2Att, 2000));
    for Blk := 0 to 199 do
      E.Process(nil, nil, @L[0], @R[0], 256);       // Regler-Glaettung ausklingen lassen
    E.NoteOn(60, 0.8);
    PkA := 0; AtSus := 0; AtRel := 1; E2Mid := 0;
    T := 0;
    for Blk := 0 to Round(2.0 * SR / 256) do
    begin
      E.Process(nil, nil, @L[0], @R[0], 256);
      T := T + 256 / SR;
      if T < 0.15 then PkA := Max(PkA, E.SourceValue[msModEnv1]);
      if (TA = 0) and (E.SourceValue[msModEnv1] >= 0.97) then TA := T;
      if Abs(T - 1.0) < 0.003 then
      begin
        AtSus := E.SourceValue[msModEnv1];
        E2Mid := E.SourceValue[msModEnv2];
        E.NoteOff(60);
      end;
      if Abs(T - 1.9) < 0.003 then AtRel := E.SourceValue[msModEnv1];
    end;
  finally
    E.Free;
  end;
  I := 0;
  Result := Format('Mod-Huellkurven: Spitze %.2f, Sustain %.2f (soll 0,30), nach Release %.3f, Huellk. 2 bei 1 s %.2f (soll ~0,5), Attack 1 fertig nach %.0f ms (soll 100)',
    [PkA, AtSus, AtRel, E2Mid, TA * 1000]);
  if (PkA > 0.97) and (Abs(AtSus - 0.3) < 0.02) and (AtRel < 0.01) and (E2Mid > 0.4) and (E2Mid < 0.6) and (Abs(TA - 0.1) < 0.01) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
  if I <> 0 then Result := '';
end;

{ Wavetable: zwei Frames (Sinus, Rechteck) im Speicher; Position 0 und 1 klingen verschieden, Position 0,5
  ist genau die Mitte (gleiche Phase -> lineares Ueberblenden); Frame-Erkennung; Aufbauzeit je Frame }
function CheckWavetable: string;
var
  Data: TArray<Single>;
  I, K: Integer;
  Out_: array[0..2] of TArray<Single>;
  D01, DMid, Rms0, Ms: Double;
  Sw: TStopwatch;
  Fl: Boolean;

  procedure Run(Pos: Double; var Dst: TArray<Single>);
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    Blk, J: Integer;
  begin
    SetLength(Dst, 20 * 512);
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, 0);
      E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
      E.SetParamById(gpOscOn, 1);
      E.SetParamById(gpOscWtOn, 1);
      E.SetParamById(gpOscWtPos, PlainToParam(gpOscWtPos, Pos * 100));
      E.SetParamById(gpMaster, PlainToParam(gpMaster, -12));
      if Pos = 0 then
      begin
        Sw := TStopwatch.StartNew;
        E.SetOscWavetable(0, Data, 2048, 'Test');
        Ms := Sw.Elapsed.TotalMilliseconds / 2;
      end
      else
        E.SetOscWavetable(0, Data, 2048, 'Test');
      for Blk := 0 to 99 do
        E.Process(nil, nil, @L[0], @R[0], 512);           // Regler-Glaettung abwarten
      E.NoteOn(57, 0.8);
      for Blk := 0 to 19 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        for J := 0 to 511 do
          Dst[Blk * 512 + J] := L[J];
      end;
      if E.WtFrameCount(0) <> 2 then
        Fl := False;
    finally
      E.Free;
    end;
  end;

begin
  Fl := True;
  SetLength(Data, 2 * 2048);
  for I := 0 to 2047 do
  begin
    Data[I] := Sin(2 * Pi * I / 2048);
    if I < 1024 then Data[2048 + I] := 0.8 else Data[2048 + I] := -0.8;
  end;
  Run(0, Out_[0]);
  Run(1, Out_[1]);
  Run(0.5, Out_[2]);
  D01 := 0; DMid := 0; Rms0 := 0;
  for K := 0 to High(Out_[0]) do
  begin
    Rms0 := Rms0 + Sqr(Out_[0][K]);
    D01 := D01 + Sqr(Out_[0][K] - Out_[1][K]);
    DMid := Max(DMid, Abs(Out_[2][K] - (Out_[0][K] + Out_[1][K]) / 2));
  end;
  Rms0 := Sqrt(Rms0 / Length(Out_[0]));
  D01 := Sqrt(D01 / Length(Out_[0]));
  Fl := Fl and (WtFrameLen(2048 * 16) = 2048) and (WtFrameLen(600) = 600) and (WtFrameLen(256 * 41) = 256);
  Result := Format('Wavetable: Pegel %.3f, Unterschied Frame 0/1 %.3f, Mitte Abweichung %.1e, Aufbau %.0f ms je Frame',
    [Rms0, D01, DMid, Ms]);
  if Fl and (Rms0 > 0.001) and (D01 > Rms0 * 0.2) and (DMid < 1E-4) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

{ Sub/Rauschen und Effekt-Reihenfolge: Sub 0 % / Rauschen 0 % = unveraendert; Sub -1 Oktave legt die
  Grundfrequenz eine Oktave tiefer dazu (Nulldurchgaenge halbieren sich bei reinem Sub), Rauschen
  macht das Signal dichter; Reihenfolge 0 = bisher, eine andere Reihenfolge klingt bei Crusher + Chorus anders }
function CheckSubFx: string;
var
  Base, SubOnly, Noise, Ord0, OrdX: TArray<Single>;
  ZcOsc, ZcSub: Integer;
  DevSame, DevOrd: Double;
  I, FollowZc: Integer;
  DbgS: string;

  function Rms(const X: TArray<Single>): Double;
  var
    K: Integer;
  begin
    Result := 0;
    for K := 0 to High(X) do
      Result := Result + Sqr(X[K]);
    Result := Sqrt(Result / Length(X));
  end;

  function Render(SubL, NoiseL, OscL: Double; FxOrd: Integer; Fx: Boolean; Follow: Boolean = False): TArray<Single>;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    Blk, J: Integer;
  begin
    SetLength(Result, 16 * 512);
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, 0);
      E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
      E.SetParamById(gpMaster, PlainToParam(gpMaster, 0));
      E.SetParamById(gpOscOn, 1);
      E.SetParamById(gpOscLevel, PlainToParam(gpOscLevel, OscL));
      E.SetParamById(gpSubLevel, PlainToParam(gpSubLevel, SubL));
      E.SetParamById(gpNoiseLevel, PlainToParam(gpNoiseLevel, NoiseL));
      E.SetParamById(gpFxOrder, StepToParam(Ord(gpFxOrder), FxOrd));
      if Follow then
      begin
        E.SetParamById(gpOscFollowPitch, 1);
        E.SetParamById(gpPitch, PlainToParam(gpPitch, 12));
      end;
      if Fx then
      begin
        E.SetParamById(gpCrushOn, 1);
        E.SetParamById(gpCrushBits, PlainToParam(gpCrushBits, 6));
        E.SetParamById(gpChoOn, 1);
      end;
      for Blk := 0 to 99 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      E.NoteOn(57, 0.8);
      for Blk := 0 to 15 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        for J := 0 to 511 do
          Result[Blk * 512 + J] := L[J];
      end;
      DbgS := DbgS + Format(' %.4f', [Rms(Result)]);
    finally
      E.Free;
    end;
  end;

  function Zc(const X: TArray<Single>): Integer;
  var
    K: Integer;
  begin
    Result := 0;
    for K := 2048 to High(X) do
      if (X[K - 1] < 0) and (X[K] >= 0) then
        Inc(Result);
  end;

begin
  DbgS := '';
  Base := Render(0, 0, 40, 0, False);
  SubOnly := Render(100, 0, 40, 0, False);
  Noise := Render(0, 60, 40, 0, False);
  DevSame := 0;
  for I := 0 to High(Base) do
    DevSame := Max(DevSame, Abs(Base[I] - SubOnly[I]));        // muss sich unterscheiden
  ZcOsc := Zc(Base);
  // reiner Sub-Anteil = mit Sub minus ohne Sub (der Sub ist relativ zum Oszillator-Pegel) -> halbe Nulldurchgaenge
  for I := 0 to High(Base) do
    SubOnly[I] := SubOnly[I] - Base[I];
  ZcSub := Zc(SubOnly);
  // Osz folgen Pitch: Pitch +12 bei eingeschaltetem Schalter = Oszillator eine Oktave hoeher (doppelte Nulldurchgaenge)
  FollowZc := Zc(Render(0, 0, 40, 0, False, True));
  Ord0 := Render(0, 0, 40, 0, True);
  OrdX := Render(0, 0, 40, 23, True);
  DevOrd := 0;
  for I := 0 to High(Ord0) do
    DevOrd := Max(DevOrd, Abs(Ord0[I] - OrdX[I]));
  Result := Format('Sub/Rauschen/Reihenfolge: Nulldurchgaenge Osz %d, nur Sub %d (soll ~halb), ' +
    'Rauschen %d, Sub veraendert %.3f, andere Reihenfolge veraendert %.3f, folgt Pitch +12: %d',
    [ZcOsc, ZcSub, Zc(Noise), DevSame, DevOrd, FollowZc]) + ', Pegel' + DbgS;
  if (DevSame > 1E-3) and (Abs(ZcSub * 2 - ZcOsc) <= 3) and (Zc(Noise) > ZcOsc * 3) and (DevOrd > 1E-3) and (Abs(FollowZc - 2 * ZcOsc) <= 3) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
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
{ Glaettung des freien LFOs: 0 % = Stufen wie bisher, halbe Glaettung = Mitte des Uebergangs bei
  einem Viertel der Stufe, 100 % ohne Spruenge; der Wert ueberlebt Speichern/Laden (Abschnitt FLSM) }
function CheckFreeSmooth: string;
var
  F: TFreeLfo;
  E, E2: TGranularEngine;
  D: TBytes;
  Path: string;
  I: Integer;
  V, Prev, MaxJump, Err: Double;
  Ok: Boolean;
begin
  FreeLfoDefault(F);
  F.Mode := 1;
  F.Steps := 4;
  F.Step[0] := 0; F.Step[1] := 1; F.Step[2] := -1; F.Step[3] := 0.5;
  Err := 0;
  // ohne Glaettung: genau die Stufe
  F.Smooth := 0;
  Err := Max(Err, Abs(FreeLfoValue(F, 0.25 + 0.01) - 1));
  // halbe Glaettung: Stufe 1 beginnt bei Phase 0,25, Uebergang 0 -> 1 ueber eine halbe Stufe
  F.Smooth := 0.5;
  Err := Max(Err, Abs(FreeLfoValue(F, 0.25) - 0));                     // Anfang = vorige Stufe
  Err := Max(Err, Abs(FreeLfoValue(F, 0.25 + 0.25 * 0.25) - 0.5));     // Mitte des Uebergangs
  Err := Max(Err, Abs(FreeLfoValue(F, 0.25 + 0.25 * 0.75) - 1));       // danach die Stufe
  // volle Glaettung: keine Spruenge (feines Abtasten)
  F.Smooth := 1;
  MaxJump := 0;
  Prev := FreeLfoValue(F, 0);
  for I := 1 to 4000 do
  begin
    V := FreeLfoValue(F, I / 4000);
    MaxJump := Max(MaxJump, Abs(V - Prev));
    Prev := V;
  end;
  // Speichern/Laden
  E := TGranularEngine.Create;
  E2 := TGranularEngine.Create;
  try
    E.FreeLfo[6].Smooth := 0.37;
    D := SaveChunk(E, '');
    LoadChunk(E2, D, Path);
    Ok := Abs(E2.FreeLfo[6].Smooth - 0.37) < 1E-6;
    Ok := Ok and (E2.FreeLfo[0].Smooth = 0);
  finally
    E.Free;
    E2.Free;
  end;
  Result := Format('LFO-Glaettung: Abweichung %.1e, groesster Sprung bei 100 %% %.4f, Speichern/Laden %s',
    [Err, MaxJump, IfThen(Ok, 'ok', 'FALSCH')]);
  if (Err < 1E-5) and (MaxJump < 0.01) and Ok then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

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

  procedure Measure1(Layer: Boolean; out MsTotal, MsWorst: Double; out Grains, Voices: Integer; Variant: Integer;
    Secs: Integer);
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
      for B := 0 to Round(Secs * SR / BLK) - 1 do
      begin
        QueryPerformanceCounter(Tb);
        E.Process(nil, nil, @L[0], @R[0], BLK);
        QueryPerformanceCounter(T1);
        Ms := (T1 - Tb) * 1000 / F;
        if Ms > MsWorst then MsWorst := Ms;
      end;
      MsTotal := (T1 - T0) * 1000 / F * 10 / Secs;   // immer bezogen auf 10 s Audio
      Grains := E.ActiveGrains;
      Voices := 0;
      for I := 0 to 31 do
        if E.VoiceOfNote(36 + I * 2) >= 0 then Inc(Voices);
    finally
      E.Free;
    end;
  end;

  { Minimum aus drei Laeufen: robust gegen andere Last auf dem Rechner }
  { Hauptmessung (Variant 0): bester von 3 Laeufen ueber 10 s - der laengste Block braucht eine lange
    Messung, um seltene Spitzen zu erwischen. Aufschluesselung (Variant 1-5): nur zur Information,
    ein Lauf ueber 4 s genuegt }
  procedure Measure(Layer: Boolean; out MsTotal, MsWorst: Double; out Grains, Voices: Integer; Variant: Integer = 0);
  var
    K, Runs, Secs: Integer;
    T, W: Double;
  begin
    MsTotal := 1E9; MsWorst := 1E9;
    if Variant = 0 then begin Runs := 3; Secs := 10; end else begin Runs := 1; Secs := 4; end;
    for K := 1 to Runs do
    begin
      Measure1(Layer, T, W, Grains, Voices, Variant, Secs);
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

{ Platz der Texte: Oberflaeche in einer Sprache aufbauen (Fenstergroesse wie im Plugin) und jeden Text gegen
  sein Steuerelement messen - Knopf zu schmal, Beschriftung abgeschnitten oder vom Nachbarn verdeckt,
  Listeneintrag breiter als die geschlossene Liste. Ergebnis: bin\<Plattform>\text_platz_<Sprache>.txt }
type
  TCtrlAccess = class(TControl);

function TextFitRun(const Code, FileName: string; out List: TStringList): Integer;
const
  ED_W = 1260;
  ED_H = 712;
var
  E: TGranularEngine;
  Frm: TForm;
  Bmp: TBitmap;
  I, K, TW, Need: Integer;
  C, O: TControl;
  T, Where: string;
  R: TRect;

  function PathOf(X: TControl): string;
  begin
    Result := '';
    while (X <> nil) and (X.Parent <> nil) do
    begin
      if (X.Parent is TPanel) and (TPanel(X.Parent).Caption <> '') then
        Exit(TPanel(X.Parent).Caption);
      if X.Parent is TTabSheet then
        Exit(Trim(TTabSheet(X.Parent).Caption));
      X := X.Parent;
    end;
  end;

  procedure Add(X: TControl; const Txt: string; NeedW, HaveW: Integer);
  begin
    List.Add(Format('%s'#9'%s'#9'%s'#9'braucht %d, hat %d', [PathOf(X), X.ClassName, Txt, NeedW, HaveW]));
  end;

begin
  List := TStringList.Create;
  LangLoadFile(Code, FileName);
  E := TGranularEngine.Create;
  Frm := TForm.CreateNew(nil);
  Bmp := TBitmap.Create;
  try
    Frm.SetBounds(-4000, -4000, ED_W, ED_H);   // ausserhalb des Bildschirms; Groesse wie das Plugin-Fenster
    E.SetSampleRate(SR);
    TGranularEditor.Create(Frm, Frm, E).LayoutForCheck;
    Frm.HandleNeeded;
    for I := 0 to Frm.ComponentCount - 1 do
      ;
    // alle Steuerelemente unterhalb des Editors
    for I := 0 to Frm.Components[0].ComponentCount - 1 do
    begin
      if not (Frm.Components[0].Components[I] is TControl) then
        Continue;
      C := TControl(Frm.Components[0].Components[I]);
      if not C.Visible or (C.Parent = nil) then
        Continue;
      Bmp.Canvas.Font := TCtrlAccess(C).Font;
      if (C is Granular.Fader.TButton) and Granular.Fader.TButton(C).IconOnly then
        Continue;                                  // nur Symbol: die Beschriftung dient nur dem Tooltip
      if C is TButton then
      begin
        T := TButton(C).Caption;
        TW := Bmp.Canvas.TextWidth(StringReplace(T, '&', '', [rfReplaceAll]));
        if TW + 10 > C.Width then
          Add(C, T, TW + 10, C.Width);
      end
      else if C is TLabel then
      begin
        T := TLabel(C).Caption;
        if T = '' then
          Continue;
        if TLabel(C).WordWrap then
        begin
          R := Rect(0, 0, C.Width, 0);
          DrawText(Bmp.Canvas.Handle, PChar(T), Length(T), R, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
          if R.Bottom > C.Height + 2 then
            Add(C, Copy(T, 1, 60) + '...', R.Bottom, C.Height);
          Continue;
        end;
        TW := Bmp.Canvas.TextWidth(T);
        if not TLabel(C).AutoSize and (TW > C.Width + 1) then
        begin
          Add(C, T, TW, C.Width);
          Continue;
        end;
        // Nachbar rechts daneben in derselben Zeile verdeckt den Text?
        for K := 0 to C.Parent.ControlCount - 1 do
        begin
          O := C.Parent.Controls[K];
          if (O = C) or not O.Visible or (O.Left <= C.Left) or (O.Left >= C.Left + TW) then
            Continue;
          if (O.Top < C.Top + C.Height - 2) and (O.Top + O.Height > C.Top + 2) then
          begin
            Add(C, T, TW, O.Left - C.Left);
            Break;
          end;
        end;
      end
      else if (C is TComboBox) and (TComboBox(C).Style = csDropDownList) and (TComboBox(C).Items.Count < 40) then
      begin
        Need := 0;
        T := '';
        for K := 0 to TComboBox(C).Items.Count - 1 do
          if Bmp.Canvas.TextWidth(TComboBox(C).Items[K]) > Need then
          begin
            Need := Bmp.Canvas.TextWidth(TComboBox(C).Items[K]);
            T := TComboBox(C).Items[K];
          end;
        if Need + 24 > C.Width then
          Add(C, T, Need + 24, C.Width);
      end;
    end;
  finally
    Bmp.Free;
    Frm.Free;
    E.Free;
  end;
  LangLoadFile('de', '');
  List.Sort;
  Result := List.Count;
end;

function CheckTextFit: string;
var
  Dir: string;
  SR: TSearchRec;
  L: TStringList;
  N: Integer;
  Bad: Boolean;

  procedure Run(const Code, F: string);
  begin
    N := TextFitRun(Code, F, L);
    try
      L.SaveToFile(ExtractFilePath(ParamStr(0)) + 'text_platz_' + Code + '.txt', TEncoding.UTF8);
    finally
      L.Free;
    end;
    Result := Result + Format(' %s: %d', [Code, N]);
    Bad := Bad or (N > 0);
  end;

begin
  Bad := False;
  Result := 'Textplatz (zu lange Beschriftungen):';
  Run('de', '');
  Dir := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\' + LANG_DIR + '\');
  if FindFirst(Dir + '*.txt', faAnyFile, SR) = 0 then
  try
    repeat
      if SR.Name[1] <> '_' then
        Run(ChangeFileExt(SR.Name, ''), Dir + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := Result + IfThen(Bad, ' (Liste: text_platz_<Sprache>.txt) -> FEHLER', ' -> OK');
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
  Ev: TVst3Event;
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
  // Noten-Ereignis: Steinbergs Union (double + Zeiger, Packung 8) beginnt bei Byte 24 (sonst
  // liest das Plugin Tonhoehe/Anschlag verschoben: MIDI kommt an, aber kein Ton - Fehlerbericht KVR 11/2026)
  if (PByte(@Ev.onPitch) - PByte(@Ev) <> 26) or
     (PByte(@Ev.onVelocity) - PByte(@Ev) <> 32) or
     (PByte(@Ev.offPitch) - PByte(@Ev) <> 26) then
    Bad := Bad + Format(' Event-Versatz(Pitch %d Vel %d)', [PByte(@Ev.onPitch) - PByte(@Ev), PByte(@Ev.onVelocity) - PByte(@Ev)]);
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
{ Oversampling (HQ): Halbband-Kern SIMD gegen Pascal, Spiegelfrequenzen mit/ohne Oversampling
  (FM-Oszillator und Saettigung bei hohem Ton), Rechenzeit. Spiegelanteil = Energie neben den
  Obertoenen (dort liegt bei einem periodischen Klang nichts ausser Spiegelungen) relativ zum Grundton. }
function OsAliasDb(OsOn: Boolean; Wave, Note: Integer; Drive: Double; Ratio: Double = 1; DrawSaw: Boolean = False;
  Classic: Boolean = False): Double;
const
  WIN = 8192;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  X: array of Double;
  B, I, Got: Integer;
  F0, F, Re, Im, W, PA, P0: Double;

  function Pow(Fr: Double): Double;
  var
    K: Integer;
    C, S, CosD, SinD, T: Double;
  begin
    Re := 0; Im := 0;
    C := 1; S := 0;
    CosD := Cos(2 * Pi * Fr / SR); SinD := Sin(2 * Pi * Fr / SR);
    for K := 0 to WIN - 1 do
    begin
      Re := Re + X[K] * C;
      Im := Im + X[K] * S;
      T := C * CosD - S * SinD;              // Drehung statt Sin/Cos je Sample
      S := S * CosD + C * SinD;
      C := T;
    end;
    Result := Re * Re + Im * Im;
  end;

begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
    E.SetParamById(gpFltOn, StepToParam(Ord(gpFltOn), 0));
    E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 0));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 0));
    E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), Wave));
    E.SetParamById(gpOscFmRatio, PlainToParam(gpOscFmRatio, Ratio));
    E.SetParamById(gpOscFmAmt, PlainToParam(gpOscFmAmt, 100));
    E.SetParamById(gpOscSustain, PlainToParam(gpOscSustain, 100));
    E.SetParamById(gpDrive, PlainToParam(gpDrive, Drive));
    E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
    E.SetParamById(gpOversample, StepToParam(Ord(gpOversample), Ord(OsOn)));
    E.SetParamById(gpOscLevel, PlainToParam(gpOscLevel, 100));   // laut genug, dass die Saettigung hart begrenzt
    E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), Ord(Classic)));
    if DrawSaw then
    begin
      for B := 0 to OSC_DRAW_N - 1 do
        E.OscDraw[0].Pt[B] := 1 - 2 * B / OSC_DRAW_N;
      E.OscDrawChanged(0);
      E.SetParamById(gpOscDraw, StepToParam(Ord(gpOscDraw), 1));
    end;
    E.NoteOn(Note, 1);
    SetLength(X, WIN);
    Got := 0;
    for B := 0 to 40 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      if B >= 8 then
        for I := 0 to 511 do
          if Got < WIN then
          begin
            W := Got / (WIN - 1) * 2 * Pi;                   // Blackman-Harris (Nebenkeulen -92 dB)
            W := 0.35875 - 0.48829 * Cos(W) + 0.14128 * Cos(2 * W) - 0.01168 * Cos(3 * W);
            X[Got] := L[I] * W;
            Inc(Got);
          end;
    end;
  finally
    E.Free;
  end;
  F0 := 440 * Power(2, (Note - 69) / 12);
  P0 := Pow(F0);
  // alles ausserhalb der Obertoene k*F0 (+-40 Hz, Hauptkeule des Fensters) bis 20 kHz ist Spiegelung
  PA := 0;
  F := 40;
  while F < 20000 do
  begin
    if Abs(F - Round(F / F0) * F0) > 40 then
      PA := PA + Pow(F);
    F := F + 2.7;                       // ~ halbe Bin-Breite (5,4 Hz): kein Spiegelton faellt durch
  end;
  Result := 10 * Log10(Max(PA, 1E-30) / Max(P0, 1E-30));
end;

{ Gezeichnete Oszillator-Welle: Kern SIMD gegen Pascal, Spiegelanteil einer gezeichneten Saege in hoher
  Lage (bandbegrenzte Wavetable: muss sauberer sein als die eingebaute Saege), Speichern/Laden }
{ Oversampling nur wo noetig: Sinus und gezeichnete Welle ohne Sync rechnen auch bei HQ ohne Oversampling
  (dort entstehen keine Spiegelfrequenzen) - Ausgabe gleich wie mit Oversampling aus, Rechenzeit gleich }
{ Feedback-Resampling: Tonhoehe bleibt ueber viele Durchlaeufe stehen (keine Drift, auch mit Pitch-Regler),
  Pegel laeuft nicht weg, Aus = wieder das Original, Uebernehmen klingt auf derselben Tonhoehe }
{ Arp als MIDI: Datei schreiben, zuruecklesen, Tonfolge/Zeiten pruefen und Anschlaege mit der Engine vergleichen
  (C-E-G, hoch + runter, 2 Oktaven, 1/16, 8 Schritte mit Pause auf Schritt 4, 120 BPM, 1 Takt) }
function CheckArpMidi: string;
const
  EXP_IDX: array[0..13] of Integer = (0, 1, 2, 3, 4, 5, 4, 3, 2, 1, 0, 1, 2, 3);
  SEQ6: array[0..5] of Integer = (60, 64, 67, 72, 76, 79);
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  Fn: string;
  D: TBytes;
  Pos, Tick, N, I, K, Ons, Offs, Bad, EngOn, B, Step: Integer;
  St: Byte;
  Ok: Boolean;

  function VarLen: Integer;
  var
    C: Byte;
  begin
    Result := 0;
    repeat
      C := D[Pos];
      Inc(Pos);
      Result := (Result shl 7) or (C and $7F);
    until C and $80 = 0;
  end;

begin
  Fn := TPath.Combine(TPath.GetTempPath, 'GranularSynth_bench_arp.mid');
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpTempo, PlainToParam(gpTempo, 120));
    E.SetParamById(gpArpOn, StepToParam(Ord(gpArpOn), 1));
    E.SetParamById(gpArpMode, StepToParam(Ord(gpArpMode), 2));
    E.SetParamById(gpArpOct, StepToParam(Ord(gpArpOct), 1));
    E.SetParamById(gpArpRate, StepToParam(Ord(gpArpRate), 3));
    E.SetParamById(gpArpSteps, StepToParam(Ord(gpArpSteps), 7));
    E.SetParamById(gpArpSwing, PlainToParam(gpArpSwing, 0));
    E.SetParamById(gpArpGate, PlainToParam(gpArpGate, 50));
    E.ArpMask := $FFFF and not Cardinal(1 shl 3);
    E.Process(nil, nil, @L[0], @R[0], 512);
    B := E.NoteOnCount;
    E.NoteOn(60, 0.8); E.NoteOn(64, 0.8); E.NoteOn(67, 0.8);
    for I := 0 to 171 do E.Process(nil, nil, @L[0], @R[0], 512);         // knapp 1 Takt (2 s)
    EngOn := E.NoteOnCount - B;                                         // nur vom Arp gestartete Stimmen
    Ok := WriteArpMidi(E, 1, Fn);
  finally
    E.Free;
  end;
  Ons := 0; Offs := 0; Bad := 0;
  if Ok then
  begin
    D := TFile.ReadAllBytes(Fn);
    TFile.Delete(Fn);
    Ok := (Length(D) > 22) and (D[0] = Ord('M')) and (D[14] = Ord('M')) and (D[12] = 1) and (D[13] = $E0);
    Pos := 22;
    Tick := 0;
    while Ok and (Pos < Length(D)) do
    begin
      Inc(Tick, VarLen);
      St := D[Pos];
      if St = $FF then
      begin
        if D[Pos + 1] = $2F then
          Break;
        N := D[Pos + 2];
        Inc(Pos, 3 + N);
      end
      else
      begin
        if St = $90 then
        begin
          // Erwartet: Schritt 0,1,2,4,5,... (Schritt 3 und 11 Pause), je 120 Ticks
          if Ons <= High(EXP_IDX) then
          begin
            K := Ons;
            Step := K + Ord(K >= 3) + Ord(K >= 10);
            if (D[Pos + 1] <> SEQ6[EXP_IDX[K]]) or (Tick <> Step * 120) then
              Inc(Bad);
          end;
          Inc(Ons);
        end
        else if St = $80 then
          Inc(Offs)
        else
          Inc(Bad);
        Inc(Pos, 3);
      end;
    end;
  end;
  Result := Format('Arp als MIDI: %d Noten (erwartet 14, Engine %d), %d Note-Aus, %d Abweichungen -> %s',
    [Ons, EngOn, Offs, Bad, IfThen(Ok and (Ons = 14) and (Offs = 14) and (Bad = 0) and (EngOn = 14), 'OK', 'FEHLER')]);
end;

{ Resampling per Automation bei geschlossenem Editor: ohne ResPrepare-Aufruf muss der Helfer-Thread die
  Puffer anlegen, danach entwickelt sich der Klang (Durchlaeufe > 0) }
function CheckResAutoAlloc: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, Wait: Integer;
  Ready: Boolean;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.SetParamById(gpResOn, StepToParam(Ord(gpResOn), 1));      // wie Automation: nur der Parameter
    E.SetParamById(gpResTime, PlainToParam(gpResTime, 500));
    E.Process(nil, nil, @L[0], @R[0], 512);
    Wait := 0;
    while not E.ResReady and (Wait < 200) do
    begin
      Sleep(10);
      Inc(Wait);
    end;
    Ready := E.ResReady;
    E.NoteOn(60, 0.8);
    for B := 0 to 4 * SR div 512 do
      E.Process(nil, nil, @L[0], @R[0], 512);
    Result := Format('Resampling per Automation: Puffer nach %d ms, %d Durchlaeufe in 4 s -> %s',
      [Wait * 10, E.ResPasses, IfThen(Ready and (E.ResPasses >= 3), 'OK', 'FEHLER')]);
  finally
    E.Free;
  end;
end;

{ Sample-Editor: Schneiden, Loeschen (Naht), Blenden, Normalisieren, Umkehren, Stille entfernen, Nulldurchgang -
  an einem kuenstlichen Signal (0,1 s Stille + 1 s Sinus 441 Hz mit Amplitude 0,25 + 0,1 s Stille, 44,1 kHz) }
function CheckSampleEdit: string;
const
  N0 = 4410;     // Stille vorn/hinten
  NS = 44100;    // Sinus
var
  D, C: TSampleData;
  I, Fails, Z, Trimmed: Integer;
  Gain, MaxStep: Double;
  Msg: string;

  function Make: TSampleData;
  var
    K: Integer;
  begin
    Result := TSampleData.Create;
    Result.SampleRate := 44100;
    Result.Channels := 2;
    Result.Frames := 2 * N0 + NS;
    SetLength(Result.L, Result.Frames);
    SetLength(Result.R, Result.Frames);
    for K := 0 to NS - 1 do
    begin
      Result.L[N0 + K] := 0.25 * Sin(2 * Pi * 441 * K / 44100);
      Result.R[N0 + K] := Result.L[N0 + K];
    end;
  end;

  procedure Fail(const What: string);
  begin
    Inc(Fails);
    Msg := Msg + ' ' + What;
  end;

begin
  Fails := 0;
  Msg := '';
  D := Make;
  try
    // Nulldurchgang: 441 Hz -> alle 50 Frames; 1/4 Periode daneben muss auf den Durchgang ziehen
    Z := SnapZero(D, N0 + 100 + 12);
    if Abs(Z - (N0 + 100)) > 1 then Fail('Nulldurchgang');
    // Normalisieren: 0,25 -> 0,977 = +11,8 dB
    Gain := SampleNormalize(D, 0, D.Frames);
    if (Abs(Gain - 20 * Log10(EDIT_NORM_PEAK / 0.25)) > 0.05) or (Abs(SamplePeak(D, 0, D.Frames) - EDIT_NORM_PEAK) > 0.001) then
      Fail('Normalisieren');
    // Stille entfernen: 2 x 0,1 s weg, je 5 ms Rand bleibt
    Trimmed := SampleTrimSilence(D);
    if Abs(Trimmed - (2 * N0 - 2 * 221)) > 4 then Fail(Format('Stille(%d)', [Trimmed]));
    // Einblenden: erster Frame 0, Mitte unveraendert
    C := SampleClone(D);
    try
      SampleFadeIn(C, 0, 4410);
      if (Abs(C.L[0]) > 1E-6) or (Abs(C.L[10000] - D.L[10000]) > 1E-6) then Fail('Einblenden');
      SampleFadeOut(C, C.Frames - 4410, C.Frames);
      if Abs(C.L[C.Frames - 1]) > 1E-6 then Fail('Ausblenden');
    finally
      C.Free;
    end;
    // Umkehren zweimal = Original
    C := SampleClone(D);
    try
      SampleReverse(C, 0, C.Frames);
      if Abs(C.L[0] - D.L[D.Frames - 1]) > 1E-6 then Fail('Umkehren');
      SampleReverse(C, 0, C.Frames);
      for I := 0 to C.Frames - 1 do
        if C.L[I] <> D.L[I] then begin Fail('Umkehren2'); Break; end;
    finally
      C.Free;
    end;
    // Zuschneiden: genau die Laenge
    C := SampleClone(D);
    try
      SampleCrop(C, 1000, 23050);
      if (C.Frames <> 22050) or (C.L[0] <> D.L[1000]) then Fail('Zuschneiden');
    finally
      C.Free;
    end;
    // Loeschen mitten im Sinus (an Nulldurchgaengen): Laenge kuerzer um Bereich + Naht, kein Sprung an der Naht
    C := SampleClone(D);
    try
      SampleDelete(C, SnapZero(C, 10000), SnapZero(C, 20000));
      if Abs(C.Frames - (D.Frames - 10000 - Round(EDIT_JOIN_SEC * 44100))) > 2 then Fail(Format('Loeschen(%d)', [C.Frames]));
      MaxStep := 0;
      for I := 9800 to 10200 do
        MaxStep := Max(MaxStep, Abs(C.L[I] - C.L[I - 1]));
      // Sinus 441 Hz bei 0,977: groesster Schritt je Frame ~0,061
      if MaxStep > 0.08 then Fail(Format('Naht %.3f', [MaxStep]));
    finally
      C.Free;
    end;
    SampleFinish(D);
    if Length(D.LR) < 2 * D.Frames then Fail('LR');
  finally
    D.Free;
  end;
  Result := 'Sample-Editor: Nulldurchgang, Normalisieren, Stille, Blenden, Umkehren, Schneiden, Loeschen' +
    IfThen(Fails = 0, ' -> OK', ':' + Msg + ' -> FEHLER');
end;

{ Tonleiter: weisse Tasten spielen C-Moll (D4 = D, E4 = Es, A4 = As, C#4 stumm) und ein Sinus-Oszillator
  rastet in C-Moll ein (Taste E4 klingt als F4, gemessen mit YIN) }
{ Gleiten je Stufe (freier LFO): markierte Stufe rutscht vom vorigen Wert herueber, unmarkierte
  springen; Chunk speichert die Schalter nur, wenn welche gesetzt sind, und laedt sie wieder }
function CheckFreeGlide: string;
var
  F: TFreeLfo;
  E, E2: TGranularEngine;
  Ch: TBytes;
  Sp: string;
  VHard, VGl, VEnd, VWant: Single;
  Plain, Back: Boolean;
begin
  FreeLfoDefault(F);
  F.Mode := 1;
  F.Steps := 8;
  F.Step[0] := 0;
  F.Step[1] := 1;
  VHard := FreeLfoValue(F, (1 + 0.1) / 8);          // Stufe 1 kurz nach Beginn, ohne Gleiten
  F.Glide := UInt64(1) shl 1;
  VGl := FreeLfoValue(F, (1 + 0.1) / 8);            // mit Gleiten: noch zwischen 0 und 1
  VEnd := FreeLfoValue(F, (1 + 0.8) / 8);           // nach dem Gleiten: Zielwert
  VWant := 0.5 - 0.5 * Cos(Pi * 0.1 / FREE_GLIDE_LEN);
  E := TGranularEngine.Create;
  E2 := TGranularEngine.Create;
  try
    Ch := SaveChunk(E, '');
    Plain := Pos('FGLD', TEncoding.ANSI.GetString(Ch)) = 0;
    E.FreeLfo[3].Glide := $8000000000000005;
    Ch := SaveChunk(E, '');
    Back := LoadChunk(E2, Ch, Sp) and (E2.FreeLfo[3].Glide = $8000000000000005) and (E2.FreeLfo[0].Glide = 0);
  finally
    E.Free;
    E2.Free;
  end;
  Result := Format('Gleiten je Stufe: ohne %.3f, mit %.3f (soll %.3f), danach %.3f, Chunk ohne Gleiten unveraendert %s, ' +
    'Speichern/Laden %s', [VHard, VGl, VWant, VEnd, BoolToStr(Plain, True), BoolToStr(Back, True)]);
  if (Abs(VHard - 1) < 1E-6) and (Abs(VGl - VWant) < 1E-5) and (VGl > 0.01) and (VGl < 0.99) and
    (Abs(VEnd - 1) < 1E-6) and Plain and Back then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

function CheckScaleKeys: string;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  P: TPitchTracker;
  B, Fails, Cnt: Integer;
  Sum: Double;
  Msg: string;

  procedure Expect(Key, Want: Integer);
  var
    Got: Boolean;
  begin
    E.NoteOn(Key, 0.8);
    E.Process(nil, nil, @L[0], @R[0], 512);
    if Want < 0 then
      Got := E.VoiceOfNote(Key) < 0
    else
      Got := E.VoiceOfNote(Want) >= 0;
    if not Got then
    begin
      Inc(Fails);
      Msg := Msg + Format(' Taste %d', [Key]);
    end;
    E.NoteOff(Key);
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.AllNotesOff;
    E.Process(nil, nil, @L[0], @R[0], 512);
  end;

begin
  Fails := 0;
  Msg := '';
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpScale, StepToParam(Ord(gpScale), 2));          // Moll
    E.SetParamById(gpScaleRoot, StepToParam(Ord(gpScaleRoot), 0));  // C
    E.SetParamById(gpScaleKeys, StepToParam(Ord(gpScaleKeys), 1));  // weisse Tasten
    E.Process(nil, nil, @L[0], @R[0], 512);
    Expect(60, 60); Expect(62, 62); Expect(64, 63); Expect(65, 65); Expect(69, 68); Expect(71, 70);
    Expect(72, 72); Expect(59, 58); Expect(61, -1);
  finally
    E.Free;
  end;

  // Oszillator rastet ein: nur Sinus-Oszillator, C-Moll, Taste E4 -> F4 (MIDI 65)
  E := TGranularEngine.Create;
  P := TPitchTracker.Create;
  try
    E.SetSampleRate(SR);
    P.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 0));
    E.SetParamById(gpScale, StepToParam(Ord(gpScale), 2));
    E.SetParamById(gpScaleRoot, StepToParam(Ord(gpScaleRoot), 0));
    E.Process(nil, nil, @L[0], @R[0], 512);
    E.NoteOn(64, 0.8);
    Sum := 0;
    Cnt := 0;
    for B := 0 to SR div 512 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      P.Process(@L[0], @R[0], 512);
      if (B > 20) and P.Valid then
      begin
        Sum := Sum + P.Note;
        Inc(Cnt);
      end;
    end;
    if (Cnt = 0) or (Abs(Sum / Cnt - 65) > 0.3) then
    begin
      Inc(Fails);
      if Cnt > 0 then Msg := Msg + Format(' Osz %.2f statt 65', [Sum / Cnt]) else Msg := Msg + ' Osz ohne Ton';
    end;
  finally
    P.Free;
    E.Free;
  end;
  Result := 'Tonleiter: weisse Tasten in C-Moll, Oszillator rastet ein (E4 -> F4)' +
    IfThen(Fails = 0, ' -> OK', ':' + Msg + ' -> FEHLER');
end;

function CheckResample: string;

  function Run(Note: Integer; PitchSemis, Mix: Double; Synced: Boolean; out N1, N2, LvlDb: Double; out Passes: Integer;
    out Restored: Boolean): Boolean;
  var
    E: TGranularEngine;
    L, R: array[0..511] of Single;
    B, Blocks: Integer;
    P: TPitchTracker;
    Sum1, Sum2: Double;
    Cnt1, Cnt2, K: Integer;
    Notes: array of Double;
    NC: Integer;

    function Median: Double;
    var
      I, J: Integer;
      T: Double;
    begin
      for I := 1 to NC - 1 do
      begin
        T := Notes[I];
        J := I - 1;
        while (J >= 0) and (Notes[J] > T) do
        begin
          Notes[J + 1] := Notes[J];
          Dec(J);
        end;
        Notes[J + 1] := T;
      end;
      if NC = 0 then Result := 0 else Result := Notes[NC div 2];
    end;

  begin
    E := TGranularEngine.Create;
    P := TPitchTracker.Create;
    try
      E.SetSampleRate(SR);
      P.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpPitch, PlainToParam(gpPitch, PitchSemis));
      E.SetParamById(gpResOn, 1);
      E.SetParamById(gpResMix, PlainToParam(gpResMix, Mix));
      if Synced then
        E.SetParamById(gpResSync, StepToParam(Ord(gpResSync), 2))     // 1/2 bei 120 BPM = 1 s
      else
        E.SetParamById(gpResTime, PlainToParam(gpResTime, 700));
      E.ResPrepare;
      E.NoteOn(Note, 0.8);
      Blocks := Round(20 * SR / 512);
      SetLength(Notes, Blocks);
      Sum1 := 0; Sum2 := 0; Cnt1 := 0; Cnt2 := 0;
      N1 := 0;
      NC := 0;
      for B := 0 to Blocks - 1 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        P.Process(@L[0], @R[0], 512);
        // Bezug: 2. Sekunde (Original), Vergleich: letzte 5 Sekunden (viele Durchlaeufe spaeter)
        if (B >= SR div 512) and (B < 2 * SR div 512) then
        begin
          for K := 0 to 511 do Sum1 := Sum1 + Sqr(L[K]) + Sqr(R[K]);
          Inc(Cnt1, 512);
          if P.Valid then begin Notes[NC] := P.Note; Inc(NC); end;
          if B = 2 * SR div 512 - 1 then
          begin
            N1 := Median;
            NC := 0;
          end;
        end
        else if B >= Blocks - 5 * SR div 512 then
        begin
          for K := 0 to 511 do Sum2 := Sum2 + Sqr(L[K]) + Sqr(R[K]);
          Inc(Cnt2, 512);
          if P.Valid then begin Notes[NC] := P.Note; Inc(NC); end;
        end;
      end;
      N2 := Median;
      Passes := E.ResPasses;
      LvlDb := 10 * Log10(Max(1E-20, Sum2 / Max(1, Cnt2)) / Max(1E-20, Sum1 / Max(1, Cnt1)));
      // neuer Anschlag: zurueck zum Original; danach Aus
      E.NoteOn(Note, 0.8);
      E.Process(nil, nil, @L[0], @R[0], 512);
      Restored := not E.ResActive;
      E.SetParamById(gpResOn, 0);
      E.Process(nil, nil, @L[0], @R[0], 512);
      Restored := Restored and not E.ResActive and (E.Sample <> nil) and (E.Sample.Frames > 0);
      Result := True;
    finally
      P.Free;
      E.Free;
    end;
  end;

var
  A1, A2, ALv, B1, B2, BLv: Double;
  PA, PB: Integer;
  RA, RB, Ok: Boolean;
begin
  Run(67, 0, 100, False, A1, A2, ALv, PA, RA);       // G4, jeder Durchlauf ersetzt ganz
  Run(60, 7, 50, True, B1, B2, BLv, PB, RB);        // C4 mit Pitch +7, halb beigemischt
  Ok := (PA >= 20) and (PB >= 15) and RA and RB and
    (Abs(A2 - A1) < 0.5) and (Abs(B2 - B1) < 0.5) and (Abs(A1 - 67) < 0.5) and (Abs(B1 - 67) < 0.5) and
    (Abs(ALv) < 6) and (Abs(BLv) < 6);
  Result := Format('Resampling (Taste gehalten): G4 100 %%, 0,7 s: %d Durchlaeufe, Ton %.2f -> %.2f, Pegel %.1f dB | ' +
    'C4+7 50 %%, 1/2 Takt: %d Durchlaeufe, Ton %.2f -> %.2f, Pegel %.1f dB | neuer Anschlag und Aus = Original %s',
    [PA, A1, A2, ALv, PB, B1, B2, BLv, IfThen(RA and RB, 'ok', 'FALSCH')]);
  if Ok then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

function CheckOsSkip: string;
var
  On: Boolean;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  Out: array[Boolean] of array of Single;
  Ms: array[Boolean] of Double;
  K, N, I: Integer;
  T0, T1, Fq: Int64;
  D: Double;
begin
  QueryPerformanceFrequency(Fq);
  for On := False to True do
  begin
    SetLength(Out[On], 431 * 512);
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
      E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
      E.SetParamById(gpOversample, StepToParam(Ord(gpOversample), Ord(On)));
      E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
      E.SetParamById(gpOsc2On, StepToParam(Ord(gpOsc2On), 1));
      E.SetParamById(gpOsc3On, StepToParam(Ord(gpOsc3On), 1));
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 0));
      E.SetParamById(gpOsc2Draw, StepToParam(Ord(gpOsc2Draw), 1));
      E.SetParamById(gpOsc3Wave, StepToParam(Ord(gpOsc3Wave), 0));
      E.SetParamById(gpOscUnison, PlainToParam(gpOscUnison, 3));
      E.SetParamById(gpOsc2Unison, PlainToParam(gpOsc2Unison, 3));
      E.SetParamById(gpOsc3Unison, PlainToParam(gpOsc3Unison, 3));
      for K := 0 to 7 do
        E.NoteOn(48 + K * 4, 0.7);
      QueryPerformanceCounter(T0);
      for N := 0 to 430 do
      begin
        E.Process(nil, nil, @L[0], @R[0], 512);
        Move(L[0], Out[On][N * 512], 512 * SizeOf(Single));
      end;
      QueryPerformanceCounter(T1);
      Ms[On] := (T1 - T0) * 1000 / Fq;
    finally
      E.Free;
    end;
  end;
  D := 0;
  for I := 0 to High(Out[False]) do
    D := Max(D, Abs(Out[True][I] - Out[False][I]));
  Result := Format('Oversampling nur wo noetig (Sinus + gezeichnet, 8 Stimmen, Unison 3): Abweichung %.1e, ' +
    'Rechenzeit %.0f ms -> %.0f ms', [D, Ms[False], Ms[True]]);
  if (D < 1E-6) and (Ms[True] < Ms[False] * 1.25 + 5) then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

{ Wavetable-Modell der eingebauten Wellen: Spiegelanteil (Saege/Rechteck E7) klassisch mit Oversampling
  gegen Wavetable ohne Oversampling; Bass-Bandbreite (Saege A1: Oberton 270 = 14,9 kHz muss da sein,
  Soll -20 log 270 = -48,6 dB zum Grundton); Gleiten ueber alle Stufen ohne Spruenge in den Hoehen;
  Rechenzeit HQ klassisch gegen Wavetable. }
function OscHarmDb(Classic: Boolean; Wave, Note, K: Integer): Double;
const
  WIN = 8192;
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  X: array of Double;
  B, I, Got: Integer;
  W, F0, Re, Im, C, S, Cd, Sd, T: Double;

  function Pow(Fr: Double): Double;
  var
    N: Integer;
  begin
    Re := 0; Im := 0; C := 1; S := 0;
    Cd := Cos(2 * Pi * Fr / SR); Sd := Sin(2 * Pi * Fr / SR);
    for N := 0 to WIN - 1 do
    begin
      Re := Re + X[N] * C;
      Im := Im + X[N] * S;
      T := C * Cd - S * Sd;
      S := S * Cd + C * Sd;
      C := T;
    end;
    Result := Re * Re + Im * Im;
  end;

begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
    E.SetParamById(gpFltOn, StepToParam(Ord(gpFltOn), 0));
    E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 0));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 0));
    E.SetParamById(gpLimiter, StepToParam(Ord(gpLimiter), 0));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), Wave));
    E.SetParamById(gpOscSustain, PlainToParam(gpOscSustain, 100));
    E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
    E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), Ord(Classic)));
    E.NoteOn(Note, 0.8);
    SetLength(X, WIN);
    Got := 0;
    for B := 0 to 40 do
    begin
      E.Process(nil, nil, @L[0], @R[0], 512);
      if B >= 8 then
        for I := 0 to 511 do
          if Got < WIN then
          begin
            W := Got / (WIN - 1) * 2 * Pi;
            X[Got] := L[I] * (0.35875 - 0.48829 * Cos(W) + 0.14128 * Cos(2 * W) - 0.01168 * Cos(3 * W));
            Inc(Got);
          end;
    end;
  finally
    E.Free;
  end;
  F0 := 440 * Power(2, (Note - 69) / 12);
  Result := 10 * Log10(Max(Pow(F0 * K), 1E-30) / Max(Pow(F0), 1E-30));
end;

{ Glide ueber 4 Oktaven: Anteil der Hoehen (2. Differenz) an der Gesamtenergie je Block darf zwischen
  Nachbarbloecken nicht springen (Stufenwechsel der Wavetable) }
var
  GGlideDbg: string;

function GlideJumpDb(Classic: Boolean): Double;
var
  E: TGranularEngine;
  L, R: array[0..255] of Single;
  B, I: Integer;
  En, Tot, Prev, Jmp, D: Double;
begin
  E := TGranularEngine.Create;
  try
    E.SetSampleRate(SR);
    E.LoadSample(CreateDemoSample(SR));
    E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
    E.SetParamById(gpFltOn, StepToParam(Ord(gpFltOn), 0));
    E.SetParamById(gpEchoOn, StepToParam(Ord(gpEchoOn), 0));
    E.SetParamById(gpRevOn, StepToParam(Ord(gpRevOn), 0));
    E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
    E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 2));
    E.SetParamById(gpOscSustain, PlainToParam(gpOscSustain, 100));
    E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
    E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), Ord(Classic)));
    E.SetParamById(gpBendRange, PlainToParam(gpBendRange, 24));
    E.PitchBend(-1);
    E.NoteOn(64, 0.8);
    for B := 0 to 20 do E.Process(nil, nil, @L[0], @R[0], 256);
    Prev := -1; Jmp := 0;
    En := 0; Tot := 0;
    for B := 0 to 1599 do
    begin
      E.PitchBend(-1 + 2 * B / 1600);          // Pitch-Bend +-24 Halbtoene: 4 Oktaven stufenlos
      E.Process(nil, nil, @L[0], @R[0], 256);
      for I := 2 to 255 do
      begin
        D := L[I] - 2 * L[I - 1] + L[I - 2];
        En := En + D * D;
        Tot := Tot + L[I] * L[I];
      end;
      if B mod 8 = 7 then                      // Fenster 2048 Samples: immer mehrere Perioden
      begin
        if Tot > 1E-9 then En := En / Tot else En := 0;
        if (B >= 40) and (Prev > 1E-12) and (En > 1E-12) and (Abs(10 * Log10(En / Prev)) > Jmp) then
        begin
          Jmp := Abs(10 * Log10(En / Prev));
          GGlideDbg := Format('Fenster %d: %.3g -> %.3g', [B div 8, Prev, En]);
        end;
        Prev := En;
        En := 0;
        Tot := 0;
      end;
    end;
  finally
    E.Free;
  end;
  Result := Jmp;
end;

{ MIDI aus der DAW: Noten mit Zeitversatz im Block (DeltaFrames), nach langer Stille, verschiedene
  Blockgroessen - jede muss so klingen wie ohne Versatz (Bildschirm-Klaviatur). }
function CheckMidiDelta: string;
const
  BLOCKS: array[0..3] of Integer = (64, 256, 512, 1024);
var
  B, Delta: Integer;
  Pk0, Pk: Double;
  Ok: Boolean;
  Info: string;

  function Run(Blk, Dlt: Integer): Double;
  var
    E: TGranularEngine;
    L, R: array of Single;
    K, I: Integer;
  begin
    Result := 0;
    SetLength(L, Blk); SetLength(R, Blk);
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(44100);
      E.LoadSample(CreateDemoSample(44100));
      for K := 0 to 400 do                         // lange Stille vorweg (Leerlauf-Ueberspringen aktiv)
        E.Process(nil, nil, @L[0], @R[0], Blk);
      E.NoteOn(60, 100 / 127, Dlt);
      for K := 0 to (44100 div Blk) do             // ~1 s
      begin
        E.Process(nil, nil, @L[0], @R[0], Blk);
        for I := 0 to Blk - 1 do
          Result := Max(Result, Abs(L[I]));
      end;
    finally
      E.Free;
    end;
  end;

begin
  Ok := True;
  Info := '';
  for B := 0 to High(BLOCKS) do
  begin
    Pk0 := Run(BLOCKS[B], 0);
    Delta := BLOCKS[B] div 2;
    Pk := Run(BLOCKS[B], Delta);
    Info := Info + Format(' %d:%.3f/%.3f', [BLOCKS[B], Pk0, Pk]);
    if (Pk0 < 0.01) or (Pk < Pk0 * 0.5) then
      Ok := False;
  end;
  Result := 'MIDI mit Versatz (Block: ohne/mit Versatz):' + Info + ' -> ' + IfThen(Ok, 'OK', 'FEHLER');
end;

{ Speichermanager: welcher ist aktiv (FastMM5 optional ueber FASTMM_DIR) und wie schnell sind viele kleine
  Anforderungen wie in der Oberflaeche (Strings, Listen, Objekte). Nur GUI/Host - der Audio-Thread fordert nichts an. }
function CheckMemManager: string;
const
  N = 400000;
var
  MM: TMemoryManagerEx;
  Watch: TStopwatch;
  I, K: Integer;
  P: array[0..63] of Pointer;
  S: string;
  L: TStringList;
  Name: string;
  Ok: Boolean;
begin
  GetMemoryManager(MM);
  {$IFDEF USE_FASTMM5}
  Ok := @MM.GetMem = @FastMM_GetMem;
  Name := 'FastMM5';
  {$ELSE}
  Ok := True;
  Name := 'Delphi-Standard (FASTMM_DIR nicht gesetzt)';
  {$ENDIF}
  FillChar(P, SizeOf(P), 0);
  Watch := TStopwatch.StartNew;
  for I := 0 to N - 1 do
  begin
    K := I and 63;
    FreeMem(P[K]);
    GetMem(P[K], 16 + (I * 37) and 1023);
  end;
  for K := 0 to 63 do
    FreeMem(P[K]);
  L := TStringList.Create;
  try
    for I := 0 to N div 4 - 1 do
    begin
      S := 'Regler ' + IntToStr(I) + ' = ' + FloatToStr(I * 0.5);
      L.Add(S);
      if L.Count > 500 then
        L.Clear;
    end;
  finally
    L.Free;
  end;
  Watch.Stop;
  Result := Format('Speichermanager: %s, %d kleine Bloecke + %d Strings in %.1f ms -> %s',
    [Name, N, N div 4, Watch.Elapsed.TotalMilliseconds, IfThen(Ok, 'OK', 'FEHLER')]);
end;

{ Speichern unter (Sample-Editor): WAV und MP3 (Media Foundation, 320 kbit/s) schreiben, wieder laden,
  Laenge und Pegel vergleichen; 96 kHz wird fuer MP3 auf 44,1 kHz umgerechnet. }
function CheckSaveAudio: string;
var
  Src, Back: TSampleData;
  Fn: string;
  RmsA, RmsB: Double;
  OkW, OkM, OkR: Boolean;
  Info: string;

  function Rms(D: TSampleData): Double;
  var
    F: Integer;
  begin
    Result := 0;
    for F := 0 to D.Frames - 1 do
      Result := Result + Sqr(D.L[F]) + Sqr(D.R[F]);
    Result := Sqrt(Result / Max(1, 2 * D.Frames));
  end;

begin
  Src := CreateDemoSample(44100);
  try
    RmsA := Rms(Src);
    Fn := TPath.Combine(TPath.GetTempPath, 'granular_save_test.wav');
    SaveAudioFile(Src, Fn);
    Back := LoadAudioFile(Fn);
    OkW := (Back.Frames = Src.Frames) and (Abs(Rms(Back) / RmsA - 1) < 0.02);
    Back.Free;
    System.SysUtils.DeleteFile(Fn);
    OkM := False; OkR := False; Info := '';
    if MediaFoundationAvailable then
    begin
      Fn := TPath.Combine(TPath.GetTempPath, 'granular_save_test.mp3');
      SaveAudioFile(Src, Fn);
      Back := LoadAudioFile(Fn);
      RmsB := Rms(Back);
      OkM := (Abs(Back.Frames - Src.Frames) < 4000) and (Abs(RmsB / RmsA - 1) < 0.1) and
        (Round(Back.SampleRate) = 44100);
      Info := Format('MP3 %d KB, %d statt %d Frames, Pegel %.3f', [TFile.GetSize(Fn) div 1024, Back.Frames,
        Src.Frames, RmsB / RmsA]);
      Back.Free;
      Src.SampleRate := 96000;                 // gleiche Daten als 96 kHz: MP3 wird 44,1 kHz, halb so viele Frames
      SaveAudioFile(Src, Fn);
      Back := LoadAudioFile(Fn);
      OkR := (Round(Back.SampleRate) = 44100) and (Abs(Back.Frames - Int64(Src.Frames) * 44100 div 96000) < 4000);
      Info := Info + Format('; 96k: %d Frames bei %.0f Hz', [Back.Frames, Back.SampleRate]);
      Back.Free;
      System.SysUtils.DeleteFile(Fn);
    end;
  finally
    Src.Free;
  end;
  Result := Format('Speichern unter: WAV %s, MP3 %s, 96 kHz -> 44,1 kHz %s (%s) -> %s',
    [BoolToStr(OkW, True), BoolToStr(OkM, True), BoolToStr(OkR, True), Info,
     IfThen(OkW and OkM and OkR, 'OK', 'FEHLER')]);
end;

function CheckWtFile: string;
var
  SawC, SawW, SqC, SqW, BassC, BassW, JmpC, JmpW: Double;
  On: Boolean;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  K, N: Integer;
  T0, T1, Fq: Int64;
  Ms: array[Boolean] of Double;
begin
  SawC := OsAliasDb(True, 2, 100, 0, 1, False, True);
  SawW := OsAliasDb(True, 2, 100, 0, 1, False, False);
  SqC := OsAliasDb(True, 3, 100, 0, 1, False, True);
  SqW := OsAliasDb(True, 3, 100, 0, 1, False, False);
  BassC := OscHarmDb(True, 2, 33, 270);
  BassW := OscHarmDb(False, 2, 33, 270);
  JmpC := GlideJumpDb(True);
  JmpW := GlideJumpDb(False);
  QueryPerformanceFrequency(Fq);
  for On := False to True do        // On = klassisch
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
      E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
      E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), Ord(On)));
      E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
      E.SetParamById(gpOsc2On, StepToParam(Ord(gpOsc2On), 1));
      E.SetParamById(gpOsc3On, StepToParam(Ord(gpOsc3On), 1));
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 2));
      E.SetParamById(gpOsc2Wave, StepToParam(Ord(gpOsc2Wave), 3));
      E.SetParamById(gpOsc3Wave, StepToParam(Ord(gpOsc3Wave), 1));
      E.SetParamById(gpOscUnison, PlainToParam(gpOscUnison, 3));
      E.SetParamById(gpOsc2Unison, PlainToParam(gpOsc2Unison, 3));
      E.SetParamById(gpOsc3Unison, PlainToParam(gpOsc3Unison, 3));
      for K := 0 to 7 do
        E.NoteOn(48 + K * 4, 0.7);
      QueryPerformanceCounter(T0);
      for N := 0 to 430 do
        E.Process(nil, nil, @L[0], @R[0], 512);
      QueryPerformanceCounter(T1);
      Ms[On] := (T1 - T0) * 1000 / Fq;
    finally
      E.Free;
    end;
  end;
  Result := Format('Wavetable-Wellen (HQ): Spiegelanteil Saege E7 klassisch %.1f -> Wavetable %.1f dB, Rechteck %.1f -> %.1f dB | ' +
    'Bass Saege A1, Oberton 270 (14,9 kHz): klassisch %.1f, Wavetable %.1f dB (Soll -48,6) | Pitch-Bend 4 Oktaven, groesste ' +
    'Aenderung des Hoehenanteils je Fenster: klassisch %.2f, Wavetable %.2f dB | Rechenzeit 8 Stimmen, Saege/Rechteck/Dreieck x Unison 3: ' +
    'klassisch %.0f ms, Wavetable %.0f ms',
    [SawC, SawW, SqC, SqW, BassC, BassW, JmpC, JmpW, Ms[True], Ms[False]]);
  if (SawW < SawC - 20) and (SqW < SqC - 20) and (Abs(BassW + 48.6) < 1.5) and (JmpW <= JmpC + 0.5) and
    (Ms[False] < Ms[True] * 1.15) then   // Klang zuerst: Rechenzeit hoechstens wenig ueber dem alten Weg
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

function CheckOscDraw: string;
var
  A, B: TWtArgs;
  Tab: array[0..2048 + 1] of Single;
  Tab2: array[0..1024 + 1] of Single;
  Env: array[0..255] of Single;
  OA, OB: array[0..511] of Single;
  I: Integer;
  D, AlOff, AlOn, SawOn: Double;
  E, E2: TGranularEngine;
  Ch: TBytes;
  Path: string;
  Ok: Boolean;
begin
  for I := 0 to 2048 + 1 do
    Tab[I] := Sin(2 * Pi * I / 2048) + 0.3 * Sin(6 * Pi * I / 2048);
  for I := 0 to 1024 + 1 do
    Tab2[I] := Sin(2 * Pi * I / 1024);
  for I := 0 to 255 do
    Env[I] := 0.4 + 0.3 * Sin(I * 0.07);
  FillChar(A, SizeOf(A), 0);
  A.Env := @Env[0]; A.TabA := @Tab[0]; A.TabB := @Tab2[0]; A.Count := 256; A.Ph := 0.37; A.DtP := 0.0213;
  A.SyncR := 1.7; A.GL := 0.8; A.GR := 1.1; A.CSizeA := 2048; A.CSizeB := 1024; A.Mix := 0.3; A.One := 1;
  B := A;
  FillChar(OA, SizeOf(OA), 0);
  FillChar(OB, SizeOf(OB), 0);
  A.Out := @OA[0];
  B.Out := @OB[0];
  RenderWt(@A);
  WtBlockPas(@B);
  D := Abs(A.Ph - B.Ph);
  for I := 0 to High(OA) do
    D := Max(D, Abs(OA[I] - OB[I]));
  // schneller Pfad (kein Sync, gleich lange Tabellen) gegen Pascal und gegen den allgemeinen Kern
  A.SyncR := 1; A.CSizeB := 2048; A.TabB := @Tab[0]; A.Ph := 0.37; B := A;
  FillChar(OA, SizeOf(OA), 0);
  FillChar(OB, SizeOf(OB), 0);
  A.Out := @OA[0];
  B.Out := @OB[0];
  RenderWtFast(@A);
  WtFastPas(@B);
  for I := 0 to High(OA) do
    D := Max(D, Abs(OA[I] - OB[I]));
  AlOff := OsAliasDb(False, 0, 100, 0, 1, True);
  AlOn := OsAliasDb(True, 0, 100, 0, 1, True);
  SawOn := OsAliasDb(True, 2, 100, 0, 1, False, True);
  E := TGranularEngine.Create;
  E2 := TGranularEngine.Create;
  try
    for I := 0 to OSC_DRAW_N - 1 do
      E.OscDraw[2].Pt[I] := Sin(4 * Pi * I / OSC_DRAW_N) * 0.7;
    E.OscDraw[2].Smooth := 0.42;
    E.OscDrawChanged(2);
    E.SetParamById(gpOsc3Draw, 1);
    Ch := SaveChunk(E, '');
    LoadChunk(E2, Ch, Path);
    Ok := CompareMem(E.OscDraw[2], E2.OscDraw[2], SizeOf(TOscDraw)) and
      (E2.GetParam(Ord(gpOsc3Draw)) >= 0.5) and CompareMem(E.OscWaveTable(2), E2.OscWaveTable(2), WT_LEN[0] * 4);
  finally
    E.Free;
    E2.Free;
  end;
  Result := Format('Gezeichnete Welle: Kern SIMD gegen Pascal max. %.1e | Spiegelanteil gezeichnete Saege E7 ' +
    '%.1f dB (mit Oversampling %.1f dB; klassische Saege %.1f dB) | Speichern/Laden %s',
    [D, AlOff, AlOn, SawOn, IfThen(Ok, 'ok', 'FALSCH')]);
  if (D < 1E-4) and (AlOn < SawOn - 10) and (AlOff < -50) and Ok then
    Result := Result + ' -> OK'
  else
    Result := Result + ' -> FEHLER';
end;

function CheckOversample: string;
var
  A, B: THbArgs;
  Src: array[0..599] of Single;
  OA, OB: array[0..599] of Single;
  I, Mode: Integer;
  D: Double;
  FmOff, FmOn, SawOff, SawOn, DrOff, DrOn, DrBase: Double;
  T0, T1, Fq: Int64;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  K, N: Integer;
  Ms: array[Boolean] of Double;
  On: Boolean;
begin
  RandSeed := 77;
  for I := 0 to High(Src) do
    Src[I] := Random * 2 - 1;
  D := 0;
  for Mode := 0 to 1 do
  begin
    if Mode = 0 then HbInitArgs(A, 1, HB_CENTER) else HbInitArgs(A, 2, 0);
    A.Count := 37;
    if Mode = 0 then
    begin
      A.InStep := 16; A.TapStep := 16; A.OutStep := 8;
      A.PC := PByte(@Src[80]); A.PD := PByte(@Src[78]); A.PA := PByte(@Src[82]);
    end
    else
    begin
      A.InStep := 8; A.TapStep := 8; A.OutStep := 16;
      A.PC := PByte(@Src[80]); A.PD := PByte(@Src[80]); A.PA := PByte(@Src[82]);
    end;
    FillChar(OA, SizeOf(OA), 0);
    FillChar(OB, SizeOf(OB), 0);
    B := A;
    A.Out := PByte(@OA[0]);
    B.Out := PByte(@OB[0]);
    RenderHbFir(@A);
    HbFirPas(@B);
    for I := 0 to High(OA) do
      D := Max(D, Abs(OA[I] - OB[I]));
    if A.PD <> B.PD then D := 1;
  end;
  FmOff := OsAliasDb(False, 4, 96, 0, 2);
  FmOn := OsAliasDb(True, 4, 96, 0, 2);
  SawOff := OsAliasDb(False, 2, 100, 0);
  SawOn := OsAliasDb(True, 2, 100, 0);
  DrOff := OsAliasDb(False, 0, 98, 100);
  DrOn := OsAliasDb(True, 0, 98, 100);
  DrBase := OsAliasDb(False, 0, 98, 0);
  // Rechenzeit: 8 Stimmen, drei FM-Oszillatoren mit Unison 3, Drive (ohne Grains)
  QueryPerformanceFrequency(Fq);
  for On := False to True do
  begin
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      E.LoadSample(CreateDemoSample(SR));
      E.SetParamById(gpGrainOn, StepToParam(Ord(gpGrainOn), 0));
      E.SetParamById(gpQuality, StepToParam(Ord(gpQuality), 1));
      E.SetParamById(gpOversample, StepToParam(Ord(gpOversample), Ord(On)));
      E.SetParamById(gpDrive, PlainToParam(gpDrive, 50));
      E.SetParamById(gpOscOn, StepToParam(Ord(gpOscOn), 1));
      E.SetParamById(gpOsc2On, StepToParam(Ord(gpOsc2On), 1));
      E.SetParamById(gpOsc3On, StepToParam(Ord(gpOsc3On), 1));
      E.SetParamById(gpOscWave, StepToParam(Ord(gpOscWave), 4));
      E.SetParamById(gpOsc2Wave, StepToParam(Ord(gpOsc2Wave), 2));
      E.SetParamById(gpOsc3Wave, StepToParam(Ord(gpOsc3Wave), 3));
      E.SetParamById(gpOscUnison, PlainToParam(gpOscUnison, 3));
      E.SetParamById(gpOsc2Unison, PlainToParam(gpOsc2Unison, 3));
      E.SetParamById(gpOsc3Unison, PlainToParam(gpOsc3Unison, 3));
      for K := 0 to 7 do
        E.NoteOn(48 + K * 4, 0.7);
      QueryPerformanceCounter(T0);
      for N := 0 to 430 do               // 5 s
        E.Process(nil, nil, @L[0], @R[0], 512);
      QueryPerformanceCounter(T1);
      Ms[On] := (T1 - T0) * 1000 / Fq;
    finally
      E.Free;
    end;
  end;
  Result := Format('Oversampling: Kern SIMD gegen Pascal max. %.1e%s | Spiegelanteil (dB rel. Grundton) ' +
    'FM C7 %.1f -> %.1f, Saegezahn E7 %.1f -> %.1f, Drive-Sinus D7 %.1f -> %.1f (ohne Drive %.1f) | Rechenzeit 5 s, 8 Stimmen, ' +
    '3 Osz. x Unison 3 + Drive: %.0f ms -> %.0f ms (%.2fx)',
    [D, IfThen(D < 1E-5, '', ' ABWEICHUNG!'), FmOff, FmOn, SawOff, SawOn, DrOff, DrOn, DrBase, Ms[False], Ms[True],
     Ms[True] / Max(Ms[False], 0.001)]);
  if (D >= 1E-5) or (FmOn > FmOff - 10) or (DrOn > DrOff - 10) then
    Result := Result + ' -> FEHLER'
  else
    Result := Result + ' -> OK';
end;

{ Hoerprobe Wavetable gegen klassisch (GranularHost.exe -abrender <Projektordner>): ausgewaehlte Presets mit
  Saege/Rechteck spielen eine kurze Phrase (tief bis hoch, dann Akkord), je einmal mit jedem Oszillator-Modell.
  WAV-Dateien nach <Projektordner>\Hoerprobe Wavetable\ (Name_A_klassisch.wav, Name_B_wavetable.wav). }
function RenderAB(const ProjectDir: string): string;
const
  PRESETS: array[0..5] of string = (
    '128 GRAINS + FM - Analog - Drei Saegen als breite Flaeche',
    '129 FM - Analog-Bass - Saege, Rechteck und Sub (Glide)',
    '132 FM - Pluck-Arp - Saege, Rechteck und Sub (Echo)',
    '134 FM - Sync-Lead - schneidend und gleitend',
    '147 FM - Lead mit Biss (Glide)',
    '149 FM - Kreisch-Lead (Modrad = schaerfer)');
  MELODY: array[0..9] of Integer = (36, 43, 48, 55, 60, 67, 72, 79, 84, 91);
var
  Dir, OutDir, Path, Res, Name: string;
  P, M, K, B, F, NBlk: Integer;
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  Smp: TSampleData;
  Lines: TStringList;
begin
  Dir := IncludeTrailingPathDelimiter(ProjectDir);
  OutDir := Dir + 'Hoerprobe Wavetable' + PathDelim;
  ForceDirectories(OutDir);
  Lines := TStringList.Create;
  try
    for P := 0 to High(PRESETS) do
      for M := 0 to 1 do                   // 0 = klassisch, 1 = Wavetable
      begin
        E := TGranularEngine.Create;
        Smp := TSampleData.Create;
        try
          E.SetSampleRate(SR);
          if not LoadChunkFromFile(E, Dir + 'Presets' + PathDelim + PRESETS[P] + '.gspreset', Path) then
          begin
            Lines.Add('fehlt: ' + PRESETS[P]);
            Continue;
          end;
          Res := ResolveSamplePath(Path, Dir);
          if FileExists(Res) then
            E.LoadSample(LoadAudioFile(Res))
          else
            E.LoadSample(CreateDemoSample(SR));
          LoadMorphSample(E, Dir);
          LoadZoneSamples(E, Dir);
          E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), 1 - M));
          // Phrase: jede Note 0,4 s, dann ein Akkord 2,5 s, 1,5 s Ausklang
          NBlk := Round((Length(MELODY) * 0.4 + 4.0) * SR / 512);
          Smp.Frames := NBlk * 512;
          Smp.SampleRate := SR;
          Smp.Channels := 2;
          SetLength(Smp.L, Smp.Frames);
          SetLength(Smp.R, Smp.Frames);
          for B := 0 to NBlk - 1 do
          begin
            F := B * 512;
            K := Trunc(F / (0.4 * SR));
            if (K < Length(MELODY)) and (F mod Round(0.4 * SR) < 512) then
            begin
              if K > 0 then E.NoteOff(MELODY[K - 1]);
              E.NoteOn(MELODY[K], 0.8);
            end
            else if (K = Length(MELODY)) and (F mod Round(0.4 * SR) < 512) then
            begin
              E.NoteOff(MELODY[K - 1]);
              E.NoteOn(48, 0.8); E.NoteOn(55, 0.8); E.NoteOn(60, 0.8); E.NoteOn(64, 0.8);
            end;
            if F = Round((Length(MELODY) * 0.4 + 2.5) * SR) div 512 * 512 then
            begin
              E.NoteOff(48); E.NoteOff(55); E.NoteOff(60); E.NoteOff(64);
            end;
            E.Process(nil, nil, @L[0], @R[0], 512);
            Move(L[0], Smp.L[F], 512 * SizeOf(Single));
            Move(R[0], Smp.R[F], 512 * SizeOf(Single));
          end;
          Name := Copy(PRESETS[P], 1, Pos(' ', PRESETS[P]) - 1);
          if M = 0 then
            Name := OutDir + PRESETS[P] + ' - A klassisch.wav'
          else
            Name := OutDir + PRESETS[P] + ' - B wavetable.wav';
          SaveWaveFile(Smp, Name);
          Lines.Add(ExtractFileName(Name));
        finally
          Smp.Free;
          E.Free;
        end;
      end;
    Result := Format('%d Hoerproben in %s', [Lines.Count, OutDir]) + sLineBreak + Lines.Text;
  finally
    Lines.Free;
  end;
end;

{ Klang-Regression: jedes Preset spielt einen Akkord (1,5 s halten, 1 s Ausklang); Summe und Spitze des
  Ausgangs je Preset werden mit Demos\regress_ref.txt verglichen. Fehlt die Datei, wird sie angelegt
  (Referenz VOR einem Umbau erzeugen, danach muss jedes Preset gleich klingen). }
{ ein Preset fuer die Klang-Regression rendern (laeuft in einem Worker-Thread): Akkord 1,5 s halten,
  1 s ausklingen; Summe der Betraege und Spitze. False = Preset nicht ladbar }
function RenderRegressPreset(const Dir, Name: string; OsOn, Classic: Boolean; out Sum, Peak: Double): Boolean;
const
  CHORD: array[0..3] of Integer = (48, 55, 60, 64);
var
  E: TGranularEngine;
  L, R: array[0..511] of Single;
  B, K: Integer;
  Path, Res: string;
  ComOk: Boolean;
begin
  Result := False;
  Sum := 0;
  Peak := 0;
  // Worker-Thread: dieselbe Rechengenauigkeit wie der Hauptthread (sonst weichen die Bits ab) und COM
  // fuer Media Foundation (Audiodateien, die kein WAV sind)
  {$IFDEF CPUX86}
  Set8087CW(Default8087CW);
  {$ENDIF}
  SetMXCSR(DefaultMXCSR);
  ComOk := Succeeded(CoInitializeEx(nil, COINIT_MULTITHREADED));
  try
    E := TGranularEngine.Create;
    try
      E.SetSampleRate(SR);
      if not LoadChunkFromFile(E, Dir + 'Presets' + PathDelim + Name, Path) then
        Exit(False);
      Res := ResolveSamplePath(Path, Dir);
      if FileExists(Res) then
        E.LoadSample(LoadAudioFile(Res))
      else
        E.LoadSample(CreateDemoSample(SR));
      LoadMorphSample(E, Dir);
      LoadZoneSamples(E, Dir);
      E.SetParamById(gpOversample, StepToParam(Ord(gpOversample), Ord(OsOn)));
      E.SetParamById(gpOscModel, StepToParam(Ord(gpOscModel), Ord(Classic)));
      for K := 0 to High(CHORD) do
        E.NoteOn(CHORD[K], 0.8);
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
      Result := True;
    finally
      E.Free;
    end;
  finally
    if ComOk then
      CoUninitialize;
  end;
end;

function CheckRegression(OsOn: Boolean = False; Classic: Boolean = True): string;
var
  Dir, RefFile, Line, Bad: string;
  SR2: TSearchRec;
  Names, Ref, Outp: TStringList;
  I, K, Cnt, NBad: Integer;
  Sum, Peak, RSum, RPeak: Double;
  Parts: TArray<string>;
  FS: TFormatSettings;
  Sums, Peaks: TArray<Double>;
  Valid: TArray<Boolean>;
  Watch: TStopwatch;
  Took: string;
begin
  FS := TFormatSettings.Invariant;
  Dir := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..'));
  // ohne Oversampling: Referenz von vor dem Oversampling (Nov. 2026); mit: eigene Referenz
  // klassisches Modell: Referenzen von vor den Wavetables; Wavetable-Modell: eigene Referenz
  RefFile := Dir + 'Demos' + PathDelim + IfThen(not Classic, 'regress_ref_wt.txt', IfThen(OsOn, 'regress_ref_os.txt', 'regress_ref.txt'));
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
    // Rendern auf allen Kernen (jedes Preset in eigener Engine, unabhaengig); verglichen wird danach
    // der Reihe nach. Die globale Startwellen-Tabelle legt eine Engine vorab an (sonst Wettlauf).
    TGranularEngine.Create.Free;
    SetLength(Sums, Names.Count);
    SetLength(Peaks, Names.Count);
    SetLength(Valid, Names.Count);
    Watch := TStopwatch.StartNew;
    TParallel.For(0, Names.Count - 1,
      procedure(Idx: Integer)
      begin
        Valid[Idx] := RenderRegressPreset(Dir, Names[Idx], OsOn, Classic, Sums[Idx], Peaks[Idx]);
      end);
    Watch.Stop;
    for I := 0 to Names.Count - 1 do
    begin
      if not Valid[I] then
        Continue;
      Sum := Sums[I];
      Peak := Peaks[I];
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
    Took := Format(' (%.1f s, %d Kerne)', [Watch.Elapsed.TotalSeconds, TThread.ProcessorCount]);
    if Ref.Count = 0 then
    begin
      ForceDirectories(ExtractFilePath(RefFile));
      Outp.SaveToFile(RefFile, TEncoding.UTF8);
      Result := IfThen(not Classic, '[Wavetable] ', IfThen(OsOn, '[Oversampling] ', '')) + Format('Klang-Regression: Referenz fuer %d Presets angelegt (%s)', [Cnt, RefFile]);
    end
    else if NBad = 0 then
      Result := IfThen(not Classic, '[Wavetable] ', IfThen(OsOn, '[Oversampling] ', '')) + Format('Klang-Regression: %d Presets wie die Referenz%s -> OK', [Cnt, Took])
    else
      Result := IfThen(not Classic, '[Wavetable] ', IfThen(OsOn, '[Oversampling] ', '')) + Format('Klang-Regression: FEHLER %d von %d Presets weichen ab:%s', [NBad, Cnt, Bad]);
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

{ Laufzeit je Check (bench_zeiten.txt neben der EXE): zeigt, wo der Pruefstand seine Zeit verbringt }
var
  GLapWatch: TStopwatch;
  GLaps: TStringList;

function Lap(const Name, Res: string): string;
begin
  // der Check ist beim Aufruf schon gelaufen (Argument): Zeit seit dem letzten Lap gehoert zu ihm
  if GLaps = nil then
    GLaps := TStringList.Create;
  GLaps.Add(Format('%8.1f s  %s', [GLapWatch.Elapsed.TotalSeconds, Name]));
  GLapWatch := TStopwatch.StartNew;
  Result := Res;
end;

{ Sequencer-Pausen: Stufe als Pause markiert -> trockener Klang schweigt (Rampe), sonst unveraendert;
  Speichern/Laden der Pausen-Bits }
function CheckFreeRest: string;
var
  F: TFreeLfo;
  E, E2: TGranularEngine;
  D: TBytes;
  Path: string;
  PkOn, PkRest: Double;
  OkFn, OkIo: Boolean;

  function Run(RestBits: UInt64): Double;
  var
    En: TGranularEngine;
    L, R: array of Single;
    K, I: Integer;
  begin
    Result := 0;
    SetLength(L, 256); SetLength(R, 256);
    En := TGranularEngine.Create;
    try
      En.SetSampleRate(44100);
      En.LoadSample(CreateDemoSample(44100));
      En.SetParamById(LFO_SHAPE_IDS[0], StepToParam(Ord(LFO_SHAPE_IDS[0]), LFO_SHAPE_FREE));
      En.FreeLfo[LFO_FREE_IDX[0]].Rest := RestBits;
      En.NoteOn(60, 100 / 127, 0);
      for K := 0 to 40 do
        En.Process(nil, nil, @L[0], @R[0], 256);   // Rampe und Einschwingen
      for K := 0 to 40 do
      begin
        En.Process(nil, nil, @L[0], @R[0], 256);
        for I := 0 to 255 do
          Result := Max(Result, Abs(L[I]));
      end;
    finally
      En.Free;
    end;
  end;

begin
  FreeLfoDefault(F);
  F.Mode := 1;
  F.Steps := 4;
  F.Rest := 2;   // Stufe 1 = Pause
  OkFn := not FreeLfoRestAt(F, 0.1) and FreeLfoRestAt(F, 0.3) and not FreeLfoRestAt(F, 0.6);
  PkOn := Run(0);
  PkRest := Run(High(UInt64));   // alle Stufen Pause -> still
  E := TGranularEngine.Create;
  E2 := TGranularEngine.Create;
  try
    E.FreeLfo[3].Rest := $A5;
    D := SaveChunk(E, '');
    LoadChunk(E2, D, Path);
    OkIo := E2.FreeLfo[3].Rest = $A5;
  finally
    E.Free;
    E2.Free;
  end;
  Result := Format('Sequencer-Pausen: Stufe %s, Pegel ohne/mit Pause %.3f/%.5f, Speichern %s -> %s',
    [IfThen(OkFn, 'OK', 'FEHLER'), PkOn, PkRest, IfThen(OkIo, 'OK', 'FEHLER'),
     IfThen(OkFn and OkIo and (PkOn > 0.01) and (PkRest < PkOn * 0.01), 'OK', 'FEHLER')]);
end;

{ Reine Klang-/Engine-Checks ohne GUI und ohne globalen Zustand: parallel auf allen Kernen,
  Ergebnis in fester Reihenfolge (spart Zeit beim Deploy). Nur Checks mit eigener Engine hier aufnehmen! }
function RunParallelChecks: string;
const
  NAMES: array[0..2] of string = ('CheckFreeRest', 'CheckFreeSmooth', 'CheckMidiDelta');
var
  Res: array[0..2] of string;
begin
  TGranularEngine.Create.Free;   // globale Tabellen vorab (sonst Wettlauf)
  TParallel.For(0, High(NAMES),
    procedure(Idx: Integer)
    begin
      {$IFDEF CPUX86}Set8087CW(Default8087CW);{$ENDIF}
      SetMXCSR(DefaultMXCSR);   // Worker-Threads: Delphi-Standard wie im Hauptthread
      case Idx of
        0: Res[Idx] := CheckFreeRest;
        1: Res[Idx] := CheckFreeSmooth;
        2: Res[Idx] := CheckMidiDelta;
      end;
    end);
  Result := Lap('Parallel: ' + string.Join(', ', NAMES), Res[0] + sLineBreak + Res[1] + sLineBreak + Res[2]);
end;


procedure SaveLaps;
begin
  if GLaps = nil then
    Exit;
  try
    GLaps.SaveToFile(ExtractFilePath(ParamStr(0)) + 'bench_zeiten.txt');
  except
  end;
  FreeAndNil(GLaps);
end;

{ nur die Oberflaechen-Pruefungen (Uebersetzung, Textplatz) - fuer reine GUI-Aenderungen }
function RunTextBench: string;
begin
  Result := CheckLanguage + sLineBreak + CheckTextFit + sLineBreak;
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
  GLapWatch := TStopwatch.StartNew;
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
  Lap('Grundmessung (Pascal/SSE)', '');

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
  Result := Result + sLineBreak +
    RunParallelChecks + sLineBreak +
    Lap('CheckGfxKernel', CheckGfxKernel) + sLineBreak +
    Lap('CheckSpectrumKernels', CheckSpectrumKernels) + sLineBreak +
    Lap('CheckReverb', CheckReverb) + sLineBreak +
    Lap('CheckSat', CheckSat) + sLineBreak +
    Lap('CheckShape', CheckShape) + sLineBreak +
    Lap('CheckComp', CheckComp) + sLineBreak +
    Lap('CheckBassMono', CheckBassMono) + sLineBreak +
    Lap('CheckFxInSend', CheckFxInSend) + sLineBreak +
    Lap('CheckModEnv', CheckModEnv) + sLineBreak +
    Lap('CheckWtFile', CheckWtFile) + sLineBreak +
    Lap('CheckSaveAudio', CheckSaveAudio) + sLineBreak +
    Lap('CheckMemManager', CheckMemManager) + sLineBreak +
    Lap('CheckSubFx', CheckSubFx) + sLineBreak +
    Lap('CheckComb', CheckComb) + sLineBreak +
    Lap('CheckPhaser', CheckPhaser) + sLineBreak +
    Lap('CheckChorus', CheckChorus) +
    sLineBreak + Lap('CheckNewSound', CheckNewSound) + sLineBreak +
    Lap('CheckEq', CheckEq) + sLineBreak +
    Lap('CheckOsc', CheckOsc) + sLineBreak +
    Lap('CheckOutputStage', CheckOutputStage) + sLineBreak +
    Lap('CheckOutTrigger', CheckOutTrigger) + sLineBreak +
    Lap('CheckPolyMod', CheckPolyMod) + sLineBreak +
    Lap('CheckMorphLayers', CheckMorphLayers) + sLineBreak +
    Lap('CheckNoteLfoIsolation', CheckNoteLfoIsolation) + sLineBreak +
    Lap('CheckFreeLfo', CheckFreeLfo) + sLineBreak +
    Lap('CheckOsc123', CheckOsc123) + sLineBreak +
    Lap('CheckGrainLevel', CheckGrainLevel) + sLineBreak +
    Lap('CheckVstMap', CheckVstMap) + sLineBreak +
    Lap('CheckSwapAB', CheckSwapAB) + sLineBreak +
    Lap('CheckMixMeters', CheckMixMeters) + sLineBreak +
    Lap('CheckSourceRename', CheckSourceRename) + sLineBreak +
    Lap('CheckEnvSeg', CheckEnvSeg) + sLineBreak +
    Lap('CheckEventDelay', CheckEventDelay) + sLineBreak +
    Lap('CheckLfoStop', CheckLfoStop) + sLineBreak +
    Lap('CheckLfoPartner', CheckLfoPartner) + sLineBreak +
    Lap('CheckArpLatch', CheckArpLatch) + sLineBreak +
    Lap('CheckRegression', CheckRegression) + sLineBreak +
    Lap('CheckRegression(True)', CheckRegression(True)) + sLineBreak +
    Lap('CheckRegression(True, False)', CheckRegression(True, False)) + sLineBreak +
    Lap('CheckWavetable', CheckWavetable) + sLineBreak +
    Lap('CheckOversample', CheckOversample) + sLineBreak +
    Lap('CheckOscDraw', CheckOscDraw) + sLineBreak +
    Lap('CheckOsSkip', CheckOsSkip) + sLineBreak +
    Lap('CheckResample', CheckResample) + sLineBreak +
    Lap('CheckArpMidi', CheckArpMidi) + sLineBreak +
    Lap('CheckResAutoAlloc', CheckResAutoAlloc) + sLineBreak +
    Lap('CheckSampleEdit', CheckSampleEdit) + sLineBreak +
    Lap('CheckScaleKeys', CheckScaleKeys) + sLineBreak +
    Lap('CheckFreeGlide', CheckFreeGlide) + sLineBreak +
    Lap('CheckVst3', CheckVst3) + sLineBreak +
    Lap('CheckLfo58', CheckLfo58) + sLineBreak +
    Lap('CheckUserMacros', CheckUserMacros) + sLineBreak +
    Lap('CheckLanguage', CheckLanguage) + sLineBreak +
    Lap('CheckTextFit', CheckTextFit) + sLineBreak +
    Lap('CheckHostVst3', CheckHostVst3) + sLineBreak +
    Lap('CheckEmbedPreset', CheckEmbedPreset) + sLineBreak +
    Lap('CheckMidiLearn', CheckMidiLearn) +
    sLineBreak + Lap('CheckFxLoad', CheckFxLoad) + sLineBreak +
    Lap('CheckPreRoll', CheckPreRoll) + sLineBreak +
    Lap('CheckIdleSkip', CheckIdleSkip) + sLineBreak +
    Lap('CheckTwoInstances', CheckTwoInstances) + sLineBreak +
    Lap('CheckPresetLoad', CheckPresetLoad) + sLineBreak +
    Lap('CheckFullLoad', CheckFullLoad) + sLineBreak +
    Lap('CheckMood', CheckMood) + sLineBreak +
    Lap('CheckMoodSongs', CheckMoodSongs);
  SaveLaps;
end;

end.
