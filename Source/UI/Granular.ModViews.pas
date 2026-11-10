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
  Granular.Lang,
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, Vcl.Controls, Vcl.Graphics, Vcl.Forms,
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

  { Anzeigen dunkeln bei lautem Ausgang mit den Lampen ab: 0..255 Deckkraft Schwarz, gesetzt vom Editor
    (nur bei Stufenwechsel; die Anzeigen des offenen Reiters werden dann einmal neu gezeichnet) }
var
  GDisplayDim: Integer = 0;

procedure DimDisplay(B: TBitmap32);

type
  TEngineView = class(TCustomPaintBox32)
  protected
    FEngine: TGranularEngine;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
  end;

  { Echo / Hall als kleines Diagramm unter den Reglern: Echo = Wiederholungen als abklingende Balken
    (Ping-Pong abwechselnd oben/unten), Hall = Nachhallkurve (Vorverzoegerung, Abklingen, Hoehen gestrichelt).
    Sparsam: nur neu gezeichnet, wenn sich ein Regler aendert (CheckKey aus dem Editor-Timer). }
  TFxKind = (fxEcho, fxHall);
  TFxCurveView = class(TEngineView)
  private
    FKind: TFxKind;
    FKey: Double;
  protected
    procedure DoPaintBuffer; override;
  public
    property Kind: TFxKind read FKind write FKind;
    procedure CheckKey;
  end;

  TEnvKind = (ekAmp, ekFilter, ekOsc, ekOscFm, ekMod);
  { Wert aus der Grafik gezogen: der Editor setzt ihn wie einen Regler (DAW-Meldung, Regler mitziehen) }
  TEnvEditEvent = procedure(Id: TGranularParamId; Norm: Single) of object;   // ekMod: Modulations-Huellkurve OscIndex 0/1

  { ADSR-Kurve; roter Strich + Punkt = aktueller Stand der juengsten Stimme }
  TEnvelopeView = class(TEngineView)
  private
    FKind: TEnvKind;
    FOscIndex: Integer;
    FTitle: string;
    FCurve: TBitmap32;       // Kurve + Fuellung + Beschriftung, nur bei Regler-Aenderung neu
    FCurveKey: Double;
    FTA, FTD, FTR, FAttMs, FSus, FScale: Double;
    FXA, FXD, FXS, FXR, FTop, FBot: Integer;
    procedure BuildCurve(W, H: Integer);
    procedure GetIds(out IdA, IdD, IdS, IdR: TGranularParamId);
    function GetFilterEnv: Boolean;
    procedure SetFilterEnv(Value: Boolean);
  private
    // Ziehen mit der Maus: 0 = nichts, 1 = Attack, 2 = Decay/Sustain, 3 = Release
    FDragPt: Integer;
    FDragX0: Integer;
    FDragT0: Double;               // Zeit des gezogenen Punkts beim Anfassen (ms)
    FOnEdit: TEnvEditEvent;
    function HandleAt(X: Integer): Integer;
    procedure SetPlain(Id: TGranularParamId; Plain: Double);
  public
    destructor Destroy; override;
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
  public
    { True = Filter-Huellkurve (F-Attack...), sonst Amplituden-Huellkurve }
    property FilterEnv: Boolean read GetFilterEnv write SetFilterEnv;
    property Kind: TEnvKind read FKind write FKind;
    property OscIndex: Integer read FOscIndex write FOscIndex;   // ekOsc/ekOscFm: Oszillator 0..2, ekMod: Huellkurve 0..1
    property Title: string read FTitle write FTitle;             // optional oben rechts
    property OnEdit: TEnvEditEvent read FOnEdit write FOnEdit;   // gesetzt = Punkte mit der Maus ziehbar
  end;

  { Eine LFO-Periode; roter Punkt = aktuelle Phase }
  TLfoView = class(TEngineView)
  private
    FGrad: TArray<TColor32>;   // Flaechenverlauf je Zeile
    FStatic: TBitmap32;        // Hintergrund + Flaeche + Kurve, nur neu bei anderer Form/Groesse/freier Form
    FKeyW, FKeyH, FKeyShape: Integer;
    FKeySum: Double;           // Pruefsumme der freien Form (aendert sie sich, wird neu gezeichnet)
    FLfo: Integer;
    FPhaseRate: Double;      // Perioden je Sekunde (aus der wirksamen Rate)
  protected
    procedure DoPaintBuffer; override;
  public
    destructor Destroy; override;
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
    property Glow: Single read FGlow;   // 1 = Clipper/Limiter greift gerade ein, klingt aus
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

  { Limiter: wie viel dB er gerade wegnimmt - Segmentkette von rechts (0 dB) nach links (-12 dB), dazu der Wert }
  TReductionView = class(TCustomPaintBox32)
  private
    FDb: Single;
    FShown: Integer;
  protected
    procedure DoPaintBuffer; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetDb(Db: Single);
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
  COL_ENV   = $FFF0B450;   // Huellkurven: Bernstein wie Werte-Schrift und Lampen
  COL_ENV_FILL = $30F0B450;
  COL_FILL  = $3078C88C;
  COL_MARK  = $FFFF5A5A;
  COL_TEXT  = $C8C8C8;

procedure DimDisplay(B: TBitmap32);
begin
  if GDisplayDim > 0 then
    B.FillRectTS(0, 0, B.Width, B.Height, TColor32(GDisplayDim) shl 24);   // ein Blend-Durchgang (SSE)
end;

constructor TEngineView.Create(AOwner: TComponent; AEngine: TGranularEngine);
begin
  inherited Create(AOwner);
  BufferOversize := 0;   // Puffer = Controlgroesse (Standard waere +40 px)
  FEngine := AEngine;
end;

{ TFxCurveView }

procedure TFxCurveView.CheckKey;
const
  ECHO_IDS: array[0..6] of TGranularParamId = (gpEchoOn, gpEchoTime, gpEchoFeedback, gpEchoDamp, gpEchoPingPong, gpEchoMix, gpEchoSync);
  HALL_IDS: array[0..5] of TGranularParamId = (gpRevOn, gpRevSize, gpRevDecay, gpRevDamp, gpRevPreDelay, gpRevMix);
var
  K: Double;
  I: Integer;
begin
  K := 0;
  if FKind = fxEcho then
    for I := 0 to High(ECHO_IDS) do K := K + (I + 1.37) * FEngine.EffParam[Ord(ECHO_IDS[I])]
  else
    for I := 0 to High(HALL_IDS) do K := K + (I + 1.37) * FEngine.EffParam[Ord(HALL_IDS[I])];
  if K <> FKey then
  begin
    FKey := K;
    ForceFullInvalidate;   // Puffer neu zeichnen (Invalidate allein zeigt nur den alten Puffer)
  end;
end;

procedure TFxCurveView.DoPaintBuffer;

  function Plain(Id: TGranularParamId): Double;
  begin
    Result := ParamToPlain(Id, FEngine.EffParam[Ord(Id)]);
  end;

  { Balken mit Glanz: quer gewoelbt (links Lichtkante, Mitte hell, rechts Schatten), zur Spitze heller }
  procedure GlossBar(Bm: TBitmap32; X0, Y0, X1, Y1: Integer; C: TColor32; TipTop: Boolean);
  var
    XX, YY, R0, G0, B0, Rr, Gg, Bb: Integer;
    Fx, Fy, F: Double;
  begin
    if (X1 <= X0) or (Y1 <= Y0) then Exit;
    R0 := (C shr 16) and $FF; G0 := (C shr 8) and $FF; B0 := C and $FF;
    for YY := Y0 to Y1 - 1 do
    begin
      if TipTop then Fy := 1 - (YY - Y0) / Max(1, Y1 - Y0) else Fy := (YY - Y0) / Max(1, Y1 - Y0);
      for XX := X0 to X1 - 1 do
      begin
        Fx := (XX - X0 + 0.5) / (X1 - X0);                       // 0..1 quer
        F := 0.62 + 0.38 * Sin(Pi * Min(1, Fx * 1.25)) + 0.12 * Fy;  // Woelbung, Licht leicht links
        Rr := Min(255, Round(R0 * F)); Gg := Min(255, Round(G0 * F)); Bb := Min(255, Round(B0 * F));
        Bm.PixelS[XX, YY] := Color32(Rr, Gg, Bb);
      end;
    end;
    Bm.VertLineTS(X0 + Max(1, (X1 - X0) div 4), Y0 + 1, Y1 - 2, $38FFFFFF);   // Glanzstreifen
    if TipTop then Bm.HorzLineTS(X0, Y0, X1 - 1, $70FFFFFF)
    else Bm.HorzLineTS(X0, Y1 - 1, X1 - 1, $40FFFFFF);
  end;

var
  B: TBitmap32;
  W, H, X, Y, K, Mid, Base, N, BW: Integer;
  P, T, Span, Lvl, Fb, Damp, Mix, Dec, Pre, Hi, YF, YPrev, YHPrev: Double;
  On, Ping: Boolean;
  C: TColor32;
  Txt: string;
begin
  Buffer.BeginUpdate;
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
  // Hintergrund wie die anderen Anzeigen: Schimmer oben, Glanzkante
  for Y := 0 to H - 1 do
  begin
    P := 1 - Y / (H - 1);
    B.HorzLineS(0, Y, W - 1, Color32(Round(8 + 18 * P), Round(9 + 18 * P), Round(11 + 21 * P)));
  end;
  B.HorzLineTS(0, 0, W - 1, $28FFF0DC);
  B.HorzLineTS(0, 1, W - 1, $10FFF0DC);
  B.Font.Name := 'Tahoma';
  B.Font.Size := UiPt(7);
  B.Font.Color := $00909090;
  if FKind = fxEcho then
  begin
    On := FEngine.EffParam[Ord(gpEchoOn)] >= 0.5;
    T := Max(10, Plain(gpEchoTime));                 // ms (bei Sync die Zeit des Reglers als Naeherung)
    Fb := EnsureRange(Plain(gpEchoFeedback) / 100, 0, 0.98);
    Damp := EnsureRange(Plain(gpEchoDamp) / 100, 0, 1);
    Mix := EnsureRange(Plain(gpEchoMix) / 100, 0, 1);
    Ping := FEngine.EffParam[Ord(gpEchoPingPong)] >= 0.5;
    // so viele Wiederholungen, bis sie unter -40 dB fallen (hoechstens 16)
    N := 1;
    Lvl := Mix;
    while (N < 16) and (Lvl * Fb > 0.01) do
    begin
      Lvl := Lvl * Fb;
      Inc(N);
    end;
    Span := T * (N + 1);
    if Ping then Mid := H div 2 else Mid := H - 12;
    Base := Mid;
    B.HorzLineS(4, Base, W - 5, COL_GRID);
    // trockener Anschlag bei 0
    X := 8;
    BW := Max(4, Min(14, (W - 20) div (N + 2) div 2));  // Balkenbreite
    GlossBar(B, X, Base - (Mid - 8), X + BW, Base, $FF5A5652, True);   // trockener Klang (grau, voll)
    Lvl := 1;                                           // Form zeigen: erste Wiederholung = volle Hoehe
    for K := 1 to N do
    begin
      X := 8 + Round((W - 30) * (K * T) / Span);
      Y := Max(1, Round((Mid - 8) * Lvl * (0.55 + 0.45 * Mix)));
      // Daempfung: spaetere Wiederholungen dunkler (weniger Hoehen)
      P := Power(1 - 0.6 * Damp, K - 1);
      C := Color32(Round(240 * (0.45 + 0.55 * P)), Round(180 * (0.35 + 0.65 * P)), Round(80 * P));
      if not On then C := Color32(70, 66, 62);
      if Ping and not Odd(K) then
        GlossBar(B, X, Base + 1, X + BW, Base + 1 + Y, C, False)      // rechts: nach unten
      else
        GlossBar(B, X, Base - Y, X + BW, Base, C, True);              // links / mono: nach oben
      Lvl := Lvl * Fb;
    end;
    if Ping then
    begin
      B.Textout(W - 16, 3, 'L');
      B.Textout(W - 16, H - 15, 'R');
    end;
    Txt := Format(Tr('%d Wiederholungen'), [N]);
  end
  else
  begin
    On := FEngine.EffParam[Ord(gpRevOn)] >= 0.5;
    Dec := Max(0.1, Plain(gpRevDecay));               // s (-60 dB)
    Pre := Plain(gpRevPreDelay) / 1000;               // s
    Damp := EnsureRange(Plain(gpRevDamp) / 100, 0, 1);
    Mix := EnsureRange(Plain(gpRevMix) / 100, 0.05, 1);
    Span := Pre + Dec * 0.9 + 0.05;                  // Anzeige gestaucht (Wurzel): Ausklingen ueber die ganze Breite
    Base := H - 10;
    B.HorzLineS(4, Base, W - 5, COL_GRID);
    // trockener Anschlag
    GlossBar(B, 8, 6, 12, Base, $FF6E6A66, True);
    YPrev := Base;
    YHPrev := Base;
    for X := 12 to W - 6 do
    begin
      T := (X - 12) / (W - 18) * Span;                 // s
      if T < Pre then
        Lvl := 0
      else
        Lvl := Power(10, -3 * (T - Pre) / Dec);         // -60 dB bei Nachhallzeit
      // Einschwingen der ersten Reflexionen (wenige ms)
      if T >= Pre then
        Lvl := Lvl * Min(1, (T - Pre) / 0.02 + 0.2);
      YF := Base - (Base - 8) * Sqrt(Lvl) * (0.7 + 0.3 * Mix);
      if On then C := COL_ENV else C := $FF5A5652;
      for Y := Max(0, Ceil(YF)) to Base - 1 do
        B.SetPixelTS(X, Y, (C and $00FFFFFF) or (TColor32(Round(18 + 60 * (Base - Y) / Max(1, Base - 8))) shl 24));
      if On then
      begin
        B.LineXS(Fixed(X - 1), Fixed(YPrev - 1.5), Fixed(X), Fixed(YF - 1.5), $30FFC060);   // Lichthof
        B.LineXS(Fixed(X - 1), Fixed(YPrev - 0.7), Fixed(X), Fixed(YF - 0.7), $50FFE8B0);   // Glanz
      end;
      B.LineXS(Fixed(X - 1), Fixed(YPrev), Fixed(X), Fixed(YF), C);
      YPrev := YF;
      // Hoehen klingen mit Daempfung schneller ab (gestrichelte, hellere Linie)
      if T >= Pre then
        Hi := Power(10, -3 * (T - Pre) / Max(0.05, Dec * (1 - 0.8 * Damp))) * Min(1, (T - Pre) / 0.02 + 0.2)
      else
        Hi := 0;
      YF := Base - (Base - 8) * Sqrt(Hi) * (0.7 + 0.3 * Mix);
      if On and (X mod 4 < 2) then
        B.LineXS(Fixed(X - 1), Fixed(YHPrev), Fixed(X), Fixed(YF), $C8FFF0C8);
      YHPrev := YF;
    end;
    Txt := Format(Tr('Nachhall %.1f s'), [Dec]);
  end;
  // Glasglanz: oberes Drittel ein Hauch heller, nach unten auslaufend
  for Y := 2 to H div 3 do
    B.HorzLineTS(1, Y, W - 2, TColor32(Round(16 * (1 - Y / (H / 3)))) shl 24 or $00FFF0DC);
  if not On then Txt := Tr('aus');
  B.Font.Color := $00B0B0B0;
  B.Textout(W - B.TextWidth(Txt) - 26, 4, Txt);
  finally
    Buffer.EndUpdate;
  end;
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
  inherited;
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
    ekMod:    begin IdA := MENV_IDS[FOscIndex, 0]; IdD := MENV_IDS[FOscIndex, 1]; IdS := MENV_IDS[FOscIndex, 2];
                IdR := MENV_IDS[FOscIndex, 3]; end;
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
  Top, Bot, X, Y, XPrev, YPrev, YY: Integer;
  Lvl: Double;
  IdA, IdD, IdS, IdR: TGranularParamId;
  Grad: array of TColor32;   // Flaeche je Hoehe: unten fast nichts, nach oben leicht leuchtend
  T: Single;

  function LvlToY(L: Double): Integer;
  begin
    Result := Bot - Round(L * (Bot - Top));
  end;

begin
  B := FCurve;
  B.SetSize(W, H);
  Top := 6;
  Bot := H - 6;
  // Hintergrund: unten schwarz, nach oben ein Hauch heller (Schimmer); Flaechen-Verlauf je Hoehe vorab
  SetLength(Grad, H);
  for YY := 0 to H - 1 do
  begin
    T := EnsureRange((Bot - YY) / Max(1, Bot - Top), 0, 1);   // 0 = unten, 1 = oben
    B.HorzLineS(0, YY, W - 1, Color32(Round(8 + 18 * T), Round(9 + 18 * T), Round(11 + 21 * T)));
    // Flaeche: unten dunkel, oben kraeftiger - Kontrast nimmt nach oben leicht ab, bleibt knackig
    Grad[YY] := (COL_ENV and $00FFFFFF) or (TColor32(Round(10 + 78 * T)) shl 24);
  end;
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
    // Flaeche: Oberkante anteilig (keine Treppe unter der Linie)
    for YY := Max(Ceil(YF), 0) to Min(Bot, H - 1) do
      B.SetPixelTS(X, YY, Grad[YY]);
    if (Ceil(YF) > YF) and (Ceil(YF) - 1 >= 0) then
      B.SetPixelTS(X, Ceil(YF) - 1, (Grad[Ceil(YF) - 1] and $00FFFFFF) or
        (TColor32(Round((Grad[Ceil(YF) - 1] shr 24) * (Ceil(YF) - YF))) shl 24));
    B.LineXS(Fixed(X - 1), Fixed(YFPrev), Fixed(X), Fixed(YF), COL_ENV);   // kantengeglaettete Kontur
    XPrev := X;
    YPrev := Y;
    YFPrev := YF;
  end;
  if Assigned(FOnEdit) then
  begin
    // Anfasser: Spitze (Attack), Knick (Decay waagrecht, Sustain senkrecht), Beginn des Release
    Y := LvlToY(FSus);
    B.FrameRectS(FXA - 3, Top - 3, FXA + 4, Top + 4, COL_ENV);
    B.FrameRectS(FXD - 3, Y - 3, FXD + 4, Y + 4, COL_ENV);
    B.FrameRectS(FXS - 3, Y - 3, FXS + 4, Y + 4, COL_ENV);
  end;
  B.Font.Name := 'Tahoma';
  B.Font.Size := UiPt(7);
  B.Font.Color := COL_TEXT;
  B.Textout(Max(4, FXA div 2 - 3), Bot - 13, 'A');
  B.Textout((FXA + FXD) div 2 - 3, Bot - 13, 'D');
  B.Textout((FXD + FXS) div 2 - 3, Bot - 13, 'S');
  B.Textout((FXS + FXR) div 2 - 3, Bot - 13, 'R');
  if FTitle <> '' then
  begin
    B.Font.Color := $0070D0FF;                 // bernstein: Name der Huellkurve oben rechts
    B.Textout(W - B.TextWidth(FTitle) - 5, Top + 2, FTitle);
  end;
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
    ekMod:    St := FEngine.GetModEnvState(FOscIndex);
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
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
  inherited;
end;

{ --- Ziehen mit der Maus: waagrecht = Zeit (logarithmisch, wie die Achse), senkrecht am Knick = Sustain.
  Doppelklick auf einen Punkt = Standardwert. Die Achse wird je Bild neu verteilt, deshalb wirkt das Ziehen
  relativ zum Anfassen (Faktor je Pixel) statt auf eine absolute Position. }

function TEnvelopeView.HandleAt(X: Integer): Integer;
var
  DA, DD, DS: Integer;
begin
  DA := Abs(X - FXA);
  DD := Abs(X - FXD);
  DS := Abs(X - FXS);
  if (DA <= DD) and (DA <= DS) then
    Result := 1
  else if DD <= DS then
    Result := 2
  else
    Result := 3;
end;

procedure TEnvelopeView.SetPlain(Id: TGranularParamId; Plain: Double);
var
  Info: TParamInfo;
begin
  Info := GetParamInfo(Ord(Id));
  Plain := EnsureRange(Plain, Info.MinV, Info.MaxV);
  if Assigned(FOnEdit) then
    FOnEdit(Id, PlainToParam(Id, Plain));
  Invalidate;
end;

procedure TEnvelopeView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  IdA, IdD, IdS, IdR: TGranularParamId;
begin
  inherited;
  if not Assigned(FOnEdit) or (Button <> mbLeft) or (FCurve = nil) then
    Exit;
  GetIds(IdA, IdD, IdS, IdR);
  FDragPt := HandleAt(X);
  FDragX0 := X;
  case FDragPt of
    1: FDragT0 := ParamToPlain(IdA, FEngine.GetParam(Ord(IdA)));
    2: FDragT0 := ParamToPlain(IdD, FEngine.GetParam(Ord(IdD)));
  else
    FDragT0 := ParamToPlain(IdR, FEngine.GetParam(Ord(IdR)));
  end;
  MouseMove(Shift + [ssLeft], X, Y);
end;

procedure TEnvelopeView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  IdA, IdD, IdS, IdR: TGranularParamId;
  T: Double;
begin
  inherited;
  if not Assigned(FOnEdit) then
    Exit;
  if FDragPt = 0 then
  begin
    if FCurve <> nil then
      if HandleAt(X) = 2 then Cursor := crSizeAll else Cursor := crSizeWE;
    Exit;
  end;
  GetIds(IdA, IdD, IdS, IdR);
  // 100 Pixel nach rechts = Zeit mal ~7,4 (logarithmisch wie die Achse); kleine Zeiten wachsen aus 1 ms heraus
  T := (Max(FDragT0, 0.5) + 1) * Exp((X - FDragX0) * 0.02) - 1;
  case FDragPt of
    1: SetPlain(IdA, T);
    2: begin
         SetPlain(IdD, T);
         if FBot > FTop then
           SetPlain(IdS, (FBot - Y) / (FBot - FTop) * 100);
       end;
    3: SetPlain(IdR, T);
  end;
end;

procedure TEnvelopeView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDragPt := 0;
end;

procedure TEnvelopeView.DblClick;
var
  IdA, IdD, IdS, IdR: TGranularParamId;
  P: TPoint;
begin
  inherited;
  if not Assigned(FOnEdit) or (FCurve = nil) then
    Exit;
  FDragPt := 0;
  GetIds(IdA, IdD, IdS, IdR);
  P := ScreenToClient(Mouse.CursorPos);
  case HandleAt(P.X) of
    1: SetPlain(IdA, GetParamInfo(Ord(IdA)).DefV);
    2: begin
         SetPlain(IdD, GetParamInfo(Ord(IdD)).DefV);
         SetPlain(IdS, GetParamInfo(Ord(IdS)).DefV);
       end;
    3: SetPlain(IdR, GetParamInfo(Ord(IdR)).DefV);
  end;
end;

{ TLfoView }

destructor TLfoView.Destroy;
begin
  FStatic.Free;
  inherited;
end;

procedure TLfoView.DoPaintBuffer;
const
  TRAIL_STEPS = 80;
var
  YF, YFPrev: Single;
  B: TBitmap32;
  W, H, X, Y, Shape, Mid, Amp, K, A, TX, TY, Steps: Integer;
  Span, P, Hz: Double;
  RateId, SyncId: TGranularParamId;
  Hold: Single;

  Ph, V: Double;
  ShapeId: TGranularParamId;
  EIdx: Integer;
  Sum: Double;
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
      B.Font.Size := UiPt(7);
      B.Font.Color := COL_TEXT;
      B.Textout(6, 4, Tr('Morph-LFO aus'));
      inherited;
      Exit;
    end;
    Dec(Shape);
  end;
  Mid := H div 2;
  Amp := H div 2 - 5;
  // edel wie die Huellkurven: Hintergrund mit Schimmer (oben ein Hauch heller), Flaeche zwischen
  // Mittellinie und Kurve als Bernstein-Verlauf (zur Kurve hin kraeftiger), oben Glanzkante.
  // Sparsam: alles Ruhende wird nur bei Aenderung vorgezeichnet, je Bild nur kopiert (Speicherkopie).
  Sum := 0;
  if Shape = LFO_SHAPE_FREE then
    for K := 0 to 31 do
      Sum := Sum + (K + 1) * FreeLfoValue(FEngine.FreeLfo[EIdx]^, K / 31);
  if (FStatic = nil) or (FKeyW <> W) or (FKeyH <> H) or (FKeyShape <> Shape) or (Sum <> FKeySum) then
  begin
    if FStatic = nil then
      FStatic := TBitmap32.Create;
    FStatic.SetSize(W, H);
    FKeyW := W; FKeyH := H; FKeyShape := Shape; FKeySum := Sum;
    SetLength(FGrad, H);
    for K := 0 to H - 1 do
    begin
      P := 1 - K / Max(1, H - 1);                             // 1 = oben, 0 = unten
      FStatic.HorzLineS(0, K, W - 1, Color32(Round(8 + 18 * P), Round(9 + 18 * P), Round(11 + 21 * P)));
      P := Min(1, Abs(K - Mid) / Max(1, Amp));                // Abstand zur Mitte
      FGrad[K] := (COL_ENV and $00FFFFFF) or (TColor32(Round(14 + 70 * P)) shl 24);
    end;
    FStatic.HorzLineTS(0, 0, W - 1, $28FFF0DC);              // Glanzkante oben (wie Glas)
    FStatic.HorzLineTS(0, 1, W - 1, $10FFF0DC);
    FStatic.HorzLineS(0, Mid, W - 1, COL_GRID);
    YFPrev := Mid;
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
      // Flaeche von der Mitte bis zur Kurve
      if Y < Mid then
        for K := Max(0, Y) to Mid - 1 do FStatic.SetPixelTS(X, K, FGrad[K])
      else
        for K := Mid + 1 to Min(H - 1, Y) do FStatic.SetPixelTS(X, K, FGrad[K]);
      if X > 0 then
        AASpan(FStatic, X, YFPrev, YF, COL_ENV);
      YFPrev := YF;
    end;
  end;
  FStatic.DrawTo(B, 0, 0);

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
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
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
      PitchText := Format(Tr('Tonhöhe: %s  (%.0f Hz)'), [NoteName(Round(FEngine.PitchTracker.Note)), FEngine.PitchTracker.Hz])
    else
      PitchText := Tr('Tonhöhe: -');
  end
  else
    PitchText := Tr('(kein Sidechain-Eingang aktiv - Quelle unten in der Host-Leiste wählen)');

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
    FStatic.Font.Size := UiPt(7);
    FStatic.Font.Color := COL_TEXT;
    FStatic.Textout(4, 2, Tr('Ausgang'));
    FStatic.Font.Color := $40A0FF;
    FStatic.Textout(56, 2, Tr('Sidechain'));
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
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
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
      // aus: neutral dunkel wie die anderen Aus-Zustaende (vorher dunkelrot, wirkte schon aktiv)
      B.FillRectS(1, 1, W - 1, H - 1, Color32(40 + A * 215 div 255, 37 + A * 23 div 255, 35 + A * 15 div 255));
      if A > 0 then
        B.FillRectTS(0, 0, W, H, Color32(255, 120, 100, A div 3));
    end;
    B.Font.Name := 'Tahoma';
    B.Font.Size := UiPt(7);
    B.Font.Style := [];
    if FMidi and (A > 120) then B.Font.Color := $00202020
    else if A > 120 then B.Font.Color := $00FFFFFF
    else if FMidi then B.Font.Color := $00A0A0C0
    else B.Font.Color := $00808080;
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
    msFilterEnv, msAmpEnv, msOsc1Env, msOsc2Env, msOsc3Env, msModEnv1, msModEnv2: Result := $FFFFD25A;   // Gelb
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
  W, H, X, Y, A, CR, CG, CB, Src: Integer;
  Rf, Lit, DX, DY, D, Cov, F, Br: Double;
  C: TColor32;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;

  B.Clear(Color32(48, 50, 56));   // Panel-Hintergrund
  Src := ParamStep(SlotSourceIndex(FSlot), FEngine.GetParam(SlotSourceIndex(FSlot)));
  if Src > 0 then
    C := SlotLedColor(TModSource(Src)) and $00FFFFFF
  else
    C := $00505050;
  // runde LED zurueckhaltend wie die gelben Bereichs-Lampen: graue Fassung, gedaempfte Farbe
  // (Kuppel: Mitte hell, Rand dunkler, Licht von oben links), weich auslaufender Schein.
  // Pro Pixel kantengeglaettet (16x16, nur bei Helligkeitsaenderung).
  Rf := Min(W, H) / 2 - 3.5;                          // Kuppel; Rest = Fassung + Schein
  Lit := FShown / 255;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      DX := X + 0.5 - W / 2;
      DY := Y + 0.5 - H / 2;
      D := Sqrt(DX * DX + DY * DY);
      // Schein: ganz leicht, weich auslaufend
      if D > Rf then
      begin
        F := 0.30 * Lit * Sqr(Max(0, 1 - (D - Rf) / 4));
        A := Round(255 * F);
        if A > 0 then B.SetPixelT(X, Y, TColor32(A) shl 24 or C);
      end;
      // Fassung: duenner grauer Ring, kaum dunkler als die Platte
      Cov := EnsureRange(Rf + 1.5 - D, 0, 1);
      if (Cov > 0) and (D > Rf - 0.5) then
        B.SetPixelT(X, Y, TColor32(Round(Cov * 170)) shl 24 or $00303236);
      // Kuppel
      Cov := EnsureRange(Rf - D, 0, 1);
      if Cov > 0 then
      begin
        F := EnsureRange(Sqrt(Sqr(DX + 0.6) + Sqr(DY + 0.6)) / Rf, 0, 1);   // 0 = Mitte
        Br := 0.30 + 0.55 * Lit;                                              // gedaempft
        // aus: warmes Grau wie die Bereichs-Lampen; an: Quellenfarbe, mit Grau gemischt
        CR := Round((100 - 26 * F) * (1 - Lit * 0.8) + ((C shr 16) and $FF) * Br * (1 - 0.3 * F) * Lit * 0.8);
        CG := Round((96 - 25 * F) * (1 - Lit * 0.8) + ((C shr 8) and $FF) * Br * (1 - 0.3 * F) * Lit * 0.8);
        CB := Round((90 - 23 * F) * (1 - Lit * 0.8) + (C and $FF) * Br * (1 - 0.3 * F) * Lit * 0.8);
        // Glanzpunkt oben links
        F := EnsureRange(1 - Sqrt(Sqr(DX + Rf * 0.45) + Sqr(DY + Rf * 0.45)) / (Rf * 0.55), 0, 1) * 0.45;
        CR := Round(CR + (255 - CR) * F); CG := Round(CG + (255 - CG) * F); CB := Round(CB + (255 - CB) * F);
        B.SetPixelT(X, Y, TColor32(Round(Cov * 255)) shl 24 or TColor32(Color32(CR, CG, CB) and $00FFFFFF));
      end;
    end;
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

{ Segmentkette ueber die ganze Breite (der Wert steht rechts auf dunklem Grund): gruen, ab 75 % bernstein, ab 95 % rot;
  beim Ausgang ab der Schwellenmarke bernstein }
procedure DrawSegments(B: TBitmap32; L: Double; IsOutput: Boolean);
const
  SEG = 20;
var
  I, X0, X1, W, H: Integer;
  F: Double;
  C: TColor32;
begin
  W := B.Width;
  H := B.Height;
  for I := 0 to SEG - 1 do
  begin
    X0 := 2 + Round(I * (W - 4) / SEG);
    X1 := 2 + Round((I + 1) * (W - 4) / SEG) - 1;
    F := (I + 0.5) / SEG;
    if F >= 0.95 then C := $FFE04030
    else if F >= 0.75 then C := $FFFFC060
    else C := $FFD08A38;                              // Bernstein wie das ganze Geraet
    if F > L then
      C := (C and $00FFFFFF) or $38000000;          // unbeleuchtet: schwach
    B.FillRectTS(X0, 3, X1, H - 3, C);
  end;
end;

procedure ValueText(B: TBitmap32; const T: string);
var
  TW, Y: Integer;
begin
  TW := B.TextWidth(T);
  Y := (B.Height - 12) div 2;
  B.FillRectTS(B.Width - TW - 6, 2, B.Width - 2, B.Height - 2, $F0141210);
  B.Textout(B.Width - TW - 4, Y, T);
end;

{ ---------------- TReductionView ---------------- }

constructor TReductionView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FShown := -1;
end;

procedure TReductionView.SetDb(Db: Single);
var
  K: Integer;
begin
  FDb := Db;
  K := Round(Min(0, Db) * 10);
  if K <> FShown then
  begin
    FShown := K;
    Invalidate;
  end;
end;

procedure TReductionView.DoPaintBuffer;
const
  SEG = 16; RANGE = 12.0;
var
  B: TBitmap32;
  I, X0, X1, W, H: Integer;
  F, Red: Double;
  C: TColor32;
  T: string;
begin
  Buffer.BeginUpdate;
  try
    B := Buffer;
    W := B.Width;
    H := B.Height;
    B.Clear($FF16181C);
    Red := EnsureRange(-FDb / RANGE, 0, 1);
    for I := 0 to SEG - 1 do
    begin
      // von rechts nach links: je mehr Reduktion, desto weiter nach links
      X1 := W - 3 - Round(I * (W - 4) / SEG);
      X0 := W - 3 - Round((I + 1) * (W - 4) / SEG) + 1;
      F := (I + 0.5) / SEG;
      if F >= 0.75 then C := $FFE04030 else if F >= 0.4 then C := $FFFFB050 else C := $FFD08A38;
      if F > Red then
        C := (C and $00FFFFFF) or $38000000;
      B.FillRectTS(X0, 3, X1, H - 3, C);
    end;
    B.Font.Name := 'Tahoma';
    B.Font.Size := UiPt(7);
    B.Font.Color := $00E6EEF2;   // hell: lesbar neben den Bernstein-Segmenten
    if FDb < -0.1 then T := Format(Tr('Reduktion %.1f dB'), [FDb]) else T := Tr('keine Reduktion');
    B.FillRectTS(2, 2, B.TextWidth(T) + 8, H - 2, $F0141210);
    B.Textout(5, (H - 12) div 2, T);
  finally
    Buffer.EndUpdate;
  end;
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
  inherited;
end;

procedure TLevelView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, X2: Integer;
  L: Double;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  B.Clear(COL_BG);
  L := Level;
  // Pegelkette: 20 Segmente, unbeleuchtet schwach sichtbar - so wirkt die Anzeige auch bei Stille als Messgeraet
  DrawSegments(B, L, FOutput);
  B.Font.Name := 'Tahoma';
  B.Font.Size := UiPt(7);
  B.Font.Color := $00E6EEF2;   // hell: lesbar neben den Bernstein-Segmenten
  if FOutput then
  begin
    X2 := 1 + Round(ParamToPlain(gpOutTrigLevel, FEngine.GetParam(Ord(gpOutTrigLevel))) / 100 * (W - 2));
    B.VertLineS(X2, 0, H - 1, $FFFFFFFF);
    ValueText(B, Format(Tr('Ausgang %.0f %%'), [L * 100]));
  end
  else if FEngine.SidechainActive then
    ValueText(B, Format(Tr('Sidechain %.0f %%'), [L * 100]))
  else
    ValueText(B, Tr('kein Sidechain-Signal'));
  finally
    Buffer.EndUpdate;
  end;
  DimDisplay(Buffer);   // Netzteil sackt bei lautem Ausgang ab: Anzeige dunkler
  inherited;
end;

end.
