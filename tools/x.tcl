#!/usr/bin/env tclsh
# tools/x.tcl - the els task runner. ALL project tooling lives here (Tcl), plus
# C built by the pinned mal bundle's gcc. Normally invoked through x.cmd (which
# sets PATH to the pinned bundle first); this script re-asserts PATH itself so it
# is also robust when run directly with the bundle's tclsh.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

proc discover_store {root} {
    set pinfile [file join $root toolchain.pin]
    if {![file exists $pinfile]} {
        error "no toolchain.pin in $root - a mal project pins its bundle by name"
    }
    set fh [open $pinfile r] ; set pin [string trim [read $fh]] ; close $fh
    if {$pin eq ""} { error "toolchain.pin is empty in $root" }
    set dir $root
    for {set i 0} {$i < 8} {incr i} {
        set cand [file join $dir X $pin]
        if {[file exists [file join $cand BUNDLE.manifest]]} { return [list $cand $pin] }
        set up [file dirname $dir]
        if {$up eq $dir} break
        set dir $up
    }
    error "bundle '$pin' not found in any ancestor X/ store from $root"
}

set ROOT [script_root]
lassign [discover_store $ROOT] TC PIN

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [file join $TC {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}

set pkgpaths {}
foreach p [list [file join $ROOT tools tclpkg] \
                [file join $TC twapi-dl twapi-5.2.0] \
                [file join $TC twapi-dl] \
                [file join $ROOT build]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
foreach p [glob -nocomplain [file join $TC tcl9 lib *]] {
    if {[file isdirectory $p]} { lappend pkgpaths $p }
}
if {[llength $pkgpaths]} {
    if {[info exists ::env(TCLLIBPATH)] && $::env(TCLLIBPATH) ne ""} {
        set ::env(TCLLIBPATH) [concat $pkgpaths $::env(TCLLIBPATH)]
    } else {
        set ::env(TCLLIBPATH) $pkgpaths
    }
    set auto_path [concat $pkgpaths $auto_path]
}

set vbins {}
foreach b [list [file join $TC tcl9 bin] [file join $TC msys64 ucrt64 bin]] {
    if {[file isdirectory $b]} { lappend vbins [file nativename $b] }
}
if {[llength $vbins]} { set ::env(PATH) "[join $vbins {;}];$::env(PATH)" }
if {![info exists ::env(MSYSTEM)]} { set ::env(MSYSTEM) UCRT64 }

# ---- path helpers -------------------------------------------------------
proc P    {args} { return [file join $::ROOT {*}$args] }
proc TCp  {args} { return [file join $::TC   {*}$args] }
proc tclsh   {} { return [TCp tcl9 bin tclsh90.exe] }
proc wish    {} { return [TCp tcl9 bin wish90.exe] }
proc tclshs  {} { return [TCp tcl9s bin tclsh90s.exe] }
proc gcc     {} { return [TCp msys64 ucrt64 bin gcc.exe] }
proc windres {} { return [TCp msys64 ucrt64 bin windres.exe] }
proc strip-exe {} { return [TCp msys64 ucrt64 bin strip.exe] }

proc stream {args} {
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            set code [lindex [dict get $opts -errorcode] 2]
            return -code error -errorcode [list STREAM CHILD $code] \
                "child exited with status $code"
        }
        return -options $opts $err
    }
}

proc tool_path {tool} {
    switch $tool {
        tclsh { return [tclsh] }
        wish  { return [wish] }
        gcc   { return [gcc] }
        twapi { return [TCp twapi-dl twapi-5.2.0 pkgIndex.tcl] }
        default { return "" }
    }
}
proc need {args} {
    foreach tool $args {
        set p [tool_path $tool]
        if {$p eq "" || ![file exists $p]} {
            error "required tool '$tool' is missing - the pinned bundle is incomplete (run: mal verify $::PIN)"
        }
    }
}

# ---- tasks --------------------------------------------------------------
proc task_help {args} {
    puts {els task runner - usage: x <command> [args]

  test [--fast]      run the in-process test suite (tcltest + event generate);
                     --fast skips the slow encoding stress test
  probe <f> [args]   run an ad-hoc verification script under the CONSOLE tclsh
                     with tests/probe.tcl preloaded
  stress             UI-driven encoding stress test
  run [file ...]     launch the editor (wish + els.tcl)
  colors [name ...]  browse Tk's named colors (swatches + hex)
  icon [size]        regenerate the app icon (the awl) -> resources/icon.png
  shot <out> [file]  screenshot the editor to <out> (twapi + PrintWindow)
  readme-shots       regenerate docs/img screenshots used by README.md
  build [out]        build the native exe -> dist/els.exe
  probe-exe [exe]    verify the fused exe's startup/session/recovery behavior
  build-ext          compile the C23 extension(s) in src/ -> build/*.dll
  toolcheck [--deep] check the pinned bundle (--deep runs functional checks)
  shell              open a shell with the pinned bundle on PATH
  env                print the resolved bundle paths + versions
  help               this message}
}

proc task_env {args} {
    puts "ROOT  = $::ROOT"
    puts "PIN   = $::PIN"
    puts "TC    = $::TC"
    foreach {label path} [list tclsh [tclsh] wish [wish] gcc [gcc]] {
        puts [format "  %-6s %s  (%s)" $label $path \
            [expr {[file exists $path] ? "ok" : "MISSING"}]]
    }
    catch {puts "  gcc   [exec [gcc] -dumpversion]"}
    catch {puts "  tcl   [exec [tclsh] << {puts [info patchlevel]}]"}
}

proc task_toolcheck {args} {
    stream [tclsh] [P tools toolcheck.tcl] {*}$args
}

proc task_probe-exe {args} {
    need tclsh
    set exe [lindex $args 0]
    if {$exe eq ""} { set exe [P dist els.exe] }
    stream [tclsh] [P tools probe_exe.tcl] $exe
}

proc task_test {args} {
    need tclsh
    stream [tclsh] [P tests run.tcl] {*}$args
}

proc task_probe {args} {
    need tclsh
    if {![llength $args]} { error "usage: x probe <script.tcl> \[args ...]" }
    set script [lindex $args 0]
    if {![file exists $script]} { error "probe script not found: $script" }
    set pp [string map {\\ /} [P tests probe.tcl]]
    set sp [string map {\\ /} [file normalize $script]]
    set boot [list set ::argv0 $sp]
    append boot \n [list set ::argv [lrange $args 1 end]]
    append boot \n [list source $pp]
    append boot \n [list source $sp]
    if {[catch {exec [tclsh] << $boot >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            exit [lindex [dict get $opts -errorcode] 2]
        }
        return -options $opts $err
    }
}

proc task_stress {args} {
    need tclsh
    stream [tclsh] [P tests encoding_stress.tcl] {*}$args
}

proc task_run {args} {
    need wish
    set ::env(ELS_NO_SINGLE_INSTANCE) 1
    exec [wish] [P els.tcl] {*}$args &
    puts "launched els"
}

proc task_colors {args} {
    need wish
    exec [wish] [P tools colors.tcl] {*}$args &
    puts "launched color viewer"
}

proc task_icon {args} {
    need wish
    stream [wish] [P tools icon.tcl] {*}$args
}

proc task_shot {args} {
    need tclsh wish twapi
    if {[lindex $args 0] eq "--selftest"} { stream [tclsh] [P tools shot.tcl] --selftest ; return }
    if {[llength $args] < 1} { error "usage: x shot <out.png> \[file ...\]" }
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    set out [lindex $args 0]
    stream [tclsh] [P tools shot.tcl] [wish] [P els.tcl] $out {*}[lrange $args 1 end]
}

proc task_readme-shots {args} {
    need tclsh wish twapi
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    stream [tclsh] [P tools readme_shots.tcl]
}

proc task_build-ext {args} {
    need gcc tclsh
    set inc [TCp tcl9 include]
    set lib [TCp tcl9 lib]
    file mkdir [P build]
    set sources {}
    foreach s [lsort [glob -nocomplain [P src *.c]]] {
        if {[file tail $s] eq "els_main.c"} continue
        lappend sources $s
    }
    if {![llength $sources]} { puts "no src/*.c to build"; return }
    set lines [list "# auto-generated by `x build-ext` - do not edit"]
    foreach src $sources {
        set name [file rootname [file tail $src]]
        set dll  [P build $name.dll]
        set init [string totitle $name]
        puts "cc  [file tail $src] -> build/$name.dll"
        stream [gcc] -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
            -I$inc $src -o $dll -L$lib -ltclstub -static-libgcc -luser32 -lgdi32
        lappend lines "package ifneeded $name 0.1 \[list load \[file join \$dir $name.dll\] $init\]"
    }
    set idx [open [P build pkgIndex.tcl] w]
    puts $idx [join $lines \n]
    close $idx
    puts "built [llength $sources] extension(s); wrote build/pkgIndex.tcl"
}

proc task_build {args} {
    need gcc tclsh
    if {![file exists [tclshs]]} {
        error "static tclsh missing in the bundle (tcl9s/bin) - run `mal verify $::PIN`"
    }
    set out [lindex $args 0] ; if {$out eq ""} { set out [P dist els.exe] }
    if {[string match -* $out]} { error "x build takes no flags (got '$out'); usage: x build ?outfile?" }
    set inc [TCp tcl9 include]
    set libd [TCp tcl9s lib]
    file mkdir [P build]
    set syslibs {
        -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
        -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
        -loleaut32 -lwinspool
    }
    puts "gen  build/els.rc + els.exe.manifest + els.ico"
    stream [tclsh] [P tools genres.tcl] [P build]
    stream [tclsh] [P tools mkico.tcl] [P build els.ico] \
        [P resources icon16.png] [P resources icon32.png] [P resources icon.png]
    puts "windres build/els.rc -> build/els.res"
    stream [windres] --include-dir [P build] --include-dir $inc \
        [P build els.rc] -O coff -o [P build els.res]
    puts "cc  els_main.c + icudet.c + winfs.c"
    stream [gcc] -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
        -DELS_STATIC_ICUDET -DELS_STATIC_WINFS -ffunction-sections -fdata-sections \
        -c [P src els_main.c] -o [P build els_main.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src icudet.c] -o [P build icudet.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src winfs.c] -o [P build winfs.o] -I$inc
    puts "ld  -> build/els-bare.exe"
    set bare [P build els-bare.exe]
    stream [gcc] -municode -mwindows -static-libgcc -Wl,--gc-sections \
        [P build els_main.o] [P build icudet.o] [P build winfs.o] [P build els.res] \
        [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] \
        [file join $libd libtclstub.a] {*}$syslibs -o $bare
    catch {stream [strip-exe] $bare}
    file mkdir [file dirname $out]
    set staged "$out.new"
    stream [tclshs] [P tools package.tcl] --wrapper $bare $staged
    catch {file delete -force "$out.old"}
    if {[catch {file rename -force $staged $out}]} {
        if {[catch {
            file rename -force $out "$out.old"
            file rename -force $staged $out
        } e]} {
            catch {file delete -force $staged}
            error "cannot place $out (locked?): $e"
        }
        puts "note: $out was in use; the running copy is parked as [file tail $out.old]"
    }
    puts "placed $out ([file size $out] bytes)"
}

# ---- dispatch -----------------------------------------------------------
set cmd [lindex $argv 0]
if {$cmd eq ""} { set cmd help }
set proc "task_$cmd"
if {[llength [info commands $proc]] == 0} {
    puts stderr "x: unknown command '$cmd' (try: x help)"
    exit 2
}
if {[catch {$proc {*}[lrange $argv 1 end]} err opts]} {
    set ec [dict get $opts -errorcode]
    if {[lindex $ec 0] eq "STREAM" && [lindex $ec 1] eq "CHILD"} {
        exit [lindex $ec 2]
    }
    puts stderr "x $cmd: $err"
    exit 1
}
