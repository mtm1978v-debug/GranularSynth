{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.AudioOut;

{$WARN SYMBOL_PLATFORM OFF}

{ Minimaler Audio-Ausgang ueber waveOut (MMSystem) - nur fuer die Test-Host-Anwendung.
  Im VST-Plugin entfaellt diese Unit; dort ruft der Host processReplacing auf.
  Eigener Thread mit hoher Prioritaet, Ereignis-gesteuert (CALLBACK_EVENT). }

interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes;

type
  TRenderEvent = procedure(OutL, OutR: System.PSingle; Frames: Integer) of object;

  TWaveOutPlayer = class(TThread)
  private const
    MAX_BUFFERS = 16;
  private
    FBufferCount: Integer;
    FWaveOut: HWAVEOUT;
    FEvent: THandle;
    FHeaders: array[0..MAX_BUFFERS - 1] of TWaveHdr;
    FBuffers: array[0..MAX_BUFFERS - 1] of TArray<SmallInt>;
    FL, FR: TArray<Single>;
    FFrames: Integer;
    FRender: TRenderEvent;
    procedure FillBuffer(Index: Integer);
  protected
    procedure Execute; override;
  public
    { BufferCount x BufferFrames = Latenz; mehr Puffer = robuster gegen kurze Last (z.B. Dateidialoge) }
    constructor Create(SampleRate, BufferFrames, BufferCount: Integer; Render: TRenderEvent);
    destructor Destroy; override;
  end;

implementation

constructor TWaveOutPlayer.Create(SampleRate, BufferFrames, BufferCount: Integer; Render: TRenderEvent);
var
  Fmt: TWaveFormatEx;
  I: Integer;
  Res: MMRESULT;
begin
  // Geraet zuerst oeffnen: scheitert es, existiert noch kein Thread-Handle
  FRender := Render;
  FBufferCount := BufferCount;
  if FBufferCount < 2 then FBufferCount := 2;
  if FBufferCount > MAX_BUFFERS then FBufferCount := MAX_BUFFERS;
  FFrames := BufferFrames;
  SetLength(FL, FFrames);
  SetLength(FR, FFrames);
  FEvent := CreateEvent(nil, False, False, nil);

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := 2;
  Fmt.nSamplesPerSec := SampleRate;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := 4;
  Fmt.nAvgBytesPerSec := SampleRate * 4;
  Res := waveOutOpen(@FWaveOut, WAVE_MAPPER, @Fmt, FEvent, 0, CALLBACK_EVENT);
  if Res <> MMSYSERR_NOERROR then
  begin
    FWaveOut := 0;
    raise Exception.CreateFmt('Audioausgabe konnte nicht geoeffnet werden (Fehler %d).', [Res]);
  end;

  for I := 0 to FBufferCount - 1 do
  begin
    SetLength(FBuffers[I], FFrames * 2);
    FillChar(FHeaders[I], SizeOf(TWaveHdr), 0);
    FHeaders[I].lpData := PAnsiChar(@FBuffers[I][0]);
    FHeaders[I].dwBufferLength := FFrames * 4;
    waveOutPrepareHeader(FWaveOut, @FHeaders[I], SizeOf(TWaveHdr));
    FHeaders[I].dwFlags := FHeaders[I].dwFlags or WHDR_DONE;  // als "frei" markieren
  end;
  inherited Create(False);  // Thread laeuft erst nach dem Konstruktor (AfterConstruction)
  Priority := tpTimeCritical;
end;

destructor TWaveOutPlayer.Destroy;
var
  I: Integer;
begin
  Terminate;
  if FEvent <> 0 then
    SetEvent(FEvent);
  inherited Destroy;  // wartet auf das Thread-Ende
  if FWaveOut <> 0 then
  begin
    waveOutReset(FWaveOut);
    for I := 0 to FBufferCount - 1 do
      waveOutUnprepareHeader(FWaveOut, @FHeaders[I], SizeOf(TWaveHdr));
    waveOutClose(FWaveOut);
  end;
  if FEvent <> 0 then
    CloseHandle(FEvent);
end;

procedure TWaveOutPlayer.FillBuffer(Index: Integer);
var
  I: Integer;
  V: Single;
  Dst: TArray<SmallInt>;
begin
  try
    FRender(@FL[0], @FR[0], FFrames);
  except
    FillChar(FL[0], FFrames * SizeOf(Single), 0);
    FillChar(FR[0], FFrames * SizeOf(Single), 0);
  end;
  Dst := FBuffers[Index];
  for I := 0 to FFrames - 1 do
  begin
    V := FL[I] * 32767;
    if V > 32767 then V := 32767 else if V < -32768 then V := -32768;
    Dst[I * 2] := Round(V);
    V := FR[I] * 32767;
    if V > 32767 then V := 32767 else if V < -32768 then V := -32768;
    Dst[I * 2 + 1] := Round(V);
  end;
  FHeaders[Index].dwFlags := FHeaders[Index].dwFlags and not WHDR_DONE;
  waveOutWrite(FWaveOut, @FHeaders[Index], SizeOf(TWaveHdr));
end;

procedure TWaveOutPlayer.Execute;
var
  I: Integer;
begin
  // fremde Plugins: Gleitkomma-Ausnahmen in diesem Thread maskieren
  Set8087CW($133F);
  SetMXCSR($1F80);
  while not Terminated do
  begin
    for I := 0 to FBufferCount - 1 do
      if (not Terminated) and ((FHeaders[I].dwFlags and WHDR_DONE) <> 0) then
        FillBuffer(I);
    WaitForSingleObject(FEvent, 50);
  end;
end;

end.
