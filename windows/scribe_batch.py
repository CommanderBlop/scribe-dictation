#!/usr/bin/env python3
"""
Batch transcription for the Windows glue (scribe.ahk).

Takes a WAV file, sends it to ElevenLabs Scribe v2 (REST), and prints the
transcript to stdout. The AutoHotkey side records the audio and pastes the
result, so this stays tiny.

Key resolution: $ELEVENLABS_API_KEY, else the Windows Credential Manager
(via keyring, service "scribe-dictation"). Fatal errors print one line
prefixed "SCRIBE-ERR " so the AHK side can show a clean tray tip.

    python scribe_batch.py <path-to.wav>
"""
import os
import sys

import requests


def get_key():
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        try:
            import keyring
            key = keyring.get_password("scribe-dictation", "api")
        except Exception:
            key = None
    return key


def die(msg):
    print("SCRIBE-ERR " + msg, end="")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        die("usage: scribe_batch.py <wav>")
    wav = sys.argv[1]
    key = get_key()
    if not key:
        die("no API key. Run windows\\set-key.ps1")

    proxies = None
    p = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if p:
        proxies = {"https": p, "http": p}

    try:
        with open(wav, "rb") as f:
            r = requests.post(
                "https://api.elevenlabs.io/v1/speech-to-text",
                headers={"xi-api-key": key},
                data={"model_id": "scribe_v2"},
                files={"file": ("audio.wav", f, "audio/wav")},
                timeout=90,
                proxies=proxies,
            )
    except Exception as e:  # network / proxy / file
        die(f"request failed ({e.__class__.__name__}). Behind a proxy? set HTTPS_PROXY")

    if r.status_code != 200:
        die(f"API {r.status_code}: {r.text[:160]}")

    text = ""
    try:
        text = (r.json() or {}).get("text", "").strip()
    except Exception:
        die("unexpected response")

    # stdout = the transcript only (no trailing newline), for the AHK paste.
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
