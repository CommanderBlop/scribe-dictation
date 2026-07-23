# Scribe Dictation — Windows package builder.  RUN ON WINDOWS.
#
# Produces  windows\dist\ScribeDictation\  — a self-contained folder that needs
# NO Python / AutoHotkey / sox installed on the end user's machine:
#
#     ScribeDictation\
#       scribe.ahk            (auto-detects bin\ and calls the frozen exes)
#       icon-*.ico
#       bin\
#         scribe_stream.exe   (realtime engine, frozen)
#         scribe_batch.exe    (paragraph transcription, frozen)
#         scribe_credits.exe  (credits balloon, frozen)
#         sox.exe + *.dll     (bundled recorder)
#
# The one-liner installer (install.ps1) stays the default distribution. This is
# only for when you want a double-click, no-prerequisites package.
#
# Prereqs on THIS (build) machine:
#   - Python 3.12+ on PATH        winget install -e --id Python.Python.3.12
#   - sox on PATH                 scoop install sox   (for bundling)
#   - AutoHotkey v2  (optional)   -> compiles scribe.ahk to scribe.exe (Ahk2Exe)
#   - Inno Setup     (optional)   -> `iscc` to build a setup.exe (see NEXT STEPS)
#   - a code-signing cert (optional but recommended) -> avoids SmartScreen
#
# Usage:   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-Zip]

param([switch]$Zip)

$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "WARN: $m" -ForegroundColor Yellow }

$win  = $PSScriptRoot
$repo = Split-Path -Parent $win
$dist = Join-Path $win "dist\ScribeDictation"
$bin  = Join-Path $dist "bin"
$work = Join-Path $win "build"           # PyInstaller scratch (spec/work)

# ---- checks ---------------------------------------------------------------
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python not found on PATH. Install Python 3.12+ and reopen the terminal."
}
$sox = (Get-Command sox -ErrorAction SilentlyContinue).Source
if (-not $sox) { Warn "sox not found on PATH — the package won't include a recorder. Install it (scoop install sox) and re-run to bundle it." }

# ---- clean ----------------------------------------------------------------
Say "Cleaning $dist …"
Remove-Item -Recurse -Force $dist, $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# ---- build venv (isolated from the runtime .venv) -------------------------
$bvenv = Join-Path $win ".build-venv"
Say "Creating build venv …"
python -m venv $bvenv
$bpy = Join-Path $bvenv "Scripts\python.exe"
& $bpy -m pip install -q --upgrade pip
& $bpy -m pip install -q -r (Join-Path $win "requirements.txt")
& $bpy -m pip install -q pyinstaller

# ---- freeze the three Python entry points ---------------------------------
# keyring's Windows Credential Manager backend is imported lazily, so tell
# PyInstaller to bundle all of keyring (and its win32 deps) explicitly.
function Freeze($name, $src) {
    Say "Freezing $name …"
    & $bpy -m PyInstaller --onefile --console --clean `
        --name $name --distpath $bin --workpath $work --specpath $work `
        --collect-all keyring `
        $src
    if (-not (Test-Path (Join-Path $bin "$name.exe"))) { throw "PyInstaller failed to produce $name.exe" }
}
Freeze "scribe_stream"  (Join-Path $repo "realtime\scribe_stream.py")
Freeze "scribe_batch"   (Join-Path $win  "scribe_batch.py")
Freeze "scribe_credits" (Join-Path $win  "scribe_credits.py")

# ---- bundle sox (exe + the DLLs that sit beside it) -----------------------
if ($sox) {
    Say "Bundling sox from $sox …"
    Copy-Item $sox $bin
    Get-ChildItem (Split-Path -Parent $sox) -Filter *.dll -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $bin }
}

# ---- assemble the user-facing folder --------------------------------------
Say "Assembling package …"
Copy-Item (Join-Path $win "scribe.ahk") $dist
Copy-Item (Join-Path $win "icon-idle.ico") $dist
Copy-Item (Join-Path $win "icon-live.ico") $dist
Copy-Item (Join-Path $win "icon-rec.ico")  $dist
Copy-Item (Join-Path $win "README.md")     $dist -ErrorAction SilentlyContinue

# ---- optional: compile scribe.ahk to a standalone scribe.exe --------------
$ahk2exe = Get-ChildItem "C:\Program Files\AutoHotkey","${env:LOCALAPPDATA}\Programs\AutoHotkey" `
    -Recurse -Filter "Ahk2Exe.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -Expand FullName
if ($ahk2exe) {
    Say "Compiling scribe.ahk -> scribe.exe (Ahk2Exe) …"
    & $ahk2exe /in (Join-Path $dist "scribe.ahk") /out (Join-Path $dist "scribe.exe")
    if (Test-Path (Join-Path $dist "scribe.exe")) {
        # if we have a compiled exe, the source .ahk is optional; keep it for transparency
        Say "Built scribe.exe — users can double-click it (AutoHotkey not required)."
    }
} else {
    Warn "Ahk2Exe not found — shipping scribe.ahk (end users then need the AutoHotkey v2 runtime). Install AutoHotkey v2 and re-run to get a standalone scribe.exe."
}

# ---- clean scratch --------------------------------------------------------
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

# ---- optional zip ---------------------------------------------------------
if ($Zip) {
    $zipPath = Join-Path $win "dist\ScribeDictation.zip"
    Say "Zipping -> $zipPath …"
    Remove-Item $zipPath -ErrorAction SilentlyContinue
    Compress-Archive -Path $dist -DestinationPath $zipPath
}

Write-Host ""
Write-Host "Done. Package at: $dist" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS (do these when you want a real distributable):" -ForegroundColor Green
Write-Host "  1. Code-sign  bin\*.exe  and  scribe.exe  with a code-signing cert:"
Write-Host "       signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a <file>"
Write-Host "     Unsigned exes trigger a SmartScreen 'protected your PC' warning."
Write-Host "  2. (Optional) Wrap it in an installer with Inno Setup — create a .iss that"
Write-Host "     copies this folder to %LOCALAPPDATA%\ScribeDictation, adds a Startup"
Write-Host "     shortcut, and runs set-key on first launch; build with:  iscc scribe.iss"
Write-Host "  3. Attach ScribeDictation.zip (or the setup.exe) to a GitHub Release."
