#!/usr/bin/env wish
# els — a tiny, focused text editor.  Tcl/Tk 9 edition.
#
# This is the rewrite of the C23/Lua els (which shipped through v0.3, archived
# in ../els-c).  Tk's Text widget is the buffer; Tcl/Tk supplies the UI runtime.
# Design language carried over from v0.3: calm grey page, the signature red
# caret, restrained chrome, opinionated (few knobs).
#
# Multi-file model: one Text widget per open document (each keeps its own undo
# stack, selection and modified state, free from Tk).  A shared gutter,
# scrollbar and status bar re-point to whichever document is active.  A custom
# flat tab strip switches between them.

# ---------------------------------------------------------------------------
# Isolated find worker
# ---------------------------------------------------------------------------
# User regular expressions never run in the UI interpreter.  The normal source
# build starts this file under tclsh; the packaged build starts the same exe and
# reaches this dispatch after its embedded Tcl/Tk runtime has initialized.  Keep
# every command in this section pure Tcl and before `package require Tk`, so the
# source worker does not load or map Tk at all.  A packaged worker may already
# own Tk's implicit root, but it exits without entering the event loop; withdraw
# it immediately as an additional no-flash guard.
namespace eval ::elsworker {
    variable VERSION 1
    variable CONTROL_MAX 262144
    variable FIELD_MAX 65536
    variable SNAPSHOT_MAX 268435456
    variable MATCH_MAX 1000000
    variable RECORD_BYTES 42
    variable OUTPUT_MAX 268435456
}

proc ::elsworker::read_regular {path limit} {
    if {![file exists $path] || [file type $path] ne "file"} {
        error "required regular file is missing"
    }
    set size [file size $path]
    if {$size < 0 || $size > $limit} { error "file exceeds limit" }
    set f [::open $path rb]
    try { set raw [read $f [expr {$limit + 1}]] } finally { close $f }
    if {[string length $raw] != $size || [string length $raw] > $limit} {
        error "file changed while being read"
    }
    return $raw
}

proc ::elsworker::decode_utf8 {raw} {
    return [encoding convertfrom -profile strict utf-8 $raw]
}

proc ::elsworker::encode_utf8 {text} {
    return [encoding convertto -profile strict utf-8 $text]
}

# Parse a serialized Tcl dictionary without allowing duplicate keys.  `dict
# create {*}$value` alone would silently let the last duplicate win, which would
# make the file protocol ambiguous at exactly the trust boundary it protects.
proc ::elsworker::exact_dict {text keys} {
    if {[catch {llength $text} n] || $n % 2} { error "invalid dictionary list" }
    set out [dict create]
    foreach {k v} $text {
        if {[dict exists $out $k]} { error "duplicate dictionary key" }
        dict set out $k $v
    }
    if {[lsort [dict keys $out]] ne [lsort $keys]} { error "dictionary schema mismatch" }
    return $out
}

proc ::elsworker::write_atomic_utf8 {path text} {
    set raw [::elsworker::encode_utf8 $text]
    set tmp "$path.tmp-[pid]-[clock clicks]"
    set f [::open $tmp {WRONLY CREAT EXCL TRUNC}]
    fconfigure $f -translation binary
    try { puts -nonewline $f $raw } finally { close $f }
    # Every protocol leaf is single-assignment.  Refuse an unexpected existing
    # target instead of replacing something that appeared after the parent made
    # its containment checks.
    file rename $tmp $path
}

proc ::elsworker::wait_for_go {jobdir token} {
    set path [file join $jobdir go]
    set until [expr {[clock milliseconds] + 5000}]
    while {[clock milliseconds] < $until} {
        if {[file exists $path]} {
            if {[catch {
                set raw [::elsworker::read_regular $path $::elsworker::CONTROL_MAX]
                set d [::elsworker::exact_dict [::elsworker::decode_utf8 $raw] \
                    {command token version}]
                expr {[dict get $d version] == $::elsworker::VERSION \
                    && [dict get $d command] eq "go" \
                    && [dict get $d token] eq $token}
            } ok] == 0 && $ok} { return 1 }
            return 0
        }
        after 25
    }
    return 0
}

proc ::elsworker::expand_subspec {subspec source groups} {
    set out ""
    set n [string length $subspec]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $subspec $i]
        if {$ch eq "&"} {
            set group 0
        } elseif {$ch eq "\\" && $i + 1 < $n} {
            set next [string index $subspec [expr {$i + 1}]]
            if {[regexp {^[0-9]$} $next]} {
                set group $next
                incr i
            } elseif {$next eq "\\" || $next eq "&"} {
                append out $next
                incr i
                continue
            } else {
                # Tcl regsub preserves an unknown escape (and a trailing
                # backslash) byte-for-byte in the substitution result.
                append out $ch
                continue
            }
        } else {
            append out $ch
            continue
        }
        if {$group < [llength $groups]} {
            lassign [lindex $groups $group] a b
            if {$a >= 0 && $b >= $a} { append out [string range $source $a [expr {$b - 1}]] }
        }
    }
    return $out
}

proc ::elsworker::adapt_case {enabled match replacement} {
    if {!$enabled || $match eq "" || ![regexp {[[:alpha:]]} $match]} {
        return $replacement
    }
    if {$match eq [string tolower $match]} { return [string tolower $replacement] }
    if {$match eq [string totitle $match]} { return [string totitle $replacement] }
    if {$match eq [string toupper $match]} { return [string toupper $replacement] }
    return $replacement
}

proc ::elsworker::append_output {outVar bytesVar crcVar limit text} {
    upvar 1 $outVar out $bytesVar bytes $crcVar crc
    set raw [::elsworker::encode_utf8 $text]
    incr bytes [string length $raw]
    if {$bytes > $limit} { error "replacement output exceeds limit" }
    set crc [zlib crc32 $raw $crc]
    append out $text
}

proc ::elsworker::record {f crcVar start end} {
    upvar 1 $crcVar crc
    set rec [format "%020d %020d\n" $start $end]
    if {[string length $rec] != $::elsworker::RECORD_BYTES} { error "match offset overflow" }
    puts -nonewline $f $rec
    set crc [zlib crc32 $rec $crc]
}

proc ::elsworker::run_job {jobdir token request source} {
    set kind [dict get $request kind]
    set pattern [dict get $request pattern]
    set replacement [dict get $request replacement]
    set nocase [dict get $request nocase]
    set regexMode [dict get $request regex_mode]
    set adapt [dict get $request adapt]
    set matchLimit [dict get $request match_limit]
    set outputLimit [dict get $request output_limit]
    set hintStart [dict get $request hint_start]
    set hintEnd [dict get $request hint_end]
    set deadline [expr {[clock milliseconds] + [dict get $request deadline_ms]}]

    set matchPath [file join $jobdir matches.idx]
    set mf [::open $matchPath {WRONLY CREAT EXCL TRUNC}]
    fconfigure $mf -translation binary
    set matchCrc 0
    set matchCount 0
    set matchTruncated 0
    set changedCount 0
    set status ok
    set err ""
    set sourceChars [string length $source]
    set output ""
    set outputBytes 0
    set outputCrc 0
    set cursor 0
    set offset 0
    set foundHint 0
    set flags {-line}
    if {$nocase} { lappend flags -nocase }

    try {
        while {$offset <= $sourceChars} {
            if {[clock milliseconds] > $deadline} { error "worker deadline exceeded" }
            set rc [catch {
                regexp {*}$flags -indices -start $offset -- $pattern $source \
                    m g1 g2 g3 g4 g5 g6 g7 g8 g9
            } matched]
            if {$rc} {
                set status bad-pattern
                set err $matched
                break
            }
            if {!$matched} { break }
            lassign $m start last
            set end [expr {$last < $start ? $start : $last + 1}]
            if {$start < 0 || $end < $start || $end > $sourceChars} {
                error "regex engine returned an invalid range"
            }

            if {$kind eq "replace-one"} {
                if {$start > $hintStart} { break }
                if {$start != $hintStart || $end != $hintEnd} {
                    set offset [expr {$end > $start ? $end : $start + 1}]
                    if {$start == $sourceChars && $end == $start} { break }
                    continue
                }
                set foundHint 1
            }

            incr matchCount
            if {$matchCount > $matchLimit} {
                set matchTruncated 1
                if {$kind ne "search"} {
                    set status limit
                    set err "match limit exceeded"
                }
                break
            }
            ::elsworker::record $mf matchCrc $start $end

            if {$kind ne "search"} {
                if {$kind eq "replace-all"} {
                    ::elsworker::append_output output outputBytes outputCrc $outputLimit \
                        [string range $source $cursor [expr {$start - 1}]]
                }
                set groups {}
                foreach pair [list $m $g1 $g2 $g3 $g4 $g5 $g6 $g7 $g8 $g9] {
                    lassign $pair a b
                    if {$a < 0 || $b < $a} {
                        lappend groups {-1 -1}
                    } else {
                        lappend groups [list $a [expr {$b + 1}]]
                    }
                }
                if {$regexMode} {
                    set repl [::elsworker::expand_subspec $replacement $source $groups]
                } else {
                    set repl $replacement
                }
                set matchedText [string range $source $start [expr {$end - 1}]]
                set repl [::elsworker::adapt_case $adapt $matchedText $repl]
                ::elsworker::append_output output outputBytes outputCrc $outputLimit $repl
                if {$repl ne $matchedText} { incr changedCount }
                set cursor $end
            }

            if {$kind eq "replace-one"} { break }
            if {$end > $start} {
                set offset $end
            } elseif {$start < $sourceChars} {
                set offset [expr {$start + 1}]
            } else {
                break
            }
        }

        if {$status eq "ok" && $kind eq "replace-one" && !$foundHint} {
            set status stale
            set err "hint no longer identifies the requested match"
        }
        if {$status eq "ok" && $kind eq "replace-all"} {
            ::elsworker::append_output output outputBytes outputCrc $outputLimit \
                [string range $source $cursor end]
        }
    } on error {e o} {
        set status error
        set err $e
    } finally {
        close $mf
    }

    set outputChars 0
    if {$status eq "ok" && $kind ne "search"} {
        set outputChars [string length $output]
        set raw [::elsworker::encode_utf8 $output]
        if {[string length $raw] != $outputBytes || [zlib crc32 $raw] != $outputCrc} {
            set status error
            set err "internal output verification failed"
        } else {
            set outPath [file join $jobdir replacement.utf8]
            set f [::open $outPath {WRONLY CREAT EXCL TRUNC}]
            fconfigure $f -translation binary
            try { puts -nonewline $f $raw } finally { close $f }
        }
    }

    set matchBytes [file size $matchPath]
    if {$matchBytes != min($matchCount, $matchLimit) * $::elsworker::RECORD_BYTES} {
        set status error
        set err "internal match index verification failed"
    }
    # Failed work is never committable.  Do this after every self-check: output
    # and match-index verification can themselves turn an otherwise successful
    # replacement into an error.  Keep the match index for diagnostics, but
    # make every replacement/output field unambiguously empty and remove any
    # regular replacement file that an earlier stage may have published.
    if {$status ne "ok"} {
        set changedCount 0
        set output ""
        set outputChars 0
        set outputBytes 0
        set outputCrc 0
        set outPath [file join $jobdir replacement.utf8]
        if {[file exists $outPath] && ![catch {file type $outPath} outType] \
                && $outType eq "file"} {
            catch {file delete $outPath}
        }
    }
    return [dict create \
        version $::elsworker::VERSION token $token status $status kind $kind \
        source_chars [dict get $request source_chars] \
        source_bytes [dict get $request source_bytes] \
        source_crc [dict get $request source_crc] \
        match_count [expr {min($matchCount, $matchLimit)}] \
        match_truncated $matchTruncated match_bytes $matchBytes match_crc $matchCrc \
        changed_count $changedCount output_chars $outputChars \
        output_bytes $outputBytes output_crc $outputCrc error [string range $err 0 4095]]
}

proc ::elsworker::main {jobdir token} {
    if {![regexp {^[0-9a-f]{16,64}$} $token]} { return 2 }
    if {![file exists $jobdir] || [file type $jobdir] ne "directory"} { return 2 }
    if {![::elsworker::wait_for_go $jobdir $token]} { return 3 }
    set requestKeys {adapt deadline_ms hint_end hint_start kind match_limit nocase \
        output_limit pattern regex_mode replacement source_bytes source_chars source_crc token version}
    if {[catch {
        set reqRaw [::elsworker::read_regular [file join $jobdir request.dict] \
            $::elsworker::CONTROL_MAX]
        set request [::elsworker::exact_dict [::elsworker::decode_utf8 $reqRaw] $requestKeys]
        if {[dict get $request version] != $::elsworker::VERSION \
                || [dict get $request token] ne $token} { error "request identity mismatch" }
        if {[dict get $request kind] ni {search replace-one replace-all}} { error "invalid job kind" }
        foreach k {nocase regex_mode adapt} {
            if {[dict get $request $k] ni {0 1}} { error "invalid boolean" }
        }
        foreach k {source_bytes source_chars source_crc match_limit output_limit deadline_ms hint_start hint_end} {
            if {![string is entier -strict [dict get $request $k]] || [dict get $request $k] < 0} {
                error "invalid numeric field"
            }
        }
        if {[dict get $request source_crc] > 0xffffffff \
                || [dict get $request match_limit] < 1 \
                || [dict get $request deadline_ms] < 1} { error "request numeric range exceeded" }
        if {[dict get $request source_bytes] > $::elsworker::SNAPSHOT_MAX \
                || [dict get $request source_chars] > $::elsworker::SNAPSHOT_MAX \
                || [dict get $request match_limit] > $::elsworker::MATCH_MAX \
                || [dict get $request output_limit] > $::elsworker::OUTPUT_MAX \
                || [dict get $request deadline_ms] > 30000} { error "request limit exceeded" }
        if {[dict get $request source_chars] > [dict get $request source_bytes] \
                || [dict get $request hint_end] < [dict get $request hint_start] \
                || [dict get $request hint_end] > [dict get $request source_chars] \
                || ([dict get $request kind] ne "replace-one" \
                    && ([dict get $request hint_start] != 0 \
                        || [dict get $request hint_end] != 0))} {
            error "request range invariant mismatch"
        }
        foreach k {pattern replacement} {
            if {[string length [::elsworker::encode_utf8 [dict get $request $k]]] > $::elsworker::FIELD_MAX} {
                error "request field exceeds limit"
            }
        }
        set snapRaw [::elsworker::read_regular [file join $jobdir snapshot.utf8] \
            $::elsworker::SNAPSHOT_MAX]
        if {[string length $snapRaw] != [dict get $request source_bytes] \
                || [zlib crc32 $snapRaw] != [dict get $request source_crc]} {
            error "snapshot byte identity mismatch"
        }
        set source [::elsworker::decode_utf8 $snapRaw]
        if {[string length $source] != [dict get $request source_chars]} {
            error "snapshot character identity mismatch"
        }
        set result [::elsworker::run_job $jobdir $token $request $source]
        ::elsworker::write_atomic_utf8 [file join $jobdir result.ready] $result
    } err opts]} {
        # If the request was readable enough to authenticate, publish a bounded
        # failure record.  Otherwise leave no result: the parent treats missing
        # or malformed protocol state as failure and never touches the document.
        catch {
            set result [dict create version $::elsworker::VERSION token $token \
                status error kind unknown source_chars 0 source_bytes 0 source_crc 0 \
                match_count 0 match_truncated 0 match_bytes 0 match_crc 0 \
                changed_count 0 output_chars 0 output_bytes 0 output_crc 0 \
                error [string range $err 0 4095]]
            ::elsworker::write_atomic_utf8 [file join $jobdir result.ready] $result
        }
        return 4
    }
    return 0
}

set ::elsworker::_dispatch 0
if {[llength $::argv] == 3 && [lindex $::argv 0] eq "--find-worker"} {
    set _script [info script]
    set _sourceDirect 0
    catch { set _sourceDirect [expr {[file normalize $_script] eq [file normalize $::argv0]}] }
    set _packagedDirect [expr {[string match {//zipfs:/*/main.tcl} $_script] \
        && [file tail $::argv0] eq [file tail [info nameofexecutable]]}]
    set ::elsworker::_dispatch [expr {$_sourceDirect || $_packagedDirect}]
}
if {$::elsworker::_dispatch} {
    catch {wm withdraw .}
    set _rc [catch {::elsworker::main [lindex $::argv 1] [lindex $::argv 2]} _result]
    if {$_rc} { exit 5 }
    exit $_result
}
unset ::elsworker::_dispatch

package require Tk

namespace eval els {
    variable version "0.95"      ;# 0.95: no crash recovery by design — atomic save + backup ring + opt-in autosave; every launch its own window; UX/tooling/backup hardening
    variable docs {}             ;# ordered list of open document ids
    variable active ""           ;# active document id ("" = none)
    variable seq 0               ;# monotonic id counter
    variable iconImage ""
    variable iconImages {}
    variable iconPath ""
    variable iconLoaded 0
    variable selftest [expr {[lindex $::argv 0] eq "--selftest"}]
    variable docPath             ;# array: id -> file path ("" = untitled)
    array set docPath {}
    variable docEnc ; array set docEnc {}   ;# id -> Tcl encoding (utf-8, utf-16le, ...)
    variable docBom ; array set docBom {}   ;# id -> 1 if a byte-order mark was present
    variable docEol ; array set docEol {}   ;# id -> lf | crlf | cr
    variable docRaw ; array set docRaw {}   ;# id -> exact bytes as loaded ("" = never from disk)
    variable docDecodeLossy; array set docDecodeLossy {} ;# id -> 1 if decode substituted U+FFFD (bad bytes for the encoding)
    variable docFormatPending; array set docFormatPending {} ;# id -> explicit Reopen-with format awaits manual Save
    variable docLossyOk   ; array set docLossyOk {}    ;# id -> user accepted lossy saves (this session)
    variable docLossyPause; array set docLossyPause {} ;# id -> auto-save paused (unencodable chars)
    variable docExtModPause; array set docExtModPause {} ;# id -> auto-save paused (file changed on disk)
    variable status_note_after ""   ;# transient statusbar note timer
    variable autosave 0             ;# File ▸ Auto-save (opt-in, persisted)
    variable autosave_after ""      ;# debounced auto-save flush timer
    variable autosave_pending {}    ;# doc ids awaiting the debounced flush
    variable backups 1              ;# File ▸ Keep Backups (on by default, persisted)
    variable BK_RING 8              ;# previous versions kept per file
    variable BK_MININT 60           ;# s: skip a backup if the newest is this fresh
    variable BK_MAXAGE 2592000      ;# s: prune backups older than 30 days
    variable BK_MAXSIZE 20971520    ;# bytes: don't back up files larger than 20 MB
    variable OPEN_WARN_SIZE 26214400 ;# bytes: confirm before opening a file larger than 25 MB
    variable IO_CHUNK 1048576        ;# bounded physical read size for streaming I/O
    variable DEFERRED_MAX_BYTES 1048576 ;# poison guard for the adjacent deferred queue
    variable deferred_files {}       ;# large files held for a deliberate foreground open
    variable deferred_blocked 0      ;# corrupt queue could not be quarantined: never overwrite it
    variable deferred_notice ""      ;# startup diagnostic surfaced after the status bar exists
    variable last_open_outcome ""    ;# opened|already|deferred|cancelled|failed (quiet callers inspect it)
    variable MAXUNDO 2000           ;# cap the per-doc undo stack (compound actions) so a long session can't grow it without bound
    # Re-entrancy guard: background work (an autosave flush, the async find/replace
    # worker's buffer commit) is deferred while a modal message pump is up, so it can
    # never mutate a document beneath a dialog.  Tokens allow overlapping guards.
    variable swap_suspend      0    ;# 1 while a modal pump runs
    variable swap_suspend_tokens {} ;# overlapping guards, released by identity rather than stack order
    variable swap_suspend_serial 0
    variable swap_suspend_base 0
    variable session_id_cached    ""
    variable session_token_cached ""
    variable probe_quiet 0          ;# probe mode: alpha-0 every toplevel (no desktop flash)
    variable drop_pending {}        ;# native drops held while a modal decision owns the context
    variable drop_after ""
    variable session_boot_after "" ;# deferred startup session-restore orchestration
    variable log_active 0           ;# reentry latch: a failing els::log must not recurse via bgerror
    variable geom_save_warned 0     ;# one-shot: settings-persist failure already surfaced this streak
    variable savedSig   ; array set savedSig   {}  ;# id -> on-disk file sig "size:mtime:crc" ("" untitled)
    variable savedSigPath; array set savedSigPath {} ;# id -> path savedSig was cached for (pins the R3 baseline)
    variable docDiskState; array set docDiskState {} ;# id -> untitled|normal|changed|missing|unavailable|readonly
    variable docDiskMeta; array set docDiskMeta {}   ;# id -> last cheap {path size mtime} observation
    variable docDiskContent; array set docDiskContent {} ;# id -> normal|changed result cached for docDiskMeta
    variable docDiskDetail; array set docDiskDetail {} ;# id -> short tooltip detail
    variable docDiskDeepAt; array set docDiskDeepAt {} ;# id -> last forced full-content observation (ms)
    variable loading    ; array set loading    {}  ;# id -> 1 while open mutates identity
    variable DISK_DEEP_PROBE_CAP 16777216  ;# forced UI checks hash only reasonably small files
    # charset detection (chardet quality via the system ICU; 0 until loaded)
    variable have_detect 0
    variable DETECT_MIN  15      ;# ignore ICU guesses below this confidence (0-100)
    # curated encodings for the status-bar picker: {label encoding bom} triples,
    # "-" marks a separator.  "Other (all)" exposes every Tcl encoding.
    variable ENC_CURATED {
        "UTF-8"                       utf-8      0
        "UTF-8 with BOM"              utf-8      1
        "UTF-16 LE"                   utf-16le   0
        "UTF-16 LE with BOM"          utf-16le   1
        "UTF-16 BE"                   utf-16be   0
        "UTF-16 BE with BOM"          utf-16be   1
        "-" - -
        "Windows-1252 (Western)"      cp1252     0
        "ISO-8859-1 (Latin-1)"        iso8859-1  0
        "ISO-8859-15 (Latin-9)"       iso8859-15 0
        "Windows-1250 (Central Eur.)" cp1250     0
        "Windows-1251 (Cyrillic)"     cp1251     0
        "-" - -
        "Shift-JIS (Japanese)"        cp932      0
        "GBK (Simplified Chinese)"    cp936      0
        "Big5 (Traditional Chinese)"  big5       0
        "EUC-JP (Japanese)"           euc-jp     0
        "EUC-KR (Korean)"             euc-kr     0
    }
    # find / replace
    variable find_q ""           ;# search text
    variable find_r ""           ;# replacement text
    variable find_case 0         ;# match case
    variable find_word 0         ;# whole word
    variable find_regex 0        ;# regular expression mode
    variable find_mode ""        ;# "" hidden | find | replace
    variable find_matches {}     ;# list of {start end} index pairs in the active doc
    variable find_current -1     ;# index into find_matches
    variable find_count ""       ;# status text e.g. "3 of 12"
    variable FIND_MAXHITS 5000   ;# cap tracked/highlighted matches; the count shows "N+"
    variable FIND_MAXINDEX 1000000 ;# hard cap in the on-disk global match index
    variable FIND_INPUT_MAX 268435456 ;# 256 MiB UTF-8 snapshot ceiling
    variable FIND_OUTPUT_MAX 268435456 ;# 256 MiB staged replacement ceiling
    variable FIND_SLICE_CHARS 262144   ;# bounded Text extraction per idle turn
    variable FIND_SLICE_BYTES 262144   ;# bounded staged-output verification turn
    variable FIND_RECORD_BYTES 42      ;# "%020d %020d\n"
    variable FIND_SEARCH_MS 10000      ;# parent-enforced isolated-worker deadline
    variable FIND_REPLACE_MS 30000
    variable find_truncated 0    ;# exact global result has more than 5000 display highlights
    variable find_index_truncated 0 ;# worker hit the 1,000,000 hard index ceiling
    variable find_adapt 0        ;# adapt-case replace (replacement follows the match's case)
    variable docEpoch ; array set docEpoch {} ;# increments on every successful text mutation
    variable find_generation 0   ;# stale callbacks/results can never win a newer request
    variable find_job_seq 0
    variable find_job {}         ;# active isolated worker job dictionary
    variable find_retired {}     ;# killed jobs awaiting confirmed process exit + cleanup
    variable find_poll_after ""
    variable find_reap_after ""
    variable find_snapshot {}    ;# immutable cache {doc epoch path chars bytes crc}
    variable find_snapshot_build {} ;# in-progress idle-sliced snapshot state
    variable find_snapshot_after ""
    variable find_pending {}     ;# newest action waiting for a snapshot / worker slot
    variable find_result_job {}  ;# completed search job retained for random-access F3
    variable find_index_path ""
    variable find_total 0
    variable find_validation {}  ;# idle-sliced matches.idx verification state
    variable find_validation_after ""
    variable find_highlight_state {} ;# idle-sliced first-5000 display tagging
    variable find_highlight_after ""
    variable find_output_read {} ;# in-progress idle-sliced replacement verification
    variable find_output_after ""
    variable find_replace_all_busy 0 ;# accepted Replace All remains cancellable through every stage
    variable find_applying 0     ;# suppress edit-triggered restart during atomic commit
    variable find_shutdown 0
    variable find_test_sync [expr {[info exists ::els_helpers_loaded] ? 1 : 0}]
    variable find_worker_command_override {} ;# deterministic child used only by tests
    variable find_history {}     ;# recent search terms, newest first (cap 16)
    variable find_hidx -1        ;# position while cycling history with Up/Down
    variable show_ws 0           ;# View ▸ Show Whitespace
    variable focus_mode 0        ;# View ▸ Focus Mode: dim all but the current line
    variable show_linenos 1      ;# View ▸ Line Numbers (persisted)
    variable recent_vs_after ""  ;# deferred recent-list scrollbar show/hide
    variable word_wrap 0         ;# View ▸ Word Wrap (soft-wrap long lines)
    variable always_on_top 0     ;# View ▸ Always on Top (wm -topmost)
    variable geom_normal ""      ;# last NORMAL-state `wm geometry .` (tracked so a
                                 ;# maximized quit still persists a real window rect)
    variable font_size 11        ;# document text size (points); the family is fixed
    variable vs_shown -1         ;# vertical scrollbar visibility (auto-hidden when content fits)
    variable vs_after ""         ;# pending (idle) vertical scrollbar-visibility update
    variable hs_shown -1         ;# horizontal scrollbar visibility (only when wrap off + long lines)
    variable hs_after ""         ;# pending (idle) horizontal scrollbar-visibility update
    variable find_after ""       ;# pending (debounced) incremental search
    variable ws_after ""         ;# pending (debounced) whitespace return-marker update
    variable tab_tip_delay 1000  ;# tabs are crossed often; let their tips breathe
    variable recent {}           ;# recently-opened file paths, newest first
    variable recent_cap 12       ;# how many recent files to keep
    variable restore_session 1   ;# reopen file-backed tabs from the previous run
    variable session_files {}     ;# file-backed tabs saved from the previous run
    variable session_pending {}   ;# saved session files that could NOT be restored this
                                  ;# run (offline drive / locked at boot) — kept so a
                                  ;# transient outage doesn't permanently forget them
    variable session_active ""    ;# active file path saved from the previous run
    variable session_owned 0      ;# 1 once THIS run adopted the saved session: an
                                  ;# explicit-file-arg launch never adopted it, so
                                  ;# persisting its own doc list would destroy the
                                  ;# stored multi-tab session
    variable config_path ""      ;# resolved executable-adjacent els.conf path
    variable gutter_px -1        ;# last-set gutter canvas width (px); -1 = unset
    variable gutter_after ""     ;# coalesced gutter-redraw after token
    variable refresh_after ""    ;# coalesced full-view refresh (resize bursts)
    variable tp_zoom_acc 0       ;# accumulated Ctrl+touchpad zoom delta
    variable recent_row_tip -1   ;# recent-list row whose hover tip is active
    variable recent_sel_path ""  ;# Maintain List selection, tracked by PATH
    variable tabs_layout_after "" ;# coalesced tab-strip overflow layout
    variable tabs_menu_choice ""  ;# radiobutton scratch state for the Tabs menu
    variable TAB_LABEL_MAX 22      ;# hard character cap; active tab fits the minimum window
    variable TAB_LABEL_PX 190      ;# hard text-pixel cap (wide glyphs cannot balloon a tab)
    variable TAB_MENU_MAX 64       ;# hard character cap for the overflow menu
    variable TAB_MENU_PX 420       ;# hard text-pixel cap for the overflow menu
    variable disk_watch_active 0   ;# true only while the application is foreground-active
    variable disk_watch_after ""   ;# modest active-window metadata poll
    variable DISK_WATCH_MS 5000    ;# stat interval; deep checks are separately cached
    variable DISK_DEEP_BACKOFF_MS 1500 ;# forced activations cannot repeatedly stream a file
    variable boot_script ""      ;# path of this file at source time (see below)
}
# Capture the script path NOW, while a `source` is active: `info script` is only
# valid during sourcing and returns "" from later event/callback contexts, so we
# remember it here to locate the running els.exe reliably (see association_exe).
set ::els::boot_script [info script]

# ---- look: the els visual identity --------------------------------------
# A calm grey page, generously leaded, with one red flourish.  Chrome defers
# to the text: flat, tonal, hairline-thin; separation by value, not borders.
set ::els::PAGE    "#F2F2F2"     ;# calm grey page (#FFF glares; ~15.8:1 w/ ink)
set ::els::INK     "#1A1A1A"     ;# near-black ink (not pure #000)
set ::els::CARET   "#DC322F"     ;# the signature red caret + accent
set ::els::LINE    "#EAEAEA"     ;# current-line wash — a whisper, not a band
set ::els::GUTTER  "#ECECEC"     ;# gutter ground (a tonal step off the page)
set ::els::GUTTINK "#8C8C8C"     ;# line numbers — quiet, deferential
set ::els::MUTED   "#6B7177"     ;# chrome text (muted slate)
set ::els::SEL     "#D6E2F2"     ;# selection — a calm cool tint, not vivid
set ::els::SELOFF  "#E2E2E2"     ;# selection while the buffer is unfocused
set ::els::CHROME  "#E9E9E9"     ;# flat chrome panels (status / find bar)
set ::els::HAIR    "#D4D4D4"     ;# 1px hairline separators
set ::els::TABBG   "#DEDEDE"     ;# the strip behind the tabs
set ::els::TABOFF  "#E6E6E6"     ;# an inactive tab
set ::els::TABON   "#F2F2F2"     ;# active tab merges into the page
set ::els::FINDALL "#FFF1C4"     ;# all find matches (soft amber)
set ::els::FINDONE "#FFD66B"     ;# the current find match (stronger amber)
set ::els::WSSPACE "#E2E2E2"     ;# a lone space — light grey (subtle; spaces are everywhere)
set ::els::WSTAB   "#D3E1F5"     ;# tabs — light blue
set ::els::WSTRAIL "#E9D9F1"     ;# 2+ spaces or trailing whitespace — light mauve
option add *tearOff 0
font create elsMono -family Consolas   -size 11
font create elsMonoHelp -family Consolas -size 10
font create elsUI   -family {Segoe UI} -size 9
font create elsUIb  -family {Segoe UI} -size 9 -weight bold   ;# section headers
font create elsTitle -family {Segoe UI Light} -size 40   ;# the About wordmark
# leading: ~1.34x line height (the single biggest "calm" lever), scaled from
# the font's own line box so it tracks DPI.  Applied as -spacing1/-spacing3.
set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]

# ---- widget-name helpers ------------------------------------------------
proc els::W {id}    { return ".txt_$id" }       ;# a document's Text widget
proc els::tabW {id} { return ".tabs.tab_$id" }  ;# a document's tab frame
proc els::T {} {                                ;# the active Text widget ("" = none)
    variable active
    if {$active eq ""} { return "" }
    return [els::W $active]
}
proc els::id_of {w} {                           ;# ".txt_d3" -> "d3"
    if {[regexp {^\.txt_(.+)$} $w -> id]} { return $id }
    return ""
}

# Background guards may overlap and need not finish in stack order: a native
# dialog pumps events, and one of those events can open a grabbed Tcl dialog.
# Tokens keep autosave and the async find worker suspended until the last
# participant leaves, while preserving a pre-existing direct suspension set by
# tests.  (swap_suspend is a historical name: 0.95 has no swaps, but the flag
# still gates any work that must not commit beneath a modal event pump.)
proc els::suspend_acquire {} {
    if {![dict size $::els::swap_suspend_tokens]} {
        set ::els::swap_suspend_base $::els::swap_suspend
    }
    set token [incr ::els::swap_suspend_serial]
    dict set ::els::swap_suspend_tokens $token 1
    set ::els::swap_suspend 1
    return $token
}
proc els::suspend_release {token} {
    if {![dict exists $::els::swap_suspend_tokens $token]} { return }
    dict unset ::els::swap_suspend_tokens $token
    if {[dict size $::els::swap_suspend_tokens]} {
        set ::els::swap_suspend 1
    } else {
        set ::els::swap_suspend $::els::swap_suspend_base
    }
}

# Native dialogs run a nested event loop.  Mark that entire interval so no
# background callback can change the document or visible context underneath a
# decision the user is still making.
proc els::message_box {args} {
    set suspendToken [els::suspend_acquire]
    try {
        tk_messageBox {*}$args
    } finally {
        els::suspend_release $suspendToken
    }
}

# Non-blocking grabbed dialogs hold the same guard until their toplevel is
# destroyed.  <Destroy> also reaches the toplevel bindtag for child widgets, so
# restore only for the toplevel's own event.
proc els::modal_window_release {top suspendToken destroyed} {
    if {$destroyed eq $top} { els::suspend_release $suspendToken }
}

# ---- app resources / preferences ---------------------------------------
proc els::find_resource {args} {
    set rel [file join {*}$args]
    foreach base [list [file dirname [info script]] [pwd]] {
        set p [file normalize [file join $base $rel]]
        if {[file exists $p]} { return $p }
    }
    return ""
}
proc els::load_icon {} {
    set imgs {}
    foreach {name file} {
        elsIcon16 icon16.png
        elsIcon32 icon32.png
        elsIcon   icon.png
    } {
        set p [els::find_resource resources $file]
        if {$p eq ""} { continue }
        catch {image delete $name}
        if {[catch {image create photo $name -file $p} img]} { continue }
        lappend imgs $img
        if {$file eq "icon.png"} {
            set ::els::iconImage $img
            set ::els::iconPath $p
        }
    }
    if {![llength $imgs]} { return }
    set ::els::iconImages $imgs
    set ::els::iconLoaded 1
    wm iconphoto . -default {*}$imgs
}
# ---- config location ----------------------------------------------------
# els keeps its settings and backup ring beside the program.
# A source/dev run uses the source directory (not the shared wish directory);
# a packaged zipfs build uses the directory containing els.exe.
proc els::config_roots {} {
    # "next to the program" = the exe's folder when packaged, the script's
    # folder (the repo) in a dev run.
    # Use the boot script captured at load time, NOT `info script`: this resolver
    # can run from a later callback where `info script` is "".  That used to miss
    # the zipfs branch and normalize "" to ".", turning the adjacent state path
    # into cwd-relative "./els.conf" (state written into whichever directory the
    # launch happened from).  Same fix association_exe already carries.
    set bs $::els::boot_script
    if {[string match "//zipfs:*" $bs]} {
        set progdir [file dirname [info nameofexecutable]]
    } else {
        set progdir [file dirname [file normalize $bs]]
    }
    return [list $progdir]
}
proc els::config_candidates {{name els.conf}} {
    set near [lindex [els::config_roots] 0]
    return [list [file join $near $name]]
}
proc els::config_legacy_candidates {} {
    return [els::config_candidates config.tcl]
}
proc els::config_file {} { return $::els::config_path }

# Large files discovered by non-interactive startup/session paths are
# never read silently and never trigger a timer-driven modal.  Keep them in their
# own tiny adjacent state file: writing els.conf here would also rewrite session
# ownership while startup is still deciding whether to adopt the previous one.
proc els::deferred_path {} {
    if {$::els::config_path eq ""} { return "" }
    return [file join [file dirname $::els::config_path] els.deferred]
}
proc els::deferred_sanitize {paths} {
    set out {}
    foreach p $paths {
        set n [els::session_path $p]
        if {$n eq ""} { continue }
        set duplicate 0
        foreach old $out {
            if {[els::same_path $old $n]} { set duplicate 1 ; break }
        }
        if {!$duplicate} { lappend out $n }
    }
    return $out
}
# Preserve a corrupt queue before allowing any new writer to replace it.  Kept
# as a seam so fault tests can prove that a failed quarantine blocks overwrite.
proc els::deferred_quarantine {path} {
    set stamp "[clock seconds]-[pid]-[clock clicks]"
    set target "$path.corrupt-$stamp"
    file rename $path $target
    return $target
}
proc els::deferred_load {} {
    set ::els::deferred_files {}
    set ::els::deferred_blocked 0
    set ::els::deferred_notice ""
    set p [els::deferred_path]
    if {$p eq "" || ![file exists $p]} { return }
    # Distinguish a TRANSIENT read fault (a sharing violation or I/O error while AV
    # or a backup tool briefly holds a perfectly valid file) from real content
    # corruption.  Only corruption should quarantine; a transient fault must leave
    # the intact queue in place and block writes this run so a later deferred_add
    # cannot clobber the good file with an empty list (R10).  So read the bytes here,
    # BEFORE the quarantine catch -- and the return on failure sits at proc scope,
    # never inside a catch (catch would trap TCL_RETURN into the quarantine path).
    # A directory at the path is NOT read (it is corruption); it falls through to the
    # quarantine catch below, preserving the directory-quarantine contract.
    set raw ""
    if {![file isdirectory $p]} {
        set fh ""
        if {[catch {
            set fh [::open $p r]
            fconfigure $fh -translation binary
            set raw [read $fh [expr {$::els::DEFERRED_MAX_BYTES + 1}]]
            close $fh
            set fh ""
        } ioerr]} {
            if {$fh ne ""} { catch {close $fh} }
            set ::els::deferred_blocked 1
            set ::els::deferred_notice "deferred-open state could not be read; it was left untouched"
            catch {els::log warn "deferred-open state at $p could not be read ($ioerr); preserved for retry"}
            return
        }
    }
    set problem ""
    if {[catch {
        if {[file isdirectory $p]} { error "state path is a directory" }
        if {[string length $raw] > $::els::DEFERRED_MAX_BYTES} { error "state file exceeds size limit" }
        set data [encoding convertfrom -profile strict utf-8 $raw]
        # Force one exact dict parse and accept only the schema we actually
        # understand.  Unknown/trailing keys are not silently rewritten away.
        dict size $data
        if {[llength $data] != 4} { error "duplicate or incomplete fields" }
        if {[lsort [dict keys $data]] ne {files schema}} { error "unexpected fields" }
        if {![string is integer -strict [dict get $data schema]] || [dict get $data schema] != 1} {
            error "unsupported schema"
        }
        set files [dict get $data files]
        llength $files
        set ::els::deferred_files [els::deferred_sanitize $files]
    } problem]} {
        set ::els::deferred_files {}
        if {[catch {set quarantined [els::deferred_quarantine $p]} qerr]} {
            # The evidence could not be moved aside.  Leave the original bytes
            # untouched and prohibit every queue write for this run.
            set ::els::deferred_blocked 1
            set ::els::deferred_notice "deferred-open state is corrupt and could not be quarantined"
            catch {els::log error "invalid deferred-open state at $p ($problem); quarantine failed: $qerr"}
        } else {
            set ::els::deferred_notice "corrupt deferred-open state was quarantined"
            catch {els::log warn "invalid deferred-open state at $p ($problem); preserved as $quarantined"}
        }
    }
}
proc els::deferred_save {} {
    if {$::els::deferred_blocked} {
        catch {els::log error "refusing to overwrite corrupt deferred-open state"}
        catch {els::status_note "deferred file list is blocked; corrupt state was preserved"}
        return 0
    }
    set p [els::deferred_path]
    if {$p eq ""} { return 0 }
    if {[catch {
        set payload [dict create schema 1 files [els::deferred_sanitize $::els::deferred_files]]
        encoding convertto -profile strict utf-8 $payload
    } bytes]} {
        catch {els::log warn "could not encode deferred-open state without loss: $bytes"}
        catch {els::status_note "deferred file list contains an invalid path and was not saved"}
        return 0
    }
    set err [els::write_atomic $p $bytes ".els-deferred-[pid]-[clock clicks].tmp"]
    if {$err ne ""} {
        catch {els::log warn "could not persist deferred opens to $p: $err"}
        catch {els::status_note "deferred file list could not be saved"}
        return 0
    }
    return 1
}
proc els::deferred_contains {p} {
    foreach old $::els::deferred_files {
        if {[els::same_path $old $p]} { return 1 }
    }
    return 0
}
proc els::deferred_add {p} {
    set n [els::session_path $p]
    if {$n eq "" || [els::deferred_contains $n]} { return 0 }
    set old $::els::deferred_files
    lappend ::els::deferred_files $n
    if {![els::deferred_save]} {
        # The queue is a durability promise.  Never claim success for a path
        # that exists only in RAM and would vanish at the next process exit.
        set ::els::deferred_files $old
        if {[winfo exists .deferred]} { els::deferred_dialog_refresh }
        return 0
    }
    if {[winfo exists .deferred]} { els::deferred_dialog_refresh }
    return 1
}
proc els::deferred_remove_many {paths} {
    set before $::els::deferred_files
    set kept {}
    set changed 0
    foreach queued $::els::deferred_files {
        set remove 0
        foreach p $paths {
            if {[els::same_path $queued $p]} { set remove 1 ; break }
        }
        if {$remove} { set changed 1 } else { lappend kept $queued }
    }
    if {!$changed} { return 0 }
    set ::els::deferred_files $kept
    if {![els::deferred_save]} {
        # Retaining an already-open duplicate is harmless; forgetting an entry
        # without durably publishing that removal is not.  Roll memory back too.
        set ::els::deferred_files $before
        if {[winfo exists .deferred]} { els::deferred_dialog_refresh }
        return 0
    }
    if {[winfo exists .deferred]} { els::deferred_dialog_refresh }
    return 1
}
# Single choke point for resolving the config location: the instant the dir is
# known, pin it and make sure it exists -- so settings, the backup ring, and (if
# enabled) autosave all have a home before the first save or a session restore.
proc els::set_config_path {p} {
    set ::els::config_path $p
    if {$p ne "" && !$::els::selftest} {
        catch {file mkdir [file dirname $p]}
    }
}
# Pin config_path immediately, even when no state file exists yet.  Return 1
# when an existing config (including old adjacent config.tcl) was found, else 0.
proc els::config_resolve_existing {} {
    set near [lindex [els::config_candidates] 0]
    set existed [file exists $near]
    els::set_config_path $near
    if {$existed} { return 1 }
    set oldNear [lindex [els::config_legacy_candidates] 0]
    if {[file exists $oldNear]} {
        catch {file copy -force $oldNear $near}
        return 1
    }
    return 0
}
# The VIRTUAL desktop rect {x y w h} — the bounding box of ALL monitors, with a
# possibly-negative top-left.  From the native GetSystemMetrics(SM_*VIRTUALSCREEN)
# helper; falls back to {0 0 <wm maxsize>} for a dev/tclsh run without the native
# command (single-monitor-correct only — the shipped exe always has the helper).
proc els::virtual_screen {} {
    if {[llength [info commands ::els::win_virtual_screen]]} {
        if {![catch {els::win_virtual_screen} r] && [llength $r] == 4 && [lindex $r 2] > 0} {
            return $r
        }
    }
    return [list 0 0 {*}[wm maxsize .]]
}
# Clamp a saved "WxH+X+Y" so a window saved on a since-disconnected monitor (or a
# corrupt/hand-edited config) cannot restore fully off-screen, where it looks like
# els failed to launch and is unrecoverable without deleting els.conf (R7).  The
# virtual-desktop rect {vx vy vw vh} is passed in (all monitors, real origin) so
# this stays a pure, testable function.  We keep the saved size and reset only the
# ORIGIN — to +60+60 (always on the primary, whose top-left is 0,0 on Windows) —
# when the title bar has no reachable presence on any monitor.  A window on a
# monitor left/above (negative coords) or right/below the primary is KEPT because
# the real virtual rect covers it.  A size-only geometry is returned unchanged.
# A negative origin reads back from Windows Tk in the "+-N" form (e.g. x=-137 ->
# "...+-137+60"); the regexp accepts the optional sign after the +/- separator,
# and `expr` reads "+-137" as -137, so the arithmetic below is correct.
proc els::clamp_geometry {g vx vy vw vh} {
    if {[regexp {^([0-9]+)x([0-9]+)([+-])(-?[0-9]+)([+-])(-?[0-9]+)$} $g -> W H sepX X sepY Y]} {
        # Tk geometry offsets: `+N` is N px from the left/top; `-N` anchors the
        # window's FAR edge N px from the screen's far edge (from-right/from-bottom).
        # Convert a from-far form to an absolute left/top before the on-screen check,
        # so a hand-edited `-N` isn't misread as an absolute negative coordinate
        # (mat-1).  Tk itself reports a negative origin as `+-N`, whose signed number
        # the capture above already carries (e.g. "+-137" -> X = -137), so no trimleft.
        if {$sepX eq "-"} { set X [expr {$vx + $vw - $X - $W}] }
        if {$sepY eq "-"} { set Y [expr {$vy + $vh - $Y - $H}] }
        set m 90   ;# min grabbable title-bar presence on the desktop
        # the title bar's top edge must sit within the desktop vertically, and the
        # window must overlap it horizontally by at least m px
        set titleY  [expr {$Y >= $vy && $Y <= $vy + $vh - $m}]
        set overlapX [expr {$X + $W > $vx + $m && $X < $vx + $vw - $m}]
        if {!($titleY && $overlapX)} {
            return "${W}x${H}+60+60"
        }
    }
    return $g
}

# els persists a tiny config dict (geometry + recent).  Readers/writers tolerate
# an empty/unset path, a missing file, or missing keys (forward/back compat).
# Read els.conf into its raw dict, tolerating a partially-corrupt file: the
# channel uses -profile replace, so ONE invalid byte (a hand-edit in an ANSI
# editor, sync corruption) degrades to U+FFFD in that value instead of throwing
# EILSEQ and discarding EVERY setting -- and leaking the open channel, which then
# blocked all future saves.  "" when there is no readable config.
proc els::config_read {} {
    set f [els::config_file]
    if {$f eq "" || ![file exists $f] || [file isdirectory $f]} { return "" }
    set data ""
    if {[catch {
        set fh [::open $f r]
        fconfigure $fh -encoding utf-8 -profile replace
        set data [read $fh]
        close $fh
    }]} {
        catch {close $fh}
        return ""
    }
    return $data
}
proc els::load_geometry {} {
    set data [els::config_read]
    if {$data eq ""} { return }
    # Per-VALUE validation, not just per-key fetch guards: els.conf is a plain
    # text file (hand-editable, sync-corruptible), and an invalid value used to
    # throw out of build before any widget existed — els could not start again
    # until the user found and deleted the config.  Readers tolerate anything.
    if {![catch {dict get $data geometry} g] && \
        [regexp {^[0-9]+x[0-9]+([+-]-?[0-9]+[+-]-?[0-9]+)?$} $g]} {
        set cg [els::clamp_geometry $g {*}[els::virtual_screen]]
        catch {wm geometry . $cg}
        # seed the normal-geometry baseline NOW, before any zoom: the <Configure>
        # tracker only fires later, so on a restore-into-zoomed session (below)
        # geom_normal would otherwise stay "" and a maximized quit would persist
        # the maximized rect as the normal window (R7)
        set ::els::geom_normal $cg
    }
    # restore a maximized session (persisted separately from the normal geometry
    # so a maximized quit doesn't strand the huge rect as a "normal" window)
    if {![catch {dict get $data zoomed} zm] && [string is boolean -strict $zm] && $zm} {
        catch {wm state . zoomed}
    }
    if {![catch {dict get $data recent} r]} {
        catch {set ::els::recent [els::recent_sanitize $r]}
    }
    if {![catch {dict get $data word_wrap} w] && [string is boolean -strict $w]} {
        set ::els::word_wrap [expr {$w ? 1 : 0}]
        if {[info exists ::els::docs] && [llength $::els::docs]} {
            catch {els::set_wrap 0}
        }
    }
    if {![catch {dict get $data show_whitespace} ws] && [string is boolean -strict $ws]} {
        set ::els::show_ws [expr {$ws ? 1 : 0}]
        if {[info exists ::els::docs] && [llength $::els::docs]} {
            catch {els::ws_refresh}
        }
    }
    if {![catch {dict get $data line_numbers} lnv] && [string is boolean -strict $lnv]} {
        set ::els::show_linenos [expr {$lnv ? 1 : 0}]
        catch {els::set_linenos 0}
    }
    if {![catch {dict get $data focus_mode} fm] && [string is boolean -strict $fm]} {
        set ::els::focus_mode [expr {$fm ? 1 : 0}]
        if {[info exists ::els::docs] && [llength $::els::docs]} { catch {els::set_focus_mode 0} }
    }
    if {![catch {dict get $data autosave} asv] && [string is boolean -strict $asv]} {
        set ::els::autosave [expr {$asv ? 1 : 0}]
    }
    if {![catch {dict get $data backups} bkv] && [string is boolean -strict $bkv]} {
        set ::els::backups [expr {$bkv ? 1 : 0}]
    }
    if {![catch {dict get $data always_on_top} t] && [string is boolean -strict $t]} {
        set ::els::always_on_top [expr {$t ? 1 : 0}]
        catch {els::set_always_on_top 0}
    }
    if {![catch {dict get $data font_size} fs] && [string is integer -strict $fs]} {
        catch {els::set_font_size $fs 0}   ;# apply the saved zoom (no re-persist)
    }
    if {![catch {dict get $data restore_session} rs] && [string is boolean -strict $rs]} {
        set ::els::restore_session [expr {$rs ? 1 : 0}]
    }
    if {![catch {dict get $data session_files} sf]} {
        catch {set ::els::session_files [els::session_sanitize $sf]}
    }
    if {![catch {dict get $data session_active} sa]} {
        catch {set ::els::session_active [els::session_path $sa]}
    }
}
# Record the window's normal-state geometry (see the <Configure> binding).
proc els::track_geometry {} {
    if {[wm state .] eq "normal"} { catch {set ::els::geom_normal [wm geometry .]} }
}
proc els::save_geometry {} {
    if {$::els::selftest} { return }
    set f [els::config_file]
    if {$f eq ""} { return }
    # Build the whole payload BEFORE touching the file: a throw in any value
    # command (e.g. `wm geometry .` on a window being torn down at quit) must not
    # leave a truncated, empty config behind.
    if {[catch {
        if {$::els::session_owned} {
            set sf [els::session_current_files]
            # keep this run's un-restorable files (offline/locked at boot) in the
            # saved session so a transient outage doesn't erase them; once such a
            # file opens it appears in session_current_files and the dedupe skips it,
            # and closing a restored tab drops it as usual.  Dedupe with same_path
            # (case-insensitive on Windows), matching the rest of the module — a
            # different-case spelling of an open file must not be listed twice.
            foreach p [els::session_sanitize $::els::session_pending] {
                set dup 0
                foreach q $sf { if {[els::same_path $p $q]} { set dup 1 ; break } }
                if {!$dup} { lappend sf $p }
            }
            set sa [els::session_current_active]
        } else {
            # this run never adopted the saved session (an explicit-file-arg
            # launch skips session restore): write the STORED session back —
            # persisting this run's doc list would destroy the user's
            # multi-tab session just by double-clicking one file
            set sf $::els::session_files
            set sa $::els::session_active
        }
        # persist the NORMAL geometry + a zoomed flag, not the live rect (which is
        # the maximized rect while zoomed) — so a maximized quit restores maximized
        # over a sane underlying window, not a monitor-sized "normal" window (R7)
        set zoomed [expr {[wm state .] eq "zoomed"}]
        if {$zoomed && $::els::geom_normal ne ""} {
            set geo $::els::geom_normal
        } else {
            set geo [wm geometry .]
        }
        # Merge the known keys OVER the existing conf dict rather than rebuilding
        # from scratch, so a key a NEWER els version added is preserved instead of
        # erased on the first save (every zoom notch / recent-open / quit) -- the
        # forward-compat the reader already promises (F57).
        set payload [els::config_read]
        if {![string is list $payload] || [llength $payload] % 2} { set payload "" }
        foreach {k v} [list \
                geometry $geo zoomed $zoomed recent $::els::recent \
                word_wrap $::els::word_wrap show_whitespace $::els::show_ws \
                focus_mode $::els::focus_mode line_numbers $::els::show_linenos \
                autosave $::els::autosave backups $::els::backups \
                always_on_top $::els::always_on_top font_size $::els::font_size \
                restore_session $::els::restore_session \
                session_files $sf session_active $sa] {
            dict set payload $k $v
        }
    }]} { return }
    # Write to a temp file then atomically rename, so a crash mid-write cannot
    # corrupt the existing config either.  pid-tagged temp: concurrent els
    # instances sharing the config dir must not publish each other's
    # half-written file through a fixed temp name.
    set tmp "$f.[pid].tmp"
    if {[catch {
        # `file rename -force` onto an existing DIRECTORY moves the temp INTO it
        # (silent non-persist), so refuse a directory config path outright -- fall
        # to the visible-failure handler below instead of pretending success (F55).
        if {[file isdirectory $f]} { error "the settings path is a directory, not a file" }
        file mkdir [file dirname $f]
        set fh [::open $tmp w]
        try { puts $fh $payload } finally { close $fh }
        file rename -force $tmp $f
    } e]} {
        catch {file delete -force $tmp}
        # persistence failure was silent before: prefs/session simply weren't
        # saved.  Log always; note once per streak so a read-only/full config dir
        # doesn't spam on every zoom notch.  Never block (this also runs at quit).
        catch {els::log warn "could not persist settings to $f: $e"}
        if {!$::els::geom_save_warned} {
            set ::els::geom_save_warned 1
            catch {els::status_note "settings could not be saved"}
        }
        return
    }
    set ::els::geom_save_warned 0
}

proc els::remote_path {path} {
    set slash [string map {\\ /} $path]
    if {[string match -nocase {//?/UNC/*} $slash]} { return 1 }
    if {[string range $slash 0 3] in {//?/ //./}} { return 0 }
    return [expr {[string range $slash 0 1] eq "//"}]
}
proc els::session_path {p} {
    if {$p eq ""} { return "" }
    # UNC normalization must stay lexical: asking the OS to canonicalize an
    # offline share can stall startup before the UI exists.
    if {[els::remote_path $p]} { return [string map {\\ /} $p] }
    if {[catch {file normalize $p} n]} { return "" }
    return $n
}
proc els::same_path {a b} {
    set pa [els::session_path $a]
    set pb [els::session_path $b]
    if {$pa eq "" || $pb eq ""} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} {
        return [string equal -nocase $pa $pb]
    }
    return [string equal $pa $pb]
}
proc els::session_sanitize {list} {
    set out {}
    foreach p $list {
        set n [els::session_path $p]
        if {$n eq "" || $n in $out} { continue }
        lappend out $n
    }
    return $out
}
proc els::session_current_files {} {
    set out {}
    foreach id $::els::docs {
        if {![info exists ::els::docPath($id)]} { continue }
        set p [els::session_path $::els::docPath($id)]
        if {$p eq "" || $p in $out} { continue }
        lappend out $p
    }
    return $out
}
proc els::session_current_active {} {
    if {$::els::active eq "" || ![info exists ::els::docPath($::els::active)]} {
        return ""
    }
    return [els::session_path $::els::docPath($::els::active)]
}
proc els::session_set_restore {} {
    els::save_geometry
}

# ---- deferred large-file opens ------------------------------------------
# The queue is intentionally modeless: it is the one foreground place where a
# user can inspect paths gathered by startup/session code and explicitly
# consent to the memory cost of opening them.
proc els::deferred_dialog_selected {} {
    set lb .deferred.f.list.lb
    if {![winfo exists $lb]} { return {} }
    set out {}
    foreach i [$lb curselection] {
        if {$i >= 0 && $i < [llength $::els::deferred_files]} {
            lappend out [lindex $::els::deferred_files $i]
        }
    }
    return $out
}
proc els::deferred_dialog_refresh {} {
    set lb .deferred.f.list.lb
    if {![winfo exists $lb]} { return }
    set selected [els::deferred_dialog_selected]
    $lb delete 0 end
    foreach p $::els::deferred_files { $lb insert end [els::display_path $p] }
    foreach p $selected {
        set i 0
        foreach q $::els::deferred_files {
            if {[els::same_path $p $q]} { $lb selection set $i ; break }
            incr i
        }
    }
    if {![llength [$lb curselection]] && [llength $::els::deferred_files]} {
        $lb selection set 0
        $lb activate 0
        $lb see 0
    }
    set state [expr {[llength $::els::deferred_files] ? "normal" : "disabled"}]
    .deferred.f.buttons.open configure -state $state
    .deferred.f.buttons.forget configure -state $state
}
proc els::deferred_dialog_select_all {} {
    set lb .deferred.f.list.lb
    if {[winfo exists $lb] && [$lb size]} { $lb selection set 0 end }
}
proc els::deferred_dialog_open {} {
    set paths [els::deferred_dialog_selected]
    foreach p $paths {
        # This button is deliberate foreground consent.  Bypass the threshold,
        # but retain the normal open error dialog; a failed open stays queued.
        els::open $p 0 0 1
    }
    if {[winfo exists .deferred.f.list.lb]} { focus .deferred.f.list.lb }
}
proc els::deferred_dialog_forget {} {
    set paths [els::deferred_dialog_selected]
    if {[llength $paths]} { els::deferred_remove_many $paths }
    if {[winfo exists .deferred.f.list.lb]} { focus .deferred.f.list.lb }
}
proc els::deferred_dialog {} {
    set top .deferred
    if {[winfo exists $top]} {
        wm deiconify $top
        raise $top
        focus $top.f.list.lb
        return
    }
    toplevel $top -bg $::els::PAGE
    wm withdraw $top
    if {$::els::probe_quiet || (![catch {wm attributes . -alpha} rootAlpha] && $rootAlpha == 0.0)} {
        catch {wm attributes $top -alpha 0.0}
    }
    wm title $top "Deferred Opens"
    wm transient $top .
    ttk::frame $top.f -padding 16
    pack $top.f -fill both -expand 1
    ttk::label $top.f.h -text "Files waiting for a deliberate open" -font elsUIb \
        -foreground $::els::INK
    ttk::label $top.f.s -font elsUI -foreground $::els::MUTED -justify left \
        -text "Large files received during startup or session restore are held here."
    grid $top.f.h -row 0 -column 0 -sticky w -pady {0 3}
    grid $top.f.s -row 1 -column 0 -sticky w -pady {0 12}
    ttk::frame $top.f.list
    set lb $top.f.list.lb
    listbox $lb -height 10 -width 72 -selectmode extended -exportselection 0 \
        -font elsUI -bg $::els::PAGE -fg $::els::INK \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -highlightcolor $::els::CARET -highlightbackground $::els::HAIR \
        -yscrollcommand [list $top.f.list.vs set] \
        -xscrollcommand [list $top.f.list.hs set]
    ttk::scrollbar $top.f.list.vs -orient vertical -command [list $lb yview]
    ttk::scrollbar $top.f.list.hs -orient horizontal -command [list $lb xview]
    grid $lb -row 0 -column 0 -sticky nsew
    grid $top.f.list.vs -row 0 -column 1 -sticky ns
    grid $top.f.list.hs -row 1 -column 0 -sticky ew
    grid columnconfigure $top.f.list 0 -weight 1
    grid rowconfigure $top.f.list 0 -weight 1
    grid $top.f.list -row 2 -column 0 -sticky nsew -pady {0 12}
    ttk::frame $top.f.buttons
    ttk::button $top.f.buttons.open -text "Open selected" -style Dialog.TButton \
        -default active -command els::deferred_dialog_open
    ttk::button $top.f.buttons.forget -text "Forget selected" -style Dialog.TButton \
        -command els::deferred_dialog_forget
    ttk::button $top.f.buttons.close -text Close -style Dialog.TButton \
        -command [list destroy $top]
    grid $top.f.buttons.open -row 0 -column 0 -padx {0 6}
    grid $top.f.buttons.forget -row 0 -column 1 -padx {0 6}
    grid $top.f.buttons.close -row 0 -column 2
    grid $top.f.buttons -row 3 -column 0 -sticky e
    grid columnconfigure $top.f 0 -weight 1
    grid rowconfigure $top.f 2 -weight 1
    bind $lb <Control-KeyPress-a> {els::deferred_dialog_select_all; break}
    bind $lb <Control-KeyPress-A> {els::deferred_dialog_select_all; break}
    bind $lb <KeyPress-Return> {els::deferred_dialog_open; break}
    bind $lb <KeyPress-KP_Enter> {els::deferred_dialog_open; break}
    bind $lb <KeyPress-Delete> {els::deferred_dialog_forget; break}
    bind $lb <Double-Button-1> {els::deferred_dialog_open; break}
    bind $top <Escape> [list destroy $top]
    # Enter also accepts from the -default active "Open selected" button after Tab
    # (Tk 9's TButton ignores Return); the listbox's own Return binding breaks, so
    # this toplevel binding never double-fires when the list has focus (R21).
    bind $top <Return>   els::deferred_dialog_open
    bind $top <KP_Enter> els::deferred_dialog_open
    wm protocol $top WM_DELETE_WINDOW [list destroy $top]
    els::deferred_dialog_refresh
    update idletasks
    set width [winfo reqwidth $top]
    set height [winfo reqheight $top]
    wm minsize $top 520 $height
    wm resizable $top 1 0
    set x [expr {[winfo rootx .] + ([winfo width .] - $width) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - $height) / 2}]
    wm geometry $top +$x+$y
    wm deiconify $top
    focus $lb
}

# ---- recent files -------------------------------------------------------
# A small MRU list under File ▸ Open Recent, persisted with the config.  The
# menu opens files quickly; a separate manager handles cleanup so the menu stays
# light instead of growing a removal submenu.
proc els::recent_sanitize {list} {
    set out {}
    foreach p $list {
        if {$p eq ""} { continue }
        # dedupe case-insensitively (els::same_path), like the rest of the module
        # (open/save-as/session): else a differently-cased spelling of one file
        # would occupy two recent slots (F33)
        set dup 0
        foreach q $out { if {[els::same_path $p $q]} { set dup 1 ; break } }
        if {$dup} { continue }
        lappend out $p
        if {[llength $out] >= $::els::recent_cap} { break }
    }
    return $out
}
proc els::recent_add {p} {
    if {$p eq ""} { return }
    set p [file normalize $p]
    # drop any prior entry for the SAME file (same_path, not exact spelling), so
    # re-opening it under a different case moves the one entry to the top (F33)
    set rest {}
    foreach q $::els::recent { if {![els::same_path $p $q]} { lappend rest $q } }
    set ::els::recent [els::recent_sanitize [linsert $rest 0 $p]]
    els::recent_rebuild
    els::save_geometry
    # the Maintain List dialog is modeless and maps row indices into THIS list:
    # without a refresh (it no-ops when closed), every action past the
    # insertion point — Remove, Open, the detail label, the hover tip — acted
    # on a DIFFERENT file than the row displayed
    els::recent_manage_refresh
}
proc els::recent_remove {p} {
    # remove every entry for the same file (same_path), so Remove clears a file
    # even if it lingered under two case spellings (F33)
    set out {}
    foreach q $::els::recent { if {![els::same_path $p $q]} { lappend out $q } }
    set ::els::recent $out
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
proc els::recent_clear {} {
    set ::els::recent {}
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
# Open a recent entry; returns the document id, or "" when nothing was opened
# (missing file, or els::open failed — unreadable/directory/permission).
proc els::recent_open {p} {
    if {[winfo exists .recent]} { set par .recent } else { set par . }
    if {![file exists $p]} {
        set ans [els::message_box -parent $par -icon question -type yesno -title els \
            -message "This file no longer exists:\n[els::display_path $p]\n\nRemove it from the list?"]
        if {$ans eq "yes"} { els::recent_remove $p }
        return ""
    }
    return [els::open $p]
}
# Elide a path to at most `max` characters in the SAME style as els::elide_path
# (keep the filename, drop leading directories behind a leading "…/"), but by
# character budget rather than pixel width — for places without a measurable
# width, like a menu label.
proc els::elide_path_chars {p max} {
    set p [els::strip_ext_prefix $p]
    if {[string length $p] <= $max} { return $p }
    set parts [file split $p]
    set best ""
    for {set i [expr {[llength $parts] - 1}]} {$i >= 0} {incr i -1} {
        set tail [file join {*}[lrange $parts $i end]]
        set cand [expr {$i == 0 ? $tail : "…/$tail"}]
        if {[string length $cand] <= $max} { set best $cand } else { break }
    }
    if {$best ne ""} { return $best }
    # even the filename alone is too long — clip its head, keep the end
    set s [file tail $p]
    if {[string length $s] > $max - 1} { set s [string range $s end-[expr {$max - 2}] end] }
    return "…$s"
}
# A compact Open-Recent menu label: same elision style as the status bar and the
# recent-files window (filename kept, leading dirs dropped behind "…/").
proc els::recent_label {p} {
    return [els::elide_path_chars $p 64]
}
proc els::recent_rebuild {} {
    set m .menu.file.recent
    if {![winfo exists $m]} { return }
    $m delete 0 end
    if {![llength $::els::recent]} {
        $m add command -label "(empty)" -state disabled
    } else {
        foreach p $::els::recent {
            $m add command -label [els::recent_label $p] -command [list els::recent_open $p]
        }
    }
    $m add separator
    $m add command -label "Maintain List..." -command els::recent_manage
}
proc els::recent_manage {} {
    catch {destroy .recent}
    toplevel .recent -bg $::els::PAGE
    wm withdraw .recent
    wm title .recent "Recent Files"
    wm transient .recent .
    set bg $::els::PAGE
    ttk::frame .recent.f -padding 18
    pack .recent.f -fill both -expand 1
    ttk::label .recent.f.h -text "Recent Files" -font elsUIb -foreground $::els::INK
    ttk::label .recent.f.s -text "Open, remove, or clean up missing entries." \
        -font elsUI -foreground $::els::MUTED
    grid .recent.f.h -row 0 -column 0 -columnspan 3 -sticky w
    grid .recent.f.s -row 1 -column 0 -columnspan 3 -sticky w -pady {2 12}

    listbox .recent.f.list -font elsUI -height 10 -activestyle none \
        -borderwidth 0 -highlightthickness 1 -highlightbackground $::els::HAIR \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -bg $bg -fg $::els::INK -yscrollcommand els::recent_vs
    ttk::scrollbar .recent.f.vs -orient vertical -command {.recent.f.list yview}
    grid .recent.f.list -row 2 -column 0 -columnspan 2 -sticky nsew
    grid .recent.f.vs   -row 2 -column 2 -sticky ns

    ttk::label .recent.f.path -text "" -font elsUI -foreground $::els::MUTED -anchor w
    grid .recent.f.path -row 3 -column 0 -columnspan 3 -sticky ew -pady {8 14}

    ttk::frame .recent.f.buttons
    grid .recent.f.buttons -row 4 -column 0 -columnspan 3 -sticky ew
    ttk::button .recent.f.buttons.open -text Open -style Dialog.TButton \
        -default active -command els::recent_manage_open
    ttk::button .recent.f.buttons.remove -text Remove -style Dialog.TButton -command els::recent_manage_remove
    ttk::button .recent.f.buttons.missing -text "Remove Missing" -style Dialog.TButton -command els::recent_manage_remove_missing
    ttk::button .recent.f.buttons.clear -text Clear -style Dialog.TButton -command els::recent_manage_clear
    ttk::button .recent.f.buttons.close -text Close -style Dialog.TButton -command {destroy .recent}
    pack .recent.f.buttons.close .recent.f.buttons.clear .recent.f.buttons.missing \
         .recent.f.buttons.remove .recent.f.buttons.open -side right -padx {6 0}

    grid columnconfigure .recent.f 0 -weight 1
    grid rowconfigure .recent.f 2 -weight 1
    bind .recent.f.list <<ListboxSelect>> els::recent_manage_select
    bind .recent.f.list <Double-Button-1> els::recent_manage_open
    bind .recent.f.list <Return>   {els::recent_manage_open ; break}
    bind .recent.f.list <KP_Enter> {els::recent_manage_open ; break}
    # Enter also accepts from the -default active Open button after Tab (Tk 9's
    # TButton ignores Return); the listbox binding breaks, so no double-fire (R21).
    bind .recent <Return>   els::recent_manage_open
    bind .recent <KP_Enter> els::recent_manage_open
    # re-elide the rows AND the detail label to the current width on any resize
    bind .recent.f.list <Configure> els::recent_manage_refresh
    bind .recent <Escape> {destroy .recent}
    bind .recent <Delete> els::recent_manage_remove
    # full native path on hover: per row in the list, and on the detail label
    set ::els::recent_row_tip -1
    set ::els::recent_sel_path ""
    bind .recent.f.list <Motion> {els::recent_row_motion %x %y %X %Y}
    bind .recent.f.list <Leave>  {els::tip_cancel ; set ::els::recent_row_tip -1}
    # the row tips are scheduled manually (not via tooltip_for), so the dialog
    # dying must cancel a pending one itself — else the after-550 fires over a
    # destroyed dialog and pops an orphan -topmost tip at the old cursor spot
    bind .recent.f.list <Destroy> {+els::tip_cancel}
    els::tooltip_for .recent.f.path els::recent_detail_tip

    els::recent_manage_refresh
    update idletasks
    # Pin a deliberate size, then keep it: a long selected path must NOT balloon
    # the dialog through geometry propagation.  Width comes from the button row /
    # subtitle plus a comfortable default — never from the longest path — and the
    # rows + detail label elide to whatever width we settle on.  Height is one
    # detail line plus chrome (the label is single-line, so it never grows tall).
    set pad 44                              ;# frame padding (18*2) + a little slack
    set minw [expr {[winfo reqwidth .recent.f.buttons] + $pad}]
    set defw [expr {[font measure elsUI [string repeat n 52]] + $pad}]
    set w [expr {max($minw, $defw)}]
    set h [winfo reqheight .recent]
    wm minsize .recent $minw $h
    set x [expr {[winfo rootx .] + ([winfo width .]  - $w) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - $h) / 3}]
    wm geometry .recent ${w}x${h}+$x+$y
    wm deiconify .recent
    update idletasks
    els::recent_manage_refresh   ;# the window now has its real width: elide to it
    focus .recent.f.list
}
# Pixel width available for a row of text inside the recent listbox (minus its
# highlight border and a little breathing room).  Returns a huge value while the
# widget is unrealized so the first fill shows full paths until the real width is
# known (a <Configure> then re-elides).
proc els::recent_manage_avail {} {
    set lb .recent.f.list
    if {![winfo exists $lb]} { return 100000 }
    set w [expr {[winfo width $lb] - 12}]
    return [expr {$w < 24 ? 100000 : $w}]
}
# Same idea for the bottom detail label (it spans the full content width).
proc els::recent_detail_avail {} {
    set l .recent.f.path
    if {![winfo exists $l]} { return 100000 }
    set w [expr {[winfo width $l] - 8}]
    return [expr {$w < 24 ? 100000 : $w}]
}
# Tooltip text for the detail label: the full native path, but only while the
# label is actually eliding it (mirrors the status-bar name tip).
proc els::recent_detail_tip {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return "" }
    if {[els::elide_path $p [els::recent_detail_avail]] eq $p} { return "" }
    return [els::path_tip $p]
}
# Per-row hover tooltip for the recent listbox: when the cursor is over a row
# whose displayed path is elided, show the full native path near the cursor.
proc els::recent_row_motion {x y rx ry} {
    variable recent_row_tip
    set lb .recent.f.list
    if {![winfo exists $lb] || ![llength $::els::recent]} { return }
    set i [$lb index @$x,$y]
    if {$i eq "" || $i < 0 || $i >= [llength $::els::recent]} {
        els::tip_cancel ; set recent_row_tip -1 ; return
    }
    # `index @x,y` CLAMPS to the nearest row, so in the empty area below the
    # last row it still answers the last index — require the pointer to be
    # inside that row's actual cell before offering its tip
    set bb [$lb bbox $i]
    if {$bb eq "" || $y < [lindex $bb 1] || $y >= [lindex $bb 1] + [lindex $bb 3]} {
        els::tip_cancel ; set recent_row_tip -1 ; return
    }
    if {$recent_row_tip == $i} { return }   ;# already handling this row
    set recent_row_tip $i
    els::tip_cancel
    set p [lindex $::els::recent $i]
    if {[$lb get $i] eq $p} { return }      ;# row not elided -> no tip
    set ::els::tip_after [after 550 \
        [list els::tip_pop_at [els::path_tip $p] [expr {$rx + 14}] [expr {$ry + 18}]]]
}
# The Maintain List scrollbar appears only when the list overflows.  The
# grid/grid-remove is a geometry change, so it is deferred to idle and
# coalesced (same discipline as the editor's own bars).
proc els::recent_vs {first last} {
    if {![winfo exists .recent.f.vs]} { return }
    .recent.f.vs set $first $last
    after cancel $::els::recent_vs_after
    set ::els::recent_vs_after [after idle els::recent_vs_apply]
}
proc els::recent_vs_apply {} {
    if {![winfo exists .recent.f.list]} { return }
    if {[winfo ismapped .recent.f.list]} {
        lassign [.recent.f.list yview] first last
        set need [expr {$first > 0.0001 || $last < 0.9999}]
    } else {
        # unmapped (e.g. a withdrawn dialog): yview degenerates to {0 1}, so
        # fall back to rows-vs-height (the dialog's height is pinned anyway)
        set need [expr {[.recent.f.list size] > [.recent.f.list cget -height]}]
    }
    if {$need} { grid .recent.f.vs } else { grid remove .recent.f.vs }
}
proc els::recent_manage_refresh {} {
    if {![winfo exists .recent.f.list]} { return }
    set lb .recent.f.list
    set avail [els::recent_manage_avail]
    $lb delete 0 end
    # elide too-long paths exactly like the status-bar name (keep the filename,
    # drop leading dirs behind "…/"); the full native path still shows in the
    # detail label below on selection.  Index->path mapping is unaffected because
    # selection is read by row index, not by the displayed text.
    foreach p $::els::recent { $lb insert end [els::elide_path $p $avail] }
    if {[llength $::els::recent]} {
        # restore the selection by PATH (tracked at select time), not by row
        # index: after the list reordered (recent_add while the dialog is open)
        # the old index would point at whatever file moved into that row
        set old [lsearch -exact $::els::recent $::els::recent_sel_path]
        if {$old < 0} { set old 0 }
        $lb selection set $old
        $lb activate $old
        $lb see $old
    }
    els::recent_manage_select
}
proc els::recent_manage_index {} {
    if {![winfo exists .recent.f.list]} { return -1 }
    set sel [.recent.f.list curselection]
    if {![llength $sel]} { return -1 }
    return [lindex $sel 0]
}
proc els::recent_manage_path {} {
    set i [els::recent_manage_index]
    if {$i < 0 || $i >= [llength $::els::recent]} { return "" }
    return [lindex $::els::recent $i]
}
proc els::recent_manage_select {} {
    if {![winfo exists .recent.f.path]} { return }
    set p [els::recent_manage_path]
    set has [expr {$p ne ""}]
    if {$has} { set ::els::recent_sel_path $p }   ;# track selection by PATH for refresh
    set hasMissing 0
    foreach r $::els::recent {
        if {![file exists $r]} { set hasMissing 1 ; break }
    }
    # elide the detail path too (full native path is on hover) so a long path
    # can't stretch the dialog wide.  (if/else, not an expr ternary: expr
    # canonicalizes number-looking operands, mangling a path like "007")
    if {$has} {
        set detail [els::elide_path $p [els::recent_detail_avail]]
    } else {
        set detail "No recent files"
    }
    .recent.f.path configure -text $detail
    foreach b {.recent.f.buttons.open .recent.f.buttons.remove} {
        $b configure -state [expr {$has ? "normal" : "disabled"}]
    }
    .recent.f.buttons.missing configure -state [expr {$hasMissing ? "normal" : "disabled"}]
    .recent.f.buttons.clear configure -state [expr {[llength $::els::recent] ? "normal" : "disabled"}]
}
proc els::recent_manage_open {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return }
    # close the dialog only when the open actually SUCCEEDED: `file exists` is
    # true for directories and unreadable files, and an error used to take the
    # dialog down with it — exactly when the user came here to clean the list
    if {[els::recent_open $p] ne ""} {
        catch {destroy .recent}
    } else {
        els::recent_manage_refresh
    }
}
proc els::recent_manage_remove {} {
    set p [els::recent_manage_path]
    if {$p eq ""} { return }
    els::recent_remove $p
}
proc els::recent_manage_remove_missing {} {
    set kept {}
    foreach p $::els::recent {
        if {[file exists $p]} { lappend kept $p }
    }
    set ::els::recent $kept
    els::recent_rebuild
    els::save_geometry
    els::recent_manage_refresh
}
proc els::recent_manage_clear {} {
    if {![llength $::els::recent]} { return }
    set ans [els::message_box -parent .recent -icon question -type yesno -title els \
        -message "Clear the recent files list?"]
    if {$ans eq "yes"} { els::recent_clear }
}

# ---- Windows integration ------------------------------------------------
# Register els as an available .txt handler; Windows still lets the user choose
# the default app.  This writes only to HKCU, so it needs no admin rights.
proc els::association_exe {} {
    # Use the boot script captured at load time, NOT `info script` — this proc
    # runs from a button callback where `info script` is "", which previously made
    # us fall back to a cwd-relative els.exe lookup (so registration only worked
    # when els happened to be launched from its own folder).
    set bs $::els::boot_script
    if {[string match {//zipfs:*} $bs]} { return [file normalize [info nameofexecutable]] }
    if {$bs eq ""} { return "" }
    set near [file join [file dirname [file normalize $bs]] els.exe]
    if {[file exists $near]} { return [file normalize $near] }
    return ""
}
# The curated set of plain-text file types els advertises itself for (declared as
# SupportedTypes / Capabilities so els surfaces for them in Open with and Default
# apps).  Code/markup (json, xml, html, js, py, ...) is deliberately absent: els
# has no syntax highlighting, so it should not claim to handle those.
proc els::assoc_exts {} {
    return {txt log ini conf cfg nfo text toml yaml yml csv tsv env properties srt}
}
# reg.exe commands that register els with Windows as an application that can open
# files — type-independent, per-user (HKCU) only.  This makes "els" appear by name
# and icon in Explorer's Open with list for ANY file, and as a manageable entry in
# Settings > Default apps.  It NEVER sets a file type's default or touches
# UserChoice: the user picks els per type via Open with > Always.  The curated text
# extensions are merely DECLARED (SupportedTypes / Capabilities) so els surfaces for
# them and Default apps shows what it handles — declaring a type is not the same as
# becoming its default.
proc els::assoc_commands {exe} {
    set exe [file nativename [file normalize $exe]]
    set appExe [file tail $exe]
    set progid els.txt
    set openCmd [format {"%s" "%%1"} $exe]
    set icon [format {"%s",0} $exe]
    set clsKey "HKCU\\Software\\Classes\\$progid"
    set appKey "HKCU\\Software\\Classes\\Applications\\$appExe"
    set capKey {HKCU\Software\anafalanx\els\Capabilities}
    set cmds {}
    # one shared ProgID els uses to open a text file
    lappend cmds [list reg.exe add $clsKey /ve /d {els Text File} /f]
    lappend cmds [list reg.exe add "$clsKey\\DefaultIcon" /ve /d $icon /f]
    lappend cmds [list reg.exe add "$clsKey\\shell\\open\\command" /ve /d $openCmd /f]
    # the application itself: friendly name + launcher (-> Open with, any file)
    lappend cmds [list reg.exe add $appKey /v FriendlyAppName /t REG_SZ /d els /f]
    lappend cmds [list reg.exe add "$appKey\\shell\\open\\command" /ve /d $openCmd /f]
    # capabilities (-> a manageable "els" entry in Settings > Default apps)
    lappend cmds [list reg.exe add $capKey /v ApplicationName /t REG_SZ /d els /f]
    lappend cmds [list reg.exe add $capKey /v ApplicationDescription /t REG_SZ /d {A tiny text editor for Windows.} /f]
    lappend cmds [list reg.exe add $capKey /v ApplicationIcon /t REG_SZ /d $icon /f]
    lappend cmds [list reg.exe add {HKCU\Software\RegisteredApplications} /v els /t REG_SZ /d {Software\anafalanx\els\Capabilities} /f]
    # declare the curated text types: list els as an Open-with option for each
    # (OpenWithProgids -> the inline right-click "Open with" submenu), advertise
    # support (SupportedTypes), and list them under Default apps (Capabilities).
    # All three are options/declarations — NONE sets the type's default.
    foreach e [els::assoc_exts] {
        lappend cmds [list reg.exe add "HKCU\\Software\\Classes\\.$e\\OpenWithProgids" /v $progid /t REG_SZ /d "" /f]
        lappend cmds [list reg.exe add "$appKey\\SupportedTypes" /v ".$e" /t REG_SZ /d "" /f]
        lappend cmds [list reg.exe add "$capKey\\FileAssociations" /v ".$e" /t REG_SZ /d $progid /f]
    }
    return $cmds
}
# reg.exe commands that fully remove exactly what assoc_commands writes.  The
# shared HKCU\Software\anafalanx vendor root may contain other anafalanx products,
# so it is never deleted merely to tidy empty parents.  Per-user only.  Any
# default the USER set via Open with > Always is left alone — that's their choice,
# Windows protects it, and it is reset in Settings > Default apps, not by us.
proc els::assoc_unregister_commands {exe} {
    set appExe [file tail [file normalize $exe]]
    set progid els.txt
    set cmds {}
    foreach e [els::assoc_exts] {
        lappend cmds [list reg.exe delete "HKCU\\Software\\Classes\\.$e\\OpenWithProgids" /v $progid /f]
    }
    lappend cmds \
        [list reg.exe delete {HKCU\Software\RegisteredApplications} /v els /f] \
        [list reg.exe delete {HKCU\Software\anafalanx\els\Capabilities} /f] \
        [list reg.exe delete "HKCU\\Software\\Classes\\Applications\\$appExe" /f] \
        [list reg.exe delete {HKCU\Software\Classes\els.txt} /f]
    return $cmds
}
proc els::assoc_run {cmd} {
    set exe [els::system32 reg.exe]
    if {$exe eq ""} return   ;# fail safe rather than a bare-name exec (CWD planting)
    exec {*}[lreplace $cmd 0 0 $exe]
}
# Read a single registry value ("" = the key's default).  Returns "" if absent.
# The value name is matched to its column (not as a substring), and reg.exe's
# "(value not set)" sentinel for an empty default is normalized to "".
proc els::reg_value {key {val ""}} {
    set exe [els::system32 reg.exe]
    if {$exe eq ""} { return "" }   ;# fail safe rather than a bare-name exec (CWD planting)
    if {$val eq ""} { set q [list $exe query $key /ve] } else { set q [list $exe query $key /v $val] }
    if {[catch {exec {*}$q} out]} { return "" }
    return [els::reg_parse $out]
}
# Parse `reg.exe query` output POSITIONALLY, never by the name column: reg.exe
# localizes the default-value name ("(Default)" / "(Standard)" / "(Par défaut)"
# — the last even contains a space) and the unset sentinel, so name matching
# made registration state read as "not registered" on non-English Windows.
# Both query forms print exactly the one requested value as the first
# "<name> REG_TYPE <data>" line; the name is matched non-greedily so localized
# names with spaces survive.
proc els::reg_parse {out} {
    foreach ln [split $out \n] {
        if {[regexp -- {^\s+(.+?)\s+REG_\w+\s+(.*)$} $ln -> nm data]} {
            set data [string trimright $data]
            if {$data eq "(value not set)"} { return "" }   ;# English sentinel
            return $data
        }
    }
    return ""
}
# Is els currently registered with Windows as an app (its Applications launcher
# present)?  Drives the dialog's state line and which buttons appear.
proc els::assoc_registered {} {
    set exe [els::association_exe]
    if {$exe eq ""} { return 0 }
    set appExe [file tail [file normalize $exe]]
    set cmd [els::reg_value "HKCU\\Software\\Classes\\Applications\\$appExe\\shell\\open\\command" ""]
    # registered == the command points at THIS exe's FULL path (not merely a file
    # named els.exe): after els.exe moves, the stale registration still holds the
    # OLD absolute path, so it now reads as not-registered and the dialog offers a
    # Repair instead of falsely reporting healthy.  string first (literal), not
    # string match, so backslashes in the path aren't treated as glob escapes.
    set want [string tolower [file nativename $exe]]
    return [expr {$want ne "" && [string first $want [string tolower $cmd]] >= 0}]
}
proc els::open_default_apps {} {
    set cmd [els::system32 cmd.exe]   ;# absolute path: never a planted cmd.exe (CWD planting)
    if {$cmd ne "" && ![catch {exec $cmd /c start "" ms-settings:defaultapps &}]} { return }
    els::open_url ms-settings:defaultapps
}
# Register / unregister actions, driven by the dialog buttons.  Both re-render the
# dialog so its status line and buttons reflect the new reality.
proc els::assoc_register {} {
    set exe [els::association_exe]
    if {$exe eq "" || ![file exists $exe]} {
        els::message_box -parent .assoc -icon warning -title els \
            -message "els can only register itself from the built els.exe.\nBuild it (z build) and run that, then try again."
        return
    }
    set errs {}
    foreach cmd [els::assoc_commands $exe] {
        if {[catch {els::assoc_run $cmd} e]} { lappend errs $e }
    }
    if {[llength $errs]} {
        els::message_box -parent .assoc -icon error -title els \
            -message "Registration didn't fully complete:\n[join [lsort -unique $errs] \n]"
    }
    catch {els::assoc_render}
}
proc els::assoc_unregister {} {
    set exe [els::association_exe]
    if {$exe eq ""} { set exe els.exe }   ;# canonical app-key name, never the host interpreter
    set errs {}
    foreach cmd [els::assoc_unregister_commands $exe] {
        if {[catch {els::assoc_run $cmd} err]} { lappend errs $err }
    }
    if {[llength $errs]} {
        set parent [expr {[winfo exists .assoc] ? ".assoc" : "."}]
        els::message_box -parent $parent -icon error -title els \
            -message "Removal didn't fully complete:\n[join [lsort -unique $errs] \n]"
    }
    catch {els::assoc_render}
    return [expr {![llength $errs]}]
}
# (Re)build the dialog body to reflect the current registration state.
proc els::assoc_render {} {
    set bg $::els::PAGE
    catch {destroy .assoc.f}
    frame .assoc.f -bg $bg
    pack  .assoc.f -padx 28 -pady 24
    set reg [els::assoc_registered]
    label .assoc.f.title -text "File Associations" -font elsUIb -fg $::els::INK -bg $bg
    grid  .assoc.f.title -row 0 -column 0 -sticky w -pady {0 10}
    set blurb "els registers with Windows as an app that can open files. To point a\nfile type at els, right-click it in Explorer, choose Open with, pick\nels, and turn on Always. Defaults are managed and reset anytime in\nWindows Settings > Default apps."
    label .assoc.f.blurb -text $blurb -font elsUI -fg $::els::MUTED -bg $bg -justify left -anchor w
    grid  .assoc.f.blurb -row 1 -column 0 -sticky w -pady {0 16}
    set statusTxt [expr {$reg ? "els is registered with Windows." : "els is not registered with Windows yet."}]
    set statusFg  [expr {$reg ? $::els::INK : $::els::MUTED}]
    label .assoc.f.status -text $statusTxt -font elsUIb -fg $statusFg -bg $bg -anchor w
    grid  .assoc.f.status -row 2 -column 0 -sticky w -pady {0 6}
    label .assoc.f.types -text "Text types els advertises: [join [lmap e [els::assoc_exts] {string cat . $e}] {  }]" \
        -font elsUI -fg $::els::MUTED -bg $bg -justify left -anchor w -wraplength 470
    grid  .assoc.f.types -row 3 -column 0 -sticky w -pady {0 18}
    frame .assoc.f.b -bg $bg
    grid  .assoc.f.b -row 4 -column 0 -sticky ew
    ttk::button .assoc.f.b.def   -text "Open Default Apps" -style Dialog.TButton -command els::open_default_apps
    ttk::button .assoc.f.b.close -text Close -style Dialog.TButton -command {destroy .assoc}
    if {$reg} {
        ttk::button .assoc.f.b.un -text "Remove els" -style Dialog.TButton -command els::assoc_unregister
        pack .assoc.f.b.close -side right -padx {6 0}
        pack .assoc.f.b.un    -side right -padx {6 0}
        pack .assoc.f.b.def   -side left
        set ::els::assoc_default .assoc.f.b.close
    } else {
        ttk::button .assoc.f.b.reg -text "Register els with Windows" \
            -style Dialog.TButton -default active -command els::assoc_register
        pack .assoc.f.b.close -side right -padx {6 0}
        pack .assoc.f.b.reg   -side left
        set ::els::assoc_default .assoc.f.b.reg
    }
    if {$reg} { .assoc.f.b.close configure -default active }
    # Enter activates the -default active button (Tk 9's TButton ignores Return);
    # no entry/list in this dialog, so a toplevel binding is unambiguous (R21).
    bind .assoc <Return>   {catch {$::els::assoc_default invoke}}
    bind .assoc <KP_Enter> {catch {$::els::assoc_default invoke}}
    grid columnconfigure .assoc.f 0 -weight 1
    update idletasks
    after idle {if {[info exists ::els::assoc_default] && [winfo exists $::els::assoc_default]} {
        focus $::els::assoc_default
    }}
}
proc els::file_associations {} {
    if {$::tcl_platform(platform) ne "windows"} {
        els::message_box -parent . -icon info -title els \
            -message "File associations are only available on Windows."
        return
    }
    catch {destroy .assoc}
    toplevel .assoc -bg $::els::PAGE
    wm withdraw .assoc
    wm title .assoc "File Associations"
    wm transient .assoc .
    wm resizable .assoc 0 0
    bind .assoc <Escape> {destroy .assoc}
    els::assoc_render
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .assoc]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .assoc]) / 4}]
    wm geometry .assoc +$x+$y
    wm deiconify .assoc
    if {[info exists ::els::assoc_default] && [winfo exists $::els::assoc_default]} {
        focus $::els::assoc_default
    }
}

# ---- flat chrome styling ------------------------------------------------
# The native 'vista' ttk theme can't be recoloured or flattened, so we base
# the chrome on 'clam' (full colour control) and build flat, borderless styles.
# Separation is by tone, not borders; one 4px spacing quantum throughout.
proc els::init_style {} {
    set s ttk::style
    catch {$s theme use clam}
    set bg $::els::CHROME ; set ink $::els::INK ; set hair $::els::HAIR
    set focusBorder "#A6ACB4"
    set selectedBg "#C6C6C6"
    set scrollBg "#BCBCBC"
    set scrollActive "#A4A4A4"
    set scrollInk "#4A4A4A"
    set scrollBorder "#9A9A9A"
    $s configure . -background $bg -foreground $ink -font elsUI \
        -borderwidth 0 -focuscolor $focusBorder -troughcolor $::els::PAGE \
        -bordercolor $hair -darkcolor $bg -lightcolor $bg
    $s configure TFrame -background $bg
    $s configure TLabel -background $bg -foreground $ink
    # entries: flat, page-coloured field, hairline border (focus = a slightly
    # firmer grey, not red — red is reserved for the document caret)
    $s configure TEntry -relief flat -borderwidth 1 -padding {6 4} \
        -fieldbackground $::els::PAGE -foreground $ink -insertcolor $ink \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map TEntry -bordercolor [list focus $focusBorder] \
        -lightcolor [list focus $focusBorder] -darkcolor [list focus $focusBorder]
    # buttons: flat, quiet until hovered
    $s configure TButton -background $bg -foreground $ink -anchor center \
        -borderwidth 0 -relief flat -padding {8 4} -focuscolor $focusBorder
    $s map TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list disabled $::els::MUTED]
    # find toggles (Aa / W / .*): a flat chip that fills grey when active
    $s configure Toolbutton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center -focuscolor $focusBorder
    $s map Toolbutton -background [list selected $selectedBg active $::els::TABBG] \
        -foreground [list selected $ink active $ink disabled $::els::MUTED]
    # find/replace controls stay regular-weight; outlines carry affordance.
    $s configure Find.Toolbutton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center -font elsUI \
        -focuscolor $focusBorder
    $s map Find.Toolbutton -background [list selected $selectedBg active $::els::TABBG] \
        -foreground [list selected $ink active $ink disabled $::els::MUTED]
    $s configure Find.TButton -background $bg -foreground $::els::MUTED \
        -borderwidth 0 -relief flat -padding {8 4} -anchor center -font elsUI \
        -focuscolor $focusBorder
    $s map Find.TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list active $ink disabled $::els::MUTED]
    $s configure FindAction.TButton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 4} -anchor center -font elsUI \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair -focuscolor $focusBorder
    $s map FindAction.TButton -background [list pressed $hair active $::els::TABBG]
    $s configure FindAction.Toolbutton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 4} -anchor center -font elsUI \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair -focuscolor $focusBorder
    $s map FindAction.Toolbutton -background [list selected $selectedBg active $::els::TABBG] \
        -foreground [list selected $ink active $ink disabled $::els::MUTED]
    # Dialog buttons should read as buttons even before hover, unlike the main
    # chrome where flatness matters more than affordance.
    $s configure Dialog.TButton -background $bg -foreground $ink \
        -borderwidth 1 -relief solid -padding {10 5} -anchor center \
        -bordercolor $hair -lightcolor $hair -darkcolor $hair -focuscolor $focusBorder
    $s map Dialog.TButton -background [list pressed $hair active $::els::TABBG] \
        -foreground [list disabled $::els::MUTED]
    $s configure Treeview -background $::els::PAGE -fieldbackground $::els::PAGE \
        -foreground $ink -bordercolor $hair -lightcolor $hair -darkcolor $hair
    $s map Treeview -background [list selected $::els::SEL] \
        -foreground [list selected $::els::INK disabled $::els::MUTED]
    $s configure Treeview.Heading -background $bg -foreground $ink
    # A traditional vertical scrollbar: clam's DEFAULT layout (so the up/down
    # arrow buttons are always drawn — unlike a thumb-only layout, and unlike the
    # classic Tk widget which on Windows only paints its arrows once activated).
    # -arrowsize sets both the arrow size and the bar's width.  Give it in POINTS
    # (as clam's own default 10.5p does) so ttk scales it per-DPI automatically —
    # a bare pixel value is NOT scaled by tk scaling.  12p is a chunky, easy-to-
    # grab bar at any DPI.
    $s configure Vertical.TScrollbar -troughcolor $::els::PAGE \
        -background $scrollBg -arrowcolor $scrollInk -bordercolor $scrollBorder \
        -relief raised -borderwidth 1 -arrowsize 12p
    $s map Vertical.TScrollbar -background [list active $scrollActive disabled $::els::PAGE]
    # the horizontal scrollbar matches the vertical one exactly (same clam default
    # layout, chunky 12p arrows, colors) so the two read as one family
    $s configure Horizontal.TScrollbar -troughcolor $::els::PAGE \
        -background $scrollBg -arrowcolor $scrollInk -bordercolor $scrollBorder \
        -relief raised -borderwidth 1 -arrowsize 12p
    $s map Horizontal.TScrollbar -background [list active $scrollActive disabled $::els::PAGE]
}

# ---- build the UI -------------------------------------------------------
proc els::build {} {
    wm title . "els $::els::version"
    wm geometry . 900x620
    els::init_style
    . configure -background $::els::PAGE
    els::load_icon
    if {$::els::config_path eq ""} { els::config_resolve_existing }
    after idle els::find_prune_stale
    catch {els::load_geometry}   ;# backstop: NO config content may abort build
    els::deferred_load
    wm minsize . 360 240
    wm protocol . WM_DELETE_WINDOW els::quit

    menu .menu
    . configure -menu .menu
    menu .menu.file
    .menu add cascade -label File -underline 0 -menu .menu.file
    .menu.file add command -label "New Tab"   -accelerator Ctrl+N -command els::new
    .menu.file add command -label Open...      -accelerator Ctrl+O -command els::open
    menu .menu.file.recent
    .menu.file add cascade -label "Open Recent" -menu .menu.file.recent
    els::recent_rebuild
    .menu.file add command -label "Deferred Opens..." -command els::deferred_dialog
    .menu.file add command -label "Reload from Disk" -command els::reload
    .menu.file add checkbutton -label "Restore Previous Session" \
        -variable ::els::restore_session -command els::session_set_restore
    .menu.file add separator
    .menu.file add command -label Save         -accelerator Ctrl+S -command els::save
    .menu.file add command -label "Save As..." -accelerator Ctrl+Shift+S -command els::saveas
    .menu.file add cascade -label "Encoding" -underline 0 \
        -menu [els::build_enc_picker .menu.file.encoding]
    .menu.file add cascade -label "Line Endings" -underline 0 \
        -menu [els::eol_menu .menu.file.eol]
    .menu.file add checkbutton -label "Auto-save" -variable ::els::autosave \
        -command els::set_autosave
    .menu.file add checkbutton -label "Keep Backups" -variable ::els::backups \
        -command els::set_backups
    .menu.file add command -label "Open Backups Folder" -command els::backups_open
    .menu.file add separator
    .menu.file add command -label "Close File" -accelerator Ctrl+W -command els::close_tab
    .menu.file add command -label Exit         -accelerator Ctrl+Q -command els::quit
    menu .menu.edit
    .menu add cascade -label Edit -underline 0 -menu .menu.edit
    .menu.edit add command -label Undo  -accelerator Ctrl+Z -command els::menu_undo
    .menu.edit add command -label Redo  -accelerator Ctrl+Y -command els::menu_redo
    .menu.edit add separator
    .menu.edit add command -label Cut   -accelerator Ctrl+X -command {els::menu_event <<Cut>>}
    .menu.edit add command -label Copy  -accelerator Ctrl+C -command {els::menu_event <<Copy>>}
    .menu.edit add command -label Paste -accelerator Ctrl+V -command {els::menu_event <<Paste>>}
    .menu.edit add command -label "Select All" -accelerator Ctrl+A -command {els::menu_event <<SelectAll>>}
    .menu.edit add separator
    .menu.edit add command -label "Find..."       -accelerator Ctrl+F -command {els::find_show find}
    .menu.edit add command -label "Replace..."    -accelerator Ctrl+H -command {els::find_show replace}
    .menu.edit add command -label "Go to Line..." -accelerator Ctrl+G -command els::goto_line

    # Buffer: the text-manipulation commands, lifted out of Edit to keep it uncluttered.
    # Line ops act on the selected lines (or the current line); sort/reverse/dedupe act on
    # the selection, else the whole buffer.
    menu .menu.buffer
    .menu add cascade -label Buffer -underline 0 -menu .menu.buffer
    .menu.buffer add command -label "Move Line Up"    -accelerator Alt+Up       -command {els::xform::move -1}
    .menu.buffer add command -label "Move Line Down"  -accelerator Alt+Down     -command {els::xform::move 1}
    .menu.buffer add command -label "Duplicate Line"  -accelerator Ctrl+D       -command els::xform::duplicate
    .menu.buffer add command -label "Delete Line"     -accelerator Ctrl+Shift+K -command els::xform::delete_line
    .menu.buffer add command -label "Join Lines"      -accelerator Ctrl+J       -command els::xform::join_lines
    .menu.buffer add command -label "Indent"                                    -command els::xform::indent
    .menu.buffer add command -label "Dedent"          -accelerator Shift+Tab    -command els::xform::dedent
    .menu.buffer add separator
    .menu.buffer add command -label "Sort Lines"             -command {els::xform::sort 1}
    .menu.buffer add command -label "Sort Lines Descending"  -command {els::xform::sort -1}
    .menu.buffer add command -label "Reverse Lines"          -command els::xform::reverse
    .menu.buffer add command -label "Remove Duplicate Lines" -command els::xform::dedupe
    .menu.buffer add separator
    .menu.buffer add command -label "UPPERCASE"                -command {els::xform::case upper}
    .menu.buffer add command -label "lowercase"                -command {els::xform::case lower}
    .menu.buffer add command -label "Trim Trailing Whitespace" -command els::xform::trim_trailing
    menu .menu.tabs -postcommand els::tabs_menu_rebuild
    .menu add cascade -label Tabs -underline 0 -menu .menu.tabs
    menu .menu.view
    .menu add cascade -label View -underline 0 -menu .menu.view
    .menu.view add checkbutton -label "Word Wrap" -variable ::els::word_wrap \
        -command els::set_wrap
    .menu.view add checkbutton -label "Line Numbers" -variable ::els::show_linenos \
        -command els::set_linenos
    .menu.view add checkbutton -label "Show Whitespace" -variable ::els::show_ws \
        -command els::set_show_ws
    .menu.view add checkbutton -label "Focus Mode" -variable ::els::focus_mode \
        -command els::set_focus_mode
    .menu.view add checkbutton -label "Always on Top" -variable ::els::always_on_top \
        -command els::set_always_on_top
    .menu.view add separator
    .menu.view add command -label "Zoom In"    -accelerator Ctrl++ -command {els::zoom 1}
    .menu.view add command -label "Zoom Out"   -accelerator Ctrl+- -command {els::zoom -1}
    .menu.view add command -label "Reset Zoom" -accelerator Ctrl+0 -command els::zoom_reset
    menu .menu.help
    .menu add cascade -label Help -underline 0 -menu .menu.help
    .menu.help add command -label "Keyboard Shortcuts" -command els::shortcuts
    .menu.help add command -label "File Associations..." -command els::file_associations
    .menu.help add command -label "els on GitHub" \
        -command {els::open_url "https://github.com/anafalanx/els"}
    .menu.help add separator
    .menu.help add command -label "About els" -command els::about

    # the tab strip
    frame .tabs -bg $::els::TABBG
    label .tabs.more -text "▾" -width 3 -padx 0 -pady 3 -anchor center \
        -font elsUI -bg $::els::TABBG -fg $::els::MUTED -cursor hand2 \
        -takefocus 1 -highlightthickness 1 -highlightbackground $::els::TABBG \
        -highlightcolor $::els::CARET
    pack .tabs.more -side right -fill y
    bind .tabs.more <Button-1> els::tabs_popup
    bind .tabs.more <KeyPress-Return> {els::tabs_popup; break}
    bind .tabs.more <KeyPress-KP_Enter> {els::tabs_popup; break}
    bind .tabs.more <KeyPress-space> {els::tabs_popup; break}
    bind .tabs <Configure> {els::tabs_schedule}
    els::tooltip .tabs.more "All open documents"

    # the shared line-number gutter — a Canvas that draws only the numbers for
    # the display rows currently on screen (see els::draw_gutter), so it is
    # O(visible rows) regardless of file size and aligns with wrapped lines for
    # free via the text widget's own dlineinfo.  quiet ink, defers to the page
    canvas .ln -bg $::els::GUTTER -borderwidth 0 -highlightthickness 0 \
        -width 40 -takefocus 0 -cursor arrow
    set ::els::gutter_px -1   ;# fresh canvas: force the next width configure

    # the shared scrollbars (traditional: arrow buttons + a wide grabbable thumb;
    # styled in init_style).  The horizontal one is gridded only when word wrap is
    # off and a line runs past the window edge (see els::update_hscroll).
    ttk::scrollbar .vs -orient vertical   -command els::scroll  -takefocus 0
    ttk::scrollbar .hs -orient horizontal -command els::hscroll -takefocus 0

    # the find / replace bar (hidden until Ctrl+F / Ctrl+H)
    els::build_findbar

    # the shared status bar — one thin, quiet line under a hairline
    ttk::frame .sb
    frame .sb.hair -height 1 -bg $::els::HAIR
    # -width 8 FIXES the requested width: the text must never drive layout.
    # With a text-following request, a long path in a narrow window inflates
    # the request, pack squeezes the right cluster, the shrunken allocation
    # re-elides the text shorter, the request shrinks, pack gives the space
    # back... a visible flicker loop.  Actual width comes from -fill x/-expand.
    ttk::label .sb.name -font elsUI -anchor w -text "untitled" -width 8 \
        -foreground $::els::MUTED
    ttk::label .sb.pos  -font elsUI -anchor e -text "Ln 1 Col 1" -foreground $::els::MUTED
    # -anchor w (not e): when a narrow window squeezes this slot the label clips
    # from the far edge, so west-anchoring keeps the DISTINGUISHING leading word
    # ("Changed"/"Not"/"On") visible instead of the shared "...on disk" tail, which
    # would read like the healthy state even when the file changed on disk (R19).
    ttk::label .sb.disk -font elsUI -anchor w -width 15 -text "Not on disk" \
        -foreground $::els::MUTED
    ttk::label .sb.eol  -font elsUI -anchor e -text "LF"    -foreground $::els::MUTED \
        -cursor hand2 -padding {4 1}
    ttk::label .sb.enc  -font elsUI -anchor e -text "UTF-8" -foreground $::els::MUTED \
        -cursor hand2 -padding {4 1}
    frame .sb.sep_eol -width 1 -bg $::els::HAIR
    frame .sb.sep_enc -width 1 -bg $::els::HAIR
    frame .sb.sep_disk -width 1 -bg $::els::HAIR
    # a normally-empty notice; lights up red when a newer release is detected
    ttk::label .sb.update -font elsUI -anchor e -text "" -foreground $::els::CARET -cursor hand2
    pack .sb.hair -side top -fill x
    # name on the left (takes the slack, elided keeping the filename); the
    # position / EOL / encoding cluster on the right, reading Ln·Col | EOL | enc
    pack .sb.name -side left  -padx {12 8}  -pady 4 -fill x -expand 1
    pack .sb.enc     -side right -padx {8 12}  -pady 4
    pack .sb.sep_enc -side right -padx {2 2}   -pady {7 6} -fill y
    pack .sb.eol     -side right -padx {8 2}   -pady 4
    pack .sb.sep_eol -side right -padx {8 2}   -pady {7 6} -fill y
    pack .sb.pos  -side right -padx {12 0}  -pady 4
    pack .sb.sep_disk -side right -padx {8 2} -pady {7 6} -fill y
    pack .sb.disk -side right -padx {8 2} -pady 4
    pack .sb.update -side right -padx {12 0} -pady 4
    # the EOL and encoding indicators are clickable pickers
    bind .sb.eol  <Button-1>  els::popup_eol_menu
    bind .sb.enc  <Button-1>  els::popup_enc_menu
    bind .sb.eol  <Enter>     {els::status_link_enter .sb.eol}
    bind .sb.enc  <Enter>     {els::status_link_enter .sb.enc}
    bind .sb.eol  <Leave>     {els::status_link_leave .sb.eol}
    bind .sb.enc  <Leave>     {els::status_link_leave .sb.enc}
    bind .sb.name <Configure> {els::update_namelabel}
    bind .sb.update <Button-1> {els::tip_cancel ; els::open_url "https://github.com/anafalanx/els/releases/latest"}
    # hover affordance like the other status-bar links, but keeping the red
    # accent (status_link_leave would reset it to MUTED)
    bind .sb.update <Enter> {.sb.update configure -background $::els::TABBG}
    bind .sb.update <Leave> {.sb.update configure -background $::els::CHROME}
    els::tooltip_for .sb.name els::name_tip
    els::tooltip_for .sb.disk els::disk_tip

    # rows: 0 tabs · 1 find bar (shown on demand) · 2 text+gutter+vscroll ·
    # 3 hscroll (shown on demand) · 4 status.  The gutter spans rows 2-3 so its
    # quiet ground continues down beside the horizontal bar (no seam under the
    # line numbers); the bottom-right cell stays an empty page-grey corner.
    grid .tabs -row 0 -column 0 -columnspan 3 -sticky ew
    grid .ln   -row 2 -column 0 -rowspan 2 -sticky ns
    # honour a persisted Line Numbers = off: load_geometry ran at the TOP of
    # build, before .ln existed, so its set_linenos call could not apply — and
    # the unconditional grid above would leave an EMPTY gutter band showing
    if {!$::els::show_linenos} { grid remove .ln }
    # The disk observer polls only while the application is foreground-active.
    # Deactivation also retains the existing auto-save-on-focus-loss behavior.
    bind . <Activate> {if {"%W" eq "."} { els::disk_watch_activate }}
    bind . <Deactivate> {if {"%W" eq "."} { els::disk_watch_deactivate ; els::autosave_all }}
    # remember the last NORMAL-state geometry: while maximized, `wm geometry .`
    # returns the maximized rect, so save_geometry would otherwise persist that as
    # a normal window.  Guard %W eq "." — `.` is in every child's bindtags, so an
    # unguarded binding would also fire for child-widget <Configure> events.
    bind . <Configure> {if {"%W" eq "."} { els::track_geometry }}
    grid .vs   -row 2 -column 2 -sticky ns
    grid .hs   -row 3 -column 1 -sticky ew
    grid .sb   -row 4 -column 0 -columnspan 3 -sticky ew
    grid rowconfigure    . 2 -weight 1
    grid columnconfigure . 1 -weight 1

    # class bindings shared by every document Text widget.  The elsText tag
    # runs BEFORE the default Text tag, so accelerators here pre-empt Tk's
    # emacs-style defaults (Ctrl+N = down-line, Ctrl+O = open-line, ...).
    bind elsText <<Modified>>    {els::on_modified %W}
    bind elsText <KeyRelease>    {els::refresh_view}
    bind elsText <ButtonRelease> {els::refresh_view}
    bind elsText <FocusIn>       {els::refresh_view}
    bind elsText <<Paste>>       {els::refresh_schedule}
    bind elsText <<Cut>>         {els::refresh_schedule}
    # coalesced: an interactive resize delivers a continuous Configure stream,
    # and a bare `after idle` per event ran N full repaints per idle batch
    bind elsText <Configure>     {els::refresh_schedule}
    bind elsText <Control-n> { els::new;       break }
    bind elsText <Control-o> { els::open;      break }
    bind elsText <Control-s> { els::save;      break }
    bind elsText <Control-Shift-S> { els::saveas; break }
    bind elsText <Control-w> { els::close_tab; break }
    bind elsText <Control-q> { els::quit;      break }
    bind elsText <Control-Tab>          { els::cycle 1;  break }
    bind elsText <Control-Shift-Tab>    { els::cycle -1; break }
    bind elsText <Control-ISO_Left_Tab> { els::cycle -1; break }
    bind elsText <Control-f> { els::find_show find;    break }
    bind elsText <Control-h> { els::find_show replace; break }
    bind elsText <Control-g> { els::goto_line;         break }
    bind elsText <Control-z> { els::menu_undo;         break }
    bind elsText <Control-y> { els::menu_redo;         break }
    bind elsText <Control-plus>       { els::zoom 1;     break }
    bind elsText <Control-equal>      { els::zoom 1;     break }
    bind elsText <Control-minus>      { els::zoom -1;    break }
    bind elsText <Control-Key-0>      { els::zoom_reset; break }
    bind elsText <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    bind elsText <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
    bind elsText <Shift-MouseWheel>   { els::hwheel %D; break }
    bind elsText <Key-F3>             { els::find_step 1;  break }
    bind elsText <Shift-Key-F3>       { els::find_step -1; break }
    # right-click context menu (Windows convention).  Text has no default
    # Button-3 action, so the caret is deliberately left where it is.
    bind elsText <Button-3>           { els::popup_text_menu %W %X %Y; break }
    # neutralize Tk's emacs-style Text defaults that surprise on a Windows editor
    # (Ctrl+K kill-to-end, Ctrl+T transpose); break pre-empts the default binding
    bind elsText <Control-k> break
    bind elsText <Control-t> break

    # text-transform shortcuts (the Buffer-menu commands).  Ctrl+D used to be a
    # neutralized Text default (delete-next-char); it is now Duplicate Line.
    bind elsText <Control-d>        { els::xform::duplicate;   break }
    bind elsText <Control-j>        { els::xform::join_lines;  break }
    bind elsText <Control-Shift-K>  { els::xform::delete_line; break }
    bind elsText <Alt-Up>           { els::xform::move -1; break }
    bind elsText <Alt-Down>         { els::xform::move  1; break }
    # Tab indents whenever there is a selection (else a literal tab) and MUST break so
    # it never reaches Tk's default Text <Tab>, which would replace the selection with a
    # tab; Shift+Tab always dedents.
    bind elsText <Key-Tab>          { if {[els::xform::tab_indents %W]} { els::xform::indent; break } }
    bind elsText <Shift-Key-Tab>    { els::xform::dedent; break }
    bind elsText <Key-ISO_Left_Tab> { els::xform::dedent; break }

    # the same accelerators on the toplevel, for when focus is off the text
    bind . <Control-n> { els::new;       break }
    bind . <Control-o> { els::open;      break }
    bind . <Control-s> { els::save;      break }
    bind . <Control-Shift-S> { els::saveas; break }
    bind . <Control-w> { els::close_tab; break }
    bind . <Control-q> { els::quit;      break }
    bind . <Control-Tab>          { els::cycle 1;  break }
    bind . <Control-Shift-Tab>    { els::cycle -1; break }
    bind . <Control-ISO_Left_Tab> { els::cycle -1; break }
    bind . <Control-f> { els::find_show find;    break }
    bind . <Control-h> { els::find_show replace; break }
    bind . <Control-g> { els::goto_line;         break }
    bind . <Control-d>       { els::xform::duplicate;   break }
    bind . <Control-j>       { els::xform::join_lines;  break }
    bind . <Control-Shift-K> { els::xform::delete_line; break }
    bind . <Alt-Up>          { els::xform::move -1; break }
    bind . <Alt-Down>        { els::xform::move  1; break }
    bind . <Control-plus>       { els::zoom 1;     break }
    bind . <Control-equal>      { els::zoom 1;     break }
    bind . <Control-minus>      { els::zoom -1;    break }
    bind . <Control-Key-0>      { els::zoom_reset; break }
    bind . <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    bind . <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
    bind . <Key-F3>             { els::find_step 1;  break }
    bind . <Shift-Key-F3>       { els::find_step -1; break }

    bind .ln <Button-1>   { focus [els::T]; break }
    bind .ln <MouseWheel> { els::wheel %D; break }
    bind .ln <Shift-MouseWheel> { els::hwheel %D; break }
    bind .ln <Control-MouseWheel> { els::zoom [expr {%D > 0 ? 1 : -1}]; break }
    # precision touchpads arrive as <TouchpadScroll>, not <MouseWheel>: the Text
    # class handles it, a bare canvas does not — without these the gutter was
    # dead to touchpad scrolling and Ctrl+touchpad scrolled instead of zooming
    bind .ln <TouchpadScroll>         { els::touchpad_scroll %D; break }
    bind .ln <Control-TouchpadScroll> { els::zoom_touchpad %D; break }
    bind .ln <Button-4>   { els::scroll scroll -3 units; break }
    bind .ln <Button-5>   { els::scroll scroll  3 units; break }

    # Explorer drop targets.  On Win32 each Tk widget is its own child HWND and
    # WM_DROPFILES is NOT forwarded to the parent, so a drop is accepted only over a
    # window we register explicitly: the toplevel's own background here, the
    # line-number gutter (the editing surface's left edge), and each document's text
    # widget (registered in new_doc).  The thin chrome strips — tab bar, status bar,
    # find bar — are deliberately NOT drop zones; the file lands on the text.
    els::drop_register .
    els::drop_register .ln

    # start with one empty document
    els::new_doc
    if {$::els::deferred_notice ne ""} {
        after idle [list els::status_note $::els::deferred_notice]
    }
}

# ---- documents ----------------------------------------------------------
# Every document Text command is proxied so a same-length edit is just as
# observable as an insertion/deletion.  Tk marks and tags float with edits, but
# worker snapshots and match offsets do not; docEpoch is the authoritative
# invalidation token captured by every asynchronous find operation.
proc els::text_proxy_install {id w} {
    set native "::els::text_native_$id"
    catch {rename $native {}}
    rename $w $native
    interp alias {} $w {} els::text_proxy $id $w $native
    bind $w <Destroy> +[list els::text_proxy_destroy $id $w $native]
}
proc els::text_proxy {id public native args} {
    set mutates 0
    set op [lindex $args 0]
    if {$op in {insert delete replace}} {
        set mutates 1
    } elseif {$op eq "edit" && [lindex $args 1] in {undo redo}} {
        set mutates 1
    }
    set rc [catch {{*}$native {*}$args} result opts]
    if {$rc} { return -options $opts $result }
    if {$mutates && [info exists ::els::docEpoch($id)]} {
        incr ::els::docEpoch($id)
        els::find_doc_mutated $id
    }
    return $result
}
proc els::text_proxy_destroy {id public native} {
    if {[info exists ::els::docEpoch($id)]} { els::find_doc_closed $id }
    catch {rename $public {}}
    catch {rename $native {}}
}

proc els::new_doc {{path ""}} {
    variable docs
    variable seq
    variable docPath
    set id "d$seq"
    incr seq
    set w [els::W $id]
    text $w -undo 1 -maxundo $::els::MAXUNDO -wrap [expr {$::els::word_wrap ? "word" : "none"}] -font elsMono \
        -bg $::els::PAGE -fg $::els::INK \
        -insertbackground $::els::CARET -insertwidth 4 -insertofftime 0 \
        -selectbackground $::els::SEL -selectforeground $::els::INK \
        -inactiveselectbackground $::els::SELOFF \
        -borderwidth 0 -highlightthickness 0 -padx 14 -pady 6 \
        -spacing1 $::els::LEAD -spacing3 $::els::LEAD \
        -tabstyle wordprocessor \
        -yscrollcommand [list els::yscroll $id] \
        -xscrollcommand [list els::xscroll $id]
    set ::els::docEpoch($id) 0
    els::text_proxy_install $id $w
    $w tag configure currentLine -background $::els::LINE
    $w tag configure wsSpace -background $::els::WSSPACE
    $w tag configure wsTab   -background $::els::WSTAB
    $w tag configure wsTrail -background $::els::WSTRAIL
    $w tag configure findAll -background $::els::FINDALL
    $w tag configure findOne -background $::els::FINDONE
    # Focus mode dims non-current lines with a foreground-only grey (reusing the
    # quiet line-number grey); background tags don't conflict, and it sits below sel
    # so selected text on a dimmed line stays legible.
    $w tag configure focusDim -foreground $::els::GUTTINK
    # stacking, low -> high: current-line wash < space/tab < trailing < matches <
    # focus-dim (fg) < selection (whitespace above the line wash so it shows on the
    # current line; trailing above space/tab so it wins on a trailing run)
    $w tag lower currentLine
    $w tag raise wsSpace
    $w tag raise wsTab
    $w tag raise wsTrail
    $w tag raise findAll
    $w tag raise findOne
    $w tag raise focusDim
    $w tag raise sel
    # let the shared class bindings fire (run before the default Text tag)
    bindtags $w [linsert [bindtags $w] 1 elsText]
    # the text area is the primary Explorer drop target (each widget is its own
    # child HWND, so drops over it don't reach the toplevel's drop registration)
    els::drop_register $w
    set docPath($id) $path
    set ::els::docEnc($id) utf-8
    set ::els::docBom($id) 0
    set ::els::docEol($id) [els::default_eol]   ;# platform-native for NEW docs
    set ::els::docRaw($id) ""
    lappend docs $id
    els::make_tab $id
    els::switch_to $id
    return $id
}
# EOL for documents born in els (files opened from disk keep their detected
# one): the platform convention — CRLF on Windows, LF elsewhere.
proc els::default_eol {} {
    if {$::tcl_platform(platform) eq "windows"} { return crlf }
    return lf
}
proc els::doc_dirty {id} {
    set w [els::W $id]
    if {![winfo exists $w]} { return 0 }
    return [$w edit modified]
}
proc els::doc_name {id} {
    variable docPath
    set p $docPath($id)
    # NOT an expr ternary: expr canonicalizes operands that look like numbers,
    # so a file named "007" displayed (and Save-As-prefilled!) as "7", and one
    # named "nan" THREW here — i.e. on every keystroke via update_tab.
    if {$p eq ""} { return "untitled" }
    return [file tail $p]
}
proc els::pristine {id} {
    # a fresh, untouched untitled document — safe to reuse on Open
    variable docPath
    if {$id eq ""} { return 0 }
    if {$docPath($id) ne ""} { return 0 }
    if {[els::doc_dirty $id]} { return 0 }
    return [expr {[[els::W $id] get 1.0 "end - 1 char"] eq ""}]
}
proc els::switch_to {id} {
    variable docs
    variable active
    if {[lsearch -exact $docs $id] < 0} { return }
    set wasActive [expr {$active eq $id}]
    if {$active ne "" && $active ne $id} { els::find_context_leave $active }
    if {$active ne "" && $active ne $id} { els::autosave_flush_doc $active }
    if {$active ne "" && [winfo exists [els::W $active]]} {
        # clear find highlights on the tab we are leaving so they don't linger as
        # orphaned tints on an inactive document (the search re-applies to the new
        # active doc below when the find bar is open)
        [els::W $active] tag remove findAll 1.0 end
        [els::W $active] tag remove findOne 1.0 end
        grid remove [els::W $active]
    }
    set active $id
    set w [els::W $id]
    grid $w -row 2 -column 1 -sticky nsew
    focus $w
    els::refresh_tabs
    els::settitle
    els::disk_probe $id [expr {$wasActive ? "refresh" : "forced"}]
    els::refresh_view
    if {$::els::find_mode ne ""} { els::find_update }
    after idle els::update_vscroll
    after idle els::update_hscroll
}
proc els::cycle {dir} {
    variable docs
    variable active
    set n [llength $docs]
    if {$n <= 1} { return }
    set i [lsearch -exact $docs $active]
    els::switch_to [lindex $docs [expr {($i + $dir + $n) % $n}]]
}
proc els::close_tab {} {
    variable active
    if {$active ne ""} { els::close_doc $active }
}
proc els::close_doc {id} {
    variable docs
    variable active
    variable docPath
    set idx [lsearch -exact $docs $id]
    if {$idx < 0} { return }
    els::autosave_flush_doc $id   ;# auto-save on: a pathed doc closes saved, no prompt
    if {[els::doc_dirty $id]} {
        set ans [els::message_box -parent . -icon warning -type yesnocancel \
            -title els -message "Save changes to [els::doc_name $id]?"]
        if {$ans eq "cancel"} { return }
        if {$ans eq "yes"} {
            els::switch_to $id
            els::save
            if {[els::doc_dirty $id]} { return }   ;# Save As was cancelled
        }
    }
    set idx [lsearch -exact $docs $id]
    set docs [lreplace $docs $idx $idx]
    destroy [els::W $id]
    destroy [els::tabW $id]
    unset -nocomplain ::els::docDecodeLossy($id) \
        ::els::docFormatPending($id)
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    unset -nocomplain docPath($id) ::els::docEnc($id) ::els::docBom($id) \
        ::els::docEol($id) ::els::docRaw($id) \
        ::els::savedSig($id) ::els::savedSigPath($id) \
        ::els::docDiskState($id) ::els::docDiskMeta($id) \
        ::els::docDiskContent($id) ::els::docDiskDetail($id) ::els::docDiskDeepAt($id) \
        ::els::docExtModPause($id) ::els::loading($id) \
        ::els::docEpoch($id)
    if {$active eq $id} { set active "" }
    if {[llength $docs] == 0} {
        els::new_doc
        return
    }
    if {$active eq ""} {
        set nidx [expr {$idx > [llength $docs] - 1 ? [llength $docs] - 1 : $idx}]
        els::switch_to [lindex $docs $nidx]
    } else {
        els::refresh_tabs
    }
}

# ---- tab strip ----------------------------------------------------------
proc els::tab_name_equal {a b} {
    if {$::tcl_platform(platform) eq "windows"} { return [string equal -nocase $a $b] }
    return [string equal $a $b]
}
# A forward-slash suffix is compact and stable even when the native path uses
# backslashes.  depth=1 means parent/basename, depth=2 grandparent/parent/name.
proc els::tab_path_suffix {id depth} {
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} { return "" }
    set parts [file split [els::strip_ext_prefix $::els::docPath($id)]]
    set first [expr {[llength $parts] - $depth - 1}]
    if {$first < 0} { set first 0 }
    return [join [lrange $parts $first end] /]
}
# Names in the strip are identities, not merely basenames: untitled documents
# are numbered, and duplicate basenames grow the shortest parent suffix that
# distinguishes them from every peer.
proc els::tab_identity {id} {
    if {![info exists ::els::docPath($id)]} { return "" }
    set p $::els::docPath($id)
    if {$p eq ""} {
        set n 0
        foreach other $::els::docs {
            if {[info exists ::els::docPath($other)] && $::els::docPath($other) eq ""} { incr n }
            if {$other eq $id} { return "untitled $n" }
        }
        return "untitled"
    }
    set base [file tail $p]
    set peers {}
    foreach other $::els::docs {
        if {![info exists ::els::docPath($other)] || $::els::docPath($other) eq ""} { continue }
        if {[els::tab_name_equal [file tail $::els::docPath($other)] $base]} { lappend peers $other }
    }
    if {[llength $peers] <= 1} { return $base }
    set parts [file split [els::strip_ext_prefix $p]]
    set maxDepth [expr {[llength $parts] - 1}]
    for {set depth 1} {$depth <= $maxDepth} {incr depth} {
        set candidate [els::tab_path_suffix $id $depth]
        set unique 1
        foreach other $peers {
            if {$other eq $id} { continue }
            if {[els::tab_name_equal $candidate [els::tab_path_suffix $other $depth]]} {
                set unique 0
                break
            }
        }
        if {$unique} { return $candidate }
    }
    # Identical normalized paths are normally rejected by open/save-as.  Keep a
    # deterministic last-resort identity for extensions/tests that create one.
    return "[els::tab_path_suffix $id $maxDepth] ([expr {[lsearch -exact $::els::docs $id] + 1}])"
}
proc els::tab_elide_identity {s max} {
    if {$max < 1} { return "" }
    if {[string length $s] <= $max} { return $s }
    if {$max == 1} { return "…" }
    # Middle elision preserves the parent discriminator at the beginning and the
    # filename/extension at the end, unlike head-only clipping.
    set keep [expr {$max - 1}]
    set left [expr {max(2, int(ceil($keep * 0.35)))}]
    if {$left >= $keep} { set left [expr {$keep - 1}] }
    set right [expr {$keep - $left}]
    return "[string range $s 0 [expr {$left - 1}]]…[string range $s end-[expr {$right - 1}] end]"
}
# Compact state marks leave room for the identity while remaining durable:
# a dirty bullet and a decoding-replacement warning.
proc els::tab_markers {id} {
    set marks ""
    if {[els::doc_dirty $id]} { append marks "•" }
    if {[info exists ::els::docDecodeLossy($id)]} { append marks "�" }
    if {$marks ne ""} { append marks " " }
    return $marks
}
proc els::tab_label_base {id max maxPixels suffix} {
    if {$max <= 0} { return "" }
    set marks [els::tab_markers $id]
    set reserved [expr {[string length $marks] + [string length $suffix]}]
    set room [expr {max(0, $max - $reserved)}]
    set identity [els::tab_identity $id]
    while {$room >= 0} {
        set label "$marks[els::tab_elide_identity $identity $room]$suffix"
        if {[string length $label] > $max} {
            set label [string range $label 0 [expr {$max - 1}]]
        }
        if {$maxPixels <= 0 || [font measure elsUI $label] <= $maxPixels} { return $label }
        incr room -1
    }
    # Actual UI caps are comfortably larger than the markers/suffix.  Keep a
    # defensive exact cap for unit callers using an artificially tiny limit.
    set label "$marks$suffix"
    set label [string range $label 0 [expr {$max - 1}]]
    while {$label ne "" && $maxPixels > 0 && [font measure elsUI $label] > $maxPixels} {
        set label [string range $label 0 end-1]
    }
    return $label
}
# Build the whole label set before selecting one: independent middle-elision can
# collapse distinct identities to the same visible string.  Colliding entries
# get a short document discriminator that is itself inside both caps.
proc els::tab_labels {max {maxPixels 0}} {
    set labels [dict create]
    foreach id $::els::docs {
        dict set labels $id [els::tab_label_base $id $max $maxPixels ""]
    }
    # A second pass covers the pathological case where a disambiguated label
    # itself equals another literal/elided name.  The document id is unique and
    # is preserved as the final suffix inside the cap.
    for {set pass 0} {$pass < 2} {incr pass} {
        set groups [dict create]
        foreach id $::els::docs {
            set key [dict get $labels $id]
            if {$::tcl_platform(platform) eq "windows"} { set key [string tolower $key] }
            dict lappend groups $key $id
        }
        set collided 0
        foreach key [dict keys $groups] {
            set ids [dict get $groups $key]
            if {[llength $ids] <= 1} { continue }
            set collided 1
            foreach id $ids {
                if {$pass == 0} {
                    set discriminator " ·[expr {[lsearch -exact $::els::docs $id] + 1}]"
                } else {
                    set discriminator " ·$id"
                }
                dict set labels $id [els::tab_label_base $id $max $maxPixels $discriminator]
            }
        }
        if {!$collided} { break }
    }
    return $labels
}
proc els::tab_label {id max {maxPixels 0}} {
    set labels [els::tab_labels $max $maxPixels]
    if {![dict exists $labels $id]} { return "" }
    return [dict get $labels $id]
}
proc els::tab_text {id} {
    return [els::tab_label $id $::els::TAB_LABEL_MAX $::els::TAB_LABEL_PX]
}
# Tooltip text for a tab: the document's full native path (empty for untitled).
proc els::tab_tip {id} {
    if {![info exists ::els::docPath($id)]} { return "" }
    set p $::els::docPath($id)
    if {$p eq ""} { return "" } else { set tip [els::path_tip $p] }
    if {[info exists ::els::docDecodeLossy($id)]} { append tip "\nContains decoding replacement characters" }
    return $tip
}
proc els::make_tab {id} {
    set tf [els::tabW $id]
    frame $tf -bg $::els::TABOFF
    label $tf.name -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text [els::tab_text $id] -padx 6 -pady 3 -anchor w
    label $tf.close -bg $::els::TABOFF -fg $::els::MUTED -font elsUI \
        -text "×" -width 2 -padx 0 -pady 3 -anchor center -cursor hand2
    pack $tf.name  -side left
    pack $tf.close -side right
    pack $tf -side left -padx {0 1} -pady {2 0} -fill y
    bind $tf       <Button-1> [list els::switch_to $id]
    bind $tf.name  <Button-1> [list els::switch_to $id]
    # drag a tab left/right to reorder it (crossing a neighbour's midpoint
    # swaps places; the docs list and the saved session follow the new order)
    bind $tf       <B1-Motion> [list els::tab_drag $id %X]
    bind $tf.name  <B1-Motion> [list els::tab_drag $id %X]
    bind $tf.close <Button-1> [list els::close_doc $id]
    bind $tf.close <Enter>    [list els::tab_close_enter $id]
    bind $tf.close <Leave>    [list els::tab_close_leave $id]
    bind $tf       <Button-3> [list els::popup_tab_menu $id %X %Y]
    bind $tf.name  <Button-3> [list els::popup_tab_menu $id %X %Y]
    els::tooltip_for $tf      [list els::tab_tip $id] $::els::tab_tip_delay
    els::tooltip_for $tf.name [list els::tab_tip $id] $::els::tab_tip_delay
    els::tabs_schedule
}
# Reorder by drag: when the pointer crosses a neighbouring tab's midpoint,
# move the dragged doc to that position and repack.  State-free (each motion
# event re-evaluates), so a plain click never reorders anything.
proc els::tab_drag {id rootX} {
    variable docs
    set idx [lsearch -exact $docs $id]
    if {$idx < 0} { return }
    foreach other $docs {
        if {$other eq $id} continue
        set tw [els::tabW $other]
        if {![winfo exists $tw] || [winfo manager $tw] ne "pack"} continue
        set mid  [expr {[winfo rootx $tw] + [winfo width $tw] / 2}]
        set oidx [lsearch -exact $docs $other]
        if {($oidx < $idx && $rootX < $mid) || ($oidx > $idx && $rootX > $mid)} {
            set docs [linsert [lreplace $docs $idx $idx] $oidx $id]
            els::tab_repack
            break
        }
    }
}
proc els::tab_repack {} {
    # A drag reorder changes position-dependent identities (untitled numbering and
    # same-basename discriminators), so relabel EVERY tab, not just the active one
    # -- tabs_layout alone would leave peers showing their pre-reorder names, e.g.
    # two tabs both reading "untitled 1" until the next switch/close/save (R17).
    els::refresh_tabs
}
proc els::tab_close_enter {id} {
    set w [els::tabW $id].close
    if {![winfo exists $w]} { return }
    set bg [expr {$id eq $::els::active ? $::els::TABON : $::els::TABOFF}]
    $w configure -bg $bg -fg $::els::INK
}
proc els::tab_close_leave {id} {
    variable active
    set bg [expr {$id eq $active ? $::els::TABON : $::els::TABOFF}]
    catch {[els::tabW $id].close configure -bg $bg -fg $::els::MUTED}
}
proc els::update_tab {id} {
    set tf [els::tabW $id]
    if {![winfo exists $tf]} { return }
    $tf.name configure -text [els::tab_text $id]
    els::tabs_schedule
}
proc els::refresh_tabs {} {
    variable docs
    variable active
    set labels [els::tab_labels $::els::TAB_LABEL_MAX $::els::TAB_LABEL_PX]
    foreach id $docs {
        set tf [els::tabW $id]
        if {![winfo exists $tf]} { continue }
        if {$id eq $active} {
            set bg $::els::TABON ; set fg $::els::INK
        } else {
            set bg $::els::TABOFF ; set fg $::els::MUTED
        }
        $tf       configure -bg $bg
        $tf.name  configure -bg $bg -fg $fg -text [dict get $labels $id]
        $tf.close configure -bg $bg -fg $::els::MUTED
    }
    set ::els::tabs_menu_choice $active
    els::tabs_layout
}
proc els::tabs_schedule {} {
    if {![winfo exists .tabs] || $::els::tabs_layout_after ne ""} { return }
    set ::els::tabs_layout_after [after idle {
        set ::els::tabs_layout_after ""
        els::tabs_layout
    }]
}
# Pack only a contiguous neighbourhood that contains the active document.  The
# right-side control always remains visible and exposes every hidden document.
proc els::tabs_layout {} {
    if {![winfo exists .tabs] || ![winfo exists .tabs.more]} { return }
    foreach id $::els::docs {
        set tf [els::tabW $id]
        if {[winfo exists $tf]} { pack forget $tf }
    }
    pack forget .tabs.more
    pack .tabs.more -side right -fill y
    if {![llength $::els::docs]} { return }
    set idx [lsearch -exact $::els::docs $::els::active]
    if {$idx < 0} { set idx 0 }
    set avail [expr {[winfo width .tabs] - [winfo reqwidth .tabs.more]}]
    if {$avail < 1} { set avail 1 }
    set left $idx
    set right $idx
    set activeW [els::tabW [lindex $::els::docs $idx]]
    # The active tab and its close button are non-negotiable at the minimum
    # window width.  Tighten its text by measured pixels before packing peers.
    set closeW [winfo reqwidth $activeW.close]
    set activeTextPx [expr {max(1, min($::els::TAB_LABEL_PX, $avail - $closeW - 18))}]
    $activeW.name configure -text [els::tab_label [lindex $::els::docs $idx] \
        $::els::TAB_LABEL_MAX $activeTextPx]
    # Measure from the two child labels, not the frame: a label's reqwidth updates
    # SYNCHRONOUSLY inside `configure`, but the enclosing frame's reqwidth is only
    # recomputed by the packer at idle -- so reading the frame here (right after the
    # label -text change) yields a STALE width and the strip packs one tab too many,
    # squeezing the rightmost close button off (R18).  The frame is borderless with
    # no inter-child padding, so name+close reqwidth equals its would-be reqwidth.
    set used [expr {[winfo reqwidth $activeW.name] + $closeW + 1}]
    set grew 1
    while {$grew} {
        set grew 0
        if {$right + 1 < [llength $::els::docs]} {
            set w [els::tabW [lindex $::els::docs [expr {$right + 1}]]]
            set need [expr {[winfo reqwidth $w.name] + [winfo reqwidth $w.close] + 1}]
            if {$used + $need <= $avail} {
                incr right
                incr used $need
                set grew 1
            }
        }
        if {$left > 0} {
            set w [els::tabW [lindex $::els::docs [expr {$left - 1}]]]
            set need [expr {[winfo reqwidth $w.name] + [winfo reqwidth $w.close] + 1}]
            if {$used + $need <= $avail} {
                incr left -1
                incr used $need
                set grew 1
            }
        }
    }
    for {set i $left} {$i <= $right} {incr i} {
        set tf [els::tabW [lindex $::els::docs $i]]
        pack $tf -side left -padx {0 1} -pady {2 0} -fill y
    }
}
proc els::tabs_menu_rebuild {} {
    set m .menu.tabs
    if {![winfo exists $m]} { return }
    $m delete 0 end
    set ::els::tabs_menu_choice $::els::active
    if {![llength $::els::docs]} {
        $m add command -label "(empty)" -state disabled
        return
    }
    set labels [els::tab_labels $::els::TAB_MENU_MAX $::els::TAB_MENU_PX]
    foreach id $::els::docs {
        $m add radiobutton -label [dict get $labels $id] \
            -variable ::els::tabs_menu_choice -value $id \
            -command [list els::switch_to $id]
    }
}
proc els::tabs_popup {} {
    if {![winfo exists .tabs.more]} { return }
    # Dismiss the button's own tooltip BEFORE posting the menu.  tk_popup below
    # enters a native modal loop that does not return until the menu closes, and
    # the .tip toplevel is override-redirect + -topmost, so a still-visible tip
    # would float over the posted menu the whole time.  Doing it here (not only in
    # the click binding) also covers the keyboard activation paths (R20).
    els::tip_cancel
    els::tabs_menu_rebuild
    update idletasks
    set m .menu.tabs
    set x [expr {[winfo rootx .tabs.more] + [winfo width .tabs.more] - [winfo reqwidth $m]}]
    if {$x < [winfo rootx .]} { set x [winfo rootx .] }
    set y [expr {[winfo rooty .tabs.more] + [winfo height .tabs.more]}]
    tk_popup $m $x $y
}

# ---- active document: on-disk state ------------------------------------
# This observer is deliberately separate from the authoritative save guard.
# Polling may update one quiet status label; it never reloads, writes, pauses
# auto-save, or asks a question.  Save still performs its own fresh signature
# probe and owns every overwrite/reload decision.
proc els::disk_stat_probe {path} {
    if {[catch {file stat $path st} err opts]} {
        set code {}
        if {[dict exists $opts -errorcode]} { set code [dict get $opts -errorcode] }
        set posix [lindex $code 1]
        set state [expr {$posix in {ENOENT ENOTDIR} ? "missing" : "unavailable"}]
        return [dict create state $state error $err]
    }
    if {![info exists st(type)] || $st(type) ne "file"} {
        return [dict create state unavailable error "path is not a regular file"]
    }
    if {[catch {file readable $path} readable] || !$readable} {
        return [dict create state unavailable error "file is not readable"]
    }
    # Read-only means we have affirmative evidence: the Windows attribute is
    # set, or Tcl reports that the current process cannot write the file.  A
    # failed attribute query alone never invents a warning.
    set readonly 0
    if {![catch {file attributes $path -readonly} ro] && \
            [string is boolean -strict $ro] && $ro} {
        set readonly 1
    } elseif {![catch {file writable $path} writable] && !$writable} {
        set readonly 1
    }
    return [dict create state ok size $st(size) mtime $st(mtime) readonly $readonly]
}
proc els::disk_probe_reset {id} {
    unset -nocomplain ::els::docDiskState($id) ::els::docDiskMeta($id) \
        ::els::docDiskContent($id) ::els::docDiskDetail($id) ::els::docDiskDeepAt($id)
}
proc els::disk_state_set {id state {detail ""}} {
    set ::els::docDiskState($id) $state
    set ::els::docDiskDetail($id) $detail
    if {$id eq $::els::active} { els::disk_render }
    return $state
}
proc els::disk_render {} {
    if {![winfo exists .sb.disk]} { return }
    set state untitled
    if {$::els::active ne "" && [info exists ::els::docDiskState($::els::active)]} {
        set state $::els::docDiskState($::els::active)
    }
    switch $state {
        normal      { set label "On disk" }
        changed     { set label "Changed on disk" }
        missing     { set label "Missing" }
        unavailable { set label "Unavailable" }
        readonly    { set label "Read-only" }
        default     { set label "Not on disk" ; set state untitled }
    }
    set fg [expr {$state in {changed missing unavailable readonly} ? $::els::CARET : $::els::MUTED}]
    .sb.disk configure -text $label -foreground $fg
}
proc els::disk_tip {} {
    set state untitled
    set detail ""
    if {$::els::active ne "" && [info exists ::els::docDiskState($::els::active)]} {
        set state $::els::docDiskState($::els::active)
        if {[info exists ::els::docDiskDetail($::els::active)]} {
            set detail $::els::docDiskDetail($::els::active)
        }
    }
    switch $state {
        normal      { set tip "No external change has been detected since els opened or saved this file. Save always performs a full conflict check." }
        changed     { set tip "The file appears to have changed outside els. Save will ask before overwriting it." }
        missing     { set tip "The file no longer exists at its saved path." }
        unavailable { set tip "The file cannot currently be inspected." }
        readonly    { set tip "The file can be read but is not currently writable." }
        default     { set tip "This document has not been saved to disk." }
    }
    if {$detail ne ""} { append tip "\n$detail" }
    return $tip
}
proc els::disk_probe {{id ""} {mode forced}} {
    if {$id eq ""} { set id $::els::active }
    if {$id eq "" || $id ni $::els::docs || ![info exists ::els::docPath($id)]} { return "" }
    set path $::els::docPath($id)
    if {$path eq ""} {
        els::disk_probe_reset $id
        return [els::disk_state_set $id untitled]
    }
    # No automatic observer may synchronously poke an obvious UNC/network path:
    # a dead share can block Tk's only event thread for many seconds.  Explicit
    # open/save/reload operations remain the deliberate place for a real check.
    if {[els::remote_path $path]} {
        if {[info exists ::els::docDiskState($id)] && $::els::docDiskState($id) ne "untitled"} {
            return $::els::docDiskState($id)
        }
        return [els::disk_state_set $id unavailable "Network paths are checked only by explicit open, save, or reload actions."]
    }
    set observed [els::disk_stat_probe $path]
    set observedState [dict get $observed state]
    if {$observedState ne "ok"} {
        unset -nocomplain ::els::docDiskMeta($id) ::els::docDiskContent($id)
        if {$observedState ni {missing unavailable}} { set observedState unavailable }
        set detail ""
        if {[dict exists $observed error]} { set detail [dict get $observed error] }
        return [els::disk_state_set $id $observedState $detail]
    }
    set size [dict get $observed size]
    set mtime [dict get $observed mtime]
    set readonly [expr {[dict get $observed readonly] ? 1 : 0}]
    set norm [els::session_path $path]
    if {$norm eq ""} { set norm $path }
    set meta [list $norm $size $mtime]

    set priorMeta ""
    if {[info exists ::els::docDiskMeta($id)]} { set priorMeta $::els::docDiskMeta($id) }
    set contentState normal
    if {[info exists ::els::docDiskContent($id)]} {
        # A metadata-only observation may never clear a content change already
        # established by a full hash.  Only a later forced hash or rebase may.
        if {$::els::docDiskContent($id) eq "changed" || $priorMeta eq $meta} {
            set contentState $::els::docDiskContent($id)
        }
    }
    set baseline [els::doc_saved_sig $id]
    set bp [split $baseline :]
    set comparable [expr {[llength $bp] == 3 \
        && [string is integer -strict [lindex $bp 0]] \
        && [string is integer -strict [lindex $bp 1]] \
        && [info exists ::els::savedSigPath($id)] \
        && [els::same_path $::els::savedSigPath($id) $path]}]
    if {$comparable} {
        set baseSize [lindex $bp 0]
        set baseMtime [lindex $bp 1]
        if {$size != $baseSize} {
            set contentState changed
        } elseif {$mode ne "forced"} {
            # Timer/refresh paths are metadata-only and conservative.  They
            # never stream file content from Tk's event loop.
            if {$mtime != $baseMtime} { set contentState changed }
        } elseif {$size > $::els::DISK_DEEP_PROBE_CAP} {
            # Large observer checks stay cheap; the save guard still hashes all
            # bytes authoritatively before any overwrite.
            if {$mtime != $baseMtime} { set contentState changed }
        } else {
            set now [clock milliseconds]
            set due [expr {$priorMeta ne $meta || ![info exists ::els::docDiskDeepAt($id)] || \
                $now - $::els::docDiskDeepAt($id) >= $::els::DISK_DEEP_BACKOFF_MS}]
            if {$due} {
                set ::els::docDiskDeepAt($id) $now
                if {[catch {els::file_sig_probe $path} deep]} {
                    unset -nocomplain ::els::docDiskMeta($id) ::els::docDiskContent($id)
                    return [els::disk_state_set $id unavailable $deep]
                }
                set deepState [dict get $deep state]
                if {$deepState ne "ok"} {
                    unset -nocomplain ::els::docDiskMeta($id) ::els::docDiskContent($id)
                    set state [expr {$deepState eq "missing" ? "missing" : "unavailable"}]
                    set detail ""
                    if {[dict exists $deep error]} { set detail [dict get $deep error] }
                    return [els::disk_state_set $id $state $detail]
                }
                set actual [dict get $deep sig]
                set ap [split $actual :]
                if {[llength $ap] == 3} { set meta [list $norm [lindex $ap 0] [lindex $ap 1]] }
                set contentState [expr {[els::sig_content $actual] eq [els::sig_content $baseline] \
                    ? "normal" : "changed"}]
            }
        }
    }
    set ::els::docDiskMeta($id) $meta
    set ::els::docDiskContent($id) $contentState
    if {$contentState eq "normal" && $readonly} {
        return [els::disk_state_set $id readonly]
    }
    set detail ""
    if {$contentState eq "changed" && $readonly} { set detail "The disk file is also read-only." }
    return [els::disk_state_set $id $contentState $detail]
}
proc els::disk_watch_schedule {} {
    if {!$::els::disk_watch_active || $::els::disk_watch_after ne ""} { return }
    set ::els::disk_watch_after [after $::els::DISK_WATCH_MS els::disk_watch_tick]
}
proc els::disk_watch_activate {} {
    set ::els::disk_watch_active 1
    catch {els::disk_probe "" forced}
    els::disk_watch_schedule
}
proc els::disk_watch_deactivate {} {
    set ::els::disk_watch_active 0
    if {$::els::disk_watch_after ne ""} { catch {after cancel $::els::disk_watch_after} }
    set ::els::disk_watch_after ""
}
proc els::disk_watch_tick {} {
    set ::els::disk_watch_after ""
    if {!$::els::disk_watch_active} { return }
    if {[catch {els::disk_probe "" timer} err]} {
        catch {els::log warn "disk-state poll failed: $err"}
    }
    els::disk_watch_schedule
}

# ---- title / status -----------------------------------------------------
proc els::settitle {} {
    variable active
    # the title bar shows only the app name + version; the filename and dirty
    # state live on the tab and in the status bar instead
    wm title . "els $::els::version"
    if {$active eq ""} { return }
    els::update_namelabel
    .sb.eol  configure -text [els::eol_label $::els::docEol($active)]
    .sb.enc  configure -text [els::enc_label $::els::docEnc($active) $::els::docBom($active)]
}
# The left status item shows the active document's path, elided to fit — the
# filename always survives, the leading directories are dropped behind a "…/".
proc els::update_namelabel {} {
    variable active
    if {![winfo exists .sb.name]} { return }
    if {$::els::status_note_after ne ""} { return }   ;# a transient note holds the slot
    if {$active eq "" || ![info exists ::els::docPath($active)]} {
        .sb.name configure -text "" ; return
    }
    set p $::els::docPath($active)
    if {$p eq ""} { .sb.name configure -text "untitled" ; return }
    # the path's length rides along in the normal depiction (same [N] the hover
    # tip shows), not only in the tooltip once the path elides
    set suffix "  \[[string length [els::display_path $p]]\]"
    set avail [expr {[winfo width .sb.name] - 4 - [font measure elsUI $suffix]}]
    if {$avail < 24} { .sb.name configure -text [file tail $p]$suffix ; return }  ;# unrealized
    .sb.name configure -text [els::elide_path $p $avail]$suffix
}
# Strip a Windows extended-length prefix (\\?\ or //?/, incl. the UNC form) from
# a path.  Tcl's `file normalize` adds it for paths over MAX_PATH (260), and it
# must never leak into anything shown to a human.
proc els::strip_ext_prefix {p} {
    if {[regexp {^[\\/]{2}\?[\\/]UNC[\\/](.*)$} $p -> rest]} { return "//$rest" }
    if {[regexp {^[\\/]{2}\?[\\/](.*)$} $p -> rest]} { return $rest }
    return $p
}
# A path formatted for human display: native (backslash) separators, no
# extended-length prefix.
proc els::display_path {p} {
    return [file nativename [els::strip_ext_prefix $p]]
}
# Tooltip text for a path: the display path followed by its character length in
# square brackets, e.g.  C:\dir\file.txt [15].  ("" stays "" so empty tips are
# still suppressed.)  The length is of the real path, sans extended prefix.
proc els::path_tip {p} {
    if {$p eq ""} { return "" }
    set d [els::display_path $p]
    return "$d \[[string length $d]\]"
}
proc els::elide_path {p avail} {
    set p [els::strip_ext_prefix $p]
    if {[font measure elsUI $p] <= $avail} { return $p }
    set parts [file split $p]
    set best ""
    # grow outward from the filename, keeping as much trailing path as fits
    for {set i [expr {[llength $parts] - 1}]} {$i >= 0} {incr i -1} {
        set tail [file join {*}[lrange $parts $i end]]
        set cand [expr {$i == 0 ? $tail : "…/$tail"}]
        if {[font measure elsUI $cand] <= $avail} { set best $cand } else { break }
    }
    if {$best ne ""} { return $best }
    # even the filename alone is too wide — clip its head, keep the end
    set s [file tail $p]
    while {[string length $s] > 1 && [font measure elsUI "…$s"] > $avail} {
        set s [string range $s 1 end]
    }
    return "…$s"
}
# Tooltip text for the status-bar name: the full path, but only while the label
# is actually eliding it (when the whole path fits, the tip would be redundant).
proc els::name_tip {} {
    variable active
    if {$active eq "" || ![info exists ::els::docPath($active)]} { return "" }
    set p $::els::docPath($active)
    if {$p eq ""} { return "" }
    # suppress the tip while the label shows the WHOLE path: the displayed text
    # is "<path>  [N]" since the length suffix rode along, so compare against
    # that full non-elided rendering, not against the bare path
    set suffix "  \[[string length [els::display_path $p]]\]"
    if {[.sb.name cget -text] eq "[els::strip_ext_prefix $p]$suffix"} { return "" }
    return [els::path_tip $p]
}
proc els::status_link_enter {w} {
    if {![winfo exists $w]} { return }
    $w configure -foreground $::els::INK -background $::els::TABBG
}
proc els::status_link_leave {w} {
    if {![winfo exists $w]} { return }
    $w configure -foreground $::els::MUTED -background $::els::CHROME
}

# ---- Edit-menu actions, routed to the active document -------------------
# A mouse-driven Edit menu undo/redo produces no key event on the text widget
# (and <<Modified>> only fires on flag transitions), so the view must be
# refreshed — and the autosave latched — explicitly, like other button edits.
proc els::menu_undo {} {
    set w [els::T]
    if {$w eq ""} { return }
    catch {$w edit undo}
    els::refresh_schedule
}
proc els::menu_redo {} {
    set w [els::T]
    if {$w eq ""} { return }
    catch {$w edit redo}
    els::refresh_schedule
}
proc els::menu_event {ev} { set w [els::T] ; if {$w ne ""} { event generate $w $ev } }

# ---- text transforms (Buffer menu) ----------------------------------------
# A curated, opinionated set of buffer transforms.  Each is undo-atomic (one
# separator-bracketed edit == one undo) and routes through the same <<Modified>> +
# view refresh as a typed edit, so the dirty state, autosave arming, and the
# gutter/whitespace all stay in sync.  Conventions: line-reorder ops act on the selected lines or,
# with no selection, the WHOLE buffer; the rest act on the selected lines (or the
# current line).  els indents with a tab (no width knob); dedent also eats up to
# four leading spaces so space-indented text still outdents.
namespace eval ::els::xform {}

# Bracket BODY (run in the caller's frame) as a single undo unit on widget W, then
# refresh the view like any edit (the edit itself fires <<Modified>>).
proc els::xform::atomic {w body} {
    set as [$w cget -autoseparators]
    $w configure -autoseparators 0
    $w edit separator
    set rc [catch {uplevel 1 $body} res opts]
    $w edit separator
    $w configure -autoseparators $as
    if {$rc == 0} { catch {els::refresh_schedule} }
    return -options $opts $res
}
proc els::xform::lastline {w} { return [lindex [split [$w index "end - 1 char"] .] 0] }
# Last DOCUMENT line.  When the text ends in \n, "end - 1 char" sits at column 0
# of the widget's mandatory final line: an empty pseudo-line that represents the
# trailing newline, not content (worker snapshots pin the same invariant).  Line
# ops must stop above it, or they drag a phantom "" into their input and write
# it back as real text (sort/reverse moved a blank line to the top and ate the
# trailing newline; dedupe ate it whenever an interior blank line existed).
# delete_line is the one caller that wants the raw widget line (lastline):
# deleting "the empty last line" legitimately removes the trailing newline.
proc els::xform::lastdoc {w} {
    lassign [split [$w index "end - 1 char"] .] l c
    if {$c == 0 && $l > 1} { incr l -1 }
    return $l
}
# 1-based line span the selection touches, else the current line.  A selection that
# ends at column 0 does not pull in that trailing (untouched) line; a selection
# reaching past the last document line (Select All runs to `end`) is clamped to it.
proc els::xform::span {w} {
    set r [$w tag ranges sel]
    if {[llength $r]} {
        lassign [split [$w index [lindex $r 0]] .] l1 c1
        lassign [split [$w index [lindex $r end]] .] l2 c2
        if {$c2 == 0 && $l2 > $l1} { incr l2 -1 }
        set ld [els::xform::lastdoc $w]
        if {$l2 > $ld && $ld >= $l1} { set l2 $ld }
        return [list $l1 $l2]
    }
    lassign [split [$w index insert] .] l c
    return [list $l $l]
}
proc els::xform::span_or_all {w} {
    if {[llength [$w tag ranges sel]]} { return [els::xform::span $w] }
    return [list 1 [els::xform::lastdoc $w]]
}
# Replace whole lines L1..L2 with LIST (leaving the trailing newline structure intact).
proc els::xform::replace_lines {w l1 l2 list} {
    $w replace "$l1.0" "$l2.end" [join $list \n]
}
proc els::xform::reselect {w l1 n} {
    $w tag remove sel 1.0 end
    if {$n > 0} { $w tag add sel "$l1.0" "[expr {$l1 + $n - 1}].end" ; $w mark set insert "$l1.0" }
}

# --- move a line / block up or down ---------------------------------------
proc els::xform::move {dir} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    if {$dir < 0 && $l1 <= 1} return
    if {$dir > 0 && $l2 >= [els::xform::lastdoc $w]} return
    if {$dir < 0} {
        els::xform::atomic $w {
            set lines [split [$w get "[expr {$l1-1}].0" "$l2.end"] \n]
            els::xform::replace_lines $w [expr {$l1-1}] $l2 \
                [concat [lrange $lines 1 end] [list [lindex $lines 0]]]
        }
        els::xform::reselect $w [expr {$l1-1}] [expr {$l2-$l1+1}]
    } else {
        els::xform::atomic $w {
            set lines [split [$w get "$l1.0" "[expr {$l2+1}].end"] \n]
            els::xform::replace_lines $w $l1 [expr {$l2+1}] \
                [concat [list [lindex $lines end]] [lrange $lines 0 end-1]]
        }
        els::xform::reselect $w [expr {$l1+1}] [expr {$l2-$l1+1}]
    }
}

# --- duplicate the current line / selected lines below the block ----------
proc els::xform::duplicate {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    set block [$w get "$l1.0" "$l2.end"]
    els::xform::atomic $w { $w insert "$l2.end" "\n$block" }
    els::xform::reselect $w [expr {$l2+1}] [expr {$l2-$l1+1}]
}

# --- delete the current line / selected lines entirely --------------------
proc els::xform::delete_line {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    set last [els::xform::lastline $w]
    els::xform::atomic $w {
        if {$l2 >= $last} {
            if {$l1 <= 1} { $w delete 1.0 end } else { $w delete "[expr {$l1-1}].end" "end - 1 char" }
        } else {
            $w delete "$l1.0" "[expr {$l2+1}].0"
        }
    }
    $w tag remove sel 1.0 end
    catch {$w mark set insert "$l1.0"} ; $w see insert
}

# --- join the selected lines (or current + next) into one -----------------
proc els::xform::join_lines {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    if {$l1 == $l2} {
        if {$l2 >= [els::xform::lastdoc $w]} return
        incr l2
    }
    set lines [split [$w get "$l1.0" "$l2.end"] \n]
    set joined [lindex $lines 0]
    foreach l [lrange $lines 1 end] { append joined " " [string trimleft $l] }
    els::xform::atomic $w { els::xform::replace_lines $w $l1 $l2 [list $joined] }
    $w tag remove sel 1.0 end ; $w mark set insert "$l1.end"
}

# --- sort / reverse / dedupe lines (selection, else whole buffer) ---------
proc els::xform::sort {{dir 1}} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span_or_all $w] l1 l2
    set lines [split [$w get "$l1.0" "$l2.end"] \n]
    set out [expr {$dir < 0 ? [lsort -decreasing $lines] : [lsort $lines]}]
    if {$out eq $lines} return
    els::xform::atomic $w { els::xform::replace_lines $w $l1 $l2 $out }
    els::xform::reselect $w $l1 [llength $out]
}
proc els::xform::reverse {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span_or_all $w] l1 l2
    set lines [split [$w get "$l1.0" "$l2.end"] \n]
    if {[llength $lines] < 2} return
    els::xform::atomic $w { els::xform::replace_lines $w $l1 $l2 [lreverse $lines] }
    els::xform::reselect $w $l1 [llength $lines]
}
proc els::xform::dedupe {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span_or_all $w] l1 l2
    set lines [split [$w get "$l1.0" "$l2.end"] \n]
    set out {} ; set seen {}
    foreach l $lines { if {![dict exists $seen $l]} { dict set seen $l 1 ; lappend out $l } }
    if {$out eq $lines} return
    els::xform::atomic $w { els::xform::replace_lines $w $l1 $l2 $out }
    els::xform::reselect $w $l1 [llength $out]
}

# --- case transforms (selection, else current line) -----------------------
proc els::xform::case {mode} {
    set w [els::T] ; if {$w eq ""} return
    set r [$w tag ranges sel]
    if {[llength $r]} {
        set a [$w index [lindex $r 0]] ; set b [$w index [lindex $r end]]
        # Select All runs to `end`, past the mandatory final newline: a replace
        # can never delete that newline, but it WOULD insert the copy carried
        # in $new — growing the buffer by one line per pass.  Clamp to the
        # last real character.
        if {[$w compare $b > "end - 1 char"]} { set b [$w index "end - 1 char"] }
    } \
    else { set a [$w index "insert linestart"] ; set b [$w index "insert lineend"] }
    set txt [$w get $a $b]
    set new [expr {$mode eq "upper" ? [string toupper $txt] : [string tolower $txt]}]
    if {$new eq $txt} return
    els::xform::atomic $w { $w replace $a $b $new }
    $w tag remove sel 1.0 end
    $w tag add sel $a [$w index "$a + [string length $new] chars"]
}

# --- trim trailing whitespace across the whole buffer ---------------------
proc els::xform::trim_trailing {} {
    set w [els::T] ; if {$w eq ""} return
    set lines [split [$w get 1.0 "end - 1 char"] \n]
    set out [lmap l $lines { string trimright $l " \t" }]
    if {$out eq $lines} return
    set ins [$w index insert]
    els::xform::atomic $w { $w replace 1.0 "end - 1 char" [join $out \n] }
    catch {$w mark set insert $ins} ; $w see insert
}

# --- indent / dedent the selected lines (or the current line) -------------
proc els::xform::indent {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    els::xform::atomic $w {
        for {set l $l1} {$l <= $l2} {incr l} { $w insert "$l.0" "\t" }
    }
    $w tag remove sel 1.0 end ; $w tag add sel "$l1.0" "$l2.end"
}
proc els::xform::dedent {} {
    set w [els::T] ; if {$w eq ""} return
    lassign [els::xform::span $w] l1 l2
    els::xform::atomic $w {
        for {set l $l1} {$l <= $l2} {incr l} {
            set line [$w get "$l.0" "$l.end"]
            if {[string index $line 0] eq "\t"} {
                $w delete "$l.0" "$l.0 + 1 char"
            } elseif {[string index $line 0] eq " "} {
                set n 0 ; while {$n < 4 && [string index $line $n] eq " "} { incr n }
                $w delete "$l.0" "$l.0 + $n chars"
            }
        }
    }
    $w tag remove sel 1.0 end ; $w tag add sel "$l1.0" "$l2.end"
}
# Tab indents whenever text is selected (any selection — one line or many) so the
# binding ALWAYS breaks while a selection exists and can never fall through to Tk's
# default Text <Tab>, whose tk::TextInsert deletes the selection and replaces it with
# a tab (silent text loss).  With no selection, Tab is a literal tab at the caret.
# Shift+Tab always dedents (the current line when nothing is selected).
proc els::xform::tab_indents {w} {
    return [expr {[llength [$w tag ranges sel]] > 0}]
}
proc els::on_modified {w} {
    variable active
    set id [els::id_of $w]
    if {$id eq ""} { return }
    if {[$w edit modified]} {
        els::autosave_soon $id                                ;# opt-in; debounced
    }
    els::update_tab $id
    if {$id eq $active} {
        els::settitle
        after idle els::refresh_view
    }
}
proc els::update_pos {} {
    set w [els::T]
    if {$w eq ""} { return }
    lassign [split [$w index insert] .] line col
    .sb.pos configure -text "Ln $line Col [expr {$col + 1}]"
}
proc els::line_count {} {
    set w [els::T]
    if {$w eq ""} { return 1 }
    set line [lindex [split [$w index "end - 1 char"] .] 0]
    if {$line < 1} { return 1 }
    return $line
}
proc els::update_current_line {} {
    set w [els::T]
    if {$w eq ""} { return }
    set line [lindex [split [$w index insert] .] 0]
    $w tag remove currentLine 1.0 end
    # emptiness via index compare, never `$w get 1.0 end-1c`: materializing the
    # whole buffer here made every keystroke O(document size)
    if {[$w compare "end - 1 char" != 1.0]} {
        $w tag add currentLine "$line.0" "$line.end + 1 char"
    }
    if {$::els::focus_mode} { els::focus_update $w $line }
    # the gutter's matching current-line band is drawn by els::draw_gutter
}
# Focus mode: keep the focusDim tag on every line EXCEPT the current one.  Runs on
# the caret hot path (every refresh_view / update_current_line), but a full retag
# is cheap: Tk stores tags as B-tree toggle points, so the whole-buffer remove +
# two adds are O(log n) (a handful of toggle points), and only the VISIBLE lines
# actually repaint — the same cost model as the currentLine wash next door.  A full
# retag every time is what keeps it CORRECT: a delta keyed on line count + caret
# line is blind to an equal-line-count structural edit (a line swap, a paste over a
# multi-line selection, a reopen/reload re-decoded to the same line count), which
# would strand a wrong dim.
proc els::focus_update {w line} {
    $w tag remove focusDim 1.0 end
    if {[$w compare "end - 1 char" != 1.0]} {
        $w tag add focusDim 1.0 "$line.0"
        $w tag add focusDim "$line.end + 1 char" end
    }
}
# View ▸ Focus Mode.  On: dim now (a full retag via update_current_line).  Off:
# clear the dim from every open doc.
proc els::set_focus_mode {{persist 1}} {
    if {$::els::focus_mode} {
        els::update_current_line
    } else {
        foreach id $::els::docs {
            set w [els::W $id]
            if {[winfo exists $w]} { $w tag remove focusDim 1.0 end }
        }
    }
    if {$persist} { els::save_geometry }
}
# Draw the line-number gutter for the CURRENTLY VISIBLE rows only, onto the
# Canvas .ln.  We ask the text widget where each visible logical line's first
# display row sits (dlineinfo) and place a right-aligned number at that baseline;
# continuation rows of a wrapped line get no number.  Cost is O(visible rows),
# independent of document size, and wrap alignment is exact and automatic (no
# leading-mirror tags).  The current line gets a wash behind its number.
proc els::draw_gutter {} {
    set w [els::T]
    if {$w eq "" || ![winfo exists .ln]} { return }
    if {!$::els::show_linenos} { return }   ;# gutter hidden: skip the work too
    .ln delete all
    set lines [els::line_count]
    set digits [expr {max(2, [string length $lines] + 1)}]
    # Pixel width for `digits` glyphs + padding.  Reconfigure ONLY on change: a
    # width change is a geometry op, so caching keeps the scroll path geometry-
    # free (digit count only changes on edits, never on a pure scroll).
    set px [expr {[font measure elsMono [string repeat 8 $digits]] + 12}]
    if {$px != $::els::gutter_px} {
        set ::els::gutter_px $px
        .ln configure -width $px
    }
    set h [winfo height $w]
    if {$h <= 1} { return }   ;# not realized yet — a later refresh will draw it
    # use the REQUESTED width: `winfo width` still reports the old realized
    # width until the geometry pass runs, so after a digit-count change the
    # numbers would right-align (and the band would size) against the old edge
    # for one visible frame
    set gw $::els::gutter_px
    set right [expr {$gw - 6}]
    set ascent [font metrics elsMono -ascent]
    set first [lindex [split [$w index @0,0] .] 0]
    set last  [lindex [split [$w index "@0,$h"] .] 0]
    set cur   [lindex [split [$w index insert] .] 0]
    # emptiness via index compare (a full `$w get` is O(document size))
    set hasText [$w compare "end - 1 char" != 1.0]
    # the current line's band must cover the line's FULL visible extent: with
    # word wrap a line spans several display rows (the text wash covers all of
    # them), and when its first row is scrolled off the top, dlineinfo "$cur.0"
    # is empty — wash the visible continuation rows from the canvas top.
    if {$hasText && $cur == $first && [$w dlineinfo "$cur.0"] eq ""} {
        set nx [$w dlineinfo "$cur.0 + 1 line linestart"]
        if {$nx ne ""} { set bot [lindex $nx 1] } else { set bot $h }
        .ln create rectangle 0 0 $gw $bot -fill $::els::LINE -outline ""
    }
    for {set ln $first} {$ln <= $last} {incr ln} {
        set di [$w dlineinfo "$ln.0"]
        if {$di eq ""} { continue }   ;# this line's first row is scrolled off
        lassign $di dx dy dw dh dbase
        if {$hasText && $ln == $cur} {
            set nx [$w dlineinfo "$ln.0 + 1 line linestart"]
            if {$nx ne ""} { set bot [lindex $nx 1] } else { set bot $h }
            if {$bot < $dy + $dh} { set bot [expr {$dy + $dh}] }
            .ln create rectangle 0 $dy $gw $bot -fill $::els::LINE -outline ""
        }
        # anchor ne at (right, baseline-ascent) puts the number's baseline on the
        # text row's baseline and its right edge at the gutter's right margin
        .ln create text $right [expr {$dy + $dbase - $ascent}] -anchor ne \
            -text $ln -font elsMono -fill $::els::GUTTINK
    }
}
# Coalesce gutter redraws caused by scrolling: a burst schedules ONE draw after
# the display loop settles (mirrors the vscroll / whitespace deferrals, and
# keeps the canvas width-configure out of the -yscrollcommand re-entrancy path).
proc els::gutter_schedule {} {
    variable gutter_after
    after cancel $gutter_after
    set gutter_after [after idle els::draw_gutter]
}
proc els::sync_scroll {} {
    if {[els::T] ne "" && [winfo exists .ln]} { els::gutter_schedule }
}
proc els::yscroll {id first last} {
    variable active
    variable vs_after
    if {$id ne $active} { return }
    .vs set $first $last
    els::gutter_schedule   ;# redraw the visible gutter numbers for the new view
    # Defer the scrollbar show/hide to idle: it calls `grid` (a geometry change),
    # and running that from inside a -yscrollcommand can re-enter the display
    # loop. Coalesced so a burst of scrolls schedules one update.
    after cancel $vs_after
    set vs_after [after idle els::update_vscroll]
    # whitespace tints are viewport-scoped, so re-tag after a scroll (coalesced)
    if {$::els::show_ws} {
        after cancel $::els::ws_after
        set ::els::ws_after [after idle els::ws_refresh]
    }
}
# Show the scrollbar only when the document doesn't fit (chrome defers).  Reads
# the live yview rather than a possibly-stale -yscrollcommand value, so it's
# correct after a load settles (yscrollcommand only fires on view *change*).
proc els::update_vscroll {} {
    variable active
    variable vs_shown
    if {$active eq "" || ![winfo exists [els::W $active]]} { return }
    lassign [[els::W $active] yview] first last
    # re-feed the shared bar from the live view: re-gridding a widget with an
    # unchanged view does not re-fire -yscrollcommand, so after a tab switch
    # the thumb still showed the PREVIOUS tab's position
    .vs set $first $last
    set need [expr {$first > 0.0001 || $last < 0.9999}]
    if {$need != $vs_shown} {
        set vs_shown $need
        if {$need} { grid .vs } else { grid remove .vs }
    }
}
proc els::scroll {args} {
    set w [els::T]
    if {$w eq ""} { return }
    $w yview {*}$args
    els::sync_scroll
}
proc els::wheel {delta} {
    set w [els::T]
    if {$w eq ""} { return }
    # scroll EXACTLY as the text widget's own <MouseWheel> class binding does
    # (tk::MouseWheel + tk::ScaleNum applies the display scaling), so one notch
    # moves the view the same amount whether the pointer is over the gutter or the
    # text — the old "1 line per notch" units drifted from the text on a scaled
    # display and the rate jumped as the pointer crossed the boundary (G-View mat-5)
    tk::MouseWheel $w y [tk::ScaleNum $delta] -4.0 pixels
    els::sync_scroll
}
# Precision-touchpad scrolling (Tk 9 delivers it as <TouchpadScroll>, which the
# Text class handles but a bare canvas does not) — used by the gutter.
proc els::touchpad_scroll {D} {
    set w [els::T]
    if {$w eq ""} { return }
    # tk::ScaleNum matches the text widget's own <TouchpadScroll> class binding, so
    # a precision-touchpad pan moves the view the same amount over the gutter as
    # over the text on a scaled display (G-View mat-5)
    lassign [tk::PreciseScrollDeltas $D] dx dy
    if {$dy != 0} { $w yview scroll [tk::ScaleNum [expr {-$dy}]] pixels ; els::sync_scroll }
    if {$dx != 0} { $w xview scroll [tk::ScaleNum [expr {-$dx}]] pixels }
}
# Ctrl+touchpad-scroll = zoom (matching Ctrl+MouseWheel): without these
# bindings the gesture fell through to the plain TouchpadScroll handler and
# scrolled instead.  Deltas accumulate so the high event rate zooms smoothly.
proc els::zoom_touchpad {D} {
    lassign [tk::PreciseScrollDeltas $D] dx dy
    if {$dy == 0} { return }
    set a [expr {$::els::tp_zoom_acc + $dy}]
    while {$a >= 60}  { els::zoom 1  ; set a [expr {$a - 60}] }
    while {$a <= -60} { els::zoom -1 ; set a [expr {$a + 60}] }
    set ::els::tp_zoom_acc $a
}
# ---- horizontal scrolling (active only when word wrap is off) -----------
# The text widget fires -xscrollcommand only on a view *change*; the show/hide
# is deferred to idle (it calls `grid`, a geometry change) and coalesced, exactly
# like the vertical bar.
proc els::xscroll {id first last} {
    variable active
    variable hs_after
    if {$id ne $active} { return }
    .hs set $first $last
    after cancel $hs_after
    set hs_after [after idle els::update_hscroll]
    # whitespace tints are viewport-scoped: a horizontal pan changes what is
    # visible too, and without this the top row's left-of-viewport whitespace
    # stayed untinted after panning back (only yscroll re-tagged)
    if {$::els::show_ws} {
        after cancel $::els::ws_after
        set ::els::ws_after [after idle els::ws_refresh]
    }
}
# Show the horizontal bar only when wrap is off AND a line runs past the window
# edge.  Under word wrap nothing scrolls sideways (xview is {0 1}), so the bar
# stays hidden — which is exactly the requested behaviour.
proc els::update_hscroll {} {
    variable active
    variable hs_shown
    if {$active eq "" || ![winfo exists [els::W $active]]} { return }
    if {$::els::word_wrap} {
        set need 0
    } else {
        lassign [[els::W $active] xview] first last
        .hs set $first $last   ;# re-feed after a tab switch (same as update_vscroll)
        set need [expr {$first > 0.0001 || $last < 0.9999}]
    }
    if {$need != $hs_shown} {
        set hs_shown $need
        if {$need} { grid .hs } else { grid remove .hs }
    }
}
proc els::hscroll {args} {
    set w [els::T]
    if {$w eq ""} { return }
    $w xview {*}$args
}
proc els::hwheel {delta} {
    set w [els::T]
    if {$w eq ""} { return }
    $w xview scroll [expr {-$delta / 120.0}] units
}
proc els::refresh_view {} {
    if {[els::T] eq ""} { return }
    els::update_pos
    els::update_current_line
    els::draw_gutter
    els::update_vscroll
    els::update_hscroll
    if {$::els::show_ws} { els::ws_refresh }
}
# Coalesce deferred full refreshes (like gutter_schedule): a resize delivers a
# continuous <Configure> stream, and one queued refresh per event multiplied
# the whole repaint several-fold per frame.
proc els::refresh_schedule {} {
    variable refresh_after
    after cancel $refresh_after
    set refresh_after [after idle els::refresh_view]
}

# ---- encoding / EOL -----------------------------------------------------
# Load the optional ICU charset detector (build/icudet.dll in source trees, a
# sibling of main.tcl in the packaged image).  Detection is a bonus: if the DLL
# or the system icu.dll is absent, els falls back to BOM + UTF-8 + cp1252.
proc els::load_detect {} {
    set dir [file dirname [info script]]
    foreach cand [list [file join $dir icudet.dll] [file join $dir build icudet.dll]] {
        if {[file exists $cand] && ![catch {load $cand Icudet}]} {
            # confirm icu.dll itself resolved (detect returns "" if not)
            return [expr {[::elsdet::detect "the quick brown fox jumps over"] ne ""}]
        }
    }
    if {![catch {package require icudet}] && \
        [::elsdet::detect "the quick brown fox jumps over"] ne ""} { return 1 }
    return 0
}

# Map an ICU canonical charset name onto a Tcl encoding name ("" = no match).
# ICU reports logical-order Hebrew as ISO-8859-8-I: byte-table identical to
# ISO-8859-8 (the -I only flags ordering), so it maps onto the same encoding.
proc els::icu_to_tcl {name} {
    set key [string tolower [string map {- "" _ "" " " ""} $name]]
    set map {
        utf8 utf-8  utf16 utf-16le  utf16le utf-16le  utf16be utf-16be
        utf32 utf-32le  utf32le utf-32le  utf32be utf-32be  usascii ascii
        iso88591 iso8859-1   iso88592 iso8859-2   iso88593 iso8859-3
        iso88594 iso8859-4   iso88595 iso8859-5   iso88596 iso8859-6
        iso88597 iso8859-7   iso88598 iso8859-8   iso88598i iso8859-8
        iso88599 iso8859-9
        iso885910 iso8859-10 iso885913 iso8859-13 iso885914 iso8859-14
        iso885915 iso8859-15 iso885916 iso8859-16
        windows1250 cp1250 windows1251 cp1251 windows1252 cp1252 windows1253 cp1253
        windows1254 cp1254 windows1255 cp1255 windows1256 cp1256 windows1257 cp1257
        windows1258 cp1258 windows874 cp874 tis620 tis-620
        shiftjis cp932 windows31j cp932 sjis cp932 ms932 cp932
        gb18030 cp936 gbk cp936 windows936 cp936 gb2312 gb2312 hzgb2312 gb2312
        big5 big5 big5hkscs big5
        eucjp euc-jp euckr euc-kr euccn euc-cn euctw euc-cn
        koi8r koi8-r koi8u koi8-u
        iso2022jp iso2022-jp iso2022kr iso2022-kr
        ibm420 ebcdic ibm424 ebcdic
    }
    if {[dict exists $map $key]} { return [dict get $map $key] }
    foreach e [encoding names] {
        if {[string map {- "" _ "" " " ""} $e] eq $key} { return $e }
    }
    return ""
}

# Resolve a BOM-less wide encoding from a STRONG UTF-16/32 NUL signature.  A
# genuine wide file has many NULs concentrated in one byte-parity (the high-byte
# of each mostly-ASCII code unit).  A file with only a few stray NULs (a log, a
# text/db export, ASCII with an embedded NUL) is NOT wide and returns "" so it is
# read as text instead of being mangled into UTF-16.  ICU picks LE/BE/32 once the
# signature is established; without ICU, parity gives UTF-16 LE/BE.
proc els::detect_wide {raw sample} {
    set n [string length $sample]
    if {$n < 4} { return "" }
    set even 0 ; set odd 0 ; set i 0
    foreach b [split $sample ""] {
        if {$b eq "\x00"} { if {$i & 1} { incr odd } else { incr even } }
        incr i
    }
    set nul [expr {$even + $odd}]
    set dominant [expr {max($even, $odd)}]
    set other    [expr {min($even, $odd)}]
    # require a structural share of NULs (>~5%) lopsided to one parity; a couple
    # of stray NULs, or NULs spread across both parities (binary), are not wide.
    # The ABSOLUTE floor ($dominant < 4) is essential: on a tiny file the >=5%
    # share is met by ONE stray NUL (1 NUL is >5% of a <=20-byte sample and is
    # trivially lopsided), which was misread as UTF-16 mojibake.  A genuine
    # BOM-less wide file packs many NULs into one parity, so 4 is a safe floor.
    if {$dominant < 4 || $nul * 20 < $n || $other > $dominant / 3} { return "" }
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            set enc [els::icu_to_tcl [lindex $d 0]]
            if {[string match utf-* $enc]} { return $enc }
        }
    }
    return [expr {$even > $odd ? "utf-16be" : "utf-16le"}]
}

# Fast ASCII-only test: true iff every byte is < 0x80.  Uses the C-level
# `string is` instead of a per-byte Tcl loop (which froze the UI on a big file).
proc els::bytes_ascii_only {raw} {
    return [string is ascii $raw]
}

proc els::detect_encoding {raw} {
    # -> {encoding bom}.  bom=1 if a byte-order mark was present (stripped on decode).
    set n [string length $raw]
    if {$n == 0} { return {utf-8 0} }
    # 1. BOM sniff — UTF-32 before UTF-16 (the UTF-32 LE BOM begins FF FE too).
    if {[string range $raw 0 3] eq "\x00\x00\xFE\xFF"} { return {utf-32be 1} }
    if {[string range $raw 0 3] eq "\xFF\xFE\x00\x00"} { return {utf-32le 1} }
    if {[string range $raw 0 2] eq "\xEF\xBB\xBF"} {
        # Trust the UTF-8 BOM only when the payload really is valid UTF-8: a
        # Windows tool prepending a BOM to legacy (cp1252...) content is common,
        # and decoding that payload as utf-8 -profile replace would destroy
        # every non-UTF-8 byte (U+FFFD -> EF BF BD on save).  On invalid payload
        # fall through to detection over the WHOLE raw (BOM bytes stay content,
        # which round-trips losslessly).
        if {![catch {encoding convertfrom -profile strict utf-8 \
                         [string range $raw 3 end]}]} {
            return {utf-8 1}
        }
    }
    if {[string range $raw 0 1] eq "\xFF\xFE"}         { return {utf-16le 1} }
    if {[string range $raw 0 1] eq "\xFE\xFF"}         { return {utf-16be 1} }
    set sample [string range $raw 0 4095]
    # 2. NUL bytes => a wide encoding (BOM-less UTF-16/32).  Text in ASCII/UTF-8
    #    or any 8-bit/CJN encoding never contains NUL — and UTF-16-of-ASCII would
    #    otherwise sneak through the UTF-8 test below, so resolve it first.
    if {[string first "\x00" $sample] >= 0} {
        set enc [els::detect_wide $raw $sample]
        if {$enc ne ""} { return [list $enc 0] }
    }
    # 3. ASCII-only bytes are shared by UTF-8 and most legacy encodings; there is
    #    no honest way to distinguish them, so els uses UTF-8 as the default.
    if {[els::bytes_ascii_only $raw]} { return {utf-8 0} }
    # 4. ICU charset detection (chardet quality) for legacy 8-bit / CJK text.
    #    This runs before the UTF-8 validity fallback so valid byte sequences do
    #    not automatically mask a stronger legacy/CJK detector answer.
    set utf8_ok [expr {![catch {encoding convertfrom -profile strict utf-8 $raw}]}]
    if {$::els::have_detect} {
        set d [::elsdet::detect $raw]
        if {[llength $d] == 2} {
            lassign $d icu conf
            set enc [els::icu_to_tcl $icu]
            # never accept a utf-8 verdict for bytes that are NOT valid UTF-8:
            # ICU trusts a BOM even when the payload is legacy bytes
            if {$enc eq "utf-8" && !$utf8_ok} { set enc "" }
            if {$enc eq "cp1252"} { set enc [els::cp1252_or_latin1 $raw] }
            if {$enc ne "" && $conf >= $::els::DETECT_MIN} { return [list $enc 0] }
        }
    }
    # 5. UTF-8 fallback when the bytes are strictly valid and ICU had no better
    #    answer.  Otherwise Windows Western — demoted to Latin-1 when the bytes
    #    include code points cp1252 cannot round-trip.
    if {$utf8_ok} { return {utf-8 0} }
    return [list [els::cp1252_or_latin1 $raw] 0]
}
# cp1252 leaves 0x81 0x8D 0x8F 0x90 0x9D undefined: Tcl 9 decodes them to
# U+FFFD and save re-encodes that as "?" — silent byte destruction.  When any
# of those bytes is present, use iso8859-1 instead: it maps all 256 bytes, so
# the file round-trips losslessly.
proc els::cp1252_or_latin1 {raw} {
    if {[regexp {[\x81\x8D\x8F\x90\x9D]} $raw]} { return iso8859-1 }
    return cp1252
}
# Decode raw bytes to the internal string.  If `lossyVar` is given, set it to 1
# when the -profile replace decode SUBSTITUTED U+FFFD for bytes the encoding can't
# hold (silent corruption the user should see before saving — see docDecodeLossy),
# distinguished from a source that genuinely contains U+FFFD by whether a STRICT
# decode of the same (BOM-stripped) bytes throws.
proc els::decode {raw enc bom {lossyVar ""}} {
    if {$bom} {
        # Strip the BOM only when those bytes are actually present: the curated
        # picker can assert bom=1 ("UTF-8 with BOM") on a file that has none,
        # and a blind byte-count skip would eat the first 2-4 CONTENT bytes —
        # persisted by the next save.  (Reopening a BOM-less file as a
        # with-BOM encoding now means "add the BOM on save", losing nothing.)
        switch -- $enc {
            utf-8    { set bomb "\xEF\xBB\xBF" }
            utf-16le { set bomb "\xFF\xFE" }
            utf-16be { set bomb "\xFE\xFF" }
            utf-32le { set bomb "\xFF\xFE\x00\x00" }
            utf-32be { set bomb "\x00\x00\xFE\xFF" }
            default  { set bomb "" }
        }
        set skip [string length $bomb]
        if {$bomb ne "" && [string range $raw 0 [expr {$skip - 1}]] eq $bomb} {
            set raw [string range $raw $skip end]
        }
    }
    set text [encoding convertfrom -profile replace $enc $raw]
    if {$lossyVar ne ""} {
        upvar 1 $lossyVar lossy
        # fast gate: a clean file has no U+FFFD, so it pays only one string scan.
        # Only if one is present do we run the (cheap-relative-to-open) strict pass:
        # strict THROWS exactly when a byte was unrepresentable, i.e. the replace
        # profile introduced the U+FFFD; if strict succeeds the U+FFFD is genuine.
        set lossy [expr {[string first � $text] >= 0 \
                         && [catch {encoding convertfrom -profile strict $enc $raw}]}]
    }
    return $text
}
proc els::detect_eol {text} {
    # Pick the DOMINANT ending, not the first one seen: first-match priority
    # classified a mostly-LF file with one stray CRLF as crlf, so a save
    # rewrote every line ending in the file.  Ties keep crlf > lf > cr.
    set crlf [regexp -all {\r\n} $text]
    set cr   [expr {[regexp -all {\r} $text] - $crlf}]
    set lf   [expr {[regexp -all {\n} $text] - $crlf}]
    if {$crlf > 0 && $crlf >= $lf && $crlf >= $cr} { return crlf }
    if {$lf > 0 && $lf >= $cr} { return lf }
    if {$cr > 0} { return cr }
    return lf
}
proc els::enc_label {enc bom} {
    set m {utf-8 "UTF-8" utf-16le "UTF-16 LE" utf-16be "UTF-16 BE" \
           utf-32le "UTF-32 LE" utf-32be "UTF-32 BE"}
    set s [expr {[dict exists $m $enc] ? [dict get $m $enc] : [string toupper $enc]}]
    if {$bom} { append s " BOM" }
    return $s
}
proc els::eol_label {eol} { return [string map {lf LF crlf CRLF cr CR} $eol] }

# ---- encoding / EOL pickers (clickable status-bar indicators) ------------
# Build a menu of {label enc bom} curated entries plus an "Other (all)" cascade
# of every Tcl encoding.  `action` is reopen|save.
proc els::enc_menu {path action} {
    menu $path -tearoff 0
    foreach {label enc bom} $::els::ENC_CURATED {
        if {$label eq "-"} { $path add separator; continue }
        $path add command -label $label -command [list els::apply_enc $action $enc $bom]
    }
    $path add separator
    set other $path.other
    menu $other -tearoff 0
    set i 0
    foreach e [lsort -dictionary [encoding names]] {
        # column-break the long list so it never runs off-screen
        $other add command -label $e -command [list els::apply_enc $action $e 0] \
            -columnbreak [expr {$i > 0 && $i % 28 == 0}]
        incr i
    }
    $path add cascade -label "Other (all encodings)" -menu $other
    return $path
}
proc els::encoding_menu_post {path} {
    if {![winfo exists $path]} { return }
    set canReopen [expr {$::els::active ne "" \
        && [info exists ::els::docPath($::els::active)] \
        && $::els::docPath($::els::active) ne ""}]
    $path entryconfigure "Reopen with Encoding" \
        -state [expr {$canReopen ? "normal" : "disabled"}]
}
proc els::build_enc_picker {path} {
    menu $path -tearoff 0 -postcommand [list els::encoding_menu_post $path]
    $path add cascade -label "Reopen with Encoding" \
        -menu [els::enc_menu $path.re reopen]
    $path add cascade -label "Set Save Encoding" \
        -menu [els::enc_menu $path.sv save]
    return $path
}
proc els::build_enc_popup {} {
    els::build_enc_picker .encpop
}
# ---- context menus (right-click on the text and on tabs) ------------------
# Editor context menu: the Windows-convention right-click Undo/Cut/Copy/Paste/…
# that even Notepad has and els lacked.  Built once, lazily; every command routes
# through the same helpers the Edit menu uses, so no new edit path is created.
# Entry states are computed at post time from the widget's condition.
proc els::build_text_menu {} {
    menu .txtpop -tearoff 0
    .txtpop add command -label Undo  -command els::menu_undo
    .txtpop add command -label Redo  -command els::menu_redo
    .txtpop add separator
    .txtpop add command -label Cut   -command {els::menu_event <<Cut>>}
    .txtpop add command -label Copy  -command {els::menu_event <<Copy>>}
    .txtpop add command -label Paste -command {els::menu_event <<Paste>>}
    .txtpop add separator
    .txtpop add command -label "Select All" -command {els::menu_event <<SelectAll>>}
    .txtpop add separator
    .txtpop add command -label "Find..."      -command {els::find_show find}
    .txtpop add command -label "Go to Line..." -command els::goto_line
    .txtpop add separator
    # file/location items — target the ACTIVE doc at invoke time (the menu is built
    # once and reused), disabled below for an untitled/never-saved document
    .txtpop add command -label "Reload from Disk"       -command els::reload
    .txtpop add command -label "Copy Full Path"         -command {els::tab_copy_path $::els::active}
    .txtpop add command -label "Open Containing Folder" -command {els::tab_reveal $::els::active}
}
proc els::popup_text_menu {w x y} {
    if {$::els::active eq ""} return
    if {![winfo exists .txtpop]} { els::build_text_menu }
    set hasSel   [expr {[llength [$w tag ranges sel]] == 2}]
    set canUndo  [expr {![catch {$w edit canundo} u] && $u}]
    set canRedo  [expr {![catch {$w edit canredo} r] && $r}]
    set canPaste [expr {![catch {clipboard get} cb] && $cb ne ""}]
    set pathed   [expr {[info exists ::els::docPath($::els::active)] && $::els::docPath($::els::active) ne ""}]
    .txtpop entryconfigure Undo  -state [expr {$canUndo  ? "normal" : "disabled"}]
    .txtpop entryconfigure Redo  -state [expr {$canRedo  ? "normal" : "disabled"}]
    .txtpop entryconfigure Cut   -state [expr {$hasSel   ? "normal" : "disabled"}]
    .txtpop entryconfigure Copy  -state [expr {$hasSel   ? "normal" : "disabled"}]
    .txtpop entryconfigure Paste -state [expr {$canPaste ? "normal" : "disabled"}]
    set fstate [expr {$pathed ? "normal" : "disabled"}]
    .txtpop entryconfigure "Reload from Disk"       -state $fstate
    .txtpop entryconfigure "Copy Full Path"         -state $fstate
    .txtpop entryconfigure "Open Containing Folder" -state $fstate
    tk_popup .txtpop $x $y
}
# Tab context menu: Close, plus (for a file-backed tab) Copy Full Path and Open
# Containing Folder.  Rebuilt per-post so it always targets the clicked tab's id.
proc els::popup_tab_menu {id x y} {
    if {$id ni $::els::docs} return
    catch {destroy .tabpop}
    menu .tabpop -tearoff 0
    .tabpop add command -label "Close" -command [list els::close_doc $id]
    set pathed [expr {[info exists ::els::docPath($id)] && $::els::docPath($id) ne ""}]
    set st [expr {$pathed ? "normal" : "disabled"}]
    .tabpop add separator
    .tabpop add command -label "Copy Full Path" -state $st -command [list els::tab_copy_path $id]
    .tabpop add command -label "Open Containing Folder" -state $st -command [list els::tab_reveal $id]
    tk_popup .tabpop $x $y
}
proc els::tab_copy_path {id} {
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} return
    clipboard clear
    clipboard append [file nativename $::els::docPath($id)]
}
# Development-only fallback used when the native helper was not built.  It
# starts Explorer directly with a dedicated argv element — never cmd.exe — and
# refuses comma/equals paths that Explorer's own command grammar mis-parses.
# The packaged product always has win_open_folder and does not use this path.
proc els::folder_fallback_argv {dir} {
    set dir [file nativename $dir]
    if {[string match {*[,=]*} $dir]} { return {} }
    set exp [els::windir explorer.exe]   ;# absolute path: never a planted explorer.exe
    if {$exp ne ""} { return [list $exp $dir] }
    return {}
}
proc els::open_folder_error {dir detail} {
    set msg "Cannot open this folder:\n[els::display_path $dir]"
    if {[string trim $detail] ne ""} { append msg "\n\n[string trim $detail]" }
    els::message_box -parent . -icon error -title els -message $msg
}
proc els::open_folder {dir} {
    if {$dir eq ""} { return 0 }
    set native [file nativename $dir]
    if {[llength [info commands ::els::win_open_folder]]} {
        if {[catch {::els::win_open_folder $native} err]} {
            els::open_folder_error $dir $err
            return 0
        }
        if {$err ne ""} {
            els::open_folder_error $dir $err
            return 0
        }
        return 1
    }
    set argv [els::folder_fallback_argv $dir]
    if {![llength $argv]} {
        els::open_folder_error $dir \
            "Native folder integration is unavailable in this development run."
        return 0
    }
    if {[catch {exec {*}$argv &} err]} {
        els::open_folder_error $dir $err
        return 0
    }
    return 1
}
proc els::tab_reveal {id} {
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} return
    # Open the CONTAINING FOLDER (matching the label and backups_open).  Not
    # `/select,<path>`: Tcl's exec quotes the whole "/select,C:\dir with space\f"
    # token as one argument and explorer ignores /select inside the quotes.
    els::open_folder [file dirname $::els::docPath($id)]
}
proc els::menu_cascade_reserve {menu {depth 1}} {
    if {$depth <= 0 || ![winfo exists $menu]} { return 0 }
    set best 0
    set end [$menu index end]
    if {$end eq "none"} { return 0 }
    for {set i 0} {$i <= $end} {incr i} {
        if {[$menu type $i] ne "cascade"} { continue }
        set sub [$menu entrycget $i -menu]
        if {$sub eq "" || ![winfo exists $sub]} { continue }
        set width [winfo reqwidth $sub]
        set nested [els::menu_cascade_reserve $sub [expr {$depth - 1}]]
        set best [expr {max($best, $width + $nested)}]
    }
    return $best
}
# Post a status-bar picker UPWARD from its indicator, kept inside the main
# window — a downward menu spills below the window's bottom sill (off-screen).
proc els::popup_up {menu widget} {
    update idletasks
    set mw [winfo reqwidth $menu] ; set mh [winfo reqheight $menu]
    set nx [winfo rootx $widget]  ; set ny [expr {[winfo rooty $widget] - $mh}]
    set winl [winfo rootx .] ; set winr [expr {$winl + [winfo width .]}]
    # Reserve room for a cascade submenu only as far as the slack allows: the
    # full reserve used to shove the whole menu far LEFT of its button (the
    # encoding picker's "Other (all)" cascade is wide).  The menu itself stays
    # inside the window; a cascade may overflow it and Tk keeps that on screen.
    set reserve [els::menu_cascade_reserve $menu]
    set slack [expr {$winr - $mw - $nx}]
    if {$reserve > $slack} { set reserve [expr {$slack > 0 ? $slack : 0}] }
    set maxx [expr {$winr - $mw - $reserve}]
    if {$nx > $maxx} { set nx $maxx }
    if {$nx < $winl}           { set nx $winl }
    if {$ny < [winfo rooty .]} { set ny [winfo rooty .] }
    tk_popup $menu $nx $ny
}
proc els::popup_enc_menu {} {
    if {$::els::active eq ""} return
    if {![winfo exists .encpop]} { els::build_enc_popup }
    els::encoding_menu_post .encpop
    els::popup_up .encpop .sb.enc
}
proc els::apply_enc {action enc bom} {
    if {$::els::active eq ""} return
    switch $action {
        reopen { els::reopen_with $enc $bom }
        save   { els::save_with   $enc $bom }
    }
}
proc els::reopen_with {enc bom} {
    set id $::els::active
    if {$::els::docPath($id) eq ""} {
        els::message_box -parent . -icon info -title els \
            -message "Nothing to reopen — this document was never loaded from a file."
        return
    }
    if {[els::doc_dirty $id]} {
        set ans [els::message_box -parent . -icon warning -type yesno -title els \
            -message "Reopen [els::doc_name $id] as [els::enc_label $enc $bom]?\
                      \nUnsaved changes will be lost."]
        if {$ans ne "yes"} return
    }
    set raw $::els::docRaw($id)
    set text [els::decode $raw $enc $bom declossy]
    set eol  [els::detect_eol $text]
    set text [string map [list \r\n \n \r \n] $text]
    set w [els::W $id]
    $w delete 1.0 end
    $w insert end $text
    $w mark set insert 1.0 ; $w see insert
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    set ::els::docEol($id) $eol
    # re-evaluate the lossy-decode flag for the newly chosen encoding
    if {$declossy} { set ::els::docDecodeLossy($id) 1 } else { unset -nocomplain ::els::docDecodeLossy($id) }
    # a NEW encoding voids any earlier "lossy is fine" consent for the old one
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    unset -nocomplain ::els::docExtModPause($id)
    set ::els::docFormatPending($id) 1
    els::cache_saved_sig $id
    $w edit reset
    $w edit modified 0
    els::update_tab $id
    els::settitle
    els::disk_probe $id
    els::refresh_view
}
# External-change (lost-update) prompt: the file changed on disk since we loaded
# or last saved it (R3).  Yes = overwrite the disk version, No = reload from disk
# (discard our edits), Cancel = do nothing.  Routed through tk_messageBox so the
# test harness's counting stub drives it deterministically; a user wanting Save As
# picks Cancel and chooses it from the menu.
proc els::extmod_ask {id} {
    set name [file tail $::els::docPath($id)]
    set ans [els::message_box -parent . -icon warning -type yesnocancel -title els \
        -message "\"$name\" has changed on disk since you opened it." \
        -detail "Yes — save anyway, overwriting the version on disk.\nNo — reload from disk, discarding your edits.\nCancel — do nothing."]
    switch $ans {
        yes { return overwrite }
        no  { return reload }
        default { return cancel }
    }
}
# A target that disappeared or cannot currently be inspected is also an
# external-state conflict.  Recreating/overwriting it is allowed only after an
# explicit foreground decision; background auto-save always pauses instead.
proc els::extstate_ask {id state detail} {
    set name [file tail $::els::docPath($id)]
    if {$state eq "missing"} {
        set message "\"$name\" has been removed since you opened it."
        set action "Yes - recreate it from this buffer.\nNo - do nothing."
    } else {
        set message "\"$name\" cannot currently be read or inspected."
        set action "Yes - try to overwrite it from this buffer.\nNo - do nothing."
    }
    if {$detail ne ""} { append action "\n\nSystem detail: $detail" }
    return [expr {[els::message_box -parent . -icon warning -type yesno -title els \
        -message $message -detail $action] eq "yes"}]
}
# Opening with the wrong encoding can substitute U+FFFD for source bytes.  A
# dirty save would make those replacements permanent, so require separate,
# explicit consent even when every resulting character is encodable.
proc els::decode_lossy_ask {id} {
    set name [els::doc_name $id]
    return [expr {[els::message_box -parent . -icon warning -type yesno -title els \
        -message "\"$name\" contains replacement characters from decoding errors." \
        -detail "Saving will make those replacements permanent and the original bytes cannot be recovered from this file.\n\nYes - save anyway.\nNo - cancel; use Reopen with Encoding or Save As instead."] eq "yes"}]
}
# One binary reader for document reloads, opens, and backups.  Keep the channel
# lifecycle here so an error from fconfigure/read can never strand an open file
# handle (on Windows that can also make a later atomic replace fail).
proc els::_read_binary_channel {fh} {
    fconfigure $fh -translation binary
    set out ""
    while {1} {
        set chunk [read $fh $::els::IO_CHUNK]
        append out $chunk
        if {[eof $fh]} { break }
    }
    return $out
}
proc els::_read_binary_prefix {fh limit} {
    fconfigure $fh -translation binary
    set out ""
    set remaining [expr {$limit + 1}]
    while {$remaining > 0} {
        set want [expr {min($remaining, $::els::IO_CHUNK)}]
        set chunk [read $fh $want]
        append out $chunk
        incr remaining -[string length $chunk]
        if {[eof $fh]} { break }
    }
    return $out
}
proc els::read_binary_file {path} {
    set fh [::open $path r]
    try {
        return [els::_read_binary_channel $fh]
    } finally {
        # Preserve the read/configuration error if closing also happens to fail.
        catch {close $fh}
    }
}
proc els::read_preflight_size {path} { return [file size $path] }
# Read no more than OPEN_WARN_SIZE+1 bytes before the large-file decision.  The
# decision and (when accepted) the remaining uncapped aggregate read use the SAME channel,
# closing the old stat/read race where a small file could grow after the size
# check and then be loaded without consent.  Returns a dict with state ok,
# deferred, cancelled, or failed; I/O errors still raise to the caller.
proc els::read_binary_guarded {path quiet consent} {
    # Quiet startup/session work must not touch an offline share before
    # the UI is usable.  Persist it locally; explicit Deferred Open is consent
    # for the potentially blocking network operation.
    if {$quiet && !$consent && [els::remote_path $path]} {
        set existed [els::deferred_contains $path]
        if {$existed || [els::deferred_add $path]} {
            return [dict create state deferred new [expr {!$existed}] reason remote]
        }
        return [dict create state failed error "the deferred-open list could not be saved"]
    }
    # A cheap pre-stat avoids reading 25 MiB merely to ask an already-known
    # question.  Do it before opening the channel so a user can leave the prompt
    # up without pinning a replaceable Windows file handle.
    if {!$consent && ![catch {els::read_preflight_size $path} knownSize] && \
            $knownSize > $::els::OPEN_WARN_SIZE} {
        if {$quiet} {
            set existed [els::deferred_contains $path]
            if {$existed || [els::deferred_add $path]} {
                return [dict create state deferred new [expr {!$existed}] reason large]
            }
            return [dict create state failed error "the deferred-open list could not be saved"]
        }
        set mb [expr {max(1, int(ceil($::els::OPEN_WARN_SIZE / 1048576.0)))}]
        set ans [els::message_box -parent . -icon warning -type yesno -title els \
            -message "\"[file tail $path]\" is larger than $mb MB.\nOpening it may take a while and use a lot of memory. Open it anyway?"]
        if {$ans ne "yes"} { return [dict create state cancelled] }
        set consent 1
    }
    set fh [::open $path r]
    try {
        set prefix [els::_read_binary_prefix $fh $::els::OPEN_WARN_SIZE]
        if {[string length $prefix] <= $::els::OPEN_WARN_SIZE} {
            return [dict create state ok bytes $prefix]
        }
        if {!$consent} {
            if {$quiet} {
                set existed [els::deferred_contains $path]
                if {$existed || [els::deferred_add $path]} {
                    return [dict create state deferred new [expr {!$existed}] reason large]
                }
                return [dict create state failed error "the deferred-open list could not be saved"]
            }
            set mb [expr {max(1, int(ceil($::els::OPEN_WARN_SIZE / 1048576.0)))}]
            set ans [els::message_box -parent . -icon warning -type yesno -title els \
                -message "\"[file tail $path]\" is larger than $mb MB.\nOpening it may take a while and use a lot of memory. Open it anyway?"]
            if {$ans ne "yes"} { return [dict create state cancelled] }
        }
        # Explicit consent removes the guard entirely; do not impose a hidden
        # second ceiling.  Continue from the already-open channel.
        append prefix [els::_read_binary_channel $fh]
        return [dict create state ok bytes $prefix]
    } finally {
        catch {close $fh}
    }
}
# Re-read a document's file FRESH from disk (unlike reopen_with, which re-decodes
# the cached bytes) and replace the buffer, re-detecting encoding/EOL.  Resets the
# doc to clean and re-caches the on-disk signature (so the R3 baseline matches
# disk again).  This is the Reload branch of the external-change prompt and of
# File ▸ Reload from Disk.
proc els::reload_from_disk {id {quiet 0} {largeConsent 0}} {
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} { return 0 }
    set p $::els::docPath($id)
    if {[catch {
        set readResult [els::read_binary_guarded $p $quiet $largeConsent]
    } err]} {
        els::disk_probe $id
        if {$quiet} {
            catch {els::log error "quiet reload failed for $p: $err"}
            catch {els::status_note "file was not reloaded: [file tail $p]"}
        } else {
            els::message_box -parent . -icon error -title els -message "Cannot reload file:\n$err"
        }
        return 0
    }
    set readState [dict get $readResult state]
    if {$readState ne "ok"} {
        if {$readState eq "failed"} {
            set err [dict get $readResult error]
            catch {els::log error "quiet reload failed for $p: $err"}
            catch {els::status_note "file was not reloaded: [file tail $p]"}
        } elseif {$readState eq "deferred" && [dict get $readResult new]} {
            set what [expr {([dict exists $readResult reason] && [dict get $readResult reason] eq "remote") \
                ? "network reload deferred" : "large reload deferred"}]
            catch {els::status_note "$what - use File > Deferred Opens..."}
        }
        return 0
    }
    set raw [dict get $readResult bytes]
    set w [els::W $id]
    lassign [els::detect_encoding $raw] enc bom
    set text [els::decode $raw $enc $bom declossy]
    set eol  [els::detect_eol $text]
    set text [string map [list \r\n \n \r \n] $text]
    set ins [$w index insert]
    $w delete 1.0 end
    $w insert end $text
    catch {$w mark set insert $ins}   ;# keep the caret line where it can still land
    $w see insert
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    set ::els::docEol($id) $eol
    set ::els::docRaw($id) $raw
    # re-reading disk can newly introduce (or clear) U+FFFD substitutions -> refresh
    # the decode-lossy marker just as open/reopen_with do (always interactive here)
    if {$declossy} { set ::els::docDecodeLossy($id) 1 } else { unset -nocomplain ::els::docDecodeLossy($id) }
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id) \
        ::els::docExtModPause($id) ::els::docFormatPending($id)
    els::cache_saved_sig $id
    $w edit reset
    $w edit modified 0
    els::update_tab $id
    els::settitle
    els::disk_probe $id
    els::refresh_view
    return 1
}
# File ▸ Reload from Disk: re-read the active document from disk, confirming first
# if there are unsaved edits.  Nothing re-reads disk otherwise (Reopen with
# Encoding deliberately re-decodes the cached bytes).
proc els::reload {} {
    set id $::els::active
    if {$id eq "" || ![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} {
        els::message_box -parent . -icon info -title els \
            -message "Nothing to reload — this document was never loaded from a file."
        return
    }
    if {[els::doc_dirty $id]} {
        set ans [els::message_box -parent . -icon warning -type yesno -title els \
            -message "Reload [els::doc_name $id] from disk?\nUnsaved changes will be lost."]
        if {$ans ne "yes"} return
    }
    els::reload_from_disk $id
}
proc els::save_with {enc bom} {
    set id $::els::active
    if {$id eq ""} { return }
    if {$::els::docEnc($id) eq $enc && $::els::docBom($id) == $bom} { return }
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    # a NEW encoding voids any earlier "lossy is fine" consent for the old one
    unset -nocomplain ::els::docLossyOk($id) ::els::docLossyPause($id)
    [els::W $id] edit modified 1
    els::update_tab $id
    els::settitle
}
proc els::eol_menu {path} {
    menu $path -tearoff 0
    foreach {lbl v} {"LF (Unix / macOS)" lf "CRLF (Windows)" crlf "CR (classic Mac)" cr} {
        $path add command -label $lbl -command [list els::set_eol $v]
    }
    return $path
}
proc els::build_eol_popup {} {
    els::eol_menu .eolpop
}
proc els::popup_eol_menu {} {
    if {$::els::active eq ""} return
    if {![winfo exists .eolpop]} { els::build_eol_popup }
    els::popup_up .eolpop .sb.eol
}
proc els::set_eol {v} {
    set id $::els::active
    if {$id eq "" || $::els::docEol($id) eq $v} return
    set ::els::docEol($id) $v
    [els::W $id] edit modified 1   ;# make the change saveable
    els::update_tab $id
    els::settitle
}

# ---- file operations ----------------------------------------------------
# Filters for the Open / Save dialogs.  Text files are first so .txt is the
# default type, while All files remains available for extensionless or unusual
# names.
proc els::filetypes {} {
    return {
        {{Text}           {.txt}}
        {{All files}      *}
        {{Tcl}            {.tcl}}
        {{C / C++}        {.c .h .cpp .hpp .cc}}
        {{Web}            {.html .htm .css .js .json .xml}}
        {{Shell / config} {.sh .ini .conf .cfg .toml .yml .yaml}}
    }
}
proc els::new {} {
    els::new_doc
}
proc els::open_quiet_failure {path err} {
    catch {els::log error "quiet open failed for $path: $err"}
    catch {els::status_note "file not opened: [file tail $path]"}
}
# A launch-file argument that failed to open is the user's own deliberate action
# (a double-click / "Open with els"), not a background timer, so it earns a real
# modal -- but only after the window is mapped (els::main defers this via `after`),
# never during pre-UI startup.  A transient status note that clears in 4s would
# otherwise leave an unexplained empty editor and no reason (R12).
proc els::report_launch_failures {paths} {
    if {![llength $paths]} { return }
    set names {}
    foreach p $paths { lappend names [file tail $p] }
    set n [llength $paths]
    set head [expr {$n == 1 ? "Could not open this file:" : "Could not open these $n files:"}]
    els::message_box -parent . -icon error -title els \
        -message "$head\n[join $names \n]\n\nSee els.log for details."
}
proc els::open {{p ""} {quiet 0} {noRecent 0} {largeConsent 0}} {
    set ::els::last_open_outcome cancelled
    if {$p eq ""} {
        set suspendToken [els::suspend_acquire]
        try {
            set p [tk_getOpenFile -parent . -filetypes [els::filetypes]]
        } finally {
            els::suspend_release $suspendToken
        }
        if {$p eq ""} { return "" }
    }
    if {![els::remote_path $p] && ![catch {file normalize $p} np]} { set p $np }
    variable active
    variable docPath
    foreach id $::els::docs {
        if {[info exists docPath($id)] && [els::same_path $docPath($id) $p]} {
            els::switch_to $id
            if {!$noRecent} { els::recent_add $p }
            els::deferred_remove_many [list $p]
            set ::els::last_open_outcome already
            return $id
        }
    }
    # Large-file guard: the whole file is read, decoded, and held ~4x in RAM with no
    # way to cancel, so a mis-dropped multi-hundred-MB file wedges the editor.  Warn
    # before the read on an interactive open — and BEFORE creating a tab, so a "no"
    # leaves no stray buffer.  A quiet startup/session path MUST NOT make
    # that memory decision itself or post a modal from a timer: persist the path in
    # Deferred Opens instead.  largeConsent is set only by that dialog's explicit
    # Open selected action; once consented there is deliberately no absolute cap.
    # The guard reads at most threshold+1 from the actual open channel.  A file
    # that grows after a stat can no longer slip into an unbounded read.
    catch {. configure -cursor watch} ; update idletasks
    set readRc [catch {set readResult [els::read_binary_guarded $p $quiet $largeConsent]} readErr]
    if {$readRc} {
        catch {. configure -cursor ""}
        set ::els::last_open_outcome failed
        if {$quiet} {
            els::open_quiet_failure $p $readErr
        } else {
            els::message_box -parent . -icon error -title els -message "Cannot open file:\n$readErr"
        }
        return ""
    }
    set readState [dict get $readResult state]
    if {$readState ne "ok"} {
        catch {. configure -cursor ""}
        switch $readState {
            deferred {
                set ::els::last_open_outcome deferred
                if {[dict get $readResult new]} {
                    set what [expr {([dict exists $readResult reason] && [dict get $readResult reason] eq "remote") \
                        ? "network file deferred" : "large file deferred"}]
                    catch {els::status_note "$what - use File > Deferred Opens..."}
                }
            }
            failed {
                set ::els::last_open_outcome failed
                els::open_quiet_failure $p [dict get $readResult error]
            }
            default { set ::els::last_open_outcome cancelled }
        }
        return ""
    }
    set prevActive $active
    set created 0
    set id ""
    set w ""
    # a big read/decode/insert blocks the single-threaded UI — show a busy cursor so
    # the freeze reads as "working", not "hung".  Read AND decode/insert are in ONE
    # catch (both can throw — e.g. an out-of-memory on a huge file, the very case
    # this feature guards) and the cursor is cleared UNCONDITIONALLY after it, so no
    # exit path — including an uncaught throw on the quiet session-restore path —
    # can strand a watch cursor on the whole app.
    set rc [catch {
        set raw [dict get $readResult bytes]
        # detect encoding + EOL, decode, normalise the buffer to LF internally
        lassign [els::detect_encoding $raw] enc bom
        set text [els::decode $raw $enc $bom declossy]
        set eol [els::detect_eol $text]
        set text [string map [list \r\n \n \r \n] $text]
        if {[els::pristine $active]} {
            set id $active
        } else {
            set id [els::new_doc]
            set created 1
        }
        set w [els::W $id]
        $w delete 1.0 end
        $w insert end $text
    } err]
    catch {. configure -cursor ""}
    if {$rc} {
        set ::els::last_open_outcome failed
        if {!$quiet} {
            els::message_box -parent . -icon error -title els -message "Cannot open file:\n$err"
        } else {
            els::open_quiet_failure $p $err
        }
        # discard only a doc WE created for this open — a reused pre-existing pristine
        # tab is the user's, so just clear any partial insert back to empty; and
        # return focus to the tab that was active before (close_doc's neighbor pick
        # lands on an arbitrary one)
        if {$created && $id ne "" && [llength $::els::docs] > 1} {
            els::close_doc $id
        } elseif {$w ne ""} {
            catch {$w delete 1.0 end ; $w edit reset ; $w edit modified 0}
        }
        if {$prevActive ne "" && $prevActive in $::els::docs} {
            els::switch_to $prevActive
        }
        return ""
    }
    $w mark set insert 1.0
    $w see insert
    set docPath($id) $p
    set ::els::docEnc($id) $enc
    set ::els::docBom($id) $bom
    set ::els::docEol($id) $eol
    set ::els::docRaw($id) $raw
    els::cache_saved_sig $id
    # flag a lossy decode (U+FFFD substituted for bytes the encoding can't hold): the
    # user sees the replacement chars in the buffer but might not realise they are
    # decode artifacts and save over the original.  A durable tab marker plus, on an
    # interactive open, one status note point them at Reopen with Encoding.
    if {$declossy} {
        set ::els::docDecodeLossy($id) 1
        if {!$quiet} {
            els::status_note "decoded with replacement characters — try Reopen with Encoding"
        }
    } else {
        unset -nocomplain ::els::docDecodeLossy($id)
    }
    $w edit reset
    $w edit modified 0
    els::switch_to $id
    els::update_tab $id
    els::settitle
    els::refresh_view
    if {!$noRecent} { els::recent_add $p }
    els::deferred_remove_many [list $p]
    set ::els::last_open_outcome opened
    return $id
}
# Emit the bytes to the (temp) save channel.  A one-line seam so a test can force
# a mid-write failure and prove the atomic temp never touches the real file.
proc els::_save_emit {chan bytes} {
    puts -nonewline $chan $bytes
}
# Atomically replace $path's contents with $bytes: write a same-directory temp,
# then rename it over the target.  On Windows `file rename -force` is a single
# MoveFileEx(REPLACE_EXISTING) — atomic on the same NTFS volume — so a crash,
# disk-full, or I/O error mid-write can NEVER truncate or corrupt the existing
# file (the old in-place `open w` truncated it the instant it opened).  Returns
# "" on success, else an error message.  A temp-write failure cleans up its
# incomplete temp; an atomic-replace failure retains the complete temp and leaves
# the original intact.  Refuses a read-only target, matching the old behavior.
#
# Metadata: the native build prefers Win32 ReplaceFileW (src/winfs.c,
# els::win_replace_file), which normally carries the target's ACLs, alternate
# data streams (e.g. the mark-of-the-web), and attributes.  Merge errors are
# deliberately best-effort so content replacement stays atomic; in that rare
# case some metadata may not carry.  When the command is absent (a dev/tclsh run)
# the plain `file rename -force` below is used, which does not carry those.  A
# >260-char or locked target may fail to save, but never falls back to truncating
# the target in place.
proc els::_durable_flush {path durable} {
    if {!$durable || ![llength [info commands ::els::win_fsync]]} { return "" }
    if {[catch {els::win_fsync [file nativename $path]} err]} {
        return "DURABILITY: $err"
    }
    if {$err ne ""} { return "DURABILITY: $err" }
    return ""
}
proc els::_atomic_rename {from to} {
    file rename -force $from $to
}
proc els::write_atomic {path bytes {tmpHint ""} {durable 0}} {
    # `file rename -force $tmp $path` treats an existing directory as a
    # destination container, moving the temp *inside* it and reporting success.
    # A save target is always a file: reject directories before creating a temp.
    if {[file isdirectory $path]} {
        return "the target is a directory"
    }
    if {[file exists $path] && ![catch {file attributes $path -readonly} ro] && $ro} {
        return "the file is read-only"
    }
    # A caller-supplied temp name lets a distinct writer (the deferred-opens queue)
    # avoid colliding on a shared [clock clicks]; saves use the default per-pid name.
    set tmp [file join [file dirname $path] \
                 [expr {$tmpHint ne "" ? $tmpHint \
                        : [format ".els-save-%d-%d.tmp" [pid] [clock clicks]]}]]
    set fh ""
    if {[catch {
        set fh [::open $tmp {WRONLY CREAT TRUNC}]
        fconfigure $fh -translation binary
        els::_save_emit $fh $bytes
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        catch {file delete -force $tmp}
        return $e   ;# temp write failed; original untouched — do NOT fall back to
                    ;# an in-place truncate (it could also fail and lose the file)
    }
    # Durability model (SAVE-ONLY — only els::save passes durable; config/backups
    # skip it, a forced flush being too costly to justify for those).  The load-bearing
    # flush is on the FINAL TARGET AFTER it holds the new content: FlushFileBuffers(target)
    # forces the file's data AND the rename metadata (the name->data binding) to the platter.
    # NTFS journaling only guarantees post-crash CONSISTENCY, not that the replace is
    # PERSISTED when the call returns — so without this a power cut just after the replace
    # can roll the name back to the OLD data (the new, temp-flushed bytes then being an
    # orphaned extent).  Flush is native-only.  A requested flush failure is a save
    # failure: the target may hold the new bytes, but the tab stays dirty so the user
    # knows the save did not durably complete.
    # Prefer ReplaceFileW (native build, src/winfs.c) when replacing an existing
    # file: atomic, with best-effort merging of the target's ACLs, alternate data
    # streams (mark-of-the-web), and attributes — which a rename-replace drops.
    if {[file exists $path] && [llength [info commands ::els::win_replace_file]]} {
        if {![catch {els::win_replace_file [file nativename $path] [file nativename $tmp]} replaceErr] \
                && $replaceErr eq ""} {
            return [els::_durable_flush $path $durable]
        }
        # ReplaceFileW failed — fall through; the temp is still present.
    }
    if {![catch {els::_atomic_rename $tmp $path} renameErr]} {
        return [els::_durable_flush $path $durable]
    }
    # Neither atomic operation worked (long path, lock, ACL, device error...).
    # The complete temp is the rescue copy; never risk the target with open/TRUNC.
    return "atomic replacement failed: $renameErr\n(a complete copy of the new content is safe at: $tmp)"
}
# Legacy helper retained for compatibility with older tests/extensions.  The
# save path deliberately never calls it.
proc els::_write_inplace {path bytes} {
    set fh ""
    if {[catch {
        set fh [::open $path {WRONLY CREAT TRUNC}]
        fconfigure $fh -translation binary
        els::_save_emit $fh $bytes
        close $fh
        set fh ""
    } e]} {
        if {$fh ne ""} { catch {close $fh} }
        return $e
    }
    return ""
}

# ===========================================================================
#  AUTOSAVE + CHANGE DETECTION (R2/R3)
#  ---------------------------------------------------------------------------
#  0.95 keeps NO crash-recovery snapshot of unsaved buffers: on a crash or power
#  loss, text that was never saved -- by the user or by autosave -- is gone, as
#  in a plain editor.  What lives here instead: a per-run session identity, the
#  on-disk file signatures that drive external-change detection, and OPT-IN
#  autosave, which writes the user's REAL file through els::save (never a hidden
#  sidecar).  On-disk safety is atomic saves + the backup ring, nothing more.
# ===========================================================================

# ---- session identity ----------------------------------------------------
# A per-run id "host-pid-token".  pid disambiguates concurrent instances; the
# token (folded from microseconds/clicks/pid/rand) disambiguates a pid reused
# across runs.  Memoized so one run keeps a single stable id (it names the
# isolated find-worker job dirs and their snapshot files).
proc els::host_tag {} {
    set h ""
    catch {set h [string tolower [info hostname]]}
    regsub -all {[^a-z0-9_]} $h _ h
    if {$h eq ""} { set h unknown }
    return $h
}
proc els::session_token {} {
    if {$::els::session_token_cached ne ""} { return $::els::session_token_cached }
    set seed "[clock microseconds]:[clock clicks]:[pid]:[info hostname]"
    for {set i 0} {$i < 4} {incr i} { append seed ":[expr {int(rand()*0x7fffffff)}]" }
    set ::els::session_token_cached \
        [format %08x%08x [zlib crc32 $seed] [zlib crc32 "salt:$seed:[clock clicks]"]]
    return $::els::session_token_cached
}
proc els::session_id {} {
    if {$::els::session_id_cached ne ""} { return $::els::session_id_cached }
    set ::els::session_id_cached "[els::host_tag]-[pid]-[els::session_token]"
    return $::els::session_id_cached
}

# ---- change-detection + on-disk file signatures --------------------------
# A signature of on-disk bytes "size:mtime:crc", used to detect a third party
# changing a file els has open (the external-change guard).  CRC covers every byte.
proc els::sig_from_bytes {bytes mtime} {
    set size [string length $bytes]
    return "$size:$mtime:[zlib crc32 $bytes]"
}
proc els::file_sig_probe {path} {
    if {[catch {file stat $path st} err opts]} {
        set code {}
        if {[dict exists $opts -errorcode]} { set code [dict get $opts -errorcode] }
        set posix [lindex $code 1]
        set state [expr {$posix in {ENOENT ENOTDIR} ? "missing" : "unreadable"}]
        return [dict create state $state error $err]
    }
    # Single open + guaranteed close.  Keep missing distinct from permission,
    # sharing and I/O failures so save can ask the right explicit question.
    set fh ""
    set sig ""
    try {
        set fh [::open $path rb]
        fconfigure $fh -translation binary
        set crc 0
        set size 0
        while {1} {
            set chunk [read $fh 1048576]
            if {$chunk ne ""} {
                incr size [string length $chunk]
                set crc [zlib crc32 $chunk $crc]
            }
            if {[eof $fh]} { break }
        }
        file stat $path final
        if {$st(size) != $final(size) || $st(mtime) != $final(mtime) || $size != $final(size)} {
            error "file changed while its signature was being read"
        }
        set sig "$size:$final(mtime):$crc"
    } on error {err opts} {
        return [dict create state unreadable error $err]
    } finally {
        if {$fh ne ""} { catch {close $fh} }
    }
    return [dict create state ok sig $sig]
}
proc els::file_sig {path} {
    set probe [els::file_sig_probe $path]
    if {[dict get $probe state] ne "ok"} { return "" }
    return [dict get $probe sig]
}
# Cache the doc's on-disk signature from the bytes we already hold (the exact
# loaded/saved bytes) plus the file's mtime -- one consistent source.
proc els::cache_saved_sig {id} {
    els::disk_probe_reset $id
    if {$::els::docPath($id) eq ""} {
        set ::els::savedSig($id) ""
        unset -nocomplain ::els::savedSigPath($id)
        return
    }
    set mtime 0
    catch {set mtime [file mtime $::els::docPath($id)]}
    set ::els::savedSig($id) [els::sig_from_bytes $::els::docRaw($id) $mtime]
    set ::els::savedSigPath($id) $::els::docPath($id)   ;# pin the R3 baseline to this path
}
proc els::doc_saved_sig {id} {
    if {[info exists ::els::savedSig($id)]} { return $::els::savedSig($id) }
    return ""
}
# The CONTENT part of a "size:mtime:crc" signature.  Since every CRC covers the
# full byte stream, volatile mtime is always dropped: byte-identical sync/AV
# rewrites do not false-positive, while same-size middle rewrites remain visible.
# Callers that also care about mtime compare the full signature directly.
proc els::sig_content {sig} {
    set p [split $sig :]
    if {[llength $p] != 3} { return $sig }
    return "[lindex $p 0]:[lindex $p 2]"
}

proc els::raise_window {} {
    catch {wm deiconify .}
    catch {raise .}
    # a brief topmost flip reliably pulls the window to the foreground on Windows
    catch {wm attributes . -topmost 1}
    after 250 {catch {wm attributes . -topmost [expr {$::els::always_on_top ? 1 : 0}]}}
    catch {focus -force .}
}
# Explorer drag-and-drop.  The native windrop helper (src/windrop.c) queues a Tcl
# event per drop that calls this with the list of dropped paths; open each as a tab
# and raise els to the front (the user dropped ONTO our window and expects it
# focused).  Directories and vanished paths are skipped.  Unlike a quiet
# startup/session open, opens here are INTERACTIVE: a deliberate drop should surface
# the large-file guard and any open error.  A native drop event can still arrive while another
# decision surface owns the event loop, so retain it until that guard closes.
proc els::drop_open {paths} {
    if {$::els::swap_suspend} {
        lappend ::els::drop_pending {*}$paths
        if {$::els::drop_after eq ""} {
            set ::els::drop_after [after 50 els::drop_resume]
        }
        return
    }
    if {[llength $::els::drop_pending]} {
        set paths [concat $::els::drop_pending $paths]
        set ::els::drop_pending {}
        if {$::els::drop_after ne ""} { after cancel $::els::drop_after }
        set ::els::drop_after ""
    }
    set opened 0
    foreach p $paths {
        if {$p eq "" || [file isdirectory $p] || ![file exists $p]} { continue }
        if {[els::open $p] ne ""} { set opened 1 }
    }
    if {$opened} { els::raise_window }
}
proc els::drop_resume {} {
    set ::els::drop_after ""
    if {![llength $::els::drop_pending]} { return }
    set paths $::els::drop_pending
    set ::els::drop_pending {}
    els::drop_open $paths
}
# Make a Tk window a native file drop target.  A no-op where the native helper is
# absent (a dev tclsh run, or a build without windrop) — drag-drop is then simply
# unavailable, and every other path still works.
proc els::drop_register {w} {
    if {[llength [info commands ::els::win_drop_register]] == 0} { return }
    catch {els::win_drop_register [winfo id $w]}
}
# ---- maintenance sweep ----------------------------------------------------
# Age out previous-version backups, and reap any dead sidecar state left by a
# pre-0.95 install: crash-recovery swaps and single-instance locks/handoff were
# removed in 0.95, so the whole swap/ and handoff/ trees next to els.conf are
# obsolete.  Best-effort; never raises.
proc els::maintenance_sweep {} {
    if {$::els::config_path eq "" || $::els::selftest} { return }
    set root [file dirname $::els::config_path]
    catch {
        foreach dead {swap handoff} { catch {file delete -force [file join $root $dead]} }
        set now [clock seconds]
        set bd [file join $root backups]
        foreach f [glob -nocomplain -directory $bd *.bak] {
            if {![catch {file mtime $f} mt] && ($now - $mt) > $::els::BK_MAXAGE} {
                catch {file delete -force $f}
            }
        }
    }
}
# ---- startup: maintenance sweep + session restore -------------------------
proc els::session_boot {openedArgs} {
    set ::els::session_boot_after ""
    if {$::els::swap_suspend} {
        set ::els::session_boot_after [after 50 [list els::session_boot $openedArgs]]
        return
    }
    catch {els::maintenance_sweep}
    if {!$openedArgs} {
        # a plain start owns the stored session from here on (whether or not
        # restoring is enabled or anything was restorable)
        set ::els::session_owned 1
        if {$::els::restore_session} { catch {els::session_restore} }
    }
}
# ---- lossy-save guard ----------------------------------------------------
# A save must never silently drop characters the document's encoding cannot
# represent.  Strict encoding via -failindex detects the first unencodable
# character without throwing; the user then chooses: switch the document to
# UTF-8 (keeps everything), save anyway with replacement characters (latched
# per document for the session), or cancel (nothing is written).

# True iff $text saves FAITHFULLY in $enc: it encodes AND decodes back to the
# identical characters.  A plain -failindex check only sees the first case (an
# unencodable character); it is blind to the cp932/euc-jp "duplicate mapping"
# case where a character encodes to bytes that decode as a DIFFERENT character
# (U+2212 MINUS -> the bytes for U+FF0D, etc.), so reopening would silently show
# text the user never wrote.  This round-trips instead, catching both.
proc els::enc_faithful {enc text} {
    if {[catch {encoding convertto -profile strict $enc $text} b]} { return 0 }
    return [expr {[encoding convertfrom $enc $b] eq $text}]
}
# First character index that would NOT save faithfully (see enc_faithful), by
# binary search on the longest faithful prefix.  We deliberately do NOT use the
# -failindex VALUE as a position: in Tcl 9.0.3 it is a character index for some
# encodings but a byte index into the internal UTF-8 representation for others
# (e.g. gb2312-raw), contradicting encoding(n) — and it cannot see round-trip
# loss at all.  Called only when the whole text is already known to be lossy.
proc els::lossy_first {enc text} {
    set lo 0 ; set hi [string length $text]
    # invariant: the prefix of length lo is faithful, the one of hi is not
    while {$lo + 1 < $hi} {
        set mid [expr {($lo + $hi) / 2}]
        if {[els::enc_faithful $enc [string range $text 0 [expr {$mid - 1}]]]} {
            set lo $mid
        } else {
            set hi $mid
        }
    }
    return [expr {$hi - 1}]
}

# Where and how big is the damage: line/col + codepoint of the first
# unencodable character, and how many there are.  The count walks per
# character from the first failure, capped (100 failures / 10000 chars) --
# it is dialog garnish, not bookkeeping.
proc els::lossy_describe {enc text} {
    set fi [els::lossy_first $enc $text]
    set before [string range $text 0 [expr {$fi - 1}]]
    set line [expr {1 + [regexp -all {\n} $before]}]
    set col  [expr {$fi - [string last \n $before]}]
    set uhex [format %04X [scan [string index $text $fi] %c]]
    set count 0
    set n [string length $text]
    set stop [expr {min($n, $fi + 10000)}]
    for {set i $fi} {$i < $stop && $count < 100} {incr i} {
        if {![els::enc_faithful $enc [string index $text $i]]} { incr count }
    }
    return [list $line $col $uhex $count]
}

# Modal three-way choice (utf8 | lossy | cancel).  The test suite replaces
# this proc with a canned-answer stub, like the native dialogs.
# The save actions the lossy dialog offers for a failing encoding.  When the
# encoding is ALREADY utf-8 (an unpaired surrogate the Tk widget holds), the
# "Save as UTF-8" action is a lie: its branch encodes with -profile replace, so
# it substitutes U+FFFD exactly like "Save anyway" -- it does NOT keep the
# character.  Omit it there so the dialog never presents two identical actions
# with contradictory labels (F22).
proc els::lossy_actions {enc} {
    if {$enc eq "utf-8"} { return {lossy cancel} }
    return {utf8 lossy cancel}
}
proc els::lossy_ask {id enc line col uhex count} {
    set top .lossy
    catch {destroy $top}
    toplevel $top -background $::els::PAGE
    wm withdraw $top
    wm title $top els
    wm transient $top .
    set countTxt [expr {$count >= 100 ? "100 or more" : $count}]
    set noun [expr {$count == 1 ? "character" : "characters"}]
    set actions [els::lossy_actions $enc]
    if {"utf8" in $actions} {
        set choice "Save as UTF-8 to keep every character, save anyway to replace\nthe unsupported ones with substitutes, or cancel."
    } else {
        set choice "Save anyway to replace the unsupported [expr {$count == 1 ? {character} : {characters}}] with a\nsubstitute, or cancel."
    }
    ttk::label $top.msg -justify left -text \
"This document contains $countTxt $noun that cannot be written
as [els::enc_label $enc 0] (first at line $line, column $col: U+$uhex).

$choice"
    ttk::frame $top.b
    set btns {}
    if {"utf8" in $actions} {
        ttk::button $top.b.utf8 -text "Save as UTF-8" -default active \
            -command {set ::els::lossy_answer utf8}
        lappend btns $top.b.utf8
    }
    ttk::button $top.b.lossy  -text "Save anyway" -command {set ::els::lossy_answer lossy}
    ttk::button $top.b.cancel -text Cancel        -command {set ::els::lossy_answer cancel}
    if {"utf8" ni $actions} { $top.b.cancel configure -default active }
    lappend btns $top.b.lossy $top.b.cancel
    pack {*}$btns -side left -padx 4
    pack $top.msg -padx 16 -pady {14 10}
    pack $top.b   -padx 16 -pady {0 12}
    wm protocol $top WM_DELETE_WINDOW {set ::els::lossy_answer cancel}
    bind $top <Escape> {set ::els::lossy_answer cancel}
    # Tk 9's TButton binds only <Key-space>, so the -default active button (which we
    # also focus below) ignores Enter -- the Windows-standard accept key.  Bind it on
    # the toplevel to the same answer the default button carries (R21).
    set enterAns [expr {"utf8" in $actions ? "utf8" : "cancel"}]
    bind $top <Return>   [list set ::els::lossy_answer $enterAns]
    bind $top <KP_Enter> [list set ::els::lossy_answer $enterAns]
    set suspendToken [els::suspend_acquire]
    try {
        update idletasks
        set x [expr {[winfo rootx .] + ([winfo width .] - [winfo reqwidth $top]) / 2}]
        set y [expr {[winfo rooty .] + 120}]
        wm geometry $top +$x+$y
        if {$::els::probe_quiet} { catch {wm attributes $top -alpha 0.0} }
        wm deiconify $top
        raise $top
        if {"utf8" in $actions} { focus $top.b.utf8 } else { focus $top.b.cancel }
        grab $top
        set ::els::lossy_answer ""
        vwait ::els::lossy_answer
        set ans $::els::lossy_answer
    } finally {
        catch {grab release $top}
        catch {destroy $top}
        els::suspend_release $suspendToken
    }
    if {$ans ni {utf8 lossy cancel}} { set ans cancel }
    return $ans
}

# A transient, quiet status message in the name slot (never a dialog) -- used
# by auto-save for failures.  The next update_namelabel restores the path.
proc els::status_note {msg} {
    if {![winfo exists .sb.name]} { return }
    catch {after cancel $::els::status_note_after}
    .sb.name configure -text $msg
    # while the timer is pending, update_namelabel leaves the note alone (a
    # successful save calls settitle right after, which must not clobber it)
    set ::els::status_note_after [after 4000 els::status_note_clear]
}
proc els::status_note_clear {} {
    set ::els::status_note_after ""
    catch {els::update_namelabel}
}

# ---- backups: previous versions ---------------------------------------------
# Every save that OVERWRITES an existing file first preserves that file's
# current content in <configdir>/backups/ (next to els.conf, hence next to the
# exe in a packaged run).  Bounded: a ring of BK_RING versions per
# file, a new backup is skipped while the newest is younger than BK_MININT
# seconds (so an auto-save burst keeps the pre-burst version instead of
# churning), files over BK_MAXSIZE are not backed up, and anything older than
# BK_MAXAGE is pruned by the periodic sweep.  Best-effort by design: a failing
# backup notes itself in the statusbar and never blocks the save.
proc els::backup_dir {} {
    if {$::els::config_path eq "" || $::els::selftest} { return "" }
    return [file join [file dirname $::els::config_path] backups]
}
# Stable per-file ring key: the filename stays human-readable, a hash of the
# full (case-folded) path keeps same-named files from different folders apart.
proc els::backup_stem {path} {
    set h [format %08x [zlib crc32 [encoding convertto -profile replace utf-8 \
        [string tolower [file normalize $path]]]]]
    return "[file tail $path].$h"
}
# Backslash-escape glob metacharacters so a name with * ? [ ] { } \ is matched
# LITERALLY by `glob`.  The backup ring's stem embeds the raw filename, so a legal
# Windows name like "report[1].txt" would otherwise make "$stem.*.bak" a character
# class that never matches — breaking both the freshness skip (a backup on every
# save) and ring pruning (unbounded growth until the age sweep).
proc els::glob_escape {s} {
    return [regsub -all {[][*?{}\\]} $s {\\&}]
}
# Order a backup ring by MTIME (epoch), then name.  The filename stamp is LOCAL
# wall-clock, so a plain name sort mis-orders after any BACKWARD clock move (DST
# fall-back, NTP/VM step-back): a backup written just after the step sorts before
# pre-step ones, so the ring prune ([lrange 0 end-BK_RING]) could delete the
# just-written newest version while keeping stale copies.  Epoch mtime is
# continuous across a DST change (only the local representation jumps), so it is
# the stable creation order (F14).
proc els::backup_ring_cmp {a b} {
    set d [expr {[lindex $a 0] - [lindex $b 0]}]
    if {$d != 0} { return [expr {$d < 0 ? -1 : 1}] }
    return [string compare [lindex $a 1] [lindex $b 1]]
}
proc els::backup_ring {dir glob} {
    set pairs {}
    foreach f [glob -nocomplain -directory $dir $glob] {
        set mt 0 ; catch {set mt [file mtime $f]}
        lappend pairs [list $mt $f]
    }
    set out {}
    foreach p [lsort -command els::backup_ring_cmp $pairs] { lappend out [lindex $p 1] }
    return $out
}
proc els::backup_keep {path} {
    if {!$::els::backups} { return }
    set dir [els::backup_dir]
    if {$dir eq ""} { return }
    if {[catch {file size $path} sz] || $sz > $::els::BK_MAXSIZE} { return }
    # NO `return` inside this catch body: catch traps TCL_RETURN too, which
    # would route the skip path into the "backup failed" note
    if {[catch {
        file mkdir $dir
        set stem [els::backup_stem $path]
        set glob "[els::glob_escape $stem].*.bak"
        set ring [els::backup_ring $dir $glob]
        # a fresh-enough newest backup already preserves the interesting
        # (pre-burst) version: skip
        set newest [lindex $ring end]
        set fresh 0
        if {$newest ne "" && ![catch {file mtime $newest} mt]} {
            # A NEGATIVE age (newest mtime in the FUTURE, e.g. after an NTP
            # step-back or VM resume) must NOT read as "fresh", or no backup is
            # taken until the clock passes the stale file's mtime (F14).
            set age [expr {[clock seconds] - $mt}]
            set fresh [expr {$age >= 0 && $age < $::els::BK_MININT}]
        }
        if {!$fresh} {
            # Microsecond-resolution, fixed-width stamp: the readable date-time plus
            # the microsecond-within-second (6 digits) — makes every backup name
            # unique even on same-second bursts (a plain second-resolution stamp
            # collided).  Ring ORDER is by mtime now (els::backup_ring), NOT the
            # name, so a backward wall-clock step can't misorder the prune (F14);
            # the stamp only needs uniqueness.  Derive both parts from one reading
            # so a second-boundary can't skew them.
            set us [clock microseconds]
            set stamp "[clock format [expr {$us / 1000000}] -format %Y%m%d-%H%M%S]-[format %06d [expr {$us % 1000000}]]"
            set target [file join $dir "$stem.$stamp.bak"]
            set n 2
            while {[file exists $target]} {   ;# same-microsecond: keep names unique
                set target [file join $dir "$stem.$stamp-$n.bak"]
                incr n
            }
            set bytes [els::read_binary_file $path]
            set werr [els::write_atomic $target $bytes]
            if {$werr ne ""} { error $werr }
            # prune the ring to the newest BK_RING entries (by mtime, F14).  Never
            # prune the backup we just wrote: after a BACKWARD wall-clock step (NTP
            # correction of a fast clock, or a VM resume to an earlier snapshot) the
            # older backups carry FUTURE mtimes, so the fresh one has the LOWEST mtime
            # and would sort into the delete slice -- a frequently-saved file would then
            # lose its just-made pre-save snapshot precisely while the clock is skewed.
            # The ring may briefly hold BK_RING+1 entries; it self-corrects once the
            # clock passes the stale future mtimes (BK audit, extends F14).
            set keep [file tail $target]
            set ring [els::backup_ring $dir $glob]
            foreach old [lrange $ring 0 end-$::els::BK_RING] {
                if {[file tail $old] eq $keep} { continue }
                catch {file delete -force $old}
            }
        }
    } err]} {
        els::status_note "backup failed: $err"
    }
}
proc els::backups_open {} {
    set dir [els::backup_dir]
    if {$dir eq ""} { return }
    catch {file mkdir $dir}
    els::open_folder $dir
}
proc els::set_backups {{persist 1}} {
    if {$persist} { els::save_geometry }
}

# ---- auto-save (opt-in) ----------------------------------------------------
# File ▸ Auto-save: documents that HAVE a file are saved automatically -- a
# moment after typing pauses, when switching tabs, when the window loses
# focus, and on close/quit.  Untitled documents are never auto-saved (els does
# not invent filenames): with no crash recovery in 0.95, their text simply is
# not on disk until you save it with a name.  Auto-saves are quiet: a write
# error becomes a statusbar note, and a document whose encoding cannot hold its
# characters pauses auto-saving until one manual save settles the question (the
# lossy guard above).
proc els::set_autosave {{persist 1}} {
    if {$::els::autosave} { els::autosave_all }   ;# turning it on saves NOW
    if {$persist} { els::save_geometry }
}
proc els::autosave_soon {id} {
    if {!$::els::autosave} { return }
    dict set ::els::autosave_pending $id 1
    catch {after cancel $::els::autosave_after}
    set ::els::autosave_after [after 1200 els::autosave_flush_pending]
}
proc els::autosave_flush_pending {} {
    set ::els::autosave_after ""
    if {!$::els::autosave} {
        set ::els::autosave_pending {}
        return
    }
    if {$::els::swap_suspend} {
        set ::els::autosave_after [after 250 els::autosave_flush_pending]
        return
    }
    set pend $::els::autosave_pending
    set ::els::autosave_pending {}
    foreach id [dict keys $pend] { els::autosave_flush_doc $id }
}
proc els::autosave_flush_doc {id} {
    if {!$::els::autosave} { return }
    if {$::els::swap_suspend} {
        if {$id ne ""} { dict set ::els::autosave_pending $id 1 }
        if {$::els::autosave_after eq ""} {
            set ::els::autosave_after [after 250 els::autosave_flush_pending]
        }
        return
    }
    if {$id eq "" || $id ni $::els::docs} { return }
    if {![info exists ::els::docPath($id)] || $::els::docPath($id) eq ""} { return }
    if {[info exists ::els::docLossyPause($id)]} { return }   ;# awaiting a manual save
    if {[info exists ::els::docExtModPause($id)]} { return }  ;# file changed on disk: manual save
    if {![els::doc_dirty $id]} { return }
    catch {els::save $id 1}
}
proc els::autosave_all {} {
    foreach id $::els::docs { els::autosave_flush_doc $id }
}

# Save a document (default: the active one).  quiet=1 is the auto-save mode:
# no dialog may ever appear -- an unencodable character pauses auto-saving for
# the document and a write error becomes a statusbar note.
proc els::save {{id ""} {quiet 0} {force 0}} {
    variable active
    variable docPath
    if {$id eq ""} { set id $active }
    if {$id eq ""} { return 0 }
    if {$docPath($id) eq ""} {
        if {$quiet} { return 0 }      ;# auto-save never invents a filename
        return [els::saveas]
    }
    # Ctrl+S on an already-clean, named document is a true no-op.  In
    # particular, do not transcode bytes that were substituted during decode.
    # Save As passes force=1 because creating a new copy is intentional.
    if {!$force && ![els::doc_dirty $id] \
            && ![info exists ::els::docFormatPending($id)]} {
        els::disk_probe $id
        return 1
    }
    # External-change guard (R3): if the file on disk no longer matches what we
    # last loaded/saved, another program rewrote it (git checkout, a formatter, a
    # sync client, a second els) — overwriting would silently destroy that change.
    # savedSigPath pins the baseline to a specific path so a Save As onto a
    # different file never false-positives.  Missing and unreadable targets are
    # conflicts too: only an explicit foreground decision may overwrite them.
    set saved [els::doc_saved_sig $id]
    if {$saved ne "" && [info exists ::els::savedSigPath($id)] \
            && $::els::savedSigPath($id) eq $docPath($id)} {
        set probe [els::file_sig_probe $docPath($id)]
        set state [dict get $probe state]
        if {$state eq "ok" && [els::sig_content [dict get $probe sig]] ne [els::sig_content $saved]} {
            if {$quiet} {
                # autosave: NEVER prompt from a background timer.  Pause quiet
                # saves for this doc until a manual save settles it (mirrors the
                # lossy-encoding pause), and say so once.
                set ::els::docExtModPause($id) 1
                els::status_note "auto-save paused: [file tail $docPath($id)] changed on disk (save manually)"
                return 0
            }
            # overwrite: empty body, fall through to write (clobber the disk copy)
            switch [els::extmod_ask $id] {
                overwrite { }
                reload    { els::reload_from_disk $id ; return 0 }
                cancel    { return 0 }
            }
        } elseif {$state ne "ok"} {
            if {$quiet} {
                set ::els::docExtModPause($id) 1
                els::status_note "auto-save paused: [file tail $docPath($id)] is $state (save manually)"
                return 0
            }
            set detail ""
            if {[dict exists $probe error]} { set detail [dict get $probe error] }
            if {![els::extstate_ask $id $state $detail]} { return 0 }
        }
    }
    unset -nocomplain ::els::docExtModPause($id)
    if {[info exists ::els::docDecodeLossy($id)]} {
        if {$quiet} {
            set ::els::docLossyPause($id) 1
            els::status_note "auto-save paused: decoded bytes were replaced in [file tail $docPath($id)] (save manually)"
            return 0
        }
        if {![els::decode_lossy_ask $id]} { return 0 }
    }
    set w [els::W $id]
    set text [$w get 1.0 "end - 1 char"]
    # re-apply the document's original EOL (buffer is LF-internal)
    switch $::els::docEol($id) {
        crlf { set text [string map [list \n \r\n] $text] }
        cr   { set text [string map [list \n \r]   $text] }
    }
    # encode in the document's encoding -- NEVER silently lossy: characters the
    # encoding cannot hold either switch the doc to UTF-8, are replaced with
    # the user's explicit consent, or cancel the save
    set enc $::els::docEnc($id)
    # only the SIGN of -failindex is trusted (see lossy_first for why)
    set bytes [encoding convertto -profile strict -failindex fi $enc $text]
    # Lossy when a character cannot be saved FAITHFULLY: it does not encode
    # (fi>=0), OR it encodes but decodes back as a DIFFERENT character (cp932/
    # euc-jp duplicate mappings — reopening would show text the user never wrote).
    # The whole-buffer round-trip compare runs only when the buffer fully encoded
    # ($bytes complete): the braced `&&` short-circuits it away when fi>=0 (where
    # $bytes is only the partial prefix).  set fi 0 routes it to the lossy path.
    if {$fi < 0 && [encoding convertfrom $enc $bytes] ne $text} { set fi 0 }
    if {$fi >= 0} {
        if {[info exists ::els::docLossyOk($id)]} {
            set bytes [encoding convertto -profile replace $enc $text]
        } elseif {$quiet} {
            set ::els::docLossyPause($id) 1
            els::status_note "auto-save paused: characters not in [els::enc_label $enc 0] (save manually once)"
            return 0
        } else {
            lassign [els::lossy_describe $enc $text] line col uhex count
            switch [els::lossy_ask $id $enc $line $col $uhex $count] {
                utf8 {
                    set ::els::docEnc($id) utf-8
                    # replace-profile only for the pathological unpaired-
                    # surrogate case, which NO file encoding can hold
                    set bytes [encoding convertto -profile replace utf-8 $text]
                }
                lossy {
                    set ::els::docLossyOk($id) 1
                    set bytes [encoding convertto -profile replace $enc $text]
                }
                cancel { return 0 }
            }
        }
    }
    unset -nocomplain ::els::docLossyPause($id)
    # restore a BOM if the document carries one
    if {$::els::docBom($id)} {
        switch $::els::docEnc($id) {
            utf-8    { set bytes "\xEF\xBB\xBF$bytes" }
            utf-16le { set bytes "\xFF\xFE$bytes" }
            utf-16be { set bytes "\xFE\xFF$bytes" }
            utf-32le { set bytes "\xFF\xFE\x00\x00$bytes" }
            utf-32be { set bytes "\x00\x00\xFE\xFF$bytes" }
        }
    }
    # an overwriting save first preserves the file's CURRENT content as a
    # backup (best-effort; never blocks the save)
    if {[file exists $docPath($id)]} { els::backup_keep $docPath($id) }
    # durable: fsync the bytes to the platter — a saved document is the user's data
    # and must survive power loss, not just a process crash (see els::write_atomic)
    if {[set err [els::write_atomic $docPath($id) $bytes "" 1]] ne ""} {
        if {[string match "DURABILITY:*" $err]} {
            # Atomic replacement already committed the new bytes; only the
            # durability guarantee failed.  Rebase the external-change guard so a
            # retry does not accuse our own write; the doc stays dirty (autosave and
            # the previous-version backups still protect the on-disk file).
            set ::els::docRaw($id) $bytes
            els::cache_saved_sig $id
        }
        if {$quiet} {
            els::status_note "auto-save failed: [file tail $docPath($id)]"
        } else {
            els::message_box -parent . -icon error -title els -message "Cannot save file:\n$err"
        }
        els::disk_probe $id
        return 0
    }
    $w edit modified 0
    # keep the cached raw bytes in sync with what is now on disk, so a later
    # "Reopen with Encoding" re-decodes the SAVED content rather than reverting
    # to the bytes loaded at open time (which silently discarded saved edits, and
    # blanked a Save-As'd new document whose docRaw was still empty)
    set ::els::docRaw($id) $bytes
    els::cache_saved_sig $id
    # the U+FFFD (if any) are now the file's real content, not a decode artifact:
    # docRaw was just refreshed to the written bytes, so the marker no longer applies
    unset -nocomplain ::els::docDecodeLossy($id)
    unset -nocomplain ::els::docFormatPending($id)
    els::update_tab $id
    els::settitle
    els::disk_probe $id
    return 1
}
proc els::saveas {} {
    variable active
    variable docPath
    if {$active eq ""} { return }
    # Native dialogs pump nested events; active can change while the picker is
    # open.  Capture the invoking document and suspend background writes (autosave,
    # the async find worker) across the whole transaction so nothing commits against
    # a half-changed target while the picker owns the event loop.
    set id $active
    set suspendToken [els::suspend_acquire]
    try {
        set p [tk_getSaveFile -parent . -filetypes [els::filetypes] \
                   -defaultextension .txt \
                   -initialfile [els::doc_name $id]]
        if {$p eq "" || $id ni $::els::docs} { return 0 }
        if {![catch {file normalize $p} np]} { set p $np }
        # refuse to point this tab at a file already open in another tab:
        # otherwise the two buffers diverge and silently clobber one another
        foreach other $::els::docs {
            if {$other ne $id && [info exists docPath($other)] && \
                    [els::same_path $docPath($other) $p]} {
                els::message_box -parent . -icon warning -title els \
                    -message "That file is already open in another tab.\
                              \nClose it there first, or choose a different name."
                return 0
            }
        }
        set oldPath $docPath($id)
        set oldModified [[els::W $id] edit modified]
        # save can change format/consent state before I/O (or raw/signatures
        # after an atomic write whose fsync fails).  Save As is transactional:
        # if it returns failure, restore every such field, including absence.
        set metaNames {docEnc docBom docEol docRaw savedSig savedSigPath \
                       docExtModPause docDecodeLossy docLossyOk docLossyPause \
                       docFormatPending}
        set oldMeta {}
        foreach name $metaNames {
            set slot "::els::${name}($id)"
            if {[info exists $slot]} {
                dict set oldMeta $name [list 1 [set $slot]]
            } else {
                dict set oldMeta $name [list 0 ""]
            }
        }
        set docPath($id) $p
        set saveCode [catch {els::save $id 0 1} saveResult saveOpts]
        if {$saveCode || !$saveResult} {
            set docPath($id) $oldPath
            foreach name $metaNames {
                set slot "::els::${name}($id)"
                lassign [dict get $oldMeta $name] existed value
                if {$existed} { set $slot $value } else { unset -nocomplain $slot }
            }
            [els::W $id] edit modified $oldModified
            els::refresh_tabs
            els::settitle
            els::disk_probe $id
            if {$saveCode} { return -options $saveOpts $saveResult }
            return 0
        }
        els::refresh_tabs
        els::recent_add $p
        els::disk_probe $id
        return 1
    } finally {
        els::suspend_release $suspendToken
    }
}
proc els::session_restore {} {
    if {!$::els::restore_session} { return 0 }
    set ::els::session_owned 1   ;# restoring IS adopting the stored session
    set ::els::session_pending {}
    set restored {}
    foreach p [els::session_sanitize $::els::session_files] {
        # A local file that is missing, or any file that fails to open right now
        # (a disconnected drive or a file briefly locked by a backup tool), is not
        # dropped from the session.  Obvious network paths take the separate durable
        # Deferred Opens route in quiet open, without probing the share at startup.
        if {![els::remote_path $p] && ![file exists $p]} {
            lappend ::els::session_pending $p
            continue
        }
        # noRecent=1: restoring the saved session must not push every restored tab
        # to the top of Open Recent (it would evict the user's genuine recents on
        # a plain restart) — a recent entry is earned by opening, not by restore (F38)
        set id [els::open $p 1 1]
        if {$id ne ""} {
            lappend restored [list $p $id]
        } else {
            # The open produced no tab: the file could not be read right now, OR it was
            # deferred (a network path, or larger than the open-warning size).  Keep it
            # in the session either way -- session_pending is folded back into
            # session_files by save_geometry, so dropping it here would silently erase
            # the tab from every future startup, leaving it findable only via File >
            # Deferred Opens.  A deferred path also lives in its own durable queue; the
            # redundancy is harmless and self-heals the moment the file is opened (R05).
            lappend ::els::session_pending $p
        }
    }
    if {![llength $restored]} { return 0 }
    set target ""
    foreach item $restored {
        lassign $item p id
        if {$p eq $::els::session_active} {
            set target $id
            break
        }
    }
    if {$target ne ""} { els::switch_to $target }
    return [llength $restored]
}
# bind an event on a widget and every descendant, so a click anywhere inside a
# composite window is caught — not just on its background
proc els::bindtree {w seq script} {
    bind $w $seq $script
    foreach c [winfo children $w] { els::bindtree $c $seq $script }
}
proc els::about {} {
    catch {destroy .about}
    toplevel .about -bg $::els::PAGE
    wm withdraw .about        ;# build off-screen, reveal only when fully formed
    wm title .about "About els"
    wm transient .about .
    wm resizable .about 0 0
    set bg $::els::PAGE
    frame .about.card -bg $bg
    pack  .about.card -padx 34 -pady 28
    frame .about.top -bg $bg
    pack  .about.top -in .about.card -anchor center
    set iconSize 0
    if {$::els::iconLoaded} {
        catch {image delete elsAboutIcon}
        image create photo elsAboutIcon
        elsAboutIcon copy elsIcon -subsample 2 -subsample 2   ;# 256px -> 128px
        set iconSize [image height elsAboutIcon]
        label .about.top.icon -image elsAboutIcon -bg $bg -bd 0
        grid .about.top.icon -row 0 -column 0 -sticky ns -padx {0 20}
    }
    label .about.top.name -text "els" -font elsTitle -fg $::els::INK -bg $bg -anchor center
    grid .about.top.name -row 0 -column 1 -sticky ns
    if {$iconSize > 0} { grid rowconfigure .about.top 0 -minsize $iconSize }
    frame .about.body -bg $bg
    pack  .about.body -in .about.card -anchor center -pady {14 0}
    label .about.body.tag -text "a simple text editor" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.tag -anchor center -pady {0 12}
    label .about.body.copy -text "© 2026 Vincent Vercauteren" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.copy -anchor center -pady {0 14}
    label .about.body.ackh -text "Acknowledgements" \
        -font elsUIb -fg $::els::INK -bg $bg -anchor center
    pack  .about.body.ackh -anchor center
    label .about.body.ack \
        -text "Made possible by Tcl/Tk 9, MinGW-w64, GCC, zlib, and LibTomMath.\nWith thanks to their maintainers and communities." \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center -justify center
    pack  .about.body.ack -anchor center -pady {3 14}
    label .about.body.ver -text "version $::els::version" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.ver -anchor center -pady {0 2}
    label .about.body.lic -text "MIT License" \
        -font elsUI -fg $::els::MUTED -bg $bg -anchor center
    pack  .about.body.lic -anchor center
    # a click anywhere, or Escape, dismisses it
    bind .about <Escape> {destroy .about}
    els::bindtree .about <Button-1> {destroy .about}
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .about]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .about]) / 3}]
    wm geometry .about +$x+$y
    wm deiconify .about
    focus .about
}
# A terse, two-column keyboard-shortcut reference (Help ▸ Keyboard Shortcuts).
# Keys in mono ink, actions in muted UI — same calm language as the regex card.
proc els::shortcuts {} {
    catch {destroy .keys}
    toplevel .keys -bg $::els::PAGE
    wm withdraw .keys        ;# build off-screen, reveal only when fully formed
    wm title .keys "Keyboard Shortcuts"
    wm transient .keys .
    wm resizable .keys 0 0
    set bg $::els::PAGE
    frame .keys.f -bg $bg
    pack  .keys.f -padx 28 -pady 22
    label .keys.f.title -text "Keyboard Shortcuts" -font elsUIb -fg $::els::INK -bg $bg
    label .keys.f.sub -text "Common actions in els" -font elsUI -fg $::els::MUTED -bg $bg
    grid .keys.f.title -row 0 -column 0 -columnspan 3 -sticky w
    grid .keys.f.sub   -row 1 -column 0 -columnspan 3 -sticky w -pady {2 14}
    set columns {
        {
            File {
                Ctrl+N        {New tab}
                Ctrl+O        {Open}
                Ctrl+S        {Save}
                Ctrl+Shift+S  {Save as}
                Ctrl+W        {Close file}
                Ctrl+Q        {Exit}
            }
            Edit {
                Ctrl+Z  {Undo}
                Ctrl+Y  {Redo}
                Ctrl+X  {Cut}
                Ctrl+C  {Copy}
                Ctrl+V  {Paste}
                Ctrl+A  {Select all}
            }
            Lines {
                {Alt+↑/↓}       {Move line up / down}
                Ctrl+D          {Duplicate line}
                Ctrl+Shift+K    {Delete line}
                Ctrl+J          {Join lines}
                {Tab/Shift+Tab} {Indent / dedent selection}
            }
        }
        {
            Navigation {
                {Home/End}        {Line start / end}
                {Ctrl+Home/End}   {File start / end}
                {Ctrl+←/→}        {Word left / right}
                {Ctrl+↑/↓}        {Paragraph up / down}
                {PageUp/PageDn}   {Page up / down}
            }
            Selection {
                {Shift+arrows}        {Extend selection}
                {Ctrl+Shift+←/→}      {Extend by word}
                {Shift+Home/End}      {Select to line edge}
                {Ctrl+Shift+Home/End} {Select to file edge}
            }
            Tabs {
                Ctrl+Tab        {Next tab}
                Ctrl+Shift+Tab  {Previous tab}
            }
        }
        {
            Search {
                Ctrl+F          {Find}
                Ctrl+H          {Replace}
                Ctrl+G          {Go to line}
                {F3/Shift+F3}   {Next / prev match}
                Enter           {Next match}
                Shift+Enter     {Previous match}
                {↑/↓}           {Search history}
                Esc             {Close find bar}
            }
            View {
                {Ctrl  +}    {Zoom in}
                {Ctrl  −}    {Zoom out}
                {Ctrl  0}    {Reset zoom}
                {Ctrl Wheel} {Zoom}
            }
        }
    }
    set col 0
    foreach sections $columns {
        set cf [frame .keys.f.c$col -bg $bg]
        if {$col < 2} {
            set padx [list 0 18]
        } else {
            set padx [list 0 0]
        }
        grid $cf -row 2 -column $col -sticky n -padx $padx
        set r 0
        foreach {cat rows} $sections {
            set sec [frame $cf.s$r -bg $bg -highlightthickness 1 \
                         -highlightbackground $::els::HAIR]
            grid $sec -row $r -column 0 -sticky new -pady [list 0 10]
            label $sec.h -text $cat -font elsUIb -fg $::els::INK -bg $bg
            grid  $sec.h -row 0 -column 0 -columnspan 2 -sticky w -padx 10 -pady {8 5}
            set sr 1
            foreach {k d} $rows {
                label $sec.k$sr -text $k -font elsMonoHelp -fg $::els::INK   -bg $bg -anchor w
                label $sec.d$sr -text $d -font elsUI       -fg $::els::MUTED -bg $bg -anchor w
                grid  $sec.k$sr -row $sr -column 0 -sticky w -padx {10 18} -pady {1 1}
                grid  $sec.d$sr -row $sr -column 1 -sticky w -padx {0 12}  -pady {1 1}
                incr sr
            }
            grid rowconfigure $sec $sr -minsize 8
            grid columnconfigure $sec 1 -weight 1
            incr r
        }
        grid columnconfigure $cf 0 -weight 1
        incr col
    }
    grid columnconfigure .keys.f {0 1 2} -weight 1
    bind .keys <Escape> {destroy .keys}
    update idletasks
    set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth .keys]) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight .keys]) / 4}]
    wm geometry .keys +$x+$y
    wm deiconify .keys
    focus .keys
}
proc els::quit {} {
    variable docs
    els::autosave_all   ;# auto-save on: pathed docs leave saved; only the rest prompt
    foreach id $docs {
        if {[els::doc_dirty $id]} {
            els::switch_to $id
            set ans [els::message_box -parent . -icon warning -type yesnocancel \
                -title els -message "Save changes to [els::doc_name $id]?"]
            if {$ans eq "cancel"} { return }   ;# aborted quit: autosave stays armed
            if {$ans eq "yes"} {
                els::save $id   ;# save the PROMPTED doc, never a since-changed $active
                if {[els::doc_dirty $id]} { return }
            }
        }
    }
    els::find_shutdown
    els::save_geometry
    els::disk_watch_deactivate
    exit
}

# ---- find / replace -----------------------------------------------------
# Worker files live only beneath the executable-adjacent state directory.  The
# helper deliberately returns "" rather than falling back elsewhere: an
# unobservable/unmanaged worker is never an acceptable substitute.
proc els::find_token {} {
    set seed "[els::session_token]:[clock microseconds]:[clock clicks]:[expr {rand()}]"
    return [format %08x%08x%08x%08x \
        [zlib crc32 $seed] [zlib crc32 "a:$seed"] \
        [zlib crc32 "b:$seed"] [zlib crc32 "c:$seed"]]
}

proc els::find_native_ready {} {
    if {[llength [info commands ::els::win_worker_spawn_watch]] \
            && [llength [info commands ::els::win_worker_watch]] \
            && [llength [info commands ::els::win_worker_status]] \
            && [llength [info commands ::els::win_worker_kill]] \
            && [llength [info commands ::els::win_path_reparse]]} { return 1 }
    # A source/development run loads the reviewed extension beside the source.
    # The packaged exe registers the same commands statically before main.tcl.
    if {![string match {//zipfs:/*} $::els::boot_script]} {
        set dll [file join [file dirname $::els::boot_script] build winfs.dll]
        if {[file exists $dll] && [file type $dll] eq "file"} { catch {load $dll Winfs} }
    }
    return [expr {[llength [info commands ::els::win_worker_spawn_watch]] \
        && [llength [info commands ::els::win_worker_watch]] \
        && [llength [info commands ::els::win_worker_status]] \
        && [llength [info commands ::els::win_worker_kill]] \
        && [llength [info commands ::els::win_path_reparse]]}]
}

# True only for an existing, ordinary filesystem object of the requested type.
# `file type` catches Tcl links; the native attribute check also catches Windows
# junctions and every other reparse point before a worker path is trusted.
proc els::find_path_plain {path expectedType} {
    if {[catch {file lstat $path st}] || $st(type) ne $expectedType} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} {
        if {![els::find_native_ready] \
                || [catch {els::win_path_reparse [file nativename $path]} reparse] \
                || $reparse} { return 0 }
    }
    return 1
}

proc els::find_root {{create 1}} {
    if {$::els::config_path eq "" || $::els::selftest} { return "" }
    set root [file join [file dirname $::els::config_path] .els-find]
    if {$create && ![file exists $root]} {
        if {[catch {file mkdir $root}]} { return "" }
    }
    if {![els::find_path_plain $root directory] \
            || [catch {set root [file normalize $root]}]} { return "" }
    # Recheck the normalized spelling too: normalization may traverse a link.
    if {![els::find_path_plain $root directory]} { return "" }
    return $root
}

proc els::find_worker_command {} {
    if {$::els::find_worker_command_override ne ""} {
        return $::els::find_worker_command_override
    }
    if {[string match {//zipfs:/*} $::els::boot_script]} {
        return [list [els::association_exe] --find-worker]
    }
    return [list [info nameofexecutable] $::els::boot_script --find-worker]
}

proc els::find_write_control {path value} {
    set raw [encoding convertto -profile strict utf-8 $value]
    if {[string length $raw] > $::elsworker::CONTROL_MAX} { error "find control file too large" }
    set tmp "$path.tmp-[pid]-[clock clicks]"
    set f [::open $tmp {WRONLY CREAT EXCL TRUNC}]
    fconfigure $f -translation binary
    try { puts -nonewline $f $raw } finally { close $f }
    if {![els::find_path_plain [file dirname $path] directory] \
            || ![els::find_path_plain $tmp file]} {
        catch {file delete $tmp}
        error "find control path is not contained"
    }
    file rename $tmp $path
}

proc els::find_job_dir_name {seq token} {
    return "find-[els::session_id]-$seq-$token"
}
proc els::find_job_name_ok {name} {
    return [regexp {^find-[a-z0-9_]+-[0-9]+-[0-9a-f]{16}-[0-9]+-[0-9a-f]{32}$} $name]
}
proc els::find_snapshot_name_ok {name {allowTemp 0}} {
    set base {^snapshot-[a-z0-9_]+-[0-9]+-[0-9a-f]{16}-[0-9a-f]{32}\.utf8$}
    if {[regexp $base $name]} { return 1 }
    return [expr {$allowTemp && [regexp \
        {^snapshot-[a-z0-9_]+-[0-9]+-[0-9a-f]{16}-[0-9a-f]{32}\.utf8\.tmp-[0-9]+-[0-9-]+$} $name]}]
}

proc els::find_job_dir_ok {dir} {
    set root [els::find_root 0]
    if {$root eq "" || ![els::find_path_plain $dir directory] \
            || [catch {set nd [file normalize $dir]}] \
            || [file dirname $nd] ne $root \
            || ![els::find_job_name_ok [file tail $nd]] \
            || ![els::find_path_plain $nd directory]} { return "" }
    return $nd
}

proc els::find_snapshot_path_ok {path {allowTemp 0}} {
    set root [els::find_root 0]
    if {$root eq "" || [catch {set np [file normalize $path]}] \
            || [file dirname $np] ne $root \
            || ![els::find_snapshot_name_ok [file tail $np] $allowTemp] \
            || ![els::find_path_plain $np file]} { return 0 }
    return 1
}

proc els::find_job_file_ok {job leaf} {
    if {![dict exists $job dir] || [file tail $leaf] ne $leaf} { return 0 }
    set dir [els::find_job_dir_ok [dict get $job dir]]
    if {$dir eq ""} { return 0 }
    set path [file join $dir $leaf]
    return [expr {[file dirname $path] eq $dir && [els::find_path_plain $path file]}]
}

proc els::find_cleanup_job {job} {
    if {$job eq "" || ![dict exists $job dir]} { return }
    set nd [els::find_job_dir_ok [dict get $job dir]]
    if {$nd eq ""} { return }
    set allowed {go request.dict snapshot.utf8 matches.idx replacement.utf8 result.ready}
    if {[catch {set leaves [glob -nocomplain -directory $nd *]}]} { return }
    foreach p $leaves {
        set leaf [file tail $p]
        if {$leaf ni $allowed && ![regexp {^(go|request\.dict|result\.ready)\.tmp-[0-9]+-[0-9-]+$} $leaf]} {
            catch {els::log warn "refusing to remove unexpected find-worker file $p"}
            return
        }
        if {![els::find_path_plain $p file]} {
            catch {els::log warn "refusing to remove non-regular find-worker file $p"}
            return
        }
    }
    foreach p $leaves {
        # Recheck each leaf immediately before deletion; cleanup races fail
        # closed and never recurse through an attacker-swapped directory.
        if {![els::find_path_plain $nd directory] || ![els::find_path_plain $p file]} { return }
        if {[catch {file delete $p}]} { return }
    }
    if {[els::find_path_plain $nd directory] \
            && ![catch {set rest [glob -nocomplain -directory $nd *]}] \
            && ![llength $rest]} { catch {file delete $nd} }
}

proc els::find_result_drop {} {
    if {$::els::find_highlight_after ne ""} {
        after cancel $::els::find_highlight_after
        set ::els::find_highlight_after ""
    }
    if {$::els::find_result_job ne ""} { els::find_cleanup_job $::els::find_result_job }
    set ::els::find_highlight_state {}
    set ::els::find_result_job {}
    set ::els::find_index_path ""
    set ::els::find_total 0
    set ::els::find_matches {}
    set ::els::find_current -1
}

proc els::find_snapshot_abort {} {
    if {$::els::find_snapshot_after ne ""} {
        after cancel $::els::find_snapshot_after
        set ::els::find_snapshot_after ""
    }
    if {$::els::find_snapshot_build ne ""} {
        set b $::els::find_snapshot_build
        if {[dict exists $b chan]} { catch {close [dict get $b chan]} }
        if {[dict exists $b tmp]} {
            set p [dict get $b tmp]
            if {[els::find_snapshot_path_ok $p 1]} { catch {file delete $p} }
        }
        set ::els::find_snapshot_build {}
    }
}

proc els::find_snapshot_drop {} {
    els::find_snapshot_abort
    if {$::els::find_snapshot ne "" && [dict exists $::els::find_snapshot path]} {
        set p [dict get $::els::find_snapshot path]
        if {[els::find_snapshot_path_ok $p]} { catch {file delete $p} }
    }
    set ::els::find_snapshot {}
}

proc els::find_prune_stale {} {
    set root [els::find_root 0]
    if {$root eq ""} { return }
    set cutoff [expr {[clock seconds] - 86400}]
    set own "find-[els::session_id]-"
    if {[catch {set entries [glob -nocomplain -directory $root *]}]} { return }
    foreach p $entries {
        set leaf [file tail $p]
        if {[string match "$own*" $leaf]} { continue }
        if {[catch {file mtime $p} mt] || $mt >= $cutoff} { continue }
        if {[els::find_job_name_ok $leaf] && [els::find_path_plain $p directory]} {
            els::find_cleanup_job [dict create dir $p]
        } elseif {[els::find_snapshot_name_ok $leaf 1] \
                && [els::find_path_plain $p file]} {
            catch {file delete $p}
        }
    }
}

proc els::build_findbar {} {
    ttk::frame .find -padding {8 6 8 0}

    ttk::frame .find.fr
    ttk::label .find.fr.l -text "Find" -font elsUI -width 7 -anchor w
    ttk::entry .find.fr.q -textvariable ::els::find_q -font elsUI
    ttk::frame .find.fr.ctrl
    ttk::checkbutton .find.fr.case  -text "Aa" -style Find.Toolbutton -takefocus 1 \
        -variable ::els::find_case  -command els::find_update
    ttk::checkbutton .find.fr.word  -text "W"  -style Find.Toolbutton -takefocus 1 \
        -variable ::els::find_word  -command els::find_update
    ttk::checkbutton .find.fr.regex -text ".*" -style Find.Toolbutton -takefocus 1 \
        -variable ::els::find_regex -command els::find_update
    ttk::button .find.fr.help -text "?" -style Find.TButton -width 2 -takefocus 1 \
        -state normal -command els::regex_help
    ttk::button .find.fr.prev -text "↑" -style Find.TButton -width 2 -takefocus 1 -command {els::find_step -1}
    ttk::button .find.fr.next -text "↓" -style Find.TButton -width 2 -takefocus 1 -command {els::find_step 1}
    ttk::label  .find.fr.n -textvariable ::els::find_count -font elsUI \
        -foreground $::els::MUTED -width 16 -anchor e   ;# room for large counts
    ttk::button .find.fr.x -text "×" -style Find.TButton -width 2 -takefocus 1 -command els::find_hide
    grid .find.fr.l    -row 0 -column 0 -padx 1 -sticky we
    grid .find.fr.q    -row 0 -column 1 -padx 1 -sticky we
    grid .find.fr.ctrl -row 0 -column 2 -padx 1 -sticky e
    grid columnconfigure .find.fr 1 -weight 1
    pack .find.fr.x .find.fr.n .find.fr.next .find.fr.prev .find.fr.help \
         .find.fr.regex .find.fr.word .find.fr.case -in .find.fr.ctrl \
         -side right -padx {2 0}
    els::tooltip .find.fr.case  "Match case"
    els::tooltip .find.fr.word  "Whole word"
    els::tooltip .find.fr.regex "Regular expression"
    els::tooltip .find.fr.help  "Regex quickref"
    els::tooltip .find.fr.prev  "Previous  (Shift+Enter)"
    els::tooltip .find.fr.next  "Next  (Enter)"
    els::tooltip_for .find.fr.n els::find_count_tip

    ttk::frame .find.rr
    ttk::label .find.rr.l -text "Replace" -font elsUI -width 7 -anchor w
    ttk::entry .find.rr.r -textvariable ::els::find_r -font elsUI
    ttk::frame .find.rr.ctrl
    ttk::checkbutton .find.rr.adapt -text "Adapt case" -style FindAction.Toolbutton -takefocus 1 \
        -variable ::els::find_adapt -command els::find_replacement_changed
    ttk::button .find.rr.rep -text "Replace" -style FindAction.TButton -takefocus 1 -command els::find_replace_one
    ttk::button .find.rr.all -text "All"     -style FindAction.TButton -takefocus 1 -command els::find_all_action
    grid .find.rr.l    -row 0 -column 0 -padx 1 -sticky we
    grid .find.rr.r    -row 0 -column 1 -padx 1 -sticky we
    grid .find.rr.ctrl -row 0 -column 2 -padx 1 -sticky e
    grid columnconfigure .find.rr 1 -weight 1
    pack .find.rr.all .find.rr.rep .find.rr.adapt -in .find.rr.ctrl \
         -side right -padx {2 0}
    els::tooltip .find.rr.adapt "Adapt case — make each replacement follow the case of the match"

    update idletasks
    set cw [expr {max([winfo reqwidth .find.fr.ctrl], [winfo reqwidth .find.rr.ctrl])}]
    set ch [expr {max([winfo reqheight .find.fr.ctrl], [winfo reqheight .find.rr.ctrl])}]
    foreach c {.find.fr.ctrl .find.rr.ctrl} {
        $c configure -width $cw -height $ch
        pack propagate $c 0
    }

    # find bar now lives at the TOP (below the tabs), so the hairline rule sits
    # at its BOTTOM, separating it from the text below
    grid .find.fr -row 0 -column 0 -sticky ew
    grid .find.rr -row 1 -column 0 -sticky ew -pady {4 0}
    frame .find.sep -height 1 -bg $::els::HAIR
    grid .find.sep -row 2 -column 0 -sticky ew -pady {6 0}
    grid columnconfigure .find 0 -weight 1

    bind .find.fr.q <KeyRelease> {
        # Only arm the 130 ms incremental-search debounce for keys that can change
        # the query TEXT.  Return/KP_Enter already stepped in the <Return> KeyPress
        # binding (excluding them keeps the "(wrapped)" note and avoids a redundant
        # re-scan); Up/Down are history recall.  Navigation and modifier keys change
        # nothing, so they must not arm a search: that search supersedes and silently
        # cancels a running Replace All (R06).
        if {"%K" ni {Up Down Return KP_Enter Left Right Home End Prior Next
                     Tab ISO_Left_Tab Shift_L Shift_R Control_L Control_R
                     Alt_L Alt_R Meta_L Meta_R Super_L Super_R Caps_Lock}} {
            set ::els::find_hidx -1 ; els::find_schedule
        }
    }
    bind .find.fr.q <Return>       { els::find_history_push $::els::find_q
                                     els::find_step 1  ; break }
    bind .find.fr.q <Shift-Return> { els::find_step -1 ; break }
    bind .find.fr.q <Up>           { els::find_history_recall  1 ; break }
    bind .find.fr.q <Down>         { els::find_history_recall -1 ; break }
    bind .find.fr.q <Escape>       { els::find_hide    ; break }
    bind .find.rr.r <Return>       { els::find_replace_one ; break }
    bind .find.rr.r <KeyRelease>   { if {"%K" ni {Return KP_Enter Escape}} { els::find_replacement_changed } }
    bind .find.rr.r <Escape>       { els::find_hide    ; break }
    # Ctrl+H is the Replace accelerator; without this, the ttk::entry TEntry class
    # binding (Control-h -> Backspace) fires first and eats a character from the
    # search/replacement text.  A widget-level binding with break pre-empts it.
    bind .find.fr.q <Control-h>    { els::find_show replace ; break }
    bind .find.rr.r <Control-h>    { els::find_show replace ; break }

    els::entry_clear_button .find.fr.q ::els::find_q
    els::entry_clear_button .find.rr.r ::els::find_r
    # Escape closes the bar from every focusable control, not only its entries.
    # Install after the clear-button children exist so the whole subtree shares
    # one deterministic dismissal path.
    els::bindtree .find <Escape> {els::find_hide ; break}

    # Textvariable traces cover paste, IME, programmatic writes, and option
    # changes that do not generate the entry KeyRelease binding.  Rebuilding the
    # test UI must not accumulate duplicate observers.
    foreach v {find_q find_case find_word find_regex} {
        catch {trace remove variable ::els::$v write els::find_query_trace}
        trace add variable ::els::$v write els::find_query_trace
    }
    foreach v {find_r find_adapt} {
        catch {trace remove variable ::els::$v write els::find_replacement_trace}
        trace add variable ::els::$v write els::find_replacement_trace
    }
}

proc els::find_query_trace {args} {
    if {[info exists ::els::find_mode] && $::els::find_mode ne ""} { els::find_schedule }
}
proc els::find_replacement_trace {args} {
    if {[info exists ::els::find_mode] && $::els::find_mode ne ""} {
        els::find_replacement_changed
    }
}

# In-entry clear button: a small "×" hugging the entry's right edge, shown
# only while the field has text; clicking empties the field (and re-runs the
# search so stale highlights vanish with the query).
proc els::entry_clear_button {entry var} {
    set x $entry.clearx
    set bg [ttk::style lookup TEntry -fieldbackground {} $::els::PAGE]
    label $x -text "×" -font elsUI -cursor hand2 -bg $bg -fg $::els::MUTED \
        -padx 2 -pady 0 -borderwidth 0
    bind $x <Enter>    [list $x configure -fg $::els::INK]
    bind $x <Leave>    [list $x configure -fg $::els::MUTED]
    bind $x <Button-1> [list els::entry_clear $entry $var]
    # re-installed on every els::build: drop the previous trace first so test
    # rebuilds don't accumulate duplicates
    catch {trace remove variable $var write [list els::entry_clear_sync $entry $var]}
    trace add variable $var write [list els::entry_clear_sync $entry $var]
    els::entry_clear_sync $entry $var
}
proc els::entry_clear_sync {entry var args} {
    set x $entry.clearx
    if {![winfo exists $x]} { return }
    if {[set $var] ne ""} {
        place $x -in $entry -relx 1.0 -x -3 -rely 0.5 -anchor e
        raise $x
    } else {
        place forget $x
    }
}
proc els::entry_clear {entry var} {
    set $var ""
    catch {focus $entry}
    els::find_update
}

# ---- find-bar polish: tooltips, count-label feedback, regex help, history
proc els::tooltip {w text} {
    bind $w <Enter>      [list els::tip_schedule $w $text]
    bind $w <Leave>      els::tip_cancel
    # per-button (not generic <ButtonPress>) + APPEND: a widget's own specific
    # <Button-1> binding (e.g. a tab's switch_to) shadows a generic one, so a
    # click never dismissed the tip; appending composes with existing handlers
    bind $w <ButtonPress-1> {+els::tip_cancel}
    bind $w <ButtonPress-2> {+els::tip_cancel}
    bind $w <ButtonPress-3> {+els::tip_cancel}
    # the anchor dying must take its pending timer AND a visible tip with it —
    # otherwise an orphan -topmost .tip floats over the desktop indefinitely
    bind $w <Destroy> {+els::tip_cancel}
}
proc els::tip_schedule {w text} {
    els::tip_cancel
    set ::els::tip_after [after 550 [list els::tip_pop $w $text]]
}
proc els::tip_cancel {} {
    if {[info exists ::els::tip_after]} { after cancel $::els::tip_after ; unset ::els::tip_after }
    catch {destroy .tip}
}
# Wrap long tooltip text so it can't run off the screen.  Tk labels only wrap at
# whitespace, but our long tips are paths (separators, usually no spaces), so we
# insert the breaks: after a separator/space once a line reaches ~target, and a
# hard break if a run grows past target+cap with no natural break point.
proc els::tip_wrap {s {target 72} {cap 24}} {
    if {[string length $s] <= $target} { return $s }
    set out {} ; set line ""
    foreach ch [split $s ""] {
        append line $ch
        set n [string length $line]
        if {($n >= $target && [string first $ch "/\\ -_"] >= 0) || $n >= $target + $cap} {
            lappend out $line ; set line ""
        }
    }
    if {$line ne ""} { lappend out $line }
    return [join $out \n]
}
proc els::tip_pop {w text} {
    catch {destroy .tip}
    if {![winfo exists $w] || $text eq ""} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text [els::tip_wrap $text] -justify left \
        -bg "#2B2B2B" -fg "#F0F0F0" -font elsUI -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set tw [winfo reqwidth .tip] ; set th [winfo reqheight .tip]
    set x [expr {[winfo rootx $w] + [winfo width $w] / 2 - $tw / 2}]
    set below [expr {[winfo rooty $w] + [winfo height $w] + 5}]
    # Prefer below the widget; flip above when needed, then clamp into the widget's
    # own toplevel (the main window, or a dialog like the recent-files manager).
    # Tooltips are context for that window, not little screen-global balloons.
    set top [winfo toplevel $w]
    set margin 4
    set winl [winfo rootx $top]
    set wint [winfo rooty $top]
    set winr [expr {$winl + [winfo width $top]}]
    set winb [expr {$wint + [winfo height $top]}]
    set above [expr {[winfo rooty $w] - $th - 5}]
    if {$below + $th <= $winb - $margin} {
        set y $below
    } elseif {$above >= $wint + $margin} {
        set y $above
    } else {
        set y [expr {min(max($below, $wint + $margin), $winb - $th - $margin)}]
    }
    if {$x < $winl + $margin} {
        set x [expr {$winl + $margin}]
    } elseif {$x + $tw > $winr - $margin} {
        set x [expr {max($winl + $margin, $winr - $margin - $tw)}]
    }
    wm geometry .tip +$x+$y
}
# A tooltip anchored at explicit screen coordinates (e.g. near the cursor), used
# for per-row tips in a list where one widget holds many hover targets.  Clamped
# to the screen rather than a window.
# Keep a tip fully on-screen: clamp its right/bottom against the VIRTUAL desktop
# (els::virtual_screen — the native multi-monitor rect), NOT wm maxsize, which is
# only the PRIMARY monitor's maximized size and teleported a secondary-monitor tip
# back to the primary's edge (G-View mat-3).  No left/top snap: monitors left/above
# the primary have legitimately negative root coordinates.
proc els::tip_clamp {rx ry tw th vx vy vw vh} {
    set right [expr {$vx + $vw}] ; set bottom [expr {$vy + $vh}]
    if {$rx + $tw > $right - 4}  { set rx [expr {$right - $tw - 4}] }
    if {$ry + $th > $bottom - 4} { set ry [expr {$ry - $th - 22}] }
    return [list $rx $ry]
}
proc els::tip_pop_at {text rx ry} {
    catch {destroy .tip}
    if {$text eq ""} { return }
    toplevel .tip -bd 0
    wm overrideredirect .tip 1
    catch {wm attributes .tip -topmost 1}
    label .tip.l -text [els::tip_wrap $text] -justify left \
        -bg "#2B2B2B" -fg "#F0F0F0" -font elsUI -padx 6 -pady 2
    pack .tip.l
    update idletasks
    set tw [winfo reqwidth .tip] ; set th [winfo reqheight .tip]
    lassign [els::tip_clamp $rx $ry $tw $th {*}[els::virtual_screen]] rx ry
    wm geometry .tip +$rx+$ry
}
# A dynamic tooltip: `textcmd` is evaluated each time the tip is about to show,
# so it tracks live state; an empty result suppresses the tip (e.g. a status
# name that currently fits and isn't elided, or an untitled tab).
proc els::tooltip_for {w textcmd {delay 550}} {
    bind $w <Enter>       [list els::tip_schedule_cmd $w $textcmd $delay]
    bind $w <Leave>       els::tip_cancel
    # see els::tooltip: per-button appends (shadowing) + a Destroy hook (orphans)
    bind $w <ButtonPress-1> {+els::tip_cancel}
    bind $w <ButtonPress-2> {+els::tip_cancel}
    bind $w <ButtonPress-3> {+els::tip_cancel}
    bind $w <Destroy> {+els::tip_cancel}
}
proc els::tip_schedule_cmd {w textcmd {delay 550}} {
    els::tip_cancel
    set ::els::tip_after [after $delay [list els::tip_pop_cmd $w $textcmd]]
}
proc els::tip_pop_cmd {w textcmd} {
    if {![winfo exists $w]} { return }
    els::tip_pop $w [uplevel #0 $textcmd]
}
# The find-count label is a fixed 16-char slot; the async find worker routes long
# diagnostics ("Find unavailable (worker control missing)", "Document too large to
# search", "Find worker returned invalid data") through it, and -anchor e clips
# them to an unreadable tail.  Its tooltip carries the full text, but only when the
# label actually clips it -- an ordinary "3 of 12" count returns "" (no tip) (R22).
proc els::find_count_tip {} {
    if {![winfo exists .find.fr.n]} { return "" }
    set s $::els::find_count
    if {$s eq "" || [string length $s] <= [.find.fr.n cget -width]} { return "" }
    return $s
}

# a compact, scannable regex quick reference, opened from the Find/Replace "?"
proc els::regex_help {} {
    catch {destroy .rehelp}
    toplevel .rehelp
    wm title .rehelp "Regular Expressions Quickref"
    wm transient .rehelp .
    wm resizable .rehelp 0 0
    catch {wm attributes .rehelp -topmost 1}
    ttk::frame .rehelp.f -padding 14
    pack .rehelp.f -fill both -expand 1
    ttk::label .rehelp.f.h -text "Regular Expressions Quickref" \
        -font elsUI -foreground $::els::MUTED
    grid .rehelp.f.h -row 0 -column 0 -columnspan 2 -sticky w -pady {0 4}
    ttk::label .rehelp.f.note -text \
        "These patterns are used when Regex is on. With Regex off, els searches for the text literally." \
        -font elsUI -foreground $::els::MUTED -wraplength 380 -justify left
    grid .rehelp.f.note -row 1 -column 0 -columnspan 2 -sticky w -pady {0 8}
    set rows {
        {.}           {any character}
        {[abc]}       {any one of these characters}
        {[^abc]}      {any character except these}
        {[a-z]}       {a range}
        {* + ?}       {0 or more,  1 or more,  0 or 1}
        {{n} {n,m}}   {exactly n  /  n to m times}
        {^ $}         {start / end of line}
        {\m \M}       {start / end of a word}
        {\w \d \s}    {word character / digit / whitespace}
        {( ... )}     {capture group}
        {\1 \2}       {backreference (use in Replace)}
        {&}           {whole match (in Replace; \& for a literal &)}
        {a|b}         {a or b}
        {\\}          {a literal backslash}
    }
    set r 2
    foreach {tok desc} $rows {
        ttk::label .rehelp.f.t$r -text $tok  -font elsMonoHelp -foreground $::els::INK
        ttk::label .rehelp.f.d$r -text $desc -font elsUI   -foreground $::els::MUTED
        grid .rehelp.f.t$r -row $r -column 0 -sticky w -padx {0 22} -pady 1
        grid .rehelp.f.d$r -row $r -column 1 -sticky w -pady 1
        incr r
    }
    bind .rehelp <Escape> {destroy .rehelp}
    focus .rehelp
    update idletasks
    set rw [winfo reqwidth .rehelp]
    set rh [winfo reqheight .rehelp]
    wm minsize .rehelp $rw $rh
    wm maxsize .rehelp $rw $rh
    wm resizable .rehelp 0 0
    set x [expr {[winfo rootx .] + ([winfo width .]  - $rw) / 2}]
    set y [expr {[winfo rooty .] + ([winfo height .] - $rh) / 3}]
    wm geometry .rehelp ${rw}x${rh}+$x+$y
}

proc els::find_history_push {term} {
    variable find_history ; variable find_hidx
    if {$term eq ""} { return }
    set find_history [linsert [lsearch -all -inline -not -exact $find_history $term] 0 $term]
    if {[llength $find_history] > 16} { set find_history [lrange $find_history 0 15] }
    set find_hidx -1
}
proc els::find_history_recall {dir} {
    variable find_history ; variable find_hidx
    set n [llength $find_history]
    if {$n == 0} { return }
    set i [expr {$find_hidx + $dir}]
    if {$i < 0}   { set find_hidx -1 ; return }   ;# back below newest: leave field as-is
    if {$i >= $n} { set i [expr {$n - 1}] }
    set find_hidx $i
    set ::els::find_q [lindex $find_history $i]
    .find.fr.q icursor end
    els::find_update
}

# Debounce incremental search: a burst of keystrokes runs ONE search after a
# short pause, so a full-buffer search never blocks the UI on every key.
proc els::find_schedule {} {
    variable find_after
    after cancel $find_after
    set find_after [after 130 els::find_scheduled_update]
}
proc els::find_scheduled_update {} {
    set ::els::find_after ""
    if {$::els::swap_suspend} {
        set ::els::find_after [after 20 els::find_scheduled_update]
        return
    }
    els::find_update
}

# escape ARE metacharacters so a literal string searches literally
proc els::re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

proc els::find_show {mode} {
    variable find_mode
    set find_mode $mode
    grid .find -row 1 -column 0 -columnspan 3 -sticky ew
    if {$mode eq "replace"} { grid .find.rr } else { grid remove .find.rr }
    catch {.find.fr.help configure -state normal}
    catch {.find.fr.help state !disabled}
    set w [els::T]
    if {$w ne "" && [llength [$w tag ranges sel]]} {
        set s [$w get sel.first sel.last]
        if {$s ne "" && [string first \n $s] < 0} { set ::els::find_q $s }
    }
    els::find_update
    focus .find.fr.q
    .find.fr.q selection range 0 end
}

proc els::find_hide {} {
    variable find_mode ; variable find_matches ; variable find_current
    variable find_after
    set find_mode ""
    # a pending debounced search would otherwise fire ~130 ms after dismissal,
    # re-tagging the buffer and teleporting the caret to a match
    after cancel $find_after
    set find_after ""
    els::find_cancel hidden
    els::find_output_abort
    els::find_result_drop
    els::find_snapshot_drop
    # drop the cached spans: they are plain string indices that do not float
    # with edits, and F3 on a hidden bar must never jump to (or replace) stale
    # coordinates — possibly in a different document
    set find_matches {}
    set find_current -1
    grid remove .find
    set w [els::T]
    if {$w ne ""} {
        $w tag remove findAll 1.0 end
        $w tag remove findOne 1.0 end
        focus $w
    }
}

proc els::find_worker_spec {} {
    # A blank literal query means "no search".  In Regex mode it is the valid
    # empty expression, matching every character boundary just like Tcl regsub.
    if {$::els::find_q eq "" && !$::els::find_regex} { return "" }
    set pat $::els::find_q
    set regexMode $::els::find_regex
    if {!$regexMode} { set pat [els::re_escape $pat] }
    if {$::els::find_word} {
        if {$::els::find_regex} {
            set pat "\\m(?:$pat)\\M"
        } else {
            set L ""; if {[regexp {^[[:alnum:]_]} $::els::find_q]} { set L {\m} }
            set R ""; if {[regexp {[[:alnum:]_]$} $::els::find_q]} { set R {\M} }
            set pat "${L}(?:$pat)${R}"
        }
    }
    return [dict create pattern $pat nocase [expr {!$::els::find_case}] \
        regex_mode $regexMode]
}

proc els::find_signature {{kind search}} {
    set sig [list $::els::find_q $::els::find_case $::els::find_word $::els::find_regex]
    if {$kind ne "search"} { lappend sig $::els::find_r $::els::find_adapt }
    return $sig
}

proc els::find_set_all_button {busy} {
    set ::els::find_replace_all_busy [expr {$busy ? 1 : 0}]
    if {![winfo exists .find.rr.all]} { return }
    if {$::els::find_replace_all_busy} {
        .find.rr.all configure -text Cancel -command {els::find_cancel user}
    } else {
        .find.rr.all configure -text All -command els::find_all_action
    }
}

proc els::find_finish_kind {kind} {
    if {$kind eq "replace-all"} { els::find_set_all_button 0 }
}

proc els::find_pending_drop {} {
    set kind ""
    if {$::els::find_pending ne "" && [dict exists $::els::find_pending kind]} {
        set kind [dict get $::els::find_pending kind]
    }
    set ::els::find_pending {}
    els::find_finish_kind $kind
}

proc els::find_pending_fail {message} {
    els::find_pending_drop
    set ::els::find_count $message
}

proc els::find_reap_tick {} {
    set ::els::find_reap_after ""
    set keep {}
    set now [clock milliseconds]
    foreach job $::els::find_retired {
        if {![dict exists $job watch] || [dict get $job watch] eq ""} {
            if {$now < [dict get $job no_watch_until]} { lappend keep $job } \
            else { els::find_cleanup_job $job }
            continue
        }
        if {[catch {els::win_worker_status [dict get $job watch]} status]} {
            lappend keep $job
        } elseif {$status eq "running"} {
            lappend keep $job
        } else {
            els::find_cleanup_job $job
        }
    }
    set ::els::find_retired $keep
    if {[llength $keep]} { set ::els::find_reap_after [after 25 els::find_reap_tick] }
}

proc els::find_retire_job {job {kill 1}} {
    if {$job eq ""} { return }
    if {[dict exists $job watch] && [dict get $job watch] ne ""} {
        if {$kill} { catch {els::win_worker_kill [dict get $job watch]} }
    } elseif {![dict exists $job no_watch_until]} {
        dict set job no_watch_until [expr {[clock milliseconds] + 5500}]
    }
    lappend ::els::find_retired $job
    if {$::els::find_reap_after eq ""} {
        set ::els::find_reap_after [after 0 els::find_reap_tick]
    }
}

proc els::find_replacement_in_flight {} {
    if {$::els::find_replace_all_busy} { return 1 }
    if {$::els::find_pending ne "" \
            && [dict get $::els::find_pending kind] ne "search"} { return 1 }
    if {$::els::find_job ne "" \
            && [dict get $::els::find_job kind] ne "search"} { return 1 }
    if {$::els::find_validation ne "" \
            && [dict get [dict get $::els::find_validation job] kind] ne "search"} { return 1 }
    if {$::els::find_output_read ne ""} { return 1 }
    return 0
}

proc els::find_restore_search {message} {
    if {$::els::find_mode eq ""} { return }
    set ::els::find_count $message
    if {$::els::active ne "" && [info exists ::els::docEpoch($::els::active)] \
            && [els::find_worker_spec] ne ""} { els::find_schedule }
}

proc els::find_cancel {{reason cancel}} {
    set restoreSearch [els::find_replacement_in_flight]
    set ::els::find_pending {}
    if {$::els::find_poll_after ne ""} {
        after cancel $::els::find_poll_after
        set ::els::find_poll_after ""
    }
    if {$::els::find_job ne ""} {
        els::find_retire_job $::els::find_job 1
        set ::els::find_job {}
    }
    els::find_validation_abort
    els::find_output_abort
    els::find_set_all_button 0
    if {$restoreSearch && $reason in {user changed}} {
        els::find_restore_search "Cancelled"
    } elseif {$reason eq "user" && $::els::find_mode ne ""} {
        set ::els::find_count "Cancelled"
    }
    # A replace that was actually running gets silently torn down by a passive
    # event -- a tab switch/close (context), closing the find bar (hidden), a
    # user edit (edit), or changing the query (superseded) -- and the find-count
    # label is immediately overwritten by the new context/search.  Leave a durable
    # status-bar note so the user is never left believing a replace completed (R08).
    if {$restoreSearch && $reason in {context hidden edit superseded}} {
        catch {els::status_note "Replace cancelled"}
    }
}

proc els::find_validation_abort {} {
    if {$::els::find_validation_after ne ""} {
        after cancel $::els::find_validation_after
        set ::els::find_validation_after ""
    }
    if {$::els::find_validation ne ""} {
        set v $::els::find_validation
        if {[dict exists $v chan]} { catch {close [dict get $v chan]} }
        if {[dict exists $v job]} { els::find_cleanup_job [dict get $v job] }
        set ::els::find_validation {}
    }
}

proc els::find_output_abort {} {
    if {$::els::find_output_after ne ""} {
        after cancel $::els::find_output_after
        set ::els::find_output_after ""
    }
    if {$::els::find_output_read ne ""} {
        set o $::els::find_output_read
        if {[dict exists $o chan]} { catch {close [dict get $o chan]} }
        if {[dict exists $o job]} { els::find_cleanup_job [dict get $o job] }
        set ::els::find_output_read {}
    }
    els::find_set_all_button 0
}

proc els::find_context_leave {id} {
    incr ::els::find_generation
    els::find_cancel context
    els::find_result_drop
    els::find_snapshot_drop
}

proc els::find_doc_mutated {id} {
    if {$::els::find_snapshot ne "" && [dict get $::els::find_snapshot doc] eq $id} {
        els::find_snapshot_drop
    } elseif {$::els::find_snapshot_build ne "" \
            && [dict get $::els::find_snapshot_build doc] eq $id} {
        els::find_snapshot_abort
    }
    if {$::els::find_applying} { return }
    if {$id eq $::els::active && $::els::find_mode ne ""} {
        incr ::els::find_generation
        els::find_cancel edit
        els::find_result_drop
        set w [els::W $id]
        catch {$w tag remove findAll 1.0 end}
        catch {$w tag remove findOne 1.0 end}
        els::find_schedule
    }
}

proc els::find_doc_closed {id} {
    if {$id eq $::els::active} { els::find_context_leave $id }
}

proc els::find_replacement_changed {} {
    if {[els::find_replacement_in_flight]} {
        incr ::els::find_generation
        els::find_cancel changed
    }
}

proc els::find_snapshot_ensure {} {
    if {$::els::find_pending eq ""} { return }
    set p $::els::find_pending
    set id [dict get $p doc]
    set epoch [dict get $p epoch]
    if {$::els::find_snapshot ne "" \
            && [dict get $::els::find_snapshot doc] eq $id \
            && [dict get $::els::find_snapshot epoch] == $epoch \
            && [els::find_snapshot_path_ok [dict get $::els::find_snapshot path]]} {
        els::find_start_worker $p
        return
    }
    if {$::els::find_snapshot_build ne "" \
            && [dict get $::els::find_snapshot_build doc] eq $id \
            && [dict get $::els::find_snapshot_build epoch] == $epoch} { return }
    els::find_snapshot_drop
    set root [els::find_root]
    set w [els::W $id]
    if {$root eq "" || ![winfo exists $w]} {
        els::find_pending_fail "Find unavailable"
        return
    }
    set chars [lindex [$w count -chars 1.0 "end - 1 char"] 0]
    if {$chars > $::els::FIND_INPUT_MAX} {
        els::find_pending_fail "Document too large to search"
        return
    }
    set token [els::find_token]
    set path [file join $root "snapshot-[els::session_id]-$token.utf8"]
    set tmp "$path.tmp-[pid]-[clock clicks]"
    if {[catch {set f [::open $tmp {WRONLY CREAT EXCL TRUNC}]} err]} {
        els::find_pending_fail "Find unavailable"
        return
    }
    fconfigure $f -translation binary
    if {![els::find_path_plain $root directory] || ![els::find_snapshot_path_ok $tmp 1]} {
        catch {close $f}
        catch {file delete $tmp}
        els::find_pending_fail "Find unavailable"
        return
    }
    set ::els::find_snapshot_build [dict create doc $id epoch $epoch path $path tmp $tmp \
        chan $f offset 0 chars $chars bytes 0 crc 0]
    set ::els::find_snapshot_after [after idle els::find_snapshot_step]
}

proc els::find_snapshot_step {} {
    set ::els::find_snapshot_after ""
    if {$::els::find_snapshot_build eq ""} { return }
    if {$::els::swap_suspend} {
        set ::els::find_snapshot_after [after 20 els::find_snapshot_step]
        return
    }
    set b $::els::find_snapshot_build
    set id [dict get $b doc]
    set w [els::W $id]
    if {![winfo exists $w] || ![info exists ::els::docEpoch($id)] \
            || $::els::docEpoch($id) != [dict get $b epoch]} {
        els::find_snapshot_abort
        els::find_pending_drop
        if {$id eq $::els::active && $::els::find_mode ne ""} { els::find_schedule }
        return
    }
    set offset [dict get $b offset]
    set chars [dict get $b chars]
    if {$offset < $chars} {
        set take [expr {min($::els::FIND_SLICE_CHARS, $chars - $offset)}]
        if {[catch {
            set text [$w get "1.0 + $offset chars" "1.0 + [expr {$offset + $take}] chars"]
            set raw [encoding convertto -profile strict utf-8 $text]
        } err]} {
            els::find_snapshot_abort
            els::find_pending_fail "Document cannot be encoded for search"
            return
        }
        set bytes [expr {[dict get $b bytes] + [string length $raw]}]
        if {$bytes > $::els::FIND_INPUT_MAX} {
            els::find_snapshot_abort
            els::find_pending_fail "Document too large to search"
            return
        }
        if {[catch {puts -nonewline [dict get $b chan] $raw}]} {
            set ::els::find_snapshot_build $b
            els::find_snapshot_abort
            els::find_pending_fail "Find snapshot write failed"
            return
        }
        dict set b bytes $bytes
        dict set b crc [zlib crc32 $raw [dict get $b crc]]
        dict set b offset [expr {$offset + $take}]
        set ::els::find_snapshot_build $b
        set ::els::find_snapshot_after [after idle els::find_snapshot_step]
        return
    }
    if {[catch {close [dict get $b chan]}]} {
        set ::els::find_snapshot_build $b
        els::find_snapshot_abort
        els::find_pending_fail "Find snapshot write failed"
        return
    }
    dict unset b chan
    if {![info exists ::els::docEpoch($id)] || $::els::docEpoch($id) != [dict get $b epoch]} {
        set ::els::find_snapshot_build $b
        els::find_snapshot_abort
        els::find_pending_drop
        if {$id eq $::els::active && $::els::find_mode ne ""} { els::find_schedule }
        return
    }
    if {![els::find_snapshot_path_ok [dict get $b tmp] 1] \
            || [catch {file rename [dict get $b tmp] [dict get $b path]}] \
            || ![els::find_snapshot_path_ok [dict get $b path]]} {
        set ::els::find_snapshot_build $b
        els::find_snapshot_abort
        els::find_pending_fail "Find unavailable"
        return
    }
    set ::els::find_snapshot [dict create doc $id epoch [dict get $b epoch] \
        path [dict get $b path] chars $chars bytes [dict get $b bytes] crc [dict get $b crc]]
    set ::els::find_snapshot_build {}
    if {$::els::find_pending ne ""} { els::find_start_worker $::els::find_pending }
}

proc els::find_start_worker {pending} {
    if {$pending eq ""} { return }
    if {[dict get $pending generation] != $::els::find_generation} {
        if {$::els::find_pending eq $pending} { els::find_pending_drop }
        return
    }
    set snap $::els::find_snapshot
    if {$snap eq "" || [dict get $snap doc] ne [dict get $pending doc] \
            || [dict get $snap epoch] != [dict get $pending epoch] \
            || ![els::find_snapshot_path_ok [dict get $snap path]]} {
        els::find_snapshot_ensure
        return
    }
    if {![els::find_native_ready]} {
        els::find_pending_fail "Find unavailable (worker control missing)"
        return
    }
    set root [els::find_root]
    if {$root eq ""} { els::find_pending_fail "Find unavailable" ; return }
    set seq [incr ::els::find_job_seq]
    set token [els::find_token]
    set dir [file join $root [els::find_job_dir_name $seq $token]]
    if {[catch {file mkdir $dir} err] || [els::find_job_dir_ok $dir] eq ""} {
        els::find_pending_fail "Find unavailable"
        return
    }
    set job [dict merge $pending [dict create dir $dir token $token watch "" started [clock milliseconds]]]
    set linked 0
    if {![catch {file link -hard [file join $dir snapshot.utf8] [dict get $snap path]}]} {
        set linked 1
    } elseif {![catch {file copy [dict get $snap path] [file join $dir snapshot.utf8]}]} {
        set linked 1
    }
    if {!$linked || ![els::find_job_file_ok $job snapshot.utf8] \
            || [catch {file size [file join $dir snapshot.utf8]} snapSize] \
            || $snapSize != [dict get $snap bytes]} {
        els::find_cleanup_job $job
        els::find_pending_fail "Find unavailable"
        return
    }
    set kind [dict get $pending kind]
    set deadline [expr {$kind eq "search" ? $::els::FIND_SEARCH_MS : $::els::FIND_REPLACE_MS}]
    set request [dict create version $::elsworker::VERSION token $token kind $kind \
        pattern [dict get $pending pattern] nocase [dict get $pending nocase] \
        regex_mode [dict get $pending regex_mode] replacement [dict get $pending replacement] \
        adapt [dict get $pending adapt] source_chars [dict get $snap chars] \
        source_bytes [dict get $snap bytes] source_crc [dict get $snap crc] \
        match_limit $::els::FIND_MAXINDEX output_limit $::els::FIND_OUTPUT_MAX \
        deadline_ms $deadline hint_start [dict get $pending hint_start] hint_end [dict get $pending hint_end]]
    if {[catch {els::find_write_control [file join $dir request.dict] $request} err]} {
        els::find_cleanup_job $job
        els::find_pending_fail "Find unavailable"
        return
    }
    if {![els::find_job_file_ok $job request.dict]} {
        els::find_cleanup_job $job
        els::find_pending_fail "Find unavailable"
        return
    }
    set cmd [concat [els::find_worker_command] [list $dir $token]]
    set cwd [file dirname [lindex $cmd 0]]
    if {[catch {set watch [els::win_worker_spawn_watch $cmd $cwd]} err] \
            || ![string match {worker-*} $watch]} {
        els::find_cleanup_job $job
        els::find_pending_fail "Find unavailable"
        return
    }
    dict set job watch $watch
    dict set job deadline_at [expr {[clock milliseconds] + $deadline + 1000}]
    if {[catch {els::find_write_control [file join $dir go] \
            [dict create version $::elsworker::VERSION token $token command go]} err]} {
        els::find_retire_job $job 1
        els::find_pending_fail "Find unavailable"
        return
    }
    if {![els::find_job_file_ok $job go]} {
        els::find_retire_job $job 1
        els::find_pending_fail "Find unavailable"
        return
    }
    set ::els::find_job $job
    set ::els::find_pending {}
    set ::els::find_poll_after [after 20 els::find_poll]
}

proc els::find_poll {} {
    set ::els::find_poll_after ""
    if {$::els::find_job eq ""} { return }
    set now [clock milliseconds]
    set job $::els::find_job
    if {$now > [dict get $job deadline_at]} {
        set ::els::find_job {}
        els::find_retire_job $job 1
        els::find_finish_kind [dict get $job kind]
        set ::els::find_count "Search timed out"
        if {[dict get $job kind] ne "search"} {
            els::find_restore_search "Search timed out"
        }
        return
    }
    if {[catch {els::win_worker_status [dict get $job watch]} status]} {
        set ::els::find_job {}
        els::find_retire_job $job 1
        els::find_finish_kind [dict get $job kind]
        set ::els::find_count "Find worker failed"
        if {[dict get $job kind] ne "search"} {
            els::find_restore_search "Find worker failed"
        }
        return
    }
    if {$status eq "running"} {
        set ::els::find_poll_after [after 20 els::find_poll]
        return
    }
    if {[llength $status] != 2 || [lindex $status 0] ne "exited" \
            || ![string is entier -strict [lindex $status 1]] \
            || [lindex $status 1] < 0} {
        set ::els::find_job {}
        els::find_retire_job $job 1
        els::find_finish_kind [dict get $job kind]
        set ::els::find_count "Find worker failed"
        if {[dict get $job kind] ne "search"} {
            els::find_restore_search "Find worker failed"
        }
        return
    }
    set ::els::find_job {}
    set exitCode [lindex $status 1]
    els::find_process_result $job $exitCode
}

proc els::find_result_fail {job message} {
    els::find_cleanup_job $job
    els::find_finish_kind [dict get $job kind]
    if {[dict get $job generation] == $::els::find_generation && $::els::find_mode ne ""} {
        set ::els::find_count $message
        if {[dict get $job kind] ne "search"} { els::find_restore_search $message }
    }
}

proc els::find_process_result {job exitCode} {
    if {[dict get $job generation] != $::els::find_generation \
            || [dict get $job doc] ne $::els::active \
            || ![info exists ::els::docEpoch([dict get $job doc])] \
            || $::els::docEpoch([dict get $job doc]) != [dict get $job epoch]} {
        els::find_cleanup_job $job
        els::find_finish_kind [dict get $job kind]
        return
    }
    set path [file join [dict get $job dir] result.ready]
    set keys {changed_count error kind match_bytes match_count match_crc match_truncated \
        output_bytes output_chars output_crc source_bytes source_chars source_crc status token version}
    if {[catch {
        if {![els::find_job_file_ok $job result.ready]} { error "result is not a plain job file" }
        set raw [::elsworker::read_regular $path $::elsworker::CONTROL_MAX]
        set result [::elsworker::exact_dict [::elsworker::decode_utf8 $raw] $keys]
        if {[dict get $result version] != $::elsworker::VERSION \
                || [dict get $result token] ne [dict get $job token] \
                || [dict get $result kind] ne [dict get $job kind]} { error "result identity mismatch" }
        foreach k {changed_count match_bytes match_count match_crc match_truncated output_bytes \
                    output_chars output_crc source_bytes source_chars source_crc} {
            if {![string is entier -strict [dict get $result $k]] || [dict get $result $k] < 0} {
                error "invalid result number"
            }
        }
        set status [dict get $result status]
        set resultKind [dict get $result kind]
        set count [dict get $result match_count]
        set bytes [dict get $result match_bytes]
        set truncated [dict get $result match_truncated]
        set changed [dict get $result changed_count]
        set outputBytes [dict get $result output_bytes]
        set outputChars [dict get $result output_chars]
        set outputCrc [dict get $result output_crc]
        if {$status ni {ok bad-pattern limit stale error} \
                || [string length [dict get $result error]] > 4096 \
                || $truncated ni {0 1} \
                || $count > $::els::FIND_MAXINDEX \
                || $bytes != $count * $::els::FIND_RECORD_BYTES \
                || $changed > $count \
                || [dict get $result match_crc] > 0xffffffff \
                || $outputCrc > 0xffffffff \
                || [dict get $result source_crc] > 0xffffffff \
                || $outputBytes > $::els::FIND_OUTPUT_MAX \
                || $outputChars > $::els::FIND_OUTPUT_MAX \
                || $outputChars > $outputBytes \
                || ($truncated && $count != $::els::FIND_MAXINDEX)} {
            error "result invariant mismatch"
        }
        if {[dict get $result source_chars] != [dict get $::els::find_snapshot chars] \
                || [dict get $result source_bytes] != [dict get $::els::find_snapshot bytes] \
                || [dict get $result source_crc] != [dict get $::els::find_snapshot crc]} {
            error "result source mismatch"
        }
        set outputPath [file join [dict get $job dir] replacement.utf8]
        set outputPresent [expr {![catch {file lstat $outputPath outputStat}]}]
        if {$outputPresent && ![els::find_job_file_ok $job replacement.utf8]} {
            error "replacement output is not a plain job file"
        }
        if {$status ne "ok"} {
            if {$changed != 0 || $outputBytes != 0 || $outputChars != 0 \
                    || $outputCrc != 0 || $outputPresent} {
                error "failed result contains replacement output"
            }
            switch -- $status {
                bad-pattern {
                    if {$count != 0 || $truncated} { error "bad-pattern result invariant mismatch" }
                }
                stale {
                    if {$resultKind ne "replace-one" || $count != 0 || $truncated} {
                        error "stale result invariant mismatch"
                    }
                }
                limit {
                    if {$resultKind ne "replace-all" || !$truncated \
                            || $count != $::els::FIND_MAXINDEX} {
                        error "limit result invariant mismatch"
                    }
                }
            }
        } else {
            if {[dict get $result error] ne ""} { error "successful result contains an error" }
            switch -- $resultKind {
                search {
                    if {$changed != 0 || $outputBytes != 0 || $outputChars != 0 \
                            || $outputCrc != 0 || $outputPresent} {
                        error "search result contains replacement output"
                    }
                }
                replace-one {
                    if {$count != 1 || $truncated || !$outputPresent} {
                        error "replace-one result invariant mismatch"
                    }
                }
                replace-all {
                    if {$truncated || !$outputPresent} {
                        error "replace-all result invariant mismatch"
                    }
                }
            }
        }
    } err]} {
        els::find_result_fail $job "Find worker returned invalid data"
        return
    }
    set status [dict get $result status]
    if {$status ne "ok" || $exitCode != 0} {
        switch -- $status {
            bad-pattern { set message "bad pattern" }
            limit       { set message "Too many matches" }
            stale       { set message "Search changed" }
            default     { set message "Find worker failed" }
        }
        els::find_result_fail $job $message
        return
    }
    set count [dict get $result match_count]
    set bytes [dict get $result match_bytes]
    set idx [file join [dict get $job dir] matches.idx]
    if {![els::find_job_file_ok $job matches.idx] \
            || [catch {file size $idx} idxSize] || $idxSize != $bytes} {
        els::find_result_fail $job "Find worker returned invalid data"
        return
    }
    if {[catch {set f [::open $idx rb]}]} {
        els::find_result_fail $job "Find worker returned invalid data"
        return
    }
    set ::els::find_validation [dict create job $job result $result chan $f bytes 0 crc 0 \
        carry "" records 0 prev_start -1 prev_end -1]
    set ::els::find_validation_after [after idle els::find_validation_step]
}

proc els::find_decimal {digits} {
    if {![regexp {^[0-9]{20}$} $digits]} { error "invalid fixed decimal" }
    set ceiling [format %020d $::els::FIND_INPUT_MAX]
    if {[string compare $digits $ceiling] > 0} { error "fixed decimal exceeds source limit" }
    set trimmed [string trimleft $digits 0]
    if {$trimmed eq ""} { return 0 }
    if {[scan $trimmed %d value] != 1} { error "invalid fixed decimal" }
    return $value
}

proc els::find_validation_step {} {
    set ::els::find_validation_after ""
    if {$::els::find_validation eq ""} { return }
    if {$::els::swap_suspend} {
        set ::els::find_validation_after [after 20 els::find_validation_step]
        return
    }
    set v $::els::find_validation
    if {[catch {set chunk [read [dict get $v chan] $::els::FIND_SLICE_BYTES]}]} {
        catch {close [dict get $v chan]}
        set ::els::find_validation {}
        els::find_result_fail [dict get $v job] "Find worker returned invalid data"
        return
    }
    if {$chunk ne ""} {
        dict incr v bytes [string length $chunk]
        dict set v crc [zlib crc32 $chunk [dict get $v crc]]
        set data "[dict get $v carry]$chunk"
        set pos 0
        set n [string length $data]
        while {$n - $pos >= $::els::FIND_RECORD_BYTES} {
            set rec [string range $data $pos [expr {$pos + $::els::FIND_RECORD_BYTES - 1}]]
            if {![regexp {^([0-9]{20}) ([0-9]{20})\n$} $rec -> sd ed]} {
                catch {close [dict get $v chan]}
                set ::els::find_validation {}
                els::find_result_fail [dict get $v job] "Find worker returned invalid data"
                return
            }
            if {[catch {
                set s [els::find_decimal $sd]
                set e [els::find_decimal $ed]
            }]} {
                catch {close [dict get $v chan]}
                set ::els::find_validation {}
                els::find_result_fail [dict get $v job] "Find worker returned invalid data"
                return
            }
            set sourceChars [dict get [dict get $v result] source_chars]
            set records [dict get $v records]
            if {$s < 0 || $e < $s || $e > $sourceChars \
                    || ($records > 0 && (([dict get $v prev_start] == [dict get $v prev_end] && $s <= [dict get $v prev_start]) \
                    || ([dict get $v prev_start] != [dict get $v prev_end] && $s < [dict get $v prev_end])))} {
                catch {close [dict get $v chan]}
                set ::els::find_validation {}
                els::find_result_fail [dict get $v job] "Find worker returned invalid data"
                return
            }
            set job [dict get $v job]
            if {$records == 0 && [dict get $job kind] eq "replace-one" \
                    && ($s != [dict get $job hint_start] \
                        || $e != [dict get $job hint_end])} {
                catch {close [dict get $v chan]}
                set ::els::find_validation {}
                els::find_result_fail $job "Find worker returned invalid data"
                return
            }
            dict set v prev_start $s
            dict set v prev_end $e
            dict incr v records
            incr pos $::els::FIND_RECORD_BYTES
        }
        dict set v carry [string range $data $pos end]
        set ::els::find_validation $v
        set ::els::find_validation_after [after idle els::find_validation_step]
        return
    }
    if {[catch {close [dict get $v chan]}]} {
        set ::els::find_validation {}
        els::find_result_fail [dict get $v job] "Find worker returned invalid data"
        return
    }
    set result [dict get $v result]
    if {[dict get $v carry] ne "" || [dict get $v records] != [dict get $result match_count] \
            || [dict get $v bytes] != [dict get $result match_bytes] \
            || [dict get $v crc] != [dict get $result match_crc]} {
        set ::els::find_validation {}
        els::find_result_fail [dict get $v job] "Find worker returned invalid data"
        return
    }
    set ::els::find_validation {}
    els::find_result_verified [dict get $v job] $result
}

proc els::find_result_verified {job result} {
    if {[dict get $job generation] != $::els::find_generation \
            || [dict get $job doc] ne $::els::active \
            || $::els::docEpoch([dict get $job doc]) != [dict get $job epoch] \
            || [find_signature [dict get $job kind]] ne [dict get $job signature]} {
        els::find_cleanup_job $job
        els::find_finish_kind [dict get $job kind]
        return
    }
    if {[dict get $job kind] eq "search"} {
        els::find_adopt_search $job $result
    } else {
        els::find_output_start $job $result
    }
}

proc els::find_record_offsets {path ordinal} {
    if {$ordinal < 0} { error "negative match ordinal" }
    if {![els::find_path_plain $path file]} { error "match index is not a plain file" }
    set f [::open $path rb]
    try {
        seek $f [expr {$ordinal * $::els::FIND_RECORD_BYTES}] start
        set rec [read $f $::els::FIND_RECORD_BYTES]
    } finally { close $f }
    if {![regexp {^([0-9]{20}) ([0-9]{20})\n$} $rec -> sd ed]} { error "invalid match record" }
    return [list [els::find_decimal $sd] [els::find_decimal $ed]]
}

proc els::find_nearest_ordinal {offset} {
    set lo 0
    set hi [expr {$::els::find_total - 1}]
    set answer 0
    while {$lo <= $hi} {
        set mid [expr {($lo + $hi) / 2}]
        lassign [els::find_record_offsets $::els::find_index_path $mid] s e
        if {$s >= $offset} { set answer $mid ; set hi [expr {$mid - 1}] } \
        else { set lo [expr {$mid + 1}] }
    }
    return $answer
}

proc els::find_adopt_search {job result} {
    set count [dict get $result match_count]
    set ::els::find_truncated [expr {$count > $::els::FIND_MAXHITS}]
    set ::els::find_index_truncated [dict get $result match_truncated]
    set w [els::W [dict get $job doc]]
    $w tag remove findAll 1.0 end
    $w tag remove findOne 1.0 end
    set ::els::find_matches {}
    if {$count == 0} {
        set ::els::find_count "No results"
        els::find_cleanup_job $job
        return
    }
    set ::els::find_result_job $job
    set ::els::find_index_path [file join [dict get $job dir] matches.idx]
    set ::els::find_total $count
    set insertOffset [lindex [$w count -chars 1.0 insert] 0]
    if {[catch {set current [els::find_nearest_ordinal $insertOffset]}]} {
        els::find_result_drop
        set ::els::find_count "Find index unavailable"
        return
    }
    els::find_highlight $current
    set limit [expr {min($count, $::els::FIND_MAXHITS)}]
    set ::els::find_highlight_state [dict create job $job ordinal 0 limit $limit]
    set ::els::find_highlight_after [after idle els::find_highlight_step]
}

proc els::find_highlight_step {} {
    set ::els::find_highlight_after ""
    if {$::els::find_highlight_state eq ""} { return }
    if {$::els::swap_suspend} {
        set ::els::find_highlight_after [after 20 els::find_highlight_step]
        return
    }
    set h $::els::find_highlight_state
    set job [dict get $h job]
    if {$::els::find_result_job eq "" || [dict get $job generation] != $::els::find_generation \
            || [dict get $job doc] ne $::els::active} {
        set ::els::find_highlight_state {}
        return
    }
    set w [els::W [dict get $job doc]]
    set ordinal [dict get $h ordinal]
    set stop [expr {min([dict get $h limit], $ordinal + 250)}]
    set ranges {}
    for {set i $ordinal} {$i < $stop} {incr i} {
        if {[catch {lassign [els::find_record_offsets $::els::find_index_path $i] s e}]} {
            set ::els::find_highlight_state {}
            els::find_result_drop
            set ::els::find_count "Find index unavailable"
            return
        }
        set si [$w index "1.0 + $s chars"]
        set ei [$w index "1.0 + $e chars"]
        lappend ::els::find_matches [list $si $ei]
        if {$e > $s} { lappend ranges $si $ei }
    }
    if {[llength $ranges]} { $w tag add findAll {*}$ranges }
    dict set h ordinal $stop
    set ::els::find_highlight_state $h
    if {$stop < [dict get $h limit]} {
        set ::els::find_highlight_after [after idle els::find_highlight_step]
    } else {
        set ::els::find_highlight_state {}
    }
}

proc els::find_output_start {job result} {
    set path [file join [dict get $job dir] replacement.utf8]
    if {![els::find_job_file_ok $job replacement.utf8] \
            || [catch {file size $path} outputSize] \
            || $outputSize != [dict get $result output_bytes] \
            || [dict get $result output_bytes] > $::els::FIND_OUTPUT_MAX} {
        els::find_result_fail $job "Find worker returned invalid data"
        return
    }
    if {[catch {set f [::open $path rb]}]} {
        els::find_result_fail $job "Find worker returned invalid data"
        return
    }
    set ::els::find_output_read [dict create job $job result $result chan $f \
        bytes 0 crc 0 carry "" text ""]
    set ::els::find_output_after [after idle els::find_output_step]
}

proc els::find_decode_chunk {data final} {
    if {$final} {
        return [list [encoding convertfrom -profile strict utf-8 $data] ""]
    }
    set n [string length $data]
    for {set trim 0} {$trim <= 3 && $trim <= $n} {incr trim} {
        if {$trim == 0} {
            set body $data; set tail ""
        } else {
            set body [string range $data 0 end-$trim]
            set tail [string range $data end-[expr {$trim - 1}] end]
        }
        if {![catch {set text [encoding convertfrom -profile strict utf-8 $body]}]} {
            return [list $text $tail]
        }
    }
    error "invalid UTF-8 in replacement output"
}

proc els::find_output_step {} {
    set ::els::find_output_after ""
    if {$::els::find_output_read eq ""} { return }
    if {$::els::swap_suspend} {
        set ::els::find_output_after [after 20 els::find_output_step]
        return
    }
    set o $::els::find_output_read
    if {[catch {set chunk [read [dict get $o chan] $::els::FIND_SLICE_BYTES]}]} {
        catch {close [dict get $o chan]}
        set ::els::find_output_read {}
        els::find_result_fail [dict get $o job] "Find worker returned invalid data"
        return
    }
    if {$chunk ne ""} {
        dict incr o bytes [string length $chunk]
        dict set o crc [zlib crc32 $chunk [dict get $o crc]]
        if {[catch {lassign [els::find_decode_chunk "[dict get $o carry]$chunk" 0] text carry}]} {
            catch {close [dict get $o chan]}
            set ::els::find_output_read {}
            els::find_result_fail [dict get $o job] "Find worker returned invalid data"
            return
        }
        dict append o text $text
        dict set o carry $carry
        set ::els::find_output_read $o
        set ::els::find_output_after [after idle els::find_output_step]
        return
    }
    if {[catch {close [dict get $o chan]}]} {
        set ::els::find_output_read {}
        els::find_result_fail [dict get $o job] "Find worker returned invalid data"
        return
    }
    if {[catch {lassign [els::find_decode_chunk [dict get $o carry] 1] tail _}]} {
        set ::els::find_output_read {}
        els::find_result_fail [dict get $o job] "Find worker returned invalid data"
        return
    }
    dict append o text $tail
    set result [dict get $o result]
    set text [dict get $o text]
    set ::els::find_output_read {}
    if {[dict get $o bytes] != [dict get $result output_bytes] \
            || [dict get $o crc] != [dict get $result output_crc] \
            || [string length $text] != [dict get $result output_chars]} {
        els::find_result_fail [dict get $o job] "Find worker returned invalid data"
        return
    }
    els::find_commit_replacement [dict get $o job] $result $text
}

proc els::find_commit_replacement {job result output} {
    set id [dict get $job doc]
    if {$id ne $::els::active || ![info exists ::els::docEpoch($id)] \
            || $::els::docEpoch($id) != [dict get $job epoch] \
            || [els::find_signature [dict get $job kind]] ne [dict get $job signature] \
            || $::els::find_mode eq ""} {
        els::find_cleanup_job $job
        els::find_finish_kind [dict get $job kind]
        return
    }
    set n [dict get $result changed_count]
    set kind [dict get $job kind]
    set w [els::W $id]
    if {$kind eq "replace-one"} {
        set start [dict get $job hint_start]
        set end [dict get $job hint_end]
        set si [$w index "1.0 + $start chars"]
        set ei [$w index "1.0 + $end chars"]
        set unchanged [expr {[$w get $si $ei] eq $output}]
    } else {
        set unchanged [expr {[$w get 1.0 "end - 1 char"] eq $output}]
    }
    if {$unchanged} { set n 0 }
    if {$n == 0} {
        els::find_cleanup_job $job
        els::find_finish_kind $kind
        if {$kind eq "replace-all"} {
            set ::els::find_count "Replaced 0"
        } else {
            # Replace still advances when the replacement is identical.  Move
            # the caret beyond this span (or wrap a terminal zero-width match),
            # then rebuild a complete search/index so F3 never strands on the
            # discarded pre-replacement result.
            set next $end
            if {$end == $start} {
                if {$start < [dict get $result source_chars]} {
                    set next [expr {$start + 1}]
                } else {
                    set next 0
                }
            }
            $w mark set insert "1.0 + $next chars"
            els::find_request search
        }
        return
    }
    set oldAuto [$w cget -autoseparators]
    set rc [catch {
        $w configure -autoseparators 0
        $w edit separator
        set ::els::find_applying 1
        if {$kind eq "replace-one"} {
            $w replace $si $ei $output
            $w mark set insert "$si + [string length $output] chars"
        } else {
            $w replace 1.0 "end - 1 char" $output
        }
        set ::els::find_applying 0
        $w edit separator
    } err opts]
    set ::els::find_applying 0
    catch {$w configure -autoseparators $oldAuto}
    els::find_cleanup_job $job
    els::find_finish_kind $kind
    if {$rc} {
        set ::els::find_count "Replace failed"
        return
    }
    els::find_result_drop
    if {$kind eq "replace-all"} {
        set ::els::find_count "Replaced $n"
    } else {
        els::find_request search
    }
}

proc els::find_request {kind {hintStart 0} {hintEnd 0}} {
    if {$::els::find_mode eq ""} { return }
    set id $::els::active
    if {$id eq "" || ![info exists ::els::docEpoch($id)]} { return }
    # An explicit request supersedes any edit/key debounce already in flight.
    # Otherwise that old timer can fire while a replacement worker is running,
    # increment the generation, and correctly-but-surprisingly reject the
    # replacement as stale.
    after cancel $::els::find_after
    set ::els::find_after ""
    incr ::els::find_generation
    els::find_cancel superseded
    els::find_result_drop
    set w [els::W $id]
    catch {$w tag remove findAll 1.0 end}
    catch {$w tag remove findOne 1.0 end}
    set spec [els::find_worker_spec]
    if {$spec eq ""} { set ::els::find_count "" ; return }
    if {[catch {
        set pbytes [string length [encoding convertto -profile strict utf-8 [dict get $spec pattern]]]
        set rbytes [string length [encoding convertto -profile strict utf-8 $::els::find_r]]
    }] || $pbytes > $::elsworker::FIELD_MAX || $rbytes > $::elsworker::FIELD_MAX} {
        set ::els::find_count "Search field too large"
        return
    }
    set ::els::find_pending [dict merge $spec [dict create generation $::els::find_generation \
        doc $id epoch $::els::docEpoch($id) signature [els::find_signature $kind] kind $kind \
        replacement $::els::find_r adapt $::els::find_adapt \
        hint_start $hintStart hint_end $hintEnd]]
    if {$kind eq "replace-all"} { els::find_set_all_button 1 }
    set ::els::find_count [expr {$kind eq "search" ? "Searching..." : "Replacing..."}]
    els::find_snapshot_ensure
}

proc els::find_test_wait {{limit 35000}} {
    if {!$::els::find_test_sync} { return }
    set until [expr {[clock milliseconds] + $limit}]
    while {[clock milliseconds] < $until} {
        update
        if {$::els::find_pending eq "" && $::els::find_job eq "" \
                && $::els::find_snapshot_build eq "" && $::els::find_validation eq "" \
                && $::els::find_output_read eq "" && $::els::find_highlight_state eq ""} { return }
        after 1
    }
    error "timed out waiting for isolated find worker"
}

proc els::find_all_action {} {
    if {$::els::find_replace_all_busy} {
        incr ::els::find_generation
        els::find_cancel user
    } else {
        els::find_replace_all
    }
}

proc els::find_shutdown {} {
    set ::els::find_shutdown 1
    incr ::els::find_generation
    els::find_cancel shutdown
    els::find_result_drop
    els::find_snapshot_drop
    set until [expr {[clock milliseconds] + 2500}]
    while {[llength $::els::find_retired] && [clock milliseconds] < $until} {
        if {$::els::find_reap_after ne ""} { after cancel $::els::find_reap_after ; set ::els::find_reap_after "" }
        els::find_reap_tick
        if {[llength $::els::find_retired]} { after 10 }
    }
}

# Public helper retained for unit-level case-template tests; production
# replacement work calls the same pure worker implementation out of process.
proc els::adapt_case {match repl} {
    return [::elsworker::adapt_case $::els::find_adapt $match $repl]
}

# Public find operations are asynchronous in production and synchronously drain
# only under the invisible white-box test harness.  Stable UI entry points keep
# menus and bindings independent of the isolated-worker protocol.
proc els::find_update {} {
    if {$::els::find_mode eq ""} { return }
    set w [els::T]
    if {$w eq ""} { return }
    catch {.find.fr.help configure -state normal}
    catch {.find.fr.help state !disabled}
    els::find_request search
    els::find_test_wait
}

proc els::find_highlight {idx} {
    if {$::els::find_total <= 0 || $::els::find_index_path eq ""} { return }
    set w [els::T]
    if {$w eq ""} { return }
    set n $::els::find_total
    set idx [expr {(($idx % $n) + $n) % $n}]
    if {[catch {lassign [els::find_record_offsets $::els::find_index_path $idx] s e}]} {
        incr ::els::find_generation
        els::find_result_drop
        set ::els::find_count "Find index unavailable"
        return
    }
    set si [$w index "1.0 + $s chars"]
    set ei [$w index "1.0 + $e chars"]
    $w tag remove findOne 1.0 end
    if {$e > $s} { $w tag add findOne $si $ei }
    $w mark set insert $si
    $w see $si
    set ::els::find_current $idx
    set more [expr {$::els::find_index_truncated ? "+" : ""}]
    set ::els::find_count "[expr {$idx + 1}] of $n$more"
    els::update_pos
    els::update_current_line
    els::draw_gutter
}

proc els::find_step {dir} {
    if {$::els::find_mode eq ""} { return }
    if {$::els::find_result_job eq "" || $::els::find_total <= 0 \
            || [dict get $::els::find_result_job doc] ne $::els::active \
            || $::els::docEpoch($::els::active) != [dict get $::els::find_result_job epoch] \
            || [els::find_signature search] ne [dict get $::els::find_result_job signature]} {
        els::find_update
        return
    }
    set old $::els::find_current
    if {$::els::find_index_truncated \
            && (($dir > 0 && $old == $::els::find_total - 1) \
            || ($dir < 0 && $old == 0))} {
        set ::els::find_count "[expr {$old + 1}] of $::els::find_total+  (navigation limit)"
        return
    }
    set idx [expr {(($old + $dir) % $::els::find_total + $::els::find_total) % $::els::find_total}]
    set wrapped [expr {($dir > 0 && $idx <= $old) || ($dir < 0 && $idx >= $old)}]
    els::find_highlight $idx
    if {$wrapped && $::els::find_total > 1} { append ::els::find_count "  (wrapped)" }
}

proc els::find_replace_one {} {
    if {$::els::find_mode eq "" || [els::T] eq ""} { return }
    # A replace is already running: a second Enter must NOT fall through to
    # find_update -> find_request search, which supersedes and kills the in-flight
    # replace worker before it commits (v0.92 was synchronous, so N Enter presses
    # made N replacements).  Ignore the extra press; the running replace commits
    # and re-searches, repositioning the caret for the next Enter (R06).
    if {[els::find_replacement_in_flight]} { return }
    if {$::els::find_result_job eq "" || $::els::find_total <= 0} {
        els::find_update
        if {$::els::find_result_job eq "" || $::els::find_total <= 0} { return }
    }
    if {[catch {lassign [els::find_record_offsets $::els::find_index_path \
            $::els::find_current] s e}]} { return }
    els::find_request replace-one $s $e
    els::find_test_wait
}

proc els::find_replace_all {} {
    if {$::els::find_mode eq "" || [els::T] eq ""} { return }
    els::find_request replace-all
    els::find_test_wait
}

# ---- go to line + whitespace --------------------------------------------
proc els::goto_line {} {
    set id $::els::active
    if {$id eq ""} { return }
    set w [els::W $id]
    if {![winfo exists $w]} { return }
    set max [lindex [split [$w index "end - 1 char"] .] 0]
    if {$max < 1} { set max 1 }
    set top .goto
    catch {destroy $top}
    toplevel $top -bg $::els::PAGE
    set suspendToken [els::suspend_acquire]
    try {
        bind $top <Destroy> [list els::modal_window_release $top $suspendToken %W]
        wm title $top "Go to Line"
        wm resizable $top 0 0
        wm transient $top .
        ttk::frame $top.f -padding 12
        ttk::label $top.f.l -text "Line (1 - $max):" -font elsUI
        # digits only at the KEYBOARD: rejecting non-numeric input beats silently
        # ignoring it at Go time
        ttk::entry $top.f.e -width 10 -font elsMono \
            -validate key -validatecommand {string is digit %P}
        ttk::frame $top.f.b
        ttk::button $top.f.b.ok     -text "Go"     -style Dialog.TButton -default active \
            -command [list els::goto_do $top $id]
        ttk::button $top.f.b.cancel -text "Cancel" -style Dialog.TButton -command [list destroy $top]
        pack $top.f.b.ok $top.f.b.cancel -side left -padx 3
        grid $top.f.l -row 0 -column 0 -sticky w
        grid $top.f.e -row 0 -column 1 -padx 6 -sticky ew
        grid $top.f.b -row 1 -column 0 -columnspan 2 -pady {10 0}
        pack $top.f
        # Enter accepts from anywhere in the dialog -- the entry (TEntry has no class
        # <Return> binding, so it bubbles here) or the -default active "Go" button
        # after Tab, since Tk 9's TButton ignores Return (R21).
        bind $top <Return>   [list els::goto_do $top $id]
        bind $top <KP_Enter> [list els::goto_do $top $id]
        bind $top <Escape> [list destroy $top]
        update idletasks
        set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth  $top]) / 2}]
        set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $top]) / 3}]
        wm geometry $top +$x+$y
        focus $top.f.e
        catch {grab $top}
    } on error {result options} {
        catch {destroy $top}
        els::suspend_release $suspendToken
        return -options $options $result
    }
}
proc els::goto_do {top id} {
    set ln [string trim [$top.f.e get]]
    set validTarget [expr {$id in $::els::docs && [winfo exists [els::W $id]]}]
    set validLine [expr {[regexp {^[0-9]+$} $ln] && [scan $ln %d ln] == 1 && $ln >= 1}]
    # plain decimal only — reject hex (0x1F) and signed (+5), which Tcl's
    # `string is integer` would otherwise accept; scan past leading zeros safely
    destroy $top
    if {$validTarget && $validLine} {
        set w [els::W $id]
        set max [lindex [split [$w index "end - 1 char"] .] 0]
        if {$max < 1} { set max 1 }
        set ln [expr {min($ln, $max)}]
        els::switch_to $id
        $w mark set insert $ln.0
        $w see $ln.0
        els::refresh_view
        focus $w
        return
    }
    set w [els::T]
    if {$w ne ""} { focus $w }
}

# Reveal whitespace when Show Whitespace is on, by tagging it with subdued
# background tints — spaces, tabs and trailing whitespace each a step of blue
# (Tk can't substitute glyphs).  Scoped to the visible viewport so it stays fast
# on large files; re-runs on scroll (els::yscroll) and edits (els::refresh_view).
# Pure tagging (no content change), so it's safe anywhere.
proc els::ws_clear {w} {
    $w tag remove wsSpace 1.0 end
    $w tag remove wsTab   1.0 end
    $w tag remove wsTrail 1.0 end
}
proc els::ws_refresh {} {
    set w [els::T]
    if {$w eq ""} { return }
    els::ws_clear $w
    if {!$::els::show_ws} { return }
    # linestart: with wrap off and the view scrolled right, @0,0 is a MID-LINE
    # index, and tagging from there left the top row's left-of-viewport
    # whitespace untinted after panning back to column 0
    set top [$w index "@0,0 linestart"]
    set bot [$w index "@0,[winfo height $w] + 1 line"]
    # spaces -> grey; tabs -> blue; any trailing space OR a run of 2+ spaces ->
    # mauve (flags trailing and accidental double-spaces, overriding the grey).
    # Ordinary single inter-word spaces stay subtle grey.
    foreach {tag pat var} {wsSpace { +} wl1  wsTab {\t+} wl2  wsTrail { +$} wl3  wsTrail {  +} wl4} {
        set i 0
        foreach s [$w search -all -regexp -count ::els::$var -- $pat $top $bot] {
            $w tag add $tag $s "$s + [lindex [set ::els::$var] $i] chars" ; incr i
        }
    }
}

proc els::set_show_ws {{persist 1}} {
    # tags are per-widget and the re-tag is viewport-based (the active widget only),
    # so turning the feature OFF must clear EVERY document's tints, not just the
    # active one — else a background tab keeps stale whitespace tint until it is
    # re-toggled while active (matches set_wrap / set_focus_mode) (G-View mat-2)
    if {$::els::show_ws} {
        els::ws_refresh
    } else {
        foreach id $::els::docs {
            if {[winfo exists [els::W $id]]} { els::ws_clear [els::W $id] }
        }
    }
    if {$persist} { els::save_geometry }
}
# View ▸ Line Numbers: hide/show the gutter (grid remove keeps its options, so
# a plain `grid .ln` restores it exactly); persisted with the config.
proc els::set_linenos {{persist 1}} {
    if {![winfo exists .ln]} { return }
    if {$::els::show_linenos} {
        grid .ln
        els::gutter_schedule
    } else {
        grid remove .ln
    }
    if {$persist} { els::save_geometry }
}
# Always on Top: keep the els window above other windows.  Tk maps this to the
# Win32 WS_EX_TOPMOST style (SetWindowPos HWND_TOPMOST), so it is reliable for
# normal windows; the only thing it cannot sit above is another app's exclusive-
# fullscreen surface, which is inherent to how Windows topmost works.
proc els::set_always_on_top {{persist 1}} {
    catch {wm attributes . -topmost [expr {$::els::always_on_top ? 1 : 0}]}
    if {$persist} { els::save_geometry }
}

# Word wrap: soft-wrap long lines in every document.  The line-number gutter
# (a Canvas, see els::draw_gutter) redraws from the text's dlineinfo, so wrapped
# lines stay aligned automatically — refresh_view repaints it after the toggle.
proc els::set_wrap {{persist 1}} {
    variable docs
    set mode [expr {$::els::word_wrap ? "word" : "none"}]
    foreach id $docs {
        if {[winfo exists [els::W $id]]} { [els::W $id] configure -wrap $mode }
    }
    els::refresh_view
    # the reflow settles after this returns; re-check the horizontal bar at idle
    # so it appears/disappears with the new wrap state
    after idle els::update_hscroll
    if {$persist} { els::save_geometry }
}

# Text size (the font FAMILY is fixed; users can only zoom).  elsMono is a named
# font shared by every document and the gutter, so resizing it scales them all;
# we then recompute the leading and rebuild the gutter so numbers stay aligned.
proc els::set_font_size {size {persist 1}} {
    set size [expr {max(6, min(48, $size))}]
    set ::els::font_size $size
    font configure elsMono -size $size
    set ::els::LEAD [expr {int([font metrics elsMono -linespace] * 0.17)}]
    foreach id $::els::docs {
        set w [els::W $id]
        if {[winfo exists $w]} { $w configure -spacing1 $::els::LEAD -spacing3 $::els::LEAD }
    }
    set ::els::gutter_px -1   ;# font size changed: force a width recompute
    els::refresh_view
    if {$persist} { els::save_geometry }   ;# remember the zoom level across runs
}
proc els::zoom {d}      { els::set_font_size [expr {$::els::font_size + $d}] }
proc els::zoom_reset {} { els::set_font_size 11 }

# ---- update check -------------------------------------------------------
# Resolve a Windows system tool to its ABSOLUTE path under %SystemRoot%\System32.
# Never invoke curl/rundll32/cmd by bare name: Tcl's exec searches the CURRENT
# DIRECTORY before PATH on Windows, and when els is launched by double-clicking a
# document the CWD is that document's folder — so a bare-name exec would run a
# malicious `curl.exe` planted beside a shared/extracted file.  Returns "" (fail
# safe — the caller then does nothing) if SystemRoot is unset or the tool is
# absent (e.g. curl.exe predates Windows 10 1803).  els.exe is x64, so System32
# is the real 64-bit dir with no WOW64 redirection.
proc els::system32 {exe} {
    if {![info exists ::env(SystemRoot)] || $::env(SystemRoot) eq ""} { return "" }
    set p [file join $::env(SystemRoot) System32 $exe]
    if {![file exists $p]} { return "" }
    return $p
}
# As system32, but for tools that live directly in %SystemRoot% (e.g.
# explorer.exe, which is NOT in System32) — same anti-planting rationale.
proc els::windir {exe} {
    if {![info exists ::env(SystemRoot)] || $::env(SystemRoot) eq ""} { return "" }
    set p [file join $::env(SystemRoot) $exe]
    if {![file exists $p]} { return "" }
    return $p
}
# ELS_NO_UPDATE_CHECK opts out of the launch-time network call entirely (portable
# / locked-down / offline installs).
proc els::update_check_off {} {
    return [expr {[info exists ::env(ELS_NO_UPDATE_CHECK)] && $::env(ELS_NO_UPDATE_CHECK) ne ""}]
}
# Best-effort, fire-and-forget check of the GitHub Releases API — a public,
# unauthenticated GET (one request at startup, far within the 60/hr limit, so
# it stays within GitHub's terms).  This runtime has no TLS, so we lean on
# Windows' bundled curl.exe; stdout is piped back and stderr is sent to NUL so
# no console window flashes.  Any failure (offline, no curl, odd JSON) is
# swallowed silently — the editor never blocks or complains.
proc els::check_update {} {
    if {$::els::selftest || [els::update_check_off]} return
    set curl [els::system32 curl.exe]
    if {$curl eq ""} return
    set url "https://api.github.com/repos/anafalanx/els/releases/latest"
    if {[catch {
        set ch [::open [list | $curl -s -m 6 \
            -H "User-Agent: els-editor" \
            -H "Accept: application/vnd.github+json" $url 2> NUL] r]
    }]} { return }
    set ::els::update_buf ""
    fconfigure $ch -blocking 0 -translation binary
    fileevent $ch readable [list els::update_read $ch]
}
proc els::update_read {ch} {
    if {[catch {read $ch} chunk]} { catch {close $ch} ; return }
    append ::els::update_buf $chunk
    if {[eof $ch]} {
        fileevent $ch readable {}
        catch {close $ch}
        els::update_parse $::els::update_buf
    }
}
proc els::update_parse {data} {
    if {![regexp {"tag_name"\s*:\s*"([^"]+)"} $data -> tag]} { return }
    set latest [string trimleft $tag vV]
    if {[els::version_gt $latest $::els::version]} { els::show_update $latest }
}
# a > b for dotted versions, via Tcl's own package comparator (junk -> false)
proc els::version_gt {a b} {
    return [expr {![catch {package vcompare $a $b} c] && $c > 0}]
}
proc els::show_update {ver} {
    if {![winfo exists .sb.update]} return
    .sb.update configure -text $ver
    els::tooltip .sb.update "els $ver is available — click to download"
    # els::tooltip REPLACED <Enter>/<Leave> with tip schedule/cancel; re-append the
    # hover highlight the pill was built with (see build) with `+`, so it both shows
    # the tip AND keeps its highlight (and <Leave> restores CHROME) (G-View mat-4)
    bind .sb.update <Enter> {+.sb.update configure -background $::els::TABBG}
    bind .sb.update <Leave> {+.sb.update configure -background $::els::CHROME}
}
# Open a URL in the user's browser.  Absolute System32 paths only — see
# els::system32 for why a bare `rundll32.exe`/`cmd.exe` is unsafe here too (a
# double-click launch leaves the CWD in the document's folder).
proc els::open_url {url} {
    set rundll [els::system32 rundll32.exe]
    if {$rundll ne "" && ![catch {exec $rundll url.dll,FileProtocolHandler $url &}]} { return }
    set cmd [els::system32 cmd.exe]
    if {$cmd ne ""} { catch {exec $cmd /c start "" $url &} }
}

proc els::startup_probe {report} {
    update idletasks
    set paths {}
    set chars {}
    set dirty {}
    set bodies {}
    foreach id $::els::docs {
        if {[info exists ::els::docPath($id)]} { lappend paths $::els::docPath($id) }
        catch {lappend chars [[els::W $id] count -chars 1.0 "end - 1 char"]}
        lappend dirty [els::doc_dirty $id]
        catch {lappend bodies [[els::W $id] get 1.0 "end - 1 char"]}
    }
    set data [dict create \
        mapped [winfo ismapped .] \
        cfgask [winfo exists .cfgask] \
        cfgask_mapped [expr {[winfo exists .cfgask] ? [winfo ismapped .cfgask] : 0}] \
        config $::els::config_path \
        docs [llength $::els::docs] \
        paths $paths \
        doc_chars $chars \
        doc_bodies $bodies \
        doc_dirty $dirty \
        active_path [els::session_current_active] \
        deferred $::els::deferred_files \
        title [wm title .] \
        argv $::argv \
        argv0 $::argv0]
    if {$report ne ""} {
        catch {file mkdir [file dirname $report]}
        # write atomically (temp + rename) so a reader polling for the report can
        # never observe a half-written file (TOCTOU)
        # doc paths/bodies can hold lone UTF-16 surrogates; strict utf-8 would throw
        # in puts and leave a truncated, malformed report.  Replace-profile + a full
        # catch + try/finally so the channel is always closed (pa-0).
        catch {
            set fh [::open $report.tmp w]
            try {
                fconfigure $fh -profile replace
                puts $fh $data
            } finally { close $fh }
            file rename -force $report.tmp $report
        }
    }
    exit
}

# ---- main ---------------------------------------------------------------
# ---- diagnostics: a small rotating log + a production bgerror ------------
# A GUI-subsystem exe has no console, so a field failure (a save error, a decode
# fault, a background callback error) otherwise vanishes or — worse — pops Tk's
# default modal "raining dialogs".  els::log appends a line to els.log next to
# els.conf, rotating at ~256 KB with one generation kept.  Self-catching with a
# reentry latch: logging can never itself raise into bgerror or crash the app.
proc els::log {level msg} {
    if {$::els::log_active} return
    if {$::els::config_path eq ""} return   ;# no chosen config dir yet: nowhere safe to write
    set ::els::log_active 1
    catch {
        set lf [file join [file dirname $::els::config_path] els.log]
        if {![catch {file size $lf} sz] && $sz > 262144} {
            catch {file rename -force $lf "$lf.1"}   ;# one generation
        }
        set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
        set fh [::open $lf a]
        try {
            # -profile replace: a $msg from bgerror can embed a lone UTF-16 surrogate
            # (NTFS names, buffer text); strict would throw mid-puts and leave a
            # truncated, newline-less line, corrupting the log's format (pa-2)
            fconfigure $fh -encoding utf-8 -profile replace
            puts $fh "$ts \[$level\] $msg"
        } finally { close $fh }
    }
    set ::els::log_active 0
}
# The production background-error handler, installed (only) for a normal launch.
# It must NEVER exit and NEVER stack modal dialogs: log the trace, then show a
# single non-modal status-bar note.  The startup PROBE keeps its own exit-3
# handler; tests install their own capture; neither path reaches here.
proc els::bgerror {msg args} {
    if {$::els::log_active} return   ;# a logging failure surfaced as a bg error: swallow
    set trace $msg
    if {[llength $args]} { catch {set trace [dict get [lindex $args 0] -errorinfo]} }
    catch {els::log error $trace}
    catch {els::status_note "internal error (logged to els.log)"}
}

proc els::main {} {
    set a0 [lindex $::argv 0]
    if {$a0 eq "--selftest"} {
        els::build
        els::selftest [lindex $::argv 1] [lindex $::argv 2]
    } else {
        set envProbe [expr {[info exists ::env(ELS_STARTUP_PROBE)] && $::env(ELS_STARTUP_PROBE) ne ""}]
        set startupProbe [expr {$envProbe || $a0 eq "--startup-probe"}]
        # plain if/else, no expr ternaries: paths/args routed through expr get
        # numerically canonicalized (`els.exe 007` would open the file "7")
        if {$envProbe} {
            set startupReport $::env(ELS_STARTUP_PROBE)
        } elseif {$startupProbe} {
            set startupReport [lindex $::argv 1]
        } else {
            set startupReport ""
        }
        if {!$envProbe && $startupProbe} {
            set fileArgs [lrange $::argv 2 end]
        } else {
            set fileArgs $::argv
        }
        els::build
        if {$startupProbe} {
            # Headless probe: keep the window off the user's screen (alpha 0 still
            # counts as mapped, so the probe's assertions hold) and route any
            # startup error to stderr + exit instead of a modal dialog — the test
            # then fails on a missing report rather than hanging behind a dialog.
            catch {wm attributes . -alpha 0.0}
            # child toplevels too: one would inherit no alpha and could
            # otherwise flash as a real opaque window during a suite run
            set ::els::probe_quiet 1
            proc ::bgerror {msg args} { catch {puts stderr "els startup-probe: $msg"} ; exit 3 }
            catch {interp bgerror {} ::bgerror}
        } else {
            # production run: route uncaught async errors to els::bgerror (log,
            # one non-modal note) instead of Tk's modal "raining
            # dialogs".  Installed HERE, not at source time, so the test harness's
            # own bgerror capture (helpers.tcl) is never clobbered.
            proc ::bgerror {msg args} { els::bgerror $msg {*}$args }
            catch {interp bgerror {} els::bgerror}
            catch {proc ::tk::dialog::error::bgerror {msg args} { els::bgerror $msg {*}$args }}
        }
        # open every file argument, each in its own tab (the first reuses the
        # initial empty document).  Explicit launch files take precedence over
        # the saved session, which is only for a plain app start.
        set openedArgs 0
        set failedArgs {}
        foreach f $fileArgs {
            if {[string index $f 0] ne "-"} {
                # Startup arguments are not yet an interactive event-loop action:
                # never load a large one silently or surface an early modal.
                els::open $f 1
                if {$::els::last_open_outcome in {opened already deferred}} {
                    set openedArgs 1
                } elseif {$::els::last_open_outcome eq "failed"} {
                    lappend failedArgs $f
                }
            }
        }
        set ::els::session_boot_after \
            [after 80 [list els::session_boot $openedArgs]]   ;# session restore
        # Surface any launch-arg open failures AFTER the UI is mapped and the event
        # loop runs (the `after` lets els::main return first), so the modal never
        # blocks startup; skipped under the headless probe so the suite stays modal-free.
        if {!$startupProbe && [llength $failedArgs]} {
            after 120 [list els::report_launch_failures $failedArgs]
        }
        if {$startupProbe} {
            # Headless probe: report once startup/session work has settled, then exit.
            after 900 [list els::startup_probe $startupReport]
            return
        }
        after 1500 els::check_update
    }
}

# headless smoke test: open a file, exercise a second tab, write a report file
proc els::selftest_report_path {{requested ""}} {
    if {$requested ne ""} { return $requested }
    set dirs {}
    set exe [info nameofexecutable]
    if {$exe ne ""} { lappend dirs [file dirname $exe] }
    if {![string match {//zipfs:*} [info script]]} {
        lappend dirs [file dirname [info script]]
    }
    if {[info exists ::env(TEMP)] && $::env(TEMP) ne ""} { lappend dirs $::env(TEMP) }
    # Actually probe writability instead of blindly returning the first candidate:
    # info nameofexecutable is never empty, so the exe dir always won before — and a
    # read-only install (Program Files) then left --selftest with no writable report
    # path and no observable output (a GUI exe discards the stderr fallback) (pa-7).
    foreach d $dirs {
        if {$d eq ""} continue
        set cand [file join $d els-selftest.txt]
        if {![catch {set fh [::open $cand w]}]} { close $fh ; return $cand }
    }
    return els-selftest.txt
}
proc els::selftest {tf {report ""}} {
    set openok "skipped"
    if {$tf ne ""} {
        if {[catch {els::open $tf} err]} {
            set openok "FAIL: $err"
        } else {
            set openok "ok lines=[els::line_count]"
        }
    }
    set d2 [els::new_doc]
    [els::W $d2] insert end "second tab body"
    set ndocs [llength $::els::docs]
    set tabs_ok 1
    foreach id $::els::docs {
        if {![winfo exists [els::tabW $id]]} { set tabs_ok 0 }
    }
    els::cycle -1
    update idletasks; update
    set w [els::T]
    set report [els::selftest_report_path $report]
    set dstate ""
    foreach id $::els::docs { append dstate "$id:[els::doc_dirty $id] " }
    set lines [list \
        "ok version=$::els::version tk=[info patchlevel]" \
        "mapped=[winfo ismapped .] title=[wm title .]" \
        "caret=[$w cget -insertbackground] page=[$w cget -bg] font=[$w cget -font]" \
        "icon=$::els::iconLoaded path=$::els::iconPath" \
        "gutter_width=[.ln cget -width] lines=[els::line_count]" \
        "current_line_tag=[$w tag ranges currentLine]" \
        "config=[els::config_file] geometry=[wm geometry .]" \
        "theme=[ttk::style theme use] scaling=[format %.3f [tk scaling]]" \
        "docs=$ndocs active=$::els::active tabs_ok=$tabs_ok" \
        "detect=$::els::have_detect" \
        "association_exe=[els::association_exe]" \
        "doc_dirty=[string trimright $dstate]" \
        "open=$openok"]
    set txt [join $lines \n]\n
    # Guard the write: a read-only or non-writable report directory must not leave
    # this headless selftest hung behind a background-error dialog.  On failure,
    # fall back to stderr (still visible to whoever launched --selftest).
    catch {file mkdir [file dirname $report]}
    # temp+rename (the same discipline as the startup-probe report) so a reader
    # polling the report can never observe a half-written file (pa-4)
    if {[catch {
        set out [::open $report.tmp w]
        try { puts -nonewline $out $txt } finally { close $out }
        file rename -force $report.tmp $report
    } err]} {
        catch {puts stderr "selftest: could not write $report: $err"}
        catch {puts -nonewline stderr $txt}
    }
    after 150 {exit}
}

# load the optional ICU charset detector (chardet-quality auto-detection); a
# missing DLL just leaves have_detect 0 and els falls back to BOM/UTF-8/cp1252
catch { set ::els::have_detect [els::load_detect] }

# run the UI only when executed as the main script, not when sourced by tests
if {[file normalize [info script]] eq [file normalize $::argv0]} {
    els::main
}
