/* winfs.c -- native filesystem helpers for els, exposed to Tcl.
 *
 *   els::win_replace_file <target> <replacement>
 *
 * Atomically replace <target> with <replacement> (a temp written alongside it)
 * via the Win32 ReplaceFileW, PRESERVING the target's security descriptor
 * (ACLs), alternate data streams (e.g. the mark-of-the-web Zone.Identifier),
 * attributes, and creation time -- all of which a plain rename-replace drops.
 * <target> must already exist and be on the same volume as <replacement>.
 * Returns "" on success, or a short error string on failure, so els::write_atomic
 * can fall back to its pure-Tcl temp+rename path.
 *
 * C23 + Tcl stubs.  Built by `z build-ext` (-> build/winfs.dll) and compiled
 * straight into the native els.exe (Winfs_Init, registered in src/els_main.c).
 */
#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Tcl's strings are (modified) UTF-8; convert to UTF-16 for the wide API.  For
 * file paths (no embedded NUL) standard CP_UTF8 is correct for every BMP code
 * point; a rare non-BMP path that converts imperfectly just makes ReplaceFileW
 * fail, and els falls back. */
static WCHAR *utf8_to_wide(const char *s, Tcl_Size n) {
    int wlen = MultiByteToWideChar(CP_UTF8, 0, s, (int)n, nullptr, 0);
    if (wlen <= 0) return nullptr;
    WCHAR *w = (WCHAR *)Tcl_Alloc((size_t)(wlen + 1) * sizeof(WCHAR));
    MultiByteToWideChar(CP_UTF8, 0, s, (int)n, w, wlen);
    w[wlen] = L'\0';
    return w;
}

static int ReplaceFile_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                           int objc, Tcl_Obj *const objv[]) {
    if (objc != 3) {
        Tcl_WrongNumArgs(ip, 1, objv, "target replacement");
        return TCL_ERROR;
    }
    Tcl_Size tn, rn;
    const char *t = Tcl_GetStringFromObj(objv[1], &tn);
    const char *r = Tcl_GetStringFromObj(objv[2], &rn);
    WCHAR *wt = utf8_to_wide(t, tn);
    WCHAR *wr = utf8_to_wide(r, rn);
    if (wt == nullptr || wr == nullptr) {
        if (wt) Tcl_Free((char *)wt);
        if (wr) Tcl_Free((char *)wr);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("path conversion failed", -1));
        return TCL_OK;
    }
    /* IGNORE_MERGE_ERRORS: still replace atomically even if some ACL/attribute
     * couldn't be carried over (preserve what we can; never block the save). */
    BOOL ok = ReplaceFileW(wt, wr, nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS,
                           nullptr, nullptr);
    DWORD gle = ok ? 0u : GetLastError();
    Tcl_Free((char *)wt);
    Tcl_Free((char *)wr);
    if (ok) {
        Tcl_SetObjResult(ip, Tcl_NewObj());                 /* "" = success */
    } else {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("ReplaceFileW error %lu",
                                            (unsigned long)gle));
    }
    return TCL_OK;
}

/* ---- session liveness via a held byte-range lock --------------------------
 * els::win_lock_file <path>  : open <path> and hold an exclusive byte-range lock
 *   for the process lifetime -> "" on success (lock held), else an error string.
 *   The OS releases the lock when the process dies (crash, kill, BSOD, reboot),
 *   so the lock is a crash- and PID-reuse-proof "this session is alive" token.
 * els::win_unlock_file       : release + close the held lock (clean quit).
 * els::win_try_lock <path>   : non-blocking probe -> "1" if the lock is FREE
 *   (no live owner -> the session that wrote this lock is dead) or "0" if HELD
 *   (a live instance owns it).  Used by the recovery scan to skip live peers. */
static HANDLE g_lock = INVALID_HANDLE_VALUE;
static WCHAR  g_lock_path[MAX_PATH * 2];   /* path the held lock was opened on */

static int LockFile_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                        int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    Tcl_Size n; const char *p = Tcl_GetStringFromObj(objv[1], &n);
    WCHAR *w = utf8_to_wide(p, n);
    if (w == nullptr) { Tcl_SetObjResult(ip, Tcl_NewStringObj("path conversion failed", -1)); return TCL_OK; }
    /* re-acquiring the path we already hold must be idempotent: byte-range
     * locks conflict across handles even within one process, so a second open
     * + LockFileEx on the same path would FAIL and look like "another
     * instance owns my lock" */
    if (g_lock != INVALID_HANDLE_VALUE && _wcsicmp(w, g_lock_path) == 0) {
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_NewObj());
        return TCL_OK;
    }
    /* NO FILE_SHARE_DELETE: it would grant every other process DELETE access
     * to the lock file while the lock is held — on Win11 (POSIX delete
     * semantics) the name unlinks immediately, a peer's try-lock then sees
     * FILE_NOT_FOUND = "owner dead", and a LIVE session's swaps get recovered
     * by a second instance.  Nothing in els requests DELETE while it's held. */
    HANDLE h = CreateFileW(w, GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    DWORD gle = GetLastError();           /* capture BEFORE Tcl_Free clobbers it */
    if (h == INVALID_HANDLE_VALUE) {
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("open lock error %lu", (unsigned long)gle));
        return TCL_OK;
    }
    OVERLAPPED ov = {0};
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov)) {
        DWORD gle2 = GetLastError();
        CloseHandle(h);
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("lock held (error %lu)", (unsigned long)gle2));
        return TCL_OK;
    }
    if (g_lock != INVALID_HANDLE_VALUE) { CloseHandle(g_lock); }  /* replace any prior */
    g_lock = h;
    wcsncpy(g_lock_path, w, (sizeof g_lock_path / sizeof g_lock_path[0]) - 1);
    g_lock_path[(sizeof g_lock_path / sizeof g_lock_path[0]) - 1] = L'\0';
    Tcl_Free((char *)w);
    Tcl_SetObjResult(ip, Tcl_NewObj());     /* "" = success, lock held */
    return TCL_OK;
}

static int UnlockFile_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                          [[maybe_unused]] int objc, [[maybe_unused]] Tcl_Obj *const objv[]) {
    if (g_lock != INVALID_HANDLE_VALUE) {
        OVERLAPPED ov = {0};
        UnlockFileEx(g_lock, 0, 1, 0, &ov);
        CloseHandle(g_lock);
        g_lock = INVALID_HANDLE_VALUE;
        g_lock_path[0] = L'\0';
    }
    Tcl_SetObjResult(ip, Tcl_NewObj());
    return TCL_OK;
}

static int TryLock_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                       int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    Tcl_Size n; const char *p = Tcl_GetStringFromObj(objv[1], &n);
    WCHAR *w = utf8_to_wide(p, n);
    if (w == nullptr) { Tcl_SetObjResult(ip, Tcl_NewStringObj("0", -1)); return TCL_OK; }
    HANDLE h = CreateFileW(w, GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    DWORD gle = GetLastError();           /* capture BEFORE Tcl_Free clobbers it */
    Tcl_Free((char *)w);
    if (h == INVALID_HANDLE_VALUE) {
        /* no such lock file -> no owner -> dead ("1"); any other open failure ->
         * be conservative and treat as live ("0", don't recover a maybe-live one) */
        const char *r = (gle == ERROR_FILE_NOT_FOUND || gle == ERROR_PATH_NOT_FOUND) ? "1" : "0";
        Tcl_SetObjResult(ip, Tcl_NewStringObj(r, -1));
        return TCL_OK;
    }
    OVERLAPPED ov = {0};
    BOOL got = LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov);
    if (got) {
        OVERLAPPED ov2 = {0};
        UnlockFileEx(h, 0, 1, 0, &ov2);
    }
    CloseHandle(h);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(got ? "1" : "0", -1));   /* 1=free/dead, 0=held/live */
    return TCL_OK;
}

/* ---- virtual desktop geometry ---------------------------------------------
 * els::win_virtual_screen -> "x y w h" of the VIRTUAL desktop: the bounding rect
 * of ALL monitors, with x/y the (possibly negative) top-left.  Tk's `wm maxsize`
 * and `winfo screenwidth` report only the PRIMARY monitor on Windows, so a saved
 * window on a monitor to the right of / below the primary would be wrongly judged
 * off-screen; the geometry clamp (els::clamp_geometry) needs the true union. */
static int VirtualScreen_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                             [[maybe_unused]] int objc, [[maybe_unused]] Tcl_Obj *const objv[]) {
    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    Tcl_Obj *r = Tcl_NewListObj(0, nullptr);
    Tcl_ListObjAppendElement(ip, r, Tcl_NewIntObj(x));
    Tcl_ListObjAppendElement(ip, r, Tcl_NewIntObj(y));
    Tcl_ListObjAppendElement(ip, r, Tcl_NewIntObj(w));
    Tcl_ListObjAppendElement(ip, r, Tcl_NewIntObj(h));
    Tcl_SetObjResult(ip, r);
    return TCL_OK;
}

int Winfs_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    /* fully-qualified name: Tcl creates ::els if it doesn't exist yet (this Init
     * may run before main.tcl is sourced, in the native build). */
    Tcl_CreateObjCommand(ip, "::els::win_replace_file",   ReplaceFile_Cmd,   nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_lock_file",      LockFile_Cmd,      nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_unlock_file",    UnlockFile_Cmd,    nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_try_lock",       TryLock_Cmd,       nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_virtual_screen", VirtualScreen_Cmd, nullptr, nullptr);
    if (Tcl_PkgProvide(ip, "winfs", "0.1") != TCL_OK) return TCL_ERROR;
    return TCL_OK;
}
