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

### Change the hotkeys

Edit the top of `windows\scribe.ahk`:

```ahk
RT_KEY    := "^+Space"   ; realtime
BATCH_KEY := "^+b"       ; paragraph
```

AutoHotkey notation: `^` = Ctrl, `+` = Shift, `!` = Alt, `#` = Win. So Ctrl+Alt+Space
is `"^!Space"`, Ctrl+Shift+B is `"^+b"`. Save, then **quit from the tray and relaunch**
(or re-run the installer) to apply.

> Pick keys that don't clash with app shortcuts you use: **Ctrl+Shift+V** is
> "paste without formatting" almost everywhere, and **Ctrl+Shift+B** toggles the
> browser bookmarks bar / VS Code build — a global hotkey shadows those. `Ctrl+Alt+…`
> combos tend to be the safest.

## Practice mode (pacing timer)

For interview / public-speaking practice, the tool can drop a marker into the
transcript every minute so you can see your words-per-minute afterward:

```
So the main challenge was scaling the pipeline …
⏱ 1:00 · 132 words
… we sharded by tenant, which halved p99 latency …
⏱ 2:00 · 118 words
```

It's **off by default** (it writes markers into your text). Turn it on at the top of
`scribe.ahk`, then quit from the tray and relaunch:

```ahk
TIMER          := true   ; enable pacing markers
TIMER_INTERVAL := 60     ; seconds between markers (e.g. 300 for 5-minute marks)
```

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
