# GranularSynth – Leitfaden für Entwickler und KI-Assistenten

Diese Datei erklärt Aufbau, Werkzeuge und die festen Regeln des Projekts.
Sie richtet sich an Menschen und an KI-Assistenten (Claude Code, Copilot, Cursor …). `AGENTS.md` verweist hierher.
Oberfläche, Kommentare und Dokumentation sind **auf Deutsch**. Bitte dabei bleiben.

## Überblick

**Ziel und Prioritäten:** professioneller Klang auf dem Niveau kommerzieller Digital-Synthesizer. Bei Zielkonflikten gilt: 1. Klangqualität, 2. möglichst niedrige Systemlast, 3. eine gute, einfach bedienbare Oberfläche (ebenfalls sehr wichtig).

- **Plugin:** eine DLL für **VST2 und VST3**. Sie enthält Instrument und FX-Variante und wird zusätzlich als `GranularSynth.vst3` ausgeliefert.
- **Plattformen:** Win32 und Win64.
- **Sprache:** Delphi 12 (RAD Studio 23.0). Als Fremdbibliothek wird nur [Graphics32](https://github.com/graphics32/graphics32) für die Grafik gebraucht. Ihr Ordner steht in der Umgebungsvariablen `GR32_DIR`, lokal gesetzt in `build.local.bat`. Diese Datei gehört nicht ins Projektarchiv.
- **Kein Steinberg-SDK:** Die VST2- und VST3-Schnittstellen sind von Hand deklariert, in `Source/Vst/Granular.Vst2.pas` und `Granular.Vst3.pas`.
- **GranularHost.exe:** Test-Host für VST2 und VST3, Prüfstand (`-bench`), Preset-Erzeugung (`-makepresets`) und Hörproben (`-renderdemos`).

## Verzeichnisse

| Pfad | Inhalt |
|---|---|
| `Source/Engine` | Klangerzeugung ohne VCL. `Granular.Engine.pas` (TGranularEngine), `Params` (alle Parameter), `State` (Chunk/Preset-Format), `DSP` (SSE-Kerne + Pascal-Referenz), `Reverb`, `Eq`, `Pitch` (YIN), `Sample`, `AudioDecode`, `SampleEdit` (Schnitt-Funktionen des Sample-Editors) |
| `Source/UI` | Oberfläche. `Granular.Editor.pas` (TGranularEditor, alle Reiter), Anzeigen (WaveView, ModViews, Spectrum, EqView, FreeLfoView, LoadView, InfoView), `Banner`, `Fader` (Knopf-/Regler-Look), `IconButton` (Symbole), `AudioEditor` (Fenster „Audio bearbeiten“), `WasapiRec` (Aufnahme inkl. Loopback), `ArpMidi` (Arp als MIDI ziehen), `Hints` (erzeugt) |
| `Source/Vst` | Plugin-Hüllen: `VstPlugin` (VST2), `Vst3Plugin` (VST3), Schnittstellen `Vst2`/`Vst3` |
| `Source/Host` | Test-Host: `MainForm`, `VstHost` (VST2) + `Vst3Host` (VST3), Audio-Ein/-Ausgang, `AutoPlay`, `Bench` (Prüfstand), `PresetGen` (alle mitgelieferten Presets), `DemoRender` |
| `Presets/` | mitgelieferte Presets, **erzeugt** von `PresetGen` (`GranularHost.exe -makepresets <Projektordner>`) |
| `Beispieltoene/` | Beispiel-Samples, größtenteils synthetisch erzeugt von `Tools/make_*.py` |
| `Hilfe/Hilfe.rtf` | Hilfe. Kapitel 11 (Reglertabelle) wird von `Tools/Hilfe_Reglertabelle.py` erzeugt |
| `Tools/` | `bump_version.py`, `Hilfe_Reglertabelle.py`, `make_hints.py`, `Install.ps1` + `Setup/` (Installer) |

## Bauen und prüfen

```bat
build.bat Release Win32 Alle
build.bat Release Win64 Alle
bin\Win32\GranularHost.exe -bench
bin\Win64\GranularHost.exe -bench
```

- `build.bat` heißt mit vollem Pfad aufrufen, wenn es aus einem anderen Ordner gestartet wird.
- In `bin\<Plattform>\bench.txt` dürfen weder `FEHLER` noch `ABWEICHUNG` stehen. Die Zeile `Klang-Regression: … -> OK` muss erscheinen.
- **Laufzeit:** Die Klang-Regression rendert auf allen Kernen (`TParallel.For`, je Preset eine Engine), verglichen wird danach der Reihe nach. Worker-Threads setzen FPU/MXCSR auf den Delphi-Standard und starten COM – sonst weichen unter Win32 die Bits ab bzw. Media Foundation lädt nichts. Zeitmessungen (Volllast, Wavetable, Oversampling, SSE/Pascal) laufen danach allein auf einem Kern und dürfen nie parallel laufen. Die Dauer je Check steht in `bin\<Plattform>\bench_zeiten.txt`. Globale, beim ersten Gebrauch angelegte Tabellen vor dem Parallel-Teil anlegen (z. B. eine Engine erzeugen und freigeben).
- **Klang-Regression:** Alle Presets werden gerendert und Bit für Bit mit `Demos/regress_ref.txt` verglichen. Wer die Datei löscht, legt die Referenz neu an. Das ist nur erlaubt, wenn eine Klangänderung **gewollt** ist.
- Neue Funktionen bekommen eine eigene `Check…`-Funktion in `Source/Host/Granular.Bench.pas`, die mit „-> OK“ oder „-> FEHLER“ endet.
- **Auslieferung:**
  1. `python Tools/bump_version.py` (Nebenversion +1)
  2. beide Plattformen bauen und den Prüfstand laufen lassen
  3. `deploy.bat` aufrufen. Es legt alles nach `Deploy\`, inklusive `Setup.exe`, `CHANGELOG.md` und `LICENSE.txt`.

## Feste Regeln (Kompatibilität)

Diese Regeln schützen DAW-Projekte und Presets der Nutzer. Verstöße fallen sonst erst beim Nutzer auf.

1. **VST-Parameter:** Die Nummer eines Parameters in der DAW ergibt sich aus `VST_ORDER`, den Matrix-Zeilen und `VST_ADDED` (`Granular.Params.pas`).
   - Neue Parameter kommen **nur hinten an `VST_ADDED`**. `VST_ADDED_COUNT` wird entsprechend erhöht.
   - Parameter werden **nie gelöscht**. Ein nicht mehr gebrauchter Parameter bleibt als Platzhalter stehen, zum Beispiel `'(frei)'`.
   - Der Prüfstand kontrolliert das mit der Zeile „VST-Nummern“.
2. **Enum `TGranularParamId`:** Neue Einträge kommen vor `gpPerformance`. `gpTempo` bleibt der letzte. Die Reihenfolge darf sich ändern, weil Presets die Parameter über ihren **Namen** speichern. Deshalb dürfen Namen nicht umbenannt werden.
3. **Modulationsquellen `TModSource`:** neue Quellen **nur ans Ende**, mit passendem Eintrag in `MOD_SOURCE_NAMES`. Presets speichern die Quelle als Klartext.
4. **Presets nie umnummerieren oder umbenennen.** Neue Presets bekommen neue Nummern, Lern-Presets heißen `Lxx`.
5. **Zufallszahlen:** LFOs und Grains teilen sich einen Zufallsgenerator. Ein zusätzlicher `Rand`-Aufruf verändert den Klang **aller** Presets, und die Regression schlägt fehl. Neue Zufallsquellen nur dort einbauen, wo sie den bestehenden Ablauf nicht berühren.
6. **Chunk-/Preset-Format (`Granular.State.pas`):** neue Daten nur als **optionale Abschnitte am Ende** mit eigener Kennung (4 Zeichen). Ältere Versionen müssen neue Dateien weiter laden können, neue Versionen alte Dateien.

## Sprachen der Oberfläche (Deutsch, Englisch, weitere)

Die Oberfläche ist mehrsprachig. Der **deutsche Text ist zugleich der Schlüssel** der Übersetzung, ähnlich wie bei gettext.

- **Laufzeit:** `Source/UI/Granular.Lang.pas`.
  - `Tr('Deutscher Text')` liefert die Übersetzung.
  - `TranslateComponents` übersetzt nach dem Aufbau alle Beschriftungen, Hinweise und Menüs.
  - Listen übersetzt `AddParam` über `Tr(StepName(...))`.
- **Sprachdateien:** `Sprachen/<Kürzel>.txt`.
  - Format: erste Zeile `#Name=English`, danach je Zeile `Deutsch<TAB>Übersetzung`, ein Zeilenumbruch im Text steht als `\n`.
  - **Eine neue Sprache ist nur eine neue Datei.** Sie erscheint automatisch in der Auswahl „Sprache / Language“ im Reiter Extras.
  - Die kleine Flagge am rechten Ende der Reiterzeile schaltet per Klick zur nächsten Sprache. Eigene Flagge: `Sprachen/<Kürzel>.png`. Eingebaut sind Deutsch und Englisch, sonst erscheint das Kürzel.
- **Gemerkte Wahl:** `Sprache.txt` im Plugin-Ordner. Fehlt sie, gilt Deutsch auf deutschem Windows, sonst Englisch.
- **Umschalten:** Der Editor meldet `OnLanguageChange`. Die Plugin-Hülle baut den Editor per Fensternachricht neu auf.

**Neue Texte (Pflicht):**
1. Jeder sichtbare Text, der zur Laufzeit gesetzt wird, läuft durch `Tr(...)`, zum Beispiel Caption, Hint, Items.Add, MessageDlg und den ersten Parameter von `Format`. Das gilt für ganze Sätze: also `Tr('Teil 1 ' + 'Teil 2')`, nicht `Tr('Teil 1 ') + Tr('Teil 2')`.
2. Ein Text, der beim Aufbau direkt an einem Steuerelement steht, wird automatisch übersetzt.
3. Nie durch `Tr` laufen dürfen Dateinamen, Ordnernamen (`Presets`, `Beispieltoene`, `Eigene Toene`), Ini-Schlüssel, VST-Klassennamen und Parameternamen, die in Presets gespeichert werden.

**Automatische Prüfung:**
- Der Prüfstand meldet „Uebersetzung: … en: N fehlen -> FEHLER“ und schreibt die Liste nach `bin\<Plattform>\lang_fehlend_<Kürzel>.txt`.
- `python Tools/lang_check.py` prüft zusätzlich alle `Tr`-Literale im Quelltext, die Tooltips und die Reglertabelle der Hilfe. Fehlende Texte stehen danach in `Sprachen/_fehlend_<Kürzel>.txt`. Sie werden übersetzt und in `Sprachen/<Kürzel>.txt` eingetragen.
- `deploy.bat` bricht ab, solange etwas fehlt.
- **Textplatz:** Der Prüfstand baut die Oberfläche in jeder Sprache auf und misst jeden Text gegen sein Steuerelement: Knöpfe, Beschriftungen mit fester Breite oder mit Nachbarn daneben und geschlossene Listen. Zu lange Texte meldet er als FEHLER und schreibt sie nach `bin\<Plattform>	ext_platz_<Sprache>.txt`. Abhilfe ist eine kürzere Übersetzung oder ein breiteres Steuerelement.

**Übersetzte Dokumente:**

| Deutsch | Übersetzung |
|---|---|
| `Hilfe/Hilfe.rtf` | `Hilfe/Hilfe_<kürzel>.rtf` |
| `LIESMICH.txt` | `README_<KÜRZEL>.txt` |
| `Eigene Toene/LIESMICH.txt` | `Eigene Toene/README_<KÜRZEL>.txt` |
| `Presets/LERNPFAD.txt` | `Presets/LEARNING_PATH_<KÜRZEL>.txt` |

- `lang_check.py` merkt sich in `Sprachen/_stand_<kürzel>.txt` einen Fingerabdruck der deutschen Vorlage. Ändert sich die Vorlage, meldet es die Übersetzung als **veraltet**.
- Nach dem Nachziehen der Übersetzung `python Tools/lang_check.py --stand` ausführen.
- Kapitel 11 der fremdsprachigen Hilfe (Reglertabelle) erzeugt `Tools/Hilfe_Reglertabelle.py` automatisch über das Wörterbuch.

## Regeln für Echtzeit und Leistung

- **Audio-Thread** (`Process`, `Render…`, `Update…`): keine Speicheranforderungen, keine String-Operationen, keine wartenden Sperren, keine Ausnahmen.
- **Heiße Schleifen:**
  - laufen als SSE-Assembler (Win32) bzw. x64-Assembler.
  - Daneben bleibt immer eine **Pascal-Referenz** erhalten.
  - Der Prüfstand vergleicht beide und misst die Zeit.
- **Ein Kern:** Das Audio wird auf einem Kern gerechnet. Ein Versuch mit einem zusätzlichen Thread war auf schwachen Laptops langsamer.
- **Nur was gebraucht wird:** Teure Bausteine rechnen nur, wenn sie benutzt werden. Beispiele sind LFO 5–8 und die Tonhöhe von Sidechain 2 (siehe `UpdateLfoUsed`).
- **Oberfläche:** schlicht und mit dem Touchpad bedienbar, geringe CPU-Last.

## Konventionen

- **Dateien:** Quelltexte sind **UTF-8 mit BOM**. Delphi liest Dateien ohne BOM als ANSI, dann gehen die Umlaute kaputt.
- **Kommentare:** auf Deutsch. In Quelltexten werden Umlaute in Kommentaren meist umschrieben (ae, oe, ue), in Oberflächentexten echt geschrieben.
- **Lizenzkopf:** Jede Quelldatei beginnt mit dem GPL-Kopf (siehe vorhandene Dateien).
- **Neuer Regler, was alles dazugehört:**
  1. Enum `TGranularParamId`
  2. Zeile in `PARAM_INFO`
  3. Eintrag in `VST_ADDED`
  4. bei Stufen-Reglern: `StepName`
  5. Wirkung in der Engine
  6. Bedienelement im Editor (`AddParam`)
  7. Hilfe-Zeile in `Tools/Hilfe_Reglertabelle.py`
  8. danach `python Tools/Hilfe_Reglertabelle.py` und `python Tools/make_hints.py` ausführen
  9. Prüfstand-Check
  10. Übersetzungen ergänzen: `python Tools/lang_check.py`, dann die fehlenden Texte in `Sprachen/*.txt` eintragen
  11. Eintrag in `CHANGELOG.md`
- **Dokumentation mitziehen:** Bei sichtbaren Änderungen auch die Hilfe (`Hilfe/Hilfe.rtf` bzw. die Reglertabelle), `LIESMICH.txt`, `README.md` und die Bildschirmfotos in `docs/screenshots/` anpassen. Die englischen Fassungen meldet `lang_check.py` dann als veraltet.
- **Changelog:** Jede für Nutzer sichtbare Änderung kommt in `CHANGELOG.md` unter die kommende Version: *Neu*, *Geändert*, *Behoben*, *Entfernt* oder *Hinweis* (Folgen für Presets und Projekte).
- **Projekteinschätzung:** `docs/Projekteinschaetzung.md` ist eine Einschätzung des Projekts von außen. Hin und wieder (etwa bei größeren Versionen, nicht bei jedem Deploy) prüfen, ob sie noch stimmt, und den Stand oben in der Datei anpassen.
- **Symbole auf Knöpfen:** Die Plugin-Oberfläche zeichnet Symbole als Vektoren, ohne Bilddateien. Ein neuer Knopf bekommt ein Symbol, wenn es eindeutig erkennbar ist (Laden, Speichern, Löschen, Abspielen, Aufnahme …). Wo der Text mehr sagt, bleibt es beim Text.
  - Die Symbole stehen in `Source/UI/Granular.IconButton.pas`: Aufzählung `TEdIcon`, Zeichnung in `DrawIcon` (Koordinaten 0..1 im Quadrat). Ein neues Symbol kommt hinten an `TEdIcon` und bekommt einen Zweig in `DrawIcon`.
  - Ein normaler `TButton` der Oberfläche (aus `Granular.Fader`) zeigt das Symbol über `B.Icon := eiOpen;` links neben dem Text. Nur mit Symbol: zusätzlich `B.IconOnly := True` – die Beschriftung bleibt für Tooltip und Barrierefreiheit gesetzt, und ein `Hint` ist dann Pflicht.
  - Passt das Symbol nicht neben den Text (etwa in einer längeren Übersetzung), wird es kleiner gezeichnet und notfalls weggelassen. Der Text wird nie abgeschnitten. Wer das Symbol sicher sehen will, macht den Knopf breit genug.
  - Eigene Fenster ohne Owner-Draw-Knöpfe (z. B. „Audio bearbeiten“) nehmen `TIconButton` aus derselben Unit.
  - **Kein GDI+** in der Plugin-DLL: Es startet beim Laden der DLL (Loader-Lock) und kann die DAW hängen lassen. Geglättet wird mit Graphics32 (`GR32_Polygons`).
  - Farben: Grundfarbe hellgrau, Akzente sparsam – grün = abspielen/übernehmen, rot = Aufnahme/Löschen/Notaus, bernstein = gewählt/aktiv.
- **Testumgebung:** Umgebungsvariablen `GRANULAR_TAB` (Reiter beim Start), `GRANULAR_LFOPAGE`, `GRANULAR_MATPAGE` und `GRANULAR_AUDIOEDIT=1` (öffnet den Sample-Editor für das Hauptsample, für Bildschirmfotos), `GRANULAR_PRESET=<Datei>` und `GRANULAR_PARAMS='Name=Wert;…'` (nach dem Öffnen ein Preset laden bzw. einzelne Regler per Name aus `PARAM_INFO` setzen, Stufen als Index – z. B. `EQ an=1;Cutoff=1800`; für Bildschirmfotos mit aussagekräftigen Anzeigen: ein kräftiges Key-Preset nehmen und die nötigen Bausteine zuschalten).

## Bekannte Eigenheiten

- In Delphi kann `Format('%+d')` nicht verwendet werden. Für Vorzeichen gibt es den eigenen Helfer `SignedPct`.
- Hat ein Delphi-Set mehr als 256 mögliche Werte (`PARAM_COUNT` > 256), wird `IdIn()` statt `in [...]` verwendet.
- `PSingle` gibt es in `System` und in `Winapi.Windows`. In Units, die beides einbinden, wird `System.PSingle` geschrieben.
- `TThread.Queue`/`ForceQueue` laufen in der Plugin-DLL nicht zuverlässig: Die RTL der DLL arbeitet ihre Warteschlange im Host nicht ab. Für „später im GUI-Thread“ einen kurzen `TTimer` nehmen.
- Strukturgrößen der VST3-Schnittstellen sind im Prüfstand festgeschrieben, zum Beispiel ParameterInfo 792 Byte und ProcessData 80/48 Byte. Felder dort nicht verschieben.
