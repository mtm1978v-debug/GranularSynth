{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.VstPlugin;

{ VST2-Plugin-Huelle um TGranularEngine + TGranularEditor.
    - Synth mit 2 Ausgaengen (Stereo) und 2 Eingaengen (= Sidechain)
    - MIDI ueber effProcessEvents (samplegenau per DeltaFrames)
    - Zustand als Chunk (Granular.State) -> Host speichert alles inkl. Matrix und Samplepfad
    - Host-Tempo (audioMasterGetTime) treibt LFO-/Echo-Sync
    - Editor: VCL-Formular ohne Rahmen im vom Host gelieferten Fenster
  Robustheit: keine Exception verlaesst die DLL; FPU/SSE-Ausnahmen werden waehrend
  der Verarbeitung maskiert und danach wiederhergestellt (Host-Zustand bleibt unberuehrt). }

interface

uses
  Granular.Lang,
  Granular.Vst2;

function CreatePlugin(AudioMaster: TAudioMasterCallback): PAEffect;

implementation

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math,
  Vcl.Controls, Vcl.Forms,
  Granular.Params, Granular.Sample, Granular.Engine, Granular.State, Granular.Editor, Granular.AudioDecode;

const
  WM_GRANULAR_RELANG = WM_USER + 711;   // Editor nach Sprachwechsel neu aufbauen


const
  PLUGIN_NAME = 'GranularSynth';
  VENDOR_NAME = 'privat';
  PLUGIN_VERSION = APP_VERSION_MAJOR * 1000 + APP_VERSION_MINOR;   // 1.0 -> 1000, 1.12 -> 1012
  EDITOR_W = 1260;  // breit genug fuer drei Spalten im Oszillator-Reiter
  EDITOR_H = 712;   // inkl. Titelbanner
  MAX_BLOCK = 8192;

type
  TGranularPlugin = class
  private
    FEffect: TAEffect;
    FAudioMaster: TAudioMasterCallback;
    FEngine: TGranularEngine;
    FForm: TForm;
    FEditor: TGranularEditor;
    FOldFormProc: TWndMethod;         // Fensterprozedur des Editor-Formulars (Sprachwechsel)
    FRect: TERect;
    FChunk: TBytes;          // muss bis zum naechsten getChunk gueltig bleiben
    FTempoWait: Integer;
    FIsFx: Boolean;          // als Effekt geladen (Dateiname mit "FX")
    FHostTicks: Int64;       // Zeit in Rueckfragen an den Host (audioMasterGetTime) im laufenden Aufruf     // Samples bis zur naechsten Tempo-Abfrage beim Host
    FTmpL, FTmpR: TArray<Single>;
    FInBuf: array[0..3] of TArray<Single>;   // Kopie der vier Eingaenge (Host kann Ein-/Ausgang teilen)
    FDryBuf: array[0..LIM_LOOK * 2 - 1] of Single;   // FX: Eingangston um die Latenz verzoegert
    FDryPos: Integer;
    FBaseDir: string;       // Ordner der DLL (Presets\, Beispieltoene\)
    procedure OpenEditor(ParentWnd: HWND);
    procedure CloseEditor;
    procedure CreateEditorPanel;
    procedure EditorLanguageChange(Sender: TObject);
    procedure FormWndProc(var Msg: TMessage);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ProcessEvents(Events: PVstEvents);
    procedure UpdateHostTempo(Frames: Integer);
    procedure EditorParamEdit(Index: Integer; Kind: TParamEditKind; Value: Single);
    function SetChunk(Data: Pointer; Size: Integer): Boolean;
  public
    constructor Create(AudioMaster: TAudioMasterCallback);
    destructor Destroy; override;
    function DoDispatch(Opcode, Index: Int32; Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt;
    procedure ProcessReplacing(Inputs, Outputs: PPSingle; Frames: Int32);
    procedure ProcessAccumulating(Inputs, Outputs: PPSingle; Frames: Int32);
  end;

{$POINTERMATH ON}
{$WARN SYMBOL_PLATFORM OFF}   // Get/SetMXCSR: bewusst, Windows-Plugin

{ --- FPU-Schutz --- }

type
  TFpuState = record
    CW: Word;
    MX: UInt32;
  end;

function EnterFpu: TFpuState;
begin
  Result.CW := Get8087CW;
  Result.MX := GetMXCSR;
  Set8087CW($133F);      // alle x87-Ausnahmen maskiert, doppelte Genauigkeit
  SetMXCSR($9F80);       // alle SSE-Ausnahmen maskiert + Flush-to-Zero (keine langsamen Denormalen im Ausklang)
end;

procedure LeaveFpu(const S: TFpuState);
begin
  Set8087CW(S.CW);
  SetMXCSR(S.MX);
end;

{ --- cdecl-Einsprungpunkte --- }

function PluginOf(Effect: PAEffect): TGranularPlugin; inline;
begin
  Result := TGranularPlugin(Effect.Obj);
end;

function DispatcherCB(Effect: PAEffect; Opcode, Index: Int32; Value: NativeInt;
  Ptr: Pointer; Opt: Single): NativeInt; cdecl;
var
  P: TGranularPlugin;
  F: TFpuState;
begin
  Result := 0;
  P := PluginOf(Effect);
  if P = nil then
    Exit;
  F := EnterFpu;
  try
    try
      if Opcode = effClose then
      begin
        Effect.Obj := nil;
        P.Free;
        Result := 1;
      end
      else
        Result := P.DoDispatch(Opcode, Index, Value, Ptr, Opt);
    except
      Result := 0;
    end;
  finally
    LeaveFpu(F);
  end;
end;

procedure ProcessReplacingCB(Effect: PAEffect; Inputs, Outputs: PPSingle; Frames: Int32); cdecl;
var
  F: TFpuState;
  T0, T1: Int64;
  P: TGranularPlugin;
begin
  QueryPerformanceCounter(T0);
  F := EnterFpu;
  P := PluginOf(Effect);
  try
    try
      P.FHostTicks := 0;
      P.ProcessReplacing(Inputs, Outputs, Frames);
    except
      // im Audio-Thread niemals eine Exception an den Host weitergeben
    end;
  finally
    LeaveFpu(F);
  end;
  // Laufzeitmessung (Anzeige im Mischpult): wie lange rechnet das Plugin je Aufruf, in welchem Thread
  QueryPerformanceCounter(T1);
  if P <> nil then
    P.FEngine.AddProcStat(Frames, T1 - T0, P.FHostTicks, GetCurrentThreadId);
end;

procedure ProcessCB(Effect: PAEffect; Inputs, Outputs: PPSingle; Frames: Int32); cdecl;
var
  F: TFpuState;
begin
  F := EnterFpu;
  try
    try
      PluginOf(Effect).ProcessAccumulating(Inputs, Outputs, Frames);
    except
    end;
  finally
    LeaveFpu(F);
  end;
end;

procedure SetParameterCB(Effect: PAEffect; Index: Int32; Parameter: Single); cdecl;
begin
  // VST-Nummern sind fest (VST_ORDER), intern kann die Reihenfolge wechseln
  PluginOf(Effect).FEngine.SetParam(VstToParam(Index), Parameter);
end;

function GetParameterCB(Effect: PAEffect; Index: Int32): Single; cdecl;
begin
  Result := PluginOf(Effect).FEngine.GetParam(VstToParam(Index));
end;

{ TGranularPlugin }

constructor TGranularPlugin.Create(AudioMaster: TAudioMasterCallback);
var
  Sr: NativeInt;
begin
  inherited Create;
  FAudioMaster := AudioMaster;
  FEngine := TGranularEngine.Create;
  FBaseDir := ExtractFilePath(GetModuleName(HInstance));
  // FX-Variante: dieselbe DLL unter einem Namen mit "FX" (z. B. "GranularSynth FX.dll") meldet sich als
  // Effekt. FL Studio gibt Instrumenten kein Audio - nur Effekte im Mixer-Slot bekommen Sidechain-Eingaenge.
  // Gespielt wird die FX-Variante ueber MIDI (z. B. MIDI-Out-Kanal in FL Studio).
  FIsFx := Pos('FX', UpperCase(ChangeFileExt(ExtractFileName(GetModuleName(HInstance)), ''))) > 0;
  Sr := 0;
  if Assigned(FAudioMaster) then
    Sr := FAudioMaster(nil, audioMasterGetSampleRate, 0, 0, nil, 0);
  if Sr > 0 then
    FEngine.SetSampleRate(Sr)
  else
    FEngine.SetSampleRate(44100);
  // Startklang: mitgelieferte Demo-Datei, sonst synthetisch erzeugt
  if FileExists(FBaseDir + 'Beispieltoene' + PathDelim + 'Demo_Klang.wav') then
    try
      FEngine.LoadSample(LoadWaveFile(FBaseDir + 'Beispieltoene' + PathDelim + 'Demo_Klang.wav'));
    except
      FEngine.LoadSample(CreateDemoSample(Round(FEngine.SampleRate)));
    end
  else
    FEngine.LoadSample(CreateDemoSample(Round(FEngine.SampleRate)));
  LoadMidiMap(FEngine, FBaseDir + MIDI_MAP_FILE);   // MIDI-Learn-Zuordnungen des Controllers
  SetLength(FTmpL, MAX_BLOCK);
  SetLength(FTmpR, MAX_BLOCK);
  for Sr := 0 to 3 do
    SetLength(FInBuf[Sr], MAX_BLOCK);

  FillChar(FEffect, SizeOf(FEffect), 0);
  FEffect.Magic := kEffectMagic;
  FEffect.Dispatcher := DispatcherCB;
  FEffect.Process := ProcessCB;
  FEffect.SetParameter := SetParameterCB;
  FEffect.GetParameter := GetParameterCB;
  FEffect.ProcessReplacing := ProcessReplacingCB;
  FEffect.NumPrograms := 1;
  FEffect.NumParams := PARAM_COUNT;
  FEffect.NumInputs := 4;      // Sidechain 1 (Eingang 1/2) und Sidechain 2 (Eingang 3/4)
  FEffect.NumOutputs := 2;
  FEffect.InitialDelay := LIM_LOOK;   // Limiter-Vorausschau -> Host gleicht die Latenz aus
  FEffect.Flags := effFlagsHasEditor or effFlagsCanReplacing or effFlagsProgramChunks;
  if not FIsFx then
    FEffect.Flags := FEffect.Flags or effFlagsIsSynth;
  FEffect.IoRatio := 1;
  FEffect.Obj := Self;
  if FIsFx then
    FEffect.UniqueID := VstFourCC('GrnF')        // eigene Kennung: DAW unterscheidet die beiden
  else
    FEffect.UniqueID := VstFourCC('GrnS');
  FEffect.Version := PLUGIN_VERSION;

  FRect.Top := 0;
  FRect.Left := 0;
  FRect.Bottom := EDITOR_H;
  FRect.Right := EDITOR_W;
end;

destructor TGranularPlugin.Destroy;
begin
  CloseEditor;
  FEngine.Free;
  inherited;
end;

procedure TGranularPlugin.OpenEditor(ParentWnd: HWND);
begin
  CloseEditor;
  FForm := TForm.CreateNew(nil);
  FForm.BorderStyle := bsNone;
  FForm.ParentWindow := ParentWnd;
  FForm.SetBounds(0, 0, EDITOR_W, EDITOR_H);
  FForm.KeyPreview := True;
  FForm.OnKeyDown := FormKeyDown;
  FForm.OnKeyUp := FormKeyUp;
  FOldFormProc := FForm.WindowProc;
  FForm.WindowProc := FormWndProc;
  CreateEditorPanel;
  // Testhilfe: Umgebungsvariable GRANULAR_TAB=1|2 oeffnet direkt einen Reiter
  FEditor.ShowPage(StrToIntDef(GetEnvironmentVariable('GRANULAR_TAB'), 0));
  // Testhilfe: GRANULAR_LFOPAGE=1 zeigt LFO 5-8, GRANULAR_MATPAGE=n die Matrix-Seite n (0-basiert)
  if GetEnvironmentVariable('GRANULAR_LFOPAGE') <> '' then
    FEditor.ShowLfoPage(StrToIntDef(GetEnvironmentVariable('GRANULAR_LFOPAGE'), 0));
  if GetEnvironmentVariable('GRANULAR_MATPAGE') <> '' then
    FEditor.ShowMatrixPage(StrToIntDef(GetEnvironmentVariable('GRANULAR_MATPAGE'), 0));
  // Testhilfe: GRANULAR_PRESET=<Datei> laedt beim Oeffnen ein Preset
  if FileExists(GetEnvironmentVariable('GRANULAR_PRESET')) then
    FEditor.LoadPreset(GetEnvironmentVariable('GRANULAR_PRESET'));
  if GetEnvironmentVariable('GRANULAR_INFO') = '1' then
    FEditor.ShowInfo;
  // Testhilfe: GRANULAR_FREEEDIT=1|2 oeffnet das Fenster 'freie Form' des LFOs
  if StrToIntDef(GetEnvironmentVariable('GRANULAR_FREEEDIT'), 0) in [1, 2] then
    FEditor.OpenFreeEditor(StrToInt(GetEnvironmentVariable('GRANULAR_FREEEDIT')) - 1);
  // Testhilfe: GRANULAR_HELP=1 oeffnet die Hilfe, =2 gleich den Changelog
  if GetEnvironmentVariable('GRANULAR_HELP') <> '' then
    FEditor.ShowHelp(GetEnvironmentVariable('GRANULAR_HELP') = '2');
  // Testhilfe: GRANULAR_FREELFO=1..9 oeffnet das Fenster 'freie Form' (1 = LFO 1); fuer Bildschirmfotos
  if StrToIntDef(GetEnvironmentVariable('GRANULAR_FREELFO'), 0) > 0 then
    FEditor.OpenFreeEditor(StrToIntDef(GetEnvironmentVariable('GRANULAR_FREELFO'), 1) - 1);
  // Testhilfe: GRANULAR_LANGTEST=<Kuerzel> schaltet nach dem Oeffnen die Sprache um (wie die Auswahl im Reiter Extras)
  if GetEnvironmentVariable('GRANULAR_LANGTEST') <> '' then
  begin
    LangSet(GetEnvironmentVariable('GRANULAR_LANGTEST'));
    EditorLanguageChange(nil);
  end;
  FForm.Visible := True;
end;

{ Bedienung in der Oberflaeche an die DAW melden: Beginn, Wert, Ende (VST2: audioMasterBeginEdit,
  audioMasterAutomate, audioMasterEndEdit). Damit nimmt die DAW Automation auf, und FL Studio kennt den
  Regler als "Last tweaked" (Create automation clip, Link to controller). }
procedure TGranularPlugin.EditorParamEdit(Index: Integer; Kind: TParamEditKind; Value: Single);
var
  V: Integer;
begin
  if not Assigned(FAudioMaster) then
    Exit;
  V := ParamToVst(Index);
  if V < 0 then
    Exit;
  case Kind of
    pekBegin: FAudioMaster(@FEffect, audioMasterBeginEdit, V, 0, nil, 0);
    pekChange: FAudioMaster(@FEffect, audioMasterAutomate, V, 0, nil, Value);
    pekEnd: FAudioMaster(@FEffect, audioMasterEndEdit, V, 0, nil, 0);
  end;
end;

{ Editor im Formular anlegen (beim Oeffnen und nach einem Sprachwechsel) }
procedure TGranularPlugin.CreateEditorPanel;
begin
  LangInit(FBaseDir);
  FEditor := TGranularEditor.Create(FForm, FForm, FEngine);
  FEditor.BaseDir := FBaseDir;
  FEditor.OnParamEdit := EditorParamEdit;   // Reglerbewegungen an die DAW melden
  FEditor.OnLanguageChange := EditorLanguageChange;
  if FIsFx then FEditor.FormatName := 'VST2 FX' else FEditor.FormatName := 'VST2';
  FEditor.SyncSampleFromEngine;
end;

procedure TGranularPlugin.EditorLanguageChange(Sender: TObject);
begin
  if FForm <> nil then
    PostMessage(FForm.Handle, WM_GRANULAR_RELANG, 0, 0);
end;

{ Sprachwechsel: Editor neu aufbauen, gleicher Reiter. Laeuft als Nachricht des Formulars - der alte
  Editor ist dann nicht mehr auf dem Aufrufstapel. }
procedure TGranularPlugin.FormWndProc(var Msg: TMessage);
var
  Page: Integer;
begin
  if (Msg.Msg = WM_GRANULAR_RELANG) and (FEditor <> nil) then
  begin
    Page := FEditor.PageIndex;
    FEditor.ReleaseAllKeys;
    FreeAndNil(FEditor);
    CreateEditorPanel;
    FEditor.ShowPage(Page);
    Exit;
  end;
  FOldFormProc(Msg);
end;

procedure TGranularPlugin.CloseEditor;
begin
  if FForm <> nil then
  begin
    FEditor.ReleaseAllKeys;
    FreeAndNil(FForm);   // gibt auch den Editor frei (Owner)
    FEditor := nil;
  end;
end;

procedure TGranularPlugin.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (FEditor <> nil) and FEditor.HandleKeyDown(Key, Shift) then
    Key := 0;
end;

procedure TGranularPlugin.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (FEditor <> nil) and FEditor.HandleKeyUp(Key) then
    Key := 0;
end;

procedure TGranularPlugin.ProcessEvents(Events: PVstEvents);
var
  I: Integer;
  E: PVstMidiEvent;
  Status, Data1, Data2: Byte;
begin
  if Events = nil then
    Exit;
  for I := 0 to Events.NumEvents - 1 do
  begin
    E := (PPointer(@Events.Events[0]) + I)^;
    if (E = nil) or (E.EventType <> kVstMidiType) then
      Continue;
    Status := E.MidiData[0] and $F0;
    Data1 := E.MidiData[1] and $7F;
    Data2 := E.MidiData[2] and $7F;
    case Status of
      $90:
        if Data2 > 0 then
          FEngine.NoteOn(Data1, Data2 / 127, E.DeltaFrames)
        else
          FEngine.NoteOff(Data1, E.DeltaFrames);
      $80:
        FEngine.NoteOff(Data1, E.DeltaFrames);
      $A0:                                  // polyphoner Aftertouch -> wie Kanal-Aftertouch
        FEngine.ChannelPressure(Data2 / 127, E.DeltaFrames);
      $D0:                                  // Kanal-Aftertouch
        FEngine.ChannelPressure(Data1 / 127, E.DeltaFrames);
      $E0:                                  // Pitchbend, 14 Bit, Mitte 8192
        FEngine.PitchBend(((Data2 shl 7) or Data1 - 8192) / 8192, E.DeltaFrames);
      $B0:
        case Data1 of
          120, 123:                         // All Sound Off / All Notes Off
            FEngine.AllNotesOff;
        else                                // 1 Modrad, 64 Sustain, 121 Reset, uebrige ignoriert
          FEngine.ControlChange(Data1, Data2 / 127, E.DeltaFrames);
        end;
    end;
  end;
end;

procedure TGranularPlugin.UpdateHostTempo(Frames: Integer);
var
  Ti: PVstTimeInfo;
  T0, T1: Int64;
begin
  if not Assigned(FAudioMaster) then
    Exit;
  // nur alle ~100 ms beim Host nachfragen: audioMasterGetTime aus einem Hilfs-Thread (FL Studio mit
  // Multithreading) kann den Audio-Thread auf den Haupt-Thread warten lassen - Tempo aendert sich selten
  Dec(FTempoWait, Frames);
  if FTempoWait > 0 then
    Exit;
  FTempoWait := Max(256, Round(FEngine.SampleRate * 0.1));
  QueryPerformanceCounter(T0);
  Ti := PVstTimeInfo(FAudioMaster(@FEffect, audioMasterGetTime, 0, kVstTempoValid, nil, 0));
  // Rendert der Host gerade (offline)? -> Engine kann auf Hoechstqualitaet schalten
  FEngine.Offline := FAudioMaster(@FEffect, audioMasterGetCurrentProcessLevel, 0, 0, nil, 0) = 4;
  QueryPerformanceCounter(T1);
  Inc(FHostTicks, T1 - T0);
  if (Ti <> nil) and ((Ti.Flags and kVstTempoValid) <> 0) and (Ti.Tempo > 0) then
    if Abs(ParamToPlain(gpTempo, FEngine.GetParamById(gpTempo)) - Ti.Tempo) > 0.01 then
      FEngine.SetParamById(gpTempo, PlainToParam(gpTempo, Ti.Tempo));
end;

procedure TGranularPlugin.ProcessReplacing(Inputs, Outputs: PPSingle; Frames: Int32);
var
  Pk: array[0..3] of Single;
  P, OL, OR_: System.PSingle;
  I, K, S1, S2, Done, N: Integer;
  A1L, A1R, A2L, A2R: System.PSingle;
  DL, DR: Single;
begin
  if (Outputs = nil) or (Frames <= 0) then
    Exit;
  UpdateHostTempo(Frames);
  S1 := ParamStep(Ord(gpSc1Input), FEngine.GetParamById(gpSc1Input));
  S2 := ParamStep(Ord(gpSc2Input), FEngine.GetParamById(gpSc2Input));
  Done := 0;
  while Done < Frames do
  begin
    N := Min(MAX_BLOCK, Frames - Done);
    A1L := nil; A1R := nil; A2L := nil; A2R := nil;
    if Inputs <> nil then
    begin
      // Eingaenge ZUERST in eigene Puffer: Effekt-Hosts (FL Studio) uebergeben Ein- und Ausgang oft im
      // selben Speicher - die Engine leert den Ausgang und haette damit den Sidechain geloescht
      for K := 0 to 3 do
      begin
        Pk[K] := 0;
        P := Inputs[K];
        if P <> nil then
        begin
          Move((P + Done)^, FInBuf[K][0], N * SizeOf(Single));
          for I := 0 to N - 1 do
            if Abs(FInBuf[K][I]) > Pk[K] then
              Pk[K] := Abs(FInBuf[K][I]);
        end
        else
          FillChar(FInBuf[K][0], N * SizeOf(Single), 0);
      end;
      FEngine.ReportVstInputPeaks(Pk);
      // Zuordnung: welches Eingangspaar speist Sidechain 1 / 2 (0 = aus, 1 = Eingang 1/2, 2 = Eingang 3/4)
      if S1 > 0 then
      begin
        A1L := @FInBuf[(S1 - 1) * 2][0];
        A1R := @FInBuf[(S1 - 1) * 2 + 1][0];
      end;
      if S2 > 0 then
      begin
        A2L := @FInBuf[(S2 - 1) * 2][0];
        A2R := @FInBuf[(S2 - 1) * 2 + 1][0];
      end;
    end;
    OL := Outputs[0] + Done;
    OR_ := Outputs[1] + Done;
    FEngine.Process(A1L, A1R, OL, OR_, N, A2L, A2R);
    // FX-Variante: Eingangston (Eingang 1/2 = Signal der Mixer-Spur) zum Ausgang dazu, um die gemeldete
    // Latenz (LIM_LOOK) verzoegert - der Host gleicht sie fuer das ganze Plugin aus
    if FIsFx and (Inputs <> nil) then
      for I := 0 to N - 1 do
      begin
        DL := FDryBuf[FDryPos * 2];
        DR := FDryBuf[FDryPos * 2 + 1];
        FDryBuf[FDryPos * 2] := FInBuf[0][I];
        FDryBuf[FDryPos * 2 + 1] := FInBuf[1][I];
        Inc(FDryPos);
        if FDryPos >= LIM_LOOK then FDryPos := 0;
        (OL + I)^ := (OL + I)^ + DL;
        (OR_ + I)^ := (OR_ + I)^ + DR;
      end;
    Inc(Done, N);
  end;
end;

procedure TGranularPlugin.ProcessAccumulating(Inputs, Outputs: PPSingle; Frames: Int32);
var
  Done, N, I: Integer;
  InL, InR, OutL, OutR: System.PSingle;
begin
  // altes process(): Ergebnis auf die Ausgaenge addieren
  if (Outputs = nil) or (Frames <= 0) then
    Exit;
  UpdateHostTempo(Frames);
  Done := 0;
  while Done < Frames do
  begin
    N := Min(MAX_BLOCK, Frames - Done);
    InL := nil;
    InR := nil;
    if Inputs <> nil then
    begin
      InL := Inputs[0] + Done;
      InR := Inputs[1] + Done;
    end;
    FEngine.Process(InL, InR, @FTmpL[0], @FTmpR[0], N);
    OutL := Outputs[0] + Done;
    OutR := Outputs[1] + Done;
    for I := 0 to N - 1 do
    begin
      OutL[I] := OutL[I] + FTmpL[I];
      OutR[I] := OutR[I] + FTmpR[I];
    end;
    Inc(Done, N);
  end;
end;

function TGranularPlugin.SetChunk(Data: Pointer; Size: Integer): Boolean;
var
  B: TBytes;
  Path: string;
begin
  Result := False;
  if (Data = nil) or (Size <= 0) then
    Exit;
  SetLength(B, Size);
  Move(Data^, B[0], Size);
  Result := LoadChunk(FEngine, B, Path);
  if not Result then
    Exit;
  if Path = EMPTY_SAMPLE_REF then
  begin
    if not IsEmptySample(FEngine.Sample) then
      FEngine.LoadSample(CreateEmptySample(44100));
    Path := '';
  end
  else
    Path := ResolveSamplePath(Path, FBaseDir);
  try
    if (Path <> '') and not SameText(Path, FEngine.SamplePath) then
      FEngine.LoadSample(LoadAudioFile(Path));
  except
    // Sample fehlt/defekt: Parameter sind trotzdem geladen
  end;
  LoadMorphSample(FEngine, FBaseDir);
  LoadZoneSamples(FEngine, FBaseDir);
  if FEditor <> nil then
    FEditor.SyncSampleFromEngine;
end;

function TGranularPlugin.DoDispatch(Opcode, Index: Int32; Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt;
var
  S: AnsiString;
begin
  Result := 0;
  case Opcode of
    effOpen, effMainsChanged, effSetBlockSize, effStartProcess, effStopProcess:
      Result := 0;
    effSetSampleRate:
      if Opt > 0 then
        FEngine.SetSampleRate(Opt);
    effGetProgram:
      Result := 0;
    effGetProgramName, effGetProgramNameIndexed:
      begin
        // aktueller Presetname -> GranularHost zeigt dazu passende Autoplay-Stuecke
        if FEngine.PresetName <> '' then
          VstStrCopy(Ptr, FEngine.PresetName, 64)
        else
          VstStrCopy(Ptr, 'Standard', 24);
        Result := 1;
      end;
    effGetParamName:
      if VstToParam(Index) >= 0 then
        VstStrCopy(Ptr, GetParamInfo(VstToParam(Index)).Name, 24);
    effGetParamLabel:
      if VstToParam(Index) >= 0 then
        VstStrCopy(Ptr, GetParamInfo(VstToParam(Index)).UnitStr, kVstMaxParamStrLen);
    effGetParamDisplay:
      if VstToParam(Index) >= 0 then
        VstStrCopy(Ptr, ParamDisplay(VstToParam(Index), FEngine.GetParam(VstToParam(Index))), 24);
    effCanBeAutomated:
      Result := Ord(VstToParam(Index) >= 0);
    effEditGetRect:
      begin
        if Ptr <> nil then
          PPointer(Ptr)^ := @FRect;
        Result := 1;
      end;
    effEditOpen:
      begin
        OpenEditor(HWND(Ptr));
        Result := 1;
      end;
    effEditClose:
      CloseEditor;
    effEditIdle:
      Result := 0;
    effGetChunk:
      begin
        FChunk := SaveChunk(FEngine, SampleRefFor(FEngine.Sample, MakePortablePath(FEngine.SamplePath, FBaseDir)));
        if Ptr <> nil then
          PPointer(Ptr)^ := @FChunk[0];
        Result := Length(FChunk);
      end;
    effSetChunk:
      Result := Ord(SetChunk(Ptr, Value));
    effProcessEvents:
      begin
        ProcessEvents(PVstEvents(Ptr));
        Result := 1;
      end;
    effGetPlugCategory:
      if FIsFx then Result := kPlugCategEffect else Result := kPlugCategSynth;
    // Namen der Ein-/Ausgaenge: DAWs (z. B. FL Studio) zeigen sie bei der Zuordnung an
    effGetInputProperties, effGetOutputProperties:
      if (Ptr <> nil) and (Index >= 0) and (Index < 4) and
         ((Opcode = effGetInputProperties) or (Index < 2)) then
      begin
        FillChar(Ptr^, SizeOf(TVstPinProperties), 0);
        with PVstPinProperties(Ptr)^ do
        begin
          if Opcode = effGetInputProperties then
          begin
            S := AnsiString(Format('Sidechain %d %s', [Index div 2 + 1, Copy('LR', Index mod 2 + 1, 1)]));
            Move(PAnsiChar(S)^, Label_[0], Length(S));
            S := AnsiString(Format('SC%d%s', [Index div 2 + 1, Copy('LR', Index mod 2 + 1, 1)]));
          end
          else
          begin
            S := AnsiString('Ausgang ' + Copy('LR', Index + 1, 1));
            Move(PAnsiChar(S)^, Label_[0], Length(S));
            S := AnsiString('Out' + Copy('LR', Index + 1, 1));
          end;
          Move(PAnsiChar(S)^, ShortLabel[0], Min(7, Length(S)));
          Flags := kVstPinIsActive;
          if Index mod 2 = 0 then
            Flags := Flags or kVstPinIsStereo;   // erster Kanal eines Stereopaars
        end;
        Result := 1;
      end;
    effGetEffectName, effGetProductString:
      begin
        if FIsFx then
          VstStrCopy(Ptr, PLUGIN_NAME + ' FX', kVstMaxNameLen)
        else
          VstStrCopy(Ptr, PLUGIN_NAME, kVstMaxNameLen);
        Result := 1;
      end;
    effGetVendorString:
      begin
        VstStrCopy(Ptr, VENDOR_NAME, kVstMaxNameLen);
        Result := 1;
      end;
    effGetVendorVersion:
      Result := PLUGIN_VERSION;
    effGetVstVersion:
      Result := 2400;
    effCanDo:
      begin
        S := AnsiString(PAnsiChar(Ptr));
        if (S = 'receiveVstEvents') or (S = 'receiveVstMidiEvent') or (S = 'receiveVstTimeInfo') or (S = 'granularResizable') then
          Result := 1
        else
          Result := -1;
      end;
  end;
end;

function CreatePlugin(AudioMaster: TAudioMasterCallback): PAEffect;
var
  P: TGranularPlugin;
begin
  Result := nil;
  try
    // Host-Versionspruefung wie ueblich: ohne audioMaster kein Plugin
    if not Assigned(AudioMaster) or (AudioMaster(nil, audioMasterVersion, 0, 0, nil, 0) = 0) then
      Exit;
    P := TGranularPlugin.Create(AudioMaster);
    Result := @P.FEffect;
  except
    Result := nil;
  end;
end;

end.
