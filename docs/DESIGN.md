# els: design

> A calm grey page, generously leaded, with one red flourish. Chrome that
> defers to the text. Quiet until summoned, instant when used. Opinionated to
> the point of having no knobs: the absence of settings *is* the design.

els is a tiny, professional, no-frills text editor. This document records the
design language and the reasoning behind it, drawn from a study of editors that
get *calm* right (EditPad Pro, Sublime Text, Zed, Nova, iA Writer) and adapted to
what Tk 9 can actually render well.

## Principles

1. **The text plane is sacred.** Nothing covers the page. Find/replace is a
   docked strip that *pushes* the text, never a modal dialog over it. This is
   the choice Sublime and EditPad Pro independently converged on, the *pro*
   decision, not a budget one.
2. **Separation by tone, not borders.** Panes, gutter and active line differ
   from the page by a few percent of lightness, with at most a 1px hairline.
   Hard borders everywhere read as amateur.
3. **One accent.** A single saturated red (`#DC322F`): the caret, and the awl
   icon's blade. Everything else is greyscale; find matches are a calm amber.
   Two or three accents read cluttered. Red is a scalpel: caret only, never
   body text or fills on text.
4. **Calm is restraint plus speed.** A steady caret, no animation, instant
   scroll. The feeling of a good editor "disappearing" is latency, not
   decoration.
5. **Few knobs.** Settings should earn their place. Keep colour, font, and caret
   choices out of the core UI unless they clearly serve everyday editing.

## The look

### Palette

| role | value | note |
|------|-------|------|
| page | `#F2F2F2` | off-white; pure `#FFF` glares (halation) |
| ink | `#1A1A1A` | near-black; ~15.8:1 on the page, crisp but not harsh |
| accent (caret, icon) | `#DC322F` | the one red flourish |
| current line | `#EAEAEA` | a whisper of wash, not a band |
| gutter | `#ECECEC` | a tonal step off the page |
| line numbers | `#8C8C8C` | quiet, deferential |
| chrome text | `#6B7177` | muted slate |
| chrome panels | `#E9E9E9` | flat status / find bar |
| hairline | `#D4D4D4` | 1px separators |
| selection | `#D6E2F2` | a calm cool tint, not vivid blue |
| find: all | `#FFF1C4` | soft amber |
| find: current | `#FFD66B` | stronger amber |

### Typography & space

- **Font:** Consolas 11pt for the document (the one monospace hand-hinted for
  Windows ClearType that ships on every machine; zero-install matters for a
  single-file app), Segoe UI 9pt for chrome. Fonts are sized in
  **points** so they scale correctly on HiDPI.
- **Leading ≈ 1.34×** is the single biggest "calm" lever. Applied via the Text
  widget's `-spacing1`/`-spacing3`, computed as `int(linespace × 0.17)` so it
  tracks DPI. The gutter mirrors it so line numbers stay aligned.
- **Text inset:** `-padx 10.5p` (14px at 100% DPI) so glyphs never touch the frame; in
  points so it scales with the display like the font.
- **Spacing grid:** chrome paddings follow a ~4px quantum.

### The caret

A **steady** red bar (`-insertwidth 3p -insertofftime 0` — 4px at 100% DPI, scaling
with the display so it keeps its weight on HiDPI screens). A blinking cursor
pulls the eye; a solid red caret is calmer *and* more distinctive.
It is els's signature.

### Screen-reader limitation

Tk draws its own text surface and exposes no UI Automation provider, so Windows
screen readers (Narrator, NVDA, JAWS) cannot read or navigate document text.
els does not add an assistive-technology layer; the user-facing limitation is
stated plainly in the README's *Requirements & limitations*.

### Right-to-left text

The same Tk Text engine performs no Unicode bidirectional reordering, so right-to-left
and mixed-direction runs (Arabic, Hebrew) display in logical rather than visual order,
and caret motion through them is confusing. Real bidi would mean reimplementing the
Unicode BiDi algorithm on top of Tk — out of scope — so this is disclosed as an
inherited limitation, like the screen-reader one, rather than fixed.

### Fixed palette; no OS theme following

els renders one hand-tuned light identity and does **not** track the Windows dark-mode
setting or a High-Contrast theme. This is a decided non-goal, following from "no
configurable colour" and the single-visual-identity principle, not an oversight. The
default palette is near-black on light grey (~15.8:1 contrast, past WCAG AAA), so most
low-vision needs are met by default; users who require a specific high-contrast scheme
are not served, and a permanently light editor amid dark-mode apps is an accepted cost.

### Platform floor

64-bit Windows 10 (1903+) / 11. els relies on the per-app UTF-8 code page (1903)
for non-ASCII paths and long-path awareness (1607); the manifest lists 7/8.1 for
compatibility but they are untested. See the README for the user-facing version.

### Chrome

The native Windows `vista` ttk theme cannot be recoloured or flattened, so the
chrome is based on **`clam`** with custom flat, borderless styles
(`els::init_style`): flat entries with a hairline border and an ink insert caret
(red is reserved for the document); flat buttons; find toggles as grey "on" chips
(neutral, since red stays the caret's); slate text; a hairline above the status
bar and below the find bar. The vertical **scrollbar is a traditional arrowed bar
(clam's default layout), and auto-hides when the document fits**. Chrome appears
only when needed.

## Find & replace

A docked bar (Ctrl+F / Ctrl+H), the lessons distilled from EditPad Pro
(*restraint plus polish*):

- **Incremental** highlight of the first 5,000 matches with an exact global
  `N of M` disk-backed index (hard ceiling: 1,000,000); Enter / Shift+Enter can
  navigate beyond the display cap and wraps only when the global index is complete.
  Zero-width matches are indexed and navigated with Tcl `regsub -all` progress
  semantics, so anchors and lookarounds terminate predictably.
- **Inline, never popup.** No-match, bad-pattern and wrap-around show as text in
  the count label, never a dialog.
- **Match Case / Whole Word / Regex** toggles (Tcl ARE), plus **Adapt case**:
  the replacement follows each match's case (`cat→dog`, `CAT→DOG`, `Cat→Dog`).
- **Regex reference:** a `?` button opens a compact
  Tcl ARE cheat-sheet: a static reference, not a builder or debugger (even
  Goyvaerts kept the heavy regex tooling in a separate program).
- **Backreferences** (`\1`, `\2`) expand in the replacement.
- **History:** Enter records the term; Up/Down recall it.
- **Tooltips** explain the terse toggles.
- **Isolation:** the UI interpreter never evaluates a user regex. It writes an
  immutable UTF-8 snapshot, then starts the same source script or fused executable
  as a disposable worker. A native Windows Job Object is assigned atomically at
  process creation, before the initial thread runs; only then can a tokenized `go`
  file authorize work. While Replace All is running its button reads **Cancel**;
  cancellation, parent death, timeout or editor exit kills the whole job. Search
  or replacement work made stale by an edit, tab switch, query change or close is
  discarded. Replacement output is staged against the immutable source, verified
  in full and committed atomically as one undo unit only if the document epoch and
  complete request signature still match. Cancellation or any failure leaves the
  document and undo stack untouched.
- **Scratch containment:** `.els-find` is always beside `els.conf`; root, job,
  snapshot, control, result, and cleanup paths reject links, junctions, and other
  reparse points, use exact leaf schemas, and fail closed on races they observe.
  An actively malicious process running as the same Windows user can still swap a
  checked path before a later path-based open/delete; defending that adversary
  requires handle-relative `FILE_FLAG_OPEN_REPARSE_POINT` APIs throughout and is
  explicitly outside the current local-desktop threat model.

## Documents and tabs

Tabs are identifiers, not merely filenames:

- Untitled documents are numbered in their document order.
- Duplicate basenames grow only the shortest parent suffix needed to distinguish
  them. Middle elision preserves both that discriminator and the filename; if two
  labels still collide under the character/pixel cap, a stable short document
  discriminator is added.
- Compact leading marks carry state without consuming the identity: `•` dirty and
  `�` text that acquired replacement characters while decoding.
  Full paths and warnings remain available in the tab tooltip.
- The layout always keeps the active tab and its close button visible. It packs a
  contiguous neighbourhood into the remaining width; the right-hand overflow
  button (▾, also `Ctrl+T`) pops a switcher listing every document. There is no
  menu-bar Tabs entry: the switcher lives on the strip where overflow happens,
  and `Ctrl+T` / `Ctrl+Tab` cover the keyboard.

## Large files and disk state

An interactive open or reload asks before reading more than 40 MiB, and REFUSES a
file too large to load safely (`els::open_would_oom`): an absolute **1 GiB hard
cap** — no text file that big survives a synchronous load into the Tk text widget
on *any* machine (a single huge line alone crashes it), and it needs no RAM query
so the refuse is never blind — plus, when the native `win_meminfo` is available, a
RAM-relative check that refuses smaller files whose projected peak wouldn't fit in
available physical memory. A crash-prevention net, not a slowness warning; the
native helper is loaded at startup (not lazily on first Find) so both paths work
from the first open. Quiet paths (startup arguments and session
restore) may not make that memory decision or display a timer-driven prompt, so a
large or network file opens as a **placeholder tab** — a real tab whose content
is not loaded (`docLazy`, buffer `-state disabled`) — materialized on the user's
first click through the same interactive guard. This reads zero bytes at startup,
so an offline share cannot block Tk's only event thread before the UI is usable —
both a UNC path (recognised lexically) and a **mapped network drive** (`Z:`,
recognised via `GetDriveType`, which reads the local mount table without
contacting the server) route to a placeholder.
Removable and optical drives stay locally observable: they fail fast when absent,
so they carry no SMB-style reconnect stall to guard against.

Undo is bounded by an action *count* (`-maxundo 2000`), not by bytes: Tk 9 offers no
byte-bounded undo, so a single huge action can retain a correspondingly large record. A
Replace All is bounded to a 256 MiB snapshot (`FIND_OUTPUT_MAX`); a large paste is
bounded only by the clipboard's own size, not by a fixed els cap. Typical keystroke
editing is bounded by the count; one giant edit is bounded only by that action's size.

The active-document status item has six user-facing states: **Not on disk**,
**On disk**, **Changed on disk**, **Missing**, **Unavailable**, and **Read-only**.
It is deliberately an early-warning observer. It may update one quiet label, but
never reloads or writes, never changes auto-save policy, and never asks a question.
Automatic observation performs no I/O on a network path — a UNC path or a mapped
network drive — so a disconnected share never stalls the event thread; such a
document reads as **Unavailable** until an explicit open, save, or reload checks
it. Every manual
or automatic save independently performs the authoritative full conflict check
before replacing a target, so the label is never treated as permission to write.

## Adjacent state

There is one state root: beside `els.exe` when packaged, beside `els.tcl` in a
source run. `els.conf`, `backups\`, `els.log`/`els.log.1`, and
transient `.els-find\` all live there. (0.95 removed crash recovery and the
single-instance handoff, so there are no `swap\`/`handoff\` dirs; a boot-time
sweep reaps either left behind by a pre-0.95 install.) No user-profile
path is a fallback, migration source or deletion target. The sole compatibility
case is an adjacent `config.tcl`: when `els.conf` is absent, it is copied once to
the new name and retained. Corrupt deferred-open state is quarantined rather than
silently rewritten when that preservation is possible.

## About and credits

The About dialog remains compact, but it names the foundations that make the
single executable possible: Tcl/Tk 9, MinGW-w64, GCC, zlib and LibTomMath, followed
by thanks to their maintainers and communities. It does not attempt to reproduce
license text. The complete MIT and third-party notices are embedded in every
released executable as `LICENSE.txt` and `THIRD-PARTY-NOTICES.txt`.

## Non-goals

Written down so they stay decided:

- No settings/preferences UI (no configurable colour, font, or caret).
- No syntax highlighting.
- No rounded corners, drop shadows, smooth/inertial scrolling, or animation:
  Tk renders these poorly; it looks professional staying flat.
- No minimap.
- No regex debugger, token-builder, or named-search manager: over-scoped.
- No modal find/replace dialog.
- **No extension API.** Buffer scripts (below) are deliberately NOT a plugin system:
  a script is a sandboxed text filter — no UI hooks, no event hooks, no access to
  anything but the text it is given. The API surface is four variables and a return
  value, chosen so it can stay stable forever. (History: scripting was originally
  declined outright, 2026-07-05, in favour of fixed built-ins; sustained real-world
  use showed the fixed set genuinely wasn't enough, and the filter contract keeps
  the original objections — knob explosion, security surface, API creep — answered.)
- **No tab-width setting**, so no Tabs↔Spaces conversion (which needs one). Indent inserts
  a literal tab; dedent removes one leading tab (or up to four leading spaces).

## Text commands

The caret/keyboard line ops are built in (Buffer menu + keys), each undo-atomic, acting
on the selected lines or the current line: Move Up/Down (Alt+↑/↓), Duplicate (Ctrl+D),
Delete (Ctrl+Shift+K), Join (Ctrl+J), Indent/Dedent (Tab/Shift+Tab on a selection).

The pure text transforms ship as **buffer scripts** instead — see below. Deliberately
excluded to keep the built-in set tight: Title Case (fiddly), Tabs↔Spaces (needs a
width knob).

## Buffer scripts

A buffer script is a Tcl **text filter**: a `*.tcl` file in `scripts\` next to
`els.conf`, listed in the Buffer menu by its file name. It runs in a **safe
interpreter** (Tcl's `-safe` base: no file, exec, network, or env access) with a hard
time limit, receives `$text` (the selection, else the whole buffer) plus
`$hasSelection` / `$path` / `$lineCount`, and whatever it returns replaces that text
as one undo step. An error or timeout is one status note; the buffer is never touched
on error — a script can at worst mangle text, and undo covers that.

The classic transforms (Sort, Sort Descending, Reverse, Remove Duplicate Lines,
UPPERCASE, lowercase, Trim Trailing Whitespace) are **seeded as default scripts** —
working examples that double as the contract's documentation. Seeding happens once
(when `scripts\` doesn't exist), so deleting a default is respected; **Buffer ▸
Restore Default Scripts** rewrites the pristine set on request, leaving other files
alone. **New Script…** names a file through the standard save dialog, seeds the
contract template, and opens it for editing — in els, naturally.

## Sources

The study behind this design:

- Sublime Text: *Anatomy of a Next Generation Text Editor*
  <https://www.sublimetext.com/blog/articles/anatomy-of-a-next-generation-text-editor>
- Zed: visual customization & philosophy <https://zed.dev/docs/visual-customization>
- Nova (Panic) review: <https://www.macstories.net/reviews/nova-review-panics-code-editor-demonstrates-why-mac-like-design-matters/>
- EditPad Pro search / regex: <https://www.editpadpro.com/search.html>,
  <https://www.regular-expressions.info/editpadpro.html>
- iA Writer: responsive typography <https://ia.net/topics/responsive-typography-the-basics>
- Tk theming: `clam`, `ttk::style`; awthemes <https://github.com/bll123/tcl-awthemes>
