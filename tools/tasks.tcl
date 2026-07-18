#!/usr/bin/env tclsh
# tools/tasks.tcl - the internal els task runner behind z.json. ALL project tooling
# lives here (Tcl), plus C built by z's vendored UCRT64 gcc. It is invoked
# through z.exe, which discovers the project root and command manifest.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

# els is a hosted z project: it builds against z's SHARED runtime payloads
# under <z>/.z/r (Tcl/Tk 9, MSYS2 UCRT64 gcc, twapi) and carries no private
# .toolchain.  z.exe starts this script with z's tclsh90 and exports Z_HOME;
# the discovery below resolves each payload from the Z_* env vars or the hosted
# layout, so the script also works when run directly with the vendored tclsh.
proc zmal_paths {root args} {
    set out {}
    if {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne ""} {
        lappend out [file join $::env(Z_HOME) {*}$args]
    } elseif {[info exists ::env(Z_ROOT)] && $::env(Z_ROOT) ne ""} {
        lappend out [file join $::env(Z_ROOT) .z {*}$args]
    }
    # Hosted layout: <z>/_els, so the z workspace root is the project parent.
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
set ::env(Z_TCLTK) [file nativename $TC]
set ::env(Z_MSYS2) [file nativename $MSYS2]
set ::env(Z_TWAPI) [file nativename $TWAPI]
source [file join $ROOT tools release_notices.tcl]

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

# z runtime wins on PATH: Tcl/Tk 9 BEFORE MSYS2, which ships its own Tcl/Tk 8.6
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
proc sha256-exe {} { return [MSYSp usr bin sha256sum.exe] }

proc path_key {path} {
    set path [string map {\\ /} [file normalize $path]]
    if {$::tcl_platform(platform) eq "windows"} { set path [string tolower $path] }
    return [string trimright $path /]
}
proc same_path {a b} { return [expr {[path_key $a] eq [path_key $b]}] }
proc path_beneath {path parent} {
    set path [path_key $path]
    set parent [path_key $parent]
    return [expr {[string first "$parent/" "$path/"] == 0 && $path ne $parent}]
}
proc path_type {path} {
    if {[catch {set st [file lstat $path]} err opts]} {
        if {![file exists $path]} { return missing }
        return -options $opts $err
    }
    return [dict get $st type]
}
proc require_regular_or_absent {path label} {
    set type [path_type $path]
    if {$type ni {missing file}} {
        error "$label must be absent or a regular file (found $type): $path"
    }
    return $type
}
proc require_regular_file {path label} {
    set type [path_type $path]
    if {$type ne "file"} { error "$label must be a regular file (found $type): $path" }
    return $path
}
proc delete_regular_if_present {path} {
    set type [path_type $path]
    if {$type eq "missing"} { return }
    if {$type ne "file"} { error "refusing to delete non-regular tooling path ($type): $path" }
    file delete -- $path
}
proc ensure_real_directory {path label} {
    set type [path_type $path]
    if {$type eq "missing"} {
        file mkdir $path
        set type [path_type $path]
    }
    if {$type ne "directory"} {
        error "$label must be a real directory, not $type: $path"
    }
    return [file normalize $path]
}

proc directory_children {path} {
    set paths [glob -nocomplain -directory $path *]
    lappend paths {*}[glob -nocomplain -types hidden -directory $path *]
    return [lsort -dictionary -unique $paths]
}

proc require_direct_child {path parent label} {
    set path [file normalize $path]
    set parent [file normalize $parent]
    if {![path_beneath $path $parent] || ![same_path [file dirname $path] $parent]} {
        error "$label must be a direct child of $parent: $path"
    }
    return $path
}

# Fixed release-check output is intentionally reusable so `z sign` can consume
# a previously validated unsigned artifact.  It is not a general scratch
# directory: reject all unexpected names and non-regular members before removing
# the exact previous three-file release set.
proc prepare_exact_release_directory {dir label} {
    set type [path_type $dir]
    if {$type eq "missing"} {
        file mkdir $dir
        set type [path_type $dir]
    }
    if {$type ne "directory"} {
        error "$label must be a real directory, not $type: $dir"
    }
    set allowed {els-unsigned.exe els-unsigned.exe.sha256 els-unsigned.exe.provenance.txt}
    foreach path [directory_children $dir] {
        set tail [file tail $path]
        if {$tail ni $allowed} {
            error "$label contains unexpected member '$tail'; inspect it manually: $dir"
        }
        delete_regular_if_present $path
    }
    return $dir
}
proc prepare_release_check_directory {} {
    set root [ensure_real_directory [P build] "release build root"]
    set dir [require_direct_child [file join $root release-check] $root "release-check directory"]
    return [prepare_exact_release_directory $dir "release-check directory"]
}

# Tcl 9's `file tempdir` asks the OS to create the directory, rather than first
# guessing a name and then trusting it.  Every external writer (gcc, windres,
# zipfs) is pointed only below one of these freshly-created directories.  A
# pre-planted symlink or hardlink at a traditional build filename can therefore
# never be opened with truncation semantics.
proc unique_stage_directory {parent prefix} {
    set parent [ensure_real_directory $parent "stage parent"]
    set stage [file tempdir [file join $parent $prefix]]
    set stage [file normalize $stage]
    if {![path_beneath $stage $parent]} {
        error "temporary stage escaped its parent: $stage"
    }
    if {[path_type $stage] ne "directory"} { error "temporary stage is not a real directory: $stage" }
    return $stage
}

proc remove_real_tree {path} {
    set type [path_type $path]
    if {$type eq "missing"} { return }
    if {$type ne "directory"} {
        error "refusing to recursively remove non-directory tooling path ($type): $path"
    }
    file delete -force -- $path
}

proc place_regular_file {source destination {label "build output"}} {
    require_regular_file $source $label
    ensure_real_directory [file dirname $destination] "$label directory"
    require_regular_or_absent $destination $label
    file rename -force -- $source $destination
    require_regular_file $destination "placed $label"
    return $destination
}

proc validate_build_output {path} {
    set path [file normalize $path]
    if {![string equal -nocase [file extension $path] .exe]} {
        error "build output must end in .exe: $path"
    }
    if {![path_beneath $path [P build]]} {
        error "development builds are confined to [P build] (got $path)"
    }
    set rel [string range [path_key $path] [expr {[string length [path_key [P build]]] + 1}] end]
    set first [lindex [split $rel /] 0]
    if {$first in {release-check release-sign release-reproduce native-startup-check} ||
        [string match _* $first] || [string match .els-* $first]} {
        error "development output uses a release-tooling-reserved build directory: $path"
    }
    return $path
}
proc validate_sign_input {path} {
    set path [file normalize $path]
    set allowed [list [P dist els-unsigned.exe] [P build release-check els-unsigned.exe]]
    foreach candidate $allowed { if {[same_path $path $candidate]} { return $path } }
    error "sign input must be dist/els-unsigned.exe or build/release-check/els-unsigned.exe"
}

# All public tasks that mutate or consume shared build/release state serialize
# through one fail-closed presence lock.  A crashed process deliberately leaves
# a stale lock: after confirming no task still runs, the operator removes it.
set ::tool_lock_path ""
set ::tool_lock_token ""
set ::tool_lock_channel ""
proc read_small_text {path} {
    set fh [open $path r]
    try {
        fconfigure $fh -encoding utf-8 -profile strict -translation lf
        return [read $fh]
    } finally {
        close $fh
    }
}
proc acquire_tool_lock {task {path ""}} {
    if {$::tool_lock_token ne ""} { error "this process already holds the els tooling lock" }
    ensure_real_directory [P build] "tooling build root"
    if {$path eq ""} {
        set path [require_direct_child [P build .els-tooling.lock] [P build] "tooling lock"]
    }
    set path [file normalize $path]
    ensure_real_directory [file dirname $path] "tooling lock directory"
    set existingType [path_type $path]
    if {$existingType ni {missing file}} {
        error "tooling lock path must be absent or a regular file (found $existingType): $path"
    }
    set token "[pid]-[clock microseconds]-[clock clicks]"
    if {[catch {open $path {RDWR CREAT EXCL}} fh]} {
        set owner "unreadable owner data"
        catch { set owner [string trim [read_small_text $path]] }
        error "another els build/release task holds $path\n  $owner\nIf this is stale, first confirm no els z task is running, then delete the lock manually."
    }
    fconfigure $fh -encoding utf-8 -translation lf -buffering none
    puts $fh [list token $token task $task pid [pid] \
        started_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]]
    flush $fh
    set ::tool_lock_path $path
    set ::tool_lock_token $token
    set ::tool_lock_channel $fh
    return $token
}
proc release_tool_lock {} {
    set path $::tool_lock_path
    set token $::tool_lock_token
    set fh $::tool_lock_channel
    set ::tool_lock_path ""
    set ::tool_lock_token ""
    set ::tool_lock_channel ""
    if {$fh eq ""} { return }
    set owner ""
    catch {
        seek $fh 0
        set owner [string trim [read $fh]]
    }
    catch {close $fh}
    if {$path eq "" || $token eq "" || [path_type $path] ne "file"} { return }
    if {[catch {dict get $owner token} actual] || $actual ne $token} { return }
    # Re-read the visible name after closing the held handle.  Cooperative
    # contenders cannot replace/delete it while the channel is open on Windows;
    # this final token comparison also refuses to delete a manually substituted
    # file in the narrow close/delete interval.
    set visible ""
    if {[catch {set visible [string trim [read_small_text $path]]}]} { return }
    if {[catch {dict get $visible token} actual] || $actual ne $token} { return }
    file delete -- $path
}
proc task_uses_tool_lock {task} {
    return [expr {$task in {
        build build-ext native-startup-check release-check sign test stress
        probe-exe shot readme-shots icon toolcheck run
    }}]
}

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
        windres { return [windres] }
        strip { return [strip-exe] }
        sha256 { return [sha256-exe] }
        twapi { return [TWAPIp pkgIndex.tcl] }
        default { return "" }
    }
}
proc need {args} {
    foreach tool $args {
        set p [tool_path $tool]
        if {$p eq "" || ![file exists $p]} {
            error "required tool '$tool' is missing - restore z's runtime payloads (r/tcltk, r/msys2, r/twapi)"
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
  z shot <out> [file]   screenshot the editor on a private, never-switched desktop
  z readme-shots        regenerate four README shots on private desktops
  z build [out]         development build of the native exe -> build/els-dev.exe;
                        custom outputs must remain under build/ and end in .exe
  z release-check [opts] fail-closed clean build/test/probe -> dist/els-unsigned.exe;
                        --no-promote keeps it in build/, --allow-dirty implies that
  z sign [in]           sign a release-check artifact, verify identity, re-probe,
                        then promote to the fixed dist/els.exe release path
                        publisher is source-pinned; ELS_SIGN_CERT_SHA1 may pin the leaf
  z probe-exe [exe]     verify the fused exe's startup and session-restore behavior
  z pecheck [mode] [exe] verify AMD64/GUI/mitigations/manifest/certificate policy;
                        mode is --unsigned (default) or --signed
  z build-ext           compile the C23 extension(s) in src/ -> build/*.dll
  z native-startup-check build a test-only packaged exe and prove native init
                        failures stop before main.tcl without showing UI
  z check [--deep]      check z's runtime payloads (r/tcltk, r/msys2, r/twapi)
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
    if {[llength $args] > 1} { error "usage: z probe-exe ?executable?" }
    ensure_native_support
    set exe [lindex $args 0]
    if {$exe eq ""} { set exe [P dist els.exe] }
    stream [tclsh] [P tools probe_exe.tcl] $exe
}

proc task_pecheck {args} {
    need tclsh
    # A mode-only invocation (as `z pecheck [mode] [exe]` implies both are optional)
    # gets the matching default artifact instead of failing pecheck.tcl's usage:
    # --signed -> the fixed signed release path, --unsigned/bare -> the unsigned one (R41).
    if {![llength $args]} {
        set args [list --unsigned [P dist els-unsigned.exe]]
    } elseif {[llength $args] == 1 && [lindex $args 0] eq "--signed"} {
        set args [list --signed [P dist els.exe]]
    } elseif {[llength $args] == 1 && [lindex $args 0] eq "--unsigned"} {
        set args [list --unsigned [P dist els-unsigned.exe]]
    }
    stream [tclsh] [P tools pecheck.tcl] {*}$args
}

# find_signtool locates signtool.exe only in trusted SDK locations.  A PATH
# fallback would let a shim forge both signing and verification output.
proc find_signtool {} {
    set sdk [lsort [glob -nocomplain {C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe}]]
    if {[llength $sdk]} { return [lindex $sdk end] }
    set zhome [expr {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne "" ? $::env(Z_HOME) : [file join [file dirname $::ROOT] .z]}]
    set j [file join $zhome r winsdk 10.0.26100.0 signtool.exe]
    if {[file exists $j]} { return $j }
    error "trusted signtool.exe not found - restore z's winsdk payload or install the Windows SDK Signing Tools"
}

# run_capture runs a command capturing BOTH stdout and stderr into one string, and
# returns [list exitcode text]. (Plain exec drops stderr, where signtool writes its
# "No certificates" message; and it must not treat stderr output as an error.)
proc run_capture {args} {
    set ch [file tempfile tmp]
    set rc [catch {exec {*}$args >@ $ch 2>@ $ch} err opts]
    close $ch
    set f [open $tmp r]
    try {
        fconfigure $f -profile replace
        set text [read $f]
    } finally {
        close $f
        file delete -- $tmp
    }
    if {$rc} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} { return [list [lindex $ec 2] $text] }
        return [list 1 [string trim "$text\n$err"]]
    }
    return [list 0 $text]
}

proc sha256_file {path} {
    if {![file isfile $path]} { error "cannot hash missing file: $path" }
    set tool [sha256-exe]
    if {![file isfile $tool]} { error "trusted z sha256sum is missing: $tool" }
    lassign [run_capture $tool --binary -- [file normalize $path]] rc out
    if {$rc != 0} { error "sha256sum failed for $path:\n$out" }
    if {![regexp -nocase {^([0-9a-f]{64})\s+\*?} $out -> hash]} {
        error "sha256sum returned no SHA-256 for $path"
    }
    return [string tolower $hash]
}

proc normalize_sha1 {value {label "ELS_SIGN_CERT_SHA1"}} {
    set value [string toupper [string map {" " "" ":" "" "-" ""} [string trim $value]]]
    if {$value ne "" && ![regexp {^[0-9A-F]{40}$} $value]} {
        # $label names the real source of the value so an unparseable signtool hash
        # line is not misattributed to the operator's pin env var (R43).
        error "$label must be exactly 40 hexadecimal digits"
    }
    return $value
}

# The publisher name is source policy, not operator input: an environment variable
# must never be able to authorize a different identity.  ELS_SIGN_CERT_SHA1 may
# tighten a release to one exact leaf certificate; changing publisher requires a
# reviewed source edit.
proc signing_identity {} {
    set subject "Open Source Developer Vincent Vercauteren"
    set sha1 ""
    if {[info exists ::env(ELS_SIGN_CERT_SHA1)]} { set sha1 [normalize_sha1 $::env(ELS_SIGN_CERT_SHA1)] }
    return [dict create subject $subject sha1 $sha1]
}

proc signing_select_args {identity} {
    set sha1 [dict get $identity sha1]
    if {$sha1 ne ""} { return [list /sha1 $sha1] }
    return [list /n [dict get $identity subject]]
}

proc verify_signed_identity {signtool exe identity} {
    lassign [run_capture $signtool verify /pa /all /v $exe] rc out
    if {$rc != 0} { error "signature verify FAILED:\n$out" }

    # The final certificate before the timestamp section is the leaf signing
    # certificate.  Parsing that bounded section avoids accepting a matching CA or
    # timestamp certificate elsewhere in /v output.
    set leafSubject ""
    set leafSha1 ""
    set timestamped 0
    set timestampVerified 0
    foreach line [split $out \n] {
        if {[regexp -nocase {^\s*The signature is timestamped:} $line]} {
            set timestamped 1
            continue
        }
        if {[regexp -nocase {^\s*Timestamp Verified by:} $line]} {
            set timestampVerified 1
            break
        }
        if {$timestamped} continue
        if {[regexp -nocase {^\s*Issued to:\s*(.*?)\s*$} $line -> value]} {
            set leafSubject $value
            set leafSha1 ""
        } elseif {[regexp -nocase {^\s*SHA1 hash:\s*([0-9A-Fa-f :\-]+)\s*$} $line -> value]} {
            if {$leafSubject ne ""} { set leafSha1 [normalize_sha1 $value "signtool SHA1 hash output"] }
        }
    }
    if {!$timestamped || !$timestampVerified} {
        error "signature is valid but a verified RFC3161 timestamp was not found"
    }
    if {$leafSubject eq "" || $leafSha1 eq ""} {
        error "could not identify the leaf signing certificate in signtool output"
    }
    set expectedSubject [dict get $identity subject]
    if {$expectedSubject ne "" && ![string equal -nocase $leafSubject $expectedSubject]} {
        error "wrong signer: got '$leafSubject', expected '$expectedSubject'"
    }
    set expectedSha1 [dict get $identity sha1]
    if {$expectedSha1 ne "" && $leafSha1 ne $expectedSha1} {
        error "wrong signer thumbprint: got $leafSha1, expected $expectedSha1"
    }
    return [dict create subject $leafSubject sha1 $leafSha1 timestamped 1]
}

proc copy_verified_sign_input {input candidate unsignedMeta} {
    require_regular_file $input "verified unsigned signing input"
    require_regular_or_absent $candidate "signing candidate"
    file copy -- $input $candidate
    require_regular_file $candidate "copied signing candidate"
    if {[file size $candidate] != [dict get $unsignedMeta artifact_bytes] ||
        [sha256_file $candidate] ne [dict get $unsignedMeta artifact_sha256]} {
        catch {delete_regular_if_present $candidate}
        error "copied signing candidate does not exactly match the verified unsigned input"
    }
    return $candidate
}

# task_sign - sign only a release-check artifact.  The input is copied to build/
# and the final dist artifact is replaced only after signature identity, timestamp,
# PE policy and the real-process probe all pass.
#   z sign [input]
proc task_sign {args} {
    assert_trusted_release_payloads
    activate_release_environment
    need tclsh sha256
    if {[llength $args] > 1} { error "usage: z sign ?input.exe?" }
    assert_release_git_inputs 0
    set sourceStart [release_source_state]
    if {[dict get $sourceStart dirty]} {
        error "refusing to sign from a dirty source tree:\n[dict get $sourceStart status]"
    }
    set signtool [find_signtool]
    set input [lindex $args 0]
    if {$input eq ""} { set input [P dist els-unsigned.exe] }
    set input [validate_sign_input $input]
    set output [P dist els.exe]
    if {![file isfile $input]} {
        error "unsigned release artifact not found: $input\nrun `z release-check` first"
    }
    set identity [signing_identity]
    set unsignedBasic [verify_release_set_basic $input]
    set unsignedHash [dict get $unsignedBasic artifact_sha256]
    set inputFingerprints [release_fingerprints]
    puts "input:    $input"
    puts "output:   $output"
    puts "signtool: $signtool"
    puts "signer:   [dict get $identity subject][expr {[dict get $identity sha1] ne {} ? " ([dict get $identity sha1])" : {}}]"

    recover_release_promotion $output
    set reproduceDir ""
    set reproduceInfo ""
    set signDir ""
    try {
        puts "\n== clean reproducible rebuild =="
        set reproduceDir [unique_stage_directory [P build] _release-reproduce]
        set reproduced [file join $reproduceDir els-unsigned.exe]
        set reproduceInfo [build_native_product $reproduced]
        verify_packaged_payload $reproduced
        stream [tclsh] [P tools pecheck.tcl] --unsigned \
            --manifest [dict get $reproduceInfo manifest] --version [els_version] $reproduced
        set unsignedMeta [read_verified_unsigned_metadata $input $reproduceInfo]
        if {[sha256_file $reproduced] ne $unsignedHash} {
            error "clean rebuild is not byte-for-byte reproducible with the release-check artifact"
        }
        if {[sha256_file $input] ne $unsignedHash} {
            error "unsigned input changed while its reproducible rebuild was running"
        }
        set preparedSubject [dict get $unsignedMeta signing_subject_expected]
        if {![string equal -nocase $preparedSubject [dict get $identity subject]]} {
            error "signer policy changed since release-check: artifact expects '$preparedSubject'"
        }
        set preparedSha1 [dict get $unsignedMeta signing_sha1_expected]
        if {$preparedSha1 ne "" && $preparedSha1 ne [dict get $identity sha1]} {
            error "signer thumbprint changed since release-check: artifact expects $preparedSha1"
        }
        if {![same_release_source_snapshot $sourceStart [release_source_state]] ||
            ![same_fingerprints $inputFingerprints [release_fingerprints]]} {
            error "source, Git index, or release dependencies changed during the reproducible rebuild"
        }

        set signDir [unique_stage_directory [P build] _release-sign]
        set candidate [file join $signDir els.exe]
        copy_verified_sign_input $input $candidate $unsignedMeta
        stream [tclsh] [P tools pecheck.tcl] --unsigned \
            --manifest [dict get $reproduceInfo manifest] --version [els_version] $candidate

        set timestampUrl [expr {[info exists ::env(ELS_TIMESTAMP_URL)] && $::env(ELS_TIMESTAMP_URL) ne "" \
            ? $::env(ELS_TIMESTAMP_URL) : "http://time.certum.pl"}]
        set selectArgs [signing_select_args $identity]
        puts "signing (a PIN dialog may pop from SimplySign Desktop on the first sign)..."
        lassign [run_capture $signtool sign {*}$selectArgs /tr $timestampUrl \
            /td sha256 /fd sha256 /v $candidate] rc out
        puts [string trim $out]
        if {$rc != 0} {
            if {[string match {*No certificates were found*} $out]} {
                error "no code-signing certificate found - SimplySign is not connected.\n  -> Open SimplySign Desktop, tray icon -> Connect to SimplySign\n     (your SimplySign e-mail + the 6-digit phone token), then re-run.\n     Refusing to emit an unsigned binary."
            }
            error "signtool sign failed (exit $rc)"
        }

        set signedInfo [verify_signed_identity $signtool $candidate $identity]
        stream [tclsh] [P tools pecheck.tcl] --signed \
            --manifest [dict get $reproduceInfo manifest] --version [els_version] $candidate
        puts "probe: confirming the signed exe still mounts its zipfs + runs..."
        if {[catch {stream [tclsh] [P tools probe_exe.tcl] $candidate} perr]} {
            error "the SIGNED exe FAILED the probe - refusing to ship a broken binary:\n  $perr"
        }
        if {[sha256_file $input] ne $unsignedHash ||
            ![same_release_source_snapshot $sourceStart [release_source_state]] ||
            ![same_fingerprints $inputFingerprints [release_fingerprints]]} {
            error "unsigned input, source, Git index, or release dependencies changed while signing"
        }

        set signedMeta [signed_release_metadata $candidate $unsignedMeta $signedInfo]
        set signedMeta [write_release_metadata $candidate $signedMeta]
        set signedMeta [validate_signed_metadata $candidate \
            [verify_release_set_basic $candidate] $unsignedMeta $signedInfo]
        assert_exact_release_stage $candidate
        promote_release_set $candidate $output
        set sum [dict get $signedMeta artifact_sha256]
        puts ""
        puts "OK - reproducibly rebuilt, signed, identity-verified, timestamped, probed and promoted."
        puts "  file       $output"
        puts "  sha256     $sum"
        puts "  provenance $output.provenance.txt"
    } finally {
        if {$reproduceInfo ne "" && [dict exists $reproduceInfo stage]} {
            remove_real_tree [dict get $reproduceInfo stage]
        }
        if {$reproduceDir ne ""} { remove_real_tree $reproduceDir }
        if {$signDir ne ""} { remove_real_tree $signDir }
    }
}

# ---- release metadata and fail-closed promotion ------------------------------
proc git_exe {} {
    set git [MSYSp usr bin git.exe]
    if {![file isfile $git]} { error "trusted z git is required for release provenance" }
    return $git
}

proc release_override_variables {} {
    return {
        GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
        GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
        CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
        LIBRARY_PATH COMPILER_PATH GCC_EXEC_PREFIX
        CFLAGS CPPFLAGS LDFLAGS LIB INCLUDE SDKROOT CC CXX GCC_SPECS SPECS
        COLLECT_GCC_OPTIONS GCC_COMPARE_DEBUG DEPENDENCIES_OUTPUT
        SUNPRO_DEPENDENCIES SOURCE_DATE_EPOCH
    }
}

proc assert_release_environment {} {
    set found {}
    foreach name [release_override_variables] {
        if {[info exists ::env($name)] && $::env($name) ne ""} { lappend found $name }
    }
    # GIT_CONFIG_KEY_n/VALUE_n can extend beyond zero; reject the whole family.
    foreach name [array names ::env GIT_CONFIG_*] {
        if {$name ni {GIT_CONFIG_NOSYSTEM} && $::env($name) ne ""} { lappend found $name }
    }
    if {[llength $found]} {
        error "release environment contains repository/compiler overrides: [join [lsort -unique $found] {, }]"
    }
}

proc assert_trusted_release_payloads {} {
    set zhome [expr {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne "" \
        ? [file normalize $::env(Z_HOME)] : [file normalize [file join [file dirname $::ROOT] .z]]}]
    foreach {label actual relative} [list \
            Tcl/Tk $::TC {r tcltk 9.0.4} \
            MSYS2 $::MSYS2 {r msys2} \
            TWAPI $::TWAPI {r twapi 5.2.0}] {
        set expected [file normalize [file join $zhome {*}$relative]]
        if {![same_path $actual $expected] || [path_type $expected] ne "directory"} {
            error "$label release payload must be z's fixed $expected (resolved $actual)"
        }
    }
}

proc activate_release_environment {} {
    assert_release_environment
    foreach name [release_override_variables] { catch {unset ::env($name)} }
    foreach name [array names ::env GIT_*] { catch {unset ::env($name)} }
    set ::env(GIT_CONFIG_NOSYSTEM) 1
    set ::env(GIT_TERMINAL_PROMPT) 0
    set ::env(GIT_OPTIONAL_LOCKS) 0
    set bins [list \
        [file nativename [TCp tcl9 bin]] \
        [file nativename [MSYSp ucrt64 bin]] \
        [file nativename [MSYSp usr bin]]]
    if {[info exists ::env(SystemRoot)] && $::env(SystemRoot) ne ""} {
        lappend bins \
            [file nativename [file join $::env(SystemRoot) System32 WindowsPowerShell v1.0]] \
            [file nativename [file join $::env(SystemRoot) System32]] \
            [file nativename $::env(SystemRoot)]
    }
    set ordered {}
    foreach bin $bins { if {$bin ni $ordered} { lappend ordered $bin } }
    set ::env(PATH) [join $ordered {;}]
    # Rebuild the only Tcl search variables children may inherit from trusted
    # payloads.  Host/user package paths are intentionally excluded.
    set ::env(TCL_LIBRARY) [file nativename [TCp tcllib tcl_library]]
    set ::env(TK_LIBRARY) [file nativename [TCp tcllib tk_library]]
    set ::env(TCLLIBPATH) [list [P tools tclpkg] $::TWAPI [P build]]
    set ::env(LANG) C
    set ::env(LC_ALL) C
}

proc git_capture_raw {args} {
    # Explicitly clear repository-routing variables even for ordinary helper
    # calls outside release-check.  This prevents a caller environment from
    # silently pointing provenance/package enumeration at a different index.
    set saved {}
    foreach name [array names ::env GIT_*] {
        dict set saved $name $::env($name)
        unset ::env($name)
    }
    set ::env(GIT_CONFIG_NOSYSTEM) 1
    set ::env(GIT_TERMINAL_PROMPT) 0
    set ::env(GIT_OPTIONAL_LOCKS) 0
    try {
        lassign [run_capture [git_exe] -C $::ROOT {*}$args] rc out
    } finally {
        foreach name [array names ::env GIT_*] { unset ::env($name) }
        dict for {name value} $saved { set ::env($name) $value }
    }
    if {$rc != 0} { error "git [join $args { }] failed:\n$out" }
    return $out
}
proc git_capture {args} {
    return [string trim [git_capture_raw {*}$args]]
}
proc normalize_relative_git_path {path} {
    # Avoid interpreting the /c/... spelling emitted by MSYS Git.  Release
    # provenance asks Git for paths relative to its explicit -C root, accepts
    # only that representation, and anchors it back inside the real root.
    set path [string trim $path]
    if {$path eq "" || [string first \x00 $path] >= 0} {
        error "Git returned an empty or invalid path"
    }
    if {[file pathtype $path] ne "relative"} {
        error "Git returned a non-relative path: $path"
    }
    set path [file normalize [file join $::ROOT $path]]
    if {![same_path $path $::ROOT] && ![path_beneath $path $::ROOT]} {
        error "Git path escaped the release root: $path"
    }
    return $path
}
proc tracked_resource_files {} {
    set raw [git_capture_raw ls-files -z -- resources]
    set files {}
    foreach rel [split $raw \x00] {
        if {$rel eq ""} continue
        set rel [string map {\\ /} $rel]
        if {![string match {resources/*} $rel]} {
            error "git returned an out-of-scope release resource: $rel"
        }
        set source [file join $::ROOT {*}[split $rel /]]
        require_regular_file $source "tracked release resource"
        lappend files $rel
    }
    return [lsort -dictionary -unique $files]
}

proc release_input_files {} {
    set files {
        els.tcl LICENSE z.json
        tools/genres.tcl tools/mkico.tcl tools/package.tcl tools/pecheck.tcl
        tools/probe_exe.tcl tools/release_notices.tcl tools/release_tests.tcl
        tools/release_tooling.test tools/tasks.tcl tools/toolcheck.tcl
        tools/native_check.tcl tools/native_startup_check.tcl
    }
    foreach dir {src tools/tclpkg} {
        foreach rel [release_tree_files [P $dir]] { lappend files "$dir/$rel" }
    }
    set testPaths [concat \
        [glob -nocomplain [P tests *.tcl]] [glob -nocomplain [P tests *.test]] \
        [glob -nocomplain -types hidden [P tests *.tcl]] \
        [glob -nocomplain -types hidden [P tests *.test]]]
    foreach path [lsort -dictionary -unique $testPaths] {
        if {[path_type $path] ne "file"} { error "test release input is not a regular file: $path" }
        lappend files "tests/[file tail $path]"
    }
    # Only tracked resources enter the package, by design.  Untracked artwork
    # therefore cannot alter a release even in --allow-dirty diagnostic mode.
    lappend files {*}[tracked_resource_files]
    set normalized {}
    foreach rel [lsort -dictionary -unique $files] {
        set rel [string map {\\ /} $rel]
        if {[file pathtype $rel] ne "relative" || [string match ../* $rel] ||
            [string first /../ "/$rel/"] >= 0} {
            error "release input escaped the project root: $rel"
        }
        require_regular_file [file join $::ROOT {*}[split $rel /]] "release input"
        lappend normalized $rel
    }
    if {![llength $normalized]} { error "release input inventory is empty" }
    return $normalized
}

proc assert_regular_git_index {} {
    set gitDir [normalize_relative_git_path \
        [git_capture rev-parse --path-format=relative --git-dir]]
    set expectedGitDir [file normalize [P .git]]
    if {![same_path $gitDir $expectedGitDir] || [path_type $gitDir] ne "directory"} {
        error "release Git directory must be the repository's real $expectedGitDir (resolved $gitDir)"
    }
    set indexPath [normalize_relative_git_path \
        [git_capture rev-parse --path-format=relative --git-path index]]
    if {![same_path $indexPath [file join $gitDir index]] || [path_type $indexPath] ne "file"} {
        error "release Git index must be the regular repository index: $indexPath"
    }
    set raw [git_capture_raw ls-files -v -z]
    set flagged {}
    foreach record [split $raw \x00] {
        if {$record eq ""} continue
        set tag [string index $record 0]
        set rel [string range $record 2 end]
        if {$tag eq "S" || [string is lower $tag]} {
            lappend flagged "$tag $rel"
        }
    }
    if {[llength $flagged]} {
        error "release inputs use skip-worktree/assume-unchanged index flags:\n[join $flagged \n]"
    }
}

proc git_index_entries {} {
    set raw [git_capture_raw ls-files -s -z]
    set entries {}
    foreach record [split $raw \x00] {
        if {$record eq ""} continue
        if {![regexp {^([0-7]{6}) ([0-9a-fA-F]{40,64}) ([0-3])\t(.+)$} $record -> mode object stage rel]} {
            error "Git returned a malformed index entry"
        }
        set rel [string map {\\ /} $rel]
        if {[dict exists $entries $rel]} { error "Git index contains duplicate/staged entry for $rel" }
        dict set entries $rel [dict create mode $mode object [string tolower $object] stage $stage]
    }
    return $entries
}

proc assert_release_git_inputs {{allowUntracked 0}} {
    set top [normalize_relative_git_path \
        [git_capture rev-parse --path-format=relative --show-toplevel]]
    if {![same_path $top $::ROOT]} {
        error "Git top-level is $top, expected $::ROOT"
    }
    if {[git_capture rev-parse --is-inside-work-tree] ne "true"} {
        error "release root is not a Git working tree"
    }
    assert_regular_git_index
    set entries [git_index_entries]
    set missing {}
    foreach rel [release_input_files] {
        if {![dict exists $entries $rel]} {
            lappend missing $rel
            continue
        }
        set entry [dict get $entries $rel]
        if {[dict get $entry stage] ne "0" || [dict get $entry mode] ni {100644 100755}} {
            error "release input has unsupported Git index mode/stage: $rel"
        }
    }
    if {[llength $missing] && !$allowUntracked} {
        error "release inputs are not tracked by Git:\n[join $missing \n]"
    }
    if {[llength $missing]} {
        puts "note: --allow-dirty includes untracked release inputs in the fingerprint: [join $missing {, }]"
    }
    return [sha256_bytes [git_capture_raw ls-files -s -z]]
}
proc release_tree_files {root {relative ""}} {
    set dir [expr {$relative eq "" ? $root : [file join $root {*}[split $relative /]]}]
    if {![file isdirectory $dir]} { error "release payload directory is missing: $dir" }
    set files {}
    set tails [glob -nocomplain -tails -directory $dir *]
    lappend tails {*}[glob -nocomplain -tails -types hidden -directory $dir *]
    foreach tail [lsort -dictionary -unique $tails] {
        set child [expr {$relative eq "" ? $tail : "$relative/$tail"}]
        set path [file join $root {*}[split $child /]]
        set type [path_type $path]
        if {$type eq "directory"} {
            lappend files {*}[release_tree_files $root $child]
        } elseif {$type eq "file"} {
            lappend files $child
        } else {
            error "release payload tree contains unsupported $type entry: $path"
        }
    }
    return $files
}
proc sha256_bytes {bytes} {
    set fh [file tempfile path]
    try {
        fconfigure $fh -translation binary
        puts -nonewline $fh $bytes
    } finally {
        close $fh
    }
    try {
        return [sha256_file $path]
    } finally {
        file delete -- $path
    }
}
proc sha256_file_batch {paths} {
    if {![llength $paths]} { return {} }
    lassign [run_capture [sha256-exe] --binary --zero -- {*}$paths] rc raw
    if {$rc != 0} { error "sha256sum failed for a release input batch:\n$raw" }
    set records [split $raw \x00]
    if {[lindex $records end] eq ""} { set records [lrange $records 0 end-1] }
    if {[llength $records] != [llength $paths]} {
        error "sha256sum returned [llength $records] records for [llength $paths] release inputs"
    }
    set hashes {}
    foreach record $records {
        if {![regexp -nocase {^([0-9a-f]{64}) [ *]} $record -> hash]} {
            error "sha256sum returned a malformed zero-delimited record"
        }
        lappend hashes [string tolower $hash]
    }
    return $hashes
}
proc release_files_sha256 {root files} {
    set manifest "els-release-file-set-v2\n"
    set batchPaths {}
    set batchNames {}
    set batchChars 0
    foreach relative $files {
        set relative [string map {\\ /} $relative]
        set path [file normalize [file join $root {*}[split $relative /]]]
        require_regular_file $path "release payload source"
        set chars [string length $path]
        if {[llength $batchPaths] && ($batchChars + $chars > 16000 || [llength $batchPaths] >= 200)} {
            foreach name $batchNames hash [sha256_file_batch $batchPaths] {
                set nameBytes [encoding convertto -profile strict utf-8 $name]
                append manifest [string length $nameBytes] ":$hash\n" $nameBytes
            }
            set batchPaths {}; set batchNames {}; set batchChars 0
        }
        lappend batchPaths $path
        lappend batchNames $relative
        incr batchChars [expr {$chars + 3}]
    }
    foreach name $batchNames hash [sha256_file_batch $batchPaths] {
        set nameBytes [encoding convertto -profile strict utf-8 $name]
        append manifest [string length $nameBytes] ":$hash\n" $nameBytes
    }
    return [sha256_bytes $manifest]
}
proc release_tree_sha256 {root} {
    return [release_files_sha256 $root [release_tree_files $root]]
}
proc release_source_state {} {
    set commit [git_capture rev-parse HEAD]
    set describe [git_capture describe --always --dirty --tags]
    set status [git_capture status --porcelain=v1 --untracked-files=all]
    set indexSha256 [sha256_bytes [git_capture_raw ls-files -s -z]]
    return [dict create commit $commit describe $describe dirty [expr {$status ne ""}] \
        status $status index_sha256 $indexSha256]
}
proc same_release_source_snapshot {a b} {
    foreach key {commit status index_sha256} {
        if {[dict get $a $key] ne [dict get $b $key]} { return 0 }
    }
    return 1
}
proc els_version {} {
    set fh [open [P els.tcl] r]
    try { set source [read $fh] } finally { close $fh }
    if {![regexp {variable\s+version\s+"([^"]+)"} $source -> version]} {
        error "cannot read els version from els.tcl"
    }
    return $version
}
proc command_version {command args} {
    lassign [run_capture $command {*}$args] rc out
    if {$rc != 0} { error "cannot read version from $command:\n$out" }
    return [string trim $out]
}
proc gcc_file {option name} {
    set reported [command_version [gcc] $option]
    if {$reported eq "" || $reported eq $name} {
        error "gcc could not resolve release dependency $name"
    }
    if {[file pathtype $reported] ne "absolute"} {
        set reported [file join [file dirname [gcc]] $reported]
    }
    set reported [file normalize $reported]
    if {![file isfile $reported]} { error "gcc release dependency is missing: $reported" }
    return $reported
}
proc gcc_directory {option name} {
    set reported [command_version [gcc] $option]
    if {$reported eq "" || $reported eq $name} {
        error "gcc could not resolve release directory $name"
    }
    if {[file pathtype $reported] ne "absolute"} {
        set reported [file join [file dirname [gcc]] $reported]
    }
    set reported [file normalize $reported]
    if {![file isdirectory $reported]} { error "gcc release directory is missing: $reported" }
    return $reported
}
proc release_fingerprints {} {
    set files [list \
        dependency.tclsh90.sha256       [tclsh] \
        dependency.tclsh90s.sha256      [tclshs] \
        dependency.wish90s.sha256       [TCp tcl9s bin wish90s.exe] \
        dependency.libtcl90.sha256      [TCp tcl9s lib libtcl90.a] \
        dependency.libtcl9tk90.sha256   [TCp tcl9s lib libtcl9tk90.a] \
        dependency.libtclstub.sha256    [TCp tcl9s lib libtclstub.a] \
        dependency.twapi-index.sha256   [TWAPIp pkgIndex.tcl] \
        dependency.libgcc.sha256        [gcc_file -print-libgcc-file-name libgcc.a] \
        dependency.libgcc-eh.sha256     [gcc_file -print-file-name=libgcc_eh.a libgcc_eh.a] \
        dependency.crt2u.sha256         [gcc_file -print-file-name=crt2u.o crt2u.o] \
        dependency.crtbegin.sha256      [gcc_file -print-file-name=crtbegin.o crtbegin.o] \
        dependency.crtend.sha256        [gcc_file -print-file-name=crtend.o crtend.o] \
        dependency.default-manifest.sha256 [gcc_file -print-file-name=default-manifest.o default-manifest.o] \
        dependency.libmingw32.sha256    [gcc_file -print-file-name=libmingw32.a libmingw32.a] \
        dependency.libmingwex.sha256    [gcc_file -print-file-name=libmingwex.a libmingwex.a] \
        dependency.libmoldname.sha256   [gcc_file -print-file-name=libmoldname.a libmoldname.a] \
        dependency.libmsvcrt.sha256     [gcc_file -print-file-name=libmsvcrt.a libmsvcrt.a] \
        dependency.libucrtbase.sha256   [gcc_file -print-file-name=libucrtbase.a libucrtbase.a] \
        tool.gcc.sha256                 [gcc] \
        tool.cc1.sha256                 [gcc_file -print-prog-name=cc1 cc1] \
        tool.collect2.sha256            [gcc_file -print-prog-name=collect2 collect2] \
        tool.lto-wrapper.sha256         [gcc_file -print-prog-name=lto-wrapper lto-wrapper] \
        tool.lto-plugin.sha256          [gcc_file -print-file-name=liblto_plugin.dll liblto_plugin.dll] \
        tool.as.sha256                  [gcc_file -print-prog-name=as as] \
        tool.ld.sha256                  [gcc_file -print-prog-name=ld ld] \
        tool.windres.sha256             [windres] \
        tool.strip.sha256               [strip-exe] \
        tool.sha256sum.sha256           [sha256-exe] \
        tool.git.sha256                 [git_exe] \
        tool.signtool.sha256            [find_signtool]]
    foreach library {
        netapi32 kernel32 user32 advapi32 userenv ws2_32 gdi32 comdlg32 imm32
        comctl32 shell32 uuid ole32 oleaut32 winspool
    } {
        set filename "lib$library.a"
        lappend files "dependency.$filename.sha256" \
            [gcc_file "-print-file-name=$filename" $filename]
    }
    foreach {label path} [::elsrelease::notice_sources $::TC $::MSYS2] {
        set slug [string tolower $label]
        regsub -all {[^a-z0-9]+} $slug - slug
        set slug [string trim $slug -]
        set key "notice.$slug.sha256"
        lappend files $key $path
    }
    set out {}
    foreach {key path} $files {
        if {![file isfile $path]} { error "release dependency is missing: $path" }
        dict set out $key [sha256_file $path]
    }
    dict set out payload.tcl-library.sha256 \
        [release_tree_sha256 [TCp tcllib tcl_library]]
    dict set out payload.tk-library.sha256 \
        [release_tree_sha256 [TCp tcllib tk_library]]
    set resources [tracked_resource_files]
    dict set out payload.resources.sha256 [release_files_sha256 $::ROOT $resources]
    dict set out source.release-inputs.sha256 \
        [release_files_sha256 $::ROOT [release_input_files]]
    dict set out headers.tcltk.sha256 [release_tree_sha256 [TCp tcl9 include]]
    dict set out headers.mingw-w64.sha256 [release_tree_sha256 [MSYSp ucrt64 include]]
    dict set out headers.gcc.sha256 \
        [release_tree_sha256 [gcc_directory -print-file-name=include include]]
    dict set out headers.gcc-fixed.sha256 \
        [release_tree_sha256 [gcc_directory -print-file-name=include-fixed include-fixed]]
    return $out
}
proc clean_manifest_value {value} {
    return [string trim [string map [list \r " " \n " | " \t " "] $value]]
}
proc write_text_atomic {path text} {
    require_regular_or_absent $path "metadata destination"
    ensure_real_directory [file dirname $path] "metadata directory"
    set tmp "$path.new-[pid]"
    delete_regular_if_present $tmp
    set fh [open $tmp {WRONLY CREAT TRUNC}]
    try {
        fconfigure $fh -encoding utf-8 -translation lf
        puts -nonewline $fh $text
    } finally {
        close $fh
    }
    if {[catch {file rename -force -- $tmp $path} err]} {
        catch {delete_regular_if_present $tmp}
        error "cannot publish metadata $path: $err"
    }
}
proc write_manifest {path values} {
    set text ""
    foreach key [lsort -dictionary [dict keys $values]] {
        append text $key "\t" [clean_manifest_value [dict get $values $key]] "\n"
    }
    write_text_atomic $path $text
}
proc read_manifest {path} {
    require_regular_file $path "release metadata"
    set fh [open $path r]
    try { fconfigure $fh -encoding utf-8 -profile strict -translation lf; set text [read $fh] } finally { close $fh }
    set values {}
    foreach line [split $text \n] {
        if {$line eq ""} continue
        set tab [string first \t $line]
        if {$tab < 1} { error "malformed release metadata line in $path: $line" }
        set key [string range $line 0 [expr {$tab - 1}]]
        if {![regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $key]} {
            error "invalid release metadata key '$key' in $path"
        }
        if {[dict exists $values $key]} { error "duplicate release metadata key '$key' in $path" }
        dict set values $key [string range $line [expr {$tab + 1}] end]
    }
    return $values
}
proc unsigned_metadata_base_keys {} {
    return {
        format product product_version artifact_file artifact_bytes artifact_sha256
        artifact_signed built_utc source_commit source_describe source_dirty source_index_sha256
        tool.tcl_version tool.gcc_version signing_subject_expected
        signing_sha1_expected packaged_notices
        native.link-map.sha256 native.link-inputs.sha256 native.winpthread-linked
    }
}
proc require_exact_keys {values expected label} {
    set actual [lsort -dictionary [dict keys $values]]
    set expected [lsort -dictionary $expected]
    set missing {}; set extra {}
    foreach key $expected { if {$key ni $actual} { lappend missing $key } }
    foreach key $actual { if {$key ni $expected} { lappend extra $key } }
    if {[llength $missing] || [llength $extra]} {
        error "$label schema mismatch; missing={[join $missing {, }]}; extra={[join $extra {, }]}"
    }
}
proc native_build_evidence {buildInfo} {
    foreach key {link_map_sha256 link_inputs_sha256 map} {
        if {![dict exists $buildInfo $key]} { error "native build evidence lacks '$key'" }
    }
    foreach key {link_map_sha256 link_inputs_sha256} {
        if {![regexp {^[0-9a-f]{64}$} [dict get $buildInfo $key]]} {
            error "native build evidence has an invalid $key"
        }
    }
    assert_no_winpthread_link_map [dict get $buildInfo map]
    return [dict create \
        native.link-map.sha256 [dict get $buildInfo link_map_sha256] \
        native.link-inputs.sha256 [dict get $buildInfo link_inputs_sha256] \
        native.winpthread-linked 0]
}
proc unsigned_release_metadata {artifact source identity fingerprints buildInfo} {
    set state [dict create \
        format els-release-provenance-v1 \
        product els \
        product_version [els_version] \
        artifact_file [file tail $artifact] \
        artifact_signed 0 \
        built_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}] \
        source_commit [dict get $source commit] \
        source_describe [dict get $source describe] \
        source_dirty [dict get $source dirty] \
        source_index_sha256 [dict get $source index_sha256] \
        tool.tcl_version [command_version [tclsh] << {puts [info patchlevel]}] \
        tool.gcc_version [command_version [gcc] -dumpfullversion -dumpversion] \
        signing_subject_expected [dict get $identity subject] \
        signing_sha1_expected [dict get $identity sha1] \
        packaged_notices {LICENSE.txt; THIRD-PARTY-NOTICES.txt}]
    if {[dict get $source dirty]} { dict set state source_status [dict get $source status] }
    dict for {key value} $fingerprints { dict set state $key $value }
    dict for {key value} [native_build_evidence $buildInfo] { dict set state $key $value }
    return $state
}
proc same_fingerprints {a b} {
    if {[lsort -dictionary [dict keys $a]] ne [lsort -dictionary [dict keys $b]]} { return 0 }
    dict for {key value} $a {
        if {[dict get $b $key] ne $value} { return 0 }
    }
    return 1
}
proc signed_release_metadata {artifact unsigned signedInfo} {
    set state $unsigned
    dict set state artifact_file [file tail $artifact]
    dict set state artifact_signed 1
    dict set state signed_utc [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]
    dict set state unsigned_sha256 [dict get $unsigned artifact_sha256]
    dict set state signer_subject [dict get $signedInfo subject]
    dict set state signer_sha1 [dict get $signedInfo sha1]
    dict set state timestamped [dict get $signedInfo timestamped]
    return $state
}
proc validate_signed_metadata {artifact values unsigned signedInfo} {
    set expected $unsigned
    dict set expected artifact_file [file tail $artifact]
    dict set expected artifact_bytes [file size $artifact]
    dict set expected artifact_sha256 [sha256_file $artifact]
    dict set expected artifact_signed 1
    dict set expected unsigned_sha256 [dict get $unsigned artifact_sha256]
    dict set expected signer_subject [dict get $signedInfo subject]
    dict set expected signer_sha1 [dict get $signedInfo sha1]
    dict set expected timestamped 1
    set expectedKeys [concat [dict keys $expected] signed_utc]
    require_exact_keys $values $expectedKeys "signed release provenance"
    dict for {key value} $expected {
        if {[dict get $values $key] ne $value} {
            error "signed release provenance '$key' differs from its verified value"
        }
    }
    if {![regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$} \
            [dict get $values signed_utc]]} {
        error "signed release provenance has an invalid signed_utc"
    }
    return $values
}
proc write_release_metadata {artifact values} {
    require_regular_file $artifact "release artifact"
    dict set values artifact_file [file tail $artifact]
    dict set values artifact_bytes [file size $artifact]
    dict set values artifact_sha256 [sha256_file $artifact]
    write_manifest "$artifact.provenance.txt" $values
    write_text_atomic "$artifact.sha256" \
        "[dict get $values artifact_sha256] *[dict get $values artifact_file]\n"
    return $values
}
proc read_checksum {path expectedName} {
    require_regular_file $path "release checksum"
    set fh [open $path r]
    try {
        # -translation binary is a COMPOUND that also resets -encoding to iso8859-1,
        # so it must come FIRST -- listing it last (as before) silently overrode the
        # declared utf-8/strict and decoded the artifact name as latin-1 (R40).
        fconfigure $fh -translation binary -encoding utf-8 -profile strict
        set text [read $fh]
    } finally { close $fh }
    if {![string match *\n $text] || [string first \n [string range $text 0 end-1]] >= 0} {
        error "malformed SHA-256 file: $path"
    }
    set line [string range $text 0 end-1]
    if {![regexp -nocase {^([0-9a-f]{64}) \*([^\r\n]+)$} $line -> hash name]} {
        error "malformed SHA-256 file: $path"
    }
    if {$name ne $expectedName} {
        error "SHA-256 file names '$name', expected '$expectedName'"
    }
    return [string tolower $hash]
}
proc verify_release_set_basic {artifact} {
    require_regular_file $artifact "release artifact"
    require_regular_file "$artifact.provenance.txt" "release provenance"
    require_regular_file "$artifact.sha256" "release checksum"
    set values [read_manifest "$artifact.provenance.txt"]
    foreach key {artifact_file artifact_bytes artifact_sha256} {
        if {![dict exists $values $key]} { error "release provenance lacks '$key'" }
    }
    if {[dict get $values artifact_file] ne [file tail $artifact]} {
        error "release provenance names '[dict get $values artifact_file]', expected '[file tail $artifact]'"
    }
    if {![string is wideinteger -strict [dict get $values artifact_bytes]] ||
        [dict get $values artifact_bytes] != [file size $artifact]} {
        error "release artifact byte count does not match provenance"
    }
    set actual [sha256_file $artifact]
    if {$actual ne [string tolower [dict get $values artifact_sha256]]} {
        error "release artifact no longer matches its provenance SHA-256"
    }
    if {$actual ne [read_checksum "$artifact.sha256" [file tail $artifact]]} {
        error "release artifact no longer matches its .sha256 file"
    }
    return $values
}
proc validate_unsigned_metadata {artifact values source identity fingerprints packagedVersion {buildInfo ""}} {
    require_exact_keys $values \
        [concat [unsigned_metadata_base_keys] [dict keys $fingerprints]] \
        "unsigned release provenance"
    foreach {key expected} [list \
            format els-release-provenance-v1 \
            product els \
            product_version [els_version] \
            artifact_file [file tail $artifact] \
            artifact_signed 0 \
            source_commit [dict get $source commit] \
            source_describe [dict get $source describe] \
            source_dirty 0 \
            source_index_sha256 [dict get $source index_sha256] \
            tool.tcl_version [command_version [tclsh] << {puts [info patchlevel]}] \
            tool.gcc_version [command_version [gcc] -dumpfullversion -dumpversion] \
            signing_subject_expected [dict get $identity subject] \
            packaged_notices {LICENSE.txt; THIRD-PARTY-NOTICES.txt}] {
        if {[dict get $values $key] ne $expected} {
            error "unsigned release provenance '$key' is '[dict get $values $key]', expected '$expected'"
        }
    }
    foreach key {native.link-map.sha256 native.link-inputs.sha256} {
        if {![regexp {^[0-9a-f]{64}$} [dict get $values $key]]} {
            error "unsigned release provenance '$key' is not a SHA-256"
        }
    }
    if {[dict get $values native.winpthread-linked] ne "0"} {
        error "unsigned release provenance unexpectedly claims a winpthreads link"
    }
    if {$buildInfo ne ""} {
        dict for {key expected} [native_build_evidence $buildInfo] {
            if {[dict get $values $key] ne $expected} {
                error "unsigned release provenance '$key' differs from the reproducible build"
            }
        }
    }
    if {$packagedVersion ne [dict get $values product_version]} {
        error "packaged main.tcl version '$packagedVersion' does not match provenance"
    }
    if {[dict get $source dirty]} { error "refusing to sign or promote from a dirty source tree" }
    if {![regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$} \
            [dict get $values built_utc]]} {
        error "unsigned release provenance has an invalid built_utc"
    }
    set prepared [dict get $values signing_sha1_expected]
    set current [dict get $identity sha1]
    if {$prepared ne $current && !($prepared eq "" && $current ne "")} {
        error "signer thumbprint policy changed since release-check"
    }
    dict for {key expected} $fingerprints {
        if {[string tolower [dict get $values $key]] ne [string tolower $expected]} {
            error "release dependency fingerprint changed: $key"
        }
    }
    return $values
}
proc read_verified_unsigned_metadata {artifact {buildInfo ""}} {
    set values [verify_release_set_basic $artifact]
    set source [release_source_state]
    set identity [signing_identity]
    set fingerprints [release_fingerprints]
    set packagedVersion [verify_packaged_payload $artifact 0]
    return [validate_unsigned_metadata $artifact $values $source $identity $fingerprints \
        $packagedVersion $buildInfo]
}
proc files_match {a b} {
    return [expr {[file size $a] == [file size $b] && [sha256_file $a] eq [sha256_file $b]}]
}
proc release_member_suffixes {} { return {.sha256 .provenance.txt {}} }
proc release_member_label {suffix} {
    switch -- $suffix {
        .sha256 { return checksum }
        .provenance.txt { return provenance }
        "" { return artifact }
    }
    error "unknown release member suffix: $suffix"
}
proc assert_exact_release_stage {artifact} {
    verify_release_set_basic $artifact
    set expected {}
    foreach suffix [release_member_suffixes] { lappend expected [file tail "$artifact$suffix"] }
    set actual {}
    foreach path [directory_children [file dirname $artifact]] {
        require_regular_file $path "staged release member"
        lappend actual [file tail $path]
    }
    if {[lsort -dictionary $actual] ne [lsort -dictionary $expected]} {
        error "staged release directory is not the exact three-file release set; expected={$expected}, actual={$actual}"
    }
}
proc verify_release_members_match {source destination} {
    foreach suffix [release_member_suffixes] {
        require_regular_file "$source$suffix" "source release member"
        require_regular_file "$destination$suffix" "published release member"
        if {![files_match "$source$suffix" "$destination$suffix"]} {
            error "published release member differs from its staged source: $destination$suffix"
        }
    }
    verify_release_set_basic $destination
}
proc promotion_journal_path {output} { return "$output.promotion-journal" }
proc promotion_stage_pattern {output} {
    return [file join [file dirname $output] ".[file tail $output].promotion-*"]
}
proc promotion_journal_values {output stage token oldFlags} {
    set values [dict create format els-release-promotion-v1 \
        output_file [file tail $output] stage_dir [file tail $stage] token $token]
    dict for {label existed} $oldFlags { dict set values "old.$label" $existed }
    return $values
}
proc validate_promotion_journal {output values} {
    require_exact_keys $values \
        {format output_file stage_dir token old.checksum old.provenance old.artifact} \
        "release promotion journal"
    if {[dict get $values format] ne "els-release-promotion-v1" ||
        [dict get $values output_file] ne [file tail $output]} {
        error "release promotion journal does not belong to $output"
    }
    set token [dict get $values token]
    if {![regexp {^[0-9]+-[0-9]+-[0-9]+$} $token]} {
        error "release promotion journal has an invalid token"
    }
    set stageTail [dict get $values stage_dir]
    if {[file tail $stageTail] ne $stageTail ||
        ![string match ".[file tail $output].promotion-*" $stageTail]} {
        error "release promotion journal has an invalid stage directory"
    }
    foreach label {checksum provenance artifact} {
        if {[dict get $values "old.$label"] ni {0 1}} {
            error "release promotion journal has an invalid old.$label flag"
        }
    }
    set stage [require_direct_child [file join [file dirname $output] $stageTail] \
        [file dirname $output] "promotion stage"]
    if {[path_type $stage] ne "directory"} {
        error "release promotion stage is missing or not a real directory: $stage"
    }
    return $stage
}
proc restore_promotion_journal {output journal values} {
    set stage [validate_promotion_journal $output $values]
    set token [dict get $values token]
    set restoreDir [file join $stage restore]
    if {[path_type $restoreDir] eq "missing"} { file mkdir $restoreDir }
    if {[path_type $restoreDir] ne "directory"} { error "promotion restore stage is not a real directory" }
    foreach suffix [release_member_suffixes] {
        set label [release_member_label $suffix]
        set destination "$output$suffix"
        set existed [dict get $values "old.$label"]
        require_regular_or_absent $destination "promotion recovery destination"
        if {$existed} {
            set backup [file join $stage old "[file tail $output]$suffix"]
            require_regular_file $backup "promotion recovery backup"
            set temp [file join $restoreDir "[file tail $output]$suffix"]
            delete_regular_if_present $temp
            file copy -- $backup $temp
            if {![files_match $backup $temp]} { error "promotion recovery copy verification failed: $temp" }
            file rename -force -- $temp $destination
        } else {
            delete_regular_if_present $destination
        }
    }
    foreach suffix [release_member_suffixes] {
        set label [release_member_label $suffix]
        set destination "$output$suffix"
        if {[dict get $values "old.$label"]} {
            set backup [file join $stage old "[file tail $output]$suffix"]
            if {![files_match $backup $destination]} { error "promotion recovery verification failed: $destination" }
        } elseif {[path_type $destination] ne "missing"} {
            error "promotion recovery failed to remove $destination"
        }
    }
    foreach suffix [release_member_suffixes] {
        delete_regular_if_present "$output$suffix.new-$token"
    }
    delete_regular_if_present $journal
    remove_real_tree $stage
}
proc reconcile_orphan_promotion_stage {output stage} {
    set internal [file join $stage journal.txt]
    require_regular_file $internal "orphan promotion journal"
    set values [read_manifest $internal]
    set recordedStage [validate_promotion_journal $output $values]
    if {![same_path $recordedStage $stage]} {
        error "orphan promotion journal points at a different stage: $recordedStage"
    }
    set staged [file join $stage new [file tail $output]]
    set visibleIsNew [expr {![catch {verify_release_members_match $staged $output}]}]
    set visibleIsOld 1
    foreach suffix [release_member_suffixes] {
        set label [release_member_label $suffix]
        set destination "$output$suffix"
        if {[dict get $values "old.$label"]} {
            set backup [file join $stage old "[file tail $output]$suffix"]
            if {[catch {files_match $backup $destination} match] || !$match} { set visibleIsOld 0 }
        } elseif {[path_type $destination] ne "missing"} {
            set visibleIsOld 0
        }
    }
    if {!$visibleIsNew && !$visibleIsOld} {
        error "orphan promotion stage cannot be reconciled automatically; inspect $stage"
    }
    remove_real_tree $stage
}
proc recover_release_promotion {output} {
    set output [file normalize $output]
    set journal [promotion_journal_path $output]
    set journalType [path_type $journal]
    set journalTemps [lsort [glob -nocomplain "$journal.new-*"]]
    if {[llength $journalTemps]} {
        if {$journalType eq "missing" && [llength $journalTemps] == 1} {
            set temp [lindex $journalTemps 0]
            require_regular_file $temp "interrupted promotion journal"
            set values [read_manifest $temp]
            validate_promotion_journal $output $values
            file rename -- $temp $journal
            set journalType file
        } elseif {$journalType eq "file"} {
            set canonical [read_manifest $journal]
            foreach temp $journalTemps {
                require_regular_file $temp "interrupted promotion journal"
                if {[read_manifest $temp] ne $canonical} {
                    error "conflicting interrupted promotion journal: $temp"
                }
                file delete -- $temp
            }
        } else {
            error "multiple or invalid interrupted promotion journals require manual inspection: [join $journalTemps {, }]"
        }
    }
    if {$journalType eq "file"} {
        set values [read_manifest $journal]
        restore_promotion_journal $output $journal $values
    } elseif {$journalType ne "missing"} {
        error "release promotion journal must be absent or regular, not $journalType: $journal"
    }
    foreach stage [lsort [glob -nocomplain [promotion_stage_pattern $output]]] {
        if {[path_type $stage] ne "directory"} {
            error "orphan promotion path is not a real directory: $stage"
        }
        reconcile_orphan_promotion_stage $output $stage
    }
}
proc promote_release_set {candidate output} {
    set candidate [file normalize $candidate]
    assert_exact_release_stage $candidate
    if {![string equal -nocase [file tail $candidate] [file tail $output]]} {
        error "release candidate and destination basenames must match"
    }
    set destinationDir [ensure_real_directory [file dirname $output] "release destination directory"]
    set output [file normalize $output]
    if {[same_path $candidate $output]} { error "release candidate and destination must be distinct" }
    recover_release_promotion $output
    foreach suffix [release_member_suffixes] {
        require_regular_or_absent "$output$suffix" "release destination"
    }

    set token "[pid]-[clock microseconds]-[clock clicks]"
    set stage [unique_stage_directory $destinationDir ".[file tail $output].promotion-"]
    set journal [promotion_journal_path $output]
    set oldFlags {}
    set journalWritten 0
    try {
        file mkdir [file join $stage new]
        file mkdir [file join $stage old]
        foreach suffix [release_member_suffixes] {
            set label [release_member_label $suffix]
            set source "$candidate$suffix"
            set staged [file join $stage new "[file tail $output]$suffix"]
            file copy -- $source $staged
            if {![files_match $source $staged]} { error "promotion stage copy verification failed: $staged" }
            set destination "$output$suffix"
            set existed [expr {[path_type $destination] eq "file"}]
            dict set oldFlags $label $existed
            if {$existed} {
                set backup [file join $stage old "[file tail $output]$suffix"]
                file copy -- $destination $backup
                if {![files_match $destination $backup]} { error "promotion backup verification failed: $backup" }
            }
        }
        set values [promotion_journal_values $output $stage $token $oldFlags]
        write_manifest [file join $stage journal.txt] $values
        write_manifest $journal $values
        set journalWritten 1

        # Publish exact, verified copies in sidecar-first/executable-last order.
        foreach suffix [release_member_suffixes] {
            set source [file join $stage new "[file tail $output]$suffix"]
            set destination "$output$suffix"
            set temp "$destination.new-$token"
            delete_regular_if_present $temp
            file copy -- $source $temp
            if {![files_match $source $temp]} { error "promotion publish copy verification failed: $temp" }
            file rename -force -- $temp $destination
        }
        verify_release_members_match $candidate $output
    } on error {err opts} {
        if {$journalWritten} {
            set recoveryRc [catch {recover_release_promotion $output} recoveryErr]
            if {$recoveryRc} { append err "\nrelease-set recovery also failed: $recoveryErr" }
        } else {
            if {[catch {remove_real_tree $stage} cleanupErr]} {
                append err "\npromotion stage cleanup also failed: $cleanupErr"
            }
        }
        return -options $opts "release promotion or verification failed: $err"
    }
    # Deleting the on-disk recovery pointer commits the verified new set.  The internal
    # journal and full old/new copies make a crash before this point recoverable.
    delete_regular_if_present $journal
    remove_real_tree $stage
    verify_release_members_match $candidate $output
}
proc zip_read_binary {path} {
    set fh [open $path r]
    try { fconfigure $fh -translation binary; return [read $fh] } finally { close $fh }
}
proc verify_packaged_payload {artifact {announce 1}} {
    set mount "ElsRelease[pid]"
    if {[catch {zipfs mount $artifact $mount} err]} { error "cannot mount packaged zipfs: $err" }
    try {
        set root "//zipfs:/$mount"
        foreach rel {main.tcl LICENSE.txt THIRD-PARTY-NOTICES.txt tcl_library/init.tcl tk_library/tk.tcl} {
            if {![file isfile [file join $root $rel]]} { error "packaged payload lacks $rel" }
        }
        set tclSource [TCp tcllib tcl_library]
        set tkSource [TCp tcllib tk_library]
        set tclFiles [release_tree_files $tclSource]
        set tkFiles [release_tree_files $tkSource]
        set tracked [tracked_resource_files]
        set resourceFiles [lmap rel $tracked { string range $rel [string length "resources/"] end }]
        set expectedFiles {main.tcl LICENSE.txt THIRD-PARTY-NOTICES.txt}
        foreach rel $resourceFiles { lappend expectedFiles "resources/$rel" }
        foreach rel $tclFiles { lappend expectedFiles "tcl_library/$rel" }
        foreach rel $tkFiles { lappend expectedFiles "tk_library/$rel" }
        set actualFiles [release_tree_files $root]
        if {[lsort -dictionary $actualFiles] ne [lsort -dictionary $expectedFiles]} {
            error "packaged payload file set differs from the trusted release inputs"
        }
        set actualMain [zip_read_binary [file join $root main.tcl]]
        set expectedMain [::elsrelease::read_binary [P els.tcl]]
        if {$actualMain ne $expectedMain} { error "packaged main.tcl differs from els.tcl" }
        set actualLicense [zip_read_binary [file join $root LICENSE.txt]]
        set expectedLicense [::elsrelease::read_binary [P LICENSE]]
        if {$actualLicense ne $expectedLicense} { error "packaged LICENSE.txt differs from the project LICENSE" }
        set actualNotices [zip_read_binary [file join $root THIRD-PARTY-NOTICES.txt]]
        set expectedNotices [::elsrelease::third_party_notices $::TC $::MSYS2]
        if {$actualNotices ne $expectedNotices} {
            error "packaged THIRD-PARTY-NOTICES.txt is incomplete or differs from its canonical sources"
        }
        foreach rel $resourceFiles {
            set expected [::elsrelease::read_binary [file join $::ROOT resources {*}[split $rel /]]]
            set actual [zip_read_binary [file join $root resources {*}[split $rel /]]]
            if {$actual ne $expected} { error "packaged resource differs from Git-tracked source: resources/$rel" }
        }
        foreach {label sourceDir packageDir files} [list \
                Tcl $tclSource tcl_library $tclFiles \
                Tk $tkSource tk_library $tkFiles] {
            foreach rel $files {
                set expected [::elsrelease::read_binary [file join $sourceDir {*}[split $rel /]]]
                set actual [zip_read_binary [file join $root $packageDir {*}[split $rel /]]]
                if {$actual ne $expected} { error "packaged $label library file differs from source: $rel" }
            }
        }
        if {![regexp {variable\s+version\s+"([^"]+)"} $actualMain -> packagedVersion]} {
            error "cannot read els version from packaged main.tcl"
        }
    } finally {
        catch {zipfs unmount $mount}
    }
    if {$announce} {
        puts "package check ok: exact main, resources, Tcl/Tk libraries and license notices are embedded"
    }
    return $packagedVersion
}

proc task_release-check {args} {
    set allowDirty 0
    set noPromote 0
    foreach arg $args {
        switch -- $arg {
            --allow-dirty { set allowDirty 1; set noPromote 1 }
            --no-promote  { set noPromote 1 }
            default { error "unknown release-check option '$arg'" }
        }
    }
    assert_trusted_release_payloads
    activate_release_environment
    need tclsh wish gcc windres strip sha256
    assert_release_git_inputs $allowDirty
    set source [release_source_state]
    if {[dict get $source dirty] && !$allowDirty} {
        error "release tree is dirty; commit/stash all changes first:\n[dict get $source status]"
    }
    if {[dict get $source dirty]} {
        puts "note: dirty-tree validation requested; promotion is forcibly disabled"
    }
    set identity [signing_identity]
    set signtool [find_signtool]
    puts "signature readiness: $signtool"
    puts "expected publisher:  [dict get $identity subject][expr {[dict get $identity sha1] ne {} ? " ([dict get $identity sha1])" : {}}]"

    puts "\n== deep toolchain check =="
    task_toolcheck --deep

    puts "\n== release input fingerprint snapshot =="
    set inputFingerprints [release_fingerprints]

    puts "\n== clean native build + load check =="
    foreach name {cap elsx icudet winfs windrop} { delete_regular_if_present [P build $name.dll] }
    delete_regular_if_present [P build pkgIndex.tcl]
    task_build-ext
    stream [tclsh] [P tools native_check.tcl] [P build]

    puts "\n== release tooling invariants =="
    stream [tclsh] [P tools release_tooling.test]

    puts "\n== complete fail-closed test suite =="
    stream [tclsh] [P tools release_tests.tcl]

    set output [P dist els-unsigned.exe]
    set buildInfo ""
    try {
        set stageDir [prepare_release_check_directory]
        set candidate [file join $stageDir els-unsigned.exe]
        puts "\n== staged product build =="
        set buildInfo [build_native_product $candidate]

        puts "\n== native startup failure path =="
        run_native_startup_check $buildInfo

        puts "\n== package + PE policy =="
        set packagedVersion [verify_packaged_payload $candidate]
        stream [tclsh] [P tools pecheck.tcl] --unsigned \
            --manifest [dict get $buildInfo manifest] --version [els_version] $candidate

        puts "\n== real packaged-executable probe =="
        stream [tclsh] [P tools probe_exe.tcl] $candidate

        puts "\n== provenance =="
        set sourceAfter [release_source_state]
        if {![same_release_source_snapshot $source $sourceAfter]} {
            error "source tree or Git index changed while release-check was running; candidate will not be promoted"
        }
        set finalFingerprints [release_fingerprints]
        if {![same_fingerprints $inputFingerprints $finalFingerprints]} {
            error "compiler, linker, runtime, packaging, signing, or notice inputs changed while release-check was running"
        }
        set metadata [unsigned_release_metadata $candidate $source $identity \
            $inputFingerprints $buildInfo]
        set metadata [write_release_metadata $candidate $metadata]
        if {[dict get $source dirty]} {
            verify_release_set_basic $candidate
        } else {
            set metadata [read_verified_unsigned_metadata $candidate $buildInfo]
        }
        assert_exact_release_stage $candidate
        set sourceFinal [release_source_state]
        if {![same_release_source_snapshot $source $sourceFinal]} {
            error "source tree or Git index changed while release provenance was written; candidate will not be promoted"
        }
        puts "candidate sha256: [dict get $metadata artifact_sha256]"

        if {$noPromote} {
            puts "\nOK - every release gate passed; promotion disabled."
            puts "  staged      $candidate"
            puts "  provenance  $candidate.provenance.txt"
            return
        }
        promote_release_set $candidate $output
        puts "\nOK - every release gate passed; unsigned candidate promoted."
        puts "  file        $output"
        puts "  sha256      [dict get $metadata artifact_sha256]"
        puts "  provenance  $output.provenance.txt"
        puts "next: z sign"
    } finally {
        if {$buildInfo ne "" && [dict exists $buildInfo stage]} {
            remove_real_tree [dict get $buildInfo stage]
        }
    }
}

proc task_test {args} {
    need tclsh
    ensure_test_native_support
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

proc native_artifact_stale {artifact inputs} {
    if {[path_type $artifact] ne "file"} { return 1 }
    foreach input $inputs {
        if {[path_type $input] ne "file" || [file mtime $input] > [file mtime $artifact]} {
            return 1
        }
    }
    return 0
}

proc run_native_support_stale {{winfs ""} {inputs ""}} {
    if {$winfs eq ""} { set winfs [P build winfs.dll] }
    if {$inputs eq ""} { set inputs [list [P src winfs.c] [P tools tasks.tcl]] }
    return [native_artifact_stale $winfs $inputs]
}

proc test_native_support_stale {{buildDir ""} {sourceDir ""} {logic ""}} {
    if {$buildDir eq ""} { set buildDir [P build] }
    if {$sourceDir eq ""} { set sourceDir [P src] }
    if {$logic eq ""} { set logic [P tools tasks.tcl] }
    set names {elsx icudet winfs}
    foreach name $names {
        if {[native_artifact_stale [file join $buildDir $name.dll] \
                [list [file join $sourceDir $name.c] $logic]]} { return 1 }
    }
    set indexInputs [list $logic]
    foreach name $names { lappend indexInputs [file join $sourceDir $name.c] }
    return [native_artifact_stale [file join $buildDir pkgIndex.tcl] $indexInputs]
}

proc capture_support_stale {{cap ""} {inputs ""}} {
    if {$cap eq ""} { set cap [P build cap.dll] }
    if {$inputs eq ""} {
        set inputs [list [P src cap.c] [P tools shot.tcl] \
            [P tools private_shot.tcl] [P tools tasks.tcl]]
    }
    return [native_artifact_stale $cap $inputs]
}

proc ensure_native_support {} {
    if {[run_native_support_stale]} {
        puts "building required native worker support..."
        task_build-ext
    }
}

proc ensure_test_native_support {} {
    if {[test_native_support_stale]} {
        puts "building required native test support..."
        task_build-ext
    }
}

proc ensure_capture_support {} {
    if {[capture_support_stale]} {
        puts "building required capture extension..."
        task_build-ext
    }
}

proc task_run {args} {
    need wish
    # Source runs depend on the native worker Job/reparse surface.  Never launch
    # against a missing or stale winfs.dll: the resulting editor would appear
    # healthy but Find/Replace would be deliberately unavailable.
    ensure_native_support
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
    need tclsh wish
    ensure_capture_support
    if {[lindex $args 0] eq "--selftest"} {
        if {[llength $args] != 1} { error "usage: z shot --selftest" }
        stream [tclsh] [P tools shot.tcl] --selftest [wish]
        return
    }
    if {[llength $args] < 1} { error "usage: z shot <out.png> \[file ...\]" }
    set out [lindex $args 0]
    stream [tclsh] [P tools shot.tcl] [wish] [P els.tcl] $out {*}[lrange $args 1 end]
}

proc task_readme-shots {args} {
    if {[llength $args]} { error "usage: z readme-shots" }
    need tclsh wish
    ensure_capture_support
    stream [tclsh] [P tools readme_shots.tcl] [wish] [tclsh]
}

proc task_build-ext {args} {
    if {[llength $args]} { error "usage: z build-ext" }
    need gcc tclsh
    set inc [TCp tcl9 include]
    set lib [TCp tcl9 lib]
    ensure_real_directory [P build] "extension build root"
    set names {cap elsx icudet winfs windrop}
    set expected [lsort [concat els_main.c [lmap name $names { format "%s.c" $name }]]]
    set actual [lsort [lmap path [glob -nocomplain [P src *.c]] { file tail $path }]]
    if {$actual ne $expected} {
        error "src/*.c inventory differs from the reviewed build list; expected={$expected}, actual={$actual}"
    }
    set stage [unique_stage_directory [P build] _extensions]
    set lines [list "# auto-generated by `z build-ext` - do not edit"]
    try {
        foreach name $names {
            set src [P src $name.c]
            set dll [file join $stage $name.dll]
            set init [string totitle $name]
            puts "cc  [file tail $src] -> staged $name.dll"
            stream [gcc] -std=c23 -O2 -Wall -Wextra -Werror -no-pthread \
                -shared -DUSE_TCL_STUBS -I$inc $src -o $dll -L$lib -ltclstub \
                -static-libgcc -luser32 -lgdi32 -lcomctl32 -lshell32 -lole32
            require_regular_file $dll "staged extension"
            lappend lines "package ifneeded $name 0.1 \[list load \[file join \$dir $name.dll\] $init\]"
        }
        set stagedIndex [file join $stage pkgIndex.tcl]
        set idx [open $stagedIndex {WRONLY CREAT EXCL}]
        try {
            fconfigure $idx -encoding utf-8 -translation lf
            puts $idx [join $lines \n]
        } finally { close $idx }
        foreach name $names {
            place_regular_file [file join $stage $name.dll] [P build $name.dll] "extension output"
        }
        place_regular_file $stagedIndex [P build pkgIndex.tcl] "extension package index"
    } finally {
        remove_real_tree $stage
    }
    puts "built [llength $names] extension(s); wrote build/pkgIndex.tcl"
}

proc native_system_libraries {} {
    return {
        -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
        -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
        -loleaut32 -lwinspool
    }
}

proc product_source_names {} { return {els_main icudet winfs windrop} }

proc assert_product_source_inventory {} {
    set allowed [lsort [lmap name [concat [product_source_names] {cap elsx}] { format "%s.c" $name }]]
    set actual [lsort [lmap path [glob -nocomplain [P src *.c]] { file tail $path }]]
    if {$actual ne $allowed} {
        error "src/*.c inventory differs from the reviewed native build list; expected={$allowed}, actual={$actual}"
    }
}

proc release_epoch {} {
    set value [git_capture show -s --format=%ct HEAD]
    if {![string is wideinteger -strict $value] || $value < 315532800} {
        error "Git returned an invalid source epoch: $value"
    }
    return $value
}

proc stable_link_map_sha256 {path stage} {
    set fh [open $path r]
    try {
        fconfigure $fh -encoding utf-8 -profile replace -translation lf
        set text [read $fh]
    } finally { close $fh }
    set replacements {}
    foreach {source marker} [list $stage <STAGE> $::ROOT <ROOT> $::TC <TCLTK> $::MSYS2 <MSYS2>] {
        set native [file nativename [file normalize $source]]
        set forward [string map {\\ /} $native]
        lappend replacements $native $marker $forward $marker
    }
    set text [string map $replacements $text]
    return [sha256_bytes $text]
}

proc assert_no_winpthread_link_map {path} {
    require_regular_file $path "native linker map"
    set fh [open $path r]
    try {
        fconfigure $fh -encoding utf-8 -profile replace -translation lf
        set text [string tolower [read $fh]]
    } finally { close $fh }
    if {[regexp {(^|[^a-z0-9])(lib)?winpthread([^a-z0-9]|$)} $text]} {
        error "native link unexpectedly includes winpthreads; add its exact license notice before releasing"
    }
}

proc native_link_input_sha256 {stage} {
    set libd [TCp tcl9s lib]
    set files [list \
        object.els_main [file join $stage els_main.o] \
        object.icudet [file join $stage icudet.o] \
        object.winfs [file join $stage winfs.o] \
        object.windrop [file join $stage windrop.o] \
        object.resources [file join $stage els.res] \
        archive.tcltk [file join $libd libtcl9tk90.a] \
        archive.tcl [file join $libd libtcl90.a] \
        archive.tclstub [file join $libd libtclstub.a]]
    foreach {name option} {
        crt2u -print-file-name=crt2u.o
        crtbegin -print-file-name=crtbegin.o
        crtend -print-file-name=crtend.o
        default-manifest -print-file-name=default-manifest.o
        libgcc -print-libgcc-file-name
        libgcc-eh -print-file-name=libgcc_eh.a
        libmingw32 -print-file-name=libmingw32.a
        libmoldname -print-file-name=libmoldname.a
        libmingwex -print-file-name=libmingwex.a
        libmsvcrt -print-file-name=libmsvcrt.a
        libucrtbase -print-file-name=libucrtbase.a
    } {
        lappend files "implicit.$name" [gcc_file $option [file tail [string range $option [expr {[string first = $option] + 1}] end]]]
    }
    foreach library {
        netapi32 kernel32 user32 advapi32 userenv ws2_32 gdi32 comdlg32 imm32
        comctl32 shell32 uuid ole32 oleaut32 winspool
    } {
        set filename "lib$library.a"
        lappend files "system.$library" [gcc_file "-print-file-name=$filename" $filename]
    }
    set manifest "els-native-link-inputs-v1\n"
    foreach {name path} $files {
        require_regular_file $path "native link input"
        append manifest $name "\t" [sha256_file $path] "\n"
    }
    return [sha256_bytes $manifest]
}

proc build_native_product {out} {
    need gcc tclsh windres strip
    if {![file isfile [tclshs]]} {
        error "static tclsh missing in z's Tcl/Tk payload (r/tcltk/9.0.4/tcl9s/bin)"
    }
    assert_product_source_inventory
    ensure_real_directory [P build] "native build root"
    ensure_real_directory [file dirname $out] "native output directory"
    require_regular_or_absent $out "native build output"
    set stage [unique_stage_directory [P build] _native]
    set hadEpoch [info exists ::env(SOURCE_DATE_EPOCH)]
    if {$hadEpoch} { set savedEpoch $::env(SOURCE_DATE_EPOCH) }
    set ::env(SOURCE_DATE_EPOCH) [release_epoch]
    set inc [TCp tcl9 include]
    set libd [TCp tcl9s lib]
    try {
        puts "gen  private native resource stage"
        stream [tclsh] [P tools genres.tcl] $stage
        stream [tclsh] [P tools mkico.tcl] [file join $stage els.ico] \
            [P resources icon16.png] [P resources icon32.png] [P resources icon.png]
        stream [windres] --include-dir $stage --include-dir $inc \
            [file join $stage els.rc] -O coff -o [file join $stage els.res]
        foreach name [product_source_names] {
            set defs {-DSTATIC_BUILD=1 -ffunction-sections -fdata-sections}
            if {$name eq "els_main"} {
                lappend defs -municode -DUNICODE -D_UNICODE \
                    -DELS_STATIC_ICUDET -DELS_STATIC_WINFS -DELS_STATIC_WINDROP
            }
            stream [gcc] -std=c23 -O2 -Wall -Wextra -Werror -no-pthread \
                -frandom-seed=els-$name {*}$defs -c [P src $name.c] \
                -o [file join $stage $name.o] -I$inc
        }
        set bare [file join $stage els-bare.exe]
        set map [file join $stage els.map]
        puts "ld  -> private native stage/els-bare.exe"
        stream [gcc] -no-pthread -municode -mwindows -static-libgcc \
            "-Wl,--gc-sections,--dynamicbase,--nxcompat,--high-entropy-va,--no-insert-timestamp,-Map,$map,--cref" \
            [file join $stage els_main.o] [file join $stage icudet.o] \
            [file join $stage winfs.o] [file join $stage windrop.o] [file join $stage els.res] \
            [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] \
            [file join $libd libtclstub.a] {*}[native_system_libraries] -o $bare
        assert_no_winpthread_link_map $map
        stream [strip-exe] --enable-deterministic-archives $bare
        set image [file join $stage els-packaged.exe]
        stream [tclshs] [P tools package.tcl] --wrapper $bare $image
        set info [dict create \
            stage $stage output $out manifest [file join $stage els.exe.manifest] \
            resource [file join $stage els.res] map $map \
            link_map_sha256 [stable_link_map_sha256 $map $stage] \
            link_inputs_sha256 [native_link_input_sha256 $stage]]
        foreach name [product_source_names] { dict set info object.$name [file join $stage $name.o] }
        place_regular_file $image $out "native build output"
        puts "placed $out ([file size $out] bytes)"
        return $info
    } on error {err opts} {
        if {[catch {remove_real_tree $stage} cleanupErr]} {
            append err "\nnative build stage cleanup also failed: $cleanupErr"
        }
        return -options $opts $err
    } finally {
        if {$hadEpoch} { set ::env(SOURCE_DATE_EPOCH) $savedEpoch } else { catch {unset ::env(SOURCE_DATE_EPOCH)} }
    }
}

# Compile the test-only Els_AppInit failure injection, package it exactly like a
# product exe, then prove it exits through the native UTF-16 diagnostic path and
# never returns to Tk_Main/main.tcl.  `prepared` is used only by release-check,
# immediately after its normal product build has refreshed the shared objects.
proc run_native_startup_check {{prepared {}}} {
    need gcc tclsh windres strip
    if {![file isfile [tclshs]]} {
        error "static tclsh missing in z's Tcl/Tk payload (r/tcltk/9.0.4/tcl9s/bin)"
    }
    set ownPrepared 0
    if {$prepared eq ""} {
        set prepOutDir [unique_stage_directory [P build] _startup-prep]
        # A failing preparatory build must not orphan the just-created stage dir: the
        # try/finally that reclaims outer_stage only begins after this block, so remove
        # it here before rethrowing (place_regular_file is the build's last step and runs
        # only on success, so on error the dir holds no product exe) (R42).
        try {
            set prepared [build_native_product [file join $prepOutDir els-normal-prep.exe]]
        } on error {err opts} {
            remove_real_tree $prepOutDir
            return -options $opts $err
        }
        dict set prepared outer_stage $prepOutDir
        set ownPrepared 1
    }
    set dir [unique_stage_directory [P build] _native-startup]
    foreach input [list [dict get $prepared object.icudet] [dict get $prepared object.winfs] \
            [dict get $prepared object.windrop] [dict get $prepared resource]] {
        require_regular_file $input "native startup-check input"
    }
    set inc [TCp tcl9 include]
    set libd [TCp tcl9s lib]
    set mainObj [file join $dir els_main-initfail.o]
    set bare [file join $dir els-initfail-bare.exe]
    set candidate [file join $dir els-initfail.exe]
    try {
        puts "cc  els_main.c (forced InitFailure)"
        stream [gcc] -std=c23 -O2 -Wall -Wextra -Werror -no-pthread -municode \
            -frandom-seed=els-init-failure -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 \
            -DELS_STATIC_ICUDET -DELS_STATIC_WINFS -DELS_STATIC_WINDROP -DELS_TEST_INIT_FAILURE \
            -ffunction-sections -fdata-sections -c [P src els_main.c] -o $mainObj -I$inc
        puts "ld  -> private startup-failure stage"
        stream [gcc] -no-pthread -municode -mwindows -static-libgcc \
            -Wl,--gc-sections,--dynamicbase,--nxcompat,--high-entropy-va,--no-insert-timestamp \
            $mainObj [dict get $prepared object.icudet] [dict get $prepared object.winfs] \
            [dict get $prepared object.windrop] [dict get $prepared resource] \
            [file join $libd libtcl9tk90.a] [file join $libd libtcl90.a] \
            [file join $libd libtclstub.a] {*}[native_system_libraries] -o $bare
        stream [strip-exe] --enable-deterministic-archives $bare
        stream [tclshs] [P tools package.tcl] --wrapper $bare $candidate
        stream [tclsh] [P tools native_startup_check.tcl] $candidate
    } finally {
        remove_real_tree $dir
        if {$ownPrepared} {
            remove_real_tree [dict get $prepared stage]
            remove_real_tree [dict get $prepared outer_stage]
        }
    }
}

proc task_native-startup-check {args} {
    if {[llength $args]} { error "usage: z native-startup-check" }
    run_native_startup_check
}

proc task_build {args} {
    need gcc tclsh windres strip
    if {[llength $args] > 1} { error "usage: z build ?build/output.exe?" }
    if {![file exists [tclshs]]} {
        error "static tclsh missing in z's Tcl/Tk payload (r/tcltk/9.0.4/tcl9s/bin)"
    }
    set out [lindex $args 0] ; if {$out eq ""} { set out [P build els-dev.exe] }
    if {[string match -* $out]} { error "z build takes no flags (got '$out'); usage: z build ?outfile?" }
    set out [validate_build_output $out]
    set info [build_native_product $out]
    remove_real_tree [dict get $info stage]
}

# ---- dispatch -----------------------------------------------------------
# Keep the task library sourceable by its focused tooling tests.  Normal z
# execution still enters this block because argv0 is tools/tasks.tcl.
if {[file normalize [info script]] eq [file normalize $argv0]} {
    set cmd [lindex $argv 0]
    if {$cmd eq ""} { set cmd help }
    set proc "task_$cmd"
    if {[llength [info commands $proc]] == 0} {
        puts stderr "els tasks: unknown command '$cmd' (try: z tasks)"
        exit 2
    }
    set lockAcquired 0
    set rc [catch {
        if {[task_uses_tool_lock $cmd]} {
            acquire_tool_lock $cmd
            set lockAcquired 1
        }
        try {
            $proc {*}[lrange $argv 1 end]
        } finally {
            if {$lockAcquired} { release_tool_lock }
        }
    } err opts]
    if {$rc} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "STREAM" && [lindex $ec 1] eq "CHILD"} {
            exit [lindex $ec 2]
        }
        puts stderr "z $cmd: $err"
        exit 1
    }
}
