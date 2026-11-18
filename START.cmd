@echo off
setlocal DisableDelayedExpansion
set "QN90B_GUI_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "QN90B_GUI_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%QN90B_GUI_PS%" goto MissingPowerShell
if not exist "%~dp0app\Launcher.ps1" goto MissingLauncher
"%QN90B_GUI_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\Launcher.ps1"
exit /b %ERRORLEVEL%
:MissingPowerShell
echo Windows PowerShell was not found. Use a Windows 10/11 x64 PC.
pause
exit /b 1
:MissingLauncher
echo app\Launcher.ps1 was not found. Extract the entire ZIP before starting.
pause
exit /b 1
