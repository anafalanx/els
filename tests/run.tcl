# tests/run.tcl — run the whole els test suite in one process.
#   .toolchain/tcl9/bin/tclsh90.exe tests/run.tcl [--fast]
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

source [file join $here helpers.tcl]
# `stress` constraint gates the slow encoding stress test: ON by default, OFF
# under --fast (tcltest then reports it Skipped rather than running it).
::tcltest::testConstraint stress [expr {!$fast}]

foreach f [lsort [glob -nocomplain [file join $here *.test]]] {
    source $f
}

set failed $::tcltest::numTests(Failed)
tcltest::cleanupTests
exit [expr {$failed > 0 ? 1 : 0}]
