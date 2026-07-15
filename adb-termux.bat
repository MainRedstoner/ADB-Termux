@echo off
setlocal
:: adb-termux.bat - Execute a command in Termux via ADB (cmd version)
:: Usage: adb-termux.bat "command"
:: Example: adb-termux.bat "pip list"

if "%~1"=="" (
    echo Usage: adb-termux.bat "command" [args...]
    echo Example: adb-termux.bat "pip list"
    echo For interactive shell, use termux-ssh.bat
    exit /b 1
)

set "CMD=%~1"
set "TMP_NAME=_adb_termux_%RANDOM%.sh"
set "LOCAL_TMP=%USERPROFILE%\%TMP_NAME%"
set "REMOTE_TMP=/data/local/tmp/%TMP_NAME%"

:: Write remote script
> "%LOCAL_TMP%" (
    echo #!/data/data/com.termux/files/usr/bin/bash
    echo export HOME=/data/data/com.termux/files/home
    echo export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH
    echo export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
    echo export PREFIX=/data/data/com.termux/files/usr
    echo export TERM=xterm-256color
    echo export CLICOLOR_FORCE=1
    echo export FORCE_COLOR=1
    echo cd $HOME
    echo.
    echo %CMD%
)

:: Convert CRLF to LF (cmd echo writes Windows line endings, bash needs Unix)
powershell -NoProfile -Command "(Get-Content '%LOCAL_TMP%' -Raw) -replace \"`r`n\", \"`n\" | Set-Content '%LOCAL_TMP%' -NoNewline"

adb push "%LOCAL_TMP%" "%REMOTE_TMP%"
if errorlevel 1 (
    echo ERROR: adb push failed
    del "%LOCAL_TMP%" 2>nul
    exit /b 1
)

adb shell run-as com.termux /data/data/com.termux/files/usr/bin/bash "%REMOTE_TMP%"

:: Cleanup
del "%LOCAL_TMP%" 2>nul
adb shell rm -f "%REMOTE_TMP%" 2>nul
