﻿GranularSynth - Granular synthesizer (VST2 and VST3) with test host
==================================================================

Contents of this folder
-----------------------
  GranularSynth.dll   The VST2 plugin (synthesizer, stereo, 2 sidechain inputs)
  GranularSynth FX.dll  the same as a VST2 effect (for the sidechain in the FL mixer)
  GranularSynth.vst3  The VST3 plugin: contains "GranularSynth" (instrument) and
                      "GranularSynth FX" (effect). The banner shows after the version which
                      variant is running (VST2, VST2 FX, VST3, VST3 FX).
  GranularHost.exe    Small VST2/VST3 host for testing - loads GranularSynth.dll and also
                      other VST2 and VST3 plugins (same bitness!)
  Beispieltoene\      WAV files to try out (synthetically generated, free to use)

Goal
----
  Professional sound on the level of commercial digital synthesizers. Priorities:
  1. sound quality (including 2x oversampling for oscillators and saturation with HQ),
  2. low CPU load, 3. easy operation.

Language
--------
  The interface language can be switched between Deutsch and English in the
  Extras tab ("Sprache / Language") or by clicking the small flag at the right
  end of the tab row. The help follows the chosen language.

32 or 64 bit?
-------------
  Win32: for older hosts such as old FL Studio (32 bit). This version uses the
         optimised SSE assembler cores (Pentium III / Athlon XP or newer).
  Win64: for 64-bit hosts. A 64-bit host only loads 64-bit plugins and vice versa.

Installation (recommended)
--------------------------
  Run Setup.exe in the main folder of the package (Windows asks for administrator rights).
  In the window choose: 64 or 32 bit (matching your DAW - old FL Studio 11 is usually 32 bit),
  VST2 (GranularSynth + FX), VST3 and, if you like, the test host. The target folders are
  detected (VST2: registered VST folder, VST3: Common Files\VST3) and can be changed.
  Each target gets a folder "GranularSynth" with plugin, presets, example sounds and help.
  Your own presets and own sounds are kept when installing a new version.
  Then in FL Studio: Options > Manage plugins > Find plugins.
  Update: run Setup.exe of the new version - it suggests your previous selection.
  Online update: Setup.exe (or Windows Settings > Apps > GranularSynth > Modify) shows whether a newer
  version is available on GitHub; the "Online-Update" button downloads and installs it.
  Update notice: the plugin checks GitHub at most once a day. If a new version exists, a small arrow
  appears at the end of the tab row; clicking it starts the setup. Only the usual web request is sent,
  no data about you or your projects.
  Uninstall: Windows Settings > Apps > "GranularSynth (64 Bit)" or "(32 Bit)" > Uninstall;
  your own presets and own sounds can be kept if you wish.

Manual installation in FL Studio
--------------------------------
  1. Copy GranularSynth.dll into the VST plugin folder (e.g. ...\VstPlugins).
  2. In FL Studio: rescan plugins (Plugin manager / "Refresh"), then insert it
     as a generator.
  3. Sidechain: route a mixer channel to the plugin's input. The sidechain
     works through the modulation matrix (source "Sidechain" or "SC pitch")
     and through "Auto-Pitch".
  VST3: leave the whole folder together (with Presets\, Beispieltoene\, Hilfe\) and in FL
     Studio under Options > Manage plugins add this folder as an extra search path,
     then "Find plugins". The .vst3 file looks for presets and sounds in its own folder -
     do not copy it alone into "Common Files\VST3".
  Automation: every movement of a control in the plugin is reported to FL. Then in FL
     Tools > Last tweaked > Create automation clip (also works in old FL 11, VST2).
     VST3 in new FL versions: right-clicking a control shows the FL menu directly
     ("Create automation clip", "Link to controller ...") plus an entry for the
     GranularSynth menu (Modulate, MIDI Learn, Default value).
  The plugin saves its complete state in the project (including the path of the WAV file).
  The WAV file itself is not embedded - do not move it, and copy it along when moving projects.

GranularHost (test host)
------------------------
  - "Load VST..."       load any VST2 or VST3 plugin; the last one used starts again
  - "Reset"             delete the saved settings of the current plugin and
                        reload it with default values
  - Tempo               host tempo for tempo sync (LFO, echo); Autoplay sets it per piece
  - Keyboard            mouse or computer keyboard (A W S E D F T G Z/Y H U J K O L P,
                        octave with + / -). Can be switched off via "Keyboard".
  - Autoplay            plays demo pieces (classical and electronic) polyphonically
  - Sidechain           choose a recording device -> goes to plugin inputs 1/2;
                        IN/OUT shows the levels
  Settings per plugin are saved automatically in
      %APPDATA%\GranularSynth\vst\
  Host settings in %APPDATA%\GranularSynth\host.ini, also containing:
      [Audio] Puffer=6  Blockgroesse=512   (more buffers = less crackling, more latency)

GranularHost.exe command line options
-------------------------------------
  <path\Plugin.dll>   load this plugin
  -autoplay           start Autoplay immediately
  -nosave             do not save anything on exit
  -bench              measure performance (result in bench.txt next to the EXE)

Using GranularSynth (short version)
-----------------------------------
  Presets:     list at the top of the plugin (examples from Presets\), "Save..." creates your own.
               Samples from outside the plugin folder are copied into "Eigene Toene\"
               (own sounds) and stored with a relative path: take the plugin folder along
               = presets work anywhere.
  Load audio:  WAV, MP3, MPEG audio, WMA, AAC/M4A, FLAC, AIFF ... (anything Windows can play;
               via Windows Media Foundation, max. 4 minutes per file).
  Quick:       6 macros (Texture, Motion, Brightness, Space, Spread, Envelope length),
               50 % = preset unchanged. Vary (with locks per area), Undo, A/B.
               HQ mode (Hermite interpolation, cleaner) and Limiter (protects against clipping).
  Right-click on a control: assign modulation (LFO, sidechain, velocity, mod wheel ...),
               choose the amount, remove modulation, default value.
  Synth:       Waveform - the left mouse button drags the selection, the right one sets the
               position. Grains, sound, envelope.
  Modulation:  2 LFOs, sidechain envelope follower, Auto-Pitch, matrix with 8 slots:
               effective value = base value + (source x factor + offset) x amount.
               The red line under a control shows the current effective value.
               To follow the pitch of the sidechain: source SC pitch, target Pitch,
               factor x2.65 tone, offset -125 %, amount 100 %.
  Filter/Echo: low-pass/band-pass/high-pass with its own envelope, ping-pong echo
               (time free or synced to the tempo).

Licence
-------
  GranularSynth - Copyright (C) 2026 Matthias Haberecht
  Free software: you may redistribute and modify it under the terms of the GNU General
  Public License, version 3 or (at your option) any later version.
  Modified versions must also be released under the GPL and refer to the original.
  Without any warranty. The full licence text is in LICENSE.txt.
