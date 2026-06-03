#!/usr/bin/env wish
# tools/colors.tcl — browse every named color Tk knows, with its #RRGGBB.
# A scrollable swatch grid with a live filter box.  Run via `x colors`.
#
# The base names are Tk's built-in set (extracted from its xcolors.c table);
# numbered shades (name1..4) and gray/grey 0..100 are generated, and anything Tk
# doesn't actually recognize is filtered out by winfo rgb.
package require Tk

set BASE {
    aliceBlue antiqueWhite aqua aquamarine azure beige bisque black
    blanchedAlmond blue blueViolet brown burlywood cadetBlue chartreuse
    chocolate coral cornflowerBlue cornsilk crimson cyan darkBlue darkCyan
    darkGoldenrod darkGray darkGreen darkGrey darkKhaki darkMagenta
    darkOliveGreen darkOrange darkOrchid darkRed darkSalmon darkSeaGreen
    darkSlateBlue darkSlateGray darkSlateGrey darkTurquoise darkViolet deepPink
    deepSkyBlue dimGray dimGrey dodgerBlue firebrick floralWhite forestGreen
    fuchsia gainsboro ghostWhite gold goldenrod gray green greenYellow grey
    honeydew hotPink indianRed indigo ivory khaki lavender lavenderBlush
    lawnGreen lemonChiffon lightBlue lightCoral lightCyan lightGoldenrod
    lightGoldenrodYellow lightGray lightGreen lightGrey lightPink lightSalmon
    lightSeaGreen lightSkyBlue lightSlateBlue lightSlateGray lightSlateGrey
    lightSteelBlue lightYellow lime limeGreen linen magenta maroon
    mediumAquamarine mediumBlue mediumOrchid mediumPurple mediumSeaGreen
    mediumSlateBlue mediumSpringGreen mediumTurquoise mediumVioletRed
    midnightBlue mintCream mistyRose moccasin navajoWhite navy navyBlue oldLace
    olive oliveDrab orange orangeRed orchid paleGoldenrod paleGreen
    paleTurquoise paleVioletRed papayaWhip peachPuff peru pink plum powderBlue
    purple red rosyBrown royalBlue saddleBrown salmon sandyBrown seaGreen
    seashell sienna silver skyBlue slateBlue slateGray slateGrey snow
    springGreen steelBlue tan teal thistle tomato turquoise violet violetRed
    wheat white whiteSmoke yellow yellowGreen
}

# Build the full candidate list: base + shades + grays, then keep what Tk knows.
set candidates {}
foreach c $BASE {
    lappend candidates $c
    foreach n {1 2 3 4} { lappend candidates $c$n }
}
for {set i 0} {$i <= 100} {incr i} { lappend candidates gray$i grey$i }

. configure -bg "#202020"
set HEX [dict create]
foreach name [lsort -unique -dictionary $candidates] {
    if {[catch {winfo rgb . $name} rgb]} { continue }
    lassign $rgb r g b
    dict set HEX $name [format "#%02X%02X%02X" [expr {$r/256}] [expr {$g/256}] [expr {$b/256}]]
}
set ALL [lsort -dictionary [dict keys $HEX]]

# ---- UI -----------------------------------------------------------------
wm title . "Tk named colors"
wm geometry . 1000x700
font create cName -family {Segoe UI} -size 9
font create cHex  -family Consolas    -size 8

frame .top -bg "#202020"
label .top.l -bg "#202020" -fg "#E6E6E6" -text "Filter:" -font {{Segoe UI} 10}
entry .top.e -textvariable ::filter -width 24
label .top.n -bg "#202020" -fg "#9AA0A6" -textvariable ::countlbl -font {{Segoe UI} 9}
pack .top.l -side left -padx {10 4} -pady 6
pack .top.e -side left -pady 6
pack .top.n -side right -padx 10
pack .top -side top -fill x

canvas .c -bg "#202020" -highlightthickness 0 -yscrollcommand {.vs set}
ttk::scrollbar .vs -orient vertical -command {.c yview}
pack .vs -side right -fill y
pack .c -side left -fill both -expand 1

set CW 168 ; set CH 74 ; set SWH 36 ; set PAD 12
proc redraw {} {
    global ALL HEX CW CH SWH PAD filter countlbl
    .c delete all
    set f [string tolower $filter]
    set shown {}
    foreach n $ALL { if {$f eq "" || [string match *$f* [string tolower $n]]} { lappend shown $n } }
    set countlbl "[llength $shown] of [llength $ALL] colors"
    set w [winfo width .c]
    set cols [expr {max(1, ($w - $PAD) / $CW)}]
    set i 0
    foreach n $shown {
        set col [expr {$i % $cols}] ; set row [expr {$i / $cols}]
        set x [expr {$PAD + $col*$CW}] ; set y [expr {$PAD + $row*$CH}]
        .c create rectangle $x $y [expr {$x+$CW-$PAD}] [expr {$y+$SWH}] \
            -fill [dict get $HEX $n] -outline "#000000"
        .c create text [expr {$x+($CW-$PAD)/2}] [expr {$y+$SWH+12}] \
            -text $n -fill "#E6E6E6" -font cName
        .c create text [expr {$x+($CW-$PAD)/2}] [expr {$y+$SWH+26}] \
            -text [dict get $HEX $n] -fill "#9AA0A6" -font cHex
        incr i
    }
    set rows [expr {($i + $cols - 1) / $cols}]
    .c configure -scrollregion [list 0 0 $w [expr {$PAD + $rows*$CH + $PAD}]]
}

proc schedule {} { catch {after cancel $::redraw_id} ; set ::redraw_id [after 80 redraw] }
bind .top.e <KeyRelease> schedule
bind .c <Configure> schedule
bind .c <MouseWheel> {.c yview scroll [expr {-%D/120}] units}
bind . <Escape> {set ::filter ""; redraw}
focus .top.e
after 60 redraw
