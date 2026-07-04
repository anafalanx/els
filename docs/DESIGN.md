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
  widget's `-spacing1`/`-spacing3`, computed as `round(linespace × 0.17)` so it
  tracks DPI. The gutter mirrors it so line numbers stay aligned.
- **Text inset:** `-padx 14` so glyphs never touch the frame.
- **Spacing grid:** chrome paddings follow a ~4px quantum.

### The caret

A **steady** 2px red bar (`-insertwidth 2 -insertofftime 0`). A blinking cursor
is a documented distraction; a solid red caret is calmer *and* more distinctive.
It is els's signature.

### Chrome

The native Windows `vista` ttk theme cannot be recoloured or flattened, so the
chrome is based on **`clam`** with custom flat, borderless styles
(`els::init_style`): flat entries with a hairline border and a red insert caret;
flat buttons; find toggles as grey "on" chips (neutral, since red stays the caret's);
slate text; hairlines above the status and find bars. The vertical **scrollbar
is slim and arrow-less, and auto-hides when the document fits**. Chrome appears
only when needed.

## Find & replace

A docked bar (Ctrl+F / Ctrl+H), the lessons distilled from EditPad Pro
(*restraint plus polish*):

- **Incremental** highlight of all matches with a live `N of M` count; Enter /
  Shift+Enter step and wrap.
- **Flash, never popup.** No-match, bad-pattern and wrap-around flash the field
  red, never a dialog.
- **Match Case / Whole Word / Regex** toggles (Tcl ARE), plus **Adapt case**:
  the replacement follows each match's case (`cat→dog`, `CAT→DOG`, `Cat→Dog`).
- **Regex reference:** a `?` button, greyed until Regex is on, opens a compact
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
