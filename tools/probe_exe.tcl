# tools/probe_exe.tcl -- process-level smoke tests for the fused els.exe.
#
# Usage: tclsh90.exe tools/probe_exe.tcl path/to/els.exe

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
set SRC [lindex $argv 0]
if {$SRC eq ""} { set SRC [file join $ROOT els.exe] }
if {![file exists $SRC]} { error "exe not found: $SRC" }

set BASE [file join $ROOT tests _tmp "exeprobe-[pid]-[clock clicks]"]
set TASKKILL [expr {[info exists ::env(SystemRoot)] \
    ? [file join $::env(SystemRoot) System32 taskkill.exe] : "taskkill.exe"}]

proc write_file {path bytes} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -translation binary
    puts -nonewline $f $bytes
    close $f
    return $path
}

proc read_file {path} {
    set f [open $path r]
    try {
        fconfigure $f -translation binary
        return [read $f]
    } finally { close $f }
}

proc exact_dict {text keys} {
    if {[catch {llength $text} n] || $n % 2} { error "invalid dictionary list" }
    set out [dict create]
    foreach {k v} $text {
        if {[dict exists $out $k]} { error "duplicate dictionary key" }
        dict set out $k $v
    }
    if {[lsort [dict keys $out]] ne [lsort $keys]} { error "dictionary schema mismatch" }
    return $out
}

proc cleanup_probe_root {path} {
    # The startup report is written just before the GUI process exits.  On
    # Windows the copied exe can therefore remain mapped for a few milliseconds
    # after the report becomes readable; retry briefly instead of either leaking
    # predictable litter or recursively clearing it on a later run.
    for {set i 0} {$i < 20} {incr i} {
        if {![file exists $path]} { return 1 }
        if {![catch {file delete -force -- $path}]} { return 1 }
        after 50
    }
    return 0
}

proc wait_report {report pid} {
    set deadline [expr {[clock milliseconds] + 6000}]
    while {[clock milliseconds] < $deadline} {
        if {[file exists $report]} {
            set f [open $report r]
            set data [read $f]
            close $f
            # only return once it parses as a dict — guards against reading a
            # half-written report (belt-and-braces atop the atomic write)
            if {![catch {dict size $data}]} { return $data }
        }
        after 50
    }
    # recycle-safe kill: the OS may have reassigned the PID to an unrelated
    # process after a crash, so only kill it if it is still an els.exe
    catch {exec $::TASKKILL /FI "PID eq [lindex $pid 0]" /FI "IMAGENAME eq els.exe" /T /F}
    error "exe probe did not finish: $report"
}

proc with_probe_environment {app pairs body} {
    set names {
        APPDATA LOCALAPPDATA HOME USERPROFILE TEMP TMP PATH
        TCL_LIBRARY TK_LIBRARY TCLLIBPATH TCL_PACKAGE_PATH
        Z_HOME Z_ROOT Z_TCLTK Z_MSYS2 Z_TWAPI MSYSTEM MINGW_PREFIX
        ELS_STARTUP_PROBE
    }
    foreach name [array names ::env TCL*] { if {$name ni $names} { lappend names $name } }
    foreach name [array names ::env TK_*] { if {$name ni $names} { lappend names $name } }
    foreach name [array names ::env Z_*] { if {$name ni $names} { lappend names $name } }
    set saved {}
    foreach name $names {
        if {[info exists ::env($name)]} {
            dict set saved $name [list 1 $::env($name)]
            unset ::env($name)
        } else { dict set saved $name [list 0 ""] }
    }
    set oldPwd [pwd]
    try {
        set profile [file join $app profile]
        set temp [file join $app temp]
        file mkdir $profile $temp [file join $app appdata] [file join $app localappdata]
        set ::env(APPDATA) [file nativename [file join $app appdata]]
        set ::env(LOCALAPPDATA) [file nativename [file join $app localappdata]]
        set ::env(HOME) [file nativename $profile]
        set ::env(USERPROFILE) [file nativename $profile]
        set ::env(TEMP) [file nativename $temp]
        set ::env(TMP) [file nativename $temp]
        set pathParts {}
        if {[info exists ::env(SystemRoot)]} {
            lappend pathParts [file nativename [file join $::env(SystemRoot) System32]] \
                [file nativename $::env(SystemRoot)]
        }
        set ::env(PATH) [join $pathParts {;}]
        foreach {name value} $pairs {
            if {$value eq "\x00unset"} { catch {unset ::env($name)} } else { set ::env($name) $value }
        }
        cd $app
        uplevel 1 $body
    } finally {
        cd $oldPwd
        dict for {name state} $saved {
            lassign $state had value
            if {$had} { set ::env($name) $value } else { catch {unset ::env($name)} }
        }
    }
}

proc launch_probe {app {args {}}} {
    set report [file join $app report.txt]
    set pairs [list ELS_STARTUP_PROBE $report]
    set exe [file join $app els.exe]
    set pid [with_probe_environment $app $pairs [list exec $exe {*}$args &]]

    return [wait_report $report $pid]
}

proc run_probe {name src {conf ""} {files {}} {args {}}} {
    set app [file join $::BASE $name]
    if {[file exists $app]} { error "unique exe probe directory already exists: $app" }
    file mkdir $app
    file copy -force $src [file join $app els.exe]
    if {$conf ne ""} { write_file [file join $app els.conf] $conf }
    foreach {tail bytes} $files {
        write_file [file join $app $tail] $bytes
    }
    return [launch_probe $app $args]
}

# The fused executable must recognize its private worker entry point before any
# normal editor startup.  Omit `go` deliberately: a correctly dispatched worker
# self-exits with code 3 after its bounded authorization wait, creates neither a
# startup report nor configuration, and never evaluates a regex.
proc probe_packaged_worker_bypass {src} {
    set app [file join $::BASE packaged-worker]
    file mkdir $app
    set exe [file join $app els.exe]
    file copy -force $src $exe
    set job [file join $app inert-job]
    file mkdir $job
    set report [file join $app normal-startup.report]
    set token 0123456789abcdef0123456789abcdef
    set code [catch {
        with_probe_environment $app [list ELS_STARTUP_PROBE $report] \
            [list exec $exe --find-worker $job $token]
    } err opts]
    set ec [expr {$code ? [dict get $opts -errorcode] : {}}]
    if {!$code || [lindex $ec 0] ne "CHILDSTATUS" || [lindex $ec 2] != 3 \
            || [file exists $report] || [file exists [file join $app els.conf]] \
            || [llength [glob -nocomplain -directory $job *]]} {
        error "packaged worker bypass probe failed: code=$code errorcode=$ec err=$err"
    }
    puts "packaged worker bypass probe ok (unauthorized worker self-exited)"

    # Now exercise the complete fused-worker path under the production
    # watch-before-go discipline.  This closes the gap where source workers pass
    # while zipfs dispatch or the statically linked runtime fails after auth.
    set winfs [file join $::ROOT build winfs.dll]
    if {![file isfile $winfs]} { error "authorized worker probe requires $winfs" }
    if {![llength [info commands ::els::win_worker_spawn_watch]]} { load $winfs Winfs }
    set authJob [file join $app authorized-job]
    file mkdir $authJob
    set authToken fedcba98765432100123456789abcdef
    set source "alpha beta alpha"
    set sourceRaw [encoding convertto -profile strict utf-8 $source]
    set request [dict create version 1 token $authToken kind search pattern alpha \
        nocase 0 regex_mode 0 replacement {} adapt 0 \
        source_chars [string length $source] source_bytes [string length $sourceRaw] \
        source_crc [zlib crc32 $sourceRaw] match_limit 1000 output_limit 1000 \
        deadline_ms 5000 hint_start 0 hint_end 0]
    write_file [file join $authJob snapshot.utf8] $sourceRaw
    write_file [file join $authJob request.dict] \
        [encoding convertto -profile strict utf-8 $request]
    set watch ""
    try {
        set spawnStarted [clock milliseconds]
        set watch [with_probe_environment $app [list ELS_STARTUP_PROBE $report] \
            [list els::win_worker_spawn_watch \
                [list $exe --find-worker $authJob $authToken] $app]]
        set spawnElapsed [expr {[clock milliseconds] - $spawnStarted}]
        if {$spawnElapsed >= 3000} {
            error "packaged worker spawn blocked for ${spawnElapsed}ms before authorization"
        }
        set go [dict create version 1 token $authToken command go]
        write_file [file join $authJob go] [encoding convertto -profile strict utf-8 $go]
        set deadline [expr {[clock milliseconds] + 8000}]
        set final ""
        while {[clock milliseconds] < $deadline} {
            set status [els::win_worker_status $watch]
            if {[lindex $status 0] eq "exited"} { set final $status ; set watch "" ; break }
            after 20
        }
        if {$final ne {exited 0}} { error "packaged worker did not exit cleanly: $final" }

        set resultRaw [read_file [file join $authJob result.ready]]
        set keys {changed_count error kind match_bytes match_count match_crc match_truncated \
            output_bytes output_chars output_crc source_bytes source_chars source_crc status token version}
        set result [exact_dict [encoding convertfrom -profile strict utf-8 $resultRaw] $keys]
        set expectedIndex [format "%020d %020d\n" 0 5]
        append expectedIndex [format "%020d %020d\n" 11 16]
        set index [read_file [file join $authJob matches.idx]]
        if {[dict get $result version] != 1 || [dict get $result token] ne $authToken \
                || [dict get $result status] ne "ok" || [dict get $result kind] ne "search" \
                || [dict get $result source_chars] != [string length $source] \
                || [dict get $result source_bytes] != [string length $sourceRaw] \
                || [dict get $result source_crc] != [zlib crc32 $sourceRaw] \
                || [dict get $result match_count] != 2 \
                || [dict get $result match_truncated] != 0 \
                || [dict get $result match_bytes] != 84 \
                || [dict get $result match_crc] != [zlib crc32 $expectedIndex] \
                || [dict get $result changed_count] != 0 \
                || [dict get $result output_chars] != 0 \
                || [dict get $result output_bytes] != 0 \
                || [dict get $result output_crc] != 0 \
                || [dict get $result error] ne "" || $index ne $expectedIndex \
                || [file exists [file join $authJob replacement.utf8]] \
                || [file exists $report] || [file exists [file join $app els.conf]]} {
            error "authorized packaged worker returned invalid data: $result"
        }
        puts "packaged worker authorized-search probe ok (2 exact matches)"
    } finally {
        if {$watch ne ""} {
            catch {els::win_worker_kill $watch}
            set until [expr {[clock milliseconds] + 3000}]
            while {[clock milliseconds] < $until} {
                if {[catch {set state [els::win_worker_status $watch]}] \
                        || [lindex $state 0] eq "exited"} { break }
                after 20
            }
        }
        foreach leaf {go request.dict snapshot.utf8 matches.idx replacement.utf8 result.ready} {
            set path [file join $authJob $leaf]
            if {![catch {file type $path} type] && $type eq "file"} { catch {file delete -- $path} }
        }
        catch {file delete -- $authJob}
    }
}

if {[file exists $BASE]} { error "unique exe probe root already exists: $BASE" }
file mkdir $BASE

probe_packaged_worker_bypass $SRC

set first [run_probe first $SRC]
set firstConfig [file normalize [file join $BASE first els.conf]]
set reportedConfig [dict get $first config]
if {[dict get $first mapped] != 1 || [dict get $first cfgask] != 0 ||
    [dict get $first cfgask_mapped] != 0 ||
    $reportedConfig eq "" || [file normalize $reportedConfig] ne $firstConfig} {
    error "first-run probe failed: $first"
}

# Old releases offered %LOCALAPPDATA%\els as a settings location.  A packaged
# executable must now ignore that profile state completely: it may neither load,
# migrate, rewrite, nor delete the old file.  Seed a tempting saved session and
# verify both process behavior and byte/mtime preservation.
set profileApp [file join $BASE profile-ignore]
if {[file exists $profileApp]} { error "unique profile probe directory already exists: $profileApp" }
file mkdir $profileApp
file copy -force $SRC [file join $profileApp els.exe]
set profileDoc [file normalize [file join $profileApp profile-only.txt]]
write_file $profileDoc "must not be restored\n"
set profileBytes [dict create geometry 713x517 recent [list $profileDoc] \
    word_wrap 1 restore_session 1 session_files [list $profileDoc] \
    session_active $profileDoc]
set profileConfig [file join $profileApp localappdata els els.conf]
write_file $profileConfig $profileBytes
set profileStamp [expr {[clock seconds] - 7200}]
file mtime $profileConfig $profileStamp
set profileRun [launch_probe $profileApp]
set adjacentConfig [file normalize [file join $profileApp els.conf]]
if {[file normalize [dict get $profileRun config]] ne $adjacentConfig ||
    $profileDoc in [dict get $profileRun paths] ||
    [dict get $profileRun active_path] eq $profileDoc ||
    [read_file $profileConfig] ne $profileBytes ||
    [file mtime $profileConfig] != $profileStamp} {
    error "profile config was loaded or changed: $profileRun"
}
puts "profile config probe ok (ignored and untouched)"

# The forbidden profile lookup is distinct from the supported adjacent-name
# migration.  A legacy config.tcl beside the exe is copied to adjacent els.conf,
# remains intact itself, and still restores its session.
set adjacentApp [file join $BASE adjacent-legacy]
set adjacentDoc [file normalize [file join $adjacentApp adjacent.txt]]
set adjacentBytes [dict create geometry 800x600 recent {} word_wrap 0 \
    restore_session 1 session_files [list $adjacentDoc] session_active $adjacentDoc]
set adjacentRun [run_probe adjacent-legacy $SRC "" \
    [list config.tcl $adjacentBytes adjacent.txt "adjacent migration\n"]]
set migratedConfig [file normalize [file join $adjacentApp els.conf]]
if {[file normalize [dict get $adjacentRun config]] ne $migratedConfig ||
    [dict get $adjacentRun active_path] ne $adjacentDoc ||
    [read_file [file join $adjacentApp config.tcl]] ne $adjacentBytes ||
    [read_file $migratedConfig] ne $adjacentBytes} {
    error "adjacent config.tcl migration failed: $adjacentRun"
}
puts "adjacent config migration probe ok"

set app2 [file join $BASE restore]
set p1 [file normalize [file join $app2 one.txt]]
set p2 [file normalize [file join $app2 two.txt]]
set miss [file normalize [file join $app2 missing.txt]]
set conf [dict create geometry 800x600 recent {} word_wrap 0 \
    restore_session 1 session_files [list $p1 $miss $p2] session_active $p2]
set restore [run_probe restore $SRC $conf [list one.txt "one\n" two.txt "two\n"]]
if {[dict get $restore cfgask] != 0 ||
    [dict get $restore docs] != 2 ||
    [file tail [dict get $restore active_path]] ne "two.txt"} {
    error "restore probe failed: $restore"
}

set app3 [file join $BASE explicit]
set previous [file normalize [file join $app3 previous.txt]]
set explicit [file normalize [file join $app3 explicit.txt]]
set conf [dict create geometry 800x600 recent {} word_wrap 0 \
    restore_session 1 session_files [list $previous] session_active $previous]
set explicitRun [run_probe explicit $SRC $conf \
    [list previous.txt "previous\n" explicit.txt "explicit\n"] [list $explicit]]
if {[dict get $explicitRun cfgask] != 0 ||
    [dict get $explicitRun docs] != 1 ||
    [file tail [dict get $explicitRun active_path]] ne "explicit.txt"} {
    error "explicit-arg probe failed: $explicitRun"
}

if {![cleanup_probe_root $BASE]} {
    puts stderr "warning: could not remove unique exe probe scratch directory: $BASE"
}
puts "exe probe ok"
