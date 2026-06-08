/*
 * els_main.c -- custom Windows entry point for els.
 *
 * A minimal fork of Tk's win/winMain.c (the literal source of wish90s.exe): a
 * GUI (no-console) WinMain that lets TclZipfs_AppHook self-mount the zipfs
 * archive appended to THIS executable -- which carries main.tcl (= els.tcl), the
 * Tcl and Tk script libraries, and resources/ -- then hands off to Tk_Main, which
 * runs main.tcl as the startup script. els's own C extension(s) are statically
 * linked and registered in the app-init below; there are no loadable DLLs.
 *
 * Build requirements (see docs/native-port-study.md):
 *   -DUNICODE -D_UNICODE -municode  : TclZipfs_AppHook uses the WCHAR signature;
 *                                     without UNICODE the self-mount silently
 *                                     no-ops and main.tcl is never found.
 *   -DSTATIC_BUILD=1                : tcl.h/tk.h must not mark symbols dllimport.
 *   USE_TCL_STUBS undefined         : with stubs, Tk_Main becomes a TIP-596 thunk
 *                                     that LoadLibrary's tcl90.dll/tk and crashes
 *                                     in a static exe with no such DLL.
 *   -mwindows                       : GUI subsystem (no console window).
 * Define ELS_STATIC_ICUDET (and link build/icudet.o) to compile the charset
 * detector straight in (Phase 2); without it, els.tcl's `package require icudet`
 * is caught and els falls back to BOM/UTF-8/cp1252 detection.
 */

#undef USE_TCL_STUBS
#include "tk.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <locale.h>
#include <stdlib.h>
#include <tchar.h>

#if defined(__GNUC__)
int _CRT_glob = 0;          /* keep the mingw CRT from glob-expanding argv */
#endif

#ifdef ELS_STATIC_ICUDET
extern int Icudet_Init(Tcl_Interp *interp);   /* src/icudet.c (no public header) */
#endif

static int Els_AppInit(Tcl_Interp *interp);

/*
 * _tWinMain -- entry point from Windows (GUI subsystem). Mirrors winMain.c but
 * with the console path removed: els is an editor, never an interactive shell.
 */
int APIENTRY
_tWinMain(
    HINSTANCE hInstance,
    HINSTANCE hPrevInstance,
    LPTSTR lpszCmdLine,
    int nCmdShow)
{
    TCHAR **argv;
    int argc;
    TCHAR *p;
    (void) hInstance;
    (void) hPrevInstance;
    (void) lpszCmdLine;
    (void) nCmdShow;

    /* Standard "C" locale so Tcl parses numbers/paths predictably. */
    setlocale(LC_ALL, "C");

    /* Take args from the CRT (wide under -municode); ignore lpszCmdLine. */
    argc = __argc;
    argv = __targv;

    /* Forward slashes for backslashes in argv[0], as wish does. */
    for (p = argv[0]; *p != '\0'; p++) {
        if (*p == '\\') {
            *p = '/';
        }
    }

    /*
     * Self-mount the zip appended to this exe at //zipfs:/app and register
     * //zipfs:/app/main.tcl as the startup script. UNICODE-only (WCHAR
     * signature). This is what makes "Tcl/Tk + els fully built-in" work.
     */
#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif

    Tk_Main(argc, argv, Els_AppInit);
    return 0;                   /* Tk_Main does not return; silences a warning. */
}

/*
 * Els_AppInit -- per-interpreter initialization: Tcl, then Tk (registered as a
 * static library), then els's statically-linked C extensions. No console window
 * and no user rc file (unlike wish): els is a GUI editor.
 */
static int
Els_AppInit(
    Tcl_Interp *interp)
{
    if (Tcl_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    if (Tk_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

#ifdef ELS_STATIC_ICUDET
    /*
     * Charset detector (src/icudet.c): seeds ::elsdet::detect and PkgProvides
     * "icudet", so els.tcl's `package require icudet` resolves in-process. The
     * extension LoadLibraryA's the system icu.dll lazily at runtime -- there is
     * no link-time ICU dependency.
     */
    if (Icudet_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Icudet", Icudet_Init, NULL);
#endif

    return TCL_OK;
}
