/* windrop.c -- native Explorer drag-and-drop for els, exposed to Tcl.
 *
 *   els::win_drop_register <hwnd>
 *
 * Turn <hwnd> (a Tk window's HWND, from `winfo id`) into a file drop target:
 * DragAcceptFiles + a comctl32 SetWindowSubclass whose WM_DROPFILES branch reads
 * the dropped paths and hands them to Tcl via els::drop_open.
 *
 * Safety: the subclass proc runs inside the window's message dispatch, which may
 * itself be nested inside a running Tcl command (e.g. during `update`).  So it
 * NEVER evaluates Tcl inline -- it collects the paths, Tcl_QueueEvent's an event,
 * and returns; the event runs els::drop_open at a safe point in Tk's event loop.
 * The subclass removes itself on WM_NCDESTROY so window teardown stays clean.
 *
 * Tk pumps the Windows message queue on the main (Tcl) thread, so the subclass
 * proc and Tcl_QueueEvent both run on that thread -- no cross-thread handoff.
 *
 * C23 + Tcl stubs.  Built by `z build-ext` (-> build/windrop.dll, compile-checked
 * only) and compiled straight into the native els.exe (Windrop_Init, registered in
 * src/els_main.c).  Links comctl32 (subclassing) + shell32 (HDROP).
 */
#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>   /* DragAcceptFiles, DragQueryFileW, DragFinish, HDROP */
#include <commctrl.h>   /* SetWindowSubclass, DefSubclassProc */
#include <stdint.h>

/* The interp to run els::drop_open in.  Set at register time on the main thread;
 * the subclass proc runs on the same thread, so a plain global is safe. */
static Tcl_Interp *g_interp = NULL;

/* A queued event carrying the dropped path list (a Tcl list obj). */
typedef struct DropEvent {
    Tcl_Event ev;
    Tcl_Obj  *paths;
} DropEvent;

/* Runs at a safe point in Tk's event loop (never from inside the wndproc). */
static int DropEventProc(Tcl_Event *evPtr, [[maybe_unused]] int flags) {
    DropEvent *de = (DropEvent *)evPtr;
    if (g_interp != NULL) {
        Tcl_Obj *cmd = Tcl_NewListObj(0, NULL);
        Tcl_IncrRefCount(cmd);
        Tcl_ListObjAppendElement(g_interp, cmd, Tcl_NewStringObj("::els::drop_open", -1));
        Tcl_ListObjAppendElement(g_interp, cmd, de->paths);
        /* errors (missing proc, etc.) route to bgerror; never crash the editor */
        if (Tcl_EvalObjEx(g_interp, cmd, TCL_EVAL_GLOBAL) != TCL_OK) {
            Tcl_BackgroundException(g_interp, TCL_ERROR);
        }
        Tcl_DecrRefCount(cmd);
    }
    Tcl_DecrRefCount(de->paths);
    return 1;   /* handled -> Tcl frees the event */
}

static LRESULT CALLBACK DropSubclassProc(HWND hwnd, UINT msg, WPARAM wParam,
                                         LPARAM lParam, UINT_PTR uid,
                                         [[maybe_unused]] DWORD_PTR ref) {
    if (msg == WM_DROPFILES) {
        HDROP hDrop = (HDROP)wParam;
        UINT n = DragQueryFileW(hDrop, 0xFFFFFFFFu, NULL, 0);
        Tcl_Obj *paths = Tcl_NewListObj(0, NULL);
        for (UINT i = 0; i < n; i++) {
            UINT len = DragQueryFileW(hDrop, i, NULL, 0);       /* chars, no NUL */
            if (len == 0) continue;
            WCHAR *wbuf = (WCHAR *)Tcl_Alloc((size_t)(len + 1) * sizeof(WCHAR));
            if (DragQueryFileW(hDrop, i, wbuf, len + 1) > 0) {
                /* WC_ERR_INVALID_CHARS: a dropped NTFS name with an unpaired UTF-16
                 * surrogate (legal on NTFS) makes this return 0 -> the path is
                 * SKIPPED, not silently converted with U+FFFD into a DIFFERENT,
                 * nonexistent path (which drop_open would then quietly ignore).
                 * Mirrors winfs.c utf8_to_wide's rejection policy (F43). */
                int u8 = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wbuf, -1, NULL, 0, NULL, NULL);
                if (u8 > 0) {
                    char *s = (char *)Tcl_Alloc((size_t)u8);
                    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wbuf, -1, s, u8, NULL, NULL);
                    Tcl_ListObjAppendElement(NULL, paths, Tcl_NewStringObj(s, u8 - 1));
                    Tcl_Free(s);
                }
            }
            Tcl_Free((char *)wbuf);
        }
        DragFinish(hDrop);

        DropEvent *de = (DropEvent *)Tcl_Alloc(sizeof(DropEvent));
        de->ev.proc = DropEventProc;
        de->ev.nextPtr = NULL;
        de->paths = paths;
        Tcl_IncrRefCount(de->paths);
        Tcl_QueueEvent((Tcl_Event *)de, TCL_QUEUE_TAIL);
        return 0;
    }
    if (msg == WM_NCDESTROY) {
        RemoveWindowSubclass(hwnd, DropSubclassProc, uid);
    }
    return DefSubclassProc(hwnd, msg, wParam, lParam);
}

static int DropRegister_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                            int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    Tcl_WideInt h;
    if (Tcl_GetWideIntFromObj(ip, objv[1], &h) != TCL_OK) return TCL_ERROR;
    HWND hwnd = (HWND)(intptr_t)h;
    if (!IsWindow(hwnd)) { Tcl_SetObjResult(ip, Tcl_NewStringObj("not a window", -1)); return TCL_OK; }
    g_interp = ip;
    /* uid 1: re-registering the same window is idempotent (SetWindowSubclass
     * replaces the existing entry for the same proc+uid). */
    if (!SetWindowSubclass(hwnd, DropSubclassProc, 1, 0)) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("subclass failed", -1));
        return TCL_OK;
    }
    DragAcceptFiles(hwnd, TRUE);
    Tcl_SetObjResult(ip, Tcl_NewObj());   /* "" = ok */
    return TCL_OK;
}

int Windrop_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(ip, "::els::win_drop_register", DropRegister_Cmd, NULL, NULL);
    if (Tcl_PkgProvide(ip, "windrop", "0.1") != TCL_OK) return TCL_ERROR;
    return TCL_OK;
}
