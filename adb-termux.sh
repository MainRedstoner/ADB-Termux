#!/bin/bash
# adb-termux - 通过 ADB 在手机 Termux 中执行命令
# 用法: adb-termux "你的命令"
# 示例: adb-termux "pip list | grep numpy"
# 兼容 Git-Bash (Windows) 和 WSL
#
# 交互模式请用 termux-ssh（SSH 提供完整 PTY，支持 tab补全/nano/job control）

# WSL: 需要特殊处理（adb.exe 路径、wslpath 替代 cygpath）
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
    # WSL 路径转换用 wslpath（不是 cygpath）
    to_win_path() { wslpath -w "$1"; }
else
    # Git-Bash (MSYS): 禁止 MSYS 自动转换 POSIX 路径
    export MSYS_NO_PATHCONV=1
    adb() { command adb "$@"; }
    ADB="adb"
    # MSYS 路径转换用 cygpath
    to_win_path() { cygpath -w "$1"; }
fi

if [ $# -eq 0 ] || [ "$1" = "-i" ] || [ "$1" = "shell" ]; then
    echo "交互模式请用 termux-ssh（支持 tab补全/nano/job control）"
    exit 1
fi

CMD="$1"
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
