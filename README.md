# els

A tiny, scriptable text editor — **Tcl/Tk 9 edition**.

els is being rebuilt on Tcl/Tk 9: a clean, cross-platform editor for everyday
text files. The previous C23/Lua line shipped through v0.3 and is preserved
separately. The new foundation trades a hand-written C core for Tk's mature
**Text widget** (the buffer) and **Tcl** (the scripting language), for far less
to maintain and Windows/macOS/Linux from one codebase.

Design language carried over: a calm grey page, the signature **red caret**,
restrained chrome, opinionated defaults.

## Run (dev)

```
els.cmd                       # Windows — uses the vendored Tcl/Tk 9 under .toolchain/
# or directly:
.toolchain/tcl9/bin/wish90.exe els.tcl [file ...]
```

## Test

The suite drives the real Tk widgets in-process (`tcltest` + Tk's
`event generate`) — white-box and headless, no second runtime:

```
.toolchain/tcl9/bin/tclsh90.exe tests/run.tcl
```

The tooling is **all-Tcl** (no AutoIt). Screenshots use
[twapi](https://github.com/apnadkarni/twapi) for window control + a Tcl/Tk
DIB→PNG capture (`scripts/fetch-twapi.sh` vendors it):

```
.toolchain/tcl9/bin/tclsh90.exe tools/shot.tcl <wish90.exe> els.tcl out.png [file ...]
```

## Status

Early skeleton — multi-file tabs, open/save/new, menu, status bar (Ln/Col),
icon, line-number gutter, current-line highlight, window geometry persistence,
the els look. Each tab is its own document (independent undo, selection, dirty
state); open several at once from the command line. Porting the rest of the
v0.3 features (find/replace, go-to-line, whitespace view, …) onto Tk.

Built on **Tcl/Tk 9.0.3**. MIT licensed.
