#!/usr/bin/env pwsh
<#
.SYNOPSIS
    SSH into Termux with full PTY support (tab completion, nano, job control).
.DESCRIPTION
    Uses a temporary adb-forwarded local port, starts sshd if needed,
    then connects. Auto-detects WSL and adapts: portproxy relay, .exe suffix, host IP.
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

$remotePort = 8022
$proxyPortCandidates = @(18022,18023,18024,18025,28022,28023,28024,38022,38023,38024)

$isWsl = Test-Path /proc/version -ErrorAction SilentlyContinue

if ($isWsl) {
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
    $gateway = (ip route show default 2>$null | Select-String -Pattern 'via ([\d.]+)').Matches.Groups[1].Value
    if (-not $gateway) {
        $gateway = (Get-Content /etc/resolv.conf | Select-String 'nameserver').ToString().Split()[1]
    }
    $sshHost = $gateway
} else {
    $adb = 'adb'
    $sshHost = 'localhost'
}

# Check ADB state without opening an adb shell (shell can hang if adbd is unresponsive).
$adbState = (& $adb get-state 2>$null | Out-String).Trim()
if ($adbState -ne 'device') {
    Write-Host "ERROR: ADB is not connected or the device is unauthorized (state: $adbState)." -ForegroundColor Red
    exit 1
}

function Get-ForwardPorts {
    param(
        [string]$Adb,
        [int]$RemotePort
    )
    $ports = @()
    $lines = & $Adb forward --list 2>$null
    foreach ($line in $lines) {
        if ($line -match "tcp:(\d+) tcp:$RemotePort\b") {
            $ports += [int]$Matches[1]
        }
    }
    return $ports
}

# Ask adb to allocate a temporary local port (tcp:0).
$beforePorts = @(Get-ForwardPorts -Adb $adb -RemotePort $remotePort)
$allocOutput = (& $adb forward tcp:0 tcp:$remotePort 2>$null | Out-String).Trim()
$localPort = $null
if ($allocOutput -match '^[0-9]+$') {
    $localPort = [int]$allocOutput
} else {
    $afterPorts = @(Get-ForwardPorts -Adb $adb -RemotePort $remotePort)
    $localPort = $afterPorts | Where-Object { $beforePorts -notcontains $_ } | Select-Object -First 1
}
if (-not $localPort) {
    Write-Host "ERROR: Failed to allocate a temporary ADB forward port." -ForegroundColor Red
    exit 1
}

function Ensure-PortProxy {
    param(
        [int]$LocalPort,
        [int]$RemotePort,
        [int[]]$Candidates
    )
    $proxyText = netsh.exe interface portproxy show v4tov4 2>$null

    # Reuse an existing rule that already points at the chosen local port.
    foreach ($line in $proxyText) {
        if ($line -match "\b(\d+)\s+127\.0\.0\.1\s+$LocalPort\b") {
            return [int]$Matches[1]
        }
    }

    # Update the old rule that used the fixed remote port.
    foreach ($line in $proxyText) {
        if ($line -match "\b(\d+)\s+127\.0\.0\.1\s+$RemotePort\b") {
            $oldPort = [int]$Matches[1]
            $null = netsh.exe interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$oldPort 2>$null
            $null = netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$oldPort connectaddress=127.0.0.1 connectport=$LocalPort 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $oldPort
            }
        }
    }

    # Try a fresh proxy port if no existing/old rule could be reused.
    foreach ($p in $Candidates) {
        $used = $false
        foreach ($line in $proxyText) {
            if ($line -match "\b$p\b") {
                $used = $true
                break
            }
        }
        if (-not $used) {
            $null = netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$p connectaddress=127.0.0.1 connectport=$LocalPort 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $p
            }
        }
    }
    return $null
}

if ($isWsl) {
    $proxyPort = Ensure-PortProxy -LocalPort $localPort -RemotePort $remotePort -Candidates $proxyPortCandidates
    if (-not $proxyPort) {
        Write-Host "ERROR: Failed to set up Windows portproxy for WSL." -ForegroundColor Red
        exit 1
    }
    $sshPort = $proxyPort
} else {
    $sshPort = $localPort
}

$sshdCheck = & $adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -f sshd" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting sshd..."
    $sshdScript = 'export HOME=/data/data/com.termux/files/home; export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH; export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib; export PREFIX=/data/data/com.termux/files/usr; exec /data/data/com.termux/files/usr/bin/sshd -p ' + $remotePort
    $sshdCommand = "run-as com.termux /data/data/com.termux/files/usr/bin/bash -c '$sshdScript'"
    $null = & $adb shell $sshdCommand 2>$null
    Start-Sleep -Seconds 1
}

$termuxUser = (& $adb shell "run-as com.termux whoami" 2>$null).Trim()
if (-not $termuxUser) {
    Write-Host "ERROR: Failed to get Termux username. Is ADB connected?" -ForegroundColor Red
    exit 1
}

$keyPath = if ($isWsl) {
    "$env:HOME/.ssh/id_ed25519_termux"
} else {
    "$env:USERPROFILE\.ssh\id_ed25519_termux"
}

try {
    if (Test-Path $keyPath) {
        if ($SshArgs) {
            ssh -o StrictHostKeyChecking=accept-new -p $sshPort -i "$keyPath" "${termuxUser}@${sshHost}" $SshArgs
        } else {
            ssh -o StrictHostKeyChecking=accept-new -p $sshPort -i "$keyPath" "${termuxUser}@${sshHost}"
        }
    } else {
        if ($SshArgs) {
            ssh -o StrictHostKeyChecking=accept-new -p $sshPort "${termuxUser}@${sshHost}" $SshArgs
        } else {
            ssh -o StrictHostKeyChecking=accept-new -p $sshPort "${termuxUser}@${sshHost}"
        }
    }
} finally {
    $null = & $adb forward --remove "tcp:$localPort" 2>$null
}
