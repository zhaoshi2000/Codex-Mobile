@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install-app.ps1"
set "result=%errorlevel%"
if "%result%"=="2" (
    echo.
    echo AstroGate Connect is installed, but the first launch is not ready.
    echo Sign in to Codex, then use the AstroGate Connect desktop shortcut to retry.
    pause
)
if not "%result%"=="0" if not "%result%"=="2" (
    echo.
    echo Installation failed. See the message above.
    pause
)
exit /b %result%
