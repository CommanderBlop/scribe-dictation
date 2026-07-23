# Scribe Dictation — Windows (⚠️ experimental)

A Windows port of the macOS tool, using **AutoHotkey v2** as the glue (global
hotkey + paste + tray) and reusing the Python side for transcription. This mirrors
the macOS architecture (thin glue + shared engine).

> **Status:** untested. It was written on a Mac and has never run on Windows yet —
> this first drop covers **paragraph mode only** (record → Scribe v2 REST → paste).
> Realtime streaming comes next, once the basics are validated. Expect rough edges;
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
permission). Rotate it any time with `windows\set-key.ps1`.

## Use

Click into any text box, press **Ctrl+Shift+Space**, talk, press it again — the
transcript is pasted at your cursor. A tray icon shows the state.

(F5 is "refresh" on Windows, so the hotkey is Ctrl+Shift+Space, not F5. Change
`HOTKEY_STR` at the top of `scribe.ahk` to taste.)

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
