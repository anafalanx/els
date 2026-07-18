if {![package vsatisfies [package provide Tcl] 9.0]} return

# z's shared Tcl/Tk payload (Z_TCLTK, set by tools/tasks.tcl); the project-local
# .toolchain this used to probe was abolished in the hosted layout (pa-6).  Returns
# a no-op when unset, deferring to the payload's own Tk pkgIndex.
if {![info exists ::env(Z_TCLTK)] || $::env(Z_TCLTK) eq ""} return
set dll [file join $::env(Z_TCLTK) tcl9 bin tcl9tk90.dll]
if {![file exists $dll]} return

package ifneeded tk 9.0.4 [list load $dll]
package ifneeded Tk 9.0.4 [list package require -exact tk 9.0.4]
