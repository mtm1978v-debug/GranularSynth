{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.WaveView;

{ Wellenformanzeige auf Basis von Graphics32 (TCustomPaintBox32).
  Bedienung:
    Linke Maustaste ziehen   -> Auswahlbereich neu aufziehen
    Linke Maustaste an Kante -> Auswahlkante verschieben
    Rechte Maustaste         -> Position innerhalb der Auswahl setzen
  Alle Werte normalisiert (0..1 bezogen auf das ganze Sample). }

interface

uses
  Granular.Lang,
  System.Classes, System.Types, System.SysUtils, System.Math, System.StrUtils,
  Vcl.Controls, Vcl.Graphics,
  GR32, GR32_Image,
  Granular.Sample, Granular.Prof;

const
  PEAK_RES = 2048;
  MAX_LIVE = 128;

type
  TWaveDrag = (wdNone, wdNewSel, wdSelStart, wdSelEnd, wdPosition, wdPreStart);

  TWaveView = class(TCustomPaintBox32)
  private
    FMin, FMax: array[0..1] of array[0..PEAK_RES - 1] of Single;
    FHasData: Boolean;
    FStereo: Boolean;
    FInfo: string;
    FSelStart, FSelEnd: Double;
    FPreStart: Double;  // Anlauf-Start (< 0 = kein Anlauf)
    FPosition: Double;  // relativ zur Auswahl 0..1
    FSpray: Double;     // relativ zur Auswahl 0..1
    FPlayheads: array[0..MAX_LIVE - 1] of Single;
    FPlayheadCount: Integer;
    FGrains: array[0..MAX_LIVE - 1] of Single;
    FGrainCount: Integer;
    FDrag: TWaveDrag;
    FAnchor: Double;
    FOnSelectionChange: TNotifyEvent;
    FOnPreStartChange: TNotifyEvent;
    FOnPositionChange: TNotifyEvent;
    FStatic: TBitmap32;       // Hintergrund + Wellenform + Marker, nur bei Bedarf neu
    FStaticValid: Boolean;
    procedure InvalidateStatic;
    procedure SetPreStartFromX(X: Integer);
    procedure MoveStartLine(X: Integer);
    function StartLine: Double;
    procedure RenderStatic(B: TBitmap32);
    function XToNorm(X: Integer): Double;
    function NormToX(N: Double): Integer;
    function AbsPosition: Double;
    procedure SetPositionFromX(X: Integer);
  protected
    procedure DoPaintBuffer; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetSample(Data: TSampleData);
    procedure SetSelection(AStart, AEnd: Double);
    { Anlauf vor der Auswahl anzeigen (< 0 oder >= Auswahlstart = aus) }
    procedure SetPreStart(Value: Double);
    procedure SetPosition(APos, ASpray: Double);
    procedure SetLiveData(const Playheads: array of Single; PlayheadCount: Integer;
      const Grains: array of Single; GrainCount: Integer);
    property SelStart: Double read FSelStart;
    property SelEnd: Double read FSelEnd;
    property Position: Double read FPosition;
    { Anlauf-Start (0..1 vor der Auswahl, < 0 = kein Anlauf); Rechtsklick links neben die Auswahl
      oder die Fahne ziehen setzt ihn, in die Auswahl gezogen = aus }
    property PreStart: Double read FPreStart;
    property OnPreStartChange: TNotifyEvent read FOnPreStartChange write FOnPreStartChange;
    property OnSelectionChange: TNotifyEvent read FOnSelectionChange write FOnSelectionChange;
    property OnPositionChange: TNotifyEvent read FOnPositionChange write FOnPositionChange;
  end;

implementation

const
  EDGE_TOLERANCE = 5;

constructor TWaveView.Create(AOwner: TComponent);
begin
  inherited;
  BufferOversize := 0;   // Puffer = Controlgroesse (Standard waere +40 px)
  FStatic := TBitmap32.Create;
  FStatic.DrawMode := dmOpaque;
  FSelStart := 0;
  FPreStart := -1;
  FSelEnd := 1;
  FInfo := Tr('Keine Sounddatei geladen - "WAV laden..." benutzen');
end;

destructor TWaveView.Destroy;
begin
  FStatic.Free;
  inherited;
end;

procedure TWaveView.InvalidateStatic;
begin
  FStaticValid := False;
  ForceFullInvalidate;
end;

procedure TWaveView.Resize;
begin
  inherited;
  FStaticValid := False;
end;

procedure TWaveView.SetSample(Data: TSampleData);
var
  Ch, B, F, F0, F1: Integer;
  Src: TArray<Single>;
  Lo, Hi, V: Single;
begin
  FHasData := (Data <> nil) and (Data.Frames > 0);
  if FHasData then
  begin
    FStereo := Data.Channels > 1;
    for Ch := 0 to 1 do
    begin
      if Ch = 0 then Src := Data.L else Src := Data.R;
      for B := 0 to PEAK_RES - 1 do
      begin
        F0 := Int64(B) * Data.Frames div PEAK_RES;
        F1 := Max(F0 + 1, Int64(B + 1) * Data.Frames div PEAK_RES);
        Lo := 0; Hi := 0;
        for F := F0 to Min(F1, Data.Frames) - 1 do
        begin
          V := Src[F];
          if V < Lo then Lo := V;
          if V > Hi then Hi := V;
        end;
        FMin[Ch, B] := Lo;
        FMax[Ch, B] := Hi;
      end;
    end;
    FInfo := Format(Tr('%s  |  %d Hz  |  %s  |  %.2f s'),
      [ExtractFileName(Data.FileName), Round(Data.SampleRate),
       IfThen(FStereo, Tr('Stereo'), Tr('Mono')), Data.Frames / Data.SampleRate]);
  end;
  InvalidateStatic;
end;

procedure TWaveView.SetSelection(AStart, AEnd: Double);
begin
  FSelStart := Min(AStart, AEnd);
  FSelEnd := Max(AStart, AEnd);
  InvalidateStatic;
end;

procedure TWaveView.SetPreStart(Value: Double);
begin
  if Value = FPreStart then
    Exit;
  FPreStart := Value;
  InvalidateStatic;
end;

{ Wo die gelbe Linie steht: Anlauf-Start (vor der Auswahl) oder die Position in der Auswahl }
function TWaveView.StartLine: Double;
begin
  if (FPreStart >= 0) and (FPreStart < FSelStart) then
    Result := FPreStart
  else
    Result := AbsPosition;
end;

{ Gelbe Linie setzen: links von der Auswahl = Anlauf-Start (Note laeuft von dort in die Auswahl),
  in der Auswahl = Position (kein Anlauf) }
procedure TWaveView.MoveStartLine(X: Integer);
begin
  if XToNorm(X) < FSelStart - 0.0005 then
  begin
    // Start vor der Auswahl: kein zusaetzlicher Versatz, die Note beginnt genau an der Linie
    if FPosition <> 0 then
    begin
      FPosition := 0;
      if Assigned(FOnPositionChange) then
        FOnPositionChange(Self);
    end;
    SetPreStartFromX(X);
  end
  else
  begin
    if FPreStart >= 0 then
    begin
      FPreStart := -1;
      if Assigned(FOnPreStartChange) then
        FOnPreStartChange(Self);
    end;
    SetPositionFromX(X);
  end;
end;

procedure TWaveView.SetPreStartFromX(X: Integer);
var
  N: Double;
begin
  N := XToNorm(X);
  if N >= FSelStart - 0.0005 then
    FPreStart := -1               // in die Auswahl gezogen: kein Anlauf
  else
    FPreStart := N;
  if Assigned(FOnPreStartChange) then
    FOnPreStartChange(Self);
  InvalidateStatic;
end;

procedure TWaveView.SetPosition(APos, ASpray: Double);
begin
  FPosition := APos;
  FSpray := ASpray;
  InvalidateStatic;
end;

procedure TWaveView.SetLiveData(const Playheads: array of Single; PlayheadCount: Integer;
  const Grains: array of Single; GrainCount: Integer);
var
  I, NP, NG: Integer;
  Same: Boolean;
begin
  NP := Min(PlayheadCount, MAX_LIVE);
  NG := Min(GrainCount, MAX_LIVE);
  Same := (NP = FPlayheadCount) and (NG = FGrainCount);
  I := 0;
  while Same and (I < NP) do
  begin
    Same := FPlayheads[I] = Playheads[I];
    Inc(I);
  end;
  I := 0;
  while Same and (I < NG) do
  begin
    Same := FGrains[I] = Grains[I];
    Inc(I);
  end;
  if Same then
    Exit;   // nichts bewegt sich -> kein Neuzeichnen
  FPlayheadCount := Min(PlayheadCount, MAX_LIVE);
  for I := 0 to FPlayheadCount - 1 do
    FPlayheads[I] := Playheads[I];
  FGrainCount := Min(GrainCount, MAX_LIVE);
  for I := 0 to FGrainCount - 1 do
    FGrains[I] := Grains[I];
  ForceFullInvalidate;
end;

function TWaveView.XToNorm(X: Integer): Double;
begin
  if Width <= 1 then
    Result := 0
  else
    Result := EnsureRange(X / (Width - 1), 0, 1);
end;

function TWaveView.NormToX(N: Double): Integer;
begin
  Result := Round(N * (Width - 1));
end;

function TWaveView.AbsPosition: Double;
begin
  Result := FSelStart + FPosition * (FSelEnd - FSelStart);
end;

procedure TWaveView.SetPositionFromX(X: Integer);
var
  Len: Double;
begin
  Len := FSelEnd - FSelStart;
  if Len <= 0 then
    FPosition := 0
  else
    FPosition := EnsureRange((XToNorm(X) - FSelStart) / Len, 0, 1);
  if Assigned(FOnPositionChange) then
    FOnPositionChange(Self);
  InvalidateStatic;
end;

procedure TWaveView.RenderStatic(B: TBitmap32);
var
  W, H, X, Ch, Bk0, Bk1, Bk, YC, H2, Y0, Y1, I, XS, XE, XP, XA: Integer;
  HasPre, InPre: Boolean;
  Lo, Hi: Single;
  N, SprayW: Double;
  InSel: Boolean;
  Alpha: Integer;
  Col: TColor32;
begin
  W := B.Width;
  H := B.Height;
  B.Clear(Color32(22, 24, 28));
  if (W < 4) or (H < 4) then
    Exit;

  XS := NormToX(FSelStart);
  XE := NormToX(FSelEnd);

  if FHasData then
  begin
    // Auswahlbereich, davor der Anlauf (bernsteinfarben)
    B.FillRectS(XS, 0, XE + 1, H, Color32(36, 48, 64));
    HasPre := (FPreStart >= 0) and (FPreStart < FSelStart);
    XA := NormToX(Max(FPreStart, 0));
    if HasPre then
      B.FillRectS(XA, 0, XS, H, Color32(52, 42, 26));

    // Spray-Bereich um die Position
    XP := NormToX(AbsPosition);
    SprayW := FSpray * (FSelEnd - FSelStart);
    if SprayW > 0 then
      B.FillRectTS(NormToX(AbsPosition - SprayW), 0, NormToX(AbsPosition + SprayW) + 1, H,
        Color32(255, 200, 60, 40));

    // Wellenform (oben links, unten rechts)
    H2 := H div 4;
    for Ch := 0 to 1 do
    begin
      YC := H div 4 + Ch * (H div 2);
      B.HorzLineS(0, YC, W - 1, Color32(50, 54, 60));
      for X := 0 to W - 1 do
      begin
        Bk0 := Int64(X) * PEAK_RES div W;
        Bk1 := Max(Bk0, Int64(X + 1) * PEAK_RES div W - 1);
        Lo := 0; Hi := 0;
        for Bk := Bk0 to Min(Bk1, PEAK_RES - 1) do
        begin
          if FMin[Ch, Bk] < Lo then Lo := FMin[Ch, Bk];
          if FMax[Ch, Bk] > Hi then Hi := FMax[Ch, Bk];
        end;
        Y0 := YC - Round(Hi * H2);
        Y1 := YC - Round(Lo * H2);
        InSel := (X >= XS) and (X <= XE);
        InPre := HasPre and (X >= XA) and (X < XS);
        if InSel then Col := Color32(120, 200, 140)
        else if InPre then Col := Color32(190, 160, 90)
        else Col := Color32(70, 100, 80);
        B.VertLineS(X, Y0, Y1, Col);
      end;
    end;
    B.HorzLineS(0, H div 2, W - 1, Color32(60, 60, 70));

    // gelbe Linie: Startpunkt (mit Anlauf vor der Auswahl, sonst die Position in der Auswahl)
    if HasPre then
      XP := XA;
    B.VertLineS(XP, 0, H - 1, Color32(255, 200, 60));
    B.FillRectS(XP - 3, H - 8, XP + 4, H, Color32(255, 200, 60));


    // Auswahlkanten mit Griffen
    B.VertLineS(XS, 0, H - 1, clWhite32);
    B.VertLineS(XE, 0, H - 1, clWhite32);
    B.FillRectS(XS, 0, XS + 6, 10, clWhite32);
    B.FillRectS(XE - 5, 0, XE + 1, 10, clWhite32);

    if FStereo then
    begin
      B.Font.Color := $A0A0A0;
      B.Textout(4, 12, 'L');
      B.Textout(4, H div 2 + 4, 'R');
    end;
  end;

  B.Font.Name := 'Tahoma';
  B.Font.Size := 8;
  B.Font.Color := $C8C8C8;
  B.Textout(14, H - 16, FInfo);
  N := FSelEnd - FSelStart;
  if FHasData then
    B.Textout(W - 220, H - 16, Format(Tr('Auswahl %.1f%% - %.1f%% (%.1f%%)'),
      [FSelStart * 100, FSelEnd * 100, N * 100]));
end;

procedure TWaveView.DoPaintBuffer;
var
  B: TBitmap32;
  I, X, H, Alpha: Integer;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  if not FStaticValid or (FStatic.Width <> B.Width) or (FStatic.Height <> B.Height) then
  begin
    FStatic.SetSize(B.Width, B.Height);
    RenderStatic(FStatic);
    FStaticValid := True;
  end;
  FStatic.DrawTo(B, 0, 0);   // reine Speicherkopie (dmOpaque)
  H := B.Height;

  if FHasData then
  begin
    // zuletzt erzeugte Grains (neueste kraeftig, aeltere verblassen)
    for I := FGrainCount - 1 downto 0 do
      if FGrains[I] >= 0 then
      begin
        Alpha := 220 - (I * 200) div MAX_LIVE;
        X := NormToX(FGrains[I]);
        // kurze Leuchtmarken oben und unten statt einer halbtransparenten Linie ueber die ganze Hoehe
        B.FillRectTS(X - 1, 1, X + 2, 12, Color32(90, 200, 255, Alpha));
        B.FillRectTS(X - 1, H - 12, X + 2, H - 1, Color32(90, 200, 255, Alpha div 2));
      end;
    // Stimmen-Abspielkoepfe
    for I := 0 to FPlayheadCount - 1 do
    begin
      X := NormToX(FPlayheads[I]);
      B.VertLineS(X, 0, H - 1, Color32(255, 90, 90));
    end;
  end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

procedure TWaveView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if not FHasData then
    Exit;
  if Button = mbRight then
  begin
    FDrag := wdPosition;
    MoveStartLine(X);
    Exit;
  end;
  if Button <> mbLeft then
    Exit;
  // gelbe Linie mit links greifen (nicht auf einer Auswahlkante)
  if (Abs(X - NormToX(StartLine)) <= EDGE_TOLERANCE) and
     (Abs(X - NormToX(FSelStart)) > EDGE_TOLERANCE) and (Abs(X - NormToX(FSelEnd)) > EDGE_TOLERANCE) then
    FDrag := wdPosition
  else if Abs(X - NormToX(FSelStart)) <= EDGE_TOLERANCE then
    FDrag := wdSelStart
  else if Abs(X - NormToX(FSelEnd)) <= EDGE_TOLERANCE then
    FDrag := wdSelEnd
  else
  begin
    FDrag := wdNewSel;
    FAnchor := XToNorm(X);
  end;
end;

procedure TWaveView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  N, T: Double;
begin
  inherited;
  if FDrag = wdNone then
  begin
    if FHasData and ((Abs(X - NormToX(FSelStart)) <= EDGE_TOLERANCE) or
                     (Abs(X - NormToX(FSelEnd)) <= EDGE_TOLERANCE) or
                     (Abs(X - NormToX(StartLine)) <= EDGE_TOLERANCE)) then
      Cursor := crSizeWE
    else
      Cursor := crDefault;
    Exit;
  end;

  N := XToNorm(X);
  case FDrag of
    wdPosition:
      begin
        MoveStartLine(X);
        Exit;
      end;
    wdNewSel:
      begin
        FSelStart := Min(FAnchor, N);
        FSelEnd := Max(FAnchor, N);
      end;
    wdSelStart: FSelStart := N;
    wdSelEnd:   FSelEnd := N;
  end;
  if FSelStart > FSelEnd then
  begin
    // Kanten haben sich gekreuzt -> Rollen tauschen
    T := FSelStart; FSelStart := FSelEnd; FSelEnd := T;
    if FDrag = wdSelStart then FDrag := wdSelEnd
    else if FDrag = wdSelEnd then FDrag := wdSelStart;
  end;
  if Assigned(FOnSelectionChange) then
    FOnSelectionChange(Self);
  InvalidateStatic;
end;

procedure TWaveView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  // Klick ohne Ziehen: Auswahl nicht auf Null zusammenfallen lassen
  if (FDrag = wdNewSel) and (FSelEnd - FSelStart < 0.002) then
  begin
    FSelStart := 0;
    FSelEnd := 1;
    if Assigned(FOnSelectionChange) then
      FOnSelectionChange(Self);
    InvalidateStatic;
  end;
  FDrag := wdNone;
end;

end.
