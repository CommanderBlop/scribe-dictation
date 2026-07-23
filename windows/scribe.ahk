#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Scribe Dictation — Windows glue (paragraph / batch mode)
;  Press the hotkey to start recording, press again to stop;
;  the recording is transcribed by ElevenLabs Scribe v2 and
;  pasted at your cursor. Mirrors the macOS Fn+F5 paragraph mode.
;
;  This is the thin "glue" (hotkey + record + paste + tray).
;  Transcription is done by windows\scribe_batch.py.
; ============================================================

; ---------------- CONFIG ----------------
HOTKEY_STR := "^+Space"    ; Ctrl+Shift+Space. F5 is "refresh" on Windows, so we avoid it.
MAX_SECS   := 120          ; safety auto-stop
; ----------------------------------------

repo   := A_ScriptDir "\.."
py     := repo "\.venv\Scripts\python.exe"
batch  := A_ScriptDir "\scribe_batch.py"
sox    := "sox"                       ; expected on PATH (installed by install.ps1)
rawF   := A_Temp "\scribe_rec.raw"
wavF   := A_Temp "\scribe_rec.wav"
outF   := A_Temp "\scribe_out.txt"

recPid := 0
recording := false

A_IconTip := "Scribe — " HOTKEY_STR " to dictate"
A_TrayMenu.Delete()
A_TrayMenu.Add("Scribe (idle)", (*) => "")
A_TrayMenu.Add("Quit", (*) => ExitApp())

Hotkey(HOTKEY_STR, (*) => Toggle())

Toggle() {
    global recording
    if recording
        StopAndTranscribe()
    else
        StartRec()
}

StartRec() {
    global recPid, recording, sox, rawF, MAX_SECS, HOTKEY_STR
    try FileDelete(rawF)
    ; record to headerless raw PCM: a force-kill can't corrupt a header that isn't there
    Run(sox ' -d -q -c 1 -r 16000 -b 16 -e signed-integer -t raw "' rawF '"', , "Hide", &recPid)
    recording := true
    A_IconTip := "Scribe — recording… (" HOTKEY_STR " to stop)"
    SetTimer(AutoStop, -MAX_SECS * 1000)   ; one-shot safety
}

StopAndTranscribe() {
    global recPid, recording, py, batch, sox, rawF, wavF, outF
    SetTimer(AutoStop, 0)
    recording := false
    if recPid {
        RunWait('taskkill /PID ' recPid ' /T /F', , "Hide")
        recPid := 0
    }
    if !FileExist(rawF) || FileGetSize(rawF) < 2000 {   ; nothing usable recorded
        A_IconTip := "Scribe — idle"
        return
    }
    A_IconTip := "Scribe — transcribing…"
    ; wrap the raw PCM into a .wav container so the API knows the format
    try FileDelete(wavF)
    RunWait(sox ' -q -t raw -r 16000 -c 1 -b 16 -e signed-integer "' rawF '" "' wavF '"', , "Hide")
    ; transcribe; capture stdout to a file (one-shot, so no concurrent-read issue)
    try FileDelete(outF)
    RunWait(A_ComSpec ' /c ""' py '" "' batch '" "' wavF '" > "' outF '""', , "Hide")
    if FileExist(outF) {
        text := Trim(FileRead(outF, "UTF-8"), " `t`r`n")
        if SubStr(text, 1, 10) = "SCRIBE-ERR"
            TrayTip("Scribe", Trim(SubStr(text, 11)), 3)
        else if text != ""
            PasteText(text)
    }
    A_IconTip := "Scribe — idle"
}

AutoStop() {
    global recording
    if recording
        StopAndTranscribe()
}

PasteText(txt) {
    prev := ClipboardAll()
    A_Clipboard := txt
    ClipWait(1)
    Send("^v")
    Sleep(150)
    A_Clipboard := prev
}
