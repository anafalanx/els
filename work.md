# els Work Plan

This is the ongoing planning doc for what to build next in els.

## User Preferences

- Keep encoding and line-ending controls in the status bar. Do not add top-level
  menu mirrors for those pickers.
- Rename the config file to `els.conf`; it is data, not executable Tcl.
- Leave the Tk column-zero caret quirk as-is for now.

## Selected Roadmap Items

Latest expanded feature poll selection:

`I1 I6 C1 C2 C3 C8 F1 F3 F4 F5 F10 F11 F12 F13 E2 E5 E6 E7 E13 S1 S2 V1 V6 N4 N5 N6 N8 N9 N10 L5 L6 H1`

Install / Distribution:
- `I1` Portable single exe remains first-class
- `I6` File association setup

Core / CUA:
- `C1` Select All, `Ctrl+A`
- `C2` Find Next / Previous, `F3` / `Shift+F3`
- `C3` F1 opens Help / Keyboard Shortcuts
- `C8` Command availability states

File / Session / Safety:
- `F1` Save All
- `F3` Close Other Tabs
- `F4` Reload / Revert from Disk
- `F5` Save Copy As
- `F10` Warn on external modification
- `F11` Read-only mode
- `F12` Open containing folder
- `F13` Copy file path commands

Editing:
- `E2` Duplicate Line / Selection
- `E5` Trim Trailing Whitespace
- `E6` Convert Case
- `E7` Indent / Unindent selection
- `E13` Wrap / Reflow Paragraph

Search:
- `S1` Ctrl+F pre-fills selected text
- `S2` Count Matches

View:
- `V1` Toggle line numbers
- `V6` Column guide / ruler

Encoding / EOL / Metadata:
- `N4` File Properties: path, size, encoding, EOL, modified state
- `N5` Ambiguous-file fallback encoding preference
- `N6` Encoding confidence indicator
- `N8` Mixed line-ending warning
- `N9` BOM add/remove command
- `N10` Binary file warning

Language / Text Help:
- `L5` Word count / character count
- `L6` URL detection

Help / Settings:
- `H1` Preferences dialog

## Removed From The Poll Selection

- `N1` Encoding menu mirroring the status picker
- `N2` Line Endings menu mirroring the status picker

## Suggested Build Order

Phase 1: low-risk CUA and search polish
- `C1` Select All
- `C2` Find Next / Previous
- `C3` F1 Help
- `S1` Ctrl+F pre-fills selected text
- `S2` Count Matches

Phase 2: file convenience commands
- `F1` Save All
- `F3` Close Other Tabs
- `F5` Save Copy As
- `F12` Open containing folder
- `F13` Copy file path commands

Phase 3: editing commands
- `E2` Duplicate Line / Selection
- `E5` Trim Trailing Whitespace
- `E6` Convert Case
- `E7` Indent / Unindent selection
- `E13` Wrap / Reflow Paragraph

Phase 4: view and writing metadata
- `V1` Toggle line numbers
- `V6` Column guide / ruler
- `L5` Word count / character count
- `L6` URL detection
- `N4` File Properties

Phase 5: file safety and encoding correctness
- `F4` Reload / Revert from Disk
- `F10` Warn on external modification
- `F11` Read-only mode
- `N5` Ambiguous-file fallback encoding preference
- `N6` Encoding confidence indicator
- `N8` Mixed line-ending warning
- `N9` BOM add/remove command
- `N10` Binary file warning

Phase 6: preferences and installation
- `H1` Preferences dialog
- `C8` Command availability states
- `I1` Portable single exe remains first-class
- `I6` File association setup
