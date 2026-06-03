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
.toolchain/tcl9/bin/wish90.exe els.tcl [file]
```

## Status

Early skeleton — open/save/new, menu, status bar (Ln/Col), icon, line-number
gutter, current-line highlight, window geometry persistence, the els look.
Porting v0.3 features (tabs, find/replace, go-to-line, whitespace view, …) onto Tk.

Built on **Tcl/Tk 9.0.3**. MIT licensed.
