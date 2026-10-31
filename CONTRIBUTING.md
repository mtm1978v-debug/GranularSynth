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

---

# Contributing to GranularSynth (English)

Thanks for your interest! GranularSynth is a small project with a single maintainer. To keep it manageable, these rules apply.

## Reporting bugs and requesting features

Use the **Issues** – all of them are welcome:

- **Bug:** template *Fehler melden / Report a bug*. Please state version, 32/64 bit, VST2/VST3, your DAW and the steps to reproduce.
- **Feature request:** template *Feature-Wunsch / Feature request*. Describe what you want to achieve musically, not only which control is missing.
- **Presets:** see the discussion *Presets gesucht! / Looking for presets!* or the template *Preset einreichen / Submit a preset*. Only your own presets and samples (or public domain) – no copyrighted WAV files or sound sources.
- **Questions and ideas:** in the **Discussions**.

## Contributing code: by arrangement only

Pull requests are accepted **only after prior agreement**:

1. Open an issue and describe what you want to change and why.
2. Wait for a "yes, please" in the issue – only then is the work worthwhile.
3. Reference the issue in your pull request.

Pull requests without prior agreement will be closed with a friendly pointer to this process.

## What a contribution must meet

The technical rules are described in detail in [CLAUDE.md](CLAUDE.md) (German). The most important ones:

- **Do not change existing presets.** The test bench (`GranularHost.exe -bench`) compares all presets bit by bit with a reference; the line `Klang-Regression` must report `OK`.
- **Stay compatible:** new VST parameters are only appended to `VST_ADDED`, never deleted or renumbered; new modulation sources only at the end of `TModSource`; preset numbers stay as they are.
- **Audio thread:** no memory allocation, no string operations, no blocking locks.
- **Both platforms:** Win32 and Win64 must build, and the test bench must run without `FEHLER` on both.
- **Translations:** every visible text goes through `Tr(...)`; `python Tools/lang_check.py` must report no missing texts, and the test bench checks that texts fit their controls in every language.
- **Source files** are UTF-8 with BOM; comments and the user interface are written in German (the English interface comes from `Sprachen/en.txt`).
- **CHANGELOG.md:** add your change under *Neu*, *Geändert* or *Behoben*.

## Licence of contributions

By contributing you agree that your contribution is published under the **GNU GPL v3 or later**, like the whole project.
