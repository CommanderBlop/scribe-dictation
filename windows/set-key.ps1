# Set or reset your ElevenLabs API key. Stores it in the Windows Credential
# Manager (via Python keyring, service "scribe-dictation"), which the tool reads.
# Run any time to rotate the key.  Usage:  .\set-key.ps1

$repo = Split-Path -Parent $PSScriptRoot
$py = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }   # fall back to PATH python

Write-Host "Get a key at  https://elevenlabs.io/app/api  (Developers -> API Keys)"
Write-Host "(needs the 'Speech to Text' permission)."
$key = Read-Host "Paste your ElevenLabs API key"

if ($key -notmatch '^sk_[A-Za-z0-9]+$') {
    Write-Host "That doesn't look like an ElevenLabs key (expected sk_...). Nothing changed." -ForegroundColor Yellow
    exit 1
}

# Store via keyring; pass the key on stdin so it never lands on a command line.
$key | & $py -c "import keyring,sys; keyring.set_password('scribe-dictation','api', sys.stdin.read().strip()); print('==> API key saved to Windows Credential Manager.')"
