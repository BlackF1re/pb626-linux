@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PB626.ps1" %*
set "PB626_EXIT=%ERRORLEVEL%"
if not "%PB626_EXIT%"=="0" echo Operation stopped. If a write started, keep the reader powered and connected. Do not reboot.
pause
exit /b %PB626_EXIT%
