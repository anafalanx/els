#!/usr/bin/env wish
# tools/icon.tcl — generate the els app icon (the awl) to resources/icon.png.
#
# Pure Tcl/Tk: analytic signed-distance-field rendering into a photo image, with
# per-pixel alpha for anti-aliased edges and transparent rounded corners (Tk's
# canvas isn't anti-aliased, so we rasterize ourselves).  `x icon [size]`.
#
# The awl: a dark rounded tile, a pale capsule handle, a ferrule band, and a
# sharp blade — the blade is the one accent colour (firebrick2 red).
package require Tk
wm withdraw .

set S [expr {[lindex $argv 0] ne "" ? [lindex $argv 0] : 256}]
set out [lindex $argv 1]
if {$out eq ""} {
    set out [file normalize [file join [file dirname [info script]] .. resources icon.png]]
}
set k [expr {$S/256.0}]

# palette (0-255 rgb)
set TILE   {29 32 39}     ;# #1D2027  dark slate tile
set HANDLE {223 226 233}  ;# #DFE2E9  pale handle
set FERR   {150 170 198}  ;# #96AAC6  ferrule band
set BLADE  {238 44 44}    ;# #EE2C2C  firebrick2 — the accent

# ---- SDF helpers (coordinates in actual pixels) -------------------------
proc cl01 {x} { expr {$x<0.0?0.0:($x>1.0?1.0:$x)} }
proc cov  {d} { expr {$d<-0.5?1.0:($d>0.5?0.0:0.5-$d)} }   ;# ~1px AA coverage

proc sdRound {px py cx cy hw hh r} {
    set qx [expr {abs($px-$cx)-$hw+$r}] ; set qy [expr {abs($py-$cy)-$hh+$r}]
    set mx [expr {$qx>$qy?$qx:$qy}]
    expr {hypot(($qx<0?0:$qx),($qy<0?0:$qy)) + ($mx<0?$mx:0.0) - $r}
}
proc sdCapsule {px py ax ay bx by r} {
    set pax [expr {$px-$ax}] ; set pay [expr {$py-$ay}]
    set bax [expr {$bx-$ax}] ; set bay [expr {$by-$ay}]
    set h [cl01 [expr {($pax*$bax+$pay*$bay)/($bax*$bax+$bay*$bay)}]]
    expr {hypot($pax-$bax*$h,$pay-$bay*$h) - $r}
}
proc sdTri {px py ax ay bx by cx cy} {
    set e0x [expr {$bx-$ax}] ; set e0y [expr {$by-$ay}]
    set e1x [expr {$cx-$bx}] ; set e1y [expr {$cy-$by}]
    set e2x [expr {$ax-$cx}] ; set e2y [expr {$ay-$cy}]
    set v0x [expr {$px-$ax}] ; set v0y [expr {$py-$ay}]
    set v1x [expr {$px-$bx}] ; set v1y [expr {$py-$by}]
    set v2x [expr {$px-$cx}] ; set v2y [expr {$py-$cy}]
    set t0 [cl01 [expr {($v0x*$e0x+$v0y*$e0y)/($e0x*$e0x+$e0y*$e0y)}]]
    set t1 [cl01 [expr {($v1x*$e1x+$v1y*$e1y)/($e1x*$e1x+$e1y*$e1y)}]]
    set t2 [cl01 [expr {($v2x*$e2x+$v2y*$e2y)/($e2x*$e2x+$e2y*$e2y)}]]
    set d0x [expr {$v0x-$e0x*$t0}] ; set d0y [expr {$v0y-$e0y*$t0}]
    set d1x [expr {$v1x-$e1x*$t1}] ; set d1y [expr {$v1y-$e1y*$t1}]
    set d2x [expr {$v2x-$e2x*$t2}] ; set d2y [expr {$v2y-$e2y*$t2}]
    set s [expr {$e0x*$e2y-$e0y*$e2x > 0 ? 1.0 : -1.0}]
    set dd0 [expr {$d0x*$d0x+$d0y*$d0y}] ; set sg0 [expr {$s*($v0x*$e0y-$v0y*$e0x)}]
    set dd1 [expr {$d1x*$d1x+$d1y*$d1y}] ; set sg1 [expr {$s*($v1x*$e1y-$v1y*$e1x)}]
    set dd2 [expr {$d2x*$d2x+$d2y*$d2y}] ; set sg2 [expr {$s*($v2x*$e2y-$v2y*$e2x)}]
    set dx [expr {min($dd0,$dd1,$dd2)}]
    set dy [expr {min($sg0,$sg1,$sg2)}]
    expr {-sqrt($dx)*($dy<0?-1.0:1.0)}
}

# ---- render -------------------------------------------------------------
proc G {v} { expr {$v*$::k} }
set img [image create photo -width $S -height $S]
lassign $TILE tR tG tB ; lassign $HANDLE hR hG hB
lassign $FERR fR fG fB ; lassign $BLADE bR bG bB

set t0 [clock milliseconds]
set data {}
for {set y 0} {$y < $S} {incr y} {
    set py [expr {$y+0.5}]
    set row {}
    for {set x 0} {$x < $S} {incr x} {
        set px [expr {$x+0.5}]
        set a [cov [sdRound $px $py [G 128] [G 128] [G 110] [G 110] [G 40]]]
        if {$a <= 0.002} { lappend row "#00000000" ; continue }
        set R $tR ; set G_ $tG ; set B $tB
        foreach {col seg} [list \
                [list $hR $hG $hB] [list capsule [G 128] [G 58] [G 128] [G 92] [G 21]] \
                [list $bR $bG $bB] [list tri [G 104] [G 124] [G 152] [G 124] [G 128] [G 230]] \
                [list $fR $fG $fB] [list round [G 128] [G 120] [G 29] [G 9] [G 4]]] {
            switch [lindex $seg 0] {
                capsule { set d [sdCapsule $px $py {*}[lrange $seg 1 end]] }
                tri     { set d [sdTri     $px $py {*}[lrange $seg 1 end]] }
                round   { set d [sdRound   $px $py {*}[lrange $seg 1 end]] }
            }
            set c [cov $d] ; set ic [expr {1.0-$c}]
            lassign $col cr cg cb
            set R  [expr {$cr*$c+$R*$ic}]
            set G_ [expr {$cg*$c+$G_*$ic}]
            set B  [expr {$cb*$c+$B*$ic}]
        }
        lappend row [format "#%02X%02X%02X%02X" \
            [expr {round($R)}] [expr {round($G_)}] [expr {round($B)}] [expr {round($a*255)}]]
    }
    lappend data $row
}
$img put $data
file mkdir [file dirname $out]
$img write $out -format png
puts "wrote $out (${S}x${S}, [expr {[clock milliseconds]-$t0}] ms)"
exit
