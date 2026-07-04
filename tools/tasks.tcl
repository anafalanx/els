#!/usr/bin/env tclsh
# tools/tasks.tcl - the internal els task runner behind z.json. ALL project tooling
# lives here (Tcl), plus C built by zmal's vendored UCRT64 gcc. It is invoked
# through z.exe, which discovers the project root and command manifest.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

# els is a hosted zmal project: it builds against zmal's SHARED runtime payloads
# under <zmal>/r (Tcl/Tk 9, MSYS2 UCRT64 gcc, twapi) and carries no private
# .toolchain.  z.exe starts this script with zmal's tclsh90 and exports ZMAL_ROOT;
# the discovery below resolves each payload from the ZMAL_* env vars or the hosted
# layout, so the script also works when run directly with the vendored tclsh.
proc zmal_paths {root args} {
    set out {}
    if {[info exists ::env(ZMAL_ROOT)] && $::env(ZMAL_ROOT) ne ""} {
        lappend out [file join $::env(ZMAL_ROOT) {*}$args]
    }
    # Hosted layout: <zmal>/_els, so the zmal root is the project parent.
    lappend out [file join [file dirname $root] {*}$args]
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
set TC    [discover_payload $ROOT ZMAL_TCLTK {r tcltk 9.0.3} {tcl9 bin tclsh90.exe} \
              [file join [file dirname $ROOT] r tcltk 9.0.3]]
set MSYS2 [discover_payload $ROOT ZMAL_MSYS2 {r msys2} {ucrt64 bin gcc.exe} \
              [file join [file dirname $ROOT] r msys2]]
set TWAPI [discover_payload $ROOT ZMAL_TWAPI {r twapi 5.2.0} {pkgIndex.tcl} \
              [file join [file dirname $ROOT] r twapi 5.2.0]]
set ::env(ZMAL_TCLTK) [file nativename $TC]
set ::env(ZMAL_MSYS2) [file nativename $MSYS2]
set ::env(ZMAL_TWAPI) [file nativename $TWAPI]

foreach {var rel marker} {
    TCL_LIBRARY {tcllib tcl_library} init.tcl
    TK_LIBRARY  {tcllib tk_library}  tk.tcl
} {
    set p [file join $TC {*}$rel]
    if {[file exists [file join $p $marker]]} { set ::env($var) [file nativename $p] }
}

set pkgpaths {}
foreach p [list [file join $ROOT tools tclpkg] $TWAPI [file join $ROOT build]] {
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

# zmal runtime wins on PATH: Tcl/Tk 9 BEFORE MSYS2, which ships its own Tcl/Tk 8.6
# that els must never use.
set vbins {}
foreach b [list [file join $TC tcl9 bin] [file join $MSYS2 ucrt64 bin] [file join $MSYS2 usr bin]] {
    if {[file isdirectory $b]} { lappend vbins [file nativename $b] }
}
if {[llength $vbins]} { set ::env(PATH) "[join $vbins {;}];$::env(PATH)" }
if {![info exists ::env(MSYSTEM)]} { set ::env(MSYSTEM) UCRT64 }

# ---- path helpers -------------------------------------------------------
proc P      {args} { return [file join $::ROOT  {*}$args] }
proc TCp    {args} { return [file join $::TC    {*}$args] }
proc MSYSp  {args} { return [file join $::MSYS2 {*}$args] }
proc TWAPIp {args} { return [file join $::TWAPI {*}$args] }
proc tclsh   {} { return [TCp tcl9 bin tclsh90.exe] }
proc wish    {} { return [TCp tcl9 bin wish90.exe] }
proc tclshs  {} { return [TCp tcl9s bin tclsh90s.exe] }
proc gcc     {} { return [MSYSp ucrt64 bin gcc.exe] }
proc windres {} { return [MSYSp ucrt64 bin windres.exe] }
proc strip-exe {} { return [MSYSp ucrt64 bin strip.exe] }

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
        twapi { return [TWAPIp pkgIndex.tcl] }
        default { return "" }
    }
}
proc need {args} {
    foreach tool $args {
        set p [tool_path $tool]
        if {$p eq "" || ![file exists $p]} {
            error "required tool '$tool' is missing - restore zmal's runtime payloads (r/tcltk, r/msys2, r/twapi)"
        }
    }
}

# ---- tasks --------------------------------------------------------------
proc task_help {args} {
    puts {els task runner - invoked through z.exe

  z test [--fast]       run the in-process test suite (tcltest + event generate);
                        --fast skips the slow encoding stress test
  z probe <f> [args]    run an ad-hoc verification script under the console tclsh
                        with tests/probe.tcl preloaded
  z stress              UI-driven encoding stress test
  z run [file ...]      launch the editor (wish + els.tcl)
  z colors [name ...]   browse Tk's named colors (swatches + hex)
  z icon [size]         regenerate the app icon (the awl) -> resources/icon.png
  z shot <out> [file]   screenshot the editor to <out> (twapi + PrintWindow)
  z readme-shots        regenerate docs/img screenshots used by README.md
  z build [out]         build the native exe -> dist/els.exe
  z sign [exe]          code-sign the release exe (Certum/SimplySign) + re-probe + verify
  z probe-exe [exe]     verify the fused exe's startup/session/recovery behavior
  z build-ext           compile the C23 extension(s) in src/ -> build/*.dll
  z check [--deep]      check zmal's runtime payloads (r/tcltk, r/msys2, r/twapi)
  z tasks env           print resolved toolchain paths + versions}
}

proc task_env {args} {
    puts "ROOT  = $::ROOT"
    puts "TCLTK = $::TC"
    puts "MSYS2 = $::MSYS2"
    puts "TWAPI = $::TWAPI"
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

# find_signtool locates signtool.exe (from the Windows SDK; not a zmal payload).
# Prefers the highest installed SDK version, then the zmal r/winsdk junction, then PATH.
proc find_signtool {} {
    set sdk [lsort [glob -nocomplain {C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe}]]
    if {[llength $sdk]} { return [lindex $sdk end] }
    set j {C:/zmal/r/winsdk/10.0.26100.0/signtool.exe}
    if {[file exists $j]} { return $j }
    set p [auto_execok signtool]
    if {[llength $p]} { return [lindex $p 0] }
    error "signtool.exe not found - install the Windows SDK \"Signing Tools for Desktop Apps\""
}

# run_capture runs a command capturing BOTH stdout and stderr into one string, and
# returns [list exitcode text]. (Plain exec drops stderr, where signtool writes its
# "No certificates" message; and it must not treat stderr output as an error.)
proc run_capture {args} {
    set ch [file tempfile tmp]
    set rc [catch {exec {*}$args >@ $ch 2>@ $ch} err opts]
    close $ch
    set f [open $tmp r] ; set text [read $f] ; close $f
    file delete -force $tmp
    if {$rc} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} { return [list [lindex $ec 2] $text] }
        return [list 1 [string trim "$text\n$err"]]
    }
    return [list 0 $text]
}

# task_sign - code-sign a release exe with the Certum Open Source cert (SimplySign).
#   z sign [exe]   (default: dist/els.exe)
# Holds no secrets and no name: signtool /a auto-selects the machine's code-signing
# certificate. Prerequisite: SimplySign Desktop must be CONNECTED (tray icon ->
# Connect to SimplySign, your SimplySign e-mail + the 6-digit phone token) so the cloud
# cert appears in the Windows store; otherwise this refuses rather than emit an unsigned
# binary. Because els.exe carries a zipfs payload appended at EOF and Authenticode
# appends its cert table there too, the signed exe is re-PROBED before it is trusted.
proc task_sign {args} {
    need tclsh
    set signtool [find_signtool]
    set exe [lindex $args 0]
    if {$exe eq ""} { set exe [P dist els.exe] }
    if {![file exists $exe]} { error "file not found: $exe" }
    set exe [file normalize $exe]
    puts "file:     $exe"
    puts "signtool: $signtool"

    # 1) Sign. /a auto-selects the code-signing cert (no identity hardcoded); the
    # timestamp flags are mandatory - they keep the signature valid past cert expiry.
    puts "signing (a PIN dialog may pop from SimplySign Desktop on the first sign)..."
    lassign [run_capture $signtool sign /a /tr http://time.certum.pl /td sha256 /fd sha256 /v $exe] rc out
    puts [string trim $out]
    if {$rc != 0} {
        if {[string match {*No certificates were found*} $out]} {
            error "no code-signing certificate found - SimplySign is not connected.\n  -> Open SimplySign Desktop, tray icon -> Connect to SimplySign\n     (your SimplySign e-mail + the 6-digit phone token), then re-run.\n     Refusing to emit an unsigned binary."
        }
        error "signtool sign failed (exit $rc)"
    }

    # 2) Prove the signed exe still mounts its zipfs and runs (see the header note).
    puts "probe: confirming the signed exe still mounts its zipfs + runs..."
    if {[catch {stream [tclsh] [P tools probe_exe.tcl] $exe} perr]} {
        error "the SIGNED exe FAILED the probe - refusing to ship a broken binary:\n  $perr"
    }

    # 3) Verify the signature is valid AND timestamped.
    lassign [run_capture $signtool verify /pa /all /v $exe] vrc vout
    if {$vrc != 0} { error "signature verify FAILED:\n$vout" }
    if {![string match {*timestamp*} $vout]} {
        error "signature is NOT timestamped - it would expire with the certificate. Aborting."
    }

    # 4) Report the full-file SHA-256 for the release notes (certutil is a Windows
    # built-in - no tcllib dependency).
    set sum ""
    lassign [run_capture certutil -hashfile $exe SHA256] hrc hout
    foreach line [split $hout \n] {
        set t [string map {" " ""} [string trim $line]]
        if {[regexp {^[0-9a-fA-F]{64}$} $t]} { set sum [string tolower $t] ; break }
    }
    puts ""
    puts "OK - signed, verified, timestamped."
    puts "  file    $exe"
    if {$sum ne ""} { puts "  sha256  $sum" }
}

proc task_test {args} {
    need tclsh
    stream [tclsh] [P tests run.tcl] {*}$args
}

proc task_probe {args} {
    need tclsh
    if {![llength $args]} { error "usage: z probe <script.tcl> \[args ...]" }
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
    if {[llength $args] < 1} { error "usage: z shot <out.png> \[file ...\]" }
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    set out [lindex $args 0]
    stream [tclsh] [P tools shot.tcl] [wish] [P els.tcl] $out {*}[lrange $args 1 end]
}

proc task_readme-shots {args} {
    need tclsh wish twapi
    if {![file exists [P build cap.dll]]} { puts "building capture extension..." ; task_build-ext }
    stream [tclsh] [P tools readme_shots.tcl] [wish] [tclsh]
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
    set lines [list "# auto-generated by `z build-ext` - do not edit"]
    foreach src $sources {
        set name [file rootname [file tail $src]]
        set dll  [P build $name.dll]
        set init [string totitle $name]
        puts "cc  [file tail $src] -> build/$name.dll"
        stream [gcc] -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
            -I$inc $src -o $dll -L$lib -ltclstub -static-libgcc \
            -luser32 -lgdi32 -lcomctl32 -lshell32
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
        error "static tclsh missing in zmal's Tcl/Tk payload (r/tcltk/9.0.3/tcl9s/bin)"
    }
    set out [lindex $args 0] ; if {$out eq ""} { set out [P dist els.exe] }
    if {[string match -* $out]} { error "z build takes no flags (got '$out'); usage: z build ?outfile?" }
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
    puts "cc  els_main.c + icudet.c + winfs.c + windrop.c"
    stream [gcc] -std=c23 -O2 -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
        -DELS_STATIC_ICUDET -DELS_STATIC_WINFS -DELS_STATIC_WINDROP \
        -ffunction-sections -fdata-sections \
        -c [P src els_main.c] -o [P build els_main.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src icudet.c] -o [P build icudet.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src winfs.c] -o [P build winfs.o] -I$inc
    stream [gcc] -std=c23 -O2 -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
        -c [P src windrop.c] -o [P build windrop.o] -I$inc
    puts "ld  -> build/els-bare.exe"
    set bare [P build els-bare.exe]
    stream [gcc] -municode -mwindows -static-libgcc -Wl,--gc-sections \
        [P build els_main.o] [P build icudet.o] [P build winfs.o] [P build windrop.o] [P build els.res] \
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
    puts stderr "els tasks: unknown command '$cmd' (try: z tasks)"
    exit 2
}
if {[catch {$proc {*}[lrange $argv 1 end]} err opts]} {
    set ec [dict get $opts -errorcode]
    if {[lindex $ec 0] eq "STREAM" && [lindex $ec 1] eq "CHILD"} {
        exit [lindex $ec 2]
    }
    puts stderr "z $cmd: $err"
    exit 1
}
