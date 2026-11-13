"""Erzeugt Kapitel 11 der Hilfe (Hilfe/Hilfe.rtf): Tabelle aller Regler je Reiter mit Erklaerung,
ob automatisierbar/Matrix-Ziel und den VST-Parameternamen.

Aufruf (aus beliebigem Ordner):   python Tools/Hilfe_Reglertabelle.py
Das Skript ersetzt nur Kapitel 11; die Kapitel davor stehen direkt in Hilfe.rtf und werden von Hand
gepflegt. Nach neuen/umbenannten Reglern hier TABS (Text) und PNAMES (VST-Namen) anpassen.
Fremdsprachen: fuer jede Sprachdatei Sprachen/<Kuerzel>.txt mit passender Hilfe/Hilfe_<Kuerzel>.rtf wird
Kapitel 11 dort ebenfalls erzeugt - alle Texte ueber das Woerterbuch der Sprachdatei. Fehlende Texte meldet
das Skript; Tools/lang_check.py fuehrt sie als fehlende Uebersetzungen.
"""
import os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))   # Projektordner

def esc(t):
    out = []
    for ch in t:
        o = ord(ch)
        if o < 128:
            out.append(ch)
        else:
            try:
                out.append("\\'%02x" % ch.encode('cp1252')[0])
            except UnicodeEncodeError:   # Pfeile, ×, ≤ ...: RTF-Unicode
                out.append("\\u%d?" % (o if o < 32768 else o - 65536))
    return ''.join(out)

TABS = [
("Kopfleiste", [
 ("Audio laden…", "beliebige Audiodatei (WAV, MP3, FLAC …) als Rohmaterial der Grains laden."),
 ("Alle Noten aus", "beendet sofort alle klingenden Noten (Notbremse)."),
 ("Okt - / Okt +", "verschiebt die PC-Tastatur und die Klaviatur um eine Oktave; dazwischen steht die aktuelle Oktave."),
 ("Preset w\u00e4hlen, < >", "Preset aus der Liste laden bzw. bl\u00e4ttern."),
 ("Speichern…", "aktuelle Einstellung als Preset speichern; eigene T\u00f6ne werden nach \u201eEigene Töne\u201c kopiert. Dateityp \u201emit eingebetteten Samples\u201c: alle benutzten Samples (Haupt-Sample, Klang B, Zonen) kommen mit in die Preset-Datei - eine Datei zum Weitergeben. Auf einem anderen Rechner werden fehlende Samples beim Laden nach \u201eEigene Töne\u201c ausgepackt. Die Wahl wird gemerkt; ältere Versionen laden solche Presets auch (ohne Auspacken). Nach dem Speichern steht der neue Name in der Presetliste."),
 ("CLIP / MIDI", "leuchten bei \u00dcbersteuerung bzw. bei jedem empfangenen MIDI-Ereignis."),
 ("Info", "Klartext, was beim Tastendruck passiert, dazu das Trigger-Protokoll (Noten, R\u00e4der, Ereignisse, Einmal-LFOs) live."),
 ("Erklärungen", "schaltet die Erklär-Displays in den Reitern ein oder aus (Standard). Aus: Maus über einen Bereich zeigt dessen Text leicht, ein Klick ins Display hält ihn fest."),
 ("Hilfe", "dieses Fenster."),
 ("Statuszeile", "das aktive Sample (bei Morph: A und B mit ihrem Anteil) und kurze Meldungen. Klingende Stimmen und aktive Grains stehen im Reiter Leistung."),
 ("Autoplay, Haken \u201ealle\u201c", "nur im Test-Host: spielt St\u00fccke ab; die Liste zeigt die zum Preset passenden, mit \u201ealle\u201c jedes St\u00fcck (z.B. eine Fl\u00e4che mit flotter Musik)."),
 ("Bend / Mod", "neben der Klaviatur: Tonh\u00f6he biegen (federt in 0,1 s zur\u00fcck) und Modrad (bleibt stehen)."),
]),
("Reiter Schnell", [
 ("Kategorie / Stern", "Kopfleiste: Presetliste nach Kategorie eingrenzen; Stern = aktuelles Preset als Favorit markieren."),
 ("Wiederholen", "stellt den zuletzt mit Rückgängig zurückgenommenen Schritt wieder her (Strg+Y)."),
 ("Makros", "Textur, Bewegung, Helligkeit, Raum, Streuung, H\u00fcllkurven-L\u00e4nge: jeder Regler ver\u00e4ndert mehrere Einstellungen auf einmal. 50 % = Preset unver\u00e4ndert; \u201eMakros auf 50 %\u201c setzt alle zur\u00fcck."),
 ("Variieren / St\u00e4rke / Variieren in", "w\u00fcrfelt eine Abwandlung des Klangs; die St\u00e4rke bestimmt wie weit. Unter \u201eVariieren in\u201c sind die Bereiche eingeschaltet, die ver\u00e4ndert werden; ausgeschaltete bleiben, wie sie sind. Gew\u00fcrfelt wird nur, was im Preset auch klingt (ausgeschaltete Teile bleiben, wie sie sind); bei den Oszillatoren bleibt die Welle, das FM-Verh\u00e4ltnis springt nur auf musikalische Werte. \u201eR\u00fcckg\u00e4ngig\u201c holt den vorigen Stand."),
 ("A/B", "zwischen zwei Fassungen hin- und herschalten und vergleichen."),
 ("HQ-Modus", "bessere Interpolation der Grains und - mit Oversampling (Reiter Leistung, Standard an) - saubere Oszillatoren und S\u00e4ttigung ohne Spiegelfrequenzen (etwas mehr Rechenlast)."),
 ("Limiter", "f\u00e4ngt Spitzen am Ausgang ab, damit nichts verzerrt."),
 ("Master", "Gesamtlautst\u00e4rke; bleibt beim Presetwechsel erhalten."),
 ("Spektrum", "zeigt live, welche Frequenzen wie laut klingen."),
]),
("Reiter Grain - Sample / Grains", [
 ("Grains an / Pegel", "Grains aus = nur die Oszillatoren klingen (klassischer Synthesizer); Pegel = Lautst\u00e4rke nur der Grains (die Lautst\u00e4rke im Klang-Bereich regelt die Summe aus Grains und Oszillatoren)."),
 ("Auswahl Start / Ende", "welcher Teil des Samples benutzt wird (auch in der Wellenansicht ziehbar)."),
 ("Position", "wo in der Auswahl die Grains gelesen werden."),
 ("Spray", "zuf\u00e4llige Streuung der Leseposition - macht den Klang lebendiger."),
 ("Scan", "wie schnell die Leseposition durch die Auswahl wandert (0 = steht, 1 = Originaltempo)."),
 ("Graingr\u00f6\u00dfe", "L\u00e4nge eines Grains: kurz = k\u00f6rnig, lang = glatt."),
 ("Dichte", "wie viele Grains pro Sekunde entstehen."),
]),
("Reiter Grain - Klang", [
 ("Pitch", "Grundtonh\u00f6he in Halbt\u00f6nen."),
 ("Oktave", "verschiebt die Grains um ganze Oktaven (-4 bis +4), zus\u00e4tzlich zu Pitch."),
 ("Pitch Zufall", "jedes Grain leicht verstimmt - Chor-/Schwebeeffekt."),
 ("Bend-Bereich", "wie weit Pitchbend die Tonh\u00f6he biegt (Halbt\u00f6ne)."),
 ("Stereobreite", "wie weit die Grains im Stereobild verteilt werden."),
 ("Grain-Panorama", "schiebt die Grains nach links oder rechts (die Streuung bleibt um die neue Mitte); der Oszillator hat sein eigenes Panorama."),
 ("R\u00fcckw\u00e4rts", "Anteil der Grains, die r\u00fcckw\u00e4rts abgespielt werden."),
 ("Lautst\u00e4rke", "Lautst\u00e4rke des Presets."),
 ("Fenster", "Form, mit der jedes Grain ein- und ausgeblendet wird (weich bis knackig)."),
 ("Key Tracking", "an = die Tonh\u00f6he folgt der Taste; aus = jede Taste spielt dieselbe Tonh\u00f6he (Fl\u00e4chen, Ger\u00e4usche)."),
 ("Auto-Stimmung", "erkennt beim Laden den Grundton eines Samples (z.B. \u201eC3 +31 Cent\u201c) und stimmt es so, dass die Taste C4 wirklich ein C spielt. Wirkt nur bei einem klaren Einzelton (Fl\u00f6te, Klavier-Ton, Cello …), nicht bei Akkorden, Sprache oder Ger\u00e4uschen; braucht Key Tracking. Kommt die Tonh\u00f6he per Auto-Pitch vom Sidechain, hat diese Vorrang."),
]),
("Reiter Grain - H\u00fcllkurve", [
 ("Attack / Decay / Sustain / Release", "wie jede Note einschwillt, auf den Haltepegel abf\u00e4llt, gehalten wird und nach dem Loslassen ausklingt. Die Grafik zeigt die Kurve, der rote Punkt die gerade gespielte Note."),
]),
("Reiter Grain - Anlauf / Schleife", [
 ("Anlauf / Anlauf-Start", "Note beginnt vor der Auswahl beim Anlauf-Start und läuft einmal in die Auswahl hinein."),
 ("Schleife hin und her", "Scan kehrt am Ende der Auswahl um statt an den Anfang zu springen."),
]),
("Reiter Samples", [
 ("Zonen 1-3", "weitere Samples je Tastenbereich (ab Starttaste); Laden, Leeren, Datei auf die Zeile ziehen."),
 ("Aufnahme", "nimmt den Sidechain-Eingang auf (bis 60 s) und l\u00e4dt ihn als Hauptsample (WAV in Eigene Toene)."),
 ("Feedback-Resampling: an / Anteil neu / Durchlauf / Im Takt", "solange eine Taste gehalten wird, wird das Gespielte (mit Effekten und Hall) nach jedem Durchlauf zur neuen Grain-Quelle - der Klang entwickelt sich, je l\u00e4nger man h\u00e4lt. Jeder neue Anschlag beginnt wieder beim Original. Durchlauf: L\u00e4nge frei (0,25-8 s) oder im Takt (1/4 bis 2 Takte). Anteil neu: 100 % ersetzt jedes Mal ganz, wenig mischt behutsam bei. Die Tonh\u00f6he bleibt stehen (die gespielte Taste wird verrechnet), Pegel und Bass werden ausgeglichen, die Schleife ist nahtlos \u00fcberblendet."),
]),
("Reiter Osz 1 / Osz 2 / Osz 3", [
 ("Oszillator an", "drei gleich aufgebaute Oszillatoren, jeder spielt jede Note mit - einzeln einschaltbar und schichtbar (z.B. zwei verstimmte S\u00e4gez\u00e4hne + Sub-Sinus)."),
 ("Welle", "Sinus, Dreieck, S\u00e4ge, Rechteck, FM (zwei Sinus), Rauschen."),
 ("Gezeichnet / Zeichnen …", "eigene Welle: Haken an = der Oszillator spielt statt \"Welle\" die gezeichnete Form. \"Zeichnen …\" \u00f6ffnet die Zeichenfl\u00e4che: eine Periode mit der Maus zeichnen (Rechtsklick = 0), Grundformen (Sinus, Dreieck, S\u00e4ge, Rechteck, Puls, Zufall, Umkehren) als Ausgangspunkt, Gl\u00e4ttung 0-100 % rundet die Obert\u00f6ne ab (100 % = fast Sinus). Gespielt wird bandbegrenzt - keine Spiegelfrequenzen, auch hoch oben; Sync, Unison, H\u00fcllkurve und Filter wirken wie gewohnt. Wird mit dem Preset gespeichert."),
 ("folgt Pitch", "Haken an = alle drei Oszillatoren folgen dem Grain-Regler Pitch samt seiner Modulation (z.B. freier LFO → Pitch als Step-Sequencer, Vibrato). Aus (Standard) = Pitch wirkt nur auf die Grains. \"Auf Pitch legen\" im Fenster der freien Form schaltet ihn mit ein."),
 ("Wavetable an / Laden … / Position", "eine Wavetable-Datei laden (WAV, z.B. aus Serum oder Vital: 2048 Punkte je Frame; auch ein einzelner Zyklus). Bis zu 32 Frames, jeder bandbegrenzt wie die eingebauten Wellen. Haken an = der Oszillator spielt die Wavetable statt \"Welle\" und Zeichnung. Position f\u00e4hrt stufenlos durch die Frames und ist je Note modulierbar (z.B. Mod-H\u00fcllkurve oder LFO → Position = wandernder Klang). Beispiele in Beispieltoene: WT_Saege_zu_Rechteck, WT_Formant_Vokale, WT_FM_Wachsend. Lern-Preset L44."),
 ("Sub / Sub-Lage / Rauschen (nur Osz 1)", "Sub = ein zus\u00e4tzlicher Ton eine oder zwei Oktaven unter Oszillator 1 (Sinus oder Rechteck), Rauschen = wei\u00dfes Rauschen dazu (Anschlag, Luft, Hats). Beide folgen Tonh\u00f6he, H\u00fcllkurve, Panorama und Filter von Oszillator 1; Pegel relativ zu dessen Pegel. Lern-Preset L45."),
 ("Sync (Obert\u00f6ne)", "Hard Sync: 0 = saubere Welle, h\u00f6her = immer mehr Obert\u00f6ne, schneidend (nicht bei Rauschen)."),
 ("Oktave / Feinstimmung / Pegel / Panorama", "Tonlage, Feinabstimmung in Cent, Lautst\u00e4rke (bis 200 %) und Position."),
 ("FM-Verh\u00e4ltnis / FM-Menge", "nur bei Welle FM: Frequenz des Modulators und St\u00e4rke - Glocken, E-Piano, Bass."),
 ("FM-Klangfarbe", "eigene H\u00fcllkurve f\u00fcr die FM-Menge (nicht die Lautst\u00e4rke): hell im Anschlag, dann weich."),
 ("Lautst\u00e4rke-H\u00fcllkurve", "ADSR des Oszillators, mit Grafik."),
 ("Eigener Filter", "Filter nur f\u00fcr diesen Oszillator, an Filter 1/2 vorbei (z.B. Rausch-Hats per Hochpass)."),
 ("Unison / Verstimmung / Breite", "2 bis 7 verstimmte Stimmen je Note, im Stereobild verteilt (fette Pads und Leads)."),
]),
("Reiter Filter", [
 ("Filter an, Typ", "Tiefpass, Bandpass, Hochpass, Ladder 24 dB (warm angezerrt, steil), Kamm (metallisch, Cutoff = Tonh\u00f6he), Formant (Vokale A-E-I-O-U \u00fcber den Cutoff)."),
 ("Cutoff / Resonanz", "Eckfrequenz und Betonung an der Eckfrequenz."),
 ("Kontur", "wie steil das Filter wirkt (sanft bis scharf)."),
 ("H\u00fcllkurve (Menge) + Filter-H\u00fcllkurve", "eigene ADSR, die mit jeder Note das Filter \u00f6ffnet und schlie\u00dft."),
 ("Filter 2", "zweites Filter mit denselben Reglern; in Reihe (nacheinander) oder parallel (gemischt)."),
]),
("Reiter Modulation", [
 ("Freie Makros", "rechts neben der Matrix: vier Regler Makro 1-4, jeder bewegt beliebig viele Ziele. Ziel zuweisen: Rechtsklick auf einen Regler > Modulieren mit > Makro n (oder eine Matrix-Zeile mit Quelle \"Makro n\"); Menge, Faktor und Offset je Ziel. Kurve je Makro: Linear, Langsam ansteigend, Schnell ansteigend, S-Kurve. Unter jedem Makro stehen seine Ziele. Ideal für die DAW-Automation: eine Spur bewegt viele Regler. Lern-Presets L35-L37."),
 ("Modulationsmatrix", "32 Zeilen auf vier Seiten (Knöpfe oben rechts, in Klammern: benutzte Zeilen; \"Modulieren mit\" im Rechtsklick-Menü nimmt immer die oberste freie Zeile). Jede Zeile: Quelle → Ziel mit Menge, Faktor und Offset. Die leuchtende Anzeige vorne pulsiert mit der Quelle. Noten-Quellen (Velocity, Note, Zufall je Note, Grain-, Filter- und Osz1-3-Hüllkurve - jede f\u00fcr sich -, LFOs mit Neustart bei Note an/aus) wirken je Note: jede Stimme hat ihre eigenen LFOs und eigenen Werte für Grain-Regler, Tonhöhe, Lautstärke, Oszillator, Filter, alle Huellkurven-Zeiten, Scan, Filter-Konturen und die LFO-Raten - eine neue Note verändert die klingenden nicht. Ziele, die es nur einmal gibt (Echo, Hall, EQ, Sättigung, Breite, Summen-Panorama, Morph, Arp, Tor), folgen der zuletzt angeschlagenen Note; die Zeile zeigt dann 'global: letzte Note'. Der Papierkorb am Zeilenende leert die Zeile (Strg+Z nimmt es zur\u00fcck)."),
 ("Glide / Zeit", "Portamento: T\u00f6ne gleiten ineinander (Aus / Immer / Nur legato), Zeit = Dauer des Gleitens."),
]),
("Reiter LFO 1-8 / Trigger", [
 ("LFO 1 bis 8: Rate, Form, Sync", "langsame Schwingung (Sinus, Dreieck, S\u00e4ge, Rechteck, Zufall, Frei); Sync = im Takt des Hosts. Klick auf die Grafik \u00f6ffnet die freie Form. Umschalter unten rechts: LFO 1-4 / LFO 5-8 (in Klammern: benutzte LFOs 5-8; unbenutzte kosten keine Rechenzeit)."),
 ("Freie Form: Klaviatur, Gl\u00e4ttung", "im Fenster der freien Form (Klick auf die LFO-Grafik): im Modus Halbt\u00f6ne zeigt links eine Klaviatur, welche Note jede Stufe spielt (Bezugston = die Taste, die du spielst; jedes C mit Oktave), die Stufen tragen den Notennamen. Gl\u00e4ttung 0-100 %: 0 % = harte Stufen (jeder Ton steht), wenig = kurzes Gleiten von Ton zu Ton, 100 % = runde Kurve; die helle Linie zeigt den echten Verlauf. Leiste \u201eGleiten\u201c unter den Stufen: Klick l\u00e4sst eine einzelne Stufe vom vorigen Ton her\u00fcbergleiten (wie Slide am Step-Sequencer), die anderen springen weiter hart. Wird mit dem Preset gespeichert."),
 ("Einmal", "der LFO l\u00e4uft nur einen Durchgang und bleibt dann stehen (Melodien, Effekt-Einsatz)."),
 ("Neustart", "frei, Note an, Note aus, an + aus, Ende Partner-LFO (Einmal), Sidechain-Trigger, SC-Ton > Schwelle, Schwellen-Tor \u00f6ffnet, Ruhe, Ausgang > Schwelle."),
 ("Partner", "welcher LFO mit seinem Einmal-Ende das Ereignis \"Ende Partner-LFO (Einmal)\" auslöst - für Start und Stopp. Vorgabe: 1 und 2 bzw. 3 und 4 gegenseitig; beliebige Ketten möglich (z.B. 1 → 2 → 3 → 4). Der Partner muss auf \"Einmal\" stehen. Nur aktiv, wenn Start oder Stopp dieses Ereignis nutzt."),
 ("Stopp", "Aus-Trigger: das Ereignis (Note an, Note aus, Ende Partner-LFO, Sidechain-Trigger, SC-Ton, Schwellen-Tor, Ruhe, Ausgang > Schwelle) hält den LFO an - keine Modulation, bis sein Start-Ereignis ihn wieder startet. \"nie\" = läuft weiter. Wirkt nur mit Start-Ereignis (nicht bei \"frei\"); mit Stopp wartet der LFO auch anfangs auf seinen ersten Start. Bei LFOs je Note hält \"Note aus\" nur die losgelassene Note an. Verzögerung wie beim Start (Reiter Timing / Hüllk.). \"nach Zeit\": der LFO hält nach einer festen Laufzeit ab seinem Start an - in ms oder als Notenwert (2/1, 1/1, 1/2, 1/4, 1/4T …; ein Notenwert gilt vor den ms)."),
 ("Ausgang > Schwelle", "Trigger auf den eigenen Ausgangspegel: \u00fcberschreitet er die Schwelle, startet ein LFO mit diesem Neustart. Ein so gestarteter LFO l\u00f6st sich nicht selbst erneut aus, solange er l\u00e4uft (keine R\u00fcckkopplung)."),
 ("Sidechain-Trigger: Pegel / Ton", "wann der Trigger ausl\u00f6st: Pegel \u00fcber der Schwelle und/oder Ton \u00fcber der Note; beide angehakt = beides n\u00f6tig."),
 ("Auto-Pitch", "die Tonh\u00f6he kommt vom Sidechain (gesungener Ton) statt von der Taste - stufenlos oder in Halbt\u00f6nen."),
]),
("Reiter Timing / Hüllk.", [
 ("Verz\u00f6gerung je Ereignis", "jedes Ereignis, das einen LFO neu startet (Note an, Note aus, Ende Partner-LFO, Sidechain-Trigger, SC-Ton, Schwellen-Tor, Ruhe, Ausgang > Schwelle), kann verz\u00f6gert wirken: frei in ms oder im Takt (2/1 bis 1/32, punktiert und triolisch; der Notenwert gewinnt). Note an bei LFOs je Note: bis dahin ruht der LFO dieser Note - z.B. Geige mit Vibrato erst nach einer halben Note (Preset 159)."),
 ("Modulations-H\u00fcllkurven 1 / 2", "zwei freie ADSR-H\u00fcllkurven je Note, nur zum Modulieren: in der Matrix als Quelle \"Mod-H\u00fcllk. 1\" bzw. \"2\" auf ein beliebiges Ziel legen (z.B. Cutoff, FM-Menge, WT-Position, Pitch). Sie laufen unabh\u00e4ngig von Lautst\u00e4rke- und Filter-H\u00fcllkurve. Lern-Preset L43."),
]),
("Reiter Effekte", [
 ("Reihenfolge der Effekte", "in welcher Reihenfolge Gate, Crusher, Chorus und Phaser das Signal bearbeiten (24 M\u00f6glichkeiten). Beispiele: Crusher vor Chorus = breiter Lo-Fi-Klang; Chorus vor Crusher = der Crusher zerhackt auch die Schwebung; Gate am Ende = auch die Effekte werden zerhackt. Lern-Preset L46."),
 ("Chorus: Tempo / Tiefe / R\u00fcckkopplung / Mix", "verschobene Kopien: breit und schwebend; viel R\u00fcckkopplung = Flanger."),
 ("Phaser: Tempo / Tiefe / R\u00fcckkopplung / Mix", "sechs Allp\u00e4sse, wandernde Kerben im Spektrum."),
 ("Bitcrusher: Bits / Abtastrate / Mix", "Lo-Fi: weniger Aufl\u00f6sung und Abtastrate."),
 ("Trance-Gate", "16 Schritte zum Anklicken, Notenwert, Schritte, Tiefe, Gl\u00e4ttung - zerhackt den Klang im Songtempo."),
]),
("Reiter Echo / Hall", [
 ("Echo: Zeit / Sync / R\u00fcckkopplung / D\u00e4mpfung / Mix", "Verz\u00f6gerung, Anzahl der Wiederholungen, Helligkeit und Anteil der Echos."),
 ("Echo Pitch", "jede Wiederholung wird um diese Halbt\u00f6ne verschoben - steigende oder fallende Treppen."),
 ("Ping-Pong", "Echos springen zwischen links und rechts."),
 ("Hall: Raum, Gr\u00f6\u00dfe, Nachhall, D\u00e4mpfung, Vorverz\u00f6gerung, Breite, Mix", "Raumklang von kleinem Zimmer bis Kathedrale; Raum = Wandmaterial (Holz, Beton …)."),
 ("Bass-Schnitt / H\u00f6hen-Schnitt", "filtern nur den Hallanteil (der trockene Klang bleibt): Bass-Schnitt gegen Dr\u00f6hnen, H\u00f6hen-Schnitt f\u00fcr einen dunklen Raum."),
 ("Eingang → Echo/Hall", "nur in der FX-Variante (im Mixer): schickt den Eingang der Spur zusätzlich durch Echo und Hall. Das trockene Signal bleibt unverändert, dazu kommt nur der Echo-/Hall-Anteil. Wird von Presets nicht verändert."),
]),
("Reiter Summe", [
 ("EQ an, B\u00e4sse, H\u00f6hen", "Klangregelung am Ende der Kette."),
 ("S\u00e4ttigung / Art", "\u00dcbersteuerung der Summe. Art: Warm (weich, wie bisher), R\u00f6hre (asymmetrisch, gerade Obert\u00f6ne, voller), Hart (harter Clip, aggressiv), Faltung (Wavefolder: lauter Drive faltet die Welle zur\u00fcck - metallisch, sehr obertonreich)."),
 ("Kompressor: an, Menge, Tempo, Verh\u00e4ltnis, Schwelle, Knick", "Drei-Band-Kompressor nach dem EQ (Kette der Summe: Echo/Hall → S\u00e4ttigung → EQ → Kompressor → Stereo → Limiter; Weichen bei 120 Hz und 2,5 kHz): leise Anteile werden angehoben, laute Spitzen gebremst - dichter, druckvoller Klang wie aus einem Multiband-Kompressor. Menge = wie stark insgesamt (auch wie viel leise Anteile angehoben werden), Tempo = wie schnell er reagiert (weniger = schneller, mehr Pumpen). Verh\u00e4ltnis = wie stark \u00fcber der Schwelle gebremst wird (4:1 = 4 dB mehr Eingang ergeben 1 dB mehr Ausgang), Schwelle = ab welchem Pegel, Knick = wie weich der Einsatz ist (0 dB = harter Knick, aggressiv; 12-24 dB = weich). Unter der Schwelle bleibt der Pegel 1:1; erst 24 dB darunter werden leise Anteile angehoben (OTT-Stil). Die Kennlinie darunter zeigt die Kurve live."),
 ("Band A / B", "zwei frei setzbare B\u00e4nder (Frequenz und Pegel), auch per Matrix steuerbar."),
 ("Kurve", "mit der Maus zeichnen, rechte Taste = 0 dB; Linear, W\u00e4rmer, Heller … sind fertige Kurven."),
 ("Leuchten", "der Hintergrund zeigt den Ausgang: blau/wei\u00df nach Pegel, blauer wo der EQ absenkt, r\u00f6ter wo er anhebt."),
 ("Stereobreite / Panorama", "Breite und Position der Summe im Stereobild."),
 ("Bass mono / mono bis", "legt alles unter der Frequenz (Standard 120 Hz) in die Mitte: der Bass bleibt im Club und auf Mono-Anlagen druckvoll und phasenfest, Breite und Raum dar\u00fcber bleiben erhalten. Kommt nach Stereobreite und Panorama, vor dem Limiter."),
 ("Limiter / HQ-Modus / Master", "dieselben Regler wie im Reiter Schnell, hier am Ende des Signalwegs: Spitzenbegrenzung, Qualit\u00e4t und Gesamtlautst\u00e4rke."),
]),
("Reiter Extras", [
 ("Sprache / Language", "Sprache der Oberfl\u00e4che (Deutsch, English, weitere als Datei im Ordner Sprachen). Schneller: Klick auf die kleine Flagge rechts in der Reiterzeile schaltet zur n\u00e4chsten Sprache."),
 ("Arpeggiator", "gehaltene Tasten nacheinander: Richtung, Oktaven, Notenwert, L\u00e4nge, Swing, Schritte und Schrittmuster (Klick = Schritt an/aus)."),
 ("Latch", "wie beim microKORG: losgelassene Tasten spielen im Arp weiter, bis neue Tasten angeschlagen werden - der neue Akkord ersetzt den alten. Solange Tasten gedrückt sind, kommen weitere dazu. Stoppen: Latch aus oder \"Alle Noten aus\"."),
 ("Tonleiter / Grundton / Tasten", "jeder Ton - Grains und Oszillatoren, vom Keyboard, aus der DAW, vom Arp, Pitch-Zufall oder LFO - rastet auf den n\u00e4chsten Ton der Tonleiter ein (bei Gleichstand nach oben). Tasten \u201ewei\u00dfe Tasten = Tonleiter\u201c: die wei\u00dfen Tasten ab C4 spielen der Reihe nach die T\u00f6ne der Tonleiter (C4 = Grundton), schwarze Tasten schweigen."),
 ("Freeze", "Leseposition steht still, der Klang friert ein."),
 ("Morph, Morph-LFO", "blendet zwischen Klang A und Ziel B; der Morph-LFO bewegt das automatisch (auch frei gezeichnet, Klick auf die Grafik)."),
 ("Zwei Klänge (Morph-Art)", "an (Standard): A und B sind zwei vollstaendig getrennte Klänge - jeder mit eigenen Stimmen, Arpeggiator, LFOs, Matrix, Filtern und Effekten; Morph regelt nur, wie laut A und B sind. Aus: ein einziger Klang, dessen Reglerwerte stufenlos von A nach B wandern (Schalter springen bei 50 %). Aeltere Presets mit Ziel B laden mit 'aus'."),
 ("Ziel B merken / laden / l\u00f6schen", "aktuellen Klang oder ein anderes Preset als Ziel B festlegen."),
 ("A ↔ B tauschen", "Bearbeitungstausch: A und B tauschen die Pl\u00e4tze (Regler, Matrix, LFO-Formen, Arp-Muster, EQ, Sample), Morph wird gespiegelt - der Klang bleibt gleich, die Regler zeigen jetzt Klang B. Nochmal klicken = zur\u00fcck."),
 ("Schwellen-Tor: Quelle, Schwelle, Ruhe-Dauer", "wird 1, sobald eine beliebige Quelle die Schwelle \u00fcberschreitet (Schalter/Trigger); Ruhe = Ereignis nach so langer Stille."),
]),
("Reiter Mischpult", [
 ("Fader", "alle Lautst\u00e4rken an einem Ort: Grains, Osz 1-3, Echo, Hall, die Effekte Gate (Tiefe), Crusher, Chorus und Phaser (Mix; ihre Anzeige zeigt, wie stark der Effekt den Klang ver\u00e4ndert), Morph, Panorama, Summe (Grains + Oszillatoren), Master. Es sind dieselben Regler wie in den anderen Reitern - wer hier schiebt, sieht es dort und umgekehrt."),
 ("Haken unter den Fadern", "Grains, Oszillatoren, Echo, Hall und die vier Effekte ein/aus."),
 ("Eingänge (DAW)", "Pegel der Host-Eingänge E1-E4 und Auswahl, welches Paar Sidechain 1 bzw. 2 speist. Sidechain 2 liefert der Matrix seinen Pegel (Quelle \"Sidechain 2\") und seine Tonhöhe (Quelle \"SC2-Tonhöhe\", wird nur gerechnet, wenn eine Zeile sie nutzt)."),
 ("Leistung", "Leistungsstufe: begrenzt Stimmen und Grains, wenn der Rechner knapp wird (wird mit Presets nicht geladen)."),
]),
("Reiter Leistung", [
 ("Rendern in H\u00f6chstqualit\u00e4t", "beim Export der DAW immer HQ und volle Stimmenzahl."),
 ("Oversampling 2x (bei HQ)", "Standard an: Bei HQ rechnen Oszillatoren und S\u00e4ttigung intern mit doppelter Abtastrate. Harte FM-, Sync- und Drive-Kl\u00e4nge bleiben sauber, ohne metallische Spiegelfrequenzen. Kostet bei oszillatorlastigen Kl\u00e4ngen bis etwa die doppelte Rechenzeit der Oszillatoren. Geh\u00f6rt zum Rechner, nicht zum Preset."),
 ("Oszillatoren: Wavetable / Klassisch", "Wavetable (Standard): Dreieck, S\u00e4ge und Rechteck kommen aus bandbegrenzten Tabellen (61 Stufen je Sechstel-Oktave) - praktisch ohne Spiegelfrequenzen (-84 dB statt -42 dB), volle H\u00f6hen bis 17 kHz auch im Bass, ohne Oversampling und daher nicht teurer. Klassisch: genau der Oszillator bis Version 2.9, f\u00fcr alte Projekte, die bitgleich klingen sollen. Geh\u00f6rt zum Rechner, nicht zum Preset."),
 ("Lastliste", "welche Klangbausteine im aktuellen Klang wie viel Rechenzeit kosten (Grains, HQ, Oszillatoren, Filter, Matrix, Echo, Hall …)."),
 ("Zeiger / Laufzeit", "geschätzte Gesamtlast und gemessene Rechenzeit im Host (Aufrufe/s, Anteil am Puffer, Spitzenwert)."),
]),]

NO = {"Sprache / Language", "Freie Form: Klaviatur, Gl\u00e4ttung", "Zonen 1-3", "Aufnahme", "Kategorie / Stern", "Wiederholen", "Lastliste", "Zeiger / Laufzeit", "Audio laden...", "Alle Noten aus", "Okt - / Okt +", "Preset w\u00e4hlen, < >", "Speichern...", "CLIP / MIDI",
      "Info", "Erklärungen", "Hilfe", "Statuszeile", "Autoplay, Haken \u201ealle\u201c", "Variieren / St\u00e4rke / Variieren in", "A/B", "Spektrum", "Kurve", "Leuchten",
      "Ziel B merken / laden / l\u00f6schen", "A <-> B tauschen"}
PART = {"Bend / Mod": "MIDI", "Latch": "Arp Latch", "Arpeggiator": "ja (Muster: nein)", "LFO 1 bis 8: Rate, Form, Sync": "ja (freie Form: nein)",
        "Morph, Morph-LFO": "ja (freie Form: nein)", "Zwei Klänge (Morph-Art)": "ja", "Modulationsmatrix": "ja (alle Zeilen)",
        "Sidechain-Trigger: Pegel / Ton": "ja (nicht modulierbar)",
        "Trance-Gate": "ja (Muster: nein; Trance-Gate an, Notenwert, Schritte, Tiefe, Glättung)"}
PNAMES = {
 "Makros": "Textur, Bewegung, Helligkeit, Raum, Streuung, Hüllk.-Länge",
 "HQ-Modus": "HQ-Modus", "Limiter": "Limiter", "Master": "Master",
 "Auswahl Start / Ende": "Auswahl Start, Auswahl Ende", "Position": "Position", "Spray": "Spray", "Scan": "Scan",
 "Graingr\u00f6\u00dfe": "Graingröße", "Dichte": "Dichte", "Glide / Zeit": "Glide, Glide-Zeit",
 "Pitch": "Pitch", "Oktave": "Grain-Oktave", "Ausgang > Schwelle": "Ausgangs-Schwelle", "Pitch Zufall": "Pitch Zufall", "Bend-Bereich": "Bend-Bereich", "Stereobreite": "Stereobreite", "Grain-Panorama": "Grain-Panorama",
 "R\u00fcckw\u00e4rts": "Rückwärts", "Lautst\u00e4rke": "Lautstärke", "Fenster": "Fenster", "Key Tracking": "Key Tracking",
 "Auto-Stimmung": "Auto-Stimmung",
 "Attack / Decay / Sustain / Release": "Attack, Decay, Sustain, Release",
 "LFO 1 bis 8: Rate, Form, Sync": "LFO1..LFO8 Rate, Form, Sync", "Einmal": "LFO1..LFO8 Einmal", "Neustart": "LFO1..LFO8 Trigger", "Partner": "LFO1..LFO8 Partner", "Stopp": "LFO1..LFO8 Stopp, Stoppzeit, Stoppzeit Takt",
 "Sidechain-Trigger: Pegel / Ton": "SC-Trig Pegel, SC-Schwelle, SC-Trig Ton, SC-Ton-Schwelle", "Auto-Pitch": "Auto-Pitch",
 "Freie Makros": "Makro 1..4, Makro 1..4 Kurve",
 "Modulationsmatrix": "Mod1..Mod32 Quelle, Ziel, Menge, Faktor, Offset",
 
 "Filter an, Typ": "Filter an, Filtertyp", "Cutoff / Resonanz": "Cutoff, Resonanz", "Kontur": "Kontur",
 "H\u00fcllkurve (Menge) + Filter-H\u00fcllkurve": "Filter-Hüllk., F-Attack, F-Decay, F-Sustain, F-Release",
 "Echo: Zeit / Sync / R\u00fcckkopplung / D\u00e4mpfung / Mix": "Echo an, Echo Zeit, Echo Sync, Feedback, Dämpfung, Echo Mix",
 "Echo Pitch": "Echo Pitch", "Ping-Pong": "Ping-Pong",
 "Hall: Raum, Gr\u00f6\u00dfe, Nachhall, D\u00e4mpfung, Vorverz\u00f6gerung, Breite, Mix": "Hall an, Hall Raum, Hall Größe, Hall Zeit, Hall Dämpfung, Hall Predelay, Hall Breite, Hall Mix",
 "Bass-Schnitt / H\u00f6hen-Schnitt": "Hall Bass-Schnitt, Hall Höhen-Schnitt", "Eingang → Echo/Hall": "Eingang Echo/Hall", "Latch": "Arp Latch", "Eingänge (DAW)": "SC1 Eingang, SC2 Eingang", "Leistung": "Leistung",
 "Trance-Gate": "Trance-Gate an, Trance-Gate Notenwert, Trance-Gate Schritte, Trance-Gate Tiefe, Trance-Gate Glättung", "Anlauf / Anlauf-Start": "Anlauf an, Anlauf-Start", "Schleife hin und her": "Schleife",
 "Chorus: Tempo / R\u00fcckkopplung / Mix": "", "Chorus: Tempo / Tiefe / R\u00fcckkopplung / Mix": "Chorus an, Chorus Tempo, Chorus Tiefe, Chorus Rückkopplung, Chorus Mix",
 "Phaser: Tempo / Tiefe / R\u00fcckkopplung / Mix": "Phaser an, Phaser Tempo, Phaser Tiefe, Phaser Rückkopplung, Phaser Mix",
 "Bitcrusher: Bits / Abtastrate / Mix": "Bitcrusher an, Bitcrusher Bits, Bitcrusher Rate, Bitcrusher Mix",
 "Unison / Verstimmung / Breite": "Osz Unison, Osz Unison Verstimmung, Osz Unison Breite (Osz2, Osz3 entsprechend)",
 "Rendern in H\u00f6chstqualit\u00e4t": "Rendern in Höchstqualität", "Gezeichnet / Zeichnen …": "Osz Gezeichnet (Osz2, Osz3 entsprechend)", "Wavetable an / Laden … / Position": "Osz Wavetable an, Osz WT-Position (Osz2, Osz3 entsprechend)", "Sub / Sub-Lage / Rauschen (nur Osz 1)": "Sub Pegel, Sub Oktave, Sub Welle, Rauschen Pegel", "Reihenfolge der Effekte": "Effekt-Reihenfolge", "folgt Pitch": "Osz folgen Pitch", "Modulations-H\u00fcllkurven 1 / 2": "Mod-Hüllk. 1 Attack/Decay/Sustain/Release, Mod-Hüllk. 2 …", "Oversampling 2x (bei HQ)": "Oversampling", "Oszillatoren: Wavetable / Klassisch": "Oszillator-Modell", "Feedback-Resampling: an / Anteil neu / Durchlauf / Im Takt": "Resampling, Resampling Anteil, Resampling Tempo, Resampling Sync",
 "Filter 2": "Filter2 an, Filter-Verschaltung, Filter2 Typ, Filter2 Cutoff, Filter2 Resonanz, Filter2 Kontur, Filter2 Hüllk.",
 "EQ an, B\u00e4sse, H\u00f6hen": "EQ an, EQ Bässe, EQ Höhen", "Band A / B": "EQ Band A Freq, EQ Band A Pegel, EQ Band B Freq, EQ Band B Pegel",
 "Arpeggiator": "Arp an, Arp Richtung, Arp Oktaven, Arp Notenwert, Arp Länge, Arp Swing, Arp Schritte",
 "Tonleiter / Grundton / Tasten": "Tonleiter, Grundton, Tonleiter-Tasten", "S\u00e4ttigung / Art": "Sättigung, Sättigung Art", "Bass mono / mono bis": "Bass mono, Bass mono bis", "Kompressor: an, Menge, Tempo, Verh\u00e4ltnis, Schwelle, Knick": "Kompressor an, Kompressor Menge, Kompressor Tempo, Kompressor Verh\u00e4ltnis, Kompressor Schwelle, Kompressor Knick", "Freeze": "Freeze",
 "Stereobreite / Panorama": "Summen-Breite, Summen-Panorama", "Limiter / HQ-Modus / Master": "Limiter, HQ-Modus, Master",
 "Morph, Morph-LFO": "Morph, Morph-LFO Form, Morph-LFO Rate, Morph-LFO Sync, Morph-LFO Tiefe", "Zwei Klänge (Morph-Art)": "Morph-Art",
 "Schwellen-Tor: Quelle, Schwelle, Ruhe-Dauer": "Tor-Quelle, Tor-Schwelle, Ruhe-Dauer",
 "Oszillator an": "Osz an / Osz2 an / Osz3 an", "Grains an / Pegel": "Grains an, Grain-Pegel", "Welle": "Osz Welle (Osz2, Osz3 entsprechend)", "Sync (Obert\u00f6ne)": "Osz Sync (Osz2, Osz3 entsprechend)",
 "Oktave / Feinstimmung / Pegel / Panorama": "Osz Oktave, Osz Fein, Osz-Pegel, Osz Panorama (Osz2, Osz3 entsprechend)",
 "FM-Verh\u00e4ltnis / FM-Menge": "Osz FM-Verh., Osz FM-Menge (Osz2, Osz3 entsprechend)",
 "FM-Klangfarbe": "FM-Hüllk. eigen, FM Attack, FM Decay, FM Sustain, FM Release (Osz2, Osz3 entsprechend)",
 "Lautst\u00e4rke-H\u00fcllkurve": "Osz Attack, Osz Decay, Osz Sustain, Osz Release (Osz2, Osz3 entsprechend)",
 "Eigener Filter": "Osz-Filter an, Osz-Filter Typ, Osz-Filter Cutoff, Osz-Filter Resonanz, Osz-Filter Kontur, Osz-Filter Hüllk. (Osz2-Filter, Osz3-Filter entsprechend)",
 "Fader": "dieselben Parameter wie in den Reitern (kein eigener Wert)", "Verz\u00f6gerung je Ereignis": "Verz. Note an, Verz. Note an Takt, Verz. Note aus … Verz. Ausgang Takt", "Haken unter den Fadern": "Grains an, Osz an, Osz2 an, Osz3 an, Echo an, Hall an",
}
def vst(n):
    if n in NO:
        return "nein"
    v = PART.get(n, "ja")
    pn = PNAMES.get(n)
    if pn and v.startswith("ja"):
        if "(" in v:
            v = v[:-1] + "; " + pn + ")"
        else:
            v = v + " (" + pn + ")"
    return v

BS = "\\"
def row(c1, c2, c3, head=False, shade=False, yes=None):
    pat = (BS + "clcbpat6") if head else ((BS + "clcbpat7") if shade else (BS + "clcbpat8"))
    r = BS + "trowd" + BS + "trgaph90" + BS + "trleft0"
    r += pat + BS + "cellx2500" + pat + BS + "cellx7300" + pat + BS + "cellx10200\n"
    b = (BS + "b ") if head else ""
    if yes is None:
        yes = c3.startswith("ja")
    c3col = (BS + "cf4 ") if yes else (BS + "cf5 ")
    if head:
        c3col = ""
    r += BS + "pard" + BS + "intbl{" + b + BS + "cf2 " + c1 + "}" + BS + "cell"
    r += BS + "pard" + BS + "intbl{" + b + c2 + "}" + BS + "cell"
    r += BS + "pard" + BS + "intbl{" + b + c3col + c3 + "}" + BS + "cell" + BS + "row\n"
    return r

import glob


def load_dict(path):
    d = {}
    for ln in open(path, encoding='utf-8-sig').read().split('\n'):
        ln = ln.rstrip('\r')
        if ln and not ln.startswith('#') and '\t' in ln:
            k, v = ln.split('\t', 1)
            d[k.replace('\\n', '\n')] = v.replace('\\n', '\n')
    return d


def make_tr(d, missing):
    if d is None:
        return lambda t: t
    def tr(t):
        key = t.strip(' ').rstrip(' :') or t
        if key in d:
            return t.replace(key, d[key], 1)
        missing.add(key)
        return t
    return tr


def vst_tr(n, T):
    v = vst(n)
    if T('ja') == 'ja':
        return v
    # "ja (Name, Name; ...)" -> Teile einzeln uebersetzen
    out = v
    if v.startswith('ja'):
        rest = v[2:].strip()
        out = T('ja')
        if rest.startswith('(') and rest.endswith(')'):
            inner = rest[1:-1]
            segs = []
            for seg in inner.split(';'):
                seg = seg.strip()
                if ':' in seg:
                    a, b = seg.split(':', 1)
                    segs.append(T(a.strip()) + ': ' + T(b.strip()))
                else:
                    segs.append(', '.join(T(x.strip()) for x in seg.split(',')))
            out += ' (' + '; '.join(segs) + ')'
    elif v == 'nein':
        out = T('nein')
    else:
        out = T(v)
    return out


def build_block(T):
    parts = ["{" + BS + "cf3" + BS + "b" + BS + "fs26 " + T("11. Alle Regler im \u00dcberblick") + BS + "par}\n",
             T("Was jeder Regler und Knopf bewirkt - Reiter f\u00fcr Reiter.") + " " +
             T("Spalte") + " {" + BS + "b " + T("VST-Parameter") + "}: "
             "{" + BS + "cf4 " + T("ja") + "} = " + T("im Host automatisierbar und Ziel in der Modulationsmatrix") + ", "
             "{" + BS + "cf5 " + T("nein") + "} = " + T("nur im Plugin-Fenster") + ", {" + BS + "cf5 MIDI} = " +
             T("kommt als MIDI-Signal") + ". " + T("Das Tempo kommt immer vom Host.") + BS + "par" + BS + "par\n"]
    for tab, items in TABS:
        parts.append("{" + BS + "cf3" + BS + "b" + BS + "fs22 " + T(tab) + BS + "par}\n")
        parts.append(row(T("Regler / Knopf"), T("Was er bewirkt"), T("VST-Parameter"), head=True))
        for k, (name, text) in enumerate(items):
            parts.append(row(T(name), T(text), vst_tr(name, T), shade=(k % 2 == 1), yes=vst(name).startswith("ja")))
        parts.append(BS + "pard" + BS + "par\n")
    return esc(''.join(parts))


def write_help(p, T):
    block = build_block(T)
    s = open(p, encoding='utf-8').read().rstrip()
    k = s.find(BS + "par\n{" + BS + "cf3" + BS + "b" + BS + "fs26 11. ")
    if k > 0:
        s = s[:k].rstrip() + "\n}"
    assert s.endswith('}')
    # Tabellenfarben: 6 = Kopfzeile, 7 = jede zweite Zeile
    if "red40" + BS + "green46" not in s:
        s = s.replace(BS + "red180" + BS + "green180" + BS + "blue180;}",
                      BS + "red180" + BS + "green180" + BS + "blue180;" + BS + "red40" + BS + "green46" + BS + "blue60;" + BS + "red34" + BS + "green34" + BS + "blue38;" + BS + "red40" + BS + "green42" + BS + "blue48;}", 1)
    if "red40" + BS + "green42" not in s:
        s = s.replace(BS + "red34" + BS + "green34" + BS + "blue38;}", BS + "red34" + BS + "green34" + BS + "blue38;" + BS + "red40" + BS + "green42" + BS + "blue48;}", 1)
    s = s[:-1].rstrip() + "\n" + BS + "par\n" + block + "}\n"
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('ok', p, len(block), s.count('{') - s.count('}'))


if __name__ == '__main__':
    write_help('Hilfe/Hilfe.rtf', make_tr(None, None))
    for lf in sorted(glob.glob('Sprachen/[!_]*.txt')):
        code = os.path.splitext(os.path.basename(lf))[0]
        hp = 'Hilfe/Hilfe_%s.rtf' % code
        if os.path.exists(hp):
            miss = set()
            write_help(hp, make_tr(load_dict(lf), miss))
            if miss:
                print('  %s: %d Texte der Reglertabelle ohne Uebersetzung (stehen deutsch in %s; Tools/lang_check.py)' % (code, len(miss), hp))
