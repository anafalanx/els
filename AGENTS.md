# Agent Instructions

`els` lives as a hosted project under `C:\zmal\_els`. Use zmal as the public
front door: run `z test`, `z build`, `z check`, or `z tasks` from `_els`, or
`z in els <task>` from the zmal root. The committed [`z.json`](z.json) drives
`tools/tasks.tcl` with zmal's `tclsh90`; els builds against zmal's shared runtime
payloads under `<zmal>/r` (Tcl/Tk 9, the UCRT64 gcc, twapi) and carries no
private toolchain. There is no project-local ignition script; do not add `.cmd`,
`.bat`, `.ps1`, or shell wrapper entry points.

Treat `z.exe` as zmal's only public entry point. Do not call zmal payload paths
directly from docs, scripts, or agent commands. Strongly avoid PowerShell and
Windows cmd for zmal-backed work; use `z <tool>`, `z bash -c "..."`, or named
project commands in [`z.json`](z.json).

## Read the Tcl/Tk 9 manual first

This repo uses the complete Tcl 9 and Tk 9 manual that ships in zmal's Tcl/Tk
payload (`<TCLTK>/manual/`, where `<TCLTK>` is the path `z tasks env` reports,
currently `C:\zmal\r\tcltk\9.0.3`).
It includes Tcl commands, Tk commands, the C API, and `tclsh`/`wish`. It is the
authoritative reference for this codebase; prefer it over training-data recall,
which may be stale or describe Tcl 8.x behavior.

- Before writing or changing any Tcl/Tk code, consult the manual. Start at
  `<TCLTK>/manual/INDEX.md` and read the pages relevant to your change (each
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

- `z build` builds it into `dist/els.exe`, the one artifact that gets run and
  released. `build/` holds intermediates only; the repo root holds no binaries.
  The build compiles `src/els_main.c`, `src/icudet.c`, and `src/winfs.c`;
  generates the PE icon/manifest/version resources from Tcl into `build/`;
  runs `windres`; links zmal's static `r/tcltk/9.0.3/tcl9s` libraries; and appends the
  zipfs payload. The final swap is staged so a running `dist/els.exe` does not
  block a rebuild.
- The architecture, the proven static-link recipe, and the pitfalls are in
  `docs/native-port-study.md`; a robustness audit and hardening roadmap is in
  `docs/robustness-hardening-study.md`.
- Verify the exe headlessly: `els.exe --selftest [report.txt]` writes a report
  file (GUI subsystem means no stderr); `z probe-exe` checks first-run/session
  behavior; `z test` runs the packaging-independent suite. Never debug a GUI
  build by running it on a failure and waiting for stderr; read the selftest
  report, or build a console-subsystem twin.

## General

- Use Tcl as much as possible for project tooling in this repo.
- Do not use PowerShell or Windows cmd for zmal-backed project work.
- Where Tcl is genuinely not suitable, use a named `z.json` command or a direct
  `z <tool>` invocation.
- Double-check UI changes through the exact user-facing interaction path before
  reporting them fixed.
- Be precise about verification: only claim behavior that was actually checked.
<!-- DRENN-CODEX-BEGIN -->
## Drenn Project Memory

This project has Drenn configured as a project-local MCP server. For substantial work, use Drenn as durable project memory: start by calling `drenn_info`, inspect existing memory programs with `list_programs`, and call `get_program` before running an unfamiliar durable program. Run or create Lua memory programs when they would help future agents.

Use `run_lua` for quick volatile one-call tools. Use `install_program` and `run_program` for memory behavior that should survive across Codex sessions. Before finishing significant work, preserve durable project facts, decisions, and useful observations in Drenn when a suitable memory program exists or when creating one is worthwhile.

Do not store secrets, credentials, private tokens, or unrelated personal data in Drenn. Treat the Tcl/Tk observer as read-only.
<!-- DRENN-CODEX-END -->
