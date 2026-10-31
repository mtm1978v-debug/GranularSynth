{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.AutoPlay;

{ Autoplay NUR fuer den Test-Host: spielt gemeinfreie Melodien mehrstimmig ab.
  Laeuft im Audio-Thread (Process wird aus dem Render-Callback gerufen) und erzeugt
  Noten mit DeltaFrames -> samplegenau, keine Timer-Ungenauigkeit.
  Abwechslung: zufaellige Reihenfolge, Transposition, Tempo +-8 %, Velocity-Humanizing.

  Notenschrift je Stimme (Leerzeichen getrennt, '|' wird ignoriert):
    C#5-2   Note C#5, Dauer 2 Einheiten      R-4   Pause 4 Einheiten
    T-12    alle folgenden Noten transponieren (Halbtoene)
    V40     Dynamik der folgenden Noten 40 %  L1 / L0  gebunden / leicht abgesetzt
  Akkordspur: 'Am:6 G:6 F#m:4 ...' -> Bass (Grundton Oktave 2) + Terz + Quinte (Oktave 4). }

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, System.Generics.Defaults;

type
  TSeqEvent = record
    Time: Int64;       // in Samples ab Songbeginn
    Note: Integer;
    IsOn: Boolean;
    Velocity: Single;
  end;

  TSong = record
    Title: string;
    Events: TArray<TSeqEvent>;
    Length: Int64;
    Bpm: Double;         // Originaltempo, Zeiten in Events beziehen sich darauf
    Kind: Integer;       // SONG_MELODY / SONG_DRONE / SONG_ARP (Bitmaske fuer den Filter)
  end;

const
  SONG_MELODY = 1;   // Melodien und Stuecke
  SONG_DRONE = 2;    // Liegetoene: wenig Melodie, der Klang steht im Vordergrund
  SONG_ARP = 4;      // gehaltene Akkorde fuer den Arpeggiator
  SONG_ALL = 7;

type
  { Ausgabe einer Note an den Host (der sie als MIDI an das geladene VST weitergibt) }
  TNoteEmit = procedure(Note: Integer; Velocity: Single; IsOn: Boolean; Delta: Integer) of object;

  TAutoPlayer = class
  private
    FSongs: TArray<TSong>;
    FSampleRate: Integer;
    // Steuerung GUI -> Audio-Thread
    FStartRequest: Integer;    // -2 = keine, -1 = zufaellig, sonst Songindex
    FStopRequest: Boolean;
    // Zustand im Audio-Thread
    FPlaying: Boolean;
    FCurrent: Integer;
    FEvIdx: Integer;
    FPos: Double;        // Songposition in Samples bei Originaltempo
    FTranspose: Integer;
    FRandomMode: Boolean;
    FRand: Cardinal;
    FActive: array[0..127] of Integer;   // laufende Noten (auch fuer die Anzeige)
    FKindMask: Integer;                  // erlaubte Arten (GUI setzt, Audio liest; Integer = atomar)
    function PickRandom(Exclude: Integer): Integer;
    function GetKind(Index: Integer): Integer;
    function Rand: Double;
    procedure AddSong(const Title: string; Bpm: Double; UnitsPerBeat: Integer;
      const Voices: array of string; const Chords: string = '');
    procedure BeginSong(Index: Integer; var Tempo: Double);
    procedure ReleaseAll(Emit: TNoteEmit);
    function GetSongCount: Integer;
    function GetTitle(Index: Integer): string;
    function GetCurrentTitle: string;
    function GetNoteActive(Note: Integer): Boolean;
  public
    constructor Create(SampleRate: Integer);
    { Audio-Thread }
    { Tempo = Host-Tempo (BPM); wird beim Songstart auf das Songtempo gesetzt }
    procedure Process(Frames: Integer; var Tempo: Double; Emit: TNoteEmit);
    { GUI-Thread }
    procedure Start(SongIndex: Integer = -1);   // -1 = Zufallsreihenfolge
    procedure Stop;
    property Playing: Boolean read FPlaying;
    property SongCount: Integer read GetSongCount;
    property Titles[Index: Integer]: string read GetTitle;
    property CurrentTitle: string read GetCurrentTitle;
    property NoteActive[Note: Integer]: Boolean read GetNoteActive;
    property Kinds[Index: Integer]: Integer read GetKind;
    { Zufallsauswahl und Folgestueck nur aus diesen Arten }
    property KindMask: Integer read FKindMask write FKindMask;
    function CurrentKind: Integer;
    { Stueck als Standard-MIDI-Datei (Typ 0, 480 Ticks je Viertel, Tempo-Meta) speichern }
    procedure ExportMidi(Index: Integer; const FileName: string);
  end;

implementation

const
  SONG_GAP_SECONDS = 1.5;
  NOTE_NAMES = 'C D EF G A B';   // Position = Halbton (H wird als B notiert)

function ParseNote(const Tok: string; out Midi: Integer): Boolean;
var
  P, Semi, Oct: Integer;
begin
  Result := False;
  if Length(Tok) < 2 then
    Exit;
  Semi := Pos(UpCase(Tok[1]), NOTE_NAMES) - 1;
  if Semi < 0 then
    Exit;
  P := 2;
  if Tok[P] = '#' then begin Inc(Semi); Inc(P); end
  else if Tok[P] = 'b' then begin Dec(Semi); Inc(P); end;
  Oct := StrToIntDef(Copy(Tok, P, MaxInt), -99);
  if Oct = -99 then
    Exit;
  Midi := (Oct + 1) * 12 + Semi;
  Result := True;
end;

{ Akkordspur -> drei Stimmen in Notenschrift }
procedure ChordsToVoices(const Chords: string; out Bass, Third, Fifth: string);
var
  Toks: TArray<string>;
  Tok, Name, Dur: string;
  P, Root, Th: Integer;
  Minor: Boolean;

  function NoteStr(Midi: Integer): string;
  const
    N: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
  begin
    Result := N[Midi mod 12] + IntToStr(Midi div 12 - 1);
  end;

begin
  Bass := ''; Third := ''; Fifth := '';
  Toks := Chords.Split([' '], TStringSplitOptions.ExcludeEmpty);
  for Tok in Toks do
  begin
    P := Pos(':', Tok);
    if P = 0 then Continue;
    Name := Copy(Tok, 1, P - 1);
    Dur := Copy(Tok, P + 1, MaxInt);
    if Name = 'R' then
    begin
      Bass := Bass + ' R-' + Dur; Third := Third + ' R-' + Dur; Fifth := Fifth + ' R-' + Dur;
      Continue;
    end;
    Minor := (Length(Name) > 1) and (Name[Length(Name)] = 'm');
    if Minor then
      Delete(Name, Length(Name), 1);
    if not ParseNote(Name + '2', Root) then Continue;
    if Minor then Th := 3 else Th := 4;
    Bass := Bass + ' ' + NoteStr(Root) + '-' + Dur;
    Third := Third + ' ' + NoteStr(Root + 24 + Th) + '-' + Dur;
    Fifth := Fifth + ' ' + NoteStr(Root + 24 + 7) + '-' + Dur;
  end;
end;

{ TAutoPlayer }

constructor TAutoPlayer.Create(SampleRate: Integer);
const
  // --- Bruder Jakob (Kanon, 8 Takte a 8 Achtel) ---
  JAKOB = 'C5-2 D5-2 E5-2 C5-2 | C5-2 D5-2 E5-2 C5-2 | E5-2 F5-2 G5-4 | E5-2 F5-2 G5-4 | ' +
          'G5-1 A5-1 G5-1 F5-1 E5-2 C5-2 | G5-1 A5-1 G5-1 F5-1 E5-2 C5-2 | ' +
          'C5-2 G4-2 C5-4 | C5-2 G4-2 C5-4 ';
  // --- Ode an die Freude (Beethoven), Achtel ---
  ODE = 'E5-2 E5-2 F5-2 G5-2 | G5-2 F5-2 E5-2 D5-2 | C5-2 C5-2 D5-2 E5-2 | E5-3 D5-1 D5-4 | ' +
        'E5-2 E5-2 F5-2 G5-2 | G5-2 F5-2 E5-2 D5-2 | C5-2 C5-2 D5-2 E5-2 | D5-3 C5-1 C5-4 ';
  ODE_CH = 'C:8 G:8 C:8 G:8 C:8 G:8 C:8 G:4 C:4 ';
  // --- Fuer Elise (Beethoven), Sechzehntel ---
  ELISE_R = 'E5-1 D#5-1 | E5-1 D#5-1 E5-1 B4-1 D5-1 C5-1 | A4-3 C4-1 E4-1 A4-1 | ' +
            'B4-3 E4-1 G#4-1 B4-1 | C5-3 E4-1 E5-1 D#5-1 | E5-1 D#5-1 E5-1 B4-1 D5-1 C5-1 | ' +
            'A4-3 C4-1 E4-1 A4-1 | B4-3 E4-1 C5-1 B4-1 | A4-6 ';
  ELISE_L = 'R-8 | A2-1 E3-1 A3-1 R-3 | E2-1 E3-1 G#3-1 R-3 | A2-1 E3-1 A3-1 R-3 | R-6 | ' +
            'A2-1 E3-1 A3-1 R-3 | E2-1 E3-1 G#3-1 R-3 | A2-6 ';
  // --- Greensleeves (traditionell), 3/4 in Achteln ---
  GREEN = 'A4-2 | C5-4 D5-2 | E5-3 F5-1 E5-2 | D5-4 B4-2 | G4-3 A4-1 B4-2 | C5-4 A4-2 | ' +
          'A4-3 G#4-1 A4-2 | B4-4 G#4-2 | E4-4 A4-2 | C5-4 D5-2 | E5-3 F5-1 E5-2 | D5-4 B4-2 | ' +
          'G4-3 A4-1 B4-2 | C5-3 B4-1 A4-2 | G#4-3 F#4-1 G#4-2 | A4-6 | A4-6 ';
  GREEN_CH = 'R:2 Am:6 C:6 G:6 Em:6 Am:6 Am:6 E:6 E:6 Am:6 C:6 G:6 Em:6 Am:6 E:6 Am:6 Am:6 ';
  // --- Menuett G-Dur (Petzold, frueher Bach zugeschrieben), 3/4 in Achteln ---
  MENU_A = 'D5-2 G4-1 A4-1 B4-1 C5-1 | D5-2 G4-2 G4-2 | E5-2 C5-1 D5-1 E5-1 F#5-1 | G5-2 G4-2 G4-2 | ' +
           'C5-2 D5-1 C5-1 B4-1 A4-1 | B4-2 C5-1 B4-1 A4-1 G4-1 | ';
  MENU = MENU_A + 'F#4-2 G4-1 A4-1 B4-1 G4-1 | A4-6 | ' +
         MENU_A + 'A4-2 B4-1 A4-1 G4-1 F#4-1 | G4-6 ';
  MENU_CH = 'G:6 G:6 C:6 G:6 C:6 G:6 D:6 D:6 G:6 G:6 C:6 G:6 C:6 G:6 D:6 G:6 ';
  // --- Kanon (Pachelbel), Achtel ---
  K1 = 'F#5-4 E5-4 D5-4 C#5-4 B4-4 A4-4 B4-4 C#5-4 ';
  K2 = 'D5-4 C#5-4 B4-4 A4-4 G4-4 F#4-4 G4-4 E4-4 ';
  K3 = 'D5-2 F#5-2 A5-2 G5-2 F#5-2 D5-2 F#5-2 E5-2 D5-2 B4-2 D5-2 A4-2 G4-2 B4-2 A4-2 G4-2 ';
  K_CH = 'D:4 A:4 Bm:4 F#m:4 G:4 D:4 G:4 A:4 ';

  // ===== Eigene elektronische Stuecke (Originalkompositionen, Sechzehntel) =====
  // --- "Neon Drive": Bass + Arpeggio + Lead, Am F C G, 1 Takt = 16 ---
  ND_BASS = 'A2-2 A3-2 A2-2 A3-2 A2-2 A3-2 A2-2 A3-2 | F2-2 F3-2 F2-2 F3-2 F2-2 F3-2 F2-2 F3-2 | ' +
            'C3-2 C4-2 C3-2 C4-2 C3-2 C4-2 C3-2 C4-2 | G2-2 G3-2 G2-2 G3-2 G2-2 G3-2 G2-2 G3-2 | ';
  ND_ARP  = 'A4-1 C5-1 E5-1 C5-1 A4-1 C5-1 E5-1 C5-1 A4-1 C5-1 E5-1 C5-1 A4-1 C5-1 E5-1 A5-1 | ' +
            'F4-1 A4-1 C5-1 A4-1 F4-1 A4-1 C5-1 A4-1 F4-1 A4-1 C5-1 A4-1 F4-1 A4-1 C5-1 F5-1 | ' +
            'C5-1 E5-1 G5-1 E5-1 C5-1 E5-1 G5-1 E5-1 C5-1 E5-1 G5-1 E5-1 C5-1 E5-1 G5-1 C6-1 | ' +
            'G4-1 B4-1 D5-1 B4-1 G4-1 B4-1 D5-1 B4-1 G4-1 B4-1 D5-1 B4-1 G4-1 B4-1 D5-1 G5-1 | ';
  ND_LEAD_A = 'E5-6 D5-2 C5-4 D5-4 | A4-8 C5-4 A4-4 | G4-6 C5-2 E5-4 G5-4 | D5-8 B4-4 D5-4 | ';
  ND_LEAD_B = 'A5-4 G5-4 E5-4 C5-4 | F5-6 E5-2 C5-8 | E5-4 G5-4 C6-8 | B4-4 A4-4 G4-4 D5-4 | ';
  // --- "Acid-Linie": einstimmig, 2 Takte ---
  ACID = 'A2-2 A2-1 A3-1 R-1 A2-1 C3-2 A2-1 G2-1 A2-2 E3-1 D3-1 C3-1 A2-1 | ' +
         'A2-1 A3-1 R-2 G3-1 A2-1 C3-2 A2-2 D#3-1 E3-1 G3-2 A3-2 | ';
  // --- "Abendlicht": Duett Lead + Bass, Achtel, Dm Bb F C ---
  AB_LEAD = 'A4-4 F4-2 G4-2 | A4-6 D5-2 | C5-4 A4-2 F4-2 | G4-8 | ' +
            'A4-2 A#4-2 C5-4 | D5-6 C5-2 | A4-4 G4-2 F4-2 | E4-8 | ';
  AB_BASS = 'D3-8 | A#2-8 | F2-8 | C3-8 | D3-8 | A#2-8 | F2-8 | C3-8 | ';
begin
  inherited Create;
  FSampleRate := SampleRate;
  FStartRequest := -2;
  FRand := 987654321;
  FKindMask := SONG_ALL;

  // elektronisch, eigene Kompositionen
  AddSong('Neon Drive (Bass + Arpeggio + Lead)', 118, 4,
    [ 'R-64 ' + ND_LEAD_A + ND_LEAD_B + ND_LEAD_A,          // Lead ab Takt 5
      ND_BASS + ND_BASS + ND_BASS + ND_BASS,
      ND_ARP + ND_ARP + ND_ARP + ND_ARP ]);
  AddSong('Acid-Linie (einstimmig)', 126, 4,
    ['T12 ' + ACID + ACID + ACID + ACID + ACID + ACID + ACID + ACID]);
  AddSong('Abendlicht (Duett)', 92, 2, [AB_LEAD + AB_LEAD, AB_BASS + AB_BASS]);
  // Gefuehls-Wechsel (eigene Kompositionen): wilde/traurige Teile wechseln mit zaertlichen
  // (leise, gebunden, Dur, hoch) - dabei erkennt die Stimmungsanalyse den Wechsel (Herzchen)
  AddSong('Herzklopfen (wild -> zart, Wechsel)', 108, 4,
    [ 'V95 L0 A4-1 C5-1 E5-1 A5-1 G5-1 E5-1 C5-1 A4-1 B4-1 D5-1 F5-1 B5-1 A5-1 F5-1 D5-1 B4-1 | C5-1 E5-1 ' +
      'A5-1 C6-1 B5-1 A5-1 E5-1 C5-1 D5-2 F5-2 G#5-2 B5-2 | A5-2 G5-1 F5-1 E5-2 D5-1 C5-1 B4-2 C5-1 D5-1 ' +
      'E5-2 G#4-2 | A4-1 E5-1 A5-1 E5-1 C6-1 A5-1 E5-1 C5-1 A4-2 R-2 E4-2 R-2 | V95 L0 A4-1 C5-1 E5-1 A5-1 ' +
      'G5-1 E5-1 C5-1 A4-1 B4-1 D5-1 F5-1 B5-1 A5-1 F5-1 D5-1 B4-1 | C5-1 E5-1 A5-1 C6-1 B5-1 A5-1 E5-1 ' +
      'C5-1 D5-2 F5-2 G#5-2 B5-2 | A5-2 G5-1 F5-1 E5-2 D5-1 C5-1 B4-2 C5-1 D5-1 E5-2 G#4-2 | A4-1 E5-1 ' +
      'A5-1 E5-1 C6-1 A5-1 E5-1 C5-1 A4-2 R-2 E4-2 R-2 | V32 L1 E5-8 G5-8 | A5-12 G5-4 | F5-8 E5-8 | D5-16 ' +
      '| E5-8 G5-8 | C6-12 B5-4 | A5-8 G5-8 | E5-16 | V95 L0 A4-1 C5-1 E5-1 A5-1 G5-1 E5-1 C5-1 A4-1 B4-1 ' +
      'D5-1 F5-1 B5-1 A5-1 F5-1 D5-1 B4-1 | C5-1 E5-1 A5-1 C6-1 B5-1 A5-1 E5-1 C5-1 D5-2 F5-2 G#5-2 B5-2 | ' +
      'A5-2 G5-1 F5-1 E5-2 D5-1 C5-1 B4-2 C5-1 D5-1 E5-2 G#4-2 | A4-1 E5-1 A5-1 E5-1 C6-1 A5-1 E5-1 C5-1 ' +
      'A4-2 R-2 E4-2 R-2 | V32 L1 E5-8 G5-8 | A5-12 G5-4 | F5-8 E5-8 | D5-16 | E5-8 G5-8 | C6-12 B5-4 | ' +
      'A5-8 G5-8 | E5-16 | V32 L1 E5-8 G5-8 | A5-12 G5-4 | F5-8 E5-8 | D5-16 | E5-8 G5-8 | C6-12 B5-4 | ' +
      'A5-8 G5-8 | E5-16 | ',
      'V100 L0 A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 ' +
      'A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 ' +
      'R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 ' +
      'E3-1 R-1 | V100 L0 A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 ' +
      'R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 ' +
      'G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 ' +
      'R-1 E2-1 R-1 E3-1 R-1 | V30 L1 C3-16 | F2-16 | D3-16 | G2-16 | A2-16 | F2-16 | D3-16 | C3-16 | V100 ' +
      'L0 A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 ' +
      'R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 ' +
      'F3-1 R-1 E2-1 R-1 E3-1 R-1 | A2-1 R-1 A3-1 R-1 A2-1 R-1 G3-1 R-1 F2-1 R-1 F3-1 R-1 E2-1 R-1 E3-1 ' +
      'R-1 | V30 L1 C3-16 | F2-16 | D3-16 | G2-16 | A2-16 | F2-16 | D3-16 | C3-16 | V30 L1 C3-16 | F2-16 | ' +
      'D3-16 | G2-16 | A2-16 | F2-16 | D3-16 | C3-16 | ',
      'V95 L0 D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | V95 ' +
      'L0 D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | V28 L1 ' +
      'G4-16 | A4-16 | F4-16 | B4-16 | C5-16 | A4-16 | F4-16 | G4-16 | V95 L0 D#4-2 R-6 A#3-2 R-6 | D#4-2 ' +
      'R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | D#4-2 R-6 A#3-2 R-6 | V28 L1 G4-16 | A4-16 | F4-16 | B4-16 | ' +
      'C5-16 | A4-16 | F4-16 | G4-16 | V28 L1 G4-16 | A4-16 | F4-16 | B4-16 | C5-16 | A4-16 | F4-16 | ' +
      'G4-16 | ' ]);
  AddSong('Regentag, dann Sonne (traurig -> zärtlich)', 84, 4,
    [ 'V45 L1 D4-8 F4-4 E4-4 | D4-12 C4-4 | A#3-8 A3-8 | G3-16 | A3-8 C4-4 A#3-4 | A3-12 G3-4 | F3-8 E3-8 ' +
      '| D3-16 | V34 L1 A5-8 C6-8 | D6-12 C6-4 | A#5-8 A5-8 | G5-16 | A5-8 F5-8 | C6-12 A#5-4 | A5-8 G5-8 ' +
      '| F5-16 | V45 L1 D4-8 F4-4 E4-4 | D4-12 C4-4 | A#3-8 A3-8 | G3-16 | A3-8 C4-4 A#3-4 | A3-12 G3-4 | ' +
      'F3-8 E3-8 | D3-16 | V34 L1 A5-8 C6-8 | D6-12 C6-4 | A#5-8 A5-8 | G5-16 | A5-8 F5-8 | C6-12 A#5-4 | ' +
      'A5-8 G5-8 | F5-16 | ',
      'V40 L1 D2-16 | A#1-16 | G1-16 | A1-16 | F1-16 | C2-16 | A#1-16 | D2-16 | V30 L1 F2-16 | A#1-16 | ' +
      'G2-16 | C3-16 | D3-16 | A#1-16 | C3-16 | F2-16 | V40 L1 D2-16 | A#1-16 | G1-16 | A1-16 | F1-16 | ' +
      'C2-16 | A#1-16 | D2-16 | V30 L1 F2-16 | A#1-16 | G2-16 | C3-16 | D3-16 | A#1-16 | C3-16 | F2-16 | ',
      'V30 L1 F3-16 | D3-16 | A#2-16 | C#3-16 | C3-16 | E3-16 | G2-16 | F2-16 | V26 L1 C5-16 | D5-16 | ' +
      'A#4-16 | E5-16 | A4-16 | F4-16 | E4-16 | A4-16 | V30 L1 F3-16 | D3-16 | A#2-16 | C#3-16 | C3-16 | ' +
      'E3-16 | G2-16 | F2-16 | V26 L1 C5-16 | D5-16 | A#4-16 | E5-16 | A4-16 | F4-16 | E4-16 | A4-16 | ' ]);
  AddSong('Sturm und Stille (angespannt -> zart)', 120, 4,
    [ 'V100 L0 E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | ' +
      'E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 ' +
      'E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 ' +
      'F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | V100 L0 E4-1 A#4-1 E5-1 A#4-1 ' +
      'F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 ' +
      'F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 ' +
      'E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 ' +
      'E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | V30 L1 G5-8 E5-8 | D5-8 E5-8 | C5-16 | R-4 E5-4 G5-8 | A5-8 G5-8 ' +
      '| F5-8 D5-8 | E5-8 D5-8 | C5-16 | V100 L0 E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 ' +
      'A#4-1 D#4-1 A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 ' +
      'A4-1 D#5-1 A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 ' +
      'A4-1 | E4-1 A#4-1 E5-1 A#4-1 F4-1 B4-1 F5-1 B4-1 E4-1 A#4-1 E5-1 A#4-1 D#4-1 A4-1 D#5-1 A4-1 | V30 ' +
      'L1 G5-8 E5-8 | D5-8 E5-8 | C5-16 | R-4 E5-4 G5-8 | A5-8 G5-8 | F5-8 D5-8 | E5-8 D5-8 | C5-16 | ',
      'V100 L0 E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 ' +
      'R-2 A#1-2 R-2 | E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 R-2 F2-1 F2-1 R-2 ' +
      'E2-1 E2-1 R-2 A#1-2 R-2 | V100 L0 E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 ' +
      'R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | ' +
      'E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | V28 L1 C3-16 | G2-16 | A2-16 | E2-16 | F2-16 ' +
      '| D3-16 | G2-16 | C3-16 | V100 L0 E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 ' +
      'R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | ' +
      'E2-1 E2-1 R-2 F2-1 F2-1 R-2 E2-1 E2-1 R-2 A#1-2 R-2 | V28 L1 C3-16 | G2-16 | A2-16 | E2-16 | F2-16 ' +
      '| D3-16 | G2-16 | C3-16 | ',
      'V90 L0 A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 ' +
      'B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | V90 L0 A#3-1 R-3 B3-1 R-3 ' +
      'A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 ' +
      'R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | V24 L1 E4-16 | B3-16 | C4-16 | G4-16 | A4-16 | F4-16 ' +
      '| B3-16 | G4-16 | V90 L0 A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 ' +
      'F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | A#3-1 R-3 B3-1 R-3 A#3-1 R-3 F#3-1 R-3 | V24 ' +
      'L1 E4-16 | B3-16 | C4-16 | G4-16 | A4-16 | F4-16 | B3-16 | G4-16 | ' ]);
  // ===== Weitere Stuecke: klassisch (gemeinfrei) voll arrangiert, modern und Techno (eigene) =====
  AddSong('Wiegenlied (Brahms) - voll', 72, 2,
    [ 'V70 L1 E4-1 E4-1 G4-4 | E4-1 E4-1 G4-4 | E4-1 G4-1 C5-2 B4-2 | A4-2 A4-2 G4-2 | D4-1 E4-1 F4-2 D4-2 ' +
      '| D4-1 E4-1 F4-4 | D4-1 F4-1 B4-1 A4-1 G4-2 | B4-2 C5-4 | C4-1 C4-1 C5-4 | A4-1 F4-1 G4-4 | E4-1 ' +
      'C4-1 F4-2 G4-2 | A4-2 G4-4 | C4-1 C4-1 C5-4 | A4-1 F4-1 G4-4 | E4-1 C4-1 F4-1 E4-1 D4-2 | C4-6 | ' +
      'V70 L1 E4-1 E4-1 G4-4 | E4-1 E4-1 G4-4 | E4-1 G4-1 C5-2 B4-2 | A4-2 A4-2 G4-2 | D4-1 E4-1 F4-2 D4-2 ' +
      '| D4-1 E4-1 F4-4 | D4-1 F4-1 B4-1 A4-1 G4-2 | B4-2 C5-4 | C4-1 C4-1 C5-4 | A4-1 F4-1 G4-4 | E4-1 ' +
      'C4-1 F4-2 G4-2 | A4-2 G4-4 | C4-1 C4-1 C5-4 | A4-1 F4-1 G4-4 | E4-1 C4-1 F4-1 E4-1 D4-2 | C4-6 | ',
      'V40 L0 C2-6 | C2-6 | C2-6 | F2-6 | G2-6 | G2-6 | G2-6 | C2-6 | C2-6 | F2-6 | C2-6 | G2-6 | C2-6 | ' +
      'F2-6 | G2-6 | C2-6 | C2-6 | C2-6 | C2-6 | F2-6 | G2-6 | G2-6 | G2-6 | C2-6 | C2-6 | F2-6 | C2-6 | ' +
      'G2-6 | C2-6 | F2-6 | G2-6 | C2-6 | ',
      'V30 L1 C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 ' +
      'E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 ' +
      'B4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 ' +
      'E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 ' +
      'B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 ' +
      'B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 ' +
      'E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 ' +
      'B4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 ' +
      'E4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 ' +
      'E4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 ' +
      'A4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 | ' ]);
  AddSong('Morgenstimmung (Grieg) - voll', 60, 2,
    [ 'V60 L1 G5-1 E5-1 D5-1 C5-1 D5-1 E5-1 | G5-1 E5-1 D5-1 C5-1 D5-1 E5-1 | D5-1 E5-1 G5-1 E5-1 G5-1 ' +
      'A5-1 | E5-1 A5-1 G5-1 E5-1 D5-1 C5-1 | V72 L1 G5-1 E5-1 D5-1 C5-1 D5-1 E5-1 | G5-1 E5-1 D5-1 C5-1 ' +
      'D5-1 E5-1 | D5-1 E5-1 G5-1 E5-1 G5-1 A5-1 | E5-1 A5-1 G5-1 E5-1 D5-1 C5-1 | V66 D5-2 E5-2 D5-2 | ' +
      'C5-6 | ',
      'V40 L0 C2-6 | C2-6 | G2-6 | C2-6 | C2-6 | C2-6 | G2-6 | C2-6 | G2-6 | C2-6 | ',
      'V28 L1 C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | G3-1 B3-1 D4-1 G4-1 D4-1 ' +
      'B3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 ' +
      'E3-1 | G3-1 B3-1 D4-1 G4-1 D4-1 B3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | G3-1 B3-1 D4-1 G4-1 D4-1 ' +
      'B3-1 | C3-1 E3-1 G3-1 C4-1 G3-1 E3-1 | ',
      'V26 L1 C4-6 | C4-6 | G4-6 | C4-6 | C4-6 | C4-6 | G4-6 | C4-6 | G4-6 | C4-6 | ',
      'V26 L1 E4-6 | E4-6 | B4-6 | E4-6 | E4-6 | E4-6 | B4-6 | E4-6 | B4-6 | E4-6 | ',
      'V26 L1 G4-6 | G4-6 | D5-6 | G4-6 | G4-6 | G4-6 | D5-6 | G4-6 | D5-6 | G4-6 | ' ]);
  AddSong('Gymnopedie Nr. 1 (Satie) - voll', 72, 2,
    [ 'R-24 | V55 L1 F#5-2 A5-2 G5-2 | F#5-2 C#5-2 B4-2 | C#5-2 D5-2 A4-2 | A4-6 | F#4-6 | R-18 | F#5-2 ' +
      'A5-2 G5-2 | F#5-2 C#5-2 B4-2 | C#5-2 D5-2 A4-2 | A4-6 | C#5-6 | F#5-6 | E5-12 | ',
      'V40 L0 G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | ' +
      'D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | G2-6 | D2-6 | ',
      'V30 L0 R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 ' +
      'B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 A3-4 | R-2 B3-4 | R-2 ' +
      'A3-4 | R-2 B3-4 | R-2 A3-4 | ',
      'V30 L0 R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | ' +
      'R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | R-2 ' +
      'D4-4 | R-2 C#4-4 | R-2 D4-4 | R-2 C#4-4 | ',
      'V30 L0 R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 ' +
      'F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 ' +
      'F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | R-2 F#4-4 | ' ]);
  AddSong('Mondscheinsonate (Beethoven) - voll', 54, 12,
    [ 'R-192 | V64 L1 R-36 G#4-9 G#4-3 | G#4-36 G#4-9 G#4-3 | G#4-24 A4-24 | G#4-24 F#4-24 | E4-36 ' +
      'G#4-9 G#4-3 | G#4-36 G#4-9 G#4-3 | G#4-24 A4-24 | G#4-24 F#4-24 | C#4-48 | ',
      'V36 L0 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | G#3-4 C#4-4 E4-4 ' +
      'G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | A3-4 C#4-4 E4-4 A3-4 C#4-4 E4-4 A3-4 D4-4 ' +
      'F#4-4 A3-4 D4-4 F#4-4 | G#3-4 C4-4 F#4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 D#4-4 F#3-4 C4-4 D#4-4 | ' +
      'G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | G#3-4 C#4-4 E4-4 G#3-4 ' +
      'C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | A3-4 C#4-4 E4-4 A3-4 C#4-4 E4-4 A3-4 D4-4 F#4-4 ' +
      'A3-4 D4-4 F#4-4 | G#3-4 C4-4 F#4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 D#4-4 F#3-4 C4-4 D#4-4 | G#3-4 ' +
      'C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | G#3-4 C#4-4 E4-4 G#3-4 C#4-4 ' +
      'E4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 E4-4 | A3-4 C#4-4 E4-4 A3-4 C#4-4 E4-4 A3-4 D4-4 F#4-4 A3-4 ' +
      'D4-4 F#4-4 | G#3-4 C4-4 F#4-4 G#3-4 C#4-4 E4-4 G#3-4 C#4-4 D#4-4 F#3-4 C4-4 D#4-4 | G#3-4 C#4-4 ' +
      'E4-4 G#3-4 C#4-4 E4-4 G#3-12 C#4-12 | ',
      'V46 L1 C#2-48 | B1-48 | A1-24 F#1-24 | G#1-48 | C#2-48 | B1-48 | A1-24 F#1-24 | G#1-48 | C#2-48 ' +
      '| B1-48 | A1-24 F#1-24 | G#1-48 | C#2-48 | ',
      'V40 L1 C#3-48 | B2-48 | A2-24 F#2-24 | G#2-48 | C#3-48 | B2-48 | A2-24 F#2-24 | G#2-48 | C#3-48 ' +
      '| B2-48 | A2-24 F#2-24 | G#2-48 | C#3-48 | ' ]);
  AddSong('Präludium C-Dur (Bach) - voll', 66, 4,
    [ 'V38 L0 R-1 R-1 G4-1 C5-1 E5-1 G4-1 C5-1 E5-1 R-1 R-1 G4-1 C5-1 E5-1 G4-1 C5-1 E5-1 | R-1 R-1 ' +
      'A4-1 D5-1 F5-1 A4-1 D5-1 F5-1 R-1 R-1 A4-1 D5-1 F5-1 A4-1 D5-1 F5-1 | R-1 R-1 G4-1 D5-1 F5-1 ' +
      'G4-1 D5-1 F5-1 R-1 R-1 G4-1 D5-1 F5-1 G4-1 D5-1 F5-1 | R-1 R-1 G4-1 C5-1 E5-1 G4-1 C5-1 E5-1 R-1 ' +
      'R-1 G4-1 C5-1 E5-1 G4-1 C5-1 E5-1 | R-1 R-1 A4-1 E5-1 A5-1 A4-1 E5-1 A5-1 R-1 R-1 A4-1 E5-1 A5-1 ' +
      'A4-1 E5-1 A5-1 | R-1 R-1 F#4-1 A4-1 D5-1 F#4-1 A4-1 D5-1 R-1 R-1 F#4-1 A4-1 D5-1 F#4-1 A4-1 D5-1 ' +
      '| R-1 R-1 G4-1 D5-1 G5-1 G4-1 D5-1 G5-1 R-1 R-1 G4-1 D5-1 G5-1 G4-1 D5-1 G5-1 | R-1 R-1 E4-1 ' +
      'G4-1 C5-1 E4-1 G4-1 C5-1 R-1 R-1 E4-1 G4-1 C5-1 E4-1 G4-1 C5-1 | R-1 R-1 E4-1 G4-1 C5-1 E4-1 ' +
      'G4-1 C5-1 R-1 R-1 E4-1 G4-1 C5-1 E4-1 G4-1 C5-1 | R-1 R-1 D4-1 F#4-1 C5-1 D4-1 F#4-1 C5-1 R-1 ' +
      'R-1 D4-1 F#4-1 C5-1 D4-1 F#4-1 C5-1 | R-1 R-1 D4-1 G4-1 B4-1 D4-1 G4-1 B4-1 R-1 R-1 D4-1 G4-1 ' +
      'B4-1 D4-1 G4-1 B4-1 | R-1 R-1 E4-1 G4-1 C#5-1 E4-1 G4-1 C#5-1 R-1 R-1 E4-1 G4-1 C#5-1 E4-1 G4-1 ' +
      'C#5-1 | R-1 R-1 D4-1 A4-1 D5-1 D4-1 A4-1 D5-1 R-1 R-1 D4-1 A4-1 D5-1 D4-1 A4-1 D5-1 | R-1 R-1 ' +
      'D4-1 F4-1 B4-1 D4-1 F4-1 B4-1 R-1 R-1 D4-1 F4-1 B4-1 D4-1 F4-1 B4-1 | R-1 R-1 C4-1 G4-1 C5-1 ' +
      'C4-1 G4-1 C5-1 R-1 R-1 C4-1 G4-1 C5-1 C4-1 G4-1 C5-1 | R-1 R-1 A3-1 C4-1 F4-1 A3-1 C4-1 F4-1 R-1 ' +
      'R-1 A3-1 C4-1 F4-1 A3-1 C4-1 F4-1 | R-1 R-1 A3-1 C4-1 F4-1 A3-1 C4-1 F4-1 R-1 R-1 A3-1 C4-1 F4-1 ' +
      'A3-1 C4-1 F4-1 | R-1 R-1 G3-1 B3-1 F4-1 G3-1 B3-1 F4-1 R-1 R-1 G3-1 B3-1 F4-1 G3-1 B3-1 F4-1 | ' +
      'R-1 R-1 G3-1 C4-1 E4-1 G3-1 C4-1 E4-1 R-1 R-1 G3-1 C4-1 E4-1 G3-1 C4-1 E4-1 | R-2 G3-2 C4-2 ' +
      'E4-10 | ',
      'V46 L1 C4-8 C4-8 | C4-8 C4-8 | B3-8 B3-8 | C4-8 C4-8 | C4-8 C4-8 | C4-8 C4-8 | B3-8 B3-8 | B3-8 ' +
      'B3-8 | A3-8 A3-8 | D3-8 D3-8 | G3-8 G3-8 | G3-8 G3-8 | F3-8 F3-8 | F3-8 F3-8 | E3-8 E3-8 | E3-8 ' +
      'E3-8 | D3-8 D3-8 | G2-8 G2-8 | C3-8 C3-8 | C3-16 | ',
      'V40 L1 R-1 E4-7 R-1 E4-7 | R-1 D4-7 R-1 D4-7 | R-1 D4-7 R-1 D4-7 | R-1 E4-7 R-1 E4-7 | R-1 E4-7 ' +
      'R-1 E4-7 | R-1 D4-7 R-1 D4-7 | R-1 D4-7 R-1 D4-7 | R-1 C4-7 R-1 C4-7 | R-1 C4-7 R-1 C4-7 | R-1 ' +
      'A3-7 R-1 A3-7 | R-1 B3-7 R-1 B3-7 | R-1 Bb3-7 R-1 Bb3-7 | R-1 A3-7 R-1 A3-7 | R-1 Ab3-7 R-1 ' +
      'Ab3-7 | R-1 G3-7 R-1 G3-7 | R-1 F3-7 R-1 F3-7 | R-1 F3-7 R-1 F3-7 | R-1 D3-7 R-1 D3-7 | R-1 E3-7 ' +
      'R-1 E3-7 | R-1 E3-15 | ' ]);
  AddSong('Eine kleine Nachtmusik (Mozart) - voll', 132, 2,
    [ 'V80 L0 G4-2 R-1 D4-1 G4-2 R-1 D4-1 | G4-1 D4-1 G4-1 B4-1 D5-4 | C5-2 R-1 A4-1 C5-2 R-1 A4-1 | C5-1 ' +
      'A4-1 F#4-1 A4-1 D4-4 | V72 L0 G5-2 R-1 D5-1 G5-2 R-1 D5-1 | G5-1 D5-1 G5-1 B5-1 D6-4 | C6-2 R-1 ' +
      'A5-1 C6-2 R-1 A5-1 | C6-1 A5-1 F#5-1 A5-1 D6-4 | V80 G4-2 B4-2 D5-2 B4-2 | G4-4 R-4 | ',
      'V50 L0 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | D2-1 ' +
      'D3-1 D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 | D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 | G2-1 G3-1 G2-1 G3-1 ' +
      'G2-1 G3-1 G2-1 G3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 D2-1 ' +
      'D3-1 | D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 D2-1 D3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | G2-1 ' +
      'G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | ',
      'V35 L0 G4-1 D5-1 B4-1 D5-1 G4-1 D5-1 B4-1 D5-1 | G4-1 D5-1 B4-1 D5-1 G4-1 D5-1 B4-1 D5-1 | D4-1 ' +
      'A4-1 F#4-1 A4-1 D4-1 A4-1 F#4-1 A4-1 | D4-1 A4-1 F#4-1 A4-1 D4-1 A4-1 F#4-1 A4-1 | G4-1 D5-1 B4-1 ' +
      'D5-1 G4-1 D5-1 B4-1 D5-1 | G4-1 D5-1 B4-1 D5-1 G4-1 D5-1 B4-1 D5-1 | D4-1 A4-1 F#4-1 A4-1 D4-1 A4-1 ' +
      'F#4-1 A4-1 | D4-1 A4-1 F#4-1 A4-1 D4-1 A4-1 F#4-1 A4-1 | G4-1 D5-1 B4-1 D5-1 G4-1 D5-1 B4-1 D5-1 | ' +
      'G4-1 D5-1 B4-1 D5-1 G4-1 D5-1 B4-1 D5-1 | ' ]);
  AddSong('Schwanensee - Thema (Tschaikowski) - voll', 76, 2,
    [ 'V65 L1 F#4-6 B3-1 C#4-1 | D4-1 E4-1 F#4-6 | D4-2 F#4-6 | D4-2 F#4-6 | B3-2 D4-2 B3-2 G3-2 | D4-2 ' +
      'B3-6 | R-8 | R-8 | V78 L1 F#5-6 B4-1 C#5-1 | D5-1 E5-1 F#5-6 | D5-2 F#5-6 | D5-2 F#5-6 | B4-2 D5-2 ' +
      'B4-2 G4-2 | D5-2 B4-6 | R-8 | R-8 | ',
      'V45 L0 B2-8 | B2-8 | B2-8 | B2-8 | G2-8 | B2-8 | F#2-8 | B2-8 | B2-8 | B2-8 | B2-8 | B2-8 | G2-8 | ' +
      'B2-8 | F#2-8 | B2-8 | ',
      'V32 L0 B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | B4-1 ' +
      'D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | G4-1 B4-1 D5-1 ' +
      'G4-1 B4-1 D5-1 G4-1 B4-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | F#4-1 A#4-1 C#5-1 F#4-1 ' +
      'A#4-1 C#5-1 F#4-1 A#4-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 ' +
      'F#5-1 B4-1 D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 ' +
      'D5-1 | B4-1 D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | G4-1 B4-1 D5-1 G4-1 B4-1 D5-1 G4-1 B4-1 | B4-1 ' +
      'D5-1 F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | F#4-1 A#4-1 C#5-1 F#4-1 A#4-1 C#5-1 F#4-1 A#4-1 | B4-1 D5-1 ' +
      'F#5-1 B4-1 D5-1 F#5-1 B4-1 D5-1 | ',
      'V28 L1 B3-8 | B3-8 | B3-8 | B3-8 | G3-8 | B3-8 | F#3-8 | B3-8 | B3-8 | B3-8 | B3-8 | B3-8 | G3-8 | ' +
      'B3-8 | F#3-8 | B3-8 | ',
      'V28 L1 D4-8 | D4-8 | D4-8 | D4-8 | B3-8 | D4-8 | A#3-8 | D4-8 | D4-8 | D4-8 | D4-8 | D4-8 | B3-8 | ' +
      'D4-8 | A#3-8 | D4-8 | ',
      'V28 L1 F#4-8 | F#4-8 | F#4-8 | F#4-8 | D4-8 | F#4-8 | C#4-8 | F#4-8 | F#4-8 | F#4-8 | F#4-8 | F#4-8 ' +
      '| D4-8 | F#4-8 | C#4-8 | F#4-8 | ' ]);
  AddSong('Sternennacht (Ballade, eigene)', 76, 2,
    [ 'V58 L1 E5-4 D5-2 C5-2 | D5-6 G4-2 | C5-4 B4-2 A4-2 | G4-8 | A4-4 G4-2 F4-2 | E4-4 G4-4 | F4-2 E4-2 ' +
      'D4-2 C4-2 | D4-8 | V74 G5-4 E5-2 D5-2 | E5-6 C5-2 | D5-4 C5-2 A4-2 | C5-8 | A5-4 G5-2 E5-2 | F5-4 ' +
      'E5-4 | D5-2 E5-2 F5-2 D5-2 | C5-8 | V58 L1 E5-4 D5-2 C5-2 | D5-6 G4-2 | C5-4 B4-2 A4-2 | G4-8 | ' +
      'A4-4 G4-2 F4-2 | E4-4 G4-4 | F4-2 E4-2 D4-2 C4-2 | D4-8 | V74 G5-4 E5-2 D5-2 | E5-6 C5-2 | D5-4 ' +
      'C5-2 A4-2 | C5-8 | A5-4 G5-2 E5-2 | F5-4 E5-4 | D5-2 E5-2 F5-2 D5-2 | C5-8 | ',
      'V45 L0 C2-4 G2-4 | G2-4 D2-4 | A2-4 E2-4 | E2-4 B2-4 | F2-4 C2-4 | C2-4 G2-4 | D2-4 A2-4 | G2-4 ' +
      'D2-4 | C2-4 G2-4 | A2-4 E2-4 | F2-4 C2-4 | G2-4 D2-4 | F2-4 C2-4 | C2-4 G2-4 | G2-4 D2-4 | C2-4 ' +
      'G2-4 | C2-4 G2-4 | G2-4 D2-4 | A2-4 E2-4 | E2-4 B2-4 | F2-4 C2-4 | C2-4 G2-4 | D2-4 A2-4 | G2-4 ' +
      'D2-4 | C2-4 G2-4 | A2-4 E2-4 | F2-4 C2-4 | G2-4 D2-4 | F2-4 C2-4 | C2-4 G2-4 | G2-4 D2-4 | C2-4 ' +
      'G2-4 | ',
      'V30 L1 C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | A4-1 ' +
      'C5-1 E5-1 A5-1 E5-1 C5-1 E5-1 C5-1 | E4-1 G4-1 B4-1 E5-1 B4-1 G4-1 B4-1 G4-1 | F4-1 A4-1 C5-1 F5-1 ' +
      'C5-1 A4-1 C5-1 A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | D4-1 F4-1 A4-1 D5-1 A4-1 F4-1 A4-1 ' +
      'F4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | A4-1 ' +
      'C5-1 E5-1 A5-1 E5-1 C5-1 E5-1 C5-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 C5-1 A4-1 | G4-1 B4-1 D5-1 G5-1 ' +
      'D5-1 B4-1 D5-1 B4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 C5-1 A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 ' +
      'E4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | C4-1 ' +
      'E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | A4-1 C5-1 E5-1 A5-1 ' +
      'E5-1 C5-1 E5-1 C5-1 | E4-1 G4-1 B4-1 E5-1 B4-1 G4-1 B4-1 G4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 C5-1 ' +
      'A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | D4-1 F4-1 A4-1 D5-1 A4-1 F4-1 A4-1 F4-1 | G4-1 ' +
      'B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | A4-1 C5-1 E5-1 A5-1 ' +
      'E5-1 C5-1 E5-1 C5-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 C5-1 A4-1 | G4-1 B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 ' +
      'B4-1 | F4-1 A4-1 C5-1 F5-1 C5-1 A4-1 C5-1 A4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | G4-1 ' +
      'B4-1 D5-1 G5-1 D5-1 B4-1 D5-1 B4-1 | C4-1 E4-1 G4-1 C5-1 G4-1 E4-1 G4-1 E4-1 | ',
      'V24 L1 C4-8 | G4-8 | A3-8 | E4-8 | F4-8 | C4-8 | D4-8 | G4-8 | C4-8 | A3-8 | F4-8 | G4-8 | F4-8 | ' +
      'C4-8 | G4-8 | C4-8 | C4-8 | G4-8 | A3-8 | E4-8 | F4-8 | C4-8 | D4-8 | G4-8 | C4-8 | A3-8 | F4-8 | ' +
      'G4-8 | F4-8 | C4-8 | G4-8 | C4-8 | ',
      'V24 L1 E4-8 | B4-8 | C4-8 | G4-8 | A4-8 | E4-8 | F4-8 | B4-8 | E4-8 | C4-8 | A4-8 | B4-8 | A4-8 | ' +
      'E4-8 | B4-8 | E4-8 | E4-8 | B4-8 | C4-8 | G4-8 | A4-8 | E4-8 | F4-8 | B4-8 | E4-8 | C4-8 | A4-8 | ' +
      'B4-8 | A4-8 | E4-8 | B4-8 | E4-8 | ',
      'V24 L1 G4-8 | D5-8 | E4-8 | B4-8 | C5-8 | G4-8 | A4-8 | D5-8 | G4-8 | E4-8 | C5-8 | D5-8 | C5-8 | ' +
      'G4-8 | D5-8 | G4-8 | G4-8 | D5-8 | E4-8 | B4-8 | C5-8 | G4-8 | A4-8 | D5-8 | G4-8 | E4-8 | C5-8 | ' +
      'D5-8 | C5-8 | G4-8 | D5-8 | G4-8 | ' ]);
  AddSong('Leuchtfeuer (Synthpop, eigene)', 112, 4,
    [ 'R-64 | V75 L0 A4-2 C5-2 E5-4 D5-2 C5-2 B4-4 | C5-2 D5-2 E5-4 G5-4 E5-4 | F5-2 E5-2 D5-4 C5-2 D5-2 ' +
      'E5-4 | D5-8 R-8 | V75 L0 A4-2 C5-2 E5-4 D5-2 C5-2 B4-4 | C5-2 D5-2 E5-4 G5-4 E5-4 | F5-2 E5-2 D5-4 ' +
      'C5-2 D5-2 E5-4 | D5-8 R-8 | V75 L0 A4-2 C5-2 E5-4 D5-2 C5-2 B4-4 | C5-2 D5-2 E5-4 G5-4 E5-4 | F5-2 ' +
      'E5-2 D5-4 C5-2 D5-2 E5-4 | D5-8 R-8 | ',
      'V55 L0 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 | C2-1 C3-1 ' +
      'C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 | F2-1 F3-1 F2-1 F3-1 F2-1 ' +
      'F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 ' +
      'G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 ' +
      'A3-1 A2-1 A3-1 A2-1 A3-1 | C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 ' +
      'C2-1 C3-1 | F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 | G2-1 ' +
      'G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | A2-1 A3-1 A2-1 A3-1 ' +
      'A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 | C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 ' +
      'C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 | F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 ' +
      'F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 ' +
      'G3-1 G2-1 G3-1 | A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 A2-1 A3-1 | ' +
      'C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 C2-1 C3-1 | F2-1 F3-1 F2-1 ' +
      'F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 F2-1 F3-1 | G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 ' +
      'G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 G2-1 G3-1 | ',
      'V34 L0 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 | C4-1 E4-1 ' +
      'G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 | F4-1 A4-1 C5-1 F5-1 F4-1 ' +
      'A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 | G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 ' +
      'G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 | A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 ' +
      'A5-1 A4-1 C5-1 E5-1 A5-1 | C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 ' +
      'G4-1 C5-1 | F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 | G4-1 ' +
      'B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 | A4-1 C5-1 E5-1 A5-1 ' +
      'A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 | C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 ' +
      'C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 | F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 ' +
      'C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 | G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 G4-1 ' +
      'B4-1 D5-1 G5-1 | A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 A4-1 C5-1 E5-1 A5-1 | ' +
      'C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 C4-1 E4-1 G4-1 C5-1 | F4-1 A4-1 C5-1 ' +
      'F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 F4-1 A4-1 C5-1 F5-1 | G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 ' +
      'D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 G4-1 B4-1 D5-1 G5-1 | ',
      'V22 L1 A3-16 | C4-16 | F4-16 | G4-16 | A3-16 | C4-16 | F4-16 | G4-16 | A3-16 | C4-16 | F4-16 | ' +
      'G4-16 | A3-16 | C4-16 | F4-16 | G4-16 | ',
      'V22 L1 C4-16 | E4-16 | A4-16 | B4-16 | C4-16 | E4-16 | A4-16 | B4-16 | C4-16 | E4-16 | A4-16 | ' +
      'B4-16 | C4-16 | E4-16 | A4-16 | B4-16 | ',
      'V22 L1 E4-16 | G4-16 | C5-16 | D5-16 | E4-16 | G4-16 | C5-16 | D5-16 | E4-16 | G4-16 | C5-16 | ' +
      'D5-16 | E4-16 | G4-16 | C5-16 | D5-16 | ' ]);
  AddSong('Tunnelblick (Techno, eigene)', 128, 4,
    [ 'R-64 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | ' +
      'V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 ' +
      'A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 ' +
      'A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 ' +
      'R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 ' +
      'R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 ' +
      'C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | ' +
      'A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 ' +
      'A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 ' +
      'R-2 G4-2 R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 ' +
      'R-2 E4-4 | V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 ' +
      '| V80 L0 A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | V80 L0 ' +
      'A4-2 R-2 A4-1 C5-1 R-2 E5-2 R-2 D5-2 C5-2 | A4-2 R-2 A4-1 C5-1 R-2 G4-2 R-2 E4-4 | ',
      'V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 ' +
      'R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 ' +
      'R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 ' +
      'G1-2 R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | ' +
      'R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 ' +
      'R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 ' +
      'G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 ' +
      'A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | V90 L0 ' +
      'R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 R-2 ' +
      'A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 ' +
      'A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 ' +
      'R-2 G1-2 | V90 L0 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 | R-2 ' +
      'A1-2 R-2 A1-2 R-2 A1-2 R-2 A1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 R-2 G1-2 | ',
      'V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 ' +
      'R-4 G3-1 R-3 | V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 ' +
      'R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 ' +
      'A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 ' +
      'A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 ' +
      'R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | V60 L0 R-4 A3-1 ' +
      'R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | ' +
      'V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 R-3 R-4 A3-1 R-3 ' +
      'R-4 G3-1 R-3 | V60 L0 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 R-4 A3-1 R-3 | R-4 A3-1 R-3 R-4 G3-1 ' +
      'R-3 R-4 A3-1 R-3 R-4 G3-1 R-3 | ' ]);
  AddSong('Morgengrau (Detroit-Techno, eigene)', 124, 4,
    [ 'R-64 | V65 L1 C5-8 G#4-8 | A#4-8 G4-8 | G#4-8 F4-8 | G4-16 | V65 L1 C5-8 G#4-8 | A#4-8 G4-8 | G#4-8 ' +
      'F4-8 | G4-16 | V65 L1 C5-8 G#4-8 | A#4-8 G4-8 | G#4-8 F4-8 | G4-16 | ',
      'V85 L0 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 | D#2-1 R-1 D#3-1 ' +
      'R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 | C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 ' +
      'C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 | C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 ' +
      'C3-1 R-1 C2-1 R-1 C3-1 R-1 | V85 L0 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 R-1 ' +
      'F3-1 R-1 | D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 | C#2-1 ' +
      'R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 | C2-1 R-1 C3-1 R-1 C2-1 ' +
      'R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 | V85 L0 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 ' +
      'R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 | D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 D#2-1 ' +
      'R-1 D#3-1 R-1 | C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 | ' +
      'C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 | V85 L0 F2-1 R-1 F3-1 R-1 ' +
      'F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 F2-1 R-1 F3-1 R-1 | D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 ' +
      'D#2-1 R-1 D#3-1 R-1 D#2-1 R-1 D#3-1 R-1 | C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 R-1 C#2-1 R-1 C#3-1 ' +
      'R-1 C#2-1 R-1 C#3-1 R-1 | C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 C2-1 R-1 C3-1 R-1 | ',
      'V55 L0 R-2 G#4-1 R-1 R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | R-2 F4-1 R-1 ' +
      'R-4 F4-1 R-3 R-2 F4-2 | R-2 E4-1 R-1 R-4 E4-1 R-3 R-2 E4-2 | V55 L0 R-2 G#4-1 R-1 R-4 G#4-1 R-3 R-2 ' +
      'G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | R-2 F4-1 R-1 R-4 F4-1 R-3 R-2 F4-2 | R-2 E4-1 R-1 R-4 ' +
      'E4-1 R-3 R-2 E4-2 | V55 L0 R-2 G#4-1 R-1 R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 ' +
      'G4-2 | R-2 F4-1 R-1 R-4 F4-1 R-3 R-2 F4-2 | R-2 E4-1 R-1 R-4 E4-1 R-3 R-2 E4-2 | V55 L0 R-2 G#4-1 ' +
      'R-1 R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | R-2 F4-1 R-1 R-4 F4-1 R-3 R-2 ' +
      'F4-2 | R-2 E4-1 R-1 R-4 E4-1 R-3 R-2 E4-2 | ',
      'V55 L0 R-2 C5-1 R-1 R-4 C5-1 R-3 R-2 C5-2 | R-2 A#4-1 R-1 R-4 A#4-1 R-3 R-2 A#4-2 | R-2 G#4-1 R-1 ' +
      'R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | V55 L0 R-2 C5-1 R-1 R-4 C5-1 R-3 R-2 ' +
      'C5-2 | R-2 A#4-1 R-1 R-4 A#4-1 R-3 R-2 A#4-2 | R-2 G#4-1 R-1 R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 ' +
      'R-4 G4-1 R-3 R-2 G4-2 | V55 L0 R-2 C5-1 R-1 R-4 C5-1 R-3 R-2 C5-2 | R-2 A#4-1 R-1 R-4 A#4-1 R-3 R-2 ' +
      'A#4-2 | R-2 G#4-1 R-1 R-4 G#4-1 R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | V55 L0 R-2 ' +
      'C5-1 R-1 R-4 C5-1 R-3 R-2 C5-2 | R-2 A#4-1 R-1 R-4 A#4-1 R-3 R-2 A#4-2 | R-2 G#4-1 R-1 R-4 G#4-1 ' +
      'R-3 R-2 G#4-2 | R-2 G4-1 R-1 R-4 G4-1 R-3 R-2 G4-2 | ' ]);
  // klassisch / traditionell
  AddSong('Ode an die Freude (Beethoven)', 112, 2, [ODE + ODE], ODE_CH + ODE_CH);
  AddSong('Bruder Jakob (Kanon, 3 Stimmen)', 104, 2,
    [JAKOB + JAKOB + JAKOB,
     'T-12 R-16 ' + JAKOB + JAKOB + JAKOB,
     'T-24 R-32 ' + JAKOB + JAKOB + JAKOB]);
  AddSong('Für Elise (Beethoven)', 66, 4, [ELISE_R + ELISE_R, ELISE_L + ELISE_L]);
  AddSong('Greensleeves (traditionell)', 104, 2, [GREEN], GREEN_CH);
  AddSong('Menuett G-Dur (Petzold)', 116, 2, [MENU], MENU_CH);
  AddSong('Kanon in D (Pachelbel)', 66, 2,
    ['R-32 ' + K1 + K2 + K3 + K1 + K2,
     'R-64 ' + K1 + K2 + K3 + K1,
     'R-96 ' + K1 + K2 + K3],
    K_CH + K_CH + K_CH + K_CH + K_CH + K_CH);

  // ===== Liegetoene (1 Einheit = 1 s bei 60 BPM): wenig Melodie, der Klang soll wirken =====
  AddSong('Liegeton: ein Ton, dann die Quinte dazu', 60, 1,
    ['A3-20 R-1 D3-20 R-1 A3-20 R-1',
     'R-8 E4-12 R-9 A3-12 R-9 E4-12 R-1']);
  FSongs[High(FSongs)].Kind := SONG_DRONE;
  AddSong('Liegeton: Oktave und Terz schweben dazu', 60, 1,
    ['C3-24 R-1 F3-24 R-1',
     'R-6 C4-18 R-7 F4-18 R-1',
     'R-12 E4-12 R-13 A4-12 R-1']);
  FSongs[High(FSongs)].Kind := SONG_DRONE;
  AddSong('Liegeton: langsame Akkordwechsel (Am F C G)', 60, 1,
    ['A2-10 F2-10 C3-10 G2-10 A2-12',
     'C4-10 A3-10 E4-10 B3-10 C4-12',
     'R-3 E4-7 R-3 C4-7 R-3 G4-7 R-3 D4-7 R-3 E4-9']);
  FSongs[High(FSongs)].Kind := SONG_DRONE;
  AddSong('Liegeton: tiefer Einzelton', 60, 1, ['D2-30 R-2 A1-30 R-2']);
  FSongs[High(FSongs)].Kind := SONG_DRONE;
  AddSong('Liegeton: hoher Ton mit Wechsel', 60, 1,
    ['E4-16 R-1 G4-16 R-1 D4-16 R-1',
     'R-10 B4-7 R-10 D5-7 R-10 A4-7 R-1']);
  FSongs[High(FSongs)].Kind := SONG_DRONE;

  // ===== Akkorde fuer den Arpeggiator (gehalten, 1 Einheit = 1 Schlag) =====
  AddSong('Arp: Akkorde Am F C G (je 1 Takt)', 120, 1,
    ['A3-4 F3-4 C4-4 G3-4 A3-4 F3-4 C4-4 G3-4 A3-4 F3-4 C4-4 G3-4 A3-4 F3-4 C4-4 G3-4',
     'C4-4 A3-4 E4-4 B3-4 C4-4 A3-4 E4-4 B3-4 C4-4 A3-4 E4-4 B3-4 C4-4 A3-4 E4-4 B3-4',
     'E4-4 C4-4 G4-4 D4-4 E4-4 C4-4 G4-4 D4-4 E4-4 C4-4 G4-4 D4-4 E4-4 C4-4 G4-4 D4-4']);
  FSongs[High(FSongs)].Kind := SONG_ARP;
  AddSong('Arp: Einzelton mit Wechsel', 120, 1, ['A3-8 F3-8 C4-8 G3-8 A3-8 F3-8 C4-8 G3-8']);
  FSongs[High(FSongs)].Kind := SONG_ARP;
  AddSong('Arp: Dm7 - G7 - Cmaj7 (je 2 Takte)', 110, 1,
    ['D3-8 G3-8 C3-8 C3-8 D3-8 G3-8 C3-8 C3-8',
     'F3-8 B3-8 E3-8 E3-8 F3-8 B3-8 E3-8 E3-8',
     'A3-8 D4-8 G3-8 G3-8 A3-8 D4-8 G3-8 G3-8',
     'C4-8 F4-8 B3-8 B3-8 C4-8 F4-8 B3-8 B3-8']);
  FSongs[High(FSongs)].Kind := SONG_ARP;
end;

procedure TAutoPlayer.ExportMidi(Index: Integer; const FileName: string);
const
  PPQ = 480;
var
  Song: ^TSong;
  Trk: TBytesStream;
  F: TFileStream;
  I, LastTick, Tick, Delta: Integer;
  SamplesPerBeat: Double;
  E: TSeqEvent;
  Tempo: Cardinal;
  Name: UTF8String;

  procedure WVar(V: Cardinal);
  var
    Buf: array[0..4] of Byte;
    N, J: Integer;
  begin
    // variable Laenge (7 Bit je Byte, hoechstes Bit = weitere Bytes folgen)
    N := 0;
    Buf[0] := V and $7F;
    V := V shr 7;
    while V > 0 do
    begin
      Inc(N);
      Buf[N] := (V and $7F) or $80;
      V := V shr 7;
    end;
    for J := N downto 0 do
      Trk.WriteBuffer(Buf[J], 1);
  end;

  procedure WB(V: Byte);
  begin
    Trk.WriteBuffer(V, 1);
  end;

  procedure WBE32(S: TStream; V: Cardinal);
  var
    Bt: array[0..3] of Byte;
  begin
    Bt[0] := V shr 24; Bt[1] := V shr 16; Bt[2] := V shr 8; Bt[3] := V;
    S.WriteBuffer(Bt, 4);
  end;

  procedure WBE16(S: TStream; V: Word);
  var
    Bt: array[0..1] of Byte;
  begin
    Bt[0] := V shr 8; Bt[1] := V;
    S.WriteBuffer(Bt, 2);
  end;

begin
  Song := @FSongs[Index];
  SamplesPerBeat := FSampleRate * 60 / Song.Bpm;
  Trk := TBytesStream.Create;
  try
    // Spurname und Tempo
    Name := UTF8String(Song.Title);
    WVar(0); WB($FF); WB($03); WVar(Length(Name));
    if Length(Name) > 0 then Trk.WriteBuffer(Name[1], Length(Name));
    Tempo := Round(60000000 / Song.Bpm);
    WVar(0); WB($FF); WB($51); WB(3); WB(Tempo shr 16); WB(Tempo shr 8); WB(Tempo);
    LastTick := 0;
    for I := 0 to High(Song.Events) do
    begin
      E := Song.Events[I];
      Tick := Round(E.Time / SamplesPerBeat * PPQ);
      Delta := Max(0, Tick - LastTick);
      LastTick := LastTick + Delta;
      WVar(Delta);
      if E.IsOn then
      begin
        WB($90); WB(EnsureRange(E.Note, 0, 127)); WB(EnsureRange(Round(E.Velocity * 127), 1, 127));
      end
      else
      begin
        WB($80); WB(EnsureRange(E.Note, 0, 127)); WB(64);
      end;
    end;
    WVar(PPQ); WB($FF); WB($2F); WB(0);     // Spurende (eine Viertel nach der letzten Note)
    F := TFileStream.Create(FileName, fmCreate);
    try
      F.WriteBuffer(AnsiString('MThd')[1], 4);
      WBE32(F, 6);
      WBE16(F, 0);       // Typ 0
      WBE16(F, 1);       // eine Spur
      WBE16(F, PPQ);
      F.WriteBuffer(AnsiString('MTrk')[1], 4);
      WBE32(F, Trk.Size);
      F.WriteBuffer(Trk.Bytes[0], Trk.Size);
    finally
      F.Free;
    end;
  finally
    Trk.Free;
  end;
end;

function TAutoPlayer.GetKind(Index: Integer): Integer;
begin
  Result := FSongs[Index].Kind;
end;

function TAutoPlayer.CurrentKind: Integer;
begin
  if FPlaying then
    Result := FSongs[FCurrent].Kind
  else
    Result := 0;
end;

{ zufaelliges Stueck der erlaubten Arten (nicht Exclude, wenn es eine Alternative gibt) }
function TAutoPlayer.PickRandom(Exclude: Integer): Integer;
var
  Cand: array of Integer;
  I, Mask: Integer;
begin
  Mask := FKindMask;
  if Mask = 0 then
    Mask := SONG_ALL;
  // Zufall = Musik hoeren: Liegetoene und Arp-Testakkorde nur ueber die Direktwahl
  Mask := Mask and not (SONG_DRONE or SONG_ARP);
  if Mask = 0 then
    Mask := SONG_ALL and not (SONG_DRONE or SONG_ARP);
  Cand := nil;
  for I := 0 to High(FSongs) do
    if (FSongs[I].Kind and Mask <> 0) and (I <> Exclude) then
      Cand := Cand + [I];
  if Length(Cand) = 0 then
    for I := 0 to High(FSongs) do
      if FSongs[I].Kind and Mask <> 0 then
        Cand := Cand + [I];
  if Length(Cand) = 0 then
    Exit(0);
  Result := Cand[Trunc(Rand * Length(Cand)) mod Length(Cand)];
end;

procedure TAutoPlayer.AddSong(const Title: string; Bpm: Double; UnitsPerBeat: Integer;
  const Voices: array of string; const Chords: string);
var
  Song: TSong;
  UnitSamples: Double;
  AllVoices: TArray<string>;
  V, Midi, P, Units, Transpose: Integer;
  T: Double;
  Tok, Name: string;
  Bass, Third, Fifth: string;
  Vel: Single;
  Legato: Boolean;
  PendIdx, PendMidi: Integer;
  Events: TArray<TSeqEvent>;
  Count: Integer;

  procedure Push(ATime: Double; ANote: Integer; AOn: Boolean; AVel: Single);
  begin
    if Count = Length(Events) then
      SetLength(Events, Count * 2 + 64);
    Events[Count].Time := Round(ATime);
    Events[Count].Note := ANote;
    Events[Count].IsOn := AOn;
    Events[Count].Velocity := AVel;
    Inc(Count);
  end;

begin
  UnitSamples := FSampleRate * 60 / (Bpm * UnitsPerBeat);
  AllVoices := [];
  for V := 0 to High(Voices) do
    AllVoices := AllVoices + [Voices[V]];
  if Chords <> '' then
  begin
    ChordsToVoices(Chords, Bass, Third, Fifth);
    AllVoices := AllVoices + [Bass, Third, Fifth];
  end;

  Count := 0;
  Song.Length := 0;
  for V := 0 to High(AllVoices) do
  begin
    T := 0;
    Transpose := 0;
    Legato := False;
    PendIdx := -1;
    // Melodie (erste Stimme) etwas lauter als Begleitung
    if V = 0 then Vel := 0.85 else Vel := 0.6;
    for Tok in AllVoices[V].Split([' ', '|'], TStringSplitOptions.ExcludeEmpty) do
    begin
      if Tok[1] = 'T' then
      begin
        Transpose := StrToIntDef(Copy(Tok, 2, MaxInt), 0);
        Continue;
      end;
      // V40 = Dynamik 40 %; L1 = gebunden (Toene ueberlappen leicht), L0 = leicht abgesetzt
      if (Tok[1] = 'V') and (Length(Tok) > 1) and CharInSet(Tok[2], ['0'..'9']) then
      begin
        Vel := EnsureRange(StrToIntDef(Copy(Tok, 2, MaxInt), 80) / 100, 0.05, 1);
        Continue;
      end;
      if (Tok[1] = 'L') and (Length(Tok) = 2) and CharInSet(Tok[2], ['0', '1']) then
      begin
        Legato := Tok[2] = '1';
        Continue;
      end;
      P := LastDelimiter('-', Tok);
      if P <= 1 then Continue;
      Name := Copy(Tok, 1, P - 1);
      Units := StrToIntDef(Copy(Tok, P + 1, MaxInt), 0);
      if Units <= 0 then Continue;
      if (Name <> 'R') and ParseNote(Name, Midi) then
      begin
        // gebundener Vorgaenger mit demselben Ton: dessen Loslassen vor diesen Anschlag ziehen
        if (PendIdx >= 0) and (PendMidi = Midi + Transpose) then
          Events[PendIdx].Time := Round(T) - 1;
        PendIdx := -1;
        Push(T, Midi + Transpose, True, Vel);
        // leicht abgesetzt, damit Wiederholungen derselben Note hoerbar neu anschlagen;
        // gebunden: knapp ueber den naechsten Anschlag hinaus (gleicher Ton folgt nie gebunden)
        if Legato then
        begin
          Push(T + Units * UnitSamples * 1.04, Midi + Transpose, False, 0);
          PendIdx := Count - 1;
          PendMidi := Midi + Transpose;
        end
        else
          Push(T + Units * UnitSamples * 0.9, Midi + Transpose, False, 0);
      end;
      if Name = 'R' then
        PendIdx := -1;
      T := T + Units * UnitSamples;
    end;
    Song.Length := Max(Song.Length, Round(T));
  end;

  // nach Zeit sortieren; bei Gleichstand Note-Off vor Note-On
  SetLength(Events, Count);
  TArray.Sort<TSeqEvent>(Events, TComparer<TSeqEvent>.Construct(
    function(const A, B: TSeqEvent): Integer
    begin
      if A.Time < B.Time then Exit(-1);
      if A.Time > B.Time then Exit(1);
      Result := Ord(A.IsOn) - Ord(B.IsOn);
    end));
  Song.Title := Title;
  Song.Bpm := Bpm;
  Song.Events := Events;
  Song.Kind := SONG_MELODY;
  FSongs := FSongs + [Song];
end;

function TAutoPlayer.Rand: Double;
begin
  FRand := FRand xor (FRand shl 13);
  FRand := FRand xor (FRand shr 17);
  FRand := FRand xor (FRand shl 5);
  Result := (FRand shr 8) / 16777216;
end;

procedure TAutoPlayer.BeginSong(Index: Integer; var Tempo: Double);
const
  TRANSPOSE_CHOICES: array[0..5] of Integer = (0, 0, -2, 2, -5, 3);
var
  Bpm: Double;
begin
  FCurrent := Index;
  FEvIdx := 0;
  FPos := 0;
  Bpm := FSongs[Index].Bpm;
  if FRandomMode then
  begin
    Bpm := Bpm * (0.92 + Rand * 0.16);   // Tempo +-8 %
    FTranspose := TRANSPOSE_CHOICES[Trunc(Rand * Length(TRANSPOSE_CHOICES)) mod Length(TRANSPOSE_CHOICES)];
  end
  else
    FTranspose := 0;
  // Songtempo wird Host-Tempo: Plugins (LFO-/Echo-Sync) laufen damit im Takt.
  // Danach folgt die Wiedergabe live dem Tempo-Regler des Hosts.
  Tempo := EnsureRange(Bpm, 40, 240);
end;

procedure TAutoPlayer.ReleaseAll(Emit: TNoteEmit);
var
  N: Integer;
begin
  for N := 0 to 127 do
    if FActive[N] > 0 then
    begin
      Emit(N, 0, False, 0);
      FActive[N] := 0;
    end;
end;

procedure TAutoPlayer.Process(Frames: Integer; var Tempo: Double; Emit: TNoteEmit);
var
  Req, Next, Note: Integer;
  Delta: Integer;
  Ratio, SongEnd: Double;
  E: TSeqEvent;
  Song: ^TSong;
begin
  if FStopRequest then
  begin
    FStopRequest := False;
    FPlaying := False;
    ReleaseAll(Emit);
  end;
  Req := FStartRequest;
  if Req <> -2 then
  begin
    FStartRequest := -2;
    ReleaseAll(Emit);
    FRandomMode := Req < 0;
    if FRandomMode then
      Req := PickRandom(-1);
    BeginSong(Req, Tempo);
    FPlaying := True;
  end;
  if not FPlaying then
    Exit;

  Song := @FSongs[FCurrent];
  // Verhaeltnis Regler-Tempo / Originaltempo: so schnell laeuft die Songzeit
  Ratio := Max(Tempo, 1) / Song.Bpm;
  SongEnd := FPos + Frames * Ratio;
  while FEvIdx < Length(Song.Events) do
  begin
    E := Song.Events[FEvIdx];
    if E.Time >= SongEnd then
      Break;
    Delta := EnsureRange(Round((E.Time - FPos) / Ratio), 0, Frames - 1);
    Note := EnsureRange(E.Note + FTranspose, 0, 127);
    if E.IsOn then
    begin
      Emit(Note, EnsureRange(E.Velocity * (0.85 + 0.3 * Rand), 0.05, 1), True, Delta);
      Inc(FActive[Note]);
    end
    else if FActive[Note] > 0 then
    begin
      Emit(Note, 0, False, Delta);
      Dec(FActive[Note]);
    end;
    Inc(FEvIdx);
  end;
  FPos := SongEnd;
  // Songende + Pause -> naechster Song (im Zufallsmodus ein anderer, sonst Wiederholung)
  if (FEvIdx >= Length(Song.Events)) and
     (FPos > Song.Length + SONG_GAP_SECONDS * FSampleRate * Ratio) then
  begin
    Next := FCurrent;
    if FRandomMode and (Length(FSongs) > 1) then
      Next := PickRandom(FCurrent);
    BeginSong(Next, Tempo);
  end;
end;

procedure TAutoPlayer.Start(SongIndex: Integer);
begin
  if (SongIndex < -1) or (SongIndex >= Length(FSongs)) then
    SongIndex := -1;
  FStartRequest := SongIndex;
end;

procedure TAutoPlayer.Stop;
begin
  FStopRequest := True;
end;

function TAutoPlayer.GetSongCount: Integer;
begin
  Result := Length(FSongs);
end;

function TAutoPlayer.GetTitle(Index: Integer): string;
begin
  Result := FSongs[Index].Title;
end;

function TAutoPlayer.GetCurrentTitle: string;
begin
  if FPlaying then
    Result := FSongs[FCurrent].Title
  else
    Result := '';
end;

function TAutoPlayer.GetNoteActive(Note: Integer): Boolean;
begin
  Result := (Note >= 0) and (Note <= 127) and (FActive[Note] > 0);
end;

end.
