# tests/helpers.tcl — shared scaffolding for the els test suite.
#
# Loads tcltest and the els library (els.tcl's main is guarded by an
# `info script eq argv0` check, so sourcing it here does NOT launch the UI).
# Tests drive the real Tk widgets in-process — white-box, deterministic, and
# headless — via direct proc calls and Tk's `event generate`.

if {[info exists ::els_helpers_loaded]} { return }
set ::els_helpers_loaded 1

package require Tk
package require tcltest

# Keep the test UI invisible without unmapping it. Keyboard `event generate`
# needs a mapped, focusable window, so we can't withdraw the root; instead make
# it fully transparent — present and focusable for the tests, unseen by the user.
catch {wm attributes . -alpha 0.0}
wm geometry . 900x620+100+100

set ::ELS_SCRIPT [info script]
if {[file pathtype $::ELS_SCRIPT] ne "absolute"} { set ::ELS_SCRIPT [file join [pwd] $::ELS_SCRIPT] }
set ::ELS_ROOT [file dirname [file dirname $::ELS_SCRIPT]]
set ::ELS_TMP  [file join $::ELS_ROOT tests _tmp]
file mkdir $::ELS_TMP

# Keep tests hermetic: never read or write the user's real config locations.
set ::env(APPDATA)      [file join $::ELS_TMP appdata]
set ::env(LOCALAPPDATA) [file join $::ELS_TMP localappdata]
catch {file delete -force $::env(APPDATA)}

# Load the els library (UI is not launched on source).
source [file join $::ELS_ROOT els.tcl]

# Pin the config path into the temp dir, so build's resolver is skipped and the
# first-run location dialog can never pop during a test run.
set ::els::config_path [file join $::ELS_TMP els.conf]
catch {file delete -force $::els::config_path}

# ---- total control of error reporting: no dialog ever reaches the screen ----
#
# THE fix for GUI error boxes "raining" on the desktop.  Loading Tk installs a
# background-error handler (tk::dialog::error::bgerror) that POPS A MODAL DIALOG
# for any uncaught error in an event handler, after-callback, or binding.  In an
# automated run that dialog steals focus, can't be read, and stalls the process.
# Replace the handler (every spelling of it) so such errors go to stderr + a log
# we can read, and capture them in a list tests can assert on.  Nothing appears
# on screen, ever.
#
# Companion rule (enforced by tools/x.tcl `probe`): run tests and probes with
# tclsh90 — a CONSOLE app whose startup errors print to stderr — NEVER wish90, a
# GUI-subsystem app with no console that can only REPORT a startup error as a
# modal dialog, before any handler could be installed.
set ::ELS_TEST_ERRLOG [file join $::ELS_TMP bgerror.log]
set ::els_test_bgerrors {}
proc ::els_test_bgerror {msg {opts {}}} {
    lappend ::els_test_bgerrors $msg
    catch {
        set fh [open $::ELS_TEST_ERRLOG a]
        puts $fh "---- bgerror ----\n$msg\n$::errorInfo"
        close $fh
    }
    catch {puts stderr "BGERROR: $msg"}
}
catch {interp bgerror {} ::els_test_bgerror}      ;# the mechanism Tk actually uses
proc ::bgerror {msg} { ::els_test_bgerror $msg }  ;# classic name, belt and braces
catch {proc ::tk::dialog::error::bgerror {msg args} { ::els_test_bgerror $msg }}

# Replace native dialogs with stubs so a stray dialog never blocks a test run.
proc ::tk_getOpenFile {args} { set ::els_test_open_args $args ; return $::els_test_openfile }
proc ::tk_getSaveFile {args} { set ::els_test_save_args $args ; return $::els_test_savefile }
proc ::tk_messageBox  {args} { return $::els_test_mbanswer }
set ::els_test_openfile ""
set ::els_test_savefile ""
set ::els_test_open_args {}
set ::els_test_save_args {}
set ::els_test_mbanswer "yes"

# Stub the OS-level menu post.  A real `tk_popup` in an unfocused/automated
# context blocks (waiting on a grab) and would flash a grabbing menu on the
# user's screen.  The real <Button-1> bindings still fire and build/configure
# the real menus; tests select entries via the canonical `<menu> invoke`.
proc ::tk_popup {args} { set ::els_test_popup_args $args }
set ::els_test_popup_args {}

# Neutralize input grabs in tests: the go-to-line modal grabs, which could trap
# the user's input during an automated run. (Tests never assert on grab state.)
proc ::grab {args} {}

# Stub the remaining native modal entry points for completeness, so no code path
# can surface one. (els does not use these today, but a future feature might.)
proc ::tk_dialog         {args} { return 0 }
proc ::tk_chooseColor    {args} { return "" }
proc ::tk_chooseDirectory {args} { return "" }

# Build a clean els UI for a test, resetting all document state.
proc els_reset {} {
    catch {. configure -menu {}}
    foreach w [winfo children .] { destroy $w }
    set ::els::docs {}
    set ::els::active ""
    set ::els::seq 0
    foreach a {docPath docEnc docBom docEol docRaw} {
        array unset ::els::$a
        array set ::els::$a {}
    }
    set ::els::show_ws 0 ; set ::els::word_wrap 0
    set ::els::restore_session 1
    set ::els::session_files {}
    set ::els::session_active ""
    # Per-test hygiene: restore the dialog stubs to their defaults and clear the
    # captured background errors, so one test's answer can't leak into the next.
    set ::els_test_openfile "" ; set ::els_test_savefile ""
    set ::els_test_mbanswer "yes" ; set ::els_test_popup_args {}
    set ::els_test_bgerrors {}
    catch {file delete -force $::els::config_path}
    catch {font configure elsMono -size 11}
    set ::els::font_size 11
    catch {set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]}
    els::build
    update
    # Commit Tk's internal focus on the document so synthetic `event generate
    # <KeyPress>` (which routes to the focus widget) is delivered, even when the
    # transparent test root is not the OS-active window.  ONE forced focus plus a
    # single event-loop turn is sufficient and deterministic.  We must NOT poll
    # `[focus]` here: it reports the OS focus, which the headless root never
    # holds, so a poll-until-equal loop would spin to its cap on every reset and
    # make the whole suite ~20x slower for no benefit.
    catch {focus -force [els::T]}
    update
}

# Active (or named) document's text, minus the widget's mandatory final newline.
proc els_text {{id ""}} {
    set w [expr {$id eq "" ? [els::T] : [els::W $id]}]
    return [$w get 1.0 "end - 1 char"]
}

# Canvas-gutter introspection for tests.  gutter_numbers returns a dict mapping
# each drawn line number -> its anchor y on the canvas; gutter_bands counts the
# current-line band rectangles.
proc gutter_numbers {} {
    set out {}
    foreach id [.ln find all] {
        if {[.ln type $id] eq "text"} {
            dict set out [.ln itemcget $id -text] [lindex [.ln coords $id] 1]
        }
    }
    return $out
}
proc gutter_bands {} {
    set n 0
    foreach id [.ln find all] { if {[.ln type $id] eq "rectangle"} { incr n } }
    return $n
}

# Write a temp file with content; return its path.
proc els_tmpfile {name content {enc utf-8}} {
    set p [file join $::ELS_TMP $name]
    set fh [::open $p w]
    fconfigure $fh -encoding $enc -translation lf
    puts -nonewline $fh $content
    close $fh
    return $p
}
