#!/usr/bin/env tclsh
# tools/toolcheck.tcl — check (and optionally prep) the vendored toolchain.
#
#   x toolcheck          report what is present / missing / outdated (+ versions)
#   x toolcheck --prep    fetch/update the auto-installable pieces
#
# The everyday `x` commands do NOT re-verify the whole toolchain (that would tax
# every invocation); they only fast-check the one or two tools they need and, if
# something is missing, point here.  This is the thorough, on-demand check.

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set TC   [file join $ROOT .toolchain]
proc TCp {args} { return [file join $::TC {*}$args] }

# Component manifest.  kind: core (build/test/run) | opt (extra).  want: the
# pinned version (empty = don't compare).  prep: {auto <x-task>} | {manual "…"}.
set ::COMPONENTS {
    {key tcl   name "Tcl/Tk 9 (shared)"  probe {tcl9 bin tclsh90.exe}              kind core want 9.0.3            prep {manual "rebuild Tcl/Tk 9 from source (build recipe in docs)"}}
    {key gcc   name "gcc / C23 (UCRT64)" probe {msys64 ucrt64 bin gcc.exe}         kind core want 16.1.0           prep {manual "vendor the MSYS2 UCRT64 toolchain (gcc/binutils/gdb)"}}
    {key twapi name "twapi"              probe {twapi-dl twapi-5.2.0 pkgIndex.tcl} kind core want 5.2.0            prep {auto fetch-twapi}}
    {key git   name "Git (MinGit)"       probe {git cmd git.exe}                   kind core want 2.54.0.windows.1 prep {auto fetch-git}}
    {key tcls  name "Tcl/Tk 9 (static)"  probe {tcl9s bin tclsh90s.exe}            kind opt  want 9.0.3            prep {manual "static build (--disable-shared); only for single-exe packaging"}}
    {key curl  name "curl"               probe {msys64 usr bin curl.exe}           kind opt  want {}               prep {manual "ships with MSYS2; used by the fetch tasks"}}
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

# {state version}  — state in {ok outdated missing}
proc status_of {comp} {
    if {![present $comp]} { return [list missing ""] }
    set v [version_of [dict get $comp key]]
    set want [dict get $comp want]
    if {$want ne "" && $v ne $want} { return [list outdated $v] }
    return [list ok $v]
}

proc report {} {
    puts ""
    puts "els toolcheck  —  .toolchain under [file nativename $::TC]"
    puts ""
    puts [format "  %-22s %-9s %s" COMPONENT STATUS VERSION/NOTE]
    puts "  [string repeat - 58]"
    set issues 0
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        set kind [dict get $c kind]
        lassign [dict get $c prep] ptype parg
        switch $state {
            ok       { set status "OK"       ; set note $v }
            outdated { set status "UPDATE"   ; set note "have $v, want [dict get $c want]"
                       if {$kind eq "core"} { incr issues } }
            missing  { set status [expr {$kind eq "core" ? "MISSING" : "(absent)"}]
                       set note [expr {$ptype eq "auto" ? "run:  x $parg" : $parg}]
                       if {$kind eq "core"} { incr issues } }
        }
        puts [format "  %-22s %-9s %s" [dict get $c name] $status $note]
    }
    puts ""
    return $issues
}

proc prep {} {
    set xtcl [file join $::ROOT tools x.tcl]
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        if {$state eq "ok"} continue
        lassign [dict get $c prep] ptype parg
        if {$ptype ne "auto"} {
            if {[dict get $c kind] eq "core"} {
                puts ">> [dict get $c name]: manual — $parg"
            }
            continue
        }
        puts ">> $state [dict get $c name]:  x $parg"
        if {$state eq "outdated"} {
            # force a re-fetch by removing the old vendored dir (contained to .toolchain)
            catch {file delete -force [TCp [lindex [dict get $c probe] 0]]}
        }
        catch {exec [TCp tcl9 bin tclsh90.exe] $xtcl $parg >@ stdout 2>@ stderr}
    }
}

# ---- main ---------------------------------------------------------------
set doPrep [expr {("--prep" in $argv) || ("--fix" in $argv)}]
set issues [report]
if {$doPrep} {
    if {$issues == 0} {
        puts "  nothing to do — all core components present and current."
    } else {
        prep
        puts "--- re-check ---"
        set issues [report]
    }
}
if {$issues > 0} {
    puts "  $issues core issue(s).  `x toolcheck --prep` fetches/updates the installable ones."
    exit 1
}
puts "  all core components present and current."
exit 0
