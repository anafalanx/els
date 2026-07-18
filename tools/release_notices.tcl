# tools/release_notices.tcl -- canonical license material embedded in els.exe.
#
# This file is sourced by both package.tcl and tasks.tcl.  Keeping the byte
# construction in one place means the release check can compare the packaged
# notice with the exact bytes the packager was supposed to write.

namespace eval ::elsrelease {}

proc ::elsrelease::read_binary {path} {
    if {![file isfile $path]} { error "required release notice is missing: $path" }
    set fh [open $path r]
    try {
        fconfigure $fh -translation binary
        return [read $fh]
    } finally {
        close $fh
    }
}

proc ::elsrelease::notice_sources {tcltk msys2} {
    return [list \
        {Tcl 9.0.4} \
            [file join $tcltk tcllib tcl_library license.terms] \
        {Tk 9.0.4} \
            [file join $tcltk tcllib tk_library license.terms] \
        {MinGW-w64 runtime} \
            [file join $msys2 ucrt64 share licenses crt COPYING.MinGW-w64-runtime.txt] \
        {GNU GPL v3 (GCC runtime support)} \
            [file join $msys2 ucrt64 share licenses gcc-libs COPYING3] \
        {GCC Runtime Library Exception 3.1} \
            [file join $msys2 ucrt64 share licenses gcc-libs COPYING.RUNTIME] \
        {zlib (bundled in Tcl)} \
            [file join $tcltk tclsrc tcl9.0.4 compat zlib LICENSE] \
        {LibTomMath (bundled in Tcl)} \
            [file join $tcltk tclsrc tcl9.0.4 libtommath LICENSE]]
}

proc ::elsrelease::third_party_notices {tcltk msys2} {
    set out "els third-party notices\n=======================\n\n"
    append out "This executable statically links Tcl, Tk, the MinGW-w64 runtime, "
    append out "and GCC runtime support (GPLv3 with the GCC Runtime Library Exception). "
    append out "Tcl also contains zlib and LibTomMath.\n"
    append out "els is linked with GCC's -no-pthread policy and does not include winpthreads.\n"
    append out "The applicable license and copyright notices follow verbatim.\n\n"
    foreach {label path} [notice_sources $tcltk $msys2] {
        append out "----- $label -----\n\n"
        set bytes [read_binary $path]
        append out $bytes
        if {![string match *\n $bytes]} { append out "\n" }
        append out "\n"
    }
    return $out
}
