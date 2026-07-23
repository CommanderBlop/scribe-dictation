-- ============================================================
--  Scribe Dictation — push-to-talk for macOS (Hammerspoon)
--  Fn+F5  realtime mode  : stream mic, paste each segment as you speak
--  Fn+F4  paragraph mode : record -> ElevenLabs Scribe v2 -> paste whole text
--
--  Why: replaces Apple Dictation with ElevenLabs Scribe v2, whose smart
--  language detection handles mixed-language speech (e.g. Chinese + English
--  in one sentence) far better.
-- ============================================================

local M = {}

-- ---------- CONFIG ----------
-- API key (https://elevenlabs.io -> Profile -> API Keys). Needs the Speech to
-- Text permission; add User -> Read too if you want the credit toast.
-- Resolved at load in order: $ELEVENLABS_API_KEY, then this literal, then the
-- macOS Keychain (M.keychainService). Most secure: leave the literal as the
-- placeholder and store the key in the Keychain — see README "Store the key once".
M.apiKey   = os.getenv("ELEVENLABS_API_KEY") or "YOUR_ELEVENLABS_API_KEY"
M.keychainService = "elevenlabs-api"   -- Keychain generic-password service name
M.modelId  = "scribe_v2"
M.sox      = "/opt/homebrew/bin/sox"        -- `which sox` (Apple Silicon default)
M.recPath  = "/tmp/scribe_rec.wav"
M.maxSecs  = 120          -- safety auto-stop while recording (paragraph mode)
M.toggleKey = { mods = {}, key = "f4" }   -- paragraph mode; media row: press Fn+F4
-- Optional: bias language. nil = auto-detect (best for mixed speech).
M.languageCode = nil      -- e.g. "zh", "en", or nil for auto
-- Show a credit toast after each transcription. Requires the API key to have
-- the "User -> Read" (user_read) permission; otherwise it's skipped silently.
M.showCredits = true
-- STT credits per audio minute. Plan-dependent: Starter = 30,276 credits ÷
-- 27 included hours ≈ 18.7/min (official $0.22/hr, billed per minute).
M.creditsPerMinute = 18.7
-- Realtime is billed at $0.39/hr (≈1.77× batch) → ~33.2/min on Starter.
M.creditsPerMinuteRealtime = 33.2
-- Route requests through a proxy (Hammerspoon, a GUI app, doesn't inherit your
-- shell's proxy vars). "auto" follows the macOS system proxy (whatever tool/port
-- is set, read fresh each time); or give an explicit URL; nil = direct. Handy in
-- regions where the realtime WebSocket needs a proxy but batch would work direct.
M.proxy = "auto"          -- "auto" | nil | "http://127.0.0.1:7890"
-- Realtime streaming mode (Fn+F5): pastes each finalized segment as you speak,
-- via the Python engine in realtime/scribe_stream.py (see realtime/README).
M.realtimeKey = { mods = {}, key = "f5" }            -- nil to disable
M.pyProject   = os.getenv("HOME") .. "/projects/scribe-dictation"  -- your cloned repo (.venv + realtime/)
-- How long a pause finalizes a realtime segment. Lower = text appears sooner
-- (still final, never revised after paste). API default 1.5s; 0.6 feels live.
M.realtimeSilenceSecs = 0.6
-- Speech-vs-silence sensitivity (0-1, API default 0.4). Higher ignores low-level
-- ambient noise, so realtime idles/auto-closes sooner after you actually stop.
M.realtimeVadThreshold = 0.4
-- Auto-close realtime after this many seconds with no new text (you probably
-- forgot to stop it). Press Fn+F5 to resume. Set to 0 to disable.
M.realtimeIdleSecs = 30
-- Practice mode: insert a pacing marker (⏱ M:SS · N words) into the transcript
-- every M.timerIntervalSecs of speaking, so you can see your words-per-minute.
-- Off by default — it writes markers into your text. Set to 300 for 5-min marks.
M.timer = false
M.timerIntervalSecs = 60
-- ----------------------------

-- If no env var and no hardcoded key, fall back to the macOS Keychain.
-- (Reading it may prompt once for Keychain access — click "Always Allow".)
-- (service name guarded to safe chars so it can't break the shell string)
if not M.apiKey:match("^sk_") and M.keychainService and M.keychainService:match("^[%w._-]+$") then
  local out, ok = hs.execute(
    "/usr/bin/security find-generic-password -s '" .. M.keychainService .. "' -w 2>/dev/null")
  if ok and out then
    out = out:gsub("%s+$", "")
    if out:match("^sk_") then M.apiKey = out end
  end
end

-- Read the macOS system proxy so "auto" follows whatever tool/port is currently
-- configured, without hardcoding. HTTPS preferred, then HTTP, then SOCKS.
local function systemProxyURL()
  local out = hs.execute("/usr/sbin/scutil --proxy 2>/dev/null") or ""
  local function field(k) return (out:match(k .. "%s*:%s*([^\n]+)") or ""):gsub("%s+$", "") end
  local function enabled(k) return field(k):match("^1") ~= nil end
  local function url(scheme, hk, pk)
    local h, p = field(hk), field(pk)
    if h:match("^[%w%.%-]+$") and p:match("^%d+$") then return scheme .. "://" .. h .. ":" .. p end
  end
  if enabled("HTTPSEnable") then return url("http",   "HTTPSProxy", "HTTPSPort") end
  if enabled("HTTPEnable")  then return url("http",   "HTTPProxy",  "HTTPPort")  end
  if enabled("SOCKSEnable") then return url("socks5", "SOCKSProxy", "SOCKSPort") end
  return nil
end

-- Resolve M.proxy to a usable URL: "auto" follows the system proxy; then only
-- use it if the port is actually listening, else go direct. Adapts to a proxy
-- app being toggled on/off without breaking transcription.
local function activeProxy()
  if not M.proxy then return nil end
  local url
  if M.proxy == "auto" then url = systemProxyURL() else url = M.proxy end
  if not url then return nil end
  -- host restricted to safe hostname/IP chars so it can't inject into the shell.
  local host, port = url:match("://([%w%.%-]+):(%d+)")
  if not host then return url end   -- odd format → trust it (curl -x / env are not shell)
  local _, ok = hs.execute("/usr/bin/nc -z -G1 " .. host .. " " .. port .. " >/dev/null 2>&1")
  return ok and url or nil
end

local recTask, watchdog
local recStart, recDuration = 0, 0
local rtTask, rtBuf = nil, ""   -- realtime streamer task + stdout line buffer
local rtStartTime = 0           -- realtime stream start (for cost estimate)
local rtIdleTimer = nil         -- auto-close-on-inactivity timer
local state = "idle"      -- idle | recording | working

-- Persisted user toggles (survive reloads without editing this file). The M.*
-- values above are defaults; anything chosen in the menu-bar menu overrides them.
local SETTINGS_KEY = "scribe.settings"
local function saveSettings()
  hs.settings.set(SETTINGS_KEY, {
    timer = M.timer, timerIntervalSecs = M.timerIntervalSecs, showCredits = M.showCredits,
  })
end
do
  local s = hs.settings.get(SETTINGS_KEY)
  if type(s) == "table" then
    if s.timer ~= nil then M.timer = s.timer end
    if s.timerIntervalSecs then M.timerIntervalSecs = s.timerIntervalSecs end
    if s.showCredits ~= nil then M.showCredits = s.showCredits end
  end
end

-- Menu-bar icon: always visible. The title shows state; the dropdown is a small
-- settings panel whose toggles persist via hs.settings (no file editing).
local menu = hs.menubar.new(true)
local function setState(s)
  state = s
  if not menu then return end
  menu:returnToMenuBar()
  menu:setTitle(({ idle = "⚪", recording = "🔴", working = "⏳" })[s] or "⚪")
end

-- Prompt for a new API key (masked) and store it in the Keychain — same entry
-- set-key.sh writes, so it's picked up on the next dictation immediately.
local function setApiKey()
  hs.focus()
  local ok, res = hs.osascript.applescript(
    'display dialog "Paste your ElevenLabs API key (sk_…):" with title "Scribe" ' ..
    'default answer "" with hidden answer buttons {"Cancel", "Save"} default button "Save"')
  if not ok or type(res) ~= "table" then return end   -- Cancel raises → ok=false
  local key = res.textReturned or ""
  if not key:match("^sk_[A-Za-z0-9]+$") then
    hs.alert.show("That doesn't look like an sk_… key — nothing changed."); return
  end
  local user = os.getenv("USER") or ""
  local _, wrote = hs.execute("/usr/bin/security add-generic-password -a '" .. user ..
    "' -s '" .. M.keychainService .. "' -T /usr/bin/security -w '" .. key .. "' -U 2>/dev/null")
  if wrote then M.apiKey = key; hs.alert.show("✅ API key saved.")
  else hs.alert.show("Couldn't write to the Keychain.") end
end

if menu then
  menu:setMenu(function()
    return {
      { title = "Scribe Dictation", disabled = true },
      { title = "-" },
      { title = "Pacing timer (practice)", checked = M.timer,
        fn = function() M.timer = not M.timer; saveSettings() end },
      { title = "Timer interval", menu = {
        { title = "1 minute",  checked = M.timerIntervalSecs == 60,
          fn = function() M.timerIntervalSecs = 60;  saveSettings() end },
        { title = "2 minutes", checked = M.timerIntervalSecs == 120,
          fn = function() M.timerIntervalSecs = 120; saveSettings() end },
        { title = "5 minutes", checked = M.timerIntervalSecs == 300,
          fn = function() M.timerIntervalSecs = 300; saveSettings() end },
      }},
      { title = "-" },
      { title = "Show credit balloon", checked = M.showCredits,
        fn = function() M.showCredits = not M.showCredits; saveSettings() end },
      { title = "-" },
      { title = "Set / update API key…", fn = setApiKey },
      { title = "Reload config", fn = function() hs.reload() end },
    }
  end)
end
setState("idle")

local function paste(text)
  text = text:gsub("[\1-\8\11-\31\127]", "")   -- strip control chars (keep tab/newline)
  hs.pasteboard.setContents(text)
  if not hs.accessibilityState() then
    hs.alert.show("⚠️ Grant Accessibility to Hammerspoon to auto-paste.\nText is on the clipboard — press ⌘V.", 5)
    return
  end
  -- small delay so the focused app sees the new clipboard before ⌘V
  hs.timer.doAfter(0.12, function()
    hs.eventtap.keyStroke({"cmd"}, "v")
  end)
end

-- 12345 -> "12,345" (handles negatives, e.g. an over-quota balance)
local function commafy(n)
  local sign = n < 0 and "-" or ""
  local s = tostring(math.floor(math.abs(n)))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return sign .. (out:gsub("^,", ""))
end

-- Toast: estimated cost of this clip + real remaining balance.
-- ElevenLabs settles usage with a ~50s delay, so we estimate the cost from the
-- audio duration (ratePerMin) and read the live remaining balance from the
-- subscription endpoint (needs user_read; toast is skipped if unavailable, so
-- both modes behave the same).
local function updateUsage(durSecs, ratePerMin)
  if not M.showCredits then return end
  local est = math.floor((durSecs or 0) * (ratePerMin or M.creditsPerMinute) / 60 + 0.5)
  local base = string.format("💳 ~%s credits (%.1fs)", commafy(est), durSecs or 0)
  local uargs = {"-sS", "--max-time", "10",
                 "https://api.elevenlabs.io/v1/user/subscription",
                 "-H", "xi-api-key: " .. M.apiKey}
  local px = activeProxy()
  if px then table.insert(uargs, "-x"); table.insert(uargs, px) end
  hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
    if code ~= 0 then return end
    local ok, j = pcall(hs.json.decode, stdout)
    if not (ok and j and j.character_count and j.character_limit) then return end
    local remaining = j.character_limit - j.character_count
    hs.alert.show(base .. " · " .. commafy(remaining) .. " left", 2.5)
  end, uargs):start()
end

local function transcribe()
  setState("working")
  local args = {
    "-sS", "--connect-timeout", "10", "--max-time", "90",
    "--retry", "2", "--retry-delay", "1", "--retry-all-errors",
    "-X", "POST", "https://api.elevenlabs.io/v1/speech-to-text",
    "-H", "xi-api-key: " .. M.apiKey,
    "-F", "model_id=" .. M.modelId,
    "-F", "file=@" .. M.recPath,
  }
  if M.languageCode then
    table.insert(args, "-F"); table.insert(args, "language_code=" .. M.languageCode)
  end
  local px = activeProxy()
  if px then table.insert(args, "-x"); table.insert(args, px) end
  hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
    setState("idle")
    if code ~= 0 then
      hs.alert.show("Scribe: curl failed (" .. code .. "): " .. tostring(stderr))
      return
    end
    local ok, json = pcall(hs.json.decode, stdout)
    if ok and json and json.text and json.text ~= "" then
      paste(json.text)
      updateUsage(recDuration, M.creditsPerMinute)
    elseif ok and json and json.detail then
      hs.alert.show("Scribe API: " .. hs.inspect(json.detail))
    else
      hs.alert.show("Scribe: empty/unexpected response")
    end
  end, args):start()
end

local function startRec()
  if rtTask then return end   -- don't start paragraph mode while realtime streams
  if not M.apiKey:match("^sk_") then
    hs.alert.show("Set your ElevenLabs API key in init.lua first"); return
  end
  setState("recording")
  -- sox: default input device -> 16kHz mono 16-bit wav.
  -- transcribe() runs in this task's exit callback, so the wav is
  -- already finalized by the time we upload it.
  recStart = hs.timer.secondsSinceEpoch()
  recTask = hs.task.new(M.sox, function()
    recDuration = hs.timer.secondsSinceEpoch() - recStart
    transcribe()
  end, {"-d", "-c", "1", "-r", "16000", "-b", "16", M.recPath})
  recTask:start()
  watchdog = hs.timer.doAfter(M.maxSecs, function() M.stop() end)
end

function M.stop()
  if watchdog then watchdog:stop(); watchdog = nil end
  if recTask and recTask:isRunning() then
    -- SIGINT lets sox finalize a valid wav, then its exit callback fires
    hs.execute("/bin/kill -INT " .. recTask:pid())
  end
end

function M.toggle()
  if state == "recording" then M.stop()
  elseif state == "idle" then startRec() end
  -- ignore presses while "working"
end

-- ---------- realtime streaming (Fn+F5) ----------
-- Launches the Python engine; each finalized segment it prints is pasted at
-- the cursor as you speak. 🟢 in the menu bar while streaming.
local function rtPaste(line)
  line = line:gsub("[\1-\8\11-\31\127]", ""):gsub("%s+$", "")
  if line == "" then return end
  hs.pasteboard.setContents(line)
  if hs.accessibilityState() then
    hs.timer.doAfter(0.08, function() hs.eventtap.keyStroke({"cmd"}, "v") end)
  end
end

local function rtStop()
  if rtIdleTimer then rtIdleTimer:stop(); rtIdleTimer = nil end
  if rtTask then
    if rtTask:isRunning() then rtTask:terminate() end
    rtTask = nil
    if rtStartTime > 0 then
      updateUsage(hs.timer.secondsSinceEpoch() - rtStartTime, M.creditsPerMinuteRealtime)
    end
  end
  rtStartTime = 0
  rtBuf = ""
  setState("idle")
end

-- Restart the inactivity clock; fires rtStop + a note if no new text arrives.
local function rtResetIdle()
  if not (M.realtimeIdleSecs and M.realtimeIdleSecs > 0) then return end
  if rtIdleTimer then rtIdleTimer:stop() end
  rtIdleTimer = hs.timer.doAfter(M.realtimeIdleSecs, function()
    if rtTask then
      rtStop()
      hs.alert.show("Realtime auto-closed — no speech for " .. M.realtimeIdleSecs ..
                    "s.\nPress Fn+F5 to start again.", 4)
    end
  end)
end

local function rtStart()
  if rtTask or state ~= "idle" then return end
  if not M.apiKey:match("^sk_") then
    hs.alert.show("Set your ElevenLabs API key in init.lua first"); return
  end
  if not hs.fs.attributes(M.pyProject .. "/.venv/bin/python") then
    hs.alert.show("Realtime needs a venv at " .. M.pyProject ..
                  "/.venv (see realtime/README)", 4)
    return
  end
  rtBuf = ""
  if menu then menu:returnToMenuBar(); menu:setTitle("🟢") end
  local rtArgs = {"-u", M.pyProject .. "/realtime/scribe_stream.py", "--emit",
    "--silence", tostring(M.realtimeSilenceSecs),
    "--vad-threshold", tostring(M.realtimeVadThreshold)}
  if M.timer then
    rtArgs[#rtArgs + 1] = "--timer"
    rtArgs[#rtArgs + 1] = "--timer-interval"
    rtArgs[#rtArgs + 1] = tostring(M.timerIntervalSecs)
  end
  rtTask = hs.task.new(M.pyProject .. "/.venv/bin/python",
    function()  -- on exit: clean up (idle timer too, in case it died on its own)
      rtTask = nil; rtBuf = ""
      if rtIdleTimer then rtIdleTimer:stop(); rtIdleTimer = nil end
      setState("idle")
    end,
    function(_, stdout, stderr)       -- stream stdout: paste each complete line
      if stderr and stderr ~= "" then
        rtResetIdle()   -- any engine chatter (heartbeat) → still hearing speech
        for line in stderr:gmatch("[^\r\n]+") do
          local msg = line:match("^SCRIBE%-ERR (.+)")   -- clean, tagged error only
          if msg then hs.alert.show("Realtime: " .. msg, 6) end
        end
      end
      rtBuf = rtBuf .. (stdout or "")
      local pasted = false
      while true do
        local nl = rtBuf:find("\n")
        if not nl then break end
        rtPaste(rtBuf:sub(1, nl - 1)); pasted = true
        rtBuf = rtBuf:sub(nl + 1)
      end
      if pasted then rtResetIdle() end   -- new text → restart the idle clock
      return true
    end,
    rtArgs)
  local env = {
    ELEVENLABS_API_KEY = M.apiKey,
    SCRIBE_SOX_PATH = M.sox,
    PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
  }
  local px = activeProxy()
  if px then env.HTTP_PROXY = px; env.HTTPS_PROXY = px; env.ALL_PROXY = px end
  rtTask:setEnvironment(env)
  rtStartTime = hs.timer.secondsSinceEpoch()
  rtTask:start()
  rtResetIdle()   -- arm the inactivity auto-close
end

function M.rtToggle()
  if rtTask then rtStop() elseif state == "idle" then rtStart() end
end

-- Paragraph key (press to start, press again to stop) — whole utterance at once
hs.hotkey.bind(M.toggleKey.mods, M.toggleKey.key, M.toggle)

-- Realtime streaming key — paste each segment as you speak
if M.realtimeKey then
  hs.hotkey.bind(M.realtimeKey.mods, M.realtimeKey.key, M.rtToggle)
end

hs.alert.show("Scribe loaded — Fn+F5 realtime · Fn+F4 paragraph")

-- Onboarding self-check: if setup is incomplete, say exactly what's missing
-- instead of failing silently on the first keypress. Only alerts on problems.
hs.timer.doAfter(0.6, function()
  local todo = {}
  if not M.apiKey:match("^sk_") then
    todo[#todo + 1] = "API key not set — run  bash set-key.sh"
  end
  if not hs.accessibilityState() then
    todo[#todo + 1] = "Accessibility not granted (System Settings → Privacy)"
  end
  if not hs.fs.attributes(M.sox) then
    todo[#todo + 1] = "sox not found at " .. M.sox .. " — rerun install.sh"
  end
  if M.realtimeKey and not hs.fs.attributes(M.pyProject .. "/.venv/bin/python") then
    todo[#todo + 1] = "Realtime not installed — rerun install.sh"
  end
  if #todo > 0 then
    hs.alert.show("⚠️ Scribe needs setup:\n• " .. table.concat(todo, "\n• "), 8)
  end
end)
