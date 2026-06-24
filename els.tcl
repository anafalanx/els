#!/usr/bin/env wish
# els — a tiny, focused text editor.  Tcl/Tk 9 edition.
#
# This is the rewrite of the C23/Lua els (which shipped through v0.3, archived
# in ../els-c).  Tk's Text widget is the buffer; Tcl/Tk supplies the UI runtime.
# Design language carried over from v0.3: calm grey page, the signature red
# caret, restrained chrome, opinionated (few knobs).
#
# Multi-file model: one Text widget per open document (each keeps its own undo
# stack, selection and modified state, free from Tk).  A shared gutter,
# scrollbar and status bar re-point to whichever document is active.  A custom
# flat tab strip switches between them.

package require Tk

namespace eval els {
    variable version "0.71"      ;# statusbar fixes: redundant path tooltip + narrow-window flicker
    variable docs {}             ;# ordered list of open document ids
    variable active ""           ;# active document id ("" = none)
    variable seq 0               ;# monotonic id counter
    variable iconImage ""
    variable iconImages {}
    variable iconPath ""
    variable iconLoaded 0
    variable selftest [expr {[lindex $::argv 0] eq "--selftest"}]
    variable docPath             ;# array: id -> file path ("" = untitled)
    array set docPath {}
    variable docEnc ; array set docEnc {}   ;# id -> Tcl encoding (utf-8, utf-16le, ...)
    variable docBom ; array set docBom {}   ;# id -> 1 if a byte-order mark was present
    variable docEol ; array set docEol {}   ;# id -> lf | crlf | cr
    variable docRaw ; array set docRaw {}   ;# id -> exact bytes as loaded ("" = never from disk)
    variable docRecovered ; array set docRecovered {}  ;# id -> 1 if this tab is crash-recovered (unsaved)
    variable docLossyOk   ; array set docLossyOk {}    ;# id -> user accepted lossy saves (this session)
    variable docLossyPause; array set docLossyPause {} ;# id -> auto-save paused (unencodable chars)
    variable status_note_after ""   ;# transient statusbar note timer
    variable autosave 0             ;# File ▸ Auto-save (opt-in, persisted)
    variable autosave_after ""      ;# debounced auto-save flush timer
    variable autosave_pending {}    ;# doc ids awaiting the debounced flush
    variable backups 1              ;# File ▸ Keep Backups (on by default, persisted)
    variable BK_RING 8              ;# previous versions kept per file
    variable BK_MININT 60           ;# s: skip a backup if the newest is this fresh
    variable BK_MAXAGE 2592000      ;# s: prune backups older than 30 days
    variable BK_MAXSIZE 20971520    ;# bytes: don't back up files larger than 20 MB
    # ---- crash-recovery / autosave subsystem (R2 / docs robustness P0-b) ----
    # A swap file per dirty doc under <configdir>/swap/, written atomically and
    # often, so a crash / power-loss / kill never loses unsaved edits; on the next
    # launch, orphaned swaps (from a dead session) are offered for non-destructive
    # recovery.  Liveness is a held Win32 byte-range lock (released by the OS on
    # process death) so a live peer's swaps are never stolen.  See the spec in the
    # crash-recovery design pass.
    variable swap_enabled      1    ;# master switch (the test harness turns it off)
    variable swap_test_mtime   0    ;# test seam: force the pure-Tcl mtime liveness path
    variable swap_after        ""   ;# after-id of the periodic tick ("" = stopped)
    variable swap_touch_after  ""   ;# after-id of the debounced first-touch flush
    variable swap_interval     2000 ;# periodic tick period (ms)
    variable swap_debounce     400  ;# debounce after an edit (ms)
    variable swap_suspend      0    ;# re-entrancy guard: 1 while a modal pump / recovery runs
    variable swap_tick_count   0
    variable session_id_cached    ""
    variable session_token_cached ""
    variable lock_handle ""         ;# non-empty once the native lock is held
    variable lock_chan   ""         ;# pure-Tcl fallback: a held channel ("" = none)
    variable probe_quiet 0          ;# probe mode: alpha-0 every toplevel (no desktop flash)
    variable handoff_after ""       ;# primary's handoff-spool poll (single-instance)
    variable last_recover 0         ;# count from the last startup recovery scan (probe/report)
    variable recover_auto 0         ;# test/probe seam: auto-apply recovery instead of dialog
    variable recover_claims {}      ;# .claimed markers created by THIS session's scan
    variable swapSig    ; array set swapSig    {}  ;# id -> last-written buffer sig "chars:crc"
    variable savedSig   ; array set savedSig   {}  ;# id -> on-disk file sig "size:mtime:crc" ("" untitled)
    variable dirtySince ; array set dirtySince {}  ;# id -> 1 if edited since last successful swap
    variable loading    ; array set loading    {}  ;# id -> 1 while open/recovery mutate identity
    variable SWAP_SIG_FULL_CAP  4194304    ;# chars: above this an idle dirty doc reuses its cached sig
    variable SWAP_FILE_CRC_CAP  16777216   ;# bytes: above this a file sig uses a sampled (head+tail) crc
    variable STALE_SECS         45         ;# fallback liveness / litter staleness window (s)
    variable HEARTBEAT_EVERY    3          ;# bump the lock mtime every Nth tick
    # charset detection (chardet quality via the system ICU; 0 until loaded)
    variable have_detect 0
    variable DETECT_MIN  15      ;# ignore ICU guesses below this confidence (0-100)
    # curated encodings for the status-bar picker: {label encoding bom} triples,
    # "-" marks a separator.  "Other (all)" exposes every Tcl encoding.
    variable ENC_CURATED {
        "UTF-8"                       utf-8      0
        "UTF-8 with BOM"              utf-8      1
        "UTF-16 LE"                   utf-16le   0
        "UTF-16 LE with BOM"          utf-16le   1
        "UTF-16 BE"                   utf-16be   0
        "UTF-16 BE with BOM"          utf-16be   1
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
    variable find_regex 0        ;# regular expression mode
    variable find_mode ""        ;# "" hidden | find | replace
    variable find_matches {}     ;# list of {start end} index pairs in the active doc
    variable find_current -1     ;# index into find_matches
    variable find_count ""       ;# status text e.g. "3 of 12"
    variable find_adapt 0        ;# adapt-case replace (replacement follows the match's case)
    variable find_history {}     ;# recent search terms, newest first (cap 16)
    variable find_hidx -1        ;# position while cycling history with Up/Down
    variable show_ws 0           ;# View ▸ Show Whitespace
    variable show_linenos 1      ;# View ▸ Line Numbers (persisted)
    variable recent_vs_after ""  ;# deferred recent-list scrollbar show/hide
    variable word_wrap 0         ;# View ▸ Word Wrap (soft-wrap long lines)
    variable always_on_top 0     ;# View ▸ Always on Top (wm -topmost)
    variable font_size 11        ;# document text size (points); the family is fixed
    variable vs_shown -1         ;# vertical scrollbar visibility (auto-hidden when content fits)
    variable vs_after ""         ;# pending (idle) vertical scrollbar-visibility update
    variable hs_shown -1         ;# horizontal scrollbar visibility (only when wrap off + long lines)
    variable hs_after ""         ;# pending (idle) horizontal scrollbar-visibility update
    variable find_after ""       ;# pending (debounced) incremental search
    variable find_scan_doc ""    ;# doc id the cached matches were scanned in
    variable find_scan_chars -1  ;# buffer char count at scan time (staleness probe)
    variable ws_after ""         ;# pending (debounced) whitespace return-marker update
    variable tab_tip_delay 1000  ;# tabs are crossed often; let their tips breathe
    variable recent {}           ;# recently-opened file paths, newest first
    variable recent_cap 12       ;# how many recent files to keep
    variable restore_session 1   ;# reopen file-backed tabs from the previous run
    variable session_files {}     ;# file-backed tabs saved from the previous run
    variable session_active ""    ;# active file path saved from the previous run
    variable session_owned 0      ;# 1 once THIS run adopted the saved session: an
                                  ;# explicit-file-arg launch never adopted it, so
                                  ;# persisting its own doc list would destroy the
                                  ;# stored multi-tab session
    variable config_path ""      ;# resolved els.conf path ("" until resolved)
    variable cfg_radio appdata   ;# first-run location dialog selection
    variable gutter_px -1        ;# last-set gutter canvas width (px); -1 = unset
    variable gutter_after ""     ;# coalesced gutter-redraw after token
    variable refresh_after ""    ;# coalesced full-view refresh (resize bursts)
    variable tp_zoom_acc 0       ;# accumulated Ctrl+touchpad zoom delta
    variable recent_row_tip -1   ;# recent-list row whose hover tip is active
    variable recent_sel_path ""  ;# Maintain List selection, tracked by PATH
    variable boot_script ""      ;# path of this file at source time (see below)
}
# Capture the script path NOW, while a `source` is active: `info script` is only
# valid during sourcing and returns "" from later event/callback contexts, so we
# remember it here to locate the running els.exe reliably (see association_exe).
set ::els::boot_script [info script]

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
set ::els::WSSPACE "#E2E2E2"     ;# a lone space — light grey (subtle; spaces are everywhere)
set ::els::WSTAB   "#D3E1F5"     ;# tabs — light blue
set ::els::WSTRAIL "#E9D9F1"     ;# 2+ spaces or trailing whitespace — light mauve
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsMonoHelp -family Consolas -size 10
font create elsUI   -family {Segoe UI} -size 9
font create elsUIb  -family {Segoe UI} -size 9 -weight bold   ;# section headers
font create elsTitle -family {Segoe UI Light} -size 40   ;# the About wordmark
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
    set imgs {}
    foreach {name file} {
        elsIcon16 icon16.png
        elsIcon32 icon32.png
        elsIcon   icon.png
    } {
        set p [els::find_resource resources $file]
        if {$p eq ""} { continue }
        catch {image delete $name}
        if {[catch {image create photo $name -file $p} img]} { continue }
        lappend imgs $img
        if {$file eq "icon.png"} {
            set ::els::iconImage $img
            set ::els::iconPath $p
        }
    }
    if {![llength $imgs]} { return }
    set ::els::iconImages $imgs
    set ::els::iconLoaded 1
    wm iconphoto . -default {*}$imgs
}
# ---- config location ----------------------------------------------------
# els keeps a tiny settings dict (window geometry + recent files) in one
# els.conf.  It is sought next to the program first (portable), then under
# %LOCALAPPDATA%\els.  On first run (neither exists) the user picks which.
proc els::config_roots {} {
    # "next to the program" = the exe's folder when packaged, the script's
    # folder (the repo) in a dev run.
    if {[string match "//zipfs:*" [info script]]} {
        set progdir [file dirname [info nameofexecutable]]
    } else {
        set progdir [file dirname [file normalize [info script]]]
    }
    if {[info exists ::env(LOCALAPPDATA)] && $::env(LOCALAPPDATA) ne ""} {
        set la $::env(LOCALAPPDATA)
    } else {
        # Tcl 9 removed tilde expansion (TIP 602): `file normalize ~` returns a
        # literal cwd-relative "~" path.  `file home` is the replacement.
        set la [file join [file home] AppData Local]
    }
    return [list $progdir [file join $la els]]
}
proc els::config_candidates {{name els.conf}} {
    lassign [els::config_roots] near appdata
    return [list [file join $near $name] [file join $appdata $name]]
}
proc els::config_legacy_candidates {} {
    return [els::config_candidates config.tcl]
}
proc els::config_file {} { return $::els::config_path }
# Single choke point for resolving the config location: the instant the dir is
# known, hold the session lock and start autosave -- so edits are protected even
# before the first save or a session restore.
proc els::set_config_path {p} {
    set ::els::config_path $p
    if {$p ne "" && !$::els::selftest} {
        catch {file mkdir [file dirname $p]}
        els::lock_acquire
        els::swap_start
        els::handoff_start   ;# become the primary: poll for handed-off files
    }
}
# Point config_path at whichever location already holds a config; 1 if found,
# 0 if this looks like a first run (neither location exists yet).
proc els::config_resolve_existing {} {
    lassign [els::config_candidates] near appdata
    if {[file exists $near]}    { els::set_config_path $near    ; return 1 }
    if {[file exists $appdata]} { els::set_config_path $appdata ; return 1 }
    lassign [els::config_legacy_candidates] oldNear oldAppdata
    foreach {old new} [list $oldNear $near $oldAppdata $appdata] {
        if {![file exists $old]} { continue }
        els::set_config_path $new
        if {![file exists $new]} {
            catch {
                file mkdir [file dirname $new]
                file copy -force $old $new
            }
        }
        return 1
    }
    return 0
}
# First run: ask where to keep settings.  The dialog is callback-driven (NOT a
# modal vwait): a vwait entered from this startup `after` deadlocks the packaged
# single-exe before its main window is ever mapped.  config_apply_choice does
# the work when the user clicks Continue.
proc els::config_first_run {} {
    lassign [els::config_candidates] near appdata
    if {$::els::selftest} { set ::els::config_path $appdata ; return }
    els::config_choice_dialog $near $appdata
}
proc els::config_postpone_choice {top} {
    catch {grab release $top}
    catch {destroy $top}
}
proc els::config_apply_choice {near appdata} {
    els::set_config_path [expr {$::els::cfg_radio eq "near" ? $near : $appdata}]
    els::save_geometry
    catch {grab release .cfgask}
    catch {destroy .cfgask}
    after idle [list els::recover_boot 0]   ;# no orphans on a true first run; harmless
}
proc els::config_choice_dialog {near appdata} {
    set ::els::cfg_radio appdata
    set top .cfgask
    catch {destroy $top}
    toplevel $top -bg $::els::PAGE
    # probe runs assert ismapped, so hide via alpha (like the root), not withdraw
    if {$::els::probe_quiet} { catch {wm attributes $top -alpha 0.0} }
    wm title $top "Welcome to els"
    wm transient $top .
    wm resizable $top 0 0
    set apply [list els::config_apply_choice $near $appdata]
    # closing the dialog is a POSTPONE, not consent: it used to run $apply and
    # silently adopt the default location as if Continue had been clicked.
    # Postponing leaves config_path unset for this session (no config written,
    # autosave/recovery stay off) and the choice is asked again next launch.
    wm protocol $top WM_DELETE_WINDOW [list els::config_postpone_choice $top]
    bind $top <Escape> [list els::config_postpone_choice $top]
    ttk::frame $top.f -padding 20 ; pack $top.f
    ttk::label $top.f.h -text "Where should els keep its settings?" \
        -font elsUIb -foreground $::els::INK
    ttk::label $top.f.s -justify left -font elsUI -foreground $::els::MUTED \
        -text "Your window size, recent files and preferences live in one small\nconfig file. Choose where to keep it."
    grid $top.f.h -row 0 -column 0 -sticky w -pady {0 3}
    grid $top.f.s -row 1 -column 0 -sticky w -pady {0 16}
    ttk::radiobutton $top.f.r1 -text "In your user profile (recommended)" \
        -value appdata -variable ::els::cfg_radio
    ttk::label $top.f.p1 -text [file nativename $appdata] -font elsUI -foreground $::els::MUTED
    ttk::radiobutton $top.f.r2 -text "Next to els (portable)" \
        -value near -variable ::els::cfg_radio
    ttk::label $top.f.p2 -text [file nativename $near] -font elsUI -foreground $::els::MUTED
    grid $top.f.r1 -row 2 -column 0 -sticky w
    grid $top.f.p1 -row 3 -column 0 -sticky w -padx {24 0} -pady {0 10}
    grid $top.f.r2 -row 4 -column 0 -sticky w
    grid $top.f.p2 -row 5 -column 0 -sticky w -padx {24 0} -pady {0 18}
    ttk::button $top.f.ok -text "Continue" -command $apply
    grid $top.f.ok -row 6 -column 0 -sticky e
    # route <Return> through the button's -command: $apply as a BIND script
    # would get %-substituted, so a "%" in the install path (legal on Windows)
    # corrupted where the config/swap dir lands when confirming with Enter
    bind $top <Return> [list $top.f.ok invoke]
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth  $top]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $top]) / 3}]
    wm geometry $top +$x+$y
    catch {grab $top}
}
# els persists a tiny config dict (geometry + recent).  Readers/writers tolerate
# an empty/unset path, a missing file, or missing keys (forward/back compat).
proc els::load_geometry {} {
    set f [els::config_file]
    if {$f eq "" || ![file exists $f]} { return }
    if {[catch {
        set fh [::open $f r]
        set data [read $fh]
        close $fh
    }]} { return }
    # Per-VALUE validation, not just per-key fetch guards: els.conf is a plain
    # text file (hand-editable, sync-corruptible), and an invalid value used to
    # throw out of build before any widget existed — els could not start again
    # until the user found and deleted the config.  Readers tolerate anything.
    if {![catch {dict get $data geometry} g] && \
        [regexp {^[0-9]+x[0-9]+([+-][0-9]+[+-][0-9]+)?$} $g]} {
        catch {wm geometry . $g}
    }
    if {![catch {dict get $data recent} r]} {
        catch {set ::els::recent [els::recent_sanitize $r]}
    }
    if {![catch {dict get $data word_wrap} w] && [string is boolean -strict $w]} {
        set ::els::word_wrap [expr {$w ? 1 : 0}]
        if {[info exists ::els::docs] && [llength $::els::docs]} {
            catch {els::set_wrap 0}
        }
    }
    if {![catch {dict get $data show_whitespace} ws] && [string is boolean -strict $ws]} {
        set ::els::show_ws [expr {$ws ? 1 : 0}]
        if {[info exists ::els::docs] && [llength $::els::docs]} {
            catch {els::ws_refresh}
        }
    }
    if {![catch {dict get $data line_numbers} lnv] && [string is boolean -strict $lnv]} {
        set ::els::show_linenos [expr {$lnv ? 1 : 0}]
        catch {els::set_linenos 0}
    }
    if {![catch {dict get $data autosave} asv] && [string is boolean -strict $asv]} {
        set ::els::autosave [expr {$asv ? 1 : 0}]
    }
    if {![catch {dict get $data backups} bkv] && [string is boolean -strict $bkv]} {
        set ::els::backups [expr {$bkv ? 1 : 0}]
    }
    if {![catch {dict get $data always_on_top} t] && [string is boolean -strict $t]} {
        set ::els::always_on_top [expr {$t ? 1 : 0}]
        catch {els::set_always_on_top 0}
    }
    if {![catch {dict get $data font_size} fs] && [string is integer -strict $fs]} {
        catch {els::set_font_size $fs 0}   ;# apply the saved zoom (no re-persist)
    }
    if {![catch {dict get $data restore_session} rs] && [string is boolean -strict $rs]} {
        set ::els::restore_session [expr {$rs ? 1 : 0}]
    }
    if {![catch {dict get $data session_files} sf]} {
        catch {set ::els::session_files [els::session_sanitize $sf]}
    }
    if {![catch {dict get $data session_active} sa]} {
        catch {set ::els::session_active [els::session_path $sa]}
    }
}
proc els::save_geometry {} {
    if {$::els::selftest} { return }
    set f [els::config_file]
    if {$f eq ""} { return }
    # Build the whole payload BEFORE touching the file: a throw in any value
    # command (e.g. `wm geometry .` on a window being torn down at quit) must not
    # leave a truncated, empty config behind.
    if {[catch {
        if {$::els::session_owned} {
            set sf [els::session_current_files]
            set sa [els::session_current_active]
        } else {
            # this run never adopted the saved session (an explicit-file-arg
            # launch skips session restore): write the STORED session back —
            # persisting this run's doc list would destroy the user's
            # multi-tab session just by double-clicking one file
            set sf $::els::session_files
            set sa $::els::session_active
        }
        set payload [dict create geometry [wm geometry .] \
                         recent $::els::recent word_wrap $::els::word_wrap \
                         show_whitespace $::els::show_ws \
                         line_numbers $::els::show_linenos \
                         autosave $::els::autosave \
                         backups $::els::backups \
                         always_on_top $::els::always_on_top \
                         font_size $::els::font_size \
                         restore_session $::els::restore_session \
                         session_files $sf \
                         session_active $sa]
    }]} { return }
    # Write to a temp file then atomically rename, so a crash mid-write cannot
    # corrupt the existing config either.  pid-tagged temp: concurrent els
    # instances sharing the config dir must not publish each other's
    # half-written file through a fixed temp name.
    set tmp "$f.[pid].tmp"
    if {[catch {
        file mkdir [file dirname $f]
        set fh [::open $tmp w]
        try { puts $fh $payload } finally { close $fh }
        file rename -force $tmp $f
    }]} { catch {file delete -force $tmp} ; return }
}

proc els::session_path {p} {
    if {$p eq ""} { return "" }
    if {[catch {file normalize $p} n]} { return "" }
    return $n
}
proc els::same_path {a b} {
    set pa [els::session_path $a]
    set pb [els::session_path $b]
    if {$pa eq "" || $pb eq ""} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} {
        return [string equal -nocase $pa $pb]
    }
    return [string equal $pa $pb]
}
proc els::session_sanitize {list} {
    set out {}
    foreach p $list {
        set n [els::session_path $p]
        if {$n eq "" || $n in $out} { continue }
        lappend out $n
    }
    return $out
}
proc els::session_current_files {} {
    set out {}
    foreach id $::els::docs {
        if {![info exists ::els::docPath($id)]} { continue }
        set p [els::session_path $::els::docPath($id)]
        if {$p eq "" || $p in $out} { continue }
        lappend out $p
    }
    return $out
}
proc els::session_current_active {} {
    if {$::els::active eq "" || ![info exists ::els::docPath($::els::active)]} {
        return ""
    }
    return [els::session_path $::els::docPath($::els::active)]
}
proc els::session_set_restore {} {
    els::save_geometry
}

# ---- recent files -------------------------------------------------------
# A small MRU list under File ▸ Open Recent, persisted with the config.  The
# menu opens files quickly; a separate manager handles cleanup so the menu stays
# light instead of growing a removal submenu.
proc els::recent_sanitize {list} {
    set out {}
    foreach p $list {
        if {$p eq "" || $p in $out} { continue }
        lappend out $p
        if {[llength $out] >= $::els::recent_cap} { break }
    }
    return $out
}
proc els::recent_add {p} {
    if {$p eq ""} { return }
    set p [file normalize $p]
    set rest [lsearch -all -inline -not -exact $::els::recent $p]
    set ::els::recent [els::recent_sanitize [linsert $rest 0 $p]]
    els::recent_rebuild
    els::save_geometry
    # the Maintain List dialog is modeless and maps row indices into THIS list:
    # without a refresh (it no-ops when closed), every action past the
    # insertion point — Remove, Open, the detail label, the hover tip — acted
    # on a DIFFERENT file than the row displayed
    els::recent_manage_refresh
}
proc els::recent_remove {p} {
    set ::els::recent [lsearch -all -inline -not -exact $::els::recent $p]
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
proc els::recent_clear {} {
    set ::els::recent {}
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
# Open a recent entry; returns the document id, or "" when nothing was opened
# (missing file, or els::open failed — unreadable/directory/permission).
proc els::recent_open {p} {
    if {[winfo exists .recent]} { set par .recent } else { set par . }
    if {![file exists $p]} {
        set ans [tk_messageBox -parent $par -icon question -type yesno -title els \
            -message "This file no longer exists:\n[els::display_path $p]\n\nRemove it from the list?"]
        if {$ans eq "yes"} { els::recent_remove $p }
        return ""
    }
    return [els::open $p]
}
# Elide a path to at most `max` characters in the SAME style as els::elide_path
# (keep the filename, drop leading directories behind a leading "…/"), but by
# character budget rather than pixel width — for places without a measurable
# width, like a menu label.
proc els::elide_path_chars {p max} {
    set p [els::strip_ext_prefix $p]
    if {[string length $p] <= $max} { return $p }
    set parts [file split $p]
    set best ""
    for {set i [expr {[llength $parts] - 1}]} {$i >= 0} {incr i -1} {
        set tail [file join {*}[lrange $parts $i end]]
        set cand [expr {$i == 0 ? $tail : "…/$tail"}]
        if {[string length $cand] <= $max} { set best $cand } else { break }
    }
    if {$best ne ""} { return $best }
    # even the filename alone is too long — clip its head, keep the end
    set s [file tail $p]
    if {[string length $s] > $max - 1} { set s [string range $s end-[expr {$max - 2}] end] }
    return "…$s"
}
# A compact Open-Recent menu label: same elision style as the status bar and the
# recent-files window (filename kept, leading dirs dropped behind "…/").
proc els::recent_label {p} {
    return [els::elide_path_chars $p 64]
}
proc els::recent_rebuild {} {
    set m .menu.file.recent
    if {![winfo exists $m]} { return }
    $m delete 0 end
    if {![llength $::els::recent]} {
        $m add command -label "(empty)" -state disabled
    } else {
        foreach p $::els::recent {
            $m add command -label [els::recent_label $p] -command [list els::recent_open $p]
        }
    }
    $m add separator
    $m add command -label "Maintain List..." -command els::recent_manage
}
proc els::recent_manage {} {
    catch {destroy .recent}
    toplevel .recent -bg $::els::PAGE
    wm withdraw .recent
    wm title .recent "Recent Files"
    wm transient .recent .
    set bg $::els::PAGE
    ttk::frame .recent.f -padding 18
    pack .recent.f -fill both -expand 1
    ttk::label .recent.f.h -text "Recent Files" -font elsUIb -foreground $::els::INK
    ttk::label .recent.f.s -text "Open, remove, or clean up missing entries." \
        -font elsUI -foreground $::els::MUTED
    grid .recent.f.h -row 0 -column 0 -columnspan 3 -sticky w
    grid .recent.f.s -row 1 -column 0 -columnspan 3 -sticky w -pady {2 12}

    listbox .recent.f.list -font elsUI -height 10 -activestyle none \
        -borderwidth 0 -highlightthickness 1 -highlightbackground $::els::HAIR \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -bg $bg -fg $::els::INK -yscrollcommand els::recent_vs
    ttk::scrollbar .recent.f.vs -orient vertical -command {.recent.f.list yview}
    grid .recent.f.list -row 2 -column 0 -columnspan 2 -sticky nsew
    grid .recent.f.vs   -row 2 -column 2 -sticky ns

    ttk::label .recent.f.path -text "" -font elsUI -foreground $::els::MUTED -anchor w
    grid .recent.f.path -row 3 -column 0 -columnspan 3 -sticky ew -pady {8 14}

    ttk::frame .recent.f.buttons
    grid .recent.f.buttons -row 4 -column 0 -columnspan 3 -sticky ew
    ttk::button .recent.f.buttons.open -text Open -style Dialog.TButton -command els::recent_manage_open
    ttk::button .recent.f.buttons.remove -text Remove -style Dialog.TButton -command els::recent_manage_remove
    ttk::button .recent.f.buttons.missing -text "Remove Missing" -style Dialog.TButton -command els::recent_manage_remove_missing
    ttk::button .recent.f.buttons.clear -text Clear -style Dialog.TButton -command els::recent_manage_clear
    ttk::button .recent.f.buttons.close -text Close -style Dialog.TButton -command {destroy .recent}
    pack .recent.f.buttons.close .recent.f.buttons.clear .recent.f.buttons.missing \
         .recent.f.buttons.remove .recent.f.buttons.open -side right -padx {6 0}

    grid columnconfigure .recent.f 0 -weight 1
    grid rowconfigure .recent.f 2 -weight 1
    bind .recent.f.list <<ListboxSelect>> els::recent_manage_select
    bind .recent.f.list <Double-Button-1> els::recent_manage_open
    # re-elide the rows AND the detail label to the current width on any resize
    bind .recent.f.list <Configure> els::recent_manage_refresh
    bind .recent <Escape> {destroy .recent}
    bind .recent <Delete> els::recent_manage_remove
    # full native path on hover: per row in the list, and on the detail label
    set ::els::recent_row_tip -1
    set ::els::recent_sel_path ""
    bind .recent.f.list <Motion> {els::recent_row_motion %x %y %X %Y}
    bind .recent.f.list <Leave>  {els::tip_cancel ; set ::els::recent_row_tip -1}
    # the row tips are scheduled manually (not via tooltip_for), so the dialog
    # dying must cancel a pending one itself — else the after-550 fires over a
    # destroyed dialog and pops an orphan -topmost tip at the old cursor spot
    bind .recent.f.list <Destroy> {+els::tip_cancel}
    els::tooltip_for .recent.f.path els::recent_detail_tip

    els::recent_manage_refresh
    update idletasks
    # Pin a deliberate size, then keep it: a long selected path must NOT balloon
    # the dialog through geometry propagation.  Width comes from the button row /
    # subtitle plus a comfortable default — never from the longest path — and the
    # rows + detail label elide to whatever width we settle on.  Height is one
    # detail line plus chrome (the label is single-line, so it never grows tall).
    set pad 44                              ;# frame padding (18*2) + a little slack
    set minw [expr {[winfo reqwidth .recent.f.buttons] + $pad}]
    set defw [expr {[font measure elsUI [string repeat n 52]] + $pad}]
    set w [expr {max($minw, $defw)}]
    set h [winfo reqheight .recent]
    wm minsize .recent $minw $h
    set x [expr {[winfo rootx .] + ([winfo width .]  - $w) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - $h) / 3}]
    wm geometry .recent ${w}x${h}+$x+$y
    wm deiconify .recent
    update idletasks
    els::recent_manage_refresh   ;# the window now has its real width: elide to it
    focus .recent.f.list
}
# Pixel width available for a row of text inside the recent listbox (minus its
# highlight border and a little breathing room).  Returns a huge value while the
# widget is unrealized so the first fill shows full paths until the real width is
# known (a <Configure> then re-elides).
proc els::recent_manage_avail {} {
    set lb .recent.f.list
    if {![winfo exists $lb]} { return 100000 }
    set w [expr {[winfo width $lb] - 12}]
    return [expr {$w < 24 ? 100000 : $w}]
}
# Same idea for the bottom detail label (it spans the full content width).
proc els::recent_detail_avail {} {
    set l .recent.f.path
    if {![winfo exists $l]} { return 100000 }
    set w [expr {[winfo width $l] - 8}]
    return [expr {$w < 24 ? 100000 : $w}]
}
# Tooltip text for the detail label: the full native path, but only while the
# label is actually eliding it (mirrors the status-bar name tip).
proc els::recent_detail_tip {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return "" }
    if {[els::elide_path $p [els::recent_detail_avail]] eq $p} { return "" }
    return [els::path_tip $p]
}
# Per-row hover tooltip for the recent listbox: when the cursor is over a row
# whose displayed path is elided, show the full native path near the cursor.
proc els::recent_row_motion {x y rx ry} {
    variable recent_row_tip
    set lb .recent.f.list
    if {![winfo exists $lb] || ![llength $::els::recent]} { return }
    set i [$lb index @$x,$y]
    if {$i eq "" || $i < 0 || $i >= [llength $::els::recent]} {
        els::tip_cancel ; set recent_row_tip -1 ; return
    }
    # `index @x,y` CLAMPS to the nearest row, so in the empty area below the
    # last row it still answers the last index — require the pointer to be
    # inside that row's actual cell before offering its tip
    set bb [$lb bbox $i]
    if {$bb eq "" || $y < [lindex $bb 1] || $y >= [lindex $bb 1] + [lindex $bb 3]} {
        els::tip_cancel ; set recent_row_tip -1 ; return
    }
    if {$recent_row_tip == $i} { return }   ;# already handling this row
    set recent_row_tip $i
    els::tip_cancel
    set p [lindex $::els::recent $i]
    if {[$lb get $i] eq $p} { return }      ;# row not elided -> no tip
    set ::els::tip_after [after 550 \
        [list els::tip_pop_at [els::path_tip $p] [expr {$rx + 14}] [expr {$ry + 18}]]]
}
# The Maintain List scrollbar appears only when the list overflows.  The
# grid/grid-remove is a geometry change, so it is deferred to idle and
# coalesced (same discipline as the editor's own bars).
proc els::recent_vs {first last} {
    if {![winfo exists .recent.f.vs]} { return }
    .recent.f.vs set $first $last
    after cancel $::els::recent_vs_after
    set ::els::recent_vs_after [after idle els::recent_vs_apply]
}
proc els::recent_vs_apply {} {
    if {![winfo exists .recent.f.list]} { return }
    if {[winfo ismapped .recent.f.list]} {
        lassign [.recent.f.list yview] first last
        set need [expr {$first > 0.0001 || $last < 0.9999}]
    } else {
        # unmapped (e.g. a withdrawn dialog): yview degenerates to {0 1}, so
        # fall back to rows-vs-height (the dialog's height is pinned anyway)
        set need [expr {[.recent.f.list size] > [.recent.f.list cget -height]}]
    }
    if {$need} { grid .recent.f.vs } else { grid remove .recent.f.vs }
}
proc els::recent_manage_refresh {} {
    if {![winfo exists .recent.f.list]} { return }
    set lb .recent.f.list
    set avail [els::recent_manage_avail]
    $lb delete 0 end
    # elide too-long paths exactly like the status-bar name (keep the filename,
    # drop leading dirs behind "…/"); the full native path still shows in the
    # detail label below on selection.  Index->path mapping is unaffected because
    # selection is read by row index, not by the displayed text.
    foreach p $::els::recent { $lb insert end [els::elide_path $p $avail] }
    if {[llength $::els::recent]} {
        # restore the selection by PATH (tracked at select time), not by row
        # index: after the list reordered (recent_add while the dialog is open)
        # the old index would point at whatever file moved into that row
        set old [lsearch -exact $::els::recent $::els::recent_sel_path]
        if {$old < 0} { set old 0 }
        $lb selection set $old
        $lb activate $old
        $lb see $old
    }
    els::recent_manage_select
}
proc els::recent_manage_index {} {
    if {![winfo exists .recent.f.list]} { return -1 }
    set sel [.recent.f.list curselection]
    if {![llength $sel]} { return -1 }
    return [lindex $sel 0]
}
proc els::recent_manage_path {} {
    set i [els::recent_manage_index]
    if {$i < 0 || $i >= [llength $::els::recent]} { return "" }
    return [lindex $::els::recent $i]
}
proc els::recent_manage_select {} {
    if {![winfo exists .recent.f.path]} { return }
    set p [els::recent_manage_path]
    set has [expr {$p ne ""}]
    if {$has} { set ::els::recent_sel_path $p }   ;# track selection by PATH for refresh
    set hasMissing 0
    foreach r $::els::recent {
        if {![file exists $r]} { set hasMissing 1 ; break }
    }
    # elide the detail path too (full native path is on hover) so a long path
    # can't stretch the dialog wide.  (if/else, not an expr ternary: expr
    # canonicalizes number-looking operands, mangling a path like "007")
    if {$has} {
        set detail [els::elide_path $p [els::recent_detail_avail]]
    } else {
        set detail "No recent files"
    }
    .recent.f.path configure -text $detail
    foreach b {.recent.f.buttons.open .recent.f.buttons.remove} {
        $b configure -state [expr {$has ? "normal" : "disabled"}]
    }
    .recent.f.buttons.missing configure -state [expr {$hasMissing ? "normal" : "disabled"}]
    .recent.f.buttons.clear configure -state [expr {[llength $::els::recent] ? "normal" : "disabled"}]
}
proc els::recent_manage_open {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return }
    # close the dialog only when the open actually SUCCEEDED: `file exists` is
    # true for directories and unreadable files, and an error used to take the
    # dialog down with it — exactly when the user came here to clean the list
    if {[els::recent_open $p] ne ""} {
        catch {destroy .recent}
    } else {
        els::recent_manage_refresh
    }
}
proc els::recent_manage_remove {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return }
    els::recent_remove $p
}
proc els::recent_manage_remove_missing {} {
    set kept {}
    foreach p $::els::recent {
        if {[file exists $p]} { lappend kept $p }
    }
    set ::els::recent $kept
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
proc els::recent_manage_clear {} {
    if {![llength $::els::recent]} { return }
    set ans [tk_messageBox -parent .recent -icon question -type yesno -title els \
        -message "Clear the recent files list?"]
    if {$ans eq "yes"} { els::recent_clear }
}

# ---- Windows integration ------------------------------------------------
# Register els as an available .txt handler; Windows still lets the user choose
# the default app.  This writes only to HKCU, so it needs no admin rights.
proc els::association_exe {} {
    # Use the boot script captured at load time, NOT `info script` — this proc
    # runs from a button callback where `info script` is "", which previously made
    # us fall back to a cwd-relative els.exe lookup (so registration only worked
    # when els happened to be launched from its own folder).
    set bs $::els::boot_script
    if {[string match {//zipfs:*} $bs]} { return [file normalize [info nameofexecutable]] }
    if {$bs eq ""} { return "" }
    set near [file join [file dirname [file normalize $bs]] els.exe]
    if {[file exists $near]} { return [file normalize $near] }
    return ""
}
# The curated set of plain-text file types els advertises itself for (declared as
# SupportedTypes / Capabilities so els surfaces for them in Open with and Default
# apps).  Code/markup (json, xml, html, js, py, ...) is deliberately absent: els
# has no syntax highlighting, so it should not claim to handle those.
proc els::assoc_exts {} {
    return {txt log ini conf cfg nfo text toml yaml yml csv tsv env properties srt}
}
# reg.exe commands that register els with Windows as an application that can open
# files — type-independent, per-user (HKCU) only.  This makes "els" appear by name
# and icon in Explorer's Open with list for ANY file, and as a manageable entry in
# Settings > Default apps.  It NEVER sets a file type's default or touches
# UserChoice: the user picks els per type via Open with > Always.  The curated text
# extensions are merely DECLARED (SupportedTypes / Capabilities) so els surfaces for
# them and Default apps shows what it handles — declaring a type is not the same as
# becoming its default.
proc els::assoc_commands {exe} {
    set exe [file nativename [file normalize $exe]]
    set appExe [file tail $exe]
    set progid els.txt
    set openCmd [format {"%s" "%%1"} $exe]
    set icon [format {"%s",0} $exe]
    set clsKey "HKCU\\Software\\Classes\\$progid"
    set appKey "HKCU\\Software\\Classes\\Applications\\$appExe"
    set capKey {HKCU\Software\anafalanx\els\Capabilities}
    set cmds {}
    # one shared ProgID els uses to open a text file
    lappend cmds [list reg.exe add $clsKey /ve /d {els Text File} /f]
    lappend cmds [list reg.exe add "$clsKey\\DefaultIcon" /ve /d $icon /f]
    lappend cmds [list reg.exe add "$clsKey\\shell\\open\\command" /ve /d $openCmd /f]
    # the application itself: friendly name + launcher (-> Open with, any file)
    lappend cmds [list reg.exe add $appKey /v FriendlyAppName /t REG_SZ /d els /f]
    lappend cmds [list reg.exe add "$appKey\\shell\\open\\command" /ve /d $openCmd /f]
    # capabilities (-> a manageable "els" entry in Settings > Default apps)
    lappend cmds [list reg.exe add $capKey /v ApplicationName /t REG_SZ /d els /f]
    lappend cmds [list reg.exe add $capKey /v ApplicationDescription /t REG_SZ /d {A tiny text editor for Windows.} /f]
    lappend cmds [list reg.exe add $capKey /v ApplicationIcon /t REG_SZ /d $icon /f]
    lappend cmds [list reg.exe add {HKCU\Software\RegisteredApplications} /v els /t REG_SZ /d {Software\anafalanx\els\Capabilities} /f]
    # declare the curated text types: list els as an Open-with option for each
    # (OpenWithProgids -> the inline right-click "Open with" submenu), advertise
    # support (SupportedTypes), and list them under Default apps (Capabilities).
    # All three are options/declarations — NONE sets the type's default.
    foreach e [els::assoc_exts] {
        lappend cmds [list reg.exe add "HKCU\\Software\\Classes\\.$e\\OpenWithProgids" /v $progid /t REG_SZ /d "" /f]
        lappend cmds [list reg.exe add "$appKey\\SupportedTypes" /v ".$e" /t REG_SZ /d "" /f]
        lappend cmds [list reg.exe add "$capKey\\FileAssociations" /v ".$e" /t REG_SZ /d $progid /f]
    }
    return $cmds
}
# reg.exe commands that fully remove els's app registration (everything
# assoc_commands writes, including the per-type OpenWithProgids options).  Per-user
# only.  Any default the USER set via Open with > Always is left alone — that's
# their choice, Windows protects it, and it's reset in Settings > Default apps, not
# by us.
proc els::assoc_unregister_commands {exe} {
    set appExe [file tail [file normalize $exe]]
    set progid els.txt
    set cmds [list \
        [list reg.exe delete "HKCU\\Software\\Classes\\Applications\\$appExe" /f] \
        [list reg.exe delete {HKCU\Software\Classes\els.txt} /f] \
        [list reg.exe delete {HKCU\Software\anafalanx\els\Capabilities} /f] \
        [list reg.exe delete {HKCU\Software\RegisteredApplications} /v els /f]]
    foreach e [els::assoc_exts] {
        lappend cmds [list reg.exe delete "HKCU\\Software\\Classes\\.$e\\OpenWithProgids" /v $progid /f]
    }
    return $cmds
}
proc els::assoc_run {cmd} {
    exec {*}$cmd
}
# Read a single registry value ("" = the key's default).  Returns "" if absent.
# The value name is matched to its column (not as a substring), and reg.exe's
# "(value not set)" sentinel for an empty default is normalized to "".
proc els::reg_value {key {val ""}} {
    if {$val eq ""} { set q [list reg.exe query $key /ve] } else { set q [list reg.exe query $key /v $val] }
    if {[catch {exec {*}$q} out]} { return "" }
    return [els::reg_parse $out]
}
# Parse `reg.exe query` output POSITIONALLY, never by the name column: reg.exe
# localizes the default-value name ("(Default)" / "(Standard)" / "(Par défaut)"
# — the last even contains a space) and the unset sentinel, so name matching
# made registration state read as "not registered" on non-English Windows.
# Both query forms print exactly the one requested value as the first
# "<name> REG_TYPE <data>" line; the name is matched non-greedily so localized
# names with spaces survive.
proc els::reg_parse {out} {
    foreach ln [split $out \n] {
        if {[regexp -- {^\s+(.+?)\s+REG_\w+\s+(.*)$} $ln -> nm data]} {
            set data [string trimright $data]
            if {$data eq "(value not set)"} { return "" }   ;# English sentinel
            return $data
        }
    }
    return ""
}
# Is els currently registered with Windows as an app (its Applications launcher
# present)?  Drives the dialog's state line and which buttons appear.
proc els::assoc_registered {} {
    set exe [els::association_exe]
    if {$exe eq ""} { return 0 }
    set appExe [file tail [file normalize $exe]]
    set cmd [els::reg_value "HKCU\\Software\\Classes\\Applications\\$appExe\\shell\\open\\command" ""]
    # locale-proof decision: registered means OUR exe appears in the command
    # (a localized unset-sentinel from a non-English reg.exe is never a match)
    return [string match -nocase "*${appExe}*" $cmd]
}
proc els::open_default_apps {} {
    if {[catch {exec cmd.exe /c start "" ms-settings:defaultapps &}]} {
        els::open_url ms-settings:defaultapps
    }
}
# Register / unregister actions, driven by the dialog buttons.  Both re-render the
# dialog so its status line and buttons reflect the new reality.
proc els::assoc_register {} {
    set exe [els::association_exe]
    if {$exe eq "" || ![file exists $exe]} {
        tk_messageBox -parent .assoc -icon warning -title els \
            -message "els can only register itself from the built els.exe.\nBuild it (z build) and run that, then try again."
        return
    }
    set errs {}
    foreach cmd [els::assoc_commands $exe] {
        if {[catch {els::assoc_run $cmd} e]} { lappend errs $e }
    }
    if {[llength $errs]} {
        tk_messageBox -parent .assoc -icon error -title els \
            -message "Registration didn't fully complete:\n[join [lsort -unique $errs] \n]"
    }
    catch {els::assoc_render}
}
proc els::assoc_unregister {} {
    set exe [els::association_exe]
    if {$exe eq ""} { set exe els.exe }   ;# canonical app-key name, never the host interpreter
    foreach cmd [els::assoc_unregister_commands $exe] { catch {els::assoc_run $cmd} }
    catch {els::assoc_render}
}
# (Re)build the dialog body to reflect the current registration state.
proc els::assoc_render {} {
    set bg $::els::PAGE
    catch {destroy .assoc.f}
    frame .assoc.f -bg $bg
    pack  .assoc.f -padx 28 -pady 24
    set reg [els::assoc_registered]
    label .assoc.f.title -text "File Associations" -font elsUIb -fg $::els::INK -bg $bg
    grid  .assoc.f.title -row 0 -column 0 -sticky w -pady {0 10}
    set blurb "els registers with Windows as an app that can open files. To point a\nfile type at els, right-click it in Explorer, choose Open with, pick\nels, and turn on Always. Defaults are managed and reset anytime in\nWindows Settings > Default apps."
    label .assoc.f.blurb -text $blurb -font elsUI -fg $::els::MUTED -bg $bg -justify left -anchor w
    grid  .assoc.f.blurb -row 1 -column 0 -sticky w -pady {0 16}
    set statusTxt [expr {$reg ? "els is registered with Windows." : "els is not registered with Windows yet."}]
    set statusFg  [expr {$reg ? $::els::INK : $::els::MUTED}]
    label .assoc.f.status -text $statusTxt -font elsUIb -fg $statusFg -bg $bg -anchor w
    grid  .assoc.f.status -row 2 -column 0 -sticky w -pady {0 6}
    label .assoc.f.types -text "Text types els advertises: [join [lmap e [els::assoc_exts] {string cat . $e}] {  }]" \
        -font elsUI -fg $::els::MUTED -bg $bg -justify left -anchor w -wraplength 470
    grid  .assoc.f.types -row 3 -column 0 -sticky w -pady {0 18}
    frame .assoc.f.b -bg $bg
    grid  .assoc.f.b -row 4 -column 0 -sticky ew
    ttk::button .assoc.f.b.def   -text "Open Default Apps" -style Dialog.TButton -command els::open_default_apps
    ttk::button .assoc.f.b.close -text Close -style Dialog.TButton -command {destroy .assoc}
    if {$reg} {
        ttk::button .assoc.f.b.un -text "Remove els" -style Dialog.TButton -command els::assoc_unregister
        pack .assoc.f.b.close -side right -padx {6 0}
        pack .assoc.f.b.un    -side right -padx {6 0}
        pack .assoc.f.b.def   -side left
    } else {
        ttk::button .assoc.f.b.reg -text "Register els with Windows" -style Dialog.TButton -command els::assoc_register
        pack .assoc.f.b.close -side right -padx {6 0}
        pack .assoc.f.b.reg   -side left
    }
    grid columnconfigure .assoc.f 0 -weight 1
    update idletasks
}
proc els::file_associations {} {
    if {$::tcl_platform(platform) ne "windows"} {
        tk_messageBox -parent . -icon info -title els \
            -message "File associations are only available on Windows."
        return
    }
    catch {destroy .assoc}
    toplevel .assoc -bg $::els::PAGE
    wm withdraw .assoc
    wm title .assoc "File Associations"
    wm transient .assoc .
    wm resizable .assoc 0 0
    bind .assoc <Escape> {destroy .assoc}
    els::assoc_render
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .assoc]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .assoc]) / 4}]
    wm geometry .assoc +$x+$y
    wm deiconify .assoc
    focus .assoc
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
    # entries: flat, page-coloured field, hairline border (focus = a slightly
    # firmer grey, not red — red is reserved for the document caret)
    $s configure TEntry -relief flat -borderwidth 1 -padding {6 4} \
        -fieldbackground $::els::PAGE -foreground $ink -insertcolor $ink \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map TEntry -bordercolor [list focus "#A6ACB4"] \
        -lightcolor [list focus "#A6ACB4"] -darkcolor [list focus "#A6ACB4"]
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
    # find/replace controls stay regular-weight; outlines carry affordance.
    $s configure Find.Toolbutton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center -font elsUI
    $s map Find.Toolbutton -background [list selected #C6C6C6 active $::els::TABBG] \
        -foreground [list selected $ink active $ink]
    $s configure Find.TButton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center -font elsUI
    $s map Find.TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list active $ink]
    $s configure FindAction.TButton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 4} -anchor center -font elsUI \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map FindAction.TButton -background [list pressed $hair active $::els::TABBG]
    $s configure FindAction.Toolbutton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 4} -anchor center -font elsUI \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map FindAction.Toolbutton -background [list selected #C6C6C6 active $::els::TABBG] \
        -foreground [list selected $ink active $ink]
    # Dialog buttons should read as buttons even before hover, unlike the main
    # chrome where flatness matters more than affordance.
    $s configure Dialog.TButton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 5} -anchor center \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map Dialog.TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list disabled $::els::MUTED]
    # A traditional vertical scrollbar: clam's DEFAULT layout (so the up/down
    # arrow buttons are always drawn — unlike a thumb-only layout, and unlike the
    # classic Tk widget which on Windows only paints its arrows once activated).
    # -arrowsize sets both the arrow size and the bar's width.  Give it in POINTS
    # (as clam's own default 10.5p does) so ttk scales it per-DPI automatically —
    # a bare pixel value is NOT scaled by tk scaling.  12p is a chunky, easy-to-
    # grab bar at any DPI.
    $s configure Vertical.TScrollbar -troughcolor $::els::PAGE \
        -background #BCBCBC -arrowcolor #4A4A4A -bordercolor #9A9A9A \
        -relief raised -borderwidth 1 -arrowsize 12p
    $s map Vertical.TScrollbar -background [list active #A4A4A4 disabled $::els::PAGE]
    # the horizontal scrollbar matches the vertical one exactly (same clam default
    # layout, chunky 12p arrows, colors) so the two read as one family
    $s configure Horizontal.TScrollbar -troughcolor $::els::PAGE \
        -background #BCBCBC -arrowcolor #4A4A4A -bordercolor #9A9A9A \
        -relief raised -borderwidth 1 -arrowsize 12p
    $s map Horizontal.TScrollbar -background [list active #A4A4A4 disabled $::els::PAGE]
}

# ---- build the UI -------------------------------------------------------
proc els::build {} {
    wm title . "els $::els::version"
    wm geometry . 900x620
    els::init_style
    . configure -background $::els::PAGE
    els::load_icon
    if {$::els::config_path eq ""} { els::config_resolve_existing }
    catch {els::load_geometry}   ;# backstop: NO config content may abort build
    wm minsize . 360 240
    wm protocol . WM_DELETE_WINDOW els::quit

    menu .menu
    . configure -menu .menu
    menu .menu.file
    .menu add cascade -label File -menu .menu.file
    .menu.file add command -label "New Tab"   -accelerator Ctrl+N -command els::new
    .menu.file add command -label Open...      -accelerator Ctrl+O -command els::open
    menu .menu.file.recent
    .menu.file add cascade -label "Open Recent" -menu .menu.file.recent
    els::recent_rebuild
    .menu.file add checkbutton -label "Restore Previous Session" \
        -variable ::els::restore_session -command els::session_set_restore
    .menu.file add separator
    .menu.file add command -label Save         -accelerator Ctrl+S -command els::save
    .menu.file add command -label "Save As..." -accelerator Ctrl+Shift+S -command els::saveas
    .menu.file add checkbutton -label "Auto-save" -variable ::els::autosave \
        -command els::set_autosave
    .menu.file add checkbutton -label "Keep Backups" -variable ::els::backups \
        -command els::set_backups
    .menu.file add command -label "Open Backups Folder" -command els::backups_open
    .menu.file add separator
    .menu.file add command -label "Close File" -accelerator Ctrl+W -command els::close_tab
    .menu.file add command -label Exit         -accelerator Ctrl+Q -command els::quit
    menu .menu.edit
    .menu add cascade -label Edit -menu .menu.edit
    .menu.edit add command -label Undo  -accelerator Ctrl+Z -command els::menu_undo
    .menu.edit add command -label Redo  -accelerator Ctrl+Y -command els::menu_redo
    .menu.edit add separator
    .menu.edit add command -label Cut   -accelerator Ctrl+X -command {els::menu_event <<Cut>>}
    .menu.edit add command -label Copy  -accelerator Ctrl+C -command {els::menu_event <<Copy>>}
    .menu.edit add command -label Paste -accelerator Ctrl+V -command {els::menu_event <<Paste>>}
    .menu.edit add separator
    .menu.edit add command -label "Find..."       -accelerator Ctrl+F -command {els::find_show find}
    .menu.edit add command -label "Replace..."    -accelerator Ctrl+H -command {els::find_show replace}
    .menu.edit add command -label "Go to Line..." -accelerator Ctrl+G -command els::goto_line
    menu .menu.view
    .menu add cascade -label View -menu .menu.view
    .menu.view add checkbutton -label "Word Wrap" -variable ::els::word_wrap \
        -command els::set_wrap
    .menu.view add checkbutton -label "Line Numbers" -variable ::els::show_linenos \
        -command els::set_linenos
    .menu.view add checkbutton -label "Show Whitespace" -variable ::els::show_ws \
        -command els::set_show_ws
    .menu.view add checkbutton -label "Always on Top" -variable ::els::always_on_top \
        -command els::set_always_on_top
    .menu.view add separator
    .menu.view add command -label "Zoom In"    -accelerator Ctrl++ -command {els::zoom 1}
    .menu.view add command -label "Zoom Out"   -accelerator Ctrl+- -command {els::zoom -1}
    .menu.view add command -label "Reset Zoom" -accelerator Ctrl+0 -command els::zoom_reset
    menu .menu.help
    .menu add cascade -label Help -menu .menu.help
    .menu.help add command -label "Keyboard Shortcuts" -command els::shortcuts
    .menu.help add command -label "File Associations..." -command els::file_associations
    .menu.help add command -label "els on GitHub" \
        -command {els::open_url "https://github.com/anafalanx/els"}
    .menu.help add separator
    .menu.help add command -label "About els" -command els::about

    # the tab strip
    frame .tabs -bg $::els::TABBG

    # the shared line-number gutter — a Canvas that draws only the numbers for
    # the display rows currently on screen (see els::draw_gutter), so it is
    # O(visible rows) regardless of file size and aligns with wrapped lines for
    # free via the text widget's own dlineinfo.  quiet ink, defers to the page
    canvas .ln -bg $::els::GUTTER -borderwidth 0 -highlightthickness 0 \
        -width 40 -takefocus 0 -cursor arrow
    set ::els::gutter_px -1   ;# fresh canvas: force the next width configure

    # the shared scrollbars (traditional: arrow buttons + a wide grabbable thumb;
    # styled in init_style).  The horizontal one is gridded only when word wrap is
    # off and a line runs past the window edge (see els::update_hscroll).
    ttk::scrollbar .vs -orient vertical   -command els::scroll  -takefocus 0
    ttk::scrollbar .hs -orient horizontal -command els::hscroll -takefocus 0

    # the find / replace bar (hidden until Ctrl+F / Ctrl+H)
    els::build_findbar

    # the shared status bar — one thin, quiet line under a hairline
    ttk::frame .sb
    frame .sb.hair -height 1 -bg $::els::HAIR
    # -width 8 FIXES the requested width: the text must never drive layout.
    # With a text-following request, a long path in a narrow window inflates
    # the request, pack squeezes the right cluster, the shrunken allocation
    # re-elides the text shorter, the request shrinks, pack gives the space
    # back... a visible flicker loop.  Actual width comes from -fill x/-expand.
    ttk::label .sb.name -font elsUI -anchor w -text "untitled" -width 8 \
        -foreground $::els::MUTED
    ttk::label .sb.pos  -font elsUI -anchor e -text "Ln 1 Col 1" -foreground $::els::MUTED
    ttk::label .sb.eol  -font elsUI -anchor e -text "LF"    -foreground $::els::MUTED \
        -cursor hand2 -padding {4 1}
    ttk::label .sb.enc  -font elsUI -anchor e -text "UTF-8" -foreground $::els::MUTED \
        -cursor hand2 -padding {4 1}
    frame .sb.sep_eol -width 1 -bg $::els::HAIR
    frame .sb.sep_enc -width 1 -bg $::els::HAIR
    # a normally-empty notice; lights up red when a newer release is detected
    ttk::label .sb.update -font elsUI -anchor e -text "" -foreground $::els::CARET -cursor hand2
    pack .sb.hair -side top -fill x
    # name on the left (takes the slack, elided keeping the filename); the
    # position / EOL / encoding cluster on the right, reading Ln·Col | EOL | enc
    pack .sb.name -side left  -padx {12 8}  -pady 4 -fill x -expand 1
    pack .sb.enc     -side right -padx {8 12}  -pady 4
    pack .sb.sep_enc -side right -padx {2 2}   -pady {7 6} -fill y
    pack .sb.eol     -side right -padx {8 2}   -pady 4
    pack .sb.sep_eol -side right -padx {8 2}   -pady {7 6} -fill y
    pack .sb.pos  -side right -padx {12 0}  -pady 4
    pack .sb.update -side right -padx {12 0} -pady 4
    # the EOL and encoding indicators are clickable pickers
    bind .sb.eol  <Button-1>  els::popup_eol_menu
    bind .sb.enc  <Button-1>  els::popup_enc_menu
    bind .sb.eol  <Enter>     {els::status_link_enter .sb.eol}
    bind .sb.enc  <Enter>     {els::status_link_enter .sb.enc}
    bind .sb.eol  <Leave>     {els::status_link_leave .sb.eol}
    bind .sb.enc  <Leave>     {els::status_link_leave .sb.enc}
    bind .sb.name <Configure> {els::update_namelabel}
    bind .sb.update <Button-1> {els::tip_cancel ; els::open_url "https://github.com/anafalanx/els/releases/latest"}
    # hover affordance like the other status-bar links, but keeping the red
    # accent (status_link_leave would reset it to MUTED)
    bind .sb.update <Enter> {.sb.update configure -background $::els::TABBG}
    bind .sb.update <Leave> {.sb.update configure -background $::els::CHROME}
    els::tooltip_for .sb.name els::name_tip

    # rows: 0 tabs · 1 find bar (shown on demand) · 2 text+gutter+vscroll ·
    # 3 hscroll (shown on demand) · 4 status.  The gutter spans rows 2-3 so its
    # quiet ground continues down beside the horizontal bar (no seam under the
    # line numbers); the bottom-right cell stays an empty page-grey corner.
    grid .tabs -row 0 -column 0 -columnspan 3 -sticky ew
    grid .ln   -row 2 -column 0 -rowspan 2 -sticky ns
    # honour a persisted Line Numbers = off: load_geometry ran at the TOP of
    # build, before .ln existed, so its set_linenos call could not apply — and
    # the unconditional grid above would leave an EMPTY gutter band showing
    if {!$::els::show_linenos} { grid remove .ln }
    # auto-save when the app window loses focus (Deactivate fires on toplevels)
    bind . <Deactivate> {if {"%W" eq "."} { els::autosave_all }}
    grid .vs   -row 2 -column 2 -sticky ns
    grid .hs   -row 3 -column 1 -sticky ew
    grid .sb   -row 4 -column 0 -columnspan 3 -sticky ew
    grid rowconfigure    . 2 -weight 1
    grid columnconfigure . 1 -weight 1

    # class bindings shared by every document Text widget.  The elsText tag
    # runs BEFORE the default Text tag, so accelerators here pre-empt Tk's
    # emacs-style defaults (Ctrl+N = down-line, Ctrl+O = open-line, ...).
    bind elsText <<Modified>>    {els::on_modified %W}
    bind elsText <KeyRelease>    {els::refresh_view}
    bind elsText <ButtonRelease> {els::refresh_view}
    bind elsText <FocusIn>       {els::refresh_view}
    bind elsText <<Paste>>       {els::refresh_schedule}
    bind elsText <<Cut>>         {els::refresh_schedule}
    # coalesced: an interactive resize delivers a continuous Configure stream,
    # and a bare `after idle` per event ran N full repaints per idle batch
    bind elsText <Configure>     {els::refresh_schedule}
    # autosave: re-arm the swap debounce on real edits (<<Modified>> only flips on
    # the 0->1 transition, so a sustained typing burst would otherwise miss it)
    bind elsText <KeyRelease>    {+els::swap_touch}
    bind elsText <<Paste>>       {+els::swap_touch}
    bind elsText <<Cut>>         {+els::swap_touch}
    bind elsText <Control-n> { els::new;       break }
    bind elsText <Control-o> { els::open;      break }
    bind elsText <Control-s> { els::save;      break }
    bind elsText <Control-Shift-S> { els::saveas; break }
    bind elsText <Control-w> { els::close_tab; break }
    bind elsText <Control-q> { els::quit;      break }
    bind elsText <Control-Tab>          { els::cycle 1;  break }
    bind elsText <Control-Shift-Tab>    { els::cycle -1; break }
    bind elsText <Control-ISO_Left_Tab> { els::cycle -1; break }
    bind elsText <Control-f> { els::find_show find;    break }
    bind elsText <Control-h> { els::find_show replace; break }
    bind elsText <Control-g> { els::goto_line;         break }
    bind elsText <Control-z> { els::menu_undo;         break }
    bind elsText <Control-y> { els::menu_redo;         break }
    bind elsText <Control-plus>       { els::zoom 1;     break }
    bind elsText <Control-equal>      { els::zoom 1;     break }
    bind elsText <Control-minus>      { els::zoom -1;    break }
    bind elsText <Control-Key-0>      { els::zoom_reset; break }
    bind elsText <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    bind elsText <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
    bind elsText <Shift-MouseWheel>   { els::hwheel %D; break }
    bind elsText <Key-F3>             { els::find_step 1;  break }
    bind elsText <Shift-Key-F3>       { els::find_step -1; break }
    # neutralize Tk's emacs-style Text defaults that surprise on a Windows editor
    # (Ctrl+K kill-to-end, Ctrl+D delete-next, Ctrl+T transpose); break pre-empts
    # the default Text binding so these keys do nothing
    bind elsText <Control-k> break
    bind elsText <Control-d> break
    bind elsText <Control-t> break

    # the same accelerators on the toplevel, for when focus is off the text
    bind . <Control-n> { els::new;       break }
    bind . <Control-o> { els::open;      break }
    bind . <Control-s> { els::save;      break }
    bind . <Control-Shift-S> { els::saveas; break }
    bind . <Control-w> { els::close_tab; break }
    bind . <Control-q> { els::quit;      break }
    bind . <Control-Tab>          { els::cycle 1;  break }
    bind . <Control-Shift-Tab>    { els::cycle -1; break }
    bind . <Control-ISO_Left_Tab> { els::cycle -1; break }
    bind . <Control-f> { els::find_show find;    break }
    bind . <Control-h> { els::find_show replace; break }
    bind . <Control-g> { els::goto_line;         break }
    bind . <Control-plus>       { els::zoom 1;     break }
    bind . <Control-equal>      { els::zoom 1;     break }
    bind . <Control-minus>      { els::zoom -1;    break }
    bind . <Control-Key-0>      { els::zoom_reset; break }
    bind . <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    bind . <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
    bind . <Key-F3>             { els::find_step 1;  break }
    bind . <Shift-Key-F3>       { els::find_step -1; break }

    bind .ln <Button-1>   { focus [els::T]; break }
    bind .ln <MouseWheel> { els::wheel %D; break }
    bind .ln <Shift-MouseWheel> { els::hwheel %D; break }
    bind .ln <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    # precision touchpads arrive as <TouchpadScroll>, not <MouseWheel>: the Text
    # class handles it, a bare canvas does not — without these the gutter was
    # dead to touchpad scrolling and Ctrl+touchpad scrolled instead of zooming
    bind .ln <TouchpadScroll>         { els::touchpad_scroll %D; break }
    bind .ln <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
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
    text $w -undo 1 -wrap [expr {$::els::word_wrap ? "word" : "none"}] -font elsMono \
        -bg $::els::PAGE -fg $::els::INK \
        -insertbackground $::els::CARET -insertwidth 4 -insertofftime 0 \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -inactiveselectbackground $::els::SELOFF \
        -borderwidth 0 -highlightthickness 0 -padx 14 -pady 6 \
        -spacing1 $::els::LEAD -spacing3 $::els::LEAD \
        -tabstyle wordprocessor \
        -yscrollcommand [list els::yscroll $id] \
        -xscrollcommand [list els::xscroll $id]
    $w tag configure currentLine -background $::els::LINE
    $w tag configure wsSpace -background $::els::WSSPACE
    $w tag configure wsTab   -background $::els::WSTAB
    $w tag configure wsTrail -background $::els::WSTRAIL
    $w tag configure findAll -background $::els::FINDALL
    $w tag configure findOne -background $::els::FINDONE
    # stacking, low -> high: current-line wash < space/tab < trailing < matches <
    # selection (whitespace above the line wash so it shows on the current line;
    # trailing above space/tab so it wins on a trailing run)
    $w tag lower currentLine
    $w tag raise wsSpace
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
    set ::els::docEol($id) [els::default_eol]   ;# platform-native for NEW docs
    set ::els::docRaw($id) ""
    lappend docs $id
    els::make_tab $id
    els::switch_to $id
    return $id
}
# EOL for documents born in els (files opened from disk keep their detected
# one): the platform convention — CRLF on Windows, LF elsewhere.
proc els::default_eol {} {
    if {$::tcl_platform(platform) eq "windows"} { return crlf }
    return lf
}
proc els::doc_dirty {id} {
    set w [els::W $id]
    if {![winfo exists $w]} { return 0 }
    return [$w edit modified]
}
proc els::doc_name {id} {
    variable docPath
    set p $docPath($id)
    # NOT an expr ternary: expr canonicalizes operands that look like numbers,
    # so a file named "007" displayed (and Save-As-prefilled!) as "7", and one
    # named "nan" THREW here — i.e. on every keystroke via update_tab.
    if {$p eq ""} { return "untitled" }
    return [file tail $p]
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
    if {$active ne "" && $active ne $id} { els::autosave_flush_doc $active }
    if {$active ne "" && [winfo exists [els::W $active]]} {
        # clear find highlights on the tab we are leaving so they don't linger as
        # orphaned tints on an inactive document (the search re-applies to the new
        # active doc below when the find bar is open)
        [els::W $active] tag remove findAll 1.0 end
        [els::W $active] tag remove findOne 1.0 end
        grid remove [els::W $active]
    }
    set active $id
    set w [els::W $id]
    grid $w -row 2 -column 1 -sticky nsew
    focus $w
    els::refresh_tabs
    els::settitle
    els::refresh_view
    if {$::els::find_mode ne ""} { els::find_update }
    after idle els::update_vscroll
    after idle els::update_hscroll
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
    els::autosave_flush_doc $id   ;# auto-save on: a pathed doc closes saved, no prompt
    if {[els::doc_dirty $id]} {
        set ::els::swap_suspend 1
        set ans [tk_messageBox -parent . -icon warning -type yesnocancel \
            -title els -message "Save changes to [els::doc_name $id]?"]
        set ::els::swap_suspend 0
        if {$ans eq "cancel"} { return }
        if {$ans eq "yes"} {
            els::switch_to $id
            els::save
            if {[els::doc_dirty $id]} { return }   ;# Save As was cancelled
        }
    }
    set idx [lsearch -exact $docs $id]
    set docs [lreplace $docs $idx $idx]
    els::swap_clear $id   ;# clean close -> the swap is no longer needed
    destroy [els::W $id]
    destroy [els::tabW $id]
    unset -nocomplain ::els::docRecovered($id)
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    unset -nocomplain docPath($id) ::els::docEnc($id) ::els::docBom($id) \
        ::els::docEol($id) ::els::docRaw($id) \
        ::els::savedSig($id) ::els::loading($id)
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
    set tag [expr {[info exists ::els::docRecovered($id)] ? " (recovered)" : ""}]
    return "$mark[els::doc_name $id]$tag"
}
# Tooltip text for a tab: the document's full native path (empty for untitled).
proc els::tab_tip {id} {
    if {![info exists ::els::docPath($id)]} { return "" }
    set p $::els::docPath($id)
    return [expr {$p eq "" ? "" : [els::path_tip $p]}]
}
proc els::make_tab {id} {
    set tf [els::tabW $id]
    frame $tf -bg $::els::TABOFF
    label $tf.name -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text [els::tab_text $id] -padx 6 -pady 3 -anchor w
    label $tf.close -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text "×" -width 2 -padx 0 -pady 3 -anchor center -cursor hand2
    pack $tf.name  -side left
    pack $tf.close -side right
    pack $tf -side left -padx {0 1} -pady {2 0} -fill y
    bind $tf       <Button-1> [list els::switch_to $id]
    bind $tf.name  <Button-1> [list els::switch_to $id]
    # drag a tab left/right to reorder it (crossing a neighbour's midpoint
    # swaps places; the docs list and the saved session follow the new order)
    bind $tf       <B1-Motion> [list els::tab_drag $id %X]
    bind $tf.name  <B1-Motion> [list els::tab_drag $id %X]
    bind $tf.close <Button-1> [list els::close_doc $id]
    bind $tf.close <Enter>    [list els::tab_close_enter $id]
    bind $tf.close <Leave>    [list els::tab_close_leave $id]
    els::tooltip_for $tf      [list els::tab_tip $id] $::els::tab_tip_delay
    els::tooltip_for $tf.name [list els::tab_tip $id] $::els::tab_tip_delay
}
# Reorder by drag: when the pointer crosses a neighbouring tab's midpoint,
# move the dragged doc to that position and repack.  State-free (each motion
# event re-evaluates), so a plain click never reorders anything.
proc els::tab_drag {id rootX} {
    variable docs
    set idx [lsearch -exact $docs $id]
    if {$idx < 0} { return }
    foreach other $docs {
        if {$other eq $id} continue
        set tw [els::tabW $other]
        if {![winfo exists $tw]} continue
        set mid  [expr {[winfo rootx $tw] + [winfo width $tw] / 2}]
        set oidx [lsearch -exact $docs $other]
        if {($oidx < $idx && $rootX < $mid) || ($oidx > $idx && $rootX > $mid)} {
            set docs [linsert [lreplace $docs $idx $idx] $oidx $id]
            els::tab_repack
            break
        }
    }
}
proc els::tab_repack {} {
    foreach id $::els::docs {
        set tf [els::tabW $id]
        if {![winfo exists $tf]} continue
        pack forget $tf
        pack $tf -side left -padx {0 1} -pady {2 0} -fill y
    }
}
proc els::tab_close_enter {id} {
    set w [els::tabW $id].close
    if {![winfo exists $w]} { return }
    set bg [expr {$id eq $::els::active ? $::els::TABON : $::els::TABOFF}]
    $w configure -bg $bg -fg $::els::INK
}
proc els::tab_close_leave {id} {
    variable active
    set bg [expr {$id eq $active ? $::els::TABON : $::els::TABOFF}]
    catch {[els::tabW $id].close configure -bg $bg -fg $::els::MUTED}
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
        $tf.close configure -bg $bg -fg $::els::MUTED
    }
}

# ---- title / status -----------------------------------------------------
proc els::settitle {} {
    variable active
    # the title bar shows only the app name + version; the filename and dirty
    # state live on the tab and in the status bar instead
    wm title . "els $::els::version"
    if {$active eq ""} { return }
    els::update_namelabel
    .sb.eol  configure -text [els::eol_label $::els::docEol($active)]
    .sb.enc  configure -text [els::enc_label $::els::docEnc($active) $::els::docBom($active)]
}
# The left status item shows the active document's path, elided to fit — the
# filename always survives, the leading directories are dropped behind a "…/".
proc els::update_namelabel {} {
    variable active
    if {![winfo exists .sb.name]} { return }
    if {$::els::status_note_after ne ""} { return }   ;# a transient note holds the slot
    if {$active eq "" || ![info exists ::els::docPath($active)]} {
        .sb.name configure -text "" ; return
    }
    set p $::els::docPath($active)
    if {$p eq ""} { .sb.name configure -text "untitled" ; return }
    # the path's length rides along in the normal depiction (same [N] the hover
    # tip shows), not only in the tooltip once the path elides
    set suffix "  \[[string length [els::display_path $p]]\]"
    set avail [expr {[winfo width .sb.name] - 4 - [font measure elsUI $suffix]}]
    if {$avail < 24} { .sb.name configure -text [file tail $p]$suffix ; return }  ;# unrealized
    .sb.name configure -text [els::elide_path $p $avail]$suffix
}
# Strip a Windows extended-length prefix (\\?\ or //?/, incl. the UNC form) from
# a path.  Tcl's `file normalize` adds it for paths over MAX_PATH (260), and it
# must never leak into anything shown to a human.
proc els::strip_ext_prefix {p} {
    if {[regexp {^[\\/]{2}\?[\\/]UNC[\\/](.*)$} $p -> rest]} { return "//$rest" }
    if {[regexp {^[\\/]{2}\?[\\/](.*)$} $p -> rest]} { return $rest }
    return $p
}
# A path formatted for human display: native (backslash) separators, no
# extended-length prefix.
proc els::display_path {p} {
    return [file nativename [els::strip_ext_prefix $p]]
}
# Tooltip text for a path: the display path followed by its character length in
# square brackets, e.g.  C:\dir\file.txt [15].  ("" stays "" so empty tips are
# still suppressed.)  The length is of the real path, sans extended prefix.
proc els::path_tip {p} {
    if {$p eq ""} { return "" }
    set d [els::display_path $p]
    return "$d \[[string length $d]\]"
}
proc els::elide_path {p avail} {
    set p [els::strip_ext_prefix $p]
    if {[font measure elsUI $p] <= $avail} { return $p }
    set parts [file split $p]
    set best ""
    # grow outward from the filename, keeping as much trailing path as fits
    for {set i [expr {[llength $parts] - 1}]} {$i >= 0} {incr i -1} {
        set tail [file join {*}[lrange $parts $i end]]
        set cand [expr {$i == 0 ? $tail : "…/$tail"}]
        if {[font measure elsUI $cand] <= $avail} { set best $cand } else { break }
    }
    if {$best ne ""} { return $best }
    # even the filename alone is too wide — clip its head, keep the end
    set s [file tail $p]
    while {[string length $s] > 1 && [font measure elsUI "…$s"] > $avail} {
        set s [string range $s 1 end]
    }
    return "…$s"
}
# Tooltip text for the status-bar name: the full path, but only while the label
# is actually eliding it (when the whole path fits, the tip would be redundant).
proc els::name_tip {} {
    variable active
    if {$active eq "" || ![info exists ::els::docPath($active)]} { return "" }
    set p $::els::docPath($active)
    if {$p eq ""} { return "" }
    # suppress the tip while the label shows the WHOLE path: the displayed text
    # is "<path>  [N]" since the length suffix rode along, so compare against
    # that full non-elided rendering, not against the bare path
    set suffix "  \[[string length [els::display_path $p]]\]"
    if {[.sb.name cget -text] eq "[els::strip_ext_prefix $p]$suffix"} { return "" }
    return [els::path_tip $p]
}
proc els::status_link_enter {w} {
    if {![winfo exists $w]} { return }
    $w configure -foreground $::els::INK -background $::els::TABBG
}
proc els::status_link_leave {w} {
    if {![winfo exists $w]} { return }
    $w configure -foreground $::els::MUTED -background $::els::CHROME
}

# ---- Edit-menu actions, routed to the active document -------------------
# A mouse-driven Edit menu undo/redo produces no key event on the text widget
# (and <<Modified>> only fires on flag transitions), so the view must be
# refreshed — and the autosave latched — explicitly, like other button edits.
proc els::menu_undo {} {
    set w [els::T]
    if {$w eq ""} { return }
    catch {$w edit undo}
    els::swap_touch
    els::refresh_schedule
}
proc els::menu_redo {} {
    set w [els::T]
    if {$w eq ""} { return }
    catch {$w edit redo}
    els::swap_touch
    els::refresh_schedule
}
proc els::menu_event {ev} { set w [els::T] ; if {$w ne ""} { event generate $w $ev } }
proc els::on_modified {w} {
    variable active
    set id [els::id_of $w]
    if {$id eq ""} { return }
    if {[$w edit modified]} {
        set ::els::dirtySince($id) 1                          ;# 0->1 dirty latch
        els::autosave_soon $id                                ;# opt-in; debounced
    } else {
        # back to the saved state (undo-to-clean, save, reopen): there is
        # nothing to protect any more — drop the latch AND the swap file, so a
        # crash cannot re-offer content the user already discarded or saved
        els::swap_clear $id
    }
    els::swap_flush_soon                                      ;# debounced; never writes inline
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
    .sb.pos configure -text "Ln $line Col [expr {$col + 1}]"
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
    # emptiness via index compare, never `$w get 1.0 end-1c`: materializing the
    # whole buffer here made every keystroke O(document size)
    if {[$w compare "end - 1 char" != 1.0]} {
        $w tag add currentLine "$line.0" "$line.end + 1 char"
    }
    # the gutter's matching current-line band is drawn by els::draw_gutter
}
# Draw the line-number gutter for the CURRENTLY VISIBLE rows only, onto the
# Canvas .ln.  We ask the text widget where each visible logical line's first
# display row sits (dlineinfo) and place a right-aligned number at that baseline;
# continuation rows of a wrapped line get no number.  Cost is O(visible rows),
# independent of document size, and wrap alignment is exact and automatic (no
# leading-mirror tags).  The current line gets a wash behind its number.
proc els::draw_gutter {} {
    set w [els::T]
    if {$w eq "" || ![winfo exists .ln]} { return }
    if {!$::els::show_linenos} { return }   ;# gutter hidden: skip the work too
    .ln delete all
    set lines [els::line_count]
    set digits [expr {max(2, [string length $lines] + 1)}]
    # Pixel width for `digits` glyphs + padding.  Reconfigure ONLY on change: a
    # width change is a geometry op, so caching keeps the scroll path geometry-
    # free (digit count only changes on edits, never on a pure scroll).
    set px [expr {[font measure elsMono [string repeat 8 $digits]] + 12}]
    if {$px != $::els::gutter_px} {
        set ::els::gutter_px $px
        .ln configure -width $px
    }
    set h [winfo height $w]
    if {$h <= 1} { return }   ;# not realized yet — a later refresh will draw it
    # use the REQUESTED width: `winfo width` still reports the old realized
    # width until the geometry pass runs, so after a digit-count change the
    # numbers would right-align (and the band would size) against the old edge
    # for one visible frame
    set gw $::els::gutter_px
    set right [expr {$gw - 6}]
    set ascent [font metrics elsMono -ascent]
    set first [lindex [split [$w index @0,0] .] 0]
    set last  [lindex [split [$w index "@0,$h"] .] 0]
    set cur   [lindex [split [$w index insert] .] 0]
    # emptiness via index compare (a full `$w get` is O(document size))
    set hasText [$w compare "end - 1 char" != 1.0]
    # the current line's band must cover the line's FULL visible extent: with
    # word wrap a line spans several display rows (the text wash covers all of
    # them), and when its first row is scrolled off the top, dlineinfo "$cur.0"
    # is empty — wash the visible continuation rows from the canvas top.
    if {$hasText && $cur == $first && [$w dlineinfo "$cur.0"] eq ""} {
        set nx [$w dlineinfo "$cur.0 + 1 line linestart"]
        if {$nx ne ""} { set bot [lindex $nx 1] } else { set bot $h }
        .ln create rectangle 0 0 $gw $bot -fill $::els::LINE -outline ""
    }
    for {set ln $first} {$ln <= $last} {incr ln} {
        set di [$w dlineinfo "$ln.0"]
        if {$di eq ""} { continue }   ;# this line's first row is scrolled off
        lassign $di dx dy dw dh dbase
        if {$hasText && $ln == $cur} {
            set nx [$w dlineinfo "$ln.0 + 1 line linestart"]
            if {$nx ne ""} { set bot [lindex $nx 1] } else { set bot $h }
            if {$bot < $dy + $dh} { set bot [expr {$dy + $dh}] }
            .ln create rectangle 0 $dy $gw $bot -fill $::els::LINE -outline ""
        }
        # anchor ne at (right, baseline-ascent) puts the number's baseline on the
        # text row's baseline and its right edge at the gutter's right margin
        .ln create text $right [expr {$dy + $dbase - $ascent}] -anchor ne \
            -text $ln -font elsMono -fill $::els::GUTTINK
    }
}
# Coalesce gutter redraws caused by scrolling: a burst schedules ONE draw after
# the display loop settles (mirrors the vscroll / whitespace deferrals, and
# keeps the canvas width-configure out of the -yscrollcommand re-entrancy path).
proc els::gutter_schedule {} {
    variable gutter_after
    after cancel $gutter_after
    set gutter_after [after idle els::draw_gutter]
}
proc els::sync_scroll {} {
    if {[els::T] ne "" && [winfo exists .ln]} { els::gutter_schedule }
}
proc els::yscroll {id first last} {
    variable active
    variable vs_after
    if {$id ne $active} { return }
    .vs set $first $last
    els::gutter_schedule   ;# redraw the visible gutter numbers for the new view
    # Defer the scrollbar show/hide to idle: it calls `grid` (a geometry change),
    # and running that from inside a -yscrollcommand can re-enter the display
    # loop. Coalesced so a burst of scrolls schedules one update.
    after cancel $vs_after
    set vs_after [after idle els::update_vscroll]
    # whitespace tints are viewport-scoped, so re-tag after a scroll (coalesced)
    if {$::els::show_ws} {
        after cancel $::els::ws_after
        set ::els::ws_after [after idle els::ws_refresh]
    }
}
# Show the scrollbar only when the document doesn't fit (chrome defers).  Reads
# the live yview rather than a possibly-stale -yscrollcommand value, so it's
# correct after a load settles (yscrollcommand only fires on view *change*).
proc els::update_vscroll {} {
    variable active
    variable vs_shown
    if {$active eq "" || ![winfo exists [els::W $active]]} { return }
    lassign [[els::W $active] yview] first last
    # re-feed the shared bar from the live view: re-gridding a widget with an
    # unchanged view does not re-fire -yscrollcommand, so after a tab switch
    # the thumb still showed the PREVIOUS tab's position
    .vs set $first $last
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
    # float division like Tk's own tk::MouseWheel: integer / floors toward
    # -inf, so +40 scrolled one unit while -40 scrolled none (asymmetric for
    # any delta that isn't a multiple of 120)
    $w yview scroll [expr {-$delta / 120.0}] units
    els::sync_scroll
}
# Precision-touchpad scrolling (Tk 9 delivers it as <TouchpadScroll>, which the
# Text class handles but a bare canvas does not) — used by the gutter.
proc els::touchpad_scroll {D} {
    set w [els::T]
    if {$w eq ""} { return }
    lassign [tk::PreciseScrollDeltas $D] dx dy
    if {$dy != 0} { $w yview scroll [expr {-$dy}] pixels ; els::sync_scroll }
    if {$dx != 0} { $w xview scroll [expr {-$dx}] pixels }
}
# Ctrl+touchpad-scroll = zoom (matching Ctrl+MouseWheel): without these
# bindings the gesture fell through to the plain TouchpadScroll handler and
# scrolled instead.  Deltas accumulate so the high event rate zooms smoothly.
proc els::zoom_touchpad {D} {
    lassign [tk::PreciseScrollDeltas $D] dx dy
    if {$dy == 0} { return }
    set a [expr {$::els::tp_zoom_acc + $dy}]
    while {$a >= 60}  { els::zoom 1  ; set a [expr {$a - 60}] }
    while {$a <= -60} { els::zoom -1 ; set a [expr {$a + 60}] }
    set ::els::tp_zoom_acc $a
}
# ---- horizontal scrolling (active only when word wrap is off) -----------
# The text widget fires -xscrollcommand only on a view *change*; the show/hide
# is deferred to idle (it calls `grid`, a geometry change) and coalesced, exactly
# like the vertical bar.
proc els::xscroll {id first last} {
    variable active
    variable hs_after
    if {$id ne $active} { return }
    .hs set $first $last
    after cancel $hs_after
    set hs_after [after idle els::update_hscroll]
    # whitespace tints are viewport-scoped: a horizontal pan changes what is
    # visible too, and without this the top row's left-of-viewport whitespace
    # stayed untinted after panning back (only yscroll re-tagged)
    if {$::els::show_ws} {
        after cancel $::els::ws_after
        set ::els::ws_after [after idle els::ws_refresh]
    }
}
# Show the horizontal bar only when wrap is off AND a line runs past the window
# edge.  Under word wrap nothing scrolls sideways (xview is {0 1}), so the bar
# stays hidden — which is exactly the requested behaviour.
proc els::update_hscroll {} {
    variable active
    variable hs_shown
    if {$active eq "" || ![winfo exists [els::W $active]]} { return }
    if {$::els::word_wrap} {
        set need 0
    } else {
        lassign [[els::W $active] xview] first last
        .hs set $first $last   ;# re-feed after a tab switch (same as update_vscroll)
        set need [expr {$first > 0.0001 || $last < 0.9999}]
    }
    if {$need != $hs_shown} {
        set hs_shown $need
        if {$need} { grid .hs } else { grid remove .hs }
    }
}
proc els::hscroll {args} {
    set w [els::T]
    if {$w eq ""} { return }
    $w xview {*}$args
}
proc els::hwheel {delta} {
    set w [els::T]
    if {$w eq ""} { return }
    $w xview scroll [expr {-$delta / 120.0}] units
}
proc els::refresh_view {} {
    if {[els::T] eq ""} { return }
    els::update_pos
    els::update_current_line
    els::draw_gutter
    els::update_vscroll
    els::update_hscroll
    if {$::els::show_ws} { els::ws_refresh }
}
# Coalesce deferred full refreshes (like gutter_schedule): a resize delivers a
# continuous <Configure> stream, and one queued refresh per event multiplied
# the whole repaint several-fold per frame.
proc els::refresh_schedule {} {
    variable refresh_after
    after cancel $refresh_after
    set refresh_after [after idle els::refresh_view]
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

# Resolve a BOM-less wide encoding from a STRONG UTF-16/32 NUL signature.  A
# genuine wide file has many NULs concentrated in one byte-parity (the high-byte
# of each mostly-ASCII code unit).  A file with only a few stray NULs (a log, a
# text/db export, ASCII with an embedded NUL) is NOT wide and returns "" so it is
# read as text instead of being mangled into UTF-16.  ICU picks LE/BE/32 once the
# signature is established; without ICU, parity gives UTF-16 LE/BE.
proc els::detect_wide {raw sample} {
    set n [string length $sample]
    if {$n < 4} { return "" }
    set even 0 ; set odd 0 ; set i 0
    foreach b [split $sample ""] {
        if {$b eq "\x00"} { if {$i & 1} { incr odd } else { incr even } }
        incr i
    }
    set nul [expr {$even + $odd}]
    set dominant [expr {max($even, $odd)}]
    set other    [expr {min($even, $odd)}]
    # require a structural share of NULs (>~5%) lopsided to one parity; a couple
    # of stray NULs, or NULs spread across both parities (binary), are not wide
    if {$nul * 20 < $n || $other > $dominant / 3} { return "" }
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            set enc [els::icu_to_tcl [lindex $d 0]]
            if {[string match utf-* $enc]} { return $enc }
        }
    }
    return [expr {$even > $odd ? "utf-16be" : "utf-16le"}]
}

# Fast ASCII-only test: true iff every byte is < 0x80.  Uses the C-level
# `string is` instead of a per-byte Tcl loop (which froze the UI on a big file).
proc els::bytes_ascii_only {raw} {
    return [string is ascii $raw]
}

proc els::detect_encoding {raw} {
    # -> {encoding bom}.  bom=1 if a byte-order mark was present (stripped on decode).
    set n [string length $raw]
    if {$n == 0} { return {utf-8 0} }
    # 1. BOM sniff — UTF-32 before UTF-16 (the UTF-32 LE BOM begins FF FE too).
    if {[string range $raw 0 3] eq "\x00\x00\xFE\xFF"} { return {utf-32be 1} }
    if {[string range $raw 0 3] eq "\xFF\xFE\x00\x00"} { return {utf-32le 1} }
    if {[string range $raw 0 2] eq "\xEF\xBB\xBF"} {
        # Trust the UTF-8 BOM only when the payload really is valid UTF-8: a
        # Windows tool prepending a BOM to legacy (cp1252...) content is common,
        # and decoding that payload as utf-8 -profile replace would destroy
        # every non-UTF-8 byte (U+FFFD -> EF BF BD on save).  On invalid payload
        # fall through to detection over the WHOLE raw (BOM bytes stay content,
        # which round-trips losslessly).
        if {![catch {encoding convertfrom -profile strict utf-8 \
                         [string range $raw 3 end]}]} {
            return {utf-8 1}
        }
    }
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
    # 3. ASCII-only bytes are shared by UTF-8 and most legacy encodings; there is
    #    no honest way to distinguish them, so els uses UTF-8 as the default.
    if {[els::bytes_ascii_only $raw]} { return {utf-8 0} }
    # 4. ICU charset detection (chardet quality) for legacy 8-bit / CJK text.
    #    This runs before the UTF-8 validity fallback so valid byte sequences do
    #    not automatically mask a stronger legacy/CJK detector answer.
    set utf8_ok [expr {![catch {encoding convertfrom -profile strict utf-8 $raw}]}]
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            lassign $d icu conf
            set enc [els::icu_to_tcl $icu]
            # never accept a utf-8 verdict for bytes that are NOT valid UTF-8:
            # ICU trusts a BOM even when the payload is legacy bytes
            if {$enc eq "utf-8" && !$utf8_ok} { set enc "" }
            if {$enc eq "cp1252"} { set enc [els::cp1252_or_latin1 $raw] }
            if {$enc ne "" && $conf >= $::els::DETECT_MIN} { return [list $enc 0] }
        }
    }
    # 5. UTF-8 fallback when the bytes are strictly valid and ICU had no better
    #    answer.  Otherwise Windows Western — demoted to Latin-1 when the bytes
    #    include code points cp1252 cannot round-trip.
    if {$utf8_ok} { return {utf-8 0} }
    return [list [els::cp1252_or_latin1 $raw] 0]
}
# cp1252 leaves 0x81 0x8D 0x8F 0x90 0x9D undefined: Tcl 9 decodes them to
# U+FFFD and save re-encodes that as "?" — silent byte destruction.  When any
# of those bytes is present, use iso8859-1 instead: it maps all 256 bytes, so
# the file round-trips losslessly.
proc els::cp1252_or_latin1 {raw} {
    if {[regexp {[\x81\x8D\x8F\x90\x9D]} $raw]} { return iso8859-1 }
    return cp1252
}
proc els::decode {raw enc bom} {
    if {$bom} {
        # Strip the BOM only when those bytes are actually present: the curated
        # picker can assert bom=1 ("UTF-8 with BOM") on a file that has none,
        # and a blind byte-count skip would eat the first 2-4 CONTENT bytes —
        # persisted by the next save.  (Reopening a BOM-less file as a
        # with-BOM encoding now means "add the BOM on save", losing nothing.)
        switch -- $enc {
            utf-8    { set bomb "\xEF\xBB\xBF" }
            utf-16le { set bomb "\xFF\xFE" }
            utf-16be { set bomb "\xFE\xFF" }
            utf-32le { set bomb "\xFF\xFE\x00\x00" }
            utf-32be { set bomb "\x00\x00\xFE\xFF" }
            default  { set bomb "" }
        }
        set skip [string length $bomb]
        if {$bomb ne "" && [string range $raw 0 [expr {$skip - 1}]] eq $bomb} {
            set raw [string range $raw $skip end]
        }
    }
    return [encoding convertfrom -profile replace $enc $raw]
}
proc els::detect_eol {text} {
    # Pick the DOMINANT ending, not the first one seen: first-match priority
    # classified a mostly-LF file with one stray CRLF as crlf, so a save
    # rewrote every line ending in the file.  Ties keep crlf > lf > cr.
    set crlf [regexp -all {\r\n} $text]
    set cr   [expr {[regexp -all {\r} $text] - $crlf}]
    set lf   [expr {[regexp -all {\n} $text] - $crlf}]
    if {$crlf > 0 && $crlf >= $lf && $crlf >= $cr} { return crlf }
    if {$lf > 0 && $lf >= $cr} { return lf }
    if {$cr > 0} { return cr }
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
    .encpop add cascade -label "Set Save Encoding"    -menu [els::enc_menu .encpop.sv save]
}
proc els::menu_cascade_reserve {menu {depth 1}} {
    if {$depth <= 0 || ![winfo exists $menu]} { return 0 }
    set best 0
    set end [$menu index end]
    if {$end eq "none"} { return 0 }
    for {set i 0} {$i <= $end} {incr i} {
        if {[$menu type $i] ne "cascade"} { continue }
        set sub [$menu entrycget $i -menu]
        if {$sub eq "" || ![winfo exists $sub]} { continue }
        set width [winfo reqwidth $sub]
        set nested [els::menu_cascade_reserve $sub [expr {$depth - 1}]]
        set best [expr {max($best, $width + $nested)}]
    }
    return $best
}
# Post a status-bar picker UPWARD from its indicator, kept inside the main
# window — a downward menu spills below the window's bottom sill (off-screen).
proc els::popup_up {menu widget} {
    update idletasks
    set mw [winfo reqwidth $menu] ; set mh [winfo reqheight $menu]
    set nx [winfo rootx $widget]  ; set ny [expr {[winfo rooty $widget] - $mh}]
    set winl [winfo rootx .] ; set winr [expr {$winl + [winfo width .]}]
    # Reserve room for a cascade submenu only as far as the slack allows: the
    # full reserve used to shove the whole menu far LEFT of its button (the
    # encoding picker's "Other (all)" cascade is wide).  The menu itself stays
    # inside the window; a cascade may overflow it and Tk keeps that on screen.
    set reserve [els::menu_cascade_reserve $menu]
    set slack [expr {$winr - $mw - $nx}]
    if {$reserve > $slack} { set reserve [expr {$slack > 0 ? $slack : 0}] }
    set maxx [expr {$winr - $mw - $reserve}]
    if {$nx > $maxx} { set nx $maxx }
    if {$nx < $winl}           { set nx $winl }
    if {$ny < [winfo rooty .]} { set ny [winfo rooty .] }
    tk_popup $menu $nx $ny
}
proc els::popup_enc_menu {} {
    if {$::els::active eq ""} return
    if {![winfo exists .encpop]} { els::build_enc_popup }
    set canReopen [expr {$::els::docPath($::els::active) ne ""}]
    .encpop entryconfigure "Reopen with Encoding" \
        -state [expr {$canReopen ? "normal" : "disabled"}]
    els::popup_up .encpop .sb.enc
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
    if {$::els::docRaw($id) eq ""} {
        # no cached on-disk bytes to re-decode (e.g. a recovered-but-unsaved tab);
        # decoding "" would silently blank the buffer — refuse instead.
        tk_messageBox -parent . -icon info -title els \
            -message "Nothing to reopen — this document's on-disk bytes aren't cached\
                      (recovered unsaved content). Save it first to re-read from disk."
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
    # a NEW encoding voids any earlier "lossy is fine" consent for the old one
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    $w edit reset
    $w edit modified 0
    els::update_tab $id
    els::settitle
    els::refresh_view
}
proc els::save_with {enc bom} {
    set id $::els::active
    if {$id eq ""} { return }
    if {$::els::docEnc($id) eq $enc && $::els::docBom($id) == $bom} { return }
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    # a NEW encoding voids any earlier "lossy is fine" consent for the old one
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    [els::W $id] edit modified 1
    els::swap_meta_touch $id       ;# the swap must carry the new encoding
    els::update_tab $id
    els::settitle
}
proc els::build_eol_popup {} {
    menu .eolpop -tearoff 0
    foreach {lbl v} {"LF (Unix / macOS)" lf "CRLF (Windows)" crlf "CR (classic Mac)" cr} {
        .eolpop add command -label $lbl -command [list els::set_eol $v]
    }
}
proc els::popup_eol_menu {} {
    if {$::els::active eq ""} return
    if {![winfo exists .eolpop]} { els::build_eol_popup }
    els::popup_up .eolpop .sb.eol
}
proc els::set_eol {v} {
    set id $::els::active
    if {$id eq "" || $::els::docEol($id) eq $v} return
    set ::els::docEol($id) $v
    [els::W $id] edit modified 1   ;# make the change saveable
    els::swap_meta_touch $id       ;# the swap must carry the new EOL
    els::update_tab $id
    els::settitle
}

# ---- file operations ----------------------------------------------------
# Filters for the Open / Save dialogs.  Text files are first so .txt is the
# default type, while All files remains available for extensionless or unusual
# names.
proc els::filetypes {} {
    return {
        {{Text}           {.txt}}
        {{All files}      *}
        {{Tcl}            {.tcl}}
        {{C / C++}        {.c .h .cpp .hpp .cc}}
        {{Web}            {.html .htm .css .js .json .xml}}
        {{Shell / config} {.sh .ini .conf .cfg .toml .yml .yaml}}
    }
}
proc els::new {} {
    els::new_doc
}
proc els::open {{p ""} {quiet 0}} {
    if {$p eq ""} {
        set p [tk_getOpenFile -parent . -filetypes [els::filetypes]]
        if {$p eq ""} { return }
    }
    if {![catch {file normalize $p} np]} { set p $np }
    variable active
    variable docPath
    foreach id $::els::docs {
        if {[info exists docPath($id)] && [els::same_path $docPath($id) $p]} {
            els::switch_to $id
            els::recent_add $p
            return $id
        }
    }
    set prevActive $active
    set created 0
    if {[els::pristine $active]} {
        set id $active
    } else {
        set id [els::new_doc]
        set created 1
    }
    set w [els::W $id]
    if {[catch {
        set fh [::open $p r]
        fconfigure $fh -translation binary
        set raw [read $fh]
        close $fh
    } err]} {
        if {!$quiet} {
            tk_messageBox -parent . -icon error -title els -message "Cannot open file:\n$err"
        }
        # discard only a doc WE created for this open — a reused pre-existing
        # pristine tab is the user's; and return focus to the tab that was
        # active before (close_doc's neighbor pick lands on an arbitrary one)
        if {$created && [llength $::els::docs] > 1} { els::close_doc $id }
        if {$prevActive ne "" && $prevActive in $::els::docs} {
            els::switch_to $prevActive
        }
        return ""
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
    els::cache_saved_sig $id
    $w edit reset
    $w edit modified 0
    els::switch_to $id
    els::update_tab $id
    els::settitle
    els::refresh_view
    els::recent_add $p
    return $id
}
# Emit the bytes to the (temp) save channel.  A one-line seam so a test can force
# a mid-write failure and prove the atomic temp never touches the real file.
proc els::_save_emit {chan bytes} {
    puts -nonewline $chan $bytes
}
# Atomically replace $path's contents with $bytes: write a same-directory temp,
# then rename it over the target.  On Windows `file rename -force` is a single
# MoveFileEx(REPLACE_EXISTING) — atomic on the same NTFS volume — so a crash,
# disk-full, or I/O error mid-write can NEVER truncate or corrupt the existing
# file (the old in-place `open w` truncated it the instant it opened).  Returns
# "" on success, else an error message; on any failure the original is left
# intact and the temp is cleaned up.  Refuses a read-only target, matching the
# old behavior.
#
# Metadata: the native build prefers Win32 ReplaceFileW (src/winfs.c,
# els::win_replace_file) for the replace, which DOES preserve the target's ACLs,
# alternate data streams (e.g. the mark-of-the-web), and attributes.  When that
# command is absent (a dev/tclsh run) the plain `file rename -force` below is used,
# which does not carry those; a >260-char or locked target falls back to an
# in-place write (non-atomic only for those rare cases).
proc els::write_atomic {path bytes {tmpHint ""}} {
    if {[file exists $path] && ![catch {file attributes $path -readonly} ro] && $ro} {
        return "the file is read-only"
    }
    # A caller-supplied temp name keeps concurrent writers (the swap fan-out loop)
    # from colliding on a shared [clock clicks]; saves use the default per-pid name.
    set tmp [file join [file dirname $path] \
                 [expr {$tmpHint ne "" ? $tmpHint \
                        : [format ".els-save-%d-%d.tmp" [pid] [clock clicks]]}]]
    set fh ""
    if {[catch {
        set fh [::open $tmp {WRONLY CREAT TRUNC}]
        fconfigure $fh -translation binary
        els::_save_emit $fh $bytes
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        catch {file delete -force $tmp}
        return $e   ;# temp write failed; original untouched — do NOT fall back to
                    ;# an in-place truncate (it could also fail and lose the file)
    }
    # Prefer ReplaceFileW (native build, src/winfs.c) when replacing an existing
    # file: it is atomic AND preserves the target's ACLs, alternate data streams
    # (e.g. the mark-of-the-web), and attributes — which a rename-replace drops.
    if {[file exists $path] && [llength [info commands ::els::win_replace_file]]} {
        if {[els::win_replace_file [file nativename $path] [file nativename $tmp]] eq ""} {
            return ""
        }
        # ReplaceFileW failed — fall through; the temp is still present.
    }
    if {![catch {file rename -force $tmp $path}]} {
        return ""   ;# plain atomic rename — the common path without the C helper
    }
    # `file rename -force` cannot overwrite a target on a >260-char path (a locked
    # target also blocks it).  The temp holds a full new copy and the original is
    # still intact, so fall back to a direct in-place write — saving never
    # regresses to "can't save where it used to" (non-atomic only for these rare
    # cases).
    catch {file delete -force $tmp}
    return [els::_write_inplace $path $bytes]
}
# Direct in-place write (the pre-atomic behavior): only a fallback for when an
# atomic rename is impossible (very long path / locked target).
proc els::_write_inplace {path bytes} {
    set fh ""
    if {[catch {
        set fh [::open $path {WRONLY CREAT TRUNC}]
        fconfigure $fh -translation binary
        els::_save_emit $fh $bytes
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        return $e
    }
    return ""
}

# ===========================================================================
#  CRASH RECOVERY / AUTOSAVE (R2)
#  ---------------------------------------------------------------------------
#  Per-dirty-doc swap files under <configdir>/swap/, written atomically and
#  often; orphaned swaps from a dead session are offered for non-destructive
#  recovery on the next launch.  Never auto-writes the user's file.
# ===========================================================================

# ---- session identity ----------------------------------------------------
# A per-run id "host-pid-token".  pid disambiguates concurrent instances; the
# token (folded from microseconds/clicks/pid/rand) disambiguates a pid reused
# across runs.  Memoized so every swap from one run shares one id.
proc els::host_tag {} {
    set h ""
    catch {set h [string tolower [info hostname]]}
    regsub -all {[^a-z0-9_]} $h _ h
    if {$h eq ""} { set h unknown }
    return $h
}
proc els::session_token {} {
    if {$::els::session_token_cached ne ""} { return $::els::session_token_cached }
    set seed "[clock microseconds]:[clock clicks]:[pid]:[info hostname]"
    for {set i 0} {$i < 4} {incr i} { append seed ":[expr {int(rand()*0x7fffffff)}]" }
    set ::els::session_token_cached \
        [format %08x%08x [zlib crc32 $seed] [zlib crc32 "salt:$seed:[clock clicks]"]]
    return $::els::session_token_cached
}
proc els::session_id {} {
    if {$::els::session_id_cached ne ""} { return $::els::session_id_cached }
    set ::els::session_id_cached "[els::host_tag]-[pid]-[els::session_token]"
    return $::els::session_id_cached
}

# ---- swap directory + file paths -----------------------------------------
# "" in any inert context (config unresolved, --selftest): every writer no-ops.
proc els::swap_dir {} {
    if {$::els::config_path eq "" || $::els::selftest} { return "" }
    set d [file join [file dirname $::els::config_path] swap]
    if {[catch {file mkdir $d}]} { return "" }
    return $d
}
proc els::swap_path {sid id} { return [file join [els::swap_dir] "swp-$sid-$id.swp"] }
proc els::lock_path {{sid ""}} {
    if {$sid eq ""} { set sid [els::session_id] }
    return [file join [els::swap_dir] "$sid.lock"]
}

# ---- the swap file: framed, self-validating ------------------------------
#   ELSSWAP v1\n  <payload bytes>  \nELSSWAPEND <len> <crc32>\n
# Payload is a Tcl dict (UTF-8).  The trailer is the last "ELSSWAPEND " line, so
# the payload may contain newlines (the body does).  Read validates len+crc and
# returns "" on any corruption -- never raises.
proc els::swap_serialize {id sid} {
    set w [els::W $id]
    # store the buffer as the internal (LF) string; encoding the whole dict to
    # UTF-8 once (below) is lossless and never goes through the doc's lossy enc.
    set text [$w get 1.0 "end - 1 char"]
    # -profile replace on BOTH conversions: Tcl 9's default strict profile
    # throws on an unpaired surrogate (which the Tk text widget happily holds,
    # e.g. from a malformed clipboard paste) — and a throw here, swallowed by
    # swap_flush_doc's catch, would silently kill crash protection for the doc.
    set d [dict create schema 1 sessionId $sid docId $id \
               path $::els::docPath($id) enc $::els::docEnc($id) \
               bom $::els::docBom($id) eol $::els::docEol($id) \
               cursor [$w index insert] dirty [els::doc_dirty $id] \
               savedSig [els::doc_saved_sig $id] mtime [clock seconds] \
               host [els::host_tag] \
               bodyCrc [zlib crc32 [encoding convertto -profile replace utf-8 $text]] \
               text $text]
    set payload [encoding convertto -profile replace utf-8 $d]
    return "ELSSWAP v1\n$payload\nELSSWAPEND [string length $payload] [zlib crc32 $payload]\n"
}
# Returns the validated dict, or "" on any corruption.  Never raises.  (No
# `return` inside the catch -- that makes catch report code 2 and swallow the
# value; set then return after.)
proc els::swap_read {file} {
    set d ""
    if {[catch {
        set fh [::open $file rb]
        set all [read $fh]
        close $fh
        set magic "ELSSWAP v1\n"
        if {[string range $all 0 [expr {[string length $magic]-1}]] ne $magic} { error bad }
        set body [string range $all [string length $magic] end]
        set idx [string last "\nELSSWAPEND " $body]   ;# the LAST trailer line
        if {$idx < 0} { error bad }
        set payload [string range $body 0 [expr {$idx-1}]]
        set trailer [string trimright [string range $body [expr {$idx+1}] end] "\n"]
        if {![regexp {^ELSSWAPEND ([0-9]+) ([0-9]+)$} $trailer -> declen declcrc]} { error bad }
        if {[string length $payload] != $declen} { error bad }
        if {[zlib crc32 $payload] != $declcrc} { error bad }
        set d [encoding convertfrom utf-8 $payload]
        if {![dict exists $d schema] || [dict get $d schema] != 1} { error bad }
        # all keys the recovery path consumes must be present: ONE incomplete
        # (yet validly framed) swap must not throw mid-scan and silently abort
        # recovery for the whole batch
        foreach k {sessionId docId path enc bom eol dirty savedSig mtime text} {
            if {![dict exists $d $k]} { error bad }
        }
    }]} { return "" }
    return $d
}

# ---- change-detection + on-disk file signatures --------------------------
# buf_sig: "chars:crc" of the LF-internal buffer.  Cheap char-count first; only
# above SWAP_SIG_FULL_CAP and only when an edit was latched (dirtySince) do we
# pay the O(n) crc -- an idle large dirty doc costs nothing per tick.
proc els::buf_sig {id} {
    set w [els::W $id]
    set chars [$w count -chars 1.0 "end - 1 char"]
    # Above the cap, an idle dirty doc reuses its cached sig to skip the O(n) crc --
    # but only when the CHAR COUNT also still matches, so a length-changing edit
    # that didn't latch dirtySince (e.g. a programmatic Replace) is never missed.
    if {$chars > $::els::SWAP_SIG_FULL_CAP && \
            ![info exists ::els::dirtySince($id)] && \
            [info exists ::els::swapSig($id)] && \
            [lindex [split $::els::swapSig($id) :] 0] == $chars} {
        return $::els::swapSig($id)
    }
    return "$chars:[zlib crc32 [encoding convertto -profile replace utf-8 \
                                    [$w get 1.0 "end - 1 char"]]]"
}
# A signature of on-disk bytes "size:mtime:crc" (sampled crc above the cap), used
# to reconcile a swap's baseline against the file at recovery time.
proc els::sig_from_bytes {bytes mtime} {
    set size [string length $bytes]
    if {$size <= $::els::SWAP_FILE_CRC_CAP} {
        set crc [zlib crc32 $bytes]
    } else {
        set crc [zlib crc32 "[string range $bytes 0 65535][string range $bytes end-65535 end]"]
    }
    return "$size:$mtime:$crc"
}
proc els::file_sig {path} {
    if {[catch {file stat $path st}]} { return "" }
    # Single open + single guaranteed close; NO `return` inside the catch (that
    # makes catch report code 2 and the outer `if` take the error branch — which
    # silently broke this for >16 MB files).  fh tracked so an I/O fault can't leak.
    set fh ""
    set sig ""
    if {[catch {
        set fh [::open $path rb]
        if {$st(size) <= $::els::SWAP_FILE_CRC_CAP} {
            set bytes [read $fh]
        } else {
            set head [read $fh 65536]
            seek $fh -65536 end
            set tail [read $fh 65536]
            set bytes "$head$tail"   ;# sampled: matches sig_from_bytes' >cap branch
        }
        close $fh
        set fh ""
        set sig "$st(size):$st(mtime):[zlib crc32 $bytes]"
    }]} {
        if {$fh ne ""} { catch {close $fh} }
        return ""
    }
    return $sig
}
# Cache the doc's on-disk signature from the bytes we already hold (the exact
# loaded/saved bytes) plus the file's mtime -- one consistent source.
proc els::cache_saved_sig {id} {
    if {$::els::docPath($id) eq ""} { set ::els::savedSig($id) ""; return }
    set mtime 0
    catch {set mtime [file mtime $::els::docPath($id)]}
    set ::els::savedSig($id) [els::sig_from_bytes $::els::docRaw($id) $mtime]
}
proc els::doc_saved_sig {id} {
    if {[info exists ::els::savedSig($id)]} { return $::els::savedSig($id) }
    return ""
}

# ---- the writer (single idempotent path) ---------------------------------
# Never raises (catch-wrapped I/O).  Writes a swap only when there are unsaved
# edits AND the buffer changed since the last swap.
proc els::swap_flush_doc {id} {
    if {!$::els::swap_enabled || $::els::swap_suspend} { return 0 }
    if {![info exists ::els::docPath($id)]} { return 0 }
    if {[els::swap_dir] eq ""} { return 0 }
    if {![winfo exists [els::W $id]]} { return 0 }
    if {[info exists ::els::loading($id)]} { return 0 }
    if {![els::doc_dirty $id]} { return 0 }   ;# clean doc: nothing to protect
    if {[els::pristine $id]} { return 0 }
    set done 0
    catch {
        set sig [els::buf_sig $id]
        if {[info exists ::els::swapSig($id)] && $sig eq $::els::swapSig($id)} {
            # content verified unchanged since the last swap: drop the latch so
            # an idle large doc returns to the cheap cached-sig path (else every
            # cursor movement would keep re-paying the O(n) crc per tick)
            unset -nocomplain ::els::dirtySince($id)
        } else {
            set sid [els::session_id]
            set bytes [els::swap_serialize $id $sid]
            if {[els::write_atomic [els::swap_path $sid $id] $bytes ".swp-$sid-$id.tmp"] eq ""} {
                set ::els::swapSig($id) $sig
                unset -nocomplain ::els::dirtySince($id)
                set done 1
            }
        }
    }
    return $done
}
proc els::swap_flush_all {} { foreach id $::els::docs { els::swap_flush_doc $id } }
# A doc's encoding/EOL metadata changed without a content edit: force the next
# autosave pass to rewrite the swap.  buf_sig is content-only, so an already-
# current swap would otherwise keep the OLD metadata and crash recovery would
# silently revert the user's explicit encoding/EOL choice.
proc els::swap_meta_touch {id} {
    unset -nocomplain ::els::swapSig($id)
    set ::els::dirtySince($id) 1
    els::swap_flush_soon
}
proc els::swap_clear {id} {
    # guard the delete: with no swap dir, swap_path degrades to a RELATIVE name
    # and the delete would aim at the current working directory
    if {[els::swap_dir] ne ""} {
        catch {file delete -force [els::swap_path [els::session_id] $id]}
    }
    unset -nocomplain ::els::swapSig($id) ::els::dirtySince($id)
}

# ---- timers --------------------------------------------------------------
proc els::swap_tick {} {
    incr ::els::swap_tick_count
    # catch the work so an unexpected throw can NEVER skip the reschedule below --
    # that would silently kill autosave for the rest of the session.
    catch {els::swap_flush_all}
    if {($::els::swap_tick_count % $::els::HEARTBEAT_EVERY) == 0} { catch {els::lock_heartbeat} }
    set ::els::swap_after [after $::els::swap_interval els::swap_tick]   ;# reschedule after work
}
proc els::swap_flush_soon {} {
    if {!$::els::swap_enabled} return
    if {$::els::swap_touch_after ne ""} { after cancel $::els::swap_touch_after }
    set ::els::swap_touch_after \
        [after $::els::swap_debounce {set ::els::swap_touch_after ""; els::swap_flush_all}]
}
# Bound to actual edit events so a sustained typing burst (which never re-fires
# <<Modified>>) keeps re-arming dirtySince + the debounce, coalescing to one
# write ~swap_debounce after typing pauses.
proc els::swap_touch {} {
    # Latch only a doc that actually has unsaved changes: plain <KeyRelease>
    # also fires for arrow keys / PgUp / the Ctrl+S release itself, and latching
    # a CLEAN doc wrote swap files for it — after a crash, the recovery dialog
    # then offered bogus "unsaved changes" for every file merely navigated
    # (worst case resurrecting pre-crash bytes over a newer external edit).
    set id $::els::active
    if {$id eq "" || ![els::doc_dirty $id]} { return }
    set ::els::dirtySince($id) 1
    els::swap_flush_soon
}
proc els::swap_start {} {
    if {!$::els::swap_enabled || $::els::selftest} { return }
    if {[els::swap_dir] eq ""} { return }
    if {$::els::swap_after ne ""} { return }
    set ::els::swap_after [after $::els::swap_interval els::swap_tick]
}
proc els::swap_stop {} {
    if {$::els::swap_after ne ""} { after cancel $::els::swap_after; set ::els::swap_after "" }
    if {$::els::swap_touch_after ne ""} { after cancel $::els::swap_touch_after; set ::els::swap_touch_after "" }
    els::handoff_stop
}

# ---- liveness lock -------------------------------------------------------
# Held Win32 byte-range lock (native build): the OS frees it the instant the
# process dies, so "lock acquirable -> owner is dead" survives crash, kill, and
# even a fast reboot/power-loss (unlike an mtime heartbeat).  Pure-Tcl builds
# fall back to mtime freshness.
proc els::lock_acquire {} {
    set d [els::swap_dir]
    if {$d eq ""} { return 0 }
    set lp [els::lock_path]
    catch {
        set fh [::open $lp w]
        puts $fh [dict create pid [pid] token [els::session_token] \
                      host [els::host_tag] started [clock seconds] ver 1]
        close $fh
    }
    if {[llength [info commands ::els::win_lock_file]]} {
        if {[els::win_lock_file [file nativename $lp]] eq ""} {
            set ::els::lock_handle 1
        } else {
            # native lock failed (AV interference, exotic FS): hold the channel
            # anyway so mtime-fallback peers still see this session as alive
            catch {set ::els::lock_chan [::open $lp {RDWR}]}
        }
    } else {
        catch {set ::els::lock_chan [::open $lp {RDWR}]}
    }
    return 1
}
proc els::lock_heartbeat {} { catch {file mtime [els::lock_path] [clock seconds]} }
proc els::lock_release {} {
    if {[llength [info commands ::els::win_unlock_file]]} { catch {els::win_unlock_file} }
    if {$::els::lock_chan ne ""} { catch {close $::els::lock_chan} }
    set ::els::lock_chan ""
    set ::els::lock_handle ""
}
# 1 if the session that owns <lp> is alive.  Native try-lock is authoritative;
# mtime is the pure-Tcl fallback only (never ORs over a successful native probe).
proc els::lock_is_live {sid lp} {
    if {!$::els::swap_test_mtime && [llength [info commands ::els::win_try_lock]]} {
        return [expr {[els::win_try_lock [file nativename $lp]] == 0}]
    }
    if {![file exists $lp]} { return 0 }
    if {[catch {file mtime $lp} mt]} { return 0 }
    return [expr {([clock seconds] - $mt) < $::els::STALE_SECS}]
}

# ---- single instance + file handoff --------------------------------------
# els is single-instance per config dir: a second launch hands its file args to
# the running instance (which opens them as tabs and raises itself) and exits.
# Detection reuses the per-session liveness locks already in the swap dir — no
# extra lock.  ELS_NO_SINGLE_INSTANCE opts out entirely (tests, probes, and any
# user who genuinely wants concurrent windows).
proc els::single_instance_off {} {
    return [expr {[info exists ::env(ELS_NO_SINGLE_INSTANCE)] && $::env(ELS_NO_SINGLE_INSTANCE) ne ""}]
}
proc els::handoff_dir {} {
    if {$::els::config_path eq "" || $::els::selftest} { return "" }
    set d [file join [file dirname $::els::config_path] handoff]
    if {[catch {file mkdir $d}]} { return "" }
    return $d
}
# Is a live els already running in THIS config dir?  Called at startup BEFORE we
# build / acquire our own session lock, so there is no own-lock to exclude.
proc els::primary_running {} {
    if {[els::single_instance_off]} { return 0 }
    lassign [els::config_candidates] near appdata
    set cfg ""
    if {[file exists $near]} { set cfg $near } elseif {[file exists $appdata]} { set cfg $appdata }
    if {$cfg eq ""} { return 0 }   ;# first run: no primary yet
    set swapdir [file join [file dirname $cfg] swap]
    foreach lp [glob -nocomplain -directory $swapdir *.lock] {
        set sid [file rootname [file tail $lp]]
        if {[els::lock_is_live $sid $lp]} { return 1 }
        # native is authoritative; pure-Tcl mtime fallback may false-positive,
        # but the worst case is a missed handoff (we just open our own window)
    }
    return 0
}
# Secondary: spool our file args for the primary, then the caller exits.  The
# file appears atomically (temp+rename) so the primary never reads a partial
# one.  An empty payload still means "raise yourself" (bare relaunch).
proc els::handoff_send {cfg fileArgs} {
    set hd [file join [file dirname $cfg] handoff]
    if {[catch {file mkdir $hd}]} { return }
    set norm {}
    foreach f $fileArgs {
        if {[string index $f 0] eq "-"} continue
        if {![catch {file normalize $f} n]} { lappend norm $n }
    }
    set target [file join $hd "[pid]-[clock clicks].open"]
    catch {els::write_atomic $target [join $norm \n] ".ho-[pid]-[clock clicks].tmp"}
}
# Primary: drain the spool — open each handed-off path as a tab and raise the
# window.  Runs on a light poll while single-instance is active.
proc els::handoff_drain {} {
    set hd [els::handoff_dir]
    if {$hd eq ""} { return }
    set raise 0
    foreach f [lsort [glob -nocomplain -directory $hd *.open]] {
        set data ""
        catch { set fh [::open $f r]; fconfigure $fh -encoding utf-8; set data [read $fh]; close $fh }
        catch {file delete -force $f}
        set raise 1
        foreach p [split $data \n] {
            if {$p ne "" && [file exists $p]} { catch {els::open $p} }
        }
    }
    if {$raise} { els::raise_window }
}
proc els::raise_window {} {
    catch {wm deiconify .}
    catch {raise .}
    # a brief topmost flip reliably pulls the window to the foreground on Windows
    catch {wm attributes . -topmost 1}
    after 250 {catch {wm attributes . -topmost [expr {$::els::always_on_top ? 1 : 0}]}}
    catch {focus -force .}
}
proc els::handoff_start {} {
    if {[els::single_instance_off] || $::els::selftest} { return }
    if {[els::handoff_dir] eq ""} { return }
    if {$::els::handoff_after ne ""} { return }
    els::handoff_tick
}
proc els::handoff_tick {} {
    catch {els::handoff_drain}
    set ::els::handoff_after [after 500 els::handoff_tick]
}
proc els::handoff_stop {} {
    if {$::els::handoff_after ne ""} { after cancel $::els::handoff_after; set ::els::handoff_after "" }
}

# ---- orphan enumeration + reconcile --------------------------------------
# Scan globs swp-*.swp and derives the owning session from the PAYLOAD (not the
# filename), so a swap is never stranded by a renamed/lost lock.  Orphan = a swap
# whose session has no live lock (and isn't ours).
proc els::swap_scan_orphans {} {
    set d [els::swap_dir]
    if {$d eq ""} { return {} }
    set mine [els::session_id]
    set live [dict create]
    set out {}
    foreach f [glob -nocomplain -directory $d swp-*.swp] {
        set rec [els::swap_read $f]
        if {$rec eq ""} { continue }   ;# unreadable: maybe a TRANSIENT lock on a live
                                       ;# peer's swap -- never delete here; the age-based
                                       ;# sweep reclaims genuinely-old corrupt swaps
        set sid [dict get $rec sessionId]
        if {$sid eq $mine} continue
        if {![dict exists $live $sid]} {
            dict set live $sid [els::lock_is_live $sid [els::lock_path $sid]]
        }
        if {[dict get $live $sid]} continue                           ;# owned by a live peer
        lappend out [list $f $rec]
    }
    return $out
}
# branch: untitled | missing | match | changed
proc els::recover_reconcile {rec} {
    set path [dict get $rec path]
    if {$path eq ""} { return untitled }
    if {![file exists $path]} { return missing }
    set base [dict get $rec savedSig]
    if {$base ne "" && [els::file_sig $path] eq $base} { return match }
    return changed
}
# Claim an orphan session once so two live instances don't both recover it.
# A separate marker (not the lock), exclusive-create; a crashed claimer's stale
# marker is swept by age and the swaps -- keyed off swp-*.swp -- stay recoverable.
proc els::orphan_claim {sid} {
    set d [els::swap_dir]
    if {$d eq ""} { return 1 }
    set cp [file join $d "$sid.claimed"]
    if {[catch {set ch [::open $cp {WRONLY CREAT EXCL}]}]} { return 0 }
    catch {puts $ch "[els::session_id] [clock seconds]"; close $ch}
    return 1
}
# Returns a list of plan triples {swapfile recordDict branch} for claimed orphans.
proc els::recover_scan {} {
    set claimed [dict create]
    set out {}
    foreach pair [els::swap_scan_orphans] {
        lassign $pair f rec
        set sid [dict get $rec sessionId]
        if {![dict exists $claimed $sid]} {
            set got [els::orphan_claim $sid]
            dict set claimed $sid $got
            if {$got} {
                # remember the marker so "Later" / quit can release it — else
                # the next launch within STALE_SECS finds the orphan already
                # claimed and silently withholds the recovery offer
                lappend ::els::recover_claims [file join [els::swap_dir] "$sid.claimed"]
            }
        }
        if {![dict get $claimed $sid]} continue
        set branch [els::recover_reconcile $rec]
        # a swap recorded for a CLEAN doc whose file is unchanged on disk has
        # nothing to recover (pre-fix sessions wrote those for merely-navigated
        # files): reclaim it instead of offering a bogus recovery
        if {![dict get $rec dirty] && $branch eq "match"} {
            catch {file delete -force $f}
            continue
        }
        lappend out [list $f $rec $branch]
    }
    return $out
}
# Release the orphan-claim markers created by THIS session's scan.  Without
# this, "Later" (or quitting with the dialog open) hid the deferred recovery
# from any relaunch within STALE_SECS.
proc els::recover_release_claims {} {
    foreach c $::els::recover_claims { catch {file delete -force $c} }
    set ::els::recover_claims {}
}
proc els::recover_dialog_close {top} {
    els::recover_release_claims
    catch {destroy $top}
}

# ---- litter sweep + teardown ---------------------------------------------
proc els::swap_sweep {} {
    set d [els::swap_dir]
    if {$d eq ""} { return }
    set now [clock seconds]
    catch {
        foreach f [glob -nocomplain -directory $d .swp-*.tmp] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::STALE_SECS} {
                catch {file delete -force $f}
            }
        }
        # genuinely-corrupt swaps: old AND unreadable.  A live session keeps its
        # swap fresh, so an old+unreadable one is safe to reclaim (a transient lock
        # on a live peer's swap leaves the mtime recent, so it is never swept here).
        foreach f [glob -nocomplain -directory $d swp-*.swp] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::STALE_SECS \
                    && [els::swap_read $f] eq ""} {
                catch {file delete -force $f}
            }
        }
        foreach f [glob -nocomplain -directory $d *.claimed] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::STALE_SECS} {
                catch {file delete -force $f}
            }
        }
        # handoff spool files a primary never drained (false-positive liveness)
        set hd [file join [file dirname $::els::config_path] handoff]
        foreach f [glob -nocomplain -directory $hd *.open .ho-*.tmp] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::STALE_SECS} {
                catch {file delete -force $f}
            }
        }
        # previous-version backups age out after BK_MAXAGE (default 30 days)
        set bd [file join [file dirname $::els::config_path] backups]
        foreach f [glob -nocomplain -directory $bd *.bak] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::BK_MAXAGE} {
                catch {file delete -force $f}
            }
        }
        # orphan locks: dead session with no surviving swaps
        foreach f [glob -nocomplain -directory $d *.lock] {
            set sid [file rootname [file tail $f]]
            if {$sid eq [els::session_id]} continue
            if {[els::lock_is_live $sid $f]} continue
            if {[llength [glob -nocomplain -directory $d "swp-$sid-*.swp"]]} continue
            catch {file delete -force $f}
        }
    }
}
# Clean teardown order: stop timers -> delete OUR swaps -> release+delete lock.
# A swap must never outlive its lock (else a peer would false-orphan it).  Only
# ever reached on a committed exit -- never on a crash or a cancelled quit.
proc els::swap_shutdown {} {
    catch {els::swap_stop}
    catch {foreach id $::els::docs { els::swap_clear $id }}
    catch {els::lock_release}
    catch {file delete -force [els::lock_path]}
    # markers are named after the ORPHAN session we claimed, never our own id —
    # release the tracked ones so deferred recovery survives a clean quit
    catch {els::recover_release_claims}
}

# ---- recovery: load into a DIRTY buffer (never auto-write) ----------------
# Loads a swap's lossless UTF-8 body into an in-memory dirty tab.  Metadata comes
# from the RECORD (never re-detected), so a lossy-encoded doc round-trips exactly.
# Merges onto an existing CLEAN tab for the same path; a user-dirtied tab is left
# alone and the recovery opens as a separate "(recovered)" tab.
proc els::recover_load {rec branch} {
    set path [dict get $rec path]
    set body [dict get $rec text]   ;# already the internal (LF) string
    set tid ""
    if {$path ne ""} {
        foreach id $::els::docs {
            if {[info exists ::els::docPath($id)] && [els::same_path $::els::docPath($id) $path]} {
                if {![els::doc_dirty $id]} { set tid $id }
                break
            }
        }
    }
    set fresh 0
    if {$tid eq ""} {
        set tid [els::new_doc]
        set fresh 1
        if {$path ne ""} { set ::els::docPath($tid) $path }
        set ::els::docRaw($tid) ""           ;# new tab: no on-disk bytes cached yet
        set ::els::docRecovered($tid) 1      ;# mark a separate recovered tab as such
    }
    # NB: when merging onto an existing clean tab, its docRaw (loaded from disk by
    # els::open) is LEFT INTACT — clobbering it would blank a later "Reopen with
    # Encoding".  We never re-detect: the swap record is authoritative.
    set w [els::W $tid]
    set ::els::loading($tid) 1
    $w delete 1.0 end
    $w insert end $body
    set ::els::docEnc($tid) [dict get $rec enc]
    set ::els::docBom($tid) [dict get $rec bom]
    set ::els::docEol($tid) [dict get $rec eol]
    catch {$w mark set insert [dict get $rec cursor]}
    catch {$w see insert}
    $w edit reset
    $w edit modified 1
    unset -nocomplain ::els::loading($tid)
    set ::els::dirtySince($tid) 1
    els::update_tab $tid
    els::settitle
    return $tid
}
# decision: recover | discard.  Suspends autosave so the running tick can't write
# a fresh swap of the recovered body before the orphan is cleared.  The orphan
# swap is deleted only AFTER a successful load (delete-last), so a failed load
# preserves it for the next attempt.
proc els::recover_apply {plan decision} {
    lassign $plan f rec branch
    catch {
        set ::els::swap_suspend 1
        switch -- $decision {
            recover {
                set id [els::recover_load $rec $branch]
                if {$id ne "" && [winfo exists [els::W $id]]} { catch {file delete -force $f} }
            }
            discard { catch {file delete -force $f} }
        }
    }
    set ::els::swap_suspend 0
}

# ---- startup orchestration + the consolidated dialog ----------------------
proc els::recover_boot {openedArgs} {
    catch {els::swap_sweep}
    if {!$openedArgs} {
        # a plain start owns the stored session from here on (whether or not
        # restoring is enabled or anything was restorable)
        set ::els::session_owned 1
        if {$::els::restore_session} { catch {els::session_restore} }
    }
    set recs {}
    catch {set recs [els::recover_scan]}
    set ::els::last_recover [llength $recs]
    if {[llength $recs]} { catch {els::recover_offer $recs} }
}
proc els::recover_label {rec branch} {
    set path [dict get $rec path]
    # no expr ternary on path data: a file named "nan" threw out of expr here,
    # and the swallowed throw silently suppressed the WHOLE recovery dialog
    if {$path eq ""} { set name "untitled" } else { set name [file tail $path] }
    set when ""
    catch {set when [clock format [dict get $rec mtime] -format "%Y-%m-%d %H:%M"]}
    switch -- $branch {
        untitled { set note "unsaved new document" }
        missing  { set note "original file is gone" }
        match    { set note "file unchanged since" }
        changed  { set note "file changed on disk since" }
        default  { set note "" }
    }
    return [list $name $note $when]
}
# One consolidated, non-modal dialog for the whole batch (never one modal per
# file).  recover_auto / ELS_RECOVER_AUTO auto-apply (probe + tests).
proc els::recover_offer {records} {
    if {![llength $records]} return
    if {$::els::recover_auto || [info exists ::env(ELS_RECOVER_AUTO)]} {
        foreach p $records { catch {els::recover_apply $p recover} }
        els::recover_release_claims
        return
    }
    set top .recover
    catch {destroy $top}
    toplevel $top -bg $::els::PAGE
    wm withdraw $top
    if {$::els::probe_quiet} { catch {wm attributes $top -alpha 0.0} }
    wm title $top "Recover unsaved changes"
    wm transient $top .
    ttk::frame $top.f -padding 16 ; pack $top.f -fill both -expand 1
    ttk::label $top.f.h -text "els found unsaved changes from a previous session." \
        -font elsUIb -foreground $::els::INK
    ttk::label $top.f.s -font elsUI -foreground $::els::MUTED -justify left \
        -text "These were autosaved when els closed unexpectedly. Recover them into\neditable tabs (nothing is written to disk until you Save), or discard."
    grid $top.f.h -row 0 -column 0 -sticky w -pady {0 3}
    grid $top.f.s -row 1 -column 0 -sticky w -pady {0 12}
    set lf $top.f.list
    ttk::frame $lf
    grid $lf -row 2 -column 0 -sticky we -pady {0 12}
    set r 0
    set ::els::_recover_pick [dict create]
    foreach p $records {
        lassign $p f rec branch
        lassign [els::recover_label $rec $branch] name note when
        set var ::els::_recover_chk($r)
        set $var [expr {$branch ne "missing"}]   ;# default-check all but vanished originals
        ttk::checkbutton $lf.c$r -variable $var -text $name -style TCheckbutton
        ttk::label $lf.n$r -font elsUI -foreground $::els::MUTED -text "  $note $when"
        grid $lf.c$r -row $r -column 0 -sticky w
        grid $lf.n$r -row $r -column 1 -sticky w
        dict set ::els::_recover_pick $r $p
        incr r
    }
    set bf $top.f.btns
    ttk::frame $bf
    grid $bf -row 3 -column 0 -sticky e
    ttk::button $bf.rec -text "Recover checked" -command [list els::recover_dialog_apply $top recover]
    ttk::button $bf.dis -text "Discard checked" -command [list els::recover_dialog_apply $top discard]
    ttk::button $bf.cancel -text "Later" -command [list els::recover_dialog_close $top]
    grid $bf.rec -row 0 -column 0 -padx {0 6}
    grid $bf.dis -row 0 -column 1 -padx {0 6}
    grid $bf.cancel -row 0 -column 2
    bind $top <Escape> [list els::recover_dialog_close $top]
    wm protocol $top WM_DELETE_WINDOW [list els::recover_dialog_close $top]
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth  $top]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $top]) / 3}]
    wm geometry $top +$x+$y
    wm deiconify $top
}
proc els::recover_dialog_apply {top decision} {
    foreach r [lsort -integer [dict keys $::els::_recover_pick]] {
        set chk 1
        catch {set chk [set ::els::_recover_chk($r)]}
        if {$decision eq "recover" && !$chk} continue   ;# unchecked: leave the swap for later
        if {$decision eq "discard" && !$chk} continue
        els::recover_apply [dict get $::els::_recover_pick $r] $decision
    }
    # releasing the claim markers lets the next launch re-offer any swaps that
    # were left unchecked (it re-claims them then)
    els::recover_dialog_close $top
}
# ---- lossy-save guard ----------------------------------------------------
# A save must never silently drop characters the document's encoding cannot
# represent.  Strict encoding via -failindex detects the first unencodable
# character without throwing; the user then chooses: switch the document to
# UTF-8 (keeps everything), save anyway with replacement characters (latched
# per document for the session), or cancel (nothing is written).

# First unencodable character, located by binary search on prefix length.
# We deliberately do NOT use the -failindex VALUE as a position: in Tcl 9.0.3
# it is a character index for some encodings but a byte index into the
# internal UTF-8 representation for others (e.g. gb2312-raw), contradicting
# encoding(n).  Only its sign ("did it fail") is trustworthy.
proc els::lossy_first {enc text} {
    set lo 0 ; set hi [string length $text]
    # invariant: the prefix of length lo encodes cleanly, the one of hi fails
    while {$lo + 1 < $hi} {
        set mid [expr {($lo + $hi) / 2}]
        encoding convertto -profile strict -failindex f $enc \
            [string range $text 0 [expr {$mid - 1}]]
        if {$f < 0} { set lo $mid } else { set hi $mid }
    }
    return [expr {$hi - 1}]
}

# Where and how big is the damage: line/col + codepoint of the first
# unencodable character, and how many there are.  The count walks per
# character from the first failure, capped (100 failures / 10000 chars) --
# it is dialog garnish, not bookkeeping.
proc els::lossy_describe {enc text} {
    set fi [els::lossy_first $enc $text]
    set before [string range $text 0 [expr {$fi - 1}]]
    set line [expr {1 + [regexp -all {\n} $before]}]
    set col  [expr {$fi - [string last \n $before]}]
    set uhex [format %04X [scan [string index $text $fi] %c]]
    set count 0
    set n [string length $text]
    set stop [expr {min($n, $fi + 10000)}]
    for {set i $fi} {$i < $stop && $count < 100} {incr i} {
        encoding convertto -profile strict -failindex f $enc [string index $text $i]
        if {$f >= 0} { incr count }
    }
    return [list $line $col $uhex $count]
}

# Modal three-way choice (utf8 | lossy | cancel).  The test suite replaces
# this proc with a canned-answer stub, like the native dialogs.
proc els::lossy_ask {id enc line col uhex count} {
    set top .lossy
    catch {destroy $top}
    toplevel $top -background $::els::PAGE
    wm withdraw $top
    wm title $top els
    wm transient $top .
    set countTxt [expr {$count >= 100 ? "100 or more" : $count}]
    set noun [expr {$count == 1 ? "character" : "characters"}]
    ttk::label $top.msg -justify left -text \
"This document contains $countTxt $noun that cannot be written
as [els::enc_label $enc 0] (first at line $line, column $col: U+$uhex).

Save as UTF-8 to keep every character, save anyway to replace
the unsupported ones with substitutes, or cancel."
    ttk::frame $top.b
    ttk::button $top.b.utf8   -text "Save as UTF-8" -command {set ::els::lossy_answer utf8}
    ttk::button $top.b.lossy  -text "Save anyway"   -command {set ::els::lossy_answer lossy}
    ttk::button $top.b.cancel -text Cancel          -command {set ::els::lossy_answer cancel}
    pack $top.b.utf8 $top.b.lossy $top.b.cancel -side left -padx 4
    pack $top.msg -padx 16 -pady {14 10}
    pack $top.b   -padx 16 -pady {0 12}
    wm protocol $top WM_DELETE_WINDOW {set ::els::lossy_answer cancel}
    bind $top <Escape> {set ::els::lossy_answer cancel}
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .] - [winfo reqwidth $top]) / 2}]
    set y [expr {[winfo rooty .] + 120}]
    wm geometry $top +$x+$y
    if {$::els::probe_quiet} { catch {wm attributes $top -alpha 0.0} }
    wm deiconify $top
    raise $top
    focus $top.b.utf8
    grab $top
    set ::els::lossy_answer ""
    vwait ::els::lossy_answer
    set ans $::els::lossy_answer
    catch {grab release $top}
    catch {destroy $top}
    if {$ans ni {utf8 lossy cancel}} { set ans cancel }
    return $ans
}

# A transient, quiet status message in the name slot (never a dialog) -- used
# by auto-save for failures.  The next update_namelabel restores the path.
proc els::status_note {msg} {
    if {![winfo exists .sb.name]} { return }
    catch {after cancel $::els::status_note_after}
    .sb.name configure -text $msg
    # while the timer is pending, update_namelabel leaves the note alone (a
    # successful save calls settitle right after, which must not clobber it)
    set ::els::status_note_after [after 4000 els::status_note_clear]
}
proc els::status_note_clear {} {
    set ::els::status_note_after ""
    catch {els::update_namelabel}
}

# ---- backups: previous versions ---------------------------------------------
# Every save that OVERWRITES an existing file first preserves that file's
# current content in <configdir>/backups/ (next to els.conf -- which is next
# to the exe for a portable install).  Bounded: a ring of BK_RING versions per
# file, a new backup is skipped while the newest is younger than BK_MININT
# seconds (so an auto-save burst keeps the pre-burst version instead of
# churning), files over BK_MAXSIZE are not backed up, and anything older than
# BK_MAXAGE is pruned by the periodic sweep.  Best-effort by design: a failing
# backup notes itself in the statusbar and never blocks the save.
proc els::backup_dir {} {
    if {$::els::config_path eq "" || $::els::selftest} { return "" }
    return [file join [file dirname $::els::config_path] backups]
}
# Stable per-file ring key: the filename stays human-readable, a hash of the
# full (case-folded) path keeps same-named files from different folders apart.
proc els::backup_stem {path} {
    set h [format %08x [zlib crc32 [encoding convertto -profile replace utf-8 \
        [string tolower [file normalize $path]]]]]
    return "[file tail $path].$h"
}
proc els::backup_keep {path} {
    if {!$::els::backups} { return }
    set dir [els::backup_dir]
    if {$dir eq ""} { return }
    if {[catch {file size $path} sz] || $sz > $::els::BK_MAXSIZE} { return }
    # NO `return` inside this catch body: catch traps TCL_RETURN too, which
    # would route the skip path into the "backup failed" note
    if {[catch {
        file mkdir $dir
        set stem [els::backup_stem $path]
        set ring [lsort [glob -nocomplain -directory $dir "$stem.*.bak"]]
        # a fresh-enough newest backup already preserves the interesting
        # (pre-burst) version: skip
        set newest [lindex $ring end]
        set fresh [expr {$newest ne "" && ![catch {file mtime $newest} mt] \
                         && [clock seconds] - $mt < $::els::BK_MININT}]
        if {!$fresh} {
            set stamp [clock format [clock seconds] -format %Y%m%d-%H%M%S]
            set target [file join $dir "$stem.$stamp.bak"]
            set n 2
            while {[file exists $target]} {     ;# same-second saves
                set target [file join $dir "$stem.$stamp-$n.bak"]
                incr n
            }
            set fh [::open $path rb] ; set bytes [read $fh] ; close $fh
            set werr [els::write_atomic $target $bytes]
            if {$werr ne ""} { error $werr }
            # prune the ring to the newest BK_RING entries
            set ring [lsort [glob -nocomplain -directory $dir "$stem.*.bak"]]
            foreach old [lrange $ring 0 end-$::els::BK_RING] {
                catch {file delete -force $old}
            }
        }
    } err]} {
        els::status_note "backup failed: $err"
    }
}
proc els::backups_open {} {
    set dir [els::backup_dir]
    if {$dir eq ""} { return }
    catch {file mkdir $dir}
    catch {exec explorer.exe [file nativename $dir] &}
}
proc els::set_backups {{persist 1}} {
    if {$persist} { els::save_geometry }
}

# ---- auto-save (opt-in) ----------------------------------------------------
# File ▸ Auto-save: documents that HAVE a file are saved automatically -- a
# moment after typing pauses, when switching tabs, when the window loses
# focus, and on close/quit.  Untitled documents are never auto-saved (crash
# recovery protects them; els does not invent filenames).  Auto-saves are
# quiet: a write error becomes a statusbar note, and a document whose
# encoding cannot hold its characters pauses auto-saving until one manual
# save settles the question (the lossy guard above).
proc els::set_autosave {{persist 1}} {
    if {$::els::autosave} { els::autosave_all }   ;# turning it on saves NOW
    if {$persist} { els::save_geometry }
}
proc els::autosave_soon {id} {
    if {!$::els::autosave} { return }
    dict set ::els::autosave_pending $id 1
    catch {after cancel $::els::autosave_after}
    set ::els::autosave_after [after 1200 els::autosave_flush_pending]
}
proc els::autosave_flush_pending {} {
    set ::els::autosave_after ""
    set pend $::els::autosave_pending
    set ::els::autosave_pending {}
    foreach id [dict keys $pend] { els::autosave_flush_doc $id }
}
proc els::autosave_flush_doc {id} {
    if {!$::els::autosave} { return }
    if {$id eq "" || $id ni $::els::docs} { return }
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} { return }
    if {[info exists ::els::docLossyPause($id)]} { return }   ;# awaiting a manual save
    if {![els::doc_dirty $id]} { return }
    catch {els::save $id 1}
}
proc els::autosave_all {} {
    foreach id $::els::docs { els::autosave_flush_doc $id }
}

# Save a document (default: the active one).  quiet=1 is the auto-save mode:
# no dialog may ever appear -- an unencodable character pauses auto-saving for
# the document and a write error becomes a statusbar note.
proc els::save {{id ""} {quiet 0}} {
    variable active
    variable docPath
    if {$id eq ""} { set id $active }
    if {$id eq ""} { return 0 }
    if {$docPath($id) eq ""} {
        if {$quiet} { return 0 }      ;# auto-save never invents a filename
        return [els::saveas]
    }
    set w [els::W $id]
    set text [$w get 1.0 "end - 1 char"]
    # re-apply the document's original EOL (buffer is LF-internal)
    switch $::els::docEol($id) {
        crlf { set text [string map [list \n \r\n] $text] }
        cr   { set text [string map [list \n \r]   $text] }
    }
    # encode in the document's encoding -- NEVER silently lossy: characters the
    # encoding cannot hold either switch the doc to UTF-8, are replaced with
    # the user's explicit consent, or cancel the save
    set enc $::els::docEnc($id)
    # only the SIGN of -failindex is trusted (see lossy_first for why)
    set bytes [encoding convertto -profile strict -failindex fi $enc $text]
    if {$fi >= 0} {
        if {[info exists ::els::docLossyOk($id)]} {
            set bytes [encoding convertto -profile replace $enc $text]
        } elseif {$quiet} {
            set ::els::docLossyPause($id) 1
            els::status_note "auto-save paused: characters not in [els::enc_label $enc 0] (save manually once)"
            return 0
        } else {
            lassign [els::lossy_describe $enc $text] line col uhex count
            switch [els::lossy_ask $id $enc $line $col $uhex $count] {
                utf8 {
                    set ::els::docEnc($id) utf-8
                    # replace-profile only for the pathological unpaired-
                    # surrogate case, which NO file encoding can hold
                    set bytes [encoding convertto -profile replace utf-8 $text]
                }
                lossy {
                    set ::els::docLossyOk($id) 1
                    set bytes [encoding convertto -profile replace $enc $text]
                }
                cancel { return 0 }
            }
        }
    }
    unset -nocomplain ::els::docLossyPause($id)
    # restore a BOM if the document carries one
    if {$::els::docBom($id)} {
        switch $::els::docEnc($id) {
            utf-8    { set bytes "\xEF\xBB\xBF$bytes" }
            utf-16le { set bytes "\xFF\xFE$bytes" }
            utf-16be { set bytes "\xFE\xFF$bytes" }
            utf-32le { set bytes "\xFF\xFE\x00\x00$bytes" }
            utf-32be { set bytes "\x00\x00\xFE\xFF$bytes" }
        }
    }
    # an overwriting save first preserves the file's CURRENT content as a
    # backup (best-effort; never blocks the save)
    if {[file exists $docPath($id)]} { els::backup_keep $docPath($id) }
    if {[set err [els::write_atomic $docPath($id) $bytes]] ne ""} {
        if {$quiet} {
            els::status_note "auto-save failed: [file tail $docPath($id)]"
        } else {
            tk_messageBox -parent . -icon error -title els -message "Cannot save file:\n$err"
        }
        return 0
    }
    $w edit modified 0
    # keep the cached raw bytes in sync with what is now on disk, so a later
    # "Reopen with Encoding" re-decodes the SAVED content rather than reverting
    # to the bytes loaded at open time (which silently discarded saved edits, and
    # blanked a Save-As'd new document whose docRaw was still empty)
    set ::els::docRaw($id) $bytes
    els::cache_saved_sig $id
    unset -nocomplain ::els::docRecovered($id)   ;# saved -> no longer a recovered tab
    els::swap_clear $id   ;# the file is safely on disk now -> drop the swap
    els::update_tab $id
    els::settitle
    return 1
}
proc els::saveas {} {
    variable active
    variable docPath
    if {$active eq ""} { return }
    set p [tk_getSaveFile -parent . -filetypes [els::filetypes] \
               -defaultextension .txt \
               -initialfile [els::doc_name $active]]
    if {$p eq ""} { return 0 }
    if {![catch {file normalize $p} np]} { set p $np }
    # refuse to point this tab at a file already open in another tab: otherwise
    # the two buffers diverge and saving one silently clobbers the other
    foreach id $::els::docs {
        if {$id ne $active && [info exists docPath($id)] && \
                [els::same_path $docPath($id) $p]} {
            tk_messageBox -parent . -icon warning -title els \
                -message "That file is already open in another tab.\
                          \nClose it there first, or choose a different name."
            return 0
        }
    }
    set oldPath $docPath($active)
    set docPath($active) $p
    if {![els::save]} {
        set docPath($active) $oldPath
        els::update_tab $active
        els::settitle
        return 0
    }
    els::update_tab $active
    els::recent_add $p
    return 1
}
proc els::session_restore {} {
    if {!$::els::restore_session} { return 0 }
    set ::els::session_owned 1   ;# restoring IS adopting the stored session
    set restored {}
    foreach p [els::session_sanitize $::els::session_files] {
        if {![file exists $p]} { continue }
        set id [els::open $p 1]
        if {$id ne ""} { lappend restored [list $p $id] }
    }
    if {![llength $restored]} { return 0 }
    set target ""
    foreach item $restored {
        lassign $item p id
        if {$p eq $::els::session_active} {
            set target $id
            break
        }
    }
    if {$target ne ""} { els::switch_to $target }
    return [llength $restored]
}
# bind an event on a widget and every descendant, so a click anywhere inside a
# composite window is caught — not just on its background
proc els::bindtree {w seq script} {
    bind $w $seq $script
    foreach c [winfo children $w] { els::bindtree $c $seq $script }
}
proc els::about {} {
    catch {destroy .about}
    toplevel .about -bg $::els::PAGE
    wm withdraw .about        ;# build off-screen, reveal only when fully formed
    wm title .about "About els"
    wm transient .about .
    wm resizable .about 0 0
    set bg $::els::PAGE
    frame .about.card -bg $bg
    pack  .about.card -padx 34 -pady 28
    frame .about.top -bg $bg
    pack  .about.top -in .about.card -anchor center
    set iconSize 0
    if {$::els::iconLoaded} {
        catch {image delete elsAboutIcon}
        image create photo elsAboutIcon
        elsAboutIcon copy elsIcon -subsample 2 -subsample 2   ;# 256px -> 128px
        set iconSize [image height elsAboutIcon]
        label .about.top.icon -image elsAboutIcon -bg $bg -bd 0
        grid .about.top.icon -row 0 -column 0 -sticky ns -padx {0 20}
    }
    label .about.top.name -text "els" -font elsTitle -fg $::els::INK -bg $bg -anchor center
    grid .about.top.name -row 0 -column 1 -sticky ns
    if {$iconSize > 0} { grid rowconfigure .about.top 0 -minsize $iconSize }
    frame .about.body -bg $bg
    pack  .about.body -in .about.card -anchor center -pady {14 0}
    label .about.body.tag -text "a simple text editor" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.tag -anchor center -pady {0 12}
    label .about.body.copy -text "© 2026 Vincent Vercauteren" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.copy -anchor center -pady {0 10}
    label .about.body.ver -text "version $::els::version" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.ver -anchor center -pady {0 2}
    label .about.body.lic -text "MIT License" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.lic -anchor center
    # a click anywhere, or Escape, dismisses it
    bind .about <Escape> {destroy .about}
    els::bindtree .about <Button-1> {destroy .about}
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .about]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .about]) / 3}]
    wm geometry .about +$x+$y
    wm deiconify .about
    focus .about
}
# A terse, two-column keyboard-shortcut reference (Help ▸ Keyboard Shortcuts).
# Keys in mono ink, actions in muted UI — same calm language as the regex card.
proc els::shortcuts {} {
    catch {destroy .keys}
    toplevel .keys -bg $::els::PAGE
    wm withdraw .keys        ;# build off-screen, reveal only when fully formed
    wm title .keys "Keyboard Shortcuts"
    wm transient .keys .
    wm resizable .keys 0 0
    set bg $::els::PAGE
    frame .keys.f -bg $bg
    pack  .keys.f -padx 28 -pady 22
    label .keys.f.title -text "Keyboard Shortcuts" -font elsUIb -fg $::els::INK -bg $bg
    label .keys.f.sub -text "Common actions in els" -font elsUI -fg $::els::MUTED -bg $bg
    grid .keys.f.title -row 0 -column 0 -columnspan 3 -sticky w
    grid .keys.f.sub   -row 1 -column 0 -columnspan 3 -sticky w -pady {2 14}
    set columns {
        {
            File {
                Ctrl+N        {New tab}
                Ctrl+O        {Open}
                Ctrl+S        {Save}
                Ctrl+Shift+S  {Save as}
                Ctrl+W        {Close file}
                Ctrl+Q        {Exit}
            }
            Edit {
                Ctrl+Z  {Undo}
                Ctrl+Y  {Redo}
                Ctrl+X  {Cut}
                Ctrl+C  {Copy}
                Ctrl+V  {Paste}
                Ctrl+A  {Select all}
            }
        }
        {
            Navigation {
                {Home/End}        {Line start / end}
                {Ctrl+Home/End}   {File start / end}
                {Ctrl+←/→}        {Word left / right}
                {Ctrl+↑/↓}        {Paragraph up / down}
                {PageUp/PageDn}   {Page up / down}
            }
            Selection {
                {Shift+arrows}        {Extend selection}
                {Ctrl+Shift+←/→}      {Extend by word}
                {Shift+Home/End}      {Select to line edge}
                {Ctrl+Shift+Home/End} {Select to file edge}
            }
            Tabs {
                Ctrl+Tab        {Next tab}
                Ctrl+Shift+Tab  {Previous tab}
            }
        }
        {
            Search {
                Ctrl+F          {Find}
                Ctrl+H          {Replace}
                Ctrl+G          {Go to line}
                {F3/Shift+F3}   {Next / prev match}
                Enter           {Next match}
                Shift+Enter     {Previous match}
                {↑/↓}           {Search history}
                Esc             {Close find bar}
            }
            View {
                {Ctrl  +}    {Zoom in}
                {Ctrl  −}    {Zoom out}
                {Ctrl  0}    {Reset zoom}
                {Ctrl Wheel} {Zoom}
            }
        }
    }
    set col 0
    foreach sections $columns {
        set cf [frame .keys.f.c$col -bg $bg]
        if {$col < 2} {
            set padx [list 0 18]
        } else {
            set padx [list 0 0]
        }
        grid $cf -row 2 -column $col -sticky n -padx $padx
        set r 0
        foreach {cat rows} $sections {
            set sec [frame $cf.s$r -bg $bg -highlightthickness 1 \
                         -highlightbackground $::els::HAIR]
            grid $sec -row $r -column 0 -sticky new -pady [list 0 10]
            label $sec.h -text $cat -font elsUIb -fg $::els::INK -bg $bg
            grid  $sec.h -row 0 -column 0 -columnspan 2 -sticky w -padx 10 -pady {8 5}
            set sr 1
            foreach {k d} $rows {
                label $sec.k$sr -text $k -font elsMonoHelp -fg $::els::INK   -bg $bg -anchor w
                label $sec.d$sr -text $d -font elsUI       -fg $::els::MUTED -bg $bg -anchor w
                grid  $sec.k$sr -row $sr -column 0 -sticky w -padx {10 18} -pady {1 1}
                grid  $sec.d$sr -row $sr -column 1 -sticky w -padx {0 12}  -pady {1 1}
                incr sr
            }
            grid rowconfigure $sec $sr -minsize 8
            grid columnconfigure $sec 1 -weight 1
            incr r
        }
        grid columnconfigure $cf 0 -weight 1
        incr col
    }
    grid columnconfigure .keys.f {0 1 2} -weight 1
    bind .keys <Escape> {destroy .keys}
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .keys]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .keys]) / 4}]
    wm geometry .keys +$x+$y
    wm deiconify .keys
    focus .keys
}
proc els::quit {} {
    variable docs
    els::autosave_all   ;# auto-save on: pathed docs leave saved; only the rest prompt
    foreach id $docs {
        if {[els::doc_dirty $id]} {
            els::switch_to $id
            set ::els::swap_suspend 1
            set ans [tk_messageBox -parent . -icon warning -type yesnocancel \
                -title els -message "Save changes to [els::doc_name $id]?"]
            set ::els::swap_suspend 0
            if {$ans eq "cancel"} { return }   ;# aborted quit: autosave stays armed
            if {$ans eq "yes"} {
                els::save
                if {[els::doc_dirty $id]} { return }
            }
        }
    }
    els::save_geometry
    els::swap_shutdown   ;# committed exit: stop autosave, delete our swaps + lock
    exit
}

# ---- find / replace -----------------------------------------------------
proc els::build_findbar {} {
    ttk::frame .find -padding {8 6 8 0}

    ttk::frame .find.fr
    ttk::label .find.fr.l -text "Find" -font elsUI -width 7 -anchor w
    ttk::entry .find.fr.q -textvariable ::els::find_q -font elsUI
    ttk::frame .find.fr.ctrl
    ttk::checkbutton .find.fr.case  -text "Aa" -style Find.Toolbutton -takefocus 0 \
        -variable ::els::find_case  -command els::find_update
    ttk::checkbutton .find.fr.word  -text "W"  -style Find.Toolbutton -takefocus 0 \
        -variable ::els::find_word  -command els::find_update
    ttk::checkbutton .find.fr.regex -text ".*" -style Find.Toolbutton -takefocus 0 \
        -variable ::els::find_regex -command els::find_update
    ttk::button .find.fr.help -text "?" -style Find.TButton -width 2 -takefocus 0 \
        -state normal -command els::regex_help
    ttk::button .find.fr.prev -text "↑" -style Find.TButton -width 2 -takefocus 0 -command {els::find_step -1}
    ttk::button .find.fr.next -text "↓" -style Find.TButton -width 2 -takefocus 0 -command {els::find_step 1}
    ttk::label  .find.fr.n -textvariable ::els::find_count -font elsUI \
        -foreground $::els::MUTED -width 16 -anchor e   ;# room for large counts
    ttk::button .find.fr.x -text "×" -style Find.TButton -width 2 -takefocus 0 -command els::find_hide
    grid .find.fr.l    -row 0 -column 0 -padx 1 -sticky we
    grid .find.fr.q    -row 0 -column 1 -padx 1 -sticky we
    grid .find.fr.ctrl -row 0 -column 2 -padx 1 -sticky e
    grid columnconfigure .find.fr 1 -weight 1
    pack .find.fr.x .find.fr.n .find.fr.next .find.fr.prev .find.fr.help \
         .find.fr.regex .find.fr.word .find.fr.case -in .find.fr.ctrl \
         -side right -padx {2 0}
    els::tooltip .find.fr.case  "Match case"
    els::tooltip .find.fr.word  "Whole word"
    els::tooltip .find.fr.regex "Regular expression"
    els::tooltip .find.fr.help  "Regex quickref"
    els::tooltip .find.fr.prev  "Previous  (Shift+Enter)"
    els::tooltip .find.fr.next  "Next  (Enter)"

    ttk::frame .find.rr
    ttk::label .find.rr.l -text "Replace" -font elsUI -width 7 -anchor w
    ttk::entry .find.rr.r -textvariable ::els::find_r -font elsUI
    ttk::frame .find.rr.ctrl
    ttk::checkbutton .find.rr.adapt -text "Adapt case" -style FindAction.Toolbutton -takefocus 0 \
        -variable ::els::find_adapt
    ttk::button .find.rr.rep -text "Replace" -style FindAction.TButton -takefocus 0 -command els::find_replace_one
    ttk::button .find.rr.all -text "All"     -style FindAction.TButton -takefocus 0 -command els::find_replace_all
    grid .find.rr.l    -row 0 -column 0 -padx 1 -sticky we
    grid .find.rr.r    -row 0 -column 1 -padx 1 -sticky we
    grid .find.rr.ctrl -row 0 -column 2 -padx 1 -sticky e
    grid columnconfigure .find.rr 1 -weight 1
    pack .find.rr.all .find.rr.rep .find.rr.adapt -in .find.rr.ctrl \
         -side right -padx {2 0}
    els::tooltip .find.rr.adapt "Adapt case — make each replacement follow the case of the match"

    update idletasks
    set cw [expr {max([winfo reqwidth .find.fr.ctrl], [winfo reqwidth .find.rr.ctrl])}]
    set ch [expr {max([winfo reqheight .find.fr.ctrl], [winfo reqheight .find.rr.ctrl])}]
    foreach c {.find.fr.ctrl .find.rr.ctrl} {
        $c configure -width $cw -height $ch
        pack propagate $c 0
    }

    # find bar now lives at the TOP (below the tabs), so the hairline rule sits
    # at its BOTTOM, separating it from the text below
    grid .find.fr -row 0 -column 0 -sticky ew
    grid .find.rr -row 1 -column 0 -sticky ew -pady {4 0}
    frame .find.sep -height 1 -bg $::els::HAIR
    grid .find.sep -row 2 -column 0 -sticky ew -pady {6 0}
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
    # Ctrl+H is the Replace accelerator; without this, the ttk::entry TEntry class
    # binding (Control-h -> Backspace) fires first and eats a character from the
    # search/replacement text.  A widget-level binding with break pre-empts it.
    bind .find.fr.q <Control-h>    { els::find_show replace ; break }
    bind .find.rr.r <Control-h>    { els::find_show replace ; break }

    els::entry_clear_button .find.fr.q ::els::find_q
    els::entry_clear_button .find.rr.r ::els::find_r
}

# In-entry clear button: a small "×" hugging the entry's right edge, shown
# only while the field has text; clicking empties the field (and re-runs the
# search so stale highlights vanish with the query).
proc els::entry_clear_button {entry var} {
    set x $entry.clearx
    set bg [ttk::style lookup TEntry -fieldbackground {} $::els::PAGE]
    label $x -text "×" -font elsUI -cursor hand2 -bg $bg -fg $::els::MUTED \
        -padx 2 -pady 0 -borderwidth 0
    bind $x <Enter>    [list $x configure -fg $::els::INK]
    bind $x <Leave>    [list $x configure -fg $::els::MUTED]
    bind $x <Button-1> [list els::entry_clear $entry $var]
    # re-installed on every els::build: drop the previous trace first so test
    # rebuilds don't accumulate duplicates
    catch {trace remove variable $var write [list els::entry_clear_sync $entry $var]}
    trace add variable $var write [list els::entry_clear_sync $entry $var]
    els::entry_clear_sync $entry $var
}
proc els::entry_clear_sync {entry var args} {
    set x $entry.clearx
    if {![winfo exists $x]} { return }
    if {[set $var] ne ""} {
        place $x -in $entry -relx 1.0 -x -3 -rely 0.5 -anchor e
        raise $x
    } else {
        place forget $x
    }
}
proc els::entry_clear {entry var} {
    set $var ""
    catch {focus $entry}
    els::find_update
}

# ---- find-bar polish: tooltips, flash, regex help, history --------------
proc els::tooltip {w text} {
    bind $w <Enter>      [list els::tip_schedule $w $text]
    bind $w <Leave>      els::tip_cancel
    # per-button (not generic <ButtonPress>) + APPEND: a widget's own specific
    # <Button-1> binding (e.g. a tab's switch_to) shadows a generic one, so a
    # click never dismissed the tip; appending composes with existing handlers
    bind $w <ButtonPress-1> {+els::tip_cancel}
    bind $w <ButtonPress-2> {+els::tip_cancel}
    bind $w <ButtonPress-3> {+els::tip_cancel}
    # the anchor dying must take its pending timer AND a visible tip with it —
    # otherwise an orphan -topmost .tip floats over the desktop indefinitely
    bind $w <Destroy> {+els::tip_cancel}
}
proc els::tip_schedule {w text} {
    els::tip_cancel
    set ::els::tip_after [after 550 [list els::tip_pop $w $text]]
}
proc els::tip_cancel {} {
    if {[info exists ::els::tip_after]} { after cancel $::els::tip_after ; unset ::els::tip_after }
    catch {destroy .tip}
}
# Wrap long tooltip text so it can't run off the screen.  Tk labels only wrap at
# whitespace, but our long tips are paths (separators, usually no spaces), so we
# insert the breaks: after a separator/space once a line reaches ~target, and a
# hard break if a run grows past target+cap with no natural break point.
proc els::tip_wrap {s {target 72} {cap 24}} {
    if {[string length $s] <= $target} { return $s }
    set out {} ; set line ""
    foreach ch [split $s ""] {
        append line $ch
        set n [string length $line]
        if {($n >= $target && [string first $ch "/\\ -_"] >= 0) || $n >= $target + $cap} {
            lappend out $line ; set line ""
        }
    }
    if {$line ne ""} { lappend out $line }
    return [join $out \n]
}
proc els::tip_pop {w text} {
    catch {destroy .tip}
    if {![winfo exists $w] || $text eq ""} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text [els::tip_wrap $text] -justify left \
        -bg "#2B2B2B" -fg "#F0F0F0" -font elsUI -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set tw [winfo reqwidth .tip] ; set th [winfo reqheight .tip]
    set x [expr {[winfo rootx $w] + [winfo width $w] / 2 - $tw / 2}]
    set below [expr {[winfo rooty $w] + [winfo height $w] + 5}]
    # Prefer below the widget; flip above when needed, then clamp into the widget's
    # own toplevel (the main window, or a dialog like the recent-files manager).
    # Tooltips are context for that window, not little screen-global balloons.
    set top [winfo toplevel $w]
    set margin 4
    set winl [winfo rootx $top]
    set wint [winfo rooty $top]
    set winr [expr {$winl + [winfo width $top]}]
    set winb [expr {$wint + [winfo height $top]}]
    set above [expr {[winfo rooty $w] - $th - 5}]
    if {$below + $th <= $winb - $margin} {
        set y $below
    } elseif {$above >= $wint + $margin} {
        set y $above
    } else {
        set y [expr {min(max($below, $wint + $margin), $winb - $th - $margin)}]
    }
    if {$x < $winl + $margin} {
        set x [expr {$winl + $margin}]
    } elseif {$x + $tw > $winr - $margin} {
        set x [expr {max($winl + $margin, $winr - $margin - $tw)}]
    }
    wm geometry .tip +$x+$y
}
# A tooltip anchored at explicit screen coordinates (e.g. near the cursor), used
# for per-row tips in a list where one widget holds many hover targets.  Clamped
# to the screen rather than a window.
proc els::tip_pop_at {text rx ry} {
    catch {destroy .tip}
    if {$text eq ""} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text [els::tip_wrap $text] -justify left \
        -bg "#2B2B2B" -fg "#F0F0F0" -font elsUI -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set tw [winfo reqwidth .tip] ; set th [winfo reqheight .tip]
    # clamp against the VIRTUAL desktop (wm maxsize tracks it), not winfo
    # screenwidth/-height, which report only the PRIMARY monitor on Windows —
    # the old clamp teleported the tip from a secondary monitor to the primary's
    # edge.  No max(...,0) snap either: monitors left/above the primary have
    # legitimately negative root coordinates.
    lassign [wm maxsize .tip] sw sh
    if {$rx + $tw > $sw - 4} { set rx [expr {$sw - $tw - 4}] }
    if {$ry + $th > $sh - 4} { set ry [expr {$ry - $th - 22}] }
    wm geometry .tip +$rx+$ry
}
# A dynamic tooltip: `textcmd` is evaluated each time the tip is about to show,
# so it tracks live state; an empty result suppresses the tip (e.g. a status
# name that currently fits and isn't elided, or an untitled tab).
proc els::tooltip_for {w textcmd {delay 550}} {
    bind $w <Enter>       [list els::tip_schedule_cmd $w $textcmd $delay]
    bind $w <Leave>       els::tip_cancel
    # see els::tooltip: per-button appends (shadowing) + a Destroy hook (orphans)
    bind $w <ButtonPress-1> {+els::tip_cancel}
    bind $w <ButtonPress-2> {+els::tip_cancel}
    bind $w <ButtonPress-3> {+els::tip_cancel}
    bind $w <Destroy> {+els::tip_cancel}
}
proc els::tip_schedule_cmd {w textcmd {delay 550}} {
    els::tip_cancel
    set ::els::tip_after [after $delay [list els::tip_pop_cmd $w $textcmd]]
}
proc els::tip_pop_cmd {w textcmd} {
    if {![winfo exists $w]} { return }
    els::tip_pop $w [uplevel #0 $textcmd]
}

# a compact, scannable regex quick reference, opened from the Find/Replace "?"
proc els::regex_help {} {
    catch {destroy .rehelp}
    toplevel .rehelp
    wm title .rehelp "Regular Expressions Quickref"
    wm transient .rehelp .
    wm resizable .rehelp 0 0
    catch {wm attributes .rehelp -topmost 1}
    ttk::frame .rehelp.f -padding 14
    pack .rehelp.f -fill both -expand 1
    ttk::label .rehelp.f.h -text "Regular Expressions Quickref" \
        -font elsUI -foreground $::els::MUTED
    grid .rehelp.f.h -row 0 -column 0 -columnspan 2 -sticky w -pady {0 4}
    ttk::label .rehelp.f.note -text \
        "These patterns are used when Regex is on. With Regex off, els searches for the text literally." \
        -font elsUI -foreground $::els::MUTED -wraplength 380 -justify left
    grid .rehelp.f.note -row 1 -column 0 -columnspan 2 -sticky w -pady {0 8}
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
    set r 2
    foreach {tok desc} $rows {
        ttk::label .rehelp.f.t$r -text $tok  -font elsMonoHelp -foreground $::els::INK
        ttk::label .rehelp.f.d$r -text $desc -font elsUI   -foreground $::els::MUTED
        grid .rehelp.f.t$r -row $r -column 0 -sticky w -padx {0 22} -pady 1
        grid .rehelp.f.d$r -row $r -column 1 -sticky w -pady 1
        incr r
    }
    bind .rehelp <Escape> {destroy .rehelp}
    focus .rehelp
    update idletasks
    set rw [winfo reqwidth .rehelp]
    set rh [winfo reqheight .rehelp]
    wm minsize .rehelp $rw $rh
    wm maxsize .rehelp $rw $rh
    wm resizable .rehelp 0 0
    set x [expr {[winfo rootx .] + ([winfo width .]  - $rw) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - $rh) / 3}]
    wm geometry .rehelp ${rw}x${rh}+$x+$y
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
    grid .find -row 1 -column 0 -columnspan 3 -sticky ew
    if {$mode eq "replace"} { grid .find.rr } else { grid remove .find.rr }
    catch {.find.fr.help configure -state normal}
    catch {.find.fr.help state !disabled}
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
    variable find_mode ; variable find_matches ; variable find_current
    variable find_after
    set find_mode ""
    # a pending debounced search would otherwise fire ~130 ms after dismissal,
    # re-tagging the buffer and teleporting the caret to a match
    after cancel $find_after
    set find_after ""
    # drop the cached spans: they are plain string indices that do not float
    # with edits, and F3 on a hidden bar must never jump to (or replace) stale
    # coordinates — possibly in a different document
    set find_matches {}
    set find_current -1
    grid remove .find
    set w [els::T]
    if {$w ne ""} {
        $w tag remove findAll 1.0 end
        $w tag remove findOne 1.0 end
        focus $w
    }
}

# The search pattern + `search` args for the current query/options; "" when the
# query is empty.  (NOT an expr ternary anywhere: expr canonicalizes operands
# that look like numbers, so a query of "007" would silently become "7".)
proc els::find_spec {} {
    variable find_q ; variable find_case ; variable find_word ; variable find_regex
    if {$find_q eq ""} { return "" }
    set useRegex $find_regex
    set pat $find_q
    if {$find_word} {
        set useRegex 1
        if {$find_regex} { set p $find_q } else { set p [els::re_escape $find_q] }
        # group the pattern so the word boundaries bind the WHOLE pattern, not
        # just the first/last alternative of an alternation like foo|bar
        set pat "\\m(?:$p)\\M"
    }
    set sargs {-all}
    if {$useRegex}   { lappend sargs -regexp }
    if {!$find_case} { lappend sargs -nocase }
    return [list $pat $sargs]
}
# Search the buffer FRESH and return the valid {start end} pairs ("bad" for a
# malformed pattern).  Centralised so find_update and Replace All can never
# disagree — Replace All must NEVER walk `tag ranges findAll` instead: Tk merges
# abutting ranges of one tag, so N adjacent matches would collapse into ONE
# replacement, silently deleting text.
proc els::find_scan {w} {
    set spec [els::find_spec]
    if {$spec eq ""} { return {} }
    lassign $spec pat sargs
    if {[catch {set starts [$w search {*}$sargs -count ::els::find_lens -- $pat 1.0 end]}]} {
        return bad
    }
    set ::els::find_scan_doc $::els::active
    set ::els::find_scan_chars [$w count -chars 1.0 end]
    set out {}
    set last [$w index "end - 1 char"]
    set i 0
    foreach s $starts {
        set L [lindex $::els::find_lens $i]
        incr i
        # skip zero-width matches (x*, ^, \d* on non-digits, …): they are
        # invisible, navigate to nothing, and Replace All would turn each into an
        # insert between every character, corrupting the buffer
        if {$L <= 0} { continue }
        set e [$w index "$s + $L chars"]
        # the widget's mandatory final newline is searchable but is NOT part of
        # the document: drop any match that extends past the last real character
        # (else \s "matches" in a whitespace-free file and Replace All edits —
        # and saves — text that was never in the document)
        if {[$w compare $e > $last]} { continue }
        lappend out [list $s $e]
    }
    return $out
}
# Does the text at s..e still satisfy the current query?  A cheap staleness
# probe for cached match spans: plain string indices do not float with edits.
proc els::find_span_ok {w s e} {
    variable find_q ; variable find_case ; variable find_word ; variable find_regex
    if {[catch {$w get $s $e} txt]} { return 0 }
    if {!$find_regex && !$find_word} {
        if {$find_case} { return [string equal $txt $find_q] }
        return [string equal -nocase $txt $find_q]
    }
    set spec [els::find_spec]
    if {$spec eq ""} { return 0 }
    lassign $spec pat sargs
    set fl {}
    if {"-nocase" in $sargs} { lappend fl -nocase }
    if {[catch {regexp {*}$fl -- "\\A(?:$pat)\\Z" $txt} ok]} { return 0 }
    return $ok
}

# re-run the search in the active doc, tag all matches, pick the current one
proc els::find_update {} {
    variable find_matches ; variable find_count ; variable find_mode
    # the bar is hidden: a late debounce / stray caller must not re-tag matches
    # or move the caret on a search the user already dismissed
    if {$find_mode eq ""} { return }
    set w [els::T]
    if {$w eq ""} { return }
    catch {.find.fr.help configure -state normal}
    catch {.find.fr.help state !disabled}
    $w tag remove findAll 1.0 end
    $w tag remove findOne 1.0 end
    set find_matches {}
    if {$::els::find_q eq ""} { set find_count "" ; return }
    set scan [els::find_scan $w]
    if {$scan eq "bad"} { set find_count "bad pattern" ; return }
    if {![llength $scan]} { set find_count "No results" ; return }
    set find_matches $scan
    foreach m $scan { $w tag add findAll {*}$m }
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
    els::draw_gutter   ;# the caret moved — refresh the gutter band + visible nums
}

proc els::find_step {dir} {
    variable find_matches ; variable find_current ; variable find_mode
    if {$find_mode eq ""} { return }   ;# bar hidden (F3): nothing to step
    set w [els::T]
    if {$w eq ""} { return }
    # Cached spans are plain string indices — they do NOT float with edits.
    # Re-scan instead of stepping when they could be stale: different doc, the
    # buffer length changed since the scan, or the target span no longer matches
    # the query (a same-length edit).  find_update lands on the match nearest
    # the caret, which is the natural continuation.
    if {![llength $find_matches] \
            || $::els::active ne $::els::find_scan_doc \
            || [$w count -chars 1.0 end] != $::els::find_scan_chars} {
        els::find_update
        return
    }
    set n [llength $find_matches]
    set idx [expr {(($find_current + $dir) % $n + $n) % $n}]
    lassign [lindex $find_matches $idx] s e
    if {![els::find_span_ok $w $s $e]} { els::find_update ; return }
    # stepping past either end wraps — say so, instead of silently teleporting
    # across the end-of-file border
    set wrapped [expr {($dir > 0 && $idx <= $find_current) || \
                       ($dir < 0 && $idx >= $find_current)}]
    els::find_highlight $idx
    if {$wrapped && $n > 1} { append ::els::find_count "  (wrapped)" }
}

# Make a match's case template carry to its replacement (when Adapt case is on).
proc els::adapt_case {match repl} {
    # [[:alpha:]] not [A-Za-z]: toupper/tolower/totitle below are Unicode-aware,
    # so an all-Cyrillic/Greek match must not be skipped by an ASCII-only guard
    if {!$::els::find_adapt || $match eq "" || ![regexp {[[:alpha:]]} $match]} { return $repl }
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
        if {$find_word} { set pat "\\m(?:$find_q)\\M" } else { set pat $find_q }
        set fl {} ; if {!$find_case} { lappend fl -nocase }
        # Re-match WITH trailing context, anchored at the match start: a
        # context-dependent construct (lookahead (?=...), \M at a word edge)
        # cannot re-match against the excised match text alone, so the
        # "replacement" would silently write the original text back.  2000 chars
        # of context bounds the cost on huge buffers; a lookahead needing more
        # degrades to leaving the match untouched.
        set ctx [$w get $s "$e + 2000 chars"]
        set out ""
        if {[catch {regsub {*}$fl -- "\\A(?:$pat)" $ctx $find_r out} nsub] || $nsub == 0} {
            set repl $matched          ;# could not re-match: leave the text as-is
        } else {
            set tail [expr {[string length $ctx] - [string length $matched]}]
            set repl [string range $out 0 end-$tail]
        }
    }
    return [els::adapt_case $matched $repl]
}

proc els::find_replace_one {} {
    set w [els::T]
    if {$w eq ""} { return }
    # Use the findOne TAG range, which floats with edits, not the cached
    # find_matches index, which does not: a direct buffer edit (the find bar can
    # stay open while you type in the document) leaves the cached index pointing
    # at the wrong span, so Replace would overwrite unrelated text.
    set range [$w tag ranges findOne]
    if {[llength $range] != 2} { els::find_step 1 ; return }
    lassign $range s e
    set repl [els::repl_for $w $s $e]
    $w edit separator
    $w replace $s $e $repl
    $w mark set insert "$s + [string length $repl] chars"
    els::swap_touch   ;# a button-driven edit doesn't fire <KeyRelease> -> latch it
    els::find_update
}

proc els::find_replace_all {} {
    set w [els::T]
    if {$w eq ""} { return }
    # Search FRESH at replace time and walk the result in reverse (earlier
    # indices stay valid while later text is replaced; no edits happen between
    # the scan and the walk).  NEVER via `tag ranges findAll`: Tk merges
    # abutting ranges of one tag, so N adjacent matches ("aa" find a) would
    # collapse into ONE range and a single replacement would eat the rest.
    set scan [els::find_scan $w]
    if {$scan eq "bad" || ![llength $scan]} { return }
    $w edit separator
    set n 0
    foreach m [lreverse $scan] {
        lassign $m s e
        $w replace $s $e [els::repl_for $w $s $e]
        incr n
    }
    $w edit separator
    els::swap_touch   ;# button-driven edit -> latch dirtySince + schedule a flush
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
    # digits only at the KEYBOARD: rejecting non-numeric input beats silently
    # ignoring it at Go time
    ttk::entry $top.f.e -width 10 -font elsMono \
        -validate key -validatecommand {string is digit %P}
    ttk::frame $top.f.b
    ttk::button $top.f.b.ok     -text "Go"     -style Dialog.TButton -command [list els::goto_do $top]
    ttk::button $top.f.b.cancel -text "Cancel" -style Dialog.TButton -command [list destroy $top]
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
    # plain decimal only — reject hex (0x1F) and signed (+5), which Tcl's
    # `string is integer` would otherwise accept; scan past leading zeros safely
    if {$w ne "" && [regexp {^[0-9]+$} $ln] && [scan $ln %d ln] == 1 && $ln >= 1} {
        set ln [expr {min($ln, [els::line_count])}]
        $w mark set insert $ln.0
        $w see $ln.0
        els::refresh_view
    }
    destroy $top
    if {$w ne ""} { focus $w }
}

# Reveal whitespace when Show Whitespace is on, by tagging it with subdued
# background tints — spaces, tabs and trailing whitespace each a step of blue
# (Tk can't substitute glyphs).  Scoped to the visible viewport so it stays fast
# on large files; re-runs on scroll (els::yscroll) and edits (els::refresh_view).
# Pure tagging (no content change), so it's safe anywhere.
proc els::ws_refresh {} {
    set w [els::T]
    if {$w eq ""} { return }
    $w tag remove wsSpace 1.0 end
    $w tag remove wsTab   1.0 end
    $w tag remove wsTrail 1.0 end
    if {!$::els::show_ws} { return }
    # linestart: with wrap off and the view scrolled right, @0,0 is a MID-LINE
    # index, and tagging from there left the top row's left-of-viewport
    # whitespace untinted after panning back to column 0
    set top [$w index "@0,0 linestart"]
    set bot [$w index "@0,[winfo height $w] + 1 line"]
    # spaces -> grey; tabs -> blue; any trailing space OR a run of 2+ spaces ->
    # mauve (flags trailing and accidental double-spaces, overriding the grey).
    # Ordinary single inter-word spaces stay subtle grey.
    foreach {tag pat var} {wsSpace { +} wl1  wsTab {\t+} wl2  wsTrail { +$} wl3  wsTrail {  +} wl4} {
        set i 0
        foreach s [$w search -all -regexp -count ::els::$var -- $pat $top $bot] {
            $w tag add $tag $s "$s + [lindex [set ::els::$var] $i] chars" ; incr i
        }
    }
}

proc els::set_show_ws {{persist 1}} {
    els::ws_refresh
    if {$persist} { els::save_geometry }
}
# View ▸ Line Numbers: hide/show the gutter (grid remove keeps its options, so
# a plain `grid .ln` restores it exactly); persisted with the config.
proc els::set_linenos {{persist 1}} {
    if {![winfo exists .ln]} { return }
    if {$::els::show_linenos} {
        grid .ln
        els::gutter_schedule
    } else {
        grid remove .ln
    }
    if {$persist} { els::save_geometry }
}
# Always on Top: keep the els window above other windows.  Tk maps this to the
# Win32 WS_EX_TOPMOST style (SetWindowPos HWND_TOPMOST), so it is reliable for
# normal windows; the only thing it cannot sit above is another app's exclusive-
# fullscreen surface, which is inherent to how Windows topmost works.
proc els::set_always_on_top {{persist 1}} {
    catch {wm attributes . -topmost [expr {$::els::always_on_top ? 1 : 0}]}
    if {$persist} { els::save_geometry }
}

# Word wrap: soft-wrap long lines in every document.  The line-number gutter
# (a Canvas, see els::draw_gutter) redraws from the text's dlineinfo, so wrapped
# lines stay aligned automatically — refresh_view repaints it after the toggle.
proc els::set_wrap {{persist 1}} {
    variable docs
    set mode [expr {$::els::word_wrap ? "word" : "none"}]
    foreach id $docs {
        if {[winfo exists [els::W $id]]} { [els::W $id] configure -wrap $mode }
    }
    els::refresh_view
    # the reflow settles after this returns; re-check the horizontal bar at idle
    # so it appears/disappears with the new wrap state
    after idle els::update_hscroll
    if {$persist} { els::save_geometry }
}

# Text size (the font FAMILY is fixed; users can only zoom).  elsMono is a named
# font shared by every document and the gutter, so resizing it scales them all;
# we then recompute the leading and rebuild the gutter so numbers stay aligned.
proc els::set_font_size {size {persist 1}} {
    set size [expr {max(6, min(48, $size))}]
    set ::els::font_size $size
    font configure elsMono -size $size
    set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]
    foreach id $::els::docs {
        set w [els::W $id]
        if {[winfo exists $w]} { $w configure -spacing1 $::els::LEAD -spacing3 $::els::LEAD }
    }
    set ::els::gutter_px -1   ;# font size changed: force a width recompute
    els::refresh_view
    if {$persist} { els::save_geometry }   ;# remember the zoom level across runs
}
proc els::zoom {d}      { els::set_font_size [expr {$::els::font_size + $d}] }
proc els::zoom_reset {} { els::set_font_size 11 }

# ---- update check -------------------------------------------------------
# Best-effort, fire-and-forget check of the GitHub Releases API — a public,
# unauthenticated GET (one request at startup, far within the 60/hr limit, so
# it stays within GitHub's terms).  This runtime has no TLS, so we lean on
# Windows' bundled curl.exe; stdout is piped back and stderr is sent to NUL so
# no console window flashes.  Any failure (offline, no curl, odd JSON) is
# swallowed silently — the editor never blocks or complains.
proc els::check_update {} {
    if {$::els::selftest} return
    set url "https://api.github.com/repos/anafalanx/els/releases/latest"
    if {[catch {
        set ch [::open [list | curl.exe -s -m 6 \
            -H "User-Agent: els-editor" \
            -H "Accept: application/vnd.github+json" $url 2> NUL] r]
    }]} { return }
    set ::els::update_buf ""
    fconfigure $ch -blocking 0 -translation binary
    fileevent $ch readable [list els::update_read $ch]
}
proc els::update_read {ch} {
    if {[catch {read $ch} chunk]} { catch {close $ch} ; return }
    append ::els::update_buf $chunk
    if {[eof $ch]} {
        fileevent $ch readable {}
        catch {close $ch}
        els::update_parse $::els::update_buf
    }
}
proc els::update_parse {data} {
    if {![regexp {"tag_name"\s*:\s*"([^"]+)"} $data -> tag]} { return }
    set latest [string trimleft $tag vV]
    if {[els::version_gt $latest $::els::version]} { els::show_update $latest }
}
# a > b for dotted versions, via Tcl's own package comparator (junk -> false)
proc els::version_gt {a b} {
    return [expr {![catch {package vcompare $a $b} c] && $c > 0}]
}
proc els::show_update {ver} {
    if {![winfo exists .sb.update]} return
    .sb.update configure -text $ver
    els::tooltip .sb.update "els $ver is available — click to download"
}
proc els::open_url {url} {
    if {[catch {exec rundll32.exe url.dll,FileProtocolHandler $url &}]} {
        catch {exec cmd.exe /c start "" $url &}
    }
}

proc els::startup_probe {report} {
    update idletasks
    set paths {}
    set chars {}
    set dirty {}
    foreach id $::els::docs {
        if {[info exists ::els::docPath($id)]} { lappend paths $::els::docPath($id) }
        catch {lappend chars [[els::W $id] count -chars 1.0 "end - 1 char"]}
        lappend dirty [els::doc_dirty $id]
    }
    set data [dict create \
        mapped [winfo ismapped .] \
        cfgask [winfo exists .cfgask] \
        cfgask_mapped [expr {[winfo exists .cfgask] ? [winfo ismapped .cfgask] : 0}] \
        config $::els::config_path \
        docs [llength $::els::docs] \
        paths $paths \
        doc_chars $chars \
        doc_dirty $dirty \
        recovered $::els::last_recover \
        swap_dir [els::swap_dir] \
        active_path [els::session_current_active] \
        title [wm title .] \
        argv $::argv \
        argv0 $::argv0]
    if {$report ne ""} {
        catch {file mkdir [file dirname $report]}
        # write atomically (temp + rename) so a reader polling for the report can
        # never observe a half-written file (TOCTOU)
        if {![catch {set fh [::open $report.tmp w]}]} {
            puts $fh $data
            close $fh
            catch {file rename -force $report.tmp $report}
        }
    }
    catch {els::swap_shutdown}   ;# probe holds a lock + may have written swaps -> clean up
    exit
}

# ---- main ---------------------------------------------------------------
proc els::main {} {
    set a0 [lindex $::argv 0]
    if {$a0 eq "--selftest"} {
        els::build
        els::selftest [lindex $::argv 1] [lindex $::argv 2]
    } else {
        set envProbe [expr {[info exists ::env(ELS_STARTUP_PROBE)] && $::env(ELS_STARTUP_PROBE) ne ""}]
        set startupProbe [expr {$envProbe || $a0 eq "--startup-probe"}]
        # plain if/else, no expr ternaries: paths/args routed through expr get
        # numerically canonicalized (`els.exe 007` would open the file "7")
        if {$envProbe} {
            set startupReport $::env(ELS_STARTUP_PROBE)
        } elseif {$startupProbe} {
            set startupReport [lindex $::argv 1]
        } else {
            set startupReport ""
        }
        if {!$envProbe && $startupProbe} {
            set fileArgs [lrange $::argv 2 end]
        } else {
            set fileArgs $::argv
        }
        # SINGLE-INSTANCE: if an els already owns this config dir, hand our file
        # args to it (it opens them + raises) and exit BEFORE building any UI or
        # acquiring our own lock.  Skipped for probes and ELS_NO_SINGLE_INSTANCE.
        if {!$startupProbe && [els::primary_running]} {
            lassign [els::config_candidates] near appdata
            if {[file exists $near]} { set cfg $near } else { set cfg $appdata }
            els::handoff_send $cfg $fileArgs
            exit 0
        }
        els::build
        if {$startupProbe} {
            # Headless probe: keep the window off the user's screen (alpha 0 still
            # counts as mapped, so the probe's assertions hold) and route any
            # startup error to stderr + exit instead of a modal dialog — the test
            # then fails on a missing report rather than hanging behind a dialog.
            catch {wm attributes . -alpha 0.0}
            # child toplevels too: the first-run Welcome dialog (and a recovery
            # offer) inherit no alpha and used to flash as a REAL opaque window
            # on the desktop during every suite run
            set ::els::probe_quiet 1
            proc ::bgerror {msg args} { catch {puts stderr "els startup-probe: $msg"} ; exit 3 }
            catch {interp bgerror {} ::bgerror}
        }
        # open every file argument, each in its own tab (the first reuses the
        # initial empty document).  Explicit launch files take precedence over
        # the saved session, which is only for a plain app start.
        set openedArgs 0
        foreach f $fileArgs {
            if {[string index $f 0] ne "-"} {
                els::open $f
                set openedArgs 1
            }
        }
        # first run (no config in either location): ask where to keep settings,
        # a moment after the main window is up (never a startup-time modal vwait)
        if {$::els::config_path eq ""} {
            after 250 els::config_first_run   ;# recovery runs once the user picks a config dir
        } else {
            after 80 [list els::recover_boot $openedArgs]   ;# session restore + crash recovery
        }
        if {$startupProbe} {
            # ELS_PROBE_LINGER keeps the probe alive longer before reporting, so
            # a SECOND process can hand a file off to it (single-instance test).
            set linger 0
            if {[info exists ::env(ELS_PROBE_LINGER)]} { catch {set linger [expr {int($::env(ELS_PROBE_LINGER))}]} }
            after [expr {900 + $linger}] [list els::startup_probe $startupReport]
            return
        }
        after 1500 els::check_update
    }
}

# headless smoke test: open a file, exercise a second tab, write a report file
proc els::selftest_report_path {{requested ""}} {
    if {$requested ne ""} { return $requested }
    set dirs {}
    set exe [info nameofexecutable]
    if {$exe ne ""} { lappend dirs [file dirname $exe] }
    if {![string match {//zipfs:*} [info script]]} {
        lappend dirs [file dirname [info script]]
    }
    if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { lappend dirs $::env(TEMP) }
    foreach d $dirs {
        if {$d ne ""} { return [file join $d els-selftest.txt] }
    }
    return els-selftest.txt
}
proc els::selftest {tf {report ""}} {
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
    set report [els::selftest_report_path $report]
    set dstate ""
    foreach id $::els::docs { append dstate "$id:[els::doc_dirty $id] " }
    set lines [list \
        "ok version=$::els::version tk=[info patchlevel]" \
        "mapped=[winfo ismapped .] title=[wm title .]" \
        "caret=[$w cget -insertbackground] page=[$w cget -bg] font=[$w cget -font]" \
        "icon=$::els::iconLoaded path=$::els::iconPath" \
        "gutter_width=[.ln cget -width] lines=[els::line_count]" \
        "current_line_tag=[$w tag ranges currentLine]" \
        "config=[els::config_file] geometry=[wm geometry .]" \
        "theme=[ttk::style theme use] scaling=[format %.3f [tk scaling]]" \
        "docs=$ndocs active=$::els::active tabs_ok=$tabs_ok" \
        "detect=$::els::have_detect" \
        "association_exe=[els::association_exe]" \
        "doc_dirty=[string trimright $dstate]" \
        "open=$openok"]
    set txt [join $lines \n]\n
    # Guard the write: a read-only or non-writable report directory must not leave
    # this headless selftest hung behind a background-error dialog.  On failure,
    # fall back to stderr (still visible to whoever launched --selftest).
    catch {file mkdir [file dirname $report]}
    if {[catch {set out [::open $report w] ; puts -nonewline $out $txt ; close $out} err]} {
        catch {puts stderr "selftest: could not write $report: $err"}
        catch {puts -nonewline stderr $txt}
    }
    after 150 {exit}
}

# load the optional ICU charset detector (chardet-quality auto-detection); a
# missing DLL just leaves have_detect 0 and els falls back to BOM/UTF-8/cp1252
catch { set ::els::have_detect [els::load_detect] }

# run the UI only when executed as the main script, not when sourced by tests
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    els::main
}
