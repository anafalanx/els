# tests/run.tcl — run the whole els test suite in one process.
#   z test [--fast]
# --fast skips the slow ~800-op encoding stress test (stress-1.1).
# Exits non-zero if any test fails.

set script [info script]
if {[file pathtype $script] ne "absolute"} { set script [file join [pwd] $script] }
set here [file dirname $script]
cd [file dirname $here]

# Parse and strip our own flags from argv BEFORE tcltest (loaded via helpers)
# can object to an unknown option; remaining args still reach tcltest.
set fast 0 ; set keep {}
foreach a $argv { if {$a eq "--fast"} { set fast 1 } else { lappend keep $a } }
set argv $keep

set suiteRc [catch {
    source [file join $here helpers.tcl]
    # `stress` constraint gates the slow encoding stress test: ON by default,
    # OFF under --fast (tcltest then reports it Skipped rather than running it).
    ::tcltest::testConstraint stress [expr {!$fast}]

    foreach f [lsort [glob -nocomplain [file join $here *.test]]] {
        source $f
    }
} suiteError suiteOpts]

set failed 0
if {[info exists ::tcltest::numTests(Failed)]} {
    set failed $::tcltest::numTests(Failed)
}

# With Tk loaded, cleanupTests may call bare `exit` unless its `interactive`
# constraint is true.  That used to terminate this runner with status 0 before
# the explicit failed-test exit below.  Keep cleanup and its summary, but make
# this driver the sole owner of the process status.  A cleanup error also fails.
set cleanupRc 0
set cleanupError ""
set cleanupOpts {}
if {[llength [info commands ::tcltest::cleanupTests]]} {
    catch {::tcltest::testConstraint interactive 1}
    set cleanupRc [catch {::tcltest::cleanupTests} cleanupError cleanupOpts]
}

if {$suiteRc} {
    puts stderr "test suite evaluation aborted: $suiteError"
    if {[dict exists $suiteOpts -errorinfo]} { puts stderr [dict get $suiteOpts -errorinfo] }
    exit 1
}
if {$cleanupRc} {
    puts stderr "test suite cleanup aborted: $cleanupError"
    if {[dict exists $cleanupOpts -errorinfo]} { puts stderr [dict get $cleanupOpts -errorinfo] }
    exit 1
}
exit [expr {$failed > 0 ? 1 : 0}]
