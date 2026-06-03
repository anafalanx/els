# els toolchain

How els is built, tested, packaged, and kept portable — and the rules that keep
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

To audit compliance:

```
git ls-files            &:: only .tcl .test .c .cmd + assets/docs
git grep -i powershell  &:: nothing
```

## What's vendored — `.toolchain/`

Everything the project needs lives here. It is **gitignored** (large,
machine-built), so it travels by *copy-paste of the folder*, not by `git clone`.

| Path | What | Version |
|---|---|---|
| `.toolchain/tcl9/` | Tcl/Tk 9 **shared** build — `tclsh90.exe`, `wish90.exe`, stubs (`lib/libtclstub.a`), headers (`include/tcl.h`, `tk.h`) | 9.0.3 |
| `.toolchain/tcl9s/` | Tcl/Tk 9 **static**, DLL-free — `tclsh90s.exe`, `wish90s.exe` (the single-exe wrapper) | 9.0.3 |
| `.toolchain/msys64/ucrt64/` | gcc (C23), binutils, gdb (MSYS2 UCRT64) | gcc 16.1.0 |
| `.toolchain/msys64/usr/bin/` | `curl.exe` etc. (used by the fetch tasks) | — |
| `.toolchain/twapi-dl/` | twapi — Windows API extension for the GUI tooling | 5.2.0 |
| `.toolchain/git/` | MinGit — git-for-windows' slim, GUI-less build | 2.54.0 |

`x toolcheck` reports the status and version of each.

## Ignition — `x.cmd`

The single entry point. It resolves the toolchain **relative to its own
location** (`%~dp0`), so the folder is relocatable to any path, then hands off to
the Tcl task runner:

```cmd
set "PATH=%TC%\msys64\ucrt64\bin;%TC%\tcl9\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"   &:: git is optional
"%TC%\tcl9\bin\tclsh90.exe" "%ELS_ROOT%tools\x.tcl" %*
```

`x shell` is handled here (it opens an interactive `cmd` with PATH set); if the
core Tcl is missing, `x.cmd` prints a clear message instead of a cryptic error.

## Task runner — `tools/x.tcl`

All tooling. Run `x help`:

```
x test               in-process test suite (tcltest + Tk event generate)
x run [file ...]     launch the editor (wish + els.tcl)
x shot <out> [file]  screenshot the editor (twapi, all-Tcl)
x build [--with-ext] fuse the single-file els.exe (--with-ext embeds build/*.dll)
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
`file exists` — *not* a full toolchain scan on every invocation. The thorough
scan is `x toolcheck`, on demand.

## Toolchain check — `tools/toolcheck.tcl`

A manifest-driven console report. Each component carries a pinned `want`
version; status is `OK` / `UPDATE (have X, want Y)` / `MISSING`. The basic report
already *runs* most tools to read their version (`gcc -dumpversion`, `tclsh ...
info patchlevel`, `git --version`), so a binary that can't launch is caught.
`x toolcheck --prep` fetches the auto-installable pieces (twapi, git) —
re-fetching outdated ones after removing the stale copy — and prints
instructions for the manual ones (Tcl, gcc, which are heavy/external). Adding a
component is one manifest line.

**`x toolcheck --deep`** goes further — it verifies the toolchain actually
*works*, the check to run after a copy-paste onto a new machine: it evaluates a
Tcl script, loads and instantiates a **Tk** widget, loads **twapi**, **compiles
a C file with gcc and loads the resulting stubs DLL** (the whole C23↔Tcl chain),
and runs git. Everything goes through the console `tclsh`, so any failure prints
as text — never a GUI dialog.

## C23 ↔ Tcl extensions

els can drop into C23 for hot paths or to bind a C library, exposed to Tcl as
ordinary commands. Extensions are built against the Tcl **stubs** (a
compiler-independent ABI), so the resulting `.dll`:

- imports **only `KERNEL32` + the UCRT** (`api-ms-win-crt-*`) — present on every
  Windows 11; it is **not** linked against `tcl90.dll` and loads with only
  `System32` on PATH (fully self-contained);
- is built with `-static-libgcc`, so it needs no gcc runtime DLLs.

`src/elsx.c` is the template. The build (run by `x build-ext`) is:

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
    -I.toolchain/tcl9/include src/elsx.c \
    -o build/elsx.dll -L.toolchain/tcl9/lib -ltclstub -static-libgcc
```

`x build-ext` compiles every `src/*.c` and writes `build/pkgIndex.tcl`, so a
`load`/`package require <name>` finds it (init proc = Titlecased filename, e.g.
`Elsx_Init` for `elsx.c`). Tests live in `tests/elsx.test` (gated on the DLL
being built, so the suite is green with or without a compiler run).

Two integration modes:

1. **Dynamic** — `package require elsx` during dev.
2. **Embedded in the single-exe** — see below; the DLL rides inside `els.exe`'s
   zipfs image and loads from there.

## Single-file build — `x build`, `tools/package.tcl`

`x build` fuses one self-contained `els.exe` (~6.7 MB, **zero non-system DLLs**).
`package.tcl` **must run under the static `tclsh90s`**, because that interpreter
keeps its `tcl_library` mounted at `//zipfs:/app` — the source we stage from.
The recipe reproduces the proven archive layout (everything at the archive root):

```
main.tcl        <- els.tcl
resources/      <- resources/
tcl_library/    <- copied from //zipfs:/app  (the static interp's library)
tk_library/     <- copied from `zipfs mount wish90s.exe`  (its appended zip holds ONLY tk_library)
[elsx.dll …]    <- with --with-ext: build/*.dll + pkgIndex.tcl
```

then `zipfs mkimg els.exe <stage> <stage> {} wish90s.exe` (STRIP=stage → files
land at the root → `main.tcl` is auto-sourced at startup). `x build --with-ext`
also embeds the compiled extensions, which then `load //zipfs:/app/elsx.dll`
from inside the exe (Tcl auto-extracts the DLL to a temp file before
`LoadLibrary`). `/els.exe` and `/build/` are gitignored — rebuild them; ship the
exe via releases.

**Testing the single-exe safely:** els requires Tk, which only `wish90s` has (no
Tk-capable `tclsh`), so a startup failure pops a modal dialog. Therefore: build,
then **verify the exe's zipfs structure matches the proven layout** (`main.tcl`,
`tcl_library/init.tcl`, `tk_library/tk.tcl`, `resources/icon.png` all present)
*before* running `els.exe --selftest` (a headless mode that writes a result file
and exits).

## Tests — `tests/`

White-box and **in-process**: `tcltest` drives the real Tk widgets via Tk's
`event generate`, with full introspection (read tag ranges, the dirty flag, the
cursor index) — far more reliable than pixel-driving, and headless. `els.tcl`'s
`main` is guarded by `info script eq argv0`, so the suite sources the editor
without launching its UI. Run `x test`.

## Screenshots — `tools/shot.tcl`

All-Tcl (no AutoIt): twapi finds the window and reads the clipboard; the capture
is Alt+PrintScreen → CF_DIB → PNG, converted in-tool (a BITMAPINFOHEADER parser
→ P6 PPM → Tk photo → PNG). It raises els topmost (twapi has no occlusion-proof
PrintWindow), retries the foreground-dependent grab, and crops to the window.
For human review, not the test path. Run `x shot out.png [file ...]`.

## Distribution

**Copy-paste the whole folder.** Because `.toolchain/` (gitignored, ~1 GB+ — the
gcc toolchain dominates) travels with the folder, dropping it onto a fresh
Windows 11 machine just works: no install, no provisioning, no network. There is
deliberately *no* "bootstrap from nothing" script — a multi-hundred-MB gcc + Tcl
toolchain can't be conjured without either downloading it (needs hosting) or
building it from source (slow, and the Tcl/Tk build runs MSYS2's bash), so it
would only add a fragile, half-working path. `x toolcheck --prep` can still fetch
the small auto-installable pieces (twapi, git) when only those are missing.

## Portability / relocation

Portable **by construction**: every path resolves relative to the invoking
script (`%~dp0` in `x.cmd`, `[info script]` in the Tcl). **Verified** by copying
the whole tree to a different absolute path and running `x build-ext` + `x test`
from there — the relocated gcc compiled the C23 extension and the relocated
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
