#!/usr/bin/env tclsh
# tools/toolcheck.tcl — check (and optionally prep) the vendored toolchain.
#
#   x toolcheck          report what is present / missing (+ versions)
#   x toolcheck --prep   fetch the auto-installable pieces that are missing
#
# The everyday `x` commands do NOT re-verify the whole toolchain (that would tax
# every invocation); they only fast-check the one or two tools they need and, if
# something is missing, point here.  This is the thorough, on-demand check.

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set TC   [file join $ROOT .toolchain]
proc TCp {args} { return [file join $::TC {*}$args] }

# Component manifest.  kind: core (needed to build/test/run) | opt (extra).
# prep: {auto <x-task>}  or  {manual "<instructions>"}.
set ::COMPONENTS {
    {key tcl   name "Tcl/Tk 9 (shared)"   probe {tcl9 bin tclsh90.exe}               kind core prep {manual "rebuild Tcl/Tk 9 from source (build recipe in docs)"}}
    {key gcc   name "gcc / C23 (UCRT64)"  probe {msys64 ucrt64 bin gcc.exe}          kind core prep {manual "vendor the MSYS2 UCRT64 toolchain (gcc/binutils/gdb)"}}
    {key twapi name "twapi 5.2"           probe {twapi-dl twapi-5.2.0 pkgIndex.tcl}  kind core prep {auto fetch-twapi}}
    {key git   name "Git (MinGit)"        probe {git cmd git.exe}                    kind core prep {auto fetch-git}}
    {key tcls  name "Tcl/Tk 9 (static)"   probe {tcl9s bin tclsh90s.exe}             kind opt  prep {manual "static build (--disable-shared); only for single-exe packaging"}}
    {key curl  name "curl"                probe {msys64 usr bin curl.exe}            kind opt  prep {manual "ships with MSYS2; used by the fetch tasks"}}
}

proc present {comp} { return [file exists [TCp {*}[dict get $comp probe]]] }

proc version_of {key} {
    set v ""
    switch $key {
        tcl   { catch {exec [TCp tcl9 bin tclsh90.exe]    << {puts [info patchlevel]}} v }
        tcls  { catch {exec [TCp tcl9s bin tclsh90s.exe]  << {puts [info patchlevel]}} v }
        gcc   { catch {exec [TCp msys64 ucrt64 bin gcc.exe] -dumpversion} v }
        git   { catch {exec [TCp git cmd git.exe] --version} v
                set v [string trim [string map {{git version} {}} $v]] }
        twapi { set v 5.2.0 }
        curl  { catch {exec [TCp msys64 usr bin curl.exe] --version} out
                regexp {curl (\S+)} $out -> v }
    }
    return $v
}

proc report {} {
    puts ""
    puts "els toolcheck  —  .toolchain under [file nativename $::TC]"
    puts ""
    puts [format "  %-22s %-9s %s" COMPONENT STATUS VERSION/NOTE]
    puts "  [string repeat - 58]"
    set missing 0
    foreach c $::COMPONENTS {
        set key  [dict get $c key]
        set kind [dict get $c kind]
        if {[present $c]} {
            set status "OK" ; set note [version_of $key]
        } else {
            lassign [dict get $c prep] ptype parg
            set note [expr {$ptype eq "auto" ? "run:  x $parg" : $parg}]
            set status [expr {$kind eq "core" ? "MISSING" : "(absent)"}]
            if {$kind eq "core"} { incr missing }
        }
        puts [format "  %-22s %-9s %s" [dict get $c name] $status $note]
    }
    puts ""
    return $missing
}

proc prep {} {
    set xtcl [file join $::ROOT tools x.tcl]
    foreach c $::COMPONENTS {
        if {[present $c]} continue
        lassign [dict get $c prep] ptype parg
        if {$ptype eq "auto"} {
            puts ">> prepping [dict get $c name]:  x $parg"
            catch {exec [TCp tcl9 bin tclsh90.exe] $xtcl $parg >@ stdout 2>@ stderr}
        } elseif {[dict get $c kind] eq "core"} {
            puts ">> [dict get $c name]: manual — $parg"
        }
    }
}

# ---- main ---------------------------------------------------------------
set doPrep [expr {("--prep" in $argv) || ("--fix" in $argv)}]
set missing [report]
if {$doPrep} {
    if {$missing == 0} {
        puts "  nothing to prep — all core components present."
    } else {
        prep
        puts "--- re-check ---"
        set missing [report]
    }
}
if {$missing > 0} {
    puts "  $missing core component(s) missing.  `x toolcheck --prep` fetches the installable ones."
    exit 1
}
puts "  all core components present."
exit 0
