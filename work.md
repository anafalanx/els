# els Work Plan

This is the ongoing planning doc for what to build next in els.

## User Preferences

- Keep encoding and line-ending controls in the status bar. Do not add top-level
  menu mirrors for those pickers.
- Rename the config file to `els.conf`; it is data, not executable Tcl.
- Leave the Tk column-zero caret quirk as-is for now.

## Selected Roadmap Items

Core / CUA:
- `C1` Select All, `Ctrl+A`
- `C2` Find Next / Previous, `F3` / `Shift+F3`
- `C3` F1 opens Keyboard Shortcuts / Help
- `C4` Delete selection menu item, `Del`
- `C5` Right-click context menu: Undo, Cut, Copy, Paste, Select All

File:
- `F1` Save All
- `F2` Close All Tabs
- `F3` Close Other Tabs
- `F4` Reload / Revert from Disk
- `F5` Save Copy As
- `F7` Restore previous session on launch

Edit:
- `E2` Duplicate Line
- `E5` Trim Trailing Whitespace
- `E6` Convert Case: upper, lower, title
- `E7` Indent / Unindent selection

Search:
- `S1` Ctrl+F pre-fills selected text
- `S2` Count Matches
- `S3` Select All Matches
- `S4` Find in Files

View:
- `V1` Toggle line numbers
- `V6` Column guide / ruler

Encoding / EOL:
- `N3` Default new-file encoding preference
- `N4` File Properties: path, size, encoding, EOL, modified state
- Add a professional encoding preference for ambiguous opened files: keep UTF-8
  as the default, but allow choosing a different default for files whose bytes
  do not prove an encoding. Consider showing whether the displayed encoding was
  certain, detected, or a fallback guess.

Tabs / Window:
- `T2` Move Tab Left / Right
- `T3` Duplicate Tab

Help / Settings:
- `H1` Preferences dialog
- `H4` Improve Keyboard Shortcuts window with grouped sections

## Removed From The Poll Selection

- `N1` Encoding menu mirroring the status picker
- `N2` Line Endings menu mirroring the status picker

## Suggested Build Order

Phase 1: low-risk CUA polish
- `C1` Select All
- `C2` Find Next / Previous
- `C3` F1 Help
- `C4` Delete menu item
- `C5` Right-click context menu
- `S1` Ctrl+F pre-fills selected text
- `S2` Count Matches
- `H4` Improve Keyboard Shortcuts window

Phase 2: file and tab operations
- `F1` Save All
- `F2` Close All Tabs
- `F3` Close Other Tabs
- `F4` Reload / Revert from Disk
- `F5` Save Copy As
- `T2` Move Tab Left / Right
- `T3` Duplicate Tab

Phase 3: editing commands
- `E2` Duplicate Line
- `E5` Trim Trailing Whitespace
- `E6` Convert Case
- `E7` Indent / Unindent selection

Phase 4: view and file metadata
- `V1` Toggle line numbers
- `V6` Column guide / ruler
- `N3` Default new-file encoding preference
- `N4` File Properties
- Default encoding preference for ambiguous opened files, plus encoding
  certainty/guess indication.

Phase 5: larger features
- `F7` Restore previous session on launch
- `S3` Select All Matches
- `S4` Find in Files
- `H1` Preferences dialog
