﻿# GranularSynth – Änderungen

Alle nennenswerten Änderungen, die neueste Version oben.
Jede Version nennt **Neu** (hinzugekommen), **Geändert** und **Behoben**.
Unter **Hinweis** steht, was sich für vorhandene Presets, Projekte oder die Installation ändert.

---

## Version 2.18 – 05.11.2026

### Neu
- **Preset 181 FM - Keys - Arp-Keys und Keys (zwei Klänge):** gezupfte FM-Keys und dieselben Keys als Arp (hoch + runter), per Morph gemischt, mit Röhren-Sättigung, kräftigem Kompressor, Bass mono und doppelter Breite.

- **Sample-Editor: Speichern unter…** – das bearbeitete Audio lässt sich direkt als **WAV** (verlustfrei) oder **MP3** (320 kbit/s, feste hohe Qualität) speichern; das Format wählst du im Speicherdialog. So lässt sich z. B. der eigene Ausgang aufnehmen („Was der PC abspielt“), zuschneiden und als Hörprobe verschicken, ohne das Sample im Preset zu ersetzen. MP3 schreibt Windows (Media Foundation); andere Abtastraten als 32/44,1/48 kHz werden dafür auf 44,1 kHz umgerechnet.

### Geändert
- **„Hauptsample bearbeiten…“ heißt jetzt „Sample-Editor…“**, ebenso der Fenstertitel.
- **Kompressor-Kennlinie wie bei einem klassischen Kompressor:** Unter der Schwelle bleibt der Pegel 1:1, an der Schwelle knickt die Kurve sichtbar auf das eingestellte Verhältnis ab. Der **Knick** rundet diese Ecke jetzt gleichmäßig nach beiden Seiten ab, statt sie zu verschieben. Leise Anteile hebt der Kompressor erst 24 dB unter der Schwelle an (OTT-Stil, weich begrenzt).

### Behoben
- **Sample-Editor:** Alles markieren (Strg+A) und *Löschen*/Entf tat nichts. Jetzt wird das Fenster geleert (z. B. für eine neue Aufnahme); *Rückgängig* holt das Audio zurück.

### Hinweis
- Presets mit eingeschaltetem Kompressor (L41) klingen dadurch etwas anders: Spitzen werden stärker gebremst, ganz leise Anteile weniger angehoben.

---

## Version 2.17 – 05.11.2026

### Neu
- **Gleiten je Stufe** (Fenster *Freier LFO*, Stufen-Modi): Unter den Stufen liegt eine Leiste *Gleiten*. Ein Klick lässt die Stufe weich vom vorigen Ton herübergleiten – wie Slide an einem Step-Sequencer, ideal für Acid- und Basslinien. Andere Stufen springen weiter hart; die *Glättung* gilt wie bisher für alle.
- **Sättigung: Art** (Reiter *Summe*, Bereich Sättigung): neben *Warm* (wie bisher) jetzt **Röhre** (asymmetrisch, gerade Obertöne, voller), **Hart** (harter Clip, aggressiv) und **Faltung** (Wavefolder – kräftiger Drive faltet die Welle zurück, metallisch und obertonreich). Mit Oversampling ohne Spiegelfrequenzen.
- **Kompressor** der Summe (nach dem EQ, vor dem Limiter): drei Bänder wie bei einem Multiband-Kompressor im OTT-Stil – leise Anteile werden angehoben, laute Spitzen gebremst. Eigene Spalte im Reiter *Summe* mit *Menge*, *Tempo*, **Verhältnis** (1:1 bis 20:1), **Schwelle** und **Knick** (harter oder weicher Einsatz) sowie einer **Kennlinie**, die die Kurve live zeigt. Macht Bässe und Leads dichter und druckvoller.
- **Bass mono** (Reiter *Summe*): legt alles unter einer einstellbaren Frequenz (Standard 120 Hz, 24 dB/Oktave) in die Mitte – der Bass bleibt im Club und auf Mono-Anlagen druckvoll, Breite und Raum darüber bleiben.
- **Modulations-Hüllkurven 1 und 2** (Reiter *Timing / Hüllk.* (bisher *Timing / Events*), unten mit Grafik wie bei den Oszillatoren): zwei freie ADSR-Hüllkurven je Note, nur zum Modulieren – in der Matrix als Quelle *Mod-Hüllk. 1/2* auf jedes Ziel.
- **Wavetables laden** (Reiter *Osz 1–3*, Bereich *Wavetable*): WAV-Dateien im Serum-/Vital-Format (2048 Punkte je Frame) oder einzelne Zyklen; bis zu 32 Frames, jeder bandbegrenzt. *Position* fährt stufenlos durch die Frames und ist je Note modulierbar. Ist eine Wavetable aktiv, sind *Welle* und *Gezeichnet* ausgegraut (bei aktiver Zeichnung *Welle*). Drei Beispiel-Wavetables liegen in *Beispieltoene* (`WT_…`).
- **Sub-Oszillator und Rauschen** an Oszillator 1 (Reiter *Osz 1*): Sinus oder Rechteck eine bzw. zwei Oktaven tiefer, dazu weißes Rauschen – folgen Tonhöhe, Hüllkurve und Filter von Osz 1.
- **Reihenfolge der Effekte** (Reiter *Effekte*, unten): Gate, Crusher, Chorus und Phaser in jeder der 24 Reihenfolgen, automatisierbar.
- **Preset-Kategorien** *Techno*, *FM / Synth*, *Grains* und **Zuletzt benutzt** (die letzten 20 geladenen Presets, gemerkt in *Zuletzt.txt*).
- **Osz folgen Pitch** (Reiter *Osz*, neben *Oktave*): die Oszillatoren folgen dem Regler *Pitch* samt Modulation – so spielt der Step-Sequencer (freier LFO → Pitch) auch reine Oszillator-Klänge. *Auf Pitch legen* schaltet ihn mit ein.
- **Lern-Presets L38–L46** für alle neuen Funktionen (Lernpfad Teil 6).

### Hinweis
- Presets ohne gleitende Stufen bleiben Byte für Byte gleich; ältere Versionen laden neue Presets, nur ohne das Gleiten.
- Wavetables werden wie Samples als Datei-Verweis im Preset gespeichert (beim Speichern nach *Eigene Toene* kopiert, wenn sie außerhalb des Plugin-Ordners liegen).
- Neue Automations-Parameter hinten angefügt (Sättigung Art, Kompressor an/Menge/Tempo/Verhältnis/Schwelle/Knick, Bass mono, Mod-Hüllkurven, Wavetable an/Position je Oszillator, Sub, Rauschen, Effekt-Reihenfolge); vorhandene Nummern bleiben. Alle Presets klingen unverändert (Kompressor aus, Art *Warm*).

---

## Version 2.16 – 04.11.2026

### Geändert
- **Variieren mit Maß** (Reiter *Schnell*): Gewürfelt wird nur noch, was im Preset auch klingt – ausgeschaltete Teile (Grains, Filter, Echo, Hall, Sättigung) bleiben unberührt. Neu ist der Bereich **Oszillatoren**: bei eingeschalteten Oszillatoren variieren FM-Menge, Pegel, Sync, Hüllkurven und Filter; die Welle bleibt, das FM-Verhältnis springt nur auf musikalische Werte (½, 1, 1½, 2, 3 …). So lassen sich auch reine FM-Presets sinnvoll abwandeln.
- **Variieren in** statt *Gesperrt*: Die Schalter unter *Variieren* zeigen jetzt, was gewürfelt wird (an = wird verändert). Anfangs sind alle an – das Würfeln selbst verhält sich wie bisher.

### Behoben
- **Audio bearbeiten:** *Abspielen* und *Aufnehmen* reagierten nicht auf Mausklicks (der Klick wurde doppelt ausgelöst und startete und stoppte sofort wieder); Zoom-Knöpfe sprangen zwei Stufen.

---

## Version 2.15 – 04.11.2026

### Neu
- **Tonleiter-Tasten** (Reiter *Extras*, Harmonie, neue Zeile *Tasten*): *weiße Tasten = Tonleiter* – die weißen Tasten ab C4 spielen der Reihe nach die Töne der gewählten Tonleiter (C4 = Grundton), die schwarzen schweigen. So lässt sich jede Tonleiter allein auf den weißen Tasten spielen. Neuer, automatisierbarer Parameter *Tonleiter-Tasten* (hinten angehängt).
- **Fenstergröße wählbar** (Reiter *Extras*, unter der Sprache): 100, 125, 150, 175 oder 200 % für große und hochauflösende Bildschirme. Schriften, Knöpfe, Symbole, Regler und Anzeigen wachsen mit; die DAW bekommt die neue Fenstergröße gemeldet (VST2 und VST3). Die Wahl gilt für alle Instanzen und wird im Plugin-Ordner gemerkt (`Fenstergroesse.txt`). Auch die Zusatzfenster wachsen mit: Audio bearbeiten, Frei zeichnen, Welle zeichnen, Info und Hilfe.
- **Sechs FM-Techno-Presets mit Drive (175–180):** Rumble-Bass, Reese-Bass (wandert im Takt), Industrial-Stab (Anschlag = härter), verzerrter Acid (Anschlag = Akzent), Peitschen-Lead (Modrad = Drive) und Pump-Pad mit Trance-Gate für den Breakdown. Gemacht für gespielte elektronische Musik; das Oversampling hält die harten FM-Obertöne mit Sättigung sauber.

### Geändert
- **Panorama-Regler** (Grain, Osz 1–3, Summe, Mischpult) zeigen die Position wie an einem Mischpult: *L 30*, *C* (Mitte), *R 30* statt −30 % … +30 %. In der DAW steht keine Einheit mehr dahinter. Presets und Automation bleiben unverändert.

### Behoben
- **Arp als MIDI:** Das gezogene MIDI-Muster ließ sich auf das Plugin-Fenster selbst fallen lassen und führte zur Meldung „Datei konnte nicht geladen werden“. Während des Ziehens nimmt das Fenster jetzt keine Dateien an; MIDI-Dateien aus dem Explorer werden still ignoriert.
- **Tonleiter wirkt jetzt auch auf die Oszillatoren.** Bisher rasteten nur die Grains ein; ein Oszillator spielte den Ton der Taste, auch wenn er nicht zur Tonleiter gehörte. Jetzt spielen Grains und Oszillatoren denselben Ton; Pitchbend und Glide bleiben stufenlos.

### Hinweis
- Presets mit eingestellter Tonleiter und Oszillatoren klingen dadurch anders (tonleiterrichtig).

---

## Version 2.14 – 03.11.2026

### Neu
- **Arp-Muster als MIDI in die DAW ziehen** (Reiter *Extras*): Das Feld *MIDI hier greifen und ziehen* unter dem Schrittmuster mit der Maus in eine Spur der DAW ziehen. Die Datei enthält genau die Noten, die der Arp mit dem zuletzt gespielten Akkord und den aktuellen Einstellungen spielt: Richtung, Oktaven, Notenwert, Länge, Swing, Schrittmuster und Tempo. Die Länge ist wählbar (1, 2, 4 oder 8 Takte). Ein Klick ohne Ziehen speichert die Datei. Wurde noch kein Akkord gespielt, nimmt der Arp C-Dur.
  - Damit lässt sich ein Arp-Lauf in der DAW weiter bearbeiten oder mit einem anderen Instrument spielen. Zum Abspielen durch GranularSynth den Arp dort ausschalten, sonst arpeggiert er die Noten noch einmal.

- **Audio bearbeiten** (Reiter *Samples*): Mit *Hauptsample bearbeiten...* und *Bearbeiten...* in jeder Zone öffnet sich ein kleiner Schnittplatz für das Sample hinter den Grains. Funktionen: Zuschneiden, Löschen, Einblenden, Ausblenden, Normalisieren (−0,2 dB), Stille entfernen, Umkehren und Rückgängig (10 Schritte). Schnitte rasten auf den nächsten Nulldurchgang ein, beim Löschen wird die Naht kurz überblendet – kein Knacken. Bedienung: ziehen = markieren, Mausrad = Zoom, Entf, Strg+Z, Strg+A.
  - **Vorhören:** *Abspielen* (Leertaste) spielt die Markierung bzw. ab dem Cursor über das Windows-Standardgerät – unabhängig vom Audio-Thread des Plugins.
  - **Aufnahme im Fenster:** von jedem Aufnahmegerät oder **„Was der PC abspielt“** (Mitschnitt des Lautsprecher-Ausgangs, WASAPI-Loopback – kein Stereomix nötig), mit Pegelanzeige, höchstens 60 s. So lässt sich z. B. ein Webradio oder ein anderes Programm als Grain-Quelle aufnehmen.
  - Symbol-Knöpfe (Play, Aufnahme, Lupen) und Zeitleiste in Sekunden.
  - *Übernehmen* speichert das Ergebnis als neue WAV in *Eigene Toene* (z. B. `Floete_C5_bearbeitet_01.wav`) und lädt es; die Originaldatei bleibt unverändert. Die Auto-Stimmung erkennt den Grundton neu.

### Geändert
- **Symbole auf den Knöpfen** der ganzen Oberfläche (geglättet gezeichnet, keine Bilddateien): Audio laden, Alle Noten aus (Stoppschild), Preset vor/zurück, Favorit-Stern (gefüllt = Favorit), Speichern (Diskette), Info, Hilfe, Variieren (Würfel), Rückgängig/Wiederholen, Morph-Knöpfe, Laden/Leeren/Bearbeiten der Zonen, Aufnahme (roter Punkt), Zeichnen. Passt ein Symbol nicht neben den Text (z. B. in einer längeren Übersetzung), bleibt nur der Text stehen.
- Kopfleiste leicht umverteilt (Platz für die Symbole); *MIDI hier greifen und ziehen* ist jetzt ein Knopf mit Klaviatur-Symbol.
- Reiter *Samples*: Der rechte Bereich heißt jetzt *Sample bearbeiten und Aufnahme vom Eingang*; der Knopf *Hauptsample bearbeiten...* steht vorn.

### Behoben
- Feedback-Resampling, das per DAW-Automation bei geschlossenem Plugin-Fenster eingeschaltet wurde, blieb wirkungslos, wenn das Preset es vorher nicht nutzte. Die Puffer werden jetzt in einem Hilfs-Thread angelegt, sobald Resampling eingeschaltet wird; der Audio-Thread fordert dabei keinen Speicher an.

---

## Version 2.13 – 02.11.2026

### Neu
- **Feedback-Resampling** (Reiter *Samples*): Solange eine Taste gehalten wird, wird das Gespielte – mit Effekten und Hall – nach jedem Durchlauf zur neuen Grain-Quelle. Der Klang entwickelt sich, je länger man hält; jeder neue Anschlag beginnt wieder beim Original.
  - *Anteil neu*: 100 % ersetzt jedes Mal ganz, wenig mischt behutsam bei.
  - *Durchlauf*: Länge frei (0,25–8 s) oder *Im Takt* (1/4 bis 2 Takte zum Host-Tempo).
  - Die Tonhöhe bleibt stehen (die gespielte Taste wird verrechnet), Pegel und Bass werden ausgeglichen, die Schleife ist nahtlos überblendet. Grains lesen bis zu ihrem Ende aus dem Stand, mit dem sie begonnen haben – kein Störgeräusch beim Wechsel.
  - Gemessen: Tonhöhe nach über 20 Durchläufen auf 0,1 Halbton genau, Pegel innerhalb ±0,6 dB.
- **Hörproben-Presets 170–174:** Klavier zerfließt, Chor wird Nebel, Glocken mit Echo, Deep-House-Stab wird Teppich, Stimme verdampft.

### Geändert
- Die Aufnahme vom Sidechain-Eingang heißt jetzt *Aufnahme vom Eingang*.

### Hinweis
- Am schönsten mit gehaltenen Einzeltönen; Akkorde schichten sich mit jedem Durchlauf zu Clustern.

---

## Version 2.12 – 02.11.2026

### Behoben
- **Test-Host: leere Presetliste:** Der Host merkte sich das zuletzt benutzte Plugin auch aus einem anderen Ordner (z. B. einem Build-Ordner ohne Presets). Jetzt hat das mitgelieferte GranularSynth neben der EXE Vorrang.

---

## Version 2.11 – 02.11.2026

### Behoben
- **Reiter *Leistung*:** Texte überlappen nicht mehr; die Laufzeit-Zeile bricht sauber um. Der Schalter heißt jetzt verständlicher *Klassische Oszillatoren (bis 2.9)* (aus = Wavetable, Standard).

---

## Version 2.10 – 02.11.2026

### Neu
- **Gezeichnete Oszillator-Wellen:** Jeder der drei Oszillatoren kann eine selbst gezeichnete Welle spielen (Haken *Gezeichnet* neben *Welle*, Knopf *Zeichnen ...*). Im Zeichenfenster: eine Periode mit der Maus zeichnen, Grundformen als Ausgangspunkt (Sinus, Dreieck, Säge, Rechteck, Puls 25 %, Zufall, Umkehren) und *Glättung* 0–100 % (rundet die Obertöne ab, 100 % = fast Sinus). Blau ist die Zeichnung, gelb der Klang, wie er gespielt wird.
- **Profi-Qualität:** Die Zeichnung wird in eine bandbegrenzte Wavetable mit 14 Stufen (je halbe Oktave) umgerechnet. Der Oszillator spielt immer nur die Obertöne, die bei der Tonhöhe unter die halbe Abtastrate passen – gemessen: −84 dB Spiegelanteil bei einer gezeichneten Säge in hoher Lage (die eingebaute Säge liegt bei −42 dB). Sync, Unison, Hüllkurve, eigener Filter und Oversampling wirken wie bei den anderen Wellen.

### Geändert
- **Weniger Rechenlast bei HQ:** Oversampling läuft nur noch, wenn ein Oszillator Spiegelfrequenzen erzeugen kann (Dreieck, Säge, Rechteck, FM oder Sync). Klänge nur mit Sinus- oder gezeichneten Oszillatoren (beide schon bandbegrenzt) sparen damit die doppelte Rechenzeit der Oszillatoren, ohne Klangverlust. Die Entscheidung gilt für alle Oszillatoren gemeinsam (sie bleiben phasengleich) und wechselt nie mitten im Ton.

- **Eingebaute Wellen als Wavetable (Standard):** Dreieck, Säge und Rechteck kommen jetzt ebenfalls aus bandbegrenzten Tabellen – 61 Stufen im Abstand einer Sechstel-Oktave, stufenlos überblendet. Gemessen: Spiegelanteil Säge in hoher Lage −84 dB statt −42 dB, Rechteck −85 statt −47 dB; im Bass klingen alle Obertöne bis 17 kHz voll (die klassische Säge dämpft sie leicht); beim Pitch-Bend über 4 Oktaven ändern sich die Höhen so gleichmäßig wie bisher. Diese Wellen brauchen kein Oversampling mehr – mit HQ dadurch sogar etwas weniger Rechenzeit als vorher.
- **Schalter *Oszillatoren: Wavetable / Klassisch*** im Reiter *Leistung*: *Klassisch* ist bitgenau der Oszillator bis Version 2.9 (für Projekte, die exakt wie früher klingen sollen). Gehört zum Rechner, nicht zum Preset.
- Die Zeichenfläche hat jetzt 1024 Punkte (bis 511 Obertöne) statt 256.

### Hinweis
- Presets und Projekte mit Dreieck, Säge oder Rechteck klingen mit dem neuen Standard etwas sauberer in den Höhen; Pegel und Grundcharakter bleiben gleich. Wer den alten Klang exakt braucht: *Leistung › Oszillatoren: Klassisch*.
- Die Zeichnung wird mit dem Preset gespeichert. Ältere Versionen laden solche Presets, spielen dort aber die unter *Welle* gewählte Form.

### Behoben
- **Test-Host: Suchfeld der Presetliste:** Buchstaben im Feld „Filter“ (z. B. „FM“) wurden vom Host als Noten der PC-Klaviatur abgefangen und kamen nicht an. Der Host erkennt Eingabefelder im Plugin-Fenster jetzt zuverlässig.

---

## Version 2.9 – 01.11.2026

### Neu
- **Klaviatur am freien LFO:** Im Fenster der freien Form (Modus *Halbtöne*) zeigt links eine Klaviatur, welche Note jede Stufe spielt. Jedes C trägt seine Oktave, die gespielte Taste ist orange hervorgehoben. Die Stufen tragen den Notennamen (z. B. „G +7“). Mit *Bezugston* stellst du ein, welche Taste du spielst – so lassen sich Melodien direkt nach Noten setzen.
- **Glättung am freien LFO (0–100 %):** 0 % = harte Stufen (jeder Ton steht), wenig = kurzes Gleiten von Ton zu Ton, 100 % = runde Kurve durch alle Werte. Die gelbe Linie zeigt den echten Verlauf. Gilt für die Stufen-Modi und wird mit dem Preset gespeichert.

### Geändert
- **README:** Bildschirmfotos aller Reiter (mit laufendem Klang) und des freien LFOs.
- Der bisherige Knopf *Glätten* (verändert die Werte selbst) heißt jetzt *Werte mitteln*.

### Hinweis
- Presets ohne Glättung klingen unverändert. Ältere Versionen laden neue Presets weiter, nur ohne Glättung.

---

## Version 2.8 – 01.11.2026

### Neu
- **Oversampling (2x) bei HQ:** Oszillatoren und Sättigung rechnen intern mit doppelter Abtastrate und werden danach mit einem steilen Halbband-Filter (71 Taps, −98 dB Sperrdämpfung) zurückgerechnet. Harte FM-, Sync- und Drive-Klänge bleiben dadurch sauber, ohne metallische Spiegelfrequenzen. Gemessen bei hohen Tönen: FM von +16 dB auf −70 dB Spiegelanteil, harter Drive von −18 dB auf −55 dB, Sägezahn um 19 dB sauberer. Standardmäßig an; abschaltbar im Reiter *Leistung* („Oversampling 2x (bei HQ)“). Die Einstellung gehört zum Rechner, nicht zum Preset.

### Geändert
- **Reiter neu geordnet, nach dem Weg des Signals:** Schnell · Grain · Samples · Osz 1-3 · **Filter** · Modulation · LFO · Timing · Effekte · **Echo / Hall** · **Summe** · Extras · Mischpult · Leistung.
  - **Filter:** Filter 1 und Filter 2 mit Verschaltung zusammen auf einem Reiter (beide wirken je Note).
  - **Echo / Hall:** ohne Filter, nur noch die beiden Raum-Effekte.
  - **Summe** (vorher „Filter 2 / EQ“): alles, was auf den Gesamtklang wirkt – Sättigung, EQ, Stereobreite, Panorama, Limiter, HQ und Master.
  - **Extras:** nur noch Spielhilfen (Arpeggiator, Harmonie, Freeze, Morph, Schwellen-Tor).
  - Presets, Automation und VST-Nummern bleiben unverändert.
- **Projektziel festgehalten:** GranularSynth strebt professionellen Klang auf dem Niveau kommerzieller Digital-Synthesizer an. Reihenfolge bei Zielkonflikten: Klangqualität, dann niedrige Rechenlast, dann einfache Bedienung.

### Behoben
- **Grauer Strich auf dem Bildschirm:** Windows ließ manchmal den Schatten eines Tooltips stehen, wenn das Plugin-Fenster geschlossen wurde, während ein Tooltip gerade ein- oder ausgeblendet wurde. Die Tooltips haben jetzt keinen Schlagschatten mehr (passt zum flachen Stil), dadurch kann nichts mehr hängen bleiben.

### Hinweis
- Mit HQ und Oversampling klingen Presets mit FM, Sync, hellen Oszillatoren oder viel Sättigung sauberer als vorher; der Grundcharakter bleibt. Wer den alten Klang genau braucht, schaltet Oversampling im Reiter *Leistung* ab (dann bitgleich wie 2.7).
- Rechenzeit: Oszillatoren brauchen mit Oversampling etwa doppelt so viel; Grains sind nicht betroffen. Bei typischen Klängen steigt die Gesamtlast nur wenig.

---

## Version 2.7 – 31.10.2026

### Neu
- **Update-Hinweis im Plugin:** Das Plugin fragt höchstens einmal am Tag bei GitHub nach, ob es eine neuere Version gibt. Wenn ja, erscheint ein kleiner bernsteinfarbener Pfeil am Ende der Reiterzeile, links neben der Sprachflagge. Der Tooltip nennt die neue Version, ein Klick startet das Setup mit dem *Online-Update* (oder öffnet die Download-Seite, wenn das Setup nicht installiert ist).

### Hinweis
- Die Abfrage läuft im Hintergrund und berührt den Klang nicht. Gesendet wird nur die übliche Web-Anfrage an GitHub, keine Daten über dich oder deine Projekte. Ohne Internet erscheint einfach kein Hinweis.

---

## Version 2.6 – 31.10.2026

### Neu
- **Changelog im Hilfefenster:** Oben im Hilfefenster schalten zwei Knöpfe zwischen *Hilfe* und *Änderungen (Changelog)* um. So ist aus dem Plugin heraus sichtbar, was sich in welcher Version geändert hat.
- **Online-Update im Setup:** Das Setup prüft beim Start, ob es auf GitHub eine neuere Version gibt. Mit *Online-Update* lädt es sie herunter, prüft die Prüfsumme und installiert sie mit derselben Auswahl wie bisher, für jede installierte Plattform. Das funktioniert auch über *Windows-Einstellungen › Apps › GranularSynth › Ändern*.

### Hinweis
- Das Online-Update setzt eine Installation mit dem Setup ab Version 2.2 voraus (Eintrag in der Programmliste). Ältere Installationen einmal normal mit dem neuen Setup überinstallieren.

---

## Version 2.5 – 31.10.2026

### Behoben
- Abgeschnittene Beschriftungen in beiden Sprachen: Listen Neustart/Stopp im Reiter LFO, Faktor-Liste der Matrix, Morph-LFO, Kurve der freien Makros, Preset-Kategorie, Unison-Verstimmung, Zonen und Anlauf.
- Die Statuszeile endet bei Platzmangel mit „…“. Der volle Text steht im Tooltip.

### Geändert
- **Neuer, flacher dunkler Stil** für Knöpfe, Auswahllisten, Eingabefelder und Reiter: feine Ränder, Bernstein als Akzent (gewählter Reiter, gewählte Seite, Listenpfeil), passend zu den Schiebereglern und Kippschaltern.
- Die Matrix-Zeilen haben ein **Papierkorb-Symbol** statt „×“.
- Die Pegelanzeigen für Sidechain und Ausgang (Reiter LFO) sind jetzt **Segmentanzeigen** (grün, bernstein, rot) mit dem Wert rechts.
- Der Prüfstand misst jetzt jeden Text gegen den Platz seines Steuerelements, in jeder Sprache. Zu lange Beschriftungen fallen so vor der Auslieferung auf.

---

## Version 2.4 – 31.10.2026

### Neu
- **Sprachflagge** klein am rechten Ende der Reiterzeile: Sie zeigt die aktuelle Sprache. Ein Klick schaltet zur nächsten Sprache der Liste. Eine neue Sprache kann ihre Flagge als *Sprachen/<Kürzel>.png* mitbringen.

---

## Version 2.3 – 31.10.2026

### Neu
- **Englische Oberfläche:** Im Reiter *Extras* gibt es die Auswahl *Sprache / Language* (Deutsch oder English). Die Oberfläche baut sich sofort in der neuen Sprache auf, die Wahl wird gemerkt.
  - Weitere Sprachen kommen als Datei in den Ordner *Sprachen* hinzu und erscheinen automatisch in der Auswahl.
  - Ohne gespeicherte Wahl startet das Plugin auf deutschem Windows deutsch, sonst englisch.
- **Englische Dokumente:** Hilfe (*Hilfe_en.rtf*), *README_EN.txt*, *Eigene Toene/README_EN.txt* und der Lernpfad (*Presets/LEARNING_PATH_EN.txt*). Die Hilfe öffnet sich in der gewählten Sprache.

### Entfernt
- 19 Presets wurden aussortiert: 02, 03, 23, 35, 40, 46, 48, 55, 65, 66, 95, 101, 107, 109, 112, 113, 117, 133 und 158. Die übrigen Presets behalten ihre Nummern, die freien Nummern werden nicht neu vergeben.

### Hinweis
- Presets, ihre Namen und die Parameternamen in der DAW bleiben deutsch. Presets sind in beiden Sprachen dieselben.
- GranularHost übernimmt eine im Plugin umgestellte Sprache erst beim nächsten Start.
- Wer die aussortierten Presets schon installiert hat, behält sie beim Aktualisieren. Sie lassen sich im Ordner *Presets* von Hand löschen.

---

## Version 2.2 – 31.10.2026

### Neu
- **Freie Makros:** Im Reiter *Modulation* gibt es rechts neben der Matrix vier Regler *Makro 1–4*.
  - Jedes Makro kann beliebig viele Regler bewegen. Zuweisen: Rechtsklick auf einen Regler › *Modulieren mit* › *Makro n*.
  - Jedes Makro hat eine eigene Kurve: *Linear*, *Langsam ansteigend*, *Schnell ansteigend* oder *S-Kurve*.
  - Unter jedem Makro stehen seine Ziele.
  - Die Makros lassen sich in der DAW automatisieren: Eine Automationsspur bewegt dann viele Regler.
- **Presets mit eingebetteten Samples:** Im Speichern-Dialog gibt es den Dateityp *„mit eingebetteten Samples“*.
  - Dann stecken Hauptsample, Klang B und Zonen-Samples mit in der Preset-Datei. So wird eine Datei weitergegeben, die alles enthält.
  - Auf einem anderen Rechner werden fehlende Samples beim Laden nach *Eigene Töne* ausgepackt.
  - Die gewählte Speicherart wird gemerkt.
- **Lern-Presets L35–L37** zu den freien Makros.
- **Setup mit Deinstallation und Update:**
  - GranularSynth erscheint in den Windows-Einstellungen unter *Apps* als „GranularSynth (64 Bit)“ bzw. „(32 Bit)“ und lässt sich dort entfernen.
  - Beim Entfernen fragt das Setup, ob eigene Presets und Töne bleiben sollen. Entfernt werden dann nur die mitgelieferten Dateien.
  - Ein neues Setup schlägt dieselbe Auswahl und dieselben Ordner vor wie beim letzten Mal („Aktualisieren“).
  - Wird beim Aktualisieren etwas abgewählt oder ein anderer Ordner gewählt, fragt das Setup, ob die alte Installation entfernt werden soll.
- **GranularHost lädt auch VST3-Plugins** (*VST laden…* › Dateityp *.vst3*). Der Test-Host kann damit die VST3-Variante von GranularSynth oder andere VST3-Plugins einzeln testen, inklusive Fenster, Noten, MIDI-Controllern und Zustand.
- **Lizenz:** GranularSynth ist freie Software unter der GNU GPL Version 3 oder neuer, Copyright © 2026 Matthias Haberecht. Der Lizenztext liegt als *LICENSE.txt* bei.

### Behoben
- Das Setup schlug für 64 Bit den falschen VST3-Ordner vor (*Program Files (x86)*), weil es die 32-Bit-PowerShell startete.
- Nach dem Speichern steht das neue Preset mit seinem Namen in der Presetliste. Bisher wurde die Liste nicht aktualisiert.

### Hinweis
- Ältere Versionen können Presets mit eingebetteten Samples laden. Sie packen die Samples aber nicht aus.
- Vorhandene Presets klingen unverändert.
- Installationen mit einem älteren Setup stehen nicht in der Programmliste. Einmal mit dem neuen Setup über die alte Installation installieren, danach lässt sie sich entfernen.

---

## Version 2.1 – 28.10.2026

### Neu
- Sidechain 2 liefert seine Tonhöhe als Matrix-Quelle **„SC2-Tonhöhe“**. Sie wird nur berechnet, wenn eine Matrix-Zeile sie nutzt.

---

## Version 2.0 – 28.10.2026

### Neu
- **VST3-Plugin** (Instrument und FX) zusätzlich zu VST2. Das Banner zeigt das Format: VST2, VST2 FX, VST3 oder VST3 FX.
- Reglerbewegungen werden an die DAW gemeldet, damit sie aufgezeichnet werden können. Dazu gibt es den Menüpunkt *Automation in der DAW*.
- **Setup.exe:** Installationsprogramm mit Auswahl von 32/64 Bit, VST2, VST3, Test-Host und Zielordnern.

### Hinweis
- In der DAW muss einmal neu nach Plugins gesucht werden, damit die VST3-Variante erscheint.

---

## Version 1.20 – 28.10.2026

### Geändert
- Die Matrix zeigt Zeilennummern. Die gewählte Matrix-Seite und der gewählte LFO-Umschalter sind farbig markiert.

## Version 1.19 – 28.10.2026

### Neu
- Die Modulationsmatrix hat **32 Zeilen** auf vier Seiten.
- Es gibt **acht LFOs** mit einem Umschalter 1–4 / 5–8. LFO 5–8 kosten nur dann Rechenzeit, wenn sie benutzt werden.

### Geändert
- *Modulieren mit* nimmt immer die erste freie Matrix-Zeile.

---

## Version 1.18 – 24.10.2026

### Neu
- Das Mischpult hat zusätzliche Kanäle für Gate, Crusher, Chorus und Phaser.

### Entfernt
- Shimmer im Hall.

### Hinweis
- Presets, die Shimmer benutzt haben, klingen ohne den Shimmer-Anteil.

## Version 1.17 – 24.10.2026

### Geändert
- Das Modulationsmenü zeigt Mengen und Zeilen. Jede Matrix-Zeile hat einen Papierkorb.

## Version 1.16 – 24.10.2026

### Neu
- Tooltips zu allen Reglern.
- Der Reiter *Leistung* hat eine Zeile *FX*.

### Geändert
- Phaser und Chorus brauchen deutlich weniger Rechenzeit.

## Version 1.15 – 24.10.2026

### Geändert
- Die gelbe Linie markiert den Startpunkt. Wird sie vor die Auswahl gezogen, entsteht ein Anlauf.

## Version 1.13 / 1.14 – 24.10.2026

### Neu
- Anlauf vor der Auswahl und Schleife hin und her.
- An jedem Regler zeigt eine Modulationsspur pro Matrix-Zeile, wie stark er moduliert wird.

### Behoben
- Grafikfehler in der Modulationsanzeige.

## Version 1.12 – 24.10.2026

### Neu
- Modulationsanzeige, MIDI-Learn, Rückgängig/Wiederholen, Preset-Kategorien und Favoriten.
- Drag & Drop, Aufnahme, Zonen, Unison, neue Filterarten, Effekte, Trance-Gate und Rendern in Höchstqualität.
- Bass- und Höhenschnitt für den Hall.

## Version 1.11 – 24.10.2026

### Geändert
- Hilfe aktualisiert. Die Lern-Presets haben jetzt einen einheitlichen Pegel.
