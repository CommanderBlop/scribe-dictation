-- ============================================================
--  Scribe Dictation — push-to-talk for macOS (Hammerspoon)
--  Fn+F5  realtime mode  : stream mic, paste each segment as you speak
--  Fn+F4  recording mode : record -> ElevenLabs Scribe v2 -> paste whole text
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
M.maxSecs  = 120          -- safety auto-stop while recording (recording mode)
M.toggleKey = { mods = {}, key = "f4" }   -- recording mode; media row: press Fn+F4
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
-- Practice mode: insert a pacing marker ([M:SS · N words]) into the transcript
-- every M.timerIntervalSecs of speaking, so you can see your words-per-minute.
-- Off by default — it writes markers into your text. Set to 300 for 5-min marks.
M.timer = false
M.timerIntervalSecs = 60
-- Hide Hammerspoon's own menu-bar icon so the Scribe dot is the single indicator
-- (like the one tray icon on Windows). Console / Reload / Quit live in the Scribe
-- menu instead; reopen after quitting via Spotlight ("Scribe Dictation").
M.hideHammerspoonIcon = true
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
    realtimeKey = M.realtimeKey, toggleKey = M.toggleKey,
    hideHammerspoonIcon = M.hideHammerspoonIcon,
  })
end
do
  local s = hs.settings.get(SETTINGS_KEY)
  if type(s) == "table" then
    if s.timer ~= nil then M.timer = s.timer end
    if s.timerIntervalSecs then M.timerIntervalSecs = s.timerIntervalSecs end
    if s.showCredits ~= nil then M.showCredits = s.showCredits end
    if s.hideHammerspoonIcon ~= nil then M.hideHammerspoonIcon = s.hideHammerspoonIcon end
    if type(s.realtimeKey) == "table" and s.realtimeKey.key then M.realtimeKey = s.realtimeKey end
    if type(s.toggleKey) == "table" and s.toggleKey.key then M.toggleKey = s.toggleKey end
  end
end

-- Hotkey presets, chosen from the menu-bar and persisted like the toggles above.
local RT_PRESETS = {
  { label = "F5",       mods = {},               key = "f5" },
  { label = "F6",       mods = {},               key = "f6" },
  { label = "⌃⇧Space",  mods = {"ctrl","shift"}, key = "space" },
  { label = "⌃⌥Space",  mods = {"ctrl","alt"},   key = "space" },
  { label = "⌘⇧D",      mods = {"cmd","shift"},  key = "d" },
}
local BATCH_PRESETS = {
  { label = "F4",       mods = {},               key = "f4" },
  { label = "F3",       mods = {},               key = "f3" },
  { label = "⌃⇧B",      mods = {"ctrl","shift"}, key = "b" },
  { label = "⌃⌥B",      mods = {"ctrl","alt"},   key = "b" },
}
local rtHotkey, batchHotkey
local function bindRealtime()
  if rtHotkey then rtHotkey:delete(); rtHotkey = nil end
  if M.realtimeKey then
    rtHotkey = hs.hotkey.bind(M.realtimeKey.mods, M.realtimeKey.key, function() M.rtToggle() end)
  end
end
local function bindRecording()
  if batchHotkey then batchHotkey:delete(); batchHotkey = nil end
  batchHotkey = hs.hotkey.bind(M.toggleKey.mods, M.toggleKey.key, function() M.toggle() end)
end
local function keyEq(a, p)   -- does current binding `a` equal preset `p`? (mods as sets)
  if not a or a.key ~= p.key then return false end
  local am = a.mods or {}
  if #am ~= #p.mods then return false end
  local set = {}
  for _, m in ipairs(am) do set[m] = true end
  for _, m in ipairs(p.mods) do if not set[m] then return false end end
  return true
end
local function setRealtimeKey(p)
  M.realtimeKey = { mods = p.mods, key = p.key }; bindRealtime(); saveSettings()
end
local function setRecordingKey(p)
  M.toggleKey = { mods = p.mods, key = p.key }; bindRecording(); saveSettings()
end
-- Human label for the current binding, e.g. ⌃⌥J — shown so a custom key is visible.
local MODSYM = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }
local function fmtKey(b)
  if not b or not b.key then return "off" end
  local has = {}
  for _, m in ipairs(b.mods or {}) do has[m] = true end
  local s = ""
  for _, m in ipairs({ "ctrl", "alt", "shift", "cmd" }) do
    if has[m] then s = s .. MODSYM[m] end
  end
  return s .. (b.key:gsub("^%l", string.upper))
end
-- "Custom…" — listen for the next real keypress and bind it live.
local function captureHotkey(setter)
  local tap, timeout
  local function stop()
    if tap then tap:stop(); tap = nil end
    if timeout then timeout:stop(); timeout = nil end
    hs.alert.closeAll()
  end
  tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local key = hs.keycodes.map[e:getKeyCode()]
    if not key then return true end
    if key == "escape" then stop(); hs.alert.show("Hotkey change cancelled."); return true end
    local flags, mods = e:getFlags(), {}
    for _, m in ipairs({ "cmd", "alt", "ctrl", "shift" }) do
      if flags[m] then mods[#mods + 1] = m end
    end
    if #mods == 0 and not key:match("^f%d+$") then
      stop()
      hs.alert.show("Use a modifier (⌘⌃⌥⇧) or an F-key so it won't hijack a normal key.", 3)
      return true
    end
    stop()
    setter({ mods = mods, key = key })
    hs.alert.show("Hotkey set.")
    return true   -- swallow the captured key
  end)
  tap:start()
  hs.alert.show("Press your shortcut…  (Esc to cancel)", 5)
  timeout = hs.timer.doAfter(5, function()
    if tap then tap:stop(); tap = nil; hs.alert.closeAll(); hs.alert.show("Hotkey capture timed out.") end
  end)
end

local function presetItems(presets, current, setter)
  local items, isPreset = {}, false
  for _, p in ipairs(presets) do
    local on = keyEq(current, p)
    if on then isPreset = true end
    items[#items + 1] = { title = p.label, checked = on, fn = function() setter(p) end }
  end
  items[#items + 1] = { title = "-" }
  -- If the current binding is a custom combo, show it (checked) so it's visible.
  if isPreset then
    items[#items + 1] = { title = "Custom…", fn = function() captureHotkey(setter) end }
  else
    items[#items + 1] = { title = "Custom: " .. fmtKey(current), checked = true,
                          fn = function() captureHotkey(setter) end }
  end
  return items
end

-- Menu-bar icon: always visible. State is a small muted dot — drawn (not an emoji),
-- so it's soft/semi-transparent and matches the Windows tray dots exactly. The
-- dropdown is a settings panel whose toggles persist via hs.settings (no file edits).
local function dotIcon(r, g, b, a, sz)
  sz = sz or 14
  local c = hs.canvas.new{ x = 0, y = 0, w = sz, h = sz }
  c[1] = { type = "circle", action = "fill",
           center = { x = sz / 2, y = sz / 2 }, radius = sz / 2 - 1,
           fillColor = { red = r, green = g, blue = b, alpha = a } }
  local img = c:imageFromCanvas()
  c:delete()
  img:template(false)   -- keep the color; a template image renders monochrome (all gray)
  return img
end
local DOTS = {   -- same colors as windows/icon-*.ico (soft, but a touch more vivid)
  idle      = dotIcon(150 / 255, 152 / 255, 158 / 255, 0.45),  -- dim gray = off
  realtime  = dotIcon(76 / 255, 182 / 255, 109 / 255, 0.95),   -- green
  recording = dotIcon(223 / 255, 94 / 255, 94 / 255, 0.95),    -- red
  working   = dotIcon(228 / 255, 176 / 255, 72 / 255, 0.95),   -- amber
}
-- Alert look: as close to the Spotlight "frosted card" feel as hs.alert allows
-- (real vibrancy/blur isn't exposed) — translucent dark card, borderless, soft
-- corners, system font at a calmer size. Applies to every alert we show.
for k, v in pairs({
  fillColor       = { white = 0.10, alpha = 0.80 },
  strokeWidth     = 0,
  strokeColor     = { alpha = 0 },
  radius          = 14,
  textSize        = 17,
  fadeInDuration  = 0.10,
  fadeOutDuration = 0.25,
}) do hs.alert.defaultStyle[k] = v end

local menu = hs.menubar.new(true)
local function setState(s)
  state = s
  if not menu then return end
  menu:returnToMenuBar()
  menu:setTitle("")
  menu:setIcon(DOTS[s] or DOTS.idle, false)   -- false = not a template, so color shows
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
  if wrote then
    M.apiKey = key
    -- Reload so everything (onboarding self-check included) picks the key up
    -- immediately — no "why does it still say no key" moment.
    hs.alert.show("API key saved — reloading…")
    hs.timer.doAfter(0.8, hs.reload)
  else hs.alert.show("Couldn't write to the Keychain.") end
end

-- Quit Hammerspoon entirely (the dot disappears). os.exit() skips
-- hs.shutdownCallback, so stop the children explicitly first. Reopen any time
-- from Spotlight: "Scribe Dictation" (or "Hammerspoon").
local function quitScribe()
  if rtTask and rtTask:isRunning() then rtTask:terminate() end
  if recTask and recTask:isRunning() then recTask:terminate() end
  hs.timer.doAfter(0.2, function() os.exit(0) end)
end

if menu then
  menu:setMenu(function()
    return {
      { title = "Scribe Dictation", disabled = true },
      { title = "-" },
      { title = "Pacing timer (practice)", checked = M.timer,
        fn = function() M.timer = not M.timer; saveSettings() end },
      { title = "Timer interval", menu = {
        { title = "10 seconds", checked = M.timerIntervalSecs == 10,
          fn = function() M.timerIntervalSecs = 10;  saveSettings() end },
        { title = "30 seconds", checked = M.timerIntervalSecs == 30,
          fn = function() M.timerIntervalSecs = 30;  saveSettings() end },
        { title = "1 minute",  checked = M.timerIntervalSecs == 60,
          fn = function() M.timerIntervalSecs = 60;  saveSettings() end },
        { title = "5 minutes", checked = M.timerIntervalSecs == 300,
          fn = function() M.timerIntervalSecs = 300; saveSettings() end },
      }},
      { title = "-" },
      { title = "Realtime hotkey  ·  " .. fmtKey(M.realtimeKey),
        menu = presetItems(RT_PRESETS, M.realtimeKey, setRealtimeKey) },
      { title = "Recording hotkey  ·  " .. fmtKey(M.toggleKey),
        menu = presetItems(BATCH_PRESETS, M.toggleKey, setRecordingKey) },
      { title = "-" },
      { title = "Show credit balloon", checked = M.showCredits,
        fn = function() M.showCredits = not M.showCredits; saveSettings() end },
      { title = "-" },
      { title = "Set / Update API key…", fn = setApiKey },
      { title = "Hammerspoon console", fn = function() hs.openConsole() end },
      -- checked = the Hammerspoon icon is currently visible
      { title = "Show/Hide Hammerspoon Icon", checked = not M.hideHammerspoonIcon,
        fn = function()
          M.hideHammerspoonIcon = not M.hideHammerspoonIcon
          hs.menuIcon(not M.hideHammerspoonIcon)
          saveSettings()
        end },
      { title = "Reload config", fn = function() hs.reload() end },
      { title = "Quit Scribe Dictation", fn = quitScribe },
    }
  end)
end
setState("idle")
-- Single-icon mode: with our dot in place, hide Hammerspoon's own menu icon.
-- (Explicitly restore it when the flag is off — hs.menuIcon persists across
-- launches, so a previous hide would otherwise stick.) If our menubar item
-- failed to create, keep the Hammerspoon icon as the fallback way in.
if M.hideHammerspoonIcon and menu then hs.menuIcon(false) else hs.menuIcon(true) end

local function paste(text)
  text = text:gsub("[\1-\8\11-\31\127]", "")   -- strip control chars (keep tab/newline)
  hs.pasteboard.setContents(text)
  if not hs.accessibilityState() then
    hs.alert.show("Grant Accessibility to Hammerspoon to auto-paste.\nText is on the clipboard — press ⌘V.", 5)
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
  local base = string.format("~%s credits (%.1fs)", commafy(est), durSecs or 0)
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
  if rtTask then return end   -- don't start recording mode while realtime streams
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
-- the cursor as you speak. A green menu-bar dot shows while streaming.
--
-- Pastes are queued and strictly serialized. The engine can emit several lines
-- nearly at once (the pacing timer splits one commit into text + marker + text);
-- overwriting the clipboard while an earlier ⌘V is still pending pastes the last
-- line N times and loses the others, so each clipboard→⌘V cycle must finish
-- before the clipboard changes again. Lines queued during a cycle are merged
-- into the next one (same result as pasting them back-to-back).
local rtQueue, rtPasting = {}, false
local rtWarnedAX = false   -- one no-Accessibility warning per session, not per line
local function rtDrain()
  if rtPasting or #rtQueue == 0 then return end
  if not hs.accessibilityState() then
    -- Can't auto-paste. Keep the queue: the clipboard accumulates the WHOLE
    -- session, so one manual ⌘V recovers everything instead of just the last line.
    hs.pasteboard.setContents(table.concat(rtQueue))
    if not rtWarnedAX then
      rtWarnedAX = true
      hs.alert.show("Grant Accessibility to Hammerspoon to auto-paste.\n" ..
                    "Dictation is accumulating on the clipboard — press ⌘V.", 5)
    end
    return
  end
  local text = table.concat(rtQueue)
  rtQueue = {}
  hs.pasteboard.setContents(text)
  rtPasting = true
  -- small delay so the focused app sees the new clipboard before ⌘V
  hs.timer.doAfter(0.08, function()
    hs.eventtap.keyStroke({"cmd"}, "v")
    -- let the app consume this paste before the clipboard changes again
    hs.timer.doAfter(0.12, function() rtPasting = false; rtDrain() end)
  end)
end
local function rtPaste(line)
  line = line:gsub("[\1-\8\11-\31\127]", ""):gsub("%s+$", "")
  if line == "" then return end
  -- Trailing space so segments don't glue together ("there.How") — the engine
  -- strips each segment's whitespace, and the Windows glue pastes `line " "` too.
  rtQueue[#rtQueue + 1] = line .. " "
  rtDrain()
end

-- Graceful stop: don't cut off speech that hasn't come back from the server yet.
-- Creating the stop file tells the engine to stop the mic, force-commit the
-- un-transcribed tail, emit it (pasted like any other line), then exit. The
-- amber "working" dot shows while that last flush is in flight; the task's exit
-- callback does the final cleanup. A second press while amber force-kills.
local RT_STOP_FILE = "/tmp/scribe_rt_stop"
local rtStopTimer            -- force-kill fallback if the engine wedges mid-drain
local function rtStop()
  if not rtTask then return end
  if state == "working" then                    -- already draining: force it now
    rtQueue = {}   -- force = drop the undelivered tail, don't leak it into a new session
    if rtTask:isRunning() then rtTask:terminate() end
    return
  end
  if rtIdleTimer then rtIdleTimer:stop(); rtIdleTimer = nil end
  setState("working")                           -- amber: finishing the last words
  local f = io.open(RT_STOP_FILE, "w")
  if f then f:close()
  else                                          -- can't signal: old hard stop
    if rtTask:isRunning() then rtTask:terminate() end
  end
  rtStopTimer = hs.timer.doAfter(8, function()
    if rtTask and rtTask:isRunning() then rtTask:terminate() end
  end)
end

-- Restart the inactivity clock; fires rtStop + a note if no new text arrives.
local function rtResetIdle()
  if not (M.realtimeIdleSecs and M.realtimeIdleSecs > 0) then return end
  if rtIdleTimer then rtIdleTimer:stop() end
  rtIdleTimer = hs.timer.doAfter(M.realtimeIdleSecs, function()
    if rtTask then
      rtStop()
      hs.alert.show("Realtime auto-closed — no speech for " .. M.realtimeIdleSecs ..
                    "s.\nPress " .. fmtKey(M.realtimeKey) .. " to start again.", 4)
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
  rtQueue = {}          -- never carry leftover lines from a force-killed session
  rtWarnedAX = false
  os.remove(RT_STOP_FILE)   -- a stale stop file would end the new stream instantly
  if menu then menu:returnToMenuBar(); menu:setTitle(""); menu:setIcon(DOTS.realtime, false) end
  local rtArgs = {"-u", M.pyProject .. "/realtime/scribe_stream.py", "--emit",
    "--silence", tostring(M.realtimeSilenceSecs),
    "--vad-threshold", tostring(M.realtimeVadThreshold),
    "--stop-file", RT_STOP_FILE}
  if M.timer then
    rtArgs[#rtArgs + 1] = "--timer"
    rtArgs[#rtArgs + 1] = "--timer-interval"
    rtArgs[#rtArgs + 1] = tostring(M.timerIntervalSecs)
  end
  rtTask = hs.task.new(M.pyProject .. "/.venv/bin/python",
    function()  -- on exit (after a graceful drain, or the engine dying): clean up.
      -- rtQueue/rtPasting are left alone — the last flushed lines may still be
      -- mid-paste-cycle, and the serialized queue finishes them on its own.
      rtTask = nil; rtBuf = ""
      if rtStopTimer then rtStopTimer:stop(); rtStopTimer = nil end
      if rtIdleTimer then rtIdleTimer:stop(); rtIdleTimer = nil end
      os.remove(RT_STOP_FILE)
      if rtStartTime > 0 then
        updateUsage(hs.timer.secondsSinceEpoch() - rtStartTime, M.creditsPerMinuteRealtime)
      end
      rtStartTime = 0
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

-- Hotkeys — bound via helpers so the menu-bar submenus can rebind them live.
-- Recording = press to start, press again to stop (whole utterance at once);
-- realtime = paste each segment as you speak.
bindRecording()
bindRealtime()

-- "Reload config" / quitting Hammerspoon while streaming or recording would leak
-- the child process (mic held open); shut them down first. Runs on hs.reload too.
hs.shutdownCallback = function()
  if rtTask and rtTask:isRunning() then rtTask:terminate() end
  if recTask and recTask:isRunning() then recTask:terminate() end
end

hs.alert.showWithImage("Scribe Dictation loaded — " .. fmtKey(M.realtimeKey) ..
                       " realtime · " .. fmtKey(M.toggleKey) .. " recording",
                       dotIcon(76 / 255, 182 / 255, 109 / 255, 0.95, 44))

-- Onboarding self-check: if setup is incomplete, say exactly what's missing
-- instead of failing silently on the first keypress. Only alerts on problems.
hs.timer.doAfter(0.6, function()
  local todo = {}
  if not M.apiKey:match("^sk_") then
    todo[#todo + 1] = "API key not set — menu-bar ⚪ → Set / Update API key…"
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
    hs.alert.show("Scribe needs setup:\n• " .. table.concat(todo, "\n• "), 8)
  end
end)
