@echo off
setlocal EnableExtensions
for %%I in ("%~dp0.") do set "CAPSULENV_ROOT=%%~fI"

set "CAPSULENV_POWERSHELL="
where pwsh.exe >nul 2>nul && set "CAPSULENV_POWERSHELL=pwsh.exe"
if not defined CAPSULENV_POWERSHELL where powershell.exe >nul 2>nul && set "CAPSULENV_POWERSHELL=powershell.exe"

if not defined CAPSULENV_POWERSHELL (
    echo capsulenv requires Windows PowerShell 5.1 or PowerShell 7.
    exit /b 1
)

"%CAPSULENV_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_ROOT%\scripts\Invoke-Capsulenv.ps1" %*
exit /b %ERRORLEVEL%
