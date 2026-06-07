#!/usr/bin/env tclsh
# tools/man2md.tcl — convert the vendored Tcl/Tk 9 manual pages (nroff, in the
# Tcl "man.macros" dialect) into Markdown, for an offline reference library that
# agents can read before working on els.
#
#   tclsh90.exe tools/man2md.tcl            ;# regenerate docs/tcl-tk-9-manual/
#
# Source: .toolchain/tcl9/share/man/{mann,man3,man1} (self-contained nroff — the
# man.macros are inlined as .de blocks in every page, so no groff/mandoc needed).
# We interpret only the high-level content macros (.TH .SH .SS .PP .TP .IP .RS
# .RE .CS/.CE .nf/.fi .DS/.DE .SO/.SE .OP .AP .QW .PQ ...) and the inline font /
# character escapes; the low-level macro-definition preamble is skipped.
#
# The goal is a faithful, readable Markdown rendering of the full text (not a
# pixel-perfect typeset), so an agent can grep and read the authoritative docs.

# ---- inline escapes -----------------------------------------------------

# Convert nroff character escapes in a plain text chunk (no \f font escapes —
# those are handled by render_fonts before this is called).  aggressive=1 also
# collapses any leftover "\X" to "X" (good for prose; off for code, to be safe).
proc esc_chars {s {aggressive 1}} {
    # protect a real backslash (written \e or \\ in nroff) first
    set s [string map [list "\\\\" "\x00" "\\e" "\x00"] $s]
    set s [string map [list \
        "\\-" "-"  "\\&" ""  "\\|" ""  "\\^" ""  "\\0" " "  "\\ " " " \
        "\\." "."  "\\%" ""  "\\:" ""  "\\c" "" \
        "\\(lq" "“" "\\(rq" "”" "\\(oq" "‘" "\\(cq" "’" \
        "\\(aq" "'" "\\(dq" "\""  "\\(bu" "•" \
        "\\(en" "–" "\\(em" "—" "\\(co" "©" "\\(tm" "™" \
        "\\(rg" "®" "\\(mu" "×" "\\(de" "°" "\\(+-" "±" \
        "\\(<=" "≤" "\\(>=" "≥" "\\(->" "→" "\\(<-" "←" \
        "\\(!=" "≠" "\\(rs" "\x00" \
    ] $s]
    regsub -all {\\[{}]} $s "" s                 ;# \{ \} conditional delimiters
    regsub -all {\\s[-+]?[0-9]} $s "" s          ;# size changes \sN \s+N \s-N
    regsub -all {\\\((..)} $s {\1} s             ;# any other \(XY -> XY
    if {$aggressive} { regsub -all {\\(.)} $s {\1} s }
    return [string map [list "\x00" "\\"] $s]
}

# Wrap a text chunk in the Markdown emphasis for an nroff font, moving any
# surrounding whitespace outside the markers (Markdown won't emphasize a run
# that starts/ends with a space).
proc styled {text style {aggressive 1}} {
    if {$style eq "R" || $text eq ""} { return [esc_chars $text $aggressive] }
    regexp {^(\s*)(.*?)(\s*)$} $text -> lead core trail
    set core [esc_chars $core $aggressive]
    set lead [esc_chars $lead $aggressive]
    set trail [esc_chars $trail $aggressive]
    if {$core eq ""} { return "$lead$trail" }
    set m [dict get {B ** I * C `} $style]
    return "$lead$m$core$m$trail"
}

# Render a line's \fX font runs into Markdown (bold/italic/code) + char escapes.
proc render_fonts {s {aggressive 1}} {
    set out ""
    set style R
    while {[regexp -indices {\\f(\(..|.)} $s m sub]} {
        append out [styled [string range $s 0 [expr {[lindex $m 0]-1}]] $style $aggressive]
        set code [string range $s [lindex $sub 0] [lindex $sub 1]]
        set s [string range $s [expr {[lindex $m 1]+1}] end]
        switch -- $code {
            B { set style B }
            I { set style I }
            C - "(CW" { set style C }
            default { set style R }
        }
    }
    append out [styled $s $style $aggressive]
    return $out
}
# inline = with Markdown emphasis; code = fonts stripped, escapes kept verbatim
proc esc_inline {s} { return [render_fonts $s 1] }
proc esc_code {s} {
    regsub -all {\\f(\(..|.)} $s "" s
    return [esc_chars $s 0]
}

# Split an nroff macro-argument line into a list, honoring "..." grouping.
proc nroff_args {s} {
    set args {} ; set s [string trim $s]
    while {$s ne ""} {
        if {[string index $s 0] eq "\""} {
            set end [string first "\"" $s 1]
            if {$end < 0} { lappend args [string range $s 1 end] ; break }
            lappend args [string range $s 1 [expr {$end-1}]]
            set s [string trimleft [string range $s [expr {$end+1}] end]]
        } elseif {[regexp -indices {\s} $s m]} {
            lappend args [string range $s 0 [expr {[lindex $m 0]-1}]]
            set s [string trimleft [string range $s [lindex $m 0] end]]
        } else { lappend args $s ; set s "" }
    }
    return $args
}

# ---- per-file conversion ------------------------------------------------

# Convert one nroff man file to {title group markdown}.
proc convert_file {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set text [read $fh] ; close $fh

    set out {}          ;# output markdown lines
    set para ""         ;# current fill-mode paragraph
    set paraPrefix ""   ;# "- " for bullet items, else ""
    set indent 0        ;# .RS/.RE nesting depth
    set mode fill       ;# fill | pre
    set inDe 0          ;# inside a .de macro definition (skip)
    set expectTerm 0    ;# next text line is a .TP term
    set inSO 0          ;# inside .SO ... .SE standard-options block
    set soOpts {}
    set title "" ; set group ""

    # flush the current paragraph (uplevel so it touches our locals directly)
    proc _flush {} { uplevel 1 {
        set _p [string trim $para]
        if {$_p ne ""} {
            lappend out "[string repeat {  } $indent]$paraPrefix$_p"
            lappend out ""
        }
        set para "" ; set paraPrefix ""
    }}
    proc _closepre {} { uplevel 1 {
        if {$mode eq "pre"} { lappend out "```" ; lappend out "" ; set mode fill }
    }}

    foreach line [split $text \n] {
        # comments and no-op request lines
        if {[string match "'\\\"*" $line] || [string match ".\\\"*" $line]} continue
        if {$line eq "." || $line eq "'"} continue

        # macro-definition preamble: skip whole .de ... .. blocks
        if {$inDe} { if {[string match ".." $line] || $line eq ".."} { set inDe 0 } ; continue }
        if {[regexp {^\.de\M} $line]} { set inDe 1 ; continue }

        set isReq [regexp {^[.'](\S+)\s?(.*)$} $line -> req rest]
        if {$isReq} {
            switch -- $req {
                TH {
                    set a [nroff_args $rest]
                    set title [lindex $a 0]
                    set group [lindex $a 4]
                    lappend out "# [esc_inline $title]"
                    if {$group ne ""} { lappend out "" ; lappend out "*[esc_inline $group]*" }
                    lappend out ""
                }
                SH { _flush ; _closepre ; lappend out "## [esc_inline [join [nroff_args $rest]]]" ; lappend out "" }
                SS { _flush ; _closepre ; lappend out "### [esc_inline [join [nroff_args $rest]]]" ; lappend out "" }
                PP - LP - sp { if {$mode eq "pre"} { lappend out "" } else { _flush } }
                br { if {$mode ne "pre"} { _flush } }
                TP { _flush ; set expectTerm 1 }
                IP {
                    _flush
                    set a [nroff_args $rest]
                    set mk [lindex $a 0]
                    if {$mk ne "" && [regexp {bu|\*|o|\\\(bu} $mk]} { set paraPrefix "- " }
                }
                RS { _flush ; incr indent }
                RE { _flush ; if {$indent > 0} { incr indent -1 } }
                nf - DS { _flush ; lappend out "```" ; set mode pre }
                fi - DE { _closepre }
                CS { _flush ; lappend out "```tcl" ; set mode pre }
                CE { _closepre }
                SO { _flush ; set inSO 1 ; set soOpts {}
                     lappend out "**Standard options** — see the referenced options manual:" ; lappend out "" }
                SE {
                    set inSO 0
                    foreach o $soOpts { lappend out "- `[esc_inline $o]`" }
                    lappend out ""
                }
                OP {
                    _flush
                    set a [nroff_args $rest]
                    lassign $a name db cls
                    lappend out "[string repeat {  } $indent]- **`[esc_inline $name]`** — database name `[esc_inline $db]`, class `[esc_inline $cls]`"
                    lappend out ""
                }
                AP {
                    _flush
                    set a [nroff_args $rest]
                    lassign $a typ nm dir
                    set term [string trim "[esc_inline $typ] [esc_inline $nm]"]
                    set d [expr {$dir ne "" ? " *($dir)*" : ""}]
                    lappend out "[string repeat {  } $indent]- **`$term`**$d"
                }
                QW { set a [nroff_args $rest] ; append para "“[esc_inline [lindex $a 0]]”[esc_inline [lindex $a 1]] " }
                PQ { set a [nroff_args $rest] ; append para "(“[esc_inline [lindex $a 0]]”[esc_inline [lindex $a 1]]) " }
                MT { append para "“” " }
                default { }   ;# ignore every other request (.ta .ti .ft .ad .BS .BE .VS .VE ...)
            }
            continue
        }

        # ---- plain content line ----
        if {$inSO} {
            foreach o [split $line "\t "] { if {[string trim $o] ne ""} { lappend soOpts [string trim $o] } }
            continue
        }
        if {$mode eq "pre"} { lappend out [esc_code $line] ; continue }
        if {$expectTerm} {
            set expectTerm 0
            set t [string trim [esc_inline $line]]
            if {$t ne ""} {
                lappend out "[string repeat {  } $indent]$t"
                lappend out ""
            }
            continue
        }
        append para [esc_inline $line] " "
    }
    _flush ; _closepre
    rename _flush {} ; rename _closepre {}

    # squeeze 3+ blank lines down to one
    set md {} ; set blank 0
    foreach l $out {
        if {[string trim $l] eq ""} { incr blank ; if {$blank > 1} continue ; lappend md "" } \
        else { set blank 0 ; lappend md $l }
    }
    return [list $title $group [string trimright [join $md \n]]\n]
}

# ---- driver -------------------------------------------------------------

set ROOT [file dirname [file dirname [file normalize [info script]]]]
set MAN  [file join $ROOT .toolchain tcl9 share man]
if {![file isdirectory $MAN]} {
    puts stderr "man source not found: $MAN (need the vendored .toolchain/tcl9)"
    exit 1
}
set OUT [file join $ROOT docs tcl-tk-9-manual]
file delete -force $OUT
file mkdir $OUT

# section dir -> {output subdir, extension, index heading}
set sections {
    mann {commands .n  "Commands"}
    man1 {userland .1  "User commands (tclsh, wish)"}
    man3 {c-api    .3  "C API"}
}

set index {}   ;# list of {heading {sorted entries...}}
dict for {sec spec} $sections {
    lassign $spec sub ext heading
    set srcdir [file join $MAN $sec]
    if {![file isdirectory $srcdir]} continue
    set dstdir [file join $OUT $sub]
    file mkdir $dstdir
    set entries {}
    foreach f [lsort [glob -nocomplain -directory $srcdir *$ext]] {
        set base [file rootname [file tail $f]]
        if {[catch {convert_file $f} res]} {
            puts stderr "FAILED $f: $res" ; continue
        }
        lassign $res title grp md
        set of [file join $dstdir $base.md]
        set oh [open $of w] ; fconfigure $oh -encoding utf-8 -translation lf
        puts -nonewline $oh $md ; close $oh
        lappend entries [list $base $title $grp]
    }
    lappend index [list $heading $sub $entries]
}

# ---- INDEX.md -----------------------------------------------------------
set ix {}
lappend ix "# Tcl 9 & Tk 9 manual (offline)"
lappend ix ""
lappend ix "Markdown rendering of the vendored Tcl/Tk 9 manual pages"
lappend ix "(`.toolchain/tcl9/share/man`), generated by `tools/man2md.tcl`."
lappend ix "Authoritative reference for writing Tcl/Tk code in this repo."
lappend ix ""
set total 0
foreach grp $index { incr total [llength [lindex $grp 2]] }
lappend ix "**$total pages.** Don't read the whole tree; open the pages relevant"
lappend ix "to your change. Filenames match the command / function name."
lappend ix ""
foreach grp $index {
    lassign $grp heading sub entries
    lappend ix "## $heading ([llength $entries])"
    lappend ix ""
    # Sub-bucket commands by their .TH manual group (Tcl vs Tk vs themed).
    if {$sub eq "commands"} {
        set buckets [dict create "Tcl commands" {} "Tk commands" {} "Tk themed widgets (ttk)" {} "Other" {}]
        foreach e [lsort -index 0 $entries] {
            lassign $e base title g
            set b "Other"
            if {[string match -nocase "*themed*" $g] || [string match "ttk_*" $base]} { set b "Tk themed widgets (ttk)" } \
            elseif {[string match "*Tk*" $g]} { set b "Tk commands" } \
            elseif {[string match "*Tcl*" $g]} { set b "Tcl commands" }
            dict lappend buckets $b $e
        }
        dict for {b es} $buckets {
            if {![llength $es]} continue
            lappend ix "### $b"
            lappend ix ""
            foreach e $es { lassign $e base title g ; lappend ix "- \[$base\]($sub/$base.md)" }
            lappend ix ""
        }
    } else {
        foreach e [lsort -index 0 $entries] {
            lassign $e base title g ; lappend ix "- \[$base\]($sub/$base.md)"
        }
        lappend ix ""
    }
}
set oh [open [file join $OUT INDEX.md] w] ; fconfigure $oh -encoding utf-8 -translation lf
puts -nonewline $oh [join $ix \n]\n ; close $oh

puts "wrote $total pages + INDEX.md to [file join docs tcl-tk-9-manual]"
