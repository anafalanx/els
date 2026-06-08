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
 * C23 + Tcl stubs.  Built by `x build-ext` (-> build/winfs.dll) and compiled
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

int Winfs_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    /* fully-qualified name: Tcl creates ::els if it doesn't exist yet (this Init
     * may run before main.tcl is sourced, in the native build). */
    Tcl_CreateObjCommand(ip, "::els::win_replace_file", ReplaceFile_Cmd, nullptr, nullptr);
    if (Tcl_PkgProvide(ip, "winfs", "0.1") != TCL_OK) return TCL_ERROR;
    return TCL_OK;
}
