# Scribe Dictation — Windows

A Windows port of the macOS tool, using **AutoHotkey v2** as the glue (global
hotkey + paste + tray) and reusing the Python side for transcription. This mirrors
the macOS architecture (thin glue + shared engine).

> **Status:** both modes (realtime + paragraph) are confirmed working on Windows.
> It's written/maintained from a Mac, so if something breaks, please open an issue —
> failures now surface as a tray notification rather than failing silently.

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

The **tray dot** shows state — ⚪ gray = idle, 🟢 green = realtime, 🔴 red = paragraph
recording — and a small balloon shows your **credits left** after each use.

**Right-click the tray icon** for a small settings menu: toggle the pacing timer and
its interval, the credit balloon, and **Set / update API key** (opens the masked key
prompt). Choices persist to `%LOCALAPPDATA%\ScribeDictation\config.ini`.

**Closed it / need to reopen?** It auto-starts at login. To reopen it now, search
**Scribe Dictation** in the Start menu (the installer adds an icon there) and click.
To close it, right-click the tray icon → **Quit**.

### Change the hotkeys

Right-click the tray icon → **Realtime hotkey** / **Paragraph hotkey** and pick a
preset (Ctrl+Shift+Space, Ctrl+Alt+Space, …). It rebinds immediately and is saved to
`config.ini`, so it sticks across restarts and a `git pull` won't reset it.

> Want a combo that isn't in the list? Edit `RT_KEY` / `BATCH_KEY` at the top of
> `scribe.ahk` (AutoHotkey notation: `^` = Ctrl, `+` = Shift, `!` = Alt, `#` = Win),
> then quit from the tray and relaunch. Avoid keys apps already use — **Ctrl+Shift+V**
> (paste-plain) and **Ctrl+Shift+B** (bookmarks bar / VS Code build); `Ctrl+Alt+…`
> combos tend to be safest.

## Practice mode (pacing timer)

For interview / public-speaking practice, the tool can drop a marker into the
transcript every minute so you can see your words-per-minute afterward:

```
So the main challenge was scaling the pipeline …
⏱ 1:00 · 132 words
… we sharded by tenant, which halved p99 latency …
⏱ 2:00 · 118 words
```

It's **off by default** (it writes markers into your text). Turn it on from the
**tray menu** — right-click the Scribe tray icon → **Pacing timer (practice)**, and
pick **Timer interval → 1 / 2 / 5 minutes**. Your choice is saved to
`%LOCALAPPDATA%\ScribeDictation\config.ini`, so it survives restarts and a `git pull`
never overwrites it. (It applies to the *next* time you start realtime.)

The marker is placed at the exact word where the minute ticks (using the API's word
timestamps), so per-minute counts are accurate — but since a segment only finalizes
when you pause, the marker *appears* when that segment commits, not exactly on the
second. Counts are bilingual (CJK characters + English words).

## Not needed on Windows

- **No Accessibility permission** — Windows doesn't gate synthetic paste like macOS.
- **Microphone** — usually already allowed for desktop apps; if recording is silent,
  check *Settings → Privacy & security → Microphone → Let desktop apps access your
  microphone*.

## Behind a proxy (e.g. mainland China)

Set `HTTPS_PROXY` for the tool's environment, e.g. `setx HTTPS_PROXY http://127.0.0.1:7890`
(then restart the tool). Batch mode uses REST, which is usually more reachable than
the realtime WebSocket.

## Troubleshooting

- **`sox` not found** — the winget id (`ChrisBagwell.SoX`) may not exist in your
  source. Install it another way (`scoop install sox`, or sox.sourceforge.net) and
  reopen the terminal. The installer warns if `sox` isn't on PATH.
- **Recording is silent** — sox uses the `waveaudio` driver on Windows (set via
  `MIC` at the top of `scribe.ahk`); if your default device isn't picked up, try a
  specific one, e.g. `MIC := "-t waveaudio 0"` or `"-t waveaudio ""Mic Name"""`.
- **Paste into an elevated app fails** — if the target app runs as admin and Scribe
  doesn't, Windows (UIPI) blocks the synthetic Ctrl+V. Run Scribe as admin too, or
  paste into a non-elevated window.
- **Nothing happens on the hotkey** — another app may already own it; change
  `RT_KEY` / `BATCH_KEY` (see above).

## Packaging (optional)

`build.ps1` (run on Windows) freezes the Python side with PyInstaller and bundles
sox + the icons into `dist\ScribeDictation\`, so end users need nothing
pre-installed. `scribe.ahk` auto-detects that `bin\` and calls the frozen exes. See
the header of `build.ps1` for the remaining steps (code-signing, an installer).

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
