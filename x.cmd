@echo off
rem ============================================================================
rem  els ignition — the ONE non-Tcl tooling file.
rem
rem  Puts the vendored toolchain (relative to THIS script, so the project folder
rem  is copy-paste portable to any Windows 11+ machine) on PATH, then hands off
rem  to the Tcl task runner.  Everything else is Tcl (or C built by the vendored
rem  gcc).  Usage:  x <command> [args]   (run `x help`)
rem
rem  Double-clicking x.cmd in Explorer (or `x shell`) drops you into a shell with
rem  the toolchain on PATH, so you can run `x test`, gcc, tclsh, etc. directly.
rem ============================================================================
setlocal
set "ELS_ROOT=%~dp0"
set "TC=%ELS_ROOT%.toolchain"
rem Tcl/Tk 9 FIRST, ahead of msys64 (which ships its own Tcl/Tk 8.6 we must not
rem use).  Our tooling calls tclsh90.exe/wish90.exe explicitly anyway.
set "PATH=%TC%\tcl9\bin;%TC%\msys64\ucrt64\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"
set "MSYSTEM=UCRT64"

rem Open a shell when double-clicked (Explorer runs `cmd /c "...x.cmd"`, so the
rem script name appears in %cmdcmdline%) or when asked explicitly via `x shell`.
set "ELS_SHELL="
echo %cmdcmdline% | find /i "%~nx0" >nul 2>&1 && set "ELS_SHELL=1"
if /i "%~1"=="shell" set "ELS_SHELL=1"

if defined ELS_SHELL (
  if not exist "%TC%\tcl9\bin\tclsh90.exe" echo [els] Warning: toolchain not found at %TC%\tcl9
  echo.
  echo   els toolchain shell - the vendored toolchain is on PATH.
  echo   Try:  x help   x test   x colors     ^(or 'exit' to leave^)
  echo.
  cmd /k prompt els$G$S
  exit /b
)

if not exist "%TC%\tcl9\bin\tclsh90.exe" (
  echo [els] Tcl toolchain not found under %TC%\tcl9 - this folder is not provisioned.
  echo        Restore .toolchain\ ^(copy-paste^), or rebuild it, then run: x toolcheck
  exit /b 1
)
"%TC%\tcl9\bin\tclsh90.exe" "%ELS_ROOT%tools\x.tcl" %*
exit /b %errorlevel%
