#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Scribe Dictation — Windows glue
;  Ctrl+Shift+Space : realtime — stream & paste each segment as you speak
;  Ctrl+Shift+B     : paragraph (fallback) — record, then transcribe the whole clip
;  Tray dot: gray = idle, green = realtime, red = paragraph. Credit balloon after each use.
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
TIMER     := false          ; practice mode: insert "⏱ M:SS · N words" markers into the text
TIMER_INTERVAL := 60        ; seconds between pacing markers (e.g. 300 for 5-min marks)
; ----------------------------------------

repo    := A_ScriptDir "\.."
py      := repo "\.venv\Scripts\python.exe"
engine  := repo "\realtime\scribe_stream.py"
batch   := A_ScriptDir "\scribe_batch.py"
creditsPy := A_ScriptDir "\scribe_credits.py"
sox     := "sox"

; A packaged build (see windows\build.ps1) ships frozen exes + sox in .\bin.
; If they're present, call those; otherwise run the .py via the venv python
; (dev mode — the command strings below are identical to the plain python call).
bin := A_ScriptDir "\bin"
if FileExist(bin "\scribe_stream.exe") {
    engineCmd  := '"' bin '\scribe_stream.exe"'
    batchCmd   := '"' bin '\scribe_batch.exe"'
    creditsCmd := '"' bin '\scribe_credits.exe"'
    sox        := bin "\sox.exe"
    EnvSet("SCRIBE_SOX_PATH", sox)   ; so the frozen engine finds the bundled sox
} else {
    engineCmd  := '"' py '" "' engine '"'
    batchCmd   := '"' py '" "' batch '"'
    creditsCmd := '"' py '" "' creditsPy '"'
}

iconIdle := A_ScriptDir "\icon-idle.ico"   ; gray = idle
iconLive := A_ScriptDir "\icon-live.ico"   ; green = realtime
iconRec  := A_ScriptDir "\icon-rec.ico"    ; red = paragraph recording
rawF    := A_Temp "\scribe_rec.raw"
wavF    := A_Temp "\scribe_rec.wav"
streamF := A_Temp "\scribe_stream.txt"
rtErrF  := A_Temp "\scribe_stream_err.txt"  ; engine stderr, so failures surface
batOutF := A_Temp "\scribe_batch_out.txt"
credF   := A_Temp "\scribe_credits.txt"

state  := "idle"    ; idle | rt | batch
rtPid  := 0
recPid := 0
lastLen := 0
rtStopping := false ; guards the "engine died" check during a deliberate stop

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
    global state, rtPid, streamF, rtErrF, lastLen, rtStopping, engineCmd, MIC, SILENCE, VAD, MAX_SECS, iconLive, TIMER, TIMER_INTERVAL
    try FileDelete(streamF)
    try FileDelete(rtErrF)
    lastLen := 0
    rtStopping := false
    EnvSet("SCRIBE_SOX_INPUT", MIC)   ; tell the engine how to open the mic on Windows
    timerArg := TIMER ? " --timer --timer-interval " TIMER_INTERVAL : ""
    ; Route the engine's stderr to a file (via cmd /c) so failures — no key, sox
    ; can't open the mic, 401, network — can be shown instead of vanishing.
    Run(A_ComSpec ' /c "' engineCmd ' --emit --out-file "' streamF '" --silence ' SILENCE ' --vad-threshold ' VAD timerArg ' 2> "' rtErrF '""', , "Hide", &rtPid)
    state := "rt"
    Active("listening (realtime)", iconLive)
    SetTimer(PollStream, 150)
    SetTimer(RtAutoStop, -MAX_SECS * 1000)
}

StopRealtime(reason := "") {
    global rtPid, rtStopping
    rtStopping := true          ; so PollStream's death-check doesn't double-fire
    SetTimer(PollStream, 0)
    SetTimer(RtAutoStop, 0)
    PollStream()   ; flush any last segment
    if rtPid {
        RunWait('taskkill /PID ' rtPid ' /T /F', , "Hide")
        rtPid := 0
    }
    Idle()
    if reason != ""
        TrayTip(reason, "Scribe error", 3)
    else
        ShowCredits()
    rtStopping := false
}

PollStream() {
    global streamF, rtErrF, lastLen, rtPid, rtStopping
    Critical            ; don't let the 150ms timer re-enter mid-paste (clipboard race)
    if FileExist(streamF) {
        txt := FileRead(streamF, "UTF-8")
        if StrLen(txt) > lastLen {
            chunk := SubStr(txt, lastLen + 1)
            ; Consume only through the last newline; hold back any partial trailing
            ; line so a poll landing mid-write can't split a multi-byte (CJK) char.
            nl := InStr(chunk, "`n", , -1)
            if nl {
                ready := SubStr(chunk, 1, nl)
                lastLen += nl
                Loop Parse ready, "`n", "`r" {
                    line := Trim(A_LoopField)
                    if line != ""
                        PasteText(line " ")
                }
            }
        }
    }
    ; Engine exited on its own (crash / fatal error)? Surface it, don't spin to MAX_SECS.
    if !rtStopping && rtPid && !ProcessExist(rtPid) {
        rtPid := 0
        err := ""
        if FileExist(rtErrF) {
            Loop Parse FileRead(rtErrF, "UTF-8"), "`n", "`r" {
                if InStr(A_LoopField, "SCRIBE-ERR")
                    err := Trim(StrReplace(A_LoopField, "SCRIBE-ERR"))
            }
        }
        StopRealtime(err != "" ? err : "realtime engine stopped — check the mic, key, or network (see README).")
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
    try {
        Run(sox ' -q ' MIC ' -c 1 -r 16000 -b 16 -e signed-integer -t raw "' rawF '"', , "Hide", &recPid)
    } catch {
        TrayTip("Couldn't start sox — is it installed and on PATH? (see README)", "Scribe", 3)
        return
    }
    state := "batch"
    Active("recording (paragraph)", iconRec)
    SetTimer(BatchAutoStop, -MAX_SECS * 1000)
}

StopBatch() {
    global recPid, sox, batchCmd, rawF, wavF, batOutF, iconRec
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
    RunWait(batchCmd ' "' wavF '" "' batOutF '"', , "Hide")
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
    global SHOW_CREDITS, creditsCmd, credF
    if !SHOW_CREDITS
        return
    try FileDelete(credF)
    RunWait(creditsCmd ' "' credF '"', , "Hide")
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
