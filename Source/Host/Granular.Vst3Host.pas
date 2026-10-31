{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Vst3Host;

{ VST3-Plugins im Test-Host: laedt eine .vst3-Datei (oder einen .vst3-Bundle-Ordner), nimmt die erste
  Klasse "Audio Module Class" und betreibt sie wie eine DAW:
    - Komponente + Controller: beide in einem Objekt (wie GranularSynth) oder getrennt; getrennte
      werden ueber IConnectionPoint verbunden und mit dem Komponenten-Zustand abgeglichen
    - Noten als Ereignisliste, Controller/Pitchbend/Aftertouch ueber IMidiMapping als Parameteraenderung
    - Reglerbewegungen im Plugin-Fenster (IComponentHandler.performEdit) gehen im naechsten Block
      als Parameteraenderung an den Prozessor
    - Tempo/Position ueber ProcessContext, Fenster per IPlugView (HWND) mit Groessenwunsch (IPlugFrame)
    - Zustand: Komponente + Controller in einer Datei
  Threading wie TVstHostPlugin: Process im Audio-Thread, alles andere im GUI-Thread; der Aufrufer
  sorgt dafuer, dass Process und Unload nicht gleichzeitig laufen. Im Audio-Thread wird nichts angelegt. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.SyncObjs,
  Granular.Vst3;

type
  TVst3SizeEvent = procedure(Sender: TObject; Width, Height: Integer) of object;

  IConnectionPoint = interface(IUnknown)
    ['{70A4156F-6E6E-4026-9891-48BFAA60D8D1}']
    function connect(other: Pointer): TResult; stdcall;
    function disconnect(other: Pointer): TResult; stdcall;
    function notify(message: Pointer): TResult; stdcall;
  end;

  IHostApplication = interface(IUnknown)
    ['{58E595CC-DB2D-4969-8B6A-AF8C36A664E5}']
    function getName(name: PWideChar): TResult; stdcall;
    function createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult; stdcall;
  end;

  TVst3HostPlugin = class;

  { Host-Objekte, die das Plugin ueber Schnittstellen aufruft }
  THostApp = class(TInterfacedObject, IHostApplication)
    function getName(name: PWideChar): TResult; stdcall;
    function createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult; stdcall;
  end;

  THostHandler = class(TInterfacedObject, IComponentHandler)
    FOwner: TVst3HostPlugin;
    function beginEdit(id: TParamID): TResult; stdcall;
    function performEdit(id: TParamID; valueNormalized: TParamValue): TResult; stdcall;
    function endEdit(id: TParamID): TResult; stdcall;
    function restartComponent(flags: Int32): TResult; stdcall;
  end;

  THostFrame = class(TInterfacedObject, IPlugFrame)
    FOwner: TVst3HostPlugin;
    function resizeView(view: Pointer; newSize: PViewRect): TResult; stdcall;
  end;

  THostEvents = class(TInterfacedObject, IEventList)
    FEv: array[0..511] of TVst3Event;
    FCount: Integer;
    function getEventCount: Int32; stdcall;
    function getEvent(index: Int32; var e: TVst3Event): TResult; stdcall;
    function addEvent(var e: TVst3Event): TResult; stdcall;
  end;

  THostQueue = class(TInterfacedObject, IParamValueQueue)
    FId: TParamID;
    FCount: Integer;
    FOfs: array[0..15] of Int32;
    FVal: array[0..15] of TParamValue;
    function getParameterId: TParamID; stdcall;
    function getPointCount: Int32; stdcall;
    function getPoint(index: Int32; out sampleOffset: Int32; out value: TParamValue): TResult; stdcall;
    function addPoint(sampleOffset: Int32; value: TParamValue; out index: Int32): TResult; stdcall;
  end;

  THostChanges = class(TInterfacedObject, IParameterChanges)
    FQ: array[0..63] of THostQueue;
    FQI: array[0..63] of IParamValueQueue;    // haelt die Warteschlangen am Leben
    FCount: Integer;
    constructor Create;
    procedure Clear;
    procedure Add(Id: TParamID; Offset: Integer; Value: TParamValue);
    function getParameterCount: Int32; stdcall;
    function getParameterData(index: Int32): Pointer; stdcall;
    function addParameterData(const id: TParamID; out index: Int32): Pointer; stdcall;
  end;

  THostStream = class(TInterfacedObject, IBStream)
    FData: TBytes;
    FPos: Integer;
    function read(buffer: Pointer; numBytes: Int32; numBytesRead: PInteger): TResult; stdcall;
    function write(buffer: Pointer; numBytes: Int32; numBytesWritten: PInteger): TResult; stdcall;
    function seek(pos: Int64; mode: Int32; newPos: PInt64): TResult; stdcall;
    function tell(pos: PInt64): TResult; stdcall;
  end;

  TVst3HostPlugin = class
  private
    FLib: HMODULE;
    FFac: IPluginFactory;
    FComp: IComponent;
    FProc: IAudioProcessor;
    FCtrl: IEditController;
    FSeparate: Boolean;
    FCompCP, FCtrlCP: IConnectionPoint;
    FMidiMap: IMidiMapping;
    FView: IPlugView;
    FHostApp: IHostApplication;
    FHandler: THostHandler;
    FHandlerI: IComponentHandler;
    FFrame: THostFrame;
    FFrameI: IPlugFrame;
    FEvents: THostEvents;
    FEventsI: IEventList;
    FChanges: THostChanges;
    FChangesI: IParameterChanges;
    FOutChanges: THostChanges;
    FOutChangesI: IParameterChanges;
    FName, FVendor, FPath: string;
    FCid: TGUID;
    FIsSynth: Boolean;
    FSampleRate: Double;
    FBlock: Integer;
    FTempo: Double;
    FSamplePos: Int64;
    FActive: Boolean;
    FOnSizeRequest: TVst3SizeEvent;
    // Busse: Kanalzeiger je Bus (Eingang 0 = Host-Eingang/Sidechain, Rest Stille; Ausgang 0 = Host-Ausgang)
    FInBus, FOutBus: array of TAudioBusBuffers;
    FInPtr, FOutPtr: array of array of System.PSingle;
    FZero: array of Single;
    FScratch: array of array of Single;
    FCtx: TProcessContext;
    // Reglerbewegungen aus dem Plugin-Fenster -> naechster Block
    FEditLock: TCriticalSection;
    FEditId: array[0..255] of TParamID;
    FEditVal: array[0..255] of TParamValue;
    FEditCount: Integer;
    FMidiIds: array[0..129] of TParamID;   // Controller -> Parameter (IMidiMapping), $FFFFFFFF = keiner
    procedure SetupBuses;
    procedure QueueEdit(Id: TParamID; Value: TParamValue);
    function MidiParam(Ctrl: Integer; out Id: TParamID): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load(const Path: string; SampleRate: Double; BlockSize: Integer);
    procedure Unload;
    { Audio-Thread }
    procedure AddMidi(Status, Data1, Data2: Byte; Delta: Integer);
    procedure Process(InL, InR, OutL, OutR: System.PSingle; Frames: Integer);
    { GUI-Thread }
    function OpenEditor(ParentWnd: HWND; out Width, Height: Integer): Boolean;
    procedure CloseEditor;
    function SaveState: TBytes;
    function LoadState(const Data: TBytes): Boolean;
    function UniqueId: Integer;
    property Tempo: Double read FTempo write FTempo;
    property Name: string read FName;
    property Vendor: string read FVendor;
    property Path: string read FPath;
    property IsSynth: Boolean read FIsSynth;
    property OnSizeRequest: TVst3SizeEvent read FOnSizeRequest write FOnSizeRequest;
  end;

{ True fuer eine .vst3-Datei oder einen .vst3-Bundle-Ordner }
function IsVst3Path(const Path: string): Boolean;

implementation

const
  STATE3_MAGIC: array[0..3] of AnsiChar = ('H', 'V', '3', 'S');
  NO_PARAM = $FFFFFFFF;
  MAX_CH = 16;

function IsVst3Path(const Path: string): Boolean;
begin
  Result := SameText(ExtractFileExt(ExcludeTrailingPathDelimiter(Path)), '.vst3');
end;

{ Bundle-Ordner: Contents\x86_64-win\Name.vst3 bzw. Contents\x86-win\Name.vst3 }
function ResolveBinary(const Path: string): string;
var
  Base: string;
begin
  Result := Path;
  if not DirectoryExists(Path) then
    Exit;
  Base := ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(Path)), '.vst3');
  {$IFDEF WIN64}
  Result := IncludeTrailingPathDelimiter(Path) + 'Contents\x86_64-win\' + Base;
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(Path) + 'Contents\x86-win\' + Base;
  {$ENDIF}
end;

{ --- Host-Objekte --- }

function THostApp.getName(name: PWideChar): TResult;
begin
  StrToString128('GranularHost', name);
  Result := kResultOk;
end;

function THostApp.createInstance(cid, iid: PAnsiChar; out obj: Pointer): TResult;
begin
  obj := nil;                 // IMessage/IAttributeList bietet der Test-Host nicht an
  Result := kNotImplemented;
end;

function THostHandler.beginEdit(id: TParamID): TResult;
begin
  Result := kResultOk;
end;

function THostHandler.performEdit(id: TParamID; valueNormalized: TParamValue): TResult;
begin
  FOwner.QueueEdit(id, valueNormalized);
  Result := kResultOk;
end;

function THostHandler.endEdit(id: TParamID): TResult;
begin
  Result := kResultOk;
end;

function THostHandler.restartComponent(flags: Int32): TResult;
begin
  Result := kResultOk;
end;

function THostFrame.resizeView(view: Pointer; newSize: PViewRect): TResult;
begin
  Result := kInvalidArgument;
  if (newSize = nil) or (FOwner.FView = nil) then
    Exit;
  if Assigned(FOwner.FOnSizeRequest) then
    FOwner.FOnSizeRequest(FOwner, newSize.right - newSize.left, newSize.bottom - newSize.top);
  FOwner.FView.onSize(newSize);
  Result := kResultOk;
end;

function THostEvents.getEventCount: Int32;
begin
  Result := FCount;
end;

function THostEvents.getEvent(index: Int32; var e: TVst3Event): TResult;
begin
  if (index < 0) or (index >= FCount) then
    Exit(kInvalidArgument);
  e := FEv[index];
  Result := kResultOk;
end;

function THostEvents.addEvent(var e: TVst3Event): TResult;
begin
  Result := kResultFalse;      // Ausgabe-Ereignisse werden nicht gebraucht
end;

function THostQueue.getParameterId: TParamID;
begin
  Result := FId;
end;

function THostQueue.getPointCount: Int32;
begin
  Result := FCount;
end;

function THostQueue.getPoint(index: Int32; out sampleOffset: Int32; out value: TParamValue): TResult;
begin
  if (index < 0) or (index >= FCount) then
    Exit(kInvalidArgument);
  sampleOffset := FOfs[index];
  value := FVal[index];
  Result := kResultOk;
end;

function THostQueue.addPoint(sampleOffset: Int32; value: TParamValue; out index: Int32): TResult;
begin
  // gleicher Zeitpunkt -> Wert ersetzen (letzte Bewegung zaehlt)
  if (FCount > 0) and (FOfs[FCount - 1] >= sampleOffset) then
  begin
    FVal[FCount - 1] := value;
    index := FCount - 1;
    Exit(kResultOk);
  end;
  if FCount > High(FOfs) then
    Exit(kResultFalse);
  FOfs[FCount] := sampleOffset;
  FVal[FCount] := value;
  index := FCount;
  Inc(FCount);
  Result := kResultOk;
end;

constructor THostChanges.Create;
var
  I: Integer;
begin
  inherited Create;
  for I := 0 to High(FQ) do
  begin
    FQ[I] := THostQueue.Create;
    FQI[I] := FQ[I];
  end;
end;

procedure THostChanges.Clear;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    FQ[I].FCount := 0;
  FCount := 0;
end;

procedure THostChanges.Add(Id: TParamID; Offset: Integer; Value: TParamValue);
var
  I, Dummy: Integer;
begin
  for I := 0 to FCount - 1 do
    if FQ[I].FId = Id then
    begin
      FQ[I].addPoint(Offset, Value, Dummy);
      Exit;
    end;
  if FCount > High(FQ) then
    Exit;
  FQ[FCount].FId := Id;
  FQ[FCount].FCount := 0;
  FQ[FCount].addPoint(Offset, Value, Dummy);
  Inc(FCount);
end;

function THostChanges.getParameterCount: Int32;
begin
  Result := FCount;
end;

function THostChanges.getParameterData(index: Int32): Pointer;
begin
  if (index < 0) or (index >= FCount) then
    Exit(nil);
  Result := Pointer(FQI[index]);
end;

function THostChanges.addParameterData(const id: TParamID; out index: Int32): Pointer;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if FQ[I].FId = id then
    begin
      index := I;
      Exit(Pointer(FQI[I]));
    end;
  if FCount > High(FQ) then
  begin
    index := -1;
    Exit(nil);
  end;
  FQ[FCount].FId := id;
  FQ[FCount].FCount := 0;
  index := FCount;
  Result := Pointer(FQI[FCount]);
  Inc(FCount);
end;

function THostStream.read(buffer: Pointer; numBytes: Int32; numBytesRead: PInteger): TResult;
var
  N: Integer;
begin
  N := Max(0, Min(numBytes, Length(FData) - FPos));
  if N > 0 then
    Move(FData[FPos], buffer^, N);
  Inc(FPos, N);
  if numBytesRead <> nil then
    numBytesRead^ := N;
  Result := kResultOk;
end;

function THostStream.write(buffer: Pointer; numBytes: Int32; numBytesWritten: PInteger): TResult;
begin
  if numBytes > 0 then
  begin
    if FPos + numBytes > Length(FData) then
      SetLength(FData, FPos + numBytes);
    Move(buffer^, FData[FPos], numBytes);
    Inc(FPos, numBytes);
  end;
  if numBytesWritten <> nil then
    numBytesWritten^ := Max(0, numBytes);
  Result := kResultOk;
end;

function THostStream.seek(pos: Int64; mode: Int32; newPos: PInt64): TResult;
begin
  case mode of
    kIBSeekSet: FPos := pos;
    kIBSeekCur: FPos := FPos + pos;
    kIBSeekEnd: FPos := Length(FData) + pos;
  end;
  FPos := EnsureRange(FPos, 0, Length(FData));
  if newPos <> nil then
    newPos^ := FPos;
  Result := kResultOk;
end;

function THostStream.tell(pos: PInt64): TResult;
begin
  if pos <> nil then
    pos^ := FPos;
  Result := kResultOk;
end;

{ --- TVst3HostPlugin --- }

constructor TVst3HostPlugin.Create;
begin
  inherited Create;
  FEditLock := TCriticalSection.Create;
  FTempo := 120;
  FHostApp := THostApp.Create;
  FHandler := THostHandler.Create;
  FHandler.FOwner := Self;
  FHandlerI := FHandler;
  FFrame := THostFrame.Create;
  FFrame.FOwner := Self;
  FFrameI := FFrame;
  FEvents := THostEvents.Create;
  FEventsI := FEvents;
  FChanges := THostChanges.Create;
  FChangesI := FChanges;
  FOutChanges := THostChanges.Create;
  FOutChangesI := FOutChanges;
end;

destructor TVst3HostPlugin.Destroy;
begin
  Unload;
  FEditLock.Free;
  inherited;
end;

procedure TVst3HostPlugin.QueueEdit(Id: TParamID; Value: TParamValue);
var
  I: Integer;
begin
  FEditLock.Enter;
  try
    for I := 0 to FEditCount - 1 do
      if FEditId[I] = Id then
      begin
        FEditVal[I] := Value;
        Exit;
      end;
    if FEditCount <= High(FEditId) then
    begin
      FEditId[FEditCount] := Id;
      FEditVal[FEditCount] := Value;
      Inc(FEditCount);
    end;
  finally
    FEditLock.Leave;
  end;
end;

procedure TVst3HostPlugin.Load(const Path: string; SampleRate: Double; BlockSize: Integer);
type
  TGetFactory = function: Pointer; stdcall;
  TInitDll = function: Boolean; stdcall;
var
  Bin: string;
  GetF: TGetFactory;
  InitF: TInitDll;
  Fac2: IPluginFactory2;
  Ci: TClassInfo;
  Ci2: TClassInfo2;
  FI: TFactoryInfo;
  I, Found: Integer;
  Obj: Pointer;
  IID: TGUID;
  CtrlCid: TGUID;
  St: THostStream;
  StI: IBStream;
  Setup: TProcessSetup;
  Ctrl: Integer;
  Id: TParamID;
begin
  Unload;
  FSampleRate := SampleRate;
  FBlock := Max(16, BlockSize);
  Bin := ResolveBinary(Path);
  FLib := LoadLibrary(PChar(Bin));
  if FLib = 0 then
    raise Exception.CreateFmt('VST3-Datei konnte nicht geladen werden (Fehler %d).' + sLineBreak +
      'Hinweis: 32-Bit-Plugins nur im 32-Bit-Host, 64-Bit-Plugins nur im 64-Bit-Host.', [GetLastError]);
  try
    @InitF := GetProcAddress(FLib, 'InitDll');
    if Assigned(InitF) then
      InitF;
    @GetF := GetProcAddress(FLib, 'GetPluginFactory');
    if not Assigned(GetF) then
      raise Exception.Create('Keine VST3-Datei (GetPluginFactory fehlt).');
    Pointer(FFac) := GetF;                       // Referenz gehoert uns
    if FFac = nil then
      raise Exception.Create('Das Plugin liefert keine Fabrik.');
    // erste Audio-Klasse suchen
    Found := -1;
    for I := 0 to FFac.countClasses - 1 do
      if (FFac.getClassInfo(I, @Ci) = kResultOk) and (AnsiString(Ci.category) = kVstAudioEffectClass) then
      begin
        Found := I;
        Break;
      end;
    if Found < 0 then
      raise Exception.Create('Das Plugin enthaelt keine Audio-Klasse.');
    FCid := Ci.cid;
    FName := string(AnsiString(Ci.name));
    FIsSynth := False;
    if Supports(FFac, IPluginFactory2, Fac2) and (Fac2.getClassInfo2(Found, @Ci2) = kResultOk) then
    begin
      FIsSynth := Pos('Instrument', string(AnsiString(Ci2.subCategories))) > 0;
      FVendor := string(AnsiString(Ci2.vendor));
    end;
    if (FVendor = '') and (FFac.getFactoryInfo(@FI) = kResultOk) then
      FVendor := string(AnsiString(FI.vendor));
    if FName = '' then
      FName := ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(Path)), '');

    IID := IComponent;
    if (FFac.createInstance(@FCid, @IID, Obj) <> kResultOk) or (Obj = nil) then
      raise Exception.Create('Das Plugin konnte nicht angelegt werden.');
    Pointer(FComp) := Obj;
    if FComp.initialize(Pointer(FHostApp)) <> kResultOk then
      raise Exception.Create('Das Plugin hat sich nicht initialisiert.');
    if not Supports(FComp, IAudioProcessor, FProc) then
      raise Exception.Create('Das Plugin hat keinen Audio-Prozessor.');
    // Controller: im selben Objekt oder eigene Klasse
    if not Supports(FComp, IEditController, FCtrl) then
    begin
      if FComp.getControllerClassId(@CtrlCid) = kResultOk then
      begin
        IID := IEditController;
        if (FFac.createInstance(@CtrlCid, @IID, Obj) = kResultOk) and (Obj <> nil) then
        begin
          Pointer(FCtrl) := Obj;
          FSeparate := True;
          if FCtrl.initialize(Pointer(FHostApp)) <> kResultOk then
            FCtrl := nil;
        end;
      end;
      if FSeparate and (FCtrl <> nil) then
      begin
        if Supports(FComp, IConnectionPoint, FCompCP) and Supports(FCtrl, IConnectionPoint, FCtrlCP) then
        begin
          FCompCP.connect(Pointer(FCtrlCP));
          FCtrlCP.connect(Pointer(FCompCP));
        end;
        // Controller mit dem Zustand der Komponente abgleichen
        St := THostStream.Create;
        StI := St;
        if FComp.getState(Pointer(StI)) = kResultOk then
        begin
          St.FPos := 0;
          FCtrl.setComponentState(Pointer(StI));
        end;
      end;
    end;
    if FCtrl <> nil then
    begin
      FCtrl.setComponentHandler(Pointer(FHandlerI));
      Supports(FCtrl, IMidiMapping, FMidiMap);
    end;
    for Ctrl := 0 to High(FMidiIds) do
    begin
      FMidiIds[Ctrl] := NO_PARAM;
      if (FMidiMap <> nil) and (FMidiMap.getMidiControllerAssignment(0, 0, Ctrl, Id) = kResultOk) then
        FMidiIds[Ctrl] := Id;
    end;

    SetupBuses;
    FillChar(Setup, SizeOf(Setup), 0);
    Setup.processMode := kRealtime;
    Setup.symbolicSampleSize := kSample32;
    Setup.maxSamplesPerBlock := FBlock;
    Setup.sampleRate := FSampleRate;
    if FProc.setupProcessing(Setup) <> kResultOk then
      raise Exception.Create('Das Plugin unterstuetzt diese Einstellungen nicht (32 Bit Float).');
    FComp.setActive(1);
    FProc.setProcessing(1);
    FActive := True;
    FPath := Path;
    FSamplePos := 0;
  except
    Unload;
    raise;
  end;
end;

procedure TVst3HostPlugin.SetupBuses;
var
  NI, NO, B, C, K, Total: Integer;
  BI: TBusInfo;
begin
  NI := FComp.getBusCount(kAudio, kInput);
  NO := FComp.getBusCount(kAudio, kOutput);
  SetLength(FZero, FBlock);
  SetLength(FInBus, NI);
  SetLength(FInPtr, NI);
  SetLength(FOutBus, NO);
  SetLength(FOutPtr, NO);
  Total := 0;
  for B := 0 to NO - 1 do
  begin
    C := 2;
    if FComp.getBusInfo(kAudio, kOutput, B, BI) = kResultOk then
      C := EnsureRange(BI.channelCount, 0, MAX_CH);
    SetLength(FOutPtr[B], Max(1, C));
    FOutBus[B].numChannels := C;
    FOutBus[B].silenceFlags := 0;
    FOutBus[B].channelBuffers32 := @FOutPtr[B][0];
    Inc(Total, C);
    FComp.activateBus(kAudio, kOutput, B, 1);
  end;
  SetLength(FScratch, Total);
  for K := 0 to Total - 1 do
    SetLength(FScratch[K], FBlock);
  K := 0;
  for B := 0 to NO - 1 do
    for C := 0 to FOutBus[B].numChannels - 1 do
    begin
      FOutPtr[B][C] := @FScratch[K][0];
      Inc(K);
    end;
  for B := 0 to NI - 1 do
  begin
    C := 2;
    if FComp.getBusInfo(kAudio, kInput, B, BI) = kResultOk then
      C := EnsureRange(BI.channelCount, 0, MAX_CH);
    SetLength(FInPtr[B], Max(1, C));
    for K := 0 to High(FInPtr[B]) do
      FInPtr[B][K] := @FZero[0];
    FInBus[B].numChannels := C;
    FInBus[B].silenceFlags := 0;
    FInBus[B].channelBuffers32 := @FInPtr[B][0];
    FComp.activateBus(kAudio, kInput, B, 1);
  end;
  if FComp.getBusCount(kEvent, kInput) > 0 then
    FComp.activateBus(kEvent, kInput, 0, 1);
end;

procedure TVst3HostPlugin.Unload;
type
  TExitDll = function: Boolean; stdcall;
var
  ExitF: TExitDll;
begin
  CloseEditor;
  try
    if FActive then
    begin
      FProc.setProcessing(0);
      FComp.setActive(0);
      FActive := False;
    end;
    if (FCompCP <> nil) and (FCtrlCP <> nil) then
    begin
      FCompCP.disconnect(Pointer(FCtrlCP));
      FCtrlCP.disconnect(Pointer(FCompCP));
    end;
    FCompCP := nil;
    FCtrlCP := nil;
    FMidiMap := nil;
    if FCtrl <> nil then
    begin
      FCtrl.setComponentHandler(nil);
      if FSeparate then
        FCtrl.terminate;
    end;
    FCtrl := nil;
    FProc := nil;
    if FComp <> nil then
      FComp.terminate;
    FComp := nil;
    FFac := nil;
  except
    // fehlerhaftes Plugin darf den Host nicht mitreissen
  end;
  FSeparate := False;
  if FLib <> 0 then
  begin
    try
      @ExitF := GetProcAddress(FLib, 'ExitDll');
      if Assigned(ExitF) then
        ExitF;
    except
    end;
    FreeLibrary(FLib);
    FLib := 0;
  end;
  FName := '';
  FVendor := '';
  FPath := '';
  FEvents.FCount := 0;
  FEditCount := 0;
end;

function TVst3HostPlugin.MidiParam(Ctrl: Integer; out Id: TParamID): Boolean;
begin
  Id := FMidiIds[Ctrl];
  Result := Id <> NO_PARAM;
end;

procedure TVst3HostPlugin.AddMidi(Status, Data1, Data2: Byte; Delta: Integer);
var
  E: PVst3Event;
  Id: TParamID;
begin
  if FComp = nil then
    Exit;
  case Status and $F0 of
    $80, $90:
      begin
        if FEvents.FCount > High(FEvents.FEv) then
          Exit;
        E := @FEvents.FEv[FEvents.FCount];
        FillChar(E^, SizeOf(TVst3Event), 0);
        E.sampleOffset := Delta;
        if ((Status and $F0) = $90) and (Data2 > 0) then
        begin
          E.eventType := kNoteOnEvent;
          E.onChannel := Status and $0F;
          E.onPitch := Data1;
          E.onVelocity := Data2 / 127;
          E.onNoteId := -1;
        end
        else
        begin
          E.eventType := kNoteOffEvent;
          E.offChannel := Status and $0F;
          E.offPitch := Data1;
          E.offVelocity := Data2 / 127;
          E.offNoteId := -1;
        end;
        Inc(FEvents.FCount);
      end;
    $B0:
      if MidiParam(Data1, Id) then
        FChanges.Add(Id, Delta, Data2 / 127);
    $D0:
      if MidiParam(kAfterTouch, Id) then
        FChanges.Add(Id, Delta, Data1 / 127);
    $E0:
      if MidiParam(kPitchBend, Id) then
        FChanges.Add(Id, Delta, (Data1 or (Data2 shl 7)) / 16383);
  end;
end;

procedure TVst3HostPlugin.Process(InL, InR, OutL, OutR: System.PSingle; Frames: Integer);
var
  Data: TProcessData;
  I, NOut: Integer;
begin
  if (FProc = nil) or (Frames <= 0) then
  begin
    if Frames > 0 then
    begin
      FillChar(OutL^, Frames * SizeOf(Single), 0);
      FillChar(OutR^, Frames * SizeOf(Single), 0);
    end;
    Exit;
  end;
  Frames := Min(Frames, FBlock);
  // Reglerbewegungen aus dem Fenster (nicht warten, wenn das Fenster gerade schreibt)
  if FEditLock.TryEnter then
  try
    for I := 0 to FEditCount - 1 do
      FChanges.Add(FEditId[I], 0, FEditVal[I]);
    FEditCount := 0;
  finally
    FEditLock.Leave;
  end;
  // Eingang 0: Host-Eingang (Sidechain), sonst Stille
  if Length(FInBus) > 0 then
  begin
    if (InL <> nil) and (FInBus[0].numChannels >= 1) then FInPtr[0][0] := InL;
    if (InR <> nil) and (FInBus[0].numChannels >= 2) then FInPtr[0][1] := InR;
  end;
  FillChar(FCtx, SizeOf(FCtx), 0);
  FCtx.state := kPlaying or kTempoValid;
  FCtx.sampleRate := FSampleRate;
  FCtx.projectTimeSamples := FSamplePos;
  FCtx.continousTimeSamples := FSamplePos;
  FCtx.tempo := FTempo;
  FCtx.projectTimeMusic := FSamplePos / FSampleRate * FTempo / 60;
  FCtx.timeSigNumerator := 4;
  FCtx.timeSigDenominator := 4;
  FOutChanges.Clear;
  FillChar(Data, SizeOf(Data), 0);
  Data.processMode := kRealtime;
  Data.symbolicSampleSize := kSample32;
  Data.numSamples := Frames;
  Data.numInputs := Length(FInBus);
  Data.numOutputs := Length(FOutBus);
  if Data.numInputs > 0 then Data.inputs := @FInBus[0];
  if Data.numOutputs > 0 then Data.outputs := @FOutBus[0];
  Data.inputParameterChanges := Pointer(FChangesI);
  Data.outputParameterChanges := Pointer(FOutChangesI);
  Data.inputEvents := Pointer(FEventsI);
  Data.processContext := @FCtx;
  try
    FProc.process(Data);
  except
    // Fehler im Plugin: Stille statt Absturz des Hosts
  end;
  FEvents.FCount := 0;
  FChanges.Clear;
  if Length(FInBus) > 0 then
  begin
    FInPtr[0][0] := @FZero[0];
    if Length(FInPtr[0]) > 1 then FInPtr[0][1] := @FZero[0];
  end;
  // Ausgang 0 in die Host-Puffer
  NOut := 0;
  if Length(FOutBus) > 0 then
    NOut := FOutBus[0].numChannels;
  if NOut >= 1 then
    Move(FOutPtr[0][0]^, OutL^, Frames * SizeOf(Single))
  else
    FillChar(OutL^, Frames * SizeOf(Single), 0);
  if NOut >= 2 then
    Move(FOutPtr[0][1]^, OutR^, Frames * SizeOf(Single))
  else
    Move(OutL^, OutR^, Frames * SizeOf(Single));
  Inc(FSamplePos, Frames);
end;

function TVst3HostPlugin.OpenEditor(ParentWnd: HWND; out Width, Height: Integer): Boolean;
var
  R: TViewRect;
begin
  Result := False;
  Width := 0;
  Height := 0;
  if FCtrl = nil then
    Exit;
  Pointer(FView) := FCtrl.createView('editor');     // Referenz gehoert uns
  if FView = nil then
    Exit;
  if FView.isPlatformTypeSupported('HWND') <> kResultTrue then
  begin
    FView := nil;
    Exit;
  end;
  FView.setFrame(Pointer(FFrameI));
  if FView.attached(Pointer(ParentWnd), 'HWND') <> kResultOk then
  begin
    FView.setFrame(nil);
    FView := nil;
    Exit;
  end;
  FillChar(R, SizeOf(R), 0);
  if FView.getSize(@R) = kResultOk then
  begin
    Width := R.right - R.left;
    Height := R.bottom - R.top;
  end;
  Result := True;
end;

procedure TVst3HostPlugin.CloseEditor;
begin
  if FView = nil then
    Exit;
  try
    FView.removed;
    FView.setFrame(nil);
  except
  end;
  FView := nil;
end;

{ Zustand: 'HV3S', Int32 Laenge + Komponenten-Zustand, Int32 Laenge + Controller-Zustand }
function TVst3HostPlugin.SaveState: TBytes;
var
  S: TBytesStream;
  Part: THostStream;
  PartI: IBStream;
  N, K: Integer;
begin
  Result := nil;
  if FComp = nil then
    Exit;
  S := TBytesStream.Create;
  try
    S.WriteBuffer(STATE3_MAGIC, 4);
    for K := 0 to 1 do
    begin
      Part := THostStream.Create;
      PartI := Part;
      if K = 0 then
        FComp.getState(Pointer(PartI))
      else if FSeparate and (FCtrl <> nil) then
        FCtrl.getState(Pointer(PartI));
      N := Length(Part.FData);
      S.WriteBuffer(N, 4);
      if N > 0 then
        S.WriteBuffer(Part.FData[0], N);
    end;
    Result := Copy(S.Bytes, 0, S.Size);
  finally
    S.Free;
  end;
end;

function TVst3HostPlugin.LoadState(const Data: TBytes): Boolean;
var
  P, N, K: Integer;
  Part: array[0..1] of TBytes;
  St: THostStream;
  StI: IBStream;
begin
  Result := False;
  if (FComp = nil) or (Length(Data) < 12) or not CompareMem(@Data[0], @STATE3_MAGIC[0], 4) then
    Exit;
  P := 4;
  for K := 0 to 1 do
  begin
    if P + 4 > Length(Data) then Exit;
    Move(Data[P], N, 4);
    Inc(P, 4);
    if (N < 0) or (P + N > Length(Data)) then Exit;
    Part[K] := Copy(Data, P, N);
    Inc(P, N);
  end;
  if Length(Part[0]) > 0 then
  begin
    St := THostStream.Create;
    StI := St;
    St.FData := Part[0];
    FComp.setState(Pointer(StI));
    if FSeparate and (FCtrl <> nil) then
    begin
      St.FPos := 0;
      FCtrl.setComponentState(Pointer(StI));
    end;
  end;
  if FSeparate and (FCtrl <> nil) and (Length(Part[1]) > 0) then
  begin
    St := THostStream.Create;
    StI := St;
    St.FData := Part[1];
    FCtrl.setState(Pointer(StI));
  end;
  Result := True;
end;

function TVst3HostPlugin.UniqueId: Integer;
begin
  Result := Integer(FCid.D1) xor (Integer(FCid.D2) shl 16) xor Integer(FCid.D3);
end;

end.
