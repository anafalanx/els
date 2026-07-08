# els toolchain

How els is built, tested, and packaged using z's shared runtime payloads.
els is a hosted z project under `C:\z\_els`; the z workspace's `z.exe` is the public
front door, and [`z.json`](z.json) drives `tools/tasks.tcl` with z's
`tclsh90`. els carries no private toolchain — every payload comes from
`<z>/r`.

## Language policy

The project and its tooling use only two languages, plus z's command surface:

| Allowed | Used for |
|---|---|
| Tcl 9 | the editor (`els.tcl`), tooling (`tools/*.tcl`), tests (`tests/*`) |
| C23 | native extensions (`src/*.c`), built with z's UCRT64 gcc |
| z command surface | `z.json` |

No bash, no PowerShell, no Python, and no project-local package manager scripts.
Avoid new `.cmd`, `.bat`, or `.ps1` glue; use `z <command>` from `_els` or
`z in els <command>` from the z workspace root.

The native `els.exe` needs Windows PE resources: an icon, an application
manifest, and version info. els keeps them out of committed source. They are
generated from Tcl at build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the
gitignored `build/` directory and compiled with z's `windres`.

## z shared runtime payloads

els builds against z's runtime payloads under `<z>/r` — owned by z,
shared across projects, never copied into the repo. `z.exe` exports only
`Z_ROOT` (plus `Z_PROJECT_ROOT`/`Z_PROJECT_NAME` inside a project);
`tools/tasks.tcl` resolves the three payload roots from the optional `Z_*`
override variables below when set, otherwise deriving them from `Z_ROOT` or
the hosted layout (`<z>/_els` → `<z>/r/...`). `z tasks env` prints the
resolved paths:

| Variable | Root | What | Version / note |
|---|---|---|---|
| `Z_TCLTK` | `r/tcltk/9.0.3` | Tcl/Tk 9 shared build (`tcl9/`), static build + link libs (`tcl9s/`), staged script libraries (`tcllib/`), source snippets (`tclsrc/`), and the Markdown manual (`manual/INDEX.md`) | 9.0.3 |
| `Z_MSYS2` | `r/msys2` | gcc, binutils, windres, strip (`ucrt64/bin`) | gcc 16.1.0 |
| `Z_TWAPI` | `r/twapi/5.2.0` | Windows API extension used by screenshot tooling | 5.2.0 |

`z check` checks the payload pieces els uses. `z check --deep` also runs
functional probes: Tcl evaluation, Tk widget creation, twapi loading, C23
extension compile/load, and Tcl 9 header validation.

## Tcl/Tk version: always 9, never msys2's 8.6

MSYS2's `ucrt64` may contain Tcl/Tk 8.6 for its own packages. els never uses it.
The rule is:

- Tooling invokes interpreters through explicit payload paths:
  `r/tcltk/9.0.3/tcl9/bin/tclsh90.exe`, `.../tcl9/bin/wish90.exe`, and
  `.../tcl9s/bin/tclsh90s.exe`.
- PATH puts the Tcl/Tk 9 `tcl9/bin` ahead of `r/msys2/ucrt64/bin`.
- C builds pass `-I<TCLTK>/tcl9/include`, so `tcl.h` is the 9.x header.

`z check --deep` enforces the practical version of that rule.

## Entry point: `z.json`

[`z.json`](z.json) is the normal entry point. It:

1. lets z discover the project root;
2. runs each command as `tclsh90 tools/tasks.tcl <task>` (z resolves
   `tclsh90` to `r/tcltk/9.0.3/tcl9/bin/tclsh90.exe`);
3. keeps project commands visible as `z test`, `z build`, `z check`, etc.

No project-local ignition script is tracked. Durable docs, scripts, and agent
instructions must use `z` commands.

## Task runner: `tools/tasks.tcl`

Run `z tasks` to see the underlying Tcl runner's task names. The usual public
commands are `z test`, `z build`, `z check`, `z build-ext`, `z shot`, and
`z run`; use `z tasks <task>` only for task-runner details that do not yet have
a short alias.

```
z test [--fast]      run the in-process test suite; --fast skips encoding stress
z probe <f> [args]   run an ad-hoc verification script under console tclsh
z stress             UI-driven encoding stress test
z run [file ...]     launch the editor
z colors [name ...]  browse Tk named colors
z icon [size]        regenerate resources/icon.png
z shot <out> [file]  screenshot the editor via twapi + PrintWindow
z readme-shots       regenerate README screenshots
z build [out]        build the native exe -> dist/els.exe
z sign [exe]         code-sign the release exe (Certum/SimplySign) + re-probe + verify
z probe-exe [exe]    verify fused exe startup/session/recovery behavior
z build-ext          compile src/*.c C23 extensions -> build/*.dll
z check [--deep]     check z's runtime payloads
z tasks env          print resolved payload roots and versions
```

There are deliberately no fetch/prep tasks here. A missing payload piece means
z's runtime is not fully hydrated — restore it on the z side, not in els.

## C23 and Tcl extensions

els drops into C23 for hot paths or native Windows bindings, exposed to Tcl as
ordinary commands. The native `els.exe` statically links the product extension
code. During development, `z build-ext` also builds each loadable extension as a
stubs DLL under `build/` (`<TCLTK>` is the resolved `r/tcltk/9.0.3` payload):

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS ^
    -I<TCLTK>/tcl9/include src/elsx.c ^
    -o build/elsx.dll -L<TCLTK>/tcl9/lib -ltclstub -static-libgcc
```

`src/icudet.c` dynamically loads the Windows system ICU (`icu.dll`) to expose
charset detection to Tcl. `src/winfs.c` provides Win32 helpers for atomic saves
and crash-recovery liveness locks. `src/windrop.c` registers Explorer
drag-and-drop so files dropped on the window open as tabs. `src/cap.c` supports
screenshot capture for `tools/shot.tcl`. `src/els_main.c` is the exe entry point
and is not built as a loadable extension.

## Build: `z build`

`z build` produces one self-contained native `els.exe` under `dist/`:

1. `tools/genres.tcl` generates `build/els.rc` and
   `build/els.exe.manifest`; `tools/mkico.tcl` generates `build/els.ico`.
2. `windres` compiles `build/els.rc` to `build/els.res`.
3. gcc compiles `src/els_main.c`, `src/icudet.c`, `src/winfs.c`, and `src/windrop.c`.
4. gcc links against z's static Tcl/Tk libraries in `<TCLTK>/tcl9s/lib` plus
   Win32 system libraries, then strips the bare exe.
5. `tools/package.tcl` stages `els.tcl`, resources, `tcl_library`, and
   `tk_library` (from `<TCLTK>/tcllib`), then appends the zipfs payload to the
   native exe.

The final artifact is `dist/els.exe`. `build/` contains intermediates only. A
rebuild writes `els.exe.new` and swaps it into place so a currently running
`dist/els.exe` does not block the build.

## PE-resource gotcha

Do not edit resources in a packaged exe after zipfs is appended. Tools such as
`UpdateResource` rewrite the PE image and can drop the appended payload, leaving
an exe that cannot find `init.tcl`. Bake resources into the bare PE first, then
append zipfs.

## Testing

Use:

```
z check --deep
z build-ext
z test
z build
z probe-exe
z shot --selftest
```

`els.exe --selftest [open-file [report.txt]]` is a headless mode that boots the full
app, writes a result file, and exits. The report goes to `<exe-dir>\els-selftest.txt`
unless a path is given as the SECOND argument (the first argument, if any, is a
document to open during the check). Because the release exe is a GUI-subsystem
program, do not debug failures by launching it and waiting for stderr; use the
selftest report or build a console-subsystem twin for investigation.

## Screenshots

`tools/shot.tcl` uses twapi to find the target window and the `cap` C extension
to capture it with `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`. The converter
selftest is:

```
z shot --selftest
```

## Distribution

Users only need the released `els.exe`. Developers need the els repo plus a
hydrated z workspace tree (`<z>/r/tcltk`, `r/msys2`, `r/twapi`). Those
multi-hundred-MB payloads belong to z, are shared across projects, and are
never committed to els.
