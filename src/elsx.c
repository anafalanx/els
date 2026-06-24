/* elsx.c — a tiny C23 Tcl extension, proving the C<->Tcl integration path.
 *
 * Demonstrates that els can drop into C23 for hot paths or to bind a C library,
 * exposed to the Tcl side as ordinary commands.  Built against the Tcl *stubs*
 * (compiler-independent ABI), so the .dll loads into the vendored Tcl 9.
 *
 * Build (see tools/tasks.tcl `build-ext`):
 *   gcc -std=c23 -shared -DUSE_TCL_STUBS -I<tcl>/include \
 *       src/elsx.c -o build/elsx.dll -L<tcl>/lib -ltclstub
 * Load:
 *   load build/elsx.dll Elsx ; elsx::hello ; elsx::sum 1 2 3
 */
#include <tcl.h>

/* C23: constexpr, attributes, the nullptr / true / false keywords. */
static constexpr int ELSX_ANSWER = 42;

[[nodiscard]]
static int accumulate(Tcl_Interp *ip, int objc, Tcl_Obj *const objv[], Tcl_WideInt *out) {
    Tcl_WideInt acc = 0;
    for (int i = 1; i < objc; i++) {
        Tcl_WideInt v;
        if (Tcl_GetWideIntFromObj(ip, objv[i], &v) != TCL_OK) return TCL_ERROR;
        acc += v;
    }
    *out = acc;
    return TCL_OK;
}

static int Hello_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                     [[maybe_unused]] int objc, [[maybe_unused]] Tcl_Obj *const objv[]) {
    Tcl_SetObjResult(ip, Tcl_ObjPrintf(
        "hello from C23 (gcc %d.%d.%d), answer=%d",
        __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__, ELSX_ANSWER));
    return TCL_OK;
}

static int Sum_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                   int objc, Tcl_Obj *const objv[]) {
    Tcl_WideInt total = 0;
    if (accumulate(ip, objc, objv, &total) != TCL_OK) return TCL_ERROR;
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(total));
    return TCL_OK;
}

/* DLL entry point.  `load elsx.dll Elsx` calls Elsx_Init. */
int Elsx_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    Tcl_CreateNamespace(ip, "elsx", nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "elsx::hello", Hello_Cmd, nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "elsx::sum",   Sum_Cmd,   nullptr, nullptr);
    Tcl_PkgProvide(ip, "elsx", "0.1");
    return TCL_OK;
}
