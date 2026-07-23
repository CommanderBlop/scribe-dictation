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
import re
import shutil
import sys
import time

import websockets

WS_BASE = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
SOX = os.environ.get("SCRIBE_SOX_PATH") or shutil.which("sox") or "/opt/homebrew/bin/sox"
SAMPLE_RATE = 16000
CHUNK_BYTES = 3200  # 16-bit mono @16kHz -> 100ms per chunk

# How sox opens the mic. macOS: "-d". Windows: bare "-d" fails ("no default audio
# device configured"), so use the waveaudio driver. Override with $SCRIBE_SOX_INPUT.
if os.environ.get("SCRIBE_SOX_INPUT"):
    SOX_INPUT = os.environ["SCRIBE_SOX_INPUT"].split()
elif sys.platform == "win32":
    SOX_INPUT = ["-t", "waveaudio", "default"]
else:
    SOX_INPUT = ["-d"]


def die(msg: str) -> None:
    """Print a one-line, Hammerspoon-recognizable fatal error, then exit."""
    print(f"SCRIBE-ERR {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# --- pacing timer (practice mode) helpers ---
# Bilingual word count: each CJK codepoint is one "word" (Chinese has no spaces),
# plus each Latin/number run counts as one.
_CJK = re.compile(r"[㐀-䶿一-鿿豈-﫿]")
_LATIN = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")


def count_words(s: str) -> int:
    return len(_CJK.findall(s)) + len(_LATIN.findall(s))


def mmss(secs: float) -> str:
    s = int(round(secs))
    return f"{s // 60}:{s % 60:02d}"


def build_url(commit_strategy: str, silence_secs: float, vad_threshold: float,
              include_timestamps: bool = False) -> str:
    params = {
        "model_id": "scribe_v2_realtime",
        "audio_format": f"pcm_{SAMPLE_RATE}",
        "commit_strategy": commit_strategy,  # "vad" or "manual"
        "include_language_detection": "true",
    }
    # The pacing timer needs per-word timestamps to credit each word to the minute it
    # was spoken; the committed_transcript_with_timestamps `words` array is empty
    # unless this is set (verified against the live API).
    if include_timestamps:
        params["include_timestamps"] = "true"
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


async def receive(ws, emit, outfh=None, interval=None, drain=None):
    """Surface transcripts. `emit` -> plain finalized lines for piping/out-file.

    `drain` (dict with "pending" flag + "evt" asyncio.Event) lets main() flush the
    tail on graceful stop: "pending" tracks whether speech has arrived since the
    last commit, and "evt" fires on every committed frame so the drain knows the
    forced flush has come back.

    If `interval` (seconds) is set, insert a pacing marker ([M:SS · N words]) every
    `interval`. Placement uses each word's absolute timestamp, so a word is credited
    to the interval in which it was *spoken*, not when the (possibly delayed) commit
    arrives — and a late commit spanning several intervals is split at the right word.
    """
    last = None
    last_beat = 0.0
    next_mark = interval          # None when the timer is off
    words_this_min = 0
    last_end = 0.0                # highest word end-time already emitted (dedup)

    def surface(line, marker=False):
        if emit:
            print(line, flush=True)
            if outfh:
                outfh.write(line + "\n")
                outfh.flush()
        else:
            prefix = "" if marker else "✓ "
            sys.stdout.write("\r\033[K" + prefix + line + "\n")
            sys.stdout.flush()

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
                if drain is not None and m.get("text"):
                    drain["pending"] = True   # speech seen since the last commit
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
                if drain is not None:
                    drain["pending"] = False
                    drain["evt"].set()        # the flush (or a VAD commit) landed
                text = (m.get("text") or "").strip()
                if not text or text == last:
                    continue
                last = text
                words = m.get("words") or []
                if next_mark is not None and words:
                    # Absolute-time dedup: the realtime server sometimes resends or
                    # overlaps a committed segment; take only words past the last
                    # end-time we've already emitted, so nothing gets pasted twice.
                    fresh = [w for w in words
                             if w.get("start") is not None and w["start"] > last_end - 0.05]
                    if not fresh:
                        if any(w.get("start") is not None for w in words):
                            continue   # every word already emitted: a pure resend
                        # No usable timestamps at all: never drop speech — degrade
                        # to plain text (marker placement resumes on the next commit).
                        surface(text)
                        words_this_min += count_words(text)
                        continue
                    last_end = max((w.get("end") or w.get("start") or last_end)
                                   for w in fresh)
                    # Split at each interval boundary using each word's absolute
                    # audio-time, so the marker lands on the right word and the count
                    # reflects what was actually said that interval.
                    bucket = []
                    for w in fresh:
                        st = w.get("start")
                        while st is not None and st >= next_mark:
                            seg = "".join(x.get("text", "") for x in bucket).strip()
                            if seg:
                                surface(seg)
                                words_this_min += count_words(seg)
                            surface(f"[{mmss(next_mark)} · {words_this_min} words]",
                                    marker=True)
                            words_this_min = 0
                            bucket = []
                            next_mark += interval
                        bucket.append(w)
                    seg = "".join(x.get("text", "") for x in bucket).strip()
                    if seg:
                        surface(seg)
                        words_this_min += count_words(seg)
                elif emit:
                    print(text, flush=True)          # one plain line -> the glue
                    if outfh:
                        outfh.write(text + "\n")
                        outfh.flush()
                else:
                    lang = m.get("language_code", "")
                    tag = f" [{lang}]" if lang else ""
                    sys.stdout.write("\r\033[K✓ " + text + tag + "\n")
                    sys.stdout.flush()
            elif t == "committed_transcript":
                pass  # ignored — duplicate of the with_timestamps message
            elif t and "error" in t:
                detail = m.get("error") or m.get("message") or t
                print(f"SCRIBE-ERR server: {detail}", file=sys.stderr, flush=True)
    except websockets.ConnectionClosed as e:
        # A deliberate drain closes the socket ourselves — whatever close code the
        # server race produces then, it isn't an error worth surfacing.
        if e.code not in (1000, 1001) and not (drain or {}).get("closing"):
            print(f"[connection closed {e.code}] {e.reason or ''}".rstrip(),
                  file=sys.stderr, flush=True)


async def watch_stop(stop_path, proc):
    """Graceful-stop trigger: when the glue creates `stop_path`, stop the mic (sox).
    pump_audio then drains sox's remaining buffered audio and finishes — main()'s
    cue to flush the un-committed tail before closing. A file (not a signal) so the
    same mechanism works on Windows, where AHK can't signal a hidden process."""
    while not os.path.exists(stop_path):
        await asyncio.sleep(0.15)
    if proc.returncode is None:
        proc.terminate()


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
    ap.add_argument("--out-file", default=None,
                    help="also append each finalized line here (for the Windows/AHK glue)")
    ap.add_argument("--timer", action="store_true",
                    help="practice mode: insert a pacing marker ([M:SS · N words]) every "
                         "--timer-interval seconds, placed by word timestamp")
    ap.add_argument("--timer-interval", type=float, default=60.0, dest="timer_interval",
                    help="seconds between pacing markers when --timer is set (default 60)")
    ap.add_argument("--stop-file", default=None, dest="stop_file",
                    help="graceful stop: when this file appears, stop the mic, flush "
                         "the not-yet-committed tail of speech, emit it, then exit "
                         "(instead of cutting it off)")
    args = ap.parse_args()

    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        try:
            import keyring  # type: ignore[import-not-found]
            key = keyring.get_password("scribe-dictation", "api")
        except Exception:
            key = None
    if not key:
        die("no API key found. (macOS: set-key.sh · Windows: set-key.ps1)")
    if args.silence <= 0:
        die("--silence must be > 0 seconds")
    if not 0 < args.vad_threshold <= 1:
        die("--vad-threshold must be between 0 and 1")
    interval = None
    if args.timer:
        if args.timer_interval <= 0:
            die("--timer-interval must be > 0 seconds")
        interval = args.timer_interval

    url = build_url("manual" if args.manual else "vad", args.silence, args.vad_threshold,
                    include_timestamps=interval is not None)

    outfh = None
    if args.out_file:
        try:
            outfh = open(args.out_file, "a", encoding="utf-8")
        except Exception:
            outfh = None

    # Capture sox's stderr so a failure (e.g. mic permission denied, no input
    # device) can be reported instead of hanging silently.
    try:
        proc = await asyncio.create_subprocess_exec(
            SOX, *SOX_INPUT, "-q", "-t", "raw", "-r", str(SAMPLE_RATE),
            "-b", "16", "-c", "1", "-e", "signed-integer", "-",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
    except (FileNotFoundError, PermissionError) as e:
        die(f"could not start sox ({SOX}): {e}")

    try:
        # close_timeout: bound the close handshake (library default 10s) so a stalled
        # network can't push a graceful stop past the glues' 8s force-kill watchdogs.
        async with websockets.connect(url, additional_headers={"xi-api-key": key},
                                      max_size=None, close_timeout=2) as ws:
            pump = asyncio.create_task(pump_audio(ws, proc))
            drain = {"pending": False, "evt": asyncio.Event()}
            recv = asyncio.create_task(receive(ws, args.emit, outfh, interval, drain))
            stopw = (asyncio.create_task(watch_stop(args.stop_file, proc))
                     if args.stop_file else None)
            done, pending = await asyncio.wait({pump, recv},
                                               return_when=asyncio.FIRST_COMPLETED)
            if pump in done and recv not in done:
                # Mic input ended (graceful stop via --stop-file, or sox died).
                # Don't cut off what was said but not yet committed: force-commit
                # it server-side (empty chunk + commit flag — works under VAD too),
                # wait for the final transcript(s), then close so recv ends cleanly.
                try:
                    drain["evt"].clear()
                    await ws.send(json.dumps({
                        "message_type": "input_audio_chunk", "audio_base_64": "",
                        "commit": True, "sample_rate": SAMPLE_RATE}))
                    hard = time.monotonic() + 8.0          # overall drain cap
                    to = 6.0 if drain["pending"] else 1.2  # nothing in flight -> quick
                    while True:
                        drain["evt"].clear()
                        try:
                            await asyncio.wait_for(
                                drain["evt"].wait(),
                                timeout=min(to, hard - time.monotonic()))
                        except (asyncio.TimeoutError, ValueError):
                            break
                        to = 0.8   # a commit landed; brief window for a follow-up
                except websockets.ConnectionClosed:
                    pass
                drain["closing"] = True
                try:
                    await ws.close()
                except websockets.WebSocketException:
                    pass
                try:
                    await asyncio.wait_for(recv, timeout=3.0)
                except asyncio.TimeoutError:
                    recv.cancel()
                    await asyncio.gather(recv, return_exceptions=True)
            else:
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
            if stopw:
                stopw.cancel()
                await asyncio.gather(stopw, return_exceptions=True)
            for task in done:
                exc = task.exception()
                if exc:
                    raise exc
    except websockets.InvalidStatus as e:
        code = getattr(getattr(e, "response", None), "status_code", None)
        if code == 401:
            die("authentication failed — check your API key and its Speech-to-Text permission.")
        die(f"server rejected the connection (HTTP {code or '?'}).")
    except (TimeoutError, OSError) as e:
        die(f"can't reach the realtime server ({e.__class__.__name__}). Behind a proxy or in a "
            "restricted region? Set M.proxy in init.lua. Fn+F4 recording mode still works.")
    except websockets.WebSocketException as e:
        die(f"WebSocket failed ({e.__class__.__name__}).")
    except Exception as e:  # never surface a raw multi-line traceback
        die(f"{e.__class__.__name__}: {e}")
    finally:
        if outfh:
            try:
                outfh.close()
            except Exception:
                pass
        if proc.returncode is None:
            proc.terminate()
        await proc.wait()
        # If sox failed (not a normal 0 / our SIGTERM), surface its error with the
        # SCRIBE-ERR tag so the glues show the real cause (mic unplugged/denied)
        # instead of silently going idle.
        if proc.returncode not in (0, None, -15) and proc.stderr:
            err = (await proc.stderr.read()).decode(errors="replace").strip()
            if err:
                print(f"SCRIBE-ERR sox: {err.splitlines()[-1]}", file=sys.stderr,
                      flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nstopped.", file=sys.stderr)
