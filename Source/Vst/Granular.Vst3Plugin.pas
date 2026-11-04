{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Vst3Plugin;

{ VST3-Huelle um TGranularEngine + TGranularEditor (dieselbe DLL wie das VST2-Plugin, ausgeliefert
  zusaetzlich als GranularSynth.vst3).
    - Fabrik mit zwei Klassen: "GranularSynth" (Instrument|Synth) und "GranularSynth FX" (Fx, fuer den
      Sidechain im Mixer-Einschub)
    - "Single Component": ein Objekt ist Prozessor (IComponent, IAudioProcessor) und Controller
      (IEditController); die DAW holt den Controller per QueryInterface
    - Parameter-IDs = VST2-Nummern (stabil, Automation in DAW-Projekten bleibt gueltig)
    - MIDI-Controller, Pitchbend und Aftertouch kommen in VST3 als (versteckte) Parameter: IMidiMapping
      ordnet Controller 0..129 den IDs MIDI_BASE + n zu -> Modrad, Pedal, MIDI-Learn wie bei VST2
    - Zustand = derselbe Chunk wie VST2 (Granular.State)
    - Rechtsklick auf einen Regler zeigt das Kontextmenue der DAW (IComponentHandler3), z.B. FL Studio
      "Create automation clip", mit einem Eintrag fuer das eigene Menue
  Keine Exception verlaesst die DLL; FPU/SSE-Ausnahmen sind waehrend der Aufrufe maskiert. }

interface

function GetPluginFactory: Pointer; stdcall;
function InitDll: Boolean; stdcall;
function ExitDll: Boolean; stdcall;

implementation

uses
  Granular.Lang,
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math, System.Types,
  Vcl.Controls, Vcl.Forms,
  Granular.Vst3, Granular.Params, Granular.Sample, Granular.Engine, Granular.State, Granular.Editor,
  Granular.AudioDecode;

const
  WM_GRANULAR_RELANG = WM_USER + 711;   // Editor nach Sprachwechsel neu aufbauen


const
  CID_SYNTH: TGUID = '{8F3A2C61-4B7D-4E19-A6C2-1D5E9B07F3A1}';
  CID_FX: TGUID = '{8F3A2C61-4B7D-4E19-A6C2-1D5E9B07F3A2}';
  VENDOR = 'HABI M';
  SDK_VERSION = 'VST 3.7.9';
  MIDI_BASE = 1000000;          // IDs der versteckten MIDI-Parameter: MIDI_BASE + Controller (0..129)
  EDITOR_W = 1260;
  EDITOR_H = 712;
  MAX_BLOCK = 8192;
  TAG_OWN_MENU = 1;

{$POINTERMATH ON}
{$WARN SYMBOL_PLATFORM OFF}

type
  TFpuState = record
    CW: Word;
    MX: UInt32;
  end;

function EnterFpu: TFpuState;
begin
  Result.CW := Get8087CW;
  Result.MX := GetMXCSR;
  Set8087CW($133F);
  SetMXCSR($9F80);
end;

procedure LeaveFpu(const S: TFpuState);
begin
  Set8087CW(S.CW);
  SetMXCSR(S.MX);
end;

type
  TGranularView = class;

  TGranularVst3 = class(TInterfacedObject, IPluginBase, IComponent, IAudioProcessor, IEditController, IMidiMapping)
  private
    FEngine: TGranularEngine;
    FIsFx: Boolean;
    FBaseDir: string;
    FHandler: IComponentHandler;
    FHandler3: IComponentHandler3;
    FView: TGranularView;          // schwach: die Ansicht haelt das Plugin, nicht umgekehrt
    FViewIntf: Pointer;            // IPlugView* der Ansicht (fuer das DAW-Kontextmenue)
    FForm: TForm;
    FEditor: TGranularEditor;
    FOldFormProc: TWndMethod;         // Fensterprozedur des Editor-Formulars (Sprachwechsel)
    FEditW, FEditH: Integer;          // Fenstergroesse in Pixeln (gewaehlte Skalierung)
    FInBuf: array[0..3] of TArray<Single>;
    FDryBuf: array[0..LIM_LOOK * 2 - 1] of Single;
    FDryPos: Integer;
    FMidiVal: array[0..kCountCtrlNumber - 1] of Double;
    procedure LoadChunkBytes(const B: TBytes);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditorParamEdit(Index: Integer; Kind: TParamEditKind; Value: Single);
    function EditorHostMenu(Index: Integer; const ScreenPos: TPoint; Ctrl: TControl): Boolean;
    procedure ProcessAudio(var Data: TProcessData);
  public
    constructor Create(AIsFx: Boolean);
    destructor Destroy; override;
    procedure OpenEditor(ParentWnd: HWND);
    procedure CloseEditor;
    procedure CreateEditorPanel;
    procedure UpdateEditSize;
    procedure EditorLanguageChange(Sender: TObject);
    procedure FormWndProc(var Msg: TMessage);
    // IPluginBase
    function initialize(context: Pointer): TResult; stdcall;
    function terminate: TResult; stdcall;
    // IComponent
    function getControllerClassId(classId: PGUID): TResult; stdcall;
    function setIoMode(mode: Int32): TResult; stdcall;
    function getBusCount(mediaType, dir: Int32): Int32; stdcall;
    function getBusInfo(mediaType, dir, index: Int32; var bus: TBusInfo): TResult; stdcall;
    function getRoutingInfo(var inInfo, outInfo: TRoutingInfo): TResult; stdcall;
    function activateBus(mediaType, dir, index: Int32; state: TBool): TResult; stdcall;
    function setActive(state: TBool): TResult; stdcall;
    function IComponent.setState = CompSetState;
    function IComponent.getState = CompGetState;
    function CompSetState(state: Pointer): TResult; stdcall;
    function CompGetState(state: Pointer): TResult; stdcall;
    // IAudioProcessor
    function setBusArrangements(inputs: PSpeakerArrangement; numIns: Int32; outputs: PSpeakerArrangement;
      numOuts: Int32): TResult; stdcall;
    function getBusArrangement(dir, index: Int32; var arr: TSpeakerArrangement): TResult; stdcall;
    function canProcessSampleSize(symbolicSampleSize: Int32): TResult; stdcall;
    function getLatencySamples: UInt32; stdcall;
    function setupProcessing(var setup: TProcessSetup): TResult; stdcall;
    function setProcessing(state: TBool): TResult; stdcall;
    function process(var data: TProcessData): TResult; stdcall;
    function getTailSamples: UInt32; stdcall;
    // IEditController
    function setComponentState(state: Pointer): TResult; stdcall;
    function IEditController.setState = CtrlSetState;
    function IEditController.getState = CtrlGetState;
    function CtrlSetState(state: Pointer): TResult; stdcall;
    function CtrlGetState(state: Pointer): TResult; stdcall;
    function getParameterCount: Int32; stdcall;
    function getParameterInfo(paramIndex: Int32; var info: TParameterInfo): TResult; stdcall;
    function getParamStringByValue(id: TParamID; valueNormalized: TParamValue; str: PWideChar): TResult; stdcall;
    function getParamValueByString(id: TParamID; str: PWideChar; out valueNormalized: TParamValue): TResult; stdcall;
    function normalizedParamToPlain(id: TParamID; valueNormalized: TParamValue): TParamValue; stdcall;
    function plainParamToNormalized(id: TParamID; plainValue: TParamValue): TParamValue; stdcall;
    function getParamNormalized(id: TParamID): TParamValue; stdcall;
    function setParamNormalized(id: TParamID; value: TParamValue): TResult; stdcall;
    function setComponentHandler(handler: Pointer): TResult; stdcall;
    function createView(name: PAnsiChar): Pointer; stdcall;
    // IMidiMapping
    function getMidiControllerAssignment(busIndex: Int32; channel: Int16; midiControllerNumber: Int16;
      out id: TParamID): TResult; stdcall;
  end;

  TGranularView = class(TInterfacedObject, IPlugView)
  private
    FPlugin: TGranularVst3;
    FKeep: IUnknown;               // haelt das Plugin am Leben, solange die Ansicht existiert
    FFrame: Pointer;               // IPlugFrame* der DAW (Groessenwunsch), nicht gezaehlt
  public
    constructor Create(APlugin: TGranularVst3);
    destructor Destroy; override;
    function isPlatformTypeSupported(platformType: PAnsiChar): TResult; stdcall;
    function attached(parent: Pointer; platformType: PAnsiChar): TResult; stdcall;
    function removed: TResult; stdcall;
    function onWheel(distance: Single): TResult; stdcall;
    function onKeyDown(key: WideChar; keyCode: Int16; modifiers: Int16): TResult; stdcall;
    function onKeyUp(key: WideChar; keyCode: Int16; modifiers: Int16): TResult; stdcall;
    function getSize(size: PViewRect): TResult; stdcall;
    function onSize(newSize: PViewRect): TResult; stdcall;
    function onFocus(state: TBool): TResult; stdcall;
    function setFrame(frame: Pointer): TResult; stdcall;
    function canResize: TResult; stdcall;
    function checkSizeConstraint(rect: PViewRect): TResult; stdcall;
  end;

  { Eintrag im DAW-Kontextmenue: oeffnet das eigene Menue }
  TMenuTarget = class(TInterfacedObject, IContextMenuTarget)
  private
    FAction: TProc;
  public
    constructor Create(const AAction: TProc);
    function executeMenuItem(tag: Int32): TResult; stdcall;
  end;

  TGranularFactory = class(TInterfacedObject, IPluginFactory, IPluginFactory2)
  public
    function getFactoryInfo(info: PFactoryInfo): TResult; stdcall;
    function countClasses: Int32; stdcall;
    function getClassInfo(index: Int32; info: PClassInfo): TResult; stdcall;
    function createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult; stdcall;
    function getClassInfo2(index: Int32; info: PClassInfo2): TResult; stdcall;
  end;

{ --- Datenstrom (IBStream) lesen/schreiben --- }

function ReadAll(StreamPtr: Pointer): TBytes;
var
  S: IBStream;
  Buf: array[0..65535] of Byte;
  Got, N: Integer;
begin
  Result := nil;
  if StreamPtr = nil then
    Exit;
  S := IBStream(StreamPtr);
  N := 0;
  repeat
    Got := 0;
    if S.read(@Buf[0], SizeOf(Buf), @Got) <> kResultOk then
      Break;
    if Got > 0 then
    begin
      SetLength(Result, N + Got);
      Move(Buf[0], Result[N], Got);
      Inc(N, Got);
    end;
  until Got < SizeOf(Buf);
end;

{ --- TGranularVst3 --- }

constructor TGranularVst3.Create(AIsFx: Boolean);
var
  K: Integer;
begin
  inherited Create;
  FIsFx := AIsFx;
  FEngine := TGranularEngine.Create;
  FBaseDir := ExtractFilePath(GetModuleName(HInstance));
  FEngine.SetSampleRate(44100);
  if FileExists(FBaseDir + 'Beispieltoene' + PathDelim + 'Demo_Klang.wav') then
    try
      FEngine.LoadSample(LoadWaveFile(FBaseDir + 'Beispieltoene' + PathDelim + 'Demo_Klang.wav'));
    except
      FEngine.LoadSample(CreateDemoSample(44100));
    end
  else
    FEngine.LoadSample(CreateDemoSample(44100));
  LoadMidiMap(FEngine, FBaseDir + MIDI_MAP_FILE);
  for K := 0 to 3 do
    SetLength(FInBuf[K], MAX_BLOCK);
  FMidiVal[kPitchBend] := 0.5;
end;

destructor TGranularVst3.Destroy;
begin
  CloseEditor;
  FHandler3 := nil;
  FHandler := nil;
  FEngine.Free;
  inherited;
end;

function TGranularVst3.initialize(context: Pointer): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.terminate: TResult;
begin
  FHandler3 := nil;
  FHandler := nil;
  Result := kResultOk;
end;

function TGranularVst3.getControllerClassId(classId: PGUID): TResult;
begin
  Result := kNotImplemented;    // Single Component: Controller ist dasselbe Objekt
end;

function TGranularVst3.setIoMode(mode: Int32): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.getBusCount(mediaType, dir: Int32): Int32;
begin
  Result := 0;
  if mediaType = kAudio then
  begin
    if dir = kInput then Result := 2 else Result := 1;
  end
  else if (mediaType = kEvent) and (dir = kInput) then
    Result := 1;
end;

function TGranularVst3.getBusInfo(mediaType, dir, index: Int32; var bus: TBusInfo): TResult;
var
  Nm: string;
begin
  Result := kInvalidArgument;
  if (index < 0) or (index >= getBusCount(mediaType, dir)) then
    Exit;
  FillChar(bus, SizeOf(bus), 0);
  bus.mediaType := mediaType;
  bus.direction := dir;
  bus.flags := kDefaultActive;
  if mediaType = kEvent then
  begin
    bus.channelCount := 16;
    bus.busType := kMain;
    Nm := 'MIDI';
  end
  else
  begin
    bus.channelCount := 2;
    if dir = kOutput then
    begin
      bus.busType := kMain;
      Nm := Tr('Ausgang');
    end
    else if index = 0 then
    begin
      // FX: Eingang 1/2 ist das Signal der Mixer-Spur; Instrument: Sidechain-Eingang
      if FIsFx then
      begin
        bus.busType := kMain;
        Nm := Tr('Eingang (E1/E2)');
      end
      else
      begin
        bus.busType := kAux;
        Nm := Tr('Sidechain (E1/E2)');
      end;
    end
    else
    begin
      bus.busType := kAux;
      bus.flags := 0;
      Nm := Tr('Sidechain 2 (E3/E4)');
    end;
  end;
  StrToString128(Nm, @bus.name[0]);
  Result := kResultOk;
end;

function TGranularVst3.getRoutingInfo(var inInfo, outInfo: TRoutingInfo): TResult;
begin
  Result := kNotImplemented;
end;

function TGranularVst3.activateBus(mediaType, dir, index: Int32; state: TBool): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.setActive(state: TBool): TResult;
begin
  Result := kResultOk;
end;

procedure TGranularVst3.LoadChunkBytes(const B: TBytes);
var
  Path: string;
begin
  if (Length(B) = 0) or not LoadChunk(FEngine, B, Path) then
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
  end;
  LoadMorphSample(FEngine, FBaseDir);
  LoadZoneSamples(FEngine, FBaseDir);
  if FEditor <> nil then
    FEditor.SyncSampleFromEngine;
end;

function TGranularVst3.CompSetState(state: Pointer): TResult;
var
  F: TFpuState;
begin
  F := EnterFpu;
  try
    try
      LoadChunkBytes(ReadAll(state));
      Result := kResultOk;
    except
      Result := kResultFalse;
    end;
  finally
    LeaveFpu(F);
  end;
end;

function TGranularVst3.CompGetState(state: Pointer): TResult;
var
  B: TBytes;
  W: Integer;
begin
  Result := kResultFalse;
  if state = nil then
    Exit;
  try
    B := SaveChunk(FEngine, SampleRefFor(FEngine.Sample, MakePortablePath(FEngine.SamplePath, FBaseDir)));
    W := 0;
    if Length(B) > 0 then
      Result := IBStream(state).write(@B[0], Length(B), @W);
  except
    Result := kResultFalse;
  end;
end;

function TGranularVst3.setBusArrangements(inputs: PSpeakerArrangement; numIns: Int32;
  outputs: PSpeakerArrangement; numOuts: Int32): TResult;
var
  I: Integer;
begin
  Result := kResultTrue;
  for I := 0 to numIns - 1 do
    if inputs[I] <> kSpeakerStereo then
      Result := kResultFalse;
  for I := 0 to numOuts - 1 do
    if outputs[I] <> kSpeakerStereo then
      Result := kResultFalse;
end;

function TGranularVst3.getBusArrangement(dir, index: Int32; var arr: TSpeakerArrangement): TResult;
begin
  arr := kSpeakerStereo;
  Result := kResultOk;
end;

function TGranularVst3.canProcessSampleSize(symbolicSampleSize: Int32): TResult;
begin
  if symbolicSampleSize = kSample32 then Result := kResultTrue else Result := kResultFalse;
end;

function TGranularVst3.getLatencySamples: UInt32;
begin
  Result := LIM_LOOK;   // Limiter-Vorausschau, die DAW gleicht sie aus
end;

function TGranularVst3.setupProcessing(var setup: TProcessSetup): TResult;
begin
  if setup.sampleRate > 0 then
    FEngine.SetSampleRate(setup.sampleRate);
  FEngine.Offline := setup.processMode = kOffline;
  Result := kResultOk;
end;

function TGranularVst3.setProcessing(state: TBool): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.process(var data: TProcessData): TResult;
var
  F: TFpuState;
  PC: IParameterChanges;
  Q: IParamValueQueue;
  EL: IEventList;
  Ev: TVst3Event;
  I, J, N, Ofs, Ctrl, Idx: Integer;
  V: TParamValue;
  Id: TParamID;
begin
  Result := kResultOk;
  F := EnterFpu;
  try
    try
      // Parameter (Automation, Regler der DAW) und MIDI-Controller
      if data.inputParameterChanges <> nil then
      begin
        Pointer(PC) := data.inputParameterChanges;      // geliehen: ohne AddRef/Release
        try
          for I := 0 to PC.getParameterCount - 1 do
          begin
            Pointer(Q) := PC.getParameterData(I);
            try
              if Q = nil then
                Continue;
              Id := Q.getParameterId;
              N := Q.getPointCount;
              if Id >= MIDI_BASE then
              begin
                Ctrl := Id - MIDI_BASE;
                for J := 0 to N - 1 do
                  if Q.getPoint(J, Ofs, V) = kResultOk then
                  begin
                    if (Ctrl >= 0) and (Ctrl < kCountCtrlNumber) then
                      FMidiVal[Ctrl] := V;
                    if Ctrl = kPitchBend then
                      FEngine.PitchBend(V * 2 - 1, Ofs)
                    else if Ctrl = kAfterTouch then
                      FEngine.ChannelPressure(V, Ofs)
                    else if (Ctrl >= 0) and (Ctrl < 128) then
                      FEngine.ControlChange(Ctrl, V, Ofs);
                  end;
              end
              else if (N > 0) and (Q.getPoint(N - 1, Ofs, V) = kResultOk) then
              begin
                Idx := VstToParam(Id);
                if Idx >= 0 then
                  FEngine.SetParam(Idx, V);
              end;
            finally
              Pointer(Q) := nil;
            end;
          end;
        finally
          Pointer(PC) := nil;
        end;
      end;
      // Noten
      if data.inputEvents <> nil then
      begin
        Pointer(EL) := data.inputEvents;
        try
          for I := 0 to EL.getEventCount - 1 do
          begin
            FillChar(Ev, SizeOf(Ev), 0);
            if EL.getEvent(I, Ev) <> kResultOk then
              Continue;
            case Ev.eventType of
              kNoteOnEvent:
                if Ev.onVelocity > 0 then
                  FEngine.NoteOn(Ev.onPitch, Ev.onVelocity, Ev.sampleOffset)
                else
                  FEngine.NoteOff(Ev.onPitch, Ev.sampleOffset);
              kNoteOffEvent:
                FEngine.NoteOff(Ev.offPitch, Ev.sampleOffset);
            end;
          end;
        finally
          Pointer(EL) := nil;
        end;
      end;
      // Tempo und Rendern
      if (data.processContext <> nil) and ((data.processContext.state and kTempoValid) <> 0) and
         (data.processContext.tempo > 0) then
        if Abs(ParamToPlain(gpTempo, FEngine.GetParamById(gpTempo)) - data.processContext.tempo) > 0.01 then
          FEngine.SetParamById(gpTempo, PlainToParam(gpTempo, data.processContext.tempo));
      FEngine.Offline := data.processMode = kOffline;
      ProcessAudio(data);
    except
      Result := kResultOk;
    end;
  finally
    LeaveFpu(F);
  end;
end;

{ Audio wie im VST2-Plugin: Eingaenge zuerst kopieren (Host kann Ein- und Ausgang teilen), Zuordnung
  Sidechain 1/2, FX: trockenes Eingangssignal latenzgleich dazu }
procedure TGranularVst3.ProcessAudio(var Data: TProcessData);
var
  OL, OR_, P, A1L, A1R, A2L, A2R: System.PSingle;
  Pk: array[0..3] of Single;
  B, C, I, K, S1, S2, Done, N, Frames: Integer;
  DL, DR: Single;
  Bus: PAudioBusBuffers;
begin
  Frames := Data.numSamples;
  if (Frames <= 0) or (Data.numOutputs < 1) or (Data.outputs = nil) or (Data.outputs.channelBuffers32 = nil) or
     (Data.outputs.numChannels < 1) then
    Exit;
  OL := Data.outputs.channelBuffers32[0];
  if Data.outputs.numChannels >= 2 then OR_ := Data.outputs.channelBuffers32[1] else OR_ := OL;
  S1 := ParamStep(Ord(gpSc1Input), FEngine.GetParamById(gpSc1Input));
  S2 := ParamStep(Ord(gpSc2Input), FEngine.GetParamById(gpSc2Input));
  Done := 0;
  while Done < Frames do
  begin
    N := Min(MAX_BLOCK, Frames - Done);
    for K := 0 to 3 do
    begin
      Pk[K] := 0;
      FillChar(FInBuf[K][0], N * SizeOf(Single), 0);
    end;
    for B := 0 to Min(Data.numInputs, 2) - 1 do
    begin
      Bus := Data.inputs + B;
      if (Bus.channelBuffers32 = nil) or (Bus.numChannels < 1) then
        Continue;
      for C := 0 to 1 do
      begin
        K := B * 2 + C;
        P := Bus.channelBuffers32[Min(C, Bus.numChannels - 1)];
        if P = nil then
          Continue;
        Move((P + Done)^, FInBuf[K][0], N * SizeOf(Single));
        for I := 0 to N - 1 do
          if Abs(FInBuf[K][I]) > Pk[K] then
            Pk[K] := Abs(FInBuf[K][I]);
      end;
    end;
    FEngine.ReportVstInputPeaks(Pk);
    A1L := nil; A1R := nil; A2L := nil; A2R := nil;
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
    FEngine.Process(A1L, A1R, OL + Done, OR_ + Done, N, A2L, A2R);
    if FIsFx then
      for I := 0 to N - 1 do
      begin
        DL := FDryBuf[FDryPos * 2];
        DR := FDryBuf[FDryPos * 2 + 1];
        FDryBuf[FDryPos * 2] := FInBuf[0][I];
        FDryBuf[FDryPos * 2 + 1] := FInBuf[1][I];
        Inc(FDryPos);
        if FDryPos >= LIM_LOOK then FDryPos := 0;
        (OL + Done + I)^ := (OL + Done + I)^ + DL;
        if OR_ <> OL then
          (OR_ + Done + I)^ := (OR_ + Done + I)^ + DR;
      end;
    Inc(Done, N);
  end;
  Data.outputs.silenceFlags := 0;
end;

function TGranularVst3.getTailSamples: UInt32;
begin
  Result := kInfiniteTail;   // Hall/Echo klingen nach; Stille wird intern ohnehin uebersprungen
end;

function TGranularVst3.setComponentState(state: Pointer): TResult;
begin
  Result := kResultOk;       // Single Component: der Zustand liegt schon im selben Objekt
end;

function TGranularVst3.CtrlSetState(state: Pointer): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.CtrlGetState(state: Pointer): TResult;
begin
  Result := kResultOk;
end;

function TGranularVst3.getParameterCount: Int32;
begin
  Result := PARAM_COUNT + kCountCtrlNumber;
end;

function TGranularVst3.getParameterInfo(paramIndex: Int32; var info: TParameterInfo): TResult;
var
  Idx, Ctrl: Integer;
  PI: TParamInfo;
  Nm: string;
begin
  Result := kInvalidArgument;
  if (paramIndex < 0) or (paramIndex >= getParameterCount) then
    Exit;
  FillChar(info, SizeOf(info), 0);
  info.unitId := kRootUnitId;
  if paramIndex < PARAM_COUNT then
  begin
    Idx := VstToParam(paramIndex);
    PI := GetParamInfo(Idx);
    info.id := paramIndex;
    StrToString128(PI.Name, @info.title[0]);
    StrToString128(PI.Name, @info.shortTitle[0]);
    StrToString128(PI.UnitStr, @info.units[0]);
    if (PI.Curve = pcStepped) and (PI.Steps >= 2) then
    begin
      info.stepCount := PI.Steps - 1;
      info.flags := kCanAutomate or kIsList;
    end
    else
      info.flags := kCanAutomate;
    info.defaultNormalizedValue := PlainToParam(Idx, PI.DefV);
  end
  else
  begin
    Ctrl := paramIndex - PARAM_COUNT;
    info.id := MIDI_BASE + Ctrl;
    case Ctrl of
      kAfterTouch: Nm := Tr('MIDI Aftertouch');
      kPitchBend: Nm := Tr('MIDI Pitchbend');
    else
      Nm := Format(Tr('MIDI CC %d'), [Ctrl]);
    end;
    StrToString128(Nm, @info.title[0]);
    StrToString128(Nm, @info.shortTitle[0]);
    info.flags := kIsHidden;
    if Ctrl = kPitchBend then
      info.defaultNormalizedValue := 0.5;
  end;
  Result := kResultOk;
end;

function TGranularVst3.getParamStringByValue(id: TParamID; valueNormalized: TParamValue; str: PWideChar): TResult;
var
  Idx: Integer;
begin
  Result := kResultFalse;
  if str = nil then
    Exit;
  try
    if id >= MIDI_BASE then
      StrToString128(Format('%.0f', [valueNormalized * 127]), str)
    else
    begin
      Idx := VstToParam(id);
      if Idx < 0 then
        Exit;
      StrToString128(ParamDisplay(Idx, valueNormalized), str);
    end;
    Result := kResultOk;
  except
  end;
end;

function TGranularVst3.getParamValueByString(id: TParamID; str: PWideChar; out valueNormalized: TParamValue): TResult;
begin
  valueNormalized := 0;
  Result := kResultFalse;
end;

function TGranularVst3.normalizedParamToPlain(id: TParamID; valueNormalized: TParamValue): TParamValue;
begin
  if (id < MIDI_BASE) and (VstToParam(id) >= 0) then
    Result := ParamToPlain(VstToParam(id), valueNormalized)
  else
    Result := valueNormalized;
end;

function TGranularVst3.plainParamToNormalized(id: TParamID; plainValue: TParamValue): TParamValue;
begin
  if (id < MIDI_BASE) and (VstToParam(id) >= 0) then
    Result := PlainToParam(VstToParam(id), plainValue)
  else
    Result := plainValue;
end;

function TGranularVst3.getParamNormalized(id: TParamID): TParamValue;
begin
  if id >= MIDI_BASE then
  begin
    if id - MIDI_BASE < kCountCtrlNumber then Result := FMidiVal[id - MIDI_BASE] else Result := 0;
  end
  else if VstToParam(id) >= 0 then
    Result := FEngine.GetParam(VstToParam(id))
  else
    Result := 0;
end;

function TGranularVst3.setParamNormalized(id: TParamID; value: TParamValue): TResult;
begin
  Result := kResultOk;
  if id >= MIDI_BASE then
  begin
    if id - MIDI_BASE < kCountCtrlNumber then
      FMidiVal[id - MIDI_BASE] := value;
  end
  else if VstToParam(id) >= 0 then
    FEngine.SetParam(VstToParam(id), value)
  else
    Result := kInvalidArgument;
end;

function TGranularVst3.setComponentHandler(handler: Pointer): TResult;
begin
  FHandler3 := nil;
  FHandler := IComponentHandler(handler);
  if FHandler <> nil then
    Supports(FHandler, IComponentHandler3, FHandler3);
  Result := kResultOk;
end;

function TGranularVst3.createView(name: PAnsiChar): Pointer;
var
  V: IPlugView;
begin
  Result := nil;
  if (name = nil) or (AnsiString(name) <> 'editor') or (FView <> nil) then
    Exit;
  V := TGranularView.Create(Self);
  V._AddRef;                   // Rueckgabe gehoert der DAW (sie ruft release)
  Result := Pointer(V);
  FViewIntf := Result;
end;

function TGranularVst3.getMidiControllerAssignment(busIndex: Int32; channel: Int16; midiControllerNumber: Int16;
  out id: TParamID): TResult;
begin
  if (busIndex = 0) and (midiControllerNumber >= 0) and (midiControllerNumber < kCountCtrlNumber) then
  begin
    id := MIDI_BASE + Cardinal(midiControllerNumber);
    Result := kResultTrue;
  end
  else
  begin
    id := 0;
    Result := kResultFalse;
  end;
end;

procedure TGranularVst3.OpenEditor(ParentWnd: HWND);
begin
  CloseEditor;
  FForm := TForm.CreateNew(nil);
  FForm.BorderStyle := bsNone;
  FForm.ParentWindow := ParentWnd;
  UpdateEditSize;
  FForm.SetBounds(0, 0, FEditW, FEditH);
  FForm.KeyPreview := True;
  FForm.OnKeyDown := FormKeyDown;
  FForm.OnKeyUp := FormKeyUp;
  FOldFormProc := FForm.WindowProc;
  FForm.WindowProc := FormWndProc;
  CreateEditorPanel;
  FForm.Visible := True;
end;

{ Editor im Formular anlegen (beim Oeffnen und nach einem Sprachwechsel) }
procedure TGranularVst3.CreateEditorPanel;
begin
  LangInit(FBaseDir);
  GUiScalePct := UiScaleLoad(FBaseDir);   // selbst gezeichnete Anzeigen: Schriftgroesse beim Aufbau
  FEditor := TGranularEditor.Create(FForm, FForm, FEngine);
  FEditor.BaseDir := FBaseDir;
  FEditor.OnParamEdit := EditorParamEdit;
  FEditor.OnHostMenu := EditorHostMenu;
  FEditor.OnLanguageChange := EditorLanguageChange;
  if FIsFx then FEditor.FormatName := 'VST3 FX' else FEditor.FormatName := 'VST3';
  FEditor.SyncSampleFromEngine;
  // gewaehlte Fenstergroesse: alle Positionen und Schriften mitwachsen lassen
  if FEditW <> EDITOR_W then
    FEditor.ApplyScale(FEditW, EDITOR_W);
end;

{ Fenstergroesse aus der gemerkten Skalierung (Reiter Extras: Fenstergroesse) }
procedure TGranularVst3.UpdateEditSize;
var
  S: Integer;
begin
  S := UiScaleLoad(FBaseDir);
  FEditW := MulDiv(EDITOR_W, S, 100);
  FEditH := MulDiv(EDITOR_H, S, 100);
end;

procedure TGranularVst3.EditorLanguageChange(Sender: TObject);
begin
  if FForm <> nil then
    PostMessage(FForm.Handle, WM_GRANULAR_RELANG, 0, 0);
end;

{ Sprachwechsel: Editor neu aufbauen, gleicher Reiter (als Nachricht: alter Editor nicht mehr aktiv) }
procedure TGranularVst3.FormWndProc(var Msg: TMessage);
var
  Page, OldW, OldH: Integer;
  R: TViewRect;
begin
  if (Msg.Msg = WM_GRANULAR_RELANG) and (FEditor <> nil) then
  begin
    Page := FEditor.PageIndex;
    FEditor.ReleaseAllKeys;
    FreeAndNil(FEditor);
    // Fenstergroesse geaendert: Formular anpassen und die DAW ueber IPlugFrame bitten
    OldW := FEditW;
    OldH := FEditH;
    UpdateEditSize;
    if (FEditW <> OldW) or (FEditH <> OldH) then
    begin
      FForm.SetBounds(0, 0, FEditW, FEditH);
      if (FView <> nil) and (FView.FFrame <> nil) then
      begin
        R.left := 0; R.top := 0; R.right := FEditW; R.bottom := FEditH;
        IPlugFrame(FView.FFrame).resizeView(FViewIntf, @R);
      end;
    end;
    CreateEditorPanel;
    FEditor.ShowPage(Page);
    Exit;
  end;
  FOldFormProc(Msg);
end;

procedure TGranularVst3.CloseEditor;
begin
  if FForm <> nil then
  begin
    FEditor.ReleaseAllKeys;
    FreeAndNil(FForm);
    FEditor := nil;
  end;
end;

procedure TGranularVst3.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (FEditor <> nil) and FEditor.HandleKeyDown(Key, Shift) then
    Key := 0;
end;

procedure TGranularVst3.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (FEditor <> nil) and FEditor.HandleKeyUp(Key) then
    Key := 0;
end;

{ Bedienung an die DAW: beginEdit / performEdit / endEdit (Automation aufnehmen, "Last tweaked") }
procedure TGranularVst3.EditorParamEdit(Index: Integer; Kind: TParamEditKind; Value: Single);
var
  Id: Integer;
begin
  if FHandler = nil then
    Exit;
  Id := ParamToVst(Index);
  if Id < 0 then
    Exit;
  case Kind of
    pekBegin: FHandler.beginEdit(Id);
    pekChange: FHandler.performEdit(Id, Value);
    pekEnd: FHandler.endEdit(Id);
  end;
end;

{ Rechtsklick auf einen Regler: Kontextmenue der DAW fuer diesen Parameter (z.B. FL Studio "Create
  automation clip"), dazu ein Eintrag fuer das eigene Menue (Modulation, MIDI-Learn, Standardwert) }
function TGranularVst3.EditorHostMenu(Index: Integer; const ScreenPos: TPoint; Ctrl: TControl): Boolean;
var
  Id: TParamID;
  M: IContextMenu;
  Item: TContextMenuItem;
  Target: IContextMenuTarget;
  Pt: TPoint;
  Ed: TGranularEditor;
begin
  Result := False;
  if (FHandler3 = nil) or (FViewIntf = nil) or (FForm = nil) or (ParamToVst(Index) < 0) then
    Exit;
  Id := ParamToVst(Index);
  Pointer(M) := FHandler3.createContextMenu(FViewIntf, @Id);   // gehoert uns: Release am Ende
  if M = nil then
    Exit;
  Ed := FEditor;
  Target := TMenuTarget.Create(
    procedure
    begin
      Ed.ShowOwnMenu(Ctrl, ScreenPos);
    end);
  FillChar(Item, SizeOf(Item), 0);
  Item.flags := kIsSeparator;
  M.addItem(Item, nil);
  FillChar(Item, SizeOf(Item), 0);
  StrToString128(Tr('GranularSynth: Modulieren, MIDI-Learn, Standardwert ...'), @Item.name[0]);
  Item.tag := TAG_OWN_MENU;
  M.addItem(Item, Target);
  Pt := FForm.ScreenToClient(ScreenPos);
  M.popup(Pt.X, Pt.Y);
  Result := True;
end;

{ --- TGranularView --- }

constructor TGranularView.Create(APlugin: TGranularVst3);
begin
  inherited Create;
  FPlugin := APlugin;
  FKeep := IEditController(APlugin);
  APlugin.FView := Self;
end;

destructor TGranularView.Destroy;
begin
  if FPlugin <> nil then
  begin
    FPlugin.CloseEditor;
    FPlugin.FView := nil;
    FPlugin.FViewIntf := nil;
  end;
  FKeep := nil;
  inherited;
end;

function TGranularView.isPlatformTypeSupported(platformType: PAnsiChar): TResult;
begin
  if (platformType <> nil) and (AnsiString(platformType) = 'HWND') then
    Result := kResultTrue
  else
    Result := kResultFalse;
end;

function TGranularView.attached(parent: Pointer; platformType: PAnsiChar): TResult;
begin
  try
    FPlugin.OpenEditor(HWND(parent));
    Result := kResultOk;
  except
    Result := kResultFalse;
  end;
end;

function TGranularView.removed: TResult;
begin
  FPlugin.CloseEditor;
  Result := kResultOk;
end;

function TGranularView.onWheel(distance: Single): TResult;
begin
  Result := kResultFalse;
end;

function TGranularView.onKeyDown(key: WideChar; keyCode: Int16; modifiers: Int16): TResult;
begin
  Result := kResultFalse;
end;

function TGranularView.onKeyUp(key: WideChar; keyCode: Int16; modifiers: Int16): TResult;
begin
  Result := kResultFalse;
end;

function TGranularView.getSize(size: PViewRect): TResult;
begin
  if size = nil then
    Exit(kInvalidArgument);
  size.left := 0;
  size.top := 0;
  FPlugin.UpdateEditSize;
  size.right := FPlugin.FEditW;
  size.bottom := FPlugin.FEditH;
  Result := kResultOk;
end;

function TGranularView.onSize(newSize: PViewRect): TResult;
begin
  Result := kResultOk;
end;

function TGranularView.onFocus(state: TBool): TResult;
begin
  Result := kResultOk;
end;

function TGranularView.setFrame(frame: Pointer): TResult;
begin
  FFrame := frame;
  Result := kResultOk;
end;

function TGranularView.canResize: TResult;
begin
  Result := kResultFalse;
end;

function TGranularView.checkSizeConstraint(rect: PViewRect): TResult;
begin
  if rect <> nil then
  begin
    FPlugin.UpdateEditSize;
    rect.right := rect.left + FPlugin.FEditW;
    rect.bottom := rect.top + FPlugin.FEditH;
  end;
  Result := kResultOk;
end;

{ --- TMenuTarget --- }

constructor TMenuTarget.Create(const AAction: TProc);
begin
  inherited Create;
  FAction := AAction;
end;

function TMenuTarget.executeMenuItem(tag: Int32): TResult;
begin
  if (tag = TAG_OWN_MENU) and Assigned(FAction) then
    try
      FAction();
    except
    end;
  Result := kResultOk;
end;

{ --- Fabrik --- }

function TGranularFactory.getFactoryInfo(info: PFactoryInfo): TResult;
begin
  if info = nil then
    Exit(kInvalidArgument);
  FillChar(info^, SizeOf(info^), 0);
  StrToChar8(VENDOR, @info.vendor[0], Length(info.vendor));
  info.flags := 0;
  Result := kResultOk;
end;

function TGranularFactory.countClasses: Int32;
begin
  Result := 2;
end;

function TGranularFactory.getClassInfo(index: Int32; info: PClassInfo): TResult;
begin
  if (info = nil) or (index < 0) or (index > 1) then
    Exit(kInvalidArgument);
  FillChar(info^, SizeOf(info^), 0);
  if index = 0 then info.cid := CID_SYNTH else info.cid := CID_FX;
  info.cardinality := kManyInstances;
  StrToChar8(kVstAudioEffectClass, @info.category[0], Length(info.category));
  if index = 0 then
    StrToChar8('GranularSynth', @info.name[0], Length(info.name))
  else
    StrToChar8('GranularSynth FX', @info.name[0], Length(info.name));
  Result := kResultOk;
end;

function TGranularFactory.getClassInfo2(index: Int32; info: PClassInfo2): TResult;
begin
  if (info = nil) or (index < 0) or (index > 1) then
    Exit(kInvalidArgument);
  FillChar(info^, SizeOf(info^), 0);
  if index = 0 then info.cid := CID_SYNTH else info.cid := CID_FX;
  info.cardinality := kManyInstances;
  StrToChar8(kVstAudioEffectClass, @info.category[0], Length(info.category));
  if index = 0 then
  begin
    StrToChar8('GranularSynth', @info.name[0], Length(info.name));
    StrToChar8('Instrument|Synth', @info.subCategories[0], Length(info.subCategories));
  end
  else
  begin
    StrToChar8('GranularSynth FX', @info.name[0], Length(info.name));
    StrToChar8('Fx', @info.subCategories[0], Length(info.subCategories));
  end;
  StrToChar8(VENDOR, @info.vendor[0], Length(info.vendor));
  StrToChar8(AnsiString(APP_VERSION), @info.version[0], Length(info.version));
  StrToChar8(SDK_VERSION, @info.sdkVersion[0], Length(info.sdkVersion));
  Result := kResultOk;
end;

function TGranularFactory.createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult;
var
  P: TGranularVst3;
  IsFx: Boolean;
  Want: TGUID;
  F: TFpuState;
begin
  obj := nil;
  Result := kNoInterface;
  if (cid = nil) or (iid = nil) then
    Exit(kInvalidArgument);
  if CompareMem(cid, @CID_SYNTH, 16) then
    IsFx := False
  else if CompareMem(cid, @CID_FX, 16) then
    IsFx := True
  else
    Exit(kResultFalse);
  Move(iid^, Want, 16);
  F := EnterFpu;
  try
    try
      P := TGranularVst3.Create(IsFx);
      if P.GetInterface(Want, obj) then
        Result := kResultOk
      else
      begin
        P.Free;
        Result := kNoInterface;
      end;
    except
      obj := nil;
      Result := kResultFalse;
    end;
  finally
    LeaveFpu(F);
  end;
end;

var
  GFactory: IPluginFactory2;

function GetPluginFactory: Pointer; stdcall;
begin
  try
    if GFactory = nil then
      GFactory := TGranularFactory.Create;
    GFactory._AddRef;            // die DAW gibt die Fabrik mit release wieder frei
    Result := Pointer(GFactory);
  except
    Result := nil;
  end;
end;

function InitDll: Boolean; stdcall;
begin
  Result := True;
end;

function ExitDll: Boolean; stdcall;
begin
  Result := True;
end;

end.
