@echo off
rem Aufruf: build.bat [Debug|Release] [Win32|Win64] [Host|Vst|Alle]
setlocal
set CFG=%1
if "%CFG%"=="" set CFG=Release
set PLT=%2
if "%PLT%"=="" set PLT=Win32
set WHAT=%3
if "%WHAT%"=="" set WHAT=Alle
rem Graphics32-Ordner: GR32_DIR (eigene Einstellungen in build.local.bat, nicht im Projektarchiv)
if exist "%~dp0build.local.bat" call "%~dp0build.local.bat"
if "%GR32_DIR%"=="" (
  echo Umgebungsvariable GR32_DIR fehlt: Ordner von Graphics32 ^(github.com/graphics32/graphics32^),
  echo z.B. in build.local.bat:  set GR32_DIR=C:\Komponenten\Graphics32
  exit /b 1
)
rem optional FastMM5 (github.com/pleriche/FastMM5): FASTMM_DIR = Ordner mit FastMM5.pas
if "%FASTMM_DIR%"=="" echo Hinweis: FASTMM_DIR nicht gesetzt - Speichermanager = Delphi-Standard
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
rem Versionsinfo (Explorer: Eigenschaften > Details) fuer DLL und Host aus Version.rc (Tools\bump_version.py)
brcc32 -fo"%~dp0Version.res" "%~dp0Version.rc" >nul || exit /b 1
if /I not "%WHAT%"=="Vst" msbuild "%~dp0GranularHost.dproj" /t:Build /p:Config=%CFG% /p:Platform=%PLT% /v:minimal || exit /b 1
if /I not "%WHAT%"=="Host" msbuild "%~dp0GranularSynth.dproj" /t:Build /p:Config=%CFG% /p:Platform=%PLT% /v:minimal || exit /b 1
