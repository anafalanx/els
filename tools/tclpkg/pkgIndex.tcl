if {![package vsatisfies [package provide Tcl] 9.0]} return

set root [file dirname [file dirname $dir]]
set tc [file join $root .toolchain]
set dll [file join $tc tcl9 bin tcl9tk90.dll]
if {![file exists $dll]} return

package ifneeded tk 9.0.3 [list load $dll]
package ifneeded Tk 9.0.3 [list package require -exact tk 9.0.3]
