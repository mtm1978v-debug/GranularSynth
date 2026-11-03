{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Engine;

{ Granular-Synthese-Engine. Frei von VCL - wird spaeter unveraendert im VST2-Plugin
  verwendet. Schnittstelle bewusst VST2-nah:
    - Process(InL, InR, OutL, OutR, Frames) ~ processReplacing; In = Sidechain (darf nil sein)
    - NoteOn/NoteOff(..., DeltaFrames)      ~ processEvents (MIDI mit Sample-Offset)
    - GetParam/SetParam normalisiert 0..1   ~ getParameter/setParameter
  Modulation: 2 LFOs, Sidechain-Huellkurvenfolger, Velocity, Zufall, Notenhoehe ->
  Matrix mit MOD_SLOTS Slots, wirkt im normalisierten Raum auf jeden benannten Parameter
  (also auch auf die LFOs selbst). Aufloesung: SUB_BLOCK Samples.
  Threading: Process laeuft im Audio-Thread; Noten/Parameter/Samplewechsel sind aus
  dem GUI-Thread sicher aufrufbar. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Math,
  Granular.Params, Granular.Sample, Granular.DSP, Granular.Pitch, Granular.Reverb, Granular.Eq;

const
  MAX_VOICES    = 32;
  { Polyphone Modulation: diese Ziele werden je Note berechnet (Grain-Erzeugung, Oszillator).
    Quellen, die an einer Note haengen (Velocity, Zufall je Note, Notenhoehe, Grain-/Osz-Huellkurven und
    LFOs mit Neustart "Note an/aus"), wirken auf diese Ziele nur in der eigenen Note. }
  PND_COUNT = 85;
  PND_IDS: array[0..PND_COUNT - 1] of TGranularParamId = (gpPosition, gpSpray, gpPitch, gpPitchRand,
    gpSpread, gpGrainPan, gpReverse, gpVolume, gpGrainSize, gpDensity,
    gpOscFine, gpOscLevel, gpOscPan, gpOscFmAmt, gpOscFmRatio, gpOscSync,
    gpFltCutoff, gpFltReso, gpFltEnvAmt, gpFlt2Cutoff, gpFlt2Reso, gpFlt2EnvAmt,
    gpOscFltCutoff, gpOscFltReso, gpOscFltEnvAmt,
    // Huellkurven je Note (Lautstaerke, Oszillator, FM, Filter), Scan, Filter-Konturen, Noten-LFO-Raten
    gpAttack, gpDecay, gpSustain, gpRelease,
    gpOscAttack, gpOscDecay, gpOscSustain, gpOscRelease,
    gpOscFmAttack, gpOscFmDecay, gpOscFmSustain, gpOscFmRelease,
    gpFltAttack, gpFltDecay, gpFltSustain, gpFltRelease,
    gpScan, gpFltContour, gpFlt2Contour, gpOscFltContour,
    gpLfo1Rate, gpLfo2Rate, gpLfo3Rate, gpLfo4Rate,
    // Oszillator 2 je Note
    gpOsc2Fine, gpOsc2Level, gpOsc2Pan, gpOsc2FmAmt, gpOsc2FmRatio, gpOsc2Sync, gpOsc2FltCutoff, gpOsc2FltReso, gpOsc2FltEnvAmt, gpOsc2FltContour, gpOsc2Attack, gpOsc2Decay, gpOsc2Sustain, gpOsc2Release, gpOsc2FmAttack, gpOsc2FmDecay, gpOsc2FmSustain, gpOsc2FmRelease,
    // Oszillator 3 je Note
    gpOsc3Fine, gpOsc3Level, gpOsc3Pan, gpOsc3FmAmt, gpOsc3FmRatio, gpOsc3Sync, gpOsc3FltCutoff, gpOsc3FltReso, gpOsc3FltEnvAmt, gpOsc3FltContour, gpOsc3Attack, gpOsc3Decay, gpOsc3Sustain, gpOsc3Release, gpOsc3FmAttack, gpOsc3FmDecay, gpOsc3FmSustain, gpOsc3FmRelease);
  PND_POS = 0; PND_SPRAY = 1; PND_PITCH = 2; PND_PRAND = 3; PND_SPREAD = 4; PND_GPAN = 5;
  PND_REV = 6; PND_VOL = 7; PND_SIZE = 8; PND_DENS = 9; PND_OFINE = 10; PND_OLVL = 11;
  PND_OPAN = 12; PND_OFM = 13; PND_ORATIO = 14; PND_OSYNC = 15;
  PND_F1CUT = 16; PND_F1RES = 17; PND_F1ENV = 18; PND_F2CUT = 19; PND_F2RES = 20; PND_F2ENV = 21;
  PND_OFCUT = 22; PND_OFRES = 23; PND_OFENV = 24;
  PND_AATT = 25; PND_ADEC = 26; PND_ASUS = 27; PND_AREL = 28;
  PND_OATT = 29; PND_ODEC = 30; PND_OSUS = 31; PND_OREL = 32;
  PND_FATT = 33; PND_FDEC = 34; PND_FSUS = 35; PND_FREL = 36;
  PND_FLATT = 37; PND_FLDEC = 38; PND_FLSUS = 39; PND_FLREL = 40;
  PND_SCAN = 41; PND_F1CON = 42; PND_F2CON = 43; PND_OFCON = 44;
  PND_LFORATE = 45;   // .. 48: Rate LFO 1..4
  { je Oszillator: Index der Noten-Werte (Oszillator 1 verstreut, 2 und 3 ab 49 bzw. 67 am Stueck) }
  OP_FINE = 0; OP_LVL = 1; OP_PAN = 2; OP_FM = 3; OP_RATIO = 4; OP_SYNC = 5; OP_FCUT = 6; OP_FRES = 7;
  OP_FENV = 8; OP_FCON = 9; OP_ATT = 10; OP_DEC = 11; OP_SUS = 12; OP_REL = 13; OP_FMATT = 14;
  OP_FMDEC = 15; OP_FMSUS = 16; OP_FMREL = 17;
  OSC_PND: array[0..2, 0..17] of Integer = (
    (PND_OFINE, PND_OLVL, PND_OPAN, PND_OFM, PND_ORATIO, PND_OSYNC, PND_OFCUT, PND_OFRES, PND_OFENV,
     PND_OFCON, PND_OATT, PND_ODEC, PND_OSUS, PND_OREL, PND_FATT, PND_FDEC, PND_FSUS, PND_FREL),
    (49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66),
    (67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84));
  MAX_GRAINS    = 1024;
  { Mischpult-Pegel: Grains, Osz 1..3, Echo, Hall, Summe, Ausgang }
  MIX_METERS = 12;
  MM_GRAINS = 0; MM_OSC1 = 1; MM_ECHO = 4; MM_HALL = 5; MM_SUM = 6; MM_OUT = 7;
  MM_GATE = 8; MM_CRUSH = 9; MM_CHO = 10; MM_PHA = 11;   // was der jeweilige Effekt veraendert
  SUB_BLOCK     = 64;    // interne Blockgroesse (Huellkurven-/Modulations-/Eventaufloesung)
  COMB_LEN      = 4096;  // Ring des Kammfilters (Frames, Zweierpotenz): tiefster Ton ~ Samplerate / 4094
  CHO_LEN       = 4096;  // Chorus-Verzoegerung (Frames, Zweierpotenz)
  PHA_STAGES    = 6;     // Allpass-Stufen des Phasers
  ZONE_COUNT    = 3;     // zusaetzliche Samples je Tastenbereich (Zone 0 = Hauptsample)
  UNI_MAX       = 7;     // Unison-Stimmen je Oszillator
  GRAIN_HISTORY = 128;   // fuer die Anzeige
  MAX_EVENTS    = 256;
  ROOT_NOTE     = 60;    // C4 = Originaltonhoehe
  SCOPE_SIZE    = 4096;  // Ringpuffer fuer Oszilloskop-Anzeige (Zweierpotenz)

const
  { Vorausschau des Ausgangs-Limiters in Samples (wird dem Host als Latenz gemeldet) }
  LIM_LOOK = 64;

type
  TEnvStage = (esIdle, esAttack, esDecay, esSustain, esRelease);

  TVoice = record
    Stage: TEnvStage;
    Note: Integer;
    Velocity: Single;
    Env: Single;
    StageTime: Integer;  // Samples seit Beginn der aktuellen Phase
    ScanPos: Double;     // Fortschritt innerhalb der Auswahl (0..1, umlaufend; < 0 = im Anlauf davor)
    ScanDir: Integer;    // Schleife hin und her: +1 vorwaerts, -1 rueckwaerts
    InPre: Boolean;      // laeuft noch im Anlauf (vor der Auswahl, ohne Umlauf)
    NextGrain: Double;   // Samples bis zum naechsten Grain
    Stamp: Int64;        // fuer Voice-Stealing (aelteste zuerst)
  end;

  { Zustand eines Filters (Filter 1/2, global oder je Stimme): bis zu drei SVF-Stufen
    (Ladder = zwei Tiefpaesse in Reihe, Formant = drei Bandpaesse parallel) und der Kammfilter }
  TFltState = record
    Svf: array[0..2] of TSvfArgs;
    Comb: TCombArgs;
    CombUsed: Boolean;     // Ring enthaelt Signal -> beim Zuruecksetzen leeren
  end;

const
  RES_BUFS = 3;          // Feedback-Resampling: spielend, vorig, Ziel

type
  TGrain = record
    Zone: Integer;       // 0 = Hauptsample, 1..ZONE_COUNT = Zonen-Sample
    Active: Boolean;
    Voice: Integer;
    Delay: Integer;      // Startversatz im aktuellen Subblock
    Remaining: Integer;
    UseB: Boolean;       // Grain stammt aus dem Sample des Morph-Ziels B
    Src: TSampleData;    // Hauptsample beim Start (Resampling tauscht es; das Grain liest bis zum Ende daraus)
    Args: TGrainRenderArgs;
  end;

  TNoteEventKind = (neOn, neOff, neAllOff, neBend, neControl, nePressure, neResetCtrl);

  PNoteEvent = ^TNoteEvent;
  TNoteEvent = record
    Kind: TNoteEventKind;
    Note: Integer;       // bei neControl: Controller-Nummer
    Velocity: Single;    // bei neBend -1..1, neControl/nePressure 0..1
    DeltaFrames: Integer;
  end;

  { Trigger-Protokoll (nur fuer die Anzeige im Info-Fenster) }
  TTrigLogKind = (tlNoteOn, tlNoteOff, tlScTrig, tlScPitch, tlGate, tlQuiet, tlLfoEnd, tlLfoStart,
    tlBend, tlControl, tlPressure, tlOutTrig);
  TTrigLogItem = record
    Time: Double;        // Sekunden seit Start der Engine
    Kind: TTrigLogKind;
    Lfo: Byte;           // tlLfoEnd/tlLfoStart: LFO 0..3 (= LFO 1..4); Noten: Stimme
    Arg: Byte;           // tlLfoStart: Neustart-Art (LFO_TRIG_*); Noten: MIDI-Note
    Val: Single;         // Noten: Velocity 0..1; Sidechain: Pegel 0..1; SC-Ton: erkannte Note
    Val2: Single;        // Note an: Glide-Versatz (Halbtoene); Sidechain: Schwelle
  end;

  { Stimmung der gespielten Musik (Naeherung nach Valenz/Erregung):
    Valence -1 (traurig/duester) .. +1 (froh/hell), Arousal 0 (ruhig) .. 1 (energiegeladen) }
  TMoodKind = (mkNone, mkTender, mkCalm, mkHappy, mkSad, mkAngry, mkMystic);
  TMood = record
    Valence, Arousal, Tender: Single;   // Tender: 0..1 zaertlich/verliebt
    Kind: TMoodKind;
    Name: string;
  end;

  TEnvelopeState = record
    Active: Boolean;
    Stage: TEnvStage;
    StageSeconds: Double;
    Level: Single;
  end;

  TGranularEngine = class
  private
    FLock: TCriticalSection;       // schuetzt Process gegen Samplewechsel
    FEventLock: TCriticalSection;  // schuetzt nur die Event-Warteschlange (kurz)
    FPending: array[0..MAX_EVENTS - 1] of TNoteEvent;
    FPendingCount: Integer;
    FEvents: array[0..MAX_EVENTS - 1] of TNoteEvent;
    FEventCount: Integer;

    FSample: TSampleData;
    FSampleRate: Double;
    FParams: array[0..PARAM_COUNT - 1] of Single;   // Grundwerte (Regler)
    FEff: array[0..NAMED_COUNT - 1] of Single;      // Wirkwerte nach Modulation
    FVoices: array[0..MAX_VOICES - 1] of TVoice;
    FGrains: array[0..MAX_GRAINS - 1] of TGrain;
    // Liste der aktiven Grains (Index in FGrains) und Stapel freier Plaetze: Schleifen laufen nur ueber
    // die klingenden Grains statt ueber alle 1024 Plaetze (spart Speicherverkehr/Cache - wichtig auf alten
    // CPUs und bei mehreren Instanzen). FActiveGrains = Laenge der Liste.
    FActList: array[0..MAX_GRAINS - 1] of Integer;
    FActPos: array[0..MAX_GRAINS - 1] of Integer;     // Position eines aktiven Grains in FActList
    FFreeList: array[0..MAX_GRAINS - 1] of Integer;
    FFreeCount: Integer;
    FGrainSearch: Integer;
    FEnvBuf: array[0..MAX_VOICES - 1, 0..SUB_BLOCK - 1] of Single;
    FMix: array[0..SUB_BLOCK * 2 - 1] of Single;    // interleaved Mischpuffer je Subblock

    // Oszilloskop: Ausgang (Mono-Summe) und Sidechain-Eingang
    FScopeOut, FScopeIn: array[0..SCOPE_SIZE - 1] of Single;
    FScopePos: Integer;
    FScopePre: array[0..SCOPE_SIZE - 1] of Single;   // Summe vor dem Equalizer (Filteransicht)
    FScopePrePos: Integer;

    // Effekte
    FSvfOsc: TSvfArgs;
    FFlt1, FFlt2: TFltState;
    FCombMem: TArray<Single>;                           // Ringe aller Kammfilter (fest beim Start angelegt)
    FFltX, FFltDry: array[0..SUB_BLOCK * 2 + 3] of Single;
    FLadSat: TSatArgs;
    // Summen-Effekte: Chorus, Phaser, Bitcrusher, Trance-Gate
    FChoBuf: array[0..CHO_LEN * 2 - 1] of Single;
    FCho: TChorusArgs;               // Zustand: Schreibposition W und LFO-Phase Ph
    FChoWasOn: Boolean;
    FPha: TPhaserArgs;
    FPhaA: array[0..1] of Single;    // Koeffizient am Ende des letzten Blocks (gleitet von dort weiter)
    FPhaPh: Double;
    FPhaWasOn: Boolean;
    FCrushHold: array[0..1] of Single;
    FCrushPh: Double;
    FTgMask: Cardinal;
    FTgGain: Single;
    FTgPos: Double;                                     // Position in Schritten seit dem Start
    FTgStep: Integer;                                   // aktueller Schritt (0 .. Schritte-1)
    FOffline: Boolean;                                  // Host rendert (nicht Echtzeit)
    FPreOfs: Double;                                    // Anlauf-Start relativ zur Auswahl (< 0 = Anlauf an)
    FPingPong: Boolean;                                 // Schleife hin und her
    // Zonen: weitere Samples je Tastenbereich (ab Taste FZoneLow)
    FZone: array[1..ZONE_COUNT] of TSampleData;
    FZoneLow: array[1..ZONE_COUNT] of Integer;
    FZoneTune: array[1..ZONE_COUNT] of Double;
    FZoneSel0, FZoneSelLen, FZoneSr: array[1..ZONE_COUNT] of Double;
    FZoneRef: array[1..ZONE_COUNT] of string;      // Pfad wie im Preset gespeichert ('' = keine Zone)
    FZoneLoaded: array[1..ZONE_COUNT] of string;   // tatsaechlich geladene Datei
    // Aufnahme des Sidechain-Eingangs (Resampling)
    FRecBuf: TArray<Single>;
    FRecPos, FRecLen: Integer;
    FRecOn: Boolean;
    FSc2Level: Double;
    FMix2: array[0..SUB_BLOCK * 2 - 1] of Single;   // Zweig fuer parallele Filter
    FOscMix: array[0..SUB_BLOCK * 2 - 1] of Single; // Oszillator mit eigenem Filter (an den Hauptfiltern vorbei)
    FOscOwnFlt: Boolean;
    FEcho: TEchoArgs;
    FEchoBuf: TArray<Single>;
    FPitchBuf: TArray<Single>;
    FFltEnv: Double;
    FFltStage: TEnvStage;
    FFltStageTime: Integer;
    FFltTrigger: Boolean;
    FEchoWasOn: Boolean;
    FReverb: TReverb;
    FEq: TEqProcessor;
    FEqCurve: TEqCurve;
    FEqVersion: Integer;
    FEqWasOn: Boolean;
    // Oszillator-Schicht: eigene Stimme je Note (eigene Huellkurve, ueberdauert die Grain-Stimme)
    FOsc: array[0..OSC_COUNT - 1, 0..MAX_VOICES - 1] of record
      Stage, FmStage: TEnvStage;
      Env, FmEnv: Single;
      StageTime, FmStageTime: Integer;   // Samples in der aktuellen Phase (Anzeige)
      Note: Integer;
      Vel: Single;
      Ph, PhM: Single;
      UPh, UPhM: array[0..UNI_MAX - 2] of Single;   // Phasen der weiteren Unison-Stimmen
    end;
    FSinTab: array[0..4097] of Single;
    FOscArgs: TOscArgs;
    FOscGain, FOscRaw, FOscScratch: array[0..SUB_BLOCK + 3] of Single;   // +4: Huellkurven-Kern schreibt in 4er-Gruppen
    // 2x-Oversampling (HQ + Schalter): Oszillatoren und Saettigung rechnen mit doppelter Rate
    FOsOn: Boolean;
    FHbDown, FHbUp: THbArgs;                                          // Halbband-Koeffizienten (abwaerts / aufwaerts)
    FOscGain2, FOscRaw2: array[0..SUB_BLOCK * 2 + 3] of Single;       // Huellkurven auf doppelter Rate
    FOsW: array[0..(HB_HIST * 2 + SUB_BLOCK * 2) * 2 - 1] of Single;  // Arbeitspuffer 2x: Vorlauf + Block
    FOsDec: array[0..SUB_BLOCK * 2 - 1] of Single;                    // Ergebnis nach dem Abwaerts-Filter
    FOscHist: array[0..OSC_COUNT - 1, 0..MAX_VOICES - 1, 0..HB_HIST * 2 * 2 - 1] of Single;   // Vorlauf je Oszillator/Stimme (eigenes Filter)
    // Oszillatoren ohne eigenes Filter: alle einer Stimme in einen 2x-Puffer, nur EIN Abwaerts-Filter je Stimme
    FOsVW: array[0..MAX_VOICES - 1, 0..(HB_HIST * 2 + SUB_BLOCK * 2) * 2 - 1] of Single;   // Vorlauf + Block
    FOsVUsed: array[0..MAX_VOICES - 1] of Boolean;
    FOscOsGroup: Boolean;   // Oszillatoren rechnen mit Oversampling (alle gemeinsam, haelt solange einer klingt)
    // gezeichnete Oszillator-Wellen: Zeichnung + bandbegrenzte Wavetables (doppelt gepuffert: die
    // Oberflaeche rechnet in den freien Satz und schaltet dann um, der Audio-Thread liest nur)
    FOscDraw: array[0..OSC_COUNT - 1] of TOscDraw;
    FWtBuf: array[0..OSC_COUNT - 1, 0..1] of TArray<Single>;   // nur angelegt, wenn wirklich gezeichnet wurde
    FWtPtr: array[0..OSC_COUNT - 1] of PSingle;                  // aktive Tabelle (Startwelle: gemeinsame)
    FWtCur: array[0..OSC_COUNT - 1] of Integer;
    FWtArgs: TWtArgs;
    FDrvMode: Integer;                                                // Saettigung: 0 aus, 1 normal, 2 mit Oversampling
    FDrvU: array[0..(HB_HIST + SUB_BLOCK) * 2 - 1] of Single;         // Vorlauf + Block (1x) fuer das Aufwaerts-Filter
    FDrvW: array[0..(HB_HIST * 2 + SUB_BLOCK * 2) * 2 - 1] of Single; // 2x: Vorlauf + Block
    FDrvAlt: array[0..SUB_BLOCK * 2 - 1] of Single;                   // anderer Pfad beim Ueberblenden
    // Polyphone Modulation je Stimme
    FPndIdx: array[TGranularParamId] of ShortInt;              // Param -> PND-Index, -1 = global
    // Klangprozessor je Note: eigener Puffer, eigene Filter (1, 2, Oszillator) und Filter-Huellkurve
    FVBuf: array[0..MAX_VOICES - 1, 0..SUB_BLOCK * 2 - 1] of Single;
    FVTmp: array[0..SUB_BLOCK * 2 - 1] of Single;
    FVHasSig: array[0..MAX_VOICES - 1] of Boolean;
    FVSvf1, FVSvf2: array[0..MAX_VOICES - 1] of TFltState;
    FVSvfOsc: array[0..OSC_COUNT - 1, 0..MAX_VOICES - 1] of TSvfArgs;
    FVFltEnv: array[0..MAX_VOICES - 1] of Double;
    FVFltStage: array[0..MAX_VOICES - 1] of TEnvStage;
    FVModOn: array[0..MAX_VOICES - 1] of Boolean;             // Stimme hat eigene Modulation
    FVPlain: array[0..MAX_VOICES - 1, 0..PND_COUNT - 1] of Single;   // Wirkwerte (Klartext) je Stimme
    FVRnd: array[0..MAX_VOICES - 1] of Single;                // "Zufall je Note" dieser Stimme
    FVLfoPh: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Double;        // Noten-LFOs: eigene Phase je Stimme
    FVLfoHold: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Single;
    FVLfoDone: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Boolean;
    // Ereignis-Verzoegerung je Stimme: Samples bis zum Neustart; Mute = bis dahin still (Note an)
    FVLfoWait: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Integer;
    FVLfoMute: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Boolean;
    FVLfoStopWait: array[0..MAX_VOICES - 1, 0..LFO_COUNT - 1] of Integer;   // Aus-Trigger verzoegert: Samples bis zum Anhalten
    FGlideOfs, FGlideStep: array[0..MAX_VOICES - 1] of Single;   // Portamento je Stimme (Halbtoene)
    FLastNote, FLastVoice: Integer;  // zuletzt angeschlagene Note/Stimme (Ausgang fuer Glide)
    FOscLast: Integer;               // zuletzt angeschlagene Oszillator-Stimme (Anzeige)
    FRevWasOn: Boolean;
    FSat: TSatArgs;
    FGainPrev: Double;                   // Lautstaerke des vorigen Subblocks (Rampe -> klickfrei)
    FGrainGainPrev: Double;              // Grain-Pegel des vorigen Subblocks (Rampe)
    FScale, FScaleRoot: Integer;
    // Arpeggiator: gehaltene Tasten (in Anschlagreihenfolge), Takt, gerade klingende Arp-Noten
    FArpHeld: array[0..31] of Integer;
    FArpVel: array[0..31] of Single;
    FArpHeldCount: Integer;
    FArpDown: array[0..127] of Boolean;   // Taste physisch gedrueckt (Latch: Liste bleibt nach dem Loslassen)
    FArpDownCount: Integer;
    FArpCur: array[0..63] of Integer;
    FArpCurCount: Integer;
    FArpRunning: Boolean;
    FArpPos, FArpNext, FArpGateEnd: Double;   // Samples seit Start
    FArpStep, FArpCount: Integer;
    FArpMask: Cardinal;                       // Schrittmuster: Bit k = Schritt k spielt
    FArpShown: Integer;                       // zuletzt gespielter Schritt (Anzeige)
    FArpLast: array[0..31] of Integer;        // zuletzt angeschlagener Akkord (fuer MIDI-Export)
    FArpLastVel: array[0..31] of Single;
    FArpLastCount: Integer;
    FPresetName: string;
    FFreeze: Boolean;
    FMorphB: array[0..NAMED_COUNT - 1] of Single;   // Morph-Ziel B (benannte Parameter)
    FMorphValid: Boolean;
    FSampleB: TSampleData;          // Sample des Morph-Ziels (Grain-Ueberblendung)
    FMorphSampleRef: string;        // Pfad (portabel) des B-Samples, wie im Chunk gespeichert
    FMorphSampleLoaded: string;     // tatsaechlich geladene Datei
    FSel0B, FSelLenB, FSrRatioB: Double;
    FTuneA, FTuneB: Double;         // Auto-Stimmung: Korrektur in Halbtoenen (-6..+6) fuer Sample A / B
    FRootA, FRootB: Double;         // erkannter Grundton (MIDI, 0 = keiner)
    // Feedback-Resampling: der eigene Ausgang wird Durchlauf fuer Durchlauf zur neuen Grain-Quelle.
    // Zwei vorab angelegte Puffer wechseln sich ab (im Audio-Thread wird nichts angefordert).
    FResSmp: array[0..RES_BUFS - 1] of TSampleData;
    FResPrevBuf: Integer;           // voriger Puffer (ausklingende Grains), -1 = keiner
    FResKeySerial, FResKeySeen: Integer;   // Tastenanschlaege: neuer Anschlag = zurueck zum Original
    // Resampling per Automation eingeschaltet (ohne offenen Editor): der Audio-Thread weckt einen
    // schlafenden Helfer, der die Puffer anlegt - im Audio-Thread selbst wird nichts angefordert
    FResThread: TThread;
    FResWake: TEvent;
    FResAsked: Boolean;
    FResCap: Integer;               // Platz je Puffer in Frames (0 = nicht angelegt)
    FResCur: Integer;               // spielender Puffer, -1 = das Original spielt
    FResOrig: TSampleData;          // Original, solange ein Puffer spielt
    FResTuneOrig: Double;           // Auto-Stimmung des Originals (im Puffer schon enthalten)
    FResOfs: Double;                // Tonlage des spielenden Puffers in Halbtoenen zu C4
    FResRecOfs: Double;             // Tonlage der laufenden Aufnahme
    FResPhase: Integer;             // 0 = Aufnahme, 1 = vorigen Stand kopieren, 2 = Gemisch messen, 3 = schreiben
    FResPos, FResLen: Integer;
    FResRawSq, FResPrevSq: Double;
    FResPrevP, FResPrevStep, FResPrevS0, FResPrevLen: Double;
    FResNote, FResLastNote: Integer;
    FResGain, FResNorm: Single;
    FResMixSq: Double;
    FResHpY, FResHpX: array[0..1] of Single;
    FResPasses: Integer;            // Anzahl getauschter Durchlaeufe (Anzeige, Pruefstand)
    FAutoTune: Boolean;
    FStepped: array[0..NAMED_COUNT - 1] of Boolean;
    FSamplePath: string;
    FPitchTrk: TPitchTracker;
    FPitchTrk2: TPitchTracker;      // Tonhoehe von Sidechain 2 (nur gerechnet, wenn die Matrix sie nutzt)
    FScPitch2Used: Boolean;
    FBend: Double;                 // Pitchbend -1..1
    FHQ: Boolean;
    FLimGain: Double;              // aktuelle Limiter-Verstaerkung (1 = keine Reduktion)
    FLimMin: Double;               // kleinste Verstaerkung seit der letzten Abfrage (Anzeige)
    FLimBuf: array[0..LIM_LOOK * 2 - 1] of Single;   // Vorausschau-Verzoegerung (interleaved)
    FLimPos: Integer;
    FLimHold: Double;
    FLimHoldCnt: Integer;
    FClipCount: Integer;           // Samples, in denen der weiche Clipper eingegriffen hat
    FMidiCount: Integer;           // eingegangene MIDI-Ereignisse (fuer die MIDI-Leuchte)
    FScLevelArmed, FScPitchArmed: Boolean;   // Schwellen-Trigger: erst nach Unterschreiten wieder scharf
    FOutTrigArmed, FOutTrigEvt: Boolean;
    FOutBusy: array[0..LFO_COUNT - 1] of Boolean;       // LFO laeuft nach Ausgangs-Trigger noch -> keine Selbst-Ausloesung
       // Trigger auf den eigenen Ausgangspegel
    FScTrigArmed, FScTrigEvt: Boolean;       // kombinierter Sidechain-Trigger (Pegel und/oder Ton)
    FScLevelEvt, FScPitchEvt: Boolean;       // Schwelle in diesem Subblock ueberschritten
    FGateOpen, FGateEvt: Boolean;            // Schwellen-Tor: offen / gerade aufgegangen
    FQuietEvt: Boolean;                      // Ruhe-Ereignis: Quelle lag die Ruhe-Dauer lang unter der Schwelle
    FQuietSamples: Double;                   // bisherige Ruhezeit in Samples (< 0 = schon gefeuert)
    FSustainPedal: Boolean;
    // MIDI-Learn: Controller -> Parameter (-1 = frei); FLearnParam wartet auf den naechsten Controller
    FCcMap: array[0..127] of Integer;
    FLearnParam, FLearnedCc: Integer;
    FHeldBySustain: array[0..127] of Boolean;
    FLog: array[0..255] of TTrigLogItem;   // Ringpuffer; schreibt nur, wenn FLogOn (Info-Fenster offen)
    FLogWrite: Integer;
    FLogOn: Boolean;
    // Stimmungs-Analyse (aus den gespielten Noten, gleitend): Tonklassen, Notendichte, Anschlag,
    // Lage, Dissonanz gleichzeitig klingender Toene, legato/staccato, Pegel
    FMoodPc: array[0..11] of Single;
    FMoodRate, FMoodVel, FMoodPitch, FMoodDiss, FMoodLegato, FMoodLevel: Single;
    FNoteOnCount: Integer;                 // Anschlaege seit Start (Anzeige: Notendichte fuer die Taenzerin)
    FLogClock: Int64;                      // Samples seit Start (Zeitstempel)
    FLogBend, FLogMod, FLogPress: Single;  // zuletzt protokollierte Werte (Raddrehungen ausduennen)
    FTrigOn, FTrigOff: Boolean;    // seit dem letzten Subblock: Note an / Note aus
    FAutoPitch: Integer;   // 0 aus, 1 frei, 2 Halbtoene
    FWindows: array[0..3, 0..WINDOW_TABLE_SIZE] of Single;
    FRand: Cardinal;
    FStampCounter: Int64;
    FActiveGrains: Integer;
    FIdleSamples: Integer;     // so lange schon still und nichts aktiv (Ausklang unter -100 dB)
    FIdleSkips: Int64;         // uebersprungene Bloecke (Pruefstand)

    FHistory: array[0..GRAIN_HISTORY - 1] of Single;
    FHistoryPos: Integer;

    // Modulationsquellen
    FLfoPhase: array[0..LFO_COUNT - 1] of Double;
    FLfoHold: array[0..LFO_COUNT - 1] of Single;
    FLfoDone: array[0..LFO_COUNT - 1] of Boolean;     // Einmal-Modus: Durchlauf beendet, LFO steht am Ende
    FLfoPend: array[0..LFO_COUNT - 1] of Integer;     // verzoegerter Neustart: Samples bis dahin (0 = keiner)
    FLfoPendTrig: array[0..LFO_COUNT - 1] of Integer; // Trigger-Art des wartenden Neustarts
    FLfoRun: array[0..LFO_COUNT - 1] of Integer;      // 0 = noch nie gestartet, 1 = laeuft, 2 = vom Aus-Trigger angehalten
    FLfoStopPend: array[0..LFO_COUNT - 1] of Integer; // verzoegertes Anhalten: Samples bis dahin (0 = keins)
    FLfoEndEvt: array[0..LFO_COUNT - 1] of Boolean;   // Durchlauf gerade beendet (Trigger fuer den anderen LFO)
    FFree: array[0..FREE_LFO_COUNT - 1] of TFreeLfo;   // frei programmierbare Formen: LFO 1, LFO 2, Morph-LFO, LFO 3..8
    FLfoUsed: array[0..LFO_COUNT - 1] of Boolean;     // LFO 5..8 werden nur gerechnet, wenn etwas sie benutzt
    FMorphPhase: Double;              // Phase des Morph-LFOs
    FMorphLfoVal: Single;             // aktueller Ausschlag des Morph-LFOs (Anzeige)
    FMorphHold: Single;
    FSource: array[TModSource] of Single;
    FScLevel: Double;
    FScInput: Boolean;
    FVstInPeak: array[0..3] of Single;
    FEffMemoN: array[0..NAMED_COUNT - 1] of Single;   // Eff-Zwischenspeicher: letzter Wirkwert (normiert) ...
    FEffMemoV: array[0..NAMED_COUNT - 1] of Double;   // ... und sein Klartext
    FStCalls, FStFrames, FStTicks, FStMax, FStHost, FStHops: Int64;
    FStThread: Cardinal;
    FInPeak: Single;     // Roh-Eingangspegel (vor Verstaerkung), fuer die Anzeige
    FOutPeak: Single;    // Ausgangspegel fuer Anzeigen (Banner), langsam abfallend

    // pro Subblock aus den Wirkwerten abgeleitete Groessen
    FSel0, FSelLen: Double;
    FPosition, FSpray, FScanInc: Double;
    FGrainLen: Integer;
    FInterval, FNorm: Double;
    FPitch, FPitchRand, FSpread, FReverse: Double;
    FWindowShape: Integer;
    FAttInc, FDecCoef, FSustain, FRelCoef, FGain: Double;
    FKeyTrack: Boolean;
    FGrainOct: Integer;              // Grain-Oktave in Halbtoenen (-48 .. +48)
    FGrainPan: Single;               // Grain-Panorama -1 (links) .. +1 (rechts)
    FGrainOn: Boolean;               // Grains an (aus = nur Oszillator)
    FBendRange: Double;
    FSrRatio: Double;
    // Morph-Art 'Zwei Klaenge': B ist ein vollstaendiger zweiter Klangerzeuger (eigene Stimmen, Arp,
    // LFOs, Matrix, Effekte); Morph blendet nur die fertigen Ausgaenge von A und B
    FLayerB: TGranularEngine;
    FLayerOn: Boolean;
    FLayerBuf: TArray<Single>;          // Ausgang von B (interleaved, ganzer Block)
    FGainBs, FGainBe: TArray<Single>;   // B-Gewicht je Subblock (Start/Ende der Rampe)
    FGainA, FGainB: Single;         // zuletzt benutzte Ausgangs-Gewichte (Rampe je Subblock)
    FSwapped: Boolean;              // A und B zum Bearbeiten getauscht (Anzeige)
    // Pegel fuer das Mischpult (nur gemessen, solange es sichtbar ist): Spitze seit der letzten Abfrage
    FMeterOn: Boolean;
    FMeter: array[0..MIX_METERS - 1] of Single;
    FMeterTmp: array[0..SUB_BLOCK * 2 - 1] of Single;

    procedure BuildWindows;
    procedure RenderSub(SubInL, SubInR, Sc2L, Sc2R: PSingle; N: Integer; Audible: Boolean);
    { B: ganzen Block rechnen (eigene Events, eigene Subblock-Schleife), Ausgang interleaved nach Out }
    procedure RenderLayerCall(InL, InR, In2L, In2R: PSingle; Frames: Integer; Events: PNoteEvent;
      EventCount: Integer; Audible: Boolean; Out: PSingle);
    procedure CopyStateTo(Dst: TGranularEngine);
    function Rand: Single; inline;
    function Eff(Id: TGranularParamId): Double;
    procedure UpdateModulation(InL, InR: PSingle; N: Integer);
    procedure UpdateBlockParams;
    procedure ApplyEvent(const E: TNoteEvent);
    procedure StartVoice(Note: Integer; Velocity: Single);
    procedure ReleaseNote(Note: Integer);
    procedure KillGrainsOfVoice(V: Integer);
    procedure ResetAll;
    procedure ResetGrains;
    function GrainAlloc: Integer;          // -1 = Pool voll
    procedure GrainFree(Slot: Integer);
    procedure RunVoices(N: Integer);
    function IsNoteSource(Src: Integer): Boolean;
    procedure UpdateVoiceModulation(N: Integer);
    procedure SpawnGrain(V, Offset: Integer);
    procedure RenderGrains(N: Integer);
    procedure RenderOscOne(O, N: Integer);
    procedure ApplyGrainLevel(N: Integer);
    { Verzoegerung (Samples) fuer Ereignisart 0..7, aus ms oder Notenwert (Takt gewinnt) }
    function EventDelaySamples(Ev: Integer): Integer;
    { Noten-LFO K einer Stimme anhalten (Dly = 0 sofort, sonst nach Dly Samples) }
    procedure StopVoiceLfo(V, K, Dly: Integer);
    { Stopp 'nach Zeit': Laufzeit von LFO K in Samples (mind. 1), aus ms oder Notenwert }
    function StopTimeSamples(K: Integer): Integer;
    function StopIsTime(K: Integer): Boolean;
    procedure RunEnvSegments(var E: Single; var Stage: TEnvStage; var StageTime: Integer; N: Integer;
      AttInc, DecK, Sus, RelK, G: Double; Raw, Gain: PSingle);
    procedure MeterPeak(Ch: Integer; P: PSingle; Count: Integer);
    procedure MeterDiff(Ch: Integer; P: PSingle; Count: Integer);
    function OscHeld(V, Note: Integer): Boolean;
    function OscSounding(V: Integer; HeldOnly: Boolean): Boolean;
    procedure WriteScope(InL, OutL, OutR: PSingle; N: Integer);
    procedure UpdateFilterEnv(N: Integer);
    procedure ProcessFilter(N: Integer);
    procedure ProcessVoiceFilters(N: Integer);
    procedure RunFilter(var F: TFltState; Buf: PSingle; N, FType: Integer; Cutoff, Reso, Contour, EnvAmt: Double;
      Env: Double = -1);
    procedure ResetFlt(var F: TFltState);
    function FilterFc(Cutoff, EnvAmt, Env: Double): Double;
    procedure ProcessChorus(N: Integer);
    procedure FxMeter(Ch, N: Integer);
    procedure ProcessPhaser(N: Integer);
    procedure ProcessCrush(N: Integer);
    procedure ProcessTranceGate(N: Integer);
    function PerfLevel: Integer;
    function ZoneOfNote(Note: Integer): Integer;
    procedure UpdateLfoUsed;
    procedure RunSvf(var Svf: TSvfArgs; Buf: PSingle; N, FType: Integer; Cutoff, Reso, Contour, EnvAmt: Double;
      Env: Double = -1);
    procedure ProcessEcho(N: Integer);
    procedure ProcessReverb(N: Integer);
    procedure ProcessDrive(N: Integer);
    procedure SatBuffer(P: PSingle; Count: Integer; Drive, Make: Single);
    procedure DriveOs(N: Integer; Drive, Make: Single);
    procedure HbDecimate(W: PSingle; N: Integer; Dst: PSingle);
    procedure RenderWtOsc(Tab: PSingle);
    function GetOscDraw(O: Integer): POscDraw;
    procedure ProcessEq(N: Integer);
    procedure ProcessStereo(N: Integer);
    procedure RenderOsc(N: Integer);
    procedure FollowSc2(L: PSingle; RAddr: NativeInt; N: Integer);
    procedure ApplyGain(N: Integer);
    function ScaleSnap(Semis: Double): Double;
    function ArpActive: Boolean;
    procedure KeyDown(Note: Integer; Velocity: Single);
    procedure KeyUp(Note: Integer);
    procedure ArpReleaseCurrent;
    procedure ArpTick(N: Integer);
    procedure ArpStepNow;
    procedure ProcessLimiter(N: Integer);
    procedure ApplyMacros;
    procedure QueueEvent(const E: TNoteEvent);
    function GetEffParam(Index: Integer): Single;
    function GetLfoPhase(Index: Integer): Double;
    function GetLfoValue(Index: Integer): Single;
    function GetSourceValue(Src: TModSource): Single;
    function GetFreeLfo(Index: Integer): PFreeLfo;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetSampleRate(Value: Double);
    { Uebernimmt den Besitz von Data. Altes Sample wird freigegeben. }
    procedure LoadSample(Data: TSampleData);
    { Feedback-Resampling: Puffer anlegen (ausserhalb des Audio-Threads, z.B. beim Einschalten) }
    procedure ResPrepare;
    { Resampling-Puffer vorhanden (Pruefstand) }
    function ResReady: Boolean;
    procedure ResRestore;
    procedure ResTick(OutL, OutR: PSingle; N: Integer);
    function ResActive: Boolean;
    function ResPasses: Integer;
    function ResOffset: Double;
    function GetSampleOrig: TSampleData;

    procedure NoteOn(Note: Integer; Velocity: Single; DeltaFrames: Integer = 0);
    procedure NoteOff(Note: Integer; DeltaFrames: Integer = 0);
    procedure AllNotesOff;
    { weitere MIDI-Ereignisse, samplegenau ueber DeltaFrames }
    procedure PitchBend(Value: Single; DeltaFrames: Integer = 0);           // -1..1
    procedure ControlChange(Cc: Integer; Value: Single; DeltaFrames: Integer = 0); // 0..1
    procedure ChannelPressure(Value: Single; DeltaFrames: Integer = 0);     // 0..1
    { Trance-Gate: Bit i = Schritt i+1 offen }
    property TgMask: Cardinal read FTgMask write FTgMask;
    function TgShownStep: Integer;
    function LfoUsed(K: Integer): Boolean;   // LFO K wird gerechnet (1..4 immer, 5..8 nur bei Benutzung)   // laufender Gate-Schritt (-1 = Gate aus oder still)
    { Host rendert offline -> mit 'Rendern in Hoechstqualitaet' HQ an und volle Stimmenzahl }
    property Offline: Boolean read FOffline write FOffline;
    { Zonen 1..ZONE_COUNT: Data = nil entfernt die Zone (Besitz geht an die Engine) }
    procedure SetZone(Z: Integer; Data: TSampleData; LowNote: Integer);
    function ZoneSample(Z: Integer): TSampleData;
    function GetZoneLow(Z: Integer): Integer;
    procedure SetZoneLow(Z, Note: Integer);
    function GetZoneRef(Z: Integer): string;
    procedure SetZoneRef(Z: Integer; const Value: string);
    function GetZoneLoaded(Z: Integer): string;
    procedure SetZoneLoaded(Z: Integer; const Value: string);
    { Aufnahme des Sidechain-Eingangs: StartRecording legt den Puffer an (GUI-Thread),
      StopRecording liefert das Aufgenommene als Sample (nil, wenn nichts ankam) }
    procedure StartRecording(Seconds: Double);
    function StopRecording: TSampleData;
    function Recording: Boolean;
    function RecordedSeconds: Double;
    { MIDI-Learn: der naechste Controller (ausser Pedal und Kanalbefehle) steuert Index.
      MidiLearnPoll liefert danach einmal die gelernte Controller-Nummer, sonst -1. }
    procedure MidiLearnStart(Index: Integer);
    procedure MidiLearnCancel;
    function MidiLearnPending: Boolean;
    function MidiLearnPoll: Integer;
    function CcForParam(Index: Integer): Integer;
    function CcTarget(Cc: Integer): Integer;
    procedure SetCcTarget(Cc, Index: Integer);

    { InL/InR = Sidechain-Eingang, nil wenn keiner vorhanden }
    procedure Process(InL, InR, OutL, OutR: PSingle; Frames: Integer; In2L: PSingle = nil; In2R: PSingle = nil);

    function GetParam(Index: Integer): Single;
    procedure SetParam(Index: Integer; Value: Single);
    function GetParamById(Id: TGranularParamId): Single;
    procedure SetParamById(Id: TGranularParamId; Value: Single);

    { Anzeige-Hilfen (lockfrei, Werte sind nur Momentaufnahmen) }
    function GetPlayheads(var Positions: array of Single): Integer;
    function GetRecentGrains(var Positions: array of Single): Integer;
    function GetEnvelopeState: TEnvelopeState;
    { je Note Leuchtstaerke 0..255 fuer die Klaviatur: gehalten = Velocity, Release = halbe Velocity }
    procedure GetActiveNotes(var States: array of Byte);
    function GetFilterEnvState: TEnvelopeState;
    { neue Protokoll-Eintraege ab Pos (Pos wird weitergezaehlt; bei Ueberlauf gehen alte verloren) }
    function ReadTriggerLog(var Pos: Integer): TArray<TTrigLogItem>;
    procedure LogTrig(Kind: TTrigLogKind; Lfo: Integer = 0; Arg: Integer = 0; Val: Single = 0; Val2: Single = 0);
    property TriggerLog: Boolean read FLogOn write FLogOn;
    property NoteOnCount: Integer read FNoteOnCount;
    { Stimmung der zuletzt gespielten Musik (einige Takte gleitend) }
    function GetMood: TMood;
    { Diagnose (Test): Wirkwert eines Noten-Ziels in Stimme V (Klartext); ohne eigene Modulation global }
    function VoiceValue(V: Integer; Id: TGranularParamId): Double;
    { Matrix-Zeile mit Noten-Quelle (Velocity, Noten-LFO, ...) auf ein Ziel, das es nur einmal gibt
      (Echo, Hall, Morph, ...): wirkt global und folgt der zuletzt angeschlagenen Note }
    function SlotIsGlobalNote(Slot: Integer): Boolean;
    { Stimme, die zuletzt Note Note angeschlagen hat (-1 = keine) }
    function VoiceOfNote(Note: Integer): Integer;
    { Oszillator-Huellkurve bzw. eigene FM-Huellkurve der zuletzt angeschlagenen Oszillator-Stimme }
    function GetOscEnvState(Fm: Boolean; Osc: Integer = 0): TEnvelopeState;
    { kopiert die letzten Count Werte (aelteste zuerst) }
    procedure GetScope(var OutBuf, InBuf: array of Single; Count: Integer);
    { Summe vor dem Equalizer (fuer die Filteransicht) }
    procedure GetScopePreEq(var Buf: array of Single; Count: Integer);

    property Sample: TSampleData read GetSampleOrig;   // Original (auch waehrend Resampling)
    property SampleRate: Double read FSampleRate;
    property ActiveGrains: Integer read FActiveGrains;
    property IdleSkips: Int64 read FIdleSkips;
    { nichts klingt oder wartet: keine Grains, Stimmen, Oszillatoren, Arp-Noten }
    function EngineIdle: Boolean;
    property EffParam[Index: Integer]: Single read GetEffParam;
    property LfoPhase[Index: Integer]: Double read GetLfoPhase;
    property LfoValue[Index: Integer]: Single read GetLfoValue;
    property SourceValue[Src: TModSource]: Single read GetSourceValue;
    { Daten der Form 'Frei' je LFO; die Oberflaeche schreibt direkt hinein (einzelne Singles, lockfrei) }
    property FreeLfo[Index: Integer]: PFreeLfo read GetFreeLfo;
    { gezeichnete Oszillator-Welle O (0..2); nach Aenderungen OscDrawChanged aufrufen (nicht im Audio-Thread) }
    property OscDraw[O: Integer]: POscDraw read GetOscDraw;
    procedure OscDrawChanged(O: Integer);
    { reichste Stufe der aktuellen Wavetable (Anzeige), WT_LEN[0] + 2 Werte }
    function OscWaveTable(O: Integer): PSingle;
    { Morph-Ziel B: aktuelle Einstellung merken / setzen / lesen (benannte Parameter, normalisiert) }
    procedure StoreMorphTarget;
    procedure SetMorphTarget(const Values: array of Single);
    procedure ClearMorphTarget;
    { Ziel B = vollstaendiger Zustand eines anderen Klangs (Parameter, Matrix, freie LFOs, Arp-Muster, EQ) }
    procedure SetMorphFromEngine(Src: TGranularEngine);
    { B-Klangerzeuger (fuer Laden/Speichern des vollstaendigen B-Zustands); nach Aenderung SyncMorphFromLayer }
    function EnsureMorphLayer: TGranularEngine;
    procedure SyncMorphFromLayer;
    property MorphLayer: TGranularEngine read FLayerB;
    function LayerMode: Boolean;
    { Bearbeitungstausch: A und B (Regler, Matrix, freie LFOs, Arp-Muster, EQ, Sample) tauschen die
      Plaetze, Morph wird gespiegelt - der Klang bleibt gleich, bearbeitet wird jetzt der andere }
    function SwapMorphAB: Boolean;
    { Mischpult-Pegel: Messung an/aus (kostet etwas Rechenzeit), Spitze abholen und zuruecksetzen }
    property MetersOn: Boolean read FMeterOn write FMeterOn;
    function TakeMeter(Ch: Integer): Single;
    property MorphSwapped: Boolean read FSwapped;
    function GetMorphTarget(var Values: array of Single): Boolean;
    property MorphValid: Boolean read FMorphValid;
    { gespeicherter Wert (0..1) eines benannten Reglers im Morph-Ziel B }
    function MorphBValue(Id: TGranularParamId): Single;
    { Sample fuer Ziel B: je nach Morph-Stellung kommt dieser Anteil der Grains aus B (uebernimmt den Besitz) }
    procedure SetMorphSample(Data: TSampleData; const LoadedFile: string);
    property MorphSampleRef: string read FMorphSampleRef write FMorphSampleRef;
    property MorphSampleLoaded: string read FMorphSampleLoaded;
    { Equalizer-Kurve (dB je Stuetzpunkt); nach Aenderungen EqChanged aufrufen }
    function EqCurve: PEqCurve;
    procedure EqChanged;
    property EqVersion: Integer read FEqVersion;
    { erkannter Grundton von Sample A / B (MIDI, 0 = keine stabile Tonhoehe) }
    property SampleRoot: Double read FRootA;
    property MorphSampleRoot: Double read FRootB;
    { Arpeggiator-Schrittmuster (im Chunk gespeichert, nicht automatisierbar) }
    property ArpMask: Cardinal read FArpMask write FArpMask;
    property ArpShownStep: Integer read FArpShown;
    { zuletzt mit Arp angeschlagener Akkord (Anschlagreihenfolge); Ergebnis = Anzahl, 0 = noch keiner }
    function ArpChord(var Notes: array of Integer; var Vel: array of Single): Integer;
    { Name des zuletzt geladenen Presets (fuer effGetProgramName -> Host waehlt passende Demos) }
    property PresetName: string read FPresetName write FPresetName;
    property SidechainActive: Boolean read FScInput;
    { Pegel der vier VST-Eingaenge (Spitze, abklingend) - das Plugin meldet sie je Block (Anzeige) }
    procedure ReportVstInputPeaks(const Peaks: array of Single);
    function VstInputPeak(I: Integer): Single;
    { Laufzeit-Statistik des Plugin-Aufrufs (vom VST-Teil gefuellt, GUI zeigt Differenzen je Sekunde) }
    procedure AddProcStat(Frames: Integer; Ticks, HostTicks: Int64; ThreadId: Cardinal);
    procedure GetProcStat(out Calls, Frames, Ticks, MaxTicks, HostTicks, Hops: Int64; ResetMax: Boolean);
    property InputPeak: Single read FInPeak;
    property OutputPeak: Single read FOutPeak;
    { Limiter-Reduktion in dB seit der letzten Abfrage (0 = keine), setzt die Spitze zurueck }
    function TakeLimiterReduction: Single;
    { Anzahl Clipper-Eingriffe seit der letzten Abfrage (setzt zurueck) - fuer die CLIP-Leuchte }
    function TakeClipCount: Integer;
    function TakeMidiCount: Integer;
    property PitchTracker: TPitchTracker read FPitchTrk;
    { Pfad der geladenen WAV-Datei, leer beim Demo-Klang (fuer Chunk/Preset) }
    property SamplePath: string read FSamplePath;
  end;



var
  GSectProfOn: Boolean = False;              // Pruefstand: Rechenzeit je Abschnitt messen
  GSectTicks: array[0..27] of Int64;   // 20 GrainLevel, 21 Gain, 22 Drive, 23 EQ, 24 Stereo, 25 Limiter, 26 VoiceFilter-Summe   // 8 Arp/SC2, 9 UpdateModulation, 10 Filter-Huellk., 11 Blockparameter

{ Arp-Tonfolge: Tasten sortieren (ausser Modus 5 'wie gespielt') und ueber Oct Oktaven ausdehnen; Ergebnis = Laenge }
function ArpBuildSeq(const Held: array of Integer; const Vel: array of Single; Count, Mode, Oct: Integer;
  var Seq: array of Integer; var SeqVel: array of Single): Integer;
{ Index in der Tonfolge fuer den Zaehler Count (Modi ausser Zufall und Akkord) }
function ArpSeqIndex(Mode, Count, Len: Integer): Integer;

implementation

uses
  System.Diagnostics;

type
  { schlaeft, bis der Audio-Thread Resampling-Puffer braucht, und legt sie dann an }
  TResAllocThread = class(TThread)
  private
    FEngine: TGranularEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TGranularEngine);
  end;

constructor TResAllocThread.Create(AEngine: TGranularEngine);
begin
  FEngine := AEngine;
  inherited Create(False);
end;

procedure TResAllocThread.Execute;
begin
  while not Terminated do
    if (FEngine.FResWake.WaitFor(INFINITE) = wrSignaled) and not Terminated then
    begin
      try
        FEngine.ResPrepare;
      except
      end;
      FEngine.FResAsked := False;
    end;
end;

type
  PFloatArr = ^TFloatArr;
  TFloatArr = array[0..$FFFFFF] of Single;

var
  GWtDefault: array[0..WT_TOTAL - 1] of Single;   // Wavetable der Startwelle (gezeichnet)
  GWtDefaultReady: Boolean;
  // eingebaute Wellen als bandbegrenzte Wavetables: 0 Dreieck, 1 Saege, 2 Rechteck (Form, Phase und
  // Pegel exakt wie im klassischen Kern: Dreieck 1 - 4|w - 0,5|, Saege 2w - 1, Rechteck +1 / -1)
  GWtBuiltin: array[0..2, 0..WT_TOTAL - 1] of Single;

{ Zeichnung -> Obertoene (FFT der Punkte, ohne Gleichanteil) -> Glaettung (Obertoene weich abrunden)
  -> bandbegrenzte Stufen. Pegel: Spitze der reichsten Stufe = 1. }
procedure BuildDrawTable(const D: TOscDraw; Dst: PSingle);
var
  A, B: array of Double;
  K, NH: Integer;
  Sm, W: Double;
begin
  NH := OSC_DRAW_N div 2 - 1;
  SetLength(A, OSC_DRAW_N div 2 + 1);
  SetLength(B, OSC_DRAW_N div 2 + 1);
  WtAnalyze(D.Pt, OSC_DRAW_N, A, B);
  Sm := EnsureRange(D.Smooth, 0, 1);
  if Sm > 0 then
    for K := 1 to NH do
    begin
      // Glaettung: hoehere Obertoene sanft daempfen (100 % = fast Sinus)
      W := Exp(-1.2 * Sqr((K - 1) * Sm));
      A[K] := A[K] * W;
      B[K] := B[K] * W;
    end;
  WtBuild(A, B, NH, Dst, True);
end;

{ Fourier-Reihen der eingebauten Wellen, einmal je Programmlauf }
procedure BuildBuiltinWaves;
var
  A, B: array of Double;
  K: Integer;
begin
  SetLength(A, WT_HARM[0] + 1);
  SetLength(B, WT_HARM[0] + 1);
  // Dreieck 1 - 4|w - 0,5| = -(8/pi^2) Summe ungerade k cos(2 pi k w) / k^2
  for K := 1 to WT_HARM[0] do
  begin
    B[K] := 0;
    if Odd(K) then A[K] := -8 / Sqr(Pi) / Sqr(K) else A[K] := 0;
  end;
  WtBuild(A, B, WT_HARM[0], @GWtBuiltin[0, 0], False);
  // Saege 2w - 1 = -(2/pi) Summe sin(2 pi k w) / k
  for K := 1 to WT_HARM[0] do
  begin
    A[K] := 0;
    B[K] := -2 / Pi / K;
  end;
  WtBuild(A, B, WT_HARM[0], @GWtBuiltin[1, 0], False);
  // Rechteck (+1 erste Haelfte) = (4/pi) Summe ungerade k sin(2 pi k w) / k
  for K := 1 to WT_HARM[0] do
  begin
    A[K] := 0;
    if Odd(K) then B[K] := 4 / Pi / K else B[K] := 0;
  end;
  WtBuild(A, B, WT_HARM[0], @GWtBuiltin[2, 0], False);
end;

{ Abschnitts-Profil (nur Pruefstand, GSectProfOn = True): 0 Modulation/Arp, 1 Stimmen/Huellkurven,
  2 Grains, 3 Oszillatoren, 4 Filter je Note, 5 Echo, 6 Hall, 7 Rest (Summe, Drive, EQ, Limiter, Pegel) }
procedure SectMark(K: Integer; var T: Int64);
var
  N: Int64;
begin
  N := TStopwatch.GetTimeStamp;             // QPC-Takte (wie im Pruefstand)
  Inc(GSectTicks[K], N - T);
  T := N;
end;

{$POINTERMATH ON}

{ TGranularEngine }

constructor TGranularEngine.Create;
var
  I: Integer;
  Info: TParamInfo;
begin
  inherited Create;
  ResetGrains;
  // Kammfilter-Ringe: Filter 1/2 global und je Stimme
  SetLength(FCombMem, (2 + 2 * MAX_VOICES) * COMB_LEN * 2);
  FFlt1.Comb.Buf := @FCombMem[0];
  FFlt2.Comb.Buf := @FCombMem[COMB_LEN * 2];
  for I := 0 to MAX_VOICES - 1 do
  begin
    FVSvf1[I].Comb.Buf := @FCombMem[(2 + I * 2) * COMB_LEN * 2];
    FVSvf2[I].Comb.Buf := @FCombMem[(3 + I * 2) * COMB_LEN * 2];
  end;
  FTgMask := $FFFF;
  FTgGain := 1;
  for I := 0 to 127 do
    FCcMap[I] := -1;
  FLearnParam := -1;
  FLearnedCc := -1;
  for I := 0 to NAMED_COUNT - 1 do
    FEffMemoN[I] := -1;                       // Wirkwerte liegen in 0..1: erster Aufruf rechnet
  FLock := TCriticalSection.Create;
  FResWake := TEvent.Create(nil, False, False, '');
  FResThread := TResAllocThread.Create(Self);
  FEventLock := TCriticalSection.Create;
  FSampleRate := 44100;
  FRand := $2545F491;
  for I := 0 to PARAM_COUNT - 1 do
  begin
    Info := GetParamInfo(I);
    FParams[I] := PlainToParam(I, Info.DefV);
  end;
  for I := 0 to NAMED_COUNT - 1 do
  begin
    FEff[I] := FParams[I];
    FStepped[I] := GetParamInfo(I).Curve = pcStepped;
  end;
  FSat.Hi4[0] := 3; FSat.Lo4[0] := -3; FSat.C27[0] := 27; FSat.C9[0] := 9;
  for I := 1 to 3 do
  begin
    FSat.Hi4[I] := 3; FSat.Lo4[I] := -3; FSat.C27[I] := 27; FSat.C9[I] := 9;
  end;
  HbInitArgs(FHbDown, 1, HB_CENTER);
  HbInitArgs(FHbUp, 2, 0);
  FWtArgs.One := 1;
  // Startwelle: Tabellen nur einmal je Programmlauf rechnen, danach kopieren (viele Engines im Pruefstand)
  for I := 0 to OSC_COUNT - 1 do
    OscDrawDefault(FOscDraw[I]);
  if not GWtDefaultReady then
  begin
    BuildBuiltinWaves;
    BuildDrawTable(FOscDraw[0], @GWtDefault[0]);
    GWtDefaultReady := True;
  end;
  for I := 0 to OSC_COUNT - 1 do
  begin
    FWtPtr[I] := @GWtDefault[0];
    FWtCur[I] := 0;
  end;
  FGainPrev := -1;
  FGrainGainPrev := -1;
  FArpMask := $FFFF;
  for I := 0 to 4097 do
    FSinTab[I] := Sin(2 * Pi * I / 4096);
  FOscArgs.C1 := 1; FOscArgs.CM1 := -1; FOscArgs.C4 := 4; FOscArgs.CHalf := 0.5; FOscArgs.CTab := 4096;
  FOscArgs.Seed := 22222; FOscArgs.CInv31 := 1.6 / 2147483648.0;   // Rauschen lauter skaliert: gleichverteilt hat es nur ~58 % Effektivwert eines gleich hohen Sinus, Hochpass/Hats schlucken weiter Energie
  for I := 0 to 3 do
    FOscArgs.AbsMask4[I] := $7FFFFFFF;
  FScLevelArmed := True;
  FScTrigArmed := True;
  FOutTrigArmed := True;
  FScPitchArmed := True;
  FArpShown := -1;
  BuildWindows;
  FLastNote := -1;
  for I := 0 to NAMED_COUNT - 1 do
    FPndIdx[TGranularParamId(I)] := -1;
  for I := 0 to PND_COUNT - 1 do
    FPndIdx[PND_IDS[I]] := I;
  FreeLfoDefault(FFree[0]);
  FreeLfoDefault(FFree[1]);
  FreeLfoDefault(FFree[2]);
  FreeLfoDefault(FFree[3]);
  FreeLfoDefault(FFree[4]);
  FFree[2].Mode := 2;   // Morph-LFO: gezeichnete Kurve (Sinus) als Start
  FLimGain := 1;
  FLimMin := 1;
  FLimHold := 1;
  FPitchTrk := TPitchTracker.Create;
  FPitchTrk2 := TPitchTracker.Create;
  FReverb := TReverb.Create;
  FEq := TEqProcessor.Create;
  FResCur := -1;
  FResPrevBuf := -1;
  FResNote := -1;
  FResLastNote := -1;
  SetSampleRate(44100);
  for I := 0 to GRAIN_HISTORY - 1 do
    FHistory[I] := -1;
end;

destructor TGranularEngine.Destroy;
begin
  if FResThread <> nil then
  begin
    FResThread.Terminate;
    FResWake.SetEvent;
    FResThread.WaitFor;
    FResThread.Free;
  end;
  FResWake.Free;
  if FLayerB <> nil then
  begin
    FLayerB.FSample := nil;      // geliehen (Sample A oder B dieser Engine)
    FLayerB.Free;
  end;
  ResRestore;
  FSample.Free;
  FResSmp[0].Free;
  FResSmp[1].Free;
  FResSmp[2].Free;
  FSampleB.Free;
  FPitchTrk.Free;
  FPitchTrk2.Free;
  FReverb.Free;
  FEq.Free;
  FEventLock.Free;
  FLock.Free;
  inherited;
end;

procedure TGranularEngine.BuildWindows;
var
  I: Integer;
  X: Double;
begin
  for I := 0 to WINDOW_TABLE_SIZE do
  begin
    X := I / WINDOW_TABLE_SIZE;
    FWindows[0, I] := 0.5 - 0.5 * Cos(2 * Pi * X);              // Hann
    FWindows[1, I] := 1 - Abs(2 * X - 1);                       // Dreieck
    FWindows[2, I] := Min(1.0, Min(X, 1 - X) * 8);              // Trapez (12.5% Flanken)
    FWindows[3, I] := Exp(-0.5 * Sqr((X - 0.5) / 0.16));        // Gauss
  end;
  FWindows[3, 0] := 0;
  FWindows[3, WINDOW_TABLE_SIZE] := 0;
end;

function TGranularEngine.Rand: Single;
begin
  // xorshift32 - schnell, nur im Audio-Thread benutzt
  FRand := FRand xor (FRand shl 13);
  FRand := FRand xor (FRand shr 17);
  FRand := FRand xor (FRand shl 5);
  Result := (FRand shr 8) * (1 / 16777216);
end;

function TGranularEngine.Eff(Id: TGranularParamId): Double;
var
  I: Integer;
begin
  // Ergebnis je Regler merken: derselbe Wirkwert wird pro Subblock oft mehrfach umgerechnet
  // (Potenz bei logarithmischen Reglern) - bei gleichem Eingangswert exakt dasselbe Ergebnis
  I := Ord(Id);
  if FEff[I] <> FEffMemoN[I] then
  begin
    FEffMemoN[I] := FEff[I];
    FEffMemoV[I] := ParamToPlain(I, FEff[I]);
  end;
  Result := FEffMemoV[I];
end;

procedure TGranularEngine.SetSampleRate(Value: Double);
begin
  if Value <= 0 then
    Exit;
  FLock.Enter;
  try
    if (FSampleRate <> Value) and (FResCap > 0) then
    begin
      ResRestore;                 // Puffer passen zur alten Rate: neu anlegen
      FreeAndNil(FResSmp[0]);
      FreeAndNil(FResSmp[1]);
      FreeAndNil(FResSmp[2]);
      FResCap := 0;
    end;
    FSampleRate := Value;
    FPitchTrk.SetSampleRate(Value);
    FPitchTrk2.SetSampleRate(Value);
    FReverb.SetSampleRate(Value);
    FEq.SetSampleRate(Value);
    // Echo-Speicher: 3 Sekunden Stereo
    FEcho.Len := Round(Value * 3);
    FEchoBuf := nil;
    SetLength(FEchoBuf, FEcho.Len * 2);
    FEcho.WritePos := 0;
    FEcho.Delay := 0;
    // Pitch-Shifter-Puffer (muss > Fensterlaenge sein)
    FEcho.PLen := 4096;
    FPitchBuf := nil;
    SetLength(FPitchBuf, FEcho.PLen * 2);
    FEcho.PBuf := @FPitchBuf[0];
    FEcho.PWrite := 0;
    FEcho.PPhase := 0;
    FEcho.PRatio := 1;
  finally
    FLock.Leave;
  end;
end;

{ Grundton eines Samples (Median der YIN-Erkennung) und Korrektur zum naechsten C-Bezug }
procedure DetectRoot(Data: TSampleData; out Root, Tune: Double);
var
  P: TPitchTracker;
  I: Integer;
  Notes: array of Double;
  Cnt, J, K: Integer;
  T: Double;
begin
  Root := 0;
  Tune := 0;
  if (Data = nil) or (Data.Frames < 2048) then
    Exit;
  P := TPitchTracker.Create;
  try
    P.SetSampleRate(Data.SampleRate);
    SetLength(Notes, Data.Frames div 256 + 1);
    Cnt := 0;
    I := 0;
    while (I + 256 < Data.Frames) and (I < Data.SampleRate * 12) do   // hoechstens die ersten 12 s
    begin
      P.Process(@Data.L[I], @Data.R[I], 256);
      if P.Valid and (I > Data.SampleRate * 0.1) then
      begin
        Notes[Cnt] := P.Note;
        Inc(Cnt);
      end;
      Inc(I, 256);
    end;
  finally
    P.Free;
  end;
  if Cnt < 20 then
    Exit;   // keine stabile Tonhoehe (Sprache, Geraeusch, Akkord)
  // Median (Einfuegesortierung genuegt fuer einige hundert Werte)
  for J := 1 to Cnt - 1 do
  begin
    T := Notes[J];
    K := J - 1;
    while (K >= 0) and (Notes[K] > T) do
    begin
      Notes[K + 1] := Notes[K];
      Dec(K);
    end;
    Notes[K + 1] := T;
  end;
  Root := Notes[Cnt div 2];
  // nur bei EINEM stabilen Ton korrigieren: mittlere Haelfte der Messwerte innerhalb eines halben
  // Halbtons. Mehrton-, Akkord- und Glockenklaenge (Grundton ohne Bedeutung) bleiben unveraendert.
  if Notes[(Cnt * 3) div 4] - Notes[Cnt div 4] > 0.5 then
  begin
    Root := 0;   // kein eindeutiger Grundton
    Exit;
  end;
  // naechster C-Bezug: Korrektur im Bereich -6..+6 Halbtoene (Oktavlage bleibt)
  Tune := ROOT_NOTE - Root;
  Tune := Tune - 12 * Round(Tune / 12);
end;

procedure TGranularEngine.LoadSample(Data: TSampleData);
var
  Old: TSampleData;
  Root, Tune: Double;
begin
  DetectRoot(Data, Root, Tune);   // ausserhalb des Locks (dauert einen Moment)
  FLock.Enter;
  try
    ResetAll;
    ResRestore;
    Old := FSample;
    FSample := Data;
    FRootA := Root;
    FTuneA := Tune;
    if (Data <> nil) and FileExists(Data.FileName) then
      FSamplePath := Data.FileName
    else
      FSamplePath := '';
  finally
    FLock.Leave;
  end;
  Old.Free;
end;

{ --- Feedback-Resampling ---
  Nur solange eine Taste gehalten wird: alle 'Resampling Tempo' (0,25..4 s) wird das Gespielte zur neuen
  Grain-Quelle. Jeder neue Tastenanschlag beginnt wieder beim Original.
  Ablauf je Durchlauf: Ausgang aufnehmen (Laenge + Ueberblendstueck), dann in Stuecken (keine Lastspitze)
  den vorigen Stand tonhoehenrichtig dazukopieren, Gemisch messen und mit Pegelausgleich und Hochpass
  schreiben. Das Ende wird in den Anfang geblendet -> nahtlose Schleife ohne Delle an den Raendern.
  Drei Puffer: spielend, vorig (noch klingende Grains lesen ihn zu Ende), Ziel der Aufnahme.
  Die Tonlage der Aufnahme (Taste + Tonhoehe + Oktave) wird gemerkt und beim Abspielen abgezogen,
  sonst wuerde der Klang mit jedem Durchlauf weiter nach oben oder unten wandern. }

const
  RES_MAX_SEC = 8;
  RES_MIN_SEC = 0.25;
  RES_XFADE_SEC = 0.03;  // Ueberblendung Ende -> Anfang
  RES_CHUNK = 16384;     // Frames je Block in den Nacharbeits-Phasen

function TGranularEngine.GetSampleOrig: TSampleData;
begin
  if FResCur >= 0 then Result := FResOrig else Result := FSample;
end;

function TGranularEngine.ResActive: Boolean;
begin
  Result := FResCur >= 0;
end;

function TGranularEngine.ResPasses: Integer;
begin
  Result := FResPasses;
end;

function TGranularEngine.ResOffset: Double;
begin
  if FResCur >= 0 then Result := FResOfs else Result := 0;
end;

function TGranularEngine.ResReady: Boolean;
begin
  Result := FResCap > 0;
end;

procedure TGranularEngine.ResPrepare;
var
  Cap, I: Integer;
  Nw: array[0..RES_BUFS - 1] of TSampleData;
begin
  if (FParams[Ord(gpResOn)] < 0.5) or (FResCap > 0) then
    Exit;
  Cap := Round((RES_MAX_SEC + RES_XFADE_SEC) * FSampleRate) + 8;
  for I := 0 to RES_BUFS - 1 do
  begin
    Nw[I] := TSampleData.Create;
    SetLength(Nw[I].L, Cap);
    SetLength(Nw[I].R, Cap);
    SetLength(Nw[I].LR, (Cap + 1) * 2);
    Nw[I].Frames := 16;
    Nw[I].SampleRate := FSampleRate;
    Nw[I].Channels := 2;
  end;
  FLock.Enter;
  try
    if FResCap = 0 then
    begin
      for I := 0 to RES_BUFS - 1 do
      begin
        FResSmp[I] := Nw[I];
        Nw[I] := nil;
      end;
      FResCap := Cap;
      FResPhase := 0;
      FResPos := 0;
    end;
  finally
    FLock.Leave;
  end;
  for I := 0 to RES_BUFS - 1 do
    Nw[I].Free;
end;

procedure TGranularEngine.ResRestore;
begin
  if FResCur >= 0 then
  begin
    FSample := FResOrig;
    FResOrig := nil;
    FTuneA := FResTuneOrig;
    FResPrevBuf := FResCur;  // ausklingende Grains lesen ihn noch zu Ende
    FResCur := -1;
    if FSample <> nil then
      UpdateBlockParams;     // Auswahl wieder auf das Original
  end;
  FResPhase := 0;
  FResPos := 0;
  FResPasses := 0;
end;

procedure TGranularEngine.ResTick(OutL, OutR: PSingle; N: Integer);
var
  V, Lo, I, Cnt, Ip, Tg, C, Xf: Integer;
  Dst, Prev: TSampleData;
  P, Fr, Mix, G, A, W: Double;
  X, Y: Single;
  Wr: Boolean;
begin
  if (Eff(gpResOn) < 0.5) or (FResCap = 0) then
  begin
    if FResCur >= 0 then
      ResRestore;
    FResPhase := 0;
    FResPos := 0;
    FResKeySeen := FResKeySerial;
    Exit;
  end;
  // neuer Tastenanschlag: zurueck zum Original, die Entwicklung beginnt von vorn
  if FResKeySeen <> FResKeySerial then
  begin
    FResKeySeen := FResKeySerial;
    ResRestore;
  end;
  // tiefste gehaltene Taste: bestimmt die Tonlage der Aufnahme
  Lo := -1;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage in [esAttack, esDecay, esSustain]) and ((Lo < 0) or (FVoices[V].Note < Lo)) then
      Lo := FVoices[V].Note;
  if (Lo < 0) and (FResPhase = 0) then
  begin
    FResPos := 0;          // keine Taste gehalten: nichts entwickelt sich weiter
    Exit;
  end;
  // Ziel: weder der spielende noch der vorige Puffer (den lesen ausklingende Grains noch)
  Tg := 0;
  while (Tg = FResCur) or (Tg = FResPrevBuf) do
    Inc(Tg);
  Dst := FResSmp[Tg];
  Xf := Max(16, Round(RES_XFADE_SEC * FSampleRate));
  case FResPhase of
    0:
      begin
        if FResPos = 0 then
        begin
          C := EnsureRange(Round(Eff(gpResSync)), 0, 4);
          if C > 0 then
            W := RES_SYNC_BEATS[C] * 60 / Max(20.0, Eff(gpTempo))
          else
            W := Eff(gpResTime) / 1000;
          FResLen := EnsureRange(Round(W * FSampleRate),
            Round(RES_MIN_SEC * FSampleRate), Round(RES_MAX_SEC * FSampleRate));
          FResRawSq := 0;
          FResNote := Lo;
        end;
        Cnt := Min(N, FResLen + Xf - FResPos);
        for I := 0 to Cnt - 1 do
        begin
          X := OutL[I];
          Y := OutR[I];
          Dst.LR[(FResPos + I) * 2] := X;
          Dst.LR[(FResPos + I) * 2 + 1] := Y;
          FResRawSq := FResRawSq + X * X + Y * Y;
        end;
        Inc(FResPos, Cnt);
        if FResPos >= FResLen + Xf then
        begin
          FResPos := 0;
          if FResRawSq / (FResLen + Xf) < 1E-9 then
            Exit;                                    // nichts zu hoeren: Durchlauf verwerfen
          FResRecOfs := FPitch + FGrainOct;
          if FKeyTrack then
            FResRecOfs := FResRecOfs + FResNote - ROOT_NOTE;
          // vorigen Stand so lesen, dass er in der Tonlage der Aufnahme klingt
          if FResCur < 0 then
          begin
            if FAutoTune and FKeyTrack then A := -FTuneA else A := 0;
          end
          else
            A := FResOfs;
          FResPrevStep := FSample.SampleRate / FSampleRate * Power(2, (FResRecOfs - A) / 12);
          FResPrevS0 := FSel0;
          FResPrevLen := Max(16.0, Min(FSelLen, FSample.Frames - 2 - FSel0));
          FResPrevP := FResPrevS0;
          FResPrevSq := 0;
          FResPhase := 1;
        end;
      end;
    1:
      begin
        // vorigen Stand (Laenge + Ueberblendstueck) kopieren
        Prev := FSample;
        Cnt := Min(RES_CHUNK, FResLen + Xf - FResPos);
        P := FResPrevP;
        for I := FResPos to FResPos + Cnt - 1 do
        begin
          Ip := Trunc(P);
          Fr := P - Ip;
          X := Prev.L[Ip] + (Prev.L[Ip + 1] - Prev.L[Ip]) * Fr;
          Y := Prev.R[Ip] + (Prev.R[Ip + 1] - Prev.R[Ip]) * Fr;
          Dst.L[I] := X;
          Dst.R[I] := Y;
          if I < FResLen then
            FResPrevSq := FResPrevSq + X * X + Y * Y;
          P := P + FResPrevStep;
          while P >= FResPrevS0 + FResPrevLen do
            P := P - FResPrevLen;
        end;
        FResPrevP := P;
        Inc(FResPos, Cnt);
        if FResPos >= FResLen + Xf then
        begin
          FResPos := 0;
          // Pegel der Aufnahme an den vorigen Stand angleichen (sonst laeuft die Rueckkopplung weg)
          if FResPrevSq > 1E-6 then
            FResGain := EnsureRange(Sqrt(FResPrevSq / FResRawSq), 0.1, 10)
          else
            FResGain := EnsureRange(0.2 * Sqrt(FResLen / FResRawSq), 0.1, 10);
          for C := 0 to 1 do
          begin
            FResHpX[C] := 0;
            FResHpY[C] := 0;
          end;
          FResMixSq := 0;
          FResPhase := 2;
        end;
      end;
    2, 3:
      begin
        // 2: Gemisch nur messen, 3: mit Pegelausgleich schreiben (gleiche Rechnung, Hochpass neu gestartet).
        // Am Anfang wird das Ende (Frames Len..Len+Xf) eingeblendet: der Sprung vom letzten Frame zum
        // ersten ist so die natuerliche Fortsetzung des Klangs.
        Wr := FResPhase = 3;
        Mix := EnsureRange(Eff(gpResMix) / 100, 0, 1);
        G := Mix * FResGain;
        A := Exp(-2 * Pi * 30 / FSampleRate);        // Hochpass 30 Hz in der Rueckfuehrung
        Cnt := Min(RES_CHUNK, FResLen - FResPos);
        for I := FResPos to FResPos + Cnt - 1 do
        begin
          if I < Xf then W := I / Xf else W := 1;
          for C := 0 to 1 do
          begin
            X := Dst.LR[I * 2 + C] * W;
            if C = 0 then Y := Dst.L[I] * W else Y := Dst.R[I] * W;
            if W < 1 then
            begin
              X := X + Dst.LR[(FResLen + I) * 2 + C] * (1 - W);
              if C = 0 then Y := Y + Dst.L[FResLen + I] * (1 - W)
              else Y := Y + Dst.R[FResLen + I] * (1 - W);
            end;
            FResHpY[C] := A * (FResHpY[C] + X - FResHpX[C]);
            FResHpX[C] := X;
            Y := G * FResHpY[C] + (1 - Mix) * Y;
            if Wr then
              Dst.LR[I * 2 + C] := Y * FResNorm
            else
              FResMixSq := FResMixSq + Y * Y;
          end;
          if Wr then
          begin
            Dst.L[I] := Dst.LR[I * 2];
            Dst.R[I] := Dst.LR[I * 2 + 1];
          end;
        end;
        Inc(FResPos, Cnt);
        if (FResPos >= FResLen) and not Wr then
        begin
          // Gemisch auf den Pegel des vorigen Stands (unkorreliert verliert es sonst je Durchlauf bis 3 dB)
          if FResPrevSq > 1E-6 then
            FResNorm := EnsureRange(Sqrt(FResPrevSq / Max(1E-12, FResMixSq)), 0.25, 4)
          else
            FResNorm := 1;
          for C := 0 to 1 do
          begin
            FResHpX[C] := 0;
            FResHpY[C] := 0;
          end;
          FResPos := 0;
          FResPhase := 3;
        end
        else if FResPos >= FResLen then
        begin
          Dst.LR[FResLen * 2] := Dst.LR[0];          // Interpolation am Ende: weiter mit dem Anfang
          Dst.LR[FResLen * 2 + 1] := Dst.LR[1];
          Dst.L[FResLen] := Dst.L[0];
          Dst.R[FResLen] := Dst.R[0];
          Dst.Frames := FResLen + 1;
          Dst.SampleRate := FSampleRate;
          if FResCur < 0 then
          begin
            FResOrig := FSample;
            FResTuneOrig := FTuneA;
            FTuneA := 0;
          end;
          FSample := Dst;                            // neue Grains lesen ab jetzt den neuen Stand
          FResPrevBuf := FResCur;
          FResCur := Tg;
          FResOfs := FResRecOfs;
          Inc(FResPasses);
          UpdateBlockParams;
          FResPos := 0;
          FResPhase := 0;
        end;
      end;
  end;
end;

procedure TGranularEngine.ResetAll;
var
  I: Integer;
begin
  for I := 0 to MAX_VOICES - 1 do
    FVoices[I].Stage := esIdle;
  ResetGrains;
end;

procedure TGranularEngine.ResetGrains;
var
  I: Integer;
begin
  for I := 0 to MAX_GRAINS - 1 do
  begin
    FGrains[I].Active := False;
    FFreeList[I] := MAX_GRAINS - 1 - I;        // kleinster Index oben auf dem Stapel
  end;
  FFreeCount := MAX_GRAINS;
  FActiveGrains := 0;
end;

function TGranularEngine.GrainAlloc: Integer;
begin
  if FFreeCount = 0 then
    Exit(-1);
  Dec(FFreeCount);
  Result := FFreeList[FFreeCount];
  FGrains[Result].Active := True;
  FActList[FActiveGrains] := Result;
  FActPos[Result] := FActiveGrains;
  Inc(FActiveGrains);
end;

procedure TGranularEngine.GrainFree(Slot: Integer);
var
  P, Last: Integer;
begin
  if not FGrains[Slot].Active then
    Exit;
  FGrains[Slot].Active := False;
  // aus der Aktiv-Liste: letzten Eintrag an diese Stelle ziehen
  P := FActPos[Slot];
  Dec(FActiveGrains);
  Last := FActList[FActiveGrains];
  FActList[P] := Last;
  FActPos[Last] := P;
  FFreeList[FFreeCount] := Slot;
  Inc(FFreeCount);
end;

function TGranularEngine.GetParam(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < PARAM_COUNT) then
    Result := FParams[Index]
  else
    Result := 0;
end;

procedure TGranularEngine.SetParam(Index: Integer; Value: Single);
begin
  if (Index >= 0) and (Index < PARAM_COUNT) then
    FParams[Index] := EnsureRange(Value, 0, 1);
end;

function TGranularEngine.GetParamById(Id: TGranularParamId): Single;
begin
  Result := FParams[Ord(Id)];
end;

procedure TGranularEngine.SetParamById(Id: TGranularParamId; Value: Single);
begin
  SetParam(Ord(Id), Value);
end;

function TGranularEngine.GetEffParam(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < NAMED_COUNT) then
    Result := FEff[Index]
  else
    Result := GetParam(Index);
end;

function TGranularEngine.GetOscDraw(O: Integer): POscDraw;
begin
  Result := @FOscDraw[EnsureRange(O, 0, OSC_COUNT - 1)];
end;

function TGranularEngine.OscWaveTable(O: Integer): PSingle;
begin
  O := EnsureRange(O, 0, OSC_COUNT - 1);
  Result := FWtPtr[O];
end;

{ Wavetable-Welle mit den Werten aus FOscArgs (Ausgabe, Huellkurve, Phase, Panorama, Sync). Stufe nach der
  erlaubten Obertonzahl WT_MARGIN / Schritt (Oversampling: Schritt halb), zwischen zwei Stufen stufenlos
  ueberblendet: beim Gleiten kommen Obertoene weich dazu bzw. gehen weich - kein Sprung an Stufengrenzen.
  Die reichere Stufe reicht dabei hoechstens bis knapp ueber die halbe Abtastrate (Spiegelungen > 20 kHz). }
procedure TGranularEngine.RenderWtOsc(Tab: PSingle);
var
  M0, M1: Integer;
  Hal, Mf: Double;
begin
  // Mf = 6 log2(H0 / erlaubte Obertoene), erlaubt = WT_MARGIN * halbe Abtastrate / Schritt
  Hal := WT_MARGIN * 0.5 / Max(FOscArgs.DtP * FOscArgs.SyncR, 1E-9);
  Mf := 6 * Log2(WT_HARM[0] / Max(Hal, 1E-9));
  if Mf < 0 then Mf := 0;
  if Mf > WT_MIPS - 1 then Mf := WT_MIPS - 1;
  M0 := Trunc(Mf);
  M1 := Min(M0 + 1, WT_MIPS - 1);
  FWtArgs.Out := FOscArgs.Out;
  FWtArgs.Env := FOscArgs.Env;
  FWtArgs.TabA := @PFloatArr(Tab)[WT_OFS[M0]];
  FWtArgs.TabB := @PFloatArr(Tab)[WT_OFS[M1]];
  FWtArgs.CSizeA := WT_LEN[M0];
  FWtArgs.CSizeB := WT_LEN[M1];
  FWtArgs.Mix := Mf - M0;
  FWtArgs.Count := FOscArgs.Count;
  FWtArgs.Ph := FOscArgs.Ph;
  FWtArgs.DtP := FOscArgs.DtP;
  FWtArgs.SyncR := FOscArgs.SyncR;
  FWtArgs.GL := FOscArgs.GL;
  FWtArgs.GR := FOscArgs.GR;
  if (FOscArgs.SyncR = 1) and (WT_LEN[M0] = WT_LEN[M1]) then
    RenderWtFast(@FWtArgs)       // ohne Sync, gleich lange Stufen: ein Index fuer beide
  else
    RenderWt(@FWtArgs);
  FOscArgs.Ph := FWtArgs.Ph;
end;

{ Tabellen der gezeichneten Welle O neu: in den freien Puffer (beim ersten Mal angelegt - nie im
  Audio-Thread), dann umschalten; der Audio-Thread liest nur die aktive Tabelle. }
procedure TGranularEngine.OscDrawChanged(O: Integer);
var
  Nxt: Integer;
begin
  O := EnsureRange(O, 0, OSC_COUNT - 1);
  Nxt := 1 - FWtCur[O];
  if Length(FWtBuf[O, Nxt]) <> WT_TOTAL then
    SetLength(FWtBuf[O, Nxt], WT_TOTAL);
  BuildDrawTable(FOscDraw[O], @FWtBuf[O, Nxt][0]);
  FWtPtr[O] := @FWtBuf[O, Nxt][0];
  FWtCur[O] := Nxt;
end;

function TGranularEngine.GetFreeLfo(Index: Integer): PFreeLfo;
begin
  Result := @FFree[EnsureRange(Index, 0, FREE_LFO_COUNT - 1)];
end;

function TGranularEngine.GetLfoPhase(Index: Integer): Double;
begin
  // Anzeige-Index (= Platz der freien Form): 0/1 = LFO 1/2, 2 = Morph-LFO, 3..8 = LFO 3..8
  case Index of
    0, 1: Result := FLfoPhase[Index];
    2: Result := FMorphPhase;
    3..8: Result := FLfoPhase[Index - 1];
  else
    Result := 0;
  end;
end;

function TGranularEngine.GetLfoValue(Index: Integer): Single;
begin
  case Index of
    0: Result := FSource[msLfo1];
    1: Result := FSource[msLfo2];
    2: Result := FMorphLfoVal;
    3: Result := FSource[msLfo3];
    4: Result := FSource[msLfo4];
    5..8: Result := FSource[LFO_SRC[Index - 1]];
  else
    Result := 0;
  end;
end;

function TGranularEngine.GetSourceValue(Src: TModSource): Single;
begin
  Result := FSource[Src];
end;

{ --- Events --- }

procedure TGranularEngine.QueueEvent(const E: TNoteEvent);
begin
  AtomicIncrement(FMidiCount);
  FEventLock.Enter;
  try
    if FPendingCount < MAX_EVENTS then
    begin
      FPending[FPendingCount] := E;
      Inc(FPendingCount);
    end;
  finally
    FEventLock.Leave;
  end;
end;

procedure TGranularEngine.NoteOn(Note: Integer; Velocity: Single; DeltaFrames: Integer);
var
  E: TNoteEvent;
begin
  E.Kind := neOn;
  E.Note := Note;
  E.Velocity := Velocity;
  E.DeltaFrames := DeltaFrames;
  QueueEvent(E);
end;

procedure TGranularEngine.NoteOff(Note: Integer; DeltaFrames: Integer);
var
  E: TNoteEvent;
begin
  E.Kind := neOff;
  E.Note := Note;
  E.Velocity := 0;
  E.DeltaFrames := DeltaFrames;
  QueueEvent(E);
end;

procedure TGranularEngine.AllNotesOff;
var
  E: TNoteEvent;
begin
  E.Kind := neAllOff;
  E.Note := 0;
  E.Velocity := 0;
  E.DeltaFrames := 0;
  QueueEvent(E);
end;

procedure TGranularEngine.PitchBend(Value: Single; DeltaFrames: Integer);
var
  E: TNoteEvent;
begin
  E.Kind := neBend; E.Note := 0; E.Velocity := Value; E.DeltaFrames := DeltaFrames;
  QueueEvent(E);
end;

procedure TGranularEngine.ControlChange(Cc: Integer; Value: Single; DeltaFrames: Integer);
var
  E: TNoteEvent;
begin
  E.Kind := neControl; E.Note := Cc; E.Velocity := Value; E.DeltaFrames := DeltaFrames;
  QueueEvent(E);
end;

procedure TGranularEngine.MidiLearnStart(Index: Integer);
begin
  FLearnedCc := -1;
  FLearnParam := Index;
end;

procedure TGranularEngine.MidiLearnCancel;
begin
  FLearnParam := -1;
end;

function TGranularEngine.MidiLearnPending: Boolean;
begin
  Result := FLearnParam >= 0;
end;

function TGranularEngine.MidiLearnPoll: Integer;
begin
  Result := FLearnedCc;
  if Result >= 0 then
    FLearnedCc := -1;
end;

function TGranularEngine.CcForParam(Index: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to 127 do
    if FCcMap[I] = Index then
      Exit(I);
  Result := -1;
end;

function TGranularEngine.CcTarget(Cc: Integer): Integer;
begin
  if (Cc >= 0) and (Cc <= 127) then Result := FCcMap[Cc] else Result := -1;
end;

{ ein Parameter haengt an hoechstens einem Controller: alte Zuordnung loesen }
procedure TGranularEngine.SetCcTarget(Cc, Index: Integer);
var
  I: Integer;
begin
  if (Cc < 0) or (Cc > 127) then
    Exit;
  if Index >= 0 then
    for I := 0 to 127 do
      if FCcMap[I] = Index then
        FCcMap[I] := -1;
  FCcMap[Cc] := Index;
end;

procedure TGranularEngine.ChannelPressure(Value: Single; DeltaFrames: Integer);
var
  E: TNoteEvent;
begin
  E.Kind := nePressure; E.Note := 0; E.Velocity := Value; E.DeltaFrames := DeltaFrames;
  QueueEvent(E);
end;

procedure TGranularEngine.ApplyEvent(const E: TNoteEvent);
var
  I: Integer;
  R: TNoteEvent;
begin
  case E.Kind of
    neOn:
      if E.Velocity > 0 then
      begin
        Inc(FResKeySerial);         // Resampling beginnt wieder beim Original
        KeyDown(E.Note, E.Velocity);
      end
      else
        KeyUp(E.Note);
    neOff:
      if FSustainPedal then
        FHeldBySustain[E.Note and 127] := True   // Pedal haelt die Note
      else
        KeyUp(E.Note);
    neBend:
      begin
        FBend := EnsureRange(E.Velocity, -1, 1);
        FSource[msPitchBend] := FBend;
        // Protokoll: nur bei merklicher Aenderung (2 %) oder beim Erreichen der Mitte/Enden
        if FLogOn and ((Abs(FBend - FLogBend) >= 0.04) or ((FBend <> FLogBend) and
           ((FBend = 0) or (Abs(FBend) >= 1)))) then
        begin
          FLogBend := FBend;
          LogTrig(tlBend, 0, 0, FBend, FBend * FBendRange);
        end;
      end;
    nePressure:
      begin
        FSource[msAftertouch] := EnsureRange(E.Velocity, 0, 1);
        if FLogOn and ((Abs(FSource[msAftertouch] - FLogPress) >= 0.02) or
           ((FSource[msAftertouch] <> FLogPress) and ((FSource[msAftertouch] = 0) or (FSource[msAftertouch] = 1)))) then
        begin
          FLogPress := FSource[msAftertouch];
          LogTrig(tlPressure, 0, 0, FLogPress);
        end;
      end;
    neControl:
    begin
      if (FLearnParam >= 0) and (E.Note >= 0) and (E.Note < 120) and (E.Note <> 64) then
      begin
        SetCcTarget(E.Note, FLearnParam);
        FLearnParam := -1;
        FLearnedCc := E.Note;
      end;
      if (E.Note >= 0) and (E.Note <= 127) and (FCcMap[E.Note] >= 0) then
        SetParam(FCcMap[E.Note], E.Velocity);
      case E.Note of
        1:
          begin
            FSource[msModWheel] := EnsureRange(E.Velocity, 0, 1);
            if FLogOn and ((Abs(FSource[msModWheel] - FLogMod) >= 0.02) or
               ((FSource[msModWheel] <> FLogMod) and ((FSource[msModWheel] = 0) or (FSource[msModWheel] = 1)))) then
            begin
              FLogMod := FSource[msModWheel];
              LogTrig(tlControl, 0, 1, FLogMod);
            end;
          end;
        121:
          begin
            R := E;
            R.Kind := neResetCtrl;
            ApplyEvent(R);
          end;
        64:
          begin
            FSustainPedal := E.Velocity >= 0.5;
            if not FSustainPedal then
              for I := 0 to 127 do
                if FHeldBySustain[I] then
                begin
                  FHeldBySustain[I] := False;
                  KeyUp(I);
                end;
          end;
      end;
    end;
    neResetCtrl:
      begin
        FBend := 0;
        FSource[msPitchBend] := 0;
        FSource[msModWheel] := 0;
        FSource[msAftertouch] := 0;
        FSustainPedal := False;
        for I := 0 to 127 do
          if FHeldBySustain[I] then
          begin
            FHeldBySustain[I] := False;
            KeyUp(I);
          end;
      end;
    neAllOff:
      for I := 0 to MAX_VOICES - 1 do
        if FVoices[I].Stage in [esAttack, esDecay, esSustain] then
        begin
          FVoices[I].Stage := esRelease;
          FVoices[I].StageTime := 0;
        end;
  end;
  if E.Kind = neAllOff then
  begin
    FillChar(FHeldBySustain, SizeOf(FHeldBySustain), 0);
    FArpHeldCount := 0;
    FillChar(FArpDown, SizeOf(FArpDown), 0);
    FArpDownCount := 0;
    FArpCurCount := 0;
    FArpRunning := False;
  end;
end;

procedure TGranularEngine.StartVoice(Note: Integer; Velocity: Single);
var
  O, K: Integer;
  I, V: Integer;
  Dis, Cnt: Integer;
  Oldest: Int64;
  Mode: Integer;
  Legato: Boolean;
  Cap: Integer;
begin
  // Leistungsstufe: nur die ersten Cap Stimmen benutzen (weniger gleichzeitige Rechenarbeit)
  Cap := Min(MAX_VOICES, PERF_VOICES[PerfLevel]);
  V := -1;
  for I := 0 to Cap - 1 do
    if FVoices[I].Stage = esIdle then
    begin
      V := I;
      Break;
    end;
  if V < 0 then
  begin
    // Voice-Stealing: bevorzugt Stimmen im Release, sonst die aelteste
    Oldest := High(Int64);
    for I := 0 to Cap - 1 do
      if (FVoices[I].Stage = esRelease) and (FVoices[I].Stamp < Oldest) then
      begin
        Oldest := FVoices[I].Stamp;
        V := I;
      end;
    if V < 0 then
      for I := 0 to Cap - 1 do
        if FVoices[I].Stamp < Oldest then
        begin
          Oldest := FVoices[I].Stamp;
          V := I;
        end;
    KillGrainsOfVoice(V);
  end;

  // Portamento: neue Note gleitet von der aktuellen Tonhoehe der letzten Note her
  // (Modus 2: nur, wenn noch eine andere Taste gehalten wird)
  FGlideOfs[V] := 0;
  FGlideStep[V] := 0;
  if (FLastNote >= 0) and (FLastNote <> Note) then
  begin
    Legato := False;
    for I := 0 to MAX_VOICES - 1 do
      if (I <> V) and (FVoices[I].Stage in [esAttack, esDecay, esSustain]) then
        Legato := True;
    Mode := ParamStep(Ord(gpGlideMode), FParams[Ord(gpGlideMode)]);
    if (Mode = 1) or ((Mode = 2) and Legato) then
    begin
      FGlideOfs[V] := FLastNote + FGlideOfs[EnsureRange(FLastVoice, 0, MAX_VOICES - 1)] - Note;
      FGlideStep[V] := Abs(FGlideOfs[V]) /
        Max(1.0, ParamToPlain(gpGlideTime, FParams[Ord(gpGlideTime)]) * FSampleRate / 1000);
    end;
  end;
  FLastNote := Note;
  FLastVoice := V;
  LogTrig(tlNoteOn, V, Note, Velocity, FGlideOfs[V]);
  // Polyphone Modulation: eigener Zufallswert, Noten-LFOs starten in dieser Stimme bei 0
  FVRnd[V] := Rand;
  ResetFlt(FVSvf1[V]);
  ResetFlt(FVSvf2[V]);
  for O := 0 to OSC_COUNT - 1 do
  begin
    FillChar(FVSvfOsc[O, V].IC1, SizeOf(FVSvfOsc[O, V].IC1), 0); FillChar(FVSvfOsc[O, V].IC2, SizeOf(FVSvfOsc[O, V].IC2), 0);
  end;
  FVFltEnv[V] := 0;
  FVFltStage[V] := esAttack;
  for I := 0 to LFO_COUNT - 1 do
  begin
    FVLfoPh[V, I] := 0;
    // Zufallszahl nur fuer LFO 1..4 und Noten-LFOs 5..8: der Zufallsgenerator ist mit den Grains geteilt,
    // eine zusaetzliche Ziehung je Note wuerde den Klang bestehender Presets veraendern
    if (I < 4) or (ParamStep(Ord(LFO_TRIG_IDS[I]), FParams[Ord(LFO_TRIG_IDS[I])]) in [1..3]) then
      FVLfoHold[V, I] := 2 * Rand - 1
    else
      FVLfoHold[V, I] := 0;
    FVLfoDone[V, I] := False;
    // Neustart 'Note an' verzoegert: der LFO dieser Note bleibt still, bis die Zeit um ist
    FVLfoWait[V, I] := 0;
    FVLfoMute[V, I] := False;
    FVLfoStopWait[V, I] := 0;
    if ParamStep(Ord(LFO_TRIG_IDS[I]), FParams[Ord(LFO_TRIG_IDS[I])]) in [1, 3] then
    begin
      FVLfoWait[V, I] := EventDelaySamples(0);
      FVLfoMute[V, I] := FVLfoWait[V, I] > 0;
      if StopIsTime(I) then
        FVLfoStopWait[V, I] := FVLfoWait[V, I] + StopTimeSamples(I);
    end;
  end;
  Inc(FNoteOnCount);
  // Stimmungs-Analyse: Tonklasse zaehlen, Dichte, Anschlag, Lage, Dissonanz zu gehaltenen Toenen
  FMoodPc[Note mod 12] := FMoodPc[Note mod 12] + 0.25;   // Anschlag zaehlt wenig, Klingdauer zaehlt (s. UpdateModulation)
  FMoodRate := FMoodRate + 1 / 3;
  FMoodVel := FMoodVel + (Velocity - FMoodVel) * 0.1;
  FMoodPitch := FMoodPitch + (Note - FMoodPitch) * 0.1;
  Dis := 0; Cnt := 0;
  for I := 0 to MAX_VOICES - 1 do
    if (I <> V) and (FVoices[I].Stage in [esAttack, esDecay, esSustain]) then
    begin
      Inc(Cnt);
      if (Abs(FVoices[I].Note - Note) mod 12) in [1, 6, 11] then Inc(Dis);   // kleine Sekunde, Tritonus, grosse Septime
    end;
  if Cnt > 0 then
    FMoodLegato := FMoodLegato + (1 - FMoodLegato) * 0.1      // ueberlappend gespielt
  else
    FMoodLegato := FMoodLegato + (0 - FMoodLegato) * 0.1;

  Inc(FStampCounter);
  FVoices[V].Stage := esAttack;
  FVoices[V].StageTime := 0;
  FVoices[V].Env := 0;
  FVoices[V].Note := Note;
  FVoices[V].Velocity := Velocity;
  FVoices[V].ScanDir := 1;
  // Anlauf: vor der Auswahl beginnen (in Auswahl-Einheiten negativ), einmal hineinlaufen
  FVoices[V].InPre := FPreOfs < 0;
  if FVoices[V].InPre then
    FVoices[V].ScanPos := FPreOfs
  else
    FVoices[V].ScanPos := 0;
  FVoices[V].NextGrain := 0;
  FVoices[V].Stamp := FStampCounter;

  FFltTrigger := True;
  FTrigOn := True;
  // Oszillator-Stimmen mitstarten (gleicher Platz wie die Grain-Stimme)
  for O := 0 to OSC_COUNT - 1 do
  begin
    FOsc[O, V].Stage := esAttack;
    FOsc[O, V].FmStage := esAttack;
    FOsc[O, V].StageTime := 0;
    FOsc[O, V].FmStageTime := 0;
    FOsc[O, V].Note := Note;
    FOsc[O, V].Vel := Velocity;
    if FOsc[O, V].Env <= 0 then
    begin
      FOsc[O, V].Ph := 0;
      FOsc[O, V].PhM := 0;
      for K := 0 to UNI_MAX - 2 do
      begin
        FOsc[O, V].UPh[K] := Rand;      // Unison: freie Phasen -> breiter, kein Phasing beim Anschlag
        FOsc[O, V].UPhM[K] := 0;
      end;
    end;
  end;
  FOscLast := V;

  // globale Notenquellen fuer die Matrix (letzte Note gewinnt)
  FSource[msVelocity] := Velocity;
  FSource[msNoteRandom] := Rand;
  FSource[msNote] := EnsureRange(Note / 127, 0, 1);
end;

{ --- Arpeggiator --- }

function ArpBuildSeq(const Held: array of Integer; const Vel: array of Single; Count, Mode, Oct: Integer;
  var Seq: array of Integer; var SeqVel: array of Single): Integer;
var
  I, J, K, T: Integer;
  Sorted: array[0..31] of Integer;
  SortedVel: array[0..31] of Single;
  V: Single;
begin
  Count := Min(Count, Length(Sorted));
  // Grundreihe: nach Tonhoehe sortiert oder in Anschlagreihenfolge
  for I := 0 to Count - 1 do
  begin
    Sorted[I] := Held[I];
    SortedVel[I] := Vel[I];
  end;
  if Mode <> 5 then
    for I := 1 to Count - 1 do
    begin
      T := Sorted[I]; V := SortedVel[I];
      J := I - 1;
      while (J >= 0) and (Sorted[J] > T) do
      begin
        Sorted[J + 1] := Sorted[J]; SortedVel[J + 1] := SortedVel[J];
        Dec(J);
      end;
      Sorted[J + 1] := T; SortedVel[J + 1] := V;
    end;
  // ueber die Oktaven ausdehnen
  Result := 0;
  for K := 0 to Oct - 1 do
    for I := 0 to Count - 1 do
      if (Result <= High(Seq)) and (Sorted[I] + 12 * K <= 127) then
      begin
        Seq[Result] := Sorted[I] + 12 * K;
        SeqVel[Result] := SortedVel[I];
        Inc(Result);
      end;
end;

function ArpSeqIndex(Mode, Count, Len: Integer): Integer;
var
  Cycle: Integer;
begin
  case Mode of
    1: Result := Len - 1 - Count mod Len;                          // runter
    2, 3:
      begin
        // hoch + runter ohne doppelte Endtoene
        if Len = 1 then
          Result := 0
        else
        begin
          Cycle := Count mod (2 * Len - 2);
          if Cycle < Len then Result := Cycle else Result := 2 * Len - 2 - Cycle;
          if Mode = 3 then
            Result := Len - 1 - Result;
        end;
      end;
  else
    Result := Count mod Len;                                        // hoch / wie gespielt
  end;
end;

function TGranularEngine.ArpChord(var Notes: array of Integer; var Vel: array of Single): Integer;
var
  I: Integer;
begin
  Result := Min(FArpLastCount, Length(Notes));
  for I := 0 to Result - 1 do
  begin
    Notes[I] := FArpLast[I];
    Vel[I] := FArpLastVel[I];
  end;
end;

function TGranularEngine.ArpActive: Boolean;
begin
  Result := FEff[Ord(gpArpOn)] >= 0.5;
end;

procedure TGranularEngine.KeyDown(Note: Integer; Velocity: Single);
var
  I: Integer;
begin
  if not ArpActive then
  begin
    StartVoice(Note, Velocity);
    Exit;
  end;
  // Latch: erste Taste nach dem Loslassen aller Tasten beginnt einen neuen Akkord (alter faellt weg)
  if (Eff(gpArpLatch) >= 0.5) and (FArpDownCount = 0) then
    FArpHeldCount := 0;
  if (Note >= 0) and (Note <= 127) and not FArpDown[Note] then
  begin
    FArpDown[Note] := True;
    Inc(FArpDownCount);
  end;
  for I := 0 to FArpHeldCount - 1 do
    if FArpHeld[I] = Note then
    begin
      FArpVel[I] := Velocity;
      Exit;
    end;
  if FArpHeldCount <= High(FArpHeld) then
  begin
    FArpHeld[FArpHeldCount] := Note;
    FArpVel[FArpHeldCount] := Velocity;
    Inc(FArpHeldCount);
  end;
  // Akkord fuer den MIDI-Export merken (bleibt nach dem Loslassen erhalten)
  for I := 0 to FArpHeldCount - 1 do
  begin
    FArpLast[I] := FArpHeld[I];
    FArpLastVel[I] := FArpVel[I];
  end;
  FArpLastCount := FArpHeldCount;
end;

procedure TGranularEngine.KeyUp(Note: Integer);
var
  I, J: Integer;
begin
  if (Note >= 0) and (Note <= 127) and FArpDown[Note] then
  begin
    FArpDown[Note] := False;
    Dec(FArpDownCount);
  end;
  // Latch: die Taste bleibt in der Arp-Liste (spielt weiter, bis neue Tasten kommen)
  if ArpActive and (Eff(gpArpLatch) >= 0.5) then
    for I := 0 to FArpHeldCount - 1 do
      if FArpHeld[I] = Note then
        Exit;
  // auch bei aktivem Arp: eine vorher direkt gestartete Stimme dieser Taste loslassen
  for I := 0 to FArpHeldCount - 1 do
    if FArpHeld[I] = Note then
    begin
      for J := I to FArpHeldCount - 2 do
      begin
        FArpHeld[J] := FArpHeld[J + 1];
        FArpVel[J] := FArpVel[J + 1];
      end;
      Dec(FArpHeldCount);
      Exit;
    end;
  ReleaseNote(Note);
end;

procedure TGranularEngine.ArpReleaseCurrent;
var
  I: Integer;
begin
  for I := 0 to FArpCurCount - 1 do
    ReleaseNote(FArpCur[I]);
  FArpCurCount := 0;
end;

{ einen Schritt ausfuehren: Muster pruefen, Note(n) waehlen und anschlagen }
procedure TGranularEngine.ArpStepNow;
var
  Steps, StepIdx, Mode, Oct, Len, I, Idx: Integer;
  Seq: array[0..127] of Integer;
  SeqVel: array[0..127] of Single;
begin
  Steps := ParamStep(Ord(gpArpSteps), FEff[Ord(gpArpSteps)]) + 1;
  StepIdx := FArpStep mod Steps;
  Inc(FArpStep);
  ArpReleaseCurrent;   // vorige Note endet spaetestens hier (kein Haengen)
  FArpShown := StepIdx;
  if (FArpMask and (1 shl StepIdx)) = 0 then
    Exit;              // Pause in diesem Schritt
  Mode := ParamStep(Ord(gpArpMode), FEff[Ord(gpArpMode)]);
  Oct := ParamStep(Ord(gpArpOct), FEff[Ord(gpArpOct)]) + 1;

  Len := ArpBuildSeq(FArpHeld, FArpVel, FArpHeldCount, Mode, Oct, Seq, SeqVel);
  if Len = 0 then
    Exit;

  if Mode = 6 then
  begin
    // Akkord: alle gehaltenen Tasten (in allen Oktaven) gleichzeitig - rhythmische Akkorde
    for I := 0 to Min(Len, High(FArpCur) + 1) - 1 do
    begin
      StartVoice(Seq[I], SeqVel[I]);
      FArpCur[FArpCurCount] := Seq[I];
      Inc(FArpCurCount);
    end;
    Inc(FArpCount);
    Exit;
  end;

  if Mode = 4 then
    Idx := Min(Trunc(Rand * Len), Len - 1)                          // Zufall
  else
    Idx := ArpSeqIndex(Mode, FArpCount, Len);
  Inc(FArpCount);
  StartVoice(Seq[Idx], SeqVel[Idx]);
  FArpCur[0] := Seq[Idx];
  FArpCurCount := 1;
end;

procedure TGranularEngine.ArpTick(N: Integer);
var
  StepLen, Swing, Gate, Tempo, Len: Double;
  BlockEnd: Double;
begin
  // Latch ausgeschaltet: Toene, deren Taste nicht mehr gedrueckt ist, fallen weg
  if (FArpHeldCount > 0) and (Eff(gpArpLatch) < 0.5) then
  begin
    Len := 0;
    StepLen := 0;
    while Round(StepLen) < FArpHeldCount do
    begin
      if FArpDown[EnsureRange(FArpHeld[Round(StepLen)], 0, 127)] then
      begin
        FArpHeld[Round(Len)] := FArpHeld[Round(StepLen)];
        FArpVel[Round(Len)] := FArpVel[Round(StepLen)];
        Len := Len + 1;
      end;
      StepLen := StepLen + 1;
    end;
    FArpHeldCount := Round(Len);
  end;
  if not ArpActive or (FArpHeldCount = 0) then
  begin
    // Arp aus oder alle Tasten los: laufende Arp-Note beenden, Takt beim naechsten Anschlag neu
    if FArpCurCount > 0 then
      ArpReleaseCurrent;
    FArpRunning := False;
    FArpShown := -1;
    Exit;
  end;
  Tempo := Max(20.0, Eff(gpTempo));
  StepLen := 60 / Tempo * ARP_RATE_BEATS[ParamStep(Ord(gpArpRate), FEff[Ord(gpArpRate)])] * FSampleRate;
  Swing := Eff(gpArpSwing) / 100;
  Gate := Eff(gpArpGate) / 100;
  if not FArpRunning then
  begin
    // erster Anschlag: sofort spielen
    FArpRunning := True;
    FArpPos := 0;
    FArpNext := 0;
    FArpStep := 0;
    FArpCount := 0;
  end;
  BlockEnd := FArpPos + N;
  // Notenende (Laenge) innerhalb dieses Blocks
  if (FArpCurCount > 0) and (FArpGateEnd < BlockEnd) and (Gate < 0.999) then
    ArpReleaseCurrent;
  while FArpNext < BlockEnd do
  begin
    // Swing: gerade Schritte laenger, ungerade entsprechend kuerzer (Summe bleibt im Takt)
    if FArpStep mod 2 = 0 then Len := StepLen * (1 + Swing) else Len := StepLen * (1 - Swing);
    ArpStepNow;
    FArpGateEnd := FArpNext + Max(64.0, Len * Gate);
    FArpNext := FArpNext + Max(64.0, Len);
  end;
  FArpPos := BlockEnd;
end;

function TGranularEngine.OscHeld(V, Note: Integer): Boolean;
var
  O: Integer;
begin
  for O := 0 to OSC_COUNT - 1 do
    if (FOsc[O, V].Note = Note) and (FOsc[O, V].Stage in [esAttack, esDecay, esSustain]) then
      Exit(True);
  Result := False;
end;

procedure TGranularEngine.ReportVstInputPeaks(const Peaks: array of Single);
var
  I: Integer;
begin
  for I := 0 to Min(3, High(Peaks)) do
    if Peaks[I] > FVstInPeak[I] * 0.9 then
      FVstInPeak[I] := Peaks[I]
    else
      FVstInPeak[I] := FVstInPeak[I] * 0.9;     // abklingen (Anzeige)
end;

procedure TGranularEngine.AddProcStat(Frames: Integer; Ticks, HostTicks: Int64; ThreadId: Cardinal);
begin
  Inc(FStCalls);
  Inc(FStFrames, Frames);
  Inc(FStTicks, Ticks);
  Inc(FStHost, HostTicks);
  if Ticks > FStMax then
    FStMax := Ticks;
  if (FStThread <> 0) and (ThreadId <> FStThread) then
    Inc(FStHops);
  FStThread := ThreadId;
end;

procedure TGranularEngine.GetProcStat(out Calls, Frames, Ticks, MaxTicks, HostTicks, Hops: Int64; ResetMax: Boolean);
begin
  Calls := FStCalls; Frames := FStFrames; Ticks := FStTicks; MaxTicks := FStMax;
  HostTicks := FStHost; Hops := FStHops;
  if ResetMax then
    FStMax := 0;
end;

function TGranularEngine.VstInputPeak(I: Integer): Single;
begin
  if (I >= 0) and (I <= 3) then Result := FVstInPeak[I] else Result := 0;
end;

function TGranularEngine.EngineIdle: Boolean;
var
  V: Integer;
begin
  Result := False;
  if (FActiveGrains > 0) or (FArpHeldCount > 0) or (FArpCurCount > 0) then
    Exit;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage <> esIdle) or OscSounding(V, False) then
      Exit;
  Result := True;
end;

function InputSilent(L, R: PSingle; Frames: Integer): Boolean;
var
  I: Integer;
begin
  Result := True;
  if L <> nil then
    for I := 0 to Frames - 1 do
      if Abs((L + I)^) > 1E-6 then
        Exit(False);
  if (R <> nil) and (R <> L) then
    for I := 0 to Frames - 1 do
      if Abs((R + I)^) > 1E-6 then
        Exit(False);
end;

function TGranularEngine.OscSounding(V: Integer; HeldOnly: Boolean): Boolean;
var
  O: Integer;
begin
  for O := 0 to OSC_COUNT - 1 do
    if (HeldOnly and (FOsc[O, V].Stage in [esAttack, esDecay, esSustain])) or
       (not HeldOnly and (FOsc[O, V].Stage <> esIdle)) then
      Exit(True);
  Result := False;
end;

procedure TGranularEngine.ReleaseNote(Note: Integer);
var
  I, K, T: Integer;
begin
  LogTrig(tlNoteOff, 0, Note);
  // polyphone Noten-LFOs mit Neustart "Note aus" / "an + aus": nur in der losgelassenen Stimme
  for I := 0 to MAX_VOICES - 1 do
    if OscHeld(I, Note) or
       ((FVoices[I].Note = Note) and (FVoices[I].Stage in [esAttack, esDecay, esSustain])) then
      for K := 0 to LFO_COUNT - 1 do
      begin
        T := Round(Eff(LFO_TRIG_IDS[K]));
        if T in [2, 3] then
        begin
          FVLfoWait[I, K] := EventDelaySamples(1);
          FVLfoMute[I, K] := False;
          if FVLfoWait[I, K] <= 0 then
          begin
            FVLfoWait[I, K] := 0;
            FVLfoPh[I, K] := 0;
            FVLfoHold[I, K] := 2 * Rand - 1;
            FVLfoDone[I, K] := False;
          end;
          if StopIsTime(K) then
            FVLfoStopWait[I, K] := FVLfoWait[I, K] + StopTimeSamples(K);
        end;
        // Aus-Trigger 'Note aus': der LFO dieser Note haelt an (ggf. verzoegert)
        if (T in [1..3]) and (Round(Eff(LFO_STOP_IDS[K])) = 2) then
          StopVoiceLfo(I, K, EventDelaySamples(1));
      end;
  for K := 0 to OSC_COUNT - 1 do
    for I := 0 to MAX_VOICES - 1 do
      if (FOsc[K, I].Note = Note) and (FOsc[K, I].Stage in [esAttack, esDecay, esSustain]) then
      begin
        FOsc[K, I].Stage := esRelease;
        FOsc[K, I].FmStage := esRelease;
        FOsc[K, I].StageTime := 0;
        FOsc[K, I].FmStageTime := 0;
      end;
  for I := 0 to MAX_VOICES - 1 do
    if (FVoices[I].Note = Note) and (FVoices[I].Stage in [esAttack, esDecay, esSustain]) then
    begin
      FVoices[I].Stage := esRelease;
      FVoices[I].StageTime := 0;
      FTrigOff := True;
    end;
end;

procedure TGranularEngine.KillGrainsOfVoice(V: Integer);
var
  I: Integer;
begin
  for I := FActiveGrains - 1 downto 0 do      // rueckwaerts: GrainFree zieht den letzten nach vorn
    if FGrains[FActList[I]].Voice = V then
      GrainFree(FActList[I]);
end;

{ --- Modulation --- }

procedure TGranularEngine.UpdateModulation(InL, InR: PSingle; N: Integer);
var
  Ev, Dly, StopS, Vc: Integer;
  Fire, Stopped: Boolean;

  { ist Ereignis Ev (0..7, Reiter Timing / Events) in diesem Block fuer LFO K eingetreten? }
  function EvFired(Ev, K: Integer): Boolean;
  begin
    case Ev of
      0: Result := FTrigOn;
      1: Result := FTrigOff;
      2: Result := FLfoEndEvt[EnsureRange(Round(Eff(LFO_PARTNER_IDS[K])), 0, LFO_COUNT - 1)];
      3: Result := FScTrigEvt;
      4: Result := FScPitchEvt;
      5: Result := FGateEvt;
      6: Result := FQuietEvt;
      7: Result := FOutTrigEvt;
    else
      Result := False;
    end;
  end;

var
  I, K, Slot, Src, Dst, Best, Trig, Cnt, Dis: Integer;
  BestStamp: Int64;
  Peak, V, Hz, Coef, Amt, Fac, Ofs: Double;
  Once, UseL, UseP, Hi, Lo: Boolean;
  Mo: Double;
  Shp: Integer;
  T: Int64;
begin
  if GSectProfOn then T := TStopwatch.GetTimeStamp;
  // Sidechain-Huellkurvenfolger (Spitzenwert je Subblock, Attack/Release geglaettet)
  FScInput := InL <> nil;
  Peak := 0;
  if FScInput then
  begin
    for I := 0 to N - 1 do
    begin
      V := Abs(InL[I]);
      if V > Peak then Peak := V;
      V := Abs(InR[I]);
      if V > Peak then Peak := V;
    end;
    if Peak > FInPeak then FInPeak := Peak;
    Peak := Peak * Power(10, Eff(gpScGain) / 20);
  end;
  FInPeak := FInPeak * 0.995;   // langsamer Abfall fuer die Anzeige
  if Peak > FScLevel then
    Coef := Exp(-N / Max(1.0, Eff(gpScAttack) * FSampleRate / 1000))
  else
    Coef := Exp(-N / Max(1.0, Eff(gpScRelease) * FSampleRate / 1000));
  FScLevel := Peak + (FScLevel - Peak) * Coef;
  FSource[msSidechain] := Min(1.0, FScLevel);

  // Tonhoehe des Sidechains (haelt den letzten gueltigen Wert)
  FPitchTrk.Process(InL, InR, N);
  FSource[msScPitch] := EnsureRange(FPitchTrk.Note / 127, 0, 1);

  // freie Makros: Reglerstellung durch die gewaehlte Kurve (Ziele ueber die Matrix)
  for I := 0 to UMAC_COUNT - 1 do
  begin
    V := EnsureRange(FParams[Ord(UMAC_IDS[I])], 0, 1);
    case ParamStep(Ord(UMAC_CURVE_IDS[I]), FParams[Ord(UMAC_CURVE_IDS[I])]) of
      1: V := V * V;                              // langsam ansteigend
      2: V := 1 - (1 - V) * (1 - V);              // schnell ansteigend
      3: V := V * V * (3 - 2 * V);                // S-Kurve
    end;
    FSource[UMAC_SRC[I]] := V;
  end;

  if GSectProfOn then SectMark(12, T);
  // Amplituden-Huellkurve der juengsten Stimme
  Best := -1;
  BestStamp := -1;
  for I := 0 to MAX_VOICES - 1 do
    if (FVoices[I].Stage <> esIdle) and (FVoices[I].Stamp > BestStamp) then
    begin
      BestStamp := FVoices[I].Stamp;
      Best := I;
    end;
  if Best >= 0 then
    FSource[msAmpEnv] := FVoices[Best].Env
  else
    FSource[msAmpEnv] := 0;
  // Oszillator-Huellkurven (global = juengste Stimme; je Note in UpdateVoiceModulation)
  FSource[msOsc1Env] := FOsc[0, EnsureRange(FOscLast, 0, MAX_VOICES - 1)].Env;
  FSource[msOsc2Env] := FOsc[1, EnsureRange(FOscLast, 0, MAX_VOICES - 1)].Env;
  FSource[msOsc3Env] := FOsc[2, EnsureRange(FOscLast, 0, MAX_VOICES - 1)].Env;

  // Sidechain-Schwellen als Ereignisse (steigende Flanke, Hysterese gegen Flattern)
  V := Eff(gpScTrigLevel) / 100;
  FScLevelEvt := FScLevelArmed and (FSource[msSidechain] > V);
  if FScLevelEvt then
    FScLevelArmed := False
  else if FSource[msSidechain] < V * 0.7 then
    FScLevelArmed := True;
  FScPitchEvt := False;
  if FScInput and FPitchTrk.Valid then
  begin
    FScPitchEvt := FScPitchArmed and (FPitchTrk.Note > Eff(gpScTrigNote));
    if FScPitchEvt then
      FScPitchArmed := False
    else if FPitchTrk.Note < Eff(gpScTrigNote) - 1 then
      FScPitchArmed := True;
  end;

  // Sidechain-Trigger: alle eingeschalteten Bedingungen erfuellt -> ausloesen; wieder scharf,
  // sobald eine davon deutlich darunter liegt (Pegel < 70 % der Schwelle, Ton 1 Halbton tiefer)
  UseL := Eff(gpScUseLevel) >= 0.5;
  UseP := Eff(gpScUsePitch) >= 0.5;
  if not UseL and not UseP then
    UseL := True;
  Hi := True;
  Lo := False;
  if UseL then
  begin
    Hi := FSource[msSidechain] > V;
    Lo := FSource[msSidechain] < V * 0.7;
  end;
  if UseP then
    if FScInput and FPitchTrk.Valid then
    begin
      Hi := Hi and (FPitchTrk.Note > Eff(gpScTrigNote));
      Lo := Lo or (FPitchTrk.Note < Eff(gpScTrigNote) - 1);
    end
    else
    begin
      Hi := False;
      Lo := True;
    end;
  FScTrigEvt := FScTrigArmed and Hi;
  if FScTrigEvt then
    FScTrigArmed := False
  else if Lo then
    FScTrigArmed := True;

  // Schwellen-Tor: beliebige Quelle gegen Schwelle (Hysterese 5 %) -> Matrix-Quelle 0/1 und Trigger.
  // LFO-Werte stammen hier aus dem vorigen Subblock (64 Samples), das genuegt fuer Schaltvorgaenge.
  V := FSource[TModSource(EnsureRange(Round(Eff(gpGateSrc)), 0, Ord(High(TModSource))))];
  FGateEvt := False;
  if not FGateOpen and (V > Eff(gpGateThresh) / 100) then
  begin
    FGateOpen := True;
    FGateEvt := True;
  end
  else if FGateOpen and (V < Eff(gpGateThresh) / 100 - 0.05) then
    FGateOpen := False;
  if FGateOpen then FSource[msGate] := 1 else FSource[msGate] := 0;
  // Ruhe-Ereignis: einmal feuern, wenn die Quelle ununterbrochen die Ruhe-Dauer unter der Schwelle
  // blieb (z. B. Pause zwischen Bassdrums, Stille im Kanal); erst nach Ueberschreiten wieder scharf
  FQuietEvt := False;
  if V >= Eff(gpGateThresh) / 100 then
    FQuietSamples := 0
  else if FQuietSamples >= 0 then
  begin
    FQuietSamples := FQuietSamples + SUB_BLOCK;
    if FQuietSamples >= Eff(gpGateQuiet) * 0.001 * FSampleRate then
    begin
      FQuietEvt := True;
      FQuietSamples := -1;
    end;
  end;

  // Ausgangs-Trigger: eigener Ausgangspegel (Spitze, vorheriger Block) ueber der Schwelle;
  // wieder scharf unter 70 % der Schwelle
  V := Eff(gpOutTrigLevel) / 100;
  FOutTrigEvt := FOutTrigArmed and (FOutPeak > V);
  if FOutTrigEvt then
    FOutTrigArmed := False
  else if FOutPeak < V * 0.7 then
    FOutTrigArmed := True;

  if GSectProfOn then SectMark(13, T);
  // Stimmungs-Analyse: gleitend vergessen (Tonklassen ~8 s, Dichte ~3 s), Pegel mitteln
  Coef := Exp(-N / (FSampleRate * 5));
  for I := 0 to 11 do
    FMoodPc[I] := FMoodPc[I] * Coef;
  // Tonklassen nach Klingdauer gewichten (lange, gehaltene Toene praegen die Tonart staerker als
  // schnelle Laeufe); Dissonanz laufend aus den gerade klingenden Toenen (Zeitkonstante ~1,5 s)
  Cnt := 0; Dis := 0;
  for I := 0 to MAX_VOICES - 1 do
    if FVoices[I].Stage <> esIdle then
    begin
      FMoodPc[FVoices[I].Note mod 12] := FMoodPc[FVoices[I].Note mod 12] + FVoices[I].Env * N / FSampleRate;
      if FVoices[I].Stage in [esAttack, esDecay, esSustain] then
        for K := I + 1 to MAX_VOICES - 1 do
          if FVoices[K].Stage in [esAttack, esDecay, esSustain] then
          begin
            Inc(Cnt);
            if (Abs(FVoices[K].Note - FVoices[I].Note) mod 12) in [1, 6, 11] then Inc(Dis);
          end;
    end;
  if Cnt > 0 then
    FMoodDiss := FMoodDiss + (Dis / Cnt - FMoodDiss) * Min(1.0, N / (FSampleRate * 1.5))
  else
    FMoodDiss := FMoodDiss * Exp(-N / (FSampleRate * 3));
  FMoodRate := FMoodRate * Exp(-N / (FSampleRate * 3));
  FMoodLevel := FMoodLevel + (Min(1.0, FOutPeak * 1.6) - FMoodLevel) * Min(1.0, N / (FSampleRate * 1.5));

  // Protokoll fuer das Info-Fenster (nur wenn offen)
  Inc(FLogClock, N);
  if FLogOn then
  begin
    // Noten werden einzeln in StartVoice/ReleaseNote protokolliert
    if FScTrigEvt then
      LogTrig(tlScTrig, 0, Ord(FPitchTrk.Valid), FSource[msSidechain], Eff(gpScTrigLevel) / 100);
    if FScPitchEvt then
      LogTrig(tlScPitch, 0, 0, FPitchTrk.Note, Eff(gpScTrigNote));
    if FGateEvt then LogTrig(tlGate);
    if FQuietEvt then LogTrig(tlQuiet);
    if FOutTrigEvt then LogTrig(tlOutTrig, 0, 0, FOutPeak, Eff(gpOutTrigLevel) / 100);
  end;

  if GSectProfOn then SectMark(14, T);
  // LFOs (Rate aus den Wirkwerten des vorigen Subblocks -> LFO kann LFO modulieren)
  UpdateLfoUsed;
  for K := 0 to LFO_COUNT - 1 do
  begin
    // LFO 5..8 ohne Benutzer: nicht rechnen (LFO 1..4 laufen immer - sie teilen den Zufallsgenerator mit
    // den Grains; ueberspringen wuerde den Klang bestehender Presets minimal veraendern)
    if not FLfoUsed[K] then
    begin
      FSource[LFO_SRC[K]] := 0;
      FLfoEndEvt[K] := False;
      Continue;
    end;
    // Neustart: 1 = Note an, 2 = Note aus, 3 = beides
    // 4 = Ende des anderen LFOs (dessen Ereignis stammt aus diesem oder dem vorigen Subblock
    // und wird genau einmal gesehen: jeder LFO loescht sein eigenes Ereignis vor der Neuberechnung)
    Trig := Round(Eff(LFO_TRIG_IDS[K]));
    // welches Ereignis feuert fuer diesen LFO? (0..7 wie im Reiter Timing / Events, -1 = keins)
    Ev := -1;
    if (Trig in [1, 3]) and FTrigOn then Ev := 0
    else if (Trig in [2, 3]) and FTrigOff then Ev := 1
    else if (Trig = LFO_TRIG_OTHER_END) and EvFired(2, K) then Ev := 2
    else if (Trig = LFO_TRIG_SC_LEVEL) and FScTrigEvt then Ev := 3
    else if (Trig = LFO_TRIG_SC_PITCH) and FScPitchEvt then Ev := 4
    else if (Trig = LFO_TRIG_GATE) and FGateEvt then Ev := 5
    else if (Trig = LFO_TRIG_QUIET) and FQuietEvt then Ev := 6
    else if (Trig = LFO_TRIG_OUT) and FOutTrigEvt and not FOutBusy[K] then Ev := 7;
    Fire := False;
    if Ev >= 0 then
    begin
      Dly := EventDelaySamples(Ev);
      if Dly <= 0 then
        Fire := True
      else
      begin
        FLfoPend[K] := Dly;              // spaeter neu starten (neues Ereignis = Wartezeit von vorn)
        FLfoPendTrig[K] := Trig;
        if Trig = LFO_TRIG_OUT then
          FOutBusy[K] := True;           // waehrend der Wartezeit nicht erneut ausloesbar
      end;
    end
    else if FLfoPend[K] > 0 then
    begin
      Dec(FLfoPend[K], N);
      if FLfoPend[K] <= 0 then
      begin
        FLfoPend[K] := 0;
        Fire := True;
        Trig := FLfoPendTrig[K];
      end;
    end;
    if Fire then
    begin
      FLfoPend[K] := 0;
      FLfoRun[K] := 1;
      FLfoStopPend[K] := 0;
      if StopIsTime(K) then
        FLfoStopPend[K] := StopTimeSamples(K);   // Stopp nach Zeit: zaehlt ab jetzt
      FLfoPhase[K] := 0;
      FLfoHold[K] := 2 * Rand - 1;
      FLfoDone[K] := False;
      // vom eigenen Ausgangspegel gestartet: bis zum Ende dieses Durchlaufs nicht erneut ausloesbar
      // (sonst wuerde der Klang, den der LFO erzeugt, ihn sofort wieder starten - Rueckkopplung)
      FOutBusy[K] := Trig = LFO_TRIG_OUT;
      if Eff(LFO_ONCE_IDS[K]) >= 0.5 then          // nur Einmal-LFOs protokollieren (die anderen laufen ohnehin)
        LogTrig(tlLfoStart, K, Trig);
    end;
    // Aus-Trigger: haelt den LFO an (Wert 0) bis zum naechsten Start-Ereignis. Nur mit Start-Ereignis
    // wirksam ('frei' laeuft immer); mit Aus-Trigger wartet der LFO auch anfangs auf seinen ersten Start.
    StopS := Round(Eff(LFO_STOP_IDS[K]));
    Stopped := False;
    if (StopS = 0) or (Trig = 0) then
      FLfoStopPend[K] := 0
    else if Trig in [1..3] then
    begin
      // Noten-LFO: 'Note aus' wirkt je Stimme (ReleaseNote), 'Note an' gar nicht, die anderen auf alle Stimmen
      if (StopS >= 3) and EvFired(StopS - 1, K) then
      begin
        Dly := EventDelaySamples(StopS - 1);
        for Vc := 0 to MAX_VOICES - 1 do
          StopVoiceLfo(Vc, K, Dly);
      end;
    end
    else
    begin
      if EvFired(StopS - 1, K) then
      begin
        Dly := EventDelaySamples(StopS - 1);
        if Dly <= 0 then
          FLfoRun[K] := 2
        else
          FLfoStopPend[K] := Dly;
      end
      else if FLfoStopPend[K] > 0 then
      begin
        Dec(FLfoStopPend[K], N);
        if FLfoStopPend[K] <= 0 then
          FLfoRun[K] := 2;
      end;
      if FLfoRun[K] = 2 then
      begin
        FLfoStopPend[K] := 0;
        FLfoPend[K] := 0;
        FOutBusy[K] := False;
      end;
      Stopped := FLfoRun[K] <> 1;
    end;
    FLfoEndEvt[K] := False;
    Once := Eff(LFO_ONCE_IDS[K]) >= 0.5;
    if not Once then
      FLfoDone[K] := False;
    if Eff(LFO_SYNC_IDS[K]) >= 0.5 then
      Hz := (Eff(gpTempo) / 60) / LFO_DIV_BEATS[LfoDivisionIndex(FEff[Ord(LFO_RATE_IDS[K])])]
    else
      Hz := Eff(LFO_RATE_IDS[K]);
    if not FLfoDone[K] and not Stopped then
      FLfoPhase[K] := FLfoPhase[K] + Hz * N / FSampleRate;
    if Once and (FLfoPhase[K] >= 1) then
    begin
      // Einmal-Modus: am Ende stehen bleiben (letzter Wert bleibt), Ende-Ereignis melden
      FLfoPhase[K] := 0.999999;
      FLfoDone[K] := True;
      FLfoEndEvt[K] := True;
      FOutBusy[K] := False;
      LogTrig(tlLfoEnd, K);
    end
    else if FLfoPhase[K] >= 1 then
    begin
      FLfoPhase[K] := FLfoPhase[K] - Floor(FLfoPhase[K]);
      FLfoHold[K] := 2 * Rand - 1;   // neuer Sample&Hold-Wert je Periode
      FOutBusy[K] := False;          // ein Durchlauf fertig: Ausgangs-Trigger wieder frei
    end;
    if Stopped then
      FSource[LFO_SRC[K]] := 0                    // angehalten: keine Modulation
    else if Round(Eff(LFO_SHAPE_IDS[K])) = LFO_SHAPE_FREE then
      FSource[LFO_SRC[K]] := FreeLfoValue(FFree[LFO_FREE_IDX[K]], FLfoPhase[K])
    else
      FSource[LFO_SRC[K]] := LfoShapeValue(Round(Eff(LFO_SHAPE_IDS[K])), FLfoPhase[K], FLfoHold[K]);
  end;
  FSource[msOff] := 0;
  FTrigOn := False;
  FTrigOff := False;

  if GSectProfOn then SectMark(15, T);
  // Matrix anwenden. Grundwert = eigene Einstellung (A), mit Morph zum Ziel B ueberblendet;
  // die Morph-Menge stammt aus dem vorigen Subblock (inkl. Modulation, wie bei den LFO-Raten)
  Mo := EnsureRange(FEff[Ord(gpMorph)], 0, 1);
  for I := 0 to NAMED_COUNT - 1 do
    FEff[I] := FParams[I];
  if FMorphValid and (Mo > 0.0005) then
    for I := 0 to NAMED_COUNT - 1 do
      // nicht gemorpht: Morph selbst, Tempo und der eigene Morph-LFO (gehoert zu keinem der beiden Klaenge);
      // bei 'Zwei Klaenge' gar nichts - A bleibt A, B rechnet selbst
      if not FLayerOn and (I <> Ord(gpMorph)) and (I <> Ord(gpTempo)) and (I <> Ord(gpMorphMode)) and
         not (I in [Ord(gpMorphLfoShape), Ord(gpMorphLfoRate), Ord(gpMorphLfoSync), Ord(gpMorphLfoDepth)]) then
        if FStepped[I] then
        begin
          if Mo >= 0.5 then
            FEff[I] := FMorphB[I];
        end
        else
          FEff[I] := FParams[I] + (FMorphB[I] - FParams[I]) * Mo;
  for Slot := 0 to MOD_SLOTS - 1 do
  begin
    Src := ParamStep(SlotSourceIndex(Slot), FParams[SlotSourceIndex(Slot)]);
    Dst := ParamStep(SlotDestIndex(Slot), FParams[SlotDestIndex(Slot)]);
    if (Src = 0) or (Dst = 0) then
      Continue;
    Amt := ParamToPlain(SlotAmountIndex(Slot), FParams[SlotAmountIndex(Slot)]) / 100;
    Fac := MOD_FACTORS[ParamStep(SlotFactorIndex(Slot), FParams[SlotFactorIndex(Slot)])];
    Ofs := ParamToPlain(SlotOffsetIndex(Slot), FParams[SlotOffsetIndex(Slot)]) / 100;
    // Noten-Quelle auf ein Ziel, das je Note berechnet wird: nicht global, sondern je Stimme (s. u.)
    if IsNoteSource(Src) and (FPndIdx[TGranularParamId(Dst - 1)] >= 0) then
      Continue;
    // Wirkwert = Grundwert + (Quelle * Faktor + Offset) * Menge
    FEff[Dst - 1] := FEff[Dst - 1] + Amt * (FSource[TModSource(Src)] * Fac + Ofs);
  end;
  ApplyMacros;
  // eigener Morph-LFO: schwingt um die Reglerstellung, Tiefe 100 % = einmal ganz von A (0) nach B (1)
  Shp := ParamStep(Ord(gpMorphLfoShape), FParams[Ord(gpMorphLfoShape)]);
  if Shp > 0 then
  begin
    if FParams[Ord(gpMorphLfoSync)] >= 0.5 then
      Hz := (Eff(gpTempo) / 60) / LFO_DIV_BEATS[LfoDivisionIndex(FParams[Ord(gpMorphLfoRate)])]
    else
      Hz := ParamToPlain(gpMorphLfoRate, FParams[Ord(gpMorphLfoRate)]);
    FMorphPhase := FMorphPhase + Hz * N / FSampleRate;
    if FMorphPhase >= 1 then
    begin
      FMorphPhase := FMorphPhase - Floor(FMorphPhase);
      FMorphHold := 2 * Rand - 1;
    end;
    if Shp = MORPH_LFO_FREE then
      V := FreeLfoValue(FFree[2], FMorphPhase)
    else
      V := LfoShapeValue(Shp - 1, FMorphPhase, FMorphHold);
    FMorphLfoVal := V;
    FEff[Ord(gpMorph)] := FEff[Ord(gpMorph)] +
      V * 0.5 * ParamToPlain(gpMorphLfoDepth, FParams[Ord(gpMorphLfoDepth)]) / 100;
  end;
  for I := 0 to NAMED_COUNT - 1 do
    FEff[I] := EnsureRange(FEff[I], 0, 1);
  if GSectProfOn then SectMark(16, T);
  UpdateVoiceModulation(N);
  if GSectProfOn then SectMark(17, T);
end;

{ Ist die Quelle an eine Note gebunden? Velocity, Zufall je Note, Notenhoehe, Grain-/Osz-Huellkurven und
  LFOs mit Neustart "Note an", "Note aus" oder "an + aus" (die laufen je Stimme). }
function TGranularEngine.GetMood: TMood;
const
  // Tonart-Profile (Krumhansl-Kessler): Gewicht je Stufe ab dem Grundton
  MAJ: array[0..11] of Single = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88);
  MIN: array[0..11] of Single = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17);
var
  Tot, BMaj, BMin, A, B, Mode, Cons, Reg: Double;
  K, I: Integer;
begin
  Tot := 0;
  for I := 0 to 11 do
    Tot := Tot + FMoodPc[I];
  Mode := 0;
  if Tot > 0.8 then
  begin
    BMaj := 0; BMin := 0;
    for K := 0 to 11 do
    begin
      A := 0; B := 0;
      for I := 0 to 11 do
      begin
        A := A + FMoodPc[(K + I) mod 12] * MAJ[I];
        B := B + FMoodPc[(K + I) mod 12] * MIN[I];
      end;
      if A > BMaj then BMaj := A;
      if B > BMin then BMin := B;
    end;
    Mode := EnsureRange((BMaj - BMin) / Max(1E-6, BMaj + BMin) * 12, -1, 1);   // Dur + / Moll -
  end;
  Cons := 1 - 2 * EnsureRange(FMoodDiss * 2.5, 0, 1);
  Reg := EnsureRange((FMoodPitch - 60) / 24, -1, 1);
  Result.Valence := EnsureRange(0.6 * Mode + 0.3 * Cons + 0.1 * Reg, -1, 1);
  A := FMoodRate / 5;
  if A > 1 then A := 1;
  A := 0.4 * A + 0.25 * FMoodVel + 0.25 * FMoodLevel + 0.1 * (1 - FMoodLegato);
  Result.Arousal := EnsureRange(A, 0, 1);
  // zaertlich / verliebt: hell, ruhig, gebunden, eher leise und nicht tief
  Result.Tender := EnsureRange(Result.Valence * 3, 0, 1) * EnsureRange((0.55 - Result.Arousal) * 3, 0, 1) *
    EnsureRange(0.4 + FMoodLegato, 0, 1) * EnsureRange(1.3 - FMoodVel, 0, 1) * EnsureRange(1.2 + Reg, 0, 1);
  if (Tot <= 0.8) and (FMoodLevel < 0.02) then
  begin
    Result.Kind := mkNone; Result.Name := '-';
  end
  else if Result.Tender > 0.45 then
  begin
    Result.Kind := mkTender; Result.Name := 'zärtlich, verliebt';
  end
  else if Result.Valence >= 0.1 then
  begin
    if Result.Arousal >= 0.5 then begin Result.Kind := mkHappy; Result.Name := 'fröhlich, ausgelassen'; end
    else begin Result.Kind := mkCalm; Result.Name := 'entspannt, zufrieden'; end;
  end
  else if Result.Valence <= -0.1 then
  begin
    if Result.Arousal >= 0.5 then begin Result.Kind := mkAngry; Result.Name := 'angespannt, wütend'; end
    else begin Result.Kind := mkSad; Result.Name := 'traurig, melancholisch'; end;
  end
  else
  begin
    if Result.Arousal >= 0.5 then begin Result.Kind := mkHappy; Result.Name := 'energiegeladen'; end
    else begin Result.Kind := mkMystic; Result.Name := 'schwebend, geheimnisvoll'; end;
  end;
end;

function TGranularEngine.EventDelaySamples(Ev: Integer): Integer;
var
  St: Integer;
  Sec: Double;
begin
  // eingestellte Werte (nicht die Wirkwerte): beim Anschlag gleich nach einem Presetwechsel sind die
  // Wirkwerte erst im naechsten Block aktuell
  St := ParamStep(Ord(DLY_SYNC[Ev]), FParams[Ord(DLY_SYNC[Ev])]);
  if St > 0 then
    Sec := DLY_SYNC_BEATS[EnsureRange(St, 0, High(DLY_SYNC_BEATS))] * 60 /
      Max(1.0, ParamToPlain(gpTempo, FParams[Ord(gpTempo)]))
  else
    Sec := ParamToPlain(DLY_MS[Ev], FParams[Ord(DLY_MS[Ev])]) / 1000;
  Result := Round(Sec * FSampleRate);
end;

function TGranularEngine.StopTimeSamples(K: Integer): Integer;
var
  St: Integer;
  Sec: Double;
begin
  St := ParamStep(Ord(LFO_STOP_SYNC[K]), FParams[Ord(LFO_STOP_SYNC[K])]);
  if St > 0 then
    Sec := DLY_SYNC_BEATS[EnsureRange(St, 0, High(DLY_SYNC_BEATS))] * 60 / Max(1.0, Eff(gpTempo))
  else
    Sec := ParamToPlain(Ord(LFO_STOP_MS[K]), FParams[Ord(LFO_STOP_MS[K])]) / 1000;
  Result := Max(1, Round(Sec * FSampleRate));
end;

function TGranularEngine.StopIsTime(K: Integer): Boolean;
begin
  Result := ParamStep(Ord(LFO_STOP_IDS[K]), FParams[Ord(LFO_STOP_IDS[K])]) = LFO_STOP_TIME;
end;

procedure TGranularEngine.StopVoiceLfo(V, K, Dly: Integer);
begin
  if Dly > 0 then
    FVLfoStopWait[V, K] := Dly
  else
  begin
    FVLfoStopWait[V, K] := 0;
    FVLfoWait[V, K] := 0;          // ein noch wartender Start entfaellt
    FVLfoMute[V, K] := True;       // still und eingefroren bis zum naechsten Start
  end;
end;

function TGranularEngine.SlotIsGlobalNote(Slot: Integer): Boolean;
var
  Src, Dst: Integer;
begin
  Src := ParamStep(SlotSourceIndex(Slot), FParams[SlotSourceIndex(Slot)]);
  Dst := ParamStep(SlotDestIndex(Slot), FParams[SlotDestIndex(Slot)]);
  Result := (Src > 0) and (Dst > 0) and IsNoteSource(Src) and (FPndIdx[TGranularParamId(Dst - 1)] < 0);
end;

function TGranularEngine.VoiceValue(V: Integer; Id: TGranularParamId): Double;
begin
  if (V >= 0) and (V < MAX_VOICES) and FVModOn[V] and (FPndIdx[Id] >= 0) then
    Result := FVPlain[V, FPndIdx[Id]]
  else
    Result := Eff(Id);
end;

function TGranularEngine.VoiceOfNote(Note: Integer): Integer;
var
  V: Integer;
begin
  Result := -1;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage <> esIdle) and (FVoices[V].Note = Note) then
      Exit(V);
end;

{ LFO 1..4 laufen immer; LFO 5..8 nur, wenn eine Matrix-Zeile oder das Schwellen-Tor sie als Quelle hat
  oder ein benutzter LFO auf ihr Ende wartet (Start/Stopp 'Ende Partner-LFO'). Nebenbei: wird die
  Tonhoehe von Sidechain 2 gebraucht? }
procedure TGranularEngine.UpdateLfoUsed;
var
  K, J, Slot, Src: Integer;
  Changed: Boolean;
begin
  for K := 0 to LFO_COUNT - 1 do
    FLfoUsed[K] := K < 4;
  FScPitch2Used := False;
  for Slot := 0 to MOD_SLOTS - 1 do
  begin
    Src := ParamStep(SlotSourceIndex(Slot), FParams[SlotSourceIndex(Slot)]);
    if (Src > 0) and (ParamStep(SlotDestIndex(Slot), FParams[SlotDestIndex(Slot)]) > 0) then
    begin
      if Src = Ord(msScPitch2) then
        FScPitch2Used := True;
      K := LfoOfSource(Src);
      if K >= 0 then
        FLfoUsed[K] := True;
    end;
  end;
  K := LfoOfSource(ParamStep(Ord(gpGateSrc), FParams[Ord(gpGateSrc)]));
  if K >= 0 then
    FLfoUsed[K] := True;
  repeat
    Changed := False;
    for K := 0 to LFO_COUNT - 1 do
      if FLfoUsed[K] and ((ParamStep(Ord(LFO_TRIG_IDS[K]), FParams[Ord(LFO_TRIG_IDS[K])]) = LFO_TRIG_OTHER_END) or
         (ParamStep(Ord(LFO_STOP_IDS[K]), FParams[Ord(LFO_STOP_IDS[K])]) = 3)) then
      begin
        J := EnsureRange(ParamStep(Ord(LFO_PARTNER_IDS[K]), FParams[Ord(LFO_PARTNER_IDS[K])]), 0, LFO_COUNT - 1);
        if not FLfoUsed[J] then
        begin
          FLfoUsed[J] := True;
          Changed := True;
        end;
      end;
  until not Changed;
end;

function TGranularEngine.LfoUsed(K: Integer): Boolean;
begin
  Result := (K >= 0) and (K < LFO_COUNT) and FLfoUsed[K];
end;

function TGranularEngine.IsNoteSource(Src: Integer): Boolean;
begin
  case TModSource(Src) of
    msVelocity, msNoteRandom, msNote, msAmpEnv, msFilterEnv, msOsc1Env, msOsc2Env, msOsc3Env: Result := True;
  else
    if LfoOfSource(Src) >= 0 then
      Result := Round(Eff(LFO_TRIG_IDS[LfoOfSource(Src)])) in [1..3]
    else
      Result := False;
  end;
end;

{ Polyphone Modulation: Noten-LFOs je Stimme weiterlaufen lassen und fuer jede klingende Stimme die
  Wirkwerte der Noten-Ziele berechnen = globaler Wirkwert + eigene Noten-Modulation. Globale Quellen
  (freie LFOs, Modrad, Sidechain ...) stecken schon im globalen Wirkwert und wirken so auf alle Noten. }
procedure TGranularEngine.UpdateVoiceModulation(N: Integer);

  { Rate des Noten-LFOs K in Stimme V: eigene Modulation (aus dem vorigen Subblock) oder global }
  function VoiceLfoHz(V, K: Integer; GlobalHz: Double): Double;
  var
    P: Double;
  begin
    // eigene Raten je Note gibt es fuer LFO 1..4 (PND_LFORATE..+3); LFO 5..8 laufen mit der globalen Rate
    if not FVModOn[V] or (K > 3) then
      Exit(GlobalHz);
    P := FVPlain[V, PND_LFORATE + K];
    if Eff(LFO_SYNC_IDS[K]) >= 0.5 then
      Result := (Eff(gpTempo) / 60) / LFO_DIV_BEATS[LfoDivisionIndex(PlainToParam(LFO_RATE_IDS[K], P))]
    else
      Result := P;
  end;

var
  V, K, Slot, Src, Dst, J, Shape: Integer;
  Hz: array[0..LFO_COUNT - 1] of Double;
  NoteLfo, Once: array[0..LFO_COUNT - 1] of Boolean;
  SlotSrc, SlotPnd: array[0..MOD_SLOTS - 1] of Integer;
  SlotAmt, SlotFac, SlotOfs: array[0..MOD_SLOTS - 1] of Double;
  ActSlot: array[0..MOD_SLOTS - 1] of Integer;   // benutzte Noten-Zeilen (je Stimme nur diese durchlaufen)
  NAct, A: Integer;
  Any: Boolean;
  Mod_: array[0..PND_COUNT - 1] of Double;
  GPlain: array[0..PND_COUNT - 1] of Single;    // globale Wirkwerte (Klartext), einmal je Block
  Touched: array[0..PND_COUNT - 1] of Boolean;  // Ziel hat eine Noten-Zeile in der Matrix
  Sv: Double;
begin
  // welche LFOs laufen je Note, mit welcher Rate
  for K := 0 to LFO_COUNT - 1 do
  begin
    NoteLfo[K] := Round(Eff(LFO_TRIG_IDS[K])) in [1..3];
    Once[K] := Eff(LFO_ONCE_IDS[K]) >= 0.5;
    if Eff(LFO_SYNC_IDS[K]) >= 0.5 then
      Hz[K] := (Eff(gpTempo) / 60) / LFO_DIV_BEATS[LfoDivisionIndex(FEff[Ord(LFO_RATE_IDS[K])])]
    else
      Hz[K] := Eff(LFO_RATE_IDS[K]);
  end;
  // Matrix-Zeilen "Noten-Quelle -> Noten-Ziel" sammeln
  Any := False;
  NAct := 0;
  for Slot := 0 to MOD_SLOTS - 1 do
  begin
    SlotPnd[Slot] := -1;
    Src := ParamStep(SlotSourceIndex(Slot), FParams[SlotSourceIndex(Slot)]);
    Dst := ParamStep(SlotDestIndex(Slot), FParams[SlotDestIndex(Slot)]);
    if (Src = 0) or (Dst = 0) or not IsNoteSource(Src) then
      Continue;
    J := FPndIdx[TGranularParamId(Dst - 1)];
    if J < 0 then
      Continue;
    SlotSrc[Slot] := Src;
    SlotPnd[Slot] := J;
    SlotAmt[Slot] := ParamToPlain(SlotAmountIndex(Slot), FParams[SlotAmountIndex(Slot)]) / 100;
    SlotFac[Slot] := MOD_FACTORS[ParamStep(SlotFactorIndex(Slot), FParams[SlotFactorIndex(Slot)])];
    SlotOfs[Slot] := ParamToPlain(SlotOffsetIndex(Slot), FParams[SlotOffsetIndex(Slot)]) / 100;
    ActSlot[NAct] := Slot;
    Inc(NAct);
    Any := True;
  end;
  if Any then
  begin
    for J := 0 to PND_COUNT - 1 do
    begin
      GPlain[J] := ParamToPlain(PND_IDS[J], FEff[Ord(PND_IDS[J])]);
      Touched[J] := False;
    end;
    for A := 0 to NAct - 1 do
      Touched[SlotPnd[ActSlot[A]]] := True;
  end;

  for V := 0 to MAX_VOICES - 1 do
  begin
    FVModOn[V] := False;
    if (FVoices[V].Stage = esIdle) and not OscSounding(V, False) then
      Continue;
    // Noten-LFOs dieser Stimme
    for K := 0 to LFO_COUNT - 1 do
      if NoteLfo[K] then
      begin
        // verzoegerter Aus-Trigger: nach Ablauf anhalten
        if FVLfoStopWait[V, K] > 0 then
        begin
          Dec(FVLfoStopWait[V, K], N);
          if FVLfoStopWait[V, K] <= 0 then
            StopVoiceLfo(V, K, 0);
        end;
        // verzoegerter Neustart: Wartezeit laeuft; still (Note an) bzw. weiterlaufend (Note aus)
        if FVLfoWait[V, K] > 0 then
        begin
          Dec(FVLfoWait[V, K], N);
          if FVLfoWait[V, K] <= 0 then
          begin
            FVLfoWait[V, K] := 0;
            FVLfoMute[V, K] := False;
            FVLfoPh[V, K] := 0;
            FVLfoHold[V, K] := 2 * Rand - 1;
            FVLfoDone[V, K] := False;
            Continue;                      // startet mit dem naechsten Block bei Phase 0
          end;
          if FVLfoMute[V, K] then
            Continue;
        end;
        if FVLfoMute[V, K] then
          Continue;                        // vom Aus-Trigger angehalten
        if not Once[K] then
          FVLfoDone[V, K] := False;
        if not FVLfoDone[V, K] then
          FVLfoPh[V, K] := FVLfoPh[V, K] + VoiceLfoHz(V, K, Hz[K]) * N / FSampleRate;
        if Once[K] and (FVLfoPh[V, K] >= 1) then
        begin
          FVLfoPh[V, K] := 0.999999;
          FVLfoDone[V, K] := True;
        end
        else if FVLfoPh[V, K] >= 1 then
        begin
          FVLfoPh[V, K] := FVLfoPh[V, K] - Floor(FVLfoPh[V, K]);
          FVLfoHold[V, K] := 2 * Rand - 1;
        end;
      end;
    if not Any then
      Continue;
    for J := 0 to PND_COUNT - 1 do
      Mod_[J] := 0;
    for A := 0 to NAct - 1 do
    begin
      Slot := ActSlot[A];
      case TModSource(SlotSrc[Slot]) of
        msVelocity:   Sv := FVoices[V].Velocity;
        msNoteRandom: Sv := FVRnd[V];
        msNote:       Sv := EnsureRange(FVoices[V].Note / 127, 0, 1);
        msAmpEnv:     Sv := FVoices[V].Env;
        msOsc1Env:    Sv := FOsc[0, V].Env;
        msOsc2Env:    Sv := FOsc[1, V].Env;
        msOsc3Env:    Sv := FOsc[2, V].Env;
        msFilterEnv:  Sv := FVFltEnv[V];
        msLfo1, msLfo2, msLfo3, msLfo4, msLfo5, msLfo6, msLfo7, msLfo8:
          begin
            K := LfoOfSource(SlotSrc[Slot]);
            Shape := Round(Eff(LFO_SHAPE_IDS[K]));
            if FVLfoMute[V, K] then
              Sv := 0                        // Note an verzoegert: noch keine Modulation
            else if Shape = LFO_SHAPE_FREE then
              Sv := FreeLfoValue(FFree[LFO_FREE_IDX[K]], FVLfoPh[V, K])
            else
              Sv := LfoShapeValue(Shape, FVLfoPh[V, K], FVLfoHold[V, K]);
          end;
      else
        Sv := 0;
      end;
      Mod_[SlotPnd[Slot]] := Mod_[SlotPnd[Slot]] + SlotAmt[Slot] * (Sv * SlotFac[Slot] + SlotOfs[Slot]);
    end;
    // Wirkwerte dieser Stimme (Klartext): global + eigene Modulation
    for J := 0 to PND_COUNT - 1 do
      if Touched[J] then
        FVPlain[V, J] := ParamToPlain(PND_IDS[J], EnsureRange(FEff[Ord(PND_IDS[J])] + Mod_[J], 0, 1))
      else
        FVPlain[V, J] := GPlain[J];
    FVModOn[V] := True;
  end;
end;

procedure TGranularEngine.UpdateBlockParams;
var
  A, B, T, SizeMs, Density: Double;
  Last, K: Integer;
begin
  Last := FSample.Frames - 1;
  A := Eff(gpSelStart) / 100;
  B := Eff(gpSelEnd) / 100;
  if B < A then
  begin
    T := A; A := B; B := T;
  end;
  if FResCur >= 0 then
  begin
    A := 0;       // Resampling-Puffer enthaelt schon genau die Auswahl
    B := 1;
  end;
  FSel0 := A * Last;
  FSelLen := Max((B - A) * Last, 16.0);
  FSrRatio := FSample.SampleRate / FSampleRate;
  for K := 1 to ZONE_COUNT do
    if FZone[K] <> nil then
    begin
      FZoneSel0[K] := A * (FZone[K].Frames - 1);
      FZoneSelLen[K] := Max((B - A) * (FZone[K].Frames - 1), 16.0);
      FZoneSr[K] := FZone[K].SampleRate / FSampleRate;
    end;
  if FSampleB <> nil then
  begin
    FSel0B := A * (FSampleB.Frames - 1);
    FSelLenB := Max((B - A) * (FSampleB.Frames - 1), 16.0);
    FSrRatioB := FSampleB.SampleRate / FSampleRate;
  end;

  // Anlauf: Start vor der Auswahl in Auswahl-Einheiten (Auswahl = 0..1); sonst 0 = aus
  FPreOfs := 0;
  if FParams[Ord(gpPreOn)] >= 0.5 then
  begin
    T := Eff(gpPreStart) / 100;
    if T < A then
      FPreOfs := (T - A) * Last / FSelLen;
  end;
  FPingPong := FParams[Ord(gpLoopMode)] >= 0.5;
  FPosition := Eff(gpPosition) / 100;
  FSpray := Eff(gpSpray) / 100;
  FScanInc := Eff(gpScan) * FSrRatio / FSelLen;
  FFreeze := Eff(gpFreeze) >= 0.5;
  if FFreeze then
    FScanInc := 0;   // Halten: die Abspielposition steht
  FScale := EnsureRange(Round(Eff(gpScale)), 0, 8);
  FScaleRoot := EnsureRange(Round(Eff(gpScaleRoot)), 0, 11);

  SizeMs := Eff(gpGrainSize);
  Density := Eff(gpDensity);
  FGrainLen := Max(16, Round(SizeMs * FSampleRate / 1000));
  FInterval := FSampleRate / Density;
  // Lautheitsausgleich bei vielen ueberlappenden Grains
  FNorm := 1 / Sqrt(Max(1.0, Density * SizeMs / 1000));

  FPitch := Eff(gpPitch);
  FPitchRand := Eff(gpPitchRand);
  FSpread := Eff(gpSpread) / 100;
  FReverse := Eff(gpReverse) / 100;
  FWindowShape := EnsureRange(Round(Eff(gpWindow)), 0, 3);

  FAttInc := 1 / Max(1.0, Eff(gpAttack) * FSampleRate / 1000);
  FDecCoef := Exp(Ln(0.001) / Max(1.0, Eff(gpDecay) * FSampleRate / 1000));
  FSustain := Eff(gpSustain) / 100;
  FRelCoef := Exp(Ln(0.0001) / Max(1.0, Eff(gpRelease) * FSampleRate / 1000));  // auf -80 dB
  FGain := DecibelToGain(Eff(gpVolume)) * DecibelToGain(Eff(gpMaster));
  FKeyTrack := Eff(gpKeyTrack) >= 0.5;
  FGrainOn := Eff(gpGrainOn) >= 0.5;
  FGrainPan := Eff(gpGrainPan) / 100;
  FGrainOct := (Round(Eff(gpGrainOct)) - 4) * 12;
  FAutoTune := Eff(gpAutoTune) >= 0.5;
  FBendRange := Eff(gpBendRange);
  FHQ := (Eff(gpQuality) >= 0.5) or (FOffline and (FParams[Ord(gpRenderHQ)] >= 0.5));
  FOsOn := FHQ and (FParams[Ord(gpOversample)] >= 0.5);
  FAutoPitch := Round(Eff(gpScPitchMode));
end;

{ --- Klang B ('Zwei Klänge'): ganzer Block am Stueck, danach von A dazugemischt --- }

procedure TGranularEngine.RenderLayerCall(InL, InR, In2L, In2R: PSingle; Frames: Integer; Events: PNoteEvent;
  EventCount: Integer; Audible: Boolean; Out: PSingle);
var
  Done, N, EvIdx: Integer;
  SubInL, SubInR, Sc2L, Sc2R: PSingle;
  E: PNoteEvent;
begin
  EvIdx := 0;
  Done := 0;
  E := Events;
  while Done < Frames do
  begin
    N := Min(SUB_BLOCK, Frames - Done);
    while (EvIdx < EventCount) and (E.DeltaFrames < Done + N) do
    begin
      ApplyEvent(E^);
      Inc(E);
      Inc(EvIdx);
    end;
    SubInL := nil; SubInR := nil; Sc2L := nil; Sc2R := nil;
    if InL <> nil then
    begin
      SubInL := InL + Done;
      SubInR := InR + Done;
    end;
    if In2L <> nil then
    begin
      Sc2L := In2L + Done;
      if In2R <> nil then
        Sc2R := In2R + Done;
    end;
    RenderSub(SubInL, SubInR, Sc2L, Sc2R, N, Audible);
    Move(FMix[0], (Out + Done * 2)^, N * 2 * SizeOf(Single));
    Inc(Done, N);
  end;
  while EvIdx < EventCount do
  begin
    ApplyEvent(E^);
    Inc(E);
    Inc(EvIdx);
  end;
end;

{ --- Audio --- }

procedure TGranularEngine.SpawnGrain(V, Offset: Integer);
var
  I, Slot, VLen: Integer;
  P, Semis, Pan, Ang, Amp: Double;
  VPos, VSpray, VPitch, VPRand, VSpread, VGPan, VRev, VVol, VNorm: Double;
  GLen: Integer;
begin
  // Leistungsstufe: hoechstens so viele Grains gleichzeitig
  if FActiveGrains >= PERF_GRAINS[PerfLevel] then
    Exit;
  Slot := GrainAlloc;
  if Slot < 0 then
    Exit;  // Pool voll - Grain verwerfen

  // Werte dieser Stimme: global, oder mit eigener (polyphoner) Noten-Modulation
  if FVModOn[V] then
  begin
    VPos := FVPlain[V, PND_POS] / 100;  VSpray := FVPlain[V, PND_SPRAY] / 100;
    VPitch := FVPlain[V, PND_PITCH];    VPRand := FVPlain[V, PND_PRAND];
    VSpread := FVPlain[V, PND_SPREAD] / 100;  VGPan := FVPlain[V, PND_GPAN] / 100;
    VRev := FVPlain[V, PND_REV] / 100;
    VVol := DecibelToGain(FVPlain[V, PND_VOL] - Eff(gpVolume));   // relativ zur globalen Lautstaerke
    VLen := Max(16, Round(FVPlain[V, PND_SIZE] * FSampleRate / 1000));
    VNorm := 1 / Sqrt(Max(1.0, FVPlain[V, PND_DENS] * FVPlain[V, PND_SIZE] / 1000));
  end
  else
  begin
    VPos := FPosition; VSpray := FSpray; VPitch := FPitch; VPRand := FPitchRand;
    VSpread := FSpread; VGPan := FGrainPan; VRev := FReverse; VVol := 1;
    VLen := FGrainLen; VNorm := FNorm;
  end;

  P := FVoices[V].ScanPos + VPos + VSpray * (2 * Rand - 1);
  if FVoices[V].InPre then
  begin
    // im Anlauf kein Umlauf: Grains bleiben zwischen Anlauf-Start und Auswahlende
    if P < FPreOfs then P := FPreOfs;
    if P >= 1 then P := P - Floor(P);
  end
  else
    P := P - Floor(P);

  Semis := VPitch + FGrainOct + VPRand * (2 * Rand - 1) + FBend * FBendRange;
  if (FAutoPitch > 0) and FScInput then
  begin
    // Auto-Pitch: Tonhoehe kommt vom Sidechain statt von der Taste
    if FAutoPitch = 2 then
      Semis := Semis + Round(FPitchTrk.Note) - ROOT_NOTE
    else
      Semis := Semis + FPitchTrk.Note - ROOT_NOTE;
  end
  else if FKeyTrack then
    Semis := Semis + (FVoices[V].Note - ROOT_NOTE) + FGlideOfs[V];
  // Tonleiter-Raster: auf den naechsten Ton der Tonleiter ziehen
  if FScale > 0 then
    Semis := ScaleSnap(Semis);

  Pan := VSpread * (2 * Rand - 1);
  // Grain-Panorama verschiebt die ganze Wolke (Streuung bleibt um die neue Mitte)
  Pan := EnsureRange(Pan + VGPan, -1, 1);
  Ang := (Pan + 1) * Pi / 4;
  Amp := FVoices[V].Velocity * VNorm * Sqrt(2.0) * VVol;   // Lautstaerke wirkt danach auf die Summe (ApplyGain)

  with FGrains[Slot] do
  begin
    Active := True;
    Voice := V;
    Delay := Offset;
    GLen := VLen;
    Remaining := GLen;
    // Grain-Ueberblendung: Anteil = Morph-Stellung kommt aus dem Sample von Ziel B
    UseB := FMorphValid and not FLayerOn and (FSampleB <> nil) and (Rand < EnsureRange(FEff[Ord(gpMorph)], 0, 1));
    if UseB then Zone := 0 else Zone := ZoneOfNote(FVoices[V].Note);
    Src := FSample;
    // Auto-Stimmung (nur mit Key Tracking): je Quelle die eigene Korrektur -> beim Morphen kein Gleiten
    if FAutoTune and FKeyTrack and not ((FAutoPitch > 0) and FScInput) then
      if UseB then Semis := Semis + FTuneB
      else if Zone > 0 then Semis := Semis + FZoneTune[Zone]
      else Semis := Semis + FTuneA;
    // Resampling-Puffer: seine Aufnahme-Tonlage abziehen -> keine Tonhoehen-Drift von Durchlauf zu Durchlauf
    if (FResCur >= 0) and not UseB and (Zone = 0) then
      Semis := Semis - FResOfs;
    if Zone > 0 then
    begin
      Args.PosFix := Round((FZoneSel0[Zone] + P * FZoneSelLen[Zone]) * FIX_ONE);
      Args.IncFix := Round(Power(2, Semis / 12) * FZoneSr[Zone] * FIX_ONE);
    end
    else if UseB then
    begin
      Args.PosFix := Round((FSel0B + P * FSelLenB) * FIX_ONE);
      Args.IncFix := Round(Power(2, Semis / 12) * FSrRatioB * FIX_ONE);
    end
    else
    begin
      Args.PosFix := Round((FSel0 + P * FSelLen) * FIX_ONE);
      Args.IncFix := Round(Power(2, Semis / 12) * FSrRatio * FIX_ONE);
    end;
    if Rand < VRev then
      Args.IncFix := -Args.IncFix;
    Args.WinPos := 0;
    // abrunden: letzter Index bleibt sicher < WINDOW_TABLE_SIZE
    Args.WinInc := Cardinal((Int64(WINDOW_TABLE_SIZE) shl WIN_FIX_SHIFT) div GLen);
    Args.Win := @FWindows[FWindowShape, 0];
    Args.GainL := Amp * Cos(Ang);
    Args.GainR := Amp * Sin(Ang);
  end;
  // (FActiveGrains zaehlt GrainAlloc)

  FHistory[FHistoryPos] := (FSel0 + P * FSelLen) / FSample.Frames;
  FHistoryPos := (FHistoryPos + 1) mod GRAIN_HISTORY;
end;

procedure TGranularEngine.RunVoices(N: Integer);
var
  V, I: Integer;
  AttInc, DecCoef, Sus, RelCoef, ScanInc: Double;
  LEnv: Single;
  LStage: TEnvStage;
  LTime: Integer;
  LScan, LNext: Double;
  LDir: Integer;
  LPre: Boolean;
begin
  // Portamento: Versatz linear (in Halbtoenen) zur Zieltonhoehe, feste Dauer je Gleitvorgang
  for V := 0 to MAX_VOICES - 1 do
    if FGlideOfs[V] <> 0 then
      if Abs(FGlideOfs[V]) <= FGlideStep[V] * N then
        FGlideOfs[V] := 0
      else if FGlideOfs[V] > 0 then
        FGlideOfs[V] := FGlideOfs[V] - FGlideStep[V] * N
      else
        FGlideOfs[V] := FGlideOfs[V] + FGlideStep[V] * N;
  for V := 0 to MAX_VOICES - 1 do
    with FVoices[V] do
    begin
      if Stage = esIdle then
        Continue;
      // Huellkurve und Scan dieser Note (eigene Noten-Modulation) oder global
      if FVModOn[V] then
      begin
        AttInc := 1 / Max(1.0, FVPlain[V, PND_AATT] * FSampleRate / 1000);
        DecCoef := Exp(Ln(0.001) / Max(1.0, FVPlain[V, PND_ADEC] * FSampleRate / 1000));
        Sus := FVPlain[V, PND_ASUS] / 100;
        RelCoef := Exp(Ln(0.0001) / Max(1.0, FVPlain[V, PND_AREL] * FSampleRate / 1000));
        if FFreeze then
          ScanInc := 0
        else
          ScanInc := FVPlain[V, PND_SCAN] * FSrRatio / FSelLen;
      end
      else
      begin
        AttInc := FAttInc; DecCoef := FDecCoef; Sus := FSustain; RelCoef := FRelCoef; ScanInc := FScanInc;
      end;
      // Zustand dieser Stimme lokal (gleiche Typen wie im Datensatz -> bitgleich), nur fuer neue Grains
      // und am Ende zurueckschreiben: spart Feldzugriffe je Sample
      LEnv := Env; LStage := Stage; LTime := StageTime; LScan := ScanPos; LNext := NextGrain;
      LDir := ScanDir; LPre := InPre;
      for I := 0 to N - 1 do
      begin
        Inc(LTime);
        case LStage of
          esAttack:
            begin
              LEnv := LEnv + AttInc;
              if LEnv >= 1 then
              begin
                LEnv := 1;
                LStage := esDecay;
                LTime := 0;
              end;
            end;
          esDecay:
            begin
              LEnv := Sus + (LEnv - Sus) * DecCoef;
              if Abs(LEnv - Sus) < 0.001 then
              begin
                LStage := esSustain;
                LTime := 0;
              end;
            end;
          esSustain:
            LEnv := LEnv + (Sus - LEnv) * 0.002;  // folgt Sustain-Aenderungen weich
          esRelease:
            begin
              LEnv := LEnv * RelCoef;
              if LEnv < 0.0001 then
              begin
                LEnv := 0;
                LStage := esIdle;
              end;
            end;
          esIdle:
            LEnv := 0;
        end;
        FEnvBuf[V, I] := LEnv;
        if LStage <> esIdle then
        begin
          if LPre then
          begin
            // Anlauf: einmal vorwaerts bis in die Auswahl, dann normal weiter
            LScan := LScan + Abs(ScanInc);
            if LScan >= 0 then
              LPre := False;
          end
          else if FPingPong then
          begin
            LScan := LScan + ScanInc * LDir;
            if LScan >= 1 then
            begin
              LScan := Max(0.0, 2 - LScan);
              LDir := -LDir;
            end
            else if LScan < 0 then
            begin
              LScan := Min(0.9999999, -LScan);
              LDir := -LDir;
            end;
          end
          else
          begin
            LScan := LScan + ScanInc;
            if (LScan >= 1) or (LScan < 0) then
              LScan := LScan - Floor(LScan);
          end;
          LNext := LNext - 1;
          if LNext <= 0 then
          begin
            if FGrainOn then
            begin
              ScanPos := LScan;                   // SpawnGrain liest die Scan-Position der Stimme
              InPre := LPre;
              SpawnGrain(V, I);           // Grains aus: nur der Oszillator klingt
            end;
            // leichter Jitter verhindert kammfilterartige Regelmaessigkeit
            if FVModOn[V] then
              LNext := LNext + FSampleRate / Max(0.1, FVPlain[V, PND_DENS]) * (0.85 + 0.3 * Rand)
            else
              LNext := LNext + FInterval * (0.85 + 0.3 * Rand);
          end;
        end;
      end;
      Env := LEnv; Stage := LStage; StageTime := LTime; ScanPos := LScan; NextGrain := LNext;
      ScanDir := LDir; InPre := LPre;
    end;
end;

procedure TGranularEngine.RenderGrains(N: Integer);
var
  K, Start, Cnt, Pad, V: Integer;
  SrcA, SrcB: PSingle;
  SrcLast, SrcLastB: Integer;
begin
  FillChar(FMix, N * 2 * SizeOf(Single), 0);
  // je Stimme ein eigener Puffer (Klangprozessor je Note); nur benutzte werden geleert
  for V := 0 to MAX_VOICES - 1 do
  begin
    if FVHasSig[V] then
      FillChar(FVBuf[V], N * 2 * SizeOf(Single), 0);
    FVHasSig[V] := False;
  end;
  // HQ (Hermite) braucht einen Frame mehr Vorlauf/Nachlauf als linear
  if FHQ then Pad := 3 else Pad := 2;
  SrcA := @FSample.LR[0];
  SrcLast := FSample.Frames - Pad;
  SrcB := nil;
  SrcLastB := 0;
  if FSampleB <> nil then
  begin
    SrcB := @FSampleB.LR[0];
    SrcLastB := FSampleB.Frames - Pad;
  end;
  // nur die aktiven Grains (rueckwaerts, weil GrainFree den letzten Listeneintrag nach vorn zieht)
  for K := FActiveGrains - 1 downto 0 do
    with FGrains[FActList[K]] do
    begin
      Start := Delay;
      Delay := 0;
      Cnt := Min(N - Start, Remaining);
      if Cnt > 0 then
      begin
        if (Zone > 0) and (FZone[Zone] <> nil) then
        begin
          Args.Src := @FZone[Zone].LR[0];
          Args.SrcLast := FZone[Zone].Frames - Pad;
        end
        else if UseB and (SrcB <> nil) then
        begin
          Args.Src := SrcB;
          Args.SrcLast := SrcLastB;
        end
        else if (Src <> nil) and (Src <> FSample) then
        begin
          Args.Src := @Src.LR[0];
          Args.SrcLast := Src.Frames - Pad;
        end
        else
        begin
          Args.Src := SrcA;
          Args.SrcLast := SrcLast;
        end;
        Args.Env := @FEnvBuf[Voice, Start];
        if not FVHasSig[Voice] then
        begin
          FillChar(FVBuf[Voice], N * 2 * SizeOf(Single), 0);
          FVHasSig[Voice] := True;
        end;
        Args.Out := @FVBuf[Voice, Start * 2];
        Args.Count := Cnt;
        if FHQ then
          RenderGrainHQ(@Args)
        else
          RenderGrain(@Args);
        Dec(Remaining, Cnt);
      end;
      if (Remaining <= 0) or (FVoices[Voice].Stage = esIdle) then
        GrainFree(FActList[K]);
    end;
  // Huellkurve der Stimme einmal auf die Summe ihrer Grains (frueher je Grain und Sample im Kern -
  // dieselbe Rechnung, nur in anderer Reihenfolge; spart je Grain-Sample einen Speicherzugriff)
  for V := 0 to MAX_VOICES - 1 do
    if FVHasSig[V] then
      for K := 0 to N - 1 do
      begin
        FVBuf[V, K * 2] := FVBuf[V, K * 2] * FEnvBuf[V, K];
        FVBuf[V, K * 2 + 1] := FVBuf[V, K * 2 + 1] * FEnvBuf[V, K];
      end;
end;

procedure TGranularEngine.WriteScope(InL, OutL, OutR: PSingle; N: Integer);
var
  I, P: Integer;
begin
  P := FScopePos;
  FOutPeak := FOutPeak * 0.97;
  for I := 0 to N - 1 do
  begin
    if Abs(OutL[I]) > FOutPeak then FOutPeak := Abs(OutL[I]);
    FScopeOut[P] := (OutL[I] + OutR[I]) * 0.5;
    if InL <> nil then
      FScopeIn[P] := InL[I]
    else
      FScopeIn[P] := 0;
    P := (P + 1) and (SCOPE_SIZE - 1);
  end;
  FScopePos := P;
end;

procedure TGranularEngine.GetScope(var OutBuf, InBuf: array of Single; Count: Integer);
var
  I, P: Integer;
begin
  Count := Min(Count, Min(Length(OutBuf), SCOPE_SIZE));
  P := (FScopePos - Count) and (SCOPE_SIZE - 1);
  for I := 0 to Count - 1 do
  begin
    OutBuf[I] := FScopeOut[P];
    InBuf[I] := FScopeIn[P];
    P := (P + 1) and (SCOPE_SIZE - 1);
  end;
end;

procedure TGranularEngine.GetScopePreEq(var Buf: array of Single; Count: Integer);
var
  I, P: Integer;
begin
  Count := Min(Count, Min(Length(Buf), SCOPE_SIZE));
  P := (FScopePrePos - Count) and (SCOPE_SIZE - 1);
  for I := 0 to Count - 1 do
  begin
    Buf[I] := FScopePre[P];
    P := (P + 1) and (SCOPE_SIZE - 1);
  end;
end;

procedure TGranularEngine.RenderSub(SubInL, SubInR, Sc2L, Sc2R: PSingle; N: Integer; Audible: Boolean);
var
  I: Integer;
  T: Int64;
begin
  if GSectProfOn then T := TStopwatch.GetTimeStamp;
  ArpTick(N);
  // zweiter Sidechain-Eingang: Huellkurvenfolger mit denselben Zeiten -> Quelle "Sidechain 2"
  if Sc2L <> nil then
  begin
    FollowSc2(Sc2L, IfThen(Sc2R <> nil, NativeInt(Sc2R), NativeInt(Sc2L)), N);
    // Tonhoehe von Sidechain 2: nur wenn eine Matrix-Zeile sie nutzt (YIN kostet Rechenzeit)
    if FScPitch2Used then
    begin
      if Sc2R <> nil then
        FPitchTrk2.Process(Sc2L, Sc2R, N)
      else
        FPitchTrk2.Process(Sc2L, Sc2L, N);
      FSource[msScPitch2] := EnsureRange(FPitchTrk2.Note / 127, 0, 1);
    end;
  end
  else
    FSource[msSidechain2] := FSource[msSidechain2] * 0.9;
  if GSectProfOn then SectMark(8, T);
  UpdateModulation(SubInL, SubInR, N);
  if GSectProfOn then SectMark(9, T);
  UpdateFilterEnv(N);
  if GSectProfOn then SectMark(10, T);
  if FSample = nil then
  begin
    FillChar(FMix[0], N * 2 * SizeOf(Single), 0);
    Exit;
  end;
  UpdateBlockParams;
  if GSectProfOn then SectMark(11, T);
  RunVoices(N);
  if GSectProfOn then SectMark(1, T);
  if not Audible then
  begin
    // ganz weggeblendet: Stimmen, Arp und LFOs laufen weiter, aber keine Grains/Effekte (spart CPU)
    ResetGrains;
    FillChar(FMix[0], N * 2 * SizeOf(Single), 0);
    Exit;
  end;
  RenderGrains(N);
  if GSectProfOn then SectMark(2, T);
  ApplyGrainLevel(N);  // nur die Grains (die Oszillatoren kommen erst danach in dieselben Puffer)
  if GSectProfOn then SectMark(20, T);
  if FMeterOn then
    for I := 0 to MAX_VOICES - 1 do
      if FVHasSig[I] then
        MeterPeak(MM_GRAINS, @FVBuf[I, 0], N * 2);
  if GSectProfOn then SectMark(7, T);
  RenderOsc(N);       // Oszillator-Schicht in denselben Kanal (danach Lautstaerke und Effekte)
  if GSectProfOn then SectMark(3, T);
  ProcessVoiceFilters(N);   // je Note: Filter 1/2 mit eigener Huellkurve, dann in die Summe
  if GSectProfOn then SectMark(4, T);
  ApplyGain(N);       // Lautstaerke auf die Summe (wirkt sofort, auch fuer laufende Grains)
  if GSectProfOn then SectMark(21, T);
  // Oszillator mit eigenem Filter (schon je Note gefiltert): an den Hauptfiltern vorbei dazu
  if FOscOwnFlt then
    for I := 0 to N * 2 - 1 do
      FMix[I] := FMix[I] + FOscMix[I] * FGainPrev;
  if FMeterOn then
  begin
    MeterPeak(MM_SUM, @FMix[0], N * 2);
    Move(FMix[0], FMeterTmp[0], N * 2 * SizeOf(Single));
  end;
  // Summen-Effekte; mit Pegelanzeige (Mischpult offen): je Effekt, was er am Klang veraendert
  ProcessTranceGate(N);   // Gate auf den trockenen Klang: Echo und Hall klingen frei aus
  if FMeterOn then FxMeter(MM_GATE, N);
  ProcessCrush(N);
  if FMeterOn then FxMeter(MM_CRUSH, N);
  ProcessChorus(N);
  if FMeterOn then FxMeter(MM_CHO, N);
  ProcessPhaser(N);
  if FMeterOn then FxMeter(MM_PHA, N);
  if GSectProfOn then SectMark(26, T);
  if GSectProfOn then SectMark(7, T);
  ProcessEcho(N);
  if GSectProfOn then SectMark(5, T);
  if FMeterOn then
  begin
    MeterDiff(MM_ECHO, @FMix[0], N * 2);     // was das Echo hinzufuegt
    Move(FMix[0], FMeterTmp[0], N * 2 * SizeOf(Single));
  end;
  if GSectProfOn then SectMark(7, T);
  ProcessReverb(N);   // Hall nach dem Echo: Echos verschwimmen im Raum
  if GSectProfOn then SectMark(6, T);
  if FMeterOn then
    MeterDiff(MM_HALL, @FMix[0], N * 2);
  ProcessDrive(N);
  if GSectProfOn then SectMark(22, T);
  ProcessEq(N);       // Equalizer vor dem Limiter
  if GSectProfOn then SectMark(23, T);
  ProcessStereo(N);   // Breite + Panorama der Summe
  if GSectProfOn then SectMark(24, T);
  ProcessLimiter(N);
  if GSectProfOn then SectMark(25, T);
  if FMeterOn then
    MeterPeak(MM_OUT, @FMix[0], N * 2);
  if GSectProfOn then SectMark(7, T);
end;

{ Pegel 'was der Effekt veraendert' und Bezug fuer den naechsten Effekt nachziehen }
procedure TGranularEngine.FxMeter(Ch, N: Integer);
begin
  MeterDiff(Ch, @FMix[0], N * 2);
  Move(FMix[0], FMeterTmp[0], N * 2 * SizeOf(Single));
end;

procedure TGranularEngine.MeterPeak(Ch: Integer; P: PSingle; Count: Integer);
var
  I: Integer;
  M: Single;
begin
  M := FMeter[Ch];
  for I := 0 to Count - 1 do
  begin
    if Abs(P^) > M then M := Abs(P^);
    Inc(P);
  end;
  FMeter[Ch] := M;
end;

{ Spitze der Aenderung gegenueber FMeterTmp (vor dem Effekt) = Anteil des Effekts }
procedure TGranularEngine.MeterDiff(Ch: Integer; P: PSingle; Count: Integer);
var
  I: Integer;
  M, D: Single;
begin
  M := FMeter[Ch];
  for I := 0 to Count - 1 do
  begin
    D := Abs(P^ - FMeterTmp[I]);
    if D > M then M := D;
    Inc(P);
  end;
  FMeter[Ch] := M;
end;

function TGranularEngine.TakeMeter(Ch: Integer): Single;
begin
  Result := 0;
  if (Ch >= 0) and (Ch < MIX_METERS) then
  begin
    Result := FMeter[Ch];
    FMeter[Ch] := 0;
  end;
end;

procedure TGranularEngine.Process(InL, InR, OutL, OutR: PSingle; Frames: Integer; In2L: PSingle; In2R: PSingle);
var
  Done, N, EvIdx, F: Integer;
  SubInL, SubInR, Sc2L, Sc2R: PSingle;
  Mo, GA, GB, T, A, B: Single;
  Smp: TSampleData;
  LayerNow, AudB: Boolean;
  K, NSub: Integer;
begin
  if Frames <= 0 then
    Exit;
  FillChar(OutL^, Frames * SizeOf(Single), 0);
  FillChar(OutR^, Frames * SizeOf(Single), 0);
  if InR = nil then
    InR := InL;

  FLock.Enter;
  try
    // Events aus der Warteschlange uebernehmen (kurzer Lock)
    FEventLock.Enter;
    try
      FEventCount := FPendingCount;
      if FEventCount > 0 then
        Move(FPending[0], FEvents[0], FEventCount * SizeOf(TNoteEvent));
      FPendingCount := 0;
    finally
      FEventLock.Leave;
    end;

    if FRecOn and (InL <> nil) then
      for F := 0 to Frames - 1 do
      begin
        if FRecPos >= FRecLen then
        begin
          FRecOn := False;               // Puffer voll: Aufnahme endet von selbst
          Break;
        end;
        FRecBuf[FRecPos * 2] := InL[F];
        FRecBuf[FRecPos * 2 + 1] := InR[F];
        Inc(FRecPos);
      end;
    // Stille: keine Noten/Ereignisse, nichts aktiv, kein Eingangssignal und der Ausklang (Hall, Echo)
    // liegt schon 0,2 s unter -100 dB -> Block ueberspringen (Ausgang bleibt 0). Kein Qualitaetsverlust:
    // hoerbar waere nichts; LFOs bleiben stehen und laufen beim naechsten Ton weiter.
    if (FEventCount = 0) and (FIdleSamples >= FSampleRate * 0.2) and EngineIdle and
       (not FLayerOn or FLayerB.EngineIdle) and InputSilent(InL, InR, Frames) and
       InputSilent(In2L, In2R, Frames) then
    begin
      FOutPeak := 0;
      Inc(FIdleSkips);
      Exit;                                       // finally gibt den Lock frei
    end;

    // zweiter Klang B (Morph-Art 'Zwei Klaenge'): bekommt dieselben Noten, eigenes Sample (B oder A)
    LayerNow := LayerMode;
    if LayerNow and not FLayerOn then
    begin
      FLayerB.ResetAll;
      FGainA := 1;
      FGainB := 0;
    end;
    FLayerOn := LayerNow;
    if FLayerOn then
    begin
      if FLayerB.FSampleRate <> FSampleRate then
        FLayerB.SetSampleRate(FSampleRate);
      Smp := FSampleB;
      if Smp = nil then
        Smp := FSample;
      if FLayerB.FSample <> Smp then
      begin
        FLayerB.ResetAll;          // laufende Grains zeigen ins alte Sample
        FLayerB.FSample := Smp;
      end;
      if FSampleB <> nil then
      begin
        FLayerB.FRootA := FRootB;
        FLayerB.FTuneA := FTuneB;
      end
      else
      begin
        FLayerB.FRootA := FRootA;
        FLayerB.FTuneA := FTuneA;
      end;
      FLayerB.FParams[Ord(gpTempo)] := FParams[Ord(gpTempo)];
      FLayerB.FParams[Ord(gpMaster)] := FParams[Ord(gpMaster)];
      FLayerB.FParams[Ord(gpOversample)] := FParams[Ord(gpOversample)];
      FLayerB.FParams[Ord(gpOscModel)] := FParams[Ord(gpOscModel)];
      FLayerB.FParams[Ord(gpPerformance)] := FParams[Ord(gpPerformance)];
      FLayerB.FOutPeak := FOutPeak;
      // B rechnet den ganzen Block am Stueck (vorab); hoerbar, wenn B
      // gerade klingt, Morph nicht ganz auf A steht oder der Morph-LFO B einblenden kann
      AudB := (FGainB > 0.0005) or (EnsureRange(FEff[Ord(gpMorph)], 0, 1) > 0.0005) or
        (ParamStep(Ord(gpMorphLfoShape), FParams[Ord(gpMorphLfoShape)]) > 0);
      NSub := (Frames + SUB_BLOCK - 1) div SUB_BLOCK;
      if Length(FLayerBuf) < Frames * 2 then
        SetLength(FLayerBuf, Frames * 2);              // nur bei ungewoehnlich grossen Bloecken
      if Length(FGainBs) < NSub then
      begin
        SetLength(FGainBs, NSub);
        SetLength(FGainBe, NSub);
      end;
      FLayerB.RenderLayerCall(InL, InR, In2L, In2R, Frames, @FEvents[0], FEventCount, AudB, @FLayerBuf[0]);
    end
    else
    begin
      FGainA := 1;
      FGainB := 0;
    end;

    EvIdx := 0;
    Done := 0;
    while Done < Frames do
    begin
      N := Min(SUB_BLOCK, Frames - Done);
      while (EvIdx < FEventCount) and (FEvents[EvIdx].DeltaFrames < Done + N) do
      begin
        ApplyEvent(FEvents[EvIdx]);     // B wendet seine Events selbst an (RenderLayerCall)
        Inc(EvIdx);
      end;
      if InL <> nil then
      begin
        SubInL := InL + Done;
        SubInR := InR + Done;
      end
      else
      begin
        SubInL := nil;
        SubInR := nil;
      end;
      Sc2L := nil;
      Sc2R := nil;
      if In2L <> nil then
      begin
        Sc2L := In2L + Done;
        if In2R <> nil then
          Sc2R := In2R + Done;
      end;
      if FLayerOn then
      begin
        // Gewichte aus der Morph-Stellung des vorigen Subblocks (inkl. Morph-LFO), gleiche Leistung
        Mo := EnsureRange(FEff[Ord(gpMorph)], 0, 1);
        GA := Cos(Mo * Pi / 2);
        GB := Sin(Mo * Pi / 2);
        RenderSub(SubInL, SubInR, Sc2L, Sc2R, N, (GA > 0.0005) or (FGainA > 0.0005));
        for F := 0 to N - 1 do
        begin
          A := FGainA + (GA - FGainA) * (F + 1) / N;
          FMix[F * 2] := FMix[F * 2] * A;
          FMix[F * 2 + 1] := FMix[F * 2 + 1] * A;
        end;
        K := Done div SUB_BLOCK;
        FGainBs[K] := FGainB;         // B wird nach dem Warten mit derselben Rampe dazugemischt
        FGainBe[K] := GB;
        FGainA := GA;
        FGainB := GB;
      end
      else
        RenderSub(SubInL, SubInR, Sc2L, Sc2R, N, True);
      if (FSample <> nil) or FLayerOn then
        Deinterleave(@FMix[0], OutL + Done, OutR + Done, N);
      if not FLayerOn then
        WriteScope(SubInL, OutL + Done, OutR + Done, N);
      Inc(Done, N);
    end;
    while EvIdx < FEventCount do
    begin
      ApplyEvent(FEvents[EvIdx]);
      Inc(EvIdx);
    end;
    // Klang B mit der Morph-Rampe je Subblock dazumischen, dann Anzeige
    if FLayerOn then
    begin
      Done := 0;
      while Done < Frames do
      begin
        N := Min(SUB_BLOCK, Frames - Done);
        K := Done div SUB_BLOCK;
        for F := 0 to N - 1 do
        begin
          B := FGainBs[K] + (FGainBe[K] - FGainBs[K]) * (F + 1) / N;
          (OutL + Done + F)^ := (OutL + Done + F)^ + FLayerBuf[(Done + F) * 2] * B;
          (OutR + Done + F)^ := (OutR + Done + F)^ + FLayerBuf[(Done + F) * 2 + 1] * B;
        end;
        if InL <> nil then
          WriteScope(InL + Done, OutL + Done, OutR + Done, N)
        else
          WriteScope(nil, OutL + Done, OutR + Done, N);
        Inc(Done, N);
      end;
    end;
    // Resampling an, aber noch keine Puffer (z.B. per Automation bei geschlossenem Editor): Helfer wecken
    if (FParams[Ord(gpResOn)] >= 0.5) and (FResCap = 0) and not FResAsked and (FResWake <> nil) then
    begin
      FResAsked := True;
      FResWake.SetEvent;
    end;
    if not FLayerOn and (FSample <> nil) then
      ResTick(OutL, OutR, Frames)
    else if FResCur >= 0 then
      ResRestore;
    // Stille-Zaehler: nur wenn nichts aktiv ist und der ganze Block unter -100 dB liegt
    if (FEventCount = 0) and EngineIdle and (not FLayerOn or FLayerB.EngineIdle) and
       InputSilent(OutL, OutR, Frames) and InputSilent(InL, InR, Frames) then
      Inc(FIdleSamples, Frames)
    else
      FIdleSamples := 0;
  finally
    FLock.Leave;
  end;
end;

{ --- Effekte: Filter-Huellkurve, Filter, Echo --- }

procedure TGranularEngine.UpdateFilterEnv(N: Integer);
var
  V: Integer;
  Gate: Boolean;
  S: Double;
begin
  // Gate = mindestens eine Stimme gedrueckt (paraphon: eine Huellkurve fuer alle)
  Gate := False;
  for V := 0 to MAX_VOICES - 1 do
    if FVoices[V].Stage in [esAttack, esDecay, esSustain] then
    begin
      Gate := True;
      Break;
    end;
  if FFltTrigger then
  begin
    FFltTrigger := False;
    FFltStage := esAttack;
    FFltStageTime := 0;
  end;
  if not Gate and (FFltStage in [esAttack, esDecay, esSustain]) then
  begin
    FFltStage := esRelease;
    FFltStageTime := 0;
  end;

  S := Eff(gpFltSustain) / 100;
  Inc(FFltStageTime, N);
  case FFltStage of
    esAttack:
      begin
        FFltEnv := FFltEnv + N / Max(1.0, Eff(gpFltAttack) * FSampleRate / 1000);
        if FFltEnv >= 1 then
        begin
          FFltEnv := 1;
          FFltStage := esDecay;
          FFltStageTime := 0;
        end;
      end;
    esDecay:
      begin
        FFltEnv := S + (FFltEnv - S) * Power(0.001, N / Max(1.0, Eff(gpFltDecay) * FSampleRate / 1000));
        if Abs(FFltEnv - S) < 0.001 then
        begin
          FFltStage := esSustain;
          FFltStageTime := 0;
        end;
      end;
    esSustain:
      FFltEnv := FFltEnv + (S - FFltEnv) * 0.1;
    esRelease:
      begin
        FFltEnv := FFltEnv * Power(0.0001, N / Max(1.0, Eff(gpFltRelease) * FSampleRate / 1000));
        if FFltEnv < 0.0001 then
        begin
          FFltEnv := 0;
          FFltStage := esIdle;
        end;
      end;
  else
    FFltEnv := 0;
  end;
  FSource[msFilterEnv] := FFltEnv;
end;

{ ein Zustandsvariablen-Filter (TPT/SVF, SIMD-Kern) mit Kontur-Mischung auf einen Puffer }
{ Grenzfrequenz mit Filter-Huellkurve (wie im SVF) }
function TGranularEngine.FilterFc(Cutoff, EnvAmt, Env: Double): Double;
begin
  if Env < 0 then Env := FFltEnv;
  Result := EnsureRange(Cutoff * Power(2, EnvAmt / 100 * 6 * Env), 20, FSampleRate * 0.45);
end;

procedure TGranularEngine.ResetFlt(var F: TFltState);
var
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    FillChar(F.Svf[I].IC1, SizeOf(F.Svf[I].IC1), 0);
    FillChar(F.Svf[I].IC2, SizeOf(F.Svf[I].IC2), 0);
  end;
  if F.CombUsed and (F.Comb.Buf <> nil) then
  begin
    FillChar(F.Comb.Buf^, COMB_LEN * 2 * SizeOf(Single), 0);
    F.CombUsed := False;
  end;
end;

{ Filter 1/2 aller Arten: Tiefpass/Bandpass/Hochpass (SVF), Ladder (Saettigung + zwei Tiefpaesse
  in Reihe, 24 dB/Okt.), Kamm (Verzoegerung = eine Periode der Cutoff-Frequenz, Resonanz =
  Rueckkopplung) und Formant (Cutoff waehlt stufenlos den Vokal A-E-I-O-U, drei Bandpaesse parallel).
  Alle Arten nutzen die SIMD-Kerne (SVF, Saettigung, Kamm). }
procedure TGranularEngine.RunFilter(var F: TFltState; Buf: PSingle; N, FType: Integer;
  Cutoff, Reso, Contour, EnvAmt: Double; Env: Double);
const
  FORM: array[0..4, 0..2] of Double = ((730, 1090, 2440), (530, 1840, 2480), (270, 2290, 3010),
    (570, 840, 2410), (300, 870, 2240));
  FORM_G: array[0..2] of Single = (1.0, 0.5, 0.3);
var
  M, Fc, D, P, Fr, Fb: Double;
  I, B, Vi, Cnt: Integer;
  G: Single;
begin
  case FType of
    FLT_LADDER:
      begin
        M := Contour / 100;
        if M < 0.999 then
          Move(Buf^, FFltDry[0], N * 2 * SizeOf(Single));
        FLadSat := FSat;
        for I := 0 to 3 do
        begin
          FLadSat.Drive4[I] := 1.8;
          FLadSat.Make4[I] := 1 / 1.8 * 1.25;
        end;
        Cnt := (N * 2) and not 3;
        if Cnt > 0 then
        begin
          FLadSat.P := Buf;
          FLadSat.Count := Cnt;
          RenderSat(@FLadSat);
        end;
        if Cnt < N * 2 then
        begin
          FLadSat.P := @Buf[Cnt];
          FLadSat.Count := N * 2 - Cnt;
          SatBlockPas(@FLadSat);
        end;
        RunSvf(F.Svf[0], Buf, N, 0, Cutoff, Reso, 100, EnvAmt, Env);
        RunSvf(F.Svf[1], Buf, N, 0, Cutoff, Reso * 0.35, 100, EnvAmt, Env);
        if M < 0.999 then
          for I := 0 to N * 2 - 1 do
            Buf[I] := FFltDry[I] * (1 - M) + Buf[I] * M;
      end;
    FLT_COMB:
      begin
        Fc := FilterFc(Cutoff, EnvAmt, Env);
        D := EnsureRange(FSampleRate / Fc, 2, COMB_LEN - 3);
        Fb := Reso / 100 * 0.97;
        M := Contour / 100;
        F.Comb.IO := Buf;
        F.Comb.Count := N;
        F.Comb.Mask := COMB_LEN - 1;
        F.Comb.DInt := Trunc(D);
        F.Comb.Frac := D - Trunc(D);
        F.Comb.Fb := Fb;
        F.Comb.MixX := 1 - M;
        F.Comb.MixW := M * (1 - 0.6 * Fb);   // Pegel bei hoher Rueckkopplung im Rahmen halten
        F.CombUsed := True;
        RenderComb(@F.Comb);
      end;
    FLT_FORMANT:
      begin
        M := Contour / 100;
        Fc := FilterFc(Cutoff, EnvAmt, Env);
        P := EnsureRange(Ln(Fc / 20) / Ln(1000) * 4, 0, 4);    // 20 Hz .. 20 kHz -> A .. U
        Vi := Min(Trunc(P), 3);
        Fr := P - Vi;
        Move(Buf^, FFltDry[0], N * 2 * SizeOf(Single));
        for I := 0 to N * 2 - 1 do
          Buf[I] := FFltDry[I] * (1 - M);
        for B := 0 to 2 do
        begin
          Move(FFltDry[0], FFltX[0], N * 2 * SizeOf(Single));
          D := FORM[Vi, B] + (FORM[Vi + 1, B] - FORM[Vi, B]) * Fr;
          RunSvf(F.Svf[B], @FFltX[0], N, 1, D, 60 + Reso * 0.38, 100, 0, 0);
          G := FORM_G[B] * M * 1.4;
          for I := 0 to N * 2 - 1 do
            Buf[I] := Buf[I] + FFltX[I] * G;
        end;
      end;
  else
    RunSvf(F.Svf[0], Buf, N, FType, Cutoff, Reso, Contour, EnvAmt, Env);
  end;
end;

{ Leistungsstufe; beim Rendern mit 'Hoechstqualitaet' immer voll }
function TGranularEngine.PerfLevel: Integer;
begin
  if FOffline and (FParams[Ord(gpRenderHQ)] >= 0.5) then
    Exit(0);
  Result := EnsureRange(ParamStep(Ord(gpPerformance), FParams[Ord(gpPerformance)]), 0, 2);
end;

{ Zone der Note: die Zone mit der hoechsten Starttaste <= Note, sonst das Hauptsample }
function TGranularEngine.ZoneOfNote(Note: Integer): Integer;
var
  Z, Best: Integer;
begin
  Result := 0;
  Best := -1;
  for Z := 1 to ZONE_COUNT do
    if (FZone[Z] <> nil) and (Note >= FZoneLow[Z]) and (FZoneLow[Z] > Best) then
    begin
      Best := FZoneLow[Z];
      Result := Z;
    end;
end;

procedure TGranularEngine.SetZone(Z: Integer; Data: TSampleData; LowNote: Integer);
var
  Old: TSampleData;
  Root, Tune: Double;
begin
  if (Z < 1) or (Z > ZONE_COUNT) then
  begin
    Data.Free;
    Exit;
  end;
  Tune := 0;
  if Data <> nil then
    DetectRoot(Data, Root, Tune);
  FLock.Enter;
  try
    ResetGrains;                     // laufende Grains koennten das alte Sample lesen
    Old := FZone[Z];
    FZone[Z] := Data;
    FZoneTune[Z] := Tune;
    FZoneLow[Z] := EnsureRange(LowNote, 0, 127);
  finally
    FLock.Leave;
  end;
  Old.Free;
end;

function TGranularEngine.ZoneSample(Z: Integer): TSampleData;
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then Result := FZone[Z] else Result := nil;
end;

function TGranularEngine.GetZoneLow(Z: Integer): Integer;
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then Result := FZoneLow[Z] else Result := 0;
end;

function TGranularEngine.GetZoneRef(Z: Integer): string;
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then Result := FZoneRef[Z] else Result := '';
end;

procedure TGranularEngine.SetZoneRef(Z: Integer; const Value: string);
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then FZoneRef[Z] := Value;
end;

function TGranularEngine.GetZoneLoaded(Z: Integer): string;
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then Result := FZoneLoaded[Z] else Result := '';
end;

procedure TGranularEngine.SetZoneLoaded(Z: Integer; const Value: string);
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then FZoneLoaded[Z] := Value;
end;

procedure TGranularEngine.SetZoneLow(Z, Note: Integer);
begin
  if (Z >= 1) and (Z <= ZONE_COUNT) then
    FZoneLow[Z] := EnsureRange(Note, 0, 127);
end;

procedure TGranularEngine.StartRecording(Seconds: Double);
var
  Buf: TArray<Single>;
  Len: Integer;
begin
  Len := Max(1, Round(Seconds * FSampleRate));
  SetLength(Buf, Len * 2);           // im GUI-Thread anlegen, nie im Audio-Thread
  FLock.Enter;
  try
    FRecBuf := Buf;
    FRecLen := Len;
    FRecPos := 0;
    FRecOn := True;
  finally
    FLock.Leave;
  end;
end;

function TGranularEngine.StopRecording: TSampleData;
var
  Buf: TArray<Single>;
  Cnt, F: Integer;
begin
  FLock.Enter;
  try
    FRecOn := False;
    Cnt := FRecPos;
    Buf := FRecBuf;
    FRecBuf := nil;
    FRecLen := 0;
  finally
    FLock.Leave;
  end;
  if Cnt < 64 then
    Exit(nil);
  Result := TSampleData.Create;
  Result.Frames := Cnt;
  Result.SampleRate := FSampleRate;
  Result.Channels := 2;
  SetLength(Result.L, Cnt);
  SetLength(Result.R, Cnt);
  for F := 0 to Cnt - 1 do
  begin
    Result.L[F] := Buf[F * 2];
    Result.R[F] := Buf[F * 2 + 1];
  end;
  BuildInterleaved(Result);
end;

function TGranularEngine.Recording: Boolean;
begin
  Result := FRecOn;
end;

function TGranularEngine.RecordedSeconds: Double;
begin
  Result := FRecPos / FSampleRate;
end;

{ Chorus: Verzoegerung 7..19 ms, Dreieck-LFO, rechts um 90 Grad versetzt (breit), mit Rueckkopplung
  bis zum Flanger. Summen-Effekt (einmal je Block) in Pascal wie das Echo, ganz in Festkomma:
  LFO-Phase 32 Bit, Verzoegerung 24.8 - nur 32-Bit-Ganzzahlen, kein Trunc je Sample (auf x87 teuer). }
procedure TGranularEngine.ProcessChorus(N: Integer);
var
  Mix: Single;
begin
  if Eff(gpChoOn) < 0.5 then
  begin
    if FChoWasOn then
    begin
      FillChar(FChoBuf, SizeOf(FChoBuf), 0);
      FChoWasOn := False;
    end;
    Exit;
  end;
  FChoWasOn := True;
  Mix := Eff(gpChoMix) / 100;
  FCho.IO := @FMix[0];
  FCho.Count := N;
  FCho.Buf := @FChoBuf[0];
  FCho.Mask := CHO_LEN - 1;
  FCho.PhInc := Cardinal(Round(Eff(gpChoRate) / FSampleRate * 4294967296.0));
  // Verzoegerung in 1/256 Samples: Spanne <= 0,012 s * 192 kHz * 256 < 2^20, Dreieck auf 12 Bit
  FCho.Base8 := Round(0.007 * FSampleRate * 256);
  FCho.Span8 := Round(0.012 * FSampleRate * Eff(gpChoDepth) / 100 * 256);
  FCho.Fb := Eff(gpChoFeedback) / 100;
  FCho.Dry := 1 - 0.5 * Mix;
  FCho.Wet := Mix * 0.7;
  FCho.Inv256 := 1 / 256;
  RenderChorus(@FCho);
end;

{ Phaser: sechs Allpaesse erster Ordnung, Mitte 200 Hz .. 6,4 kHz per Sinus-LFO (rechts versetzt),
  Rueckkopplung. Koeffizient einmal je Block (<= 64 Samples) berechnet und im SIMD-Kern gleitend
  dorthin gefuehrt (keine Stufen). }
procedure TGranularEngine.ProcessPhaser(N: Integer);
var
  C: Integer;
  Mix, Depth, Ph, T, Fq: Double;
  ATarget: Single;
begin
  if Eff(gpPhaOn) < 0.5 then
  begin
    if FPhaWasOn then
    begin
      FillChar(FPha.X1, SizeOf(FPha.X1), 0);
      FillChar(FPha.Y1, SizeOf(FPha.Y1), 0);
      FillChar(FPha.Last, SizeOf(FPha.Last), 0);
      FPhaWasOn := False;
    end;
    Exit;
  end;
  Mix := Eff(gpPhaMix) / 100;
  Depth := Eff(gpPhaDepth) / 100;
  FPhaPh := FPhaPh + Eff(gpPhaRate) / FSampleRate * N;
  if FPhaPh >= 1 then FPhaPh := FPhaPh - Floor(FPhaPh);
  for C := 0 to 1 do
  begin
    Ph := FPhaPh + C * 0.25;
    if Ph >= 1 then Ph := Ph - 1;
    T := 0.5 - 0.5 * Cos(2 * Pi * Ph);
    Fq := Min(200 * Power(2, Depth * 5 * T), FSampleRate * 0.45);
    T := Tan(Pi * Fq / FSampleRate);
    ATarget := (T - 1) / (T + 1);
    if not FPhaWasOn then
      FPhaA[C] := ATarget;
    FPha.A4[C] := FPhaA[C];
    FPha.DA4[C] := (ATarget - FPhaA[C]) / N;
    FPhaA[C] := ATarget;
    FPha.Fb4[C] := Eff(gpPhaFeedback) / 100;
    FPha.Dry4[C] := 1 - 0.5 * Mix;
    FPha.Wet4[C] := 0.5 * Mix;
  end;
  FPhaWasOn := True;
  FPha.IO := @FMix[0];
  FPha.Count := N;
  RenderPhaser(@FPha);
  // ausklingender Phaser: winzige Restwerte nullen (Denormal-Zahlen bremsen ohne FTZ stark)
  if (Abs(FPha.Last[0]) < 1E-20) and (Abs(FPha.Last[1]) < 1E-20) then
  begin
    FillChar(FPha.X1, SizeOf(FPha.X1), 0);
    FillChar(FPha.Y1, SizeOf(FPha.Y1), 0);
    FillChar(FPha.Last, SizeOf(FPha.Last), 0);
  end;
end;

{ Bitcrusher: Abtastrate senken (Wert halten) und Aufloesung vergroebern }
procedure TGranularEngine.ProcessCrush(N: Integer);
var
  I, C: Integer;
  Lv, Ratio, Mix: Double;
begin
  if Eff(gpCrushOn) < 0.5 then
    Exit;
  Lv := Power(2, Eff(gpCrushBits) - 1);
  Ratio := Min(1.0, Eff(gpCrushRate) / FSampleRate);
  Mix := Eff(gpCrushMix) / 100;
  for I := 0 to N - 1 do
  begin
    FCrushPh := FCrushPh + Ratio;
    if FCrushPh >= 1 then
    begin
      FCrushPh := FCrushPh - 1;
      for C := 0 to 1 do
        FCrushHold[C] := Round(FMix[I * 2 + C] * Lv) / Lv;
    end;
    for C := 0 to 1 do
      FMix[I * 2 + C] := FMix[I * 2 + C] * (1 - Mix) + FCrushHold[C] * Mix;
  end;
end;

function TGranularEngine.TgShownStep: Integer;
var
  Steps: Integer;
begin
  if (FParams[Ord(gpTgOn)] < 0.5) or ((FTgPos <= 0) and (FTgStep = 0)) then
    Exit(-1);
  Steps := EnsureRange(ParamStep(Ord(gpTgSteps), FParams[Ord(gpTgSteps)]), 0, 15) + 1;
  Result := FTgStep mod Steps;
end;

{ Trance-Gate: Schrittmuster im Songtempo; geschlossene Schritte senken um 'Tiefe', Glaettung gegen
  Knacken. Beginnt mit der ersten Note nach Stille wieder bei Schritt 1. }
procedure TGranularEngine.ProcessTranceGate(N: Integer);
var
  I, V, Steps, St: Integer;
  StepLen, Depth, Sm, Coef, Inc_: Double;
  G, Tgt, Cf: Single;
  Active: Boolean;
begin
  if Eff(gpTgOn) < 0.5 then
  begin
    FTgGain := 1;
    Exit;
  end;
  Active := False;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage <> esIdle) or OscSounding(V, False) then
    begin
      Active := True;
      Break;
    end;
  if not Active then
  begin
    FTgPos := 0;
    FTgStep := 0;
    Exit;
  end;
  StepLen := Max(16.0, 60 / Eff(gpTempo) * ARP_RATE_BEATS[EnsureRange(ParamStep(Ord(gpTgRate), FEff[Ord(gpTgRate)]), 0, 5)] * FSampleRate);
  Steps := EnsureRange(ParamStep(Ord(gpTgSteps), FEff[Ord(gpTgSteps)]), 0, 15) + 1;
  Depth := Eff(gpTgDepth) / 100;
  Sm := Eff(gpTgSmooth);
  if Sm < 0.05 then
    Coef := 1
  else
    Coef := 1 - Exp(-1 / (Sm * 0.001 * FSampleRate));
  Cf := Coef;
  G := FTgGain;
  // FTgPos = Bruchteil des laufenden Schritts (0..1), FTgStep = Schritt
  if FTgStep >= Steps then
    FTgStep := FTgStep mod Steps;
  Inc_ := 1 / StepLen;
  for I := 0 to N - 1 do
  begin
    if (FTgMask shr FTgStep) and 1 <> 0 then
      Tgt := 1
    else
      Tgt := 1 - Depth;
    G := G + (Tgt - G) * Cf;
    FMix[I * 2] := FMix[I * 2] * G;
    FMix[I * 2 + 1] := FMix[I * 2 + 1] * G;
    FTgPos := FTgPos + Inc_;
    if FTgPos >= 1 then
    begin
      FTgPos := FTgPos - 1;
      Inc(FTgStep);
      if FTgStep >= Steps then
        FTgStep := 0;
    end;
  end;
  FTgGain := G;
end;

procedure TGranularEngine.RunSvf(var Svf: TSvfArgs; Buf: PSingle; N, FType: Integer;
  Cutoff, Reso, Contour, EnvAmt: Double; Env: Double);
var
  M, Fc, G, K, A1, A2, A3, CX, CL, CB: Double;
  C: Integer;
begin
  M := Contour / 100;
  if Env < 0 then Env := FFltEnv;          // ohne Angabe: globale Filter-Huellkurve
  Fc := Cutoff * Power(2, EnvAmt / 100 * 6 * Env);
  Fc := EnsureRange(Fc, 20, FSampleRate * 0.45);
  G := Tan(Pi * Fc / FSampleRate);
  K := 2 - 1.96 * Reso / 100;          // Daempfung: 2 (keine Resonanz) .. 0.04
  A1 := 1 / (1 + G * (G + K));
  A2 := G * A1;
  A3 := G * A2;
  case FType of
    1: begin CX := 1 - M; CL := 0;  CB := M * K; end;  // Bandpass, Spitze normiert auf 1
    2: begin CX := 1;     CL := -M; CB := -M * K; end; // Hochpass = x - k*bp - lp
  else
       begin CX := 1 - M; CL := M;  CB := 0; end;      // Tiefpass
  end;
  for C := 0 to 3 do
  begin
    Svf.A1[C] := A1; Svf.A2[C] := A2; Svf.A3[C] := A3;
    Svf.MixX[C] := CX; Svf.MixL[C] := CL; Svf.MixB[C] := CB;
  end;
  Svf.Buf := Buf;
  Svf.Count := N;
  RenderSvf(@Svf);
  for C := 0 to 1 do
  begin
    if Abs(Svf.IC1[C]) < 1E-15 then Svf.IC1[C] := 0;
    if Abs(Svf.IC2[C]) < 1E-15 then Svf.IC2[C] := 0;
  end;
end;

{ Filter 1 und optional Filter 2: in Reihe (1 -> 2) oder parallel (Mittelwert beider Ausgaenge,
  damit die Lautstaerke gleich bleibt; ist nur einer aktiv, wirkt nur dieser) }
procedure TGranularEngine.ProcessFilter(N: Integer);
var
  On1, On2, Par: Boolean;
  I: Integer;
begin
  On1 := (Eff(gpFltOn) >= 0.5) and (Eff(gpFltContour) > 0.05);
  On2 := (Eff(gpFlt2On) >= 0.5) and (Eff(gpFlt2Contour) > 0.05);
  if not On1 then
    ResetFlt(FFlt1);
  if not On2 then
    ResetFlt(FFlt2);
  Par := Eff(gpFltRouting) >= 0.5;
  if On1 and On2 and Par then
  begin
    Move(FMix[0], FMix2[0], N * 2 * SizeOf(Single));
    RunFilter(FFlt1, @FMix[0], N, Round(Eff(gpFltType)), Eff(gpFltCutoff), Eff(gpFltReso), Eff(gpFltContour), Eff(gpFltEnvAmt));
    RunFilter(FFlt2, @FMix2[0], N, Round(Eff(gpFlt2Type)), Eff(gpFlt2Cutoff), Eff(gpFlt2Reso), Eff(gpFlt2Contour), Eff(gpFlt2EnvAmt));
    for I := 0 to N * 2 - 1 do
      FMix[I] := (FMix[I] + FMix2[I]) * 0.5;
    Exit;
  end;
  if On1 then
    RunFilter(FFlt1, @FMix[0], N, Round(Eff(gpFltType)), Eff(gpFltCutoff), Eff(gpFltReso), Eff(gpFltContour), Eff(gpFltEnvAmt));
  if On2 then
    RunFilter(FFlt2, @FMix[0], N, Round(Eff(gpFlt2Type)), Eff(gpFlt2Cutoff), Eff(gpFlt2Reso), Eff(gpFlt2Contour), Eff(gpFlt2EnvAmt));
end;

{ Klangprozessor je Note: Filter-Huellkurve der Stimme (Anschlag bis Loslassen der eigenen Note),
  Filter 1 und 2 (Reihe/parallel) mit den Werten der Stimme (global + eigene Noten-Modulation),
  danach in die Summe. Echo, Hall, EQ und Limiter wirken danach global auf die Summe. }
procedure TGranularEngine.ProcessVoiceFilters(N: Integer);
var
  V, I, T1, T2: Integer;
  On1, On2, Par: Boolean;
  Sus, AttK, DecK, RelK: Double;
  C1, R1, E1, C2, R2, E2, Co1, Co2: Double;
  GSus, GAttK, GDecK, GRelK, GCo1, GCo2: Double;
  Buf: PSingle;
begin
  On1 := Eff(gpFltOn) >= 0.5;
  On2 := Eff(gpFlt2On) >= 0.5;
  Par := Eff(gpFltRouting) >= 0.5;
  T1 := Round(Eff(gpFltType)); T2 := Round(Eff(gpFlt2Type));
  GCo1 := Eff(gpFltContour); GCo2 := Eff(gpFlt2Contour);
  GSus := Eff(gpFltSustain) / 100;
  GAttK := N / Max(1.0, Eff(gpFltAttack) * FSampleRate / 1000);
  GDecK := Power(0.001, N / Max(1.0, Eff(gpFltDecay) * FSampleRate / 1000));
  GRelK := Power(0.0001, N / Max(1.0, Eff(gpFltRelease) * FSampleRate / 1000));
  for V := 0 to MAX_VOICES - 1 do
  begin
    // Filter-Huellkurve dieser Note (laeuft auch ohne Signal weiter, damit sie stimmt)
    if FVModOn[V] then
    begin
      Sus := FVPlain[V, PND_FLSUS] / 100;
      AttK := N / Max(1.0, FVPlain[V, PND_FLATT] * FSampleRate / 1000);
      DecK := Power(0.001, N / Max(1.0, FVPlain[V, PND_FLDEC] * FSampleRate / 1000));
      RelK := Power(0.0001, N / Max(1.0, FVPlain[V, PND_FLREL] * FSampleRate / 1000));
      Co1 := FVPlain[V, PND_F1CON]; Co2 := FVPlain[V, PND_F2CON];
    end
    else
    begin
      Sus := GSus; AttK := GAttK; DecK := GDecK; RelK := GRelK; Co1 := GCo1; Co2 := GCo2;
    end;
    if (FVFltStage[V] in [esAttack, esDecay, esSustain]) and
       not (FVoices[V].Stage in [esAttack, esDecay, esSustain]) and
       not OscSounding(V, True) then
      FVFltStage[V] := esRelease;
    case FVFltStage[V] of
      esAttack:
        begin
          FVFltEnv[V] := FVFltEnv[V] + AttK;
          if FVFltEnv[V] >= 1 then begin FVFltEnv[V] := 1; FVFltStage[V] := esDecay; end;
        end;
      esDecay:
        begin
          FVFltEnv[V] := Sus + (FVFltEnv[V] - Sus) * DecK;
          if Abs(FVFltEnv[V] - Sus) < 0.001 then FVFltStage[V] := esSustain;
        end;
      esSustain:
        FVFltEnv[V] := FVFltEnv[V] + (Sus - FVFltEnv[V]) * 0.1;
      esRelease:
        begin
          FVFltEnv[V] := FVFltEnv[V] * RelK;
          if FVFltEnv[V] < 0.0001 then begin FVFltEnv[V] := 0; FVFltStage[V] := esIdle; end;
        end;
    end;
    if not FVHasSig[V] then
      Continue;
    if FVModOn[V] then
    begin
      C1 := FVPlain[V, PND_F1CUT]; R1 := FVPlain[V, PND_F1RES]; E1 := FVPlain[V, PND_F1ENV];
      C2 := FVPlain[V, PND_F2CUT]; R2 := FVPlain[V, PND_F2RES]; E2 := FVPlain[V, PND_F2ENV];
    end
    else
    begin
      C1 := Eff(gpFltCutoff); R1 := Eff(gpFltReso); E1 := Eff(gpFltEnvAmt);
      C2 := Eff(gpFlt2Cutoff); R2 := Eff(gpFlt2Reso); E2 := Eff(gpFlt2EnvAmt);
    end;
    Buf := @FVBuf[V, 0];
    if On1 and On2 and Par then
    begin
      Move(FVBuf[V], FVTmp, N * 2 * SizeOf(Single));
      RunFilter(FVSvf1[V], Buf, N, T1, C1, R1, Co1, E1, FVFltEnv[V]);
      RunFilter(FVSvf2[V], @FVTmp[0], N, T2, C2, R2, Co2, E2, FVFltEnv[V]);
      for I := 0 to N * 2 - 1 do
        FMix[I] := FMix[I] + (FVBuf[V, I] + FVTmp[I]) * 0.5;
      Continue;
    end;
    if On1 then
      RunFilter(FVSvf1[V], Buf, N, T1, C1, R1, Co1, E1, FVFltEnv[V]);
    if On2 then
      RunFilter(FVSvf2[V], Buf, N, T2, C2, R2, Co2, E2, FVFltEnv[V]);
    for I := 0 to N * 2 - 1 do
      FMix[I] := FMix[I] + FVBuf[V, I];
  end;
end;

procedure TGranularEngine.ProcessEcho(N: Integer);
var
  Mix, Sec: Double;
begin
  if Eff(gpEchoOn) < 0.5 then
  begin
    // beim Ausschalten Speicher leeren -> beim Wiedereinschalten keine alten Wiederholungen
    if FEchoWasOn then
    begin
      FillChar(FEchoBuf[0], Length(FEchoBuf) * SizeOf(Single), 0);
      FillChar(FPitchBuf[0], Length(FPitchBuf) * SizeOf(Single), 0);
      FEcho.LP[0] := 0;
      FEcho.LP[1] := 0;
      FEchoWasOn := False;
    end;
    Exit;
  end;
  FEchoWasOn := True;
  Mix := Eff(gpEchoMix) / 100;
  if (Mix <= 0.0005) or (FEcho.Len < 4) then
    Exit;
  if Eff(gpEchoSync) >= 0.5 then
    Sec := LFO_DIV_BEATS[EchoDivisionIndex(FEff[Ord(gpEchoTime)])] * 60 / Eff(gpTempo)
  else
    Sec := Eff(gpEchoTime) / 1000;
  FEcho.Target := EnsureRange(Sec * FSampleRate, 1, FEcho.Len - 2);
  if FEcho.Delay <= 0 then
    FEcho.Delay := FEcho.Target;
  FEcho.Feedback := Eff(gpEchoFeedback) / 100;
  FEcho.Mix := Mix;
  FEcho.DampCoef := 1 - 0.9 * Eff(gpEchoDamp) / 100;
  FEcho.PingPong := Eff(gpEchoPingPong) >= 0.5;
  FEcho.PRatio := Power(2, Eff(gpEchoPitch) / 12);
  FEcho.Buf := @FEchoBuf[0];
  FEcho.IO := @FMix[0];
  FEcho.Count := N;
  EchoBlock(@FEcho);
end;

function TGranularEngine.ScaleSnap(Semis: Double): Double;
var
  Abs0, D, K, Best: Integer;
  Mask: Word;
begin
  // absolute Tonhoehe = ROOT_NOTE + Semis; naechster Ton der Tonleiter (bei Gleichstand nach oben)
  Mask := SCALE_MASKS[FScale];
  Abs0 := Round(ROOT_NOTE + Semis);
  Best := Abs0;
  for D := 0 to 6 do
  begin
    K := Abs0 + D;
    if Mask and (1 shl (((K - FScaleRoot) mod 12 + 12) mod 12)) <> 0 then
    begin
      Best := K;
      Break;
    end;
    K := Abs0 - D;
    if Mask and (1 shl (((K - FScaleRoot) mod 12 + 12) mod 12)) <> 0 then
    begin
      Best := K;
      Break;
    end;
  end;
  Result := Best - ROOT_NOTE;
end;

procedure TGranularEngine.ApplyGain(N: Integer);
var
  I: Integer;
  G, Step: Double;
begin
  // Lautstaerke als Rampe ueber den Subblock -> auch schnelle Gates (Frei-LFO) knacken nicht
  if FGainPrev < 0 then
    FGainPrev := FGain;
  G := FGainPrev;
  Step := (FGain - FGainPrev) / N;
  for I := 0 to N - 1 do
  begin
    G := G + Step;
    FMix[I * 2] := FMix[I * 2] * G;
    FMix[I * 2 + 1] := FMix[I * 2 + 1] * G;
  end;
  FGainPrev := FGain;
end;

function TGranularEngine.EqCurve: PEqCurve;
begin
  Result := @FEqCurve;
end;

procedure TGranularEngine.EqChanged;
begin
  Inc(FEqVersion);
end;

procedure TGranularEngine.FollowSc2(L: PSingle; RAddr: NativeInt; N: Integer);
var
  R: PSingle;
  I: Integer;
  Peak, V, Coef: Double;
begin
  R := PSingle(RAddr);
  Peak := 0;
  for I := 0 to N - 1 do
  begin
    V := Abs(L[I]);
    if V > Peak then Peak := V;
    V := Abs(R[I]);
    if V > Peak then Peak := V;
  end;
  Peak := Peak * Power(10, Eff(gpScGain) / 20);
  if Peak > FSc2Level then
    Coef := Exp(-N / Max(1.0, Eff(gpScAttack) * FSampleRate / 1000))
  else
    Coef := Exp(-N / Max(1.0, Eff(gpScRelease) * FSampleRate / 1000));
  FSc2Level := Peak + (FSc2Level - Peak) * Coef;
  FSource[msSidechain2] := Min(1.0, FSc2Level);
end;

{ Oszillator-Schicht: je Stimme ein Oszillator in der Notenhoehe (+ Oktave/Fein/Pitchbend),
  Sinus/FM ueber eine Tabelle (4096 + linear), Saegezahn/Rechteck bandbegrenzt (PolyBLEP),
  eigene ADSR; Mischung mit gleicher Leistung ins Panorama. }
procedure TGranularEngine.RenderOscOne(O, N: Integer);
const
  OSC_UNI: array[0..OSC_COUNT - 1, 0..2] of TGranularParamId = (
    (gpOscUnison, gpOscDetune, gpOscUniWidth), (gpOsc2Unison, gpOsc2Detune, gpOsc2UniWidth),
    (gpOsc3Unison, gpOsc3Detune, gpOsc3UniWidth));
var
  Uni, K: Integer;
  UniDet, UniWidth, UniNorm, UD, UPn, UDt: Double;
  GL0, GR0: Single;
  VAtt, VDec, VSus, VRel, VFAtt, VFDec, VFSus, VFRel: Double;
  V, I, Wave: Integer;
  Hz, Dt, Lvl, Pn, AttInc, DecCoef, Sus, RelCoef, Ratio, FmIdx: Double;
  VFine, VLvl, VPn, VRatio: Double;
  FAtt, FDec, FSus, FRel: Double;
  E, F: Single;
  OwnFm, OwnFlt, OsV, DrawOn, UseWt: Boolean;
  WtTab: PSingle;
  Dst: PSingle;
  G0, R0: Single;
  P: TOscParamIds;
begin
  P := OSC_P[O];
  if Eff(P.On_) < 0.5 then
  begin
    for V := 0 to MAX_VOICES - 1 do
    begin
      FOsc[O, V].Stage := esIdle;
      FOsc[O, V].Env := 0;
      FOsc[O, V].FmEnv := 0;
    end;
    Exit;
  end;
  Wave := EnsureRange(Round(Eff(P.Wave)), 0, 5);
  DrawOn := Eff(P.Draw) >= 0.5;                  // gezeichnete Welle ersetzt 'Welle'
  if DrawOn then
  begin
    Wave := 0;
    UseWt := True;
    WtTab := FWtPtr[O];
  end
  else
  begin
    // Modell Wavetable: Dreieck, Saege, Rechteck bandbegrenzt aus Tabellen (klassisch: PolyBLEP-Kern)
    UseWt := (Wave in [1, 2, 3]) and (FParams[Ord(gpOscModel)] < 0.5);
    if UseWt then
      WtTab := @GWtBuiltin[Wave - 1, 0]
    else
      WtTab := nil;
  end;
  OwnFlt := Eff(P.FltOn) >= 0.5;
  Uni := EnsureRange(Round(Eff(OSC_UNI[O, 0])), 1, UNI_MAX);
  if Wave = 5 then
    Uni := 1;                                    // Rauschen: Unison wuerde nur lauter machen
  UniDet := Eff(OSC_UNI[O, 1]);
  UniWidth := Eff(OSC_UNI[O, 2]) / 100;
  UniNorm := 1 / Sqrt(Uni);
  if OwnFlt and not FOscOwnFlt then
  begin
    FillChar(FOscMix[0], N * 2 * SizeOf(Single), 0);   // erster Oszillator mit eigenem Filter
    FOscOwnFlt := True;
  end;
  Lvl := Sqr(Eff(P.Level) / 100) * 0.5;
  Pn := Eff(P.Pan) / 100;
  AttInc := 1 / Max(1.0, Eff(P.Attack) * FSampleRate / 1000);
  DecCoef := Exp(Ln(0.001) / Max(1.0, Eff(P.Decay) * FSampleRate / 1000));
  Sus := Eff(P.Sustain) / 100;
  RelCoef := Exp(Ln(0.0001) / Max(1.0, Eff(P.Release) * FSampleRate / 1000));
  Ratio := Eff(P.FmRatio);
  FmIdx := Eff(P.FmAmt) / 100 * 6 / (2 * Pi);
  // eigene FM-Huellkurve: steuert nur die FM-Menge (Klangfarbe/Punch), nicht die Lautstaerke
  OwnFm := (Wave = 4) and (Eff(P.FmEnvOn) >= 0.5);
  FAtt := 1 / Max(1.0, Eff(P.FmAttack) * FSampleRate / 1000);
  FDec := Exp(Ln(0.001) / Max(1.0, Eff(P.FmDecay) * FSampleRate / 1000));
  FSus := Eff(P.FmSustain) / 100;
  FRel := Exp(Ln(0.0001) / Max(1.0, Eff(P.FmRelease) * FSampleRate / 1000));
  FOscArgs.Tab := @FSinTab[0];
  FOscArgs.Wave := Wave;
  FOscArgs.GL := Sqrt((1 - Pn) / 2) * Sqrt(2);
  FOscArgs.GR := Sqrt((1 + Pn) / 2) * Sqrt(2);
  FOscArgs.FmIdx := FmIdx;
  // Hard Sync: Folgewelle 1x .. 8x je Periode (0 % = aus, Welle unveraendert)
  FOscArgs.SyncR := 1 + Eff(P.Sync) / 100 * 7;
  for V := 0 to MAX_VOICES - 1 do
    with FOsc[O, V] do
    begin
      if Stage = esIdle then
        Continue;
      // Werte dieser Stimme (polyphone Noten-Modulation) oder global
      if FVModOn[V] then
      begin
        VFine := FVPlain[V, OSC_PND[O, OP_FINE]];
        VLvl := Sqr(FVPlain[V, OSC_PND[O, OP_LVL]] / 100) * 0.5;
        VPn := FVPlain[V, OSC_PND[O, OP_PAN]] / 100;
        FOscArgs.FmIdx := FVPlain[V, OSC_PND[O, OP_FM]] / 100 * 6 / (2 * Pi);
        VRatio := FVPlain[V, OSC_PND[O, OP_RATIO]];
        FOscArgs.SyncR := 1 + FVPlain[V, OSC_PND[O, OP_SYNC]] / 100 * 7;
      end
      else
      begin
        VFine := Eff(P.Fine); VLvl := Lvl; VPn := Pn; VRatio := Ratio;
        FOscArgs.FmIdx := FmIdx;
        FOscArgs.SyncR := 1 + Eff(P.Sync) / 100 * 7;
      end;
      if FVModOn[V] then
      begin
        VAtt := 1 / Max(1.0, FVPlain[V, OSC_PND[O, OP_ATT]] * FSampleRate / 1000);
        VDec := Exp(Ln(0.001) / Max(1.0, FVPlain[V, OSC_PND[O, OP_DEC]] * FSampleRate / 1000));
        VSus := FVPlain[V, OSC_PND[O, OP_SUS]] / 100;
        VRel := Exp(Ln(0.0001) / Max(1.0, FVPlain[V, OSC_PND[O, OP_REL]] * FSampleRate / 1000));
        VFAtt := 1 / Max(1.0, FVPlain[V, OSC_PND[O, OP_FMATT]] * FSampleRate / 1000);
        VFDec := Exp(Ln(0.001) / Max(1.0, FVPlain[V, OSC_PND[O, OP_FMDEC]] * FSampleRate / 1000));
        VFSus := FVPlain[V, OSC_PND[O, OP_FMSUS]] / 100;
        VFRel := Exp(Ln(0.0001) / Max(1.0, FVPlain[V, OSC_PND[O, OP_FMREL]] * FSampleRate / 1000));
      end
      else
      begin
        VAtt := AttInc; VDec := DecCoef; VSus := Sus; VRel := RelCoef;
        VFAtt := FAtt; VFDec := FDec; VFSus := FSus; VFRel := FRel;
      end;
      FOscArgs.GL := Sqrt((1 - VPn) / 2) * Sqrt(2);
      FOscArgs.GR := Sqrt((1 + VPn) / 2) * Sqrt(2);
      Hz := 440 * Power(2, (Note - 69 + FGlideOfs[V] + (Round(Eff(P.Oct)) - 3) * 12 + VFine / 100 +
        FBend * FBendRange) / 12);
      OsV := FOsOn and FOscOsGroup and ((Wave <> 5) or DrawOn);   // Rauschen: nichts zu spiegeln
      if OsV then
        Dt := Min(Hz / (FSampleRate * 2), 0.45)
      else
        Dt := Min(Hz / FSampleRate, 0.45);
      // Huellkurven abschnittsweise (Stufe fuer Stufe, SIMD-Kern), Klang im SIMD-Kern
      E := Env;
      RunEnvSegments(E, Stage, StageTime, N, VAtt, VDec, VSus, VRel, Vel * VLvl, @FOscRaw[0], @FOscGain[0]);
      Env := E;
      if FMeterOn then
        for I := 0 to N - 1 do
          if FOscGain[I] * 1.41 > FMeter[MM_OSC1 + O] then
            FMeter[MM_OSC1 + O] := FOscGain[I] * 1.41;    // Spitze der Welle (Panorama gleiche Leistung)
      if OwnFm then
      begin
        F := FmEnv;
        RunEnvSegments(F, FmStage, FmStageTime, N, VFAtt, VFDec, VFSus, VFRel, 1, @FOscRaw[0], @FOscScratch[0]);
        FmEnv := F;
      end;
      // ohne eigenes Filter: in den Puffer der Stimme (laeuft durch deren Filter 1/2);
      // mit eigenem Filter: Stimme einzeln filtern (eigener Zustand, eigene Huellkurve), dann in den Osz-Zweig
      if OwnFlt then
      begin
        FillChar(FVTmp, N * 2 * SizeOf(Single), 0);
        Dst := @FVTmp[0];
      end
      else
      begin
        if not FVHasSig[V] then
        begin
          FillChar(FVBuf[V], N * 2 * SizeOf(Single), 0);
          FVHasSig[V] := True;
        end;
        Dst := @FVBuf[V, 0];
      end;
      if OsV then
      begin
        // doppelte Rate: Huellkurven linear dazwischen, Welle in den Arbeitspuffer hinter den Vorlauf
        G0 := FOscGain[0]; R0 := FOscRaw[0];
        for I := 0 to N - 1 do
        begin
          FOscGain2[I * 2] := (G0 + FOscGain[I]) * 0.5;
          FOscGain2[I * 2 + 1] := FOscGain[I];
          FOscRaw2[I * 2] := (R0 + FOscRaw[I]) * 0.5;
          FOscRaw2[I * 2 + 1] := FOscRaw[I];
          G0 := FOscGain[I]; R0 := FOscRaw[I];
        end;
        if OwnFlt then
        begin
          Move(FOscHist[O, V, 0], FOsW[0], HB_HIST * 2 * 2 * SizeOf(Single));
          FillChar(FOsW[HB_HIST * 2 * 2], N * 2 * 2 * SizeOf(Single), 0);
          FOscArgs.Out := @FOsW[HB_HIST * 2 * 2];
        end
        else
        begin
          if not FOsVUsed[V] then
          begin
            FillChar(FOsVW[V, HB_HIST * 2 * 2], N * 2 * 2 * SizeOf(Single), 0);
            FOsVUsed[V] := True;
          end;
          FOscArgs.Out := @FOsVW[V, HB_HIST * 2 * 2];
        end;
        FOscArgs.Env := @FOscGain2[0];
        FOscArgs.EnvRaw := @FOscRaw2[0];
        FOscArgs.Count := N * 2;
      end
      else
      begin
        FOscArgs.Out := Dst;
        FOscArgs.Env := @FOscGain[0];
        FOscArgs.EnvRaw := @FOscRaw[0];
        FOscArgs.Count := N;
      end;
      if Uni <= 1 then
      begin
        FOscArgs.Ph := Ph;
        FOscArgs.PhM := PhM;
        FOscArgs.DtP := Dt;
        FOscArgs.Dt := Min(Dt * FOscArgs.SyncR, 0.45);   // PolyBLEP-Breite der schnelleren Folgewelle
        FOscArgs.DtM := Min(Dt * VRatio, 0.45);
        if UseWt then
          RenderWtOsc(WtTab)
        else
          RenderOscBlock(@FOscArgs);
        Ph := FOscArgs.Ph;
        PhM := FOscArgs.PhM;
      end
      else
      begin
        // Unison: Uni Stimmen gleichmaessig ueber +-Verstimmung und +-Breite verteilt, Summe leistungsgleich
        GL0 := FOscArgs.GL; GR0 := FOscArgs.GR;
        for K := 0 to Uni - 1 do
        begin
          UD := 2 * K / (Uni - 1) - 1;                     // -1 .. +1
          UPn := EnsureRange(VPn + UD * UniWidth, -1, 1);
          FOscArgs.GL := Sqrt((1 - UPn) / 2) * Sqrt(2) * UniNorm;
          FOscArgs.GR := Sqrt((1 + UPn) / 2) * Sqrt(2) * UniNorm;
          UDt := Min(Dt * Power(2, UD * UniDet / 1200), 0.45);
          if K = 0 then
          begin
            FOscArgs.Ph := Ph; FOscArgs.PhM := PhM;
          end
          else
          begin
            FOscArgs.Ph := UPh[K - 1]; FOscArgs.PhM := UPhM[K - 1];
          end;
          FOscArgs.DtP := UDt;
          FOscArgs.Dt := Min(UDt * FOscArgs.SyncR, 0.45);
          FOscArgs.DtM := Min(UDt * VRatio, 0.45);
          if UseWt then
            RenderWtOsc(WtTab)
          else
            RenderOscBlock(@FOscArgs);
          if K = 0 then
          begin
            Ph := FOscArgs.Ph; PhM := FOscArgs.PhM;
          end
          else
          begin
            UPh[K - 1] := FOscArgs.Ph; UPhM[K - 1] := FOscArgs.PhM;
          end;
        end;
        FOscArgs.GL := GL0; FOscArgs.GR := GR0;
      end;
      if OsV and OwnFlt then
      begin
        // zurueck auf die normale Rate und dazumischen; Vorlauf fuer den naechsten Block merken
        HbDecimate(@FOsW[0], N, @FOsDec[0]);
        for I := 0 to N * 2 - 1 do
          PFloatArr(Dst)[I] := PFloatArr(Dst)[I] + FOsDec[I];
        Move(FOsW[N * 2 * 2], FOscHist[O, V, 0], HB_HIST * 2 * 2 * SizeOf(Single));
      end;
      if OwnFlt then
      begin
        if FVModOn[V] then
          RunSvf(FVSvfOsc[O, V], @FVTmp[0], N, Round(Eff(P.FltType)), FVPlain[V, OSC_PND[O, OP_FCUT]], FVPlain[V, OSC_PND[O, OP_FRES]],
            FVPlain[V, OSC_PND[O, OP_FCON]], FVPlain[V, OSC_PND[O, OP_FENV]], FVFltEnv[V])
        else
          RunSvf(FVSvfOsc[O, V], @FVTmp[0], N, Round(Eff(P.FltType)), Eff(P.FltCutoff), Eff(P.FltReso),
            Eff(P.FltContour), Eff(P.FltEnvAmt), FVFltEnv[V]);
        for I := 0 to N * 2 - 1 do
          FOscMix[I] := FOscMix[I] + FVTmp[I];
      end;
    end;
end;

{ Grain-Pegel: wirkt sofort auch auf laufende Grains (Puffer je Stimme, Rampe ueber den Subblock) }
procedure TGranularEngine.ApplyGrainLevel(N: Integer);
var
  V, I: Integer;
  G, G0, Gi: Single;
begin
  G := DecibelToGain(Eff(gpGrainLevel));
  if FGrainGainPrev < 0 then
    FGrainGainPrev := G;
  G0 := FGrainGainPrev;
  FGrainGainPrev := G;
  if (Abs(G - 1) < 1E-6) and (Abs(G0 - 1) < 1E-6) then
    Exit;
  for V := 0 to MAX_VOICES - 1 do
    if FVHasSig[V] then
      for I := 0 to N - 1 do
      begin
        Gi := G0 + (G - G0) * (I + 1) / N;
        FVBuf[V, I * 2] := FVBuf[V, I * 2] * Gi;
        FVBuf[V, I * 2 + 1] := FVBuf[V, I * 2 + 1] * Gi;
      end;
end;

{ ADSR-Huellkurve fuer N Samples in Raw (Huellkurve) und Gain (= Raw * G). Statt jedes Sample zu
  verzweigen: je Stufe ausrechnen, wie viele Samples sie noch dauert, und den Abschnitt am Stueck im
  SIMD-Kern rechnen (Attack linear, Decay/Sustain/Release geometrisch zum Ziel). Gleiches Verhalten wie
  die frueheren Einzelschritte: Attack bis 1, Decay bis |E-S| < 0.001, Sustain naehert sich S (0,2 %
  je Sample), Release bis 0.0001, danach still. }
procedure TGranularEngine.RunEnvSegments(var E: Single; var Stage: TEnvStage; var StageTime: Integer; N: Integer;
  AttInc, DecK, Sus, RelK, G: Double; Raw, Gain: PSingle);
var
  Off, Rem, Nn, Seg, L: Integer;
  A: TEnvSegArgs;
  D, K, Kp: Double;
  Done: Boolean;

  function RawAt(I: Integer): PSingle;
  begin
    Result := PSingle(NativeUInt(Raw) + NativeUInt(I) * SizeOf(Single));
  end;

  function GainAt(I: Integer): PSingle;
  begin
    Result := PSingle(NativeUInt(Gain) + NativeUInt(I) * SizeOf(Single));
  end;

  { Abschnitt geometrisch zum Ziel T (Faktor K je Sample) bzw. linear (Schritt Inc) }
  procedure RunGeo(T, Start, Kf: Double; Cnt: Integer);
  var
    J: Integer;
  begin
    Kp := Kf;
    for J := 0 to 3 do
    begin
      A.Base4[J] := T;
      A.D4[J] := (Start - T) * Kp;
      Kp := Kp * Kf;
      A.Add4[J] := 0;
      A.G4[J] := G;
    end;
    Kp := Kf * Kf;
    Kp := Kp * Kp;
    for J := 0 to 3 do
      A.Mul4[J] := Kp;
    A.Raw := RawAt(Off);
    A.Gain := GainAt(Off);
    A.Count := (Cnt + 3) div 4;
    RenderEnvSeg(@A);
  end;

  procedure RunLin(Start, Inc_: Double; Cnt: Integer);
  var
    J: Integer;
  begin
    for J := 0 to 3 do
    begin
      A.Base4[J] := Start;
      A.D4[J] := Inc_ * (J + 1);
      A.Mul4[J] := 1;
      A.Add4[J] := Inc_ * 4;
      A.G4[J] := G;
    end;
    A.Raw := RawAt(Off);
    A.Gain := GainAt(Off);
    A.Count := (Cnt + 3) div 4;
    RenderEnvSeg(@A);
  end;

begin
  Off := 0;
  while Off < N do
  begin
    Rem := N - Off;
    Done := False;          // Stufe endet in diesem Abschnitt
    case Stage of
      esAttack:
        begin
          if AttInc <= 0 then
            Nn := 1
          else
            Nn := Max(1, Ceil(Min(1.0E9, (1 - E) / AttInc)));
          Seg := Min(Nn, Rem);
          RunLin(E, AttInc, Seg);
          if Nn <= Rem then
          begin
            RawAt(Off + Seg - 1)^ := 1;
            GainAt(Off + Seg - 1)^ := G;
            Stage := esDecay;
            Done := True;
          end;
        end;
      esDecay:
        begin
          D := Abs(E - Sus);
          K := DecK;
          if (D * K < 0.001) or (K <= 0) or (K >= 1) then
            Nn := 1
          else
            Nn := Max(1, Ceil(Min(1.0E9, Ln(0.001 / D) / Ln(K))));
          Seg := Min(Nn, Rem);
          RunGeo(Sus, E, K, Seg);
          if Nn <= Rem then
          begin
            Stage := esSustain;
            Done := True;
          end;
        end;
      esSustain:
        begin
          Seg := Rem;
          RunGeo(Sus, E, 0.998, Seg);
        end;
      esRelease:
        begin
          K := RelK;
          if (E * K < 0.0001) or (K <= 0) or (K >= 1) then
            Nn := 1
          else
            Nn := Max(1, Ceil(Min(1.0E9, Ln(0.0001 / E) / Ln(K))));
          Seg := Min(Nn, Rem);
          RunGeo(0, E, K, Seg);
          if Nn <= Rem then
          begin
            RawAt(Off + Seg - 1)^ := 0;
            GainAt(Off + Seg - 1)^ := 0;
            Stage := esIdle;
            Done := True;
          end;
        end;
    else
      begin
        Seg := Rem;
        for L := 0 to Seg - 1 do
        begin
          RawAt(Off + L)^ := 0;
          GainAt(Off + L)^ := 0;
        end;
      end;
    end;
    E := RawAt(Off + Seg - 1)^;
    if Done then
      StageTime := 0
    else
      Inc(StageTime, Seg);
    Inc(Off, Seg);
  end;
end;

{ alle Oszillatoren; FOscMix sammelt die mit eigenem Filter (an Filter 1/2 vorbei) }
procedure TGranularEngine.RenderOsc(N: Integer);
var
  O, V, I, Wave: Integer;
  NeedOs, Active, Draw: Boolean;
begin
  FOscOwnFlt := False;
  FillChar(FOsVUsed, SizeOf(FOsVUsed), 0);
  // Oversampling nur, wo Spiegelfrequenzen entstehen koennen: FM, klassische Dreieck/Saege/Rechteck und
  // alles mit Sync. Sinus und Wavetable-Wellen (schon bandbegrenzt) ohne Sync brauchen es nicht, Rauschen nie.
  // Gemeinsam fuer alle Oszillatoren (sonst waeren sie um die Filterlaufzeit gegeneinander verschoben) und
  // haltend, solange einer klingt (ein Wechsel mitten im Ton waere ein Sprung).
  if FOsOn then
  begin
    NeedOs := False;
    Active := False;
    for O := 0 to OSC_COUNT - 1 do
    begin
      if Eff(OSC_P[O].On_) < 0.5 then
        Continue;
      Draw := Eff(OSC_P[O].Draw) >= 0.5;
      Wave := EnsureRange(Round(Eff(OSC_P[O].Wave)), 0, 5);
      if not Draw and ((Wave = 4) or ((Wave in [1, 2, 3]) and (FParams[Ord(gpOscModel)] >= 0.5))) then
        NeedOs := True;     // FM; klassische Dreieck/Saege/Rechteck (Wavetable-Wellen sind schon bandbegrenzt)
      if Eff(OSC_P[O].Sync) > 0.001 then
        NeedOs := True;     // Sync: harter Neustart der Welle
      for V := 0 to MAX_VOICES - 1 do
        if FOsc[O, V].Stage <> esIdle then
        begin
          Active := True;
          if FVModOn[V] and (FVPlain[V, OSC_PND[O, OP_SYNC]] > 0.001) then
            NeedOs := True;
        end;
    end;
    if NeedOs then
      FOscOsGroup := True
    else if not Active then
      FOscOsGroup := False;
  end
  else
    FOscOsGroup := False;
  for O := 0 to OSC_COUNT - 1 do
    RenderOscOne(O, N);
  // Oversampling: je Stimme einmal zurueck auf die normale Rate, in den Puffer der Stimme
  for V := 0 to MAX_VOICES - 1 do
    if FOsVUsed[V] then
    begin
      HbDecimate(@FOsVW[V, 0], N, @FOsDec[0]);
      for I := 0 to N * 2 - 1 do
        FVBuf[V, I] := FVBuf[V, I] + FOsDec[I];
      Move(FOsVW[V, N * 2 * 2], FOsVW[V, 0], HB_HIST * 2 * 2 * SizeOf(Single));
    end;
end;

{ Stereobreite (Mitte/Seite) und Panorama (Balance mit gleicher Leistung) fuer die Summe }
procedure TGranularEngine.ProcessStereo(N: Integer);
var
  I: Integer;
  W, Pn, GL, GR, M, S, L, R: Single;
begin
  W := Eff(gpWidth) / 100;
  Pn := Eff(gpPan) / 100;
  if (Abs(W - 1) < 0.005) and (Abs(Pn) < 0.005) then
    Exit;
  // Balance: Mitte = 1/1, ganz links: L = sqrt2-Anteil, R = 0 (Gesamtleistung bleibt)
  GL := Sqrt(1 - Pn) * 1.0;
  GR := Sqrt(1 + Pn) * 1.0;
  if GL > 1 then GL := 1;
  if GR > 1 then GR := 1;
  for I := 0 to N - 1 do
  begin
    L := FMix[I * 2];
    R := FMix[I * 2 + 1];
    M := (L + R) * 0.5;
    S := (L - R) * 0.5 * W;
    FMix[I * 2] := (M + S) * GL;
    FMix[I * 2 + 1] := (M - S) * GR;
  end;
end;

procedure TGranularEngine.ProcessEq(N: Integer);
var
  I, P: Integer;
begin
  // Abgriff vor dem EQ fuer die Filteransicht (Mono-Summe)
  P := FScopePrePos;
  for I := 0 to N - 1 do
  begin
    FScopePre[P] := (FMix[I * 2] + FMix[I * 2 + 1]) * 0.5;
    P := (P + 1) and (SCOPE_SIZE - 1);
  end;
  FScopePrePos := P;
  if Eff(gpEqOn) < 0.5 then
  begin
    if FEqWasOn then
    begin
      FEq.Reset;
      FEqWasOn := False;
    end;
    Exit;
  end;
  FEqWasOn := True;
  FEq.Process(@FMix[0], N, FEqCurve, FEqVersion, Eff(gpEqBass), Eff(gpEqTreble),
    [Eff(gpEqAFreq), Eff(gpEqAGain), Eff(gpEqBFreq), Eff(gpEqBGain)]);
end;

procedure TGranularEngine.SatBuffer(P: PSingle; Count: Integer; Drive, Make: Single);
var
  I, Cnt: Integer;
begin
  for I := 0 to 3 do
  begin
    FSat.Drive4[I] := Drive;
    FSat.Make4[I] := Make;
  end;
  Cnt := Count and not 3;
  FSat.P := P;
  FSat.Count := Cnt;
  RenderSat(@FSat);
  if Cnt < Count then
  begin
    FSat.P := @PFloatArr(P)[Cnt];
    FSat.Count := Count - Cnt;
    SatBlockPas(@FSat);
  end;
end;

{ 2x abwaerts: W = Vorlauf (HB_HIST*2 Frames) + 2N neue Frames -> N Frames nach Dst.
  Ausgabe n ist um Frame HB_HIST*2 + 2n + 1 - 35 (2x) zentriert: der neueste Frame wird gerade noch benutzt. }
procedure TGranularEngine.HbDecimate(W: PSingle; N: Integer; Dst: PSingle);
const
  C0 = HB_HIST * 2 + 1 - (2 * HB_PAIRS - 1);
begin
  FHbDown.Out := PByte(Dst);
  FHbDown.PC := PByte(W) + C0 * 8;
  FHbDown.PD := PByte(W) + (C0 - 1) * 8;
  FHbDown.PA := PByte(W) + (C0 + 1) * 8;
  FHbDown.Count := N;
  FHbDown.InStep := 16;
  FHbDown.TapStep := 16;
  FHbDown.OutStep := 8;
  RenderHbFir(@FHbDown);
end;

{ Saettigung mit doppelter Rate: FMix -> aufwaerts (Halbband) -> Kennlinie -> abwaerts -> FMix.
  Laufzeit 35 Samples; der Vorlauf beider Filter steht in FDrvU/FDrvW. }
procedure TGranularEngine.DriveOs(N: Integer; Drive, Make: Single);
var
  I: Integer;
begin
  Move(FMix[0], FDrvU[HB_HIST * 2], N * 2 * SizeOf(Single));
  // gerade Ausgaben: Filter um x[n - 17.5]; ungerade: x[n - 17] (Mitte des Halbbands)
  FHbUp.Out := PByte(@FDrvW[HB_HIST * 2 * 2]);
  FHbUp.PD := PByte(@FDrvU[(HB_HIST - HB_PAIRS) * 2]);
  FHbUp.PA := PByte(@FDrvU[(HB_HIST - HB_PAIRS + 1) * 2]);
  FHbUp.PC := FHbUp.PD;
  FHbUp.Count := N;
  FHbUp.InStep := 8;
  FHbUp.TapStep := 8;
  FHbUp.OutStep := 16;
  RenderHbFir(@FHbUp);
  for I := 0 to N - 1 do
  begin
    FDrvW[(HB_HIST * 2 + I * 2 + 1) * 2] := FDrvU[(HB_HIST - HB_PAIRS + 1 + I) * 2];
    FDrvW[(HB_HIST * 2 + I * 2 + 1) * 2 + 1] := FDrvU[(HB_HIST - HB_PAIRS + 1 + I) * 2 + 1];
  end;
  SatBuffer(@FDrvW[HB_HIST * 2 * 2], N * 2 * 2, Drive, Make);
  HbDecimate(@FDrvW[0], N, @FMix[0]);
  Move(FDrvU[N * 2], FDrvU[0], HB_HIST * 2 * SizeOf(Single));
  Move(FDrvW[N * 2 * 2], FDrvW[0], HB_HIST * 2 * 2 * SizeOf(Single));
end;

procedure TGranularEngine.ProcessDrive(N: Integer);
var
  A, Drive, Make, T: Single;
  I, Mode: Integer;
begin
  A := Eff(gpDrive) / 100;
  if A <= 0.001 then
    Mode := 0
  else if FOsOn then
    Mode := 2
  else
    Mode := 1;
  // Antrieb 1 .. 16fach, Ausgleich haelt die Lautheit etwa gleich
  Drive := 1 + 15 * A * A;
  Make := 1 / Sqrt(Drive) * (1 + 0.35 * A);
  if (Mode <> 2) and (FDrvMode <> 2) then
  begin
    if Mode = 1 then
      SatBuffer(@FMix[0], N * 2, Drive, Make);
    FDrvMode := Mode;
    Exit;
  end;
  if Mode = FDrvMode then
  begin
    DriveOs(N, Drive, Make);
    Exit;
  end;
  // Wechsel von/zu Oversampling (andere Laufzeit): ueber den Block ueberblenden statt springen
  if Mode = 2 then
  begin
    FillChar(FDrvU, SizeOf(FDrvU), 0);
    FillChar(FDrvW, SizeOf(FDrvW), 0);
  end;
  Move(FMix[0], FDrvAlt[0], N * 2 * SizeOf(Single));
  if Mode = 1 then
    SatBuffer(@FDrvAlt[0], N * 2, Drive, Make);
  DriveOs(N, Drive, Make);              // FMix = Oversampling-Pfad
  for I := 0 to N - 1 do
  begin
    T := (I + 1) / N;                   // Anteil des neuen Pfads
    if Mode <> 2 then
      T := 1 - T;
    FMix[I * 2] := FDrvAlt[I * 2] + (FMix[I * 2] - FDrvAlt[I * 2]) * T;
    FMix[I * 2 + 1] := FDrvAlt[I * 2 + 1] + (FMix[I * 2 + 1] - FDrvAlt[I * 2 + 1]) * T;
  end;
  FDrvMode := Mode;
end;

function TGranularEngine.EnsureMorphLayer: TGranularEngine;
begin
  if FLayerB = nil then
  begin
    FLayerB := TGranularEngine.Create;
    FLayerB.SetSampleRate(FSampleRate);
    SetLength(FLayerBuf, 4096 * 2);
    SetLength(FGainBs, 4096 div SUB_BLOCK + 1);
    SetLength(FGainBe, 4096 div SUB_BLOCK + 1);
  end;
  Result := FLayerB;
end;

function TGranularEngine.LayerMode: Boolean;
begin
  Result := FMorphValid and (FLayerB <> nil) and (ParamStep(Ord(gpMorphMode), FParams[Ord(gpMorphMode)]) = 1);
end;

{ vollstaendiger Klangzustand (ohne Sample und ohne eigenes Morph-Ziel) in eine andere Engine }
procedure TGranularEngine.CopyStateTo(Dst: TGranularEngine);
var
  I: Integer;
begin
  for I := 0 to PARAM_COUNT - 1 do
    Dst.FParams[I] := FParams[I];
  for I := 0 to NAMED_COUNT - 1 do
    Dst.FEff[I] := FParams[I];     // gilt sofort (Arp an/aus) - auch fuer den ersten Anschlag
  for I := 0 to 4 do
    Dst.FFree[I] := FFree[I];
  for I := 0 to OSC_COUNT - 1 do
  begin
    Dst.FOscDraw[I] := FOscDraw[I];
    if FWtPtr[I] = @GWtDefault[0] then
      Dst.FWtPtr[I] := @GWtDefault[0]       // Startwelle: gemeinsame Tabelle, nichts zu rechnen
    else
      Dst.OscDrawChanged(I);
  end;
  Dst.FArpMask := FArpMask;
  Dst.EqCurve^ := EqCurve^;
  Dst.EqChanged;
  Dst.FMorphValid := False;
end;

function TGranularEngine.MorphBValue(Id: TGranularParamId): Single;
begin
  Result := FMorphB[Ord(Id)];
end;

procedure TGranularEngine.SyncMorphFromLayer;
var
  I: Integer;
begin
  if FLayerB = nil then
    Exit;
  for I := 0 to NAMED_COUNT - 1 do
    FMorphB[I] := FLayerB.FParams[I];
  FMorphValid := True;
end;

procedure TGranularEngine.StoreMorphTarget;
begin
  FSwapped := False;
  FLock.Enter;
  try
    CopyStateTo(EnsureMorphLayer);
    FLayerB.ResetAll;
    SyncMorphFromLayer;
  finally
    FLock.Leave;
  end;
end;

procedure TGranularEngine.SetMorphFromEngine(Src: TGranularEngine);
begin
  FSwapped := False;
  FLock.Enter;
  try
    Src.CopyStateTo(EnsureMorphLayer);
    FLayerB.ResetAll;
    SyncMorphFromLayer;
  finally
    FLock.Leave;
  end;
end;

{ nur benannte Werte (aeltere Presets): Rest (Matrix, freie LFOs, Arp-Muster) wie A }
procedure TGranularEngine.SetMorphTarget(const Values: array of Single);
var
  I: Integer;
begin
  FSwapped := False;
  CopyStateTo(EnsureMorphLayer);
  for I := 0 to Min(High(Values), NAMED_COUNT - 1) do
    if not IdIn(TGranularParamId(I), [gpMaster, gpTempo]) then
      FLayerB.FParams[I] := EnsureRange(Values[I], 0, 1);
  SyncMorphFromLayer;
end;

procedure TGranularEngine.ClearMorphTarget;
begin
  FMorphValid := False;
  FMorphSampleRef := '';
  FSwapped := False;
end;

function TGranularEngine.SwapMorphAB: Boolean;
const
  KEEP: array[0..7] of TGranularParamId = (gpMaster, gpTempo, gpMorph, gpMorphMode,
    gpMorphLfoShape, gpMorphLfoRate, gpMorphLfoSync, gpMorphLfoDepth);   // gehoeren zu keinem der beiden Klaenge
var
  I: Integer;
  T: Single;
  F: TFreeLfo;
  Dw: TOscDraw;
  Wb: TArray<Single>;
  Wp: PSingle;
  Wc: Integer;
  M: Cardinal;
  Eq: TEqCurve;
  Smp: TSampleData;
  D: Double;
  S: string;
begin
  Result := False;
  if not FMorphValid or (FLayerB = nil) then
    Exit;
  FLock.Enter;
  try
    for I := 0 to PARAM_COUNT - 1 do
      if (I >= NAMED_COUNT) or not IdIn(TGranularParamId(I), KEEP) then
      begin
        T := FParams[I];
        FParams[I] := FLayerB.FParams[I];
        FLayerB.FParams[I] := T;
      end;
    FParams[Ord(gpMorph)] := 1 - FParams[Ord(gpMorph)];      // gleiche Mischung, nur von der anderen Seite
    for I := 0 to 4 do
      if I <> 2 then                                         // 2 = Morph-LFO (bleibt)
      begin
        F := FFree[I];
        FFree[I] := FLayerB.FFree[I];
        FLayerB.FFree[I] := F;
      end;
    M := FArpMask; FArpMask := FLayerB.FArpMask; FLayerB.FArpMask := M;
    for I := 0 to OSC_COUNT - 1 do
    begin
      // Zeichnung und fertige Tabellen tauschen die Plaetze (nichts neu zu rechnen)
      Dw := FOscDraw[I]; FOscDraw[I] := FLayerB.FOscDraw[I]; FLayerB.FOscDraw[I] := Dw;
      Wb := FWtBuf[I, 0]; FWtBuf[I, 0] := FLayerB.FWtBuf[I, 0]; FLayerB.FWtBuf[I, 0] := Wb;
      Wb := FWtBuf[I, 1]; FWtBuf[I, 1] := FLayerB.FWtBuf[I, 1]; FLayerB.FWtBuf[I, 1] := Wb;
      Wp := FWtPtr[I]; FWtPtr[I] := FLayerB.FWtPtr[I]; FLayerB.FWtPtr[I] := Wp;
      Wc := FWtCur[I]; FWtCur[I] := FLayerB.FWtCur[I]; FLayerB.FWtCur[I] := Wc;
    end;
    Eq := EqCurve^; EqCurve^ := FLayerB.EqCurve^; FLayerB.EqCurve^ := Eq;
    EqChanged;
    FLayerB.EqChanged;
    // eigenes B-Sample: Plaetze tauschen (sonst spielen beide dasselbe Sample)
    ResRestore;
    if FSampleB <> nil then
    begin
      Smp := FSample; FSample := FSampleB; FSampleB := Smp;
      D := FRootA; FRootA := FRootB; FRootB := D;
      D := FTuneA; FTuneA := FTuneB; FTuneB := D;
      S := FSamplePath; FSamplePath := FMorphSampleLoaded; FMorphSampleLoaded := S;
    end;
    for I := 0 to NAMED_COUNT - 1 do
    begin
      FEff[I] := FParams[I];
      FLayerB.FEff[I] := FLayerB.FParams[I];
    end;
    ResetAll;
    FLayerB.ResetAll;
    SyncMorphFromLayer;
    FSwapped := not FSwapped;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TGranularEngine.SetMorphSample(Data: TSampleData; const LoadedFile: string);
var
  Old: TSampleData;
  I: Integer;
  Root, Tune: Double;
begin
  DetectRoot(Data, Root, Tune);
  FLock.Enter;
  try
    // laufende B-Grains beenden (sie zeigen in das alte Sample)
    for I := FActiveGrains - 1 downto 0 do
      if FGrains[FActList[I]].UseB then
        GrainFree(FActList[I]);
    Old := FSampleB;
    if (Data <> nil) and (Data.Frames < 8) then
      FreeAndNil(Data);
    FSampleB := Data;
    FRootB := Root;
    FTuneB := Tune;
    FMorphSampleLoaded := LoadedFile;
  finally
    FLock.Leave;
  end;
  Old.Free;
end;

function TGranularEngine.GetMorphTarget(var Values: array of Single): Boolean;
var
  I: Integer;
begin
  Result := FMorphValid;
  if Result then
    for I := 0 to Min(High(Values), NAMED_COUNT - 1) do
      Values[I] := FMorphB[I];
end;

procedure TGranularEngine.ProcessReverb(N: Integer);
var
  Mix: Double;
begin
  if Eff(gpRevOn) < 0.5 then
  begin
    if FRevWasOn then
    begin
      FReverb.Clear;   // beim Wiedereinschalten kein alter Nachhall
      FRevWasOn := False;
    end;
    Exit;
  end;
  FRevWasOn := True;
  Mix := Eff(gpRevMix) / 100;
  FReverb.LowCut := Eff(gpRevLowCut);
  FReverb.HighCut := Eff(gpRevHighCut);
  FReverb.Process(@FMix[0], N, Eff(gpRevSize) / 100, Eff(gpRevDecay), Eff(gpRevDamp) / 100,
    Eff(gpRevPreDelay), Eff(gpRevWidth) / 100, Mix, FFreeze, Round(Eff(gpRevRoom)));
end;

{ Makros: 50 % = neutral. Jedes Makro verschiebt mehrere Wirkwerte musikalisch sinnvoll
  (im Reglerbereich, also Zeiten/Groessen logarithmisch). Nicht destruktiv: das Preset
  bleibt unveraendert, nur die Wirkung wird verschoben. }
procedure TGranularEngine.ApplyMacros;

  procedure Add(Id: TGranularParamId; Delta: Double);
  begin
    FEff[Ord(Id)] := FEff[Ord(Id)] + Delta;
  end;

var
  D: Double;
begin
  // Textur: klein/dicht/koernig  <->  gross/weich/flaechig
  D := FEff[Ord(gpMacroTexture)] - 0.5;
  Add(gpGrainSize, D * 0.9);
  Add(gpDensity, -D * 0.4);
  Add(gpSpray, D * 0.2);
  // Bewegung: steht still  <->  wandert und schwebt
  D := FEff[Ord(gpMacroMotion)] - 0.5;
  Add(gpScan, D * 0.3);
  Add(gpSpray, D * 0.3);
  Add(gpLfo1Rate, D * 0.5);
  Add(gpLfo2Rate, D * 0.5);
  // Helligkeit: dunkel  <->  hell (Filter, Echo-Daempfung, Fenster-Haerte bleibt)
  D := FEff[Ord(gpMacroBright)] - 0.5;
  Add(gpFltCutoff, D * 0.8);
  Add(gpEchoDamp, -D * 0.8);
  // Raum: trocken/schmal  <->  weit mit Echo (schaltet Echo ab ca. 55 % zu)
  D := FEff[Ord(gpMacroSpace)] - 0.5;
  Add(gpRevMix, D * 0.5);
  Add(gpRevDecay, D * 0.3);
  Add(gpSpread, D * 1.2);
  Add(gpEchoMix, D * 0.9);
  Add(gpEchoFeedback, D * 0.5);
  if D > 0.05 then
    FEff[Ord(gpEchoOn)] := 1;
  // Streuung: geordnet  <->  zufaellig (Tonhoehe, Rueckwaerts, Position)
  D := FEff[Ord(gpMacroScatter)] - 0.5;
  Add(gpPitchRand, D * 0.4);
  Add(gpReverse, D * 0.8);
  Add(gpSpray, D * 0.5);
  // Huellkurven-Laenge: perkussiv  <->  langsam einschwingend/lang ausklingend
  D := FEff[Ord(gpMacroEnv)] - 0.5;
  Add(gpAttack, D * 0.6);
  Add(gpDecay, D * 0.4);
  Add(gpRelease, D * 0.6);
  Add(gpFltAttack, D * 0.4);
  Add(gpFltRelease, D * 0.4);
end;

{ Spitzenlimiter, Stereo gekoppelt: sehr schneller Attack (~0,3 ms), weicher Release
  (~120 ms), Schwelle -1 dBFS. Danach harte Sicherung bei 0,99 gegen Restueberschwinger. }
{ Ausgangsstufe: Limiter mit Vorausschau + weicher Clipper (immer aktiv).
  - Das Signal wird um LIM_LOOK Samples verzoegert. Die noetige Absenkung wird am Eingang
    bestimmt, gehalten (Hold = Vorausschau) und mit einer Attack-Zeit kleiner als die Vorausschau
    angefahren -> die Verstaerkung ist schon unten, wenn die Spitze am Ausgang ankommt (kein
    Ueberschiessen, kein Knacken).
  - Weicher Clipper als letzte Sicherung, auch bei ausgeschaltetem Limiter: unterhalb von
    SOFT_KNEE unveraendert, darueber sanft (tanh-artig) gegen SOFT_MAX gerundet - nie 0 dBFS,
    keine Knicke in der Wellenform. }
procedure TGranularEngine.ProcessLimiter(N: Integer);
const
  THRESHOLD = 0.85;    // ca. -1,4 dBFS
  SOFT_KNEE = 0.80;
  SOFT_MAX = 0.98;
var
  I, P, HoldCnt, Clip: Integer;
  Peak, Target, AttC, RelC, G, L, R, DL, DR, Hold, GMin, A, T: Double;
  LimOn, Quiet: Boolean;
  M: Single;
begin
  LimOn := Eff(gpLimiter) >= 0.5;
  G := FLimGain;
  P := FLimPos;
  // Ruhe-Pfad: Limiter ganz offen und alles (Block und Vorausschau) unter dem Knie -> das Ergebnis ist
  // exakt das um LIM_LOOK verzoegerte Signal (Absenkung 1, Soft-Clip wirkungslos): nur umkopieren
  Quiet := not LimOn or ((G = 1) and (FLimHold = 1));
  if Quiet then
  begin
    M := 0;
    for I := 0 to N * 2 - 1 do
      if Abs(FMix[I]) > M then M := Abs(FMix[I]);
    for I := 0 to LIM_LOOK * 2 - 1 do
      if Abs(FLimBuf[I]) > M then M := Abs(FLimBuf[I]);
    Quiet := M <= SOFT_KNEE;
  end;
  if Quiet then
  begin
    for I := 0 to N - 1 do
    begin
      DL := FLimBuf[P * 2];
      DR := FLimBuf[P * 2 + 1];
      FLimBuf[P * 2] := FMix[I * 2];
      FLimBuf[P * 2 + 1] := FMix[I * 2 + 1];
      Inc(P);
      if P >= LIM_LOOK then P := 0;
      FMix[I * 2] := DL;
      FMix[I * 2 + 1] := DR;
    end;
    if LimOn then
      FLimHoldCnt := LIM_LOOK     // wie im vollen Pfad: Ziel 1 <= Halten 1 setzt den Zaehler jedes Sample
    else
      FLimGain := 1;              // Limiter aus: voller Pfad setzt die Absenkung auf 1
    FLimPos := P;
    Exit;
  end;
  AttC := 1 - Exp(-5 / LIM_LOOK);                      // ~99 % innerhalb der Vorausschau
  RelC := 1 - Exp(-1 / (0.15 * FSampleRate));
  // Zustand in lokalen Variablen (Register statt Klassenfelder je Sample)
  Hold := FLimHold;
  HoldCnt := FLimHoldCnt;
  GMin := FLimMin;
  Clip := 0;
  for I := 0 to N - 1 do
  begin
    L := FMix[I * 2];
    R := FMix[I * 2 + 1];
    // Vorausschau: neues Sample rein, verzoegertes raus
    DL := FLimBuf[P * 2];
    DR := FLimBuf[P * 2 + 1];
    FLimBuf[P * 2] := L;
    FLimBuf[P * 2 + 1] := R;
    Inc(P);
    if P >= LIM_LOOK then P := 0;
    if LimOn then
    begin
      Peak := Max(Abs(L), Abs(R));
      if Peak > THRESHOLD then Target := THRESHOLD / Peak else Target := 1;
      // Hold: die tiefste Absenkung der Vorausschau halten, erst danach loslassen
      if Target <= Hold then
      begin
        Hold := Target;
        HoldCnt := LIM_LOOK;
      end
      else if HoldCnt > 0 then
        Dec(HoldCnt)
      else
        Hold := Target;
      if Hold < G then
        G := G + (Hold - G) * AttC
      else
        G := G + (Hold - G) * RelC;
      DL := DL * G;
      DR := DR * G;
      if G < GMin then
        GMin := G;
    end
    else
      G := 1;
    if (Abs(DL) > SOFT_KNEE) or (Abs(DR) > SOFT_KNEE) then
      Inc(Clip);
    // Soft-Clip (rationale tanh-Naeherung oberhalb des Knies), eingebaut statt Funktionsaufruf
    A := Abs(DL);
    if A > SOFT_KNEE then
    begin
      T := (A - SOFT_KNEE) / (SOFT_MAX - SOFT_KNEE);
      if T > 3 then T := 3;
      T := T * (27 + T * T) / (27 + 9 * T * T);
      A := SOFT_KNEE + (SOFT_MAX - SOFT_KNEE) * T;
      if DL < 0 then DL := -A else DL := A;
    end;
    A := Abs(DR);
    if A > SOFT_KNEE then
    begin
      T := (A - SOFT_KNEE) / (SOFT_MAX - SOFT_KNEE);
      if T > 3 then T := 3;
      T := T * (27 + T * T) / (27 + 9 * T * T);
      A := SOFT_KNEE + (SOFT_MAX - SOFT_KNEE) * T;
      if DR < 0 then DR := -A else DR := A;
    end;
    FMix[I * 2] := DL;
    FMix[I * 2 + 1] := DR;
  end;
  FLimHold := Hold;
  FLimHoldCnt := HoldCnt;
  FLimMin := GMin;
  Inc(FClipCount, Clip);
  FLimGain := G;
  FLimPos := P;
end;

function TGranularEngine.TakeMidiCount: Integer;
begin
  Result := AtomicExchange(FMidiCount, 0);
end;

function TGranularEngine.TakeClipCount: Integer;
begin
  Result := AtomicExchange(FClipCount, 0);
end;

function TGranularEngine.TakeLimiterReduction: Single;
begin
  Result := 20 * Log10(Max(FLimMin, 1E-6));
  FLimMin := 1;
end;

procedure TGranularEngine.LogTrig(Kind: TTrigLogKind; Lfo, Arg: Integer; Val, Val2: Single);
var
  P: Integer;
begin
  if not FLogOn then
    Exit;
  P := FLogWrite and High(FLog);
  FLog[P].Time := FLogClock / Max(1, FSampleRate);
  FLog[P].Kind := Kind;
  FLog[P].Lfo := Lfo;
  FLog[P].Arg := Arg;
  FLog[P].Val := Val;
  FLog[P].Val2 := Val2;
  FLogWrite := FLogWrite + 1;   // erst nach dem Eintrag weiterzaehlen (Leser im GUI-Thread)
end;

function TGranularEngine.ReadTriggerLog(var Pos: Integer): TArray<TTrigLogItem>;
var
  W, I: Integer;
begin
  W := FLogWrite;
  if W - Pos > Length(FLog) then
    Pos := W - Length(FLog);
  SetLength(Result, Max(0, W - Pos));
  for I := 0 to High(Result) do
    Result[I] := FLog[(Pos + I) and High(FLog)];
  Pos := W;
end;

function TGranularEngine.GetOscEnvState(Fm: Boolean; Osc: Integer): TEnvelopeState;
var
  V: Integer;
begin
  V := EnsureRange(FOscLast, 0, MAX_VOICES - 1);
  Result.Active := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].Stage <> esIdle;
  if Fm then
  begin
    Result.Stage := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].FmStage;
    Result.StageSeconds := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].FmStageTime / FSampleRate;
    Result.Level := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].FmEnv;
  end
  else
  begin
    Result.Stage := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].Stage;
    Result.StageSeconds := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].StageTime / FSampleRate;
    Result.Level := FOsc[EnsureRange(Osc, 0, OSC_COUNT - 1), V].Env;
  end;
  if not Result.Active then
    Result.Stage := esIdle;
end;

function TGranularEngine.GetFilterEnvState: TEnvelopeState;
begin
  Result.Active := FFltStage <> esIdle;
  Result.Stage := FFltStage;
  Result.StageSeconds := FFltStageTime / FSampleRate;
  Result.Level := FFltEnv;
end;

function TGranularEngine.GetPlayheads(var Positions: array of Single): Integer;
var
  V: Integer;
  P: Double;
begin
  Result := 0;
  if FSample = nil then
    Exit;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage <> esIdle) and (Result <= High(Positions)) then
    begin
      P := FVoices[V].ScanPos + FPosition;
      if not FVoices[V].InPre or (P >= 1) then
        P := P - Floor(P);
      Positions[Result] := (FSel0 + P * FSelLen) / FSample.Frames;
      Inc(Result);
    end;
end;

function TGranularEngine.GetRecentGrains(var Positions: array of Single): Integer;
var
  I, Idx, Start: Integer;
begin
  // neueste zuerst
  Result := 0;
  Start := FHistoryPos;
  for I := 1 to GRAIN_HISTORY do
  begin
    if Result > High(Positions) then
      Break;
    Idx := (Start - I + GRAIN_HISTORY) mod GRAIN_HISTORY;
    Positions[Result] := FHistory[Idx];
    Inc(Result);
  end;
end;

procedure TGranularEngine.GetActiveNotes(var States: array of Byte);
var
  V, N, L: Integer;
begin
  FillChar(States[0], Length(States), 0);
  for V := 0 to MAX_VOICES - 1 do
  begin
    N := FVoices[V].Note;
    if (N < 0) or (N > High(States)) then
      Continue;
    case FVoices[V].Stage of
      esAttack, esDecay, esSustain:
        L := EnsureRange(Round(FVoices[V].Velocity * 255), 50, 255);
      esRelease:
        L := EnsureRange(Round(FVoices[V].Velocity * 128), 25, 128);
    else
      L := 0;
    end;
    if L > States[N] then
      States[N] := L;
  end;
end;

function TGranularEngine.GetEnvelopeState: TEnvelopeState;
var
  V, Best: Integer;
  BestStamp: Int64;
begin
  // juengste aktive Stimme
  Best := -1;
  BestStamp := -1;
  for V := 0 to MAX_VOICES - 1 do
    if (FVoices[V].Stage <> esIdle) and (FVoices[V].Stamp > BestStamp) then
    begin
      BestStamp := FVoices[V].Stamp;
      Best := V;
    end;
  Result.Active := Best >= 0;
  if Result.Active then
  begin
    Result.Stage := FVoices[Best].Stage;
    Result.StageSeconds := FVoices[Best].StageTime / FSampleRate;
    Result.Level := FVoices[Best].Env;
  end
  else
  begin
    Result.Stage := esIdle;
    Result.StageSeconds := 0;
    Result.Level := 0;
  end;
end;

end.
