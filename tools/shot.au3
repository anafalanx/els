; tools/shot.au3 — launch the Tk els and capture ITS window to PNG (PID-scoped,
; so it never grabs another window). Uses real Win32 capture of the Tk toplevel.
;   AutoIt3_x64.exe tools\shot.au3 <wish.exe> <els.tcl> <openfile|-> <out.png>
#include <ScreenCapture.au3>

If $CmdLine[0] < 4 Then Exit 2
Local $wish = $CmdLine[1], $script = $CmdLine[2], $openf = $CmdLine[3], $png = $CmdLine[4]

Local $cmd = '"' & $wish & '" "' & $script & '"'
If $openf <> "-" Then $cmd &= ' "' & $openf & '"'
; any args after the PNG are extra files (extra tabs)
For $i = 5 To $CmdLine[0]
    $cmd &= ' "' & $CmdLine[$i] & '"'
Next
Local $pid = Run($cmd)
If $pid = 0 Then Exit 3

; bind to the visible, titled top-level owned by OUR wish process
Local $h = 0, $t = TimerInit()
While TimerDiff($t) < 12000
    Local $l = WinList()
    For $i = 1 To $l[0][0]
        If $l[$i][0] <> "" And WinGetProcess($l[$i][1]) = $pid And BitAND(WinGetState($l[$i][1]), 2) Then $h = $l[$i][1]
    Next
    If $h <> 0 Then ExitLoop
    Sleep(150)
WEnd
If $h = 0 Then
    ProcessClose($pid)
    Exit 4
EndIf

WinActivate($h)
WinWaitActive($h, "", 5)
Sleep(800)                         ; let Tk paint
_ScreenCapture_CaptureWnd($png, $h)
Sleep(200)
WinClose($h)                       ; clean close (no WM_DELETE handler => exits)
Sleep(300)
ProcessClose($pid)
Exit 0
