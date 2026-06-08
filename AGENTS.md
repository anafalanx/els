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

## The build is native (custom C entry point)

`els.exe` is a **real native Windows PE**: a custom C23 `WinMain`
(`src/els_main.c`, a minimal fork of Tk's `winMain.c`) with Tcl, Tk, and the
icudet charset detector **statically linked in**, plus the Tcl/Tk script libraries
and `els.tcl` riding inside an appended zipfs image. `els.tcl` is ordinary Tcl,
unchanged by the C entry point.

- **`x build`** builds it (compile `src/els_main.c` + `src/icudet.c`; the PE
  icon/manifest/version `.rc`/`.manifest`/`.ico` are **generated from Tcl** by
  `tools/genres.tcl` + `tools/mkico.tcl` into gitignored `build/`, then `windres`'d;
  link the static `.toolchain/tcl9s` libs; append the zipfs payload).
  **`x build-wish`** is the legacy wrapper build (fuse onto `wish90s.exe`),
  kept as a fallback.
- The architecture, the proven static-link recipe, and the pitfalls are in
  [`docs/native-port-study.md`](docs/native-port-study.md); a robustness audit +
  hardening roadmap is in
  [`docs/robustness-hardening-study.md`](docs/robustness-hardening-study.md).
- Verify the exe headlessly: `els.exe --selftest [report.txt]` writes a report
  file (GUI subsystem = no stderr); `x probe-exe` checks first-run + session
  restore; `x test` runs the packaging-independent suite. **Never** debug a GUI
  build by running it on a failure — it rains modal dialogs; read the file-report
  selftest, or build a console-subsystem twin (gcc without `-mwindows`).

## General

- Use Tcl as much as possible for project tooling in this repo.
- Do not use PowerShell for project work.
- Where Tcl is genuinely not suitable, use standard Windows command line
  commands.
- Double-check UI changes through the exact user-facing interaction path before
  reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
