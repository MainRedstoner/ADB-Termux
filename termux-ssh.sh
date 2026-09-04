#!/bin/bash
# termux-ssh.sh - SSH into Termux with a full PTY via ADB forward.
# Uses a temporary ADB-forwarded local port to avoid conflicts with other services.
# Compatible with Git-Bash (Windows), WSL and native Linux.

export MSYS_NO_PATHCONV=1

REMOTE_PORT=8022
PROXY_CANDIDATES=(18022 18023 18024 18025 18026 18027 18028 18029 28022 28023 28024 28025 28026 28027 38022 38023 38024 38025 38026 38027 48022 48023 48024)

# WSL: use Windows adb.exe and a portproxy relay because WSL2 localhost
# cannot reach adb-forwarded ports.
if grep -qi microsoft /proc/version 2>/dev/null; then
    if command -v adb.exe &>/dev/null; then
        ADB="adb.exe"
    else
        WIN_APPDATA=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n ')
        ADB="$(wslpath "${WIN_APPDATA}\Android\platform-tools\adb.exe")"
        if [ ! -f "$ADB" ]; then
            echo "ERROR: adb.exe not found. Install Android Platform Tools or add it to PATH." >&2
            exit 1
        fi
    fi
    GATEWAY=$(ip route show default 2>/dev/null | grep -oP 'via \K[\d.]+' | head -1)
    if [ -z "$GATEWAY" ]; then
        GATEWAY=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
    fi
    SSH_HOST="$GATEWAY"
    IS_WSL=1
else
    # Native Linux / Git-Bash / Cygwin: use native adb and connect via localhost.
    ADB="adb"
    adb() { command adb "$@"; }
    SSH_HOST="localhost"
    IS_WSL=0
fi

# Check ADB state without opening an adb shell (shell can hang if adbd is unresponsive).
ADB_STATE=$($ADB get-state 2>/dev/null | tr -d '\r\n ')
if [ "$ADB_STATE" != "device" ]; then
    echo "ERROR: ADB is not connected or the device is unauthorized (state: ${ADB_STATE:-none}). Check 'adb devices' and authorize the phone." >&2
    exit 1
fi

# Wrap adb shell with a timeout so an unresponsive device cannot hang the script forever.
adb_shell() {
    timeout 10 "$ADB" shell -T "$@" || {
        rc=$?
        if [ "$rc" -eq 124 ]; then
            echo "ERROR: ADB shell timed out; the device may be unresponsive. Reconnect/authorize the phone." >&2
            exit 1
        fi
        return "$rc"
    }
}

get_remote_forward_ports() {
    $ADB forward --list 2>/dev/null | awk -v rp="tcp:$REMOTE_PORT" '$3==rp {sub(/^tcp:/,"",$2); print $2}'
}

# Ask adb to allocate a temporary local port (tcp:0). This avoids fixed-port
# conflicts with other services on the PC.
BEFORE_PORTS=$(get_remote_forward_ports)
ALLOC_OUTPUT=$($ADB forward tcp:0 tcp:"$REMOTE_PORT" 2>/dev/null | tr -d '\r\n ')

LOCAL_PORT=""
if [ -n "$ALLOC_OUTPUT" ] && [[ "$ALLOC_OUTPUT" =~ ^[0-9]+$ ]]; then
    LOCAL_PORT="$ALLOC_OUTPUT"
else
    AFTER_PORTS=$(get_remote_forward_ports)
    for p in $AFTER_PORTS; do
        if ! printf '%s\n' "$BEFORE_PORTS" | grep -qx "$p"; then
            LOCAL_PORT="$p"
            break
        fi
    done
fi

if [ -z "$LOCAL_PORT" ]; then
    echo "ERROR: Failed to allocate a temporary ADB forward port." >&2
    exit 1
fi

cleanup() {
    $ADB forward --remove "tcp:$LOCAL_PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

setup_portproxy() {
    local p old_line old_port
    # Reuse an existing rule that already points at the local port.
    old_line=$(netsh.exe interface portproxy show v4tov4 2>/dev/null | awk -v lp="$LOCAL_PORT" 'NR>4 && $4==lp {print; exit}')
    if [ -n "$old_line" ]; then
        PROXY_PORT=$(printf '%s\n' "$old_line" | awk '{print $2}')
        return 0
    fi
    # Reuse/update the old rule that points at the remote port.
    old_line=$(netsh.exe interface portproxy show v4tov4 2>/dev/null | awk -v rp="$REMOTE_PORT" 'NR>4 && $4==rp {print; exit}')
    if [ -n "$old_line" ]; then
        old_port=$(printf '%s\n' "$old_line" | awk '{print $2}')
        netsh.exe interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport="$old_port" >/dev/null 2>&1 || true
        if netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport="$old_port" connectaddress=127.0.0.1 connectport="$LOCAL_PORT" >/dev/null 2>&1; then
            PROXY_PORT="$old_port"
            return 0
        fi
    fi
    # Try fresh candidates.
    for p in "${PROXY_CANDIDATES[@]}"; do
        if netsh.exe interface portproxy show v4tov4 2>/dev/null | awk -v lp="$p" 'NR>4 && $2==lp {found=1} END {exit !found}'; then
            continue
        fi
        if netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport="$p" connectaddress=127.0.0.1 connectport="$LOCAL_PORT" >/dev/null 2>&1; then
            PROXY_PORT="$p"
            return 0
        fi
    done
    return 1
}

if [ "$IS_WSL" = "1" ]; then
    if ! setup_portproxy; then
        echo "ERROR: Failed to set up Windows portproxy for WSL." >&2
        exit 1
    fi
    SSH_PORT="$PROXY_PORT"
else
    SSH_PORT="$LOCAL_PORT"
fi

if ! adb_shell run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -f sshd >/dev/null; then
    echo "Starting sshd on the device..." >&2
    SSHD_CMD='export HOME=/data/data/com.termux/files/home; export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH; export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib; export PREFIX=/data/data/com.termux/files/usr; exec /data/data/com.termux/files/usr/bin/sshd -p '"$REMOTE_PORT"
    adb_shell "run-as com.termux /data/data/com.termux/files/usr/bin/bash -c '$SSHD_CMD'" >/dev/null
fi

# Wait until sshd actually answers on the forwarded port. A blind short sleep
# races sshd startup, and phone power management can drop loopback
# connections for a while.
SSH_READY=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SSH_PORT && head -c 4 <&3" 2>/dev/null)" = "SSH-" ]; then
        SSH_READY=1
        break
    fi
    sleep 1
done
if [ "$SSH_READY" != "1" ]; then
    echo "WARNING: sshd not answering on port $SSH_PORT yet; trying anyway..." >&2
fi

TERMUX_USER=$(adb_shell run-as com.termux whoami | tr -d '\r\n')
if [ -z "$TERMUX_USER" ]; then
    echo "ERROR: Failed to get Termux username. Is ADB connected?" >&2
    exit 1
fi

echo "Connecting: ${TERMUX_USER}@${SSH_HOST}:${SSH_PORT} (temporary adb forward tcp:${LOCAL_PORT} -> tcp:${REMOTE_PORT})" >&2
# Preferred key can be overridden with TERMUX_SSH_KEY; fall back to the common
# default key when the dedicated Termux key is not present, letting ssh also use
# an agent or password if no key file exists.
SSH_KEY="${TERMUX_SSH_KEY:-$HOME/.ssh/id_ed25519_termux}"
if [ ! -f "$SSH_KEY" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
    SSH_KEY="$HOME/.ssh/id_ed25519"
fi

SSH_KEY_ARGS=()
if [ -f "$SSH_KEY" ]; then
    SSH_KEY_ARGS=(-i "$SSH_KEY")
fi

ssh -o StrictHostKeyChecking=accept-new "${SSH_KEY_ARGS[@]}" -p "$SSH_PORT" "${TERMUX_USER}@$SSH_HOST" "$@"
