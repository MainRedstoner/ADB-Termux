@echo off
setlocal
:: termux-ssh.bat - SSH into Termux (cmd version)
:: Uses a temporary local port, starts sshd, then connects.

set "REMOTE_PORT=8022"
set "LOCAL_PORT="

:: Check ADB state without opening an adb shell (shell can hang if adbd is unresponsive).
set "ADB_STATE="
for /f "delims=" %%S in ('adb get-state 2^>nul') do set "ADB_STATE=%%S"
if not "%ADB_STATE%"=="device" (
    echo ERROR: ADB is not connected or device is unauthorized. State: %ADB_STATE%
    exit /b 1
)

:: Ask ADB to allocate a temporary local port (tcp:0)
for /f "delims=" %%P in ('adb forward tcp:0 tcp:%REMOTE_PORT% 2^>nul') do (
    set "LOCAL_PORT=%%P"
)

:: Fallback: if adb did not print the allocated port, find it from forward --list
if not defined LOCAL_PORT (
    for /f "tokens=2" %%B in ('adb forward --list 2^>nul ^| findstr /r /c:" tcp:%REMOTE_PORT%$"') do (
        if not defined LOCAL_PORT set "LOCAL_PORT=%%B"
    )
)

if not defined LOCAL_PORT (
    echo ERROR: Failed to allocate a temporary ADB forward port.
    exit /b 1
)

:: Strip tcp: prefix if the fallback captured "tcp:12345"
set "LOCAL_PORT=%LOCAL_PORT:tcp:=%"

:: Ensure sshd is running
adb shell run-as com.termux /data/data/com.termux/files/usr/bin/pgrep -f sshd >nul 2>&1
if errorlevel 1 (
    echo Starting sshd...
    set "SSHD_SCRIPT=export HOME=/data/data/com.termux/files/home; export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:$PATH; export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib; export PREFIX=/data/data/com.termux/files/usr; exec /data/data/com.termux/files/usr/bin/sshd -p %REMOTE_PORT%"
    adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/bash -c '%SSHD_SCRIPT%'" >nul 2>&1
    ping -n 2 127.0.0.1 >nul
)

:: Dynamically resolve Termux username
for /f "delims=" %%i in ('adb shell "run-as com.termux whoami" 2^>nul') do set "TERMUX_USER=%%i"
if "%TERMUX_USER%"=="" (
    echo ERROR: Failed to get Termux username. Is ADB connected?
    exit /b 1
)

set "KEY=%USERPROFILE%\.ssh\id_ed25519_termux"

if exist "%KEY%" (
    if "%~1"=="" (
        ssh -o StrictHostKeyChecking=accept-new -p %LOCAL_PORT% -i "%KEY%" %TERMUX_USER%@localhost
    ) else (
        ssh -o StrictHostKeyChecking=accept-new -p %LOCAL_PORT% -i "%KEY%" %TERMUX_USER%@localhost %*
    )
) else (
    if "%~1"=="" (
        ssh -o StrictHostKeyChecking=accept-new -p %LOCAL_PORT% %TERMUX_USER%@localhost
    ) else (
        ssh -o StrictHostKeyChecking=accept-new -p %LOCAL_PORT% %TERMUX_USER%@localhost %*
    )
)

:: Remove the temporary forward after SSH exits
set "SSH_RC=%ERRORLEVEL%"
adb forward --remove tcp:%LOCAL_PORT% >nul 2>&1
exit /b %SSH_RC%
