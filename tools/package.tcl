# tools/package.tcl — build the single-file els.exe.
#
# Runs under the STATIC tclsh90s selected by `x build`, so zipfs can append the
# staged app payload to a Tk-capable wrapper.
#
#   tclsh90s.exe tools/package.tcl [out.exe] [--with-ext]
#
# Reproduces the proven layout — main.tcl, resources/, tcl_library/, tk_library/
# at the archive root — fused into a copy of the wish90s wrapper.  The staged
# libraries come from the static zipfs image when available, or from the
# portable appfull payload used by the launcher.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set TC   [file join $ROOT .toolchain]
proc TCp {args} { return [file join $::TC {*}$args] }
proc copy_tree {src dst} {
    file mkdir $dst
    foreach item [glob -nocomplain [file join $src *]] {
        set target [file join $dst [file tail $item]]
        if {[file isdirectory $item]} {
            copy_tree $item $target
        } else {
            file copy -force $item $target
        }
    }
}
proc zip_entries {root {rel ""}} {
    set out {}
    foreach item [glob -nocomplain [file join $root $rel *]] {
        set name [file tail $item]
        set zrel [expr {$rel eq "" ? $name : [file join $rel $name]}]
        if {[file isdirectory $item]} {
            lappend out {*}[zip_entries $root $zrel]
        } else {
            lappend out $item [string map {\\ /} $zrel]
        }
    }
    return $out
}

set positional {}
set withExt 0
set wrapperOverride ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        --with-ext { set withExt 1 }
        --wrapper  { incr i ; set wrapperOverride [lindex $argv $i] }
        default    { lappend positional [lindex $argv $i] }
    }
}
set out [lindex $positional 0]
if {$out eq ""} { set out [file join $ROOT els.exe] }

# `wish` = the original static wrapper (used to extract tk_library); the mkimg
# wrapper may be an icon-stamped copy (--wrapper) — its icon survives because
# mkimg appends the zip AFTER the PE image.
set wish [TCp tcl9s bin wish90s.exe]
if {![file exists $wish]} { error "static wish missing: $wish" }
set mkimgWrapper [expr {$wrapperOverride ne "" ? $wrapperOverride : $wish}]
if {[file isdirectory //zipfs:/app/tcl_library]} {
    set tclLibrary //zipfs:/app/tcl_library
} elseif {[file isdirectory [TCp appfull tcl_library]]} {
    set tclLibrary [TCp appfull tcl_library]
} else {
    error "tcl_library not found in //zipfs:/app or .toolchain/appfull"
}

set stage [file join $TC _pkg_stage]
file delete -force $stage
file mkdir $stage

# 1. tcl_library — from the static interp's //zipfs:/app when mounted, otherwise
# from the staged appfull payload used by the portable launcher.
copy_tree $tclLibrary [file join $stage tcl_library]

# 2. tk_library — from the wish90s wrapper's appended archive
set copiedTk 0
if {![catch {zipfs mount $wish Wt}]} {
    if {[file isdirectory //zipfs:/Wt/tk_library]} {
        copy_tree //zipfs:/Wt/tk_library [file join $stage tk_library]
        set copiedTk 1
    }
    zipfs unmount Wt
}
if {!$copiedTk && [file isdirectory [TCp appfull tk_library]]} {
    copy_tree [TCp appfull tk_library] [file join $stage tk_library]
    set copiedTk 1
}
if {!$copiedTk} { error "tk_library not found in wish90s.exe or .toolchain/appfull" }

# 3. app: main.tcl (= els.tcl) + resources/
file copy -force [file join $ROOT els.tcl] [file join $stage main.tcl]
if {[file isdirectory [file join $ROOT resources]]} {
    copy_tree [file join $ROOT resources] [file join $stage resources]
}

# 3b. optional: embed compiled C extensions (loadable from the zipfs image)
set ndll 0
if {$withExt} {
    foreach dll [glob -nocomplain [file join $ROOT build *.dll]] {
        file copy -force $dll [file join $stage [file tail $dll]]
        incr ndll
    }
    set pidx [file join $ROOT build pkgIndex.tcl]
    if {$ndll && [file exists $pidx]} { file copy -force $pidx [file join $stage pkgIndex.tcl] }
}

# 4. fuse — STRIP=stage so the staged tree lands at the archive root
file delete -force $out
set entries [zip_entries $stage]
if {![llength $entries]} { error "package stage is empty: $stage" }
zipfs lmkimg $out $entries {} $mkimgWrapper
file delete -force $stage
puts "built [file nativename $out]  ([file size $out] bytes; ext: $ndll[expr {$wrapperOverride ne {} ? {; iconned wrapper} : {}}])"
