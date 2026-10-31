{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Vst2;

{ Eigene Deklaration der VST-2.4-Binaerschnittstelle (Plugin- und Host-Seite).
  Nach der oeffentlich dokumentierten ABI geschrieben, ohne Steinberg-SDK-Quelltext.
  Aufrufkonvention cdecl, Strukturen mit C-Ausrichtung - gilt fuer Win32 und Win64. }

interface

{$ALIGN 8}
{$MINENUMSIZE 4}

const
  kEffectMagic = $56737450;   // 'VstP'

  // Plugin-Opcodes (Host -> Plugin)
  effOpen = 0;               effClose = 1;
  effSetProgram = 2;         effGetProgram = 3;
  effSetProgramName = 4;     effGetProgramName = 5;
  effGetParamLabel = 6;      effGetParamDisplay = 7;      effGetParamName = 8;
  effSetSampleRate = 10;     effSetBlockSize = 11;        effMainsChanged = 12;
  effEditGetRect = 13;       effEditOpen = 14;            effEditClose = 15;
  effEditIdle = 19;
  effGetChunk = 23;          effSetChunk = 24;
  effProcessEvents = 25;     effCanBeAutomated = 26;
  effGetProgramNameIndexed = 29;
  effGetInputProperties = 33; effGetOutputProperties = 34;
  effGetPlugCategory = 35;
  effGetEffectName = 45;     effGetVendorString = 47;
  effGetProductString = 48;  effGetVendorVersion = 49;
  effCanDo = 51;             effGetVstVersion = 58;
  effStartProcess = 71;      effStopProcess = 72;

  // Host-Opcodes (Plugin -> Host)
  audioMasterAutomate = 0;          audioMasterVersion = 1;
  audioMasterCurrentId = 2;         audioMasterIdle = 3;
  audioMasterGetTime = 7;           audioMasterProcessEvents = 8;
  audioMasterIOChanged = 13;        audioMasterSizeWindow = 15;
  audioMasterGetSampleRate = 16;    audioMasterGetBlockSize = 17;
  audioMasterGetCurrentProcessLevel = 23;
  audioMasterGetVendorString = 32;  audioMasterGetProductString = 33;
  audioMasterGetVendorVersion = 34; audioMasterCanDo = 37;
  audioMasterGetLanguage = 38;      audioMasterUpdateDisplay = 42;
  audioMasterBeginEdit = 43;        audioMasterEndEdit = 44;

  // Flags
  effFlagsHasEditor = 1;
  effFlagsCanReplacing = 16;
  effFlagsProgramChunks = 32;
  effFlagsIsSynth = 256;
  effFlagsNoSoundInStop = 512;

  kPlugCategEffect = 1;
  kPlugCategSynth = 2;
  kVstMidiType = 1;

  // VstTimeInfo.flags
  kVstTransportPlaying = 2;
  kVstPpqPosValid = 512;
  kVstTempoValid = 1024;
  kVstTimeSigValid = 8192;

  kVstMaxParamStrLen = 8;     // laut Spezifikation; die meisten Hosts erlauben mehr
  kVstMaxNameLen = 64;

  // VstPinProperties.flags
  kVstPinIsActive = 1;
  kVstPinIsStereo = 2;

type
  PAEffect = ^TAEffect;
  PPSingle = ^PSingle;

  TAudioMasterCallback = function(Effect: PAEffect; Opcode, Index: Int32;
    Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt; cdecl;
  TDispatcherProc = function(Effect: PAEffect; Opcode, Index: Int32;
    Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt; cdecl;
  TProcessProc = procedure(Effect: PAEffect; Inputs, Outputs: PPSingle; SampleFrames: Int32); cdecl;
  TProcessDoubleProc = procedure(Effect: PAEffect; Inputs, Outputs: Pointer; SampleFrames: Int32); cdecl;
  TSetParameterProc = procedure(Effect: PAEffect; Index: Int32; Parameter: Single); cdecl;
  TGetParameterProc = function(Effect: PAEffect; Index: Int32): Single; cdecl;
  TVstPluginMain = function(AudioMaster: TAudioMasterCallback): PAEffect; cdecl;

  { Beschreibung eines Ein-/Ausgangs (effGetInputProperties / effGetOutputProperties) }
  PVstPinProperties = ^TVstPinProperties;
  TVstPinProperties = record
    Label_: array[0..63] of AnsiChar;
    Flags: Int32;
    ArrangementType: Int32;
    ShortLabel: array[0..7] of AnsiChar;
    Future: array[0..47] of Byte;
  end;

  TAEffect = record
    Magic: Int32;
    Dispatcher: TDispatcherProc;
    Process: TProcessProc;                 // veraltet (akkumulierend)
    SetParameter: TSetParameterProc;
    GetParameter: TGetParameterProc;
    NumPrograms: Int32;
    NumParams: Int32;
    NumInputs: Int32;
    NumOutputs: Int32;
    Flags: Int32;
    Resvd1: NativeInt;                     // fuer den Host reserviert
    Resvd2: NativeInt;
    InitialDelay: Int32;
    RealQualities: Int32;
    OffQualities: Int32;
    IoRatio: Single;
    Obj: Pointer;                          // fuer das Plugin (Zeiger auf eigenes Objekt)
    User: Pointer;
    UniqueID: Int32;
    Version: Int32;
    ProcessReplacing: TProcessProc;
    ProcessDoubleReplacing: TProcessDoubleProc;
    Future: array[0..55] of Byte;
  end;

  PERect = ^TERect;
  TERect = record
    Top, Left, Bottom, Right: SmallInt;
  end;

  PVstMidiEvent = ^TVstMidiEvent;
  TVstMidiEvent = record
    EventType: Int32;        // kVstMidiType
    ByteSize: Int32;         // SizeOf(TVstMidiEvent) = 32
    DeltaFrames: Int32;
    Flags: Int32;
    NoteLength: Int32;
    NoteOffset: Int32;
    MidiData: array[0..3] of Byte;
    Detune: ShortInt;
    NoteOffVelocity: Byte;
    Reserved1: Byte;
    Reserved2: Byte;
  end;

  PVstEvents = ^TVstEvents;
  TVstEvents = record
    NumEvents: Int32;
    Reserved: NativeInt;
    Events: array[0..1] of PVstMidiEvent;  // tatsaechlich NumEvents Eintraege
  end;

  PVstTimeInfo = ^TVstTimeInfo;
  TVstTimeInfo = record
    SamplePos: Double;
    SampleRate: Double;
    NanoSeconds: Double;
    PpqPos: Double;
    Tempo: Double;
    BarStartPos: Double;
    CycleStartPos: Double;
    CycleEndPos: Double;
    TimeSigNumerator: Int32;
    TimeSigDenominator: Int32;
    SmpteOffset: Int32;
    SmpteFrameRate: Int32;
    SamplesToNextClock: Int32;
    Flags: Int32;
  end;

{ String sicher in einen vom Host bereitgestellten Puffer kopieren }
procedure VstStrCopy(Dest: Pointer; const Value: string; MaxLen: Integer);
function VstFourCC(const S: AnsiString): Int32;

implementation

procedure VstStrCopy(Dest: Pointer; const Value: string; MaxLen: Integer);
var
  A: AnsiString;
  N: Integer;
begin
  if Dest = nil then
    Exit;
  A := AnsiString(Value);
  N := Length(A);
  if N > MaxLen - 1 then
    N := MaxLen - 1;
  if N > 0 then
    Move(A[1], Dest^, N);
  PAnsiChar(Dest)[N] := #0;
end;

function VstFourCC(const S: AnsiString): Int32;
begin
  Result := (Ord(S[1]) shl 24) or (Ord(S[2]) shl 16) or (Ord(S[3]) shl 8) or Ord(S[4]);
end;

end.
