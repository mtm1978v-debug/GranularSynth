{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.AudioDecode;

{ Laedt beliebige Audiodateien, die Windows abspielen kann (MP3, MPEG-Audio, WMA, AAC/M4A,
  FLAC, AIFF, ...), ueber Windows Media Foundation (Source Reader) und wandelt sie in
  Float-PCM. WAV wird weiterhin mit dem eigenen, schnellen Loader gelesen.
  Media Foundation wird DYNAMISCH geladen (ab Vista/Win7 vorhanden): fehlt sie, bleibt
  nur WAV - das Plugin startet trotzdem.
  Die COM-Schnittstellen sind hier minimal selbst deklariert; die Reihenfolge der
  Methoden entspricht exakt den Windows-Headern (mfobjects.h, mfreadwrite.h). }

interface

uses
  Granular.Sample;

const
  { Laengenbegrenzung (Speicher: Sample liegt dreifach im RAM - L, R und interleaved) }
  MAX_DECODE_SECONDS = 240;

  AUDIO_FILE_FILTER =
    'Audiodateien|*.wav;*.mp3;*.mpeg;*.mpg;*.mp2;*.m4a;*.aac;*.wma;*.flac;*.aif;*.aiff;*.ogg|' +
    'WAV (*.wav)|*.wav|Alle Dateien (*.*)|*.*';

{ WAV ueber den eigenen Loader, alles andere ueber Media Foundation }
function LoadAudioFile(const FileName: string): TSampleData;
function MediaFoundationAvailable: Boolean;

implementation

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Math;

type
  // --- minimale COM-Deklarationen (Reihenfolge = vtable!) ---
  IMFAttributes = interface(IUnknown)
    ['{2cd2d921-c447-44a7-a13c-4adabfc247e3}']
    function GetItem(const guidKey: TGUID; pValue: Pointer): HResult; stdcall;
    function GetItemType(const guidKey: TGUID; out pType: Integer): HResult; stdcall;
    function CompareItem(const guidKey: TGUID; Value: Pointer; out pbResult: BOOL): HResult; stdcall;
    function Compare(pTheirs: IMFAttributes; MatchType: Integer; out pbResult: BOOL): HResult; stdcall;
    function GetUINT32(const guidKey: TGUID; out punValue: UINT32): HResult; stdcall;
    function GetUINT64(const guidKey: TGUID; out punValue: UInt64): HResult; stdcall;
    function GetDouble(const guidKey: TGUID; out pfValue: Double): HResult; stdcall;
    function GetGUID(const guidKey: TGUID; out pguidValue: TGUID): HResult; stdcall;
    function GetStringLength(const guidKey: TGUID; out pcchLength: UINT32): HResult; stdcall;
    function GetString(const guidKey: TGUID; pwszValue: PWideChar; cchBufSize: UINT32; pcchLength: PUINT32): HResult; stdcall;
    function GetAllocatedString(const guidKey: TGUID; out ppwszValue: PWideChar; out pcchLength: UINT32): HResult; stdcall;
    function GetBlobSize(const guidKey: TGUID; out pcbBlobSize: UINT32): HResult; stdcall;
    function GetBlob(const guidKey: TGUID; pBuf: PByte; cbBufSize: UINT32; pcbBlobSize: PUINT32): HResult; stdcall;
    function GetAllocatedBlob(const guidKey: TGUID; out ppBuf: PByte; out pcbSize: UINT32): HResult; stdcall;
    function GetUnknown(const guidKey: TGUID; const riid: TGUID; out ppv): HResult; stdcall;
    function SetItem(const guidKey: TGUID; Value: Pointer): HResult; stdcall;
    function DeleteItem(const guidKey: TGUID): HResult; stdcall;
    function DeleteAllItems: HResult; stdcall;
    function SetUINT32(const guidKey: TGUID; unValue: UINT32): HResult; stdcall;
    function SetUINT64(const guidKey: TGUID; unValue: UInt64): HResult; stdcall;
    function SetDouble(const guidKey: TGUID; fValue: Double): HResult; stdcall;
    function SetGUID(const guidKey: TGUID; const guidValue: TGUID): HResult; stdcall;
    function SetString(const guidKey: TGUID; wszValue: PWideChar): HResult; stdcall;
    function SetBlob(const guidKey: TGUID; pBuf: PByte; cbBufSize: UINT32): HResult; stdcall;
    function SetUnknown(const guidKey: TGUID; pUnknown: IUnknown): HResult; stdcall;
    function LockStore: HResult; stdcall;
    function UnlockStore: HResult; stdcall;
    function GetCount(out pcItems: UINT32): HResult; stdcall;
    function GetItemByIndex(unIndex: UINT32; out pguidKey: TGUID; pValue: Pointer): HResult; stdcall;
    function CopyAllItems(pDest: IMFAttributes): HResult; stdcall;
  end;

  IMFMediaType = interface(IMFAttributes)
    ['{44ae0fa8-ea31-4109-8d2e-4cae4997c555}']
    function GetMajorType(out pguidMajorType: TGUID): HResult; stdcall;
    function IsCompressedFormat(out pfCompressed: BOOL): HResult; stdcall;
    function IsEqual(pIMediaType: IMFMediaType; out pdwFlags: DWORD): HResult; stdcall;
    function GetRepresentation(guidRepresentation: TGUID; out ppvRepresentation: Pointer): HResult; stdcall;
    function FreeRepresentation(guidRepresentation: TGUID; pvRepresentation: Pointer): HResult; stdcall;
  end;

  IMFMediaBuffer = interface(IUnknown)
    ['{045FA593-8799-42b8-BC8D-8968C6453507}']
    function Lock(out ppbBuffer: PByte; pcbMaxLength: PDWORD; pcbCurrentLength: PDWORD): HResult; stdcall;
    function Unlock: HResult; stdcall;
    function GetCurrentLength(out pcbCurrentLength: DWORD): HResult; stdcall;
    function SetCurrentLength(cbCurrentLength: DWORD): HResult; stdcall;
    function GetMaxLength(out pcbMaxLength: DWORD): HResult; stdcall;
  end;

  IMFSample = interface(IMFAttributes)
    ['{c40a00f2-b93a-4d80-ae8c-5a1c634f58e4}']
    function GetSampleFlags(out pdwSampleFlags: DWORD): HResult; stdcall;
    function SetSampleFlags(dwSampleFlags: DWORD): HResult; stdcall;
    function GetSampleTime(out phnsSampleTime: Int64): HResult; stdcall;
    function SetSampleTime(hnsSampleTime: Int64): HResult; stdcall;
    function GetSampleDuration(out phnsSampleDuration: Int64): HResult; stdcall;
    function SetSampleDuration(hnsSampleDuration: Int64): HResult; stdcall;
    function GetBufferCount(out pdwBufferCount: DWORD): HResult; stdcall;
    function GetBufferByIndex(dwIndex: DWORD; out ppBuffer: IMFMediaBuffer): HResult; stdcall;
    function ConvertToContiguousBuffer(out ppBuffer: IMFMediaBuffer): HResult; stdcall;
    function AddBuffer(pBuffer: IMFMediaBuffer): HResult; stdcall;
    function RemoveBufferByIndex(dwIndex: DWORD): HResult; stdcall;
    function RemoveAllBuffers: HResult; stdcall;
    function GetTotalLength(out pcbTotalLength: DWORD): HResult; stdcall;
    function CopyToBuffer(pBuffer: IMFMediaBuffer): HResult; stdcall;
  end;

  IMFSourceReader = interface(IUnknown)
    ['{70ae66f2-c809-4e4f-8915-bdcb406b7993}']
    function GetStreamSelection(dwStreamIndex: DWORD; out pfSelected: BOOL): HResult; stdcall;
    function SetStreamSelection(dwStreamIndex: DWORD; fSelected: BOOL): HResult; stdcall;
    function GetNativeMediaType(dwStreamIndex: DWORD; dwMediaTypeIndex: DWORD; out ppMediaType: IMFMediaType): HResult; stdcall;
    function GetCurrentMediaType(dwStreamIndex: DWORD; out ppMediaType: IMFMediaType): HResult; stdcall;
    function SetCurrentMediaType(dwStreamIndex: DWORD; pdwReserved: PDWORD; pMediaType: IMFMediaType): HResult; stdcall;
    function SetCurrentPosition(const guidTimeFormat: TGUID; varPosition: Pointer): HResult; stdcall;
    function ReadSample(dwStreamIndex: DWORD; dwControlFlags: DWORD; pdwActualStreamIndex: PDWORD;
      pdwStreamFlags: PDWORD; pllTimestamp: PInt64; out ppSample: IMFSample): HResult; stdcall;
    function Flush(dwStreamIndex: DWORD): HResult; stdcall;
    function GetServiceForStream(dwStreamIndex: DWORD; const guidService: TGUID; const riid: TGUID; out ppvObject): HResult; stdcall;
    function GetPresentationAttribute(dwStreamIndex: DWORD; const guidAttribute: TGUID; pvarAttribute: Pointer): HResult; stdcall;
  end;

  TMFStartup = function(Version: ULONG; dwFlags: DWORD): HResult; stdcall;
  TMFShutdown = function: HResult; stdcall;
  TMFCreateMediaType = function(out ppMFType: IMFMediaType): HResult; stdcall;
  TMFCreateSourceReaderFromURL = function(pwszURL: PWideChar; pAttributes: IMFAttributes;
    out ppSourceReader: IMFSourceReader): HResult; stdcall;

const
  MF_VERSION_WIN7 = $00020070;
  MF_VERSION_VISTA = $00010070;
  MF_SOURCE_READER_FIRST_AUDIO_STREAM = DWORD($FFFFFFFD);
  MF_SOURCE_READER_ALL_STREAMS = DWORD($FFFFFFFE);
  MF_SOURCE_READERF_ENDOFSTREAM = 2;

  MF_MT_MAJOR_TYPE: TGUID = '{48eba18e-f8c9-4687-bf11-0a74c9f96a8f}';
  MF_MT_SUBTYPE: TGUID = '{f7e34c9a-42e8-4714-b74b-cb29d72c35e5}';
  MF_MT_AUDIO_NUM_CHANNELS: TGUID = '{37e48bf5-645e-4c5b-89de-ada9e29b696a}';
  MF_MT_AUDIO_SAMPLES_PER_SECOND: TGUID = '{5faeeae7-0290-4c31-9e8a-c534f68d9dba}';
  MFMediaType_Audio: TGUID = '{73647561-0000-0010-8000-00AA00389B71}';
  MFAudioFormat_Float: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';

var
  GPlat, GReadWrite: HMODULE;
  GTried: Boolean;
  MFStartup: TMFStartup;
  MFShutdown: TMFShutdown;
  MFCreateMediaType: TMFCreateMediaType;
  MFCreateSourceReaderFromURL: TMFCreateSourceReaderFromURL;

function MediaFoundationAvailable: Boolean;
begin
  if not GTried then
  begin
    GTried := True;
    GPlat := LoadLibrary('mfplat.dll');
    GReadWrite := LoadLibrary('mfreadwrite.dll');
    if (GPlat <> 0) and (GReadWrite <> 0) then
    begin
      @MFStartup := GetProcAddress(GPlat, 'MFStartup');
      @MFShutdown := GetProcAddress(GPlat, 'MFShutdown');
      @MFCreateMediaType := GetProcAddress(GPlat, 'MFCreateMediaType');
      @MFCreateSourceReaderFromURL := GetProcAddress(GReadWrite, 'MFCreateSourceReaderFromURL');
    end;
  end;
  Result := Assigned(MFStartup) and Assigned(MFShutdown) and Assigned(MFCreateMediaType) and
    Assigned(MFCreateSourceReaderFromURL);
end;

procedure Check(Hr: HResult; const What: string);
begin
  if Failed(Hr) then
    raise ESampleLoadError.CreateFmt('%s fehlgeschlagen (0x%.8x).', [What, Cardinal(Hr)]);
end;

function DecodeWithMF(const FileName: string): TSampleData;
var
  ComInit: HResult;
  Reader: IMFSourceReader;
  MT, Cur: IMFMediaType;
  Sample: IMFSample;
  Buf: IMFMediaBuffer;
  Flags, Len: DWORD;
  Channels, Rate: UINT32;
  P: PByte;
  Pcm: TArray<Single>;
  Count, MaxCount, N, I, F, Frames: Integer;
  Src: PSingle;
begin
  if not MediaFoundationAvailable then
    raise ESampleLoadError.Create('Windows Media Foundation ist auf diesem System nicht verfügbar - ' +
      'bitte WAV-Dateien verwenden.');
  ComInit := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    if Failed(MFStartup(MF_VERSION_WIN7, 0)) then
      Check(MFStartup(MF_VERSION_VISTA, 0), 'MFStartup');
    try
      Check(MFCreateSourceReaderFromURL(PWideChar(FileName), nil, Reader), 'Datei öffnen');
      Reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, False);
      Check(Reader.SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, True), 'Audiospur wählen');
      // Ausgabe: unkomprimiertes 32-Bit-Float, Kanalzahl/Abtastrate wie in der Datei
      Check(MFCreateMediaType(MT), 'MediaType');
      MT.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      MT.SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
      Check(Reader.SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nil, MT), 'Float-Ausgabe einstellen');
      Check(Reader.GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, Cur), 'Format lesen');
      Check(Cur.GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, Channels), 'Kanalzahl');
      Check(Cur.GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, Rate), 'Abtastrate');
      if (Channels < 1) or (Rate = 0) then
        raise ESampleLoadError.Create('Ungültiges Audioformat.');

      MaxCount := MAX_DECODE_SECONDS * Integer(Rate) * Integer(Channels);
      Count := 0;
      SetLength(Pcm, Integer(Rate) * Integer(Channels) * 10);
      repeat
        Flags := 0;
        Sample := nil;
        Check(Reader.ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nil, @Flags, nil, Sample), 'Lesen');
        if Sample <> nil then
        begin
          Check(Sample.ConvertToContiguousBuffer(Buf), 'Puffer');
          Check(Buf.Lock(P, nil, @Len), 'Puffer sperren');
          try
            N := Min(Integer(Len) div SizeOf(Single), MaxCount - Count);
            if Count + N > Length(Pcm) then
              SetLength(Pcm, Max(Count + N, Length(Pcm) * 2));
            if N > 0 then
              Move(P^, Pcm[Count], N * SizeOf(Single));
            Inc(Count, N);
          finally
            Buf.Unlock;
          end;
          Buf := nil;
        end;
      until ((Flags and MF_SOURCE_READERF_ENDOFSTREAM) <> 0) or (Count >= MaxCount);
      Reader := nil;
    finally
      MFShutdown;
    end;
  finally
    if Succeeded(ComInit) then
      CoUninitialize;
  end;

  Frames := Count div Integer(Channels);
  if Frames < 16 then
    raise ESampleLoadError.Create('Die Datei enthält keine (ausreichenden) Audiodaten.');
  Result := TSampleData.Create;
  try
    Result.FileName := FileName;
    Result.SampleRate := Rate;
    Result.Channels := Channels;
    Result.Frames := Frames;
    SetLength(Result.L, Frames);
    SetLength(Result.R, Frames);
    Src := @Pcm[0];
    for F := 0 to Frames - 1 do
    begin
      I := F * Integer(Channels);
      Result.L[F] := PSingle(NativeUInt(Src) + NativeUInt(I) * SizeOf(Single))^;
      if Channels > 1 then
        Result.R[F] := PSingle(NativeUInt(Src) + NativeUInt(I + 1) * SizeOf(Single))^
      else
        Result.R[F] := Result.L[F];
    end;
    BuildInterleaved(Result);
  except
    Result.Free;
    raise;
  end;
end;

function LoadAudioFile(const FileName: string): TSampleData;
begin
  if SameText(ExtractFileExt(FileName), '.wav') then
  try
    Exit(LoadWaveFile(FileName));
  except
    // exotisches WAV (z.B. ADPCM) -> Media Foundation versuchen
  end;
  Result := DecodeWithMF(FileName);
end;

initialization

finalization
  if GReadWrite <> 0 then FreeLibrary(GReadWrite);
  if GPlat <> 0 then FreeLibrary(GPlat);

end.
