# tools/package.tcl - append the els zipfs payload onto a wrapper exe.
#
# Runs under the STATIC tclsh90s so zipfs can lmkimg-append the staged app
# payload - main.tcl (= els.tcl), resources/, licenses, tcl_library/, tk_library/
# at the archive root (+ build/*.dll with --with-ext) - onto a Tk-capable wrapper,
# AFTER the PE image so a baked-in icon/manifest survives.
#
#   tclsh90s.exe tools/package.tcl [build/out.exe] [--wrapper W] [--with-ext]

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
# els uses z's SHARED Tcl/Tk payload (<z>/.z/r/tcltk/9.0.4); tasks.tcl exports
# Z_TCLTK/Z_HOME into our environment, and we fall back to the hosted layout.
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
proc discover_tcltk {root} {
    set cands {}
    if {[info exists ::env(Z_TCLTK)] && $::env(Z_TCLTK) ne ""} { lappend cands $::env(Z_TCLTK) }
    lappend cands {*}[zmal_paths $root r tcltk 9.0.4]
    foreach p $cands {
        set p [file normalize $p]
        if {[file exists [file join $p tcl9 bin tclsh90.exe]]} { return $p }
    }
    error "z Tcl/Tk payload not found (r/tcltk/9.0.4) - restore z's runtime payloads"
}
proc discover_msys2 {root} {
    set cands {}
    if {[info exists ::env(Z_MSYS2)] && $::env(Z_MSYS2) ne ""} { lappend cands $::env(Z_MSYS2) }
    lappend cands {*}[zmal_paths $root r msys2]
    foreach p $cands {
        set p [file normalize $p]
        if {[file isfile [file join $p ucrt64 share licenses crt COPYING.MinGW-w64-runtime.txt]]} {
            return $p
        }
    }
    error "z MSYS2 payload not found (r/msys2) - restore z's runtime payloads"
}
set ROOT [script_root]
set TC   [discover_tcltk $ROOT]
set MSYS2 [discover_msys2 $ROOT]
proc TCp {args} { return [file join $::TC {*}$args] }
source [file join $ROOT tools release_notices.tcl]

proc package_path_type {path} {
    if {[catch {set st [file lstat $path]} err opts]} {
        if {![file exists $path]} { return missing }
        return -options $opts $err
    }
    return [dict get $st type]
}
proc package_path_key {path} {
    set path [string map {\\ /} [file normalize $path]]
    if {$::tcl_platform(platform) eq "windows"} { set path [string tolower $path] }
    return [string trimright $path /]
}
proc package_path_beneath {path parent} {
    set path [package_path_key $path]
    set parent [package_path_key $parent]
    return [expr {[string first "$parent/" "$path/"] == 0 && $path ne $parent}]
}
proc package_real_directory {path label} {
    set type [package_path_type $path]
    if {$type eq "missing"} {
        file mkdir $path
        set type [package_path_type $path]
    }
    if {$type ne "directory"} {
        error "$label must be a real directory, not $type: $path"
    }
    return [file normalize $path]
}
proc package_regular_or_absent {path label} {
    set type [package_path_type $path]
    if {$type ni {missing file}} {
        error "$label must be absent or a regular file (found $type): $path"
    }
    return $type
}
proc package_delete_regular {path} {
    set type [package_path_type $path]
    if {$type eq "missing"} { return }
    if {$type ne "file"} { error "refusing to delete non-regular package path ($type): $path" }
    file delete -- $path
}
proc package_remove_tree {path} {
    set type [package_path_type $path]
    if {$type eq "missing"} { return }
    if {$type ne "directory"} { error "refusing to remove non-directory package stage ($type): $path" }
    file delete -force -- $path
}
proc validate_package_output {root out} {
    package_real_directory [file join $root build] "package build root"
    set out [file normalize $out]
    if {![package_path_beneath $out [file join $root build]]} {
        error "package output must remain below [file join $root build]: $out"
    }
    if {![regexp -nocase {\.exe(?:\.new-[0-9]+)?$} [file tail $out]]} {
        error "package output must end in .exe (or the task runner's .exe.new-PID staging suffix): $out"
    }
    set rel [string range [package_path_key $out] \
        [expr {[string length [package_path_key [file join $root build]]] + 1}] end]
    set first [lindex [split $rel /] 0]
    if {$first in {release-check release-sign release-reproduce native-startup-check}} {
        error "package output uses a release-tooling-reserved directory: $out"
    }
    package_real_directory [file dirname $out] "package output directory"
    package_regular_or_absent $out "package output"
    return $out
}

proc package_children {dir} {
    set items [glob -nocomplain -directory $dir *]
    lappend items {*}[glob -nocomplain -types hidden -directory $dir *]
    return [lsort -dictionary -unique $items]
}
proc copy_tree {src dst} {
    file mkdir $dst
    foreach item [package_children $src] {
        set target [file join $dst [file tail $item]]
        set type [package_path_type $item]
        if {$type eq "directory"} {
            copy_tree $item $target
        } elseif {$type eq "file"} {
            file copy -force $item $target
        } else {
            error "package source tree contains unsupported $type entry: $item"
        }
    }
}
proc zip_entries {root {rel ""}} {
    set out {}
    foreach item [package_children [file join $root $rel]] {
        set name [file tail $item]
        if {$rel eq ""} { set zrel $name } else { set zrel [file join $rel $name] }
        set type [package_path_type $item]
        if {$type eq "directory"} {
            lappend out {*}[zip_entries $root $zrel]
        } elseif {$type eq "file"} {
            lappend out $item [string map {\\ /} $zrel]
        } else {
            error "package stage contains unsupported $type entry: $item"
        }
    }
    return $out
}

# Project resources are release inputs, so copy exactly what Git tracks rather
# than a directory glob that can silently admit ignored editor backups or other
# uncommitted files.  Tcl/Tk runtime trees are separately pinned by provenance.
proc copy_tracked_resources {root stage} {
    set git [file join $::MSYS2 usr bin git.exe]
    if {![file isfile $git]} { error "trusted z git is required to enumerate tracked release resources" }
    set saved {}
    foreach name [array names ::env GIT_*] {
        if {[info exists ::env($name)]} {
            dict set saved $name [list 1 $::env($name)]
            unset ::env($name)
        } else { dict set saved $name [list 0 ""] }
    }
    set ::env(GIT_CONFIG_NOSYSTEM) 1
    set ::env(GIT_TERMINAL_PROMPT) 0
    set ::env(GIT_OPTIONAL_LOCKS) 0
    try {
        if {[catch {exec $git -C $root ls-files -z -- resources} raw opts]} {
            return -options $opts "cannot enumerate tracked resources: $raw"
        }
    } finally {
        foreach name [array names ::env GIT_*] { unset ::env($name) }
        dict for {name state} $saved {
            lassign $state had value
            if {$had} { set ::env($name) $value } else { catch {unset ::env($name)} }
        }
    }
    foreach rel [split $raw \x00] {
        if {$rel eq ""} continue
        set rel [string map {\\ /} $rel]
        if {![string match {resources/*} $rel]} {
            error "git returned an out-of-scope resource path: $rel"
        }
        set src [file join $root {*}[split $rel /]]
        if {[catch {set type [dict get [file lstat $src] type]}] || $type ne "file"} {
            error "tracked resource is missing or is not a regular file: $src"
        }
        set inside [lrange [split $rel /] 1 end]
        set dst [file join $stage resources {*}$inside]
        file mkdir [file dirname $dst]
        file copy -force -- $src $dst
    }
}

proc normalize_package_mtimes {root epoch} {
    foreach item [package_children $root] {
        if {[file isdirectory $item]} { normalize_package_mtimes $item $epoch }
        file mtime $item $epoch
    }
    file mtime $root $epoch
}

set positional {}
set withExt 0
set wrapperOverride ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        --with-ext { set withExt 1 }
        --wrapper  {
            if {$i + 1 >= [llength $argv]} { error "--wrapper requires a path" }
            incr i
            set wrapperOverride [lindex $argv $i]
        }
        default {
            set arg [lindex $argv $i]
            if {[string match --* $arg]} { error "unknown package option '$arg'" }
            lappend positional $arg
        }
    }
}
if {[llength $positional] > 1} { error "usage: package.tcl ?build/out.exe? ?--wrapper path? ?--with-ext?" }
set out [lindex $positional 0]
if {$out eq ""} { set out [file join $ROOT build els-dev.exe] }
set out [validate_package_output $ROOT $out]

set wish [TCp tcl9s bin wish90s.exe]
if {![file isfile $wish]} { error "static wish missing: $wish" }
if {$wrapperOverride ne ""} { set mkimgWrapper $wrapperOverride } else { set mkimgWrapper $wish }
if {[package_path_type $mkimgWrapper] ne "file"} {
    error "package wrapper is missing or not a regular file: $mkimgWrapper"
}
if {[file isdirectory //zipfs:/app/tcl_library]} {
    set tclLibrary //zipfs:/app/tcl_library
} elseif {[file isdirectory [TCp tcllib tcl_library]]} {
    set tclLibrary [TCp tcllib tcl_library]
} else {
    error "tcl_library not found in //zipfs:/app or the bundle's tcllib"
}

set scratch [file tempdir [file join $ROOT build _package]]
set scratch [file normalize $scratch]
if {![package_path_beneath $scratch [file join $ROOT build]]} {
    error "package scratch directory escaped build/: $scratch"
}
if {[package_path_type $scratch] ne "directory"} {
    error "package scratch path is not a real directory: $scratch"
}
set stage [file join $scratch payload]
file mkdir $stage
set image [file join $scratch image.exe]

try {
    copy_tree $tclLibrary [file join $stage tcl_library]

    set copiedTk 0
    if {![catch {zipfs mount $wish Wt}]} {
        if {[file isdirectory //zipfs:/Wt/tk_library]} {
            copy_tree //zipfs:/Wt/tk_library [file join $stage tk_library]
            set copiedTk 1
        }
        zipfs unmount Wt
    }
    if {!$copiedTk && [file isdirectory [TCp tcllib tk_library]]} {
        copy_tree [TCp tcllib tk_library] [file join $stage tk_library]
        set copiedTk 1
    }
    if {!$copiedTk} { error "tk_library not found in wish90s.exe or the bundle's tcllib" }

    if {[package_path_type [file join $ROOT els.tcl]] ne "file"} {
        error "project main script is missing or not a regular file"
    }
    file copy -force -- [file join $ROOT els.tcl] [file join $stage main.tcl]
    copy_tracked_resources $ROOT $stage

    # A one-file binary still has to carry the notices governing its own and its
    # statically-linked code.  Keep the verbatim els license separately and also
    # provide one discoverable third-party notice containing all applicable terms.
    set ownLicense [file join $ROOT LICENSE]
    if {[package_path_type $ownLicense] ne "file"} { error "project license is missing: $ownLicense" }
    file copy -force $ownLicense [file join $stage LICENSE.txt]
    set noticePath [file join $stage THIRD-PARTY-NOTICES.txt]
    set notice [open $noticePath {WRONLY CREAT TRUNC}]
    try {
        fconfigure $notice -translation binary
        puts -nonewline $notice [::elsrelease::third_party_notices $TC $MSYS2]
    } finally {
        close $notice
    }

    set PRODUCT_EXTS {icudet}
    set ndll 0
    if {$withExt} {
        foreach name $PRODUCT_EXTS {
            set dll [file join $ROOT build $name.dll]
            set dllType [package_path_type $dll]
            if {$dllType eq "missing"} continue
            if {$dllType ne "file"} { error "product extension is not a regular file: $dll" }
            # --with-ext is a manual/development packaging path.  Never make a
            # plausible-looking image from a DLL older than either its source or
            # the build recipe; the fused production build does not use this path.
            foreach input [list [file join $ROOT src $name.c] [file join $ROOT tools tasks.tcl]] {
                if {[package_path_type $input] ne "file"} {
                    error "product extension input is missing or not a regular file: $input"
                }
                if {[file mtime $input] > [file mtime $dll]} {
                    error "product extension is stale: $dll (run z build-ext)"
                }
            }
            file copy -force $dll [file join $stage $name.dll]
            incr ndll
        }
        set pidx [file join $ROOT build pkgIndex.tcl]
        if {$ndll} {
            if {[package_path_type $pidx] ne "file"} {
                error "extension package index is missing or not a regular file: $pidx"
            }
            set fh [open $pidx r]
            try { set src [read $fh] } finally { close $fh }
            set keep {}
            foreach ln [split $src \n] {
                foreach name $PRODUCT_EXTS {
                    if {[regexp "package ifneeded $name \[ \t\]" $ln]} { lappend keep $ln ; break }
                }
            }
            set fh [open [file join $stage pkgIndex.tcl] w]
            try {
                puts $fh "# lean product index - only the extensions els loads ([join $PRODUCT_EXTS {, }])"
                puts $fh [join $keep \n]
            } finally { close $fh }
        }
    }

    set entries [zip_entries $stage]
    if {![llength $entries]} { error "package stage is empty: $stage" }
    if {[info exists ::env(SOURCE_DATE_EPOCH)] && $::env(SOURCE_DATE_EPOCH) ne ""} {
        if {![string is wideinteger -strict $::env(SOURCE_DATE_EPOCH)]} {
            error "SOURCE_DATE_EPOCH must be an integer"
        }
        normalize_package_mtimes $stage $::env(SOURCE_DATE_EPOCH)
    }
    zipfs lmkimg $image $entries {} $mkimgWrapper
    if {[package_path_type $image] ne "file"} { error "packager did not produce a regular file: $image" }
    file rename -force -- $image $out
} finally {
    package_delete_regular $image
    package_remove_tree $scratch
}
puts "built [file nativename $out]  ([file size $out] bytes; ext: $ndll[expr {$wrapperOverride ne {} ? {; iconned wrapper} : {}}])"
