@echo off
:: termux-ssh.bat - SSH into Termux (cmd version)
:: Auto-sets up ADB forward, starts sshd, then connects.

:: Ensure ADB port forward
adb forward --list 2>nul | findstr /r "tcp:8022.*tcp:8022" >nul
if errorlevel 1 (
    adb forward tcp:8022 tcp:8022 >nul
)

:: Ensure sshd is running
adb shell run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -x sshd >nul 2>&1
if errorlevel 1 (
    echo Starting sshd...
    adb shell run-as com.termux /data/data/com.termux/files/usr/bin/sshd -p 8022 >nul
    timeout /t 1 /nobreak >nul
)

:: Dynamically resolve Termux username (varies across devices)
for /f "delims=" %%i in ('adb shell "run-as com.termux whoami" 2^>nul') do set "TERMUX_USER=%%i"
if "%TERMUX_USER%"=="" (
    echo ERROR: Failed to get Termux username. Is ADB connected?
    exit /b 1
)

set "KEY=%USERPROFILE%\.ssh\id_ed25519_termux"
set "SSH_OPTS=-o StrictHostKeyChecking=accept-new -p 8022"
if exist "%KEY%" set "SSH_OPTS=%SSH_OPTS% -i "%KEY%""

if "%~1"=="" (
    ssh %SSH_OPTS% %TERMUX_USER%@localhost
) else (
    ssh %SSH_OPTS% %TERMUX_USER%@localhost %*
)
