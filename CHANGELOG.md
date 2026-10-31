# GranularSynth – Änderungen

Alle nennenswerten Änderungen, die neueste Version oben.
Jede Version nennt **Neu** (hinzugekommen), **Geändert** und **Behoben**.
Unter **Hinweis** steht, was sich für vorhandene Presets, Projekte oder die Installation ändert.

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
