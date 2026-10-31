# GranularSynth

**Granular- und FM-Synthesizer als VST2- und VST3-Plugin für Windows (32 und 64 Bit)**, mit eigenem Test-Host.
Geschrieben in Delphi, ohne Plugin-Framework. Die rechenintensiven Teile sind von Hand in SSE-Assembler optimiert, damit die CPU-Last niedrig bleibt.

*Granular and FM synthesizer plugin (VST2/VST3, Windows 32/64 bit) with its own test host. The user interface and documentation are in German.*

![Reiter Grain](docs/screenshots/grain.png)

## Was er kann

- **Granular-Synthese** aus beliebigen Samples (WAV, MP3 u. a.). Einstellbar sind Auswahl, Position, Spray, Scan, Graingröße, Dichte, Fenster und Rückwärts-Anteil. Dazu kommen ein Anlauf vor der Auswahl, eine Schleife hin und her und bis zu drei Zonen.
- **Drei FM-Oszillatoren** mit eigener Hüllkurve, eigenem Filter und Unison.
- **Modulationsmatrix mit 32 Zeilen**, 8 LFOs (auch frei gezeichnet oder in Stufen), Hüllkurven, Velocity, Sidechain-Pegel und Sidechain-Tonhöhe. Die Modulation wirkt je Note.
- **Vier freie Makros**: Ein Regler bewegt beliebig viele Ziele mit wählbarer Kurve. Die Makros lassen sich in der DAW automatisieren.
- **Effekte**: zwei Filter, EQ, Echo, Hall, Gate, Crusher, Chorus, Phaser und Trance-Gate. Dazu ein Mischpult mit Pegelanzeigen.
- **Sidechain**: Tonhöhe erkennen (Auto-Pitch), Trigger aus Pegel und Ton, Aufnahme.
- **Morph**: zwischen zwei kompletten Klängen überblenden.
- **Bedienung**: MIDI-Learn, Rückgängig/Wiederholen, A/B-Vergleich, Variieren, Preset-Kategorien und Favoriten. Presets lassen sich mit eingebetteten Samples speichern.
- **Mitgeliefert**: über 160 Presets, darunter ein **Lernpfad (L01–L37)**, der die Matrix Schritt für Schritt erklärt. Dazu Beispieltöne und eine ausführliche Hilfe.
- **GranularHost**: ein kleiner Test-Host für VST2 und VST3 mit Klaviatur, Autoplay, Audio-Ein- und -Ausgang, Sidechain und einem Prüfstand (`-bench`).

![Modulationsmatrix und freie Makros](docs/screenshots/modulation.png)

![Mischpult](docs/screenshots/mischpult.png)

## Installation

1. Lade die aktuelle Version unter **[Releases](../../releases)** herunter und entpacke sie.
2. Starte `Setup.exe`. Wähle 64 oder 32 Bit (passend zur DAW), VST2 und/oder VST3 und auf Wunsch den Test-Host.
3. Lass die DAW neu nach Plugins suchen.

Entfernen lässt sich GranularSynth über *Windows-Einstellungen › Apps*.
Mehr dazu steht in [LIESMICH.txt](LIESMICH.txt), die Änderungen je Version stehen in [CHANGELOG.md](CHANGELOG.md).

## Selbst bauen

Voraussetzungen:
- Embarcadero Delphi 12 (RAD Studio 23.0)
- [Graphics32](https://github.com/graphics32/graphics32). Den Ordner trägst du in der Umgebungsvariablen `GR32_DIR` ein, am einfachsten in einer Datei `build.local.bat` neben `build.bat`:
  ```bat
  @set GR32_DIR=C:\Komponenten\Graphics32
  ```
  Wer in der Delphi-IDE baut, legt `GR32_DIR` unter *Tools › Optionen › Umgebungsvariablen* an.
- Python 3, nur für die Werkzeuge in `Tools/`

```bat
build.bat Release Win64 Alle
build.bat Release Win32 Alle
bin\Win64\GranularHost.exe -bench
deploy.bat
```

- `build.bat` baut für beide Plattformen.
- Der Prüfstand `-bench` schreibt seine Ergebnisse nach `bin\<Plattform>\bench.txt`.
- `deploy.bat` legt die Auslieferung nach `Deploy\`.

Aufbau, Regeln und Werkzeuge stehen in [CLAUDE.md](CLAUDE.md). Diese Datei ist für Entwickler und für KI-Assistenten gedacht.

## Mitmachen

Fehlermeldungen und Feature-Wünsche sind willkommen: bitte über **[Issues](../../issues)** mit den Vorlagen dort.
Wenn du Code beitragen möchtest, frag bitte vorher in einem Issue an. Die Regeln stehen in [CONTRIBUTING.md](CONTRIBUTING.md).

## Lizenz

Copyright © 2026 Matthias Haberecht.
GranularSynth ist freie Software unter der **GNU General Public License Version 3 oder neuer** (siehe [LICENSE.txt](LICENSE.txt)). Du darfst sie nutzen, weitergeben und verändern. Veränderte Fassungen müssen ebenfalls unter der GPL stehen und auf das Original verweisen.

VST ist eine Marke der Steinberg Media Technologies GmbH. Die VST-Schnittstellen sind hier eigenständig aus der öffentlichen Spezifikation umgesetzt.
