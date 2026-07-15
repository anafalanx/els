#!/usr/bin/env wish
# Entry point launched by cap.dll on a private, never-switched Win32 desktop.
set here [file dirname [file normalize [info script]]]
source [file join $here shot.tcl]
shot_private_entry $argv
