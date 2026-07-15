#!/usr/bin/env pwsh
<#
.SYNOPSIS
    SSH into Termux with full PTY support (tab completion, nano, job control).
.DESCRIPTION
    Auto-sets up ADB port forwarding, starts sshd if needed, then SSH in.
    Auto-detects WSL and adapts: portproxy relay, .exe suffix, host IP.
.PARAMETER SshArgs
    Arguments forwarded to ssh. No args = interactive shell; with args = run and exit.
.EXAMPLE
    .\termux-ssh.ps1
    .\termux-ssh.ps1 python --version
    .\termux-ssh.ps1 "pip list | grep numpy"
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SshArgs
)

# ── WSL detection and adaptation ─────────────────────────────────
$isWsl = Test-Path /proc/version -ErrorAction SilentlyContinue

if ($isWsl) {
    # Running under Linux PowerShell in WSL: need Windows tools
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

    # WSL2 cannot reach Windows localhost:8022 (adb forward port).
    # Determine Windows host IP and set up portproxy relay.
    $gateway = (ip route show default 2>$null | Select-String -Pattern 'via ([\d.]+)').Matches.Groups[1].Value
    if (-not $gateway) {
        $gateway = (Get-Content /etc/resolv.conf | Select-String 'nameserver').ToString().Split()[1]
    }
    $sshHost = $gateway
    $sshPort = '18022'

    # Ensure portproxy rule (idempotent)
    $proxyCheck = netsh.exe interface portproxy show v4tov4 2>$null
    if ($proxyCheck -notmatch '18022.*8022') {
        $null = netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=18022 connectaddress=127.0.0.1 connectport=8022
    }
} else {
    $adb = 'adb'
    $sshHost = 'localhost'
    $sshPort = '8022'
}

# ── Ensure ADB port forward ──────────────────────────────────────
$forwardList = & $adb forward --list 2>$null
if ($forwardList -notmatch 'tcp:8022.*tcp:8022') {
    $null = & $adb forward tcp:8022 tcp:8022
}

# ── Ensure sshd is running ───────────────────────────────────────
$sshdCheck = & $adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -x sshd" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting sshd..."
    $null = & $adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/sshd -p 8022"
    Start-Sleep -Seconds 1
}

# ── Dynamically resolve Termux username ──────────────────────────
$termuxUser = (& $adb shell "run-as com.termux whoami" 2>$null).Trim()
if (-not $termuxUser) {
    Write-Host "ERROR: Failed to get Termux username. Is ADB connected?" -ForegroundColor Red
    exit 1
}

# ── Connect ───────────────────────────────────────────────────────
$keyPath = if ($isWsl) {
    # WSL: ssh key lives in WSL home, not Windows profile
    "$env:HOME/.ssh/id_ed25519_termux"
} else {
    "$env:USERPROFILE\.ssh\id_ed25519_termux"
}

if (Test-Path $keyPath) {
    if ($SshArgs) {
        ssh -o StrictHostKeyChecking=accept-new -p $sshPort -i "$keyPath" "${termuxUser}@${sshHost}" @SshArgs
    } else {
        ssh -o StrictHostKeyChecking=accept-new -p $sshPort -i "$keyPath" "${termuxUser}@${sshHost}"
    }
} else {
    if ($SshArgs) {
        ssh -o StrictHostKeyChecking=accept-new -p $sshPort "${termuxUser}@${sshHost}" @SshArgs
    } else {
        ssh -o StrictHostKeyChecking=accept-new -p $sshPort "${termuxUser}@${sshHost}"
    }
}
