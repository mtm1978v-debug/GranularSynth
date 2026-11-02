{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit MainForm;

{ GranularHost: kleiner VST2/VST3-Host ("Multitool").
    - laedt GranularSynth.dll oder jedes andere VST2- oder VST3-Plugin passender Bitbreite
    - Editor des Plugins eingebettet, Fenster passt sich an
    - Klaviatur (Maus + PC-Tastatur), Autoplay, Host-Tempo (Zeitinfo fuer Tempo-Sync)
    - Sidechain: Aufnahmegeraet -> Plugin-Eingaenge 1/2
    - Zustand je Plugin in %APPDATA%\GranularSynth\vst\ (automatisch), "Zuruecksetzen" loescht ihn
  Testschalter: -bench  -autoplay  -nosave  <Plugin.dll> }

interface

uses
  Granular.Lang,
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.StrUtils, System.Classes, System.Math,
  System.SyncObjs, System.IOUtils, System.IniFiles, System.UITypes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics,
  GR32, GR32_Image, Granular.ComboFit,
  Granular.Keyboard, Granular.AudioOut, Granular.AudioIn, Granular.AutoPlay,
  Granular.Vst2, Granular.VstHost, Granular.Vst3Host, Granular.Bench, Granular.PresetGen, Granular.DemoRender, Granular.Sample, Granular.AudioDecode, Granular.Prof,
  Granular.Fader;   // nach Vcl.ComCtrls: TTrackBar im DJ-Fader-Look

const
  WM_PLUGIN_SIZE = WM_USER + 101;

type
  { Pegelanzeige IN (Sidechain) / OUT, horizontal }
  THostMeter = class(TCustomPaintBox32)
  public
    PeakIn, PeakOut: Single;
    constructor Create(AOwner: TComponent); override;
  protected
    procedure DoPaintBuffer; override;
  end;

  TMidiMsg = record
    Status, Data1, Data2: Byte;
    Delta: Integer;
  end;

  TfrmMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormDeactivate(Sender: TObject);
  private
    // Audio
    FPlugin: TVstHostPlugin;
    FLock: TCriticalSection;           // Process <-> Laden/Entladen
    FPlayer: TWaveOutPlayer;
    FRecorder: TWaveInRecorder;
    FRing: TStereoRing;
    FInL, FInR: TArray<Single>;
    FTempo: Double;                    // Host-Tempo, Audio-Thread liest, GUI/Autoplay schreiben
    FAuto: TAutoPlayer;
    FMidiLock: TCriticalSection;
    FMidiQueue: array[0..255] of TMidiMsg;
    FMidiCount: Integer;
    FPeakIn, FPeakOut: Single;
    FNoSave: Boolean;
    FSampleRate, FBlockFrames, FBlockCount: Integer;

    // Oberflaeche
    FTopBar, FBottomBar, FBottomArea, FPluginArea: TPanel;
    FLoadButton, FResetButton, FPanicButton, FOctDown, FOctUp: TButton;
    FPluginLabel, FTempoLabel, FAutoLabel, FHintLabel: TLabel;
    FTempoTrack: TTrackBar;
    FAutoButton: TButton;
    FAutoCombo, FScCombo: TComboBox;
    FAutoAllCheck: TCheckBox;        // Autoplay: alle Stuecke statt nur der zum Preset passenden
    FPresetMask: Integer;            // zum Preset passende Stueckarten (aus dem Namen)
    FComboSongs: TArray<Integer>;    // Eintrag i+1 der Autoplay-Liste -> Songindex
    FProgName: string;               // zuletzt gemeldeter Presetname des Plugins
    FProgTick: Integer;
    FKeysCheck: TCheckBox;
    FKeys: TKeyboardView;
    FWheelArea: TPanel;
    FBendWheel, FModWheel: TWheelView;
    FMeter: THostMeter;
    FTimer: TTimer;
    FOctave: Integer;
    FKeyNote: array[Byte] of Integer;
    FShownAuto: array[0..127] of Boolean;
    FEditorW, FEditorH: Integer;
    FUpdatingTempo: Boolean;
    FHostTick: Integer;
    FResizable: Boolean;     // Plugin-Editor darf vom Host vergroessert werden

    procedure BuildUI;
    function MakeButton(AParent: TWinControl; const ACaption: string; X, W: Integer; AClick: TNotifyEvent): TButton;
    function MakeLabel(AParent: TWinControl; const ACaption: string; X, W: Integer): TLabel;

    // Plugin
    procedure LoadPlugin(const Path: string; RestoreState: Boolean = True);
    procedure UnloadPlugin(SaveState: Boolean);
    procedure SavePluginState;
    procedure ShowPluginEditor;
    procedure AdjustWindowSize;
    procedure PluginAreaResize(Sender: TObject);
    procedure PluginSizeRequest(Sender: TObject; Width, Height: Integer);
    procedure WMPluginSize(var Msg: TMessage); message WM_PLUGIN_SIZE;
    function StateDir: string;
    function PluginStateDir: string;

    // Audio-Thread
    procedure Render(OutL, OutR: System.PSingle; Frames: Integer);
    procedure EmitNote(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
    procedure QueueMidi(Status, Data1, Data2: Byte);

    // Ereignisse
    procedure LoadClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PanicClick(Sender: TObject);
    procedure OctaveClick(Sender: TObject);
    procedure TempoChange(Sender: TObject);
    procedure AutoButtonClick(Sender: TObject);
    procedure ScComboChange(Sender: TObject);
    procedure KeysCheckClick(Sender: TObject);
    procedure KeyboardNote(Sender: TObject; Note: Integer; IsOn: Boolean);
    procedure AutoComboChange(Sender: TObject);
    procedure AutoComboCloseUp(Sender: TObject);
    procedure AutoAllClick(Sender: TObject);
    procedure ApplyAutoMask;
    procedure WheelChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure FillAutoCombo(Mask: Integer);
    procedure MidiExportClick(Sender: TObject);
    procedure CheckPresetKind;
    function PcKeyToSemitone(Key: Word): Integer;
    procedure ReleasePcKeys;
    procedure UpdateTempoLabel;

    // Einstellungen
    procedure LoadHostSettings;
    procedure SaveHostSettings;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

{$POINTERMATH ON}

const
  HOST_INI = 'host.ini';
  // 32- und 64-Bit-Host teilen sich host.ini - der Pluginpfad muss je Bitbreite getrennt sein
  {$IFDEF WIN64}
  PLUGIN_KEY = 'Pfad64';
  {$ELSE}
  PLUGIN_KEY = 'Pfad32';
  {$ENDIF}
  BG_DARK = $002A2624;
  BG_MAIN = $00383230;
  COL_TEXT = $00DCDCDC;
  COL_VAL = $005AD2FF;
  BAR_H = 36;
  KEYS_H = 70;

{ THostMeter }

constructor THostMeter.Create(AOwner: TComponent);
begin
  inherited;
  BufferOversize := 0;
end;

procedure THostMeter.DoPaintBuffer;
var
  B: TBitmap32;
  W, H, X: Integer;

  procedure Bar(Y: Integer; Peak: Single; const Cap: string; Col: TColor32);
  var
    Db, L: Double;
  begin
    if Peak > 0.000001 then Db := 20 * Log10(Peak) else Db := -100;
    L := EnsureRange((Db + 60) / 60, 0, 1);
    B.FillRectS(28, Y, W - 2, Y + 8, $FF0E0F12);
    X := 28 + Round(L * (W - 30));
    if X > 28 then
      B.FillRectS(28, Y, X, Y + 8, IfThen(Db > -1, Integer($FFFF5A5A), Integer(Col)));
    B.Textout(2, Y - 3, Cap);
  end;

begin
  Buffer.BeginUpdate;   // Aenderungsmeldungen je Zeichenaufruf unterdruecken (sehr teuer)
  try
  B := Buffer;
  W := B.Width;
  H := B.Height;
  B.Clear($FF16181C);
  B.Font.Name := 'Tahoma';
  B.Font.Size := 7;
  B.Font.Color := $C8C8C8;
  Bar(H div 2 - 11, PeakIn, 'IN', $FFFFA040);
  Bar(H div 2 + 3, PeakOut, 'OUT', $FF78C88C);
  finally
    Buffer.EndUpdate;
  end;
  inherited;
end;

function DecodeTest(const FileName: string): string;
var
  D: TSampleData;
  F: Integer;
  Peak, T0: Double;
begin
  T0 := Now;
  try
    D := LoadAudioFile(FileName);
    try
      Peak := 0;
      for F := 0 to D.Frames - 1 do
        Peak := Max(Peak, Max(Abs(D.L[F]), Abs(D.R[F])));
      Result := Format(Tr('OK: %d Hz, %d Kanäle, %.2f s, Spitze %.3f, Dauer %.0f ms'),
        [Round(D.SampleRate), D.Channels, D.Frames / D.SampleRate, Peak, (Now - T0) * 86400000]);
    finally
      D.Free;
    end;
  except
    on E: Exception do
      Result := Tr('FEHLER: ') + E.Message;
  end;
end;

{ TfrmMain }

function TfrmMain.StateDir: string;
begin
  // %APPDATA%\GranularSynth - auch ohne Schreibrecht im Programmordner nutzbar
  Result := TPath.Combine(TPath.GetHomePath, 'GranularSynth');
end;

function TfrmMain.PluginStateDir: string;
begin
  Result := TPath.Combine(StateDir, 'vst');
end;

function TfrmMain.MakeButton(AParent: TWinControl; const ACaption: string; X, W: Integer;
  AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, 6, W, 25);
  Result.Caption := ACaption;
  Result.TabStop := False;
  Result.OnClick := AClick;
end;

function TfrmMain.MakeLabel(AParent: TWinControl; const ACaption: string; X, W: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, 11, W, 16);
  Result.Caption := ACaption;
  Result.Font.Color := COL_TEXT;
  Result.Transparent := True;
end;

procedure TfrmMain.BuildUI;
var
  I: Integer;
  Dev: string;
begin
  Color := BG_MAIN;

  // --- Kopfleiste: Plugin, Tempo, Oktave ---
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := alTop;
  FTopBar.Height := BAR_H;
  FTopBar.BevelOuter := bvNone;
  FTopBar.ParentBackground := False;
  FTopBar.Color := BG_DARK;
  FLoadButton := MakeButton(FTopBar, Tr('VST laden...'), 8, 96, LoadClick);
  FResetButton := MakeButton(FTopBar, Tr('Zurücksetzen'), 108, 96, ResetClick);
  FResetButton.Hint := Tr('Gespeicherte Einstellungen dieses Plugins löschen und neu laden');
  FResetButton.ShowHint := True;
  FPluginLabel := MakeLabel(FTopBar, Tr('(kein Plugin)'), 212, 230);
  FPluginLabel.Font.Color := COL_VAL;
  FPluginLabel.Font.Style := [fsBold];
  MakeLabel(FTopBar, Tr('Tempo'), 448, 40);
  FTempoTrack := TTrackBar.Create(Self);
  FTempoTrack.Parent := FTopBar;
  FTempoTrack.SetBounds(488, 6, 160, 24);
  FTempoTrack.TickStyle := tsNone;
  FTempoTrack.ThumbLength := 16;
  FTempoTrack.Min := 40;
  FTempoTrack.Max := 240;
  FTempoTrack.Position := 120;
  FTempoTrack.TabStop := False;
  FTempoTrack.OnChange := TempoChange;
  FTempoLabel := MakeLabel(FTopBar, Tr('120 BPM'), 652, 60);
  FTempoLabel.Font.Color := COL_VAL;
  FPanicButton := MakeButton(FTopBar, Tr('Alle Noten aus'), 716, 96, PanicClick);
  FOctDown := MakeButton(FTopBar, Tr('Okt -'), 818, 44, OctaveClick);
  FOctUp := MakeButton(FTopBar, Tr('Okt +'), 864, 44, OctaveClick);

  // --- Klaviatur: vor der Fussleiste erzeugt -> liegt darueber ---
  // Container fuer Klaviatur + Fussleiste: feste Reihenfolge unabhaengig von der Erzeugung
  FBottomArea := TPanel.Create(Self);
  FBottomArea.Parent := Self;
  FBottomArea.Align := alBottom;
  FBottomArea.Height := KEYS_H + BAR_H;
  FBottomArea.BevelOuter := bvNone;
  FKeys := TKeyboardView.Create(Self);
  FKeys.Parent := FBottomArea;
  FKeys.Align := alClient;
  FKeys.OnNote := KeyboardNote;
  // Pitchbend (federt zurueck) und Modrad (bleibt stehen) links neben der Klaviatur
  FWheelArea := TPanel.Create(Self);
  FWheelArea.Parent := FBottomArea;
  FWheelArea.Align := alLeft;
  FWheelArea.Width := 72;
  FWheelArea.BevelOuter := bvNone;
  FWheelArea.ParentBackground := False;
  FWheelArea.Color := BG_DARK;
  FBendWheel := TWheelView.Create(Self, Tr('Bend'), True);
  FBendWheel.Parent := FWheelArea;
  FBendWheel.SetBounds(6, 4, 28, KEYS_H - 8);
  FBendWheel.OnChange := WheelChange;
  FBendWheel.Hint := Tr('Pitchbend: ziehen, beim Loslassen federt es zurück');
  FModWheel := TWheelView.Create(Self, Tr('Mod'), False);
  FModWheel.Parent := FWheelArea;
  FModWheel.SetBounds(38, 4, 28, KEYS_H - 8);
  FModWheel.OnChange := WheelChange;
  FModWheel.Hint := Tr('Modrad (MIDI CC 1): bleibt stehen');

  // --- Fussleiste: Autoplay, Sidechain, Pegel, Klaviatur ---
  FBottomBar := TPanel.Create(Self);
  FBottomBar.Parent := FBottomArea;
  FBottomBar.Align := alBottom;
  FBottomBar.Height := BAR_H;
  FBottomBar.BevelOuter := bvNone;
  FBottomBar.ParentBackground := False;
  FBottomBar.Color := BG_DARK;
  FAutoButton := MakeButton(FBottomBar, Tr('Autoplay Start'), 8, 100, AutoButtonClick);
  FAutoCombo := TComboBox.Create(Self);
  FAutoCombo.Parent := FBottomBar;
  EnableComboFit(FAutoCombo);
  FAutoCombo.Style := csDropDownList;
  FAutoCombo.SetBounds(112, 8, 176, 21);
  MakeButton(FBottomBar, Tr('MIDI ...'), 292, 54, MidiExportClick).Hint :=
    Tr('Gewähltes Stück als MIDI-Datei speichern (bei "Zufall": alle passenden Stücke in einen Ordner)');
  FAutoCombo.TabStop := False;
  FAutoCombo.DropDownCount := 20;
  FAutoCombo.OnChange := AutoComboChange;      // Auswahl startet das Stueck sofort
  FAutoCombo.OnCloseUp := AutoComboCloseUp;
  FillAutoCombo(SONG_ALL);
  // alle Stuecke zeigen, auch wenn das Preset nur zu Liegetoenen/Arps passt (z.B. Flaeche mit flotter Musik)
  FAutoAllCheck := TCheckBox.Create(Self);
  FAutoAllCheck.Parent := FBottomBar;
  FAutoAllCheck.SetBounds(350, 7, 22, 22);
  FAutoAllCheck.TabStop := False;
  FAutoAllCheck.Hint := Tr('Alle Stücke anzeigen, nicht nur die zum Preset passenden');
  FAutoAllCheck.ShowHint := True;
  FAutoAllCheck.OnClick := AutoAllClick;
  MakeLabel(FBottomBar, Tr('alle'), 375, 30);
  MakeLabel(FBottomBar, Tr('Sidechain:'), 404, 60);
  FScCombo := TComboBox.Create(Self);
  FScCombo.Parent := FBottomBar;
  EnableComboFit(FScCombo);
  FScCombo.Style := csDropDownList;
  FScCombo.SetBounds(466, 8, 170, 21);
  FScCombo.TabStop := False;
  FScCombo.DropDownCount := 20;
  FScCombo.Items.Add(Tr('Aus'));
  for Dev in ListInputDevices do
    FScCombo.Items.Add(Dev);
  FScCombo.ItemIndex := 0;
  FScCombo.OnChange := ScComboChange;
  FMeter := THostMeter.Create(Self);
  FMeter.Parent := FBottomBar;
  FMeter.SetBounds(642, 4, 150, 28);
  FKeysCheck := TCheckBox.Create(Self);
  FKeysCheck.Parent := FBottomBar;
  FKeysCheck.SetBounds(798, 7, 22, 22);
  FKeysCheck.Checked := False;
  FKeysCheck.TabStop := False;
  FKeysCheck.OnClick := KeysCheckClick;
  MakeLabel(FBottomBar, Tr('Klaviatur'), 823, 60);
  FAutoLabel := MakeLabel(FBottomBar, '', 884, 300);
  FAutoLabel.Font.Color := COL_VAL;

  // --- Plugin-Bereich ---
  FPluginArea := TPanel.Create(Self);
  FPluginArea.Parent := Self;
  FPluginArea.Align := alClient;
  FPluginArea.BevelOuter := bvNone;
  FPluginArea.ParentBackground := False;
  FPluginArea.Color := BG_MAIN;
  FPluginArea.OnResize := PluginAreaResize;
  FHintLabel := TLabel.Create(Self);
  FHintLabel.Parent := FPluginArea;
  FHintLabel.SetBounds(20, 20, 600, 60);
  FHintLabel.AutoSize := False;
  FHintLabel.WordWrap := True;
  FHintLabel.Font.Color := COL_TEXT;
  FHintLabel.Transparent := True;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 40;
  FTimer.OnTimer := TimerTick;
end;

procedure StartLog(const What: string); forward;

procedure TfrmMain.FormCreate(Sender: TObject);
var
  Ini: TMemIniFile;
  PluginPath, DefaultPath: string;
  I: Integer;
begin
  StartLog('FormCreate');
  if FindCmdLineSwitch('decodetest') then
  begin
    // GranularHost.exe -decodetest <Audiodatei>: dekodieren, Kennwerte nach decodetest.txt
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'decodetest.txt', DecodeTest(ParamStr(ParamCount)));
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;
  if FindCmdLineSwitch('makepresets') then
  begin
    // GranularHost.exe -makepresets <Projektordner>
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'presets.txt', MakePresets(ParamStr(ParamCount)));
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;
  if FindCmdLineSwitch('exportmidi') then
  begin
    // GranularHost.exe -exportmidi <Ordner>: alle Autoplay-Stuecke als MIDI
    with TAutoPlayer.Create(44100) do
    try
      ForceDirectories(ParamStr(ParamCount));
      for I := 0 to SongCount - 1 do
        ExportMidi(I, IncludeTrailingPathDelimiter(ParamStr(ParamCount)) + Format('%.2d.mid', [I + 1]));
    finally
      Free;
    end;
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;
  if FindCmdLineSwitch('abrender') then
  begin
    // GranularHost.exe -abrender <Projektordner>: Hoerprobe Oszillator-Modell klassisch / Wavetable
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'abrender.txt', RenderAB(ParamStr(ParamCount)));
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;
  if FindCmdLineSwitch('renderdemos') then
  begin
    // GranularHost.exe -renderdemos <Projektordner>: alle Presets mit passender Demo rendern + analysieren
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'renderdemos.txt', RenderDemos(ParamStr(ParamCount)));
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;
  if FindCmdLineSwitch('bench') then
  begin
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'bench.txt', RunBenchmark);
    Application.ShowMainForm := False;
    Application.Terminate;
    Exit;
  end;

  FNoSave := FindCmdLineSwitch('nosave');
  FOctave := 4;
  for I := 0 to High(FKeyNote) do
    FKeyNote[I] := -1;
  FTempo := 120;
  FLock := TCriticalSection.Create;
  FMidiLock := TCriticalSection.Create;
  FRing := TStereoRing.Create;
  FAuto := TAutoPlayer.Create(44100);
  FPlugin := TVstHostPlugin.Create;
  FPlugin.OnSizeRequest := PluginSizeRequest;

  // Audio-Einstellungen (Puffer gegen Knacksen bei Dateidialogen etc.)
  Ini := TMemIniFile.Create(TPath.Combine(StateDir, HOST_INI));
  try
    FSampleRate := Ini.ReadInteger('Audio', 'Abtastrate', 44100);
    FBlockFrames := EnsureRange(Ini.ReadInteger('Audio', 'Blockgröße', 512), 64, HOST_MAX_BLOCK);
    FBlockCount := EnsureRange(Ini.ReadInteger('Audio', 'Puffer', 6), 2, 16);
    PluginPath := Ini.ReadString('Plugin', PLUGIN_KEY, '');
  finally
    Ini.Free;
  end;
  SetLength(FInL, HOST_MAX_BLOCK);
  SetLength(FInR, HOST_MAX_BLOCK);

  LangInit(ExtractFilePath(ParamStr(0)));   // gleiche Sprache wie das Plugin (Sprache.txt im Programmordner)
  BuildUI;
  TranslateComponents(Self);
  LoadHostSettings;

  // Plugin: Kommandozeile > zuletzt benutzt > GranularSynth.dll neben der EXE
  if (ParamCount > 0) and FileExists(ParamStr(ParamCount)) and
     (SameText(ExtractFileExt(ParamStr(ParamCount)), '.dll') or IsVst3Path(ParamStr(ParamCount))) then
    PluginPath := ParamStr(ParamCount)
  else if (PluginPath <> '') and StartsText('GranularSynth', ExtractFileName(PluginPath)) and
          not SameText(ExtractFilePath(PluginPath), ExtractFilePath(ParamStr(0))) and
          FileExists(ExtractFilePath(ParamStr(0)) + ExtractFileName(PluginPath)) then
    // gemerktes GranularSynth aus anderem Ordner (z.B. Build-Ordner ohne Presets):
    // das mitgelieferte neben der EXE hat Vorrang
    PluginPath := ExtractFilePath(ParamStr(0)) + ExtractFileName(PluginPath);
  if (PluginPath = '') or not FileExists(PluginPath) then
    PluginPath := ExtractFilePath(ParamStr(0)) + 'GranularSynth.dll';
  if FileExists(PluginPath) then
    try
      LoadPlugin(PluginPath);
    except
      on E: Exception do
      begin
        // z.B. falsche Bitbreite: ohne Meldung auf das mitgelieferte Plugin ausweichen
        DefaultPath := ExtractFilePath(ParamStr(0)) + 'GranularSynth.dll';
        if not SameText(PluginPath, DefaultPath) and FileExists(DefaultPath) then
          try
            LoadPlugin(DefaultPath);
          except
            on E2: Exception do
              FHintLabel.Caption := Tr('Plugin konnte nicht geladen werden: ') + E2.Message;
          end
        else
          FHintLabel.Caption := Tr('Plugin konnte nicht geladen werden: ') + E.Message;
      end;
    end
  else
    FHintLabel.Caption := Tr('Kein Plugin geladen. "VST laden..." wählen (z.B. GranularSynth.dll).');

  try
    FPlayer := TWaveOutPlayer.Create(FSampleRate, FBlockFrames, FBlockCount, Render);
  except
    on E: Exception do
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
  end;

  if FindCmdLineSwitch('autoplay') then
    AutoButtonClick(nil);
  StartLog('FormCreate fertig');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  if FPlugin = nil then
    Exit;   // Benchmark-Modus
  FreeAndNil(FPlayer);      // Audio zuerst stoppen
  FreeAndNil(FRecorder);
  if not FNoSave then
  try
    SaveHostSettings;
  except
  end;
  UnloadPlugin(not FNoSave);
  FreeAndNil(FPlugin);
  FreeAndNil(FRing);
  FreeAndNil(FAuto);
  FreeAndNil(FMidiLock);
  FreeAndNil(FLock);
end;

{ --- Plugin --- }

{ Startzeit-Protokoll (nur mit Umgebungsvariable GRANULAR_STARTLOG=1): %TEMP%\granular_start.txt }
procedure StartLog(const What: string);
begin
  if GetEnvironmentVariable('GRANULAR_STARTLOG') = '1' then
    TFile.AppendAllText(TPath.Combine(TPath.GetTempPath, 'granular_start.txt'),
      FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + What + sLineBreak);
end;

procedure TfrmMain.LoadPlugin(const Path: string; RestoreState: Boolean);
var
  F: string;
begin
  StartLog('LoadPlugin ' + Path);
  UnloadPlugin(not FNoSave);
  FLock.Enter;
  try
    FPlugin.Load(Path, FSampleRate, FBlockFrames);
    StartLog('Plugin geladen');
    FPlugin.Tempo := FTempo;
  finally
    FLock.Leave;
  end;
  if RestoreState then
  begin
    F := FPlugin.StateFileName(PluginStateDir);
    if FileExists(F) then
      try
        FPlugin.LoadState(TFile.ReadAllBytes(F));
        StartLog('Zustand geladen');
      except
        // defekter Zustand -> Plugin-Standardwerte
      end;
  end;
  FPluginLabel.Caption := FPlugin.Name;
  // eigenes Protokoll: GranularSynth meldet, dass sein Editor mitwachsen kann
  FResizable := FPlugin.Dispatch(effCanDo, 0, 0, PAnsiChar('granularResizable'), 0) = 1;
  if not FPlugin.IsSynth then
    FPluginLabel.Caption := FPlugin.Name + Tr('  (Effekt)');
  ShowPluginEditor;
  StartLog('Editor offen');
end;

procedure TfrmMain.SavePluginState;
var
  Data: TBytes;
begin
  if not FPlugin.Loaded then
    Exit;
  Data := FPlugin.SaveState;
  if Length(Data) > 0 then
  begin
    ForceDirectories(PluginStateDir);
    TFile.WriteAllBytes(FPlugin.StateFileName(PluginStateDir), Data);
  end;
end;

procedure TfrmMain.UnloadPlugin(SaveState: Boolean);
begin
  if not FPlugin.Loaded then
    Exit;
  ReleasePcKeys;
  if SaveState then
    try
      SavePluginState;
    except
    end;
  FLock.Enter;
  try
    FPlugin.Unload;
  finally
    FLock.Leave;
  end;
  FPluginLabel.Caption := Tr('(kein Plugin)');
  FEditorW := 0;
  FEditorH := 0;
end;

procedure TfrmMain.ShowPluginEditor;
var
  W, H: Integer;
begin
  FHintLabel.Visible := False;
  if FPlugin.OpenEditor(FPluginArea.Handle, W, H) then
  begin
    FEditorW := W;
    FEditorH := H;
  end
  else
  begin
    FEditorW := 0;
    FEditorH := 0;
    FHintLabel.Caption := FPlugin.Name + Tr(' hat kein eigenes Fenster. Spielbar über Klaviatur/Autoplay.');
    FHintLabel.Visible := True;
  end;
  AdjustWindowSize;
end;

procedure TfrmMain.AdjustWindowSize;
var
  W, H: Integer;
begin
  if WindowState <> wsNormal then
    Exit;
  W := Max(FEditorW, 920);
  if FEditorH > 0 then H := FEditorH else H := 120;
  H := H + 2 * BAR_H;
  if FKeys.Visible then
    Inc(H, KEYS_H);
  Constraints.MinWidth := 0;
  ClientWidth := W;
  ClientHeight := H;
  // nie schmaler als das Plugin-Fenster: sonst werden die Schieberegler zu kurz
  if FEditorW > 0 then
    Constraints.MinWidth := Width;
  PluginAreaResize(nil);
end;

procedure TfrmMain.PluginAreaResize(Sender: TObject);
var
  Child: HWND;
begin
  if not FResizable or (FEditorW <= 0) then
    Exit;
  // Plugin-Fenster (erstes Kindfenster) auf die Bereichsgroesse bringen, nie kleiner als sein Wunschmass
  Child := GetWindow(FPluginArea.Handle, GW_CHILD);
  while Child <> 0 do
  begin
    if IsWindowVisible(Child) then
      SetWindowPos(Child, 0, 0, 0, Max(FPluginArea.ClientWidth, FEditorW),
        Max(FPluginArea.ClientHeight, FEditorH), SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOMOVE);
    Child := GetWindow(Child, GW_HWNDNEXT);
  end;
end;

procedure TfrmMain.PluginSizeRequest(Sender: TObject; Width, Height: Integer);
begin
  // kann aus beliebigem Thread kommen -> in den GUI-Thread verlagern
  PostMessage(Handle, WM_PLUGIN_SIZE, Width, Height);
end;

procedure TfrmMain.WMPluginSize(var Msg: TMessage);
begin
  FEditorW := Msg.WParam;
  FEditorH := Msg.LParam;
  AdjustWindowSize;
end;

{ --- Audio-Thread --- }

procedure TfrmMain.EmitNote(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer);
begin
  if IsOn then
    FPlugin.AddMidi($90, Note, EnsureRange(Round(Velocity * 127), 1, 127), Delta)
  else
    FPlugin.AddMidi($80, Note, 0, Delta);
end;

procedure TfrmMain.QueueMidi(Status, Data1, Data2: Byte);
begin
  FMidiLock.Enter;
  try
    if FMidiCount <= High(FMidiQueue) then
    begin
      FMidiQueue[FMidiCount].Status := Status;
      FMidiQueue[FMidiCount].Data1 := Data1;
      FMidiQueue[FMidiCount].Data2 := Data2;
      Inc(FMidiCount);
    end;
  finally
    FMidiLock.Leave;
  end;
end;

procedure TfrmMain.Render(OutL, OutR: System.PSingle; Frames: Integer);
var
  I: Integer;
  InL, InR: System.PSingle;
  P: Single;
begin
  FLock.Enter;
  try
    if not FPlugin.Loaded then
    begin
      FillChar(OutL^, Frames * SizeOf(Single), 0);
      FillChar(OutR^, Frames * SizeOf(Single), 0);
      Exit;
    end;
    // Noten aus der Oberflaeche (Klaviatur, PC-Tasten)
    FMidiLock.Enter;
    try
      for I := 0 to FMidiCount - 1 do
        FPlugin.AddMidi(FMidiQueue[I].Status, FMidiQueue[I].Data1, FMidiQueue[I].Data2, 0);
      FMidiCount := 0;
    finally
      FMidiLock.Leave;
    end;
    // Autoplay (samplegenau) - kann das Tempo setzen
    FAuto.Process(Frames, FTempo, EmitNote);
    FPlugin.Tempo := FTempo;

    // Sidechain
    InL := nil;
    InR := nil;
    if FRecorder <> nil then
    begin
      FRing.Read(@FInL[0], @FInR[0], Frames);
      InL := @FInL[0];
      InR := @FInR[0];
      P := FPeakIn;
      for I := 0 to Frames - 1 do
        P := Max(P, Max(Abs(FInL[I]), Abs(FInR[I])));
      FPeakIn := P;
    end;
    FPlugin.Process(InL, InR, OutL, OutR, Frames);
    P := FPeakOut;
    for I := 0 to Frames - 1 do
      P := Max(P, Max(Abs(OutL[I]), Abs(OutR[I])));
    FPeakOut := P;
  finally
    FLock.Leave;
  end;
end;

{ --- Ereignisse --- }

procedure TfrmMain.LoadClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    {$IFDEF WIN64}
    Dlg.Title := Tr('VST2/VST3-Plugin laden (64 Bit)');
    {$ELSE}
    Dlg.Title := Tr('VST2/VST3-Plugin laden (32 Bit)');
    {$ENDIF}
    Dlg.Filter := 'VST-Plugins (*.dll, *.vst3)|*.dll;*.vst3|VST2-Plugins (*.dll)|*.dll|VST3-Plugins (*.vst3)|*.vst3';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if FPlugin.Loaded then
      Dlg.InitialDir := ExtractFilePath(FPlugin.Path);
    if Dlg.Execute then
    try
      LoadPlugin(Dlg.FileName);
    except
      on E: Exception do
      begin
        FHintLabel.Caption := Tr('Plugin konnte nicht geladen werden: ') + E.Message;
        FHintLabel.Visible := True;
        MessageDlg(E.Message, mtError, [mbOK], 0);
      end;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TfrmMain.ResetClick(Sender: TObject);
var
  Path, F: string;
begin
  if not FPlugin.Loaded then
    Exit;
  if MessageDlg(Tr('Gespeicherte Einstellungen von "') + FPlugin.Name + Tr('" löschen und das Plugin ' +
    'mit Standardwerten neu laden?'), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  Path := FPlugin.Path;
  F := FPlugin.StateFileName(PluginStateDir);
  UnloadPlugin(False);          // NICHT speichern
  if FileExists(F) then
    DeleteFile(F);
  LoadPlugin(Path, False);
end;

procedure TfrmMain.PanicClick(Sender: TObject);
var
  N: Integer;
begin
  ReleasePcKeys;
  QueueMidi($B0, 123, 0);       // All Notes Off
  for N := 0 to 127 do
    FKeys.SetPressed(N, False);
end;

procedure TfrmMain.OctaveClick(Sender: TObject);
begin
  if Sender = FOctUp then
    FOctave := Min(FOctave + 1, 8)
  else
    FOctave := Max(FOctave - 1, 0);
  FKeys.SetPcRange((FOctave + 1) * 12, 17);
end;

procedure TfrmMain.UpdateTempoLabel;
begin
  FTempoLabel.Caption := Format(Tr('%.0f BPM'), [FTempo]);
end;

procedure TfrmMain.TempoChange(Sender: TObject);
begin
  if FUpdatingTempo then
    Exit;
  FTempo := FTempoTrack.Position;
  UpdateTempoLabel;
end;

procedure TfrmMain.AutoComboChange(Sender: TObject);
begin
  // gewaehltes Stueck gleich spielen (laeuft schon eins, wird gewechselt - Start loest alte Noten)
  if (FAutoCombo.ItemIndex >= 1) and (FAutoCombo.ItemIndex <= Length(FComboSongs)) then
    FAuto.Start(FComboSongs[FAutoCombo.ItemIndex - 1])
  else
    FAuto.Start(-1);
  FAutoButton.Caption := Tr('Autoplay Stop');
end;

{ Liste/Zufall: zum Preset passend oder (Haken 'alle') saemtliche Stuecke }
procedure TfrmMain.ApplyAutoMask;
var
  Mask: Integer;
begin
  Mask := FPresetMask;
  if (Mask = 0) or FAutoAllCheck.Checked then
    Mask := SONG_ALL;
  if Mask <> FAuto.KindMask then
  begin
    FAuto.KindMask := Mask;
    FillAutoCombo(Mask);
  end;
end;

procedure TfrmMain.AutoAllClick(Sender: TObject);
begin
  ApplyAutoMask;
  ActiveControl := nil;      // PC-Tasten wieder fuer die Klaviatur
end;

procedure TfrmMain.AutoComboCloseUp(Sender: TObject);
begin
  // Fokus aus der Liste nehmen: sonst blaettern die PC-Tasten (Klaviatur) darin weiter
  TThread.ForceQueue(nil, procedure
    begin
      if not (csDestroying in ComponentState) then
        ActiveControl := nil;
    end);
end;

procedure TfrmMain.AutoButtonClick(Sender: TObject);
begin
  if FAuto.Playing then
  begin
    FAuto.Stop;
    FAutoButton.Caption := Tr('Autoplay Start');
  end
  else
  begin
    if (FAutoCombo.ItemIndex >= 1) and (FAutoCombo.ItemIndex <= Length(FComboSongs)) then
      FAuto.Start(FComboSongs[FAutoCombo.ItemIndex - 1])
    else
      FAuto.Start(-1);   // Zufall aus den passenden Stuecken
    FAutoButton.Caption := Tr('Autoplay Stop');
  end;
end;

procedure TfrmMain.ScComboChange(Sender: TObject);
begin
  FreeAndNil(FRecorder);
  FPeakIn := 0;
  if FScCombo.ItemIndex > 0 then
  try
    FRecorder := TWaveInRecorder.Create(Cardinal(FScCombo.ItemIndex - 1), FSampleRate, FBlockFrames, FRing);
  except
    on E: Exception do
    begin
      FScCombo.ItemIndex := 0;
      MessageDlg(E.Message, mtWarning, [mbOK], 0);
    end;
  end;
end;

procedure TfrmMain.KeysCheckClick(Sender: TObject);
begin
  FKeys.Visible := FKeysCheck.Checked;
  FWheelArea.Visible := FKeys.Visible;
  if FKeys.Visible then
    FBottomArea.Height := KEYS_H + BAR_H
  else
    FBottomArea.Height := BAR_H;
  AdjustWindowSize;
end;

procedure TfrmMain.WheelChange(Sender: TObject);
var
  V: Integer;
begin
  if Sender = FBendWheel then
  begin
    V := EnsureRange(Round(8192 + FBendWheel.Value * 8192), 0, 16383);
    QueueMidi($E0, V and $7F, V shr 7);
  end
  else
    QueueMidi($B0, 1, EnsureRange(Round(FModWheel.Value * 127), 0, 127));
end;

procedure TfrmMain.KeyboardNote(Sender: TObject; Note: Integer; IsOn: Boolean);
begin
  if IsOn then
    QueueMidi($90, Note, 100)
  else
    QueueMidi($80, Note, 0);
  FKeys.SetPressed(Note, IsOn);
end;

procedure TfrmMain.TimerTick(Sender: TObject);
var
  N: Integer;
  On: Boolean;
begin
  // Host im Hintergrund: Anzeigen nur etwa 2x je Sekunde (Plugin-Idle laeuft trotzdem)
  // Host im Hintergrund: Timer auf 500 ms (Anzeigen 2x je Sekunde), im Vordergrund 40 ms
  if Application.Active then
    FTimer.Interval := 40
  else
    FTimer.Interval := 500;
  FPlugin.Idle;
  // etwa jede Sekunde: welches Preset ist im Plugin geladen? -> passende Autoplay-Stuecke
  Inc(FProgTick);
  if (FProgTick mod 3 = 0) or not Application.Active then
    CheckPresetKind;
  // Autoplay-Noten anzeigen
  for N := 0 to 127 do
  begin
    On := FAuto.NoteActive[N];
    if On <> FShownAuto[N] then
    begin
      FShownAuto[N] := On;
      FKeys.SetPressed(N, On);
    end;
  end;
  // Tempo vom Autoplay in den Regler uebernehmen
  if Round(FTempo) <> FTempoTrack.Position then
  begin
    FUpdatingTempo := True;
    try
      FTempoTrack.Position := Round(FTempo);
    finally
      FUpdatingTempo := False;
    end;
    UpdateTempoLabel;
  end;
  if FAuto.Playing then
  begin
    // Titel ohne Klammerzusatz, damit er in die Leiste passt; voller Titel im Tooltip
    FAutoLabel.Caption := Tr('spielt: ') + Trim(Copy(FAuto.CurrentTitle, 1,
      IfThen(Pos(' (', FAuto.CurrentTitle) > 0, Pos(' (', FAuto.CurrentTitle) - 1, MaxInt)));
    FAutoLabel.Hint := FAuto.CurrentTitle;
    FAutoLabel.ShowHint := True;
  end
  else
    FAutoLabel.Caption := '';
  // Pegel mit Abfall
  FMeter.PeakIn := FPeakIn;
  FMeter.PeakOut := FPeakOut;
  FPeakIn := FPeakIn * 0.7;
  FPeakOut := FPeakOut * 0.7;
  FMeter.ForceFullInvalidate;
end;

procedure TfrmMain.MidiExportClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Fd: TFileOpenDialog;
  I, Idx: Integer;
  Dir, Fn: string;

  function SafeName(const S: string): string;
  var
    C: Char;
  begin
    Result := '';
    for C in S do
      if CharInSet(C, ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then Result := Result + '_'
      else Result := Result + C;
  end;

begin
  if (FAutoCombo.ItemIndex >= 1) and (FAutoCombo.ItemIndex <= Length(FComboSongs)) then
  begin
    Idx := FComboSongs[FAutoCombo.ItemIndex - 1];
    Dlg := TSaveDialog.Create(Self);
    try
      Dlg.Filter := 'MIDI-Datei (*.mid)|*.mid';
      Dlg.DefaultExt := 'mid';
      Dlg.FileName := SafeName(FAuto.Titles[Idx]) + '.mid';
      Dlg.Options := Dlg.Options + [ofOverwritePrompt];
      if Dlg.Execute then
        FAuto.ExportMidi(Idx, Dlg.FileName);
    finally
      Dlg.Free;
    end;
  end
  else
  begin
    // "Zufall" gewaehlt: alle gerade angezeigten (passenden) Stuecke in einen Ordner
    Fd := TFileOpenDialog.Create(Self);
    try
      Fd.Options := [fdoPickFolders];
      Fd.Title := Tr('Ordner für die MIDI-Dateien wählen');
      if not Fd.Execute then
        Exit;
      Dir := IncludeTrailingPathDelimiter(Fd.FileName);
    finally
      Fd.Free;
    end;
    for I := 0 to High(FComboSongs) do
    begin
      Fn := Dir + SafeName(FAuto.Titles[FComboSongs[I]]) + '.mid';
      FAuto.ExportMidi(FComboSongs[I], Fn);
    end;
    ShowMessage(Format(Tr('%d MIDI-Dateien gespeichert in %s'), [Length(FComboSongs), Dir]));
  end;
end;

procedure TfrmMain.FillAutoCombo(Mask: Integer);
var
  I, Sel: Integer;
begin
  Sel := FAutoCombo.ItemIndex;
  FAutoCombo.Items.BeginUpdate;
  try
    FAutoCombo.Items.Clear;
    FComboSongs := nil;
    if Mask = SONG_ALL then
      FAutoCombo.Items.Add(Tr('Zufall: alle Stücke, mit Variation'))
    else
      FAutoCombo.Items.Add(Tr('Zufall: zum Preset passende Stücke'));
    for I := 0 to FAuto.SongCount - 1 do
      if FAuto.Kinds[I] and Mask <> 0 then
      begin
        FAutoCombo.Items.Add(FAuto.Titles[I]);
        FComboSongs := FComboSongs + [I];
      end;
  finally
    FAutoCombo.Items.EndUpdate;
  end;
  if (Sel >= 0) and (Sel < FAutoCombo.Items.Count) and (Mask = SONG_ALL) then
    FAutoCombo.ItemIndex := Sel
  else
    FAutoCombo.ItemIndex := 0;
end;

{ Presetname des Plugins abfragen (VST effGetProgramName) und die Autoplay-Liste filtern:
  Flaechen/Stimmen/Oper -> Liegetoene, Arp -> Akkorde, sonst alles }
procedure TfrmMain.CheckPresetKind;
const
  DRONE_WORDS: array[0..12] of string = ('fläche', 'freeze', 'oper', 'stimme', 'kathedrale', 'nebel',
    'ozean', 'dämmerung', 'morph', 'regen', 'weltraum', 'eingefroren', 'pad im');
var
  Buf: array[0..255] of AnsiChar;
  Name, Low: string;
  Mask, I: Integer;
begin
  if (FPlugin = nil) or not FPlugin.Loaded then
    Exit;
  FillChar(Buf, SizeOf(Buf), 0);
  FPlugin.Dispatch(effGetProgramName, 0, 0, @Buf[0], 0);
  Name := string(AnsiString(PAnsiChar(@Buf[0])));
  if Name = FProgName then
    Exit;
  FProgName := Name;
  Low := LowerCase(Name);
  Mask := SONG_ALL;
  if Pos('arp', Low) > 0 then
    Mask := SONG_ARP
  else
    for I := 0 to High(DRONE_WORDS) do
      if Pos(DRONE_WORDS[I], Low) > 0 then
      begin
        Mask := SONG_DRONE;
        Break;
      end;
  FPresetMask := Mask;
  ApplyAutoMask;
  // neues Preset bei laufendem Autoplay: sofort neu starten (passendes Stueck, gleich eine Note)
  if FAuto.Playing then
  begin
    if (FAutoCombo.ItemIndex >= 1) and (FAutoCombo.ItemIndex <= Length(FComboSongs)) then
      FAuto.Start(FComboSongs[FAutoCombo.ItemIndex - 1])
    else
      FAuto.Start(-1);
  end;
end;

function TfrmMain.PcKeyToSemitone(Key: Word): Integer;
begin
  case Key of
    Ord('A'): Result := 0;   Ord('W'): Result := 1;   Ord('S'): Result := 2;
    Ord('E'): Result := 3;   Ord('D'): Result := 4;   Ord('F'): Result := 5;
    Ord('T'): Result := 6;   Ord('G'): Result := 7;
    Ord('Z'), Ord('Y'): Result := 8;
    Ord('H'): Result := 9;   Ord('U'): Result := 10;  Ord('J'): Result := 11;
    Ord('K'): Result := 12;  Ord('O'): Result := 13;  Ord('L'): Result := 14;
    Ord('P'): Result := 15;  VK_OEM_3: Result := 16;
  else
    Result := -1;
  end;
end;

{ Hat ein Eingabefeld die Tastatur? Per Windows-Klassenname geprueft: Felder im Plugin-Fenster gehoeren
  zur VCL der Plugin-DLL, 'is TCustomEdit' erkennt sie im Host nicht (Suchfeld der Presetliste). }
function FocusIsEdit: Boolean;
var
  C: array[0..63] of Char;
begin
  Result := False;
  if GetClassName(GetFocus, C, Length(C)) > 0 then
    Result := (Pos('Edit', string(C)) > 0) or (Pos('Memo', string(C)) > 0);
end;

procedure TfrmMain.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Semi: Integer;
begin
  if (ssCtrl in Shift) or (ssAlt in Shift) then
    Exit;
  if (Screen.ActiveControl is TComboBox) and TComboBox(Screen.ActiveControl).DroppedDown then
    Exit;
  if (Screen.ActiveControl is TCustomEdit) or FocusIsEdit then
    Exit;
  case Key of
    VK_ADD, VK_OEM_PLUS:   begin OctaveClick(FOctUp); Key := 0; Exit; end;
    VK_SUBTRACT, VK_OEM_MINUS: begin OctaveClick(FOctDown); Key := 0; Exit; end;
  end;
  Semi := PcKeyToSemitone(Key);
  if Semi < 0 then
    Exit;
  if FKeyNote[Key] < 0 then
  begin
    FKeyNote[Key] := (FOctave + 1) * 12 + Semi;
    KeyboardNote(nil, FKeyNote[Key], True);
  end;
  Key := 0;
end;

procedure TfrmMain.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if FKeyNote[Key] >= 0 then
  begin
    KeyboardNote(nil, FKeyNote[Key], False);
    FKeyNote[Key] := -1;
    Key := 0;
  end;
end;

procedure TfrmMain.ReleasePcKeys;
var
  I: Integer;
begin
  for I := 0 to High(FKeyNote) do
    if FKeyNote[I] >= 0 then
    begin
      KeyboardNote(nil, FKeyNote[I], False);
      FKeyNote[I] := -1;
    end;
end;

procedure TfrmMain.FormDeactivate(Sender: TObject);
begin
  ReleasePcKeys;
end;

{ --- Einstellungen --- }

procedure TfrmMain.LoadHostSettings;
var
  Ini: TMemIniFile;
  Dev: string;
  Idx: Integer;
begin
  Ini := TMemIniFile.Create(TPath.Combine(StateDir, HOST_INI));
  try
    if Ini.ValueExists('Fenster', 'Left') then
    begin
      Position := poDesigned;
      Left := Ini.ReadInteger('Fenster', 'Left', Left);
      Top := Ini.ReadInteger('Fenster', 'Top', Top);
      MakeFullyVisible;
    end;
    FTempo := EnsureRange(Ini.ReadInteger('Host', 'Tempo', 120), 40, 240);
    FTempoTrack.Position := Round(FTempo);
    UpdateTempoLabel;
    FKeysCheck.Checked := False;   // beim Start immer ohne Klaviatur (Wunsch); waehrend der Sitzung frei umschaltbar
    KeysCheckClick(nil);
    FOctave := EnsureRange(Ini.ReadInteger('Host', 'Oktave', 4), 0, 8);
    FKeys.SetPcRange((FOctave + 1) * 12, 17);
    Idx := Ini.ReadInteger('Autoplay', 'Auswahl', 0);
    if (Idx >= 0) and (Idx < FAutoCombo.Items.Count) then
      FAutoCombo.ItemIndex := Idx;
    // Geraet ueber den Namen suchen - Indizes aendern sich beim Ein-/Ausstecken
    Dev := Ini.ReadString('Sidechain', 'Gerät', '');
    Idx := FScCombo.Items.IndexOf(Dev);
    if (Dev <> '') and (Idx > 0) then
    begin
      FScCombo.ItemIndex := Idx;
      ScComboChange(nil);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TfrmMain.SaveHostSettings;
var
  Ini: TMemIniFile;
begin
  ForceDirectories(StateDir);
  Ini := TMemIniFile.Create(TPath.Combine(StateDir, HOST_INI));
  try
    if WindowState = wsNormal then
    begin
      Ini.WriteInteger('Fenster', 'Left', Left);
      Ini.WriteInteger('Fenster', 'Top', Top);
    end;
    Ini.WriteInteger('Host', 'Tempo', Round(FTempo));
    Ini.WriteBool('Host', 'Klaviatur', FKeysCheck.Checked);
    Ini.WriteInteger('Host', 'Oktave', FOctave);
    Ini.WriteInteger('Autoplay', 'Auswahl', FAutoCombo.ItemIndex);
    if FScCombo.ItemIndex > 0 then
      Ini.WriteString('Sidechain', 'Gerät', FScCombo.Text)
    else
      Ini.WriteString('Sidechain', 'Gerät', '');
    Ini.WriteString('Plugin', PLUGIN_KEY, FPlugin.Path);
    Ini.DeleteKey('Plugin', 'Pfad');   // alter, gemeinsamer Schluessel
    // Audio-Werte nur anlegen, damit man sie von Hand anpassen kann
    Ini.WriteInteger('Audio', 'Abtastrate', FSampleRate);
    Ini.WriteInteger('Audio', 'Blockgröße', FBlockFrames);
    Ini.WriteInteger('Audio', 'Puffer', FBlockCount);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

end.
