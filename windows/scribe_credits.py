#!/usr/bin/env python3
"""
Print remaining ElevenLabs credits (character_limit - character_count), formatted
with thousands separators, to `outfile` if given else stdout. Prints nothing on any
error or if the key lacks the User->Read permission (so the tray notice just skips).

    python scribe_credits.py [outfile]
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


def remaining():
    import requests
    key = get_key()
    if not key:
        return ""
    proxies = None
    p = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if p:
        proxies = {"https": p, "http": p}
    r = requests.get(
        "https://api.elevenlabs.io/v1/user/subscription",
        headers={"xi-api-key": key}, timeout=10, proxies=proxies,
    )
    if r.status_code != 200:
        return ""
    j = r.json()
    if "character_limit" not in j or "character_count" not in j:
        return ""
    return f"{j['character_limit'] - j['character_count']:,}"


def main():
    try:
        out = remaining()
    except Exception:
        out = ""
    dest = sys.argv[1] if len(sys.argv) > 1 else None
    if dest:
        try:
            with open(dest, "w", encoding="utf-8") as f:
                f.write(out)
            return
        except Exception:
            pass
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
