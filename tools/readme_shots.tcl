# tools/readme_shots.tcl -- regenerate README screenshots with staged UI states.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

set ROOT [script_root]
set TMP  [file join $ROOT tests _tmp readme_shots]
set OUT  [file join $ROOT docs img]

# wish + tclsh come from zmal's shared runtime, passed in by `z readme-shots`
# (els carries no private .toolchain).  twapi is found by shot.tcl via the
# TCLLIBPATH this process already inherits from the z front door.
set WISH  [lindex $argv 0]
set TCLSH [lindex $argv 1]
if {$WISH eq "" || $TCLSH eq ""} { error "usage: readme_shots.tcl <wish> <tclsh>" }

proc write_file {path bytes} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -encoding utf-8 -translation lf
    puts -nonewline $f $bytes
    close $f
    return $path
}

proc capture {scene out {title ""}} {
    set tclsh $::TCLSH
    set wish  $::WISH
    set shot  [file join $::ROOT tools shot.tcl]
    set wrap  [file join $::TMP readme_scene.tcl]
    set cmd [list $tclsh $shot $wish $wrap [file join $::OUT $out] $scene]
    puts "capturing $out"
    set old [pwd]
    set hadTitle [info exists ::env(ELS_SHOT_TITLE)]
    if {$hadTitle} { set oldTitle $::env(ELS_SHOT_TITLE) }
    set changedTitle [expr {$title ne ""}]
    if {$changedTitle} { set ::env(ELS_SHOT_TITLE) $title }
    cd $::ROOT
    if {[catch {exec {*}$cmd 2>@1} result]} {
        cd $old
        if {$changedTitle} {
            if {$hadTitle} { set ::env(ELS_SHOT_TITLE) $oldTitle } else { unset ::env(ELS_SHOT_TITLE) }
        }
        puts $result
        error "capture failed for $scene"
    }
    cd $old
    if {$changedTitle} {
        if {$hadTitle} { set ::env(ELS_SHOT_TITLE) $oldTitle } else { unset ::env(ELS_SHOT_TITLE) }
    }
    puts $result
}

file delete -force $TMP
file mkdir $TMP $OUT

write_file [file join $TMP notes.txt] {Notes before the rain

The little blue notebook is missing again.
Try the windowsill, the coat pocket, or the shelf with the teacups.

Keep:
  fresh pencils
  spare stamps
  the good idea from Tuesday
}

write_file [file join $TMP errands.txt] {A Small List for Thursday

Buy apples with opinions.
Return the library book about clouds.
Sharpen three pencils.
Write down the sentence before it wanders off.

Later:
  make soup
  sort the drawer marked "almost"
  leave room on the page
}

write_file [file join $TMP spacing.txt] "Two  spaces  between  words.\n    four-space indent here\n\t tab-indented line\nline with trailing spaces    \njust normal single spaces ok\n"

write_file [file join $TMP focus.txt] {On writing in a quiet room

A plain page asks for nothing.
No ribbons, no blinking, no small badges begging to be cleared.
You set down one sentence, then the next, and the room stays quiet.

Focus mode dims every line but the one you are on:
the paragraph ahead waits in patient grey,
and the sentence under your hands is the only one in ink.

A small trick, an old one, and it works.
}

write_file [file join $TMP els.conf] [dict create geometry 960x640+80+80 \
    recent {} word_wrap 0 restore_session 0 session_files {} session_active ""]

set wrapper [string map [list @ROOT@ [file normalize $ROOT] @TMP@ [file normalize $TMP]] {
set ::README_ROOT {@ROOT@}
set ::README_TMP  {@TMP@}
set ::README_SCENE [lindex $argv 0]
set ::argv {}

source [file join $::README_ROOT els.tcl]

proc readme_file {name} {
    return [file join $::README_TMP $name]
}

proc readme_stage_editor {} {
    wm geometry . 960x640+80+80
    els::open [readme_file notes.txt]
    els::open [readme_file errands.txt]
    set w [els::T]
    $w mark set insert 5.34
    $w see 1.0
    focus $w
    els::refresh_view
}

proc readme_stage_find {} {
    wm geometry . 960x620+90+90
    els::open [readme_file spacing.txt]
    set ::els::show_ws 1
    set ::els::find_q "space"
    set ::els::find_r "gap"
    set ::els::find_case 0
    set ::els::find_word 0
    set ::els::find_regex 0
    set ::els::find_adapt 1
    els::find_show replace
    catch {.find.fr.q selection clear}
    els::ws_refresh
    els::find_update
}

proc readme_stage_about {} {
    wm geometry . 720x520+100+100
    els::about
    update idletasks
}

proc readme_stage_focus {} {
    wm geometry . 960x640+80+80
    els::open [readme_file focus.txt]
    set w [els::T]
    set ::els::focus_mode 1
    # caret on the "only one in ink" line: it stays ink-black while every other
    # line dims to grey — exactly what Focus Mode does
    $w mark set insert 9.30
    els::set_focus_mode 0     ;# apply the dimming (persist 0 — don't touch config)
    $w see 1.0
    focus $w
    els::refresh_view
}

proc readme_stage {} {
    switch -- $::README_SCENE {
        editor { readme_stage_editor }
        find   { readme_stage_find }
        about  { readme_stage_about }
        focus  { readme_stage_focus }
        default { error "unknown README screenshot scene: $::README_SCENE" }
    }
    update idletasks
    update
}

# Read the staged config from this temp dir instead of the developer's real
# els.conf (next-to-program / %LOCALAPPDATA%): pinning config_path before main
# skips first-run resolution and the location dialog, so the screenshots show a
# clean, deterministic session rather than whatever tabs, recent files, or window
# geometry the developer's own config happens to hold.
set ::els::config_path [file join $::README_TMP els.conf]
els::main
after 220 readme_stage
}]
write_file [file join $TMP readme_scene.tcl] $wrapper

capture editor editor-whimsy.png
capture find find-whitespace.png
capture about about.png "About els"
capture focus focus-mode.png
