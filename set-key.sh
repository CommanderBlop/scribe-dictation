#!/bin/bash
#
# Set or reset your ElevenLabs API key. Stores it in the macOS Keychain
# (encrypted), which init.lua reads. Safe to run any time to rotate the key.
#
#   bash set-key.sh
#
# After it runs, reload Hammerspoon (menu-bar 🔨 -> Reload Config).

SERVICE="elevenlabs-api"
say() { printf "\033[1;36m==>\033[0m %s\n" "$1"; }

echo "Get a key at  https://elevenlabs.io  ->  Profile  ->  API Keys"
echo "(it needs the 'Speech to Text' permission; add 'User -> Read' for the credit popup)."
printf "Paste your ElevenLabs API key and press Return: "
read -r KEY < /dev/tty 2>/dev/null || read -r KEY || KEY=""

# ElevenLabs keys are sk_ + alphanumerics; validate before storing.
if ! printf '%s' "$KEY" | grep -qE '^sk_[A-Za-z0-9]+$'; then
  say "That doesn't look like an ElevenLabs key (expected sk_…). Nothing changed."
  exit 1
fi

# -U updates if it already exists; -T authorizes the security tool to read it
# back without prompting (so Hammerspoon can fetch it silently).
if security add-generic-password -a "$USER" -s "$SERVICE" -T /usr/bin/security -w "$KEY" -U 2>/dev/null; then
  say "API key saved to your Keychain."
  say "Now reload Hammerspoon:  menu-bar 🔨  ->  Reload Config."
else
  say "Could not write to the Keychain."; exit 1
fi
