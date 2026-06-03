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
}

# ---- look: the els visual identity --------------------------------------
set ::els::PAGE  "#F2F2F2"       ;# calm grey page (not pure white)
set ::els::INK   "#1A1A1A"
set ::els::CARET "#DC2626"       ;# the signature red caret
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsUI   -family {Segoe UI} -size 9

# ---- build the UI -------------------------------------------------------
proc els::build {} {
    wm title . "els"
    wm geometry . 900x620
    wm minsize . 360 240

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
        -tabstyle wordprocessor -yscrollcommand {.vs set}
    ttk::scrollbar .vs -orient vertical -command {.t yview}

    ttk::frame .sb
    ttk::label .sb.pos  -font elsUI -anchor w -text "Ln 1, Col 1"
    ttk::label .sb.name -font elsUI -anchor e -text "untitled"
    pack .sb.pos  -side left  -padx 8 -pady 2
    pack .sb.name -side right -padx 8 -pady 2

    grid .t  -row 0 -column 0 -sticky nsew
    grid .vs -row 0 -column 1 -sticky ns
    grid .sb -row 1 -column 0 -columnspan 2 -sticky ew
    grid rowconfigure    . 0 -weight 1
    grid columnconfigure . 0 -weight 1

    bind . <Control-n> { els::new;  break }
    bind . <Control-o> { els::open; break }
    bind . <Control-s> { els::save; break }
    bind . <Control-q> { els::quit; break }
    bind .t <<Modified>>    els::on_modified
    bind .t <KeyRelease>    els::update_pos
    bind .t <ButtonRelease> els::update_pos
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
}
proc els::update_pos {} {
    lassign [split [.t index insert] .] line col
    .sb.pos configure -text "Ln $line, Col [expr {$col + 1}]"
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
proc els::quit {} { exit }

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
    puts $out "theme=[ttk::style theme use] scaling=[format %.3f [tk scaling]]"
    puts $out "open=$openok"
    close $out
    after 150 {exit}
} elseif {$::a0 ne ""} {
    els::open $::a0
}
