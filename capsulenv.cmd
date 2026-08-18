@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "CAPSULENV_ROOT=%%~fI"

rem capsulenv.cmd is the control plane. Keep it on Windows PowerShell 5.1 so
rem relocation/reset can freely rebuild the capsule's own pwsh app and shims.
rem Interactive/project shells are selected separately by the PowerShell module.
set "CAPSULENV_CONTROL_POWERSHELL="
call :SelectWindowsPowerShell "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_CONTROL_POWERSHELL (
    for /f "delims=" %%P in ('where powershell.exe 2^>nul') do call :SelectWindowsPowerShell "%%P"
)
if not defined CAPSULENV_CONTROL_POWERSHELL (
    echo capsulenv requires Windows PowerShell 5.1 for its control plane.
    exit /b 1
)

set "CAPSULENV_ENTRY=%CAPSULENV_ROOT%\modules\Capsulenv\runtime\Invoke-Capsulenv.ps1"
if not exist "%CAPSULENV_ENTRY%" set "CAPSULENV_ENTRY=%CAPSULENV_ROOT%\module-runtime\Invoke-Capsulenv.ps1"
if not exist "%CAPSULENV_ENTRY%" (
    echo capsulenv runtime entrypoint is missing: %CAPSULENV_ENTRY%
    exit /b 1
)

"%CAPSULENV_CONTROL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_ENTRY%" %*
exit /b %ERRORLEVEL%

:SelectWindowsPowerShell
if defined CAPSULENV_CONTROL_POWERSHELL exit /b 0
if not exist "%~1" exit /b 0
"%~1" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1) { exit 0 } else { exit 1 }" >nul 2>nul
if not errorlevel 1 set "CAPSULENV_CONTROL_POWERSHELL=%~f1"
exit /b 0
