/* cap.c -- isolated screenshot support.
 *
 * `elscap::run_private timeoutMs executable ?arg ...?` creates a private
 * Win32 desktop, starts one suspended child on it, assigns that child (and its
 * descendants) to a kill-on-close Job, resumes it, and waits with a bounded
 * timeout.  The desktop is never passed to SwitchDesktop and therefore never
 * becomes the interactive/input desktop.  Tk may map, focus and paint normally
 * there without producing a visible window on the user's desktop.
 *
 * The child uses `elscap::window hwnd` to PrintWindow one of its own, normally
 * mapped toplevels into a DIB.  tools/shot.tcl converts that DIB to PNG.
 * Foreground HWND equality is checked around both capture and the complete
 * private-desktop child lifetime.
 *
 * C23 + Tcl stubs; links user32 + gdi32.  Built by `z build-ext`.
 */
#include <tcl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

static int fail(Tcl_Interp *ip, const char *msg) {
    Tcl_SetObjResult(ip, Tcl_NewStringObj(msg, -1));
    return TCL_ERROR;
}

static int win_fail(Tcl_Interp *ip, const char *action, DWORD code) {
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s failed (Windows error %lu)",
                                      action, (unsigned long)code));
    return TCL_ERROR;
}

static Tcl_Obj *hwnd_obj(HWND hwnd) {
    return Tcl_NewWideIntObj((Tcl_WideInt)(intptr_t)hwnd);
}

static int get_hwnd(Tcl_Interp *ip, Tcl_Obj *obj, HWND *out) {
    Tcl_WideInt value;
    if (Tcl_GetWideIntFromObj(ip, obj, &value) != TCL_OK) return TCL_ERROR;
    HWND hwnd = (HWND)(intptr_t)value;
    if (!IsWindow(hwnd)) return fail(ip, "no such window");
    *out = hwnd;
    return TCL_OK;
}

static int foreground_unchanged(Tcl_Interp *ip, HWND before, const char *action) {
    HWND after = GetForegroundWindow();
    if (after == before) return TCL_OK;
    Tcl_SetObjResult(ip, Tcl_ObjPrintf(
        "foreground window changed during %s (before=%lld, after=%lld)", action,
        (long long)(intptr_t)before, (long long)(intptr_t)after));
    return TCL_ERROR;
}

static int Foreground_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                          int objc, Tcl_Obj *const objv[]) {
    if (objc != 1) { Tcl_WrongNumArgs(ip, 1, objv, ""); return TCL_ERROR; }
    Tcl_SetObjResult(ip, hwnd_obj(GetForegroundWindow()));
    return TCL_OK;
}

static int Window_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                      int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "hwnd"); return TCL_ERROR; }
    HWND hwnd;
    if (get_hwnd(ip, objv[1], &hwnd) != TCL_OK) return TCL_ERROR;

    RECT r;
    if (!GetWindowRect(hwnd, &r)) return win_fail(ip, "GetWindowRect", GetLastError());
    int64_t width = (int64_t)r.right - (int64_t)r.left;
    int64_t height = (int64_t)r.bottom - (int64_t)r.top;
    if (width < 1 || height < 1 || width > INT_MAX || height > INT_MAX) {
        return fail(ip, "window has invalid dimensions");
    }
    int w = (int)width, h = (int)height;
    if ((Tcl_WideInt)w > (TCL_SIZE_MAX - 40) / 4 / h) {
        return fail(ip, "window is too large to capture safely");
    }

    HWND foreground = GetForegroundWindow();
    HDC screen = GetDC(NULL);
    if (!screen) return win_fail(ip, "GetDC", GetLastError());
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
    if (!mem || !bmp) {
        DWORD code = GetLastError();
        if (bmp) DeleteObject(bmp);
        if (mem) DeleteDC(mem);
        ReleaseDC(NULL, screen);
        return win_fail(ip, "GDI bitmap/DC allocation", code);
    }
    HGDIOBJ old = SelectObject(mem, bmp);
    if (!old || old == HGDI_ERROR) {
        DeleteObject(bmp);
        DeleteDC(mem);
        ReleaseDC(NULL, screen);
        return fail(ip, "SelectObject failed");
    }
    BOOL printed = PrintWindow(hwnd, mem, PW_RENDERFULLCONTENT);
    SelectObject(mem, old); /* bmp must not remain selected for GetDIBits */

    BITMAPINFOHEADER bih = {0};
    bih.biSize = sizeof(BITMAPINFOHEADER);
    bih.biWidth = w;
    bih.biHeight = -h; /* negative => top-down rows */
    bih.biPlanes = 1;
    bih.biBitCount = 32;
    bih.biCompression = BI_RGB;

    Tcl_Size npix = (Tcl_Size)w * (Tcl_Size)h * 4;
    unsigned char *buf = (unsigned char *)Tcl_Alloc(40 + npix);
    memcpy(buf, &bih, 40);
    BITMAPINFOHEADER query = bih; /* GetDIBits treats this as in+out */
    int lines = GetDIBits(screen, bmp, 0, (UINT)h, buf + 40,
                          (BITMAPINFO *)&query, DIB_RGB_COLORS);

    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);

    if (!printed || lines != h) {
        Tcl_Free((char *)buf);
        return fail(ip, "PrintWindow/GetDIBits failed");
    }
    if (foreground_unchanged(ip, foreground, "PrintWindow capture") != TCL_OK) {
        Tcl_Free((char *)buf);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewByteArrayObj(buf, 40 + npix));
    Tcl_Free((char *)buf);
    return TCL_OK;
}

typedef struct {
    wchar_t *data;
    size_t len;
    size_t cap;
} WideBuffer;

static int wb_reserve(WideBuffer *b, size_t extra) {
    /* CreateProcessW's 32767-unit limit includes the trailing NUL. */
    if (extra > 32766 || b->len > 32766 - extra) return 0;
    size_t needed = b->len + extra + 1;
    if (needed <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < needed) {
        if (cap > 32767 / 2) { cap = 32767; break; }
        cap *= 2;
    }
    wchar_t *next = b->data
        ? (wchar_t *)HeapReAlloc(GetProcessHeap(), 0, b->data, cap * sizeof(wchar_t))
        : (wchar_t *)HeapAlloc(GetProcessHeap(), 0, cap * sizeof(wchar_t));
    if (!next) return 0;
    b->data = next;
    b->cap = cap;
    return 1;
}

static int wb_chars(WideBuffer *b, wchar_t c, size_t count) {
    if (!wb_reserve(b, count)) return 0;
    for (size_t i = 0; i < count; ++i) b->data[b->len++] = c;
    b->data[b->len] = L'\0';
    return 1;
}

static int wb_span(WideBuffer *b, const wchar_t *s, size_t count) {
    if (!wb_reserve(b, count)) return 0;
    memcpy(b->data + b->len, s, count * sizeof(wchar_t));
    b->len += count;
    b->data[b->len] = L'\0';
    return 1;
}

/* Quote one argv element using the CommandLineToArgvW/MS C-runtime rules. */
static int wb_arg(WideBuffer *b, const wchar_t *arg) {
    size_t n = wcslen(arg);
    int quote = n == 0 || wcspbrk(arg, L" \t\"") != NULL;
    if (!quote) return wb_span(b, arg, n);
    if (!wb_chars(b, L'"', 1)) return 0;
    size_t slashes = 0;
    for (size_t i = 0; i < n; ++i) {
        wchar_t c = arg[i];
        if (c == L'\\') {
            ++slashes;
        } else if (c == L'"') {
            if (!wb_chars(b, L'\\', slashes * 2 + 1)
                    || !wb_chars(b, L'"', 1)) return 0;
            slashes = 0;
        } else {
            if (!wb_chars(b, L'\\', slashes) || !wb_chars(b, c, 1)) return 0;
            slashes = 0;
        }
    }
    return wb_chars(b, L'\\', slashes * 2) && wb_chars(b, L'"', 1);
}

static int obj_to_wide(Tcl_Interp *ip, Tcl_Obj *obj, Tcl_DString *ds,
                       const wchar_t **wide) {
    Tcl_Size len;
    const char *utf = Tcl_GetStringFromObj(obj, &len);
    Tcl_DStringInit(ds);
    *wide = Tcl_UtfToWCharDString(utf, len, ds);
    if (!*wide) { Tcl_DStringFree(ds); return fail(ip, "UTF-16 conversion failed"); }
    Tcl_Size wide_bytes = Tcl_DStringLength(ds);
    if (wide_bytes < 0 || wide_bytes % (Tcl_Size)sizeof(wchar_t) != 0) {
        Tcl_DStringFree(ds);
        return fail(ip, "UTF-16 conversion produced an invalid length");
    }
    size_t wide_units = (size_t)wide_bytes / sizeof(wchar_t);
    if (wmemchr(*wide, L'\0', wide_units) != NULL) {
        Tcl_DStringFree(ds);
        return fail(ip, "argument contains NUL");
    }
    return TCL_OK;
}

static int terminate_process_bounded(HANDLE process, DWORD exit_code,
                                     DWORD timeout, DWORD *error_code) {
    DWORD state = WaitForSingleObject(process, 0);
    if (state == WAIT_OBJECT_0) return 1;
    if (state == WAIT_FAILED) { *error_code = GetLastError(); return 0; }
    if (!TerminateProcess(process, exit_code)) {
        DWORD terminate_error = GetLastError();
        if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0) return 1;
        *error_code = terminate_error;
        return 0;
    }
    state = WaitForSingleObject(process, timeout);
    if (state == WAIT_OBJECT_0) return 1;
    *error_code = state == WAIT_FAILED ? GetLastError() : WAIT_TIMEOUT;
    return 0;
}

static LONG private_counter = 0;

static int RunPrivate_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                          int objc, Tcl_Obj *const objv[]) {
    if (objc < 3) {
        Tcl_WrongNumArgs(ip, 1, objv, "timeoutMs executable ?arg ...?");
        return TCL_ERROR;
    }
    int timeout;
    if (Tcl_GetIntFromObj(ip, objv[1], &timeout) != TCL_OK) return TCL_ERROR;
    if (timeout < 100 || timeout > 120000) {
        return fail(ip, "timeoutMs must be in 100..120000");
    }

    WideBuffer cmd = {0};
    Tcl_DString app_ds;
    const wchar_t *application = NULL;
    if (obj_to_wide(ip, objv[2], &app_ds, &application) != TCL_OK) return TCL_ERROR;
    int build_ok = 1;
    for (int i = 2; i < objc && build_ok; ++i) {
        Tcl_DString arg_ds;
        const wchar_t *arg;
        if (obj_to_wide(ip, objv[i], &arg_ds, &arg) != TCL_OK) {
            build_ok = 0;
            break;
        }
        if (i > 2) build_ok = wb_chars(&cmd, L' ', 1);
        if (build_ok) build_ok = wb_arg(&cmd, arg);
        Tcl_DStringFree(&arg_ds);
    }
    if (!build_ok || !cmd.data) {
        if (cmd.data) HeapFree(GetProcessHeap(), 0, cmd.data);
        Tcl_DStringFree(&app_ds);
        if (Tcl_GetStringResult(ip)[0] == '\0') {
            fail(ip, "private child command line exceeds 32766 UTF-16 code units");
        }
        return TCL_ERROR;
    }

    wchar_t desktop_name[128];
    LONG serial = InterlockedIncrement(&private_counter);
    _snwprintf_s(desktop_name, _countof(desktop_name), _TRUNCATE,
        L"els-shot-%lu-%llu-%ld", (unsigned long)GetCurrentProcessId(),
        (unsigned long long)GetTickCount64(), (long)serial);

    HWND foreground = GetForegroundWindow();
    HDESK desktop = NULL;
    HANDLE job = NULL;
    PROCESS_INFORMATION pi = {0};
    DWORD child_exit = 0;
    DWORD child_pid = 0;
    DWORD failure_code = 0;
    const char *failure_action = NULL;

    desktop = CreateDesktopW(desktop_name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop) { failure_action = "CreateDesktopW"; failure_code = GetLastError(); goto cleanup; }
    job = CreateJobObjectW(NULL, NULL);
    if (!job) { failure_action = "CreateJobObjectW"; failure_code = GetLastError(); goto cleanup; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
            &limits, sizeof(limits))) {
        failure_action = "SetInformationJobObject"; failure_code = GetLastError(); goto cleanup;
    }

    STARTUPINFOW si = {0};
    si.cb = sizeof(si);
    si.lpDesktop = desktop_name;
    /* A GUI-subsystem child otherwise enables Windows' startup-feedback cursor
     * heuristics.  Its windows are private, and its pointer feedback must be
     * just as invisible on the user's input desktop. */
    si.dwFlags = STARTF_FORCEOFFFEEDBACK;
    if (!CreateProcessW(application, cmd.data, NULL, NULL, FALSE,
            CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, NULL, NULL, &si, &pi)) {
        failure_action = "CreateProcessW(private desktop)";
        failure_code = GetLastError();
        goto cleanup;
    }
    child_pid = pi.dwProcessId;
    if (!AssignProcessToJobObject(job, pi.hProcess)) {
        DWORD assign_error = GetLastError();
        DWORD cleanup_error = 0;
        if (!terminate_process_bounded(pi.hProcess, 1, 5000, &cleanup_error)) {
            failure_action = "terminating unassigned private child";
            failure_code = cleanup_error;
        } else {
            failure_action = "AssignProcessToJobObject";
            failure_code = assign_error;
        }
        goto cleanup;
    }
    if (ResumeThread(pi.hThread) == (DWORD)-1) {
        failure_action = "ResumeThread"; failure_code = GetLastError();
        TerminateJobObject(job, 1);
        goto cleanup;
    }

    DWORD waited = WaitForSingleObject(pi.hProcess, (DWORD)timeout);
    if (waited == WAIT_TIMEOUT) {
        TerminateJobObject(job, 124);
        WaitForSingleObject(pi.hProcess, 5000);
        failure_action = "private screenshot child timed out";
        failure_code = WAIT_TIMEOUT;
        goto cleanup;
    }
    if (waited != WAIT_OBJECT_0) {
        failure_action = "WaitForSingleObject"; failure_code = GetLastError(); goto cleanup;
    }
    if (!GetExitCodeProcess(pi.hProcess, &child_exit)) {
        failure_action = "GetExitCodeProcess"; failure_code = GetLastError(); goto cleanup;
    }

cleanup:
    if (pi.hThread) CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    /* Closing a kill-on-close job also removes any worker descendants that the
     * editor scene started; none can retain the private desktop. */
    if (job) CloseHandle(job);
    if (desktop && !CloseDesktop(desktop) && !failure_action) {
        failure_action = "CloseDesktop";
        failure_code = GetLastError();
    }
    HeapFree(GetProcessHeap(), 0, cmd.data);
    Tcl_DStringFree(&app_ds);

    if (foreground_unchanged(ip, foreground, "private-desktop child lifetime") != TCL_OK) {
        return TCL_ERROR;
    }
    if (failure_action) return win_fail(ip, failure_action, failure_code);
    if (child_exit != 0) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("private screenshot child exited with code %lu",
                                          (unsigned long)child_exit));
        return TCL_ERROR;
    }

    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_DictObjPut(ip, result, Tcl_NewStringObj("pid", -1),
                   Tcl_NewWideIntObj((Tcl_WideInt)child_pid));
    Tcl_DictObjPut(ip, result, Tcl_NewStringObj("exit_code", -1), Tcl_NewIntObj(0));
    Tcl_DictObjPut(ip, result, Tcl_NewStringObj("private_desktop", -1), Tcl_NewIntObj(1));
    Tcl_DictObjPut(ip, result, Tcl_NewStringObj("foreground", -1), hwnd_obj(foreground));
    Tcl_SetObjResult(ip, result);
    return TCL_OK;
}

int Cap_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    Tcl_CreateNamespace(ip, "elscap", nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "elscap::foreground", Foreground_Cmd, nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "elscap::window", Window_Cmd, nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "elscap::run_private", RunPrivate_Cmd, nullptr, nullptr);
    Tcl_PkgProvide(ip, "elscap", "0.1");
    return TCL_OK;
}
