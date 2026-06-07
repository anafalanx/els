# Claude / agent instructions

The canonical instructions for this repo live in **[`AGENTS.md`](AGENTS.md)** —
read it first.

Most important: this repo vendors the **full Tcl 9 & Tk 9 manual** as Markdown
under **[`docs/tcl-tk-9-manual/`](docs/tcl-tk-9-manual/)** (start at
[`INDEX.md`](docs/tcl-tk-9-manual/INDEX.md)). It is the authoritative Tcl/Tk
reference for this codebase — before writing or changing Tcl/Tk code, open the
manual pages relevant to your change (grep the tree; don't read all 1293 pages).
Prefer it over training-data recall, which may be stale or describe Tcl 8.x.
