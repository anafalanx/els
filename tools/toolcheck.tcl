#!/usr/bin/env tclsh
# tools/toolcheck.tcl - check that z's shared runtime payloads have what els
# needs and, with --deep, that they actually work.  els carries no private
# .toolchain: Tcl/Tk 9, the UCRT64 gcc, and twapi all come from <z>/.z/r.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
proc zmal_paths {root args} {
    set out {}
    if {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne ""} {
        lappend out [file join $::env(Z_HOME) {*}$args]
    } elseif {[info exists ::env(Z_ROOT)] && $::env(Z_ROOT) ne ""} {
        lappend out [file join $::env(Z_ROOT) .z {*}$args]
    }
    lappend out [file join [file dirname $root] .z {*}$args]
    return $out
}
proc discover_payload {root envs rel marker missingPath} {
    set candidates {}
    foreach var $envs {
        if {[info exists ::env($var)] && $::env($var) ne ""} { lappend candidates $::env($var) }
    }
    lappend candidates {*}[zmal_paths $root {*}$rel]
    foreach p $candidates {
        set p [file normalize $p]
        if {[file exists [file join $p {*}$marker]]} { return $p }
    }
    return [file normalize $missingPath]
}
set ROOT [script_root]
set TC    [discover_payload $ROOT Z_TCLTK {r tcltk 9.0.4} {tcl9 bin tclsh90.exe} \
              [file join [file dirname $ROOT] .z r tcltk 9.0.4]]
set MSYS2 [discover_payload $ROOT Z_MSYS2 {r msys2} {ucrt64 bin gcc.exe} \
              [file join [file dirname $ROOT] .z r msys2]]
set TWAPI [discover_payload $ROOT Z_TWAPI {r twapi 5.2.0} {pkgIndex.tcl} \
              [file join [file dirname $ROOT] .z r twapi 5.2.0]]
proc P      {args} { return [file join $::ROOT  {*}$args] }
proc TCp    {args} { return [file join $::TC    {*}$args] }
proc MSYSp  {args} { return [file join $::MSYS2 {*}$args] }
proc TWAPIp {args} { return [file join $::TWAPI {*}$args] }

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [TCp {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list [file join $ROOT tools tclpkg] $TWAPI [P build]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
if {[llength $pkgpaths]} {
    set ::env(TCLLIBPATH) [expr {[info exists ::env(TCLLIBPATH)] && $::env(TCLLIBPATH) ne "" \
        ? [concat $pkgpaths $::env(TCLLIBPATH)] : $pkgpaths}]
    set auto_path [concat $pkgpaths $auto_path]
}

set ::COMPONENTS {
    {key tcl      name "Tcl/Tk 9 (shared)"      loc tc     probe {tcl9 bin tclsh90.exe}          kind core want 9.0.4}
    {key wish     name "Tk 9 wish"              loc tc     probe {tcl9 bin wish90.exe}           kind core want {}}
    {key gcc      name "gcc / C23 (UCRT64)"     loc msys2  probe {ucrt64 bin gcc.exe}            kind core want 16.1.0}
    {key windres  name "windres"                loc msys2  probe {ucrt64 bin windres.exe}        kind core want {}}
    {key strip    name "strip"                  loc msys2  probe {ucrt64 bin strip.exe}           kind core want {}}
    {key sha256   name "SHA-256 tool"            loc msys2  probe {usr bin sha256sum.exe}           kind core want {}}
    {key git      name "Git release enumerator"  loc msys2  probe {usr bin git.exe}                 kind core want {}}
    {key tcls     name "Tcl/Tk 9 (static)"      loc tc     probe {tcl9s bin tclsh90s.exe}        kind core want 9.0.4}
    {key wishs    name "Tk 9 static wrapper"    loc tc     probe {tcl9s bin wish90s.exe}         kind core want {}}
    {key libtcl   name "static Tcl library"     loc tc     probe {tcl9s lib libtcl90.a}          kind core want {}}
    {key libtk    name "static Tk library"      loc tc     probe {tcl9s lib libtcl9tk90.a}       kind core want {}}
    {key libstub  name "static Tcl stub library" loc tc    probe {tcl9s lib libtclstub.a}        kind core want {}}
    {key tclh     name "Tcl/Tk 9 headers"       loc tc     probe {tcl9 include tcl.h}            kind core want {}}
    {key tcllib   name "Tcl/Tk script library"  loc tc     probe {tcllib tcl_library init.tcl}   kind core want {}}
    {key tklib    name "Tk script library"      loc tc     probe {tcllib tk_library tk.tcl}      kind core want {}}
    {key twapi    name "twapi"                  loc twapi  probe {pkgIndex.tcl}                  kind core want 5.2.0}
    {key manual   name "Tcl/Tk + C-API manual"  loc tc     probe {manual INDEX.md}               kind opt  want {}}
    {key tclsrc   name "Tcl/Tk 9 source"        loc tc     probe {tclsrc tcl9.0.4 generic tcl.h} kind core want {}}
    {key zliblic  name "bundled zlib notice"     loc tc     probe {tclsrc tcl9.0.4 compat zlib LICENSE} kind core want {}}
    {key tomlic   name "LibTomMath notice"        loc tc     probe {tclsrc tcl9.0.4 libtommath LICENSE} kind core want {}}
    {key mingwlic name "MinGW runtime notices"    loc msys2  probe {ucrt64 share licenses crt COPYING.MinGW-w64-runtime.txt} kind core want {}}
    {key gccgpl   name "GCC runtime GPLv3 terms"   loc msys2  probe {ucrt64 share licenses gcc-libs COPYING3} kind core want {}}
    {key gccex    name "GCC runtime exception"    loc msys2  probe {ucrt64 share licenses gcc-libs COPYING.RUNTIME} kind core want {}}
    {key tclpkg   name "project tclpkg helper"  loc root   probe {tools tclpkg pkgIndex.tcl}     kind opt  want {}}
}

proc comp_path {comp args} {
    set rel [concat [dict get $comp probe] $args]
    switch [dict get $comp loc] {
        root    { return [P     {*}$rel] }
        msys2   { return [MSYSp {*}$rel] }
        twapi   { return [TWAPIp {*}$rel] }
        default { return [TCp   {*}$rel] }
    }
}
proc present {comp} { return [file exists [comp_path $comp]] }

proc version_of {comp} {
    set v ""
    switch [dict get $comp key] {
        tcl   { if {[catch {exec [TCp tcl9 bin tclsh90.exe]   << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        tcls  { if {[catch {exec [TCp tcl9s bin tclsh90s.exe] << {puts [info patchlevel]}} v]} {
                    return "ERROR: [string map [list \n { }] [string trim $v]]" } }
        gcc   { catch {exec [MSYSp ucrt64 bin gcc.exe] -dumpversion} v }
        twapi { set idx [comp_path $comp]
                if {![catch {open $idx r} fh]} { set d [read $fh] ; close $fh
                    regexp {package ifneeded\s+twapi\s+(\S+)} $d -> v } }
    }
    return $v
}
proc status_of {comp} {
    if {![present $comp]} { return [list missing ""] }
    set v [version_of $comp]
    if {[string match {ERROR:*} $v]} { return [list broken $v] }
    set want [dict get $comp want]
    if {$want ne "" && $v ne $want} { return [list outdated $v] }
    return [list ok $v]
}

proc report {} {
    puts ""
    puts "els toolcheck  -  z shared runtime payloads"
    puts "    tcltk  [file nativename $::TC]"
    puts "    msys2  [file nativename $::MSYS2]"
    puts "    twapi  [file nativename $::TWAPI]"
    puts ""
    puts [format "  %-24s %-9s %s" COMPONENT STATUS VERSION/NOTE]
    puts "  [string repeat - 60]"
    set issues 0
    foreach c $::COMPONENTS {
        lassign [status_of $c] state v
        set kind [dict get $c kind]
        switch $state {
            ok       { set status "OK"     ; set note $v }
            broken   { set status "BROKEN" ; set note $v ; if {$kind eq "core"} { incr issues } }
            outdated { set status "UPDATE" ; set note "have $v, want [dict get $c want]"
                       if {$kind eq "core"} { incr issues } }
            missing  { set status [expr {$kind eq "core" ? "MISSING" : "(absent)"}]
                       set note [expr {$kind eq "core" ? "restore z's runtime payloads" : ""}]
                       if {$kind eq "core"} { incr issues } }
        }
        puts [format "  %-24s %-9s %s" [dict get $c name] $status $note]
    }
    puts ""
    return $issues
}

proc tmpdir {} { return [P build "_toolcheck-[pid]-[clock clicks]"] }
proc fwd {p} { return [string map {\\ /} [file nativename $p]] }
proc tcl_eval {script} {
    if {[catch {exec [TCp tcl9 bin tclsh90.exe] << $script} out]} { return [list 0 $out] }
    return [list 1 $out]
}
proc deep_line {name ok detail} {
    puts [format "  %-26s %-5s %s" $name [expr {$ok ? {PASS} : {FAIL}}] $detail]
    return [expr {$ok ? 0 : 1}]
}
proc deep_ext {} {
    set gcc [MSYSp ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C23<->Tcl extension" 0 "gcc missing"] }
    set t [tmpdir]
    if {[file exists $t]} { return [deep_line "C23<->Tcl extension" 0 "unique scratch path already exists"] }
    file mkdir $t
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
        lassign [tcl_eval "load {[fwd $dll]} Tcverify; puts \[tcverify\]"] loadOk lout
        if {!$loadOk || [string trim $lout] ne "1234"} { set ok 0; set detail "load failed: $lout" }
    }
    file delete -force $t
    return [deep_line "C23<->Tcl extension" $ok $detail]
}
proc deep_header {} {
    set gcc [MSYSp ucrt64 bin gcc.exe]
    if {![file exists $gcc]} { return [deep_line "C build uses Tcl 9 header" 0 "gcc missing"] }
    set t [tmpdir]
    if {[file exists $t]} { return [deep_line "C build uses Tcl 9 header" 0 "unique scratch path already exists"] }
    file mkdir $t
    set c [file join $t hv.c]
    set fh [open $c w] ; puts $fh "#include <tcl.h>" ; puts $fh {const char *V = TCL_PATCH_LEVEL;} ; close $fh
    set v ""
    if {![catch {exec $gcc -I[TCp tcl9 include] -E $c} out]} { regexp {const char \*V = "([0-9.]+)"} $out -> v }
    file delete -force $t
    return [deep_line "C build uses Tcl 9 header" [string match 9.* $v] "tcl.h = $v"]
}
proc deep_static_zipfs {} {
    set shell [TCp tcl9s bin tclsh90s.exe]
    if {![file exists $shell]} { return [deep_line "Static Tcl has zipfs" 0 "tclsh90s missing"] }
    if {[catch {exec $shell << {puts [expr {[llength [info commands zipfs]] == 1} ]}} out]} {
        return [deep_line "Static Tcl has zipfs" 0 [string trim $out]]
    }
    set ok [expr {[string trim $out] eq "1"}]
    return [deep_line "Static Tcl has zipfs" $ok [expr {$ok ? "zipfs command available" : "zipfs command missing"}]]
}
proc deep {} {
    puts ""
    puts "  functional checks (does it actually run?):"
    set f 0
    lassign [tcl_eval {puts [expr {6*7}]}] ok out
    incr f [deep_line "Tcl evaluates a script" [expr {$ok && [string trim $out] eq "42"}] [string trim $out]]
    lassign [tcl_eval {package require Tk; label .l -text hi; puts [winfo class .l]; exit}] ok out
    incr f [deep_line "Tk creates a widget" [expr {$ok && [string match *abel [string trim $out]]}] [string trim $out]]
    lassign [tcl_eval "lappend auto_path {[fwd $::TWAPI]}; puts \[package require twapi\]"] ok out
    incr f [deep_line "twapi loads" [expr {$ok && [string match 5.* [string trim $out]]}] [string trim $out]]
    incr f [deep_ext]
    incr f [deep_header]
    incr f [deep_static_zipfs]
    return $f
}

if {[llength $argv] > 1 || ([llength $argv] == 1 && [lindex $argv 0] ne "--deep")} {
    puts stderr "usage: z check ?--deep?"
    exit 2
}
set doDeep [expr {[llength $argv] == 1}]
set issues [report]
if {$doDeep} { incr issues [deep] }
puts ""
if {$issues > 0} {
    puts "  $issues issue(s). A MISSING core piece means a z runtime payload is incomplete."
    exit 1
}
puts [expr {$doDeep ? "  all components present, current, and functional." \
                    : "  all core components present and current. (`z check --deep` verifies they work)"}]
exit 0
