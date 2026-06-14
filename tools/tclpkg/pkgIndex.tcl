if {![package vsatisfies [package provide Tcl] 9.0]} return

set root [file dirname [file dirname $dir]]
set pinfile [file join $root toolchain.pin]
if {![file exists $pinfile]} return
set fh [open $pinfile r] ; set pin [string trim [read $fh]] ; close $fh
if {$pin eq ""} return
set d $root
set tc ""
for {set i 0} {$i < 8} {incr i} {
    set cand [file join $d X $pin]
    if {[file exists [file join $cand BUNDLE.manifest]]} { set tc $cand ; break }
    set up [file dirname $d]
    if {$up eq $d} break
    set d $up
}
if {$tc eq ""} return
set dll [file join $tc tcl9 bin tcl9tk90.dll]

package ifneeded tk 9.0.3 [list load $dll]
package ifneeded Tk 9.0.3 [list package require -exact tk 9.0.3]
