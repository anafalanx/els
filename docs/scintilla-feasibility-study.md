# Feasibility Study: Integrating Scintilla into els

**Prepared for:** the author of els
**Date:** 2026-07-20 (rev. 2 — revised under adversarial review)
**Subject:** replacing or supplementing Tk's text widget with Scintilla, to remove the 50,000-char long-line refusal and the 40 MB / 1 GiB file-size limits
**Basis:** five parallel investigations (Scintilla externals with original benchmarks; els↔Tk coupling inventory; test-suite blast radius; build/toolchain/release-gate analysis; product identity and alternatives), then three adversarial reviews — one of which rebuilt Scintilla 5.6.4 against els's toolchain and wrote new benchmarks. **Rev. 2 changes the crux magnitude, resolves the study's own #1 risk, and reverses the build recommendation.**

**Confidence convention:** claims are tagged **[High]** (directly measured here, or read from source and reproduced), **[Med]** (measured once, or inferred from source with a plausible mechanism), **[Low]** (reasoned, not measured). Untagged text is argument, not evidence.

---

## VERDICT

Three questions come apart, and the answer differs for each.

### 1. Is it feasible?

**Yes, unambiguously.** Every technical precondition checks out under direct measurement, and an adversarial rebuild reproduced the load-bearing ones independently. **[High]**

- Scintilla 5.6.4 (6 July 2026, ~6–9 releases/year for 25 years), HPND — static linking into a closed-source signed exe carries no obligation beyond a notice line.
- It builds clean with els's own unmodified UCRT64 mingw-w64 toolchain (g++ 16.1.0). Verified twice, independently.
- It links statically into a single exe via `Scintilla_RegisterClasses`. Verified by building such an exe, twice.
- Static-link imports stay inside `pecheck.tcl`'s existing allowlist (KERNEL32, `api-ms-win-crt-*`, user32/gdi32/imm32/ole32/oleaut32/advapi32). Verified against `tools/pecheck.tcl:82`.
- One function pointer (`SCI_GETDIRECTFUNCTION`) drives everything, so the Tcl binding is structurally like els's existing `winfs.c` / `elsx.c` shims.
- Lexilla is a separate library; els's "no syntax highlighting" is satisfied by *omission*.

No showstopper exists. Feasibility was never the hard question.

### 2. Does Scintilla actually fix the problem? — **downgraded from rev. 1**

**Partly. Rev. 1 said "solved, decisively, four orders of magnitude." That was measured on the wrong document shape and the claim does not survive.**

The original benchmark built a document of 40 short lines + **one** 266k-char line + 40 short lines. Every headline number describes *an isolated long line surrounded by short ones*. The motivating file class — minified bundles, sourcemap-free webpack output, SQL dumps — is **mostly** long lines. A new benchmark (100 lines × 266k chars, 25 MB, otherwise identical settings) gives **[High]**:

| | vscroll mean | hscroll mean | working set (25 MB doc) |
|---|---:|---:|---:|
| DirectWrite / PAGE | **196 ms** | 181 ms | 274 MB (~11×) |
| GDI / PAGE | **208 ms** | 165 ms | 226 MB (~9×) |
| DirectWrite / CARET | 1818 ms | 1951 ms | 138 MB |
| GDI / CARET | 1410 ms | 1448 ms | 95 MB |

That is ~5 fps and ~9–11× file size in RAM — not 16 ms and not 1.14–1.52×. **The honest claim is: solved for isolated long lines; usable-but-janky and memory-hungry for files made of long lines.** Against Tk's 375 s it is still an enormous win, but "decisively solved" was wrong and is withdrawn.

Offsetting this, the study's own **#1 ranked risk is resolved in Scintilla's favour: word wrap is linear, not quadratic** (§1.2). And **word wrap defaults to off** in els (`els.tcl:570`), so the risk was over-weighted even before it was measured away.

### 3. Is it advisable?

**Full replacement (Option A): no — not as an increment to 1.x.** The reason is unchanged and survived all three reviews: els sells a data-safety promise, and the mechanism that keeps it is a 715-test white-box suite that drives real Tk widgets in-process with `event generate`. A hosted Scintilla control is a foreign HWND; `event generate` cannot reach it. A stronger version of the same argument emerged under review: the suite's real determinism mechanism is `els_reset`'s **cancel-every-pending-`after`** sweep (`tests/helpers.tcl:204`, `foreach a [after info] { catch {after cancel $a} }`), and a component with deferrals els cannot enumerate — Scintilla's idle wrap and idle styling — sits outside that invariant *permanently*, not just during the port. **[High]**

**Dual engine (Option B): no, and it remains the worst option.** All of A's cost plus permanent duplication of every feature, two save paths against the one guarantee that must never break, and a hidden mode in a product whose proposition is one hand-tuned feel with no knobs.

**Custom D2D editor from scratch (Option D): no.** Unchanged, and now better supported: see C1's fate below, which is D arriving by increments.

**Hand-written D2D read-only viewer (Option C1): no — reversed from rev. 1.** Rev. 1 recommended this. It was wrong, on four independent grounds that all three reviews found separately:

1. Its justifying claim was false. Rev. 1 argued "the correctness Scintilla contributes is overwhelmingly *editing* correctness, and a viewer needs none of it." A viewer needs almost entirely *rendering* correctness: chunked measurement, run breaking that respects script/style boundaries, `IDWriteFontFallback` (which you lose the moment you stop handing whole strings to `IDWriteTextLayout`), grapheme-cluster boundaries for hit-testing and selection, bidi, and a UTF-8↔UTF-16 index duality els does not currently have. That is exactly the "correctness inherited: none" row, and it inverts the C1-vs-C2 table.
2. The new many-long-lines measurement adds a requirement rev. 1 never budgeted: a **viewport-bounded layout cache with an eviction policy** — the thing Scintilla itself handles only adequately. **[High]**
3. C1 is a foreign HWND too. The `event generate` argument used to kill A applies to it unchanged; rev. 1 gave it a pass ("the testable surface is pure functions") that tests the arithmetic and abandons the widget.
4. For a solo maintainer the maintenance comparison was **inverted**. Scintilla's treadmill is *elective* — statically linked, no Lexilla, no network, 5.6.4 can sit frozen for years. Hand-written D2D layout is a *non-elective, bus-factor-1, no-upstream, no-test-harness* obligation for the life of the project.

Realistic size for C1 is **3,000–5,000 lines of C23 with manual COM vtable dispatch, not 800–1,500** **[Med]** — which trips rev. 1's own abandon-ceiling before the viewer draws a selection. The tripwire fired; rev. 1 did not notice.

**Do nothing (Option E): defensible, and stronger than rev. 1 credited.** The refusals are *honest*, which is rare. But an unopenable `.min.js` or one-line JSON blob is a real gap — **of unmeasured frequency**, which rev. 1 asserted and never established.

---

## THE RECOMMENDATION

> **Ship the cheap, honest, in-engine work now. Do not build a second renderer on present evidence. If a viewer is ever built, it is C2 (stripped Scintilla), not C1. Reconsider A only as els 2.0 — and if that conversation happens, its headline is accessibility, not long lines.**

In order:

0. **Ask the usage question first** — *do you actually want to **edit** these files, or only read them?* Free, and the highest-information action in this document. Rev. 1 buried it at step 4; every downstream choice presupposes its answer.
1. **Re-measure `LONGLINE_CHARS` on Tk 9.0.4 and set it from data.** Half a day, unconditional, zero risk. The constant at `els.tcl:571` encodes a ~2.3 s measurement from an older toolchain and should not be an inheritance. **[High confidence in the estimate.]**
2. **Measure decode time vs. insert time on a large open.** One hour. `docs/ROADMAP.md:27` asserts "Decode + insert into Tk's B-tree dominates" but nobody has split the two. If *insert* is the larger half, Scintilla's gap buffer fixes more than this study credits and the chunked reader fixes less — because chunking preserves responsiveness without reducing total time. **This one measurement can reorder everything below it, and it is not in any prior confidence register.**
3. **Replace the refusal with an honest read-only elided view** (§4, E+ item 2, rewritten). Rev. 1's hard-break-injection version is **withdrawn** — it was the least honest and most data-integrity-exposed item in the plan, and it was scheduled first, unconditionally.
4. **Finish the chunked reader** already scoped in `docs/ROADMAP.md`. It addresses files opened *routinely*; Scintilla does not fix it, because the decode stays els's Tcl either way.
5. **Then re-ask what residual problem survives.** Plausibly: "you still cannot horizontally scroll a genuine 266k-char line, and you still cannot open >1 GiB." Only with usage evidence in hand does a second renderer become arguable — and then as C2.

**Deferred, not cancelled:** the Tk-hosting spike (rev. 1's 4a). It informs an els-2.0 conversation that is not on the table at 0.99, it now costs **8–12 days, not two** (§3.2), and nothing in steps 0–5 depends on it.

**One correction to the framing that motivated this study, retained from rev. 1 because it held up:** the Direct2D clock does not prove what it appears to prove. A clock face is output-only — no focus, no keyboard, no IME, no selection, no clipboard, no drag-drop, no test harness. It proves a D2D surface can render inside a Tk window. It says nothing about a component that must *own input*, and that is where this decision turns.

---

## 1. THE CRUX — how much does Scintilla actually fix?

**Measurement setup (both rounds):** Scintilla 5.6.4 built with `C:\dev\.z\r\msys2\ucrt64\bin\g++` at `-O3 -std=c++17`, statically linked into a bare Win32 host, 1580×940, Consolas 11, UTF-8, null lexer, undo off. Each "frame" is a forced full-window synchronous repaint (`InvalidateRect(NULL, TRUE)` + `UpdateWindow`) — harsher than Scintilla's normal partial invalidation. Sources under `…\scratchpad\sizetest\` (`bench.cxx`, `bigbench.cxx`, and the adversarial additions `manylines.cxx`, `mlwrap.cxx`, `wrapbench.cxx`).

Two ways the benchmark could have flattered Scintilla were checked and ruled out **[High]**: `PositionCache` only caches strings under 30 chars (`PositionCache.cxx:1105`), so the repeating 43-byte test pattern did not inflate results; and `checkMonospaced` defaults to `false` (`Style.h:22`), so the monospace-ASCII arithmetic fast path was *not* taken. Real measurement occurred. (Both were luck rather than design. Note the corollary: calling `SCI_STYLESETCHECKMONOSPACED` on els's Consolas would engage that fast path — an unexploited speedup no prior round considered.)

### 1.1 Long lines — solved when isolated, merely improved when they are the whole file

**Isolated long line** (one long line among short ones), horizontal scroll **[High]**:

| Line length | Technology | Layout cache | hscroll mean | hscroll worst |
|---:|---|---|---:|---:|
| 200 (baseline) | DirectWrite | PAGE | 16.1 ms | 19.0 ms |
| **266,000** | DirectWrite | PAGE | **16.2 ms** | 17.6 ms |
| 1,000,000 | DirectWrite | PAGE | 16.4 ms | 20.4 ms |
| 200 (baseline) | GDI | PAGE | 3.0 ms | 11.5 ms |
| **266,000** | GDI | PAGE | **6.3 ms** | 9.7 ms |
| 500,000 | GDI | PAGE | 9.8 ms | 16.1 ms |
| 266,000 | DirectWrite | **CARET (default)** | 58.6 ms | 105 ms |
| 266,000 | GDI | **CARET (default)** | 37.0 ms | 55 ms |

Against els's measured Tk curve — 0.4 s @ 20k, 2.3 s @ 50k, 9.4 s @ 100k, 37 s @ 200k, **375 s @ 266k, quadratic** — that is 16 ms versus 375 seconds.

**Many long lines** (100 × 266k, 25 MB) — the shape of an actual minified bundle **[High]**: 196 ms/frame DirectWrite, 208 ms GDI, 274/226 MB working set. See the VERDICT table.

**Two caveats on the harness, in both directions, so the number is not over- or under-read:**
- The forced full-window repaint is harsher than a real scroll, which invalidates partially. The 196 ms is therefore an **upper bound** **[Med]**.
- Conversely, whether those frames are *layout*-bound (cache eviction) or *draw*-bound is not separated. The memory figure strongly implies the cache is holding all visible lines and therefore not thrashing, which would make the cost drawing, not layout — and drawing cost does not fall with a better cache. **This is a one-hour follow-up that would sharpen the number; it does not change the direction.**

**Why the isolated case works** (read from 5.6.4 source **[High]**):

1. **Chunked measurement.** `EditView::LayoutLine` runs `BreakFinder`; `PositionCache.h` sets `lengthStartSubdivision = 300`, `lengthEachSubdivision = 100`. Runs over 300 chars are split into ~100-char pieces, each measured with one `IDWriteTextLayout`/GDI call. **Tk's exact failure mode — handing the whole 266k-char string to the measurement API on every scroll — is architecturally impossible.**
2. **Binary search to first visible char.** `BreakFinder`: `if (xStart > 0.0f) nextBreak = ll->FindBefore(xStart, lineRange);` over cached `positions[]`. Horizontal scroll does not walk from column 0. **Caveat [High]:** the benchmark's 200 × 400 px sweep covers ~79,600 px ≈ 10,900 columns — about **4%** of a 266k line and **1%** of a 1 M line. The mechanism is real in source but was never exercised at depth.
3. **`SC_CACHE_PAGE` is mandatory and is not the default** (`EditView.cxx:193` is `llc.SetLevel(LineCache::Caret)`). CARET allocates exactly one layout slot for all visible lines, so every repaint evicts and re-lays-out. **But it is not the "single call that is the difference between solved and not," as rev. 1 claimed.** `LineLayoutCache::AllocateForLevel` (`PositionCache.cxx:487–495`) sizes PAGE at `AlignUp(linesOnScreen + 1, 20)` **full-line** layouts; at ~10 bytes/char that is 60 × 266k × 10 ≈ 160 MB, which matches the measured working-set delta. **PAGE converts re-layout thrash into a memory multiplier. It does not make many long lines fast.** This is the direct refutation of rev. 1's §1.3 gap #4, which had guessed the opposite from source reading.

**The "Scintilla truncates lines at 4000 chars" claim is stale folklore.** `LineLayout::Resize` in 5.6.4 self-extends. Real limits: ~2³¹ chars per line (`int` counters), and ~10 bytes/char to lay one out.

**Isolated-line scaling to absurdity** (DirectWrite, PAGE) **[High]**: 1 M chars → 16.4 ms; 5 M → 68 ms; 20 M → 133 ms; 50 M → 351 ms. Tk extrapolated on its quadratic curve would be in the tens of hours.

**Editing inside a long line is O(line length) per keystroke** **[High]** — unchanged and still the honest weak spot:

| Line length | ms/keystroke (DirectWrite) | ms/keystroke (GDI) |
|---:|---:|---:|
| 200 | — | 5.3 |
| 266,000 | 33.3 | — |
| 500,000 | 64.2 | 53.2 |
| 1,000,000 | 69.0 | — |

Upper bounds — the harness forces a full repaint per keystroke. **Reading a 266k-char line is solved; editing one is tolerable.** That split is what made a read-only viewer attractive in rev. 1, and it is still true; what changed is that building the viewer by hand is not cheap.

Also absent from every table: `firstPaint`, the uncached full-line layout, **13 ms at 266k** **[High]**. The 16 ms figure is 200 repaints reusing one cached layout. That is legitimate for a scroll benchmark, but the layout cost is what a viewer pays on open and on every eviction — and eviction is the many-lines case.

### 1.2 Word wrap — **resolved, and it favours Scintilla**

Rev. 1 ranked this its **#1 risk** and could not measure it: `bench.cxx`'s `pump()` is a bare `PeekMessage` drain that never idles, so Scintilla's deferred wrap pass never fired, and the wrap runs silently produced no-wrap numbers. Rev. 1 therefore left Notepad++ #13423's roughly-quadratic curve (524k → ~9 s, 1 M → ~44 s) standing unrefuted.

`wrapbench.cxx` fixes the pump (`PeekMessage` + `Sleep(1)`) and confirms wrap actually executed — `SCI_WRAPCOUNT` returned 1547 / 3048 / 5814 rows for 266k / 524k / 1 M **[High]**:

| line length | toggle-wrap cost | post-wrap vscroll |
|---:|---:|---:|
| 266,000 | 0.067 s | 15.8 ms |
| 524,288 | 0.132 s | 15.8 ms |
| 1,000,000 | 0.162 s | 15.7 ms |

**Linear.** The Notepad++ curve does not reproduce in 5.6.4 with `SC_CACHE_PAGE`. Rev. 1's risk #1 and its condition #5 both resolve in Scintilla's favour, and the wrap spike is **done** — delete it from the plan.

Tie-back to §1.1: with 100 long lines the wrap pass costs **5.1 s as a one-time freeze** (≈50 ms per 266k line — still linear), after which scrolling is 15.7 ms. So on a real minified bundle the choice is a multi-second freeze on open (wrap on) or ~200 ms frames forever (wrap off). Neither is quadratic; neither appeared in rev. 1.

**And rev. 1 over-weighted this risk before any of it was measured:** `els.tcl:570` sets `word_wrap 0`. Wrap is a shipped View toggle that is **off by default**. **[High]**

### 1.3 Large files — genuinely strong, on short-line files only

Storage is a **gap buffer** (`CellBuffer` over `SplitVector<char>`), fully in RAM. Two document options dominate: `SC_DOCUMENTOPTION_STYLES_NONE` (drops the style array — pure waste for els) and `SC_DOCUMENTOPTION_TEXT_LARGE` (>2 GB on 64-bit). **[High]**

| Size | Options | Load | WS delta | ×file | Goto end | Scroll/line | Insert mid-doc | Search whole |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 100 MB | DEFAULT | 0.16 s | 251 MB | 2.51× | 33 ms | 16.7 ms | 93 ms | 0.40 s |
| 100 MB | STYLES_NONE+LARGE | 0.22 s | 152 MB | **1.52×** | 33 ms | 16.7 ms | 57 ms | 0.50 s |
| 500 MB | STYLES_NONE+LARGE | 0.96 s | 600 MB | **1.20×** | 33 ms | 16.7 ms | 237 ms | 1.78 s |
| 1024 MB | STYLES_NONE+LARGE | 1.77 s | 1188 MB | **1.16×** | 33 ms | 16.7 ms | 650 ms | 4.52 s |
| **2500 MB** | STYLES_NONE+LARGE | 4.69 s | 2856 MB | **1.14×** | 33 ms | 16.7 ms | 1796 ms | 10.4 s |
| 2500 MB | STYLES_NONE only | — | — | — | — | — | — | `SCI_CREATEDOCUMENT` → 0 (clean fail) |

**Scope correction, and it is important:** `bigbench.cxx:83` generates **64-byte lines** — its own comment says `// 64-byte lines, like a log file.` Every row above is a **short-line** file. §1.1 is a **single-long-line** file. **Nothing measured is both large and long-lined — which is precisely a 50 MB minified bundle.** The 25 MB multi-long-line run shows the multipliers do not compose (9–11× RAM, not 1.14×). **[High]**

Findings that survive that correction, scoped to short-line files:

- **A 2.5 GB document works**, scrolling at the vsync cap, at 1.14× file size in RAM. The widely-repeated "Scintilla is limited to 2 GB" claim is false.
- **The 2–4× memory multiplier is a choice, not a law.** DEFAULT reproduces it (2.1–2.5×); `STYLES_NONE` drops it to 1.14–1.52×. Notepad++ pays 2–4× *because it lexes*. **Rev. 1 called this "the single most under-appreciated point in the whole analysis." Demoted: it is true for log files and false for bundles.**
- **Failure without `TEXT_LARGE` is clean** (returns 0), not a crash. els would always pass it on x64.
- **Gap-buffer distant-edit stall:** first insert far from the gap costs 0.24 s @ 500 MB, 0.65 s @ 1 GB, **1.8 s @ 2.5 GB**; subsequent nearby edits are cheap. One stall per jump, not a death spiral — but a blemish in a "calm" editor.
- **Whole-doc search is blocking and single-threaded:** 10.4 s across 2.5 GB (~250 MB/s). els would need cancel/progress.
- **`SCI_CREATELOADER`/`ILoader` allows background loading** off the UI thread. Never exercised here. **[Low]**

**Caveat on scope, sharpened:** els's 40 MB warning exists because of **read + decode + insert** in els's own Tcl, not rendering. `docs/ROADMAP.md:27` states "Decode + insert into Tk's B-tree dominates" — but **the two halves have never been separated**, and the answer matters in both directions. If decode dominates, the chunked reader is the right fix and Scintilla is irrelevant here. If *insert* dominates, Scintilla's gap buffer fixes more than this study credits, and the chunked reader fixes less than the roadmap implies — because chunking keeps the window alive without reducing total time. **One hour of work. Do it before step 4.**

### 1.4 Where the crux evidence is still weak

1. **Real disk I/O was never in the loop.** All large loads used in-memory `SCI_ADDTEXT`; `ILoader` was never exercised. els's actual large-file bottleneck was excluded from every measurement. **[Low confidence in any large-file end-to-end claim.]**
2. **Scintilla has never been hosted inside a Tk window.** The benchmark host was a plain Win32 parent. Message-loop interaction, focus, Tk's `DoOneEvent`/idle handling versus Scintilla's deferred wrapping and idle styling, DPI changes, IME window placement — all unexercised. Given the D2D-clock precedent this *should* work, but "should" is doing real work in that sentence, and the clock proved only output. **[Low]**
3. **The many-long-lines number is one run, on one machine, with a deliberately harsh repaint model.** Direction: certain. Magnitude: ±2×. **[Med]**
4. **Deep horizontal scrolling** (beyond ~4% into a long line) is unmeasured, so the binary-search mechanism is source-verified but not performance-verified. **[Med]**
5. Wine with D2D (extrapolated from adjacent projects; no Scintilla-specific bug found); screen readers other than NVDA.

**Crux verdict:** Scintilla improves els's long-line problem by a very large margin for isolated long lines, and by roughly 3 orders of magnitude — 200 ms rather than 375 s — for files composed of long lines, at ~10× RAM. It substantially improves large short-line files. It does not fix els's large-file bottleneck, which is els's own decode path. Word wrap, previously the largest evidentiary gap, is now measured and is linear.

---

## 2. WHAT IT COSTS

### 2.1 Coupling surface: 179 method call sites, 307 lines

Verified against `C:\dev\_els\els.tcl` (8,086 lines). **[High]**

| Category | Sites | Notes |
|---|---:|---|
| **Tags** | **55** | 23 `tag remove`, 10 `tag add`, 7 `tag ranges`, 7 `tag configure`, 7 `tag raise`, 1 `tag lower` |
| Indices | 35 | 29 `index`, 4 `compare`, 3 `count -chars`, 1 `search` |
| Content | 35 | 19 `get`, 8 `delete`, 5 `replace`, 4 `insert` |
| Display/view | 24 | 8 `see`, 5 `xview`, 4 `yview`, 4 `dlineinfo` |
| Editing/undo | 21 | 10 `edit modified`, 4 `edit separator`, 3 `edit reset` |
| Marks | 12 | all `mark set insert` |
| Bindings | ~40 | class bindings on the `elsText` bindtag, inserted at position 1 |

Widget-name indirection is centralised in four one-liners (`els::W`, `els::tabW`, `els::T`, `els::id_of`, 653–660). There is exactly **one** text-widget creation site (2188). A command proxy is **already** interposed on every document widget (`els::text_proxy_install`, 2149–2172).

**Things that get simpler or disappear outright:**

- `SCI_GETCHARACTERPOINTER` returns a zero-copy contiguous UTF-8 buffer → the ~70-line incremental find-snapshot slicer (6656–6725, 256 KB per idle turn) collapses to one write.
- Byte addressing over an already-UTF-8 document → the 8 `"1.0 + $N chars"` conversions in find vanish.
- `SCN_MODIFIED` delivers position+length natively → `els::text_proxy` (29 lines) deleted.
- Native `SC_MARGIN_NUMBER` → `els::draw_gutter` (3461–3517, 57 lines of `dlineinfo` alignment) deleted.
- `SCI_SETCARETLINEVISIBLE`/`CARETLINEBACK` → the `update_current_line` retag disappears.
- No phantom trailing line → `els::xform::lastdoc` (3196–3202) deleted.
- `SCI_BEGINUNDOACTION`/`ENDUNDOACTION` beats the `-autoseparators` bracket dance.

**Credit-accounting caveat:** ~156 lines of Tcl the author wrote and understands, traded for ~2,000 lines of C++ he did not write plus ~90k vendored. Rev. 1's §3 table presented this as an offsetting credit. It is not fungible and the table below no longer treats it as such.

**Things that need redesign, not translation:**

- **The 8-level tag z-order stack** (2213–2220: `currentLine < wsSpace < wsTab < wsTrail < findAll < findOne < focusDim < sel`). Six of seven are **background** tags. Scintilla gives **one background per character** plus fixed-order indicator overlays. Six overlapping backgrounds must become alpha-composited indicator boxes, which **will not reproduce the exact palette**. Least clean mapping in the port, and it lands on a stated identity pillar.
- **Whitespace tinting.** els draws three subdued background tints. `SCI_SETVIEWWS` draws dots and arrows in **one** colour. Rebuild with three indicators, scanned per-viewport, on every scroll and edit — now your code, on a hot path.
- **Pixel-granular vertical scrolling.** `els::touchpad_scroll` (3580) uses `$w yview scroll N **pixels**` (3587) so precision-touchpad panning matches the gutter (the "G-View mat-5" fix). **Scintilla scrolls vertically in whole lines only.** Unrecoverable regression.
- **Bounded undo.** `MAXUNDO 2000` (463, applied at 2188) has **no Scintilla equivalent** — only `SCI_EMPTYUNDOBUFFER`. Accept unbounded growth or drop the guarantee.
- **Drag & drop.** `els::drop_register` calls `RegisterDragDrop` on the text widget's HWND (2225, 4889–4892, `src/windrop.c`). Scintilla registers its own `IDropTarget`; a second registration fails `DRAGDROP_E_ALREADYREGISTERED`. `windrop.c` needs rework, not a recompile.
- **Key map ownership.** Scintilla's defaults collide with *different meanings*: `Ctrl+D` = `SCI_LINEDUPLICATE`, `Ctrl+T` = `SCI_LINETRANSPOSE` (els: tab switcher), `Ctrl+L` = `SCI_LINECUT`, `Ctrl+Y` = redo. Fix: `SCI_CLEARALLCMDKEYS` and re-assign from zero. A wash, tilting positive — it is more in keeping with "a decided tool."
- **Multiple/rectangular selection must be explicitly disabled.** All 19 `els::xform::*` procs assume one selection. Leaving multi-select on produces a *silently wrong* Sort or Move Lines.
- **Mark floating.** Tk marks float with edits; Scintilla byte positions do not. The invariant described at els.tcl:2147–2148 goes away.

**The largest structural cost, easy to miss:** els binds `elsText` at bindtag position 1, *ahead* of Tk's `Text` class, and then deliberately **falls through** for everything it does not override — caret motion, shift-selection, word-wise motion, Home/End, double/triple-click selection, autoscroll-on-drag, clipboard, IME composition. **That inheritance is a large part of why els is 8,000 lines instead of 20,000.** Scintilla supplies its own equivalents — good ones, but *different* ones, and every difference is a place where els's hand-tuned feel has to be re-decided by someone who first has to notice it.

### 2.2 Test suite: 346 of 715 tests (48%) in direct contact; ~375 (52%) take damage

The census is exact and was independently reconfirmed line by line. **[High]**

| File | Tests | TEXT (direct) | UI_DOC | UI_CHROME | PURE |
|---|---:|---:|---:|---:|---:|
| ui.test | 224 | **73** | 50 | 85 | 16 |
| els.test | 132 | **73** | 42 | 15 | 2 |
| find.test | 87 | **72** | 1 | 14 | 0 |
| encoding.test | 68 | **36** | 19 | 4 | 9 |
| units.test | 61 | 3 | 10 | 5 | 43 |
| xform.test | 56 | **53** | 0 | 3 | 0 |
| view.test | 41 | **34** | 2 | 4 | 1 |
| winfs.test | 27 | 1 | 0 | 2 | 24 |
| others (5 files) | 19 | 1 | 1 | 9 | 10 |
| **Total** | **715** | **346 (48.4%)** | **125 (17.5%)** | **139 (19.4%)** | **105 (14.7%)** |

Tiering the 346: **A — model only** (`insert`/`delete`/`get`/`index`/`mark`/`compare`/`count`), survivable behind a Tcl façade: **223**. **B — needs API that won't exist** (`tag ranges`, `edit undo/modified`, `dlineinfo`, `yview`, `cget`, `search`, `sel`): **94**. **C — input synthesis** (`event generate` into the text widget): **23**. **C+B**: **6**.

Final outcome across all 715: ~340 survive untouched (48%); ~252 mechanical adaptation (35%); ~100 substantive rewrite (14%); ~23 delete and replace (3%). **[Med]** — these are estimates, not measurements, and no port has been attempted.

**The three mechanisms that break — one of them restated, because rev. 1 got its shape wrong:**

1. **`event generate` stops existing for the component under test.** 33 sites across 29 tests aim synthetic keys at the text widget. `helpers.tcl:238` does `catch {focus -force [els::T]}` precisely so those reach the widget without OS focus — a Tk-internal trick. A child HWND with its own WndProc never sees a Tk queue event, and `PostMessage` to a window without real Win32 focus does not reliably produce keyboard input — exactly the headless condition the suite runs in. The replacement is `SCI_*` message injection: a different and **weaker** thing that tests Scintilla's command layer, not the path a keystroke takes. **[High]**
2. **`tag ranges` is the only observable for two shipped features.** 25 tests assert on `wsTab`(6), `wsTrail`(5), `wsSpace`(5), `findAll`(5), `currentLine`(5), `findOne`(4), `sel`(5), `focusDim`(3). Indicators are queryable (`SCI_INDICATORSTART`/`END`/`VALUEAT`), so most is recoverable — but `currentLine` becomes native caret-line highlight, which is **not** a queryable range, and `els::selftest` line 8053 loses that probe outright.
3. **The synchronisation barrier — corrected.** Rev. 1 said "~600 tests rely on `update`". That was wrong and should not be quoted: it also contradicted rev. 1's own "~340 survive untouched." Measured: **~204 direct `update` calls across all test bodies** (ui 129, view 47, els 9, find 5, xform 5, units 4, encoding 3, harness 2), plus 21 `ui_settle`. The barrier is **largely centralized in helpers** — so this is a helpers rewrite, not 600 test edits. **[High]**

   But in *kind* it is worse than rev. 1 described. `els_reset` does not merely `update`; it **enumerates and cancels every pending `after`** — the named ones (`find_after`, `find_poll_after`, `find_snapshot_after`, `tip_after`, …) at helpers.tcl:158–177, then a blanket `foreach a [after info] { catch {after cancel $a} }` at helpers.tcl:204, with the comment naming "order-dependent flakes" as the enemy. **That sweep is the actual source of a green 715.** Any component with deferrals els cannot enumerate — Scintilla's idle wrap and idle styling, or a hand-written renderer's own paint/scroll scheduling — is **outside that invariant permanently**. It is not "update stops being a barrier"; it is "the cancel-everything invariant becomes uncloseable." **[High]** **This is the single strongest argument in the document, and it applies to Option A and Option C alike.**

**Also:** **597 of 715 tests call `els_reset`/`ui_reset`/`find_reset`**, each doing `destroy [winfo children .]` + `els::build` — 597 widget create/destroy cycles per run. Under Scintilla that is 597 HWND cycles with a real message pump, introducing timing sensitivity into what is today a deterministic in-process `tclsh90` run **that gates the release**. Mitigation: `SC_TECHNOLOGY_DEFAULT` (GDI) for the test path, which keeps it GPU-free. **Not priced anywhere in rev. 1: the resulting suite wall-clock, and the permanent flakiness tax on a gate that becomes timing-sensitive rather than deterministic. For a solo maintainer that tax is levied on every future change, not once.**

Not counted in the 715: `helpers.tcl` (274 lines) needs partial rewrite; `encoding_stress.tcl` (297 lines, ~800 UI ops, gating `stress-1.1`) needs its driving layer rewritten wholesale.

### 2.3 Build, toolchain, release gates — strengthened

Toolchain-wise this is feasible **without a new z payload for the compiler**: `g++` 16.1.0, `libstdc++.a`, `libsupc++.a`, `libwinpthread.a` and its `COPYING` are already inside `C:\dev\.z\r\msys2\ucrt64`. Verified twice. **[High]**

**But this GCC is `Thread model: posix`, and that detonates a deliberate invariant** **[High]**:

| Experiment | Result |
|---|---|
| `g++ -static-libgcc -static-libstdc++` (no `-static`) | exe gains a runtime dependency on **`libwinpthread-1.dll`** |
| `g++ -no-pthread` (els's mandatory flag) | **link fails** — undefined pthread symbols |
| same, TU compiled `-fno-exceptions -fno-rtti` | **still fails identically** |
| `gcc … -Wl,-Bstatic -lstdc++ -lpthread -Wl,-Bdynamic` | **works**; imports stay `KERNEL32` + `api-ms-win-crt-*` |

**Rev. 1 understated this and its confidence register flagged the magnitude as inferred. It is now measured, and it resolves against the study.** Rev. 1 attributed the failure to `eh_alloc.o` being dragged in by `operator new` — i.e. an incidental libstdc++ allocator artifact one might dodge with a different runtime. Linking **real Scintilla objects** with els's mandatory flags produces **17 distinct undefined symbols**:

```
pthread_create   pthread_join     pthread_detach    pthread_once
pthread_cond_broadcast/destroy/signal/wait
pthread_key_create/delete  pthread_getspecific/setspecific
pthread_mutex_init/destroy/lock/unlock  pthread_num_processors_np
```

`pthread_num_processors_np` is `std::thread::hardware_concurrency()`; `pthread_create/join/detach` are real `std::thread`/`std::async` from the parallel layout path. **Scintilla spawns threads functionally. This is not an artifact you can engineer around.** A signed single exe that now creates worker threads is also a change to the startup-check profile and to the AV/EDR heuristic surface that nothing in this study budgets.

The link map contains `libpthread.a(libwinpthread_la-{mutex,thread,cond,sched,spinlock,rwlock,clock,misc,nanosleep}.o)`, so `assert_no_winpthread_link_map`'s regex at `tools/tasks.tcl:2021` matches and the gate fails exactly as predicted. **[High]**

**els must start shipping winpthreads inside the exe.** That single fact breaks, by name:

1. **`assert_no_winpthread_link_map` (tasks.tcl:2014–2024)** — hard fail. *This gate exists precisely to catch what libstdc++ forces.*
2. **The `-no-pthread` policy itself** — passing it at link time makes any libstdc++ link fail outright.
3. **`native.winpthread-linked` provenance field** — written as literal `0` (1195); `read_verified_unsigned_metadata` errors with *"unsigned release provenance unexpectedly claims a winpthreads link"* if it isn't (1343).
4. **`tools/release_notices.tcl`** — emits *"els is linked with GCC's -no-pthread policy and does not include winpthreads."* Now false. `notice_sources` must add `share/licenses/libwinpthread/COPYING` and name libstdc++ under GPLv3 + Runtime Library Exception. `verify_packaged_payload` byte-compares the packaged notice, so both sides move together.
5. **`tools/release_tooling.test` — two tests fail.** Line 704 asserts the packaged notice literally contains `does not include winpthreads`; `provenance-1.5` asserts a map containing `libwinpthread.a` is *rejected*.
6. **`-Wall -Wextra -Werror` over vendored C++** will not pass. A second, relaxed flag profile for third-party `.cxx` weakens the "everything compiles clean" property. **[Med — asserted directionally, not tested.]**
7. **`release_fingerprints` (1050–1117) has a real hole.** It pins `tool.gcc`, `cc1`, `collect2`, `libgcc.a`, `libgcc_eh.a`, `libmsvcrt.a` — but **no** `g++`, `cc1plus`, `libstdc++.a`, `libsupc++.a`, `libpthread.a`, no `headers.libstdcxx.sha256`. Byte-for-byte reproducibility would still *pass* while silently losing coverage. The subtlest item and the easiest to skip by accident.
8. **`toolchain.md`'s "Allowed: Tcl 9, C23" and `AGENTS.md`** are normative, not decorative.
9. **This is a provenance *redesign*, not an extension — rev. 1 filed it wrongly.** `native_link_input_sha256` (2026–2065) enumerates link inputs *by name*; `run_native_startup_check` (2135–2189) re-links the object list by hand; `product_source_names`/`assert_product_source_inventory` (1980–2067) inventory sources; `unsigned_metadata_base_keys` (1163–1171) makes any new key a **breaking metadata-schema change**. A ~90k-line vendored tree makes by-name enumeration untenable; these must be converted to tree-hash form. That is a change to *how the release proves what went into the binary*.

**Not affected:** `pecheck.tcl` structural policy (AMD64/GUI/ASLR/DEP/HEVA/manifest/VERSIONINFO/icons/cert-table) — the `allowed_import` allowlist at `tools/pecheck.tcl:82` already covers user32/gdi32/imm32/ole32/oleaut32, and d2d1/dwrite are `LoadLibrary`-loaded (the same pattern `icudet.c` uses for `icu.dll`); zipfs append + PE-resource ordering; `probe_exe.tcl`; the tooling lock; signing/timestamping/promotion. **[High — independently reconfirmed.]**

**Vendoring:** ~90k lines of Scintilla C++ under `_els/src/` would drag through `release_tree_files` into `source.release-inputs.sha256` and require every file Git-tracked at mode 100644. The idiomatic fit is a `<z>/.z/r/scintilla/<version>` payload with a `dependency.scintilla-tree.sha256` fingerprint, plus teaching `assert_trusted_release_payloads` about it.

### 2.4 Binary size — real, but demoted as a decision input

| Source | Method | Delta | Resulting els.exe |
|---|---|---:|---:|
| Scintilla researcher | **Measured**: minimal Win32 exe 18.5 KB → +static Scintilla 2,197 KB | **+2.13 MB** | ~7.3 MB (+41%) |
| Build researcher | Measured C++ floor (+181 KB) + estimated Scintilla core | **+1.2–1.9 MB** | ~6.4–7.1 MB |

Plan against **~7.2–7.4 MB, up from 5.25 MB** **[Med]**. `NO_CXX11_REGEX=1` produced *no* reduction, so `std::regex` is not the bulk. Untested: `-Os`, `--gc-sections`, LTO (guess 10–20%). This is **pure addition** — Tk's text widget remains statically linked in `libtcl9tk90.a` and cannot be removed.

**Demotion:** rev. 1 used the "+2.1 MB vs +50–150 KB" row as a tiebreaker for C1 over C2. `docs/DESIGN.md` makes the **single executable** an identity pillar (§"About and credits", line 222); it says nothing about megabytes, and neither do the non-goals. **A 5 MB→7 MB single file is still a single file.** Size is a real cost and should be stated; it is not a reason to prefer hand-written layout code over three decades of maintained rendering correctness.

### 2.5 Two things els gains — one of which rev. 1 buried

- **Accessibility: this is the strongest argument for Scintilla in the entire document, and rev. 1 filed it as a freebie in a subsection.** `docs/DESIGN.md:73` and `README.md:285–287` record the screen-reader gap as a **permanent, disclosed limitation**: els draws its own text surface on Tk, which exposes no UI Automation provider, so Narrator, NVDA and JAWS cannot read or navigate document text at all. NVDA does not use an accessibility API for Scintilla — `NVDAObjects/window/scintilla.py` sends `SCI_*` messages cross-process, keyed off the `"Scintilla"` **window class name** **[High, verified from NVDA's source]**. Embedding a real Scintilla control converts a documented permanent exclusion into a solved problem **for zero work**.

  "Calm, no-settings, hand-tuned" is a legitimate reason to refuse knobs. It is not a reason a blind user cannot read a file. Long lines are a rare-file annoyance; unreadable-to-a-screen-reader is a permanent exclusion of a class of users. **If A is ever revisited as els 2.0, accessibility is the headline of that conversation, not long lines.** And note the direction this points: a hand-written D2D surface has **no** accessibility story whatsoever, so C1 forecloses the one unambiguous win while spending the budget.

  (Caveat: Win32 accessibility is otherwise Scintilla's weakest area — no MSAA text pattern, no IAccessible2, no UIA `TextPattern`; the docs say only that "the system caret is manipulated to help screen readers." JAWS and Narrator with Scintilla are **unverified**. **[Low]** The NVDA path is the verified one.)

- **IME/CJK is materially better than anything hand-written.** Both `SC_IME_WINDOWED` and `SC_IME_INLINE` on Win32, with Retrieve/Reconvert/Delete Surrounding, reserved indicators 32–35 for IME underlining, a dedicated `win32/HanjaDic.cxx`, DBCS code pages, `SCI_SETFONTLOCALE`. IME is the thing everyone underestimates.

**Counterweight:** four DirectWrite technology variants exist because D2D fails in the field often enough to need three fallbacks. Notepad++ #16278 (Mar 2025) is a real `D2D1.DLL` crash fixed by switching to GDI; Scintilla bug #2420 was a `d2d1.dll` crash from a `SINGLE_THREADED` global factory.

---

## 3. COST SUMMARY

### 3.1 Dimensions

| Dimension | Full replacement (A) |
|---|---|
| New C++ glue | 1,500–3,000 lines **[Low]** — **larger than all six existing `src/*.c` combined (1,752 lines)**, in a language the project does not use |
| Tcl re-expression | 179 call sites / 307 lines across 390 procs; all 19 `xform` procs; the whole find highlighter |
| Deleted code | `text_proxy` (29), `draw_gutter` (57), find-snapshot slicer (~70), `lastdoc`, 8 char-offset conversions — **~156 lines, not creditable against ~2,000 written + ~90k vendored** |
| Tests damaged | **375 / 715 (52%)** — ~252 mechanical, ~100 rewrite, ~23 delete **[Med]** |
| Test machinery required | span-query API, layout-metrics API, input-injection path, flush barrier, an `after`-enumeration substitute for deferrals els cannot see, and a golden-image harness the project does not have |
| Suite character | deterministic in-process CPU run → 597 HWND cycles with a real message pump; **permanent flakiness tax on the release gate**, wall-clock unpriced |
| Release gates | 9 named, incl. 2 currently-passing tests in `release_tooling.test`, plus a **provenance redesign** (by-name link-input enumeration → tree-hash) |
| Policy reversals | `-no-pthread` → ship winpthreads (and **ship worker threads**); C23-only → C23+C++17/20; `-Werror` → relaxed profile for vendored code |
| Size | 5.25 MB → ~7.3 MB (+41%); new AV/heuristic false-positive surface, unassessed |
| Permanently lost | pixel-granular touchpad scroll; bounded undo (`MAXUNDO 2000`); exact tag-stack palette; one `selftest` probe |
| Permanently gained | **screen-reader access via NVDA**; best-in-class IME |
| Upstream treadmill | 6–9 releases/year — but **elective**: statically linked, no Lexilla, no network, 5.6.4 can sit frozen. Upgrades are *pulled* for bugs you care about, not pushed. (Elective until a Windows platform change — DPI, IME, DirectWrite — forces one.) |
| Bus factor | Sole maintainer, 25+ years. HPND makes forking legal; ~40 self-contained `.cxx`, no external deps. Real but **bounded** — and strictly better than bus-factor-1-by-construction |

### 3.2 Effort — the number rev. 1 never gave

Rev. 1 quantified everything except cost: precise about lines and tests, silent about calendar, and it attached its only time estimates to the cheapest items. That is an estimation pathology, and it meant "reject A" was argued from qualitative risk rather than from the comparison the method promised. The verdict was right; it was not *supported*. Estimates below are for one experienced solo engineer who knows this codebase, and are wide on purpose.

| Item | Estimate | Confidence |
|---|---|---|
| Re-measure `LONGLINE_CHARS` | **0.5 day** | High |
| Separate decode time from insert time | **1–2 hours** | High |
| Ask/answer the usage question | free | — |
| Honest elided read-only view (§4 E+2) + save-guards in 4 paths + tests | **4–8 days** | Med — most likely item to overrun |
| Chunked reader (already scoped in ROADMAP) | weeks, per ROADMAP | not this study's to price |
| Tk-hosting spike (rev. 1's "two-day 4a") | **8–12 days** | Med — needs a Scintilla `z` payload (project history says a payload bump is multi-day), a statically registered Tcl extension in the single-exe link path, `winfo id` reparenting glue, and an `SCN_*`→Tcl path *before* the experiment starts |
| Wrap spike (rev. 1's 4b) | **0 — already done** (§1.2) | High |
| Option C2 (stripped read-only Scintilla viewer) | **2–4 months** — glue is small (300–600 lines) but the release-gate and provenance work is the same one-time cost as A's | Low |
| Option C1 (hand-written D2D viewer) | **3–6 months, then permanent ownership** | Low |
| Option A (full replacement) | **5–9 months of concentrated solo work**, plus a permanently slower, timing-sensitive release gate | Low — wide error bars, and the test-strategy rebuild is the least predictable part |

A solo maintainer gets a small number of "big swing" budgets in a project's life. **A spike that overruns is the most common way one of them is lost** — which is why the spike is deferred rather than scheduled, and why its honest price is stated as 8–12 days rather than two.

---

## 4. THE OPTIONS

### A. Full replacement — Scintilla becomes els's engine

**Buys.** One engine, one behaviour; identity preserved because there is still only one way els feels. Long-line limits largely lift (fully for isolated lines, to ~5 fps for bundle-shaped files). Large short-line files up to 2.5 GB. Gutter Canvas, text proxy, find slicer deleted. IME improves. **Screen readers work.**

**Costs.** §3 in full. Three compound: a glue layer larger than all existing C combined, an index-model rewrite through 390 procs, and — decisively — **the suite's driving *and* determinism mechanisms stop existing for the component under test.**

**The honest framing.** This is a rewrite of a shipped, signed, code-complete 0.99 product, executed with the regression net switched off, at an honest 5–9 months. For an editor whose identity claim is *never lose text you have saved*, that attacks the one thing els sells. There is a quieter identity cost too: els today is *one file you can read*; it becomes a Tcl shell over a C++ engine.

**Verdict: reject as an increment to 1.x. Preserve as an explicit els-2.0 conversation** — a scheduled successor project whose test strategy is designed and built *first*, and **whose stated motivation should be accessibility, not long lines.**

### B. Dual engine — Tk Text normally, Scintilla for currently-refused files

**Buys.** Nothing another option doesn't buy more cheaply.

**Costs.** All of A — a second engine is not a smaller engine — **plus permanent duplication**: two undo stacks, two whitespace renderers, two focus-mode implementations, two gutters, two scrollbar syncs, all 19 xform procs twice forever, and **two save paths against the one guarantee that must never break.**

**Identity: fatal.** The file you couldn't open before opens into an editor with a different caret, different selection semantics, different keys — a hidden mode the user never asked for and cannot turn off. A settings UI in a trenchcoat, which is exactly what `DESIGN.md`'s non-goals exist to prevent.

**Verdict: reject, hardest of all.** *And apply the same test to any viewer proposal — see C.*

### C. Read-only viewer for currently-refused files

The idea is still the right *shape*: **editing a 266k-char line responsively is a hard engine problem; reading one is an easier one.** §1.1 confirms the split is real — scrolling an isolated 266k line is 16 ms, typing into it is 33 ms/keystroke. els does not need to solve the hard one.

But rev. 1's version of C was granted an identity free pass it did not earn, and rev. 1's choice of *how* to build it was wrong. Both are corrected here.

**C is Option B with a smaller second engine, and it must pass B's tests.** Rev. 1 noticed this once — "the only survivable version of B is B-restricted-to-read-only, at which point it *is* Option C" — and then never carried the critique forward. Held to B's own standard:

- **Palette duplication.** §6.7 makes "can the 8-level tag stack be reproduced?" potentially disqualifying for A. A viewer must reproduce the visual identity from zero: `#F2F2F2`/`#1A1A1A`, 1.34× leading computed as `int(linespace × 0.17)`, the 10.5p inset, the 3p steady red caret, `#D6E2F2` selection, gutter tonal step and baseline alignment, DPI scaling of all of it. Two independent implementations of "what els looks like," drifting — the permanent duplication used to kill B.
- **Foreign HWND.** The decisive argument against A applies unchanged. Rev. 1's rebuttal ("line indexing, hit-testing and scroll math are pure functions") tests the arithmetic and abandons the widget: focus, selection drag, wheel/touchpad scroll, Ctrl+C, Escape, tab switching, DPI change, participation in `els::build`/`destroy` across 597 resets. And a hosted control's own paint/scroll deferrals sit outside `els_reset`'s cancel-everything sweep permanently.
- **Find is not "almost free."** Rev. 1 said els's find is "already engine-agnostic" because the worker runs out-of-process over bytes. **Half true, and the half that matters is false: `els::find_snapshot_step` (6656–6725) snapshots the *widget buffer* via `$w get "1.0 + $offset chars" …`, not the disk bytes** **[High, read from source]**. A viewer therefore needs a new snapshot source. And `FIND_INPUT_MAX` is 256 MiB (`els.tcl:529`) — the viewer's headline case is files above that ceiling, so it also needs a raised ceiling with a new worker memory profile, new offset→display mapping, new highlight application, and new scroll-to-match. That is scope creep already latent in the scope statement.

**The sub-decision — which engine? Rev. 1 answered C1; the answer is C2.**

|  | C1: hand-written D2D in C23 | C2: stripped read-only Scintilla |
|---|---|---|
| New code | **3,000–5,000 lines C** (manual COM vtable dispatch runs ~1.5–2× the C++ line count) | ~300–600 lines C++ glue |
| Toolchain | none — D2D/DWrite are COM, callable from C23 | C++17, static libstdc++, **winpthreads + worker threads shipped** |
| Release gates | untouched | 9 gates + 2 failing tests + notices + fingerprints + provenance redesign |
| Size | ~+50–150 KB | ~+2.1 MB |
| **Correctness inherited** | **none — and a viewer needs a lot of it** | chunked measurement, `BreakFinder` run splitting, font fallback, bidi, grapheme clusters, gap buffer, `TEXT_LARGE`, **NVDA** |
| Many-long-lines behaviour | you must build a viewport layout cache with eviction **yourself** | ~200 ms frames, ~10× RAM — imperfect, but built and debugged |
| Maintenance | **non-elective, bus-factor-1, no upstream, no rendering test harness, forever** | elective; can freeze at 5.6.4 |
| Accessibility | **none, permanently** | free |
| Estimate | 3–6 months + permanent ownership | 2–4 months, one-time |

**Why rev. 1 got this backwards.** It rested on one sentence: *"the correctness Scintilla contributes is overwhelmingly editing correctness — IME, undo, selection semantics across grapheme clusters, mark floating — and a viewer needs none of it."* Enumerate what a viewer actually needs and it is almost entirely **rendering** correctness — the exact thing §1.1 spends three pages praising:

- chunked measurement + position cache + binary-search hit-test (rev. 1 itself named this C1's "hard part");
- run breaking that respects style and script boundaries — `lengthEachSubdivision = 100` applies *within* a `BreakFinder` run, not blindly across the string; a naive 100-char subdivision splits combining marks, ligatures and bidi runs. "Take Scintilla's idea without its build" reimports precisely the bug class that Option D is rejected for;
- **font fallback** — the moment you stop handing whole strings to `IDWriteTextLayout`, DirectWrite stops doing fallback for you, and CJK or emoji in a log file becomes tofu unless you drive `IDWriteFontFallback` per run;
- grapheme-cluster boundaries and bidi — needed for *selection and hit-testing*, which the viewer explicitly ships;
- **UTF-8↔UTF-16 index duality** — els's document is UTF-8, DWrite is UTF-16; every drawn chunk needs conversion and every hit-test result needs mapping back. Scintilla owns this; C1 builds and maintains a second index space forever.

Add the requirement §1.1 discovered — a viewport-bounded layout cache with an eviction policy — and rev. 1's 800–1,500-line budget is not close. **Rev. 1 also set an abandon ceiling at 1,500 lines and said crossing it means "C2 becomes the cheaper trade after all." Its own scope description guarantees that tripwire fires. The study had already reasoned its way to C2 without noticing.** And an abandon ceiling on half-built, correctness-critical native rendering code is not a real off-ramp: by the time you know, the budget is spent and you own a half-renderer.

**Verdict: the viewer is deferred, not recommended, on present evidence — because its motivating frequency was never established (§5). If it is ever built, it is C2.** The scope-discipline risk rev. 1 identified is real and its mitigation is retained: **write the read-only-ness into `docs/DESIGN.md` as a non-goal on day one, before writing code** — the way the scripting API was decided against on 2026-07-05.

### D. Custom D2D/DirectWrite *editor* from scratch

Piece table, bidi, complex-script shaping, IME composition (`WM_IME_*`, `ImmSetCompositionWindow`), UIA accessibility, clipboard, DPI, grapheme-cluster selection, undo. Scintilla is three decades of accumulated correctness in exactly these areas. 10,000+ lines to arrive at a worse Scintilla, spending every remaining year of the project on the layer users never see.

**Verdict: the clearest "no" here — and note that C1 at 3,000–5,000 lines is this option arriving by increments.**

### E / E+. Do nothing, or do the cheap things

**E buys** zero cost — identity, 715 green tests, release process, 5.25 MB signed single file all intact. And the refusals are *honest*, which is rarer and more valuable than the original framing credited. **E costs** an unopenable `.min.js`, single-line JSON, SQL dump, or long log line — **at an unmeasured frequency**.

**E+ item 1 — re-measure `LONGLINE_CHARS` on Tk 9.0.4 and set it from data.** 50,000 was set against a measured ~2.3 s (`els.tcl:571`). If the real tolerance boundary is ~0.5 s the honest threshold is nearer 20k; if the curve moved with the toolchain it might be 80k. Half a day. The constant encodes a measurement from an older toolchain and should not be an inheritance. **Do this regardless of every other decision here.** [Unchanged from rev. 1 — this item survived all three reviews clean.]

**E+ item 2 — WITHDRAWN as written, replaced.**

Rev. 1 proposed: *"offer to insert hard breaks every N chars into a read-only buffer, clearly labelled."* **That is the least honest item in the plan, and it was scheduled first and unconditionally.** It displays text that is not the text in the file, in an editor whose distinguishing virtue is honest refusal. Four verified defects it did not price:

- **Fabricated line numbers.** `els::draw_gutter` (3461) numbers *logical* lines via `$w index @0,0`. Injected breaks are real logical lines, so a 266k-char line 1 renders as lines 1…267. The gutter — whose whole job is to tell you where you are in the file — lies, with no marker. Continuation rows of a *soft* wrap correctly get no number; this design deliberately defeats that.
- **Silent find false negatives.** The find snapshot is taken from the widget buffer (verified above), so any term straddling an injected break returns "no matches" for a string demonstrably in the file. For a data-safety editor, find reporting the absence of present text is a worse honesty failure than refusing to open.
- **Clipboard contamination.** Copy carries the fabricated newlines into the user's paste target. Corrupting text on the way *out* is the same class of harm as on the way in — and it is the *likely* use of a read-only view of a minified file.
- **Wrong reuse, twice over.** `els::become_lazy` (2301) is the **placeholder** mechanism — an *empty* buffer, `-state disabled`, plus `bind $w <KeyPress> [list els::lazy_key $id]` which **materializes the file on the first keystroke**. A wrapped view has content and must never materialize; reusing `docLazy` layers a contradictory second meaning onto something that also drives tab glyphs, `make_placeholder` and session restore. And `docDiskState … readonly` (481, set at 2988) is an *observation about the file on disk* (`file attributes -readonly`), not a buffer mode. **els has no concept of a buffer whose content deliberately differs from the file.** That is a new invariant, not reuse.

Plus: it delivers wrap semantics, by content mutation, to a user whose `word_wrap` is **0** (570). "~50–100 lines of Tcl" is not credible once real-line-number mapping, find offset translation, copy translation and status-bar Ln/Col are included — that is a translation layer between two coordinate spaces, precisely the bug class this project spends its energy avoiding. And by rev. 1's own test it is a hidden mode, *less* honest than a viewer, since a viewer shows the file and this shows a fabrication of it.

**E+ item 2, rewritten — the honest elided view:**

> Open read-only. Render each over-long line **truncated**, followed by an explicit, non-selectable elision marker: **"+266,412 characters not shown."** Tk never lays out a long line.

Nothing is fabricated — only omitted, and visibly. The gutter stays byte-true (one file line = one display line). No coordinate mapping. No injected characters to leak into a paste.

**The residual honesty obligations, stated rather than glossed** — because the buffer's content is still not the file's content, just subtractively rather than additively:

- **Find must not silently under-report.** In an elided buffer, either refuse find with a stated reason ("this view omits N characters; search is unavailable here"), or route it at the file bytes. **Refusing loudly is in character; returning "no matches" is not.** Choose before coding.
- **Copy yields the visible prefix only.** Disclose it, or block copy on elided lines. Do not let a partial copy look complete.
- **The save-guard is four paths, not one:** `els::save` (5277), `els::saveas` (5445), `els::save_with` (4394, encoding conversion), and **`els::autosave_flush_doc` (5253)** — autosave is user-persisted and debounced, so a user with it on is exactly the person at risk. Guard in the model, not the UI, and write a test per path. The pattern already exists twice for placeholder tabs (5255, 5282), so it is idiomatic and cheap.
- Backup ring and disk-watch/reload behaviour need a decision for a buffer that is not the file.

**4–8 days including the guard tests, not "days, not months" and not 50–100 lines.** It remains worth doing — it converts most refusals into "you can read the start of it," inside the existing engine, the existing suite and the existing ethos — but it is the item in this plan most likely to produce a data-integrity bug, so it ships with tests, not with speed.

**Verdict: E+ item 1 ships now, unconditionally. E+ item 2 ships in its elided form, after step 0's usage answer, with the four save-guards and an explicit decision on find and copy semantics.**

---

## 5. RECOMMENDATION

**Ask what the user actually wants. Ship the cheap in-engine work. Do not build a second renderer on present evidence. If one is ever built, it is C2.**

0. **The usage question, first, because it is free and it is the highest-information action in this document:** *do you want to **edit** these files, or only read them?* Rev. 1 deferred this behind three unconditional steps that partly presuppose its answer. If the real case is "I open a 200 MB log and need to fix three lines," a read-only viewer is a half-answer and the whole C branch is aimed at the wrong half.
1. **Re-measure the quadratic curve on Tk 9.0.4 and set `LONGLINE_CHARS` from data.** Half a day. Unconditional.
2. **Separate decode from insert on a large open.** One hour. It can reorder everything after it.
3. **Build the elided read-only view** (§4), with save-guards in all four paths, an explicit find/copy decision, and its own tests. 4–8 days.
4. **Finish the chunked reader.** It addresses the freeze on files opened *routinely* — and by rev. 1's own frequency argument it should outrank two long-line items, which rev. 1 ranked above it.
5. **Then re-ask what residual problem survives.** This is the comparison rev. 1 never made, which is why it never had to defend a from-scratch renderer against the cheap thing it had just recommended. Plausible residue: no horizontal scrolling of a genuine 266k-char line, no >1 GiB open. Weigh that against 2–4 months and a release-policy reversal, **with usage evidence in hand.**

**Deferred:** the Tk-hosting spike. It is 8–12 days, not two; it informs an els-2.0 conversation that is not on the table at 0.99; and it is the phase most likely to generate temptation. **Dropped entirely:** the wrap spike — §1.2 answered it. **Re-specified if it ever runs:** rev. 1's render spike said *"render 60 visible lines of a file with a 266k-char line."* That is the optimistic single-long-line case, now confirmed fast — **as written, it passes and tells you nothing.** It must be 60 visible lines that are *each* long.

**Why not A, stated plainly.** Not because Scintilla is bad — it is excellent, it improves the long-line case by three to four orders of magnitude depending on file shape, word wrap turns out to be linear, the Lexilla split makes it a *better* ethos fit than the framing assumed, and it would hand a blind user a file els cannot currently read to them. It is because of a verifiable property of *this* project: the 715-test suite drives real Tk widgets with `event generate` and stays deterministic by cancelling every pending `after` it can enumerate. A foreign HWND is invisible to the first and outside the second. That suite is the mechanism by which a solo maintainer keeps a promise about never losing saved text. A requires switching it off, rebuilding it against a weaker substitute, rewriting 390 procs' index model, redesigning how the release proves what went into the binary, and reversing an invariant written specifically to prevent what libstdc++ forces — for 5–9 months. **The cost lands on the thing that makes els trustworthy; the benefit lands mostly on the thing that makes els occasionally inconvenient.**

**One argument on the other side, kept visible so it is not lost:** the accessibility benefit does *not* land on "occasionally inconvenient." It lands on a documented permanent exclusion. That is not enough to justify A as a 1.x increment — but it is enough that an els-2.0 conversation should be framed around it rather than around long lines, and it is the reason A is preserved rather than closed.

**A note on what this study delivers.** One reviewer's sharpest line is that the net new deliverable is a re-measured constant, and that the study is 90% of the way to "the 1.1 roadmap already contains the answer" before flinching and appending an engine project. The flinch is real and rev. 2 removes it. The rest is not quite right: rev. 2 delivers a re-measured constant, an answered usage question, a decode/insert split that can reorder the roadmap, an honest elided view replacing a dishonest one, the chunked reader promoted, a resolved word-wrap risk, and a well-supported "no" on a 5–9-month project. **A well-supported "no" is a deliverable.** It is worth more than a quarter.

---

## 6. WHAT WOULD MAKE THIS A MISTAKE

Conditions under which the recommendation is wrong — stated so they can be checked rather than assumed.

**The recommendation is wrong if:**

1. **Step 0 comes back "I need to edit these files."** Then the entire read-only branch is a half-answer and the real choice is A-as-2.0 versus permanent honest refusal. Check this before anything else.
2. **Insert, not decode, dominates a large open** (step 2). Then Scintilla's gap buffer fixes more than credited, the chunked reader fixes less than the roadmap implies, and the ordering of steps 3–5 changes.
3. **The elided view turns out to be enough** and the residual gap in step 5 is empty. Then this study's answer is "the 1.1 roadmap already contained it," and that is a good outcome, not a disappointing one.
4. **Usage evidence shows the refused-file class is frequent.** Frequency was asserted in rev. 1 and never established; the entire viewer branch rested on "a real, not-rare gap." If it *is* frequent, C2 becomes arguable on its merits and 2–4 months is a defensible price.
5. **You are willing to pay the release-policy reversal for its own sake.** If shipping winpthreads and adopting C++ is something you'd do anyway, the marginal cost of Scintilla collapses and C2 (or A) gets much cheaper. The provenance/notices/gate work is one-time; the treadmill is elective.
6. **Accessibility moves up the priority list.** It is the one thing here that Scintilla solves completely, for free, and that no in-engine work can touch. If it becomes a priority, this is no longer a long-line study.

**Adopting Scintilla at all is a mistake if:**

7. **The many-long-lines number is worse in practice than 196 ms** — e.g. once real disk I/O, a real message loop and els's own idle work are in the frame. ~5 fps is already the boundary of acceptable for a "calm" editor; there is no headroom.
8. **The 8-level tag z-order cannot be reproduced acceptably.** Six overlapping *background* tags → alpha-composited indicators is the least clean mapping in the port, and it lands directly on "one hand-tuned light palette," a stated identity pillar. Prototype the palette *before* committing. If it can't look right, that alone is disqualifying for A.
9. **Losing pixel-granular touchpad scrolling matters more than it sounds.** `yview scroll N pixels` was a deliberate fix (G-View mat-5); Scintilla is line-granular vertically. If smooth panning is part of "calm," this is unrecoverable.
10. **Byte-for-byte reproducibility silently degrades.** Adding C++ without adding `g++`/`cc1plus`/`libstdc++.a` to `release_fingerprints` leaves `z sign` passing while covering less. **This will not announce itself.** If you're not going to do the fingerprint and provenance work properly, don't do the C++ at all.
11. **You do the work while the suite is degraded.** Any variant of A executed by disabling tests and fixing them afterwards inverts the project's risk posture. If A ever happens, the test strategy — including a substitute for the `after`-cancellation invariant — is designed and built *first*, before a line of the port lands.

**Building a viewer at all is a mistake if:**

12. **You build it as C1.** Rev. 1's own tripwire — abandon at 1,500 lines — fires before the viewer draws a selection, and by then the budget is spent on a half-renderer you own forever. If the viewer is worth building, it is worth C2's one-time gate cost.

**The comparison is weaker than it looks if** the benchmarks are not apples-to-apples. Scintilla's numbers are 400-px horizontal scroll steps with forced full-window repaints, covering ~4% of the long line; els's Tk numbers are "one horizontal scroll" of a 266k line. The exact operations were never reconciled. The gap is three to four orders of magnitude, so the conclusion survives a large methodological discount — **but the precise ratio should not be quoted as if it were a measurement of the same thing.**

---

## 7. CONFIDENCE REGISTER

Ranked by how much each threatens the conclusions. **Two of rev. 1's top three are now closed.**

| # | Gap | Status | Impact |
|---|---|---|---|
| 1 | **Many simultaneously-visible long lines.** Rev. 1 inferred from `AllocateForLevel` that `SC_CACHE_PAGE` fixed it. | **CLOSED — against the study.** Measured: 196–208 ms/frame, 9–11× RAM at 100 × 266k. PAGE converts thrash into a memory multiplier. | **High. Downgraded the crux claim and re-specified the go/no-go test.** |
| 2 | **Word wrap on long lines.** Rev. 1's #1 risk; wrap never actually ran under its pump. | **CLOSED — in Scintilla's favour.** Linear: 0.067/0.132/0.162 s toggle at 266k/524k/1 M, 15.7–15.8 ms post-wrap scroll, `SCI_WRAPCOUNT` confirming. Notepad++ #13423 does not reproduce in 5.6.4 with PAGE. And `word_wrap` defaults to 0. | Was High; now none. |
| 3 | **Scintilla has never been hosted in a Tk window.** Plain Win32 parent throughout. Message loop, focus, `event generate`, Tk idle vs. Scintilla deferred wrap/idle-styling — all unexercised. The D2D clock proved output only. | **OPEN.** Spike deferred (8–12 days, not 2). | **High** — determines whether A is ever viable. |
| 4 | **No maintained Tcl/Tk Scintilla binding exists.** 1,500–3,000 lines is an estimate. | **OPEN.** | **High** — largest single new code artifact. |
| 5 | **Nothing measured is both large and long-lined.** §1.3 is 64-byte lines (`bigbench.cxx:83`); §1.1 is one long line; the adversarial run is 25 MB. A 50 MB minified bundle is unmeasured. | **OPEN.** | **High** — it is the actual target file class. |
| 6 | **Real file I/O.** All large loads used in-memory `SCI_ADDTEXT`; `ILoader` never exercised. | **OPEN.** | Medium — els's real large-file bottleneck was excluded from every measurement. |
| 7 | **Decode vs. insert has never been separated.** `ROADMAP.md:27` asserts both dominate. | **OPEN — one hour of work, and it can reorder the plan.** | **Medium-high**, and it was in no prior register. |
| 8 | **Deep horizontal scrolling.** The sweep covers ~4% of a 266k line, so the binary-search mechanism is source-verified but not performance-verified. | **OPEN.** | Medium. |
| 9 | **Frames layout-bound or draw-bound?** The 196 ms was not decomposed; the memory figure hints the cache is holding, which would make it draw cost that a better cache won't reduce. | **OPEN — ~1 hour.** | Medium — sharpens the number, doesn't change direction. |
| 10 | **Size delta:** +2.13 MB measured vs. +1.2–1.9 MB estimated; `-Os`/LTO/`--gc-sections` untested. | **OPEN.** | Low — plan against 7.3 MB, and stop using size as a decision lever. |
| 11 | **AV/EDR heuristic surface** of a signed exe growing 41% with a static C++ runtime *and newly spawning worker threads*. | **OPEN — unassessed.** | Low-medium, unpriced everywhere. |
| 12 | **`-Wall -Wextra -Werror` over vendored Scintilla** — asserted to fail, not tested. | **OPEN.** | Low. Directionally certain. |
| 13 | **Wine** with D2D. No Scintilla-specific current bug found; extrapolated from adjacent projects (SynEdit #91). | **OPEN.** | Low — GDI mode is the obvious fallback. |
| 14 | **Screen readers other than NVDA** (JAWS, Narrator). NVDA is verified from its source. | **OPEN.** | Low-medium — matters more now that accessibility is the headline 2.0 argument. |
| 15 | **`SCI_SETLAYOUTTHREADS`** effect on typing latency inside long lines — set but never isolated. Docs claim ~4× on layout-bound work. | **OPEN.** | Low. |
| 16 | **`SCI_STYLESETCHECKMONOSPACED`** — `checkMonospaced` defaults false, so the arithmetic fast path was never taken. On els's Consolas it would engage. | **OPEN — an unexploited speedup no round has measured.** | Low, but free upside for A or C2. |
| 17 | **Post-port suite wall-clock and flakiness tax.** 597 HWND cycles with a real message pump; never timed, never priced as an ongoing cost. | **OPEN.** | Medium for A — it is levied on every future change. |
| 18 | **Serialization.** No account of how a half-built engine coexists with 1.x bug-fix releases on a signed pipeline maintained by one person. | **OPEN.** | Medium for A. |
| 19 | **The `-no-pthread` magnitude** — rev. 1 inferred it from a synthetic libstdc++ TU. | **CLOSED — against the study.** Real Scintilla objects yield 17 undefined pthread symbols including `pthread_create`/`join`/`detach` and `pthread_num_processors_np`. Scintilla spawns threads functionally; this is not dodgeable. | Was Medium; now certain and worse. |
| 20 | **The DirectWrite hscroll numbers are vsync-floored (~16.6 ms).** | Noted, not a gap. | None. |

**One stale data point to discount actively:** SourceForge feature request **#928** ("Support for large files / 64-bit mode") was rejected in July 2012 with *"Changing to 64-bit positions is highly inefficient for files that do not need this,"* milestone `Won't_Implement`. It remains the top search hit and it is **obsolete** — `SC_DOCUMENTOPTION_TEXT_LARGE` landed in 4.0.5 (2018), `Sci::Position` is `intptr_t`, and 2.5 GB was measured working in 5.6.4. Do not let that ticket collapse the proposal, and do not let anyone else cite it at you.

---

## APPENDIX — corrections worth carrying forward regardless of the decision

1. **Scintilla's defaults are a better ethos fit than assumed.** Autocompletion (`SCI_AUTOCSHOW`) and calltips (`SCI_CALLTIPSHOW`) are opt-in — nothing appears unless you call them. Syntax highlighting lives in **Lexilla**, a *separate* library since 5.x; build without it and els's "no syntax highlighting" non-goal is satisfied by omission. Folding, brace matching, indent guides, virtual space, annotations, edge markers: all default-off. The residual obligation is a *permanent* review item — every upgrade can add a new default, and the maintainer must re-audit that els still looks like els. Small each time; unbounded in aggregate. **Mitigated by the fact that upgrades are elective** (§3.1).

2. **`SC_TECHNOLOGY_DEFAULT` (GDI) remains the right choice for els — on revised grounds.** Rev. 1 justified it as "faster for els's workload." That holds for isolated long lines (6.3 ms vs 16.2 ms at 266k, not vsync-capped) but **not** for the many-long-lines case, where GDI and DirectWrite are equal (208 vs 196 ms vscroll; GDI is ahead on hscroll, 165 vs 181). **So the honest claim is "at least as fast, never slower, and safer."** The safety is the real argument: it avoids the driver-crash class documented in Notepad++ #16278 and Scintilla #2420, avoids the Remote Desktop and Wine questions entirely, keeps the headless test path GPU-free across 597 resets, and removes any pressure to expose a rendering-mode setting — which els has no place to put. **Corollary, unchanged and worth restating: the Direct2D result that prompted this study is not needed for the fast path.**

3. **The find pipeline is less engine-agnostic than believed.** `els::find_snapshot_step` reads the **widget buffer**, not the file, and `FIND_INPUT_MAX` is 256 MiB (`els.tcl:529`). Any design that puts different bytes in the buffer than on disk — hard-wrapped, elided, or a foreign control — must answer for find before it answers for anything else. This is true of E+ item 2, of C, and of A.

4. **`els_reset`'s `after`-cancellation sweep (`tests/helpers.tcl:204`) is the load-bearing determinism mechanism of the whole project.** It is not documented as such anywhere. Anything introduced into els that schedules deferred work els cannot enumerate is outside it, permanently. That sentence is the shortest correct summary of why this study says no.