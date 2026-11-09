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
  Leiste unten (Stufen-Modi): Klick schaltet Gleiten der Stufe um (Ziehen setzt mehrere gleich),
  Mausrad auf einer Stufe = +/- 1 Halbton (bzw. fein im Modus Frei).
  Halbton-Modus: links eine Klaviatur mit Notennamen (Bezugston = gespielte Taste, waehlbar), damit
  man Melodien direkt nach Noten setzen kann. Bei Glaettung > 0 zeigt eine Kurve den echten Verlauf.
  Zeichnen: Raster, Balken und Kurve liegen in einer gecachten Ebene; je Bild kommt nur
  die Abspielmarke dazu, und auch das nur, wenn sie sich bewegt hat. }

interface

uses
  Granular.Lang,
  Winapi.Windows, System.Classes, System.SysUtils, System.Math, System.Types, Vcl.Controls,
  GR32, GR32_Image,
  Granular.Params, Granular.Engine, Granular.GfxAsm, Granular.DSP;

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
    FRoot: Integer;            // Bezugston der Klaviatur: Stufe 0 = diese Note (0 = C)
    FLaneDrag: Boolean;        // Ziehen in der Gleit-Leiste
    FLaneRest: Boolean;        // Leiste: Rechtsklick bearbeitet Pausen statt Gleiten
    FLaneSet: Boolean;         // ... setzt diesen Zustand
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
    procedure SetRoot(const Value: Integer);
    function KeysW: Integer;
    function LaneH: Integer;
    function StepAt(X: Integer): Integer;
    procedure LaneAt(X: Integer; First: Boolean);
    procedure DrawKeys(W, H: Integer);
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
    property Root: Integer read FRoot write SetRoot;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { Zeichenflaeche fuer eine Oszillator-Welle (eine Periode): blau die Zeichnung, gelb der Klang, wie ihn
    der Oszillator wirklich spielt (bandbegrenzt, mit Glaettung). Ziehen zeichnet, Rechtsklick setzt 0. }
  TOscWaveView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FOsc: Integer;
    FDrawing, FErase: Boolean;
    FLastIdx: Integer;
    FLastVal: Single;
    FOnChange: TNotifyEvent;
    procedure EditAt(X, Y: Integer; First: Boolean);
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine; AOsc: Integer); reintroduce;
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
  COL_BAR     = $FFB0803C;   // Bernstein wie das ganze Geraet
  COL_BAR_NEG = $FF8A5A34;   // negative Stufen: dunkleres Braun-Orange
  COL_CAP     = $FFFFD9A0;
  COL_CURVE   = $FFFFD9A0;
  COL_FILLC   = $FF5A4220;
  COL_KEY_W   = $FFC8CCD2;   // Klaviatur: weisse Taste (gedaempft wie der Rest der Oberflaeche)
  COL_KEY_B   = $FF1C1E22;
  COL_KEY_GAP = $FF5A606A;
  COL_SMOOTH  = $FFF2EEE6;   // Verlauf mit Glaettung (hell, hebt sich vom Bernstein ab)
  TOP_PAD = 6;
  KEYS_W = 36;               // Breite der Klaviatur links (Halbton-Modus)
  LANE_H = 13;               // Gleit-Leiste unter den Stufen
  COL_LANE    = $FF15171A;
  COL_GLIDE   = $FFFFD070;
  NOTE_NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'H');
  BLACK_KEY: array[0..11] of Boolean = (False, True, False, True, False, False, True, False, True, False, True, False);

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

procedure TFreeLfoView.SetRoot(const Value: Integer);
begin
  if Value <> FRoot then
  begin
    FRoot := ((Value mod 12) + 12) mod 12;
    Rebuild;
  end;
end;

{ Notenname; deutsch H, sonst B }
function NoteName(N: Integer): string;
begin
  Result := NOTE_NAMES[N];
  if (N = 11) and (LangCode <> 'de') then
    Result := 'B';
end;

{ Gleit-Leiste nur in den Stufen-Modi }
function TFreeLfoView.LaneH: Integer;
begin
  if (Data.Mode <> 2) and (Height > 60) then
    Result := LANE_H
  else
    Result := 0;
end;

function TFreeLfoView.StepAt(X: Integer): Integer;
var
  N: Integer;
begin
  N := EnsureRange(Data.Steps, 1, FREE_MAX_STEPS);
  Result := EnsureRange((X - KeysW) * N div Max(1, Width - KeysW), 0, N - 1);
end;

procedure TFreeLfoView.LaneAt(X: Integer; First: Boolean);
var
  F: PFreeLfo;
  I: Integer;
  B: UInt64;
begin
  F := Data;
  I := StepAt(X);
  B := UInt64(1) shl I;
  if FLaneRest then
  begin
    // Pause: Stufe schweigt (Rechtsklick)
    if First then
      FLaneSet := F.Rest and B = 0;
    if FLaneSet = (F.Rest and B <> 0) then
      Exit;
    if FLaneSet then
      F.Rest := F.Rest or B
    else
      F.Rest := F.Rest and not B;
    Changed;
    Exit;
  end;
  if First then
    FLaneSet := F.Glide and B = 0;      // erster Klick schaltet um, Ziehen setzt danach gleich
  if FLaneSet = (F.Glide and B <> 0) then
    Exit;
  if FLaneSet then
    F.Glide := F.Glide or B
  else
    F.Glide := F.Glide and not B;
  Changed;
end;

{ Klaviatur nur im Halbton-Modus (dort bedeutet die Hoehe eine Note) }
function TFreeLfoView.KeysW: Integer;
begin
  if (Data.Mode = 0) and (Width > 200) then
    Result := KEYS_W
  else
    Result := 0;
end;

{ Klaviatur links: je Halbtonzeile eine Taste, Name bei genug Hoehe, C immer beschriftet;
  die Zeile 0 (= gespielte Taste) ist hervorgehoben }
procedure TFreeLfoView.DrawKeys(W, H: Integer);
var
  K, Note, Y, Y0, Y1: Integer;
  Hs: Single;
  Black: Boolean;
  S: string;
begin
  Hs := (H - 2 * TOP_PAD) / (2 * FRange);
  // wie ein liegendes Klavier: weisse Flaeche, schwarze Tasten kuerzer darueber
  FStatic.FillRectS(0, 0, KEYS_W - 1, H, COL_KEY_W);
  for K := -FRange to FRange do
  begin
    Y := ValueToY(K / FREE_SEMIS, H);
    Y0 := Round(Y - Hs / 2);
    Y1 := Round(Y + Hs / 2);
    Note := ((FRoot + K) mod 12 + 12) mod 12;
    Black := BLACK_KEY[Note];
    if K = 0 then
      FStatic.FillRectS(0, Max(Y0, 0), KEYS_W - 1, Min(Y1, H), $FFE8B878);   // Bezugston = gespielte Taste
    if Black then
      FStatic.FillRectS(0, Max(Y0, 0), KEYS_W - 13, Min(Y1, H), COL_KEY_B)
    else if not BLACK_KEY[(Note + 11) mod 12] then
      FStatic.HorzLineS(0, Min(Y1, H - 1), KEYS_W - 2, COL_KEY_GAP);   // Fuge E|F und H|C
    if (Hs >= 9) or (Note = 0) then
    begin
      S := NoteName(Note);
      if Note = 0 then
        S := S + IntToStr((60 + FRoot + K) div 12 - 1);   // Bezugston C = C4 (MIDI 60)
      if Black then FStatic.Font.Color := $00D0D0D0 else FStatic.Font.Color := $00202020;
      if Black then
        FStatic.Textout(2, Y - 6, S)
      else
        FStatic.Textout(KEYS_W - 2 - FStatic.TextWidth(S) - 1, Y - 6, S);
    end;
  end;
  FStatic.VertLineS(KEYS_W - 1, 0, H - 1, COL_OCT);
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
  L: Integer;
begin
  Result := -1;
  if not ShapeIsFree then
    Exit;
  Ph := FEngine.LfoPhase[FLfo];
  Ph := Ph - Floor(Ph);
  L := KeysW;
  if Data.Mode = 2 then
    Result := L + Round(Ph * Max(1, Width - L - 1))
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
  L, WW, FullH: Integer;
begin
  if FStatic = nil then
  begin
    FStatic := TBitmap32.Create;
    FStatic.DrawMode := dmOpaque;
  end;
  FStatic.SetSize(W, H);
  F := Data;
  FullH := H;
  H := H - LaneH;                 // Werte oberhalb der Gleit-Leiste
  FStatic.BeginUpdate;
  try
    FStatic.Clear(COL_BG);
    FStatic.Font.Name := 'Tahoma';
    FStatic.Font.Size := UiPt(7);
    Mid := H div 2;
    L := KeysW;
    WW := Max(1, W - L);

    // waagrechtes Raster
    if F.Mode = 0 then
    begin
      for K := -FRange to FRange do
      begin
        Y := ValueToY(K / FREE_SEMIS, H);
        if ((FRoot + K) mod 12 + 12) mod 12 = 0 then
          FStatic.HorzLineS(L, Y, W - 1, COL_OCT)          // jedes C kraeftiger (Oktaven)
        else if (H - 2 * TOP_PAD) / (2 * FRange) >= 4 then
          FStatic.HorzLineS(L, Y, W - 1, COL_LINE);
      end;
    end
    else
    begin
      FStatic.HorzLineS(0, ValueToY(0.5, H), W - 1, COL_LINE);
      FStatic.HorzLineS(0, ValueToY(-0.5, H), W - 1, COL_LINE);
    end;
    FStatic.HorzLineS(L, Mid, W - 1, COL_ZERO);
    if L > 0 then
      DrawKeys(W, H);

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
        X0 := L + I * WW div N;
        X1 := L + (I + 1) * WW div N - 1;
        // Trennlinien, jede 4. Stufe kraeftiger (Takt-Orientierung)
        if I > 0 then
          if I mod 4 = 0 then
            FStatic.VertLineS(X0, 0, H - 1, COL_BEAT)
          else
            FStatic.VertLineS(X0, 0, H - 1, COL_SEP);
        if F.Rest and (UInt64(1) shl I) <> 0 then
        begin
          // Pause: kein Ton -> Feld schraffiert, Schrift "Pause" (statt Balken)
          FStatic.FillRectTS(X0 + 1, 0, X1, H, $70000000);
          for K := 0 to H - 1 do
            for Px := X0 + 1 to X1 - 1 do
              if (Px + K) mod 8 = 0 then
                FStatic.SetPixelTS(Px, K, $30FFFFFF);
          if X1 - X0 >= 30 then
          begin
            FStatic.Font.Color := $00A0A0FF;
            FStatic.Textout(X0 + (X1 - X0 - FStatic.TextWidth(Tr('Pause'))) div 2, H div 2 - 7, Tr('Pause'));
            FStatic.Font.Color := $00E0E0E0;
          end;
          Continue;
        end;
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
          S := NoteName(((FRoot + K) mod 12 + 12) mod 12);
          if X1 - X0 >= 34 then
            if K > 0 then S := S + ' +' + IntToStr(K) else S := S + ' ' + IntToStr(K);
          if V >= 0 then
            FStatic.Textout(X0 + 4, Min(Y + 3, H - 14), S)
          else
            FStatic.Textout(X0 + 4, Max(Y - 14, 0), S);
        end;
      end;
    end;

    if (F.Mode <> 2) and ((F.Smooth > 0.001) or (F.Glide <> 0)) then
    begin
      // echter Verlauf mit Glaettung (so hoert man es)
      YPrevF := (H div 2) - EnsureRange(FreeLfoValue(F^, 0) / VisMax, -1, 1) * ((H div 2) - TOP_PAD);
      for Px := 0 to WW - 1 do
      begin
        YF := (H div 2) - EnsureRange(FreeLfoValue(F^, Px / WW) / VisMax, -1, 1) * ((H div 2) - TOP_PAD);
        AASpan(FStatic, L + Px, YPrevF, YF, COL_SMOOTH);
        YPrevF := YF;
      end;
    end;

    if FullH > H then
    begin
      // Gleit-Leiste: je Stufe ein Feld, gleitende Stufen mit Rampe vom vorigen Wert
      N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
      FStatic.FillRectS(0, H, W, FullH, COL_LANE);
      FStatic.HorzLineS(0, H, W - 1, COL_OCT);
      if L > 0 then
      begin
        FStatic.Font.Color := $00909090;
        FStatic.Textout(2, H + 1, Tr('Gleiten / Pause'));
      end;
      for I := 0 to N - 1 do
      begin
        X0 := L + I * WW div N;
        X1 := L + (I + 1) * WW div N - 1;
        if I > 0 then
          FStatic.VertLineS(X0, H + 1, FullH - 1, COL_SEP);
        if F.Rest and (UInt64(1) shl I) <> 0 then
        begin
          // Pause: Feld dunkel, Stufe oben abgedunkelt mit Querstrich
          FStatic.FillRectTS(X0 + 1, H + 1, X1, FullH - 1, $C0000000);
          FStatic.HorzLineS(X0 + 2, (H + FullH) div 2, X1 - 1, $FFB04040);
          Continue;
        end;
        if (F.Glide and (UInt64(1) shl I) <> 0) and (X1 - X0 >= 3) then
        begin
          // kleine Rampe: zeigt das Herueberrutschen
          for Px := X0 + 2 to X1 - 1 do
          begin
            YF := FullH - 2 - (Px - X0 - 2) / Max(1, X1 - X0 - 3) * (FullH - H - 4);
            Y := Ceil(YF);
            FStatic.VertLineS(Px, Y, FullH - 2, COL_GLIDE);
            // Oberkante anteilig deckend -> keine Treppen
            FStatic.SetPixelTS(Px, Y - 1, (COL_GLIDE and $00FFFFFF) or (TColor32(Round((Y - YF) * 255)) shl 24));
          end;
        end;
      end;
    end;

    FStatic.Font.Color := $00909090;
    if (F.Mode = 0) and (L = 0) then   // mit Klaviatur zeigt sie die Toene - sonst laege die Zahl ueber den Stufen
    begin
      FStatic.Textout(W - 30, ValueToY(Min(12, FRange) / FREE_SEMIS, H) + 1, '+' + IntToStr(Min(12, FRange)));
      FStatic.Textout(W - 30, ValueToY(-Min(12, FRange) / FREE_SEMIS, H) - 12, '-' + IntToStr(Min(12, FRange)));
    end;
    FWasFree := ShapeIsFree;
    if not FWasFree then
    begin
      FStatic.Font.Color := $0060B0FF;
      FStatic.Textout(L + 6, 4, Tr('inaktiv - Form "Frei" wählen (Knopf rechts oder Modulations-Reiter)'));
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
          X0 := KeysW + K * (W - KeysW) div N;
          X1 := KeysW + (K + 1) * (W - KeysW) div N;
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
  X := X - KeysW;
  W := Max(1, Width - KeysW);
  H := Height - LaneH;
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
  if (Button in [mbLeft, mbRight]) and (X >= KeysW) and (LaneH > 0) and (Y >= Height - LaneH) then
  begin
    FLaneRest := Button = mbRight;
    FLaneDrag := True;
    MouseCapture := True;
    LaneAt(X, True);
  end
  else if (Button = mbRight) and (X >= KeysW) and (Data.Mode <> 2) then
  begin
    FLaneRest := True;
    FLaneDrag := True;
    MouseCapture := True;
    LaneAt(X, True);
  end
  else if (Button in [mbLeft, mbRight]) and (X >= KeysW) then
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
  if FLaneDrag then
    LaneAt(EnsureRange(X, KeysW, Width - 1), False)
  else if FDrawing then
    EditAt(EnsureRange(X, KeysW, Width - 1), EnsureRange(Y, 0, Height - 1 - LaneH), False);
end;

procedure TFreeLfoView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDrawing := False;
  FLaneDrag := False;
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
  Idx := EnsureRange((P.X - KeysW) * N div Max(1, Width - KeysW), 0, N - 1);
  if WheelDelta > 0 then Dir := 1 else Dir := -1;
  if F.Mode = 0 then
    F.Step[Idx] := FreeQuantize(FreeQuantize(F.Step[Idx]) + Dir / FREE_SEMIS)
  else
    F.Step[Idx] := EnsureRange(F.Step[Idx] + Dir * 0.02, -1, 1);
  Changed;
end;

{ TOscWaveView }

constructor TOscWaveView.Create(AOwner: TComponent; AEngine: TGranularEngine; AOsc: Integer);
begin
  inherited Create(AOwner);
  BufferOversize := 0;
  FEngine := AEngine;
  FOsc := AOsc;
  FLastIdx := -1;
end;

procedure TOscWaveView.DoPaintBuffer;
type
  TSA = array[0..$FFFFFF] of Single;
var
  B: TBitmap32;
  W, H, Mid, Amp, Px, Y, I: Integer;
  D: POscDraw;
  T: ^TSA;
  V, YF, YPrevF: Single;
begin
  B := Buffer;
  B.BeginUpdate;
  try
    W := B.Width;
    H := B.Height;
    B.Clear(COL_BG);
    if (W < 20) or (H < 20) then
      Exit;
    Mid := H div 2;
    Amp := Mid - TOP_PAD;
    B.HorzLineS(0, Mid - Amp div 2, W - 1, COL_LINE);
    B.HorzLineS(0, Mid + Amp div 2, W - 1, COL_LINE);
    for I := 1 to 3 do
      B.VertLineS(I * W div 4, 0, H - 1, COL_SEP);
    B.HorzLineS(0, Mid, W - 1, COL_ZERO);
    D := FEngine.OscDraw[FOsc];
    // Zeichnung: Flaeche zur Mittellinie + Kontur
    YPrevF := Mid - EnsureRange(D.Pt[0], -1, 1) * Amp;
    for Px := 0 to W - 1 do
    begin
      V := D.Pt[Min(Px * OSC_DRAW_N div W, OSC_DRAW_N - 1)];
      YF := Mid - EnsureRange(V, -1, 1) * Amp;
      Y := Round(YF);
      if Y < Mid then
        B.VertLineS(Px, Y, Mid - 1, COL_FILLC)
      else if Y > Mid then
        B.VertLineS(Px, Mid + 1, Y, COL_FILLC);
      AASpan(B, Px, YPrevF, YF, COL_CURVE);
      YPrevF := YF;
    end;
    // Klang: volle Bandbreite der Wavetable (gelb)
    T := Pointer(FEngine.OscWaveTable(FOsc));
    YPrevF := Mid - EnsureRange(T[0], -1.2, 1.2) * Amp;
    for Px := 0 to W - 1 do
    begin
      YF := Mid - EnsureRange(T[Px * WT_LEN[0] div W], -1.2, 1.2) * Amp;
      AASpan(B, Px, YPrevF, YF, COL_SMOOTH);
      YPrevF := YF;
    end;
  finally
    B.EndUpdate;
  end;
  inherited;
end;

procedure TOscWaveView.EditAt(X, Y: Integer; First: Boolean);
var
  D: POscDraw;
  Idx, I, A, Bi, Mid, Amp: Integer;
  V: Single;
  T: Double;
begin
  D := FEngine.OscDraw[FOsc];
  Mid := Height div 2;
  Amp := Max(1, Mid - TOP_PAD);
  if FErase then
    V := 0
  else
    V := EnsureRange((Mid - Y) / Amp, -1, 1);
  Idx := EnsureRange(X * OSC_DRAW_N div Max(1, Width), 0, OSC_DRAW_N - 1);
  // Luecke zur letzten Mausposition linear fuellen
  if First or (FLastIdx < 0) then
    D.Pt[Idx] := V
  else
  begin
    A := Min(FLastIdx, Idx);
    Bi := Max(FLastIdx, Idx);
    for I := A to Bi do
    begin
      if Bi = A then T := 1 else T := (I - FLastIdx) / (Idx - FLastIdx);
      D.Pt[I] := FLastVal + (V - FLastVal) * T;
    end;
  end;
  FLastIdx := Idx;
  FLastVal := V;
  if Assigned(FOnChange) then
    FOnChange(Self);
  Invalidate;
end;

procedure TOscWaveView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
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

procedure TOscWaveView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDrawing then
    EditAt(EnsureRange(X, 0, Width - 1), EnsureRange(Y, 0, Height - 1), False);
end;

procedure TOscWaveView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDrawing := False;
  FErase := False;
  MouseCapture := False;
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
  Y: Integer;
  T: Single;
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
    B.Font.Size := UiPt(7);
    for I := 0 to ARP_MAX_STEPS - 1 do
    begin
      X0 := I * W div ARP_MAX_STEPS + 1;
      X1 := (I + 1) * W div ARP_MAX_STEPS - 1;
      On := (FMask and (1 shl I)) <> 0;
      Active := I < FSteps;
      if On and Active then C := $FFC48E40          // Bernstein wie Lampen und Huellkurven
      else if On then C := $FF3A3022
      else if Active then C := $FF2A2E34
      else C := $FF1E2024;
      if On then
      begin
        // Taste mit Glanz: oben hell, nach unten in dunkles Orange; obere Kante als Lichtreflex
        for Y := 2 to H - 3 do
        begin
          T := (Y - 2) / Max(1, H - 5);
          if Active then
            B.HorzLineS(X0, Y, X1 - 1, Color32(Round(236 - 120 * T), Round(180 - 108 * T), Round(96 - 70 * T)))
          else
            B.HorzLineS(X0, Y, X1 - 1, Color32(Round(92 - 50 * T), Round(70 - 40 * T), Round(40 - 24 * T)));
        end;
        if Active then
          B.HorzLineTS(X0, 2, X1 - 1, $70FFF4E0);
      end
      else
        B.FillRectS(X0, 2, X1, H - 2, C);
      if I mod 4 = 0 then
        B.VertLineS(X0 - 1, 0, H - 1, COL_BEAT);
      if I = FShown then
      begin
        B.FillRectTS(X0, 2, X1, H - 2, $48FFFFFF);   // laufender Schritt: heller
        B.FillRectS(X0, H - 5, X1, H - 2, $FFFFE8B8);
      end;
      if On and Active then B.Font.Color := $00202020          // dunkle Schrift auf Bernstein
      else if Active then B.Font.Color := $00E0E0E0 else B.Font.Color := $00606060;
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
