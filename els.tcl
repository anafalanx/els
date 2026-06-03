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
    variable version "0.12"      ;# Tk edition; the C line ended at 0.3
    variable docs {}             ;# ordered list of open document ids
    variable active ""           ;# active document id ("" = none)
    variable seq 0               ;# monotonic id counter
    variable iconImage ""
    variable iconPath ""
    variable iconLoaded 0
    variable selftest [expr {[lindex $::argv 0] eq "--selftest"}]
    variable docPath             ;# array: id -> file path ("" = untitled)
    array set docPath {}
    variable docEnc ; array set docEnc {}   ;# id -> Tcl encoding (utf-8, utf-16le, ...)
    variable docBom ; array set docBom {}   ;# id -> 1 if a byte-order mark was present
    variable docEol ; array set docEol {}   ;# id -> lf | crlf | cr
    variable docRaw ; array set docRaw {}   ;# id -> exact bytes as loaded ("" = never from disk)
    # charset detection (chardet quality via the system ICU; 0 until loaded)
    variable have_detect 0
    variable DETECT_MIN  15      ;# ignore ICU guesses below this confidence (0-100)
    # curated encodings for the status-bar picker: {label encoding bom} triples,
    # "-" marks a separator.  "Other (all)" exposes every Tcl encoding.
    variable ENC_CURATED {
        "UTF-8"                       utf-8      0
        "UTF-8 with BOM"              utf-8      1
        "UTF-16 LE"                   utf-16le   1
        "UTF-16 BE"                   utf-16be   1
        "-" - -
        "Windows-1252 (Western)"      cp1252     0
        "ISO-8859-1 (Latin-1)"        iso8859-1  0
        "ISO-8859-15 (Latin-9)"       iso8859-15 0
        "Windows-1250 (Central Eur.)" cp1250     0
        "Windows-1251 (Cyrillic)"     cp1251     0
        "-" - -
        "Shift-JIS (Japanese)"        cp932      0
        "GBK (Simplified Chinese)"    cp936      0
        "Big5 (Traditional Chinese)"  big5       0
        "EUC-JP (Japanese)"           euc-jp     0
        "EUC-KR (Korean)"             euc-kr     0
    }
    # find / replace
    variable find_q ""           ;# search text
    variable find_r ""           ;# replacement text
    variable find_case 0         ;# match case
    variable find_word 0         ;# whole word
    variable find_regex 0        ;# regular expression (Tcl ARE)
    variable find_mode ""        ;# "" hidden | find | replace
    variable find_matches {}     ;# list of {start end} index pairs in the active doc
    variable find_current -1     ;# index into find_matches
    variable find_count ""       ;# status text e.g. "3 of 12"
    variable find_adapt 0        ;# adapt-case replace (replacement follows the match's case)
    variable find_history {}     ;# recent search terms, newest first (cap 16)
    variable find_hidx -1        ;# position while cycling history with Up/Down
    variable show_ws 0           ;# View ▸ Show Whitespace
    variable vs_shown -1         ;# scrollbar visibility (auto-hidden when content fits)
    variable vs_after ""         ;# pending (idle) scrollbar-visibility update
    variable find_after ""       ;# pending (debounced) incremental search
}

# ---- look: the els visual identity --------------------------------------
# A calm grey page, generously leaded, with one red flourish.  Chrome defers
# to the text: flat, tonal, hairline-thin; separation by value, not borders.
set ::els::PAGE    "#F2F2F2"     ;# calm grey page (#FFF glares; ~15.8:1 w/ ink)
set ::els::INK     "#1A1A1A"     ;# near-black ink (not pure #000)
set ::els::CARET   "#DC322F"     ;# the signature red caret + accent
set ::els::LINE    "#EAEAEA"     ;# current-line wash — a whisper, not a band
set ::els::GUTTER  "#ECECEC"     ;# gutter ground (a tonal step off the page)
set ::els::GUTTINK "#8C8C8C"     ;# line numbers — quiet, deferential
set ::els::MUTED   "#6B7177"     ;# chrome text (muted slate)
set ::els::SEL     "#D6E2F2"     ;# selection — a calm cool tint, not vivid
set ::els::SELOFF  "#E2E2E2"     ;# selection while the buffer is unfocused
set ::els::CHROME  "#E9E9E9"     ;# flat chrome panels (status / find bar)
set ::els::HAIR    "#D4D4D4"     ;# 1px hairline separators
set ::els::TABBG   "#DEDEDE"     ;# the strip behind the tabs
set ::els::TABOFF  "#E6E6E6"     ;# an inactive tab
set ::els::TABON   "#F2F2F2"     ;# active tab merges into the page
set ::els::FINDALL "#FFF1C4"     ;# all find matches (soft amber)
set ::els::FINDONE "#FFD66B"     ;# the current find match (stronger amber)
set ::els::WSTAB   "#D3D8F0"     ;# tabs (blue-grey block — visible on page + line)
set ::els::WSTRAIL "#F3C0C0"     ;# trailing whitespace (clear red block)
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsUI   -family {Segoe UI} -size 9
# leading: ~1.34x line height (the single biggest "calm" lever), scaled from
# the font's own line box so it tracks DPI.  Applied as -spacing1/-spacing3.
set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]

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

# ---- flat chrome styling ------------------------------------------------
# The native 'vista' ttk theme can't be recoloured or flattened, so we base
# the chrome on 'clam' (full colour control) and build flat, borderless styles.
# Separation is by tone, not borders; one 4px spacing quantum throughout.
proc els::init_style {} {
    set s ttk::style
    catch {$s theme use clam}
    set bg $::els::CHROME ; set ink $::els::INK ; set hair $::els::HAIR
    $s configure . -background $bg -foreground $ink -font elsUI \
        -borderwidth 0 -focuscolor $bg -troughcolor $::els::PAGE \
        -bordercolor $hair -darkcolor $bg -lightcolor $bg
    $s configure TFrame -background $bg
    $s configure TLabel -background $bg -foreground $ink
    # entries: flat, page-coloured field, hairline border, red insert caret
    $s configure TEntry -relief flat -borderwidth 1 -padding {6 4} \
        -fieldbackground $::els::PAGE -foreground $ink -insertcolor $::els::CARET \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map TEntry -bordercolor [list focus $::els::CARET]
    # a brief red-tinted field flashed on no-match / wrap-around (never a popup)
    $s configure Flash.TEntry -relief flat -borderwidth 1 -padding {6 4} \
        -fieldbackground $::els::WSTRAIL -foreground $::els::INK \
        -bordercolor $::els::CARET -lightcolor $::els::CARET -darkcolor $::els::CARET
    # buttons: flat, quiet until hovered
    $s configure TButton -background $bg -foreground $ink -anchor center \
        -borderwidth 0 -relief flat -padding {8 4} -focuscolor $bg
    $s map TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list disabled $::els::MUTED]
    # find toggles (Aa / W / .*): a flat chip that fills grey when active
    $s configure Toolbutton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center
    $s map Toolbutton -background [list selected #C6C6C6 active $::els::TABBG] \
        -foreground [list selected $ink active $ink]
    # a slim, arrow-less vertical scrollbar (thumb only)
    $s layout Vertical.TScrollbar {
        Vertical.Scrollbar.trough -sticky ns -children {
            Vertical.Scrollbar.thumb -expand 1 -sticky nswe
        }
    }
    $s configure Vertical.TScrollbar -troughcolor $::els::PAGE \
        -background #CACACA -bordercolor $::els::PAGE \
        -lightcolor #CACACA -darkcolor #CACACA \
        -borderwidth 0 -arrowsize 0 -width 12 -gripcount 0
    $s map Vertical.TScrollbar -background [list active #B0B0B0 disabled $::els::PAGE]
}

# ---- build the UI -------------------------------------------------------
proc els::build {} {
    wm title . "els"
    wm geometry . 900x620
    els::init_style
    . configure -background $::els::PAGE
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
    menu .menu.view
    .menu add cascade -label View -menu .menu.view
    .menu.view add command -label "Go to Line..." -accelerator Ctrl+G -command els::goto_line
    .menu.view add separator
    .menu.view add checkbutton -label "Show Whitespace" -variable ::els::show_ws \
        -command els::ws_refresh
    menu .menu.help
    .menu add cascade -label Help -menu .menu.help
    .menu.help add command -label "About els" -command els::about

    # the tab strip
    frame .tabs -bg $::els::TABBG

    # the shared line-number gutter — mirrors the buffer's padding + leading so
    # numbers align with their text rows; quiet ink so it defers to the page
    text .ln -width 4 -wrap none -font elsMono \
        -bg $::els::GUTTER -fg $::els::GUTTINK \
        -borderwidth 0 -highlightthickness 0 -padx 6 -pady 6 \
        -spacing1 $::els::LEAD -spacing3 $::els::LEAD \
        -takefocus 0 -cursor arrow -insertwidth 0 -state disabled
    .ln tag configure currentLine -background $::els::LINE

    # the shared scrollbar
    ttk::scrollbar .vs -orient vertical -command {els::scroll}

    # the find / replace bar (hidden until Ctrl+F / Ctrl+H)
    els::build_findbar

    # the shared status bar — one thin, quiet line under a hairline
    ttk::frame .sb
    frame .sb.hair -height 1 -bg $::els::HAIR
    ttk::label .sb.pos  -font elsUI -anchor w -text "Ln 1, Col 1" -foreground $::els::MUTED
    ttk::label .sb.eol  -font elsUI -anchor w -text "LF"    -foreground $::els::MUTED -cursor hand2
    ttk::label .sb.enc  -font elsUI -anchor w -text "UTF-8" -foreground $::els::MUTED -cursor hand2
    ttk::label .sb.name -font elsUI -anchor e -text "untitled" -foreground $::els::MUTED
    pack .sb.hair -side top -fill x
    pack .sb.pos  -side left  -padx {12 16} -pady 4
    pack .sb.eol  -side left  -padx {0 16} -pady 4
    pack .sb.enc  -side left  -padx {0 16} -pady 4
    pack .sb.name -side right -padx 12 -pady 4
    # the EOL and encoding indicators are clickable pickers
    bind .sb.eol <Button-1> {els::popup_eol_menu %X %Y}
    bind .sb.enc <Button-1> {els::popup_enc_menu %X %Y}

    grid .tabs -row 0 -column 0 -columnspan 3 -sticky ew
    grid .ln   -row 1 -column 0 -sticky ns
    grid .vs   -row 1 -column 2 -sticky ns
    grid .sb   -row 3 -column 0 -columnspan 3 -sticky ew
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
    bind elsText <Control-f> { els::find_show find;    break }
    bind elsText <Control-h> { els::find_show replace; break }
    bind elsText <Control-g> { els::goto_line;         break }

    # the same accelerators on the toplevel, for when focus is off the text
    bind . <Control-n> { els::new;       break }
    bind . <Control-o> { els::open;      break }
    bind . <Control-s> { els::save;      break }
    bind . <Control-w> { els::close_tab; break }
    bind . <Control-q> { els::quit;      break }
    bind . <Control-Tab>          { els::cycle 1;  break }
    bind . <Control-Shift-Tab>    { els::cycle -1; break }
    bind . <Control-ISO_Left_Tab> { els::cycle -1; break }
    bind . <Control-f> { els::find_show find;    break }
    bind . <Control-h> { els::find_show replace; break }
    bind . <Control-g> { els::goto_line;         break }

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
        -insertbackground $::els::CARET -insertwidth 2 -insertofftime 0 \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -inactiveselectbackground $::els::SELOFF \
        -borderwidth 0 -highlightthickness 0 -padx 14 -pady 6 \
        -spacing1 $::els::LEAD -spacing3 $::els::LEAD \
        -tabstyle wordprocessor \
        -yscrollcommand [list els::yscroll $id]
    $w tag configure currentLine -background $::els::LINE
    $w tag configure wsTab   -background $::els::WSTAB
    $w tag configure wsTrail -background $::els::WSTRAIL
    $w tag configure findAll -background $::els::FINDALL
    $w tag configure findOne -background $::els::FINDONE
    # stacking, low -> high: current-line wash < whitespace < matches < selection
    # (whitespace above the line wash so it's visible on the current line too)
    $w tag lower currentLine
    $w tag raise wsTab
    $w tag raise wsTrail
    $w tag raise findAll
    $w tag raise findOne
    $w tag raise sel
    # let the shared class bindings fire (run before the default Text tag)
    bindtags $w [linsert [bindtags $w] 1 elsText]
    set docPath($id) $path
    set ::els::docEnc($id) utf-8
    set ::els::docBom($id) 0
    set ::els::docEol($id) lf
    set ::els::docRaw($id) ""
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
    if {$::els::find_mode ne ""} { els::find_update }
    after idle els::update_vscroll
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
    unset -nocomplain docPath($id) ::els::docEnc($id) ::els::docBom($id) \
        ::els::docEol($id) ::els::docRaw($id)
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
    .sb.eol  configure -text [els::eol_label $::els::docEol($active)]
    .sb.enc  configure -text [els::enc_label $::els::docEnc($active) $::els::docBom($active)]
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
    variable vs_after
    if {$id ne $active} { return }
    .vs set $first $last
    .ln yview moveto $first
    # Defer the scrollbar show/hide to idle: it calls `grid` (a geometry change),
    # and running that from inside a -yscrollcommand can re-enter the display
    # loop. Coalesced so a burst of scrolls schedules one update.
    after cancel $vs_after
    set vs_after [after idle els::update_vscroll]
}
# Show the scrollbar only when the document doesn't fit (chrome defers).  Reads
# the live yview rather than a possibly-stale -yscrollcommand value, so it's
# correct after a load settles (yscrollcommand only fires on view *change*).
proc els::update_vscroll {} {
    variable active
    variable vs_shown
    if {$active eq "" || ![winfo exists [els::W $active]]} { return }
    lassign [[els::W $active] yview] first last
    set need [expr {$first > 0.0001 || $last < 0.9999}]
    if {$need != $vs_shown} {
        set vs_shown $need
        if {$need} { grid .vs } else { grid remove .vs }
    }
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
    els::update_vscroll
    if {$::els::show_ws} { els::ws_refresh }
}

# ---- encoding / EOL -----------------------------------------------------
# Load the optional ICU charset detector (build/icudet.dll in source trees, a
# sibling of main.tcl in the packaged image).  Detection is a bonus: if the DLL
# or the system icu.dll is absent, els falls back to BOM + UTF-8 + cp1252.
proc els::load_detect {} {
    set dir [file dirname [info script]]
    foreach cand [list [file join $dir icudet.dll] [file join $dir build icudet.dll]] {
        if {[file exists $cand] && ![catch {load $cand Icudet}]} {
            # confirm icu.dll itself resolved (detect returns "" if not)
            return [expr {[::elsdet::detect "the quick brown fox jumps over"] ne ""}]
        }
    }
    if {![catch {package require icudet}] && \
        [::elsdet::detect "the quick brown fox jumps over"] ne ""} { return 1 }
    return 0
}

# Map an ICU canonical charset name onto a Tcl encoding name ("" = no match).
proc els::icu_to_tcl {name} {
    set key [string tolower [string map {- "" _ "" " " ""} $name]]
    set map {
        utf8 utf-8  utf16 utf-16le  utf16le utf-16le  utf16be utf-16be
        utf32 utf-32le  utf32le utf-32le  utf32be utf-32be  usascii ascii
        iso88591 iso8859-1   iso88592 iso8859-2   iso88593 iso8859-3
        iso88594 iso8859-4   iso88595 iso8859-5   iso88596 iso8859-6
        iso88597 iso8859-7   iso88598 iso8859-8   iso88599 iso8859-9
        iso885910 iso8859-10 iso885913 iso8859-13 iso885914 iso8859-14
        iso885915 iso8859-15 iso885916 iso8859-16
        windows1250 cp1250 windows1251 cp1251 windows1252 cp1252 windows1253 cp1253
        windows1254 cp1254 windows1255 cp1255 windows1256 cp1256 windows1257 cp1257
        windows1258 cp1258 windows874 cp874 tis620 tis-620
        shiftjis cp932 windows31j cp932 sjis cp932 ms932 cp932
        gb18030 cp936 gbk cp936 windows936 cp936 gb2312 gb2312 hzgb2312 gb2312
        big5 big5 big5hkscs big5
        eucjp euc-jp euckr euc-kr euccn euc-cn euctw euc-cn
        koi8r koi8-r koi8u koi8-u
        iso2022jp iso2022-jp iso2022kr iso2022-kr
        ibm420 ebcdic ibm424 ebcdic
    }
    if {[dict exists $map $key]} { return [dict get $map $key] }
    foreach e [encoding names] {
        if {[string map {- "" _ "" " " ""} $e] eq $key} { return $e }
    }
    return ""
}

# Resolve a BOM-less wide encoding (NUL bytes present).  ICU nails LE/BE/32;
# without ICU, fall back to a NUL-parity guess (UTF-16 LE/BE only).
proc els::detect_wide {raw sample} {
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            set enc [els::icu_to_tcl [lindex $d 0]]
            if {[string match utf-* $enc]} { return $enc }
        }
    }
    set even 0 ; set odd 0 ; set i 0
    foreach b [split $sample ""] {
        if {$b eq "\x00"} { if {$i & 1} { incr odd } else { incr even } }
        incr i
    }
    if {$even == 0 && $odd == 0} { return "" }
    if {$even > $odd} { return utf-16be }
    return utf-16le
}

proc els::detect_encoding {raw} {
    # -> {encoding bom}.  bom=1 if a byte-order mark was present (stripped on decode).
    set n [string length $raw]
    if {$n == 0} { return {utf-8 0} }
    # 1. BOM sniff — UTF-32 before UTF-16 (the UTF-32 LE BOM begins FF FE too).
    if {[string range $raw 0 3] eq "\x00\x00\xFE\xFF"} { return {utf-32be 1} }
    if {[string range $raw 0 3] eq "\xFF\xFE\x00\x00"} { return {utf-32le 1} }
    if {[string range $raw 0 2] eq "\xEF\xBB\xBF"}     { return {utf-8 1} }
    if {[string range $raw 0 1] eq "\xFF\xFE"}         { return {utf-16le 1} }
    if {[string range $raw 0 1] eq "\xFE\xFF"}         { return {utf-16be 1} }
    set sample [string range $raw 0 4095]
    # 2. NUL bytes => a wide encoding (BOM-less UTF-16/32).  Text in ASCII/UTF-8
    #    or any 8-bit/CJN encoding never contains NUL — and UTF-16-of-ASCII would
    #    otherwise sneak through the UTF-8 test below, so resolve it first.
    if {[string first "\x00" $sample] >= 0} {
        set enc [els::detect_wide $raw $sample]
        if {$enc ne ""} { return [list $enc 0] }
    }
    # 3. valid UTF-8 without BOM — definitive and free.
    if {![catch {encoding convertfrom -profile strict utf-8 $raw}]} { return {utf-8 0} }
    # 4. ICU charset detection (chardet quality) for legacy 8-bit / CJK text.
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            lassign $d icu conf
            set enc [els::icu_to_tcl $icu]
            if {$enc ne "" && $conf >= $::els::DETECT_MIN} { return [list $enc 0] }
        }
    }
    # 5. fallback: Windows Western — a superset of ASCII/Latin-1; never errors.
    return {cp1252 0}
}
proc els::decode {raw enc bom} {
    if {$bom} {
        set skip 2
        if {$enc eq "utf-8"} { set skip 3 } elseif {[string match utf-32* $enc]} { set skip 4 }
        set raw [string range $raw $skip end]
    }
    return [encoding convertfrom -profile replace $enc $raw]
}
proc els::detect_eol {text} {
    if {[string first "\r\n" $text] >= 0} { return crlf }
    if {[string first "\n"   $text] >= 0} { return lf }
    if {[string first "\r"   $text] >= 0} { return cr }
    return lf
}
proc els::enc_label {enc bom} {
    set m {utf-8 "UTF-8" utf-16le "UTF-16 LE" utf-16be "UTF-16 BE" \
           utf-32le "UTF-32 LE" utf-32be "UTF-32 BE"}
    set s [expr {[dict exists $m $enc] ? [dict get $m $enc] : [string toupper $enc]}]
    if {$bom} { append s " BOM" }
    return $s
}
proc els::eol_label {eol} { return [string map {lf LF crlf CRLF cr CR} $eol] }

# ---- encoding / EOL pickers (clickable status-bar indicators) ------------
# Build a menu of {label enc bom} curated entries plus an "Other (all)" cascade
# of every Tcl encoding.  `action` is reopen|save.
proc els::enc_menu {path action} {
    menu $path -tearoff 0
    foreach {label enc bom} $::els::ENC_CURATED {
        if {$label eq "-"} { $path add separator; continue }
        $path add command -label $label -command [list els::apply_enc $action $enc $bom]
    }
    $path add separator
    set other $path.other
    menu $other -tearoff 0
    set i 0
    foreach e [lsort -dictionary [encoding names]] {
        # column-break the long list so it never runs off-screen
        $other add command -label $e -command [list els::apply_enc $action $e 0] \
            -columnbreak [expr {$i > 0 && $i % 28 == 0}]
        incr i
    }
    $path add cascade -label "Other (all encodings)" -menu $other
    return $path
}
proc els::build_enc_popup {} {
    menu .encpop -tearoff 0
    .encpop add cascade -label "Reopen with Encoding" -menu [els::enc_menu .encpop.re reopen]
    .encpop add cascade -label "Save with Encoding"   -menu [els::enc_menu .encpop.sv save]
}
proc els::popup_enc_menu {x y} {
    if {$::els::active eq ""} return
    if {![winfo exists .encpop]} { els::build_enc_popup }
    set canReopen [expr {$::els::docPath($::els::active) ne ""}]
    .encpop entryconfigure "Reopen with Encoding" \
        -state [expr {$canReopen ? "normal" : "disabled"}]
    tk_popup .encpop $x $y
}
proc els::apply_enc {action enc bom} {
    if {$::els::active eq ""} return
    switch $action {
        reopen { els::reopen_with $enc $bom }
        save   { els::save_with   $enc $bom }
    }
}
proc els::reopen_with {enc bom} {
    set id $::els::active
    if {$::els::docPath($id) eq ""} {
        tk_messageBox -parent . -icon info -title els \
            -message "Nothing to reopen — this document was never loaded from a file."
        return
    }
    if {[els::doc_dirty $id]} {
        set ans [tk_messageBox -parent . -icon warning -type yesno -title els \
            -message "Reopen [els::doc_name $id] as [els::enc_label $enc $bom]?\
                      \nUnsaved changes will be lost."]
        if {$ans ne "yes"} return
    }
    set raw $::els::docRaw($id)
    set text [els::decode $raw $enc $bom]
    set eol  [els::detect_eol $text]
    set text [string map [list \r\n \n \r \n] $text]
    set w [els::W $id]
    $w delete 1.0 end
    $w insert end $text
    $w mark set insert 1.0 ; $w see insert
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    set ::els::docEol($id) $eol
    $w edit reset
    $w edit modified 0
    els::update_tab $id
    els::settitle
    els::refresh_view
}
proc els::save_with {enc bom} {
    set id $::els::active
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    els::settitle
    els::save
}
proc els::build_eol_popup {} {
    menu .eolpop -tearoff 0
    foreach {lbl v} {"LF (Unix / macOS)" lf "CRLF (Windows)" crlf "CR (classic Mac)" cr} {
        .eolpop add command -label $lbl -command [list els::set_eol $v]
    }
}
proc els::popup_eol_menu {x y} {
    if {$::els::active eq ""} return
    if {![winfo exists .eolpop]} { els::build_eol_popup }
    tk_popup .eolpop $x $y
}
proc els::set_eol {v} {
    set id $::els::active
    if {$id eq "" || $::els::docEol($id) eq $v} return
    set ::els::docEol($id) $v
    [els::W $id] edit modified 1   ;# make the change saveable
    els::update_tab $id
    els::settitle
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
        fconfigure $fh -translation binary
        set raw [read $fh]
        close $fh
    } err]} {
        tk_messageBox -parent . -icon error -title els -message "Cannot open file:\n$err"
        if {[els::pristine $id] && [llength $::els::docs] > 1} { els::close_doc $id }
        return
    }
    # detect encoding + EOL, decode, normalise the buffer to LF internally
    lassign [els::detect_encoding $raw] enc bom
    set text [els::decode $raw $enc $bom]
    set eol [els::detect_eol $text]
    set text [string map [list \r\n \n \r \n] $text]
    $w delete 1.0 end
    $w insert end $text
    $w mark set insert 1.0
    $w see insert
    set docPath($id) $p
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    set ::els::docEol($id) $eol
    set ::els::docRaw($id) $raw
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
    set text [$w get 1.0 "end - 1 char"]
    # re-apply the document's original EOL (buffer is LF-internal)
    switch $::els::docEol($active) {
        crlf { set text [string map [list \n \r\n] $text] }
        cr   { set text [string map [list \n \r]   $text] }
    }
    # encode in the document's original encoding, restoring a BOM if it had one
    set bytes [encoding convertto -profile replace $::els::docEnc($active) $text]
    if {$::els::docBom($active)} {
        switch $::els::docEnc($active) {
            utf-8    { set bytes "\xEF\xBB\xBF$bytes" }
            utf-16le { set bytes "\xFF\xFE$bytes" }
            utf-16be { set bytes "\xFE\xFF$bytes" }
            utf-32le { set bytes "\xFF\xFE\x00\x00$bytes" }
            utf-32be { set bytes "\x00\x00\xFE\xFF$bytes" }
        }
    }
    if {[catch {
        set fh [::open $docPath($active) w]
        fconfigure $fh -translation binary
        puts -nonewline $fh $bytes
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

# ---- find / replace -----------------------------------------------------
proc els::build_findbar {} {
    ttk::frame .find -padding {8 0 8 6}

    ttk::frame .find.fr
    ttk::label .find.fr.l -text "Find" -font elsUI -width 7 -anchor w
    ttk::entry .find.fr.q -textvariable ::els::find_q -font elsUI
    ttk::checkbutton .find.fr.case  -text "Aa" -style Toolbutton -takefocus 0 \
        -variable ::els::find_case  -command els::find_update
    ttk::checkbutton .find.fr.word  -text "W"  -style Toolbutton -takefocus 0 \
        -variable ::els::find_word  -command els::find_update
    ttk::checkbutton .find.fr.regex -text ".*" -style Toolbutton -takefocus 0 \
        -variable ::els::find_regex -command els::find_update
    ttk::button .find.fr.help -text "?" -width 2 -takefocus 0 -command els::regex_help
    ttk::button .find.fr.prev -text "↑" -width 2 -takefocus 0 -command {els::find_step -1}
    ttk::button .find.fr.next -text "↓" -width 2 -takefocus 0 -command {els::find_step 1}
    ttk::label  .find.fr.n -textvariable ::els::find_count -font elsUI \
        -foreground $::els::MUTED -width 11 -anchor e
    ttk::button .find.fr.x -text "×" -width 2 -takefocus 0 -command els::find_hide
    grid .find.fr.l .find.fr.q .find.fr.case .find.fr.word .find.fr.regex .find.fr.help \
         .find.fr.prev .find.fr.next .find.fr.n .find.fr.x -row 0 -padx 1 -sticky we
    grid columnconfigure .find.fr 1 -weight 1
    els::tooltip .find.fr.case  "Match case"
    els::tooltip .find.fr.word  "Whole word"
    els::tooltip .find.fr.regex "Regular expression (Tcl ARE)"
    els::tooltip .find.fr.help  "Regex reference"
    els::tooltip .find.fr.prev  "Previous  (Shift+Enter)"
    els::tooltip .find.fr.next  "Next  (Enter)"

    ttk::frame .find.rr
    ttk::label .find.rr.l -text "Replace" -font elsUI -width 7 -anchor w
    ttk::entry .find.rr.r -textvariable ::els::find_r -font elsUI
    ttk::checkbutton .find.rr.adapt -text "Adapt case" -style Toolbutton -takefocus 0 \
        -variable ::els::find_adapt
    ttk::button .find.rr.rep -text "Replace" -takefocus 0 -command els::find_replace_one
    ttk::button .find.rr.all -text "All"     -takefocus 0 -command els::find_replace_all
    grid .find.rr.l .find.rr.r .find.rr.adapt .find.rr.rep .find.rr.all -row 0 -padx 1 -sticky we
    grid columnconfigure .find.rr 1 -weight 1
    els::tooltip .find.rr.adapt "Adapt case — make each replacement follow the case of the match"

    frame .find.top -height 1 -bg $::els::HAIR
    grid .find.top -row 0 -column 0 -sticky ew -pady {0 6}
    grid .find.fr -row 1 -column 0 -sticky ew
    grid .find.rr -row 2 -column 0 -sticky ew -pady {4 0}
    grid columnconfigure .find 0 -weight 1

    bind .find.fr.q <KeyRelease> {
        if {"%K" ni {Up Down}} { set ::els::find_hidx -1 ; els::find_schedule }
    }
    bind .find.fr.q <Return>       { els::find_history_push $::els::find_q
                                     els::find_step 1  ; break }
    bind .find.fr.q <Shift-Return> { els::find_step -1 ; break }
    bind .find.fr.q <Up>           { els::find_history_recall  1 ; break }
    bind .find.fr.q <Down>         { els::find_history_recall -1 ; break }
    bind .find.fr.q <Escape>       { els::find_hide    ; break }
    bind .find.rr.r <Return>       { els::find_replace_one ; break }
    bind .find.rr.r <Escape>       { els::find_hide    ; break }
}

# ---- find-bar polish: tooltips, flash, regex help, history --------------
proc els::tooltip {w text} {
    bind $w <Enter>      [list els::tip_schedule $w $text]
    bind $w <Leave>      els::tip_cancel
    bind $w <ButtonPress> els::tip_cancel
}
proc els::tip_schedule {w text} {
    els::tip_cancel
    set ::els::tip_after [after 550 [list els::tip_pop $w $text]]
}
proc els::tip_cancel {} {
    if {[info exists ::els::tip_after]} { after cancel $::els::tip_after ; unset ::els::tip_after }
    catch {destroy .tip}
}
proc els::tip_pop {w text} {
    catch {destroy .tip}
    if {![winfo exists $w]} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text $text -bg "#2B2B2B" -fg "#F0F0F0" -font elsUI -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set x [expr {[winfo rootx $w] + [winfo width $w]/2 - [winfo reqwidth .tip]/2}]
    set y [expr {[winfo rooty $w] + [winfo height $w] + 5}]
    wm geometry .tip +$x+$y
}

# briefly flash the search field red — used instead of a popup on no-match/wrap
proc els::find_flash {} {
    if {![winfo exists .find.fr.q]} { return }
    .find.fr.q configure -style Flash.TEntry
    after 150 { catch {.find.fr.q configure -style TEntry} }
}

# a compact, scannable Tcl ARE cheat-sheet (opened from the greyed-until-on "?")
proc els::regex_help {} {
    catch {destroy .rehelp}
    toplevel .rehelp
    wm title .rehelp "Regular expressions — Tcl ARE"
    wm transient .rehelp .
    catch {wm attributes .rehelp -topmost 1}
    ttk::frame .rehelp.f -padding 14
    pack .rehelp.f -fill both -expand 1
    ttk::label .rehelp.f.h -text "Tcl ARE — the syntax els searches with" \
        -font elsUI -foreground $::els::MUTED
    grid .rehelp.f.h -row 0 -column 0 -columnspan 2 -sticky w -pady {0 8}
    set rows {
        {.}           {any character}
        {[abc]}       {any one of these characters}
        {[^abc]}      {any character except these}
        {[a-z]}       {a range}
        {* + ?}       {0 or more,  1 or more,  0 or 1}
        {{n} {n,m}}   {exactly n  /  n to m times}
        {^ $}         {start / end of line}
        {\m \M}       {start / end of a word}
        {\w \d \s}    {word character / digit / whitespace}
        {( ... )}     {capture group}
        {\1 \2}       {backreference (use in Replace)}
        {a|b}         {a or b}
        {\\}          {a literal backslash}
    }
    set r 1
    foreach {tok desc} $rows {
        ttk::label .rehelp.f.t$r -text $tok  -font elsMono -foreground $::els::INK
        ttk::label .rehelp.f.d$r -text $desc -font elsUI   -foreground $::els::MUTED
        grid .rehelp.f.t$r -row $r -column 0 -sticky w -padx {0 22} -pady 1
        grid .rehelp.f.d$r -row $r -column 1 -sticky w -pady 1
        incr r
    }
    bind .rehelp <Escape> {destroy .rehelp}
    focus .rehelp
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .rehelp]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .rehelp]) / 3}]
    wm geometry .rehelp +$x+$y
}

proc els::find_history_push {term} {
    variable find_history ; variable find_hidx
    if {$term eq ""} { return }
    set find_history [linsert [lsearch -all -inline -not -exact $find_history $term] 0 $term]
    if {[llength $find_history] > 16} { set find_history [lrange $find_history 0 15] }
    set find_hidx -1
}
proc els::find_history_recall {dir} {
    variable find_history ; variable find_hidx
    set n [llength $find_history]
    if {$n == 0} { return }
    set i [expr {$find_hidx + $dir}]
    if {$i < 0}   { set find_hidx -1 ; return }   ;# back below newest: leave field as-is
    if {$i >= $n} { set i [expr {$n - 1}] }
    set find_hidx $i
    set ::els::find_q [lindex $find_history $i]
    .find.fr.q icursor end
    els::find_update
}

# Debounce incremental search: a burst of keystrokes runs ONE search after a
# short pause, so a full-buffer search never blocks the UI on every key.
proc els::find_schedule {} {
    variable find_after
    after cancel $find_after
    set find_after [after 130 els::find_update]
}

# escape ARE metacharacters so a literal string searches literally
proc els::re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

proc els::find_show {mode} {
    variable find_mode
    set find_mode $mode
    grid .find -row 2 -column 0 -columnspan 3 -sticky ew
    if {$mode eq "replace"} { grid .find.rr } else { grid remove .find.rr }
    set w [els::T]
    if {$w ne "" && [llength [$w tag ranges sel]]} {
        set s [$w get sel.first sel.last]
        if {$s ne "" && [string first \n $s] < 0} { set ::els::find_q $s }
    }
    els::find_update
    focus .find.fr.q
    .find.fr.q selection range 0 end
}

proc els::find_hide {} {
    variable find_mode
    set find_mode ""
    grid remove .find
    set w [els::T]
    if {$w ne ""} {
        $w tag remove findAll 1.0 end
        $w tag remove findOne 1.0 end
        focus $w
    }
}

# re-run the search in the active doc, tag all matches, pick the current one
proc els::find_update {} {
    variable find_q ; variable find_case ; variable find_word ; variable find_regex
    variable find_matches ; variable find_count
    set w [els::T]
    if {$w eq ""} { return }
    # the regex reference is reachable only while Regex is on
    catch {.find.fr.help configure -state [expr {$find_regex ? "normal" : "disabled"}]}
    $w tag remove findAll 1.0 end
    $w tag remove findOne 1.0 end
    set find_matches {}
    if {$find_q eq ""} { set find_count "" ; return }

    set useRegex $find_regex
    set pat $find_q
    if {$find_word} {
        set useRegex 1
        set p [expr {$find_regex ? $find_q : [els::re_escape $find_q]}]
        set pat "\\m$p\\M"
    }
    set sargs {-all}
    if {$useRegex}   { lappend sargs -regexp }
    if {!$find_case} { lappend sargs -nocase }
    if {[catch {set starts [$w search {*}$sargs -count ::els::find_lens -- $pat 1.0 end]}]} {
        set find_count "bad pattern" ; els::find_flash ; return
    }
    if {![llength $starts]} { set find_count "No results" ; els::find_flash ; return }

    set lens $::els::find_lens
    set i 0
    foreach s $starts {
        set e [$w index "$s + [lindex $lens $i] chars"]
        $w tag add findAll $s $e
        lappend find_matches [list $s $e]
        incr i
    }
    set n [llength $find_matches]
    set ins [$w index insert]
    set cur 0
    for {set j 0} {$j < $n} {incr j} {
        if {[$w compare [lindex [lindex $find_matches $j] 0] >= $ins]} { set cur $j ; break }
    }
    els::find_highlight $cur
}

proc els::find_highlight {idx} {
    variable find_matches ; variable find_current ; variable find_count
    set w [els::T]
    set n [llength $find_matches]
    if {$n == 0} { return }
    set idx [expr {($idx % $n + $n) % $n}]
    set find_current $idx
    $w tag remove findOne 1.0 end
    lassign [lindex $find_matches $idx] s e
    $w tag add findOne $s $e
    $w mark set insert $s
    $w see $s
    set find_count "[expr {$idx + 1}] of $n"
    els::update_pos
    els::update_current_line
}

proc els::find_step {dir} {
    variable find_matches ; variable find_current
    if {![llength $find_matches]} { els::find_update ; return }
    set n [llength $find_matches]
    set next [expr {$find_current + $dir}]
    if {$next < 0 || $next >= $n} { els::find_flash }   ;# wrapped around
    els::find_highlight $next
}

# Make a match's case template carry to its replacement (when Adapt case is on).
proc els::adapt_case {match repl} {
    if {!$::els::find_adapt || $match eq "" || ![regexp {[A-Za-z]} $match]} { return $repl }
    if {$match eq [string toupper $match]} { return [string toupper $repl] }
    if {$match eq [string tolower $match]} { return [string tolower $repl] }
    if {$match eq [string totitle $match]} { return [string totitle $repl] }
    return $repl
}
# The replacement text for the match at s..e: expands regex backreferences
# (\1, \2, …) when Regex is on, then applies adapt-case.
proc els::repl_for {w s e} {
    variable find_q ; variable find_r ; variable find_regex ; variable find_word ; variable find_case
    set matched [$w get $s $e]
    set repl $find_r
    if {$find_regex} {
        set pat [expr {$find_word ? "\\m$find_q\\M" : $find_q}]
        set fl {} ; if {!$find_case} { lappend fl -nocase }
        catch {regsub {*}$fl -- $pat $matched $find_r repl}
    }
    return [els::adapt_case $matched $repl]
}

proc els::find_replace_one {} {
    variable find_matches ; variable find_current
    set w [els::T]
    if {$w eq ""} { return }
    if {![llength $find_matches] || $find_current < 0} { els::find_step 1 ; return }
    lassign [lindex $find_matches $find_current] s e
    set repl [els::repl_for $w $s $e]
    $w edit separator
    $w replace $s $e $repl
    $w mark set insert "$s + [string length $repl] chars"
    els::find_update
}

proc els::find_replace_all {} {
    variable find_matches
    set w [els::T]
    if {$w eq "" || ![llength $find_matches]} { return }
    set n [llength $find_matches]
    $w edit separator
    foreach m [lreverse $find_matches] {
        lassign $m s e
        $w replace $s $e [els::repl_for $w $s $e]
    }
    $w edit separator
    els::find_update
    set ::els::find_count "Replaced $n"
}

# ---- go to line + whitespace --------------------------------------------
proc els::goto_line {} {
    set w [els::T]
    if {$w eq ""} { return }
    set max [els::line_count]
    set top .goto
    catch {destroy $top}
    toplevel $top -bg $::els::PAGE
    wm title $top "Go to Line"
    wm resizable $top 0 0
    wm transient $top .
    ttk::frame $top.f -padding 12
    ttk::label $top.f.l -text "Line (1 - $max):" -font elsUI
    ttk::entry $top.f.e -width 10 -font elsMono
    ttk::frame $top.f.b
    ttk::button $top.f.b.ok     -text "Go"     -command [list els::goto_do $top]
    ttk::button $top.f.b.cancel -text "Cancel" -command [list destroy $top]
    pack $top.f.b.ok $top.f.b.cancel -side left -padx 3
    grid $top.f.l -row 0 -column 0 -sticky w
    grid $top.f.e -row 0 -column 1 -padx 6 -sticky ew
    grid $top.f.b -row 1 -column 0 -columnspan 2 -pady {10 0}
    pack $top.f
    bind $top.f.e <Return> [list els::goto_do $top]
    bind $top <Escape> [list destroy $top]
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth  $top]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $top]) / 3}]
    wm geometry $top +$x+$y
    focus $top.f.e
    catch {grab $top}
}
proc els::goto_do {top} {
    set w [els::T]
    set ln [string trim [$top.f.e get]]
    if {$w ne "" && [string is integer -strict $ln] && $ln >= 1} {
        set ln [expr {min($ln, [els::line_count])}]
        $w mark set insert $ln.0
        $w see $ln.0
        els::refresh_view
    }
    destroy $top
    if {$w ne ""} { focus $w }
}

# highlight tabs + trailing whitespace in the active doc (when Show Whitespace
# is on).  Tk's Text widget can't substitute glyphs, so we reveal whitespace by
# tagging it rather than drawing · / → marks.
proc els::ws_refresh {} {
    set w [els::T]
    if {$w eq ""} { return }
    $w tag remove wsTab   1.0 end
    $w tag remove wsTrail 1.0 end
    if {!$::els::show_ws} { return }
    set i 0
    foreach s [$w search -all -regexp -count ::els::ws_lens -- {\t+} 1.0 end] {
        $w tag add wsTab $s "$s + [lindex $::els::ws_lens $i] chars" ; incr i
    }
    set i 0
    foreach s [$w search -all -regexp -count ::els::ws_lens2 -- {[ \t]+$} 1.0 end] {
        $w tag add wsTrail $s "$s + [lindex $::els::ws_lens2 $i] chars" ; incr i
    }
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
    puts $out "detect=$::els::have_detect"
    set dstate ""
    foreach id $::els::docs { append dstate "$id:[els::doc_dirty $id] " }
    puts $out "doc_dirty=[string trimright $dstate]"
    puts $out "open=$openok"
    close $out
    after 150 {exit}
}

# load the optional ICU charset detector (chardet-quality auto-detection); a
# missing DLL just leaves have_detect 0 and els falls back to BOM/UTF-8/cp1252
catch { set ::els::have_detect [els::load_detect] }

# run the UI only when executed as the main script, not when sourced by tests
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    els::main
}
