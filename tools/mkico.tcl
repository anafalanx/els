#!/usr/bin/env tclsh
# tools/mkico.tcl -- pack PNG files into a standalone Windows .ico (PNG-compressed
# entries, supported by Windows Vista+ and read by windres into RT_ICON /
# RT_GROUP_ICON). Pure byte manipulation; runs under tclsh90 (no Tk needed).
#
#   tclsh90.exe tools/mkico.tcl out.ico in16.png in32.png in256.png ...
#
# Each PNG's dimensions are read from its IHDR; sizes >=256 are encoded as 0 in
# the directory entry (the .ico convention). Used by the native build to bake the
# awl into els.exe via src/els.rc.

proc png_dim {bytes} {
    # PNG IHDR: 8-byte signature, then length(4)+"IHDR"(4), then width(4 BE) at
    # offset 16 and height(4 BE) at offset 20.
    if {[string length $bytes] < 24 ||
        [binary encode hex [string range $bytes 0 7]] ne "89504e470d0a1a0a" ||
        [string range $bytes 12 15] ne "IHDR"} { error "not a valid PNG header" }
    binary scan $bytes "@16 Iu Iu" w h
    if {$w < 1 || $w > 256 || $h < 1 || $h > 256} {
        error "PNG dimensions are outside the ICO 1..256 range: ${w}x${h}"
    }
    return [list $w $h]
}

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}

set out  [lindex $argv 0]
set pngs  [lrange $argv 1 end]
if {$out eq "" || ![llength $pngs]} {
    puts stderr "usage: mkico.tcl out.ico in.png \[in.png ...\]"
    exit 2
}
set root [script_root]
set build [file normalize [file join $root build]]
set out [file normalize $out]
set outKey [string tolower [string map {\\ /} $out]]
set buildKey [string trimright [string tolower [string map {\\ /} $build]] /]
if {[string first "$buildKey/" "$outKey/"] != 0 ||
    ![string equal -nocase [file extension $out] .ico]} {
    error "mkico output must be an .ico below $build: $out"
}
if {[catch {set parentType [dict get [file lstat [file dirname $out]] type]}] ||
    $parentType ne "directory"} {
    error "mkico output directory is missing or not a real directory: [file dirname $out]"
}
if {[file exists $out]} { error "mkico output already exists: $out" }

set n [llength $pngs]
set entries "" ; set blobs ""
set offset [expr {6 + 16 * $n}]          ;# ICONDIR(6) + n * ICONDIRENTRY(16)
foreach p $pngs {
    if {[catch {set inputType [dict get [file lstat $p] type]}] || $inputType ne "file"} {
        error "mkico input is missing or not a regular file: $p"
    }
    set fh [open $p rb]
    try { fconfigure $fh -translation binary; set png [read $fh] } finally { close $fh }
    lassign [png_dim $png] w h
    set bw [expr {$w >= 256 ? 0 : $w}]
    set bh [expr {$h >= 256 ? 0 : $h}]
    set len [string length $png]
    # ICONDIRENTRY: bWidth bHeight bColorCount bReserved wPlanes wBitCount
    #               dwBytesInRes dwImageOffset  (little-endian)
    append entries [binary format "ccccssii" $bw $bh 0 0 1 32 $len $offset]
    append blobs $png
    incr offset $len
}
# ICONDIR: idReserved=0, idType=1 (icon), idCount=n  (little-endian)
set ico [binary format "sss" 0 1 $n]
append ico $entries $blobs

set fh [open $out {WRONLY CREAT EXCL BINARY}]
try {
    puts -nonewline $fh $ico
} finally { close $fh }
puts "wrote [file nativename $out] ($n image(s), [file size $out] bytes)"
