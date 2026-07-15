#!/usr/bin/env tclsh
# Headless process regression for els_main.c's fail-closed AppInit path.
# The input executable must be a packaged build compiled with
# ELS_TEST_INIT_FAILURE; that compile-only surface writes one UTF-16 report and
# never displays a MessageBox.

proc fail {msg} { puts stderr "native startup check failed: $msg"; exit 1 }

set exe [lindex $argv 0]
if {$exe eq "" || [llength $argv] != 1} {
    fail "usage: native_startup_check.tcl path-to-packaged-initfail.exe"
}
set exe [file normalize $exe]
if {![file isfile $exe]} { fail "test executable is missing: $exe" }

proc env_save {names} {
    set saved {}
    foreach name $names {
        if {[info exists ::env($name)]} {
            dict set saved $name [list 1 $::env($name)]
        } else {
            dict set saved $name [list 0 ""]
        }
    }
    return $saved
}
proc env_restore {saved} {
    dict for {name state} $saved {
        lassign $state had value
        if {$had} { set ::env($name) $value } else { unset -nocomplain ::env($name) }
    }
}
proc read_binary {path} {
    set f [open $path rb]
    try { return [read $f] } finally { close $f }
}

# Tcl's Windows pipeline layer detaches GUI-subsystem executables and therefore
# cannot report their real exit status.  Start-Process retains a process handle,
# waits with a finite timeout, and propagates the exact native exit code.
proc run_with_timeout {exe timeoutMs} {
    set winroot ""
    foreach name {SystemRoot WINDIR} {
        if {[info exists ::env($name)] && $::env($name) ne ""} {
            set winroot $::env($name)
            break
        }
    }
    set powershell [file join $winroot System32 WindowsPowerShell v1.0 powershell.exe]
    if {$winroot eq "" || ![file executable $powershell]} {
        error "cannot locate the Windows PowerShell process-wait helper"
    }
    set waitScript {
        $ErrorActionPreference = 'Stop'
        $p = Start-Process -FilePath $env:ELS_TEST_WAIT_EXE -PassThru
        if (-not $p.WaitForExit([int]$env:ELS_TEST_WAIT_MS)) {
            try { $p.Kill() } catch {}
            try { $p.WaitForExit() } catch {}
            exit 124
        }
        exit $p.ExitCode
    }
    set saved [env_save {ELS_TEST_WAIT_EXE ELS_TEST_WAIT_MS}]
    try {
        set ::env(ELS_TEST_WAIT_EXE) $exe
        set ::env(ELS_TEST_WAIT_MS) $timeoutMs
        set rc [catch {
            exec $powershell -NoLogo -NoProfile -NonInteractive \
                -ExecutionPolicy Bypass -Command $waitScript
        } msg opts]
    } finally {
        env_restore $saved
    }
    return [list $rc $msg $opts]
}

set work [file join [file dirname $exe] \
    "initfail-Jos\u00E9-\u4F60\u597D-\U0001F600-[pid]-[clock clicks]"]
set report [file join $work failure-utf16.txt]
set continued [file join $work main-continued.txt]
set envNames {APPDATA LOCALAPPDATA ELS_TEST_INIT_REPORT ELS_STARTUP_PROBE}
set saved [env_save $envNames]

if {[file exists $work]} { fail "unique native startup-check directory already exists: $work" }
file mkdir $work
set outcome {}
try {
    set ::env(APPDATA) [file join $work appdata]
    set ::env(LOCALAPPDATA) [file join $work localappdata]
    set ::env(ELS_TEST_INIT_REPORT) $report
    # Production main.tcl writes this probe.  Its absence proves AppInit did not
    # return to Tk_Main and source the startup script after reporting failure.
    set ::env(ELS_STARTUP_PROBE) $continued
    set outcome [run_with_timeout $exe 5000]
} finally {
    env_restore $saved
}

lassign $outcome rc msg opts
if {!$rc} { fail "test process returned exit code 0" }
set ec [dict get $opts -errorcode]
if {[lindex $ec 0] ne "CHILDSTATUS" || [lindex $ec 2] == 0} {
    fail "test process did not report a nonzero child exit: $ec ($msg)"
}
if {[lindex $ec 2] == 124} { fail "test process did not exit within 5000 ms" }
if {![file isfile $report]} { fail "UTF-16 failure report was not created" }
if {[file exists $continued]} { fail "main.tcl continued after AppInit failure" }

set bytes [read_binary $report]
if {[string length $bytes] < 4 || [binary encode hex [string range $bytes 0 1]] ne "fffe"} {
    fail "failure report is not BOM-marked UTF-16LE"
}
set text [encoding convertfrom unicode [string range $bytes 2 end]]
foreach expected {
    {test-only initialization}
    {injected diagnostic}
    {Jos\u00E9}
    {\u4F60\u597D}
    {\U0001F600}
} {
    if {[string first [subst -nocommands -novariables $expected] $text] < 0} {
        fail "UTF-16 report omitted expected text: $expected (got: $text)"
    }
}

catch {file delete -force -- $work}
puts "native startup check ok (exit=[lindex $ec 2], one UTF-16 report, main.tcl not sourced)"
