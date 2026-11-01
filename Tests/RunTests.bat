@echo off
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------------------
rem  Builds and runs the RaceBox protocol tests, then builds (does not run)
rem  the RaceBox Reader demo so the Bluetooth unit is compiled too.
rem  No RaceBox device needed.
rem
rem  Override the compiler location if it is not found:
rem     set BDS=C:\Program Files (x86)\Embarcadero\Studio\23.0
rem ---------------------------------------------------------------------------

set "TESTDIR=%~dp0"
set "TESTDIR=%TESTDIR:~0,-1%"
set "RB=%TESTDIR%\.."
set "OUT=%TESTDIR%\Win32"

if defined BDS (
  set "DCC=%BDS%\bin\dcc32.exe"
) else (
  for %%V in (37.0 23.0 22.0) do (
    if not defined DCC (
      if exist "%ProgramFiles(x86)%\Embarcadero\Studio\%%V\bin\dcc32.exe" (
        set "DCC=%ProgramFiles(x86)%\Embarcadero\Studio\%%V\bin\dcc32.exe"
        set "BDS=%ProgramFiles(x86)%\Embarcadero\Studio\%%V"
      )
    )
  )
)

if not exist "%DCC%" (
  echo ERROR: could not find dcc32.exe. Set BDS to your Delphi install.
  exit /b 2
)

if not exist "%OUT%" mkdir "%OUT%"
set "FLAGS=-Q -B --no-config -NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Data;Xml -U"%BDS%\lib\win32\release" -U"%RB%\Source" -I"%BDS%\lib\win32\release" -N"%OUT%" -E"%OUT%""
set FAILED=0

echo === RaceBoxProtocolTest ===
"%DCC%" %FLAGS% "%TESTDIR%\RaceBoxProtocolTest.dpr" > "%OUT%\RaceBoxProtocolTest.build.log" 2>&1
if errorlevel 1 (
  echo BUILD FAILED - see %OUT%\RaceBoxProtocolTest.build.log
  findstr /I /C:"Error" /C:"Fatal" "%OUT%\RaceBoxProtocolTest.build.log"
  set /a FAILED+=1
) else (
  "%OUT%\RaceBoxProtocolTest.exe"
  if errorlevel 1 set /a FAILED+=1
)
echo.

echo === RaceBoxReader demo (build only) ===
pushd "%RB%\Demo"
"%DCC%" %FLAGS% RaceBoxReader.dpr > "%OUT%\RaceBoxReader.build.log" 2>&1
if errorlevel 1 (
  echo BUILD FAILED - see %OUT%\RaceBoxReader.build.log
  findstr /I /C:"Error" /C:"Fatal" "%OUT%\RaceBoxReader.build.log"
  set /a FAILED+=1
) else (
  echo   ok   demo and RaceBox.BLE compiled
)
popd
echo.

if %FAILED%==0 (
  echo RACEBOX TESTS PASSED
  exit /b 0
) else (
  echo %FAILED% RACEBOX STEP^(S^) FAILED
  exit /b 1
)
