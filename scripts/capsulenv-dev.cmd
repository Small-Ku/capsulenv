@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0..") do set "CAPSULENV_SOURCE_ROOT=%%~fI"
set "CAPSULENV_DEV_ENTRY=%CAPSULENV_SOURCE_ROOT%\module-runtime\Invoke-Capsulenv.ps1"

rem Explicit source-tree CLI. It is intentionally named capsulenv-dev and lives
rem under scripts so a Git checkout cannot be mistaken for a working capsule.
if not exist "%CAPSULENV_DEV_ENTRY%" (
    echo capsulenv development entrypoint is missing: %CAPSULENV_DEV_ENTRY% 1^>^&2
    exit /b 1
)

set "CAPSULENV_CONTROL_POWERSHELL="
call :SelectWindowsPowerShell "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_CONTROL_POWERSHELL (
    for /f "delims=" %%P in ('where powershell.exe 2^>nul') do call :SelectWindowsPowerShell "%%P"
)
if not defined CAPSULENV_CONTROL_POWERSHELL (
    echo capsulenv development CLI requires Windows PowerShell 5.1. 1^>^&2
    exit /b 1
)

"%CAPSULENV_CONTROL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_DEV_ENTRY%" %*
exit /b %ERRORLEVEL%

:SelectWindowsPowerShell
if defined CAPSULENV_CONTROL_POWERSHELL exit /b 0
if not exist "%~1" exit /b 0
"%~1" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1) { exit 0 } else { exit 1 }" >nul 2>nul
if not errorlevel 1 set "CAPSULENV_CONTROL_POWERSHELL=%~f1"
exit /b 0
