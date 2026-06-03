@echo off
rem ============================================================================
rem  els ignition — the ONE non-Tcl tooling file.
rem
rem  Puts the vendored toolchain (relative to THIS script, so the project folder
rem  is copy-paste portable to any Windows 11+ machine) on PATH, then hands off
rem  to the Tcl task runner.  Everything else is Tcl (or C built by the vendored
rem  gcc).  Usage:  x <command> [args]   (run `x help`)
rem ============================================================================
setlocal
set "ELS_ROOT=%~dp0"
set "TC=%ELS_ROOT%.toolchain"
set "PATH=%TC%\msys64\ucrt64\bin;%TC%\tcl9\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"
set "MSYSTEM=UCRT64"
"%TC%\tcl9\bin\tclsh90.exe" "%ELS_ROOT%tools\x.tcl" %*
exit /b %errorlevel%
