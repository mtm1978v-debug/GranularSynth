{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.DSP;

{ Zeitkritische DSP-Kernroutinen.

  Datenformat (fuer SIMD gewaehlt):
    - Sample und Mischpuffer sind Stereo-INTERLEAVED (L R L R ...), damit ein Stereo-
      Frame-Paar mit einem einzigen 16-Byte-Load in ein SSE-Register passt.
    - Leseposition als 32.32-Festkomma (Int64): Ganzzahlteil = High-DWord (vorzeichen-
      behaftet), Bruchteil = Low-DWord. Spart das auf x87 sehr teure Trunc() und macht
      Pascal- und Assemblerpfad bitnah identisch.
    - Fensterposition als 16.16-Festkomma (Cardinal).

  Implementierungen mit IDENTISCHER Semantik:
    RenderGrainPas  - Referenz in Pascal (laeuft auf jeder CPU, wird mitgepflegt)
    RenderGrainSSE  - Win32: Assembler, nur SSE1 (ab Pentium III / Athlon XP)
                      Win64: eigener x64-Assembler (andere Aufrufkonvention/Register)
  Beim Start waehlt InitDSP per CPUID den schnellsten verfuegbaren Pfad.
  Aenderungen am Algorithmus IMMER in beiden Versionen nachziehen; der Benchmark
  (GranularHost.exe -bench) vergleicht die Ausgaben beider Pfade. }

interface

const
  WINDOW_TABLE_SIZE = 4096;  // Fenstertabelle hat WINDOW_TABLE_SIZE + 1 Eintraege
  FIX_ONE = 4294967296.0;    // 2^32 fuer 32.32-Festkomma
  WIN_FIX_SHIFT = 16;

type
  PGrainRenderArgs = ^TGrainRenderArgs;
  TGrainRenderArgs = record
    Src: PSingle;            // Sample interleaved L R L R ...
    SrcLast: Integer;        // letzter gueltiger Interpolationsindex (Frames - 2)
    PosFix: Int64;           // Leseposition 32.32, wird fortgeschrieben
    IncFix: Int64;           // Schrittweite 32.32 (negativ = rueckwaerts)
    Win: PSingle;            // Fenstertabelle
    WinPos: Cardinal;        // Fensterposition 16.16, wird fortgeschrieben
    WinInc: Cardinal;        // abgerundet -> Index bleibt < WINDOW_TABLE_SIZE
    Env: PSingle;            // unbenutzt: die Huellkurve wendet RenderGrains einmal je Stimme an
    GainL, GainR: Single;    // Panning * Velocity * Normierung
    Out: PSingle;            // Mischpuffer interleaved (wird addiert)
    Count: Integer;          // Anzahl Ausgabesamples (> 0)
  end;

  TGrainRenderProc = procedure(Args: PGrainRenderArgs);

  { Stereo-State-Variable-Filter (TPT/Zavalishin) auf interleaved Puffer, in-place.
    Ausgabe y = CX*x + CL*v2 (Tiefpass) + CB*v1 (Bandpass) - damit sind Tiefpass,
    Bandpass, Hochpass und die Kontur (trocken/gefiltert) ein einziger Kern.
    Alle Vektoren 4-fach [L R L R], damit SSE sie direkt laden kann. }
  PSvfArgs = ^TSvfArgs;
  TSvfArgs = record
    Buf: PSingle;                  // interleaved, wird ueberschrieben
    Count: Integer;                // Frames
    IC1, IC2: array[0..3] of Single;   // Zustand [L R - -]
    A1, A2, A3: array[0..3] of Single; // Koeffizienten
    MixX, MixL, MixB: array[0..3] of Single; // Ausgangsmischung (CX/CL waeren Registernamen!)
  end;

  TSvfProc = procedure(Args: PSvfArgs);

  { Stereo-Echo mit Ping-Pong und gedaempfter Rueckkopplung, in-place auf interleaved Puffer }
  PEchoArgs = ^TEchoArgs;
  TEchoArgs = record
    Buf: PSingle;                  // Verzoegerungsspeicher interleaved
    Len: Integer;                  // Laenge in Frames
    WritePos: Integer;
    Delay: Double;                 // aktuelle Verzoegerung (Samples), gleitet zu Target
    Target: Double;
    Feedback, Mix, DampCoef: Single;
    PingPong: Boolean;
    LP: array[0..1] of Single;     // Daempfungs-Tiefpass-Zustand
    // Pitch-Shifter in der Rueckkopplung (jede Wiederholung um Ratio transponiert)
    PBuf: PSingle;                 // interleaved, PLen Frames
    PLen: Integer;
    PWrite: Integer;
    PPhase: Double;                // 0..1, Saegezahn der beiden Lesekoepfe
    PRatio: Double;                // 1 = aus, 2 = Oktave hoch je Wiederholung
    IO: PSingle;                   // Audio interleaved, in-place
    Count: Integer;
  end;

procedure RenderGrainPas(Args: PGrainRenderArgs);
procedure RenderGrainSSE(Args: PGrainRenderArgs);
procedure RenderGrainHQPas(Args: PGrainRenderArgs);
procedure RenderGrainHQSSE(Args: PGrainRenderArgs);
procedure SvfBlockPas(Args: PSvfArgs);
procedure SvfBlockSSE(Args: PSvfArgs);
procedure EchoBlock(Args: PEchoArgs);

type
  { Saettigung: y = t(clamp(x * Drive, -3, 3)) * Makeup,  t(x) = x (27 + x^2) / (27 + 9 x^2)
    (rationale tanh-Naeherung, weich und ohne Tabellen). Count = Anzahl Werte, Vielfaches von 4. }
  PSatArgs = ^TSatArgs;
  TSatArgs = record
    P: PSingle;
    Count: Integer;
    Drive4, Make4, Hi4, Lo4, C27, C9: array[0..3] of Single;
  end;
  TSatProc = procedure(Args: PSatArgs);

  { weitere Saettigungs-Arten, Count = Vielfaches von 4:
      Kind 1 Roehre:  y = (t(clamp(x * Drive + Bias, Lo, Hi)) - Off) * Make   (asymmetrisch -> gerade Obertoene)
      Kind 2 Hart:    y = clamp(x * Drive, -1, 1) * Make
      Kind 3 Faltung: y = zweimal an +/-1 gespiegelt (Wavefolder), vorher clamp(x * Drive, Lo, Hi) }
  PShapeArgs = ^TShapeArgs;
  TShapeArgs = record
    P: PSingle;
    Count: Integer;
    Kind: Integer;
    Drive4, Make4, Bias4, Off4, Hi4, Lo4, C27, C9, One4, MOne4, Zero4: array[0..3] of Single;
  end;
  TShapeProc = procedure(Args: PShapeArgs);

procedure SatBlockPas(Args: PSatArgs);
procedure SatBlockSSE(Args: PSatArgs);
procedure ShapeBlockPas(Args: PShapeArgs);
procedure ShapeBlockSSE(Args: PShapeArgs);

type
  { Huellkurven-Abschnitt (eine Stufe ohne Wechsel): je 4 Werte  x = Base + D;  Raw = x;  Gain = x * G;
    danach D = D * Mul + Add.  Geometrisch (Decay/Sustain/Release): Base = Ziel, D = (E-Ziel)*[k,k2,k3,k4],
    Mul = k4, Add = 0.  Linear (Attack): Base = E, D = Inc*[1,2,3,4], Mul = 1, Add = 4*Inc.
    Count = Anzahl 4er-Gruppen (der Aufrufer rundet auf, die Puffer haben 4 Werte Reserve). }
  PEnvSegArgs = ^TEnvSegArgs;
  TEnvSegArgs = record
    Raw, Gain: PSingle;
    Count: Integer;
    Base4, D4, Mul4, Add4, G4: array[0..3] of Single;
  end;
  TEnvSegProc = procedure(Args: PEnvSegArgs);

procedure EnvSegPas(Args: PEnvSegArgs);
procedure EnvSegSSE(Args: PEnvSegArgs);

type
  { Oszillator einer Stimme ueber einen Block: Welle 0 Sinus, 1 Dreieck, 2 Saegezahn (PolyBLEP),
    3 Rechteck (PolyBLEP), 4 FM (Traeger-Sinus, Index * Huellkurve * Sinus des Modulators),
    5 weisses Rauschen (LCG 32 Bit, Seed im Record, Skalierung CInv31).
    Env = fertige Verstaerkung je Sample, EnvRaw = Huellkurve 0..1 (FM-Helligkeit).
    Out += Sample * Env * GL/GR (interleaved). Sinus aus Tabelle (4096 + 2 Eintraege, linear).
    Hard Sync: die Welle wird mit der Phase frac(Ph * SyncR) gelesen (Ph = Grundton-Phase, Schritt
    DtP) - das ist genau eine Folgewelle, die am Periodenanfang des Grundtons neu startet. }
  POscArgs = ^TOscArgs;
  TOscArgs = record
    Out, Env, EnvRaw, Tab: PSingle;
    Count, Wave: Integer;
    Ph, PhM, Dt, DtM, FmIdx, GL, GR: Single;
    C1, CM1, C4, CHalf, CTab: Single;
    AbsMask4: array[0..3] of Cardinal;
    Seed: Integer;
    CInv31: Single;
    DtP: Single;         // Phasenschritt des Grundtons (Dt = Schritt der Sync-Welle, fuer PolyBLEP)
    SyncR: Single;       // Hard Sync: Welle laeuft SyncR-mal je Periode und startet am Periodenanfang neu (1 = aus)
  end;
  TOscProc = procedure(Args: POscArgs);

procedure OscBlockPas(Args: POscArgs);
procedure OscBlockSSE(Args: POscArgs);

const
  { 2x-Oversampling (HQ): Halbband-FIR, 71 Taps, Kaiser beta 9.9. Durchlass bis 0.204 fs (18 kHz bei
    44,1 kHz, Welligkeit < 0.001 dB), Sperrbereich ab 0.296 fs mit -98 dB. Halbband: jeder zweite Tap ist 0,
    die Mitte ist 0.5, uebrig bleiben 18 symmetrische Paare. Laufzeit: 17,5 Samples je Richtung (1x). }
  HB_PAIRS = 18;
  HB_CENTER = 0.5;
  HB_COEF: array[0..HB_PAIRS - 1] of Single = (
    3.1709224099e-01, -1.0250110361e-01, 5.7820710782e-02, -3.7622097114e-02, 2.5803055745e-02, -1.7997620298e-02,
    1.2529103597e-02, -8.6017102024e-03, 5.7713455965e-03, -3.7541832321e-03, 2.3482626878e-03, -1.3991763525e-03,
    7.8459184537e-04, -4.0705123099e-04, 1.9021596996e-04, -7.6273172237e-05, 2.3486292349e-05, -3.5512258218e-06
  );
  HB_HIST = 2 * HB_PAIRS;   // Vorlauf in Frames: Abwaerts 2*36 (2x), Aufwaerts 36 (1x)

type
  { Symmetrischer FIR auf Stereo-Frames (interleaved L/R), je Ausgabe-Frame i:
      y = C4[0] * PC[i] + Summe k=1..HB_PAIRS  C4[k] * (PD[i] - (k-1)*Tap  +  PA[i] + (k-1)*Tap)
    PD/PA/PC ruecken je Ausgabe um InStep Bytes vor, Out um OutStep Bytes, Tap in Bytes.
    Abwaerts (2x -> 1x): InStep = Tap = 2 Frames. Aufwaerts (gerade Ausgaben): InStep = Tap = 1 Frame,
    OutStep = 2 Frames. Die Zeiger im Record stehen danach hinter dem letzten Frame. }
  PHbArgs = ^THbArgs;
  THbArgs = record
    Out, PD, PA, PC: PByte;
    Count, Pairs: Integer;        // Pairs: Arbeitszaehler des SSE-Kerns
    InStep, TapStep, OutStep: Integer;
    C4: array[0..HB_PAIRS, 0..3] of Single;
  end;
  THbProc = procedure(Args: PHbArgs);

procedure HbFirPas(Args: PHbArgs);
procedure HbFirSSE(Args: PHbArgs);

const
  { Bandbegrenzte Wavetables (eingebaute Wellen Dreieck/Saege/Rechteck und gezeichnete Wellen):
    WT_MIPS Stufen im Abstand einer Sechstel-Oktave; Stufe m enthaelt nur die Obertoene 1..WT_HARM[m].
    Jede Stufe hat mindestens 16 Punkte je Periode ihres hoechsten Obertons (WT_LEN, Zweierpotenz, mind.
    2048), damit die lineare Interpolation auch bei tiefen Toenen sauber bleibt. Ablage hintereinander
    ab WT_OFS[m], je WT_LEN[m] + 2 Werte (2 Schutzwerte = Anfang wiederholt).
    Auswahl (siehe Engine): Stufe a = floor(Mf), Mf = 6 log2(WT_HARM[0] * 2 * Schritt / WT_MARGIN), ueberblendet
    zur naechsten. Mit WT_MARGIN = 0,87 bleibt die reichere Stufe unter 0,98 der halben Abtastrate (keine
    Spiegelungen), und alle Obertoene bis 0,78 der halben Abtastrate (17 kHz bei 44,1 kHz) klingen voll. }
  WT_MIPS = 61;
  WT_HARM: array[0..WT_MIPS - 1] of Integer = (
    1023, 911, 812, 723, 644, 574, 512, 456, 406, 362, 322, 287, 256, 228, 203, 181, 161, 144, 128,
    114, 101, 90, 81, 72, 64, 57, 51, 45, 40, 36, 32, 28, 25, 23, 20, 18, 16, 14, 13, 11, 10, 9, 8, 7,
    6, 6, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1);
  WT_LEN: array[0..WT_MIPS - 1] of Integer = (
    16384, 16384, 16384, 16384, 16384, 16384, 8192, 8192, 8192, 8192, 8192, 8192, 4096, 4096, 4096,
    4096, 4096, 4096, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048,
    2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048,
    2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048);
  WT_OFS: array[0..WT_MIPS - 1] of Integer = (
    0, 16386, 32772, 49158, 65544, 81930, 98316, 106510, 114704, 122898, 131092, 139286, 147480,
    151578, 155676, 159774, 163872, 167970, 172068, 174118, 176168, 178218, 180268, 182318, 184368,
    186418, 188468, 190518, 192568, 194618, 196668, 198718, 200768, 202818, 204868, 206918, 208968,
    211018, 213068, 215118, 217168, 219218, 221268, 223318, 225368, 227418, 229468, 231518, 233568,
    235618, 237668, 239718, 241768, 243818, 245868, 247918, 249968, 252018, 254068, 256118, 258168);
  WT_TOTAL = 260218;
  WT_MARGIN = 0.87;

type
  { Wavetable-Oszillator einer Stimme ueber einen Block (Stereo interleaved, addierend):
      w = frac(Ph * SyncR); a = Tab A linear bei w * CSizeA; b = Tab B linear bei w * CSizeB;
      Wert = a + (b - a) * Mix (Ueberblenden zweier benachbarter Stufen, kein Sprung beim Gleiten);
      Out += Wert * Env * GL/GR; danach Ph += DtP (Ph < 1). }
  PWtArgs = ^TWtArgs;
  TWtArgs = record
    Out, Env, TabA, TabB: PSingle;
    Count: Integer;
    Ph, DtP, SyncR, GL, GR, CSizeA, CSizeB, Mix, One: Single;
  end;
  TWtProc = procedure(Args: PWtArgs);

procedure WtBlockPas(Args: PWtArgs);
procedure WtBlockSSE(Args: PWtArgs);
{ schneller Pfad ohne Sync (SyncR = 1) und mit gleich langen Tabellen (CSizeA = CSizeB): ein Index fuer beide }
procedure WtFastPas(Args: PWtArgs);
procedure WtFastSSE(Args: PWtArgs);
{ alle Stufen aus Obertoenen bauen: x(w) = Summe k  A[k] cos(2 pi k w) + B[k] sin(2 pi k w), k = 1..NH
  (Index 0 von A/B ungenutzt). Normalize: Spitze der reichsten Stufe = 1. Nicht im Audio-Thread. }
procedure WtBuild(const A, B: array of Double; NH: Integer; Dst: PSingle; Normalize: Boolean);
{ Obertoene einer Periode aus N Punkten (N Zweierpotenz): A[k], B[k] fuer k = 1..N div 2 - 1 }
procedure WtAnalyze(const X: array of Single; N: Integer; var A, B: array of Double);
{ Koeffizienten setzen: Scale 1 = Abwaerts, 2 = Aufwaerts (Nullen eingefuegt -> Pegel x2) }
procedure HbInitArgs(var A: THbArgs; Scale, Center: Single);

type
  { Kammfilter (Filtertyp 'Kamm'), Stereo interleaved in-place:
      d = Verzoegerung (DInt + Frac Frames, linear interpoliert),  y = x + Fb * d,
      Ring[Schreibposition] = y,  Ausgabe = MixX * x + MixW * y.
    Ring: Mask + 1 Frames (Zweierpotenz) interleaved; DInt >= 1, DInt + 1 <= Mask. }
  PCombArgs = ^TCombArgs;
  TCombArgs = record
    IO: PSingle;
    Count: Integer;
    Buf: PSingle;
    Mask: Integer;
    WritePos: Integer;
    DInt: Integer;
    Frac, Fb, MixX, MixW: Single;
  end;
  TCombProc = procedure(Args: PCombArgs);

procedure CombBlockPas(Args: PCombArgs);
procedure CombBlockSSE(Args: PCombArgs);

type
  { Phaser, Stereo interleaved in-place: je Sample y = x + Fb * Last, dann sechs Allpaesse erster Ordnung
    (s = a * (y - Y1[k]) + X1[k];  X1[k] = y;  Y1[k] = s;  y = s), Last = y,
    Ausgabe = Dry * x + Wet * y; Koeffizient a gleitet je Sample um DA (Spur 0 = links, 1 = rechts).
    Alle Vektoren 4-fach, benutzt werden die Spuren 0 und 1. }
  PPhaserArgs = ^TPhaserArgs;
  TPhaserArgs = record
    IO: PSingle;
    Count: Integer;
    A4, DA4, Fb4, Dry4, Wet4: array[0..3] of Single;
    X1, Y1: array[0..5, 0..1] of Single;
    Last: array[0..1] of Single;
  end;
  TPhaserProc = procedure(Args: PPhaserArgs);

procedure PhaserBlockPas(Args: PPhaserArgs);
procedure PhaserBlockSSE(Args: PPhaserArgs);

type
  { Chorus, Stereo interleaved in-place, nur 32-Bit-Ganzzahlen fuer die Verzoegerung:
      Ph += PhInc (32 Bit, Ueberlauf = Periode); je Kanal p = Ph + c * 2^30 (rechts 90 Grad),
      Dreieck t = p < 2^31 ? p : not p;  d = Base8 + (Span8 * (t shr 19)) shr 12  (1/256 Samples),
      Lesen linear zwischen Ring[W - d div 256] und Ring[W - d div 256 - 1],
      Ring[W] = x + Fb * y,  Ausgabe = Dry * x + Wet * y.  Ring = Mask + 1 Frames interleaved. }
  PChorusArgs = ^TChorusArgs;
  TChorusArgs = record
    IO: PSingle;
    Count: Integer;
    Buf: PSingle;
    Mask: Integer;
    W: Integer;
    Ph, PhInc, Base8, Span8: Cardinal;
    Fb, Dry, Wet, Inv256: Single;
  end;
  TChorusProc = procedure(Args: PChorusArgs);

procedure ChorusBlockPas(Args: PChorusArgs);
procedure ChorusBlockSSE(Args: PChorusArgs);

{ Interleaved -> getrennte Kanaele (VST2-Ausgabe), Pascal genuegt hier }
procedure Deinterleave(Src, OutL, OutR: PSingle; Frames: Integer);

function CpuHasSSE: Boolean;
function CpuHasSSE2: Boolean;
procedure InitDSP(AllowSSE: Boolean = True);

var
  { Austauschbarer Zeiger, gesetzt von InitDSP }
  RenderGrain: TGrainRenderProc = RenderGrainPas;
  RenderGrainHQ: TGrainRenderProc = RenderGrainHQPas;
  RenderSvf: TSvfProc = SvfBlockPas;
  RenderSat: TSatProc = SatBlockPas;
  RenderShape: TShapeProc = ShapeBlockPas;
  RenderOscBlock: TOscProc = OscBlockPas;
  RenderEnvSeg: TEnvSegProc = EnvSegPas;
  RenderComb: TCombProc = CombBlockPas;
  RenderPhaser: TPhaserProc = PhaserBlockPas;
  RenderChorus: TChorusProc = ChorusBlockPas;
  RenderHbFir: THbProc = HbFirPas;
  RenderWt: TWtProc = WtBlockPas;
  RenderWtFast: TWtProc = WtFastPas;
  DSPPathName: string = 'Pascal';

implementation

uses
  System.Math, Granular.Reverb, Granular.Eq;

{$POINTERMATH ON}

const
  FRAC_SCALE: Single = 1 / 16777216;   // 24-Bit-Bruchteil -> 0..1
  HQ_HALF: array[0..3] of Single = (0.5, 0.5, 0.5, 0.5);
  PITCH_WIN = 1024;                    // Fensterlaenge des Echo-Pitch-Shifters (Samples)

{ ------------------------------------------------------------------------------
  Referenzimplementierung (Pascal)
  ------------------------------------------------------------------------------ }
procedure RenderGrainPas(Args: PGrainRenderArgs);
var
  I, Ip: Integer;
  Pos: Int64;
  WinPos: Cardinal;
  Fr, A, L0, R0: Single;
  Src, Win, Out: PSingle;
begin
  Src := Args.Src;
  Win := Args.Win;
  Out := Args.Out;
  Pos := Args.PosFix;
  WinPos := Args.WinPos;
  for I := 0 to Args.Count - 1 do
  begin
    Ip := Integer(Pos shr 32);                                   // Ganzzahlteil (signed)
    if Cardinal(Ip) <= Cardinal(Args.SrcLast) then               // unsigned: faengt Ip < 0 mit ab
    begin
      Fr := (Cardinal(Pos) shr 8) * FRAC_SCALE;                  // Bruchteil, 24 Bit
      L0 := Src[Ip * 2];
      R0 := Src[Ip * 2 + 1];
      L0 := L0 + (Src[Ip * 2 + 2] - L0) * Fr;                    // lineare Interpolation
      R0 := R0 + (Src[Ip * 2 + 3] - R0) * Fr;
      A := Win[WinPos shr WIN_FIX_SHIFT];       // Huellkurve der Stimme: spaeter einmal je Stimme
      Out[I * 2]     := Out[I * 2]     + L0 * (A * Args.GainL);
      Out[I * 2 + 1] := Out[I * 2 + 1] + R0 * (A * Args.GainR);
    end;
    Inc(Pos, Args.IncFix);
    Inc(WinPos, Args.WinInc);
  end;
  Args.PosFix := Pos;
  Args.WinPos := WinPos;
end;

{ ------------------------------------------------------------------------------
  SSE1-Version (Win32 Assembler). Pro Ausgabesample:
    xmm0 = [L0 R0 L1 R1]  (ein 16-Byte-Load holt beide Frames beider Kanaele)
    xmm0 = a + (b - a) * fr  -> Lanes 0/1 = interpolierte L/R
    xmm3 = Win * Env * [GainL GainR]
    Out[0..1] += xmm0 * xmm3   (movlps: 2 Floats lesen/schreiben)
  Register: eax/edx = Position lo/hi, esi = Src, edi = Out, ebx = Env, ecx = Hilfs.
  Zaehler, Schrittweite und Fensterwerte liegen in lokalen Variablen.
  Pascal-Entsprechung jeder Gruppe steht als Kommentar daneben.
  ------------------------------------------------------------------------------ }
{$IF Defined(CPUX86)}
{ Schleifenzustand nur in Registern (Fensterposition in ebx, Ende als Zeiger) - frueher lagen
  Fensterposition und Zaehler im Speicher und wurden je Sample gelesen UND geschrieben, was auf
  aelteren CPUs jede Runde auf den vorigen Speicherzugriff warten liess. Die Huellkurve der Stimme
  ist nicht mehr hier (RenderGrains multipliziert die Summe aller Grains einer Stimme einmal). }
procedure RenderGrainSSE(Args: PGrainRenderArgs);
var
  OutEnd, IncLo, IncHi, WinInc, WinBase, SrcLast: Cardinal;
  Gains: array[0..3] of Single;
asm
        push    ebx
        push    esi
        push    edi
        mov     ecx, eax                            // ecx = Args

        mov     eax, [ecx].TGrainRenderArgs.Count   // OutEnd = Out + Count * 8
        shl     eax, 3
        add     eax, [ecx].TGrainRenderArgs.Out
        mov     OutEnd, eax
        mov     eax, dword ptr [ecx].TGrainRenderArgs.IncFix
        mov     IncLo, eax
        mov     eax, dword ptr [ecx].TGrainRenderArgs.IncFix + 4
        mov     IncHi, eax
        mov     eax, [ecx].TGrainRenderArgs.WinInc
        mov     WinInc, eax
        mov     eax, [ecx].TGrainRenderArgs.Win
        mov     WinBase, eax
        mov     eax, [ecx].TGrainRenderArgs.SrcLast
        mov     SrcLast, eax
        mov     eax, [ecx].TGrainRenderArgs.GainL      // Gains = [GL GR GL GR]
        mov     dword ptr Gains, eax
        mov     dword ptr Gains + 8, eax
        mov     eax, [ecx].TGrainRenderArgs.GainR
        mov     dword ptr Gains + 4, eax
        mov     dword ptr Gains + 12, eax
        movups  xmm7, Gains
        movss   xmm6, FRAC_SCALE

        mov     esi, [ecx].TGrainRenderArgs.Src
        mov     edi, [ecx].TGrainRenderArgs.Out
        mov     ebx, [ecx].TGrainRenderArgs.WinPos
        push    ecx                                 // Args fuer das Zurueckschreiben merken
        mov     eax, dword ptr [ecx].TGrainRenderArgs.PosFix
        mov     edx, dword ptr [ecx].TGrainRenderArgs.PosFix + 4

@Loop:
        // if Cardinal(Ip) <= Cardinal(SrcLast) then
        cmp     edx, SrcLast
        ja      @Skip

        // Fr := (Cardinal(Pos) shr 8) * FRAC_SCALE   -> in alle 4 Lanes
        mov     ecx, eax
        shr     ecx, 8
        cvtsi2ss xmm1, ecx
        mulss   xmm1, xmm6
        shufps  xmm1, xmm1, 0

        // L0/R0/L1/R1 laden, interpolieren: a + (b - a) * Fr
        movups  xmm0, [esi + edx * 8]
        movhlps xmm2, xmm0
        subps   xmm2, xmm0
        mulps   xmm2, xmm1
        addps   xmm0, xmm2

        // A := Win[WinPos shr 16] * [GainL GainR]
        mov     ecx, ebx
        shr     ecx, WIN_FIX_SHIFT
        shl     ecx, 2
        add     ecx, WinBase
        movss   xmm3, [ecx]
        shufps  xmm3, xmm3, 0
        mulps   xmm3, xmm7
        mulps   xmm0, xmm3

        // Out[I*2], Out[I*2+1] += ...
        movlps  xmm4, [edi]
        addps   xmm4, xmm0
        movlps  [edi], xmm4

@Skip:
        add     edi, 8                              // naechster Stereo-Frame
        add     eax, IncLo                          // Inc(Pos, IncFix)  (64 Bit)
        adc     edx, IncHi
        add     ebx, WinInc                         // Inc(WinPos, WinInc) - im Register
        cmp     edi, OutEnd
        jb      @Loop

        pop     ecx                                 // Args.PosFix / Args.WinPos zurueck
        mov     dword ptr [ecx].TGrainRenderArgs.PosFix, eax
        mov     dword ptr [ecx].TGrainRenderArgs.PosFix + 4, edx
        mov     [ecx].TGrainRenderArgs.WinPos, ebx

        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ ------------------------------------------------------------------------------
  x64-Version (SSE, auf x64 immer vorhanden). Microsoft-x64-Konvention: Args in RCX.
  Die 32.32-Position passt hier in EIN Register (r8) - kein add/adc-Paar noetig.
    r8  = PosFix      r9  = IncFix       r10d = WinPos     r11d = WinInc
    rsi = Src         rdi = Out          rbx  = Env        rdx  = Fenstertabelle
    r12 = Args        r13d = SrcLast     r14d = Zaehler    r15  = Hilfs
    xmm4 = [GainL GainR GainL GainR]     xmm5 = FRAC_SCALE xmm0..3 = Hilfs
  Nur fluechtige XMM-Register -> kein Sichern von xmm6..15 noetig.
  ------------------------------------------------------------------------------ }
procedure RenderGrainSSE(Args: PGrainRenderArgs);
asm
        .PUSHNV rbx
        .PUSHNV rsi
        .PUSHNV rdi
        .PUSHNV r12
        .PUSHNV r13
        .PUSHNV r14
        .PUSHNV r15
        mov     r12, rcx
        mov     r14d, [r12].TGrainRenderArgs.Count
        test    r14d, r14d
        jz      @Done
        mov     rsi, [r12].TGrainRenderArgs.Src
        mov     rdi, [r12].TGrainRenderArgs.Out
        mov     rdx, [r12].TGrainRenderArgs.Win
        mov     r8,  [r12].TGrainRenderArgs.PosFix
        mov     r9,  [r12].TGrainRenderArgs.IncFix
        mov     r10d, [r12].TGrainRenderArgs.WinPos
        mov     r11d, [r12].TGrainRenderArgs.WinInc
        mov     r13d, [r12].TGrainRenderArgs.SrcLast
        movss   xmm4, [r12].TGrainRenderArgs.GainL      // xmm4 = [GL GR GL GR]
        movss   xmm0, [r12].TGrainRenderArgs.GainR
        unpcklps xmm4, xmm0
        movlhps xmm4, xmm4
        movss   xmm5, FRAC_SCALE

@Loop:
        // Ip := Integer(Pos shr 32); if Cardinal(Ip) <= Cardinal(SrcLast) then
        mov     rax, r8
        sar     rax, 32
        cmp     eax, r13d
        ja      @Skip

        // Fr := (Cardinal(Pos) shr 8) * FRAC_SCALE
        mov     r15d, r8d
        shr     r15d, 8
        cvtsi2ss xmm1, r15d
        mulss   xmm1, xmm5
        shufps  xmm1, xmm1, 0

        // [L0 R0 L1 R1] laden, interpolieren
        movups  xmm0, [rsi + rax * 8]
        movhlps xmm2, xmm0
        subps   xmm2, xmm0
        mulps   xmm2, xmm1
        addps   xmm0, xmm2

        // A := Win[WinPos shr 16] * [GainL GainR]
        mov     r15d, r10d
        shr     r15d, WIN_FIX_SHIFT
        movss   xmm3, [rdx + r15 * 4]
        shufps  xmm3, xmm3, 0
        mulps   xmm3, xmm4
        mulps   xmm0, xmm3

        // Out += ...
        movlps  xmm2, [rdi]
        addps   xmm2, xmm0
        movlps  [rdi], xmm2

@Skip:
        add     rdi, 8
        add     r8, r9                                  // Inc(Pos, IncFix) - ein 64-Bit-Add
        add     r10d, r11d                              // Inc(WinPos, WinInc)
        dec     r14d
        jnz     @Loop

        mov     [r12].TGrainRenderArgs.PosFix, r8
        mov     [r12].TGrainRenderArgs.WinPos, r10d
@Done:
end;
{$ELSE}
procedure RenderGrainSSE(Args: PGrainRenderArgs);
begin
  RenderGrainPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  HQ-Kern: 4-Punkt-Hermite-Interpolation (statt linear) - deutlich sauberer bei
  starker Transposition (weniger Aliasing/Rauhigkeit), braucht Ip-1 .. Ip+2.
  Gueltigkeitsbereich: SrcLast = Frames - 3 und Ip >= 1, also
  Cardinal(Ip - 1) <= Cardinal(SrcLast - 1).
  Optimierte Form (Niemitalo, "x-form"), mathematisch gleich der Standard-Hermite,
  braucht aber nur die Konstante 0.5:
    c1 = (y1 - ym1) * 0.5
    v  = y0 - y1
    w  = c1 + v
    a  = w + v + (y2 - y0) * 0.5
    b  = w + a
    y  = ((a * f - b) * f + c1) * f + y0
  ------------------------------------------------------------------------------ }
procedure RenderGrainHQPas(Args: PGrainRenderArgs);
var
  I, Ip, C: Integer;
  Pos: Int64;
  WinPos: Cardinal;
  F, A, Ym1, Y0, Y1, Y2, C1, Vd, W, Ac, Bc, V: Single;
  Src, Win, Out: PSingle;
begin
  Src := Args.Src;
  Win := Args.Win;
  Out := Args.Out;
  Pos := Args.PosFix;
  WinPos := Args.WinPos;
  for I := 0 to Args.Count - 1 do
  begin
    Ip := Integer(Pos shr 32);
    if Cardinal(Ip - 1) <= Cardinal(Args.SrcLast - 1) then
    begin
      F := (Cardinal(Pos) shr 8) * FRAC_SCALE;
      A := Win[WinPos shr WIN_FIX_SHIFT];
      for C := 0 to 1 do
      begin
        Ym1 := Src[(Ip - 1) * 2 + C];
        Y0 := Src[Ip * 2 + C];
        Y1 := Src[(Ip + 1) * 2 + C];
        Y2 := Src[(Ip + 2) * 2 + C];
        C1 := (Y1 - Ym1) * 0.5;
        Vd := Y0 - Y1;
        W := C1 + Vd;
        Ac := W + Vd + (Y2 - Y0) * 0.5;
        Bc := W + Ac;
        V := ((Ac * F - Bc) * F + C1) * F + Y0;
        if C = 0 then
          Out[I * 2] := Out[I * 2] + V * (A * Args.GainL)
        else
          Out[I * 2 + 1] := Out[I * 2 + 1] + V * (A * Args.GainR);
      end;
    end;
    Inc(Pos, Args.IncFix);
    Inc(WinPos, Args.WinInc);
  end;
  Args.PosFix := Pos;
  Args.WinPos := WinPos;
end;

{$IF Defined(CPUX86)}
{ HQ, Win32/SSE1. Beide Kanaele parallel in Lanes 0/1:
    xmm0 = ym1  xmm1 = y0  xmm2 = y1  xmm3 = y2  (zwei 16-Byte-Loads + movhlps)
    xmm4 = c1   xmm5 = c3 -> Ergebnis   xmm0 = c2   xmm7 = Konstante bzw. f
  f wird erst nach den Koeffizienten berechnet - so reichen 8 XMM-Register. }
procedure RenderGrainHQSSE(Args: PGrainRenderArgs);
var
  OutEnd, IncLo, IncHi, WinInc, WinBase, Last1: Cardinal;
  Gains: array[0..3] of Single;
asm
        push    ebx
        push    esi
        push    edi
        mov     ecx, eax
        mov     eax, [ecx].TGrainRenderArgs.Count   // OutEnd = Out + Count * 8
        shl     eax, 3
        add     eax, [ecx].TGrainRenderArgs.Out
        mov     OutEnd, eax
        mov     eax, dword ptr [ecx].TGrainRenderArgs.IncFix
        mov     IncLo, eax
        mov     eax, dword ptr [ecx].TGrainRenderArgs.IncFix + 4
        mov     IncHi, eax
        mov     eax, [ecx].TGrainRenderArgs.WinInc
        mov     WinInc, eax
        mov     eax, [ecx].TGrainRenderArgs.Win
        mov     WinBase, eax
        mov     eax, [ecx].TGrainRenderArgs.SrcLast
        dec     eax
        mov     Last1, eax                          // SrcLast - 1
        mov     eax, [ecx].TGrainRenderArgs.GainL
        mov     dword ptr Gains, eax
        mov     dword ptr Gains + 8, eax
        mov     eax, [ecx].TGrainRenderArgs.GainR
        mov     dword ptr Gains + 4, eax
        mov     dword ptr Gains + 12, eax
        mov     esi, [ecx].TGrainRenderArgs.Src
        mov     edi, [ecx].TGrainRenderArgs.Out
        mov     ebx, [ecx].TGrainRenderArgs.WinPos
        push    ecx
        mov     eax, dword ptr [ecx].TGrainRenderArgs.PosFix
        mov     edx, dword ptr [ecx].TGrainRenderArgs.PosFix + 4
@Loop:
        // if Cardinal(Ip - 1) <= Cardinal(SrcLast - 1) then
        lea     ecx, [edx - 1]
        cmp     ecx, Last1
        ja      @Skip
        // ym1, y0, y1, y2 (je [L R])
        movups  xmm0, [esi + edx * 8 - 8]
        movhlps xmm1, xmm0
        movups  xmm2, [esi + edx * 8 + 8]
        movhlps xmm3, xmm2
        movups  xmm7, HQ_HALF
        // c1 = (y1 - ym1) * 0.5                         -> xmm4
        movaps  xmm4, xmm2
        subps   xmm4, xmm0
        mulps   xmm4, xmm7
        // v = y0 - y1                                   -> xmm5
        movaps  xmm5, xmm1
        subps   xmm5, xmm2
        // w = c1 + v                                    -> xmm6
        movaps  xmm6, xmm4
        addps   xmm6, xmm5
        // a = w + v + (y2 - y0) * 0.5                   -> xmm5
        subps   xmm3, xmm1
        mulps   xmm3, xmm7
        addps   xmm5, xmm6
        addps   xmm5, xmm3
        // b = w + a                                     -> xmm6
        addps   xmm6, xmm5
        // f = (Cardinal(Pos) shr 8) * FRAC_SCALE        -> xmm7
        mov     ecx, eax
        shr     ecx, 8
        cvtsi2ss xmm7, ecx
        mulss   xmm7, FRAC_SCALE
        shufps  xmm7, xmm7, 0
        // y = ((a * f - b) * f + c1) * f + y0           -> xmm5
        mulps   xmm5, xmm7
        subps   xmm5, xmm6
        mulps   xmm5, xmm7
        addps   xmm5, xmm4
        mulps   xmm5, xmm7
        addps   xmm5, xmm1
        // A = Win * [GainL GainR]
        mov     ecx, ebx
        shr     ecx, WIN_FIX_SHIFT
        shl     ecx, 2
        add     ecx, WinBase
        movss   xmm3, [ecx]
        shufps  xmm3, xmm3, 0
        movups  xmm6, Gains
        mulps   xmm3, xmm6
        mulps   xmm5, xmm3
        movlps  xmm2, [edi]
        addps   xmm2, xmm5
        movlps  [edi], xmm2
@Skip:
        add     edi, 8
        add     eax, IncLo
        adc     edx, IncHi
        add     ebx, WinInc                         // Fensterposition im Register
        cmp     edi, OutEnd
        jb      @Loop
        pop     ecx
        mov     dword ptr [ecx].TGrainRenderArgs.PosFix, eax
        mov     dword ptr [ecx].TGrainRenderArgs.PosFix + 4, edx
        mov     [ecx].TGrainRenderArgs.WinPos, ebx
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ HQ, x64: wie Win32, Position in r8 (ein 64-Bit-Register), xmm6/xmm7 gesichert. }
procedure RenderGrainHQSSE(Args: PGrainRenderArgs);
asm
        .PUSHNV rbx
        .PUSHNV rsi
        .PUSHNV rdi
        .PUSHNV r12
        .PUSHNV r13
        .PUSHNV r14
        .PUSHNV r15
        .SAVENV xmm6
        .SAVENV xmm7
        mov     r12, rcx
        mov     r14d, [r12].TGrainRenderArgs.Count
        test    r14d, r14d
        jz      @Done
        mov     rsi, [r12].TGrainRenderArgs.Src
        mov     rdi, [r12].TGrainRenderArgs.Out
        mov     rdx, [r12].TGrainRenderArgs.Win
        mov     r8,  [r12].TGrainRenderArgs.PosFix
        mov     r9,  [r12].TGrainRenderArgs.IncFix
        mov     r10d, [r12].TGrainRenderArgs.WinPos
        mov     r11d, [r12].TGrainRenderArgs.WinInc
        mov     r13d, [r12].TGrainRenderArgs.SrcLast
        dec     r13d                                    // SrcLast - 1
@Loop:
        mov     rax, r8
        sar     rax, 32
        lea     r15d, [eax - 1]
        cmp     r15d, r13d
        ja      @Skip
        movups  xmm0, [rsi + rax * 8 - 8]
        movhlps xmm1, xmm0
        movups  xmm2, [rsi + rax * 8 + 8]
        movhlps xmm3, xmm2
        movups  xmm7, HQ_HALF
        movaps  xmm4, xmm2
        subps   xmm4, xmm0
        mulps   xmm4, xmm7                              // c1
        movaps  xmm5, xmm1
        subps   xmm5, xmm2                              // v
        movaps  xmm6, xmm4
        addps   xmm6, xmm5                              // w
        subps   xmm3, xmm1
        mulps   xmm3, xmm7
        addps   xmm5, xmm6
        addps   xmm5, xmm3                              // a
        addps   xmm6, xmm5                              // b
        mov     r15d, r8d
        shr     r15d, 8
        cvtsi2ss xmm7, r15d
        mulss   xmm7, FRAC_SCALE
        shufps  xmm7, xmm7, 0                           // f
        mulps   xmm5, xmm7
        subps   xmm5, xmm6
        mulps   xmm5, xmm7
        addps   xmm5, xmm4
        mulps   xmm5, xmm7
        addps   xmm5, xmm1                              // y
        mov     r15d, r10d
        shr     r15d, WIN_FIX_SHIFT
        movss   xmm3, [rdx + r15 * 4]
        shufps  xmm3, xmm3, 0
        movss   xmm6, [r12].TGrainRenderArgs.GainL
        movss   xmm7, [r12].TGrainRenderArgs.GainR
        unpcklps xmm6, xmm7
        mulps   xmm3, xmm6
        mulps   xmm5, xmm3
        movlps  xmm2, [rdi]
        addps   xmm2, xmm5
        movlps  [rdi], xmm2
@Skip:
        add     rdi, 8
        add     r8, r9
        add     r10d, r11d
        dec     r14d
        jnz     @Loop
        mov     [r12].TGrainRenderArgs.PosFix, r8
        mov     [r12].TGrainRenderArgs.WinPos, r10d
@Done:
end;
{$ELSE}
procedure RenderGrainHQSSE(Args: PGrainRenderArgs);
begin
  RenderGrainHQPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  State-Variable-Filter - Referenz (Pascal)
  ------------------------------------------------------------------------------ }
procedure SvfBlockPas(Args: PSvfArgs);
var
  I, C: Integer;
  X, V1, V2, V3: Single;
  P: PSingle;
begin
  P := Args.Buf;
  for I := 0 to Args.Count - 1 do
    for C := 0 to 1 do
    begin
      X := P[I * 2 + C];
      V3 := X - Args.IC2[C];                                       // v3 = x - ic2
      V1 := Args.A1[C] * Args.IC1[C] + Args.A2[C] * V3;            // v1 = a1*ic1 + a2*v3
      V2 := Args.IC2[C] + Args.A2[C] * Args.IC1[C] + Args.A3[C] * V3; // v2 = ic2 + a2*ic1 + a3*v3
      Args.IC1[C] := 2 * V1 - Args.IC1[C];
      Args.IC2[C] := 2 * V2 - Args.IC2[C];
      P[I * 2 + C] := Args.MixX[C] * X + Args.MixL[C] * V2 + Args.MixB[C] * V1;
    end;
end;

{ ------------------------------------------------------------------------------
  State-Variable-Filter - SSE1. L und R laufen parallel in den Lanes 0/1.
    xmm0 = ic1   xmm1 = ic2   xmm2 = a1   xmm3 = a2   xmm4 = a3   xmm5..7 = Hilfs
  Mischkoeffizienten werden je Sample mit movups aus dem Record geladen (L1-Cache).
  ------------------------------------------------------------------------------ }
{$IF Defined(CPUX86)}
procedure SvfBlockSSE(Args: PSvfArgs);
asm
        push    esi
        mov     ecx, [eax].TSvfArgs.Count
        test    ecx, ecx
        jz      @Done
        mov     esi, [eax].TSvfArgs.Buf
        movups  xmm0, [eax].TSvfArgs.IC1
        movups  xmm1, [eax].TSvfArgs.IC2
        movups  xmm2, [eax].TSvfArgs.A1
        movups  xmm3, [eax].TSvfArgs.A2
        movups  xmm4, [eax].TSvfArgs.A3
@Loop:
        xorps   xmm5, xmm5
        movlps  xmm5, [esi]               // x = [L R 0 0]
        movaps  xmm6, xmm5
        subps   xmm6, xmm1                // v3 = x - ic2
        movaps  xmm7, xmm0
        mulps   xmm7, xmm2                // a1*ic1
        movaps  xmm5, xmm6
        mulps   xmm5, xmm3                // a2*v3
        addps   xmm7, xmm5                // v1
        mulps   xmm6, xmm4                // a3*v3
        movaps  xmm5, xmm0
        mulps   xmm5, xmm3                // a2*ic1
        addps   xmm6, xmm5
        addps   xmm6, xmm1                // v2 = ic2 + a2*ic1 + a3*v3
        movaps  xmm5, xmm7
        addps   xmm5, xmm7
        subps   xmm5, xmm0
        movaps  xmm0, xmm5                // ic1 = 2*v1 - ic1
        movaps  xmm5, xmm6
        addps   xmm5, xmm6
        subps   xmm5, xmm1
        movaps  xmm1, xmm5                // ic2 = 2*v2 - ic2
        movups  xmm5, [eax].TSvfArgs.MixB
        mulps   xmm7, xmm5                // CB*v1
        movups  xmm5, [eax].TSvfArgs.MixL
        mulps   xmm6, xmm5                // CL*v2
        addps   xmm7, xmm6
        xorps   xmm5, xmm5
        movlps  xmm5, [esi]
        movups  xmm6, [eax].TSvfArgs.MixX
        mulps   xmm5, xmm6                // CX*x
        addps   xmm7, xmm5
        movlps  [esi], xmm7               // y
        add     esi, 8
        dec     ecx
        jnz     @Loop
        movups  [eax].TSvfArgs.IC1, xmm0
        movups  [eax].TSvfArgs.IC2, xmm1
@Done:
        pop     esi
end;
{$ELSEIF Defined(CPUX64)}
{ ------------------------------------------------------------------------------
  State-Variable-Filter x64: identisch zur Win32-Version, Args in RCX, Puffer in RDX,
  Zaehler in R8D. xmm6/xmm7 sind unter x64 nicht-fluechtig -> per .SAVENV gesichert.
  ------------------------------------------------------------------------------ }
procedure SvfBlockSSE(Args: PSvfArgs);
asm
        .SAVENV xmm6
        .SAVENV xmm7
        mov     r8d, [rcx].TSvfArgs.Count
        test    r8d, r8d
        jz      @Done
        mov     rdx, [rcx].TSvfArgs.Buf
        movups  xmm0, [rcx].TSvfArgs.IC1
        movups  xmm1, [rcx].TSvfArgs.IC2
        movups  xmm2, [rcx].TSvfArgs.A1
        movups  xmm3, [rcx].TSvfArgs.A2
        movups  xmm4, [rcx].TSvfArgs.A3
@Loop:
        xorps   xmm5, xmm5
        movlps  xmm5, [rdx]               // x = [L R 0 0]
        movaps  xmm6, xmm5
        subps   xmm6, xmm1                // v3 = x - ic2
        movaps  xmm7, xmm0
        mulps   xmm7, xmm2                // a1*ic1
        movaps  xmm5, xmm6
        mulps   xmm5, xmm3                // a2*v3
        addps   xmm7, xmm5                // v1
        mulps   xmm6, xmm4                // a3*v3
        movaps  xmm5, xmm0
        mulps   xmm5, xmm3                // a2*ic1
        addps   xmm6, xmm5
        addps   xmm6, xmm1                // v2 = ic2 + a2*ic1 + a3*v3
        movaps  xmm5, xmm7
        addps   xmm5, xmm7
        subps   xmm5, xmm0
        movaps  xmm0, xmm5                // ic1 = 2*v1 - ic1
        movaps  xmm5, xmm6
        addps   xmm5, xmm6
        subps   xmm5, xmm1
        movaps  xmm1, xmm5                // ic2 = 2*v2 - ic2
        movups  xmm5, [rcx].TSvfArgs.MixB
        mulps   xmm7, xmm5                // MixB*v1
        movups  xmm5, [rcx].TSvfArgs.MixL
        mulps   xmm6, xmm5                // MixL*v2
        addps   xmm7, xmm6
        xorps   xmm5, xmm5
        movlps  xmm5, [rdx]
        movups  xmm6, [rcx].TSvfArgs.MixX
        mulps   xmm5, xmm6                // MixX*x
        addps   xmm7, xmm5
        movlps  [rdx], xmm7               // y
        add     rdx, 8
        dec     r8d
        jnz     @Loop
        movups  [rcx].TSvfArgs.IC1, xmm0
        movups  [rcx].TSvfArgs.IC2, xmm1
@Done:
end;
{$ELSE}
procedure SvfBlockSSE(Args: PSvfArgs);
begin
  SvfBlockPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Echo (Pascal; speichergebunden, SIMD bringt hier wenig)
  ------------------------------------------------------------------------------ }
{ Zwei Lesekoepfe mit saegezahnfoermiger Verzoegerung, um eine halbe Periode
  versetzt und dreieckig ueberblendet - klassischer, billiger Delay-Pitch-Shifter. }
procedure PitchShift(Args: PEchoArgs; var L, R: Single);
var
  D, Rp, Fr, G1: Double;
  W, I0, I1, K: Integer;
  OutL, OutR: Double;
  Buf: PSingle;
begin
  Buf := Args.PBuf;
  W := Args.PWrite;
  Buf[W * 2] := L;
  Buf[W * 2 + 1] := R;
  Args.PPhase := Args.PPhase + (1 - Args.PRatio) / PITCH_WIN;
  if Args.PPhase >= 1 then Args.PPhase := Args.PPhase - 1
  else if Args.PPhase < 0 then Args.PPhase := Args.PPhase + 1;
  OutL := 0;
  OutR := 0;
  for K := 0 to 1 do
  begin
    if K = 0 then D := Args.PPhase else D := Args.PPhase + 0.5;
    if D >= 1 then D := D - 1;
    G1 := 1 - Abs(2 * D - 1);                 // Dreiecksfenster, Summe beider = 1
    Rp := W - 1 - D * PITCH_WIN;
    if Rp < 0 then Rp := Rp + Args.PLen;
    I0 := Trunc(Rp);
    Fr := Rp - I0;
    I1 := I0 + 1;
    if I1 >= Args.PLen then I1 := 0;
    OutL := OutL + G1 * (Buf[I0 * 2] + (Buf[I1 * 2] - Buf[I0 * 2]) * Fr);
    OutR := OutR + G1 * (Buf[I0 * 2 + 1] + (Buf[I1 * 2 + 1] - Buf[I0 * 2 + 1]) * Fr);
  end;
  Inc(W);
  if W >= Args.PLen then W := 0;
  Args.PWrite := W;
  L := OutL;
  R := OutR;
end;

procedure EchoBlock(Args: PEchoArgs);
var
  I, I0, I1, W, Len: Integer;
  Rp, Fr: Double;
  XL, XR, DL, DR, WL, WR, Fb, Mix, Dc, FbL, FbR: Single;
  Buf, IO: PSingle;
  Shift: Boolean;
begin
  Buf := Args.Buf;
  IO := Args.IO;
  Len := Args.Len;
  W := Args.WritePos;
  Fb := Args.Feedback;
  Mix := Args.Mix;
  Dc := Args.DampCoef;
  Shift := (Args.PBuf <> nil) and (Abs(Args.PRatio - 1) > 0.0005);
  for I := 0 to Args.Count - 1 do
  begin
    XL := IO[I * 2];
    XR := IO[I * 2 + 1];
    // Zeitaenderungen gleiten (wie Bandecho) statt zu knacken
    Args.Delay := Args.Delay + (Args.Target - Args.Delay) * 0.0005;
    // der Pitch-Shifter verzoegert im Mittel um ein halbes Fenster -> abziehen, damit das Echo im Takt bleibt
    if Shift and (Args.Delay > PITCH_WIN * 0.5 + 1) then
      Rp := W - (Args.Delay - PITCH_WIN * 0.5)
    else
      Rp := W - Args.Delay;
    if Rp < 0 then
      Rp := Rp + Len;
    I0 := Trunc(Rp);
    Fr := Rp - I0;
    I1 := I0 + 1;
    if I1 >= Len then
      I1 := 0;
    DL := Buf[I0 * 2] + (Buf[I1 * 2] - Buf[I0 * 2]) * Fr;
    DR := Buf[I0 * 2 + 1] + (Buf[I1 * 2 + 1] - Buf[I0 * 2 + 1]) * Fr;
    // Daempfung: einpoliger Tiefpass im Rueckkopplungsweg
    Args.LP[0] := Args.LP[0] + (DL - Args.LP[0]) * Dc;
    Args.LP[1] := Args.LP[1] + (DR - Args.LP[1]) * Dc;
    FbL := Args.LP[0];
    FbR := Args.LP[1];
    if Args.PingPong then
    begin
      WL := (XL + XR) * 0.5 + Fb * FbR;
      WR := Fb * FbL;
    end
    else
    begin
      WL := XL + Fb * FbL;
      WR := XR + Fb * FbR;
    end;
    // Pitch-Echo: alles, was in die Verzoegerung geht (Eingang + Rueckkopplung), wird transponiert ->
    // 1. Wiederholung = +1 x Pitch, 2. = +2 x Pitch, ... (stufenweise steigende/fallende Echos)
    if Shift then
      PitchShift(Args, WL, WR);
    // Denormal-Schutz: ausklingende Rueckkopplung hart auf 0
    if Abs(WL) < 1E-15 then WL := 0;
    if Abs(WR) < 1E-15 then WR := 0;
    Buf[W * 2] := WL;
    Buf[W * 2 + 1] := WR;
    Inc(W);
    if W >= Len then
      W := 0;
    IO[I * 2] := XL + Mix * Args.LP[0];
    IO[I * 2 + 1] := XR + Mix * Args.LP[1];
  end;
  Args.WritePos := W;
  if Abs(Args.LP[0]) < 1E-15 then Args.LP[0] := 0;
  if Abs(Args.LP[1]) < 1E-15 then Args.LP[1] := 0;
end;

{ ------------------------------------------------------------------------------
  Saettigung
  ------------------------------------------------------------------------------ }
procedure SatBlockPas(Args: PSatArgs);
var
  I: Integer;
  Y, Y2, Num, Den: Single;
begin
  for I := 0 to Args.Count - 1 do
  begin
    Y := Args.P[I] * Args.Drive4[0];
    if Y > Args.Hi4[0] then Y := Args.Hi4[0];
    if Y < Args.Lo4[0] then Y := Args.Lo4[0];
    Y2 := Y * Y;
    Num := (Args.C27[0] + Y2) * Y;
    Den := Y2 * Args.C9[0] + Args.C27[0];
    Args.P[I] := (Num / Den) * Args.Make4[0];
  end;
end;

{$IF Defined(CPUX86)}
{ SSE1, 4 Werte je Schritt; eax = Args. Nur xmm0..xmm4. }
procedure SatBlockSSE(Args: PSatArgs);
asm
        mov     edx, [eax].TSatArgs.P
        mov     ecx, [eax].TSatArgs.Count
        shr     ecx, 2
        jz      @done
@loop:
        movups  xmm0, [edx]
        movups  xmm1, [eax+TSatArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [eax+TSatArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [eax+TSatArgs.Lo4]
        maxps   xmm0, xmm1
        movaps  xmm2, xmm0
        mulps   xmm2, xmm2
        movups  xmm3, [eax+TSatArgs.C27]
        movaps  xmm4, xmm3
        addps   xmm3, xmm2
        mulps   xmm3, xmm0
        movups  xmm1, [eax+TSatArgs.C9]
        mulps   xmm2, xmm1
        addps   xmm2, xmm4
        divps   xmm3, xmm2
        movups  xmm1, [eax+TSatArgs.Make4]
        mulps   xmm3, xmm1
        movups  [edx], xmm3
        add     edx, 16
        dec     ecx
        jnz     @loop
@done:
end;
{$ELSEIF Defined(CPUX64)}
procedure SatBlockSSE(Args: PSatArgs);
asm
        mov     rdx, [rcx].TSatArgs.P
        mov     r8d, [rcx].TSatArgs.Count
        shr     r8d, 2
        jz      @done
@loop:
        movups  xmm0, [rdx]
        movups  xmm1, [rcx+TSatArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [rcx+TSatArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [rcx+TSatArgs.Lo4]
        maxps   xmm0, xmm1
        movaps  xmm2, xmm0
        mulps   xmm2, xmm2
        movups  xmm3, [rcx+TSatArgs.C27]
        movaps  xmm4, xmm3
        addps   xmm3, xmm2
        mulps   xmm3, xmm0
        movups  xmm1, [rcx+TSatArgs.C9]
        mulps   xmm2, xmm1
        addps   xmm2, xmm4
        divps   xmm3, xmm2
        movups  xmm1, [rcx+TSatArgs.Make4]
        mulps   xmm3, xmm1
        movups  [rdx], xmm3
        add     rdx, 16
        dec     r8d
        jnz     @loop
@done:
end;
{$ELSE}
procedure SatBlockSSE(Args: PSatArgs);
begin
  SatBlockPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Weitere Saettigungs-Arten (Roehre, Hart, Faltung)
  ------------------------------------------------------------------------------ }
procedure ShapeBlockPas(Args: PShapeArgs);
var
  I, K: Integer;
  Y, Y2, U: Single;
begin
  for I := 0 to Args.Count - 1 do
  begin
    Y := Args.P[I] * Args.Drive4[0];
    case Args.Kind of
      1:
        begin
          Y := Y + Args.Bias4[0];
          if Y > Args.Hi4[0] then Y := Args.Hi4[0];
          if Y < Args.Lo4[0] then Y := Args.Lo4[0];
          Y2 := Y * Y;
          Y := ((Args.C27[0] + Y2) * Y) / (Y2 * Args.C9[0] + Args.C27[0]);
          Y := Y - Args.Off4[0];
        end;
      2:
        begin
          if Y > Args.One4[0] then Y := Args.One4[0];
          if Y < Args.MOne4[0] then Y := Args.MOne4[0];
        end;
    else
      begin
        if Y > Args.Hi4[0] then Y := Args.Hi4[0];
        if Y < Args.Lo4[0] then Y := Args.Lo4[0];
        for K := 0 to 1 do
        begin
          U := Y - Args.One4[0];
          if U < 0 then U := 0;
          U := U + U;
          Y := Y - U;
          U := Y + Args.One4[0];
          if U > 0 then U := 0;
          U := U + U;
          Y := Y - U;
        end;
      end;
    end;
    Args.P[I] := Y * Args.Make4[0];
  end;
end;

{$IF Defined(CPUX86)}
{ SSE1, 4 Werte je Schritt; eax = Args. Nur xmm0..xmm4. }
procedure ShapeBlockSSE(Args: PShapeArgs);
asm
        mov     edx, [eax].TShapeArgs.P
        mov     ecx, [eax].TShapeArgs.Count
        shr     ecx, 2
        jz      @done
        cmp     dword ptr [eax].TShapeArgs.Kind, 2
        je      @hard
        ja      @fold
@tube:
        movups  xmm0, [edx]
        movups  xmm1, [eax+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Bias4]
        addps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Lo4]
        maxps   xmm0, xmm1
        movaps  xmm2, xmm0
        mulps   xmm2, xmm2
        movups  xmm3, [eax+TShapeArgs.C27]
        movaps  xmm4, xmm3
        addps   xmm3, xmm2
        mulps   xmm3, xmm0
        movups  xmm1, [eax+TShapeArgs.C9]
        mulps   xmm2, xmm1
        addps   xmm2, xmm4
        divps   xmm3, xmm2
        movups  xmm1, [eax+TShapeArgs.Off4]
        subps   xmm3, xmm1
        movups  xmm1, [eax+TShapeArgs.Make4]
        mulps   xmm3, xmm1
        movups  [edx], xmm3
        add     edx, 16
        dec     ecx
        jnz     @tube
        jmp     @done
@hard:
        movups  xmm0, [edx]
        movups  xmm1, [eax+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.One4]
        minps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.MOne4]
        maxps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Make4]
        mulps   xmm0, xmm1
        movups  [edx], xmm0
        add     edx, 16
        dec     ecx
        jnz     @hard
        jmp     @done
@fold:
        movups  xmm0, [edx]
        movups  xmm1, [eax+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Lo4]
        maxps   xmm0, xmm1
        movups  xmm3, [eax+TShapeArgs.One4]
        movups  xmm4, [eax+TShapeArgs.Zero4]
        // zweimal spiegeln: oben an +1, unten an -1
        movaps  xmm1, xmm0
        subps   xmm1, xmm3
        maxps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        addps   xmm1, xmm3
        minps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        subps   xmm1, xmm3
        maxps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        addps   xmm1, xmm3
        minps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movups  xmm1, [eax+TShapeArgs.Make4]
        mulps   xmm0, xmm1
        movups  [edx], xmm0
        add     edx, 16
        dec     ecx
        jnz     @fold
@done:
end;
{$ELSEIF Defined(CPUX64)}
procedure ShapeBlockSSE(Args: PShapeArgs);
asm
        mov     rdx, [rcx].TShapeArgs.P
        mov     r8d, [rcx].TShapeArgs.Count
        shr     r8d, 2
        jz      @done
        cmp     dword ptr [rcx].TShapeArgs.Kind, 2
        je      @hard
        ja      @fold
@tube:
        movups  xmm0, [rdx]
        movups  xmm1, [rcx+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Bias4]
        addps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Lo4]
        maxps   xmm0, xmm1
        movaps  xmm2, xmm0
        mulps   xmm2, xmm2
        movups  xmm3, [rcx+TShapeArgs.C27]
        movaps  xmm4, xmm3
        addps   xmm3, xmm2
        mulps   xmm3, xmm0
        movups  xmm1, [rcx+TShapeArgs.C9]
        mulps   xmm2, xmm1
        addps   xmm2, xmm4
        divps   xmm3, xmm2
        movups  xmm1, [rcx+TShapeArgs.Off4]
        subps   xmm3, xmm1
        movups  xmm1, [rcx+TShapeArgs.Make4]
        mulps   xmm3, xmm1
        movups  [rdx], xmm3
        add     rdx, 16
        dec     r8d
        jnz     @tube
        jmp     @done
@hard:
        movups  xmm0, [rdx]
        movups  xmm1, [rcx+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.One4]
        minps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.MOne4]
        maxps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Make4]
        mulps   xmm0, xmm1
        movups  [rdx], xmm0
        add     rdx, 16
        dec     r8d
        jnz     @hard
        jmp     @done
@fold:
        movups  xmm0, [rdx]
        movups  xmm1, [rcx+TShapeArgs.Drive4]
        mulps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Hi4]
        minps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Lo4]
        maxps   xmm0, xmm1
        movups  xmm3, [rcx+TShapeArgs.One4]
        movups  xmm4, [rcx+TShapeArgs.Zero4]
        // zweimal spiegeln: oben an +1, unten an -1
        movaps  xmm1, xmm0
        subps   xmm1, xmm3
        maxps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        addps   xmm1, xmm3
        minps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        subps   xmm1, xmm3
        maxps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movaps  xmm1, xmm0
        addps   xmm1, xmm3
        minps   xmm1, xmm4
        addps   xmm1, xmm1
        subps   xmm0, xmm1
        movups  xmm1, [rcx+TShapeArgs.Make4]
        mulps   xmm0, xmm1
        movups  [rdx], xmm0
        add     rdx, 16
        dec     r8d
        jnz     @fold
@done:
end;
{$ELSE}
procedure ShapeBlockSSE(Args: PShapeArgs);
begin
  ShapeBlockPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Huellkurven-Abschnitt (Oszillator-Huellkurven, 4 Werte je Schritt)
  ------------------------------------------------------------------------------ }
procedure EnvSegPas(Args: PEnvSegArgs);
var
  I, L: Integer;
  D: array[0..3] of Single;
  X: Single;
  R, G: PSingle;
begin
  for L := 0 to 3 do
    D[L] := Args.D4[L];
  R := Args.Raw;
  G := Args.Gain;
  for I := 0 to Args.Count - 1 do
  begin
    for L := 0 to 3 do
    begin
      X := Args.Base4[L] + D[L];
      R^ := X;
      G^ := X * Args.G4[L];
      Inc(R);
      Inc(G);
      D[L] := D[L] * Args.Mul4[L] + Args.Add4[L];
    end;
  end;
end;

{$IF Defined(CPUX86)}
{ eax = Args; xmm0 = D, xmm1 = Base, xmm2 = Mul, xmm3 = Add, xmm4 = G }
procedure EnvSegSSE(Args: PEnvSegArgs);
asm
        push    ebx
        mov     edx, [eax].TEnvSegArgs.Raw
        mov     ebx, [eax].TEnvSegArgs.Gain
        mov     ecx, [eax].TEnvSegArgs.Count
        test    ecx, ecx
        jle     @done
        movups  xmm0, [eax+TEnvSegArgs.D4]
        movups  xmm1, [eax+TEnvSegArgs.Base4]
        movups  xmm2, [eax+TEnvSegArgs.Mul4]
        movups  xmm3, [eax+TEnvSegArgs.Add4]
        movups  xmm4, [eax+TEnvSegArgs.G4]
@loop:
        movaps  xmm5, xmm1
        addps   xmm5, xmm0
        movups  [edx], xmm5
        mulps   xmm5, xmm4
        movups  [ebx], xmm5
        mulps   xmm0, xmm2
        addps   xmm0, xmm3
        add     edx, 16
        add     ebx, 16
        dec     ecx
        jnz     @loop
@done:
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ rcx = Args }
procedure EnvSegSSE(Args: PEnvSegArgs);
asm
        mov     rdx, [rcx].TEnvSegArgs.Raw
        mov     r9, [rcx].TEnvSegArgs.Gain
        mov     r8d, [rcx].TEnvSegArgs.Count
        test    r8d, r8d
        jle     @done
        movups  xmm0, [rcx+TEnvSegArgs.D4]
        movups  xmm1, [rcx+TEnvSegArgs.Base4]
        movups  xmm2, [rcx+TEnvSegArgs.Mul4]
        movups  xmm3, [rcx+TEnvSegArgs.Add4]
        movups  xmm4, [rcx+TEnvSegArgs.G4]
@loop:
        movaps  xmm5, xmm1
        addps   xmm5, xmm0
        movups  [rdx], xmm5
        mulps   xmm5, xmm4
        movups  [r9], xmm5
        mulps   xmm0, xmm2
        addps   xmm0, xmm3
        add     rdx, 16
        add     r9, 16
        dec     r8d
        jnz     @loop
@done:
end;
{$ELSE}
procedure EnvSegSSE(Args: PEnvSegArgs);
begin
  EnvSegPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Oszillator (je Stimme)
  ------------------------------------------------------------------------------ }
procedure OscBlockPas(Args: POscArgs);

  function TabSin(T: PSingle; P: Single): Single;
  var
    X, F: Single;
    K: Integer;
  begin
    X := P * 4096;
    K := Trunc(X);
    F := X - K;
    Result := T[K] + (T[K + 1] - T[K]) * F;
  end;

  function Blep(T, Dt: Single): Single;
  var
    U: Single;
  begin
    if T < Dt then
    begin
      U := T / Dt;
      Result := ((U + U) - U * U) - 1;
    end
    else if T > 1 - Dt then
    begin
      U := (T - 1) / Dt;
      Result := ((U + U) + U * U) + 1;
    end
    else
      Result := 0;
  end;

var
  I: Integer;
  Ph, PhM0, S, X, T, G: Single;
begin
  PhM0 := Args.Ph;     // Grundton-Phase
  for I := 0 to Args.Count - 1 do
  begin
    // Hard Sync: Phase der Welle = frac(Grundton-Phase * SyncR)
    Ph := PhM0 * Args.SyncR;
    Ph := Ph - Trunc(Ph);
    case Args.Wave of
      1: S := 1 - Abs(Ph - 0.5) * 4;
      2: S := ((Ph + Ph) - 1) - Blep(Ph, Args.Dt);
      3: begin
           if Ph < 0.5 then S := 1 else S := -1;
           S := S + Blep(Ph, Args.Dt);
           T := Ph + 0.5;
           if T >= 1 then T := T - 1;
           S := S - Blep(T, Args.Dt);
         end;
      4: begin
           X := TabSin(Args.Tab, Args.PhM) * Args.FmIdx * Args.EnvRaw[I] + Ph;
           X := X - Trunc(X);
           if X < 0 then X := X + 1;
           S := TabSin(Args.Tab, X);
           Args.PhM := Args.PhM + Args.DtM;
           if Args.PhM >= 1 then Args.PhM := Args.PhM - 1;
         end;
      5: begin
           Args.Seed := Integer(Cardinal(Args.Seed) * 1664525 + 1013904223);
           S := Args.Seed * Args.CInv31;
         end;
    else
      S := TabSin(Args.Tab, Ph);
    end;
    PhM0 := PhM0 + Args.DtP;
    if PhM0 >= 1 then PhM0 := PhM0 - 1;
    G := S * Args.Env[I];
    Args.Out[I * 2] := G * Args.GL + Args.Out[I * 2];
    Args.Out[I * 2 + 1] := G * Args.GR + Args.Out[I * 2 + 1];
  end;
  Args.Ph := PhM0;
end;

{$IF Defined(CPUX86)}
{ SSE1 (skalar): eax = Args; esi Ausgabe, edi Verstaerkung, ebx Rohhuellkurve, edx Sinustabelle,
  ecx Tabellenindex; der Zaehler laeuft im Argument-Record. Nur xmm0..xmm4. }
procedure OscBlockSSE(Args: POscArgs);
asm
        push    esi
        push    edi
        push    ebx
        mov     esi, [eax+TOscArgs.Out]
        mov     edi, [eax+TOscArgs.Env]
        mov     ebx, [eax+TOscArgs.EnvRaw]
        mov     edx, [eax+TOscArgs.Tab]
        cmp     dword ptr [eax+TOscArgs.Count], 0
        jle     @done
        movss   xmm5, [eax+TOscArgs.Ph]    // xmm5 = Grundton-Phase
@loop:
        // Hard Sync: xmm0 = frac(Grundton-Phase * SyncR) -> Phase der Welle
        movaps  xmm0, xmm5
        mulss   xmm0, [eax+TOscArgs.SyncR]
        cvttss2si ecx, xmm0
        cvtsi2ss xmm1, ecx
        subss   xmm0, xmm1
        mov     ecx, [eax+TOscArgs.Wave]
        cmp     ecx, 1
        je      @tri
        cmp     ecx, 2
        je      @saw
        cmp     ecx, 3
        je      @sqr
        cmp     ecx, 4
        je      @fm
        cmp     ecx, 5
        je      @noise
// ---- Sinus
        movaps  xmm2, xmm0
        mulss   xmm2, [eax+TOscArgs.CTab]
        cvttss2si ecx, xmm2
        cvtsi2ss xmm3, ecx
        subss   xmm2, xmm3
        movss   xmm3, [edx+ecx*4]
        movss   xmm4, [edx+ecx*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4
        movaps  xmm1, xmm3
        jmp     @mix
// ---- Dreieck: 1 - 4*|ph - 0.5|
@tri:
        movaps  xmm2, xmm0
        subss   xmm2, [eax+TOscArgs.CHalf]
        movups  xmm3, [eax+TOscArgs.AbsMask4]
        andps   xmm2, xmm3
        mulss   xmm2, [eax+TOscArgs.C4]
        movss   xmm1, [eax+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- Saegezahn: (2ph - 1) - blep(ph)
@saw:
        movaps  xmm1, xmm0
        addss   xmm1, xmm0
        subss   xmm1, [eax+TOscArgs.C1]
        movaps  xmm2, xmm0
        movss   xmm3, [eax+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @sa1
        movss   xmm4, [eax+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @sa2
        jmp     @mix
@sa1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [eax+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
@sa2:
        subss   xmm2, [eax+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [eax+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- Rechteck: (+1/-1) + blep(ph) - blep(frac(ph + 0.5))
@sqr:
        movss   xmm1, [eax+TOscArgs.C1]
        comiss  xmm0, [eax+TOscArgs.CHalf]
        jb      @q0
        movss   xmm1, [eax+TOscArgs.CM1]
@q0:
        movaps  xmm2, xmm0
        movss   xmm3, [eax+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @qa1
        movss   xmm4, [eax+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @qa2
        jmp     @qb
@qa1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [eax+TOscArgs.C1]
        addss   xmm1, xmm2
        jmp     @qb
@qa2:
        subss   xmm2, [eax+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [eax+TOscArgs.C1]
        addss   xmm1, xmm2
@qb:
        movaps  xmm2, xmm0
        addss   xmm2, [eax+TOscArgs.CHalf]
        comiss  xmm2, [eax+TOscArgs.C1]
        jb      @qc
        subss   xmm2, [eax+TOscArgs.C1]
@qc:
        movss   xmm3, [eax+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @qd1
        movss   xmm4, [eax+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @qd2
        jmp     @mix
@qd1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [eax+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
@qd2:
        subss   xmm2, [eax+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [eax+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- weisses Rauschen: Seed = Seed * 1664525 + 1013904223, Wert = Seed * CInv31
@noise:
        mov     ecx, [eax+TOscArgs.Seed]
        imul    ecx, ecx, 1664525
        add     ecx, 1013904223
        mov     [eax+TOscArgs.Seed], ecx
        cvtsi2ss xmm1, ecx
        mulss   xmm1, [eax+TOscArgs.CInv31]
        jmp     @mix
// ---- FM: sin(ph + idx * env * sin(phM))
@fm:
        movss   xmm2, [eax+TOscArgs.PhM]
        mulss   xmm2, [eax+TOscArgs.CTab]
        cvttss2si ecx, xmm2
        cvtsi2ss xmm3, ecx
        subss   xmm2, xmm3
        movss   xmm3, [edx+ecx*4]
        movss   xmm4, [edx+ecx*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4                 // sin(phM)
        mulss   xmm3, [eax+TOscArgs.FmIdx]
        mulss   xmm3, [ebx]                // * Huellkurve
        addss   xmm3, xmm0                 // x = ph + ...
        cvttss2si ecx, xmm3
        cvtsi2ss xmm4, ecx
        subss   xmm3, xmm4                 // f = x - trunc(x)
        xorps   xmm4, xmm4
        comiss  xmm3, xmm4
        jae     @fpos
        addss   xmm3, [eax+TOscArgs.C1]
@fpos:
        movaps  xmm2, xmm3
        mulss   xmm2, [eax+TOscArgs.CTab]
        cvttss2si ecx, xmm2
        cvtsi2ss xmm3, ecx
        subss   xmm2, xmm3
        movss   xmm3, [edx+ecx*4]
        movss   xmm4, [edx+ecx*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4
        movaps  xmm1, xmm3
        movss   xmm2, [eax+TOscArgs.PhM]
        addss   xmm2, [eax+TOscArgs.DtM]
        comiss  xmm2, [eax+TOscArgs.C1]
        jb      @fm1
        subss   xmm2, [eax+TOscArgs.C1]
@fm1:
        movss   [eax+TOscArgs.PhM], xmm2
// ---- Phase weiter, mischen
@mix:
        addss   xmm5, [eax+TOscArgs.DtP]
        comiss  xmm5, [eax+TOscArgs.C1]
        jb      @nowrap
        subss   xmm5, [eax+TOscArgs.C1]
@nowrap:
        mulss   xmm1, [edi]
        movaps  xmm2, xmm1
        mulss   xmm2, [eax+TOscArgs.GL]
        addss   xmm2, [esi]
        movss   [esi], xmm2
        mulss   xmm1, [eax+TOscArgs.GR]
        addss   xmm1, [esi+4]
        movss   [esi+4], xmm1
        add     esi, 8
        add     edi, 4
        add     ebx, 4
        dec     dword ptr [eax+TOscArgs.Count]
        jnz     @loop
        movss   [eax+TOscArgs.Ph], xmm5
@done:
        pop     ebx
        pop     edi
        pop     esi
end;
{$ELSEIF Defined(CPUX64)}
{ x64: rcx = Args; r8 Ausgabe, r9 Verstaerkung, r10 Rohhuellkurve, r11 Tabelle, eax Index }
procedure OscBlockSSE(Args: POscArgs);
asm
        mov     r8, [rcx+TOscArgs.Out]
        mov     r9, [rcx+TOscArgs.Env]
        mov     r10, [rcx+TOscArgs.EnvRaw]
        mov     r11, [rcx+TOscArgs.Tab]
        cmp     dword ptr [rcx+TOscArgs.Count], 0
        jle     @done
        movss   xmm5, [rcx+TOscArgs.Ph]    // xmm5 = Grundton-Phase (fluechtig)
@loop:
        // Hard Sync: xmm0 = frac(Grundton-Phase * SyncR) -> Phase der Welle
        movaps  xmm0, xmm5
        mulss   xmm0, [rcx+TOscArgs.SyncR]
        cvttss2si eax, xmm0
        cvtsi2ss xmm1, eax
        subss   xmm0, xmm1
        mov     eax, [rcx+TOscArgs.Wave]
        cmp     eax, 1
        je      @tri
        cmp     eax, 2
        je      @saw
        cmp     eax, 3
        je      @sqr
        cmp     eax, 4
        je      @fm
        cmp     eax, 5
        je      @noise
// ---- Sinus
        movaps  xmm2, xmm0
        mulss   xmm2, [rcx+TOscArgs.CTab]
        cvttss2si eax, xmm2
        cvtsi2ss xmm3, eax
        subss   xmm2, xmm3
        movss   xmm3, [r11+rax*4]
        movss   xmm4, [r11+rax*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4
        movaps  xmm1, xmm3
        jmp     @mix
// ---- Dreieck: 1 - 4*|ph - 0.5|
@tri:
        movaps  xmm2, xmm0
        subss   xmm2, [rcx+TOscArgs.CHalf]
        movups  xmm3, [rcx+TOscArgs.AbsMask4]
        andps   xmm2, xmm3
        mulss   xmm2, [rcx+TOscArgs.C4]
        movss   xmm1, [rcx+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- Saegezahn: (2ph - 1) - blep(ph)
@saw:
        movaps  xmm1, xmm0
        addss   xmm1, xmm0
        subss   xmm1, [rcx+TOscArgs.C1]
        movaps  xmm2, xmm0
        movss   xmm3, [rcx+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @sa1
        movss   xmm4, [rcx+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @sa2
        jmp     @mix
@sa1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [rcx+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
@sa2:
        subss   xmm2, [rcx+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [rcx+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- Rechteck: (+1/-1) + blep(ph) - blep(frac(ph + 0.5))
@sqr:
        movss   xmm1, [rcx+TOscArgs.C1]
        comiss  xmm0, [rcx+TOscArgs.CHalf]
        jb      @q0
        movss   xmm1, [rcx+TOscArgs.CM1]
@q0:
        movaps  xmm2, xmm0
        movss   xmm3, [rcx+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @qa1
        movss   xmm4, [rcx+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @qa2
        jmp     @qb
@qa1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [rcx+TOscArgs.C1]
        addss   xmm1, xmm2
        jmp     @qb
@qa2:
        subss   xmm2, [rcx+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [rcx+TOscArgs.C1]
        addss   xmm1, xmm2
@qb:
        movaps  xmm2, xmm0
        addss   xmm2, [rcx+TOscArgs.CHalf]
        comiss  xmm2, [rcx+TOscArgs.C1]
        jb      @qc
        subss   xmm2, [rcx+TOscArgs.C1]
@qc:
        movss   xmm3, [rcx+TOscArgs.Dt]
        comiss  xmm2, xmm3
        jb      @qd1
        movss   xmm4, [rcx+TOscArgs.C1]
        subss   xmm4, xmm3
        comiss  xmm2, xmm4
        ja      @qd2
        jmp     @mix
@qd1:
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        subss   xmm2, xmm4
        subss   xmm2, [rcx+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
@qd2:
        subss   xmm2, [rcx+TOscArgs.C1]
        divss   xmm2, xmm3
        movaps  xmm4, xmm2
        mulss   xmm4, xmm2
        addss   xmm2, xmm2
        addss   xmm2, xmm4
        addss   xmm2, [rcx+TOscArgs.C1]
        subss   xmm1, xmm2
        jmp     @mix
// ---- weisses Rauschen (wie x86)
@noise:
        mov     eax, [rcx+TOscArgs.Seed]
        imul    eax, eax, 1664525
        add     eax, 1013904223
        mov     [rcx+TOscArgs.Seed], eax
        cvtsi2ss xmm1, eax
        mulss   xmm1, [rcx+TOscArgs.CInv31]
        jmp     @mix
// ---- FM: sin(ph + idx * env * sin(phM))
@fm:
        movss   xmm2, [rcx+TOscArgs.PhM]
        mulss   xmm2, [rcx+TOscArgs.CTab]
        cvttss2si eax, xmm2
        cvtsi2ss xmm3, eax
        subss   xmm2, xmm3
        movss   xmm3, [r11+rax*4]
        movss   xmm4, [r11+rax*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4                 // sin(phM)
        mulss   xmm3, [rcx+TOscArgs.FmIdx]
        mulss   xmm3, [r10]                // * Huellkurve
        addss   xmm3, xmm0                 // x = ph + ...
        cvttss2si eax, xmm3
        cvtsi2ss xmm4, eax
        subss   xmm3, xmm4                 // f = x - trunc(x)
        xorps   xmm4, xmm4
        comiss  xmm3, xmm4
        jae     @fpos
        addss   xmm3, [rcx+TOscArgs.C1]
@fpos:
        movaps  xmm2, xmm3
        mulss   xmm2, [rcx+TOscArgs.CTab]
        cvttss2si eax, xmm2
        cvtsi2ss xmm3, eax
        subss   xmm2, xmm3
        movss   xmm3, [r11+rax*4]
        movss   xmm4, [r11+rax*4+4]
        subss   xmm4, xmm3
        mulss   xmm4, xmm2
        addss   xmm3, xmm4
        movaps  xmm1, xmm3
        movss   xmm2, [rcx+TOscArgs.PhM]
        addss   xmm2, [rcx+TOscArgs.DtM]
        comiss  xmm2, [rcx+TOscArgs.C1]
        jb      @fm1
        subss   xmm2, [rcx+TOscArgs.C1]
@fm1:
        movss   [rcx+TOscArgs.PhM], xmm2
// ---- Phase weiter, mischen
@mix:
        addss   xmm5, [rcx+TOscArgs.DtP]
        comiss  xmm5, [rcx+TOscArgs.C1]
        jb      @nowrap
        subss   xmm5, [rcx+TOscArgs.C1]
@nowrap:
        mulss   xmm1, [r9]
        movaps  xmm2, xmm1
        mulss   xmm2, [rcx+TOscArgs.GL]
        addss   xmm2, [r8]
        movss   [r8], xmm2
        mulss   xmm1, [rcx+TOscArgs.GR]
        addss   xmm1, [r8+4]
        movss   [r8+4], xmm1
        add     r8, 8
        add     r9, 4
        add     r10, 4
        dec     dword ptr [rcx+TOscArgs.Count]
        jnz     @loop
        movss   [rcx+TOscArgs.Ph], xmm5
@done:
end;
{$ELSE}
procedure OscBlockSSE(Args: POscArgs);
begin
  OscBlockPas(Args);
end;
{$IFEND}

procedure Deinterleave(Src, OutL, OutR: PSingle; Frames: Integer);
var
  I: Integer;
begin
  for I := 0 to Frames - 1 do
  begin
    OutL[I] := Src[I * 2];
    OutR[I] := Src[I * 2 + 1];
  end;
end;

{ ------------------------------------------------------------------------------
  Kammfilter
  ------------------------------------------------------------------------------ }
procedure CombBlockPas(Args: PCombArgs);
var
  I, C, W, R0, R1: Integer;
  D, X, Y: Single;
begin
  W := Args.WritePos;
  for I := 0 to Args.Count - 1 do
  begin
    R0 := (W - Args.DInt) and Args.Mask;
    R1 := (R0 - 1) and Args.Mask;
    for C := 0 to 1 do
    begin
      D := Args.Buf[R0 * 2 + C] + (Args.Buf[R1 * 2 + C] - Args.Buf[R0 * 2 + C]) * Args.Frac;
      X := Args.IO[I * 2 + C];
      Y := X + Args.Fb * D;
      Args.Buf[W * 2 + C] := Y;
      Args.IO[I * 2 + C] := Args.MixX * X + Args.MixW * Y;
    end;
    W := (W + 1) and Args.Mask;
  end;
  Args.WritePos := W;
end;

{$IF Defined(CPUX86)}
{ SSE1, ein Stereo-Paar je Schritt in den unteren zwei Spuren (obere Spuren bleiben 0).
  eax = Args, esi = IO, edi = Ring, ebx = Schreibposition, ecx = Zaehler, edx/ebp = Leseindizes }
procedure CombBlockSSE(Args: PCombArgs);
asm
        push    ebx
        push    esi
        push    edi
        push    ebp
        mov     esi, [eax].TCombArgs.IO
        mov     edi, [eax].TCombArgs.Buf
        mov     ecx, [eax].TCombArgs.Count
        mov     ebx, [eax].TCombArgs.WritePos
        xorps   xmm0, xmm0
        xorps   xmm1, xmm1
        xorps   xmm2, xmm2
        movss   xmm5, [eax].TCombArgs.Frac
        shufps  xmm5, xmm5, 0
        movss   xmm6, [eax].TCombArgs.Fb
        shufps  xmm6, xmm6, 0
        movss   xmm7, [eax].TCombArgs.MixX
        shufps  xmm7, xmm7, 0
        movss   xmm4, [eax].TCombArgs.MixW
        shufps  xmm4, xmm4, 0
        test    ecx, ecx
        jle     @done
@loop:
        mov     ebp, ebx
        sub     ebp, [eax].TCombArgs.DInt
        and     ebp, [eax].TCombArgs.Mask
        lea     edx, [ebp - 1]
        and     edx, [eax].TCombArgs.Mask
        movlps  xmm0, [edi + ebp * 8]          // Ring[R0]
        movlps  xmm1, [edi + edx * 8]          // Ring[R1]
        subps   xmm1, xmm0
        mulps   xmm1, xmm5
        addps   xmm0, xmm1                     // d
        mulps   xmm0, xmm6                     // Fb * d
        movlps  xmm2, [esi]                    // x
        addps   xmm0, xmm2                     // y
        movlps  [edi + ebx * 8], xmm0
        mulps   xmm2, xmm7
        mulps   xmm0, xmm4
        addps   xmm2, xmm0
        movlps  [esi], xmm2
        add     esi, 8
        inc     ebx
        and     ebx, [eax].TCombArgs.Mask
        dec     ecx
        jnz     @loop
@done:
        mov     [eax].TCombArgs.WritePos, ebx
        pop     ebp
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ rcx = Args, r8 = IO, r9 = Ring, r10d = Schreibposition, r11d = Zaehler, eax/edx = Leseindizes }
procedure CombBlockSSE(Args: PCombArgs);
asm
        .SAVENV XMM6
        .SAVENV XMM7
        mov     r8, [rcx].TCombArgs.IO
        mov     r9, [rcx].TCombArgs.Buf
        mov     r11d, [rcx].TCombArgs.Count
        mov     r10d, [rcx].TCombArgs.WritePos
        xorps   xmm0, xmm0
        xorps   xmm1, xmm1
        xorps   xmm2, xmm2
        movss   xmm5, [rcx].TCombArgs.Frac
        shufps  xmm5, xmm5, 0
        movss   xmm6, [rcx].TCombArgs.Fb
        shufps  xmm6, xmm6, 0
        movss   xmm7, [rcx].TCombArgs.MixX
        shufps  xmm7, xmm7, 0
        movss   xmm4, [rcx].TCombArgs.MixW
        shufps  xmm4, xmm4, 0
        test    r11d, r11d
        jle     @done
@loop:
        mov     eax, r10d
        sub     eax, [rcx].TCombArgs.DInt
        and     eax, [rcx].TCombArgs.Mask
        mov     edx, eax
        dec     edx
        and     edx, [rcx].TCombArgs.Mask
        movlps  xmm0, [r9 + rax * 8]
        movlps  xmm1, [r9 + rdx * 8]
        subps   xmm1, xmm0
        mulps   xmm1, xmm5
        addps   xmm0, xmm1
        mulps   xmm0, xmm6
        movlps  xmm2, [r8]
        addps   xmm0, xmm2
        mov     eax, r10d
        movlps  [r9 + rax * 8], xmm0
        mulps   xmm2, xmm7
        mulps   xmm0, xmm4
        addps   xmm2, xmm0
        movlps  [r8], xmm2
        add     r8, 8
        inc     r10d
        and     r10d, [rcx].TCombArgs.Mask
        dec     r11d
        jnz     @loop
@done:
        mov     [rcx].TCombArgs.WritePos, r10d
end;
{$ELSE}
procedure CombBlockSSE(Args: PCombArgs);
begin
  CombBlockPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Phaser
  ------------------------------------------------------------------------------ }
procedure PhaserBlockPas(Args: PPhaserArgs);
var
  I, C, K: Integer;
  X, Y, S: Single;
  A: array[0..1] of Single;
begin
  A[0] := Args.A4[0];
  A[1] := Args.A4[1];
  for I := 0 to Args.Count - 1 do
  begin
    for C := 0 to 1 do
    begin
      X := Args.IO[I * 2 + C];
      Y := X + Args.Fb4[C] * Args.Last[C];
      for K := 0 to 5 do
      begin
        S := A[C] * (Y - Args.Y1[K, C]) + Args.X1[K, C];
        Args.X1[K, C] := Y;
        Args.Y1[K, C] := S;
        Y := S;
      end;
      Args.Last[C] := Y;
      Args.IO[I * 2 + C] := Args.Dry4[C] * X + Args.Wet4[C] * Y;
      A[C] := A[C] + Args.DA4[C];
    end;
  end;
end;

{$IF Defined(CPUX86)}
{ SSE1, links/rechts in den Spuren 0/1 (obere Spuren bleiben 0); Zustand im Record (L1-Cache).
  xmm0 = x, xmm1 = y, xmm4 = Last, xmm5 = Fb, xmm6 = DA, xmm7 = a }
procedure PhaserBlockSSE(Args: PPhaserArgs);
asm
        push    esi
        mov     esi, [eax].TPhaserArgs.IO
        mov     ecx, [eax].TPhaserArgs.Count
        xorps   xmm0, xmm0
        xorps   xmm2, xmm2
        xorps   xmm4, xmm4
        movlps  xmm4, [eax].TPhaserArgs.Last
        movups  xmm5, [eax + TPhaserArgs.Fb4]
        movups  xmm6, [eax + TPhaserArgs.DA4]
        movups  xmm7, [eax + TPhaserArgs.A4]
        test    ecx, ecx
        jle     @done
@loop:
        movlps  xmm0, [esi]
        movaps  xmm1, xmm4
        mulps   xmm1, xmm5
        addps   xmm1, xmm0
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 0]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 0]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 0], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 0], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 8]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 8]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 8], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 8], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 16]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 16]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 16], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 16], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 24]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 24]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 24], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 24], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 32]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 32]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 32], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 32], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [eax + TPhaserArgs.Y1 + 40]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [eax + TPhaserArgs.X1 + 40]
        addps   xmm3, xmm2
        movlps  [eax + TPhaserArgs.X1 + 40], xmm1
        movlps  [eax + TPhaserArgs.Y1 + 40], xmm3
        movaps  xmm1, xmm3
        movaps  xmm4, xmm1
        movups  xmm2, [eax + TPhaserArgs.Dry4]
        mulps   xmm0, xmm2
        movups  xmm2, [eax + TPhaserArgs.Wet4]
        mulps   xmm1, xmm2
        addps   xmm0, xmm1
        movlps  [esi], xmm0
        addps   xmm7, xmm6
        add     esi, 8
        dec     ecx
        jnz     @loop
@done:
        movlps  [eax].TPhaserArgs.Last, xmm4
        pop     esi
end;
{$ELSEIF Defined(CPUX64)}
{ rcx = Args, r8 = IO, r9d = Zaehler }
procedure PhaserBlockSSE(Args: PPhaserArgs);
asm
        .SAVENV XMM6
        .SAVENV XMM7
        mov     r8, [rcx].TPhaserArgs.IO
        mov     r9d, [rcx].TPhaserArgs.Count
        xorps   xmm0, xmm0
        xorps   xmm2, xmm2
        xorps   xmm4, xmm4
        movlps  xmm4, [rcx].TPhaserArgs.Last
        movups  xmm5, [rcx + TPhaserArgs.Fb4]
        movups  xmm6, [rcx + TPhaserArgs.DA4]
        movups  xmm7, [rcx + TPhaserArgs.A4]
        test    r9d, r9d
        jle     @done
@loop:
        movlps  xmm0, [r8]
        movaps  xmm1, xmm4
        mulps   xmm1, xmm5
        addps   xmm1, xmm0
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 0]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 0]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 0], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 0], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 8]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 8]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 8], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 8], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 16]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 16]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 16], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 16], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 24]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 24]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 24], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 24], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 32]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 32]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 32], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 32], xmm3
        movaps  xmm1, xmm3
        movaps  xmm3, xmm1
        movlps  xmm2, [rcx + TPhaserArgs.Y1 + 40]
        subps   xmm3, xmm2
        mulps   xmm3, xmm7
        movlps  xmm2, [rcx + TPhaserArgs.X1 + 40]
        addps   xmm3, xmm2
        movlps  [rcx + TPhaserArgs.X1 + 40], xmm1
        movlps  [rcx + TPhaserArgs.Y1 + 40], xmm3
        movaps  xmm1, xmm3
        movaps  xmm4, xmm1
        movups  xmm2, [rcx + TPhaserArgs.Dry4]
        mulps   xmm0, xmm2
        movups  xmm2, [rcx + TPhaserArgs.Wet4]
        mulps   xmm1, xmm2
        addps   xmm0, xmm1
        movlps  [r8], xmm0
        addps   xmm7, xmm6
        add     r8, 8
        dec     r9d
        jnz     @loop
@done:
        movlps  [rcx].TPhaserArgs.Last, xmm4
end;
{$ELSE}
procedure PhaserBlockSSE(Args: PPhaserArgs);
begin
  PhaserBlockPas(Args);
end;
{$IFEND}

{ ------------------------------------------------------------------------------
  Chorus
  ------------------------------------------------------------------------------ }
procedure ChorusBlockPas(Args: PChorusArgs);
var
  I, C, Di, R0, R1: Integer;
  P, T, D: Cardinal;
  Fr, X, Y: Single;
begin
  for I := 0 to Args.Count - 1 do
  begin
    {$Q-}
    Args.Ph := Args.Ph + Args.PhInc;
    for C := 0 to 1 do
    begin
      P := Args.Ph + Cardinal(C) * $40000000;
      if P < $80000000 then T := P else T := not P;
      D := Args.Base8 + (Args.Span8 * (T shr 19)) shr 12;
      {$Q+}
      Fr := Integer(D and $FF) * Args.Inv256;
      Di := Integer(D shr 8);
      R0 := (Args.W - Di) and Args.Mask;
      R1 := (R0 - 1) and Args.Mask;
      Y := Args.Buf[R0 * 2 + C] + (Args.Buf[R1 * 2 + C] - Args.Buf[R0 * 2 + C]) * Fr;
      X := Args.IO[I * 2 + C];
      Args.Buf[Args.W * 2 + C] := X + Args.Fb * Y;
      Args.IO[I * 2 + C] := Args.Dry * X + Args.Wet * Y;
    end;
    Args.W := (Args.W + 1) and Args.Mask;
  end;
end;

{$IF Defined(CPUX86)}
{ SSE1 skalar je Kanal; eax = Args, esi = IO, edi = Ring, ebx = W, ecx = Zaehler, edx/ebp frei.
  xmm4 = Fb, xmm5 = Dry, xmm6 = Wet, xmm7 = 1/256 }
procedure ChorusBlockSSE(Args: PChorusArgs);
asm
        push    ebx
        push    esi
        push    edi
        push    ebp
        mov     esi, [eax].TChorusArgs.IO
        mov     edi, [eax].TChorusArgs.Buf
        mov     ecx, [eax].TChorusArgs.Count
        mov     ebx, [eax].TChorusArgs.W
        movss   xmm4, [eax].TChorusArgs.Fb
        movss   xmm5, [eax].TChorusArgs.Dry
        movss   xmm6, [eax].TChorusArgs.Wet
        movss   xmm7, [eax].TChorusArgs.Inv256
        test    ecx, ecx
        jle     @done
@loop:
        mov     edx, [eax].TChorusArgs.PhInc
        add     [eax].TChorusArgs.Ph, edx
        mov     edx, [eax].TChorusArgs.Ph
        test    edx, edx
        jns     @tri0
        not     edx
@tri0:
        shr     edx, 19
        imul    edx, [eax].TChorusArgs.Span8
        shr     edx, 12
        add     edx, [eax].TChorusArgs.Base8      // d (1/256 Samples)
        mov     ebp, edx
        and     ebp, $FF
        cvtsi2ss xmm3, ebp
        mulss   xmm3, xmm7                        // Bruchteil
        shr     edx, 8
        mov     ebp, ebx
        sub     ebp, edx
        and     ebp, [eax].TChorusArgs.Mask       // R0
        mov     edx, ebp
        dec     edx
        and     edx, [eax].TChorusArgs.Mask       // R1
        movss   xmm0, [edi + ebp * 8 + 0]
        movss   xmm1, [edi + edx * 8 + 0]
        subss   xmm1, xmm0
        mulss   xmm1, xmm3
        addss   xmm0, xmm1                        // y
        movss   xmm2, [esi + 0]               // x
        movaps  xmm1, xmm0
        mulss   xmm1, xmm4
        addss   xmm1, xmm2
        movss   [edi + ebx * 8 + 0], xmm1     // Ring = x + Fb * y
        mulss   xmm2, xmm5
        mulss   xmm0, xmm6
        addss   xmm2, xmm0
        movss   [esi + 0], xmm2
        mov     edx, [eax].TChorusArgs.Ph
        add     edx, $40000000
        test    edx, edx
        jns     @tri1
        not     edx
@tri1:
        shr     edx, 19
        imul    edx, [eax].TChorusArgs.Span8
        shr     edx, 12
        add     edx, [eax].TChorusArgs.Base8      // d (1/256 Samples)
        mov     ebp, edx
        and     ebp, $FF
        cvtsi2ss xmm3, ebp
        mulss   xmm3, xmm7                        // Bruchteil
        shr     edx, 8
        mov     ebp, ebx
        sub     ebp, edx
        and     ebp, [eax].TChorusArgs.Mask       // R0
        mov     edx, ebp
        dec     edx
        and     edx, [eax].TChorusArgs.Mask       // R1
        movss   xmm0, [edi + ebp * 8 + 4]
        movss   xmm1, [edi + edx * 8 + 4]
        subss   xmm1, xmm0
        mulss   xmm1, xmm3
        addss   xmm0, xmm1                        // y
        movss   xmm2, [esi + 4]               // x
        movaps  xmm1, xmm0
        mulss   xmm1, xmm4
        addss   xmm1, xmm2
        movss   [edi + ebx * 8 + 4], xmm1     // Ring = x + Fb * y
        mulss   xmm2, xmm5
        mulss   xmm0, xmm6
        addss   xmm2, xmm0
        movss   [esi + 4], xmm2
        add     esi, 8
        inc     ebx
        and     ebx, [eax].TChorusArgs.Mask
        dec     ecx
        jnz     @loop
@done:
        mov     [eax].TChorusArgs.W, ebx
        pop     ebp
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
{ rcx = Args, r8 = IO, r9 = Ring, r10d = W, r11d = Zaehler, eax/edx frei }
procedure ChorusBlockSSE(Args: PChorusArgs);
asm
        .SAVENV XMM6
        .SAVENV XMM7
        mov     r8, [rcx].TChorusArgs.IO
        mov     r9, [rcx].TChorusArgs.Buf
        mov     r11d, [rcx].TChorusArgs.Count
        mov     r10d, [rcx].TChorusArgs.W
        movss   xmm4, [rcx].TChorusArgs.Fb
        movss   xmm5, [rcx].TChorusArgs.Dry
        movss   xmm6, [rcx].TChorusArgs.Wet
        movss   xmm7, [rcx].TChorusArgs.Inv256
        test    r11d, r11d
        jle     @done
@loop:
        mov     edx, [rcx].TChorusArgs.PhInc
        add     [rcx].TChorusArgs.Ph, edx
        mov     edx, [rcx].TChorusArgs.Ph
        test    edx, edx
        jns     @tri0
        not     edx
@tri0:
        shr     edx, 19
        imul    edx, [rcx].TChorusArgs.Span8
        shr     edx, 12
        add     edx, [rcx].TChorusArgs.Base8
        mov     eax, edx
        and     eax, $FF
        cvtsi2ss xmm3, eax
        mulss   xmm3, xmm7
        shr     edx, 8
        mov     eax, r10d
        sub     eax, edx
        and     eax, [rcx].TChorusArgs.Mask
        mov     edx, eax
        dec     edx
        and     edx, [rcx].TChorusArgs.Mask
        movss   xmm0, [r9 + rax * 8 + 0]
        movss   xmm1, [r9 + rdx * 8 + 0]
        subss   xmm1, xmm0
        mulss   xmm1, xmm3
        addss   xmm0, xmm1
        movss   xmm2, [r8 + 0]
        movaps  xmm1, xmm0
        mulss   xmm1, xmm4
        addss   xmm1, xmm2
        mov     eax, r10d
        movss   [r9 + rax * 8 + 0], xmm1
        mulss   xmm2, xmm5
        mulss   xmm0, xmm6
        addss   xmm2, xmm0
        movss   [r8 + 0], xmm2
        mov     edx, [rcx].TChorusArgs.Ph
        add     edx, $40000000
        test    edx, edx
        jns     @tri1
        not     edx
@tri1:
        shr     edx, 19
        imul    edx, [rcx].TChorusArgs.Span8
        shr     edx, 12
        add     edx, [rcx].TChorusArgs.Base8
        mov     eax, edx
        and     eax, $FF
        cvtsi2ss xmm3, eax
        mulss   xmm3, xmm7
        shr     edx, 8
        mov     eax, r10d
        sub     eax, edx
        and     eax, [rcx].TChorusArgs.Mask
        mov     edx, eax
        dec     edx
        and     edx, [rcx].TChorusArgs.Mask
        movss   xmm0, [r9 + rax * 8 + 4]
        movss   xmm1, [r9 + rdx * 8 + 4]
        subss   xmm1, xmm0
        mulss   xmm1, xmm3
        addss   xmm0, xmm1
        movss   xmm2, [r8 + 4]
        movaps  xmm1, xmm0
        mulss   xmm1, xmm4
        addss   xmm1, xmm2
        mov     eax, r10d
        movss   [r9 + rax * 8 + 4], xmm1
        mulss   xmm2, xmm5
        mulss   xmm0, xmm6
        addss   xmm2, xmm0
        movss   [r8 + 4], xmm2
        add     r8, 8
        inc     r10d
        and     r10d, [rcx].TChorusArgs.Mask
        dec     r11d
        jnz     @loop
@done:
        mov     [rcx].TChorusArgs.W, r10d
end;
{$ELSE}
procedure ChorusBlockSSE(Args: PChorusArgs);
begin
  ChorusBlockPas(Args);
end;
{$IFEND}

{ ---------- 2x-Oversampling: Halbband-FIR ---------- }

procedure HbInitArgs(var A: THbArgs; Scale, Center: Single);
var
  K, J: Integer;
begin
  for J := 0 to 3 do
  begin
    A.C4[0, J] := Center;
    for K := 1 to HB_PAIRS do
      A.C4[K, J] := HB_COEF[K - 1] * Scale;
  end;
end;

procedure HbFirPas(Args: PHbArgs);
var
  I, K: Integer;
  D, Aa: PByte;
  L, R: Single;
begin
  with Args^ do
    for I := 0 to Count - 1 do
    begin
      L := C4[0, 0] * PSingle(PC)^;
      R := C4[0, 1] * PSingle(PC + 4)^;
      D := PD;
      Aa := PA;
      for K := 1 to HB_PAIRS do
      begin
        L := L + (PSingle(D)^ + PSingle(Aa)^) * C4[K, 0];
        R := R + (PSingle(D + 4)^ + PSingle(Aa + 4)^) * C4[K, 1];
        Dec(D, TapStep);
        Inc(Aa, TapStep);
      end;
      PSingle(Out)^ := L;
      PSingle(Out + 4)^ := R;
      Inc(Out, OutStep);
      Inc(PD, InStep);
      Inc(PA, InStep);
      Inc(PC, InStep);
    end;
end;

{ SSE: zwei Ausgabe-Frames je Durchlauf in den vier Spuren [L0 R0 L1 R1] (movlps/movhps), gleiche
  Rechenreihenfolge wie die Pascal-Referenz. Nur xmm0-xmm3 (unter x64 fluechtig). }
{$IF Defined(CPUX86)}
procedure HbFirKernel(Args: PHbArgs);
asm
        push    ebx
        push    esi
        push    edi
        push    ebp
        mov     ecx, [eax].THbArgs.Count
        shr     ecx, 1
        jz      @Done
        mov     [eax].THbArgs.Pairs, ecx
        mov     ebp, [eax].THbArgs.InStep
@Outer:
        mov     esi, [eax].THbArgs.PD
        mov     edi, [eax].THbArgs.PA
        mov     edx, [eax].THbArgs.PC
        movlps  xmm0, [edx]
        movhps  xmm0, [edx+ebp]
        movups  xmm3, [eax + THbArgs.C4]
        mulps   xmm0, xmm3
        lea     ebx, [eax + THbArgs.C4]
        add     ebx, 16
        mov     ecx, HB_PAIRS
        mov     edx, [eax].THbArgs.TapStep
@Inner:
        movlps  xmm1, [esi]
        movhps  xmm1, [esi+ebp]
        movlps  xmm2, [edi]
        movhps  xmm2, [edi+ebp]
        addps   xmm1, xmm2
        movups  xmm3, [ebx]
        mulps   xmm1, xmm3
        addps   xmm0, xmm1
        sub     esi, edx
        add     edi, edx
        add     ebx, 16
        dec     ecx
        jnz     @Inner
        mov     edx, [eax].THbArgs.Out
        mov     ecx, [eax].THbArgs.OutStep
        movlps  [edx], xmm0
        movhps  [edx+ecx], xmm0
        lea     edx, [edx+ecx*2]
        mov     [eax].THbArgs.Out, edx
        lea     ecx, [ebp+ebp]
        add     [eax].THbArgs.PD, ecx
        add     [eax].THbArgs.PA, ecx
        add     [eax].THbArgs.PC, ecx
        dec     dword ptr [eax].THbArgs.Pairs
        jnz     @Outer
@Done:
        pop     ebp
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
procedure HbFirKernel(Args: PHbArgs);
asm
        mov     eax, [rcx].THbArgs.Count
        shr     eax, 1
        jz      @Done
        mov     [rcx].THbArgs.Pairs, eax
        movsxd  r10, dword ptr [rcx].THbArgs.InStep
        movsxd  r11, dword ptr [rcx].THbArgs.TapStep
@Outer:
        mov     rax, [rcx].THbArgs.PD
        mov     r8, [rcx].THbArgs.PA
        mov     rdx, [rcx].THbArgs.PC
        movlps  xmm0, [rdx]
        movhps  xmm0, [rdx+r10]
        movups  xmm3, [rcx + THbArgs.C4]
        mulps   xmm0, xmm3
        lea     rdx, [rcx + THbArgs.C4]
        add     rdx, 16
        mov     r9d, HB_PAIRS
@Inner:
        movlps  xmm1, [rax]
        movhps  xmm1, [rax+r10]
        movlps  xmm2, [r8]
        movhps  xmm2, [r8+r10]
        addps   xmm1, xmm2
        movups  xmm3, [rdx]
        mulps   xmm1, xmm3
        addps   xmm0, xmm1
        sub     rax, r11
        add     r8, r11
        add     rdx, 16
        dec     r9d
        jnz     @Inner
        mov     rdx, [rcx].THbArgs.Out
        movsxd  r9, dword ptr [rcx].THbArgs.OutStep
        movlps  [rdx], xmm0
        movhps  [rdx+r9], xmm0
        lea     rdx, [rdx+r9*2]
        mov     [rcx].THbArgs.Out, rdx
        lea     rax, [r10+r10]
        add     [rcx].THbArgs.PD, rax
        add     [rcx].THbArgs.PA, rax
        add     [rcx].THbArgs.PC, rax
        dec     dword ptr [rcx].THbArgs.Pairs
        jnz     @Outer
@Done:
end;
{$ELSE}
procedure HbFirKernel(Args: PHbArgs);
begin
  HbFirPas(Args);
end;
{$IFEND}

procedure HbFirSSE(Args: PHbArgs);
var
  Odd: Boolean;
begin
  Odd := (Args.Count and 1) <> 0;
  HbFirKernel(Args);                // gerade Anzahl, Zeiger stehen danach dahinter
  if Odd then
  begin
    Args.Count := 1;
    HbFirPas(Args);
  end;
end;

{ ---------- Wavetable-Oszillator (gezeichnete Welle) ---------- }

procedure WtBlockPas(Args: PWtArgs);
type
  TSA = array[0..$FFFFFF] of Single;
  PSA = ^TSA;
var
  N, I: Integer;
  Ph, W, X, F, Va, Vb, E: Single;
  O, En, Ta, Tb: PSA;
begin
  O := PSA(Args.Out);
  En := PSA(Args.Env);
  Ta := PSA(Args.TabA);
  Tb := PSA(Args.TabB);
  Ph := Args.Ph;
  for N := 0 to Args.Count - 1 do
  begin
    W := Ph * Args.SyncR;
    W := W - Trunc(W);
    X := W * Args.CSizeA;
    I := Trunc(X);
    F := X - I;
    Va := Ta[I] + (Ta[I + 1] - Ta[I]) * F;
    X := W * Args.CSizeB;
    I := Trunc(X);
    F := X - I;
    Vb := Tb[I] + (Tb[I + 1] - Tb[I]) * F;
    Va := Va + (Vb - Va) * Args.Mix;
    E := Va * En[N];
    O[N * 2] := O[N * 2] + E * Args.GL;
    O[N * 2 + 1] := O[N * 2 + 1] + E * Args.GR;
    Ph := Ph + Args.DtP;
    if Ph >= Args.One then
      Ph := Ph - Args.One;
  end;
  Args.Ph := Ph;
end;

{ SSE skalar, gleiche Rechenreihenfolge wie die Pascal-Referenz; nur xmm0-xmm5 }
{$IF Defined(CPUX86)}
procedure WtBlockSSE(Args: PWtArgs);
asm
        push    ebx
        push    esi
        push    edi
        push    ebp
        mov     ecx, [eax].TWtArgs.Count
        test    ecx, ecx
        jle     @Done
        mov     esi, [eax].TWtArgs.Out
        mov     edi, [eax].TWtArgs.Env
        mov     ebx, [eax].TWtArgs.TabA
        mov     ebp, [eax].TWtArgs.TabB
        movss   xmm5, [eax].TWtArgs.Ph
@Loop:
        movaps  xmm0, xmm5
        mulss   xmm0, [eax].TWtArgs.SyncR
        cvttss2si edx, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, edx
        subss   xmm0, xmm1                 // w
        movaps  xmm4, xmm0
        mulss   xmm0, [eax].TWtArgs.CSizeA
        cvttss2si edx, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, edx
        subss   xmm0, xmm1                 // f
        movss   xmm2, [ebx+edx*4]
        movss   xmm3, [ebx+edx*4+4]
        subss   xmm3, xmm2
        mulss   xmm3, xmm0
        addss   xmm2, xmm3                 // a
        mulss   xmm4, [eax].TWtArgs.CSizeB
        cvttss2si edx, xmm4
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, edx
        subss   xmm4, xmm1
        movss   xmm3, [ebp+edx*4]
        movss   xmm0, [ebp+edx*4+4]
        subss   xmm0, xmm3
        mulss   xmm0, xmm4
        addss   xmm3, xmm0                 // b
        subss   xmm3, xmm2
        mulss   xmm3, [eax].TWtArgs.Mix
        addss   xmm2, xmm3                 // a + (b - a) * Mix
        mulss   xmm2, [edi]
        movaps  xmm3, xmm2
        mulss   xmm3, [eax].TWtArgs.GL
        addss   xmm3, [esi]
        movss   [esi], xmm3
        mulss   xmm2, [eax].TWtArgs.GR
        addss   xmm2, [esi+4]
        movss   [esi+4], xmm2
        addss   xmm5, [eax].TWtArgs.DtP
        comiss  xmm5, [eax].TWtArgs.One
        jb      @NoWrap
        subss   xmm5, [eax].TWtArgs.One
@NoWrap:
        add     esi, 8
        add     edi, 4
        dec     ecx
        jnz     @Loop
        movss   [eax].TWtArgs.Ph, xmm5
@Done:
        pop     ebp
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
procedure WtBlockSSE(Args: PWtArgs);
asm
        push    rbx
        mov     r9d, [rcx].TWtArgs.Count
        test    r9d, r9d
        jle     @Done
        mov     r8, [rcx].TWtArgs.Out
        mov     r10, [rcx].TWtArgs.Env
        mov     r11, [rcx].TWtArgs.TabA
        mov     rbx, [rcx].TWtArgs.TabB
        movss   xmm5, [rcx].TWtArgs.Ph
@Loop:
        movaps  xmm0, xmm5
        mulss   xmm0, [rcx].TWtArgs.SyncR
        cvttss2si eax, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, eax
        subss   xmm0, xmm1
        movaps  xmm4, xmm0
        mulss   xmm0, [rcx].TWtArgs.CSizeA
        cvttss2si eax, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, eax
        subss   xmm0, xmm1
        movsxd  rdx, eax
        movss   xmm2, [r11+rdx*4]
        movss   xmm3, [r11+rdx*4+4]
        subss   xmm3, xmm2
        mulss   xmm3, xmm0
        addss   xmm2, xmm3
        mulss   xmm4, [rcx].TWtArgs.CSizeB
        cvttss2si eax, xmm4
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, eax
        subss   xmm4, xmm1
        movsxd  rdx, eax
        movss   xmm3, [rbx+rdx*4]
        movss   xmm0, [rbx+rdx*4+4]
        subss   xmm0, xmm3
        mulss   xmm0, xmm4
        addss   xmm3, xmm0
        subss   xmm3, xmm2
        mulss   xmm3, [rcx].TWtArgs.Mix
        addss   xmm2, xmm3
        mulss   xmm2, [r10]
        movaps  xmm3, xmm2
        mulss   xmm3, [rcx].TWtArgs.GL
        addss   xmm3, [r8]
        movss   [r8], xmm3
        mulss   xmm2, [rcx].TWtArgs.GR
        addss   xmm2, [r8+4]
        movss   [r8+4], xmm2
        addss   xmm5, [rcx].TWtArgs.DtP
        comiss  xmm5, [rcx].TWtArgs.One
        jb      @NoWrap
        subss   xmm5, [rcx].TWtArgs.One
@NoWrap:
        add     r8, 8
        add     r10, 4
        dec     r9d
        jnz     @Loop
        movss   [rcx].TWtArgs.Ph, xmm5
@Done:
        pop     rbx
end;
{$ELSE}
procedure WtBlockSSE(Args: PWtArgs);
begin
  WtBlockPas(Args);
end;
{$IFEND}

procedure WtFastPas(Args: PWtArgs);
type
  TSA = array[0..$FFFFFF] of Single;
  PSA = ^TSA;
var
  N, I: Integer;
  Ph, X, F, Va, Vb, E: Single;
  O, En, Ta, Tb: PSA;
begin
  O := PSA(Args.Out);
  En := PSA(Args.Env);
  Ta := PSA(Args.TabA);
  Tb := PSA(Args.TabB);
  Ph := Args.Ph;
  for N := 0 to Args.Count - 1 do
  begin
    X := Ph * Args.CSizeA;
    I := Trunc(X);
    F := X - I;
    Va := Ta[I] + (Ta[I + 1] - Ta[I]) * F;
    Vb := Tb[I] + (Tb[I + 1] - Tb[I]) * F;
    Va := Va + (Vb - Va) * Args.Mix;
    E := Va * En[N];
    O[N * 2] := O[N * 2] + E * Args.GL;
    O[N * 2 + 1] := O[N * 2 + 1] + E * Args.GR;
    Ph := Ph + Args.DtP;
    if Ph >= Args.One then
      Ph := Ph - Args.One;
  end;
  Args.Ph := Ph;
end;

{$IF Defined(CPUX86)}
procedure WtFastSSE(Args: PWtArgs);
asm
        push    ebx
        push    esi
        push    edi
        push    ebp
        mov     ecx, [eax].TWtArgs.Count
        test    ecx, ecx
        jle     @Done
        mov     esi, [eax].TWtArgs.Out
        mov     edi, [eax].TWtArgs.Env
        mov     ebx, [eax].TWtArgs.TabA
        mov     ebp, [eax].TWtArgs.TabB
        movss   xmm5, [eax].TWtArgs.Ph
        movss   xmm4, [eax].TWtArgs.Mix
@Loop:
        movaps  xmm0, xmm5
        mulss   xmm0, [eax].TWtArgs.CSizeA
        cvttss2si edx, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, edx
        subss   xmm0, xmm1                 // f
        movss   xmm2, [ebx+edx*4]
        movss   xmm3, [ebx+edx*4+4]
        subss   xmm3, xmm2
        mulss   xmm3, xmm0
        addss   xmm2, xmm3                 // a
        movss   xmm3, [ebp+edx*4]
        movss   xmm1, [ebp+edx*4+4]
        subss   xmm1, xmm3
        mulss   xmm1, xmm0
        addss   xmm3, xmm1                 // b
        subss   xmm3, xmm2
        mulss   xmm3, xmm4
        addss   xmm2, xmm3
        mulss   xmm2, [edi]
        movaps  xmm3, xmm2
        mulss   xmm3, [eax].TWtArgs.GL
        addss   xmm3, [esi]
        movss   [esi], xmm3
        mulss   xmm2, [eax].TWtArgs.GR
        addss   xmm2, [esi+4]
        movss   [esi+4], xmm2
        addss   xmm5, [eax].TWtArgs.DtP
        comiss  xmm5, [eax].TWtArgs.One
        jb      @NoWrap
        subss   xmm5, [eax].TWtArgs.One
@NoWrap:
        add     esi, 8
        add     edi, 4
        dec     ecx
        jnz     @Loop
        movss   [eax].TWtArgs.Ph, xmm5
@Done:
        pop     ebp
        pop     edi
        pop     esi
        pop     ebx
end;
{$ELSEIF Defined(CPUX64)}
procedure WtFastSSE(Args: PWtArgs);
asm
        push    rbx
        mov     r9d, [rcx].TWtArgs.Count
        test    r9d, r9d
        jle     @Done
        mov     r8, [rcx].TWtArgs.Out
        mov     r10, [rcx].TWtArgs.Env
        mov     r11, [rcx].TWtArgs.TabA
        mov     rbx, [rcx].TWtArgs.TabB
        movss   xmm5, [rcx].TWtArgs.Ph
        movss   xmm4, [rcx].TWtArgs.Mix
@Loop:
        movaps  xmm0, xmm5
        mulss   xmm0, [rcx].TWtArgs.CSizeA
        cvttss2si eax, xmm0
        xorps   xmm1, xmm1
        cvtsi2ss xmm1, eax
        subss   xmm0, xmm1
        movsxd  rdx, eax
        movss   xmm2, [r11+rdx*4]
        movss   xmm3, [r11+rdx*4+4]
        subss   xmm3, xmm2
        mulss   xmm3, xmm0
        addss   xmm2, xmm3
        movss   xmm3, [rbx+rdx*4]
        movss   xmm1, [rbx+rdx*4+4]
        subss   xmm1, xmm3
        mulss   xmm1, xmm0
        addss   xmm3, xmm1
        subss   xmm3, xmm2
        mulss   xmm3, xmm4
        addss   xmm2, xmm3
        mulss   xmm2, [r10]
        movaps  xmm3, xmm2
        mulss   xmm3, [rcx].TWtArgs.GL
        addss   xmm3, [r8]
        movss   [r8], xmm3
        mulss   xmm2, [rcx].TWtArgs.GR
        addss   xmm2, [r8+4]
        movss   [r8+4], xmm2
        addss   xmm5, [rcx].TWtArgs.DtP
        comiss  xmm5, [rcx].TWtArgs.One
        jb      @NoWrap
        subss   xmm5, [rcx].TWtArgs.One
@NoWrap:
        add     r8, 8
        add     r10, 4
        dec     r9d
        jnz     @Loop
        movss   [rcx].TWtArgs.Ph, xmm5
@Done:
        pop     rbx
end;
{$ELSE}
procedure WtFastSSE(Args: PWtArgs);
begin
  WtFastPas(Args);
end;
{$IFEND}

{ komplexe FFT (radix 2, an Ort und Stelle), Sign = +1 ruecklaeufig ohne 1/N, -1 vorwaerts }
procedure WtFft(var Re, Im: array of Double; N, Sign: Integer);
var
  I, J, K, M, Step: Integer;
  T, Wr, Wi, Ar, Ai, Tr, Ti, Ang: Double;
begin
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      T := Re[I]; Re[I] := Re[J]; Re[J] := T;
      T := Im[I]; Im[I] := Im[J]; Im[J] := T;
    end;
    K := N shr 1;
    while (K >= 1) and (J >= K) do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  Step := 1;
  while Step < N do
  begin
    for M := 0 to Step - 1 do
    begin
      Ang := Sign * Pi * M / Step;
      Wr := Cos(Ang);
      Wi := Sin(Ang);
      I := M;
      while I < N do
      begin
        J := I + Step;
        Ar := Re[J] * Wr - Im[J] * Wi;
        Ai := Re[J] * Wi + Im[J] * Wr;
        Tr := Re[I];
        Ti := Im[I];
        Re[J] := Tr - Ar;
        Im[J] := Ti - Ai;
        Re[I] := Tr + Ar;
        Im[I] := Ti + Ai;
        Inc(I, Step * 2);
      end;
    end;
    Step := Step * 2;
  end;
end;

procedure WtAnalyze(const X: array of Single; N: Integer; var A, B: array of Double);
var
  Re, Im: array of Double;
  K: Integer;
begin
  SetLength(Re, N);
  SetLength(Im, N);
  for K := 0 to N - 1 do
  begin
    Re[K] := X[K];
    Im[K] := 0;
  end;
  WtFft(Re, Im, N, -1);
  // X[k] = Summe x e^(-i 2 pi k n / N)  ->  a_k = 2 Re / N, b_k = -2 Im / N
  for K := 1 to N div 2 - 1 do
  begin
    A[K] := 2 * Re[K] / N;
    B[K] := -2 * Im[K] / N;
  end;
end;

procedure WtBuild(const A, B: array of Double; NH: Integer; Dst: PSingle; Normalize: Boolean);
type
  TSA = array[0..$FFFFFF] of Single;
var
  Re, Im: array of Double;
  M, L, K, H, I: Integer;
  T: ^TSA;
  Peak, Sc: Double;
begin
  Sc := 1;
  for M := 0 to WT_MIPS - 1 do
  begin
    L := WT_LEN[M];
    H := Min(Min(WT_HARM[M], NH), L div 2 - 1);
    SetLength(Re, L);
    SetLength(Im, L);
    for I := 0 to L - 1 do
    begin
      Re[I] := 0;
      Im[I] := 0;
    end;
    // x(n) = Summe (a cos + b sin) = Summe X[k] e^(+i...), X[k] = (a - i b)/2, X[L-k] = konjugiert
    for K := 1 to H do
    begin
      Re[K] := A[K] / 2;
      Im[K] := -B[K] / 2;
      Re[L - K] := A[K] / 2;
      Im[L - K] := B[K] / 2;
    end;
    WtFft(Re, Im, L, 1);
    if (M = 0) and Normalize then
    begin
      Peak := 0;
      for I := 0 to L - 1 do
        Peak := Max(Peak, Abs(Re[I]));
      if Peak > 1E-9 then Sc := 1 / Peak else Sc := 0;
    end;
    T := Pointer(PByte(Dst) + WT_OFS[M] * SizeOf(Single));
    for I := 0 to L - 1 do
      T[I] := Re[I] * Sc;
    T[L] := T[0];
    T[L + 1] := T[1];
  end;
end;

function CpuHasSSE: Boolean;
{$IFDEF CPUX86}
var
  Features: Cardinal;
begin
  asm
        push    ebx
        // CPUID vorhanden? (ID-Bit 21 in EFLAGS umschaltbar)
        pushfd
        pop     eax
        mov     ecx, eax
        xor     eax, $200000
        push    eax
        popfd
        pushfd
        pop     eax
        xor     eax, ecx
        mov     Features, 0
        jz      @NoCpuid
        mov     eax, 1
        cpuid
        mov     Features, edx
@NoCpuid:
        pop     ebx
  end;
  Result := (Features and (1 shl 25)) <> 0;   // EDX Bit 25 = SSE
end;
{$ELSE}
begin
  Result := True;
end;
{$ENDIF}

function CpuHasSSE2: Boolean;
{$IFDEF CPUX86}
var
  Features: Cardinal;
begin
  Features := 0;
  if not CpuHasSSE then
    Exit(False);
  asm
        push    ebx
        mov     eax, 1
        cpuid
        mov     Features, edx
        pop     ebx
  end;
  Result := (Features and (1 shl 26)) <> 0;   // EDX Bit 26 = SSE2
end;
{$ELSE}
begin
  Result := True;   // x64 hat immer SSE2
end;
{$ENDIF}

procedure InitDSP(AllowSSE: Boolean);
begin
  InitReverbDSP(AllowSSE and CpuHasSSE);
  InitEqDSP(AllowSSE and CpuHasSSE2);
  if AllowSSE and CpuHasSSE then
  begin
    RenderGrain := RenderGrainSSE;
    RenderGrainHQ := RenderGrainHQSSE;
    RenderSvf := SvfBlockSSE;
    RenderSat := SatBlockSSE;
    RenderShape := ShapeBlockSSE;
    RenderOscBlock := OscBlockSSE;
    RenderEnvSeg := EnvSegSSE;
    RenderComb := CombBlockSSE;
    RenderPhaser := PhaserBlockSSE;
    RenderChorus := ChorusBlockSSE;
    RenderHbFir := HbFirSSE;
    RenderWt := WtBlockSSE;
    RenderWtFast := WtFastSSE;
    {$IFDEF CPUX64}
    DSPPathName := 'SSE x64';
    {$ELSE}
    DSPPathName := 'SSE';
    {$ENDIF}
  end
  else
  begin
    RenderGrain := RenderGrainPas;
    RenderGrainHQ := RenderGrainHQPas;
    RenderSvf := SvfBlockPas;
    RenderSat := SatBlockPas;
    RenderShape := ShapeBlockPas;
    RenderOscBlock := OscBlockPas;
    RenderEnvSeg := EnvSegPas;
    RenderComb := CombBlockPas;
    RenderPhaser := PhaserBlockPas;
    RenderChorus := ChorusBlockPas;
    RenderHbFir := HbFirPas;
    RenderWt := WtBlockPas;
    RenderWtFast := WtFastPas;
    DSPPathName := 'Pascal';
  end;
end;

initialization
  InitDSP;

end.
