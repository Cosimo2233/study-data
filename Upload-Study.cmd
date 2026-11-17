@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upload-Study.ps1"
set "upload_result=%errorlevel%"
echo.
pause
exit /b %upload_result%
