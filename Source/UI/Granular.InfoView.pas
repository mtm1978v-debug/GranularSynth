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
  Granular.Lang,
  Winapi.Windows, Winapi.Messages, System.Classes, System.SysUtils, System.Math, System.Types, System.IOUtils,
  Vcl.Controls, Vcl.Forms, Vcl.Grids, Vcl.ExtCtrls, Vcl.Graphics, Vcl.StdCtrls, Vcl.ComCtrls,
  Granular.Fader, Granular.Params, Granular.Engine;

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
procedure ShowHelpWindow(AOwner: TComponent; const FileName: string; Changelog: Boolean = False);

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
    FEd: TRichEdit;
    FHelpFile, FChangeFile: string;
    FBtnHelp, FBtnChange: TButton;
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure BtnClick(Sender: TObject);
    { False = Hilfe (RTF), True = Changelog (CHANGELOG.md, fuer die Anzeige in RTF umgesetzt) }
    procedure ShowDoc(Changelog: Boolean);
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

{ Markdown des Changelogs (Ueberschriften #/##/###, Aufzaehlungen -, Fett **, Kursiv *, Code `, Trenner ---)
  in einfaches RTF in den Farben der Hilfe umsetzen }
function MarkdownToRtf(const Md: string): string;
var
  Lines: TStringList;
  I, K, Ind: Integer;
  L, T, Out: string;
  Bold, Ital: Boolean;

  function Esc(const S: string): string;
  var
    C: Char;
  begin
    Result := '';
    for C in S do
      case C of
        '\', '{', '}': Result := Result + '\' + C;
      else
        if Ord(C) > 127 then
          Result := Result + '\u' + IntToStr(SmallInt(Ord(C))) + '?'
        else
          Result := Result + C;
      end;
  end;

  { Inline: **fett**, *kursiv*, `code` }
  function InlineMd(const S: string): string;
  var
    J: Integer;
  begin
    Result := '';
    J := 1;
    while J <= Length(S) do
    begin
      if (S[J] = '*') and (J < Length(S)) and (S[J + 1] = '*') then
      begin
        Bold := not Bold;
        if Bold then Result := Result + '\b ' else Result := Result + '\b0 ';
        Inc(J, 2);
        Continue;
      end;
      if S[J] = '*' then
      begin
        Ital := not Ital;
        if Ital then Result := Result + '\i ' else Result := Result + '\i0 ';
        Inc(J);
        Continue;
      end;
      if S[J] = '`' then
      begin
        Inc(J);
        Continue;
      end;
      Result := Result + Esc(S[J]);
      Inc(J);
    end;
    if Bold then Result := Result + '\b0 ';
    if Ital then Result := Result + '\i0 ';
    Bold := False;
    Ital := False;
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Text := Md;
    Out := '{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}' +
      '{\colortbl;\red220\green220\blue220;\red224\green168\blue64;\red150\green150\blue150;}' +
      '\f0\fs19\cf1 ';
    Bold := False;
    Ital := False;
    for I := 0 to Lines.Count - 1 do
    begin
      L := Lines[I];
      T := TrimLeft(L);
      if T = '' then
        Continue;
      if T.StartsWith('### ') then
        Out := Out + '\pard\sb120{\b\fs21\cf1 ' + InlineMd(Copy(T, 5, MaxInt)) + '}\par' + sLineBreak
      else if T.StartsWith('## ') then
        Out := Out + '\pard\sb240\sa60{\b\fs25\cf2 ' + InlineMd(Copy(T, 4, MaxInt)) + '}\par' + sLineBreak
      else if T.StartsWith('# ') then
        Out := Out + '\pard\sa120{\b\fs30\cf2 ' + InlineMd(Copy(T, 3, MaxInt)) + '}\par' + sLineBreak
      else if T = '---' then
        Out := Out + '\pard\sb60{\cf3 ' + StringOfChar('_', 60) + '}\par' + sLineBreak
      else if T.StartsWith('- ') then
      begin
        Ind := 0;
        K := 1;
        while (K <= Length(L)) and (L[K] = ' ') do Inc(K);
        Ind := (K - 1) div 2;                     // zwei Leerzeichen je Ebene
        Out := Out + Format('\pard\li%d\fi-200\sa30 \bullet  ', [300 + Ind * 320]) +
          InlineMd(Copy(T, 3, MaxInt)) + '\par' + sLineBreak;
      end
      else
        Out := Out + '\pard\sa60 ' + InlineMd(T) + '\par' + sLineBreak;
    end;
    Result := Out + '}';
  finally
    Lines.Free;
  end;
end;

procedure THelpForm.ShowDoc(Changelog: Boolean);
var
  Md: string;
  St: TStringStream;
begin
  FEd.Lines.BeginUpdate;
  try
    if Changelog then
    begin
      if FileExists(FChangeFile) then
      begin
        Md := TFile.ReadAllText(FChangeFile, TEncoding.UTF8);
        St := TStringStream.Create(MarkdownToRtf(Md), TEncoding.ASCII);
        try
          FEd.PlainText := False;
          FEd.Lines.LoadFromStream(St);
        finally
          St.Free;
        end;
      end
      else
        FEd.Lines.Text := Tr('Changelog nicht gefunden: ') + FChangeFile;
    end
    else if FileExists(FHelpFile) then
      FEd.Lines.LoadFromFile(FHelpFile)
    else
      FEd.Lines.Text := Tr('Hilfedatei nicht gefunden: ') + FHelpFile;
  finally
    FEd.Lines.EndUpdate;
  end;
  FEd.SelStart := 0;
  FEd.Perform(EM_SCROLLCARET, 0, 0);
  FBtnHelp.Active := not Changelog;
  FBtnChange.Active := Changelog;
end;

procedure THelpForm.BtnClick(Sender: TObject);
begin
  ShowDoc(Sender = FBtnChange);
end;

procedure ShowHelpWindow(AOwner: TComponent; const FileName: string; Changelog: Boolean);
var
  Ed: TRichEdit;
  Bar: TPanel;
begin
  if HelpForm <> nil then
  begin
    HelpForm.ShowDoc(Changelog);
    HelpForm.Show;
    HelpForm.BringToFront;
    Exit;
  end;
  HelpForm := THelpForm.CreateNew(AOwner);
  HelpForm.Caption := Tr('GRANULAR - Hilfe  (FM ') + #$00B7 + Tr(' Synthese ') + #$00B7 + Tr(' HABI M ') + #$00B7 + Tr(' Version ') + APP_VERSION + ')';
  HelpForm.BorderStyle := bsSizeToolWin;
  HelpForm.FormStyle := fsStayOnTop;
  HelpForm.Position := poScreenCenter;
  HelpForm.ClientWidth := 720;
  HelpForm.ClientHeight := 640;
  HelpForm.Color := COL_BG;
  HelpForm.KeyPreview := True;
  HelpForm.OnKeyDown := HelpForm.FormKeyDown;
  // Umschalter oben: Hilfe / Changelog
  Bar := TPanel.Create(HelpForm);
  Bar.Parent := HelpForm;
  Bar.Align := alTop;
  Bar.Height := 34;
  Bar.BevelOuter := bvNone;
  Bar.ParentBackground := False;
  Bar.Color := COL_BG;
  HelpForm.FBtnHelp := TButton.Create(HelpForm);
  HelpForm.FBtnHelp.Parent := Bar;
  HelpForm.FBtnHelp.SetBounds(12, 6, 110, 24);
  HelpForm.FBtnHelp.Caption := Tr('Hilfe');
  HelpForm.FBtnHelp.TabStop := False;
  HelpForm.FBtnHelp.OnClick := HelpForm.BtnClick;
  HelpForm.FBtnChange := TButton.Create(HelpForm);
  HelpForm.FBtnChange.Parent := Bar;
  HelpForm.FBtnChange.SetBounds(128, 6, 170, 24);
  HelpForm.FBtnChange.Caption := Tr('Änderungen (Changelog)');
  HelpForm.FBtnChange.TabStop := False;
  HelpForm.FBtnChange.OnClick := HelpForm.BtnClick;
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
  HelpForm.FEd := Ed;
  HelpForm.FHelpFile := FileName;
  // CHANGELOG.md liegt im Plugin-Ordner, die Hilfe darunter im Ordner Hilfe
  HelpForm.FChangeFile := ExpandFileName(ExtractFilePath(FileName) + '..' + PathDelim + 'CHANGELOG.md');
  HelpForm.ShowDoc(Changelog);
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
      Part := Format(Tr('%s (%s %%'), [DestName(D), Sgn(Amt)]);
      if MOD_FACTORS[F] <> 1 then
        Part := Part + ', ' + MOD_FACTOR_NAMES[F];
      if Abs(Ofs) > 0.5 then
        Part := Part + Tr(', Offset ') + Sgn(Ofs) + ' %';
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
      if IsOn(Id) then Note := Tr(' [wird zusätzlich von ') + By + Tr(' beeinflusst]')
      else Note := Tr(' [nur eingeschaltet, solange ') + By + Tr(' es einschaltet]');
    Result := IsOn(Id) or (By <> '');
  end;

  function LfoText(K: Integer): string;
  var
    F: PFreeLfo;
    I: Integer;
    Shp, TrgTxt, Steps: string;
  begin
    Shp := LFO_SHAPE_NAMES[EnsureRange(St(LFO_SHAPE_IDS[K]), 0, 5)];
    if St(LFO_SHAPE_IDS[K]) = LFO_SHAPE_FREE then
    begin
      F := E.FreeLfo[LFO_FREE_IDX[K]];
      if F.Mode = 2 then
        Shp := Tr('freie, gezeichnete Kurve')
      else
      begin
        Steps := '';
        for I := 0 to Min(F.Steps, 16) - 1 do
          if F.Mode = 0 then
            Steps := Steps + Sgn(Round(F.Step[I] * FREE_SEMIS)) + ' '
          else
            Steps := Steps + Format(Tr('%.0f%% '), [F.Step[I] * 100]);
        if F.Steps > 16 then Steps := Steps + '...';
        if F.Mode = 0 then
          Shp := Format(Tr('frei, %d Halbton-Stufen (%s)'), [F.Steps, Trim(Steps)])
        else
          Shp := Format(Tr('frei, %d Stufen (%s)'), [F.Steps, Trim(Steps)]);
      end;
    end;
    if IsOn(LFO_SYNC_IDS[K]) then
      Result := Format(Tr('%s, im Takt: ein Durchlauf = %s'), [Shp, LFO_DIV_NAMES[LfoDivisionIndex(N(LFO_RATE_IDS[K]))]])
    else
      Result := Format(Tr('%s, %s'), [Shp, PV(LFO_RATE_IDS[K])]);
    case St(LFO_TRIG_IDS[K]) of
      0: TrgTxt := Tr('läuft frei durch');
      1: TrgTxt := Tr('startet mit jeder Note neu');
      2: TrgTxt := Tr('startet beim Loslassen einer Taste neu');
      3: TrgTxt := Tr('startet bei Note an und Note aus neu');
      4: TrgTxt := Format(Tr('startet, wenn LFO %d seinen Einmal-Durchlauf beendet'), [(K xor 1) + 1]);
      5: TrgTxt := Tr('startet, wenn der Sidechain-Pegel ') + PV(gpScTrigLevel) + Tr(' überschreitet');
      6: TrgTxt := Tr('startet, wenn die Sidechain-Tonhöhe über ') + PV(gpScTrigNote) + Tr(' steigt');
      7: TrgTxt := Tr('startet, wenn das Schwellen-Tor öffnet');
    end;
    Result := Result + '; ' + TrgTxt;
    if IsOn(LFO_ONCE_IDS[K]) then
      Result := Result + Tr(', läuft nur EINMAL und bleibt dann am Ende stehen')
    else
      Result := Result + Tr(', wiederholt sich');
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
    BInfo := Tr(' Klang B spielt sein eigenes Sample (') + ChangeFileExt(ExtractFileName(E.MorphSampleLoaded), '') +
      Tr('): so viele Grains wie die Morph-Stellung kommen daraus.')
  else
    BInfo := '';

  // 1) Taste
  if Active(gpArpOn, Nt) then
  begin
    Mask := E.ArpMask;
    Pat := '';
    for K := 0 to St(gpArpSteps) do
      if Mask and (1 shl K) <> 0 then Pat := Pat + 'x' else Pat := Pat + '.';
    Add(Tr('1. Taste'),
      Format(Tr('Arpeggiator: die gehaltenen Tasten laufen "%s" über %s in %s-Schritten (Länge %s, Swing %s). ' +
        'Muster %s (x = spielt, . = Pause).%s'),
        [PV(gpArpMode), PV(gpArpOct), PV(gpArpRate), PV(gpArpGate), PV(gpArpSwing), Pat, Nt]));
  end
  else
    Add(Tr('1. Taste'), Tr('Jede Taste startet eine eigene Stimme (mehrstimmig).'));

  // 2) Tonhoehe
  if IsOn(gpKeyTrack) then T := Tr('folgt der Taste') else T := Tr('bleibt fest (Tasten ändern die Tonhöhe nicht)');
  if Abs(Plain(gpPitch)) > 0.01 then T := T + Tr(', verschoben um ') + PV(gpPitch);
  if Plain(gpPitchRand) > 0.01 then T := T + Tr(', je Grain zufällig +/- ') + PV(gpPitchRand);
  if St(gpScale) > 0 then T := T + Format(Tr(', rastet auf %s-%s ein'), [PV(gpScaleRoot), PV(gpScale)]);
  if St(gpScPitchMode) > 0 then T := T + Tr(', Auto-Pitch: folgt der Tonhöhe am Sidechain (') + PV(gpScPitchMode) + ')';
  Add(Tr('2. Tonhöhe'), T + '.');

  // 3) Grains
  T := Format(Tr('%s Grains pro Sekunde, je %s lang (Fenster %s), aus dem Bereich %s bis %s des Samples'),
    [PV(gpDensity), PV(gpGrainSize), PV(gpWindow), PV(gpSelStart), PV(gpSelEnd)]);
  if IsOn(gpFreeze) then
    T := T + Tr('; FREEZE: die Abspielposition steht still')
  else
    T := T + Tr('; Abspielgeschwindigkeit ') + PV(gpScan);
  if Plain(gpSpray) > 0.5 then T := T + Tr(', Positions-Streuung ') + PV(gpSpray);
  if Plain(gpReverse) > 0.5 then T := T + ', ' + PV(gpReverse) + Tr(' rückwärts');
  T := T + Tr(', Stereobreite ') + PV(gpSpread) + '.';
  Add(Tr('3. Grains'), T);

  // 4) Huellkurve
  Add(Tr('4. Lautstärke'), Format(Tr('Anschwellen %s, Abfall %s auf %s, nach dem Loslassen Ausklang %s. Lautstärke %s.'),
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
      Add(Format(Tr('5. LFO %d'), [K + 1]), LfoText(K) + Tr('. Bewegt: ') + Targets(LFO_SRC[K]) + '.');
  if UsedSrc[msGate] or (St(gpLfo1Trig) = LFO_TRIG_GATE) or (St(gpLfo2Trig) = LFO_TRIG_GATE) then
  begin
    T := Format(Tr('öffnet, wenn "%s" über %s steigt (schließt knapp darunter wieder)'), [PV(gpGateSrc), PV(gpGateThresh)]);
    if UsedSrc[msGate] then T := T + Tr('. Schaltet: ') + Targets(msGate);
    Add(Tr('5. Schwellen-Tor'), T + '.');
  end;
  for M := msSidechain to High(TModSource) do
    if UsedSrc[M] and (M <> msGate) and (LfoOfSource(Ord(M)) < 0) then
      Add('5. ' + MOD_SOURCE_NAMES[M], Tr('steuert ') + Targets(M) + '.');
  if UsedSrc[msSidechain] or (St(gpLfo1Trig) in [LFO_TRIG_SC_LEVEL, LFO_TRIG_SC_PITCH]) or
     (St(gpLfo2Trig) in [LFO_TRIG_SC_LEVEL, LFO_TRIG_SC_PITCH]) then
    Add(Tr('   Sidechain'), Format(Tr('Eingang verstärkt um %s, reagiert in %s, fällt in %s ab.'),
      [PV(gpScGain), PV(gpScAttack), PV(gpScRelease)]));
  if E.MorphValid and (St(gpMorphLfoShape) > 0) then
  begin
    if IsOn(gpMorphLfoSync) then T := Tr('im Takt (') + LFO_DIV_NAMES[LfoDivisionIndex(N(gpMorphLfoRate))] + ')'
    else T := PV(gpMorphLfoRate);
    Add(Tr('   Morph'), Format(Tr('Morph-LFO (%s, %s) pendelt um %s mit Tiefe %s zwischen Klang A (0 %%) und B (100 %%).%s'),
      [PV(gpMorphLfoShape), T, PV(gpMorph), PV(gpMorphLfoDepth), BInfo]));
  end
  else if E.MorphValid and (Plain(gpMorph) > 0.5) then
    Add(Tr('   Morph'), Tr('blendet ') + PV(gpMorph) + Tr(' zum gemerkten Klang B.') + BInfo)
  else if E.MorphValid and UsedSrc[msOff] then
    Add(Tr('   Morph'), Tr('Ziel B ist gemerkt.'));

  // 6) Effektkette
  Chain := Tr('Grains');
  if Active(gpFltOn, Nt) and (Plain(gpFltContour) > 0.5) then
  begin
    T := Format(Tr('%s bei %s, Resonanz %s, Wirkung %s'), [PV(gpFltType), PV(gpFltCutoff), PV(gpFltReso), PV(gpFltContour)]);
    if Abs(Plain(gpFltEnvAmt)) > 0.5 then
      T := T + Format(Tr('; eigene Hüllkurve (%s / %s / %s / %s) verschiebt den Cutoff um %s'),
        [PV(gpFltAttack), PV(gpFltDecay), PV(gpFltSustain), PV(gpFltRelease), PV(gpFltEnvAmt)]);
    Add(Tr('6. Filter'), T + '.' + Nt);
    Chain := Chain + Tr(' -> Filter');
  end;
  if Active(gpEchoOn, Nt) then
  begin
    if IsOn(gpEchoSync) then
      T := Tr('Wiederholung im Takt alle ') + LFO_DIV_NAMES[EchoDivisionIndex(N(gpEchoTime))]
    else
      T := Tr('Wiederholung alle ') + PV(gpEchoTime);
    T := Format(Tr('%s, Rückkopplung %s, Dämpfung %s, Mix %s'), [T, PV(gpEchoFeedback), PV(gpEchoDamp), PV(gpEchoMix)]);
    if IsOn(gpEchoPingPong) then T := T + Tr(', springt links/rechts');
    if Abs(Plain(gpEchoPitch)) > 0.05 then
      T := T + Tr('; ECHO-TREPPE: jede Wiederholung um ') + PV(gpEchoPitch) + Tr(' versetzt');
    Add(Tr('7. Echo'), T + '.' + Nt);
    Chain := Chain + Tr(' -> Echo');
  end;
  if Active(gpRevOn, Nt) then
  begin
    T := Format(Tr('Raumgröße %s, Nachhall %s, Höhendämpfung %s, Vorverzögerung %s, Mix %s'),
      [PV(gpRevSize), PV(gpRevDecay), PV(gpRevDamp), PV(gpRevPreDelay), PV(gpRevMix)]);
    if IsOn(gpFreeze) then T := T + Tr('; FREEZE: der Raum hält den Klang fast unbegrenzt');
    Add(Tr('8. Hall'), T + '.' + Nt);
    Chain := Chain + Tr(' -> Hall');
  end;
  if Plain(gpDrive) > 0.5 then
  begin
    Add(Tr('9. Sättigung'), Tr('warme Übersteuerung ') + PV(gpDrive) + '.');
    Chain := Chain + Tr(' -> Sättigung');
  end;
  if IsOn(gpLimiter) then
    Chain := Chain + Tr(' -> Limiter -> weicher Clipper -> Ausgang')
  else
    Chain := Chain + Tr(' -> weicher Clipper -> Ausgang');
  Add(Tr('Signalweg'), Chain + '.');
  Add(Tr('Programm'), Tr('GranularSynth ') + APP_VERSION + Tr(' - Copyright (C) 2026 Matthias Haberecht - freie Software unter der GNU GPL Version 3 oder neuer, ohne Gewaehrleistung (LICENSE.txt im Plugin-Ordner)'));
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
  Caption := Tr('Info - was passiert bei einem Tastendruck');
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
  L.Caption := Tr('Trigger-Protokoll (live): Noten, Pitchbend/Modrad/Aftertouch, Ereignisse, Einmal-LFOs');
  FMoodLbl := TLabel.Create(Self);
  FMoodLbl.Parent := Self;
  FMoodLbl.Align := alBottom;
  FMoodLbl.AlignWithMargins := True;
  FMoodLbl.Margins.SetBounds(8, 4, 8, 0);
  FMoodLbl.Font.Color := COL_TEXT;
  FMoodLbl.Caption := Tr('Stimmung: -');
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
    FMoodLbl.Caption := Format(Tr('Stimmung der Musik: %s   (Valenz %s, Energie %.2f, zärtlich %.2f)'),
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
    Result := Format(Tr('%s%d (MIDI %d)'), [NOTE_NAMES[N mod 12], N div 12 - 1, N]);
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
      S := Format(Tr('%9s s   '), [FormatFloat('0.00', Items[I].Time)]);
      case Items[I].Kind of
        tlNoteOn:
          begin
            S := S + Format(Tr('Note an   %-14s Velocity %3d (%3.0f %%)  Stimme %d'), [NoteStr(Items[I].Arg),
              Round(Items[I].Val * 127), Items[I].Val * 100, Items[I].Lfo + 1]);
            if Abs(Items[I].Val2) > 0.01 then
              S := S + Tr('  Glide von ') + FormatFloat('+0.0;-0.0', Items[I].Val2) + Tr(' Halbtönen');
          end;
        tlNoteOff:
          S := S + Format(Tr('Note aus  %s'), [NoteStr(Items[I].Arg)]);
        tlBend:
          S := S + Format(Tr('Pitchbend %5.0f %%  (%s Halbtöne)  MIDI %d'), [Items[I].Val * 100,
            FormatFloat('+0.00;-0.00;0.00', Items[I].Val2), EnsureRange(Round(8192 + Items[I].Val * 8192), 0, 16383)]);
        tlControl:
          S := S + Format(Tr('Modrad    %5.0f %%  (CC 1 = %d)'), [Items[I].Val * 100, Round(Items[I].Val * 127)]);
        tlPressure:
          S := S + Format(Tr('Aftertouch %4.0f %%  (%d)'), [Items[I].Val * 100, Round(Items[I].Val * 127)]);
        tlScTrig:
          begin
            S := S + Format(Tr('Ereignis: Sidechain-Trigger  Pegel %.0f %% (Schwelle %.0f %%)'),
              [Items[I].Val * 100, Items[I].Val2 * 100]);
          end;
        tlOutTrig:
          S := S + Format(Tr('Ereignis: Ausgang > Schwelle  Pegel %.0f %% (Schwelle %.0f %%)'),
            [Items[I].Val * 100, Items[I].Val2 * 100]);
        tlScPitch:
          S := S + Format(Tr('Ereignis: SC-Ton > Schwelle  erkannt %s, Schwelle %s'),
            [NoteStr(Round(Items[I].Val)), NoteStr(Round(Items[I].Val2))]);
        tlLfoStart:
          S := S + Format(Tr('  -> Einmal-LFO %d startet (%s)'), [Items[I].Lfo + 1,
            LFO_TRIG_NAMES[EnsureRange(Items[I].Arg, 0, High(LFO_TRIG_NAMES))]]);
        tlLfoEnd:
          S := S + Format(Tr('  -> LFO %d Einmal-Durchlauf beendet'), [Items[I].Lfo + 1]);
      else
        S := S + Tr('Ereignis: ') + KIND_TEXT[Items[I].Kind];
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
  FGrid.Cells[0, 0] := Tr('Schritt');
  FGrid.Cells[1, 0] := Tr('Was passiert');
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
