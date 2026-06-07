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
    HMODULE h = LoadLibraryA("icu.dll");
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
    Tcl_Size len;
    unsigned char *bytes = Tcl_GetByteArrayFromObj(objv[1], &len);
    int err = 0;
    UCSD det = p_open(&err);
    if (err > 0 || !det) { Tcl_SetObjResult(ip, Tcl_NewObj()); return TCL_OK; }
    err = 0; p_setText(det, (const char *)bytes, (int)len, &err);
    err = 0; UCSM m = p_detect(det, &err);
    /* build the {name conf} list only on success; allocate the empty fallback
     * obj only when there is no match — creating it up front and overwriting it
     * with the list would abandon (leak) the empty obj on every detection. */
    Tcl_Obj *res = nullptr;
    if (m && err <= 0) {
        err = 0; const char *name = p_getName(m, &err);
        err = 0; int conf = p_getConfidence(m, &err);
        if (name) {
            res = Tcl_NewListObj(0, nullptr);
            Tcl_ListObjAppendElement(ip, res, Tcl_NewStringObj(name, -1));
            Tcl_ListObjAppendElement(ip, res, Tcl_NewIntObj(conf));
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
    Tcl_PkgProvide(ip, "elsdet", "0.1");
    return TCL_OK;
}
