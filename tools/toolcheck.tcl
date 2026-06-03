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

# ---- deep functional checks (--deep): does it actually RUN? ---------------
# Everything is exercised through the *console* tclsh90, so failures arrive as
# text on stderr (never a GUI dialog), including the Tk check.
proc tmpdir {} {
    set d [expr {[info exists ::env(TEMP)] && $::env(TEMP) ne "" ? $::env(TEMP) : $::TC}]
    return [file join $d els_toolcheck_[pid]]
}
proc fwd {p} { return [string map {\\ /} [file nativename $p]] }

proc tcl_eval {script} {
    # run a script in the vendored shared tclsh; return {ok output}
    if {[catch {exec [TCp tcl9 bin tclsh90.exe] << $script} out]} { return [list 0 $out] }
    return [list 1 $out]
}
proc deep_line {name ok detail} {
    puts [format "  %-26s %-5s %s" $name [expr {$ok ? {PASS} : {FAIL}}] $detail]
    return [expr {$ok ? 0 : 1}]
}

# Compile a tiny stubs extension and load it — proves gcc + headers + stubs +
# Tcl's `load` all work together (the whole C23<->Tcl chain).
proc deep_ext {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C23<->Tcl extension" 0 "gcc missing"] }
    set t [tmpdir]; file delete -force $t; file mkdir $t
    set c [file join $t tcverify.c]; set dll [file join $t tcverify.dll]
    set fh [open $c w]
    puts $fh {#include <tcl.h>}
    puts $fh {static int Tc(void*cd,Tcl_Interp*ip,int o,Tcl_Obj*const v[]){Tcl_SetObjResult(ip,Tcl_NewIntObj(1234));return TCL_OK;}}
    puts $fh {int Tcverify_Init(Tcl_Interp*ip){if(Tcl_InitStubs(ip,"9.0",0)==NULL)return TCL_ERROR;Tcl_CreateObjCommand(ip,"tcverify",Tc,NULL,NULL);return TCL_OK;}}
    close $fh
    set ok 1; set detail "gcc -std=c23 compile + stubs load OK"
    if {[catch {exec $gcc -std=c23 -O1 -shared -DUSE_TCL_STUBS -I[TCp tcl9 include] \
            $c -o $dll -L[TCp tcl9 lib] -ltclstub -static-libgcc} e]} {
        set ok 0; set detail "compile failed: $e"
    } else {
        lassign [tcl_eval "load {[fwd $dll]} Tcverify; puts \[tcverify\]"] lok lout
        if {!$lok || [string trim $lout] ne "1234"} { set ok 0; set detail "load failed: $lout" }
    }
    file delete -force $t
    return [deep_line "C23<->Tcl extension" $ok $detail]
}

# Confirm the C build resolves els's Tcl 9 header — NOT msys64's bundled 8.6.
proc deep_header {} {
    set gcc [TCp msys64 ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C build uses Tcl 9 header" 0 "gcc missing"] }
    set t [tmpdir] ; file delete -force $t ; file mkdir $t
    set c [file join $t hv.c]
    set fh [open $c w]
    puts $fh {#include <tcl.h>}
    puts $fh {const char *V = TCL_PATCH_LEVEL;}
    close $fh
    set v ""
    if {![catch {exec $gcc -I[TCp tcl9 include] -E $c} out]} {
        regexp {const char \*V = "([0-9.]+)"} $out -> v
    }
    file delete -force $t
    return [deep_line "C build uses Tcl 9 header" [string match 9.* $v] "tcl.h = $v"]
}

proc deep {} {
    puts ""
    puts "  functional checks (does it actually run?):"
    set f 0
    lassign [tcl_eval {puts [expr {6*7}]}] ok out
    incr f [deep_line "Tcl evaluates a script" [expr {$ok && [string trim $out] eq "42"}] [string trim $out]]
    lassign [tcl_eval {package require Tk; label .l -text hi; puts [winfo class .l]; exit}] ok out
    incr f [deep_line "Tk creates a widget" [expr {$ok && [string match *abel [string trim $out]]}] [string trim $out]]
    lassign [tcl_eval "lappend auto_path {[fwd [TCp twapi-dl]]}; puts \[package require twapi\]"] ok out
    incr f [deep_line "twapi loads" [expr {$ok && [string match 5.* [string trim $out]]}] [string trim $out]]
    incr f [deep_ext]
    incr f [deep_header]
    if {[file exists [TCp git cmd git.exe]]} {
        set ok [expr {![catch {exec [TCp git cmd git.exe] --version}]}]
        incr f [deep_line "git runs" $ok ""]
    }
    return $f
}

# ---- main ---------------------------------------------------------------
set doPrep [expr {("--prep" in $argv) || ("--fix" in $argv)}]
set doDeep [expr {"--deep" in $argv}]
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
if {$doDeep} { incr issues [deep] }
puts ""
if {$issues > 0} {
    puts "  $issues issue(s). `x toolcheck --prep` fetches/updates; `--deep` runs functional checks."
    exit 1
}
puts [expr {$doDeep ? "  all components present, current, and functional." \
                    : "  all core components present and current.  (run `x toolcheck --deep` to verify they work)"}]
exit 0
