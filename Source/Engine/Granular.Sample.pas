{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Sample;

{ Sampledaten (immer Stereo, Single-Float) und ein einfacher WAV-Loader
  ohne Fremdabhaengigkeiten. Unterstuetzt PCM 8/16/24/32 Bit, Float 32/64 Bit,
  WAVE_FORMAT_EXTENSIBLE, Mono und Stereo (bei mehr Kanaelen: die ersten zwei). }

interface

uses
  System.SysUtils, System.Classes;

type
  TSampleData = class
  public
    L, R: TArray<Single>;   // bei Mono-Dateien identischer Inhalt
    LR: TArray<Single>;     // interleaved L R L R ... (+1 Frame Reserve) fuer die DSP-Kerne
    Frames: Integer;
    SampleRate: Double;
    Channels: Integer;      // Kanalzahl der Originaldatei
    FileName: string;
  end;

  ESampleLoadError = class(Exception);

const
  // Samplepfad im Preset fuer "bewusst kein Sample" (Init-Preset); '' bedeutet dagegen Demo-Klang
  EMPTY_SAMPLE_REF = '*leer*';

{ Stilles Sample (1 s): Preset ohne Klangquelle }
function CreateEmptySample(SampleRate: Integer): TSampleData;
function IsEmptySample(Data: TSampleData): Boolean;
{ Samplepfad fuers Speichern: leeres Sample als EMPTY_SAMPLE_REF, sonst Path }
function SampleRefFor(Data: TSampleData; const Path: string): string;

{ Baut Data.LR aus L/R auf - nach jedem Fuellen von L/R aufrufen }
procedure BuildInterleaved(Data: TSampleData);

function LoadWaveFile(const FileName: string): TSampleData;
{ Erzeugt einen synthetischen Stereo-Klang (C4, obertonreich, leicht verstimmt),
  damit ohne Sounddatei sofort etwas zu hoeren ist. }
function CreateDemoSample(SampleRate: Integer): TSampleData;
{ Schreibt Stereo-16-Bit-PCM (z.B. um den Demo-Klang als Datei mitzuliefern) }
procedure SaveWaveFile(Data: TSampleData; const FileName: string);

implementation

uses
  System.Math;

procedure BuildInterleaved(Data: TSampleData);
var
  F: Integer;
begin
  SetLength(Data.LR, (Data.Frames + 1) * 2);
  for F := 0 to Data.Frames - 1 do
  begin
    Data.LR[F * 2] := Data.L[F];
    Data.LR[F * 2 + 1] := Data.R[F];
  end;
  Data.LR[Data.Frames * 2] := 0;
  Data.LR[Data.Frames * 2 + 1] := 0;
end;

procedure SaveWaveFile(Data: TSampleData; const FileName: string);
var
  S: TFileStream;
  F, DataBytes, V: Integer;
  W: Word;
  D: Cardinal;
  Peak, G: Single;
  Pcm: TArray<SmallInt>;

  procedure Put4(const Tag: AnsiString);
  begin
    S.WriteBuffer(Tag[1], 4);
  end;

begin
  Peak := 0;
  for F := 0 to Data.Frames - 1 do
    Peak := Max(Peak, Max(Abs(Data.L[F]), Abs(Data.R[F])));
  if Peak > 0.99 then G := 0.99 / Peak else G := 1;
  SetLength(Pcm, Data.Frames * 2);
  for F := 0 to Data.Frames - 1 do
  begin
    V := Round(Data.L[F] * G * 32767);
    Pcm[F * 2] := EnsureRange(V, -32768, 32767);
    V := Round(Data.R[F] * G * 32767);
    Pcm[F * 2 + 1] := EnsureRange(V, -32768, 32767);
  end;
  DataBytes := Data.Frames * 4;
  S := TFileStream.Create(FileName, fmCreate);
  try
    Put4('RIFF');
    D := 36 + DataBytes;  S.WriteBuffer(D, 4);
    Put4('WAVE');
    Put4('fmt ');
    D := 16;              S.WriteBuffer(D, 4);
    W := 1;               S.WriteBuffer(W, 2);     // PCM
    W := 2;               S.WriteBuffer(W, 2);     // Stereo
    D := Round(Data.SampleRate); S.WriteBuffer(D, 4);
    D := Round(Data.SampleRate) * 4; S.WriteBuffer(D, 4);
    W := 4;               S.WriteBuffer(W, 2);
    W := 16;              S.WriteBuffer(W, 2);
    Put4('data');
    D := DataBytes;       S.WriteBuffer(D, 4);
    if DataBytes > 0 then
      S.WriteBuffer(Pcm[0], DataBytes);
  finally
    S.Free;
  end;
end;

function CreateEmptySample(SampleRate: Integer): TSampleData;
begin
  Result := TSampleData.Create;
  Result.FileName := EMPTY_SAMPLE_REF;
  Result.SampleRate := SampleRate;
  Result.Channels := 1;
  Result.Frames := SampleRate;
  SetLength(Result.L, Result.Frames);
  SetLength(Result.R, Result.Frames);
  BuildInterleaved(Result);
end;

function IsEmptySample(Data: TSampleData): Boolean;
begin
  Result := (Data <> nil) and (Data.FileName = EMPTY_SAMPLE_REF);
end;

function SampleRefFor(Data: TSampleData; const Path: string): string;
begin
  if IsEmptySample(Data) then
    Result := EMPTY_SAMPLE_REF
  else
    Result := Path;
end;

function CreateDemoSample(SampleRate: Integer): TSampleData;
const
  BASE_FREQ = 261.6256;
  SECONDS = 4;
var
  F, H: Integer;
  T, Env, Morph, SL, SR, Amp: Double;
begin
  Result := TSampleData.Create;
  Result.FileName := 'Demo-Klang (synthetisch)';
  Result.SampleRate := SampleRate;
  Result.Channels := 2;
  Result.Frames := SampleRate * SECONDS;
  SetLength(Result.L, Result.Frames);
  SetLength(Result.R, Result.Frames);
  RandSeed := 12345;
  for F := 0 to Result.Frames - 1 do
  begin
    T := F / SampleRate;
    Env := Min(1.0, T * 20) * Min(1.0, (SECONDS - T) * 4);
    Morph := T / SECONDS;  // Klangfarbe aendert sich ueber die Zeit -> Position hoerbar
    SL := 0; SR := 0;
    for H := 1 to 12 do
    begin
      Amp := Power(1 - Morph * 0.9, H - 1) / H;
      SL := SL + Amp * Sin(2 * Pi * BASE_FREQ * H * T * 0.998);
      SR := SR + Amp * Sin(2 * Pi * BASE_FREQ * H * T * 1.002 + H);
    end;
    // etwas Rauschen in der zweiten Haelfte
    SL := SL + Morph * 0.15 * (Random - 0.5);
    SR := SR + Morph * 0.15 * (Random - 0.5);
    Result.L[F] := 0.35 * Env * SL;
    Result.R[F] := 0.35 * Env * SR;
  end;
  BuildInterleaved(Result);
end;

const
  WAVE_FORMAT_PCM        = $0001;
  WAVE_FORMAT_IEEE_FLOAT = $0003;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

function ReadWord(const B: TBytes; Ofs: Integer): Word; inline;
begin
  Result := B[Ofs] or (B[Ofs + 1] shl 8);
end;

function ReadDWord(const B: TBytes; Ofs: Integer): Cardinal; inline;
begin
  Result := B[Ofs] or (B[Ofs + 1] shl 8) or (B[Ofs + 2] shl 16) or (Cardinal(B[Ofs + 3]) shl 24);
end;

function ChunkIs(const B: TBytes; Ofs: Integer; const Id: AnsiString): Boolean;
begin
  Result := (B[Ofs] = Ord(Id[1])) and (B[Ofs + 1] = Ord(Id[2])) and
            (B[Ofs + 2] = Ord(Id[3])) and (B[Ofs + 3] = Ord(Id[4]));
end;

function DecodeSample(const B: TBytes; Ofs, Bits, Tag: Integer): Single;
var
  I: Integer;
begin
  if Tag = WAVE_FORMAT_IEEE_FLOAT then
  begin
    if Bits = 64 then
      Result := PDouble(@B[Ofs])^
    else
      Result := PSingle(@B[Ofs])^;
    Exit;
  end;
  case Bits of
    8:  Result := (B[Ofs] - 128) / 128;
    16: Result := SmallInt(ReadWord(B, Ofs)) / 32768;
    24: begin
          I := B[Ofs] or (B[Ofs + 1] shl 8) or (B[Ofs + 2] shl 16);
          if I and $800000 <> 0 then
            I := I or Integer($FF000000);
          Result := I / 8388608;
        end;
    32: Result := Integer(ReadDWord(B, Ofs)) / 2147483648.0;
  else
    Result := 0;
  end;
end;

function LoadWaveFile(const FileName: string): TSampleData;
var
  Stream: TFileStream;
  B: TBytes;
  P, Size, ChunkSize: Integer;
  Tag, Channels, Bits, BlockAlign: Integer;
  Rate: Cardinal;
  DataOfs, DataSize: Integer;
  HasFmt: Boolean;
  F, Ofs, BytesPerSample: Integer;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := Stream.Size;
    SetLength(B, Size);
    if Size > 0 then
      Stream.ReadBuffer(B[0], Size);
  finally
    Stream.Free;
  end;

  if (Size < 12) or not ChunkIs(B, 0, 'RIFF') or not ChunkIs(B, 8, 'WAVE') then
    raise ESampleLoadError.Create('Keine gültige WAV-Datei.');

  HasFmt := False;
  Tag := 0; Channels := 0; Bits := 0; BlockAlign := 0; Rate := 0;
  DataOfs := -1; DataSize := 0;
  P := 12;
  while P + 8 <= Size do
  begin
    ChunkSize := Integer(ReadDWord(B, P + 4));
    if (ChunkSize < 0) or (ChunkSize > Size - P - 8) then
      ChunkSize := Size - P - 8;
    if ChunkIs(B, P, 'fmt ') and (ChunkSize >= 16) then
    begin
      Tag        := ReadWord(B, P + 8);
      Channels   := ReadWord(B, P + 10);
      Rate       := ReadDWord(B, P + 12);
      BlockAlign := ReadWord(B, P + 20);
      Bits       := ReadWord(B, P + 22);
      if (Tag = WAVE_FORMAT_EXTENSIBLE) and (ChunkSize >= 40) then
        Tag := ReadWord(B, P + 8 + 24);  // erste 2 Bytes der SubFormat-GUID
      HasFmt := True;
    end
    else if ChunkIs(B, P, 'data') then
    begin
      DataOfs := P + 8;
      DataSize := ChunkSize;
    end;
    Inc(P, 8 + ChunkSize + (ChunkSize and 1));
  end;

  if not HasFmt or (DataOfs < 0) then
    raise ESampleLoadError.Create('WAV-Datei ohne fmt- oder data-Chunk.');
  if not (Tag in [WAVE_FORMAT_PCM, WAVE_FORMAT_IEEE_FLOAT]) then
    raise ESampleLoadError.CreateFmt('WAV-Format %d wird nicht unterstützt.', [Tag]);
  if (Channels < 1) or (Rate = 0) or not (Bits in [8, 16, 24, 32, 64]) then
    raise ESampleLoadError.Create('WAV-Kopfdaten ungültig.');

  BytesPerSample := Bits div 8;
  if BlockAlign < Channels * BytesPerSample then
    BlockAlign := Channels * BytesPerSample;

  Result := TSampleData.Create;
  try
    Result.FileName := FileName;
    Result.SampleRate := Rate;
    Result.Channels := Channels;
    Result.Frames := DataSize div BlockAlign;
    SetLength(Result.L, Result.Frames);
    SetLength(Result.R, Result.Frames);
    for F := 0 to Result.Frames - 1 do
    begin
      Ofs := DataOfs + F * BlockAlign;
      Result.L[F] := DecodeSample(B, Ofs, Bits, Tag);
      if Channels > 1 then
        Result.R[F] := DecodeSample(B, Ofs + BytesPerSample, Bits, Tag)
      else
        Result.R[F] := Result.L[F];
    end;
    if Result.Frames < 16 then
      raise ESampleLoadError.Create('WAV-Datei enthält zu wenige Samples.');
    BuildInterleaved(Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
