@echo off
setlocal
rem Clear PSModulePath inherited from PowerShell 7; otherwise powershell.exe (5.1) tries to load PS7 modules and fails.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssmc.ps1" %*
set "SSMC_EXIT=%ERRORLEVEL%"
if not "%SSMC_EXIT%"=="0" pause
exit /b %SSMC_EXIT%
