@echo off
setlocal
if not exist "%~dp0install-app.ps1" goto :extract_all
if not exist "%~dp0Runtime\node.exe" goto :extract_all
if not exist "%~dp0src\bridge.mjs" goto :extract_all
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

:extract_all
echo.
echo AstroGate Connect needs the complete extracted ZIP folder.
echo In File Explorer, right-click the ZIP and choose "Extract All".
echo Then open the extracted "AstroGate Connect" folder and run this installer again.
echo Do not run the installer from inside the ZIP preview.
pause
exit /b 1
