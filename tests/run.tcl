# tests/run.tcl — run the whole els test suite in one process.
#   .toolchain/tcl9/bin/tclsh90.exe tests/run.tcl
# Exits non-zero if any test fails.

set script [info script]
if {[file pathtype $script] ne "absolute"} { set script [file join [pwd] $script] }
set here [file dirname $script]
cd [file dirname $here]
source [file join $here helpers.tcl]

foreach f [lsort [glob -nocomplain [file join $here *.test]]] {
    source $f
}

set failed $::tcltest::numTests(Failed)
tcltest::cleanupTests
exit [expr {$failed > 0 ? 1 : 0}]
