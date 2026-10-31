{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Eq;

{ Grafischer Equalizer: 28 Glockenfilter (Terz-Abstand, 31 Hz .. 16 kHz) aus einer frei
  gezeichneten Kurve, dazu Bass- und Hoehen-Shelf (automatisierbar). Biquads nach dem
  RBJ-Kochbuch, transponierte Direktform II.
  HQ: Koeffizienten UND Filterzustaende in doppelter Genauigkeit (64 Bit) - bei tiefen
  Frequenzen und vielen Filtern hintereinander bleibt so kein Rundungsrauschen/Grenzzyklus.
    EqBlockPas    Referenz (Pascal, Double)
    EqBlockSSE2   Win32/Win64 SSE2: L und R als zwei Doubles in einem Register (packed double)
  Ohne SSE2 (sehr alte CPU) rechnet die Pascal-Referenz, ebenfalls in Double.
  Baender mit 0 dB werden uebersprungen -> Rechenzeit nur fuer das, was eingestellt ist. }

interface

uses
  System.SysUtils, System.Math;

const
  EQ_CURVE_N = 64;          // Stuetzpunkte der gezeichneten Kurve (log. 20 Hz .. 20 kHz)
  EQ_BANDS = 28;            // Glockenfilter: 31,5 Hz .. 16 kHz in Terzschritten
  EQ_MAX_DB = 18;
  EQ_F_MIN = 20.0;
  EQ_F_MAX = 20000.0;

type
  TEqCurve = array[0..EQ_CURVE_N - 1] of Single;   // dB je Stuetzpunkt
  TBandGains = array[0..EQ_BANDS - 1] of Double;   // entworfene Bandpegel (dB)
  PEqCurve = ^TEqCurve;

  PEqBand = ^TEqBand;
  TEqBand = record           // 7 x 16 Byte: je Feld L und R als Double (packed fuer SSE2)
    B0, B1, B2, A1, A2: array[0..1] of Double;
    Z1, Z2: array[0..1] of Double;
  end;

  PEqArgs = ^TEqArgs;
  TEqArgs = record
    IO: PSingle;             // interleaved L R
    Count: Integer;          // Frames
    NBands: Integer;
    Bands: PEqBand;
    Dn: array[0..1] of Double;   // winziger Gleichanteil gegen Denormal-Zahlen
  end;

  TEqProc = procedure(Args: PEqArgs);

  TEqProcessor = class
  private
    FSampleRate: Double;
    FBands: array[0..EQ_BANDS + 3] of TEqBand;   // aktive Baender (dicht gepackt)
    FCount: Integer;
    FKeyCurve: Integer;      // Version der Kurve, fuer die zuletzt gerechnet wurde
    FKeyBass, FKeyTreble: Single;
    FKeyBands: array[0..3] of Single;
    FGains: TBandGains;
    FGainsVersion, FKeyCurveNew: Integer;
    FSinceDesign: Integer;            // Samples seit dem letzten Kurven-Neuentwurf
    FArgs: TEqArgs;
    procedure Design(const Curve: TEqCurve; BassDb, TrebleDb: Single; const Bands: array of Single);
  public
    constructor Create;
    procedure SetSampleRate(Value: Double);
    procedure Reset;
    { Bands = (Freq A, dB A, Freq B, dB B): zwei frei setzbare Glockenbaender (Matrix-Ziele) }
    procedure Process(IO: PSingle; N: Integer; const Curve: TEqCurve; CurveVersion: Integer;
      BassDb, TrebleDb: Single; const Bands: array of Single);
  end;

{ Mittenfrequenz von Band I und Kurvenwert bei Frequenz F (fuer Anzeige und Entwurf) }
function EqBandFreq(I: Integer): Double;
function EqCurveAt(const Curve: TEqCurve; F: Double): Double;
{ Betragsgang der kompletten Kette bei F in dB (Anzeige) }
function EqResponseDb(const Curve: TEqCurve; BassDb, TrebleDb: Single; F, SampleRate: Double;
  const Bands: array of Single): Double;

procedure EqBlockPas(Args: PEqArgs);
procedure EqBlockSSE2(Args: PEqArgs);

var
  EqBlock: TEqProc = EqBlockPas;

procedure InitEqDSP(UseSSE: Boolean);

implementation

{$POINTERMATH ON}

const
  BAND_Q = 3.0;              // etwas breiter als Terz -> glatt zwischen den Bandmitten
  SHELF_BASS_F = 120;
  SHELF_TREBLE_F = 6000;

type
  TCoef = record
    B0, B1, B2, A1, A2: Double;
  end;

function EqBandFreq(I: Integer): Double;
begin
  Result := 31.5 * Power(2, I / 3);     // 31,5 Hz .. 16 kHz in Terzschritten
end;

function EqCurveAt(const Curve: TEqCurve; F: Double): Double;
var
  X, T: Double;
  I: Integer;
begin
  X := Ln(EnsureRange(F, EQ_F_MIN, EQ_F_MAX) / EQ_F_MIN) / Ln(EQ_F_MAX / EQ_F_MIN) * (EQ_CURVE_N - 1);
  I := Min(Trunc(X), EQ_CURVE_N - 2);
  T := X - I;
  Result := Curve[I] + (Curve[I + 1] - Curve[I]) * T;
end;

function Peaking(F, Q, Db, Sr: Double): TCoef;
var
  A, W, Al, Cw, A0: Double;
begin
  A := Power(10, Db / 40);
  W := 2 * Pi * Min(F, Sr * 0.45) / Sr;
  Al := Sin(W) / (2 * Q);
  Cw := Cos(W);
  A0 := 1 + Al / A;
  Result.B0 := (1 + Al * A) / A0;
  Result.B1 := -2 * Cw / A0;
  Result.B2 := (1 - Al * A) / A0;
  Result.A1 := -2 * Cw / A0;
  Result.A2 := (1 - Al / A) / A0;
end;

function Shelf(F, Db, Sr: Double; High: Boolean): TCoef;
var
  A, W, Al, Cw, Sq, A0: Double;
begin
  A := Power(10, Db / 40);
  W := 2 * Pi * Min(F, Sr * 0.45) / Sr;
  Cw := Cos(W);
  Al := Sin(W) / 2 * Sqrt(2);          // Steilheit S = 1
  Sq := 2 * Sqrt(A) * Al;
  if not High then
  begin
    A0 := (A + 1) + (A - 1) * Cw + Sq;
    Result.B0 := A * ((A + 1) - (A - 1) * Cw + Sq) / A0;
    Result.B1 := 2 * A * ((A - 1) - (A + 1) * Cw) / A0;
    Result.B2 := A * ((A + 1) - (A - 1) * Cw - Sq) / A0;
    Result.A1 := -2 * ((A - 1) + (A + 1) * Cw) / A0;
    Result.A2 := ((A + 1) + (A - 1) * Cw - Sq) / A0;
  end
  else
  begin
    A0 := (A + 1) - (A - 1) * Cw + Sq;
    Result.B0 := A * ((A + 1) + (A - 1) * Cw + Sq) / A0;
    Result.B1 := -2 * A * ((A - 1) + (A + 1) * Cw) / A0;
    Result.B2 := A * ((A + 1) + (A - 1) * Cw - Sq) / A0;
    Result.A1 := 2 * ((A - 1) - (A + 1) * Cw) / A0;
    Result.A2 := ((A + 1) - (A - 1) * Cw - Sq) / A0;
  end;
end;

function CoefMagDb(const C: TCoef; F, Sr: Double): Double;
var
  W, Cr, Ci, Dr, Di, C1, S1, C2, S2: Double;
begin
  W := 2 * Pi * F / Sr;
  C1 := Cos(W); S1 := Sin(W); C2 := Cos(2 * W); S2 := Sin(2 * W);
  Cr := C.B0 + C.B1 * C1 + C.B2 * C2;
  Ci := -(C.B1 * S1 + C.B2 * S2);
  Dr := 1 + C.A1 * C1 + C.A2 * C2;
  Di := -(C.A1 * S1 + C.A2 * S2);
  Result := 10 * Log10(Max((Cr * Cr + Ci * Ci) / Max(Dr * Dr + Di * Di, 1E-20), 1E-20));
end;

{ Bandpegel so bestimmen, dass die Summe aller Baender an jeder Bandmitte die gezeichnete Kurve
  trifft (benachbarte Glockenfilter ueberlappen; ohne Korrektur entstehen Wellen und zu viel/
  zu wenig Anhebung). Einige Iterationen genuegen; nur bei Aenderung der Kurve gerechnet. }
function DesignGains(const Curve: TEqCurve; SampleRate: Double): TBandGains;
var
  It, I, J: Integer;
  Target, Resp: TBandGains;
begin
  for I := 0 to EQ_BANDS - 1 do
  begin
    Target[I] := EqCurveAt(Curve, EqBandFreq(I));
    Result[I] := Target[I];
  end;
  for It := 1 to 8 do
  begin
    for I := 0 to EQ_BANDS - 1 do
    begin
      Resp[I] := 0;
      for J := 0 to EQ_BANDS - 1 do
        if (Abs(Result[J]) > 0.01) and (EqBandFreq(J) < SampleRate * 0.45) then
          Resp[I] := Resp[I] + CoefMagDb(Peaking(EqBandFreq(J), BAND_Q, Result[J], SampleRate), EqBandFreq(I), SampleRate);
    end;
    for I := 0 to EQ_BANDS - 1 do
      Result[I] := EnsureRange(Result[I] + 0.75 * (Target[I] - Resp[I]), -24, 24);
  end;
end;

var
  GCacheKey: string;
  GCache: TBandGains;

function CachedGains(const Curve: TEqCurve; SampleRate: Double): TBandGains;
var
  K: string;
  I: Integer;
begin
  K := FloatToStr(SampleRate);
  for I := 0 to EQ_CURVE_N - 1 do
    K := K + '|' + IntToStr(Round(Curve[I] * 100));
  if K <> GCacheKey then
  begin
    GCache := DesignGains(Curve, SampleRate);
    GCacheKey := K;
  end;
  Result := GCache;
end;

function EqResponseDb(const Curve: TEqCurve; BassDb, TrebleDb: Single; F, SampleRate: Double;
  const Bands: array of Single): Double;
var
  Gs: TBandGains;
  I: Integer;
  G: Double;
begin
  Result := 0;
  Gs := CachedGains(Curve, SampleRate);
  for I := 0 to EQ_BANDS - 1 do
  begin
    G := Gs[I];
    if Abs(G) > 0.05 then
      Result := Result + CoefMagDb(Peaking(EqBandFreq(I), BAND_Q, G, SampleRate), F, SampleRate);
  end;
  if Abs(BassDb) > 0.05 then
    Result := Result + CoefMagDb(Shelf(SHELF_BASS_F, BassDb, SampleRate, False), F, SampleRate);
  if Abs(TrebleDb) > 0.05 then
    Result := Result + CoefMagDb(Shelf(SHELF_TREBLE_F, TrebleDb, SampleRate, True), F, SampleRate);
  for I := 0 to 1 do
    if (Length(Bands) >= I * 2 + 2) and (Abs(Bands[I * 2 + 1]) > 0.05) then
      Result := Result + CoefMagDb(Peaking(Bands[I * 2], 1.4, Bands[I * 2 + 1], SampleRate), F, SampleRate);
end;

{ ---------------- Rechenkern ---------------- }

procedure EqBlockPas(Args: PEqArgs);
var
  S, B: Integer;
  X0, X1, Y0, Y1: Double;
  Bd: PEqBand;
begin
  for S := 0 to Args.Count - 1 do
  begin
    X0 := Args.IO[S * 2] + Args.Dn[0];
    X1 := Args.IO[S * 2 + 1] + Args.Dn[1];
    Bd := Args.Bands;
    for B := 0 to Args.NBands - 1 do
    begin
      Y0 := Bd.B0[0] * X0 + Bd.Z1[0];
      Y1 := Bd.B0[1] * X1 + Bd.Z1[1];
      Bd.Z1[0] := (Bd.B1[0] * X0 - Bd.A1[0] * Y0) + Bd.Z2[0];
      Bd.Z1[1] := (Bd.B1[1] * X1 - Bd.A1[1] * Y1) + Bd.Z2[1];
      Bd.Z2[0] := Bd.B2[0] * X0 - Bd.A2[0] * Y0;
      Bd.Z2[1] := Bd.B2[1] * X1 - Bd.A2[1] * Y1;
      X0 := Y0;
      X1 := Y1;
      Inc(Bd);
    end;
    Args.IO[S * 2] := X0;
    Args.IO[S * 2 + 1] := X1;
  end;
end;

{$IF Defined(CPUX86)}
{ SSE2 (packed double): eax = Args. xmm0 = (L, R) als Double. Nur xmm0..xmm4. }
procedure EqBlockSSE2(Args: PEqArgs);
asm
        push    esi
        push    edi
        push    ebx
        mov     esi, [eax].TEqArgs.IO
        mov     ecx, [eax].TEqArgs.Count
        test    ecx, ecx
        jle     @done
        movupd  xmm4, [eax+TEqArgs.Dn]
@sample:
        cvtps2pd xmm0, [esi]               // 2 Singles -> 2 Doubles
        addpd   xmm0, xmm4
        mov     edi, [eax].TEqArgs.Bands
        mov     ebx, [eax].TEqArgs.NBands
        test    ebx, ebx
        jz      @store
@band:
        movupd  xmm1, [edi+TEqBand.B0]
        mulpd   xmm1, xmm0
        movupd  xmm2, [edi+TEqBand.Z1]
        addpd   xmm1, xmm2                 // y = b0*x + z1
        movupd  xmm2, [edi+TEqBand.B1]
        mulpd   xmm2, xmm0
        movupd  xmm3, [edi+TEqBand.A1]
        mulpd   xmm3, xmm1
        subpd   xmm2, xmm3
        movupd  xmm3, [edi+TEqBand.Z2]
        addpd   xmm2, xmm3
        movupd  [edi+TEqBand.Z1], xmm2     // z1 = b1*x - a1*y + z2
        movupd  xmm2, [edi+TEqBand.B2]
        mulpd   xmm2, xmm0
        movupd  xmm3, [edi+TEqBand.A2]
        mulpd   xmm3, xmm1
        subpd   xmm2, xmm3
        movupd  [edi+TEqBand.Z2], xmm2     // z2 = b2*x - a2*y
        movapd  xmm0, xmm1
        add     edi, TYPE TEqBand
        dec     ebx
        jnz     @band
@store:
        cvtpd2ps xmm0, xmm0
        movlps  [esi], xmm0
        add     esi, 8
        dec     ecx
        jnz     @sample
@done:
        pop     ebx
        pop     edi
        pop     esi
end;
{$ELSEIF Defined(CPUX64)}
procedure EqBlockSSE2(Args: PEqArgs);
asm
        mov     r8, [rcx].TEqArgs.IO
        mov     r9d, [rcx].TEqArgs.Count
        test    r9d, r9d
        jle     @done
        movupd  xmm4, [rcx+TEqArgs.Dn]
@sample:
        cvtps2pd xmm0, [r8]
        addpd   xmm0, xmm4
        mov     r10, [rcx].TEqArgs.Bands
        mov     r11d, [rcx].TEqArgs.NBands
        test    r11d, r11d
        jz      @store
@band:
        movupd  xmm1, [r10+TEqBand.B0]
        mulpd   xmm1, xmm0
        movupd  xmm2, [r10+TEqBand.Z1]
        addpd   xmm1, xmm2
        movupd  xmm2, [r10+TEqBand.B1]
        mulpd   xmm2, xmm0
        movupd  xmm3, [r10+TEqBand.A1]
        mulpd   xmm3, xmm1
        subpd   xmm2, xmm3
        movupd  xmm3, [r10+TEqBand.Z2]
        addpd   xmm2, xmm3
        movupd  [r10+TEqBand.Z1], xmm2
        movupd  xmm2, [r10+TEqBand.B2]
        mulpd   xmm2, xmm0
        movupd  xmm3, [r10+TEqBand.A2]
        mulpd   xmm3, xmm1
        subpd   xmm2, xmm3
        movupd  [r10+TEqBand.Z2], xmm2
        movapd  xmm0, xmm1
        add     r10, TYPE TEqBand
        dec     r11d
        jnz     @band
@store:
        cvtpd2ps xmm0, xmm0
        movlps  [r8], xmm0
        add     r8, 8
        dec     r9d
        jnz     @sample
@done:
end;
{$ELSE}
procedure EqBlockSSE2(Args: PEqArgs);
begin
  EqBlockPas(Args);
end;
{$IFEND}

procedure InitEqDSP(UseSSE: Boolean);
begin
  if UseSSE then EqBlock := EqBlockSSE2 else EqBlock := EqBlockPas;
end;

{ ---------------- TEqProcessor ---------------- }

constructor TEqProcessor.Create;
begin
  inherited Create;
  FSampleRate := 44100;
  FKeyCurve := -1;
  FGainsVersion := -2;
  FArgs.Dn[0] := 1E-20;
  FArgs.Dn[1] := 1E-20;
end;

procedure TEqProcessor.SetSampleRate(Value: Double);
begin
  FSampleRate := Value;
  FKeyCurve := -1;
  FGainsVersion := -2;
  Reset;
end;

procedure TEqProcessor.Reset;
var
  I: Integer;
begin
  for I := 0 to High(FBands) do
  begin
    FillChar(FBands[I].Z1, SizeOf(FBands[I].Z1), 0);
    FillChar(FBands[I].Z2, SizeOf(FBands[I].Z2), 0);
  end;
end;

procedure TEqProcessor.Design(const Curve: TEqCurve; BassDb, TrebleDb: Single; const Bands: array of Single);
var
  I, K: Integer;
  C: TCoef;
  G: Double;
  Gs: TBandGains;

  procedure Put(const Cf: TCoef);
  var
    L: Integer;
    OldZ1, OldZ2: array[0..1] of Double;
  begin
    // Zustand beibehalten, wenn das Band an derselben Stelle bleibt -> kein Knacken beim Ziehen
    Move(FBands[FCount].Z1, OldZ1, SizeOf(OldZ1));
    Move(FBands[FCount].Z2, OldZ2, SizeOf(OldZ2));
    for L := 0 to 1 do
    begin
      FBands[FCount].B0[L] := Cf.B0; FBands[FCount].B1[L] := Cf.B1; FBands[FCount].B2[L] := Cf.B2;
      FBands[FCount].A1[L] := Cf.A1; FBands[FCount].A2[L] := Cf.A2;
    end;
    Move(OldZ1, FBands[FCount].Z1, SizeOf(OldZ1));
    Move(OldZ2, FBands[FCount].Z2, SizeOf(OldZ2));
    Inc(FCount);
  end;

begin
  // Bandpegel nur neu entwerfen, wenn sich die Kurve geaendert hat (Baesse/Hoehen/Baender A/B nicht)
  if FGainsVersion <> FKeyCurveNew then
  begin
    FGains := DesignGains(Curve, FSampleRate);
    FGainsVersion := FKeyCurveNew;
  end;
  for I := 0 to EQ_BANDS - 1 do
    Gs[I] := FGains[I];
  K := FCount;
  FCount := 0;
  if Abs(BassDb) > 0.05 then
    Put(Shelf(SHELF_BASS_F, BassDb, FSampleRate, False));
  for I := 0 to EQ_BANDS - 1 do
  begin
    G := Gs[I];
    if (Abs(G) > 0.05) and (EqBandFreq(I) < FSampleRate * 0.45) then
    begin
      C := Peaking(EqBandFreq(I), BAND_Q, G, FSampleRate);
      Put(C);
    end;
  end;
  if Abs(TrebleDb) > 0.05 then
    Put(Shelf(SHELF_TREBLE_F, TrebleDb, FSampleRate, True));
  for I := 0 to 1 do
    if Abs(Bands[I * 2 + 1]) > 0.05 then
      Put(Peaking(Bands[I * 2], 1.4, Bands[I * 2 + 1], FSampleRate));   // breites Glockenband
  // frei gewordene Baender: Zustand loeschen (beim naechsten Einschalten sauber)
  for I := FCount to K - 1 do
  begin
    FillChar(FBands[I].Z1, SizeOf(FBands[I].Z1), 0);
    FillChar(FBands[I].Z2, SizeOf(FBands[I].Z2), 0);
  end;
end;

procedure TEqProcessor.Process(IO: PSingle; N: Integer; const Curve: TEqCurve; CurveVersion: Integer;
  BassDb, TrebleDb: Single; const Bands: array of Single);
var
  I: Integer;
  Chg: Boolean;
begin
  Chg := False;
  for I := 0 to 3 do
    if Abs(Bands[I] - FKeyBands[I]) > IfThen(Odd(I), 0.05, 0.5) then
      Chg := True;
  Inc(FSinceDesign, N);
  // Kurve wird gerade gezeichnet: hoechstens alle 30 ms neu entwerfen (Rechenzeit im Audio-Thread)
  if (CurveVersion <> FKeyCurve) and (FSinceDesign < FSampleRate * 0.03) and (FKeyCurve >= 0) and not Chg then
    CurveVersion := FKeyCurve;
  if Chg or (CurveVersion <> FKeyCurve) or (Abs(BassDb - FKeyBass) > 0.05) or (Abs(TrebleDb - FKeyTreble) > 0.05) then
  begin
    if CurveVersion <> FKeyCurve then
      FSinceDesign := 0;
    FKeyCurveNew := CurveVersion;
    for I := 0 to 3 do
      FKeyBands[I] := Bands[I];
    Design(Curve, BassDb, TrebleDb, Bands);
    FKeyCurve := CurveVersion;
    FKeyBass := BassDb;
    FKeyTreble := TrebleDb;
  end;
  if FCount = 0 then
    Exit;
  FArgs.IO := IO;
  FArgs.Count := N;
  FArgs.NBands := FCount;
  FArgs.Bands := @FBands[0];
  EqBlock(@FArgs);
end;


end.
