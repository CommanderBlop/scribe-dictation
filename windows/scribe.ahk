#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Scribe Dictation — Windows glue (paragraph / batch mode)
;  Press the hotkey to start recording, press again to stop;
;  the recording is transcribed by ElevenLabs Scribe v2 and
;  pasted at your cursor. (Thin glue; transcription is in
;  windows\scribe_batch.py.)
; ============================================================

; ---------------- CONFIG ----------------
HOTKEY_STR := "^+Space"    ; Ctrl+Shift+Space. (F5 is "refresh" on Windows.)
MAX_SECS   := 120          ; safety auto-stop
MIC := "waveaudio default" ; Windows input. sox's bare "-d" fails here; use the
                           ; waveaudio driver. Change "default" to "0" or a device
                           ; name if the wrong mic is picked.
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

; ---- tray ----
A_IconTip := "Scribe — " HOTKEY_STR " to dictate"
A_TrayMenu.Delete()
A_TrayMenu.Add("Scribe (idle)", (*) => "")
A_TrayMenu.Add("Quit", (*) => ExitApp())

; ---- on-screen indicator (small pill, always on top, click-through) ----
ind := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
ind.BackColor := "C0392B"
ind.SetFont("s11 bold cWhite", "Segoe UI")
indText := ind.Add("Text", "x0 y8 w170 h24 Center", "")

; confirm the script actually launched
TrayTip("Ready — press " HOTKEY_STR " in any text box to dictate.", "Scribe Dictation is running", 1)

Hotkey(HOTKEY_STR, (*) => Toggle())

Toggle() {
    global recording
    if recording
        StopAndTranscribe()
    else
        StartRec()
}

Indicator(msg, color := "C0392B") {
    global ind, indText
    if msg = "" {
        ind.Hide()
        return
    }
    ind.BackColor := color
    indText.Text := msg
    ind.Show("NoActivate x" (A_ScreenWidth // 2 - 85) " y26 w170 h40")
}

StartRec() {
    global recPid, recording, sox, rawF, MAX_SECS, HOTKEY_STR
    try FileDelete(rawF)
    Run(sox ' -q -t ' MIC ' -c 1 -r 16000 -b 16 -e signed-integer -t raw "' rawF '"', , "Hide", &recPid)
    recording := true
    A_IconTip := "Scribe — recording…"
    Indicator("● Recording")
    SetTimer(AutoStop, -MAX_SECS * 1000)
}

StopAndTranscribe() {
    global recPid, recording, py, batch, sox, rawF, wavF, outF
    SetTimer(AutoStop, 0)
    recording := false
    if recPid {
        RunWait('taskkill /PID ' recPid ' /T /F', , "Hide")
        recPid := 0
    }
    if !FileExist(rawF) || FileGetSize(rawF) < 2000 {
        Indicator("")
        TrayTip("No audio captured — is the microphone working? (sox)", "Scribe", 3)
        A_IconTip := "Scribe — idle"
        return
    }
    A_IconTip := "Scribe — transcribing…"
    Indicator("Transcribing…", "2C3E50")
    try FileDelete(wavF)
    RunWait(sox ' -q -t raw -r 16000 -c 1 -b 16 -e signed-integer "' rawF '" "' wavF '"', , "Hide")
    try FileDelete(outF)
    ; run python directly (no shell redirect); it writes the result/errors to outF
    RunWait('"' py '" "' batch '" "' wavF '" "' outF '"', , "Hide")
    Indicator("")
    text := ""
    if FileExist(outF)
        text := Trim(FileRead(outF, "UTF-8"), " `t`r`n")
    if text = ""
        TrayTip("No transcript produced — check Python/sox (see README manual check).", "Scribe", 3)
    else if SubStr(text, 1, 10) = "SCRIBE-ERR"
        TrayTip(Trim(SubStr(text, 11)), "Scribe error", 3)
    else
        PasteText(text)
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
