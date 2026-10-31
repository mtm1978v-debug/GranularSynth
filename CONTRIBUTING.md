# Mitmachen bei GranularSynth

Danke für dein Interesse! GranularSynth ist ein kleines Projekt mit einem Maintainer. Damit es übersichtlich bleibt, gelten diese Regeln.

## Fehler melden und Wünsche äußern

Dafür sind die **Issues** da, alle sind ausdrücklich willkommen:

- **Fehler:** Vorlage *Fehler melden*. Gib bitte Version, 32/64 Bit, VST2/VST3, die DAW und die Schritte an, mit denen sich der Fehler wiederholen lässt.
- **Feature-Wunsch:** Vorlage *Feature-Wunsch*. Beschreib, was du musikalisch erreichen willst, nicht nur, welcher Regler fehlt.
- **Fragen und Klangideen:** gern als Issue mit dem Label *Frage*.

## Code beitragen: nur nach Absprache

Pull Requests nehme ich **nur nach vorheriger Absprache** an:

1. Eröffne ein Issue und beschreib, was du ändern möchtest und warum.
2. Warte auf ein „Ja, gern“ im Issue. Erst dann lohnt sich die Arbeit.
3. Verweise im Pull Request auf das Issue.

Unabgesprochene Pull Requests schließe ich mit freundlichem Hinweis auf diesen Ablauf.

## Was ein Beitrag mitbringen muss

Die technischen Regeln stehen ausführlich in [CLAUDE.md](CLAUDE.md). Am wichtigsten sind diese:

- **Keine bestehenden Presets verändern.** Der Prüfstand (`GranularHost.exe -bench`) vergleicht alle Presets Bit für Bit mit einer Referenz. Die Zeile `Klang-Regression` muss `OK` melden.
- **Kompatibel bleiben:**
  - Neue VST-Parameter werden nur hinten an `VST_ADDED` angehängt. Keiner wird gelöscht oder umnummeriert.
  - Neue Modulationsquellen kommen nur ans Ende von `TModSource`.
  - Preset-Nummern bleiben, wie sie sind.
- **Audio-Thread:** keine Speicheranforderungen, keine String-Operationen, keine Sperren, die warten.
- **Beide Plattformen:** Win32 und Win64 müssen sich bauen lassen, der Prüfstand muss auf beiden ohne `FEHLER` laufen.
- **Quelltexte** sind UTF-8 mit BOM. Kommentare und Oberfläche sind auf Deutsch.
- **CHANGELOG.md:** Trag deine Änderung ein, unter *Neu*, *Geändert* oder *Behoben*. Wenn sie Folgen für vorhandene Presets oder Projekte hat, gehört das unter *Hinweis*.

## Lizenz der Beiträge

Mit einem Beitrag stimmst du zu, dass er unter der **GNU GPL v3 oder neuer** veröffentlicht wird, wie das ganze Projekt.
