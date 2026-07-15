#!/usr/bin/env tclsh
# tools/pecheck.tcl -- dependency-free PE policy check for els release artifacts.
#
# Authenticode trust is verified separately by signtool.  This parser owns the
# structural policy that must remain independent of localized binutils output:
# AMD64/PE32+/GUI, ASLR+DEP+relocations, a constrained DLL import surface, the
# exact ID-1 manifest in every language, VERSIONINFO, icon resources, and the
# expected presence/absence of the certificate table.

proc fail {msg} {
    puts stderr "PE check failed: $msg"
    exit 1
}

proc byte_at {data off} {
    set off [expr {wide($off)}]
    if {$off < 0 || $off >= [string length $data]} {
        fail "byte at offset $off is beyond the file"
    }
    binary scan $data "@${off}c" value
    return [expr {$value & 0xff}]
}
proc u16le {data off} {
    return [expr {[byte_at $data $off] | ([byte_at $data [expr {$off + 1}]] << 8)}]
}
proc u32le {data off} {
    return [expr {wide([byte_at $data $off]) |
                  (wide([byte_at $data [expr {$off + 1}]]) << 8) |
                  (wide([byte_at $data [expr {$off + 2}]]) << 16) |
                  (wide([byte_at $data [expr {$off + 3}]]) << 24)}]
}
proc u32be {data off} {
    return [expr {(wide([byte_at $data $off]) << 24) |
                  (wide([byte_at $data [expr {$off + 1}]]) << 16) |
                  (wide([byte_at $data [expr {$off + 2}]]) << 8) |
                  wide([byte_at $data [expr {$off + 3}]])}]
}

proc rva_to_raw {data table sections rva bytes} {
    if {$bytes < 0} { fail "negative PE data size" }
    for {set i 0} {$i < $sections} {incr i} {
        set section [expr {$table + ($i * 40)}]
        set virtualSize [u32le $data [expr {$section + 8}]]
        set sectionRva [u32le $data [expr {$section + 12}]]
        set rawSize [u32le $data [expr {$section + 16}]]
        set raw [u32le $data [expr {$section + 20}]]
        set span [expr {max($virtualSize, $rawSize)}]
        if {$rva < $sectionRva || $rva >= $sectionRva + $span} continue
        set delta [expr {$rva - $sectionRva}]
        if {$delta + $bytes > $rawSize || $raw + $delta + $bytes > [string length $data]} {
            fail [format "RVA 0x%08x points outside section file data" $rva]
        }
        return [expr {$raw + $delta}]
    }
    fail [format "RVA 0x%08x is not mapped by a PE section" $rva]
}

proc data_directory {data opt optSize count index} {
    if {$index >= $count || 112 + (($index + 1) * 8) > $optSize} {
        fail "optional header does not expose required data-directory index $index"
    }
    set at [expr {$opt + 112 + ($index * 8)}]
    return [list [u32le $data $at] [u32le $data [expr {$at + 4}]]]
}

proc read_c_string {data raw {maxBytes 512}} {
    set end [expr {min([string length $data], $raw + $maxBytes)}]
    set out ""
    for {set i $raw} {$i < $end} {incr i} {
        set b [byte_at $data $i]
        if {$b == 0} { return $out }
        if {$b < 0x20 || $b > 0x7e} { fail "DLL name contains a non-ASCII byte" }
        append out [format %c $b]
    }
    fail "unterminated DLL name"
}

proc allowed_import {name} {
    set lower [string tolower $name]
    if {[regexp {^(api-ms-win|ext-ms-win)-[a-z0-9-]+\.dll$} $lower]} { return 1 }
    return [expr {$lower in {
        advapi32.dll comctl32.dll comdlg32.dll gdi32.dll imm32.dll kernel32.dll
        netapi32.dll ole32.dll oleaut32.dll shell32.dll user32.dll userenv.dll
        winspool.drv ws2_32.dll ucrtbase.dll
    }}]
}

proc pe_imports {data opt optSize directoryCount table sections} {
    set imports {}
    foreach {index descriptorSize nameOffset label} {
        1 20 12 import
        13 32 4 delay-import
    } {
        lassign [data_directory $data $opt $optSize $directoryCount $index] rva size
        if {$rva == 0 && $size == 0} continue
        if {$rva == 0 || $size < $descriptorSize} { fail "$label directory is malformed" }
        set max [expr {min(4096, ($size / $descriptorSize) + 1)}]
        set terminated 0
        for {set i 0} {$i < $max} {incr i} {
            set raw [rva_to_raw $data $table $sections [expr {$rva + ($i * $descriptorSize)}] $descriptorSize]
            set allZero 1
            for {set j 0} {$j < $descriptorSize} {incr j 4} {
                if {[u32le $data [expr {$raw + $j}]] != 0} { set allZero 0; break }
            }
            if {$allZero} { set terminated 1; break }
            if {$index == 13 && ([u32le $data $raw] & 1) == 0} {
                fail "delay-import descriptor uses VA fields instead of RVA fields"
            }
            set nameRva [u32le $data [expr {$raw + $nameOffset}]]
            if {$nameRva == 0} { fail "$label descriptor has no DLL name" }
            set name [read_c_string $data [rva_to_raw $data $table $sections $nameRva 1]]
            if {![allowed_import $name]} { fail "$label DLL is outside the Windows allowlist: $name" }
            lappend imports [string tolower $name]
        }
        if {!$terminated} { fail "$label descriptor table is not terminated" }
    }
    set imports [lsort -dictionary -unique $imports]
    foreach required {kernel32.dll user32.dll gdi32.dll} {
        if {$required ni $imports} { fail "required Windows import is absent: $required" }
    }
    return $imports
}

proc resource_name {data base limit offset} {
    set at [expr {$base + $offset}]
    if {$at < $base || $at + 2 > $limit} { fail "resource name points outside resource data" }
    set n [u16le $data $at]
    if {$at + 2 + (2 * $n) > $limit} { fail "resource name extends outside resource data" }
    set out ""
    for {set i 0} {$i < $n} {incr i} {
        append out [format %c [u16le $data [expr {$at + 2 + (2 * $i)}]]]
    }
    return $out
}

proc resource_entries {data base limit dirRel} {
    set dir [expr {$base + $dirRel}]
    if {$dir < $base || $dir + 16 > $limit} {
        fail "resource directory points outside the PE resource data"
    }
    set named [u16le $data [expr {$dir + 12}]]
    set ids [u16le $data [expr {$dir + 14}]]
    set count [expr {$named + $ids}]
    if {$dir + 16 + ($count * 8) > $limit} {
        fail "resource directory entries extend outside the PE resource data"
    }
    set result {}
    for {set i 0} {$i < $count} {incr i} {
        set entry [expr {$dir + 16 + ($i * 8)}]
        set rawName [u32le $data $entry]
        set rawTarget [u32le $data [expr {$entry + 4}]]
        if {$rawName & 0x80000000} {
            set kind name
            set value [resource_name $data $base $limit [expr {$rawName & 0x7fffffff}]]
        } else {
            if {$rawName > 0xffff} { fail "numeric resource ID exceeds 16 bits" }
            set kind id
            set value $rawName
        }
        lappend result [dict create kind $kind value $value \
            target [expr {$rawTarget & 0x7fffffff}] directory [expr {($rawTarget & 0x80000000) != 0}]]
    }
    return $result
}

proc resource_context {data opt optSize directoryCount table sections} {
    lassign [data_directory $data $opt $optSize $directoryCount 2] rva size
    if {$rva == 0 || $size < 16} { fail "PE resource data directory is absent" }
    set base [rva_to_raw $data $table $sections $rva $size]
    return [dict create data $data base $base limit [expr {$base + $size}] \
        table $table sections $sections]
}

proc resource_blobs {context typeId} {
    set data [dict get $context data]
    set base [dict get $context base]
    set limit [dict get $context limit]
    set table [dict get $context table]
    set sections [dict get $context sections]
    set types {}
    foreach entry [resource_entries $data $base $limit 0] {
        if {[dict get $entry kind] eq "id" && [dict get $entry value] == $typeId} { lappend types $entry }
    }
    if {[llength $types] == 0} { return {} }
    if {[llength $types] != 1 || ![dict get [lindex $types 0] directory]} {
        fail "resource type $typeId is duplicated or does not point to a directory"
    }
    set blobs {}
    foreach nameEntry [resource_entries $data $base $limit [dict get [lindex $types 0] target]] {
        if {![dict get $nameEntry directory]} { fail "resource type $typeId name is not a directory" }
        foreach langEntry [resource_entries $data $base $limit [dict get $nameEntry target]] {
            if {[dict get $langEntry directory]} { fail "resource type $typeId language points to a directory" }
            set de [expr {$base + [dict get $langEntry target]}]
            if {$de < $base || $de + 16 > $limit} { fail "resource type $typeId data entry is out of bounds" }
            set rva [u32le $data $de]
            set size [u32le $data [expr {$de + 4}]]
            if {$size == 0} { fail "resource type $typeId has an empty data blob" }
            set raw [rva_to_raw $data $table $sections $rva $size]
            lappend blobs [dict create \
                name_kind [dict get $nameEntry kind] name [dict get $nameEntry value] \
                lang_kind [dict get $langEntry kind] lang [dict get $langEntry value] \
                bytes [string range $data $raw [expr {$raw + $size - 1}]]]
        }
    }
    return $blobs
}

proc read_binary_file {path label} {
    if {[catch {set type [dict get [file lstat $path] type]}] || $type ne "file"} {
        fail "$label is missing or not a regular file: $path"
    }
    set fh [open $path r]
    try { fconfigure $fh -translation binary; return [read $fh] } finally { close $fh }
}

proc check_manifest {context expectedPath} {
    set blobs [resource_blobs $context 24]
    if {![llength $blobs]} { fail "RT_MANIFEST resource type 24 is absent" }
    set expected ""
    if {$expectedPath ne ""} { set expected [read_binary_file $expectedPath "generated manifest"] }
    set reference ""
    foreach blob $blobs {
        if {[dict get $blob name_kind] ne "id" || [dict get $blob name] != 1} {
            fail "RT_MANIFEST must contain only CREATEPROCESS_MANIFEST_RESOURCE_ID (1)"
        }
        set bytes [string trimright [dict get $blob bytes] "\x00"]
        if {$reference eq ""} { set reference $bytes } elseif {$bytes ne $reference} {
            fail "RT_MANIFEST language variants differ"
        }
        if {$expectedPath ne "" && $bytes ne [string trimright $expected "\x00"]} {
            fail "RT_MANIFEST bytes do not match the generated manifest input"
        }
    }
    foreach token {
        {requestedExecutionLevel level="asInvoker"}
        {<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>}
        {<longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>}
    } {
        if {[string first $token $reference] < 0} { fail "RT_MANIFEST lacks '$token'" }
    }
}

proc ascii_utf16le {text} {
    set bytes ""
    foreach char [split $text ""] {
        scan $char %c value
        if {$value > 0x7f} { fail "internal version policy token is not ASCII" }
        append bytes [binary format cc $value 0]
    }
    return $bytes
}

proc check_version_info {context version} {
    if {![regexp {^([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?$} $version -> a b c d]} {
        fail "--version must be a dotted numeric version"
    }
    if {$c eq ""} { set c 0 }; if {$d eq ""} { set d 0 }
    set expectedMS [expr {(wide($a) << 16) | wide($b)}]
    set expectedLS [expr {(wide($c) << 16) | wide($d)}]
    set blobs [resource_blobs $context 16]
    if {![llength $blobs]} { fail "VERSIONINFO resource type 16 is absent" }
    foreach blob $blobs {
        if {[dict get $blob name_kind] ne "id" || [dict get $blob name] != 1} {
            fail "VERSIONINFO must use numeric ID 1"
        }
        set bytes [dict get $blob bytes]
        set sig [string first "\xbd\x04\xef\xfe" $bytes]
        if {$sig < 0 || $sig + 16 > [string length $bytes]} { fail "VERSIONINFO lacks VS_FIXEDFILEINFO" }
        if {[u32le $bytes [expr {$sig + 8}]] != $expectedMS || [u32le $bytes [expr {$sig + 12}]] != $expectedLS} {
            fail "VERSIONINFO fixed file version does not match $version"
        }
        foreach token [list anafalanx {els} els.exe $version] {
            if {[string first [ascii_utf16le $token] $bytes] < 0} {
                fail "VERSIONINFO lacks '$token'"
            }
        }
    }
}

proc png_dimensions {bytes} {
    if {[string length $bytes] < 24 || [string range $bytes 0 7] ne "\x89PNG\r\n\x1a\n" ||
        [string range $bytes 12 15] ne "IHDR"} { fail "RT_ICON image is not a PNG" }
    return [list [u32be $bytes 16] [u32be $bytes 20]]
}

proc check_icons {context} {
    set groups [resource_blobs $context 14]
    set icons [resource_blobs $context 3]
    if {![llength $groups] || ![llength $icons]} { fail "RT_GROUP_ICON/RT_ICON resources are incomplete" }
    set reference ""
    set ids {}
    foreach group $groups {
        set bytes [dict get $group bytes]
        if {$reference eq ""} { set reference $bytes } elseif {$bytes ne $reference} {
            fail "RT_GROUP_ICON language variants differ"
        }
    }
    if {[string length $reference] < 6 || [u16le $reference 0] != 0 || [u16le $reference 2] != 1} {
        fail "RT_GROUP_ICON header is malformed"
    }
    set count [u16le $reference 4]
    if {$count != 3 || [string length $reference] < 6 + (14 * $count)} {
        fail "RT_GROUP_ICON must describe exactly three images"
    }
    set dimensions {}
    for {set i 0} {$i < $count} {incr i} {
        set at [expr {6 + (14 * $i)}]
        set w [byte_at $reference $at]; if {$w == 0} { set w 256 }
        set h [byte_at $reference [expr {$at + 1}]]; if {$h == 0} { set h 256 }
        lappend dimensions [list $w $h]
        lappend ids [u16le $reference [expr {$at + 12}]]
    }
    if {[lsort -integer -index 0 $dimensions] ne {{16 16} {32 32} {256 256}}} {
        fail "RT_GROUP_ICON dimensions are not 16, 32, and 256 pixels"
    }
    foreach id $ids {
        set found 0
        foreach icon $icons {
            if {[dict get $icon name_kind] eq "id" && [dict get $icon name] == $id} {
                set dims [png_dimensions [dict get $icon bytes]]
                if {$dims ni $dimensions} { fail "RT_ICON ID $id has an unexpected PNG size" }
                set found 1
            }
        }
        if {!$found} { fail "RT_GROUP_ICON references missing RT_ICON ID $id" }
    }
}

set mode --unsigned
set manifestPath ""
set version ""
set positional {}
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        --unsigned - --signed { set mode $arg }
        --manifest {
            incr i
            if {$i >= [llength $argv]} { fail "--manifest needs a path" }
            set manifestPath [file normalize [lindex $argv $i]]
        }
        --version {
            incr i
            if {$i >= [llength $argv]} { fail "--version needs a value" }
            set version [lindex $argv $i]
        }
        default {
            if {[string match -* $arg]} { fail "unknown option '$arg'" }
            lappend positional $arg
        }
    }
}
if {[llength $positional] != 1} {
    fail "usage: pecheck.tcl ?--unsigned|--signed? ?--manifest file? ?--version x.y.z? path/to/els.exe"
}
set path [file normalize [lindex $positional 0]]
set data [read_binary_file $path "PE image"]
set size [string length $data]
if {$size < 512} { fail "file is too small to be a PE image ($size bytes)" }
if {[string range $data 0 1] ne "MZ"} { fail "DOS MZ signature is missing" }
set pe [u32le $data 0x3c]
if {$pe < 64 || $pe + 264 > $size || [string range $data $pe [expr {$pe + 3}]] ne "PE\x00\x00"} {
    fail "PE signature/header offset is invalid"
}
set machine [u16le $data [expr {$pe + 4}]]
set sections [u16le $data [expr {$pe + 6}]]
set optSize [u16le $data [expr {$pe + 20}]]
set coffChars [u16le $data [expr {$pe + 22}]]
set opt [expr {$pe + 24}]
set table [expr {$opt + $optSize}]
if {$machine != 0x8664} { fail [format "machine is 0x%04x, expected AMD64" $machine] }
if {$sections < 1 || $table + (40 * $sections) > $size} { fail "PE section table is invalid" }
if {$optSize < 224 || [u16le $data $opt] != 0x20b} { fail "image is not a complete PE32+ image" }
set directoryCount [u32le $data [expr {$opt + 108}]]
if {$directoryCount < 14} { fail "optional header exposes only $directoryCount data directories" }
if {($coffChars & 0x0001) != 0} { fail "COFF RELOCS_STRIPPED flag is set" }
if {($coffChars & 0x0002) == 0 || ($coffChars & 0x0020) == 0} {
    fail "COFF executable/large-address-aware flags are incomplete"
}
set subsystem [u16le $data [expr {$opt + 68}]]
set dllChars [u16le $data [expr {$opt + 70}]]
if {$subsystem != 2} { fail "subsystem is $subsystem, expected Windows GUI (2)" }
foreach {bit label} {0x0020 HIGH_ENTROPY_VA 0x0040 DYNAMIC_BASE 0x0100 NX_COMPAT} {
    if {($dllChars & $bit) == 0} { fail "$label mitigation flag is absent" }
}
lassign [data_directory $data $opt $optSize $directoryCount 5] relocRva relocSize
if {$relocRva == 0 || $relocSize < 8} { fail "base-relocation directory is absent" }
rva_to_raw $data $table $sections $relocRva $relocSize

lassign [data_directory $data $opt $optSize $directoryCount 4] certOff certSize
if {$mode eq "--unsigned"} {
    if {$certOff != 0 || $certSize != 0} { fail "candidate already has an Authenticode certificate table" }
} else {
    if {$certOff == 0 || $certSize < 8 || ($certOff & 7) != 0 ||
        $certOff + $certSize != $size} {
        fail "signed candidate has no valid certificate table"
    }
}

set imports [pe_imports $data $opt $optSize $directoryCount $table $sections]
set context [resource_context $data $opt $optSize $directoryCount $table $sections]
check_manifest $context $manifestPath
if {$version ne ""} { check_version_info $context $version }
check_icons $context

puts [format "PE check ok: AMD64 GUI, mitigations=0x%04x, relocs=yes, imports=%d, resources=manifest/version/icon, certificate=%s, bytes=%d" \
    $dllChars [llength $imports] [expr {$mode eq "--signed" ? "present" : "absent"}] $size]
