{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.AudioIn;

{ Mikrofon-/Line-Eingang ueber waveIn - nur fuer den Test-Host als Sidechain-Quelle.
  Im VST-Plugin liefert der Host den Sidechain ueber zusaetzliche Eingangskanaele.
  Uebergabe an den Ausgabe-Thread ueber einen lockfreien Ringpuffer
  (genau ein Schreiber, genau ein Leser). }

interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes;

type
  TStereoRing = class
  private const
    SIZE = 65536;             // Frames, Zweierpotenz
    MASK = SIZE - 1;
    MAX_FILL = 4096;          // mehr Vorlauf -> aelteste Daten verwerfen (Latenz begrenzen)
  private
    FL, FR: array[0..SIZE - 1] of Single;
    FWritePos: Integer;       // nur vom Schreiber veraendert
    FReadPos: Integer;        // nur vom Leser veraendert
  public
    procedure WriteInterleaved16(Src: PSmallInt; Frames: Integer);
    procedure Read(L, R: System.PSingle; Frames: Integer);
  end;

  TWaveInRecorder = class(TThread)
  private const
    BUFFER_COUNT = 4;
  private
    FWaveIn: HWAVEIN;
    FEvent: THandle;
    FHeaders: array[0..BUFFER_COUNT - 1] of TWaveHdr;
    FBuffers: array[0..BUFFER_COUNT - 1] of TArray<SmallInt>;
    FFrames: Integer;
    FRing: TStereoRing;
  protected
    procedure Execute; override;
  public
    { DeviceId = Index aus ListInputDevices; WAVE_MAPPED -> Windows wandelt Format/Kanaele }
    constructor Create(DeviceId: Cardinal; SampleRate, BufferFrames: Integer; Ring: TStereoRing);
    destructor Destroy; override;
  end;

{ Namen aller Aufnahmegeraete (Index = DeviceId) }
function ListInputDevices: TArray<string>;

implementation

function ListInputDevices: TArray<string>;
var
  I, N: Integer;
  Caps: TWaveInCaps;
begin
  N := waveInGetNumDevs;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    if waveInGetDevCaps(I, @Caps, SizeOf(Caps)) = MMSYSERR_NOERROR then
      Result[I] := Caps.szPname
    else
      Result[I] := Format('Geraet %d', [I]);
end;

{$POINTERMATH ON}

{ TStereoRing }

procedure TStereoRing.WriteInterleaved16(Src: PSmallInt; Frames: Integer);
var
  I, W: Integer;
begin
  W := FWritePos;
  for I := 0 to Frames - 1 do
  begin
    FL[W and MASK] := Src[I * 2] * (1 / 32768);
    FR[W and MASK] := Src[I * 2 + 1] * (1 / 32768);
    Inc(W);
  end;
  FWritePos := W;  // erst nach dem Schreiben veroeffentlichen
end;

procedure TStereoRing.Read(L, R: System.PSingle; Frames: Integer);
var
  I, Avail, Rd: Integer;
begin
  Rd := FReadPos;
  Avail := FWritePos - Rd;
  if Avail > MAX_FILL then
  begin
    Rd := FWritePos - Frames;
    Avail := Frames;
  end;
  for I := 0 to Frames - 1 do
    if I < Avail then
    begin
      L[I] := FL[(Rd + I) and MASK];
      R[I] := FR[(Rd + I) and MASK];
    end
    else
    begin
      L[I] := 0;
      R[I] := 0;
    end;
  if Avail > Frames then
    Avail := Frames;
  if Avail > 0 then
    FReadPos := Rd + Avail;
end;

{ TWaveInRecorder }

constructor TWaveInRecorder.Create(DeviceId: Cardinal; SampleRate, BufferFrames: Integer; Ring: TStereoRing);
var
  Fmt: TWaveFormatEx;
  I: Integer;
  Res: MMRESULT;
begin
  // Geraet zuerst oeffnen: scheitert es, existiert noch kein Thread-Handle
  FRing := Ring;
  FFrames := BufferFrames;
  FEvent := CreateEvent(nil, False, False, nil);

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := 2;
  Fmt.nSamplesPerSec := SampleRate;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := 4;
  Fmt.nAvgBytesPerSec := SampleRate * 4;
  Res := waveInOpen(@FWaveIn, DeviceId, @Fmt, FEvent, 0, CALLBACK_EVENT or WAVE_MAPPED);
  if Res <> MMSYSERR_NOERROR then
  begin
    FWaveIn := 0;
    raise Exception.CreateFmt('Audioeingang konnte nicht geoeffnet werden (Fehler %d).', [Res]);
  end;

  for I := 0 to BUFFER_COUNT - 1 do
  begin
    SetLength(FBuffers[I], FFrames * 2);
    FillChar(FHeaders[I], SizeOf(TWaveHdr), 0);
    FHeaders[I].lpData := PAnsiChar(@FBuffers[I][0]);
    FHeaders[I].dwBufferLength := FFrames * 4;
    waveInPrepareHeader(FWaveIn, @FHeaders[I], SizeOf(TWaveHdr));
    waveInAddBuffer(FWaveIn, @FHeaders[I], SizeOf(TWaveHdr));
  end;
  waveInStart(FWaveIn);
  inherited Create(False);
  Priority := tpHigher;
end;

destructor TWaveInRecorder.Destroy;
var
  I: Integer;
begin
  Terminate;
  if FEvent <> 0 then
    SetEvent(FEvent);
  inherited Destroy;  // wartet auf das Thread-Ende
  if FWaveIn <> 0 then
  begin
    waveInStop(FWaveIn);
    waveInReset(FWaveIn);
    for I := 0 to BUFFER_COUNT - 1 do
      waveInUnprepareHeader(FWaveIn, @FHeaders[I], SizeOf(TWaveHdr));
    waveInClose(FWaveIn);
  end;
  if FEvent <> 0 then
    CloseHandle(FEvent);
end;

procedure TWaveInRecorder.Execute;
var
  I: Integer;
begin
  while not Terminated do
  begin
    WaitForSingleObject(FEvent, 50);
    for I := 0 to BUFFER_COUNT - 1 do
      if (not Terminated) and ((FHeaders[I].dwFlags and WHDR_DONE) <> 0) then
      begin
        FRing.WriteInterleaved16(PSmallInt(FHeaders[I].lpData), FHeaders[I].dwBytesRecorded div 4);
        FHeaders[I].dwFlags := FHeaders[I].dwFlags and not WHDR_DONE;
        waveInAddBuffer(FWaveIn, @FHeaders[I], SizeOf(TWaveHdr));
      end;
  end;
end;

end.
