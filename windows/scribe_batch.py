#!/usr/bin/env python3
"""
Batch transcription for the Windows glue (scribe.ahk).

    python scribe_batch.py <wav> [outfile]

Sends the WAV to ElevenLabs Scribe v2 (REST) and writes the transcript to
`outfile` if given, otherwise stdout. ANY failure is written the same way as a
single line prefixed "SCRIBE-ERR " so nothing fails silently and the AHK side
can show it. Key: $ELEVENLABS_API_KEY, else Windows Credential Manager (keyring).
"""
import os
import sys


def get_key():
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        try:
            import keyring
            key = keyring.get_password("scribe-dictation", "api")
        except Exception:
            key = None
    return key


def transcribe(wav):
    import requests  # imported here so a missing dependency surfaces as a message
    if not os.path.exists(wav):
        return "SCRIBE-ERR recording not found: " + wav
    if os.path.getsize(wav) < 2000:
        return "SCRIBE-ERR the recording is empty — is the microphone working? (sox)"
    key = get_key()
    if not key:
        return "SCRIBE-ERR no API key. Run windows\\set-key.ps1"

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
    except Exception as e:
        return f"SCRIBE-ERR request failed ({e.__class__.__name__}): {e}"

    if r.status_code != 200:
        return f"SCRIBE-ERR API {r.status_code}: {r.text[:160]}"
    try:
        return (r.json() or {}).get("text", "").strip()
    except Exception:
        return "SCRIBE-ERR unexpected response from the API"


def main():
    outfile = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        result = transcribe(sys.argv[1]) if len(sys.argv) > 1 else "SCRIBE-ERR usage: scribe_batch.py <wav>"
    except Exception as e:  # e.g. missing 'requests'/'keyring'
        result = f"SCRIBE-ERR {e.__class__.__name__}: {e}"

    if outfile:
        try:
            with open(outfile, "w", encoding="utf-8") as f:
                f.write(result)
            return
        except Exception:
            pass
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
