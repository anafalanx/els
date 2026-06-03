#!/usr/bin/env wish
# els — a tiny, scriptable text editor.  Tcl/Tk 9 edition.
#
# This is the rewrite of the C23/Lua els (which shipped through v0.3, archived
# in ../els-c).  Tk's Text widget is the buffer; Tcl is the scripting language.
# Design language carried over from v0.3: calm grey page, the signature red
# caret, restrained chrome, opinionated (few knobs).

package require Tk

namespace eval els {
    variable version "0.4-dev"   ;# Tk edition; the C line ended at 0.3
    variable path ""             ;# current file ("" = untitled)
    variable dirty 0
    variable iconImage ""
    variable iconPath ""
    variable iconLoaded 0
    variable selftest [expr {[lindex $::argv 0] eq "--selftest"}]
}

# ---- look: the els visual identity --------------------------------------
set ::els::PAGE  "#F2F2F2"       ;# calm grey page (not pure white)
set ::els::INK   "#1A1A1A"
set ::els::CARET "#DC2626"       ;# the signature red caret
set ::els::LINE  "#E8E8E8"
set ::els::GUTTER "#E2E2E2"
set ::els::MUTED "#666666"
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsUI   -family {Segoe UI} -size 9

# ---- app resources / preferences ---------------------------------------
proc els::find_resource {args} {
    set rel [file join {*}$args]
    foreach base [list [file dirname [info script]] [pwd]] {
        set p [file normalize [file join $base $rel]]
        if {[file exists $p]} { return $p }
    }
    return ""
}
proc els::load_icon {} {
    set p [els::find_resource resources icon.png]
    if {$p eq ""} { return }
    if {[catch {image create photo elsIcon -file $p} img]} { return }
    set ::els::iconImage $img
    set ::els::iconPath $p
    set ::els::iconLoaded 1
    wm iconphoto . -default $img
}
proc els::config_file {} {
    if {[info exists ::env(APPDATA)] && $::env(APPDATA) ne ""} {
        set base [file join $::env(APPDATA) els]
    } elseif {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
        set base [file join $::env(XDG_CONFIG_HOME) els]
    } else {
        set base [file join [file normalize ~] .config els]
    }
    return [file join $base config.tcl]
}
proc els::load_geometry {} {
    set f [els::config_file]
    if {![file exists $f]} { return }
    if {[catch {
        set fh [::open $f r]
        set data [read $fh]
        close $fh
        set g [dict get $data geometry]
    }]} { return }
    if {[regexp {^[0-9]+x[0-9]+([+-][0-9]+){0,2}$} $g]} {
        wm geometry . $g
    }
}
proc els::save_geometry {} {
    if {$::els::selftest} { return }
    if {[catch {
        set f [els::config_file]
        file mkdir [file dirname $f]
        set fh [::open $f w]
        puts $fh [dict create geometry [wm geometry .]]
        close $fh
    }]} { return }
}

# ---- build the UI -------------------------------------------------------
proc els::build {} {
    wm title . "els"
    wm geometry . 900x620
    els::load_icon
    els::load_geometry
    wm minsize . 360 240
    wm protocol . WM_DELETE_WINDOW els::quit

    menu .menu
    . configure -menu .menu
    menu .menu.file
    .menu add cascade -label File -menu .menu.file
    .menu.file add command -label New        -accelerator Ctrl+N -command els::new
    .menu.file add command -label Open...     -accelerator Ctrl+O -command els::open
    .menu.file add command -label Save        -accelerator Ctrl+S -command els::save
    .menu.file add command -label "Save As..."                    -command els::saveas
    .menu.file add separator
    .menu.file add command -label Exit        -accelerator Ctrl+Q -command els::quit
    menu .menu.help
    .menu add cascade -label Help -menu .menu.help
    .menu.help add command -label "About els" -command els::about

    text .t -undo 1 -wrap none -font elsMono \
        -bg $::els::PAGE -fg $::els::INK \
        -insertbackground $::els::CARET -insertwidth 2 \
        -borderwidth 0 -highlightthickness 0 -padx 6 -pady 4 \
        -tabstyle wordprocessor -yscrollcommand {els::yscroll}
    .t tag configure currentLine -background $::els::LINE
    .t tag lower currentLine

    text .ln -width 4 -wrap none -font elsMono \
        -bg $::els::GUTTER -fg $::els::MUTED \
        -borderwidth 0 -highlightthickness 0 -padx 5 -pady 4 \
        -takefocus 0 -cursor arrow -insertwidth 0 -state disabled
    .ln tag configure currentLine -background $::els::LINE

    ttk::scrollbar .vs -orient vertical -command {els::scroll}

    ttk::frame .sb
    ttk::label .sb.pos  -font elsUI -anchor w -text "Ln 1, Col 1"
    ttk::label .sb.name -font elsUI -anchor e -text "untitled"
    pack .sb.pos  -side left  -padx 8 -pady 2
    pack .sb.name -side right -padx 8 -pady 2

    grid .ln -row 0 -column 0 -sticky ns
    grid .t  -row 0 -column 1 -sticky nsew
    grid .vs -row 0 -column 2 -sticky ns
    grid .sb -row 1 -column 0 -columnspan 3 -sticky ew
    grid rowconfigure    . 0 -weight 1
    grid columnconfigure . 1 -weight 1

    bind . <Control-n> { els::new;  break }
    bind . <Control-o> { els::open; break }
    bind . <Control-s> { els::save; break }
    bind . <Control-q> { els::quit; break }
    bind .t <<Modified>>    els::on_modified
    bind .t <KeyRelease>    els::refresh_view
    bind .t <ButtonRelease> els::refresh_view
    bind .t <FocusIn>       els::refresh_view
    bind .t <<Paste>>       { after idle els::refresh_view }
    bind .t <<Cut>>         { after idle els::refresh_view }
    bind .t <Configure>     { after idle els::refresh_view }
    bind .ln <Button-1>     { focus .t; break }
    bind .ln <MouseWheel>   { els::wheel %D; break }
    bind .ln <Button-4>     { .t yview scroll -3 units; els::sync_scroll; break }
    bind .ln <Button-5>     { .t yview scroll 3 units; els::sync_scroll; break }
    els::refresh_view
    focus .t
}

# ---- title / status -----------------------------------------------------
proc els::settitle {} {
    set name [expr {$::els::path eq "" ? "untitled" : [file tail $::els::path]}]
    set mark [expr {$::els::dirty ? "• " : ""}]
    wm title . "els — $mark$name"
    .sb.name configure -text [expr {$::els::path eq "" ? "untitled" : $::els::path}]
}
proc els::on_modified {} {
    set ::els::dirty [.t edit modified]
    els::settitle
    after idle els::refresh_view
}
proc els::update_pos {} {
    lassign [split [.t index insert] .] line col
    .sb.pos configure -text "Ln $line, Col [expr {$col + 1}]"
}
proc els::line_count {} {
    set line [lindex [split [.t index "end - 1 char"] .] 0]
    if {$line < 1} { return 1 }
    return $line
}
proc els::update_current_line {} {
    set line [lindex [split [.t index insert] .] 0]
    .t tag remove currentLine 1.0 end
    .t tag add currentLine "$line.0" "$line.end + 1 char"
    .ln tag remove currentLine 1.0 end
    .ln tag add currentLine "$line.0" "$line.end"
}
proc els::update_line_numbers {} {
    set lines [els::line_count]
    set digits [string length $lines]
    set width [expr {max(2, $digits + 1)}]
    set numbers ""
    for {set i 1} {$i <= $lines} {incr i} {
        append numbers [format "%*d\n" [expr {$width - 1}] $i]
    }
    .ln configure -state normal -width $width
    .ln delete 1.0 end
    .ln insert end $numbers
    .ln configure -state disabled
    els::sync_scroll
}
proc els::sync_scroll {} {
    if {[winfo exists .ln] && [winfo exists .t]} {
        .ln yview moveto [lindex [.t yview] 0]
    }
}
proc els::yscroll {first last} {
    .vs set $first $last
    .ln yview moveto $first
}
proc els::scroll {args} {
    .t yview {*}$args
    els::sync_scroll
}
proc els::wheel {delta} {
    .t yview scroll [expr {-$delta / 120}] units
    els::sync_scroll
}
proc els::refresh_view {} {
    els::update_pos
    els::update_line_numbers
    els::update_current_line
}

# ---- file operations ----------------------------------------------------
proc els::new {} {
    .t delete 1.0 end
    set ::els::path ""
    .t edit reset; .t edit modified 0
    els::settitle; els::update_pos
}
proc els::open {{p ""}} {
    if {$p eq ""} {
        set p [tk_getOpenFile -parent .]
        if {$p eq ""} return
    }
    set fh [::open $p r]
    fconfigure $fh -encoding utf-8
    set data [read $fh]
    close $fh
    .t delete 1.0 end
    .t insert end $data
    .t mark set insert 1.0
    .t see insert
    set ::els::path $p
    .t edit reset; .t edit modified 0
    els::settitle; els::update_pos
}
proc els::save {} {
    if {$::els::path eq ""} { return [els::saveas] }
    set fh [::open $::els::path w]
    fconfigure $fh -encoding utf-8
    puts -nonewline $fh [.t get 1.0 "end - 1 char"]
    close $fh
    .t edit modified 0
    els::settitle
}
proc els::saveas {} {
    set p [tk_getSaveFile -parent .]
    if {$p eq ""} return
    set ::els::path $p
    els::save
}
proc els::about {} {
    tk_messageBox -parent . -title "About els" -type ok \
        -message "els $::els::version\nTcl/Tk [info patchlevel]\n\nA tiny, scriptable text editor."
}
proc els::quit {} {
    els::save_geometry
    exit
}

# ---- main ---------------------------------------------------------------
els::build
set ::a0 [lindex $argv 0]
if {$::a0 eq "--selftest"} {
    set tf [lindex $argv 1]
    set openok "skipped"
    if {$tf ne ""} {
        if {[catch {els::open $tf} err]} {
            set openok "FAIL: $err"
        } else {
            set openok "ok lines=[lindex [split [.t index end-1c] .] 0]"
        }
    }
    update idletasks; update
    set out [::open {C:/Users/anafa/dev/els/.toolchain/els-selftest.txt} w]
    puts $out "ok version=$::els::version tk=[info patchlevel]"
    puts $out "mapped=[winfo ismapped .] title=[wm title .]"
    puts $out "caret=[.t cget -insertbackground] page=[.t cget -bg] font=[.t cget -font]"
    puts $out "icon=$::els::iconLoaded path=$::els::iconPath"
    puts $out "gutter_width=[.ln cget -width] lines=[els::line_count]"
    puts $out "current_line_tag=[.t tag ranges currentLine]"
    puts $out "config=[els::config_file] geometry=[wm geometry .]"
    puts $out "theme=[ttk::style theme use] scaling=[format %.3f [tk scaling]]"
    puts $out "open=$openok"
    close $out
    after 150 {exit}
} elseif {$::a0 ne ""} {
    els::open $::a0
}
