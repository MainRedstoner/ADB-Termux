#!/bin/bash
# termux-ssh - 一键 SSH 进入 Termux 完整终端（tab补全、nano 都能用）
# 兼容 Git-Bash (Windows) 和 WSL

export MSYS_NO_PATHCONV=1

# WSL: 需要特殊处理（WSL2 的 localhost 转发对 adb forward 端口不可用）
if grep -qi microsoft /proc/version 2>/dev/null; then
    # 自动定位 Windows 版 adb.exe
    if command -v adb.exe &>/dev/null; then
        ADB="adb.exe"
    else
        # 用 %LOCALAPPDATA% 获取路径（不依赖用户名/系统盘）
        WIN_APPDATA=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n ')
        ADB="$(wslpath "${WIN_APPDATA}\\Android\\platform-tools\\adb.exe")"
        if [ ! -f "$ADB" ]; then
            echo "错误: 找不到 adb.exe，请安装 Android Platform Tools 或将其加入 PATH"
            exit 1
        fi
    fi

    # WSL2 无法直连 Windows 127.0.0.1:8022（adb forward 端口），
    # 需要通过 Windows portproxy 中转到宿主 IP。
    GATEWAY=$(ip route show default 2>/dev/null | grep -oP 'via \K[\d.]+' | head -1)
    if [ -z "$GATEWAY" ]; then
        # fallback: 用 /etc/resolv.conf 里的 nameserver（通常就是 Windows 宿主）
        GATEWAY=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
    fi
    SSH_HOST="$GATEWAY"
    SSH_PORT=18022

    # 确保 portproxy 规则存在（idempotent）
    if ! netsh.exe interface portproxy show v4tov4 2>/dev/null | grep -q "18022.*8022"; then
        netsh.exe interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=18022 connectaddress=127.0.0.1 connectport=8022
    fi
else
    ADB="adb"
    SSH_HOST="localhost"
    SSH_PORT=8022
fi

# 确保 ADB 转发
if ! $ADB forward --list 2>/dev/null | grep -q "tcp:8022.*tcp:8022"; then
    $ADB forward tcp:8022 tcp:8022
fi

# 确保 sshd 在跑
if ! $ADB shell run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -x sshd > /dev/null 2>&1; then
    echo "启动 sshd..."
    $ADB shell run-as com.termux /data/data/com.termux/files/usr/bin/sshd -p 8022
    sleep 1
fi

# 动态获取 Termux 的用户名（不同手机 u0_aXXX 编号可能不同）
TERMUX_USER=$($ADB shell run-as com.termux whoami 2>/dev/null | tr -d '\r\n')
if [ -z "$TERMUX_USER" ]; then
    echo "错误: 无法获取 Termux 用户名，ADB 是否已连接？"
    exit 1
fi

exec ssh -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/id_ed25519_termux" -p "$SSH_PORT" "${TERMUX_USER}@$SSH_HOST" "$@"
