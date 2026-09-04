# ADB Termux 工具集

通过 ADB 在 Android 手机上操作 Termux 环境。提供两套工具、三种 shell（bash / PowerShell / cmd），覆盖一次性和交互式两种使用场景。所有硬编码均已消除，换一台手机/电脑直接可用。

## 目录

```
adb-termux-ssh/
├── adb-termux.sh    # bash 版一次性命令执行（含 WSL / Linux 适配）
├── adb-termux.ps1   # PowerShell 版（含 WSL / Linux 适配）
├── adb-termux.bat   # cmd 版
├── termux-ssh.sh    # bash 版交互式 SSH（含 WSL / Linux 适配）
├── termux-ssh.ps1   # PowerShell 版（含 WSL / Linux 适配）
├── termux-ssh.bat   # cmd 版
├── bin/             # 与根目录相同的可部署副本
│   ├── adb-termux.sh
│   ├── adb-termux.ps1
│   ├── adb-termux.bat
│   ├── termux-ssh.sh
│   ├── termux-ssh.ps1
│   └── termux-ssh.bat
└── README.md
```

---

## 背景：为什么需要这些脚本

### 核心问题：`adb shell run-as` 不带 Termux 环境

ADB 提供了 `adb shell run-as com.termux` 以 Termux 应用身份执行命令，但这条命令运行在 Android 系统环境里——

```bash
$ adb shell run-as com.termux bash
$ echo $PATH
/sbin:/system/bin:/system/xbin          # ← 没有 Termux 的 /data/data/.../usr/bin
$ which python
python: not found                        # ← pip、python、java 全找不到
$ echo $HOME
/                                        # ← 不是 Termux 的 home
```

因为 Android 的 `run-as` 只切换 Linux 用户，不执行 shell 初始化。Termux 的所有可执行文件、库文件、home 目录都需要显式设置环境变量才能访问。

### 解决思路

在每个要执行的命令前注入 Termux 环境变量：

```bash
export HOME=/data/data/com.termux/files/home
export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
export PREFIX=/data/data/com.termux/files/usr
cd $HOME
```

本项目的两套工具都是围绕这条思路构建的，只是传递方式不同。

---

## `adb-termux` — 一次性命令执行

**适用场景：** 脚本自动化、批量操作、只跑一条命令拿结果就走。

### 工作原理

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ 1. 生成临时    │     │ 2. adb push  │     │ 3. run-as    │
│    shell 脚本 │ ──→ │    到手机     │ ──→ │    bash 执行  │
│   (含环境变量) │     │ /data/local/ │     │              │
└──────────────┘     └──────────────┘     └──────────────┘
       │                                       │
       └──────────── 4. 清理临时文件 ←───────────┘
```

**为什么走 `/data/local/tmp/`：** 这是 Android 上少数几个所有用户可读写的目录。`adb push` 以 `shell` 用户写入，`run-as com.termux` 以 Termux 用户读取。

### 生成的脚本模板

```bash
#!/data/data/com.termux/files/usr/bin/bash
export HOME=/data/data/com.termux/files/home
export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
export PREFIX=/data/data/com.termux/files/usr
export TERM=xterm-256color
export CLICOLOR_FORCE=1
export FORCE_COLOR=1
cd $HOME

# ← 用户命令拼在这里
pip list
```

### 颜色支持

`adb shell run-as` 不分配伪终端（PTY），大部分命令行工具检测到非终端输出就会关闭颜色。通过三个环境变量强制开启：

| 变量                    | 影响范围                                             |
| --------------------- | ------------------------------------------------ |
| `TERM=xterm-256color` | 让程序相信自己连接到了终端                                    |
| `CLICOLOR_FORCE=1`    | 强制 `ls --color=auto`、`grep`、`fd`、`bat` 等出颜色      |
| `FORCE_COLOR=1`       | 覆盖 Node.js / Python 工具（pytest、eslint）的 isatty 检查 |

### 用法

```bash
# bash (Git-Bash / WSL / 原生 Linux)
./adb-termux.sh "pip list"
./adb-termux.sh "python -c 'print(1+1)'"

# PowerShell（参数用不用引号都可以）
.\adb-termux.ps1 "pip list"
.\adb-termux.ps1 python -c 'print(1+1)'

# cmd（命令用引号）
adb-termux.bat "pip list"
```

### 平台差异

|       | bash                                   | PowerShell                      | cmd                 |
| ----- | -------------------------------------- | ------------------------------- | ------------------- |
| 平台    | Git-Bash / WSL / 原生 Linux 自适应         | Windows (PS5/PS7) / WSL / 原生 Linux 自适应 | Windows (cmd)       |
| 路径转换  | MSYS: `cygpath -w` / WSL: `wslpath -w` / Linux: 直接 | Windows: 直接 / WSL: `wslpath -w` / Linux: 直接 | 直接使用                |
| 换行符   | `\n`（天然 Unix）                          | `\n`（Set-Content）               | 需 `powershell` 转 LF |
| 清理可靠性 | `trap ... EXIT`*                       | `try/finally`*                  | 顺序执行†               |

> \* Ctrl+C 也能保证清理<br>
> † Ctrl+C 中断会留残留文件

> **cmd 版 CRLF→LF 的必要性：** cmd 的 `echo` 写入 `\r\n` 换行符，推到手机后 bash 会把 `\r` 当命令名解析，产生 `$'\r': command not found`。所以 push 前用 PowerShell 做一次 `\r\n → \n` 转换。

---

## `termux-ssh` — 交互式 SSH 终端

**适用场景：** 需要 tab 补全、方向键、nano/vim、job control 的交互式操作。

### 为什么不用 `adb shell` 直接交互

ADB shell 不分配 PTY（伪终端），后果：

- Tab 补全输出字面量 `^I`
- nano/vim 花屏
- Ctrl+C 不工作或行为异常
- `less`/`htop` 等 TUI 程序无法运行

### 工作原理：ADB 端口转发 + SSH

```
┌─────────────────────────────────────────────────┐
│                     Windows PC                  │
│                                                 │
│   ssh -p <临时端口> <动态用户名>@localhost │
│        │                                        │
│        │ adb forward tcp:<临时端口> tcp:8022  │
│        ▼                                        │
│   ┌─────────┐    USB/WiFi    ┌────────────────┐ │
│   │localhost│ ←────────────→ │ Android 设备    │ │
│   │:<自动端口>│                │  sshd -p 8022  │ │
│   └─────────┘                │  (Termux 内)   │ │
│                              └────────────────┘ │
└─────────────────────────────────────────────────┘
```

脚本自动完成三步：确保 ADB 转发 → 确保手机 sshd 运行 → SSH 连接。

SSH 用户名通过 `run-as com.termux whoami` 动态获取，不同手机自动适配（不硬编码 `u0_a185`）。

### WSL 适配（bash 版和 ps1 版均支持）

WSL2 有两个坑：

1. **端口转发不可达：** Windows 上 `adb forward` 的端口只绑定在 Windows 侧的 `127.0.0.1`，WSL2 虚拟机无法通过 `localhost` 访问。
2. **adb.exe 不自动匹配：** WSL 的 PATH 中有 Windows 程序，但需要显式写 `.exe` 后缀。

bash 版自动处理：

```
WSL2 虚拟机                Windows 宿主
    │                         │
    │  ssh 到宿主 IP:<代理端口>  │
    │ ──────────────────────→ │ netsh portproxy
    │                         │ 0.0.0.0:<代理端口>
    │                         │   → 127.0.0.1:<临时本地端口>
    │                         │       → adb forward
    │                         │           → 手机 sshd
```

**adb.exe 自动定位：**

```
1. command -v adb.exe → 在 PATH 中找到了？直接用
2. 没找到 → cmd.exe 取 %LOCALAPPDATA%
          → wslpath 转成 WSL 路径
          → 拼接 /Android/platform-tools/adb.exe
3. 都不行 → 报错退出
```

不依赖 Windows 用户名、WSL 用户名、系统盘符——`%LOCALAPPDATA%` 永远是正确答案。

### 原生 Linux 适配（bash / pwsh 版）

原生 Linux 上直接使用本机 `adb`，不需要 `adb.exe`、`cygpath` / `wslpath` 或 Windows portproxy；SSH 通过 `adb forward` 分配的本机端口连接 `localhost`。bash 和 pwsh 版都会自动检测 Linux，在 Linux 上直接使用 POSIX 路径推送临时脚本，并自动调整 SSH 密钥路径；pwsh 的 `adb shell` 调用也会带超时保护，避免设备无响应时一直卡住。

### SSH 认证

bash 版优先使用 `$TERMUX_SSH_KEY`，pwsh 版使用 `$env:TERMUX_SSH_KEY`；默认密钥是 `~/.ssh/id_ed25519_termux`。若该专用密钥不存在，会回退到 `~/.ssh/id_ed25519`，并继续支持 ssh-agent 或密码认证。

首次配置密钥登录：

```bash
# 1. 生成专用密钥（可选，也可用已有密钥）
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_termux

# 2. 把公钥推到手机
adb push ~/.ssh/id_ed25519_termux.pub /sdcard/Download/

# 3. 安装到 Termux
adb-termux.sh "mkdir -p ~/.ssh && cat /sdcard/Download/id_ed25519_termux.pub >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

### 首次配置 SSH 环境

Termux 默认的 sshd 登录后找不到 `python` 等包，原因：

1. `~/.profile` 和 `~/.bashrc` 是空的
2. sshd 默认用 `/system/bin/sh` 而不是 Termux bash

一次性修复：

```bash
# 写入 shell profile
adb-termux.sh "cat > ~/.profile << 'EOF'
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=\$PREFIX/bin:\$PREFIX/bin/applets:\$PATH
export LD_LIBRARY_PATH=\$PREFIX/lib
export TERM=xterm-256color
export LANG=en_US.UTF-8
if [ -n \"\$BASH\" ] && [ -f ~/.bashrc ]; then . ~/.bashrc; fi
EOF
cp ~/.profile ~/.bashrc"

# 设置登录 shell（用 whoami 动态获取用户名）
adb-termux.sh "echo \"\$(whoami):x:\$(id -u):\$(id -g):Termux:\$HOME:/data/data/com.termux/files/usr/bin/bash\" >> /data/data/com.termux/files/usr/etc/passwd"

# 重启 sshd
adb-termux.sh "pkill sshd; sshd -p 8022"
```

### 用法

```bash
# 交互模式
./termux-ssh.sh

# 带命令（执行后退出）
./termux-ssh.sh python --version
./termux-ssh.sh "pip list | grep numpy"
```

所有额外参数透明传递给 `ssh`。

### 故障排查

如果 `termux-ssh` 无法启动，先确认 ADB 状态：

```bash
adb kill-server
adb start-server
adb devices
```

要求看到：

```text
<设备序列号>       device
```

如果是：

```text
unauthorized
offline
```

说明手机端 USB 调试授权或 ADB 传输有问题，先在手机上重新授权/重新插拔，不要直接改脚本。

脚本现在的行为：

- 启动前用 `adb get-state` 快速检查，设备未连接、未授权、offline 时立即报错；
- bash 版对后续 `adb shell` 操作加了 10 秒超时，设备 shell 无响应时不会无限卡住；
- SSH 退出后自动删除本次 ADB 临时转发。

---

## 开发踩坑记录

### 1. MSYS 路径自动转换（bash 版）

Git-Bash 的 MSYS 层会自动把 POSIX 路径转成 Windows 路径，例如 `/data/local/tmp` → `C:/Program Files/Git/data/local/tmp`，导致 `adb push` 失败。

**修复：** `export MSYS_NO_PATHCONV=1` + `adb() { command adb "$@"; }` 绕过 MSYS 对 adb 的别名包装。

### 2. `adb push` 需要 Windows 路径（bash 版）

`adb.exe` 是 Windows 程序，无法识别 POSIX 路径（如 `/c/Users/...` 或 `/home/...`）。

**修复：** MSYS 下用 `cygpath -w`，WSL 下用 `wslpath -w`，统一转成 `C:\Users\...` 格式。

### 3. 中文编码问题（ps1 / bat）

PowerShell 5 和 cmd 默认按系统 ANSI 编码（中文 Windows 是 GBK）读取脚本文件。UTF-8 无 BOM 的中文注释和字符串会变成乱码，其中某些字节恰好是 `"`（0x22），导致字符串提前终止、语法错误甚至死循环。

**修复：** 三个脚本统一使用纯英文注释和消息，避免编码问题。

### 4. PS5 下数组 splatting 传参异常（ps1）

`& ssh @sshArgs` 这种 PowerShell 数组展开语法在 PS5 中对 native 命令行为不可靠，可能打乱参数顺序，导致 `u0_a185@localhost` 被当成远程命令执行。

**修复：** 直接用 `ssh -o ... -p <自动端口>` 调用，不使用 `&` + 数组 splatting。

### 5. cmd `echo` 的 CRLF 换行符（bat）

cmd 的 `echo` 输出 `\r\n`，生成脚本推到 Linux 后 bash 把 `\r` 当命令解析。

**修复：** 写入后调用 PowerShell 做 `\r\n → \n` 转换。

### 6. SSH 用户名硬编码

最初所有版本的 SSH 连接都写死了 `u0_a185@localhost`，换一台手机（Termux 的 Linux UID 不同）就无法登录。

**修复：** 连接前通过 `run-as com.termux whoami` 动态获取当前设备的 Termux 用户名。

### 7. WSL adb.exe 路径硬编码

bash 版最初写死了 `/mnt/c/Users/MainRedstoner/...`，换一台电脑或 WSL 用户名与 Windows 不一致就找不到。

**修复：** 优先检查 `adb.exe` 是否在 PATH 中；不在则用 `cmd.exe /c 'echo %LOCALAPPDATA%'` 获取路径，`wslpath` 转成 WSL 格式。不依赖用户名、系统盘符。

### 8. 本地 SSH 转发端口固定导致冲突

最初所有版本都使用 `adb forward tcp:8022 tcp:8022`，如果 Windows 上已有程序占用 8022（例如本地 HTTP 服务），ADB 转发会绑定失败，SSH 会连到错误服务。

**修复：** 三个 `termux-ssh` 脚本现在使用 `adb forward tcp:0 tcp:8022` 让 ADB 自动分配一个临时本地端口，SSH 结束后会删除该临时转发。WSL 的 portproxy 也会自动复用/更新到对应的临时本地转发端口，避免再次撞上 8022。

### 9. ADB 设备“假在线”导致脚本卡死

有时 `adb devices` 显示 `device`，但实际 `adb shell` 已经无响应，脚本会一直卡住。

**修复：** 脚本先通过 `adb get-state` 快速判断设备状态；bash 版后续所有 `adb shell run-as ...` 操作都有 10 秒超时，超时后直接报错退出，避免永久挂起。

### 10. 原生 Linux 路径转换

原生 Linux 的 `adb` 本身接受 POSIX 路径，不需要 `cygpath` / `wslpath`。bash 和 pwsh 脚本现在都会检测 Linux，在 Linux 上直接使用原生路径，避免误走 WSL/Windows 路径转换分支。

---



## 快速对照

| 需求                     | 工具                | 命令示例                                                              |
| ---------------------- | ----------------- | ----------------------------------------------------------------- |
| 拿一条结果                  | `adb-termux.sh`   | `./adb-termux.sh "pip list"`                                      |
| 进去敲命令                  | `termux-ssh.sh`   | `./termux-ssh.sh`                                                 |
| 远程执行后退                 | `termux-ssh.sh`   | `./termux-ssh.sh python -c '1+1'`                                 |
| 脚本自动化                  | `adb-termux.sh`   | `./adb-termux.sh "pgrep -f minecraft"`                            |
|                        |                   |                                                                   |
| `WSL` & `Git Bash` 下使用 | `.sh` / `.ps1` 后缀 | `./adb-termux.sh "pip list"` & `pwsh ./adb-termux.ps1 "pip list"` |
| `PowerShell` 下使用       | `.ps1` 后缀         | `.\adb-termux.ps1 pip list`                                       |
| `CMD` 下使用              | `.bat` 后缀         | `adb-termux.bat "pip list"`                                       |

---

> 代码由 DeepSeek 生成。


