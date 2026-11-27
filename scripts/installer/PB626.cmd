@echo off
where powershell.exe >nul 2>nul || (echo Windows PowerShell 5.1 is required. & pause & exit /b 1)
powershell.exe -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 5) { exit 0 } else { exit 1 }"
if errorlevel 1 (echo Windows PowerShell 5.1 or newer is required. & pause & exit /b 1)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PB626.ps1" %*
set "PB626_EXIT=%ERRORLEVEL%"
if not "%PB626_EXIT%"=="0" echo Operation failed. If a write started, keep the reader powered and connected; do not reboot.
pause
exit /b %PB626_EXIT%
