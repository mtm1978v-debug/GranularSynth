{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.FreeLfoView;

{ Editor fuer den frei programmierbaren LFO (Form 'Frei'):
    Halbtoene (Stufen): jede Stufe rastet auf ganze Halbtoene ein -> Melodien ueber Pitch
    Frei (Stufen):      jede Stufe nimmt beliebige Werte an
    Gezeichnet:         Kurve mit der Maus zeichnen; feste Aufloesung (FREE_DRAW_N Punkte),
                        Luecken zwischen Mauspositionen werden linear gefuellt, die Engine
                        interpoliert zusaetzlich -> keine Bildschirm-Treppen im Ton
  Bedienung: Ziehen setzt Werte (auch ueber mehrere Stufen), Rechtsklick/-ziehen setzt 0,
  Mausrad auf einer Stufe = +/- 1 Halbton (bzw. fein im Modus Frei).
  Zeichnen: Raster, Balken und Kurve liegen in einer gecachten Ebene; je Bild kommt nur
  die Abspielmarke dazu, und auch das nur, wenn sie sich bewegt hat. }

interface

uses
  Granular.Lang,
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, System.Types, Vcl.Controls,
  GR32, GR32_Image,
  Granular.Params, Granular.Engine, Granular.GfxAsm;

type
  TFreeLfoView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FLfo: Integer;
    FRange: Integer;           // Halbton-Modus: sichtbar +/- FRange Halbtoene
    FStatic: TBitmap32;
    FDirty: Boolean;
    FDrawing: Boolean;
    FErase: Boolean;
    FLastIdx: Integer;
    FLastVal: Single;
    FMarkKey: Integer;         // zuletzt gezeichnete Markenposition (Stufe bzw. Pixel), -1 = keine
    FWasFree: Boolean;         // Form war beim letzten Aufbau 'Frei' (Hinweistext)
    FOnChange: TNotifyEvent;
    function Data: PFreeLfo;
    function ShapeIsFree: Boolean;
    function VisMax: Single;
    function ValueToY(V: Single; H: Integer): Integer;
    function YToValue(Y, H: Integer): Single;
    function CurrentMarkKey: Integer;
    procedure BuildStatic(W, H: Integer);
    procedure EditAt(X, Y: Integer; First: Boolean);
    procedure Changed;
    procedure SetRange(const Value: Integer);
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine; ALfo: Integer); reintroduce;
    destructor Destroy; override;
    { Daten wurden von aussen geaendert (Preset, Modus, Stufenzahl) }
    procedure Rebuild;
    { im Animationstakt: zeichnet nur, wenn sich Abspielmarke oder Inhalt geaendert haben }
    procedure Tick;
    property Range: Integer read FRange write SetRange;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { Schrittmuster des Arpeggiators: 16 Felder, Klick schaltet einen Schritt an/aus.
    Felder hinter der eingestellten Schrittzahl sind abgedunkelt, der laufende Schritt leuchtet. }
  TArpPatternView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FShown: Integer;
    FMask: Cardinal;
    FSteps: Integer;
    FOnChange: TNotifyEvent;
    FGate: Boolean;
    function CellAt(X: Integer): Integer;
    function CurMask: Cardinal;
    function CurSteps: Integer;
    function CurShown: Integer;
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
    procedure Tick;
    { True: zeigt/bearbeitet das Trance-Gate-Muster statt des Arp-Musters }
    property Gate: Boolean read FGate write FGate;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

const
  COL_BG      = $FF16181C;
  COL_LINE    = $FF24282E;
  COL_OCT     = $FF3A404A;
  COL_ZERO    = $FF56606C;
  COL_SEP     = $FF2C3036;
  COL_BEAT    = $FF444A54;
  COL_BAR     = $FF2D6E9E;
  COL_BAR_NEG = $FF7A4A9E;
  COL_CAP     = $FF9FE0FF;
  COL_CURVE   = $FF9FE0FF;
  COL_FILLC   = $FF20486A;
  TOP_PAD = 6;

constructor TFreeLfoView.Create(AOwner: TComponent; AEngine: TGranularEngine; ALfo: Integer);
begin
  inherited Create(AOwner);
  BufferOversize := 0;
  FEngine := AEngine;
  FLfo := ALfo;
  FRange := 12;
  FDirty := True;
  FMarkKey := -2;
end;

destructor TFreeLfoView.Destroy;
begin
  FStatic.Free;
  inherited;
end;

function TFreeLfoView.Data: PFreeLfo;
begin
  Result := FEngine.FreeLfo[FLfo];
end;

function TFreeLfoView.ShapeIsFree: Boolean;
var
  Id: TGranularParamId;
begin
  if FLfo = 2 then
    Exit(ParamStep(Ord(gpMorphLfoShape), FEngine.GetParam(Ord(gpMorphLfoShape))) = MORPH_LFO_FREE);
  Id := LFO_SHAPE_IDS[EnsureRange(LfoOfFree(FLfo), 0, LFO_COUNT - 1)];
  Result := ParamStep(Ord(Id), FEngine.GetParam(Ord(Id))) = LFO_SHAPE_FREE;
end;

function TFreeLfoView.VisMax: Single;
begin
  if Data.Mode = 0 then
    Result := FRange / FREE_SEMIS
  else
    Result := 1;
end;

function TFreeLfoView.ValueToY(V: Single; H: Integer): Integer;
var
  Amp, Mid: Integer;
begin
  Mid := H div 2;
  Amp := Mid - TOP_PAD;
  Result := Mid - Round(EnsureRange(V / VisMax, -1, 1) * Amp);
end;

function TFreeLfoView.YToValue(Y, H: Integer): Single;
var
  Amp, Mid: Integer;
begin
  Mid := H div 2;
  Amp := Max(1, Mid - TOP_PAD);
  Result := EnsureRange((Mid - Y) / Amp, -1, 1) * VisMax;
  if Data.Mode = 0 then
    Result := FreeQuantize(Result);
end;

procedure TFreeLfoView.SetRange(const Value: Integer);
begin
  if Value <> FRange then
  begin
    FRange := EnsureRange(Value, 1, FREE_SEMIS);
    Rebuild;
  end;
end;

procedure TFreeLfoView.Rebuild;
begin
  FDirty := True;
  Invalidate;
end;

procedure TFreeLfoView.Changed;
begin
  FDirty := True;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TFreeLfoView.CurrentMarkKey: Integer;
var
  Ph: Double;
begin
  Result := -1;
  if not ShapeIsFree then
    Exit;
  Ph := FEngine.LfoPhase[FLfo];
  Ph := Ph - Floor(Ph);
  if Data.Mode = 2 then
    Result := Round(Ph * Max(1, Width - 1))
  else
    Result := Min(Trunc(Ph * Data.Steps), Data.Steps - 1);
end;

procedure TFreeLfoView.Tick;
var
  K: Integer;
begin
  if ShapeIsFree <> FWasFree then
    FDirty := True;
  K := CurrentMarkKey;
  if FDirty or (K <> FMarkKey) then
    Invalidate;
end;

procedure TFreeLfoView.BuildStatic(W, H: Integer);
var
  F: PFreeLfo;
  I, N, X0, X1, Y, Y0, Mid, K, Px: Integer;
  V: Single;
  C: TColor32;
  S: string;
  YPrev: Integer;
  YF, YPrevF: Single;
begin
  if FStatic = nil then
  begin
    FStatic := TBitmap32.Create;
    FStatic.DrawMode := dmOpaque;
  end;
  FStatic.SetSize(W, H);
  F := Data;
  FStatic.BeginUpdate;
  try
    FStatic.Clear(COL_BG);
    FStatic.Font.Name := 'TahomaTr(';
    FStatic.Font.Size := 7;
    Mid := H div 2;

    // waagrechtes Raster
    if F.Mode = 0 then
    begin
      for K := -FRange to FRange do
      begin
        Y := ValueToY(K / FREE_SEMIS, H);
        if K mod 12 = 0 then
          FStatic.HorzLineS(0, Y, W - 1, COL_OCT)
        else if (H - 2 * TOP_PAD) / (2 * FRange) >= 4 then
          FStatic.HorzLineS(0, Y, W - 1, COL_LINE);
      end;
    end
    else
    begin
      FStatic.HorzLineS(0, ValueToY(0.5, H), W - 1, COL_LINE);
      FStatic.HorzLineS(0, ValueToY(-0.5, H), W - 1, COL_LINE);
    end;
    FStatic.HorzLineS(0, Mid, W - 1, COL_ZERO);

    if F.Mode = 2 then
    begin
      // gezeichnete Kurve: Flaeche zur Mittellinie + helle Kontur
      YPrev := ValueToY(FreeLfoValue(F^, 0), H);
      YPrevF := YPrev;
      for Px := 0 to W - 1 do
      begin
        V := FreeLfoValue(F^, Px / W);
        Y := ValueToY(V, H);
        YF := (H div 2) - EnsureRange(V / VisMax, -1, 1) * ((H div 2) - TOP_PAD);
        if Y < Mid then
          FStatic.VertLineS(Px, Y, Mid - 1, COL_FILLC)
        else if Y > Mid then
          FStatic.VertLineS(Px, Mid + 1, Y, COL_FILLC);
        AASpan(FStatic, Px, YPrevF, YF, COL_CURVE);
        YPrev := Y;
        YPrevF := YF;
      end;
      for I := 1 to 3 do
        FStatic.VertLineS(Round(I * W / 4), 0, H - 1, COL_SEP);
    end
    else
    begin
      N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
      FStatic.Font.Color := $00E0E0E0;
      for I := 0 to N - 1 do
      begin
        X0 := I * W div N;
        X1 := (I + 1) * W div N - 1;
        // Trennlinien, jede 4. Stufe kraeftiger (Takt-Orientierung)
        if I > 0 then
          if I mod 4 = 0 then
            FStatic.VertLineS(X0, 0, H - 1, COL_BEAT)
          else
            FStatic.VertLineS(X0, 0, H - 1, COL_SEP);
        V := F.Step[I];
        if F.Mode = 0 then
          V := FreeQuantize(V);
        Y := ValueToY(V, H);
        if V >= 0 then C := COL_BAR else C := COL_BAR_NEG;
        Y0 := Min(Y, Mid);
        if X1 - X0 >= 3 then
        begin
          if Y <> Mid then
            FStatic.FillRectS(X0 + 2, Y0, X1 - 1, Max(Y, Mid) + 1, C);
          FStatic.FillRectS(X0 + 2, Y - 1, X1 - 1, Y + 2, COL_CAP);
        end
        else
          FStatic.VertLineS(X0, Min(Y, Mid), Max(Y, Mid), COL_CAP);
        // Halbtonzahl in die Stufe schreiben, wenn Platz ist
        if (F.Mode = 0) and (X1 - X0 >= 18) then
        begin
          K := Round(V * FREE_SEMIS);
          if K > 0 then S := '+' + IntToStr(K) else S := IntToStr(K);
          if V >= 0 then
            FStatic.Textout(X0 + 4, Min(Y + 3, H - 14), S)
          else
            FStatic.Textout(X0 + 4, Max(Y - 14, 0), S);
        end;
      end;
    end;

    FStatic.Font.Color := $00909090;
    if F.Mode = 0 then
    begin
      FStatic.Textout(W - 30, ValueToY(Min(12, FRange) / FREE_SEMIS, H) + 1, Format(Tr(')+%d'), [Min(12, FRange)]));
      FStatic.Textout(W - 30, ValueToY(-Min(12, FRange) / FREE_SEMIS, H) - 12, Format(Tr('-%d'), [Min(12, FRange)]));
    end;
    FWasFree := ShapeIsFree;
    if not FWasFree then
    begin
      FStatic.Font.Color := $0060B0FF;
      FStatic.Textout(6, 4, Tr('inaktiv - Form "Frei" wählen (Knopf rechts oder Modulations-Reiter)'));
    end;
  finally
    FStatic.EndUpdate;
  end;
  FDirty := False;
end;

procedure TFreeLfoView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, X0, X1, N, K, Y: Integer;
begin
  Buffer.BeginUpdate;
  try
    B := Buffer;
    W := B.Width;
    H := B.Height;
    if (W < 20) or (H < 20) then
    begin
      B.Clear(COL_BG);
      FDirty := False;
    end
    else
    begin
      if FDirty or (FStatic = nil) or (FStatic.Width <> W) or (FStatic.Height <> H) then
        BuildStatic(W, H);
      FStatic.DrawTo(B, 0, 0);
      K := CurrentMarkKey;
      FMarkKey := K;
      if K >= 0 then
      begin
        if Data.Mode = 2 then
        begin
          // Abspielmarke mit weichem Lichthof
          Y := ValueToY(FreeLfoValue(Data^, FEngine.LfoPhase[FLfo]), H);
          B.FillRectTS(K - 3, 0, K + 4, H, $18FF5A5A);
          B.VertLineTS(K, 0, H - 1, $70FF5A5A);
          B.FillRectTS(K - 4, Y - 4, K + 5, Y + 5, $50FF5A5A);
          B.FillRectS(K - 2, Y - 2, K + 3, Y + 3, $FFFF5A5A);
        end
        else
        begin
          // aktuelle Stufe leuchtet auf
          N := EnsureRange(Data.Steps, 1, FREE_MAX_STEPS);
          X0 := K * W div N;
          X1 := (K + 1) * W div N;
          B.FillRectTS(X0 + 1, 0, X1, H, $30FFD070);
          B.FillRectTS(X0 + 1, H - 4, X1, H, $C0FFD070);
        end;
      end;
    end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

procedure TFreeLfoView.EditAt(X, Y: Integer; First: Boolean);
var
  F: PFreeLfo;
  N, Idx, I, A, Bi: Integer;
  V: Single;
  T: Double;
  W, H: Integer;
begin
  F := Data;
  W := Max(1, Width);
  H := Height;
  if FErase then
    V := 0
  else
    V := YToValue(Y, H);
  if F.Mode = 2 then
  begin
    Idx := EnsureRange(X * FREE_DRAW_N div W, 0, FREE_DRAW_N - 1);
    // Luecke zur letzten Mausposition linear fuellen
    if First or (FLastIdx < 0) then
      F.Draw[Idx] := V
    else
    begin
      A := Min(FLastIdx, Idx);
      Bi := Max(FLastIdx, Idx);
      for I := A to Bi do
      begin
        if Bi = A then T := 1 else T := (I - FLastIdx) / (Idx - FLastIdx);
        F.Draw[I] := FLastVal + (V - FLastVal) * T;
      end;
    end;
  end
  else
  begin
    N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
    Idx := EnsureRange(X * N div W, 0, N - 1);
    if First or (FLastIdx < 0) then
      F.Step[Idx] := V
    else
    begin
      A := Min(FLastIdx, Idx);
      Bi := Max(FLastIdx, Idx);
      for I := A to Bi do
      begin
        if Bi = A then T := 1 else T := (I - FLastIdx) / (Idx - FLastIdx);
        F.Step[I] := FLastVal + (V - FLastVal) * T;
        if F.Mode = 0 then
          F.Step[I] := FreeQuantize(F.Step[I]);
      end;
    end;
  end;
  FLastIdx := Idx;
  FLastVal := V;
  Changed;
end;

procedure TFreeLfoView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button in [mbLeft, mbRight] then
  begin
    FDrawing := True;
    FErase := Button = mbRight;
    FLastIdx := -1;
    MouseCapture := True;
    EditAt(X, Y, True);
  end;
end;

procedure TFreeLfoView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDrawing then
    EditAt(EnsureRange(X, 0, Width - 1), EnsureRange(Y, 0, Height - 1), False);
end;

procedure TFreeLfoView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDrawing := False;
  FErase := False;
  MouseCapture := False;
end;

function TFreeLfoView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  P: TPoint;
  F: PFreeLfo;
  N, Idx, Dir: Integer;
begin
  Result := True;
  F := Data;
  if F.Mode = 2 then
    Exit;
  P := ScreenToClient(MousePos);
  N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
  Idx := EnsureRange(P.X * N div Max(1, Width), 0, N - 1);
  if WheelDelta > 0 then Dir := 1 else Dir := -1;
  if F.Mode = 0 then
    F.Step[Idx] := FreeQuantize(FreeQuantize(F.Step[Idx]) + Dir / FREE_SEMIS)
  else
    F.Step[Idx] := EnsureRange(F.Step[Idx] + Dir * 0.02, -1, 1);
  Changed;
end;

{ TArpPatternView }

constructor TArpPatternView.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  BufferOversize := 0;
  FEngine := AEngine;
  FShown := -2;
end;

function TArpPatternView.CellAt(X: Integer): Integer;
begin
  Result := EnsureRange(X * ARP_MAX_STEPS div Max(1, Width), 0, ARP_MAX_STEPS - 1);
end;

function TArpPatternView.CurMask: Cardinal;
begin
  if FGate then Result := FEngine.TgMask else Result := FEngine.ArpMask;
end;

function TArpPatternView.CurSteps: Integer;
begin
  if FGate then
    Result := ParamStep(Ord(gpTgSteps), FEngine.GetParam(Ord(gpTgSteps))) + 1
  else
    Result := ParamStep(Ord(gpArpSteps), FEngine.GetParam(Ord(gpArpSteps))) + 1;
end;

function TArpPatternView.CurShown: Integer;
begin
  if FGate then Result := FEngine.TgShownStep else Result := FEngine.ArpShownStep;
end;

procedure TArpPatternView.Tick;
begin
  if (CurShown <> FShown) or (CurMask <> FMask) or (CurSteps <> FSteps) then
    Invalidate;
end;

procedure TArpPatternView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, I, X0, X1: Integer;
  On, Active: Boolean;
  C: TColor32;
begin
  Buffer.BeginUpdate;
  try
    B := Buffer;
    W := B.Width;
    H := B.Height;
    B.Clear(COL_BG);
    FShown := CurShown;
    FMask := CurMask;
    FSteps := CurSteps;
    B.Font.Name := 'Tahoma';
    B.Font.Size := 7;
    for I := 0 to ARP_MAX_STEPS - 1 do
    begin
      X0 := I * W div ARP_MAX_STEPS + 1;
      X1 := (I + 1) * W div ARP_MAX_STEPS - 1;
      On := (FMask and (1 shl I)) <> 0;
      Active := I < FSteps;
      if On and Active then C := COL_BAR
      else if On then C := $FF263240
      else if Active then C := $FF2A2E34
      else C := $FF1E2024;
      B.FillRectS(X0, 2, X1, H - 2, C);
      if I mod 4 = 0 then
        B.VertLineS(X0 - 1, 0, H - 1, COL_BEAT);
      if I = FShown then
      begin
        B.FillRectTS(X0, 2, X1, H - 2, $60FFD070);
        B.FillRectS(X0, H - 5, X1, H - 2, $FFFFD070);
      end;
      if Active then B.Font.Color := $00E0E0E0 else B.Font.Color := $00606060;
      B.Textout(X0 + 3, 4, IntToStr(I + 1));
    end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

procedure TArpPatternView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    if FGate then
      FEngine.TgMask := FEngine.TgMask xor (1 shl CellAt(X))
    else
      FEngine.ArpMask := FEngine.ArpMask xor (1 shl CellAt(X));
    Invalidate;
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

end.
