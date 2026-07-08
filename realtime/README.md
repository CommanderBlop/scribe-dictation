# Scribe v2 Realtime — streaming prototype

Local terminal prototype for streaming dictation, before wiring it into the
Hammerspoon hotkey + paste flow.

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
- Realtime is billed at ~$0.39/audio-hour (≈1.8× the batch rate) — see the main README

## Next step

Wire into Hammerspoon: hotkey starts this streamer, committed segments get pasted
at the cursor (clipboard + ⌘V), hotkey again stops it. Batch `init.lua` stays as the
stable fallback.
