@echo off
rem ============================================================================
rem  els bootstrap — provision .toolchain on a fresh checkout (NO Tcl needed yet).
rem
rem  The normal distribution model is copy-paste of the whole folder (which
rem  carries .toolchain).  This is for the `git clone` case, where .toolchain is
rem  absent: it downloads a pre-built toolchain bundle with PowerShell (always on
rem  Windows 11), unpacks it, then hands off to `x toolcheck`.
rem
rem  Set ELS_TOOLCHAIN_URL to a .zip of the .toolchain tree (host it as a release
rem  asset).  Without it, this prints what to do.
rem ============================================================================
setlocal
set "ELS_ROOT=%~dp0"

if exist "%ELS_ROOT%.toolchain\tcl9\bin\tclsh90.exe" (
  echo Toolchain already present. Verifying...
  call "%ELS_ROOT%x.cmd" toolcheck
  exit /b %errorlevel%
)

if "%ELS_TOOLCHAIN_URL%"=="" (
  echo No .toolchain found, and ELS_TOOLCHAIN_URL is not set.
  echo.
  echo   - Easiest: copy-paste a folder that already has .toolchain\ into place.
  echo   - Or: set ELS_TOOLCHAIN_URL to a toolchain-bundle .zip, then re-run:
  echo         set ELS_TOOLCHAIN_URL=https://.../els-toolchain.zip
  echo         bootstrap
  exit /b 1
)

echo Downloading toolchain bundle from %ELS_TOOLCHAIN_URL% ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "Invoke-WebRequest -Uri $env:ELS_TOOLCHAIN_URL -OutFile '%ELS_ROOT%toolchain.zip';" ^
  "Expand-Archive -Force '%ELS_ROOT%toolchain.zip' '%ELS_ROOT%';" ^
  "Remove-Item '%ELS_ROOT%toolchain.zip'"
if errorlevel 1 (
  echo Download/unpack failed.
  exit /b 1
)

echo Toolchain unpacked. Verifying...
call "%ELS_ROOT%x.cmd" toolcheck --prep
exit /b %errorlevel%
