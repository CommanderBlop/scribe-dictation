#!/bin/bash
#
# Scribe Dictation — one-command installer for macOS.
# Run it with:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/CommanderBlop/scribe-dictation/main/install.sh)"
#
# It installs Homebrew (if needed), sox, and Hammerspoon; downloads this tool;
# asks you to paste your ElevenLabs API key; and opens the two permission panes.
# The only things it can't do for you (macOS won't allow it): creating the API
# key on elevenlabs.io, and ticking the two permission checkboxes.

set -e
REPO_URL="https://github.com/CommanderBlop/scribe-dictation.git"
REPO="$HOME/projects/scribe-dictation"
DEST="$HOME/.hammerspoon/init.lua"

say() { printf "\033[1;36m==>\033[0m %s\n" "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
  say "This installer supports macOS only. Nothing was changed."
  exit 1
fi

# --- 1. Homebrew -----------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew (you may be asked for your Mac login password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# put brew on PATH for this run (Apple Silicon or Intel)
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"

# --- 2. dependencies -------------------------------------------------------
say "Installing sox and Hammerspoon…"
brew list sox >/dev/null 2>&1            || brew install sox
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
SOX_PATH="$(command -v sox || true)"
if [ -z "$SOX_PATH" ]; then
  say "sox was installed but could not be found. Restart Terminal and rerun this installer."
  exit 1
fi

# --- 3. download / update the tool ----------------------------------------
if [ -d "$REPO/.git" ]; then
  say "Updating Scribe Dictation…"
  if ! git -C "$REPO" pull --ff-only; then
    say "Could not update the existing clone at $REPO. Resolve its Git changes, then rerun."
    exit 1
  fi
elif [ -e "$REPO" ]; then
  say "$REPO already exists but is not a Scribe Git clone. Move it aside, then rerun."
  exit 1
else
  say "Downloading Scribe Dictation…"; mkdir -p "$HOME/projects"
  git clone "$REPO_URL" "$REPO"
fi

# --- 4. install the Hammerspoon config ------------------------------------
mkdir -p "$HOME/.hammerspoon"
# back up a pre-existing, unrelated Hammerspoon config
if [ -f "$DEST" ] && ! grep -q "Scribe Dictation\|Scribe v2 push-to-talk" "$DEST"; then
  cp "$DEST" "$DEST.bak.$(date +%s)"; say "Backed up your existing config to $DEST.bak.*"
fi
cp "$REPO/init.lua" "$DEST"
chmod 600 "$DEST"
# fix sox path on Intel Macs (only if we actually found a different one)
[ -n "$SOX_PATH" ] && [ "$SOX_PATH" != "/opt/homebrew/bin/sox" ] && \
  sed -i '' "s#/opt/homebrew/bin/sox#$SOX_PATH#g" "$DEST"

# --- 5. API key (stored in the macOS Keychain, read by init.lua) ----------
# The key lives in the Keychain, not the config file — so it survives updates
# and can be reset any time with set-key.sh, independent of everything else.
if security find-generic-password -s elevenlabs-api -w >/dev/null 2>&1; then
  say "API key already in your Keychain — keeping it."
else
  bash "$REPO/set-key.sh" || say "No key yet — run 'bash $REPO/set-key.sh' any time to set it."
fi

# --- 6. realtime mode (the default Fn+F5 experience) ----------------------
say "Setting up the realtime engine…"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -m venv "$REPO/.venv" 2>/dev/null; then
  brew list python >/dev/null 2>&1 || brew install python
  "$(brew --prefix python)/bin/python3" -m venv "$REPO/.venv"
fi
"$REPO/.venv/bin/pip" install -q --upgrade pip
"$REPO/.venv/bin/pip" install -q -r "$REPO/realtime/requirements.txt"
say "Realtime ready."

# --- 7. explain + open permission panes, then reload Hammerspoon ----------
say "Opening the two macOS permission screens. Here's why each is needed:"
echo "   • Accessibility — lets Scribe simulate ⌘V to paste text at your cursor. That's its only use."
echo "   • Microphone    — lets sox record your voice. Nothing else is accessed."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" || true

# Load the config so there's no manual "Reload Config" step. Prefer the hs CLI
# if it's installed; otherwise relaunch the app (it reloads config on launch).
if command -v hs >/dev/null 2>&1 && hs -c "hs.reload()" >/dev/null 2>&1; then
  say "Reloaded Hammerspoon."
else
  osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
  sleep 1
  open -a Hammerspoon || true
fi

cat <<'DONE'

============================================================
 Almost there — flip two switches (macOS requires this by hand):

   In the Settings windows that just opened, turn ON
   "Hammerspoon" under BOTH Accessibility and Microphone.

 Then test it (about 10 seconds):
   1. Click into any text box (Claude, a browser, Notes…)
   2. Press  Fn+F5    (a 🟢 appears in the menu bar)
   3. Say a sentence
   4. Press  Fn+F5    again  →  your words appear at the cursor

 Fn+F5 is realtime mode. Fn+F4 is paragraph mode (press once to
 record, then again to transcribe the whole recording).

 Heads up: on most Macs single F5 is Apple Dictation — use Fn+F5.
 If the first press does nothing, see the README's Troubleshooting.

 (If Scribe ever seems inactive: menu-bar 🔨 → Reload Config.)
============================================================
DONE
