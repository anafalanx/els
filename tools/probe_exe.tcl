# tools/probe_exe.tcl -- process-level smoke tests for the fused els.exe.
#
# Usage: tclsh90.exe tools/probe_exe.tcl path/to/els.exe

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set SRC [lindex $argv 0]
if {$SRC eq ""} { set SRC [file join $ROOT els.exe] }
if {![file exists $SRC]} { error "exe not found: $SRC" }

set BASE [file join $ROOT tests _tmp exeprobe]

proc write_file {path bytes} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -translation binary
    puts -nonewline $f $bytes
    close $f
    return $path
}

proc wait_report {report pid} {
    set deadline [expr {[clock milliseconds] + 6000}]
    while {[clock milliseconds] < $deadline} {
        if {[file exists $report]} {
            set f [open $report r]
            set data [read $f]
            close $f
            return $data
        }
        after 50
    }
    catch {exec taskkill /PID [lindex $pid 0] /T /F}
    error "exe probe did not finish: $report"
}

proc run_probe {name src {conf ""} {files {}} {args {}}} {
    set app [file join $::BASE $name]
    catch {file delete -force $app}
    file mkdir $app
    file copy -force $src [file join $app els.exe]
    if {$conf ne ""} { write_file [file join $app els.conf] $conf }
    foreach {tail bytes} $files {
        write_file [file join $app $tail] $bytes
    }
    set report [file join $app report.txt]

    set saved {}
    foreach v {APPDATA LOCALAPPDATA ELS_STARTUP_PROBE} {
        if {[info exists ::env($v)]} {
            dict set saved $v [list 1 $::env($v)]
        } else {
            dict set saved $v [list 0 ""]
        }
    }
    set ::env(APPDATA) [file join $app appdata]
    set ::env(LOCALAPPDATA) [file join $app localappdata]
    set ::env(ELS_STARTUP_PROBE) $report
    set pid [exec [file join $app els.exe] {*}$args &]
    foreach v {APPDATA LOCALAPPDATA ELS_STARTUP_PROBE} {
        lassign [dict get $saved $v] had val
        if {$had} { set ::env($v) $val } else { unset ::env($v) }
    }

    return [wait_report $report $pid]
}

file mkdir $BASE

set first [run_probe first $SRC]
if {[dict get $first mapped] != 1 || [dict get $first cfgask] != 1 ||
    [dict get $first cfgask_mapped] != 1 ||
    [dict get $first config] ne ""} {
    error "first-run probe failed: $first"
}

set app2 [file join $BASE restore]
set p1 [file normalize [file join $app2 one.txt]]
set p2 [file normalize [file join $app2 two.txt]]
set miss [file normalize [file join $app2 missing.txt]]
set conf [dict create geometry 800x600 recent {} word_wrap 0 \
    restore_session 1 session_files [list $p1 $miss $p2] session_active $p2]
set restore [run_probe restore $SRC $conf [list one.txt "one\n" two.txt "two\n"]]
if {[dict get $restore cfgask] != 0 ||
    [dict get $restore docs] != 2 ||
    [file tail [dict get $restore active_path]] ne "two.txt"} {
    error "restore probe failed: $restore"
}

set app3 [file join $BASE explicit]
set previous [file normalize [file join $app3 previous.txt]]
set explicit [file normalize [file join $app3 explicit.txt]]
set conf [dict create geometry 800x600 recent {} word_wrap 0 \
    restore_session 1 session_files [list $previous] session_active $previous]
set explicitRun [run_probe explicit $SRC $conf \
    [list previous.txt "previous\n" explicit.txt "explicit\n"] [list $explicit]]
if {[dict get $explicitRun cfgask] != 0 ||
    [dict get $explicitRun docs] != 1 ||
    [file tail [dict get $explicitRun active_path]] ne "explicit.txt"} {
    error "explicit-arg probe failed: $explicitRun"
}

puts "exe probe ok"
