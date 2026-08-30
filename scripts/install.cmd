@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CAPSULENV_INSTALL_ENTRY=%~dp0Install-Capsulenv.ps1"

rem Source-tree installer entrypoint. Release bundles expose install.cmd at their
rem root instead; keeping the source entry under scripts prevents a checkout from
rem looking like an installed capsule.
set "CAPSULENV_INSTALL_POWERSHELL="
call :SelectWindowsPowerShell "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_INSTALL_POWERSHELL (
    for /f "delims=" %%P in ('where powershell.exe 2^>nul') do call :SelectWindowsPowerShell "%%P"
)
if not defined CAPSULENV_INSTALL_POWERSHELL (
    echo capsulenv source installer requires Windows PowerShell 5.1. 1^>^&2
    exit /b 1
)

"%CAPSULENV_INSTALL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_INSTALL_ENTRY%" %*
exit /b %ERRORLEVEL%

:SelectWindowsPowerShell
if defined CAPSULENV_INSTALL_POWERSHELL exit /b 0
if not exist "%~1" exit /b 0
"%~1" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1) { exit 0 } else { exit 1 }" >nul 2>nul
if not errorlevel 1 set "CAPSULENV_INSTALL_POWERSHELL=%~f1"
exit /b 0
