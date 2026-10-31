{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.InfoView;

{ Info-Fenster: beschreibt die aktuelle Einstellung in Klartext als Tabelle -
  in der Reihenfolge, in der beim Tastendruck etwas passiert (Taste -> Arp -> Stimme ->
  Tonhoehe -> Grains -> Huellkurve -> LFOs/Matrix -> Effektkette -> Ausgang).
  Nicht modal, bleibt vorn; prueft alle 300 ms, ob sich etwas geaendert hat, und baut die
  Tabelle nur dann neu (Preset-Wechsel, Regler, Automation). Nur aktive Teile werden genannt. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.Classes, System.SysUtils, System.Math, System.Types,
  Vcl.Controls, Vcl.Forms, Vcl.Grids, Vcl.ExtCtrls, Vcl.Graphics, Vcl.StdCtrls, Vcl.ComCtrls,
  Granular.Params, Granular.Engine;

type
  TInfoRow = record
    Area, Text: string;
  end;

  TInfoForm = class(TForm)
  private
    FEngine: TGranularEngine;
    FGrid: TStringGrid;
    FTimer: TTimer;
    FLast: string;
    FMoodLbl: TLabel;        // erkannte Stimmung der Musik (live)
    FLog: TMemo;             // Trigger-Protokoll (live, nur bei offenem Fenster)
    FLogPos: Integer;
    FLogLines: Integer;
    procedure PollLog;
    procedure FormShow(Sender: TObject);
    procedure FormHide(Sender: TObject);
    procedure GridDrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
    procedure TimerTick(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FitRows;
  public
    constructor CreateInfo(AOwner: TComponent; AEngine: TGranularEngine);
    procedure Refresh(Force: Boolean = False);
  end;

{ Hilfe-Fenster (nicht modal, nur eines): zeigt die RTF-Datei Hilfe\Hilfe.rtf neben dem Plugin -
  Text ohne Neukompilieren aenderbar (z.B. mit WordPad) }
procedure ShowHelpWindow(AOwner: TComponent; const FileName: string);

{ die Beschreibung selbst (auch ohne Fenster nutzbar) }
function BuildInfo(E: TGranularEngine): TArray<TInfoRow>;

implementation

const
  COL_BG = $00302A28;
  COL_BG2 = $00383230;
  COL_AREA = $005AD2FF;
  COL_TEXT = $00E6E6E6;
  COL_HEAD = $00201A18;

type
  THelpForm = class(TForm)
  private
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    destructor Destroy; override;
  end;

var
  HelpForm: THelpForm;

destructor THelpForm.Destroy;
begin
  HelpForm := nil;   // gehoert dem Editor: mit ihm freigegeben
  inherited;
end;

procedure THelpForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    Close;
end;

procedure ShowHelpWindow(AOwner: TComponent; const FileName: string);
var
  Ed: TRichEdit;
begin
  if HelpForm <> nil then
  begin
    HelpForm.Show;
    HelpForm.BringToFront;
    Exit;
  end;
  HelpForm := THelpForm.CreateNew(AOwner);
  HelpForm.Caption := 'GRANULAR - Hilfe  (FM ' + #$00B7 + ' Synthese ' + #$00B7 + ' HABI M ' + #$00B7 + ' Version ' + APP_VERSION + ')';
  HelpForm.BorderStyle := bsSizeToolWin;
  HelpForm.FormStyle := fsStayOnTop;
  HelpForm.Position := poScreenCenter;
  HelpForm.ClientWidth := 720;
  HelpForm.ClientHeight := 640;
  HelpForm.Color := COL_BG;
  HelpForm.KeyPreview := True;
  HelpForm.OnKeyDown := HelpForm.FormKeyDown;
  Ed := TRichEdit.Create(HelpForm);
  Ed.Parent := HelpForm;
  Ed.Align := alClient;
  Ed.AlignWithMargins := True;
  Ed.Margins.SetBounds(12, 10, 4, 10);
  Ed.BorderStyle := bsNone;
  Ed.ReadOnly := True;
  Ed.ScrollBars := ssVertical;
  Ed.Color := COL_BG;
  Ed.PlainText := False;
  if FileExists(FileName) then
    Ed.Lines.LoadFromFile(FileName)
  else
    Ed.Lines.Text := 'Hilfedatei nicht gefunden: ' + FileName;
  Ed.SelStart := 0;
  HelpForm.Show;
end;

function Sgn(V: Double): string;
begin
  if V >= 0 then Result := '+' + FormatFloat('0', V) else Result := FormatFloat('0', V);
end;

function BuildInfo(E: TGranularEngine): TArray<TInfoRow>;
var
  Rows: TArray<TInfoRow>;

  procedure Add(const Area, Text: string);
  var
    R: TInfoRow;
  begin
    R.Area := Area;
    R.Text := Text;
    Rows := Rows + [R];
  end;

  function N(Id: TGranularParamId): Single;
  begin
    Result := E.GetParam(Ord(Id));
  end;

  { eingestellter Wert; laeuft gerade Modulation darauf, zusaetzlich der Wert in diesem Moment }
  function PV(Id: TGranularParamId): string;
  var
    Ef: Single;
  begin
    Result := ParamDisplay(Id, N(Id));
    Ef := E.EffParam[Ord(Id)];
    if (GetParamInfo(Ord(Id)).Curve <> pcStepped) and (Abs(Ef - N(Id)) > 0.004) then
      Result := Result + ' (jetzt ' + ParamDisplay(Id, Ef) + ')';
  end;

  function St(Id: TGranularParamId): Integer;
  begin
    Result := ParamStep(Ord(Id), N(Id));
  end;

  function IsOn(Id: TGranularParamId): Boolean;
  begin
    Result := N(Id) >= 0.5;
  end;

  function Plain(Id: TGranularParamId): Double;
  begin
    Result := ParamToPlain(Id, N(Id));
  end;

  function SlotUses(Src: TModSource): Boolean;
  var
    S: Integer;
  begin
    Result := False;
    for S := 0 to MOD_SLOTS - 1 do
      if (ParamStep(SlotSourceIndex(S), E.GetParam(SlotSourceIndex(S))) = Ord(Src)) and
         (ParamStep(SlotDestIndex(S), E.GetParam(SlotDestIndex(S))) > 0) then
        Exit(True);
  end;

  { "bewegt Cutoff um +25 %, Position um -10 %" fuer eine Quelle }
  function Targets(Src: TModSource): string;
  var
    S, D, F: Integer;
    Amt, Ofs: Double;
    Part: string;
  begin
    Result := '';
    for S := 0 to MOD_SLOTS - 1 do
    begin
      if ParamStep(SlotSourceIndex(S), E.GetParam(SlotSourceIndex(S))) <> Ord(Src) then
        Continue;
      D := ParamStep(SlotDestIndex(S), E.GetParam(SlotDestIndex(S)));
      if D = 0 then
        Continue;
      Amt := ParamToPlain(SlotAmountIndex(S), E.GetParam(SlotAmountIndex(S)));
      F := ParamStep(SlotFactorIndex(S), E.GetParam(SlotFactorIndex(S)));
      Ofs := ParamToPlain(SlotOffsetIndex(S), E.GetParam(SlotOffsetIndex(S)));
      Part := Format('%s (%s %%', [DestName(D), Sgn(Amt)]);
      if MOD_FACTORS[F] <> 1 then
        Part := Part + ', ' + MOD_FACTOR_NAMES[F];
      if Abs(Ofs) > 0.5 then
        Part := Part + ', Offset ' + Sgn(Ofs) + ' %';
      Part := Part + ')';
      if Result <> '' then Result := Result + ', ';
      Result := Result + Part;
    end;
  end;

  { Quellen, die per Matrix auf diesen Parameter wirken (z. B. "Schwellen-Tor") }
  function SwitchedBy(Id: TGranularParamId): string;
  var
    S, Src: Integer;
  begin
    Result := '';
    for S := 0 to MOD_SLOTS - 1 do
      if ParamStep(SlotDestIndex(S), E.GetParam(SlotDestIndex(S))) = Ord(Id) + 1 then
      begin
        Src := ParamStep(SlotSourceIndex(S), E.GetParam(SlotSourceIndex(S)));
        if Src > 0 then
        begin
          if Result <> '' then Result := Result + ', ';
          Result := Result + MOD_SOURCE_NAMES[TModSource(Src)];
        end;
      end;
  end;

  { an oder per Matrix schaltbar? Note fuer die Beschreibung }
  function Active(Id: TGranularParamId; out Note: string): Boolean;
  var
    By: string;
  begin
    By := SwitchedBy(Id);
    Note := '';
    if By <> '' then
      if IsOn(Id) then Note := ' [wird zusätzlich von ' + By + ' beeinflusst]'
      else Note := ' [nur eingeschaltet, solange ' + By + ' es einschaltet]';
    Result := IsOn(Id) or (By <> '');
  end;

  function LfoText(K: Integer): string;
  var
    F: PFreeLfo;
    I: Integer;
    Shp, Tr, Steps: string;
  begin
    Shp := LFO_SHAPE_NAMES[EnsureRange(St(LFO_SHAPE_IDS[K]), 0, 5)];
    if St(LFO_SHAPE_IDS[K]) = LFO_SHAPE_FREE then
    begin
      F := E.FreeLfo[LFO_FREE_IDX[K]];
      if F.Mode = 2 then
        Shp := 'freie, gezeichnete Kurve'
      else
      begin
        Steps := '';
        for I := 0 to Min(F.Steps, 16) - 1 do
          if F.Mode = 0 then
            Steps := Steps + Sgn(Round(F.Step[I] * FREE_SEMIS)) + ' '
          else
            Steps := Steps + Format('%.0f%% ', [F.Step[I] * 100]);
        if F.Steps > 16 then Steps := Steps + '...';
        if F.Mode = 0 then
          Shp := Format('frei, %d Halbton-Stufen (%s)', [F.Steps, Trim(Steps)])
        else
          Shp := Format('frei, %d Stufen (%s)', [F.Steps, Trim(Steps)]);
      end;
    end;
    if IsOn(LFO_SYNC_IDS[K]) then
      Result := Format('%s, im Takt: ein Durchlauf = %s', [Shp, LFO_DIV_NAMES[LfoDivisionIndex(N(LFO_RATE_IDS[K]))]])
    else
      Result := Format('%s, %s', [Shp, PV(LFO_RATE_IDS[K])]);
    case St(LFO_TRIG_IDS[K]) of
      0: Tr := 'läuft frei durch';
      1: Tr := 'startet mit jeder Note neu';
      2: Tr := 'startet beim Loslassen einer Taste neu';
      3: Tr := 'startet bei Note an und Note aus neu';
      4: Tr := Format('startet, wenn LFO %d seinen Einmal-Durchlauf beendet', [(K xor 1) + 1]);
      5: Tr := 'startet, wenn der Sidechain-Pegel ' + PV(gpScTrigLevel) + ' überschreitet';
      6: Tr := 'startet, wenn die Sidechain-Tonhöhe über ' + PV(gpScTrigNote) + ' steigt';
      7: Tr := 'startet, wenn das Schwellen-Tor öffnet';
    end;
    Result := Result + '; ' + Tr;
    if IsOn(LFO_ONCE_IDS[K]) then
      Result := Result + ', läuft nur EINMAL und bleibt dann am Ende stehen'
    else
      Result := Result + ', wiederholt sich';
  end;

var
  K, S, Src, Dst: Integer;
  T, Chain, Pat, Nt, BInfo: string;
  Mask: Cardinal;
  UsedSrc: array[TModSource] of Boolean;
  M: TModSource;
begin
  Rows := nil;
  if E.MorphSampleLoaded <> '' then
    BInfo := ' Klang B spielt sein eigenes Sample (' + ChangeFileExt(ExtractFileName(E.MorphSampleLoaded), '') +
      '): so viele Grains wie die Morph-Stellung kommen daraus.'
  else
    BInfo := '';

  // 1) Taste
  if Active(gpArpOn, Nt) then
  begin
    Mask := E.ArpMask;
    Pat := '';
    for K := 0 to St(gpArpSteps) do
      if Mask and (1 shl K) <> 0 then Pat := Pat + 'x' else Pat := Pat + '.';
    Add('1. Taste',
      Format('Arpeggiator: die gehaltenen Tasten laufen "%s" über %s in %s-Schritten (Länge %s, Swing %s). ' +
        'Muster %s (x = spielt, . = Pause).%s',
        [PV(gpArpMode), PV(gpArpOct), PV(gpArpRate), PV(gpArpGate), PV(gpArpSwing), Pat, Nt]));
  end
  else
    Add('1. Taste', 'Jede Taste startet eine eigene Stimme (mehrstimmig).');

  // 2) Tonhoehe
  if IsOn(gpKeyTrack) then T := 'folgt der Taste' else T := 'bleibt fest (Tasten ändern die Tonhöhe nicht)';
  if Abs(Plain(gpPitch)) > 0.01 then T := T + ', verschoben um ' + PV(gpPitch);
  if Plain(gpPitchRand) > 0.01 then T := T + ', je Grain zufällig +/- ' + PV(gpPitchRand);
  if St(gpScale) > 0 then T := T + Format(', rastet auf %s-%s ein', [PV(gpScaleRoot), PV(gpScale)]);
  if St(gpScPitchMode) > 0 then T := T + ', Auto-Pitch: folgt der Tonhöhe am Sidechain (' + PV(gpScPitchMode) + ')';
  Add('2. Tonhöhe', T + '.');

  // 3) Grains
  T := Format('%s Grains pro Sekunde, je %s lang (Fenster %s), aus dem Bereich %s bis %s des Samples',
    [PV(gpDensity), PV(gpGrainSize), PV(gpWindow), PV(gpSelStart), PV(gpSelEnd)]);
  if IsOn(gpFreeze) then
    T := T + '; FREEZE: die Abspielposition steht still'
  else
    T := T + '; Abspielgeschwindigkeit ' + PV(gpScan);
  if Plain(gpSpray) > 0.5 then T := T + ', Positions-Streuung ' + PV(gpSpray);
  if Plain(gpReverse) > 0.5 then T := T + ', ' + PV(gpReverse) + ' rückwärts';
  T := T + ', Stereobreite ' + PV(gpSpread) + '.';
  Add('3. Grains', T);

  // 4) Huellkurve
  Add('4. Lautstärke', Format('Anschwellen %s, Abfall %s auf %s, nach dem Loslassen Ausklang %s. Lautstärke %s.',
    [PV(gpAttack), PV(gpDecay), PV(gpSustain), PV(gpRelease), PV(gpVolume)]));

  // 5) Modulation
  FillChar(UsedSrc, SizeOf(UsedSrc), 0);
  for S := 0 to MOD_SLOTS - 1 do
  begin
    Src := ParamStep(SlotSourceIndex(S), E.GetParam(SlotSourceIndex(S)));
    Dst := ParamStep(SlotDestIndex(S), E.GetParam(SlotDestIndex(S)));
    if (Src > 0) and (Dst > 0) then
      UsedSrc[TModSource(Src)] := True;
  end;
  for K := 0 to LFO_COUNT - 1 do
    if UsedSrc[LFO_SRC[K]] then
      Add(Format('5. LFO %d', [K + 1]), LfoText(K) + '. Bewegt: ' + Targets(LFO_SRC[K]) + '.');
  if UsedSrc[msGate] or (St(gpLfo1Trig) = LFO_TRIG_GATE) or (St(gpLfo2Trig) = LFO_TRIG_GATE) then
  begin
    T := Format('öffnet, wenn "%s" über %s steigt (schließt knapp darunter wieder)', [PV(gpGateSrc), PV(gpGateThresh)]);
    if UsedSrc[msGate] then T := T + '. Schaltet: ' + Targets(msGate);
    Add('5. Schwellen-Tor', T + '.');
  end;
  for M := msSidechain to High(TModSource) do
    if UsedSrc[M] and (M <> msGate) and (LfoOfSource(Ord(M)) < 0) then
      Add('5. ' + MOD_SOURCE_NAMES[M], 'steuert ' + Targets(M) + '.');
  if UsedSrc[msSidechain] or (St(gpLfo1Trig) in [LFO_TRIG_SC_LEVEL, LFO_TRIG_SC_PITCH]) or
     (St(gpLfo2Trig) in [LFO_TRIG_SC_LEVEL, LFO_TRIG_SC_PITCH]) then
    Add('   Sidechain', Format('Eingang verstärkt um %s, reagiert in %s, fällt in %s ab.',
      [PV(gpScGain), PV(gpScAttack), PV(gpScRelease)]));
  if E.MorphValid and (St(gpMorphLfoShape) > 0) then
  begin
    if IsOn(gpMorphLfoSync) then T := 'im Takt (' + LFO_DIV_NAMES[LfoDivisionIndex(N(gpMorphLfoRate))] + ')'
    else T := PV(gpMorphLfoRate);
    Add('   Morph', Format('Morph-LFO (%s, %s) pendelt um %s mit Tiefe %s zwischen Klang A (0 %%) und B (100 %%).%s',
      [PV(gpMorphLfoShape), T, PV(gpMorph), PV(gpMorphLfoDepth), BInfo]));
  end
  else if E.MorphValid and (Plain(gpMorph) > 0.5) then
    Add('   Morph', 'blendet ' + PV(gpMorph) + ' zum gemerkten Klang B.' + BInfo)
  else if E.MorphValid and UsedSrc[msOff] then
    Add('   Morph', 'Ziel B ist gemerkt.');

  // 6) Effektkette
  Chain := 'Grains';
  if Active(gpFltOn, Nt) and (Plain(gpFltContour) > 0.5) then
  begin
    T := Format('%s bei %s, Resonanz %s, Wirkung %s', [PV(gpFltType), PV(gpFltCutoff), PV(gpFltReso), PV(gpFltContour)]);
    if Abs(Plain(gpFltEnvAmt)) > 0.5 then
      T := T + Format('; eigene Hüllkurve (%s / %s / %s / %s) verschiebt den Cutoff um %s',
        [PV(gpFltAttack), PV(gpFltDecay), PV(gpFltSustain), PV(gpFltRelease), PV(gpFltEnvAmt)]);
    Add('6. Filter', T + '.' + Nt);
    Chain := Chain + ' -> Filter';
  end;
  if Active(gpEchoOn, Nt) then
  begin
    if IsOn(gpEchoSync) then
      T := 'Wiederholung im Takt alle ' + LFO_DIV_NAMES[EchoDivisionIndex(N(gpEchoTime))]
    else
      T := 'Wiederholung alle ' + PV(gpEchoTime);
    T := Format('%s, Rückkopplung %s, Dämpfung %s, Mix %s', [T, PV(gpEchoFeedback), PV(gpEchoDamp), PV(gpEchoMix)]);
    if IsOn(gpEchoPingPong) then T := T + ', springt links/rechts';
    if Abs(Plain(gpEchoPitch)) > 0.05 then
      T := T + '; ECHO-TREPPE: jede Wiederholung um ' + PV(gpEchoPitch) + ' versetzt';
    Add('7. Echo', T + '.' + Nt);
    Chain := Chain + ' -> Echo';
  end;
  if Active(gpRevOn, Nt) then
  begin
    T := Format('Raumgröße %s, Nachhall %s, Höhendämpfung %s, Vorverzögerung %s, Mix %s',
      [PV(gpRevSize), PV(gpRevDecay), PV(gpRevDamp), PV(gpRevPreDelay), PV(gpRevMix)]);
    if IsOn(gpFreeze) then T := T + '; FREEZE: der Raum hält den Klang fast unbegrenzt';
    Add('8. Hall', T + '.' + Nt);
    Chain := Chain + ' -> Hall';
  end;
  if Plain(gpDrive) > 0.5 then
  begin
    Add('9. Sättigung', 'warme Übersteuerung ' + PV(gpDrive) + '.');
    Chain := Chain + ' -> Sättigung';
  end;
  if IsOn(gpLimiter) then
    Chain := Chain + ' -> Limiter -> weicher Clipper -> Ausgang'
  else
    Chain := Chain + ' -> weicher Clipper -> Ausgang';
  Add('Signalweg', Chain + '.');
  Add('Programm', 'GranularSynth ' + APP_VERSION + ' - Copyright (C) 2026 Matthias Haberecht - freie Software unter der GNU GPL Version 3 oder neuer, ohne Gewaehrleistung (LICENSE.txt im Plugin-Ordner)');
  Result := Rows;
end;

{ TInfoForm }

constructor TInfoForm.CreateInfo(AOwner: TComponent; AEngine: TGranularEngine);
var
  L: TLabel;
  Sp: TSplitter;
begin
  inherited CreateNew(AOwner);
  FEngine := AEngine;
  Caption := 'Info - was passiert bei einem Tastendruck';
  BorderStyle := bsSizeToolWin;
  FormStyle := fsStayOnTop;
  Position := poScreenCenter;
  ClientWidth := 860;
  ClientHeight := 720;
  Color := COL_BG;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;
  OnResize := FormResize;
  // unten: Trigger-Protokoll (Engine schreibt nur, solange dieses Fenster offen ist)
  L := TLabel.Create(Self);
  L.Parent := Self;
  L.Align := alBottom;
  L.AlignWithMargins := True;
  L.Margins.SetBounds(8, 4, 8, 2);
  L.Caption := 'Trigger-Protokoll (live): Noten, Pitchbend/Modrad/Aftertouch, Ereignisse, Einmal-LFOs';
  FMoodLbl := TLabel.Create(Self);
  FMoodLbl.Parent := Self;
  FMoodLbl.Align := alBottom;
  FMoodLbl.AlignWithMargins := True;
  FMoodLbl.Margins.SetBounds(8, 4, 8, 0);
  FMoodLbl.Font.Color := COL_TEXT;
  FMoodLbl.Caption := 'Stimmung: -';
  L.Font.Color := COL_AREA;
  L.Font.Style := [fsBold];
  FLog := TMemo.Create(Self);
  FLog.Parent := Self;
  FLog.Align := alBottom;
  FLog.Height := 150;
  FLog.ReadOnly := True;
  FLog.ScrollBars := ssVertical;
  FLog.Color := COL_HEAD;
  FLog.Font.Name := 'Consolas';
  FLog.Font.Size := 9;
  FLog.Font.Color := COL_TEXT;
  FLog.BorderStyle := bsNone;
  FLog.WordWrap := False;
  L.Top := FLog.Top - 1;   // Ueberschrift ueber dem Protokoll
  Sp := TSplitter.Create(Self);
  Sp.Parent := Self;
  Sp.Align := alBottom;
  Sp.Height := 4;
  Sp.Top := L.Top - 1;
  OnShow := FormShow;
  OnHide := FormHide;
  FGrid := TStringGrid.Create(Self);
  FGrid.Parent := Self;
  FGrid.Align := alClient;
  FGrid.ColCount := 2;
  FGrid.FixedCols := 0;
  FGrid.FixedRows := 1;
  FGrid.DefaultDrawing := False;
  FGrid.Options := [goVertLine, goHorzLine];
  FGrid.Color := COL_BG;
  FGrid.DrawingStyle := gdsClassic;
  FGrid.StyleElements := [];
  FGrid.Font.Name := 'Segoe UI';
  FGrid.Font.Size := 9;
  FGrid.ScrollBars := ssVertical;
  FGrid.BorderStyle := bsNone;
  FGrid.OnDrawCell := GridDrawCell;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;   // Echtzeit: neu gezeichnet wird nur, wenn sich der Text aendert
  FTimer.OnTimer := TimerTick;
  Refresh(True);
end;

procedure TInfoForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    Close;
end;

procedure TInfoForm.FormResize(Sender: TObject);
begin
  FitRows;
end;

procedure TInfoForm.TimerTick(Sender: TObject);
begin
  if not Visible then
    Exit;   // geschlossen: nichts tun
  PollLog;
  with FEngine.GetMood do
    FMoodLbl.Caption := Format('Stimmung der Musik: %s   (Valenz %s, Energie %.2f, zärtlich %.2f)',
      [Name, FormatFloat('+0.00;-0.00;0.00', Valence), Arousal, Tender]);
  Refresh;
end;

procedure TInfoForm.FormShow(Sender: TObject);
begin
  FEngine.ReadTriggerLog(FLogPos);   // Altes verwerfen
  FEngine.TriggerLog := True;
end;

procedure TInfoForm.FormHide(Sender: TObject);
begin
  FEngine.TriggerLog := False;
end;

procedure TInfoForm.PollLog;
const
  KIND_TEXT: array[TTrigLogKind] of string = ('Note an', 'Note aus', 'Sidechain-Trigger',
    'SC-Ton > Schwelle', 'Schwellen-Tor öffnet', 'Ruhe (Ruhe-Dauer erreicht)', '', '', '', '', '', '');
  NOTE_NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'H');

  function NoteStr(N: Integer): string;
  begin
    N := EnsureRange(N, 0, 127);
    Result := Format('%s%d (MIDI %d)', [NOTE_NAMES[N mod 12], N div 12 - 1, N]);
  end;

var
  Items: TArray<TTrigLogItem>;
  I: Integer;
  S: string;
begin
  Items := FEngine.ReadTriggerLog(FLogPos);
  if Length(Items) = 0 then
    Exit;
  FLog.Lines.BeginUpdate;
  try
    for I := 0 to High(Items) do
    begin
      S := Format('%9s s   ', [FormatFloat('0.00', Items[I].Time)]);
      case Items[I].Kind of
        tlNoteOn:
          begin
            S := S + Format('Note an   %-14s Velocity %3d (%3.0f %%)  Stimme %d', [NoteStr(Items[I].Arg),
              Round(Items[I].Val * 127), Items[I].Val * 100, Items[I].Lfo + 1]);
            if Abs(Items[I].Val2) > 0.01 then
              S := S + '  Glide von ' + FormatFloat('+0.0;-0.0', Items[I].Val2) + ' Halbtönen';
          end;
        tlNoteOff:
          S := S + Format('Note aus  %s', [NoteStr(Items[I].Arg)]);
        tlBend:
          S := S + Format('Pitchbend %5.0f %%  (%s Halbtöne)  MIDI %d', [Items[I].Val * 100,
            FormatFloat('+0.00;-0.00;0.00', Items[I].Val2), EnsureRange(Round(8192 + Items[I].Val * 8192), 0, 16383)]);
        tlControl:
          S := S + Format('Modrad    %5.0f %%  (CC 1 = %d)', [Items[I].Val * 100, Round(Items[I].Val * 127)]);
        tlPressure:
          S := S + Format('Aftertouch %4.0f %%  (%d)', [Items[I].Val * 100, Round(Items[I].Val * 127)]);
        tlScTrig:
          begin
            S := S + Format('Ereignis: Sidechain-Trigger  Pegel %.0f %% (Schwelle %.0f %%)',
              [Items[I].Val * 100, Items[I].Val2 * 100]);
          end;
        tlOutTrig:
          S := S + Format('Ereignis: Ausgang > Schwelle  Pegel %.0f %% (Schwelle %.0f %%)',
            [Items[I].Val * 100, Items[I].Val2 * 100]);
        tlScPitch:
          S := S + Format('Ereignis: SC-Ton > Schwelle  erkannt %s, Schwelle %s',
            [NoteStr(Round(Items[I].Val)), NoteStr(Round(Items[I].Val2))]);
        tlLfoStart:
          S := S + Format('  -> Einmal-LFO %d startet (%s)', [Items[I].Lfo + 1,
            LFO_TRIG_NAMES[EnsureRange(Items[I].Arg, 0, High(LFO_TRIG_NAMES))]]);
        tlLfoEnd:
          S := S + Format('  -> LFO %d Einmal-Durchlauf beendet', [Items[I].Lfo + 1]);
      else
        S := S + 'Ereignis: ' + KIND_TEXT[Items[I].Kind];
      end;
      FLog.Lines.Add(S);
      Inc(FLogLines);
    end;
    // nur die letzten 300 Zeilen behalten
    while FLog.Lines.Count > 300 do
      FLog.Lines.Delete(0);
  finally
    FLog.Lines.EndUpdate;
  end;
  FLog.SelStart := Length(FLog.Text);
  FLog.Perform(EM_SCROLLCARET, 0, 0);
end;

procedure TInfoForm.Refresh(Force: Boolean);
var
  Rows: TArray<TInfoRow>;
  I: Integer;
  Key: string;
begin
  Rows := BuildInfo(FEngine);
  Key := '';
  for I := 0 to High(Rows) do
    Key := Key + Rows[I].Area + #1 + Rows[I].Text + #2;
  if (Key = FLast) and not Force then
    Exit;   // nichts geaendert -> nichts zeichnen
  FLast := Key;
  FGrid.RowCount := Length(Rows) + 1;
  FGrid.Cells[0, 0] := 'Schritt';
  FGrid.Cells[1, 0] := 'Was passiert';
  for I := 0 to High(Rows) do
  begin
    FGrid.Cells[0, I + 1] := Rows[I].Area;
    FGrid.Cells[1, I + 1] := Rows[I].Text;
  end;
  FitRows;
  FGrid.Invalidate;
end;

{ Zeilenhoehe nach umbrochenem Text }
procedure TInfoForm.FitRows;
var
  R: Integer;
  Rc: TRect;
  W: Integer;
begin
  if FGrid = nil then
    Exit;
  FGrid.ColWidths[0] := 130;
  W := Max(100, FGrid.ClientWidth - FGrid.ColWidths[0] - 4);
  FGrid.ColWidths[1] := W;
  FGrid.Canvas.Font := FGrid.Font;
  FGrid.RowHeights[0] := 24;
  for R := 1 to FGrid.RowCount - 1 do
  begin
    Rc := Rect(0, 0, W - 12, 0);
    DrawText(FGrid.Canvas.Handle, PChar(FGrid.Cells[1, R]), -1, Rc, DT_WORDBREAK or DT_CALCRECT or DT_NOPREFIX);
    FGrid.RowHeights[R] := Max(24, Rc.Height + 10);
  end;
end;

procedure TInfoForm.GridDrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
var
  C: TCanvas;
  R: TRect;
begin
  C := FGrid.Canvas;
  if ARow = 0 then
    C.Brush.Color := COL_HEAD
  else if Odd(ARow) then
    C.Brush.Color := COL_BG
  else
    C.Brush.Color := COL_BG2;
  C.FillRect(Rect);
  C.Font := FGrid.Font;
  if (ARow = 0) or (ACol = 0) then
  begin
    C.Font.Color := COL_AREA;
    C.Font.Style := [fsBold];
  end
  else
    C.Font.Color := COL_TEXT;
  R := Rect;
  InflateRect(R, -6, -5);
  DrawText(C.Handle, PChar(FGrid.Cells[ACol, ARow]), -1, R, DT_WORDBREAK or DT_NOPREFIX);
end;

end.
