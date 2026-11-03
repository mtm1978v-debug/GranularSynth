{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.SampleEdit;

{ Bearbeitungsschritte fuer den Sample-Editor (Fenster "Audio bearbeiten"). Alle Funktionen arbeiten
  auf L/R eines TSampleData (Frames = gueltige Laenge) ausserhalb des Audio-Threads; LR (interleaved)
  baut erst SampleFinish fuer das fertige Ergebnis. Bereiche sind halboffen: [A, B) in Frames. }

interface

uses
  System.SysUtils, System.Math, Granular.Sample;

const
  EDIT_SNAP_SEC  = 0.005;    // Schnittpunkte bis 5 ms zum naechsten Nulldurchgang ziehen
  EDIT_JOIN_SEC  = 0.003;    // Loeschen: 3 ms Ueberblendung an der Nahtstelle
  EDIT_NORM_PEAK = 0.977;    // Normalisieren auf -0,2 dBFS
  EDIT_SILENCE   = 0.003;    // Stille entfernen: unter -50 dBFS gilt als still
  EDIT_SIL_KEEP  = 0.005;    // ... und 5 ms Rand bleiben stehen

function SampleClone(Src: TSampleData): TSampleData;
{ LR aufbauen, Dateiname loeschen (das Ergebnis ist eine neue Aufnahme) }
procedure SampleFinish(D: TSampleData);
{ naechster Nulldurchgang (Summe L+R) im Umkreis von EDIT_SNAP_SEC, sonst Pos selbst }
function SnapZero(D: TSampleData; Pos: Integer): Integer;
{ nur [A, B) behalten }
procedure SampleCrop(D: TSampleData; A, B: Integer);
{ [A, B) entfernen, Naht kurz ueberblendet }
procedure SampleDelete(D: TSampleData; A, B: Integer);
{ weich ein- bzw. ausblenden (Sinus-Kurve) ueber [A, B) - ausserhalb bleibt unveraendert }
procedure SampleFadeIn(D: TSampleData; A, B: Integer);
procedure SampleFadeOut(D: TSampleData; A, B: Integer);
{ Spitze in [A, B) auf EDIT_NORM_PEAK bringen; Ergebnis = Verstaerkung in dB (0 bei Stille) }
function SampleNormalize(D: TSampleData; A, B: Integer): Double;
procedure SampleReverse(D: TSampleData; A, B: Integer);
{ Stille am Anfang und Ende entfernen; Ergebnis = entfernte Frames }
function SampleTrimSilence(D: TSampleData): Integer;
{ Spitzenwert (Betrag, beide Kanaele) in [A, B) }
function SamplePeak(D: TSampleData; A, B: Integer): Single;

implementation

function SampleClone(Src: TSampleData): TSampleData;
begin
  Result := TSampleData.Create;
  Result.Frames := Src.Frames;
  Result.SampleRate := Src.SampleRate;
  Result.Channels := Src.Channels;
  Result.FileName := Src.FileName;
  Result.L := Copy(Src.L, 0, Src.Frames);
  Result.R := Copy(Src.R, 0, Src.Frames);
end;

procedure SampleFinish(D: TSampleData);
begin
  SetLength(D.L, D.Frames);
  SetLength(D.R, D.Frames);
  BuildInterleaved(D);
  D.FileName := '';
end;

procedure ClampRange(D: TSampleData; var A, B: Integer);
var
  T: Integer;
begin
  if A > B then begin T := A; A := B; B := T; end;
  A := EnsureRange(A, 0, D.Frames);
  B := EnsureRange(B, 0, D.Frames);
end;

function SnapZero(D: TSampleData; Pos: Integer): Integer;
var
  Win, K, P: Integer;

  function Cross(I: Integer): Boolean;
  begin
    Result := (I > 0) and (I < D.Frames) and
      ((D.L[I - 1] + D.R[I - 1] <= 0) <> (D.L[I] + D.R[I] <= 0));
  end;

begin
  Result := EnsureRange(Pos, 0, D.Frames);
  if (Result = 0) or (Result = D.Frames) then
    Exit;
  Win := Round(EDIT_SNAP_SEC * D.SampleRate);
  for K := 0 to Win do
  begin
    P := Result + K;
    if Cross(P) then Exit(P);
    P := Result - K;
    if Cross(P) then Exit(P);
  end;
end;

procedure SampleCrop(D: TSampleData; A, B: Integer);
begin
  ClampRange(D, A, B);
  if B - A < 1 then
    Exit;
  D.L := Copy(D.L, A, B - A);
  D.R := Copy(D.R, A, B - A);
  D.Frames := B - A;
end;

procedure SampleDelete(D: TSampleData; A, B: Integer);
var
  N, J, I, Rest: Integer;
  W: Single;
  NL, NR: TArray<Single>;
begin
  ClampRange(D, A, B);
  if (B - A < 1) or (B - A >= D.Frames) then
    Exit;
  Rest := D.Frames - B;
  // Ueberblendung: Ende des linken Teils laeuft in den Anfang des rechten Teils
  N := Min(Round(EDIT_JOIN_SEC * D.SampleRate), Min(A, Rest));
  SetLength(NL, A + Rest - N);
  SetLength(NR, A + Rest - N);
  for I := 0 to A - N - 1 do
  begin
    NL[I] := D.L[I];
    NR[I] := D.R[I];
  end;
  for J := 0 to N - 1 do
  begin
    W := (J + 0.5) / N;
    NL[A - N + J] := D.L[A - N + J] * (1 - W) + D.L[B + J] * W;
    NR[A - N + J] := D.R[A - N + J] * (1 - W) + D.R[B + J] * W;
  end;
  for I := N to Rest - 1 do
  begin
    NL[A - N + I] := D.L[B + I];
    NR[A - N + I] := D.R[B + I];
  end;
  D.L := NL;
  D.R := NR;
  D.Frames := Length(NL);
end;

procedure Fade(D: TSampleData; A, B: Integer; FadeIn: Boolean);
var
  I, N: Integer;
  G: Single;
begin
  ClampRange(D, A, B);
  N := B - A;
  if N < 2 then
    Exit;
  for I := 0 to N - 1 do
  begin
    G := Sin(0.5 * Pi * I / (N - 1));        // 0 .. 1, weich
    G := G * G;
    if not FadeIn then
      G := 1 - G;
    D.L[A + I] := D.L[A + I] * G;
    D.R[A + I] := D.R[A + I] * G;
  end;
end;

procedure SampleFadeIn(D: TSampleData; A, B: Integer);
begin
  Fade(D, A, B, True);
end;

procedure SampleFadeOut(D: TSampleData; A, B: Integer);
begin
  Fade(D, A, B, False);
end;

function SamplePeak(D: TSampleData; A, B: Integer): Single;
var
  I: Integer;
begin
  ClampRange(D, A, B);
  Result := 0;
  for I := A to B - 1 do
    Result := Max(Result, Max(Abs(D.L[I]), Abs(D.R[I])));
end;

function SampleNormalize(D: TSampleData; A, B: Integer): Double;
var
  I: Integer;
  P, G: Single;
begin
  ClampRange(D, A, B);
  P := SamplePeak(D, A, B);
  if P < 1E-6 then
    Exit(0);
  G := EDIT_NORM_PEAK / P;
  for I := A to B - 1 do
  begin
    D.L[I] := D.L[I] * G;
    D.R[I] := D.R[I] * G;
  end;
  Result := 20 * Log10(G);
end;

procedure SampleReverse(D: TSampleData; A, B: Integer);
var
  I, J: Integer;
  T: Single;
begin
  ClampRange(D, A, B);
  I := A;
  J := B - 1;
  while I < J do
  begin
    T := D.L[I]; D.L[I] := D.L[J]; D.L[J] := T;
    T := D.R[I]; D.R[I] := D.R[J]; D.R[J] := T;
    Inc(I);
    Dec(J);
  end;
end;

function SampleTrimSilence(D: TSampleData): Integer;
var
  A, B, Keep, Old: Integer;

  function Loud(I: Integer): Boolean;
  begin
    Result := (Abs(D.L[I]) > EDIT_SILENCE) or (Abs(D.R[I]) > EDIT_SILENCE);
  end;

begin
  Result := 0;
  if D.Frames < 2 then
    Exit;
  A := 0;
  while (A < D.Frames) and not Loud(A) do
    Inc(A);
  if A >= D.Frames then
    Exit;                      // alles still: nichts anfassen
  B := D.Frames - 1;
  while (B > A) and not Loud(B) do
    Dec(B);
  Keep := Round(EDIT_SIL_KEEP * D.SampleRate);
  A := Max(0, A - Keep);
  B := Min(D.Frames, B + 1 + Keep);
  Old := D.Frames;
  SampleCrop(D, A, B);
  Result := Old - D.Frames;
end;

end.
