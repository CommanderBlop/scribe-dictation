# Scribe Dictation

System-wide push-to-talk dictation for macOS that replaces Apple Dictation with
**[ElevenLabs Scribe v2](https://elevenlabs.io/realtime-speech-to-text)**.

Press a hotkey, speak, and your words are transcribed and pasted at the cursor —
in any app (Claude desktop, browser, editor, anywhere a text field is focused).

**Why Scribe v2?** Its smart language detection handles **mixed-language speech**
out of the box. You can speak Chinese and English in the same sentence and it
transcribes both correctly — something Apple Dictation forces you to fight with a
fixed language setting.

It's a single [Hammerspoon](https://www.hammerspoon.org/) config file plus `sox`
for recording. Two modes:

- **Fn+F5 — paragraph mode** (default): record, then transcribe the whole
  utterance at once. Simple and reliable; text appears a moment after you stop.
- **Fn+F4 — realtime mode** (optional): stream the mic to Scribe v2 Realtime over a
  WebSocket and paste each segment as you pause. Needs a small Python engine —
  see [realtime/README.md](realtime/README.md).

---

## How it works

```
Fn+F5: hotkey ─► record mic (sox) ─► Scribe v2 (REST) ──────► paste whole text
Fn+F4: hotkey ─► stream mic (sox) ─► Scribe v2 Realtime (WS) ─► paste each segment
```

1. Hotkey → `sox` captures your mic.
2. Paragraph mode POSTs the WAV to the REST endpoint; realtime streams PCM chunks
   over the WebSocket.
3. Returned text is placed on the clipboard and pasted with ⌘V at the cursor.

---

## Requirements

- macOS (tested on Apple Silicon)
- [Homebrew](https://brew.sh/)
- An [ElevenLabs](https://elevenlabs.io/) account + API key

---

## Quick start

### 1. Install dependencies

```bash
brew install sox
brew install --cask hammerspoon
```

> On Intel Macs, `sox` installs to `/usr/local/bin/sox`. Check with `which sox`
> and update `M.sox` in `init.lua` if needed.

### 2. Install the config

```bash
mkdir -p ~/.hammerspoon
cp init.lua ~/.hammerspoon/init.lua
```

> ⚠️ If you already use Hammerspoon, this overwrites your `init.lua`. In that case
> save it as `~/.hammerspoon/scribe.lua` and add `require("scribe")` to your existing
> `init.lua` instead.

### 3. Add your API key

Get a key at **elevenlabs.io → Profile → API Keys**. Give it the **Speech to Text**
permission, and — if you want the credit toast (see below) — also **User → Read**.
Then edit `~/.hammerspoon/init.lua` and replace the placeholder:

```lua
M.apiKey = os.getenv("ELEVENLABS_API_KEY") or "YOUR_ELEVENLABS_API_KEY"
```

Hammerspoon is a GUI app and **won't** see a key you `export` in your shell.
Either paste the key directly into the line above, or set it for GUI apps with:

```bash
launchctl setenv ELEVENLABS_API_KEY sk-your-key-here
```

### 4. Launch and grant permissions

```bash
open -a Hammerspoon
```

Grant Hammerspoon two permissions in **System Settings → Privacy & Security**:

| Permission       | Why                                            |
|------------------|------------------------------------------------|
| **Accessibility**| Simulate ⌘V paste and capture global hotkeys   |
| **Microphone**   | `sox` records your mic (prompts on first use)  |

Then click the Hammerspoon menu-bar hammer → **Reload Config**. You should see a
"Scribe dictation loaded" notification.

### 5. Dictate

Focus any text field, press **Fn+F5**, speak, then press **Fn+F5** again. The
transcribed text is pasted at the cursor.

While recording a 🔴 appears in the menu bar; ⏳ while transcribing; nothing when idle.

---

## Hotkeys

| Action                          | Default  | Config field    |
|---------------------------------|----------|-----------------|
| Paragraph mode (record → paste) | `Fn+F5`  | `M.toggleKey`   |
| Realtime mode (stream → paste)  | `Fn+F4`  | `M.realtimeKey` |

Press once to start, press again to stop. The two modes are mutually exclusive —
while one is active, the other key is ignored. 🔴/⏳ shows in the menu bar for
paragraph mode, 🟢 for realtime.

### About the Fn+F5 key

On keyboards where the function row is media keys (the default), **single F5** is
the 🎤 Apple Dictation key, while **Fn+F5** sends a real F5 keycode. This config
binds plain `f5`, so **press Fn+F5** to dictate — no system settings to change, and
no conflict with Apple Dictation on single F5.

Prefer a bare F5 (no Fn)? Turn on *System Settings → Keyboard → Keyboard Shortcuts
→ Function Keys → "Use F1, F2, etc. as standard function keys"*, and optionally turn
off Apple Dictation so single F5 is free.

Want a different key/combo? Edit `M.toggleKey`, e.g. `{ mods = {"cmd","alt"}, key = "d" }`.

---

## Configuration

All settings live at the top of `init.lua`:

| Field            | Default                | Notes |
|------------------|------------------------|-------|
| `M.apiKey`       | env or placeholder     | Your ElevenLabs API key |
| `M.modelId`      | `"scribe_v2"`          | `scribe_v1` also available |
| `M.sox`          | `/opt/homebrew/bin/sox`| Path to the `sox` binary |
| `M.maxSecs`         | `120`               | Auto-stop after N seconds |
| `M.toggleKey`       | `Fn+F5`             | Press to start / press again to stop |
| `M.languageCode`    | `nil`               | `nil` = auto-detect; or force `"zh"`, `"en"`, … |
| `M.showCredits`     | `true`              | Show a credit toast after each transcription |
| `M.creditsPerMinute`| `18.7`              | Credits/min for paragraph mode estimate (plan-dependent) |
| `M.creditsPerMinuteRealtime`| `33.2`      | Credits/min for realtime estimate (realtime is ~1.77× pricier) |
| `M.proxy`           | `nil`               | Route curl via a proxy, e.g. `"http://127.0.0.1:7890"` |
| `M.realtimeKey`     | `Fn+F4`             | Realtime streaming toggle (`nil` to disable) |
| `M.pyProject`       | `~/projects/scribe-dictation` | Path to this repo (has `.venv` + `realtime/`) |

Leave `M.languageCode = nil` to get the mixed-language auto-detection that makes
Scribe worth using.

---

## Realtime mode (Fn+F4)

Paragraph mode (Fn+F5) works with nothing but Hammerspoon + sox. Realtime mode adds
live, segment-by-segment dictation by streaming to **Scribe v2 Realtime** over a
WebSocket. It uses a small Python engine, so it needs a one-time venv:

```bash
cd ~/projects/scribe-dictation          # wherever you cloned this repo
python3 -m venv .venv
.venv/bin/pip install -r realtime/requirements.txt
```

Point `M.pyProject` at that folder. Then press **Fn+F4** to start streaming (🟢),
speak, and each finalized segment is pasted as you pause; press Fn+F4 again to stop.
Details and troubleshooting: [realtime/README.md](realtime/README.md).

> Realtime is billed at **$0.39/audio-hour** (≈1.77× paragraph mode). The credit
> toast uses `M.creditsPerMinuteRealtime` for its estimate.

---

## Credit usage display

When `M.showCredits = true`, after each transcription a toast shows roughly:

```
💳 ~6 credits (12.4s) · 28,990 left
```

- **Remaining** is read live from `GET /v1/user/subscription` (`character_limit −
  character_count`). This needs the API key to have the **User → Read**
  (`user_read`) permission. Without it, the call is skipped silently — dictation
  still works, you just don't get the toast.
- **This clip's cost** is an *estimate* (`~`), computed from the recording length ×
  `M.creditsPerMinute`. ElevenLabs settles real usage with a ~50s delay, so an exact
  per-clip number isn't available immediately — the duration estimate is instant and
  close.

**The rate is plan-dependent.** ElevenLabs officially bills Scribe v1/v2 at
**$0.22 per audio hour, per minute** (not per token). The credits-per-minute then
depends on your plan's credit pool:

| Plan    | Credits / month | Included Scribe hours | ≈ credits / min |
|---------|-----------------|-----------------------|-----------------|
| Starter | 30,276          | 27 h                  | **18.7**        |
| Creator | 100,000         | 100 h                 | **16.7**        |

Set `M.creditsPerMinute` to match your plan. To verify empirically: note
`character_count` from the subscription endpoint, transcribe a clip of known length,
**wait ~1 minute** (usage settles with a delay), read it again, and divide the
credit difference by the minutes of audio. (Scribe v2 *Realtime* is pricier —
$0.39/hr — so its per-minute credit rate is ~1.8× the batch figures above.)

Set `M.showCredits = false` to disable the toast (and the extra API call) entirely.

---

## Troubleshooting

Open the Hammerspoon **Console** (menu-bar hammer → Console) to see logs.

| Symptom | Likely cause |
|---------|--------------|
| Nothing pastes | Accessibility permission not granted to Hammerspoon |
| No 🔴 / no audio | Microphone permission not granted, or wrong `M.sox` path |
| `Scribe API: ...` alert | Bad/expired API key, or out of credits |
| "empty/unexpected response" | Check Console for the raw response printed below it |
| `curl failed (28)` timeout | Network needs a proxy — Hammerspoon (GUI) doesn't see your shell's proxy vars. Set `M.proxy` |
| Fn+F5 does nothing | Some keyboards differ — remap `M.toggleKey` to e.g. `⌘⌥D` |

---

## Roadmap ideas

- ✅ Real-time streaming via Scribe v2 Realtime (WebSocket) — see [realtime/](realtime/README.md)
- `keyterms` support to bias domain vocabulary / names
- Native Swift menu-bar app for status, auto-launch, and device selection
- Pure-Lua realtime (drop the Python engine) if `hs.websocket` gains header auth

---

## Security note

Your API key is stored in plaintext in `init.lua`. Don't commit a real key.
The `init.lua` here ships with a placeholder; keep it that way in version control.

---

## License

MIT
