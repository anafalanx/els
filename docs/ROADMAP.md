# els roadmap

Decided-but-not-yet-built work, nearest target first. Anything still being argued
about belongs in a study under `docs/`, not here.

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
