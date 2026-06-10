#!/usr/bin/env tclsh
# tools/shot.tcl — launch a Tk app and screenshot ITS window to PNG, robustly.
#
# Window-finding via twapi (by PID); the capture is the cap extension's
# PrintWindow (occlusion-proof) -> a DIB, converted to PNG here.  No clipboard,
# no foreground, no Snipping-Tool, no full-screen crop — it grabs only the one
# window, even if covered or in the background.
#
#   tclsh90.exe tools/shot.tcl <wish.exe> <els.tcl> <out.png> [file ...]
#   tclsh90.exe tools/shot.tcl <els.exe> - <out.png> [file ...]   # single-exe
#   tclsh90.exe tools/shot.tcl --selftest        ;# headless converter checks
#
# Set ELS_SHOT_TITLE to capture a specific toplevel/dialog by title.
#
# Requires build/cap.dll (`x build-ext`).

package require Tk
wm withdraw .

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ::SHOT_ROOT [script_root]
if {[info exists ::env(ELS_TWAPI_DIR)] && $::env(ELS_TWAPI_DIR) ne ""} {
    lappend auto_path $::env(ELS_TWAPI_DIR)
} else {
    lappend auto_path [file join $::SHOT_ROOT .toolchain twapi-dl]
}

# ---- DIB (CF_DIB / BITMAPINFOHEADER) -> Tk photo ------------------------
# Handles the uncompressed 24/32-bpp DIBs that a screen capture produces.
proc dib_to_photo {dib} {
    binary scan $dib iiissiiiiii \
        biSize biWidth biHeight biPlanes biBitCount biCompression \
        biSizeImage bppmX bppmY biClrUsed biClrImportant
    set width  $biWidth
    set height [expr {abs($biHeight)}]
    set topDown [expr {$biHeight < 0}]
    set bpp [expr {$biBitCount & 0xffff}]
    if {$bpp != 24 && $bpp != 32} {
        error "unsupported DIB bit depth: $bpp (need 24 or 32)"
    }
    if {$biCompression != 0 && $biCompression != 3} {
        error "unsupported DIB compression: $biCompression (need BI_RGB or BI_BITFIELDS)"
    }
    set bytesPP [expr {$bpp / 8}]
    set rowStride [expr {(($width * $bpp + 31) / 32) * 4}]
    set maskBytes [expr {$biCompression == 3 ? 12 : 0}]
    set pixelStart [expr {$biSize + ($biClrUsed * 4) + $maskBytes}]

    # Build a binary P6 PPM (top-down RGB), which Tk's photo reads natively.
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
    set ppm [join $rows ""]

    set tmp [file join [::shot_tmpdir] _shot_[pid].ppm]
    set fh [::open $tmp w]
    try {
        fconfigure $fh -translation binary
        puts -nonewline $fh $ppm
    } finally {
        close $fh
    }
    # always remove the scratch PPM, even if Tk fails to read it back
    try {
        set img [image create photo -file $tmp]
    } finally {
        file delete -force $tmp
    }
    return $img
}

# a writable scratch dir (overridable); avoids assuming cwd
proc ::shot_tmpdir {} {
    if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { return $::env(TEMP) }
    return $::SHOT_ROOT
}

# ---- live capture -------------------------------------------------------
proc els_window_for_pid {pid timeoutMs {title ""}} {
    set deadline [expr {[clock milliseconds] + $timeoutMs}]
    while {[clock milliseconds] < $deadline} {
        foreach hwin [twapi::find_windows -toplevel 1 -visible 1] {
            if {[catch {twapi::get_window_process $hwin} wp]} { continue }
            if {$wp != $pid} { continue }
            if {$title eq ""} { return $hwin }
            if {[catch {twapi::get_window_text $hwin} wt]} { continue }
            if {$wt eq $title || [string match $title $wt]} { return $hwin }
        }
        after 120
    }
    return ""
}

# A twapi handle is a {address TYPE} list (e.g. {5900116 HWND}); elscap::window
# wants the integer address.
proc hwnd_int {h} {
    set a [lindex $h 0]
    if {[regexp {(0x[0-9a-fA-F]+|[0-9]+)} $a -> n]} { return $n }
    return $a
}

proc main {argv} {
    if {[lindex $argv 0] eq "--selftest"} { selftest ; return }
    package require twapi
    load [file join $::SHOT_ROOT build cap.dll] Cap

    lassign $argv app script out
    set files [lrange $argv 3 end]
    if {$app eq "" || $script eq "" || $out eq ""} {
        puts stderr "usage: shot.tcl <wish.exe> <els.tcl> <out.png> \[file ...\]"
        puts stderr "       shot.tcl <els.exe> - <out.png> \[file ...\]   ;# single-exe"
        exit 2
    }
    # the shot target must be OUR OWN spawned instance: without the opt-out,
    # single-instance would hand the files to (and raise) the user's running
    # els, and the window-by-pid wait below would time out on a dead process
    set ::env(ELS_NO_SINGLE_INSTANCE) 1
    if {$script eq "-"} {
        set pid [exec $app {*}$files &]            ;# self-contained els.exe
    } else {
        set pid [exec $app $script {*}$files &]    ;# wish + els.tcl
    }
    set title [expr {[info exists ::env(ELS_SHOT_TITLE)] ? $::env(ELS_SHOT_TITLE) : ""}]
    set hwin [els_window_for_pid $pid 12000 $title]
    if {$hwin eq ""} {
        catch {twapi::end_process $pid -force}
        puts stderr "window for pid $pid never appeared"
        exit 3
    }
    after 700                     ;# let Tk finish painting
    # PrintWindow the target directly — occlusion-proof, no foreground needed.
    # Whatever happens during capture/convert/write, always close the window we
    # spawned so a failure can't leave an orphaned els process behind.
    try {
        set img [dib_to_photo [elscap::window [hwnd_int $hwin]]]
        $img write $out -format png
        puts "wrote $out ([image width $img]x[image height $img])"
    } finally {
        catch {twapi::send_message $hwin 0x10 0 0}   ;# WM_CLOSE
        after 400
        catch {twapi::end_process $pid -force}
    }
}

# ---- headless converter self-test (no capture, no focus steal) ----------
proc make_dib {width height bpp pixels} {
    # pixels: flat list of {b g r ...} bottom-up rows already laid out top-down;
    # we store them bottom-up.  Each pixel is bytesPP bytes (BGRA or BGR).
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

proc selftest {} {
    set fails 0
    # 3x2, 32bpp, known colours (top-down logical): row0 R,G,B ; row1 W,K,gray
    # pixel bytes are BGRA
    set px {
        0 0 255 0   0 255 0 0   255 0 0 0
        255 255 255 0   0 0 0 0   128 128 128 0
    }
    set dib [make_dib 3 2 32 $px]
    set img [dib_to_photo $dib]
    foreach {x y want} {0 0 {255 0 0}  1 0 {0 255 0}  2 0 {0 0 255}
                        0 1 {255 255 255}  1 1 {0 0 0}  2 1 {128 128 128}} {
        set got [$img get $x $y]
        # photo get may return 4 (RGBA) elements in Tk 9; compare first 3
        set got [lrange $got 0 2]
        if {$got ne $want} {
            puts "FAIL 32bpp ($x,$y): got {$got} want {$want}"; incr fails
        }
    }
    puts "32bpp dims = [image width $img]x[image height $img] (want 3x2)"
    if {[image width $img] != 3 || [image height $img] != 2} { incr fails }
    image delete $img

    # 24bpp variant (no alpha): same colours
    set px24 {
        0 0 255   0 255 0   255 0 0
        255 255 255   0 0 0   128 128 128
    }
    set dib24 [make_dib 3 2 24 $px24]
    set img24 [dib_to_photo $dib24]
    if {[lrange [$img24 get 0 0] 0 2] ne {255 0 0}} { puts "FAIL 24bpp (0,0)"; incr fails }
    if {[lrange [$img24 get 2 1] 0 2] ne {128 128 128}} { puts "FAIL 24bpp (2,1)"; incr fails }
    image delete $img24

    # round-trip through PNG on disk
    set png [file join [::shot_tmpdir] _shot_selftest.png]
    set img2 [dib_to_photo $dib]
    $img2 write $png -format png
    set back [image create photo -file $png]
    if {[lrange [$back get 0 0] 0 2] ne {255 0 0}} { puts "FAIL png-roundtrip (0,0)"; incr fails }
    file delete -force $png
    image delete $img2 $back

    # speed: a realistic 1366x950 32bpp frame
    set row {}
    for {set x 0} {$x < 1366} {incr x} { lappend row [expr {$x & 255}] 64 128 0 }
    set big {}
    for {set y 0} {$y < 950} {incr y} { lappend big {*}$row }
    set dibBig [make_dib 1366 950 32 $big]
    set t0 [clock milliseconds]
    set imgBig [dib_to_photo $dibBig]
    set ms [expr {[clock milliseconds] - $t0}]
    puts "1366x950 32bpp convert = ${ms} ms, dims [image width $imgBig]x[image height $imgBig]"
    image delete $imgBig

    if {$fails == 0} {
        puts "shot.tcl converter selftest: OK"
        exit 0
    } else {
        puts "shot.tcl converter selftest: $fails FAILURE(S)"
        exit 1
    }
}

# Tk is loaded for the photo image, so we must exit explicitly — otherwise the
# interpreter falls into the Tk event loop and never terminates.
if {[catch {main $argv} err]} {
    puts stderr $err
    exit 1
}
exit 0
