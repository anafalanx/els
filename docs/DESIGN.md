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
  copy-paste-portable app), Segoe UI 9pt for chrome. Fonts are sized in
  **points** so they scale correctly on HiDPI.
- **Leading ≈ 1.34×** is the single biggest "calm" lever. Applied via the Text
  widget's `-spacing1`/`-spacing3`, computed as `int(linespace × 0.17)` so it
  tracks DPI. The gutter mirrors it so line numbers stay aligned.
- **Text inset:** `-padx 14` so glyphs never touch the frame.
- **Spacing grid:** chrome paddings follow a ~4px quantum.

### The caret

A **steady** 4px red bar (`-insertwidth 4 -insertofftime 0`). A blinking cursor
is a documented distraction; a solid red caret is calmer *and* more distinctive.
It is els's signature.

### Accessibility, honestly

The steady caret removes one documented barrier, but it does not make els an
accessible editor. Tk draws its own text surface and exposes no UI Automation
provider, so Windows screen readers (Narrator, NVDA, JAWS) cannot read or
navigate document text — a limitation of the toolkit, not a setting els withheld,
and one no amount of theming fixes. Text zoom and a fixed high-contrast palette
are the accessibility levers els does have. The user-facing statement of this
lives in the README's *Requirements & limitations*.

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

- **Incremental** highlight of all matches with a live `N of M` count; Enter /
  Shift+Enter step and wrap.
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

## Non-goals

Written down so they stay decided:

- No settings/preferences UI (no configurable colour, font, or caret).
- No syntax highlighting.
- No rounded corners, drop shadows, smooth/inertial scrolling, or animation:
  Tk renders these poorly; it looks professional staying flat.
- No minimap.
- No regex debugger, token-builder, or named-search manager: over-scoped.
- No modal find/replace dialog.
- **No scripting / extension API.** The text-manipulation commands ship as a fixed,
  curated set (Buffer menu; see below), not as a user-scriptable buffer API. A scripting
  surface is the ultimate knob — it would contradict the whole "no settings" identity,
  add a security/API-stability surface to a data-safety editor, and turn 1.0 from "a
  decided tool" into "an extensible platform." Decided against, 2026-07-05.
- **No tab-width setting**, so no Tabs↔Spaces conversion (which needs one). Indent inserts
  a literal tab; dedent removes one leading tab (or up to four leading spaces).

## Text commands

A small, opinionated set of buffer transforms (Buffer menu + keys), each undo-atomic. Line
ops act on the selected lines or the current line; sort/reverse/dedupe act on the selection
or, with none, the whole buffer.

- **Lines:** Move Up/Down (Alt+↑/↓), Duplicate (Ctrl+D), Delete (Ctrl+Shift+K),
  Join (Ctrl+J), Indent/Dedent (Tab/Shift+Tab on a selection).
- **Reorder:** Sort, Sort Descending, Reverse, Remove Duplicate Lines.
- **Transform:** UPPERCASE, lowercase, Trim Trailing Whitespace.

Deliberately excluded to keep the set tight: Title Case (fiddly), Tabs↔Spaces (needs a
width knob), sort variants beyond the two directions.

## Sources

The study behind this design:

- Sublime Text: *Anatomy of a Next Generation Text Editor*
  <https://www.sublimetext.com/blog/articles/anatomy-of-a-next-generation-text-editor>
- Zed: visual customization & philosophy <https://zed.dev/docs/visual-customization>
- Nova (Panic) review: <https://www.macstories.net/reviews/nova-review-panics-code-editor-demonstrates-why-mac-like-design-matters/>
- EditPad Pro search / regex: <https://www.editpadpro.com/search.html>,
  <https://www.regular-expressions.info/editpadpro.html>
- iA Writer: responsive typography <https://ia.net/topics/responsive-typography-the-basics>
- Blinking caret as an accessibility barrier:
  <https://sensorydiversity.com/the-blinking-cursor-text-caret-is-an-overlooked-accessibility-barrier-in-software-development/>
- Tk theming: `clam`, `ttk::style`; awthemes <https://github.com/bll123/tcl-awthemes>
