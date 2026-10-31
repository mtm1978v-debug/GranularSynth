{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.GfxAsm;

{ Schnelle Grafik-Kerne fuer die Banner-Animation.
  ContrastRow: jeder Farbkanal c -> sat((c * KFix) shr 6 + Offset), 0..255.
  Die Kontrastkurve ist linear -> SIMD-tauglich:
    ContrastRowPas   Referenz (Pascal)
    ContrastRowMMX   Win32, MMX: 2 Pixel je Schritt (MMX gibt es auf jedem PC seit Pentium MMX)
    ContrastRowSSE2  Win64, SSE2: 4 Pixel je Schritt (auf x64 immer vorhanden)
  KFix = Faktor * 64 (0..255), Offset darf negativ sein. Der Alphakanal wird mitgerechnet
  (fuer das deckende Banner bedeutungslos). }

interface

uses
  GR32;

type
  TContrastRowProc = procedure(P: PColor32; Count, KFix, Ofs: Integer);

  { Spektrum: FFT-Butterfly-Block (Count Paare, Count Vielfaches von 4):
      K = J + HalfBytes;  X = Tw * K;  K := J - X;  J := J + X   (komplex, getrennte Re/Im-Felder) }
  TFftButterflyProc = procedure(Re, Im: PSingle; HalfBytes: Integer; TwR, TwI: PSingle; Count: Integer);
  { Spektrum: Dst[i] := Re[i]^2 + Im[i]^2  (Count Vielfaches von 4) }
  TPowerSpecProc = procedure(Re, Im, Dst: PSingle; Count: Integer);
  { Filteransicht: Dst[i] := Src[i] + Glow[i] je Byte mit Saettigung (Hintergrund aufhellen) }
  TAddRowSatProc = procedure(Dst, Src, Glow: PColor32; Count: Integer);

procedure ContrastRowPas(P: PColor32; Count, KFix, Ofs: Integer);
procedure FftButterflyPas(Re, Im: PSingle; HalfBytes: Integer; TwR, TwI: PSingle; Count: Integer);
procedure PowerSpecPas(Re, Im, Dst: PSingle; Count: Integer);
procedure AddRowSatPas(Dst, Src, Glow: PColor32; Count: Integer);
{ Kantengeglaettete Kurve, spaltenweise: deckt in Spalte X den Bereich Y0..Y1 (Gleitkomma)
  mit 1 px Strichstaerke ab; Randpixel bekommen ihre Flaechendeckung als Alpha (Mischung
  ueber den MMX/SSE-Blender von Graphics32), das Innere ist eine einzige Fuelloperation. }
procedure AASpan(B: TCustomBitmap32; X: Integer; Y0, Y1: Single; Col: TColor32);
procedure InitGfx;

var
  ContrastRow: TContrastRowProc = ContrastRowPas;
  FftButterfly: TFftButterflyProc = FftButterflyPas;
  PowerSpec: TPowerSpecProc = PowerSpecPas;
  AddRowSat: TAddRowSatProc = AddRowSatPas;

implementation

uses
  Granular.DSP;   // CpuHasSSE (SSE impliziert MMX)

{$POINTERMATH ON}

procedure ContrastRowPas(P: PColor32; Count, KFix, Ofs: Integer);
var
  I, C, V: Integer;
  B: PByte;
begin
  B := PByte(P);
  for I := 0 to Count * 4 - 1 do
  begin
    C := B[I];
    V := ((C * KFix) shr 6) + Ofs;
    if V < 0 then V := 0 else if V > 255 then V := 255;
    B[I] := V;
  end;
end;

{$IF Defined(CPUX86)}
{ MMX: eax = P, edx = Count (gerade, s. ContrastRowFast), ecx = KFix, Offset auf dem Stack.
    mm7 = 0   mm6 = KFix (4 Worte)   mm5 = |Offset| (4 Worte)
  je 2 Pixel: Bytes -> Worte (punpck), * KFix (pmullw, < 65536), shr 6 (psrlw),
  +/- Offset mit Saettigung (paddusw/psubusw), zurueck zu Bytes (packuswb). }
procedure ContrastRowMMX(P: PColor32; Count, KFix, Ofs: Integer);
asm
        push    ebx
        mov     ebx, Ofs
        pxor    mm7, mm7
        movd    mm6, ecx
        punpcklwd mm6, mm6
        punpckldq mm6, mm6
        mov     ecx, edx
        shr     ecx, 1                  // Pixelpaare
        jz      @Tail
        test    ebx, ebx
        js      @NegSetup
        movd    mm5, ebx
        punpcklwd mm5, mm5
        punpckldq mm5, mm5
@PosLoop:
        movq    mm0, [eax]
        movq    mm1, mm0
        punpcklbw mm0, mm7
        punpckhbw mm1, mm7
        pmullw  mm0, mm6
        pmullw  mm1, mm6
        psrlw   mm0, 6
        psrlw   mm1, 6
        paddusw mm0, mm5
        paddusw mm1, mm5
        packuswb mm0, mm1
        movq    [eax], mm0
        add     eax, 8
        dec     ecx
        jnz     @PosLoop
        jmp     @Tail
@NegSetup:
        neg     ebx
        movd    mm5, ebx
        punpcklwd mm5, mm5
        punpckldq mm5, mm5
        neg     ebx
@NegLoop:
        movq    mm0, [eax]
        movq    mm1, mm0
        punpcklbw mm0, mm7
        punpckhbw mm1, mm7
        pmullw  mm0, mm6
        pmullw  mm1, mm6
        psrlw   mm0, 6
        psrlw   mm1, 6
        psubusw mm0, mm5
        psubusw mm1, mm5
        packuswb mm0, mm1
        movq    [eax], mm0
        add     eax, 8
        dec     ecx
        jnz     @NegLoop
@Tail:
        emms                            // MMX-Zustand freigeben (FPU wieder nutzbar)
@Done:
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ SSE2: rcx = P, edx = Count, r8d = KFix, r9d = Offset. Je 4 Pixel (16 Byte). }
procedure ContrastRowSSE2(P: PColor32; Count, KFix, Ofs: Integer);
asm
        pxor    xmm2, xmm2
        movd    xmm3, r8d
        pshuflw xmm3, xmm3, 0
        punpcklqdq xmm3, xmm3           // KFix in 8 Worten
        mov     eax, r9d
        test    eax, eax
        jns     @Pos
        neg     eax
@Pos:
        movd    xmm5, eax
        pshuflw xmm5, xmm5, 0
        punpcklqdq xmm5, xmm5           // |Offset| in 8 Worten
        mov     r10d, edx
        shr     r10d, 2                 // 4er-Gruppen
        jz      @Tail
@Loop:
        movdqu  xmm0, [rcx]
        movdqa  xmm1, xmm0
        punpcklbw xmm0, xmm2
        punpckhbw xmm1, xmm2
        pmullw  xmm0, xmm3
        pmullw  xmm1, xmm3
        psrlw   xmm0, 6
        psrlw   xmm1, 6
        test    r9d, r9d
        js      @Sub
        paddusw xmm0, xmm5
        paddusw xmm1, xmm5
        jmp     @Pack
@Sub:
        psubusw xmm0, xmm5
        psubusw xmm1, xmm5
@Pack:
        packuswb xmm0, xmm1
        movdqu  [rcx], xmm0
        add     rcx, 16
        dec     r10d
        jnz     @Loop
@Tail:
        and     edx, 3
        jz      @Done
@One:
        movd    xmm0, [rcx]
        punpcklbw xmm0, xmm2
        pmullw  xmm0, xmm3
        psrlw   xmm0, 6
        test    r9d, r9d
        js      @Sub1
        paddusw xmm0, xmm5
        jmp     @Pack1
@Sub1:
        psubusw xmm0, xmm5
@Pack1:
        packuswb xmm0, xmm0
        movd    [rcx], xmm0
        add     rcx, 4
        dec     edx
        jnz     @One
@Done:
end;
{$IFEND}

{$IF Defined(CPUX86)}
{ Huelle: MMX fuer die Paare, Pascal fuer ein evtl. ungerades letztes Pixel }
procedure ContrastRowFast(P: PColor32; Count, KFix, Ofs: Integer);
begin
  ContrastRowMMX(P, Count and not 1, KFix, Ofs);
  if Count and 1 <> 0 then
    ContrastRowPas(P + (Count - 1), 1, KFix, Ofs);
end;
{$IFEND}

procedure AASpan(B: TCustomBitmap32; X: Integer; Y0, Y1: Single; Col: TColor32);
var
  T, Top, Bot, Cov: Single;
  R0, R1, I: Integer;
  A0: Cardinal;
begin
  if Y0 > Y1 then
  begin
    T := Y0; Y0 := Y1; Y1 := T;
  end;
  Top := Y0 - 0.5;
  Bot := Y1 + 0.5;
  R0 := Trunc(Top + 1000) - 1000;          // floor ohne Math-Unit
  R1 := Trunc(Bot - 0.0001 + 1000) - 1000;
  A0 := Col shr 24;
  if R1 - R0 >= 2 then
    B.VertLineS(X, R0 + 1, R1 - 1, Col);
  for I := R0 to R1 do
  begin
    if (I > R0) and (I < R1) then
      Continue;
    if I + 1 < Bot then Cov := I + 1 else Cov := Bot;
    if I > Top then Cov := Cov - I else Cov := Cov - Top;
    if Cov >= 0.98 then
      B.PixelS[X, I] := Col
    else if Cov > 0.02 then
      B.SetPixelTS(X, I, (Col and $00FFFFFF) or (Cardinal(Round(Cov * A0)) shl 24));
  end;
end;

{ ---------------- Spektrum-Kerne ---------------- }

procedure FftButterflyPas(Re, Im: PSingle; HalfBytes: Integer; TwR, TwI: PSingle; Count: Integer);
var
  I, H: Integer;
  XR, XI, KR, KI: Single;
begin
  H := HalfBytes div SizeOf(Single);
  for I := 0 to Count - 1 do
  begin
    KR := Re[I + H];
    KI := Im[I + H];
    XR := KR * TwR[I] - KI * TwI[I];
    XI := KR * TwI[I] + KI * TwR[I];
    Re[I + H] := Re[I] - XR;
    Im[I + H] := Im[I] - XI;
    Re[I] := Re[I] + XR;
    Im[I] := Im[I] + XI;
  end;
end;

procedure PowerSpecPas(Re, Im, Dst: PSingle; Count: Integer);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    Dst[I] := Re[I] * Re[I] + Im[I] * Im[I];
end;

procedure AddRowSatPas(Dst, Src, Glow: PColor32; Count: Integer);
var
  I, V: Integer;
  D, S, G: PByte;
begin
  D := PByte(Dst); S := PByte(Src); G := PByte(Glow);
  for I := 0 to Count * 4 - 1 do
  begin
    V := S[I] + G[I];
    if V > 255 then V := 255;
    D[I] := V;
  end;
end;

{$IF Defined(CPUX86)}
{ MMX (paddusb), 2 Pixel je Schritt: eax = Dst, edx = Src, ecx = Glow, Count auf dem Stack (gerade) }
procedure AddRowSatMMX(Dst, Src, Glow: PColor32; Count: Integer);
asm
        push    ebx
        mov     ebx, Count
        shr     ebx, 1
        jz      @done
@loop:
        movq    mm0, [edx]
        paddusb mm0, [ecx]
        movq    [eax], mm0
        add     eax, 8
        add     edx, 8
        add     ecx, 8
        dec     ebx
        jnz     @loop
@done:
        emms
        pop     ebx
end;

procedure AddRowSatFast(Dst, Src, Glow: PColor32; Count: Integer);
begin
  AddRowSatMMX(Dst, Src, Glow, Count and not 1);
  if Count and 1 <> 0 then
    AddRowSatPas(Dst + (Count - 1), Src + (Count - 1), Glow + (Count - 1), 1);
end;
{$ELSEIF Defined(CPUX64)}
{ SSE2 (paddusb), 4 Pixel je Schritt: rcx = Dst, rdx = Src, r8 = Glow, r9d = Count }
procedure AddRowSatSSE2(Dst, Src, Glow: PColor32; Count: Integer);
asm
        mov     r10d, r9d
        shr     r10d, 2
        jz      @tail
@loop:
        movdqu  xmm0, [rdx]
        movdqu  xmm1, [r8]
        paddusb xmm0, xmm1
        movdqu  [rcx], xmm0
        add     rcx, 16
        add     rdx, 16
        add     r8, 16
        dec     r10d
        jnz     @loop
@tail:
        and     r9d, 3
        jz      @done
@one:
        movd    xmm0, [rdx]
        movd    xmm1, [r8]
        paddusb xmm0, xmm1
        movd    [rcx], xmm0
        add     rcx, 4
        add     rdx, 4
        add     r8, 4
        dec     r9d
        jnz     @one
@done:
end;
{$IFEND}

{$IF Defined(CPUX86)}
{ SSE1, 4 Butterflies je Schritt. eax = Re, edx = Im, ecx = HalfBytes, Rest auf dem Stack.
  Nur xmm0..xmm5 (gleiche Registerwahl wie x64). }
procedure FftButterflySSE(Re, Im: PSingle; HalfBytes: Integer; TwR, TwI: PSingle; Count: Integer);
asm
        push    ebx
        push    esi
        push    edi
        mov     esi, TwR
        mov     edi, TwI
        mov     ebx, Count
        shr     ebx, 2
        jz      @done
@loop:
        movups  xmm0, [eax+ecx]       // Kr
        movups  xmm1, [edx+ecx]       // Ki
        movups  xmm2, [esi]           // wr
        movups  xmm3, [edi]           // wi
        movaps  xmm4, xmm0
        mulps   xmm4, xmm2
        movaps  xmm5, xmm1
        mulps   xmm5, xmm3
        subps   xmm4, xmm5            // XR
        mulps   xmm0, xmm3
        mulps   xmm1, xmm2
        addps   xmm0, xmm1            // XI
        movups  xmm2, [eax]
        movaps  xmm3, xmm2
        subps   xmm2, xmm4
        addps   xmm3, xmm4
        movups  [eax+ecx], xmm2
        movups  [eax], xmm3
        movups  xmm2, [edx]
        movaps  xmm3, xmm2
        subps   xmm2, xmm0
        addps   xmm3, xmm0
        movups  [edx+ecx], xmm2
        movups  [edx], xmm3
        add     eax, 16
        add     edx, 16
        add     esi, 16
        add     edi, 16
        dec     ebx
        jnz     @loop
@done:
        pop     edi
        pop     esi
        pop     ebx
end;

{ SSE1: eax = Re, edx = Im, ecx = Dst, Count auf dem Stack }
procedure PowerSpecSSE(Re, Im, Dst: PSingle; Count: Integer);
asm
        push    ebx
        mov     ebx, Count
        shr     ebx, 2
        jz      @done
@loop:
        movups  xmm0, [eax]
        movups  xmm1, [edx]
        mulps   xmm0, xmm0
        mulps   xmm1, xmm1
        addps   xmm0, xmm1
        movups  [ecx], xmm0
        add     eax, 16
        add     edx, 16
        add     ecx, 16
        dec     ebx
        jnz     @loop
@done:
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ x64: rcx = Re, rdx = Im, r8d = HalfBytes, r9 = TwR, TwI/Count auf dem Stack. Nur xmm0..xmm5 (fluechtig). }
procedure FftButterflySSE(Re, Im: PSingle; HalfBytes: Integer; TwR, TwI: PSingle; Count: Integer);
asm
        mov     r10, TwI
        mov     r11d, Count
        movsxd  r8, r8d
        shr     r11d, 2
        jz      @done
@loop:
        movups  xmm0, [rcx+r8]
        movups  xmm1, [rdx+r8]
        movups  xmm2, [r9]
        movups  xmm3, [r10]
        movaps  xmm4, xmm0
        mulps   xmm4, xmm2
        movaps  xmm5, xmm1
        mulps   xmm5, xmm3
        subps   xmm4, xmm5
        mulps   xmm0, xmm3
        mulps   xmm1, xmm2
        addps   xmm0, xmm1
        movups  xmm2, [rcx]
        movaps  xmm3, xmm2
        subps   xmm2, xmm4
        addps   xmm3, xmm4
        movups  [rcx+r8], xmm2
        movups  [rcx], xmm3
        movups  xmm2, [rdx]
        movaps  xmm3, xmm2
        subps   xmm2, xmm0
        addps   xmm3, xmm0
        movups  [rdx+r8], xmm2
        movups  [rdx], xmm3
        add     rcx, 16
        add     rdx, 16
        add     r9, 16
        add     r10, 16
        dec     r11d
        jnz     @loop
@done:
end;

{ x64: rcx = Re, rdx = Im, r8 = Dst, r9d = Count }
procedure PowerSpecSSE(Re, Im, Dst: PSingle; Count: Integer);
asm
        shr     r9d, 2
        jz      @done
@loop:
        movups  xmm0, [rcx]
        movups  xmm1, [rdx]
        mulps   xmm0, xmm0
        mulps   xmm1, xmm1
        addps   xmm0, xmm1
        movups  [r8], xmm0
        add     rcx, 16
        add     rdx, 16
        add     r8, 16
        dec     r9d
        jnz     @loop
@done:
end;
{$IFEND}

procedure InitGfx;
begin
  {$IF Defined(CPUX86)}
  if CpuHasSSE then            // SSE-faehige CPU hat sicher MMX
  begin
    ContrastRow := ContrastRowFast;
    FftButterfly := FftButterflySSE;
    PowerSpec := PowerSpecSSE;
    AddRowSat := AddRowSatFast;
  end
  else
    ContrastRow := ContrastRowPas;
  {$ELSEIF Defined(CPUX64)}
  ContrastRow := ContrastRowSSE2;
  FftButterfly := FftButterflySSE;
  PowerSpec := PowerSpecSSE;
  AddRowSat := AddRowSatSSE2;
  {$ELSE}
  ContrastRow := ContrastRowPas;
  {$IFEND}
end;

initialization
  InitGfx;

end.
