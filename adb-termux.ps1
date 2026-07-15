#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Execute a command inside Termux on Android via ADB.
.DESCRIPTION
    Generates a temp script with Termux environment boilerplate,
    pushes it to the device, and runs it via adb shell run-as.
    Auto-detects WSL and adapts paths / adb location accordingly.
    Color output is enabled (CLICOLOR_FORCE / FORCE_COLOR).
.PARAMETER CommandArgs
    The command to execute (remaining args are auto-joined, no quotes needed).
.EXAMPLE
    .\adb-termux.ps1 pip list
    .\adb-termux.ps1 python -c 'print(1+1)'
.NOTES
    For interactive shell, use termux-ssh.ps1 instead.
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

if (-not $CommandArgs) {
    Write-Host "Usage: adb-termux.ps1 <command> [args...]" -ForegroundColor Yellow
    Write-Host "Example: adb-termux.ps1 pip list" -ForegroundColor Yellow
    Write-Host "For interactive shell, use termux-ssh.ps1" -ForegroundColor Yellow
    exit 1
}

# ── WSL detection and adaptation ─────────────────────────────────
$isWsl = Test-Path /proc/version -ErrorAction SilentlyContinue

if ($isWsl) {
    # Running under Linux PowerShell in WSL: need Windows adb.exe
    if (Get-Command adb.exe -ErrorAction SilentlyContinue) {
        $adb = 'adb.exe'
    } else {
        $winAppData = (cmd.exe /c 'echo %LOCALAPPDATA%' 2>$null).Trim()
        $adb = "$(wslpath "$winAppData")/Android/platform-tools/adb.exe"
        if (-not (Test-Path $adb)) {
            Write-Host "ERROR: adb.exe not found. Install Android Platform Tools or add to PATH." -ForegroundColor Red
            exit 1
        }
    }
} else {
    $adb = 'adb'
}

# ── Build command and temp paths ─────────────────────────────────
$Command = $CommandArgs -join ' '
$TmpName = "_adb_termux_$PID.sh"

if ($isWsl) {
    # WSL: write to WSL temp, convert to Windows path for adb push
    $LocalTmp = "/tmp/$TmpName"
    $LocalTmpWin = wslpath -w $LocalTmp
} else {
    $LocalTmp = Join-Path $env:USERPROFILE $TmpName
}

$RemoteTmp = "/data/local/tmp/$TmpName"

# Build remote script (backtick-escape $ to prevent local expansion)
$ScriptContent = @"
#!/data/data/com.termux/files/usr/bin/bash
export HOME=/data/data/com.termux/files/home
export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:`$PATH
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
export PREFIX=/data/data/com.termux/files/usr
export TERM=xterm-256color
export CLICOLOR_FORCE=1
export FORCE_COLOR=1
cd `$HOME

$Command
"@

Set-Content -Path $LocalTmp -Value $ScriptContent -NoNewline

try {
    $pushPath = if ($isWsl) { $LocalTmpWin } else { $LocalTmp }
    & $adb push $pushPath $RemoteTmp
    if ($LASTEXITCODE -ne 0) { throw "adb push failed" }
    & $adb shell run-as com.termux /data/data/com.termux/files/usr/bin/bash $RemoteTmp
} finally {
    Remove-Item $LocalTmp -ErrorAction SilentlyContinue
    & $adb shell rm -f $RemoteTmp 2>$null
}
