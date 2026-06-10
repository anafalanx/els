/* icudet.c — charset detection via the Windows system ICU (icu.dll), exposed to
 * Tcl as `elsdet::detect <bytes> -> {charset confidence}` (empty if ICU's
 * detector is unavailable).  Windows 10 1903+ / 11 ship ICU as a system DLL, so
 * this needs nothing vendored — it dynamically loads icu.dll and resolves the
 * ucsdet_* charset-detector entry points (the same approach the C-era els used
 * for ICU regex).  els maps the returned ICU name to a Tcl encoding.
 *
 * C23 + Tcl stubs.  Built by `x build-ext`.
 */
#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* ucsdet_* signatures (UErrorCode and int32_t are int here) */
typedef void *UCSD;   /* UCharsetDetector* */
typedef void *UCSM;   /* const UCharsetMatch* */
static UCSD        (*p_open)(int *) = nullptr;
static void        (*p_setText)(UCSD, const char *, int, int *) = nullptr;
static UCSM        (*p_detect)(UCSD, int *) = nullptr;
static const char *(*p_getName)(UCSM, int *) = nullptr;
static int         (*p_getConfidence)(UCSM, int *) = nullptr;
static void        (*p_close)(UCSD) = nullptr;
static int g_state = -1;   /* -1 untried, 0 unavailable, 1 ready */

static int load_icu(void) {
    if (g_state >= 0) return g_state;
    g_state = 0;
    /* System32 ONLY: a bare LoadLibraryA searches the exe's directory first,
     * and els is a copy-the-folder portable app — an icu.dll planted next to
     * els.exe would be loaded and executed.  We only ever want the system ICU;
     * if it is absent, els falls back to BOM/UTF-8/cp1252 detection. */
    HMODULE h = LoadLibraryExA("icu.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!h) return 0;
    p_open          = (void *)GetProcAddress(h, "ucsdet_open");
    p_setText       = (void *)GetProcAddress(h, "ucsdet_setText");
    p_detect        = (void *)GetProcAddress(h, "ucsdet_detect");
    p_getName       = (void *)GetProcAddress(h, "ucsdet_getName");
    p_getConfidence = (void *)GetProcAddress(h, "ucsdet_getConfidence");
    p_close         = (void *)GetProcAddress(h, "ucsdet_close");
    if (p_open && p_setText && p_detect && p_getName && p_getConfidence && p_close) g_state = 1;
    return g_state;
}

static int Detect_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                      int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "bytes"); return TCL_ERROR; }
    if (!load_icu()) { Tcl_SetObjResult(ip, Tcl_NewObj()); return TCL_OK; }  /* empty = unavailable */
    /* In Tcl 9, Tcl_GetByteArrayFromObj returns NULL for a value with any
     * codepoint > U+00FF and then writes NOTHING to len — initialize it and
     * check the pointer, or `if (len <= 0)` reads an indeterminate value. */
    Tcl_Size len = 0;
    unsigned char *bytes = Tcl_GetByteArrayFromObj(objv[1], &len);
    /* nothing to detect on empty/non-byte input — and don't hand ICU a
     * 0-length / NULL buffer (ucsdet_setText on empty text is undefined for
     * some ICU builds) */
    if (bytes == nullptr || len <= 0) { Tcl_SetObjResult(ip, Tcl_NewObj()); return TCL_OK; }
    /* ucsdet_setText takes an int32: clamp (detection only reads a prefix
     * anyway; a >2 GiB length would go negative = "NUL-terminated" overread) */
    if (len > (Tcl_Size)(1 << 20)) { len = (Tcl_Size)(1 << 20); }
    int err = 0;
    UCSD det = p_open(&err);
    if (err > 0 || !det) { Tcl_SetObjResult(ip, Tcl_NewObj()); return TCL_OK; }
    /* build the {name conf} list only when every ICU step succeeds; allocate the
     * empty fallback obj only when there is no usable match (creating it up front
     * and overwriting it would abandon — leak — the empty obj on every match). */
    Tcl_Obj *res = nullptr;
    err = 0; p_setText(det, (const char *)bytes, (int)len, &err);
    if (err <= 0) {
        err = 0; UCSM m = p_detect(det, &err);
        if (m && err <= 0) {
            err = 0; const char *name = p_getName(m, &err);
            int nameOk = (err <= 0 && name != nullptr);
            err = 0; int conf = p_getConfidence(m, &err);
            int confOk = (err <= 0);
            if (nameOk && confOk) {
                Tcl_Obj *l = Tcl_NewListObj(0, nullptr);
                /* check the append return codes; on the (practically impossible)
                 * failure for a fresh list, discard l cleanly instead of leaking */
                if (Tcl_ListObjAppendElement(ip, l, Tcl_NewStringObj(name, -1)) == TCL_OK
                 && Tcl_ListObjAppendElement(ip, l, Tcl_NewIntObj(conf))      == TCL_OK) {
                    res = l;
                } else {
                    Tcl_IncrRefCount(l); Tcl_DecrRefCount(l);   /* free the partial list */
                }
            }
        }
    }
    if (res == nullptr) res = Tcl_NewObj();   /* empty = no detection */
    p_close(det);
    Tcl_SetObjResult(ip, res);
    return TCL_OK;
}

int Icudet_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    /* absolute names: Init may run with a non-global current namespace (els
     * loads this from inside `::els`), and relative names would land there. */
    Tcl_CreateNamespace(ip, "::elsdet", nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::elsdet::detect", Detect_Cmd, nullptr, nullptr);
    if (Tcl_PkgProvide(ip, "icudet", "0.1") != TCL_OK) return TCL_ERROR;
    if (Tcl_PkgProvide(ip, "elsdet", "0.1") != TCL_OK) return TCL_ERROR;
    return TCL_OK;
}
