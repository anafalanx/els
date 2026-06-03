# els

A tiny, scriptable text editor — **Tcl/Tk 9 edition**.

els is being rebuilt on Tcl/Tk 9: a clean, cross-platform editor for everyday
text files. The previous C23/Lua line shipped through v0.3 and is preserved
separately. The new foundation trades a hand-written C core for Tk's mature
**Text widget** (the buffer) and **Tcl** (the scripting language), for far less
to maintain and Windows/macOS/Linux from one codebase.

Design language carried over: a calm grey page, the signature **red caret**,
restrained chrome, opinionated defaults.

## Toolchain & tasks

The project is **fully self-contained**: a vendored Tcl/Tk 9, the gcc/C23
toolchain (MSYS2 UCRT64), and twapi all live under `.toolchain/`, so the folder
is copy-paste portable to any Windows 11+ machine — no installs, no system
dependencies. One **ignition script**, `x.cmd`, puts the vendored toolchain on
PATH (relative to itself) and hands off to a Tcl task runner; everything else is
Tcl or C.

```
x help          # list tasks
x run [file...] # launch the editor
x test          # in-process test suite (tcltest + Tk event generate)
x shot out.png  # screenshot the editor (twapi, all-Tcl — no AutoIt)
x build         # fuse the single-file els.exe (--with-ext embeds build/*.dll)
x build-ext     # compile src/*.c C23 extensions -> build/*.dll
x toolcheck     # check the vendored toolchain (--prep fetches what's missing)
x shell         # a shell with the vendored toolchain on PATH
x env           # show the resolved toolchain
```

`x build` produces one self-contained `els.exe` (~6.7 MB, zero non-system DLLs)
by fusing `els.tcl` + Tcl/Tk into a `zipfs` image on a static interpreter;
`x build --with-ext` also embeds any compiled C extension so it loads from
inside the exe. Distribution is copy-paste of the whole folder (it carries the
vendored `.toolchain/`) — no installer, no provisioning.

The project uses **only C and Tcl 9**, plus one classical-`cmd` boot script
(`x.cmd`) — no bash, PowerShell, or Python. See
[`toolchain.md`](toolchain.md) for the full setup.

The toolchain (Tcl/Tk 9, gcc/C23, twapi, MinGit) lives under `.toolchain/` and is
**relocatable** — verified by copying the folder to a different path and
rebuilding + testing from there. `x toolcheck` reports each component; `x
toolcheck --prep` fetches the auto-installable pieces (twapi, git) on a freshly
cloned checkout. Everyday commands only fast-check the one or two tools they
need, so they stay instant.

## C extensions (C23)

els can drop into **C23** for hot paths or to bind a C library, exposed to Tcl
as ordinary commands. Extensions build against the Tcl *stubs* (compiler-
independent, system-DLL-only) with the vendored gcc — see `src/elsx.c`. They can
load dynamically (`package require`) or be embedded in the single-file `els.exe`
via its `zipfs` image. `x build-ext` compiles them; tests live in
`tests/elsx.test`.

## Status

Early skeleton — multi-file tabs, open/save/new, menu, status bar (Ln/Col),
icon, line-number gutter, current-line highlight, window geometry persistence,
the els look. Each tab is its own document (independent undo, selection, dirty
state); open several at once from the command line. Porting the rest of the
v0.3 features (find/replace, go-to-line, whitespace view, …) onto Tk.

Built on **Tcl/Tk 9.0.3**. MIT licensed.
