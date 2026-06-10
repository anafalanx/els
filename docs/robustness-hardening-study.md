<!--
  Robustness audit + hardening plan produced 2026-06-08 by a multi-agent
  investigation (19 agents) of the live els.tcl, with LIVE PROBES driven through
  tests/helpers.tcl under tclsh90.exe and an adversarial verification pass on every
  critical/high data-loss finding. Claims are tagged [OBSERVED] (reproduced by
  probe), [CODE-READ], or [INFERRED]. Line numbers are as of els 0.30. Companion to
  docs/native-port-study.md (the native port is the P3 capstone here).
-->

# els — Extreme-Robustness Hardening Study

**Scope:** a robustness audit and prioritized hardening plan for els (single-file Tcl/Tk 9.0.3 Windows text editor, `els.tcl`, ~3000 lines). Goal is *robustness, not features*. Grounded in direct code reads, six parallel audits (several with live probes driven via `tests/helpers.tcl` under `tclsh90.exe`), and an adversarial verification pass on every critical/high data-loss claim. Each claim below is tagged **[OBSERVED]** (reproduced by live probe), **[CODE-READ]** (confirmed in source), or **[INFERRED]**.

---

## 1. Executive summary & robustness posture today

els is already a *carefully* built editor. The robustness gaps are not sloppiness — they are a small number of specific, high-consequence omissions, plus one architectural decision (in-place document writes) that is the dominant data-loss risk. The verification pass **confirmed every critical and high finding**, reproduced the #1 truncation window byte-for-byte, and — importantly — found that the proposed fixes are sound but carry concrete Windows pitfalls that must be handled (notably for the atomic-save rename).

### What is already solid (keep, and add regression guards)

| Area | Evidence |
|---|---|
| **Atomic config save** | `els::save_geometry` writes `$f.tmp` then `file rename -force $tmp $f`, deleting the temp on failure (els.tcl:336-342). [CODE-READ] |
| **Atomic selftest report** | `--selftest` report uses the same temp+rename discipline (~2849-2852). [CODE-READ] |
| **Guarded config load** | Config load is per-key `catch`-guarded; 6 corrupt/garbage `els.conf` variants, a config-path-that-is-a-directory, and vanished/garbage `session_files` all survived with `load_geometry ok=1` and zero bgerrors. [OBSERVED] |
| **Encoding round-trips** | 95-encoding auto-detect with strict-UTF-8 test, NUL-parity wide detection, replace-profile decode (never throws on bad bytes). A 4 MB all-bytes binary opened in 539 ms without error. [OBSERVED] |
| **Dirty-close / quit flow** | `WM_DELETE_WINDOW` always routes to `els::quit`; when a chosen save fails, `quit` re-checks `doc_dirty` and **aborts exit** (`exit=0`) so the user is never silently dropped. Read-only target saves fail safe (`open w` is blocked before truncation; original bytes intact, buffer stays dirty). [OBSERVED] |
| **reg.exe injection safety** | `assoc_run` does `exec {*}$cmd` where every element is built with `[list …]`; a hostile exe path stayed a single literal argv element. No cmd.exe, no word-splitting. [OBSERVED] |
| **Recents / session validate-on-use** | `recent_open` checks `file exists` and offers removal; "Remove Missing" exists; `session_sanitize`/`recent_sanitize` dedupe and tolerate junk. [OBSERVED] |
| **Graceful ICU absence** | Missing system ICU returns `""` → documented BOM/UTF-8/cp1252 fallback. [CODE-READ] |
| **Regex-DoS resistance** | Tcl's hybrid DFA/NFA engine resisted `(a+)+$`, `(a\|aa)+$`, `(.*)*`, and true backrefs — all returned ~0 ms at every size tried. els is far less exposed to regex catastrophic backtracking than PCRE editors. *(This downgrades a concern people would expect to be top-tier.)* [OBSERVED] |

### The real gaps (ranked in §2)

1. **Document save is non-atomic** — `els::save` truncates the user's real file before writing. **#1 data-loss risk.**
2. **No autosave / swap / crash-recovery** for unsaved edits; untitled buffers vanish without a trace on abrupt exit.
3. **No external-modification detection** — a normal save silently clobbers a file changed on disk by another program (lost update).
4. **Silent lossy encoding** on save (`-profile replace` writes `?` and reports success).
5. **UI freeze** in find/replace when many matches land on one very long line (minified JS/CSS/JSON, single-line CSV).
6. **No production `bgerror`** — the shipped app falls back to Tk's modal "raining dialogs"; **no diagnostic log anywhere.**
7. **Restored geometry not clamped** to a visible monitor — window strands off-screen after a monitor change.
8. Minor: no large-file guard; long-path/DPI manifest gaps; `save_geometry` fails silently.

---

## 2. Top risks, ranked

### R1 — Non-atomic document save truncates the real file before writing **[OBSERVED, verified]**
- **Location:** `els::save` els.tcl:1966-1970 (`set fh [::open $docPath($active) w]; fconfigure -translation binary; puts -nonewline; close`). `saveas` (1985) and `save_with` (1839) route through this single write site. *(Verification note: `save_with` only flips encoding/BOM metadata in memory and marks the buffer modified; the actual write is always `els::save`. There is **one** write sink, not two — the fix and tests target `els::save` only.)*
- **Trigger:** any failure in the window between `open w` and `close` while saving a **writable** file — process crash, power loss, taskkill, disk-full, transient I/O error, antivirus quarantine, OneDrive/network drop.
- **Current behavior:** the file is truncated to **0 bytes the instant `open w` returns**, before any byte is written (`size_the_moment_after_open_w=0` reproduced on a 27- and a 35-byte file). On mid-write failure the surrounding `catch` fires a `tk_messageBox`, but the original bytes are already gone; the in-memory buffer is the sole surviving copy, and only while the process lives. A simulated partial write left only `"PARTIAL"` (7 bytes) on disk.
- **Blast radius:** total loss of an existing on-disk document on any interrupted save. The editor whose #1 goal is data safety routes its most precious write through the one unsafe path while config and the selftest report are already atomic.
- **Fix:** write to a same-directory temp (`$path.els-tmp-<pid>`), flush+close, then `file rename -force $tmp $path`; on any failure delete the temp and report the error with the original untouched (verified: after a failed atomic rename the original is intact). **Mandatory Windows caveats, all reproduced (§6):** rename-replace **breaks NTFS hardlinks**, **drops explicit (non-inherited) ACLs**, and **drops Alternate Data Streams** (e.g. Zone.Identifier / mark-of-the-web). It also **fails cleanly on a read-locked target** (AV/indexer/OneDrive holding a handle) where the old in-place `open w` could write through — a *recoverable* regression, not data loss. Prefer Win32 `ReplaceFileW` (preserves ACL/ADS/attributes/creation-time) for the packaged build; in pure Tcl, detect hardlink/ADS-bearing/EFS targets and fall back to in-place rewrite (write a `.bak` first), and carry attributes onto the temp. Note: **Tcl 9.0.3 has no fsync** (`chan configure -fsync` → "bad option"); `flush`+`close` only reach OS buffers — same durability as the existing atomic config save, acceptable to ship, a future native port can add real fsync.

### R2 — No autosave / swap / crash-recovery; unsaved edits and untitled buffers lost on abrupt exit **[OBSERVED, verified]**
- **Location:** no machinery exists (grep for `autosave|swap|recover|backup` = 0 hits). Dirty state is only `$w edit modified` + the `<<Modified>>`→`els::on_modified` binding (els.tcl:1064, ~1415); `on_modified` writes nothing. `session_current_files` (~368) stores file **paths only**, skipping any doc whose path is `""`.
- **Trigger:** power loss/BSOD, taskkill, OS-update reboot, an uncaught Tcl error reaching exit, or a Tk/Tcl C-level segfault, while any tab is dirty.
- **Current behavior:** [OBSERVED] editing flips dirty 1 but `after info` shows **0 swap/autosave timers** and **no file is written anywhere**. On restart, session restore re-opens named files at their last *saved* bytes — all edits since the last save are gone with no prompt. **Untitled buffers are strictly worse:** `session_current_files` never records them (`PERSISTED COUNT = 0` for two dirty untitled buffers), so there is literally no record they existed. *(Graceful quit DOES prompt to save untitled docs; the loss is specific to abrupt exit.)*
- **Blast radius:** every dirty tab across the session; every never-saved buffer with no trace.
- **Fix:** a per-dirty-doc **swap** subsystem (full design in §4 P0-b). Write one atomic swap file per dirty doc under `<configdir>/swap/`, debounced on `<<Modified>>` (~1500 ms, coalesced per id) **plus** an unconditional repeating periodic flush (~30 s, because Tk fires `<<Modified>>` only on the 0↔1 transition — a doc that stays dirty without further edits would otherwise never refresh [OBSERVED]). On startup, scan for orphaned swaps (owner process dead), reconcile against disk, and **offer non-destructive recovery into a dirty buffer — never auto-write**. Key swaps by `sessionId+docId` so untitled buffers are recoverable; cancel/cleanup precisely on clean save/close/quit. **No Windows rename pitfall here** — a swap is a fresh app-private file, not a rename over the user's document.
- **Status — IMPLEMENTED** (the `CRASH RECOVERY / AUTOSAVE (R2)` section of `els.tcl` + the `els::win_lock_file`/`win_try_lock` helpers in `src/winfs.c`; 21 in-process tests in `tests/recover.test` + a process-level recovery probe in `tools/probe_exe.tcl`). An adversarial design pass (then an adversarial code review) refined the sketch above on several points worth recording:
  - **Liveness is a held Win32 byte-range lock, not pid+start-time.** A session holds an exclusive `LockFileEx` range on `<sid>.lock`; the OS frees it on process death, so "the lock is acquirable ⇒ that session is dead" — crash-, PID-reuse-, *and* fast-reboot-proof (a stale mtime can't falsely veto a dead lock). A pure-Tcl fallback (mtime freshness) covers dev/tclsh runs.
  - **A single ~2 s periodic tick + a ~400 ms post-edit debounce**, re-armed on real edit events (`<KeyRelease>`/`<<Paste>>`/`<<Cut>>`), replaces the 1.5 s/30 s pair — bounding worst-case lost edits to ~2 s without thrashing; idle large dirty buffers cost nothing (a cheap char-count gate + a `dirtySince` latch skip the O(n) crc).
  - **Recovery indexes the swap files (payload `sessionId`), not the lock files** — so a crashed claimer / renamed lock can never strand recoverable swaps. One *consolidated* dialog (never one modal per file). Recovered metadata (enc/bom/eol/cursor) comes from the swap record, never re-detected, so a lossy-encoded doc round-trips byte-exact.
  - **One accepted limitation:** on a true first run, between launch and the user dismissing the config-location dialog, `config_path` is unresolved so no lock/swap exists — edits in that sub-second window (during which the modal grabs input) are unrecoverable. Bounded and documented; not worth eagerly creating a swap dir the user may not have chosen.

### R3 — Lost update: external on-disk change silently overwritten **[OBSERVED, verified]**
- **Location:** `els::open` (1929-1933) caches `docPath/docEnc/docBom/docEol/docRaw` but **no mtime/size/ctime/hash**; `els::save` (1966) does no staleness check. grep for `file (mtime|stat|size|ctime)` against on-disk targets = 0 hits.
- **Trigger:** a file is open in els; another program (git checkout, format-on-save, cloud sync, a second els) rewrites it on disk; the user then saves. **Note: this is an everyday-save hazard, not crash-specific.**
- **Current behavior:** [OBSERVED] external `"v2-EXTERNAL-EDIT"` content replaced by the stale buffer; `save` returned **rc=1 (success), no prompt**; the external change is permanently gone.
- **Blast radius:** irreversible third-party data loss with no warning; common, mundane triggers.
- **Fix:** capture `file mtime`+`file size` (**and a content hash — required, not optional:** NTFS mtime is ~1 s granularity and two same-second writes produced identical mtimes in probes) at open and **re-cache after every successful save** (verified: els's own save advances mtime by 1 s — without re-caching, the *next* save false-positives as "externally changed"). Before writing, re-stat; on mismatch prompt **Overwrite / Reload / Save As**. The check wires into the **in-place truncate path** (els::save does *not* rename today — a finding-text reference to "re-check before the rename" pointed at machinery that doesn't exist; correct it to the actual write site).

### R4 — Silent lossy encoding substitution on save **[IMPLEMENTED 2026-06-10]**

> Shipped essentially as designed below: `els::save` encodes strictly and on
> failure asks keep-lossy / switch-to-UTF-8 / cancel, with the lossy consent
> latched per document and voided on an encoding change.  One design
> divergence found the hard way: in Tcl 9.0.3 the `-failindex` VALUE is a
> byte offset into the internal UTF-8 rep for some encodings (gb2312-raw)
> and a character index for others, contradicting encoding(n) -- only its
> sign is trusted, and `els::lossy_first` locates the failing character by
> binary search on prefix length instead.  Auto-save (also added) uses a
> quiet mode: lossy pauses auto-saving for the doc until a manual save
> settles it.  Tests lossy-1.1..1.8.
- **Location:** `els::save` els.tcl:1956 — `encoding convertto -profile replace $docEnc $text`.
- **Trigger:** buffer holds a character not representable in the document's encoding (euro in iso8859-1; any non-ASCII in a legacy single-byte codepage; or after a "Save with Encoding" downgrade). The picker (els.tcl:43-53) offers 9 lossy encodings, and any file auto-opened as a legacy codepage carries that `docEnc` forward — so a plain Ctrl+S loses data with no explicit lossy action.
- **Current behavior:** [OBSERVED] euro U+20AC written as byte `0x3F` (`?`); `save` returns **success, no warning**. Worse-hidden than expected: the buffer still *shows* the euro (open early-returns for an already-open path), so nothing reveals the loss until a fresh reopen.
- **Blast radius:** silent character corruption persisted to the user's real file.
- **Fix:** encode with `-profile strict` first (verified: throws `unexpected character at index 8: 'U+0020AC'`, and `-failindex` returns the partial result + byte offset, enabling position marking); on throw, prompt **keep-this-encoding-and-replace / switch to UTF-8 / cancel**; only fall back to `-profile replace` after explicit consent. No rename → **no atomicity/ACL/ADS pitfall** introduced. (`-failindex` is a *byte* offset into the encoded output → map to a text-widget index for marking; the "switch to UTF-8" branch should reconcile BOM/extension.)

### R5 — UI freeze in find/replace on a very long line **[OBSERVED]**
- **Location:** `els::find_update` els.tcl:2558-2568 (per-match `$w index "$s + $L chars"` and per-match `$w tag add`); `find_replace_all` ~2642 walks the same ranges with a `regsub` per match.
- **Trigger:** open a one-/few-line file (minified JS/CSS/JSON, single-line CSV, binary blob), open Find, type a common substring. `find_update` is **O(matches × lineLength)**.
- **Current behavior:** [OBSERVED] the *same* 5000 matches cost **23 ms across 5000 lines vs 8955 ms on one line (390×)**; a single 25,000-char line with 5000 matches **froze >60 s (OS-killed)**. The 130 ms debounce only coalesces a burst — it does not bound the cost of one evaluation, and Tcl being single-threaded, no `after`/event can preempt the spin (a watchdog `after` never fired).
- **Blast radius:** indefinite UI freeze; no data loss, but a hang on common input.
- **Fix:** in `find_update` (1) cap tracked/highlighted matches (`MAXHITS≈5000`, show `"N+"` in `find_count`); (2) replace the per-match loop with **one batched** `$w tag add findAll {*}$ranges`. Keep `find_replace_all` symmetric (cap + bounded, still reverse-order). Optional defense-in-depth: a wall-clock budget with periodic `update` for regex. *(Regex catastrophic backtracking is **not** the urgent item — the long-line tag-add loop is.)*

### R6 — No production `bgerror`; no diagnostic log **[CODE-READ + OBSERVED]**
- **Location:** the only `::bgerror` install is inside `if {$startupProbe}` (els.tcl:2876-2877). Normal launch installs none → Tk's default `tk::dialog::error::bgerror` modal-per-error ("raining dialogs"). No app-level log anywhere (the only `*.log` is `tests/helpers.tcl`'s, never created by the app). ~84 `catch {}` blocks swallow errors silently.
- **Trigger:** any uncaught error in an after-callback, binding, `<<Modified>>` handler, scrollbar/gutter redraw, or find-highlight in the shipped app.
- **Current behavior:** modal error storm the user must dismiss; no record of field failures (save errors, decode faults, recovery events); a GUI-subsystem build has no console.
- **Blast radius:** not directly data-loss, but masks/interrupts save flows and leaves field failures invisible.
- **Fix:** install a production `bgerror` (outside the probe guard) that **flushes all dirty swaps first** (once R2 lands), then **logs** to a small rotating `els.log` next to `els.conf` (~256 KB + one rollover, written via the temp+rename discipline, self-catching so logging can't crash the app), then shows **one** coalesced, de-duplicated, dismissible, parented notice — never a stack of modals; never exit.

### R7 — Restored geometry not clamped to a visible monitor **[OBSERVED]**
- **Location:** `els::load_geometry` els.tcl:281-283 — regexp-validates only the *format* `^[0-9]+x[0-9]+([+-][0-9]+){0,2}$`, then unconditionally `wm geometry . $g`.
- **Trigger:** window saved on a monitor since disconnected/rearranged (undock, projector, RDP at a different resolution), or a corrupt/hand-edited config.
- **Current behavior:** [OBSERVED] `+99999+99999` restored at `rootx=32780` off a 3840-wide screen; `-5000-5000` restored at `rootx=-1533 rooty=-3093`. Window is off-screen and unreachable; the user assumes els failed to launch. Recoverable only by editing/deleting `els.conf`.
- **Blast radius:** app appears dead; non-technical users can't recover.
- **Fix:** after parsing `WxH+X+Y`, if the title bar falls outside the virtual desktop (`winfo vrootwidth/vrootheight`, allowing for multi-monitor), reset the origin to a safe on-screen value (e.g. `+60+60`) while keeping the saved size, before `wm geometry`. Also persist/restore the **zoomed** state explicitly (today the raw zoomed geometry is stored as a normal window, which compounds the off-screen case). Pure Tcl.

---

## 3. Full failure-mode inventory

### Bucket A — Data loss / save integrity

| Mode | Trigger | Today | Risk | Fix |
|---|---|---|---|---|
| Non-atomic save truncates real file (R1) [OBSERVED] | Any failure between `open w` and `close` on a writable file | File 0 bytes the instant `open w` returns; original gone; `catch`→messageBox after the fact | **Critical** | Same-dir temp + `file rename -force` / `ReplaceFileW`; preserve ACL/ADS/hardlinks; delete temp on fail |
| Lost update silently overwritten (R3) [OBSERVED] | External program rewrites file after open; user saves | No mtime/size/hash captured or checked; stale buffer clobbers disk; rc=1, no prompt | **High** | Capture mtime+size+hash at open & after each save; re-stat before write; prompt on mismatch |
| Silent lossy encoding (R4) [OBSERVED] | Unrepresentable char in doc's encoding | `-profile replace` writes `?`; returns success, no warning | **High** | `-profile strict` first; prompt on throw; `replace` only on consent |
| No autosave/swap; dirty buffers lost (R2) [OBSERVED] | Crash/power-loss/kill/segfault with dirty tabs | Nothing written; 0 timers; no recovery | **High** | Per-dirty-doc atomic swap; startup orphan-scan + non-destructive recovery |
| Untitled buffers vanish with no trace (R2) [OBSERVED] | Abrupt exit with a never-saved buffer | `session_current_files` skips path=`""`; no record exists | **High** | Key swaps by sessionId+docId; recover as "Recovered (untitled)" |
| Recovery clobbers a file changed since crash [CODE-READ] | File changed on disk between crash and recovery | Naive re-save would destroy the newer disk version | **High** | Store `savedSig` in swap; reconcile on recovery; never auto-write |
| Vanished parent dir / disconnected share [OBSERVED] | Dir deleted / share/OneDrive/USB unplugged, then save | `save` returns 0, transient dialog; edits live only in buffer | **Medium** | Keep dirty (does); offer Save-As elsewhere; swap keeps a current copy |
| Atomic-fix: rename breaks hardlinks (R1 caveat) [OBSERVED] | Saving a hardlinked file via naive temp+rename | Sibling link keeps stale content; link severed | **Medium** | Detect nlink>1 / reparse / ADS → in-place fallback, or re-link |
| Atomic-fix: rename drops explicit ACL/ADS/EFS/compression (R1 caveat) [OBSERVED] | File with explicit ACE / ADS / EFS / compression | New temp gets only inherited ACLs; ADS gone (e.g. Zone.Identifier) | **Medium** | `ReplaceFileW`, or copy security descriptor + attributes onto temp; in-place fallback |
| Temp-file leak on crash (once R1 lands) [INFERRED] | Crash between temp write and rename | Orphaned `.tmp` in user's dir | **Low** | pid-tagged temp; clean stale temps on next open/save; delete in `catch` |

### Bucket B — Crash recovery

| Mode | Trigger | Today | Risk | Fix |
|---|---|---|---|---|
| No swap for unsaved edits (R2) [OBSERVED] | Any abrupt exit with dirty tabs | No swap machinery at all | **Critical** | Debounced+periodic atomic per-doc swap under `<configdir>/swap/` |
| No reconciliation against on-disk state [CODE-READ] | Recover after file changed/missing on disk | No mtime/sig; naive re-save destroys newer disk version | **High** | `savedSig` (size+mtime+hash) in swap; escalate prompt on mismatch; recover into dirty buffer only |
| Two instances collide on swaps [INFERRED] | Two els processes sharing a config dir (els has NO single-instance machinery — by design, any number may run) | A naive path-keyed swap → B overwrites A's swap; B treats A's *live* swap as a crash orphan | **Medium** | Per-run `sessionId` (pid + random token) + held byte-range liveness lock; scan skips live sessions |
| Uncaught error exits with no swap flush [OBSERVED] | Background error in shipped app | Tk modal; if it leads to exit, nothing flushed (no swap exists) | **Medium** | Production bgerror flushes swaps first (R6) |
| C-level segfault loses everything [CODE-READ] | Tcl/Tk C-level crash | The one class pure-Tcl can't pre-empt; nothing survives | **High** (residual) | Capstone (§7): SEH handler blind-writes pre-registered buffers to the **same swap format/dir** |

### Bucket C — Never crash / never hang

| Mode | Trigger | Today | Risk | Fix |
|---|---|---|---|---|
| Find/replace freeze on long line (R5) [OBSERVED] | Many matches on one very long line | 8955 ms / >60 s freeze; O(matches×lineLen) | **High** | Match cap + batched `$w tag add` |
| Synchronous find inside debounce (R5) [OBSERVED] | Any slow single search | Debounce coalesces but doesn't bound cost; whole app frozen | **Medium** | Primarily the cap; optional chunked search w/ wall-clock budget |
| No large-file guard [OBSERVED] | Open tens/hundreds of MB | Linear but no busy cursor, no warning; `docRaw` holds raw bytes 2-3× in RAM | **Medium** | `file size` check → confirm >~25 MB; busy cursor; drop/lazy `docRaw` for huge files |
| `refresh_view` full-buffer scans per edit [OBSERVED] | Editing large buffer | 3× full-buffer `$w get` per call; ~20 ms @200k lines (OK now) | **Low** | O(1) emptiness checks (`$w compare end-1c == 1.0`) |
| Binary / NUL / invalid-UTF input [OBSERVED] | Open arbitrary binary | Decodes safely (no crash); only the *shape* (no newlines) hits the long-line path | **Low** | Covered by R5 guards; optional "looks binary" confirm |
| Regex catastrophic backtracking [OBSERVED] | `(a+)+$` etc. | Tcl engine resists — ~0 ms | **Low** (downgraded) | Optional wall-clock budget as defense-in-depth |

### Bucket D — Environment survival

| Mode | Trigger | Today | Risk | Fix |
|---|---|---|---|---|
| Geometry off-screen, unreachable (R7) [OBSERVED] | Monitor disconnect/rearrange; corrupt config | Format-validated then applied verbatim; window strands off-screen | **High** | Clamp origin onto a visible monitor before `wm geometry` |
| Long paths fail in file dialogs / reg.exe [OBSERVED] | Path >260 chars, machine `LongPathsEnabled=0` | Tcl file layer copes; inherited `wish.exe.manifest` lacks `longPathAware` → dialogs/reg.exe MAX_PATH-bound | **Medium** | Add `longPathAware` manifest to built exe (tools/package.tcl) |
| Blurry on mixed-DPI multi-monitor [CODE-READ] | Drag between 150%/100% monitors | Manifest is `dpiAware=true` (system DPI), not PerMonitorV2 | **Low** | Set `PerMonitorV2` in same manifest change |
| Zoomed state persisted as raw geometry [OBSERVED] | Quit while maximized | Full-monitor size stored as normal window; intent lost | **Low** | Persist zoomed flag + normal geometry; restore then `wm state zoomed` |
| Recents/session on vanished net/removable path [OBSERVED] | UNC/USB/OneDrive path offline at launch | Handled gracefully (`file exists` check, Remove Missing); slow UNC may briefly block | **Low** | Optional: bound the validity probe off the UI critical path |

### Bucket E — Fail visibly & recoverably

| Mode | Trigger | Today | Risk | Fix |
|---|---|---|---|---|
| No production bgerror (R6) [CODE-READ+OBSERVED] | Any uncaught async error in shipped app | Only probe-branch bgerror; Tk modal "raining dialogs" | **High** | Production bgerror: flush swaps → log → one coalesced notice; never exit |
| No diagnostic log (R6) [OBSERVED] | Any field failure (save error, decode fault, async error) | Zero app-level logging; errors swallowed by ~84 catches | **Medium** | Rotating `els.log` next to `els.conf`; self-catching `els::log` |
| `save_geometry` fails silently [OBSERVED] | Read-only/full/locked config dir, or dir-as-config | `catch`→quiet `return`; prefs/session silently not persisted | **Low** | Log + one-shot non-modal status note (don't block quit) |

---

## 4. Prioritized hardening roadmap

Effort: **S** ≈ ½–1 day, **M** ≈ 2–4 days, **L** ≈ 1–2 weeks.

### P0 — Data loss (do first)

**P0-a. Atomic document save** — *M (not the optimistic "~6 lines"; ReplaceFile/attribute-preservation/`.bak` add real work).*
- *els.tcl:* rewrite the write block in `els::save` (1966-1970) to: encode (after the P1-c strict-encoding gate), write to `$docPath.els-tmp-<pid>` in the **same directory**, `flush`+`close`, then atomically replace. **Packaged build:** prefer Win32 `ReplaceFileW` (preserves ACL/ADS/attributes). **Pure-Tcl path:** detect hardlink (`file stat` nlink) / ADS / EFS / reparse → fall back to in-place rewrite after writing a one-generation `.bak`; otherwise `file rename -force`. Copy source attributes onto the temp where feasible. Delete the temp in a `catch`/`finally` on any failure (mirror els.tcl:342). Re-stat to refresh the R3 signature after a successful replace.
- *Tested:* the **`save-fault-*`** family (see §5) — rename the global `::open`/`::puts` (the reg-6.2 idiom) to throw mid-write; assert the on-disk file equals the pre-save bytes, `save` returns 0, doc stays dirty, exactly one messageBox, `els_test_bgerrors` empty. Positive twin: no `.tmp`/`.bak` residue after a clean save. **Plus** ADS-preservation and hardlink-sync assertions (both reproduced as regressions in verification). This family is **red today, green only after the fix**.

**P0-b. Autosave / swap + crash-recovery-on-restart** — *L.*
- *els.tcl — new subsystem:* `els::swap_dir`/`swap_path`/`swap_flush`/`swap_schedule`/`swap_clear` + a startup `recover_scan`/`recover_offer`.
  - Swap payload = a Tcl dict `{schemaVersion, sessionId, docId, docPath ("" for untitled), encoding, bom, eol, savedSig(size+mtime+hash), cursor ($w index insert), text}` — text stored **UTF-8 of the LF-internal buffer** (lossless; do **not** re-encode in the doc's lossy `docEnc`). Round-trips CJK/accents/tabs/embedded-NUL (verified).
  - One **atomically written** file per dirty doc (temp+rename **within** `<configdir>/swap/` — safe, no user ACL/ADS at stake). Write a length/checksum trailer so a half-written swap is detectable and discarded. Keep one prior generation against power-loss mid-rename.
  - **Filename keyed on `sessionId+docId`** (not basename — two open `notes.txt` would otherwise collide [verified]).
  - Wire `on_modified`→`swap_schedule` (debounced `after ~1500`, coalesced per id) **plus** a repeating `after ~30000` periodic flush. **Cancel both timers in `close_doc` and `quit`;** guard `swap_flush` with `winfo exists` + `doc_dirty` (safe even if a cancel is missed; verified that a clean `edit modified 0` makes a re-entered flush a no-op).
  - Clear a doc's swap on **clean save** (after `edit modified 0`), **clean close**, and **quit** (after `save_geometry`).
  - **Liveness lock:** per-run `els-<sessionId>.lock` (pid + start-time + random token); on startup, a swap whose sessionId has no live lock is orphaned. The scan skips this instance's and any *other live* instance's swaps.
  - **Recovery UX:** one consolidated dialog (not one modal per file). Reconcile `savedSig` vs current disk: match → "Restore unsaved changes"; changed/missing → escalate ("recover edits / keep disk version / save recovered copy as…"). **Recovery always lands in an in-memory dirty buffer; never auto-writes.** Layer over session restore: restore paths first, then apply matching swaps by path, then add untitled recovered buffers as new tabs (avoid double-opening a path).
- *Tested:* two layers (§5) — fast in-process unit tests of `swap_write`/`recover_scan`/`recover_offer` driven through the `tk_messageBox` stub; **plus** the process-level `ELS_STARTUP_PROBE` harness (write swap → recycle-safe PID+image taskkill → relaunch → assert recovery in the report dict). Multi-instance test: two simulated sessions don't recover each other's live swaps.

### P1 — Never hang / fail visibly

**P1-a. Find/replace long-line guard (R5)** — *S.* Cap (`MAXHITS≈5000`, `"N+"`) + batched `$w tag add findAll {*}$ranges` in `find_update` (els.tcl:2558-2568); symmetric in `find_replace_all`. *Tested:* a `perf-*` case mirroring ui-4.12 but with a **single long line** of thousands of matches, asserting `<500 ms` (the existing perf test is multi-line and misses the O(n²) case).

**P1-b. Production bgerror + rotating log (R6)** — *S–M.* `els::log {level msg}` (self-catching, temp+rename rollover, ~256 KB + one `.1`) next to `els.conf`; production `bgerror` outside the `$startupProbe` guard that flushes swaps → logs → shows one coalesced non-modal notice; also override `tk::dialog::error::bgerror`. Log startup, save failures, geometry clamps, config R/W failures, bgerror events. *Tested:* process-level — probe triggers a benign `after`-error, assert it's logged (under pinned LOCALAPPDATA) and the process stayed alive; in-process — a thrown after-error lands in the log path, not a dialog.

**P1-c. Strict-encoding gate (R4)** — *S.* `-profile strict` first in `els::save` (1956); prompt on throw; `replace` only on consent. *Tested:* `extmod`/encoding family asserts a euro-in-iso8859-1 save **prompts** instead of silently writing `0x3F`.

### P2 — Environment

**P2-a. Geometry clamp + zoomed state (R7)** — *S.* Clamp in `load_geometry` (281-283); persist/restore zoomed in `save_geometry`. *Tested:* feed `+99999+99999`, assert `rootx` within screen bounds.
**P2-b. External-modification detection (R3)** — *M.* Cache mtime+size+hash at open (1929-1933); **re-cache after every successful save** and on reload/Save-As; compare before write; prompt. *Tested:* `extmod-*` family — bump `file mtime` explicitly (deterministic, no clock wait); assert save prompts; cancel preserves the external bytes.
**P2-c. Large-file guard** — *S.* `file size` check + confirm + busy cursor in `els::open` (~1908); consider dropping/lazy `docRaw` for huge files. *Tested:* `perf-*` K-line load budget.
**P2-d. longPathAware + PerMonitorV2 manifest** — *S (build, not Tcl).* Embed/override the manifest on the produced exe in `tools/package.tcl` (~57-62).
**P2-e. `save_geometry` visibility** — *S.* Log + one-shot non-modal status note instead of silent return.
**Keep-as-is regression guards:** assoc injection-safety (assert a quote-laden exe path stays one argv element); corrupt-config + dir-as-config + vanished-session startup cases; "save fails on quit ⇒ exit not called".

### P3 — Native-port capstone (last)

**P3. C `WinMain` + SEH crash handler** — *L (separate effort, `docs/native-port-study.md`).* The **only** place to survive a Tcl/Tk C-level segfault with data intact. The handler runs in a corrupted process: **zero allocation, zero CRT I/O, zero Tcl API** — only raw Win32 (`CreateFileW`/`WriteFile`/`MoveFileExW`) over a **pre-registered** `{swapPath, bufferPtr, len, cursor, meta}` table that els keeps updated (els maintains a shadow snapshot of each dirty buffer — the Tk text widget has no stable flat `{ptr,len}`). It blind-writes each entry to `swapPath.tmp` + rename **into the same swap format/dir the P0-b Tcl path already scans**. **Hard prerequisite: P0-b ships first** — the Tcl layer (swap write + orphan detection + reconcile + prompt) is the heavy lifting; the C handler is a thin, write-only producer. The manifest work (P2-d) folds in here too.

---

## 5. Test strategy

The harness already has every primitive the hardening needs — `tests/helpers.tcl` sources `els.tcl` **in-process under `tclsh90` (console)**, stubs every modal dialog, captures `bgerror` to `els_test_bgerrors`, pins `APPDATA`/`LOCALAPPDATA`/`config_path` into `tests/_tmp`, and exposes `els_reset`/`els_text`/`els_tmpfile`. 268 tests run green (~75 s). The **fault-injection idiom already exists** (reg-6.2 renames `els::session_current_files` to `error boom`). New families:

- **`save-fault-*` (P0-a) — highest value, deterministic, red→green.** Promote a shared `with_open_failing {atWrite body}` helper into `helpers.tcl` (rename `::open`, install a stub that throws on `open`-fail or on the first `puts`/`close` to the temp channel; **always restore in `-cleanup`**). Add a `raw_read` helper to `helpers.tcl` (today it lives only in `ui.test`) and a counting `tk_messageBox` stub. Assert original survives byte-for-byte, `save`→0, `doc_dirty`==1, exactly one messageBox, `els_test_bgerrors` empty; plus ADS/hardlink preservation and read-only/vanished-target sub-cases.
- **`recover.test` (P0-b) — two layers.** In-process: call `swap_write`, assert a swap appears under pinned LOCALAPPDATA, `recover_scan`/`recover_offer` on a second `els_reset` offers exactly the orphan with text intact; accepting recreates a dirty tab, declining deletes the swap; untitled round-trip; two sessions don't recover each other's live swaps. Process-level: reuse `startup.test`'s `startup_probe`/`startup_wait_report` (recycle-safe **PID+IMAGENAME** taskkill — never blanket-kill els.exe) — write swap, kill, relaunch, assert recovery in the report dict.
- **`extmod-*` (P2-b/P1-c).** Set `file mtime $p [expr {[file mtime $p]+5}]` (settable, deterministic — no clock wait); assert save prompts (not silent clobber); cancel preserves external bytes; strict-encoding prompt on unrepresentable chars.
- **`perf-*` (P1-a/P2-c).** Long-line many-match search under a generous absolute cap (suite runs ~75 s loaded); K-line load budget; run pathological cases under an `after` watchdog so a true hang **fails the test** rather than wedging CI.
- **`fuzz-*` (defense-in-depth), gated behind a `fuzz` constraint (like `stress`).** Seeded LCG (reuse `rand_encs`): `detect_encoding`/`decode` never-throw on random/odd/truncated-multibyte/NUL bytes; open→save→reopen round-trip; random insert/delete/undo/redo invariant. Replayable on failure.

All families stay hermetic exactly as `helpers.tcl` guarantees (pinned dirs, stubbed dialogs, captured bgerror, `tclsh90` not `wish90`, `-cleanup` restoring any renamed command) — **no real registry write, no real crash, no raining dialog.** `run.tcl` already globs `tests/*.test`; add `fuzz`/`perf` constraints alongside `stress` so `--fast` stays quick.

---

## 6. Pitfalls & caveats

- **Atomic save is the trade, not a free win.** `file rename -force` on Windows is `MoveFileEx(REPLACE_EXISTING)` — atomic for same-volume NTFS, but the destination inherits the *temp's* metadata: **explicit ACLs, ADS (incl. Zone.Identifier / mark-of-the-web), compression/EFS, and hardlink identity are dropped** (all reproduced). It **fails on a read-locked target** (AV/indexer/OneDrive holding a handle) where in-place `open w` could write through — fails *cleanly* (original intact), a recoverable regression. **`ReplaceFileW`** (packaged build) preserves ACL/ADS/attributes by design; in pure Tcl, detect-and-fall-back-to-in-place for hardlinked/ADS/EFS files. Temp **must** be same-directory (same-volume) or rename degrades to non-atomic copy. **No fsync in Tcl 9.0.3** — durability against power-loss between rename and OS flush is no better than the existing atomic config save (acceptable; native port can add it).
- **mtime alone is insufficient for R3.** NTFS ~1 s granularity (FAT 2 s); same-second equal-size external edits evade an mtime+size check — **include a content hash**. And els's *own* save advances mtime by 1 s → **re-cache the signature after every successful save** or the next save false-positives.
- **Swap-file engineering (R2):** write the swap atomically (else a crash mid-swap yields a truncated swap, defeating the purpose); validate with a checksum/trailer; keep one prior generation; robust **liveness** (pid + start-time / lock token — PID reuse is real on Windows); **debounce** (`<<Modified>>` fires per keystroke and is fired programmatically by the app) — never write synchronously per keystroke; wrap the writer in `catch` so it can't itself raise into bgerror; store text **lossless UTF-8**, not the doc's lossy `docEnc`.
- **Swap collisions:** key by `sessionId+docId`, not basename; recovery scan must skip live sessions or a second running els's swaps get mis-claimed as orphans.
- **Regex timeout:** the cap+batch is the real fix; a wall-clock budget is optional defense-in-depth. The Tcl engine already resists classic catastrophic backtracking — don't over-invest here.
- **Recovery prompts and bgerror** must use the app's own parented, coalesced dialog (the known "raining modal dialogs" hazard), never Tk's default; recovery **never auto-writes** the user's file.
- **OneDrive/network targets:** `file exists` on a slow/offline UNC path can briefly block the UI (latency, not correctness) — consider bounding the validity probe off the UI critical path.
- **Harness teardown:** an observed `EXIT=124` on some probes was a **Tk-on-exit teardown hang in the headless harness** (clean `exit 0` returns `EXIT=0`), **not** an els defect — but the event loop can wedge at process teardown; worth knowing.

---

## 7. Sequencing & where the native port slots in

```
P0-a Atomic document save  ──► closes the #1 truncation window (everyday saves safe)
P0-b Swap + crash-recovery ──► closes the unsaved-edits/untitled-buffer hole
        │  (defines the swap FILE FORMAT + dir layout = the frozen contract)
        ▼
P1  Find/replace guard · production bgerror + log · strict-encoding gate
P2  Geometry clamp · ext-mod detection · large-file guard · manifest · save_geometry visibility
        ▼
P3  Native C WinMain + SEH crash handler  ──► CAPSTONE, depends on P0-b's swap format
```

The native port is **last, not first.** The Tcl swap+reconcile layer (P0-b) covers the common abrupt-exit classes a pure-Tcl idle/periodic writer *can* pre-empt — power loss, taskkill, OS reboot, bgerror-exit. A C-level segfault is the **residual tail** that only an OS-level SEH handler can survive, and that handler is near-useless without the Tcl reader that detects orphans, reconciles against disk, and prompts. So: **freeze the swap format/dir now** as the shared contract; ship the Tcl layer; add the thin, write-only C producer afterward. (P2-d's manifest naturally rides along with the native-port build work.)

---

## 8. Open questions

1. **Atomic-save mechanism for the packaged build:** commit to `ReplaceFileW` (needs a tiny C shim or a Tcl extension), or stay pure-Tcl with detect-and-fall-back-to-in-place for hardlink/ADS/EFS files? The pure-Tcl path silently drops ADS (e.g. mark-of-the-web) on every save of an ADS-bearing file unless special-cased.
2. **`.bak` policy:** keep a one-generation `$path.bak` on first overwrite (extra safety + an undo-the-save affordance) vs. no clutter in the user's directory?
3. **Autosave cadence & scope:** debounce/periodic values (1500 ms / 30 s proposed); do we also write swaps for *clean* docs to capture cursor/scroll, or dirty-only? Bound swap writing for very large buffers to avoid write-amplification.
4. **Recovery-vs-session-restore precedence** when both reference the same path: confirm the "restore paths first, then layer swaps by path, then add untitled" ordering avoids double-open in all cases.
5. **External-mod UX granularity:** also flag on window focus-in (not just at save), so the user sees a "changed on disk" banner before they keep editing a stale buffer?
6. **Large-file thresholds:** soft confirm at ~25 MB and a hard ceiling (refuse / open read-only)? And do we drop `docRaw` for huge files (losing zero-cost "Reopen with Encoding") to bound the ~2-3× RAM?
7. **Log location & retention:** `els.log` next to `els.conf` — but in portable mode that's the program dir (may be read-only on a locked-down machine); fall back to `%LOCALAPPDATA%`?
8. **Shadow-buffer cost for the SEH table (P3):** maintaining a flat `{ptr,len}` snapshot of each dirty buffer for the handler has an edit-time cost — acceptable, or only snapshot on the periodic tick?

---

**Files referenced (all absolute):** `els.tcl` (save 1943-1984; in-place write 1966-1970; saveas 1985-2016; atomic config save 336-342; load_geometry 281-284; find_update 2527-2577; main/bgerror 2858-2901), `tests/helpers.tcl`, `tests/ui.test`, `tests/startup.test`, `tests/run.tcl`, `tests/encoding_stress.tcl`, `tools/package.tcl`, `docs/native-port-study.md`.
