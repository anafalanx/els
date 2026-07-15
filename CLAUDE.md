# Claude / agent instructions

The canonical instructions for this repo live in `AGENTS.md`; read it first.

`els` is hosted under `C:\dev\_els`. Use z as the public front door:
run `z test`, `z build`, `z check`, or `z tasks` from `_els`, or
`z in els <task>` from the z workspace root. els is a full z project: it builds
against z's shared runtime payloads under `<z>/.z/r` (Tcl/Tk 9, the UCRT64
gcc, twapi) and carries no private `.toolchain`. `z tasks env` prints the
resolved payload roots.

Most important: this repo uses the full Tcl 9 and Tk 9 manual that ships in
z's Tcl/Tk payload, at `<TCLTK>/manual/INDEX.md` — where `<TCLTK>` is the
path `z tasks env` reports (currently `C:\dev\.z\r\tcltk\9.0.3`). It is the
authoritative Tcl/Tk reference for this codebase. Before writing or changing
Tcl/Tk code, open the manual pages relevant to your change. Prefer it over
training-data recall, which may be stale or describe Tcl 8.x.

Strongly avoid PowerShell and Windows cmd for z-backed work. Use `z <tool>`,
`z bash -c "..."`, or named commands in `z.json`; do not add durable `.ps1`,
`.bat`, or `.cmd` glue.
<!-- DRENN-CLAUDE-BEGIN -->
## Drenn Project Memory

This project has Drenn configured in `.mcp.json` as a project-local MCP server. For substantial work, use Drenn as durable project memory: start by calling `drenn_info`, inspect existing memory programs with `list_programs`, and call `get_program` before running an unfamiliar durable program. Run or create Lua memory programs when they would help future agents.

Use `run_lua` for quick volatile one-call tools. Use `install_program` and `run_program` for memory behavior that should survive across Claude Code sessions. Before finishing significant work, preserve durable project facts, decisions, and useful observations in Drenn when a suitable memory program exists or when creating one is worthwhile.

Do not store secrets, credentials, private tokens, or unrelated personal data in Drenn. Treat the Tcl/Tk observer as read-only.
<!-- DRENN-CLAUDE-END -->
