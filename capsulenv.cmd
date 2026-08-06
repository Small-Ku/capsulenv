@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "CAPSULENV_ROOT=%%~fI"

if not defined CAPSULENV_BOOTSTRAP_SCOOP_ROOT set "CAPSULENV_BOOTSTRAP_SCOOP_ROOT=%CAPSULENV_ROOT%\scoop"
if not defined CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT set "CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT=%CAPSULENV_ROOT%\scoop-global"
for %%I in ("%CAPSULENV_BOOTSTRAP_SCOOP_ROOT%") do set "CAPSULENV_BOOTSTRAP_SCOOP_ROOT=%%~fI"
for %%I in ("%CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT%") do set "CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT=%%~fI"

set "CAPSULENV_POWERSHELL="
call :FindScoopPwsh "%CAPSULENV_BOOTSTRAP_SCOOP_ROOT%"
if not defined CAPSULENV_POWERSHELL call :FindScoopPwsh "%CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT%"
if not defined CAPSULENV_POWERSHELL (
    where pwsh.exe >nul 2>nul && set "CAPSULENV_POWERSHELL=pwsh.exe"
)
if not defined CAPSULENV_POWERSHELL if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "CAPSULENV_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_POWERSHELL (
    where powershell.exe >nul 2>nul && set "CAPSULENV_POWERSHELL=powershell.exe"
)

if not defined CAPSULENV_POWERSHELL (
    echo capsulenv requires Windows PowerShell 5.1 or PowerShell 7.
    exit /b 1
)

"%CAPSULENV_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_ROOT%\scripts\Invoke-Capsulenv.ps1" %*
exit /b %ERRORLEVEL%

:FindScoopPwsh
set "CAPSULENV_PWSH_APP_ROOT=%~1\apps\pwsh"
if exist "%CAPSULENV_PWSH_APP_ROOT%\" (
    for /f "delims=" %%D in ('dir /b /ad /o-d "%CAPSULENV_PWSH_APP_ROOT%" 2^>nul') do (
        if /i not "%%D"=="current" call :SelectPowerShell "%CAPSULENV_PWSH_APP_ROOT%\%%D\pwsh.exe"
    )
    call :SelectPowerShell "%CAPSULENV_PWSH_APP_ROOT%\current\pwsh.exe"
)
call :SelectPowerShell "%~1\shims\pwsh.exe"
set "CAPSULENV_PWSH_APP_ROOT="
exit /b 0

:SelectPowerShell
if defined CAPSULENV_POWERSHELL exit /b 0
if not exist "%~1" exit /b 0
"%~1" -NoLogo -NoProfile -Command "exit 0" >nul 2>nul
if not errorlevel 1 set "CAPSULENV_POWERSHELL=%~f1"
exit /b 0
