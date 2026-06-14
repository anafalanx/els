# Agent Instructions

## Read the Tcl/Tk 9 manual first

This repo uses the complete Tcl 9 and Tk 9 manual from the pinned mal bundle
named in `toolchain.pin`. In the normal mal layout it lives under
`..\X\<pin>\manual\` and includes Tcl commands, Tk commands, the C API, and
`tclsh`/`wish`. It is the authoritative reference for this codebase; prefer it
over training-data recall, which may be stale or describe Tcl 8.x behavior.

- Before writing or changing any Tcl/Tk code, consult the manual. Start at
  `..\X\<pin>\manual\INDEX.md` and read the pages relevant to your change (each
  file is named after the command/function, e.g. `commands/text.md`,
  `commands/ttk_treeview.md`, `c-api/Tcl_Obj.md`).
- Do not try to read all 1293 pages into context. Open the few that matter for
  the task. Grep the manual tree to find the right page. If, during execution
  of the task, you need further guidance from the manual, read more pages.

## The build is native (custom C entry point)

`els.exe` is a real native Windows PE: a custom C23 `WinMain`
(`src/els_main.c`, a minimal fork of Tk's `winMain.c`) with Tcl, Tk, the icudet
charset detector, and the Win32 file-system helper statically linked in, plus
the Tcl/Tk script libraries and `els.tcl` riding inside an appended zipfs image.
`els.tcl` is ordinary Tcl, unchanged by the C entry point.

- `x build` builds it into `dist/els.exe`, the one artifact that gets run and
  released. `build/` holds intermediates only; the repo root holds no binaries.
  The build compiles `src/els_main.c`, `src/icudet.c`, and `src/winfs.c`;
  generates the PE icon/manifest/version resources from Tcl into `build/`;
  runs `windres`; links the static `<bundle>/tcl9s` libraries; and appends the
  zipfs payload. The final swap is staged so a running `dist/els.exe` does not
  block a rebuild.
- The architecture, the proven static-link recipe, and the pitfalls are in
  `docs/native-port-study.md`; a robustness audit and hardening roadmap is in
  `docs/robustness-hardening-study.md`.
- Verify the exe headlessly: `els.exe --selftest [report.txt]` writes a report
  file (GUI subsystem means no stderr); `x probe-exe` checks first-run/session
  behavior; `x test` runs the packaging-independent suite. Never debug a GUI
  build by running it on a failure and waiting for stderr; read the selftest
  report, or build a console-subsystem twin.

## General

- Use Tcl as much as possible for project tooling in this repo.
- Do not use PowerShell for project work.
- Where Tcl is genuinely not suitable, use standard Windows command line
  commands.
- Double-check UI changes through the exact user-facing interaction path before
  reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
