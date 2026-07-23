# Scribe Dictation — Windows installer (EXPERIMENTAL, untested).
# Run in PowerShell:
#   irm https://raw.githubusercontent.com/CommanderBlop/scribe-dictation/main/windows/install.ps1 | iex

$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "==> $m" -ForegroundColor Cyan }

# Inline (not a separate .ps1 file) so it runs under the same policy-free context
# as this iex'd script — loading a .ps1 from disk is blocked by the default
# "Restricted" execution policy.
function Set-ScribeKey($PyExe) {
    Write-Host "Get a key at  https://elevenlabs.io/app/api  (Developers -> API Keys, 'Speech to Text')."
    $key = Read-Host "Paste your ElevenLabs API key"
    if ($key -notmatch '^sk_[A-Za-z0-9]+$') {
        Write-Host "That doesn't look like an ElevenLabs key (sk_...). Skipped." -ForegroundColor Yellow
        return
    }
    $key | & $PyExe -c "import keyring,sys; keyring.set_password('scribe-dictation','api', sys.stdin.read().strip())"
    Say "API key saved to Windows Credential Manager."
}

Say "Installing AutoHotkey, Python, git, sox via winget (approve any prompts)…"
winget install -e --id AutoHotkey.AutoHotkey --silent --accept-source-agreements --accept-package-agreements
winget install -e --id Python.Python.3.12    --silent --accept-source-agreements --accept-package-agreements
winget install -e --id Git.Git               --silent --accept-source-agreements --accept-package-agreements
# sox package id can vary between winget sources; try, but don't fail the install
try { winget install -e --id ChrisBagwell.SoX --silent --accept-source-agreements --accept-package-agreements } catch {}

# refresh PATH so freshly-installed tools are visible in this session
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")

$repo = "$HOME\projects\scribe-dictation"
if (Test-Path "$repo\.git") { Say "Updating Scribe Dictation…"; git -C $repo pull --ff-only }
else { Say "Downloading Scribe Dictation…"; git clone https://github.com/CommanderBlop/scribe-dictation $repo }

Say "Setting up the Python environment…"
python -m venv "$repo\.venv"
& "$repo\.venv\Scripts\python.exe" -m pip install -q --upgrade pip
& "$repo\.venv\Scripts\python.exe" -m pip install -q -r "$repo\windows\requirements.txt"

if (-not (Get-Command sox -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: 'sox' isn't on PATH. Install it (e.g. 'scoop install sox', or from sox.sourceforge.net) and reopen the terminal — recording needs it." -ForegroundColor Yellow
}

Set-ScribeKey "$repo\.venv\Scripts\python.exe"

Say "Adding a startup shortcut…"
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$startup\Scribe Dictation.lnk")
$sc.TargetPath = "$repo\windows\scribe.ahk"
$sc.Save()

Say "Launching Scribe…"
Start-Process "$repo\windows\scribe.ahk"

Write-Host ""
Write-Host "Done. Click into any text box, press Ctrl+Shift+Space, talk, press again — text appears at your cursor." -ForegroundColor Green
Write-Host "Rotate the key any time:  & '$repo\windows\set-key.ps1'"
