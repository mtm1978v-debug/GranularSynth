{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.LoadView;

{ Reiter "Leistung":
  - TLoadList: welche Rechenbloecke in Klang A und B aktiv sind, mit ihrem Anteil an der theoretischen
    Volllast (alles an, A und B, volle Polyphonie = 100 %). Gewichte aus den Pruefstand-Messungen.
  - TLoadGauge: Drehzahlmesser fuer die gemessene Rechenzeit des Plugins (Anteil an der Echtzeit) mit
    Marke fuer den laengsten Aufruf (Anteil an der Pufferdauer).
  Beide zeichnen gepuffert und nur auf Anforderung (Reiter sichtbar). }

interface

uses
  Granular.Lang,
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, Vcl.Controls, Vcl.Graphics,
  GR32, GR32_Polygons, GR32_VectorUtils,
  Granular.Params, Granular.Engine;

type
  TLoadItem = record
    Name: string;
    Weight: Double;        // Anteil an einem voll belegten Klang (Summe aller Bloecke = 100)
    OnA, OnB: Boolean;
  end;

  TLoadList = class(TGraphicControl)
  private
    FEngine: TGranularEngine;
    FItems: array of TLoadItem;
    FLayerB: Boolean;
    FBuf: TBitmap;
    FSig: string;           // Zustand der letzten Zeichnung (nur bei Aenderung neu zeichnen)
    FDrawnSig: string;      // Stand im Zwischenbild (Text/Balken nur bei Aenderung neu rechnen)
    FDrawnW, FDrawnH: Integer;
    FDim: Integer;          // Abdunkelung 0..255 (Netzteil sackt bei lautem Ausgang ab)
    procedure Build;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
    destructor Destroy; override;
    procedure Tick;          // Zustand aus der Engine lesen, bei Aenderung neu zeichnen
    procedure SetSag(Br: Single);   // Helligkeit 0,5..1 wie die Bereichs-Lampen; zeichnet nur bei Stufenwechsel
    function TheoryPercent: Double;
    property Font;
  end;

  TLoadGauge = class(TGraphicControl)
  private
    FValue, FShown, FPeak: Double;   // Rechenzeit % (Ziel / angezeigt, gedaempft), laengster Aufruf %
    FTheory: Double;                  // theoretische Last % (Marke am Rand)
    FBuf: TBitmap32;                  // Graphics32: kantengeglaettete Boegen, Striche, Nadel
    FFace: TBitmap32;                 // vorgerechnetes Zifferblatt (Einfassung, Verlauf, Zonen, Skala, Glas)
    FDim: Integer;                    // Abdunkelung 0..255 (wie TLoadList)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetValues(Load, Peak, Theory: Double);
    procedure Tick;          // Nadel weich nachfuehren
    procedure SetSag(Br: Single);
    property Font;
  end;

implementation

const
  BG = $00302C2A;
  COL_TEXT = $00DCDCDC;
  COL_DIM = $00808080;
  COL_AMBER = $0040A8E0;
  COL_A = $0060C080;       // gruen (Klang A)
  COL_B = $00D0A060;       // blaeulich (Klang B)
  // Rechenblock-Liste als Hardware-Display: warmes Schwarz, bernsteinfarbene Segmente
  LCD_BG = $00100C0A;   LCD_LINE = $000B0907;   LCD_TXT = $0064B4E6;   LCD_DIM = $00305A78;
  LCD_SEG_A = $0040A8F0; LCD_SEG_B = $003C88C8; LCD_SEG_OFF = $00141E28;

{ ---------------- TLoadList ---------------- }

constructor TLoadList.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  FEngine := AEngine;
  FBuf := TBitmap.Create;
  ControlStyle := ControlStyle + [csOpaque];
end;

destructor TLoadList.Destroy;
begin
  FBuf.Free;
  inherited;
end;

{ Bloecke und Gewichte (je Klang 100): Messung "Volllast" im Pruefstand, gerundet }
procedure TLoadList.Build;

  function ValA(Id: TGranularParamId): Single;
  begin
    Result := FEngine.GetParam(Ord(Id));
  end;

  function ValB(Id: TGranularParamId): Single;
  begin
    Result := FEngine.MorphBValue(Id);
  end;

  function OnOf(Id: TGranularParamId; B: Boolean): Boolean;
  var
    V: Single;
  begin
    if B then V := ValB(Id) else V := ValA(Id);
    Result := ParamStep(Ord(Id), V) >= 1;
  end;

  procedure Add(const AName: string; W: Double; A, B: Boolean);
  var
    N: Integer;
  begin
    N := Length(FItems);
    SetLength(FItems, N + 1);
    FItems[N].Name := AName;
    FItems[N].Weight := W;
    FItems[N].OnA := A;
    FItems[N].OnB := B and FLayerB;
  end;

  function OscOn(K: Integer; B: Boolean): Boolean;
  var
    VOn, VLvl: Single;
  begin
    if B then
    begin
      VOn := ValB(OSC_P[K].On_); VLvl := ValB(OSC_P[K].Level);
    end
    else
    begin
      VOn := ValA(OSC_P[K].On_); VLvl := ValA(OSC_P[K].Level);
    end;
    Result := (ParamStep(Ord(OSC_P[K].On_), VOn) = 1) and (ParamToPlain(Ord(OSC_P[K].Level), VLvl) > 0.5);
  end;

  function FilterOn(B: Boolean): Boolean;
  var
    K: Integer;
  begin
    Result := OnOf(gpFltOn, B) or OnOf(gpFlt2On, B);
    for K := 0 to OSC_COUNT - 1 do
      Result := Result or (OscOn(K, B) and OnOf(OSC_P[K].FltOn, B));
  end;

  function MatrixOn: Boolean;
  var
    S: Integer;
  begin
    Result := False;
    for S := 0 to MOD_SLOTS - 1 do
      if (ParamStep(SlotSourceIndex(S), FEngine.GetParam(SlotSourceIndex(S))) > 0) and
         (ParamStep(SlotDestIndex(S), FEngine.GetParam(SlotDestIndex(S))) > 0) then
        Exit(True);
  end;

  function DriveOn(B: Boolean): Boolean;
  var
    V: Single;
  begin
    if B then V := ValB(gpDrive) else V := ValA(gpDrive);
    Result := ParamToPlain(Ord(gpDrive), V) > 0.5;
  end;

  function FxOn(B: Boolean): Boolean;
  begin
    Result := OnOf(gpChoOn, B) or OnOf(gpPhaOn, B) or OnOf(gpCrushOn, B) or OnOf(gpTgOn, B);
  end;

begin
  FItems := nil;
  FLayerB := FEngine.LayerMode;
  Add(Tr('Grundlast (Stimmen, Hüllkurven, LFOs)'), 14, True, True);
  Add(Tr('Grains'), 30, OnOf(gpGrainOn, False), OnOf(gpGrainOn, True));
  Add(Tr('HQ-Interpolation'), 8, OnOf(gpGrainOn, False) and OnOf(gpQuality, False),
    OnOf(gpGrainOn, True) and OnOf(gpQuality, True));
  Add(Tr('Oszillator 1'), 6, OscOn(0, False), OscOn(0, True));
  Add(Tr('Oszillator 2'), 6, OscOn(1, False), OscOn(1, True));
  Add(Tr('Oszillator 3'), 6, OscOn(2, False), OscOn(2, True));
  Add(Tr('Filter je Note'), 9, FilterOn(False), FilterOn(True));
  Add(Tr('Modulation je Note (Matrix)'), 7, MatrixOn, MatrixOn);
  Add(Tr('Echo'), 4, OnOf(gpEchoOn, False), OnOf(gpEchoOn, True));
  Add(Tr('Hall'), 6, OnOf(gpRevOn, False), OnOf(gpRevOn, True));
  Add(Tr('Equalizer'), 2, OnOf(gpEqOn, False), OnOf(gpEqOn, True));
  Add(Tr('Sättigung'), 1, DriveOn(False), DriveOn(True));
  Add(Tr('Arpeggiator'), 1, OnOf(gpArpOn, False), OnOf(gpArpOn, True));
  // Summen-Effekte aus dem Reiter Effekte zusammengefasst Gewicht gemessen:
  // Pruefstand 'FX-Last', alle vier an = etwa 12 (Grains = 30)
  Add(Tr('FX (Chorus, Phaser, Bitcrusher, Gate)'), 12, FxOn(False), FxOn(True));
end;

function TLoadList.TheoryPercent: Double;
var
  I: Integer;
  Total: Double;
begin
  Result := 0;
  for I := 0 to High(FItems) do
  begin
    if FItems[I].OnA then Result := Result + FItems[I].Weight;
    if FItems[I].OnB then Result := Result + FItems[I].Weight;
  end;
  // A + B voll = 100 %
  Total := 0;
  for I := 0 to High(FItems) do
    Total := Total + FItems[I].Weight;
  if Total > 0 then
    Result := Result / (2 * Total) * 100;
end;

procedure TLoadList.Tick;
var
  I: Integer;
  S: string;
begin
  Build;
  S := BoolToStr(FLayerB);
  for I := 0 to High(FItems) do
    S := S + Ord(FItems[I].OnA).ToString + Ord(FItems[I].OnB).ToString;
  S := S + IntToStr(Width) + 'x' + IntToStr(Height);
  if S <> FSig then
  begin
    FSig := S;
    Invalidate;
  end;
end;

{ Helligkeit -> Abdunkelung in 12 Stufen (wie TGroupPanel.SagLed); True = Stufe hat sich geaendert }
function SagStep(Br: Single; var Dim: Integer): Boolean;
var
  D: Integer;
begin
  D := Round(EnsureRange(Round((1 - Br) / 0.5 * 11), 0, 11) * 0.5 / 11 * 200);   // hoechstens ~ -40 %
  Result := D <> Dim;
  Dim := D;
end;

{ Schwarz mit fester Deckkraft ueber ein Rechteck legen (ein AlphaBlend-Aufruf, kein Pixelzugriff) }
procedure DimRect(DC: HDC; X, Y, W, H, Alpha: Integer);
var
  Bm: TBitmap;
  Bf: TBlendFunction;
begin
  if Alpha <= 0 then Exit;
  Bm := TBitmap.Create;
  try
    Bm.SetSize(1, 1);
    Bm.Canvas.Pixels[0, 0] := clBlack;
    Bf.BlendOp := AC_SRC_OVER; Bf.BlendFlags := 0; Bf.SourceConstantAlpha := Alpha; Bf.AlphaFormat := 0;
    Winapi.Windows.AlphaBlend(DC, X, Y, W, H, Bm.Canvas.Handle, 0, 0, 1, 1, Bf);
  finally
    Bm.Free;
  end;
end;

procedure TLoadList.SetSag(Br: Single);
begin
  if SagStep(Br, FDim) then
    Invalidate;
end;

procedure TLoadGauge.SetSag(Br: Single);
begin
  if SagStep(Br, FDim) then
    Invalidate;
end;

procedure TLoadList.Paint;
var
  C: TCanvas;
  I, Y: Integer;
  T: Double;
  ROW, X_NAME, X_A, X_B, BAR_W: Integer;   // wachsen mit der Fenstergroesse (Schrift waechst mit)

  // Balken als LED-Segmente (wie eine Pegelkette auf einem Geraete-Display)
  procedure Bar(X, Y: Integer; Frac: Double; On_: Boolean; Col: TColor);
  var
    K, N, Lit, SW: Integer;
  begin
    SW := Max(3, UiPt(4));
    N := BAR_W div SW;
    if On_ then Lit := Max(1, Round(N * Frac)) else Lit := 0;
    for K := 0 to N - 1 do
    begin
      if K < Lit then C.Brush.Color := Col else C.Brush.Color := LCD_SEG_OFF;
      C.FillRect(Rect(X + K * SW, Y + 5, X + K * SW + SW - 1, Y + 15));
    end;
    C.Brush.Style := bsClear;
    if On_ then C.Font.Color := LCD_TXT else C.Font.Color := LCD_DIM;
    if On_ then
      C.TextOut(X + BAR_W + 6, Y + 2, Format(Tr('%.0f %%'), [Frac * 30]))
    else
      C.TextOut(X + BAR_W + 6, Y + 2, Tr('aus'));
    C.Brush.Style := bsSolid;
  end;

begin
  ROW := UiPt(21); X_NAME := UiPt(8); X_A := UiPt(250); X_B := UiPt(410); BAR_W := UiPt(120);
  if (FDrawnSig = FSig) and (FDrawnW = Width) and (FDrawnH = Height) then
  begin
    Canvas.Draw(0, 0, FBuf);                          // nur Helligkeit geaendert: Zwischenbild + Abdunkeln
    DimRect(Canvas.Handle, 2, 2, Width - 4, Height - 4, FDim);   // nur die Anzeige, nicht die Fase
    Exit;
  end;
  FDrawnSig := FSig; FDrawnW := Width; FDrawnH := Height;
  if (FBuf.Width <> Width) or (FBuf.Height <> Height) then
    FBuf.SetSize(Width, Height);
  C := FBuf.Canvas;
  // Display: Einfassung (Fase), dunkles Glas mit leichtem Verlauf und feinen Rasterzeilen
  C.Brush.Color := BG;
  C.FillRect(Rect(0, 0, Width, Height));
  C.Brush.Color := $00151210; C.FillRect(Rect(0, 0, Width, Height));
  C.Pen.Color := $000A0908; C.MoveTo(0, Height - 1); C.LineTo(0, 0); C.LineTo(Width - 1, 0);
  C.Pen.Color := $00585452; C.LineTo(Width - 1, Height - 1); C.LineTo(0, Height - 1);
  for Y := 2 to Height - 3 do
  begin
    T := Y / Max(1, Height);
    C.Pen.Color := RGB(Round(16 + 10 * (1 - T)), Round(13 + 8 * (1 - T)), Round(11 + 6 * (1 - T)));
    if Y mod 3 = 0 then C.Pen.Color := LCD_LINE;      // Rasterzeilen
    C.MoveTo(2, Y); C.LineTo(Width - 2, Y);
  end;
  C.Font.Assign(Font);
  C.Brush.Style := bsClear;
  C.Font.Color := COL_AMBER;
  C.Font.Style := [fsBold];
  C.TextOut(X_NAME, 4, Tr('Rechenblock'));
  C.TextOut(X_A, 4, Tr('Klang A'));
  if FLayerB then
    C.TextOut(X_B, 4, Tr('Klang B'))
  else
    C.TextOut(X_B, 4, Tr('Klang B (aus)'));
  C.Font.Style := [];
  C.Brush.Style := bsSolid;
  for I := 0 to High(FItems) do
  begin
    Y := UiPt(28) + I * ROW;
    C.Brush.Style := bsClear;
    C.Font.Color := LCD_TXT;
    C.TextOut(X_NAME, Y + 2, FItems[I].Name);
    C.Brush.Style := bsSolid;
    // Balkenlaenge: Gewicht relativ zum groessten Block (Grains = 30)
    Bar(X_A, Y, FItems[I].Weight / 30, FItems[I].OnA, LCD_SEG_A);
    Bar(X_B, Y, FItems[I].Weight / 30, FItems[I].OnB, LCD_SEG_B);
  end;
  Y := UiPt(28) + Length(FItems) * ROW + UiPt(8);
  T := TheoryPercent;
  C.Brush.Style := bsClear;
  C.Font.Color := COL_AMBER;
  C.Font.Style := [fsBold];
  C.TextOut(X_NAME, Y, Format(Tr('Theoretische Last: %.0f %% der Volllast (alles an, A + B, 32 Stimmen)'), [T]));
  C.Font.Style := [];
  C.Font.Color := LCD_DIM;
  C.TextOut(X_NAME, Y + 18, Tr('Prozentangabe je Block: Anteil an einem voll belegten Klang (Messwerte des Prüfstands).'));
  Canvas.Draw(0, 0, FBuf);
  DimRect(Canvas.Handle, 2, 2, Width - 4, Height - 4, FDim);   // nur die Anzeige, nicht die Fase
end;

{ ---------------- TLoadGauge ---------------- }

constructor TLoadGauge.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBuf := TBitmap32.Create;
  FFace := TBitmap32.Create;
  ControlStyle := ControlStyle + [csOpaque];
end;

destructor TLoadGauge.Destroy;
begin
  FBuf.Free;
  FFace.Free;
  inherited;
end;

procedure TLoadGauge.SetValues(Load, Peak, Theory: Double);
begin
  FValue := Max(0, Load);
  FPeak := Max(0, Peak);
  FTheory := Max(0, Theory);
end;

procedure TLoadGauge.Tick;
var
  Old: Double;
begin
  Old := FShown;
  FShown := FShown + (FValue - FShown) * 0.25;      // Nadel weich nachfuehren
  if Abs(FShown - Old) > 0.02 then
    Invalidate;
end;

procedure TLoadGauge.Paint;
const
  A0 = 210; A1 = -30;          // Skala von 210 Grad (links unten) bis -30 Grad (rechts unten)
  FULL = 100;                   // Skalenende = 100 % eines Kerns
var
  C: TCanvas;
  Cx, Cy, R: Double;
  I: Integer;
  V: Double;
  S: string;
  P: TFloatPoint;
  Swap: TBitmap32;
  F, Hw: Double;
  PX0, PX1, PY0, PY1: Integer;

  function PtAt(Pct, Rad: Double): TFloatPoint;
  var
    A: Double;
  begin
    A := DegToRad(A0 + (A1 - A0) * EnsureRange(Pct / FULL, 0, 1.08));
    Result := FloatPoint(Cx + Rad * Cos(A), Cy - Rad * Sin(A));
  end;

  { Bogenstueck als geglaettete dicke Linie (Punkte alle 0,5 %) }
  procedure ArcZone(P0, P1: Double; Col: TColor; W: Double);
  var
    Pts: TArrayOfFloatPoint;
    N, K: Integer;
  begin
    N := Max(2, Round((P1 - P0) * 2) + 1);
    SetLength(Pts, N);
    for K := 0 to N - 1 do
      Pts[K] := PtAt(P0 + (P1 - P0) * K / (N - 1), R - 6);
    PolylineFS(FBuf, Pts, Color32(Col), False, W, jsRound, esButt);
  end;

  procedure Line(const A, B: TFloatPoint; Col: TColor; W: Double; Round_: Boolean);
  var
    Pts: TArrayOfFloatPoint;
  begin
    SetLength(Pts, 2);
    Pts[0] := A;
    Pts[1] := B;
    if Round_ then
      PolylineFS(FBuf, Pts, Color32(Col), False, W, jsRound, esRound)
    else
      PolylineFS(FBuf, Pts, Color32(Col), False, W, jsMiter, esButt);
  end;

begin
  Cx := Width / 2;
  // Bogen ueber 240 Grad: reicht R * sin(30) = R/2 unter die Mitte, darunter Wert und Beschriftung (60 px)
  // Platte fuellt das Feld; der Kreis samt Einfassung liegt komplett auf der Platte (angeschraubt = innen)
  R := Max(20, Min(Width / 2, Height / 2) - 22);   // so gross wie moeglich, rund (kein Ei)
  Cy := Height / 2;
  if (FFace.Width <> Width) or (FFace.Height <> Height) then
  begin
    // Zifferblatt einmal je Groesse: Metalleinfassung, Verlauf, Zonen mit Schein, Skala, Glasreflex
    FFace.SetSize(Width, Height);
    Swap := FBuf; FBuf := FFace;          // Hilfsroutinen zeichnen in FBuf
    FBuf.Clear(Color32(BG));
    // rechteckige Platte (Verlauf oben hell -> unten dunkel, Fase) mit vier Schrauben
    // Platte fuellt das ganze Feld (kleiner Rand), der Tacho ist darin eingelassen
    PX0 := 3; PX1 := Width - 4;
    PY0 := 3; PY1 := Height - 4;
    for I := PY0 to PY1 do
    begin
      F := (I - PY0) / Max(1, PY1 - PY0);
      // eingelassen: oben im Schatten der Kante dunkler, nach unten neutral grau (kein Braunton)
      FBuf.HorzLineS(PX0, I, PX1, Color32(Round(26 + 12 * F), Round(27 + 12 * F), Round(30 + 12 * F)));
    end;
    // Fase einer Vertiefung: oben/links Schatten, unten/rechts Lichtkante
    FBuf.HorzLineS(PX0, PY0, PX1, Color32(12, 12, 14));      FBuf.VertLineS(PX0, PY0, PY1, Color32(14, 14, 16));
    FBuf.HorzLineS(PX0 + 1, PY0 + 1, PX1, Color32(20, 20, 23)); FBuf.VertLineS(PX0 + 1, PY0 + 1, PY1, Color32(21, 21, 24));
    FBuf.HorzLineS(PX0, PY1, PX1, Color32(70, 71, 76));      FBuf.VertLineS(PX1, PY0, PY1, Color32(62, 63, 68));
    for I := 0 to 3 do
    begin
      if I mod 2 = 0 then F := PX0 + 9 else F := PX1 - 9;
      if I < 2 then P := FloatPoint(F, PY0 + 9) else P := FloatPoint(F, PY1 - 9);
      PolygonFS(FBuf, Circle(P.X, P.Y, 4, 24), Color32(21, 18, 16));
      PolygonFS(FBuf, Circle(P.X, P.Y, 3.2, 24), Color32(76, 82, 90));
      Line(FloatPoint(P.X - 2.2, P.Y + 2.2), FloatPoint(P.X + 2.2, P.Y - 2.2), $001A1C20, 1.2, False);
    end;
    for I := 0 to 7 do                     // Einfassung: aussen dunkel, Lichtkante, innen dunkel
      PolygonFS(FBuf, Circle(Cx, Cy - 0.6 * (7 - I) / 7, R + 7 - I, 96),
        Color32(Round(24 + 34 * Sin(Pi * I / 7)), Round(25 + 34 * Sin(Pi * I / 7)), Round(28 + 36 * Sin(Pi * I / 7))));   // Graphit, gedaempft
    for I := 0 to 39 do                    // Zifferblatt: Rand dunkel, zur Mitte leicht heller
    begin
      F := I / 39;
      PolygonFS(FBuf, Circle(Cx, Cy, R * (1 - F * 0.98), 96),
        Color32(Round(18 + 22 * F), Round(19 + 22 * F), Round(22 + 24 * F)));
    end;
    // Zonen: gruen bis 50 %, gelb bis 80 %, rot darueber - mit weichem Schein darunter
    ArcZone(0, 50, $0050A050, 6);
    ArcZone(50, 80, $0030C0D0, 6);
    ArcZone(80, 100, $004040D0, 6);
    // Skalenstriche
    for I := 0 to 10 do
      if I mod 5 = 0 then
        Line(PtAt(I * 10, R - 12), PtAt(I * 10, R - 24), $00C0C0C0, 2, False)
      else
        Line(PtAt(I * 10, R - 12), PtAt(I * 10, R - 20), $00A0A0A0, 1.2, False);
    // Schimmer: oben ein Hauch Licht, fliessend nach unten auslaufend (zeilenweise im Kreis, kein Rand)
    for I := Round(Cy - R) to Round(Cy) do
    begin
      F := (I - (Cy - R)) / R;                       // 0 oben .. 1 Mitte
      Hw := Sqrt(Max(0, Sqr(R - 1) - Sqr(I - Cy)));
      if Hw > 1 then
        FBuf.HorzLineTS(Round(Cx - Hw), I, Round(Cx + Hw), Color32(255, 240, 220, Round(22 * Sqr(1 - F))));
    end;
    FBuf := Swap;
  end;
  if (FBuf.Width <> Width) or (FBuf.Height <> Height) then
    FBuf.SetSize(Width, Height);
  FFace.DrawTo(FBuf, 0, 0);
  // Marke: laengster Aufruf (Spitze) in Bernstein
  if FPeak > 0 then
    Line(PtAt(FPeak, R - 1), PtAt(FPeak, R - 15), COL_AMBER, 3, True);
  // Nadel mit Schatten, Nabe
  V := FShown;
  P := PtAt(V, R - 16);
  Line(FloatPoint(Cx + 1.5, Cy + 1.5), FloatPoint(P.X + 1.5, P.Y + 1.5), $00181818, 3.5, True);
  Line(FloatPoint(Cx, Cy), P, $00F0F0F0, 3, True);
  PolygonFS(FBuf, Circle(Cx, Cy, 8, 48), Color32($00303030));
  PolygonFS(FBuf, Circle(Cx, Cy, 6.5, 48), Color32($00707070));
  PolygonFS(FBuf, Circle(Cx - 1.5, Cy - 1.5, 2.5, 24), Color32($00B0B0B0));   // Glanzpunkt

  // Texte (Windows-Schriftglaettung)
  C := FBuf.Canvas;
  C.Font.Assign(Font);
  C.Brush.Style := bsClear;
  for I := 0 to 10 do
    if I mod 2 = 0 then
    begin
      C.Font.Color := COL_TEXT;
      P := PtAt(I * 10, R - 38);
      S := IntToStr(I * 10);
      C.TextOut(Round(P.X) - C.TextWidth(S) div 2, Round(P.Y) - 7, S);
    end;
  C.Font.Size := UiPt(16);
  C.Font.Style := [fsBold];
  S := Format(Tr('%.1f %%'), [FShown]);
  C.TextOut(Round(Cx) - C.TextWidth(S) div 2, Round(Cy) + 16, S);
  C.Font.Size := Font.Size;
  C.Font.Style := [];
  C.Font.Color := COL_DIM;
  S := Tr('Rechenzeit (Anteil eines Kerns)');
  C.TextOut(Round(Cx) - C.TextWidth(S) div 2, Round(Cy + R / 2) + 16, S);
  // nur das Zifferblatt dunkelt ab (Beleuchtung); Platte und Einfassung sind Befestigung und bleiben
  if FDim > 0 then
    PolygonFS(FBuf, Circle(Cx, Cy, R, 96), TColor32(FDim) shl 24);
  FBuf.DrawTo(Canvas.Handle, 0, 0);
end;

end.
