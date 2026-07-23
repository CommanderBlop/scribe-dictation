# Scribe Dictation — Windows installer.
# Run in PowerShell:
#   irm https://raw.githubusercontent.com/CommanderBlop/scribe-dictation/main/windows/install.ps1 | iex

$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "==> $m" -ForegroundColor Cyan }

# Inline (not a separate .ps1 file) so it runs under the same policy-free context
# as this iex'd script — loading a .ps1 from disk is blocked by the default
# "Restricted" execution policy.
function Set-ScribeKey($PyExe) {
    # Already stored? Keep it (don't re-prompt on re-runs).
    $have = & $PyExe -c "import keyring; print('yes' if keyring.get_password('scribe-dictation','api') else 'no')" 2>$null
    if ($have -eq 'yes') { Say "API key already in your Credential Manager - keeping it."; return }
    Write-Host "Get a key at  https://elevenlabs.io/app/api  (Developers -> API Keys, 'Speech to Text')."
    # -AsSecureString so the pasted key isn't echoed to the console / scrollback.
    $sec = Read-Host "Paste your ElevenLabs API key" -AsSecureString
    $key = [System.Net.NetworkCredential]::new('', $sec).Password
    if ($key -notmatch '^sk_[A-Za-z0-9]+$') {
        Write-Host "That doesn't look like an ElevenLabs key (sk_...). Skipped." -ForegroundColor Yellow
        return
    }
    # Pass via env var, not a stdin pipe (PowerShell's stdin pipe to a native exe
    # can hang the reader waiting for an EOF that never comes).
    $env:_SCRIBE_KEY = $key
    & $PyExe -c "import keyring,os; keyring.set_password('scribe-dictation','api', os.environ['_SCRIBE_KEY'])"
    Remove-Item Env:\_SCRIBE_KEY -ErrorAction SilentlyContinue
    Say "API key saved to Windows Credential Manager."
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget (App Installer) isn't available. Install 'App Installer' from the Microsoft Store (or update Windows), reopen PowerShell, and re-run this."
}

Say "Installing AutoHotkey, Python, git, sox via winget (approve any prompts)…"
winget install -e --id AutoHotkey.AutoHotkey --silent --accept-source-agreements --accept-package-agreements
winget install -e --id Python.Python.3.12    --silent --accept-source-agreements --accept-package-agreements
winget install -e --id Git.Git               --silent --accept-source-agreements --accept-package-agreements
# sox package id can vary between winget sources; try, but don't fail the install
try { winget install -e --id ChrisBagwell.SoX --silent --accept-source-agreements --accept-package-agreements } catch {}

# refresh PATH so freshly-installed tools are visible in this session
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")

# winget sets $ErrorActionPreference-immune native exit codes, so verify the tools
# we depend on actually landed rather than tripping confusingly a few lines down.
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python didn't install (or isn't on PATH). Install Python 3.12+ manually, reopen PowerShell, and re-run this."
}

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

# Find the AutoHotkey v2 exe — a silent winget install often doesn't set up the
# .ahk file association, so we launch the script via the exe directly.
$cands = Get-ChildItem "C:\Program Files\AutoHotkey","${env:LOCALAPPDATA}\Programs\AutoHotkey" `
    -Recurse -Filter "AutoHotkey*.exe" -ErrorAction SilentlyContinue | Select-Object -Expand FullName
$ahk = $cands | Where-Object { $_ -match '\\v2\\' -or $_ -match 'AutoHotkey64\.exe' } | Select-Object -First 1
if (-not $ahk) { $ahk = $cands | Select-Object -First 1 }
$script = "$repo\windows\scribe.ahk"

Say "Adding Start-menu + startup shortcuts…"
$ws = New-Object -ComObject WScript.Shell
$icon = "$repo\windows\icon-idle.ico"
function New-ScribeShortcut($path) {
    $sc = $ws.CreateShortcut($path)
    if ($ahk) { $sc.TargetPath = $ahk; $sc.Arguments = "`"$script`"" } else { $sc.TargetPath = $script }
    if (Test-Path $icon) { $sc.IconLocation = $icon }
    $sc.Save()
}
# Startup = auto-run at login; Programs = a clickable "Scribe Dictation" you can
# search in the Start menu to reopen it any time (e.g. after you Quit from the tray).
New-ScribeShortcut ([Environment]::GetFolderPath('Startup') + "\Scribe Dictation.lnk")
New-ScribeShortcut ([Environment]::GetFolderPath('Programs') + "\Scribe Dictation.lnk")

Say "Launching Scribe…"
if ($ahk) {
    Start-Process $ahk -ArgumentList "`"$script`""
    Write-Host "(Using AutoHotkey at: $ahk)"
} else {
    Write-Host "Couldn't find AutoHotkey.exe. Open AutoHotkey from the Start menu once, then double-click:`n  $script" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Click into any text box, press Ctrl+Shift+Space, talk, press again — text appears at your cursor." -ForegroundColor Green
Write-Host "Rotate the key any time:  powershell -ExecutionPolicy Bypass -File `"$repo\windows\set-key.ps1`""
