#!/usr/bin/env tclsh
# tools/native_check.tcl -- fail-closed load check for every release/test DLL.

proc fail {msg} { puts stderr "native check failed: $msg"; exit 1 }
set dir [lindex $argv 0]
if {$dir eq ""} { fail "usage: native_check.tcl build-directory" }
set dir [file normalize $dir]

foreach {file init commands} {
    elsx.dll   Elsx    {::elsx::hello ::elsx::sum}
    icudet.dll Icudet  {::elsdet::detect}
    winfs.dll  Winfs   {::els::win_replace_file ::els::win_open_folder ::els::win_fsync ::els::win_drive_type ::els::win_virtual_screen ::els::win_worker_spawn_watch ::els::win_worker_watch ::els::win_worker_status ::els::win_worker_kill ::els::win_path_reparse}
    windrop.dll Windrop {::els::win_drop_register}
} {
    set path [file join $dir $file]
    if {![file isfile $path]} { fail "required component is missing: $path" }
    if {[catch {load $path $init} err opts]} {
        fail "cannot load $file: $err"
    }
    foreach command $commands {
        if {![llength [info commands $command]]} { fail "$file did not register $command" }
    }
}
if {[elsx::sum 20 22] != 42} { fail "elsx smoke result was not 42" }
if {[package require icudet] ne "0.1"} { fail "icudet package version is not 0.1" }
if {[package require winfs] ne "0.1"} { fail "winfs package version is not 0.1" }
puts "native check ok: elsx, icudet, winfs and windrop loaded"
