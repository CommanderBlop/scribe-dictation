# Scribe v2 Realtime — streaming prototype

Small Python engine behind the Hammerspoon **Fn+F5** realtime hotkey. It can also
run directly in a terminal for testing.

It captures the mic with `sox` (raw PCM, no extra audio deps), streams to
`wss://api.elevenlabs.io/v1/speech-to-text/realtime`, and prints transcripts live:

- `…` interim text (partial_transcript, reprinted in place)
- `✓` finalized segment (committed_transcript) with detected `[language]`

## Run

From the project root:

```bash
# one-time: venv + deps (sox already installed via brew)
python3 -m venv .venv
.venv/bin/pip install -r realtime/requirements.txt   # websockets + python-socks

# each run — needs a key with the Speech to Text permission
export ELEVENLABS_API_KEY=sk-your-key
.venv/bin/python realtime/scribe_stream.py        # VAD auto-segmenting; Ctrl-C to stop
.venv/bin/python realtime/scribe_stream.py --manual
```

### Flags (what the glues pass)

| Flag | Used by | Purpose |
|------|---------|---------|
| `--emit` | both | machine view: finalized text only, one plain line each |
| `--out-file PATH` | Windows | also append each finalized line here (AHK polls this file) |
| `--silence SECS` / `--vad-threshold 0-1` | both | VAD tuning (see Protocol notes) |
| `--timer` / `--timer-interval SECS` | both | pacing markers `[M:SS · N words]` (practice mode) |
| `--stop-file PATH` | both | graceful stop: when this file appears, stop the mic, force-commit the un-transcribed tail, emit it, exit 0 |

> **Mic permission:** the terminal app you run this in (Terminal.app / iTerm)
> must have Microphone access in *System Settings → Privacy & Security →
> Microphone*. If you see `●session` but no transcripts when you speak, that
> permission is the usual cause.

Speak a mixed Chinese/English sentence — you should see interim text update as you
talk and a `✓` line each time you pause (VAD commit).

> **Behind a proxy?** If you get `connecting through a SOCKS proxy requires
> python-socks`, install it (it's in `requirements.txt`). `websockets` auto-detects
> `HTTPS_PROXY` / `ALL_PROXY` from your shell and routes through it.

## Protocol notes

- Model: `scribe_v2_realtime`
- Audio: `pcm_16000`, 100 ms chunks, base64 in `input_audio_chunk` messages
- Auth: `xi-api-key` header (no single-use token needed for local use)
- `commit_strategy=vad` lets the server segment on silence; `manual` defers commits
- `--silence <secs>` (default 0.6, API default 1.5) sets how long a pause finalizes a
  segment. Lower = text appears sooner; it's still the *committed* (final) transcript,
  never a partial, so pasted text is never revised afterwards. Tunable from Hammerspoon
  via `M.realtimeSilenceSecs`.
- `--vad-threshold <0-1>` (default 0.4 = API default) sets speech-vs-silence
  sensitivity. Raise it (e.g. 0.5–0.6) in a noisy room so low-level ambient sound isn't
  treated as speech — this makes Hammerspoon's inactivity auto-close (`M.realtimeIdleSecs`)
  trigger sooner after you actually stop talking. Too high can miss very quiet speech.
  Tunable via `M.realtimeVadThreshold`.
- **Word timestamps** (`include_timestamps=true`, set whenever `--timer` is on):
  `committed_transcript_with_timestamps.words` carries per-word `start`/`end` in
  seconds, **absolute across the whole session** (verified live — segment 2 starts
  at 5.8s, not 0). The array is empty without the query param.
- **Forced commit / graceful stop**: an `input_audio_chunk` with `"commit": true`
  (empty audio is fine) makes the server finalize everything it has — works under
  `commit_strategy=vad` too, in ~200 ms. There is *no* standalone `commit` message
  type (the server rejects it). `--stop-file` uses this so stopping mid-sentence
  emits the tail instead of cutting it off.
- Realtime is billed at ~$0.39/audio-hour (≈1.8× the batch rate) — see the main README

## How the glues consume this

Both platforms run this engine with `--emit` and paste each printed line at the
cursor: Hammerspoon (`init.lua`) reads stdout directly; AHK (`windows/scribe.ahk`)
polls `--out-file`. Stop is the `--stop-file` handshake above — the glue shows an
amber "working" state until the engine exits with the tail flushed. `SCRIBE-ERR …`
on stderr is the one-line fatal-error contract both glues surface to the user.
