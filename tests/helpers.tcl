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

set ::ELS_ROOT [file normalize [file join [file dirname [info script]] ..]]
set ::ELS_TMP  [file join $::ELS_ROOT tests _tmp]
file mkdir $::ELS_TMP

# Keep tests hermetic: never read or write the user's real %APPDATA%\els.
set ::env(APPDATA) [file join $::ELS_TMP appdata]
catch {file delete -force $::env(APPDATA)}

# Load the els library (UI is not launched on source).
source [file join $::ELS_ROOT els.tcl]

# Replace native dialogs with stubs so a stray dialog never blocks a test run.
proc ::tk_getOpenFile {args} { return $::els_test_openfile }
proc ::tk_getSaveFile {args} { return $::els_test_savefile }
proc ::tk_messageBox  {args} { return $::els_test_mbanswer }
set ::els_test_openfile ""
set ::els_test_savefile ""
set ::els_test_mbanswer "yes"

# Stub the OS-level menu post.  A real `tk_popup` in an unfocused/automated
# context blocks (waiting on a grab) and would flash a grabbing menu on the
# user's screen.  The real <Button-1> bindings still fire and build/configure
# the real menus; tests select entries via the canonical `<menu> invoke`.
proc ::tk_popup {args} {}

# Neutralize input grabs in tests: the go-to-line modal grabs, which could trap
# the user's input during an automated run. (Tests never assert on grab state.)
proc ::grab {args} {}

# Build a clean els UI for a test, resetting all document state.
proc els_reset {} {
    catch {. configure -menu {}}
    foreach w [winfo children .] { destroy $w }
    set ::els::docs {}
    set ::els::active ""
    set ::els::seq 0
    array unset ::els::docPath
    array set ::els::docPath {}
    set ::els::show_ws 0 ; set ::els::word_wrap 0
    catch {font configure elsMono -size 11}
    set ::els::font_size 11
    catch {set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]}
    els::build
    update
}

# Active (or named) document's text, minus the widget's mandatory final newline.
proc els_text {{id ""}} {
    set w [expr {$id eq "" ? [els::T] : [els::W $id]}]
    return [$w get 1.0 "end - 1 char"]
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
