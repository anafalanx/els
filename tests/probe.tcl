# tests/probe.tcl — preamble for ad-hoc, GUI-quiet verification probes.
#
# Source this FIRST in any throwaway probe, then load els / an extension / etc.
# It guarantees the probe is headless and CANNOT pop a dialog:
#   - the Tk root is transparent and tiny (present, but never seen)
#   - every background / event-loop error goes to stderr, never a modal dialog
#   - the native modal entry points are stubbed to non-blocking no-ops
#
# ALWAYS run a probe with tclsh90 (a console app: startup errors -> stderr),
# NEVER wish90 (a GUI-subsystem app with no console: a startup error can only be
# REPORTED as a modal dialog).  `x probe <script.tcl> [args]` does this for you.

package require Tk
catch {wm attributes . -alpha 0.0}
wm geometry . 1x1+0+0

proc ::els_probe_bgerror {msg {opts {}}} {
    catch {puts stderr "BGERROR: $msg\n$::errorInfo"}
}
catch {interp bgerror {} ::els_probe_bgerror}
proc ::bgerror {msg} { ::els_probe_bgerror $msg }
catch {proc ::tk::dialog::error::bgerror {msg args} { ::els_probe_bgerror $msg }}

# Non-blocking stubs for the native modal dialogs.
proc ::tk_messageBox      {args} { return "ok" }
proc ::tk_dialog          {args} { return 0 }
proc ::tk_getOpenFile     {args} { return "" }
proc ::tk_getSaveFile     {args} { return "" }
proc ::tk_chooseColor     {args} { return "" }
proc ::tk_chooseDirectory {args} { return "" }
proc ::grab               {args} {}
