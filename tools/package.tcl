# tools/package.tcl — build the single-file els.exe.
#
# MUST run under the STATIC tclsh90s: that interpreter has its tcl_library
# mounted at //zipfs:/app, which is where we source it from.  Invoked by
# `x build` (which selects tclsh90s).
#
#   tclsh90s.exe tools/package.tcl [out.exe] [--with-ext]
#
# Reproduces the proven layout — main.tcl, resources/, tcl_library/, tk_library/
# at the archive root — fused into a copy of the wish90s wrapper.  zipfs mkimg
# REPLACES the wrapper's own appended zip (which holds only tk_library), so we
# must stage BOTH libraries ourselves.

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set TC   [file join $ROOT .toolchain]
proc TCp {args} { return [file join $::TC {*}$args] }

set positional {}
set withExt 0
foreach a $argv {
    if {$a eq "--with-ext"} { set withExt 1 } else { lappend positional $a }
}
set out [lindex $positional 0]
if {$out eq ""} { set out [file join $ROOT els.exe] }

set wish [TCp tcl9s bin wish90s.exe]
if {![file exists $wish]} { error "static wish missing: $wish" }
if {![file isdirectory //zipfs:/app/tcl_library]} {
    error "tcl_library not at //zipfs:/app — run package.tcl under tclsh90s, not tclsh90"
}

set stage [file join $TC _pkg_stage]
file delete -force $stage
file mkdir $stage

# 1. tcl_library — from this static interp's //zipfs:/app
file copy -force //zipfs:/app/tcl_library [file join $stage tcl_library]

# 2. tk_library — from the wish90s wrapper's appended archive
zipfs mount $wish Wt
file copy -force //zipfs:/Wt/tk_library [file join $stage tk_library]
zipfs unmount $wish

# 3. app: main.tcl (= els.tcl) + resources/
file copy -force [file join $ROOT els.tcl] [file join $stage main.tcl]
if {[file isdirectory [file join $ROOT resources]]} {
    file copy -force [file join $ROOT resources] [file join $stage resources]
}

# 3b. optional: embed compiled C extensions (loadable from the zipfs image)
set ndll 0
if {$withExt} {
    foreach dll [glob -nocomplain -directory [file join $ROOT build] *.dll] {
        file copy -force $dll [file join $stage [file tail $dll]]
        incr ndll
    }
    set pidx [file join $ROOT build pkgIndex.tcl]
    if {$ndll && [file exists $pidx]} { file copy -force $pidx [file join $stage pkgIndex.tcl] }
}

# 4. fuse — STRIP=stage so the staged tree lands at the archive root
file delete -force $out
zipfs mkimg $out $stage $stage {} $wish
file delete -force $stage
puts "built [file nativename $out]  ([file size $out] bytes; ext: $ndll)"
