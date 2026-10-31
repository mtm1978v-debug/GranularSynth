@echo off
rem Baut Tools\Setup\Setup.exe (32 Bit, verlangt Administratorrechte, startet Install.ps1)
setlocal
set HERE=%~dp0
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" || exit /b 1
pushd "%HERE%"
brcc32 -fo"Setup.res" "Setup.rc" || (popd & exit /b 1)
dcc32 -B -Q -E"%HERE%." -N"%HERE%dcu" Setup.dpr || (popd & exit /b 1)
popd
echo Setup.exe gebaut.
