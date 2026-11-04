{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Keyboard;

{ Bildschirmklaviatur (Graphics32). Spielbar mit der Maus; zeigt zusaetzlich die
  ueber die PC-Tastatur gespielten Noten und den Bereich der PC-Tastatur an. }

interface

uses
  Granular.Lang,
  System.Classes, System.SysUtils, System.Math, System.Types,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics,
  GR32, GR32_Image, Granular.Prof;

type
  TKeyNoteEvent = procedure(Sender: TObject; Note: Integer; IsOn: Boolean) of object;

  TKeyboardView = class(TCustomPaintBox32)
  private
    FFirstNote: Integer;
    FOctaves: Integer;
    FPressed: array[0..127] of Boolean;
    FSounding: array[0..127] of Byte;   // vom Plugin verarbeitet: Leuchtstaerke 0..255 (Velocity)
    FGlow: array[0..127] of Single;     // Leuchtstaerke 0..1, glimmt nach dem Loslassen weich aus
    FLabels: TBitmap32;                 // Notennamen (C2, C3 ...) einmal gerendert, dann nur eingeblendet
    FMouseNote: Integer;
    FPcBase: Integer;   // erste Note der PC-Tastatur
    FPcRange: Integer;
    FOnNote: TKeyNoteEvent;
    function WhiteCount: Integer;
    function NoteAt(X, Y: Integer): Integer;
    procedure KeyRect(Note: Integer; out X0, X1, Y1: Integer; out Black: Boolean);
    procedure SetMouseNote(Note: Integer);
  protected
    procedure DoPaintBuffer; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetPressed(Note: Integer; Value: Boolean);
    procedure SetPcRange(BaseNote, Count: Integer);
    { klingende Noten der Engine; zeichnet nur neu, wenn sich etwas geaendert hat }
    procedure SetSounding(const States: array of Byte);
    property OnNote: TKeyNoteEvent read FOnNote write FOnNote;
  end;

  { Rad neben der Klaviatur (Pitchbend / Modrad), senkrecht, mit der Maus ziehen.
    SpringBack: beim Loslassen in etwa 0,1 s weich zurueck zur Mitte }
  TWheelView = class(TCustomControl)
  private
    FValue: Single;                  // Pitchbend -1..1, Modrad 0..1
    FSpringBack, FDragging: Boolean;
    FCaption: string;
    FTimer: TTimer;
    FOnChange: TNotifyEvent;
    procedure SetFromY(Y: Integer);
    procedure SpringTick(Sender: TObject);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent; const ACaption: string; ASpringBack: Boolean); reintroduce;
    property Value: Single read FValue;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

function NoteName(Note: Integer): string;

implementation

const
  IS_BLACK: array[0..11] of Boolean =
    (False, True, False, True, False, False, True, False, True, False, True, False);
  WHITE_INDEX: array[0..11] of Integer = (0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6);
  NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'H');

destructor TKeyboardView.Destroy;
begin
  FLabels.Free;
  inherited;
end;

function NoteName(Note: Integer): string;
begin
  Result := NAMES[Note mod 12] + IntToStr(Note div 12 - 1);
end;

constructor TKeyboardView.Create(AOwner: TComponent);
begin
  inherited;
  BufferOversize := 0;   // Puffer = Controlgroesse (Standard waere +40 px)
  FFirstNote := 36;  // C2
  FOctaves := 5;
  FMouseNote := -1;
end;

function TKeyboardView.WhiteCount: Integer;
begin
  Result := FOctaves * 7 + 1;
end;

procedure TKeyboardView.KeyRect(Note: Integer; out X0, X1, Y1: Integer; out Black: Boolean);
var
  Rel, Oct, Semi, WI: Integer;
  WW: Double;
begin
  Rel := Note - FFirstNote;
  Oct := Rel div 12;
  Semi := Rel mod 12;
  WW := Width / WhiteCount;
  WI := Oct * 7 + WHITE_INDEX[Semi];
  Black := IS_BLACK[Semi];
  if Black then
  begin
    X0 := Round((WI + 1) * WW - WW * 0.3);
    X1 := Round((WI + 1) * WW + WW * 0.3);
    Y1 := Round(Height * 0.6);
  end
  else
  begin
    X0 := Round(WI * WW);
    X1 := Round((WI + 1) * WW);
    Y1 := Height;
  end;
end;

function TKeyboardView.NoteAt(X, Y: Integer): Integer;
var
  N, X0, X1, Y1: Integer;
  Black: Boolean;
  Last: Integer;
begin
  Result := -1;
  Last := FFirstNote + FOctaves * 12;
  // schwarze Tasten liegen oben -> zuerst pruefen
  for N := FFirstNote to Last do
  begin
    KeyRect(N, X0, X1, Y1, Black);
    if Black and (X >= X0) and (X < X1) and (Y < Y1) then
      Exit(N);
  end;
  for N := FFirstNote to Last do
  begin
    KeyRect(N, X0, X1, Y1, Black);
    if not Black and (X >= X0) and (X < X1) then
      Exit(N);
  end;
end;

function Mix(A, B: TColor32; T: Single): TColor32;
var
  W: Integer;

  function Ch(Shift: Integer): TColor32;
  begin
    Result := TColor32((Integer((A shr Shift) and $FF) * (255 - W) + Integer((B shr Shift) and $FF) * W) div 255);
  end;

begin
  W := Round(EnsureRange(T, 0, 1) * 255);
  Result := $FF000000 or (Ch(16) shl 16) or (Ch(8) shl 8) or Ch(0);
end;

procedure TKeyboardView.DoPaintBuffer;
var
  B: TBitmap32;
  N, X0, X1, Y1, Last: Integer;
  Black: Boolean;
  Col: TColor32;
begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  B.Clear(Color32(40, 40, 44));
  Last := FFirstNote + FOctaves * 12;

  for N := FFirstNote to Last do
  begin
    KeyRect(N, X0, X1, Y1, Black);
    if Black then Continue;
    if FPressed[N] then Col := Color32(255, 200, 60)
    else Col := Mix(Color32(235, 235, 230), Color32(90, 200, 255), FGlow[N]);
    B.FillRectS(X0 + 1, 0, X1, Y1 - 1, Col);
    if (N >= FPcBase) and (N < FPcBase + FPcRange) then
      B.FillRectS(X0 + 1, Y1 - 5, X1, Y1 - 1, Color32(90, 160, 220));

  end;
  for N := FFirstNote to Last do
  begin
    KeyRect(N, X0, X1, Y1, Black);
    if not Black then Continue;
    if FPressed[N] then Col := Color32(220, 160, 30)
    else Col := Mix(Color32(30, 30, 34), Color32(40, 170, 240), FGlow[N]);
    B.FillRectS(X0, 0, X1, Y1, Col);
    if (N >= FPcBase) and (N < FPcBase + FPcRange) then
      B.FillRectS(X0 + 1, Y1 - 4, X1 - 1, Y1, Color32(90, 160, 220));
  end;
  // Notennamen: einmal je Groesse rendern, danach nur noch einblenden (kein GDI-Text je Bild)
  if (FLabels = nil) or (FLabels.Width <> B.Width) or (FLabels.Height <> B.Height) then
  begin
    if FLabels = nil then
    begin
      FLabels := TBitmap32.Create;
      FLabels.DrawMode := dmBlend;
    end;
    FLabels.SetSize(B.Width, B.Height);
    FLabels.Clear(0);
    FLabels.Font.Name := 'Tahoma';
    FLabels.Font.Size := UiPt(7);
    for N := FFirstNote to Last do
      if N mod 12 = 0 then
      begin
        KeyRect(N, X0, X1, Y1, Black);
        FLabels.RenderText(X0 + 3, Y1 - 20, NoteName(N), 0, $FF505050);
      end;
  end;
  // nur die kleinen Beschriftungsflaechen einblenden, nicht die ganze Klaviatur
  for N := FFirstNote to Last do
    if N mod 12 = 0 then
    begin
      KeyRect(N, X0, X1, Y1, Black);
      B.Draw(X0 + 2, Y1 - 21, Rect(X0 + 2, Y1 - 21, X0 + 28, Y1 - 6), FLabels);
    end;
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

procedure TKeyboardView.SetPressed(Note: Integer; Value: Boolean);
begin
  if (Note >= 0) and (Note <= 127) and (FPressed[Note] <> Value) then
  begin
    FPressed[Note] := Value;
    ForceFullInvalidate;
  end;
end;

procedure TKeyboardView.SetSounding(const States: array of Byte);
var
  N: Integer;
  Changed: Boolean;
  Target, G: Single;
begin
  Changed := False;
  for N := 0 to Min(High(States), 127) do
  begin
    FSounding[N] := States[N];
    // Ziel: gehalten = voll, Release = halb, still = aus; Anstieg sofort, Abklingen weich
    Target := States[N] / 255;   // Helligkeit folgt der Velocity der Note
    if Target >= FGlow[N] then
      G := Target
    else
      G := Max(Target, FGlow[N] * 0.82);
    if G < 0.02 then
      G := 0;
    if G <> FGlow[N] then
    begin
      FGlow[N] := G;
      Changed := True;
    end;
  end;
  if Changed then
    ForceFullInvalidate;
end;

procedure TKeyboardView.SetPcRange(BaseNote, Count: Integer);
begin
  FPcBase := BaseNote;
  FPcRange := Count;
  ForceFullInvalidate;
end;

procedure TKeyboardView.SetMouseNote(Note: Integer);
begin
  if Note = FMouseNote then
    Exit;
  if (FMouseNote >= 0) and Assigned(FOnNote) then
    FOnNote(Self, FMouseNote, False);
  FMouseNote := Note;
  if (FMouseNote >= 0) and Assigned(FOnNote) then
    FOnNote(Self, FMouseNote, True);
end;

procedure TKeyboardView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
    SetMouseNote(NoteAt(X, Y));
end;

procedure TKeyboardView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if ssLeft in Shift then
    SetMouseNote(NoteAt(X, Y));
end;

procedure TKeyboardView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
    SetMouseNote(-1);
end;

{ TWheelView }

constructor TWheelView.Create(AOwner: TComponent; const ACaption: string; ASpringBack: Boolean);
begin
  inherited Create(AOwner);
  FCaption := ACaption;
  FSpringBack := ASpringBack;
  DoubleBuffered := True;
  ShowHint := True;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 15;
  FTimer.OnTimer := SpringTick;
end;

procedure TWheelView.SetFromY(Y: Integer);
var
  T: Single;
begin
  T := 1 - EnsureRange((Y - 4) / Max(1, ClientHeight - 8), 0, 1);   // oben = 1
  if FSpringBack then T := T * 2 - 1;
  if Abs(T - FValue) > 1e-4 then
  begin
    FValue := T;
    Invalidate;
    if Assigned(FOnChange) then FOnChange(Self);
  end;
end;

procedure TWheelView.SpringTick(Sender: TObject);
begin
  // ~0,1 s weich zur Mitte: je Takt (15 ms) gut ein Drittel des Restwegs
  FValue := FValue * 0.6;
  if Abs(FValue) < 0.004 then
  begin
    FValue := 0;
    FTimer.Enabled := False;
  end;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

procedure TWheelView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then Exit;
  FTimer.Enabled := False;
  FDragging := True;
  SetFromY(Y);
end;

procedure TWheelView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then SetFromY(Y);
end;

procedure TWheelView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if not FDragging then Exit;
  FDragging := False;
  if FSpringBack and (FValue <> 0) then FTimer.Enabled := True;
end;

procedure TWheelView.Paint;
var
  R: TRect;
  T, Y, Mid: Integer;
begin
  R := ClientRect;
  Canvas.Brush.Color := $00302820;
  Canvas.Pen.Color := $00605850;
  Canvas.Rectangle(R);
  if FSpringBack then T := Round((FValue + 1) / 2 * 1000) else T := Round(FValue * 1000);
  Y := R.Bottom - 4 - Round(T / 1000 * (R.Height - 8));
  Mid := (R.Top + R.Bottom) div 2;
  // Fuellung von der Ruhelage bis zum Wert
  Canvas.Brush.Color := $00B08040;
  if FSpringBack then
  begin
    if Y < Mid then Canvas.FillRect(Rect(R.Left + 3, Y, R.Right - 3, Mid))
    else Canvas.FillRect(Rect(R.Left + 3, Mid, R.Right - 3, Y));
    Canvas.Pen.Color := $00807870;
    Canvas.MoveTo(R.Left + 1, Mid); Canvas.LineTo(R.Right - 1, Mid);
  end
  else
    Canvas.FillRect(Rect(R.Left + 3, Y, R.Right - 3, R.Bottom - 3));
  Canvas.Brush.Color := $00E0D8D0;
  Canvas.FillRect(Rect(R.Left + 2, Y - 2, R.Right - 2, Y + 2));
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := $00C0B8B0;
  Canvas.Font.Size := UiPt(7);
  Canvas.TextOut((R.Width - Canvas.TextWidth(FCaption)) div 2, R.Bottom - 14, FCaption);
  Canvas.Brush.Style := bsSolid;
end;

end.
