# els 0.93 — post-release review of the v0.92..v0.93 diff

**Date:** 2026-07-15 · **Range:** the single release commit `7f6aa9f` (v0.92..v0.93; 12,388 insertions / 1,618 deletions across 42 files) · **Baseline:** suite green at v0.93 (743/743).

**Method:** 113-agent workflow — 10 scoped finders (worker, state/recovery, lifecycle, tabs/status/menus, dialogs/focus/find-bar, Tcl 9 language sweep, native C, release tooling, tests audit, docs-vs-code) + a completeness-critic round (4 gap finders), every finding adversarially verified by 2 independent agents (a refuter obliged to kill it, and an impact assessor), several verified empirically with tclsh/compiled-C probes against the shipped Tcl/Tk 9.0.3.

**Result: 46 confirmed findings** — 2 critical, 5 major, 36 minor, 3 cosmetic. 3 candidate findings were refuted during verification (recorded at the end — two by empirical probe, one as a documented, probe-enforced design decision).

---

## R01 — Recovery dialog: a single unconfirmed Delete keypress permanently discards every preselected crash-recovery swap

**Severity:** critical · **Kind:** ux · **Location:** `els.tcl:5705`

**Evidence:** recover_offer preselects all non-missing entries (`$tree selection set $initiallySelected`, els.tcl:5671) and focuses the tree (`focus $tree`, els.tcl:5718); the new binding `bind ElsRecoveryTree <KeyPress-Delete> {els::recover_dialog_key [winfo toplevel %W] discard; break}` (els.tcl:5705-5706) routes straight to recover_dialog_apply -> recover_apply -> `file delete -force $f` (els.tcl:5564-5566) with no confirmation dialog, and the swaps are the only copy of the crashed session's unsaved text.

**Scenario:** els relaunches after a crash and the recovery chooser appears with keyboard focus on the fully-preselected list. The user presses Delete once (muscle memory from file managers where Delete moves to a recycle bin, or a stray keystroke aimed at the editor beneath) — every listed recovery record is irreversibly deleted on the spot; the dialog closes and the unsaved work from the crashed session is gone. v0.92 required a deliberate click on the "Discard checked" button; the keyboard path plus select-all default is new in 0.93.

**Verifier assessment:** After a crash, the recovery dialog opens with keyboard focus on a fully-preselected list; one stray Delete keypress permanently deletes (file delete -force, no confirmation, no undo) every recovery swap — the only copy of the crashed session's unsaved text. v0.92 required a deliberate button click; the unconfirmed keyboard path, select-all default, and tree focus are all new in v0.93, turning the data-protection feature into a one-keystroke irreversible data-loss trap.

---

## R02 — Replace-All worker commit during lossy_ask modal makes save write stale text and mark the replaced buffer clean (silent data loss)

**Severity:** critical · **Kind:** bug · **Location:** `els.tcl:6120`

**Evidence:** els::save captures the buffer at line 6092 (`set text [$w get 1.0 "end - 1 char"]`) BEFORE the lossy-encoding prompt at line 6120 (`switch [els::lossy_ask ...]`), then writes those bytes (6151) and unconditionally runs `$w edit modified 0` (6171), `set ::els::docRaw($id) $bytes`, `els::cache_saved_sig $id`, and `els::swap_clear $id` (6184). lossy_ask (5850-5852) does `grab $top; vwait ::els::lossy_answer` — vwait runs the full event loop, so the new v0.93 async find pipeline's `after 20 els::find_poll` / `after idle` chains fire during it (the project itself documents timers firing inside modal pumps at els.tcl:5293-5299). find_commit_replacement (7982) has no guard against a save in progress: its checks (doc active, docEpoch unchanged, signature, find_mode) all pass, so it executes `$w replace 1.0 "end - 1 char" $output` mid-prompt. The save then writes the pre-replacement `text`, and `edit modified 0` marks the now-different buffer clean; doc_dirty (2397) is exactly `$w edit modified`, and swap_clear has dropped the crash-recovery swap. In v0.92 Replace All was synchronous, so no mutation source existed inside lossy_ask; the async worker introduces one.

**Scenario:** Open a cp1252 document containing a character cp1252 cannot encode (e.g. '→'). Click Replace 'All' on a large document (worker runs for a second or more), then immediately press Ctrl+S. The 'cannot be written as Windows-1252' dialog appears; while it is open the worker finishes and rewrites the buffer ('Replaced N' appears behind the dialog). Click 'Save anyway' (or 'Save as UTF-8'): the file on disk gets the PRE-replacement text, yet the tab shows clean and the swap is deleted. Quit: no save prompt, autosave skips the 'clean' doc — the entire Replace All result is silently lost while the UI told the user it was applied and saved.

**Verifier assessment:** A user who presses Ctrl+S while a Replace All worker is still running on a non-UTF-8 document with unencodable characters gets the lossy-encoding dialog; the worker commits its buffer rewrite during that modal's vwait pump (no guard in find_commit_replacement detects the in-progress save), and the save then writes the pre-replacement text to disk, marks the mutated buffer clean, rebases docRaw/saved-signature to the stale bytes, and deletes the crash-recovery swap. The UI shows "Replaced N" and a clean saved tab, quit prompts nothing, and the entire Replace All result is silently and unrecoverably lost — silent data loss with the editor's saved/clean contract violated.

---

## R03 — Replace All worker can commit into the buffer beneath an open modal dialog (close/quit save prompt, external-change reload prompt)

**Severity:** major · **Kind:** bug · **Location:** `els.tcl:7982`

**Evidence:** The pipeline advances on `after 20` polls (find_poll, line 7513/7541) and `after idle` chains (7700, 7912), and find_commit_replacement (7982) has no modal/suspend guard — its only gates are doc==active, epoch, signature, find_mode. The codebase knows after-callbacks fire inside tk_messageBox's native pump: close_doc wraps its prompt in `set ::els::swap_suspend 1` (2466-2469) and swap_flush checks that flag (4849), and the comment at 5294-5296 says a drain must never run "while a modal is up". But neither close_doc (2465-2476) nor quit (6482-6493) nor the disk-change dialog cancels or pauses the in-flight find job before prompting, and the find pipeline consults no suspend flag, so all guards pass and `$w replace 1.0 "end - 1 char" $output` rewrites the document under the dialog. In v0.92 replace-all was synchronous, so no modal could interleave — this window is introduced by the new worker.

**Scenario:** User clicks Replace All on a multi-MB document (worker runs 1-2 s), then presses Ctrl+W. "Save changes to X?" appears; during its message pump the worker finishes and the whole buffer is silently replaced beneath the dialog. The user, judging by the text they last saw, clicks "No" — discarding a Replace All they were never told completed — or clicks "Cancel" and keeps a document that no longer matches what they read when deciding. Same interleave applies to the quit prompt and the file-changed-on-disk Reload prompt (a just-committed "Replaced N" is instantly obliterated by Reload).

**Verifier assessment:** During a slow Replace All (multi-MB doc, worker runs 1-2 s), pressing Ctrl+W or quitting opens the "Save changes?" prompt, and the async find pipeline — which has no modal/suspend guard (find_commit_replacement, els.tcl:7982) even though the codebase guards swap and handoff against exactly this tk_messageBox message-pump reentrancy — commits the whole-buffer replacement beneath the open dialog. The user then decides Yes/No/Cancel against content that silently changed: "Yes" saves a post-replace buffer they believed was pre-replace, "No" discards a completed Replace All they were never told finished, and the external-change Reload prompt can wipe out a just-committed replacement. No crash and the mutation is user-requested and undoable, so not critical, but it is a real save/discard-integrity race in a mainline flow introduced by the new async worker (v0.92 replace-all was synchronous and could not interleave with a modal).

---

## R04 — savedSig CRC format change breaks 0.92 swap baselines for >16 MiB files: false "file changed on disk" at recovery and on first save

**Severity:** major · **Kind:** bug · **Location:** `els.tcl:4771`

**Evidence:** v0.93 sig_from_bytes is now always full-CRC: `return "$size:$mtime:[zlib crc32 $bytes]"` and file_sig_probe CRCs every byte (els.tcl:4775-4810). v0.92 sampled head+tail 64K above SWAP_FILE_CRC_CAP (16777216). A 0.92 swap's savedSig for a >16 MiB file therefore never equals a 0.93 file_sig even when the file is byte-identical — empirically verified with tclsh: sampled sig 16777217:1000:264481398 vs full sig 16777217:1000:2209477596. recover_reconcile (els.tcl:5334-5341) then returns "changed" instead of "match", and recover_load pins savedSig($tid) to the stale-format sig (els.tcl:5500-5507), so the first save's R3 guard (sig_content compare, els.tcl:6051-6070) also fires extmod_ask claiming the file changed on disk. No format migration or fallback comparison exists.

**Scenario:** User edits a 20 MiB log in els 0.92, it crashes, they upgrade to 0.93 (same exe-adjacent config, so the swap IS found). The recovery dialog falsely labels the entry "file changed on disk since" although nothing touched the file. After recovering, Ctrl+S pops "changed on disk... Yes=overwrite / No=reload (discard our edits)". A user who trusts the (false) external-change claim and picks reload has the recovered unsaved text replaced by disk content with `edit reset` (undo history cleared) and the swap dropped — the crash-recovered edits are destroyed on the strength of a false conflict report.

**Verifier assessment:** A user recovering a crashed 0.92 session in 0.93 with a >16 MiB file gets a deterministic false "file changed on disk" verdict twice: the recovery dialog mislabels the entry, and the first Ctrl+S pops an external-modification conflict even though the file is byte-identical (0.92 stored a sampled head+tail CRC, 0.93 compares against a full CRC with no format migration). Choosing "reload" at the false prompt replaces the crash-recovered unsaved edits with disk content and clears undo — permanent loss of the recovered work, induced by misinformation in the one flow meant to protect it. Mitigated by narrow preconditions (>16 MiB file + crash under 0.92 + upgrade before recovery + user choosing reload; "overwrite" resolves correctly), and it is a one-time upgrade-transition hazard, so major rather than critical.

---

## R05 — Session tabs for network and >25 MB files silently migrate out of the saved session into the deferred queue with only one transient note

**Severity:** major · **Kind:** inconsistency · **Location:** `els.tcl:6279`

**Evidence:** session_restore: a deferred file is deliberately NOT added to session_pending (`elseif {![els::deferred_contains $p]}`, els.tcl:6279-6282) and has no tab, so save_geometry's session_files (open docs + pending, els.tcl:1053-1065) drops it from the persisted session on the first rewrite. read_binary_guarded defers EVERY remote path in quiet mode regardless of size (els.tcl:4192-4199) and every >OPEN_WARN_SIZE file. The only user signal is a single transient status note on the launch where the entry is new ("large file deferred - use File > Deferred Opens...", els.tcl:4430); subsequent launches show nothing (deferred_notice is only set for corruption, els.tcl:768-809), and no startup indicator reports a non-empty queue. This contradicts the adjacent session_pending design, whose stated purpose is that un-restorable files are "not dropped from the session" (comment els.tcl:6263-6266).

**Scenario:** A user's saved session includes two UNC-path documents (or one 30 MB log). After upgrading to 0.93, the next restart restores the local tabs, defers the UNC files, and rewrites session_files without them. The user misses the one-time status note; from then on those documents never reappear at startup and nothing indicates a pending queue — the tabs have silently vanished unless the user discovers File > Deferred Opens. In 0.92 the same session reopened all tabs.

**Verifier assessment:** Users upgrading to 0.93 with network-path or >25 MB files in their saved session lose those tabs at startup: session_restore defers them (els.tcl:4194-4199, 4206-4211) without adding them to session_pending (els.tcl:6279-6283), so save_geometry (els.tcl:1053-1065) rewrites the persisted session without them on the first run. The only signal is a single transient status note on the launch where the entry is first deferred; every later launch is silent (deferred_notice covers only corruption). The documents themselves are not lost — their paths sit in a durable Deferred Opens queue reachable via the File menu, and opening from that dialog restores the tab and its session membership — but nothing persistent points the user there, so from their perspective previously-restoring tabs silently vanish after the upgrade. This contradicts the adjacent session_pending design comment that un-restorable files are "not dropped from the session," confirming it is unintended rather than a deliberate tradeoff. Major (wrong user-visible behavior in the mainline session-restore flow, with a recoverable path), not critical (no data loss or corruption).

---

## R06 — Async find pipeline silently drops/cancels replace actions: repeated Replace presses lose replacements and passive keys cancel a running Replace All

**Severity:** major · **Kind:** ux · **Location:** `els.tcl:8059`

**Evidence:** find_request (8059-8071) unconditionally supersedes any in-flight job: `incr ::els::find_generation; els::find_cancel superseded; els::find_result_drop`. (a) find_replace_one (8196-8206) requires an adopted search result; after each replace-one request the result is dropped, so a second Enter in .find.rr.r while the first replace (or its follow-up search) is still in flight takes the `find_result_job eq ""` branch -> find_update -> find_request search, which KILLS the in-flight replace-one worker before it commits and performs no replacement itself. reason 'superseded' produces no message (find_cancel 7242-7246 only messages for user/changed). In v0.92 find_replace_one was synchronous — N Enter presses always made N replacements. (b) `bind .find.fr.q <KeyRelease>` (6780-6787) arms find_schedule for any key not in {Up Down Return KP_Enter} — including Left/Right/Home/End and the release of the Tab that traversed focus into the entry (now reachable since every findbar control changed to -takefocus 1); 130 ms later find_update -> find_request search cancels a running Replace All (busy button flips Cancel->All, 'Replacing...' becomes 'Searching...') with no 'Cancelled' notice, even though nothing changed.

**Scenario:** User opens Replace, finds a match, and taps Enter three times in the Replace field to replace three consecutive occurrences (the v0.92 and universal-editor idiom). Press 1 starts a replace-one worker; presses 2 and 3 arrive during the worker/search round-trips, kill the in-flight replace, and degrade into plain searches — the buffer ends with 0 or 1 replacements instead of 3, with no error. Similarly, during a long-running Replace All, pressing Home in the find entry to inspect the query silently cancels the whole replacement.

**Verifier assessment:** Verified in code: pressing Enter repeatedly in the Replace field (the standard replace-next idiom, which worked in v0.92's synchronous implementation) now silently kills the in-flight replace worker and degrades to a plain search, so N presses yield fewer than N replacements with no error — find_replace_one (els.tcl:8196) falls into find_update when find_result_job is empty (which find_request itself clears at 8071), and find_request (8059) unconditionally supersedes/cancels with a silent 'superseded' reason (find_cancel 7228 only messages for user/changed). Separately, the .find.fr.q KeyRelease binding (6780) excludes only Up/Down/Return/KP_Enter, so Home/End/arrow keys/Tab-release (entries are newly -takefocus 1) arm the 130ms debounce that cancels a running Replace All entirely and silently — the count flips from 'Replacing...' to 'Searching...' and zero replacements are applied. Not critical: the buffer is never corrupted or left partially edited (replace-all applies atomically at commit), and the visible match count lets users detect the miss — but it is silent wrong behavior in a mainline find/replace flow and a regression from v0.92.

---

## R07 — Handoff of a permanently-unopenable path retries forever: recurring status-bar notes and unbounded log growth, spool never expires

**Severity:** major · **Kind:** bug · **Location:** `els.tcl:5224`

**Evidence:** els.tcl:5224-5227 (handoff_drain): `if {[catch {els::open $p 1} openErr] || $::els::last_open_outcome ni {opened already deferred}} { lappend unresolved $p }` — any path that fails to open is re-queued with attempt+1 and notBefore=now+handoff_backoff (els.tcl:5153, capped at 30000 ms). There is no attempt ceiling and no quarantine for permanent failures, and swap_sweep no longer ages out *.open spools (els.tcl:5422-5425 now sweeps only `.ho-*.tmp *.invalid-*`; v0.92 swept `*.open` and deleted each spool after one drain attempt). Each retry runs els::open quiet, whose failure path (els::open_quiet_failure, els.tcl:4380) does `els::log error ...` plus `els::status_note "file not opened: [file tail $path]"` — i.e. a status-bar flash and a log line every <=30 s, forever, and the .open file persists across restarts.

**Scenario:** With a primary els running, the user launches `els.exe C:\gone.txt` (a deleted/renamed file, a typo, or a broken Explorer association target). The secondary spools the handoff and exits; the primary's open fails (file does not exist — it never will), so the request is rewritten with backoff and retried indefinitely: the status bar flashes "file not opened: gone.txt" every 30 seconds for the rest of the session AND every future session (the spool survives restarts and is exempt from the stale sweep), while the log grows by ~2900 error lines per day. The only escape is manually deleting the .open file. Same loop for an access-denied path. v0.92 deleted the spool after a single attempt.

**Verifier assessment:** If a user launches els with a path the primary can never open (deleted/renamed file from a stale shortcut, a typo, or an access-denied file) while an els window is already running, the handoff spool is retried forever: the status bar flashes "file not opened: <name>" for 4 seconds every ~30 seconds for the rest of the session and in every future session, since the .open spool survives restarts and is explicitly exempt from the stale sweep (els.tcl:5422-5425). The log accrues an error line per retry (bounded at ~512 KB by rotation, so "unbounded log growth" in the finding is overstated). There is no attempt ceiling, no quarantine for permanent failures, and no in-app way to stop it — the only escape is manually deleting the spool file from the config directory. This is a regression from v0.92, which deleted each spool after one drain attempt and skipped nonexistent paths.

---

## R08 — Accepted Replace All is silently discarded on tab switch, doc close, Escape/hide, or typing in the Find field — no cancellation feedback

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:7242`

**Evidence:** find_cancel shows "Cancelled" only for `$reason in {user changed}` (7242-7246). All other cancellations of an accepted Replace All (busy button already flipped to Cancel, count showing "Replacing...") are mute: switch_to → find_context_leave (2424, 7276) cancels with reason `context` and then find_update immediately overwrites the count with the new doc's search results; find_hide cancels with `hidden`; a keystroke in the Find query fires find_request which cancels with `superseded` and shows "Searching...". Nothing is applied (atomicity holds), but the operation vanishes without any notice. In v0.92 the operation was synchronous, so it could not be lost to a tab switch or keystroke.

**Scenario:** User clicks All on a large document, flips to another tab for a second while "Replacing..." is shown, and flips back: the replace was cancelled by the tab switch, the count now reads "1 of N" from the re-run search, the button is back to "All", and no message ever said the replacement did not happen — the user plausibly believes it did and saves/ships the unreplaced file.

**Verifier assessment:** An in-flight Replace All is silently cancelled by a tab switch, doc close, Escape/hide, or a Find-query keystroke: find_cancel (els.tcl:7242) shows "Cancelled" only for reasons {user changed}, so these paths give no notice and the count is immediately overwritten ("Searching...", "N of M"). Nothing is ever partially applied, and on returning the still-matching highlights and "N of M" count truthfully show the text was not replaced, so the UI does not actively mislead. The exposure window exists only while the async pipeline is running (large documents), making the ship-an-unreplaced-file scenario an edge case requiring both narrow timing and the user ignoring on-screen evidence. A real feedback regression vs v0.92's synchronous replace (and inconsistent with the Replace-field edit path, which does say "Cancelled"), but edge-case wrong behavior, not mainline: minor.

---

## R09 — Handoff spool retries permanently-failing paths forever: recurring status-bar note and log error every 30 s, across restarts, with no expiry

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:5226`

**Evidence:** handoff_drain marks any path whose quiet open fails as unresolved (`$::els::last_open_outcome ni {opened already deferred}` -> `lappend unresolved $p`, els.tcl:5224-5227) and rewrites the spool with attempt+1 and a backoff that caps at 30 s with no attempt limit (handoff_backoff, els.tcl:5153-5156; probed: backoff(1000)=30000). swap_sweep no longer ages out *.open spools — v0.92 swept `*.open .ho-*.tmp`, v0.93 sweeps only `.ho-*.tmp *.invalid-*` (els.tcl:5425) and the comment declares valid requests "never age out". A missing/deleted file, a directory argument, or an undecodable file fails els::open every time, so each ~30 s retry runs open_quiet_failure -> `els::log error` + `els::status_note "file not opened: ..."` (els.tcl:4380-4383), and the fsync'd spool rewrite (durable=1, els.tcl:5246) repeats indefinitely, surviving restarts.

**Scenario:** With an els primary running, the user double-clicks a file in Explorer, then deletes/renames it (or the shell hands off a directory) before the 500 ms drain picks it up. Forever after — including every future session — the primary flashes "file not opened: X" on the status bar every 30 seconds (masking other notes such as "crash protection is failing"), appends a log error each time, and rewrites the spool file with a durable flush; the request can only be cleared by manually deleting the .open file from the handoff directory. v0.92 consumed the spool after one attempt.

**Verifier assessment:** If a handed-off path fails permanently (file deleted/renamed before the 500 ms drain, a directory argument, or an unreadable file), the primary els instance retries it every 30 seconds forever — flashing "file not opened: X" on the status bar (potentially masking other notes), appending a log error each cycle, and durably rewriting the spool — persisting across restarts with no attempt cap, no age-out (v0.92's sweep of *.open was removed in v0.93), and no way to clear it except manually deleting the .open file from the handoff directory. Triggering requires an edge-case event, and there is no data loss or crash, but once triggered the nuisance is permanent.

---

## R10 — deferred_load quarantines the healthy queue on any transient read error, silently emptying the durable deferred-open list

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:799`

**Evidence:** deferred_load wraps `::open $p r` / read / parse in one catch (els.tcl:776-796); ANY failure — including a transient sharing violation or I/O error on a perfectly valid file (e.g. antivirus or a concurrent ELS_NO_SINGLE_INSTANCE instance mid-rewrite) — falls into the corruption handler which renames the file to `$path.corrupt-<stamp>` (deferred_quarantine, els.tcl:762-767) and starts this run with an empty queue. The entries were a "durability promise" (comment at els.tcl:847), and the same paths were already dropped from session_files (see session_restore), so after quarantine no els surface lists them; only the one-time note "corrupt deferred-open state was quarantined" hints anything happened.

**Scenario:** A user has three large files parked in Deferred Opens. At the next launch the els.deferred read hits a transient sharing violation (backup tool/AV holding the file). els renames the intact queue to els.deferred.corrupt-..., shows a brief status note, and the three files disappear from both the deferred dialog and the saved session — recoverable only by hand-inspecting the state directory. Distinguishing an open/read I/O failure (retryable, like handoff_drain does) from a parse failure (true corruption) would avoid discarding good state.

**Verifier assessment:** If the els.deferred state file hits a transient read error at startup (rather than actual corruption), the intact deferred-open queue is renamed to a .corrupt-* file and the user's parked files vanish from the Deferred Opens dialog with only a brief status note; recovery requires manually inspecting the state directory. However, the trigger is rare (a sub-1MiB local file read once per launch), the most likely transient cause — a sharing lock — usually also blocks the quarantine rename, which then preserves the file and lets the next launch load it normally, and even a successful quarantine preserves the bytes on disk with a log line naming the file. Real design flaw (read errors conflated with parse corruption, unlike handoff_drain which distinguishes them), but edge-case and recoverable rather than mainline data loss.

---

## R11 — "large file deferred" status note is wrong for small network files deferred by the remote-path rule

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:4430`

**Evidence:** els::open reports every deferred outcome as `"large file deferred - use File > Deferred Opens..."` (els.tcl:4430) and reload as "large reload deferred" (els.tcl:4273), but read_binary_guarded defers ANY remote path in quiet mode before any size check (els.tcl:4192-4199), so a 1 KB UNC file gets the "large file" message.

**Scenario:** A user double-clicks a 2 KB \\server\share\notes.txt while els is running; the primary raises with the note "large file deferred - use File > Deferred Opens...". The user concludes els mis-measured the file or is broken, since the file is tiny; the note should say the file is on a network path and awaits a deliberate open.

**Verifier assessment:** A user who opens a small network/UNC file via startup, session restore, or single-instance handoff sees the status note "large file deferred - use File > Deferred Opens..." even though the file was deferred because it is on a remote path, not because of size (els.tcl:4194-4199 defers any remote path in quiet mode before the size check; els.tcl:4430 and 4273 hardcode the "large" wording). The message is misleading — a 2 KB file gets called large — but the underlying behavior is correct and the note's guidance still directs the user to the right place (Deferred Opens), where the file opens normally. Impact is momentary confusion from a wrong reason string, not data loss or broken functionality.

---

## R12 — Startup file-argument open failures are now quiet: a failed double-click open shows only a transient status note instead of the 0.92 error dialog

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:8604`

**Evidence:** main now opens launch arguments with quiet=1 (`els::open $f 1`, els.tcl:8604); on failure the quiet path runs open_quiet_failure -> log + `status_note "file not opened: ..."` (els.tcl:4380-4383) and suppresses the `tk_messageBox` error. v0.92 called `els::open $f` (non-quiet) and surfaced "Cannot open file: <reason>" in a modal. The change is aimed at never posting a pre-UI modal, but a direct launch argument is the user's own deliberate action, not a background timer.

**Scenario:** A user double-clicks a .txt whose read fails (ACL denial, exclusive lock, path removed). els opens showing an empty untitled document plus a status note that clears after a few seconds; a user who glances away sees an empty editor with no explanation and no error detail (the reason is only in els.log), and may assume the file is empty.

**Verifier assessment:** A user who double-clicks a file that fails to read (permission denied, exclusive lock, path gone) gets an empty untitled editor with only a 4-second statusbar note ("file not opened: <name>") instead of 0.92's modal error with the reason; if they glance away they see an unexplained empty editor and may assume the file is empty. No crash or data loss (the buffer is unbound, so saving prompts Save As), the failure is logged, and the successful-open mainline path is unaffected — so this is degraded error feedback in an edge-case failure path, a real but minor regression.

---

## R13 — No WM_SAVE_YOURSELF handler: Windows logoff/restart kills els with no final swap flush, no session/geometry persist, and a phantom crash-recovery dialog on every next start

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:1987` · **pre-existing** (exposed, not introduced, by this diff)

**Evidence:** els registers only `wm protocol . WM_DELETE_WINDOW els::quit` (els.tcl:1987); grep confirms no WM_SAVE_YOURSELF handler anywhere in the repo. The Tk 9.0.3 manual (commands/wm.md) states: "On the Windows platform, a WM_SAVE_YOURSELF message is sent on user logout or system restart" and "if no handler has been installed for a protocol ... all messages of that protocol are ignored". Tk source (tclsrc/tk9.0.3/win/tkWinWm.c:8004-8018) confirms WM_QUERYENDSESSION synthesizes ONLY the WM_SAVE_YOURSELF protocol event (never WM_DELETE_WINDOW) and TkWmProtocolEventProc (line 6611) runs a registered handler synchronously via Tcl_EvalEx — so a handler could flush swaps and save the session before shutdown proceeds. With none registered, DefWindowProc returns TRUE and the OS terminates the process at WM_ENDSESSION with zero Tcl code running: els::quit, els::save_geometry, els::swap_shutdown, els::handoff_stop never execute. The last debounced/periodic swap flush (swap_debounce 400ms / swap_interval 2000ms, els.tcl:476-477) is the only protection.

**Scenario:** User has els open with a dirty document and clicks Start > Restart (or Windows Update forces a reboot). The process is killed at WM_ENDSESSION: (1) keystrokes typed in the last ~2.4s (since the last swap tick/debounce) are permanently lost; (2) session_files/geometry/prefs changes since the last save_geometry call are lost — tabs closed since then resurrect on relaunch; (3) the .lock/.listen files and all swaps are left behind, so the next launch treats a routine OS restart as a crash and pops the recovery dialog for every dirty doc — on every single reboot. The release is titled "resilient Windows lifecycle" yet the one OS-initiated lifecycle event has no handling.

**Verifier assessment:** On Windows logoff/restart, els is killed without running its quit path because no WM_SAVE_YOURSELF handler is registered (only WM_DELETE_WINDOW, els.tcl:1987). However, the continuous swap autosave (400ms debounce / 2s tick) bounds actual keystroke loss to roughly the last 0.4-2.4 seconds, and the existing crash-recovery path losslessly restores all other unsaved edits on next launch. The recovery dialog only appears if dirty documents existed (otherwise the stale-lock sweep silently cleans up), and geometry/session state is saved frequently during normal use, so drift is small. Real gap: an OS-initiated shutdown is treated as a crash instead of a clean exit, causing a recovery dialog after reboot when unsaved edits existed, possible resurrection of a just-closed tab, and loss of a couple seconds of typing. Annoying but well-mitigated edge-case behavior, not data corruption or major loss.

---

## R14 — quit's final handoff_drain consumes durable handoff requests into a dying non-session-owning instance, silently losing the open request

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:6499` · **pre-existing** (exposed, not introduced, by this diff)

**Evidence:** els::quit runs `catch {els::handoff_drain}` (els.tcl:6499) after the prompts; the v0.93 drain deletes a spool file once every path reports opened/already/deferred (els.tcl:5229-5235). The tabs it opens are then discarded: save_geometry (els.tcl:1067-1073) writes back the STORED session when session_owned==0 (explicit-file-arg launch), and swap_shutdown+exit follow immediately. v0.93 elsewhere promotes spool files to durable promises: swap_sweep now exempts *.open ("Valid handoff requests are durable delivery promises and never age out", els.tcl:5422-5423) and drain deletes only after delivery. The window is not tiny: handoff_tick refuses to drain while swap_suspend is set (els.tcl:5293-5301), and quit's "Save changes?" tk_messageBox sets swap_suspend (els.tcl:6484-6487), so every request spooled while the quit prompt sits open accumulates and is consumed by this one drain.

**Scenario:** Primary was launched by double-clicking a.txt (session_owned=0). User presses Ctrl+Q; the "Save changes?" prompt sits open for 30s. Meanwhile the user double-clicks b.txt in Explorer: the secondary sees the live .listen marker, spools b.txt, and exits 0 (delivered). User answers the prompt; quit's drain opens b.txt into the exiting process, deletes the spool, save_geometry writes the old stored session, exit. b.txt never appears in any window and is not in the next session — the durable delivery promise was consumed and dropped. Had quit skipped the drain, the next launch would have opened it.

**Verifier assessment:** If els was launched by double-clicking a file (so it never adopted the saved session) and the user double-clicks another file while els's quit "Save changes?" prompt is open (or within the ~500ms poll gap at quit), the second file's handoff request is consumed by the dying instance and silently dropped: it opens into a process that exits immediately, is not written into the persisted session (save_geometry writes back the stored session when session_owned==0), and the spool file is deleted. The file never appears in any window or the next session. No file contents are lost and re-double-clicking recovers, but the v0.93 "durable delivery" guarantee is silently broken in this timing window; skipping the quit-time drain for non-session-owning instances would let the next launch deliver it.

---

## R15 — handoff_send treats a durable-flush failure as total failure but leaves the already-published spool file behind, producing duplicate opens and a permanent second listening instance

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:5111`

**Evidence:** handoff_send calls `els::write_atomic $target $payload ... 1` and on any non-empty error returns 0 without deleting $target (els.tcl:5110-5115). But v0.93's write_atomic performs the atomic rename FIRST and only then `return [els::_durable_flush $path $durable]` (els.tcl:4602-4603); _durable_flush returns "DURABILITY: ..." when win_fsync fails (els.tcl:4543-4550). So on an fsync failure the spool file is fully published on disk while handoff_send reports failure, and els::main falls through to open locally ("If the handoff directory is unwritable/full, fall through and open locally", els.tcl:8570-8573). In v0.92 handoff_send was `catch {els::write_atomic ...}` and the caller always exited 0, so this published-but-reported-failed state is new.

**Scenario:** win_fsync on the handoff spool fails transiently (dying USB profile drive, AV filter). The secondary double-click launch falls through and builds a full second instance opening b.txt locally; the primary's 500ms poll drains the leftover spool and ALSO opens b.txt and raises itself. The user gets the same file in two windows, and the second instance registers its own .listen marker, so from now on two listening primaries race to drain the same spool nondeterministically until one quits. Fix direction: delete $target before returning 0 when the publish itself succeeded.

**Verifier assessment:** If fsync on the handoff spool file transiently fails (native build, e.g. flaky removable/network profile drive or AV filter), write_atomic has already published the spool via rename but reports failure; handoff_send returns 0 without deleting the published file, so the second launch falls through and opens the file locally while the primary also drains the leftover spool and opens the same file. The user ends up with the same document in two windows and two live listening instances racing on one handoff directory, risking a last-save-wins clobber between the windows. Mechanics confirmed at els.tcl:4602-4603 (rename before durable flush), 5110-5114 (no cleanup on failure), 8568-8573 (fallthrough to local open). Real defect, but gated behind a rare environmental fault rather than a mainline flow, hence minor; fix is to delete the published spool (or treat post-rename flush failure as success) before returning 0.

---

## R16 — Handoff retry loop has no terminal condition: a permanently unopenable local path is retried (with a status-bar note and log line) every 30 seconds forever, across restarts

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:5224`

**Evidence:** For an unresolved path, handoff_drain rewrites the request with attempt+1 and notBefore (els.tcl:5218-5249); handoff_backoff caps at 30000ms (els.tcl:5153-5156) and nothing ever caps the attempt count or quarantines a request whose paths permanently fail. swap_sweep explicitly exempts *.open files from aging (els.tcl:5422-5429), so the request survives every relaunch. Each retry calls `els::open $p 1`, whose failure path runs open_quiet_failure: `els::log error "quiet open failed..."` plus `els::status_note "file not opened: [file tail $path]"` (els.tcl:4380-4383). v0.92 deleted the spool file unconditionally after one consume attempt, so unbounded retry is new v0.93 behavior; the new retry design covers transient failures (locks, share hiccups) but has no path for permanent ones. There is also no UI to inspect or clear stuck requests (the Deferred Opens dialog covers only the deferred queue).

**Scenario:** User double-clicks report.txt while the primary is busy behind a modal; before the drain runs, the user deletes report.txt. The spooled request now fails on every drain: the status bar flashes "file not opened: report.txt" and els.log gains an error line every 30 seconds, indefinitely — and after quitting and relaunching els the next day, the retries resume, because the request never ages out and is never quarantined. Only manually deleting the file from the handoff directory stops it.

**Verifier assessment:** If a file handed off to a busy els instance becomes permanently unopenable (e.g. deleted before the drain runs), the spooled request retries every 30 seconds forever — flashing "file not opened: <name>" in the status bar and writing an error log line each time — and resumes after every relaunch, since handoff .open files are exempt from sweep aging and no attempt cap or quarantine exists for open failures. The only remedy is manually deleting the .open file from the handoff directory; no UI exposes stuck requests. Impact is bounded (log rotates at 256KB, no data loss or crash) and the trigger is an edge-case race, but once hit the nuisance is indefinite and un-clearable in-app.

---

## R17 — Drag-reordering tabs leaves two tabs showing the same identity (e.g. both 'untitled 1')

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:2771`

**Evidence:** tab_drag -> tab_repack -> tabs_layout, and tabs_layout relabels ONLY the active tab: `$activeW.name configure -text [els::tab_label [lindex $::els::docs $idx] ...]` (els.tcl:2771-2772). tab_identity (els.tcl:2524) is position-dependent: untitled docs are numbered by their position in $::els::docs, and elision-collision discriminators use `[lsearch -exact $::els::docs $id] + 1` (els.tcl:2628). So a reorder changes the active tab's computed identity while every other tab keeps the label refresh_tabs wrote for the OLD order; nothing else relabels until the next refresh_tabs. Probe against the real widgets (sourcing els.tcl v0.93 headlessly): before drag: 'untitled 1' | 'untitled 2'; after simulating tab_drag's reorder+tab_repack: tab(d0)='untitled 1' tab(d1)='untitled 1' — two tabs with identical labels; after the eventual refresh_tabs the documents silently swap names (d0 becomes 'untitled 2').

**Scenario:** User has two untitled tabs ('untitled 1', 'untitled 2'), clicks 'untitled 2' and drags it left past its neighbour. From that moment both tabs read 'untitled 1' — for as long as the user keeps working in the dragged tab (label refresh only happens on the next switch_to/close/save). The user can no longer tell the two buffers apart and can click the x on, or type into, the wrong one; when refresh finally runs, the two documents exchange their displayed names, compounding the confusion. Same mechanism corrupts the ' ·N' collision discriminators for same-named files.

**Verifier assessment:** Confirmed: tab_drag reorders els::docs and repacks via tabs_layout, which relabels only the active tab (els.tcl:2771), while tab_identity numbering and collision discriminators are position-dependent — so after dragging one untitled tab past another, two tabs briefly show the same name (e.g. both 'untitled 1') until the next refresh_tabs (tab switch/close/save), at which point the positional names swap. Real defect, but impact is a transient misleading label requiring multiple untitled or same-named documents plus a drag reorder; no data loss (dirty-close still prompts) and it self-corrects on the next tab interaction, which users perform constantly. Edge-case wrong behavior: minor.

---

## R18 — tabs_layout measures the active tab's frame reqwidth immediately after changing its label text, reading a stale value and over/under-packing the strip

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:2773`

**Evidence:** `$activeW.name configure -text ...` (els.tcl:2771) is followed on the next line by `set used [expr {[winfo reqwidth $activeW] + 1}]` (els.tcl:2773). A frame's requested size is recomputed by the packer in an idle callback, not synchronously (probe: label reconfigure changed the label's own reqwidth 76->505 instantly, but the containing frame stayed 112 until `update idletasks`, then 541). refresh_tabs (els.tcl:2726-2740) has the same flaw: it reconfigures every tab's label then calls tabs_layout synchronously. Probe reproducing the real startup sequence (active label previously laid out at pre-map width 1 as '…', then the map-time <Configure> layout runs once): packed=4 sum(reqwidth)=944 avail=855 overpack=1; last packed tab got width 146 vs reqwidth 235 (its right portion, including the x close button packed -side right inside the frame, is squeezed away), and tabs_layout_after='' with zero pending afters — nothing is scheduled to correct it.

**Scenario:** Launch els with several files on the command line (Explorer multi-select 'Open with els'): all opens run before the window maps, so the active tab is laid out at width 1 with a '…' label; the single map-time <Configure> relayout then under-measures the active tab by up to ~TAB_LABEL_PX and packs one tab too many. The right-most 'visible' tab renders squeezed against the ▾ button with its close button clipped into a dead/misleading click target, and stays that way until the user switches tabs or resizes. The synchronous refresh_tabs path (labels shrinking after closing an untitled tab, or growing when a same-basename file gains a 'parent/' discriminator) mis-sizes the neighbourhood the same way.

**Verifier assessment:** Real Tk staleness bug: tabs_layout (els.tcl:2771-2773) and refresh_tabs (2736-2740) read a tab frame's reqwidth immediately after reconfiguring its label, before the packer's idle-time geometry propagation updates it, so the tab strip can pack one tab too many (or too few). Worst case is launching els with several files before the window maps: the map-time layout under-measures the active tab by up to ~TAB_LABEL_PX, over-packs the strip, and the rightmost visible tab renders squeezed with its close button clipped; no corrective relayout is scheduled because .tabs itself never gets another <Configure>. However, the impact is purely visual and transient — it self-heals on any tab switch, resize, open/close, or other layout trigger; a misclick on the clipped close area only switches tabs (non-destructive); and the common refresh_tabs cases involve only small label-width deltas. Edge-case visual wrongness, not a broken mainline flow: minor.

---

## R19 — New .sb.disk indicator starves the status bar at narrow widths: release-update pill vanishes and the disk label clips to a misleading fragment

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:2142`

**Evidence:** Pack order in build (els.tcl:2135-2143): .sb.name, .sb.enc, .sb.sep_enc, .sb.eol, .sb.sep_eol, .sb.pos, then the NEW `pack .sb.sep_disk` / `pack .sb.disk -side right -padx {8 2}` and finally the pre-existing `pack .sb.update` — pack gives space in packing order, so update (the red 'newer release' notice) is now the first casualty and disk the second. .sb.disk is `-width 15 -anchor e` (els.tcl:2121), ~195 px of new demand. Probe at the app's own wm minsize width 360: .sb.update mapped=0 and .sb.disk mapped=0; at 500 px: .sb.update still mapped=0, .sb.disk mapped but squeezed to w=58 of req=195 — with -anchor e only the right-hand tail of the text shows, so 'Not on disk'/'Changed on disk' both render as a fragment ending in '…on disk'. In v0.92 the same right-side cluster fit comfortably at these widths (no disk label), so the update pill was visible.

**Scenario:** User keeps els as a narrow side-by-side window (anywhere near the permitted 360 px minimum): the new-release notice never appears even when an update is detected (regression vs 0.92), and the disk-state field — whose whole point is warning about external changes — either disappears or shows only a truncated right fragment such as 'on disk', which reads like the healthy 'On disk' state even when the full text is 'Changed on disk'.

**Verifier assessment:** Users who keep els in a narrow side-by-side window (roughly under 550-600 px, versus the 900 px default) lose the new-release notice entirely (a regression from v0.92, since the new 15-char disk indicator packed before it now consumes its space first) and see the disk-state label clipped from the right, e.g. "Changed on disk" truncated to "...on disk". The mechanism is confirmed by pack order and the fixed -width 15 request in els.tcl:2121/2135-2143. Impact is limited: at default and typical window widths everything fits; warning states render in the red accent color even when clipped, and the full state is available via tooltip; the update pill is advisory, not a gating feature. Edge-case wrong behavior, not a mainline flow or data-integrity issue.

---

## R20 — Clicking the ▾ overflow button while its tooltip is visible leaves the topmost tooltip floating over the open menu

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:2086`

**Evidence:** `bind .tabs.more <Button-1> els::tabs_popup` (els.tcl:2086) is installed BEFORE `els::tooltip .tabs.more "All open documents"` (els.tcl:2091), and els::tooltip appends its dismiss with `bind $w <ButtonPress-1> {+els::tip_cancel}` (els.tcl:6872) — so on click, tabs_popup runs first and tip_cancel only after it returns. tabs_popup ends in tk_popup (els.tcl:2825), which on Windows enters a native modal menu loop and does not return until the menu is dismissed. The .tip toplevel is override-redirect and `-topmost 1` (els.tcl:6909). The codebase itself acknowledges this ordering requirement elsewhere: `bind .sb.update <Button-1> {els::tip_cancel ; els::open_url ...}` (els.tcl:2152) cancels the tip before its blocking action.

**Scenario:** User hovers the ▾ all-documents button for ~550 ms so the 'All open documents' tooltip pops, then clicks it: the overflow menu opens with the stale topmost tooltip stuck floating above/over it for the entire time the menu is posted, only disappearing when the menu closes. (The same pattern exists for the tab right-click context menu via make_tab, but that ordering predates 0.93; the ▾ instance is new.)

**Verifier assessment:** A user who hovers the tab-strip overflow (▾) button long enough for its "All open documents" tooltip to appear (~550 ms) and then clicks will see the tooltip remain stuck floating on top of the opened documents menu for as long as the menu is posted, potentially obscuring the top menu entry. The menu itself works normally and the tooltip vanishes when the menu closes; impact is a visible but transient rendering glitch with no functional or data consequence.

---

## R21 — Dialog buttons marked -default active never respond to Enter (Tk 9 ttk::button has no Return binding)

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:5829`

**Evidence:** v0.93 adds `-default active` to buttons in lossy_ask (5829, 5835), goto_line ('Go', 8232), recover_offer ('Recover selected', 5681), deferred dialog ('Open selected', 1277-1278), recent-manage ('Open', 1441), and file-associations ('Register els with Windows', 1852 / Close 1857). ttk_button.md describes -default active as “the one that gets invoked when the user presses <Enter>”, but no toplevel <Return> binding was added, and empirically in Tk 9.0.3 `bind TButton` contains only <Key-space> (no <Key-Return>) and `event info <<Invoke>>` maps no physical event. lossy_ask even sets keyboard focus ON the default button (5849): the modal save dialog draws a default-highlighted, focused button that ignores Enter entirely (only Space works). Enter works in these dialogs only where an entry/tree/listbox has its own explicit binding.

**Scenario:** The 'cannot be written as Windows-1252' save dialog appears with 'Save as UTF-8' visually highlighted as the default button and focused. The user presses Enter — the Windows-standard way to accept a dialog's default — and nothing happens; likewise Enter does nothing after tabbing to the ring-highlighted default button in Go to Line, the recovery dialog, Deferred Opens, or File Associations.

**Verifier assessment:** Verified: Tk 9.0.3's TButton class binds only Space and the unmapped virtual <<Invoke>>, and els adds no toplevel <Return> bindings, so every v0.93 '-default active' button draws the Windows default-button ring but ignores Enter. Worst in the modal lossy-save dialog (els.tcl:5806-5858), which focuses the highlighted 'Save as UTF-8' button yet Enter does nothing (only Space/click work); in Go to Line, Deferred Opens, Recent, and Recovery the entry/list widgets have their own Enter bindings so the mainline keyboard path still works and the dead spot appears only after tabbing to the button. No data loss or blocked flow — a platform-convention keyboard-UX defect with trivial workarounds, hence minor rather than major.

---

## R22 — Find-bar count label (fixed width 16, anchor e) clips the new long worker status/error messages

**Severity:** minor · **Kind:** ux · **Location:** `els.tcl:6731`

**Evidence:** `.find.fr.n` is `ttk::label ... -width 16 -anchor e` (6731-6732) inside the .find.fr.ctrl frame that is frozen at build time with `pack propagate $c 0` (6764-6770). v0.93 routes new, much longer strings into ::els::find_count: 'Find worker returned invalid data' (33 chars), 'Find unavailable (worker control missing)' (41), 'Document cannot be encoded for search' (38), 'Document too large to search' (28), 'N of M+  (navigation limit)'. With a fixed 16-average-char width and -anchor e, the leading part of each message is clipped with no ellipsis, so the user sees only an uninterpretable tail fragment.

**Scenario:** Run els from source without build/winfs.dll and press Ctrl+F, or search a >256 MiB document: the count slot shows a clipped fragment such as '...ntrol missing)' or '...ge to search' instead of the actual diagnostic, leaving the user with no readable explanation of why find is unavailable.

**Verifier assessment:** The find-bar status label (els.tcl:6731, fixed -width 16, -anchor e, inside a frame frozen with pack propagate 0) left-clips the new v0.93 diagnostic strings with no ellipsis, so messages like "Find unavailable (worker control missing)" (41 chars) or "Document too large to search" (28 chars) show only an uninterpretable tail fragment. Verified: these strings are routed straight into ::els::find_count (find_pending_fail 7171, find_result_fail 7565) with no tooltip or other display surface. Impact is limited to error/edge paths — source runs missing build/winfs.dll (dev scenario; the packaged exe registers the worker commands statically), documents over 256 MiB, worker output corruption, or the 1,000,000-match navigation ceiling. Normal counts ("3 of 12", "No results", "Replaced N") fit and display correctly, so the mainline find/replace flow is unaffected; the cost is lost diagnosability when find fails, not lost functionality or data.

---

## R23 — Worker run_job's `trap {*}` handler never matches, so its error-normalization path is dead code

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:279`

**Evidence:** els.tcl:279 `} trap {*} {e o} { set status error ; set err $e }`. Per try(n), a trap pattern is matched as a LIST PREFIX of the error's -errorcode; `{*}` only matches an errorCode whose first word is the literal string "*". Empirically verified on tclsh 9.0.3: both `try {error boom} trap {*} ...` and `try {throw {FOO BAR} boom} trap {*} ...` propagate uncaught (probe output: 'outer catch rc=1'). Every `error` raised inside the try — "worker deadline exceeded", "regex engine returned an invalid range", "replacement output exceeds limit" (append_output), "match offset overflow" (record) — therefore bypasses the handler (the finally still closes $mf) and unwinds to ::elsworker::main's catch, which writes the generic fallback record `kind unknown source_chars 0 ...`. The parent (els::find_process_result, els.tcl ~7620) then fails its `[dict get $result kind] ne [dict get $job kind]` identity check and reports "Find worker returned invalid data" instead of the structured status/message this handler was written to publish. The catch-all spelling is `on error` (or `trap {}`).

**Scenario:** User runs Replace All with a catastrophic-backtracking regex on a large document. The worker hits its 30 s deadline and raises "worker deadline exceeded"; because the trap never fires, the run_job self-check/normalization block (zeroing output fields, bounded per-kind failure record) is skipped and main writes the kind-unknown fallback. The find bar shows the misleading "Find worker returned invalid data" instead of a worker-failure/timeout message, and the same happens for a disk-full failure while writing matches.idx.

**Verifier assessment:** Confirmed dead code: `trap {*}` in worker run_job (els.tcl:279) never matches errors raised with `error` (errorCode NONE), verified empirically on the shipped tclsh 9.0.3. Worker-internal failures (30 s deadline, invalid regex range, output/match-limit overflows, disk-full on the index) bypass the structured-failure path and hit main's kind-unknown fallback, which the parent rejects at the source-identity check (els.tcl:7619). User-visible effect: the find bar shows "Find worker returned invalid data" instead of "Find worker failed" — one generic message instead of another, since the parent's status switch (els.tcl:7677) never surfaces the specific error text anyway. All failure paths still fail safe: the document is never modified, no data loss or corruption is possible. Impact is limited to a misleading error string in rare edge-case failures, so this is a minor (not major) defect; the fix is trivial (`on error` or `trap {}`).

---

## R24 — v0.93 handoff record is silently destroyed by a still-running v0.92 primary: double-clicked file never opens anywhere

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:5108`

**Evidence:** v0.93 handoff_send (els.tcl:5107-5110) writes the new record format unconditionally: `set record [dict create schema 1 paths $norm attempt 0 notBefore 0]` / `encoding convertto -profile strict utf-8 "ELSHANDOFF v1\n$record"`, and main (els.tcl:8568-8573) then `exit 0`s, treating the spool as durably delivered. The spool file name (`[pid]-[clock clicks].open`), the `<sid>.listen` marker and the lock protocol are unchanged from v0.92, so a v0.93 launch in a shared state dir DOES hand off to a live v0.92 primary. But v0.92's handoff_drain (v0.92 els.tcl:3669-3686) decodes the record as ordinary UTF-8 (probe-confirmed: strict convertfrom succeeds), unconditionally `file delete -force`s the spool after reading (v0.92:3678), then does `foreach p [split $data \n] { if {$p ne "" && [file exists $p]} { catch {els::open $p 1} } }` — line 1 is the literal "ELSHANDOFF v1" and line 2 is the dict string "schema 1 paths C:/... attempt 0 notBefore 0", neither an existing file, so nothing opens and the only durable copy is gone. v0.92 has no magic check and no quarantine; the same fate meets a pending v0.93 retry record via v0.92's sweep, which deletes any handoff *.open older than STALE_SECS=45s (v0.92:3861) — the exact files v0.93's sweep comment (els.tcl:5422-5423) declares "durable delivery promises [that] never age out".

**Scenario:** Portable in-place upgrade: els 0.92 is running from C:\tools\els (adjacent els.conf, lock + .listen in C:\tools\els\swap). The user drops the 0.93 exe into the same folder (old process keeps running) and double-clicks notes.txt in Explorer. The 0.93 process sees the live 0.92 .listen, spools "ELSHANDOFF v1\nschema 1 paths C:/.../notes.txt attempt 0 notBefore 0" and exits 0 reporting durable delivery. Within 500 ms the 0.92 primary reads the spool, deletes it, opens NOTHING (neither line is an existing file) and merely raises its window. The user's open request is silently lost — the old window comes to front without notes.txt, and no error, log entry or retry exists in either process.

**Verifier assessment:** During a version-skew window (a still-running v0.92 primary sharing a state dir with a newly launched v0.93 binary), a double-clicked file is silently never opened: the v0.93 secondary spools the new dict-format record and exits 0, and the v0.92 primary decodes it as plain UTF-8, deletes the spool, finds no line that is an existing file, and merely raises its window — no error, log, or retry in either process. Verified against both tags: v0.93 els.tcl:5107-5110/8568-8573 and v0.92 handoff_drain (delete-after-read, file-exists gate, no magic check). Real forward-compat defect, but the trigger requires the old process to keep running while the new exe launches from the same folder (running exes cannot be overwritten on Windows, so mainly dev/tclsh runs or renamed-exe upgrades), the condition ends when the old instance exits, and no document data is lost or corrupted — the file is recoverable via File > Open. Edge-case wrong behavior, not a mainline or release-gating failure.

---

## R25 — Drain retries a never-openable handoff path forever: immortal spool plus a 'file not opened' status nag every 30s, with no expiry or quarantine

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:5224`

**Evidence:** v0.93 handoff_drain (els.tcl:5218-5250) treats any path whose quiet open fails as `unresolved` (`$::els::last_open_outcome ni {opened already deferred}`) and rewrites the spool with attempt+1 and a backoff that hard-caps at 30s (`handoff_backoff`: `min(30000, 250*(1<<exponent))`, els.tcl:5153-5156). There is no terminal state for a permanently failing path: quarantine only covers invalid/oversize records (els.tcl:5201-5208), and swap_sweep explicitly excludes *.open ("Valid handoff requests are durable delivery promises and never age out", els.tcl:5422-5425). Every failed attempt calls open_quiet_failure (els.tcl:4380-4383), which posts `status_note "file not opened: [file tail $path]"` and a log error — i.e. every <=30s, forever, surviving restarts. Both v0.92 defenses were removed in this diff: v0.92's drain skipped nonexistent paths (`if {$p ne "" && [file exists $p]}`, v0.92:3684) and its sweep aged *.open out after 45s (v0.92:3861). The mixed-version trigger is direct: a stale legacy 0.92 spool (crashed 0.92 primary, never drained) survives the upgrade because 0.93 never sweeps *.open; the 0.93 primary decodes it via the legacy branch (handoff_decode els.tcl:5129-5130), and if its file has since been deleted the newline path is converted into an immortal v1 retry record.

**Scenario:** els 0.92 crashes with an undrained handoff spool naming C:\temp\draft.txt; the user later deletes draft.txt and upgrades to 0.93 in place. On the next 0.93 start the drain adopts the stale spool, the open fails (file missing), and the request is rewritten as a v1 retry record. From then on — every session, forever — the status bar flashes "file not opened: draft.txt" every 30 seconds and els.log accumulates a 'quiet open failed' error per attempt; the .open file can only be removed by manually deleting it from the handoff folder. The same loop starts in pure 0.93 whenever a handed-off file is deleted (or stays permanently access-denied) before delivery.

**Verifier assessment:** Verified as described: v0.93's handoff drain has no terminal state for a path that can never be opened (deleted, access-denied, dead share) — the spool record is rewritten forever with a backoff capped at 30s, and both v0.92 defenses (skip nonexistent paths; sweep *.open after STALE_SECS) were removed, so the loop survives restarts including a stale 0.92 spool adopted after an in-place upgrade. Once triggered, the user gets a "file not opened: <name>" status-bar flash and an els.log error every ~30 seconds in every future session, fixable only by manually deleting the .open file from the handoff folder. The trigger is edge-case (normal handoffs drain within ~500 ms; it takes a crashed/undrained spool or a file removed before delivery), and there is no data loss, corruption, or crash — the editor stays usable — so this is edge-case wrong behavior, though at the severe end of minor (borderline major) because the degradation is permanent and has no in-app recovery.

---

## R26 — Profile-configured 0.92 primary is invisible to 0.93: both instances run as primary, same document editable in two windows with no handoff

**Severity:** minor · **Kind:** inconsistency · **Location:** `els.tcl:714`

**Evidence:** v0.92 config_roots returned {progdir, %LOCALAPPDATA%\els} and its first-run dialog RECOMMENDED the profile location (v0.92:249-378), so a typical 0.92 install keeps els.conf, the swap dir, the session lock and the .listen marker under %LOCALAPPDATA%\els. v0.93 config_roots (els.tcl:714-728) returns only the exe-adjacent dir, and primary_running (els.tcl:5065-5083) scans only `[file dirname [lindex [els::config_candidates] 0]]/swap`. A live 0.92 primary's lock/.listen in the profile dir is therefore never probed: the 0.93 launch sees no primary, becomes one itself, and vice versa a stale 0.92 shortcut launched while a 0.93 primary runs resolves the profile config (v0.92:295-311) and boots as a second primary — additionally restoring the OLD profile session, i.e. immediately re-opening the same files already open in the 0.93 window, with autosave enabled in both. README.md deliberately documents ignoring "old profile-stored els state" (no fallback/migration), but nothing detects or warns about the live-instance overlap; the per-config-dir single-instance promise (els.tcl:5049) silently stops holding across the upgrade boundary.

**Scenario:** A user whose 0.92 keeps settings in the recommended profile location upgrades the exe in place while their 0.92 window (with open tabs) is still running, then double-clicks report.txt. Instead of report.txt opening as a tab in the existing window (the pre-upgrade behavior), a second full editor appears; report.txt may already be open and dirty in the 0.92 window. Edits now diverge between two windows holding the same file — the R3 changed-on-disk guard fires only at the next save, where picking overwrite discards the other window's saved changes. The 0.92-side crash swaps and session in %LOCALAPPDATA%\els additionally never surface in 0.93 (documented, but combined with the silent dual-primary window the upgrade path invites confusion and lost edits).

**Verifier assessment:** Only during the transient upgrade window where a still-running v0.92 instance (with profile-stored config) coexists with a first v0.93 launch: opening a file spawns a second primary window instead of handing off to the old one, and the same document can be edited in both. Divergence is caught by the changed-on-disk guard at save (loss requires explicitly choosing overwrite), autosave is off by default, swap dirs are separate, and the situation self-resolves once the old window closes. Single-instance remains per-config-dir as documented, and ignoring old profile state is an explicit v0.93 design decision; the gap is merely the absence of a warning about a live legacy instance.

---

## R27 — reload_from_disk and reopen_with discard recovered content without recover_source_drop, so a retained recovery orphan is re-offered after the user explicitly discarded it

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:4298`

**Evidence:** reload_from_disk (els.tcl:4295-4301) does:  unset -nocomplain ::els::docLossyOk($id) ... ; els::cache_saved_sig $id ; unset -nocomplain ::els::docRecovered($id) ; $w edit reset ; $w edit modified 0 ; els::swap_clear $id  — it clears docRecovered and the current-session swap but never calls els::recover_source_drop, leaving ::els::docRecoverySource($id) set and the old-session orphan .swp on disk. reopen_with has the identical gap at els.tcl:4097 (unset -nocomplain ::els::docRecovered($id) ::els::docExtModPause($id), no recover_source_drop). Contrast the two paths that WERE taught about the new v0.93 retained-source machinery: close_doc calls els::recover_source_drop at els.tcl:2480 ('saved or explicitly discarded: old orphan is no longer needed') and save calls it at els.tcl:6183. After the reload the doc is clean, so every later swap_flush_doc pass exits at the '![els::doc_dirty $id]' early-return (els.tcl:4853) and never reaches the recover_source_commit retirement call at els.tcl:4900 — the orphan is permanent until the doc is re-dirtied or the tab is closed. Verified empirically with a headless tclsh 9.0.3 probe (source els.tcl, els::build, recover_apply with swap suspended to force retention, then els::reload_from_disk): output was 'A post-reload: recovered=0 source=1 orphan=1', 'A post-flush: flush=0 source=1 orphan=1', and a subsequent els::swap_scan_orphans still offered the discarded text ('recovered unsaved A'); the reopen_with case printed 'B post-reopen: recovered=0 source=1 orphan=1'. The docRecoverySource/recover_source_commit/recover_source_drop machinery is entirely new in v0.93 (zero occurrences in v0.92's els.tcl), so this omission is introduced by this release.

**Scenario:** User's els crashes with unsaved edits; on relaunch they accept the recovery, but the first current-session swap write fails (disk briefly full / swap dir ACL hiccup), so the old orphan is deliberately retained (status note 'original safety copy retained until crash protection succeeds', els.tcl:5582) and docRecoverySource stays set. The user decides the recovered text is wrong and runs File > Reload from Disk, confirming 'Unsaved changes will be lost' — or Reopen with Encoding, confirming the same. The buffer now matches disk and the doc is clean, so no swap pass ever retires the orphan. On the NEXT launch (or a second crash), the recovery dialog re-offers 'unsaved changes' for that file — pre-selected, one Enter away from merging back into the clean tab — containing exactly the content the user already explicitly discarded; an inattentive user re-recovers and saves stale pre-crash text over the current file.

**Verifier assessment:** After a crash-recovery whose first replacement swap write failed (rare degraded state: disk full / swap-dir ACL failure), a user who then explicitly discards the recovered text via File > Reload from Disk or Reopen with Encoding will have the stale pre-crash safety copy silently retained; on the next launch the recovery dialog re-offers content they already discarded, and an inattentive re-accept plus save could overwrite the current file with stale text. Requires a multi-step unlikely precondition chain and active user confirmation to cause harm; the direct symptom is a confusing spurious recovery offer and a leaked .swp file.

---

## R28 — els::save's decision prompts (incl. the new extstate_ask/decode_lossy_ask) pump with swap_suspend==0, so handoff_drain opens and switches tabs beneath the modal

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:6079`

**Evidence:** handoff_tick's only guard is `if {!$::els::swap_suspend} { catch {els::handoff_drain} }` (els.tcl:5300), and its comment (5294-5299) states the invariant: "Never drain while a modal is up (swap_suspend marks one): the drain opens files and switch_to's them, and an after-timer fires during a native tk_messageBox's message pump". But els::save — reached with swap_suspend==0 from Ctrl+S (`bind . <Control-s> { els::save }`, els.tcl:2250), from close_doc's yes-branch (suspend is cleared back to 0 at els.tcl:2469 BEFORE `els::save` at 2473), and from quit's yes-branch (cleared at 6487 before `els::save $id` at 6490) — pumps up to five modals without ever setting the guard: `switch [els::extmod_ask $id]` (6066), `if {![els::extstate_ask $id $state $detail]} { return 0 }` (6079, NEW in 0.93), `if {![els::decode_lossy_ask $id]} { return 0 }` (6089, NEW in 0.93), `els::lossy_ask` (6120, a grab+`vwait ::els::lossy_answer` dialog at 5852 — vwait(n): "enters the Tcl event loop to process events", so the 500 ms handoff_tick fires), and the save-error box (6166). The interactive open-error boxes (4419, 4472) and the large-open consent prompts (4214, 4234) are equally unguarded. While any of these is up, handoff_tick fires within 500 ms and handoff_drain runs `els::open $p 1` (5224), which calls `els::switch_to` (4395/4512): a new tab is created, `set active $id` + `focus $w` (2434-2437) move the active document, keyboard focus and the visible buffer out from under the destructive prompt, and `els::raise_window` (5251) deiconifies/raises/topmost-flips the toplevel beneath the modal. v0.93 itself demonstrates the required pattern in the very same commit — saveas brackets its native dialog with oldSuspend save/restore (6198-6199, 6256) and recover_apply does too (5552-5570) — but the two prompts newly added to els::save (extstate_ask, decode_lossy_ask) repeat the unguarded pattern (extmod_ask/lossy_ask/save-error instances predate 0.93; handoff_tick and its guard are unchanged from v0.92:3730-3738).

**Scenario:** Doc a.txt is dirty and a sync client rewrote (or deleted) it on disk. User hits Ctrl+S; the extmod_ask box "a.txt has changed on disk... No — reload from disk, discarding your edits" (or the new extstate_ask "has been removed — Yes: recreate it from this buffer") is up. The user double-clicks b.txt in Explorer; the second els instance spools it and within 500 ms handoff_tick drains inside the modal's message pump: a b.txt tab opens, becomes active, and is now the buffer displayed behind the dialog. The user, glancing at the visible (wrong) buffer to decide whether their edits are worth keeping, answers "No — reload, discarding your edits": a.txt's real unsaved edits are discarded based on a misdirected decision. Even on a harmless answer, focus is left in b.txt, so the user's next keystrokes land in the newly opened file instead of the document they were saving.

**Verifier assessment:** If a file handoff from a second els instance arrives while one of els::save's conflict prompts is open (file changed/removed on disk, lossy encoding, or save error), the handed-off file opens and becomes the active, visible, focused buffer beneath the modal within 500 ms — violating the codebase's own documented swap_suspend invariant. The save/reload still targets the correct document (save captures $id up front), so no automatic misdirected write occurs; the risk is a user answering a destructive prompt ("No — reload, discarding your edits") while looking at the wrong buffer, plus focus landing in the new tab so the next keystrokes hit the wrong file. Requires the coincidence of an already-rare conflict prompt and a concurrent second-instance handoff, so it is edge-case rather than mainline; still worth the two-line oldSuspend bracket fix that saveas and recover_apply in the same release already use.

---

## R29 — Go-to-Line resolves the target document at Go time, so a handoff drain during the grabbed dialog retargets the jump to the wrong document

**Severity:** minor · **Kind:** bug · **Location:** `els.tcl:8250` · **pre-existing** (exposed, not introduced, by this diff)

**Evidence:** goto_line (8215) shows a grabbed toplevel (`catch {grab $top}`, 8247) whose label advertises the ACTIVE doc's line count, but goto_do re-resolves the widget at action time: `set w [els::T]` (8250) — els::T returns the CURRENT active text widget. A Tk grab does not stop timers: while .goto is up, handoff_tick (5300-5301) still fires every 500 ms with swap_suspend==0, and handoff_drain's `els::open $p 1` (5224) calls switch_to (4395/4512), changing ::els::active beneath the grab. The dialog then executes `$w mark set insert $ln.0` (8256) against the newly drained document, clamped to ITS line count (8255). Structure is unchanged from v0.92 (goto_line at v0.92:5416), but the v0.93 timer inventory this dialog pumps against grew, and no modal audit covered it.

**Scenario:** User opens Go to Line on a 5000-line log (dialog says "Line (1 - 5000):"). While they type the line number, a second instance hands off a 40-line file; its tab opens and becomes active beneath the grabbed dialog. The user types 3200 and presses Enter: the caret jumps to the END of the 40-line handed-off file instead of line 3200 of the log, and the user is left editing the wrong document at an arbitrary position.

**Verifier assessment:** If a second els instance hands off a file during the few seconds the Go-to-Line dialog is open, the handoff timer (which the grabbed dialog does not suspend) switches the active document underneath the dialog; pressing Go then moves the caret in the newly opened file (clamped to its line count) instead of the document the dialog was opened for, and focus lands in the wrong tab. The mechanism is verified in code (goto_do re-resolves els::T at action time; goto_line never sets swap_suspend; handoff_drain's els::open calls switch_to). Impact is a misplaced caret in the wrong tab — no data loss, corruption, or crash — in a narrow multi-instance race window, and the behavior is unchanged from v0.92, so it is not a v0.93 regression.

---

## R30 — RunPrivate leaves a suspended-orphan window: child is job-assigned AFTER CreateProcessW, not atomically at creation

**Severity:** minor · **Kind:** bug · **Location:** `src/cap.c:321`

**Evidence:** RunPrivate_Cmd creates the child with CREATE_SUSPENDED (line 314-315) and only afterwards calls AssignProcessToJobObject(job, pi.hProcess) (line 321). Between those two calls the suspended child belongs to no kill-on-close Job. If this els process dies in that window, the child is never resumed and never killed. The v0.93 winfs worker path was deliberately written to avoid exactly this: WorkerSpawnWatch_Cmd uses PROC_THREAD_ATTRIBUTE_JOB_LIST to assign the job atomically at creation, with the comment (winfs.c 539-542) "If the parent dies anywhere after CreateProcessW ... there is no unattached PID or suspended-orphan interval." cap.c did not adopt the same technique.

**Scenario:** els is force-killed (or crashes) during a screenshot in the microsecond window after CreateProcessW returns but before AssignProcessToJobObject runs. The suspended private-desktop wish child is orphaned: it is never resumed, never terminated by the (now-closed) kill-on-close job, and lingers as a suspended process holding its private desktop until the next reboot. Narrow window; screenshot is a dev/test surface.

**Verifier assessment:** Only if els is force-killed or crashes in the microsecond gap between CreateProcessW and AssignProcessToJobObject during a private-desktop screenshot (a dev/test surface) would a suspended, inert child process and its private desktop leak until reboot. No data loss, corruption, or wrong user-visible behavior; the child consumes negligible resources while suspended. Real defect and worth fixing via the PROC_THREAD_ATTRIBUTE_JOB_LIST pattern already used in winfs.c, but impact is a rare resource leak in a non-mainline flow.

---

## R31 — quiet-open-1.1's log assertion reads a shared accumulating els.log already containing the expected phrase

**Severity:** minor · **Kind:** test-gap · **Location:** `tests/els.test:1416`

**Evidence:** quiet-open-1.1 asserts `[string match "*quiet open failed*" [raw_read $log]]` against tests/_tmp/els.log without deleting the log in setup. bigfile-1.10 (tests/els.test:1277, earlier in the same file) exercises a failed quiet open through the same els::open_quiet_failure (els.tcl:4380-4383), which appends 'quiet open failed for ...' to the same file; els_reset never clears els.log (only els.conf, els.deferred, .els-find are deleted).

**Scenario:** A regression that stops the startup-style quiet-open path (missing file, quiet=1) from logging — while the deferred-add failure path still logs — leaves quiet-open-1.1 green: the match succeeds on bigfile-1.10's earlier line in the shared log, so the 'is logged' claim in the title is not attributable to this test's open.

**Verifier assessment:** No user-facing impact today — the product correctly logs quiet-open failures. The defect is that quiet-open-1.1's log assertion matches against a shared, never-cleared tests/_tmp/els.log that bigfile-1.10 has already seeded with the exact phrase "quiet open failed", so the assertion cannot attribute logging to its own open. A future regression that removes the log call from els::open_quiet_failure (while keeping the status note) would pass this test falsely, weakening the regression guard for the quiet-open logging contract. Verified: els_reset (tests/helpers.tcl:245-248) deletes els.conf/els.deferred/.els-find but not els.log, and bigfile-1.10's failed quiet open reaches els::open_quiet_failure via read_binary_guarded's "deferred-open list could not be saved" path (els.tcl:4204-4211, 4433-4436).

---

## R32 — recover-dialog-1.4 asserts nothing about the 'leaves every swap for later' half of its title

**Severity:** minor · **Kind:** test-gap · **Location:** `tests/recover.test:359`

**Evidence:** The plans are built from paths that are never created: `lappend plans [list [file join $::ELS_TMP "later-$i.swp"] $rec missing]` (no forge_swap/raw_write). The body only checks Ctrl+A selection counts, the KP_Enter binding, and `[winfo exists .recover]` after Escape — there is no assertion that Escape refrained from deleting or consuming the swaps, and none is possible since the files do not exist.

**Scenario:** A regression where the Escape/WM-close path of the recovery dialog discards or recovers the listed swaps (instead of leaving them for a later run) passes this test unchanged: the dialog still closes, selection counts are unaffected, and the nonexistent swap files can't reveal a wrongful deletion.

**Verifier assessment:** No user-visible defect today — the Escape/WM-close path correctly leaves swaps untouched (els.tcl:5390-5393, 5707-5708). The issue is that recover-dialog-1.4 titles this guarantee but builds its plans from nonexistent swap files and asserts only selection counts, a binding, and window destruction, so a future regression that makes Escape discard or consume unrecovered swaps (silent loss of a user's unsaved-crash data) would pass this test. Partially mitigated: a regression in the shared close proc itself would be caught by recover-dialog-1.1's file-exists assertion; only an Escape-binding-specific regression slips through. Fix is trivial: forge real swaps in 1.4 and assert they still exist after Escape.

---

## R33 — probe_exe.tcl was binary at v0.92 (4 raw NUL sentinel bytes), making the release-commit diff for it unreviewable as text; v0.93 file itself is clean

**Severity:** minor · **Kind:** inconsistency · **Location:** `tools/probe_exe.tcl:1` · **pre-existing** (exposed, not introduced, by this diff)

**Evidence:** git cat-file of the v0.92 blob (9145 bytes) shows 4 literal 0x00 bytes inside the env-restore sentinel `"\0unset"` at v0.92 lines 157/188/199/200 (e.g. `if {$v eq "^@unset"} { catch {unset ::env($k)} } ...`), which trips git's NUL-in-first-8kB binary heuristic. The v0.93 blob (21071 bytes) has zero NULs — the sentinel is now the source-level escape `\x00unset` (current lines 124/139/416/427-428) — and is plain UTF-8 (only two U+2014 em dashes in comments). Verified v0.93 is git-textual (diff vs empty tree shows 442 added lines; blame and git grep work), brace-complete (`info complete` = 1) and runs under tclsh90 (reaches its runtime 'exe not found' check). The claim that v0.93 'contains NUL bytes on ~442 lines' is false — grep with a NUL byte in the pattern degenerates to an empty pattern matching all 442 lines. `git diff v0.92 v0.93` prints 'Bin 9145 -> 21071 bytes' solely because the OLD side is binary; the file is not corrupted at either revision.

**Scenario:** Anyone reviewing the v0.93 release commit (or any range crossing v0.92) sees only 'Bin' for tools/probe_exe.tcl and cannot read the substantial probe changes (the file more than doubled) as a textual diff; git grep/diff at v0.92-era revisions report 'Binary file matches'. Current-head tooling is unaffected. Fixed as a side effect in 0.93; the residual cost is history display only.

**Verifier assessment:** No end-user or runtime impact at all: the file behaves identically at both tags and the shipped v0.93 copy is clean UTF-8 text. Verified: the v0.92 blob contains 4 raw NUL bytes (the "\0unset" env sentinel at lines 157/188/199/200), which makes git treat it as binary, so `git diff v0.92 v0.93` shows only "Bin 9145 -> 21071 bytes" and the substantial probe rewrite (442-line file, more than doubled) cannot be reviewed as a textual diff; git grep/blame at v0.92-era revisions also report "Binary file". The defect was fixed as a side effect in v0.93 (sentinel now written as the source escape \x00unset). Residual cost is purely historical-diff readability for developers reviewing the release range — a real but small dev-tooling annoyance, not a release-gate or user-facing problem.

---

## R34 — Unauthorized-worker probe execs the candidate exe synchronously with no timeout or watchdog — a wedged candidate hangs release-check forever

**Severity:** minor · **Kind:** bug · **Location:** `tools/probe_exe.tcl:174`

**Evidence:** Lines 172-175: `set code [catch { with_probe_environment $app [list ELS_STARTUP_PROBE $report] [list exec $exe --find-worker $job $token] } err opts]`. This is the only place in the file where the untrusted candidate binary is run synchronously: `exec` (no `&`) blocks until the child exits (Tcl exec manual). Every other child interaction in this file is deadline-guarded (wait_report: 6000ms + taskkill, line 60-77; worker watch: 8000ms poll, line 215-221; kill drain: 3000ms, line 253-258). The bound relied on here lives inside the candidate itself: elsworker::wait_for_go (els.tcl:82-100) self-exits after 5000ms — but the probe's whole purpose is to certify a candidate whose worker/startup path may be broken. If the candidate wedges before either exit path (a regression in the wait_for_go loop, a Tk-level hang, or an uncaught error during els::build that pops a modal Tk error dialog in the GUI-subsystem exe BEFORE the probe's exit-3 ::bgerror is installed at els.tcl:8585), the exec never returns and no outer deadline exists.

**Scenario:** A build regression makes els.exe throw during els::build (e.g. a zipfs resource missing after a packaging change): the GUI-subsystem exe shows Tk's modal startup-error dialog and never exits; `z release-check` (tasks.tcl:1740) and `z sign`'s re-probe (tasks.tcl:633) block indefinitely at '== real packaged-executable probe ==' with no output, requiring a human to find and kill the invisible (CREATE_NO_WINDOW-less) child — instead of the bounded 6s-timeout-plus-taskkill failure every other probe in this file produces.

**Verifier assessment:** No end-user impact: this is release/dev tooling. The unauthorized-worker probe (tools/probe_exe.tcl:172-175) execs the candidate synchronously with no timeout, unlike every other deadline-guarded child launch in the file, so a candidate that wedges before any of its internal exit paths (e.g. a startup error surfacing Tk's modal dialog before the probe's exit-3 bgerror is installed at els.tcl:8585) hangs `z release-check`/`z sign` indefinitely instead of failing within the bounded 6s-plus-taskkill pattern used elsewhere. The gate fails safe — it can never falsely pass a broken build — and the hang only occurs when the candidate is already broken in a specific wedging mode, so the cost is a developer manually noticing and killing a stuck, silent release check rather than any wrong release or data loss.

---

## R35 — Authorization `go` file written non-atomically, racing the worker's read-once wait_for_go — contract mismatch with the production writer causes flaky release failures

**Severity:** minor · **Kind:** bug · **Location:** `tools/probe_exe.tcl:214`

**Evidence:** Line 214: `write_file [file join $authJob go] [encoding convertto -profile strict utf-8 $go]` — write_file (lines 19-26) opens the FINAL path directly (`open $path w`), so the file exists empty from `open` until `close` flushes the payload. The consumer, elsworker::wait_for_go (els.tcl:82-100), polls `file exists` every 25ms and on the FIRST sighting reads the file once; if it does not parse as the exact {command token version} dict it returns 0 permanently (els.tcl:95 `return 0` — no retry), and the worker exits 3. Production knows this contract: els::find_write_control (els.tcl:6573-6585) writes `go` via temp-name + `file rename` precisely so the worker can never observe a partial file. The probe bypasses that atomic-write discipline for the very same consumer.

**Scenario:** On a loaded release machine (AV filter driver scanning new files in the freshly created job dir, disk pressure), the worker's 25ms poll lands between the probe's open() and close() of `go`, reads an empty/partial file, permanently rejects authorization and exits 3; the watch loop then reports `{exited 3}` and line 222 raises 'packaged worker did not exit cleanly: exited 3' — release-check fails spuriously on a perfectly good build, and the failure is timing-dependent and unreproducible.

**Verifier assessment:** No end-user impact. The race is real (probe writes the go file non-atomically while the worker's wait_for_go reads it once on first sighting with no retry), but it only affects the release smoke-test tool, the window is microseconds wide under normal conditions, and it fails safe: a rare timing hit spuriously fails the release check on a good build, and a re-run passes. It cannot let a bad build through or corrupt anything.

---

## R36 — Single-instance probe never kills the second launched process on any failure path — a handoff regression leaves a live full-GUI els.exe on the release machine

**Severity:** minor · **Kind:** bug · **Location:** `tools/probe_exe.tcl:434` · **pre-existing** (exposed, not introduced, by this diff)

**Evidence:** Lines 424-430 spawn the second process (`set secPid [env_swap $app4 [...ELS_STARTUP_PROBE "\x00unset"...] { exec [file join $app4 els.exe] $handed & }]`) with the startup probe deliberately unset, so if single-instance detection is broken it builds a real, visible, never-exiting editor (els.tcl:8568-8619: without $startupProbe there is no linger/exit timer). Yet no path ever kills $secPid: the failure branch at lines 434-436 just raises `error "single-instance probe: handed-off file not opened..."`, and wait_report's timeout kill (line 75) and the lock-timeout kill (line 420) both filter on the PRIMARY pid only (`/FI "PID eq [lindex $primePid 0]"`). $secPid is assigned and never used. (The same gap existed in v0.92's version of this block; v0.93 rewrote the block — env scrubbing, absolute TASKKILL — without closing it.)

**Scenario:** Exactly when this probe correctly detects the bug it exists for (primary_running/handoff regression): the second launch opens handed.txt in a full interactive editor window on the release engineer's desktop, the probe errors out, cleanup_probe_root (line 439) is never reached, and the stray els.exe keeps tests/_tmp/exeprobe-*/single/els.exe mapped and its CWD inside the scratch tree indefinitely — each retry of `z release-check` stacks another orphan GUI process that must be killed by hand.

**Verifier assessment:** Real cleanup gap in the release-check tool (tools/probe_exe.tcl:424-436): the second spawned els.exe ($secPid) is never killed on any failure path, and since it runs without ELS_STARTUP_PROBE it builds a full visible GUI with no exit timer (els.tcl:8568-8619) if single-instance detection/handoff regresses. However, it only manifests when the probe is already failing — the release gate still correctly blocks, no wrong verdict is produced, and fresh unique scratch dirs mean orphans don't poison later runs. Impact is limited to stray GUI processes and scratch litter on the release engineer's machine requiring manual taskkill, one per retry. The gap also pre-existed in v0.92, so it is not a new regression in this range. Worth fixing (kill $secPid in failure paths), but edge-case tooling hygiene, not a broken gate.

---

## R37 — Uniquely-named scratch root is cleaned only on full success — every failed probe run permanently leaks ~7 copies of els.exe under tests/_tmp

**Severity:** minor · **Kind:** bug · **Location:** `tools/probe_exe.tcl:439`

**Evidence:** v0.93 switched from v0.92's fixed, self-reclaiming scratch dir (`set BASE [file join $ROOT tests _tmp exeprobe]` with `catch {file delete -force $app}` before each probe) to a per-run unique root (line 15: `exeprobe-[pid]-[clock clicks]`) whose only removal is `cleanup_probe_root $BASE` at line 439, executed after ALL probes pass. There is no try/finally or trap around the top-level probe sequence, and the uniqueness checks (lines 149, 268, 287, 401) guarantee later runs never reclaim an earlier run's directory. Each run copies the multi-megabyte candidate exe into seven probe dirs (packaged-worker, first, profile-ignore, adjacent-legacy, restore, explicit, recover, single).

**Scenario:** While debugging a broken build, an engineer re-runs `z release-check` five times; each run aborts at some probe error and leaves an entire exeprobe-<pid>-<clicks> tree (7 exe copies plus app state) behind — tens to hundreds of MB of unbounded, never-reclaimed accumulation in tests/_tmp, with no message telling the user the scratch root was preserved (the only notice, line 440, is on the success path).

**Verifier assessment:** No end-user or release-artifact impact: the leak is confined to the developer's gitignored tests/_tmp directory and only occurs when a release probe run fails. Each failed run silently strands a unique exeprobe-<pid>-<clicks> tree containing up to 8 copies of the ~5 MB candidate exe (~40 MB max per run), which unlike v0.92's fixed-path scheme is never reclaimed by later runs. Disk accumulation is unbounded across repeated failures but easily cleaned manually; the probe still correctly gates broken binaries.

---

## R38 — lock-1.2 never exercises the visible-file token re-comparison guard it advertises

**Severity:** minor · **Kind:** test-gap · **Location:** `tools/release_tooling.test:513`

**Evidence:** The body does `close $::tool_lock_channel` itself before calling release_tool_lock. In tools/tasks.tcl release_tool_lock (lines ~290-316), the first step is `catch { seek $fh 0; set owner [string trim [read $fh]] }` on the held channel; because the test already closed it, that read fails and `owner` stays "", so the earlier guard `if {[catch {dict get $owner token} actual] || $actual ne $token} { return }` returns before the advertised final guard (`set visible [read_small_text $path]` + token comparison, the code path the test's own comment says it emulates: 'Emulate the narrow interval after release_tool_lock closes its held handle but before it removes the visible name') is ever reached.

**Scenario:** If a future edit deletes or breaks the visible-name re-read/token re-comparison in release_tool_lock (the only guard protecting the real close-then-delete race window), lock-1.2 still passes — the replacement file survives via the unrelated 'owner unreadable' early return — so the release tooling suite green-lights a build whose lock release can delete another task's freshly acquired lock in the close/delete interval.

**Verifier assessment:** No user-visible impact today: the visible-file token re-comparison guard in release_tool_lock (tools/tasks.tcl:310-312) exists and works. The defect is that lock-1.2 never reaches that guard — closing the channel before release makes the owner read fail, so the proc returns early at the line-305 owner-token check, and the test would still pass if the guard were deleted. It is a genuine test-coverage gap (the test cannot exercise what its comment claims, since Windows forces closing the handle before replacing the file, which guarantees the early return), but the only consequence is latent: a future regression removing the guard would go undetected, allowing a narrow close/delete race in internal build tooling where one task's lock release deletes another task's fresh lock. Not a broken release gate now, and no end-user data is at risk.

---

## R39 — z run mutates shared build/ state (via ensure_native_support -> task_build-ext) without taking the new tooling lock

**Severity:** minor · **Kind:** inconsistency · **Location:** `tools/tasks.tcl:1880`

**Evidence:** proc task_run calls `ensure_native_support` (line 1880), which invokes `task_build-ext` and rewrites build/*.dll and build/pkgIndex.tcl via `place_regular_file ... [P build $name.dll]`. But `task_uses_tool_lock` (lines 315-320) lists `build build-ext native-startup-check release-check sign test stress probe-exe shot readme-shots icon toolcheck` — `run` is absent, so the dispatcher never acquires build/.els-tooling.lock for it. This contradicts the lock's own charter comment (line 248: "All public tasks that mutate or consume shared build/release state serialize through one fail-closed presence lock"). Both the lock and the ensure_native_support call in task_run are new in v0.93 (v0.92's task_run only exec'd wish).

**Scenario:** While `z release-check` holds the lock and has just deleted build/{cap,elsx,icudet,winfs,windrop}.dll for its "clean native build + load check", a developer runs `z run` in another terminal. task_run sees winfs.dll missing, runs task_build-ext concurrently with release-check's own task_build-ext; the two racing `file rename -force` placements can leave release-check's native_check.tcl loading a DLL mid-replacement, spuriously failing the release run (or z run silently interleaves with release build state). Fail-closed but a lock-invariant violation.

**Verifier assessment:** Real lock-invariant violation: `z run` can trigger an unlocked `task_build-ext` that rewrites build/*.dll and pkgIndex.tcl while a lock-holding task (notably `z release-check`, which deletes those DLLs mid-run) is using them. Requires a developer to run two z tasks concurrently in a seconds-wide window; outcomes are fail-closed (spurious release-check failure or failed run needing a rerun, since Windows rename-over-loaded-DLL fails loudly and both racing builds compile identical clean sources into unique staging dirs). No end-user editor impact and no silent artifact corruption — a dev-tooling concurrency edge case, not a broken release gate.

---

## R40 — read_checksum's declared utf-8/strict channel options are silently overridden by -translation binary in the same fconfigure call

**Severity:** minor · **Kind:** bug · **Location:** `tools/tasks.tcl:1263`

**Evidence:** Line 1263: `fconfigure $fh -encoding utf-8 -profile strict -translation binary`. fconfigure applies options left to right, and `-translation binary` resets the encoding to iso8859-1 — empirically verified on the vendored tclsh90 9.0.3: after this exact call, `fconfigure $f -encoding` reports `iso8859-1`. So the .sha256 file (written by write_release_metadata as UTF-8) is actually read as raw latin-1 bytes and the -profile strict guard is meaningless. The three intended guarantees (utf-8 decode, strict validation, exact byte-level \n check) cannot all hold; two of the three declared options are dead code.

**Scenario:** Today artifact names are ASCII (els.exe/els-unsigned.exe) so nothing breaks; but if a release artifact name ever contained a non-ASCII character, read_checksum would compare the mojibake latin-1 decoding of the UTF-8 name against the real name and reject a perfectly valid checksum file (spurious fail-closed), and any invalid-UTF-8 corruption in the file is no longer detected as such. The declared intent and actual channel configuration disagree in brand-new release-gate code.

**Verifier assessment:** Empirically confirmed on the vendored tclsh 9.0.3: `-translation binary` (applied last) resets the channel encoding to iso8859-1, silently killing the declared `-encoding utf-8 -profile strict`. However, all current artifact names (els.exe, els-unsigned.exe) are ASCII, where latin-1 and UTF-8 decode identically, so read_checksum behaves correctly for every input the release pipeline produces today. The only latent failure is fail-closed (a non-ASCII artifact name would be spuriously rejected via the name-mismatch check); no path allows a bad checksum to be accepted, since the SHA-256 hash comparison is encoding-independent. Real defect — misleading dead options in new release-gate code — but zero present user impact and safe-direction failure in the hypothetical, so minor.

---

## R41 — `z pecheck --signed` (mode without path, as the help text suggests) errors with usage instead of applying a default artifact

**Severity:** minor · **Kind:** ux · **Location:** `tools/tasks.tcl:413`

**Evidence:** task_pecheck: `if {![llength $args]} { set args [list --unsigned [P dist els-unsigned.exe]] }` — the default artifact is injected only when NO arguments are given. task_help line 377 documents `z pecheck [mode] [exe]  ... mode is --unsigned (default) or --signed`, implying the exe is optional in both modes. With `z pecheck --signed`, pecheck.tcl receives zero positional arguments and exits: `usage: pecheck.tcl ?--unsigned|--signed? ?--manifest file? ?--version x.y.z? path/to/els.exe`.

**Scenario:** An operator who just ran `z sign` follows the help text and runs `z pecheck --signed` to re-verify the shipped dist/els.exe; instead of checking the obvious default artifact they get a usage failure (exit 1). Fail-closed but the documented interface and the implementation disagree.

**Verifier assessment:** Only affects operators running the internal `z pecheck --signed` convenience form; they get a fail-closed usage error (exit 1) instead of a default-artifact check, contradicting the help text. Trivial workaround (pass the exe path explicitly), no possibility of a wrong verification verdict, and no impact on shipped editor behavior or release integrity.

---

## R42 — run_native_startup_check leaks its _startup-prep stage directory when the preparatory build fails

**Severity:** minor · **Kind:** bug · **Location:** `tools/tasks.tcl:2130`

**Evidence:** Lines 2128-2133: `set prepOutDir [unique_stage_directory [P build] _startup-prep]` is created, then `set prepared [build_native_product ...]` runs, and only after it succeeds is `set ownPrepared 1` reached; the cleanup (`remove_real_tree ... outer_stage`) lives in the try/finally that begins later at line 2144. If build_native_product throws (it removes only its own inner _native stage on error), the freshly created build/_startup-prepXXXXXX directory is orphaned with no cleanup path — unlike every other stage in this file, which is either removed in a finally or on the error path.

**Scenario:** `z native-startup-check` on a machine with a broken payload (e.g., missing tcl9s static lib) fails partway through build_native_product; each retry leaves another empty build/_startup-prep* directory accumulating in build/, contrary to the release tooling's otherwise-meticulous stage cleanup discipline. No correctness impact (validate_build_output reserves `_*` names).

**Verifier assessment:** Only affects a developer running standalone `z native-startup-check` when the preparatory native build fails: each failed attempt orphans one empty build/_startup-prep* directory (cleanup lives in a finally block that is never entered on this path, and build_native_product removes only its own inner stage on error). No build output corruption, no crash, and the release gate is unaffected since release-check passes its own prepared build info; the impact is accumulating empty temp directories in build/ contrary to the tooling's cleanup discipline.

---

## R43 — verify_signed_identity reuses normalize_sha1 to parse signtool output, so a malformed hash line produces an error blaming ELS_SIGN_CERT_SHA1

**Severity:** minor · **Kind:** ux · **Location:** `tools/tasks.tcl:513`

**Evidence:** Line 512-513: when a `SHA1 hash:` line from `signtool verify /pa /all /v` matches the loose charset regexp `([0-9A-Fa-f :\-]+)` but is not exactly 40 hex digits (e.g., a wrapped or truncated line in localized/edge signtool output), `normalize_sha1 $value` throws "ELS_SIGN_CERT_SHA1 must be exactly 40 hexadecimal digits" — an error message about the operator's pin environment variable, even when that variable was never set; the actual problem is unparseable signtool verify output.

**Scenario:** During `z sign` on a machine whose signtool emits an unexpected SHA1-hash line format, the run aborts with a diagnostic directing the operator to fix ELS_SIGN_CERT_SHA1 (which is unset), sending them down the wrong debugging path. Fail-closed; diagnostics only.

**Verifier assessment:** Only affects operators running the internal `z sign` release task on a machine whose signtool emits a malformed/wrapped SHA1-hash line — a rare edge case. The run fails closed (no bad artifact can ship), but the error message wrongly blames the ELS_SIGN_CERT_SHA1 environment variable instead of the unparseable signtool output, misdirecting debugging. No end-user or release-artifact impact; misleading diagnostic only.

---

## R44 — Caret section still asserts a blinking cursor is a "documented" distraction after this commit deleted the supporting citation

**Severity:** cosmetic · **Kind:** inconsistency · **Location:** `docs/DESIGN.md:64`

**Evidence:** docs/DESIGN.md:64-65 (unchanged): "A blinking cursor is a documented distraction; a solid red caret is calmer...". The v0.93 diff removed the only supporting reference from the study list at the bottom of the file: "- Blinking caret as an accessibility barrier: <https://sensorydiversity.com/...>" was deleted along with the "Accessibility, honestly" section it supported. The word "documented" now points at nothing in the document's own reference list.

**Scenario:** A reader following the design rationale looks for the document behind "documented distraction" and finds the reference list no longer contains it, weakening the stated justification for the signature steady caret.

**Verifier assessment:** No impact on the running editor or any user flow. The defect is real — DESIGN.md:64-65 still claims a blinking cursor is a "documented" distraction while v0.93 deleted the only supporting citation (the sensorydiversity.com link) from the reference list — but it is purely an internal design-doc consistency gap. A reader tracing the rationale finds a dangling claim; nothing else. Fix is a one-line doc edit (restore the citation or drop the word "documented").

---

## R45 — Screenshots section describes the retired twapi window-finding design; v0.93 rewrote tools/shot.tcl to a twapi-free private-desktop architecture

**Severity:** cosmetic · **Kind:** doc-mismatch · **Location:** `toolchain.md:240`

**Evidence:** toolchain.md:240-241 still says "`tools/shot.tcl` uses twapi to find the target window and the `cap` C extension to capture it" and calls `z shot --selftest` "the converter selftest". The same release commit rewrote tools/shot.tcl (+541 lines changed) and src/cap.c (+382): the v0.93 shot.tcl header states "Its native helper creates a private Win32 desktop (never SwitchDesktop), starts a kill-on-close child there... The child lets Tk map/focus/paint normally on that private desktop, captures its own HWND with PrintWindow" and contains ZERO twapi references (`grep twapi tools/shot.tcl` is empty; the v0.92 version had "Window-finding via twapi (by PID)" and a twapi package-require block). `ensure_capture_support` in tools/tasks.tcl only builds cap.dll; twapi's sole remaining consumer is tools/toolcheck.tcl:214 (payload check). The new `--selftest` also requires a wish.exe and exercises the full private-desktop capture (shot.tcl:441-443, shot_selftest at :343), not just the DIB converter. README.md:307 has the same stale claim in the task table: "z shot out.png # screenshot the editor (twapi, all-Tcl, no AutoIt)" — both "twapi" and "all-Tcl" are false for the v0.93 implementation (native C private-desktop helper does the window work). The docs were extensively swept for this release (README/toolchain both heavily edited in this same commit) but this paragraph and the README table annotation were missed.

**Scenario:** A developer debugging a screenshot failure (e.g. z readme-shots producing a black/empty PNG) reads toolchain.md and starts investigating twapi window-enumeration and TCLLIBPATH/Z_TWAPI resolution — a code path that no longer exists — instead of the actual private-desktop/cap.dll child lifecycle where such failures now originate; likewise someone auditing dependencies concludes twapi is load-bearing for screenshots when it is only a toolcheck payload probe.

**Verifier assessment:** No end-user or runtime impact; the screenshot tooling works as implemented. Stale developer docs (toolchain.md:241-243 "uses twapi... converter selftest" and README.md:307 "(twapi, all-Tcl, no AutoIt)") describe the retired v0.92 design instead of the v0.93 twapi-free private-desktop architecture, which could send a contributor debugging screenshot failures down a nonexistent twapi code path or cause a dependency audit to wrongly conclude twapi is load-bearing for screenshots.

---

## R46 — Payload-root fallback description omits Z_HOME, which the code prefers over Z_ROOT

**Severity:** cosmetic · **Kind:** doc-mismatch · **Location:** `toolchain.md:34`

**Evidence:** The sentence rewritten in this release (toolchain.md:31-35) says z.exe "exports `Z_HOME`" but then states tasks.tcl resolves payload roots from the `Z_*` overrides "otherwise deriving them from `Z_ROOT` or the hosted layout". tools/tasks.tcl `zmal_paths` (lines 17-27) actually tries Z_HOME FIRST (`if {[info exists ::env(Z_HOME)] ...} lappend out [file join $::env(Z_HOME) ...]`), and only `elseif` falls back to `$::env(Z_ROOT)/.z`, then the hosted layout. So Z_HOME — always exported per the doc's own claim — is the primary derivation source and Z_ROOT is effectively dead whenever Z_HOME is set, contradicting the doc's derivation chain.

**Scenario:** A developer running tools/tasks.tcl outside z sets Z_ROOT per the doc to point at an alternate workspace while a stale Z_HOME is still in the environment; the tooling silently resolves payloads from Z_HOME instead, and the doc gives no hint why the override is ignored.

**Verifier assessment:** The doc sentence in toolchain.md:31-35 misstates the payload-root derivation order (code prefers Z_HOME over Z_ROOT), which could briefly confuse a developer running tasks.tcl outside z with a stale Z_HOME set; no runtime behavior is affected, explicit Z_* overrides still work, and `z tasks env` reveals the resolved paths.

---

# Refuted during verification (kept for the record)

## ✗ Replace All commit discards caret, selection and scroll position (whole-buffer replace with no insert/yview restore)

`els.tcl:8037` — refuted: The finding models `$w replace 1.0 "end - 1 char" $output` as delete-then-insert ("collapses the insert mark to 1.0... pushes the right-gravity insert mark to the end of the inserted text"). That is wrong for Tk's `replace` subcommand: the Tk 9 manual (manual/commands/text.md, pathName replace, line 752) states "The deletion and insertion are arranged so that no unnecessary scrolling of the window or movement of insertion cursor occurs", and Tk special-cases an insert mark inside the replaced range by restoring it at the same character offset from the range start (clamped to the inserted length). An empirical tclsh90/Tk probe reproducing the exact scenario (10,000-line buffer, caret at 50.5, view at top line 40, three length-changing replacements near the top, then whole-buffer replace) gave: insert 50.5 -> 49.23 (same char offset, 6-char drift from the earlier replacements' length delta), top line 40.0 unchanged, yview unchanged. The claimed failure — caret at line 10,000 and scroll position gone — cannot occur. The only surviving residuals versus v0.92's per-span reverse replace are: the sel tag is cleared, and the caret can drift by the cumulative length delta of matches before it. Those are cosmetic, not the reported defect. preExisting=false: the whole-buffer replace path is new in v0.93 (v0.92 find_replace_all at line 5386 replaced spans in reverse), but the new code does not exhibit the claimed behavior.

## ✗ Upgrade abandons 0.92 %LOCALAPPDATA% state: pre-upgrade crash-recovery swaps are never scanned or offered

`els.tcl:893` — refuted: The finding's factual chain is accurate: v0.93 els.tcl:893 config_resolve_existing pins only the exe-adjacent config, config_candidates (els.tcl:730-733) returns a single path, swap_dir/swap_scan_orphans (els.tcl:4661, 5312) derive from it, zero LOCALAPPDATA references remain, and v0.92 did check %LOCALAPPDATA%\els\els.conf second with the first-run dialog defaulting to appdata. The scenario can occur. However, the finding's defect claim rests on an "upgrade-must-recover-pre-upgrade-swaps requirement" that does not exist anywhere in the repo (grep for "upgrade" across all .md files and els.txt: zero matches). The opposite is the documented v0.93 requirement: README.md:31-34/138 ("never falls back to the user profile and deliberately ignores old profile-stored els state"; "There is no profile fallback, migration or deletion") and docs/DESIGN.md:164-172 ("No user-profile path is a fallback, migration source or deletion target"). It is enforced by release tooling: tools/probe_exe.tcl:282-308 seeds a tempting %LOCALAPPDATA%\els\els.conf and FAILS the release probe if the packaged exe loads, migrates, rewrites, or deletes it (byte/mtime preservation asserted), and tests/ui.test cfg-2.3 asserts LOCALAPPDATA cannot influence the config root. No data is destroyed: old profile swap snapshots are deliberately left byte-for-byte intact on disk and remain manually recoverable; they are only not offered through the UI. This is an intentional, documented, probe-tested product decision of the 0.93 release, not an overlooked bug; the finding mislabels spec'd behavior as a critical defect by citing a fabricated requirement. (One could argue for a one-time user notice about the old location as a UX improvement, but that is a product suggestion, not a correctness bug.) preExisting=false: v0.92 consulted the profile location, so the flagged behavior was introduced in the v0.92..v0.93 range (single release commit 7f6aa9f).

## ✗ win_open_folder forces \\?\ extended-length prefix onto ShellExecuteExW, which the shell cannot parse

`src/winfs.c:181` — refuted: The premise is accurate (for UTF-16 length >= 260, ShellExecuteExW at src/winfs.c:181 does receive a \\?\-prefixed path, whether prefixed by utf8_to_wide's branch or already prefixed by Tcl 9's file normalize, since els::open_folder passes file nativename without stripping), but the conclusion is empirically false. A C probe compiled with the repo's UCRT64 gcc, replicating OpenFolder_Cmd's exact SHELLEXECUTEINFOW setup (SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC, verb "open", SW_SHOWNORMAL), ran on this Windows 11 system: ShellExecuteExW SUCCEEDED (hInstApp=42) for both a short \\?\-prefixed directory and a 324-character \\?\-prefixed directory, and Shell.Application window enumeration confirmed Explorer actually opened at the correct long-path folder (resolved via 8.3 short-name components). The modern Windows shell parses/normalizes the \\?\ extended-length prefix; the claim that ParseDisplayName rejects it and the user sees "Cannot open this folder" is stale folklore. Additionally, the unprefixed long path failed GetFileAttributesW (gle=3) in a non-longPathAware process, showing the prefix enables rather than breaks the long-path case. The claimed failure scenario cannot occur on the supported platform.
