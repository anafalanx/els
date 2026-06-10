# tools/package.tcl — append the els zipfs payload onto a wrapper exe.
#
# Runs under the STATIC tclsh90s so zipfs can `lmkimg`-append the staged app
# payload — main.tcl (= els.tcl), resources/, tcl_library/, tk_library/ at the
# archive root (+ build/*.dll with --with-ext) — onto a Tk-capable wrapper, AFTER
# the PE image so a baked-in icon/manifest survives.  The wrapper (`--wrapper`)
# is the native build's build/els-bare.exe (our custom C WinMain, resources
# already baked at link time).
#
#   tclsh90s.exe tools/package.tcl [out.exe] [--wrapper W] [--with-ext]
#
# tk_library is extracted from wish90s.exe's own appended archive (present
# regardless of the mkimg wrapper) or the portable appfull payload; tcl_library
# from the static interp's //zipfs:/app or appfull.

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
        # no expr ternary on file names: expr canonicalizes number-looking
        # operands, so a payload file named "007" would be packaged as "7"
        if {$rel eq ""} { set zrel $name } else { set zrel [file join $rel $name] }
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
if {$out eq ""} { set out [file join $ROOT dist els.exe] }

# `wish` = the original static wrapper (used to extract tk_library); the mkimg
# wrapper may be an icon-stamped copy (--wrapper) — its icon survives because
# mkimg appends the zip AFTER the PE image.
set wish [TCp tcl9s bin wish90s.exe]
if {![file exists $wish]} { error "static wish missing: $wish" }
if {$wrapperOverride ne ""} { set mkimgWrapper $wrapperOverride } else { set mkimgWrapper $wish }
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
#
# Only the extensions the PRODUCT itself loads ship in els.exe.  build/ also
# holds cap.dll (the test-only PrintWindow capture used by tools/shot.tcl) and
# elsx.dll (a demo extension); embedding every build/*.dll would bake those into
# the shipped binary.  els.tcl `package require`s only icudet (charset
# detection), so that is the whole allow-list.
set PRODUCT_EXTS {icudet}
set ndll 0
if {$withExt} {
    foreach name $PRODUCT_EXTS {
        set dll [file join $ROOT build $name.dll]
        if {![file exists $dll]} continue
        file copy -force $dll [file join $stage $name.dll]
        incr ndll
    }
    # Write a lean pkgIndex carrying only the allow-listed loaders, reusing the
    # exact `package ifneeded` lines `x build-ext` generated (so the version and
    # init-proc name stay in sync) but dropping cap/elsx.
    set pidx [file join $ROOT build pkgIndex.tcl]
    if {$ndll && [file exists $pidx]} {
        set fh [open $pidx r] ; set src [read $fh] ; close $fh
        set keep {}
        foreach ln [split $src \n] {
            foreach name $PRODUCT_EXTS {
                if {[regexp "package ifneeded $name \[ \t\]" $ln]} { lappend keep $ln ; break }
            }
        }
        set fh [open [file join $stage pkgIndex.tcl] w]
        puts $fh "# lean product index — only the extensions els loads ([join $PRODUCT_EXTS {, }])"
        puts $fh [join $keep \n]
        close $fh
    }
}

# 4. fuse — STRIP=stage so the staged tree lands at the archive root
file delete -force $out
set entries [zip_entries $stage]
if {![llength $entries]} { error "package stage is empty: $stage" }
zipfs lmkimg $out $entries {} $mkimgWrapper
file delete -force $stage
puts "built [file nativename $out]  ([file size $out] bytes; ext: $ndll[expr {$wrapperOverride ne {} ? {; iconned wrapper} : {}}])"
