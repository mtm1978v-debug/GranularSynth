{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Pitch;

{ Tonhoehenerkennung fuer den Sidechain (Auto-Pitch), YIN-Verfahren
  (de Cheveigne/Kawahara 2002), sparsam fuer langsame Rechner:
    - Eingang wird auf 1/4 der Abtastrate heruntergemittelt (44,1 kHz -> 11 kHz)
    - Analyse alle HOP Samples (ca. 23 ms) ueber ein Fenster von WIN Samples
    - Bereich ca. 50 Hz .. 1000 Hz (Stimme, die meisten Instrumente)
  Ergebnis: MIDI-Notennummer (gebrochen) + Gueltig-Flag. Bei Stille/Rauschen bleibt
  die letzte gueltige Note stehen (Valid = False). }

interface

type
  TPitchTracker = class
  private const
    DECIM = 4;
    WIN = 300;          // Analysefenster (dezimierte Samples)
    TAU_MAX = 230;      // laengste Periode -> ca. 48 Hz bei 11 kHz
    BUF = 1024;         // Ringpuffer (Zweierpotenz >= WIN + TAU_MAX)
    HOP = 256;
    THRESHOLD = 0.15;   // YIN-Schwelle
  private
    FRing: array[0..BUF - 1] of Single;
    FWork: array[0..WIN + TAU_MAX - 1] of Single;
    FDiff: array[0..TAU_MAX] of Single;
    FPos, FSinceHop, FDecCount: Integer;
    FDecAcc: Single;
    FRate: Double;      // dezimierte Abtastrate
    FNote: Double;
    FValid: Boolean;
    FHz: Double;
    procedure Analyse;
  public
    constructor Create;
    procedure SetSampleRate(Value: Double);
    procedure Process(InL, InR: PSingle; N: Integer);
    property Note: Double read FNote;      // MIDI, z.B. 57.0 = A3
    property Hz: Double read FHz;
    property Valid: Boolean read FValid;
  end;

implementation

uses
  System.Math;

{$POINTERMATH ON}

constructor TPitchTracker.Create;
begin
  inherited;
  FNote := 60;
  SetSampleRate(44100);
end;

procedure TPitchTracker.SetSampleRate(Value: Double);
begin
  FRate := Value / DECIM;
end;

procedure TPitchTracker.Process(InL, InR: PSingle; N: Integer);
var
  I: Integer;
begin
  if InL = nil then
  begin
    FValid := False;
    Exit;
  end;
  for I := 0 to N - 1 do
  begin
    // Mono + Mittelwert ueber DECIM Samples (einfacher Anti-Aliasing-Tiefpass)
    FDecAcc := FDecAcc + (InL[I] + InR[I]);
    Inc(FDecCount);
    if FDecCount = DECIM then
    begin
      FRing[FPos] := FDecAcc * (0.5 / DECIM);
      FPos := (FPos + 1) and (BUF - 1);
      FDecAcc := 0;
      FDecCount := 0;
      Inc(FSinceHop);
      if FSinceHop >= HOP then
      begin
        FSinceHop := 0;
        Analyse;
      end;
    end;
  end;
end;

procedure TPitchTracker.Analyse;
var
  I, Tau, Best, Start, TauMin: Integer;
  D, Sum, Energy, Cm, Prev, S0, S1, S2, Shift, Period: Double;
begin
  // letzte WIN + TAU_MAX Samples linear kopieren
  Start := (FPos - (WIN + TAU_MAX)) and (BUF - 1);
  Energy := 0;
  for I := 0 to WIN + TAU_MAX - 1 do
  begin
    FWork[I] := FRing[(Start + I) and (BUF - 1)];
    if I < WIN then
      Energy := Energy + Sqr(FWork[I]);
  end;
  // zu leise (< ca. -50 dB RMS) -> keine Tonhoehe
  if Energy / WIN < 1E-5 then
  begin
    FValid := False;
    Exit;
  end;

  // Differenzfunktion d(tau)
  FDiff[0] := 0;
  for Tau := 1 to TAU_MAX do
  begin
    D := 0;
    for I := 0 to WIN - 1 do
      D := D + Sqr(FWork[I] - FWork[I + Tau]);
    FDiff[Tau] := D;
  end;

  // kumulativ normierte Differenz, erste Unterschreitung der Schwelle suchen
  TauMin := Max(2, Floor(FRate / 1000));   // nicht hoeher als ca. 1 kHz
  Sum := 0;
  Best := -1;
  Prev := 1;
  for Tau := 1 to TAU_MAX do
  begin
    Sum := Sum + FDiff[Tau];
    if Sum > 0 then Cm := FDiff[Tau] * Tau / Sum else Cm := 1;
    FDiff[Tau - 1] := Prev;   // Platz sparen: FDiff[t-1] haelt jetzt cmnd(t-1)
    Prev := Cm;
    if (Tau >= TauMin) and (Best < 0) and (Cm < THRESHOLD) then
      Best := Tau;
    // nach der Unterschreitung bis zum lokalen Minimum weiterlaufen
    if (Best > 0) and (Tau = Best + 1) then
      if Cm < FDiff[Best] then
        Best := Tau
      else
        Break;
  end;
  if (Best < 0) or (Best >= TAU_MAX - 1) then
  begin
    FValid := False;
    Exit;
  end;
  FDiff[Best + 1] := Prev;

  // parabolische Interpolation um das Minimum
  S0 := FDiff[Best - 1];
  S1 := FDiff[Best];
  S2 := FDiff[Best + 1];
  Shift := 0;
  if Abs(S0 - 2 * S1 + S2) > 1E-12 then
    Shift := EnsureRange(0.5 * (S0 - S2) / (S0 - 2 * S1 + S2), -1, 1);
  Period := Best + Shift;
  if Period <= 0 then
  begin
    FValid := False;
    Exit;
  end;
  FHz := FRate / Period;
  FNote := 69 + 12 * Log2(FHz / 440);
  FValid := True;
end;

end.
