{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.ArpMidi;

{ Arpeggiator-Muster als MIDI-Datei: schreibt die Noten, die der Arp mit dem zuletzt gespielten
  Akkord und den aktuellen Einstellungen erzeugt (Richtung, Oktaven, Notenwert, Laenge, Swing,
  Schrittmuster), und startet das Ziehen der Datei per OLE-Drag&Drop in die DAW.
  Tonleiter, Pitch & Co. wirken nicht auf die Datei - die spielt das Plugin beim Abspielen selbst. }

interface

uses
  Winapi.Windows, Winapi.ActiveX, Winapi.ShlObj, System.SysUtils, System.Classes, System.Math, System.IOUtils,
  Granular.Params, Granular.Engine;

const
  ARP_MIDI_BARS: array[0..3] of Integer = (1, 2, 4, 8);

{ Standard-MIDI-Datei (Format 0, 480 Ticks je Viertel) mit Bars Takten 4/4 schreiben;
  ohne gemerkten Akkord wird C-Dur (C4 E4 G4) verwendet. False = Datei nicht schreibbar }
function WriteArpMidi(Engine: TGranularEngine; Bars: Integer; const FileName: string): Boolean;
{ Datei per Drag&Drop ziehen (blockiert bis zum Loslassen); True = irgendwo abgelegt }
function DragFileOut(const FileName: string): Boolean;

implementation

const
  PPQ = 480;

type
  TMidiEv = record
    Tick: Integer;
    On: Boolean;
    Note, Vel: Byte;
  end;

function SHCreateStdEnumFmtEtc(cfmt: UINT; afmt: PFormatEtc; out ppenumFormatEtc: IEnumFormatEtc): HResult;
  stdcall; external 'shell32.dll';

function WriteArpMidi(Engine: TGranularEngine; Bars: Integer; const FileName: string): Boolean;
var
  Held: array[0..31] of Integer;
  HeldVel: array[0..31] of Single;
  Seq: array[0..127] of Integer;
  SeqVel: array[0..127] of Single;
  Evs: array of TMidiEv;
  EvCount, Count, Len, Mode, Oct, Steps, StepIdx, Step, ArpCount, I, J, Idx, Total: Integer;
  StepLen, Swing, Gate, T, L, OffT: Double;
  Mask: Cardinal;
  Track: TBytesStream;
  F: TFileStream;
  Tmp: TMidiEv;
  Uspq: Integer;

  function P(Id: TGranularParamId): Single;
  begin
    Result := Engine.GetParamById(Id);
  end;

  procedure AddEv(ATick: Integer; AOn: Boolean; ANote: Integer; AVel: Single);
  begin
    if EvCount >= Length(Evs) then
      SetLength(Evs, EvCount * 2 + 64);
    Evs[EvCount].Tick := ATick;
    Evs[EvCount].On := AOn;
    Evs[EvCount].Note := EnsureRange(ANote, 0, 127);
    Evs[EvCount].Vel := EnsureRange(Round(AVel * 127), 1, 127);
    Inc(EvCount);
  end;

  procedure PlayNote(Note: Integer; Vel: Single; OnT, OffTick: Double);
  begin
    AddEv(Round(OnT), True, Note, Vel);
    AddEv(Min(Round(OffTick), Total), False, Note, 0);
  end;

  procedure WVar(S: TStream; V: Cardinal);
  var
    Buf: array[0..4] of Byte;
    N: Integer;
  begin
    N := 0;
    Buf[0] := V and $7F;
    V := V shr 7;
    while V > 0 do
    begin
      Inc(N);
      Buf[N] := (V and $7F) or $80;
      V := V shr 7;
    end;
    while N >= 0 do
    begin
      S.WriteBuffer(Buf[N], 1);
      Dec(N);
    end;
  end;

  procedure WBytes(S: TStream; const B: array of Byte);
  begin
    if Length(B) > 0 then
      S.WriteBuffer(B[0], Length(B));
  end;

  procedure WBE32(S: TStream; V: Cardinal);
  begin
    WBytes(S, [V shr 24, (V shr 16) and $FF, (V shr 8) and $FF, V and $FF]);
  end;

begin
  Result := False;
  Count := Engine.ArpChord(Held, HeldVel);
  if Count = 0 then
  begin
    Held[0] := 60; Held[1] := 64; Held[2] := 67;
    HeldVel[0] := 0.8; HeldVel[1] := 0.8; HeldVel[2] := 0.8;
    Count := 3;
  end;
  Mode := ParamStep(Ord(gpArpMode), P(gpArpMode));
  Oct := ParamStep(Ord(gpArpOct), P(gpArpOct)) + 1;
  Steps := ParamStep(Ord(gpArpSteps), P(gpArpSteps)) + 1;
  StepLen := ARP_RATE_BEATS[ParamStep(Ord(gpArpRate), P(gpArpRate))] * PPQ;
  Swing := ParamToPlain(gpArpSwing, P(gpArpSwing)) / 100;
  Gate := ParamToPlain(gpArpGate, P(gpArpGate)) / 100;
  Mask := Engine.ArpMask;
  Len := ArpBuildSeq(Held, HeldVel, Count, Mode, Oct, Seq, SeqVel);
  if Len = 0 then
    Exit;
  Total := Max(1, Bars) * 4 * PPQ;
  RandSeed := 12345;   // Zufall: bei gleichen Einstellungen dieselbe Datei
  EvCount := 0;
  T := 0;
  Step := 0;
  ArpCount := 0;
  // wie TGranularEngine.ArpTick/ArpStepNow, nur in Ticks statt Samples
  while Round(T) < Total do
  begin
    if Step mod 2 = 0 then L := StepLen * (1 + Swing) else L := StepLen * (1 - Swing);
    StepIdx := Step mod Steps;
    Inc(Step);
    if (Mask and (1 shl StepIdx)) <> 0 then
    begin
      if Gate < 0.999 then OffT := T + Max(1.0, L * Gate) else OffT := T + L;
      if Mode = 6 then
        for I := 0 to Len - 1 do
          PlayNote(Seq[I], SeqVel[I], T, OffT)
      else
      begin
        if Mode = 4 then
          Idx := Min(Trunc(Random * Len), Len - 1)
        else
          Idx := ArpSeqIndex(Mode, ArpCount, Len);
        PlayNote(Seq[Idx], SeqVel[Idx], T, OffT);
      end;
      Inc(ArpCount);
    end;
    T := T + Max(1.0, L);
  end;

  // nach Zeit sortieren, bei Gleichstand Note-Aus zuerst (Wiederholung derselben Taste)
  for I := 1 to EvCount - 1 do
  begin
    Tmp := Evs[I];
    J := I - 1;
    while (J >= 0) and ((Evs[J].Tick > Tmp.Tick) or ((Evs[J].Tick = Tmp.Tick) and Evs[J].On and not Tmp.On)) do
    begin
      Evs[J + 1] := Evs[J];
      Dec(J);
    end;
    Evs[J + 1] := Tmp;
  end;

  Track := TBytesStream.Create;
  try
    Uspq := Round(60000000 / Max(20.0, ParamToPlain(gpTempo, P(gpTempo))));
    WBytes(Track, [0, $FF, $51, 3, Uspq shr 16, (Uspq shr 8) and $FF, Uspq and $FF]);
    WBytes(Track, [0, $FF, $58, 4, 4, 2, 24, 8]);   // 4/4
    WBytes(Track, [0, $FF, $03, 15]);
    WBytes(Track, TEncoding.ASCII.GetBytes('GranularSynth A'));
    T := 0;
    for I := 0 to EvCount - 1 do
    begin
      WVar(Track, Cardinal(Evs[I].Tick - Round(T)));
      T := Evs[I].Tick;
      if Evs[I].On then
        WBytes(Track, [$90, Evs[I].Note, Evs[I].Vel])
      else
        WBytes(Track, [$80, Evs[I].Note, 64]);
    end;
    WVar(Track, Cardinal(Max(0, Total - Round(T))));
    WBytes(Track, [$FF, $2F, 0]);
    try
      F := TFileStream.Create(FileName, fmCreate);
      try
        WBytes(F, [Ord('M'), Ord('T'), Ord('h'), Ord('d'), 0, 0, 0, 6, 0, 0, 0, 1, PPQ shr 8, PPQ and $FF]);
        WBytes(F, [Ord('M'), Ord('T'), Ord('r'), Ord('k')]);
        WBE32(F, Track.Size);
        F.WriteBuffer(Track.Bytes[0], Track.Size);
      finally
        F.Free;
      end;
      Result := True;
    except
      Result := False;
    end;
  finally
    Track.Free;
  end;
end;

{ --- Drag&Drop einer Datei (CF_HDROP), z.B. in die Spur einer DAW --- }

type
  TFileDrop = class(TInterfacedObject, IDataObject, IDropSource)
  private
    FFile: string;
    FFmt: TFormatEtc;
  public
    constructor Create(const AFile: string);
    // IDropSource
    function QueryContinueDrag(fEscapePressed: BOOL; grfKeyState: Longint): HResult; stdcall;
    function GiveFeedback(dwEffect: Longint): HResult; stdcall;
    // IDataObject
    function GetData(const formatetcIn: TFormatEtc; out medium: TStgMedium): HResult; stdcall;
    function GetDataHere(const formatetc: TFormatEtc; out medium: TStgMedium): HResult; stdcall;
    function QueryGetData(const formatetc: TFormatEtc): HResult; stdcall;
    function GetCanonicalFormatEtc(const formatetc: TFormatEtc; out formatetcOut: TFormatEtc): HResult; stdcall;
    function SetData(const formatetc: TFormatEtc; var medium: TStgMedium; fRelease: BOOL): HResult; stdcall;
    function EnumFormatEtc(dwDirection: Longint; out enumFormatEtc: IEnumFormatEtc): HResult; stdcall;
    function DAdvise(const formatetc: TFormatEtc; advf: Longint; const advSink: IAdviseSink;
      out dwConnection: Longint): HResult; stdcall;
    function DUnadvise(dwConnection: Longint): HResult; stdcall;
    function EnumDAdvise(out enumAdvise: IEnumStatData): HResult; stdcall;
  end;

constructor TFileDrop.Create(const AFile: string);
begin
  inherited Create;
  FFile := AFile;
  FFmt.cfFormat := CF_HDROP;
  FFmt.ptd := nil;
  FFmt.dwAspect := DVASPECT_CONTENT;
  FFmt.lindex := -1;
  FFmt.tymed := TYMED_HGLOBAL;
end;

function TFileDrop.QueryContinueDrag(fEscapePressed: BOOL; grfKeyState: Longint): HResult;
begin
  if fEscapePressed then
    Result := DRAGDROP_S_CANCEL
  else if grfKeyState and (MK_LBUTTON or MK_RBUTTON) = 0 then
    Result := DRAGDROP_S_DROP
  else
    Result := S_OK;
end;

function TFileDrop.GiveFeedback(dwEffect: Longint): HResult;
begin
  Result := DRAGDROP_S_USEDEFAULTCURSORS;
end;

function TFileDrop.QueryGetData(const formatetc: TFormatEtc): HResult;
begin
  if (formatetc.cfFormat = CF_HDROP) and (formatetc.tymed and TYMED_HGLOBAL <> 0) then
    Result := S_OK
  else
    Result := DV_E_FORMATETC;
end;

function TFileDrop.GetData(const formatetcIn: TFormatEtc; out medium: TStgMedium): HResult;
var
  H: HGLOBAL;
  D: PDropFiles;
  Bytes: NativeInt;
begin
  FillChar(medium, SizeOf(medium), 0);
  Result := QueryGetData(formatetcIn);
  if Result <> S_OK then
    Exit;
  // DROPFILES + Dateiname (Unicode) + doppelte Null
  Bytes := SizeOf(TDropFiles) + (Length(FFile) + 2) * SizeOf(Char);
  H := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, Bytes);
  if H = 0 then
    Exit(E_OUTOFMEMORY);
  D := GlobalLock(H);
  D.pFiles := SizeOf(TDropFiles);
  D.fWide := True;
  Move(PChar(FFile)^, PByte(D)[SizeOf(TDropFiles)], Length(FFile) * SizeOf(Char));
  GlobalUnlock(H);
  medium.tymed := TYMED_HGLOBAL;
  medium.hGlobal := H;
  medium.unkForRelease := nil;
  Result := S_OK;
end;

function TFileDrop.GetDataHere(const formatetc: TFormatEtc; out medium: TStgMedium): HResult;
begin
  Result := E_NOTIMPL;
end;

function TFileDrop.GetCanonicalFormatEtc(const formatetc: TFormatEtc; out formatetcOut: TFormatEtc): HResult;
begin
  formatetcOut := formatetc;
  formatetcOut.ptd := nil;
  Result := DATA_S_SAMEFORMATETC;
end;

function TFileDrop.SetData(const formatetc: TFormatEtc; var medium: TStgMedium; fRelease: BOOL): HResult;
begin
  Result := E_NOTIMPL;
end;

function TFileDrop.EnumFormatEtc(dwDirection: Longint; out enumFormatEtc: IEnumFormatEtc): HResult;
begin
  if dwDirection = DATADIR_GET then
    Result := SHCreateStdEnumFmtEtc(1, @FFmt, enumFormatEtc)
  else
    Result := E_NOTIMPL;
end;

function TFileDrop.DAdvise(const formatetc: TFormatEtc; advf: Longint; const advSink: IAdviseSink;
  out dwConnection: Longint): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TFileDrop.DUnadvise(dwConnection: Longint): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TFileDrop.EnumDAdvise(out enumAdvise: IEnumStatData): HResult;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function DragFileOut(const FileName: string): Boolean;
var
  Drop: TFileDrop;
  Effect: Longint;
  InitHr: HResult;
begin
  // OLE ist im GUI-Thread der DAW meist schon initialisiert (S_FALSE); sonst hier nachholen
  InitHr := OleInitialize(nil);
  try
    Drop := TFileDrop.Create(FileName);
    Effect := DROPEFFECT_NONE;
    Result := DoDragDrop(Drop as IDataObject, Drop as IDropSource, DROPEFFECT_COPY, Effect) = DRAGDROP_S_DROP;
  finally
    if Succeeded(InitHr) then
      OleUninitialize;
  end;
end;

end.
