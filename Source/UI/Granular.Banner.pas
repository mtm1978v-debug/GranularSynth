{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Banner;

{ Titelbanner: leuchtende Koernerwolke, die eine Welle bildet und mit dem Klang pulsiert,
  darueber der Schriftzug GRANULAR mit weichem Glimmen und "HABI M . Deutung".
  Alles zur Laufzeit mit Graphics32 gezeichnet (keine Bilddatei):
    - Hintergrund + Schriftzug: nur bei Groessenaenderung neu berechnet (zwischengespeichert)
    - Koerner: je Frame (Timer des Editors), ca. 2000 kleine Punkte - wenige Prozent CPU
  Die Ausgangslautstaerke kommt aus der Engine (OutputPeak). }

interface

uses
  System.Classes, System.SysUtils, System.Math, System.Types, Vcl.Graphics, Vcl.Controls,
  GR32, GR32_Image,
  Granular.Params, Granular.Engine, Granular.GfxAsm, Granular.Prof;

const
  BANNER_TITLE = 'GRANULAR';
  BANNER_SUBTITLE = 'FM  ' + #$00B7 + '  Synthese  ' + #$00B7 + '  HABI M  ' + #$00B7 + '  Version ' + APP_VERSION;

type
  { Strichmaennchen: 11 Gelenkpunkte (Kopfmitte, Hals, Huefte, Ellbogen/Haende, Knie/Fuesse)
    + 5 Zopfpunkte (11..15, physikalisch nachgezogen) }
  TDancerPose = record
    X, Y: array[0..24] of Single;   // 0..10 Gelenke, 11..16 Zopf links, 17..22 Zopf rechts, 23/24 Rocksaum
    HeadScale: Single;              // Kopf kommt nach vorn (> 1 = groesser, "faehrt auf einen zu")
    HeadTurn: Single;               // Kopf zur Seite gedreht: -1 linkes / +1 rechtes Ohr nach vorn
  end;

  TGrain = record
    X: Single;        // 0..1 ueber die Breite
    Band: Single;     // -1..1: Lage innerhalb des Wellenbandes
    Phase: Single;
    Speed: Single;
    Size: Byte;
    Bright: Byte;
    Layer: Byte;      // 0/1: zwei ineinander verwobene Wellenbaender
    Glow: Boolean;    // mit weichem Lichthof
  end;

  TBannerView = class(TCustomPaintBox32)
  private
    FEngine: TGranularEngine;
    FFormatName: string;
    FBack: TBitmap32;        // Verlauf (deckend)
    FTitle: TBitmap32;       // Schriftzug mit Glimmen (Alpha)
    FCacheW, FCacheH: Integer;
    FTitleFade: array of Byte;   // je Pixel: 0 an der Schrift .. 255 ab FADE_R Abstand (Koerner blenden aus)
    FTitleRect: TRect;       // nur dieser Bereich enthaelt Schrift -> nur hier mischen
    FGrains: array of TGrain;
    FTime: Double;
    FLevel: Single;          // geglaetteter Ausgangspegel 0..1
    // Langeweile bei Stille: schaut sich um, tippt mit dem Fuss, verlagert das Gewicht
    // Applaus: nach langem Spielen und dann Pause klatscht sie manchmal (danach kleine Verbeugung)
    FPlayRun: Double;        // Sekunden ununterbrochen getanzt
    FApplChecked: Boolean;   // diese Pause schon ausgewuerfelt
    FApplOn: Boolean;
    FApplT, FApplDur: Double;
    FClapPh, FClapRate: Double;   // Klatsch-Phase (0 = Haende treffen sich), Klatschen je Sekunde
    FIdleT, FBored: Double;  // Sekunden Stille, Staerke der Langeweile-Gesten 0..1
    FBoredAct: Integer;      // 0 = umschauen, 1 = Fuss tippen, 2 = Gewicht verlagern
    FBoredLeft: Double;      // Restdauer der laufenden Geste
    FLook, FLookT, FShift, FShiftT, FTap: Double;
    FBoredSide: Integer;     // Seite der Geste (-1 links, +1 rechts)
    FSquats: Integer;        // Anzahl Kniebeugen
    FHairLift: Double;       // Haare streifen: Zopf auf der Seite der Hand sachte anheben
    // Sitzen: 0 steht, 1 setzt sich, 2 sitzt, 3 steht auf (Musik) bzw. 4 steht auf (Langeweile vorbei)
    FSitState: Integer;
    // Stimmung der Musik (geglaettet) und Reaktion: Valenz, Erregung, Zaertlichkeit
    FMV, FMA, FMT: Double;
    FAnchorV, FAnchorA: Double;  // Stimmung "vorher" (langsam) -> Staerke eines Wechsels
    FTenderOn, FTenderSeen: Boolean;
    FHeartCool: Double;          // Sperrzeit bis zu den naechsten Herzchen
    FHearts: array[0..2] of record
      Active: Boolean;
      Age, Life, Delay, Size, OX, OY, Sway: Double;
    end;
    // Begruessung beim Start: Hut auf, abnehmen, verneigen, Hut wegwerfen (Zoepfe kommen hervor)
    FIntroWait: Double;
    FTilt: Double;           // Klangfarbe der Musik, gleitend: -1 bassig (roetlich) .. +1 hell (blaeulich)
    FTintBuf, FTintIn: array of Single;      // Wartezeit vor dem Auftritt (Fenster sichtbar)
    FIntroT: Double;         // Sekunden seit Start der Begruessung (>= INTRO_END: vorbei)
    FHatMode: Integer;       // 0 auf dem Kopf, 1 in der Hand, 2 fliegt, 3 weg
    FHatX, FHatY, FHatAng, FHatVX, FHatVY, FHatSpin: Double;
    FHairLen: Double;        // Zopflaenge 0..1 (unter dem Hut eingesteckt -> fallen heraus)
    // Anklicken: 1 = Purzelbaum (in Ruhe), 2 = Salto (beim Tanzen), danach geht es normal weiter
    FFlipKind: Integer;
    FFlipT: Double;          // 0..1 Fortschritt
    FFlipDir: Integer;
    // Tanz-Energie: Notendichte (Anschlaege/s) und Pegel -> ruhige oder ausgelassene Schritte
    FNoteRate: Double;       // geglaettete Anschlaege je Sekunde
    FLastNoteCount: Integer;
    FEnergy: Double;         // 0 ruhig .. 1 ausgelassen
    FMoveStart: Double;      // Schlag, an dem der aktuelle Schritt begann
    FMoveMin, FMoveMax: Double;   // Dauer des aktuellen Schritts: Wechsel frueh. beim Peak / spaetestens
    FBlendT: Double;         // Ueberblendung zum naechsten Schritt 0..1, < 0 = keine
    FCurMove, FNextMove: Integer;
    FDanceBeat, FTempoRate, FCalmW: Double;   // Tanztakt (ruhig: halbes Tempo)
    FSkirtFast: Boolean;     // Rock faellt schnell nach (Ueberschlag), bis er wieder normal haengt
    FSit: Double;            // Fortschritt 0 (steht) .. 1 (sitzt)
    FSitT, FSitStay: Double; // Zeit im Sitzen, geplante Sitzdauer
    FSitSide: Integer;       // ueber welche Seite sie aufsteht
    FListenSide: Integer;    // Hoeren: -1 linke Hand, +1 rechte, 0 beide Haende an den Ohren
    FListen, FListenT: Double; // Hoer-Geste: eigener Kanal still, aber Sidechain bringt Signal
    FScLevel: Single;        // geglaetteter Sidechain-Pegel 0..1 (hellt den Hintergrund auf)
    FFlash: Single;          // Lichtimpuls nach Presetwechsel: 1 -> 0 in ca. 0,7 s
    FFrameMs: Double;        // gemessene Kosten eines Bildes inkl. Bildschirmuebertragung (geglaettet)
    FHueShift: Single;       // Farbverschiebung durch LFO 1
    // Frequenzbaender fuer die Koernerwolke (links Baesse, rechts Hoehen)
    FBandLvl: array[0..31] of Single;   // geglaettet 0..1
    FScopeL, FScopeR: array of Single;
    FRe, FIm, FTwR, FTwI, FWin: array of Single;
    FRev: array of Integer;
    FBandLo, FBandHi: array[0..31] of Integer;
    FBandSr: Double;
    // Taenzer
    FBeat: Double;           // Schlaege seit Start (Host-Tempo)
    FDance: Single;          // 0..1 Tanzstaerke (Noten gehalten + hoerbar)
    FWiggle: Single;         // 0..1 Zappeln im Ausklang
    FKick: Single;           // Huepfer bei neuem Anschlag, klingt ab
    FPrevPeak: Single;
    FWigT: Double;
    FHairX, FHairY, FHairPX, FHairPY: array[0..1, 0..5] of Single;   // zwei Zoepfe: Verlet-Ketten
    FHairInit: Boolean;
    FSkirtX, FSkirtY, FSkirtVX, FSkirtVY: Single;   // Rocksaum-Mitte als gedaempfte Feder (zieht nach)
    FSkirtInit: Boolean;
    FScreenPos: TPoint;      // Bildschirmlage des Banners: Fenster verschieben -> Zoepfe/Rock schwingen nach
    FScreenKnown: Boolean;
    FArmVar, FArmVarT: array[0..1] of Single;   // kleine Abwandlung der Armhaltung (alle 2 Schlaege neu)
    FArmBeat: Integer;
    FPrevHandY: array[0..1] of Single;           // Hand-y des vorigen Bildes (Arme hoch -> Zopf-Stups)
    // Pirouette: Drehung um die eigene Achse (selten; bei grosser Lautstaerke sehr selten doppelt)
    FSpinOn: Boolean;
    FSpinP: Double;          // Fortschritt 0..1
    FSpinTurns: Integer;     // 1 oder 2 Umdrehungen
    FSpinCos, FSpinSpd: Single;   // aktuelle Breiten-Stauchung, Winkelgeschwindigkeit (rad/s)
    FSpinBeat: Integer;      // zuletzt gepruefter Schlag
    FBrkBar: Integer;        // Breakdance: zuletzt gepruefter Takt (Salto als Power-Move)
    FPrevHipPX: Single;      // Hueft-x des vorigen Bildes (Hueftwackeln schubst den Rock)
    FSkirtLift: array[0..1] of Single;   // Rock fliegt ueber dem gehobenen Knie hoch (schnell hoch, langsam runter)
    FDancerX: Integer;       // rechte Grenze der Arme (vom Editor: buendig mit dem Stil-Feld)
    FLastPlay: Double;       // Schlag, in dem zuletzt eine Note gehalten/angeschlagen war
    FGhost: array[0..6] of TDancerPose;   // [0] = aktuell, 1..6 = Nachzieh-Spur (aelter)
    FGhostValid: Integer;
    procedure UpdateBands;
    procedure UpdateDancer(Seconds: Double);
    procedure SetFormatName(const Value: string);
    procedure DrawDancer(Bits: PColor32Array; W, H: Integer);
    procedure UpdateTint(Seconds: Double);
    function TintColor(Base: TColor32; Amount: Single): TColor32;
    procedure DrawHat(Bits: PColor32Array; W, H: Integer);
    procedure DrawHearts(Bits: PColor32Array; W, H: Integer);
    procedure SpawnHearts;
    procedure BuildCaches;
    procedure ApplyWindowMove;
    procedure BuildTitleFade(W, H: Integer);
    procedure ApplyContrast(B: TBitmap32);
    function GrainColor(X: Single; Alpha: Integer): TColor32;
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent; AEngine: TGranularEngine); reintroduce;
    destructor Destroy; override;
    { vom Editor-Timer aufgerufen: Zeit fortschreiben, neu zeichnen }
    procedure Tick(Seconds: Double);
    { Lichtimpuls ausloesen (z.B. beim Presetwechsel) }
    procedure Flash;
    { Plugin-Format hinter der Version im Untertitel, z.B. 'VST3 FX' }
    property FormatName: string read FFormatName write SetFormatName;
    { Kosten eines Banner-Bildes in ms (fuer die Bildraten-Regelung) }
    property FrameMs: Double read FFrameMs;
    property DancerX: Integer read FDancerX write FDancerX;
  end;

implementation

uses
  Winapi.Windows;

const
  GRAIN_COUNT = 2400;
  SIN_BITS = 12;
  SIN_SIZE = 1 shl SIN_BITS;          // 4096 Eintraege je Periode
  SIN_MASK = SIN_SIZE - 1;
  SIN_SCALE = SIN_SIZE / (2 * Pi);    // Bogenmass -> Tabellenindex

var
  SinTab: array[0..SIN_SIZE - 1] of Single;

{ schneller Sinus per Tabelle: ein Tabellenzugriff statt x87-FSIN (Banner-Aufloesung genuegt) }
function FastSin(X: Single): Single; inline;
begin
  Result := SinTab[Trunc(X * SIN_SCALE + 1024 * SIN_SIZE) and SIN_MASK];
end;

procedure InitSinTab;
var
  I: Integer;
begin
  for I := 0 to SIN_SIZE - 1 do
    SinTab[I] := Sin(I * 2 * Pi / SIN_SIZE);
end;

constructor TBannerView.Create(AOwner: TComponent; AEngine: TGranularEngine);
var
  I: Integer;
begin
  inherited Create(AOwner);
  FBlendT := -1;
  FTempoRate := 1;
  FIntroT := -2.6;          // Auftritt (UpdateDancer: WALK_START), danach die Begruessung mit dem Hut
  FMoveMin := 8;
  FMoveMax := 32;
  BufferOversize := 0;
  FEngine := AEngine;
  FBack := TBitmap32.Create;
  FBack.DrawMode := dmOpaque;
  FTitle := TBitmap32.Create;
  FTitle.DrawMode := dmBlend;
  RandSeed := 20261010;   // feste Verteilung: Banner sieht bei jedem Start gleich aus
  SetLength(FGrains, GRAIN_COUNT);
  for I := 0 to GRAIN_COUNT - 1 do
    with FGrains[I] do
    begin
      X := Random;
      // dichter in der Bandmitte (Summe zweier Zufallswerte ~ Dreieck)
      Band := (Random + Random) - 1;
      Phase := Random * 2 * Pi;
      Speed := 0.004 + Random * 0.018;
      if Random < 0.25 then Size := 2 else Size := 1;
      Bright := 130 + Random(126);
      Layer := Random(2);
      Glow := Random < 0.2;
    end;
end;

destructor TBannerView.Destroy;
begin
  FTitle.Free;
  FBack.Free;
  inherited;
end;

function TBannerView.GrainColor(X: Single; Alpha: Integer): TColor32;
var
  T: Single;
  R, G, B: Integer;
begin
  // LFO 1 verschiebt die Farbpalette sanft (Banner 'atmet' mit der Modulation)
  X := EnsureRange(X + FHueShift, 0, 1);
  // Cyan -> Tuerkis -> warmes Orange ueber die Breite
  if X < 0.6 then
  begin
    T := X / 0.6;
    R := Round(60 + 30 * T);
    G := Round(200 + 30 * T);
    B := Round(255 - 75 * T);
  end
  else
  begin
    T := (X - 0.6) / 0.4;
    R := Round(90 + 165 * T);
    G := Round(230 - 70 * T);
    B := Round(180 - 140 * T);
  end;
  Result := Color32(R, G, B, EnsureRange(Alpha, 0, 255));
end;

procedure TBannerView.BuildCaches;
var
  Sub: string;
  W, H, Y, X, Dx, Dy, TW, TH, TX, TY, SW: Integer;
  T: Single;
begin
  W := Width;
  H := Height;
  FCacheW := W;
  FCacheH := H;

  // Hintergrund: senkrechter Verlauf, unten minimal heller (kein Raster: Kontrast/Sidechain-Toenung
  // wuerden feine Linien als sichtbares Gitter hervorheben)
  FBack.SetSize(W, H);
  for Y := 0 to H - 1 do
  begin
    T := Y / Max(1, H - 1);
    FBack.HorzLineS(0, Y, W - 1, Color32(Round(14 + 10 * T), Round(16 + 12 * T), Round(22 + 16 * T)));
  end;
  FBack.HorzLineS(0, H - 1, W - 1, $FF3A4250);

  // Schriftzug mit Glimmen: mehrfach versetzt und transparent = weicher Lichthof
  FTitle.SetSize(W, H);
  FTitle.Clear(0);
  FTitle.Font.Name := 'Segoe UI';
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Height := -Round(H * 0.62);
  TW := FTitle.TextWidth(BANNER_TITLE);
  TH := FTitle.TextHeight(BANNER_TITLE);
  TX := 18;
  TY := (H - TH) div 2 - 2;
  for Dy := -4 to 4 do
    for Dx := -4 to 4 do
      if (Dx * Dx + Dy * Dy <= 16) and ((Dx <> 0) or (Dy <> 0)) then
        FTitle.RenderText(TX + Dx, TY + Dy, BANNER_TITLE, 2, $0E50E0FF);
  FTitle.RenderText(TX, TY, BANNER_TITLE, 2, $FFEFFBFF);

  // Untertitel rechts neben dem Titel, an der Grundlinie
  FTitle.Font.Style := [];
  FTitle.Font.Height := -Round(H * 0.24);
  Sub := BANNER_SUBTITLE;
  if FFormatName <> '' then
    Sub := Sub + '  ' + #$00B7 + '  ' + FFormatName;     // "VST2", "VST3", "VST2 FX" ...
  SW := FTitle.TextWidth(Sub);
  FTitle.RenderText(TX + TW + 16, TY + TH - FTitle.TextHeight(Sub) - Round(H * 0.08),
    Sub, 2, $FFFFC060);
  FTitleRect := Rect(Max(0, TX - 6), Max(0, TY - 6), Min(W, TX + TW + 16 + SW + 6), Min(H, TY + TH + 6));
  BuildTitleFade(W, H);
end;

{ Abstandskarte zur Schrift (Chamfer 3/4, zwei Durchlaeufe), einmal je Groessenaenderung:
  Koerner werden zur Schrift hin auf wenigen Pixeln ausgeblendet und erreichen sie nie. }
procedure TBannerView.BuildTitleFade(W, H: Integer);
const
  FADE_R = 6;
  BIG = 30000;
var
  D: array of Integer;
  X, Y, I, V: Integer;
  Bits: PColor32Array;
begin
  SetLength(FTitleFade, W * H);
  SetLength(D, W * H);
  Bits := FTitle.Bits;
  for I := 0 to W * H - 1 do
    if (Bits[I] shr 24) > 60 then D[I] := 0 else D[I] := BIG;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      I := Y * W + X;
      V := D[I];
      if X > 0 then V := Min(V, D[I - 1] + 3);
      if Y > 0 then
      begin
        V := Min(V, D[I - W] + 3);
        if X > 0 then V := Min(V, D[I - W - 1] + 4);
        if X < W - 1 then V := Min(V, D[I - W + 1] + 4);
      end;
      D[I] := V;
    end;
  for Y := H - 1 downto 0 do
    for X := W - 1 downto 0 do
    begin
      I := Y * W + X;
      V := D[I];
      if X < W - 1 then V := Min(V, D[I + 1] + 3);
      if Y < H - 1 then
      begin
        V := Min(V, D[I + W] + 3);
        if X < W - 1 then V := Min(V, D[I + W + 1] + 4);
        if X > 0 then V := Min(V, D[I + W - 1] + 4);
      end;
      D[I] := V;
    end;
  for I := 0 to W * H - 1 do
    FTitleFade[I] := Min(255, D[I] * 255 div (3 * FADE_R));
end;

procedure TBannerView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  S: Double;
begin
  inherited;
  if (Button <> mbLeft) or (FGhostValid = 0) or (FFlipKind <> 0) then
    Exit;
  // Treffer: grob das Rechteck um die Figur (aktuelle Pose)
  S := Height * 0.56 / 44.5;
  if (Abs(X - FGhost[0].X[2]) > 14 * S) or (Y < FGhost[0].Y[0] - 8 * S) or (Y > FGhost[0].Y[2] + 22 * S) then
    Exit;
  if FDance > 0.2 then
    FFlipKind := 2              // Salto, danach weitertanzen
  else
  begin
    FFlipKind := 1;             // Purzelbaum; sitzt sie, kommt sie dabei hoch
    FSitState := 0;
    FSit := 0;
  end;
  FFlipT := 0;
  if Random < 0.5 then FFlipDir := -1 else FFlipDir := 1;
end;

procedure TBannerView.SetFormatName(const Value: string);
begin
  if FFormatName = Value then
    Exit;
  FFormatName := Value;
  FCacheW := -1;          // Titelbild mit neuem Untertitel neu aufbauen
  Invalidate;
end;

procedure TBannerView.Flash;
begin
  FFlash := 1;
end;

{ Fenster wurde verschoben: die Figur bewegt sich mit, Zoepfe und Rock bleiben durch ihre Traegheit
  kurz zurueck (in Fensterkoordinaten also entgegen der Bewegung) und schwingen dann nach. }
procedure TBannerView.ApplyWindowMove;
var
  P: TPoint;
  Dx, Dy: Single;
  K, I: Integer;
begin
  if not HandleAllocated then
    Exit;
  P.X := 0; P.Y := 0;
  P := ClientToScreen(P);
  if FScreenKnown and FHairInit then
  begin
    Dx := EnsureRange(P.X - FScreenPos.X, -60, 60);
    Dy := EnsureRange(P.Y - FScreenPos.Y, -60, 60);
    if (Dx <> 0) or (Dy <> 0) then
    begin
      for K := 0 to 1 do
        for I := 1 to 5 do
        begin
          FHairX[K, I] := FHairX[K, I] - Dx * 0.5;
          FHairY[K, I] := FHairY[K, I] - Dy * 0.5;
          FHairPX[K, I] := FHairPX[K, I] - Dx * 0.5;
          FHairPY[K, I] := FHairPY[K, I] - Dy * 0.5;
        end;
      FSkirtVX := FSkirtVX - Dx * 12;
      FSkirtVY := FSkirtVY - Dy * 12;
    end;
  end;
  FScreenPos := P;
  FScreenKnown := True;
end;

procedure TBannerView.Tick(Seconds: Double);
var
  P: Single;
  T0, T1, Freq: Int64;
begin
  if FFlash > 0 then
    FFlash := Max(0, FFlash - Seconds / 0.7);
  // Animationstempo folgt dem Pegel: leise = langsames Treiben, laut = die Wolke rast
  FTime := FTime + Seconds * (0.5 + 3.0 * FLevel);
  P := Min(1.0, FEngine.OutputPeak * 2.5);
  // Sidechain-Kanaele treiben die Wolke mit: der lautere von Ausgang, Sidechain 1 und 2 zaehlt
  P := Max(P, Min(1.0, Max(FEngine.SourceValue[msSidechain], FEngine.SourceValue[msSidechain2]) * 1.5));
  // schneller Anstieg, langsames Abklingen - die Wolke "atmet" mit dem Klang
  if P > FLevel then
    FLevel := FLevel + (P - FLevel) * 0.7     // Anstieg: 90 % nach ca. 2 Frames
  else
    FLevel := FLevel + (P - FLevel) * 0.10;   // Abklingen
  FHueShift := FHueShift + (FEngine.LfoValue[0] * 0.12 - FHueShift) * 0.3;
  // Sidechain-Huellkurvenfolger (aus der Matrix-Quelle) -> Helligkeit des Hintergrunds
  P := FEngine.SourceValue[msSidechain];
  if P > FScLevel then
    FScLevel := FScLevel + (P - FScLevel) * 0.6     // schnell hoch (halbe Zeit bis zur Spitze)
  else
    FScLevel := FScLevel + (P - FScLevel) * 0.25;   // ruhig zurueck
  ApplyWindowMove;
  UpdateDancer(Seconds);
  UpdateTint(Seconds);
  UpdateBands;
  // sofort zeichnen und dabei die echten Kosten messen (Berechnung + Uebertragung auf den Schirm)
  QueryPerformanceCounter(T0);
  ForceFullInvalidate;
  if HandleAllocated then
    UpdateWindow(Handle);
  QueryPerformanceCounter(T1);
  QueryPerformanceFrequency(Freq);
  FFrameMs := FFrameMs + ((T1 - T0) * 1000 / Freq - FFrameMs) * 0.1;
end;

{ Kontrast/Leuchtkraft per Scanline: eine Tabelle je Frame (256 Werte), dann jedes Pixel
  einmal durch die Tabelle. Laut = mehr Kontrast und Glanz, leise = weicher und ruhiger. }
procedure TBannerView.ApplyContrast(B: TBitmap32);
var
  K, Lift: Single;
  KFix, Offset: Integer;
begin
  // c' = (c - 64) * K + 64 + Lift  =  c * K + (64 - 64 * K + Lift)   -> linear, SIMD-tauglich
  K := 0.8 + 1.4 * FLevel;
  Lift := 30 * FLevel + 45 * FFlash;   // Presetwechsel: kurz aufhellen
  KFix := EnsureRange(Round(K * 64), 0, 255);
  Offset := Round(64 - 64 * K + Lift);
  // das Bitmap liegt zusammenhaengend im Speicher -> ein Aufruf fuer alle Pixel
  ContrastRow(PColor32(B.Bits), B.Width * B.Height, KFix, Offset);
end;

{ additiv aufhellen (Licht addiert sich), mit Saettigung - direkt im Pixelspeicher }
procedure AddPixel(Bits: PColor32Array; W, H, X, Y: Integer; C: TColor32; A: Integer); inline;
var
  P: PColor32;
  D: TColor32;
  R, G, B: Integer;
begin
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) or (A <= 0) then
    Exit;
  P := @Bits[Y * W + X];
  D := P^;
  R := Integer((D shr 16) and $FF) + ((Integer((C shr 16) and $FF) * A) shr 8);
  G := Integer((D shr 8) and $FF) + ((Integer((C shr 8) and $FF) * A) shr 8);
  B := Integer(D and $FF) + ((Integer(C and $FF) * A) shr 8);
  if R > 255 then R := 255;
  if G > 255 then G := 255;
  if B > 255 then B := 255;
  P^ := $FF000000 or TColor32(R shl 16) or TColor32(G shl 8) or TColor32(B);
end;

{ ---------------- Frequenzbaender ---------------- }

{ 512-Punkte-FFT des Ausgangs (Hann), 32 logarithmische Baender 40 Hz .. 16 kHz, Pegel in dB
  auf 0..1, schnell hoch / langsam runter. Butterflies ab Stufe 4 im SIMD-Kern (GfxAsm). }
procedure TBannerView.UpdateBands;
const
  N = 512;
  BITS = 9;
var
  I, J, K, Len, Half, B: Integer;
  XR, XI, M, Mx, V, F0, F1: Single;
begin
  if Length(FRe) <> N then
  begin
    SetLength(FScopeL, N); SetLength(FScopeR, N);
    SetLength(FRe, N); SetLength(FIm, N); SetLength(FWin, N); SetLength(FRev, N);
    SetLength(FTwR, N); SetLength(FTwI, N);
    for I := 0 to N - 1 do
    begin
      FWin[I] := 0.5 - 0.5 * Cos(2 * Pi * I / (N - 1));
      J := 0;
      for K := 0 to BITS - 1 do
        if (I and (1 shl K)) <> 0 then J := J or (1 shl (BITS - 1 - K));
      FRev[I] := J;
    end;
    K := 1;
    while K < N do
    begin
      for I := 0 to K - 1 do
      begin
        FTwR[K + I] := Cos(Pi * I / K);
        FTwI[K + I] := -Sin(Pi * I / K);
      end;
      K := K shl 1;
    end;
    FBandSr := 0;
  end;
  if FBandSr <> FEngine.SampleRate then
  begin
    FBandSr := FEngine.SampleRate;
    for B := 0 to 31 do
    begin
      F0 := 40 * Power(16000 / 40, B / 32);
      F1 := 40 * Power(16000 / 40, (B + 1) / 32);
      FBandLo[B] := EnsureRange(Trunc(F0 * N / FBandSr), 1, N div 2 - 1);
      FBandHi[B] := EnsureRange(Trunc(F1 * N / FBandSr), FBandLo[B], N div 2 - 1);
    end;
  end;
  if FEngine.OutputPeak < 0.0005 then
  begin
    for B := 0 to 31 do
      FBandLvl[B] := FBandLvl[B] * 0.9;
    Exit;
  end;
  FEngine.GetScope(FScopeL, FScopeR, N);
  for I := 0 to N - 1 do
  begin
    FRe[FRev[I]] := FScopeL[I] * FWin[I];
    FIm[FRev[I]] := 0;
  end;
  Len := 2;
  while Len <= N do
  begin
    Half := Len shr 1;
    I := 0;
    while I < N do
    begin
      if Half >= 4 then
        FftButterfly(@FRe[I], @FIm[I], Half * SizeOf(Single), @FTwR[Half], @FTwI[Half], Half)
      else
        for J := I to I + Half - 1 do
        begin
          K := J + Half;
          XR := FRe[K] * FTwR[Half + J - I] - FIm[K] * FTwI[Half + J - I];
          XI := FRe[K] * FTwI[Half + J - I] + FIm[K] * FTwR[Half + J - I];
          FRe[K] := FRe[J] - XR; FIm[K] := FIm[J] - XI;
          FRe[J] := FRe[J] + XR; FIm[J] := FIm[J] + XI;
        end;
      Inc(I, Len);
    end;
    Len := Len shl 1;
  end;
  for B := 0 to 31 do
  begin
    Mx := 0;
    for I := FBandLo[B] to FBandHi[B] do
    begin
      M := Sqr(FRe[I]) + Sqr(FIm[I]);
      if M > Mx then Mx := M;
    end;
    // Amplitude in dB (Hann: 4/N), -66 .. -6 dB -> 0..1
    V := 10 * Log10(Max(Mx * Sqr(4 / N), 1E-12));
    V := EnsureRange((V + 66) / 60, 0, 1);
    if V > FBandLvl[B] then
      FBandLvl[B] := FBandLvl[B] + (V - FBandLvl[B]) * 0.6
    else
      FBandLvl[B] := FBandLvl[B] + (V - FBandLvl[B]) * 0.12;
  end;
end;

{ ---------------- Taenzer ---------------- }

{ Haltung aus Winkeln: 0 = Glied haengt nach unten, positiv = zur Koerperaussenseite }
procedure TBannerView.UpdateDancer(Seconds: Double);
const
  TWO_PI = 2 * Pi;
  // Begruessung (Sekunden): Hand zum Hut, abheben, verneigen, aufrichten, Wurf
  // Auftritt davor (FIntroT negativ): zwei gemaechliche Schritte von rechts ins Bild (seitlich, Hut auf),
  // dann zum Publikum drehen, kurz stehen
  WALK_START = -2.6; WALK_END = -1.0; TURN_END = -0.3;
  IN_REACH = 0.7; IN_LIFT = 1.2; IN_BOW = 1.6; IN_BOWHOLD = 2.4; IN_UP = 2.9; IN_THROW = 3.3; INTRO_END = 3.8;
  // ausgelassene Schritte (0..5, 7); 6 = ruhiger Teil im halben Tempo; 7 = Breakdance (meist kurz eingestreut)
  FAST_MOVES: array[0..6] of Integer = (0, 1, 2, 3, 4, 5, 7);
  CALM_MOVE = 6;
  BREAK_MOVE = 7;
var
  Bpm, P, Target, Wt, Phi, Half, Bounce, Sw, W0, W1, W2: Double;
  Env: TEnvelopeState;
  Move: Integer;
  Wm: array[0..7] of Double;
  Bp, Fz, Fs: Double;      // Breakdance: Lage im Takt, Freeze-Staerke, Seite
  MIdx: Integer;
  ListenW: Double;
  PeakNow: Boolean;
  FlipA, FlipLift, FlipCY, CA, SA, Fx, Fy: Double;
  Bow, HatA, T: Double;
  WalkW, WalkSw, WalkP, WalkOff, SideW, TurnP: Double;
  ApplSide: Double;        // Applaus: 0 vorn .. 1 seitlich
  Mood: TMood;
  WTen, WSad, WAng, WHap: Double;
  Ax, Ay, SegL, Dt, Vx, Vy, D, Ang0, Flare: Double;
  K, Hk: Integer;
  Jack: Double;
  HipX, HipY, Lean, Tilt: Double;
  AUL, ALL, AUR, ALR, LUL, LLL, LUR, LLR: Double;   // Ober-/Unterarm, Ober-/Unterschenkel links/rechts
  S, Arm1, Arm2, Leg1, Leg2, Torso, HeadR, BaseX, BaseY: Double;
  I: Integer;
  Pose: TDancerPose;

  procedure Limb(Sx, Sy: Double; A1, A2, L1, L2: Double; Dir: Integer; Mid, Tip: Integer);
  var
    Ex, Ey: Double;
  begin
    // Dir = -1 linke Seite (aussen = -x), +1 rechte Seite
    Ex := Sx + Dir * L1 * Sin(A1);
    Ey := Sy + L1 * Cos(A1);
    Pose.X[Mid] := Ex;
    Pose.Y[Mid] := Ey;
    Pose.X[Tip] := Ex + Dir * L2 * Sin(A1 + A2);
    Pose.Y[Tip] := Ey + L2 * Cos(A1 + A2);
  end;

begin
  Bpm := EnsureRange(ParamToPlain(gpTempo, FEngine.EffParam[Ord(gpTempo)]), 40, 240);
  FBeat := FBeat + Seconds * Bpm / 60;
  FWigT := FWigT + Seconds;

  // Zustand: Noten gehalten und hoerbar -> tanzen; Ausklang -> zappeln; Stille -> stehen
  P := FEngine.OutputPeak;
  Env := FEngine.GetEnvelopeState;
  // getanzt wird, solange in den letzten 1,5 Schlaegen gespielt wurde und noch etwas klingt
  // (auch kurze Noten/Arp: zwischen den Anschlaegen nicht ins Zappeln fallen)
  if Env.Active and (Env.Stage <> esRelease) then
    FLastPlay := FBeat;
  // Tanzstaerke folgt der Lautstaerke: leise = zaghaft, laut = voll; schnell zurueck, wenn es leiser wird
  if (FBeat - FLastPlay < 1.5) and (P > 0.008) then
    Target := EnsureRange((P - 0.01) * 9, 0.15, 1)
  else
    Target := 0;
  // Begruessung laeuft: erst danach tanzen
  if FIntroT < INTRO_END then
  begin
    // erst zaehlen, wenn das Banner wirklich zu sehen ist; grosse Zeitspruenge (Laden) nicht mitnehmen
    if HandleAllocated and IsWindowVisible(Handle) then
    begin
      if FIntroWait < 0.4 then
        FIntroWait := FIntroWait + Min(Seconds, 0.3)     // kurz innehalten, dann losgehen
      else
        FIntroT := FIntroT + Min(Seconds, 0.3);
    end;
    Target := 0;
    FIdleT := 0;
  end;
  // sitzt sie, steht sie bei Musik erst auf - getanzt wird erst, wenn sie steht
  if FSitState <> 0 then
  begin
    if (Target > 0) and (FSitState in [1, 2]) then
      FSitState := 3;
    Target := 0;
  end;
  if Target > FDance then
    FDance := Min(Target, FDance + Seconds * 4)
  else
    FDance := Max(Target, FDance - Seconds * 6);
  Wt := EnsureRange(P * 4, 0, 0.5) * (1 - FDance);
  FWiggle := FWiggle + (Wt - FWiggle) * Min(1, Seconds * 6);
  // Peak in der Musik (deutlicher Pegelsprung) - Zeitpunkt fuer einen Stilwechsel
  PeakNow := (P > FPrevPeak * 1.5 + 0.03) and (P > 0.04);
  // neuer Anschlag: Pegelsprung -> kleiner Huepfer
  if Env.Active and (Env.Stage = esAttack) and (Env.StageSeconds < 0.05) and (FDance > 0.3) then
    FKick := 1
  else if (P > FPrevPeak * 1.5 + 0.03) and (FDance > 0.3) then
    FKick := 1;
  FPrevPeak := P;
  FKick := Max(0, FKick - Seconds * 5);
  {$IFDEF DANCEDBG}
  if Frac(FWigT) < Seconds then
    with TStringList.Create do
    try
      if FileExists(GetEnvironmentVariable('TEMP') + '\dance.txt') then LoadFromFile(GetEnvironmentVariable('TEMP') + '\dance.txt');
      Add(Format('P=%.4f act=%d stage=%d dance=%.2f wig=%.2f beat=%.1f last=%.1f', [P, Ord(Env.Active), Ord(Env.Stage), FDance, FWiggle, FBeat, FLastPlay]));
      SaveToFile(GetEnvironmentVariable('TEMP') + '\dance.txt');
    finally
      Free;
    end;
  {$ENDIF}

  // Tanzschritt wechselt alle 4 Takte, weich ueberblendet. Reihenfolge aus der Tabelle:
  // 5 = Aepfelpfluecken, 6 = ruhiger Teil im halben Tempo mit langsamer Drehung (seltener)
  // eigener Tanztakt: in ruhigen Passagen (wenig Energie, ruhiger Schritt, zaertlich/traurig)
  // weich auf das halbe Tempo - die Bewegungen werden langsamer, bleiben aber im Takt der Musik
  D := EnsureRange((0.4 - FEnergy) * 3, 0, 1);
  D := Max(D, Max(FCalmW, EnsureRange(FMT * 1.5, 0, 1)));
  FTempoRate := FTempoRate + ((1 - 0.5 * D) - FTempoRate) * Min(1.0, Seconds / 1.5);
  FDanceBeat := FDanceBeat + Seconds * Bpm / 60 * FTempoRate;
  Phi := FDanceBeat * TWO_PI;       // eine Periode je (Tanz-)Schlag
  Half := FDanceBeat * Pi;          // eine Periode je zwei Schlaege
  // Energie der Musik: Anschlaege je Sekunde (Zeitkonstante ~3 s) und Pegel.
  // Ruhig (wenige, leise Toene) -> meist der langsame Schritt, selten ein schneller;
  // ausgelassen (viele, laute Toene) -> meist schnelle Schritte, selten ein ruhiger.
  I := FEngine.NoteOnCount;
  if I - FLastNoteCount >= 2 then
    PeakNow := True;                         // mehrere Anschlaege auf einmal (Akkord, Einsatz) = Peak
  D := (I - FLastNoteCount) / Max(Seconds, 0.001);
  FLastNoteCount := I;
  FNoteRate := FNoteRate + (Min(D, 40) - FNoteRate) * Min(1.0, Seconds / 3);
  D := 0.6 * EnsureRange(FNoteRate / 5, 0, 1) + 0.4 * EnsureRange(FLevel * 1.4, 0, 1);
  FEnergy := FEnergy + (D - FEnergy) * Min(1.0, Seconds / 2);
  // Stimmung der Musik: geglaettet; Herzchen beim Hineinwechseln ins Zaertliche
  Mood := FEngine.GetMood;
  D := Min(1.0, Seconds / 1.5);
  FMV := FMV + (Mood.Valence - FMV) * D;
  FMA := FMA + (Mood.Arousal - FMA) * D;
  FMT := FMT + (Mood.Tender - FMT) * D;
  if not FTenderOn then
  begin
    D := Min(1.0, Seconds / 4);
    FAnchorV := FAnchorV + (FMV - FAnchorV) * D;
    FAnchorA := FAnchorA + (FMA - FAnchorA) * D;
  end;
  FHeartCool := Max(0, FHeartCool - Seconds);
  // Testschalter GRANULAR_HEARTS=1: einmal Herzchen direkt nach der Begruessung
  if (not FTenderSeen) and (FIntroT >= INTRO_END) and (GetEnvironmentVariable('GRANULAR_HEARTS') = '1') then
  begin
    FTenderSeen := True;
    SpawnHearts;
  end;
  if (not FTenderOn) and (FMT > 0.55) and (FLevel > 0.01) then
  begin
    FTenderOn := True;
    // Staerke des Wechsels: wie weit war die Musik vorher davon weg (froh/laut oder traurig/duester)
    D := EnsureRange(Sqrt(Sqr(FMV - FAnchorV) + Sqr(FMA - FAnchorA)) / 0.9, 0, 1);
    if (not FTenderSeen) or ((D > 0.45) and (FHeartCool < 18)) or
       ((FHeartCool <= 0) and (Random < 0.15 + 0.6 * D)) then
    begin
      FTenderSeen := True;
      SpawnHearts;
      FHeartCool := 30 - 18 * D;
    end;
  end
  else if FTenderOn and (FMT < 0.35) then
    FTenderOn := False;

  // Stilwechsel synchron zur Musik: fruehestens nach 2 Takten im selben Schritt beim naechsten Peak,
  // spaetestens nach 8 Takten auf der naechsten Eins. Dann zuegig (1/2 Schlag) ueberblenden.
  if (FBlendT < 0) and (FDance > 0.05) and
     ((PeakNow and (FBeat - FMoveStart >= FMoveMin)) or
      ((FBeat - FMoveStart >= FMoveMax) and (Frac(FBeat / 4) < 0.1))) then
  begin
    if FEnergy < 0.35 then D := 0.7          // ruhige Passage: meist langsam
    else if FMT > 0.5 then D := 0.6          // zaertlich: gern der ruhige Schritt
    else if FEnergy < 0.6 then D := 0.3
    else D := 0.08;                          // ausgelassen: selten langsam
    if Random < D then
      FNextMove := CALM_MOVE
    else
      repeat
        FNextMove := FAST_MOVES[Random(Length(FAST_MOVES))];
        // Breakdance passt zu Energie: bei wenig Schwung meist neu wuerfeln
        if (FNextMove = BREAK_MOVE) and (FEnergy < 0.45) and (Random < 0.7) then
          FNextMove := FCurMove;
      until FNextMove <> FCurMove;
    if FNextMove <> FCurMove then
      FBlendT := 0;
    FMoveStart := FBeat;
    // Dauer des neuen Schritts (in Schlaegen): der ruhige Teil meist laenger als die anderen,
    // manchmal aber nur ein kurzer Einschub von einem Takt ("eins, zwei, drei, vier")
    if FNextMove = CALM_MOVE then
    begin
      if Random < 0.25 then
      begin
        FMoveMin := 4; FMoveMax := 4;          // kurzer Einschub: nach genau einem Takt weiter
      end
      else
      begin
        FMoveMin := 16; FMoveMax := 48;        // lang: 4 bis 12 Takte
      end;
    end
    else if FNextMove = BREAK_MOVE then
    begin
      // meist nur ein eingestreuter Takt (Toprock + Freeze), manchmal 2 bis 4 Takte
      if Random < 0.6 then
      begin
        FMoveMin := 4; FMoveMax := 4;
      end
      else
      begin
        FMoveMin := 8; FMoveMax := 16;
      end;
    end
    else
    begin
      FMoveMin := 8; FMoveMax := 32;           // schnelle Schritte: 2 bis 8 Takte
    end;
  end;
  Move := FCurMove;
  for I := 0 to High(Wm) do
    Wm[I] := 0;
  Wm[Move] := 1;
  if FBlendT >= 0 then
  begin
    FBlendT := FBlendT + Seconds * Bpm / 60 / 0.5;   // ueber einen halben Schlag
    if FBlendT >= 1 then
    begin
      FCurMove := FNextMove;
      FBlendT := -1;
      Wm[Move] := 0;
      Wm[FCurMove] := 1;
    end
    else
    begin
      Sw := FBlendT * FBlendT * (3 - 2 * FBlendT);
      Wm[Move] := 1 - Sw;
      Wm[FNextMove] := Wm[FNextMove] + Sw;
    end;
  end;
  W0 := Wm[0]; W1 := Wm[1]; W2 := Wm[2];
  Jack := (1 - Cos(Phi)) * 0.5;     // 0..1 je Schlag (Hampelmann)

  Bounce := Abs(Sin(Half * 2)) * (W0 + W2 + Wm[4]) + Abs(Sin(Half)) * W1 + Jack * Wm[3] +
    Abs(Sin(Phi)) * 0.8 * Wm[5] + Abs(Sin(Half * 0.5)) * 0.25 * Wm[6] + Abs(Sin(Phi)) * 0.6 * Wm[7];
  // Groesse: Figur ~56 % der Bannerhoehe; schwebt - freier Raum oben : unten = 0,382 : 0,618
  // Kindchenschema (Kind ~5 Jahre, leicht ueberzeichnet): Kopf ~1/4 der Hoehe, Rumpf kurz,
  // Beine knapp die Haelfte. Gesamthoehe 44,5 Einheiten: Kopf 11 + Hals 1 + Rumpf 12 + Beine 20,5
  S := Height * 0.56 / 44.5;
  Torso := 12 * S; HeadR := 5.5 * S;
  Arm1 := 7.5 * S; Arm2 := 7 * S; Leg1 := 10.25 * S; Leg2 := 10.25 * S;
  // DancerX = rechte Grenze der ausgestreckten Arme (vom Editor); groesste Reichweite ab der
  // Koerpermitte: Ober- + Unterarm + Hueftschwung
  if FDancerX > 0 then BaseX := FDancerX - (Arm1 + Arm2 + 6 * S) else BaseX := Width * 0.78;
  BaseY := (Height - 44.5 * S) * 0.382 + 44.5 * S;

  // Ausgangshaltung (stehend), dann Tanzschritte mit Staerke FDance dazumischen
  HipX := 0; Lean := 0; Tilt := 0;
  AUL := 0.25; ALL := 0.15; AUR := 0.25; ALR := 0.15;
  LUL := 0.2; LLL := 0; LUR := 0.2; LLR := 0;

  // Schritt 0 "Pumpen": Arme abwechselnd hoch, Knie abwechselnd hochziehen
  AUL := AUL + FDance * W0 * (1.6 + 1.1 * Sin(Phi));
  AUR := AUR + FDance * W0 * (1.6 - 1.1 * Sin(Phi));
  ALL := ALL + FDance * W0 * (1.2 + 0.6 * Sin(Phi));
  ALR := ALR + FDance * W0 * (1.2 - 0.6 * Sin(Phi));
  LUL := LUL + FDance * W0 * 0.7 * Max(0, Sin(Phi));
  LUR := LUR + FDance * W0 * 0.7 * Max(0, -Sin(Phi));
  LLL := LLL + FDance * W0 * 1.1 * Max(0, Sin(Phi));
  LLR := LLR + FDance * W0 * 1.1 * Max(0, -Sin(Phi));
  // Schritt 1 "Seitschritt": Huefte pendelt, Arme hoch und winken, Beine wechseln
  HipX := HipX + FDance * W1 * 6 * S * Sin(Half);
  AUL := AUL + FDance * W1 * (2.5 + 0.35 * Sin(Phi * 2));
  AUR := AUR + FDance * W1 * (2.5 + 0.35 * Sin(Phi * 2 + Pi));
  ALL := ALL + FDance * W1 * (0.5 + 0.5 * Sin(Phi * 2));
  ALR := ALR + FDance * W1 * (0.5 + 0.5 * Sin(Phi * 2 + Pi));
  LUL := LUL + FDance * W1 * (0.45 + 0.45 * Sin(Half));
  LUR := LUR + FDance * W1 * (0.45 - 0.45 * Sin(Half));
  // Schritt 2 "Twist": Oberkoerper kippt, Arme schwingen gegengleich, Knie rein/raus
  Lean := Lean + FDance * W2 * 0.18 * Sin(Phi);
  AUL := AUL + FDance * W2 * (0.9 + 0.9 * Sin(Phi));
  AUR := AUR + FDance * W2 * (0.9 - 0.9 * Sin(Phi));
  ALL := ALL + FDance * W2 * 1.4;
  ALR := ALR + FDance * W2 * 1.4;
  LUL := LUL + FDance * W2 * 0.55 * Sin(Phi);
  LUR := LUR - FDance * W2 * 0.55 * Sin(Phi);
  LLL := LLL + FDance * W2 * 0.8 * Abs(Sin(Phi));
  LLR := LLR + FDance * W2 * 0.8 * Abs(Sin(Phi));
  // Schritt 3 "Hampelmann": Arme von unten nach oben, Beine auf und zu, kleiner Sprung
  AUL := AUL + FDance * Wm[3] * 2.6 * Jack;
  AUR := AUR + FDance * Wm[3] * 2.6 * Jack;
  ALL := ALL + FDance * Wm[3] * 0.3 * Jack;
  ALR := ALR + FDance * Wm[3] * 0.3 * Jack;
  LUL := LUL + FDance * Wm[3] * 0.45 * Jack;
  LUR := LUR + FDance * Wm[3] * 0.45 * Jack;
  // Schritt 4 "Disco": rechter Arm zeigt schraeg hoch / schraeg runter, linke Hand in der Huefte
  AUR := AUR + FDance * Wm[4] * (1.5 + 1.0 * Sin(Half));
  ALR := ALR + FDance * Wm[4] * 0.1;
  AUL := AUL + FDance * Wm[4] * 0.7;
  ALL := ALL + FDance * Wm[4] * 2.3;
  HipX := HipX + FDance * Wm[4] * 3 * S * Sin(Phi);
  Lean := Lean - FDance * Wm[4] * 0.12 * Sin(Half);
  LUR := LUR + FDance * Wm[4] * 0.35 * Max(0, Sin(Phi));
  LLR := LLR + FDance * Wm[4] * 0.6 * Max(0, Sin(Phi));
  FCalmW := Wm[6];
  Tilt := FDance * 0.12 * Sin(Phi + 0.6) * (1 - 0.6 * Wm[6]);
  // Kopf schwenkt im Halbtakt nach links und rechts
  Tilt := Tilt + FDance * 0.32 * Sin(Half + 0.3) * (1 - 0.7 * Wm[6]);
  // Schritt 5 "Aepfelpfluecken": auf der Stelle treten, abwechselnd nach oben greifen
  // (linker Arm hoch, wenn das rechte Knie kommt, und umgekehrt)
  LUL := LUL + FDance * Wm[5] * 0.85 * Max(0, Sin(Phi));
  LLL := LLL + FDance * Wm[5] * 1.15 * Max(0, Sin(Phi));
  LUR := LUR + FDance * Wm[5] * 0.85 * Max(0, -Sin(Phi));
  LLR := LLR + FDance * Wm[5] * 1.15 * Max(0, -Sin(Phi));
  AUL := AUL + FDance * Wm[5] * (1.6 + 1.3 * Max(0, -Sin(Phi)));
  AUR := AUR + FDance * Wm[5] * (1.6 + 1.3 * Max(0, Sin(Phi)));
  ALL := ALL + FDance * Wm[5] * 0.7 * Max(0, Sin(Phi));
  ALR := ALR + FDance * Wm[5] * 0.7 * Max(0, -Sin(Phi));
  Tilt := Tilt + FDance * Wm[5] * 0.12 * Sin(Phi);
  // Schritt 6 "ruhig": halbes Tempo, Arme fliessen langsam auf und ab, sanftes Wiegen
  AUL := AUL + FDance * Wm[6] * (1.3 + 0.8 * Sin(Half * 0.5));
  AUR := AUR + FDance * Wm[6] * (1.3 - 0.8 * Sin(Half * 0.5));
  ALL := ALL + FDance * Wm[6] * (0.6 + 0.3 * Sin(Half * 0.5 + 1));
  ALR := ALR + FDance * Wm[6] * (0.6 - 0.3 * Sin(Half * 0.5 + 1));
  Lean := Lean + FDance * Wm[6] * 0.07 * Sin(Half * 0.5);
  HipX := HipX + FDance * Wm[6] * 2 * S * Sin(Half * 0.5);

  // Armhaltung leicht abwandeln: alle 2 Schlaege neue Zielwerte, weich angesteuert
  if Trunc(FBeat / 2) <> FArmBeat then
  begin
    FArmBeat := Trunc(FBeat / 2);
    FArmVarT[0] := (Random - 0.5) * 0.7;
    FArmVarT[1] := (Random - 0.5) * 0.7;
  end;
  FArmVar[0] := FArmVar[0] + (FArmVarT[0] - FArmVar[0]) * Min(1.0, Seconds * 3);
  FArmVar[1] := FArmVar[1] + (FArmVarT[1] - FArmVar[1]) * Min(1.0, Seconds * 3);
  AUL := AUL + FDance * FArmVar[0];
  AUR := AUR + FDance * FArmVar[1];
  ALL := ALL - FDance * FArmVar[1] * 0.5;
  ALR := ALR - FDance * FArmVar[0] * 0.5;

  // Federn in den Knien: Huefte tiefer, Knie beugen
  HipY := -(Leg1 + Leg2) + FDance * (Bounce * 6 * S) + FKick * (-6 * S) * (1 - Wm[6]);   // ruhig: keine Huepfer
  LLL := LLL + FDance * Bounce * 0.9;
  LLR := LLR + FDance * Bounce * 0.9;
  LUL := LUL - FDance * Bounce * 0.35;
  LUR := LUR - FDance * Bounce * 0.35;

  // Schritt 7 "Breakdance": Toprock (Kreuzschritte, Faeuste vor der Brust, Oberkoerper federt vor und
  // zurueck), auf dem 4. Schlag ein Freeze: tief in die Hocke, ein Bein seitlich ausgestreckt, eine Hand
  // stuetzt am Boden, die andere zeigt nach oben - die Seite wechselt jeden Takt
  if Wm[7] > 0.001 then
  begin
    Wt := FDance * Wm[7];
    Bp := Frac(FDanceBeat / 4) * 4;                  // 0..4 im Takt
    if Bp >= 3 then Fz := Sin(Pi * (Bp - 3)) else Fz := 0;
    Fz := Min(1.0, Fz * 1.6);                        // Freeze schnell rein, kurz halten, raus
    if Odd(Trunc(FDanceBeat / 4)) then Fs := 1 else Fs := -1;
    // Toprock (ausser im Freeze)
    D := Wt * (1 - Fz);
    LUL := LUL + D * (-0.4 * Max(0, Sin(Phi)) + 0.15);   // linker Fuss kreuzt vor
    LUR := LUR + D * (-0.4 * Max(0, -Sin(Phi)) + 0.15);  // ... dann der rechte
    LLL := LLL + D * 0.5 * Max(0, Sin(Phi));
    LLR := LLR + D * 0.5 * Max(0, -Sin(Phi));
    AUL := AUL + D * (0.9 + 0.3 * Sin(Phi));
    AUR := AUR + D * (0.9 - 0.3 * Sin(Phi));
    ALL := ALL + D * 1.9;
    ALR := ALR + D * 1.9;
    Lean := Lean + D * 0.1 * Sin(Phi);
    HipX := HipX + D * 2 * S * Sin(Half);
    // Freeze
    D := Wt * Fz;
    HipY := HipY + D * 9 * S;
    Lean := Lean + D * 0.28 * Fs;
    if Fs > 0 then
    begin
      // Standbein links tief gebeugt, rechtes Bein seitlich gestreckt, linke Hand am Boden
      LUL := LUL + (1.1 - LUL) * D;  LLL := LLL + (2.0 - LLL) * D;
      LUR := LUR + (1.55 - LUR) * D; LLR := LLR + (0 - LLR) * D;
      AUL := AUL + (0.3 - AUL) * D;  ALL := ALL + (0 - ALL) * D;
      AUR := AUR + (2.8 - AUR) * D;  ALR := ALR + (0.1 - ALR) * D;
    end
    else
    begin
      LUR := LUR + (1.1 - LUR) * D;  LLR := LLR + (2.0 - LLR) * D;
      LUL := LUL + (1.55 - LUL) * D; LLL := LLL + (0 - LLL) * D;
      AUR := AUR + (0.3 - AUR) * D;  ALR := ALR + (0 - ALR) * D;
      AUL := AUL + (2.8 - AUL) * D;  ALL := ALL + (0.1 - ALL) * D;
    end;
    Tilt := Tilt * (1 - D) + D * 0.15 * Fs;
    // Power-Move: zu Taktbeginn selten ein Salto (wie beim Anklicken)
    if Trunc(FDanceBeat / 4) <> FBrkBar then
    begin
      FBrkBar := Trunc(FDanceBeat / 4);
      if (FFlipKind = 0) and (Wm[7] > 0.9) and (FDance > 0.5) and (Random < 0.15) then
      begin
        FFlipKind := 2;
        FFlipT := 0;
        if Random < 0.5 then FFlipDir := -1 else FFlipDir := 1;
      end;
    end;
  end;

  // Zappeln (Ausklang): kleine, schnelle Unruhe
  if FWiggle > 0.001 then
  begin
    AUL := AUL + FWiggle * 0.35 * Sin(FWigT * 17);
    AUR := AUR + FWiggle * 0.35 * Sin(FWigT * 19 + 1);
    ALL := ALL + FWiggle * 0.3 * Sin(FWigT * 23);
    ALR := ALR + FWiggle * 0.3 * Sin(FWigT * 21 + 2);
    Tilt := Tilt + FWiggle * 0.15 * Sin(FWigT * 13);
    HipX := HipX + FWiggle * 1.2 * S * Sin(FWigT * 11);
  end;

  // Hoeren: eigener Ausgang still, am Sidechain kommt etwas -> Hand ans Ohr, Kopf neigen,
  // ganz zaghaft mitwiegen ("was ist denn da zu hoeren?")
  D := Max(FEngine.SourceValue[msSidechain], FEngine.SourceValue[msSidechain2]);
  if (FDance < 0.01) and (P < 0.003) and (D > 0.04) then
    FListen := Min(1, FListen + Seconds * 1.5)
  else
    FListen := Max(0, FListen - Seconds * 1.2);
  if FListen <= 0 then
    FListenT := 0;
  ListenW := 0;
  if FListen > 0 then
  begin
    // neues Zuhoeren: Seite auswuerfeln (links, rechts oder beide Haende)
    if FListenT = 0 then
      case Random(5) of
        0, 1: FListenSide := 1;
        2, 3: FListenSide := -1;
      else
        FListenSide := 0;
      end;
    FListenT := FListenT + Seconds;
    Wt := FListen * (0.6 + 0.4 * EnsureRange(D * 3, 0, 1));   // lauter -> etwas deutlicher
    ListenW := Wt;
    if FListenSide >= 0 then
    begin
      AUR := AUR + Wt * 0.95;               // Ellbogen seitlich, Hand am rechten Ohr
      ALR := ALR + Wt * 2.15;
    end;
    if FListenSide <= 0 then
    begin
      AUL := AUL + Wt * 0.95;               // ... bzw. am linken Ohr
      ALL := ALL + Wt * 2.15;
    end;
    // Kopf zur Hand geneigt (beide Haende: aufrecht, nur leicht nickend)
    Tilt := Tilt + FListenSide * Wt * (0.26 + 0.05 * Sin(FListenT * 1.7)) +
      (1 - Abs(FListenSide)) * Wt * 0.04 * Sin(FListenT * 1.7);
    Lean := Lean + FListenSide * Wt * 0.05;
    HipX := HipX + Wt * 0.8 * S * Sin(FListenT * 1.3);        // zaghaftes Mitwiegen
  end;

  // Reaktion auf die Stimmung (nur beim Tanzen, dezent):
  //   zaertlich: Haende zum Herzen, sanftes Wiegen; traurig: Arme haengen, Kopf sinkt;
  //   wuetend/angespannt: Stampfen, Arme angewinkelt; froehlich: Arme hoeher, mehr Schwung
  if FDance > 0.05 then
  begin
    WTen := FMT * FDance;
    WSad := EnsureRange(-FMV * 2, 0, 1) * EnsureRange((0.5 - FMA) * 2.5, 0, 1) * FDance;
    WAng := EnsureRange(-FMV * 2, 0, 1) * EnsureRange((FMA - 0.45) * 2.5, 0, 1) * FDance;
    WHap := EnsureRange(FMV * 2, 0, 1) * EnsureRange((FMA - 0.4) * 2.5, 0, 1) * FDance;
    AUL := AUL + (0.55 - AUL) * 0.7 * WTen;  ALL := ALL + (2.5 - ALL) * 0.7 * WTen;
    AUR := AUR + (0.55 - AUR) * 0.7 * WTen;  ALR := ALR + (2.5 - ALR) * 0.7 * WTen;
    Tilt := Tilt + WTen * 0.12 * Sin(Half * 0.5);
    AUL := AUL * (1 - 0.45 * WSad);  AUR := AUR * (1 - 0.45 * WSad);
    ALL := ALL * (1 - 0.5 * WSad);   ALR := ALR * (1 - 0.5 * WSad);
    LUL := LUL + WAng * 0.55 * Max(0, Sin(Phi));  LUR := LUR + WAng * 0.55 * Max(0, -Sin(Phi));
    LLL := LLL + WAng * 0.8 * Max(0, Sin(Phi));   LLR := LLR + WAng * 0.8 * Max(0, -Sin(Phi));
    ALL := ALL + WAng * 1.1;  ALR := ALR + WAng * 1.1;
    AUL := AUL + WHap * 0.45; AUR := AUR + WHap * 0.45;
    HipY := HipY - WHap * 1.2 * S * Abs(Sin(Phi));
  end
  else
  begin
    WSad := 0;
  end;

  // Applaus: wurde lange (> 45 s) durchgetanzt und die Musik hoert auf, klatscht sie manchmal
  // (Testschalter GRANULAR_APPLAUS=1: schon nach 3 s und immer)
  if FDance > 0.3 then
  begin
    FPlayRun := FPlayRun + Seconds;
    FApplChecked := False;
  end
  else if (FDance < 0.02) and not FApplChecked and (FIntroT >= INTRO_END) then
  begin
    FApplChecked := True;
    if GetEnvironmentVariable('GRANULAR_APPLAUS') = '1' then
      D := 3
    else
      D := 45;
    if (FPlayRun > D) and (FSitState = 0) and ((D = 3) or (Random < 0.5)) then
    begin
      FApplOn := True;
      FApplT := 0;
      FApplDur := 2.4 + Random * 1.6;          // 2,4 .. 4 s klatschen
      FClapPh := 0.5;                          // Haende beginnen auseinander
      FClapRate := 4.2 + Random * 0.8;
    end;
    FPlayRun := 0;
  end;

  // Langeweile: nach ~3 s Stille alle paar Sekunden eine kleine, langsame Geste
  if (FDance < 0.01) and (FWiggle < 0.01) and (P < 0.003) and (FListen < 0.01) and not FApplOn then
    FIdleT := FIdleT + Seconds
  else
    FIdleT := 0;
  if FIdleT > 3 then
    FBored := Min(1, FBored + Seconds)
  else
    FBored := Max(0, FBored - Seconds * 4);
  FHairLift := 0;
  if FBored > 0 then
  begin
    FBoredLeft := FBoredLeft - Seconds;
    FTap := FTap + Seconds;                    // Zeit seit Beginn der Geste
    if FBoredLeft <= 0 then
    begin
      // Gesten-Auswahl (gewichtet): umschauen und ruhig stehen am haeufigsten, Fuss tippen
      // (links oder rechts) selten, dazu wiegen, strecken, Haende in die Huefte, Gewicht verlagern
      // Testschalter GRANULAR_SIT=1: setzt sich bei der ersten Langeweile-Geste sofort hin
      if (FSitState = 0) and (((FIdleT > 12) and (Random < 0.15)) or
         (GetEnvironmentVariable('GRANULAR_SIT') = '1')) then
      begin
        FSitState := 1;              // hinsetzen und eine Weile sitzen bleiben
        FSitT := 0;
        FSitStay := 20 + Random * 40;
        if Random < 0.5 then FSitSide := -1 else FSitSide := 1;
      end;
      case Random(17) of
        0..2: FBoredAct := 0;        // umschauen
        3..5: FBoredAct := 4;        // ruhig dastehen
        6:    FBoredAct := 2;        // rechter Fuss tippt
        7:    FBoredAct := 5;        // linker Fuss tippt
        8, 9: FBoredAct := 3;        // Gewicht auf eine Seite
        10:   FBoredAct := 6;        // sanft hin und her wiegen, Arme baumeln mit
        11:   FBoredAct := 7;        // Arme langsam hochstrecken
        12:   FBoredAct := 8;        // Haende in die Huefte
        13:   FBoredAct := 10;       // durch die Haare streifen
        14:   FBoredAct := 11;       // Kopf nach hinten werfen
        15:   FBoredAct := 12;       // Kniebeugen
      else
        FBoredAct := 9;              // auf den Zehen wippen
      end;
      case FBoredAct of
        7: FBoredLeft := 2.8;
        10: FBoredLeft := 2.6;
        11: FBoredLeft := 2.0;
        12: begin FSquats := 1 + Random(3); FBoredLeft := FSquats * 1.4 + 0.4; end;
      else
        FBoredLeft := 2.2 + Random * 2.5;
      end;
      if Random < 0.5 then FBoredSide := -1 else FBoredSide := 1;
      FTap := 0;
      FLookT := 0;
      FShiftT := 0;
      case FBoredAct of
        0: if Random < 0.5 then FLookT := -1 else FLookT := 1;
        3, 8: if Random < 0.5 then FShiftT := -1 else FShiftT := 1;
      end;
    end;
    // weich und deutlich langsamer als beim Tanzen
    FLook := FLook + (FLookT - FLook) * Min(1.0, Seconds * 2.2);
    FShift := FShift + (FShiftT - FShift) * Min(1.0, Seconds * 1.5);
    Tilt := Tilt + FBored * FLook * 0.30;
    Lean := Lean + FBored * FLook * 0.04;
    HipX := HipX + FBored * FShift * 1.6 * S;
    LUL := LUL - FBored * FShift * 0.08;
    LUR := LUR + FBored * FShift * 0.08;
    // Ein-/Ausblenden der laufenden Geste (je ~0,5 s), damit nichts ruckt
    Wt := FBored * Min(1, FTap * 2) * Min(1, FBoredLeft * 2);
    case FBoredAct of
      2, 5:   // Fuss tippen, zweimal je Sekunde, deutlich aber klein
        begin
          D := Max(0, Sin(FTap * 2 * TWO_PI)) * Wt;
          if FBoredAct = 2 then
          begin
            LLR := LLR + 0.38 * D; LUR := LUR + 0.12 * D;
          end
          else
          begin
            LLL := LLL + 0.38 * D; LUL := LUL + 0.12 * D;
          end;
          Tilt := Tilt + 0.05 * D;      // Kopf nickt ein wenig mit
        end;
      6:      // wiegen: Huefte und Kopf pendeln langsam, Arme baumeln gegengleich
        begin
          D := Sin(FTap * 2.2) * Wt;
          HipX := HipX + D * 1.3 * S;
          Tilt := Tilt - D * 0.12;
          AUL := AUL + Max(0, D) * 0.35;
          AUR := AUR + Max(0, -D) * 0.35;
        end;
      7:      // strecken: Arme langsam nach oben, kurz halten, wieder runter; Kopf leicht zurueck
        begin
          D := Sin(Min(1, FTap / 2.8) * Pi) * Wt;
          AUL := AUL + D * 2.5; AUR := AUR + D * 2.5;
          ALL := ALL + D * 0.3; ALR := ALR + D * 0.3;
          HipY := HipY - D * 1.0 * S;   // auf die Zehen
        end;
      8:      // Haende in die Huefte, Gewicht zur Seite
        begin
          AUL := AUL + Wt * 0.75; ALL := ALL + Wt * 2.1;
          AUR := AUR + Wt * 0.75; ALR := ALR + Wt * 2.1;
        end;
      9:      // auf den Zehen wippen
        HipY := HipY - Max(0, Sin(FTap * 1.6 * TWO_PI)) * Wt * 1.2 * S;
      10:     // durch die Haare streifen: Hand hoch an den Kopf, dann langsam am Zopf entlang nach aussen
        begin
          D := Min(1, FTap / 0.8);                     // Hand hebt sich
          P := EnsureRange((FTap - 0.8) / 1.4, 0, 1);  // streicht nach aussen/unten
          if FBoredSide > 0 then
          begin
            AUR := AUR + Wt * (2.7 * D - 1.2 * P);
            ALR := ALR + Wt * (1.9 * D - 1.3 * P);
          end
          else
          begin
            AUL := AUL + Wt * (2.7 * D - 1.2 * P);
            ALL := ALL + Wt * (1.9 * D - 1.3 * P);
          end;
          Tilt := Tilt - FBoredSide * Wt * 0.15 * D;   // Kopf neigt sich zur Hand
          FHairLift := Wt * D * (1 - P * 0.5);          // Zopf wird sachte mitgenommen
        end;
      11:     // Kopf schwungvoll zurueckwerfen, dann langsam zurueck - die Zoepfe fliegen
        begin
          if FTap < 0.35 then D := Sin(FTap / 0.35 * Pi / 2)
          else D := Max(0, 1 - (FTap - 0.35) / 1.2);
          Tilt := Tilt + FBoredSide * Wt * 0.55 * D;
          Lean := Lean - FBoredSide * Wt * 0.10 * D;
        end;
      12:     // Kniebeugen (1 bis 3), Arme gehen zum Ausgleich nach vorn/oben
        if FTap < FSquats * 1.4 then
        begin
          D := Sqr(Sin(FTap / 1.4 * Pi)) * Wt;
          HipY := HipY + D * 5 * S;
          LUL := LUL - D * 0.9; LUR := LUR - D * 0.9;
          LLL := LLL + D * 1.9; LLR := LLR + D * 1.9;
          AUL := AUL + D * 1.4; AUR := AUR + D * 1.4;
        end;
    end;
  end;

  // Sitzen auf dem Boden: Huefte sinkt, Knie seitlich angezogen, Haende ruhen auf den Knien.
  // Aufstehen asymmetrisch ueber eine Seite (ein Bein streckt sich zuerst), Haende stuetzen kurz ab.
  case FSitState of
    1: begin FSit := Min(1, FSit + Seconds / 1.6); if FSit >= 1 then FSitState := 2; end;
    2: begin
         FSitT := FSitT + Seconds;
         if FSitT > FSitStay then FSitState := 4;      // genug gesessen
       end;
    3: begin FSit := Max(0, FSit - Seconds / 1.2); if FSit <= 0 then FSitState := 0; end;   // Musik: zuegig
    4: begin FSit := Max(0, FSit - Seconds / 1.8); if FSit <= 0 then FSitState := 0; end;   // gemaechlich
  end;
  if FSit > 0 then
  begin
    FBored := 0;                                       // im Sitzen keine Steh-Gesten
    D := FSit * FSit * (3 - 2 * FSit);                 // weich (smoothstep)
    if FSitState in [3, 4] then
      Wt := EnsureRange(FSit * 1.4 - 0.4, 0, 1)        // Seite FSitSide streckt sich frueher
    else
      Wt := D;
    Wt := Wt * Wt * (3 - 2 * Wt);
    // Seitlich sitzen: beide Knie zur Seite FSitSide, Unterschenkel unter den Koerper gefaltet.
    // Bein auf der Knie-Seite liegt flach nach aussen, das andere kreuzt vor dem Koerper hinueber.
    if FSitSide > 0 then
    begin
      LUR := LUR + (1.55 - LUR) * Wt;  LLR := LLR + (-2.5 - LLR) * Wt;
      LUL := LUL + (-1.1 - LUL) * D;   LLL := LLL + (2.3 - LLL) * D;
    end
    else
    begin
      LUL := LUL + (1.55 - LUL) * Wt;  LLL := LLL + (-2.5 - LLL) * Wt;
      LUR := LUR + (-1.1 - LUR) * D;   LLR := LLR + (2.3 - LLR) * D;
    end;
    // Huefte sinkt, bis Knie/Fuesse auf dem Boden liegen
    HipY := HipY + (Leg1 + Leg2) * 0.62 * (D + Wt) * 0.5;
    // Arme: Hand auf der Knie-Seite ruht auf dem Knie, die andere im Schoss;
    // beim Auf-/Hinsetzen stuetzen die Haende seitlich ab
    Vx := Sin(Pi * D) * Ord(FSitState <> 2);           // Abstuetz-Anteil waehrend der Bewegung
    if FSitSide > 0 then
    begin
      AUR := AUR + (0.78 - AUR) * D - Vx * 0.35;  ALR := ALR + (0.1 - ALR) * D;
      AUL := AUL + (0.25 - AUL) * D;              ALL := ALL + (1.1 - ALL) * D;
    end
    else
    begin
      AUL := AUL + (0.78 - AUL) * D - Vx * 0.35;  ALL := ALL + (0.1 - ALL) * D;
      AUR := AUR + (0.25 - AUR) * D;              ALR := ALR + (1.1 - ALR) * D;
    end;
    Lean := Lean - FSitSide * 0.08 * D;                // Oberkoerper leicht von den Knien weg
    HipX := HipX + FSitSide * Vx * 2.2 * S;            // Gewicht ueber die Aufsteh-Seite
    Lean := Lean - FSitSide * Vx * 0.10;
    // sitzend: Kopf wiegt sich ganz sacht
    if FSitState = 2 then
      Tilt := Tilt + D * 0.09 * Sin(FSitT * 0.8) + D * 0.03 * Sin(FSitT * 2.1);
  end;

  // Begruessung: rechte Hand zum Hut, Hut abheben, verneigen (Oberkoerper verkuerzt sich in der
  // Vorderansicht, Kopf sinkt), Hut seitlich ausgestreckt; aufrichten, Hut im Bogen wegwerfen
  // Auftritt: Schrittwechsel (Beine/Arme gegengleich, Huefte wippt), am Ende Drehung nach vorn
  WalkW := 0; WalkSw := 0; WalkOff := 0; SideW := 1; TurnP := 1;
  if FIntroT < 0 then
  begin
    WalkP := EnsureRange((FIntroT - WALK_START) / (WALK_END - WALK_START), 0, 1);
    WalkW := Min(1.0, Min(WalkP * 5, (1 - WalkP) * 5));            // weich an- und auslaufend
    WalkSw := Sin(WalkP * 2 * Pi) * WalkW;                          // zwei Schritte
    // geht nach links: von ausserhalb des rechten Rands bis an ihren Platz
    WalkOff := 1.3 * (Leg1 + Leg2) * (1 - WalkP * WalkP * (3 - 2 * WalkP));
    LUL := LUL + 0.42 * WalkSw;  LUR := LUR + 0.42 * WalkSw;       // links vor / rechts zurueck (Gehrichtung links)
    LLL := LLL - 0.55 * WalkW * Max(0, Cos(WalkP * 2 * Pi));       // Knie des schwingenden Beins (Unterschenkel nach hinten)
    LLR := LLR + 0.55 * WalkW * Max(0, -Cos(WalkP * 2 * Pi));
    AUL := AUL - 0.28 * WalkSw;  AUR := AUR - 0.28 * WalkSw;       // Arme gegengleich
    ALL := ALL + 0.15 * WalkW;   ALR := ALR + 0.15 * WalkW;
    HipY := HipY + 0.8 * S * Abs(WalkSw);                          // tiefer im Schritt, hoch beim Durchschwingen
    Lean := Lean - 0.04 * WalkW;                                    // leicht in Gehrichtung
    TurnP := EnsureRange((FIntroT - WALK_END) / (TURN_END - WALK_END), 0, 1);
    TurnP := TurnP * TurnP * (3 - 2 * TurnP);
    SideW := 0.45 + 0.55 * TurnP;                                   // Seitenansicht -> Vorderansicht
  end;

  if FIntroT < INTRO_END then
  begin
    T := Max(0, FIntroT);
    // Arm zum Kopf (Hand am Hutrand) ... Hut hoch ... seitlich ausstrecken ... Wurf nach oben
    if T < IN_REACH then D := T / IN_REACH else D := 1;
    D := D * D * (3 - 2 * D);
    Wt := EnsureRange((T - IN_LIFT) / (IN_BOW - IN_LIFT), 0, 1);       // vom Kopf weg nach aussen
    Wt := Wt * Wt * (3 - 2 * Wt);
    AUR := AUR + D * (2.75 - 1.6 * Wt);
    ALR := ALR + D * (2.0 - 1.85 * Wt);
    if (T > IN_LIFT) and (T < IN_BOW) then
      AUR := AUR + 0.35 * Sin((T - IN_LIFT) / (IN_BOW - IN_LIFT) * Pi);  // Hut ein Stueck anheben
    // Verneigung
    if T < IN_BOW then Bow := 0
    else if T < IN_BOW + 0.4 then Bow := (T - IN_BOW) / 0.4
    else if T < IN_BOWHOLD then Bow := 1
    else if T < IN_UP then Bow := 1 - (T - IN_BOWHOLD) / (IN_UP - IN_BOWHOLD)
    else Bow := 0;
    Bow := Bow * Bow * (3 - 2 * Bow);
    AUL := AUL + Bow * 0.7; ALL := ALL + Bow * 1.7;                    // linke Hand an den Bauch
    LLL := LLL + Bow * 0.25; LLR := LLR + Bow * 0.25;                  // Knie leicht gebeugt
    HipY := HipY + Bow * 1.2 * S;
    // Wurf: Arm holt aus und schwingt nach oben-aussen
    if T > IN_UP then
    begin
      Wt := EnsureRange((T - IN_UP) / (IN_THROW - IN_UP), 0, 1);
      AUR := AUR - 0.5 * Sin(Wt * Pi) + 1.6 * Wt * Wt;
      ALR := ALR - 0.1 * Wt;
      if T > IN_THROW then
      begin
        Wt := EnsureRange((T - IN_THROW) / (INTRO_END - IN_THROW), 0, 1);
        AUR := AUR + (0.25 - AUR) * Wt;                                // Arm sinkt zurueck
        ALR := ALR + (0.15 - ALR) * Wt;
      end;
    end;
    Torso := Torso * (1 - 0.42 * Bow);                                 // Vorderansicht: verkuerzt
  end
  else
    Bow := 0;

  // Applaus in Seitenansicht (Blick nach links, wie beim Auftritt): erst zur Seite drehen, dann klatschen -
  // beide Arme nach vorn, Unterarme vor der Brust; die Haende oeffnen sich (vordere Hand hoch, hintere tief)
  // und schnappen zusammen. Nicht metronomisch: jede Periode leicht anderes Tempo, zum Ende langsamer und
  // kleiner. Danach Verbeugung nach vorn und zurueck zum Publikum drehen.
  ApplSide := 0;
  // Testschalter GRANULAR_APPLAUS=2: einmal Applaus direkt nach der Begruessung, 3: in Schleife
  if not FApplOn and (FIntroT >= INTRO_END) and
     (((FClapRate = 0) and (GetEnvironmentVariable('GRANULAR_APPLAUS') = '2')) or
      (GetEnvironmentVariable('GRANULAR_APPLAUS') = '3')) then      // 3 = immer wieder (Bildfolge)
  begin
    FApplOn := True; FApplT := 0; FApplDur := 4; FClapPh := 0.5; FClapRate := 4.5;
  end;
  if FApplOn then
  begin
    FApplT := FApplT + Seconds;
    if (FDance > 0.1) or (FApplT > FApplDur + 2.1) or (FSitState <> 0) then
      FApplOn := False;
  end;
  if FApplOn then
  begin
    // Drehung: 0,4 s zur Seite, am Ende (nach der Verbeugung) 0,4 s zurueck
    ApplSide := Min(1.0, FApplT / 0.4) * EnsureRange((FApplDur + 2.1 - FApplT) / 0.4, 0, 1);
    ApplSide := ApplSide * ApplSide * (3 - 2 * ApplSide);
    // Klatschen (nach der Drehung einsetzend, vor der Verbeugung endend)
    Wt := EnsureRange((FApplT - 0.3) / 0.3, 0, 1) * EnsureRange((FApplDur - FApplT) / 0.35, 0, 1);
    Wt := Wt * Wt * (3 - 2 * Wt);
    D := EnsureRange((FApplDur - FApplT) / 1.2, 0.35, 1);       // zum Ende: langsamer, kleiner
    FClapPh := FClapPh + Seconds * FClapRate * (0.75 + 0.25 * D);
    if FClapPh >= 1 then
    begin
      FClapPh := FClapPh - 1;
      FClapRate := 4.2 + Random * 0.8;
    end;
    Jack := Power((1 + Cos(TWO_PI * FClapPh)) * 0.5, 4);         // 1 = Haende beisammen
    Jack := 1 - D * (1 - Jack);                                  // kleiner werdende Oeffnung
    // Arme nach vorn (links = Blickrichtung): linker Arm positive, rechter negative Winkel;
    // gleiche Betraege = Haende am selben Punkt
    AUL := AUL + (0.85 - AUL) * ApplSide;
    AUR := AUR + (-0.85 - AUR) * ApplSide;
    ALL := ALL + (1.0 + 0.85 * (1 - Jack) * Wt - ALL) * ApplSide;     // vordere Hand oeffnet nach oben
    ALR := ALR + (-1.0 + 0.35 * (1 - Jack) * Wt - ALR) * ApplSide;    // hintere nach unten
    HipY := HipY - Wt * 0.25 * S * Jack;                         // kleiner Ruck beim Treffen
    Tilt := Tilt + ApplSide * (0.04 * Sin(FApplT * 2.3) - 0.05);
    // Verbeugung nach dem Klatschen: Oberkoerper nach vorn (Blickrichtung), Arme haengen
    if FApplT > FApplDur then
    begin
      Wt := Sin(Pi * EnsureRange((FApplT - FApplDur) / 1.4, 0, 1));
      Wt := Wt * Wt * (3 - 2 * Wt);
      Lean := Lean - Wt * 0.55;
      AUL := AUL + (0.35 - AUL) * Wt; ALL := ALL + (0.1 - ALL) * Wt;
      AUR := AUR + (-0.35 - AUR) * Wt; ALR := ALR + (-0.1 - ALR) * Wt;
      LLL := LLL + Wt * 0.15; LLR := LLR + Wt * 0.15;
    end;
  end;

  // Purzelbaum / Salto: Fortschritt und Zusammenrollen (Knie an die Brust, Arme um die Beine)
  FlipA := 0; FlipLift := 0; FlipCY := 0;
  if FFlipKind <> 0 then
  begin
    if FFlipKind = 1 then FFlipT := FFlipT + Seconds / 1.6 else FFlipT := FFlipT + Seconds / 0.9;
    if FFlipT >= 1 then
      FFlipKind := 0
    else
    begin
      D := Sin(Pi * FFlipT);                           // Hocke: am staerksten in der Mitte
      if FFlipKind = 1 then
        D := Min(1.0, D * 1.8);                        // Purzelbaum: enges Knaeuel fast die ganze Zeit
      LUL := LUL + D * 1.3;  LUR := LUR + D * 1.3;
      LLL := LLL + D * 2.0;  LLR := LLR + D * 2.0;
      AUL := AUL + D * 1.0;  AUR := AUR + D * 1.0;
      ALL := ALL + D * 1.2;  ALR := ALR + D * 1.2;
      Wt := FFlipT * FFlipT * (3 - 2 * FFlipT);        // Drehung weich an- und auslaufend
      FlipA := Wt * TWO_PI;
      if FFlipKind = 2 then
        FlipLift := D * 10 * S                         // Salto: Sprung nach oben
      else
        HipY := HipY + D * 7 * S;                      // Purzelbaum: tief am Boden
    end;
  end;

  // Gelenkpunkte
  Pose.X[2] := BaseX + HipX;                 // Huefte
  Pose.Y[2] := BaseY + HipY;
  Pose.X[1] := Pose.X[2] + Torso * Sin(Lean);   // Hals
  Pose.Y[1] := Pose.Y[2] - Torso * Cos(Lean);
  // Kopf sitzt direkt auf den Schultern (kurzer Hals)
  Pose.X[0] := Pose.X[1] + HeadR * 0.92 * Sin(Lean + Tilt);   // Kopfmitte
  Pose.Y[0] := Pose.Y[1] - HeadR * 0.92 * Cos(Lean + Tilt);
  // traurig: Kopf sinkt etwas auf die Brust
  if WSad > 0.01 then
    Pose.Y[0] := Pose.Y[0] + WSad * 1.6 * S;
  // Hoeren: Kopf kommt etwas nach vorn (groesser) und dreht das lauschende Ohr zum Betrachter
  Pose.HeadScale := 1 + 0.12 * ListenW + 0.06 * Bow;
  Pose.HeadTurn := FListenSide * 0.85 * ListenW;
  Limb(Pose.X[1], Pose.Y[1] + 0.8 * S, AUL, ALL, Arm1, Arm2, -1, 3, 4);   // linker Arm
  Limb(Pose.X[1], Pose.Y[1] + 0.8 * S, AUR, ALR, Arm1, Arm2, +1, 5, 6);   // rechter Arm
  Limb(Pose.X[2], Pose.Y[2], LUL, LLL, Leg1, Leg2, -1, 7, 8);            // linkes Bein
  Limb(Pose.X[2], Pose.Y[2], LUR, LLR, Leg1, Leg2, +1, 9, 10);           // rechtes Bein

  // Pirouette: einmal je Schlag wuerfeln; nur beim Tanzen, selten. Sehr laut -> selten zweimal.
  if Trunc(FBeat) <> FSpinBeat then
  begin
    FSpinBeat := Trunc(FBeat);
    if not FSpinOn and (FDance > 0.6) and (Wm[6] < 0.01) and (Random < 0.025) then
    begin
      FSpinOn := True;
      FSpinP := 0;
      if (FLevel > 0.8) and (Random < 0.3) then FSpinTurns := 2 else FSpinTurns := 1;
    end;
  end;
  FSpinCos := 1;
  FSpinSpd := 0;
  if (Wm[6] > 0.01) and not FSpinOn and (FDance > 0.05) then
  begin
    Wt := FBeat / 8 * TWO_PI;
    FSpinCos := 1 - Wm[6] * Min(1.0, FDance * 1.5) * (1 - Cos(Wt));
    FSpinSpd := Wm[6] * TWO_PI / 8 * Bpm / 60;
    for I := 0 to 10 do
      Pose.X[I] := Pose.X[2] + (Pose.X[I] - Pose.X[2]) * FSpinCos;
  end
  else if FSpinOn then
  begin
    // eine Umdrehung dauert gut einen Schlag; weich an- und auslaufen
    P := FSpinP;
    FSpinP := FSpinP + Seconds * Bpm / 60 / (1.2 * FSpinTurns);
    if FSpinP >= 1 then
      FSpinOn := False
    else
    begin
      Wt := FSpinP * FSpinP * (3 - 2 * FSpinP) * FSpinTurns * TWO_PI;   // Drehwinkel
      FSpinCos := Cos(Wt);
      P := P * P * (3 - 2 * P) * FSpinTurns * TWO_PI;
      FSpinSpd := Abs(Wt - P) / Max(Seconds, 0.001);
      // Breite um die Koerperachse stauchen/spiegeln -> sieht aus wie Drehen
      for I := 0 to 10 do
        Pose.X[I] := Pose.X[2] + (Pose.X[I] - Pose.X[2]) * FSpinCos;
    end;
  end;
  // Auftritt: seitlich gestaucht (Profil), von links herein, Kopf schaut in Gehrichtung
  if FIntroT < 0 then
  begin
    Fx := Pose.X[2];                           // Bezug festhalten (Huefte wird selbst mit verschoben)
    for I := 0 to 10 do
      Pose.X[I] := Fx + (Pose.X[I] - Fx) * SideW + WalkOff;
    Pose.HeadTurn := -0.8 * (1 - TurnP);
  end;
  // Applaus: seitlich (Profil wie beim Auftritt), Kopf schaut in Blickrichtung
  if ApplSide > 0.001 then
  begin
    Fx := Pose.X[2];
    for I := 0 to 10 do
      Pose.X[I] := Fx + (Pose.X[I] - Fx) * (1 - 0.3 * ApplSide);   // Dreiviertel-Ansicht: Arme bleiben lang
    Pose.HeadTurn := -0.8 * ApplSide;
  end;
  // Purzelbaum: Rolle nach vorn - in der Vorderansicht ein Ueberschlag um die Querachse
  // (Hoehe schrumpft, kippt kopfueber, kommt zurueck). Salto: Drehung in der Bildebene im Sprung.
  if FlipA <> 0 then
  begin
    FlipCY := Pose.Y[2] - 4 * S;                       // Drehpunkt: Koerpermitte
    CA := Cos(FlipA); SA := Sin(FlipA) * FFlipDir;
    for I := 0 to 10 do
    begin
      Fx := Pose.X[I] - Pose.X[2];
      Fy := Pose.Y[I] - FlipCY;
      if FFlipKind = 1 then
        Pose.Y[I] := FlipCY + Fy * CA * (0.75 + 0.25 * Abs(CA))   // Ueberschlag nach vorn (kopfueber gestaucht)
      else
      begin
        Pose.X[I] := Pose.X[2] + Fx * CA - Fy * SA;
        Pose.Y[I] := FlipCY + Fx * SA + Fy * CA - FlipLift;
      end;
    end;
  end;
  // Purzelbaum: das Knaeuel rollt auf dem Boden - tiefster Punkt immer auf Bodenhoehe
  if (FlipA <> 0) and (FFlipKind = 1) then
  begin
    Fy := -1E9;
    for I := 0 to 10 do
      if Pose.Y[I] > Fy then Fy := Pose.Y[I];
    Fy := BaseY - Fy;
    for I := 0 to 10 do
      Pose.Y[I] := Pose.Y[I] + Fy;
  end;
  // Zwei Zoepfe (links/rechts oben am Kopf), Verlet-Ketten mit Schwerkraft und Daempfung;
  // feste Gliedlaenge per Abstands-Korrektur -> schwingen jeder Bewegung nach
  // unter dem Hut eingesteckt; sobald der Hut sich hebt, rutschen sie heraus und fallen
  if FIntroT < IN_LIFT then FHairLen := 0.12
  else FHairLen := Min(1, FHairLen + Seconds / 0.5);
  SegL := 4.9 * S * FHairLen;      // lange Zoepfe (bis etwa zur Huefte)
  Dt := EnsureRange(Seconds, 0.001, 0.05);
  for Hk := 0 to 1 do
  begin
    if Hk = 0 then Ang0 := -1.15 else Ang0 := 1.15;
    Ax := Pose.X[0] + HeadR * Sin(Lean + Tilt + Ang0);
    Ay := Pose.Y[0] - HeadR * Cos(Lean + Tilt + Ang0);
    Ax := Pose.X[2] + (Ax - Pose.X[2]) * FSpinCos;
    if not FHairInit then
      for I := 0 to 5 do
      begin
        FHairX[Hk, I] := Ax + Sign(Ang0) * I * SegL * 0.35;
        FHairY[Hk, I] := Ay + I * SegL * 0.9;
        FHairPX[Hk, I] := FHairX[Hk, I];
        FHairPY[Hk, I] := FHairY[Hk, I];
      end;
    FHairX[Hk, 0] := Ax;
    FHairY[Hk, 0] := Ay;
    for I := 1 to 5 do
    begin
      Vx := (FHairX[Hk, I] - FHairPX[Hk, I]) * 0.90;
      Vy := (FHairY[Hk, I] - FHairPY[Hk, I]) * 0.90;
      FHairPX[Hk, I] := FHairX[Hk, I];
      FHairPY[Hk, I] := FHairY[Hk, I];
      // Schwerkraft + leichter Zug nach aussen (Zoepfe fallen seitlich am Kopf vorbei)
      FHairX[Hk, I] := FHairX[Hk, I] + Vx + Sign(Ang0) * 120 * S * Dt * Dt;
      FHairY[Hk, I] := FHairY[Hk, I] + Vy + 900 * S * Dt * Dt;
      // Arm geht hoch -> dezenter Stups nach oben, dann faellt der Zopf von selbst zurueck
      if (I >= 2) and (FPrevHandY[Hk] > Pose.Y[4 + 2 * Hk]) then
        FHairY[Hk, I] := FHairY[Hk, I] - Min(FPrevHandY[Hk] - Pose.Y[4 + 2 * Hk], 3 * S) * 0.08 * (I - 1) / 4;
      // Haare streifen: Zopf auf der Seite der Hand wird sachte angehoben und nach aussen gefuehrt
      if (FHairLift > 0.01) and (Sign(Ang0) = FBoredSide) and (I >= 2) then
      begin
        FHairY[Hk, I] := FHairY[Hk, I] - FHairLift * 60 * S * Dt * Dt * I;
        FHairX[Hk, I] := FHairX[Hk, I] + Sign(Ang0) * FHairLift * 40 * S * Dt * Dt * I;
      end;
      // Fliehkraft beim Drehen: Zoepfe fliegen nach aussen und heben sich
      if FSpinSpd > 0.1 then
      begin
        D := FHairX[Hk, I] - Pose.X[2];
        if Abs(D) < S then D := Sign(Ang0) * S;
        FHairX[Hk, I] := FHairX[Hk, I] + Sign(D) * Sqr(Min(FSpinSpd, 14)) * 0.9 * S * Dt * Dt * I;
        FHairY[Hk, I] := FHairY[Hk, I] - Sqr(Min(FSpinSpd, 14)) * 0.35 * S * Dt * Dt * I;
      end;
    end;
    for K := 0 to 2 do
      for I := 1 to 5 do
      begin
        Vx := FHairX[Hk, I] - FHairX[Hk, I - 1];
        Vy := FHairY[Hk, I] - FHairY[Hk, I - 1];
        D := Sqrt(Vx * Vx + Vy * Vy);
        if D > 0.0001 then
        begin
          D := (D - SegL) / D;
          FHairX[Hk, I] := FHairX[Hk, I] - Vx * D;
          FHairY[Hk, I] := FHairY[Hk, I] - Vy * D;
        end;
      end;
    for I := 0 to 5 do
    begin
      // Boden: kopfueber (Purzelbaum, Sitzen) liegen die Zoepfe auf statt durchzuhaengen
      if FHairY[Hk, I] > BaseY then
      begin
        FHairY[Hk, I] := BaseY;
        FHairPY[Hk, I] := BaseY;
      end;
      Pose.X[11 + Hk * 6 + I] := FHairX[Hk, I];
      Pose.Y[11 + Hk * 6 + I] := FHairY[Hk, I];
    end;
  end;
  FHairInit := True;
  FPrevHandY[0] := Pose.Y[4];
  FPrevHandY[1] := Pose.Y[6];
  // Glockenrock: Saum schwingt mit der Hueftbewegung leicht nach
  // Glockenrock mit Traegheit: die Saum-Mitte haengt an einer gedaempften Feder an der Huefte.
  // Huepft sie hoch, bleibt der Saum zurueck (Rock wird laenger); faellt sie, fliegt er hoch und
  // weht dabei auf (breiter). Seitlich zieht er der Hueftbewegung nach.
  Vx := Pose.X[2] + HipX * 0.25;            // Ruhelage der Saum-Mitte
  Vy := Pose.Y[2] + 7.5 * S;
  if not FSkirtInit then
  begin
    FSkirtX := Vx; FSkirtY := Vy; FSkirtVX := 0; FSkirtVY := 0; FSkirtInit := True;
    FPrevHipPX := Pose.X[2];
  end;
  D := Min(Dt, 0.05);
  // Hueftwackeln: der Saum bekommt einen Teil der Hueftgeschwindigkeit mit und schwingt weiter aus
  FSkirtVX := FSkirtVX + (Pose.X[2] - FPrevHipPX) / D * 0.6;
  FPrevHipPX := Pose.X[2];
  // Ueberschlag (Purzelbaum/Salto): Rock faellt etwa 4,5-mal schneller nach (Feder steifer,
  // Daempfung passend mit), sonst haengt er sichtbar hinterher
  // schnell bleiben, bis der Saum nach dem Ueberschlag wieder auf normaler Hoehe haengt
  if FFlipKind <> 0 then
    FSkirtFast := True
  else if FSkirtFast and (Abs(FSkirtY - Vy) < 0.5 * S) and (Abs(FSkirtX - Vx) < 0.5 * S) and
     (FSkirtLift[0] < 0.3 * S) and (FSkirtLift[1] < 0.3 * S) then
    FSkirtFast := False;
  if FSkirtFast then Fx := 4.5 else Fx := 1;
  Fy := Sqrt(Fx);
  FSkirtVX := FSkirtVX + ((Vx - FSkirtX) * 160 * Fx - FSkirtVX * 5 * Fy) * D;
  FSkirtVY := FSkirtVY + ((Vy - FSkirtY) * 170 * Fx - FSkirtVY * 5 * Fy) * D;
  FSkirtX := EnsureRange(FSkirtX + FSkirtVX * D, Vx - 4.5 * S, Vx + 4.5 * S);
  FSkirtY := EnsureRange(FSkirtY + FSkirtVY * D, Vy - 5 * S, Vy + 4 * S);
  Flare := 8.5 * S + Min(FSpinSpd, 14) * 0.25 * S + FDance * 1.4 * S * Abs(Sin(Phi)) + Max(0, Vy - FSkirtY) * 1.3;
  Pose.X[23] := FSkirtX - Flare;
  Pose.Y[23] := FSkirtY + (FSkirtX - Vx) * 0.55;     // Saum kippt beim seitlichen Nachziehen
  Pose.X[24] := FSkirtX + Flare;
  Pose.Y[24] := FSkirtY - (FSkirtX - Vx) * 0.55;
  // gehobenes Knie (7 links, 9 rechts) schleudert die Rockseite hoch - wie die Spitzenanzeige
  // beim EQ: sofort mit, dann gemaechlich wieder herunter
  for K := 0 to 1 do
  begin
    D := Max(0, (Pose.Y[2] + Leg1 * 0.85) - Pose.Y[7 + 2 * K]) * 1.4;
    if D > FSkirtLift[K] then
      FSkirtLift[K] := FSkirtLift[K] + (D - FSkirtLift[K]) * 0.6
    else
      FSkirtLift[K] := Max(0, FSkirtLift[K] - 6 * S * Dt * (1 + 3.5 * Ord(FSkirtFast)));   // nach Ueberschlag 4,5x
  end;
  Pose.Y[23] := Pose.Y[23] - FSkirtLift[0];
  Pose.X[23] := Pose.X[23] - FSkirtLift[0] * 0.7;
  Pose.Y[24] := Pose.Y[24] - FSkirtLift[1];
  Pose.X[24] := Pose.X[24] + FSkirtLift[1] * 0.7;

  // Rocksaum dreht um die (schon mitgedrehte) Huefte mit
  if FlipA <> 0 then
    for I := 23 to 24 do
    begin
      Fx := Pose.X[I] - Pose.X[2];
      Fy := Pose.Y[I] - Pose.Y[2];
      if FFlipKind = 1 then
        Pose.Y[I] := Pose.Y[2] + Fy * CA
      else
      begin
        Pose.X[I] := Pose.X[2] + Fx * CA - Fy * SA;
        Pose.Y[I] := Pose.Y[2] + Fx * SA + Fy * CA;
      end;
    end;
  // Hut: auf dem Kopf, in der rechten Hand (6), dann geworfen (Wurfparabel mit Drehung)
  if FHatMode < 3 then
  begin
    HatA := 0;
    if (FHatMode = 0) and (FIntroT >= IN_LIFT - 0.15) then FHatMode := 1;
    if (FHatMode = 1) and (FIntroT >= IN_THROW) then
    begin
      FHatMode := 2;
      FHatVX := -(230 + 70 * Random) * S;     // flacher Bogen nach links durchs Banner
      FHatVY := -120 * S;
      FHatSpin := -7;
    end;
    case FHatMode of
      0: begin
           HatA := Lean + Tilt;
           FHatX := Pose.X[0] + Sin(HatA) * HeadR * 0.8;
           FHatY := Pose.Y[0] - Cos(HatA) * HeadR * 0.8;
           FHatAng := HatA;
         end;
      1: begin
           // in der Hand: Krempe an der Hand, Hut leicht schraeg nach aussen
           FHatX := Pose.X[6];
           FHatY := Pose.Y[6] - HeadR * 0.2;
           FHatAng := FHatAng + (0.35 * (1 - Bow) + 1.2 * Bow - FHatAng) * Min(1.0, Seconds * 8);
         end;
      2: begin
           FHatVY := FHatVY + 260 * S * Seconds;
           FHatX := FHatX + FHatVX * Seconds;
           FHatY := FHatY + FHatVY * Seconds;
           FHatAng := FHatAng + FHatSpin * Seconds;
           if (FHatY > Height + 40 * S) or (FHatX < -40 * S) then FHatMode := 3;
         end;
    end;
  end;
  // Herzchen: aufploppen, sacht steigen und wiegen, dann wie Seifenblasen zerplatzen
  for I := 0 to 2 do
    with FHearts[I] do
      if Active then
      begin
        if Delay > 0 then Delay := Delay - Seconds
        else
        begin
          Age := Age + Seconds;
          if Age >= Life then Active := False;
        end;
      end;
  // Nachzieh-Spur fortschreiben
  for I := High(FGhost) downto 1 do
    FGhost[I] := FGhost[I - 1];
  FGhost[0] := Pose;
  if FGhostValid < Length(FGhost) then
  begin
    Inc(FGhostValid);
    if FGhostValid = 1 then
      for I := 1 to High(FGhost) do
        FGhost[I] := Pose;
  end;
end;

{ Leuchtlinie (Wu-Verfahren, additiv): je Schritt zwei Pixel mit Flaechenanteil, dazu ein
  schwacher Lichthof darueber/darunter. Direkt in die Pixelzeilen - kein GR32-Linienaufruf. }
procedure GlowLine(Bits: PColor32Array; W, H: Integer; X1, Y1, X2, Y2: Single; C: TColor32; A: Integer);
var
  Dx, Dy, G, T, Y, X, F: Single;
  I, N, P0, Q: Integer;
begin
  Dx := X2 - X1;
  Dy := Y2 - Y1;
  if Abs(Dx) >= Abs(Dy) then
  begin
    N := Round(Abs(Dx));
    if N = 0 then N := 1;
    G := Dy / N;
    if Dx < 0 then T := -1 else T := 1;
    Y := Y1;
    for I := 0 to N do
    begin
      P0 := Round(X1 + I * T);
      Q := Trunc(Y + 1000) - 1000;
      F := Y - Q;
      AddPixel(Bits, W, H, P0, Q, C, Round(A * (1 - F)));
      AddPixel(Bits, W, H, P0, Q + 1, C, Round(A * F));
      AddPixel(Bits, W, H, P0, Q - 1, C, A div 5);
      AddPixel(Bits, W, H, P0, Q + 2, C, A div 5);
      Y := Y + G;
    end;
  end
  else
  begin
    N := Round(Abs(Dy));
    if N = 0 then N := 1;
    G := Dx / N;
    if Dy < 0 then T := -1 else T := 1;
    X := X1;
    for I := 0 to N do
    begin
      P0 := Round(Y1 + I * T);
      Q := Trunc(X + 1000) - 1000;
      F := X - Q;
      AddPixel(Bits, W, H, Q, P0, C, Round(A * (1 - F)));
      AddPixel(Bits, W, H, Q + 1, P0, C, Round(A * F));
      AddPixel(Bits, W, H, Q - 1, P0, C, A div 5);
      AddPixel(Bits, W, H, Q + 2, P0, C, A div 5);
      X := X + G;
    end;
  end;
end;

procedure TBannerView.SpawnHearts;
const
  // zwei mittlere und ein kleines Herz, schoen um den Kopf verteilt (Einheiten: Figur-Massstab)
  OXS: array[0..2] of Double = (-9.5, -2.5, 4.0);   // Taenzerin steht rechts am Rand -> eher links/oben
  OYS: array[0..2] of Double = (-6.5, -13.0, -9.0);
  SZ: array[0..2] of Double = (3.3, 2.9, 2.0);
  DL: array[0..2] of Double = (0, 0.28, 0.55);
var
  I: Integer;
begin
  for I := 0 to 2 do
    with FHearts[I] do
    begin
      Active := True;
      Age := 0;
      Delay := DL[I];
      Life := 2.6 + Random * 0.9;
      Size := SZ[I];
      OX := OXS[I] + (Random - 0.5) * 1.5;
      OY := OYS[I] + (Random - 0.5) * 1.5;
      Sway := Random * 6.28;
    end;
end;

procedure TBannerView.DrawHearts(Bits: PColor32Array; W, H: Integer);
var
  I, K: Integer;
  S, R, CX, CY, Sc, Pop, U, Vv, X, Y, F, A, Ang: Double;
  Fill, Rim: TColor32;
begin
  if FGhostValid = 0 then
    Exit;
  S := H * 0.56 / 44.5;
  for I := 0 to 2 do
    with FHearts[I] do
    begin
      if not Active or (Delay > 0) then
        Continue;
      // Position: ueber/um den Kopf, steigt langsam und wiegt sich
      CX := FGhost[0].X[0] + (OX + 1.2 * Sin(Age * 2.1 + Sway)) * S;
      CY := FGhost[0].Y[0] + (OY - Age * 2.2) * S;
      // Aufploppen: 0 -> 1,15 -> 1 in 0,3 s
      if Age < 0.3 then Sc := Sin(Age / 0.3 * Pi * 0.75) * 1.25
      else Sc := 1;
      Pop := EnsureRange((Age - (Life - 0.35)) / 0.35, 0, 1);    // Zerplatzen am Ende
      R := Size * S * Sc;
      if Pop <= 0 then
      begin
        Fill := Color32(255, 105, 170);
        Rim := Color32(255, 185, 215);
        // Flaeche: Herzkurve (x^2 + y^2 - 1)^3 - x^2 y^3 <= 0, y nach oben
        U := -1.25;
        while U <= 1.25 do
        begin
          Vv := -1.15;
          while Vv <= 1.3 do
          begin
            F := Sqr(U * U + Vv * Vv - 1) * (U * U + Vv * Vv - 1) - U * U * Vv * Vv * Vv;
            if F <= 0 then
              AddPixel(Bits, W, H, Round(CX + U * R), Round(CY - Vv * R), Fill, 95);
            Vv := Vv + 0.5 / Max(R, 1);
          end;
          U := U + 0.5 / Max(R, 1);
        end;
        // Kontur (Parameterform) und ein kleiner Glanzpunkt wie bei einer Seifenblase
        for K := 0 to 23 do
        begin
          Ang := K * 2 * Pi / 24;
          X := 16 * Power(Sin(Ang), 3) / 16;
          Y := (13 * Cos(Ang) - 5 * Cos(2 * Ang) - 2 * Cos(3 * Ang) - Cos(4 * Ang)) / 16;
          U := 16 * Power(Sin(Ang + 2 * Pi / 24), 3) / 16;
          Vv := (13 * Cos(Ang + 2 * Pi / 24) - 5 * Cos(2 * (Ang + 2 * Pi / 24)) - 2 * Cos(3 * (Ang + 2 * Pi / 24)) -
            Cos(4 * (Ang + 2 * Pi / 24))) / 16;
          GlowLine(Bits, W, H, CX + X * R * 1.05, CY - Y * R * 1.05 - R * 0.15, CX + U * R * 1.05, CY - Vv * R * 1.05 - R * 0.15, Rim, 150);
        end;
        AddPixel(Bits, W, H, Round(CX - R * 0.45), Round(CY - R * 0.55), $FFFFFFFF, 200);
        AddPixel(Bits, W, H, Round(CX - R * 0.35), Round(CY - R * 0.65), $FFFFFFFF, 120);
      end
      else
      begin
        // Seifenblase platzt: duenner Ring dehnt sich und verblasst, kleine Troepfchen fliegen weg
        A := 170 * (1 - Pop);
        for K := 0 to 17 do
        begin
          Ang := K * 2 * Pi / 18;
          GlowLine(Bits, W, H, CX + Cos(Ang) * R * (1 + 1.3 * Pop), CY + Sin(Ang) * R * (1 + 1.3 * Pop),
            CX + Cos(Ang + 2 * Pi / 18) * R * (1 + 1.3 * Pop), CY + Sin(Ang + 2 * Pi / 18) * R * (1 + 1.3 * Pop),
            Color32(255, 190, 220), Round(A * 0.6));
        end;
        for K := 0 to 5 do
        begin
          Ang := K * 2 * Pi / 6 + Sway;
          AddPixel(Bits, W, H, Round(CX + Cos(Ang) * R * (1.2 + 2.2 * Pop)), Round(CY + Sin(Ang) * R * (1.2 + 2.2 * Pop)),
            Color32(255, 150, 200), Round(A));
        end;
      end;
    end;
end;

procedure TBannerView.DrawHat(Bits: PColor32Array; W, H: Integer);
var
  S, R, Cs, Sn: Single;
  Pt: array[0..5, 0..1] of Single;
  I: Integer;
  C, Fc: TColor32;
  U, Vv: Single;

  procedure P(K: Integer; Dx, Dy: Single);
  begin
    // Hutkoordinaten (Dx quer, Dy nach oben) gedreht um FHatAng, Ursprung = Mitte der Krempe
    Pt[K, 0] := FHatX + Dx * Cs + Dy * Sn;
    Pt[K, 1] := FHatY + Dx * Sn - Dy * Cs;
  end;

begin
  if FHatMode >= 3 then
    Exit;
  S := H * 0.56 / 44.5;
  R := 5.5 * S;
  Cs := Cos(FHatAng); Sn := Sin(FHatAng);
  C := Color32(235, 225, 205);
  // Flaeche: Krone und Krempe dicht mit Pixeln fuellen (in Hutkoordinaten abtasten, ~0,5 px Raster),
  // etwas dunkler als die Kontur -> wirkt wie ein ausgefuellter Zylinder
  U := -R * 0.78;
  while U <= R * 0.78 do
  begin
    Vv := 0;
    while Vv <= R * 1.55 do
    begin
      if (Vv > R * 0.22) and (Vv < R * 0.48) then Fc := Color32(255, 150, 70)     // Hutband
      else Fc := Color32(150, 160, 185);
      AddPixel(Bits, W, H, Round(FHatX + U * Cs + Vv * Sn), Round(FHatY + U * Sn - Vv * Cs), Fc, 70);
      Vv := Vv + 0.5;
    end;
    U := U + 0.5;
  end;
  U := -R * 1.35;
  while U <= R * 1.35 do
  begin
    Vv := -R * 0.14;
    while Vv <= R * 0.1 do
    begin
      AddPixel(Bits, W, H, Round(FHatX + U * Cs + Vv * Sn), Round(FHatY + U * Sn - Vv * Cs), Color32(150, 160, 185), 80);
      Vv := Vv + 0.5;
    end;
    U := U + 0.5;
  end;
  // Zylinder: Krempe breit, Krone schmaler und hoch
  P(0, -R * 1.35, 0);   P(1, R * 1.35, 0);
  P(2, -R * 0.78, 0.1 * R);  P(3, -R * 0.78, R * 1.55);
  P(4, R * 0.78, R * 1.55);  P(5, R * 0.78, 0.1 * R);
  GlowLine(Bits, W, H, Pt[0, 0], Pt[0, 1], Pt[1, 0], Pt[1, 1], C, 200);
  for I := 2 to 4 do
    GlowLine(Bits, W, H, Pt[I, 0], Pt[I, 1], Pt[I + 1, 0], Pt[I + 1, 1], C, 200);
  // Hutband
  P(2, -R * 0.78, R * 0.35); P(3, R * 0.78, R * 0.35);
  GlowLine(Bits, W, H, Pt[2, 0], Pt[2, 1], Pt[3, 0], Pt[3, 1], Color32(255, 170, 90), 170);
end;

{ Bass/Hoehen-Verhaeltnis des Ausgangs (letzte ~23 ms) -> gleitender Mittelwert ueber ~0,75 s;
  in Stille langsam zurueck zur neutralen Farbe }
procedure TBannerView.UpdateTint(Seconds: Double);
const
  N = 1024;
var
  I: Integer;
  Sr, AL, AH, LpL, LpH, X, EL, EH, ET, Raw: Double;
begin
  if Length(FTintBuf) <> N then
  begin
    SetLength(FTintBuf, N);
    SetLength(FTintIn, N);
  end;
  FEngine.GetScope(FTintBuf, FTintIn, N);
  Sr := Max(8000.0, FEngine.SampleRate);
  AL := 1 - Exp(-2 * Pi * 200 / Sr);      // Tiefpass 200 Hz -> Bass
  AH := 1 - Exp(-2 * Pi * 3000 / Sr);     // Signal minus Tiefpass 3 kHz -> Hoehen
  LpL := 0; LpH := 0; EL := 0; EH := 0; ET := 0;
  for I := 0 to N - 1 do
  begin
    X := FTintBuf[I];
    LpL := LpL + (X - LpL) * AL;
    LpH := LpH + (X - LpH) * AH;
    if I >= 64 then                         // Einschwingen der Filter auslassen
    begin
      EL := EL + Sqr(LpL);
      EH := EH + Sqr(X - LpH);
      ET := ET + Sqr(X);
    end;
  end;
  if ET / (N - 64) > Sqr(0.004) then
  begin
    // Hoehen sind in Musik von Natur aus leiser: gewichtet, damit ein ausgewogener Mix etwa 0 ergibt
    EL := Sqrt(EL); EH := 2.8 * Sqrt(EH);
    Raw := (EH - EL) / Max(1E-9, EH + EL);
    FTilt := FTilt + (Raw - FTilt) * Min(1.0, Seconds / 0.75);
  end
  else
    FTilt := FTilt * (1 - Min(1.0, Seconds / 6));
end;

{ Grundfarbe zur Musik hin toenen: bassig -> warmes Rot, hell -> kuehles Blau }
function TBannerView.TintColor(Base: TColor32; Amount: Single): TColor32;
var
  T: Single;
  R, G, B, TR, TG, TB: Integer;
begin
  T := EnsureRange(Abs(FTilt) * 2.2, 0, 1) * Amount;
  if FTilt < 0 then begin TR := 255; TG := 70; TB := 55; end
  else begin TR := 60; TG := 125; TB := 255; end;
  R := (Base shr 16) and $FF; G := (Base shr 8) and $FF; B := Base and $FF;
  Result := Color32(Round(R + (TR - R) * T), Round(G + (TG - G) * T), Round(B + (TB - B) * T));
end;

procedure TBannerView.DrawDancer(Bits: PColor32Array; W, H: Integer);
const
  // Strecken: Hals-Huefte, Arme (Hals->Ellbogen->Hand), Beine (Huefte->Knie->Fuss)
  SEG_A: array[0..8] of Integer = (1, 1, 3, 1, 5, 2, 7, 2, 9);
  SEG_B: array[0..8] of Integer = (2, 3, 4, 5, 6, 7, 8, 9, 10);
var
  G, I, K, A, Rows, PX: Integer;
  R, Ang, S, T, XL, YL, XR, YR, RX, RY, HX: Single;
  C: TColor32;
begin
  if FGhostValid = 0 then
    Exit;
  S := H * 0.56 / 44.5;
  R := 5.5 * S;
  // aelteste Spur zuerst, aktuelle Pose zuletzt (am hellsten, scharf)
  for G := Min(FGhostValid, Length(FGhost)) - 1 downto 0 do
  begin
    if G = 0 then
    begin
      A := 165;                         // gedaempft: ordnet sich ins Bild ein, Koerner ziehen darueber
      C := TintColor(Color32(205, 228, 248), 0.95);   // faerbt sich mit der Musik (Bass rot, Hoehen blau)
    end
    else
    begin
      A := Round(38 * Power(0.55, G - 1) * (0.25 + 0.75 * Max(FDance, FWiggle)));   // dezent: Kontrast bleibt
      if A < 6 then Continue;
      C := TintColor(Color32(110, 190, 255), 0.8);   // Spur kuehler, mitgetoent
    end;
    with FGhost[G] do
    begin
      for I := 0 to High(SEG_A) do
        GlowLine(Bits, W, H, X[SEG_A[I]], Y[SEG_A[I]], X[SEG_B[I]], Y[SEG_B[I]], C, A);
      // Arme und Beine 1 Pixel breiter: zweite Linie quer zur Strecke versetzt
      for I := 1 to High(SEG_A) do
        if Abs(X[SEG_B[I]] - X[SEG_A[I]]) > Abs(Y[SEG_B[I]] - Y[SEG_A[I]]) then
          GlowLine(Bits, W, H, X[SEG_A[I]], Y[SEG_A[I]] + 1, X[SEG_B[I]], Y[SEG_B[I]] + 1, C, A * 3 div 4)
        else
          GlowLine(Bits, W, H, X[SEG_A[I]] + 1, Y[SEG_A[I]], X[SEG_B[I]] + 1, Y[SEG_B[I]], C, A * 3 div 4);
      // zwei Zoepfe
      // je Zopf drei eng nebeneinanderliegende Straehnen -> dicker, geflochtener Eindruck
      for I := 11 to 15 do
      begin
        GlowLine(Bits, W, H, X[I], Y[I], X[I + 1], Y[I + 1], C, A);
        GlowLine(Bits, W, H, X[I] - 0.7 * S, Y[I], X[I + 1] - 0.7 * S, Y[I + 1], C, A * 2 div 3);
        GlowLine(Bits, W, H, X[I] + 0.7 * S, Y[I], X[I + 1] + 0.7 * S, Y[I + 1], C, A * 2 div 3);
      end;
      for I := 17 to 21 do
      begin
        GlowLine(Bits, W, H, X[I], Y[I], X[I + 1], Y[I + 1], C, A);
        GlowLine(Bits, W, H, X[I] - 0.7 * S, Y[I], X[I + 1] - 0.7 * S, Y[I + 1], C, A * 2 div 3);
        GlowLine(Bits, W, H, X[I] + 0.7 * S, Y[I], X[I + 1] + 0.7 * S, Y[I + 1], C, A * 2 div 3);
      end;
      // Glockenrock: von der Taille (knapp ueber der Huefte) zum Saum, Saum als Linie
      // Rock ausgefuellt: Zeilen zwischen Taille und Saum, zarter als die Umrisslinien
      Rows := Max(2, Round(Max(Y[23], Y[24]) - (Y[2] - 2 * S)) * 2);
      for K := 0 to Rows do
      begin
        T := K / Rows;
        XL := X[2] - S + (X[23] - X[2] + S) * T;
        YL := Y[2] - 2 * S + (Y[23] - Y[2] + 2 * S) * T;
        XR := X[2] + S + (X[24] - X[2] - S) * T;
        YR := Y[2] - 2 * S + (Y[24] - Y[2] + 2 * S) * T;
        for PX := Round(XL) to Round(XR) do
          AddPixel(Bits, W, H, PX, Round(YL + (YR - YL) * (PX - XL) / Max(1, XR - XL)), C, A div 4);
      end;
      GlowLine(Bits, W, H, X[2] - S, Y[2] - 2 * S, X[23], Y[23], C, A);
      GlowLine(Bits, W, H, X[2] + S, Y[2] - 2 * S, X[24], Y[24], C, A);
      GlowLine(Bits, W, H, X[23], Y[23], X[24], Y[24], C, A * 3 div 4);
      // Kopf als Ellipse aus 14 Sehnen: nach vorn = groesser, zur Seite gedreht = schmaler
      RY := R * Max(HeadScale, 0.5);
      RX := RY * (1 - 0.14 * Abs(HeadTurn));
      HX := X[0] + HeadTurn * R * 0.12;          // Gesicht wandert leicht zur Drehseite
      for K := 0 to 13 do
      begin
        Ang := K * 2 * Pi / 14;
        GlowLine(Bits, W, H, HX + RX * Cos(Ang), Y[0] + RY * Sin(Ang),
          HX + RX * Cos(Ang + 2 * Pi / 14), Y[0] + RY * Sin(Ang + 2 * Pi / 14), C, A);
      end;
      // Ohr der gedrehten Seite: kleiner Bogen aussen am Kopf, waechst mit der Drehung
      if Abs(HeadTurn) > 0.05 then
      begin
        T := Sign(HeadTurn);
        for K := 0 to 3 do
        begin
          Ang := -Pi / 2 + K * Pi / 4;
          GlowLine(Bits, W, H,
            HX + T * (RX + R * 0.28 * Abs(HeadTurn) * Cos(Ang)), Y[0] + R * 0.34 * Sin(Ang),
            HX + T * (RX + R * 0.28 * Abs(HeadTurn) * Cos(Ang + Pi / 4)), Y[0] + R * 0.34 * Sin(Ang + Pi / 4),
            C, A * 3 div 4);
        end;
      end;
    end;
  end;
end;

procedure TBannerView.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, I, PX, PY, Alpha, Dx, Dy, BandX: Integer;
  Mid, Amp, Wave, Spread, Turb, XX, BL, OX, OY, PXF, Ease, Fade: Single;
  C: TColor32;
  Bits: PColor32Array;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  if (W < 8) or (H < 8) then
  begin
    inherited;
    Exit;
  end;
  if (FCacheW <> W) or (FCacheH <> H) then
    BuildCaches;
  FBack.DrawTo(B, 0, 0);
  // je lauter der Sidechain, desto heller der Hintergrund (kuehler Blauton);
  // doppelte Staerke: volle Helligkeit schon bei halbem Pegel
  if FScLevel > 0.01 then
    B.FillRectTS(0, 0, W, H, Color32(70, 110, 190, Round(EnsureRange(FScLevel * 2, 0, 1) * 170)));

  // Taenzer zuerst: Koerner und Lichtimpuls ziehen ueber ihn hinweg
  DrawDancer(B.Bits, W, H);
  DrawHat(B.Bits, W, H);
  DrawHearts(B.Bits, W, H);

  // Koernerwolke als zwei verwobene, wandernde Wellen; Pegel macht sie hoeher, heller, unruhiger
  Mid := H * 0.52;
  Amp := H * (0.18 + 0.30 * FLevel);
  Spread := H * (0.13 + 0.10 * FLevel);
  Turb := 0.6 + 4.0 * FLevel;
  Bits := B.Bits;
  for I := 0 to High(FGrains) do
    with FGrains[I] do
    begin
      XX := X + FTime * Speed;
      XX := XX - Floor(XX);
      if Layer = 0 then
        Wave := FastSin(XX * 2 * Pi * 1.5 + FTime * 0.7) * 0.65 + FastSin(XX * 2 * Pi * 3.7 - FTime * 1.1) * 0.35
      else
        Wave := (FastSin(XX * 2 * Pi * 1.2 - FTime * 0.5 + 1.8) * 0.7 + FastSin(XX * 2 * Pi * 4.3 + FTime * 0.9) * 0.3) * 0.8;
      if FGhostValid > 0 then
      begin
        // Wolke stroemt vom Taenzer aus: je ein Teil aus linker Hand, rechter Hand und Koerper,
        // alle nach links; der Ursprung folgt der Pose, die Welle baut sich erst auf
        with FGhost[0] do
          case I mod 3 of
            0: begin OX := X[4]; OY := Y[4]; end;
            1: begin OX := X[6]; OY := Y[6]; end;
          else
            OX := (X[1] + X[2]) * 0.5; OY := (Y[1] + Y[2]) * 0.5;
          end;
        PXF := OX - XX * (OX + 4);             // nur nach links
        Ease := Min(1.0, XX * 3.5);
        Ease := Ease * (2 - Ease);
      end
      else
      begin
        PXF := XX * (W - 1); OY := Mid; Ease := 1;
      end;
      PX := Round(PXF);
      // Frequenzband an dieser Stelle: laute Baender schwingen weiter aus und leuchten heller
      BL := FBandLvl[EnsureRange(Trunc(PXF / W * 31.99), 0, 31)];
      PY := Round(OY + (Mid - OY + Wave * Amp * (0.8 + 0.55 * BL) + Band * Spread * (0.9 + 0.4 * BL)) * Ease +
        FastSin(Phase + FTime * Turb) * (2.5 + 3 * (1 - Ease) * FDance));
      Alpha := Min(255, Round(Bright * (0.55 + 0.3 * FLevel + 0.55 * BL) * (1 - Abs(Band) * 0.45)));
      // vom Taenzer weg langsam einblenden: am Ursprung unsichtbar, mit der Entfernung kraeftiger
      if FGhostValid > 0 then
      begin
        Fade := Min(1.0, XX / 0.075);
        Alpha := Round(Alpha * Fade * Fade * (3 - 2 * Fade));
        if Alpha < 3 then Continue;
      end;
      // Schrift freihalten: zum Schriftbereich hin auf kurzer Strecke ausblenden
      if (PX >= 0) and (PX < W) and (PY >= 0) and (PY < H) and (FTitleFade[PY * W + PX] < 255) then
      begin
        Fade := FTitleFade[PY * W + PX] / 255;
        Alpha := Round(Alpha * Fade * Fade);
        if Alpha < 3 then Continue;
      end;
      C := GrainColor(EnsureRange(PXF / W, 0, 1), 255);
      if Glow then
        for Dy := -2 to 2 do
          for Dx := -2 to 2 do
            AddPixel(Bits, W, H, PX + Dx, PY + Dy, C, Alpha div 7);
      AddPixel(Bits, W, H, PX, PY, C, Alpha);
      if Size > 1 then
      begin
        AddPixel(Bits, W, H, PX - 1, PY, C, Alpha div 2);
        AddPixel(Bits, W, H, PX + 1, PY, C, Alpha div 2);
        AddPixel(Bits, W, H, PX, PY - 1, C, Alpha div 2);
        AddPixel(Bits, W, H, PX, PY + 1, C, Alpha div 2);
      end;
    end;

  // Lichtimpuls: weiches Band, das einmal von links nach rechts durchs Banner laeuft
  if FFlash > 0 then
  begin
    BandX := Round((1 - FFlash) * (W + 160)) - 80;
    for Dx := -60 to 60 do
    begin
      Alpha := Round(150 * FFlash * Exp(-Sqr(Dx / 24)));
      if Alpha > 2 then
        B.VertLineTS(BandX + Dx, 0, H - 1, Color32(190, 235, 255, Alpha));
    end;
  end;
  // Schrift nur im Schriftbereich mischen statt ueber das ganze Banner
  B.Draw(FTitleRect.Left, FTitleRect.Top, FTitleRect, FTitle);
  ApplyContrast(B);
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

initialization
  InitSinTab;

end.
