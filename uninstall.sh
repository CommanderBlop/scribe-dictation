#!/bin/bash
#
# Scribe Dictation — uninstaller. Reverses install.sh and the optional
# "store the key once" LaunchAgent. Anything shared (Homebrew, sox, the
# Hammerspoon app) or hard to undo is asked about first; nothing is forced.
#
# Run with:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/CommanderBlop/scribe-dictation/main/uninstall.sh)"
# or, from a local clone:  bash uninstall.sh

REPO="$HOME/projects/scribe-dictation"
DEST="$HOME/.hammerspoon/init.lua"
PLIST="$HOME/Library/LaunchAgents/com.scribe.elevenlabs-key.plist"
ZSHRC="$HOME/.zshrc"

say() { printf "\033[1;36m==>\033[0m %s\n" "$1"; }
ask() { printf "%s [y/N]: " "$1"; local a; read -r a < /dev/tty 2>/dev/null || a=""; [ "$a" = y ] || [ "$a" = Y ]; }

say "Uninstalling Scribe Dictation…"

# 1. stop Hammerspoon
osascript -e 'quit app "Hammerspoon"' 2>/dev/null || true

# 2. Hammerspoon config — restore a backup we made, else remove ours
if [ -f "$DEST" ] && grep -q "Scribe Dictation\|Scribe v2 push-to-talk" "$DEST" 2>/dev/null; then
  bak="$(ls -t "$DEST".bak.* 2>/dev/null | head -1)"
  if [ -n "$bak" ]; then
    mv "$bak" "$DEST"; say "Restored your previous Hammerspoon config from backup."
  else
    rm -f "$DEST"; say "Removed $DEST."
  fi
else
  say "$DEST isn't ours (or absent) — left untouched."
fi

# 3. optional "store the key once" LaunchAgent + shell line
if [ -f "$PLIST" ]; then
  launchctl unload -w "$PLIST" 2>/dev/null || true
  launchctl unsetenv ELEVENLABS_API_KEY 2>/dev/null || true
  rm -f "$PLIST"; say "Removed the API-key LaunchAgent and unset the variable."
fi
if grep -q "ELEVENLABS_API_KEY" "$ZSHRC" 2>/dev/null; then
  sed -i '' '/Scribe Dictation/d; /ELEVENLABS_API_KEY/d' "$ZSHRC"
  say "Removed the ELEVENLABS_API_KEY line(s) from ~/.zshrc."
fi

# 4. the downloaded repo (and its venv) — ask
if [ -d "$REPO" ] && ask "Delete the downloaded files at $REPO (includes the realtime venv)?"; then
  rm -rf "$REPO"; say "Removed $REPO."
fi

# 5. shared brew tools — ask, default no
if command -v brew >/dev/null 2>&1; then
  if ask "Uninstall the Hammerspoon app via brew? Skip if you use it for anything else"; then
    brew uninstall --cask hammerspoon 2>/dev/null || true
  fi
  if ask "Uninstall sox via brew? Skip if other tools rely on it"; then
    brew uninstall sox 2>/dev/null || true
  fi
fi

cat <<'DONE'

============================================================
 Done. Two things only you can do:

   1. Revoke the API key at elevenlabs.io -> Profile -> API Keys
      if you won't use it again.

   2. In System Settings -> Privacy & Security, remove
      "Hammerspoon" from Accessibility and Microphone if you
      uninstalled the app.

 Homebrew itself was left installed (other software may use it).
============================================================
DONE
