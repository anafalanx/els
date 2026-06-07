#!/usr/bin/env tclsh
# tools/gen_sample.tcl — generate a large random-word text file for manually
# testing els at scale (scroll / word-wrap / gutter performance, find, etc.).
#
#   tclsh90.exe tools/gen_sample.tcl <out.txt> <lines> [target-cols]
#
# Each line is filled with random words from a small pool up to ~target columns
# (default 120).  LF line endings, UTF-8.  Deterministic (fixed seed), so the
# same arguments always produce the same file.  Output goes wherever you point
# it; the samples/ dir is gitignored for exactly this.

set ::WORDS {
    the quick brown fox jumps over a lazy dog and then writes random words
    across many lines to exercise the editor scroll wrap gutter find replace
    column ruler status bar tab document buffer encoding caret selection undo
    redo paragraph sentence sample small sharp tool single file windows text
    editing performance large fixture twelvecharword middle short longer
    wordlength variety alpha beta gamma delta epsilon zeta eta theta iota
    kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega
    north south east west up down left right open close save read write line
}

proc main {argv} {
    lassign $argv out nlines target
    if {$out eq "" || ![string is integer -strict $nlines] || $nlines < 1} {
        puts stderr "usage: gen_sample.tcl <out.txt> <lines> \[target-cols]"
        exit 2
    }
    if {$target eq ""} { set target 120 }
    set ws $::WORDS
    set nw [llength $ws]
    expr {srand(20250607)}                ;# deterministic content
    file mkdir [file dirname $out]
    set fh [open $out w]
    fconfigure $fh -translation lf -encoding utf-8
    set sum 0
    for {set i 1} {$i <= $nlines} {incr i} {
        set line [lindex $ws [expr {int(rand()*$nw)}]]   ;# at least one word
        while 1 {
            set w [lindex $ws [expr {int(rand()*$nw)}]]
            if {[string length $line] + [string length $w] + 1 > $target} break
            append line " " $w
        }
        puts $fh $line
        incr sum [string length $line]
    }
    close $fh
    puts [format "wrote %s: %d lines, ~%.0f avg cols, %.1f MB" \
        $out $nlines [expr {double($sum)/$nlines}] [expr {[file size $out]/1048576.0}]]
}
main $argv
