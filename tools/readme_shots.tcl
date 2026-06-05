# tools/readme_shots.tcl -- regenerate README screenshots with staged UI states.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

set ROOT [script_root]
set TMP  [file join $ROOT tests _tmp readme_shots]
set OUT  [file join $ROOT docs img]

proc write_file {path bytes} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -translation binary
    puts -nonewline $f $bytes
    close $f
    return $path
}

proc tool {name} {
    return [file join $::ROOT .toolchain tcl9 bin $name]
}

proc capture {scene out {title ""}} {
    set tclsh [tool tclsh90.exe]
    set wish  [tool wish90.exe]
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

proc readme_stage {} {
    switch -- $::README_SCENE {
        editor { readme_stage_editor }
        find   { readme_stage_find }
        about  { readme_stage_about }
        default { error "unknown README screenshot scene: $::README_SCENE" }
    }
    update idletasks
    update
}

els::main
after 220 readme_stage
}]
write_file [file join $TMP readme_scene.tcl] $wrapper

capture editor editor-whimsy-0.20.png
capture find find-whitespace-0.20.png
capture about about-0.20.png "About els"
