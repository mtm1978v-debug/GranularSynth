GranularSynth - the "Eigene Toene" (own sounds) folder
=====================================================

This is where your own sounds (WAV, MP3 etc.) used in your own presets are kept.
The folder is empty when delivered and fills up by itself.

How it works
------------
1. Use "Load audio..." to load any audio file - no matter where it is
   (WAV, MP3, M4A, AAC, WMA, FLAC, AIFF, OGG).
2. When you "Save..." a preset, the file is automatically COPIED HERE
   if it is outside the plugin folder. The preset only remembers
   "Eigene Toene\<file name>" (relative path).
   This also applies to the sound of morph target B.
3. If the file is already in the plugin folder (e.g. here or in "Beispieltoene"),
   nothing is copied - the preset refers to it directly.

Same file name but a different file? Then the copy gets a number
(e.g. "Gitarre_2.wav"). The same file is never copied twice.

Sharing and moving
------------------
Presets and sounds stay together as long as this folder sits next to the presets
in the plugin folder. So when sharing, pass on the "Presets" folder AND this
"Eigene Toene" folder. If the plugin folder is moved, a preset finds its sound
again by its file name here or in "Beispieltoene".

Please do not rename or delete files that are used by presets -
otherwise the preset can no longer find its sound.

You may also put your own files here by hand and then load them from here
with "Load audio...".

Language: the interface language can be switched between Deutsch and English
in the Extras tab ("Sprache / Language").
