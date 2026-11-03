{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.AudioEditor;

{ Fenster "Audio bearbeiten": schneller Schnittplatz fuer das Sample hinter den Grains (Hauptsample
  oder Zone). Arbeitet auf einer Kopie; erst "Uebernehmen" liefert das fertige Sample zurueck, das der
  Editor dann als neue WAV in "Eigene Toene" speichert und in die Engine laedt (wie eine Aufnahme).
  Vorhoeren ueber das Windows-Standardgeraet (PlaySound aus dem Speicher) - unabhaengig vom
  Audio-Thread des Plugins, funktioniert im Host wie in der DAW.
  Aufnahme ueber WASAPI: jedes Aufnahmegeraet oder "was der PC abspielt" (Loopback), hoechstens REC_MAX_SEC.
  Bedienung: ziehen = markieren, Shift+Klick = Markierung erweitern, Mausrad = Zoom,
  Leertaste = Abspielen/Stopp, Entf = Loeschen, Strg+Z = Rueckgaengig, Strg+A = alles markieren. }

interface

uses
  Granular.Lang,
  Winapi.Windows, Winapi.Messages, Winapi.MMSystem, System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Graphics, Vcl.Forms, Vcl.Dialogs,
  Granular.Fader,   // nach Vcl.StdCtrls: Knoepfe im Look des Plugins
  Granular.Sample, Granular.SampleEdit, Granular.AudioDecode, Granular.WasapiRec, Granular.IconButton;

type
  TWaveBox = class(TCustomControl)
  protected
    procedure Paint; override;
  public
    OnPaintWave: TNotifyEvent;
  end;

  TAudioEditForm = class(TForm)
  private
    FData: TSampleData;                    // Arbeitskopie
    FUndo: TObjectList<TSampleData>;
    FSelA, FSelB: Integer;                 // Markierung in Frames (A = B: keine)
    FViewA, FViewB: Integer;               // sichtbarer Ausschnitt
    FDrag: Boolean;
    FDragFrom: Integer;
    FWave: TWaveBox;
    FInfo: TLabel;
    FBaseDir: string;
    FButtons: TList<TIconButton>;
    FPlayBtn: TIconButton;
    FPlayWav: TBytes;                      // WAV im Speicher, muss bis zum Stopp leben
    FPlayFrom, FPlayLen: Integer;          // gespielter Bereich (Frames)
    FPlayT0: Cardinal;
    FPlaying: Boolean;
    FTimer: TTimer;
    procedure PlayClick(Sender: TObject);
    procedure StopPlay;
    procedure TimerTick(Sender: TObject);
    function PlayPos: Integer;
  private
    FSrcCombo: TComboBox;
    FSources: TArray<TRecSource>;
    FRecBtn: TIconButton;
    FRec: TWasapiRecorder;
    FLevelBg, FLevel: TPanel;
    FRecInfo: TLabel;
    procedure RecClick(Sender: TObject);
    procedure StopRec(Keep: Boolean);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    function Btn(AParent: TWinControl; X, Y, W: Integer; Icon: TEdIcon; const Cap, HintText: string;
      Click: TNotifyEvent): TIconButton;
    function HasSel: Boolean;
    procedure RangeOrAll(out A, B: Integer);
    procedure PushUndo;
    procedure Changed;
    procedure UpdateInfo;
    function XToFrame(X: Integer): Integer;
    function FrameToX(F: Integer): Integer;
    procedure PaintWave(Sender: TObject);
    procedure PaintRuler(C: TCanvas; W, Top: Integer);
    procedure WaveMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure WaveMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure WaveMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure WaveWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
      var Handled: Boolean);
    procedure ZoomAt(Center: Integer; Factor: Double);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure LoadClick(Sender: TObject);
    procedure CropClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure FadeInClick(Sender: TObject);
    procedure FadeOutClick(Sender: TObject);
    procedure NormClick(Sender: TObject);
    procedure TrimClick(Sender: TObject);
    procedure ReverseClick(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure SelAllClick(Sender: TObject);
    procedure ZoomInClick(Sender: TObject);
    procedure ZoomOutClick(Sender: TObject);
    procedure ZoomAllClick(Sender: TObject);
    procedure SetData(D: TSampleData);
  public
    constructor CreateEditor(Src: TSampleData; const ACaption, BaseDir: string);
    destructor Destroy; override;
  end;

{ Editor zeigen; True = Uebernehmen, Res = neues Sample (gehoert dem Aufrufer, LR gebaut, FileName leer) }
function EditAudio(Src: TSampleData; const Caption, BaseDir: string; out Res: TSampleData): Boolean;

implementation

const
  BG_MAIN  = $00383230;   // wie im Plugin-Fenster (BGR)
  BG_DARK  = $002A2624;
  COL_NAME = $00DCDCDC;
  COL_WAVE = $0080C878;
  COL_SEL  = $00604A30;
  UNDO_MAX = 10;
  RULER_H = 18;           // Hoehe der Zeitleiste unter der Wellenform
  REC_MAX_SEC = 60;       // laengste Aufnahme (Speicher auf 32-Bit-Rechnern)          // Undo-Stufen (32-Bit-Rechner: begrenzter Speicher)

procedure TWaveBox.Paint;
begin
  if Assigned(OnPaintWave) then
    OnPaintWave(Self);
end;

function EditAudio(Src: TSampleData; const Caption, BaseDir: string; out Res: TSampleData): Boolean;
var
  F: TAudioEditForm;
begin
  Res := nil;
  F := TAudioEditForm.CreateEditor(Src, Caption, BaseDir);
  try
    Result := (F.ShowModal = mrOk) and (F.FData <> nil) and (F.FData.Frames > 1);
    if Result then
    begin
      Res := F.FData;
      F.FData := nil;
      SampleFinish(Res);
    end;
  finally
    F.Free;
  end;
end;

constructor TAudioEditForm.CreateEditor(Src: TSampleData; const ACaption, BaseDir: string);
var
  Top, Bottom: TPanel;
  B: TIconButton;
  X: Integer;

  function Next(W: Integer): Integer;
  begin
    Result := X;
    Inc(X, W + 6);
  end;

begin
  inherited CreateNew(nil);
  FBaseDir := BaseDir;
  FUndo := TObjectList<TSampleData>.Create(True);
  FButtons := TList<TIconButton>.Create;
  Caption := ACaption;
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMaximize];
  Position := poScreenCenter;
  ClientWidth := 1000;
  ClientHeight := 440;
  Constraints.MinWidth := 1000;
  Constraints.MinHeight := 320;
  Color := BG_MAIN;
  Font.Color := COL_NAME;
  KeyPreview := True;
  OnKeyDown := FormKey;

  Top := TPanel.Create(Self);
  Top.Parent := Self;
  Top.Align := alTop;
  Top.Height := 76;
  Top.BevelOuter := bvNone;
  Top.ParentBackground := False;
  Top.Color := BG_DARK;
  X := 8;
  Btn(Top, Next(126), 7, 126, eiOpen, Tr('Datei laden...'), Tr('Eine Audiodatei zum Bearbeiten laden'), LoadClick);
  FPlayBtn := Btn(Top, Next(112), 7, 112, eiPlay, Tr('Abspielen'), Tr('Markierung (ohne: ab Cursor) anhören - Leertaste'), PlayClick);
  Btn(Top, Next(136), 7, 136, eiSelAll, Tr('Alles markieren'), Tr('Ganzes Sample markieren (Strg+A)'), SelAllClick);
  Btn(Top, Next(34), 7, 34, eiZoomIn, '', Tr('Hineinzoomen (auch Mausrad)'), ZoomInClick);
  Btn(Top, Next(34), 7, 34, eiZoomOut, '', Tr('Herauszoomen (auch Mausrad)'), ZoomOutClick);
  Btn(Top, Next(34), 7, 34, eiZoomFit, '', Tr('Ganzes Sample zeigen'), ZoomAllClick);
  FInfo := TLabel.Create(Self);
  FInfo.Parent := Top;
  FInfo.SetBounds(X + 8, 13, 380, 16);
  FInfo.AutoSize := False;
  FInfo.Transparent := True;
  FInfo.Font.Color := $005AD2FF;

  // zweite Zeile: Aufnahme von einem Geraet oder vom Lautsprecher-Ausgang
  FRecInfo := TLabel.Create(Self);   // zuerst die Beschriftung "Aufnahme:", unten neu belegt
  FRecInfo.Parent := Top;
  FRecInfo.SetBounds(8, 48, 70, 16);
  FRecInfo.Transparent := True;
  FRecInfo.Caption := Tr('Aufnahme:');
  FSrcCombo := TComboBox.Create(Self);
  FSrcCombo.Parent := Top;
  FSrcCombo.Style := csDropDownList;
  FSrcCombo.SetBounds(84, 44, 330, 21);
  FSrcCombo.TabStop := False;
  FSrcCombo.DropDownCount := 16;
  try
    FSources := ListRecSources(Tr('Was der PC abspielt') + ': ');
  except
    FSources := nil;
  end;
  for var Src0 in FSources do
    FSrcCombo.Items.Add(Src0.Name);
  if FSrcCombo.Items.Count > 0 then
    FSrcCombo.ItemIndex := 0;
  FRecBtn := Btn(Top, 422, 41, 110, eiRec, Tr('Aufnehmen'), Tr('Aufnahme starten/stoppen - ersetzt das Audio im Fenster ' +
    '(Rückgängig holt es zurück)'), RecClick);
  FLevelBg := TPanel.Create(Self);
  FLevelBg.Parent := Top;
  FLevelBg.SetBounds(540, 48, 120, 12);
  FLevelBg.BevelOuter := bvNone;
  FLevelBg.ParentBackground := False;
  FLevelBg.Color := $00201C1A;
  FLevel := TPanel.Create(Self);
  FLevel.Parent := FLevelBg;
  FLevel.SetBounds(0, 0, 0, 12);
  FLevel.BevelOuter := bvNone;
  FLevel.ParentBackground := False;
  FLevel.Color := COL_WAVE;
  FRecInfo := TLabel.Create(Self);
  FRecInfo.Parent := Top;
  FRecInfo.SetBounds(668, 47, 280, 16);
  FRecInfo.AutoSize := False;
  FRecInfo.Transparent := True;
  FRecInfo.Font.Color := $00A0A0A0;
  if FSources = nil then
    FRecInfo.Caption := Tr('Kein Aufnahmegerät gefunden')
  else
    FRecInfo.Caption := Format(Tr('höchstens %d s'), [REC_MAX_SEC]);
  OnCloseQuery := FormCloseQuery;

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := 82;
  Bottom.BevelOuter := bvNone;
  Bottom.ParentBackground := False;
  Bottom.Color := BG_DARK;
  X := 8;
  Btn(Bottom, Next(118), 8, 118, eiCrop, Tr('Zuschneiden'), Tr('Nur die Markierung behalten'), CropClick);
  Btn(Bottom, Next(96), 8, 96, eiDelete, Tr('Löschen'), Tr('Markierung entfernen (Entf)'), DeleteClick);
  Btn(Bottom, Next(108), 8, 108, eiFadeIn, Tr('Einblenden'), Tr('Markierung (ohne: ganzes Sample) weich einblenden'), FadeInClick);
  Btn(Bottom, Next(108), 8, 108, eiFadeOut, Tr('Ausblenden'), Tr('Markierung (ohne: ganzes Sample) weich ausblenden'), FadeOutClick);
  Btn(Bottom, Next(124), 8, 124, eiNormalize, Tr('Normalisieren'), Tr('Lautstärke auf -0,2 dB Spitze bringen (Markierung oder alles)'), NormClick);
  Btn(Bottom, Next(140), 8, 140, eiTrim, Tr('Stille entfernen'), Tr('Stille am Anfang und Ende abschneiden'), TrimClick);
  Btn(Bottom, Next(104), 8, 104, eiReverse, Tr('Umkehren'), Tr('Markierung (ohne: ganzes Sample) rückwärts'), ReverseClick);
  Btn(Bottom, Next(118), 8, 118, eiUndo, Tr('Rückgängig'), Tr('Letzten Schritt zurücknehmen (Strg+Z)'), UndoClick);
  B := Btn(Bottom, 0, 44, 120, eiOk, Tr('Übernehmen'), Tr('Bearbeitetes Sample laden und in "Eigene Toene" speichern'), nil);
  B.ModalResult := mrOk;
  B.Anchors := [akRight, akTop];
  B.Left := Bottom.Width - 2 * 126 - 8;
  B := Btn(Bottom, 0, 44, 120, eiCancel, Tr('Abbrechen'), Tr('Fenster schließen, nichts ändern'), nil);
  B.ModalResult := mrCancel;
  B.Anchors := [akRight, akTop];
  B.Left := Bottom.Width - 126 - 8;
  with TLabel.Create(Self) do
  begin
    Parent := Bottom;
    SetBounds(8, 50, 620, 16);
    AutoSize := False;
    Transparent := True;
    Font.Color := $00A0A0A0;
    Caption := Tr('Ziehen = markieren, Shift+Klick = erweitern, Mausrad = Zoom. ' +
      'Schnitte rasten auf den nächsten Nulldurchgang ein.');
  end;

  FWave := TWaveBox.Create(Self);
  FWave.Parent := Self;
  FWave.Align := alClient;
  FWave.DoubleBuffered := True;
  FWave.OnPaintWave := PaintWave;
  FWave.OnMouseDown := WaveMouseDown;
  FWave.OnMouseMove := WaveMouseMove;
  FWave.OnMouseUp := WaveMouseUp;
  OnMouseWheel := WaveWheel;      // Rad kommt beim Formular an (die Wellenform hat keinen Fokus)

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 30;
  FTimer.Enabled := False;
  FTimer.OnTimer := TimerTick;

  if (Src <> nil) and (Src.Frames > 1) then
    SetData(SampleClone(Src));
  UpdateInfo;
end;

destructor TAudioEditForm.Destroy;
begin
  StopPlay;
  StopRec(False);
  FData.Free;
  FUndo.Free;
  FButtons.Free;
  inherited;
end;

function TAudioEditForm.Btn(AParent: TWinControl; X, Y, W: Integer; Icon: TEdIcon; const Cap, HintText: string;
  Click: TNotifyEvent): TIconButton;
begin
  Result := TIconButton.Create(Self);
  Result.Icon := Icon;
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 27);
  Result.Caption := Cap;
  Result.Hint := HintText;
  Result.ShowHint := True;
  Result.OnClick := Click;
  FButtons.Add(Result);
end;

procedure TAudioEditForm.SetData(D: TSampleData);
begin
  StopPlay;
  FData.Free;
  FData := D;
  FSelA := 0;
  FSelB := 0;
  FViewA := 0;
  FViewB := FData.Frames;
  FUndo.Clear;
  Changed;
end;

function TAudioEditForm.HasSel: Boolean;
begin
  Result := (FData <> nil) and (Abs(FSelB - FSelA) >= 2);
end;

procedure TAudioEditForm.RangeOrAll(out A, B: Integer);
begin
  if HasSel then
  begin
    A := Min(FSelA, FSelB);
    B := Max(FSelA, FSelB);
  end
  else
  begin
    A := 0;
    B := FData.Frames;
  end;
end;

procedure TAudioEditForm.PushUndo;
begin
  if FData = nil then
    Exit;
  StopPlay;                 // die Daten aendern sich gleich
  FUndo.Add(SampleClone(FData));
  while FUndo.Count > UNDO_MAX do
    FUndo.Delete(0);
end;

procedure TAudioEditForm.Changed;
begin
  if FData <> nil then
  begin
    FViewB := EnsureRange(FViewB, 1, FData.Frames);
    FViewA := EnsureRange(FViewA, 0, FViewB - 1);
    FSelA := EnsureRange(FSelA, 0, FData.Frames);
    FSelB := EnsureRange(FSelB, 0, FData.Frames);
  end;
  UpdateInfo;
  FWave.Invalidate;
end;

procedure TAudioEditForm.UpdateInfo;
var
  SR: Double;
begin
  if (FData = nil) or (FData.Frames < 1) then
  begin
    FInfo.Caption := Tr('Kein Audio - Datei laden');
    Exit;
  end;
  SR := FData.SampleRate;
  if HasSel then
    FInfo.Caption := Format(Tr('Länge %.2f s | Markierung %.2f s (%.2f - %.2f s)'),
      [FData.Frames / SR, Abs(FSelB - FSelA) / SR, Min(FSelA, FSelB) / SR, Max(FSelA, FSelB) / SR])
  else
    FInfo.Caption := Format(Tr('Länge %.2f s | %d Hz | keine Markierung'), [FData.Frames / SR, Round(SR)]);
end;

function TAudioEditForm.XToFrame(X: Integer): Integer;
begin
  if (FData = nil) or (FWave.Width < 2) then
    Exit(0);
  Result := EnsureRange(FViewA + Round(X / FWave.Width * (FViewB - FViewA)), 0, FData.Frames);
end;

function TAudioEditForm.FrameToX(F: Integer): Integer;
begin
  if FViewB <= FViewA then
    Exit(0);
  Result := Round((F - FViewA) / (FViewB - FViewA) * FWave.Width);
end;

{ Zeitleiste: Striche in einem runden Abstand (mindestens ~80 Pixel), Beschriftung in Sekunden }
procedure TAudioEditForm.PaintRuler(C: TCanvas; W, Top: Integer);
const
  STEPS: array[0..14] of Double = (0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 30);
var
  T0, Span, Step, T: Double;
  I, X: Integer;
  Fmt: string;
begin
  C.Brush.Color := BG_DARK;
  C.FillRect(Rect(0, Top, W, Top + RULER_H));
  Span := (FViewB - FViewA) / FData.SampleRate;
  if (Span <= 0) or (W < 10) then
    Exit;
  Step := STEPS[High(STEPS)];
  for I := 0 to High(STEPS) do
    if STEPS[I] / Span * W >= 80 then
    begin
      Step := STEPS[I];
      Break;
    end;
  if Step < 0.01 then Fmt := '%.3f s' else if Step < 0.1 then Fmt := '%.2f s' else if Step < 1 then Fmt := '%.1f s'
  else Fmt := '%.0f s';
  T0 := FViewA / FData.SampleRate;
  T := Ceil(T0 / Step) * Step;
  C.Font.Color := $00A0A0A0;
  C.Font.Size := 8;
  C.Brush.Style := bsClear;
  C.Pen.Color := $00706860;
  while T <= T0 + Span do
  begin
    X := Round((T - T0) / Span * W);
    C.MoveTo(X, Top); C.LineTo(X, Top + 5);
    C.TextOut(X + 3, Top + 3, Format(Fmt, [T]));
    T := T + Step;
  end;
  C.Brush.Style := bsSolid;
end;

procedure TAudioEditForm.PaintWave(Sender: TObject);
var
  C: TCanvas;
  W, H, X, I, F0, F1, Ch, Chs, Mid, Half, X0, X1: Integer;
  Lo, Hi, V: Single;
  Src: TArray<Single>;
begin
  C := FWave.Canvas;
  W := FWave.Width;
  H := FWave.Height - RULER_H;          // unten die Zeitleiste
  C.Brush.Color := $00201C1A;
  C.FillRect(Rect(0, 0, W, FWave.Height));
  if (FData = nil) or (FData.Frames < 2) then
    Exit;
  PaintRuler(C, W, H);
  if HasSel then
  begin
    X0 := Max(0, FrameToX(Min(FSelA, FSelB)));
    X1 := Min(W, FrameToX(Max(FSelA, FSelB)));
    if X1 > X0 then
    begin
      C.Brush.Color := COL_SEL;
      C.FillRect(Rect(X0, 0, X1, H));
    end;
  end;
  if FData.Channels > 1 then Chs := 2 else Chs := 1;
  C.Pen.Color := COL_WAVE;
  for Ch := 0 to Chs - 1 do
  begin
    if Ch = 0 then Src := FData.L else Src := FData.R;
    Half := H div (2 * Chs);
    Mid := Half + Ch * 2 * Half;
    C.Pen.Color := $00505050;
    C.MoveTo(0, Mid); C.LineTo(W, Mid);
    C.Pen.Color := COL_WAVE;
    for X := 0 to W - 1 do
    begin
      F0 := FViewA + Int64(X) * (FViewB - FViewA) div W;
      F1 := Max(F0 + 1, FViewA + Int64(X + 1) * (FViewB - FViewA) div W);
      F1 := Min(F1, FData.Frames);
      Lo := 0; Hi := 0;
      for I := F0 to F1 - 1 do
      begin
        V := Src[I];
        if V < Lo then Lo := V;
        if V > Hi then Hi := V;
      end;
      C.MoveTo(X, Mid - Round(Hi * (Half - 2)));
      C.LineTo(X, Mid - Round(Lo * (Half - 2)) + 1);
    end;
  end;
  if FPlaying then
  begin
    C.Pen.Color := clWhite;
    X0 := FrameToX(PlayPos);
    C.MoveTo(X0, 0); C.LineTo(X0, H);
  end;
  if not HasSel and (FSelA > 0) then
  begin
    C.Pen.Color := $005AD2FF;
    X0 := FrameToX(FSelA);
    C.MoveTo(X0, 0); C.LineTo(X0, H);
  end;
end;

procedure TAudioEditForm.WaveMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (FData = nil) or (Button <> mbLeft) then
    Exit;
  if ssShift in Shift then
    FSelB := XToFrame(X)
  else
  begin
    FSelA := XToFrame(X);
    FSelB := FSelA;
  end;
  FDragFrom := FSelA;
  FDrag := True;
  Changed;
end;

procedure TAudioEditForm.WaveMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if not FDrag then
    Exit;
  FSelB := XToFrame(X);
  Changed;
end;

procedure TAudioEditForm.WaveMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDrag := False;
end;

procedure TAudioEditForm.ZoomAt(Center: Integer; Factor: Double);
var
  Span: Integer;
begin
  if FData = nil then
    Exit;
  Span := EnsureRange(Round((FViewB - FViewA) * Factor), Min(64, FData.Frames), FData.Frames);
  FViewA := EnsureRange(Center - Span div 2, 0, FData.Frames - Span);
  FViewB := FViewA + Span;
  Changed;
end;

procedure TAudioEditForm.WaveWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
var
  P: TPoint;
begin
  P := FWave.ScreenToClient(MousePos);
  if not PtInRect(FWave.ClientRect, P) then
    Exit;
  if WheelDelta > 0 then
    ZoomAt(XToFrame(P.X), 0.7)
  else
    ZoomAt(XToFrame(P.X), 1 / 0.7);
  Handled := True;
end;

procedure TAudioEditForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_SPACE then
    PlayClick(nil)
  else if Key = VK_DELETE then
    DeleteClick(nil)
  else if (ssCtrl in Shift) and (Key = Ord('Z')) then
    UndoClick(nil)
  else if (ssCtrl in Shift) and (Key = Ord('A')) then
    SelAllClick(nil)
  else
    Exit;
  Key := 0;
end;

procedure TAudioEditForm.LoadClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := AUDIO_FILE_FILTER;
    if DirectoryExists(FBaseDir + 'Eigene Toene') then
      Dlg.InitialDir := FBaseDir + 'Eigene Toene';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if Dlg.Execute then
    try
      SetData(LoadAudioFile(Dlg.FileName));
    except
      on E: Exception do
        MessageDlg(Tr('Datei konnte nicht geladen werden:') + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TAudioEditForm.CropClick(Sender: TObject);
var
  A, B: Integer;
begin
  if not HasSel then
    Exit;
  PushUndo;
  A := SnapZero(FData, Min(FSelA, FSelB));
  B := SnapZero(FData, Max(FSelA, FSelB));
  SampleCrop(FData, A, B);
  FSelA := 0; FSelB := 0;
  FViewA := 0; FViewB := FData.Frames;
  Changed;
end;

procedure TAudioEditForm.DeleteClick(Sender: TObject);
var
  A, B: Integer;
begin
  if not HasSel then
    Exit;
  A := SnapZero(FData, Min(FSelA, FSelB));
  B := SnapZero(FData, Max(FSelA, FSelB));
  if B - A >= FData.Frames then
    Exit;                    // alles loeschen: nicht sinnvoll
  PushUndo;
  SampleDelete(FData, A, B);
  FSelA := A; FSelB := A;
  Changed;
end;

procedure TAudioEditForm.FadeInClick(Sender: TObject);
var
  A, B: Integer;
begin
  if FData = nil then Exit;
  PushUndo;
  RangeOrAll(A, B);
  SampleFadeIn(FData, A, B);
  Changed;
end;

procedure TAudioEditForm.FadeOutClick(Sender: TObject);
var
  A, B: Integer;
begin
  if FData = nil then Exit;
  PushUndo;
  RangeOrAll(A, B);
  SampleFadeOut(FData, A, B);
  Changed;
end;

procedure TAudioEditForm.NormClick(Sender: TObject);
var
  A, B: Integer;
begin
  if FData = nil then Exit;
  PushUndo;
  RangeOrAll(A, B);
  SampleNormalize(FData, A, B);
  Changed;
end;

procedure TAudioEditForm.TrimClick(Sender: TObject);
begin
  if FData = nil then Exit;
  PushUndo;
  if SampleTrimSilence(FData) = 0 then
    FUndo.Delete(FUndo.Count - 1)    // nichts geaendert: kein Undo-Schritt
  else
  begin
    FSelA := 0; FSelB := 0;
    FViewA := 0; FViewB := FData.Frames;
  end;
  Changed;
end;

procedure TAudioEditForm.ReverseClick(Sender: TObject);
var
  A, B: Integer;
begin
  if FData = nil then Exit;
  PushUndo;
  RangeOrAll(A, B);
  SampleReverse(FData, A, B);
  Changed;
end;

procedure TAudioEditForm.UndoClick(Sender: TObject);
begin
  if FUndo.Count = 0 then
    Exit;
  StopPlay;
  FData.Free;
  FData := FUndo.Extract(FUndo.Last);
  Changed;
end;

procedure TAudioEditForm.SelAllClick(Sender: TObject);
begin
  if FData = nil then Exit;
  FSelA := 0;
  FSelB := FData.Frames;
  Changed;
end;

procedure TAudioEditForm.ZoomInClick(Sender: TObject);
begin
  if HasSel then
    ZoomAt((FSelA + FSelB) div 2, 0.5)
  else
    ZoomAt((FViewA + FViewB) div 2, 0.5);
end;

{ --- Vorhoeren --- }

function TAudioEditForm.PlayPos: Integer;
begin
  Result := FPlayFrom + Round((GetTickCount - FPlayT0) / 1000 * FData.SampleRate);
end;

procedure TAudioEditForm.StopPlay;
begin
  if FPlaying then
    PlaySound(nil, 0, 0);
  FPlaying := False;
  if FTimer <> nil then
    FTimer.Enabled := False;
  if FPlayBtn <> nil then
  begin
    FPlayBtn.Caption := Tr('Abspielen');
    FPlayBtn.Icon := eiPlay;
  end;
  FPlayWav := nil;
end;

procedure TAudioEditForm.PlayClick(Sender: TObject);
var
  A, B, I, N, Bytes: Integer;
  P: PSmallInt;

  procedure W32(Ofs: Integer; V: Cardinal);
  begin
    PCardinal(@FPlayWav[Ofs])^ := V;
  end;

  procedure W16(Ofs: Integer; V: Word);
  begin
    PWord(@FPlayWav[Ofs])^ := V;
  end;

begin
  if FPlaying then
  begin
    StopPlay;
    FWave.Invalidate;
    Exit;
  end;
  if (FData = nil) or (FData.Frames < 2) then
    Exit;
  // Bereich: Markierung, sonst ab Cursor bis zum Ende
  if HasSel then
  begin
    A := Min(FSelA, FSelB);
    B := Max(FSelA, FSelB);
  end
  else
  begin
    A := FSelA;
    if A >= FData.Frames - 1 then A := 0;
    B := FData.Frames;
  end;
  N := B - A;
  Bytes := N * 4;
  SetLength(FPlayWav, 44 + Bytes);
  Move(AnsiString('RIFF')[1], FPlayWav[0], 4);
  W32(4, 36 + Bytes);
  Move(AnsiString('WAVEfmt ')[1], FPlayWav[8], 8);
  W32(16, 16);
  W16(20, 1);                                   // PCM
  W16(22, 2);                                   // Stereo
  W32(24, Round(FData.SampleRate));
  W32(28, Round(FData.SampleRate) * 4);
  W16(32, 4);
  W16(34, 16);
  Move(AnsiString('data')[1], FPlayWav[36], 4);
  W32(40, Bytes);
  P := @FPlayWav[44];
  for I := A to B - 1 do
  begin
    P^ := Round(EnsureRange(FData.L[I], -1, 1) * 32767); Inc(P);
    P^ := Round(EnsureRange(FData.R[I], -1, 1) * 32767); Inc(P);
  end;
  if not PlaySound(PChar(@FPlayWav[0]), 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT) then
  begin
    FPlayWav := nil;
    Exit;
  end;
  FPlayFrom := A;
  FPlayLen := N;
  FPlayT0 := GetTickCount;
  FPlaying := True;
  FPlayBtn.Caption := Tr('Stopp');
  FPlayBtn.Icon := eiStop;
  FTimer.Enabled := True;
end;

procedure TAudioEditForm.TimerTick(Sender: TObject);
var
  Pk: Single;
begin
  if FRec <> nil then
  begin
    FRecBtn.Active := (GetTickCount div 400) mod 2 = 0;   // roter Punkt blinkt
    Pk := FRec.TakePeak;
    FLevel.Width := Round(FLevelBg.Width * EnsureRange(Pk, 0, 1));
    if Pk > 0.98 then FLevel.Color := $004040FF else FLevel.Color := COL_WAVE;   // rot = Uebersteuerung
    if FRec.Finished then
      StopRec(True)                         // Fehler oder Hoechstlaenge erreicht
    else
      FRecInfo.Caption := Format(Tr('Aufnahme läuft: %.1f s'), [FRec.Seconds]);
    Exit;
  end;
  if FPlaying and (PlayPos >= FPlayFrom + FPlayLen) then
    StopPlay;
  FWave.Invalidate;
end;

{ --- Aufnahme --- }

procedure TAudioEditForm.RecClick(Sender: TObject);
begin
  if FRec <> nil then
  begin
    StopRec(True);
    Exit;
  end;
  if (FSrcCombo.ItemIndex < 0) or (FSrcCombo.ItemIndex > High(FSources)) then
    Exit;
  StopPlay;
  FRec := TWasapiRecorder.Create(FSources[FSrcCombo.ItemIndex], REC_MAX_SEC);
  FRecBtn.Caption := Tr('Stopp');
  FRecBtn.Active := True;
  FSrcCombo.Enabled := False;
  if FSources[FSrcCombo.ItemIndex].Loopback then
    FRecInfo.Caption := Tr('Aufnahme läuft (Klang von GranularSynth wird mit aufgenommen)')
  else
    FRecInfo.Caption := Tr('Aufnahme läuft ...');
  FTimer.Enabled := True;
end;

procedure TAudioEditForm.StopRec(Keep: Boolean);
var
  D: TSampleData;
  Err: string;
begin
  if FRec = nil then
    Exit;
  D := FRec.Finish;
  Err := FRec.Error;
  FreeAndNil(FRec);
  if FRecBtn <> nil then
  begin
    FRecBtn.Caption := Tr('Aufnehmen');
    FRecBtn.Active := False;
    FSrcCombo.Enabled := True;
    FLevel.Width := 0;
    FTimer.Enabled := False;
  end;
  if not Keep then
  begin
    D.Free;
    Exit;
  end;
  if D = nil then
  begin
    if Err <> '' then
      FRecInfo.Caption := Tr('Aufnahme nicht möglich') + ': ' + Err
    else
      FRecInfo.Caption := Tr('Nichts aufgenommen (lief Ton?)');
    Exit;
  end;
  // Aufnahme ersetzt das Audio im Fenster; der vorige Stand bleibt als Rueckgaengig-Schritt
  PushUndo;
  FData.Free;
  FData := D;
  FSelA := 0; FSelB := 0;
  FViewA := 0; FViewB := FData.Frames;
  FRecInfo.Caption := Format(Tr('%.1f s aufgenommen'), [FData.Frames / FData.SampleRate]);
  Changed;
end;

procedure TAudioEditForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // laufende Aufnahme beim Uebernehmen behalten, beim Abbrechen verwerfen
  StopRec(ModalResult = mrOk);
  StopPlay;
end;

procedure TAudioEditForm.ZoomOutClick(Sender: TObject);
begin
  ZoomAt((FViewA + FViewB) div 2, 2);
end;

procedure TAudioEditForm.ZoomAllClick(Sender: TObject);
begin
  if FData = nil then Exit;
  FViewA := 0;
  FViewB := FData.Frames;
  Changed;
end;

end.
