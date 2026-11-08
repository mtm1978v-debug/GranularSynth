{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

unit Granular.Editor;

{ Bedienoberflaeche des Synthesizers als eigenstaendiges Panel.
  Wird im Test-Host ins Hauptfenster gesetzt und spaeter im VST2-Plugin in das
  vom Host gelieferte Editorfenster (effEditOpen -> ParentWindow).

  Aufbau: Kopfleiste | Reiter "Synth" / "Modulation" | Klaviatur (immer sichtbar).
  Touchpad-tauglich: nur Schieberegler, Auswahllisten und Haekchen, grosse Zeilen. }

interface

uses
  Granular.Lang,
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.Classes, System.SysUtils, System.StrUtils, System.Math, System.IOUtils,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Dialogs, Vcl.Graphics, Vcl.Forms, Vcl.Menus, Vcl.Imaging.pngimage,
  Granular.Update,
  Granular.Params, Granular.Sample, Granular.Engine, Granular.WaveView, Granular.Keyboard,
  Granular.ModViews, Granular.State, Granular.AudioDecode, Granular.Banner, Granular.Prof, Granular.Spectrum, Granular.ComboFit, Granular.FreeLfoView, Granular.InfoView, Granular.EqView, Granular.Eq,
  Granular.LoadView, Granular.Hints, Granular.ArpMidi, Granular.AudioEditor,
  Granular.Fader,   // nach Vcl.ComCtrls: TTrackBar im DJ-Fader-Look
  Granular.IconButton;   // Symbole (TEdIcon) fuer die Knoepfe

const
  WM_EDITOR_DEFOCUS = WM_USER + 211;   // Fokus nach Listenauswahl zurueck an den Editor

type
  { Liefert True, wenn der Sidechain-Eingang (de)aktiviert werden konnte }
  TSidechainSwitchEvent = function(Sender: TObject; Enable: Boolean): Boolean of object;
  { Bedienung eines Reglers an die DAW melden (Automation aufnehmen, "Last tweaked", Controller verknuepfen):
    Beginn einer Bewegung, jeder neue Wert, Ende der Bewegung. Index = interner Parameterindex. }
  TParamEditKind = (pekBegin, pekChange, pekEnd);
  TParamEditEvent = procedure(Index: Integer; Kind: TParamEditKind; Value: Single) of object;
  { Rechtsklick auf einen Regler: DAW-Kontextmenue zeigen (VST3: Automationsspur, Controller ...);
    True = gezeigt, sonst erscheint das eigene Menue }
  THostMenuEvent = function(Index: Integer; const ScreenPos: TPoint; Ctrl: TControl): Boolean of object;

  TParamBinding = record
    Index: Integer;
    Track: TTrackBar;
    Combo: TComboBox;
    Check: TCheckBox;
    NameLabel: TLabel;
    ValueLabel: TLabel;
    ModMarker: TPanel;     // roter Strich unter dem Regler = aktueller Wirkwert (Basis + Matrix)
    LastBase, LastEff: Single;   // zuletzt angezeigte Werte -> nur bei Aenderung neu formatieren
    LastCaption: string;
    StepOfItem: TArray<Integer>;   // sortierte Liste (Matrix-Ziel): Eintrag -> Stufe; leer = Eintrag = Stufe
    Vertical: Boolean;             // Mischpult-Fader: oben = Maximum (Trackbar zaehlt von oben)
    OnOffCaption: Boolean;         // Haken-Beschriftung zeigt den Zustand ("an" / "aus")
  end;

  { Breitenanpassung beim Groessenwechsel des Elternpanels }
  TStretchItem = record
    Ctrl: TControl;
    Left, RightGap: Integer;
    AlignRight: Boolean;    // True: nur verschieben (rechtsbuendig), sonst strecken
  end;

  TVarySection = (vsGrains, vsSound, vsEnvelope, vsModulation, vsEffects, vsOscs);

  TGranularEditor = class(TCustomPanel)
  private
    FEngine: TGranularEngine;
    FTopBar: TPanel;
    FBanner: TBannerView;
    FBannerTimer: TTimer;
    FBannerTick: Integer;
    FBannerLast: Int64;
    // Grafik-Budget: GUI-Thread soll hoechstens ~10 % einer CPU brauchen
    FGfxLevel: Integer;          // 0 = 60 B/s ... 5 = Banner 10 B/s, Live-Anzeigen 10 B/s
    FGfxCheckWall, FGfxCheckCpu: Int64;
    FMainTick: Integer;
    FFgLevel: Integer;           // Stufe im Vordergrund, wird beim Zurueckholen wiederhergestellt
    FIsForeground: Boolean;
    FFgKnown: Boolean;           // Vorder-/Hintergrund schon einmal festgestellt?
    FGfxCalm: Integer;           // Sekunden in Folge, in denen eine hoehere Stufe erlaubt waere
    FLevelLoad: array[0..8] of Double;    // (frueher gelernte Last; nicht mehr verwendet)
    FLevelStrikes: array[0..8] of Integer;  // wie oft die Stufe schon zu teuer war (Sperre verdoppelt sich)
    FGfxStart: Int64;                     // Startzeitpunkt: die ersten Sekunden zaehlen nicht (Startlast)
    FGfxOver: Integer;                    // Sekunden in Folge ueber dem Limit
    FLevelBlocked: array[0..8] of Int64;  // Stufe nach Ueberlast bis zu diesem Zeitpunkt gesperrt
    FLoadButton, FPanicButton, FOctDown, FOctUp: TButton;
    FStatus: TLabel;
    FPresetCombo: TComboBox;
    FPresetSave, FPresetPrev, FPresetNext: TButton;
    FPresetFiles: TArray<string>;
    FPresetFilter: TEdit;                    // Suchtext: Liste zeigt nur Presets mit diesem Text im Namen
    FAllPresetNames, FAllPresetFiles: TArray<string>;
    // Schnell-Reiter
    FVaryStrength: TTrackBar;
    FVaryStyle: TComboBox;      // Stil-Richtung beim Variieren
    FMorphLabel: TLabel;
    FArpPattern: TArpPatternView;
    FArpMidiBars: TComboBox;
    FClipLed, FMidiLed: TClipLed;
    FQuickPV: TPanel;        // Einstellungs-Rechteck rechts im Schnell-Reiter (Bezug fuer den Taenzer)
    FInfoForm: TInfoForm;
    FVaryChecks: array[TVarySection] of TCheckBox;   // an = Bereich wird beim Variieren gewuerfelt
    FUndoButton, FABButton: TButton;
    FLimiterLabel: TLabel;
    FUndo, FRedo: TArray<TArray<Single>>;
    FRedoButton: TButton;
    FCommitted: TArray<Single>;  // Stand vor der laufenden Reglerbewegung (Grundlage fuer Rueckgaengig)
    FEditParam: Integer;         // zuletzt bewegter Regler: eine Bewegung = ein Rueckgaengig-Schritt
    FEditTick: Cardinal;
    FAB: array[0..1] of TArray<Single>;
    FABActive: Integer;
    FABInit: Boolean;
    // Rechtsklick-Menue
    FModMenu: TPopupMenu;
    FModAmountMenu, FModRemoveItem: TMenuItem;
    FModInfoItem, FLearnItem, FLearnRemoveItem: TMenuItem;
    FModSlotItems: TArray<TMenuItem>;   // je Matrix-Zeile auf den Regler ein Untermenue (beim Oeffnen neu)
    FWheelParam, FWheelSlot: Integer;    // Alt + Mausrad wirkt auf diese Zeile (fuer diesen Regler)
    FLearnBinding: Integer;      // wartet auf einen Controller fuer diesen Regler (-1 = nein)
    // Preset-Auswahl: Kategorie und Favoriten
    FPresetCat: TComboBox;
    FPresetFav: TButton;
    FFavorites: TArray<string>;  // Dateinamen ohne Pfad
    // Direkteingabe
    FValueEdit: TEdit;
    FEditBinding: Integer;
    FBaseDir: string;
    FPages: TPageControl;
    FTabQuick, FTabSynth, FTabMod, FTabMod2, FTabFx, FTabExtra, FTabEq, FTabMix, FTabTiming, FTabPerf: TTabSheet;
    FTabFx2: TTabSheet;           // Effekte: Chorus, Phaser, Bitcrusher, Trance-Gate
    FTabFlt: TTabSheet;           // Filter 1 + 2 (je Note)
    FTabSamples: TTabSheet;       // Zonen und Aufnahme
    FRecButton: TButton;
    FRecLabel: TLabel;
    FResLabel: TLabel;            // Feedback-Resampling: Stand (Durchlauf)
    FZoneRow: array[1..ZONE_COUNT] of TPanel;
    FZoneName: array[1..ZONE_COUNT] of TLabel;
    FZoneNote: array[1..ZONE_COUNT] of TComboBox;
    FGatePattern: TArpPatternView;
    FLoadList: TLoadList;
    FLoadGauge: TLoadGauge;
    FDlyMsIdx: array[0..DLY_EVENT_COUNT - 1] of Integer;   // ms-Regler (ausgegraut, wenn ein Notenwert gilt)
    FTabOsc: array[0..OSC_COUNT - 1] of TTabSheet;
    FMixMeters: array[0..MIX_METERS - 1] of TMixMeter;   // Pegel neben den Mischpult-Fadern
    FEqView: TEqView;
    FCompCurve: TCompCurveView;
    FRecent: TArray<string>;   // zuletzt geladene Presets (Dateinamen, neueste zuerst)
    FMEnvView: array[0..MENV_COUNT - 1] of TEnvelopeView;
    FWaveIdx, FDrawIdx, FWaveState: array[0..OSC_COUNT - 1] of Integer;   // Welle/Gezeichnet ausgrauen
    FMEnvKey: array[0..MENV_COUNT - 1] of Double;
    FWtName: array[0..OSC_COUNT - 1] of TLabel;
    FWtShown: array[0..OSC_COUNT - 1] of string;
    FCompSig: string;
    // Fenster 'Frei-LFO' (modal, je LFO): Editor + Bedienelemente; keine automatisierbaren
    // Parameter, die Daten liegen nur im Chunk. Felder sind nur bei offenem Fenster belegt.
    FFreeView: array[0..FREE_LFO_COUNT - 1] of TFreeLfoView;
    FFreeMode, FFreeRange: array[0..FREE_LFO_COUNT - 1] of TComboBox;
    FFreeRoot: array[0..FREE_LFO_COUNT - 1] of TComboBox;     // Bezugston der Klaviatur
    FFreeSmooth: array[0..FREE_LFO_COUNT - 1] of TTrackBar;   // Glaettung 0..100 %
    FFreeSmoothLbl: array[0..FREE_LFO_COUNT - 1] of TLabel;
    // Fenster "Welle zeichnen" je Oszillator
    FWaveForm: array[0..OSC_COUNT - 1] of TForm;
    FAudioForm: array[0..ZONE_COUNT] of TForm;   // Sample-Editor je Hauptsample (0) / Zone, nicht modal
    FWaveView: array[0..OSC_COUNT - 1] of TOscWaveView;
    FWaveSmooth: array[0..OSC_COUNT - 1] of TTrackBar;
    FWaveSmoothLbl: array[0..OSC_COUNT - 1] of TLabel;
    FWaveUse: array[0..OSC_COUNT - 1] of TCheckBox;
    FFreeSteps: array[0..FREE_LFO_COUNT - 1] of TTrackBar;
    FFreeStepsLbl: array[0..FREE_LFO_COUNT - 1] of TLabel;
    FWave: TWaveView;
    FSynthArea: TPanel;
    FCols: array[0..2] of TPanel;
    FEnvView, FFltEnvView: TEnvelopeView;
    FFltView: TFilterView;           // Frequenzgang der Filter (Reiter Filter)
    FPendingPreset: string;          // Testhilfe GRANULAR_PRESET (verzoegert)
    FOscEnvView: array[0..OSC_COUNT - 1] of TEnvelopeView;
    FOscEnvKey: array[0..OSC_COUNT - 1] of Double;
    FMorphLfoView: TLfoView;
    FFmEnvIdx: array[0..OSC_COUNT - 1, 0..4] of Integer;   // Bindungen: Haken + FM-Huellkurve je Oszillator
    FSyncIdx: array[0..OSC_COUNT - 1] of Integer;          // Bindung Osz Sync (bei Rauschen ausgegraut)
    FFmEnvState: array[0..OSC_COUNT - 1] of Integer;       // zuletzt gezeigter Zustand (0 aus, 1 Haken, 2 alles, 3 Rauschen)
    FDancerGap: Integer;           // Abstand der Taenzerin zum rechten Banner-Rand
    FLfoViews: array[0..LFO_COUNT - 1] of TLfoView;
    FLfoPanels: array[0..LFO_COUNT - 1] of TPanel;   // je LFO ein Feld; sichtbar: LFO 1-4 oder 5-8
    FLfoPage: Integer;
    FLfoPageBtn: array[0..1] of TButton;
    FSlotLeds: array[0..MOD_SLOTS - 1] of TSlotLed;
    FSlotGlobal: array[0..MOD_SLOTS - 1] of TLabel;   // Hinweis: Noten-Quelle auf globales Ziel
    FSlotCtrls: array[0..MOD_SLOTS - 1] of TArray<TControl>;   // alle Steuerelemente einer Zeile (Seitenwechsel)
    FMatPage: Integer;                                  // sichtbare Seite der Matrix (je MAT_ROWS Zeilen)
    FMatPageBtn: array of TButton;
    FLedsDirty: Boolean;
    FLedSag: Single;              // 0 = volle Spannung, >0 = Lampen sacken bei lautem Ausgang leicht ab          // ein Schalter wurde aus der Engine gesetzt -> Lampen nachziehen
    FMacroTargets: array[0..UMAC_COUNT - 1] of TLabel;   // freie Makros: welche Regler sie bewegen
    FSpectrum: TSpectrumView;
    FMixSpectrum: TSpectrumView;   // dasselbe Frequenzband im Mischpult (laeuft nur, wenn der Reiter sichtbar ist)
    FLevelView, FOutLevelView: TLevelView;
    FTrigPanel: TPanel;
    FInLevels: TLabel;        // Mischpult: Pegel der vier VST-Eingaenge
    FProcStat: TLabel;        // Reiter Leistung: Laufzeit-Statistik des Plugins
    FStPrev: array[0..5] of Int64;
    FStLast: Int64;
    FStopMsIdx, FStopSyncIdx, FPartnerIdx: array[0..LFO_COUNT - 1] of Integer;   // Stoppzeit-Regler (nur bei Stopp 'nach Zeit' aktiv)   // Trigger-Schwellen: rechts neben LFO 3/4 (BuildMod2Tab setzt den Platz)
    FMicCheck: TCheckBox;
    FMicLabel: TLabel;
    FKeys: TKeyboardView;
    FKeysRow: TPanel;
    FBendWheel, FModWheel: TWheelView;
    FBottom: TPanel;
    FMonitor: TMonitorView;
    FTimer: TTimer;
    FAnimPaused: Boolean;     // Fenster minimiert/unsichtbar: keine Animation, Timer selten

    FBindings: TArray<TParamBinding>;
    FBindingOf: array[0..PARAM_COUNT - 1] of Integer;
    FStretch: TArray<TStretchItem>;
    FUpdating: Boolean;
    FOctave: Integer;
    FKeyNote: array[Byte] of Integer;   // gespielte Note je virtuellem Tastencode
    FPlayheads, FGrains: array[0..MAX_LIVE - 1] of Single;
    FSounding: array[0..127] of Byte;
    FEnvKey, FFltEnvKey: Double;     // Kennwert der zuletzt gezeichneten Huellkurve
    FMonitorIdle: Integer;           // Frames ohne Signal - danach kein Neuzeichnen
    FOnSidechainSwitch: TSidechainSwitchEvent;
    FOnParamEdit: TParamEditEvent;
    FOnHostMenu: THostMenuEvent;
    FOnLanguageChange: TNotifyEvent;   // Sprache gewechselt: die Huelle baut die Oberflaeche neu auf
    FLangCombo: TComboBox;
    FScaleCombo: TComboBox;
    FLangCodes, FLangNames: TStringList;
    FLangFlag: TPaintBox;              // Flagge in der Reiterzeile: Klick = naechste Sprache
    FLangFlagHost: TPanel;             // Fenster-Traeger: liegt ueber der Reiterleiste (TPaintBox allein waere verdeckt)
    FUpdHost: TPanel;                  // Hinweis "neue Version" links neben der Flagge (erst sichtbar, wenn es eine gibt)
    FUpdIcon: TPaintBox;
    FUpdVersion, FUpdPage: string;
    FHostEditParam: Integer;      // Regler, dessen Bewegung der DAW gerade gemeldet wird (-1 = keiner)
    FHostEditTick: Cardinal;
    FHostItem: TMenuItem;
    procedure TrackContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure SetFormatName(const Value: string);
    procedure HostEdit(Index: Integer; Continuous: Boolean);
    procedure EndHostEdit;
    procedure HostAutomationClick(Sender: TObject);

    function MakePanel(AParent: TWinControl; AAlign: TAlign; const ATitle: string): TPanel;
    procedure AddStretch(Ctrl: TControl; RightGap: Integer; AlignRight: Boolean = False);
    procedure PanelResize(Sender: TObject);
    procedure RelayoutAll(Sender: TObject);
    procedure PagesChanging(Sender: TObject; var AllowChange: Boolean);
    procedure PagesChange(Sender: TObject);
    procedure SynthAreaResize(Sender: TObject);
    function AddParam(AParent: TWinControl; Index, X, Y, NameW, ValueW: Integer;
      ComboW: Integer = 150; const ACaption: string = ''; TrackW: Integer = 0): Integer;
    procedure BuildControls;
    procedure BuildSynthTab;
    procedure BuildModTab;
    procedure BuildFxTab;
    procedure BuildFilterTab;
    procedure BuildQuickTab;
    procedure FreeTimerTick(Sender: TObject);
    procedure LfoViewClick(Sender: TObject);
    procedure FreeFormClose(Sender: TObject; var Action: TCloseAction);
    procedure FreeFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FreeFormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FFreeForm: array[0..FREE_LFO_COUNT - 1] of TForm;
  private
    procedure MatrixComboValidate(C: TComboBox);
    procedure MatrixComboExit(Sender: TObject);
    procedure MatrixComboKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SyncFreeUi;
    procedure FreeModeChange(Sender: TObject);
    procedure FreeRangeChange(Sender: TObject);
    procedure FreeStepsChange(Sender: TObject);
    procedure FreeActivateClick(Sender: TObject);
    procedure FreePitchClick(Sender: TObject);
    procedure FreeSmoothClick(Sender: TObject);
    procedure FreeSmoothChange(Sender: TObject);
    procedure FreeRootChange(Sender: TObject);
    procedure WaveEditClick(Sender: TObject);
    procedure WaveFormClose(Sender: TObject; var Action: TCloseAction);
    procedure WaveShapeClick(Sender: TObject);
    procedure WaveSmoothChange(Sender: TObject);
    procedure WaveUseClick(Sender: TObject);
    procedure WaveViewChange(Sender: TObject);
    procedure WaveChanged(O: Integer; TurnOn: Boolean);
    procedure FreeResetClick(Sender: TObject);
    procedure BuildModMenu;
    function TakeSnapshot: TArray<Single>;
    procedure ApplySnapshot(const Snap: TArray<Single>);
    procedure UndoClick(Sender: TObject);
    procedure RedoClick(Sender: TObject);
    procedure RefreshModRings;
    procedure TrackModWheel(Sender: TObject; Delta: Integer);
    procedure LearnClick(Sender: TObject);
    procedure LearnRemoveClick(Sender: TObject);
    procedure PollMidiLearn;
    function PresetInCategory(const Name: string; Cat: Integer): Boolean;
    function IsFavorite(const FileName: string): Boolean;
    function IsRecent(const FileName: string): Boolean;
    procedure AddRecent(const FileName: string);
    procedure LoadFavorites;
    procedure SaveFavorites;
    procedure UpdateFavButton;
    procedure PresetFavClick(Sender: TObject);
    procedure PresetCatChange(Sender: TObject);
    procedure ABClick(Sender: TObject);
    procedure VaryClick(Sender: TObject);
    procedure ApplyVaryStyle(Style: Integer);
    procedure BuildExtraTab;
    procedure BuildEqTab;
    procedure BuildOscTab(O: Integer);
    procedure BuildMixTab;
    procedure BuildFx2Tab;
    procedure ApplyParamHint(const B: TParamBinding);
    procedure WtLoadClick(Sender: TObject);
    procedure UpdateWtNames;
    procedure ApplyCaptionHints;
  protected
    procedure CreateWnd; override;
  private
    procedure BuildSampleTab;
    procedure RecClick(Sender: TObject);
    procedure ZoneLoadClick(Sender: TObject);
    procedure EditSampleClick(Sender: TObject);
    procedure EditSample(Z: Integer);
    procedure EditSampleDone(Z: Integer; Res: TSampleData);
    procedure AudioEditorTimer(Sender: TObject);
    procedure PresetLaterTimer(Sender: TObject);
    procedure ZoneClearClick(Sender: TObject);
    procedure ZoneNoteChange(Sender: TObject);
    procedure LoadZoneFile(Z: Integer; const FileName: string);
    procedure UpdateZoneUi;
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    procedure GatePatternChange(Sender: TObject);
    procedure BuildPerfTab;
    function AddFader(AParent: TWinControl; Index, X, Y, H: Integer; const ACaption: string; W: Integer = 88): Integer;
    procedure BuildMod2Tab;
    procedure BuildTimingTab;
    procedure EqPresetClick(Sender: TObject);
    procedure UpdateMorphLabel;
    procedure MorphStoreClick(Sender: TObject);
    procedure MorphSwapClick(Sender: TObject);
    procedure MorphLoadClick(Sender: TObject);
    procedure MorphClearClick(Sender: TObject);
    procedure MorphFreeClick(Sender: TObject);
    procedure FreeGateClick(Sender: TObject);
    procedure InfoClick(Sender: TObject);
    procedure HelpClick(Sender: TObject);
    procedure LangComboChange(Sender: TObject);
    procedure ScaleComboChange(Sender: TObject);
    procedure LangFlagPaint(Sender: TObject);
    procedure UpdIconPaint(Sender: TObject);
    procedure UpdIconClick(Sender: TObject);
    procedure LangFlagClick(Sender: TObject);
    procedure SwitchLanguage(const Code: string);
    procedure EnsureLangList;
    procedure ComboCloseUp(Sender: TObject);
    procedure WMEditorDefocus(var Msg: TMessage); message WM_EDITOR_DEFOCUS;
    procedure SortDestCombo(var B: TParamBinding);
    function ComboStepOfItem(const B: TParamBinding; Item: Integer): Integer;
    function ComboItemOfStep(const B: TParamBinding; Step: Integer): Integer;
    procedure SetBindingEnabled(Idx: Integer; Value: Boolean);
    procedure MacroResetClick(Sender: TObject);
    function MenuParamIndex: Integer;
    function SlotsFor(Index: Integer): TArray<Integer>;
    procedure ModMenuPopup(Sender: TObject);
    procedure ModAssignClick(Sender: TObject);
    procedure ModAmountClick(Sender: TObject);
    procedure ModSlotClick(Sender: TObject);
    function FirstFreeSlot: Integer;
    function SlotFor(Src, Dst: Integer): Integer;
    procedure SetSlot(Slot, Src, Dst: Integer; Amount: Double; Factor: Integer);
    procedure SlotClearClick(Sender: TObject);
    procedure MatPageClick(Sender: TObject);
    procedure BuildLfoPanel(AParent: TWinControl; K, Y, W: Integer);
    procedure LfoPageClick(Sender: TObject);
    procedure UpdateLfoPageCaptions;
    procedure UpdateMatrixPageCaptions;
    procedure UpdateMacroTargets;
    function IndexOfPresetFile(const FileName: string): Integer;
    procedure ClearSlot(Slot: Integer);
    function WheelSlotFor(Index: Integer): Integer;
    function SlotCaption(Slot: Integer): string;
    procedure ModRemoveClick(Sender: TObject);
    procedure ModDefaultClick(Sender: TObject);
    procedure ValueLabelClick(Sender: TObject);
    function ParseValueInput(Index: Integer; const Text: string; out Norm: Single): Boolean;
    procedure CommitValueEdit;
    procedure CancelValueEdit;
    procedure ValueEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ValueEditExit(Sender: TObject);
    procedure SyncControlsFromEngine;

    procedure TrackChange(Sender: TObject);
    procedure ComboChange(Sender: TObject);
    procedure SetupLeds;
    procedure WaveItemIcon(Sender: TObject; Index: Integer; Cv: TCanvas; const R: TRect; Col: TColor);
    procedure CheckClick(Sender: TObject);
    procedure MicClick(Sender: TObject);
    procedure ParamChangedByUser(Index: Integer; FromBinding: Integer = -1);
    procedure EnvViewEdit(Id: TGranularParamId; Norm: Single);
    procedure SetupEnvView(V: TEnvelopeView);
    procedure SetControlValue(BindingIdx: Integer; Norm: Single);
    procedure UpdateValueLabel(BindingIdx: Integer);
    function DisplayFor(Index: Integer; Norm: Single): string;

    procedure WaveSelectionChange(Sender: TObject);
    procedure WavePreStartChange(Sender: TObject);
    procedure WavePositionChange(Sender: TObject);
    procedure KeyboardNote(Sender: TObject; Note: Integer; IsOn: Boolean);
    procedure LoadClick(Sender: TObject);
    procedure PanicClick(Sender: TObject);
    procedure OctaveClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure BannerTimerTick(Sender: TObject);
    procedure CheckGfxBudget;
    procedure SyncWaveFromParams;
    procedure UpdatePcRange;
    function PcKeyToSemitone(Key: Word): Integer;
    procedure PlayNote(Note: Integer; IsOn: Boolean);
    procedure WheelChange(Sender: TObject);
    procedure SetOnSidechainSwitch(const Value: TSidechainSwitchEvent);
  public
    { gesetzt vom Plugin (VST2/VST3): Reglerbewegungen an die DAW melden }
    property OnParamEdit: TParamEditEvent read FOnParamEdit write FOnParamEdit;
    property OnHostMenu: THostMenuEvent read FOnHostMenu write FOnHostMenu;
    property OnLanguageChange: TNotifyEvent read FOnLanguageChange write FOnLanguageChange;
    { Oberflaeche auf M/D vergroessern (Fenstergroesse): Positionen, Schriften und die gemerkten
      Abstaende der mitwachsenden Regler }
    procedure ApplyScale(M, D: Integer);
    destructor Destroy; override;
    function PageIndex: Integer;
    { Hilfefenster oeffnen; Changelog = gleich die Aenderungsliste zeigen }
    procedure ShowHelp(Changelog: Boolean);
    { Fenster 'Audio bearbeiten' fuer das Hauptsample (Testhilfe, nach dem Oeffnen des Editors) }
    procedure OpenAudioEditor;
    procedure LoadPresetLater(const FileName: string; DelayMs: Integer);
    { 'VST2', 'VST3', 'VST2 FX', 'VST3 FX': steht im Banner hinter der Version }
    property FormatName: string write SetFormatName;
    { eigenes Rechtsklick-Menue fuer einen Regler zeigen (aus dem DAW-Menue heraus) }
    procedure ShowOwnMenu(Ctrl: TControl; const ScreenPos: TPoint);
  private
    procedure SetBaseDir(const Value: string);
    procedure UpdateProcStat;
    procedure RefreshPresets;
    procedure ApplyPresetFilter;
    procedure PresetFilterChange(Sender: TObject);
    procedure PresetFilterKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PresetComboChange(Sender: TObject);
    procedure PresetSaveClick(Sender: TObject);
    procedure ArpMidiMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PresetStepClick(Sender: TObject);
  public
    { AParent muss sofort gesetzt werden: TPageControl braucht beim Aufbau ein Fensterhandle }
    constructor Create(AOwner: TComponent; AParent: TWinControl; AEngine: TGranularEngine); reintroduce;
    { Uebernimmt Besitz von Data }
    procedure SetSample(Data: TSampleData);
    procedure LoadFile(const FileName: string);
    { Alle Regler aus der Engine neu lesen (Preset-Wechsel, VST-Automation) }
    procedure UpdateFromEngine;
    { PC-Tastatur. Rueckgabe True = Taste verbraucht }
    function HandleKeyDown(Key: Word; Shift: TShiftState): Boolean;
    function HandleKeyUp(Key: Word): Boolean;
    procedure ReleaseAllKeys;
    procedure ShowModulationPage;
    procedure ShowLfoPage(Page: Integer);
    procedure ShowMatrixPage(Page: Integer);
    { Fenster 'freie Form' eines LFOs (0/1) oeffnen }
    procedure OpenFreeEditor(K: Integer);
    procedure OpenWaveEditor(O: Integer);
    { Info-Fenster (Klartext-Uebersicht) zeigen }
    procedure ShowInfo;
    procedure ShowPage(Index: Integer);
    procedure LoadPreset(const FileName: string);
    { Zustand fuer Rueckgaengig merken (vor Variieren, Preset-Wechsel, A/B) }
    procedure PushUndo;
    { Ordner der Plugin-DLL: dort liegen Presets\ und Beispieltoene\ }
    property BaseDir: string read FBaseDir write SetBaseDir;
    { Noten von aussen anzeigen (z.B. Autoplay im Test-Host) }
    procedure ShowExternalNote(Note: Integer; IsOn: Boolean);
    { Nur im Test-Host gesetzt (Mikrofon); im VST liefert der Host den Sidechain }
    { Pfad der geladenen WAV-Datei, leer beim Demo-Klang (fuer den Zustands-Chunk) }
    function SamplePath: string;
    { Wellenform aus dem aktuellen Engine-Sample neu aufbauen (Plugin: nach setChunk / Editor-Oeffnen) }
    procedure SyncSampleFromEngine;
    property OnSidechainSwitch: TSidechainSwitchEvent read FOnSidechainSwitch write SetOnSidechainSwitch;
  end;

implementation

const
  MAT_ROWS = 8;        // Matrix-Zeilen je Seite im Reiter Modulation
  // Presetliste: 0 = alle, 1 = Favoriten, danach Stichwort-Kategorien (Stichworte durch Komma getrennt)
  // Nov. 2026: Techno, FM / Synth, Grains, Zuletzt benutzt hinten angefuegt (Index der alten bleibt)
  PRESET_CATS: array[0..16] of string = ('Alle Presets', '★ Favoriten', 'Flächen / Pads', 'Bass', 'Lead',
    'Arp', 'Glocken / Zupfen', 'Instrumente', 'Stimme / Chor', 'Natur / FX', 'Morph / Doppel', 'Lernen', 'Init',
    'Techno', 'FM / Synth', 'Grains', '⟲ Zuletzt benutzt');
  PRESET_CAT_WORDS: array[0..16] of string = ('', '', 'flaeche,pad,teppich,nebel,wolke,ozean,weite',
    'bass,sub', 'lead', 'arp', 'glock,marimba,vibraphon,kalimba,steeldrum,harfe,gitarre,pluck,zupf,kristall,spieluhr',
    'floete,oboe,trompete,horn,tuba,cello,violin,geige,klarinette,klavier,orgel,piano,rhodes,blech,kontrabass,didgeridoo',
    'stimme,chor,oper,vokal,kennedy,armstrong,caruso,saenger', 'natur,wasser,dschungel,voegel,industrie,weltraum,stotter,gate,wind,regen',
    'morph,doppel', '', 'init', 'techno,acid,rumble,reese,industrial', 'fm -,fm +,+ fm,fm-,osz', 'grains', '');
  CAT_LEARN = 11;
  CAT_RECENT = 16;
  RECENT_MAX = 20;
  RECENT_FILE = 'Zuletzt.txt';

type
  TControlAccess = class(TControl);   // Zugriff auf OnClick der Grafik-Anzeigen

const
  ROW_H = 28;
  COMBO_INSET = 8;   // Trackbar-Schiene beginnt ca. 8 px nach ihrer linken Kante
  BANNER_H = 70;
  BG_MAIN  = $00383230;   // BGR
  BG_DARK  = $002A2624;
  COL_NAME = $00DCDCDC;
  COL_VAL  = $005AD2FF;
  COL_MOD  = $005A5AFF;   // Wert gerade moduliert

constructor TGranularEditor.Create(AOwner: TComponent; AParent: TWinControl; AEngine: TGranularEngine);
var
  I: Integer;
begin
  inherited Create(AOwner);
  FEngine := AEngine;
  FOctave := 4;
  for I := 0 to High(FKeyNote) do
    FKeyNote[I] := -1;
  for I := 0 to PARAM_COUNT - 1 do
    FBindingOf[I] := -1;
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := BG_MAIN;
  Width := 1000;
  Height := 700;
  Parent := AParent;
  Align := alClient;
  BuildControls;
  // Sprache: Beschriftungen, Hinweise, Menues nach dem Aufbau uebersetzen (Listen uebersetzt AddParam selbst)
  TranslateComponents(Self);
  // nach jeder Auswahl in einer Liste den Fokus zurueck an den Editor geben: sonst blaettern
  // die PC-Tasten (Klaviatur) in der gerade geschlossenen Liste weiter
  for I := 0 to ComponentCount - 1 do
    if (Components[I] is TComboBox) and not Assigned(TComboBox(Components[I]).OnCloseUp) then
      TComboBox(Components[I]).OnCloseUp := ComboCloseUp;
  RelayoutAll(nil);
  UpdateFromEngine;
  UpdatePcRange;
end;

procedure TGranularEditor.ComboCloseUp(Sender: TObject);
begin
  // erst nach dem Schliessen umsetzen (die Liste verarbeitet die Auswahl noch)
  if HandleAllocated then
    PostMessage(Handle, WM_EDITOR_DEFOCUS, 0, 0);
end;

procedure TGranularEditor.WMEditorDefocus(var Msg: TMessage);
begin
  if HandleAllocated and Visible then
    Winapi.Windows.SetFocus(Handle);
end;

{ --- Aufbau --- }

{ ---------------- Mischpult-Optik: Konsolen-Gehaeuse und Kanalzuege ----------------
  Rein statisch gezeichnet (nur bei Groessenaenderung/Neuzeichnen), die Fader und Pegel laufen wie bisher.
  Farben aus der Palette des Plugins: Grundton wie BG_MAIN/BG_DARK, Kappen im Blau des Spektrums, im
  Bernstein der Werte und in einem warmen Rot fuer den Ausgang. }
type
  { gemeinsame Basis: der Hintergrund wird einmal in ein Bild gezeichnet (DrawBack) und danach nur noch
    kopiert - neu erzeugt nur bei Groessenaenderung }
  TCachedPanel = class(TCustomPanel)
  private
    FCache: Vcl.Graphics.TBitmap;
  protected
    procedure DrawBack(Cv: TCanvas; const R0: TRect); virtual; abstract;
    procedure Paint; override;
    procedure Resize; override;
  public
    destructor Destroy; override;
  end;

  TMixDeck = class(TCachedPanel)
  public
    Display: TControl;            // eingelassenes Display (Spektrum)
  protected
    procedure DrawBack(Cv: TCanvas; const R0: TRect); override;
  end;

  TMixStrip = class(TCachedPanel)
  public
    Cap: TColor;                  // Gruppenfarbe der Kappe
    CapH: Integer;                // Hoehe der Kappe (hinter dem Kanalnamen)
  protected
    procedure DrawBack(Cv: TCanvas; const R0: TRect); override;
  end;

const
  DECK_BG    = $00221E1C;         // Gehaeuse: dunkler als BG_DARK
  STRIP_BG   = $00403A36;         // Kanalzug: etwas heller als BG_MAIN
  STRIP_HI   = $00655D57;         // Lichtkante oben/links
  STRIP_LO   = $00171412;         // Schattenkante unten/rechts
  CAP_SRC    = $00A06A2C;         // Quellen: Blau wie das Spektrum (gedaempft)
  CAP_FX     = $002E7AA8;         // Effekte: Bernstein (gedaempft)
  CAP_OUT    = $003A3C9C;         // Ausgang: warmes Rot (gedaempft)

{ Kantengeglaettete Linie auf eine VCL-Canvas (fuer kleine, einmal gezeichnete Schraegen):
  je Schritt entlang der Hauptachse zwei Pixel anteilig mit dem Untergrund gemischt; Breite W = parallele Linien }
procedure AALineCv(Cv: TCanvas; X0, Y0, X1, Y1: Single; Col: TColor; W: Integer = 1);

  procedure Blend(X, Y: Integer; A: Single);
  var
    Bg, Fg: TColor;
    R, G, B: Integer;
  begin
    if A <= 0.01 then
      Exit;
    A := Min(A, 1);
    Bg := ColorToRGB(Cv.Pixels[X, Y]);
    Fg := ColorToRGB(Col);
    R := Round((Fg and $FF) * A + (Bg and $FF) * (1 - A));
    G := Round(((Fg shr 8) and $FF) * A + ((Bg shr 8) and $FF) * (1 - A));
    B := Round(((Fg shr 16) and $FF) * A + ((Bg shr 16) and $FF) * (1 - A));
    Cv.Pixels[X, Y] := RGB(R, G, B);
  end;

var
  I, K, Steps: Integer;
  T, X, Y, F, Ofs: Single;
  Steep: Boolean;
begin
  Steep := Abs(Y1 - Y0) > Abs(X1 - X0);
  Steps := Max(1, Ceil(Max(Abs(X1 - X0), Abs(Y1 - Y0))));
  for K := 0 to W - 1 do
  begin
    Ofs := K - (W - 1) / 2;
    for I := 0 to Steps do
    begin
      T := I / Steps;
      X := X0 + (X1 - X0) * T;
      Y := Y0 + (Y1 - Y0) * T;
      if Steep then
      begin
        X := X + Ofs;
        F := X - Floor(X);
        Blend(Floor(X), Round(Y), 1 - F);
        Blend(Floor(X) + 1, Round(Y), F);
      end
      else
      begin
        Y := Y + Ofs;
        F := Y - Floor(Y);
        Blend(Round(X), Floor(Y), 1 - F);
        Blend(Round(X), Floor(Y) + 1, F);
      end;
    end;
  end;
end;

{ Schraube (Kreuzschlitz schraeg): Kopf mit Rand, Schlitz kantengeglaettet }
procedure DrawScrew(Cv: TCanvas; Cx, Cy, Sr: Integer);
begin
  Granular.Fader.Ellipse0(Cv.Handle, Cx, Cy, Sr, $005A524C, $00151210);
  AALineCv(Cv, Cx - Sr + 1, Cy + Sr - 1, Cx + Sr - 1, Cy - Sr + 1, $00201C1A);
end;

function MixShade(C: TColor; F: Double): TColor;
var
  R, G, B: Integer;
begin
  C := ColorToRGB(C);
  R := EnsureRange(Round((C and $FF) * F), 0, 255);
  G := EnsureRange(Round(((C shr 8) and $FF) * F), 0, 255);
  B := EnsureRange(Round(((C shr 16) and $FF) * F), 0, 255);
  Result := TColor(R or (G shl 8) or (B shl 16));
end;

procedure MixBevel(Cv: TCanvas; R: TRect; Hi, Lo: TColor);
begin
  Cv.Pen.Color := Hi;
  Cv.MoveTo(R.Left, R.Bottom - 1); Cv.LineTo(R.Left, R.Top); Cv.LineTo(R.Right - 1, R.Top);
  Cv.Pen.Color := Lo;
  Cv.LineTo(R.Right - 1, R.Bottom - 1); Cv.LineTo(R.Left - 1, R.Bottom - 1);
end;

destructor TCachedPanel.Destroy;
begin
  FCache.Free;
  inherited;
end;

procedure TCachedPanel.Resize;
begin
  FreeAndNil(FCache);                 // neue Groesse: Bild beim naechsten Zeichnen neu erzeugen
  inherited;
end;

procedure TCachedPanel.Paint;
begin
  if (FCache = nil) or (FCache.Width <> ClientWidth) or (FCache.Height <> ClientHeight) then
  begin
    FreeAndNil(FCache);
    FCache := Vcl.Graphics.TBitmap.Create;
    FCache.PixelFormat := pf24bit;
    FCache.SetSize(Max(1, ClientWidth), Max(1, ClientHeight));
    DrawBack(FCache.Canvas, Rect(0, 0, ClientWidth, ClientHeight));
  end;
  Canvas.Draw(0, 0, FCache);
end;

procedure TMixDeck.DrawBack(Cv: TCanvas; const R0: TRect);
var
  R: TRect;
  I, Cx, Cy, Sr: Integer;
begin
  R := R0;
  Cv.Brush.Color := DECK_BG;
  Cv.FillRect(R);
  // Gehaeuse: doppelte Fase (aussen hell/dunkel, innen umgekehrt = eingefasster Rahmen)
  MixBevel(Cv, R, $00534B45, $000C0A09);
  InflateRect(R, -1, -1);
  MixBevel(Cv, R, $00403934, $00100E0D);
  InflateRect(R, -4, -4);
  MixBevel(Cv, R, $00100E0D, $00453E39);
  // Schrauben in den Ecken
  Sr := Max(2, ScaleValue(3));
  for I := 0 to 3 do
  begin
    if I mod 2 = 0 then Cx := ScaleValue(4) + Sr else Cx := R0.Right - ScaleValue(4) - Sr - 1;
    if I < 2 then Cy := ScaleValue(4) + Sr else Cy := R0.Bottom - ScaleValue(4) - Sr - 1;
    DrawScrew(Cv, Cx, Cy, Sr);
  end;
  // eingelassenes Display (Spektrum) wie an einem modernen Digitalgeraet: breite schwarze Einfassung,
  // darum eine Fase ins Gehaeuse, oben eine feine Glas-Lichtkante
  if Display <> nil then
  begin
    R := Display.BoundsRect;
    InflateRect(R, ScaleValue(6), ScaleValue(6));
    MixBevel(Cv, R, $00100E0D, $00564E48);
    InflateRect(R, -1, -1);
    Cv.Brush.Color := $000B0A0A;
    Cv.FillRect(R);
    Cv.Pen.Color := $00343030;
    Cv.MoveTo(R.Left + 2, R.Top + 1); Cv.LineTo(R.Right - 2, R.Top + 1);
    R := Display.BoundsRect;
    InflateRect(R, 1, 1);
    MixBevel(Cv, R, $00050505, $00242222);
  end;
end;

procedure TMixStrip.DrawBack(Cv: TCanvas; const R0: TRect);
var
  R, C: TRect;
  Y: Integer;
begin
  R := R0;
  // Grundflaeche mit sachtem Verlauf (oben etwas heller, wie gebuerstetes Metall im Licht)
  for Y := R.Top to R.Bottom - 1 do
  begin
    Cv.Pen.Color := MixShade(STRIP_BG, 1.08 - 0.10 * Y / Max(1, R.Bottom));
    Cv.MoveTo(R.Left, Y); Cv.LineTo(R.Right, Y);
  end;
  // Kappe in Gruppenfarbe mit heller Oberkante
  C := Rect(R.Left + 2, R.Top + 2, R.Right - 2, R.Top + 2 + CapH);
  Cv.Brush.Color := Cap;
  Cv.FillRect(C);
  Cv.Pen.Color := MixShade(Cap, 1.6);
  Cv.MoveTo(C.Left, C.Top); Cv.LineTo(C.Right, C.Top);
  Cv.Pen.Color := MixShade(Cap, 0.55);
  Cv.MoveTo(C.Left, C.Bottom); Cv.LineTo(C.Right, C.Bottom);
  // Fase des Moduls
  MixBevel(Cv, R, STRIP_HI, STRIP_LO);
end;

{ Funktionsbereich (LFO, Filter, Huellkurve ...): erhabenes Panel auf dunklerem Grund - Fase hell oben/links,
  dunkel unten/rechts, Kopfleiste hinter dem Titel etwas heller mit feiner bernsteinfarbener Unterkante.
  Rein statisch gezeichnet. }
type
  TGroupPanel = class(TPanel)
  private
    FCache: Vcl.Graphics.TBitmap;
    FLedShown: Boolean;
    FLedBr: Single;       // gezeigte Helligkeit (Spannungsabfall bei lautem Ausgang)
    FLedX, FLedY, FLedR: Integer;
    FLedImg: array[0..11] of Vcl.Graphics.TBitmap;   // vorgerechnete Helligkeitsstufen (einmal je Groesse)
    FLedOff: Vcl.Graphics.TBitmap;                    // Lampe aus
    FScrewImg: array[0..1] of Vcl.Graphics.TBitmap;   // untere Schrauben obenauf (mit Ring)
    function LedImage(On_: Boolean; K: Integer): Vcl.Graphics.TBitmap;
    procedure FreeLedImgs;
    procedure WMPaint(var Message: TWMPaint); message WM_PAINT;
    function LedOn: Boolean;
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    LedCheck: TCheckBox;    // Ein-Schalter der Funktionseinheit -> Betriebslampe oben rechts
    LedMaster: TCheckBox;   // uebergeordneter Schalter (z. B. Oszillator an): aus = Lampe aus
    LedFunc: TFunc<Boolean>;   // Lampe nach Bedingung (z. B. Saettigung > 0, Zone geladen)
    procedure UpdateLed;
    procedure SagLed(Br: Single);
    destructor Destroy; override;
  end;

const
  AREA_BG = $002A2624;            // Grund zwischen den Bereichen (wie BG_DARK)
  GRP_HEAD = 22;                  // Hoehe der Kopfleiste (bei 100 %)

destructor TGroupPanel.Destroy;
begin
  FreeLedImgs;
  FCache.Free;
  inherited;
end;

{ nach den Beschriftungen (TLabel zeichnen sich nach Paint): die unteren Schrauben noch einmal obenauf,
  mit einem schmalen Ring in Plattenfarbe - ragt ein Text in die Ecke, ist er dort "durchgeschraubt" }
procedure TGroupPanel.WMPaint(var Message: TWMPaint);
var
  DC: HDC;
  Cv: TCanvas;
  Sr, D, Y, E, K, X: Integer;
begin
  inherited;
  if FCache = nil then
    Exit;
  Sr := Max(2, ScaleValue(3));
  D := ScaleValue(3) + Sr;
  Y := ClientHeight - 1 - D;
  E := Sr + 4;
  for K := 0 to 1 do
  begin
    if K = 0 then X := D else X := ClientWidth - 1 - D;
    if FScrewImg[K] = nil then
    begin
      // einmal rechnen: Untergrund aus dem Zwischenbild, Ring in Plattenfarbe, Schraube
      FScrewImg[K] := Vcl.Graphics.TBitmap.Create;
      FScrewImg[K].PixelFormat := pf24bit;
      FScrewImg[K].SetSize(2 * E + 1, 2 * E + 1);
      Cv := FScrewImg[K].Canvas;
      BitBlt(Cv.Handle, 0, 0, 2 * E + 1, 2 * E + 1, FCache.Canvas.Handle, X - E, Y - E, SRCCOPY);
      Granular.Fader.Ellipse0(Cv.Handle, E, E, Sr + 2, Color, Color);
      DrawScrew(Cv, E, E, Sr);
    end;
  end;
  DC := GetDC(Handle);
  try
    BitBlt(DC, D - E, Y - E, 2 * E + 1, 2 * E + 1, FScrewImg[0].Canvas.Handle, 0, 0, SRCCOPY);
    BitBlt(DC, ClientWidth - 1 - D - E, Y - E, 2 * E + 1, 2 * E + 1, FScrewImg[1].Canvas.Handle, 0, 0, SRCCOPY);
  finally
    ReleaseDC(Handle, DC);
  end;
end;

procedure TGroupPanel.Resize;
begin
  FreeLedImgs;
  FreeAndNil(FCache);
  inherited;
end;

{ Gebrauchsspuren auf einer Metallplatte (24-Bit-Bitmap): feines Korn und einzelne Flugrost-Flecken,
  dezent. Zufall mit eigenem Startwert je Platte -> jede Platte anders, aber
  bei jedem Neuzeichnen gleich (kein Flackern). }
procedure WearPlate(B: Vcl.Graphics.TBitmap; Seed: Cardinal);
var
  St: Cardinal;
  X, Y, I, K, N, Cx, Cy, Rad, W, H: Integer;
  P: PByteArray;
  A, D, Rn: Single;

  function Rnd: Single;   // 0..1
  begin
    St := St * 1664525 + 1013904223;
    Result := (St shr 8) / 16777216;
  end;

  procedure Mix(X, Y: Integer; R, G, Bl: Integer; Alpha: Single);
  var
    Q: PByteArray;
  begin
    if (X < 2) or (Y < 2) or (X >= W - 2) or (Y >= H - 2) or (Alpha <= 0) then
      Exit;
    Q := B.ScanLine[Y];
    Q[X * 3] := Round(Q[X * 3] + (Bl - Q[X * 3]) * Alpha);
    Q[X * 3 + 1] := Round(Q[X * 3 + 1] + (G - Q[X * 3 + 1]) * Alpha);
    Q[X * 3 + 2] := Round(Q[X * 3 + 2] + (R - Q[X * 3 + 2]) * Alpha);
  end;

begin
  W := B.Width; H := B.Height;
  if (W < 20) or (H < 20) then
    Exit;
  St := Seed or 1;
  // feines Korn (+-2 Helligkeit)
  for Y := 2 to H - 3 do
  begin
    P := B.ScanLine[Y];
    for X := 2 to W - 3 do
      if Rnd < 0.5 then
      begin
        K := Round(Rnd * 8) - 4;
        for I := 0 to 2 do
          P[X * 3 + I] := EnsureRange(P[X * 3 + I] + K, 0, 255);
      end;
  end;
  // Flugrost: wenige weiche, unregelmaessige Flecken
  N := 2 + (W * H) div 25000;
  for K := 1 to N do
  begin
    Cx := Round(Rnd * W); Cy := Round(Rnd * H);
    Rad := 3 + Round(Rnd * 7);
    for Y := Cy - Rad to Cy + Rad do
      for X := Cx - Rad to Cx + Rad do
      begin
        D := Sqrt(Sqr(X - Cx) + Sqr(Y - Cy)) / Rad;
        Rn := Rnd;
        if (D < 1) and (Rn < 0.75 - 0.5 * D) then
        begin
          A := (1 - D) * (0.20 + 0.20 * Rnd);
          Mix(X, Y, 120 + Round(Rnd * 40), 62 + Round(Rnd * 20), 30, A);
        end;
      end;
  end;
end;

{ Betriebs-LED, je Pixel berechnet (weich, ohne Fragmente): schmale dunkle Fassung, Kuppel mit Verlauf,
  an = warmes Bernstein wie die Werte-Schrift mit leichtem Schein, aus = mattes, ungefaerbtes Glas }
procedure DrawLed(Cv: TCanvas; Cx, Cy, Rad: Integer; On_: Boolean; Br: Single = 1);
var
  X, Y: Integer;
  D, Cov, T, Rf, Hl, Gl: Single;
  Bg: TColor;
  R, G, B, R0, G0, B0, R1, G1, B1: Single;

  procedure Put(X, Y: Integer; Rr, Gg, Bb, A: Single);
  begin
    if A <= 0.01 then
      Exit;
    A := Min(A, 1);
    Bg := ColorToRGB(Cv.Pixels[X, Y]);
    Cv.Pixels[X, Y] := RGB(Round(Rr * A + (Bg and $FF) * (1 - A)), Round(Gg * A + ((Bg shr 8) and $FF) * (1 - A)),
      Round(Bb * A + ((Bg shr 16) and $FF) * (1 - A)));
  end;

begin
  if On_ then
  begin
    R0 := 255; G0 := 214; B0 := 130;   // Mitte (Bernstein)
    R1 := 214; G1 := 132; B1 := 40;    // Rand
    // Spannung sackt ab: dunkler und waermer (Blau/Gruen sinken staerker als Rot)
    R0 := R0 * (0.55 + 0.45 * Br); G0 := G0 * Br; B0 := B0 * Br * Br;
    R1 := R1 * (0.55 + 0.45 * Br); G1 := G1 * Br; B1 := B1 * Br * Br;
  end
  else
  begin
    R0 := 100; G0 := 96; B0 := 90;
    R1 := 74; G1 := 71; B1 := 67;
  end;
  Rf := Rad + 0.5;
  for Y := Cy - Rad - 8 to Cy + Rad + 8 do
    for X := Cx - Rad - 8 to Cx + Rad + 8 do
    begin
      D := Sqrt(Sqr(X - Cx) + Sqr(Y - Cy));
      // Schein (nur an): ganz leicht, weich auslaufend
      if On_ and (D > Rf) then
      begin
        Gl := 0.26 * Br * Sqr(Max(0, 1 - (D - Rf) / 7.5));   // weit und weich auslaufend
        if Gl > 0 then
          Put(X, Y, 255, 176, 72, Gl);
      end;
      // Fassung: duenner dunkler Ring
      Cov := EnsureRange(Rf + 1.5 - D, 0, 1);
      if (Cov > 0) and (D > Rf - 0.5) then
        if On_ then
          Put(X, Y, 72, 50, 26, Cov * 0.85)   // Fassung vom Licht leicht angestrahlt
        else
          Put(X, Y, 40, 38, 36, Cov * 0.7);   // Fassung aus: weicher, kaum dunkler als die Platte
      // Kuppel
      Cov := EnsureRange(Rf - D, 0, 1);
      if Cov > 0 then
      begin
        T := EnsureRange(Sqrt(Sqr(X - Cx + 0.6) + Sqr(Y - Cy + 0.6)) / Rf, 0, 1);   // Licht von oben links
        R := R0 + (R1 - R0) * T; G := G0 + (G1 - G0) * T; B := B0 + (B1 - B0) * T;
        Hl := EnsureRange(1 - Sqrt(Sqr(X - Cx + Rad * 0.45) + Sqr(Y - Cy + Rad * 0.45)) / (Rad * 0.55), 0, 1) * 0.55;
        R := R + (255 - R) * Hl; G := G + (255 - G) * Hl; B := B + (255 - B) * Hl;   // Glanzpunkt
        Put(X, Y, R, G, B, Cov);
      end;
    end;
end;

procedure TGroupPanel.Paint;
var
  R: TRect;
  Hh, Y, Sr, D: Integer;
  Cv: TCanvas;
begin
  if (FCache = nil) or (FCache.Width <> ClientWidth) or (FCache.Height <> ClientHeight) then
  begin
    FreeAndNil(FCache);
    FCache := Vcl.Graphics.TBitmap.Create;
    FCache.PixelFormat := pf24bit;
    FCache.SetSize(Max(1, ClientWidth), Max(1, ClientHeight));
    Cv := FCache.Canvas;
    R := Rect(0, 0, ClientWidth, ClientHeight);
    Cv.Brush.Color := Color;
    Cv.FillRect(R);
    Hh := ScaleValue(GRP_HEAD);
    for Y := 1 to Hh - 1 do
    begin
      Cv.Pen.Color := MixShade(Color, 1.16 - 0.12 * Y / Hh);
      Cv.MoveTo(1, Y); Cv.LineTo(R.Right - 1, Y);
    end;
    Cv.Pen.Color := MixShade($005AD2FF, 0.42);
    Cv.MoveTo(1, Hh); Cv.LineTo(R.Right - 1, Hh);
    MixBevel(Cv, R, $005C5550, $00141110);
    // Gebrauchsspuren (Startwert aus Lage und Groesse: jede Platte eigen, stabil beim Neuzeichnen)
    WearPlate(FCache, Cardinal(Left * 7919 + Top * 104729 + ClientWidth * 31 + ClientHeight * 131 + Length(Name) * 17));
    // aufs Geraet geschraubt: kleine Schrauben in den vier Ecken (oben in der Kopfleiste)
    Sr := Max(2, ScaleValue(3));
    D := ScaleValue(3) + Sr;
    DrawScrew(Cv, D, Hh div 2, Sr);
    DrawScrew(Cv, R.Right - 1 - D, Hh div 2, Sr);
    DrawScrew(Cv, D, R.Bottom - 1 - D, Sr);
    DrawScrew(Cv, R.Right - 1 - D, R.Bottom - 1 - D, Sr);
  end;
  Canvas.Draw(0, 0, FCache);
  // Betriebslampe: eingelassene LED oben rechts, etwas Abstand zur Schraube
  if (LedCheck <> nil) or (LedMaster <> nil) or Assigned(LedFunc) then
  begin
    Sr := Max(2, ScaleValue(3));
    D := ScaleValue(3) + Sr;
    Y := ScaleValue(GRP_HEAD) div 2;
    Hh := ScaleValue(3);                                        // LED-Radius
    R.Left := ClientWidth - 1 - D - Sr - ScaleValue(10) - Hh;   // Mitte: rechts, etwas Abstand zur Schraube
    FLedShown := LedOn;
    if FLedBr <= 0 then FLedBr := 1;
    if (FLedX <> R.Left) or (FLedY <> Y) or (FLedR <> Hh) then
      FreeLedImgs;
    FLedX := R.Left; FLedY := Y; FLedR := Hh;
    D := FLedR + 9;
    BitBlt(Canvas.Handle, FLedX - D, FLedY - D, 2 * D + 1, 2 * D + 1,
      LedImage(FLedShown, EnsureRange(Round((1 - FLedBr) / 0.5 * 11), 0, 11)).Canvas.Handle, 0, 0, SRCCOPY);
  end;
end;

function TGroupPanel.LedOn: Boolean;
begin
  Result := ((LedCheck = nil) or LedCheck.Checked) and ((LedMaster = nil) or LedMaster.Checked) and
    (not Assigned(LedFunc) or LedFunc());
end;

{ nur die Lampe neu: Untergrund aus dem Zwischenbild, Lampe mit neuer Helligkeit, ein BitBlt }
procedure TGroupPanel.FreeLedImgs;
var
  I: Integer;
begin
  for I := 0 to High(FLedImg) do
    FreeAndNil(FLedImg[I]);
  FreeAndNil(FLedOff);
  FreeAndNil(FScrewImg[0]);
  FreeAndNil(FScrewImg[1]);
end;

{ Lampe als fertiges Bild (Untergrund aus dem Zwischenbild); einmal gerechnet, danach nur kopiert }
function TGroupPanel.LedImage(On_: Boolean; K: Integer): Vcl.Graphics.TBitmap;
var
  E: Integer;
begin
  if On_ then Result := FLedImg[K] else Result := FLedOff;
  if Result <> nil then
    Exit;
  E := FLedR + 9;
  Result := Vcl.Graphics.TBitmap.Create;
  Result.PixelFormat := pf24bit;
  Result.SetSize(2 * E + 1, 2 * E + 1);
  BitBlt(Result.Canvas.Handle, 0, 0, 2 * E + 1, 2 * E + 1, FCache.Canvas.Handle, FLedX - E, FLedY - E, SRCCOPY);
  DrawLed(Result.Canvas, E, E, FLedR, On_, 1 - K * 0.5 / 11);
  if On_ then FLedImg[K] := Result else FLedOff := Result;
end;

procedure TGroupPanel.SagLed(Br: Single);
var
  E, X0, Y0, K: Integer;
  DC: HDC;
begin
  if not FLedShown or (FCache = nil) or (FLedR <= 0) or not HandleAllocated or not IsWindowVisible(Handle) then
    Exit;
  // 12 Stufen von 0,5 bis 1: nur bei Stufenwechsel etwas tun
  K := EnsureRange(Round((1 - Br) / 0.5 * 11), 0, 11);
  if Round((1 - FLedBr) / 0.5 * 11) = K then
    Exit;
  FLedBr := 1 - K * 0.5 / 11;
  E := FLedR + 9;
  X0 := FLedX - E; Y0 := FLedY - E;
  DC := GetDC(Handle);
  try
    BitBlt(DC, X0, Y0, 2 * E + 1, 2 * E + 1, LedImage(True, K).Canvas.Handle, 0, 0, SRCCOPY);
  finally
    ReleaseDC(Handle, DC);
  end;
end;

procedure TGroupPanel.UpdateLed;
begin
  if ((LedCheck <> nil) or (LedMaster <> nil) or Assigned(LedFunc)) and (LedOn <> FLedShown) then
    Invalidate;
end;


function TGranularEditor.MakePanel(AParent: TWinControl; AAlign: TAlign; const ATitle: string): TPanel;
const
  AREA_TAG = 7731;
var
  L: TLabel;
  Grund: TPanel;
  I: Integer;
begin
  // direkt auf einem Reiter: erst einen dunklen Grund anlegen (einmal je Reiter), damit zwischen den
  // erhabenen Bereichen nicht die helle Reiterflaeche durchscheint
  if (AParent is TTabSheet) and (AAlign <> alNone) then
  begin
    Grund := nil;
    for I := 0 to AParent.ControlCount - 1 do
      if (AParent.Controls[I] is TPanel) and (AParent.Controls[I].Tag = AREA_TAG) then
        Grund := TPanel(AParent.Controls[I]);
    if Grund = nil then
    begin
      Grund := TPanel.Create(Self);
      Grund.Parent := AParent;
      Grund.Tag := AREA_TAG;
      Grund.Align := alClient;
      Grund.BevelOuter := bvNone;
      Grund.ParentBackground := False;
      Grund.Color := AREA_BG;
    end;
    AParent := Grund;
  end;
  Result := TGroupPanel.Create(Self);
  Result.Parent := AParent;
  if AAlign <> alNone then
  begin
    // Luft rundherum, damit jeder Bereich als eigenes, erhabenes Feld auf dem dunkleren Grund steht
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(3, 3, 3, 3);
  end;
  Result.Align := AAlign;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Color := BG_MAIN;
  Result.OnResize := PanelResize;
  if ATitle <> '' then
  begin
    L := TLabel.Create(Self);
    L.Parent := Result;
    L.SetBounds(18, 4, 300, 16);
    L.Caption := ATitle;
    L.Font.Color := COL_VAL;
    L.Font.Style := [fsBold];
    L.Transparent := True;
  end;
end;

procedure TGranularEditor.AddStretch(Ctrl: TControl; RightGap: Integer; AlignRight: Boolean);
var
  Item: TStretchItem;
begin
  Item.Ctrl := Ctrl;
  Item.Left := Ctrl.Left;
  Item.RightGap := RightGap;
  Item.AlignRight := AlignRight;
  FStretch := FStretch + [Item];
end;

procedure TGranularEditor.ApplyScale(M, D: Integer);
var
  I: Integer;
begin
  if (M = D) or (D <= 0) then
    Exit;
  // eigene Schrift: sonst skaliert Delphi nur Steuerelemente mit eigener Schrift, alle anderen
  // (Knoepfe, Reiter, Listen) erben die unveraenderte Schrift des Formulars
  ParentFont := False;
  ScaleBy(M, D);
  for I := 0 to High(FStretch) do
  begin
    FStretch[I].Left := MulDiv(FStretch[I].Left, M, D);
    FStretch[I].RightGap := MulDiv(FStretch[I].RightGap, M, D);
  end;
  RelayoutAll(nil);
end;

procedure TGranularEditor.PanelResize(Sender: TObject);
var
  I, W: Integer;
begin
  W := (Sender as TWinControl).ClientWidth;
  for I := 0 to High(FStretch) do
    if FStretch[I].Ctrl.Parent = Sender then
      if FStretch[I].AlignRight then
        FStretch[I].Ctrl.Left := W - FStretch[I].RightGap - FStretch[I].Ctrl.Width
      else
        FStretch[I].Ctrl.Width := Max(30, W - FStretch[I].Left - FStretch[I].RightGap);
end;

{ Reiterwechsel ohne sichtbaren Aufbau: vor dem Wechsel das Zeichnen sperren, danach Layout anpassen,
  freigeben und alles in einem Rutsch neu zeichnen (sonst sieht man, wie die Steuerelemente nacheinander
  erscheinen) }
procedure TGranularEditor.PagesChanging(Sender: TObject; var AllowChange: Boolean);
begin
  if FPages.HandleAllocated then
    SendMessage(FPages.Handle, WM_SETREDRAW, 0, 0);
end;

procedure TGranularEditor.PagesChange(Sender: TObject);
var
  ExSt: NativeInt;
begin
  try
    RelayoutAll(Sender);
    // Werte und Live-Anzeigen des neuen Reiters sofort nachziehen (sonst zeigen die Regler kurz ihre
    // Grundstellung, bis der Timer das naechste Mal laeuft) - noch bei gesperrtem Zeichnen
    TimerTick(nil);
    SyncControlsFromEngine;
  finally
    if FPages.HandleAllocated then
    begin
      // ganzer Reiter-Baum in einem Rutsch: Windows setzt alle Unterfenster erst im Speicher zusammen
      // (WS_EX_COMPOSITED) und zeigt das fertige Bild - kein sichtbarer Aufbau, bis dahin bleibt der alte Reiter
      ExSt := GetWindowLong(FPages.Handle, GWL_EXSTYLE);
      SetWindowLong(FPages.Handle, GWL_EXSTYLE, ExSt or WS_EX_COMPOSITED);
      SendMessage(FPages.Handle, WM_SETREDRAW, 1, 0);
      RedrawWindow(FPages.Handle, nil, 0, RDW_ERASE or RDW_FRAME or RDW_INVALIDATE or RDW_ALLCHILDREN or RDW_UPDATENOW);
      SetWindowLong(FPages.Handle, GWL_EXSTYLE, ExSt);
    end;
  end;
end;

procedure TGranularEditor.RelayoutAll(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to High(FStretch) do
    PanelResize(FStretch[I].Ctrl.Parent);
  // Sprachflagge ueber dem freien Ende der Reiterzeile
  if FStatus <> nil then
    FStatus.Width := Max(60, FStatus.Parent.ClientWidth - FStatus.Left - 6);
  if (FLangFlagHost <> nil) and (FPages <> nil) then
  begin
    FLangFlagHost.SetBounds(ClientWidth - 30, FPages.Top + 5, 21, 14);
    FLangFlagHost.BringToFront;
    if FUpdHost <> nil then
    begin
      FUpdHost.SetBounds(ClientWidth - 52, FPages.Top + 4, 16, 16);
      FUpdHost.BringToFront;
    end;
  end;
end;

const
  WK_NONE = -1; WK_SINE = 0; WK_TRI = 1; WK_SAW = 2; WK_SQUARE = 3; WK_FM = 4; WK_NOISE = 5; WK_SH = 6;
  WK_FREE = 7; WK_OFF = 8;
  // Filter: Frequenzgang (links tief, rechts hoch)
  WK_LP = 10; WK_BP = 11; WK_HP = 12; WK_LADDER = 13; WK_COMB = 14; WK_FORMANT = 15;

{ Wellenform eines Listeneintrags (fuer das Bild in der Auswahlliste), WK_NONE = keine Wellen-Liste }
function WaveKind(ParamIdx, Step: Integer): Integer;
const
  LFO_MAP: array[0..5] of Integer = (WK_SINE, WK_TRI, WK_SAW, WK_SQUARE, WK_SH, WK_FREE);
  MORPH_MAP: array[0..6] of Integer = (WK_OFF, WK_SINE, WK_TRI, WK_SAW, WK_SQUARE, WK_SH, WK_FREE);
begin
  Result := WK_NONE;
  if (ParamIdx < 0) or (ParamIdx >= PARAM_COUNT) then
    Exit;
  case TGranularParamId(ParamIdx) of
    gpOscWave, gpOsc2Wave, gpOsc3Wave: Result := EnsureRange(Step, 0, 5);
    gpSubWave: if Step = 1 then Result := WK_SQUARE else Result := WK_SINE;
    gpLfo1Shape, gpLfo2Shape, gpLfo3Shape, gpLfo4Shape, gpLfo5Shape, gpLfo6Shape, gpLfo7Shape, gpLfo8Shape:
      Result := LFO_MAP[EnsureRange(Step, 0, 5)];
    gpMorphLfoShape: Result := MORPH_MAP[EnsureRange(Step, 0, 6)];
    gpFltType, gpFlt2Type: Result := WK_LP + EnsureRange(Step, 0, 5);
    gpOscFltType, gpOsc2FltType, gpOsc3FltType: Result := WK_LP + EnsureRange(Step, 0, 2);
  end;
end;

{ eine Periode der Form in R zeichnen (kantengeglaettet) }
procedure DrawWaveIcon(Cv: TCanvas; const R: TRect; Kind: Integer; Col: TColor);
const
  SH: array[0..5] of Single = (0.3, -0.7, 0.9, -0.2, 0.6, -0.9);
  FREE_PTS: array[0..7] of Single = (0, 0.8, 0.3, -0.5, -0.9, 0.2, 0.6, 0);
var
  I, N: Integer;
  X0, Y0, X1, Y1, W, Hh, Mid, T, V, PV: Single;

  function Val(T: Single): Single;
  begin
    case Kind of
      WK_SINE: Result := Sin(2 * Pi * T);
      WK_TRI: if T < 0.25 then Result := 4 * T else if T < 0.75 then Result := 2 - 4 * T else Result := 4 * T - 4;
      WK_SAW: Result := 1 - 2 * T;
      WK_FM: Result := Sin(2 * Pi * T + 2.2 * Sin(4 * Pi * T));
      WK_LP: Result := 0.45 - 1.5 / (1 + Exp(-(T - 0.66) * 16)) + 0.25 * Exp(-Sqr((T - 0.56) / 0.06));
      WK_HP: Result := 0.45 - 1.5 / (1 + Exp(-(0.34 - T) * 16)) + 0.25 * Exp(-Sqr((T - 0.44) / 0.06));
      WK_LADDER: Result := 0.45 - 1.6 / (1 + Exp(-(T - 0.64) * 30)) + 0.45 * Exp(-Sqr((T - 0.58) / 0.045));
      WK_BP: Result := -0.9 + 1.7 * Exp(-Sqr((T - 0.5) / 0.13));
      WK_COMB: Result := -0.85 + 1.6 * Sqr(Sqr(Abs(Cos(Pi * 3.5 * T))));
      WK_FORMANT: Result := Min(0.95, -0.9 + 1.7 * Exp(-Sqr((T - 0.22) / 0.05)) + 1.4 * Exp(-Sqr((T - 0.52) / 0.05))
        + 1.0 * Exp(-Sqr((T - 0.8) / 0.05)));
      WK_FREE: Result := FREE_PTS[Min(7, Trunc(T * 7))] + (FREE_PTS[Min(7, Trunc(T * 7) + 1)] - FREE_PTS[Min(7, Trunc(T * 7))]) * Frac(T * 7);
    else
      Result := 0;
    end;
  end;

begin
  W := R.Right - R.Left - 1;
  Hh := (R.Bottom - R.Top) / 2 - 2;
  Mid := (R.Top + R.Bottom) / 2;
  case Kind of
    WK_OFF:
      AALineCv(Cv, R.Left, Mid, R.Right - 1, Mid, Col);
    WK_SQUARE:
      begin
        AALineCv(Cv, R.Left, Mid - Hh, R.Left + W / 2, Mid - Hh, Col);
        AALineCv(Cv, R.Left + W / 2, Mid - Hh, R.Left + W / 2, Mid + Hh, Col);
        AALineCv(Cv, R.Left + W / 2, Mid + Hh, R.Left + W, Mid + Hh, Col);
      end;
    WK_SH:
      for I := 0 to 5 do
      begin
        X0 := R.Left + W * I / 6; X1 := R.Left + W * (I + 1) / 6;
        AALineCv(Cv, X0, Mid - SH[I] * Hh, X1, Mid - SH[I] * Hh, Col);
        if I < 5 then
          AALineCv(Cv, X1, Mid - SH[I] * Hh, X1, Mid - SH[I + 1] * Hh, Col);
      end;
    WK_NOISE:
      begin
        N := 7;
        PV := 0;
        for I := 0 to Round(W) div 2 do
        begin
          N := (N * 1103515245 + 12345) and $7FFFFFFF;
          V := (N mod 2000) / 1000 - 1;
          AALineCv(Cv, R.Left + (I - 1) * 2, Mid - PV * Hh, R.Left + I * 2, Mid - V * Hh, Col);
          PV := V;
        end;
      end;
  else
    begin
      N := Max(8, Round(W));
      X0 := R.Left; Y0 := Mid - Val(0) * Hh;
      for I := 1 to N do
      begin
        T := I / N;
        if (Kind = WK_SAW) and (I = N) then T := 0.9999;
        X1 := R.Left + W * T; Y1 := Mid - Val(T) * Hh;
        AALineCv(Cv, X0, Y0, X1, Y1, Col);
        X0 := X1; Y0 := Y1;
      end;
      if Kind = WK_SAW then
        AALineCv(Cv, X0, Y0, X0, Mid - Hh, Col);
    end;
  end;
end;

procedure TGranularEditor.WaveItemIcon(Sender: TObject; Index: Integer; Cv: TCanvas; const R: TRect; Col: TColor);
begin
  DrawWaveIcon(Cv, R, WaveKind(FBindings[(Sender as TComponent).Tag].Index, Index), Col);
end;

function TGranularEditor.AddParam(AParent: TWinControl; Index, X, Y, NameW, ValueW: Integer;
  ComboW: Integer; const ACaption: string; TrackW: Integer): Integer;
var
  B: TParamBinding;
  Info: TParamInfo;
  S: Integer;
  Cap: string;
begin
  Info := GetParamInfo(Index);
  if ACaption <> '' then Cap := ACaption else Cap := Info.Name;
  B := Default(TParamBinding);
  B.Index := Index;
  B.LastBase := -1;
  B.LastEff := -1;
  Result := Length(FBindings);

  if (Info.Curve = pcStepped) and (Info.Steps = 2) then
  begin
    B.Check := TCheckBox.Create(Self);
    B.Check.Parent := AParent;
    if NameW > 0 then
      Inc(X, COMBO_INSET);   // Haken buendig zur Schiene der Regler
    B.Check.SetBounds(X + NameW, Y + 1, 24, 24);        // Kippschalter (Granular.Fader)
    B.Check.Caption := '';
    B.Check.Tag := Result;
    B.Check.OnClick := CheckClick;
    // erster Ein-Schalter oben in einem Bereich ("... an") = Betriebslampe dieses Bereichs
    if (AParent is TGroupPanel) and (TGroupPanel(AParent).LedCheck = nil) and (Y <= 30) and
      (Info.Name.EndsWith(' an') or Cap.EndsWith(' an')) then
      TGroupPanel(AParent).LedCheck := B.Check;
    // eigenes Label: Windows-Themes ignorieren Font.Color bei Checkboxen
    B.NameLabel := TLabel.Create(Self);
    B.NameLabel.Parent := AParent;
    B.NameLabel.SetBounds(X + NameW + 27, Y + 5, 150, 16);
    B.NameLabel.Caption := Cap;
    B.NameLabel.Font.Color := COL_NAME;
    B.NameLabel.Transparent := True;
  end
  else
  begin
    if NameW > 0 then
    begin
      B.NameLabel := TLabel.Create(Self);
      B.NameLabel.Parent := AParent;
      B.NameLabel.SetBounds(X, Y + 5, NameW - 4, 16);
      B.NameLabel.Caption := Cap;
      B.NameLabel.Font.Color := COL_NAME;
      B.NameLabel.Transparent := True;
    end;
    if Info.Curve = pcStepped then
    begin
      B.Combo := TComboBox.Create(Self);
      B.Combo.Parent := AParent;
      // Matrix-Quelle/-Ziel: eintippen mit Autovervollstaendigung; nur gueltige Eintraege
      // werden uebernommen, sonst bleibt der alte Wert (s. MatrixComboValidate)
      if (Index >= MATRIX_BASE) and ((Index - MATRIX_BASE) mod MOD_STRIDE <= 1) then
      begin
        B.Combo.Style := csDropDown;
        B.Combo.AutoComplete := True;
        B.Combo.AutoDropDown := False;
        B.Combo.OnExit := MatrixComboExit;
        B.Combo.OnKeyDown := MatrixComboKeyDown;
      end
      else
        B.Combo.Style := csDropDownList;
      EnableComboFit(B.Combo);
      // mit Beschriftung: Liste buendig zur sichtbaren Schiene der Schieberegler darueber/darunter
      if NameW > 0 then
        B.Combo.SetBounds(X + NameW + COMBO_INSET, Y + 2, ComboW, 21)
      else
        B.Combo.SetBounds(X, Y + 2, ComboW, 21);
      B.Combo.DropDownCount := 32;
      B.Combo.Items.BeginUpdate;     // ohne Neuzeichnen je Eintrag (Matrix-Ziele: ~300 Eintraege)
      try
        for S := 0 to Info.Steps - 1 do
          B.Combo.Items.Add(Tr(StepName(Index, S)));
      finally
        B.Combo.Items.EndUpdate;
      end;
      // Matrix-Ziel: alphabetisch anzeigen ("Aus" bleibt oben), damit z.B. alle "Osz ..." beieinander
      // stehen - auch neue Regler, die intern hinten angehaengt sind
      if (Index >= MATRIX_BASE) and ((Index - MATRIX_BASE) mod MOD_STRIDE = 1) then
        SortDestCombo(B);
      B.Combo.Tag := Result;
      B.Combo.OnChange := ComboChange;
      // Wellenform-Auswahl (Oszillatoren, Sub, LFOs, Morph-LFO): kleines Bild der Form vor dem Namen
      if WaveKind(Index, 0) <> WK_NONE then
      begin
        B.Combo.OnItemIcon := WaveItemIcon;
      end;
    end
    else
    begin
      B.Track := TTrackBar.Create(Self);
      B.Track.Parent := AParent;
      B.Track.TickStyle := tsNone;
      B.Track.ThumbLength := 20;
      B.Track.SetBounds(X + NameW, Y, 100, 24);
      B.Track.Max := 1000;
      B.Track.PageSize := 50;
      B.Track.LineSize := 5;
      B.Track.Tag := Result;
      B.Track.OnChange := TrackChange;
      B.Track.OnModWheel := TrackModWheel;
      if Index < NAMED_COUNT then
        B.Track.PopupMenu := FModMenu;
      TControlAccess(B.Track).OnContextPopup := TrackContextPopup;
      if TrackW > 0 then
        B.Track.Width := TrackW         // feste Breite, Wert direkt dahinter
      else
        AddStretch(B.Track, ValueW + 6);

      B.ModMarker := TPanel.Create(Self);
      B.ModMarker.Parent := AParent;
      B.ModMarker.BevelOuter := bvNone;
      B.ModMarker.ParentBackground := False;
      B.ModMarker.Color := COL_MOD;
      B.ModMarker.SetBounds(X + NameW, Y + 22, 4, 4);
      B.ModMarker.Visible := False;

      B.ValueLabel := TLabel.Create(Self);
      B.ValueLabel.Parent := AParent;
      B.ValueLabel.AutoSize := False;
      B.ValueLabel.SetBounds(X + NameW + TrackW + 2, Y + 5, ValueW, 16);
      B.ValueLabel.Font.Color := COL_VAL;
      B.ValueLabel.Transparent := True;
      B.ValueLabel.ShowHint := True;
      B.ValueLabel.Tag := Result;
      B.ValueLabel.Cursor := crHandPoint;
      B.ValueLabel.OnClick := ValueLabelClick;
      if TrackW = 0 then
        AddStretch(B.ValueLabel, 4, True);
    end;
  end;
  ApplyParamHint(B);
  FBindings := FBindings + [B];
  FBindingOf[Index] := Result;
end;

{ senkrechter Fader fuer das Mischpult: Name oben, Wert darunter, Regler (oben = Maximum) }
function TGranularEditor.AddFader(AParent: TWinControl; Index, X, Y, H: Integer; const ACaption: string;
  W: Integer): Integer;
var
  B: TParamBinding;
begin
  B := Default(TParamBinding);
  B.Index := Index;
  B.LastBase := -1;
  B.LastEff := -1;
  B.Vertical := True;
  Result := Length(FBindings);
  B.NameLabel := TLabel.Create(Self);
  B.NameLabel.Parent := AParent;
  B.NameLabel.SetBounds(X, Y, W - 4, 16);
  B.NameLabel.Alignment := taCenter;
  B.NameLabel.AutoSize := False;
  B.NameLabel.Caption := ACaption;
  B.NameLabel.Font.Color := COL_NAME;
  B.NameLabel.Transparent := True;
  B.Track := TTrackBar.Create(Self);
  B.Track.Parent := AParent;
  B.Track.Orientation := trVertical;
  B.Track.TickStyle := tsNone;
  B.Track.ThumbLength := 28;                  // grosse Fader-Kappe wie am DJ-Mixer
  B.Track.SetBounds(X + (W - 4) div 2 - 22, Y + 20, 38, H);   // Fader mittig unter dem Namen
  B.Track.Max := 1000;
  B.Track.PageSize := 50;
  B.Track.LineSize := 5;
  B.Track.Tag := Result;
  B.Track.OnChange := TrackChange;
  B.Track.OnModWheel := TrackModWheel;
  if Index < NAMED_COUNT then
    B.Track.PopupMenu := FModMenu;
  TControlAccess(B.Track).OnContextPopup := TrackContextPopup;
  B.ValueLabel := TLabel.Create(Self);
  B.ValueLabel.Parent := AParent;
  B.ValueLabel.AutoSize := False;
  B.ValueLabel.Alignment := taCenter;
  B.ValueLabel.SetBounds(X, Y + 24 + H, W - 4, 16);
  B.ValueLabel.Font.Color := COL_VAL;
  B.ValueLabel.Transparent := True;
  B.ValueLabel.ShowHint := True;
  B.ValueLabel.Tag := Result;
  B.ValueLabel.Cursor := crHandPoint;
  B.ValueLabel.OnClick := ValueLabelClick;
  ApplyParamHint(B);
  FBindings := FBindings + [B];
  if FBindingOf[Index] < 0 then
    FBindingOf[Index] := Result;
end;

procedure TGranularEditor.BuildControls;

  function MakeButton(const ACaption: string; ALeft, AWidth: Integer; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := FTopBar;
    Result.SetBounds(ALeft, 6, AWidth, 25);
    Result.Caption := ACaption;
    Result.OnClick := AClick;
    Result.TabStop := False;
  end;

begin
  // Titelbanner (ganz oben)
  StartMark('Editor: vor Banner');
  FBanner := TBannerView.Create(Self, FEngine);
  StartMark('Banner erstellt');
  FBanner.Parent := Self;
  FBanner.Align := alTop;
  FBanner.Height := BANNER_H;

  // Kopfleiste
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := alTop;
  FTopBar.Top := FBanner.Height + 1;   // unter dem Banner einreihen
  FTopBar.Height := 37;
  FTopBar.BevelOuter := bvNone;
  FTopBar.ParentBackground := False;
  FTopBar.Color := BG_DARK;

  FLoadButton := MakeButton(Tr('Audio laden...'), 8, 104, LoadClick);
  FPanicButton := MakeButton(Tr('Alle Noten aus'), 116, 116, PanicClick);
  FOctDown := MakeButton(Tr('Okt -'), 240, 46, OctaveClick);
  FOctUp := MakeButton(Tr('Okt +'), 290, 46, OctaveClick);
  FLoadButton.Icon := eiOpen;
  FPanicButton.Icon := eiPanic;

  FPresetCombo := TComboBox.Create(Self);
  FPresetCombo.Parent := FTopBar;
  FPresetCombo.Style := csDropDownList;
  EnableComboFit(FPresetCombo);
  // Suchfeld: z.B. "fm", "arp", "natur" - Gross/Klein egal, Teil des Namens genuegt
  FPresetCat := TComboBox.Create(Self);
  FPresetCat.Parent := FTopBar;
  FPresetCat.Style := csDropDownList;
  FPresetCat.SetBounds(350, 8, 116, 21);
  FPresetCat.DropDownCount := 20;
  FPresetCat.TabStop := False;
  for var CatName in PRESET_CATS do
    FPresetCat.Items.Add(Tr(CatName));
  FPresetCat.ItemIndex := 0;
  FPresetCat.Hint := Tr('Kategorie der Presetliste (ergibt sich aus dem Namen); ★ Favoriten = mit dem Stern markierte');
  FPresetCat.ShowHint := True;
  FPresetCat.OnChange := PresetCatChange;
  FPresetFilter := TEdit.Create(Self);
  FPresetFilter.Parent := FTopBar;
  FPresetFilter.SetBounds(470, 8, 40, 21);
  FPresetFilter.TextHint := Tr('Filter');
  FPresetFilter.Color := $00A09C98;       // Metallgrau wie die Aufklapplisten
  FPresetFilter.Hint := Tr('Presetliste filtern: nur Namen, die diesen Text enthalten (z.B. FM, Arp, Natur, Stimme). ' +
    'Esc = Filter löschen, Enter = Liste aufklappen');
  FPresetFilter.ShowHint := True;
  FPresetFilter.OnChange := PresetFilterChange;
  FPresetFilter.OnKeyDown := PresetFilterKeyDown;
  FPresetPrev := MakeButton('<', 508, 24, PresetStepClick);
  FPresetPrev.Icon := eiPrev;
  FPresetPrev.IconOnly := True;
  FPresetCombo.SetBounds(534, 8, 156, 21);
  FPresetCombo.DropDownCount := 30;
  FPresetCombo.TabStop := False;
  FPresetCombo.OnChange := PresetComboChange;
  FPresetNext := MakeButton('>', 692, 24, PresetStepClick);
  FPresetNext.Icon := eiNext;
  FPresetNext.IconOnly := True;
  FPresetFav := MakeButton('☆', 720, 26, PresetFavClick);
  FPresetFav.Icon := eiStar;
  FPresetFav.IconOnly := True;
  FPresetFav.Hint := Tr('Aktuelles Preset als Favorit markieren / Markierung entfernen');
  FPresetFav.ShowHint := True;
  FPresetSave := MakeButton(Tr('Speichern...'), 750, 94, PresetSaveClick);
  FPresetSave.Icon := eiSave;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FTopBar;
  FClipLed := TClipLed.Create(Self, FEngine);
  FClipLed.Parent := FTopBar;
  FClipLed.SetBounds(850, 9, 36, 19);
  FClipLed.Hint := Tr('Leuchtet, wenn der weiche Clipper eingreift (Ausgang zu laut) - Lautstärke etwas zurücknehmen');
  FClipLed.ShowHint := True;
  FMidiLed := TClipLed.Create(Self, FEngine);
  FMidiLed.Midi := True;
  FMidiLed.Parent := FTopBar;
  FMidiLed.SetBounds(890, 9, 36, 19);
  FMidiLed.Hint := Tr('Leuchtet bei jedem MIDI-Ereignis (Noten, Pitchbend, Modrad, Aftertouch, Pedal)');
  FMidiLed.ShowHint := True;
  var B := MakeButton(Tr('Info'), 930, 44, InfoClick);
  B.Icon := eiInfo;
  B.Hint := Tr('Klartext-Übersicht: was passiert bei einem Tastendruck (live)');
  B := MakeButton(Tr('Hilfe'), 978, 48, HelpClick);
  B.Icon := eiHelp;
  B.Hint := Tr('Bedienung in einfachen Worten (Kapitel)');
  // Sprachflagge (klein, gedaempft): rechts in der Reiterzeile, Klick schaltet zur naechsten Sprache
  EnsureLangList;
  FLangFlagHost := TPanel.Create(Self);
  FLangFlagHost.Parent := Self;
  FLangFlagHost.BevelOuter := bvNone;
  FLangFlagHost.ParentBackground := False;
  FLangFlagHost.Color := BG_MAIN;
  FLangFlagHost.Caption := '';
  FLangFlag := TPaintBox.Create(Self);
  FLangFlag.Parent := FLangFlagHost;
  FLangFlag.Align := alClient;
  FLangFlag.Cursor := crHandPoint;
  FLangFlag.ShowHint := True;
  FLangFlag.OnPaint := LangFlagPaint;
  FLangFlag.OnClick := LangFlagClick;
  // Update-Hinweis: Pruefung im Hintergrund (hoechstens einmal am Tag), Symbol erst bei neuer Version
  FUpdHost := TPanel.Create(Self);
  FUpdHost.Parent := Self;
  FUpdHost.BevelOuter := bvNone;
  FUpdHost.ParentBackground := False;
  FUpdHost.Color := BG_MAIN;
  FUpdHost.Caption := '';
  FUpdHost.Visible := False;
  FUpdHost.Anchors := [akTop, akRight];
  FUpdIcon := TPaintBox.Create(Self);
  FUpdIcon.Parent := FUpdHost;
  FUpdIcon.Align := alClient;
  FUpdIcon.Cursor := crHandPoint;
  FUpdIcon.ShowHint := True;
  FUpdIcon.OnPaint := UpdIconPaint;
  FUpdIcon.OnClick := UpdIconClick;
  UpdateCheckStart(APP_VERSION);
  if FLangCodes.Count > 1 then
    FLangFlag.Hint := Format(Tr('Sprache wechseln (nächste: %s)'),
      [FLangNames[(Max(0, FLangCodes.IndexOf(LangCode)) + 1) mod FLangCodes.Count]])
  else
    FLangFlag.Hint := Tr('Sprache wechseln');
  FStatus.AutoSize := False;
  FStatus.EllipsisPosition := epEndEllipsis;
  FStatus.SetBounds(1034, 11, 220, 16);
  FStatus.Anchors := [akLeft, akTop, akRight];
  FStatus.Hint := Tr('PC-Tastatur: A W S E D F T G Z H U J K O L P spielt, + / - wechselt die Oktave');
  FStatus.ShowHint := True;
  FStatus.Font.Color := COL_NAME;
  FStatus.Transparent := True;

  // Unterer Block in fester Reihenfolge: Monitor oben, Klaviatur ganz unten.
  // Eigener Container, damit die Ausrichtung nie die Klaviatur zwischen die Diagramme schiebt.
  FBottom := TPanel.Create(Self);
  FBottom.Parent := Self;
  FBottom.Align := alBottom;
  FBottom.Height := 84 + 70;
  FBottom.BevelOuter := bvNone;
  FBottom.ParentBackground := False;
  FBottom.Color := Color;

  // Klaviaturzeile: links Pitchbend (federt zurueck) und Modrad, rechts die Tasten
  FKeysRow := TPanel.Create(Self);
  FKeysRow.Parent := FBottom;
  FKeysRow.Align := alBottom;
  FKeysRow.Height := 70;
  FKeysRow.BevelOuter := bvNone;
  FKeysRow.ParentBackground := False;
  FKeysRow.Color := Color;
  FBendWheel := TWheelView.Create(Self, Tr('Bend'), True);
  FBendWheel.Parent := FKeysRow;
  FBendWheel.SetBounds(4, 4, 28, 62);
  FBendWheel.OnChange := WheelChange;
  FBendWheel.Hint := Tr('Pitchbend: ziehen, beim Loslassen federt es zurück');
  FModWheel := TWheelView.Create(Self, Tr('Mod'), False);
  FModWheel.Parent := FKeysRow;
  FModWheel.SetBounds(36, 4, 28, 62);
  FModWheel.OnChange := WheelChange;
  FModWheel.Hint := Tr('Modrad: bleibt stehen');
  FKeys := TKeyboardView.Create(Self);
  FKeys.Parent := FKeysRow;
  FKeys.Align := alClient;
  FKeys.AlignWithMargins := True;
  FKeys.Margins.SetBounds(70, 0, 0, 0);
  FKeys.OnNote := KeyboardNote;

  // Monitor (Ausgang + Sidechain) ueber der Klaviatur, direkt unter dem Spektrum
  FMonitor := TMonitorView.Create(Self, FEngine);
  FMonitor.Parent := FBottom;
  FMonitor.Align := alClient;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FLangFlagHost.Anchors := [akTop, akRight];   // Lage setzt RelayoutAll (nach dem Ausrichten)
  FPages.TabStop := False;
  FPages.OnChanging := PagesChanging;
  FPages.OnChange := PagesChange;
  // Reihenfolge = Weg des Signals: Klang erzeugen -> je Note formen -> Bewegung -> Gesamtklang -> Spielhilfen
  FTabQuick := TTabSheet.Create(Self);
  FTabQuick.PageControl := FPages;
  FTabQuick.Caption := Tr('   Schnell   ');
  FTabSynth := TTabSheet.Create(Self);
  FTabSynth.PageControl := FPages;
  FTabSynth.Caption := Tr('   Grain   ');
  FTabSamples := TTabSheet.Create(Self);
  FTabSamples.PageControl := FPages;
  FTabSamples.Caption := Tr('   Samples   ');
  for var OI := 0 to OSC_COUNT - 1 do
  begin
    FTabOsc[OI] := TTabSheet.Create(Self);
    FTabOsc[OI].PageControl := FPages;
    FTabOsc[OI].Caption := Format(Tr('  Osz %d  '), [OI + 1]);
  end;
  FTabFlt := TTabSheet.Create(Self);
  FTabFlt.PageControl := FPages;
  FTabFlt.Caption := Tr('   Filter   ');
  FTabMod := TTabSheet.Create(Self);
  FTabMod.PageControl := FPages;
  FTabMod.Caption := Tr('   Modulation   ');
  FTabMod2 := TTabSheet.Create(Self);
  FTabMod2.PageControl := FPages;
  FTabMod2.Caption := Tr('   LFO 1-8 / Trigger   ');
  FTabTiming := TTabSheet.Create(Self);
  FTabTiming.PageControl := FPages;
  FTabTiming.Caption := Tr('   Timing / Hüllk.   ');
  FTabFx2 := TTabSheet.Create(Self);
  FTabFx2.PageControl := FPages;
  FTabFx2.Caption := Tr('   Effekte   ');
  FTabFx := TTabSheet.Create(Self);
  FTabFx.PageControl := FPages;
  FTabFx.Caption := Tr('   Echo / Hall   ');
  FTabEq := TTabSheet.Create(Self);
  FTabEq.PageControl := FPages;
  FTabEq.Caption := Tr('   Summe   ');
  FTabExtra := TTabSheet.Create(Self);
  FTabExtra.PageControl := FPages;
  FTabExtra.Caption := Tr('   Extras   ');
  FTabMix := TTabSheet.Create(Self);
  FTabMix.PageControl := FPages;
  FTabMix.Caption := Tr('  Mischpult  ');
  FTabPerf := TTabSheet.Create(Self);
  FTabPerf.PageControl := FPages;
  FTabPerf.Caption := Tr('  Leistung  ');

  FEditBinding := -1;
  FEditParam := -1;
  FLearnBinding := -1;
  FWheelParam := -1;
  FHostEditParam := -1;
  FGfxLevel := 1;   // = GFX_FG_BEST (30 B/s), Konstante steht weiter unten
  FFgLevel := 1;
  for var LI := 0 to High(FLevelLoad) do
    FLevelLoad[LI] := -1;
  FValueEdit := TEdit.Create(Self);
  FValueEdit.Parent := Self;
  FValueEdit.Visible := False;
  FValueEdit.Color := $00201A18;
  FValueEdit.Font.Color := COL_VAL;
  FValueEdit.OnKeyDown := ValueEditKeyDown;
  FValueEdit.OnExit := ValueEditExit;
  BuildModMenu;
  BuildQuickTab;
  StartMark('BuildQuickTab');
  BuildSynthTab;
  StartMark('BuildSynthTab');
  BuildModTab;
  StartMark('BuildModTab');
  BuildMod2Tab;
  StartMark('BuildMod2Tab');
  BuildTimingTab;
  StartMark('BuildTimingTab');
  BuildFxTab;
  BuildFilterTab;
  StartMark('BuildFxTab');
  BuildExtraTab;
  StartMark('BuildExtraTab');
  BuildEqTab;
  StartMark('BuildEqTab');
  BuildFx2Tab;
  BuildSampleTab;
  for var OI := 0 to OSC_COUNT - 1 do
    BuildOscTab(OI);
  StartMark('BuildOscTabs');
  BuildMixTab;
  BuildPerfTab;
  SetupLeds;
  StartMark('BuildMixTab');
  ApplyCaptionHints;
  ShowMatrixPage(0);
  ShowLfoPage(0);
  FPages.ActivePage := FTabSynth;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 33;                       // Anzeigen/Regler 30 Hz (Banner hat eigenen Takt)
  FTimer.OnTimer := TimerTick;

  // Banner-Animation mit eigenem Takt: Windows-Timer laufen in ~15,6-ms-Schritten,
  // 15 ms und jeder Schritt gezeichnet = ca. 60 Bilder/s
  FBannerTimer := TTimer.Create(Self);
  FBannerTimer.Interval := 15;
  FBannerTimer.OnTimer := BannerTimerTick;
end;

procedure TGranularEditor.BuildSynthTab;
const
  COL0: array[0..6] of TGranularParamId =
    (gpSelStart, gpSelEnd, gpPosition, gpSpray, gpScan, gpGrainSize, gpDensity);
  COL1: array[0..8] of TGranularParamId =
    (gpPitch, gpPitchRand, gpBendRange, gpSpread, gpGrainPan, gpReverse, gpVolume, gpWindow, gpKeyTrack);
  COL2: array[0..3] of TGranularParamId = (gpAttack, gpDecay, gpSustain, gpRelease);
var
  I: Integer;
begin
  // Reglerbereich fest unten, Wellenform fuellt den Rest (waechst im Vollbild mit)
  FSynthArea := TPanel.Create(Self);
  FSynthArea.Parent := FTabSynth;
  FSynthArea.Align := alBottom;
  FSynthArea.Height := 24 + 9 * ROW_H + 8;
  FSynthArea.BevelOuter := bvNone;
  FSynthArea.ParentBackground := False;
  FSynthArea.Color := AREA_BG;
  FSynthArea.OnResize := SynthAreaResize;

  FWave := TWaveView.Create(Self);
  FWave.Parent := FTabSynth;
  FWave.Align := alClient;
  FWave.OnSelectionChange := WaveSelectionChange;
  FWave.OnPreStartChange := WavePreStartChange;
  FWave.OnPositionChange := WavePositionChange;

  FCols[2] := MakePanel(FSynthArea, alClient, Tr('Hüllkurve'));
  FCols[0] := MakePanel(FSynthArea, alLeft, Tr('Sample / Grains'));
  FCols[1] := MakePanel(FSynthArea, alLeft, Tr('Klang'));
  FCols[1].Left := FCols[0].Left + FCols[0].Width + 1;  // Reihenfolge links -> rechts

  for I := 0 to High(COL0) do
    AddParam(FCols[0], Ord(COL0[I]), 8, 24 + I * ROW_H, 92, 66);
  // Grains abschaltbar: dann spielen nur die Oszillatoren (klassischer Synthesizer)
  AddParam(FCols[0], Ord(gpGrainOn), 8, 24 + 7 * ROW_H, 92, 0, 0, Tr('Grains an'));
  AddParam(FCols[0], Ord(gpGrainLevel), 232, 24 + 7 * ROW_H, 40, 66, 0, Tr('Pegel'));   // nur die Grains
  for I := 0 to High(COL1) do
    AddParam(FCols[1], Ord(COL1[I]), 8, 24 + I * ROW_H, 92, 66, 120);
  // Auto-Stimmung neben Key Tracking (gleiche Zeile)
  // Oktave der Grains (ganze Oktaven, zusaetzlich zu Pitch) rechts neben dem Fenster
  AddParam(FCols[1], Ord(gpGrainOct), 270, 24 + 7 * ROW_H, 52, 0, 84, Tr('Oktave'));
  AddParam(FCols[1], Ord(gpAutoTune), 270, 24 + 8 * ROW_H, 0, 0, 0, Tr('Auto-Stimmung'));

  FEnvView := TEnvelopeView.Create(Self, FEngine);
  SetupEnvView(FEnvView);
  FEnvView.Parent := FCols[2];
  FEnvView.SetBounds(8, 24, 100, 84);
  AddStretch(FEnvView, 8);
  for I := 0 to High(COL2) do
    AddParam(FCols[2], Ord(COL2[I]), 8, 114 + I * ROW_H, 70, 66);
  // Anlauf vor der Auswahl und Art der Schleife in der Auswahl
  AddParam(FCols[2], Ord(gpPreOn), 8, 114 + 4 * ROW_H + 2, 70, 0, 0, Tr('Anlauf'));
  AddParam(FCols[2], Ord(gpLoopMode), 158, 114 + 4 * ROW_H + 2, 0, 0, 0, Tr('Schleife hin und her'));
  AddParam(FCols[2], Ord(gpPreStart), 8, 114 + 5 * ROW_H + 2, 70, 66, 0, Tr('Anlauf-Start'));
end;

procedure TGranularEditor.SynthAreaResize(Sender: TObject);
var
  W: Integer;
begin
  W := FSynthArea.ClientWidth div 3;
  FCols[0].Width := W;
  FCols[1].Width := W;
end;

procedure TGranularEditor.BuildModTab;
const
  MX = 18;      // Platz fuer die Zeilennummer vor jeder Matrix-Zeile
var
  Left, Right, P, PMac: TPanel;
  K, S, Y: Integer;
  L: TLabel;
  NumL: TLabel;
  FirstB: Integer;
begin
  // LFO 1/2 und Trigger-Schwellen liegen im Reiter 'LFOs / Trigger' (links), die Matrix allein hier
  Left := TPanel.Create(Self);
  Left.Parent := FTabMod2;
  Left.Align := alLeft;
  Left.Width := 356;      // breit genug fuer die Listen Neustart/Stopp (auch englisch)
  Left.BevelOuter := bvNone;
  Left.ParentBackground := False;
  Left.Color := AREA_BG;

  // LFO 1/2 und an denselben Plaetzen LFO 5/6 (Umschalter im Reiter LFO)
  for K in [0, 1, 4, 5] do
    BuildLfoPanel(Left, K, (K mod 4) * 187, Left.Width);

  // Sidechain-Trigger: wann die LFO-Neustart-Option "Sidechain-Trigger" ausloest
  // (Verstaerkung/Attack/Release des Huellkurvenfolgers bleiben im Preset, ohne eigene Regler)
  P := MakePanel(Left, alNone, Tr('Trigger-Schwellen (Sidechain / Ausgang)'));
  P.SetBounds(0, 288, Left.Width, 204);
  FTrigPanel := P;
  FLevelView := TLevelView.Create(Self, FEngine);
  FLevelView.Parent := P;
  FLevelView.SetBounds(8, 24, 140, 20);
  AddParam(P, Ord(gpScPitchMode), 156, 20, 72, 0, 90);
  AddParam(P, Ord(gpScUseLevel), 8, 50, 0, 0, 0, Tr('Pegel'));
  AddParam(P, Ord(gpScTrigLevel), 90, 48, 60, 60, 0, Tr('Schwelle'));
  AddParam(P, Ord(gpScUsePitch), 8, 50 + 26, 0, 0, 0, Tr('Ton'));
  AddParam(P, Ord(gpScTrigNote), 90, 48 + 26, 60, 60, 0, Tr('über'));
  // eigener Ausgangspegel als Trigger (LFO-Neustart "Ausgang > Schwelle")
  // Pegelanzeige des eigenen Ausgangs mit Schwellen-Marke, rechts daneben die Schwelle
  FOutLevelView := TLevelView.Create(Self, FEngine);
  FOutLevelView.Output := True;
  FOutLevelView.Parent := P;
  FOutLevelView.SetBounds(8, 48 + 2 * 26 + 2, 112, 20);
  FOutLevelView.Hint := Tr('Eigener Ausgangspegel; weiße Marke = Schwelle für den Trigger "Ausgang > Schwelle"');
  FOutLevelView.ShowHint := True;
  AddParam(P, Ord(gpOutTrigLevel), 128, 48 + 2 * 26, 0, 60, 0, '');
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(8, 48 + 3 * 26 + 2, Left.Width - 16, 50);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Sidechain-Trigger: alle Haken müssen erfüllt sein. Ausgang > Schwelle: eigener Pegel, ' +
    'kein Selbst-Neustart, solange der LFO läuft.');
  AddStretch(L, 8);
  FMicCheck := TCheckBox.Create(Self);
  FMicCheck.Parent := P;
  FMicCheck.SetBounds(100, 48 + 5 * 26 + 4, 18, 18);  // nur Test-Host-Altbestand, unsichtbar
  FMicCheck.Caption := '';
  FMicCheck.Visible := False;
  FMicCheck.OnClick := MicClick;
  FMicLabel := TLabel.Create(Self);
  FMicLabel.Parent := P;
  FMicLabel.SetBounds(122, 48 + 5 * 26 + 5, 250, 16);
  FMicLabel.Caption := Tr('Mikrofon als Sidechain');
  FMicLabel.Font.Color := COL_NAME;
  FMicLabel.Transparent := True;
  FMicLabel.Visible := False;

  // Tempo kommt vom Host (VST-Zeitinfo) - kein eigener Regler mehr

  // Matrix
  // rechts die freien Makros als eigenes Feld (bleibt bei jeder Matrix-Seite stehen), links die Matrix
  PMac := MakePanel(FTabMod, alRight, Tr('Freie Makros'));
  PMac.Width := 440;
  Right := MakePanel(FTabMod, alClient, Tr('Modulationsmatrix'));
  for S := 0 to 4 do
  begin
    L := TLabel.Create(Self);
    L.Parent := Right;
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    case S of
      0: begin L.SetBounds(26 + MX, 26, 100, 16); L.Caption := Tr('Quelle'); end;
      1: begin L.SetBounds(130 + MX, 26, 120, 16); L.Caption := Tr('Ziel'); end;
      2: begin L.SetBounds(262 + MX, 26, 150, 16); L.Caption := Tr('Menge'); end;
      3: begin L.SetBounds(418 + MX, 26, 70, 16); L.Caption := Tr('Faktor'); end;
      4: begin L.SetBounds(496 + MX, 26, 120, 16); L.Caption := Tr('Offset'); end;
    end;
  end;
  // Seiten: je MAT_ROWS Zeilen, Knopf zeigt, wie viele Zeilen der Seite benutzt sind
  SetLength(FMatPageBtn, (MOD_SLOTS + MAT_ROWS - 1) div MAT_ROWS);
  for S := 0 to High(FMatPageBtn) do
  begin
    FMatPageBtn[S] := TButton.Create(Self);
    FMatPageBtn[S].Parent := Right;
    // in der Kopfleiste der Matrix, rechtsbuendig
    FMatPageBtn[S].SetBounds(0, 1, 84, 20);
    AddStretch(FMatPageBtn[S], 16 + (High(FMatPageBtn) - S) * 88, True);   // rechts frei fuer die Schraube
    FMatPageBtn[S].Tag := S;
    FMatPageBtn[S].TabStop := False;
    FMatPageBtn[S].OnClick := MatPageClick;
    FMatPageBtn[S].Hint := Tr('Matrix-Zeilen dieser Seite zeigen (in Klammern: benutzte Zeilen)');
    FMatPageBtn[S].ShowHint := True;
  end;
  // freie Makros: ein Regler bewegt beliebig viele Ziele (Matrix-Zeilen mit Quelle 'Makro n') - eigenes,
  // erhabenes Feld rechts neben der Matrix (bleibt bei jeder Matrix-Seite stehen)
  for K := 0 to UMAC_COUNT - 1 do
  begin
    Y := 30 + K * 50;
    AddParam(PMac, Ord(UMAC_IDS[K]), 8, Y, 62, 46, 0, '', 170);
    AddParam(PMac, Ord(UMAC_CURVE_IDS[K]), 292, Y, 0, 0, 138);
    FMacroTargets[K] := TLabel.Create(Self);
    FMacroTargets[K].Parent := PMac;
    FMacroTargets[K].AutoSize := False;
    FMacroTargets[K].SetBounds(70, Y + 25, 360, 16);
    FMacroTargets[K].Font.Color := $00909090;
    FMacroTargets[K].Transparent := True;
    AddStretch(FMacroTargets[K], 8);
  end;
  L := TLabel.Create(Self);
  L.Parent := PMac;
  L.SetBounds(8, 30 + UMAC_COUNT * 50, 420, 50);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  AddStretch(L, 8);
  L.Caption := Tr('Ziele zuweisen: Rechtsklick auf einen Regler > Modulieren mit > Makro 1-4, ' +
    'oder eine Matrix-Zeile mit Quelle "Makro n". Menge, Faktor und Offset je Ziel; ' +
    'die Kurve gilt für alle Ziele des Makros. Die Makros sind in der DAW automatisierbar.');

  for S := 0 to MOD_SLOTS - 1 do
  begin
    Y := 44 + (S mod MAT_ROWS) * 34;
    // leuchtende Anzeige statt Slotnummer: pulsiert mit der Quelle dieses Slots
    FSlotLeds[S] := TSlotLed.Create(Self, FEngine);
    FSlotLeds[S].Parent := Right;
    FSlotLeds[S].Slot := S;
    FSlotLeds[S].SetBounds(6 + MX, Y + 3, 16, 16);
    // Zeilennummer vorne: zeigt, auf welcher Seite der Matrix man ist
    NumL := TLabel.Create(Self);
    NumL.Parent := Right;
    NumL.AutoSize := False;
    NumL.Alignment := taRightJustify;
    NumL.SetBounds(2, Y + 4, MX + 2, 16);
    NumL.Caption := IntToStr(S + 1);
    NumL.Font.Color := COL_NAME;
    NumL.Transparent := True;
    FSlotLeds[S].Hint := Format(Tr('Zeile %d'), [S + 1]);
    FSlotLeds[S].ShowHint := True;
    FirstB := Length(FBindings);
    AddParam(Right, SlotSourceIndex(S), 26 + MX, Y, 0, 0, 100);
    AddParam(Right, SlotDestIndex(S), 130 + MX, Y, 0, 0, 128);
    AddParam(Right, SlotAmountIndex(S), 262 + MX, Y, 0, 46, 0, '', 108);
    AddParam(Right, SlotFactorIndex(S), 418 + MX, Y, 0, 0, 74);
    AddParam(Right, SlotOffsetIndex(S), 496 + MX, Y, 0, 50, 0, '', 120);
    FSlotCtrls[S] := [FSlotLeds[S], NumL];
    for K := FirstB to High(FBindings) do
      with FBindings[K] do
      begin
        if Track <> nil then FSlotCtrls[S] := FSlotCtrls[S] + [Track];
        if Combo <> nil then FSlotCtrls[S] := FSlotCtrls[S] + [Combo];
        if ValueLabel <> nil then FSlotCtrls[S] := FSlotCtrls[S] + [ValueLabel];
        if (NameLabel <> nil) and (NameLabel.Caption <> '') then FSlotCtrls[S] := FSlotCtrls[S] + [NameLabel];
      end;
    // Zeile leeren (Quelle, Ziel, Menge, Faktor, Offset) - ohne jedes Feld einzeln zurueckzustellen
    with TButton.Create(Self) do
    begin
      Parent := Right;
      SetBounds(496 + MX + 120 + 2 + 50 + 6, Y, 26, 22);
      Caption := #$00D7;
      Glyph := 1;              // Papierkorb-Symbol
      Tag := S;
      TabStop := False;
      Hint := Tr('Diese Matrix-Zeile leeren (Quelle aus, Ziel aus, Menge 0) - Strg+Z nimmt es zurück');
      ShowHint := True;
      OnClick := SlotClearClick;
      FSlotCtrls[S] := FSlotCtrls[S] + [TControl(Self.Components[Self.ComponentCount - 1])];
    end;
    FSlotGlobal[S] := TLabel.Create(Self);
    FSlotGlobal[S].Parent := Right;
    FSlotGlobal[S].SetBounds(132 + MX, Y + 23, 126, 11);
    FSlotGlobal[S].AutoSize := False;
    FSlotGlobal[S].Font.Size := 6;          // TLabel: waechst mit ApplyScale
    FSlotGlobal[S].Font.Color := $0050A0E0;
    FSlotGlobal[S].Transparent := True;
    FSlotGlobal[S].Caption := Tr('global: letzte Note');
    FSlotGlobal[S].Hint := Tr('Dieses Ziel gibt es nur einmal für den ganzen Klang. Eine Noten-Quelle ' +
      '(Velocity, Noten-LFO ...) wirkt hier global und folgt der zuletzt angeschlagenen Note.');
    FSlotGlobal[S].ShowHint := True;
    FSlotGlobal[S].Visible := False;
  end;
  // Portamento unter der Matrix (Tonhoehen-Bewegung zwischen den Noten)
  // in den Spalten der Matrix: Beschriftung unter "Quelle", Modus unter "Ziel", Zeit unter "Menge" (Tooltip)
  Y := 44 + MAT_ROWS * 34 + 6;
  L := TLabel.Create(Self);
  L.Parent := Right;
  L.SetBounds(28 + MX, Y + 5, 100, 16);
  L.Caption := Tr('Glide');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  K := AddParam(Right, Ord(gpGlideMode), 130 + MX, Y, 0, 0, 128);
  FBindings[K].Combo.Hint := Tr('Glide (Portamento): Aus / Immer / Nur legato');
  FBindings[K].Combo.ShowHint := True;
  K := AddParam(Right, Ord(gpGlideTime), 262 + MX, Y, 0, 46, 0, '', 108);
  FBindings[K].Track.Hint := Tr('Glide-Zeit: Dauer des Gleitens von Ton zu Ton');
  FBindings[K].Track.ShowHint := True;
  L := TLabel.Create(Self);
  L.Parent := Right;
  L.SetBounds(10, 44 + MAT_ROWS * 34 + 40, 600, 60);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Wirkwert = Grundwert + (Quelle x Faktor + Offset) x Menge, im Reglerbereich (Zeiten ' +
    'logarithmisch). LFOs bipolar, übrige Quellen 0..1. Roter Strich unter einem Regler = ' +
    'aktueller Wirkwert. Tonhöhe folgen: SC-Tonhöhe -> Pitch, Faktor x2,65 Ton, Offset ' +
    '-125 %, Menge 100 % (C4 = Originalhöhe).');
  AddStretch(L, 10);
end;

{ --- Reiter Filter: Filter 1 und 2 wirken je Note (jede Stimme hat eigene Filter und Huellkurve) --- }

procedure TGranularEditor.BuildFilterTab;
const
  FLT: array[0..5] of TGranularParamId = (gpFltOn, gpFltType, gpFltCutoff, gpFltReso, gpFltContour, gpFltEnvAmt);
  FENV: array[0..3] of TGranularParamId = (gpFltAttack, gpFltDecay, gpFltSustain, gpFltRelease);
  FLT2: array[0..6] of TGranularParamId =
    (gpFlt2On, gpFltRouting, gpFlt2Type, gpFlt2Cutoff, gpFlt2Reso, gpFlt2Contour, gpFlt2EnvAmt);
  FLT2_CAP: array[0..6] of string = ('Filter 2 an', 'Parallel (aus = Reihe)', 'Typ', 'Cutoff', 'Resonanz', 'Kontur', 'Hüllkurve');
var
  Area, PF, F2, PInfo, RightA, TopA, PResp: TPanel;
  I: Integer;
  L: TLabel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabFlt;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  // Filter 1 | Filter 2 | Erklaerung
  PF := MakePanel(Area, alLeft, Tr('Filter 1'));
  PF.Width := 360;
  // rechts: oben Filter 2 und Erklaerung, darunter der Frequenzgang ueber die ganze Breite
  RightA := TPanel.Create(Self);
  RightA.Parent := Area;
  RightA.Align := alClient;
  RightA.BevelOuter := bvNone;
  RightA.ParentBackground := False;
  RightA.Color := AREA_BG;
  TopA := TPanel.Create(Self);
  TopA.Parent := RightA;
  TopA.Align := alTop;
  TopA.Height := 24 + 7 * ROW_H + 16;
  TopA.BevelOuter := bvNone;
  TopA.ParentBackground := False;
  TopA.Color := AREA_BG;
  F2 := MakePanel(TopA, alLeft, Tr('Filter 2'));
  F2.Width := 360;
  PInfo := MakePanel(TopA, alClient, Tr('So wirken die Filter'));
  PResp := MakePanel(RightA, alClient, Tr('Frequenzgang der Filter (rot = was die Filter wegschneiden)'));
  FFltView := TFilterView.Create(Self, FEngine);
  FFltView.Parent := PResp;
  FFltView.AlignWithMargins := True;
  FFltView.Margins.SetBounds(8, 26, 8, 14);   // unten Platz fuer die Schrauben
  FFltView.Align := alClient;
  FFltView.Hint := Tr('Türkis = Filter 1, orange = Filter 2, hell = Ergebnis (Reihe: nacheinander, parallel: gemischt). ' +
    'Der Cutoff wandert mit der Filter-Hüllkurve. Unten das Spektrum vor (blass) und nach den Filtern, rot = weggeschnitten.');
  FFltView.ShowHint := True;

  for I := 0 to High(FLT) do
    AddParam(PF, Ord(FLT[I]), 8, 24 + I * ROW_H, 100, 70, 130);
  L := TLabel.Create(Self);
  L.Parent := PF;
  L.SetBounds(8, 24 + 6 * ROW_H + 6, 300, 16);
  L.Caption := Tr('Filter-Hüllkurve (startet mit jeder Note)');
  L.Font.Color := COL_VAL;
  L.Transparent := True;
  FFltEnvView := TEnvelopeView.Create(Self, FEngine);
  SetupEnvView(FFltEnvView);
  FFltEnvView.FilterEnv := True;
  FFltEnvView.Parent := PF;
  FFltEnvView.SetBounds(8, 24 + 7 * ROW_H, 100, 76);
  AddStretch(FFltEnvView, 8);
  for I := 0 to High(FENV) do
    AddParam(PF, Ord(FENV[I]), 8, 24 + 7 * ROW_H + 82 + I * ROW_H, 100, 70);

  // gleiches Raster wie Filter 1: Haken oben, darunter Typ und Regler
  AddParam(F2, Ord(gpFlt2On), 8, 24, 100, 0, 0, Tr('Filter 2 an'));
  AddParam(F2, Ord(gpFltRouting), 8, 24 + 6 * ROW_H, 100, 0, 0, Tr('Parallel statt Reihe'));
  for I := 2 to High(FLT2) do
    AddParam(F2, Ord(FLT2[I]), 8, 24 + (I - 1) * ROW_H, 100, 70, 130, FLT2_CAP[I]);

  L := TLabel.Create(Self);
  L.Parent := PInfo;
  L.SetBounds(8, 26, 290, 24 + 7 * ROW_H - 14);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Beide Filter wirken je Note: jede Stimme hat ihre eigenen Filter und ihre eigene Filter-Hüllkurve. ' +
    'Kontur = wie stark der Filter wirkt (trocken <-> gefiltert). Die Filter-Hüllkurve verschiebt den Cutoff um ' +
    'bis zu +-6 Oktaven; Filter 2 folgt ihr mit eigener Menge.') + sLineBreak + sLineBreak +
    Tr('In Reihe: Filter 1 -> Filter 2 (z.B. Hochpass + Tiefpass = Bandbreite). Parallel: beide Filter ' +
    'bekommen das Signal, ihre Ausgänge werden gemischt (z.B. zwei Bandpässe = Vokal-Formanten).') + sLineBreak + sLineBreak +
    Tr('Oszillatoren mit eigenem Filter (Reiter Osz) laufen an diesen Filtern vorbei. ' +
    'Alle Regler sind auch Ziele der Modulationsmatrix.');
  AddStretch(L, 10);
end;

procedure TGranularEditor.BuildFxTab;
const
  ECHO: array[0..7] of TGranularParamId =
    (gpEchoOn, gpEchoTime, gpEchoSync, gpEchoFeedback, gpEchoDamp, gpEchoPitch, gpEchoPingPong, gpEchoMix);
  REV: array[0..6] of TGranularParamId =
    (gpRevOn, gpRevSize, gpRevDecay, gpRevDamp, gpRevPreDelay, gpRevWidth, gpRevMix);
  REV_CAP: array[0..6] of string = ('Hall an', 'Größe', 'Zeit', 'Dämpfung', 'Predelay', 'Breite', 'Mix');
var
  Area, PE, PR, PInfo: TPanel;
  I: Integer;
  L: TLabel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabFx;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;

  // Gesamtklang: Echo | Hall (Signalweg) | Erklaerung - gleiche Spaltenbreite wie auf den anderen Reitern
  PE := MakePanel(Area, alLeft, Tr('Echo (Ping-Pong)'));
  PE.Width := 360;
  PR := MakePanel(Area, alLeft, Tr('Hall'));
  PR.Width := 360;
  PR.Left := PE.Left + PE.Width + 1;
  PInfo := MakePanel(Area, alClient, Tr('So wirken Echo und Hall'));

  for I := 0 to High(ECHO) do
    AddParam(PE, Ord(ECHO[I]), 8, 24 + I * ROW_H, 92, 62);
  for I := 0 to High(REV) do
    AddParam(PR, Ord(REV[I]), 8, 24 + I * ROW_H, 100, 62, 150, REV_CAP[I]);
  AddParam(PR, Ord(gpRevRoom), 8, 24 + 7 * ROW_H, 100, 0, 140, Tr('Raum'));
  AddParam(PR, Ord(gpRevLowCut), 8, 24 + 8 * ROW_H, 100, 62, 150, Tr('Bass-Schnitt'));
  AddParam(PR, Ord(gpRevHighCut), 8, 24 + 9 * ROW_H, 100, 62, 150, Tr('Höhen-Schnitt'));
  L := TLabel.Create(Self);
  L.Parent := PInfo;
  L.SetBounds(8, 24, 290, 330);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Echo und Hall wirken auf den Gesamtklang (alle Noten zusammen). Echo-Zeit mit Sync = Notenwert zum Tempo. ' +
    'Echo Pitch transponiert jede Wiederholung um den eingestellten Wert (+5 = jede ' +
    'Wiederholung eine Quarte höher). Alle Regler sind auch Ziele der Modulationsmatrix.') + sLineBreak + sLineBreak +
    Tr('Größe = Raumgröße, Zeit = Nachhallzeit, Dämpfung = wie schnell die Höhen verklingen, Raum = Wandmaterial. ' +
    'Bass-/Höhen-Schnitt filtern nur den Hall (der trockene Klang bleibt): Bass-Schnitt hoch = kein Dröhnen.');
  AddStretch(L, 10);
end;

{ --- Reiter "Schnell": Makros, Variieren, Undo, A/B, Qualitaet --- }

{ --- Variieren mit Stil --- }

procedure TGranularEditor.ApplyVaryStyle(Style: Integer);

  // Wert zufaellig im Klartext-Bereich [Lo, Hi]
  procedure R(Id: TGranularParamId; Lo, Hi: Double);
  begin
    FEngine.SetParamById(Id, PlainToParam(Id, Lo + (Hi - Lo) * Random));
  end;

  procedure Fix(Id: TGranularParamId; Plain: Double);
  begin
    FEngine.SetParamById(Id, PlainToParam(Id, Plain));
  end;

var
  Env, Grains, Fx: Boolean;
begin
  if Style <= 0 then
    Exit;
  Env := FVaryChecks[vsEnvelope].Checked;
  Grains := FVaryChecks[vsGrains].Checked;
  Fx := FVaryChecks[vsEffects].Checked;
  case Style of
    1: begin   // Pad / Flaeche: weich, lang, breit, mit Raum
         if Env then begin R(gpAttack, 250, 1500); R(gpSustain, 80, 100); R(gpRelease, 1500, 5000); end;
         if Grains then begin R(gpGrainSize, 120, 400); R(gpDensity, 15, 60); R(gpSpread, 50, 100); end;
         if Fx then begin Fix(gpRevOn, 1); R(gpRevMix, 25, 50); R(gpRevDecay, 3, 9); end;
       end;
    2: begin   // Pluck / Zupf: kurzer Anschlag, schnelles Abklingen
         if Env then begin R(gpAttack, 1, 8); R(gpDecay, 150, 600); R(gpSustain, 0, 25); R(gpRelease, 200, 800); end;
         if Grains then begin R(gpGrainSize, 30, 120); R(gpDensity, 40, 120); end;
         if Fx then begin Fix(gpRevOn, 1); R(gpRevMix, 10, 30); R(gpRevDecay, 0.8, 2.5); end;
       end;
    3: begin   // Textur / Wolke: viele kleine Grains, verstreut
         if Grains then
         begin
           R(gpGrainSize, 10, 60); R(gpDensity, 80, 250); R(gpSpray, 20, 80); R(gpScan, 0, 0.3);
           R(gpSpread, 60, 100); R(gpPitchRand, 0, 3);
         end;
         if Env then begin R(gpAttack, 50, 600); R(gpRelease, 800, 3000); end;
       end;
    4: begin   // Rhythmisch: knackig, Echo im Takt
         if Env then begin R(gpAttack, 1, 5); R(gpSustain, 30, 80); R(gpRelease, 80, 400); end;
         if Grains then begin R(gpGrainSize, 40, 120); R(gpDensity, 20, 70); end;
         if Fx then
         begin
           Fix(gpEchoOn, 1); Fix(gpEchoSync, 1);
           FEngine.SetParamById(gpEchoTime, (LFO_DIV_COUNT - 1 - (6 + Random(3))) / (LFO_DIV_COUNT - 1));
           R(gpEchoFeedback, 25, 60); R(gpEchoMix, 20, 45);
         end;
       end;
    5: begin   // Bass: tief, schmal, gefiltert
         if Grains then begin R(gpGrainSize, 60, 200); R(gpDensity, 30, 90); R(gpSpread, 0, 20); end;
         Fix(gpPitch, -12);
         if Fx then
         begin
           Fix(gpFltOn, 1); Fix(gpFltType, 0); R(gpFltCutoff, 200, 900); R(gpFltReso, 20, 60);
           R(gpDrive, 20, 60); Fix(gpRevOn, 0);
         end;
       end;
  end;
end;

{ --- Reiter Extras: Arpeggiator, Harmonie, Halten, Morph (Spielhilfen) --- }

procedure TGranularEditor.BuildExtraTab;
const
  ARP: array[0..6] of TGranularParamId = (gpArpOn, gpArpMode, gpArpOct, gpArpRate, gpArpGate, gpArpSwing, gpArpSteps);
  ARP_CAP: array[0..6] of string = ('Arp an', 'Richtung', 'Oktaven', 'Notenwert', 'Länge', 'Swing', 'Schritte');
var
  Area, PA, PH, PK, PM: TPanel;
  B: TButton;
  I: Integer;
  L: TLabel;

  function Hint(AParent: TWinControl; Y, H: Integer; const Text: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(8, Y, 300, H);
    Result.AutoSize := False;
    Result.WordWrap := True;
    Result.Font.Color := $00A0A0A0;
    Result.Transparent := True;
    Result.Caption := Text;
    AddStretch(Result, 10);
  end;

  function Btn(AParent: TWinControl; Y: Integer; const Cap: string; Click: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(8, Y, 250, 27);
    Result.Caption := Cap;
    Result.OnClick := Click;
    Result.TabStop := False;
  end;

begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabExtra;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;

  // Spalten: Arpeggiator | Harmonie + Klangfarbe | Morph
  PA := MakePanel(Area, alLeft, Tr('Arpeggiator'));
  PA.Width := 340;
  PH := MakePanel(Area, alLeft, Tr('Harmonie'));
  PH.Width := 320;
  PH.Left := PA.Left + PA.Width + 1;
  PM := MakePanel(Area, alClient, Tr('Morph (A -> B)'));
  // oben verankert direkt unter der Harmonie-Erklaerung (nicht unten: sonst wandert der Block mit der Fensterhoehe)
  PK := MakePanel(PH, alNone, Tr('Halten'));
  PK.SetBounds(0, 24 + 3 * ROW_H + 6 + 90 + 64, PH.Width, 110);
  AddStretch(PK, 0);      // eigene Breitenanpassung statt Anchors (beim Skalieren zuverlaessig)

  for I := 0 to High(ARP) do
    AddParam(PA, Ord(ARP[I]), 8, 24 + I * ROW_H, 90, 52, 140, ARP_CAP[I]);
  // Latch (wie microKORG): losgelassene Tasten spielen weiter, bis neue Tasten kommen
  I := AddParam(PA, Ord(gpArpLatch), 190, 24, 0, 0, 0, Tr('Latch'));
  FBindings[I].Check.Hint := Tr('Latch: losgelassene Tasten spielen weiter, bis neue Tasten angeschlagen werden');
  FBindings[I].Check.ShowHint := True;
  L := TLabel.Create(Self);
  L.Parent := PA;
  L.SetBounds(8, 24 + 7 * ROW_H + 6, 300, 16);
  L.Caption := Tr('Schrittmuster (Klick = Schritt an/aus)');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  FArpPattern := TArpPatternView.Create(Self, FEngine);
  FArpPattern.Parent := PA;
  FArpPattern.SetBounds(8, 24 + 7 * ROW_H + 24, 300, 30);
  AddStretch(FArpPattern, 8);
  Hint(PA, 24 + 7 * ROW_H + 60, 94,
    Tr('Gehaltene Tasten werden nacheinander gespielt, im Tempo des Hosts; auch eine einzelne ' +
    'Taste läuft über die Oktaven. Schritte im Muster ausschalten = Pause an dieser Stelle ' +
    '(wie beim microKorg). Akkord = alle Tasten gleichzeitig im Rhythmus des Musters. ' +
    'Tonleiter (rechts) gilt auch für den Arp.'));
  // Muster als MIDI-Datei in die DAW ziehen (Klick ohne Ziehen = speichern)
  FArpMidiBars := TComboBox.Create(Self);
  FArpMidiBars.Parent := PA;
  FArpMidiBars.Style := csDropDownList;
  FArpMidiBars.SetBounds(8, 24 + 7 * ROW_H + 159, 90, 21);
  FArpMidiBars.TabStop := False;
  for I := 0 to High(ARP_MIDI_BARS) do
    if ARP_MIDI_BARS[I] = 1 then
      FArpMidiBars.Items.Add(Tr('1 Takt'))
    else
      FArpMidiBars.Items.Add(Format(Tr('%d Takte'), [ARP_MIDI_BARS[I]]));
  FArpMidiBars.ItemIndex := 2;
  EnableComboFit(FArpMidiBars);
  B := TButton.Create(Self);
  B.Parent := PA;
  B.SetBounds(106, 24 + 7 * ROW_H + 156, 222, 27);
  B.Caption := Tr('MIDI hier greifen und ziehen');
  B.Icon := eiKeys;
  B.TabStop := False;
  B.Cursor := crDrag;
  B.Hint := Tr('Das Arp-Muster mit dem zuletzt gespielten Akkord als MIDI-Datei in eine Spur ' +
    'der DAW ziehen. Klick ohne Ziehen = Datei speichern.');
  B.ShowHint := True;
  B.OnMouseDown := ArpMidiMouseDown;

  AddParam(PH, Ord(gpScale), 8, 24, 90, 0, 180);
  AddParam(PH, Ord(gpScaleRoot), 8, 24 + ROW_H, 90, 0, 80);
  AddParam(PH, Ord(gpScaleKeys), 100, 24 + 2 * ROW_H, 0, 0, 0, Tr('Weiße Tasten = Tonleiter'));
  Hint(PH, 24 + 3 * ROW_H + 6, 84,
    Tr('Tonleiter: jeder Ton (Keyboard, DAW, Arp, Zufall, LFO) rastet bei Grains und Oszillatoren auf die ' +
    'Tonleiter ein. Weiße Tasten = Tonleiter: die weißen Tasten spielen der Reihe nach die Töne der Tonleiter ' +
    '(C4 = Grundton), die schwarzen schweigen.'));

  // Sprache der Oberflaeche: "Deutsch" + jede Datei in Sprachen\ (Beschriftung bewusst zweisprachig)
  L := TLabel.Create(Self);
  L.Parent := PH;
  L.SetBounds(8, 24 + 3 * ROW_H + 6 + 90, 120, 16);
  L.Caption := 'Sprache / Language';
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  EnsureLangList;
  FLangCombo := TComboBox.Create(Self);
  FLangCombo.Parent := PH;
  FLangCombo.Style := csDropDownList;
  FLangCombo.SetBounds(130, 24 + 3 * ROW_H + 6 + 86, 150, 21);
  FLangCombo.TabStop := False;
  FLangCombo.Items.Assign(FLangNames);
  FLangCombo.ItemIndex := Max(0, FLangCodes.IndexOf(LangCode));
  FLangCombo.OnChange := LangComboChange;
  // Fenstergroesse (fuer grosse/hochaufloesende Bildschirme): Wechsel baut den Editor neu auf
  L := TLabel.Create(Self);
  L.Parent := PH;
  L.SetBounds(8, 24 + 3 * ROW_H + 6 + 120, 120, 16);
  L.Caption := Tr('Fenstergröße');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  FScaleCombo := TComboBox.Create(Self);
  FScaleCombo.Parent := PH;
  FScaleCombo.Style := csDropDownList;
  FScaleCombo.SetBounds(130, 24 + 3 * ROW_H + 6 + 116, 150, 21);
  FScaleCombo.TabStop := False;
  for I := 0 to High(UI_SCALES) do
  begin
    FScaleCombo.Items.Add(Format('%d %%', [UI_SCALES[I]]));
    if UI_SCALES[I] = UiScaleLoad then
      FScaleCombo.ItemIndex := I;
  end;
  if FScaleCombo.ItemIndex < 0 then
    FScaleCombo.ItemIndex := 0;
  FScaleCombo.Hint := Tr('Größe des Plugin-Fensters - für große oder hochauflösende Bildschirme. ' +
    'Gilt für alle Instanzen und wird gemerkt.');
  FScaleCombo.ShowHint := True;
  EnableComboFit(FScaleCombo);
  FScaleCombo.OnChange := ScaleComboChange;

  AddParam(PK, Ord(gpFreeze), 8, 24, 90, 0);
  Hint(PK, 24 + ROW_H + 2, 50,
    Tr('Freeze: die Leseposition steht still, der Klang friert ein; mit Hall klingt er lange aus. ' +
    'Sättigung, Breite und Panorama: Reiter Summe.'));

  AddParam(PM, Ord(gpMorph), 8, 24, 70, 52);
  // eigener Morph-LFO (unabhaengig von beiden Klaengen)
  AddParam(PM, Ord(gpMorphLfoShape), 8, 24 + ROW_H, 70, 0, 120, Tr('Morph-LFO'));
  AddParam(PM, Ord(gpMorphLfoSync), 210, 24 + ROW_H, 0, 0, 0, Tr('Sync'));
  AddParam(PM, Ord(gpMorphLfoRate), 8, 24 + 2 * ROW_H, 70, 52, 0, Tr('Rate'));
  AddParam(PM, Ord(gpMorphLfoDepth), 8, 24 + 3 * ROW_H, 70, 52, 0, Tr('Tiefe'));
  B := Btn(PM, 24 + 4 * ROW_H + 6, Tr('Jetzigen Klang als Ziel B merken'), MorphStoreClick);
  B.Width := 200;
  B.Icon := eiBookmark;
  B := Btn(PM, 24 + 4 * ROW_H + 6, Tr('Ziel B löschen'), MorphClearClick);
  B.Icon := eiTrash;
  B.Left := 214;
  B.Width := 100;
  // Bearbeitungstausch: B nach vorn holen, bearbeiten, zuruecktauschen (Klang bleibt gleich)
  B := Btn(PM, 24 + 4 * ROW_H + 6, Tr('A <-> B tauschen'), MorphSwapClick);
  B.Icon := eiSwap;
  B.Left := 320;
  B.Width := 120;
  B.Hint := Tr('A und B tauschen die Plätze (Regler, Matrix, LFO-Formen, Arp-Muster, EQ, Sample). ' +
    'Morph wird gespiegelt, der Klang bleibt gleich - die Regler zeigen jetzt den anderen Klang. ' +
    'Nochmal klicken = zurück.');
  B.ShowHint := True;
  B := Btn(PM, 24 + 4 * ROW_H + 38, Tr('Preset als Ziel B laden ...'), MorphLoadClick);
  B.Icon := eiOpen;
  B.Width := 200;
  B := Btn(PM, 24 + 4 * ROW_H + 38, Tr('Frei zeichnen ...'), MorphFreeClick);
  B.Icon := eiPencil;
  B.Left := 214;
  B.Width := 120;
  FMorphLabel := TLabel.Create(Self);
  FMorphLabel.Parent := PM;
  FMorphLabel.SetBounds(8, 24 + 4 * ROW_H + 72, 200, 16);
  // Morph-Art: an = A und B zwei vollstaendig getrennte Klaenge, aus = Werte stufenlos ueberblenden
  AddParam(PM, Ord(gpMorphMode), 210, 24 + 4 * ROW_H + 66, 0, 0, 0, Tr('Zwei Klänge'));
  FMorphLabel.Font.Color := COL_VAL;
  FMorphLabel.Transparent := True;
  // Anzeige des Morph-LFOs (Klick = freie Form bearbeiten)
  FMorphLfoView := TLfoView.Create(Self, FEngine);
  FMorphLfoView.Lfo := LFO_COUNT;   // = Morph-LFO
  FMorphLfoView.Parent := PM;
  FMorphLfoView.SetBounds(8, 24 + 4 * ROW_H + 92, 300, 36);
  FMorphLfoView.Hint := Tr('Morph-LFO (Klick: freie Form zeichnen)');
  FMorphLfoView.ShowHint := True;
  FMorphLfoView.Cursor := crHandPoint;
  TControlAccess(FMorphLfoView).OnClick := MorphFreeClick;
  AddStretch(FMorphLfoView, 8);
  // Schwellen-Tor: universeller Schalter/Trigger
  L := TLabel.Create(Self);
  L.Parent := PM;
  L.SetBounds(8, 24 + 4 * ROW_H + 134, 300, 16);
  L.Caption := Tr('Schwellen-Tor');
  L.Font.Color := COL_VAL;
  L.Font.Style := [fsBold];
  L.Transparent := True;
  AddParam(PM, Ord(gpGateSrc), 8, 24 + 4 * ROW_H + 152, 70, 0, 130, Tr('Quelle'));
  AddParam(PM, Ord(gpGateThresh), 8, 24 + 5 * ROW_H + 152, 70, 52, 0, Tr('Schwelle'));
  AddParam(PM, Ord(gpGateQuiet), 8, 24 + 6 * ROW_H + 152, 70, 52, 0, Tr('Ruhe-Dauer'));
  Hint(PM, 24 + 7 * ROW_H + 152, 64,
    Tr('Schwellen-Tor = 1, sobald die Quelle über der Schwelle liegt: als ' +
    'Matrix-Quelle schaltet es Ein/Aus-Regler, als LFO-Trigger startet es einen LFO. Trigger "Ruhe": startet den LFO, wenn die Quelle die ' +
    'Ruhe-Dauer lang unter der Schwelle blieb (Pause, Stille).'));
  UpdateMorphLabel;
end;

procedure TGranularEditor.UpdateMorphLabel;
begin
  if FMorphLabel = nil then
    Exit;
  if FEngine.MorphValid and FEngine.MorphSwapped then
    FMorphLabel.Caption := Tr('Getauscht: du bearbeitest B')
  else if FEngine.MorphValid and (FEngine.MorphSampleLoaded <> '') then
    FMorphLabel.Caption := Tr('Ziel B: ') + ChangeFileExt(ExtractFileName(FEngine.MorphSampleLoaded), '')
  else if FEngine.MorphValid then
    FMorphLabel.Caption := Tr('Ziel B gesetzt (gleiches Sample)')
  else
    FMorphLabel.Caption := Tr('Noch kein Ziel B');
end;

procedure TGranularEditor.MorphSwapClick(Sender: TObject);
begin
  if not FEngine.SwapMorphAB then
  begin
    MessageDlg(Tr('Erst ein Ziel B merken oder laden - dann lassen sich A und B tauschen.'), mtInformation, [mbOK], 0);
    Exit;
  end;
  // Pfad von B fuers Speichern: das bisherige A-Sample (oder keins = gleiches Sample)
  if FEngine.MorphSampleLoaded <> '' then
    FEngine.MorphSampleRef := MakePortablePath(FEngine.MorphSampleLoaded, FBaseDir);
  SyncSampleFromEngine;     // Wellenansicht + alle Regler
  UpdateMorphLabel;
end;

procedure TGranularEditor.MorphStoreClick(Sender: TObject);
begin
  FEngine.StoreMorphTarget;
  // Ziel B bekommt das jetzige Sample mit
  FEngine.MorphSampleRef := MakePortablePath(FEngine.SamplePath, FBaseDir);
  if FEngine.SamplePath <> '' then
    LoadMorphSample(FEngine, FBaseDir)
  else
    FEngine.SetMorphSample(CreateDemoSample(44100), '');
  UpdateMorphLabel;
end;

procedure TGranularEditor.MorphLoadClick(Sender: TObject);
var
  Dlg: TOpenDialog;
  Tmp: TGranularEngine;
  Path: string;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Filter := 'Granular-Presets (*.gspreset)|*.gspreset';
    if FBaseDir <> '' then
      Dlg.InitialDir := IncludeTrailingPathDelimiter(FBaseDir) + 'Presets';
    if not Dlg.Execute then
      Exit;
    Tmp := TGranularEngine.Create;
    try
      if not LoadChunkFromFile(Tmp, Dlg.FileName, Path) then
        raise Exception.Create(Tr('Keine gültige Preset-Datei: ') + Dlg.FileName);
      FEngine.SetMorphFromEngine(Tmp);   // vollstaendig: Matrix, freie LFOs, Arp-Muster, EQ
      // Sample des geladenen Presets wird das Sample von Ziel B
      FEngine.MorphSampleRef := Path;
      LoadMorphSample(FEngine, FBaseDir);
    finally
      Tmp.Free;
    end;
  finally
    Dlg.Free;
  end;
  UpdateMorphLabel;
end;

procedure TGranularEditor.MorphFreeClick(Sender: TObject);
begin
  OpenFreeEditor(2);
end;

procedure TGranularEditor.MorphClearClick(Sender: TObject);
begin
  FEngine.ClearMorphTarget;
  UpdateMorphLabel;
end;

{ Rhythmus-Gate: Frei-LFO als 16-Stufen-Muster auf die Lautstaerke }
procedure TGranularEditor.FreeGateClick(Sender: TObject);
const
  PATTERN: array[0..15] of Single = (0, -1, 0, -1, 0, 0, -1, 0, 0, -1, 0, -1, 0, 0, 0, -1);
var
  K, LK, S, Slot, Src, Dst, F1, I: Integer;
  F: PFreeLfo;
begin
  K := (Sender as TComponent).Tag;
  PushUndo;
  F := FEngine.FreeLfo[K];
  F.Mode := 1;
  F.Steps := 16;
  for I := 0 to 15 do
    F.Step[I] := PATTERN[I];
  LK := LfoOfFree(K);
  FEngine.SetParam(Ord(LFO_SHAPE_IDS[LK]), StepToParam(Ord(LFO_SHAPE_IDS[LK]), LFO_SHAPE_FREE));
  FEngine.SetParam(Ord(LFO_SYNC_IDS[LK]), 1);
  FEngine.SetParam(Ord(LFO_RATE_IDS[LK]), 2 / (LFO_DIV_COUNT - 1));   // ein Takt je Durchlauf -> 16tel-Gate
  FEngine.SetParam(Ord(LFO_TRIG_IDS[LK]), StepToParam(Ord(LFO_TRIG_IDS[LK]), 0));
  Src := Ord(LFO_SRC[LK]);
  Dst := Ord(gpVolume) + 1;
  Slot := SlotFor(Src, Dst);
  if Slot < 0 then
    Slot := MOD_SLOTS - 1;
  F1 := 0;
  for S := 0 to MOD_FACTOR_COUNT - 1 do
    if MOD_FACTORS[S] = 1 then
      F1 := S;
  SetSlot(Slot, Src, Dst, 100, F1);
  UpdateFromEngine;
end;

procedure TGranularEditor.ShowInfo;
begin
  InfoClick(nil);
end;

procedure TGranularEditor.SetBindingEnabled(Idx: Integer; Value: Boolean);
var
  C: TColor;
begin
  if (Idx < 0) or (Idx > High(FBindings)) then
    Exit;
  if Value then C := COL_NAME else C := $00606060;
  with FBindings[Idx] do
  begin
    if Track <> nil then Track.Enabled := Value;
    if Check <> nil then Check.Enabled := Value;
    if Combo <> nil then Combo.Enabled := Value;
    if NameLabel <> nil then NameLabel.Font.Color := C;
    if ValueLabel <> nil then ValueLabel.Visible := Value;
  end;
end;

procedure TGranularEditor.EnsureLangList;
begin
  if FLangCodes <> nil then
    Exit;
  FLangCodes := TStringList.Create;
  FLangNames := TStringList.Create;
  LangList(FLangCodes, FLangNames);
end;

procedure TGranularEditor.ScaleComboChange(Sender: TObject);
begin
  if FScaleCombo.ItemIndex < 0 then
    Exit;
  UiScaleSave(UI_SCALES[FScaleCombo.ItemIndex]);
  // wie beim Sprachwechsel: die Plugin-Huelle baut den Editor in der neuen Groesse auf
  if Assigned(FOnLanguageChange) then
    FOnLanguageChange(Self);
end;

procedure TGranularEditor.LangComboChange(Sender: TObject);
begin
  if (FLangCombo.ItemIndex >= 0) and (FLangCombo.ItemIndex < FLangCodes.Count) then
    SwitchLanguage(FLangCodes[FLangCombo.ItemIndex]);
end;

procedure TGranularEditor.LangFlagClick(Sender: TObject);
begin
  if FLangCodes.Count > 1 then
    SwitchLanguage(FLangCodes[(Max(0, FLangCodes.IndexOf(LangCode)) + 1) mod FLangCodes.Count]);
end;

{ Flagge der aktuellen Sprache: Sprachen\<Kuerzel>.png, falls vorhanden (jede neue Sprache kann ihre
  eigene mitbringen); sonst eingebaut fuer Deutsch und Englisch; sonst das Kuerzel auf grauem Grund }
function Muted(Col: TColor): TColor;
const
  BG = $00302C2A;   // ungefaehr der Hintergrund der Reiterzeile
  K = 0.55;         // Anteil der Flaggenfarbe
begin
  Col := ColorToRGB(Col);
  Result := RGB(Round(GetRValue(Col) * K + GetRValue(BG) * (1 - K)),
                Round(GetGValue(Col) * K + GetGValue(BG) * (1 - K)),
                Round(GetBValue(Col) * K + GetBValue(BG) * (1 - K)));
end;

procedure TGranularEditor.LangFlagPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, I: Integer;
  F: string;
  Png: TPngImage;
begin
  C := FLangFlag.Canvas;
  W := FLangFlag.Width;
  H := FLangFlag.Height;
  F := IncludeTrailingPathDelimiter(FBaseDir) + LANG_DIR + PathDelim + LangCode + '.png';
  if (FBaseDir <> '') and FileExists(F) then
  begin
    Png := TPngImage.Create;
    try
      try
        Png.LoadFromFile(F);
        C.StretchDraw(Rect(0, 0, W, H), Png);
        Exit;
      except
      end;
    finally
      Png.Free;
    end;
  end;
  C.Pen.Style := psClear;
  if LangCode = 'de' then
  begin
    for I := 0 to 2 do
    begin
      case I of
        0: C.Brush.Color := Muted(clBlack);
        1: C.Brush.Color := Muted($000000DD);     // Rot (BGR)
      else
        C.Brush.Color := Muted($0000CEFF);        // Gold
      end;
      C.FillRect(Rect(0, I * H div 3, W, (I + 1) * H div 3));
    end;
  end
  else if LangCode = 'en' then
  begin
    // Union Jack, vereinfacht: blau, weisse und rote Diagonalen, weisses und rotes Kreuz
    C.Brush.Color := Muted($007D2401);
    C.FillRect(Rect(0, 0, W, H));
    C.Pen.Style := psSolid;
    C.Pen.Color := Muted(clWhite);
    AALineCv(C, 0, 0, W - 1, H - 1, Muted(clWhite), 3);
    AALineCv(C, W - 1, 0, 0, H - 1, Muted(clWhite), 3);
    AALineCv(C, 0, 0, W - 1, H - 1, Muted($002E10C8));
    AALineCv(C, W - 1, 0, 0, H - 1, Muted($002E10C8));
    C.Pen.Style := psClear;
    C.Brush.Color := Muted(clWhite);
    C.FillRect(Rect(W div 2 - 2, 0, W div 2 + 2, H));
    C.FillRect(Rect(0, H div 2 - 2, W, H div 2 + 2));
    C.Brush.Color := Muted($002E10C8);
    C.FillRect(Rect(W div 2 - 1, 0, W div 2 + 1, H));
    C.FillRect(Rect(0, H div 2 - 1, W, H div 2 + 1));
  end
  else
  begin
    C.Brush.Color := $00606060;
    C.FillRect(Rect(0, 0, W, H));
    C.Font.Color := clWhite;
    C.Font.Style := [fsBold];
    C.Font.Size := UiPt(6);
    C.Brush.Style := bsClear;
    C.TextOut((W - C.TextWidth(UpperCase(LangCode))) div 2, (H - C.TextHeight('X')) div 2, UpperCase(LangCode));
    C.Brush.Style := bsSolid;
  end;
  // feiner Rahmen
  C.Pen.Style := psSolid;
  C.Pen.Width := 1;
  C.Pen.Color := $00404040;
  C.Brush.Style := bsClear;
  C.Rectangle(0, 0, W, H);
  C.Brush.Style := bsSolid;
end;

{ Update-Symbol: bernsteinfarbener Kreis mit Pfeil nach oben (gedaempft wie die Flagge) }
procedure TGranularEditor.UpdIconPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, Cx: Integer;
begin
  C := FUpdIcon.Canvas;
  W := FUpdIcon.Width;
  H := FUpdIcon.Height;
  C.Brush.Color := BG_MAIN;
  C.FillRect(Rect(0, 0, W, H));
  Granular.Fader.Ellipse0(C.Handle, W div 2, H div 2, Min(W, H) div 2 - 1, $00284C66, $0040A8E0);
  Cx := W div 2;
  C.Pen.Color := $0070D0F8;
  C.Pen.Width := 2;
  C.MoveTo(Cx, H - 4); C.LineTo(Cx, 4);
  AALineCv(C, Cx - 3.5, 7.5, Cx, 4, $0070D0F8, 2);
  AALineCv(C, Cx + 3.5, 7.5, Cx, 4, $0070D0F8, 2);
  C.Pen.Width := 1;
end;

{ Klick: Setup starten (Online-Update), sonst die Release-Seite im Browser }
procedure TGranularEditor.UpdIconClick(Sender: TObject);
var
  Setup: string;
begin
  Setup := UpdateSetupPath;
  if Setup <> '' then
  begin
    if MessageDlg(Format(Tr('Version %s ist verfügbar. Jetzt das Setup starten?'), [FUpdVersion]) + sLineBreak + sLineBreak +
      Tr('Dort aktualisiert der Knopf "Online-Update" alles. Bitte vorher die DAW speichern und schließen.'),
      mtInformation, [mbYes, mbNo], 0) = mrYes then
      ShellExecute(0, 'open', PChar(Setup), '-StartUpdate', nil, SW_SHOWNORMAL);   // Setup fragt gleich nach dem Update
  end
  else
    ShellExecute(0, 'open', PChar(FUpdPage), nil, nil, SW_SHOWNORMAL);
end;

procedure TGranularEditor.SwitchLanguage(const Code: string);
begin
  if Code = LangCode then
    Exit;
  LangSet(Code);
  // neu aufbauen macht die Huelle (Plugin) per Nachricht - der Editor darf sich nicht selbst freigeben
  if Assigned(FOnLanguageChange) then
    FOnLanguageChange(Self)
  else
    MessageDlg('Die neue Sprache gilt beim nächsten Öffnen des Fensters.' + sLineBreak +
      'The new language applies the next time the window is opened.', mtInformation, [mbOK], 0);
end;

destructor TGranularEditor.Destroy;
begin
  FLangCodes.Free;
  FLangNames.Free;
  inherited;
end;

function TGranularEditor.PageIndex: Integer;
begin
  Result := FPages.ActivePageIndex;
end;

procedure TGranularEditor.ShowHelp(Changelog: Boolean);
begin
  ShowHelpWindow(Self, LangHelpFile(FBaseDir), Changelog);
end;

procedure TGranularEditor.HelpClick(Sender: TObject);
begin
  ShowHelpWindow(Self, LangHelpFile(FBaseDir));
end;

procedure TGranularEditor.InfoClick(Sender: TObject);
begin
  if FInfoForm = nil then
    FInfoForm := TInfoForm.CreateInfo(Self, FEngine);
    UiScaleForm(FInfoForm);
  FInfoForm.Refresh(True);
  FInfoForm.Show;
  FInfoForm.BringToFront;
end;

{ --- Reiter LFO 3 / 4 --- }

procedure TGranularEditor.BuildMod2Tab;
var
  Area, P: TPanel;
  K: Integer;
  L: TLabel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabMod2;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  for K in [2, 3, 6, 7] do
    BuildLfoPanel(Area, K, ((K mod 4) - 2) * 187, 356);
  // gleicher Abstand zur linken LFO-Spalte wie zwischen den Reihen (4 px)
  for K in [2, 3, 6, 7] do
    FLfoPanels[K].Left := 4;
  P := MakePanel(Area, alNone, Tr('So arbeiten die LFOs'));
  P.SetBounds(364, 187, 330, 183);
  // Umschalter LFO 1-4 / 5-8 (unter der Erklaerung in der dritten Spalte)
  for K := 0 to 1 do
  begin
    FLfoPageBtn[K] := TButton.Create(Self);
    FLfoPageBtn[K].Parent := P;
    FLfoPageBtn[K].SetBounds(14 + K * 154, 144, 148, 24);   // Ecken frei fuer die Schrauben
    FLfoPageBtn[K].Tag := K;
    FLfoPageBtn[K].TabStop := False;
    FLfoPageBtn[K].OnClick := LfoPageClick;
    FLfoPageBtn[K].Hint := Tr('LFO 1-4 bzw. 5-8 zeigen (in Klammern: benutzte LFOs 5-8)');
    FLfoPageBtn[K].ShowHint := True;
  end;
  L := TLabel.Create(Self);
  L.Parent := P;
  // dritte Spalte: Trigger-Schwellen (so hoch wie die obere LFO-Reihe), darunter die Erklaerung mit dem
  // Umschalter (so hoch wie die untere Reihe) - beide Spalten enden auf einer Linie
  FTrigPanel.Parent := Area;
  FTrigPanel.SetBounds(364, 0, 330, 183);
  L.SetBounds(8, 26, 314, 116);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Alle acht LFOs können dasselbe und sind in der Matrix "LFO 1" bis "LFO 8" (Umschalter unten). "frei" = läuft für alle ' +
    'Noten; "Note an/aus" = eigener LFO je Note. Feld unter "Einmal" = Partner: dessen Einmal-Ende ist ' +
    '"Ende Partner-LFO" (Ketten 1 -> 2 -> 3 möglich). "Stopp" hält den LFO an, bis er wieder startet; ' +
    '"nach Zeit" = nach der Zeit darunter. Klick auf eine Anzeige: freie Form bearbeiten.');
end;

{ --- ein LFO-Feld (LFO 1..8, gleicher Aufbau): Anzeige, Rate, Form, Einmal, Sync, Neustart, Stopp, Zeit, Partner --- }
procedure TGranularEditor.BuildLfoPanel(AParent: TWinControl; K, Y, W: Integer);
var
  P: TPanel;
  I: Integer;
begin
  P := MakePanel(AParent, alNone, Format(Tr('LFO %d'), [K + 1]));
  P.SetBounds(0, Y, W, 183);
  P.Visible := K < 4;
  FLfoPanels[K] := P;
  FLfoViews[K] := TLfoView.Create(Self, FEngine);
  FLfoViews[K].Parent := P;
  FLfoViews[K].Lfo := K;
  FLfoViews[K].SetBounds(8, 24, 110, 52);
  FLfoViews[K].Tag := K;
  FLfoViews[K].Cursor := crHandPoint;
  FLfoViews[K].Hint := Tr('Klick: freie Form bearbeiten (Stufen / Halbtöne / zeichnen)');
  FLfoViews[K].ShowHint := True;
  TControlAccess(FLfoViews[K]).OnClick := LfoViewClick;
  AddParam(P, Ord(LFO_ONCE_IDS[K]), 8, 22 + 2 * ROW_H, 0, 0, 0, Tr('Einmal'));
  AddParam(P, Ord(LFO_RATE_IDS[K]), 124, 22, 40, 56, 0, Tr('Rate'));
  AddParam(P, Ord(LFO_SHAPE_IDS[K]), 124, 22 + ROW_H, 40, 0, 120, Tr('Form'));
  AddParam(P, Ord(LFO_SYNC_IDS[K]), 86, 22 + 2 * ROW_H, 0, 0, 0, Tr('Sync'));
  AddParam(P, Ord(LFO_TRIG_IDS[K]), 164 + COMBO_INSET, 22 + 2 * ROW_H, 0, 0, 166);   // Neustart, buendig unter Form
  AddParam(P, Ord(LFO_STOP_IDS[K]), 124, 22 + 3 * ROW_H, 40, 0, 166, Tr('Stopp'));        // Aus-Trigger
  FStopSyncIdx[K] := AddParam(P, Ord(LFO_STOP_SYNC[K]), 8 + COMBO_INSET, 22 + 4 * ROW_H, 0, 0, 100);
  FStopMsIdx[K] := AddParam(P, Ord(LFO_STOP_MS[K]), 124, 22 + 4 * ROW_H, 40, 66, 0, Tr('Zeit'));
  FPartnerIdx[K] := AddParam(P, Ord(LFO_PARTNER_IDS[K]), 8 + COMBO_INSET, 22 + 3 * ROW_H, 0, 0, 100);
  FBindings[FPartnerIdx[K]].Combo.Hint := Tr('Partner: dessen Einmal-Ende ist das Ereignis "Ende Partner-LFO"');
  FBindings[FPartnerIdx[K]].Combo.ShowHint := True;
  // Inhalt 3 px tiefer: nicht an die Kopfleiste geklatscht (Titel bleibt)
  for I := 0 to P.ControlCount - 1 do
    if P.Controls[I].Top >= 8 then
      P.Controls[I].Top := P.Controls[I].Top + 3;
end;

procedure TGranularEditor.ShowLfoPage(Page: Integer);
var
  K: Integer;
begin
  FLfoPage := EnsureRange(Page, 0, 1);
  for K := 0 to LFO_COUNT - 1 do
    if FLfoPanels[K] <> nil then
      FLfoPanels[K].Visible := K div 4 = FLfoPage;
  UpdateLfoPageCaptions;
end;

procedure TGranularEditor.LfoPageClick(Sender: TObject);
begin
  ShowLfoPage((Sender as TComponent).Tag);
end;

{ "LFO 1-4" / "LFO 5-8 (2 benutzt)": benutzt = von der Matrix, dem Tor oder als Partner gebraucht;
  die sichtbare Seite ist bernsteinfarben }
procedure TGranularEditor.UpdateLfoPageCaptions;
var
  K, N: Integer;
  Cap: string;
begin
  if FLfoPageBtn[0] = nil then
    Exit;
  N := 0;
  for K := 4 to LFO_COUNT - 1 do
    if FEngine.LfoUsed(K) then
      Inc(N);
  for K := 0 to 1 do
  begin
    if K = 0 then Cap := Tr('LFO 1-4') else Cap := Tr('LFO 5-8');
    if (K = 1) and (N > 0) then
      Cap := Cap + Format(Tr(' (%d benutzt)'), [N]);
    FLfoPageBtn[K].Active := K = FLfoPage;
    if FLfoPageBtn[K].Caption <> Cap then
      FLfoPageBtn[K].Caption := Cap;
  end;
end;

{ --- Reiter Timing / Hüllk.: jedes Ereignis, das LFOs neu startet, kann verzoegert wirken --- }

procedure TGranularEditor.BuildTimingTab;
const
  X_MS = 8; NAME_W = 170; TRACK_W = 240; X_SYNC = 8 + 170 + 240 + 90;
  MENV_CAP: array[0..3] of string = ('Attack', 'Decay', 'Sustain', 'Release');
var
  Area, P: TPanel;
  I, Y: Integer;
  L: TLabel;

  procedure Head(X: Integer; const Cap: string);
  begin
    L := TLabel.Create(Self);
    L.Parent := P;
    L.SetBounds(X, 26, 200, 16);
    L.Caption := Cap;
    L.Font.Color := COL_NAME;
    L.Transparent := True;
  end;

begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabTiming;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  P := MakePanel(Area, alLeft, Tr('Ereignis-Verzögerung (LFO-Neustart)'));
  P.Width := X_SYNC + 130;
  Head(X_MS, Tr('Ereignis'));
  Head(X_MS + NAME_W, Tr('Verzögerung frei'));
  Head(X_SYNC, Tr('oder im Takt'));
  for I := 0 to DLY_EVENT_COUNT - 1 do
  begin
    Y := 42 + I * (ROW_H - 3);   // enger: letzte Zeile bleibt im Bereich
    FDlyMsIdx[I] := AddParam(P, Ord(DLY_MS[I]), X_MS, Y, NAME_W, 66, 0, DLY_EVENT_NAMES[I], TRACK_W);
    AddParam(P, Ord(DLY_SYNC[I]), X_SYNC, Y, 0, 0, 110);
  end;
  L := TLabel.Create(Self);
  L.Parent := Area;
  L.SetBounds(P.Width + 16, 30, 460, 260);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Jedes Ereignis, das einen LFO startet oder stoppt (Reiter LFO 1-8 / Trigger), kann hier verzögert wirken: ' +
    'frei in Millisekunden oder im Takt (Notenwert; dann gilt der Notenwert). 0 ms und "Aus" = sofort.') +
    sLineBreak + sLineBreak +
    Tr('Note an bei LFOs je Note: bis die Verzögerung um ist, ruht der LFO dieser Note (keine Modulation) - ' +
    'der Ton beginnt glatt, danach setzt der Effekt ein. Beispiel Geige: LFO 1 Neustart "Note an", ' +
    'nicht Einmal, Sinus 5,5 Hz -> Pitch; hier "Note an" auf 1/2 = das Vibrato beginnt nach einer halben Note, ' +
    'für jede Note einzeln.') + sLineBreak + sLineBreak +
    Tr('Note aus: der LFO läuft bis zum verzögerten Neustart weiter. Alle anderen Ereignisse: der LFO startet ' +
    'nach der Wartezeit neu; ein neues Ereignis in der Wartezeit beginnt sie von vorn. Als Stopp-Ereignis ' +
    'hält es den LFO nach derselben Wartezeit an.');
  AddStretch(L, 10);

  // freie Modulations-Huellkurven (Nov. 2026): unten ueber die ganze Breite, zwei Spalten
  P := MakePanel(Area, alBottom, Tr('Modulations-Hüllkurven (je Note; in der Matrix als Quelle "Mod-Hüllk. 1" und "Mod-Hüllk. 2")'));
  P.Height := 24 + 4 * ROW_H + 6;
  // je Huellkurve: Grafik links (wie bei den Oszillatoren, roter Punkt = juengste Note), Regler rechts daneben
  for I := 0 to MENV_COUNT - 1 do
  begin
    FMEnvView[I] := TEnvelopeView.Create(Self, FEngine);
    SetupEnvView(FMEnvView[I]);
    FMEnvView[I].Kind := ekMod;
    FMEnvView[I].OscIndex := I;
    FMEnvView[I].Title := Tr(MOD_SOURCE_NAMES[MENV_SRC[I]]);
    FMEnvView[I].Parent := P;
    FMEnvView[I].SetBounds(8 + I * 620, 26, 210, 4 * ROW_H - 14);   // unten frei fuer die Schraube
    for Y := 0 to 3 do
      AddParam(P, Ord(MENV_IDS[I, Y]), 228 + I * 620, 24 + Y * ROW_H, 64, 70, 0, Tr(MENV_CAP[Y]), 230);
  end;
end;

{ --- Reiter Oszillator 1..3 (gleicher Aufbau) --- }

procedure TGranularEditor.BuildOscTab(O: Integer);
const
  CAP0: array[0..8] of string = ('Oszillator an', 'Welle', 'Sync (Obertöne)', 'Oktave', 'Feinstimmung', 'Pegel',
    'Panorama', 'FM-Verhältnis', 'FM-Menge');
  OFLT_CAP: array[0..5] of string = ('Filter an', 'Typ', 'Cutoff', 'Resonanz', 'Kontur', 'Hüllkurve');
  ENV_H = 64;
  ENV_Y = 24 + ENV_H + 6;    // Regler unter den Huellkurven-Anzeigen
  UNI: array[0..OSC_COUNT - 1, 0..2] of TGranularParamId = (
    (gpOscUnison, gpOscDetune, gpOscUniWidth), (gpOsc2Unison, gpOsc2Detune, gpOsc2UniWidth),
    (gpOsc3Unison, gpOsc3Detune, gpOsc3UniWidth));
var
  Area, P0, P1, P2: TPanel;
  I: Integer;
  L: TLabel;
  Op: TOscParamIds;
  Col0: array[0..8] of TGranularParamId;
  Col1: array[0..3] of TGranularParamId;
  OFlt: array[0..5] of TGranularParamId;
begin
  Op := OSC_P[O];
  Col0[0] := Op.On_; Col0[1] := Op.Wave; Col0[2] := Op.Sync; Col0[3] := Op.Oct; Col0[4] := Op.Fine;
  Col0[5] := Op.Level; Col0[6] := Op.Pan; Col0[7] := Op.FmRatio; Col0[8] := Op.FmAmt;
  Col1[0] := Op.Attack; Col1[1] := Op.Decay; Col1[2] := Op.Sustain; Col1[3] := Op.Release;
  OFlt[0] := Op.FltOn; OFlt[1] := Op.FltType; OFlt[2] := Op.FltCutoff; OFlt[3] := Op.FltReso;
  OFlt[4] := Op.FltContour; OFlt[5] := Op.FltEnvAmt;

  Area := TPanel.Create(Self);
  Area.Parent := FTabOsc[O];
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  P0 := MakePanel(Area, alLeft, Format(Tr('Oszillator %d (zusätzlich zu den Grains, je Note)'), [O + 1]));
  P0.Width := 480;
  P2 := MakePanel(Area, alRight, Format(Tr('Eigener Filter (nur Oszillator %d)'), [O + 1]));
  P2.Width := 400;
  for I := 0 to High(OFlt) do
    AddParam(P2, Ord(OFlt[I]), 8, 24 + I * ROW_H, 80, 62, 150, OFLT_CAP[I]);
  L := TLabel.Create(Self);
  L.Parent := P2;
  L.SetBounds(8, 24 + 6 * ROW_H + 6, 380, 48);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Eingeschaltet läuft der Oszillator nur durch diesen Filter, an Filter 1/2 vorbei - z.B. Rausch-' +
    'Hats per Hochpass, während die Fläche tief gefiltert bleibt. Echo, Hall und EQ wirken weiter.');

  // Wavetable (Nov. 2026): geladene Datei ersetzt Welle und Zeichnung, Position je Note modulierbar
  L := TLabel.Create(Self);
  L.Parent := P2;
  L.SetBounds(8, 24 + 8 * ROW_H + 8, 200, 16);
  L.Caption := Tr('Wavetable');
  L.Font.Color := COL_VAL;
  L.Font.Style := [fsBold];
  L.Transparent := True;
  AddParam(P2, Ord(Op.WtOn), 80, 24 + 8 * ROW_H + 4, 80, 0, 0, Tr('Wavetable an'));
  with TButton.Create(Self) do
  begin
    Parent := P2;
    SetBounds(270, 24 + 8 * ROW_H + 4, 110, 24);
    Caption := Tr('Laden ...');
    Icon := eiOpen;
    Tag := O;
    TabStop := False;
    OnClick := WtLoadClick;
    Hint := Tr('Wavetable-Datei laden (WAV, z.B. aus Serum oder Vital: 2048 Punkte je Frame, oder ein einzelner ' +
      'Zyklus). Bis zu 32 Frames, jeder bandbegrenzt; "WT-Position" fährt durch die Frames.');
    ShowHint := True;
  end;
  AddParam(P2, Ord(Op.WtPos), 8, 24 + 9 * ROW_H + 4, 80, 62, 0, Tr('Position'));
  FWtName[O] := TLabel.Create(Self);
  FWtName[O].Parent := P2;
  FWtName[O].SetBounds(8, 24 + 10 * ROW_H + 8, 380, 16);
  FWtName[O].Font.Color := $00A0A0A0;
  FWtName[O].Transparent := True;
  FWtName[O].Caption := '';
  P1 := MakePanel(Area, alClient, Format(Tr('Lautstärke-Hüllkurve (Oszillator %d)'), [O + 1]));
  // Anzeige der Oszillator-Huellkurve (roter Punkt = juengste Stimme)
  FOscEnvView[O] := TEnvelopeView.Create(Self, FEngine);
  SetupEnvView(FOscEnvView[O]);
  FOscEnvView[O].Kind := ekOsc;
  FOscEnvView[O].OscIndex := O;
  FOscEnvView[O].Parent := P1;
  FOscEnvView[O].SetBounds(8, 24, 300, ENV_H);
  AddStretch(FOscEnvView[O], 8);
  for I := 0 to High(Col0) do
    if I = 2 then
      FSyncIdx[O] := AddParam(P0, Ord(Col0[I]), 8, 24 + I * ROW_H, 110, 62, 150, CAP0[I])
    else if I = 1 then
      FWaveIdx[O] := AddParam(P0, Ord(Col0[I]), 8, 24 + I * ROW_H, 110, 62, 150, CAP0[I])
    else
      AddParam(P0, Ord(Col0[I]), 8, 24 + I * ROW_H, 110, 62, 150, CAP0[I]);
  // gezeichnete Welle: Haken ersetzt die Auswahl 'Welle', Knopf oeffnet die Zeichenflaeche
  FDrawIdx[O] := AddParam(P0, Ord(Op.Draw), 286, 24 + ROW_H, 0, 0, 0, Tr('Gezeichnet'));
  // gilt fuer alle drei Oszillatoren (derselbe Schalter in jedem Osz-Reiter)
  AddParam(P0, Ord(gpOscFollowPitch), 286, 24 + 3 * ROW_H, 0, 0, 0, Tr('folgt Pitch'));
  FWaveState[O] := -1;
  with TButton.Create(Self) do
  begin
    Parent := P0;
    SetBounds(384, 24 + ROW_H, 88, 24);
    Caption := Tr('Zeichnen ...');
    Icon := eiPencil;
    Tag := O;
    TabStop := False;
    OnClick := WaveEditClick;
    Hint := Tr('Eigene Welle zeichnen: eine Periode mit der Maus, dazu Grundformen und Glättung. ' +
      'Der Oszillator spielt sie bandbegrenzt (ohne Spiegelfrequenzen).');
    ShowHint := True;
  end;
  // FM-Klangfarbe: eigene Huellkurve fuer die FM-MENGE (nicht die Lautstaerke - die regelt die
  // Lautstaerke-Huellkurve in der Mitte). Wirkt nur bei Welle FM mit Haken; sonst ausgegraut.
  L := TLabel.Create(Self);
  L.Parent := P0;
  L.SetBounds(8, 24 + 9 * ROW_H + 9, 106, 16);
  L.Caption := Tr('FM-Klangfarbe');
  L.Font.Color := COL_VAL;
  L.Font.Style := [fsBold];
  L.Transparent := True;
  FFmEnvIdx[O, 0] := AddParam(P0, Ord(Op.FmEnvOn), 8, 24 + 9 * ROW_H + 4, 110, 0, 0,
    Tr('eigene Hüllkurve (nur Welle FM)'));
  FFmEnvIdx[O, 1] := AddParam(P0, Ord(Op.FmAttack), 8, 24 + 10 * ROW_H + 4, 110, 62, 0, Tr('Farbe Attack'));
  FFmEnvIdx[O, 2] := AddParam(P0, Ord(Op.FmDecay), 8, 24 + 11 * ROW_H + 4, 110, 62, 0, Tr('Farbe Decay'));
  FFmEnvIdx[O, 3] := AddParam(P0, Ord(Op.FmSustain), 8, 24 + 12 * ROW_H + 4, 110, 62, 0, Tr('Farbe Sustain'));
  FFmEnvIdx[O, 4] := AddParam(P0, Ord(Op.FmRelease), 8, 24 + 13 * ROW_H + 4, 110, 62, 0, Tr('Farbe Release'));
  FFmEnvState[O] := -1;
  for I := 0 to High(Col1) do
    AddParam(P1, Ord(Col1[I]), 8, ENV_Y + I * ROW_H, 70, 62);
  // Unison: mehrere verstimmte Stimmen je Note, ueber das Stereobild verteilt
  AddParam(P1, Ord(UNI[O, 0]), 8, ENV_Y + 4 * ROW_H + 6, 70, 0, 120, Tr('Unison'));
  AddParam(P1, Ord(UNI[O, 1]), 8, ENV_Y + 5 * ROW_H + 6, 70, 62, 0, Tr('Schwebung'));   // = Verstimmung der Unison-Stimmen (Tooltip)
  AddParam(P1, Ord(UNI[O, 2]), 8, ENV_Y + 6 * ROW_H + 6, 70, 62, 0, Tr('Breite'));
  if O = 0 then
  begin
    // Sub-Oszillator und Rauschanteil (Nov. 2026): folgen Tonhoehe, Huellkurve und Filter von Osz 1
    AddParam(P1, Ord(gpSubLevel), 8, ENV_Y + 7 * ROW_H + 12, 70, 62, 0, Tr('Sub'));
    AddParam(P1, Ord(gpSubOct), 8, ENV_Y + 8 * ROW_H + 12, 0, 0, 0, Tr('2 Oktaven tiefer'));
    AddParam(P1, Ord(gpSubWave), 170, ENV_Y + 8 * ROW_H + 12, 0, 0, 0, Tr('Rechteck statt Sinus'));
    AddParam(P1, Ord(gpNoiseLevel), 8, ENV_Y + 9 * ROW_H + 12, 70, 62, 0, Tr('Rauschen'));
  end
  else
  begin
    L := TLabel.Create(Self);
    L.Parent := P1;
    L.SetBounds(8, ENV_Y + 7 * ROW_H + 10, 420, 80);
    L.AutoSize := False;
    L.WordWrap := True;
    L.Font.Color := $00A0A0A0;
    L.Transparent := True;
    L.Caption :=
      Tr('Spielt jede Note mit: z.B. Bass (Sinus, Oktave -1/-2), Glocke (FM 3,5 / 40 %), Kick (FM + kurzer ' +
      'Decay) oder Hats (Rauschen + Hochpass). Drei Oszillatoren lassen sich schichten (z.B. zwei ' +
      'leicht verstimmte Sägezähne + Sub-Sinus). Alle Regler sind Matrix-Ziele, auch je Note.');
    AddStretch(L, 10);
  end;
  // abhaengige Bereiche: Oszillator aus = Lampe aus
  TGroupPanel(P1).LedMaster := TGroupPanel(P0).LedCheck;
  TGroupPanel(P2).LedMaster := TGroupPanel(P0).LedCheck;
end;

{ --- Reiter Mischpult: alle Lautstaerken an einem Ort - dieselben Parameter wie in den anderen
  Reitern (kein eigener Wert), beide Regler zeigen immer dasselbe --- }

function NoteName(N: Integer): string;
const
  NN: array[0..11] of string = ('C', 'Cis', 'D', 'Dis', 'E', 'F', 'Fis', 'G', 'Gis', 'A', 'B', 'H');
begin
  Result := NN[N mod 12] + IntToStr(N div 12 - 1);
end;

{ --- Reiter Samples: Zonen (weitere Samples je Tastenbereich) und Aufnahme des Sidechain-Eingangs --- }
procedure TGranularEditor.BuildSampleTab;
var
  Area, PZ, PR, PF: TPanel;
  Z, N: Integer;
  L: TLabel;
  B: TButton;
  RCol: TPanel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabSamples;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  PZ := MakePanel(Area, alLeft, Tr('Zonen: weitere Samples je Tastenbereich'));
  PZ.Width := 640;
  // rechte Spalte: oben Sample bearbeiten/Aufnahme, darunter Feedback-Resampling (zwei eigene Bereiche)
  RCol := TPanel.Create(Self);
  RCol.Parent := Area;
  RCol.Align := alClient;
  RCol.BevelOuter := bvNone;
  RCol.ParentBackground := False;
  RCol.Color := AREA_BG;
  PR := MakePanel(RCol, alTop, Tr('Sample bearbeiten und Aufnahme vom Eingang'));
  PR.Height := 146;

  L := TLabel.Create(Self);
  L.Parent := PZ;
  L.SetBounds(8, 26, 610, 34);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Das Hauptsample (Reiter Grain) spielt unterhalb der ersten Zone. Jede Zone gilt ab ihrer ' +
    'Starttaste bis zur nächsten Zone - z.B. tiefe Töne vom Cello, hohe von der Geige. Alle Grain-Regler wirken auf alle Zonen.');
  for Z := 1 to ZONE_COUNT do
  begin
    FZoneRow[Z] := TPanel.Create(Self);
    FZoneRow[Z].Parent := PZ;
    FZoneRow[Z].SetBounds(8, 66 + (Z - 1) * 40, 620, 34);
    FZoneRow[Z].BevelOuter := bvNone;
    FZoneRow[Z].ParentBackground := False;
    FZoneRow[Z].Color := BG_MAIN;
    L := TLabel.Create(Self);
    L.Parent := FZoneRow[Z];
    L.SetBounds(0, 9, 56, 16);
    L.Caption := Format(Tr('Zone %d'), [Z]);
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    L := TLabel.Create(Self);
    L.Parent := FZoneRow[Z];
    L.SetBounds(60, 9, 40, 16);
    L.Caption := Tr('ab');
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    FZoneNote[Z] := TComboBox.Create(Self);
    FZoneNote[Z].Parent := FZoneRow[Z];
    FZoneNote[Z].Style := csDropDownList;
    FZoneNote[Z].SetBounds(82, 5, 70, 21);
    FZoneNote[Z].DropDownCount := 24;
    FZoneNote[Z].TabStop := False;
    FZoneNote[Z].Items.BeginUpdate;
    for N := 0 to 127 do
      FZoneNote[Z].Items.Add(NoteName(N));
    FZoneNote[Z].Items.EndUpdate;
    FZoneNote[Z].Tag := Z;
    FZoneNote[Z].OnChange := ZoneNoteChange;
    B := TButton.Create(Self);
    B.Parent := FZoneRow[Z];
    B.SetBounds(160, 3, 90, 26);
    B.Caption := Tr('Laden...');
    B.Icon := eiOpen;
    B.Tag := Z;
    B.TabStop := False;
    B.OnClick := ZoneLoadClick;
    B := TButton.Create(Self);
    B.Parent := FZoneRow[Z];
    B.SetBounds(256, 3, 70, 26);
    B.Caption := Tr('Leeren');
    B.Icon := eiTrash;
    B.Tag := Z;
    B.TabStop := False;
    B.OnClick := ZoneClearClick;
    B := TButton.Create(Self);
    B.Parent := FZoneRow[Z];
    B.SetBounds(332, 3, 96, 26);
    B.Caption := Tr('Bearbeiten...');
    B.Icon := eiPencil;
    B.Hint := Tr('Sample dieser Zone schneiden, blenden, normalisieren');
    B.ShowHint := True;
    B.Tag := Z;
    B.TabStop := False;
    B.OnClick := EditSampleClick;
    FZoneName[Z] := TLabel.Create(Self);
    FZoneName[Z].Parent := FZoneRow[Z];
    FZoneName[Z].SetBounds(436, 9, 184, 16);
    FZoneName[Z].AutoSize := False;
    FZoneName[Z].Font.Color := COL_VAL;
    FZoneName[Z].Transparent := True;
  end;
  L := TLabel.Create(Self);
  L.Parent := PZ;
  L.SetBounds(8, 66 + ZONE_COUNT * 40 + 6, 610, 34);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Tipp: Audiodateien lassen sich auch aus dem Explorer auf das Fenster ziehen - auf eine ' +
    'Zonen-Zeile = in diese Zone, sonst als Hauptsample.');

  FRecButton := TButton.Create(Self);
  FRecButton.Parent := PR;
  FRecButton.SetBounds(216, 26, 170, 30);
  FRecButton.Caption := Tr('Aufnahme starten');
  FRecButton.Icon := eiRec;
  FRecButton.TabStop := False;
  FRecButton.OnClick := RecClick;
  B := TButton.Create(Self);
  B.Parent := PR;
  B.SetBounds(8, 26, 200, 30);
  B.Caption := Tr('Sample-Editor...');
  B.Icon := eiPencil;
  B.Hint := Tr('Audio bearbeiten: schneiden, löschen, ein-/ausblenden, normalisieren, Stille entfernen, umkehren');
  B.ShowHint := True;
  B.Tag := 0;
  B.TabStop := False;
  B.OnClick := EditSampleClick;
  FRecLabel := TLabel.Create(Self);
  FRecLabel.Parent := PR;
  FRecLabel.SetBounds(8, 62, 420, 16);
  FRecLabel.Font.Color := COL_VAL;
  FRecLabel.Transparent := True;
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.SetBounds(8, 82, 420, 64);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Nimmt den Sidechain-Eingang auf (in der DAW: Eingang des Plugins, im Host: Mikrofon/Eingang) ' +
    'und lädt das Ergebnis als neues Hauptsample - so lässt sich eine Spur, die Stimme oder der eigene ' +
    'Klang live granulieren. Die Aufnahme wird als WAV in "Eigene Toene" gespeichert und ist damit Teil des Presets.');
  AddStretch(L, 10);

  // Feedback-Resampling: der eigene Klang wird Durchlauf fuer Durchlauf zur neuen Grain-Quelle
  PF := MakePanel(RCol, alClient, Tr('Feedback-Resampling'));
  AddParam(PF, Ord(gpResOn), 8, 24, 0, 0, 0, Tr('Resampling an'));
  AddParam(PF, Ord(gpResMix), 8, 24 + ROW_H, 90, 66, 0, Tr('Anteil neu'));
  AddParam(PF, Ord(gpResTime), 8, 24 + 2 * ROW_H, 90, 66, 0, Tr('Durchlauf'));
  AddParam(PF, Ord(gpResSync), 8, 24 + 3 * ROW_H, 90, 0, 100, Tr('Im Takt'));
  FResLabel := TLabel.Create(Self);
  FResLabel.Parent := PF;
  FResLabel.SetBounds(8, 24 + 4 * ROW_H + 4, 420, 16);
  FResLabel.AutoSize := False;
  FResLabel.Font.Color := COL_VAL;
  FResLabel.Transparent := True;
  L := TLabel.Create(Self);
  L.Parent := PF;
  L.SetBounds(8, 24 + 5 * ROW_H, 420, 110);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Solange eine Taste gehalten wird, wird das Gespielte (mit Effekten und Hall) nach jedem Durchlauf ' +
    'zur neuen Grain-Quelle - der Klang entwickelt sich, je länger man hält. Jeder neue Anschlag beginnt wieder beim ' +
    'Original. Durchlauf: Länge frei in ms oder im Takt. Anteil neu: 100 % ersetzt jedes Mal ganz, wenig mischt ' +
    'behutsam bei. Tonhöhe und Pegel bleiben stehen.');
  AddStretch(L, 10);
end;

procedure TGranularEditor.RecClick(Sender: TObject);
var
  Data: TSampleData;
  Dir, Fn: string;
begin
  if FRecButton.Tag = 0 then
  begin
    FEngine.StartRecording(60);
    FRecButton.Tag := 1;
    FRecButton.Caption := Tr('Stopp und laden');
    FRecLabel.Caption := Tr('Aufnahme läuft ...');
    Exit;
  end;
  FRecButton.Tag := 0;
  FRecButton.Caption := Tr('Aufnahme starten');
  Data := FEngine.StopRecording;
  if Data = nil then
  begin
    FRecLabel.Caption := Tr('Nichts aufgenommen (kommt Signal am Sidechain-Eingang an?)');
    Exit;
  end;
  Dir := FBaseDir + 'Eigene Toene' + PathDelim;
  try
    ForceDirectories(Dir);
    Fn := Dir + Tr('Aufnahme ') + FormatDateTime(Tr('yyyy-mm-dd hh-nn-ss'), Now) + '.wav';
    SaveWaveFile(Data, Fn);
    Data.FileName := Fn;
  except
    Fn := '';                 // Ordner schreibgeschuetzt: Sample gilt bis zum Schliessen
  end;
  FRecLabel.Caption := Format(Tr('%.1f s geladen'), [Data.Frames / Data.SampleRate]);
  PushUndo;
  SetSample(Data);
end;

{ Fenster "Audio bearbeiten" fuer das Hauptsample (Tag 0) oder eine Zone (Tag = Zone); das Ergebnis
  wird als neue WAV in "Eigene Toene" gespeichert - das Original bleibt unangetastet }
procedure TGranularEditor.EditSampleClick(Sender: TObject);
begin
  EditSample((Sender as TComponent).Tag);
end;

procedure TGranularEditor.OpenAudioEditor;
var
  T: TTimer;
begin
  // modal erst nach dem Oeffnen des Plugin-Fensters (sonst blockiert effEditOpen); ein Timer statt
  // TThread.Queue - die RTL der DLL arbeitet ihre Warteschlange im Host nicht ab
  T := TTimer.Create(Self);
  T.Interval := 500;
  T.OnTimer := AudioEditorTimer;
end;

var
  GTestSetupDone: Boolean;   // Testhilfe GRANULAR_PRESET/GRANULAR_PARAMS schon ausgefuehrt

{ Testhilfe: Preset erst laden, wenn Host und Autoplay ihren Zustand gesetzt haben (sonst ueberschreiben sie es) }
procedure TGranularEditor.LoadPresetLater(const FileName: string; DelayMs: Integer);
var
  T: TTimer;
begin
  FPendingPreset := FileName;
  T := TTimer.Create(Self);
  T.Interval := DelayMs;
  T.OnTimer := PresetLaterTimer;
end;

{ Testhilfe GRANULAR_SCREWCHECK=<Datei>: alle Bereiche durchgehen und auflisten, welche Bedienelemente in
  eine Schraubenecke ragen (Bereich, Ecke, Element, Text) }
procedure ScrewCheck(Root: TWinControl; L: TStrings);
const
  CORNER: array[0..3] of string = ('oben links', 'oben rechts', 'unten links', 'unten rechts');
var
  I, J, K, Sr, D, Cx, Cy: Integer;
  P: TWinControl;
  C: TControl;
  R, S, T: TRect;
  Txt, Title: string;
begin
  for I := 0 to Root.ControlCount - 1 do
    if Root.Controls[I] is TWinControl then
    begin
      P := TWinControl(Root.Controls[I]);
      if (P is TGroupPanel) and (P.ClientWidth > 20) then
      begin
        Sr := Max(2, P.ScaleValue(3));
        D := P.ScaleValue(3) + Sr;
        Title := '';
        for J := 0 to P.ControlCount - 1 do
          if (P.Controls[J] is TLabel) and (P.Controls[J].Top < 8) then
            Title := TLabel(P.Controls[J]).Caption;
        for K := 0 to 3 do
        begin
          if K mod 2 = 0 then Cx := D else Cx := P.ClientWidth - 1 - D;
          if K < 2 then Cy := P.ScaleValue(GRP_HEAD) div 2 else Cy := P.ClientHeight - 1 - D;
          S := Rect(Cx - Sr - 2, Cy - Sr - 2, Cx + Sr + 3, Cy + Sr + 3);
          for J := 0 to P.ControlCount - 1 do
          begin
            C := P.Controls[J];
            if not C.Visible then
              Continue;
            R := C.BoundsRect;
            if C is TLabel then
            begin
              // nur der tatsaechlich beschriebene Teil zaehlt
              Txt := TLabel(C).Caption;
              if TLabel(C).Alignment = taRightJustify then
                R.Left := R.Right - TLabel(C).Canvas.TextWidth(Txt)
              else
                R.Right := R.Left + TLabel(C).Canvas.TextWidth(Txt);
              R.Bottom := R.Top + TLabel(C).Canvas.TextHeight('Ag');
            end
            else
              Txt := C.ClassName;
            if (C is TLabel) and (C.Top < 8) then
              Continue;   // Titel
            if IntersectRect(T, R, S) then
              L.Add(Format('%s | %s | %s | %s', [Title, CORNER[K], C.ClassName,
                StringReplace(Txt, sLineBreak, ' ', [rfReplaceAll])]));
          end;
        end;
      end;
      ScrewCheck(P, L);
    end;
end;

procedure TGranularEditor.PresetLaterTimer(Sender: TObject);
var
  Items: TArray<string>;
  Item, Name: string;
  P, I: Integer;
  V: Double;
  SL: TStringList;
begin
  (Sender as TTimer).Enabled := False;
  if GetEnvironmentVariable('GRANULAR_SCREWCHECK') <> '' then
  begin
    SL := TStringList.Create;
    try
      ScrewCheck(Self, SL);
      SL.SaveToFile(GetEnvironmentVariable('GRANULAR_SCREWCHECK'), TEncoding.UTF8);
    finally
      SL.Free;
    end;
  end;
  if GTestSetupDone then
    Exit;
  GTestSetupDone := True;
  if FileExists(FPendingPreset) then
    LoadPreset(FPendingPreset);
  // Testhilfe GRANULAR_PARAMS: 'Name=Wert;Name=Wert' (Klartext wie in der Reglertabelle, Stufen als Index),
  // z. B. 'EQ an=1;Cutoff=650;Filtertyp=0' - fuer Bildschirmfotos mit aussagekraeftigen Anzeigen
  Items := GetEnvironmentVariable('GRANULAR_PARAMS').Split([';']);
  for Item in Items do
  begin
    P := Pos('=', Item);
    if P < 2 then
      Continue;
    Name := Trim(Copy(Item, 1, P - 1));
    V := StrToFloatDef(Trim(Copy(Item, P + 1, MaxInt)), 0, TFormatSettings.Invariant);
    for I := 0 to PARAM_COUNT - 1 do
      if SameText(GetParamInfo(I).Name, Name) then
      begin
        if GetParamInfo(I).Curve = pcStepped then
          FEngine.SetParam(I, StepToParam(I, Round(V)))
        else
          FEngine.SetParam(I, PlainToParam(I, V));
        Break;
      end;
  end;
  UpdateFromEngine;
end;

procedure TGranularEditor.AudioEditorTimer(Sender: TObject);
begin
  (Sender as TTimer).Enabled := False;
  EditSample(0);
end;

procedure TGranularEditor.EditSample(Z: Integer);
var
  Src: TSampleData;
  Name, Cap: string;
begin
  if Z = 0 then
  begin
    Src := FEngine.Sample;
    Name := FEngine.SamplePath;
    Cap := Tr('Sample-Editor - Hauptsample');
  end
  else
  begin
    Src := FEngine.ZoneSample(Z);
    Name := FEngine.GetZoneLoaded(Z);
    Cap := Format(Tr('Sample-Editor - Zone %d'), [Z]);
  end;
  if (Src <> nil) and IsEmptySample(Src) then
    Src := nil;
  if FAudioForm[Z] <> nil then
  begin
    FAudioForm[Z].Show;
    FAudioForm[Z].BringToFront;
    Exit;
  end;
  FAudioForm[Z] := ShowAudioEditor(Self, Src, Cap, FBaseDir,
    procedure(R: TSampleData)
    begin
      EditSampleDone(Z, R);
    end,
    procedure
    begin
      FAudioForm[Z] := nil;
    end);
end;

{ Uebernehmen im Sample-Editor: speichern in "Eigene Toene" und laden }
procedure TGranularEditor.EditSampleDone(Z: Integer; Res: TSampleData);
var
  N: Integer;
  Name, Dir, Fn: string;
begin
  if Z = 0 then
    Name := FEngine.SamplePath
  else
    Name := FEngine.GetZoneLoaded(Z);
  // Name: Original + "_bearbeitet_NN"; ohne Datei (Demo-Klang, Aufnahme ohne Ordner) "Sample"
  Name := ChangeFileExt(ExtractFileName(Name), '');
  N := Pos('_bearbeitet_', Name);
  if N > 0 then
    Name := Copy(Name, 1, N - 1);
  if Name = '' then
    Name := 'Sample';
  Dir := FBaseDir + 'Eigene Toene' + PathDelim;
  Fn := '';
  try
    ForceDirectories(Dir);
    N := 1;
    repeat
      Fn := Dir + Format('%s_bearbeitet_%.2d.wav', [Name, N]);
      Inc(N);
    until not FileExists(Fn);
    SaveWaveFile(Res, Fn);
    Res.FileName := Fn;
  except
    Fn := '';                 // Ordner schreibgeschuetzt: Sample gilt bis zum Schliessen
  end;
  if Z = 0 then
  begin
    PushUndo;
    SetSample(Res);
  end
  else
  begin
    FEngine.SetZone(Z, Res, FZoneNote[Z].ItemIndex);
    FEngine.SetZoneLoaded(Z, Fn);
    if Fn <> '' then
      FEngine.SetZoneRef(Z, MakePortablePath(Fn, FBaseDir))
    else
      FEngine.SetZoneRef(Z, '');
    UpdateZoneUi;
  end;
end;

procedure TGranularEditor.LoadZoneFile(Z: Integer; const FileName: string);
begin
  FEngine.SetZone(Z, LoadAudioFile(FileName), FZoneNote[Z].ItemIndex);
  FEngine.SetZoneLoaded(Z, FileName);
  FEngine.SetZoneRef(Z, MakePortablePath(FileName, FBaseDir));
  UpdateZoneUi;
end;

procedure TGranularEditor.WtLoadClick(Sender: TObject);
var
  O: Integer;
  Dlg: TOpenDialog;
begin
  O := (Sender as TComponent).Tag;
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := AUDIO_FILE_FILTER;
    if DirectoryExists(FBaseDir + 'Beispieltoene') then
      Dlg.InitialDir := FBaseDir + 'Beispieltoene';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if not Dlg.Execute then
      Exit;
    PushUndo;
    FEngine.WtRef[O] := MakePortablePath(Dlg.FileName, FBaseDir);
    Screen.Cursor := crHourGlass;
    try
      LoadOscWavetables(FEngine, FBaseDir);
    finally
      Screen.Cursor := crDefault;
    end;
    if FEngine.WtFrameCount(O) > 0 then
      FEngine.SetParamById(OSC_P[O].WtOn, 1)
    else
      MessageDlg(Format(Tr('Die Datei "%s" ließ sich nicht als Wavetable laden.'), [ExtractFileName(Dlg.FileName)]),
        mtWarning, [mbOK], 0);
    UpdateFromEngine;
    UpdateWtNames;
  finally
    Dlg.Free;
  end;
end;

{ Name und Frame-Zahl der geladenen Wavetable je Oszillator (nur bei Aenderung neu setzen) }
procedure TGranularEditor.UpdateWtNames;
var
  O: Integer;
  S: string;
begin
  for O := 0 to OSC_COUNT - 1 do
  begin
    if FWtName[O] = nil then
      Continue;
    if FEngine.WtFrameCount(O) > 0 then
      S := Format(Tr('%s - %d Frames'), [ChangeFileExt(ExtractFileName(FEngine.WtLoaded[O]), ''), FEngine.WtFrameCount(O)])
    else
      S := Tr('keine Wavetable geladen');
    if S <> FWtShown[O] then
    begin
      FWtShown[O] := S;
      FWtName[O].Caption := S;
    end;
  end;
end;

procedure TGranularEditor.ZoneLoadClick(Sender: TObject);
var
  Dlg: TOpenDialog;
  Z: Integer;
begin
  Z := (Sender as TComponent).Tag;
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := AUDIO_FILE_FILTER;
    if DirectoryExists(FBaseDir + 'Beispieltoene') then
      Dlg.InitialDir := FBaseDir + 'Beispieltoene';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if Dlg.Execute then
    try
      LoadZoneFile(Z, Dlg.FileName);
    except
      on E: Exception do
        MessageDlg(Tr('Datei konnte nicht geladen werden:') + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TGranularEditor.ZoneClearClick(Sender: TObject);
var
  Z: Integer;
begin
  Z := (Sender as TComponent).Tag;
  FEngine.SetZone(Z, nil, FZoneNote[Z].ItemIndex);
  FEngine.SetZoneLoaded(Z, '');
  FEngine.SetZoneRef(Z, '');
  UpdateZoneUi;
end;

procedure TGranularEditor.ZoneNoteChange(Sender: TObject);
var
  Z: Integer;
begin
  if FUpdating then
    Exit;
  Z := (Sender as TComponent).Tag;
  FEngine.SetZoneLow(Z, FZoneNote[Z].ItemIndex);
  FPages.SetFocus;
end;

procedure TGranularEditor.UpdateZoneUi;
var
  Z: Integer;
begin
  if FZoneNote[1] = nil then
    Exit;
  FUpdating := True;
  try
    for Z := 1 to ZONE_COUNT do
    begin
      FZoneNote[Z].ItemIndex := FEngine.GetZoneLow(Z);
      if FEngine.ZoneSample(Z) <> nil then
        FZoneName[Z].Caption := ExtractFileName(FEngine.GetZoneLoaded(Z))
      else
        FZoneName[Z].Caption := Tr('(leer)');
    end;
  finally
    FUpdating := False;
  end;
end;

procedure TGranularEditor.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);     // Audiodateien aus dem Explorer aufs Fenster ziehen
end;

procedure TGranularEditor.WMDropFiles(var Msg: TWMDropFiles);
var
  Buf: array[0..MAX_PATH] of Char;
  Pt: TPoint;
  Z, Target: Integer;
  Fn: string;
begin
  try
    if DragQueryFile(Msg.Drop, 0, Buf, Length(Buf)) = 0 then
      Exit;
    Fn := Buf;
    // MIDI (z.B. das eigene Arp-Muster) gehoert in eine DAW-Spur, nicht ins Sample
    if SameText(ExtractFileExt(Fn), '.mid') or SameText(ExtractFileExt(Fn), '.midi') then
      Exit;
    DragQueryPoint(Msg.Drop, Pt);
    Pt := ClientToScreen(Pt);
    Target := 0;
    if FPages.ActivePage = FTabSamples then
      for Z := 1 to ZONE_COUNT do
        if PtInRect(FZoneRow[Z].BoundsRect, FZoneRow[Z].Parent.ScreenToClient(Pt)) then
          Target := Z;
    try
      if Target > 0 then
        LoadZoneFile(Target, Fn)
      else
      begin
        PushUndo;
        LoadFile(Fn);
      end;
    except
      on E: Exception do
        MessageDlg(Tr('Datei konnte nicht geladen werden:') + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    DragFinish(Msg.Drop);
    Msg.Result := 0;
  end;
end;

{ Tooltip aus der Reglertabelle der Hilfe (Granular.Hints): auf Regler/Liste/Schalter und Beschriftung.
  Vorhandene, eigens gesetzte Hinweise bleiben. Lange Texte umbrechen, damit das Fenster lesbar bleibt. }
procedure TGranularEditor.ApplyParamHint(const B: TParamBinding);
var
  H: string;

  procedure Put(C: TControl);
  begin
    if (C <> nil) and (C.Hint = '') then
    begin
      C.Hint := H;
      C.ShowHint := True;
    end;
  end;

begin
  H := Tr(ParamHint(B.Index));
  if H = '' then
    Exit;
  H := WrapText(H, 80);
  Put(B.Track);
  Put(B.Combo);
  Put(B.Check);
  Put(B.NameLabel);
end;

{ Knoepfe und Schalter ohne eigenen Regler: Tooltip ueber die Beschriftung (z.B. "Variieren", "A/B") }
procedure TGranularEditor.ApplyCaptionHints;
var
  I: Integer;
  H: string;
begin
  for I := 0 to ComponentCount - 1 do
    if (Components[I] is TButton) and (TButton(Components[I]).Hint = '') then
    begin
      H := Tr(CaptionHint(TButton(Components[I]).Caption));
      if H <> '' then
      begin
        TButton(Components[I]).Hint := WrapText(H, 80);
        TButton(Components[I]).ShowHint := True;
      end;
    end;
  // Tooltips lang genug stehen lassen, um sie zu lesen
  Application.HintHidePause := 30000;
end;

{ --- Reiter Effekte: Chorus, Phaser, Bitcrusher (auf die Summe, vor Echo und Hall) und Trance-Gate --- }
procedure TGranularEditor.BuildFx2Tab;
const
  CHO: array[0..4] of TGranularParamId = (gpChoOn, gpChoRate, gpChoDepth, gpChoFeedback, gpChoMix);
  CHO_CAP: array[0..4] of string = ('Chorus an', 'Tempo', 'Tiefe', 'Rückkopplung', 'Mix');
  PHA: array[0..4] of TGranularParamId = (gpPhaOn, gpPhaRate, gpPhaDepth, gpPhaFeedback, gpPhaMix);
  PHA_CAP: array[0..4] of string = ('Phaser an', 'Tempo', 'Tiefe', 'Rückkopplung', 'Mix');
  CRU: array[0..3] of TGranularParamId = (gpCrushOn, gpCrushBits, gpCrushRate, gpCrushMix);
  CRU_CAP: array[0..3] of string = ('Bitcrusher an', 'Bits', 'Abtastrate', 'Mix');
  TG: array[0..4] of TGranularParamId = (gpTgOn, gpTgRate, gpTgSteps, gpTgDepth, gpTgSmooth);
  TG_CAP: array[0..4] of string = ('Gate an', 'Notenwert', 'Schritte', 'Tiefe', 'Glättung');
var
  Area, P1, P2, P3, P4: TPanel;
  I: Integer;

  procedure Hint(P: TPanel; Y: Integer; const Text: string);
  var
    L: TLabel;
  begin
    L := TLabel.Create(Self);
    L.Parent := P;
    L.SetBounds(8, Y, 280, 130);
    L.AutoSize := False;
    L.WordWrap := True;
    L.Font.Color := $00A0A0A0;
    L.Transparent := True;
    L.Caption := Text;
    AddStretch(L, 10);
  end;

begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabFx2;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  // Reihenfolge der vier Effekte (Nov. 2026): unten, ueber die ganze Breite
  P4 := MakePanel(Area, alBottom, Tr('Reihenfolge der Effekte im Signalweg (der erste bearbeitet zuerst)'));
  P4.Height := 24 + ROW_H + 8;
  AddParam(P4, Ord(gpFxOrder), 8, 24, 100, 0, 300, Tr('Reihenfolge'));
  P1 := MakePanel(Area, alLeft, Tr('Chorus / Flanger'));
  P1.Width := 300;
  P2 := MakePanel(Area, alLeft, Tr('Phaser'));
  P2.Width := 300;
  P2.Left := P1.Left + P1.Width + 1;
  P3 := MakePanel(Area, alLeft, Tr('Bitcrusher'));
  P3.Width := 300;
  P3.Left := P2.Left + P2.Width + 1;
  P4 := MakePanel(Area, alClient, Tr('Trance-Gate (Schrittmuster im Songtempo)'));
  for I := 0 to High(CHO) do
    AddParam(P1, Ord(CHO[I]), 8, 24 + I * ROW_H, 92, 62, 0, CHO_CAP[I]);
  for I := 0 to High(PHA) do
    AddParam(P2, Ord(PHA[I]), 8, 24 + I * ROW_H, 92, 62, 0, PHA_CAP[I]);
  for I := 0 to High(CRU) do
    AddParam(P3, Ord(CRU[I]), 8, 24 + I * ROW_H, 92, 62, 0, CRU_CAP[I]);
  for I := 0 to High(TG) do
    if I in [1, 2] then
      AddParam(P4, Ord(TG[I]), 8, 24 + I * ROW_H, 92, 0, 110, TG_CAP[I])
    else
      AddParam(P4, Ord(TG[I]), 8, 24 + I * ROW_H, 92, 62, 0, TG_CAP[I]);
  FGatePattern := TArpPatternView.Create(Self, FEngine);
  FGatePattern.Gate := True;
  FGatePattern.Parent := P4;
  FGatePattern.SetBounds(8, 24 + 5 * ROW_H + 6, 280, 34);
  FGatePattern.Hint := Tr('Klick schaltet einen Schritt auf/zu (zu = um "Tiefe" leiser). Der laufende Schritt leuchtet.');
  FGatePattern.ShowHint := True;
  FGatePattern.OnChange := GatePatternChange;
  AddStretch(FGatePattern, 8);
  Hint(P1, 24 + 5 * ROW_H + 8,
    Tr('Mehrere leicht verschobene Kopien: breiter, schwebender Klang. Rückkopplung hoch und Tiefe klein = ' +
    'Flanger (Düsenjet). Links und rechts laufen versetzt - schön auf Pads und E-Piano.'));
  Hint(P2, 24 + 5 * ROW_H + 8,
    Tr('Sechs Allpässe erzeugen wandernde Kerben im Spektrum: der typische Wusch der 70er. Langsames Tempo ' +
    'auf Flächen, schneller auf Rhodes und Gitarren-Sounds. Rückkopplung macht die Kerben schärfer.'));
  Hint(P3, 24 + 4 * ROW_H + 8,
    Tr('Senkt Auflösung (Bits) und Abtastrate: Lo-Fi, Retro-Konsole, Dreck. 8 Bit / 11 kHz = Heimcomputer, ' +
    '4 Bit = kaputt. Mix unter 100 % mischt das Original dazu.'));
  Hint(P4, 24 + 5 * ROW_H + 50,
    Tr('Zerhackt den Klang im Takt: zu = leiser um "Tiefe" (100 % = stumm). Glättung gegen Knacken. Wirkt vor ' +
    'Echo und Hall - die laufen frei aus. Beginnt nach einer Pause wieder bei Schritt 1. Die Effekte liegen ' +
    'auf der Summe, nach den Filtern und vor Echo/Hall; alle Regler sind Matrix-Ziele.'));
end;

procedure TGranularEditor.GatePatternChange(Sender: TObject);
begin
  FEditParam := -1;     // Musteraenderung beendet eine laufende Reglerbewegung (eigener Undo-Schritt folgt nicht)
end;

procedure TGranularEditor.BuildMixTab;
type
  TCh = record
    Fader, Switch_: TGranularParamId;
    HasSwitch: Boolean;
    Cap, SwCap: string;
  end;
const
  CH_W = 62;           // Kanalbreite, fuer alle Kanaele gleich (ruhiges Bild)
  GAP = 32;            // Abstand zwischen den Gruppen
  FADER_H = 180;
  STRIP_GAP = 3;       // Fuge zwischen zwei Kanalzuegen
  DECK_PAD = 10;       // Rand des Gehaeuses
  STRIP_H = FADER_H + 78;
var
  Area, P: TPanel;
  Deck: TMixDeck;
  Strip: TMixStrip;
  Chs: array[0..13] of TCh;
  MeterOf: array[0..13] of Integer;
  W: Integer;
  K: Integer;
  I, X, Y: Integer;
  L: TLabel;

  procedure SetCh(Idx: Integer; F: TGranularParamId; const C: string; HasSw: Boolean;
    Sw: TGranularParamId; const SwC: string);
  begin
    Chs[Idx].Fader := F; Chs[Idx].Cap := C; Chs[Idx].HasSwitch := HasSw;
    Chs[Idx].Switch_ := Sw; Chs[Idx].SwCap := SwC;
  end;

begin
  SetCh(0, gpGrainLevel, Tr('Grains'), True, gpGrainOn, 'an');
  SetCh(1, gpOscLevel, Tr('Osz 1'), True, gpOscOn, 'an');
  SetCh(2, gpOsc2Level, Tr('Osz 2'), True, gpOsc2On, 'an');
  SetCh(3, gpOsc3Level, Tr('Osz 3'), True, gpOsc3On, 'an');
  SetCh(4, gpEchoMix, Tr('Echo'), True, gpEchoOn, 'an');
  SetCh(5, gpRevMix, Tr('Hall'), True, gpRevOn, 'an');
  // Summen-Effekte (Reiter Effekte): Mix bzw. Gate-Tiefe, Schalter an/aus
  SetCh(6, gpTgDepth, Tr('Gate'), True, gpTgOn, 'an');
  SetCh(7, gpCrushMix, Tr('Crusher'), True, gpCrushOn, 'an');
  SetCh(8, gpChoMix, Tr('Chorus'), True, gpChoOn, 'an');
  SetCh(9, gpPhaMix, Tr('Phaser'), True, gpPhaOn, 'an');
  SetCh(10, gpMorph, Tr('Morph'), False, gpMorph, '');
  SetCh(11, gpPan, Tr('Panorama'), False, gpPan, '');
  SetCh(12, gpVolume, Tr('Summe'), False, gpVolume, '');
  SetCh(13, gpMaster, Tr('Master'), False, gpMaster, '');
  // Pegelanzeige je Kanal (Morph und Panorama haben keinen eigenen Pegel); Effekte: was sie veraendern
  MeterOf[0] := MM_GRAINS; MeterOf[1] := MM_OSC1; MeterOf[2] := MM_OSC1 + 1; MeterOf[3] := MM_OSC1 + 2;
  MeterOf[4] := MM_ECHO; MeterOf[5] := MM_HALL;
  MeterOf[6] := MM_GATE; MeterOf[7] := MM_CRUSH; MeterOf[8] := MM_CHO; MeterOf[9] := MM_PHA;
  MeterOf[10] := -1; MeterOf[11] := -1;
  MeterOf[12] := MM_SUM; MeterOf[13] := MM_OUT;

  Area := TPanel.Create(Self);
  Area.Parent := FTabMix;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  P := MakePanel(Area, alClient, Tr('Mischpult  (dieselben Regler wie in den Reitern - ändern sich hier und dort gemeinsam)'));
  // Konsole: Gehaeuse ueber die volle Breite, darin die Kanalzuege und rechts das Spektrum als Display
  Deck := TMixDeck.Create(Self);
  Deck.Parent := P;
  Deck.BevelOuter := bvNone;
  Deck.ParentBackground := False;
  Deck.Color := DECK_BG;
  Deck.SetBounds(8, 24, 900, STRIP_H + 2 * DECK_PAD);
  Deck.OnResize := PanelResize;
  AddStretch(Deck, 8);
  X := DECK_PAD;
  for I := 0 to High(Chs) do
  begin
    if I in [4, 10] then
      Inc(X, GAP - STRIP_GAP);             // Gruppen: Klangquellen | Effekte (Echo, Hall, Gate ...) | Ausgang
    W := CH_W - STRIP_GAP;
    Strip := TMixStrip.Create(Self);
    Strip.Parent := Deck;
    Strip.BevelOuter := bvNone;
    Strip.ParentBackground := False;
    Strip.Color := STRIP_BG;
    Strip.CapH := 18;
    if I < 4 then Strip.Cap := CAP_SRC else if I < 10 then Strip.Cap := CAP_FX else Strip.Cap := CAP_OUT;
    Strip.SetBounds(X, DECK_PAD, W, STRIP_H);
    K := AddFader(Strip, Ord(Chs[I].Fader), 2, 4, FADER_H, Chs[I].Cap, W);
    if Strip.Cap = CAP_FX then
      FBindings[K].NameLabel.Font.Color := $00262626;   // dunkle Schrift auf der hellen Bernstein-Kappe
    if MeterOf[I] >= 0 then
    begin
      FMixMeters[MeterOf[I]] := TMixMeter.Create(Self);
      FMixMeters[MeterOf[I]].Parent := Strip;
      FMixMeters[MeterOf[I]].SetBounds(2 + (W - 4) div 2 + 18, 4 + 24, 7, FADER_H - 8);
      if I in [6..9] then
        FMixMeters[MeterOf[I]].Hint := Tr('Wie stark der Effekt den Klang verändert (grün, ab -6 dB gelb, ab 0 dB rot)')
      else
        FMixMeters[MeterOf[I]].Hint := Tr('Pegel (grün, ab -6 dB gelb, ab 0 dB rot)');
      FMixMeters[MeterOf[I]].ShowHint := True;
    end;
    if Chs[I].HasSwitch then
    begin
      // unter der Fadermitte; Beschriftung zeigt den Zustand
      K := AddParam(Strip, Ord(Chs[I].Switch_), 2 + (W - 4) div 2 - 22, 4 + FADER_H + 46, 0, 0, 0, 'an');
      FBindings[K].OnOffCaption := True;
      FBindings[K].NameLabel.Width := 40;
      FBindings[K].Check.Hint := Chs[I].Cap + Tr(' ein/aus');
      FBindings[K].Check.ShowHint := True;
      SetControlValue(K, FEngine.GetParam(Ord(Chs[I].Switch_)));
    end;
    Inc(X, CH_W);
  end;
  // rechts neben den Kanaelen: Frequenzband als eingelassenes Display, so hoch wie die Kanalzuege;
  // die Texte darunter laufen ueber die volle Breite
  FMixSpectrum := TSpectrumView.Create(Self, FEngine);
  FMixSpectrum.Parent := Deck;
  FMixSpectrum.SetBounds(X + GAP - STRIP_GAP + 6, DECK_PAD + 6, 300, STRIP_H - 12);
  AddStretch(FMixSpectrum, DECK_PAD + 8);
  Deck.Display := FMixSpectrum;
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(12, 24 + STRIP_H + 2 * DECK_PAD + 8, 900, 40);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Grains/Osz 1-3 = Pegel der Quellen, Echo/Hall = Mischanteil, Gate/Crusher/Chorus/Phaser = Reiter Effekte ' +
    '(Gate: Tiefe, sonst Mix; die Anzeige zeigt, wie stark der Effekt den Klang verändert), Summe = Lautstärke, ' +
    'Master = Ausgang (bleibt beim Presetwechsel). Haken darunter: an/aus.');
  AddStretch(L, 12);

  // Eingaenge der DAW: welches Eingangspaar ist Sidechain 1 / 2, dazu die Live-Pegel aller vier
  // Eingaenge (zeigt sofort, ob und wo die DAW Audio schickt)
  Y := 24 + STRIP_H + 2 * DECK_PAD + 8 + 46;
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(12, Y + 5, 110, 16);
  L.Caption := Tr('Eingänge (DAW):');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  AddParam(P, Ord(gpSc1Input), 120, Y, 82, 0, 110, Tr('Sidechain 1'));
  AddParam(P, Ord(gpSc2Input), 340, Y, 82, 0, 110, Tr('Sidechain 2'));
  FInLevels := TLabel.Create(Self);
  FInLevels.Parent := P;
  FInLevels.SetBounds(560, Y + 5, 420, 16);
  FInLevels.Font.Color := COL_NAME;
  FInLevels.Transparent := True;
  FInLevels.Hint := Tr('Pegel der vier Plugin-Eingänge. Alles "-" = die DAW schickt kein Audio: in FL Studio ' +
    'die Eingänge des Plugins im Wrapper (Processing) bzw. Mixer zuordnen, siehe Hilfe.');
  FInLevels.ShowHint := True;
  // Leistungsstufe (gehoert zum Rechner, nicht zum Preset)
  Y := Y + 28;
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(12, Y + 5, 110, 16);
  L.Caption := Tr('Leistung:');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  K := AddParam(P, Ord(gpPerformance), 120, Y, 0, 0, 200);
  FBindings[K].Combo.Hint := Tr('Begrenzt gleichzeitige Stimmen und Grains (weniger CPU-Spitzen, z. B. auf ' +
    'langsamen Rechnern oder mit vielen Instanzen in FL Studio). Bleibt beim Presetwechsel erhalten.');
  FBindings[K].Combo.ShowHint := True;
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(340, Y + 5, 560, 16);
  L.Caption := Tr('Rechenlast und aktive Rechenblöcke: Reiter "Leistung".');
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
end;

{ --- Reiter Leistung: aktive Rechenbloecke (theoretische Last) und Drehzahlmesser der Rechenzeit --- }

procedure TGranularEditor.BuildPerfTab;
var
  Area, PL, PR: TPanel;
  L: TLabel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabPerf;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  PL := MakePanel(Area, alLeft, Tr('Aktive Rechenblöcke'));
  PL.Width := 600;
  FLoadList := TLoadList.Create(Self, FEngine);
  FLoadList.Parent := PL;
  FLoadList.AlignWithMargins := True;
  FLoadList.Margins.SetBounds(8, 24, 8, 14);   // unten Platz fuer die Schrauben
  FLoadList.Align := alClient;
  FLoadList.Font.Assign(Font);
  PR := MakePanel(Area, alClient, Tr('Rechenzeit (gemessen)'));
  FLoadGauge := TLoadGauge.Create(Self);
  FLoadGauge.Parent := PR;
  FLoadGauge.SetBounds(8, 24, 380, 290);
  FLoadGauge.Font.Assign(Font);
  FLoadGauge.Hint := Tr('Nadel: Rechenzeit des Plugins (Anteil eines Kerns, Mittel je Sekunde). ' +
    'Bernsteinmarke: längster Aufruf im Verhältnis zur Pufferdauer.');
  FLoadGauge.ShowHint := True;
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.AutoSize := False;
  L.WordWrap := True;               // erst nach AutoSize := False, sonst schrumpft die Beschriftung
  L.SetBounds(12, 318, 384, 46);
  L.Caption := '';
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  FProcStat := L;
  FProcStat.Hint := Tr('Laufzeit des Plugins (je Sekunde): Aufrufe der DAW, Samples je Aufruf, eigene Rechenzeit ' +
    'in % der Echtzeit (Durchschnitt / längster Aufruf im Verhältnis zur Pufferdauer), Zeit in Rückfragen an die ' +
    'DAW, Thread-Wechsel zwischen den Aufrufen.');
  FProcStat.ShowHint := True;
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.SetBounds(12, 366, 384, 52);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Gemessen wird nur, solange dieser Reiter offen ist. FL Studio: Optionen > Audio > ' +
    '"Multithreaded generator processing" verteilt Instanzen auf mehrere Kerne. Weniger Last: Mischpult > Leistung.');  // Rendern: beim Export (offline) HQ und volle Stimmenzahl, egal wie sparsam live eingestellt
  AddParam(PR, Ord(gpRenderHQ), 400, 30, 0, 0, 0, Tr('Rendern in Höchstqualität'));
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.SetBounds(404, 30 + ROW_H, 230, 86);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('An: Beim Export/Rendern der DAW (nicht in Echtzeit) rechnet GranularSynth immer mit HQ und ' +
    'voller Stimmen- und Grainzahl - live darf es sparsam sein, die Datei klingt trotzdem bestmöglich.');
  // Oversampling: gehoert zum Rechner (wie die Leistungsstufe), wirkt nur bei HQ
  AddParam(PR, Ord(gpOversample), 400, 150, 0, 0, 0, Tr('Oversampling 2x (bei HQ)'));
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.SetBounds(404, 150 + ROW_H, 230, 100);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('An (Standard): Oszillatoren und Sättigung rechnen intern mit doppelter Abtastrate. ' +
    'Harte FM-, Sync- und Drive-Klänge bleiben sauber, ohne metallische Spiegelfrequenzen. Kostet etwas mehr Rechenzeit.');
  // Oszillator-Modell: aus = Wavetable (bandbegrenzt, Standard), an = klassisch (bitgenau wie bis 2.9)
  AddParam(PR, Ord(gpOscModel), 400, 284, 0, 0, 0, Tr('Klassische Oszillatoren (bis 2.9)'));
  L := TLabel.Create(Self);
  L.Parent := PR;
  L.SetBounds(404, 284 + ROW_H, 230, 86);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption := Tr('Aus (Standard): Dreieck, Säge und Rechteck kommen bandbegrenzt aus Wavetables - sauberer, ' +
    'ohne Oversampling. An: genau der Klang bis Version 2.9, nur für alte Projekte.');
end;

{ --- Reiter EQ --- }

procedure TGranularEditor.BuildEqTab;
const
  NAMES: array[0..5] of string = ('Linear', 'Wärmer', 'Heller', 'Präsenz', 'Telefon', 'Loudness');
  EQ_C1 = 110;          // Spalte Baesse / Band A
  EQ_C2 = 520;          // Spalte Hoehen / Band B
var
  Area, Top, PS, PC: TPanel;
  I: Integer;
  B: TButton;
  L: TLabel;
begin
  Area := TPanel.Create(Self);
  Area.Parent := FTabEq;
  Area.Align := alClient;
  Area.BevelOuter := bvNone;
  Area.ParentBackground := False;
  Area.Color := AREA_BG;
  // Summe = Ende der Kette (alle Noten zusammen): Saettigung, EQ, Stereo, Limiter, Master
  PS := MakePanel(Area, alRight, Tr('Sättigung, Stereo, Ausgang'));   // rechts; die EQ-Kurve sitzt links
  PS.Width := 330;
  AddParam(PS, Ord(gpDrive), 8, 24, 100, 62);
  AddParam(PS, Ord(gpDriveType), 8, 24 + ROW_H, 100, 0, 100, Tr('Art'));
  AddParam(PS, Ord(gpWidth), 8, 24 + 2 * ROW_H, 100, 62, 0, Tr('Stereobreite'));
  AddParam(PS, Ord(gpPan), 8, 24 + 3 * ROW_H, 100, 62, 0, Tr('Panorama'));
  AddParam(PS, Ord(gpBassMonoOn), 8, 24 + 4 * ROW_H, 100, 0, 0, Tr('Bass mono'));
  AddParam(PS, Ord(gpBassMonoFreq), 8, 24 + 5 * ROW_H, 100, 62, 0, Tr('mono bis'));
  AddParam(PS, Ord(gpLimiter), 8, 24 + 6 * ROW_H, 100, 0, 0);
  AddParam(PS, Ord(gpQuality), 8, 24 + 7 * ROW_H, 100, 0, 100);
  AddParam(PS, Ord(gpMaster), 8, 24 + 8 * ROW_H, 100, 62, 0, Tr('Master'));
  // Signalweg und Arten stehen in Tooltip und Hilfe (die Spalte ist voll)

  // Kompressor: eigene Spalte links neben der Ausgangs-Spalte (Signalweg EQ -> Kompressor -> Ausgang)
  PC := MakePanel(Area, alRight, Tr('Kompressor (drei Bänder)'));
  PC.Width := 330;
  PC.Left := PS.Left - 1;
  AddParam(PC, Ord(gpCompOn), 8, 24, 100, 0, 0, Tr('Kompressor an'));
  AddParam(PC, Ord(gpCompAmt), 8, 24 + ROW_H, 100, 62, 0, Tr('Menge'));
  AddParam(PC, Ord(gpCompTime), 8, 24 + 2 * ROW_H, 100, 62, 0, Tr('Tempo'));
  AddParam(PC, Ord(gpCompRatio), 8, 24 + 3 * ROW_H, 100, 62, 0, Tr('Verhältnis'));
  AddParam(PC, Ord(gpCompThresh), 8, 24 + 4 * ROW_H, 100, 62, 0, Tr('Schwelle'));
  AddParam(PC, Ord(gpCompKnee), 8, 24 + 5 * ROW_H, 100, 62, 0, Tr('Knick'));
  FCompCurve := TCompCurveView.Create(Self);
  FCompCurve.Engine := FEngine;
  FCompCurve.Parent := PC;
  FCompCurve.SetBounds(8, 24 + 6 * ROW_H + 4, 312, 86);
  FCompCurve.Hint := Tr('Kennlinie: waagrecht der Eingangspegel, senkrecht der Ausgang (je Band). Gestrichelt = ' +
    'unverändert, gelb = Schwelle. Unter der Schwelle 1:1, darüber flacher (Verhältnis); erst 24 dB unter ' +
    'der Schwelle werden leise Anteile angehoben. Der Knick rundet die Ecken ab.');
  FCompCurve.ShowHint := True;
  AddStretch(FCompCurve, 8);
  Top := MakePanel(Area, alTop, Tr('Equalizer (Kurve mit der Maus zeichnen, rechte Taste = 0 dB)'));
  Top.Height := 112;
  AddParam(Top, Ord(gpEqOn), 8, 24, 0, 0, 0, Tr('EQ an'));
  // Raster: Baesse ueber Band A, Hoehen ueber Band B; gleiche Schienenlaengen, Werte untereinander
  AddParam(Top, Ord(gpEqBass), EQ_C1, 24, 60, 62, 0, Tr('Bässe'), 110);
  AddParam(Top, Ord(gpEqTreble), EQ_C2, 24, 60, 62, 0, Tr('Höhen'), 110);
  AddParam(Top, Ord(gpEqAFreq), EQ_C1, 52, 60, 62, 0, Tr('Band A'), 110);
  AddParam(Top, Ord(gpEqAGain), EQ_C1 + 240, 52, 0, 56, 0, '', 110);
  AddParam(Top, Ord(gpEqBFreq), EQ_C2, 52, 60, 62, 0, Tr('Band B'), 110);
  AddParam(Top, Ord(gpEqBGain), EQ_C2 + 240, 52, 0, 56, 0, '', 110);
  for I := 0 to High(NAMES) do
  begin
    B := TButton.Create(Self);
    B.Parent := Top;
    B.SetBounds(14 + I * 82, 82, 76, 23);   // Ecke frei fuer die Schraube
    B.Caption := NAMES[I];
    B.Tag := I;
    B.TabStop := False;
    B.OnClick := EqPresetClick;
  end;
  L := TLabel.Create(Self);
  L.Parent := Top;
  L.SetBounds(8 + 6 * 82 + 8, 86, 400, 16);
  L.Caption := Tr('Bänder A/B, Bässe, Höhen: Matrix-Ziele (z.B. Sidechain 2 duckt Band A).');
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  FEqView := TEqView.Create(Self, FEngine);
  FEqView.Spectrum := FSpectrum;     // Filteransicht leuchtet mit dem Ausgangsspektrum (Schnell-Tab ist schon gebaut)
  FEqView.Parent := Area;
  FEqView.Align := alClient;
  FEqView.AlignWithMargins := True;
  FEqView.Margins.SetBounds(8, 4, 8, 8);
end;

procedure TGranularEditor.EqPresetClick(Sender: TObject);
var
  I: Integer;
  F, G: Double;
  C: PEqCurve;
begin
  C := FEngine.EqCurve;
  for I := 0 to EQ_CURVE_N - 1 do
  begin
    F := EQ_F_MIN * Power(EQ_F_MAX / EQ_F_MIN, I / (EQ_CURVE_N - 1));
    case (Sender as TComponent).Tag of
      1: G := 3 * Exp(-Sqr(Ln(F / 200) / 1.1)) - 2.5 * Exp(-Sqr(Ln(F / 6000) / 1.2));   // waermer
      2: G := 4 * Exp(-Sqr(Ln(F / 9000) / 1.0)) - 1.5 * Exp(-Sqr(Ln(F / 250) / 1.0));    // heller
      3: G := 4 * Exp(-Sqr(Ln(F / 2500) / 0.6));                                          // Praesenz
      4: G := IfThen((F < 400) or (F > 3500), -15, 4 * Exp(-Sqr(Ln(F / 1200) / 0.5)));    // Telefon
      5: G := 6 * Exp(-Sqr(Ln(F / 60) / 0.9)) + 4 * Exp(-Sqr(Ln(F / 12000) / 0.9));       // Loudness
    else
      G := 0;
    end;
    C[I] := EnsureRange(G, -EQ_MAX_DB, EQ_MAX_DB);
  end;
  FEngine.EqChanged;
  if (Sender as TComponent).Tag > 0 then
    FEngine.SetParamById(gpEqOn, 1);
  UpdateFromEngine;
  FEqView.Invalidate;
end;

{ --- Matrix-Combos mit Eingabe --- }

procedure TGranularEditor.SortDestCombo(var B: TParamBinding);
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 1 to B.Combo.Items.Count - 1 do
      L.AddObject(B.Combo.Items[I], TObject(I));
    L.CaseSensitive := False;
    L.Sort;
    SetLength(B.StepOfItem, B.Combo.Items.Count);
    B.StepOfItem[0] := 0;
    B.Combo.Items.BeginUpdate;
    try
      B.Combo.Items.Clear;
      B.Combo.Items.Add(Tr(StepName(B.Index, 0)));      // "Aus" zuerst
      for I := 0 to L.Count - 1 do
      begin
        B.Combo.Items.Add(L[I]);
        B.StepOfItem[I + 1] := Integer(L.Objects[I]);
      end;
    finally
      B.Combo.Items.EndUpdate;
    end;
  finally
    L.Free;
  end;
end;

function TGranularEditor.ComboStepOfItem(const B: TParamBinding; Item: Integer): Integer;
begin
  if (Length(B.StepOfItem) > 0) and (Item >= 0) and (Item <= High(B.StepOfItem)) then
    Result := B.StepOfItem[Item]
  else
    Result := Item;
end;

function TGranularEditor.ComboItemOfStep(const B: TParamBinding; Step: Integer): Integer;
var
  I: Integer;
begin
  if Length(B.StepOfItem) = 0 then
    Exit(Step);
  for I := 0 to High(B.StepOfItem) do
    if B.StepOfItem[I] = Step then
      Exit(I);
  Result := -1;
end;

procedure TGranularEditor.MatrixComboValidate(C: TComboBox);
var
  B: TParamBinding;
  T: string;
  I, Found: Integer;
begin
  B := FBindings[C.Tag];
  T := Trim(C.Text);
  Found := -1;
  // genau, dann Anfang, dann irgendwo enthalten (ohne Gross/Klein)
  for I := 0 to C.Items.Count - 1 do
    if SameText(C.Items[I], T) then
    begin
      Found := I;
      Break;
    end;
  if (Found < 0) and (T <> '') then
    for I := 0 to C.Items.Count - 1 do
      if StartsText(T, C.Items[I]) then
      begin
        Found := I;
        Break;
      end;
  if (Found < 0) and (T <> '') then
    for I := 0 to C.Items.Count - 1 do
      if ContainsText(C.Items[I], T) then
      begin
        Found := I;
        Break;
      end;
  if Found >= 0 then
    Found := ComboStepOfItem(B, Found);
  if Found >= 0 then
  begin
    if ParamStep(B.Index, FEngine.GetParam(B.Index)) <> Found then
    begin
      FEngine.SetParam(B.Index, StepToParam(B.Index, Found));
      ParamChangedByUser(B.Index);
    end;
  end;
  // Anzeige immer auf den (neuen oder alten) gueltigen Wert setzen
  SetControlValue(C.Tag, FEngine.GetParam(B.Index));
end;

procedure TGranularEditor.MatrixComboExit(Sender: TObject);
begin
  MatrixComboValidate(Sender as TComboBox);
end;

procedure TGranularEditor.MatrixComboKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    MatrixComboValidate(Sender as TComboBox);
    (Sender as TComboBox).SelectAll;
    Key := 0;
  end
  else if Key = VK_ESCAPE then
  begin
    SetControlValue((Sender as TComboBox).Tag, FEngine.GetParam(FBindings[(Sender as TComboBox).Tag].Index));
    Key := 0;
  end;
end;

{ --- Reiter Frei-LFO --- }

procedure TGranularEditor.LfoViewClick(Sender: TObject);
var
  T: Integer;
begin
  T := (Sender as TComponent).Tag;
  OpenFreeEditor(LFO_FREE_IDX[T]);   // LFO -> Platz der freien Form (2 = Morph-LFO)
end;

procedure TGranularEditor.FreeTimerTick(Sender: TObject);
var
  K: Integer;
begin
  for K := 0 to 4 do
    if FFreeView[K] <> nil then
      FFreeView[K].Tick;   // zeichnet nur, wenn die Abspielmarke weiterrueckt
end;

const
  NOTE_NAMES_DE: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'H');

{ Werkzeugfenster fuer die Form "Frei" eines LFOs (nicht modal, bleibt vorn): Aenderungen wirken
  sofort und sind beim Spielen live zu hoeren - Engine-Daten werden direkt bearbeitet, Klaviatur
  und PC-Tasten bleiben bedienbar. Die LFO-Anzeige im Modulations-Reiter zeigt die Form mit. }
procedure TGranularEditor.OpenFreeEditor(K: Integer);
var
  Frm: TForm;
  P: TPanel;
  L: TLabel;
  I: Integer;
  Tmr: TTimer;

  function Btn(const ACaption: string; ARight, AWidth: Integer; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Frm);
    Result.Parent := P;
    Result.SetBounds(P.ClientWidth - ARight - AWidth, 22, AWidth, 25);
    Result.Anchors := [akTop, akRight];
    Result.Caption := ACaption;
    Result.Tag := K;
    Result.OnClick := AClick;
    Result.TabStop := False;
  end;

begin
  if FFreeForm[K] <> nil then
  begin
    FFreeForm[K].BringToFront;
    Exit;
  end;
  Frm := TForm.CreateNew(Self);
  FFreeForm[K] := Frm;
  Frm.Tag := K;
  Frm.OnClose := FreeFormClose;
  Frm.OnKeyDown := FreeFormKeyDown;
  Frm.OnKeyUp := FreeFormKeyUp;
  Frm.FormStyle := fsStayOnTop;
  begin
    if K = 2 then Frm.Caption := Tr('Morph-LFO - freie Form')
    else Frm.Caption := Format(Tr('LFO %d - freie Form'), [LfoOfFree(K) + 1]);
    Frm.BorderStyle := bsSizeToolWin;
    Frm.BorderIcons := [biSystemMenu];
    Frm.Position := poScreenCenter;
    Frm.ClientWidth := 990;
    Frm.ClientHeight := 440;
    Frm.Constraints.MinWidth := 880;
    Frm.Constraints.MinHeight := 300;
    Frm.Color := BG_MAIN;
    Frm.Font.Assign(Font);
    Frm.KeyPreview := True;

    P := TPanel.Create(Frm);
    P.Parent := Frm;
    P.Align := alClient;
    P.BevelOuter := bvNone;
    P.ParentBackground := False;
    P.Color := BG_MAIN;

    L := TLabel.Create(Frm);
    L.Parent := P;
    L.SetBounds(8, 4, 400, 16);
    if K = 2 then L.Caption := Tr('Morph-LFO  -  Form "Frei" (Ausschlag = Morph A <-> B)')
    else if K > 2 then L.Caption := Format(Tr('LFO %d  -  Form "Frei"'), [LfoOfFree(K) + 1])
    else L.Caption := Format(Tr('LFO %d  -  Form "Frei"'), [K + 1]);
    L.Font.Color := COL_VAL;
    L.Font.Style := [fsBold];
    L.Transparent := True;

    FFreeMode[K] := TComboBox.Create(Frm);
    FFreeMode[K].Parent := P;
    FFreeMode[K].Style := csDropDownList;
    FFreeMode[K].SetBounds(8, 23, 132, 21);
    for I := 0 to High(FREE_MODE_NAMES) do
      FFreeMode[K].Items.Add(Tr(FREE_MODE_NAMES[I]));
    FFreeMode[K].Tag := K;
    FFreeMode[K].TabStop := False;
    FFreeMode[K].OnChange := FreeModeChange;
    EnableComboFit(FFreeMode[K]);

    L := TLabel.Create(Frm);
    L.Parent := P;
    L.SetBounds(150, 26, 40, 16);
    L.Caption := Tr('Stufen');
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    FFreeSteps[K] := TTrackBar.Create(Frm);
    FFreeSteps[K].Parent := P;
    FFreeSteps[K].SetBounds(190, 22, 150, 26);
    FFreeSteps[K].Min := 1;
    FFreeSteps[K].Max := FREE_MAX_STEPS;
    FFreeSteps[K].TickStyle := tsNone;
    FFreeSteps[K].ThumbLength := 16;
    FFreeSteps[K].Tag := K;
    FFreeSteps[K].TabStop := False;
    FFreeSteps[K].OnChange := FreeStepsChange;
    FFreeStepsLbl[K] := TLabel.Create(Frm);
    FFreeStepsLbl[K].Parent := P;
    FFreeStepsLbl[K].SetBounds(344, 26, 30, 16);
    FFreeStepsLbl[K].Font.Color := COL_VAL;
    FFreeStepsLbl[K].Transparent := True;

    FFreeRange[K] := TComboBox.Create(Frm);
    FFreeRange[K].Parent := P;
    FFreeRange[K].Style := csDropDownList;
    FFreeRange[K].SetBounds(380, 23, 104, 21);
    FFreeRange[K].Items.Add(Tr('Anzeige +/-12'));
    FFreeRange[K].Items.Add(Tr('Anzeige +/-24'));
    FFreeRange[K].ItemIndex := 0;
    FFreeRange[K].Tag := K;
    FFreeRange[K].TabStop := False;
    FFreeRange[K].OnChange := FreeRangeChange;

    // zweite Zeile: Glaettung (weiche Uebergaenge zwischen den Stufen) und Bezugston der Klaviatur
    L := TLabel.Create(Frm);
    L.Parent := P;
    L.SetBounds(8, 58, 70, 16);
    L.Caption := Tr('Glättung');
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    FFreeSmooth[K] := TTrackBar.Create(Frm);
    FFreeSmooth[K].Parent := P;
    FFreeSmooth[K].SetBounds(80, 54, 200, 26);
    FFreeSmooth[K].Min := 0;
    FFreeSmooth[K].Max := 100;
    FFreeSmooth[K].TickStyle := tsNone;
    FFreeSmooth[K].ThumbLength := 16;
    FFreeSmooth[K].Tag := K;
    FFreeSmooth[K].TabStop := False;
    FFreeSmooth[K].OnChange := FreeSmoothChange;
    FFreeSmooth[K].Hint := Tr('Glättung: 0 % = harte Stufen (jeder Ton steht), wenig = kurzes Gleiten von Ton zu Ton, ' +
      '100 % = runde Kurve durch alle Werte.');
    FFreeSmooth[K].ShowHint := True;
    FFreeSmoothLbl[K] := TLabel.Create(Frm);
    FFreeSmoothLbl[K].Parent := P;
    FFreeSmoothLbl[K].SetBounds(284, 58, 40, 16);
    FFreeSmoothLbl[K].Font.Color := COL_VAL;
    FFreeSmoothLbl[K].Transparent := True;
    L := TLabel.Create(Frm);
    L.Parent := P;
    L.SetBounds(340, 58, 90, 16);
    L.Caption := Tr('Bezugston');
    L.Font.Color := COL_NAME;
    L.Transparent := True;
    FFreeRoot[K] := TComboBox.Create(Frm);
    FFreeRoot[K].Parent := P;
    FFreeRoot[K].Style := csDropDownList;
    FFreeRoot[K].SetBounds(430, 55, 54, 21);
    for I := 0 to 11 do
      FFreeRoot[K].Items.Add(NOTE_NAMES_DE[I]);
    if LangCode <> 'de' then
      FFreeRoot[K].Items[11] := 'B';
    FFreeRoot[K].ItemIndex := 0;
    FFreeRoot[K].Tag := K;
    FFreeRoot[K].TabStop := False;
    FFreeRoot[K].OnChange := FreeRootChange;
    FFreeRoot[K].Hint := Tr('Bezugston: die Taste, die du spielst. Die Klaviatur links benennt die Stufen danach ' +
      '(nur Anzeige, der Klang ändert sich nicht).');
    FFreeRoot[K].ShowHint := True;

    Btn(Tr('Zurücksetzen'), 8, 92, FreeResetClick);
    Btn(Tr('Werte mitteln'), 104, 96, FreeSmoothClick);
    Btn(Tr('Form = Frei'), 312, 80, FreeActivateClick);
    if K <> 2 then
    begin
      Btn(Tr('Auf Pitch legen'), 204, 104, FreePitchClick);
      Btn(Tr('Auf Gate legen'), 396, 100, FreeGateClick);
    end;

    L := TLabel.Create(Frm);
    L.Parent := P;
    L.Align := alBottom;
    L.AlignWithMargins := True;
    L.Margins.SetBounds(10, 2, 10, 6);
    L.AutoSize := False;
    L.Height := 72;
    L.WordWrap := True;
    L.Font.Color := $00A0A0A0;
    L.Transparent := True;
    L.Caption :=
      Tr('Ziehen setzt Werte (auch über mehrere Stufen), Rechtsklick setzt 0, Mausrad = +/- 1 Halbton. ' +
      '"Auf Pitch legen" stellt Form Frei, Neustart bei Note an und einen Matrix-Slot LFO -> Pitch ' +
      '(Menge 50 %, Faktor x1) ein: jede Stufe trifft genau ihren Halbton, jede Note spielt die Folge von vorn. ' +
      'Rate/Sync gilt für einen ganzen Durchlauf. Klaviatur links: welche Note eine Stufe spielt (Bezugston = gespielte Taste). ' +
      'Glättung: weiche Übergänge, die helle Linie zeigt den echten Verlauf. Leiste „Gleiten“ unten: Klick lässt eine Stufe ' +
      'vom vorigen Ton herübergleiten (wie Slide am Sequencer). Änderungen wirken sofort.');

    FFreeView[K] := TFreeLfoView.Create(Frm, FEngine, K);
    FFreeView[K].Parent := P;
    FFreeView[K].Hint := Tr('Linksklick: Stufe setzen (Ziehen zeichnet). Rechtsklick: Pause an/aus. Leiste unten: Gleiten');
    FFreeView[K].ShowHint := True;
    FFreeView[K].SetBounds(8, 84, P.ClientWidth - 16, P.ClientHeight - 84 - 76);
    FFreeView[K].Anchors := [akLeft, akTop, akRight, akBottom];

    Tmr := TTimer.Create(Frm);
    Tmr.Interval := 33;
    Tmr.OnTimer := FreeTimerTick;

    SyncFreeUi;
    UiScaleForm(Frm);
    Frm.Show;
  end;
end;

{ --- Fenster "Welle zeichnen": eine Periode frei zeichnen, Grundformen, Glaettung (nicht modal, wirkt sofort) --- }

procedure TGranularEditor.WaveEditClick(Sender: TObject);
begin
  OpenWaveEditor((Sender as TComponent).Tag);
end;

procedure TGranularEditor.OpenWaveEditor(O: Integer);
const
  SHAPES: array[0..6] of string = ('Sinus', 'Dreieck', 'Säge', 'Rechteck', 'Puls 25 %', 'Zufall', 'Umkehren');
var
  Frm: TForm;
  P: TPanel;
  L: TLabel;
  I: Integer;
  B: TButton;
begin
  if FWaveForm[O] <> nil then
  begin
    FWaveForm[O].BringToFront;
    Exit;
  end;
  Frm := TForm.CreateNew(Self);
  FWaveForm[O] := Frm;
  Frm.Tag := O;
  Frm.OnClose := WaveFormClose;
  Frm.OnKeyDown := FreeFormKeyDown;
  Frm.OnKeyUp := FreeFormKeyUp;
  Frm.KeyPreview := True;
  Frm.FormStyle := fsStayOnTop;
  Frm.Caption := Format(Tr('Osz %d - Welle zeichnen'), [O + 1]);
  Frm.BorderStyle := bsSizeToolWin;
  Frm.BorderIcons := [biSystemMenu];
  Frm.Position := poScreenCenter;
  Frm.ClientWidth := 820;
  Frm.ClientHeight := 400;
  Frm.Constraints.MinWidth := 700;
  Frm.Constraints.MinHeight := 300;
  Frm.Color := BG_MAIN;
  Frm.Font.Assign(Font);

  P := TPanel.Create(Frm);
  P.Parent := Frm;
  P.Align := alClient;
  P.BevelOuter := bvNone;
  P.ParentBackground := False;
  P.Color := BG_MAIN;

  // Grundformen als Ausgangspunkt
  for I := 0 to High(SHAPES) do
  begin
    B := TButton.Create(Frm);
    B.Parent := P;
    B.SetBounds(8 + I * 100, 8, 94, 25);
    B.Caption := Tr(SHAPES[I]);
    B.Tag := O * 100 + I;
    B.TabStop := False;
    B.OnClick := WaveShapeClick;
  end;

  L := TLabel.Create(Frm);
  L.Parent := P;
  L.SetBounds(8, 46, 70, 16);
  L.Caption := Tr('Glättung');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  FWaveSmooth[O] := TTrackBar.Create(Frm);
  FWaveSmooth[O].Parent := P;
  FWaveSmooth[O].SetBounds(80, 42, 200, 26);
  FWaveSmooth[O].Min := 0;
  FWaveSmooth[O].Max := 100;
  FWaveSmooth[O].TickStyle := tsNone;
  FWaveSmooth[O].ThumbLength := 16;
  FWaveSmooth[O].Tag := O;
  FWaveSmooth[O].TabStop := False;
  FWaveSmooth[O].Position := Round(FEngine.OscDraw[O].Smooth * 100);
  FWaveSmooth[O].OnChange := WaveSmoothChange;
  FWaveSmooth[O].Hint := Tr('Glättung: rundet die Obertöne der Zeichnung ab. 0 % = genau die gezeichnete Form, ' +
    '100 % = fast ein Sinus. Die helle Linie zeigt, was der Oszillator spielt.');
  FWaveSmooth[O].ShowHint := True;
  FWaveSmoothLbl[O] := TLabel.Create(Frm);
  FWaveSmoothLbl[O].Parent := P;
  FWaveSmoothLbl[O].SetBounds(284, 46, 40, 16);
  FWaveSmoothLbl[O].Font.Color := COL_VAL;
  FWaveSmoothLbl[O].Transparent := True;
  FWaveSmoothLbl[O].Caption := IntToStr(FWaveSmooth[O].Position) + ' %';
  FWaveUse[O] := TCheckBox.Create(Frm);
  FWaveUse[O].Parent := P;
  FWaveUse[O].SetBounds(340, 44, 300, 20);
  FWaveUse[O].Caption := Format(Tr('Oszillator %d spielt die gezeichnete Welle'), [O + 1]);
  FWaveUse[O].Checked := FEngine.GetParam(Ord(OSC_P[O].Draw)) >= 0.5;
  FWaveUse[O].Tag := O;
  FWaveUse[O].TabStop := False;
  FWaveUse[O].OnClick := WaveUseClick;

  L := TLabel.Create(Frm);
  L.Parent := P;
  L.Align := alBottom;
  L.AlignWithMargins := True;
  L.Margins.SetBounds(10, 2, 10, 6);
  L.AutoSize := False;
  L.Height := 56;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Ziehen zeichnet eine Periode der Welle, Rechtsklick setzt 0. Bernstein = deine Zeichnung, hell = was der ' +
    'Oszillator spielt: bandbegrenzt (keine Spiegelfrequenzen, auch in hohen Lagen) und mit Glättung. ' +
    'Sync, Unison, Hüllkurve und Filter wirken wie bei den anderen Wellen; wird mit dem Preset gespeichert.');

  FWaveView[O] := TOscWaveView.Create(Frm, FEngine, O);
  FWaveView[O].Parent := P;
  FWaveView[O].SetBounds(8, 76, P.ClientWidth - 16, P.ClientHeight - 76 - 64);
  FWaveView[O].Anchors := [akLeft, akTop, akRight, akBottom];
  FWaveView[O].Tag := O;
  FWaveView[O].OnChange := WaveViewChange;
  UiScaleForm(Frm);
  Frm.Show;
end;

procedure TGranularEditor.WaveFormClose(Sender: TObject; var Action: TCloseAction);
var
  O: Integer;
begin
  O := (Sender as TForm).Tag;
  FWaveView[O] := nil;
  FWaveSmooth[O] := nil;
  FWaveSmoothLbl[O] := nil;
  FWaveUse[O] := nil;
  FWaveForm[O] := nil;
  Action := caFree;
end;

{ Tabellen neu rechnen; beim Zeichnen den Oszillator auf "Gezeichnet" stellen (man will hoeren, was man malt) }
procedure TGranularEditor.WaveChanged(O: Integer; TurnOn: Boolean);
begin
  FEngine.OscDrawChanged(O);
  if TurnOn and (FEngine.GetParam(Ord(OSC_P[O].Draw)) < 0.5) then
  begin
    FEngine.SetParamById(OSC_P[O].Draw, 1);
    if FEngine.GetParam(Ord(OSC_P[O].On_)) < 0.5 then
      FEngine.SetParamById(OSC_P[O].On_, 1);
    UpdateFromEngine;
  end;
  if FWaveUse[O] <> nil then
  begin
    FUpdating := True;
    try
      FWaveUse[O].Checked := FEngine.GetParam(Ord(OSC_P[O].Draw)) >= 0.5;
    finally
      FUpdating := False;
    end;
  end;
  if FWaveView[O] <> nil then
    FWaveView[O].Invalidate;
end;

procedure TGranularEditor.WaveViewChange(Sender: TObject);
begin
  WaveChanged((Sender as TComponent).Tag, True);
end;

procedure TGranularEditor.WaveShapeClick(Sender: TObject);
var
  O, K, I: Integer;
  D: POscDraw;
  X: Double;
begin
  O := (Sender as TComponent).Tag div 100;
  K := (Sender as TComponent).Tag mod 100;
  D := FEngine.OscDraw[O];
  for I := 0 to OSC_DRAW_N - 1 do
  begin
    X := I / OSC_DRAW_N;
    case K of
      0: D.Pt[I] := Sin(2 * Pi * X);
      1: if X < 0.25 then D.Pt[I] := 4 * X else if X < 0.75 then D.Pt[I] := 2 - 4 * X else D.Pt[I] := 4 * X - 4;
      2: D.Pt[I] := 1 - 2 * X;
      3: if X < 0.5 then D.Pt[I] := 1 else D.Pt[I] := -1;
      4: if X < 0.25 then D.Pt[I] := 1 else D.Pt[I] := -1;
      5: D.Pt[I] := EnsureRange(D.Pt[I] * 0.5 + (Random * 2 - 1) * 0.5, -1, 1);   // Zufall: aufrauen, Form bleibt erkennbar
      6: D.Pt[I] := -D.Pt[I];
    end;
  end;
  WaveChanged(O, True);
end;

procedure TGranularEditor.WaveSmoothChange(Sender: TObject);
var
  O: Integer;
begin
  O := (Sender as TComponent).Tag;
  FEngine.OscDraw[O].Smooth := FWaveSmooth[O].Position / 100;
  FWaveSmoothLbl[O].Caption := IntToStr(FWaveSmooth[O].Position) + ' %';
  WaveChanged(O, False);
end;

procedure TGranularEditor.WaveUseClick(Sender: TObject);
var
  O: Integer;
begin
  if FUpdating then
    Exit;
  O := (Sender as TComponent).Tag;
  FEngine.SetParamById(OSC_P[O].Draw, Ord(FWaveUse[O].Checked));
  UpdateFromEngine;
end;

procedure TGranularEditor.FreeFormClose(Sender: TObject; var Action: TCloseAction);
var
  K: Integer;
begin
  K := (Sender as TForm).Tag;
  FFreeView[K] := nil;
  FFreeMode[K] := nil;
  FFreeRange[K] := nil;
  FFreeSteps[K] := nil;
  FFreeStepsLbl[K] := nil;
  FFreeSmooth[K] := nil;
  FFreeSmoothLbl[K] := nil;
  FFreeRoot[K] := nil;
  FFreeForm[K] := nil;
  Action := caFree;
  if LfoOfFree(K) >= 0 then
    FLfoViews[LfoOfFree(K)].ForceFullInvalidate;
end;

procedure TGranularEditor.FreeFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    (Sender as TForm).Close
  else if HandleKeyDown(Key, Shift) then
    Key := 0;   // Notentasten spielen auch bei offenem Fenster
end;

procedure TGranularEditor.FreeFormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if HandleKeyUp(Key) then
    Key := 0;
end;

procedure TGranularEditor.SyncFreeUi;
var
  K: Integer;
  F: PFreeLfo;
begin
  FUpdating := True;
  try
    for K := 0 to FREE_LFO_COUNT - 1 do
    begin
      if FFreeView[K] = nil then
        Continue;
      F := FEngine.FreeLfo[K];
      FFreeMode[K].ItemIndex := EnsureRange(F.Mode, 0, 2);
      FFreeSteps[K].Position := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
      FFreeStepsLbl[K].Caption := IntToStr(FFreeSteps[K].Position);
      FFreeSteps[K].Enabled := F.Mode <> 2;
      FFreeRange[K].Enabled := F.Mode = 0;
      FFreeRoot[K].Enabled := F.Mode = 0;
      FFreeSmooth[K].Position := Round(EnsureRange(F.Smooth, 0, 1) * 100);
      FFreeSmooth[K].Enabled := F.Mode <> 2;
      FFreeSmoothLbl[K].Caption := IntToStr(FFreeSmooth[K].Position) + ' %';
      FFreeView[K].Rebuild;
    end;
  finally
    FUpdating := False;
  end;
end;

procedure TGranularEditor.FreeModeChange(Sender: TObject);
var
  K, I: Integer;
  F: PFreeLfo;
begin
  if FUpdating then
    Exit;
  K := (Sender as TComponent).Tag;
  F := FEngine.FreeLfo[K];
  F.Mode := FFreeMode[K].ItemIndex;
  // beim Wechsel auf Halbtoene vorhandene Stufen auf das Raster ziehen
  if F.Mode = 0 then
    for I := 0 to FREE_MAX_STEPS - 1 do
      F.Step[I] := FreeQuantize(F.Step[I]);
  SyncFreeUi;
end;

procedure TGranularEditor.FreeRangeChange(Sender: TObject);
var
  K: Integer;
begin
  K := (Sender as TComponent).Tag;
  if FFreeRange[K].ItemIndex = 1 then
    FFreeView[K].Range := 24
  else
    FFreeView[K].Range := 12;
end;

procedure TGranularEditor.FreeStepsChange(Sender: TObject);
var
  K: Integer;
begin
  if FUpdating then
    Exit;
  K := (Sender as TComponent).Tag;
  FEngine.FreeLfo[K].Steps := FFreeSteps[K].Position;
  FFreeStepsLbl[K].Caption := IntToStr(FFreeSteps[K].Position);
  FFreeView[K].Rebuild;
end;

procedure TGranularEditor.FreeActivateClick(Sender: TObject);
var
  K: Integer;
begin
  K := (Sender as TComponent).Tag;
  if K = 2 then
    FEngine.SetParamById(gpMorphLfoShape, StepToParam(Ord(gpMorphLfoShape), MORPH_LFO_FREE))
  else
    FEngine.SetParamById(LFO_SHAPE_IDS[LfoOfFree(K)], StepToParam(Ord(LFO_SHAPE_IDS[LfoOfFree(K)]), LFO_SHAPE_FREE));
  UpdateFromEngine;
end;

procedure TGranularEditor.FreePitchClick(Sender: TObject);
var
  K, LK, S, Slot, Src, Dst, F1: Integer;
begin
  K := (Sender as TComponent).Tag;
  LK := LfoOfFree(K);
  PushUndo;
  FEngine.SetParam(Ord(LFO_SHAPE_IDS[LK]), StepToParam(Ord(LFO_SHAPE_IDS[LK]), LFO_SHAPE_FREE));
  FEngine.SetParam(Ord(LFO_TRIG_IDS[LK]), StepToParam(Ord(LFO_TRIG_IDS[LK]), 1));   // Neustart bei Note an
  if FEngine.FreeLfo[K].Mode = 2 then
    FEngine.FreeLfo[K].Mode := 0;
  Src := Ord(LFO_SRC[LK]);
  Dst := Ord(gpPitch) + 1;
  // vorhandene Zeile LFO -> Pitch wiederverwenden, sonst die oberste freie
  Slot := SlotFor(Src, Dst);
  if Slot < 0 then
    Slot := MOD_SLOTS - 1;
  F1 := 0;
  for S := 0 to MOD_FACTOR_COUNT - 1 do
    if MOD_FACTORS[S] = 1 then
      F1 := S;
  SetSlot(Slot, Src, Dst, 50, F1);
  // Oszillatoren sollen die Melodie mitspielen (Pitch steuert sonst nur die Grains)
  FEngine.SetParamById(gpOscFollowPitch, 1);
  UpdateFromEngine;
end;

procedure TGranularEditor.FreeSmoothChange(Sender: TObject);
var
  K: Integer;
begin
  if FUpdating then
    Exit;
  K := (Sender as TComponent).Tag;
  FEngine.FreeLfo[K].Smooth := FFreeSmooth[K].Position / 100;
  FFreeSmoothLbl[K].Caption := IntToStr(FFreeSmooth[K].Position) + ' %';
  FFreeView[K].Rebuild;
  if LfoOfFree(K) >= 0 then
    FLfoViews[LfoOfFree(K)].ForceFullInvalidate;
end;

procedure TGranularEditor.FreeRootChange(Sender: TObject);
var
  K: Integer;
begin
  K := (Sender as TComponent).Tag;
  FFreeView[K].Root := FFreeRoot[K].ItemIndex;
end;

procedure TGranularEditor.FreeSmoothClick(Sender: TObject);
var
  K, I, N: Integer;
  F: PFreeLfo;
  Tmp: array[0..FREE_DRAW_N - 1] of Single;
begin
  K := (Sender as TComponent).Tag;
  F := FEngine.FreeLfo[K];
  if F.Mode = 2 then
  begin
    // zyklischer gleitender Mittelwert ueber 5 Punkte (die Kurve bleibt nahtlos)
    for I := 0 to FREE_DRAW_N - 1 do
      Tmp[I] := (F.Draw[(I + FREE_DRAW_N - 2) mod FREE_DRAW_N] + F.Draw[(I + FREE_DRAW_N - 1) mod FREE_DRAW_N] +
        F.Draw[I] + F.Draw[(I + 1) mod FREE_DRAW_N] + F.Draw[(I + 2) mod FREE_DRAW_N]) / 5;
    Move(Tmp[0], F.Draw[0], SizeOf(Tmp));
  end
  else if F.Mode = 1 then
  begin
    N := EnsureRange(F.Steps, 1, FREE_MAX_STEPS);
    for I := 0 to N - 1 do
      Tmp[I] := (F.Step[(I + N - 1) mod N] + 2 * F.Step[I] + F.Step[(I + 1) mod N]) / 4;
    for I := 0 to N - 1 do
      F.Step[I] := Tmp[I];
  end;
  FFreeView[K].Rebuild;
end;

procedure TGranularEditor.FreeResetClick(Sender: TObject);
var
  K, M, N: Integer;
begin
  K := (Sender as TComponent).Tag;
  M := FEngine.FreeLfo[K].Mode;
  N := FEngine.FreeLfo[K].Steps;
  FreeLfoDefault(FEngine.FreeLfo[K]^);
  FEngine.FreeLfo[K].Mode := M;
  FEngine.FreeLfo[K].Steps := N;
  SyncFreeUi;
end;

procedure TGranularEditor.BuildQuickTab;
const
  MACROS: array[0..5] of TGranularParamId =
    (gpMacroTexture, gpMacroMotion, gpMacroBright, gpMacroSpace, gpMacroScatter, gpMacroEnv);
  HINTS: array[0..5] of string = (
    'körnig, dicht  <->  weich, flächig',
    'steht still  <->  wandert und schwebt',
    'dunkel  <->  hell',
    'trocken, schmal  <->  weit mit Echo',
    'geordnet  <->  zufällig',
    'perkussiv  <->  langsam, lang ausklingend');
  SECTION_NAMES: array[TVarySection] of string =
    ('Grains', 'Klang', 'Hüllkurve', 'Modulation', 'Effekte', 'Oszillatoren');
var
  PM, PV: TPanel;
  I, Y: Integer;
  L: TLabel;
  Sec: TVarySection;
  B: TButton;
begin
  // Spektrum unten ueber die ganze Breite
  FSpectrum := TSpectrumView.Create(Self, FEngine);
  FSpectrum.Parent := FTabQuick;
  FSpectrum.Align := alBottom;
  FSpectrum.Height := 120;
  PV := MakePanel(FTabQuick, alClient, Tr('Variieren, Vergleichen, Qualität'));
  FQuickPV := PV;
  PM := MakePanel(FTabQuick, alLeft, Tr('Makros  (50 % = Preset unverändert)'));
  PM.Width := 520;

  for I := 0 to High(MACROS) do
  begin
    Y := 26 + I * 46;
    AddParam(PM, Ord(MACROS[I]), 8, Y, 110, 56);
    L := TLabel.Create(Self);
    L.Parent := PM;
    L.SetBounds(118, Y + 23, 380, 14);   // 1 px hoeher: die letzte Zeile stoesst sonst an den Rand
    L.Caption := HINTS[I];
    L.Font.Color := $00909090;
    L.Transparent := True;
  end;
  B := TButton.Create(Self);
  B.Parent := PM;
  B.SetBounds(118, 26 + 6 * 46 + 4, 150, 25);
  B.Caption := Tr('Makros auf 50 %');
  B.TabStop := False;
  B.OnClick := MacroResetClick;

  // Variieren
  AddParam(PV, Ord(gpQuality), 8, 26, 100, 0, 100);
  AddParam(PV, Ord(gpLimiter), 8, 26 + ROW_H, 100, 0, 0);
  FLimiterLabel := TLabel.Create(Self);
  FLimiterLabel.Parent := PV;
  FLimiterLabel.SetBounds(240, 26 + ROW_H + 5, 200, 16);
  AddParam(PV, Ord(gpMaster), 240, 26, 60, 60, 0, Tr('Master'), 140);
  FLimiterLabel.Font.Color := COL_VAL;
  FLimiterLabel.Transparent := True;

  L := TLabel.Create(Self);
  L.Parent := PV;
  L.SetBounds(8, 26 + 2 * ROW_H + 14, 120, 16);
  L.Caption := Tr('Variieren - Stärke');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  FVaryStrength := TTrackBar.Create(Self);
  FVaryStrength.Parent := PV;
  FVaryStrength.SetBounds(130, 26 + 2 * ROW_H + 10, 180, 24);
  FVaryStrength.TickStyle := tsNone;
  FVaryStrength.ThumbLength := 16;
  FVaryStrength.Max := 100;
  FVaryStrength.Position := 30;
  FVaryStrength.TabStop := False;
  FVaryStyle := TComboBox.Create(Self);
  FVaryStyle.Parent := PV;
  FVaryStyle.Style := csDropDownList;
  FVaryStyle.SetBounds(318, 26 + 2 * ROW_H + 11, 128, 21);
  FVaryStyle.Items.CommaText := Tr('"Stil: frei","Pad / Fläche","Pluck / Zupf","Textur / Wolke","Rhythmisch","Bass"');
  FVaryStyle.ItemIndex := 0;
  FVaryStyle.TabStop := False;
  FVaryStyle.Hint := Tr('Richtung beim Variieren: würfelt nur in Bereichen, die zu diesem Stil passen');
  FVaryStyle.ShowHint := True;
  EnableComboFit(FVaryStyle);

  Y := 26 + 3 * ROW_H + 14;
  L := TLabel.Create(Self);
  L.Parent := PV;
  L.SetBounds(8, Y, 300, 16);
  L.Caption := Tr('Variieren in:');
  L.Font.Color := COL_NAME;
  L.Transparent := True;
  for Sec := Low(TVarySection) to High(TVarySection) do
  begin
    FVaryChecks[Sec] := TCheckBox.Create(Self);
    FVaryChecks[Sec].Parent := PV;
    FVaryChecks[Sec].SetBounds(16 + (Ord(Sec) mod 3) * 110, Y + 22 + (Ord(Sec) div 3) * 24, 16, 16);
    FVaryChecks[Sec].TabStop := False;
    FVaryChecks[Sec].Checked := True;           // anfangs wird alles gewuerfelt
    L := TLabel.Create(Self);
    L.Parent := PV;
    L.SetBounds(36 + (Ord(Sec) mod 3) * 110, Y + 22 + (Ord(Sec) div 3) * 24, 80, 16);
    L.Caption := SECTION_NAMES[Sec];
    L.Font.Color := COL_NAME;
    L.Transparent := True;
  end;

  Y := Y + 22 + 2 * 24 + 10;
  B := TButton.Create(Self);
  B.Parent := PV;
  B.SetBounds(8, Y, 110, 30);
  B.Caption := Tr('Variieren');
  B.Icon := eiDice;
  B.TabStop := False;
  B.OnClick := VaryClick;
  FUndoButton := TButton.Create(Self);
  FUndoButton.Parent := PV;
  FUndoButton.SetBounds(124, Y, 110, 30);
  FUndoButton.Caption := Tr('Rückgängig');
  FUndoButton.Icon := eiUndo;
  FUndoButton.TabStop := False;
  FUndoButton.OnClick := UndoClick;
  FUndoButton.Hint := Tr('Letzten Schritt zurücknehmen (Strg+Z)');
  FUndoButton.ShowHint := True;
  FRedoButton := TButton.Create(Self);
  FRedoButton.Parent := PV;
  FRedoButton.SetBounds(240, Y, 110, 30);
  FRedoButton.Caption := Tr('Wiederholen');
  FRedoButton.Icon := eiRedo;
  FRedoButton.TabStop := False;
  FRedoButton.OnClick := RedoClick;
  FRedoButton.Hint := Tr('Zurückgenommenen Schritt wiederherstellen (Strg+Y oder Strg+Umschalt+Z)');
  FRedoButton.ShowHint := True;
  FABButton := TButton.Create(Self);
  FABButton.Parent := PV;
  FABButton.SetBounds(356, Y, 80, 30);
  FABButton.Caption := Tr('A/B: A');
  FABButton.TabStop := False;
  FABButton.OnClick := ABClick;

  L := TLabel.Create(Self);
  L.Parent := PV;
  L.SetBounds(8, Y + 40, 420, 70);
  L.AutoSize := False;
  L.WordWrap := True;
  L.Font.Color := $00A0A0A0;
  L.Transparent := True;
  L.Caption :=
    Tr('Variieren ändert die eingeschalteten Bereiche (Variieren in) zufällig um die eingestellte Stärke. ' +
    'Rückgängig (Strg+Z) nimmt jede Reglerbewegung, Variieren, Preset-Wechsel und A/B zurück, ' +
    'Wiederholen (Strg+Y) stellt sie wieder her. A/B merkt sich zwei Fassungen zum Vergleichen. ' +
    'Rechtsklick auf einen Regler: Modulation zuweisen oder MIDI-Learn. Alt + Mausrad: Modulationsmenge.');
  AddStretch(L, 10);
end;

function TGranularEditor.TakeSnapshot: TArray<Single>;
var
  I: Integer;
begin
  SetLength(Result, PARAM_COUNT);
  for I := 0 to PARAM_COUNT - 1 do
    Result[I] := FEngine.GetParam(I);
end;

procedure TGranularEditor.ApplySnapshot(const Snap: TArray<Single>);
var
  I: Integer;
begin
  for I := 0 to Min(Length(Snap), PARAM_COUNT) - 1 do
    FEngine.SetParam(I, Snap[I]);
  UpdateFromEngine;
end;

procedure TGranularEditor.PushUndo;
begin
  FUndo := FUndo + [TakeSnapshot];
  if Length(FUndo) > 100 then
    Delete(FUndo, 0, 1);
  FRedo := nil;
  FEditParam := -1;          // naechste Reglerbewegung beginnt einen neuen Schritt
end;

procedure TGranularEditor.UndoClick(Sender: TObject);
begin
  if Length(FUndo) = 0 then
    Exit;
  FRedo := FRedo + [TakeSnapshot];
  ApplySnapshot(FUndo[High(FUndo)]);
  SetLength(FUndo, Length(FUndo) - 1);
  FEditParam := -1;
end;

procedure TGranularEditor.RedoClick(Sender: TObject);
begin
  if Length(FRedo) = 0 then
    Exit;
  FUndo := FUndo + [TakeSnapshot];
  ApplySnapshot(FRedo[High(FRedo)]);
  SetLength(FRedo, Length(FRedo) - 1);
  FEditParam := -1;
end;

procedure TGranularEditor.ABClick(Sender: TObject);
begin
  if not FABInit then
  begin
    FAB[0] := TakeSnapshot;
    FAB[1] := TakeSnapshot;
    FABInit := True;
  end;
  PushUndo;
  FAB[FABActive] := TakeSnapshot;     // aktuelle Fassung merken
  FABActive := 1 - FABActive;
  ApplySnapshot(FAB[FABActive]);
  if FABActive = 0 then FABButton.Caption := Tr('A/B: A') else FABButton.Caption := Tr('A/B: B');
end;

procedure TGranularEditor.MacroResetClick(Sender: TObject);
var
  Id: TGranularParamId;
begin
  PushUndo;
  for Id := gpMacroTexture to gpMacroEnv do
    FEngine.SetParamById(Id, 0.5);
  UpdateFromEngine;
end;

procedure TGranularEditor.VaryClick(Sender: TObject);
const
  GRAINS: array[0..5] of TGranularParamId = (gpPosition, gpSpray, gpScan, gpGrainSize, gpDensity, gpWindow);
  KLANG: array[0..2] of TGranularParamId = (gpPitchRand, gpSpread, gpReverse);
  ENV: array[0..3] of TGranularParamId = (gpAttack, gpDecay, gpSustain, gpRelease);
  MODS: array[0..3] of TGranularParamId = (gpLfo1Rate, gpLfo1Shape, gpLfo2Rate, gpLfo2Shape);
  FLT: array[0..4] of TGranularParamId = (gpFltType, gpFltCutoff, gpFltReso, gpFltContour, gpFltEnvAmt);
  ECHO: array[0..2] of TGranularParamId = (gpEchoTime, gpEchoFeedback, gpEchoDamp);
  // FM-Verhaeltnisse, die musikalisch bleiben (ganzzahlig oder halbzahlig: harmonische Obertoene)
  FM_RATIOS: array[0..8] of Double = (0.5, 1, 1.5, 2, 3, 4, 5, 6, 7);
var
  S: Double;

  function IsOn(Id: TGranularParamId): Boolean;
  begin
    Result := FEngine.GetParamById(Id) >= 0.5;
  end;

  procedure Vary(Index: Integer; Scale: Double = 1);
  var
    Info: TParamInfo;
    V: Double;
  begin
    Info := GetParamInfo(Index);
    if Info.Curve = pcStepped then
    begin
      if Random < S * 0.3 then
        FEngine.SetParam(Index, StepToParam(Index, Random(Info.Steps)));
    end
    else
    begin
      // naeherungsweise Normalverteilung, Staerke 100 % ~ +-0,5 im Reglerbereich
      V := FEngine.GetParam(Index) + (Random + Random + Random - 1.5) * S * 0.6 * Scale;
      FEngine.SetParam(Index, EnsureRange(V, 0, 1));
    end;
  end;

  procedure VaryList(const Ids: array of TGranularParamId; Scale: Double = 1);
  var
    I: Integer;
  begin
    for I := 0 to High(Ids) do
      Vary(Ord(Ids[I]), Scale);
  end;

  { Oszillatoren: nur eingeschaltete; Welle bleibt (der Charakter des Presets), FM-Verhaeltnis springt
    nur auf musikalische Werte, Pegel und Sync behutsam }
  procedure VaryOscs;
  var
    O, K: Integer;
    P: TOscParamIds;
    Cur, Best: Double;
  begin
    for O := 0 to OSC_COUNT - 1 do
    begin
      P := OSC_P[O];
      if not IsOn(P.On_) then
        Continue;
      if Random < S * 0.4 then
      begin
        // Nachbar-Verhaeltnis in der Liste (ein Schritt hoch oder runter)
        Cur := ParamToPlain(P.FmRatio, FEngine.GetParamById(P.FmRatio));
        K := 0;
        for var I := 0 to High(FM_RATIOS) do
          if Abs(FM_RATIOS[I] - Cur) < Abs(FM_RATIOS[K] - Cur) then
            K := I;
        K := EnsureRange(K + IfThen(Random < 0.5, -1, 1), 0, High(FM_RATIOS));
        Best := FM_RATIOS[K];
        FEngine.SetParamById(P.FmRatio, PlainToParam(P.FmRatio, Best));
      end;
      Vary(Ord(P.FmAmt));
      Vary(Ord(P.Level), 0.4);
      Vary(Ord(P.Sync), 0.5);
      VaryList([P.Attack, P.Decay, P.Sustain, P.Release], 0.6);
      if IsOn(P.FmEnvOn) then
        VaryList([P.FmAttack, P.FmDecay, P.FmSustain, P.FmRelease], 0.6);
      if IsOn(P.FltOn) then
        VaryList([P.FltCutoff, P.FltReso, P.FltEnvAmt], 0.6);
    end;
  end;

var
  Slot: Integer;
begin
  S := FVaryStrength.Position / 100;
  if S <= 0 then
    Exit;
  PushUndo;
  // mit Mass: nur Teile, die im Preset auch klingen (ausgeschaltete bleiben unberuehrt)
  if FVaryChecks[vsGrains].Checked and IsOn(gpGrainOn) then VaryList(GRAINS);
  if FVaryChecks[vsSound].Checked and IsOn(gpGrainOn) then VaryList(KLANG);
  if FVaryChecks[vsEnvelope].Checked then VaryList(ENV);
  if FVaryChecks[vsModulation].Checked then
  begin
    VaryList(MODS);
    // nur die Mengen bereits belegter Slots, keine neuen Zuordnungen erfinden
    for Slot := 0 to MOD_SLOTS - 1 do
      if ParamStep(SlotSourceIndex(Slot), FEngine.GetParam(SlotSourceIndex(Slot))) > 0 then
        Vary(SlotAmountIndex(Slot), 0.5);
  end;
  if FVaryChecks[vsEffects].Checked then
  begin
    if IsOn(gpFltOn) then
      VaryList(FLT);
    if IsOn(gpEchoOn) then
    begin
      VaryList(ECHO);
      Vary(Ord(gpEchoPitch), 0.3);
    end;
    if IsOn(gpRevOn) then
      VaryList([gpRevMix, gpRevDecay], 0.5);
    if FEngine.GetParamById(gpDrive) > 0 then
      Vary(Ord(gpDrive), 0.5);     // Saettigung nur, wenn das Preset schon welche hat
  end;
  if FVaryChecks[vsOscs].Checked then
    VaryOscs;
  ApplyVaryStyle(FVaryStyle.ItemIndex);
  UpdateFromEngine;
end;

{ "+25 %" / "-10 %" / "0 %" - Delphis Format kennt kein Plus-Zeichen }
function SignedPct(V: Integer): string;
begin
  if V > 0 then
    Result := '+' + IntToStr(V) + ' %'
  else
    Result := IntToStr(V) + ' %';
end;

{ --- Rechtsklick auf einen Regler: Modulation direkt zuweisen --- }

procedure TGranularEditor.BuildModMenu;
const
  AMOUNTS: array[0..7] of Integer = (-50, -25, -10, 5, 10, 25, 50, 100);
var
  Sub, It: TMenuItem;
  Src: TModSource;
  I: Integer;
begin
  FModMenu := TPopupMenu.Create(Self);
  FModMenu.OnPopup := ModMenuPopup;
  Sub := TMenuItem.Create(FModMenu);
  Sub.Caption := Tr('Modulieren mit');
  FModMenu.Items.Add(Sub);
  for Src := Succ(msOff) to High(TModSource) do
  begin
    It := TMenuItem.Create(FModMenu);
    It.Caption := MOD_SOURCE_NAMES[Src];
    It.Tag := Ord(Src);
    It.OnClick := ModAssignClick;
    Sub.Add(It);
  end;
  FModAmountMenu := TMenuItem.Create(FModMenu);
  FModAmountMenu.Caption := Tr('Modulationsmenge');
  FModMenu.Items.Add(FModAmountMenu);
  for I := 0 to High(AMOUNTS) do
  begin
    It := TMenuItem.Create(FModMenu);
    It.Caption := SignedPct(AMOUNTS[I]);
    It.Tag := AMOUNTS[I];
    It.OnClick := ModAmountClick;
    FModAmountMenu.Add(It);
  end;
  FModRemoveItem := TMenuItem.Create(FModMenu);
  FModRemoveItem.Caption := Tr('Modulation entfernen');
  FModRemoveItem.OnClick := ModRemoveClick;
  FModMenu.Items.Add(FModRemoveItem);
  FModInfoItem := TMenuItem.Create(FModMenu);      // zeigt, wer den Regler schon moduliert
  FModInfoItem.Enabled := False;
  FModMenu.Items.Add(FModInfoItem);
  It := TMenuItem.Create(FModMenu);
  It.Caption := '-';
  FModMenu.Items.Add(It);
  FLearnItem := TMenuItem.Create(FModMenu);
  FLearnItem.Caption := Tr('MIDI-Learn');
  FLearnItem.OnClick := LearnClick;
  FModMenu.Items.Add(FLearnItem);
  FLearnRemoveItem := TMenuItem.Create(FModMenu);
  FLearnRemoveItem.OnClick := LearnRemoveClick;
  FModMenu.Items.Add(FLearnRemoveItem);
  FHostItem := TMenuItem.Create(FModMenu);
  FHostItem.Caption := Tr('Automation in der DAW (als "zuletzt geändert" melden)');
  FHostItem.OnClick := HostAutomationClick;
  FModMenu.Items.Add(FHostItem);
  It := TMenuItem.Create(FModMenu);
  It.Caption := '-';
  FModMenu.Items.Add(It);
  It := TMenuItem.Create(FModMenu);
  It.Caption := Tr('Standardwert');
  It.OnClick := ModDefaultClick;
  FModMenu.Items.Add(It);
end;

function TGranularEditor.MenuParamIndex: Integer;
begin
  Result := -1;
  if (FModMenu.PopupComponent <> nil) and (FModMenu.PopupComponent.Tag >= 0) and
     (FModMenu.PopupComponent.Tag <= High(FBindings)) then
    Result := FBindings[FModMenu.PopupComponent.Tag].Index;
end;

function TGranularEditor.SlotsFor(Index: Integer): TArray<Integer>;
var
  Slot: Integer;
begin
  Result := nil;
  for Slot := 0 to MOD_SLOTS - 1 do
    if (ParamStep(SlotSourceIndex(Slot), FEngine.GetParam(SlotSourceIndex(Slot))) > 0) and
       (ParamStep(SlotDestIndex(Slot), FEngine.GetParam(SlotDestIndex(Slot))) = Index + 1) then
      Result := Result + [Slot];
end;

{ "Zeile 3: LFO 1  +25 %" }
function TGranularEditor.SlotCaption(Slot: Integer): string;
begin
  Result := Format(Tr('Zeile %d: %s  %s'), [Slot + 1,
    StepName(SlotSourceIndex(Slot), ParamStep(SlotSourceIndex(Slot), FEngine.GetParam(SlotSourceIndex(Slot)))),
    SignedPct(Round(ParamToPlain(SlotAmountIndex(Slot), FEngine.GetParam(SlotAmountIndex(Slot)))))]);
end;

{ Zeile fuer Alt + Mausrad: die im Menue gewaehlte, sonst die erste, die auf den Regler wirkt (-1 = keine) }
function TGranularEditor.WheelSlotFor(Index: Integer): Integer;
var
  Slots: TArray<Integer>;
  S: Integer;
begin
  Slots := SlotsFor(Index);
  Result := -1;
  if Length(Slots) = 0 then
    Exit;
  Result := Slots[0];
  if FWheelParam = Index then
    for S in Slots do
      if S = FWheelSlot then
        Exit(S);
end;

procedure TGranularEditor.ModMenuPopup(Sender: TObject);
const
  AMOUNTS: array[0..9] of Integer = (100, 50, 25, 10, 5, -5, -10, -25, -50, -100);
var
  Idx, Slot, Cc, K, Pos, A: Integer;
  Slots: TArray<Integer>;
  Sub, It: TMenuItem;
begin
  Idx := MenuParamIndex;
  Slots := nil;
  if Idx >= 0 then
    Slots := SlotsFor(Idx);
  // Untermenues des letzten Oeffnens entfernen, je wirkender Matrix-Zeile ein neues
  for It in FModSlotItems do
    It.Free;
  FModSlotItems := nil;
  FModAmountMenu.Visible := False;
  FModInfoItem.Visible := False;
  FModRemoveItem.Visible := Length(Slots) > 1;
  FModRemoveItem.Caption := Tr('Alle Modulationen dieses Reglers entfernen');
  FModMenu.Items[0].Enabled := (Idx >= 0) and (Idx < NAMED_COUNT - 1);
  Pos := 1;
  for K := 0 to High(Slots) do
  begin
    Slot := Slots[K];
    Sub := TMenuItem.Create(FModMenu);
    Sub.Caption := SlotCaption(Slot);
    if K <= High(MOD_LANE_NAMES) then
      Sub.Caption := Sub.Caption + '   (' + MOD_LANE_NAMES[K] + ')';
    for A in AMOUNTS do
    begin
      It := TMenuItem.Create(Sub);
      It.Caption := Tr('Menge ') + SignedPct(A);
      It.Checked := Round(ParamToPlain(SlotAmountIndex(Slot), FEngine.GetParam(SlotAmountIndex(Slot)))) = A;
      It.Tag := Slot * 1000 + 500 + A;          // 400..600: Menge
      It.OnClick := ModSlotClick;
      Sub.Add(It);
    end;
    It := TMenuItem.Create(Sub);
    It.Caption := '-';
    Sub.Add(It);
    It := TMenuItem.Create(Sub);
    It.Caption := Tr('Für Alt + Mausrad wählen');
    It.Checked := WheelSlotFor(Idx) = Slot;
    It.Tag := Slot * 1000 + 1;
    It.OnClick := ModSlotClick;
    Sub.Add(It);
    It := TMenuItem.Create(Sub);
    It.Caption := Tr('Diese Modulation entfernen');
    It.Tag := Slot * 1000 + 2;
    It.OnClick := ModSlotClick;
    Sub.Add(It);
    FModMenu.Items.Insert(Pos, Sub);
    Inc(Pos);
    FModSlotItems := FModSlotItems + [Sub];
  end;
  Cc := -1;
  if Idx >= 0 then
    Cc := FEngine.CcForParam(Idx);
  FLearnItem.Enabled := Idx >= 0;
  if FEngine.MidiLearnPending and (FLearnBinding >= 0) and (FBindings[FLearnBinding].Index = Idx) then
    FLearnItem.Caption := Tr('MIDI-Learn abbrechen')
  else if Cc >= 0 then
    FLearnItem.Caption := Format(Tr('MIDI-Learn (jetzt CC %d) - neu lernen'), [Cc])
  else
    FLearnItem.Caption := Tr('MIDI-Learn: Regler am Controller bewegen');
  FLearnRemoveItem.Visible := Cc >= 0;
  FLearnRemoveItem.Caption := Format(Tr('MIDI-Zuordnung CC %d entfernen'), [Cc]);
end;

procedure TGranularEditor.LearnClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := MenuParamIndex;
  if Idx < 0 then
    Exit;
  if FEngine.MidiLearnPending and (FLearnBinding >= 0) and (FBindings[FLearnBinding].Index = Idx) then
  begin
    FEngine.MidiLearnCancel;
    FLearnBinding := -1;
    FStatus.Caption := Tr('MIDI-Learn abgebrochen');
    Exit;
  end;
  FLearnBinding := FModMenu.PopupComponent.Tag;
  FEngine.MidiLearnStart(Idx);
  FStatus.Caption := Tr('MIDI-Learn "') + GetParamInfo(Idx).Name + Tr('": jetzt einen Regler am Controller bewegen (Esc bricht ab)');
end;

{ Bewegung eines Reglers an die DAW melden. Beginn/Ende umschliessen eine zusammenhaengende Bewegung
  (wie beim Ziehen eines Schiebereglers), damit die DAW sie als eine Automations-Geste aufnimmt. }
procedure TGranularEditor.HostEdit(Index: Integer; Continuous: Boolean);
begin
  if not Assigned(FOnParamEdit) or (Index < 0) or (Index >= PARAM_COUNT) then
    Exit;
  if FHostEditParam <> Index then
  begin
    EndHostEdit;
    FOnParamEdit(Index, pekBegin, FEngine.GetParam(Index));
    FHostEditParam := Index;
  end;
  FOnParamEdit(Index, pekChange, FEngine.GetParam(Index));
  FHostEditTick := GetTickCount;
  if not Continuous then
    EndHostEdit;
end;

procedure TGranularEditor.EndHostEdit;
begin
  if FHostEditParam < 0 then
    Exit;
  if Assigned(FOnParamEdit) then
    FOnParamEdit(FHostEditParam, pekEnd, FEngine.GetParam(FHostEditParam));
  FHostEditParam := -1;
end;

{ Rechtsklick auf einen Regler: im VST3-Plugin zuerst das Menue der DAW (dort u.a. "Create automation clip"),
  mit einem Eintrag fuer das eigene Menue; sonst wie bisher das eigene Menue }
procedure TGranularEditor.TrackContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  Pos: TPoint;
begin
  if not Assigned(FOnHostMenu) then
    Exit;
  if (MousePos.X < 0) and (MousePos.Y < 0) then
    Pos := (Sender as TControl).ClientToScreen(Point((Sender as TControl).Width div 2, (Sender as TControl).Height div 2))
  else
    Pos := (Sender as TControl).ClientToScreen(MousePos);
  if FOnHostMenu(FBindings[(Sender as TComponent).Tag].Index, Pos, Sender as TControl) then
    Handled := True;
end;

procedure TGranularEditor.ShowOwnMenu(Ctrl: TControl; const ScreenPos: TPoint);
begin
  FModMenu.PopupComponent := Ctrl;
  FModMenu.Popup(ScreenPos.X, ScreenPos.Y);
end;

procedure TGranularEditor.SetFormatName(const Value: string);
begin
  FBanner.FormatName := Value;
end;

{ Rechtsklick > "Automation in der DAW": Regler bei der DAW als zuletzt geaendert melden. In FL Studio
  danach Tools > Last tweaked > Create automation clip (bzw. Link to controller). }
procedure TGranularEditor.HostAutomationClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := MenuParamIndex;
  if Idx < 0 then
    Exit;
  if not Assigned(FOnParamEdit) then
  begin
    FStatus.Caption := Tr('Nur im Plugin (DAW): hier im Test-Host gibt es keine Automationsspuren');
    Exit;
  end;
  HostEdit(Idx, False);
  FStatus.Caption := '"' + GetParamInfo(Idx).Name + Tr('" gemeldet - in FL Studio jetzt: Tools > Last tweaked > ' +
    'Create automation clip');
end;

procedure TGranularEditor.LearnRemoveClick(Sender: TObject);
var
  Cc: Integer;
begin
  Cc := FEngine.CcForParam(MenuParamIndex);
  if Cc < 0 then
    Exit;
  FEngine.SetCcTarget(Cc, -1);
  SaveMidiMap(FEngine, FBaseDir + MIDI_MAP_FILE);
  FStatus.Caption := Format(Tr('MIDI-Zuordnung CC %d entfernt'), [Cc]);
end;

{ vom Anzeige-Timer: hat die Engine einen Controller gelernt? -> speichern und melden }
procedure TGranularEditor.PollMidiLearn;
var
  Cc: Integer;
begin
  Cc := FEngine.MidiLearnPoll;
  if Cc < 0 then
    Exit;
  SaveMidiMap(FEngine, FBaseDir + MIDI_MAP_FILE);
  if FLearnBinding >= 0 then
    FStatus.Caption := Format(Tr('MIDI-Learn: CC %d steuert jetzt "%s"'), [Cc, GetParamInfo(FBindings[FLearnBinding].Index).Name]);
  FLearnBinding := -1;
end;

{ Modulationsbalken in den Reglern: Summe der Matrix-Mengen, die auf den Regler wirken }
procedure TGranularEditor.RefreshModRings;
var
  I, Slot, Dst, K: Integer;
  Lanes: array of TArray<Single>;
begin
  SetLength(Lanes, NAMED_COUNT);
  for Slot := 0 to MOD_SLOTS - 1 do
    if ParamStep(SlotSourceIndex(Slot), FEngine.GetParam(SlotSourceIndex(Slot))) > 0 then
    begin
      Dst := ParamStep(SlotDestIndex(Slot), FEngine.GetParam(SlotDestIndex(Slot))) - 1;
      if (Dst >= 0) and (Dst < NAMED_COUNT) then
      begin
        K := Length(Lanes[Dst]);
        SetLength(Lanes[Dst], K + 1);
        Lanes[Dst][K] := ParamToPlain(SlotAmountIndex(Slot), FEngine.GetParam(SlotAmountIndex(Slot))) / 100;
      end;
    end;
  for I := 0 to High(FBindings) do
    if (FBindings[I].Track <> nil) and (FBindings[I].Index < NAMED_COUNT) then
      FBindings[I].Track.SetModDepths(Lanes[FBindings[I].Index]);
end;

{ Alt + Mausrad auf einem modulierten Regler: Menge aller Matrix-Zeilen dorthin in 5-%-Schritten }
procedure TGranularEditor.TrackModWheel(Sender: TObject; Delta: Integer);
var
  Idx, Slot, K, Lane: Integer;
  A: Double;
  Slots: TArray<Integer>;
begin
  Idx := FBindings[(Sender as TComponent).Tag].Index;
  Slot := WheelSlotFor(Idx);
  if Slot < 0 then
  begin
    FStatus.Caption := Tr('Alt + Mausrad: dieser Regler ist nicht moduliert (Rechtsklick > Modulieren mit)');
    Exit;
  end;
  if (FEditParam <> -2 - Slot) or (GetTickCount - FEditTick > 1500) then
  begin
    PushUndo;
    FEditParam := -2 - Slot;
  end;
  FEditTick := GetTickCount;
  A := ParamToPlain(SlotAmountIndex(Slot), FEngine.GetParam(SlotAmountIndex(Slot)));
  A := EnsureRange(Round(A / 5) * 5 + Sign(Delta) * 5, -100, 100);
  FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), A));
  ParamChangedByUser(SlotAmountIndex(Slot));
  Slots := SlotsFor(Idx);
  Lane := 0;
  for K := 0 to High(Slots) do
    if Slots[K] = Slot then
      Lane := K;
  FStatus.Caption := Tr('Alt + Mausrad: ') + SlotCaption(Slot);
  if Length(Slots) > 1 then
    FStatus.Caption := FStatus.Caption + Format(Tr('  (Spur %s; andere Zeile: Rechtsklick > Zeile > Für Alt + Mausrad wählen)'),
      [MOD_LANE_NAMES[Min(Lane, High(MOD_LANE_NAMES))]]);
  RefreshModRings;
  UpdateMacroTargets;
end;

procedure TGranularEditor.ModAssignClick(Sender: TObject);
var
  Idx, Slot, Free, Src: Integer;
begin
  Idx := MenuParamIndex;
  if (Idx < 0) or (Idx >= NAMED_COUNT - 1) then
    Exit;
  Src := (Sender as TMenuItem).Tag;
  for Slot := 0 to MOD_SLOTS - 1 do
    if (ParamStep(SlotSourceIndex(Slot), FEngine.GetParam(SlotSourceIndex(Slot))) = Src) and
       (ParamStep(SlotDestIndex(Slot), FEngine.GetParam(SlotDestIndex(Slot))) = Idx + 1) then
      Exit;   // gibt es schon
  Free := FirstFreeSlot;   // immer die oberste freie Zeile, nicht hinten anhaengen
  if Free < 0 then
  begin
    MessageDlg(Tr('Alle ') + IntToStr(MOD_SLOTS) + Tr(' Matrix-Zeilen sind belegt.'), mtInformation, [mbOK], 0);
    Exit;
  end;
  PushUndo;
  SetSlot(Free, Src, Idx + 1, 25, MOD_FACTOR_DEFAULT);
  UpdateFromEngine;
  FStatus.Caption := Format(Tr('Modulation in Matrix-Zeile %d'), [Free + 1]);
end;

{ oberste Matrix-Zeile, die nichts bewirkt (keine Quelle oder kein Ziel); -1 = alle belegt }
function TGranularEditor.FirstFreeSlot: Integer;
var
  S: Integer;
begin
  for S := 0 to MOD_SLOTS - 1 do
    if (ParamStep(SlotSourceIndex(S), FEngine.GetParam(SlotSourceIndex(S))) = 0) or
       (ParamStep(SlotDestIndex(S), FEngine.GetParam(SlotDestIndex(S))) = 0) then
      Exit(S);
  Result := -1;
end;

{ vorhandene Zeile Quelle -> Ziel wiederverwenden, sonst die oberste freie (-1 = keine frei) }
function TGranularEditor.SlotFor(Src, Dst: Integer): Integer;
var
  S: Integer;
begin
  for S := 0 to MOD_SLOTS - 1 do
    if (ParamStep(SlotSourceIndex(S), FEngine.GetParam(SlotSourceIndex(S))) = Src) and
       (ParamStep(SlotDestIndex(S), FEngine.GetParam(SlotDestIndex(S))) = Dst) then
      Exit(S);
  Result := FirstFreeSlot;
end;

{ Zeile setzen und die Matrix-Ansicht auf ihre Seite stellen }
procedure TGranularEditor.SetSlot(Slot, Src, Dst: Integer; Amount: Double; Factor: Integer);
begin
  FEngine.SetParam(SlotSourceIndex(Slot), StepToParam(SlotSourceIndex(Slot), Src));
  FEngine.SetParam(SlotDestIndex(Slot), StepToParam(SlotDestIndex(Slot), Dst));
  FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), Amount));
  FEngine.SetParam(SlotFactorIndex(Slot), StepToParam(SlotFactorIndex(Slot), Factor));
  FEngine.SetParam(SlotOffsetIndex(Slot), PlainToParam(SlotOffsetIndex(Slot), 0));
  if Slot div MAT_ROWS <> FMatPage then
    ShowMatrixPage(Slot div MAT_ROWS);
end;

{ --- Matrix-Seiten --- }

procedure TGranularEditor.ShowMatrixPage(Page: Integer);
var
  S: Integer;
  C: TControl;
begin
  FMatPage := EnsureRange(Page, 0, High(FMatPageBtn));
  for S := 0 to MOD_SLOTS - 1 do
  begin
    for C in FSlotCtrls[S] do
      C.Visible := S div MAT_ROWS = FMatPage;
    if FSlotGlobal[S] <> nil then
      FSlotGlobal[S].Visible := (S div MAT_ROWS = FMatPage) and FEngine.SlotIsGlobalNote(S);
  end;
  for S := 0 to MOD_SLOTS - 1 do
    if S div MAT_ROWS <> FMatPage then
      for var K := 0 to High(FBindings) do
        if (FBindings[K].ModMarker <> nil) and (FBindings[K].Index >= SlotSourceIndex(S)) and
           (FBindings[K].Index <= SlotOffsetIndex(S)) then
          FBindings[K].ModMarker.Visible := False;
  UpdateMatrixPageCaptions;
end;

procedure TGranularEditor.MatPageClick(Sender: TObject);
begin
  ShowMatrixPage((Sender as TComponent).Tag);
end;

{ "9-16 (2)": benutzte Zeilen je Seite; die sichtbare Seite ist bernsteinfarben }
procedure TGranularEditor.UpdateMatrixPageCaptions;
var
  P, S, N: Integer;
  Cap: string;
begin
  for P := 0 to High(FMatPageBtn) do
  begin
    N := 0;
    for S := P * MAT_ROWS to Min(MOD_SLOTS, (P + 1) * MAT_ROWS) - 1 do
      if ParamStep(SlotSourceIndex(S), FEngine.GetParam(SlotSourceIndex(S))) > 0 then
        Inc(N);
    Cap := Format(Tr('%d-%d'), [P * MAT_ROWS + 1, Min(MOD_SLOTS, (P + 1) * MAT_ROWS)]);
    if N > 0 then
      Cap := Cap + Format(Tr(' (%d)'), [N]);
    FMatPageBtn[P].Active := P = FMatPage;   // sichtbare Seite bernsteinfarben
    if FMatPageBtn[P].Caption <> Cap then
      FMatPageBtn[P].Caption := Cap;
  end;
end;

{ Zeile unter jedem freien Makro: welche Regler es bewegt (aus den Matrix-Zeilen) }
procedure TGranularEditor.UpdateMacroTargets;
var
  K, S, Src, Dst, N: Integer;
  T: string;
begin
  if FMacroTargets[0] = nil then
    Exit;
  for K := 0 to UMAC_COUNT - 1 do
  begin
    T := '';
    N := 0;
    for S := 0 to MOD_SLOTS - 1 do
    begin
      Src := ParamStep(SlotSourceIndex(S), FEngine.GetParam(SlotSourceIndex(S)));
      Dst := ParamStep(SlotDestIndex(S), FEngine.GetParam(SlotDestIndex(S)));
      if (Src = Ord(UMAC_SRC[K])) and (Dst > 0) then
      begin
        Inc(N);
        if T <> '' then T := T + ', ';
        T := T + DestName(Dst);
      end;
    end;
    if N = 0 then
      T := Tr('noch keine Ziele')
    else
      T := '-> ' + T;
    if FMacroTargets[K].Caption <> T then
    begin
      FMacroTargets[K].Caption := T;
      FMacroTargets[K].Hint := T;
      FMacroTargets[K].ShowHint := True;
    end;
  end;
end;

procedure TGranularEditor.ClearSlot(Slot: Integer);
begin
  FEngine.SetParam(SlotSourceIndex(Slot), 0);
  FEngine.SetParam(SlotDestIndex(Slot), 0);
  FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), 0));
  FEngine.SetParam(SlotFactorIndex(Slot), StepToParam(SlotFactorIndex(Slot), MOD_FACTOR_DEFAULT));
  FEngine.SetParam(SlotOffsetIndex(Slot), PlainToParam(SlotOffsetIndex(Slot), 0));
end;

procedure TGranularEditor.SlotClearClick(Sender: TObject);
begin
  PushUndo;
  ClearSlot((Sender as TComponent).Tag);
  UpdateFromEngine;
end;

procedure TGranularEditor.ModSlotClick(Sender: TObject);
var
  Slot, Code: Integer;
begin
  Slot := (Sender as TMenuItem).Tag div 1000;
  Code := (Sender as TMenuItem).Tag mod 1000;
  if (Slot < 0) or (Slot >= MOD_SLOTS) then
    Exit;
  case Code of
    1:
      begin
        FWheelParam := MenuParamIndex;
        FWheelSlot := Slot;
        FStatus.Caption := Tr('Alt + Mausrad: ') + SlotCaption(Slot);
      end;
    2:
      begin
        PushUndo;
        ClearSlot(Slot);
        UpdateFromEngine;
      end;
    400..600:
      begin
        PushUndo;
        FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), Code - 500));
        UpdateFromEngine;
        FStatus.Caption := SlotCaption(Slot);
      end;
  end;
end;

procedure TGranularEditor.ModAmountClick(Sender: TObject);
var
  Slot: Integer;
begin
  PushUndo;
  for Slot in SlotsFor(MenuParamIndex) do
    FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), (Sender as TMenuItem).Tag));
  UpdateFromEngine;
end;

procedure TGranularEditor.ModRemoveClick(Sender: TObject);
var
  Slot: Integer;
begin
  PushUndo;
  for Slot in SlotsFor(MenuParamIndex) do
  begin
    FEngine.SetParam(SlotSourceIndex(Slot), 0);
    FEngine.SetParam(SlotDestIndex(Slot), 0);
    FEngine.SetParam(SlotAmountIndex(Slot), PlainToParam(SlotAmountIndex(Slot), 0));
  end;
  UpdateFromEngine;
end;

procedure TGranularEditor.ModDefaultClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := MenuParamIndex;
  if Idx < 0 then
    Exit;
  PushUndo;
  FEngine.SetParam(Idx, PlainToParam(Idx, GetParamInfo(Idx).DefV));
  UpdateFromEngine;
end;

{ --- Werte exakt eingeben: Klick auf die Wertanzeige oeffnet ein Eingabefeld --- }

procedure TGranularEditor.ValueLabelClick(Sender: TObject);
var
  L: TLabel;
  B: TParamBinding;
begin
  L := Sender as TLabel;
  if (L.Tag < 0) or (L.Tag > High(FBindings)) then
    Exit;
  CommitValueEdit;   // evtl. noch offenes Feld zuerst uebernehmen
  B := FBindings[L.Tag];
  FEditBinding := L.Tag;
  FValueEdit.Parent := L.Parent;
  FValueEdit.SetBounds(L.Left - 2, L.Top - 3, Max(L.Width + 12, 70), 20);
  FValueEdit.Text := DisplayFor(B.Index, FEngine.GetParam(B.Index));
  FValueEdit.Visible := True;
  FValueEdit.BringToFront;
  FValueEdit.SetFocus;
  FValueEdit.SelectAll;
end;

function TGranularEditor.ParseValueInput(Index: Integer; const Text: string; out Norm: Single): Boolean;
var
  S, Num: string;
  I, D: Integer;
  V: Double;
  Info: TParamInfo;
  Fs: TFormatSettings;
  Synced: Boolean;
begin
  Result := False;
  S := Trim(Text);
  if S = '' then
    Exit;
  Info := GetParamInfo(Index);

  // Notenwerte bei Tempo-Sync (LFO-Rate, Echo-Zeit)
  Synced := (Index = Ord(gpEchoTime)) and (FEngine.GetParamById(gpEchoSync) >= 0.5);
  for var LK := 0 to LFO_COUNT - 1 do
    if (Index = Ord(LFO_RATE_IDS[LK])) and (FEngine.GetParamById(LFO_SYNC_IDS[LK]) >= 0.5) then
      Synced := True;
  if Synced then
    for D := 0 to LFO_DIV_COUNT - 1 do
      if SameText(S, LFO_DIV_NAMES[D]) then
      begin
        if Index = Ord(gpEchoTime) then
          Norm := (LFO_DIV_COUNT - 1 - D) / (LFO_DIV_COUNT - 1)
        else
          Norm := D / (LFO_DIV_COUNT - 1);
        Exit(True);
      end;

  // Stufenparameter: Klartext der Stufe akzeptieren
  if Info.Curve = pcStepped then
    for D := 0 to Info.Steps - 1 do
      if SameText(S, StepName(Index, D)) then
      begin
        Norm := StepToParam(Index, D);
        Exit(True);
      end;

  if (Index = Ord(gpVolume)) and (Pos('inf', LowerCase(S)) > 0) then
  begin
    Norm := 0;
    Exit(True);
  end;

  // Zahl herausloesen: Vorzeichen, Ziffern, Komma oder Punkt; Einheit wird ignoriert
  Num := '';
  for I := 1 to Length(S) do
    if CharInSet(S[I], ['0'..'9', '-', '+', ',', '.']) then
      Num := Num + S[I]
    else if Num <> '' then
      Break;
  Num := StringReplace(Num, ',', '.', [rfReplaceAll]);
  Fs := TFormatSettings.Invariant;
  if not TryStrToFloat(Num, V, Fs) then
    Exit;
  if Pos('k', LowerCase(S)) > 0 then
    V := V * 1000;   // "2,5 kHz"
  Norm := PlainToParam(Index, EnsureRange(V, Info.MinV, Info.MaxV));
  Result := True;
end;

procedure TGranularEditor.CommitValueEdit;
var
  B: TParamBinding;
  N: Single;
begin
  if not FValueEdit.Visible or (FEditBinding < 0) then
    Exit;
  B := FBindings[FEditBinding];
  if ParseValueInput(B.Index, FValueEdit.Text, N) then
  begin
    PushUndo;
    FEngine.SetParam(B.Index, N);
    SetControlValue(FEditBinding, N);
    ParamChangedByUser(B.Index);
  end;
  CancelValueEdit;
end;

procedure TGranularEditor.CancelValueEdit;
begin
  FEditBinding := -1;
  if FValueEdit.Visible then
  begin
    FValueEdit.Visible := False;
    if FPages.CanFocus then
      FPages.SetFocus;   // Fokus zurueck -> PC-Tastatur spielt wieder
  end;
end;

procedure TGranularEditor.ValueEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_RETURN: begin CommitValueEdit; Key := 0; end;
    VK_ESCAPE: begin CancelValueEdit; Key := 0; end;
  end;
end;

procedure TGranularEditor.ValueEditExit(Sender: TObject);
begin
  CommitValueEdit;
end;

{ --- Werte --- }

function TGranularEditor.DisplayFor(Index: Integer; Norm: Single): string;
var
  K: Integer;
begin
  for K := 0 to LFO_COUNT - 1 do
    if (Index = Ord(LFO_RATE_IDS[K])) and (FEngine.EffParam[Ord(LFO_SYNC_IDS[K])] >= 0.5) then
      Exit(LFO_DIV_NAMES[LfoDivisionIndex(Norm)]);
  if (Index = Ord(gpEchoTime)) and (FEngine.EffParam[Ord(gpEchoSync)] >= 0.5) then
    Result := LFO_DIV_NAMES[EchoDivisionIndex(Norm)]
  else if GetParamInfo(Index).Curve = pcStepped then
    Result := Tr(ParamDisplay(Index, Norm))
  else
    Result := ParamDisplay(Index, Norm);
end;

procedure TGranularEditor.UpdateValueLabel(BindingIdx: Integer);
const
  THUMB_MARGIN = 12;   // ungefaehrer Rand der Trackbar bis zur Schieberbahn
var
  B: ^TParamBinding;
  Base, Eff: Single;
  Cap: string;
  Modulated: Boolean;
  X: Integer;
begin
  B := @FBindings[BindingIdx];
  if B.ValueLabel = nil then
    Exit;
  // Beschriftung = immer der Grundwert (Regler); die Matrix verschiebt nur den Wirkwert
  Base := FEngine.GetParam(B.Index);
  Eff := FEngine.EffParam[B.Index];
  if (Base = B.LastBase) and (Eff = B.LastEff) then
    Exit;   // unveraendert: kein Format, kein Neuzeichnen
  B.LastBase := Base;
  B.LastEff := Eff;
  Modulated := Abs(Eff - Base) > 0.0005;
  Cap := DisplayFor(B.Index, Base);
  if Modulated then
    B.ValueLabel.Hint := Tr('wirksam: ') + DisplayFor(B.Index, Eff) + Tr('  -  Klick: Wert eingeben')
  else
    B.ValueLabel.Hint := Tr('Klick: Wert eingeben');
  if Cap <> B.LastCaption then
  begin
    B.ValueLabel.Caption := Cap;
    B.LastCaption := Cap;
  end;

  if B.ModMarker <> nil then
  begin
    if Modulated then
    begin
      X := B.Track.Left + THUMB_MARGIN + Round(Eff * (B.Track.Width - 2 * THUMB_MARGIN)) - 2;
      // Fenster verschieben ist teuer: nur bei mindestens 2 px Aenderung
      if Abs(B.ModMarker.Left - X) >= 2 then
        B.ModMarker.Left := X;
    end;
    Modulated := Modulated and ((B.Track = nil) or B.Track.Visible);   // ausgeblendete Matrix-Seite
    if B.ModMarker.Visible <> Modulated then
      B.ModMarker.Visible := Modulated;
  end;
end;

procedure TGranularEditor.SetControlValue(BindingIdx: Integer; Norm: Single);
var
  B: TParamBinding;
begin
  B := FBindings[BindingIdx];
  FUpdating := True;
  try
    if B.Track <> nil then
    begin
      if B.Vertical then
        B.Track.Position := B.Track.Max - Round(Norm * B.Track.Max)
      else
        B.Track.Position := Round(Norm * B.Track.Max);
    end
    else if B.Combo <> nil then
      B.Combo.ItemIndex := ComboItemOfStep(B, ParamStep(B.Index, Norm))
    else if B.Check <> nil then
    begin
      B.Check.Checked := Norm >= 0.5;
      FLedsDirty := True;
      if B.OnOffCaption then
        B.NameLabel.Caption := System.StrUtils.IfThen(Norm >= 0.5, Tr('an'), Tr('aus'));
    end;
  finally
    FUpdating := False;
  end;
  UpdateValueLabel(BindingIdx);
end;

procedure TGranularEditor.SyncControlsFromEngine;
var
  I: Integer;
  B: TParamBinding;
  V: Single;
  Changed: Boolean;
begin
  // Werte, die nicht ueber diese Oberflaeche geaendert wurden (Autoplay-Tempo,
  // spaeter VST-Automation), in die Regler uebernehmen - ausser der Nutzer zieht gerade
  for I := 0 to High(FBindings) do
  begin
    B := FBindings[I];
    V := FEngine.GetParam(B.Index);
    if B.Track <> nil then
      Changed := (Round(V * B.Track.Max) <> IfThen(B.Vertical, B.Track.Max - B.Track.Position, B.Track.Position)) and
        (GetCapture <> B.Track.Handle)
    else if B.Combo <> nil then
      Changed := (ComboItemOfStep(B, ParamStep(B.Index, V)) <> B.Combo.ItemIndex) and not B.Combo.DroppedDown
    else
      Changed := (V >= 0.5) <> B.Check.Checked;
    if Changed then
    begin
      SetControlValue(I, V);
      if B.Index < Length(FCommitted) then
        FCommitted[B.Index] := V;     // Automation/MIDI-Learn: Grundlage fuer Rueckgaengig nachziehen
    end;
  end;
end;

{ alle Betriebslampen pruefen (neu gezeichnet wird nur, was sich geaendert hat) }
procedure UpdateLeds(Root: TWinControl);
var
  I: Integer;
begin
  for I := 0 to Root.ControlCount - 1 do
    if Root.Controls[I] is TWinControl then
    begin
      if Root.Controls[I] is TGroupPanel then
        TGroupPanel(Root.Controls[I]).UpdateLed;
      UpdateLeds(TWinControl(Root.Controls[I]));
    end;
end;

procedure TGranularEditor.UpdateFromEngine;
var
  I: Integer;
begin
  for I := 0 to High(FBindings) do
    SetControlValue(I, FEngine.GetParam(FBindings[I].Index));
  SyncWaveFromParams;
  SyncFreeUi;
  UpdateMorphLabel;
  if FArpPattern <> nil then
    FArpPattern.Invalidate;
  RefreshModRings;
  UpdateMacroTargets;
  if FMatPageBtn <> nil then
    UpdateMatrixPageCaptions;
  UpdateZoneUi;
  FCommitted := TakeSnapshot;
  if FLedsDirty then
  begin
    FLedsDirty := False;
    UpdateLeds(Self);
  end;
end;

{ Huellkurven-Grafik: Punkte mit der Maus ziehen wie die Regler daneben }
procedure TGranularEditor.SetupEnvView(V: TEnvelopeView);
begin
  V.OnEdit := EnvViewEdit;
  V.Hint := Tr('Punkte ziehen: Spitze = Attack, Knick = Decay (waagrecht) und Sustain (senkrecht), ' +
    'rechter Punkt = Release. Doppelklick = Standardwert.');
  V.ShowHint := True;
end;

procedure TGranularEditor.EnvViewEdit(Id: TGranularParamId; Norm: Single);
begin
  if Abs(FEngine.GetParam(Ord(Id)) - Norm) < 1E-7 then
    Exit;
  FEngine.SetParam(Ord(Id), Norm);
  ParamChangedByUser(Ord(Id), -1);
end;

procedure TGranularEditor.ParamChangedByUser(Index: Integer; FromBinding: Integer);
var
  I: Integer;
begin
  // Rueckgaengig: eine zusammenhaengende Bewegung desselben Reglers = ein Schritt.
  // FCommitted haelt den Stand davor (wird nach jeder Aenderung nachgefuehrt).
  if FromBinding >= 0 then
  begin
    if Length(FCommitted) <> PARAM_COUNT then
      FCommitted := TakeSnapshot;
    if (Index <> FEditParam) or (GetTickCount - FEditTick > 1500) then
    begin
      FUndo := FUndo + [Copy(FCommitted)];
      if Length(FUndo) > 100 then
        Delete(FUndo, 0, 1);
      FRedo := nil;
      FEditParam := Index;
    end;
    FEditTick := GetTickCount;
  end;
  if (Index >= 0) and (Index < Length(FCommitted)) then
    FCommitted[Index] := FEngine.GetParam(Index);
  // an die DAW melden: Schieberegler als fortlaufende Bewegung, Listen/Schalter als einzelner Schritt
  if FromBinding >= 0 then
    HostEdit(Index, FBindings[FromBinding].Track <> nil)
  else
    HostEdit(Index, False);
  if Index >= NAMED_COUNT then
    RefreshModRings;
    UpdateMacroTargets;                  // Matrix geaendert -> Balken in den Reglern nachziehen
  // derselbe Parameter kann mehrfach in der Oberflaeche stehen (z.B. Mischpult + Reiter):
  // alle Regler sofort gleichziehen
  for I := 0 to High(FBindings) do
    if (FBindings[I].Index = Index) and (I <> FromBinding) then
      SetControlValue(I, FEngine.GetParam(Index))
    else if I = FromBinding then
      UpdateValueLabel(I);
  if (Index = Ord(gpSelStart)) or (Index = Ord(gpSelEnd)) or
     (Index = Ord(gpPosition)) or (Index = Ord(gpSpray)) or
     (Index = Ord(gpPreOn)) or (Index = Ord(gpPreStart)) then
    SyncWaveFromParams;
end;

procedure TGranularEditor.TrackChange(Sender: TObject);
var
  B: TParamBinding;
begin
  if FUpdating then
    Exit;
  B := FBindings[(Sender as TComponent).Tag];
  if B.Vertical then
    FEngine.SetParam(B.Index, (B.Track.Max - B.Track.Position) / B.Track.Max)
  else
    FEngine.SetParam(B.Index, B.Track.Position / B.Track.Max);
  ParamChangedByUser(B.Index, (Sender as TComponent).Tag);
end;

{ Betriebslampen, die nicht an einem Ein-Schalter haengen: Bedingung je Bereich }
procedure TGranularEditor.SetupLeds;

  function Grp(C: TControl): TGroupPanel;
  begin
    if C is TGroupPanel then Result := TGroupPanel(C) else Result := nil;
  end;

  function FindGrp(Root: TWinControl; const Title: string): TGroupPanel;
  var
    I, J: Integer;
  begin
    Result := nil;
    for I := 0 to Root.ControlCount - 1 do
      if Root.Controls[I] is TWinControl then
      begin
        if Root.Controls[I] is TGroupPanel then
          for J := 0 to TGroupPanel(Root.Controls[I]).ControlCount - 1 do
            if (TGroupPanel(Root.Controls[I]).Controls[J] is TLabel) and
              (TLabel(TGroupPanel(Root.Controls[I]).Controls[J]).Caption = Title) then
              Exit(TGroupPanel(Root.Controls[I]));
        Result := FindGrp(TWinControl(Root.Controls[I]), Title);
        if Result <> nil then
          Exit;
      end;
  end;

var
  G: TGroupPanel;
begin
  // Makros (Schnell): sobald einer nicht auf 50 % steht
  G := FindGrp(Self, Tr('Makros  (50 % = Preset unverändert)'));
  if G <> nil then
    G.LedFunc := function: Boolean
      var
        Id: TGranularParamId;
      begin
        Result := False;
        for Id := gpMacroTexture to gpMacroEnv do
          if Abs(FEngine.GetParamById(Id) - 0.5) > 0.005 then
            Exit(True);
      end;
  // Grain-Reiter: alle drei Bereiche leuchten, wenn die Grains an sind
  for G in [Grp(FCols[0]), Grp(FCols[1]), Grp(FCols[2])] do
    if G <> nil then
      G.LedFunc := function: Boolean
        begin
          Result := FEngine.GetParamById(gpGrainOn) >= 0.5;
        end;
  // Zonen: sobald eine Zone ein Sample hat
  G := FindGrp(Self, Tr('Zonen: weitere Samples je Tastenbereich'));
  if G <> nil then
    G.LedFunc := function: Boolean
      var
        Z: Integer;
      begin
        Result := False;
        for Z := 1 to ZONE_COUNT do
          if FEngine.ZoneSample(Z) <> nil then
            Exit(True);
      end;
  // freie Makros: sobald einer ein Ziel in der Matrix hat
  G := FindGrp(Self, Tr('Freie Makros'));
  if G <> nil then
    G.LedFunc := function: Boolean
      var
        K, S2: Integer;
      begin
        Result := False;
        for S2 := 0 to MOD_SLOTS - 1 do
          if ParamStep(SlotDestIndex(S2), FEngine.GetParam(SlotDestIndex(S2))) > 0 then
            for K := 0 to UMAC_COUNT - 1 do
              if ParamStep(SlotSourceIndex(S2), FEngine.GetParam(SlotSourceIndex(S2))) = Ord(UMAC_SRC[K]) then
                Exit(True);
      end;
  // Saettigung > 0
  G := FindGrp(Self, Tr('Sättigung, Stereo, Ausgang'));
  if G <> nil then
    G.LedFunc := function: Boolean
      begin
        Result := ParamToPlain(gpDrive, FEngine.GetParamById(gpDrive)) > 0.05;
      end;
  // Harmonie: Tonleiter gewaehlt
  G := FindGrp(Self, Tr('Harmonie'));
  if G <> nil then
    G.LedFunc := function: Boolean
      begin
        Result := ParamStep(Ord(gpScale), FEngine.GetParamById(gpScale)) > 0;
      end;
  UpdateLeds(Self);
end;

procedure TGranularEditor.ComboChange(Sender: TObject);
var
  B: TParamBinding;
begin
  if FUpdating then
    Exit;
  B := FBindings[(Sender as TComponent).Tag];
  if B.Combo.ItemIndex < 0 then
    Exit;   // Eingabe passt (noch) zu keinem Eintrag
  FEngine.SetParam(B.Index, StepToParam(B.Index, ComboStepOfItem(B, B.Combo.ItemIndex)));
  ParamChangedByUser(B.Index, (Sender as TComponent).Tag);
  if (B.Combo.ItemIndex = LFO_SHAPE_FREE) then
    for var LK := 0 to LFO_COUNT - 1 do
      if B.Index = Ord(LFO_SHAPE_IDS[LK]) then
        OpenFreeEditor(LFO_FREE_IDX[LK]);
  if (B.Index = Ord(gpMorphLfoShape)) and (B.Combo.ItemIndex = MORPH_LFO_FREE) then
    OpenFreeEditor(2);
end;

procedure TGranularEditor.CheckClick(Sender: TObject);
var
  B: TParamBinding;
begin
  if FUpdating then
    Exit;
  B := FBindings[(Sender as TComponent).Tag];
  FEngine.SetParam(B.Index, IfThen(B.Check.Checked, 1.0, 0.0));
  UpdateLeds(Self);
  if B.OnOffCaption then
    B.NameLabel.Caption := System.StrUtils.IfThen(B.Check.Checked, 'an', 'aus');
  ParamChangedByUser(B.Index, (Sender as TComponent).Tag);
end;

procedure TGranularEditor.SetOnSidechainSwitch(const Value: TSidechainSwitchEvent);
begin
  FOnSidechainSwitch := Value;
  FMicCheck.Visible := Assigned(Value);
  FMicLabel.Visible := Assigned(Value);
end;

procedure TGranularEditor.MicClick(Sender: TObject);
begin
  if FUpdating or not Assigned(FOnSidechainSwitch) then
    Exit;
  if not FOnSidechainSwitch(Self, FMicCheck.Checked) then
  begin
    FUpdating := True;
    try
      FMicCheck.Checked := False;
    finally
      FUpdating := False;
    end;
  end;
end;

procedure TGranularEditor.SyncWaveFromParams;
begin
  FWave.SetSelection(
    ParamToPlain(gpSelStart, FEngine.GetParamById(gpSelStart)) / 100,
    ParamToPlain(gpSelEnd, FEngine.GetParamById(gpSelEnd)) / 100);
  FWave.SetPosition(
    ParamToPlain(gpPosition, FEngine.GetParamById(gpPosition)) / 100,
    ParamToPlain(gpSpray, FEngine.GetParamById(gpSpray)) / 100);
  if FEngine.GetParamById(gpPreOn) >= 0.5 then
    FWave.SetPreStart(ParamToPlain(gpPreStart, FEngine.GetParamById(gpPreStart)) / 100)
  else
    FWave.SetPreStart(-1);
end;

{ Anlauf-Start in der Wellenform gesetzt/gezogen: Schalter und Regler nachziehen }
procedure TGranularEditor.WavePreStartChange(Sender: TObject);
begin
  if FWave.PreStart < 0 then
    FEngine.SetParamById(gpPreOn, 0)
  else
  begin
    FEngine.SetParamById(gpPreOn, 1);
    FEngine.SetParamById(gpPreStart, PlainToParam(gpPreStart, FWave.PreStart * 100));
  end;
  SetControlValue(FBindingOf[Ord(gpPreOn)], FEngine.GetParamById(gpPreOn));
  SetControlValue(FBindingOf[Ord(gpPreStart)], FEngine.GetParamById(gpPreStart));
  if FCommitted <> nil then
  begin
    FCommitted[Ord(gpPreOn)] := FEngine.GetParamById(gpPreOn);
    FCommitted[Ord(gpPreStart)] := FEngine.GetParamById(gpPreStart);
  end;
end;

procedure TGranularEditor.WaveSelectionChange(Sender: TObject);
begin
  FEngine.SetParamById(gpSelStart, PlainToParam(gpSelStart, FWave.SelStart * 100));
  FEngine.SetParamById(gpSelEnd, PlainToParam(gpSelEnd, FWave.SelEnd * 100));
  SetControlValue(FBindingOf[Ord(gpSelStart)], FEngine.GetParamById(gpSelStart));
  SetControlValue(FBindingOf[Ord(gpSelEnd)], FEngine.GetParamById(gpSelEnd));
end;

procedure TGranularEditor.WavePositionChange(Sender: TObject);
begin
  FEngine.SetParamById(gpPosition, PlainToParam(gpPosition, FWave.Position * 100));
  SetControlValue(FBindingOf[Ord(gpPosition)], FEngine.GetParamById(gpPosition));
end;

{ --- Sample --- }

procedure TGranularEditor.SetSample(Data: TSampleData);
begin
  FWave.SetSample(Data);     // Peaks berechnen, solange wir die Daten sicher lesen
  FEngine.LoadSample(Data);  // danach gehoert das Sample der Engine
end;

function TGranularEditor.SamplePath: string;
begin
  Result := FEngine.SamplePath;
end;

procedure TGranularEditor.SyncSampleFromEngine;
begin
  FWave.SetSample(FEngine.Sample);
  UpdateFromEngine;
end;

procedure TGranularEditor.LoadFile(const FileName: string);
begin
  SetSample(LoadAudioFile(FileName));
end;

procedure TGranularEditor.LoadClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := AUDIO_FILE_FILTER;
    if DirectoryExists(FBaseDir + 'Beispieltoene') then
      Dlg.InitialDir := FBaseDir + 'Beispieltoene';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if Dlg.Execute then
    try
      LoadFile(Dlg.FileName);
    except
      on E: Exception do
        MessageDlg(Tr('Datei konnte nicht geladen werden:') + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TGranularEditor.PanicClick(Sender: TObject);
begin
  ReleaseAllKeys;
  FEngine.AllNotesOff;
end;

procedure TGranularEditor.OctaveClick(Sender: TObject);
begin
  if Sender = FOctUp then
    FOctave := Min(FOctave + 1, 8)
  else
    FOctave := Max(FOctave - 1, 0);
  UpdatePcRange;
end;

procedure TGranularEditor.UpdatePcRange;
begin
  FKeys.SetPcRange((FOctave + 1) * 12, 17);
end;

const
  // Stufen 0..6: Vordergrund (Budget 10 %), 7..8: Hintergrund (Budget 1 %)
  // Vordergrund: Timer 15 ms (Banner) / 33 ms (Anzeigen); Hintergrund: beide 250 ms
  GFX_DIVIDER: array[0..8] of Integer = (1, 2, 3, 4, 6, 8, 10, 1, 4);   // Banner: 60/30/20/15/10/8/6 | 4/1 B/s
  VIEW_DIVIDER: array[0..8] of Integer = (1, 1, 1, 1, 2, 3, 4, 1, 4);   // Anzeigen: 30/30/30/30/15/10/8 | 4/1 B/s
  GFX_FG_MAX = 6;            // hoechste Stufe im Vordergrund
  GFX_BG_MIN = 7;            // erste Hintergrund-Stufe
  GFX_UP_SECONDS = 3;        // so viele ruhige Sekunden, bevor es wieder fluessiger wird
  GFX_DOWN_SECONDS = 2;      // so viele Sekunden ueber dem Limit, bevor gespart wird
  GFX_BG_HIGH = 1.0;         // Hintergrund: hoechstens ~1 % einer CPU
  GFX_BG_LOW = 0.4;
  GFX_BUDGET_HIGH = 10.0;    // Sicherung: Zeichnen darf im Vordergrund 10 % einer CPU nicht ueberschreiten
  GFX_BUDGET_LOW = 5.0;      // erst darunter (3 s lang) wieder eine Stufe fluessiger
  GFX_FG_BEST = 1;           // beste Stufe im Vordergrund: 30 B/s - fluessig, aber keine Dauerlast

{ Misst einmal je Sekunde die CPU-Zeit des GUI-Threads (alle Timer laufen dort) und
  passt die Bildrate an. Schnelle PCs bleiben bei 60 B/s, langsame finden ihre Stufe. }
procedure TGranularEditor.CheckGfxBudget;
var
  Creation, ExitT, Kernel, User: TFileTime;
  Cpu, Wall, Freq: Int64;
  Load, High, Low: Double;
  Fg: Boolean;
  FgWnd: HWND;
  FgPid: DWORD;
begin
  // Fenster minimiert oder unsichtbar: alles anhalten, nur noch selten nachsehen, ob es wieder da ist
  if HandleAllocated and (IsIconic(GetAncestor(Handle, GA_ROOT)) or not IsWindowVisible(Handle)) then
  begin
    if not FAnimPaused then
    begin
      FAnimPaused := True;
      FBannerTimer.Interval := 500;
      FTimer.Interval := 500;
      FFgKnown := False;                         // beim Wiedererscheinen Takt neu setzen
    end;
    Exit;
  end;
  if FAnimPaused then
  begin
    FAnimPaused := False;
    FBannerLast := 0;                            // kein Zeitsprung in der Animation
  end;
  // Vordergrund = das aktive Fenster gehoert zu unserem Programm (GranularHost bzw. FL Studio).
  // Robuster als ein Fenstervergleich: egal ob Plugin, Host-Leiste oder anderes Host-Fenster
  // angeklickt ist - erst der Wechsel in ein anderes Programm zaehlt als Hintergrund.
  FgWnd := GetForegroundWindow;
  FgPid := 0;
  if FgWnd <> 0 then
    GetWindowThreadProcessId(FgWnd, FgPid);
  Fg := (FgPid <> 0) and (FgPid = GetCurrentProcessId);
  // beim ersten Mal den tatsaechlichen Zustand immer anwenden (nicht nur bei Wechsel)
  if (Fg <> FIsForeground) or not FFgKnown then
  begin
    FFgKnown := True;
    FIsForeground := Fg;
    if Fg then
    begin
      FGfxLevel := Max(FFgLevel, GFX_FG_BEST);  // sofort zurueck (hoechstens 30 B/s)
      FBannerTimer.Interval := 15;             // volle Animationsrate moeglich
      FTimer.Interval := 33;                   // Anzeigen/Regler: 30 Hz reichen
    end
    else
    begin
      FFgLevel := Min(FGfxLevel, GFX_FG_MAX);
      FGfxLevel := Max(FGfxLevel, GFX_BG_MIN);  // sofort sparen, nicht erst nachregeln
      // Timer selbst verlangsamen: nichts wacht mehr unnoetig auf
      FBannerTimer.Interval := 250;
      FTimer.Interval := 250;
    end;
    FGfxCheckWall := 0;                         // Messung neu beginnen
  end;
  QueryPerformanceCounter(Wall);
  QueryPerformanceFrequency(Freq);
  if not GetThreadTimes(GetCurrentThread, Creation, ExitT, Kernel, User) then
    Exit;
  Cpu := Int64(Kernel) + Int64(User);            // 100-ns-Einheiten
  if FGfxCheckWall = 0 then
  begin
    FGfxCheckWall := Wall;
    FGfxCheckCpu := Cpu;
    Exit;
  end;
  if (Wall - FGfxCheckWall) < Freq then
    Exit;                                        // erst nach einer Sekunde bewerten
  Load := (Cpu - FGfxCheckCpu) / 1E7 / ((Wall - FGfxCheckWall) / Freq) * 100;
  FGfxCheckWall := Wall;
  FGfxCheckCpu := Cpu;
  if FIsForeground then
  begin
    // einfache Sicherung mit weiter Hysterese: >10 % fuer 2 s -> eine Stufe sparsamer,
    // <5 % fuer 3 s -> eine Stufe fluessiger, aber nie ueber 30 B/s
    if FGfxStart = 0 then
      FGfxStart := Wall;
    if Wall - FGfxStart < 3 * Freq then
      Exit;                                    // Startlast nicht bewerten
    if Load > GFX_BUDGET_HIGH then
    begin
      Inc(FGfxOver);
      FGfxCalm := 0;
      if (FGfxOver >= GFX_DOWN_SECONDS) and (FGfxLevel < GFX_FG_MAX) then
      begin
        Inc(FGfxLevel);
        FGfxOver := 0;
      end;
    end
    else if Load < GFX_BUDGET_LOW then
    begin
      FGfxOver := 0;
      Inc(FGfxCalm);
      if (FGfxCalm >= GFX_UP_SECONDS) and (FGfxLevel > GFX_FG_BEST) then
      begin
        Dec(FGfxLevel);
        FGfxCalm := 0;
      end;
    end
    else
    begin
      FGfxOver := 0;
      FGfxCalm := 0;
    end;
  end
  else
  begin
    High := GFX_BG_HIGH; Low := GFX_BG_LOW;
    if (Load > High) and (FGfxLevel < Length(GFX_DIVIDER) - 1) then
      Inc(FGfxLevel)
    else if (Load < Low) and (FGfxLevel > GFX_BG_MIN) then
      Dec(FGfxLevel);
  end;
end;


{ rechter Rand des tatsaechlich sichtbaren Bereichs von C (in C-Koordinaten): Client-Bereich des
  Hauptfensters (Host/DAW), in das das Plugin eingebettet ist }
function VisibleRight(C: TWinControl): Integer;
var
  Root: HWND;
  R: TRect;
  P: TPoint;
begin
  Result := C.ClientWidth;
  if not C.HandleAllocated then
    Exit;
  Root := GetAncestor(C.Handle, GA_ROOT);
  if (Root = 0) or (Root = C.Handle) or not GetClientRect(Root, R) then
    Exit;
  P := Point(R.Right, 0);
  Winapi.Windows.ClientToScreen(Root, P);
  Result := Min(Result, C.ScreenToClient(P).X);
end;

procedure TGranularEditor.BannerTimerTick(Sender: TObject);
var
  Now64, Freq: Int64;
  Dt: Double;
  S: Integer;
begin
  CheckGfxBudget;
  if FAnimPaused then
    Exit;
  Inc(FBannerTick);
  // beste Vordergrundstufe: 4 von 5 Takten (~50 B/s, fluessig), sonst jeder n-te Takt
  if FGfxLevel = GFX_FG_BEST then
  begin
    if FBannerTick mod 5 = 4 then
      Exit;
  end
  else if FBannerTick mod GFX_DIVIDER[FGfxLevel] <> 0 then
    Exit;
  // echte vergangene Zeit -> gleichmaessige Bewegung, auch wenn ein Bild verspaetet kommt
  QueryPerformanceCounter(Now64);
  QueryPerformanceFrequency(Freq);
  if FBannerLast = 0 then
    Dt := 0.016
  else
    Dt := EnsureRange((Now64 - FBannerLast) / Freq, 0, 0.3);
  FBannerLast := Now64;
  // Taenzer waagrecht im goldenen Schnitt des Einstellungs-Rechtecks (selten neu berechnen)
  // Taenzer rechtsbuendig: ausgestreckter Arm haelt denselben Abstand zum rechten Rand wie das
  // Stil-Feld zum rechten Rand des Einstellungs-Rechtecks (selten neu berechnen)
  // Das Einstellungs-Rechteck waechst mit dem Fenster, das Stil-Feld nicht: deshalb am rechten
  // Rand des Rechtecks ausrichten (Abstand wie Stil-Feld zum linken Rand der Bedienelemente)
  // Abstand zum rechten Banner-Rand nur messen, solange der Schnell-Reiter sichtbar ist (verdeckte
  // Reiter werden beim Vergroessern nicht neu ausgerichtet); die Position folgt der Bannerbreite immer.
  if (FQuickPV <> nil) and (FVaryStyle <> nil) and (FBannerTick mod 16 = 1) and
     FQuickPV.Showing and FBanner.HandleAllocated then
    FDancerGap := FBanner.ClientWidth - FBanner.ScreenToClient(FQuickPV.ClientToScreen(
      Point(FQuickPV.ClientWidth - UiPt(12), 0))).X;
  if FDancerGap <= 0 then
    FDancerGap := UiPt(24);   // bis zur ersten Messung: Rand von Reiter + Einstellungs-Rechteck
  // Ist das Fenster des Hosts schmaler als das Plugin (z. B. 125 % auf einem kleinen Bildschirm), wird rechts
  // abgeschnitten: Granuli dann am sichtbaren rechten Rand ausrichten, damit sie nicht halb verschwindet
  FBanner.DancerX := Min(FBanner.ClientWidth, VisibleRight(FBanner)) - FDancerGap;
  FBanner.Tick(Dt);
  if FPages.ActivePage = FTabQuick then
    FSpectrum.Tick;
  if (FPages.ActivePage = FTabMix) and (FMixSpectrum <> nil) then
    FMixSpectrum.Tick;
  if (FPages.ActivePage = FTabExtra) and (FArpPattern <> nil) then
    FArpPattern.Tick;
  // Morph-LFO: laufend nur, wenn er an ist; sonst selten (Formwechsel sichtbar machen)
  if (FPages.ActivePage = FTabExtra) and (FMorphLfoView <> nil) and
     ((FEngine.GetParam(Ord(gpMorphLfoShape)) > 0) or (FBannerTick mod 16 = 0)) then
    FMorphLfoView.ForceFullInvalidate;
  if (FPages.ActivePage = FTabEq) and (FEqView <> nil) then
    FEqView.Tick;
  // LFO-Anzeigen mit Leuchtspur im selben fluessigen Takt (nur wenn sichtbar)
  if (FPages.ActivePage = FTabMod2) and (FLfoViews[2] <> nil) then
    for S := 0 to LFO_COUNT - 1 do
      if S div 4 = FLfoPage then
        FLfoViews[S].ForceFullInvalidate;
  if FPages.ActivePage = FTabMod then
  begin
    for S := 0 to MOD_SLOTS - 1 do
      FSlotLeds[S].UpdateGlow;   // zeichnet nur, wenn sich die Helligkeit merklich aendert
  end;
end;

{ Laufzeit-Statistik einmal je Sekunde: Differenzen der Zaehler aus dem Audio-Thread }
procedure TGranularEditor.UpdateProcStat;
var
  Now64, Freq, Calls, Frames, Ticks, MaxT, Host, Hops: Int64;
  Sec, AvgFr, Load, MaxLoad, HostPct: Double;
begin
  QueryPerformanceCounter(Now64);
  QueryPerformanceFrequency(Freq);
  if (FStLast <> 0) and (Now64 - FStLast < Freq) then
    Exit;
  FEngine.GetProcStat(Calls, Frames, Ticks, MaxT, Host, Hops, True);
  if FStLast <> 0 then
  begin
    Sec := (Now64 - FStLast) / Freq;
    Calls := Calls - FStPrev[0]; Frames := Frames - FStPrev[1]; Ticks := Ticks - FStPrev[2];
    Host := Host - FStPrev[4]; Hops := Hops - FStPrev[5];
    if Calls > 0 then
    begin
      AvgFr := Frames / Calls;
      Load := 100 * (Ticks / Freq) / Max(Sec, 0.001);                       // Anteil an der Echtzeit
      MaxLoad := 100 * (MaxT / Freq) / Max(AvgFr / FEngine.SampleRate, 1E-6);  // laengster Aufruf / Pufferdauer
      HostPct := 100 * (Host / Freq) / Max(Sec, 0.001);
      FProcStat.Caption := Format(Tr('Laufzeit: %d Aufrufe/s, %.0f Samples, Rechenzeit %.1f %% (max. %.0f %% eines Puffers)') +
        sLineBreak + Tr('DAW-Rückfragen %.2f %%, Thread-Wechsel %d/s'),
        [Round(Calls / Sec), AvgFr, Load, MaxLoad, HostPct, Round(Hops / Sec)]);
      FLoadGauge.SetValues(Load, MaxLoad, FLoadList.TheoryPercent);
    end
    else
    begin
      FProcStat.Caption := Tr('Laufzeit: keine Aufrufe der DAW (Plugin pausiert)');
      FLoadGauge.SetValues(0, 0, FLoadList.TheoryPercent);
    end;
  end;
  FEngine.GetProcStat(FStPrev[0], FStPrev[1], FStPrev[2], FStPrev[3], FStPrev[4], FStPrev[5], False);
  FStLast := Now64;
end;

{ Eingangspegel als dB-Text, '-' fuer Stille }
function InDb(P: Single): string;
begin
  if P < 0.0001 then
    Result := '  -  '
  else
    Result := Format(Tr('%4.0f dB'), [20 * Log10(P)]);
end;

{ Zahl rechtsbuendig auf feste Stellenzahl: vorn Ziffern-Leerzeichen (gleich breit wie eine Ziffer) }
function FixNum(N, Digits: Integer): string;
begin
  Result := IntToStr(N);
  while Length(Result) < Digits do
    Result := #$2007 + Result;
end;

{ Sample-Namen fuer die Kopfleiste kuerzen (voller Name steht im Tooltip) }
function ShortName(const S: string): string;
begin
  if Length(S) > 16 then
    Result := Copy(S, 1, 15) + '...'
  else
    Result := S;
end;

{ Lampen des sichtbaren Reiters: Helligkeit nachfuehren }
procedure SagLeds(Root: TWinControl; Br: Single);
var
  I: Integer;
begin
  for I := 0 to Root.ControlCount - 1 do
    if Root.Controls[I] is TWinControl then
    begin
      if Root.Controls[I] is TGroupPanel then
        TGroupPanel(Root.Controls[I]).SagLed(Br);
      SagLeds(TWinControl(Root.Controls[I]), Br);
    end;
end;

procedure TGranularEditor.TimerTick(Sender: TObject);
var
  LedPk: Single;
  Tmp: Boolean;
  PC, GC, I, O: Integer;
  LimDb: Single;
  EnvKey: Double;
  LiveFrame: Boolean;
  AnimInfo, SmpA, SmpB, SmpInfo, SmpFull: string;
  MorphB: Single;
begin
  // Netzteil am Limit: lauter Ausgang laesst die Lampen leicht einbrechen (schnell rein, langsam erholen),
  // dazu ein ganz leichtes Flackern
  LedPk := EnsureRange((FEngine.OutputPeak - 0.12) / 0.45, 0, 1);
  if LedPk > FLedSag then
    FLedSag := FLedSag + (LedPk - FLedSag) * 0.5
  else
    FLedSag := FLedSag + (LedPk - FLedSag) * 0.08;
  if (FPages <> nil) and (FPages.ActivePage <> nil) then
  begin
    UpdateLeds(FPages.ActivePage);
    SagLeds(FPages.ActivePage, 1 - 0.42 * FLedSag - 0.08 * FLedSag * Random);
  end;
  FEngine.ResPrepare;                          // Resampling eingeschaltet: Puffer anlegen (nicht im Audio-Thread)
  if FAnimPaused then
    Exit;                                      // minimiert/unsichtbar: nichts zeichnen
  Inc(FMainTick);
  if (FResLabel <> nil) and (FPages.ActivePage = FTabSamples) then
    if FEngine.GetParam(Ord(gpResOn)) < 0.5 then
      FResLabel.Caption := ''
    else if FEngine.ResActive then
      FResLabel.Caption := Format(Tr('Durchlauf %d'), [FEngine.ResPasses])
    else
      FResLabel.Caption := Tr('Spielt das Original - der erste Durchlauf läuft ...');
  if (FUpdHost <> nil) and not FUpdHost.Visible and UpdateAvailable(FUpdVersion, FUpdPage) then
  begin
    if UpdateSetupPath <> '' then
      FUpdIcon.Hint := Format(Tr('Neue Version %s verfügbar (installiert: %s). Klick: Setup starten - dort "Online-Update".'),
        [FUpdVersion, APP_VERSION])
    else
      FUpdIcon.Hint := Format(Tr('Neue Version %s verfügbar (installiert: %s). Klick: Download-Seite öffnen.'),
        [FUpdVersion, APP_VERSION]);
    FUpdHost.Visible := True;
    FUpdHost.BringToFront;
  end;
  if (FHostEditParam >= 0) and (GetTickCount - FHostEditTick > 400) and (GetCapture = 0) then
    EndHostEdit;
  if FLearnBinding >= 0 then
    PollMidiLearn;
  FEngine.MetersOn := FPages.ActivePage = FTabMix;
  FEngine.FilterScopeOn := (FFltView <> nil) and (FPages.ActivePage = FTabFlt);
  if FEngine.FilterScopeOn then
    FFltView.Tick;
  UpdateWtNames;
  if (FCompCurve <> nil) and (FPages.ActivePage = FTabEq) then
  begin
    AnimInfo := Format('%.4f|%.4f|%.4f|%.4f|%.4f', [FEngine.GetParamById(gpCompOn), FEngine.GetParamById(gpCompAmt),
      FEngine.GetParamById(gpCompRatio), FEngine.GetParamById(gpCompThresh), FEngine.GetParamById(gpCompKnee)]);
    if AnimInfo <> FCompSig then
    begin
      FCompSig := AnimInfo;
      FCompCurve.Invalidate;
    end;
  end;
  if FPages.ActivePage = FTabTiming then
    for I := 0 to DLY_EVENT_COUNT - 1 do
      with FBindings[FDlyMsIdx[I]] do
      begin
        // gilt ein Notenwert, ist der ms-Regler ohne Wirkung (Name bleibt lesbar)
        Track.Enabled := FEngine.GetParam(Ord(DLY_SYNC[I])) < 0.5 / 14;
        ValueLabel.Visible := Track.Enabled;
      end;
  if FPages.ActivePage = FTabMod2 then
  begin
    if FMainTick mod 15 = 0 then
      UpdateLfoPageCaptions;              // "LFO 5-8 (2 benutzt)"
    for I := 0 to LFO_COUNT - 1 do
    begin
      // Stoppzeit nur bei Stopp 'nach Zeit'; ms-Regler ohne Wirkung, wenn ein Notenwert gilt
      Tmp := ParamStep(Ord(LFO_STOP_IDS[I]), FEngine.GetParam(Ord(LFO_STOP_IDS[I]))) = LFO_STOP_TIME;
      FBindings[FStopSyncIdx[I]].Combo.Enabled := Tmp;
      // Partner nur, wenn Start oder Stopp 'Ende Partner-LFO' ist
      FBindings[FPartnerIdx[I]].Combo.Enabled :=
        (ParamStep(Ord(LFO_TRIG_IDS[I]), FEngine.GetParam(Ord(LFO_TRIG_IDS[I]))) = LFO_TRIG_OTHER_END) or
        (ParamStep(Ord(LFO_STOP_IDS[I]), FEngine.GetParam(Ord(LFO_STOP_IDS[I]))) = 3);
      with FBindings[FStopMsIdx[I]] do
      begin
        Track.Enabled := Tmp and (FEngine.GetParam(FBindings[FStopSyncIdx[I]].Index) < 0.5 / 14);
        ValueLabel.Visible := Track.Enabled;
      end;
    end;
  end;
  if FEngine.Recording or ((FRecButton <> nil) and (FRecButton.Tag = 1)) then
  begin
    if not FEngine.Recording and (FRecButton.Tag = 1) then
      RecClick(nil)                       // Puffer voll: Aufnahme endet von selbst -> laden
    else if FMainTick mod 8 = 0 then
      FRecLabel.Caption := Format(Tr('Aufnahme läuft: %.1f s (max. 60 s)'), [FEngine.RecordedSeconds]);
  end;
  if (FPages.ActivePage = FTabFx2) and (FGatePattern <> nil) then
    FGatePattern.Tick;
  if (FPages.ActivePage = FTabPerf) and (FProcStat <> nil) then
  begin
    UpdateProcStat;
    if FMainTick mod 8 = 0 then
      FLoadList.Tick;                  // Zustand der Bloecke (zeichnet nur bei Aenderung)
    FLoadGauge.Tick;
  end;
  if (FPages.ActivePage = FTabMix) and (FInLevels <> nil) and (FMainTick mod 4 = 0) then
    FInLevels.Caption := Format(Tr('Pegel  E1 %s   E2 %s   E3 %s   E4 %s'),
      [InDb(FEngine.VstInputPeak(0)), InDb(FEngine.VstInputPeak(1)), InDb(FEngine.VstInputPeak(2)), InDb(FEngine.VstInputPeak(3))]);
  if FEngine.MetersOn then
    for I := 0 to MIX_METERS - 1 do
      if FMixMeters[I] <> nil then
        FMixMeters[I].Feed(FEngine.TakeMeter(I));
  if FPages.ActivePage = FTabMod then
    for I := 0 to MOD_SLOTS - 1 do
      if FSlotGlobal[I] <> nil then
        FSlotGlobal[I].Visible := (I div MAT_ROWS = FMatPage) and FEngine.SlotIsGlobalNote(I);
  // Vordergrund laeuft der Anzeige-Timer mit 33 ms (30 Hz): Stufen 0..3 = jeder Takt,
  // gedrosselte Stufen entsprechend seltener; Hintergrund (250 ms) wie gehabt
  if FGfxLevel >= GFX_BG_MIN then
    LiveFrame := FMainTick mod VIEW_DIVIDER[FGfxLevel] = 0
  else
    LiveFrame := FMainTick mod VIEW_DIVIDER[FGfxLevel] = 0;
  // Wertanzeigen und Status: hoechstens jeder zweite Takt (15 Hz)
  if not LiveFrame and (FMainTick mod 2 <> 0) then
    Exit;
  // Hintergrund: den ganzen Anzeige-Timer (inkl. Wertanzeigen) nur im langsamen Takt
  if (FGfxLevel >= GFX_BG_MIN) and not LiveFrame then
    Exit;
  PC := FEngine.GetPlayheads(FPlayheads);
  if FEngine.ActiveGrains > 0 then
    GC := FEngine.GetRecentGrains(FGrains)
  else
    GC := 0;
  if not LiveFrame then
    // Animationen ausgelassen (Grafik-Budget), Rest des Timers laeuft normal weiter
  else if FPages.ActivePage = FTabSynth then
  begin
    FWave.SetLiveData(FPlayheads, PC, FGrains, GC);
    // Huellkurve nur neu zeichnen, wenn sie laeuft oder sich ihre Regler geaendert haben
    EnvKey := FEngine.EffParam[Ord(gpAttack)] + 3.1 * FEngine.EffParam[Ord(gpDecay)] +
      7.3 * FEngine.EffParam[Ord(gpSustain)] + 13.7 * FEngine.EffParam[Ord(gpRelease)];
    if FEngine.GetEnvelopeState.Active or (EnvKey <> FEnvKey) then
    begin
      FEnvKey := EnvKey;
      FEnvView.ForceFullInvalidate;
    end;
  end
  else if (FPages.ActivePage = FTabOsc[0]) or (FPages.ActivePage = FTabOsc[1]) or
          (FPages.ActivePage = FTabOsc[2]) then
  begin
    O := FPages.ActivePage.PageIndex - FTabOsc[0].PageIndex;
    // Welle / Gezeichnet ausgrauen, wenn etwas Vorrangiges spielt: Wavetable > Zeichnung > Welle
    PC := 0;
    if (FEngine.GetParam(Ord(OSC_P[O].WtOn)) >= 0.5) and (FEngine.WtFrameCount(O) > 0) then
      PC := 2
    else if FEngine.GetParam(Ord(OSC_P[O].Draw)) >= 0.5 then
      PC := 1;
    if PC <> FWaveState[O] then
    begin
      FWaveState[O] := PC;
      SetBindingEnabled(FWaveIdx[O], PC = 0);
      SetBindingEnabled(FDrawIdx[O], PC < 2);
    end;
    // FM-Klangfarbe ausgrauen, solange sie nicht wirkt (andere Welle bzw. Haken aus)
    I := 0;
    if PC > 0 then
      I := 0                             // Wavetable/Zeichnung: keine FM-Welle
    else if ParamStep(Ord(OSC_P[O].Wave), FEngine.GetParam(Ord(OSC_P[O].Wave))) = 5 then
      I := 3                             // Rauschen: Sync wirkungslos
    else if ParamStep(Ord(OSC_P[O].Wave), FEngine.GetParam(Ord(OSC_P[O].Wave))) = 4 then
    begin
      I := 1;
      if FEngine.GetParam(Ord(OSC_P[O].FmEnvOn)) >= 0.5 then I := 2;
    end;
    if I <> FFmEnvState[O] then
    begin
      FFmEnvState[O] := I;
      SetBindingEnabled(FFmEnvIdx[O, 0], I in [1, 2]);
      for PC := 1 to 4 do
        SetBindingEnabled(FFmEnvIdx[O, PC], I = 2);
      SetBindingEnabled(FSyncIdx[O], I <> 3);
    end;
    // Oszillator-Huellkurve: nur neu zeichnen, wenn eine Stimme laeuft oder Regler sich aendern
    EnvKey := FEngine.EffParam[Ord(OSC_P[O].Attack)] + 3.1 * FEngine.EffParam[Ord(OSC_P[O].Decay)] +
      7.3 * FEngine.EffParam[Ord(OSC_P[O].Sustain)] + 13.7 * FEngine.EffParam[Ord(OSC_P[O].Release)];
    if FEngine.GetOscEnvState(False, O).Active or (EnvKey <> FOscEnvKey[O]) then
    begin
      FOscEnvKey[O] := EnvKey;
      FOscEnvView[O].ForceFullInvalidate;
    end;
  end
  else if FPages.ActivePage = FTabTiming then
  begin
    for I := 0 to MENV_COUNT - 1 do
      if FMEnvView[I] <> nil then
      begin
        EnvKey := FEngine.EffParam[Ord(MENV_IDS[I, 0])] + 3.1 * FEngine.EffParam[Ord(MENV_IDS[I, 1])] +
          7.3 * FEngine.EffParam[Ord(MENV_IDS[I, 2])] + 13.7 * FEngine.EffParam[Ord(MENV_IDS[I, 3])];
        if FEngine.GetModEnvState(I).Active or (EnvKey <> FMEnvKey[I]) then
        begin
          FMEnvKey[I] := EnvKey;
          FMEnvView[I].ForceFullInvalidate;
        end;
      end;
  end
  else if FPages.ActivePage = FTabMod2 then
    begin FLevelView.UpdateLevel; FOutLevelView.UpdateLevel; end           // zeichnet nur bei Aenderung; LFO-Anzeigen im Banner-Takt
  else
  begin
    EnvKey := FEngine.EffParam[Ord(gpFltAttack)] + 3.1 * FEngine.EffParam[Ord(gpFltDecay)] +
      7.3 * FEngine.EffParam[Ord(gpFltSustain)] + 13.7 * FEngine.EffParam[Ord(gpFltRelease)];
    if FEngine.GetFilterEnvState.Active or (EnvKey <> FFltEnvKey) then
    begin
      FFltEnvKey := EnvKey;
      FFltEnvView.ForceFullInvalidate;
    end;
  end;
  SyncControlsFromEngine;
  // Monitor: bei Stille (kein Ausgang, kein Sidechain) nach ein paar Frames nicht mehr zeichnen
  if (FEngine.OutputPeak > 0.0002) or (FEngine.InputPeak > 0.0002) then
    FMonitorIdle := 0
  else if FMonitorIdle < 1000 then
    Inc(FMonitorIdle);
  // ab Stufe 3 den Monitor nur jedes zweite Mal zeichnen, ab Stufe 4 im Takt der Live-Anzeigen
  if (FMonitorIdle < 5) and LiveFrame and ((FGfxLevel < 3) or not Odd(FMainTick)) then
    FMonitor.ForceFullInvalidate;
  if LiveFrame then
  begin
    FEngine.GetActiveNotes(FSounding);   // klingende Noten auf der Klaviatur leuchten lassen
    FKeys.SetSounding(FSounding);
  end;
  if FPages.ActivePage = FTabQuick then
  begin
    LimDb := FEngine.TakeLimiterReduction;
    if LimDb < -0.1 then
      FLimiterLabel.Caption := Format(Tr('Reduktion %.1f dB'), [LimDb])
    else
      FLimiterLabel.Caption := Tr('keine Reduktion');
  end;
  if LiveFrame then
    for I := 0 to High(FBindings) do
      UpdateValueLabel(I);
  FClipLed.UpdateClip;   // zeichnet nur, wenn sich die Helligkeit sichtbar aendert
  FMidiLed.UpdateClip;
  if FIsForeground then
    if FGfxLevel = GFX_FG_BEST then
      AnimInfo := Tr('Anim 51 B/s')
    else
      AnimInfo := Format(Tr('Anim %d B/s'), [Round(64 / GFX_DIVIDER[FGfxLevel])])
  else
    AnimInfo := Format(Tr('Anim %d B/s (Hintergrund)'), [Round(4 / GFX_DIVIDER[FGfxLevel])]);
  // kurz halten, damit alles in die Kopfleiste passt; die Tastenbelegung steht im Tooltip
  // aktives Sample (bei Morph mit eigenem B-Sample: beide mit ihrem Anteil an den Grains)
  if FEngine.SamplePath <> '' then
    SmpA := ChangeFileExt(ExtractFileName(FEngine.SamplePath), '')
  else if IsEmptySample(FEngine.Sample) then
    SmpA := Tr('kein Sample')
  else
    SmpA := Tr('Demo-Klang (eingebaut)');
  if FEngine.MorphValid and (FEngine.MorphSampleLoaded <> '') and
     not SameText(FEngine.MorphSampleLoaded, FEngine.SamplePath) then
  begin
    MorphB := EnsureRange(FEngine.EffParam[Ord(gpMorph)], 0, 1);
    SmpB := ChangeFileExt(ExtractFileName(FEngine.MorphSampleLoaded), '');
    SmpFull := Tr('A: ') + SmpA + Tr('   B: ') + SmpB;
    SmpInfo := Format(Tr('A: %s %d %%  B: %s %d %%'), [ShortName(SmpA), Round((1 - MorphB) * 100),
      ShortName(SmpB), Round(MorphB * 100)]);
  end
  else
  begin
    SmpFull := Tr('Sample: ') + SmpA;
    SmpInfo := Tr('Sample: ') + ShortName(SmpA);
  end;
  if FEngine.GetParam(Ord(gpGrainOn)) < 0.5 then
  begin
    SmpInfo := Tr('Grains aus (nur Oszillator)');
    SmpFull := SmpInfo + ' - ' + SmpFull;
  end;
  // Zahlen mit fester Breite (Ziffern-Leerzeichen U+2007 = so breit wie eine Ziffer): beim Wechsel
  // von ein- auf mehrstellig rutschen die Trenner und der Samplename nicht hin und her
  FStatus.Caption := Format(Tr('Okt %s  |  %s Stimmen  |  %s Grains  |  %s'),
    [FixNum(FOctave, 2), FixNum(PC, 2), FixNum(FEngine.ActiveGrains, 4), SmpInfo]);
  FStatus.Hint := SmpFull + sLineBreak + AnimInfo + Tr(' - PC-Tastatur: A W S E D F T G Z H U J K O L P spielt, + / - wechselt die Oktave');
end;

{ --- Noten --- }

procedure TGranularEditor.PlayNote(Note: Integer; IsOn: Boolean);
begin
  if (Note < 0) or (Note > 127) then
    Exit;
  if IsOn then
    FEngine.NoteOn(Note, 0.8)
  else
    FEngine.NoteOff(Note);
  FKeys.SetPressed(Note, IsOn);
end;

procedure TGranularEditor.WheelChange(Sender: TObject);
begin
  if Sender = FBendWheel then
    FEngine.PitchBend(FBendWheel.Value)
  else
    FEngine.ControlChange(1, FModWheel.Value);
end;

procedure TGranularEditor.KeyboardNote(Sender: TObject; Note: Integer; IsOn: Boolean);
begin
  PlayNote(Note, IsOn);
end;

function TGranularEditor.PcKeyToSemitone(Key: Word): Integer;
begin
  case Key of
    Ord('A'): Result := 0;
    Ord('W'): Result := 1;
    Ord('S'): Result := 2;
    Ord('E'): Result := 3;
    Ord('D'): Result := 4;
    Ord('F'): Result := 5;
    Ord('T'): Result := 6;
    Ord('G'): Result := 7;
    Ord('Z'), Ord('Y'): Result := 8;   // Z (US) bzw. Y (DE) an derselben Stelle
    Ord('H'): Result := 9;
    Ord('U'): Result := 10;
    Ord('J'): Result := 11;
    Ord('K'): Result := 12;
    Ord('O'): Result := 13;
    Ord('L'): Result := 14;
    Ord('P'): Result := 15;
    VK_OEM_3: Result := 16;           // Oe auf deutscher Tastatur
  else
    Result := -1;
  end;
end;

function TGranularEditor.HandleKeyDown(Key: Word; Shift: TShiftState): Boolean;
var
  Semi: Integer;
begin
  Result := False;
  if Screen.ActiveControl is TCustomEdit then
    Exit;                                       // Eingabefeld hat die Tastatur (auch Strg+Z)
  if (ssCtrl in Shift) and not (ssAlt in Shift) then
  begin
    if (Key = Ord('Z')) and (ssShift in Shift) or (Key = Ord('Y')) then
    begin
      RedoClick(nil);
      Exit(True);
    end;
    if Key = Ord('Z') then
    begin
      UndoClick(nil);
      Exit(True);
    end;
  end;
  if (ssCtrl in Shift) or (ssAlt in Shift) then
    Exit;
  if (Key = VK_ESCAPE) and FEngine.MidiLearnPending then
  begin
    FEngine.MidiLearnCancel;
    FLearnBinding := -1;
    FStatus.Caption := Tr('MIDI-Learn abgebrochen');
    Exit(True);
  end;
  // aufgeklappte Auswahllisten brauchen die Tastatur selbst
  if (Screen.ActiveControl is TComboBox) and (TComboBox(Screen.ActiveControl).DroppedDown or
     (TComboBox(Screen.ActiveControl).Style = csDropDown)) then
    Exit;
  case Key of
    VK_ADD, VK_OEM_PLUS:
      begin
        OctaveClick(FOctUp);
        Exit(True);
      end;
    VK_SUBTRACT, VK_OEM_MINUS:
      begin
        OctaveClick(FOctDown);
        Exit(True);
      end;
  end;
  Semi := PcKeyToSemitone(Key);
  if Semi < 0 then
    Exit;
  Result := True;
  if FKeyNote[Key] >= 0 then
    Exit;  // Tastenwiederholung ignorieren
  FKeyNote[Key] := (FOctave + 1) * 12 + Semi;
  PlayNote(FKeyNote[Key], True);
end;

function TGranularEditor.HandleKeyUp(Key: Word): Boolean;
begin
  if (Screen.ActiveControl is TCustomEdit) and (FKeyNote[Key] < 0) then
    Exit(False);
  Result := PcKeyToSemitone(Key) >= 0;
  if FKeyNote[Key] >= 0 then
  begin
    PlayNote(FKeyNote[Key], False);
    FKeyNote[Key] := -1;
  end;
end;

procedure TGranularEditor.SetBaseDir(const Value: string);
begin
  if Value <> '' then
    FBaseDir := IncludeTrailingPathDelimiter(Value)
  else
    FBaseDir := '';
  RefreshPresets;
end;

procedure TGranularEditor.RefreshPresets;
var
  SR: TSearchRec;
  Dir: string;
  Names: TStringList;
  I: Integer;
begin
  LoadFavorites;
  FAllPresetNames := nil;
  FAllPresetFiles := nil;
  Dir := FBaseDir + 'Presets' + PathDelim;
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if (FBaseDir <> '') and (FindFirst(Dir + '*.gspreset', faAnyFile, SR) = 0) then
    try
      repeat
        Names.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    for I := 0 to Names.Count - 1 do
    begin
      FAllPresetNames := FAllPresetNames + [ChangeFileExt(Names[I], '')];
      FAllPresetFiles := FAllPresetFiles + [Dir + Names[I]];
    end;
  finally
    Names.Free;
  end;
  ApplyPresetFilter;
end;

{ Liste nach dem Suchtext filtern (Teiltext, Gross/Klein egal); gewaehltes Preset bleibt gewaehlt }
function TGranularEditor.IndexOfPresetFile(const FileName: string): Integer;
begin
  for Result := 1 to High(FPresetFiles) do
    if SameText(ExpandFileName(FPresetFiles[Result]), ExpandFileName(FileName)) then
      Exit;
  Result := -1;
end;

procedure TGranularEditor.ApplyPresetFilter;
var
  I, Sel: Integer;
  F, Cur: string;
begin
  Cur := '';
  if (FPresetCombo.ItemIndex > 0) and (FPresetCombo.ItemIndex <= High(FPresetFiles)) then
    Cur := FPresetFiles[FPresetCombo.ItemIndex];
  F := '';
  if FPresetFilter <> nil then
    F := LowerCase(Trim(FPresetFilter.Text));
  FPresetCombo.Items.BeginUpdate;
  try
    FPresetCombo.Items.Clear;
    FPresetFiles := [''];
    FPresetCombo.Items.Add(Tr('- Preset wählen -'));
    Sel := 0;
    for I := 0 to High(FAllPresetNames) do
      if ((F = '') or (Pos(F, LowerCase(FAllPresetNames[I])) > 0)) and
         ((FPresetCat = nil) or (FPresetCat.ItemIndex <= 0) or
          ((FPresetCat.ItemIndex = 1) and IsFavorite(FAllPresetFiles[I])) or
          ((FPresetCat.ItemIndex = CAT_RECENT) and IsRecent(FAllPresetFiles[I])) or
          ((FPresetCat.ItemIndex > 1) and (FPresetCat.ItemIndex <> CAT_RECENT) and
           PresetInCategory(FAllPresetNames[I], FPresetCat.ItemIndex))) then
      begin
        if IsFavorite(FAllPresetFiles[I]) then
          FPresetCombo.Items.Add('★ ' + FAllPresetNames[I])
        else
          FPresetCombo.Items.Add(FAllPresetNames[I]);
        FPresetFiles := FPresetFiles + [FAllPresetFiles[I]];
        if SameText(FAllPresetFiles[I], Cur) then
          Sel := High(FPresetFiles);
      end;
    if F <> '' then
      FPresetCombo.Items[0] := Format(Tr('- %d Treffer für "%s" -'), [High(FPresetFiles), Trim(FPresetFilter.Text)])
    else if (FPresetCat <> nil) and (FPresetCat.ItemIndex > 0) then
      FPresetCombo.Items[0] := Format(Tr('- %d Presets: %s -'), [High(FPresetFiles), FPresetCat.Text]);
  finally
    FPresetCombo.Items.EndUpdate;
  end;
  FUpdating := True;     // nur die Anzeige waehlen, nicht neu laden
  try
    FPresetCombo.ItemIndex := Sel;
  finally
    FUpdating := False;
  end;
  UpdateFavButton;
end;

{ Kategorien ergeben sich aus Stichworten im Presetnamen (Gross/Klein egal, Teilwort genuegt) }
function TGranularEditor.PresetInCategory(const Name: string; Cat: Integer): Boolean;
var
  N, W: string;
begin
  N := LowerCase(Name);
  if (Cat < 2) or (Cat > High(PRESET_CAT_WORDS)) then
    Exit(True);
  if Cat = CAT_LEARN then
    Exit((Length(N) >= 3) and (N[1] = 'l') and CharInSet(N[2], ['0'..'9']));
  for W in PRESET_CAT_WORDS[Cat].Split([',']) do
    if Pos(W, N) > 0 then
      Exit(True);
  Result := False;
end;

function TGranularEditor.IsFavorite(const FileName: string): Boolean;
var
  F, X: string;
begin
  F := ExtractFileName(FileName);
  for X in FFavorites do
    if SameText(X, F) then
      Exit(True);
  Result := False;
end;

function TGranularEditor.IsRecent(const FileName: string): Boolean;
var
  F, X: string;
begin
  F := ExtractFileName(FileName);
  for X in FRecent do
    if SameText(X, F) then
      Exit(True);
  Result := False;
end;

{ Preset an den Anfang der Liste "Zuletzt benutzt" (hoechstens RECENT_MAX), in Zuletzt.txt gemerkt }
procedure TGranularEditor.AddRecent(const FileName: string);
var
  F: string;
  L: TStringList;
  I: Integer;
begin
  F := ExtractFileName(FileName);
  if F = '' then
    Exit;
  L := TStringList.Create;
  try
    L.Add(F);
    for I := 0 to High(FRecent) do
      if not SameText(FRecent[I], F) and (L.Count < RECENT_MAX) then
        L.Add(FRecent[I]);
    FRecent := L.ToStringArray;
    if FBaseDir <> '' then
      try
        L.SaveToFile(FBaseDir + RECENT_FILE, TEncoding.UTF8);
      except
        // Ordner schreibgeschuetzt: gilt bis zum Schliessen
      end;
  finally
    L.Free;
  end;
end;

procedure TGranularEditor.LoadFavorites;
var
  L: TStringList;
begin
  FRecent := nil;
  if (FBaseDir <> '') and FileExists(FBaseDir + RECENT_FILE) then
  begin
    L := TStringList.Create;
    try
      try
        L.LoadFromFile(FBaseDir + RECENT_FILE, TEncoding.UTF8);
        FRecent := L.ToStringArray;
      except
      end;
    finally
      L.Free;
    end;
  end;
  FFavorites := nil;
  if (FBaseDir = '') or not FileExists(FBaseDir + 'Favoriten.txt') then
    Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FBaseDir + 'Favoriten.txt', TEncoding.UTF8);
      FFavorites := L.ToStringArray;
    except
    end;
  finally
    L.Free;
  end;
end;

procedure TGranularEditor.SaveFavorites;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.AddStrings(FFavorites);
    try
      L.SaveToFile(FBaseDir + 'Favoriten.txt', TEncoding.UTF8);
    except
      // Ordner schreibgeschuetzt: Favoriten gelten bis zum Schliessen
    end;
  finally
    L.Free;
  end;
end;

procedure TGranularEditor.UpdateFavButton;
var
  I: Integer;
begin
  if FPresetFav = nil then
    Exit;
  I := FPresetCombo.ItemIndex;
  FPresetFav.Enabled := (I > 0) and (I <= High(FPresetFiles));
  if FPresetFav.Enabled and IsFavorite(FPresetFiles[I]) then
  begin
    FPresetFav.Caption := '★';
    FPresetFav.Icon := eiStarFull;
  end
  else
  begin
    FPresetFav.Caption := '☆';
    FPresetFav.Icon := eiStar;
  end;
end;

procedure TGranularEditor.PresetFavClick(Sender: TObject);
var
  I, K: Integer;
  F: string;
begin
  I := FPresetCombo.ItemIndex;
  if (I <= 0) or (I > High(FPresetFiles)) then
    Exit;
  F := ExtractFileName(FPresetFiles[I]);
  if IsFavorite(F) then
  begin
    for K := High(FFavorites) downto 0 do
      if SameText(FFavorites[K], F) then
        Delete(FFavorites, K, 1);
  end
  else
    FFavorites := FFavorites + [F];
  SaveFavorites;
  ApplyPresetFilter;
  FPages.SetFocus;
end;

procedure TGranularEditor.PresetCatChange(Sender: TObject);
begin
  ApplyPresetFilter;
  FPages.SetFocus;          // PC-Tastatur spielt wieder
end;

procedure TGranularEditor.PresetFilterChange(Sender: TObject);
begin
  ApplyPresetFilter;
end;

procedure TGranularEditor.PresetFilterKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_ESCAPE:
      begin
        FPresetFilter.Text := '';
        Key := 0;
      end;
    VK_RETURN:
      begin
        FPresetCombo.SetFocus;
        FPresetCombo.DroppedDown := True;
        Key := 0;
      end;
  end;
end;

procedure TGranularEditor.LoadPreset(const FileName: string);
var
  Path, Resolved: string;
  Master: Double;
begin
  ReleaseAllKeys;
  PushUndo;
  Master := FEngine.GetParam(Ord(gpMaster));        // Master gehoert dem Nutzer, nicht dem Preset
  if not LoadChunkFromFile(FEngine, FileName, Path, FBaseDir) then
    raise Exception.Create(Tr('Keine gültige Preset-Datei: ') + FileName);
  FEngine.SetParamById(gpMaster, Master);
  FEngine.PresetName := ChangeFileExt(ExtractFileName(FileName), '');
  FBanner.Flash;   // Lichtimpuls durchs Banner
  Resolved := ResolveSamplePath(Path, FBaseDir);
  if Path = EMPTY_SAMPLE_REF then
  begin
    if not IsEmptySample(FEngine.Sample) then
      SetSample(CreateEmptySample(44100));      // Init-Preset: bewusst ohne Sample
  end
  else if (Resolved <> '') and not SameText(Resolved, FEngine.SamplePath) then
    LoadFile(Resolved)
  else if (Path <> '') and (Resolved = '') then
    MessageDlg(Tr('Das Sample des Presets wurde nicht gefunden:') + sLineBreak + Path, mtWarning, [mbOK], 0);
  LoadMorphSample(FEngine, FBaseDir);   // Sample des Morph-Ziels B (Grain-Ueberblendung)
  LoadZoneSamples(FEngine, FBaseDir);
  UpdateFromEngine;
  AddRecent(FileName);
end;

procedure TGranularEditor.PresetComboChange(Sender: TObject);
var
  I: Integer;
begin
  I := FPresetCombo.ItemIndex;
  if (I <= 0) or (I > High(FPresetFiles)) then
    Exit;
  try
    LoadPreset(FPresetFiles[I]);
  except
    on E: Exception do
      MessageDlg(E.Message, mtError, [mbOK], 0);
  end;
  UpdateFavButton;
  FPages.SetFocus;   // Fokus weg von der Liste -> PC-Tastatur spielt wieder
end;

procedure TGranularEditor.PresetStepClick(Sender: TObject);
var
  I, N: Integer;
begin
  N := FPresetCombo.Items.Count - 1;   // Eintrag 0 = "- Preset waehlen -"
  if N <= 0 then
    Exit;
  I := FPresetCombo.ItemIndex;
  if Sender = FPresetNext then
  begin
    Inc(I);
    if I > N then I := 1;               // am Ende wieder von vorn
  end
  else
  begin
    Dec(I);
    if I < 1 then I := N;
  end;
  FPresetCombo.ItemIndex := I;
  PresetComboChange(FPresetCombo);
end;

{ Speichern-Option 'Samples einbetten' merken (Datei im Plugin-Ordner) }
const
  EMBED_OPT_FILE = 'PresetSpeichern.txt';

{ Arp-Muster als MIDI: Ziehen = Drag&Drop in die DAW, Klick = Speichern-Dialog }
procedure TGranularEditor.ArpMidiMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Bars: Integer;
  Fn: string;
  Dlg: TSaveDialog;
begin
  if Button <> mbLeft then
    Exit;
  Bars := ARP_MIDI_BARS[EnsureRange(FArpMidiBars.ItemIndex, 0, High(ARP_MIDI_BARS))];
  if DragDetect(TWinControl(Sender).Handle, Mouse.CursorPos) then
  begin
    // eindeutiger Name: manche DAWs verweisen auf die Datei statt sie zu kopieren
    Fn := TPath.Combine(TPath.GetTempPath, 'GranularSynth Arp ' + FormatDateTime('hhnnss', Now) + '.mid');
    if WriteArpMidi(FEngine, Bars, Fn) then
    begin
      // waehrend des eigenen Ziehens keine Dateien annehmen: Ablegen auf dem Plugin = 'nicht erlaubt'
      DragAcceptFiles(Handle, False);
      try
        DragFileOut(Fn);
      finally
        DragAcceptFiles(Handle, True);
      end;
    end;
    Exit;
  end;
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.Filter := Tr('MIDI-Datei (*.mid)|*.mid');
    Dlg.DefaultExt := 'mid';
    Dlg.FileName := 'GranularSynth Arp.mid';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if Dlg.Execute and not WriteArpMidi(FEngine, Bars, Dlg.FileName) then
      MessageDlg(Tr('Die MIDI-Datei konnte nicht geschrieben werden.'), mtError, [mbOK], 0);
  finally
    Dlg.Free;
  end;
end;

procedure TGranularEditor.PresetSaveClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Embed: Boolean;
  I: Integer;
begin
  Dlg := TSaveDialog.Create(nil);
  try
    // zwei Dateitypen = die Option: ohne Samples (klein, wie bisher) oder mit eingebetteten Samples
    // (eine Datei mit allem, z.B. zum Weitergeben an einen anderen Rechner)
    Dlg.Filter := Tr('Granular-Preset (*.gspreset)|*.gspreset|' +
      'Granular-Preset mit eingebetteten Samples (*.gspreset)|*.gspreset');
    Dlg.FilterIndex := 1;
    try
      if (FBaseDir <> '') and FileExists(FBaseDir + EMBED_OPT_FILE) and
         (Trim(TFile.ReadAllText(FBaseDir + EMBED_OPT_FILE)) = 'Samples einbetten=1') then
        Dlg.FilterIndex := 2;
    except
    end;
    Dlg.DefaultExt := 'gspreset';
    if DirectoryExists(FBaseDir + 'Presets') then
      Dlg.InitialDir := FBaseDir + 'Presets';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if Dlg.Execute then
    try
      // eigene Samples nach "Eigene Toene" kopieren: Preset bleibt mit dem Plugin-Ordner portabel
      if FEngine.MorphValid and (ResolveSamplePath(FEngine.MorphSampleRef, FBaseDir) <> '') then
        FEngine.MorphSampleRef := MakeSharedSamplePath(
          ResolveSamplePath(FEngine.MorphSampleRef, FBaseDir), FBaseDir);
      for var Z := 1 to ZONE_COUNT do
        if FEngine.GetZoneLoaded(Z) <> '' then
          FEngine.SetZoneRef(Z, MakeSharedSamplePath(FEngine.GetZoneLoaded(Z), FBaseDir));
      for var W := 0 to OSC_COUNT - 1 do
        if FEngine.WtLoaded[W] <> '' then
          FEngine.WtRef[W] := MakeSharedSamplePath(FEngine.WtLoaded[W], FBaseDir);
      Embed := Dlg.FilterIndex = 2;
      try
        TFile.WriteAllText(FBaseDir + EMBED_OPT_FILE, 'Samples einbetten=' + IntToStr(Ord(Embed)));
      except
        // Ordner schreibgeschuetzt: Wahl gilt nur fuer dieses Mal
      end;
      // Name des Presets = Dateiname (Anzeige im Banner, Programmname in der DAW)
      FEngine.PresetName := ChangeFileExt(ExtractFileName(Dlg.FileName), '');
      SaveChunkToFile(FEngine, SampleRefFor(FEngine.Sample, MakeSharedSamplePath(FEngine.SamplePath, FBaseDir)),
        Dlg.FileName, FBaseDir, Embed);
      RefreshPresets;
      // das gespeicherte Preset in der Liste zeigen (Filter/Kategorie, die es verstecken, zuruecksetzen)
      I := IndexOfPresetFile(Dlg.FileName);
      if (I < 0) and ((FPresetFilter.Text <> '') or (FPresetCat.ItemIndex > 0)) then
      begin
        FUpdating := True;
        try
          FPresetFilter.Text := '';
          FPresetCat.ItemIndex := 0;
        finally
          FUpdating := False;
        end;
        ApplyPresetFilter;
        I := IndexOfPresetFile(Dlg.FileName);
      end;
      if I > 0 then
      begin
        FUpdating := True;
        try
          FPresetCombo.ItemIndex := I;
        finally
          FUpdating := False;
        end;
        UpdateFavButton;
      end;
    except
      on E: Exception do
        MessageDlg(Tr('Preset konnte nicht gespeichert werden:') + sLineBreak + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TGranularEditor.ShowExternalNote(Note: Integer; IsOn: Boolean);
begin
  FKeys.SetPressed(Note, IsOn);
end;

procedure TGranularEditor.ShowPage(Index: Integer);
begin
  if (Index >= 0) and (Index < FPages.PageCount) then
    FPages.ActivePageIndex := Index;
  FPages.InvalidateTabs;
end;

procedure TGranularEditor.ShowModulationPage;
begin
  FPages.ActivePage := FTabMod;
  FPages.InvalidateTabs;
end;

procedure TGranularEditor.ReleaseAllKeys;
var
  I: Integer;
begin
  for I := 0 to High(FKeyNote) do
    if FKeyNote[I] >= 0 then
    begin
      PlayNote(FKeyNote[I], False);
      FKeyNote[I] := -1;
    end;
end;

end.
