#!/usr/bin/env wish
# els — a tiny, scriptable text editor.  Tcl/Tk 9 edition.
#
# This is the rewrite of the C23/Lua els (which shipped through v0.3, archived
# in ../els-c).  Tk's Text widget is the buffer; Tcl is the scripting language.
# Design language carried over from v0.3: calm grey page, the signature red
# caret, restrained chrome, opinionated (few knobs).
#
# Multi-file model: one Text widget per open document (each keeps its own undo
# stack, selection and modified state, free from Tk).  A shared gutter,
# scrollbar and status bar re-point to whichever document is active.  A custom
# flat tab strip switches between them.

package require Tk

namespace eval els {
    variable version "0.4-dev"   ;# Tk edition; the C line ended at 0.3
    variable docs {}             ;# ordered list of open document ids
    variable active ""           ;# active document id ("" = none)
    variable seq 0               ;# monotonic id counter
    variable iconImage ""
    variable iconPath ""
    variable iconLoaded 0
    variable selftest [expr {[lindex $::argv 0] eq "--selftest"}]
    variable docPath             ;# array: id -> file path ("" = untitled)
    array set docPath {}
}

# ---- look: the els visual identity --------------------------------------
set ::els::PAGE   "#F2F2F2"      ;# calm grey page (not pure white)
set ::els::INK    "#1A1A1A"
set ::els::CARET  "#DC2626"      ;# the signature red caret
set ::els::LINE   "#E8E8E8"
set ::els::GUTTER "#E2E2E2"
set ::els::MUTED  "#666666"
set ::els::TABBG  "#D6D6D6"      ;# the strip behind the tabs
set ::els::TABOFF "#E2E2E2"      ;# an inactive tab
set ::els::TABON  "#F2F2F2"      ;# active tab merges into the page
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsUI   -family {Segoe UI} -size 9

# ---- widget-name helpers ------------------------------------------------
proc els::W {id}    { return ".txt_$id" }       ;# a document's Text widget
proc els::tabW {id} { return ".tabs.tab_$id" }  ;# a document's tab frame
proc els::T {} {                                ;# the active Text widget ("" = none)
    variable active
    if {$active eq ""} { return "" }
    return [els::W $active]
}
proc els::id_of {w} {                           ;# ".txt_d3" -> "d3"
    if {[regexp {^\.txt_(.+)$} $w -> id]} { return $id }
    return ""
}

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
    .menu.file add command -label "New Tab"   -accelerator Ctrl+N -command els::new
    .menu.file add command -label Open...      -accelerator Ctrl+O -command els::open
    .menu.file add command -label Save         -accelerator Ctrl+S -command els::save
    .menu.file add command -label "Save As..."                     -command els::saveas
    .menu.file add separator
    .menu.file add command -label "Close Tab"  -accelerator Ctrl+W -command els::close_tab
    .menu.file add command -label Exit         -accelerator Ctrl+Q -command els::quit
    menu .menu.help
    .menu add cascade -label Help -menu .menu.help
    .menu.help add command -label "About els" -command els::about

    # the tab strip
    frame .tabs -bg $::els::TABBG

    # the shared line-number gutter
    text .ln -width 4 -wrap none -font elsMono \
        -bg $::els::GUTTER -fg $::els::MUTED \
        -borderwidth 0 -highlightthickness 0 -padx 5 -pady 4 \
        -takefocus 0 -cursor arrow -insertwidth 0 -state disabled
    .ln tag configure currentLine -background $::els::LINE

    # the shared scrollbar
    ttk::scrollbar .vs -orient vertical -command {els::scroll}

    # the shared status bar
    ttk::frame .sb
    ttk::label .sb.pos  -font elsUI -anchor w -text "Ln 1, Col 1"
    ttk::label .sb.name -font elsUI -anchor e -text "untitled"
    pack .sb.pos  -side left  -padx 8 -pady 2
    pack .sb.name -side right -padx 8 -pady 2

    grid .tabs -row 0 -column 0 -columnspan 3 -sticky ew
    grid .ln   -row 1 -column 0 -sticky ns
    grid .vs   -row 1 -column 2 -sticky ns
    grid .sb   -row 2 -column 0 -columnspan 3 -sticky ew
    grid rowconfigure    . 1 -weight 1
    grid columnconfigure . 1 -weight 1

    # class bindings shared by every document Text widget.  The elsText tag
    # runs BEFORE the default Text tag, so accelerators here pre-empt Tk's
    # emacs-style defaults (Ctrl+N = down-line, Ctrl+O = open-line, ...).
    bind elsText <<Modified>>    {els::on_modified %W}
    bind elsText <KeyRelease>    {els::refresh_view}
    bind elsText <ButtonRelease> {els::refresh_view}
    bind elsText <FocusIn>       {els::refresh_view}
    bind elsText <<Paste>>       {after idle els::refresh_view}
    bind elsText <<Cut>>         {after idle els::refresh_view}
    bind elsText <Configure>     {after idle els::refresh_view}
    bind elsText <Control-n> { els::new;       break }
    bind elsText <Control-o> { els::open;      break }
    bind elsText <Control-s> { els::save;      break }
    bind elsText <Control-w> { els::close_tab; break }
    bind elsText <Control-q> { els::quit;      break }
    bind elsText <Control-Tab>          { els::cycle 1;  break }
    bind elsText <Control-Shift-Tab>    { els::cycle -1; break }
    bind elsText <Control-ISO_Left_Tab> { els::cycle -1; break }

    # the same accelerators on the toplevel, for when focus is off the text
    bind . <Control-n> { els::new;       break }
    bind . <Control-o> { els::open;      break }
    bind . <Control-s> { els::save;      break }
    bind . <Control-w> { els::close_tab; break }
    bind . <Control-q> { els::quit;      break }
    bind . <Control-Tab>          { els::cycle 1;  break }
    bind . <Control-Shift-Tab>    { els::cycle -1; break }
    bind . <Control-ISO_Left_Tab> { els::cycle -1; break }

    bind .ln <Button-1>   { focus [els::T]; break }
    bind .ln <MouseWheel> { els::wheel %D; break }
    bind .ln <Button-4>   { els::scroll scroll -3 units; break }
    bind .ln <Button-5>   { els::scroll scroll  3 units; break }

    # start with one empty document
    els::new_doc
}

# ---- documents ----------------------------------------------------------
proc els::new_doc {{path ""}} {
    variable docs
    variable seq
    variable docPath
    set id "d$seq"
    incr seq
    set w [els::W $id]
    text $w -undo 1 -wrap none -font elsMono \
        -bg $::els::PAGE -fg $::els::INK \
        -insertbackground $::els::CARET -insertwidth 2 \
        -borderwidth 0 -highlightthickness 0 -padx 6 -pady 4 \
        -tabstyle wordprocessor \
        -yscrollcommand [list els::yscroll $id]
    $w tag configure currentLine -background $::els::LINE
    $w tag lower currentLine
    # let the shared class bindings fire (run before the default Text tag)
    bindtags $w [linsert [bindtags $w] 1 elsText]
    set docPath($id) $path
    lappend docs $id
    els::make_tab $id
    els::switch_to $id
    return $id
}
proc els::doc_dirty {id} {
    set w [els::W $id]
    if {![winfo exists $w]} { return 0 }
    return [$w edit modified]
}
proc els::doc_name {id} {
    variable docPath
    set p $docPath($id)
    return [expr {$p eq "" ? "untitled" : [file tail $p]}]
}
proc els::pristine {id} {
    # a fresh, untouched untitled document — safe to reuse on Open
    variable docPath
    if {$id eq ""} { return 0 }
    if {$docPath($id) ne ""} { return 0 }
    if {[els::doc_dirty $id]} { return 0 }
    return [expr {[[els::W $id] get 1.0 "end - 1 char"] eq ""}]
}
proc els::switch_to {id} {
    variable docs
    variable active
    if {[lsearch -exact $docs $id] < 0} { return }
    if {$active ne "" && [winfo exists [els::W $active]]} {
        grid remove [els::W $active]
    }
    set active $id
    set w [els::W $id]
    grid $w -row 1 -column 1 -sticky nsew
    focus $w
    els::refresh_tabs
    els::settitle
    els::refresh_view
}
proc els::cycle {dir} {
    variable docs
    variable active
    set n [llength $docs]
    if {$n <= 1} { return }
    set i [lsearch -exact $docs $active]
    els::switch_to [lindex $docs [expr {($i + $dir + $n) % $n}]]
}
proc els::close_tab {} {
    variable active
    if {$active ne ""} { els::close_doc $active }
}
proc els::close_doc {id} {
    variable docs
    variable active
    variable docPath
    set idx [lsearch -exact $docs $id]
    if {$idx < 0} { return }
    if {[els::doc_dirty $id]} {
        set ans [tk_messageBox -parent . -icon warning -type yesnocancel \
            -title els -message "Save changes to [els::doc_name $id]?"]
        if {$ans eq "cancel"} { return }
        if {$ans eq "yes"} {
            els::switch_to $id
            els::save
            if {[els::doc_dirty $id]} { return }   ;# Save As was cancelled
        }
    }
    set idx [lsearch -exact $docs $id]
    set docs [lreplace $docs $idx $idx]
    destroy [els::W $id]
    destroy [els::tabW $id]
    unset -nocomplain docPath($id)
    if {$active eq $id} { set active "" }
    if {[llength $docs] == 0} {
        els::new_doc
        return
    }
    if {$active eq ""} {
        set nidx [expr {$idx > [llength $docs] - 1 ? [llength $docs] - 1 : $idx}]
        els::switch_to [lindex $docs $nidx]
    } else {
        els::refresh_tabs
    }
}

# ---- tab strip ----------------------------------------------------------
proc els::tab_text {id} {
    set mark [expr {[els::doc_dirty $id] ? "• " : ""}]
    return "$mark[els::doc_name $id]"
}
proc els::make_tab {id} {
    set tf [els::tabW $id]
    frame $tf -bg $::els::TABOFF
    label $tf.name -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text [els::tab_text $id] -padx 6 -pady 3 -anchor w
    label $tf.close -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text "×" -padx 4 -pady 3
    pack $tf.name  -side left
    pack $tf.close -side right
    pack $tf -side left -padx {0 1} -pady {2 0} -fill y
    bind $tf       <Button-1> [list els::switch_to $id]
    bind $tf.name  <Button-1> [list els::switch_to $id]
    bind $tf.close <Button-1> [list els::close_doc $id]
    bind $tf.close <Enter>    [list $tf.close configure -fg $::els::CARET]
    bind $tf.close <Leave>    [list els::tab_close_leave $id]
}
proc els::tab_close_leave {id} {
    variable active
    set fg [expr {$id eq $active ? $::els::INK : $::els::MUTED}]
    catch {[els::tabW $id].close configure -fg $fg}
}
proc els::update_tab {id} {
    set tf [els::tabW $id]
    if {![winfo exists $tf]} { return }
    $tf.name configure -text [els::tab_text $id]
}
proc els::refresh_tabs {} {
    variable docs
    variable active
    foreach id $docs {
        set tf [els::tabW $id]
        if {![winfo exists $tf]} { continue }
        if {$id eq $active} {
            set bg $::els::TABON ; set fg $::els::INK
        } else {
            set bg $::els::TABOFF ; set fg $::els::MUTED
        }
        $tf       configure -bg $bg
        $tf.name  configure -bg $bg -fg $fg
        $tf.close configure -bg $bg -fg $fg
    }
}

# ---- title / status -----------------------------------------------------
proc els::settitle {} {
    variable active
    variable docPath
    if {$active eq ""} { wm title . "els"; return }
    set p $docPath($active)
    set mark [expr {[els::doc_dirty $active] ? "• " : ""}]
    wm title . "els — $mark[els::doc_name $active]"
    .sb.name configure -text [expr {$p eq "" ? "untitled" : $p}]
}
proc els::on_modified {w} {
    variable active
    set id [els::id_of $w]
    if {$id eq ""} { return }
    els::update_tab $id
    if {$id eq $active} {
        els::settitle
        after idle els::refresh_view
    }
}
proc els::update_pos {} {
    set w [els::T]
    if {$w eq ""} { return }
    lassign [split [$w index insert] .] line col
    .sb.pos configure -text "Ln $line, Col [expr {$col + 1}]"
}
proc els::line_count {} {
    set w [els::T]
    if {$w eq ""} { return 1 }
    set line [lindex [split [$w index "end - 1 char"] .] 0]
    if {$line < 1} { return 1 }
    return $line
}
proc els::update_current_line {} {
    set w [els::T]
    if {$w eq ""} { return }
    set line [lindex [split [$w index insert] .] 0]
    $w tag remove currentLine 1.0 end
    $w tag add currentLine "$line.0" "$line.end + 1 char"
    .ln tag remove currentLine 1.0 end
    .ln tag add currentLine "$line.0" "$line.end"
}
proc els::update_line_numbers {} {
    if {[els::T] eq ""} { return }
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
    set w [els::T]
    if {$w ne "" && [winfo exists .ln]} {
        .ln yview moveto [lindex [$w yview] 0]
    }
}
proc els::yscroll {id first last} {
    variable active
    if {$id ne $active} { return }
    .vs set $first $last
    .ln yview moveto $first
}
proc els::scroll {args} {
    set w [els::T]
    if {$w eq ""} { return }
    $w yview {*}$args
    els::sync_scroll
}
proc els::wheel {delta} {
    set w [els::T]
    if {$w eq ""} { return }
    $w yview scroll [expr {-$delta / 120}] units
    els::sync_scroll
}
proc els::refresh_view {} {
    if {[els::T] eq ""} { return }
    els::update_pos
    els::update_line_numbers
    els::update_current_line
}

# ---- file operations ----------------------------------------------------
proc els::new {} {
    els::new_doc
}
proc els::open {{p ""}} {
    if {$p eq ""} {
        set p [tk_getOpenFile -parent .]
        if {$p eq ""} { return }
    }
    variable active
    variable docPath
    if {[els::pristine $active]} {
        set id $active
    } else {
        set id [els::new_doc]
    }
    set w [els::W $id]
    if {[catch {
        set fh [::open $p r]
        fconfigure $fh -encoding utf-8
        set data [read $fh]
        close $fh
    } err]} {
        tk_messageBox -parent . -icon error -title els -message "Cannot open file:\n$err"
        if {[els::pristine $id] && [llength $::els::docs] > 1} { els::close_doc $id }
        return
    }
    $w delete 1.0 end
    $w insert end $data
    $w mark set insert 1.0
    $w see insert
    set docPath($id) $p
    $w edit reset
    $w edit modified 0
    els::switch_to $id
    els::update_tab $id
    els::settitle
    els::refresh_view
}
proc els::save {} {
    variable active
    variable docPath
    if {$active eq ""} { return }
    if {$docPath($active) eq ""} { return [els::saveas] }
    set w [els::W $active]
    if {[catch {
        set fh [::open $docPath($active) w]
        fconfigure $fh -encoding utf-8
        puts -nonewline $fh [$w get 1.0 "end - 1 char"]
        close $fh
    } err]} {
        tk_messageBox -parent . -icon error -title els -message "Cannot save file:\n$err"
        return
    }
    $w edit modified 0
    els::update_tab $active
    els::settitle
}
proc els::saveas {} {
    variable active
    variable docPath
    if {$active eq ""} { return }
    set p [tk_getSaveFile -parent .]
    if {$p eq ""} { return }
    set docPath($active) $p
    els::save
    els::update_tab $active
}
proc els::about {} {
    tk_messageBox -parent . -title "About els" -type ok \
        -message "els $::els::version\nTcl/Tk [info patchlevel]\n\nA tiny, scriptable text editor."
}
proc els::quit {} {
    variable docs
    foreach id $docs {
        if {[els::doc_dirty $id]} {
            els::switch_to $id
            set ans [tk_messageBox -parent . -icon warning -type yesnocancel \
                -title els -message "Save changes to [els::doc_name $id]?"]
            if {$ans eq "cancel"} { return }
            if {$ans eq "yes"} {
                els::save
                if {[els::doc_dirty $id]} { return }
            }
        }
    }
    els::save_geometry
    exit
}

# ---- main ---------------------------------------------------------------
proc els::main {} {
    els::build
    set a0 [lindex $::argv 0]
    if {$a0 eq "--selftest"} {
        els::selftest [lindex $::argv 1]
    } else {
        # open every file argument, each in its own tab (the first reuses the
        # initial empty document)
        foreach f $::argv {
            if {[string index $f 0] ne "-"} { els::open $f }
        }
    }
}

# headless smoke test: open a file, exercise a second tab, write a report file
proc els::selftest {tf} {
    set openok "skipped"
    if {$tf ne ""} {
        if {[catch {els::open $tf} err]} {
            set openok "FAIL: $err"
        } else {
            set openok "ok lines=[els::line_count]"
        }
    }
    set d2 [els::new_doc]
    [els::W $d2] insert end "second tab body"
    set ndocs [llength $::els::docs]
    set tabs_ok 1
    foreach id $::els::docs {
        if {![winfo exists [els::tabW $id]]} { set tabs_ok 0 }
    }
    els::cycle -1
    update idletasks; update
    set w [els::T]
    set out [::open {C:/Users/anafa/dev/els/.toolchain/els-selftest.txt} w]
    puts $out "ok version=$::els::version tk=[info patchlevel]"
    puts $out "mapped=[winfo ismapped .] title=[wm title .]"
    puts $out "caret=[$w cget -insertbackground] page=[$w cget -bg] font=[$w cget -font]"
    puts $out "icon=$::els::iconLoaded path=$::els::iconPath"
    puts $out "gutter_width=[.ln cget -width] lines=[els::line_count]"
    puts $out "current_line_tag=[$w tag ranges currentLine]"
    puts $out "config=[els::config_file] geometry=[wm geometry .]"
    puts $out "theme=[ttk::style theme use] scaling=[format %.3f [tk scaling]]"
    puts $out "docs=$ndocs active=$::els::active tabs_ok=$tabs_ok"
    set dstate ""
    foreach id $::els::docs { append dstate "$id:[els::doc_dirty $id] " }
    puts $out "doc_dirty=[string trimright $dstate]"
    puts $out "open=$openok"
    close $out
    after 150 {exit}
}

# run the UI only when executed as the main script, not when sourced by tests
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    els::main
}
