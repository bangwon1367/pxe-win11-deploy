@echo off
rem ============================================================================
rem  startnet.cmd - WinPE entry point (replaces the default one in boot.wim).
rem  Runs when wimboot has loaded boot.wim over the network.
rem ============================================================================
setlocal

rem WinPE initialisation: brings up networking, PnP, and the WMI stack.
echo [startnet] wpeinit...
call wpeinit

rem Give the NIC a DHCP lease before PowerShell tries to reach the share.
echo [startnet] acquiring network...
for /l %%i in (1,1,30) do (
    ping -n 1 -w 1000 127.0.0.1 >nul
    ipconfig | findstr /i "IPv4" >nul && goto :net_ready
)
:net_ready

rem Keep the deployment transcript on the WinPE ramdisk; Deploy.ps1 copies it to the share.
if not exist X:\Deploy\logs mkdir X:\Deploy\logs

echo.
echo  pxe-win11-deploy - Windows 11 26H2 unattended deployment
echo  ----------------------------------------------------------
echo  Deploying in 5 seconds. Press Ctrl+C to drop to a shell instead.
echo.
timeout /t 5 >nul

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Deploy.ps1 %*
rem PowerShell returns non-zero on an unhandled throw; keep the window for forensics.
if errorlevel 1 (
    echo.
    echo  *** deployment FAILED (exit %errorlevel%) ***
    echo  Log: X:\Deploy\logs
    echo  Fix the cause, then reboot to retry.  Dropping to a shell.
    cmd.exe
)

rem If Deploy.ps1 finished cleanly it has already issued the reboot.
echo [startnet] rebooting...
wpeutil reboot
