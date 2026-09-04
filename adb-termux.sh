#!/bin/bash
# adb-termux - 通过 ADB 在手机 Termux 中执行命令
# 用法: adb-termux "你的命令"
# 示例: adb-termux "pip list | grep numpy"
# 兼容 Git-Bash (Windows)、WSL 和原生 Linux
#
# 交互模式请用 termux-ssh（SSH 提供完整 PTY，支持 tab补全/nano/job control）

# Platform detection: WSL / native Linux / Git-Bash (MSYS)
# WSL needs adb.exe and wslpath; native Linux uses POSIX paths directly.
if grep -qi microsoft /proc/version 2>/dev/null; then
    # Locate Windows adb.exe
    if command -v adb.exe &>/dev/null; then
        ADB="adb.exe"
    else
        WIN_APPDATA=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n ')
        ADB="$(wslpath "${WIN_APPDATA}\\Android\\platform-tools\\adb.exe")"
        if [ ! -f "$ADB" ]; then
            echo "ERROR: adb.exe not found. Install Android Platform Tools or add it to PATH." >&2
            exit 1
        fi
    fi
    # WSL path conversion via wslpath
    to_win_path() { wslpath -w "$1"; }
elif [ "$(uname -s)" = "Linux" ]; then
    # Native Linux: adb accepts POSIX paths directly; no cygpath/wslpath needed.
    if ! command -v adb >/dev/null 2>&1; then
        echo "ERROR: adb not found. Install Android Platform Tools or add it to PATH." >&2
        exit 1
    fi
    adb() { command adb "$@"; }
    ADB="adb"
    to_win_path() { printf '%s\n' "$1"; }
else
    # Git-Bash / MSYS / Cygwin: disable MSYS path conversion and use cygpath.
    export MSYS_NO_PATHCONV=1
    adb() { command adb "$@"; }
    ADB="adb"
    to_win_path() { cygpath -w "$1"; }
fi

if [ $# -eq 0 ] || [ "$1" = "-i" ] || [ "$1" = "shell" ]; then
    echo "交互模式请用 termux-ssh（支持 tab补全/nano/job control）"
    exit 1
fi

CMD="$*"
TMP_NAME="_adb_termux_$$.sh"
LOCAL_TMP="$HOME/$TMP_NAME"

# POSIX → Windows 路径转换（adb push 是 Windows 程序，不认 POSIX 路径）
LOCAL_TMP_WIN=$(to_win_path "$LOCAL_TMP")

REMOTE_TMP="/data/local/tmp/$TMP_NAME"

cleanup() {
    rm -f "$LOCAL_TMP"
    $ADB shell rm -f "$REMOTE_TMP" 2>/dev/null
}
trap cleanup EXIT

# 检查 adb
if ! $ADB shell echo ok > /dev/null 2>&1; then
    echo "错误: ADB 未连接或设备未授权"
    exit 1
fi

# 生成脚本（自动加 Termux 环境变量）
cat > "$LOCAL_TMP" << 'BOILERPLATE'
#!/data/data/com.termux/files/usr/bin/bash
export HOME=/data/data/com.termux/files/home
export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
export PREFIX=/data/data/com.termux/files/usr
export TERM=xterm-256color
export CLICOLOR_FORCE=1
export FORCE_COLOR=1
cd $HOME

BOILERPLATE
echo "$CMD" >> "$LOCAL_TMP"

# 推送
PUSH_ERR=$($ADB push "$LOCAL_TMP_WIN" "$REMOTE_TMP" 2>&1 1>/dev/null)
if [ $? -ne 0 ]; then
    echo "错误: 推送失败"
    echo "  本地: $LOCAL_TMP_WIN"
    echo "  adb: $PUSH_ERR"
    exit 1
fi

# 执行
$ADB shell run-as com.termux /data/data/com.termux/files/usr/bin/bash "$REMOTE_TMP"
