# Scribe Dictation — Windows (⚠️ experimental)

A Windows port of the macOS tool, using **AutoHotkey v2** as the glue (global
hotkey + paste + tray) and reusing the Python side for transcription. This mirrors
the macOS architecture (thin glue + shared engine).

> **Status:** early. Paragraph mode is confirmed working on Windows; realtime
> streaming is newly added. Written/maintained from a Mac, so expect rough edges —
> please report what breaks.

## Install

In **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/CommanderBlop/scribe-dictation/main/windows/install.ps1 | iex
```

It installs AutoHotkey, Python, git, and sox (via winget), sets up a Python venv,
asks for your **ElevenLabs API key** (stored in the Windows Credential Manager),
adds a startup shortcut, and launches the tool.

Get a key at **elevenlabs.io/app/api** (Developers → API Keys, *Speech to Text*
permission). Rotate it any time with:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\projects\scribe-dictation\windows\set-key.ps1"
```

(The `-ExecutionPolicy Bypass` is needed because Windows blocks running `.ps1`
files by default — the one-line installer sidesteps this by inlining the step.)

## Use

Two modes — click into any text box, then:

- **Ctrl+Shift+Space — realtime** (primary): text is pasted segment-by-segment as you
  speak; press again to stop.
- **Ctrl+Shift+B — paragraph** (fallback): record, press again to stop, and the whole
  clip is transcribed and pasted at once.

The **tray dot** shows state — 🟢 green = idle, 🔴 red = recording — and a small
balloon shows your **credits left** after each use. (F5 is "refresh" on Windows, so
the keys aren't F5; change them at the top of `scribe.ahk`.)

## Not needed on Windows

- **No Accessibility permission** — Windows doesn't gate synthetic paste like macOS.
- **Microphone** — usually already allowed for desktop apps; if recording is silent,
  check *Settings → Privacy & security → Microphone → Let desktop apps access your
  microphone*.

## Behind a proxy (e.g. mainland China)

Set `HTTPS_PROXY` for the tool's environment, e.g. `setx HTTPS_PROXY http://127.0.0.1:7890`
(then restart the tool). Batch mode uses REST, which is usually more reachable than
the realtime WebSocket.

## Known things to validate (first-run checklist)

These are the parts most likely to need fixing on real Windows:

1. **winget package IDs** — especially **sox** (`ChrisBagwell.SoX` may not exist in
   your winget source). If `sox` isn't found, install it another way (`scoop install
   sox`, or sox.sourceforge.net) and reopen the terminal.
2. **`sox -d` default input device** — on Windows sox uses the `waveaudio` driver;
   if recording fails, we may need `-t waveaudio -d` or a device name.
3. **Global hotkey** — whether Ctrl+Shift+Space is captured without running AHK as
   admin.
4. **Paste** — Ctrl+V into the focused app (blocked only if the target app runs as
   admin and this one doesn't — UIPI).
5. **`.ahk` launch** — Start-Process on the `.ahk` relies on AutoHotkey being
   installed and associated with `.ahk`.

## Architecture

```
scribe.ahk (AutoHotkey v2)              windows\scribe_batch.py (Python)
  global hotkey  ─ record (sox → raw)     reads key from Credential Manager
  stop           ─ raw → wav (sox)        POST wav → Scribe v2 REST
  paste (Ctrl+V) ◀─ transcript ◀──────────  prints the transcript
  tray icon
```

Uninstall: delete `%USERPROFILE%\projects\scribe-dictation`, remove the
`Scribe Dictation.lnk` from your Startup folder, and (optionally) `winget uninstall`
AutoHotkey / sox.
