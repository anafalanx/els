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
#include <wchar.h>

#if defined(__GNUC__)
int _CRT_glob = 0;          /* keep the mingw CRT from glob-expanding argv */
#endif

#ifdef ELS_STATIC_ICUDET
extern int Icudet_Init(Tcl_Interp *interp);   /* src/icudet.c (no public header) */
#endif
#ifdef ELS_STATIC_WINFS
extern int Winfs_Init(Tcl_Interp *interp);    /* src/winfs.c -- els::win_replace_file */
#endif
#ifdef ELS_STATIC_WINDROP
extern int Windrop_Init(Tcl_Interp *interp);  /* src/windrop.c -- els::win_drop_register */
#endif

static int Els_AppInit(Tcl_Interp *interp);

/* A GUI-subsystem process has no console, so returning TCL_ERROR from AppInit
 * is not fail-closed: Tk_Main displays another warning and then continues into
 * main.tcl with a partly initialized interpreter.  Report exactly once and end
 * the process while the interpreter result is still available. */
#ifdef ELS_TEST_INIT_FAILURE
static void
WriteTestFailureReport(const WCHAR *body)
{
    WCHAR path[32768];
    DWORD pathLen = GetEnvironmentVariableW(L"ELS_TEST_INIT_REPORT", path,
            (DWORD)(sizeof(path) / sizeof(path[0])));
    if (pathLen == 0 || pathLen >= (DWORD)(sizeof(path) / sizeof(path[0]))) {
        return;
    }

    HANDLE report = CreateFileW(path, GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, NULL);
    if (report == INVALID_HANDLE_VALUE) {
        return;
    }

    /* UTF-16LE with a BOM: the test validates the exact Unicode diagnostic. */
    const WCHAR bom = 0xFEFF;
    DWORD written;
    (void)WriteFile(report, &bom, (DWORD)sizeof(bom), &written, NULL);
    size_t chars = wcslen(body);
    (void)WriteFile(report, body, (DWORD)(chars * sizeof(WCHAR)), &written, NULL);
    (void)FlushFileBuffers(report);
    (void)CloseHandle(report);
}
#endif

static _Noreturn void
InitFailure(Tcl_Interp *interp, const WCHAR *stage)
{
    WCHAR detail[1536] = L"No further detail was provided.";
    WCHAR body[2048];
    const char *msg = Tcl_GetStringResult(interp);
    if (msg != NULL && *msg != '\0') {
        int n = MultiByteToWideChar(CP_UTF8, 0, msg, -1, detail,
                                    (int)(sizeof(detail) / sizeof(detail[0])));
        if (n == 0) {
            wcscpy(detail, L"The diagnostic message could not be decoded.");
        }
    }
    swprintf(body, sizeof(body) / sizeof(body[0]),
             L"els cannot start: %ls failed.\n\n%ls\n\n"
             L"The executable or its embedded runtime may be damaged.",
             stage, detail);
#ifdef ELS_TEST_INIT_FAILURE
    /* Compile-time-only probe surface: production builds contain neither the
     * environment variable nor this no-UI reporting branch. */
    WriteTestFailureReport(body);
#else
    MessageBoxW(NULL, body, L"els", MB_ICONERROR | MB_OK);
#endif
    ExitProcess((UINT)EXIT_FAILURE);
}

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

    /*
     * Refuse to run as a Tcl-script host (F42).  If the appended zipfs payload did
     * NOT mount -- a stripped or corrupt exe, e.g. a PE-resource tool rewrote the
     * image (see docs/toolchain.md's "PE-resource gotcha") -- TclZipfs_AppHook
     * registered no startup script, and Tk_Main would then fall back to wish
     * semantics and SOURCE the first file argument as a Tcl script (Tcl_Main's
     * "?-encoding name? fileName" rule).  A double-clicked "document" would then
     * execute arbitrary Tcl/exec.  The intact els.exe always registers
     * //zipfs:/app/main.tcl at this point, so this only fires on a damaged binary.
     */
    if (Tcl_GetStartupScript(NULL) == NULL) {
#ifdef ELS_TEST_INIT_FAILURE
        WriteTestFailureReport(
            L"els cannot start: its embedded application payload is missing or "
            L"corrupt (the executable may be damaged). Please reinstall els.");
#else
        MessageBoxW(NULL,
            L"els cannot start: its embedded application payload is missing or "
            L"corrupt (the executable may be damaged). Please reinstall els.",
            L"els", MB_ICONERROR | MB_OK);
#endif
        return 1;
    }

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
        InitFailure(interp, L"Tcl initialization");
    }
#ifdef ELS_TEST_INIT_FAILURE
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
            "injected diagnostic: Jos\xC3\xA9 / \xE4\xBD\xA0\xE5\xA5\xBD / "
            "\xF0\x9F\x98\x80", -1));
    InitFailure(interp, L"test-only initialization");
#endif
    if (Tk_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"Tk initialization");
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
        InitFailure(interp, L"character detector initialization");
    }
    Tcl_StaticLibrary(interp, "Icudet", Icudet_Init, NULL);
#endif

#ifdef ELS_STATIC_WINFS
    /* els::win_replace_file -- atomic file replacement with best-effort Windows
     * metadata merging (used by els::write_atomic; harmless if absent — Tcl
     * falls back to temp+rename). */
    if (Winfs_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"filesystem helper initialization");
    }
    Tcl_StaticLibrary(interp, "Winfs", Winfs_Init, NULL);
#endif

#ifdef ELS_STATIC_WINDROP
    /* els::win_drop_register -- Explorer drag-and-drop (harmless if absent: els.tcl
     * only registers drop targets when the command exists). */
    if (Windrop_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"drag-and-drop initialization");
    }
    Tcl_StaticLibrary(interp, "Windrop", Windrop_Init, NULL);
#endif

    return TCL_OK;
}
