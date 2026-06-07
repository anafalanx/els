# Agent Instructions

## Read the Tcl/Tk 9 manual first

This repo vendors the **complete Tcl 9 & Tk 9 manual** as Markdown under
[`docs/tcl-tk-9-manual/`](docs/tcl-tk-9-manual/) (1293 pages: Tcl + Tk commands,
the C API, and `tclsh`/`wish`). It is the **authoritative reference** for this
codebase — prefer it over training-data recall, which may be stale or describe
Tcl 8.x behavior.

- **Before writing or changing any Tcl/Tk code, consult the manual.** Start at
  [`docs/tcl-tk-9-manual/INDEX.md`](docs/tcl-tk-9-manual/INDEX.md) and read the
  pages relevant to your change (each file is named after the command/function,
  e.g. `commands/text.md`, `commands/ttk_treeview.md`, `c-api/Tcl_Obj.md`).
- Do **not** try to read all 1293 pages into context — open the few that matter
  for the task. Grep the tree to find the right page. If, during execution of
  the task, you need further guidance from the manual, you can read more pages.
- The pages are generated from the vendored nroff by `tools/man2md.tcl`; to
  refresh them, rerun `tclsh90 tools/man2md.tcl` (do not hand-edit the output).

## General

- Use Tcl as much as possible for project tooling in this repo.
- Do not use PowerShell for project work.
- Where Tcl is genuinely not suitable, use standard Windows command line
  commands.
- Double-check UI changes through the exact user-facing interaction path before
  reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
