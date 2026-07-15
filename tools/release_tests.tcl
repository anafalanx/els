#!/usr/bin/env tclsh
# tools/release_tests.tcl -- fail-closed release test driver.
#
# The public invocation always starts a child and requires a private completion
# sentinel.  A test file that accidentally calls `exit 0`, a truncated driver,
# or a child killed after printing a plausible summary can therefore never be
# mistaken for a completed release suite.

proc fail {msg {opts {}}} {
    puts stderr "release tests failed: $msg"
    if {$opts ne "" && [dict exists $opts -errorinfo]} {
        puts stderr [dict get $opts -errorinfo]
    }
    exit 1
}
proc read_binary {path} {
    set fh [open $path r]
    try { fconfigure $fh -translation binary; return [read $fh] } finally { close $fh }
}
proc write_sentinel {path text} {
    set fh [open $path {WRONLY CREAT EXCL}]
    try {
        fconfigure $fh -encoding utf-8 -translation lf
        puts -nonewline $fh $text
        flush $fh
    } finally { close $fh }
}

set script [file normalize [info script]]
set root [file dirname [file dirname $script]]
set here [file join $root tests]
set expectedFiles {
    els.test elsx.test encoding.test find.test harness.test recover.test
    startup.test stress.test ui.test units.test view.test winfs.test xform.test
}

if {[lindex $argv 0] ne "--child"} {
    if {[llength $argv]} { fail "usage: release_tests.tcl" }
    set build [file join $root build]
    file mkdir $build
    if {[catch {set stage [file tempdir [file join $build _release-tests-]]} err]} {
        fail "cannot create private runner stage: $err"
    }
    set sentinel [file join $stage completed.txt]
    set token "[pid]-[clock microseconds]-[clock clicks]"
    set expected "els-release-tests-complete-v1\n$token\n"
    set rc [catch {
        exec [info nameofexecutable] $script --child $sentinel $token >@ stdout 2>@ stderr
    } childError childOpts]
    if {$rc} {
        catch {file delete -force -- $stage}
        if {[dict exists $childOpts -errorcode] &&
            [lindex [dict get $childOpts -errorcode] 0] eq "CHILDSTATUS"} {
            fail "child exited with status [lindex [dict get $childOpts -errorcode] 2]"
        }
        fail "child launch failed: $childError" $childOpts
    }
    if {![file isfile $sentinel]} {
        catch {file delete -force -- $stage}
        fail "child returned success without its completion sentinel"
    }
    set actual [read_binary $sentinel]
    set cleanupRc [catch {file delete -force -- $stage} cleanupErr]
    if {$actual ne $expected} { fail "child completion sentinel was malformed or belonged to another run" }
    if {$cleanupRc} { fail "cannot remove private runner stage: $cleanupErr" }
    puts "release test child completion sentinel verified"
    exit 0
}

if {[llength $argv] != 3} { fail "invalid private child invocation" }
set sentinel [file normalize [lindex $argv 1]]
set token [lindex $argv 2]
if {![regexp {^[0-9]+-[0-9]+-[0-9]+$} $token]} { fail "invalid private child token" }
if {[file exists $sentinel]} { fail "private child sentinel already exists" }
cd $root

set testPaths [glob -nocomplain [file join $here *.test]]
lappend testPaths {*}[glob -nocomplain -types hidden [file join $here *.test]]
set actualFiles [lsort -dictionary -unique [lmap path $testPaths { file tail $path }]]
set expectedFiles [lsort -dictionary $expectedFiles]
if {$actualFiles ne $expectedFiles} {
    fail "test inventory changed; expected={$expectedFiles}, actual={$actualFiles}"
}

proc run_expected_test_files {here expectedFiles requiredConstraints} {
    # tcltest deliberately evaluates each test's setup/body/cleanup in the
    # caller's scope.  Source the suites at global scope as before, but keep the
    # fail-closed runner's counters in this private procedure frame so ordinary
    # test locals such as "before" or "name" cannot corrupt the inventory.
    set unavailable {}
    foreach name $expectedFiles {
        set before $::tcltest::numTests(Total)
        uplevel #0 [list source [file join $here $name]]
        set count [expr {$::tcltest::numTests(Total) - $before}]
        if {$count <= 0} { error "test file registered no tests: $name" }
        dict set ::release_file_counts $name $count
    }
    foreach constraint $requiredConstraints {
        if {![::tcltest::testConstraint $constraint]} { lappend unavailable $constraint }
    }
    return [dict create \
        unavailable $unavailable \
        total $::tcltest::numTests(Total) \
        passed $::tcltest::numTests(Passed) \
        skipped $::tcltest::numTests(Skipped) \
        failed $::tcltest::numTests(Failed)]
}

proc run_release_test_child {here expectedFiles sentinel token} {
    # Keep every piece of runner-owned state—including the authentication token
    # and sentinel path—outside the global scope where tcltest intentionally
    # evaluates test bodies.  The suites themselves still run at global scope.
    set required {detect extBuilt winfsBuilt startup stress winlong powershellAvailable}
    set unavailable {}
    set total 0
    set passed 0
    set skipped 0
    set failed 0
    set ::release_failed_tests {}
    set ::release_skipped_tests {}
    set ::release_seen_tests {}
    set ::release_file_counts {}

    set suiteRc [catch {
        set ::argv {}
        uplevel #0 [list source [file join $here helpers.tcl]]
        ::tcltest::testConstraint stress 1

        rename ::tcltest::test ::tcltest::_release_test
        proc ::tcltest::test {name description args} {
            lappend ::release_seen_tests $name
            set failedBefore $::tcltest::numTests(Failed)
            set skippedBefore $::tcltest::numTests(Skipped)
            set rc [catch {
                uplevel 1 [list ::tcltest::_release_test $name $description {*}$args]
            } result opts]
            if {$::tcltest::numTests(Failed) > $failedBefore} { lappend ::release_failed_tests $name }
            if {$::tcltest::numTests(Skipped) > $skippedBefore} { lappend ::release_skipped_tests $name }
            return -options $opts $result
        }
        if {[llength [info commands ::test]]} { rename ::test {} }
        namespace eval :: { namespace import ::tcltest::test }

        set stats [run_expected_test_files $here $expectedFiles $required]
        set unavailable [dict get $stats unavailable]
        set total       [dict get $stats total]
        set passed      [dict get $stats passed]
        set skipped     [dict get $stats skipped]
        set failed      [dict get $stats failed]
    } suiteError suiteOpts]

    set cleanupRc 0
    set cleanupError ""
    set cleanupOpts {}
    if {[llength [info commands ::tcltest::cleanupTests]]} {
        catch {::tcltest::testConstraint interactive 1}
        set cleanupRc [catch {::tcltest::cleanupTests} cleanupError cleanupOpts]
    }

    if {$suiteRc} { fail "suite evaluation aborted: $suiteError" $suiteOpts }
    if {$cleanupRc} { fail "tcltest cleanup aborted: $cleanupError" $cleanupOpts }
    if {[llength $unavailable]} { fail "required constraints unavailable: [join $unavailable {, }]" }
    if {$total <= 0 || $total != [llength $::release_seen_tests]} {
        fail "test registration count is inconsistent: total=$total, observed=[llength $::release_seen_tests]"
    }
    if {[llength [lsort -unique $::release_seen_tests]] != [llength $::release_seen_tests]} {
        fail "duplicate test names were registered"
    }
    if {$failed != 0} { fail "$failed of $total tests failed: [join $::release_failed_tests {, }]" }
    if {$skipped != 0} { fail "$skipped of $total tests were skipped: [join $::release_skipped_tests {, }]" }

    puts "release tests ok: $passed/$total passed; files=[dict size $::release_file_counts]; required constraints: [join $required {, }]"
    write_sentinel $sentinel "els-release-tests-complete-v1\n$token\n"
}

run_release_test_child $here $expectedFiles $sentinel $token
exit 0
