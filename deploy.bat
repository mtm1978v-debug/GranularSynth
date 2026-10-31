@echo off
rem ============================================================================
rem  GranularSynth - Auslieferung
rem  Baut Host + VST2-Plugin im Release-Modus fuer Win32 und Win64 und legt je
rem  Plattform einen fertigen Ordner an:
rem     Deploy\Win32\  GranularHost.exe, GranularSynth.dll, Beispieltoene\, Presets\, Hilfe\, Eigene Toene\, LIESMICH.txt, CHANGELOG.md, LICENSE.txt
rem     Deploy\Win64\  (dasselbe in 64 Bit)
rem  Voraussetzung: RAD Studio 23.0, Graphics32 (Ordner in GR32_DIR, z.B. per build.local.bat)
rem  Hinweis: laufende GranularHost.exe vorher schliessen (sonst ist die EXE gesperrt).
rem ============================================================================
setlocal
set ROOT=%~dp0
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" || goto :fehler

if exist "%ROOT%build.local.bat" call "%ROOT%build.local.bat"
if "%GR32_DIR%"=="" (
  echo Umgebungsvariable GR32_DIR fehlt: Ordner von Graphics32 ^(github.com/graphics32/graphics32^),
  echo z.B. in build.local.bat:  set GR32_DIR=C:\Komponenten\Graphics32
  exit /b 1
)
rem Uebersetzungen vollstaendig? (fehlende Texte stehen danach in Sprachen\_fehlend_<Sprache>.txt)
python "%ROOT%Tools\lang_check.py" || goto :fehler
for %%P in (Win32 Win64) do (
  echo.
  echo === %%P ===
  msbuild "%ROOT%GranularHost.dproj"  /t:Build /p:Config=Release /p:Platform=%%P /v:minimal || goto :fehler
  msbuild "%ROOT%GranularSynth.dproj" /t:Build /p:Config=Release /p:Platform=%%P /v:minimal || goto :fehler
  rem NIE den Ordner loeschen: dort liegen auch eigene Presets und "Eigene Toene" des Nutzers.
  rem Nur fehlende Ordner anlegen und die ausgelieferten Dateien ueberschreiben.
  if not exist "%ROOT%Deploy\%%P\Beispieltoene" mkdir "%ROOT%Deploy\%%P\Beispieltoene"
  if not exist "%ROOT%Deploy\%%P\Presets" mkdir "%ROOT%Deploy\%%P\Presets"
  if not exist "%ROOT%Deploy\%%P\Hilfe" mkdir "%ROOT%Deploy\%%P\Hilfe"
  if not exist "%ROOT%Deploy\%%P\Eigene Toene" mkdir "%ROOT%Deploy\%%P\Eigene Toene"
  if not exist "%ROOT%Deploy\%%P\Sprachen" mkdir "%ROOT%Deploy\%%P\Sprachen"
  copy /y "%ROOT%bin\%%P\GranularHost.exe"  "%ROOT%Deploy\%%P\" >nul || goto :fehler
  copy /y "%ROOT%bin\%%P\GranularSynth.dll" "%ROOT%Deploy\%%P\" >nul || goto :fehler
  rem FX-Variante (dieselbe DLL, meldet sich am Namen "FX" als Effekt - fuer Sidechain im FL-Mixer)
  copy /y "%ROOT%bin\%%P\GranularSynth.dll" "%ROOT%Deploy\%%P\GranularSynth FX.dll" >nul || goto :fehler
  rem VST3 (dieselbe DLL, exportiert zusaetzlich GetPluginFactory): Instrument und FX in einer Datei
  copy /y "%ROOT%bin\%%P\GranularSynth.dll" "%ROOT%Deploy\%%P\GranularSynth.vst3" >nul || goto :fehler
  copy /y "%ROOT%Beispieltoene\*.wav" "%ROOT%Deploy\%%P\Beispieltoene\" >nul || goto :fehler
  copy /y "%ROOT%Presets\*.gspreset" "%ROOT%Deploy\%%P\Presets\" >nul || goto :fehler
  copy /y "%ROOT%Presets\*.txt" "%ROOT%Deploy\%%P\Presets\" >nul || goto :fehler
  copy /y "%ROOT%Hilfe\*.rtf" "%ROOT%Deploy\%%P\Hilfe\" >nul || goto :fehler
  copy /y "%ROOT%Eigene Toene\LIESMICH.txt" "%ROOT%Deploy\%%P\Eigene Toene\" >nul || goto :fehler
  copy /y "%ROOT%Eigene Toene\README_EN.txt" "%ROOT%Deploy\%%P\Eigene Toene\" >nul || goto :fehler
  rem Sprachdateien (ohne Arbeitslisten _*.txt)
  for %%F in ("%ROOT%Sprachen\*.txt") do (echo %%~nxF| findstr /b "_" >nul || copy /y "%%F" "%ROOT%Deploy\%%P\Sprachen\" >nul)
  copy /y "%ROOT%LIESMICH.txt" "%ROOT%Deploy\%%P\" >nul || goto :fehler
  copy /y "%ROOT%README_EN.txt" "%ROOT%Deploy\%%P\" >nul || goto :fehler
  copy /y "%ROOT%CHANGELOG.md" "%ROOT%Deploy\%%P\" >nul || goto :fehler
  copy /y "%ROOT%LICENSE.txt" "%ROOT%Deploy\%%P\" >nul || goto :fehler
)

rem Installation: Setup.exe (fragt nach Administratorrechten) startet Install.ps1 mit der Auswahl
rem 32/64 Bit, VST2, VST3, Test-Host und Zielordner
call "%ROOT%Tools\Setup\build_setup.bat" || goto :fehler
copy /y "%ROOT%Tools\Setup\Setup.exe" "%ROOT%Deploy\" >nul || goto :fehler
copy /y "%ROOT%Tools\Install.ps1" "%ROOT%Deploy\" >nul || goto :fehler

echo.
echo Auslieferung fertig:
dir /b /s "%ROOT%Deploy\*.exe" "%ROOT%Deploy\*.dll" "%ROOT%Deploy\*.vst3" "%ROOT%Deploy\*.ps1"
exit /b 0

:fehler
echo.
echo *** FEHLER - Auslieferung abgebrochen ***
exit /b 1
