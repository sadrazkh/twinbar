@echo off
rem Twinbar: runs twinbar.ps1 with Windows PowerShell, whatever the execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0twinbar.ps1" %*
exit /b %ERRORLEVEL%
