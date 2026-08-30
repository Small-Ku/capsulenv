@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "CAPSULENV_SOURCE_ROOT=%%~fI"

rem This launcher is copied to the root of a release bundle. Source checkouts
rem intentionally use scripts\install.cmd so the two directory roles are clear.
set "CAPSULENV_INSTALL_ENTRY=%CAPSULENV_SOURCE_ROOT%\scripts\Install-Capsulenv.ps1"
if not exist "%CAPSULENV_INSTALL_ENTRY%" (
    echo capsulenv installer script is missing: %CAPSULENV_INSTALL_ENTRY% 1^>^&2
    exit /b 1
)

rem Installer/control-plane work must never be hosted by capsule pwsh: it may
rem rebuild pwsh current links/shims while running. Prefer canonical Windows
rem PowerShell 5.1, then validate PATH powershell.exe candidates only.
set "CAPSULENV_INSTALL_POWERSHELL="
call :SelectWindowsPowerShell "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_INSTALL_POWERSHELL (
    for /f "delims=" %%P in ('where powershell.exe 2^>nul') do call :SelectWindowsPowerShell "%%P"
)
if not defined CAPSULENV_INSTALL_POWERSHELL (
    echo capsulenv installer requires Windows PowerShell 5.1. 1^>^&2
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
