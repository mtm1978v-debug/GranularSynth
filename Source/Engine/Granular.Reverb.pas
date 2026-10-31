{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Reverb;

{ Stereo-Hall (Feedback Delay Network, 8 Linien).

  Signalweg:  Eingang -> Pre-Delay -> 4 Allpaesse je Kanal (Diffusion, dichter Anfang)
              -> FDN: 8 Verzoegerungslinien mit teilerfremden Laengen, je Linie
                 Hoehendaempfung (Tiefpass) und Nachhallgewicht, Rueckkopplung ueber eine
                 Hadamard-Matrix (verlustfrei, maximal durchmischt)
              -> Stereo-Abgriff, Breite (Mitte/Seite), Mischung zum trockenen Signal

  Rechenkern: weil jede Linie laenger als ein Block (64 Samples) ist, haengen die Werte eines
  Blocks nur von frueher geschriebenen Werten ab. Die Linien werden blockweise in ein
  8-spaltiges Feld gelesen, der Kern rechnet je Sample alle 8 Linien auf einmal (2 SSE-Register),
  danach wird das Feld zurueckgeschrieben.
    FdnBlockPas   Referenz (Pascal)
    FdnBlockSSE   Win32 SSE1 / Win64 SSE (nur Packed-Single, kein SSE2 noetig)
  -bench vergleicht beide. }

interface

uses
  System.SysUtils, System.Math;

const
  REV_LINES = 8;
  REV_BLOCK = 64;

type
  PFdnArgs = ^TFdnArgs;
  TFdnArgs = record
    Tap: PSingle;          // Count * 8: rein = gelesene Linienwerte, raus = zu schreibende Werte
    InLR: PSingle;         // Count * 2 (L, R) Eingang nach Diffusion
    OutLR: PSingle;        // Count * 2 (L, R) Nachhall-Abgriff
    Count: Integer;
    LP: array[0..7] of Single;     // Zustand der Daempfungs-Tiefpaesse
    Damp: array[0..7] of Single;   // Tiefpass-Koeffizient (1 = keine Daempfung)
    Gain: array[0..7] of Single;   // Nachhallgewicht je Linie, inkl. 1/sqrt(8) der Hadamard-Matrix
    SignA: array[0..3] of Cardinal;   // ( +, -, +, - )
    SignB: array[0..3] of Cardinal;   // ( +, +, -, - )
  end;

  TFdnProc = procedure(Args: PFdnArgs);

  TReverb = class
  private
    FSampleRate: Double;
    FLines: array[0..REV_LINES - 1] of TArray<Single>;
    FLen: array[0..REV_LINES - 1] of Integer;   // aktuelle Laenge (Samples)
    FMaxLen: Integer;
    FWrite: Integer;                            // gemeinsame Schreibposition aller Linien
    FPre: TArray<Single>;                       // Pre-Delay, interleaved
    FPreLen, FPreWrite, FPreSamples: Integer;
    FAp: array[0..7] of TArray<Single>;         // Allpaesse: 0..3 links, 4..7 rechts
    FApLen, FApPos: array[0..7] of Integer;
    FArgs: TFdnArgs;
    FTap: array[0..REV_BLOCK * REV_LINES - 1] of Single;
    FIn, FOut: array[0..REV_BLOCK * 2 - 1] of Single;
    FSize: Double;                              // wirksame Groesse (0..1)
    FFade: Single;                              // Nachhall-Lautstaerke beim Groessenwechsel
    FFadeDir: Integer;                          // -1 ausblenden, +1 einblenden, 0 fertig
    FPendingSize: Double;
    FDenorm: Single;
    FInGain: Single;
    // zuletzt berechnete Koeffizienten-Eingaenge: nur bei Aenderung neu rechnen (Potenzen je Block sparen)
    FCoT60, FCoDamp: Double;
    FCoRoom: Integer;
    FCoFreeze: Boolean;
    FCoLen: array[0..REV_LINES - 1] of Integer;
    FCoValid: Boolean;
    // Bass-/Hoehen-Schnitt nur fuer den Hallanteil: je Kanal zwei Tiefpaesse (12 dB/Okt.)
    FLcState, FHcState: array[0..1, 0..1] of Single;
    FLcA, FHcA: Single;
    procedure ApplySize(Size: Double);
    procedure Chunk(IO: PSingle; N: Integer; Mix, Width: Single);
  public
    LowCut, HighCut: Double;   // Hz: Bass-/Hoehen-Schnitt des Hallanteils (20 / 20000 = aus)
    constructor Create;
    procedure SetSampleRate(Value: Double);
    procedure Clear;
    { IO interleaved stereo, in-place: IO := IO + Mix * Hall.
      Size 0..1, Decay = Nachhallzeit RT60 in s, Damp 0..1, PreDelay in ms, Width 0..1, Mix 0..1 }
    { Room: 0 Neutral, 1 Holz, 2 Sandstein, 3 Tapete/Stoff, 4 Beton, 5 Schallschutz }
    procedure Process(IO: PSingle; N: Integer; Size, Decay, Damp, PreDelayMs, Width, Mix: Double;
      Freeze: Boolean = False; Room: Integer = 0);
  end;

procedure FdnBlockPas(Args: PFdnArgs);
procedure FdnBlockSSE(Args: PFdnArgs);

var
  FdnBlock: TFdnProc = FdnBlockPas;

procedure InitReverbDSP(UseSSE: Boolean);

implementation

{$POINTERMATH ON}

const
  // Linienlaengen bei 44,1 kHz und Groesse 1 (teilerfremd, ~29 .. 81 ms)
  BASE_LEN: array[0..REV_LINES - 1] of Integer = (1277, 1499, 1733, 1999, 2297, 2593, 2953, 3571);
  // Diffusions-Allpaesse (Samples bei 44,1 kHz), rechts leicht versetzt -> breites Bild
  AP_LEN: array[0..7] of Integer = (142, 107, 379, 277, 151, 113, 397, 263);
  AP_G = 0.62;
  SIZE_MIN = 0.35;
  SIZE_MAX = 1.6;
  OUT_SCALE = 0.3;

{ ------------------------------------------------------------------------------
  Rechenkern
  ------------------------------------------------------------------------------ }

procedure FdnBlockPas(Args: PFdnArgs);
var
  S, I: Integer;
  X, Y, H: array[0..7] of Single;
  T: PSingle;
  L, R, A, B, C, D: Single;
begin
  for S := 0 to Args.Count - 1 do
  begin
    T := @Args.Tap[S * 8];
    for I := 0 to 7 do
      X[I] := T[I];
    // Stereo-Abgriff (gleiche Summationsreihenfolge wie der SSE-Kern)
    Args.OutLR[S * 2] := (X[0] + X[5]) + (X[2] + X[7]);
    Args.OutLR[S * 2 + 1] := (X[1] + X[4]) + (X[3] + X[6]);
    // Daempfung und Nachhallgewicht
    for I := 0 to 7 do
    begin
      Args.LP[I] := (X[I] - Args.LP[I]) * Args.Damp[I] + Args.LP[I];
      Y[I] := Args.LP[I] * Args.Gain[I];
    end;
    // Hadamard 4x4 je Haelfte ...
    for I := 0 to 1 do
    begin
      A := Y[I * 4] + Y[I * 4 + 1];
      B := Y[I * 4] - Y[I * 4 + 1];
      C := Y[I * 4 + 2] + Y[I * 4 + 3];
      D := Y[I * 4 + 2] - Y[I * 4 + 3];
      H[I * 4] := A + C;
      H[I * 4 + 1] := B + D;
      H[I * 4 + 2] := A - C;
      H[I * 4 + 3] := B - D;
    end;
    // ... und zwischen den Haelften -> 8x8; dazu der Eingang (L, R, -L, -R | R, L, -R, -L)
    L := Args.InLR[S * 2];
    R := Args.InLR[S * 2 + 1];
    T[0] := (H[0] + H[4]) + L;
    T[1] := (H[1] + H[5]) + R;
    T[2] := (H[2] + H[6]) - L;
    T[3] := (H[3] + H[7]) - R;
    T[4] := (H[0] - H[4]) + R;
    T[5] := (H[1] - H[5]) + L;
    T[6] := (H[2] - H[6]) - R;
    T[7] := (H[3] - H[7]) - L;
  end;
end;

{$IF Defined(CPUX86)}
{ SSE1. eax = Args. xmm6 = SignA, xmm7 = SignB. Speicherzugriffe nur unausgerichtet (movups). }
procedure FdnBlockSSE(Args: PFdnArgs);
asm
        push    esi
        push    edi
        push    ebx
        mov     esi, [eax].TFdnArgs.Tap
        mov     edi, [eax].TFdnArgs.InLR
        mov     edx, [eax].TFdnArgs.OutLR
        mov     ecx, [eax].TFdnArgs.Count
        test    ecx, ecx
        jle     @done
        movups  xmm6, [eax+TFdnArgs.SignA]
        movups  xmm7, [eax+TFdnArgs.SignB]
@loop:
        movups  xmm0, [esi]
        movups  xmm1, [esi+16]
        // Abgriff: s = x0 + (x5, x4, x7, x6);  L = s0 + s2, R = s1 + s3
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $B1
        addps   xmm2, xmm0
        movhlps xmm3, xmm2
        addps   xmm3, xmm2
        movlps  [edx], xmm3
        // Daempfung lp := (x - lp) * d + lp
        movups  xmm4, [eax+TFdnArgs.LP]
        movups  xmm5, [eax+TFdnArgs.Damp]
        subps   xmm0, xmm4
        mulps   xmm0, xmm5
        addps   xmm0, xmm4
        movups  [eax+TFdnArgs.LP], xmm0
        movups  xmm4, [eax+TFdnArgs.LP+16]
        movups  xmm5, [eax+TFdnArgs.Damp+16]
        subps   xmm1, xmm4
        mulps   xmm1, xmm5
        addps   xmm1, xmm4
        movups  [eax+TFdnArgs.LP+16], xmm1
        // Nachhallgewicht
        movups  xmm4, [eax+TFdnArgs.Gain]
        mulps   xmm0, xmm4
        movups  xmm4, [eax+TFdnArgs.Gain+16]
        mulps   xmm1, xmm4
        // Hadamard 4x4 (beide Haelften)
        movaps  xmm2, xmm0
        shufps  xmm2, xmm2, $B1
        xorps   xmm0, xmm6
        addps   xmm0, xmm2
        movaps  xmm2, xmm0
        shufps  xmm2, xmm2, $4E
        xorps   xmm0, xmm7
        addps   xmm0, xmm2
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $B1
        xorps   xmm1, xmm6
        addps   xmm1, xmm2
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $4E
        xorps   xmm1, xmm7
        addps   xmm1, xmm2
        // zwischen den Haelften
        movaps  xmm2, xmm0
        addps   xmm0, xmm1
        subps   xmm2, xmm1
        // Eingang (L, R, -L, -R) bzw. (R, L, -R, -L)
        movss   xmm3, [edi]
        movss   xmm4, [edi+4]
        unpcklps xmm3, xmm4
        movlhps xmm3, xmm3
        xorps   xmm3, xmm7
        addps   xmm0, xmm3
        shufps  xmm3, xmm3, $B1
        addps   xmm2, xmm3
        movups  [esi], xmm0
        movups  [esi+16], xmm2
        add     esi, 32
        add     edi, 8
        add     edx, 8
        dec     ecx
        jnz     @loop
@done:
        pop     ebx
        pop     edi
        pop     esi
end;
{$ELSEIF Defined(CPUX64)}
{ x64: rcx = Args. xmm6/xmm7 sind nicht fluechtig -> .SAVENV }
procedure FdnBlockSSE(Args: PFdnArgs);
asm
        .SAVENV xmm6
        .SAVENV xmm7
        mov     r8, [rcx].TFdnArgs.Tap
        mov     r9, [rcx].TFdnArgs.InLR
        mov     r10, [rcx].TFdnArgs.OutLR
        mov     r11d, [rcx].TFdnArgs.Count
        test    r11d, r11d
        jle     @done
        movups  xmm6, [rcx+TFdnArgs.SignA]
        movups  xmm7, [rcx+TFdnArgs.SignB]
@loop:
        movups  xmm0, [r8]
        movups  xmm1, [r8+16]
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $B1
        addps   xmm2, xmm0
        movhlps xmm3, xmm2
        addps   xmm3, xmm2
        movlps  [r10], xmm3
        movups  xmm4, [rcx+TFdnArgs.LP]
        movups  xmm5, [rcx+TFdnArgs.Damp]
        subps   xmm0, xmm4
        mulps   xmm0, xmm5
        addps   xmm0, xmm4
        movups  [rcx+TFdnArgs.LP], xmm0
        movups  xmm4, [rcx+TFdnArgs.LP+16]
        movups  xmm5, [rcx+TFdnArgs.Damp+16]
        subps   xmm1, xmm4
        mulps   xmm1, xmm5
        addps   xmm1, xmm4
        movups  [rcx+TFdnArgs.LP+16], xmm1
        movups  xmm4, [rcx+TFdnArgs.Gain]
        mulps   xmm0, xmm4
        movups  xmm4, [rcx+TFdnArgs.Gain+16]
        mulps   xmm1, xmm4
        movaps  xmm2, xmm0
        shufps  xmm2, xmm2, $B1
        xorps   xmm0, xmm6
        addps   xmm0, xmm2
        movaps  xmm2, xmm0
        shufps  xmm2, xmm2, $4E
        xorps   xmm0, xmm7
        addps   xmm0, xmm2
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $B1
        xorps   xmm1, xmm6
        addps   xmm1, xmm2
        movaps  xmm2, xmm1
        shufps  xmm2, xmm2, $4E
        xorps   xmm1, xmm7
        addps   xmm1, xmm2
        movaps  xmm2, xmm0
        addps   xmm0, xmm1
        subps   xmm2, xmm1
        movss   xmm3, [r9]
        movss   xmm4, [r9+4]
        unpcklps xmm3, xmm4
        movlhps xmm3, xmm3
        xorps   xmm3, xmm7
        addps   xmm0, xmm3
        shufps  xmm3, xmm3, $B1
        addps   xmm2, xmm3
        movups  [r8], xmm0
        movups  [r8+16], xmm2
        add     r8, 32
        add     r9, 8
        add     r10, 8
        dec     r11d
        jnz     @loop
@done:
end;
{$ELSE}
procedure FdnBlockSSE(Args: PFdnArgs);
begin
  FdnBlockPas(Args);
end;
{$IFEND}

procedure InitReverbDSP(UseSSE: Boolean);
begin
  if UseSSE then
    FdnBlock := FdnBlockSSE
  else
    FdnBlock := FdnBlockPas;
end;

{ ------------------------------------------------------------------------------
  TReverb
  ------------------------------------------------------------------------------ }

constructor TReverb.Create;
const
  SA: array[0..3] of Cardinal = (0, $80000000, 0, $80000000);
  SB: array[0..3] of Cardinal = (0, 0, $80000000, $80000000);
var
  I: Integer;
begin
  inherited Create;
  for I := 0 to 3 do
  begin
    FArgs.SignA[I] := SA[I];
    FArgs.SignB[I] := SB[I];
  end;
  FSize := -1;
  FFade := 1;
  FDenorm := 1E-18;
  FInGain := 1;
  LowCut := 20;
  HighCut := 20000;
  SetSampleRate(44100);
end;

procedure TReverb.SetSampleRate(Value: Double);
var
  I: Integer;
  K: Double;
begin
  FSampleRate := Value;
  FCoValid := False;               // Koeffizienten haengen von der Samplerate ab
  K := Value / 44100;
  FMaxLen := Round(BASE_LEN[REV_LINES - 1] * SIZE_MAX * K) + REV_BLOCK + 8;
  for I := 0 to REV_LINES - 1 do
  begin
    FLines[I] := nil;
    SetLength(FLines[I], FMaxLen);
  end;
  FPreLen := Round(0.26 * Value) + 2;
  FPre := nil;
  SetLength(FPre, FPreLen * 2);
  for I := 0 to 7 do
  begin
    FApLen[I] := Max(4, Round(AP_LEN[I] * K));
    FAp[I] := nil;
    SetLength(FAp[I], FApLen[I]);
    FApPos[I] := 0;
  end;
  FWrite := 0;
  FPreWrite := 0;
  FSize := -1;
  Clear;
end;

procedure TReverb.Clear;
var
  I: Integer;
begin
  for I := 0 to REV_LINES - 1 do
    FillChar(FLines[I][0], Length(FLines[I]) * SizeOf(Single), 0);
  FillChar(FPre[0], Length(FPre) * SizeOf(Single), 0);
  for I := 0 to 7 do
    FillChar(FAp[I][0], Length(FAp[I]) * SizeOf(Single), 0);
  FillChar(FArgs.LP, SizeOf(FArgs.LP), 0);
  FillChar(FLcState, SizeOf(FLcState), 0);
  FillChar(FHcState, SizeOf(FHcState), 0);
end;

procedure TReverb.ApplySize(Size: Double);
var
  I: Integer;
  F: Double;
begin
  FSize := Size;
  F := (SIZE_MIN + (SIZE_MAX - SIZE_MIN) * Size) * FSampleRate / 44100;
  for I := 0 to REV_LINES - 1 do
    FLen[I] := EnsureRange(Round(BASE_LEN[I] * F), REV_BLOCK + 2, FMaxLen - 2);
end;

{ ein Stueck <= REV_BLOCK Samples }
procedure TReverb.Chunk(IO: PSingle; N: Integer; Mix, Width: Single);
var
  S, I, P, Rd, Ln, PW, Seg: Integer;
  L, R, X, Y, Mid, Side, G: Single;
  Line, Pre: PSingle;
  ApB: array[0..7] of PSingle;      // Allpass-Puffer, Positionen und Laengen lokal (Register/Stack statt
  ApP, ApL: array[0..7] of Integer; // doppelter Indirektion und Feld-Rueckschreiben je Sample)
begin
  // 1) Pre-Delay + Diffusion
  for I := 0 to 7 do
  begin
    ApB[I] := @FAp[I][0];
    ApP[I] := FApPos[I];
    ApL[I] := FApLen[I];
  end;
  Pre := @FPre[0];
  PW := FPreWrite;
  for S := 0 to N - 1 do
  begin
    L := IO[S * 2];
    R := IO[S * 2 + 1];
    Pre[PW * 2] := L;
    Pre[PW * 2 + 1] := R;
    Rd := PW - FPreSamples;
    if Rd < 0 then Inc(Rd, FPreLen);
    L := Pre[Rd * 2];
    R := Pre[Rd * 2 + 1];
    Inc(PW);
    if PW >= FPreLen then PW := 0;
    // Allpaesse (Schroeder): y = -g*x + d;  Speicher = x + g*y
    for I := 0 to 3 do
    begin
      P := ApP[I];
      Y := ApB[I][P] - AP_G * L;
      ApB[I][P] := L + AP_G * Y;
      Inc(P); if P >= ApL[I] then P := 0;
      ApP[I] := P;
      L := Y;
      P := ApP[I + 4];
      Y := ApB[I + 4][P] - AP_G * R;
      ApB[I + 4][P] := R + AP_G * Y;
      Inc(P); if P >= ApL[I + 4] then P := 0;
      ApP[I + 4] := P;
      R := Y;
    end;
    // winziger Gleichanteil verhindert langsame Denormal-Zahlen im ausklingenden Netz
    FIn[S * 2] := L * FInGain + FDenorm;
    FIn[S * 2 + 1] := R * FInGain - FDenorm;
  end;
  FPreWrite := PW;
  for I := 0 to 7 do
    FApPos[I] := ApP[I];

  // 2) Linien blockweise lesen (Laenge > Block -> nur Werte aus frueheren Bloecken)
  // (in hoechstens zwei zusammenhaengenden Stuecken: keine Ende-Pruefung je Sample)
  for I := 0 to REV_LINES - 1 do
  begin
    Line := @FLines[I][0];
    Ln := FLen[I];
    Rd := FWrite - Ln;
    if Rd < 0 then Inc(Rd, FMaxLen);
    Seg := Min(N, FMaxLen - Rd);
    for S := 0 to Seg - 1 do
      FTap[S * 8 + I] := Line[Rd + S];
    for S := Seg to N - 1 do
      FTap[S * 8 + I] := Line[S - Seg];
  end;

  // 3) Netz (SIMD-Kern)
  FArgs.Tap := @FTap[0];
  FArgs.InLR := @FIn[0];
  FArgs.OutLR := @FOut[0];
  FArgs.Count := N;
  FdnBlock(@FArgs);

  // 4) zurueckschreiben
  Seg := Min(N, FMaxLen - FWrite);
  for I := 0 to REV_LINES - 1 do
  begin
    Line := @FLines[I][0];
    P := FWrite;
    for S := 0 to Seg - 1 do
      Line[P + S] := FTap[S * 8 + I];
    for S := Seg to N - 1 do
      Line[S - Seg] := FTap[S * 8 + I];
  end;
  FWrite := (FWrite + N) mod FMaxLen;

  // 5) Breite + Mischung; beim Groessenwechsel kurz aus- und wieder einblenden
  for S := 0 to N - 1 do
  begin
    if FFadeDir <> 0 then
    begin
      FFade := FFade + FFadeDir * (1 / 256);
      if FFade <= 0 then
      begin
        FFade := 0;
        ApplySize(FPendingSize);
        FFadeDir := 1;
      end
      else if FFade >= 1 then
      begin
        FFade := 1;
        FFadeDir := 0;
      end;
    end;
    G := Mix * OUT_SCALE * FFade;
    X := FOut[S * 2];
    Y := FOut[S * 2 + 1];
    if FHcA < 1 then
    begin
      // Hoehen-Schnitt: zwei Tiefpaesse in Reihe
      FHcState[0, 0] := FHcState[0, 0] + FHcA * (X - FHcState[0, 0]);
      FHcState[0, 1] := FHcState[0, 1] + FHcA * (FHcState[0, 0] - FHcState[0, 1]);
      X := FHcState[0, 1];
      FHcState[1, 0] := FHcState[1, 0] + FHcA * (Y - FHcState[1, 0]);
      FHcState[1, 1] := FHcState[1, 1] + FHcA * (FHcState[1, 0] - FHcState[1, 1]);
      Y := FHcState[1, 1];
    end;
    if FLcA > 0 then
    begin
      // Bass-Schnitt: Signal minus seinem Tiefpass, zweimal
      FLcState[0, 0] := FLcState[0, 0] + FLcA * (X - FLcState[0, 0]);
      X := X - FLcState[0, 0];
      FLcState[0, 1] := FLcState[0, 1] + FLcA * (X - FLcState[0, 1]);
      X := X - FLcState[0, 1];
      FLcState[1, 0] := FLcState[1, 0] + FLcA * (Y - FLcState[1, 0]);
      Y := Y - FLcState[1, 0];
      FLcState[1, 1] := FLcState[1, 1] + FLcA * (Y - FLcState[1, 1]);
      Y := Y - FLcState[1, 1];
    end;
    Mid := (X + Y) * 0.5;
    Side := (X - Y) * 0.5 * Width;
    IO[S * 2] := IO[S * 2] + G * (Mid + Side);
    IO[S * 2 + 1] := IO[S * 2 + 1] + G * (Mid - Side);
  end;
end;

procedure TReverb.Process(IO: PSingle; N: Integer; Size, Decay, Damp, PreDelayMs, Width, Mix: Double;
  Freeze: Boolean; Room: Integer);
const
  // Raum-Material: Faktor auf die Hoehendaempfungs-Grenzfrequenz und auf die Nachhallzeit
  //              Neutral  Holz  Sandstein  Tapete  Beton  Schallschutz
  ROOM_FC: array[0..5] of Double = (1.0, 0.45, 0.8, 0.22, 1.7, 0.12);
  ROOM_T60: array[0..5] of Double = (1.0, 0.75, 1.1, 0.45, 1.45, 0.18);
var
  I, Done, C: Integer;
  Fc, A, T60: Double;
  Q: Double;
  Changed: Boolean;
begin
  // Groesse in 2-%-Schritten -> bei Modulation nicht staendig umschalten
  Q := Round(EnsureRange(Size, 0, 1) * 50) / 50;
  if FSize < 0 then
    ApplySize(Q)
  else if (Q <> FSize) and (FFadeDir = 0) then
  begin
    FPendingSize := Q;
    FFadeDir := -1;
  end
  else if FFadeDir <> 0 then
    FPendingSize := Q;

  // Koeffizienten nur neu, wenn sich Nachhallzeit, Daempfung, Raum, Freeze oder die Linienlaengen
  // geaendert haben (gleiche Eingaben -> exakt dieselben Werte wie bisher je Block berechnet)
  Room := EnsureRange(Room, 0, 5);
  Changed := not FCoValid or (Decay <> FCoT60) or (Damp <> FCoDamp) or (Room <> FCoRoom) or (Freeze <> FCoFreeze);
  for I := 0 to REV_LINES - 1 do
    if FLen[I] <> FCoLen[I] then
      Changed := True;
  if Changed then
  begin
    FCoValid := True;
    FCoT60 := Decay;
    FCoDamp := Damp;
    FCoRoom := Room;
    FCoFreeze := Freeze;
    for I := 0 to REV_LINES - 1 do
      FCoLen[I] := FLen[I];
    // Nachhallzeit -> Gewicht je Linie: g = 10^(-3 * Laenge / (RT60 * fs)), dazu 1/sqrt(8)
    T60 := Max(0.05, Decay * ROOM_T60[Room]);
    for I := 0 to REV_LINES - 1 do
      FArgs.Gain[I] := Power(10, -3 * FLen[I] / (T60 * FSampleRate)) / Sqrt(8);
    // Daempfung: Grenzfrequenz 18 kHz (0) .. 1,2 kHz (1)
    Fc := EnsureRange(18000 * Power(1200 / 18000, EnsureRange(Damp, 0, 1)) * ROOM_FC[Room], 300, 20000);
    A := 1 - Exp(-2 * Pi * Fc / FSampleRate);
    for I := 0 to REV_LINES - 1 do
      FArgs.Damp[I] := A;
    // Freeze: Nachhallzeit ~60 s ohne Hoehendaempfung, Eingang leiser -> der Raum haelt den Klang
    // fast unbegrenzt fest (auch wenn Freeze schon beim Laden an ist), ohne sich aufzuschaukeln
    if Freeze then
    begin
      for I := 0 to REV_LINES - 1 do
      begin
        FArgs.Gain[I] := Power(10, -3 * FLen[I] / (60 * FSampleRate)) / Sqrt(8);
        FArgs.Damp[I] := 1;
      end;
      FInGain := 0.35;
    end
    else
      FInGain := 1;
  end;
  FPreSamples := EnsureRange(Round(PreDelayMs * FSampleRate / 1000), 0, FPreLen - 1);
  if HighCut >= 19900 then
    FHcA := 1
  else
    FHcA := 1 - Exp(-2 * Pi * EnsureRange(HighCut, 200, 20000) / FSampleRate);
  if LowCut <= 20.5 then
    FLcA := 0
  else
    FLcA := 1 - Exp(-2 * Pi * EnsureRange(LowCut, 20, 5000) / FSampleRate);
  FDenorm := -FDenorm;

  Done := 0;
  while Done < N do
  begin
    C := Min(REV_BLOCK, N - Done);
    Chunk(@IO[Done * 2], C, Mix, Width);
    Inc(Done, C);
  end;
end;

end.
