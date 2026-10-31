{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Vst3;

{ VST3-Schnittstellen (nur der Teil, den GranularSynth braucht), von Hand nach den Steinberg-Headern
  (github.com/steinbergmedia/vst3_pluginterfaces) uebertragen. Reihenfolge der Methoden = Reihenfolge im
  C++-Header (Vtable!), IIDs aus DECLARE_CLASS_IID in COM-Schreibweise (Windows: COM_COMPATIBLE).
  Aufrufkonvention PLUGIN_API = stdcall. Strukturen mit natuerlicher Ausrichtung wie in C++ (kein packed). }

interface

type
  TResult = HRESULT;
  TParamID = Cardinal;
  TParamValue = Double;
  TBool = Byte;
  TString128 = array[0..127] of WideChar;
  PString128 = ^TString128;
  TSpeakerArrangement = UInt64;
  PSpeakerArrangement = ^TSpeakerArrangement;

const
  kResultOk = 0;
  kResultTrue = 0;
  kResultFalse = 1;
  kInvalidArgument = HRESULT($80070057);
  kNotImplemented = HRESULT($80004001);
  kNoInterface = HRESULT($80004002);

  // Medien/Busse
  kAudio = 0;
  kEvent = 1;
  kInput = 0;
  kOutput = 1;
  kMain = 0;
  kAux = 1;
  kDefaultActive = 1;
  kSpeakerStereo: TSpeakerArrangement = 3;   // kSpeakerL | kSpeakerR

  // Verarbeitung
  kRealtime = 0;
  kPrefetch = 1;
  kOffline = 2;
  kSample32 = 0;
  kSample64 = 1;
  kNoTail = 0;
  kInfiniteTail = $FFFFFFFF;

  // ProcessContext.state
  kPlaying = 1 shl 1;
  kTempoValid = 1 shl 10;

  // Parameter
  kCanAutomate = 1 shl 0;
  kIsReadOnly = 1 shl 1;
  kIsList = 1 shl 3;
  kIsHidden = 1 shl 4;
  kRootUnitId = 0;

  // restartComponent
  kParamValuesChanged = 1 shl 2;

  // Ereignisse
  kNoteOnEvent = 0;
  kNoteOffEvent = 1;

  // MIDI-Controller (IMidiMapping)
  kCtrlModWheel = 1;
  kCtrlSustainOnOff = 64;
  kAfterTouch = 128;
  kPitchBend = 129;
  kCountCtrlNumber = 130;

  // Kontextmenue
  kIsSeparator = 1 shl 0;
  kIsDisabled = 1 shl 1;
  kIsChecked = 1 shl 2;

  // Fabrik
  kManyInstances = $7FFFFFFF;
  kUnicodeFactory = 1 shl 4;
  kVstAudioEffectClass = 'Audio Module Class';

  // IBStream.seek
  kIBSeekSet = 0;
  kIBSeekCur = 1;
  kIBSeekEnd = 2;

type
  PFactoryInfo = ^TFactoryInfo;
  TFactoryInfo = record
    vendor: array[0..63] of AnsiChar;
    url: array[0..255] of AnsiChar;
    email: array[0..127] of AnsiChar;
    flags: Int32;
  end;

  PClassInfo = ^TClassInfo;
  TClassInfo = record
    cid: TGUID;
    cardinality: Int32;
    category: array[0..31] of AnsiChar;
    name: array[0..63] of AnsiChar;
  end;

  PClassInfo2 = ^TClassInfo2;
  TClassInfo2 = record
    cid: TGUID;
    cardinality: Int32;
    category: array[0..31] of AnsiChar;
    name: array[0..63] of AnsiChar;
    classFlags: UInt32;
    subCategories: array[0..127] of AnsiChar;
    vendor: array[0..63] of AnsiChar;
    version: array[0..63] of AnsiChar;
    sdkVersion: array[0..63] of AnsiChar;
  end;

  TBusInfo = record
    mediaType: Int32;
    direction: Int32;
    channelCount: Int32;
    name: TString128;
    busType: Int32;
    flags: UInt32;
  end;

  TRoutingInfo = record
    mediaType: Int32;
    busIndex: Int32;
    channel: Int32;
  end;

  TProcessSetup = record
    processMode: Int32;
    symbolicSampleSize: Int32;
    maxSamplesPerBlock: Int32;
    sampleRate: Double;
  end;

  PPSingleArr = ^PSingle;
  PAudioBusBuffers = ^TAudioBusBuffers;
  TAudioBusBuffers = record
    numChannels: Int32;
    silenceFlags: UInt64;
    channelBuffers32: PPSingleArr;   // Union mit channelBuffers64 (nur 32 Bit unterstuetzt)
  end;

  PProcessContext = ^TProcessContext;
  TProcessContext = record
    state: UInt32;
    sampleRate: Double;
    projectTimeSamples: Int64;
    systemTime: Int64;
    continousTimeSamples: Int64;
    projectTimeMusic: Double;
    barPositionMusic: Double;
    cycleStartMusic: Double;
    cycleEndMusic: Double;
    tempo: Double;
    timeSigNumerator: Int32;
    timeSigDenominator: Int32;
    chord: UInt32;               // Chord: keyNote, rootNote (uint8), chordMask (int16)
    smpteOffsetSubframes: Int32;
    frameRateFps: UInt32;
    frameRateFlags: UInt32;
    samplesToNextClock: Int32;
  end;

  { Event: Kopf + Union (NoteOn/NoteOff ...). Die Union ist in C++ bis 24 Byte gross (x64);
    hier grosszuegig 40 Byte, der Host schreibt hoechstens sizeof(Event) }
  PVst3Event = ^TVst3Event;
  TVst3Event = record
    busIndex: Int32;
    sampleOffset: Int32;
    ppqPosition: Double;
    flags: Word;
    eventType: Word;
    case Integer of
      0: (onChannel, onPitch: Int16; onTuning, onVelocity: Single; onLength, onNoteId: Int32);
      1: (offChannel, offPitch: Int16; offVelocity: Single; offNoteId: Int32; offTuning: Single);
      2: (raw: array[0..39] of Byte);
  end;

  TViewRect = record
    left, top, right, bottom: Int32;
  end;
  PViewRect = ^TViewRect;

  TContextMenuItem = record
    name: TString128;
    tag: Int32;
    flags: Int32;
  end;

  TParameterInfo = record
    id: TParamID;
    title: TString128;
    shortTitle: TString128;
    units: TString128;
    stepCount: Int32;
    defaultNormalizedValue: TParamValue;
    unitId: Int32;
    flags: Int32;
  end;

  IBStream = interface(IUnknown)
    ['{C3BF6EA2-3099-4752-9B6B-F9901EE33E9B}']
    function read(buffer: Pointer; numBytes: Int32; numBytesRead: PInteger): TResult; stdcall;
    function write(buffer: Pointer; numBytes: Int32; numBytesWritten: PInteger): TResult; stdcall;
    function seek(pos: Int64; mode: Int32; newPos: PInt64): TResult; stdcall;
    function tell(pos: PInt64): TResult; stdcall;
  end;

  IParamValueQueue = interface(IUnknown)
    ['{01263A18-ED07-4F6F-98C9-D3564686F9BA}']
    function getParameterId: TParamID; stdcall;
    function getPointCount: Int32; stdcall;
    function getPoint(index: Int32; out sampleOffset: Int32; out value: TParamValue): TResult; stdcall;
    function addPoint(sampleOffset: Int32; value: TParamValue; out index: Int32): TResult; stdcall;
  end;

  IParameterChanges = interface(IUnknown)
    ['{A4779663-0BB6-4A56-B443-84A8466FEB9D}']
    function getParameterCount: Int32; stdcall;
    function getParameterData(index: Int32): Pointer; stdcall;          // IParamValueQueue* (geliehen)
    function addParameterData(const id: TParamID; out index: Int32): Pointer; stdcall;
  end;

  IEventList = interface(IUnknown)
    ['{3A2C4214-3463-49FE-B2C4-F397B9695A44}']
    function getEventCount: Int32; stdcall;
    function getEvent(index: Int32; var e: TVst3Event): TResult; stdcall;
    function addEvent(var e: TVst3Event): TResult; stdcall;
  end;

  PProcessData = ^TProcessData;
  TProcessData = record
    processMode: Int32;
    symbolicSampleSize: Int32;
    numSamples: Int32;
    numInputs: Int32;
    numOutputs: Int32;
    inputs: PAudioBusBuffers;
    outputs: PAudioBusBuffers;
    inputParameterChanges: Pointer;    // IParameterChanges*
    outputParameterChanges: Pointer;
    inputEvents: Pointer;              // IEventList*
    outputEvents: Pointer;
    processContext: PProcessContext;
  end;

  IPluginBase = interface(IUnknown)
    ['{22888DDB-156E-45AE-8358-B34808190625}']
    function initialize(context: Pointer): TResult; stdcall;
    function terminate: TResult; stdcall;
  end;

  IPluginFactory = interface(IUnknown)
    ['{7A4D811C-5211-4A1F-AED9-D2EE0B43BF9F}']
    function getFactoryInfo(info: PFactoryInfo): TResult; stdcall;
    function countClasses: Int32; stdcall;
    function getClassInfo(index: Int32; info: PClassInfo): TResult; stdcall;
    function createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult; stdcall;
  end;

  IPluginFactory2 = interface(IPluginFactory)
    ['{0007B650-F24B-4C0B-A464-EDB9F00B2ABB}']
    function getClassInfo2(index: Int32; info: PClassInfo2): TResult; stdcall;
  end;

  IComponent = interface(IPluginBase)
    ['{E831FF31-F2D5-4301-928E-BBEE25697802}']
    function getControllerClassId(classId: PGUID): TResult; stdcall;
    function setIoMode(mode: Int32): TResult; stdcall;
    function getBusCount(mediaType, dir: Int32): Int32; stdcall;
    function getBusInfo(mediaType, dir, index: Int32; var bus: TBusInfo): TResult; stdcall;
    function getRoutingInfo(var inInfo, outInfo: TRoutingInfo): TResult; stdcall;
    function activateBus(mediaType, dir, index: Int32; state: TBool): TResult; stdcall;
    function setActive(state: TBool): TResult; stdcall;
    function setState(state: Pointer): TResult; stdcall;     // IBStream*
    function getState(state: Pointer): TResult; stdcall;
  end;

  IAudioProcessor = interface(IUnknown)
    ['{42043F99-B7DA-453C-A569-E79D9AAEC33D}']
    function setBusArrangements(inputs: PSpeakerArrangement; numIns: Int32; outputs: PSpeakerArrangement;
      numOuts: Int32): TResult; stdcall;
    function getBusArrangement(dir, index: Int32; var arr: TSpeakerArrangement): TResult; stdcall;
    function canProcessSampleSize(symbolicSampleSize: Int32): TResult; stdcall;
    function getLatencySamples: UInt32; stdcall;
    function setupProcessing(var setup: TProcessSetup): TResult; stdcall;
    function setProcessing(state: TBool): TResult; stdcall;
    function process(var data: TProcessData): TResult; stdcall;
    function getTailSamples: UInt32; stdcall;
  end;

  IComponentHandler = interface(IUnknown)
    ['{93A0BEA3-0BD0-45DB-8E89-0B0CC1E46AC6}']
    function beginEdit(id: TParamID): TResult; stdcall;
    function performEdit(id: TParamID; valueNormalized: TParamValue): TResult; stdcall;
    function endEdit(id: TParamID): TResult; stdcall;
    function restartComponent(flags: Int32): TResult; stdcall;
  end;

  IContextMenuTarget = interface(IUnknown)
    ['{3CDF2E75-85D3-4144-BF86-D36BD7C4894D}']
    function executeMenuItem(tag: Int32): TResult; stdcall;
  end;

  IContextMenu = interface(IUnknown)
    ['{2E93C863-0C9C-4588-97DB-ECF5AD17817D}']
    function getItemCount: Int32; stdcall;
    function getItem(index: Int32; var item: TContextMenuItem; target: PPointer): TResult; stdcall;
    function addItem(const item: TContextMenuItem; target: IContextMenuTarget): TResult; stdcall;
    function removeItem(const item: TContextMenuItem; target: IContextMenuTarget): TResult; stdcall;
    function popup(x, y: Int32): TResult; stdcall;
  end;

  IComponentHandler3 = interface(IUnknown)
    ['{69F11617-D26B-400D-A4B6-B9647B6EBBAB}']
    function createContextMenu(plugView: Pointer; paramID: PCardinal): Pointer; stdcall;   // IContextMenu* (gehoert uns)
  end;

  IEditController = interface(IPluginBase)
    ['{DCD7BBE3-7742-448D-A874-AACC979C759E}']
    function setComponentState(state: Pointer): TResult; stdcall;
    function setState(state: Pointer): TResult; stdcall;
    function getState(state: Pointer): TResult; stdcall;
    function getParameterCount: Int32; stdcall;
    function getParameterInfo(paramIndex: Int32; var info: TParameterInfo): TResult; stdcall;
    function getParamStringByValue(id: TParamID; valueNormalized: TParamValue; str: PWideChar): TResult; stdcall;
    function getParamValueByString(id: TParamID; str: PWideChar; out valueNormalized: TParamValue): TResult; stdcall;
    function normalizedParamToPlain(id: TParamID; valueNormalized: TParamValue): TParamValue; stdcall;
    function plainParamToNormalized(id: TParamID; plainValue: TParamValue): TParamValue; stdcall;
    function getParamNormalized(id: TParamID): TParamValue; stdcall;
    function setParamNormalized(id: TParamID; value: TParamValue): TResult; stdcall;
    function setComponentHandler(handler: Pointer): TResult; stdcall;   // IComponentHandler*
    function createView(name: PAnsiChar): Pointer; stdcall;              // IPlugView* (gehoert dem Host)
  end;

  IMidiMapping = interface(IUnknown)
    ['{DF0FF9F7-49B7-4669-B63A-B7327ADBF5E5}']
    function getMidiControllerAssignment(busIndex: Int32; channel: Int16; midiControllerNumber: Int16;
      out id: TParamID): TResult; stdcall;
  end;

  IPlugFrame = interface(IUnknown)
    ['{367FAF01-AFA9-4693-8D4D-A2A0ED0882A3}']
    function resizeView(view: Pointer; newSize: PViewRect): TResult; stdcall;
  end;

  IPlugView = interface(IUnknown)
    ['{5BC32507-D060-49EA-A615-1B522B755B29}']
    function isPlatformTypeSupported(platformType: PAnsiChar): TResult; stdcall;
    function attached(parent: Pointer; platformType: PAnsiChar): TResult; stdcall;
    function removed: TResult; stdcall;
    function onWheel(distance: Single): TResult; stdcall;
    function onKeyDown(key: WideChar; keyCode: Int16; modifiers: Int16): TResult; stdcall;
    function onKeyUp(key: WideChar; keyCode: Int16; modifiers: Int16): TResult; stdcall;
    function getSize(size: PViewRect): TResult; stdcall;
    function onSize(newSize: PViewRect): TResult; stdcall;
    function onFocus(state: TBool): TResult; stdcall;
    function setFrame(frame: Pointer): TResult; stdcall;    // IPlugFrame*
    function canResize: TResult; stdcall;
    function checkSizeConstraint(rect: PViewRect): TResult; stdcall;
  end;


{ String in ein String128-Feld (UTF-16, mit Null abgeschlossen) bzw. in ein char8-Feld }
procedure StrToString128(const S: string; Dest: PWideChar);
procedure StrToChar8(const S: AnsiString; Dest: PAnsiChar; Size: Integer);

implementation

uses
  System.SysUtils, System.Math;

procedure StrToString128(const S: string; Dest: PWideChar);
var
  N: Integer;
begin
  N := Min(Length(S), 127);
  if N > 0 then
    Move(PChar(S)^, Dest^, N * SizeOf(WideChar));
  Dest[N] := #0;
end;

procedure StrToChar8(const S: AnsiString; Dest: PAnsiChar; Size: Integer);
var
  N: Integer;
begin
  FillChar(Dest^, Size, 0);
  N := Min(Length(S), Size - 1);
  if N > 0 then
    Move(PAnsiChar(S)^, Dest^, N);
end;

end.
