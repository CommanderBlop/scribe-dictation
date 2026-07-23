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
TIMER     := false          ; practice mode: insert "[M:SS · N words]" markers into the text
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
cfgFile := EnvGet("LOCALAPPDATA") "\ScribeDictation\config.ini"  ; persisted toggles

state  := "idle"    ; idle | rt | batch
rtPid  := 0
recPid := 0
lastLen := 0
rtStopping := false ; guards the "engine died" check during a deliberate stop

LoadConfig()   ; override the CONFIG defaults above with any saved menu choices

try TraySetIcon(iconIdle)
A_IconTip := "Scribe — idle  (Ctrl+Shift+Space realtime · Ctrl+Shift+B paragraph)"

; Hotkey presets, chosen from the tray menu (label, AHK key string). Persisted
; like the toggles. AHK notation: ^=Ctrl +=Shift !=Alt #=Win.
RT_PRESETS := [["Ctrl+Shift+Space", "^+Space"], ["Ctrl+Alt+Space", "^!Space"], ["Ctrl+Shift+D", "^+d"], ["Ctrl+Alt+D", "^!d"]]
BATCH_PRESETS := [["Ctrl+Shift+B", "^+b"], ["Ctrl+Alt+B", "^!b"], ["Ctrl+Shift+G", "^+g"], ["Ctrl+Alt+G", "^!g"]]

; Right-click tray menu = a small settings panel; toggles persist to config.ini
; (in %LOCALAPPDATA%), so they survive restarts and `git pull` never clobbers them.
intervalMenu := Menu()
intervalMenu.Add("1 minute", (*) => SetInterval(60))
intervalMenu.Add("2 minutes", (*) => SetInterval(120))
intervalMenu.Add("5 minutes", (*) => SetInterval(300))

rtKeyMenu := Menu()
for i, p in RT_PRESETS
    rtKeyMenu.Add(p[1], SetRtKey.Bind(p[2]))
rtKeyMenu.Add()
rtKeyMenu.Add("Custom…", (*) => CaptureHotkey("rt"))
batchKeyMenu := Menu()
for i, p in BATCH_PRESETS
    batchKeyMenu.Add(p[1], SetBatchKey.Bind(p[2]))
batchKeyMenu.Add()
batchKeyMenu.Add("Custom…", (*) => CaptureHotkey("batch"))

A_TrayMenu.Delete()
A_TrayMenu.Add("Scribe Dictation", (*) => "")
A_TrayMenu.Disable("Scribe Dictation")
A_TrayMenu.Add()
A_TrayMenu.Add("Pacing timer (practice)", (*) => ToggleTimer())
A_TrayMenu.Add("Timer interval", intervalMenu)
A_TrayMenu.Add()
A_TrayMenu.Add("Realtime hotkey", rtKeyMenu)
A_TrayMenu.Add("Paragraph hotkey", batchKeyMenu)
A_TrayMenu.Add()
A_TrayMenu.Add("Show credits", (*) => ToggleCredits())
A_TrayMenu.Add()
A_TrayMenu.Add("Set / update API key…", (*) => SetApiKey())
A_TrayMenu.Add("Quit", (*) => ExitApp())
RefreshTrayChecks()

Hotkey(RT_KEY, HotkeyRealtime)
Hotkey(BATCH_KEY, HotkeyBatch)

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
            TrayTip(c " credits left", "Scribe", 1)
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

; ---------------- settings (tray menu + config.ini) ----------------
LoadConfig() {
    global cfgFile, TIMER, TIMER_INTERVAL, SHOW_CREDITS, RT_KEY, BATCH_KEY
    if !FileExist(cfgFile)
        return
    TIMER := IniRead(cfgFile, "scribe", "timer", TIMER ? "1" : "0") = "1"
    SHOW_CREDITS := IniRead(cfgFile, "scribe", "show_credits", SHOW_CREDITS ? "1" : "0") = "1"
    v := IniRead(cfgFile, "scribe", "timer_interval", TIMER_INTERVAL)
    if IsInteger(v) && Integer(v) > 0
        TIMER_INTERVAL := Integer(v)
    RT_KEY := IniRead(cfgFile, "scribe", "rt_key", RT_KEY)
    BATCH_KEY := IniRead(cfgFile, "scribe", "batch_key", BATCH_KEY)
}

SaveConfig() {
    global cfgFile, TIMER, TIMER_INTERVAL, SHOW_CREDITS, RT_KEY, BATCH_KEY
    try DirCreate(RegExReplace(cfgFile, "\\[^\\]+$"))   ; ensure the parent folder
    IniWrite(TIMER ? "1" : "0", cfgFile, "scribe", "timer")
    IniWrite(SHOW_CREDITS ? "1" : "0", cfgFile, "scribe", "show_credits")
    IniWrite(TIMER_INTERVAL, cfgFile, "scribe", "timer_interval")
    IniWrite(RT_KEY, cfgFile, "scribe", "rt_key")
    IniWrite(BATCH_KEY, cfgFile, "scribe", "batch_key")
}

RefreshTrayChecks() {
    global TIMER, SHOW_CREDITS, TIMER_INTERVAL, RT_KEY, BATCH_KEY
    global intervalMenu, rtKeyMenu, batchKeyMenu, RT_PRESETS, BATCH_PRESETS
    if TIMER
        A_TrayMenu.Check("Pacing timer (practice)")
    else
        A_TrayMenu.Uncheck("Pacing timer (practice)")
    if SHOW_CREDITS
        A_TrayMenu.Check("Show credits")
    else
        A_TrayMenu.Uncheck("Show credits")
    for label, secs in Map("1 minute", 60, "2 minutes", 120, "5 minutes", 300) {
        if TIMER_INTERVAL = secs
            intervalMenu.Check(label)
        else
            intervalMenu.Uncheck(label)
    }
    for i, p in RT_PRESETS {
        if RT_KEY = p[2]
            rtKeyMenu.Check(p[1])
        else
            rtKeyMenu.Uncheck(p[1])
    }
    for i, p in BATCH_PRESETS {
        if BATCH_KEY = p[2]
            batchKeyMenu.Check(p[1])
        else
            batchKeyMenu.Uncheck(p[1])
    }
}

; Hotkey callbacks (variadic to swallow the hotkey-name arg AHK passes).
HotkeyRealtime(*) => ToggleRealtime()
HotkeyBatch(*)    => ToggleBatch()

SetRtKey(newKey, *) {
    global RT_KEY, BATCH_KEY
    if newKey = BATCH_KEY {
        TrayTip("That's already the paragraph hotkey — pick another.", "Scribe", 3)
        return
    }
    try Hotkey(RT_KEY, HotkeyRealtime, "Off")   ; unbind the old
    RT_KEY := newKey
    try Hotkey(RT_KEY, HotkeyRealtime, "On")     ; bind the new
    SaveConfig()
    RefreshTrayChecks()
}

SetBatchKey(newKey, *) {
    global RT_KEY, BATCH_KEY
    if newKey = RT_KEY {
        TrayTip("That's already the realtime hotkey — pick another.", "Scribe", 3)
        return
    }
    try Hotkey(BATCH_KEY, HotkeyBatch, "Off")
    BATCH_KEY := newKey
    try Hotkey(BATCH_KEY, HotkeyBatch, "On")
    SaveConfig()
    RefreshTrayChecks()
}

; "Custom…" — a tiny window with AHK's native Hotkey control: press a combo, Save.
CaptureHotkey(kind) {
    title := "Scribe — set " (kind = "rt" ? "realtime" : "paragraph") " hotkey"
    g := Gui("+AlwaysOnTop -MinimizeBox", title)
    g.SetFont("s10")
    g.Add("Text", , "Press the shortcut you want, then click Save.`nInclude Ctrl / Alt / Shift / Win (or use an F-key).")
    hc := g.Add("Hotkey", "w240")
    save := g.Add("Button", "Default w90", "Save")
    g.Add("Button", "x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    save.OnEvent("Click", SaveCapture.Bind(kind, g, hc))
    g.Show()
}

SaveCapture(kind, g, hc, *) {
    v := hc.Value
    if v = "" {
        TrayTip("No key captured — press a combo first.", "Scribe", 2)
        return
    }
    if !RegExMatch(v, "[\^!+#]") && !RegExMatch(v, "i)F\d+$") {
        TrayTip("Use a combo with Ctrl/Alt/Shift/Win (or an F-key) so it won't hijack a normal key.", "Scribe", 4)
        return
    }
    g.Destroy()
    if kind = "rt"
        SetRtKey(v)
    else
        SetBatchKey(v)
}

ToggleTimer() {
    global TIMER
    TIMER := !TIMER
    SaveConfig()
    RefreshTrayChecks()
}

ToggleCredits() {
    global SHOW_CREDITS
    SHOW_CREDITS := !SHOW_CREDITS
    SaveConfig()
    RefreshTrayChecks()
}

SetInterval(secs) {
    global TIMER_INTERVAL
    TIMER_INTERVAL := secs
    SaveConfig()
    RefreshTrayChecks()
}

SetApiKey() {
    ; Reuse the audited set-key.ps1 (masked -AsSecureString input, stores to the
    ; Windows Credential Manager). The engine reads the key fresh on each use.
    setkey := A_ScriptDir "\set-key.ps1"
    if !FileExist(setkey) {
        TrayTip("set-key.ps1 not found next to scribe.ahk", "Scribe", 3)
        return
    }
    Run('powershell -NoProfile -ExecutionPolicy Bypass -File "' setkey '"')
}
