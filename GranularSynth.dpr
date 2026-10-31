{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

library GranularSynth;

{ VST2- und VST3-Plugin (Synthesizer) in einer DLL. Win32 fuer das alte FL Studio, Win64 fuer neuere Hosts.
  VST2: VSTPluginMain und - fuer alte Hosts - "main" (Datei GranularSynth.dll / GranularSynth FX.dll).
  VST3: GetPluginFactory, InitDll, ExitDll (dieselbe Datei als GranularSynth.vst3 ausgeliefert). }

uses
  Granular.Params in 'Source\Engine\Granular.Params.pas',
  Granular.Sample in 'Source\Engine\Granular.Sample.pas',
  Granular.Eq in 'Source\Engine\Granular.Eq.pas',
  Granular.EqView in 'Source\UI\Granular.EqView.pas',
  Granular.Fader in 'Source\UI\Granular.Fader.pas',
  Granular.LoadView in 'Source\UI\Granular.LoadView.pas',
  Granular.Hints in 'Source\UI\Granular.Hints.pas',
  Granular.Reverb in 'Source\Engine\Granular.Reverb.pas',
  Granular.DSP in 'Source\Engine\Granular.DSP.pas',
  Granular.Pitch in 'Source\Engine\Granular.Pitch.pas',
  Granular.AudioDecode in 'Source\Engine\Granular.AudioDecode.pas',
  Granular.Engine in 'Source\Engine\Granular.Engine.pas',
  Granular.State in 'Source\Engine\Granular.State.pas',
  Granular.WaveView in 'Source\UI\Granular.WaveView.pas',
  Granular.Prof in 'Source\UI\Granular.Prof.pas',
  Granular.Keyboard in 'Source\UI\Granular.Keyboard.pas',
  Granular.ModViews in 'Source\UI\Granular.ModViews.pas',
  Granular.GfxAsm in 'Source\UI\Granular.GfxAsm.pas',
  Granular.ComboFit in 'Source\UI\Granular.ComboFit.pas',
  Granular.FreeLfoView in 'Source\UI\Granular.FreeLfoView.pas',
  Granular.InfoView in 'Source\UI\Granular.InfoView.pas',
  Granular.Spectrum in 'Source\UI\Granular.Spectrum.pas',
  Granular.Banner in 'Source\UI\Granular.Banner.pas',
  Granular.Editor in 'Source\UI\Granular.Editor.pas',
  Granular.Vst2 in 'Source\Vst\Granular.Vst2.pas',
  Granular.VstPlugin in 'Source\Vst\Granular.VstPlugin.pas',
  Granular.Vst3 in 'Source\Vst\Granular.Vst3.pas',
  Granular.Vst3Plugin in 'Source\Vst\Granular.Vst3Plugin.pas';

{$R *.res}
{$R Version.res}   // Versionsinfo (Version.rc, von Tools/bump_version.py erzeugt, build.bat uebersetzt)

function VSTPluginMain(AudioMaster: TAudioMasterCallback): PAEffect; cdecl;
begin
  Result := CreatePlugin(AudioMaster);
end;

exports
  VSTPluginMain,
  VSTPluginMain name 'main',
  GetPluginFactory,
  InitDll,
  ExitDll;

begin
  // Ausnahmen im Gleitkomma nie an den Host weiterreichen
  IsMultiThread := True;
end.
