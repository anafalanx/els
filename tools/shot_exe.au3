; tools/shot_exe.au3 — launch a single-file els.exe and capture ITS window (PID-scoped).
;   AutoIt3_x64.exe tools\shot_exe.au3 <els.exe> <openfile|-> <out.png>
#include <ScreenCapture.au3>

If $CmdLine[0] < 3 Then Exit 2
Local $exe = $CmdLine[1], $openf = $CmdLine[2], $png = $CmdLine[3]

Local $cmd = '"' & $exe & '"'
If $openf <> "-" Then $cmd &= ' "' & $openf & '"'
Local $pid = Run($cmd)
If $pid = 0 Then Exit 3

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
Sleep(800)
_ScreenCapture_CaptureWnd($png, $h)
Sleep(200)
WinClose($h)
Sleep(300)
ProcessClose($pid)
Exit 0
