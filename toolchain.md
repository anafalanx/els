# els toolchain

How els is built, tested, packaged, and kept portable with its project-local
`.toolchain/`. els is hosted under `C:\zmal\_els`; zmal's `z.exe` is the
public front door, and `z.json` invokes the project-local `.toolchain` Tcl
directly.

## Language policy

The project and its tooling use only two languages, plus zmal's command surface:

| Allowed | Used for |
|---|---|
| Tcl 9 | the editor (`els.tcl`), tooling (`tools/*.tcl`), tests (`tests/*`) |
| C23 | native extensions (`src/*.c`), built with the `.toolchain` gcc |
| zmal command surface | `z.json` |

No bash, no PowerShell, no Python, and no project-local package manager scripts.
Avoid new `.cmd`, `.bat`, or `.ps1` glue; use `z <command>` from `_els` or
`z in els <command>` from the zmal root.

The native `els.exe` needs Windows PE resources: an icon, an application
manifest, and version info. els keeps them out of committed source. They are
generated from Tcl at build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the
gitignored `build/` directory and compiled with `.toolchain` `windres`.

## Project-local toolchain

The restored toolchain lives at `.toolchain/`. The repo can move anywhere as
long as that directory moves with it. The project treats the toolchain as
read-only and keeps build products under `build/` or `dist/`.

`.toolchain/` provides:

| Bundle path | What | Version / note |
|---|---|---|
| `tcl9/` | Tcl/Tk 9 shared build: `tclsh90.exe`, `wish90.exe`, headers, stubs | 9.0.3 |
| `tcl9s/` | Tcl/Tk 9 static build and link libraries used by `z build` | 9.0.3 |
| `tcllib/` | script libraries staged for packaging (`tcl_library`, `tk_library`) | pinned |
| `msys64/ucrt64/` | gcc, binutils, windres, strip | gcc 16.1.0 |
| `twapi-dl/twapi-5.2.0/` | Windows API extension used by screenshot tooling | 5.2.0 |
| `manual/` | Tcl/Tk 9 Markdown manual (`manual/INDEX.md`) | generated from the bundle |
| `tclsrc/` | Tcl/Tk source tree snippets used for headers/reference | 9.0.3 |

`z check` checks the parts els uses. `z check --deep` also runs
functional probes: Tcl evaluation, Tk widget creation, twapi loading, C23
extension compile/load, and Tcl 9 header validation.

## Tcl/Tk version: always 9, never msys64's 8.6

MSYS2's `ucrt64` may contain Tcl/Tk 8.6 for its own packages. els never uses it.
The rule is:

- Tooling invokes interpreters through explicit `.toolchain` paths:
  `tcl9/bin/tclsh90.exe`, `tcl9/bin/wish90.exe`, and `tcl9s/bin/tclsh90s.exe`.
- PATH puts `tcl9/bin` ahead of `msys64/ucrt64/bin`.
- C builds pass `-I.toolchain/tcl9/include`, so `tcl.h` is the 9.x header.

`z check --deep` enforces the practical version of that rule.

## Entry point: `z.json`

`z.json` is the normal entry point. It:

1. lets zmal discover the project root;
2. runs `.toolchain/tcl9/bin/tclsh90.exe tools/tasks.tcl`;
3. keeps project commands visible as `z test`, `z build`, `z check`, etc.

No project-local ignition script is tracked. Durable docs, scripts, and agent
instructions must use zmal `z` commands.

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
z probe-exe [exe]    verify fused exe startup/session/recovery behavior
z build-ext          compile src/*.c C23 extensions -> build/*.dll
z check [--deep]     check the project-local .toolchain
z tasks env          print resolved toolchain paths and versions
```

There are deliberately no fetch/prep tasks here. Missing or outdated bundle
contents mean `.toolchain/` was not restored completely.

## C23 and Tcl extensions

els drops into C23 for hot paths or native Windows bindings, exposed to Tcl as
ordinary commands. The native `els.exe` statically links the product extension
code. During development, `z build-ext` also builds each loadable extension as a
stubs DLL under `build/`:

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS ^
    -I.toolchain/tcl9/include src/elsx.c ^
    -o build/elsx.dll -L.toolchain/tcl9/lib -ltclstub -static-libgcc
```

`src/icudet.c` dynamically loads the Windows system ICU (`icu.dll`) to expose
charset detection to Tcl. `src/winfs.c` provides Win32 helpers for atomic saves
and crash-recovery liveness locks. `src/cap.c` supports screenshot capture for
`tools/shot.tcl`. `src/els_main.c` is the exe entry point and is not built as a
loadable extension.

## Build: `z build`

`z build` produces one self-contained native `els.exe` under `dist/`:

1. `tools/genres.tcl` generates `build/els.rc` and
   `build/els.exe.manifest`; `tools/mkico.tcl` generates `build/els.ico`.
2. `windres` compiles `build/els.rc` to `build/els.res`.
3. gcc compiles `src/els_main.c`, `src/icudet.c`, and `src/winfs.c`.
4. gcc links against the static Tcl/Tk libraries in `<bundle>/tcl9s/lib` plus
   Win32 system libraries, then strips the bare exe.
5. `tools/package.tcl` stages `els.tcl`, resources, `tcl_library`, and
   `tk_library`, then appends the zipfs payload to the native exe.

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

`els.exe --selftest [report.txt]` is a headless mode that boots the full app,
writes a result file, and exits. Because the release exe is a GUI-subsystem
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

Users only need the released `els.exe`. Developers need the els repo plus its
`.toolchain/` directory. The multi-hundred-MB toolchain is intentionally ignored
by git and travels as a local project payload.
