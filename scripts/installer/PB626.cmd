@echo off
where pwsh.exe >nul 2>nul || (echo Install PowerShell 7.4 or newer first. & pause & exit /b 1)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PB626.ps1"
if errorlevel 1 echo Operation failed. Do not disconnect during a partial write.
pause
