@echo off
rem els launcher — runs the Tk els with the vendored Tcl/Tk 9.
"%~dp0.toolchain\tcl9\bin\wish90.exe" "%~dp0els.tcl" %*
