@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PB626.ps1" -PauseOnExit %*
exit /b %ERRORLEVEL%
