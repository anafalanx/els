# els toolchain

How els is built, tested, and packaged using z's shared runtime payloads.
els is a hosted z project under `C:\dev\_els`; the z workspace's `z.exe` is the public
front door, and [`z.json`](z.json) drives `tools/tasks.tcl` with z's
`tclsh90`. els carries no private toolchain — every payload comes from
`<z>/.z/r`.

## Language policy

The project and its tooling use only two languages, plus z's command surface:

| Allowed | Used for |
|---|---|
| Tcl 9 | the editor (`els.tcl`), tooling (`tools/*.tcl`), tests (`tests/*`) |
| C23 | the native exe entry point and native modules (`src/*.c`), built with z's UCRT64 gcc |
| z command surface | `z.json` |

No bash, no PowerShell, no Python, and no project-local package manager scripts.
Avoid new `.cmd`, `.bat`, or `.ps1` glue; use `z <command>` from `_els` or
`z in els <command>` from the z workspace root.

The native `els.exe` needs Windows PE resources: an icon, an application
manifest, and version info. els keeps them out of committed source. They are
generated from Tcl at build time (`tools/genres.tcl`, `tools/mkico.tcl`) into the
gitignored `build/` directory and compiled with z's `windres`.

## z shared runtime payloads

els builds against z's runtime payloads under `<z>/.z/r` — owned by z,
shared across projects, never copied into the repo. `z.exe` exports `Z_HOME`
(and may also export `Z_ROOT`, plus `Z_PROJECT_ROOT`/`Z_PROJECT_NAME` inside a project);
`tools/tasks.tcl` resolves the three payload roots from the optional `Z_*`
override variables below when set, otherwise deriving them from `Z_HOME`, then
`Z_ROOT` (as `$Z_ROOT/.z`), then the hosted layout (`<z>/_els` → `<z>/.z/r/...`). `z tasks env` prints the
resolved paths:

| Variable | Root | What | Version / note |
|---|---|---|---|
| `Z_TCLTK` | `r/tcltk/9.0.3` | Tcl/Tk 9 shared build (`tcl9/`), static build + link libs (`tcl9s/`), staged script libraries (`tcllib/`), source snippets (`tclsrc/`), and the Markdown manual (`manual/INDEX.md`) | 9.0.3 |
| `Z_MSYS2` | `r/msys2` | gcc, binutils, windres, strip (`ucrt64/bin`) | gcc 16.1.0 |
| `Z_TWAPI` | `r/twapi/5.2.0` | Windows API extension (twapi); a z-shared payload `z check` verifies -- els's private-desktop screenshots no longer use it | 5.2.0 |

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
commands include `z test`, `z build`, `z release-check`, `z sign`, `z check`,
`z build-ext`, `z shot`, and `z run`; use `z tasks <task>` only for task-runner
details that do not yet have a short alias.

```
z test [--fast]      run the in-process test suite; --fast skips encoding stress
z probe <f> [args]   run an ad-hoc verification script under console tclsh
z stress             UI-driven encoding stress test
z run [file ...]     launch the editor
z colors [name ...]  browse Tk named colors
z icon [size]        regenerate resources/icon.png
z shot <out> [file]  screenshot the editor on a private desktop via PrintWindow
z readme-shots       regenerate README screenshots
z build [out]        development build -> build/els-dev.exe; out must be build/*.exe
z release-check      fail-closed clean build/test/probe -> dist/els-unsigned.exe
z sign [in]          sign a verified artifact, re-probe, promote -> dist/els.exe
z probe-exe [exe]    verify fused exe startup and session-restore behavior
z pecheck [mode] [exe] verify AMD64/GUI/mitigation/manifest/certificate-table policy
z build-ext          compile the five loadable C23 modules -> build/*.dll
z native-startup-check build/package a test-only init failure and prove fail-closed exit
z check [--deep]     check z's runtime payloads
z tasks env          print resolved payload roots and versions
```

There are deliberately no fetch/prep tasks here. A missing payload piece means
z's runtime is not fully hydrated — restore it on the z side, not in els.

## C23 and Tcl extensions

els drops into C23 for hot paths or native Windows bindings, exposed to Tcl as
ordinary commands. The product build compiles `icudet`, `winfs`, and `windrop`
as ordinary static objects and registers them from `src/els_main.c`.
During development and tests, `z build-ext` instead builds the five loadable
modules (`cap`, `elsx`, `icudet`, `winfs`, and `windrop`) as Tcl stubs DLLs under
`build/` (`<TCLTK>` is the resolved `r/tcltk/9.0.3` payload):

```
gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS ^
    -I<TCLTK>/tcl9/include src/elsx.c ^
    -o build/elsx.dll -L<TCLTK>/tcl9/lib -ltclstub -static-libgcc
```

`src/icudet.c` dynamically loads the Windows system ICU (`icu.dll`) to expose
charset detection to Tcl. `src/winfs.c` provides Win32 helpers for atomic,
durable saves (ReplaceFileW + FlushFileBuffers) and the isolated find/replace
worker. `src/windrop.c` registers Explorer
drag-and-drop so files dropped on the window open as tabs. `src/cap.c` supports
screenshot capture for `tools/shot.tcl`. `src/els_main.c` is the exe entry point
and is never built as a loadable extension. `cap` and `elsx` remain development/
test helpers; they are not part of the product-static link.

## Development build: `z build`

`z build` produces one self-contained native development executable under
`build/` (`build/els-dev.exe` by default):

1. `tools/genres.tcl` generates `build/els.rc` and
   `build/els.exe.manifest`; `tools/mkico.tcl` generates `build/els.ico`.
2. `windres` compiles `build/els.rc` to `build/els.res`.
3. gcc compiles `src/els_main.c`, `src/icudet.c`, `src/winfs.c`, and `src/windrop.c`.
4. gcc links against z's static Tcl/Tk libraries in `<TCLTK>/tcl9s/lib` plus
   Win32 system libraries, then strips the bare exe.
5. `tools/package.tcl` stages `els.tcl`, Git-tracked resources, the els license,
   exact third-party notices, `tcl_library`, and `tk_library` (from
   `<TCLTK>/tcllib`), then appends the zipfs payload to the native exe.

An optional output must normalize below `build/` and end in `.exe`; source files,
directories, links, and release paths are rejected. Placement uses a unique
staged file and restores the prior build if replacement fails. Development
builds never write `dist/`; releases use the gate below.

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
z probe-exe build/els-dev.exe
z shot --selftest
```

`z probe-exe build/els-dev.exe` copies that exact candidate into isolated
standalone directories and launches real child processes with controlled
profile, state, and temporary paths. It verifies adjacent-state behavior and
explicit and restored (session) opens, and it exercises the fused worker's
watch-before-go dispatch, without depending on an installed or previously
released copy. Separately, `z pecheck`
parses the PE and permits only its reviewed Windows system/API-set import
surface; it also checks whether the Authenticode certificate table is absent or
present as requested. It does **not** establish signer trust or identity:
`z sign` delegates that to the trusted Windows SDK `signtool`, pins the expected
publisher (and optionally its SHA-1 thumbprint), and requires a verified RFC 3161
timestamp.

`els.exe --selftest [open-file [report.txt]]` is a headless mode that boots the full
app, writes a result file, and exits. The report goes to `<exe-dir>\els-selftest.txt`
unless a path is given as the SECOND argument (the first argument, if any, is a
document to open during the check). Because the release exe is a GUI-subsystem
program, do not debug failures by launching it and waiting for stderr; use the
selftest report or build a console-subsystem twin for investigation.

## Release: fail closed, then sign

The release path is deliberately separate from `z build`:

```
z release-check
z sign
```

`z release-check` refuses a dirty source tree, verifies that signing tools are
available from trusted fixed locations, runs the deep toolchain check, rebuilds
and loads every native extension, checks release-tooling invariants, and runs the
complete suite with skips treated as failures. It then builds a staged
executable, compiles a test-only native initialization failure and proves it
exits before Tcl UI startup, verifies every embedded main/resource/Tcl/Tk file
and license-notice byte against its trusted source, applies the
AMD64/GUI/mitigation/manifest PE policy, probes the real
packaged process, and confirms that the source tree did not change during the
run. Its provenance schema, artifact size/hash, clean Git state, compiler/header/
link inputs, packaging tools, and notice-source fingerprints are all recomputed from
trusted local inputs before promotion. Only then does it publish the fixed
`dist/els-unsigned.exe`, its `.sha256`, and its `.provenance.txt`.

Use `--no-promote` to leave a clean-tree candidate under `build/release-check`.
`--allow-dirty` exists only for diagnostic validation and always implies
`--no-promote`; a dirty build can never become a release input.

`z sign` accepts only the verified `dist/els-unsigned.exe` set or its
`build/release-check/els-unsigned.exe` no-promotion twin; its destination is
always `dist/els.exe` and cannot be overridden. The unsigned provenance and
checksum are strictly parsed and fully recomputed before signing. It then makes
a clean product rebuild and requires the unsigned executable to reproduce
byte-for-byte, including the recorded normalized linker-map and exact link-input
evidence, before copying the verified bytes into its private signing stage.
That copy is independently size- and SHA-256-checked before `signtool` runs.
The publisher is pinned in source as **Open Source Developer Vincent
Vercauteren**; `ELS_SIGN_CERT_SHA1` may additionally pin the exact leaf
certificate. Signing requires an RFC 3161 timestamp (Certum by default;
`ELS_TIMESTAMP_URL` may override the service), verifies the resulting signer
and timestamp, re-runs signed PE policy and the packaged-process probe, writes
and revalidates new checksum/provenance sidecars, and only then promotes and
post-verifies the complete set at `dist/els.exe`. A signing, verification, or
promotion failure rolls back the release set. Promotion stages and verifies all
three members, publishes the two sidecars before the executable, and records an
on-disk recovery journal plus old/new copies. A later invocation can restore an
interrupted process-level publication or reconcile one that committed before
cleanup. This is crash-recovery machinery; the Tcl task runner does not claim an
explicit `FlushFileBuffers` power-loss guarantee for the journal itself.

Build, test, probe, screenshot, release-check, and signing tasks share an
exclusive `build/.els-tooling.lock`, preventing concurrent tasks from racing on
common intermediates. A stale lock fails closed and reports its owner; it is
removed manually only after confirming that owner is no longer running.

## Screenshots

`tools/shot.tcl` renders the editor on a private Win32 desktop (created by the
`cap` C extension's `elscap::run_private`, never the input desktop, so nothing
flashes on screen), and the staged child captures its own toplevel with
`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`. This replaced the earlier twapi
window-finding design and is twapi-free. The converter selftest is:

```
z shot --selftest
```

## Distribution

Users only need the released `els.exe`. Developers need the els repo plus a
hydrated z workspace tree (`<z>/.z/r/tcltk`, `.z/r/msys2`, `.z/r/twapi`). Those
multi-hundred-MB payloads belong to z, are shared across projects, and are
never committed to els.

The `.sha256` and `.provenance.txt` release sidecars let users and maintainers
verify the executable but are not runtime dependencies. `LICENSE.txt` and
`THIRD-PARTY-NOTICES.txt` are embedded in the appended zipfs payload. The latter
contains the exact applicable Tcl, Tk, MinGW-w64 runtime, GCC GPLv3 and runtime-exception,
zlib, and LibTomMath notice files used by the build.

At runtime, the packaged app keeps `els.conf`, `els.deferred`,
`backups\`, rotating `els.log`/`els.log.1`, and transient
`.els-find\` only beside `els.exe`; a source run uses the directory containing
`els.tcl`. There is no profile fallback, migration, or deletion of old profile
state. The sole legacy bridge is adjacent: when `els.conf` is absent but
`config.tcl` exists in that same directory, els copies it once to `els.conf` and
leaves the original intact. The application directory must therefore be
writable. Moving the exe without those sidecars gives it separate, fresh state.
