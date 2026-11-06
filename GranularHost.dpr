{ GranularSynth - Granular + FM Synthese
  Copyright (C) 2026 Matthias Haberecht

  This program is free software: you can redistribute it and/or modify it under the terms of the
  GNU General Public License as published by the Free Software Foundation, either version 3 of the
  License, or (at your option) any later version. This program is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (LICENSE.txt) for details. }

program GranularHost;

{ VST2-Host ("Multitool") fuer GranularSynth.dll und andere VST2-Plugins gleicher Bitbreite.
  Die Engine-Units sind nur fuer den Benchmark (-bench) eingebunden. }

uses
  {$IFDEF USE_FASTMM5} FastMM5, {$ENDIF}   // schneller Speichermanager (optional, FASTMM_DIR) - muss zuerst stehen
  Vcl.Forms,
  Granular.Params in 'Source\Engine\Granular.Params.pas',
  Granular.Sample in 'Source\Engine\Granular.Sample.pas',
  Granular.Eq in 'Source\Engine\Granular.Eq.pas',
  Granular.Reverb in 'Source\Engine\Granular.Reverb.pas',
  Granular.DSP in 'Source\Engine\Granular.DSP.pas',
  Granular.Pitch in 'Source\Engine\Granular.Pitch.pas',
  Granular.State in 'Source\Engine\Granular.State.pas',
  Granular.AudioDecode in 'Source\Engine\Granular.AudioDecode.pas',
  Granular.Engine in 'Source\Engine\Granular.Engine.pas',
  Granular.Vst2 in 'Source\Vst\Granular.Vst2.pas',
  Granular.VstHost in 'Source\Host\Granular.VstHost.pas',
  Granular.Vst3Host in 'Source\Host\Granular.Vst3Host.pas',
  Granular.AudioIn in 'Source\Host\Granular.AudioIn.pas',
  Granular.AudioOut in 'Source\Host\Granular.AudioOut.pas',
  Granular.AutoPlay in 'Source\Host\Granular.AutoPlay.pas',
  Granular.DemoRender in 'Source\Host\Granular.DemoRender.pas',
  Granular.PresetGen in 'Source\Host\Granular.PresetGen.pas',
  Granular.ComboFit in 'Source\UI\Granular.ComboFit.pas',
  Granular.GfxAsm in 'Source\UI\Granular.GfxAsm.pas',
  Granular.Vst3 in 'Source\Vst\Granular.Vst3.pas',
  Granular.Bench in 'Source\Host\Granular.Bench.pas',
  Granular.Prof in 'Source\UI\Granular.Prof.pas',
  Granular.Keyboard in 'Source\UI\Granular.Keyboard.pas',
  MainForm in 'Source\Host\MainForm.pas' {frmMain};

{$R *.res}
{$R Version.res}   // Versionsinfo (Version.rc, von Tools/bump_version.py erzeugt, build.bat uebersetzt)

begin
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'GranularHost';
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
