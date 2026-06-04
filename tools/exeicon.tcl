#!/usr/bin/env tclsh
# tools/exeicon.tcl — bake the awl into an .exe as its PE icon, so Explorer and
# the taskbar show it for the file itself.  (The runtime *window* icon is set
# separately by els.tcl via `wm iconphoto` from the embedded resources/icon.png;
# this is the icon compiled into the binary's resource section.)
#
#   tclsh90.exe tools/exeicon.tcl <exe>
#
# Renders the awl at several sizes with icon.tcl and writes RT_GROUP_ICON +
# RT_ICON resources via twapi's UpdateResource.  Skips cleanly if twapi is
# unavailable, so a build still succeeds without it.
proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set TC   [file join $ROOT .toolchain]
lappend auto_path [file join $TC twapi-dl]

set exe [lindex $argv 0]
if {$exe eq "" || ![file exists $exe]} { puts stderr "usage: exeicon.tcl <exe>" ; exit 2 }

# SAFETY: editing PE resources rewrites the executable and DROPS any data
# appended after the PE image — which for a finished single-exe is the whole
# zipfs payload (tcl_library/tk_library/main.tcl).  So refuse to touch a packaged
# app (main.tcl at the zip root); the icon must go into the WRAPPER before mkimg.
if {![catch {zipfs mount $exe _exeicon_chk}]} {
    set packaged [file exists //zipfs:/_exeicon_chk/main.tcl]
    catch {zipfs unmount _exeicon_chk}
    if {$packaged} {
        puts stderr "exeicon: refusing to edit a packaged single-exe (would strip its zipfs payload).\n  Icon the wrapper before `zipfs mkimg`."
        exit 3
    }
}

if {[catch {package require twapi} e]} {
    puts stderr "twapi unavailable ($e) — PE icon skipped" ; exit 0
}

set wish [file join $TC tcl9 bin wish90.exe]
set gen  [file join $ROOT tools icon.tcl]
set sizes {256 128 64 48 32 16}
set RT_ICON 3 ; set RT_GROUP_ICON 14 ; set LANG 1033

# render each size and read its PNG bytes
set tmp [file join $TC _exeicon] ; file delete -force $tmp ; file mkdir $tmp
set imgs {} ; set id 101
foreach s $sizes {
    set p [file join $tmp i$s.png]
    exec $wish $gen $s $p
    set fh [open $p rb] ; set png [read $fh] ; close $fh
    lappend imgs [list $s $png $id] ; incr id
}

# GRPICONDIR: header (reserved,type=1,count) + a 14-byte entry per image
set dir [binary format sss 0 1 [llength $imgs]]
foreach e $imgs {
    lassign $e s png id
    set wh [expr {$s >= 256 ? 0 : $s}]   ;# 0 means 256 in the icon directory
    append dir [binary format ccccssis $wh $wh 0 0 1 32 [string length $png] $id]
}

set h [twapi::begin_resource_update $exe]
foreach e $imgs {
    lassign $e s png id
    twapi::update_resource $h $RT_ICON $id $LANG $png
}
# replace the wrapper's group icons (named APP and TK) so Explorer shows ours
foreach grp {APP TK} {
    twapi::update_resource $h $RT_GROUP_ICON $grp $LANG $dir
}
twapi::end_resource_update $h
file delete -force $tmp
puts "embedded PE icon ([join $sizes ,]px) into [file tail $exe]"
exit 0
