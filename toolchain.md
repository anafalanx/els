# els toolchain

How els is built, tested, packaged, and kept portable inside the mal workspace.
els is a Tcl/Tk 9 editor with C23 extensions. The project no longer carries a
private `.toolchain/`; instead, `x.cmd` reads `toolchain.pin` and uses the
sealed mal bundle named there.

## Language policy

The project and its tooling use only two languages, plus one boot script:

| Allowed | Used for |
|---|---|
| Tcl 9 | the editor (`els.tcl`), tooling (`tools/*.tcl`), tests (`tests/*`) |
| C23 | native extensions (`src/*.c`), built with the pinned bundle gcc |
| classical Windows `cmd` | exactly one file: `x.cmd` |

No bash, no PowerShell, no Python, and no project-local package manager scripts.
The `.cmd` file exists only because PATH has to be set before Tcl is reachable;
all real logic lives in Tcl.

The native `els.exe` needs Windows PE resources: an icon, an application
manifest, and version info. els keeps them out of committed source. They are
generated from Tcl at build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the
gitignored `build/` directory and compiled with the pinned bundle `windres`.

## Pinned mal bundle

`toolchain.pin` contains the bundle name, currently:

```
tika26b
```

`x.cmd` starts at the repo directory and walks upward until it finds:

```
X/<pin>/BUNDLE.manifest
```

In the normal mal layout that resolves to `C:\mal\X\tika26b`. The repo can move
within that mal tree, and the bundle can be resealed by mal, but the repo itself
does not own or mutate the bundle.

The pinned bundle provides:

| Bundle path | What | Version / note |
|---|---|---|
| `tcl9/` | Tcl/Tk 9 shared build: `tclsh90.exe`, `wish90.exe`, headers, stubs | 9.0.3 |
| `tcl9s/` | Tcl/Tk 9 static build and link libraries used by `x build` | 9.0.3 |
| `tcllib/` | script libraries staged for packaging (`tcl_library`, `tk_library`) | pinned |
| `msys64/ucrt64/` | gcc, binutils, windres, strip | gcc 16.1.0 |
| `twapi-dl/twapi-5.2.0/` | Windows API extension used by screenshot tooling | 5.2.0 |
| `manual/` | Tcl/Tk 9 Markdown manual (`manual/INDEX.md`) | generated from the bundle |
| `tclsrc/` | Tcl/Tk source tree snippets used for headers/reference | 9.0.3 |

Check the bundle itself from the mal root with:

```
mal verify tika26b
mal status
```

`x toolcheck` checks the parts els uses. `x toolcheck --deep` also runs
functional probes: Tcl evaluation, Tk widget creation, twapi loading, C23
extension compile/load, and Tcl 9 header validation.

## Tcl/Tk version: always 9, never msys64's 8.6

MSYS2's `ucrt64` may contain Tcl/Tk 8.6 for its own packages. els never uses it.
The rule is:

- Tooling invokes interpreters through explicit bundle paths:
  `tcl9/bin/tclsh90.exe`, `tcl9/bin/wish90.exe`, and `tcl9s/bin/tclsh90s.exe`.
- PATH puts `tcl9/bin` ahead of `msys64/ucrt64/bin`.
- C builds pass `-I<X>/<pin>/tcl9/include`, so `tcl.h` is the 9.x header.

`x toolcheck --deep` enforces the practical version of that rule.

## Ignition: `x.cmd`

`x.cmd` is the single entry point. It:

1. reads `toolchain.pin`;
2. resolves the matching mal bundle by walking upward to `X/<pin>/`;
3. prepends the bundle Tcl and gcc directories to PATH;
4. sets `TCL_LIBRARY` and `TK_LIBRARY` from `tcllib/`;
5. dispatches to `tools/x.tcl`.

Double-clicking `x.cmd`, running `x` with no arguments, or running `x shell`
opens a command shell with the pinned bundle on PATH. Other commands hand off to
the Tcl task runner.

## Task runner: `tools/x.tcl`

Run `x help`:

```
x test [--fast]      run the in-process test suite; --fast skips encoding stress
x probe <f> [args]   run an ad-hoc verification script under console tclsh
x stress             UI-driven encoding stress test
x run [file ...]     launch the editor
x colors [name ...]  browse Tk named colors
x icon [size]        regenerate resources/icon.png
x shot <out> [file]  screenshot the editor via twapi + PrintWindow
x readme-shots       regenerate README screenshots
x build [out]        build the native exe -> dist/els.exe
x probe-exe [exe]    verify fused exe startup/session/recovery behavior
x build-ext          compile src/*.c C23 extensions -> build/*.dll
x toolcheck [--deep] check the pinned bundle
x shell              open a shell with the pinned bundle on PATH
x env                print resolved bundle paths and versions
```

There are deliberately no fetch/prep tasks here. Missing or outdated bundle
contents are a mal concern, not an els checkout concern.

## C23 and Tcl extensions

els drops into C23 for hot paths or native Windows bindings, exposed to Tcl as
ordinary commands. The native `els.exe` statically links the product extension
code. During development, `x build-ext` also builds each loadable extension as a
stubs DLL under `build/`:

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS ^
    -I<X>/<pin>/tcl9/include src/elsx.c ^
    -o build/elsx.dll -L<X>/<pin>/tcl9/lib -ltclstub -static-libgcc
```

`src/icudet.c` dynamically loads the Windows system ICU (`icu.dll`) to expose
charset detection to Tcl. `src/winfs.c` provides Win32 helpers for atomic saves
and crash-recovery liveness locks. `src/cap.c` supports screenshot capture for
`tools/shot.tcl`. `src/els_main.c` is the exe entry point and is not built as a
loadable extension.

## Build: `x build`

`x build` produces one self-contained native `els.exe` under `dist/`:

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
x toolcheck --deep
x build-ext
x test
x build
x probe-exe
x shot --selftest
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
x shot --selftest
```

## Distribution

Users only need the released `els.exe`. Developers need the els repo inside a
mal workspace that contains the pinned bundle under `X/<pin>/`. The source repo
does not vendor the multi-hundred-MB toolchain anymore, so bundle creation,
resealing, and verification live at the mal layer.
