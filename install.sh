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
SOX_PATH="$(command -v sox)"

# --- 3. download / update the tool ----------------------------------------
if [ -d "$REPO/.git" ]; then
  say "Updating Scribe Dictation…"; git -C "$REPO" pull --ff-only || true
else
  say "Downloading Scribe Dictation…"; mkdir -p "$HOME/projects"
  git clone "$REPO_URL" "$REPO"
fi

# --- 4. install the Hammerspoon config ------------------------------------
mkdir -p "$HOME/.hammerspoon"
# preserve an already-saved API key across re-runs / updates
OLD_KEY=""
[ -f "$DEST" ] && OLD_KEY="$(sed -n 's/.*or "\(sk_[A-Za-z0-9]*\)".*/\1/p' "$DEST" | head -1)"
# back up a pre-existing, unrelated Hammerspoon config
if [ -f "$DEST" ] && ! grep -q "Scribe Dictation\|Scribe v2 push-to-talk" "$DEST"; then
  cp "$DEST" "$DEST.bak.$(date +%s)"; say "Backed up your existing config to $DEST.bak.*"
fi
cp "$REPO/init.lua" "$DEST"
# fix sox path on Intel Macs
[ "$SOX_PATH" != "/opt/homebrew/bin/sox" ] && sed -i '' "s#/opt/homebrew/bin/sox#$SOX_PATH#g" "$DEST"
# restore a previously-saved key (only on the assignment line)
[ -n "$OLD_KEY" ] && sed -i '' "/^M.apiKey/ s#YOUR_ELEVENLABS_API_KEY#$OLD_KEY#" "$DEST"

# --- 5. API key ------------------------------------------------------------
if grep -q "YOUR_ELEVENLABS_API_KEY" "$DEST"; then
  echo
  echo "Get a key at  https://elevenlabs.io  ->  Profile  ->  API Keys"
  echo "(needs the 'Speech to Text' permission; add 'User -> Read' for the credit popup)."
  printf "Paste your API key here and press Return (or just Return to skip): "
  read -r KEY < /dev/tty || KEY=""
  if [ -n "$KEY" ]; then
    sed -i '' "/^M.apiKey/ s#YOUR_ELEVENLABS_API_KEY#$KEY#" "$DEST"; say "API key saved."
  else
    say "Skipped — open $DEST later and replace YOUR_ELEVENLABS_API_KEY."
  fi
fi

# the config may now hold your key in plaintext — restrict it to you
chmod 600 "$DEST" 2>/dev/null || true

# --- 6. optional realtime mode --------------------------------------------
printf "Enable realtime mode too (Fn+F4, live dictation)? [y/N]: "
read -r RT < /dev/tty || RT=""
if [ "$RT" = "y" ] || [ "$RT" = "Y" ]; then
  say "Setting up the realtime engine…"
  if ! python3 -m venv "$REPO/.venv" 2>/dev/null; then brew install python; python3 -m venv "$REPO/.venv"; fi
  "$REPO/.venv/bin/pip" install -q --upgrade pip
  "$REPO/.venv/bin/pip" install -q -r "$REPO/realtime/requirements.txt"
  say "Realtime ready."
fi

# --- 7. launch + open the permission panes --------------------------------
open -a Hammerspoon || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" || true

cat <<'DONE'

============================================================
 Two last clicks (macOS requires these by hand):

   1. In the Settings windows that just opened, switch ON
      "Hammerspoon" under BOTH Accessibility and Microphone.

   2. Click the hammer icon (🔨) in your top menu bar
      -> Reload Config.

 Then click into any text box (Claude, browser, Notes…),
 press  Fn+F5 , say something, press  Fn+F5  again.
 Your words appear where the cursor is.  🎙️
============================================================
DONE
