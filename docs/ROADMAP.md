# els roadmap

Decided-but-not-yet-built work, nearest target first. Anything still being argued
about belongs in a study under `docs/`, not here.

## Decided against — do not re-open

### Replacing Tk's text widget (Scintilla, or a custom Direct2D component)

**Decision (2026-07-20): els keeps Tk's text widget and accepts its limits.** The
long-line refusal (≥ 50,000 chars), the 40 MB open warning and the 1 GiB hard refuse
stay. They are honest, they are tested, and they are cheap to maintain.

This was studied properly before deciding — see `docs/scintilla-feasibility-study.md`,
which includes benchmarks from an actual Scintilla 5.6.4 build against els's own
toolchain. Summary of why the answer is no:

- **It only partly works.** On the document shape that actually motivates it — files
  made *of* long lines, not one long line among short ones — Scintilla gives roughly
  5 fps scrolling and 9–11× the file size in RAM. A huge improvement on Tk's 375 s
  freeze, but not a solved problem.
- **The real blocker is testability, and it is permanent.** The suite drives real Tk
  widgets in-process; a hosted Scintilla (or custom D2D) control is a foreign HWND
  that `event generate` cannot reach, and its idle deferrals sit outside the
  cancel-every-pending-`after` invariant in `tests/helpers.tcl` that makes the suite
  deterministic. That is not a porting cost, it is a standing one.
- **A hand-written D2D viewer is not the cheap middle path it looks like.** It needs
  mostly *rendering* correctness — font fallback, grapheme clusters, bidi, UTF-8 ↔
  UTF-16 index duality — which is exactly the part you do not get for free, and it
  inherits the same foreign-HWND testing problem.

If this is ever reconsidered, the honest headline is **accessibility**, not long
lines: a custom-drawn surface forecloses screen-reader support permanently, whereas
today's gap is at least fixable in principle. Reconsider only as a 2.0, and only with
that trade stated out loud.

## 1.1

### Chunked file reading with a progress indicator

**What.** Read a file in chunks, yielding to the event loop between them, and show
progress in the status bar while a large open is in flight.

**Why.** A large open currently blocks the UI for the whole read + decode + insert.
Measured on this machine: a 25 MB file takes ~4.4 s end to end, and the 40 MB open
warning exists precisely because ~5 s is where Windows starts ghosting the window as
"(Not Responding)". Chunking keeps the window alive and lets the status bar say what
is happening, instead of presenting a frozen editor.

**Where.** The reader is the seam: `els::read_binary_guarded` and its
`_read_binary_prefix` / `_read_binary_channel` helpers. The applier
(`els::install_content` → `els::apply_decoded`) must stay exactly as it is — the
single UI-thread choke point every load path already funnels through. The long-line
gate (`els::longline_gate`) runs on the assembled bytes and is unaffected.

**Deliberately NOT an off-process async loader.** Considered and declined:

- The read is not the expensive part. Decode + insert into Tk's B-tree dominates, and
  that cannot leave the UI thread — so moving only the I/O off-thread barely dents the
  freeze for local files.
- Piping tens of MB back from a child process adds a copy and can be slower end to end.
- It introduces a stale/superseded-callback class of bug: applying old bytes over a
  document the user has since edited, reloaded, or closed. That is a data-loss risk for
  an editor whose entire claim is never losing text you have saved.

Revisit a true async loader only if editing over the network becomes a real workflow;
until then remote paths are already neutralised by placeholder tabs, which never touch
a share during quiet work.

**Done when.** A 40 MB open leaves the window responsive with visible progress, the
test suite stays deterministic (no new flakiness), and `apply_decoded` is untouched.
