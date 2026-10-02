@echo off
rem ============================================================================
rem  SetupComplete.cmd - first-boot hook, runs ONCE as SYSTEM at the end of setup,
rem  after OOBE, before the logon screen. This is the reliable hook: unlike OOBE it
rem  cannot be blocked by Microsoft tightening the online-account requirements.
rem
rem  Post-Install.ps1 also runs a second time from FirstLogonCommands (as the admin
rem  user) because winget refuses to do useful work in a SYSTEM context on some
rem  builds. Every phase is marker-guarded, so the second run only does the
rem  leftovers.
rem ============================================================================
setlocal

if not exist C:\Deploy mkdir C:\Deploy

echo [SetupComplete] pxe-win11-deploy post-install phase >> C:\Deploy\setupcomplete.log
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -Command "Start-Transcript -Path C:\Deploy\setupcomplete.log -Append | Out-Null; & 'C:\Deploy\Post-Install.ps1'; Stop-Transcript | Out-Null"

rem Remove our own hook so a re-run of setup cannot execute it twice.
del /f /q "%~f0" 2>nul
endlocal
