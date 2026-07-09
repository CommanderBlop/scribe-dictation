-- ============================================================
--  Scribe Dictation — push-to-talk for macOS (Hammerspoon)
--  Fn+F5  paragraph mode : record -> ElevenLabs Scribe v2 -> paste whole text
--  Fn+F4  realtime mode  : stream mic, paste each segment as you speak
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
M.toggleKey = { mods = {}, key = "f5" }   -- paragraph mode; media row: press Fn+F5
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
-- Route curl through a proxy. Hammerspoon (a GUI app) doesn't inherit your
-- shell's proxy vars, so set this if your network needs one (e.g. Clash on
-- 127.0.0.1:7890) to avoid timeouts. nil = direct connection.
M.proxy = nil             -- e.g. "http://127.0.0.1:7890"
-- Realtime streaming mode (Fn+F4): pastes each finalized segment as you speak,
-- via the Python engine in realtime/scribe_stream.py (see realtime/README).
M.realtimeKey = { mods = {}, key = "f4" }            -- nil to disable
M.pyProject   = os.getenv("HOME") .. "/projects/scribe-dictation"  -- your cloned repo (.venv + realtime/)
-- How long a pause finalizes a realtime segment. Lower = text appears sooner
-- (still final, never revised after paste). API default 1.5s; 0.6 feels live.
M.realtimeSilenceSecs = 0.6
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

-- Use the proxy only if it's actually listening; otherwise go direct. Handles a
-- proxy app (e.g. Clash) being toggled on/off without breaking transcription.
local function activeProxy()
  if not M.proxy then return nil end
  local host, port = M.proxy:match("://([^:/]+):(%d+)")
  if not host then return M.proxy end   -- unparseable → trust the config
  local _, ok = hs.execute("/usr/bin/nc -z -G1 " .. host .. " " .. port .. " >/dev/null 2>&1")
  return ok and M.proxy or nil
end

local recTask, watchdog
local recStart, recDuration = 0, 0
local rtTask, rtBuf = nil, ""   -- realtime streamer task + stdout line buffer
local rtStartTime = 0           -- realtime stream start (for cost estimate)
local state = "idle"      -- idle | recording | working

-- Menu-bar icon: created on demand, only visible while active.
local menu = hs.menubar.new(false)   -- start hidden
local function setState(s)
  state = s
  if not menu then return end
  if s == "idle" then
    menu:removeFromMenuBar()
  else
    menu:returnToMenuBar()
    menu:setTitle(s == "recording" and "🔴" or "⏳")
  end
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

-- ---------- realtime streaming (Fn+F4) ----------
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
  if rtTask then
    if rtTask:isRunning() then rtTask:terminate() end
    rtTask = nil
    if rtStartTime > 0 then
      updateUsage(hs.timer.secondsSinceEpoch() - rtStartTime, M.creditsPerMinuteRealtime)
    end
  end
  rtStartTime = 0
  rtBuf = ""
  if menu then menu:removeFromMenuBar() end
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
  rtTask = hs.task.new(M.pyProject .. "/.venv/bin/python",
    function() rtTask = nil; rtBuf = ""; if menu then menu:removeFromMenuBar() end end,
    function(_, stdout, stderr)       -- stream stdout: paste each complete line
      if stderr and stderr ~= "" then
        for line in stderr:gmatch("[^\r\n]+") do
          if line:find("[Ee]rror") or line:find("rejected") or line:find("Set ELEVEN") then
            hs.alert.show("Realtime: " .. line, 4)
          end
        end
      end
      rtBuf = rtBuf .. (stdout or "")
      while true do
        local nl = rtBuf:find("\n")
        if not nl then break end
        rtPaste(rtBuf:sub(1, nl - 1))
        rtBuf = rtBuf:sub(nl + 1)
      end
      return true
    end,
    {"-u", M.pyProject .. "/realtime/scribe_stream.py", "--emit",
     "--silence", tostring(M.realtimeSilenceSecs)})
  local env = { ELEVENLABS_API_KEY = M.apiKey, PATH = "/opt/homebrew/bin:/usr/bin:/bin" }
  local px = activeProxy()
  if px then env.HTTP_PROXY = px; env.HTTPS_PROXY = px; env.ALL_PROXY = px end
  rtTask:setEnvironment(env)
  rtStartTime = hs.timer.secondsSinceEpoch()
  rtTask:start()
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

hs.alert.show("Scribe loaded — Fn+F5 paragraph · Fn+F4 realtime")
