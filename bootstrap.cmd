@echo off
rem ============================================================================
rem  els bootstrap — provision .toolchain on a fresh checkout (NO Tcl yet).
rem
rem  Classical Windows cmd ONLY — uses the built-in curl.exe + tar.exe that ship
rem  in System32 on Windows 10 1803+ / Windows 11.  No PowerShell, no bash.
rem
rem  The normal distribution model is copy-paste of the whole folder (which
rem  carries .toolchain).  This is for the `git clone` case, where .toolchain is
rem  absent: it downloads a pre-built toolchain bundle and unpacks it, then hands
rem  off to `x toolcheck`.  Set ELS_TOOLCHAIN_URL to a .zip of the toolchain
rem  tree (host it as a release asset); without it, this prints what to do.
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
curl.exe -L --fail -o "%ELS_ROOT%toolchain.zip" "%ELS_TOOLCHAIN_URL%"
if errorlevel 1 ( echo Download failed. & exit /b 1 )

echo Extracting ...
tar.exe -xf "%ELS_ROOT%toolchain.zip" -C "%ELS_ROOT%"
if errorlevel 1 ( echo Extract failed. & exit /b 1 )
del "%ELS_ROOT%toolchain.zip"

echo Toolchain unpacked. Verifying...
call "%ELS_ROOT%x.cmd" toolcheck --prep
exit /b %errorlevel%
