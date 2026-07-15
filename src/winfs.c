/* winfs.c -- native filesystem helpers for els, exposed to Tcl.
 *
 *   els::win_replace_file <target> <replacement>
 *   els::win_open_folder <path>
 *   els::win_worker_spawn_watch <commandList> <workingDirectory>
 *
 * Atomically replace <target> with <replacement> (a temp written alongside it)
 * via Win32 ReplaceFileW.  Windows normally carries the target's security
 * descriptor, alternate data streams (e.g. Zone.Identifier), attributes, and
 * creation time; merge errors are deliberately non-fatal, so preservation is
 * best-effort while atomic replacement remains mandatory.
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
#include <limits.h>
#include <objbase.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* Tcl's strings are (modified) UTF-8; convert to UTF-16 for the wide API.
 * Reject invalid UTF-8, embedded NULs, and lengths the Win32 converter cannot
 * represent rather than acting on a DIFFERENT/truncated path.  Tcl itself cannot
 * reliably address rare NTFS names containing lone UTF-16 surrogates, so those
 * remain unsupported instead of being silently substituted. */
static WCHAR *utf8_to_wide(const char *s, Tcl_Size n) {
    if (n <= 0 || n > INT_MAX || memchr(s, '\0', (size_t)n) != nullptr) {
        return nullptr;
    }
    int inputLen = (int)n;
    int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   s, inputLen, nullptr, 0);
    if (wlen <= 0) return nullptr;
    WCHAR *w = (WCHAR *)Tcl_Alloc(((size_t)wlen + 1u) * sizeof(WCHAR));
    int converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        s, inputLen, w, wlen);
    if (converted != wlen) {
        Tcl_Free((char *)w);
        return nullptr;
    }
    w[wlen] = L'\0';

    /* Extended-length safety net.  Win32 path APIs are MAX_PATH(260)-bound unless
     * the path carries the \\?\ prefix.  Tcl 9's `file normalize` ALREADY adds that
     * prefix for >260-char paths (els even strips it back off for display — see
     * els::strip_ext_prefix), so the normal save path, which passes
     * `file nativename [file normalize …]`, arrives here already prefixed and the
     * guard below detects that and skips re-prefixing.  This branch is therefore a
     * DEFENSIVE fallback for any caller that hands us an un-normalized long path; it
     * does not fire on the normal save path, and short paths are byte-identical to
     * before.  Only fully-qualified backslash-separated drive/UNC paths qualify. */
    if (wlen >= MAX_PATH &&        /* >= not > : MAX_PATH (260) counts the NUL, so a
                                    * path of exactly 260 chars already exceeds the
                                    * non-prefixed Win32 limit and needs \\?\ (F39) */
        !(w[0] == L'\\' && w[1] == L'\\' && w[2] == L'?' && w[3] == L'\\')) {
        const WCHAR *pfx = nullptr;
        const WCHAR *tail = w;
        if (((w[0] >= L'A' && w[0] <= L'Z') || (w[0] >= L'a' && w[0] <= L'z')) &&
            w[1] == L':' && w[2] == L'\\') {
            pfx = L"\\\\?\\";                       /* C:\long…  ->  \\?\C:\long… */
        } else if (w[0] == L'\\' && w[1] == L'\\') {
            pfx = L"\\\\?\\UNC\\"; tail = w + 2;    /* \\srv\share…  ->  \\?\UNC\srv\share… */
        }
        if (pfx != nullptr) {
            size_t pl = wcslen(pfx), tl = wcslen(tail);
            WCHAR *pw = (WCHAR *)Tcl_Alloc((pl + tl + 1) * sizeof(WCHAR));
            wcscpy(pw, pfx);
            wcscat(pw, tail);
            Tcl_Free((char *)w);
            return pw;
        }
    }
    return w;
}

static WCHAR *utf8_to_wide_worker_arg(const char *s, Tcl_Size n) {
    if (n == 0) {
        WCHAR *empty = (WCHAR *)Tcl_Alloc(sizeof(WCHAR));
        empty[0] = L'\0';
        return empty;
    }
    return utf8_to_wide(s, n);
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

/* Open an existing directory through the Windows shell without routing a
 * document-derived path through cmd.exe.  Legal Windows names may contain
 * command metacharacters; ShellExecuteExW receives the path as a dedicated
 * argument and never reparses it as shell syntax.  Returns "" on success or a
 * short error string on failure. */
static int OpenFolder_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                          int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "path");
        return TCL_ERROR;
    }
    Tcl_Size n;
    const char *p = Tcl_GetStringFromObj(objv[1], &n);
    WCHAR *w = utf8_to_wide(p, n);
    if (w == nullptr) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("path conversion failed", -1));
        return TCL_OK;
    }

    DWORD attrs = GetFileAttributesW(w);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        DWORD gle = GetLastError();
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("folder lookup error %lu",
                                           (unsigned long)gle));
        return TCL_OK;
    }
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("path is not a directory", -1));
        return TCL_OK;
    }

    HRESULT co = CoInitializeEx(nullptr,
            COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    /* RPC_E_CHANGED_MODE means this Tcl thread is already initialized in a
     * different apartment (normally MTA), not that COM is unavailable.  The
     * shell call can still run; only a successful CoInitializeEx invocation
     * adds a reference that this function must balance. */
    BOOL uninitialize = SUCCEEDED(co);
    if (FAILED(co) && co != RPC_E_CHANGED_MODE) {
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("COM initialization error 0x%08lx",
                                           (unsigned long)co));
        return TCL_OK;
    }

    SHELLEXECUTEINFOW execInfo = {0};
    execInfo.cbSize = sizeof(execInfo);
    execInfo.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
    execInfo.lpVerb = L"open";
    execInfo.lpFile = w;
    execInfo.nShow = SW_SHOWNORMAL;
    BOOL ok = ShellExecuteExW(&execInfo);
    DWORD gle = ok ? 0u : GetLastError();
    if (uninitialize) {
        CoUninitialize();
    }
    Tcl_Free((char *)w);
    if (ok) {
        Tcl_SetObjResult(ip, Tcl_NewObj());
    } else {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("ShellExecuteExW error %lu",
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
/* Heap copy (ANY length) of the path the held lock was opened on.  A fixed buffer
 * truncated \\?\-prefixed long paths, so the idempotent-re-acquire compare below
 * stopped matching the same path and a second LockFileEx failed as "lock held" (F40). */
static WCHAR *g_lock_path = nullptr;

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
    if (g_lock != INVALID_HANDLE_VALUE && g_lock_path != nullptr && wcscmp(w, g_lock_path) == 0) {
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
    BOOL locked = LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov);
    if (!locked && GetLastError() == ERROR_LOCK_VIOLATION) {
        /* A peer's win_try_lock briefly HOLDS byte 0 to probe us (TryLock_Cmd locks
         * then immediately unlocks).  If our own acquire lands inside that window,
         * LockFileEx fails spuriously with ERROR_LOCK_VIOLATION; without a retry the
         * session downgrades to the lock-less channel fallback for good, and every
         * native-probing peer then reads our lock as free = "owner dead".  One retry
         * after a short pause clears the transient collision (F41). */
        Sleep(15);
        OVERLAPPED ovr = {0};
        locked = LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ovr);
    }
    if (!locked) {
        DWORD gle2 = GetLastError();
        CloseHandle(h);
        Tcl_Free((char *)w);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("lock held (error %lu)", (unsigned long)gle2));
        return TCL_OK;
    }
    if (g_lock != INVALID_HANDLE_VALUE) { CloseHandle(g_lock); }  /* replace any prior */
    g_lock = h;
    if (g_lock_path != nullptr) { Tcl_Free((char *)g_lock_path); }
    size_t wn = wcslen(w) + 1;                            /* full, untruncated copy (F40) */
    g_lock_path = (WCHAR *)Tcl_Alloc(wn * sizeof(WCHAR));
    wmemcpy(g_lock_path, w, wn);
    Tcl_Free((char *)w);
    Tcl_SetObjResult(ip, Tcl_NewObj());     /* "" = success, lock held */
    return TCL_OK;
}

static int UnlockFile_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                          int objc, Tcl_Obj *const objv[]) {
    if (objc != 1) { Tcl_WrongNumArgs(ip, 1, objv, nullptr); return TCL_ERROR; }
    if (g_lock != INVALID_HANDLE_VALUE) {
        OVERLAPPED ov = {0};
        UnlockFileEx(g_lock, 0, 1, 0, &ov);
        CloseHandle(g_lock);
        g_lock = INVALID_HANDLE_VALUE;
        if (g_lock_path != nullptr) { Tcl_Free((char *)g_lock_path); g_lock_path = nullptr; }
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

/* ---- isolated find-worker lifecycle --------------------------------------
 * A regex worker is deliberately a disposable child process.  Each watched
 * child is placed in its own Job Object with KILL_ON_JOB_CLOSE, and both
 * handles live in interpreter-associated state.  Closing the interpreter (a
 * clean exit, Tcl failure, or parent-process death) therefore kills every
 * worker even when no Tcl cleanup callback can run.
 *
 * Tokens are opaque capabilities, never PIDs: a recycled PID cannot make a
 * late status/kill operation target an unrelated process.  Only a DIRECT child
 * of this process may be watched, preventing this small API from becoming a
 * general arbitrary-process terminator if it is called incorrectly. */
typedef struct WorkerEntry {
    HANDLE process;
    HANDLE job;
    DWORD pid;
    char token[48];
    struct WorkerEntry *next;
} WorkerEntry;

typedef struct WorkerState {
    WorkerEntry *head;
    unsigned long long sequence;
} WorkerState;

#define WORKER_COMMAND_MAX_ARGS 64
#define WORKER_COMMAND_CAP 32767u

static void WorkerEntryClose(WorkerEntry *entry, BOOL terminate) {
    if (entry == nullptr) return;
    if (entry->job != nullptr) {
        if (terminate) (void)TerminateJobObject(entry->job, ERROR_CANCELLED);
        CloseHandle(entry->job); /* KILL_ON_JOB_CLOSE is the final backstop. */
    }
    if (entry->process != nullptr) CloseHandle(entry->process);
    Tcl_Free((char *)entry);
}

static void WorkerStateDelete(void *clientData, [[maybe_unused]] Tcl_Interp *ip) {
    WorkerState *state = (WorkerState *)clientData;
    WorkerEntry *entry = state->head;
    while (entry != nullptr) {
        WorkerEntry *next = entry->next;
        WorkerEntryClose(entry, TRUE);
        entry = next;
    }
    Tcl_Free((char *)state);
}

static BOOL IsDirectChild(DWORD pid) {
    BOOL direct = FALSE;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return FALSE;
    PROCESSENTRY32W pe = {0};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snapshot, &pe)) {
        do {
            if (pe.th32ProcessID == pid) {
                direct = (pe.th32ParentProcessID == GetCurrentProcessId());
                break;
            }
        } while (Process32NextW(snapshot, &pe));
    }
    CloseHandle(snapshot);
    return direct;
}

static WorkerEntry *WorkerFind(WorkerState *state, const char *token,
                               Tcl_Size tokenLength,
                               WorkerEntry ***linkOut) {
    WorkerEntry **link = &state->head;
    while (*link != nullptr) {
        size_t storedLength = strlen((*link)->token);
        if (tokenLength >= 0 && (size_t)tokenLength == storedLength
                && memcmp((*link)->token, token, storedLength) == 0) {
            if (linkOut != nullptr) *linkOut = link;
            return *link;
        }
        link = &(*link)->next;
    }
    return nullptr;
}

static HANDLE WorkerJobCreate(Tcl_Interp *ip) {
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (job == nullptr) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("CreateJobObjectW error %lu",
                                           (unsigned long)GetLastError()));
        return nullptr;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits))) {
        DWORD gle = GetLastError();
        CloseHandle(job);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("SetInformationJobObject error %lu",
                                           (unsigned long)gle));
        return nullptr;
    }
    return job;
}

static WorkerEntry *WorkerEntryAdd(WorkerState *state, HANDLE process,
                                   HANDLE job, DWORD pid) {
    WorkerEntry *entry = (WorkerEntry *)Tcl_Alloc(sizeof(WorkerEntry));
    memset(entry, 0, sizeof(*entry));
    entry->process = process;
    entry->job = job;
    entry->pid = pid;
    LARGE_INTEGER ticks;
    QueryPerformanceCounter(&ticks);
    state->sequence++;
    _snprintf(entry->token, sizeof(entry->token), "worker-%016llx-%016llx",
              state->sequence,
              ((unsigned long long)ticks.QuadPart ^
               ((unsigned long long)(uintptr_t)entry << 7)));
    entry->token[sizeof(entry->token) - 1] = '\0';
    entry->next = state->head;
    state->head = entry;
    return entry;
}

static BOOL WorkerCommandPut(WCHAR *command, size_t *length, WCHAR ch) {
    if (*length >= WORKER_COMMAND_CAP - 1u) return FALSE;
    command[(*length)++] = ch;
    return TRUE;
}

/* Quote one argument according to the CommandLineToArgvW/CRT convention used
 * by Tcl's Windows entry points.  Quoting every argument keeps spaces, quotes,
 * and trailing backslashes unambiguous and never invokes cmd.exe. */
static BOOL WorkerCommandAppendArg(WCHAR *command, size_t *length,
                                   const WCHAR *arg) {
    if (wcslen(arg) >= WORKER_COMMAND_CAP ||
            !WorkerCommandPut(command, length, L'"')) return FALSE;
    size_t slashes = 0;
    for (const WCHAR *p = arg; *p != L'\0'; ++p) {
        if (*p == L'\\') {
            slashes++;
            continue;
        }
        if (*p == L'"') {
            for (size_t i = 0; i < slashes * 2u + 1u; ++i) {
                if (!WorkerCommandPut(command, length, L'\\')) return FALSE;
            }
            if (!WorkerCommandPut(command, length, L'"')) return FALSE;
        } else {
            for (size_t i = 0; i < slashes; ++i) {
                if (!WorkerCommandPut(command, length, L'\\')) return FALSE;
            }
            if (!WorkerCommandPut(command, length, *p)) return FALSE;
        }
        slashes = 0;
    }
    for (size_t i = 0; i < slashes * 2u; ++i) {
        if (!WorkerCommandPut(command, length, L'\\')) return FALSE;
    }
    return WorkerCommandPut(command, length, L'"');
}

static int WorkerWatch_Cmd(void *cd, Tcl_Interp *ip,
                           int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "pid"); return TCL_ERROR; }
    Tcl_WideInt widePid;
    if (Tcl_GetWideIntFromObj(ip, objv[1], &widePid) != TCL_OK) return TCL_ERROR;
    if (widePid <= 0 || (unsigned long long)widePid > (unsigned long long)MAXDWORD
            || (DWORD)widePid == GetCurrentProcessId()) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("pid is not a valid child process", -1));
        return TCL_ERROR;
    }
    DWORD pid = (DWORD)widePid;
    HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION |
                                 PROCESS_SET_QUOTA | PROCESS_TERMINATE,
                                 FALSE, pid);
    if (process == nullptr) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("OpenProcess error %lu",
                                           (unsigned long)GetLastError()));
        return TCL_ERROR;
    }
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(process, &exitCode)) {
        DWORD gle = GetLastError();
        CloseHandle(process);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("GetExitCodeProcess error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }
    if (exitCode != STILL_ACTIVE) {
        CloseHandle(process);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("worker already exited with code %lu",
                                           (unsigned long)exitCode));
        return TCL_ERROR;
    }
    /* Hold the process object before verifying ancestry.  While this handle is
     * open Windows cannot recycle its PID between a Toolhelp parent check and
     * Job assignment, so a fast-exiting child can never redirect the capability
     * onto an unrelated replacement process.  This closes only the PID-reuse
     * race inside els: a malicious process already running as the same Windows
     * user remains outside the local-desktop threat model documented in DESIGN. */
    if (!IsDirectChild(pid)) {
        CloseHandle(process);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("pid is not a direct child process", -1));
        return TCL_ERROR;
    }

    HANDLE job = WorkerJobCreate(ip);
    if (job == nullptr) { CloseHandle(process); return TCL_ERROR; }
    if (!AssignProcessToJobObject(job, process)) {
        DWORD gle = GetLastError();
        CloseHandle(job);
        CloseHandle(process);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("AssignProcessToJobObject error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }

    WorkerEntry *entry = WorkerEntryAdd((WorkerState *)cd, process, job, pid);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(entry->token, -1));
    return TCL_OK;
}

/* Create and watch a worker as one native operation.  Tcl's Windows `exec ...
 * &` waits for GUI-subsystem input-idle, which deadlocks els's watch-before-go
 * handshake because the private worker intentionally has no UI/event loop.
 *
 * PROC_THREAD_ATTRIBUTE_JOB_LIST assigns the new suspended process to its
 * kill-on-close Job Object atomically at creation.  If the parent dies anywhere
 * after CreateProcessW, Windows closes the only job handle and kills the child;
 * there is no unattached PID or suspended-orphan interval. */
static int WorkerSpawnWatch_Cmd(void *cd, Tcl_Interp *ip,
                                int objc, Tcl_Obj *const objv[]) {
    if (objc != 3) {
        Tcl_WrongNumArgs(ip, 1, objv, "commandList workingDirectory");
        return TCL_ERROR;
    }
    Tcl_Size argCount = 0;
    Tcl_Obj **args = nullptr;
    if (Tcl_ListObjGetElements(ip, objv[1], &argCount, &args) != TCL_OK) {
        return TCL_ERROR;
    }
    if (argCount < 1 || argCount > WORKER_COMMAND_MAX_ARGS) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("worker command has invalid argument count", -1));
        return TCL_ERROR;
    }

    WCHAR *command = (WCHAR *)Tcl_Alloc(WORKER_COMMAND_CAP * sizeof(WCHAR));
    WCHAR *application = nullptr;
    size_t commandLength = 0;
    BOOL commandOk = TRUE;
    for (Tcl_Size i = 0; i < argCount; ++i) {
        Tcl_Size byteLength = 0;
        const char *text = Tcl_GetStringFromObj(args[i], &byteLength);
        WCHAR *wide = utf8_to_wide_worker_arg(text, byteLength);
        if (wide == nullptr) {
            commandOk = FALSE;
            break;
        }
        if (i == 0 && byteLength == 0) commandOk = FALSE;
        if (i > 0 && !WorkerCommandPut(command, &commandLength, L' ')) {
            commandOk = FALSE;
        }
        if (commandOk && !WorkerCommandAppendArg(command, &commandLength, wide)) {
            commandOk = FALSE;
        }
        if (i == 0) application = wide; else Tcl_Free((char *)wide);
        if (!commandOk) break;
    }
    if (!commandOk || application == nullptr) {
        if (application != nullptr) Tcl_Free((char *)application);
        Tcl_Free((char *)command);
        Tcl_SetObjResult(ip, Tcl_NewStringObj(
                "worker command contains invalid, NUL, or oversized text", -1));
        return TCL_ERROR;
    }
    command[commandLength] = L'\0';

    Tcl_Size cwdLength = 0;
    const char *cwdText = Tcl_GetStringFromObj(objv[2], &cwdLength);
    WCHAR *cwd = utf8_to_wide(cwdText, cwdLength);
    if (cwd == nullptr) {
        Tcl_Free((char *)application);
        Tcl_Free((char *)command);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("worker directory conversion failed", -1));
        return TCL_ERROR;
    }

    HANDLE job = WorkerJobCreate(ip);
    if (job == nullptr) {
        Tcl_Free((char *)cwd);
        Tcl_Free((char *)application);
        Tcl_Free((char *)command);
        return TCL_ERROR;
    }

    SIZE_T attributeBytes = 0;
    (void)InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = nullptr;
    if (attributeBytes > 0) {
        attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(
                GetProcessHeap(), 0, attributeBytes);
    }
    if (attributes == nullptr || !InitializeProcThreadAttributeList(
            attributes, 1, 0, &attributeBytes)) {
        DWORD gle = GetLastError();
        if (attributes != nullptr) HeapFree(GetProcessHeap(), 0, attributes);
        CloseHandle(job);
        Tcl_Free((char *)cwd);
        Tcl_Free((char *)application);
        Tcl_Free((char *)command);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("worker attribute initialization error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }
    HANDLE jobs[1] = {job};
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   jobs, sizeof(jobs), nullptr, nullptr)) {
        DWORD gle = GetLastError();
        DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);
        CloseHandle(job);
        Tcl_Free((char *)cwd);
        Tcl_Free((char *)application);
        Tcl_Free((char *)command);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("worker job attribute error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }

    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList = attributes;
    PROCESS_INFORMATION processInfo = {0};
    DWORD flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT;
    BOOL created = CreateProcessW(application, command, nullptr, nullptr, FALSE,
                                  flags, nullptr, cwd, &startup.StartupInfo,
                                  &processInfo);
    DWORD createError = created ? 0u : GetLastError();
    DeleteProcThreadAttributeList(attributes);
    HeapFree(GetProcessHeap(), 0, attributes);
    Tcl_Free((char *)cwd);
    Tcl_Free((char *)application);
    Tcl_Free((char *)command);
    if (!created) {
        CloseHandle(job);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("CreateProcessW error %lu",
                                           (unsigned long)createError));
        return TCL_ERROR;
    }

    BOOL inJob = FALSE;
    BOOL jobQueried = IsProcessInJob(processInfo.hProcess, job, &inJob);
    if (!jobQueried || !inJob) {
        DWORD gle = jobQueried ? ERROR_INVALID_DATA : GetLastError();
        TerminateProcess(processInfo.hProcess, ERROR_CANCELLED);
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        CloseHandle(job);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("worker job verification error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }

    WorkerState *state = (WorkerState *)cd;
    WorkerEntry *entry = WorkerEntryAdd(state, processInfo.hProcess, job,
                                        processInfo.dwProcessId);
    if (ResumeThread(processInfo.hThread) == (DWORD)-1) {
        DWORD gle = GetLastError();
        CloseHandle(processInfo.hThread);
        state->head = entry->next;
        WorkerEntryClose(entry, TRUE);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("ResumeThread error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }
    CloseHandle(processInfo.hThread);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(entry->token, -1));
    return TCL_OK;
}

static int WorkerStatus_Cmd(void *cd, Tcl_Interp *ip,
                            int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "token"); return TCL_ERROR; }
    Tcl_Size tokenLength;
    const char *token = Tcl_GetStringFromObj(objv[1], &tokenLength);
    WorkerState *state = (WorkerState *)cd;
    WorkerEntry **link = nullptr;
    WorkerEntry *entry = WorkerFind(state, token, tokenLength, &link);
    if (entry == nullptr) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown worker token", -1));
        return TCL_ERROR;
    }
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(entry->process, &exitCode)) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("GetExitCodeProcess error %lu",
                                           (unsigned long)GetLastError()));
        return TCL_ERROR;
    }
    if (exitCode == STILL_ACTIVE) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("running", -1));
        return TCL_OK;
    }
    Tcl_Obj *result = Tcl_NewListObj(0, nullptr);
    Tcl_ListObjAppendElement(ip, result, Tcl_NewStringObj("exited", -1));
    Tcl_ListObjAppendElement(ip, result, Tcl_NewWideIntObj((Tcl_WideInt)exitCode));
    *link = entry->next;
    WorkerEntryClose(entry, FALSE);
    Tcl_SetObjResult(ip, result);
    return TCL_OK;
}

static int WorkerKill_Cmd(void *cd, Tcl_Interp *ip,
                          int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "token"); return TCL_ERROR; }
    Tcl_Size tokenLength;
    const char *token = Tcl_GetStringFromObj(objv[1], &tokenLength);
    WorkerEntry *entry = WorkerFind((WorkerState *)cd, token, tokenLength, nullptr);
    if (entry == nullptr) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown worker token", -1));
        return TCL_ERROR;
    }
    if (!TerminateJobObject(entry->job, ERROR_CANCELLED)) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("TerminateJobObject error %lu",
                                           (unsigned long)GetLastError()));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewObj());
    return TCL_OK;
}

/* A containment check for worker scratch roots.  Tcl's `file type` identifies
 * symbolic links but a Windows junction can still present as a directory;
 * FILE_ATTRIBUTE_REPARSE_POINT catches both without following the target. */
static int PathReparse_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                           int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    Tcl_Size n;
    const char *p = Tcl_GetStringFromObj(objv[1], &n);
    WCHAR *w = utf8_to_wide(p, n);
    if (w == nullptr) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("path conversion failed", -1));
        return TCL_ERROR;
    }
    DWORD attrs = GetFileAttributesW(w);
    DWORD gle = GetLastError();
    Tcl_Free((char *)w);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("GetFileAttributesW error %lu",
                                           (unsigned long)gle));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(
            (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0));
    return TCL_OK;
}

/* ---- virtual desktop geometry ---------------------------------------------
 * els::win_virtual_screen -> "x y w h" of the VIRTUAL desktop: the bounding rect
 * of ALL monitors, with x/y the (possibly negative) top-left.  Tk's `wm maxsize`
 * and `winfo screenwidth` report only the PRIMARY monitor on Windows, so a saved
 * window on a monitor to the right of / below the primary would be wrongly judged
 * off-screen; the geometry clamp (els::clamp_geometry) needs the true union. */
static int VirtualScreen_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                             int objc, Tcl_Obj *const objv[]) {
    if (objc != 1) { Tcl_WrongNumArgs(ip, 1, objv, nullptr); return TCL_ERROR; }
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

/* ---- durability: force buffered file data to the platter ------------------
 * els::win_fsync <path> : FlushFileBuffers on <path> so its already-written bytes
 *   survive power loss, not just a process crash (a crash leaves the data in the
 *   OS cache, which the OS still flushes; only power loss / BSOD loses it).  els
 *   calls this on the TARGET *after* the atomic replace, which forces both the file
 *   data AND the rename metadata (the name->data binding) durable.  Flushing only
 *   the pre-replace temp would persist the new data clusters but NOT the directory
 *   change that repoints the name at them: NTFS journaling makes the volume come
 *   back structurally CONSISTENT, not the last replace PERSISTED, so a power cut
 *   right after the replace could roll the name back to the old data.  Returns "" on
 *   success or a short error string (best-effort: the caller never blocks a save). */
static int Fsync_Cmd([[maybe_unused]] void *cd, Tcl_Interp *ip,
                     int objc, Tcl_Obj *const objv[]) {
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR; }
    Tcl_Size n; const char *p = Tcl_GetStringFromObj(objv[1], &n);
    WCHAR *w = utf8_to_wide(p, n);
    if (w == nullptr) { Tcl_SetObjResult(ip, Tcl_NewStringObj("path conversion failed", -1)); return TCL_OK; }
    /* GENERIC_WRITE is required for FlushFileBuffers; share read+write so a
     * concurrent reader/writer of the same file can't make the open fail. */
    HANDLE h = CreateFileW(w, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    DWORD gle = GetLastError();           /* capture BEFORE Tcl_Free clobbers it */
    Tcl_Free((char *)w);
    if (h == INVALID_HANDLE_VALUE) {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("open error %lu", (unsigned long)gle));
        return TCL_OK;
    }
    BOOL ok = FlushFileBuffers(h);
    gle = ok ? 0u : GetLastError();
    CloseHandle(h);
    if (ok) {
        Tcl_SetObjResult(ip, Tcl_NewObj());                 /* "" = success */
    } else {
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("FlushFileBuffers error %lu",
                                            (unsigned long)gle));
    }
    return TCL_OK;
}

int Winfs_Init(Tcl_Interp *ip) {
    if (Tcl_InitStubs(ip, "9.0", 0) == nullptr) return TCL_ERROR;
    WorkerState *workers = (WorkerState *)Tcl_GetAssocData(ip,
            "els::winfs::workers", nullptr);
    if (workers == nullptr) {
        workers = (WorkerState *)Tcl_Alloc(sizeof(WorkerState));
        memset(workers, 0, sizeof(*workers));
        Tcl_SetAssocData(ip, "els::winfs::workers", WorkerStateDelete, workers);
    }
    /* fully-qualified name: Tcl creates ::els if it doesn't exist yet (this Init
     * may run before main.tcl is sourced, in the native build). */
    Tcl_CreateObjCommand(ip, "::els::win_replace_file",   ReplaceFile_Cmd,   nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_open_folder",    OpenFolder_Cmd,    nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_fsync",          Fsync_Cmd,         nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_lock_file",      LockFile_Cmd,      nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_unlock_file",    UnlockFile_Cmd,    nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_try_lock",       TryLock_Cmd,       nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_virtual_screen", VirtualScreen_Cmd, nullptr, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_worker_spawn_watch", WorkerSpawnWatch_Cmd, workers, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_worker_watch",   WorkerWatch_Cmd,   workers, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_worker_status",  WorkerStatus_Cmd,  workers, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_worker_kill",    WorkerKill_Cmd,    workers, nullptr);
    Tcl_CreateObjCommand(ip, "::els::win_path_reparse",   PathReparse_Cmd,   nullptr, nullptr);
    if (Tcl_PkgProvide(ip, "winfs", "0.1") != TCL_OK) return TCL_ERROR;
    return TCL_OK;
}
