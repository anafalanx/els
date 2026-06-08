#!/usr/bin/env tclsh
# tools/x.tcl — the els task runner.  ALL project tooling lives here (Tcl), plus
# C built by the vendored gcc.  Normally invoked through x.cmd (which sets PATH
# to the vendored toolchain first); this script re-asserts PATH itself so it is
# also robust when run directly with the vendored tclsh.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set TC   [file join $ROOT .toolchain]

# Some portable Tcl builds keep their script libraries in the packaged appfull
# tree rather than beside tclsh90.exe/wish90.exe.  Export those paths so every
# child Tcl/Tk process can initialize without relying on machine installs.
foreach {var rel marker} {
    TCL_LIBRARY {appfull tcl_library} init.tcl
    TK_LIBRARY  {appfull tk_library}  tk.tcl
} {
    set p [file join $TC {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}
set pkgpaths {}
foreach p [list [file join $ROOT tools tclpkg] \
                [file join $TC twapi-dl twapi-5.2.0] \
                [file join $TC twapi-dl]] {
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

# Make the vendored toolchain win on PATH (idempotent with x.cmd).  Tcl/Tk 9
# comes BEFORE msys64 (which ships its own Tcl/Tk 8.6 that els must never use).
# Git is optional (app and core tooling do not use it) — only added if vendored.
set vbins {}
foreach b [list [file join $TC tcl9 bin] [file join $TC msys64 ucrt64 bin] \
                [file join $TC git cmd]] {
    if {[file isdirectory $b]} { lappend vbins [file nativename $b] }
}
if {[llength $vbins]} { set ::env(PATH) "[join $vbins {;}];$::env(PATH)" }
if {![info exists ::env(MSYSTEM)]} { set ::env(MSYSTEM) UCRT64 }

# the vendored curl (used by the fetch tasks), or PATH curl as a fallback
proc curl-exe {} {
    foreach c [list [TCp msys64 usr bin curl.exe] [TCp msys64 ucrt64 bin curl.exe]] {
        if {[file exists $c]} { return $c }
    }
    return curl
}

# ---- path helpers -------------------------------------------------------
proc P  {args} { return [file join $::ROOT {*}$args] }
proc TCp {args} { return [file join $::TC {*}$args] }
# RULE: always go through these explicit vendored Tcl/Tk 9 paths — NEVER a bare
# `tclsh`/`wish`, which on PATH could resolve to msys64's Tcl/Tk 8.6.  C builds
# must likewise pass -I[TCp tcl9 include] (see build-ext / package).
proc tclsh {} { return [TCp tcl9 bin tclsh90.exe] }
proc wish  {} { return [TCp tcl9 bin wish90.exe] }
proc gcc   {} { return [TCp msys64 ucrt64 bin gcc.exe] }
proc windres {} { return [TCp msys64 ucrt64 bin windres.exe] }
proc strip-exe {} { return [TCp msys64 ucrt64 bin strip.exe] }
proc tclshs {} { return [TCp tcl9s bin tclsh90s.exe] }

# Stream a child's stdout/stderr through to ours.  A non-zero exit from the
# child is a NORMAL signal here (a failing test, a missing tool), so propagate
# the child's own exit code rather than letting exec's "child process exited
# abnormally" bubble up as if the task runner itself had crashed.  A genuine
# exec failure (could not start, killed by a signal) is re-raised as before.
proc stream {args} {
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} err opts]} {
        if {[lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            exit [lindex [dict get $opts -errorcode] 2]
        }
        return -options $opts $err
    }
}

# Cheap per-command guard: a task declares the tool(s) it needs; we only check
# those exist (a microsecond `file exists`, NOT a full toolchain scan), and
# point at `x toolcheck` if one is missing.
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
            error "required tool '$tool' is missing — run: x toolcheck --prep"
        }
    }
}

# ---- tasks --------------------------------------------------------------
proc task_help {args} {
    puts {els task runner — usage: x <command> [args]

  test [--fast]      run the in-process test suite (tcltest + event generate);
                     --fast skips the slow ~800-op encoding stress test
  probe <f> [args]   run an ad-hoc verification script under the CONSOLE tclsh
                     with the dialog-quiet preamble (tests/probe.tcl) preloaded,
                     so a probe error goes to stderr, never a modal dialog
  stress             UI-driven encoding stress test (open/reopen/save every
                     encoding, lots of mojibake; proves it never hangs)
  run [file ...]     launch the editor (wish + els.tcl)
  colors [name ...]  browse Tk's named colors (swatches + hex)
  icon [size]        regenerate the app icon (the awl) -> resources/icon.png
  shot <out> [file]  screenshot the editor to <out> (twapi)
  readme-shots       regenerate docs/img screenshots used by README.md
  build [out]        build the native els.exe — a custom C23 WinMain with Tcl+Tk
                     +icudet statically linked in and PE icon/manifest/version
                     baked via windres (see docs/native-port-study.md)
  build-wish [--with-ext]  legacy fallback: fuse els.exe onto a copy of wish90s
                     (--with-ext embeds build/*.dll); superseded by `build`
  probe-exe [exe]    launch the fused exe in a temp config home and verify
                     first-run prompt + session restore startup
  build-ext          compile the C23 extension(s) in src/ -> build/*.dll
  fetch-twapi        vendor the twapi extension into .toolchain/
  fetch-git          vendor MinGit into .toolchain/git/
  toolcheck [opts]   check the toolchain — --prep fetches/updates, --deep runs
                     functional checks (compile C, load Tk/twapi, run the chain)
  shell              open a shell with the vendored toolchain on PATH
  env                print the resolved toolchain paths + versions
  help               this message}
}

proc task_env {args} {
    puts "ROOT  = $::ROOT"
    foreach {label path} [list tclsh [tclsh] wish [wish] gcc [gcc]] {
        puts [format "  %-6s %s  (%s)" $label $path \
            [expr {[file exists $path] ? "ok" : "MISSING"}]]
    }
    set git [TCp git cmd git.exe]
    puts [format "  %-6s %s  (%s)" git $git \
        [expr {[file exists $git] ? "ok" : "optional — run `x fetch-git`"}]]
    catch {puts "  gcc   [exec [gcc] -dumpversion]"}
    catch {puts "  tcl   [exec [tclsh] << {puts [info patchlevel]}]"}
    if {[file exists $git]} { catch {puts "  git   [exec $git --version]"} }
}

proc task_toolcheck {args} {
    stream [tclsh] [P tools toolcheck.tcl] {*}$args
}

# LEGACY fallback build: fuse els.exe onto a copy of wish90s (the stock static Tk
# shell) by stamping the icon then appending the zipfs payload.  Superseded by the
# native `x build` (task_build below); kept one cycle as a rollback path.  Runs
# package.tcl under the STATIC tclsh90s so zipfs can append the payload.
proc task_build-wish {args} {
    set tclshs [TCp tcl9s bin tclsh90s.exe]
    if {![file exists $tclshs]} {
        error "static interpreter missing (.toolchain/tcl9s) — needed for `x build`; see `x toolcheck`"
    }
    # split out the output path (first non-flag) from flags like --with-ext
    set out "" ; set rest {}
    foreach a $args {
        if {[string match -* $a]} { lappend rest $a } elseif {$out eq ""} { set out $a } else { lappend rest $a }
    }
    if {$out eq ""} { set out [P els.exe] }
    # Icon the WRAPPER first: stamp the awl into a wish90s copy's PE resources,
    # then mkimg appends the zip AFTER it so both icon and payload survive.
    # (Editing the finished exe would strip the appended zipfs archive.)
    set wargs {}
    set tmpwrap [TCp _iconwrap.exe]
    set wish90s [TCp tcl9s bin wish90s.exe]
    catch {file delete -force $tmpwrap}
    if {[file exists $wish90s] && ![catch {file copy -force $wish90s $tmpwrap}]} {
        if {![catch {stream [tclsh] [P tools exeicon.tcl] $tmpwrap} e]} {
            set wargs [list --wrapper $tmpwrap]
        } else {
            puts "warning: PE icon skipped: $e"
        }
    }
    stream $tclshs [P tools package.tcl] $out {*}$wargs {*}$rest
    catch {file delete -force $tmpwrap}
}

proc task_probe-exe {args} {
    need tclsh
    set exe [lindex $args 0]
    if {$exe eq ""} { set exe [P els.exe] }
    stream [tclsh] [P tools probe_exe.tcl] $exe
}

proc task_test {args} {
    need tclsh
    stream [tclsh] [P tests run.tcl] {*}$args
}

# Run a throwaway verification probe the controlled way: CONSOLE tclsh (errors
# -> stderr, never a dialog) with tests/probe.tcl preloaded (transparent root,
# bgerror -> stderr, modal dialogs stubbed).  Never wish.  This is how all ad-hoc
# verification should run so a probe can never rain a dialog on the user.
proc task_probe {args} {
    need tclsh
    if {![llength $args]} { error "usage: x probe <script.tcl> \[args ...]" }
    set script [lindex $args 0]
    if {![file exists $script]} { error "probe script not found: $script" }
    set pp [string map {\\ /} [P tests probe.tcl]]
    set sp [string map {\\ /} [file normalize $script]]
    set boot "set ::argv0 {$sp}\nset ::argv {[lrange $args 1 end]}\nsource {$pp}\nsource {$sp}"
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
    if {[llength $args] < 1} { error "usage: x shot <out.png> \[file ...\]" }
    # shot.tcl captures via the cap extension (PrintWindow) — build it on demand
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    set out [lindex $args 0]
    stream [tclsh] [P tools shot.tcl] [wish] [P els.tcl] $out {*}[lrange $args 1 end]
}

proc task_readme-shots {args} {
    need tclsh wish twapi
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    stream [tclsh] [P tools readme_shots.tcl]
}

# Compile every src/*.c into build/<name>.dll against the Tcl stubs, and emit a
# pkgIndex.tcl so `package require <name>` works.  Init proc = Titlecased name
# (elsx.c -> Elsx_Init), matching Tcl's load convention.
proc task_build-ext {args} {
    need gcc tclsh
    set inc [TCp tcl9 include]
    set lib [TCp tcl9 lib]
    file mkdir [P build]
    set sources [lsort [glob -nocomplain [P src *.c]]]
    if {![llength $sources]} { puts "no src/*.c to build"; return }
    set idx [open [P build pkgIndex.tcl] w]
    puts $idx "# auto-generated by `x build-ext` — do not edit"
    foreach src $sources {
        set name [file rootname [file tail $src]]
        set dll  [P build $name.dll]
        set init [string totitle $name]
        puts "cc  [file tail $src] -> build/$name.dll"
        stream [gcc] -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
            -I$inc $src -o $dll -L$lib -ltclstub -static-libgcc -luser32 -lgdi32
        puts $idx "package ifneeded $name 0.1 \[list load \[file join \$dir $name.dll\] $init\]"
    }
    close $idx
    puts "built [llength $sources] extension(s); wrote build/pkgIndex.tcl"
}

# Build the native els.exe (THE canonical build): a custom C23 WinMain
# (src/els_main.c) statically linked against Tcl+Tk (.toolchain/tcl9s) with icudet
# compiled in and the PE resources (icon + manifest + version) baked via windres,
# then the same zipfs payload (tcl_library/tk_library/main.tcl/resources) appended.
# See docs/native-port-study.md.  Headers come from the SHARED tree (tcl9/include —
# tcl9s has none); libs from the STATIC tree (tcl9s/lib).  The legacy wish-wrapper
# build is `x build-wish` (task_build-wish above).
proc task_build {args} {
    need gcc tclsh
    if {![file exists [tclshs]]} { error "static tclsh missing (.toolchain/tcl9s) — run `x toolcheck`" }
    set out [lindex $args 0] ; if {$out eq ""} { set out [P els.exe] }
    set inc [TCp tcl9 include]
    set libd [TCp tcl9s lib]
    file mkdir [P build]
    # the Win32 system libraries Tk needs (= tkConfig.sh TK_LIBS, proven set)
    set syslibs {
        -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
        -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
        -loleaut32 -lwinspool
    }
    # 1. generate the PE resource inputs from Tcl into build/ (gitignored), so the
    #    committed repo stays Tcl + C + one .cmd: the .rc + manifest (version from
    #    els.tcl) and the .ico packed from the awl PNGs.
    puts "gen  build/els.rc + els.exe.manifest + els.ico"
    stream [tclsh] [P tools genres.tcl] [P build]
    stream [tclsh] [P tools mkico.tcl] [P build els.ico] \
        [P resources icon16.png] [P resources icon32.png] [P resources icon.png]
    # 2. compile resources (icon + manifest + VERSIONINFO) -> COFF object
    puts "windres build/els.rc -> build/els.res"
    stream [windres] --include-dir [P build] --include-dir $inc \
        [P build els.rc] -O coff -o [P build els.res]
    # 3. compile the entry point (UNICODE + STATIC + static icudet) and icudet
    puts "cc  els_main.c + icudet.c"
    stream [gcc] -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
        -DELS_STATIC_ICUDET -ffunction-sections -fdata-sections \
        -c [P src els_main.c] -o [P build els_main.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src icudet.c] -o [P build icudet.o] -I$inc
    # 4. link: GUI subsystem; Tk before Tcl before stub; system libs last
    puts "ld  -> build/els-bare.exe"
    set bare [P build els-bare.exe]
    stream [gcc] -municode -mwindows -static-libgcc -Wl,--gc-sections \
        [P build els_main.o] [P build icudet.o] [P build els.res] \
        [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] \
        [file join $libd libtclstub.a] {*}$syslibs -o $bare
    catch {stream [strip-exe] $bare}      ;# shrink before the payload append
    # 5. append the zipfs payload (tcl_library/tk_library/main.tcl/resources) onto
    #    OUR exe.  No --with-ext: icudet is compiled in, so no DLL is embedded.
    stream [tclshs] [P tools package.tcl] --wrapper $bare $out
}

proc task_fetch-twapi {args} {
    set ver 5.2 ; set zip twapi-5.2.0.zip
    set dest [TCp twapi-dl]
    if {[file exists [file join $dest twapi-5.2.0 pkgIndex.tcl]]} {
        puts "twapi already vendored at [file join $dest twapi-5.2.0]"
        return
    }
    file mkdir $dest
    set zpath [file join $dest $zip]
    puts "downloading twapi $ver ..."
    stream [curl-exe] -L --fail -o $zpath \
        "https://github.com/apnadkarni/twapi/releases/download/v$ver/$zip"
    # extract with Tcl's own zipfs (no external unzip needed)
    set mp /twapi_extract
    catch {zipfs unmount $mp}
    zipfs mount $zpath $mp
    file copy -force //zipfs:$mp/twapi-5.2.0 [file join $dest twapi-5.2.0]
    zipfs unmount $mp
    file delete -force $zpath
    puts "twapi $ver vendored at [file join $dest twapi-5.2.0]"
}

# Optional: vendor MinGit (git-for-windows' slim, embeddable, GUI-less build) so
# the project folder is self-contained on a machine without git.  Not needed by
# the app or the build/test tooling.  Pass a MinGit zip URL, or use the default.
proc task_fetch-git {args} {
    set url [lindex $args 0]
    if {$url eq ""} {
        set url "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip"
    }
    set dest [TCp git]
    if {[file exists [TCp git cmd git.exe]]} { puts "git already vendored at $dest"; return }
    file mkdir $dest
    set zpath [file join $::TC mingit.zip]
    puts "downloading MinGit from $url ..."
    stream [curl-exe] -L --fail -o $zpath $url
    set mp /mingit
    catch {zipfs unmount $mp}
    zipfs mount $zpath $mp
    foreach item [glob -nocomplain -tails -directory //zipfs:$mp *] {
        file copy -force //zipfs:$mp/$item [file join $dest $item]
    }
    zipfs unmount $mp
    file delete -force $zpath
    puts "MinGit vendored at $dest"
}

# ---- dispatch -----------------------------------------------------------
set cmd [lindex $argv 0]
if {$cmd eq ""} { set cmd help }
set proc "task_$cmd"
if {[llength [info commands $proc]] == 0} {
    puts stderr "x: unknown command '$cmd' (try: x help)"
    exit 2
}
if {[catch {$proc {*}[lrange $argv 1 end]} err]} {
    puts stderr "x $cmd: $err"
    exit 1
}
