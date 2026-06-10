# els toolchain

How els is built, tested, packaged, and kept portable, plus the rules that keep
it that way. els is a Tcl/Tk 9 editor with optional C23 extensions; the whole
project, toolchain included, is **self-contained and copy-paste portable**: drop
the folder onto any Windows 11 machine and everything works, with no installs
and no dependency on anything already present on the system.

## Language policy

The project and its tooling use **only two languages**, plus one boot script:

| Allowed | Used for |
|---|---|
| **Tcl 9** | the editor (`els.tcl`), all tooling (`tools/*.tcl`), tests (`tests/*`) |
| **C23** | optional native extensions (`src/*.c`), built with the vendored gcc |
| **classical Windows `cmd`** | exactly one file: `x.cmd` |

No bash, **no PowerShell**, no Python, nothing else. The single `.cmd` file
exists only because PATH has to be set *before* Tcl is reachable (a
chicken-and-egg the shell must solve). It is deliberately tiny; all real logic
lives in Tcl.

The native `els.exe` needs Windows PE resources — an icon, an application
manifest, and version info — which are normally `.rc`/`.ico`/`.manifest` files.
els keeps them **out of the committed source**: they are *generated from Tcl* at
build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the gitignored `build/`,
and compiled by the already-vendored `windres`. So the policy holds — the repo
is Tcl + C + one `.cmd`, with no new languages or dependencies.

To audit compliance:

```
git ls-files            &:: only .tcl .test .c .cmd + assets/docs
git grep -i powershell  &:: nothing
```

## What's vendored: `.toolchain/`

Everything the project needs lives here. It is **gitignored** (large,
machine-built), so it travels by *copy-paste of the folder*, not by `git clone`.

| Path | What | Version |
|---|---|---|
| `.toolchain/tcl9/` | Tcl/Tk 9 **shared** build: `tclsh90.exe`, `wish90.exe`, stubs (`lib/libtclstub.a`), headers (`include/tcl.h`, `tk.h`) | 9.0.3 |
| `.toolchain/tcl9s/` | Tcl/Tk 9 **static**, DLL-free: the link libs `lib/libtcl90.a` + `libtcl9tk90.a` (the native `x build` links these into els.exe), plus `tclsh90s.exe` (runs the packaging step) and `wish90s.exe` (packaging extracts `tk_library` from its appended archive) | 9.0.3 |
| `.toolchain/msys64/ucrt64/` | gcc (C23), binutils, gdb (MSYS2 UCRT64) | gcc 16.1.0 |
| `.toolchain/msys64/usr/bin/` | `curl.exe` etc. (used by the fetch tasks) | n/a |
| `.toolchain/twapi-dl/` | twapi: Windows API extension for the GUI tooling | 5.2.0 |
| `.toolchain/git/` | MinGit: git-for-windows' slim, GUI-less build | 2.54.0 |

`x toolcheck` reports the status and version of each.

### Tcl/Tk version: always 9, never msys64's 8.6

MSYS2's `ucrt64` bundles its own **Tcl/Tk 8.6** (`tclsh.exe`, `wish.exe`,
`tcl86.dll`, an 8.6 `include/tcl.h`, `lib/tcl8.6`).  It is left intact (MSYS2 may
want it), but **els never uses it**.  The rule:

- Tooling invokes the interpreter only through the explicit vendored paths
  `tcl9/bin/tclsh90.exe` / `wish90.exe` (and `tcl9s` for packaging), **never a
  bare `tclsh`/`wish`**, which on PATH could resolve to the 8.6 build.
- PATH puts `tcl9/bin` **ahead of** `msys64/ucrt64/bin`.
- C builds pass `-I.toolchain/tcl9/include` so `tcl.h` is the 9.x header.

`x toolcheck --deep` enforces this: it confirms the live interpreters are 9.0.x
and that a freshly compiled C extension links the 9.0 stubs and reports a 9.x
`tcl.h`.

## Ignition: `x.cmd`

The single entry point. It resolves the toolchain **relative to its own
location** (`%~dp0`), so the folder is relocatable to any path, then hands off to
the Tcl task runner:

```cmd
set "PATH=%TC%\tcl9\bin;%TC%\msys64\ucrt64\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"   &:: git is optional
if exist "%TC%\appfull\tcl_library\init.tcl" set "TCL_LIBRARY=%TC%\appfull\tcl_library"
if exist "%TC%\appfull\tk_library\tk.tcl" set "TK_LIBRARY=%TC%\appfull\tk_library"
"%TC%\tcl9\bin\tclsh90.exe" "%ELS_ROOT%tools\x.tcl" %*
```

`x shell` is handled here (it opens an interactive `cmd` with PATH set); if the
core Tcl is missing, `x.cmd` prints a clear message instead of a cryptic error.

## Task runner: `tools/x.tcl`

All tooling. Run `x help`:

```
x test               in-process test suite (tcltest + Tk event generate)
x run [file ...]     launch the editor (wish + els.tcl)
x shot <out> [file]  screenshot the editor (twapi, all-Tcl)
x build              build the native exe -> dist/els.exe (C23 WinMain, static Tcl+Tk+icudet)
x build-ext          compile src/*.c C23 extensions -> build/*.dll
x fetch-twapi        vendor twapi into .toolchain/
x fetch-git          vendor MinGit into .toolchain/git/
x toolcheck [--prep] check the vendored toolchain (--prep fetches/updates)
x shell              a shell with the vendored toolchain on PATH
x env                print the resolved toolchain paths + versions
```

`x.tcl` re-asserts PATH itself (so it is robust when run directly with the
vendored `tclsh90.exe`) and uses a **cheap per-command guard**: each task
declares only the one or two tools it needs (`need gcc tclsh`), a microsecond
`file exists`, *not* a full toolchain scan on every invocation. The thorough
scan is `x toolcheck`, on demand.

## Toolchain check: `tools/toolcheck.tcl`

A manifest-driven console report. Each component carries a pinned `want`
version; status is `OK` / `UPDATE (have X, want Y)` / `MISSING`. The basic report
already *runs* most tools to read their version (`gcc -dumpversion`, `tclsh ...
info patchlevel`, `git --version`), so a binary that can't launch is caught.
`x toolcheck --prep` fetches the auto-installable pieces (twapi, git),
re-fetching outdated ones after removing the stale copy, and prints
instructions for the manual ones (Tcl, gcc, which are heavy/external). Adding a
component is one manifest line.

**`x toolcheck --deep`** goes further: it verifies the toolchain actually
*works*, the check to run after a copy-paste onto a new machine. It evaluates a
Tcl script, loads and instantiates a **Tk** widget, loads **twapi**, **compiles
a C file with gcc and loads the resulting stubs DLL** (the whole C23↔Tcl chain),
and runs git. Everything goes through the console `tclsh`, so any failure prints
as text, never as a GUI dialog.

## C23 ↔ Tcl extensions

els drops into C23 for hot paths or to bind a C library, exposed to Tcl as
ordinary commands. The native `els.exe` **statically links its product extension
in** (see the build below); during development every `src/*.c` also builds as a
standalone `.dll` against the Tcl **stubs** (a compiler-independent ABI), so a dev
`.dll`:

- imports **only `KERNEL32` + the UCRT** (`api-ms-win-crt-*`), present on every
  Windows 11; it is **not** linked against `tcl90.dll`;
- is built with `-static-libgcc`, so it needs no gcc runtime DLLs.

`src/elsx.c` is the template. `x build-ext` compiles every `src/*.c` →
`build/<name>.dll` + `build/pkgIndex.tcl`, so `load`/`package require <name>`
finds it (init proc = Titlecased filename, e.g. `Icudet_Init` for `icudet.c`):

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
    -I.toolchain/tcl9/include src/elsx.c \
    -o build/elsx.dll -L.toolchain/tcl9/lib -ltclstub -static-libgcc
```

The product ships only what it needs: `src/icudet.c` (charset detection) and
`src/winfs.c` are **compiled straight into the native `els.exe`** (no DLL);
`cap.c` (the screenshot capture used by `tools/shot.tcl`) and `elsx.c` (a demo)
stay dev-only `.dll`s. `src/winfs.c` exposes two native helpers used by the
data-safety layer: `els::win_replace_file` (atomic, metadata-preserving save via
`ReplaceFileW` — keeps ACLs / alternate data streams / the mark-of-the-web that a
rename drops) and the session-liveness lock `els::win_lock_file` /
`win_try_lock` / `win_unlock_file` (a held `LockFileEx` byte-range the OS frees on
process death — so "the lock is acquirable ⇒ that session is dead", which the
crash-recovery scan relies on; see below). When `winfs` is absent (a dev/tclsh
run) els falls back to a pure-Tcl temp+rename save and an mtime-based liveness.
(`els_main.c` is the exe entry point, not a loadable extension — `x build-ext`
skips it.) Tests live in `tests/elsx.test` / `tests/winfs.test`, gated on the DLL
being built so the suite is green with or without a compiler run.

## Build: `x build` (native els.exe)

`x build` produces one self-contained **native** `els.exe` (~5.1 MB, **zero
non-system DLLs**) from our own C23 entry point — a real Windows PE, not a stock
interpreter with scripts bolted on. `WinMain` is ours; Tcl, Tk, and the icudet
detector are statically linked in; the Tcl/Tk script libraries + `els.tcl` ride
inside an appended zipfs image. `els.tcl` is unchanged by any of this. Steps
(`tools/x.tcl` `task_build`):

1. `tools/genres.tcl` generates `build/els.rc` + `build/els.exe.manifest` from
   Tcl (the version comes straight from `els.tcl`'s `variable version`), and
   `tools/mkico.tcl` packs `resources/icon*.png` into `build/els.ico`. These are
   gitignored build artifacts, so the committed repo stays Tcl + C + one `.cmd`
   (no `.rc`/`.manifest`/`.ico` source — the same way `els.ico` was always made).
2. `windres` compiles `build/els.rc` (icon + manifest + VERSIONINFO) →
   `build/els.res`.
3. gcc compiles `src/els_main.c` (a minimal fork of Tk's `winMain.c`, built
   `-municode -DUNICODE -DSTATIC_BUILD -DELS_STATIC_ICUDET`) and `src/icudet.c`.
4. gcc links them + `els.res` against the **static** libs in `.toolchain/tcl9s/lib`
   (`libtcl9tk90.a`, `libtcl90.a`, `libtclstub.a`) + the Win32 system libs
   (`tkConfig.sh`'s `TK_LIBS`), with `-mwindows` (GUI subsystem) and
   `--gc-sections`; then `strip`. Headers come from `.toolchain/tcl9/include`
   (the static tree ships none; they are ABI-identical 9.0.3).
5. `package.tcl` (under static `tclsh90s`) appends the zipfs payload onto our exe
   — `main.tcl` (= els.tcl), `resources/`, `tcl_library/`, `tk_library/`. **No
   DLL is embedded**; icudet is compiled in. At boot, `TclZipfs_AppHook`
   self-mounts the appended zip at `//zipfs:/app` and runs `main.tcl`.

The PE **icon + manifest** (system-DPI-aware, common-controls v6, UTF-8 code page,
long-path aware) **+ version info** (`FileDescription`/`ProductName` = `els`) are
baked at link time by windres. They survive the zipfs append because the zip lands
*after* the PE image. `/els.exe` and `/build/` are gitignored (so is the generated
`src/els.ico`); rebuild them, ship the exe via releases. The full rationale and the
proven link recipe are in `docs/native-port-study.md`.

### A PE-resource gotcha worth keeping

Editing a packaged exe's PE resources (icon, version info, manifest — e.g. via
twapi `UpdateResource`) **rewrites the PE image and DROPS anything appended
after it**, which for els means the entire zipfs payload: the exe shrinks and
dies with "Cannot find init.tcl". Resources must be baked into the bare PE
*first* (the native build does this at link time via windres) and the zipfs
appended *after*. (The pre-0.60 legacy wrapper build, `x build-wish` +
`tools/exeicon.tcl`, was retired once the native build shipped; git history
has it.)

### Testing the exe safely

`els.exe --selftest [report.txt]` is a headless mode that boots the full app,
writes a result file, and exits (a GUI-subsystem exe has no stderr). `x probe-exe`
drives the first-run prompt + session restore in a temp config home. Verify the
appended zipfs structure (`main.tcl`, `tcl_library/init.tcl`, `tk_library/tk.tcl`,
`resources/icon.png`) is intact. **NEVER debug by running a GUI build directly on
a failure** — it rains modal dialogs on the user; read the file-report selftest,
or build a console-subsystem twin (gcc without `-mwindows`) whose stderr is text.

## Tests: `tests/`

White-box and **in-process**: `tcltest` drives the real Tk widgets via Tk's
`event generate`, with full introspection (read tag ranges, the dirty flag, the
cursor index). This is far more reliable than pixel-driving, and headless. `els.tcl`'s
`main` is guarded by `info script eq argv0`, so the suite sources the editor
without launching its UI. Run `x test`.

## Screenshots: `tools/shot.tcl` + `src/cap.c`

Robust, occlusion-proof window capture.  twapi finds the target window by PID;
the **cap C extension** (`src/cap.c`, built by `x build-ext`) captures it with
**`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`**, rendering that *one*
window's pixels even when it is covered or in the background, with no foreground,
no clipboard, no Snipping-Tool, and no full-screen crop.  It returns a DIB
(BITMAPINFOHEADER + 32-bpp pixels) that `shot.tcl` converts to PNG (→ P6 PPM →
Tk photo).  Deterministic, no retries.  `x shot out.png [file ...]` builds the
extension on demand.  (`PrintWindow` is reliable for normal GDI/DWM windows like
Tk's; it can fail on hardware-accelerated apps, but we only shoot our own.)

## Distribution

**Copy-paste the whole folder.** Because `.toolchain/` (gitignored, ~1 GB+, with
the gcc toolchain dominating) travels with the folder, dropping it onto a fresh
Windows 11 machine just works: no install, no provisioning, no network. There is
deliberately *no* "bootstrap from nothing" script: a multi-hundred-MB gcc + Tcl
toolchain can't be conjured without either downloading it (needs hosting) or
building it from source (slow, and the Tcl/Tk build runs MSYS2's bash), so it
would only add a fragile, half-working path. `x toolcheck --prep` can still fetch
the small auto-installable pieces (twapi, git) when only those are missing.

## Portability / relocation

Portable **by construction**: every path resolves relative to the invoking
script (`%~dp0` in `x.cmd`, `[info script]` in the Tcl). **Verified** by copying
the whole tree to a different absolute path and running `x build-ext` + `x test`
from there: the relocated gcc compiled the C23 extension and the relocated
`tclsh` ran the suite green. MSYS2 UCRT64 relocates cleanly. The only system
requirement is the Windows UCRT, which ships with Windows 10 1903+ / all
Windows 11.

## Rebuilding the toolchain from source (reference)

Only needed to regenerate `.toolchain/{tcl9,tcl9s}` (the rest is fetched by
`x toolcheck --prep` / vendored). Tcl/Tk 9.0.3 is built with the vendored MSYS2
UCRT64 gcc:

- **shared:** `./configure --prefix=.../tcl9 --enable-64bit && make && make install`
  (build Tcl first, then Tk with `--with-tcl`).
- **static (DLL-free):** `make distclean` then `./configure --disable-shared
  --enable-64bit` (Tk also needs `--with-tcl=$P/lib`).
- Gotchas: MSYS2 has only `mingw32-make` (make a `make` shim); Tk's configure
  leaves `EXEEXT` empty (build with `make EXEEXT=.exe`) and needs Tcl's
  `minizip.exe` staged into `tk9.0.3/win/` (a zipfs prerequisite).

Run builds with the UCRT64 `bin` prepended to PATH so gcc's children
(`cc1.exe`, `as.exe`) find their DLLs.
