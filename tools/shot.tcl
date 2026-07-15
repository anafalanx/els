#!/usr/bin/env tclsh
# tools/shot.tcl -- invisible Tk screenshot controller and DIB converter.
#
# The controller never launches a Tk window on the interactive desktop.  Its
# native helper creates a private Win32 desktop (never SwitchDesktop), starts a
# kill-on-close child there, and waits with a hard timeout.  The child lets Tk
# map/focus/paint normally on that private desktop, captures its own HWND with
# PrintWindow, writes the PNG, and exits.  Foreground HWND equality is verified
# across both capture and the complete child lifetime.
#
#   tclsh90.exe tools/shot.tcl <wish.exe> <els.tcl> <out.png> [file ...]
#   tclsh90.exe tools/shot.tcl --selftest <wish.exe>
#
# Set ELS_SHOT_TITLE to require a specific target-window title.  A staged scene
# may set ::ELS_SHOT_TARGET (Tk path) and ::ELS_SHOT_READY to signal completion.

# Deliberately do not `package require Tk` in this controller.  It runs on the
# interactive desktop, and even an immediately-withdrawn Tk root would weaken
# the guarantee that screenshot tooling creates no interactive-desktop window.
# The private child is Wish and supplies the Tk commands used below.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ::SHOT_ROOT [script_root]

proc ::shot_tmpdir {} {
    set d [file join $::SHOT_ROOT build]
    file mkdir $d
    return $d
}

# ---- DIB (BITMAPINFOHEADER) -> Tk photo --------------------------------
proc dib_to_photo {dib} {
    if {![llength [info commands image]]} {
        error "DIB conversion requires Tk in the private screenshot child"
    }
    if {[string length $dib] < 40} { error "DIB is shorter than BITMAPINFOHEADER" }
    binary scan $dib iiissiiiiii \
        biSize biWidth biHeight biPlanes biBitCount biCompression \
        biSizeImage bppmX bppmY biClrUsed biClrImportant
    set width $biWidth
    set height [expr {abs($biHeight)}]
    set topDown [expr {$biHeight < 0}]
    set bpp [expr {$biBitCount & 0xffff}]
    if {$width < 1 || $height < 1 || $width > 16384 || $height > 16384} {
        error "invalid DIB dimensions: ${width}x${height}"
    }
    if {$bpp ni {24 32}} { error "unsupported DIB bit depth: $bpp" }
    if {$biCompression ni {0 3}} { error "unsupported DIB compression: $biCompression" }
    set bytesPP [expr {$bpp / 8}]
    set rowStride [expr {(($width * $bpp + 31) / 32) * 4}]
    set maskBytes [expr {$biCompression == 3 ? 12 : 0}]
    set pixelStart [expr {$biSize + ($biClrUsed * 4) + $maskBytes}]
    set required [expr {$pixelStart + $rowStride * $height}]
    if {[string length $dib] < $required} { error "DIB pixel payload is truncated" }

    set rows [list "P6\n$width $height\n255\n"]
    set rowLen [expr {$width * $bytesPP}]
    for {set oy 0} {$oy < $height} {incr oy} {
        set sy [expr {$topDown ? $oy : $height - 1 - $oy}]
        set off [expr {$pixelStart + $sy * $rowStride}]
        binary scan [string range $dib $off [expr {$off + $rowLen - 1}]] cu* bs
        set rgb {}
        if {$bytesPP == 4} {
            foreach {b g r a} $bs { lappend rgb $r $g $b }
        } else {
            foreach {b g r} $bs { lappend rgb $r $g $b }
        }
        lappend rows [binary format c* $rgb]
    }
    set tmp [file join [::shot_tmpdir] "_shot_[pid]_[clock clicks].ppm"]
    set fh [::open $tmp {WRONLY CREAT EXCL}]
    try {
        fconfigure $fh -translation binary
        puts -nonewline $fh [join $rows ""]
    } finally {
        close $fh
    }
    try {
        set img [image create photo -file $tmp]
    } finally {
        file delete -force -- $tmp
    }
    return $img
}

proc shot_image_stats {img} {
    set width [image width $img]
    set height [image height $img]
    set gx [expr {min(24, $width)}]
    set gy [expr {min(18, $height)}]
    set colors {}
    set black 0
    set total 0
    for {set iy 0} {$iy < $gy} {incr iy} {
        set y [expr {$gy == 1 ? 0 : ($iy * ($height - 1)) / ($gy - 1)}]
        for {set ix 0} {$ix < $gx} {incr ix} {
            set x [expr {$gx == 1 ? 0 : ($ix * ($width - 1)) / ($gx - 1)}]
            set rgb [lrange [$img get $x $y] 0 2]
            dict set colors $rgb 1
            if {[lindex $rgb 0] < 8 && [lindex $rgb 1] < 8 && [lindex $rgb 2] < 8} {
                incr black
            }
            incr total
        }
    }
    set unique [dict size $colors]
    if {$unique < 4} {
        error "captured private-desktop image is visually empty ($unique sampled colors)"
    }
    if {$black * 10 >= $total * 9} {
        error "captured private-desktop image is predominantly black ($black/$total samples)"
    }
    return [dict create sample_unique $unique sample_black $black sample_total $total]
}

proc png_dimensions {path} {
    if {![file isfile $path]} { error "private screenshot PNG is missing" }
    set fh [::open $path r]
    try {
        fconfigure $fh -translation binary
        set header [read $fh 24]
    } finally {
        close $fh
    }
    if {[string length $header] != 24
            || [binary encode hex [string range $header 0 7]] ne "89504e470d0a1a0a"} {
        error "private screenshot output is not a PNG"
    }
    if {[binary scan $header @12a4IuIu chunk width height] != 3
            || $chunk ne "IHDR" || $width < 1 || $height < 1} {
        error "private screenshot PNG has an invalid IHDR"
    }
    return [list $width $height]
}

proc shot_write_status {path values} {
    set payload [dict merge [dict create protocol els-private-shot-v1] $values]
    set temp "$path.[pid].[clock clicks].tmp"
    set fh [::open $temp {WRONLY CREAT EXCL}]
    try {
        fconfigure $fh -encoding utf-8 -profile replace -translation lf
        puts $fh $payload
    } finally {
        close $fh
    }
    file rename -force -- $temp $path
}

proc shot_read_status {path} {
    if {![file isfile $path]} { error "private screenshot child wrote no status record" }
    set fh [::open $path r]
    try {
        fconfigure $fh -encoding utf-8 -profile strict -translation lf
        set payload [read $fh 16385]
    } finally {
        close $fh
    }
    if {[string length $payload] > 16384 || [catch {dict size $payload}]} {
        error "private screenshot status is malformed"
    }
    if {![dict exists $payload protocol] || [dict get $payload protocol] ne "els-private-shot-v1"} {
        error "private screenshot status has the wrong protocol"
    }
    return $payload
}

proc shot_wait_ready {timeoutMs} {
    if {[info exists ::ELS_SHOT_READY] && $::ELS_SHOT_READY} { return }
    set ::_shot_waiting ""
    set deadline [expr {[clock milliseconds] + $timeoutMs}]
    proc ::_shot_ready_poll {deadline} {
        if {[info exists ::ELS_SHOT_READY] && $::ELS_SHOT_READY} {
            set ::_shot_waiting ready
        } elseif {[clock milliseconds] >= $deadline} {
            set ::_shot_waiting timeout
        } else {
            after 20 [list ::_shot_ready_poll $deadline]
        }
    }
    after 0 [list ::_shot_ready_poll $deadline]
    vwait ::_shot_waiting
    set result $::_shot_waiting
    unset -nocomplain ::_shot_waiting
    rename ::_shot_ready_poll {}
    if {$result ne "ready"} { error "Tk scene did not become ready within $timeoutMs ms" }
}

# Called only by tools/private_shot.tcl inside the private-desktop Wish child.
proc shot_private_capture {script out status expectedTitle files} {
    load [file join $::SHOT_ROOT build cap.dll] Cap
    set ::env(ELS_NO_SINGLE_INSTANCE) 1
    unset -nocomplain ::ELS_SHOT_READY ::ELS_SHOT_TARGET
    set ::argv $files
    set ::argv0 $script
    # A main script normally runs at global scope.  Preserve that contract: in
    # particular, scripts conventionally read unqualified $argv, which would
    # otherwise resolve in this procedure's local frame and be missing.
    uplevel #0 [list source $script]

    # README scenes signal after their exact staged state is laid out.  An
    # ordinary z shot has no staging contract, so allow startup/session work a
    # short, deterministic settling interval and then use the main toplevel.
    if {[info exists ::env(ELS_SHOT_STAGED)] && $::env(ELS_SHOT_STAGED) eq "1"} {
        shot_wait_ready 12000
    } else {
        set ::_shot_settled 0
        after 1200 {set ::_shot_settled 1}
        vwait ::_shot_settled
        unset ::_shot_settled
        set ::ELS_SHOT_TARGET .
    }
    set target [expr {[info exists ::ELS_SHOT_TARGET] ? $::ELS_SHOT_TARGET : "."}]
    if {![winfo exists $target]} { error "staged Tk target does not exist: $target" }
    update idletasks
    set ::_shot_painted 0
    after 250 {set ::_shot_painted 1}
    vwait ::_shot_painted
    unset ::_shot_painted
    update idletasks
    update
    if {![winfo ismapped $target]} { error "staged Tk target is not mapped on the private desktop" }
    if {$expectedTitle ne "" && [wm title $target] ne $expectedTitle} {
        error "staged target title is '[wm title $target]', expected '$expectedTitle'"
    }

    set dib [elscap::window [wm frame $target]]
    set img [dib_to_photo $dib]
    try {
        set width [image width $img]
        set height [image height $img]
        if {$width < 100 || $height < 100} {
            error "captured private-desktop image is unexpectedly small: ${width}x${height}"
        }
        set stats [shot_image_stats $img]
        file mkdir [file dirname $out]
        $img write $out -format png
    } finally {
        image delete $img
    }
    shot_write_status $status [dict merge \
        [dict create status ok width $width height $height target $target \
            title [wm title $target] bytes [file size $out]] $stats]
    catch {els::swap_shutdown}
}

proc shot_private_entry {argv} {
    if {[llength $argv] != 5} {
        error "private child usage: <script> <out> <status> <title> <file-list>"
    }
    lassign $argv script out status title files
    set rc [catch {shot_private_capture $script $out $status $title $files} err opts]
    if {$rc} {
        catch {shot_write_status $status [dict create status error message [string range $err 0 8191]]}
        catch {els::swap_shutdown}
        catch {destroy .}
        exit 1
    }
    catch {destroy .}
    exit 0
}

proc shot_run_private {wish script out files {expectedTitle ""} {timeout 30000}} {
    load [file join $::SHOT_ROOT build cap.dll] Cap
    set script [file normalize $script]
    set out [file normalize $out]
    file mkdir [file dirname $out]
    set status [file join [::shot_tmpdir] "_shot_status_[pid]_[clock clicks].tcl"]
    set stage [file join [file dirname $out] \
        ".[file tail $out].[pid].[clock clicks].private-shot.png"]
    file delete -force -- $status $stage
    set foreground [elscap::foreground]
    set child [file join $::SHOT_ROOT tools private_shot.tcl]
    try {
        set runRc [catch {
            elscap::run_private $timeout $wish $child $script $stage $status $expectedTitle $files
        } runResult runOpts]
        set statusResult ""
        set statusError ""
        if {[file isfile $status]} {
            if {[catch {set statusResult [shot_read_status $status]} statusError]} {
                set statusResult ""
            }
        }
        if {$runRc} {
            if {$statusResult ne "" && [dict exists $statusResult message]} {
                append runResult ": " [dict get $statusResult message]
            } elseif {$statusError ne ""} {
                append runResult ": " $statusError
            }
            return -options $runOpts $runResult
        }
        if {[elscap::foreground] != $foreground} {
            error "foreground HWND changed across private screenshot controller"
        }
        if {$statusResult eq "" || ![dict exists $statusResult status]
                || [dict get $statusResult status] ne "ok"} {
            error "private screenshot child did not report success"
        }
        set keys [lsort [dict keys $statusResult]]
        if {$keys ne {bytes height protocol sample_black sample_total sample_unique status target title width}} {
            error "private screenshot success record has the wrong schema"
        }
        foreach key {bytes height sample_black sample_total sample_unique width} {
            if {![string is integer -strict [dict get $statusResult $key]]
                    || [dict get $statusResult $key] < 0} {
                error "private screenshot success record has an invalid $key"
            }
        }
        lassign [png_dimensions $stage] pngWidth pngHeight
        if {$pngWidth != [dict get $statusResult width]
                || $pngHeight != [dict get $statusResult height]
                || [file size $stage] != [dict get $statusResult bytes]} {
            error "private screenshot PNG disagrees with child status"
        }
        file rename -force -- $stage $out
        return $statusResult
    } finally {
        file delete -force -- $status $stage
    }
}

# ---- tests --------------------------------------------------------------
proc make_dib {width height bpp pixels} {
    set bytesPP [expr {$bpp / 8}]
    set rowStride [expr {(($width * $bpp + 31) / 32) * 4}]
    set pad [expr {$rowStride - $width * $bytesPP}]
    set hdr [binary format iiissiiiiii 40 $width $height 1 $bpp 0 0 2835 2835 0 0]
    set body ""
    for {set y [expr {$height - 1}]} {$y >= 0} {incr y -1} {
        for {set x 0} {$x < $width} {incr x} {
            set i [expr {($y * $width + $x) * $bytesPP}]
            append body [binary format c* [lrange $pixels $i [expr {$i + $bytesPP - 1}]]]
        }
        if {$pad > 0} { append body [binary format x$pad] }
    }
    return $hdr$body
}

proc shot_selftest {wish} {
    if {$wish eq ""} { error "selftest requires wish.exe" }
    set token "[pid]_[clock clicks]"
    set scene [file join [::shot_tmpdir] "_private scene $token.tcl"]
    set hang [file join [::shot_tmpdir] "_private hang $token.tcl"]
    set png [file join [::shot_tmpdir] "_private proof $token.png"]
    set preserve [file join [::shot_tmpdir] "_private preserve $token.png"]
    set fh [::open $scene {WRONLY CREAT EXCL}]
    try {
        fconfigure $fh -encoding utf-8 -translation lf
        puts $fh {
package require Tk
set px {
    0 0 255 0   0 255 0 0   255 0 0 0
    255 255 255 0   0 0 0 0   128 128 128 0
}
set testImage [dib_to_photo [make_dib 3 2 32 $px]]
try {
    foreach {x y want} {0 0 {255 0 0} 1 0 {0 255 0} 2 0 {0 0 255}
                        0 1 {255 255 255} 1 1 {0 0 0} 2 1 {128 128 128}} {
        if {[lrange [$testImage get $x $y] 0 2] ne $want} {
            error "DIB converter mismatch at $x,$y"
        }
    }
} finally {
    image delete $testImage
}
wm title . "private desktop proof"
wm geometry . 420x240+30+30
frame .f -bg #24577a
label .f.l -text "private desktop" -bg #24577a -fg white
pack .f.l -expand 1
pack .f -expand 1 -fill both
set ::ELS_SHOT_TARGET .
set ::ELS_SHOT_READY 1
}
    } finally { close $fh }
    set fh [::open $hang {WRONLY CREAT EXCL}]
    try {
        fconfigure $fh -encoding utf-8 -translation lf
        puts $fh {package require Tk
wm title . "private timeout proof"
vwait ::PRIVATE_SHOT_NEVER_SET}
    } finally { close $fh }
    set hadStaged [info exists ::env(ELS_SHOT_STAGED)]
    if {$hadStaged} { set oldStaged $::env(ELS_SHOT_STAGED) }
    set ::env(ELS_SHOT_STAGED) 1
    try {
        set before [elscap::foreground]
        set timeoutRc [catch {elscap::run_private 350 $wish $hang} timeoutError]
        if {!$timeoutRc || ![string match "*timed out*" $timeoutError]} {
            error "private desktop timeout/cleanup proof failed: $timeoutError"
        }
        if {[elscap::foreground] != $before} { error "private timeout proof changed foreground" }
        puts "private desktop timeout cleanup = OK"
        set result [shot_run_private $wish $scene $png {} "private desktop proof" 20000]
        if {[elscap::foreground] != $before} { error "private desktop selftest changed foreground" }
        lassign [png_dimensions $png] width height
        if {$width < 420 || $height < 240} { error "private desktop proof image is too small" }
        puts "private desktop capture = OK ([dict get $result width]x[dict get $result height], foreground $before unchanged)"

        set fh [::open $preserve {WRONLY CREAT EXCL}]
        try {
            fconfigure $fh -translation binary
            puts -nonewline $fh "existing destination"
        } finally { close $fh }
        if {![catch {shot_run_private $wish $scene $preserve {} "deliberately wrong title" 20000}]} {
            error "a failed private capture unexpectedly reported success"
        }
        set fh [::open $preserve r]
        try {
            fconfigure $fh -translation binary
            set preserved [read $fh]
        } finally { close $fh }
        if {$preserved ne "existing destination"} {
            error "a failed private capture replaced its existing destination"
        }
        puts "failed-capture destination preservation = OK"
    } finally {
        if {$hadStaged} { set ::env(ELS_SHOT_STAGED) $oldStaged } else { unset -nocomplain ::env(ELS_SHOT_STAGED) }
        file delete -force -- $scene $hang $png $preserve
    }
    if {![catch {elscap::run_private 99 $wish}]} { error "run_private accepted an invalid timeout" }
    if {![catch {elscap::run_private 1000 $wish "bad\u0000argument"} nulError]
            || ![string match "*NUL*" $nulError]} {
        error "run_private did not reject an embedded NUL: $nulError"
    }
    if {![catch {elscap::run_private 1000 $wish [string repeat x 32767]} longError]
            || ![string match "*exceeds*" $longError]} {
        error "run_private did not reject an oversized command line: $longError"
    }
    if {![catch {elscap::foreground unexpected}]} { error "foreground accepted an argument" }
    puts "private child argument validation = OK"
    puts "shot.tcl selftest: OK"
}

proc main {argv} {
    load [file join $::SHOT_ROOT build cap.dll] Cap
    if {[lindex $argv 0] eq "--selftest"} {
        if {[llength $argv] != 2} { error "usage: shot.tcl --selftest <wish.exe>" }
        shot_selftest [lindex $argv 1]
        return
    }
    lassign $argv wish script out
    set files [lrange $argv 3 end]
    if {$wish eq "" || $script eq "" || $out eq ""} {
        error "usage: shot.tcl <wish.exe> <els.tcl> <out.png> \[file ...\]"
    }
    set ::env(ELS_NO_SINGLE_INSTANCE) 1
    set expectedTitle [expr {[info exists ::env(ELS_SHOT_TITLE)] ? $::env(ELS_SHOT_TITLE) : ""}]
    set result [shot_run_private $wish $script $out $files $expectedTitle]
    puts "wrote [file normalize $out] ([dict get $result width]x[dict get $result height]) on a private desktop; foreground unchanged"
}

# When sourced by the private child this file is a library.  Only a direct
# controller invocation owns process exit.
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {main $argv} err opts]} {
        puts stderr $err
        exit 1
    }
    exit 0
}
