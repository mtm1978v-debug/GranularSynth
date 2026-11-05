{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.EqView;

{ Kurvenansicht des grafischen Equalizers: 20 Hz .. 20 kHz logarithmisch, +-18 dB.
  Ziehen mit der linken Maustaste zeichnet die Kurve (Luecken zwischen Mauspositionen werden
  gefuellt), rechte Maustaste zieht auf 0 dB. Duenn: gezeichnete Kurve, hell mit Flaeche:
  tatsaechlicher Frequenzgang aller Filter (nur bei Aenderung neu berechnet).
  Raster und Beschriftung liegen in einer gecachten Ebene.
  Hintergrund leuchtet, wo am Ausgang (nach dem EQ) Frequenzen klingen (Helligkeit = Pegel);
  wo der EQ absenkt, wird es blauer, wo er anhebt, roter (Vergleich mit eigener FFT ueber
  den Abgriff vor dem EQ). Aufhellen zeilenweise per SIMD (AddRowSat, Granular.GfxAsm). }

interface

uses
  Granular.Lang,
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, Vcl.Controls,
  GR32, GR32_Image,
  Granular.Params, Granular.Engine, Granular.Eq, Granular.GfxAsm, Granular.Spectrum;

type
  { Kennlinie des Kompressors (Reiter Summe): waagrecht Eingang -60..0 dBFS, senkrecht Ausgang;
    gestrichelte Diagonale = unveraendert, gelbe Linie = Schwelle. Rechnet mit CompGainDb der Engine
    und der eingestellten Menge - zeigt also genau, was der Kompressor je Band tut. }
  TCompCurveView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
  protected
    procedure DoPaintBuffer; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Engine: TGranularEngine read FEngine write FEngine;
  end;

  TEqView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FGrid: TBitmap32;
    FResp: array of Single;      // Frequenzgang je Pixelspalte (dB)
    FKey: string;                // Kennung des zuletzt berechneten Zustands
    FDrawing, FErase: Boolean;
    FLastIdx: Integer;
    FLastVal: Single;
    FOnChange: TNotifyEvent;
    FSpectrum: TSpectrumView;    // liefert die Pegel je Spalte (Analyse ohne Zeichnen)
    FPre: TSpectrumView;         // eigene Analyse vor dem EQ (nie sichtbar)
    FOut: TArray<Single>;        // Ausgangspegel je Spalte
    FGlow: array of TColor32;    // Aufhellung je Spalte
    FGlowOn: Boolean;            // Hintergrund leuchtet gerade (noch einmal dunkel zeichnen, wenn es endet)
    function XToF(X: Integer): Double;
    function DbToY(Db: Double): Single;
    procedure BuildGrid(W, H: Integer);
    procedure EditAt(X, Y: Integer; First: Boolean);
    function StateKey: string;
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
    destructor Destroy; override;
    { im Anzeige-Takt: zeichnet nur, wenn sich Kurve oder Bass/Hoehen geaendert haben }
    procedure Tick;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Spectrum: TSpectrumView read FSpectrum write FSpectrum;
  end;

implementation

constructor TCompCurveView.Create(AOwner: TComponent);
begin
  inherited;
  BufferOversize := 0;      // Puffer = sichtbare Flaeche (sonst liegen rechte Beschriftung und Raster daneben)
end;

procedure TCompCurveView.DoPaintBuffer;
const
  DB_MIN = -60.0;
  C_BG = $FF17191D;
  C_GRID = $FF2A2E35;
  C_DIAG = $FF4A505A;
  C_THR = $FFE8B040;
  C_CURVE = $FF9FE0FF;
  C_OFF = $FF5A6470;
var
  B: TBitmap32;
  W, H, Px, I, Y: Integer;
  Th, Rt, Kn, Amt, Lv, Out_, YF, YPrev: Double;
  On_: Boolean;

  function DbToY(D: Double): Double;
  begin
    Result := (H - 1) * (1 - (EnsureRange(D, DB_MIN, 0) - DB_MIN) / -DB_MIN);
  end;

begin
  B := Buffer;
  B.BeginUpdate;
  try
    W := B.Width;
    H := B.Height;
    B.Clear(C_BG);
    if (W < 20) or (H < 20) or (FEngine = nil) then
      Exit;
    // Raster alle 12 dB
    I := 12;
    while I < 60 do
    begin
      Px := Round((W - 1) * (1 - I / 60));
      B.VertLineS(Px, 0, H - 1, C_GRID);
      B.HorzLineS(0, Round(DbToY(-I)), W - 1, C_GRID);
      Inc(I, 12);
    end;
    // unveraendert (Diagonale), gestrichelt
    for Px := 0 to W - 1 do
      if (Px div 3) mod 2 = 0 then
        B.PixelS[Px, Round(DbToY(DB_MIN + -DB_MIN * Px / (W - 1)))] := C_DIAG;
    Th := Round(ParamToPlain(gpCompThresh, FEngine.GetParamById(gpCompThresh)) * 10) / 10;
    Rt := Max(1, Round(ParamToPlain(gpCompRatio, FEngine.GetParamById(gpCompRatio)) * 10) / 10);
    Kn := Max(0, Round(ParamToPlain(gpCompKnee, FEngine.GetParamById(gpCompKnee)) * 10) / 10);
    Amt := ParamToPlain(gpCompAmt, FEngine.GetParamById(gpCompAmt)) / 100;
    On_ := FEngine.GetParamById(gpCompOn) >= 0.5;
    Px := Round((W - 1) * (Th - DB_MIN) / -DB_MIN);
    B.VertLineS(Px, 0, H - 1, C_THR);
    YPrev := -1;
    for Px := 0 to W - 1 do
    begin
      Lv := DB_MIN + -DB_MIN * Px / (W - 1);
      Out_ := Lv + CompGainDb(Lv, Th, Rt, Kn) * Amt;
      YF := DbToY(Out_);
      if YPrev < 0 then YPrev := YF;
      if On_ then
      begin
        AASpan(B, Px, YPrev, YF, C_CURVE);
        AASpan(B, Px, YPrev + 1, YF + 1, C_CURVE);
      end
      else
        AASpan(B, Px, YPrev, YF, C_OFF);
      YPrev := YF;
    end;
    B.Font.Name := 'Tahoma';
    B.Font.Size := UiPt(7);
    B.Font.Color := $00909090;
    B.Textout(3, 2, Tr('Ausgang'));
    Y := H - 14;
    B.Textout(W - B.TextWidth(Tr('Eingang')) - 3, Y, Tr('Eingang'));
    if not On_ then
    begin
      B.Font.Color := $0060B0FF;
      B.Textout(3, Y, Tr('aus'));
    end;
  finally
    B.EndUpdate;
  end;
  inherited;
end;

const
  COL_BG = $FF16181C;
  COL_LINE = $FF262A31;
  COL_ZERO = $FF4A525C;
  COL_DRAWN = $FF6C7A8C;
  COL_RESP = $FF9FE0FF;
  COL_FILL_UP = $3060C0FF;
  COL_FILL_DN = $30FF9060;
  PAD_B = 16;

constructor TEqView.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  BufferOversize := 0;
  FEngine := AEngine;
end;

destructor TEqView.Destroy;
begin
  FPre.Free;
  FGrid.Free;
  inherited;
end;

function TEqView.XToF(X: Integer): Double;
begin
  Result := EQ_F_MIN * Power(EQ_F_MAX / EQ_F_MIN, EnsureRange(X / Max(1, Width - 1), 0, 1));
end;

function TEqView.DbToY(Db: Double): Single;
var
  H: Integer;
begin
  H := Height - PAD_B;
  Result := H / 2 - EnsureRange(Db, -EQ_MAX_DB, EQ_MAX_DB) / EQ_MAX_DB * (H / 2 - 6);
end;

function TEqView.StateKey: string;
begin
  Result := Format(Tr('%d|%.2f|%.2f|%.3f|%.3f|%.3f|%.3f|%d|%d'), [FEngine.EqVersion,
    ParamToPlain(gpEqBass, FEngine.GetParam(Ord(gpEqBass))),
    ParamToPlain(gpEqTreble, FEngine.GetParam(Ord(gpEqTreble))),
    FEngine.GetParam(Ord(gpEqAFreq)), FEngine.GetParam(Ord(gpEqAGain)), FEngine.GetParam(Ord(gpEqBFreq)),
    FEngine.GetParam(Ord(gpEqBGain)), Width, Height]);
end;

procedure TEqView.Tick;
var
  L: TArray<Single>;
  X, W: Integer;
  V, T: Single;
  Any: Boolean;
begin
  W := Width;
  Any := False;
  if FPre = nil then
  begin
    FPre := TSpectrumView.Create(nil, FEngine);
    FPre.PreEq := True;
  end;
  // Ausgang nach dem EQ
  SetLength(FOut, 0);
  if (FSpectrum <> nil) and (W >= 40) and FSpectrum.Analyze(W) then
  begin
    FOut := FSpectrum.Levels;
    for X := 0 to High(FOut) do
      if FOut[X] > 0.02 then
      begin
        Any := True;
        Break;
      end;
  end;
  // Leuchten = Ausgang nach dem EQ (blau-weiss); Differenz zum Signal vor dem EQ faerbt ein:
  // abgesenkt -> blauer, angehoben -> roter (volle Faerbung bei 12 dB)
  FPre.Analyze(W);
  L := FPre.Levels;
  if Length(FOut) = W then
  begin
    SetLength(FGlow, W);
    for X := 0 to W - 1 do
    begin
      // erst ab etwa -68 dB sichtbar, oben kraeftig: Pegel 0..1 (-90..0 dB) -> 0..1
      V := (FOut[X] - 0.25) * 1.45;
      if V <= 0 then
        FGlow[X] := 0
      else
      begin
        V := V * V;
        if V > 1 then V := 1;
        if Length(L) = W then
          T := EnsureRange((FOut[X] - L[X]) * 90 / 12, -1, 1)
        else
          T := 0;
        if T >= 0 then
          FGlow[X] := Color32(Round(V * (60 + 140 * T)), Round(V * 110 * (1 - 0.6 * T)),
            Round(V * 150 * (1 - 0.7 * T)), 0)
        else
          FGlow[X] := Color32(Round(V * 60 * (1 + 0.8 * T)), Round(V * 110 * (1 + 0.5 * T)),
            Round(V * (150 - 90 * T)), 0);
      end;
    end;
  end;
  if Any or FGlowOn then
  begin
    FGlowOn := Any;
    Invalidate;
  end
  else if StateKey <> FKey then
    Invalidate;
end;

procedure TEqView.BuildGrid(W, H: Integer);
const
  FREQS: array[0..9] of Double = (20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000);
  LABELS: array[0..9] of string = ('20', '50', '100', '200', '500', '1k', '2k', '5k', '10k', '20k');
var
  I, X, Y, D: Integer;
begin
  if FGrid = nil then
  begin
    FGrid := TBitmap32.Create;
    FGrid.DrawMode := dmOpaque;
  end;
  FGrid.SetSize(W, H);
  FGrid.BeginUpdate;
  try
    FGrid.Clear(COL_BG);
    FGrid.Font.Name := 'TahomaTr(';
    FGrid.Font.Size := UiPt(7);
    FGrid.Font.Color := $808080;
    D := -18;
    while D <= 18 do
    begin
      Y := Round(DbToY(D));
      if D = 0 then FGrid.HorzLineS(0, Y, W - 1, COL_ZERO) else FGrid.HorzLineS(0, Y, W - 1, COL_LINE);
      if D > 0 then FGrid.Textout(3, Y - 12, '+' + IntToStr(D) + ') dB')
      else if D < 0 then FGrid.Textout(3, Y - 12, IntToStr(D) + Tr(' dB'));
      Inc(D, 6);
    end;
    for I := 0 to High(FREQS) do
    begin
      X := Round(Ln(FREQS[I] / EQ_F_MIN) / Ln(EQ_F_MAX / EQ_F_MIN) * (W - 1));
      FGrid.VertLineS(X, 0, H - PAD_B, COL_LINE);
      FGrid.Textout(Min(X + 2, W - 22), H - PAD_B + 2, LABELS[I]);
    end;
  finally
    FGrid.EndUpdate;
  end;
end;

procedure TEqView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, X, Y0: Integer;
  Curve: PEqCurve;
  Bass, Treble: Single;
  Prev, Yv, Yd, PrevD: Single;
  On: Boolean;
begin
  Buffer.BeginUpdate;
  try
    B := Buffer;
    W := B.Width;
    H := B.Height;
    if (W < 40) or (H < 40) then
    begin
      B.Clear(COL_BG);
      FKey := '';
    end
    else
    begin
      if (FGrid = nil) or (FGrid.Width <> W) or (FGrid.Height <> H) then
        BuildGrid(W, H);
      if FGlowOn and (Length(FGlow) = W) then
      begin
        // Raster mit Aufhellung je Spalte uebernehmen (Beschriftungszeile unten unveraendert)
        for X := 0 to H - 1 do
          if X < H - PAD_B then
            AddRowSat(PColor32(B.ScanLine[X]), PColor32(FGrid.ScanLine[X]), @FGlow[0], W)
          else
            Move(FGrid.ScanLine[X]^, B.ScanLine[X]^, W * SizeOf(TColor32));
      end
      else
        FGrid.DrawTo(B, 0, 0);
      Curve := FEngine.EqCurve;
      Bass := ParamToPlain(gpEqBass, FEngine.GetParam(Ord(gpEqBass)));
      Treble := ParamToPlain(gpEqTreble, FEngine.GetParam(Ord(gpEqTreble)));
      On := FEngine.GetParam(Ord(gpEqOn)) >= 0.5;
      // Frequenzgang nur bei Aenderung neu (je Spalte ein Wert)
      if (FKey <> StateKey) or (Length(FResp) <> W) then
      begin
        SetLength(FResp, W);
        for X := 0 to W - 1 do
          FResp[X] := EqResponseDb(Curve^, Bass, Treble, XToF(X), Max(FEngine.SampleRate, 22050),
            [ParamToPlain(gpEqAFreq, FEngine.GetParam(Ord(gpEqAFreq))), ParamToPlain(gpEqAGain, FEngine.GetParam(Ord(gpEqAGain))),
             ParamToPlain(gpEqBFreq, FEngine.GetParam(Ord(gpEqBFreq))), ParamToPlain(gpEqBGain, FEngine.GetParam(Ord(gpEqBGain)))]);
        FKey := StateKey;
      end;
      Y0 := Round(DbToY(0));
      PrevD := DbToY(EqCurveAt(Curve^, XToF(0)));
      Prev := DbToY(FResp[0]);
      for X := 0 to W - 1 do
      begin
        // gezeichnete Kurve (duenn)
        Yd := DbToY(EqCurveAt(Curve^, XToF(X)));
        AASpan(B, X, PrevD, Yd, COL_DRAWN);
        PrevD := Yd;
        // tatsaechlicher Frequenzgang mit Flaeche zur 0-dB-Linie
        Yv := DbToY(FResp[X]);
        if On then
        begin
          if Yv < Y0 - 1 then B.VertLineTS(X, Round(Yv), Y0 - 1, COL_FILL_UP)
          else if Yv > Y0 + 1 then B.VertLineTS(X, Y0 + 1, Round(Yv), COL_FILL_DN);
          AASpan(B, X, Prev, Yv, COL_RESP);
        end
        else
          AASpan(B, X, Prev, Yv, $FF505860);
        Prev := Yv;
      end;
      if not On then
      begin
        B.Font.Name := 'Tahoma';
        B.Font.Size := UiPt(8);
        B.Font.Color := $0060B0FF;
        B.Textout(W div 2 - 60, 6, Tr('EQ ist aus ("EQ an" anhaken)'));
      end;
    end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

procedure TEqView.EditAt(X, Y: Integer; First: Boolean);
var
  Curve: PEqCurve;
  Idx, I, A, Bi: Integer;
  V: Single;
  H: Integer;
  T: Double;
begin
  Curve := FEngine.EqCurve;
  H := Height - PAD_B;
  if FErase then
    V := 0
  else
    V := EnsureRange((H / 2 - Y) / (H / 2 - 6) * EQ_MAX_DB, -EQ_MAX_DB, EQ_MAX_DB);
  Idx := EnsureRange(Round(X / Max(1, Width - 1) * (EQ_CURVE_N - 1)), 0, EQ_CURVE_N - 1);
  if First or (FLastIdx < 0) then
    Curve[Idx] := V
  else
  begin
    A := Min(FLastIdx, Idx);
    Bi := Max(FLastIdx, Idx);
    for I := A to Bi do
    begin
      if Bi = A then T := 1 else T := (I - FLastIdx) / (Idx - FLastIdx);
      Curve[I] := FLastVal + (V - FLastVal) * T;
    end;
  end;
  FLastIdx := Idx;
  FLastVal := V;
  FEngine.EqChanged;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TEqView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
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

procedure TEqView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDrawing then
    EditAt(EnsureRange(X, 0, Width - 1), EnsureRange(Y, 0, Height - 1), False);
end;

procedure TEqView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDrawing := False;
  FErase := False;
  MouseCapture := False;
end;

end.
