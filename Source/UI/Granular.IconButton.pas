{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.IconButton;

{ Knopf mit gezeichnetem Symbol (Graphics32, geglaettet) im dunklen Look des Plugins - fuer das Fenster
  "Audio bearbeiten". Symbol links, Text rechts daneben (ohne Text: Symbol mittig). Active = Knopf
  leuchtet (z.B. laufende Aufnahme). Keine Bilddateien: alle Symbole sind Vektoren. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math, System.Types,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms,
  GR32, GR32_Polygons, GR32_VectorUtils;   // kein GDI+: dessen Start beim Laden einer DLL ist riskant

type
  TEdIcon = (eiNone, eiOpen, eiPlay, eiStop, eiRec, eiSelAll, eiZoomIn, eiZoomOut, eiZoomFit, eiCrop, eiDelete,
    eiFadeIn, eiFadeOut, eiNormalize, eiTrim, eiReverse, eiUndo, eiOk, eiCancel,
    eiPrev, eiNext, eiStar, eiStarFull, eiSave, eiInfo, eiHelp, eiPencil, eiDice, eiTrash, eiBookmark, eiSwap,
    eiPanic, eiKeys, eiRedo);

  TIconButton = class(TCustomControl)
  private
    FIcon: TEdIcon;
    FHover, FPressed, FActive: Boolean;
    FModalResult: TModalResult;
    procedure SetIcon(V: TEdIcon);
    procedure SetActive(V: Boolean);
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMTextChanged(var Msg: TMessage); message CM_TEXTCHANGED;
    procedure CMEnabledChanged(var Msg: TMessage); message CM_ENABLEDCHANGED;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Icon: TEdIcon read FIcon write SetIcon;
    property Active: Boolean read FActive write SetActive;
    property ModalResult: TModalResult read FModalResult write FModalResult;
    property Caption;
    property OnClick;
    property Font;
  end;

{ Symbol mit Kantenlaenge S an (X, Y) in einen Geraetekontext zeichnen - der Hintergrund bleibt erhalten
  (fuer die Owner-Draw-Knoepfe der Plugin-Oberflaeche) }
procedure PaintIcon(DC: HDC; X, Y, S: Integer; Icon: TEdIcon; Active: Boolean = False; Dim: Boolean = False;
  Hot: Boolean = False);

implementation

const
  COL_FACE   = $00423C38;
  COL_HOVER  = $00544C47;
  COL_DOWN   = $00302B28;
  COL_EDGE   = $00605852;
  COL_TEXT   = $00DCDCDC;
  ICO_AMBER  = $0048A0DC;   // Bernstein (BGR) wie Lampen, Huellkurven, Schrittmuster
  ICO_AMBER_D = $00387EB0;  // dunkler Ton fuer Rueckseiten
  ICO_DEEP   = $00286A9C;   // tiefes Bernstein: Flaechen mit heller Schrift darauf (Speichern, Info, Hilfe)
  ICO_WARMRED = $003A5AC8;  // gedaempftes, warmes Orangerot (Stopp/Panik)

constructor TIconButton.Create(AOwner: TComponent);
begin
  inherited;
  // csClickEvents raus: Click kommt allein aus MouseUp - sonst loest die VCL ihn zusaetzlich aus,
  // und Umschalter wie Abspielen/Stopp springen sofort zurueck
  ControlStyle := ControlStyle + [csOpaque] - [csDoubleClicks, csClickEvents];
  DoubleBuffered := True;
  Width := 100;
  Height := 27;
  TabStop := False;
  Font.Color := COL_TEXT;
end;

procedure TIconButton.SetIcon(V: TEdIcon);
begin
  FIcon := V;
  Invalidate;
end;

procedure TIconButton.SetActive(V: Boolean);
begin
  if FActive <> V then
  begin
    FActive := V;
    Invalidate;
  end;
end;

procedure TIconButton.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FHover := True;
  Invalidate;
end;

procedure TIconButton.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHover := False;
  FPressed := False;
  Invalidate;
end;

procedure TIconButton.CMTextChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TIconButton.CMEnabledChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TIconButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
end;

procedure TIconButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  WasDown: Boolean;
begin
  WasDown := FPressed;
  FPressed := False;
  Invalidate;
  inherited;
  if WasDown and (Button = mbLeft) and Winapi.Windows.PtInRect(ClientRect, System.Types.Point(X, Y)) and Enabled then
    Click;
end;

procedure TIconButton.Click;
var
  F: TCustomForm;
begin
  inherited;
  if FModalResult <> mrNone then
  begin
    F := GetParentForm(Self);
    if F <> nil then
      F.ModalResult := FModalResult;
  end;
end;

{ Symbol in ein Bitmap der Kantenlaenge S zeichnen (Hintergrund ist schon gefuellt) }
procedure DrawIcon(B: TBitmap32; Icon: TEdIcon; S: Single; Active, Dim: Boolean);
var
  Fg: TColor32;
  W: Single;

  function P(PX, PY: Single): TFloatPoint;
  begin
    Result := FloatPoint(PX * S, PY * S);
  end;

  function Col(C: TColor; A: Byte = 255): TColor32;
  begin
    Result := SetAlpha(Color32(C), A);
  end;

  procedure Line(X1, Y1, X2, Y2: Single; C: TColor32);
  begin
    PolylineFS(B, [P(X1, Y1), P(X2, Y2)], C, False, W, jsRound, esRound);
  end;

  procedure Fill(const Pts: array of TFloatPoint; C: TColor32);
  var
    A: TArrayOfFloatPoint;
    I: Integer;
  begin
    SetLength(A, Length(Pts));
    for I := 0 to High(Pts) do
      A[I] := Pts[I];
    PolygonFS(B, A, C);
  end;

  procedure Box(X0, Y0, X1, Y1: Single; C: TColor32);
  begin
    Fill([P(X0, Y0), P(X1, Y0), P(X1, Y1), P(X0, Y1)], C);
  end;

  procedure Ring(CX, CY, R: Single; C: TColor32);
  begin
    PolylineFS(B, Circle(CX * S, CY * S, R * S, 32), C, True, W);
  end;

  procedure Lens(Plus: Integer);   // 1 = plus, -1 = minus
  begin
    W := S * 0.1;
    Ring(0.4, 0.4, 0.29, Fg);
    W := S * 0.16;
    Line(0.63, 0.63, 0.88, 0.88, Fg);
    W := S * 0.09;
    Line(0.26, 0.4, 0.54, 0.4, Fg);
    if Plus > 0 then
      Line(0.4, 0.26, 0.4, 0.54, Fg);
  end;

var
  I: Integer;
  Arc: TArrayOfFloatPoint;
  Ang: Single;
begin
  // Grundfarbe der Symbole: Bernstein wie im ganzen Geraet (weniger Kontrast als Weiss);
  // aktiv = helles Bernstein
  if Dim then Fg := Col($00808080) else if Active and (Icon <> eiRec) then Fg := Col($0070C8FF)
  else Fg := Col(ICO_AMBER);
  W := S * 0.1;
  case Icon of
    eiPlay: Fill([P(0.22, 0.12), P(0.88, 0.5), P(0.22, 0.88)], Col($0060D878));
    eiStop: Box(0.2, 0.2, 0.8, 0.8, Fg);
    eiRec:
      begin
        if Active then
        begin
          PolygonFS(B, Circle(0.5 * S, 0.5 * S, 0.47 * S, 32), Col($006060FF, 90));
          PolygonFS(B, Circle(0.5 * S, 0.5 * S, 0.38 * S, 32), Col($003C3CFF));
        end
        else
          PolygonFS(B, Circle(0.5 * S, 0.5 * S, 0.38 * S, 32), Col($002828D0));
      end;
    eiOpen:
      begin
        Fill([P(0.05, 0.22), P(0.4, 0.22), P(0.5, 0.32), P(0.95, 0.32), P(0.95, 0.85), P(0.05, 0.85)], Col(ICO_AMBER_D));
        Box(0.05, 0.42, 0.95, 0.85, Col(ICO_AMBER));
      end;
    eiSelAll:
      begin
        W := S * 0.08;
        for I := 0 to 3 do
        begin
          Line(0.1 + I * 0.22, 0.18, 0.2 + I * 0.22, 0.18, Fg);
          Line(0.1 + I * 0.22, 0.82, 0.2 + I * 0.22, 0.82, Fg);
        end;
        Line(0.1, 0.32, 0.1, 0.42, Fg); Line(0.1, 0.58, 0.1, 0.68, Fg);
        Line(0.9, 0.32, 0.9, 0.42, Fg); Line(0.9, 0.58, 0.9, 0.68, Fg);
      end;
    eiZoomIn: Lens(1);
    eiZoomOut: Lens(-1);
    eiZoomFit:
      begin
        W := S * 0.09;
        Line(0.14, 0.5, 0.86, 0.5, Fg);
        Line(0.14, 0.5, 0.32, 0.34, Fg); Line(0.14, 0.5, 0.32, 0.66, Fg);
        Line(0.86, 0.5, 0.68, 0.34, Fg); Line(0.86, 0.5, 0.68, 0.66, Fg);
        Line(0.04, 0.15, 0.04, 0.85, Fg); Line(0.96, 0.15, 0.96, 0.85, Fg);
      end;
    eiCrop:
      begin
        Line(0.28, 0.05, 0.28, 0.72, Fg); Line(0.28, 0.72, 0.95, 0.72, Fg);
        Line(0.05, 0.28, 0.72, 0.28, Fg); Line(0.72, 0.28, 0.72, 0.95, Fg);
      end;
    eiDelete:
      begin
        W := S * 0.13;
        Line(0.22, 0.22, 0.78, 0.78, Col($006A6AF0)); Line(0.78, 0.22, 0.22, 0.78, Col($006A6AF0));
      end;
    eiFadeIn: Fill([P(0.05, 0.85), P(0.95, 0.15), P(0.95, 0.85)], Col($0080C878));
    eiFadeOut: Fill([P(0.05, 0.15), P(0.95, 0.85), P(0.05, 0.85)], Col($0080C878));
    eiNormalize:
      begin
        W := S * 0.08;
        Line(0.05, 0.1, 0.95, 0.1, Col($005AD2FF));
        Box(0.12, 0.55, 0.3, 0.9, Col($0080C878));
        Box(0.41, 0.32, 0.59, 0.9, Col($0080C878));
        Box(0.7, 0.2, 0.88, 0.9, Col($0080C878));
      end;
    eiTrim:
      begin
        Line(0.12, 0.1, 0.12, 0.9, Fg); Line(0.88, 0.1, 0.88, 0.9, Fg);
        Box(0.26, 0.34, 0.74, 0.66, Col($0080C878));
      end;
    eiReverse:
      begin
        W := S * 0.09;
        Line(0.1, 0.32, 0.88, 0.32, Fg); Line(0.88, 0.32, 0.7, 0.16, Fg); Line(0.88, 0.32, 0.7, 0.48, Fg);
        Line(0.9, 0.7, 0.12, 0.7, Fg); Line(0.12, 0.7, 0.3, 0.54, Fg); Line(0.12, 0.7, 0.3, 0.86, Fg);
      end;
    eiUndo, eiRedo:
      begin
        // Bogen von links oben im Uhrzeigersinn nach rechts unten, Pfeilspitze links (Redo gespiegelt)
        SetLength(Arc, 21);
        for I := 0 to 20 do
        begin
          Ang := Pi + I / 20 * 1.35 * Pi;
          Arc[I] := FloatPoint((0.52 + 0.32 * Cos(Ang)) * S, (0.55 + 0.3 * Sin(Ang)) * S);
          if Icon = eiRedo then Arc[I].X := S - Arc[I].X;
        end;
        PolylineFS(B, Arc, Fg, False, W, jsRound, esRound);
        if Icon = eiUndo then
          Fill([P(0.04, 0.42), P(0.36, 0.42), P(0.2, 0.7)], Fg)
        else
          Fill([P(0.96, 0.42), P(0.64, 0.42), P(0.8, 0.7)], Fg);
      end;
    eiOk:
      begin
        W := S * 0.14;
        Line(0.12, 0.52, 0.4, 0.8, Col($0060D878)); Line(0.4, 0.8, 0.9, 0.22, Col($0060D878));
      end;
    eiCancel:
      begin
        W := S * 0.12;
        Line(0.24, 0.24, 0.76, 0.76, Fg); Line(0.76, 0.24, 0.24, 0.76, Fg);
      end;
    eiPrev: Fill([P(0.7, 0.15), P(0.3, 0.5), P(0.7, 0.85)], Fg);
    eiNext: Fill([P(0.3, 0.15), P(0.7, 0.5), P(0.3, 0.85)], Fg);
    eiStar, eiStarFull:
      begin
        SetLength(Arc, 10);
        for I := 0 to 9 do
        begin
          Ang := -Pi / 2 + I * Pi / 5;
          if I mod 2 = 0 then W := 0.47 else W := 0.2;
          Arc[I] := FloatPoint((0.5 + W * Cos(Ang)) * S, (0.54 + W * Sin(Ang)) * S);
        end;
        if Icon = eiStarFull then
          PolygonFS(B, Arc, Col($0040C8FF))
        else
          PolylineFS(B, Arc, Fg, True, S * 0.08, jsRound);
      end;
    eiSave:
      begin
        Fill([P(0.1, 0.1), P(0.78, 0.1), P(0.9, 0.22), P(0.9, 0.9), P(0.1, 0.9)], Col(ICO_DEEP));
        Box(0.26, 0.1, 0.68, 0.36, Col($00F0E6DC));
        Box(0.24, 0.55, 0.76, 0.9, Col($00403830));
      end;
    eiInfo, eiHelp:
      begin
        PolygonFS(B, Circle(0.5 * S, 0.5 * S, 0.45 * S, 32), Col(ICO_DEEP));
        W := S * 0.13;
        if Icon = eiInfo then
        begin
          PolygonFS(B, Circle(0.5 * S, 0.27 * S, 0.08 * S, 12), Col($00FFFFFF));
          Line(0.5, 0.45, 0.5, 0.76, Col($00FFFFFF));
        end
        else
        begin
          SetLength(Arc, 13);
          for I := 0 to 12 do
          begin
            Ang := Pi + I / 12 * 1.5 * Pi;
            Arc[I] := FloatPoint((0.5 + 0.17 * Cos(Ang)) * S, (0.37 + 0.15 * Sin(Ang)) * S);
          end;
          PolylineFS(B, Arc, Col($00FFFFFF), False, S * 0.12, jsRound, esRound);
          Line(0.5, 0.52, 0.5, 0.6, Col($00FFFFFF));
          PolygonFS(B, Circle(0.5 * S, 0.77 * S, 0.075 * S, 12), Col($00FFFFFF));
        end;
      end;
    eiPencil:
      begin
        Fill([P(0.7, 0.1), P(0.9, 0.3), P(0.35, 0.85), P(0.15, 0.65)], Col(ICO_AMBER));
        Fill([P(0.15, 0.65), P(0.35, 0.85), P(0.08, 0.92)], Fg);
      end;
    eiDice:
      begin
        Fill([P(0.12, 0.12), P(0.88, 0.12), P(0.88, 0.88), P(0.12, 0.88)], Fg);
        PolygonFS(B, Circle(0.32 * S, 0.32 * S, 0.08 * S, 12), Col($00302A26));
        PolygonFS(B, Circle(0.5 * S, 0.5 * S, 0.08 * S, 12), Col($00302A26));
        PolygonFS(B, Circle(0.68 * S, 0.68 * S, 0.08 * S, 12), Col($00302A26));
      end;
    eiTrash:
      begin
        W := S * 0.08;
        Line(0.15, 0.24, 0.85, 0.24, Col(ICO_AMBER));
        Line(0.4, 0.12, 0.6, 0.12, Col(ICO_AMBER));
        Fill([P(0.24, 0.32), P(0.76, 0.32), P(0.7, 0.9), P(0.3, 0.9)], Col(ICO_AMBER_D));
      end;
    eiBookmark: Fill([P(0.25, 0.08), P(0.75, 0.08), P(0.75, 0.92), P(0.5, 0.7), P(0.25, 0.92)], Col(ICO_AMBER));
    eiSwap:
      begin
        W := S * 0.09;
        Line(0.12, 0.32, 0.86, 0.32, Fg); Line(0.86, 0.32, 0.68, 0.16, Fg); Line(0.86, 0.32, 0.68, 0.48, Fg);
        Line(0.88, 0.7, 0.14, 0.7, Fg); Line(0.14, 0.7, 0.32, 0.54, Fg); Line(0.14, 0.7, 0.32, 0.86, Fg);
      end;
    eiPanic:
      begin
        // Achteck (Stoppschild)
        SetLength(Arc, 8);
        for I := 0 to 7 do
        begin
          Ang := Pi / 8 + I * Pi / 4;
          Arc[I] := FloatPoint((0.5 + 0.46 * Cos(Ang)) * S, (0.5 + 0.46 * Sin(Ang)) * S);
        end;
        PolygonFS(B, Arc, Col(ICO_WARMRED));
        Box(0.24, 0.44, 0.76, 0.56, Col($00F0E8E0));
      end;
    eiKeys:
      begin
        Box(0.08, 0.15, 0.92, 0.85, Fg);
        for I := 1 to 3 do
          Box(0.08 + I * 0.21 - 0.02, 0.15, 0.08 + I * 0.21 + 0.02, 0.85, Col($00302A26));
        for I := 0 to 2 do
          Box(0.08 + (I + 1) * 0.21 - 0.06, 0.15, 0.08 + (I + 1) * 0.21 + 0.06, 0.55, Col($00302A26));
      end;
  end;
end;

procedure PaintIcon(DC: HDC; X, Y, S: Integer; Icon: TEdIcon; Active, Dim, Hot: Boolean);
var
  Bmp: TBitmap32;
begin
  if (Icon = eiNone) or (S < 4) then
    Exit;
  Bmp := TBitmap32.Create;
  try
    Bmp.SetSize(S, S);
    // vorhandenen Hintergrund uebernehmen, darauf geglaettet zeichnen, zurueckkopieren
    BitBlt(Bmp.Canvas.Handle, 0, 0, S, S, DC, X, Y, SRCCOPY);
    Bmp.ResetAlpha;
    DrawIcon(Bmp, Icon, S, Active or Hot, Dim);
    Bmp.DrawTo(DC, X, Y);
  finally
    Bmp.Free;
  end;
end;

procedure TIconButton.Paint;
var
  R, TR: TRect;
  Face: TColor;
  Bmp: TBitmap32;
  S, IX, IY: Integer;
  Txt: string;
begin
  R := ClientRect;
  if FPressed then Face := COL_DOWN
  else if FActive and (FIcon = eiRec) then Face := $00302A50
  else if FHover and Enabled then Face := COL_HOVER
  else Face := COL_FACE;
  Canvas.Brush.Color := Parent.Brush.Color;
  Canvas.FillRect(R);
  Canvas.Brush.Color := Face;
  Canvas.Pen.Color := COL_EDGE;
  Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);
  // leichter Glanz oben
  Canvas.Pen.Color := $00686058;
  Canvas.MoveTo(R.Left + 3, R.Top + 1);
  Canvas.LineTo(R.Right - 3, R.Top + 1);

  Txt := Caption;
  S := Min(Height - 10, 18);
  if Txt = '' then IX := (Width - S) div 2 else IX := 8;
  IY := (Height - S) div 2;
  if FPressed then
  begin
    Inc(IX);
    Inc(IY);
  end;
  if FIcon <> eiNone then
  begin
    Bmp := TBitmap32.Create;
    try
      Bmp.SetSize(S, S);
      Bmp.Clear(Color32(Face));
      DrawIcon(Bmp, FIcon, S, FActive, not Enabled);
      Bmp.DrawTo(Canvas.Handle, IX, IY);
    finally
      Bmp.Free;
    end;
  end;
  if Txt <> '' then
  begin
    Canvas.Font := Font;
    if not Enabled then Canvas.Font.Color := $00808080;
    Canvas.Brush.Style := bsClear;
    TR := R;
    if FIcon <> eiNone then TR.Left := IX + S + 6 else TR.Left := 6;
    TR.Right := R.Right - 4;
    if FPressed then Winapi.Windows.OffsetRect(TR, 1, 1);
    DrawText(Canvas.Handle, PChar(Txt), -1, TR, DT_SINGLELINE or DT_VCENTER or DT_LEFT or DT_END_ELLIPSIS);
    Canvas.Brush.Style := bsSolid;
  end;
end;

end.
