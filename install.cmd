@echo off
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "CAPSULENV_SOURCE_ROOT=%%~fI"

set "CAPSULENV_INSTALL_POWERSHELL="
call :FindScoopPwsh "%CAPSULENV_SOURCE_ROOT%\scoop"
if not defined CAPSULENV_INSTALL_POWERSHELL call :FindScoopPwsh "%CAPSULENV_SOURCE_ROOT%\scoop-global"
if not defined CAPSULENV_INSTALL_POWERSHELL (
    for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do call :SelectPowerShell "%%P"
)
if not defined CAPSULENV_INSTALL_POWERSHELL if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "CAPSULENV_INSTALL_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined CAPSULENV_INSTALL_POWERSHELL (
    echo capsulenv installer requires Windows PowerShell 5.1 or PowerShell 7.
    exit /b 1
)

"%CAPSULENV_INSTALL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_SOURCE_ROOT%\scripts\Install-Capsulenv.ps1" %*
exit /b %ERRORLEVEL%

:FindScoopPwsh
set "CAPSULENV_INSTALL_PWSH_ROOT=%~1\apps\pwsh"
if exist "%CAPSULENV_INSTALL_PWSH_ROOT%\" (
    for /f "delims=" %%D in ('dir /b /ad /o-d "%CAPSULENV_INSTALL_PWSH_ROOT%" 2^>nul') do (
        if /i not "%%D"=="current" call :SelectPowerShell "%CAPSULENV_INSTALL_PWSH_ROOT%\%%D\pwsh.exe"
    )
    call :SelectPowerShell "%CAPSULENV_INSTALL_PWSH_ROOT%\current\pwsh.exe"
)
call :SelectPowerShell "%~1\shims\pwsh.exe"
set "CAPSULENV_INSTALL_PWSH_ROOT="
exit /b 0

:SelectPowerShell
if defined CAPSULENV_INSTALL_POWERSHELL exit /b 0
if not exist "%~1" exit /b 0
"%~1" -NoLogo -NoProfile -Command "exit 0" >nul 2>nul
if not errorlevel 1 set "CAPSULENV_INSTALL_POWERSHELL=%~f1"
exit /b 0
