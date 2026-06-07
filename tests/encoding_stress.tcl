# tests/encoding_stress.tcl — comprehensive, UI-driven encoding stress test.
#
# For ~34 sample files (one per encoding / BOM variant, in the right script) it
# drives the REAL els UI the way a user would — by generating <Button-1> events
# on the status-bar indicators and invoking the resulting menu entries — to:
#   1. open the file through File ▸ Open and record what detection chose;
#   2. REOPEN it under 7 encodings (≥4 deliberately wrong) via the encoding
#      picker, producing intentional mojibake;
#   3. SAVE the text into 5 deterministically-"random" other encodings via the
#      picker (Set Save Encoding), then re-open each garbled result and let
#      detection chew on the garbage.
# Every operation is timed; the goal is to prove els stays responsive and never
# hangs or crashes on garbled / mismatched data, and to report how it performs.
#
# Run:  x stress      (or:  tclsh90 tests/encoding_stress.tcl)
# Exits non-zero if any operation errors or exceeds the per-op time budget.

source [file join [file dirname [info script]] helpers.tcl]

set ::BUDGET_MS 2000           ;# any single UI op slower than this is a failure
                               ;# (real ops are ~40 ms; a true hang is seconds+)
set ::FAIL {}                  ;# collected failures
set ::DETECT {}                ;# detection report rows

foreach c {open reopen saveas savewith opengarble} {
    dict set ::T_count $c 0 ; dict set ::T_total $c 0
    dict set ::T_max $c 0   ; dict set ::T_maxlbl $c ""
}

proc timed {cat label body} {
    set t0 [clock microseconds]
    if {[catch {uplevel 1 $body} err opts]} {
        lappend ::FAIL "ERROR $cat \[$label]: $err"
        return -1
    }
    set us [expr {[clock microseconds] - $t0}]
    dict incr ::T_count $cat
    dict set ::T_total $cat [expr {[dict get $::T_total $cat] + $us}]
    if {$us > [dict get $::T_max $cat]} {
        dict set ::T_max $cat $us ; dict set ::T_maxlbl $cat $label
    }
    if {$us > $::BUDGET_MS * 1000} {
        lappend ::FAIL "SLOW $cat \[$label]: [expr {$us/1000}]ms > ${::BUDGET_MS}ms"
    }
    return $us
}

# ---- raw byte / BOM helpers ---------------------------------------------
proc wr {name bytes} {
    set p [file join $::ELS_TMP $name]
    set f [open $p w] ; fconfigure $f -translation binary
    puts -nonewline $f $bytes ; close $f ; return $p
}
proc bom_bytes {enc} {
    switch -- $enc {
        utf-8    { return "\xEF\xBB\xBF" }
        utf-16le { return "\xFF\xFE" }
        utf-16be { return "\xFE\xFF" }
        utf-32le { return "\xFF\xFE\x00\x00" }
        utf-32be { return "\x00\x00\xFE\xFF" }
    }
    return ""
}
proc rand_encs {n seed} {
    set all [encoding names] ; set out {} ; set s $seed
    while {[llength $out] < $n} {
        set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
        set e [lindex $all [expr {$s % [llength $all]}]]
        if {$e ni $out} { lappend out $e }
    }
    return $out
}

# ---- UI actions (generate events / invoke menus, as a user would) --------
proc ui_open {path} {
    set ::els_test_openfile $path
    .menu.file invoke "Open..."
    update
}
proc ui_saveas {path} {
    set ::els_test_savefile $path
    .menu.file invoke "Save As..."
    update
}
proc ui_pick {sub enc} {                 ;# sub = re | sv  (Reopen/Save submenu)
    event generate .sb.enc <ButtonPress-1> -x 5 -y 5   ;# real click → builds/posts picker
    catch {.encpop unpost} ; catch {grab release .encpop}
    .encpop.$sub.other invoke [.encpop.$sub.other index $enc]
    update
}

# ---- sample corpus: representative text per script ----------------------
set ::S(ascii)     "The quick brown fox jumps over the lazy dog. 0123456789!?\n"
set ::S(uni)       "Café — naïve Ωμέγα 日本語 한국어 ☺ €100 ½+¾ — Ωμέγα.\n"
set ::S(west)      "Café déjà vu, naïve façade — prix 100€, ½ litre, œuvre d'art.\n"
set ::S(west1)     "Café déjà vu, naïve façade, smörgåsbord; ¿señor? ¡Hola! ½.\n"
set ::S(central)   "Příliš žluťoučký kůň úpěl ďábelské ódy; Łódź, Gdańsk, Brno.\n"
set ::S(russian)   "Съешь же ещё этих мягких французских булок да выпей чаю.\n"
set ::S(greek)     "Ξεσκεπάζω την ψυχοφθόρα βδελυγμία· γειά σου κόσμε.\n"
set ::S(turkish)   "Pijamalı hasta yağız şoföre çabucak güvendi; İstanbul, İzmir.\n"
set ::S(hebrew)    "דג סקרן שט בים מאוכזב ולפתע מצא חברה.\n"
set ::S(arabic)    "نص حكيم له سر قاطع وذو شأن عظيم مكتوب على ثوب.\n"
set ::S(japanese)  "いろはにほへと ちりぬるを。日本語のエンコーディング試験です。\n"
set ::S(schinese)  "快速的棕色狐狸跳过懒狗。简体中文编码测试 12345。\n"
set ::S(tchinese)  "快速的棕色狐狸跳過懶狗。繁體中文編碼測試 12345。\n"
set ::S(korean)    "다람쥐 헌 쳇바퀴에 타고파. 한국어 인코딩 시험 12345.\n"
set ::S(ukrainian) "Жебракують філософи при ґанку церкви в Гадячі; їжа є.\n"
set ::S(thai)      "เป็นมนุษย์สุดประเสริฐเลิศคุณค่า กว่าบรรดาฝูงสัตว์เดรัจฉาน\n"

# samples: {label encoding bom scriptKey}
set ::SAMPLES {
    ascii          ascii      0 ascii
    utf-8          utf-8      0 uni
    utf-8-bom      utf-8      1 uni
    utf-16le-bom   utf-16le   1 uni
    utf-16be-bom   utf-16be   1 uni
    utf-16le-nobom utf-16le   0 uni
    utf-16be-nobom utf-16be   0 uni
    utf-32le-bom   utf-32le   1 uni
    utf-32be-bom   utf-32be   1 uni
    cp1252         cp1252     0 west
    iso8859-1      iso8859-1  0 west1
    iso8859-15     iso8859-15 0 west
    cp1250         cp1250     0 central
    iso8859-2      iso8859-2  0 central
    cp1251         cp1251     0 russian
    koi8-r         koi8-r     0 russian
    iso8859-5      iso8859-5  0 russian
    cp1253         cp1253     0 greek
    iso8859-7      iso8859-7  0 greek
    cp1254         cp1254     0 turkish
    iso8859-9      iso8859-9  0 turkish
    cp1255         cp1255     0 hebrew
    cp1256         cp1256     0 arabic
    cp932          cp932      0 japanese
    shiftjis       shiftjis   0 japanese
    euc-jp         euc-jp     0 japanese
    cp936          cp936      0 schinese
    gb2312         gb2312     0 schinese
    big5           big5       0 tchinese
    cp949          cp949      0 korean
    euc-kr         euc-kr     0 korean
    koi8-u         koi8-u     0 ukrainian
    tis-620        tis-620    0 thai
    cp874          cp874      0 thai
}

# 7 encodings to reopen each sample as (mostly wrong → mojibake)
set ::REOPEN_SET {utf-8 utf-16le utf-16be cp1252 cp1251 cp932 big5}

# The whole run, wrapped in a proc so the default suite (tests/stress.test) can
# invoke it and assert on the result; `x stress` runs it standalone (below).
# Returns the list of failures — empty means PASS.
proc els_stress_run {} {
    set ::FAIL {} ; set ::DETECT {}        ;# fresh accumulators for this run
    foreach c {open reopen saveas savewith opengarble} {
        dict set ::T_count $c 0 ; dict set ::T_total $c 0
        dict set ::T_max $c 0   ; dict set ::T_maxlbl $c ""
    }
    puts "=== els encoding stress (UI-driven: events + menu invoke) ==="
puts "detector: [expr {$::els::have_detect ? {ICU available} : {UNAVAILABLE (BOM/UTF-8/cp1252 only)}}]"
puts "samples: [expr {[llength $::SAMPLES]/4}]   reopen-as: [llength $::REOPEN_SET]/sample   save-as: 5/sample"
puts "per-op budget: ${::BUDGET_MS} ms\n"

# warm-up (untimed): run each UI path once so first-call JIT / DLL-load /
# menu-build costs don't skew the measured timings.
els_reset ; els::build_enc_popup ; els::build_eol_popup
set warm [wr _warm.txt [encoding convertto utf-8 "warm up\n"]]
ui_open $warm
ui_pick re utf-16le
ui_saveas [file join $::ELS_TMP _warm_out.txt]
ui_pick sv cp1252
ui_open $warm

set wall0 [clock microseconds]
set sidx 0
foreach {label enc bom skey} $::SAMPLES {
    incr sidx
    puts -nonewline [format "  %-15s " $label] ; flush stdout
    els_reset
    els::build_enc_popup ; els::build_eol_popup        ;# pre-warm menus (untimed)

    # build the sample bytes and a disposable work copy
    set text $::S($skey)
    set bytes [encoding convertto -profile replace $enc $text]
    if {$bom} { set bytes "[bom_bytes $enc]$bytes" }
    set work [wr "w_$label.txt" $bytes]

    # 1. OPEN via the File menu + record detection
    timed open "open:$label" { ui_open $work }
    set idA $::els::active
    set dEnc $::els::docEnc($idA) ; set dBom $::els::docBom($idA)
    set compat [expr {[catch {els::decode $bytes $dEnc $dBom} dec] ? 0 : [string equal $dec $text]}]
    lappend ::DETECT [list $label $enc $bom $dEnc $dBom $compat]

    # 2. REOPEN under each encoding (deliberate mojibake), then back to correct
    foreach renc $::REOPEN_SET {
        timed reopen "reopen:$label->$renc" { ui_pick re $renc }
        if {[catch {[els::T] get 1.0 end}]} { lappend ::FAIL "buffer broken: reopen $label->$renc" }
    }
    timed reopen "reopen:$label->$enc" { ui_pick re $enc }   ;# restore correct text

    # 3. SAVE into 5 "random" encodings, re-open each garbled result
    set gi 0
    foreach senc [rand_encs 5 $sidx] {
        set gpath [file join $::ELS_TMP "g_${label}_$gi.txt"]
        els::switch_to $idA
        timed saveas   "saveas:$label"          { ui_saveas $gpath }
        timed savewith "savewith:$label->$senc" { ui_pick sv $senc }
        timed opengarble "open-garble:$label/$senc" { ui_open $gpath }
        set idB $::els::active
        if {[catch {[els::T] get 1.0 end}]} { lappend ::FAIL "buffer broken: open-garble $label/$senc" }
        if {$idB ne $idA} { catch {els::close_doc $idB} }
        incr gi
    }
    puts "ok"
}
set wallMs [expr {([clock microseconds] - $wall0) / 1000.0}]

# ---- detection report ----------------------------------------------------
puts "\nDETECTION  (declared -> detected; * = decodes identically to the source):"
puts [format "  %-15s %-12s %-4s  %-12s %-4s %s" declared "" bom detected bom note]
set nCompat 0 ; set nExact 0
foreach r $::DETECT {
    lassign $r label de db dd dbb ok
    if {$dd eq $de} { incr nExact }
    if {$ok} { incr nCompat }
    set note [expr {$dd eq $de ? "exact" : ($ok ? "compatible *" : "lossy")}]
    puts [format "  %-15s %-12s %-4d  %-12s %-4d %s" $label $de $db $dd $dbb $note]
}
set nTot [llength $::DETECT]
puts "  -> exact: $nExact/$nTot,  lossless (exact or compatible): $nCompat/$nTot"

# ---- timing report -------------------------------------------------------
puts "\nTIMING (ms):  category        ops      total      avg       max   slowest"
set nOps 0
foreach c {open reopen saveas savewith opengarble} {
    set n [dict get $::T_count $c] ; if {$n == 0} continue
    incr nOps $n
    set tot [dict get $::T_total $c]
    puts [format "  %-14s %6d  %9.1f  %7.2f  %8.1f   %s" \
        $c $n [expr {$tot/1000.0}] [expr {$tot/1000.0/$n}] \
        [expr {[dict get $::T_max $c]/1000.0}] [dict get $::T_maxlbl $c]]
}
puts [format "  TOTAL          %6d ops in %.1f s wall   (budget %d ms/op)" \
    $nOps [expr {$wallMs/1000.0}] $::BUDGET_MS]

# ---- canonical detection assertions (deterministic cases only) -----------
proc want_detect {label wantEnc wantBom} {
    foreach r $::DETECT {
        lassign $r l de db dd dbb ok
        if {$l eq $label} {
            if {$dd ne $wantEnc || $dbb != $wantBom} {
                lappend ::FAIL "detect $label: got $dd/$dbb want $wantEnc/$wantBom"
            }
            return
        }
    }
}
want_detect utf-8-bom    utf-8    1
want_detect utf-16le-bom utf-16le 1
want_detect utf-16be-bom utf-16be 1
want_detect utf-32le-bom utf-32le 1
want_detect utf-32be-bom utf-32be 1
want_detect utf-8        utf-8    0
if {$::els::have_detect} {
    want_detect utf-16le-nobom utf-16le 0
    want_detect utf-16be-nobom utf-16be 0
}

    return $::FAIL
}

# ---- entry points -------------------------------------------------------
# Standalone (`x stress`): run it, print the verdict, exit with a status.  When
# sourced by the default suite, tests/stress.test sets ::els_stress_sourced
# first and calls els_stress_run itself, so skip the auto-run here.
if {![info exists ::els_stress_sourced]} {
    set fails [els_stress_run]
    puts ""
    if {[llength $fails]} {
        puts "RESULT: FAIL ([llength $fails] issue(s))"
        foreach f $fails { puts "  - $f" }
        exit 1
    }
    puts "RESULT: PASS — no hang, no crash, all within budget."
    exit 0
}
