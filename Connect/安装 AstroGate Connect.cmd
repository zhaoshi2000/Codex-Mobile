@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install-app.ps1"
set "result=%errorlevel%"
if not "%result%"=="0" (
    echo.
    echo Installation failed. See the message above.
    pause
)
exit /b %result%
