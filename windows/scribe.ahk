#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Scribe Dictation — Windows glue
;  Ctrl+Shift+Space : realtime — stream & paste each segment as you speak
;  Ctrl+Shift+B     : paragraph (fallback) — record, then transcribe the whole clip
;  Tray dot: green = idle, red = recording. A credit balloon shows after each use.
;  Transcription is done by the Python side (realtime engine / scribe_batch.py).
; ============================================================

; ---------------- CONFIG ----------------
RT_KEY    := "^+Space"       ; realtime (primary)
BATCH_KEY := "^+b"          ; paragraph mode (fallback)
MIC       := "-t waveaudio default"  ; full sox input spec (bare -d fails on Windows).
                                     ; e.g. "-t waveaudio 0" or "-t waveaudio ""Mic Name""".
SILENCE   := "0.6"          ; realtime: pause (s) that finalizes a segment
VAD       := "0.4"          ; realtime: speech-vs-silence sensitivity 0-1
MAX_SECS  := 180            ; safety auto-stop
SHOW_CREDITS := true        ; tray balloon with credits left after each use
; ----------------------------------------

repo    := A_ScriptDir "\.."
py      := repo "\.venv\Scripts\python.exe"
engine  := repo "\realtime\scribe_stream.py"
batch   := A_ScriptDir "\scribe_batch.py"
creditsPy := A_ScriptDir "\scribe_credits.py"
sox     := "sox"
iconIdle := A_ScriptDir "\icon-idle.ico"   ; gray = idle
iconLive := A_ScriptDir "\icon-live.ico"   ; green = realtime
iconRec  := A_ScriptDir "\icon-rec.ico"    ; red = paragraph recording
rawF    := A_Temp "\scribe_rec.raw"
wavF    := A_Temp "\scribe_rec.wav"
streamF := A_Temp "\scribe_stream.txt"
batOutF := A_Temp "\scribe_batch_out.txt"
credF   := A_Temp "\scribe_credits.txt"

state  := "idle"    ; idle | rt | batch
rtPid  := 0
recPid := 0
lastLen := 0

try TraySetIcon(iconIdle)
A_IconTip := "Scribe — idle  (Ctrl+Shift+Space realtime · Ctrl+Shift+B paragraph)"
A_TrayMenu.Delete()
A_TrayMenu.Add("Scribe Dictation", (*) => "")
A_TrayMenu.Add("Quit", (*) => ExitApp())

Hotkey(RT_KEY, (*) => ToggleRealtime())
Hotkey(BATCH_KEY, (*) => ToggleBatch())

Idle() {
    global state, iconIdle
    state := "idle"
    try TraySetIcon(iconIdle)
    A_IconTip := "Scribe — idle"
}
Active(tip, icon) {
    try TraySetIcon(icon)
    A_IconTip := "Scribe — " tip
}

; ---------------- realtime ----------------
ToggleRealtime() {
    global state
    if state = "rt"
        StopRealtime()
    else if state = "idle"
        StartRealtime()
}

StartRealtime() {
    global state, rtPid, streamF, lastLen, py, engine, MIC, SILENCE, VAD, MAX_SECS, iconLive
    try FileDelete(streamF)
    lastLen := 0
    EnvSet("SCRIBE_SOX_INPUT", MIC)   ; tell the engine how to open the mic on Windows
    Run('"' py '" "' engine '" --emit --out-file "' streamF '" --silence ' SILENCE ' --vad-threshold ' VAD, , "Hide", &rtPid)
    state := "rt"
    Active("listening (realtime)", iconLive)
    SetTimer(PollStream, 150)
    SetTimer(RtAutoStop, -MAX_SECS * 1000)
}

StopRealtime() {
    global rtPid
    SetTimer(PollStream, 0)
    SetTimer(RtAutoStop, 0)
    PollStream()   ; flush any last segment
    if rtPid {
        RunWait('taskkill /PID ' rtPid ' /T /F', , "Hide")
        rtPid := 0
    }
    Idle()
    ShowCredits()
}

PollStream() {
    global streamF, lastLen
    if !FileExist(streamF)
        return
    txt := FileRead(streamF, "UTF-8")
    if StrLen(txt) > lastLen {
        chunk := SubStr(txt, lastLen + 1)
        lastLen := StrLen(txt)
        Loop Parse chunk, "`n", "`r" {
            line := Trim(A_LoopField)
            if line != ""
                PasteText(line " ")
        }
    }
}

RtAutoStop() {
    global state
    if state = "rt"
        StopRealtime()
}

; ---------------- paragraph / batch ----------------
ToggleBatch() {
    global state
    if state = "batch"
        StopBatch()
    else if state = "idle"
        StartBatch()
}

StartBatch() {
    global state, recPid, sox, MIC, rawF, MAX_SECS, iconRec
    try FileDelete(rawF)
    Run(sox ' -q ' MIC ' -c 1 -r 16000 -b 16 -e signed-integer -t raw "' rawF '"', , "Hide", &recPid)
    state := "batch"
    Active("recording (paragraph)", iconRec)
    SetTimer(BatchAutoStop, -MAX_SECS * 1000)
}

StopBatch() {
    global recPid, sox, py, batch, rawF, wavF, batOutF, iconRec
    SetTimer(BatchAutoStop, 0)
    if recPid {
        RunWait('taskkill /PID ' recPid ' /T /F', , "Hide")
        recPid := 0
    }
    if !FileExist(rawF) || FileGetSize(rawF) < 2000 {
        Idle()
        TrayTip("No audio captured — is the microphone working? (sox)", "Scribe", 3)
        return
    }
    Active("transcribing…", iconRec)
    try FileDelete(wavF)
    RunWait(sox ' -q -t raw -r 16000 -c 1 -b 16 -e signed-integer "' rawF '" "' wavF '"', , "Hide")
    try FileDelete(batOutF)
    RunWait('"' py '" "' batch '" "' wavF '" "' batOutF '"', , "Hide")
    text := ""
    if FileExist(batOutF)
        text := Trim(FileRead(batOutF, "UTF-8"), " `t`r`n")
    Idle()
    if text = ""
        TrayTip("No transcript produced — check Python/sox (see README).", "Scribe", 3)
    else if SubStr(text, 1, 10) = "SCRIBE-ERR"
        TrayTip(Trim(SubStr(text, 11)), "Scribe error", 3)
    else {
        PasteText(text)
        ShowCredits()
    }
}

BatchAutoStop() {
    global state
    if state = "batch"
        StopBatch()
}

; ---------------- shared ----------------
ShowCredits() {
    global SHOW_CREDITS, py, creditsPy, credF
    if !SHOW_CREDITS
        return
    try FileDelete(credF)
    RunWait('"' py '" "' creditsPy '" "' credF '"', , "Hide")
    if FileExist(credF) {
        c := Trim(FileRead(credF, "UTF-8"), " `t`r`n")
        if c != ""
            TrayTip(c " credits left", "Scribe 💳", 1)
    }
}

PasteText(txt) {
    prev := ClipboardAll()
    A_Clipboard := txt
    ClipWait(1)
    Send("^v")
    Sleep(120)
    A_Clipboard := prev
}
