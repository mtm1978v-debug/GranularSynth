{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.WasapiRec;

{ Aufnahme fuer den Sample-Editor ueber WASAPI (gemeinsamer Modus): jedes aktive Aufnahmegeraet und
  zusaetzlich jedes Wiedergabegeraet als Loopback ("was der PC abspielt" - kein Stereomix noetig).
  Laeuft in einem eigenen Thread (Abfrage alle 10 ms) und schreibt in vorab angelegte Puffer; die
  Oberflaeche liest nur Pegel und Laenge. Schnittstellen von Hand deklariert (kein SDK noetig). }

interface

uses
  Winapi.Windows, Winapi.MMSystem, Winapi.ActiveX, Winapi.PropSys, System.SysUtils, System.Classes, System.Math, System.Win.ComObj,
  Granular.Sample;

type
  TRecSource = record
    Name: string;
    Id: string;
    Loopback: Boolean;
  end;

  TWasapiRecorder = class(TThread)
  private
    FId: string;
    FLoopback: Boolean;
    FMaxSec: Double;
    FL, FR: TArray<Single>;
    FFrames: Integer;          // geschrieben (nur der Thread erhoeht)
    FRate: Integer;
    FPeak: Single;             // seit der letzten Abfrage
    FError: string;
    FStarted: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const Source: TRecSource; MaxSec: Double);
    { Spitzenpegel seit dem letzten Aufruf (0..1) }
    function TakePeak: Single;
    function Seconds: Double;
    { Aufnahme beenden; Ergebnis = Sample (gehoert dem Aufrufer) oder nil, Fehlertext in Error }
    function Finish: TSampleData;
    property Error: string read FError;
    property Started: Boolean read FStarted;
  end;

{ alle Quellen: Loopback des Standard-Ausgangs zuerst, dann Aufnahmegeraete, dann weitere Loopbacks }
function ListRecSources(const LoopbackPrefix: string): TArray<TRecSource>;

implementation

const
  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IAudioClient: TGUID = '{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}';
  IID_IAudioCaptureClient: TGUID = '{C8ADBD64-E71E-48A0-A4DE-185C395CD317}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';
  PKEY_Device_FriendlyName: TPropertyKey = (fmtid: '{A45C254E-DF1C-4EFD-8020-67D146A850E0}'; pid: 14);
  eRender = 0;
  eCapture = 1;
  eConsole = 0;
  DEVICE_STATE_ACTIVE = 1;
  AUDCLNT_SHAREMODE_SHARED = 0;
  AUDCLNT_STREAMFLAGS_LOOPBACK = $00020000;
  AUDCLNT_BUFFERFLAGS_SILENT = 2;
  WAVE_FORMAT_IEEE_FLOAT = 3;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

type
  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer; out ppInterface): HResult; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties: IPropertyStore): HResult; stdcall;
    function GetId(out ppstrId: PWideChar): HResult; stdcall;
    function GetState(out pdwState: DWORD): HResult; stdcall;
  end;

  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}']
    function GetCount(out pcDevices: UINT): HResult; stdcall;
    function Item(nDevice: UINT; out ppDevice: IMMDevice): HResult; stdcall;
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: Integer; dwStateMask: DWORD; out ppDevices: IMMDeviceCollection): HResult; stdcall;
    function GetDefaultAudioEndpoint(dataFlow, role: Integer; out ppEndpoint: IMMDevice): HResult; stdcall;
    function GetDevice(pwstrId: PWideChar; out ppDevice: IMMDevice): HResult; stdcall;
    function RegisterEndpointNotificationCallback(pClient: IUnknown): HResult; stdcall;
    function UnregisterEndpointNotificationCallback(pClient: IUnknown): HResult; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}']
    function Initialize(ShareMode: Integer; StreamFlags: DWORD; hnsBufferDuration, hnsPeriodicity: Int64;
      pFormat: PWaveFormatEx; AudioSessionGuid: PGUID): HResult; stdcall;
    function GetBufferSize(out pNumBufferFrames: UINT32): HResult; stdcall;
    function GetStreamLatency(out phnsLatency: Int64): HResult; stdcall;
    function GetCurrentPadding(out pNumPaddingFrames: UINT32): HResult; stdcall;
    function IsFormatSupported(ShareMode: Integer; pFormat: PWaveFormatEx; out ppClosestMatch: PWaveFormatEx): HResult; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWaveFormatEx): HResult; stdcall;
    function GetDevicePeriod(out phnsDefaultDevicePeriod, phnsMinimumDevicePeriod: Int64): HResult; stdcall;
    function Start: HResult; stdcall;
    function Stop: HResult; stdcall;
    function Reset: HResult; stdcall;
    function SetEventHandle(eventHandle: THandle): HResult; stdcall;
    function GetService(const riid: TGUID; out ppv): HResult; stdcall;
  end;

  IAudioCaptureClient = interface(IUnknown)
    ['{C8ADBD64-E71E-48A0-A4DE-185C395CD317}']
    function GetBuffer(out ppData: PByte; out pNumFramesToRead: UINT32; out pdwFlags: DWORD;
      pu64DevicePosition, pu64QPCPosition: PUInt64): HResult; stdcall;
    function ReleaseBuffer(NumFramesRead: UINT32): HResult; stdcall;
    function GetNextPacketSize(out pNumFramesInNextPacket: UINT32): HResult; stdcall;
  end;

  TWaveFormatExtensible = packed record
    Format: TWaveFormatEx;
    wValidBitsPerSample: Word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;
  PWaveFormatExtensible = ^TWaveFormatExtensible;

function DeviceName(const D: IMMDevice): string;
var
  Store: IPropertyStore;
  V: TPropVariant;
begin
  Result := '?';
  if Succeeded(D.OpenPropertyStore(STGM_READ, Store)) then
  begin
    FillChar(V, SizeOf(V), 0);
    if Succeeded(Store.GetValue(PKEY_Device_FriendlyName, V)) and (V.vt = VT_LPWSTR) then
      Result := V.pwszVal;
    PropVariantClear(V);
  end;
end;

function DeviceId(const D: IMMDevice): string;
var
  P: PWideChar;
begin
  Result := '';
  if Succeeded(D.GetId(P)) then
  begin
    Result := P;
    CoTaskMemFree(P);
  end;
end;

function ListRecSources(const LoopbackPrefix: string): TArray<TRecSource>;
var
  En: IMMDeviceEnumerator;
  Col: IMMDeviceCollection;
  D: IMMDevice;
  N, I: UINT;
  DefId: string;
  Init: HResult;

  procedure Add(const AName, AId: string; Loop: Boolean);
  var
    S: TRecSource;
  begin
    S.Name := AName;
    S.Id := AId;
    S.Loopback := Loop;
    Result := Result + [S];
  end;

begin
  Result := nil;
  Init := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    if Failed(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IMMDeviceEnumerator, En)) then
      Exit;
    DefId := '';
    if Succeeded(En.GetDefaultAudioEndpoint(eRender, eConsole, D)) then
    begin
      DefId := DeviceId(D);
      Add(LoopbackPrefix + DeviceName(D), DefId, True);
    end;
    if Succeeded(En.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, Col)) and Succeeded(Col.GetCount(N)) then
      for I := 0 to N - 1 do
        if Succeeded(Col.Item(I, D)) then
          Add(DeviceName(D), DeviceId(D), False);
    if Succeeded(En.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, Col)) and Succeeded(Col.GetCount(N)) then
      for I := 0 to N - 1 do
        if Succeeded(Col.Item(I, D)) and (DeviceId(D) <> DefId) then
          Add(LoopbackPrefix + DeviceName(D), DeviceId(D), True);
  finally
    if Succeeded(Init) then
      CoUninitialize;
  end;
end;

{ --- TWasapiRecorder --- }

constructor TWasapiRecorder.Create(const Source: TRecSource; MaxSec: Double);
begin
  FId := Source.Id;
  FLoopback := Source.Loopback;
  FMaxSec := MaxSec;
  inherited Create(False);
end;

function TWasapiRecorder.TakePeak: Single;
begin
  Result := FPeak;
  FPeak := 0;
end;

function TWasapiRecorder.Seconds: Double;
begin
  if FRate > 0 then Result := FFrames / FRate else Result := 0;
end;

procedure TWasapiRecorder.Execute;
var
  En: IMMDeviceEnumerator;
  Dev: IMMDevice;
  Client: IAudioClient;
  Cap: IAudioCaptureClient;
  Fmt: PWaveFormatEx;
  Flags, PktFlags: DWORD;
  Avail, I, K, Ch, Cap0: Integer;
  Got: UINT32;
  Data: PByte;
  IsFloat: Boolean;
  Bits, BlockAlign: Integer;
  L, R, Pk: Single;

  function SampleAt(P: PByte; C: Integer): Single;
  var
    Q: PByte;
  begin
    Q := P + C * (Bits div 8);
    if IsFloat then
      Result := System.PSingle(Q)^
    else
      case Bits of
        16: Result := PSmallInt(Q)^ / 32768;
        24: Result := ((Integer(Q[0]) shl 8) or (Integer(Q[1]) shl 16) or (Integer(Q[2]) shl 24)) / 2147483648.0;
        32: Result := PInteger(Q)^ / 2147483648.0;
      else
        Result := 0;
      end;
  end;

begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  Fmt := nil;
  try
    try
      OleCheck(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IMMDeviceEnumerator, En));
      OleCheck(En.GetDevice(PWideChar(FId), Dev));
      OleCheck(Dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Client));
      OleCheck(Client.GetMixFormat(Fmt));
      Ch := Fmt.nChannels;
      Bits := Fmt.wBitsPerSample;
      BlockAlign := Fmt.nBlockAlign;
      IsFloat := (Fmt.wFormatTag = WAVE_FORMAT_IEEE_FLOAT) or
        ((Fmt.wFormatTag = WAVE_FORMAT_EXTENSIBLE) and IsEqualGUID(PWaveFormatExtensible(Fmt).SubFormat,
        KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
      FRate := Fmt.nSamplesPerSec;
      Flags := 0;
      if FLoopback then
        Flags := AUDCLNT_STREAMFLAGS_LOOPBACK;
      OleCheck(Client.Initialize(AUDCLNT_SHAREMODE_SHARED, Flags, 2000000, 0, Fmt, nil));   // 200 ms Puffer
      OleCheck(Client.GetService(IID_IAudioCaptureClient, Cap));
      Cap0 := Round(FMaxSec * FRate);
      SetLength(FL, Cap0);
      SetLength(FR, Cap0);
      OleCheck(Client.Start);
      FStarted := True;
      while not Terminated and (FFrames < Cap0) do
      begin
        Sleep(10);
        while Succeeded(Cap.GetNextPacketSize(Got)) and (Got > 0) do
        begin
          if Failed(Cap.GetBuffer(Data, Got, PktFlags, nil, nil)) then
            Break;
          Avail := Min(Integer(Got), Cap0 - FFrames);
          Pk := FPeak;
          for I := 0 to Avail - 1 do
          begin
            if PktFlags and AUDCLNT_BUFFERFLAGS_SILENT <> 0 then
            begin
              L := 0; R := 0;
            end
            else
            begin
              K := I * BlockAlign;
              L := SampleAt(Data + K, 0);
              if Ch > 1 then R := SampleAt(Data + K, 1) else R := L;
            end;
            FL[FFrames + I] := L;
            FR[FFrames + I] := R;
            Pk := Max(Pk, Max(Abs(L), Abs(R)));
          end;
          FPeak := Pk;
          Inc(FFrames, Avail);
          Cap.ReleaseBuffer(Got);
        end;
      end;
      Client.Stop;
    except
      on E: Exception do
        FError := E.Message;
    end;
  finally
    if Fmt <> nil then
      CoTaskMemFree(Fmt);
    Cap := nil;
    Client := nil;
    Dev := nil;
    En := nil;
    CoUninitialize;
  end;
end;

function TWasapiRecorder.Finish: TSampleData;
begin
  Terminate;
  WaitFor;
  Result := nil;
  if FFrames < 2 then
    Exit;
  Result := TSampleData.Create;
  Result.SampleRate := FRate;
  Result.Channels := 2;
  Result.Frames := FFrames;
  Result.L := Copy(FL, 0, FFrames);
  Result.R := Copy(FR, 0, FFrames);
  FL := nil;
  FR := nil;
end;

end.
