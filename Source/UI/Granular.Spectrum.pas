{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Spectrum;

{ Spektrum-Anzeige (Fourier-Transformation) des Plugin-Ausgangs:
    - FFT ueber die letzten 2048 Samples, Hann-Fenster
    - logarithmische Frequenzachse 20 Hz .. 20 kHz, Pegel in dB (-90 .. 0)
    - Nachlauf: Kurve steigt sofort, faellt langsam; Spitzenpunkte halten kurz und sinken
    - Glow: Flaeche mit Farbverlauf, leuchtende Kontur
  Schnell: Twiddle-Faktoren und Bitumkehr einmal vorberechnet, Raster gecacht,
  Zeichnen in BeginUpdate/EndUpdate. }

interface

uses
  Granular.Lang,
  System.Classes, System.SysUtils, System.Math, System.Types, Vcl.Graphics,
  GR32, GR32_Image,
  Granular.Engine, Granular.GfxAsm;

const
  FFT_BITS = 12;
  FFT_SIZE = 1 shl FFT_BITS;     // 4096 (feineres Raster im Bass)
  FFT_HALF = FFT_SIZE div 2;

type
  TSpectrumView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FIn, FDummy: array of Single;
    FRe, FIm: array[0..FFT_SIZE - 1] of Single;
    FWin: array[0..FFT_SIZE - 1] of Single;
    FTwR, FTwI: array[0..FFT_SIZE - 1] of Single;   // Twiddles je Stufe zusammenhaengend: Stufe mit Half h ab Index h
    FRev: array[0..FFT_SIZE - 1] of Integer;
    FPow: array[0..FFT_HALF - 1] of Single;          // Leistung je Bin (Re^2 + Im^2)
    FCol: TArray<Single>;           // geglaettete Pegel je Pixelspalte (0..1)
    FPeak: array of Single;          // Spitzenhalten je Spalte
    FPeakHold: array of Integer;     // Frames, die die Spitze noch gehalten wird
    FGrid: TBitmap32;                // Hintergrund mit Raster und Beschriftung
    FFill: array[0..63] of TColor32; // (frueher Flaechenfarben)
    FGrad: array of TColor32;
    FSm: array of Single;            // geglaettete Anzeige-Werte (nur Darstellung)        // Flaeche: Farbe je Hoehe (oben hell, unten dunkel), Bernstein
    FIdleFrames: Integer;
    FBinLo, FBinHi: array of Integer;   // Bin-Bereich je Pixelspalte (einmal je Breite berechnet)
    FBinSr: Double;
    FBinPos: array of Single;        // Frequenz der Spaltenmitte als Bin-Position (Interpolation)
    FPreEq: Boolean;
    FSource: Integer;                // 0 = Ausgang/PreEq, 1 = vor den Filtern, 2 = nach den Filtern
    FAnyVisible: Boolean;            // noch etwas ueber der Grundlinie (Kurve oder Spitze)
    procedure Prepare;
    procedure FFT;
    procedure BuildGrid(W, H: Integer);
    function FreqToX(F: Double; W: Integer): Integer;
  protected
    procedure DoPaintBuffer; override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
    destructor Destroy; override;
    { Daten holen, transformieren, neu zeichnen; False bei Stille (dann wird nicht gezeichnet) }
    function Tick: Boolean;
    { nur analysieren (ohne Zeichnen) fuer W Spalten 20 Hz .. 20 kHz; Ergebnis in Levels (0..1,
      mit Nachlauf). Fuer andere Ansichten (Filteransicht), wenn das Spektrum selbst verdeckt ist. }
    function Analyze(W: Integer): Boolean;
    property Levels: TArray<Single> read FCol;
    { True: analysiert die Summe vor dem Equalizer statt des Ausgangs }
    property PreEq: Boolean read FPreEq write FPreEq;
    { 1 = Summe vor den Filtern je Note, 2 = danach (Reiter Filter); 0 = wie bisher }
    property Source: Integer read FSource write FSource;
  end;

implementation

const
  F_MIN = 20.0;
  F_MAX = 20000.0;
  DB_MIN = -90.0;
  COL_BG = $FF16181C;

constructor TSpectrumView.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  BufferOversize := 0;
  FEngine := AEngine;
  SetLength(FIn, FFT_SIZE);
  SetLength(FDummy, FFT_SIZE);
  Prepare;
end;

destructor TSpectrumView.Destroy;
begin
  FGrid.Free;
  inherited;
end;

procedure TSpectrumView.Prepare;
var
  I, J, K: Integer;
begin
  for I := 0 to FFT_SIZE - 1 do
  begin
    FWin[I] := 0.5 - 0.5 * Cos(2 * Pi * I / (FFT_SIZE - 1));   // Hann
    J := 0;
    for K := 0 to FFT_BITS - 1 do
      if (I and (1 shl K)) <> 0 then
        J := J or (1 shl (FFT_BITS - 1 - K));
    FRev[I] := J;
  end;
  for I := 0 to 63 do
    FFill[I] := Color32(Round(16 + 30 * I / 63), Round(40 + 120 * I / 63), Round(80 + 120 * I / 63));
  K := 1;
  while K < FFT_SIZE do
  begin
    for I := 0 to K - 1 do
    begin
      FTwR[K + I] := Cos(Pi * I / K);
      FTwI[K + I] := -Sin(Pi * I / K);
    end;
    K := K shl 1;
  end;
end;

{ iterative Radix-2-FFT (in-place). Die Stufen 1 und 2 in Pascal, ab Half = 4 der SIMD-Kern
  FftButterfly (Granular.GfxAsm: SSE Win32/Win64, Pascal-Referenz FftButterflyPas). }
procedure TSpectrumView.FFT;
var
  Len, Half, I, J, K: Integer;
  XR, XI: Single;
begin
  Len := 2;
  while Len <= FFT_SIZE do
  begin
    Half := Len shr 1;
    I := 0;
    while I < FFT_SIZE do
    begin
      if Half >= 4 then
        FftButterfly(@FRe[I], @FIm[I], Half * SizeOf(Single), @FTwR[Half], @FTwI[Half], Half)
      else
        for J := I to I + Half - 1 do
        begin
          K := J + Half;
          XR := FRe[K] * FTwR[Half + J - I] - FIm[K] * FTwI[Half + J - I];
          XI := FRe[K] * FTwI[Half + J - I] + FIm[K] * FTwR[Half + J - I];
          FRe[K] := FRe[J] - XR;
          FIm[K] := FIm[J] - XI;
          FRe[J] := FRe[J] + XR;
          FIm[J] := FIm[J] + XI;
        end;
      Inc(I, Len);
    end;
    Len := Len shl 1;
  end;
end;

function TSpectrumView.FreqToX(F: Double; W: Integer): Integer;
begin
  Result := Round(Ln(F / F_MIN) / Ln(F_MAX / F_MIN) * (W - 1));
end;

{ Displayglas: dezenter senkrechter Verlauf (oben etwas heller als Base), einmal je Rasterbild }
procedure GlassBg(B: TBitmap32; Base: TColor32; Lift: Integer);
var
  Y, R, G, Bl, K: Integer;
begin
  for Y := 0 to B.Height - 1 do
  begin
    K := Round(Lift * Sqr(1 - Y / Max(1, B.Height - 1)));
    R := Min(255, ((Base shr 16) and $FF) + K);
    G := Min(255, ((Base shr 8) and $FF) + K);
    Bl := Min(255, (Base and $FF) + K + K div 2);
    B.HorzLineS(0, Y, B.Width - 1, $FF000000 or TColor32(R shl 16) or TColor32(G shl 8) or TColor32(Bl));
  end;
end;

procedure TSpectrumView.BuildGrid(W, H: Integer);
const
  LINES: array[0..8] of Double = (50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000);
  LABELS: array[0..8] of string = ('50', '100', '200', '500', '1k', '2k', '5k', '10k', '20k');
var
  I, X, Y, D, Tx, LastX: Integer;
  T: Single;
begin
  // Flaechen-Verlauf: oben warmes Bernstein, nach unten in dunkles Braun auslaufend
  SetLength(FGrad, H);
  for Y := 0 to H - 1 do
  begin
    T := Y / Max(1, H - 14);
    T := Min(T, 1);
    FGrad[Y] := Color32(Round(214 - 160 * T), Round(150 - 120 * T), Round(62 - 48 * T), Round(235 - 90 * T));
  end;
  if FGrid = nil then
  begin
    FGrid := TBitmap32.Create;
    FGrid.DrawMode := dmOpaque;
  end;
  FGrid.SetSize(W, H);
  FGrid.BeginUpdate;
  try
    GlassBg(FGrid, COL_BG, 12);
    // Pegelraster alle 18 dB
    D := 0;
    while D >= Round(DB_MIN) do
    begin
      Y := Round((D / DB_MIN) * (H - 14));
      FGrid.HorzLineS(0, Y, W - 1, $FF262A31);
      Dec(D, 18);
    end;
    FGrid.Font.Name := 'Tahoma';
    FGrid.Font.Size := UiPt(7);
    FGrid.Font.Color := $808080;
    LastX := -1000;
    for I := 0 to High(LINES) do
    begin
      X := FreqToX(LINES[I], W);
      FGrid.VertLineS(X, 0, H - 14, $FF262A31);
      // Beschriftung nur, wenn sie nicht in die vorige laeuft (schmale Anzeige, z.B. im Mischpult)
      Tx := Min(X + 2, W - 22);
      if Tx >= LastX + 4 then
      begin
        FGrid.Textout(Tx, H - 13, LABELS[I]);
        LastX := Tx + FGrid.TextWidth(LABELS[I]);
      end;
    end;
    FGrid.Textout(4, 2, Tr('Spektrum (Ausgang)'));
  finally
    FGrid.EndUpdate;
  end;
end;

function TSpectrumView.Tick: Boolean;
begin
  Result := Analyze(Width);
  if Result then
    ForceFullInvalidate;
end;

function TSpectrumView.Analyze(W: Integer): Boolean;
var
  I, X, B0, B1, B: Integer;
  M, Mx, F0, F1, Sr, V: Double;
begin
  Result := False;
  if W < 20 then
    Exit;
  // Stille: nach dem Ausklingen der Anzeige nicht mehr zeichnen
  if FEngine.OutputPeak < 0.0001 then
  begin
    Inc(FIdleFrames);
    // erst aufhoeren, wenn Kurve UND Spitzenpunkte ganz unten angekommen sind
    if (FIdleFrames > 60) and not FAnyVisible then
      Exit;
  end
  else
    FIdleFrames := 0;

  if FSource > 0 then
    FEngine.GetScopeFilter(FSource - 1, FIn, FFT_SIZE)
  else if FPreEq then
    FEngine.GetScopePreEq(FIn, FFT_SIZE)
  else
    FEngine.GetScope(FIn, FDummy, FFT_SIZE);
  for I := 0 to FFT_SIZE - 1 do
  begin
    FRe[FRev[I]] := FIn[I] * FWin[I];
    FIm[FRev[I]] := 0;
  end;
  FFT;
  // Leistung je Bin (SIMD); Logarithmus erst je Pixelspalte
  PowerSpec(@FRe[0], @FIm[0], @FPow[0], FFT_HALF);

  Sr := FEngine.SampleRate;
  if (Length(FCol) <> W) or (Sr <> FBinSr) then
  begin
    SetLength(FCol, W);
    SetLength(FPeak, W);
    SetLength(FPeakHold, W);
    // Frequenzbereich je Pixelspalte (logarithmisch) nur bei Groessen-/Ratenwechsel berechnen
    SetLength(FBinLo, W);
    SetLength(FBinHi, W);
    SetLength(FBinPos, W);
    for X := 0 to W - 1 do
    begin
      F0 := F_MIN * Power(F_MAX / F_MIN, X / W);
      F1 := F_MIN * Power(F_MAX / F_MIN, (X + 1) / W);
      FBinLo[X] := EnsureRange(Trunc(F0 * FFT_SIZE / Sr), 1, FFT_HALF - 1);
      FBinHi[X] := EnsureRange(Trunc(F1 * FFT_SIZE / Sr), FBinLo[X], FFT_HALF - 1);
      FBinPos[X] := EnsureRange(Sqrt(F0 * F1) * FFT_SIZE / Sr, 1, FFT_HALF - 2);
    end;
    FBinSr := Sr;
  end;
  FAnyVisible := False;
  for X := 0 to W - 1 do
  begin
    B0 := FBinLo[X];
    B1 := FBinHi[X];
    if B1 - B0 <= 1 then
    begin
      // schmale Spalte (Bass): zwischen den beiden Nachbar-Bins weich interpolieren statt Treppen
      B := Trunc(FBinPos[X]);
      F0 := FBinPos[X] - B;
      M := FPow[B] + (FPow[B + 1] - FPow[B]) * F0;
    end
    else
    begin
      M := 0;
      for B := B0 to B1 do
        if FPow[B] > M then
          M := FPow[B];
    end;
    // Amplitude (Hann-Fenster: Faktor 4/N) in dB: 10*log10(P * (4/N)^2)
    M := M * Sqr(4 / FFT_SIZE);
    if M > 1E-18 then
      Mx := 10 * Log10(M)
    else
      Mx := -180;
    V := EnsureRange((Mx - DB_MIN) / -DB_MIN, 0, 1);
    // Nachlauf: sofort hoch, langsam runter
    if V > FCol[X] then
      FCol[X] := V
    else
      FCol[X] := FCol[X] - (FCol[X] - V) * 0.12;
    // Spitze halten und dann sinken lassen
    if V >= FPeak[X] then
    begin
      FPeak[X] := V;
      FPeakHold[X] := 20;
    end
    else if FPeakHold[X] > 0 then
      Dec(FPeakHold[X])
    else
      FPeak[X] := Max(0, FPeak[X] - 0.01);
    if FCol[X] < 0.004 then
      FCol[X] := 0;
    if (FPeak[X] > 0) or (FCol[X] > 0) then
      FAnyVisible := True;
  end;
  Result := True;
end;

procedure TSpectrumView.DoPaintBuffer;
var
  Bm: TBitmap32;
  W, H, X, Y, YP, Base, YPrev, A: Integer;
  YY: Integer;
  PkS: Single;
  YF, YPrevF: Single;
begin
  Buffer.BeginUpdate;
  try
    Bm := Buffer;
    W := Bm.Width;
    H := Bm.Height;
    if (W < 20) or (H < 20) then
    begin
      Bm.Clear(COL_BG);
      inherited;
      Exit;
    end;
    if (FGrid = nil) or (FGrid.Width <> W) or (FGrid.Height <> H) then
      BuildGrid(W, H);
    FGrid.DrawTo(Bm, 0, 0);
    Base := H - 14;
    if Length(FCol) = W then
    begin
      // seitlich glaetten (1-2-3-2-1), nur fuer die Darstellung: ruhigere Kurve ohne Zacken
      if Length(FSm) <> W then
        SetLength(FSm, W);
      for X := 0 to W - 1 do
        FSm[X] := (FCol[Max(X - 2, 0)] + 2 * FCol[Max(X - 1, 0)] + 3 * FCol[X] + 2 * FCol[Min(X + 1, W - 1)] +
          FCol[Min(X + 2, W - 1)]) / 9;
      YPrev := Base;
      YPrevF := Base;
      for X := 0 to W - 1 do
      begin
        YF := Base - FSm[X] * Base;
        Y := Round(YF);
        // Flaeche: Verlauf nach Hoehe (oben hell, unten dunkel), Oberkante anteilig
        if (Y < Base) and (Length(FGrad) = H) then
        begin
          for YY := Max(Ceil(YF), 0) to Base - 1 do
            Bm.SetPixelTS(X, YY, FGrad[YY]);
          if (Ceil(YF) > YF) and (Ceil(YF) - 1 >= 0) then
            Bm.SetPixelTS(X, Ceil(YF) - 1, (FGrad[Ceil(YF) - 1] and $00FFFFFF) or
              (TColor32(Round(((FGrad[Ceil(YF) - 1] shr 24) and $FF) * (Ceil(YF) - YF))) shl 24));
        end;
        // Kontur: weicher Lichthof + kantengeglaettete Linie
        A := Round(60 + 90 * FSm[X]);
        if X > 0 then
        begin
          Bm.VertLineTS(X, Min(Y, YPrev) - 1, Max(Y, YPrev) + 1, Color32(255, 176, 72, A div 7));   // Lichthof nur angedeutet
          Bm.LineXS(Fixed(X - 1), Fixed(YPrevF), Fixed(X), Fixed(YF), Color32(255, 214, 140, 190));   // feine Kontur
        end;
        YPrev := Y;
        YPrevF := YF;
        // Spitzenpunkt
        // Spitzenwert genauso geglaettet wie die Kurve; nur zeigen, wenn er ueber der Kurve liegt
        PkS := (FPeak[Max(X - 2, 0)] + 2 * FPeak[Max(X - 1, 0)] + 3 * FPeak[X] + 2 * FPeak[Min(X + 1, W - 1)] +
          FPeak[Min(X + 2, W - 1)]) / 9;
        YP := Base - Round(PkS * Base);
        if (PkS > 0.02) and (PkS > FSm[X] + 1.5 / Base) and (YP < Base) then
          Bm.SetPixelTS(X, YP, Color32(255, 236, 200, 200));   // Spitze: heller Punkt
      end;
    end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

end.
