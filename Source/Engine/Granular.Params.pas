{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Params;

{ Parameterdefinitionen des Granular-Synthesizers.
  Alle Parameter werden intern normalisiert (0..1) gehalten - exakt wie VST2
  (getParameter/setParameter). Die Umrechnung in Klartextwerte passiert nur hier.

  Indexraum:  0 .. NAMED_COUNT-1           benannte Parameter (TGranularParamId)
              MATRIX_BASE .. PARAM_COUNT-1  Modulationsmatrix (je Slot: Quelle, Ziel, Menge) }

interface

type
  TParamCurve = (pcLinear, pcExp, pcStepped, pcDecibel);

  TGranularParamId = (
    gpSelStart,    // Auswahlbereich Anfang (Anteil am Sample)
    gpSelEnd,      // Auswahlbereich Ende
    gpPosition,    // Startposition innerhalb der Auswahl
    gpSpray,       // Zufallsstreuung der Position
    gpScan,        // Scan-Geschwindigkeit (1 = Originaltempo, 0 = eingefroren)
    gpGrainSize,   // Graingroesse ms
    gpDensity,     // Grains pro Sekunde
    gpPitch,       // Tonhoehe Halbtoene
    gpPitchRand,   // Tonhoehen-Zufall Halbtoene
    gpSpread,      // Stereobreite (zufaelliges Panning je Grain)
    gpReverse,     // Wahrscheinlichkeit rueckwaerts
    gpWindow,      // Fensterform
    gpAttack,      // Huellkurve
    gpRelease,
    gpVolume,      // Lautstaerke dB
    gpKeyTrack,    // Tastatur steuert Tonhoehe
    gpDecay,
    gpSustain,
    gpLfo1Rate, gpLfo1Shape, gpLfo1Sync,
    gpLfo2Rate, gpLfo2Shape, gpLfo2Sync,
    gpScGain,      // Sidechain-Hüllkurvenfolger
    gpScAttack,
    gpScRelease,
    gpFltType,     // Filter: Tiefpass / Bandpass / Hochpass
    gpFltCutoff,
    gpFltReso,
    gpFltContour,  // Kontur = wie stark der Filter wirkt (Trocken/Gefiltert)
    gpFltEnvAmt,   // Filter-Huellkurve -> Cutoff, bipolar, +-6 Oktaven
    gpFltAttack, gpFltDecay, gpFltSustain, gpFltRelease,
    gpEchoTime,    // ms bzw. Notenwert bei Sync
    gpEchoSync,
    gpEchoFeedback,
    gpEchoDamp,    // Daempfung (Tiefpass) im Rueckkopplungsweg
    gpEchoPingPong,
    gpEchoMix,
    gpEchoPitch,   // Tonhoehenaenderung je Wiederholung (Pitch-Echo)
    gpFltOn,       // Filter ein/aus
    gpEchoOn,      // Echo ein/aus
    gpLfo1Trig,    // LFO-Neustart: frei / Note an / Note aus / an+aus
    gpLfo2Trig,
    gpLfo1Once,    // LFO laeuft nach dem Neustart nur einen Durchlauf und bleibt am Ende stehen
    gpLfo2Once,
    gpBendRange,   // Pitchbend-Bereich in Halbtoenen
    gpQuality,     // Interpolation: Standard (linear) / HQ (Hermite)
    gpLimiter,     // Ausgangslimiter an/aus
    gpMacroTexture, gpMacroMotion, gpMacroBright, gpMacroSpace, gpMacroScatter, gpMacroEnv,
    gpScPitchMode, // Auto-Pitch: Grains folgen der Tonhoehe des Sidechains
    gpRevOn,       // Hall (FDN) an/aus
    gpRevSize, gpRevDecay, gpRevDamp, gpRevPreDelay, gpRevWidth, gpRevMix,
    gpScale,       // Tonleiter-Raster fuer alle Tonhoehen (Aus = frei)
    gpScaleRoot,   // Grundton der Tonleiter
    gpMorph,       // Ueberblendung zum gemerkten Morph-Ziel B
    gpFreeze,      // Halten: Scan steht, Hall klingt unendlich
    gpDrive,       // Saettigung (weiches Clipping vor dem Limiter)
    gpArpOn,       // Arpeggiator an/aus
    gpArpMode,     // Richtung: hoch, runter, hoch/runter, ...
    gpArpOct,      // Oktavbereich 1..4
    gpArpRate,     // Notenwert je Schritt (zum Tempo)
    gpArpGate,     // Notenlaenge in % des Schritts
    gpArpSwing,    // Swing: gerade Schritte laenger, ungerade kuerzer
    gpArpSteps,    // Laenge des Schrittmusters 1..16
    gpScTrigLevel, // Schwelle fuer den LFO-Trigger 'SC-Pegel > Schwelle'
    gpScTrigNote,  // Schwelle fuer den LFO-Trigger 'SC-Ton > Schwelle' (MIDI-Note)
    gpGateSrc,     // Schwellen-Tor: beobachtete Quelle
    gpGateThresh,  // Schwellen-Tor: Schwelle
    gpGateQuiet,   // Ruhe-Ereignis: so lange muss die Quelle unter der Schwelle bleiben
    gpMorphLfoShape, // eigener Morph-LFO (wird selbst nicht gemorpht): Aus/Sinus/.../Frei
    gpMorphLfoRate, gpMorphLfoSync, gpMorphLfoDepth,
    gpAutoTune,    // Auto-Stimmung: Grundton des Samples erkennen und auf den C-Bezug ziehen
    gpEqOn, gpEqBass, gpEqTreble,   // grafischer Equalizer an, Bass-/Hoehen-Shelf (automatisierbar)
    gpWidth,       // Stereobreite der Summe (Mitte/Seite), 0 = mono, 100 = unveraendert, 200 = extra breit
    gpPan,         // Panorama der Summe (links/rechts), per LFO/Matrix bewegbar
    gpRevRoom,     // Raum-Material des Halls (Klangfarbe der Waende)
    // Oszillator-Schicht (je Note, gemischt mit den Grains)
    gpOscOn, gpOscWave, gpOscOct, gpOscFine, gpOscLevel, gpOscPan, gpOscFmRatio, gpOscFmAmt,
    gpOscAttack, gpOscDecay, gpOscSustain, gpOscRelease,
    gpOscFltOn, gpOscFltType, gpOscFltCutoff, gpOscFltReso, gpOscFltContour, gpOscFltEnvAmt,   // eigener Filter des Oszillators
    gpOscFmEnvOn, gpOscFmAttack, gpOscFmDecay, gpOscFmSustain, gpOscFmRelease,   // eigene FM-Huellkurve (aus = folgt der Lautstaerke)
    // LFO 3 und 4 (voller Funktionsumfang wie LFO 1/2)
    gpLfo3Rate, gpLfo3Shape, gpLfo3Sync, gpLfo3Trig, gpLfo3Once,
    gpLfo4Rate, gpLfo4Shape, gpLfo4Sync, gpLfo4Trig, gpLfo4Once,
    // zweiter Filter (gleiche Einstellungen), in Reihe oder parallel zum ersten
    gpFlt2On, gpFltRouting, gpFlt2Type, gpFlt2Cutoff, gpFlt2Reso, gpFlt2Contour, gpFlt2EnvAmt,
    // zwei frei setzbare EQ-Baender (Matrix-Ziele: z.B. Frequenz wegducken per Sidechain)
    gpEqAFreq, gpEqAGain, gpEqBFreq, gpEqBGain,
    gpScUseLevel, gpScUsePitch, // Sidechain-Trigger: Bedingungen Pegel / Ton (beide an = beide muessen erfuellt sein)
    gpOutTrigLevel, // Schwelle fuer den LFO-Trigger 'Ausgang > Schwelle' (eigener Ausgangspegel)
    gpGrainOct,    // Oktave der Grains (-4 .. +4), zusaetzlich zu Pitch
    gpGrainPan,    // Panorama nur der Grains (Oszillator hat 'Osz Panorama', Summe 'Summen-Panorama')
    gpGrainOn,     // Grains an (aus = nur Oszillator: klassischer Synthesizer)
    gpOscSync,     // Oszillator Hard Sync: 0 = saubere Welle, hoeher = immer mehr Obertoene
    gpGlideMode, gpGlideTime,   // Portamento: Aus / immer / nur legato, Dauer des Gleitens
    gpGrainLevel,  // Pegel nur der Grains (Lautstaerke = Summe aus Grains und Oszillatoren)
    gpMorphMode,   // Morph-Art: 0 = Werte ueberblenden (ein Klang), 1 = zwei getrennte Klaenge A und B
    // Oszillator 2 (gleicher Aufbau wie Oszillator 1)
    gpOsc2On, gpOsc2Wave, gpOsc2Oct, gpOsc2Fine, gpOsc2Level, gpOsc2Pan, gpOsc2FmRatio, gpOsc2FmAmt,
    gpOsc2Sync, gpOsc2Attack, gpOsc2Decay, gpOsc2Sustain, gpOsc2Release, gpOsc2FltOn, gpOsc2FltType,
    gpOsc2FltCutoff, gpOsc2FltReso, gpOsc2FltContour, gpOsc2FltEnvAmt, gpOsc2FmEnvOn, gpOsc2FmAttack,
    gpOsc2FmDecay, gpOsc2FmSustain, gpOsc2FmRelease,
    // Oszillator 3 (gleicher Aufbau wie Oszillator 1)
    gpOsc3On, gpOsc3Wave, gpOsc3Oct, gpOsc3Fine, gpOsc3Level, gpOsc3Pan, gpOsc3FmRatio, gpOsc3FmAmt,
    gpOsc3Sync, gpOsc3Attack, gpOsc3Decay, gpOsc3Sustain, gpOsc3Release, gpOsc3FltOn, gpOsc3FltType,
    gpOsc3FltCutoff, gpOsc3FltReso, gpOsc3FltContour, gpOsc3FltEnvAmt, gpOsc3FmEnvOn, gpOsc3FmAttack,
    gpOsc3FmDecay, gpOsc3FmSustain, gpOsc3FmRelease,
    // Ereignis-Verzoegerung (Reiter Timing / Events): je Ereignisart ms oder Notenwert (Takt <> Aus gewinnt)
    gpDlyOn, gpDlyOnSync, gpDlyOff, gpDlyOffSync, gpDlyEnd, gpDlyEndSync, gpDlySc, gpDlyScSync,
    gpDlyScPitch, gpDlyScPitchSync, gpDlyGate, gpDlyGateSync, gpDlyQuiet, gpDlyQuietSync, gpDlyOut, gpDlyOutSync,
    // Aus-Trigger je LFO: Ereignis, das den LFO anhaelt (0 = nie, sonst Ereignis 0..7 + 1)
    gpLfo1Stop, gpLfo2Stop, gpLfo3Stop, gpLfo4Stop,
    // Stopp 'nach Zeit': Laufzeit ab dem Start, ms oder Notenwert (Takt <> Aus gewinnt)
    gpLfo1StopMs, gpLfo1StopSync, gpLfo2StopMs, gpLfo2StopSync,
    gpLfo3StopMs, gpLfo3StopSync, gpLfo4StopMs, gpLfo4StopSync,
    // Partner je LFO: dessen Einmal-Ende ist das Ereignis 'Ende Partner-LFO' (Start und Stopp)
    gpLfo1Partner, gpLfo2Partner, gpLfo3Partner, gpLfo4Partner,
    gpArpLatch,    // Arp Latch: losgelassene Tasten spielen weiter, bis neue Tasten kommen
    gpSc1Input, gpSc2Input,   // VST-Eingangspaar fuer Sidechain 1 / 2 (aus, Eingang 1/2, Eingang 3/4)
    // Unison je Oszillator: Stimmenzahl, Verstimmung, Stereobreite
    gpOscUnison, gpOscDetune, gpOscUniWidth, gpOsc2Unison, gpOsc2Detune, gpOsc2UniWidth,
    gpOsc3Unison, gpOsc3Detune, gpOsc3UniWidth,
    // Effekte auf der Summe: Chorus, Phaser, Bitcrusher
    gpChoOn, gpChoRate, gpChoDepth, gpChoFeedback, gpChoMix,
    gpPhaOn, gpPhaRate, gpPhaDepth, gpPhaFeedback, gpPhaMix,
    gpCrushOn, gpCrushBits, gpCrushRate, gpCrushMix,
    gpShimmer,     // entfernt (Okt. 2026): Platzhalter ohne Wirkung, damit VST-Nummern bleiben
    gpRevLowCut, gpRevHighCut,   // Bass-/Hoehen-Schnitt nur des Hallanteils
    // Trance-Gate: Schrittmuster (gezeichnet, im Chunk) im Songtempo
    gpTgOn, gpTgRate, gpTgSteps, gpTgDepth, gpTgSmooth,
    gpPreOn, gpPreStart,   // Anlauf: Note startet vor der Auswahl und laeuft einmal in sie hinein
    gpLoopMode,    // Scan in der Auswahl: vorwaerts (umlaufend) / hin und her
    gpRenderHQ,    // beim Rendern (offline) hoechste Qualitaet: HQ an, volle Stimmenzahl
    // LFO 5 bis 8 (Okt. 2026): gleicher Aufbau wie LFO 1-4
    gpLfo5Rate, gpLfo5Shape, gpLfo5Sync, gpLfo5Trig, gpLfo5Once, gpLfo5Stop, gpLfo5StopMs, gpLfo5StopSync, gpLfo5Partner,
    gpLfo6Rate, gpLfo6Shape, gpLfo6Sync, gpLfo6Trig, gpLfo6Once, gpLfo6Stop, gpLfo6StopMs, gpLfo6StopSync, gpLfo6Partner,
    gpLfo7Rate, gpLfo7Shape, gpLfo7Sync, gpLfo7Trig, gpLfo7Once, gpLfo7Stop, gpLfo7StopMs, gpLfo7StopSync, gpLfo7Partner,
    gpLfo8Rate, gpLfo8Shape, gpLfo8Sync, gpLfo8Trig, gpLfo8Once, gpLfo8Stop, gpLfo8StopMs, gpLfo8StopSync, gpLfo8Partner,
    // freie Makros (Okt. 2026): je ein Regler + Kurve; Ziele ueber die Matrix (Quelle 'Makro 1..4')
    gpUMac1, gpUMac2, gpUMac3, gpUMac4, gpUMac1Curve, gpUMac2Curve, gpUMac3Curve, gpUMac4Curve,
    gpOversample,  // Nov. 2026: 2x-Oversampling bei HQ (Oszillatoren, Saettigung); gehoert zum Rechner, nicht zum Preset
    gpPerformance, // Leistungsstufe: begrenzt Stimmen/Grains (gehoert nicht zum Klang, bleibt beim Presetwechsel)
    gpMaster,      // Master-Lautstaerke (gehoert nicht zum Klang: bleibt beim Presetwechsel)
    gpTempo        // Tempo fuer LFO-Sync (im VST spaeter vom Host); muss der LETZTE sein
  );

  TModSource = (msOff, msLfo1, msLfo2, msSidechain, msVelocity, msNoteRandom, msNote, msFilterEnv, msAmpEnv, msScPitch, msModWheel, msAftertouch, msPitchBend, msGate, msLfo3, msLfo4, msSidechain2,
    msOsc1Env, msOsc2Env, msOsc3Env,   // Huellkurven der Oszillatoren (je Note, unabhaengig von den Grains)
    msLfo5, msLfo6, msLfo7, msLfo8,    // Okt. 2026 (hinten: Presets speichern die Quelle als Klartext)
    msScPitch2,                        // Tonhoehe von Sidechain 2
    msMacro1, msMacro2, msMacro3, msMacro4);   // freie Makros (Regler durch die Kurve)

  TParamInfo = record
    Name: string;
    UnitStr: string;
    MinV, MaxV, DefV: Double;
    Curve: TParamCurve;
    Steps: Integer;
  end;

const
  NAMED_COUNT = Ord(High(TGranularParamId)) + 1;
  { Programmversion: Banner-Text und VST-Versionsnummer (Major*1000 + Minor). Jedes Deploy: Nebenversion +1
    (Tools/bump_version.py), VST3-Unterstuetzung = Version 2.0 (--major) }
  APP_VERSION_MAJOR = 2;
  APP_VERSION_MINOR = 9;
  APP_VERSION = '2.9';
  MOD_SLOTS = 32;
  MOD_SLOTS_V1 = 8;     // so viele Zeilen gab es bis Okt. 2026 (deren VST-Nummern liegen vor VST_ADDED)
  MATRIX_BASE = NAMED_COUNT;
  MOD_STRIDE = 5;   // je Slot: Quelle, Ziel, Menge, Faktor, Offset
  PARAM_COUNT = NAMED_COUNT + MOD_SLOTS * MOD_STRIDE;
  MOD_FACTOR_COUNT = 10;
  { x2,65 = 127/48: SC-Tonhoehe (0..127 Noten) -> Pitch-Regler (48 Halbtoene) 1:1 }
  MOD_FACTORS: array[0..MOD_FACTOR_COUNT - 1] of Double =
    (1 / 16, 1 / 8, 1 / 4, 1 / 2, 1, 2, 127 / 48, 4, 8, 16);
  MOD_FACTOR_NAMES: array[0..MOD_FACTOR_COUNT - 1] of string =
    ('x1/16', 'x1/8', 'x1/4', 'x1/2', 'x1', 'x2', 'x2,65 Ton', 'x4', 'x8', 'x16');
  MOD_FACTOR_DEFAULT = 4;
  MOD_SOURCE_COUNT = Ord(High(TModSource)) + 1;

  { LFO 1 bis 8: Regler je LFO, Matrix-Quelle und Platz der frei gezeichneten Form (FreeLfo; 2 = Morph-LFO) }
  LFO_COUNT = 8;
  { freie Makros: Regler, Kurve und Matrix-Quelle }
  UMAC_COUNT = 4;
  UMAC_IDS: array[0..UMAC_COUNT - 1] of TGranularParamId = (gpUMac1, gpUMac2, gpUMac3, gpUMac4);
  UMAC_CURVE_IDS: array[0..UMAC_COUNT - 1] of TGranularParamId = (gpUMac1Curve, gpUMac2Curve, gpUMac3Curve, gpUMac4Curve);
  UMAC_SRC: array[0..UMAC_COUNT - 1] of TModSource = (msMacro1, msMacro2, msMacro3, msMacro4);
  UMAC_CURVE_NAMES: array[0..3] of string = ('Linear', 'Langsam ansteigend', 'Schnell ansteigend', 'S-Kurve');
  LFO_RATE_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Rate, gpLfo2Rate, gpLfo3Rate, gpLfo4Rate, gpLfo5Rate, gpLfo6Rate, gpLfo7Rate, gpLfo8Rate);
  LFO_SHAPE_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Shape, gpLfo2Shape, gpLfo3Shape, gpLfo4Shape, gpLfo5Shape, gpLfo6Shape, gpLfo7Shape, gpLfo8Shape);
  LFO_SYNC_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Sync, gpLfo2Sync, gpLfo3Sync, gpLfo4Sync, gpLfo5Sync, gpLfo6Sync, gpLfo7Sync, gpLfo8Sync);
  LFO_TRIG_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Trig, gpLfo2Trig, gpLfo3Trig, gpLfo4Trig, gpLfo5Trig, gpLfo6Trig, gpLfo7Trig, gpLfo8Trig);
  LFO_ONCE_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Once, gpLfo2Once, gpLfo3Once, gpLfo4Once, gpLfo5Once, gpLfo6Once, gpLfo7Once, gpLfo8Once);
  LFO_STOP_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Stop, gpLfo2Stop, gpLfo3Stop, gpLfo4Stop, gpLfo5Stop, gpLfo6Stop, gpLfo7Stop, gpLfo8Stop);
  LFO_STOP_MS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1StopMs, gpLfo2StopMs, gpLfo3StopMs, gpLfo4StopMs, gpLfo5StopMs, gpLfo6StopMs, gpLfo7StopMs, gpLfo8StopMs);
  LFO_STOP_SYNC: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1StopSync, gpLfo2StopSync, gpLfo3StopSync, gpLfo4StopSync, gpLfo5StopSync, gpLfo6StopSync, gpLfo7StopSync, gpLfo8StopSync);
  LFO_PARTNER_IDS: array[0..LFO_COUNT - 1] of TGranularParamId = (gpLfo1Partner, gpLfo2Partner, gpLfo3Partner, gpLfo4Partner, gpLfo5Partner, gpLfo6Partner, gpLfo7Partner, gpLfo8Partner);
  LFO_SRC: array[0..LFO_COUNT - 1] of TModSource = (msLfo1, msLfo2, msLfo3, msLfo4, msLfo5, msLfo6, msLfo7, msLfo8);
  LFO_FREE_IDX: array[0..LFO_COUNT - 1] of Integer = (0, 1, 3, 4, 5, 6, 7, 8);
  FREE_LFO_COUNT = 9;     // frei gezeichnete Formen: LFO 1, LFO 2, Morph-LFO, LFO 3..8
  MOD_DEST_COUNT = NAMED_COUNT;   // 0 = Aus, 1..NAMED_COUNT-1 = benannter Parameter (ohne Tempo)

  WINDOW_NAMES: array[0..3] of string = ('Hann', 'Dreieck', 'Trapez', 'Gauß');
  FILTER_NAMES: array[0..5] of string = ('Tiefpass', 'Bandpass', 'Hochpass', 'Ladder 24 dB', 'Kamm', 'Formant (Vokal)');
  FLT_LADDER = 3; FLT_COMB = 4; FLT_FORMANT = 5;
  RENDER_HQ_NAMES: array[0..1] of string = ('wie Echtzeit', 'Höchste Qualität');
  OVERSAMPLE_NAMES: array[0..1] of string = ('Aus', '2x bei HQ');
  ROUTING_NAMES: array[0..1] of string = ('In Reihe (1 -> 2)', 'Parallel (1 + 2)');
  AUTOPITCH_NAMES: array[0..2] of string = ('Aus', 'Frei', 'Halbtöne');
  SCALE_NAMES: array[0..8] of string = ('Aus (chromatisch frei)', 'Dur', 'Moll', 'Harmonisch Moll', 'Dorisch',
    'Pentatonik Dur', 'Pentatonik Moll', 'Blues', 'Ganzton');
  { je Tonleiter: Bit k gesetzt = Halbton k ueber dem Grundton gehoert dazu }
  SCALE_MASKS: array[0..8] of Word = ($FFF, $AB5, $5AD, $9AD, $6AD, $295, $4A9, $4E9, $555);
  ROOT_NAMES: array[0..11] of string = ('C', 'Cis', 'D', 'Dis', 'E', 'F', 'Fis', 'G', 'Gis', 'A', 'B', 'H');
  ARP_MODE_NAMES: array[0..6] of string = ('Hoch', 'Runter', 'Hoch + Runter', 'Runter + Hoch', 'Zufall',
    'Wie gespielt', 'Akkord (alle)');
  ARP_OCT_NAMES: array[0..3] of string = ('1 Oktave', '2 Oktaven', '3 Oktaven', '4 Oktaven');
  ARP_RATE_NAMES: array[0..5] of string = ('1/4', '1/8', '1/8 Triole', '1/16', '1/16 Triole', '1/32');
  ARP_RATE_BEATS: array[0..5] of Double = (1, 0.5, 1 / 3, 0.25, 1 / 6, 0.125);
  ARP_MAX_STEPS = 16;
  OSC_WAVE_NAMES: array[0..5] of string = ('Sinus', 'Dreieck', 'Sägezahn', 'Rechteck', 'FM (2 Sinus)', 'Weißes Rauschen');
  OSC_OCT_NAMES: array[0..5] of string = ('-3 Oktaven', '-2 Oktaven', '-1 Oktave', '0', '+1 Oktave', '+2 Oktaven');
  ROOM_NAMES: array[0..5] of string = ('Neutral', 'Holz', 'Sandstein', 'Tapete / Stoff', 'Beton', 'Schallschutz');
  LFO_TRIG_NAMES: array[0..9] of string = ('frei', 'Note an', 'Note aus', 'an + aus', 'Ende Partner-LFO (Einmal)',
    'Sidechain-Trigger', 'SC-Ton > Schwelle', 'Schwellen-Tor öffnet', 'Ruhe (unter Schwelle)',
    'Ausgang > Schwelle');
  LFO_TRIG_OUT = 9;         // Neustart, wenn der eigene Ausgangspegel die Ausgangs-Schwelle von unten ueberschreitet
  LFO_TRIG_QUIET = 8;       // Neustart, wenn die Tor-Quelle die Ruhe-Dauer lang unter der Schwelle blieb
  LFO_TRIG_GATE = 7;        // Neustart, wenn das Schwellen-Tor aufgeht
  LFO_TRIG_SC_LEVEL = 5;    // Sidechain-Trigger: Pegel und/oder Ton ueber der Schwelle (s. gpScUseLevel/gpScUsePitch)
  LFO_TRIG_SC_PITCH = 6;    // Neustart, wenn die erkannte Sidechain-Tonhoehe die Ton-Schwelle ueberschreitet
  LFO_TRIG_OTHER_END = 4;   // Neustart, wenn der andere LFO seinen Einmal-Durchlauf beendet
  QUALITY_NAMES: array[0..1] of string = ('Standard', 'HQ');
  LFO_SHAPE_NAMES: array[0..5] of string = ('Sinus', 'Dreieck', 'Sägezahn', 'Rechteck', 'Sample&Hold', 'Frei');
  MORPH_LFO_NAMES: array[0..6] of string = ('Aus (nur Regler)', 'Sinus', 'Dreieck', 'Sägezahn', 'Rechteck',
    'Sample&Hold', 'Frei');
  MORPH_LFO_FREE = 6;
  GLIDE_NAMES: array[0..2] of string = ('Aus', 'Immer', 'Nur legato');
  MORPH_MODE_NAMES: array[0..1] of string = ('Werte überblenden', 'Zwei Klänge');
  { Ereignis-Verzoegerung: Notenwerte (0 = Aus -> ms-Wert gilt), Laenge in Vierteln }
  DLY_SYNC_NAMES: array[0..14] of string = ('Aus (ms)', '2/1', '1/1', '1/2.', '1/2', '1/2T', '1/4.', '1/4',
    '1/4T', '1/8.', '1/8', '1/8T', '1/16', '1/16T', '1/32');
  DLY_SYNC_BEATS: array[0..14] of Double = (0, 8, 4, 3, 2, 4 / 3, 1.5, 1, 2 / 3, 0.75, 0.5, 1 / 3, 0.25, 1 / 6, 0.125);
  { Ereignisarten 0..7 (Note an, Note aus, Partner-Ende, SC-Trigger, SC-Ton, Tor, Ruhe, Ausgang) }
  DLY_EVENT_COUNT = 8;
  { Aus-Trigger: 0 = nie (laeuft bis zum naechsten Start weiter), sonst Ereignis Step-1 }
  LFO_STOP_NAMES: array[0..9] of string = ('nie', 'Note an', 'Note aus', 'Ende Partner-LFO (Einmal)',
    'Sidechain-Trigger', 'SC-Ton > Schwelle', 'Schwellen-Tor öffnet', 'Ruhe (unter Schwelle)',
    'Ausgang > Schwelle', 'nach Zeit');
  LFO_STOP_TIME = 9;
  SC_INPUT_NAMES: array[0..2] of string = ('aus', 'Eingang 1/2', 'Eingang 3/4');
  { Leistungsstufe: hoechstens so viele Stimmen / Grains gleichzeitig (CPU-Spitzen begrenzen) }
  PERF_NAMES: array[0..2] of string = ('Voll (32 Stimmen)', 'Sparsam (16 Stimmen)', 'Sehr sparsam (8 Stimmen)');
  PERF_VOICES: array[0..2] of Integer = (32, 16, 8);
  PERF_GRAINS: array[0..2] of Integer = (1024, 400, 180);   // Stopp nach fester Laufzeit ab dem Start
  DLY_EVENT_NAMES: array[0..DLY_EVENT_COUNT - 1] of string = ('Note an', 'Note aus', 'Ende Partner-LFO (Einmal)',
    'Sidechain-Trigger', 'SC-Ton > Schwelle', 'Schwellen-Tor öffnet', 'Ruhe (unter Schwelle)', 'Ausgang > Schwelle');

type
  { Parameter eines Oszillators (1..3 haben denselben Aufbau) }
  TOscParamIds = record
    On_, Wave, Oct, Fine, Level, Pan, FmRatio, FmAmt, Sync,
    Attack, Decay, Sustain, Release,
    FltOn, FltType, FltCutoff, FltReso, FltContour, FltEnvAmt,
    FmEnvOn, FmAttack, FmDecay, FmSustain, FmRelease: TGranularParamId;
  end;

const
  DLY_MS: array[0..7] of TGranularParamId = (gpDlyOn, gpDlyOff, gpDlyEnd, gpDlySc, gpDlyScPitch, gpDlyGate,
    gpDlyQuiet, gpDlyOut);
  DLY_SYNC: array[0..7] of TGranularParamId = (gpDlyOnSync, gpDlyOffSync, gpDlyEndSync, gpDlyScSync,
    gpDlyScPitchSync, gpDlyGateSync, gpDlyQuietSync, gpDlyOutSync);
  OSC_COUNT = 3;
  OSC_P: array[0..OSC_COUNT - 1] of TOscParamIds = (
    (On_: gpOscOn; Wave: gpOscWave; Oct: gpOscOct; Fine: gpOscFine; Level: gpOscLevel; Pan: gpOscPan;
     FmRatio: gpOscFmRatio; FmAmt: gpOscFmAmt; Sync: gpOscSync;
     Attack: gpOscAttack; Decay: gpOscDecay; Sustain: gpOscSustain; Release: gpOscRelease;
     FltOn: gpOscFltOn; FltType: gpOscFltType; FltCutoff: gpOscFltCutoff; FltReso: gpOscFltReso;
     FltContour: gpOscFltContour; FltEnvAmt: gpOscFltEnvAmt;
     FmEnvOn: gpOscFmEnvOn; FmAttack: gpOscFmAttack; FmDecay: gpOscFmDecay; FmSustain: gpOscFmSustain;
     FmRelease: gpOscFmRelease),
    (On_: gpOsc2On; Wave: gpOsc2Wave; Oct: gpOsc2Oct; Fine: gpOsc2Fine; Level: gpOsc2Level; Pan: gpOsc2Pan;
     FmRatio: gpOsc2FmRatio; FmAmt: gpOsc2FmAmt; Sync: gpOsc2Sync;
     Attack: gpOsc2Attack; Decay: gpOsc2Decay; Sustain: gpOsc2Sustain; Release: gpOsc2Release;
     FltOn: gpOsc2FltOn; FltType: gpOsc2FltType; FltCutoff: gpOsc2FltCutoff; FltReso: gpOsc2FltReso;
     FltContour: gpOsc2FltContour; FltEnvAmt: gpOsc2FltEnvAmt;
     FmEnvOn: gpOsc2FmEnvOn; FmAttack: gpOsc2FmAttack; FmDecay: gpOsc2FmDecay; FmSustain: gpOsc2FmSustain;
     FmRelease: gpOsc2FmRelease),
    (On_: gpOsc3On; Wave: gpOsc3Wave; Oct: gpOsc3Oct; Fine: gpOsc3Fine; Level: gpOsc3Level; Pan: gpOsc3Pan;
     FmRatio: gpOsc3FmRatio; FmAmt: gpOsc3FmAmt; Sync: gpOsc3Sync;
     Attack: gpOsc3Attack; Decay: gpOsc3Decay; Sustain: gpOsc3Sustain; Release: gpOsc3Release;
     FltOn: gpOsc3FltOn; FltType: gpOsc3FltType; FltCutoff: gpOsc3FltCutoff; FltReso: gpOsc3FltReso;
     FltContour: gpOsc3FltContour; FltEnvAmt: gpOsc3FltEnvAmt;
     FmEnvOn: gpOsc3FmEnvOn; FmAttack: gpOsc3FmAttack; FmDecay: gpOsc3FmDecay; FmSustain: gpOsc3FmSustain;
     FmRelease: gpOsc3FmRelease));
  LFO_SHAPE_FREE = 5;   // frei programmierbarer LFO (Stufen oder gezeichnet, s. TFreeLfo)
  MOD_SOURCE_NAMES: array[TModSource] of string =
    ('Aus', 'LFO 1', 'LFO 2', 'Sidechain', 'Velocity', 'Zufall je Note', 'Notenhöhe', 'Filter-Hüllk.', 'Grain-Hüllk.', 'SC-Tonhöhe', 'Modrad', 'Aftertouch', 'Pitchbend', 'Schwellen-Tor', 'LFO 3', 'LFO 4', 'Sidechain 2',
     'Osz1-Hüllk.', 'Osz2-Hüllk.', 'Osz3-Hüllk.', 'LFO 5', 'LFO 6', 'LFO 7', 'LFO 8', 'SC2-Tonhöhe',
    'Makro 1', 'Makro 2', 'Makro 3', 'Makro 4');

  LFO_DIV_COUNT = 10;
  LFO_DIV_NAMES: array[0..LFO_DIV_COUNT - 1] of string =
    ('4/1', '2/1', '1/1', '1/2', '1/4', '1/4T', '1/8', '1/8T', '1/16', '1/32');
  LFO_DIV_BEATS: array[0..LFO_DIV_COUNT - 1] of Double =
    (16, 8, 4, 2, 1, 2 / 3, 0.5, 1 / 3, 0.25, 0.125);

  PARAM_INFO: array[TGranularParamId] of TParamInfo = (
    (Name: 'Auswahl Start'; UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Auswahl Ende';  UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Position';      UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Spray';         UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 2;    Curve: pcLinear;  Steps: 0),
    (Name: 'Scan';          UnitStr: 'x';  MinV: -2;   MaxV: 2;    DefV: 1;    Curve: pcLinear;  Steps: 0),
    (Name: 'Graingröße';  UnitStr: 'ms'; MinV: 5;    MaxV: 500;  DefV: 80;   Curve: pcExp;     Steps: 0),
    (Name: 'Dichte';        UnitStr: '/s'; MinV: 1;    MaxV: 200;  DefV: 40;   Curve: pcExp;     Steps: 0),
    (Name: 'Pitch';         UnitStr: 'st'; MinV: -24;  MaxV: 24;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Pitch Zufall';  UnitStr: 'st'; MinV: 0;    MaxV: 12;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Stereobreite';  UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 30;   Curve: pcLinear;  Steps: 0),
    (Name: 'Rückwärts';   UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Fenster';       UnitStr: '';   MinV: 0;    MaxV: 3;    DefV: 0;    Curve: pcStepped; Steps: 4),
    (Name: 'Attack';        UnitStr: 'ms'; MinV: 1;    MaxV: 5000; DefV: 10;   Curve: pcExp;     Steps: 0),
    (Name: 'Release';       UnitStr: 'ms'; MinV: 1;    MaxV: 5000; DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'Lautstärke';   UnitStr: 'dB'; MinV: -60;  MaxV: 6;    DefV: 0;    Curve: pcDecibel; Steps: 0),
    (Name: 'Key Tracking';  UnitStr: '';   MinV: 0;    MaxV: 1;    DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Decay';         UnitStr: 'ms'; MinV: 1;    MaxV: 5000; DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'Sustain';       UnitStr: '%';  MinV: 0;    MaxV: 100;  DefV: 80;   Curve: pcLinear;  Steps: 0),
    (Name: 'LFO1 Rate';     UnitStr: 'Hz'; MinV: 0.02; MaxV: 20;   DefV: 1;    Curve: pcExp;     Steps: 0),
    (Name: 'LFO1 Form';     UnitStr: '';   MinV: 0;    MaxV: 5;    DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'LFO1 Sync';     UnitStr: '';   MinV: 0;    MaxV: 1;    DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO2 Rate';     UnitStr: 'Hz'; MinV: 0.02; MaxV: 20;   DefV: 0.25; Curve: pcExp;     Steps: 0),
    (Name: 'LFO2 Form';     UnitStr: '';   MinV: 0;    MaxV: 5;    DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'LFO2 Sync';     UnitStr: '';   MinV: 0;    MaxV: 1;    DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'SC Verstärk.'; UnitStr: 'dB'; MinV: 0;    MaxV: 40;   DefV: 12;   Curve: pcLinear;  Steps: 0),
    (Name: 'SC Attack';     UnitStr: 'ms'; MinV: 1;    MaxV: 500;  DefV: 10;   Curve: pcExp;     Steps: 0),
    (Name: 'SC Release';    UnitStr: 'ms'; MinV: 10;   MaxV: 2000; DefV: 200;  Curve: pcExp;     Steps: 0),
    (Name: 'Filtertyp';     UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'Cutoff';        UnitStr: 'Hz'; MinV: 20;   MaxV: 20000; DefV: 2000; Curve: pcExp;     Steps: 0),
    (Name: 'Resonanz';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 20;   Curve: pcLinear;  Steps: 0),
    (Name: 'Kontur';        UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 100;    Curve: pcLinear;  Steps: 0),
    (Name: 'Filter-Hüllk.'; UnitStr: '%'; MinV: -100; MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'F-Attack';      UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 5;    Curve: pcExp;     Steps: 0),
    (Name: 'F-Decay';       UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 400;  Curve: pcExp;     Steps: 0),
    (Name: 'F-Sustain';     UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 30;   Curve: pcLinear;  Steps: 0),
    (Name: 'F-Release';     UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 400;  Curve: pcExp;     Steps: 0),
    (Name: 'Echo Zeit';     UnitStr: 'ms'; MinV: 10;   MaxV: 2000;  DefV: 350;  Curve: pcExp;     Steps: 0),
    (Name: 'Echo Sync';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Feedback';      UnitStr: '%';  MinV: 0;    MaxV: 95;    DefV: 40;   Curve: pcLinear;  Steps: 0),
    (Name: 'Dämpfung';     UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 30;   Curve: pcLinear;  Steps: 0),
    (Name: 'Ping-Pong';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Echo Mix';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 35;    Curve: pcLinear;  Steps: 0),
    (Name: 'Echo Pitch';    UnitStr: 'st'; MinV: -12;  MaxV: 12;    DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Filter an';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Echo an';       UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO1 Trigger';  UnitStr: '';   MinV: 0;    MaxV: 9;     DefV: 0;    Curve: pcStepped; Steps: 10),
    (Name: 'LFO2 Trigger';  UnitStr: '';   MinV: 0;    MaxV: 9;     DefV: 0;    Curve: pcStepped; Steps: 10),
    (Name: 'LFO1 Einmal';   UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO2 Einmal';   UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Bend-Bereich';  UnitStr: 'st'; MinV: 0;    MaxV: 24;    DefV: 2;    Curve: pcLinear;  Steps: 0),
    (Name: 'HQ-Modus';      UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Limiter';       UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Textur';        UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Bewegung';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Helligkeit';    UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Raum';          UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Streuung';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Hüllk.-Länge'; UnitStr: '%'; MinV: 0;    MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Auto-Pitch';    UnitStr: '';   MinV: 0;    MaxV: 2;     DefV: 0;    Curve: pcStepped; Steps: 3),
    (Name: 'Hall an';       UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Hall Größe';  UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 60;   Curve: pcLinear;  Steps: 0),
    (Name: 'Hall Zeit';     UnitStr: 's';  MinV: 0.2;  MaxV: 20;    DefV: 2.5;  Curve: pcExp;     Steps: 0),
    (Name: 'Hall Dämpfung'; UnitStr: '%'; MinV: 0;    MaxV: 100;   DefV: 40;   Curve: pcLinear;  Steps: 0),
    (Name: 'Hall Predelay'; UnitStr: 'ms'; MinV: 0;    MaxV: 250;   DefV: 20;   Curve: pcLinear;  Steps: 0),
    (Name: 'Hall Breite';   UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Hall Mix';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 30;   Curve: pcLinear;  Steps: 0),
    (Name: 'Tonleiter';     UnitStr: '';   MinV: 0;    MaxV: 8;     DefV: 0;    Curve: pcStepped; Steps: 9),
    (Name: 'Grundton';      UnitStr: '';   MinV: 0;    MaxV: 11;    DefV: 0;    Curve: pcStepped; Steps: 12),
    (Name: 'Morph';         UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Freeze';        UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Sättigung';    UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Arp an';        UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Arp Richtung';  UnitStr: '';   MinV: 0;    MaxV: 6;     DefV: 0;    Curve: pcStepped; Steps: 7),
    (Name: 'Arp Oktaven';   UnitStr: '';   MinV: 0;    MaxV: 3;     DefV: 0;    Curve: pcStepped; Steps: 4),
    (Name: 'Arp Notenwert'; UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 3;    Curve: pcStepped; Steps: 6),
    (Name: 'Arp Länge';    UnitStr: '%';  MinV: 5;    MaxV: 100;   DefV: 70;   Curve: pcLinear;  Steps: 0),
    (Name: 'Arp Swing';     UnitStr: '%';  MinV: 0;    MaxV: 50;    DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Arp Schritte';  UnitStr: '';   MinV: 0;    MaxV: 15;    DefV: 7;    Curve: pcStepped; Steps: 16),
    (Name: 'SC-Schwelle';   UnitStr: '%';  MinV: 1;    MaxV: 100;   DefV: 40;   Curve: pcLinear;  Steps: 0),
    (Name: 'SC-Ton-Schwelle'; UnitStr: ''; MinV: 36;   MaxV: 96;    DefV: 60;   Curve: pcLinear;  Steps: 0),
    (Name: 'Tor-Quelle';    UnitStr: '';   MinV: 0;    MaxV: 19;    DefV: 3;    Curve: pcStepped; Steps: 20),
    (Name: 'Tor-Schwelle';  UnitStr: '%';  MinV: -100; MaxV: 100;   DefV: 50;   Curve: pcLinear;  Steps: 0),
    (Name: 'Ruhe-Dauer';    UnitStr: 'ms'; MinV: 20;   MaxV: 20000; DefV: 500;  Curve: pcExp;     Steps: 0),
    (Name: 'Morph-LFO Form'; UnitStr: '';  MinV: 0;    MaxV: 6;     DefV: 0;    Curve: pcStepped; Steps: 7),
    (Name: 'Morph-LFO Rate'; UnitStr: 'Hz'; MinV: 0.01; MaxV: 10;   DefV: 0.1;  Curve: pcExp;     Steps: 0),
    (Name: 'Morph-LFO Sync'; UnitStr: '';  MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Morph-LFO Tiefe'; UnitStr: '%'; MinV: 0;   MaxV: 100;   DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Auto-Stimmung'; UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'EQ an';         UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'EQ Bässe';     UnitStr: 'dB'; MinV: -12;  MaxV: 12;    DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'EQ Höhen';     UnitStr: 'dB'; MinV: -12;  MaxV: 12;    DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Summen-Breite'; UnitStr: '%';  MinV: 0;    MaxV: 200;   DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Summen-Panorama'; UnitStr: '%'; MinV: -100; MaxV: 100;  DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Hall Raum';     UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'Osz an';        UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Osz Welle';     UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'Osz Oktave';    UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 3;    Curve: pcStepped; Steps: 6),
    (Name: 'Osz Fein';      UnitStr: 'ct'; MinV: -100; MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Osz-Pegel';     UnitStr: '%';  MinV: 0;    MaxV: 200;   DefV: 40;   Curve: pcLinear;  Steps: 0),
    (Name: 'Osz Panorama';  UnitStr: '%';  MinV: -100; MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Osz FM-Verh.';  UnitStr: 'x';  MinV: 0.5;  MaxV: 8;     DefV: 2;    Curve: pcLinear;  Steps: 0),
    (Name: 'Osz FM-Menge';  UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 30;   Curve: pcLinear;  Steps: 0),
    (Name: 'Osz Attack';    UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 10;   Curve: pcExp;     Steps: 0),
    (Name: 'Osz Decay';     UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'Osz Sustain';   UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 80;   Curve: pcLinear;  Steps: 0),
    (Name: 'Osz Release';   UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'Osz-Filter an'; UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Osz-Filter Typ'; UnitStr: '';  MinV: 0;    MaxV: 2;     DefV: 0;    Curve: pcStepped; Steps: 3),
    (Name: 'Osz-Filter Cutoff'; UnitStr: 'Hz'; MinV: 20; MaxV: 20000; DefV: 2000; Curve: pcExp;    Steps: 0),
    (Name: 'Osz-Filter Resonanz'; UnitStr: '%'; MinV: 0; MaxV: 100;  DefV: 20;   Curve: pcLinear;  Steps: 0),
    (Name: 'Osz-Filter Kontur'; UnitStr: '%'; MinV: 0;  MaxV: 100;   DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Osz-Filter Hüllk.'; UnitStr: '%'; MinV: -100; MaxV: 100; DefV: 0;   Curve: pcLinear;  Steps: 0),
    (Name: 'FM-Hüllk. eigen'; UnitStr: ''; MinV: 0;   MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'FM Attack';     UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 1;    Curve: pcExp;     Steps: 0),
    (Name: 'FM Decay';      UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 150;  Curve: pcExp;     Steps: 0),
    (Name: 'FM Sustain';    UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 20;   Curve: pcLinear;  Steps: 0),
    (Name: 'FM Release';    UnitStr: 'ms'; MinV: 1;    MaxV: 5000;  DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'LFO3 Rate';     UnitStr: 'Hz'; MinV: 0.02; MaxV: 20;    DefV: 0.5;  Curve: pcExp;     Steps: 0),
    (Name: 'LFO3 Form';     UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'LFO3 Sync';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO3 Trigger';  UnitStr: '';   MinV: 0;    MaxV: 9;     DefV: 0;    Curve: pcStepped; Steps: 10),
    (Name: 'LFO3 Einmal';   UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO4 Rate';     UnitStr: 'Hz'; MinV: 0.02; MaxV: 20;    DefV: 2;    Curve: pcExp;     Steps: 0),
    (Name: 'LFO4 Form';     UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 0;    Curve: pcStepped; Steps: 6),
    (Name: 'LFO4 Sync';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'LFO4 Trigger';  UnitStr: '';   MinV: 0;    MaxV: 9;     DefV: 0;    Curve: pcStepped; Steps: 10),
    (Name: 'LFO4 Einmal';   UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Filter2 an';    UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Filter-Verschaltung'; UnitStr: ''; MinV: 0; MaxV: 1;    DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Filter2 Typ';   UnitStr: '';   MinV: 0;    MaxV: 5;     DefV: 2;    Curve: pcStepped; Steps: 6),
    (Name: 'Filter2 Cutoff'; UnitStr: 'Hz'; MinV: 20;  MaxV: 20000; DefV: 300;  Curve: pcExp;     Steps: 0),
    (Name: 'Filter2 Resonanz'; UnitStr: '%'; MinV: 0;  MaxV: 100;   DefV: 20;   Curve: pcLinear;  Steps: 0),
    (Name: 'Filter2 Kontur'; UnitStr: '%'; MinV: 0;    MaxV: 100;   DefV: 100;  Curve: pcLinear;  Steps: 0),
    (Name: 'Filter2 Hüllk.'; UnitStr: '%'; MinV: -100; MaxV: 100;  DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'EQ Band A Freq'; UnitStr: 'Hz'; MinV: 30;  MaxV: 16000; DefV: 250;  Curve: pcExp;     Steps: 0),
    (Name: 'EQ Band A Pegel'; UnitStr: 'dB'; MinV: -18; MaxV: 18;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'EQ Band B Freq'; UnitStr: 'Hz'; MinV: 30;  MaxV: 16000; DefV: 3000; Curve: pcExp;     Steps: 0),
    (Name: 'EQ Band B Pegel'; UnitStr: 'dB'; MinV: -18; MaxV: 18;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'SC-Trig Pegel'; UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'SC-Trig Ton';   UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 0;    Curve: pcStepped; Steps: 2),
    (Name: 'Ausgangs-Schwelle'; UnitStr: '%'; MinV: 1; MaxV: 100;   DefV: 15;   Curve: pcLinear;  Steps: 0),
    (Name: 'Grain-Oktave';  UnitStr: '';   MinV: 0;    MaxV: 8;     DefV: 4;    Curve: pcStepped; Steps: 9),
    (Name: 'Grain-Panorama'; UnitStr: '%'; MinV: -100; MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Grains an';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Osz Sync';      UnitStr: '%';  MinV: 0;    MaxV: 100;   DefV: 0;    Curve: pcLinear;  Steps: 0),
    (Name: 'Glide';         UnitStr: '';   MinV: 0;    MaxV: 2;     DefV: 0;    Curve: pcStepped; Steps: 3),
    (Name: 'Glide-Zeit';    UnitStr: 'ms'; MinV: 5;    MaxV: 5000;  DefV: 150;  Curve: pcExp;     Steps: 0),
    (Name: 'Grain-Pegel';   UnitStr: 'dB'; MinV: -60;  MaxV: 6;     DefV: 0;    Curve: pcDecibel; Steps: 0),
    (Name: 'Morph-Art';     UnitStr: '';   MinV: 0;    MaxV: 1;     DefV: 1;    Curve: pcStepped; Steps: 2),
    (Name: 'Osz2 an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz2 Welle'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'Osz2 Oktave'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 3; Curve: pcStepped; Steps: 6),
    (Name: 'Osz2 Fein'; UnitStr: 'ct'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2-Pegel'; UnitStr: '%'; MinV: 0; MaxV: 200; DefV: 40; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Panorama'; UnitStr: '%'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 FM-Verh.'; UnitStr: 'x'; MinV: 0.5; MaxV: 8; DefV: 2; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 FM-Menge'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 30; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Sync'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Attack'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 10; Curve: pcExp; Steps: 0),
    (Name: 'Osz2 Decay'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Osz2 Sustain'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 80; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Release'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Osz2-Filter an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz2-Filter Typ'; UnitStr: ''; MinV: 0; MaxV: 2; DefV: 0; Curve: pcStepped; Steps: 3),
    (Name: 'Osz2-Filter Cutoff'; UnitStr: 'Hz'; MinV: 20; MaxV: 20000; DefV: 2000; Curve: pcExp; Steps: 0),
    (Name: 'Osz2-Filter Resonanz'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 20; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2-Filter Kontur'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 100; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2-Filter Hüllk.'; UnitStr: '%'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 FM-Hüllk. eigen'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz2 FM Attack'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'Osz2 FM Decay'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 150; Curve: pcExp; Steps: 0),
    (Name: 'Osz2 FM Sustain'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 20; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 FM Release'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Osz3 an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz3 Welle'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'Osz3 Oktave'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 3; Curve: pcStepped; Steps: 6),
    (Name: 'Osz3 Fein'; UnitStr: 'ct'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3-Pegel'; UnitStr: '%'; MinV: 0; MaxV: 200; DefV: 40; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Panorama'; UnitStr: '%'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 FM-Verh.'; UnitStr: 'x'; MinV: 0.5; MaxV: 8; DefV: 2; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 FM-Menge'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 30; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Sync'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Attack'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 10; Curve: pcExp; Steps: 0),
    (Name: 'Osz3 Decay'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Osz3 Sustain'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 80; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Release'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Osz3-Filter an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz3-Filter Typ'; UnitStr: ''; MinV: 0; MaxV: 2; DefV: 0; Curve: pcStepped; Steps: 3),
    (Name: 'Osz3-Filter Cutoff'; UnitStr: 'Hz'; MinV: 20; MaxV: 20000; DefV: 2000; Curve: pcExp; Steps: 0),
    (Name: 'Osz3-Filter Resonanz'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 20; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3-Filter Kontur'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 100; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3-Filter Hüllk.'; UnitStr: '%'; MinV: -100; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 FM-Hüllk. eigen'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Osz3 FM Attack'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'Osz3 FM Decay'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 150; Curve: pcExp; Steps: 0),
    (Name: 'Osz3 FM Sustain'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 20; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 FM Release'; UnitStr: 'ms'; MinV: 1; MaxV: 5000; DefV: 300; Curve: pcExp; Steps: 0),
    (Name: 'Verz. Note an'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Note an Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. Note aus'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Note aus Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. Partner-Ende'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Partner-Ende Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. SC-Trigger'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. SC-Trigger Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. SC-Ton'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. SC-Ton Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. Tor'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Tor Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. Ruhe'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Ruhe Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'Verz. Ausgang'; UnitStr: 'ms'; MinV: 0; MaxV: 4000; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Verz. Ausgang Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO1 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO2 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO3 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO4 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO1 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO1 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO2 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO2 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO3 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO3 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO4 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO4 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    // Vorgabe = bisheriges festes Paar (1<->2, 3<->4): alte Presets klingen gleich
    (Name: 'LFO1 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 1; Curve: pcStepped; Steps: 8),
    (Name: 'LFO2 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 0; Curve: pcStepped; Steps: 8),
    (Name: 'LFO3 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 3; Curve: pcStepped; Steps: 8),
    (Name: 'LFO4 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 2; Curve: pcStepped; Steps: 8),
    (Name: 'Arp Latch'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'SC1 Eingang'; UnitStr: ''; MinV: 0; MaxV: 2; DefV: 1; Curve: pcStepped; Steps: 3),
    (Name: 'SC2 Eingang'; UnitStr: ''; MinV: 0; MaxV: 2; DefV: 2; Curve: pcStepped; Steps: 3),
    (Name: 'Osz Unison'; UnitStr: ''; MinV: 1; MaxV: 7; DefV: 1; Curve: pcStepped; Steps: 7),
    (Name: 'Osz Unison Verstimmung'; UnitStr: 'ct'; MinV: 0; MaxV: 100; DefV: 15; Curve: pcLinear; Steps: 0),
    (Name: 'Osz Unison Breite'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 70; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Unison'; UnitStr: ''; MinV: 1; MaxV: 7; DefV: 1; Curve: pcStepped; Steps: 7),
    (Name: 'Osz2 Unison Verstimmung'; UnitStr: 'ct'; MinV: 0; MaxV: 100; DefV: 15; Curve: pcLinear; Steps: 0),
    (Name: 'Osz2 Unison Breite'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 70; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Unison'; UnitStr: ''; MinV: 1; MaxV: 7; DefV: 1; Curve: pcStepped; Steps: 7),
    (Name: 'Osz3 Unison Verstimmung'; UnitStr: 'ct'; MinV: 0; MaxV: 100; DefV: 15; Curve: pcLinear; Steps: 0),
    (Name: 'Osz3 Unison Breite'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 70; Curve: pcLinear; Steps: 0),
    (Name: 'Chorus an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Chorus Tempo'; UnitStr: 'Hz'; MinV: 0.05; MaxV: 5; DefV: 0.6; Curve: pcExp; Steps: 0),
    (Name: 'Chorus Tiefe'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 40; Curve: pcLinear; Steps: 0),
    (Name: 'Chorus Rückkopplung'; UnitStr: '%'; MinV: 0; MaxV: 90; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Chorus Mix'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 40; Curve: pcLinear; Steps: 0),
    (Name: 'Phaser an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Phaser Tempo'; UnitStr: 'Hz'; MinV: 0.02; MaxV: 5; DefV: 0.3; Curve: pcExp; Steps: 0),
    (Name: 'Phaser Tiefe'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 70; Curve: pcLinear; Steps: 0),
    (Name: 'Phaser Rückkopplung'; UnitStr: '%'; MinV: 0; MaxV: 90; DefV: 40; Curve: pcLinear; Steps: 0),
    (Name: 'Phaser Mix'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 50; Curve: pcLinear; Steps: 0),
    (Name: 'Bitcrusher an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Bitcrusher Bits'; UnitStr: 'Bit'; MinV: 1; MaxV: 16; DefV: 8; Curve: pcLinear; Steps: 0),
    (Name: 'Bitcrusher Rate'; UnitStr: 'Hz'; MinV: 500; MaxV: 48000; DefV: 11025; Curve: pcExp; Steps: 0),
    (Name: 'Bitcrusher Mix'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 100; Curve: pcLinear; Steps: 0),
    (Name: '(frei)'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),   // war Shimmer
    (Name: 'Hall Bass-Schnitt'; UnitStr: 'Hz'; MinV: 20; MaxV: 2000; DefV: 20; Curve: pcExp; Steps: 0),
    (Name: 'Hall Höhen-Schnitt'; UnitStr: 'Hz'; MinV: 500; MaxV: 20000; DefV: 20000; Curve: pcExp; Steps: 0),
    (Name: 'Trance-Gate an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Trance-Gate Notenwert'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 3; Curve: pcStepped; Steps: 6),
    (Name: 'Trance-Gate Schritte'; UnitStr: ''; MinV: 0; MaxV: 15; DefV: 15; Curve: pcStepped; Steps: 16),
    (Name: 'Trance-Gate Tiefe'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 100; Curve: pcLinear; Steps: 0),
    (Name: 'Trance-Gate Glättung'; UnitStr: 'ms'; MinV: 0; MaxV: 50; DefV: 4; Curve: pcLinear; Steps: 0),
    (Name: 'Anlauf an'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Anlauf-Start'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Schleife'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'Rendern in Höchstqualität'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 1; Curve: pcStepped; Steps: 2),
    (Name: 'LFO5 Rate'; UnitStr: 'Hz'; MinV: 0.02; MaxV: 20; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'LFO5 Form'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'LFO5 Sync'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO5 Trigger'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO5 Einmal'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO5 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO5 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO5 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO5 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 5; Curve: pcStepped; Steps: 8),
    (Name: 'LFO6 Rate'; UnitStr: 'Hz'; MinV: 0.02; MaxV: 20; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'LFO6 Form'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'LFO6 Sync'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO6 Trigger'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO6 Einmal'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO6 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO6 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO6 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO6 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 4; Curve: pcStepped; Steps: 8),
    (Name: 'LFO7 Rate'; UnitStr: 'Hz'; MinV: 0.02; MaxV: 20; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'LFO7 Form'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'LFO7 Sync'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO7 Trigger'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO7 Einmal'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO7 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO7 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO7 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO7 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 7; Curve: pcStepped; Steps: 8),
    (Name: 'LFO8 Rate'; UnitStr: 'Hz'; MinV: 0.02; MaxV: 20; DefV: 1; Curve: pcExp; Steps: 0),
    (Name: 'LFO8 Form'; UnitStr: ''; MinV: 0; MaxV: 5; DefV: 0; Curve: pcStepped; Steps: 6),
    (Name: 'LFO8 Sync'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO8 Trigger'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO8 Einmal'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 0; Curve: pcStepped; Steps: 2),
    (Name: 'LFO8 Stopp'; UnitStr: ''; MinV: 0; MaxV: 9; DefV: 0; Curve: pcStepped; Steps: 10),
    (Name: 'LFO8 Stoppzeit'; UnitStr: 'ms'; MinV: 0; MaxV: 10000; DefV: 1000; Curve: pcLinear; Steps: 0),
    (Name: 'LFO8 Stoppzeit Takt'; UnitStr: ''; MinV: 0; MaxV: 14; DefV: 0; Curve: pcStepped; Steps: 15),
    (Name: 'LFO8 Partner'; UnitStr: ''; MinV: 0; MaxV: 7; DefV: 6; Curve: pcStepped; Steps: 8),
    (Name: 'Makro 1'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Makro 2'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Makro 3'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Makro 4'; UnitStr: '%'; MinV: 0; MaxV: 100; DefV: 0; Curve: pcLinear; Steps: 0),
    (Name: 'Makro 1 Kurve'; UnitStr: ''; MinV: 0; MaxV: 3; DefV: 0; Curve: pcStepped; Steps: 4),
    (Name: 'Makro 2 Kurve'; UnitStr: ''; MinV: 0; MaxV: 3; DefV: 0; Curve: pcStepped; Steps: 4),
    (Name: 'Makro 3 Kurve'; UnitStr: ''; MinV: 0; MaxV: 3; DefV: 0; Curve: pcStepped; Steps: 4),
    (Name: 'Makro 4 Kurve'; UnitStr: ''; MinV: 0; MaxV: 3; DefV: 0; Curve: pcStepped; Steps: 4),
    (Name: 'Oversampling'; UnitStr: ''; MinV: 0; MaxV: 1; DefV: 1; Curve: pcStepped; Steps: 2),
    (Name: 'Leistung'; UnitStr: ''; MinV: 0; MaxV: 2; DefV: 0; Curve: pcStepped; Steps: 3),
    (Name: 'Master';        UnitStr: 'dB'; MinV: -60;  MaxV: 6;     DefV: 0;    Curve: pcDecibel; Steps: 0),
    (Name: 'Tempo';         UnitStr: 'BPM'; MinV: 60;  MaxV: 200;  DefV: 120;  Curve: pcLinear;  Steps: 0)
  );

{ --- VST-Parameternummern ---
  Die DAW speichert Automation ueber die Nummer. Damit neue Regler (intern irgendwo eingefuegt)
  keine Automation verschieben, gilt fuer VST eine FESTE Reihenfolge:
    0 .. Length(VST_ORDER)-1        benannte Regler aus VST_ORDER (Stand Okt. 2026)
    danach MOD_SLOTS_V1 * MOD_STRIDE Matrix-Zeilen 1..8
    danach                           spaeter hinzugekommene Regler, NUR HINTEN an VST_ADDED anhaengen
    danach                           Matrix-Zeilen 9..MOD_SLOTS (immer ganz hinten, waechst mit MOD_SLOTS)
  Nie umsortieren, nie loeschen (entfernte Regler bleiben als Platzhalter). Fehlt ein Regler in
  beiden Listen, haengt VstMap ihn hinten an und -bench meldet FEHLER. }
const
  VST_ORDER: array[0..198] of TGranularParamId = (
    gpSelStart, gpSelEnd, gpPosition, gpSpray, gpScan, gpGrainSize, gpDensity, gpPitch, gpPitchRand,
    gpSpread, gpReverse, gpWindow, gpAttack, gpRelease, gpVolume, gpKeyTrack, gpDecay, gpSustain,
    gpLfo1Rate, gpLfo1Shape, gpLfo1Sync, gpLfo2Rate, gpLfo2Shape, gpLfo2Sync, gpScGain, gpScAttack,
    gpScRelease, gpFltType, gpFltCutoff, gpFltReso, gpFltContour, gpFltEnvAmt, gpFltAttack, gpFltDecay,
    gpFltSustain, gpFltRelease, gpEchoTime, gpEchoSync, gpEchoFeedback, gpEchoDamp, gpEchoPingPong,
    gpEchoMix, gpEchoPitch, gpFltOn, gpEchoOn, gpLfo1Trig, gpLfo2Trig, gpLfo1Once, gpLfo2Once, gpBendRange,
    gpQuality, gpLimiter, gpMacroTexture, gpMacroMotion, gpMacroBright, gpMacroSpace, gpMacroScatter,
    gpMacroEnv, gpScPitchMode, gpRevOn, gpRevSize, gpRevDecay, gpRevDamp, gpRevPreDelay, gpRevWidth,
    gpRevMix, gpScale, gpScaleRoot, gpMorph, gpFreeze, gpDrive, gpArpOn, gpArpMode, gpArpOct, gpArpRate,
    gpArpGate, gpArpSwing, gpArpSteps, gpScTrigLevel, gpScTrigNote, gpGateSrc, gpGateThresh, gpGateQuiet,
    gpMorphLfoShape, gpMorphLfoRate, gpMorphLfoSync, gpMorphLfoDepth, gpAutoTune, gpEqOn, gpEqBass,
    gpEqTreble, gpWidth, gpPan, gpRevRoom, gpOscOn, gpOscWave, gpOscOct, gpOscFine, gpOscLevel, gpOscPan,
    gpOscFmRatio, gpOscFmAmt, gpOscAttack, gpOscDecay, gpOscSustain, gpOscRelease, gpOscFltOn, gpOscFltType,
    gpOscFltCutoff, gpOscFltReso, gpOscFltContour, gpOscFltEnvAmt, gpOscFmEnvOn, gpOscFmAttack,
    gpOscFmDecay, gpOscFmSustain, gpOscFmRelease, gpLfo3Rate, gpLfo3Shape, gpLfo3Sync, gpLfo3Trig,
    gpLfo3Once, gpLfo4Rate, gpLfo4Shape, gpLfo4Sync, gpLfo4Trig, gpLfo4Once, gpFlt2On, gpFltRouting,
    gpFlt2Type, gpFlt2Cutoff, gpFlt2Reso, gpFlt2Contour, gpFlt2EnvAmt, gpEqAFreq, gpEqAGain, gpEqBFreq,
    gpEqBGain, gpScUseLevel, gpScUsePitch, gpOutTrigLevel, gpGrainOct, gpGrainPan, gpGrainOn, gpOscSync,
    gpGlideMode, gpGlideTime, gpGrainLevel, gpMorphMode, gpOsc2On, gpOsc2Wave, gpOsc2Oct, gpOsc2Fine,
    gpOsc2Level, gpOsc2Pan, gpOsc2FmRatio, gpOsc2FmAmt, gpOsc2Sync, gpOsc2Attack, gpOsc2Decay,
    gpOsc2Sustain, gpOsc2Release, gpOsc2FltOn, gpOsc2FltType, gpOsc2FltCutoff, gpOsc2FltReso,
    gpOsc2FltContour, gpOsc2FltEnvAmt, gpOsc2FmEnvOn, gpOsc2FmAttack, gpOsc2FmDecay, gpOsc2FmSustain,
    gpOsc2FmRelease, gpOsc3On, gpOsc3Wave, gpOsc3Oct, gpOsc3Fine, gpOsc3Level, gpOsc3Pan, gpOsc3FmRatio,
    gpOsc3FmAmt, gpOsc3Sync, gpOsc3Attack, gpOsc3Decay, gpOsc3Sustain, gpOsc3Release, gpOsc3FltOn,
    gpOsc3FltType, gpOsc3FltCutoff, gpOsc3FltReso, gpOsc3FltContour, gpOsc3FltEnvAmt, gpOsc3FmEnvOn,
    gpOsc3FmAttack, gpOsc3FmDecay, gpOsc3FmSustain, gpOsc3FmRelease, gpMaster, gpTempo);
  VST_ADDED_COUNT = 116;   // Anzahl der Eintraege in VST_ADDED
  VST_ADDED: array[0..VST_ADDED_COUNT - 1] of TGranularParamId = (
    // Okt. 2026: Ereignis-Verzoegerung
    gpDlyOn, gpDlyOnSync, gpDlyOff, gpDlyOffSync, gpDlyEnd, gpDlyEndSync, gpDlySc, gpDlyScSync,
    gpDlyScPitch, gpDlyScPitchSync, gpDlyGate, gpDlyGateSync, gpDlyQuiet, gpDlyQuietSync, gpDlyOut, gpDlyOutSync,
    // Okt. 2026: Aus-Trigger der LFOs
    gpLfo1Stop, gpLfo2Stop, gpLfo3Stop, gpLfo4Stop,
    // Okt. 2026: Stopp nach Zeit
    gpLfo1StopMs, gpLfo1StopSync, gpLfo2StopMs, gpLfo2StopSync,
    gpLfo3StopMs, gpLfo3StopSync, gpLfo4StopMs, gpLfo4StopSync,
    // Okt. 2026: Partner-LFO waehlbar
    gpLfo1Partner, gpLfo2Partner, gpLfo3Partner, gpLfo4Partner,
    // Okt. 2026: Arp Latch
    gpArpLatch,
    // Okt. 2026: Zuordnung der VST-Eingaenge zu den Sidechains
    gpSc1Input, gpSc2Input,
    // Okt. 2026: Leistungsstufe
    gpPerformance,
    // Okt. 2026: Unison, Chorus, Phaser, Bitcrusher, Shimmer, Trance-Gate, Render-Qualitaet
    gpOscUnison, gpOscDetune, gpOscUniWidth, gpOsc2Unison, gpOsc2Detune, gpOsc2UniWidth,
    gpOsc3Unison, gpOsc3Detune, gpOsc3UniWidth,
    gpChoOn, gpChoRate, gpChoDepth, gpChoFeedback, gpChoMix,
    gpPhaOn, gpPhaRate, gpPhaDepth, gpPhaFeedback, gpPhaMix,
    gpCrushOn, gpCrushBits, gpCrushRate, gpCrushMix,
    gpShimmer,
    gpTgOn, gpTgRate, gpTgSteps, gpTgDepth, gpTgSmooth,
    gpRenderHQ,
    gpRevLowCut, gpRevHighCut,
    // Okt. 2026: Anlauf vor der Auswahl, Schleife hin und her
    gpPreOn, gpPreStart, gpLoopMode,
    // Okt. 2026: LFO 5 bis 8
    gpLfo5Rate, gpLfo5Shape, gpLfo5Sync, gpLfo5Trig, gpLfo5Once, gpLfo5Stop, gpLfo5StopMs, gpLfo5StopSync, gpLfo5Partner,
    gpLfo6Rate, gpLfo6Shape, gpLfo6Sync, gpLfo6Trig, gpLfo6Once, gpLfo6Stop, gpLfo6StopMs, gpLfo6StopSync, gpLfo6Partner,
    gpLfo7Rate, gpLfo7Shape, gpLfo7Sync, gpLfo7Trig, gpLfo7Once, gpLfo7Stop, gpLfo7StopMs, gpLfo7StopSync, gpLfo7Partner,
    gpLfo8Rate, gpLfo8Shape, gpLfo8Sync, gpLfo8Trig, gpLfo8Once, gpLfo8Stop, gpLfo8StopMs, gpLfo8StopSync, gpLfo8Partner,
    gpUMac1, gpUMac2, gpUMac3, gpUMac4, gpUMac1Curve, gpUMac2Curve, gpUMac3Curve, gpUMac4Curve,
    // Nov. 2026: Oversampling
    gpOversample);


{ VST-Nummer -> interner Index und zurueck (-1 = ungueltig) }
function VstToParam(VstIndex: Integer): Integer;
function ParamToVst(Index: Integer): Integer;
{ True, wenn jeder Regler genau einmal in VST_ORDER/VST_ADDED steht (sonst automatisch angehaengt) }
function VstMapComplete: Boolean;

function GetParamInfo(Index: Integer): TParamInfo;
function ParamToPlain(Index: Integer; Norm: Single): Double; overload;
function ParamToPlain(Id: TGranularParamId; Norm: Single): Double; overload;
function PlainToParam(Index: Integer; Plain: Double): Single; overload;
function PlainToParam(Id: TGranularParamId; Plain: Double): Single; overload;
function ParamStep(Index: Integer; Norm: Single): Integer;
{ LFO-Nummer (0..LFO_COUNT-1) einer Matrix-Quelle, -1 = kein LFO }
function LfoOfSource(Src: Integer): Integer;
{ LFO-Nummer zu einem Platz der frei gezeichneten Formen (FreeLfo), -1 = Morph-LFO }
function LfoOfFree(FreeIdx: Integer): Integer;
{ Id in Liste (Ersatz fuer 'in [..]': mehr als 256 Regler passen in keine Delphi-Menge) }
function IdIn(Id: TGranularParamId; const List: array of TGranularParamId): Boolean;
function StepToParam(Index, Step: Integer): Single;
function StepName(Index, Step: Integer): string;
function ParamDisplay(Index: Integer; Norm: Single): string; overload;
function ParamDisplay(Id: TGranularParamId; Norm: Single): string; overload;
function DecibelToGain(Db: Double): Double;

{ Matrix-Hilfen }
function SlotSourceIndex(Slot: Integer): Integer;
function SlotDestIndex(Slot: Integer): Integer;
function SlotAmountIndex(Slot: Integer): Integer;
function SlotFactorIndex(Slot: Integer): Integer;
function SlotOffsetIndex(Slot: Integer): Integer;
function DestName(Dest: Integer): string;
{ Umlaute ausschreiben (ä -> ae, ß -> ss ...): Namen aelterer Presets (ohne Umlaute) passen weiter }
function FoldUmlauts(const S: string): string;

{ LFO }
function LfoDivisionIndex(RateNorm: Single): Integer;
{ Echo: hoher Reglerwert = laengere Zeit -> umgekehrte Reihenfolge der Notenwerte }
function EchoDivisionIndex(TimeNorm: Single): Integer;
function LfoShapeValue(Shape: Integer; Phase: Double; SampleHold: Single): Single;

const
  FREE_MAX_STEPS = 64;     // Stufen des freien LFOs
  FREE_DRAW_N = 256;       // feste Aufloesung der gezeichneten Kurve (unabhaengig vom Bildschirm)
  FREE_SEMIS = 24;         // Halbton-Modus: Wert 1 = 24 Halbtoene (Matrix-Menge 50 % auf Pitch = 1 Stufe 1 Halbton)
  FREE_MODE_NAMES: array[0..2] of string = ('Halbtöne (Stufen)', 'Frei (Stufen)', 'Gezeichnet');

type
  { Frei programmierbarer LFO. Werte bipolar -1..1.
      Modus 0: Stufen, Werte auf Halbtoene gerastert (k / FREE_SEMIS)
      Modus 1: Stufen, beliebige Werte
      Modus 2: gezeichnete Kurve, FREE_DRAW_N Stuetzpunkte, linear interpoliert }
  TFreeLfo = record
    Mode: Integer;
    Steps: Integer;
    Step: array[0..FREE_MAX_STEPS - 1] of Single;
    Draw: array[0..FREE_DRAW_N - 1] of Single;
    Smooth: Single;   // Nov. 2026: Glaettung der Stufen 0..1 (0 = harte Stufen, 1 = runde Kurve)
  end;
  PFreeLfo = ^TFreeLfo;

procedure FreeLfoDefault(var F: TFreeLfo);
function FreeLfoValue(const F: TFreeLfo; Phase: Double): Single;
function FreeQuantize(V: Single): Single;   // auf Halbtonraster

implementation

uses
  System.SysUtils, System.Math;

function Clamp01(V: Double): Double;
begin
  if V < 0 then Result := 0
  else if V > 1 then Result := 1
  else Result := V;
end;

function SlotSourceIndex(Slot: Integer): Integer;
begin
  Result := MATRIX_BASE + Slot * MOD_STRIDE;
end;

function SlotDestIndex(Slot: Integer): Integer;
begin
  Result := MATRIX_BASE + Slot * MOD_STRIDE + 1;
end;

function SlotAmountIndex(Slot: Integer): Integer;
begin
  Result := MATRIX_BASE + Slot * MOD_STRIDE + 2;
end;

function SlotFactorIndex(Slot: Integer): Integer;
begin
  Result := MATRIX_BASE + Slot * MOD_STRIDE + 3;
end;

function SlotOffsetIndex(Slot: Integer): Integer;
begin
  Result := MATRIX_BASE + Slot * MOD_STRIDE + 4;
end;

function FoldUmlauts(const S: string): string;
var
  Enc: TEncoding;
begin
  Result := S;
  // Presets aus Version 1.2-1.4 (Quelltext versehentlich als ANSI gelesen): "GraingrÃ¶ÃŸe" -> "Graingröße"
  if Pos(#$00C3, Result) > 0 then
  begin
    Enc := TEncoding.GetEncoding(1252);
    try
      Result := TEncoding.UTF8.GetString(Enc.GetBytes(Result));
    finally
      Enc.Free;
    end;
  end;
  Result := StringReplace(Result, #$00E4, 'ae', [rfReplaceAll]);
  Result := StringReplace(Result, #$00F6, 'oe', [rfReplaceAll]);
  Result := StringReplace(Result, #$00FC, 'ue', [rfReplaceAll]);
  Result := StringReplace(Result, #$00C4, 'Ae', [rfReplaceAll]);
  Result := StringReplace(Result, #$00D6, 'Oe', [rfReplaceAll]);
  Result := StringReplace(Result, #$00DC, 'Ue', [rfReplaceAll]);
  Result := StringReplace(Result, #$00DF, 'ss', [rfReplaceAll]);
end;

function DestName(Dest: Integer): string;
begin
  if (Dest <= 0) or (Dest >= MOD_DEST_COUNT) then
    Result := 'Aus'
  else
    Result := PARAM_INFO[TGranularParamId(Dest - 1)].Name;
end;

function GetParamInfo(Index: Integer): TParamInfo;
var
  Slot, Kind: Integer;
begin
  if Index < NAMED_COUNT then
    Exit(PARAM_INFO[TGranularParamId(Index)]);
  Slot := (Index - MATRIX_BASE) div MOD_STRIDE;
  Kind := (Index - MATRIX_BASE) mod MOD_STRIDE;
  Result.UnitStr := '';
  Result.DefV := 0;
  Result.MinV := 0;
  case Kind of
    0: begin
         Result.Name := Format('Mod%d Quelle', [Slot + 1]);
         Result.MaxV := MOD_SOURCE_COUNT - 1;
         Result.Curve := pcStepped;
         Result.Steps := MOD_SOURCE_COUNT;
       end;
    1: begin
         Result.Name := Format('Mod%d Ziel', [Slot + 1]);
         Result.MaxV := MOD_DEST_COUNT - 1;
         Result.Curve := pcStepped;
         Result.Steps := MOD_DEST_COUNT;
       end;
    3: begin
         Result.Name := Format('Mod%d Faktor', [Slot + 1]);
         Result.MaxV := MOD_FACTOR_COUNT - 1;
         Result.DefV := MOD_FACTOR_DEFAULT;
         Result.Curve := pcStepped;
         Result.Steps := MOD_FACTOR_COUNT;
       end;
    4: begin
         Result.Name := Format('Mod%d Offset', [Slot + 1]);
         Result.UnitStr := '%';
         Result.MinV := -200;
         Result.MaxV := 200;
         Result.Curve := pcLinear;
         Result.Steps := 0;
       end;
  else
    Result.Name := Format('Mod%d Menge', [Slot + 1]);
    Result.UnitStr := '%';
    Result.MinV := -100;
    Result.MaxV := 100;
    Result.Curve := pcLinear;
    Result.Steps := 0;
  end;
end;

{ Zahlenwerte aller Regler (ohne Namen/Texte), einmal beim Laden der Unit gebaut. Die Umrechnungen im
  Audio-Thread lesen nur hieraus - GetParamInfo liefert den Namen als String (bei Matrix-Reglern per
  Format neu gebaut) und wuerde dort Speicher anlegen: das kostet Zeit und sperrt den gemeinsamen
  Speicherverwalter, sodass sich mehrere Instanzen auf mehreren Kernen gegenseitig ausbremsen. }
type
  TParamNum = record
    MinV, MaxV, Ratio: Double;    // Ratio = MaxV / MinV (exponentielle Kurve)
    Curve: TParamCurve;
    Steps: Integer;
  end;

var
  GParamNum: array of TParamNum;

procedure BuildParamNum;
var
  I: Integer;
  Info: TParamInfo;
begin
  SetLength(GParamNum, PARAM_COUNT);
  for I := 0 to PARAM_COUNT - 1 do
  begin
    Info := GetParamInfo(I);
    GParamNum[I].MinV := Info.MinV;
    GParamNum[I].MaxV := Info.MaxV;
    if Info.MinV <> 0 then
      GParamNum[I].Ratio := Info.MaxV / Info.MinV
    else
      GParamNum[I].Ratio := 1;
    GParamNum[I].Curve := Info.Curve;
    GParamNum[I].Steps := Info.Steps;
  end;
end;

function ParamToPlain(Index: Integer; Norm: Single): Double;
var
  N: Double;
begin
  N := Clamp01(Norm);
  with GParamNum[Index] do
    case Curve of
      pcExp:
        Result := MinV * Power(Ratio, N);
      pcStepped:
        Result := MinV + Round(N * (Steps - 1)) * (MaxV - MinV) / (Steps - 1);
    else
      Result := MinV + N * (MaxV - MinV);
    end;
end;

function ParamToPlain(Id: TGranularParamId; Norm: Single): Double;
begin
  Result := ParamToPlain(Ord(Id), Norm);
end;

function PlainToParam(Index: Integer; Plain: Double): Single;
begin
  with GParamNum[Index] do
    case Curve of
      pcExp:
        if Plain <= MinV then Result := 0
        else Result := Clamp01(Ln(Plain / MinV) / Ln(Ratio));
    else
      Result := Clamp01((Plain - MinV) / (MaxV - MinV));
    end;
end;

function PlainToParam(Id: TGranularParamId; Plain: Double): Single;
begin
  Result := PlainToParam(Ord(Id), Plain);
end;

function ParamStep(Index: Integer; Norm: Single): Integer;
begin
  with GParamNum[Index] do
    if Steps < 2 then
      Result := 0
    else
      Result := Round(Clamp01(Norm) * (Steps - 1));
end;

function LfoOfFree(FreeIdx: Integer): Integer;
var
  K: Integer;
begin
  for K := 0 to LFO_COUNT - 1 do
    if LFO_FREE_IDX[K] = FreeIdx then
      Exit(K);
  Result := -1;
end;

function LfoOfSource(Src: Integer): Integer;
var
  K: Integer;
begin
  for K := 0 to LFO_COUNT - 1 do
    if Ord(LFO_SRC[K]) = Src then
      Exit(K);
  Result := -1;
end;

function IdIn(Id: TGranularParamId; const List: array of TGranularParamId): Boolean;
var
  X: TGranularParamId;
begin
  for X in List do
    if X = Id then
      Exit(True);
  Result := False;
end;

function StepToParam(Index, Step: Integer): Single;
begin
  with GParamNum[Index] do
    if Steps < 2 then
      Result := 0
    else
      Result := Clamp01(Step / (Steps - 1));
end;

function StepName(Index, Step: Integer): string;
var
  Kind: Integer;
begin
  if Index >= MATRIX_BASE then
  begin
    Kind := (Index - MATRIX_BASE) mod MOD_STRIDE;
    case Kind of
      0: Result := MOD_SOURCE_NAMES[TModSource(EnsureRange(Step, 0, MOD_SOURCE_COUNT - 1))];
      3: Result := MOD_FACTOR_NAMES[EnsureRange(Step, 0, MOD_FACTOR_COUNT - 1)];
    else
      Result := DestName(Step);
    end;
    Exit;
  end;
  case TGranularParamId(Index) of
    gpWindow: Result := WINDOW_NAMES[EnsureRange(Step, 0, 3)];
    gpFltType, gpFlt2Type: Result := FILTER_NAMES[EnsureRange(Step, 0, 5)];
    gpOscFltType, gpOsc2FltType, gpOsc3FltType: Result := FILTER_NAMES[EnsureRange(Step, 0, 2)];
    gpOscUnison, gpOsc2Unison, gpOsc3Unison: if Step = 0 then Result := 'aus (1 Stimme)' else Result := Format('%d Stimmen', [Step + 1]);
    gpTgRate: Result := ARP_RATE_NAMES[EnsureRange(Step, 0, 5)];
    gpTgSteps: Result := IntToStr(EnsureRange(Step, 0, 15) + 1);
    gpRenderHQ: Result := RENDER_HQ_NAMES[EnsureRange(Step, 0, 1)];
    gpOversample: Result := OVERSAMPLE_NAMES[EnsureRange(Step, 0, 1)];
    gpLoopMode: if Step = 0 then Result := 'Vorwärts' else Result := 'Hin und her';
    gpFltRouting: Result := ROUTING_NAMES[EnsureRange(Step, 0, 1)];
    gpScPitchMode: Result := AUTOPITCH_NAMES[EnsureRange(Step, 0, 2)];
    gpScale: Result := SCALE_NAMES[EnsureRange(Step, 0, 8)];
    gpScaleRoot: Result := ROOT_NAMES[EnsureRange(Step, 0, 11)];
    gpArpMode: Result := ARP_MODE_NAMES[EnsureRange(Step, 0, 6)];
    gpArpOct: Result := ARP_OCT_NAMES[EnsureRange(Step, 0, 3)];
    gpArpRate: Result := ARP_RATE_NAMES[EnsureRange(Step, 0, 5)];
    gpArpSteps: Result := IntToStr(EnsureRange(Step, 0, 15) + 1);
    gpGateSrc: Result := MOD_SOURCE_NAMES[TModSource(EnsureRange(Step, 0, Ord(High(TModSource))))];
    gpMorphLfoShape: Result := MORPH_LFO_NAMES[EnsureRange(Step, 0, 6)];
    gpGlideMode: Result := GLIDE_NAMES[EnsureRange(Step, 0, 2)];
    gpMorphMode: Result := MORPH_MODE_NAMES[EnsureRange(Step, 0, 1)];
    gpDlyOnSync, gpDlyOffSync, gpDlyEndSync, gpDlyScSync, gpDlyScPitchSync, gpDlyGateSync, gpDlyQuietSync,
    gpDlyOutSync, gpLfo1StopSync, gpLfo2StopSync, gpLfo3StopSync, gpLfo4StopSync, gpLfo5StopSync, gpLfo6StopSync, gpLfo7StopSync, gpLfo8StopSync: Result := DLY_SYNC_NAMES[EnsureRange(Step, 0, 14)];
    gpGrainOct: if Step = 4 then Result := '0' else if Step > 4 then Result := Format('+%d Okt.', [Step - 4]) else Result := Format('%d Okt.', [Step - 4]);
    gpRevRoom: Result := ROOM_NAMES[EnsureRange(Step, 0, 5)];
    gpOscWave, gpOsc2Wave, gpOsc3Wave: Result := OSC_WAVE_NAMES[EnsureRange(Step, 0, 5)];
    gpOscOct, gpOsc2Oct, gpOsc3Oct: Result := OSC_OCT_NAMES[EnsureRange(Step, 0, 5)];
    gpLfo1Trig, gpLfo2Trig, gpLfo3Trig, gpLfo4Trig, gpLfo5Trig, gpLfo6Trig, gpLfo7Trig, gpLfo8Trig: Result := LFO_TRIG_NAMES[EnsureRange(Step, 0, 9)];
    gpLfo1Stop, gpLfo2Stop, gpLfo3Stop, gpLfo4Stop, gpLfo5Stop, gpLfo6Stop, gpLfo7Stop, gpLfo8Stop: Result := LFO_STOP_NAMES[EnsureRange(Step, 0, 9)];
    gpSc1Input, gpSc2Input: Result := SC_INPUT_NAMES[EnsureRange(Step, 0, 2)];
    gpPerformance: Result := PERF_NAMES[EnsureRange(Step, 0, 2)];
    gpLfo1Partner, gpLfo2Partner, gpLfo3Partner, gpLfo4Partner, gpLfo5Partner, gpLfo6Partner, gpLfo7Partner, gpLfo8Partner: Result := Format('LFO %d', [EnsureRange(Step, 0, LFO_COUNT - 1) + 1]);
    gpQuality: Result := QUALITY_NAMES[EnsureRange(Step, 0, 1)];
    gpUMac1Curve, gpUMac2Curve, gpUMac3Curve, gpUMac4Curve: Result := UMAC_CURVE_NAMES[EnsureRange(Step, 0, 3)];
    gpLfo1Shape, gpLfo2Shape, gpLfo3Shape, gpLfo4Shape, gpLfo5Shape, gpLfo6Shape, gpLfo7Shape, gpLfo8Shape: Result := LFO_SHAPE_NAMES[EnsureRange(Step, 0, 5)];
  else
    if Step <> 0 then Result := 'An' else Result := 'Aus';
  end;
end;

function DecibelToGain(Db: Double): Double;
begin
  if Db <= PARAM_INFO[gpVolume].MinV then
    Result := 0
  else
    Result := Power(10, Db / 20);
end;

function ParamDisplay(Index: Integer; Norm: Single): string;
var
  V: Double;
  Info: TParamInfo;
begin
  Info := GetParamInfo(Index);
  if Info.Curve = pcStepped then
    Exit(StepName(Index, ParamStep(Index, Norm)));
  V := ParamToPlain(Index, Norm);
  if Index = Ord(gpVolume) then
  begin
    if Norm <= 0 then Result := '-inf dB' else Result := Format('%.1f dB', [V]);
  end
  else if Index = Ord(gpScTrigNote) then
    Result := Copy('C  CisD  DisE  F  FisG  GisA  B  H  ', (Round(V) mod 12) * 3 + 1, 3).Trim +
      IntToStr(Round(V) div 12 - 1)
  else if Index = Ord(gpFltCutoff) then
  begin
    if V >= 1000 then Result := Format('%.2f kHz', [V / 1000]) else Result := Format('%.0f Hz', [V]);
  end
  else if (Index < NAMED_COUNT) and IdIn(TGranularParamId(Index), [gpScan, gpPitch, gpPitchRand, gpLfo1Rate, gpLfo2Rate,
    gpLfo3Rate, gpLfo4Rate, gpLfo5Rate, gpLfo6Rate, gpLfo7Rate, gpLfo8Rate, gpEchoPitch, gpMorphLfoRate]) then
    Result := Format('%.2f %s', [V, Info.UnitStr])
  else if Abs(V) >= 100 then
    Result := Format('%.0f %s', [V, Info.UnitStr])
  else
    Result := Format('%.1f %s', [V, Info.UnitStr]);
end;

function ParamDisplay(Id: TGranularParamId; Norm: Single): string;
begin
  Result := ParamDisplay(Ord(Id), Norm);
end;

function LfoDivisionIndex(RateNorm: Single): Integer;
begin
  Result := Round(Clamp01(RateNorm) * (LFO_DIV_COUNT - 1));
end;

function EchoDivisionIndex(TimeNorm: Single): Integer;
begin
  Result := (LFO_DIV_COUNT - 1) - LfoDivisionIndex(TimeNorm);
end;

procedure FreeLfoDefault(var F: TFreeLfo);
const
  // kleines Arpeggio in Halbtoenen: Grundton, Terz, Quinte, Oktave ...
  MELODY: array[0..7] of Integer = (0, 3, 7, 12, 7, 3, 0, -5);
var
  I: Integer;
begin
  F.Mode := 0;
  F.Steps := 8;
  F.Smooth := 0;
  for I := 0 to FREE_MAX_STEPS - 1 do
    F.Step[I] := MELODY[I mod 8] / FREE_SEMIS;
  for I := 0 to FREE_DRAW_N - 1 do
    F.Draw[I] := Sin(2 * Pi * I / FREE_DRAW_N);
end;

function FreeQuantize(V: Single): Single;
begin
  Result := EnsureRange(Round(V * FREE_SEMIS), -FREE_SEMIS, FREE_SEMIS) / FREE_SEMIS;
end;

function FreeLfoValue(const F: TFreeLfo; Phase: Double): Single;
var
  N, I: Integer;
  X, T: Double;
  Prev: Single;
begin
  Phase := Phase - Floor(Phase);
  if F.Mode = 2 then
  begin
    // gezeichnet: zyklisch linear interpolieren -> keine Treppen aus der Bildschirmaufloesung
    X := Phase * FREE_DRAW_N;
    I := Trunc(X);
    T := X - I;
    I := I mod FREE_DRAW_N;
    Result := F.Draw[I] + (F.Draw[(I + 1) mod FREE_DRAW_N] - F.Draw[I]) * T;
  end
  else
  begin
    N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
    X := Phase * N;
    I := Min(Trunc(X), N - 1);
    Result := F.Step[I];
    if F.Mode = 0 then
      Result := FreeQuantize(Result);
    // Glaettung: am Anfang jeder Stufe weich (Kosinus) vom Wert der vorigen Stufe herueber gleiten;
    // der Uebergang dauert Smooth * Stufenlaenge (1 = ganze Stufe -> runde Kurve durch alle Werte)
    if F.Smooth > 0.001 then
    begin
      T := X - I;
      if T < F.Smooth then
      begin
        Prev := F.Step[(I + N - 1) mod N];
        if F.Mode = 0 then
          Prev := FreeQuantize(Prev);
        Result := Prev + (Result - Prev) * (0.5 - 0.5 * Cos(Pi * T / F.Smooth));
      end;
    end;
  end;
end;

function LfoShapeValue(Shape: Integer; Phase: Double; SampleHold: Single): Single;
begin
  // bipolar -1..1, Phase 0..1
  case Shape of
    0: Result := Sin(2 * Pi * Phase);
    1: if Phase < 0.25 then Result := 4 * Phase
       else if Phase < 0.75 then Result := 2 - 4 * Phase
       else Result := 4 * Phase - 4;
    2: Result := 2 * Phase - 1;
    3: if Phase < 0.5 then Result := 1 else Result := -1;
    4: Result := SampleHold;
  else
    Result := 0;   // Frei: wird von FreeLfoValue berechnet
  end;
end;

var
  GVstToParam, GParamToVst: TArray<Integer>;
  GVstComplete: Boolean;

procedure BuildVstMap;
var
  I, K: Integer;
  Used: array of Boolean;

  procedure Add(Idx: Integer);
  begin
    if (Idx < 0) or (Idx >= PARAM_COUNT) or Used[Idx] then
    begin
      GVstComplete := False;     // doppelt oder ungueltig
      Exit;
    end;
    Used[Idx] := True;
    GVstToParam := GVstToParam + [Idx];
  end;

begin
  SetLength(Used, PARAM_COUNT);
  GVstComplete := True;
  GVstToParam := nil;
  for I := 0 to High(VST_ORDER) do
    Add(Ord(VST_ORDER[I]));
  for K := 0 to MOD_SLOTS_V1 * MOD_STRIDE - 1 do
    Add(NAMED_COUNT + K);
  for I := 0 to VST_ADDED_COUNT - 1 do
    Add(Ord(VST_ADDED[I]));
  // Matrix-Zeilen 9..32 (Okt. 2026) ganz hinten: bestehende Automation verschiebt sich nicht
  for K := MOD_SLOTS_V1 * MOD_STRIDE to MOD_SLOTS * MOD_STRIDE - 1 do
    Add(NAMED_COUNT + K);
  // Sicherheitsnetz: vergessene Regler hinten anhaengen (dann ist die Liste unvollstaendig)
  for I := 0 to PARAM_COUNT - 1 do
    if not Used[I] then
    begin
      GVstComplete := False;
      Used[I] := True;
      GVstToParam := GVstToParam + [I];
    end;
  SetLength(GParamToVst, PARAM_COUNT);
  for I := 0 to High(GVstToParam) do
    GParamToVst[GVstToParam[I]] := I;
end;

function VstToParam(VstIndex: Integer): Integer;
begin
  if (VstIndex >= 0) and (VstIndex < Length(GVstToParam)) then
    Result := GVstToParam[VstIndex]
  else
    Result := -1;
end;

function ParamToVst(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < Length(GParamToVst)) then
    Result := GParamToVst[Index]
  else
    Result := -1;
end;

function VstMapComplete: Boolean;
begin
  Result := GVstComplete and (Length(GVstToParam) = PARAM_COUNT);
end;

initialization
  BuildParamNum;
  BuildVstMap;

end.
