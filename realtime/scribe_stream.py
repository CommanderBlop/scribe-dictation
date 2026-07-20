#!/usr/bin/env python3
"""
Scribe v2 Realtime — local streaming engine.

Captures the mic via `sox` (raw PCM, no extra audio deps), streams it to the
ElevenLabs realtime speech-to-text WebSocket, and surfaces transcripts:
  - partial_transcript   -> interim text, reprinted in place (terminal mode)
  - committed_transcript  -> finalized segment

Two output modes:
  default   human view: '…' interim + '✓ text [lang]' finalized
  --emit    machine view: finalized text only, one plain line each, flushed.
            Used by the Hammerspoon Fn+F5 binding, which pastes each line.

Usage:
    export ELEVENLABS_API_KEY=sk-...
    python scribe_stream.py            # VAD auto-segmenting; Ctrl-C to stop
    python scribe_stream.py --manual   # manual commit strategy (no VAD)
    python scribe_stream.py --emit     # plain finalized lines (for Hammerspoon)

Requires: websockets (+ python-socks if behind a SOCKS proxy), sox (brew).
"""
import argparse
import asyncio
import base64
import json
import os
import shutil
import sys
import time

import websockets

WS_BASE = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
SOX = os.environ.get("SCRIBE_SOX_PATH") or shutil.which("sox") or "/opt/homebrew/bin/sox"
SAMPLE_RATE = 16000
CHUNK_BYTES = 3200  # 16-bit mono @16kHz -> 100ms per chunk


def build_url(commit_strategy: str, silence_secs: float, vad_threshold: float) -> str:
    params = {
        "model_id": "scribe_v2_realtime",
        "audio_format": f"pcm_{SAMPLE_RATE}",
        "commit_strategy": commit_strategy,  # "vad" or "manual"
        "include_language_detection": "true",
    }
    # vad_silence_threshold_secs: lower -> commits after a shorter pause -> text
    #   appears sooner (API default 1.5s). Committed text is final; pasting is safe.
    # vad_threshold: speech-vs-silence sensitivity (API default 0.4). Higher ->
    #   ignores low-level ambient sound, so the stream idles/auto-closes sooner.
    if commit_strategy == "vad":
        params["vad_silence_threshold_secs"] = f"{silence_secs:g}"
        params["vad_threshold"] = f"{vad_threshold:g}"
    return f"{WS_BASE}?" + "&".join(f"{k}={v}" for k, v in params.items())


async def pump_audio(ws, proc):
    """Read raw PCM from sox stdout and push base64 chunks to the socket."""
    try:
        while True:
            chunk = await proc.stdout.read(CHUNK_BYTES)
            if not chunk:
                break
            await ws.send(json.dumps({
                "message_type": "input_audio_chunk",
                "audio_base_64": base64.b64encode(chunk).decode("ascii"),
                "sample_rate": SAMPLE_RATE,
            }))
    except (websockets.ConnectionClosed, asyncio.CancelledError):
        pass


async def receive(ws, emit: bool):
    """Surface transcripts. `emit` -> plain finalized lines for piping."""
    last = None
    last_beat = 0.0
    try:
        async for raw in ws:
            try:
                m = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue  # ignore a malformed frame, keep streaming
            t = m.get("message_type")
            if t == "session_started":
                print(f"● session {m.get('session_id', '')[:8]} — speak now",
                      file=sys.stderr, flush=True)
            elif t == "partial_transcript":
                if emit:
                    # Heartbeat to stderr (throttled ~1/s) so the Hammerspoon
                    # idle-timer knows speech is still coming between commits.
                    now = time.monotonic()
                    if now - last_beat > 1.0:
                        last_beat = now
                        print("·", file=sys.stderr, flush=True)
                else:
                    sys.stdout.write("\r\033[K… " + m.get("text", ""))
                    sys.stdout.flush()
            # The server sends BOTH committed_transcript and *_with_timestamps for
            # each segment, and occasionally repeats the same segment; we use only
            # the richer one and drop consecutive duplicates, so every finalized
            # segment surfaces exactly once.
            elif t == "committed_transcript_with_timestamps":
                text = (m.get("text") or "").strip()
                if not text or text == last:
                    continue
                last = text
                if emit:
                    print(text, flush=True)          # one plain line -> Hammerspoon
                else:
                    lang = m.get("language_code", "")
                    tag = f" [{lang}]" if lang else ""
                    sys.stdout.write("\r\033[K✓ " + text + tag + "\n")
                    sys.stdout.flush()
            elif t == "committed_transcript":
                pass  # ignored — duplicate of the with_timestamps message
            elif t and "error" in t:
                print(f"[server {t}] {m.get('message') or m}", file=sys.stderr, flush=True)
    except websockets.ConnectionClosed as e:
        if e.code not in (1000, 1001):  # not a normal close
            print(f"[connection closed {e.code}] {e.reason or ''}".rstrip(),
                  file=sys.stderr, flush=True)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manual", action="store_true", help="manual commit (no VAD)")
    ap.add_argument("--emit", action="store_true",
                    help="print only finalized text, one plain line each")
    ap.add_argument("--silence", type=float, default=0.6,
                    help="VAD silence (secs) before a segment is finalized; "
                         "lower = faster output, less trailing context (API default 1.5)")
    ap.add_argument("--vad-threshold", type=float, default=0.4, dest="vad_threshold",
                    help="speech-vs-silence sensitivity 0-1 (API default 0.4); "
                         "higher = ignores ambient noise, idles/closes sooner")
    args = ap.parse_args()

    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY first.")
    if args.silence <= 0:
        sys.exit("--silence must be > 0 seconds")
    if not 0 < args.vad_threshold <= 1:
        sys.exit("--vad-threshold must be between 0 and 1")

    url = build_url("manual" if args.manual else "vad", args.silence, args.vad_threshold)
    # Capture sox's stderr so a failure (e.g. mic permission denied, no input
    # device) can be reported instead of hanging silently.
    try:
        proc = await asyncio.create_subprocess_exec(
            SOX, "-d", "-q", "-t", "raw", "-r", str(SAMPLE_RATE),
            "-b", "16", "-c", "1", "-e", "signed-integer", "-",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except (FileNotFoundError, PermissionError) as e:
        sys.exit(f"Could not start sox ({SOX}): {e}")

    try:
        async with websockets.connect(url, additional_headers={"xi-api-key": key},
                                      max_size=None) as ws:
            pump = asyncio.create_task(pump_audio(ws, proc))
            recv = asyncio.create_task(receive(ws, args.emit))
            # Stop as soon as either side ends (sox dying ends pump -> we exit,
            # rather than blocking forever waiting for transcripts).
            done, pending = await asyncio.wait({pump, recv},
                                               return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                exc = task.exception()
                if exc:
                    raise exc
    except websockets.InvalidStatus as e:
        sys.exit(f"WebSocket rejected (check your API key / permissions): {e}")
    finally:
        if proc.returncode is None:
            proc.terminate()
        await proc.wait()
        # If sox failed (not a normal 0 / our SIGTERM), surface its error.
        if proc.returncode not in (0, None, -15) and proc.stderr:
            err = (await proc.stderr.read()).decode(errors="replace").strip()
            if err:
                print(f"[sox] {err}", file=sys.stderr)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nstopped.", file=sys.stderr)
