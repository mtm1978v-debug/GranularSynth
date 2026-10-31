{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.VstHost;

{ Minimaler, robuster VST2-Host fuer ein Plugin:
    - laedt eine beliebige VST2-DLL (passende Bitbreite!), Einsprung VSTPluginMain/main
    - MIDI-Noten samplegenau (effProcessEvents vor jedem Block)
    - Zeitinfo (Tempo, Position) fuer Tempo-Sync der Plugins
    - Editor im Host-Fenster, Groessenwunsch des Plugins wird gemeldet
    - Zustand sichern/laden: Chunk, falls das Plugin Chunks kann, sonst alle Parameter
  Threading: Process laeuft im Audio-Thread, alles andere im GUI-Thread. Der Aufrufer
  stellt sicher, dass Process und Unload nicht gleichzeitig laufen (Lock im Host).
  VST3 (.vst3-Datei oder Bundle-Ordner): alle Aufrufe gehen an TVst3HostPlugin (Granular.Vst3Host);
  Dispatch liefert dann 0 (VST2-Opcodes gibt es dort nicht). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math,
  Granular.Vst2, Granular.Vst3Host;

const
  HOST_MAX_BLOCK = 4096;
  HOST_MAX_EVENTS = 512;
  HOST_MAX_CHANNELS = 16;

type
  EVstHostError = class(Exception);

  TPluginSizeEvent = procedure(Sender: TObject; Width, Height: Integer) of object;

  TVstHostPlugin = class
  private
    FLib: HMODULE;
    FEffect: PAEffect;
    FPath, FName, FVendor: string;
    FSampleRate: Double;
    FBlockSize: Integer;
    FTimeInfo: TVstTimeInfo;
    FSamplePos: Double;
    FTempo: Double;
    FEditorOpen: Boolean;
    FOnSizeRequest: TPluginSizeEvent;
    // MIDI fuer den naechsten Block (nur Audio-Thread)
    FMidi: array[0..HOST_MAX_EVENTS - 1] of TVstMidiEvent;
    FMidiPtrs: array[0..HOST_MAX_EVENTS + 1] of Pointer;   // TVstEvents-Kopf + Zeiger
    FMidiCount: Integer;
    // Kanalpuffer
    FZero: array of Single;
    FScratch: array of array of Single;
    FIns, FOuts: array[0..HOST_MAX_CHANNELS - 1] of System.PSingle;
    FV3: TVst3HostPlugin;                  // geladenes VST3-Plugin (sonst nil)
    procedure V3Size(Sender: TObject; Width, Height: Integer);
    function GetFlag(Mask: Integer): Boolean;
    function GetUniqueId: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load(const Path: string; SampleRate: Double; BlockSize: Integer);
    procedure Unload;
    function Dispatch(Opcode, Index: Int32; Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt; reintroduce;

    { Audio-Thread }
    procedure AddMidi(Status, Data1, Data2: Byte; Delta: Integer);
    procedure Process(InL, InR, OutL, OutR: System.PSingle; Frames: Integer);
    property Tempo: Double read FTempo write FTempo;

    { GUI-Thread }
    function OpenEditor(ParentWnd: HWND; out Width, Height: Integer): Boolean;
    procedure CloseEditor;
    procedure Idle;
    function SaveState: TBytes;
    function LoadState(const Data: TBytes): Boolean;
    function StateFileName(const Dir: string): string;

    property Loaded: Boolean index 0 read GetFlag;
    property HasEditor: Boolean index effFlagsHasEditor read GetFlag;
    property IsSynth: Boolean index effFlagsIsSynth read GetFlag;
    property Effect: PAEffect read FEffect;
    function IsVst3: Boolean;
    property Name: string read FName;
    property Vendor: string read FVendor;
    property Path: string read FPath;
    property UniqueId: Integer read GetUniqueId;
    property SampleRate: Double read FSampleRate;
    property OnSizeRequest: TPluginSizeEvent read FOnSizeRequest write FOnSizeRequest;
  end;

implementation

{$POINTERMATH ON}

const
  STATE_MAGIC: array[0..3] of AnsiChar = ('H', 'S', 'T', 'S');
  STATE_CHUNK = 1;
  STATE_PARAMS = 2;

threadvar
  GLoading: TVstHostPlugin;   // waehrend VSTPluginMain ist Effect noch unbekannt

function HostOf(Effect: PAEffect): TVstHostPlugin;
begin
  if (Effect <> nil) and (Effect.Resvd1 <> 0) then
    Result := TVstHostPlugin(Effect.Resvd1)
  else
    Result := GLoading;
end;

function HostCallback(Effect: PAEffect; Opcode, Index: Int32; Value: NativeInt;
  Ptr: Pointer; Opt: Single): NativeInt; cdecl;
var
  H: TVstHostPlugin;
  S: AnsiString;
begin
  Result := 0;
  try
    H := HostOf(Effect);
    case Opcode of
      audioMasterVersion:
        Result := 2400;
      audioMasterCurrentId:
        if (H <> nil) and (H.FEffect <> nil) then
          Result := H.FEffect.UniqueID;
      audioMasterIdle, audioMasterUpdateDisplay, audioMasterIOChanged,
      audioMasterAutomate, audioMasterBeginEdit, audioMasterEndEdit:
        Result := 1;
      audioMasterGetTime:
        if H <> nil then
        begin
          H.FTimeInfo.SampleRate := H.FSampleRate;
          H.FTimeInfo.SamplePos := H.FSamplePos;
          H.FTimeInfo.Tempo := H.FTempo;
          H.FTimeInfo.PpqPos := H.FSamplePos / Max(H.FSampleRate, 1.0) * H.FTempo / 60;
          H.FTimeInfo.BarStartPos := Floor(H.FTimeInfo.PpqPos / 4) * 4;
          H.FTimeInfo.TimeSigNumerator := 4;
          H.FTimeInfo.TimeSigDenominator := 4;
          H.FTimeInfo.Flags := kVstTransportPlaying or kVstTempoValid or kVstPpqPosValid or kVstTimeSigValid;
          Result := NativeInt(@H.FTimeInfo);
        end;
      audioMasterGetSampleRate:
        if H <> nil then
          Result := Round(H.FSampleRate);
      audioMasterGetBlockSize:
        if H <> nil then
          Result := H.FBlockSize;
      audioMasterSizeWindow:
        if (H <> nil) and Assigned(H.FOnSizeRequest) then
        begin
          H.FOnSizeRequest(H, Index, Value);
          Result := 1;
        end;
      audioMasterGetCurrentProcessLevel:
        Result := 0;
      audioMasterGetVendorString:
        begin
          VstStrCopy(Ptr, 'privat', kVstMaxNameLen);
          Result := 1;
        end;
      audioMasterGetProductString:
        begin
          VstStrCopy(Ptr, 'GranularHost', kVstMaxNameLen);
          Result := 1;
        end;
      audioMasterGetVendorVersion:
        Result := 1000;
      audioMasterGetLanguage:
        Result := 1;
      audioMasterCanDo:
        begin
          S := AnsiString(PAnsiChar(Ptr));
          if (S = 'sendVstEvents') or (S = 'sendVstMidiEvent') or (S = 'sendVstTimeInfo') or
             (S = 'sizeWindow') or (S = 'supplyIdle') then
            Result := 1;
        end;
    end;
  except
    Result := 0;
  end;
end;

{ TVstHostPlugin }

constructor TVstHostPlugin.Create;
var
  I: Integer;
begin
  inherited;
  FTempo := 120;
  SetLength(FZero, HOST_MAX_BLOCK);
  SetLength(FScratch, HOST_MAX_CHANNELS);
  for I := 0 to HOST_MAX_CHANNELS - 1 do
    SetLength(FScratch[I], HOST_MAX_BLOCK);
end;

destructor TVstHostPlugin.Destroy;
begin
  Unload;
  inherited;
end;

function TVstHostPlugin.IsVst3: Boolean;
begin
  Result := FV3 <> nil;
end;

procedure TVstHostPlugin.V3Size(Sender: TObject; Width, Height: Integer);
begin
  if Assigned(FOnSizeRequest) then
    FOnSizeRequest(Self, Width, Height);
end;

function TVstHostPlugin.GetFlag(Mask: Integer): Boolean;
begin
  if FV3 <> nil then
  begin
    if Mask = effFlagsIsSynth then Exit(FV3.IsSynth);
    Exit(True);                          // geladen, Fenster: OpenEditor entscheidet
  end;
  if Mask = 0 then
    Result := FEffect <> nil
  else
    Result := (FEffect <> nil) and ((FEffect.Flags and Mask) <> 0);
end;

function TVstHostPlugin.GetUniqueId: Integer;
begin
  if FV3 <> nil then Exit(FV3.UniqueId);
  if FEffect <> nil then Result := FEffect.UniqueID else Result := 0;
end;

function TVstHostPlugin.Dispatch(Opcode, Index: Int32; Value: NativeInt; Ptr: Pointer; Opt: Single): NativeInt;
begin
  if (FEffect = nil) or (FV3 <> nil) then
    Exit(0);
  Result := FEffect.Dispatcher(FEffect, Opcode, Index, Value, Ptr, Opt);
end;

procedure TVstHostPlugin.Load(const Path: string; SampleRate: Double; BlockSize: Integer);
var
  Main: TVstPluginMain;
  Buf: array[0..255] of AnsiChar;
begin
  Unload;
  FSampleRate := SampleRate;
  FBlockSize := Min(BlockSize, HOST_MAX_BLOCK);
  if IsVst3Path(Path) then
  begin
    FV3 := TVst3HostPlugin.Create;
    FV3.OnSizeRequest := V3Size;
    try
      FV3.Load(Path, SampleRate, HOST_MAX_BLOCK);
    except
      FreeAndNil(FV3);
      raise;
    end;
    FPath := Path;
    FName := FV3.Name;
    FVendor := FV3.Vendor;
    Exit;
  end;
  FLib := LoadLibrary(PChar(Path));
  if FLib = 0 then
    raise EVstHostError.CreateFmt('DLL konnte nicht geladen werden (Fehler %d).' + sLineBreak +
      'Hinweis: 32-Bit-Plugins nur im 32-Bit-Host, 64-Bit-Plugins nur im 64-Bit-Host.', [GetLastError]);
  try
    @Main := GetProcAddress(FLib, 'VSTPluginMain');
    if not Assigned(Main) then
      @Main := GetProcAddress(FLib, 'main');
    if not Assigned(Main) then
      raise EVstHostError.Create('Keine VST2-DLL (VSTPluginMain/main fehlt).');
    GLoading := Self;
    try
      FEffect := Main(HostCallback);
    finally
      GLoading := nil;
    end;
    if (FEffect = nil) or (FEffect.Magic <> kEffectMagic) then
    begin
      FEffect := nil;
      raise EVstHostError.Create('Das Plugin hat sich nicht initialisiert (kein gültiges AEffect).');
    end;
    if (FEffect.NumInputs > HOST_MAX_CHANNELS) or (FEffect.NumOutputs > HOST_MAX_CHANNELS) then
    begin
      FEffect := nil;
      raise EVstHostError.Create('Zu viele Ein-/Ausgänge für diesen Host.');
    end;
    FEffect.Resvd1 := NativeInt(Self);
    FPath := Path;

    Dispatch(effOpen, 0, 0, nil, 0);
    Dispatch(effSetSampleRate, 0, 0, nil, FSampleRate);
    Dispatch(effSetBlockSize, 0, FBlockSize, nil, 0);

    FillChar(Buf, SizeOf(Buf), 0);
    Dispatch(effGetEffectName, 0, 0, @Buf, 0);
    FName := string(PAnsiChar(@Buf));
    if FName = '' then
    begin
      FillChar(Buf, SizeOf(Buf), 0);
      Dispatch(effGetProductString, 0, 0, @Buf, 0);
      FName := string(PAnsiChar(@Buf));
    end;
    if FName = '' then
      FName := ChangeFileExt(ExtractFileName(Path), '');
    FillChar(Buf, SizeOf(Buf), 0);
    Dispatch(effGetVendorString, 0, 0, @Buf, 0);
    FVendor := string(PAnsiChar(@Buf));

    Dispatch(effMainsChanged, 0, 1, nil, 0);
    Dispatch(effStartProcess, 0, 0, nil, 0);
  except
    if FEffect <> nil then
    begin
      Dispatch(effClose, 0, 0, nil, 0);
      FEffect := nil;
    end;
    FreeLibrary(FLib);
    FLib := 0;
    raise;
  end;
end;

procedure TVstHostPlugin.Unload;
begin
  if FV3 <> nil then
    FreeAndNil(FV3);                     // Destruktor beendet das Plugin
  if FEffect <> nil then
  begin
    try
      CloseEditor;
      Dispatch(effStopProcess, 0, 0, nil, 0);
      Dispatch(effMainsChanged, 0, 0, nil, 0);
      Dispatch(effClose, 0, 0, nil, 0);
    except
      // fehlerhaftes Plugin darf den Host nicht mitreissen
    end;
    FEffect := nil;
  end;
  if FLib <> 0 then
  begin
    FreeLibrary(FLib);
    FLib := 0;
  end;
  FName := '';
  FVendor := '';
  FPath := '';
  FMidiCount := 0;
end;

procedure TVstHostPlugin.AddMidi(Status, Data1, Data2: Byte; Delta: Integer);
begin
  if FV3 <> nil then
  begin
    FV3.AddMidi(Status, Data1, Data2, Delta);
    Exit;
  end;
  if FMidiCount >= HOST_MAX_EVENTS then
    Exit;
  FillChar(FMidi[FMidiCount], SizeOf(TVstMidiEvent), 0);
  FMidi[FMidiCount].EventType := kVstMidiType;
  FMidi[FMidiCount].ByteSize := SizeOf(TVstMidiEvent);
  FMidi[FMidiCount].DeltaFrames := Delta;
  FMidi[FMidiCount].MidiData[0] := Status;
  FMidi[FMidiCount].MidiData[1] := Data1;
  FMidi[FMidiCount].MidiData[2] := Data2;
  Inc(FMidiCount);
end;

procedure TVstHostPlugin.Process(InL, InR, OutL, OutR: System.PSingle; Frames: Integer);
var
  I, NIn, NOut: Integer;
  Ev: PVstEvents;
begin
  if FV3 <> nil then
  begin
    FV3.Tempo := FTempo;
    FV3.Process(InL, InR, OutL, OutR, Frames);
    Exit;
  end;
  if (FEffect = nil) or (Frames <= 0) then
  begin
    FillChar(OutL^, Frames * SizeOf(Single), 0);
    FillChar(OutR^, Frames * SizeOf(Single), 0);
    Exit;
  end;
  Frames := Min(Frames, HOST_MAX_BLOCK);

  // MIDI des Blocks uebergeben (TVstEvents: NumEvents, Reserved, Zeiger...)
  if FMidiCount > 0 then
  begin
    Ev := @FMidiPtrs[0];
    Ev.NumEvents := FMidiCount;
    Ev.Reserved := 0;
    for I := 0 to FMidiCount - 1 do
      (PPointer(@Ev.Events[0]) + I)^ := @FMidi[I];
    Dispatch(effProcessEvents, 0, 0, Ev, 0);
    FMidiCount := 0;
  end;

  // Eingaenge: 1+2 = Sidechain (falls vorhanden), Rest Stille
  NIn := FEffect.NumInputs;
  for I := 0 to NIn - 1 do
    FIns[I] := @FZero[0];
  if (NIn >= 1) and (InL <> nil) then FIns[0] := InL;
  if (NIn >= 2) and (InR <> nil) then FIns[1] := InR;

  // Ausgaenge: 1+2 direkt in die Host-Puffer, weitere in Scratch
  NOut := FEffect.NumOutputs;
  for I := 0 to NOut - 1 do
    FOuts[I] := @FScratch[I][0];
  if NOut >= 1 then FOuts[0] := OutL;
  if NOut >= 2 then FOuts[1] := OutR;

  if (FEffect.Flags and effFlagsCanReplacing) <> 0 then
    FEffect.ProcessReplacing(FEffect, @FIns[0], @FOuts[0], Frames)
  else
  begin
    for I := 0 to NOut - 1 do
      FillChar(FOuts[I]^, Frames * SizeOf(Single), 0);
    FEffect.Process(FEffect, @FIns[0], @FOuts[0], Frames);
  end;

  if NOut = 1 then
    Move(OutL^, OutR^, Frames * SizeOf(Single))
  else if NOut = 0 then
  begin
    FillChar(OutL^, Frames * SizeOf(Single), 0);
    FillChar(OutR^, Frames * SizeOf(Single), 0);
  end;
  FSamplePos := FSamplePos + Frames;
end;

function TVstHostPlugin.OpenEditor(ParentWnd: HWND; out Width, Height: Integer): Boolean;
var
  R: PERect;
begin
  if FV3 <> nil then
    Exit(FV3.OpenEditor(ParentWnd, Width, Height));
  Result := False;
  Width := 0;
  Height := 0;
  if not HasEditor then
    Exit;
  R := nil;
  Dispatch(effEditGetRect, 0, 0, @R, 0);
  Dispatch(effEditOpen, 0, 0, Pointer(ParentWnd), 0);
  FEditorOpen := True;
  // manche Plugins liefern die Groesse erst nach dem Oeffnen
  R := nil;
  Dispatch(effEditGetRect, 0, 0, @R, 0);
  if R <> nil then
  begin
    Width := R.Right - R.Left;
    Height := R.Bottom - R.Top;
  end;
  Result := True;
end;

procedure TVstHostPlugin.CloseEditor;
begin
  if FV3 <> nil then
    FV3.CloseEditor;
  if FEditorOpen then
  begin
    FEditorOpen := False;
    Dispatch(effEditClose, 0, 0, nil, 0);
  end;
end;

procedure TVstHostPlugin.Idle;
begin
  if FEditorOpen then
    Dispatch(effEditIdle, 0, 0, nil, 0);
end;

function TVstHostPlugin.SaveState: TBytes;
var
  S: TBytesStream;
  Kind, Id, N, I: Integer;
  P: Pointer;
  V: Single;
begin
  if FV3 <> nil then
    Exit(FV3.SaveState);
  Result := nil;
  if FEffect = nil then
    Exit;
  S := TBytesStream.Create;
  try
    S.WriteBuffer(STATE_MAGIC, 4);
    Id := FEffect.UniqueID;
    if (FEffect.Flags and effFlagsProgramChunks) <> 0 then
    begin
      Kind := STATE_CHUNK;
      P := nil;
      N := Dispatch(effGetChunk, 0, 0, @P, 0);
      S.WriteBuffer(Kind, 4);
      S.WriteBuffer(Id, 4);
      if (P = nil) or (N < 0) then N := 0;
      S.WriteBuffer(N, 4);
      if N > 0 then
        S.WriteBuffer(P^, N);
    end
    else
    begin
      Kind := STATE_PARAMS;
      N := FEffect.NumParams;
      S.WriteBuffer(Kind, 4);
      S.WriteBuffer(Id, 4);
      S.WriteBuffer(N, 4);
      for I := 0 to N - 1 do
      begin
        V := FEffect.GetParameter(FEffect, I);
        S.WriteBuffer(V, 4);
      end;
    end;
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

function TVstHostPlugin.LoadState(const Data: TBytes): Boolean;
var
  Kind, Id, N, I: Integer;
  V: Single;
begin
  if FV3 <> nil then
    Exit(FV3.LoadState(Data));
  Result := False;
  if (FEffect = nil) or (Length(Data) < 16) or not CompareMem(@Data[0], @STATE_MAGIC[0], 4) then
    Exit;
  Move(Data[4], Kind, 4);
  Move(Data[8], Id, 4);
  Move(Data[12], N, 4);
  if (Id <> FEffect.UniqueID) or (N < 0) then
    Exit;
  case Kind of
    STATE_CHUNK:
      if 16 + N <= Length(Data) then
      begin
        Dispatch(effSetChunk, 0, N, @Data[16], 0);
        Result := True;
      end;
    STATE_PARAMS:
      if 16 + N * 4 <= Length(Data) then
      begin
        for I := 0 to Min(N, FEffect.NumParams) - 1 do
        begin
          Move(Data[16 + I * 4], V, 4);
          FEffect.SetParameter(FEffect, I, V);
        end;
        Result := True;
      end;
  end;
end;

function TVstHostPlugin.StateFileName(const Dir: string): string;
var
  Base: string;
  I: Integer;
begin
  // Name + ID: gleiche Plugins in verschiedenen Ordnern teilen sich den Zustand
  Base := FName;
  for I := 1 to Length(Base) do
    if not CharInSet(Base[I], ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Base[I] := '_';
  Result := IncludeTrailingPathDelimiter(Dir) + Format('%s_%.8x.hstate', [Base, Cardinal(GetUniqueId)]);
end;

end.
