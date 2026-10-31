{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.ModViews;

{ Kleine Anzeigen fuer Huellkurve, LFOs und Sidechain-Pegel (Graphics32).
  Lesen ihren Zustand direkt aus der Engine (lockfreie Momentaufnahmen);
  der Editor-Timer ruft nur ForceFullInvalidate auf. }

interface

uses
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, Vcl.Controls, Vcl.Graphics,
  GR32, GR32_Image,
  Granular.Params, Granular.Engine, Granular.Keyboard, Granular.GfxAsm, Granular.Prof;

type
  { schmale Pegelanzeige fuer das Mischpult (senkrecht, -48 .. +3 dB): gruen, ab -6 dB gelb, ab 0 dB rot;
    Spitze faellt weich ab, kurze Haltelinie }
  TMixMeter = class(TGraphicControl)
  private
    FLevel, FHold: Single;     // dB-Skala 0..1
    FHoldAge: Integer;
    FShownPx, FShownHold: Integer;
    FBuf: Vcl.Graphics.TBitmap;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Spitze (linear) seit der letzten Abfrage; nur bei sichtbarer Aenderung neu zeichnen }
    procedure Feed(Peak: Single);
  end;

  TEngineView = class(TCustomPaintBox32)
  protected
    FEngine: TGranularEngine;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
  end;

  TEnvKind = (ekAmp, ekFilter, ekOsc, ekOscFm);

  { ADSR-Kurve; roter Strich + Punkt = aktueller Stand der juengsten Stimme }
  TEnvelopeView = class(TEngineView)
  private
    FKind: TEnvKind;
    FOscIndex: Integer;
    FCurve: TBitmap32;       // Kurve + Fuellung + Beschriftung, nur bei Regler-Aenderung neu
    FCurveKey: Double;
    FTA, FTD, FTR, FAttMs, FSus, FScale: Double;
    FXA, FXD, FXS, FXR, FTop, FBot: Integer;
    procedure BuildCurve(W, H: Integer);
    procedure GetIds(out IdA, IdD, IdS, IdR: TGranularParamId);
    function GetFilterEnv: Boolean;
    procedure SetFilterEnv(Value: Boolean);
  public
    destructor Destroy; override;
  private
  protected
    procedure DoPaintBuffer; override;
  public
    { True = Filter-Huellkurve (F-Attack...), sonst Amplituden-Huellkurve }
    property FilterEnv: Boolean read GetFilterEnv write SetFilterEnv;
    property Kind: TEnvKind read FKind write FKind;
    property OscIndex: Integer read FOscIndex write FOscIndex;   // ekOsc/ekOscFm: Oszillator 0..2
  end;

  { Eine LFO-Periode; roter Punkt = aktuelle Phase }
  TLfoView = class(TEngineView)
  private
    FLfo: Integer;
    FPhaseRate: Double;      // Perioden je Sekunde (aus der wirksamen Rate)
  protected
    procedure DoPaintBuffer; override;
  public
    property Lfo: Integer read FLfo write FLfo;
  end;

  { Sidechain-/Ausgangsmonitor: Oszilloskop (Ausgang gruen, Sidechain orange,
    so verstaerkt wie der Huellkurvenfolger ihn sieht) + Pegelbalken IN und SC }
  TMonitorView = class(TEngineView)
  private
    FOut, FIn: array of Single;
    FStatic: TBitmap32;      // Hintergrund + Beschriftungen, nur bei Aenderung neu (kein GDI-Text je Bild)
    FLastText: string;
    FTextTick: Cardinal;     // Tonhoehentext hoechstens ~5x je Sekunde erneuern
  public
    destructor Destroy; override;
  private
  protected
    procedure DoPaintBuffer; override;
  end;

  { leuchtende Anzeige je Matrix-Slot: pulsiert mit dem aktuellen Wert seiner Quelle }
  { CLIP-Leuchte: leuchtet rot, sobald der weiche Clipper eingreift, klingt in ~1 s aus.
    Zeichnet nur bei sichtbarer Helligkeitsaenderung. }
  TClipLed = class(TEngineView)
  private
    FGlow: Single;
    FShown: Integer;
    FLastTick: Cardinal;
    FMidi: Boolean;
  protected
    procedure DoPaintBuffer; override;
  public
    procedure UpdateClip;
    { True = MIDI-Leuchte (gelb), sonst CLIP (rot) }
    property Midi: Boolean read FMidi write FMidi;
  end;

  TSlotLed = class(TEngineView)
  private
    FSlot: Integer;
    FShown: Integer;     // zuletzt gezeichnete Helligkeit (0..255) -> nur bei Aenderung neu zeichnen
  protected
    procedure DoPaintBuffer; override;
  public
    property Slot: Integer read FSlot write FSlot;
    { liefert True, wenn sich die Anzeige geaendert hat (dann wurde neu gezeichnet) }
    function UpdateGlow: Boolean;
  end;

  { Pegelbalken der Sidechain-Huellkurve }
  TLevelView = class(TEngineView)
  private
    FShownPct: Integer;
    FShownActive: Boolean;
    FShownThr: Integer;
    FOutput: Boolean;        // True: eigener Ausgangspegel mit Marke der Ausgangs-Schwelle
    function Level: Double;
  protected
    procedure DoPaintBuffer; override;
  public
    { neu zeichnen nur, wenn sich der angezeigte Prozentwert oder der Zustand aendert }
    procedure UpdateLevel;
    property Output: Boolean read FOutput write FOutput;
  end;

implementation

{ TMixMeter }

constructor TMixMeter.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];    // deckend: Windows loescht den Hintergrund nicht vorher (kein Flackern)
  FBuf := Vcl.Graphics.TBitmap.Create;
end;

destructor TMixMeter.Destroy;
begin
  FBuf.Free;
  inherited;
end;

procedure TMixMeter.Feed(Peak: Single);
const
  DB_MIN = -48; DB_MAX = 3;
var
  V: Single;
  Px, HPx: Integer;
begin
  if Peak > 1E-5 then
    V := EnsureRange((20 * Log10(Peak) - DB_MIN) / (DB_MAX - DB_MIN), 0, 1)
  else
    V := 0;
  if V >= FLevel then
    FLevel := V
  else
    FLevel := Max(V, FLevel - 0.008);          // faellt weich (~0,4 dB je Takt, etwa 25 dB/s)
  if FLevel >= FHold then
  begin
    FHold := FLevel;
    FHoldAge := 0;
  end
  else
  begin
    Inc(FHoldAge);
    if FHoldAge > 40 then
      FHold := Max(FLevel, FHold - 0.02);
  end;
  Px := Round(FLevel * (Height - 2));
  HPx := Round(FHold * (Height - 2));
  if (Px <> FShownPx) or (HPx <> FShownHold) then
  begin
    FShownPx := Px;
    FShownHold := HPx;
    Invalidate;
  end;
end;

procedure TMixMeter.Paint;
const
  DB_MIN = -48; DB_MAX = 3;
var
  Y0, YYel, YRed, Top, H: Integer;
  C: TCanvas;
begin
  if (FBuf.Width <> Width) or (FBuf.Height <> Height) then
    FBuf.SetSize(Width, Height);
  C := FBuf.Canvas;
  H := Height - 2;
  C.Brush.Color := $00201A16;
  C.FillRect(Rect(0, 0, Width, Height));
  YYel := 1 + H - Round((-6 - DB_MIN) / (DB_MAX - DB_MIN) * H);   // Bildschirmzeile fuer -6 dB
  YRed := 1 + H - Round((0 - DB_MIN) / (DB_MAX - DB_MIN) * H);    // 0 dB
  Y0 := 1 + H;
  Top := Y0 - FShownPx;
  if FShownPx > 0 then
  begin
    C.Brush.Color := $0040C850;                                // gruen
    C.FillRect(Rect(1, Max(Top, YYel), Width - 1, Y0));
    if Top < YYel then
    begin
      C.Brush.Color := $0030D8E8;                              // gelb
      C.FillRect(Rect(1, Max(Top, YRed), Width - 1, YYel));
    end;
    if Top < YRed then
    begin
      C.Brush.Color := $003040F0;                              // rot
      C.FillRect(Rect(1, Top, Width - 1, YRed));
    end;
  end;
  // 0-dB-Marke und Haltelinie
  C.Brush.Color := $00606060;
  C.FillRect(Rect(0, YRed, Width, YRed + 1));
  if FShownHold > 0 then
  begin
    C.Brush.Color := $00A0F0B0;
    C.FillRect(Rect(1, Y0 - FShownHold, Width - 1, Y0 - FShownHold + 1));
  end;
  Canvas.Draw(0, 0, FBuf);
end;

const
  COL_BG    = $FF16181C;
  COL_GRID  = $FF32363C;
  COL_CURVE = $FF78C88C;
  COL_FILL  = $3078C88C;
  COL_MARK  = $FFFF5A5A;
  COL_TEXT  = $C8C8C8;

constructor TEngineView.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  BufferOversize := 0;   // Puffer = Controlgroesse (Standard waere +40 px)
  FEngine := AEngine;
end;

{ TEnvelopeView }

destructor TEnvelopeView.Destroy;
begin
  FCurve.Free;
  inherited;
end;


procedure TEnvelopeView.GetIds(out IdA, IdD, IdS, IdR: TGranularParamId);
begin
  case FKind of
    ekFilter: begin IdA := gpFltAttack; IdD := gpFltDecay; IdS := gpFltSustain; IdR := gpFltRelease; end;
    ekOsc:    with OSC_P[FOscIndex] do begin IdA := Attack; IdD := Decay; IdS := Sustain; IdR := Release; end;
    ekOscFm:  with OSC_P[FOscIndex] do begin IdA := FmAttack; IdD := FmDecay; IdS := FmSustain; IdR := FmRelease; end;
  else
    IdA := gpAttack; IdD := gpDecay; IdS := gpSustain; IdR := gpRelease;
  end;
end;

function TEnvelopeView.GetFilterEnv: Boolean;
begin
  Result := FKind = ekFilter;
end;

procedure TEnvelopeView.SetFilterEnv(Value: Boolean);
begin
  if Value then FKind := ekFilter else FKind := ekAmp;
end;

procedure TEnvelopeView.BuildCurve(W, H: Integer);
const
  SUSTAIN_SHARE = 0.18;   // Breite des Sustain-Plateaus (zeitlos)
var
  YF, YFPrev: Single;
  B: TBitmap32;
  Top, Bot, X, Y, XPrev, YPrev: Integer;
  Lvl: Double;
  IdA, IdD, IdS, IdR: TGranularParamId;

  function LvlToY(L: Double): Integer;
  begin
    Result := Bot - Round(L * (Bot - Top));
  end;

begin
  B := FCurve;
  B.SetSize(W, H);
  B.Clear(COL_BG);
  Top := 6;
  Bot := H - 6;
  GetIds(IdA, IdD, IdS, IdR);
  // logarithmisch gestauchte Zeitachse, damit kurze und lange Zeiten lesbar bleiben
  FTA := Ln(1 + ParamToPlain(IdA, FEngine.EffParam[Ord(IdA)]));
  FTD := Ln(1 + ParamToPlain(IdD, FEngine.EffParam[Ord(IdD)]));
  FTR := Ln(1 + ParamToPlain(IdR, FEngine.EffParam[Ord(IdR)]));
  FAttMs := ParamToPlain(IdA, FEngine.EffParam[Ord(IdA)]);
  FSus := ParamToPlain(IdS, FEngine.EffParam[Ord(IdS)]) / 100;
  FScale := (W - 8) * (1 - SUSTAIN_SHARE) / Max(FTA + FTD + FTR, 0.001);
  FXA := 4 + Round(FTA * FScale);
  FXD := FXA + Round(FTD * FScale);
  FXS := FXD + Round((W - 8) * SUSTAIN_SHARE);
  FXR := W - 4;
  FTop := Top;
  FBot := Bot;

  B.HorzLineS(0, Bot, W - 1, COL_GRID);
  B.HorzLineS(0, Top, W - 1, COL_GRID);
  B.VertLineS(FXA, Top, Bot, COL_GRID);
  B.VertLineS(FXD, Top, Bot, COL_GRID);
  B.VertLineS(FXS, Top, Bot, COL_GRID);
  YFPrev := Bot;
  XPrev := 4;
  YPrev := Bot;
  for X := 5 to FXR do
  begin
    if X <= FXA then
      Lvl := (X - 4) / Max(1, FXA - 4)
    else if X <= FXD then
      Lvl := FSus + (1 - FSus) * Power(0.001, (X - FXA) / Max(1, FXD - FXA))
    else if X <= FXS then
      Lvl := FSus
    else
      Lvl := FSus * Power(0.0001, (X - FXS) / Max(1, FXR - FXS));
    Y := LvlToY(Lvl);
    YF := Bot - Lvl * (Bot - Top);
    B.VertLineTS(X, Y, Bot, COL_FILL);
    AASpan(B, X, YFPrev, YF, COL_CURVE);   // geglaettete Kontur
    XPrev := X;
    YPrev := Y;
    YFPrev := YF;
  end;
  B.Font.Name := 'Tahoma';
  B.Font.Size := 7;
  B.Font.Color := COL_TEXT;
  B.Textout(Max(4, FXA div 2 - 3), Bot - 13, 'A');
  B.Textout((FXA + FXD) div 2 - 3, Bot - 13, 'D');
  B.Textout((FXD + FXS) div 2 - 3, Bot - 13, 'S');
  B.Textout((FXS + FXR) div 2 - 3, Bot - 13, 'R');
end;

procedure TEnvelopeView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, I, Y: Integer;
  T, MX, Key: Double;
  St: TEnvelopeState;
  IdA, IdD, IdS, IdR: TGranularParamId;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  if (W < 20) or (H < 20) then
  begin
    B.Clear(COL_BG);
    inherited;
    Exit;
  end;
  GetIds(IdA, IdD, IdS, IdR);
  // Kurve nur neu berechnen, wenn sich Groesse oder Regler geaendert haben
  Key := FEngine.EffParam[Ord(IdA)] + 3.1 * FEngine.EffParam[Ord(IdD)] +
    7.3 * FEngine.EffParam[Ord(IdS)] + 13.7 * FEngine.EffParam[Ord(IdR)];
  if FCurve = nil then
  begin
    FCurve := TBitmap32.Create;
    FCurve.DrawMode := dmOpaque;
  end;
  if (FCurve.Width <> W) or (FCurve.Height <> H) or (Key <> FCurveKey) then
  begin
    BuildCurve(W, H);
    FCurveKey := Key;
  end;
  FCurve.DrawTo(B, 0, 0);   // reine Speicherkopie

  // aktueller Stand der juengsten Stimme (roter Strich + Punkt)
  case FKind of
    ekFilter: St := FEngine.GetFilterEnvState;
    ekOsc:    St := FEngine.GetOscEnvState(False, FOscIndex);
    ekOscFm:  St := FEngine.GetOscEnvState(True, FOscIndex);
  else
    St := FEngine.GetEnvelopeState;
  end;
  if St.Active then
  begin
    T := St.StageSeconds * 1000;
    case St.Stage of
      esAttack:  MX := 4 + Min(1.0, T / Max(1.0, FAttMs)) * (FXA - 4);
      esDecay:   MX := FXA + Min(1.0, Ln(1 + T) / Max(FTD, 0.001)) * (FXD - FXA);
      esSustain: MX := (FXD + FXS) / 2;
    else
      MX := FXS + Min(1.0, Ln(1 + T) / Max(FTR, 0.001)) * (FXR - FXS);
    end;
    I := Round(MX);
    Y := FBot - Round(St.Level * (FBot - FTop));
    B.VertLineS(I, FTop, FBot, COL_MARK);
    B.FillRectS(I - 3, Y - 3, I + 4, Y + 4, COL_MARK);
  end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

{ TLfoView }

procedure TLfoView.DoPaintBuffer;
const
  TRAIL_STEPS = 80;
var
  YF, YFPrev: Single;
  B: TBitmap32;
  W, H, X, Y, XPrev, YPrev, Shape, Mid, Amp, K, A, TX, TY, Steps: Integer;
  Span, P, Hz: Double;
  RateId, SyncId: TGranularParamId;
  Hold: Single;

  Ph, V: Double;
  ShapeId: TGranularParamId;
  EIdx: Integer;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  B.Clear(COL_BG);
  if (W < 10) or (H < 10) then
  begin
    inherited;
    Exit;
  end;
  // Lfo = 0..LFO_COUNT-1: LFO 1..8; Lfo = LFO_COUNT: Morph-LFO
  if FLfo >= LFO_COUNT then
  begin
    ShapeId := gpMorphLfoShape;
    EIdx := 2;                         // Engine-Index fuer Phase/Wert/freie Form (2 = Morph-LFO)
  end
  else
  begin
    ShapeId := LFO_SHAPE_IDS[FLfo];
    EIdx := LFO_FREE_IDX[FLfo];
  end;
  Shape := Round(ParamToPlain(ShapeId, FEngine.EffParam[Ord(ShapeId)]));
  if FLfo >= LFO_COUNT then
  begin
    // Morph-LFO: Stufe 0 = Aus, danach dieselben Formen wie die LFOs (6 = Frei -> 5)
    if Shape <= 0 then
    begin
      B.HorzLineS(0, H div 2, W - 1, COL_GRID);
      B.Font.Name := 'Tahoma';
      B.Font.Size := 7;
      B.Font.Color := COL_TEXT;
      B.Textout(6, 4, 'Morph-LFO aus');
      inherited;
      Exit;
    end;
    Dec(Shape);
  end;
  Mid := H div 2;
  Amp := H div 2 - 5;
  B.HorzLineS(0, Mid, W - 1, COL_GRID);

  YFPrev := Mid;
  XPrev := 0;
  YPrev := Mid;
  for X := 0 to W - 1 do
  begin
    Ph := X / (W - 1);
    // S&H wird mit einem festen Treppenmuster angedeutet
    if Shape = LFO_SHAPE_FREE then
      V := FreeLfoValue(FEngine.FreeLfo[EIdx]^, Ph)
    else
      V := LfoShapeValue(Shape, Ph, Sin(Floor(Ph * 6) * 2.3) * 0.9);
    YF := Mid - V * Amp;
    Y := Round(YF);
    if X > 0 then
      AASpan(B, X, YFPrev, YF, COL_CURVE);
    XPrev := X;
    YPrev := Y;
    YFPrev := YF;
  end;

  X := Round(FEngine.LfoPhase[EIdx] * (W - 1));
  Y := Mid - Round(FEngine.LfoValue[EIdx] * Amp);
  // Leuchtspur als zusammenhaengendes Kurvenstueck: berechnet aus der aktuellen Phase,
  // Laenge folgt der LFO-Geschwindigkeit (~0,12 s Nachlauf) -> bei jeder Bildrate fluessig.
  Ph := FEngine.LfoPhase[EIdx];
  // Geschwindigkeit exakt aus der wirksamen LFO-Rate (bzw. Tempo und Notenwert bei Sync)
  if FLfo >= LFO_COUNT then
  begin
    RateId := gpMorphLfoRate; SyncId := gpMorphLfoSync;
  end
  else
  begin
    RateId := LFO_RATE_IDS[FLfo]; SyncId := LFO_SYNC_IDS[FLfo];
  end;
  if FEngine.EffParam[Ord(SyncId)] >= 0.5 then
    Hz := (ParamToPlain(gpTempo, FEngine.EffParam[Ord(gpTempo)]) / 60) /
      LFO_DIV_BEATS[LfoDivisionIndex(FEngine.EffParam[Ord(RateId)])]
  else
    Hz := ParamToPlain(RateId, FEngine.EffParam[Ord(RateId)]);
  FPhaseRate := Hz;
  Span := EnsureRange(FPhaseRate * 0.12, 0.03, 0.45);
  Hold := FEngine.LfoValue[EIdx];
  // je Pixel Spurlaenge ein weicher Punkt (2x2), vom Schweifende (blass) zur Spitze (kraeftig)
  Steps := EnsureRange(Round(Span * W), 4, TRAIL_STEPS);
  for K := 0 to Steps do
  begin
    P := Ph - Span * (1 - K / Steps);
    if P < 0 then P := P + 1;
    if Shape = 4 then V := Hold
    else if Shape = LFO_SHAPE_FREE then V := FreeLfoValue(FEngine.FreeLfo[EIdx]^, P)
    else V := LfoShapeValue(Shape, P, Hold);
    TX := Round(P * (W - 1));
    TY := Mid - Round(V * Amp);
    A := 30 + K * 200 div Steps;
    B.FillRectTS(TX - 1, TY - 1, TX + 1, TY + 1, Color32(255, 90, 90, A));
  end;
  B.VertLineTS(X, 0, H - 1, $60FF5A5A);
  B.FillRectS(X - 3, Y - 3, X + 4, Y + 4, COL_MARK);
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

{ TMonitorView }

destructor TMonitorView.Destroy;
begin
  FStatic.Free;
  inherited;
end;


procedure TMonitorView.DoPaintBuffer;
const
  METER_W = 22;
  COL_IN = $FFFFA040;
var
  B: TBitmap32;
  W, H, SW, Mid, Amp, X, I, N, YO, YI, PrevO, PrevI: Integer;
  Gain, V, Db: Double;
  PitchText: string;
  YOF, YIF, PrevOF, PrevIF: Single;

  procedure Meter(XL: Integer; Level: Double; Col: TColor32);
  var
    Y: Integer;
  begin
    Y := (H - 16) - Round(EnsureRange(Level, 0, 1) * (H - 20));
    if Y < H - 16 then
      B.FillRectS(XL, Y, XL + METER_W - 4, H - 16, Col);
  end;

  // senkrechte Spanne zwischen zwei aufeinanderfolgenden Punkten: eine Fuelloperation je Spalte
  procedure Span(XX, Y0, Y1: Integer; Col: TColor32);
  begin
    if Y0 > Y1 then
      B.VertLineS(XX, Y1, Y0, Col)
    else
      B.VertLineS(XX, Y0, Y1, Col);
  end;

begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  if (W < 80) or (H < 30) then
  begin
    B.Clear(COL_BG);
    inherited;
    Exit;
  end;
  SW := W - 2 * METER_W - 8;          // Breite des Oszilloskops
  Mid := H div 2;
  Amp := H div 2 - 4;

  // Tonhoehen-/Statustext: nur wenn er sich aendert, wird die statische Ebene neu gebaut
  if FEngine.SidechainActive then
  begin
    if FEngine.PitchTracker.Valid then
      PitchText := Format('Tonhöhe: %s  (%.0f Hz)', [NoteName(Round(FEngine.PitchTracker.Note)), FEngine.PitchTracker.Hz])
    else
      PitchText := 'Tonhöhe: -';
  end
  else
    PitchText := '(kein Sidechain-Eingang aktiv - Quelle unten in der Host-Leiste wählen)';

  // statische Ebene: Hintergrund, Mittellinie, Beschriftungen, Messgeraete-Rahmen.
  // Der Tonhoehentext aendert sich laufend -> nur alle 200 ms in die Ebene uebernehmen
  if (PitchText <> FLastText) and (GetTickCount - FTextTick < 200) and (FStatic <> nil) and
     (FStatic.Width = W) and (FStatic.Height = H) then
    PitchText := FLastText;
  if (FStatic = nil) or (FStatic.Width <> W) or (FStatic.Height <> H) or (PitchText <> FLastText) then
  begin
    FTextTick := GetTickCount;
    if FStatic = nil then
    begin
      FStatic := TBitmap32.Create;
      FStatic.DrawMode := dmOpaque;
    end;
    FStatic.SetSize(W, H);
    FStatic.Clear(COL_BG);
    FStatic.HorzLineS(0, Mid, SW, COL_GRID);
    FStatic.Font.Name := 'Tahoma';
    FStatic.Font.Size := 7;
    FStatic.Font.Color := COL_TEXT;
    FStatic.Textout(4, 2, 'Ausgang');
    FStatic.Font.Color := $40A0FF;
    FStatic.Textout(56, 2, 'Sidechain');
    FStatic.Font.Color := COL_TEXT;
    FStatic.Textout(120, 2, PitchText);
    for I := 0 to 1 do
    begin
      X := SW + 8 + I * METER_W;
      FStatic.FillRectS(X, 4, X + METER_W - 4, H - 16, $FF0E0F12);
      if I = 0 then FStatic.Textout(X + 2, H - 14, 'IN') else FStatic.Textout(X + 2, H - 14, 'SC');
    end;
    FLastText := PitchText;
  end;
  FStatic.DrawTo(B, 0, 0);            // reine Speicherkopie

  // Kurven: je Pixelspalte eine senkrechte Spanne (statt ~1900 einzelner Linien)
  N := SW;
  if Length(FOut) < N then
  begin
    SetLength(FOut, N);
    SetLength(FIn, N);
  end;
  FEngine.GetScope(FOut, FIn, N);
  Gain := Power(10, ParamToPlain(gpScGain, FEngine.EffParam[Ord(gpScGain)]) / 20);
  // kantengeglaettet: Spanne je Spalte mit weichen Enden (AASpan)
  PrevOF := Mid; PrevIF := Mid;
  for I := 0 to N - 1 do
  begin
    YIF := Mid - EnsureRange(FIn[I] * Gain, -1, 1) * Amp;
    YOF := Mid - EnsureRange(FOut[I], -1, 1) * Amp;
    if I > 0 then
    begin
      AASpan(B, I, PrevIF, YIF, COL_IN);
      AASpan(B, I, PrevOF, YOF, COL_CURVE);
    end;
    PrevOF := YOF; PrevIF := YIF;
  end;

  // Pegel: IN in dB (-60..0), SC = Huellkurvenfolger (0..1)
  V := FEngine.InputPeak;
  if V > 0.000001 then Db := 20 * Log10(V) else Db := -100;
  Meter(SW + 8, (Db + 60) / 60, IfThen(Db > -1, Integer(COL_MARK), Integer(COL_IN)));
  Meter(SW + 8 + METER_W, FEngine.SourceValue[msSidechain], COL_CURVE);
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

{ TClipLed }

procedure TClipLed.UpdateClip;
var
  V: Integer;
  Now: Cardinal;
  Dt: Single;
begin
  // echte vergangene Zeit -> gleiches Ausklingen bei jeder Timer-Rate
  Now := GetTickCount;
  if FLastTick = 0 then FLastTick := Now;
  Dt := Min(0.5, (Now - FLastTick) / 1000);
  FLastTick := Now;
  if (FMidi and (FEngine.TakeMidiCount > 0)) or (not FMidi and (FEngine.TakeClipCount > 0)) then
    FGlow := 1
  else
    if FMidi then FGlow := Max(0, FGlow - Dt * 4) else FGlow := Max(0, FGlow - Dt * 1.2);
  V := Round(FGlow * 20);
  if V <> FShown then
    Invalidate;
end;

procedure TClipLed.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, A: Integer;
begin
  Buffer.BeginUpdate;
  try
    B := Buffer;
    W := B.Width;
    H := B.Height;
    FShown := Round(FGlow * 20);
    B.Clear($FF1A1C20);
    A := Round(FGlow * 255);
    // Lichthof + Kern, Farbe von dunkelrot (aus) nach hellrot (Eingriff)
    if FMidi then
    begin
      B.FillRectS(1, 1, W - 1, H - 1, Color32(55 + A * 200 div 255, 50 + A * 165 div 255, 20 + A * 20 div 255));
      if A > 0 then
        B.FillRectTS(0, 0, W, H, Color32(255, 230, 120, A div 3));
    end
    else
    begin
      B.FillRectS(1, 1, W - 1, H - 1, Color32(60 + A * 195 div 255, 20 + A * 40 div 255, 20 + A * 30 div 255));
      if A > 0 then
        B.FillRectTS(0, 0, W, H, Color32(255, 120, 100, A div 3));
    end;
    B.Font.Name := 'Tahoma';
    B.Font.Size := 7;
    B.Font.Style := [];
    if FMidi and (A > 120) then B.Font.Color := $00202020
    else if A > 120 then B.Font.Color := $00FFFFFF
    else B.Font.Color := $00A0A0C0;
    if FMidi then
      B.Textout((W - B.TextWidth('MIDI')) div 2, (H - B.TextHeight('MIDI')) div 2, 'MIDI')
    else
      B.Textout((W - B.TextWidth('CLIP')) div 2, (H - B.TextHeight('CLIP')) div 2, 'CLIP');
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

{ TSlotLed }

function SlotLedColor(Src: TModSource): TColor32;
begin
  case Src of
    msLfo1: Result := $FF50D2FF;                       // Cyan
    msLfo2: Result := $FFB48CFF;                       // Violett
    msSidechain, msScPitch: Result := $FFFFA040;       // Orange wie im Monitor
    msVelocity, msNote, msNoteRandom: Result := $FF78E08C;
    msFilterEnv, msAmpEnv, msOsc1Env, msOsc2Env, msOsc3Env: Result := $FFFFD25A;   // Gelb
  else
    Result := $FFDCDCDC;                               // Modrad, Aftertouch, Pitchbend
  end;
end;

function TSlotLed.UpdateGlow: Boolean;
var
  Src: Integer;
  V: Single;
  L: Integer;
begin
  Src := ParamStep(SlotSourceIndex(FSlot), FEngine.GetParam(SlotSourceIndex(FSlot)));
  if Src <= 0 then
    L := 0
  else
  begin
    V := Abs(FEngine.SourceValue[TModSource(Src)]);
    L := 40 + Round(EnsureRange(V, 0, 1) * 215);      // aktive Quelle glimmt mindestens leicht
  end;
  Result := Abs(L - FShown) > 6;
  if Result then
  begin
    FShown := L;
    ForceFullInvalidate;
  end;
end;

procedure TSlotLed.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, CX, CY, R, I, A, Src: Integer;
  C: TColor32;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;

  B.Clear(Color32(48, 50, 56));   // Panel-Hintergrund
  CX := W div 2;
  CY := H div 2;
  Src := ParamStep(SlotSourceIndex(FSlot), FEngine.GetParam(SlotSourceIndex(FSlot)));
  if Src > 0 then
    C := SlotLedColor(TModSource(Src)) and $00FFFFFF
  else
    C := $00505050;
  // weicher Lichthof: konzentrische Quadrate mit abnehmender Deckkraft, darueber der Kern
  R := Min(W, H) div 2;
  for I := R downto 1 do
  begin
    A := FShown * (R - I + 1) div (R * 3);
    B.FillRectTS(CX - I, CY - I, CX + I, CY + I, TColor32(EnsureRange(A, 0, 255)) shl 24 or C);
  end;
  B.FillRectTS(CX - 2, CY - 2, CX + 2, CY + 2, TColor32(EnsureRange(FShown, 30, 255)) shl 24 or C);
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

{ TLevelView }

function TLevelView.Level: Double;
begin
  if FOutput then
    Result := EnsureRange(FEngine.OutputPeak, 0, 1)
  else
    Result := FEngine.SourceValue[msSidechain];
end;

procedure TLevelView.UpdateLevel;
var
  Pct, Thr: Integer;
begin
  Pct := Round(Level * 100);
  Thr := Round(ParamToPlain(gpOutTrigLevel, FEngine.GetParam(Ord(gpOutTrigLevel))));
  if (Pct <> FShownPct) or (FEngine.SidechainActive <> FShownActive) or (FOutput and (Thr <> FShownThr)) then
  begin
    FShownPct := Pct;
    FShownThr := Thr;
    FShownActive := FEngine.SidechainActive;
    ForceFullInvalidate;
  end;
end;

procedure TLevelView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, X, X2: Integer;
  L: Double;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  B.Clear(COL_BG);
  L := Level;
  X := Round(L * (W - 2));
  if FOutput then
  begin
    // Ausgang: Balken orange, sobald er die Schwelle erreicht; weisse Marke = Schwelle
    X2 := 1 + Round(ParamToPlain(gpOutTrigLevel, FEngine.GetParam(Ord(gpOutTrigLevel))) / 100 * (W - 2));
    if X > 0 then
      B.FillRectS(1, 1, 1 + X, H - 1, IfThen(1 + X >= X2, Integer($FFFFA040), Integer(COL_CURVE)));
    B.VertLineS(X2, 0, H - 1, $FFFFFFFF);
    B.Font.Name := 'Tahoma';
    B.Font.Size := 7;
    B.Font.Color := COL_TEXT;
    B.Textout(4, (H - 12) div 2, Format('Ausgang %.0f %%', [L * 100]));
  end
  else
  begin
  if X > 0 then
    B.FillRectS(1, 1, 1 + X, H - 1, IfThen(L > 0.95, Integer(COL_MARK), Integer(COL_CURVE)));
  B.Font.Name := 'Tahoma';
  B.Font.Size := 7;
  B.Font.Color := COL_TEXT;
  if FEngine.SidechainActive then
    B.Textout(4, (H - 12) div 2, Format('Sidechain %.0f %%', [L * 100]))
  else
    B.Textout(4, (H - 12) div 2, 'kein Sidechain-Signal');
  end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

end.
